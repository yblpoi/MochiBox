//
//  SessionController.swift
//  MochiBox
//
//  会话状态机 + Agent 消息分发 + 译文下发；以及 UI 唯一入口 AppState。
//  状态机：idle → launching → attaching → attached → translating → stopped / failed
//  依据 docs/prd.md §A.2、P0-06/07/14/15/16；docs/architecture.md §3.5、§3.7。
//

import Foundation
import Combine

/// 线程安全的设置盒：让 `TranslationPipeline` 的两个闭包**每批读到最新值**，
/// 从而「设置保存后立即生效无需重启」且**不需要重建 pipeline**（P0-12 / AC2.2c）。
///
/// 只有设置签名（后端 / endpoint / 模型 / 凭据）变化时才重建 provider；
/// 其余字段直接透传给管线，因此 `batchWindowMs` / `maxBatch` / `maxConcurrent` 也是即时生效的。
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settingsValue: Settings
    private var credentialsValue: Credentials
    private var cachedProvider: TranslatorProvider?
    private var cachedSignature: String = ""

    init(settings: Settings, credentials: Credentials) {
        self.settingsValue = settings
        self.credentialsValue = credentials
    }

    var settings: Settings {
        lock.lock()
        defer { lock.unlock() }
        return settingsValue
    }

    var credentials: Credentials {
        lock.lock()
        defer { lock.unlock() }
        return credentialsValue
    }

    func update(settings: Settings, credentials: Credentials) {
        lock.lock()
        settingsValue = settings
        credentialsValue = credentials
        let signature = SettingsBox.signature(settings: settings, credentials: credentials)
        if signature != cachedSignature {
            cachedProvider = nil
            cachedSignature = ""
        }
        lock.unlock()
    }

    /// 每批出队时调用一次。后端切换在这里立即体现（无需重启 App）。
    func provider() -> TranslatorProvider {
        lock.lock()
        defer { lock.unlock() }
        let signature = SettingsBox.signature(settings: settingsValue, credentials: credentialsValue)
        if let cached = cachedProvider, signature == cachedSignature {
            return cached
        }
        let made = TranslationProviderFactory.make(settings: settingsValue, credentials: credentialsValue)
        cachedProvider = made
        cachedSignature = signature
        return made
    }

    private static func signature(settings: Settings, credentials: Credentials) -> String {
        return [
            settings.effectiveBackend.rawValue,
            settings.endpoint,
            settings.model,
            // max_tokens 是 provider 的构造参数，不进签名的话改完要重启才生效。
            String(settings.maxOutputTokens),
            settings.reasoningOffMode,
            String(settings.timeoutSec),
            credentials.apiKey,
            credentials.deeplApiKey
        ].joined(separator: "|")
    }
}

@MainActor
final class SessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case launching
        case attaching
        case attached
        case translating
        case stopped
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var stateLabel: String = "未连接"
    @Published private(set) var attachInfo: AttachInfo?
    @Published private(set) var lastError: ErrorInfo?
    @Published private(set) var backendStatus: BackendStatus = .ok
    @Published private(set) var translatedCount: Int = 0
    @Published private(set) var port: Int = 0
    @Published private(set) var pageURL: String = ""
    /// 会话级语言探测：前 100 行几乎不含假名时置真，主窗口据此提示“这游戏本来就是中文”。
    ///
    /// 只置一次（用户关掉后不再骚扰）；start() / stop() 清零。
    @Published var chineseSuspected: Bool = false

    /// 当前会话占用的游戏 id（库列表用它显示「已启动」）。
    ///
    /// `idle` / `stopped` / `failed` 一律 nil：僵尸会话不应让列表一直挂着"已启动"。
    var runningGameId: String? {
        switch state {
        case .launching, .attaching, .attached, .translating:
            return currentEntry?.id
        case .idle, .stopped, .failed:
            return nil
        }
    }

    let stream: TextStreamStore
    /// V0.6 修改器（§3）。UI 直接读它的 `@Published`，写操作也由它转发 RPC。
    let cheat: CheatController
    /// V0.6 全文翻译（§4）。
    let fullText: FullTextController
    /// 术语表快照：全文与实时共用（运行期 HP/MP 也要短路）。
    private let glossaryBox = GlossaryBox()

    private let cache: TranslationCache
    private let paths: AppPaths
    private let log: SessionLog
    /// 管线闭包读的就是这份（见 `makePipeline`）。**不是 private**：自检要断言
    /// `setTranslationEnabled` 把开关同步到了管线侧（实时链路读上面的 `settings`，
    /// 全文翻译走 `TranslationPipeline.resolve` → `settings().agentEnabled`）。
    let settingsBox: SettingsBox
    private var settings: Settings
    private var adapter: MVAdapter?
    private var pipeline: TranslationPipeline?
    private var currentEntry: GameEntry?
    private var sessionId: String = ""
    private var sessionToken: String = ""
    /// V0.6 RPC 通道（会话级：随 attach 建立、随 stop 关闭）。
    private var rpc: AgentRPC?
    /// `cacheKey → (translatedSegments, backend)`：本会话已下发过的译文，重复绘制直接复用。
    ///
    /// **不存 `raw`**：同一 `cacheKey` 的每行 `raw` 不同（控制码差异），存首行整串会被
    /// 后续行复用成"别人的码值"（BUG-11 的 Host 侧同型点）。这里只留译文段，
    /// 由 `TextStreamStore.applyTranslation` 按**目标行自己的骨架**重组。
    private var delivered: [String: (segments: [Segment], backend: BackendKind)] = [:]
    /// `cacheKey → mapKey`：页面侧译文映射键，只用于下发（§6.2.1 第 3 条）。
    private var mapKeyByCacheKey: [String: String] = [:]
    /// 已送进管线、尚未拿到结果的**翻译身份**（`cacheKey`）。
    ///
    /// 批次整体失败时（401 / 429 / 超时 / 熔断）`PipelineBatchResult.items` 是空的，
    /// 光看结果不知道"哪几句挂了" —— 没有这份登记，那些行会永远停在 `pending`，
    /// 用户看到的是"一行都不动"，与"后端很慢"无法区分。
    private var inFlightCacheKeys: Set<String> = []

    /// `stop()` 幂等闸。
    ///
    /// 两条路径会同时喊停：用户点「停止」（UI → `stop()`）与用户点红叉关掉内置窗口
    /// （pump → `.stopped` → `Task { stop() }`）。没有它就会重复 uninstall / terminate，
    /// 状态机把 `.stopping` 打两遍，日志里看起来像"停了两次"。
    private var stopRequested = false

    /// 语言探测计数：收到的文本行总数与含假名的行数（每行只计一次）。
    private var totalTextRows: Int = 0
    private var kanaTextRows: Int = 0
    /// 判定阈值：满 100 行才看比例，避免开局几行标签就误报。
    private let chineseProbeRowThreshold: Int = 100
    private let chineseProbeKanaRatio: Double = 0.02
    /// “本会话已提示过”的闩。用户点掉提示后 chineseSuspected 会变 false，
    /// 但比例仍然低 —— 没有这个闩，下一行文本就会把提示再弹出来。
    private var chineseProbeFired: Bool = false

    /// 信封协议不匹配的丢弃计数。
    ///
    /// 每条消息打一行 warn 会把日志淹掉（一次会话上万行），真正的原因反而要翻到最前面
    /// 才看得见。首次丢弃立刻打，之后每 200 条补一行"仍在丢弃"。
    private var protocolMismatchDropped: Int = 0
    /// 诊断信封（`start_message_*`）的分级与节流。策略本体在 `AgentDiagGate`（Infra 层），
    /// 这里只保留实例：状态必须跨消息保留，且随 `start()` 归零。
    private var diagGate = AgentDiagGate()

    /// 下发时找不到 `mapKey` 的累计次数（全文结果每条都可能命中）。
    ///
    /// 逐条 warn 会把 8000 行日志塞满，真错误（401 / 解析失败）反而要翻到最前面才看得见；
    /// 这里只记数，每 200 条补一行 warn 汇总。**下发行为不变**（仍然跳过这一条）。
    private var mapKeyMissing: Int = 0

    init(
        stream: TextStreamStore,
        cache: TranslationCache,
        log: SessionLog,
        settings: Settings,
        paths: AppPaths = AppPaths.shared,
        credentialsProvider: @escaping @Sendable () -> Credentials
    ) {
        self.stream = stream
        self.cache = cache
        self.log = log
        self.settings = settings
        self.paths = paths
        self.settingsBox = SettingsBox(settings: settings, credentials: credentialsProvider())
        self.cheat = CheatController(log: log)
        self.fullText = FullTextController(log: log, glossaryBox: glossaryBox)
    }

    // MARK: - 对外操作

    /// 保存设置：**只改内存值 + 落盘**（落盘由 `AppState` 做），**不重建 pipeline**。
    /// 后端 / 模型 / 凭据变化由 `SettingsBox.provider()` 在下一批自动体现（P0-12、AC2.2c）。
    func updateSettings(_ newSettings: Settings, credentials: Credentials? = nil) async {
        settings = newSettings
        settingsBox.update(settings: newSettings, credentials: credentials ?? settingsBox.credentials)
        stream.updateMaxRows(newSettings.maxTextRows)
        stream.setPaused(!newSettings.agentEnabled)
        guard adapter != nil else { return }
        try? await adapter?.send(.config(currentConfig()))
    }

    func start(_ entry: GameEntry) async {
        stopRequested = false
        protocolMismatchDropped = 0
        mapKeyMissing = 0
        diagGate.reset()
        switch state {
        case .idle, .stopped, .failed:
            break
        default:
            log.warn("SessionController", "会话已在进行中，忽略重复启动")
            return
        }
        guard entry.isLaunchable else {
            lastError = ErrorInfo(
                code: .launcherNoExecutable,
                message: "\(entry.engine.displayName) 本轮不支持启动（\(entry.supportLevel.uiLabel)）"
            )
            state = .failed
            stateLabel = "不支持"
            return
        }

        sessionToken = RandomHex.make(16)
        sessionId = UUID().uuidString
        currentEntry = entry
        translatedCount = 0
        resetChineseDetection()
        delivered.removeAll()
        mapKeyByCacheKey.removeAll()
        inFlightCacheKeys.removeAll()
        backendStatus = .ok
        lastError = nil
        stream.clear()
        stream.updateMaxRows(settings.maxTextRows)
        stream.setPaused(!settings.agentEnabled)

        state = .launching
        stateLabel = "启动中…"
        log.info("SessionController", "会话开始", [
            "game": entry.name,
            "engine": entry.engine.rawValue,
            "session": String(sessionId.prefix(8))
        ])

        await makePipeline()

        let adapter = MVAdapter(engine: entry.engine, log: log)
        self.adapter = adapter

        do {
            let handle = try await adapter.launch(entry, log: log)
            port = handle.port
            state = .attaching
            stateLabel = "连接中…"

            let info = try await adapter.attach(
                handle,
                sessionToken: sessionToken,
                config: currentConfig(),
                onAgentMessage: { [weak self] envelope in
                    Task { @MainActor in self?.handleEnvelope(envelope) }
                },
                onStateChange: { [weak self] adapterState in
                    Task { @MainActor in self?.handleAdapterState(adapterState) }
                }
            )
            attachInfo = info
            pageURL = info.pageURL
            state = .attached
            stateLabel = "已连接"
            await adapter.startTextPump()
            log.info("SessionController", "会话已连接", [
                "port": "\(handle.port)",
                "page": info.pageURL,
                "hooks": info.hooks.joined(separator: ",")
            ])
            // RPC 线程与全文译文都依赖"已 attach + pump 在跑"，必须放在这个点之后。
            await connectAgentFeatures(entry: entry)
        } catch let error as MochiBoxError {
            fail(error)
        } catch {
            fail(MochiBoxError(code: .attachFailed, underlying: "\(error)"))
        }
    }

    func stop() async {
        guard !stopRequested else { return }
        stopRequested = true
        guard state != .idle else { return }
        state = .stopped
        stateLabel = "停止中…"
        resetChineseDetection()
        // 顺序是刻意的：先让全文任务停手 + 落盘，再拆 RPC，最后 cancel 管线，
        // 之后才动适配器。`adapter.stop()` 之后页面就没了，但 `TranslationPipeline`
        // 的 worker 还可能在发网络请求 —— 不 cancel 就是"窗口关了还在后台烧 API"。
        await disconnectAgentFeatures()
        if let pipeline = pipeline {
            await pipeline.cancelAll()
        }
        pipeline = nil
        if let adapter = adapter {
            await adapter.stop()
        }
        adapter = nil
        await cache.flush()
        attachInfo = nil
        port = 0
        pageURL = ""
        state = .idle
        stateLabel = "未连接"
        log.info("SessionController", "会话已停止")
    }

    func reconnect() async {
        guard let entry = currentEntry else { return }
        await stop()
        await start(entry)
    }

    func setTranslationEnabled(_ enabled: Bool) async {
        settings.agentEnabled = enabled
        // 管线闭包读的是 `settingsBox.settings`，不是本地 `settings`：只改本地的话，
        // 实时链路（handleText 读本地）已经停了，但全文翻译走
        // `FullTextController → pipeline.resolve` 仍按 enabled=true 继续翻译并计费。
        // SettingsBox 的签名不含 agentEnabled，update 只透传、不会重建 provider。
        settingsBox.update(settings: settings, credentials: settingsBox.credentials)
        // 先取消在飞请求：只发 config 的话，管线里已经发出去的那几批回来仍会
        // cache.put + 推流，用户点了“关闭翻译”游戏里还会再跳一次译文。
        // cancelAll() 会自增 epoch，之后回来的结果被丢弃（见 TranslationPipeline）。
        await pipeline?.cancelAll()
        if enabled { chineseSuspected = false }
        stream.setPaused(!enabled)
        try? await adapter?.send(.config(currentConfig()))
    }

    func setFontScale(_ scale: Double) async {
        settings.fontScale = min(1.3, max(0.8, scale))
        try? await adapter?.send(.config(currentConfig()))
    }

    /// 游戏绘制字体族（空 = 自动）。只改内存 + 下发；落盘由 AppState 的读-改-写负责。
    func setGameFontFamily(_ family: String) async {
        settings.gameFontFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await adapter?.send(.config(currentConfig()))
    }

    /// 数据回写总开关。只改内存 + 下发；落盘同样由 AppState 的读-改-写负责。
    /// 重复下发同值不做本地去重：Agent 侧按"值变了才动作"处理，Host 少一条幂等判据。
    func setDataPatchEnabled(_ enabled: Bool) async {
        settings.dataPatchEnabled = enabled
        try? await adapter?.send(.config(currentConfig()))
    }

    /// 数据回写的名字类子开关（`name` / `nickname` / `Game_Actor._name`）。
    func setDataPatchNames(_ enabled: Bool) async {
        settings.dataPatchNames = enabled
        try? await adapter?.send(.config(currentConfig()))
    }

    /// 忽略缓存重译（P1-08 留位，P0 可直接复用为"重新翻译"）。
    ///
    /// 入参是**翻译身份**（`cacheKey`）：重译按它重查一次，结果由 `stream.applyTranslation`
    /// **扇出**刷新所有共享该键的行 —— 用户会同时看到 `350` 与 `\C[2]350` 一起更新，属预期。
    func retranslate(key: String) async {
        guard let pipeline = pipeline else { return }
        guard let row = stream.rows.last(where: { $0.key == key }) else { return }
        delivered.removeValue(forKey: key)
        await pipeline.submit([
            TranslationRequestItem(key: row.key, text: row.text, segments: row.segments)
        ], priority: .high)
    }

    // MARK: - 内部

    private func currentConfig() -> AgentConfig {
        return AgentConfig(
            enabled: settings.agentEnabled,
            fontScale: settings.fontScale,
            srcLang: settings.srcLang,
            tgtLang: settings.tgtLang,
            maxMapSize: K.maxAgentMapSize,
            gameFontFamily: settings.gameFontFamily,
            dataPatchEnabled: settings.dataPatchEnabled,
            dataPatchNames: settings.dataPatchNames
        )
    }

    /// 建一条新管线。**闭包捕获 `settingsBox`**（不是设置快照），
    /// 所以后端切换无需重建、也不需要重启 App。
    private func makePipeline() async {
        let box = settingsBox
        let snapshot = settings
        let newPipeline = TranslationPipeline(
            cache: cache,
            provider: { box.provider() },
            settings: { box.settings },
            policy: ResiliencePolicy(settings: snapshot),
            log: log
        )
        await newPipeline.onResult { [weak self] result in
            Task { @MainActor in self?.handleBatchResult(result) }
        }
        if let old = pipeline {
            await old.cancelAll()
        }
        pipeline = newPipeline
    }

    // MARK: - V0.6：RPC 与全文译文接线

    /// 会话连上后建立 RPC 通道，并把全文译文自动加载 + 下发（§4.4）。
    ///
    /// 顺序不能换：`AgentRPC` 的传输是 `adapter.send`，而 `send` 依赖 `agentInjector`
    /// 已经注入（`attach` 返回后才成立）；全文下发又依赖 pump 在跑（回包要有人收）。
    private func connectAgentFeatures(entry: GameEntry) async {
        let adapter = self.adapter
        let rpc = AgentRPC(transport: { command in
            guard let adapter = adapter else {
                throw MochiBoxError(code: .attachFailed, message: "适配器已释放")
            }
            try await adapter.send(command)
        }, log: log)
        self.rpc = rpc
        cheat.attach(rpc: rpc, engine: entry.engine, log: log)

        let hash = SessionController.gameHash(for: entry)
        let store = FullTextStore(paths: paths, gameHash: hash, log: log)
        let glossaryStore = GlossaryStore(paths: paths, gameHash: hash, log: log)
        guard let pipeline = pipeline else { return }

        // 全文模式的批大小按管线吞吐给：一次交给管线的条数不超过它一波能发出去的量。
        // 批太大（1 万条）会让 waitForBatch 的超时预算失真；太小则是旧版的 10 条一批。
        let batchSize = min(120, max(20, max(1, settings.maxBatch) * max(1, settings.maxConcurrent)))
        // 一波 = batchSize / (maxBatch × maxConcurrent) 次往返，每次最坏吃满 timeoutSec。
        let perWave = max(1, max(1, settings.maxBatch) * max(1, settings.maxConcurrent))
        let waves = Int(ceil(Double(batchSize) / Double(perWave)))
        let bulkTimeoutSec = Double(waves) * Double(max(1, settings.timeoutSec)) * 4 + 30

        fullText.attach(
            rpc: rpc,
            pipeline: pipeline,
            store: store,
            glossaryStore: glossaryStore,
            gameHash: hash,
            srcLang: settings.srcLang,
            tgtLang: settings.tgtLang,
            sendTranslations: { [weak self] items in
                await self?.sendFullTextTranslations(items)
            },
            sendClear: { [weak self] in
                await self?.sendFullTextClear()
            },
            log: log,
            bulkBatchSize: batchSize,
            bulkTimeoutSec: bulkTimeoutSec
        )
        await fullText.loadPersisted()
        await fullText.pushAll(force: true)
        log.info("SessionController", "V0.6 通道已接线", [
            "gameHash": hash,
            "cheat": entry.engine.rawValue,
            "fulltext": "\(fullText.corpusCount)"
        ])
    }

    /// 停止 / 重连：先落盘再拆通道（否则最后一批译文会丢）。
    private func disconnectAgentFeatures() async {
        await fullText.saveNow()
        fullText.detach()
        cheat.detach()
        if let rpc = rpc {
            await rpc.close()
        }
        rpc = nil
    }

    /// 抹掉页面内存里的译文（清理假译文后、重新下发前用）。
    ///
    /// Agent 侧 clear 会清空 translations / mapOrder，之后 pushAll 重发全部有效译文。
    private func sendFullTextClear() async {
        guard let adapter = adapter else { return }
        do {
            try await adapter.send(.clear)
            log.info("SessionController", "已清空页面译文映射（准备重发）")
        } catch {
            log.warn("SessionController", "清空页面译文失败", ["error": "\(error)"])
        }
    }

    /// 全文译文下发（§2.4：走现有 `setTranslations`，按 `K.setTranslationsChunk` 分片）。
    private func sendFullTextTranslations(_ items: [TranslationPushItem]) async {
        guard let adapter = adapter else { return }
        var index = 0
        while index < items.count {
            let end = min(index + K.setTranslationsChunk, items.count)
            let chunk = Array(items[index..<end])
            do {
                try await adapter.send(.setTranslations(chunk))
            } catch {
                log.warn("SessionController", "全文译文下发失败", ["index": "\(index)"])
                return
            }
            index = end
            // 让出主线程：10k 条 = 50 次 evaluate，攒在一起会把 UI 顶住。
            await Task.yield()
        }
    }

    /// `gameHash` = `sha256(webRoot 规范路径)` 前 16 hex（与浏览器 profile 同源）。
    ///
    /// 用 **webRoot** 而不是游戏根目录：MV 的 `www/` 与 MZ 的根目录是同一份数据的
    /// 不同布局，稳定派生才能保证"同一个游戏每次落到同一个译文文件"。
    static func gameHash(for entry: GameEntry) -> String {
        let root = URL(fileURLWithPath: entry.path, isDirectory: true)
        let webRoot = (try? GameLauncher.detectWebRoot(gameRoot: root, engine: entry.engine)) ?? root
        return WebPortAssignments.gameHash(for: webRoot)
    }

    /// 页面重载 / 重新注入后 Agent 会再发一次 `hello`（§9）：重放 config + 全文译文。
    private func replayAfterHello() {
        guard rpc != nil, state == .attached || state == .translating else { return }
        log.info("SessionController", "Agent 重新握手，重放配置与全文译文")
        Task { [weak self] in
            guard let self = self else { return }
            try? await self.adapter?.send(.config(self.currentConfig()))
            await self.fullText.pushAll(force: true)
        }
    }

    private func fail(_ error: MochiBoxError) {
        lastError = error.asErrorInfo
        state = .failed
        stateLabel = "连接失败"
        log.error("SessionController", "会话失败", ["code": error.code.rawValue, "message": error.message])
        Task { await adapter?.stop() }
    }

    private func handleAdapterState(_ adapterState: AdapterState) {
        switch adapterState {
        case .launching:
            state = .launching
            stateLabel = "启动中…"
        case .discovering, .handshaking, .attaching, .injecting, .awaitingHello:
            state = .attaching
            stateLabel = adapterState.uiLabel
        case .attached(let start):
            state = .attached
            stateLabel = "已连接"
            port = start.port
        case .failed(let info):
            lastError = info
            state = .failed
            stateLabel = "连接失败"
        case .stopping:
            stateLabel = "停止中…"
        case .stopped:
            // 窗口被用户关掉（矩阵 E12）也会走到这里。
            //
            // 关键：`.stopped` **不一定是**我们 `stop()` 发起的。用户点红叉时，
            // `MVAdapter` 已自行收掉内核窗口与静态服务，但 Host 侧的翻译管线、
            // 全文任务、缓存 flush 还没人做 —— 不补这一步，窗口关了进程还在后台
            // 发请求/占内存。所以 `stopRequested == false` 时补一次完整 `stop()`。
            if !stopRequested {
                // 不在这里改 `state`：`stop()` 自己会走 `.stopped → .idle`。
                // 先置 `.stopped` 反而会在 `stop()` 因 `state == .idle` 提前返回时
                // 把 UI 卡在「停止中…」（重复 `.stopped` 就会踩到）。
                Task { await self.stop() }
                return
            }
            state = .idle
            stateLabel = "未连接"
            attachInfo = nil
            port = 0
            pageURL = ""
        }
    }

    private func handleEnvelope(_ envelope: AgentEnvelope) {
        guard envelope.v == K.protocolVersion else {
            protocolMismatchDropped += 1
            // 首次立即报（带可执行指引），之后每 200 条补一行：这类故障的表现是
            // "文本流 0 句 + 作弊全超时"，日志被逐条 warn 淹掉时最难定位。
            if protocolMismatchDropped == 1 || protocolMismatchDropped % 200 == 0 {
                log.warn("SessionController", "Agent 信封协议版本不匹配，消息被丢弃（文本流与 RPC 都会失效）", [
                    "v": "\(envelope.v)",
                    "expected": "\(K.protocolVersion)",
                    "type": envelope.type,
                    "dropped": "\(protocolMismatchDropped)",
                    "hint": "页面里的 agent_mvmz.js 与宿主版本不一致：停止会话后重新启动即可重注入"
                ])
            }
            return
        }
        if !sessionToken.isEmpty, !envelope.sessionToken.isEmpty, envelope.sessionToken != sessionToken {
            log.warn("SessionController", "sessionToken 不匹配，丢弃消息", ["type": envelope.type])
            return
        }
        switch envelope.type {
        case "text":
            handleText(envelope)
        case "error":
            if let payload = try? envelope.payload.decoded(AgentErrorPayload.self) {
                // 分级与节流都在 AgentDiagGate 里（可被 qa 探针直接断言）：
                // start_message_* 是诊断 → info + 每 200 条补一行；其它 code 仍按"内部错误"warn。
                // 信封内容与 fields 一字不动，只改"写不写、写哪一级"。
                switch diagGate.consume(code: payload.code) {
                case let .emit(level, message):
                    var fields = [
                        "code": payload.code,
                        "message": String(payload.message.prefix(200))
                    ]
                    if level == .info { fields["occurrences"] = "\(diagGate.count)" }
                    log.emit(level, "SessionController", message, fields)
                case .drop:
                    break
                }
            }
        case "stats":
            break
        case "hello":
            // 首次 hello 在 `AgentInjector.injectAndHandshake` 里就被消费掉了；
            // 走到这里的是"页面刷新 / hook 被覆盖后重新注入"，此时必须重放状态（§9）。
            replayAfterHello()
        case "pong":
            break
        case "rpcResult":
            guard let payload = try? envelope.payload.decoded(AgentRPCResultPayload.self),
                  let rpc = rpc else { return }
            Task { await rpc.deliver(payload) }
        case "scanChunk":
            guard let payload = try? envelope.payload.decoded(ScanChunkPayload.self) else { return }
            fullText.handleScanChunk(payload)
        case "scanDone":
            guard let payload = try? envelope.payload.decoded(ScanDonePayload.self) else { return }
            fullText.handleScanDone(payload)
        default:
            log.debug("SessionController", "未知 Agent 消息类型", ["type": envelope.type])
        }
    }

    private func handleText(_ envelope: AgentEnvelope) {
        guard let payload = try? envelope.payload.decoded(AgentTextPayload.self) else { return }
        if state == .attached {
            state = .translating
            stateLabel = "翻译中"
        }

        // 两级 key（§6.2.1）：Agent 上报的 payload.key 是页面侧 mapKey。
        // 这里**一律丢弃并按 Agent 上报的 segments 重算** cacheKey，绝不拿 mapKey 当缓存键。
        let mapKey = Segmenter.mapKey(payload.segments)
        // 与全文链路共用同一套 profile：否则全文预译过的句子在这里必然 miss、再花一次钱。
        let joined = Segmenter.joinForBackend(payload.segments)
        recordTextLanguage(joined)
        // 用全文扫描时判定的类别，保证两条链路对同一句算出同一个 profile。
        let category = fullText.category(forText: joined) ?? .dialogue
        let allowSingle = category.allowsSingleCharTerms
        let hints = glossaryBox.snapshot().pairs(in: [joined], includeSingleChar: allowSingle)
        let profile = TranslationProfile.id(category: category, pairs: hints)
        let cacheKey = Segmenter.cacheKey(
            engineFamily: K.engineFamily,
            srcLang: settings.srcLang,
            tgtLang: settings.tgtLang,
            segments: payload.segments,
            profile: profile
        )
        mapKeyByCacheKey[cacheKey] = mapKey
        log.debug("SessionController", "文本事件", [
            "surface": payload.surface,
            "mapKey": String(mapKey.prefix(24)),
            "cacheKey": String(cacheKey.prefix(8))
        ])

        stream.ingest(payload, cacheKey: cacheKey, sessionId: sessionId, gameId: currentEntry?.id ?? "")

        // §7.8 规范顺序：normalizeForKey（在 SkipRules 内部）→ skipReason → 缓存 → 入队。
        // 命中 skip 即终止：不入队、不查缓存、不写缓存。
        //
        // 双端判定：Agent 也会在页面上判一次（P0-08 要求跳过句仍上报，见 `agent_mvmz.js`
        // 的 `collect`）。两边用的是同一套判据，**status 以 Host 为准**；
        // Agent 的结论只用来留痕，绝不因为"Agent 说跳过"就跳过（那等于把判据交给页面）。
        let hostReason = SkipRules.skipReason(
            for: mapKey,
            enabled: settings.agentEnabled,
            minLength: K.minTranslateLength
        )
        if let reason = hostReason {
            if let agentReason = payload.skipReason, !agentReason.isEmpty, agentReason != reason {
                log.debug("SessionController", "双端跳过理由不一致，按 Host 处理", [
                    "host": reason,
                    "agent": agentReason,
                    "mapKey": String(mapKey.prefix(24))
                ])
            }
            stream.applySkip(cacheKey: cacheKey, reason: reason)
            return
        }
        if let agentReason = payload.skipReason, !agentReason.isEmpty {
            log.warn("SessionController", "Agent 判为跳过但 Host 判为需翻译，按 Host 处理", [
                "agent": agentReason,
                "mapKey": String(mapKey.prefix(24))
            ])
        }

        if let cached = delivered[cacheKey] {
            stream.applyTranslation(
                cacheKey: cacheKey,
                translatedRaw: nil,
                segments: cached.segments,
                backend: cached.backend,
                latencyMs: 0,
                cached: true
            )
            return
        }

        Task { await self.resolve(payload, cacheKey: cacheKey, hints: hints, category: category) }
    }

    /// 统计收到的文本行，判“这游戏本来就是中文”。
    ///
    /// 只看假名比例：日文对白几乎每行都有假名，纯中文游戏为 0；2% 的余量留给
    /// 物品名里的「カ」这类零星日文。满 100 行才判，且整个会话只提示一次 ——
    /// 用户点掉后不再反复弹（chineseProbeFired 只在换会话时清）。
    private func recordTextLanguage(_ text: String) {
        guard !text.isEmpty else { return }
        totalTextRows += 1
        if SkipRules.containsKana(text) { kanaTextRows += 1 }
        guard !chineseProbeFired, totalTextRows >= chineseProbeRowThreshold else { return }
        let ratio = Double(kanaTextRows) / Double(totalTextRows)
        guard ratio < chineseProbeKanaRatio else { return }
        chineseProbeFired = true
        chineseSuspected = true
        log.info("SessionController", "检测到游戏文本已是中文", [
            "rows": "\(totalTextRows)",
            "kanaRows": "\(kanaTextRows)",
            "ratio": String(format: "%.4f", ratio)
        ])
    }

    private func resetChineseDetection() {
        totalTextRows = 0
        kanaTextRows = 0
        chineseProbeFired = false
        chineseSuspected = false
    }

    private func resolve(
        _ payload: AgentTextPayload,
        cacheKey: String,
        hints: [GlossaryPair],
        category: TranslationCategory
    ) async {
        guard let pipeline = pipeline else { return }
        // 术语整串命中：不请求模型。HP/MP 这类 keepAsIs 直接按原文显示，
        // 避免同一缩写在不同时刻被译成「生命值 / HP」两种样子。
        if Segmenter.textSegmentCount(payload.segments) == 1,
           let term = glossaryBox.snapshot().exact(payload.text) {
            if term.keepAsIs {
                stream.applySkip(cacheKey: cacheKey, reason: "glossary_keep")
                return
            }
            if let segments = try? Segmenter.translatedSegments(segments: payload.segments, translatedText: term.target),
               let raw = try? Segmenter.reassemble(segments: payload.segments, translatedText: term.target) {
                delivered[cacheKey] = (segments: segments, backend: settings.effectiveBackend)
                stream.applyTranslation(
                    cacheKey: cacheKey,
                    translatedRaw: raw,
                    segments: segments,
                    backend: settings.effectiveBackend,
                    latencyMs: 0,
                    cached: false
                )
                pushTranslation(cacheKey: cacheKey, raw: raw, segments: segments)
                return
            }
        }
        inFlightCacheKeys.insert(cacheKey)
        let items = [TranslationRequestItem(
            key: cacheKey,
            text: payload.text,
            segments: payload.segments,
            category: category,
            glossary: hints
        )]
        let outcomes = await pipeline.resolve(items)
        guard let outcome = outcomes.first else { return }
        switch outcome {
        case .hit(let result):
            guard let segments = try? Segmenter.translatedSegments(segments: payload.segments, translatedText: result.translatedText),
                  let raw = try? Segmenter.reassemble(segments: payload.segments, translatedText: result.translatedText) else {
                stream.applyError(cacheKey: cacheKey, error: ErrorInfo(code: .segmentMismatch))
                return
            }
            delivered[cacheKey] = (segments: segments, backend: settings.effectiveBackend)
            stream.applyTranslation(
                cacheKey: cacheKey,
                translatedRaw: raw,
                segments: segments,
                backend: settings.effectiveBackend,
                latencyMs: result.latencyMs,
                cached: true
            )
            pushTranslation(cacheKey: cacheKey, raw: raw, segments: segments)
        case .passthrough(let result):
            // 结果层 translatedText == text（PRD §5.4），但 TextEvent.translated 必须是 nil：
            // 否则译文列里出现的其实是日文原文，用户以为翻译成功了（"假译文"）。
            stream.applyTranslation(
                cacheKey: cacheKey,
                translatedRaw: nil,
                segments: nil,
                backend: .passthrough,
                latencyMs: 0,
                cached: false
            )
            _ = result
        case .pending:
            stream.markPending(cacheKey: cacheKey)
        case .skipped(let reason):
            // 管线侧也判了一次（双端判定）；走到这里说明判定发生在 fetch 之后，
            // 仍然按 §7.8 落 `.skipped`，绝不写缓存、绝不显示原文冒充译文。
            stream.applySkip(cacheKey: cacheKey, reason: reason)
        case .failed(let info):
            stream.applyError(cacheKey: cacheKey, error: info)
        }
    }

    private func handleBatchResult(_ result: PipelineBatchResult) {
        if let error = result.error {
            if error.code == .circuitOpen {
                // 会话头要能显示"约 N 秒后自动重试"，所以这里必须带上 until；
                // .degraded 只有文案、没有倒计时。
                backendStatus = .circuitOpen(until: Date().addingTimeInterval(K.circuitBreakerOpenSec))
            } else {
                backendStatus = .degraded(error)
            }
        } else {
            backendStatus = .ok
        }
        // 单条失败：只把对应行标错。这些 key 不在 `result.items` 里，
        // 若只依赖下面的 orphaned 分支（仅在 `error != nil` 时触发），它们会一直停在 pending。
        for (key, info) in result.itemErrors {
            inFlightCacheKeys.remove(key)
            guard mapKeyByCacheKey[key] != nil else { continue }
            stream.applyError(cacheKey: key, error: info)
        }
        let resolvedKeys = Set(result.items.map { $0.key })
        // 批次整体失败时 items 为空：把"已送出但没拿到结果"的行按**翻译身份**扇出成 `error`，
        // 否则用户看到"一行报错、其余永远转圈"（错误路径最容易被漏，因为测试常常只放一条样本）。
        if let error = result.error {
            let orphaned = inFlightCacheKeys.subtracting(resolvedKeys)
            for key in orphaned {
                stream.applyError(cacheKey: key, error: error)
            }
            inFlightCacheKeys.subtract(orphaned)
        }
        for item in result.items {
            inFlightCacheKeys.remove(item.key)
            // 全文链路的 cacheKey 天然不在实时映射里（它没有页面行）。旧实现要等到
            // pushTranslation 里才发现，于是每条都先 translatedCount += 1 虚增一次、
            // 再打一行"缺少 mapKey"。判断必须提到计数与下发之前。
            guard mapKeyByCacheKey[item.key] != nil else { continue }
            guard let segments = item.translatedSegments,
                  let raw = try? Segmenter.reassemble(segments: segments, translatedText: item.translatedText) else {
                // 段数不匹配等单条失败：同样要落 `.error`，不能静默跳过（否则该行永远 pending）。
                stream.applyError(cacheKey: item.key, error: result.error ?? ErrorInfo(code: .segmentMismatch))
                continue
            }
            delivered[item.key] = (segments: segments, backend: result.backend)
            stream.applyTranslation(
                cacheKey: item.key,
                translatedRaw: result.backend == .passthrough ? nil : raw,
                segments: result.backend == .passthrough ? nil : segments,
                backend: result.backend,
                latencyMs: item.latencyMs,
                cached: item.cached
            )
            translatedCount += 1
            pushTranslation(cacheKey: item.key, raw: raw, segments: segments)
        }
    }

    /// 下发译文。`TranslationPushItem.key` 必须是**页面侧 mapKey**，
    /// 否则 Agent 查不到自己的 Map（§6.2.1 第 3 条）。
    private func pushTranslation(cacheKey: String, raw: String, segments: [Segment]) {
        guard let adapter = adapter else { return }
        guard let mapKey = mapKeyByCacheKey[cacheKey] else {
            mapKeyMissing += 1
            log.debug("SessionController", "缺少 mapKey，跳过下发", [
                "cacheKey": String(cacheKey.prefix(8)),
                "missed": "\(mapKeyMissing)"
            ])
            if mapKeyMissing % 200 == 0 {
                // 每 200 条一行汇总：数量够大才值得 warn（多半是页面侧 Map 还没挂上），
                // 但真正要紧的是别把 401 / 解析失败挤到日志最前面。
                log.warn("SessionController", "缺少 mapKey 持续发生，下发被跳过", [
                    "missed": "\(mapKeyMissing)"
                ])
            }
            return
        }
        let pushItem = TranslationPushItem(key: mapKey, translatedRaw: raw, segments: segments)
        Task {
            try? await adapter.send(.setTranslation(pushItem))
        }
    }
}

// MARK: - 根状态

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var games: [GameEntry] = []
    @Published var settings: Settings
    @Published var credentials: Credentials
    @Published var selectedGameId: String?
    @Published var selectedRowId: String?
    @Published var showSettings: Bool = false
    @Published var showCompliance: Bool = false
    @Published var isBusy: Bool = false
    @Published var notice: String = ""
    @Published var fontScaleDraft: Double = 1.0
    @Published var showClearCacheConfirm: Bool = false
    @Published var probeInProgress: Bool = false
    @Published var probeResultText: String = ""
    @Published private(set) var cacheStats: CacheStats = CacheStats()
    /// 正在运行的会话所对应的游戏 id（`nil` = 没有运行中的会话）。
    ///
    /// 单独存一份而不是让视图直接读 `session.runningGameId`：`AppState` 只观察自己的
    /// `@Published`，`SessionController.state` 的变化不会自动让主窗口重绘 ——
    /// 那正是"游戏都跑起来了，库里还写着可启动"的原因。
    @Published private(set) var runningGameId: String?
    /// 会话级中文探测的 UI 镜像（SessionController 是真相，这里只负责触发重绘）。
    ///
    /// 主窗口只观察 AppState，SessionController 的 @Published 不会让 SwiftUI 重绘，
    /// 所以必须桥一层；用户点“仍要翻译”时直接置 false（随后启用翻译会让会话侧也清零）。
    @Published var chineseSuspected: Bool = false

    let stream: TextStreamStore
    let session: SessionController

    private let paths: AppPaths
    private let libraryStore: LibraryStore
    private let settingsStore: SettingsStore
    private let cache: TranslationCache
    private let log: SessionLog
    /// `session.state` → `runningGameId` 的桥。
    private var sessionStateCancellable: AnyCancellable?
    /// `session.chineseSuspected` → 本对象的桥（见属性注释）。
    private var chineseSuspectedCancellable: AnyCancellable?

    init(paths: AppPaths = AppPaths.shared) {
        self.paths = paths
        paths.ensureDirectories()

        let bootLog = SessionLog(directory: paths.logsDirectory, sessionId: RandomHex.make(8), minLevel: .info)
        self.log = bootLog
        self.libraryStore = LibraryStore(url: paths.libraryURL, log: bootLog)
        self.settingsStore = SettingsStore(
            settingsURL: paths.settingsURL,
            credentialsURL: paths.credentialsURL,
            log: bootLog
        )

        let loadedSettings = settingsStore.loadSettings()
        let loadedCredentials = settingsStore.loadCredentials()
        self.settings = loadedSettings
        self.credentials = loadedCredentials

        let cache = TranslationCache(
            url: paths.cacheShardURL(for: loadedSettings.languagePair),
            maxEntries: loadedSettings.maxCacheEntries,
            log: bootLog
        )
        self.cache = cache

        let stream = TextStreamStore(maxRows: loadedSettings.maxTextRows)
        self.stream = stream

        self.session = SessionController(
            stream: stream,
            cache: cache,
            log: bootLog,
            settings: loadedSettings,
            paths: paths,
            credentialsProvider: { return loadedCredentials }
        )

        self.games = libraryStore.load().games
        self.showCompliance = loadedSettings.complianceAckVersion < K.complianceVersion
        self.fontScaleDraft = loadedSettings.fontScale
        refreshMissingFlags()
        applyStoredComplianceState()

        Task { @MainActor in
            await cache.load()
            await refreshCacheStats()
        }

        // 会话状态 → 库列表的「已启动」。用 `$state` 而不是 `objectWillChange`：
        // 后者在每次 `translatedCount` 之类的心跳字段变化时也会发，主窗口会被
        // 每秒重绘很多次；`$state` 只在真正切换状态时发一次。
        // `receive(on:)` 把读取推到下一轮 run loop —— `@Published` 是 willSet，
        // 同步读到的还是旧 state（首次会永远是 nil）。
        sessionStateCancellable = session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.runningGameId = self.session.runningGameId
                }
            }

        chineseSuspectedCancellable = session.$chineseSuspected
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                if self.chineseSuspected != value { self.chineseSuspected = value }
            }
    }

    // MARK: 生命周期

    func onAppear() {
        if settings.complianceAckVersion < K.complianceVersion {
            showCompliance = true
        }
        Task { await refreshCacheStats() }
    }

    private func applyStoredComplianceState() {
        if settings.complianceAckVersion < K.complianceVersion {
            showCompliance = true
        }
    }

    private func refreshMissingFlags() {
        let manager = FileManager.default
        var changed = false
        for index in games.indices {
            let exists = manager.fileExists(atPath: games[index].path)
            if games[index].missing != !exists {
                games[index].missing = !exists
                changed = true
            }
        }
        if changed {
            try? libraryStore.save(LibraryFile(games: games))
        }
    }

    // MARK: 库操作

    @discardableResult
    func addGame(url: URL) async -> GameEntry? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        if games.contains(where: { $0.path == path }) {
            if let existing = games.first(where: { $0.path == path }) {
                selectedGameId = existing.id
                notice = "该游戏已在库中：\(existing.name)"
            }
            return nil
        }
        isBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> DetectionResult in
            return EngineDetector.detect(standardized)
        }.value
        isBusy = false

        let entry = EngineDetector.makeEntry(path: path, result: result)
        games.append(entry)
        selectedGameId = entry.id
        try? libraryStore.save(LibraryFile(games: games))
        notice = "已添加：\(entry.name)（\(entry.engine.displayName)）"
        log.info("AppState", "添加游戏", ["path": path, "engine": entry.engine.rawValue])
        return entry
    }

    func addGames(urls: [URL]) async {
        for url in urls {
            _ = await addGame(url: url)
        }
    }

    func removeGame(id: String) {
        games.removeAll { $0.id == id }
        if selectedGameId == id { selectedGameId = games.first?.id }
        try? libraryStore.save(LibraryFile(games: games))
    }

    func selectGame(id: String) {
        selectedGameId = id
    }

    var selectedGame: GameEntry? {
        guard let id = selectedGameId else { return nil }
        return games.first { $0.id == id }
    }

    // MARK: 会话

    func startSession() async {
        guard let entry = selectedGame else {
            notice = "请先选择一个游戏"
            return
        }
        if !settings.hasUsableBackend {
            notice = "未配置翻译后端，将使用直通模式（不产生网络请求）"
        }
        await session.start(entry)
        var updated = entry
        updated.launchCount += 1
        updated.lastLaunchedAt = Timestamp.nowMs()
        if let index = games.firstIndex(where: { $0.id == entry.id }) {
            games[index] = updated
            try? libraryStore.save(LibraryFile(games: games))
        }
    }

    func stopSession() async {
        await session.stop()
        await refreshCacheStats()
    }

    func reconnectSession() async {
        await session.reconnect()
    }

    func clearStream() {
        stream.clear()
    }

    // MARK: 设置

    func saveSettings() {
        let normalized = settings.normalized()
        settings = normalized.settings
        for warning in normalized.warnings {
            log.warn("AppState", warning)
        }
        if !settings.allowSendTextToBackend {
            settings.backendType = .passthrough
        }
        try? settingsStore.saveSettings(settings)
        try? settingsStore.saveCredentials(credentials)
        let snapshot = settings
        let credentialSnapshot = credentials
        Task { await session.updateSettings(snapshot, credentials: credentialSnapshot) }
        notice = "已保存设置"
    }

    /// 字号的**唯一写入口**：持久化设置 → 会话设置 → 一次 `.config`。
    ///
    /// 修复前两条 UI 路径各写一半：滑杆只改 `SessionController.settings`（不碰
    /// `AppState.settings`、不落盘），`⌘+`/`⌘-` 只改 `AppState.settings`（同样不落盘），
    /// 于是重启后字号回弹，两条路径混用时还会从各自记住的旧值起算。
    ///
    /// 相等即返回：滑杆"停止拖动"提交与快捷键后的 debounce 提交会撞在一起，
    /// 靠 `settings.fontScale` 的幂等判定保证每次实际变化只发一次 `.config`。
    func applyFontScale(_ scale: Double) {
        let clamped = min(1.3, max(0.8, scale))
        guard clamped != settings.fontScale else {
            if fontScaleDraft != clamped { fontScaleDraft = clamped }
            return
        }
        settings.fontScale = clamped
        fontScaleDraft = clamped
        // 只落 settings.json（与 `acknowledgeCompliance` 同一写法）：不走 `saveSettings()`，
        // 那条路径会重建会话设置并弹"已保存设置"，字号拖动不该产生这种副作用。
        //
        // 写盘是"读-改-写"：设置页的 `$app.settings.*` 是直接绑定，用户改了 endpoint/超时
        // 未点"保存设置"时，内存 settings 里有未确认的编辑。以磁盘版本为基底只回写
        // fontScale，这些编辑就不会被拖一下滑杆顺带提交。
        //
        // 磁盘缺失/损坏时 `loadSettingsFromDisk()` 返回 nil，此时退回内存 settings：
        // 否则会把默认值写回去，反而冲掉用户此前保存的设置。
        var persisted = settingsStore.loadSettingsFromDisk() ?? settings
        persisted.fontScale = clamped
        try? settingsStore.saveSettings(persisted)
        Task { await session.setFontScale(clamped) }
    }

    /// 翻译开关的**唯一写入口**：落盘 → 同步内存 → 通知会话。
    ///
    /// 修复前 MainWindow 的 Toggle 只改 app.settings + 会话内存，从不写 settings.json，
    /// 重启后又变回开启。落盘沿用 applyFontScale 的“读-改-写”：只回写 agentEnabled，
    /// 设置页里未点“保存设置”的其它编辑不会被顺带提交。
    func setTranslationEnabled(_ enabled: Bool) {
        var persisted = settingsStore.loadSettingsFromDisk() ?? settings
        persisted.agentEnabled = enabled
        try? settingsStore.saveSettings(persisted)
        settings.agentEnabled = enabled
        if enabled { chineseSuspected = false }
        Task { await session.setTranslationEnabled(enabled) }
    }

    /// 游戏字体族：选中即生效（不等“保存设置”），同样只回写这一个字段。
    func setGameFontFamily(_ family: String) {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != settings.gameFontFamily else { return }
        settings.gameFontFamily = trimmed
        var persisted = settingsStore.loadSettingsFromDisk() ?? settings
        persisted.gameFontFamily = trimmed
        try? settingsStore.saveSettings(persisted)
        Task { await session.setGameFontFamily(trimmed) }
    }

    /// 数据回写总开关：落盘 → 同步内存 → 通知会话（与字体族同一条读-改-写路径）。
    ///
    /// 只回写这一个字段：设置页里改了 endpoint / 超时但没点"保存设置"时，
    /// 拖开关不该把这些未确认的编辑顺带提交。
    func setDataPatchEnabled(_ enabled: Bool) {
        guard enabled != settings.dataPatchEnabled else { return }
        var persisted = settingsStore.loadSettingsFromDisk() ?? settings
        persisted.dataPatchEnabled = enabled
        try? settingsStore.saveSettings(persisted)
        settings.dataPatchEnabled = enabled
        Task { await session.setDataPatchEnabled(enabled) }
    }

    /// 名字类子开关（`name` / `nickname` / `Game_Actor._name`）。
    /// 总开关关掉时它仍可切换（UI 置灰只是提示），值原样保存，开着总开关时才生效。
    func setDataPatchNames(_ enabled: Bool) {
        guard enabled != settings.dataPatchNames else { return }
        var persisted = settingsStore.loadSettingsFromDisk() ?? settings
        persisted.dataPatchNames = enabled
        try? settingsStore.saveSettings(persisted)
        settings.dataPatchNames = enabled
        Task { await session.setDataPatchNames(enabled) }
    }

    func acknowledgeCompliance() {
        settings.complianceAckVersion = K.complianceVersion
        showCompliance = false
        try? settingsStore.saveSettings(settings)
        log.info("AppState", "用户已确认合规声明", ["version": "\(K.complianceVersion)"])
    }

    func clearCache() async {
        do {
            try await cache.clearAll()
            await refreshCacheStats()
            notice = "缓存已清空"
        } catch {
            notice = "清空缓存失败：\(error)"
        }
    }

    func refreshCacheStats() async {
        let stats = await cache.stats()
        cacheStats = stats
    }

    var logsDirectory: URL { return paths.logsDirectory }
}
