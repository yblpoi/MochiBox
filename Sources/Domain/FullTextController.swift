//
//  FullTextController.swift
//  MochiBox
//
//  V0.6 全文翻译的状态机与执行器（docs/architecture-v0.6-cheat-and-fulltext.md §4）。
//
//    idle ──scan──▶ scanning ──scanDone──▶ done ──translate──▶ translating ──▶ done
//                        │                                              │
//                        └────────── cancel ──▶ cancelled ◀─────────────┘
//
//  三段职责：
//    ① 收片：`handleScanChunk` / `handleScanDone`（由 `SessionController.handleEnvelope`
//       同步调用 —— 与 RPC 回包走**同一条** drain pump，不新开循环）；
//    ② 翻译：按 10 条一批驱动**现有的** `TranslationPipeline`（并发上限、熔断、重试
//       全部复用，§4.3；并发上限默认 4，可由 `maxConcurrent` 配置）。
//       批内先 `resolve`（查缓存）再把未命中的等回来；
//    ③ 落盘与下发：`FullTextStore`（0600 原子写）+ `setTranslations` 分片。
//
//  为什么不用自己的 URLSession：全文与实时共用一份缓存与一套熔断，才谈得上
//  "全文翻过的句子，运行时直接命中"（AC-10.2 的离线重启也依赖这一点）。
//

import Foundation
import Combine

@MainActor
final class FullTextController: ObservableObject {
    // MARK: - 对外状态

    @Published private(set) var phase: FullTextPhase = .idle
    /// 语料条数（去重后的原文数）。
    @Published private(set) var discovered: Int = 0
    /// 已译条数（含命中缓存）。
    @Published private(set) var translated: Int = 0
    /// 其中命中缓存 / 已落盘的条数。
    @Published private(set) var cachedCount: Int = 0
    /// 失败条数（可"重试失败项"）。
    @Published private(set) var failedCount: Int = 0
    /// Agent 在扫描时跳过的条数（纯数字 / 纯 ASCII 等，§4.1 过滤）。
    @Published private(set) var scanSkipped: Int = 0
    /// 本轮翻译的目标条数（进度条分母）。
    @Published private(set) var pendingTarget: Int = 0
    @Published private(set) var progress: FullTextProgress = FullTextProgress()
    @Published private(set) var failures: [FullTextFailure] = []
    @Published private(set) var lastError: ErrorInfo?
    /// 最近一次下发/导出的结果文案。
    @Published private(set) var notice: String = ""
    @Published private(set) var gameHash: String = ""
    /// 是否已接上 RPC（= 会话已连接）。
    @Published private(set) var isAttached: Bool = false
    /// 语料镜像（**粗粒度**刷新：阶段切换 / 每 200 条）。逐条发布会让 SwiftUI
    /// 在上万行时每次 diff 一遍全表。
    @Published private(set) var rows: [FullTextEntry] = []

    // MARK: - 扫描选项

    /// 扫描全量地图（`data/Map*.json`，§4.1）。
    @Published var includeMaps: Bool = true
    /// 把运行期见过的串也纳入语料（Agent 的 `runtimeSeen`）。
    @Published var includeRuntime: Bool = true
    /// 跳过"插件指令行"（含 `<...>` 的行，§4.2 的开关）。
    @Published var skipPluginLines: Bool = true

    // MARK: - 内部

    private var rpc: AgentRPC?
    private var pipeline: TranslationPipeline?
    private var store: FullTextStore?
    private var sendTranslations: (@Sendable ([TranslationPushItem]) async -> Void)?
    /// HostCommand.clear：清理掉假译文后必须先抹掉页面内存里的旧值，
    /// 否则本轮的 pushAll 只会覆盖"有译文"的键，被清掉的假译文还留在页面上。
    private var sendClear: (@Sendable () async -> Void)?
    /// 下一次 pushAll 之前是否要先 clear（只在本次加载真的清过假译文时为真）。
    private var needsClearBeforePush = false
    /// 清理提示：pushAll 会把 notice 改成"已下发 N 条"，这条要一起带上。
    private var purgeNotice: String = ""
    private var log: SessionLog?

    private var corpus = FullTextCorpus()
    /// 每游戏术语表（`glossary/<gameHash>.json`）。
    private var glossaryStore: GlossaryStore?
    /// 与实时路径共享的术语快照（HP/MP 在运行期也要短路）。
    private let glossaryBox: GlossaryBox
    /// 术语页的镜像（编辑后立即刷新）。
    @Published private(set) var glossaryRows: [GlossaryEntry] = []
    /// 本轮翻译顺序：按类别排序后的 raw（先术语/名称，后描述/对话）。
    private var workOrder: [String] = []
    private var workCursor: Int = 0
    private var glossaryLoaded = false
    private var glossaryDirty = false
    /// 用户删掉的术语（墓碑）：种子每次都会重建，没有它删了会复活。
    private var deletedSources: Set<String> = []
    /// 文本（归一后）→ 扫描时判定的类别。
    ///
    /// 实时链路靠它用**和全文相同的类别**算 profile：同一句话若两边类别不同，
    /// 缓存键会分叉（全文译过的句子运行时再花钱翻一次），下发到 Agent 的同一个
    /// mapKey 上还会互相覆盖。
    private var categoryByTextKey: [String: TranslationCategory] = [:]

    /// 实时链路查类别；`nil` = 没扫到过，按对话处理。
    func category(forText text: String) -> TranslationCategory? {
        return categoryByTextKey[GlossaryKey.normalize(text)]
    }
    /// 已译但 profile 与当前不一致的条数（「按新术语重翻」的按钮依据）。
    @Published private(set) var staleCount: Int = 0
    /// 有质量问题的条数。
    @Published private(set) var qualityCount: Int = 0
    private var scanId: String?
    private var scanEstimated: Int = 0
    private var srcLang: String = K.fixedSrcLang
    private var tgtLang: String = K.fixedTgtLang

    /// 翻译游标：从上次停下的位置继续（避免每批都从头扫 10k 条）。
    private var cursor: Int = 0
    private var isCancelRequested: Bool = false
    /// 每批条数 / 单批等待上限。默认取 FullTextConfig，接线时由 SessionController 按
    /// maxBatch × maxConcurrent 计算传入：固定 10 条会让 1 万条排 1000 批。
    private var bulkBatchSize: Int = FullTextConfig.batchSize
    private var bulkTimeoutSec: Double = FullTextConfig.batchTimeoutSec
    private var registeredPipeline: ObjectIdentifier?
    private var lastPushedCount: Int = -1

    /// attach 代次。翻译任务是 UI 起的**非结构化** Task：`stop()` 既不 await 也不持有句柄，
    /// 上一轮完全可能在 store 已被换成本作之后才恢复。它靠这个代次判断"我这轮已经作废"，
    /// 见 `attach` 与 `translate` 的收尾守卫。
    private var attachEpoch: Int = 0

    /// 在飞条目：`cacheKey → 本轮共享这个 key 的全部原文（含各自骨架）`。
    ///
    /// **不能只存一条**：文本相同、控制码不同的两行（`\\C[2]350` / `\\C[3]350`）
    /// 会算出同一个 `cacheKey`；覆盖写会让后一条静默停在未译。
    private struct InFlight {
        var entries: [(raw: String, skeleton: [Segment])]
        /// 这一键用的缓存 profile（术语短路为空）。
        var profile: String = ""
    }

    private var inFlight: [String: InFlight] = [:]
    /// 本批尚未拿到结果的 key（轮询等待用）。
    private var outstanding: Set<String> = []
    private var failedRaws: Set<String> = []
    private var skippedRaws: Set<String> = []
    private var translatedSinceSave: Int = 0
    private var lastPublishedTranslated: Int = 0
    /// 直通模式（未配置后端）被跳过的条数：全 0 译文时用它给出准确提示，
    /// 而不是让用户对着"已完成 0 条"猜。
    private var passthroughSkipped: Int = 0

    init(log: SessionLog? = nil, glossaryBox: GlossaryBox = GlossaryBox()) {
        self.log = log
        self.glossaryBox = glossaryBox
    }

    // MARK: - 接线

    /// 会话连上后由 `SessionController` 调用。
    ///
    /// - Parameter sendTranslations: 把译文灌回页面（`HostCommand.setTranslations`，
    ///   分片由调用方负责 —— `K.setTranslationsChunk` 是协议层常量）。
    func attach(
        rpc: AgentRPC,
        pipeline: TranslationPipeline,
        store: FullTextStore,
        glossaryStore: GlossaryStore? = nil,
        gameHash: String,
        srcLang: String,
        tgtLang: String,
        sendTranslations: @escaping @Sendable ([TranslationPushItem]) async -> Void,
        sendClear: (@Sendable () async -> Void)? = nil,
        log: SessionLog? = nil,
        bulkBatchSize: Int = FullTextConfig.batchSize,
        bulkTimeoutSec: Double = FullTextConfig.batchTimeoutSec
    ) {
        // 每次 attach 换一代。上一轮 `translate()` 若还活着（刚被 `cancelAll()` 唤醒、
        // 或正卡在某一批的 `waitForBatch` 里），它看到代次变了就必须整体放弃：
        // 收尾的 `saveNow()` 拿的是**当前** store，不挡的话上一轮的队列会写进本作的
        // 译文文件；换游戏那条路更狠 —— corpus 刚被清空、`loadPersisted()` 还没合并完，
        // 一次 `saveNow()` 就把本作的译文文件写成 0 条。
        attachEpoch &+= 1
        self.rpc = rpc
        self.pipeline = pipeline
        self.store = store
        self.glossaryStore = glossaryStore
        // 换游戏 ≠ 同一款重连。本控制器是 App 进程级单例（`SessionController.fullText`），
        // `detach()` 保留语料只对"同一 gameHash 重连后整体重放"成立（见 detach 注释）。
        // 不在这里清：第二款游戏打开时上一款的条目会被一起下发，而且 `loadPersisted()`
        // 清理假译文后的 `saveNow()` 会把上一款的译文写进**本作**的 `fulltext/<hash>.json`。
        // 安全性是**两件事**，别只想到第一件：
        // ① 不丢数据：正常换游戏先走 `SessionController.stop()` → 先 `saveNow()` 再 `detach()`
        //    （Sources/Domain/SessionController.swift:306 → :472）。唯一绕开它的是 `.failed`
        //    状态下直接重开（`start()` 允许 idle/stopped/failed 进入）：那种情况下
        //    `connectAgentFeatures` 要么还没跑（fullText 未 attach，语料属于上一款已正常 stop 的
        //    游戏），要么刚跑完 `loadPersisted()`（语料 == 盘上文件，一条新译文都还没有）——
        //    这里清掉的都是盘上已有的内容，不会丢。
        // ② 旧任务不许写新 store：上一轮的 `translate()` 若还活着，它收尾的 `saveNow()` 拿到的是
        //    **当前** store。这条由 `attachEpoch`（本方法开头自增 + `translate` 的守卫）负责，
        //    换游戏与 `.failed` 重开两条路都覆盖。
        if !self.gameHash.isEmpty, self.gameHash != gameHash {
            resetGameScopedState()
            // 扫描侧计数不在 clearAll 的口径里，但换游戏必须一起归零（UI 上是同一组指标）。
            scanSkipped = 0
            passthroughSkipped = 0
            translatedSinceSave = 0
            needsClearBeforePush = false
            purgeNotice = ""
            // 术语表同样按游戏隔离：不重置 glossaryLoaded，`loadGlossaryIfNeeded()` 会直接
            // return，上一款的术语继续生效，并随 `saveGlossary()` 写进新游戏的
            // `glossary/<gameHash>.json`。这里只把快照回落成内置种子，真正的落盘加载
            // 由紧随其后的 `loadPersisted()` → `loadGlossary()` 走原路径（不另写一份种子逻辑）。
            glossaryLoaded = false
            glossaryDirty = false
            deletedSources.removeAll()
            glossaryBox.update(Glossary(GlossarySeed.entries))
            publishGlossary()
            self.log?.info("FullTextController", "切换游戏，已清空上一款游戏的语料", [
                "from": self.gameHash,
                "to": gameHash
            ])
        }
        self.gameHash = gameHash
        self.srcLang = srcLang
        self.tgtLang = tgtLang
        self.sendTranslations = sendTranslations
        self.sendClear = sendClear
        self.bulkBatchSize = max(1, bulkBatchSize)
        self.bulkTimeoutSec = max(1, bulkTimeoutSec)
        if let log = log { self.log = log }
        self.isAttached = true
        self.lastError = nil
        self.phase = .idle
        self.scanId = nil
        // 复位取消标记只对**本次**会话有效。上一轮遗留的翻译任务不靠这个布尔值收手
        // （它一置 false，"取消"就被撤销了），而是靠上面自增过的 attachEpoch 作废。
        self.isCancelRequested = false
        self.lastPushedCount = -1
        registerPipelineHandler(pipeline)
    }

    /// 会话停止 / 重连：取消在飞的翻译与扫描，**保留语料**（重连后要重放）。
    func detach() {
        isCancelRequested = true
        rpc = nil
        pipeline = nil
        sendTranslations = nil
        sendClear = nil
        isAttached = false
        inFlight.removeAll()
        outstanding.removeAll()
        if phase.isRunning { phase = .cancelled }
    }

    /// 清掉"跟着某一款游戏走"的内存状态（**不碰落盘**）。
    ///
    /// 两个调用点：`attach` 换游戏、`clearAll`（UI 的"删除译文数据"）。字段清单只写一份，
    /// 免得将来加字段时漏掉一边 —— 漏掉的后果就是上一款游戏的条目/计数继续留在新游戏里。
    private func resetGameScopedState() {
        corpus.clear()
        failures.removeAll()
        failedRaws.removeAll()
        skippedRaws.removeAll()
        inFlight.removeAll()
        outstanding.removeAll()
        translated = 0
        cachedCount = 0
        failedCount = 0
        qualityCount = 0
        staleCount = 0
        workOrder.removeAll()
        workCursor = 0
        categoryByTextKey.removeAll()
        discovered = 0
        pendingTarget = 0
        cursor = 0
        lastPushedCount = -1
        phase = .idle
        refreshCounts()
        publishRows()
    }

    private func registerPipelineHandler(_ pipeline: TranslationPipeline) {
        let identifier = ObjectIdentifier(pipeline)
        guard registeredPipeline != identifier else { return }
        registeredPipeline = identifier
        Task { [weak self] in
            await pipeline.onResult { result in
                Task { @MainActor in self?.handlePipelineResult(result) }
            }
        }
    }

    // MARK: - 扫描

    /// 开始扫描。立即返回（Agent 分片推送，§2.3）。
    @discardableResult
    func scan() async -> Bool {
        guard let rpc = rpc else {
            lastError = ErrorInfo(code: .attachFailed, message: "尚未连接游戏")
            phase = .failed
            return false
        }
        guard phase != .scanning, phase != .translating else { return false }
        isCancelRequested = false
        scanId = nil
        scanEstimated = 0
        scanSkipped = 0
        lastError = nil
        phase = .scanning
        let args: [String: JSONValue] = [
            "includeMaps": .bool(includeMaps),
            "includeRuntime": .bool(includeRuntime)
        ]
        do {
            let value = try await rpc.call(method: "text.scanStart", args: .object(args))
            let start = try value.decoded(ScanStartPayload.self)
            if scanId == nil { scanId = start.scanId }
            scanEstimated = max(0, start.estimated)
            await loadGlossaryIfNeeded()
            ingestTerms(start.terms)
            refreshCounts()
            log?.info("FullTextController", "全文扫描开始", ["scanId": start.scanId, "estimated": "\(start.estimated)"])
            return true
        } catch let error as MochiBoxError {
            lastError = error.asErrorInfo
            phase = .failed
            return false
        } catch {
            lastError = ErrorInfo(code: .agentError, message: "扫描启动失败：\(error)")
            phase = .failed
            return false
        }
    }

    /// 取消扫描。Agent 会在片间检查，并以 `scanDone(cancelled:true)` 收尾（§2.3）。
    @discardableResult
    func cancelScan() async -> Bool {
        guard phase == .scanning else { return false }
        phase = .cancelled
        guard let rpc = rpc, let id = scanId else { return true }
        _ = try? await rpc.call(method: "text.scanCancel", args: .object(["scanId": .string(id)]))
        log?.info("FullTextController", "全文扫描已取消", ["scanId": id])
        return true
    }

    /// 收一片扫描结果（MainActor，由 `SessionController` 同步调用）。
    func handleScanChunk(_ payload: ScanChunkPayload) {
        guard accept(scanId: payload.scanId) else { return }
        // RPC 回包比第一片晚到时会出现"片先到"的顺序；按"正在扫描"继续收，不要丢片。
        // **但翻译已经开始时不许回退阶段**：取消扫描后立刻点翻译，残留的片会把
        // `.translating` 顶回 `.scanning`，UI 就会显示成"正在扫描"而进度条卡住。
        if phase != .scanning && phase != .translating {
            phase = .scanning
        }
        for item in payload.items {
            if skipPluginLines && FullTextFilter.isPluginLine(item.raw) { continue }
            let raw = item.raw
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let isNew = corpus.insert(raw: raw, source: item.source, path: item.path)
            if isNew {
                let skeleton = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
                let key = GlossaryKey.normalize(Segmenter.joinForBackend(skeleton))
                if !key.isEmpty {
                    categoryByTextKey[key] = TranslationCategory.inferred(source: item.source, path: item.path)
                }
                // 扫描片在翻译期间到达：追加到队列尾部，否则这轮会漏掉、得再点一次翻译。
                if phase == .translating { workOrder.append(raw) }
            }
        }
        discovered = corpus.count
        // 每片都刷 `rows` 会让 10k 条语料在扫描期间反复重排；200 条一刷足够看出在动。
        if corpus.count / 200 != rows.count / 200 { publishRows() }
    }

    /// 收尾（MainActor）。
    func handleScanDone(_ payload: ScanDonePayload) {
        guard accept(scanId: payload.scanId) else { return }
        scanSkipped = payload.skipped
        // 同上：翻译已经在跑时，扫描的收尾只更新统计，不能改阶段。
        if phase != .translating {
            phase = payload.cancelled ? .cancelled : .done
        }
        discovered = corpus.count
        publishRows()
        refreshCounts()
        log?.info("FullTextController", "全文扫描结束", [
            "total": "\(payload.total)",
            "skipped": "\(payload.skipped)",
            "cancelled": payload.cancelled ? "1" : "0",
            "corpus": "\(corpus.count)"
        ])
    }

    /// 只接受当前这次扫描的片；`scanId` 还没记下来时（回包晚于首片）认领第一片。
    private func accept(scanId incoming: String) -> Bool {
        guard !incoming.isEmpty else { return true }
        if scanId == nil {
            scanId = incoming
            return true
        }
        return scanId == incoming
    }

    // MARK: - 翻译

    /// 翻译所有未译条目（批 10 / 顺序执行；并发与熔断复用管线）。
    ///
    /// `await` 会一直等到整轮结束或取消 —— 调用方（UI）应放在 `Task {}` 里，
    /// 否则按钮的点击回调会被挂住（主线程不会卡，但交互反馈会延后）。
    func translate() async {
        guard pipeline != nil else {
            lastError = ErrorInfo(code: .attachFailed, message: "尚未连接游戏")
            return
        }
        guard phase != .translating, phase != .scanning else { return }
        guard corpus.count > 0 else {
            notice = "还没有语料：先点「扫描」"
            return
        }
        // 本轮绑定的 attach 代次。中途换了 attach（= 换了会话，可能连游戏都换了）就作废，
        // 否则收尾的落盘/下发会落到别人的 store 上（见 attachEpoch 与收尾守卫）。
        let epoch = attachEpoch
        // 本轮新增 = 结束时 - 开始时（translated 是累计值，重试轮同样适用）。
        let translatedAtStart = corpus.translatedCount
        // 上一轮的错误不能粘在这一轮：本轮结束时会按真实结果重写。
        lastError = nil
        isCancelRequested = false
        cursor = 0
        failedRaws.removeAll()
        skippedRaws.removeAll()
        failures.removeAll()
        failedCount = 0
        inFlight.removeAll()
        outstanding.removeAll()
        translatedSinceSave = 0
        passthroughSkipped = 0
        pendingTarget = corpus.untranslatedCount
        phase = .translating
        refreshCounts()
        log?.info("FullTextController", "全文翻译开始", ["pending": "\(pendingTarget)"])

        await loadGlossaryIfNeeded()
        // 名称类先翻、描述/对话后翻：术语在被引用前就已锁定，且不增加任何模型调用。
        learnTermsFromCorpus()
        prepareWorkOrder()

        // 代次条件写在循环条件里：换过 attach（= 上一轮的 workOrder 属于别的会话）
        // 就再也不进循环体，剩下的收尾由下面那道 guard 挡住。
        while epoch == attachEpoch && !isCancelRequested {
            let batch = nextBatch(limit: bulkBatchSize)
            if batch.isEmpty { break }
            await translateBatch(batch)
            if translatedSinceSave >= FullTextConfig.saveEvery {
                translatedSinceSave = 0
                await saveNow(ifEpoch: epoch)
            }
            publishRowsIfNeeded()
        }
        // 循环可能因为"队列空了"自然结束，而 attach 恰好落在这一段 —— 收尾那三句
        // （saveNow / saveGlossaryIfDirty / pushAll）都是写给**当前** store 的，必须再挡一次。
        guard epoch == attachEpoch else { return }

        // 主循环跑完再修术语违例：「名称先翻」只保证**它们之后**的句子拿到术语，
        // 已经在术语表完整之前翻掉的句子只能靠这一次带强调的重译（每条最多一次）。
        var stillViolating = 0
        if !isCancelRequested {
            stillViolating = await repairGlossaryViolations()
        }

        phase = isCancelRequested ? .cancelled : .done
        // 收尾判定看**本轮新增**：0 条新增 + 有失败时不能报 .done（绿色「已完成」）——
        // finish_reason / token 预算这类原因只在日志里，界面必须自己说出来。
        var outcome = FullTextOutcome.Summary(phase: phase, notice: "", error: nil)
        if !isCancelRequested {
            outcome = FullTextOutcome.summary(
                translatedThisRun: corpus.translatedCount - translatedAtStart,
                failedCount: failedCount,
                firstMessage: failures.first?.error.message
            )
            phase = outcome.phase
        }
        if let message = outcome.error {
            lastError = ErrorInfo(code: failures.first?.error.code ?? .badResponse, message: message)
            log?.warn("FullTextController", "本轮没有新增译文，阶段置为失败", [
                "failed": "\(failedCount)",
                "added": "\(corpus.translatedCount - translatedAtStart)"
            ])
        }
        if translated == 0 && passthroughSkipped > 0 && !isCancelRequested {
            notice = "当前是直通模式（未配置翻译后端），全文翻译不会产生译文"
        }
        await saveNow(ifEpoch: epoch)
        saveGlossaryIfDirty()
        await pushAll()
        // 放在 pushAll 之后：它推送成功时会用「已下发 N 条」覆盖 notice。
        if stillViolating > 0 {
            notice = "有 \(stillViolating) 条译文仍未遵守锁定术语（可在术语页调整译名）"
        }
        // 失败原因优先级最高：它解释的是「为什么少了一批译文」。
        if !outcome.notice.isEmpty {
            notice = outcome.notice
        }
        refreshStaleCount()
        refreshCounts()
        log?.info("FullTextController", "全文翻译结束", [
            "translated": "\(translated)",
            "failed": "\(failedCount)",
            "cancelled": isCancelRequested ? "1" : "0"
        ])
    }

    /// 取消翻译（下一批边界生效；已完成的条目保留）。
    func cancel() {
        isCancelRequested = true
        if phase == .scanning {
            Task { await cancelScan() }
        } else if phase == .translating {
            phase = .cancelled
        }
    }

    /// 重试失败项。
    func retryFailed() async {
        guard !failedRaws.isEmpty else {
            notice = "没有失败项"
            return
        }
        failedRaws.removeAll()
        failures.removeAll()
        failedCount = 0
        cursor = 0
        await translate()
    }

    /// 按类别排序后的待翻队列：系统术语 → 名称 → 地名 → 描述 → 对话。
    private func prepareWorkOrder() {
        var pending: [(raw: String, index: Int, rank: Int)] = []
        pending.reserveCapacity(corpus.count)
        for (index, raw) in corpus.order.enumerated() {
            guard let entry = corpus.entry(for: raw), !entry.isTranslated else { continue }
            if failedRaws.contains(raw) || skippedRaws.contains(raw) { continue }
            pending.append((raw, index, entry.category.rank))
        }
        pending.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.index < rhs.index
        }
        workOrder = pending.map { $0.raw }
        workCursor = 0
    }

    /// 下一批：只取**同一个 rank 组**，名称/术语整组翻完并学进术语表之后，才轮到
    /// 引用它们的描述与对话（分组规则在 `FullTextWorkOrder`，纯函数、可单测）。
    ///
    /// 旧实现是「全序取前 N 条」：名称与对话在 rank 交界处混进同一批，而名称要等回包
    /// 才 `learnTermIfNeeded`，同批的引用句发请求时根本拿不到它 —— 「咬人水母」在名称
    /// 字段里是一个译法、在台词里被模型自由译成「刺人水母」。
    private func nextBatch(limit: Int) -> [FullTextEntry] {
        let raws = FullTextWorkOrder.nextBatch(
            order: workOrder,
            rankOf: { corpus.entry(for: $0)?.category.rank ?? Int.max },
            cursor: &workCursor,
            isTranslated: { corpus.entry(for: $0)?.isTranslated ?? true },
            isBlocked: { raw in
                corpus.entry(for: raw) == nil
                    || failedRaws.contains(raw)
                    || skippedRaws.contains(raw)
            },
            limit: limit
        )
        return raws.compactMap { corpus.entry(for: $0) }
    }

    /// - Parameters:
    ///   - ignoreCache: 跳过缓存查询（术语违例重译用：坏译文就在缓存里）。结果仍按原 key 覆盖写回。
    ///   - emphasis: 本批必须逐字使用的术语对（上一版违反的），管线取并集放进 request 级。
    private func translateBatch(
        _ batch: [FullTextEntry],
        ignoreCache: Bool = false,
        emphasis: [GlossaryPair] = []
    ) async {
        guard let pipeline = pipeline, !isCancelRequested else { return }
        var items: [TranslationRequestItem] = []
        var seenKeys: Set<String> = []
        let snapshot = glossary
        for entry in batch {
            let skeleton = Segmenter.splitSegments(raw: entry.raw, engineFamily: K.engineFamily)
            // 全 code 行（`\i[17]`）没有可翻的文本段，与运行期一致地跳过。
            guard Segmenter.textSegmentCount(skeleton) > 0 else {
                skippedRaws.insert(entry.raw)
                continue
            }
            let category = entry.category
            let text = Segmenter.joinForBackend(skeleton)
            let allowSingle = category.allowsSingleCharTerms
            // 整串命中术语表：0 请求、绝对一致。keepAsIs（HP/MP）回填输入原文，
            // 不能写 target —— 归一化会把 `LV` 变成 `Lv`。
            // 用剥码后的文本查：`\C[2]HP` 的 raw 整串永远不等于 `HP`，
            // 实时侧传的正是剥码文本，两边必须同口径。
            if Segmenter.textSegmentCount(skeleton) == 1, let output = snapshot.exactOutput(for: text) {
                let hints = snapshot.pairs(in: [text], includeSingleChar: allowSingle)
                let profile = profileId(for: category, pairs: hints)
                applyGlossaryTranslation(entry: entry, target: output, profile: profile)
                continue
            }
            let hints = snapshot.pairs(in: [text], includeSingleChar: allowSingle)
            let profile = profileId(for: category, pairs: hints)
            let key = Segmenter.cacheKey(
                engineFamily: K.engineFamily,
                srcLang: srcLang,
                tgtLang: tgtLang,
                segments: skeleton,
                profile: profile
            )
            if inFlight[key] == nil { inFlight[key] = InFlight(entries: [], profile: profile) }
            inFlight[key]?.entries.append((raw: entry.raw, skeleton: skeleton))
            // 同一个 key 只发一条请求；结果回来时再扇出到共享它的全部原文。
            guard seenKeys.insert(key).inserted else { continue }
            items.append(TranslationRequestItem(
                key: key,
                text: text,
                segments: skeleton,
                category: category,
                glossary: hints,
                ignoreCache: ignoreCache ? true : nil,
                emphasis: emphasis.isEmpty ? nil : emphasis
            ))
        }
        guard !items.isEmpty else { return }

        let outcomes = await pipeline.resolve(items)
        outstanding.removeAll()
        for (index, outcome) in outcomes.enumerated() {
            let item = items[index]
            switch outcome {
            case .hit(let result):
                applyTranslated(key: item.key, translatedText: result.translatedText, cached: true)
            case .pending:
                outstanding.insert(item.key)
            case .skipped(let reason):
                markSkipped(key: item.key)
                log?.debug("FullTextController", "全文条目被跳过", ["reason": reason])
            case .passthrough:
                // 直通模式：结果 == 原文，不算译好，也不该反复重试。
                markPassthrough(key: item.key)
            case .failed(let info):
                markFailed(key: item.key, error: info)
            }
        }
        if !outstanding.isEmpty {
            await waitForBatch()
        }
    }

    // MARK: - 术语违例修复

    /// 对「译文没遵守锁定术语」的条目再要一次译文，**每条最多一次**。
    ///
    /// 只动机翻/缓存（人工译文一条不动），上限 `FullTextConfig.repairLimit`：
    /// 术语表本身若被改坏，重译整轮会让成本翻倍，宁可只在质量页暴露。
    /// 仍违例的保留 `.glossaryViolation` 并写 warn —— 不循环重试，避免反复计费。
    /// - Returns: 重译后**仍然**违例的条数（由 `translate()` 落到 notice 上）。
    private func repairGlossaryViolations() async -> Int {
        guard pipeline != nil, !isCancelRequested else { return 0 }
        let snapshot = glossary
        guard !snapshot.isEmpty else { return 0 }

        var targets: [(entry: FullTextEntry, pairs: [GlossaryPair])] = []
        for entry in corpus.all {
            guard targets.count < FullTextConfig.repairLimit else { break }
            guard entry.origin != .manual, entry.isTranslated else { continue }
            guard entry.issues.contains(QualityIssue.glossaryViolation.rawValue) else { continue }
            guard let translated = entry.translated else { continue }
            let skeleton = Segmenter.splitSegments(raw: entry.raw, engineFamily: K.engineFamily)
            let text = Segmenter.joinForBackend(skeleton)
            let pairs = snapshot.violations(raw: text, translated: translated, category: entry.category)
            // 检查之后术语被改过（用户编辑 / 删墓碑）：现在不违例，不必再花钱。
            guard !pairs.isEmpty else { continue }
            targets.append((entry, pairs))
        }
        guard !targets.isEmpty else { return 0 }

        log?.info("FullTextController", "术语违例自动重译", ["items": "\(targets.count)"])

        // `beginRepair` 会清掉旧译文，先留一份：回不来的原样恢复，
        // 否则一次网络抖动就把最多 200 条已有译文连磁盘一起抹掉。
        var rollback: [String: FullTextEntry] = [:]
        for target in targets {
            rollback[target.entry.raw] = target.entry
            corpus.beginRepair(raw: target.entry.raw)
            translated = max(0, translated - 1)
        }

        // 按批走现有管线（并发/超时/熔断全部复用）。一批内的违例术语取并集，
        // 避免把 200 条塞进一个请求。
        let chunkSize = max(1, bulkBatchSize)
        var start = 0
        while start < targets.count && !isCancelRequested {
            let end = min(start + chunkSize, targets.count)
            var seen: Set<String> = []
            var emphasis: [GlossaryPair] = []
            for target in targets[start..<end] {
                for pair in target.pairs where emphasis.count < 20 {
                    guard seen.insert(GlossaryKey.normalize(pair.source)).inserted else { continue }
                    emphasis.append(pair)
                }
            }
            let batch = targets[start..<end].compactMap { corpus.entry(for: $0.entry.raw) }
            if !batch.isEmpty {
                await translateBatch(batch, ignoreCache: true, emphasis: emphasis)
            }
            start = end
        }

        // 没回来的（超时/失败/直通）恢复旧译文；回来的看是否还违例。
        var stillViolating = 0
        for target in targets {
            let raw = target.entry.raw
            guard let current = corpus.entry(for: raw) else { continue }
            if !current.isTranslated, let previous = rollback[raw] {
                corpus.applyTranslation(
                    raw: raw,
                    translated: previous.translated ?? "",
                    segments: previous.segments,
                    origin: previous.origin,
                    profile: previous.profile,
                    issues: previous.issues
                )
                if previous.isTranslated { translated += 1 }
                continue
            }
            if current.issues.contains(QualityIssue.glossaryViolation.rawValue) {
                stillViolating += 1
            }
        }
        if stillViolating > 0 {
            log?.warn("FullTextController", "术语违例重译后仍未遵守", ["items": "\(stillViolating)"])
        }

        // 修好的条数没变，但**内容**变了：pushAll 靠条数判重，不清掉这个水位就
        // 不会把修好的译文重放到页面（Agent 会一直显示旧名字）。
        if targets.contains(where: { corpus.entry(for: $0.entry.raw)?.isTranslated == true }) {
            lastPushedCount = -1
        }

        // 计数按语料重算：beginRepair / 回滚 / 同 key 扇出都会让增量记账漂移，一次对齐。
        translated = corpus.translatedCount
        refreshStaleCount()
        refreshCounts()
        publishRows()
        return stillViolating
    }

    /// 等本批结果。轮询而非 continuation：这里有超时兜底 + 取消检查，
    /// 用 continuation 还得再维护一张等待者表，反而更容易漏唤醒。
    private func waitForBatch() async {
        let deadline = Date().addingTimeInterval(bulkTimeoutSec)
        let tick = UInt64(FullTextConfig.waitTickMs) * 1_000_000
        while !outstanding.isEmpty && !isCancelRequested && Date() < deadline {
            try? await Task.sleep(nanoseconds: tick)
        }
        if !outstanding.isEmpty {
            let keys = outstanding
            outstanding.removeAll()
            let error = ErrorInfo(code: .timeout, message: "全文翻译批次超时（\(Int(bulkTimeoutSec))s）")
            for key in keys {
                markFailed(key: key, error: error)
            }
        }
    }

    /// 这批结果有没有可信译文？passthrough（直通/熔断降级）与 circuit_open 一律不可信。
    ///
    /// 纯函数（B 组直接单测）：旧实现熔断期回填"译文 = 原文"的 items，调用方只看
    /// items 不看 backend，于是把日文原文当成译文写进语料并标记已翻译 ——
    /// 真机上 7000+ 条就是这么被污染的。
    nonisolated static func isUntranslatedResult(_ result: PipelineBatchResult) -> Bool {
        if result.backend == .passthrough { return true }
        if result.error?.code == .circuitOpen { return true }
        return false
    }

    /// 管线回调（由 `onResult` 触发，已切到 MainActor）。
    ///
    /// `outstanding` **只属于当前这一批**：`translateBatch` 在提交前 `removeAll()`，
    /// 随后 `await waitForBatch()` 阻塞到本批回齐（主循环与术语修复环都是顺序调用），
    /// 所以任何时刻最多只有一批在飞 —— 出错时整批清是安全的，不存在误杀别的批次。
    /// （同一管线也承载实时链路，但实时条目不在 `outstanding` 里，清不动它们。）
    ///
    /// 入口先判"这批结果是否可信"，不可信就整批落失败，绝不写语料。
    private func handlePipelineResult(_ result: PipelineBatchResult) {
        // 失败原因必须落到可见的 lastError（第一条为准）：后续块成功时 result.error == nil，
        // 若无条件覆盖就会把原因洗掉，界面只剩一句"失败 N 条"。
        if let error = result.error, lastError == nil {
            lastError = error
        }
        // 守卫必须在 for 循环**之前**：这条路径一条译文都不能落进 corpus。
        if Self.isUntranslatedResult(result) {
            let error = result.error ?? ErrorInfo(code: .circuitOpen)
            // 用 markFailed 而不是 markSkipped：熔断是暂时的，用户要能"重试失败项"。
            // markSkipped 会把这些条目写进 skippedRaws，重试时被永久跳过。
            for item in result.items {
                markFailed(key: item.key, error: error)
            }
            let keys = outstanding
            outstanding.removeAll()
            for key in keys {
                markFailed(key: key, error: error)
            }
            log?.warn("FullTextController", "整批结果不是译文，已按失败落账", [
                "code": error.code.rawValue,
                "items": "\(result.items.count)",
                "outstanding": "\(keys.count)"
            ])
            return
        }
        // 单条失败（段数不符且重试后仍失败）：只落对应的 key，不再把整批 outstanding
        // 一起标失败 —— 旧实现靠 `result.error` 判断"哪句挂了"，一条坏句会连坐整批。
        for (key, info) in result.itemErrors {
            markFailed(key: key, error: info)
        }
        for item in result.items {
            guard inFlight[item.key] != nil else { continue }
            applyTranslated(key: item.key, translatedText: item.translatedText, cached: item.cached)
        }
        if let error = result.error, !outstanding.isEmpty {
            // 部分失败也要立刻收尾：拆块后常见的形状是"这一批交付了 30 条、剩 10 条失败"，
            // `items` 非空但 `error` 非空。旧实现只在 `items.isEmpty` 时清，剩下的 key 只能
            // 靠 `waitForBatch` 的 90s 超时收场 —— 每波空转 90s，用户等不及就取消了。
            // 靠结果本身无法知道"哪几句挂了"（`items` 里没有失败项），所以按整批清。
            let keys = outstanding
            outstanding.removeAll()
            for key in keys {
                markFailed(key: key, error: error)
            }
        }
        outstanding.subtract(result.items.map { $0.key })
    }

    /// 术语整串命中：不经过模型，直接写回。
    ///
    /// keepAsIs 也写回（target == 原文）：这样进度条能到 100%、行状态是「已译」、
    /// 导出也一致；若记成 skipped，pending 分母永远差这几条。
    private func applyGlossaryTranslation(entry: FullTextEntry, target: String, profile: String) {
        let skeleton = Segmenter.splitSegments(raw: entry.raw, engineFamily: K.engineFamily)
        do {
            let segments = try Segmenter.translatedSegments(segments: skeleton, translatedText: target)
            let reassembled = try Segmenter.reassemble(segments: skeleton, translatedText: target)
            let issues = FullTextQuality.check(
                raw: entry.raw,
                translated: reassembled,
                segments: skeleton,
                category: entry.category,
                glossary: glossary,
                srcLang: srcLang,
                suppressIdentical: true
            )
            corpus.applyTranslation(
                raw: entry.raw,
                translated: reassembled,
                segments: segments,
                origin: .machine,
                profile: profile,
                issues: issues.map { $0.rawValue }
            )
            translated += 1
            translatedSinceSave += 1
        } catch {
            failedRaws.insert(entry.raw)
            recordFailure(raw: entry.raw, error: ErrorInfo(code: .segmentMismatch))
        }
        refreshCounts()
    }

    /// 一条结果扇出到共享同一 cacheKey 的全部原文（各自按自己的骨架重组）。
    private func applyTranslated(key: String, translatedText: String, cached: Bool) {
        guard let info = inFlight.removeValue(forKey: key) else { return }
        outstanding.remove(key)
        for entry in info.entries {
            do {
                let segments = try Segmenter.translatedSegments(segments: entry.skeleton, translatedText: translatedText)
                let reassembled = try Segmenter.reassemble(segments: entry.skeleton, translatedText: translatedText)
                let previous = corpus.entry(for: entry.raw)
                let hadIssues = !(previous?.issues.isEmpty ?? true)
                let category = previous?.category ?? .other
                let issues = FullTextQuality.check(
                    raw: entry.raw,
                    translated: reassembled,
                    segments: entry.skeleton,
                    category: category,
                    glossary: glossary,
                    srcLang: srcLang
                )
                corpus.applyTranslation(
                    raw: entry.raw,
                    translated: reassembled,
                    segments: segments,
                    origin: cached ? .cache : .machine,
                    profile: info.profile,
                    issues: issues.map { $0.rawValue }
                )
                if issues.isEmpty && hadIssues { qualityCount = max(0, qualityCount - 1) }
                if !issues.isEmpty && !hadIssues { qualityCount += 1 }
                if cached { cachedCount += 1 }
                translated += 1
                translatedSinceSave += 1
                learnTermIfNeeded(raw: entry.raw)
            } catch {
                failedRaws.insert(entry.raw)
                recordFailure(raw: entry.raw, error: ErrorInfo(code: .segmentMismatch))
            }
        }
        refreshCounts()
    }

    private func markSkipped(key: String) {
        guard let info = inFlight.removeValue(forKey: key) else { return }
        outstanding.remove(key)
        for entry in info.entries { skippedRaws.insert(entry.raw) }
    }

    private func markPassthrough(key: String) {
        guard let info = inFlight.removeValue(forKey: key) else { return }
        outstanding.remove(key)
        passthroughSkipped += info.entries.count
        for entry in info.entries { skippedRaws.insert(entry.raw) }
    }

    private func markFailed(key: String, error: ErrorInfo) {
        guard let info = inFlight.removeValue(forKey: key) else { return }
        outstanding.remove(key)
        for entry in info.entries {
            failedRaws.insert(entry.raw)
            recordFailure(raw: entry.raw, error: error)
        }
        refreshCounts()
    }

    private func recordFailure(raw: String, error: ErrorInfo) {
        if let index = failures.firstIndex(where: { $0.raw == raw }) {
            failures[index] = FullTextFailure(raw: raw, error: error)
        } else if failures.count < 500 {
            failures.append(FullTextFailure(raw: raw, error: error))
        }
        failedCount = failedRaws.count
    }

    // MARK: - 下发

    /// 把语料里的译文一次性灌回页面（`setTranslations` 分片由调用方负责，§2.4）。
    ///
    /// 只在"有新增译文"时真正下发：重连后 `lastPushedCount` 会被清空（`attach`），
    /// 因此重连一定会重放（§9）。
    func pushAll(force: Bool = false) async {
        guard isAttached, let send = sendTranslations else { return }
        // 清理过假译文：页面内存里还留着上一轮的旧值，必须先整体抹掉再重发。
        // 发不出去也不保留标记没意义 —— 下一次 pushAll 会重新走一遍。
        if needsClearBeforePush, let clear = sendClear {
            await clear()
            needsClearBeforePush = false
            lastPushedCount = -1
        }
        let ready = corpus.all.filter { $0.isTranslated }
        guard !ready.isEmpty else {
            // 只有用户**显式**要求下发时才覆盖提示文案：自动路径（翻译结束后）
            // 刚写过"直通模式无译文"这类更具体的说明，不能被一句空话顶掉。
            if force { notice = noticeWithPurge("暂无可下发的译文") }
            return
        }
        if !force && ready.count == lastPushedCount { return }

        var items: [TranslationPushItem] = []
        items.reserveCapacity(ready.count)
        var dropped = 0
        for entry in ready {
            guard let translated = entry.translated, !translated.isEmpty else { continue }
            let rawSegments = Segmenter.splitSegments(raw: entry.raw, engineFamily: K.engineFamily)
            if Segmenter.textSegmentCount(rawSegments) == 0 { continue }
            let translatedSegments = entry.segments
                ?? Segmenter.splitSegments(raw: translated, engineFamily: K.engineFamily)
            // 文本段数对不上就不可能安全重组（Agent 的 `mergeBySkeleton` 会拒绝拼接），
            // 与其下发一条"永远画原文"的废条目，不如计入 dropped 让 UI 说出来。
            guard Segmenter.textSegmentCount(translatedSegments) == Segmenter.textSegmentCount(rawSegments) else {
                dropped += 1
                continue
            }
            items.append(TranslationPushItem(
                key: Segmenter.mapKey(rawSegments),
                translatedRaw: translated,
                segments: translatedSegments
            ))
        }
        guard !items.isEmpty else {
            notice = noticeWithPurge("无可下发条目（\(dropped) 条缺分段证据）")
            return
        }
        await send(items)
        lastPushedCount = ready.count
        // 清理提示不能被"已下发 N 条"顶掉：用户得知道这几千条为什么重新出现了。
        notice = noticeWithPurge("已下发 \(items.count) 条译文" + (dropped > 0 ? "（跳过 \(dropped) 条）" : ""))
        log?.info("FullTextController", "全文译文已下发", [
            "items": "\(items.count)",
            "dropped": "\(dropped)"
        ])
    }

    /// 下发文案前拼上"清理了 N 条假译文"。清理发生在加载阶段，
    /// 但用户往往是在"翻译完成"之后才看提示，拼在一起才解释得通。
    private func noticeWithPurge(_ text: String) -> String {
        return purgeNotice.isEmpty ? text : "\(purgeNotice)；\(text)"
    }

    // MARK: - 术语表

    /// 当前术语快照（每次读都给一份值拷贝，批量内不会看到半成品）。
    var glossary: Glossary { return glossaryBox.snapshot() }

    /// 读本游戏术语表（内置种子打底 + 落盘条目覆盖）。
    func loadGlossary() async {
        var snapshot = Glossary(GlossarySeed.entries)
        if let store = glossaryStore {
            let file = await Task.detached(priority: .utility) { store.load() }.value
            if let file = file {
                for entry in file.entries { snapshot.upsert(entry) }
                deletedSources = Set(file.deletedSources ?? [])
            }
        }
        for source in deletedSources { snapshot.remove(source: source) }
        glossaryBox.update(snapshot)
        glossaryLoaded = true
        publishGlossary()
        refreshStaleCount()
    }

    private func loadGlossaryIfNeeded() async {
        guard !glossaryLoaded else { return }
        await loadGlossary()
    }

    /// 扫描启动时 Agent 带回来的 `$dataSystem.terms`。
    ///
    /// 只处理两类：
    /// · 纯 ASCII 标识符（HP/MP/TP/EXP/Lv）→ `keepAsIs`，命中即不送模型；
    /// · 其余交给语料翻完后 `learnTermIfNeeded`（**不预置空译文**）。
    private func ingestTerms(_ terms: [ScanTerm]) {
        guard !terms.isEmpty else { return }
        var snapshot = glossaryBox.snapshot()
        var changed = false
        for term in terms {
            let source = term.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            if snapshot.entry(for: source) != nil { continue }
            if isASCIIIdentifier(source) {
                snapshot.upsert(GlossaryEntry(
                    source: source,
                    target: source,
                    kind: .system,
                    keepAsIs: true
                ))
                changed = true
            }
        }
        if changed {
            glossaryBox.update(snapshot)
            publishGlossary()
            saveGlossary()
        }
    }

    /// 把已译的名称/系统术语并入术语表（缓存/人工译文也参与）。
    func learnTermsFromCorpus() {
        var snapshot = glossaryBox.snapshot()
        var changed = false
        for entry in corpus.all where entry.isTranslated {
            guard let translated = entry.translated else { continue }
            if learnTerm(entry: entry, translated: translated, into: &snapshot) { changed = true }
        }
        guard changed else { return }
        glossaryBox.update(snapshot)
        publishGlossary()
        saveGlossary()
        refreshStaleCount()
    }

    private func learnTermIfNeeded(raw: String) {
        guard let entry = corpus.entry(for: raw), let translated = entry.translated, !translated.isEmpty else { return }
        var snapshot = glossaryBox.snapshot()
        guard learnTerm(entry: entry, translated: translated, into: &snapshot) else { return }
        glossaryBox.update(snapshot)
        // 不在这里落盘：一次全文翻译可能学上千条，逐条写会把磁盘打满。
        glossaryDirty = true
    }

    private func learnTerm(entry: FullTextEntry, translated: String, into snapshot: inout Glossary) -> Bool {
        guard let kind = glossaryKind(for: entry) else { return false }
        let source = entry.raw
        guard source.count <= 24, translated.count <= 32 else { return false }
        guard !source.contains("%"), !translated.contains("%") else { return false }
        guard !source.contains("\n"), !translated.contains("\n") else { return false }
        let skeleton = Segmenter.splitSegments(raw: source, engineFamily: K.engineFamily)
        guard Segmenter.textSegmentCount(skeleton) == 1 else { return false }
        guard translated != source else { return false }
        // 纯 ASCII 不学：这类词要么已在种子表 keepAsIs，要么是标识符。
        guard source.unicodeScalars.contains(where: { !$0.isASCII }) else { return false }
        let banned = CharacterSet(charactersIn: "。！？!?…「」『』（）()")
        guard translated.rangeOfCharacter(from: banned) == nil else { return false }
        return snapshot.learn(source: source, target: translated, kind: kind)
    }

    private func glossaryKind(for entry: FullTextEntry) -> GlossaryKind? {
        switch entry.category {
        case .systemTerm: return .system
        case .place: return .place
        case .entityName:
            return (entry.source == "actor" || entry.source == "class") ? .actor : .asset
        case .description, .dialogue, .other: return nil
        }
    }

    private func isASCIIIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private func publishGlossary() {
        glossaryRows = glossary.all
    }

    private func saveGlossaryIfDirty() {
        guard glossaryDirty else { return }
        publishGlossary()
        saveGlossary()
    }

    private func saveGlossary() {
        glossaryDirty = false
        guard let store = glossaryStore else { return }
        // 只持久化「用户编辑」与「从本局学到的资产/地名」：
        // 内置种子与引擎系统术语每次启动都会重建，写进文件反而会在将来覆盖新种子。
        let persistable = glossary.all.filter { entry in
            entry.edited || entry.kind == .asset || entry.kind == .actor || entry.kind == .place
        }
        let file = GlossaryFile(
            gameHash: gameHash,
            srcLang: srcLang,
            tgtLang: tgtLang,
            entries: persistable,
            deletedSources: Array(deletedSources).sorted()
        )
        let logger = log
        Task.detached(priority: .utility) {
            do {
                try store.save(file)
            } catch {
                logger?.warn("FullTextController", "术语表保存失败", ["error": "\(error)"])
            }
        }
    }

    /// 用户改一条术语（UI）。`edited == true` 后自动学习不再覆盖它。
    func setTerm(source: String, target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !trimmed.isEmpty else { return }
        // 用户手动加回来：清掉墓碑，否则下次启动又被删掉。
        deletedSources.remove(GlossaryKey.normalize(source))
        var snapshot = glossaryBox.snapshot()
        snapshot.upsert(GlossaryEntry(
            source: source,
            target: trimmed,
            kind: .user,
            locked: true,
            keepAsIs: false,
            edited: true
        ))
        glossaryBox.update(snapshot)
        publishGlossary()
        saveGlossary()
        refreshStaleCount()
        notice = "已更新术语：\(source)"
    }

    /// 清空删除墓碑并重新加载内置种子（用户编辑过的条目仍在磁盘文件里）。
    func resetGlossary() async {
        deletedSources.removeAll()
        saveGlossary()
        await loadGlossary()
        notice = "已恢复内置术语"
    }

    func deleteTerm(source: String) {
        var snapshot = glossaryBox.snapshot()
        snapshot.remove(source: source)
        deletedSources.insert(source)
        glossaryBox.update(snapshot)
        publishGlossary()
        saveGlossary()
        refreshStaleCount()
        notice = "已删除术语：\(source)"
    }

    @discardableResult
    func exportGlossary(to url: URL) async -> Bool {
        guard let store = glossaryStore else {
            lastError = ErrorInfo(code: .attachFailed, message: "尚未连接游戏")
            return false
        }
        let snapshot = glossary
        do {
            try await Task.detached(priority: .utility) {
                try store.export(snapshot, to: url)
            }.value
            notice = "已导出 \(snapshot.count) 条术语到 \(url.lastPathComponent)"
            return true
        } catch {
            lastError = ErrorInfo(code: .ioError, message: "导出术语失败：\(error)")
            return false
        }
    }

    @discardableResult
    func importGlossary(from url: URL) async -> Int? {
        guard let store = glossaryStore else {
            lastError = ErrorInfo(code: .attachFailed, message: "尚未连接游戏")
            return nil
        }
        let snapshot = glossary
        do {
            let (updated, count) = try await Task.detached(priority: .utility) { () -> (Glossary, Int) in
                var copy = snapshot
                let accepted = try store.importFile(from: url, into: &copy)
                return (copy, accepted)
            }.value
            for entry in updated.all {
                deletedSources.remove(GlossaryKey.normalize(entry.source))
            }
            glossaryBox.update(updated)
            publishGlossary()
            saveGlossary()
            refreshStaleCount()
            notice = "已导入 \(count) 条术语"
            return count
        } catch let error as MochiBoxError {
            lastError = error.asErrorInfo
            return nil
        } catch {
            lastError = ErrorInfo(code: .ioError, message: "导入术语失败：\(error)")
            return nil
        }
    }

    /// 缓存 profile：类别 + **本条文本命中的术语**。
    ///
    /// 不用全表指纹：用户改一个词就让 10k 条全部换键，重翻成本会失控。
    /// 只把「本条真的用到」的术语算进去，改哪个词只影响包含它的句子。
    private func profileId(for category: TranslationCategory, pairs: [GlossaryPair]) -> String {
        return TranslationProfile.id(category: category, pairs: pairs)
    }

    private func needsRetranslation(_ entry: FullTextEntry) -> Bool {
        guard entry.isTranslated, entry.origin != .manual else { return false }
        let skeleton = Segmenter.splitSegments(raw: entry.raw, engineFamily: K.engineFamily)
        let text = Segmenter.joinForBackend(skeleton)
        let pairs = glossary.pairs(in: [text], includeSingleChar: entry.category.allowsSingleCharTerms)
        let current = profileId(for: entry.category, pairs: pairs)
        if entry.profile == current { return false }
        // 升级前数据（profile 为空）：只在与术语相关时判过期，避免一次全量重翻。
        if entry.profile.isEmpty {
            return !glossary.terms(in: text).isEmpty
        }
        return true
    }

    private func refreshStaleCount() {
        var stale = 0
        var quality = 0
        for entry in corpus.all {
            if !entry.issues.isEmpty { quality += 1 }
            if needsRetranslation(entry) { stale += 1 }
        }
        staleCount = stale
        qualityCount = quality
    }

    /// 「按新术语重翻」：只清机翻/缓存，**人工译文一条不动**。
    @discardableResult
    func retranslateStale() async -> Bool {
        guard !phase.isRunning else { return false }
        await loadGlossaryIfNeeded()
        learnTermsFromCorpus()
        var removed = 0
        for entry in corpus.all where entry.isTranslated && entry.origin != .manual && needsRetranslation(entry) {
            corpus.resetTranslation(raw: entry.raw)
            removed += 1
        }
        guard removed > 0 else {
            notice = "没有需要按新术语重翻的条目"
            refreshStaleCount()
            return false
        }
        translated = corpus.translatedCount
        cachedCount = 0
        failedCount = 0
        failedRaws.removeAll()
        skippedRaws.removeAll()
        failures.removeAll()
        inFlight.removeAll()
        outstanding.removeAll()
        lastPushedCount = -1
        refreshCounts()
        publishRows()
        refreshStaleCount()
        notice = "已清空 \(removed) 条机翻，开始按新术语重翻"
        await translate()
        return true
    }

    // MARK: - 持久化

    /// 读本游戏的译文文件并并入语料（启动会话时调用一次）。
    @discardableResult
    func loadPersisted() async -> Bool {
        // 术语表独立加载：没有全文文件也要有（运行期 HP/MP 短路依赖它）。
        await loadGlossaryIfNeeded()
        guard let store = store else { return false }
        let file = await Task.detached(priority: .utility) { store.load() }.value
        guard let file = file, !file.entries.isEmpty else {
            refreshCounts()
            publishRows()
            return false
        }
        corpus.mergePersisted(
            entries: file.entries,
            segments: file.segments,
            origins: file.origins,
            profiles: file.profiles,
            issues: file.issues
        )
        // 旧版本在熔断期把"原文"当译文写进过语料（translated == raw、origin=machine/cache）。
        // 这些条目必须回到未译：否则页面收到的"译文"仍然是日文，而且缓存里一条都没有，
        // 用户重跑全文翻译也会因为"已译"被跳过，永远修不好。
        let purged = corpus.purgePassthroughMachineTranslations()
        if purged > 0 {
            purgeNotice = "清理了 \(purged) 条与原文相同的假译文"
            notice = purgeNotice
            needsClearBeforePush = true
            log?.warn("FullTextController", "清理了 \(purged) 条与原文相同的假译文", [
                "entries": "\(file.entries.count)",
                "remaining": "\(corpus.translatedCount)"
            ])
            // 立刻落盘：否则下一次启动又从旧文件里读回来（复活）。
            await saveNow()
        }
        // 恢复类别索引：不重扫也要让实时链路用和全文相同的 profile。
        // 按 raw 的 UTF-8 字节序回填：「先到者赢」，避免字典遍历序随机导致
        // 归一后撞 key 的两条（HP/hp）类别时对时错。
        let categoryRows = (file.categories ?? [:]).sorted {
            $0.key.utf8.lexicographicallyPrecedes($1.key.utf8)
        }
        for (raw, rawCategory) in categoryRows {
            let skeleton = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
            let key = GlossaryKey.normalize(Segmenter.joinForBackend(skeleton))
            guard !key.isEmpty, categoryByTextKey[key] == nil else { continue }
            categoryByTextKey[key] = TranslationCategory(rawValue: rawCategory) ?? .other
        }
        translated = 0
        cachedCount = 0
        for entry in corpus.all where entry.isTranslated {
            translated += 1
            cachedCount += 1
        }
        refreshCounts()
        publishRows()
        log?.info("FullTextController", "已加载全文译文", [
            "entries": "\(file.entries.count)",
            "gameHash": gameHash
        ])
        return true
    }

    /// 立即落盘。
    ///
    /// 没有译文且文件还不存在时**不写**：否则每开一次会话都会给每个游戏留一个空文件。
    func saveNow() async {
        guard let store = store else { return }
        let file = makeFile(payload: store.gameHash)
        if file.entries.isEmpty && !FileIO.exists(store.url) { return }
        saveGlossaryIfDirty()
        do {
            try await Task.detached(priority: .utility) { try store.save(file) }.value
        } catch let error as MochiBoxError {
            lastError = error.asErrorInfo
        } catch {
            lastError = ErrorInfo(code: .ioError, message: "保存全文译文失败：\(error)")
        }
    }

    /// 只给"可能跨越一次 attach"的调用方用（翻译任务的收尾与批间落盘）：
    /// 代次变了就**什么都不写** —— 此刻的 `store` 已经不是发起这一轮时那款游戏的了。
    private func saveNow(ifEpoch epoch: Int) async {
        guard epoch == attachEpoch else { return }
        await saveNow()
    }

    private func makeFile(payload gameHash: String) -> FullTextFile {
        var entries: [String: String] = [:]
        var segments: [String: [Segment]] = [:]
        var origins: [String: String] = [:]
        var profiles: [String: String] = [:]
        var issues: [String: [String]] = [:]
        var categories: [String: String] = [:]
        for entry in corpus.all {
            guard let translated = entry.translated, !translated.isEmpty else { continue }
            entries[entry.raw] = translated
            origins[entry.raw] = entry.origin.rawValue
            if !entry.profile.isEmpty { profiles[entry.raw] = entry.profile }
            if !entry.issues.isEmpty { issues[entry.raw] = entry.issues }
            categories[entry.raw] = entry.category.rawValue
            if let segs = entry.segments { segments[entry.raw] = segs }
        }
        return FullTextFile(
            gameHash: gameHash,
            engine: K.engineFamily,
            srcLang: srcLang,
            tgtLang: tgtLang,
            entries: entries,
            segments: segments.isEmpty ? nil : segments,
            origins: origins.isEmpty ? nil : origins,
            profiles: profiles.isEmpty ? nil : profiles,
            issues: issues.isEmpty ? nil : issues,
            categories: categories.isEmpty ? nil : categories,
            meta: [
                "translated": .number(Double(entries.count)),
                "corpus": .number(Double(corpus.count)),
                "backend": .string("mvmz")
            ]
        )
    }

    // MARK: - 导入 / 导出

    /// 导出前的公共前置：两个导出入口的「空译文」提示文案与错误码逐字相同。
    ///
    /// - Returns: 非空字典；为空时已写好 `lastError`，调用方直接 `return false`。
    private func exportDictionary() -> [String: String]? {
        let dictionary = FullTextStore.manualDictionary(from: corpus.all)
        guard !dictionary.isEmpty else {
            lastError = ErrorInfo(code: .ioError, message: "还没有译文可导出")
            return nil
        }
        return dictionary
    }

    /// `runIO` 的结果。不用 `Result`：`ErrorInfo` 不是 `Error`（是给 UI 看的纯数据）。
    private enum IOResult<T> {
        case success(T)
        case failure(ErrorInfo)
    }

    /// detached 写盘 + 双 catch 归一化。
    ///
    /// 只包住导出路径真正同构的那一段：`MochiBoxError` 原样保留（`asErrorInfo` 带上它
    /// 自己的 code / 可重试标记），其余错误统一归一成 `.ioError` + `<label>：\(error)`。
    /// `label` 由调用方显式传入，不设默认值 —— 文案是调用方的契约，不是本方法的。
    private func runIO<T: Sendable>(
        _ label: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async -> IOResult<T> {
        do {
            let value = try await Task.detached(priority: .utility) { try await body() }.value
            return .success(value)
        } catch let error as MochiBoxError {
            return .failure(error.asErrorInfo)
        } catch {
            return .failure(ErrorInfo(code: .ioError, message: "\(label)：\(error)"))
        }
    }

    /// 导出到用户选择的路径（`{原文:译文}`，MTool 兼容）。
    @discardableResult
    func exportManual(to url: URL) async -> Bool {
        guard let store = store else { return false }
        guard let dictionary = exportDictionary() else { return false }
        switch await runIO("导出失败", { try store.exportManual(dictionary, to: url) }) {
        case .success:
            notice = "已导出 \(dictionary.count) 条到 \(url.lastPathComponent)"
            return true
        case .failure(let info):
            lastError = info
            return false
        }
    }

    /// 导出到游戏目录（`<game>/ManualTransFile.json`，显式动作，§4.4）。
    @discardableResult
    func exportToGameDirectory(_ gameRoot: URL) async -> Bool {
        guard let store = store else { return false }
        guard let dictionary = exportDictionary() else { return false }
        switch await runIO("导出失败", { try store.exportToGameDirectory(dictionary, gameRoot: gameRoot) }) {
        case .success(let target):
            notice = "已写出 \(target.path)"
            return true
        case .failure(let info):
            lastError = info
            return false
        }
    }

    /// 导入 MTool 格式的人工译文（`{原文:译文}`；`原文 == 译文` 视为未译）。
    ///
    /// 合并策略（§4.5）：**导入优先于机翻**，`FullTextCorpus.applyTranslation` 里
    /// `.manual` 不会被机翻覆盖。冲突数（覆盖了已有译文几条）回传给 UI。
    @discardableResult
    func importManual(from url: URL) async -> ManualImportResult? {
        guard let store = store else { return nil }
        let existing = FullTextStore.manualDictionary(from: corpus.all)
        do {
            let output = try await Task.detached(priority: .utility) {
                try store.importManual(from: url, existing: existing)
            }.value
            for (raw, value) in output.entries {
                if corpus.entry(for: raw) == nil {
                    corpus.insert(raw: raw, source: "manual", path: "")
                }
                let rawSegments = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
                let translatedSegments = Segmenter.splitSegments(raw: value, engineFamily: K.engineFamily)
                let usable = Segmenter.textSegmentCount(rawSegments) == Segmenter.textSegmentCount(translatedSegments)
                    ? translatedSegments
                    : nil
                let wasTranslated = corpus.entry(for: raw)?.isTranslated ?? false
                corpus.applyTranslation(raw: raw, translated: value, segments: usable, origin: .manual)
                if !wasTranslated { translated += 1 }
                cursor = min(cursor, corpus.order.count)
            }
            refreshCounts()
            publishRows()
            await saveNow()
            await pushAll(force: true)
            notice = output.result.summary
            return output.result
        } catch let error as MochiBoxError {
            lastError = error.asErrorInfo
            return nil
        } catch {
            lastError = ErrorInfo(code: .ioError, message: "导入失败：\(error)")
            return nil
        }
    }

    /// 清空语料与落盘文件（UI 的"删除译文数据"）。
    func clearAll() async {
        cancel()
        resetGameScopedState()
        await saveNow()
    }

    // MARK: - 统计

    private func refreshCounts() {
        discovered = corpus.count
        failedCount = failedRaws.count
        progress = FullTextProgress(
            phase: phase,
            discovered: discovered,
            translated: translated,
            cached: cachedCount,
            failed: failedCount,
            scanSkipped: scanSkipped,
            pending: pendingTarget
        )
    }

    private func publishRows() {
        rows = corpus.all
        lastPublishedTranslated = translated
    }

    /// 每 200 条刷一次镜像（扫描/翻译都可能长时间跑）。
    private func publishRowsIfNeeded() {
        if translated - lastPublishedTranslated >= 200 {
            publishRows()
        }
    }

    // MARK: - 只读快照（UI 表格用）

    var corpusCount: Int { return corpus.count }
}
