//
//  probe_crossgame.swift
//  MochiBox · E2E 领域层探针（D21：全文语料按游戏隔离 + 跨 attach 的旧任务）
//
//  回归的现场（真机日志 22:03–22:12）：
//   `FullTextController` 在 App 进程里只有一个实例（`SessionController.fullText`），
//   跨游戏复用。修复前 `attach()` 换游戏只改 store/rpc/gameHash/lastPushedCount，
//   不清语料；`detach()` 刻意保留语料；`loadPersisted()` 把新游戏的译文**合并**进旧语料；
//   `pushAll()` 推的是 `corpus.all`。于是第二款游戏收到 7468（A）+ 5328（B）- 178（同 key）
//   = 12618 条，其中 57.8% 是上一款游戏的译文；同一次 loadPersisted 里的 `saveNow()`
//   还会把 A 的条目写进 `fulltext/<B>.json`（`makeFile` 遍历整个 corpus）。
//
//  ② 之后还有一条**由修复本身引入**的风险：`translate()` 是 UI 起的非结构化 Task，
//  `stop()` 既不 await 也不持有句柄。换 store 之后旧任务若恢复，收尾那句无条件
//  `await saveNow()` 会拿**新** store 写旧队列 —— 只加 `corpus.clear()` 的话，
//  这一路会把刚清空、`loadPersisted()` 还没合并完的语料写成 0 条，直接把新游戏的
//  译文文件抹掉。⑥ 就是这个场景：用一支会挂住的 translator 把旧任务钉在批里，
//  在挂起期间 detach + attach 到另一款游戏，再放行。
//
//  这里不读真实用户的 fulltext 文件：所有文件都由探针在 --work 临时目录里现写，
//  条数用实测的值（7468 / 5328），保证可重复。
//
//  依据：Sources/Domain/FullTextController.swift（attach / detach / translate / pushAll /
//        saveNow）；Sources/Domain/SessionController.swift:306（stop）→ :472
//        （disconnectAgentFeatures 里先 saveNow 再 detach，这是"换游戏清内存不丢数据"的依据）。
//

import Foundation
import CryptoKit

@main
struct DomainCrossGameProbe {
    static func main() async {
        let args = ProbeArgs()
        switch args.only {
        case "D21": await d21(args)
        default: TAP.ok("probe", "未知 --only 参数", false, "only=\(args.only)")
        }
        exit(TAP.finish())
    }

    /// 下发记录：`pushAll` 的 send 闭包每批追加一次。
    @MainActor
    final class PushRecorder {
        private(set) var batches: [[TranslationPushItem]] = []

        var lastCount: Int { return batches.last?.count ?? -1 }

        var lastTranslated: [String] {
            return (batches.last ?? []).map { $0.translatedRaw }
        }

        func record(_ items: [TranslationPushItem]) {
            batches.append(items)
        }
    }

    /// 普通探针用：这三条用例一次真翻译请求都不发。
    struct StubTranslator: TranslatorProvider {
        var kind: BackendKind { return .passthrough }

        func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
            return []
        }
    }

    /// 挂在 `translate()` 的闸门：让一个翻译任务停在"批已发出、结果没回"的状态，
    /// 好在它挂着的这几百毫秒里做 detach + attach（= 用户停止后立刻换游戏）。
    @MainActor
    final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        var waiting: Int { return waiters.count }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    /// 永不返回的 translator：第一次调用就挂住，直到用例放行。
    ///
    /// `kind` 必须是真后端：管线见到 `effectiveBackend == .passthrough` 会**短路**，
    /// 一条请求都不发（也就永远挂不住）。
    struct BlockingTranslator: TranslatorProvider {
        let gate: Gate

        var kind: BackendKind { return .openai }

        func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
            await gate.wait()
            return []
        }
    }

    static func sha256(_ url: URL) -> String {
        guard let data = FileIO.readData(url) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 造一款游戏的译文表：原文 `<prefix>-0001`，译文 `<mark>0001`（互不相同的字符集，
    /// 便于断言"下发里有没有别作的条目"）。
    static func seed(prefix: String, mark: String, count: Int) -> [String: String] {
        var entries: [String: String] = [:]
        entries.reserveCapacity(count)
        for index in 1...count {
            let suffix = String(format: "%04d", index)
            entries["\(prefix)-\(suffix)"] = "\(mark)\(suffix)"
        }
        return entries
    }

    /// 用 Agent 的 wire 形状造一片扫描结果：探针里没有真 Agent，但语料只能从扫描进来
    /// （`loadPersisted` 只带"已译"条目，翻不出东西）。
    static func scanPayloads(count: Int) -> (ScanChunkPayload, ScanDonePayload)? {
        let items: [[String: Any]] = (1...count).map { index in
            ["raw": String(format: "C-%02dテスト発言", index), "source": "actor", "path": "actors.\(index).name"]
        }
        let chunkJSON: [String: Any] = ["scanId": "scan-crossgame", "seq": 1, "items": items]
        let doneJSON: [String: Any] = ["scanId": "scan-crossgame", "total": count, "skipped": 0, "cancelled": false]
        guard
            let chunkData = try? JSONSerialization.data(withJSONObject: chunkJSON),
            let doneData = try? JSONSerialization.data(withJSONObject: doneJSON),
            let chunk = try? JSONDecoder().decode(ScanChunkPayload.self, from: chunkData),
            let done = try? JSONDecoder().decode(ScanDonePayload.self, from: doneData)
        else { return nil }
        return (chunk, done)
    }

    @MainActor
    static func d21(_ args: ProbeArgs) async {
        let root = args.root
        let fulltextDir = root.appendingPathComponent("fulltext", isDirectory: true)
        let glossaryDir = root.appendingPathComponent("glossary", isDirectory: true)
        let cacheURL = root.appendingPathComponent("cache/translations.jsonl")

        // 四个 hash 都是 16 位十六进制（与 WebPortAssignments 的同款形态），互不相同即可。
        let hashA = "a1a1a1a1a1a1a1a1"
        let hashB = "b2b2b2b2b2b2b2b2"
        let hashC = "c3c3c3c3c3c3c3c3"
        let hashD = "d4d4d4d4d4d4d4d4"

        let storeA = FullTextStore(directory: fulltextDir, gameHash: hashA)
        let storeB = FullTextStore(directory: fulltextDir, gameHash: hashB)
        let entriesA = seed(prefix: "A", mark: "甲", count: 7468)
        let entriesB = seed(prefix: "B", mark: "乙", count: 5328)

        // 现场形态：同一个 fulltext 目录下两款游戏各一份文件。
        do {
            // A 里有一条**人工译文**：跨同游戏重连不许被机翻覆盖、更不许被 purge 掉。
            try storeA.save(FullTextFile(
                gameHash: hashA,
                entries: entriesA,
                origins: ["A-0001": FullTextOrigin.manual.rawValue]
            ))
            try storeB.save(FullTextFile(gameHash: hashB, entries: entriesB))
            // A 的术语表：一条自己的术语 + 一个删除墓碑（HP）。墓碑不隔离的话，
            // 换到 B 之后 HP 仍然是"被删掉"的，而且会被 saveGlossary() 写进 B 的文件。
            try GlossaryStore(directory: glossaryDir, gameHash: hashA).save(GlossaryFile(
                gameHash: hashA,
                entries: [GlossaryEntry(source: "A専用語", target: "A专用词", kind: .asset)],
                deletedSources: ["HP"]
            ))
        } catch {
            TAP.ok("D21", "赛前准备：两份译文文件 + A 的术语表写出", false, "\(error)")
            return
        }

        let controller = FullTextController(log: nil)
        let pipeline = TranslationPipeline(
            cache: TranslationCache(url: cacheURL),
            provider: { StubTranslator() },
            settings: { Settings() }
        )
        let rpc = AgentRPC(transport: { _ in })
        let recorder = PushRecorder()

        let send: @Sendable ([TranslationPushItem]) async -> Void = { items in
            await recorder.record(items)
        }

        // MARK: - ① A 首次会话

        controller.attach(
            rpc: rpc,
            pipeline: pipeline,
            store: storeA,
            glossaryStore: GlossaryStore(directory: glossaryDir, gameHash: hashA),
            gameHash: hashA,
            srcLang: K.fixedSrcLang,
            tgtLang: K.fixedTgtLang,
            sendTranslations: send
        )
        await controller.loadPersisted()
        TAP.eqInt("D21", "① A 载入后语料 = 7468", controller.corpusCount, 7468)
        TAP.ok("D21", "① A 的术语表已加载（属于 A 的条目可见）",
               controller.glossary.entry(for: "A専用語") != nil,
               controller.glossary.entry(for: "A専用語")?.target ?? "-")
        TAP.ok("D21", "① A 的删除墓碑生效（HP 已被用户删掉）",
               controller.glossary.entry(for: "HP") == nil,
               controller.glossary.entry(for: "HP")?.target ?? "-")

        await controller.pushAll(force: true)
        TAP.eqInt("D21", "① A 首次下发的 items = 7468", recorder.lastCount, 7468)

        // MARK: - ② 同一 gameHash 重连：语料必须保留并重放（detach 注释的原意）

        // 与 SessionController.disconnectAgentFeatures 同序：先落盘，再 detach。
        await controller.saveNow()
        controller.detach()
        controller.attach(
            rpc: rpc,
            pipeline: pipeline,
            store: storeA,
            glossaryStore: GlossaryStore(directory: glossaryDir, gameHash: hashA),
            gameHash: hashA,
            srcLang: K.fixedSrcLang,
            tgtLang: K.fixedTgtLang,
            sendTranslations: send
        )
        TAP.eqInt("D21", "② 同一游戏重连后语料仍在（7468 条没被清）", controller.corpusCount, 7468)
        await controller.loadPersisted()
        // 不带 force：attach 复位了 lastPushedCount，重连必须整体重放。
        await controller.pushAll()
        TAP.eqInt("D21", "② 同一游戏重连后 pushAll 重放 7468 条", recorder.lastCount, 7468)
        let manualRow = controller.rows.first { $0.raw == "A-0001" }
        TAP.ok("D21", "② 人工译文跨重连仍是 .manual（没被机翻/清理覆盖）",
               manualRow?.origin == .manual && manualRow?.translated == "甲0001",
               "\(manualRow?.origin.rawValue ?? "-") / \(manualRow?.translated ?? "-")")

        // MARK: - ③ 换游戏：attach 当场清场

        await controller.saveNow()
        let shaABeforeSwitch = sha256(storeA.url)
        controller.detach()
        controller.attach(
            rpc: rpc,
            pipeline: pipeline,
            store: storeB,
            glossaryStore: GlossaryStore(directory: glossaryDir, gameHash: hashB),
            gameHash: hashB,
            srcLang: K.fixedSrcLang,
            tgtLang: K.fixedTgtLang,
            sendTranslations: send
        )
        // 修复前这里是 7468：语料跟着进程走，attach 不清。
        TAP.eqInt("D21", "③ 换游戏后 attach 立刻清空上一款游戏的语料", controller.corpusCount, 0)
        TAP.eqInt("D21", "③ 换游戏后 translated 归零（不是 A 的 7468）", controller.translated, 0)
        TAP.eq("D21", "③ 当前 gameHash 已切到 B", controller.gameHash, hashB)

        await controller.loadPersisted()
        TAP.eqInt("D21", "③ B 载入后语料 = 5328（只有本作）", controller.corpusCount, 5328)
        await controller.pushAll(force: true)
        TAP.eqInt("D21", "③ B 下发的 items = 5328（修复前是两作之和）", recorder.lastCount, 5328)
        TAP.ok("D21", "③ 下发里没有一条是 A 的译文（不串流）",
               recorder.lastTranslated.allSatisfy { $0.hasPrefix("乙") },
               "混入 \(recorder.lastTranslated.filter { !$0.hasPrefix("乙") }.count) 条")

        // MARK: - ④ 写回 B 的文件不能带上 A 的条目；A 的文件不许被碰

        await controller.saveNow()
        let writtenB = storeB.load()
        TAP.eqInt("D21", "④ B 的 fulltext 文件写回后条目数 = 5328", writtenB?.entries.count ?? -1, 5328)
        let foreign = (writtenB?.entries.keys ?? [String: String]().keys).filter { $0.hasPrefix("A-") }
        TAP.ok("D21", "④ B 的 fulltext 文件不含 A 的条目（译文文件没被写脏）",
               foreign.isEmpty, "混入 \(foreign.count) 条，例：\(foreign.sorted().prefix(3).joined(separator: ","))")
        let writtenA = storeA.load()
        TAP.eqInt("D21", "④ A 的 fulltext 文件仍是 7468 条（换游戏没动上一作）",
                  writtenA?.entries.count ?? -1, 7468)
        TAP.eq("D21", "④ A 的译文文件字节 sha 与切换前一致", sha256(storeA.url), shaABeforeSwitch)

        // MARK: - ⑤ 术语表也按游戏隔离

        TAP.ok("D21", "⑤ 换到 B 后 A 的术语已失效（glossaryLoaded 已重置）",
               controller.glossary.entry(for: "A専用語") == nil,
               controller.glossary.entry(for: "A専用語")?.target ?? "-")
        TAP.ok("D21", "⑤ A 的删除墓碑没有跟到 B（HP 回到内置种子）",
               controller.glossary.entry(for: "HP")?.keepAsIs == true,
               controller.glossary.entry(for: "HP")?.target ?? "-")

        // MARK: - ⑥ 换 store 时还活着的旧翻译任务：不许写 B/D 的文件
        //
        // 序列与 SessionController 一致：翻译任务挂在批里 → stop()（saveNow + detach）
        // → 立刻 start(另一款游戏)（attach 换 store）。中间**没有**任何 await，
        // 模拟"旧任务正卡在批里、attach 恰好落地"这个最坏交错。

        await controller.saveNow()
        controller.detach()

        let storeC = FullTextStore(directory: fulltextDir, gameHash: hashC)
        let storeD = FullTextStore(directory: fulltextDir, gameHash: hashD)
        // D 是"本来就有译文的另一款游戏"：它的文件必须在整段里一字不动。
        try? storeD.save(FullTextFile(gameHash: hashD, entries: seed(prefix: "D", mark: "丁", count: 8)))
        let shaDBefore = sha256(storeD.url)

        let gate = Gate()
        // 必须是真后端：Settings 默认 passthrough，管线会直接短路成 .passthrough。
        var draftSettings = Settings()
        draftSettings.backendType = .openai
        draftSettings.endpoint = "http://127.0.0.1:9"
        let blockingSettings = draftSettings
        let blockingPipeline = TranslationPipeline(
            cache: TranslationCache(url: root.appendingPathComponent("cache/blocking.jsonl")),
            provider: { BlockingTranslator(gate: gate) },
            settings: { blockingSettings }
        )
        controller.attach(
            rpc: rpc,
            pipeline: blockingPipeline,
            store: storeC,
            glossaryStore: nil,
            gameHash: hashC,
            srcLang: K.fixedSrcLang,
            tgtLang: K.fixedTgtLang,
            sendTranslations: send
        )
        if let payloads = scanPayloads(count: 20) {
            controller.handleScanChunk(payloads.0)
            controller.handleScanDone(payloads.1)
        } else {
            TAP.ok("D21", "⑥ 扫描分片夹具可解码", false, "JSON 形状与 Agent 不一致")
        }
        TAP.eqInt("D21", "⑥ 扫描下来 20 条未译语料（C 会话）", controller.corpusCount, 20)

        let translationTask = Task { await controller.translate() }
        // 等它真的挂在批里（translator 已被调用、结果没回）。
        var waited = 0
        while gate.waiting == 0 && waited < 100 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        TAP.ok("D21", "⑥ 旧翻译任务已挂在批里（等待 0 次说明没起来）",
               gate.waiting > 0, "waiting=\(gate.waiting) phase=\(controller.phase.rawValue)")

        // stop()：先落盘（此时 store 还是 C）再 detach；紧接着 start(D) —— 两句之间不能有 await。
        await controller.saveNow()
        controller.detach()
        let pipelineD = TranslationPipeline(
            cache: TranslationCache(url: cacheURL),
            provider: { StubTranslator() },
            settings: { Settings() }
        )
        controller.attach(
            rpc: rpc,
            pipeline: pipelineD,
            store: storeD,
            glossaryStore: GlossaryStore(directory: glossaryDir, gameHash: hashD),
            gameHash: hashD,
            srcLang: K.fixedSrcLang,
            tgtLang: K.fixedTgtLang,
            sendTranslations: send
        )
        gate.open()
        await translationTask.value

        TAP.eq("D21", "⑥ 旧任务没把 D 的译文文件写空/写脏（字节 sha 不变）",
               sha256(storeD.url), shaDBefore)
        let writtenD = storeD.load()
        TAP.ok("D21", "⑥ D 的文件仍是 8 条、且没有 C 的条目",
               writtenD?.entries.count == 8 && (writtenD?.entries.keys.allSatisfy { $0.hasPrefix("D-") } ?? false),
               "entries=\(writtenD?.entries.count ?? -1)")

        await controller.loadPersisted()
        TAP.eqInt("D21", "⑥ 换到 D 后语料 = 8（C 的扫描语料没跟过来）", controller.corpusCount, 8)
        await controller.pushAll(force: true)
        TAP.eqInt("D21", "⑥ D 下发 8 条（旧任务的队列没被下发）", recorder.lastCount, 8)
    }
}
