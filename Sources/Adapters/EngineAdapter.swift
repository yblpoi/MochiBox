//
//  EngineAdapter.swift
//  MochiBox
//
//  引擎适配器协议、启动句柄、attach 信息、状态机与注册表；
//  以及本轮唯一实现 MVAdapter（MV/MZ 共用）。
//  依据 docs/architecture.md §3.5。
//

import Foundation

// MARK: - 基础类型

enum LaunchLayout: String, Sendable {
    case nwjsSubBundle      // <root>/nwjs.app/Contents/MacOS/nwjs
    case innerAppBundle     // <root>/<name>.app/Contents/MacOS/<exe>
    case outerAppBundle     // 输入本身是 .app
    /// v0.2：nwjs 布局一个都没命中，改走 Web 运行后端（静态 HTTP + Chromium 内核）。
    ///
    /// 与 `LaunchTransport` 语义重叠但**不合并**：`LaunchLayout` 进日志与 `AdapterProbe`
    /// （探测阶段不启动进程、也编不出 transport）；`LaunchTransport` 只用于 `terminate` 分流。
    case webBrowser
    case unknown
}

/// 运行传输方式：让 `terminate` 知道该收哪些资源。
enum LaunchTransport: String, Sendable {
    /// v0.1 行为：单进程，收 pid 即可。
    case nwjs
    /// v0.2：浏览器进程 + HTTP 监听 + 全部在飞连接。
    case webBrowser
    /// v0.4：应用内 `WKWebView` 窗口 + HTTP 监听（**没有浏览器进程**：`pid` 恒为 0）。
    case embeddedKernel
}

/// 内核选择（v0.4）。`nil` = 自动：headless 或显式 `--browser` → Chromium，否则内置内核。
///
/// 为什么不加进 `LaunchStrategy`：`LaunchStrategy` 的 `.webBrowser(webRoot:engine:)` 被
/// `SelfTest/LauncherCaseSupport.swift` 与 `GameLauncher.launch` 的 switch 依赖，
/// 加 case 或改关联值会牵动自测与产品路；内核选择放在 `LaunchOptions` 上，两处零改动。
enum WebKernelKind: String, Sendable {
    case chromium
    case embedded
}

/// Web 运行后端的可传递描述符。
///
/// **只放能在 actor 之外安全传递的值**：`NWListener` / `NWConnection` 不是 `Sendable`，
/// 塞进 `Sendable` struct 会直接编译不过。runner 本体留在 `GameLauncher.webRuns` 里，
/// 由 `sessionKey` 找回。
struct WebRunDescriptor: Sendable {
    /// 在 `GameLauncher.webRuns` 里找回 runner 的键（随机 16 hex）。
    var sessionKey: String
    /// 静态服务端口（存档 origin 的一部分，确定性派生）。
    var httpPort: Int
    var webRoot: URL
    /// `http://127.0.0.1:<httpPort>/index.html`
    var pageURL: String
    var profileDir: URL
    var browserBundlePath: String
}

struct AdapterProbe: Sendable {
    var dataRoot: URL?
    var launchLayout: LaunchLayout
    var warnings: [String]
}

struct LaunchHandle: Sendable {
    // ── v0.1 字段，顺序不动 ──
    var pid: Int32
    var port: Int
    var executableURL: URL
    var arguments: [String]
    var gameRoot: URL
    var logURL: URL
    var startedAt: Date
    // ── v0.2 追加，全部带默认值（既有构造点零改动）──
    /// 默认 `.nwjs`：`AttachCLI` 里 `LaunchHandle(pid: 0, …)` 那种"不启动、只 attach"的
    /// 构造点不需要改一个字。
    var transport: LaunchTransport = .nwjs
    /// `transport == .webBrowser` 时非空；`terminate` 用它找回 `StaticWebServer`。
    var web: WebRunDescriptor? = nil
    // ── v0.4 追加，同样全部带默认值（既有构造点零改动）──
    /// `transport == .embeddedKernel` 时非空；`attach` 用它找回内置内核会话。
    var embedded: EmbeddedRunDescriptor? = nil
    /// 窗口关闭信号盒。pump 与 `--play` 的 drain 循环都靠它提前收敛（矩阵 E12）。
    var closed: WindowCloseSignal? = nil
    /// 是否在 hello 之后做场景活性判定（矩阵 E15）。
    ///
    /// **只有 `--play` 的 web 后端（embedded / chromium）会置 true**：那是我们自己刚拉起的
    /// 页面，"连上了但游戏没跑起来"必须当场判死。`--attach` 附着的是别人早就开着的页面，
    /// 它在不在 `Scene_*` 不归我们判（v0.1 的一次性符号判定原样保留）。
    var requiresSceneProbe: Bool = false
}

/// 启动参数（v0.2）：由 `--play` / 设置页 / 产品默认值构造。
struct LaunchOptions: Sendable {
    var headless: Bool = false
    /// `--browser` 或 `Settings.browserPath`。
    var browserPathOverride: String? = nil
    var extraBrowserArgs: [String] = []
    var windowSize: String = K.browserWindowSize
    /// v0.4：nil = 自动（headless 或显式 `--browser` → chromium，否则 embedded）。
    var kernel: WebKernelKind? = nil
    /// v0.4 矩阵 E15：hello 之后是否再判一次"游戏真的在跑"。
    /// 只有 `--play` 会置 true（`--attach` 不许动 v0.1 的行为）。
    var requiresSceneProbe: Bool = false
}

struct AttachInfo: Sendable {
    var pageURL: String
    var browserVersion: String?
    var agentVersion: Int
    var hooks: [String]
    var usedFlatten: Bool
    var allowOriginsRetryUsed: Bool
}

enum AdapterState: Sendable {
    case launching
    case discovering
    case handshaking
    case attaching
    case injecting
    case awaitingHello
    case attached(Start)
    case failed(ErrorInfo)
    case stopping
    case stopped

    struct Start: Sendable {
        var port: Int
        var pageURL: String
        var usedFlatten: Bool
    }

    var uiLabel: String {
        switch self {
        case .launching: return "启动中…"
        case .discovering: return "等待调试端口…"
        case .handshaking: return "握手…"
        case .attaching: return "连接页面…"
        case .injecting: return "注入 Agent…"
        case .awaitingHello: return "等待 Agent 握手…"
        case .attached: return "已连接"
        case .failed: return "连接失败"
        case .stopping: return "停止中…"
        case .stopped: return "已停止"
        }
    }
}

// MARK: - 协议

protocol EngineAdapter: AnyObject, Sendable {
    var engine: EngineKind { get }

    /// 1. 纯磁盘探测（不启动进程）。
    func probe(_ gameRoot: URL) throws -> AdapterProbe

    /// 2. 启动游戏进程（含端口分配 + 日志重定向）。
    func launch(_ entry: GameEntry, log: SessionLog?) async throws -> LaunchHandle

    /// 3. CDP 发现 + attach + 注入 + hello + config 下发。
    func attach(
        _ handle: LaunchHandle,
        sessionToken: String,
        config: AgentConfig,
        onAgentMessage: @escaping @Sendable (AgentEnvelope) -> Void,
        onStateChange: @escaping @Sendable (AdapterState) -> Void
    ) async throws -> AttachInfo

    /// 4. 启动 drain 轮询。
    func startTextPump() async

    /// 5. 下发命令。
    func send(_ command: HostCommand) async throws

    /// 6. 清理：停 Agent → 关 WS → terminate → 3s → kill。
    func stop() async

    /// 7. 自愈：hook 被插件覆盖时重装 agent（幂等）。
    func ensureAgentAlive() async
}

// MARK: - MV/MZ 适配器

/// MV 与 MZ 共用同一实现（Agent 侧只做 feature-detect，不判版本）。
final class MVAdapter: EngineAdapter, @unchecked Sendable {
    let engine: EngineKind
    private let launcher: GameLauncher
    private let log: SessionLog?

    private var cdp: CDPClient?
    /// 当前通道（CDP 薄壳或 WK 实现）。`AgentInjector` 只认它。
    private var channel: (any PageChannel)?
    /// `transport == .embeddedKernel` 时持有内核（截图用）。
    private var kernel: (any EmbeddedKernelSession)?
    /// CDP 会话 id（只给 `Page.captureScreenshot` 用）。
    private var cdpSessionId: String?
    private var agentInjector: AgentInjector?
    private var pumpTask: Task<Void, Never>?
    private var messageHandler: (@Sendable (AgentEnvelope) -> Void)?
    private var stateHandler: (@Sendable (AdapterState) -> Void)?
    private var currentHandle: LaunchHandle?
    /// `stop()` 幂等闸：窗口关闭（pump 内触发）与 UI 点「停止」可能同时到达。
    private let stopLock = NSLock()
    private var isStopping = false

    init(engine: EngineKind = .mv, launcher: GameLauncher = GameLauncher(), log: SessionLog? = nil) {
        self.engine = engine
        self.launcher = launcher
        self.log = log
    }

    // MARK: probe

    func probe(_ gameRoot: URL) throws -> AdapterProbe {
        let root = EngineDetector.normalizedScanRoot(gameRoot)
        var warnings: [String] = []
        var dataRoot: URL?
        let manager = FileManager.default

        let mzData = root.appendingPathComponent("data", isDirectory: true)
        let mvData = root.appendingPathComponent("www/data", isDirectory: true)
        let mvDataFallback = root.appendingPathComponent("data", isDirectory: true)

        if manager.fileExists(atPath: mzData.path) {
            dataRoot = mzData
        } else if manager.fileExists(atPath: mvData.path) {
            dataRoot = mvData
        } else if manager.fileExists(atPath: mvDataFallback.path) {
            dataRoot = mvDataFallback
        } else {
            warnings.append("未找到 data 目录（L1 预翻译不可用，运行时翻译仍可用）")
        }

        var layout: LaunchLayout = .unknown
        let nwjsSub = root.appendingPathComponent("nwjs.app/Contents/MacOS/nwjs")
        if manager.fileExists(atPath: nwjsSub.path) {
            layout = .nwjsSubBundle
        } else if root.pathExtension == "app" {
            layout = .outerAppBundle
        } else if let apps = try? manager.contentsOfDirectory(atPath: root.path), apps.contains(where: { $0.hasSuffix(".app") }) {
            layout = .innerAppBundle
        } else if (try? GameLauncher.detectWebRoot(gameRoot: root, engine: engine)) != nil {
            // nwjs 布局一个都不命中，但目录里能托管 web 根 → 走浏览器运行后端。
            layout = .webBrowser
        }

        return AdapterProbe(dataRoot: dataRoot, launchLayout: layout, warnings: warnings)
    }

    // MARK: launch

    /// 协议方法（v0.1 签名不变）：等价于"用默认 `LaunchOptions` 启动"。
    func launch(_ entry: GameEntry, log: SessionLog?) async throws -> LaunchHandle {
        return try await launch(entry, options: LaunchOptions(), log: log)
    }

    /// v0.2 的具体重载：把 `headless` / 浏览器路径 / 额外参数透传给 `GameLauncher`，
    /// 分流（nwjs vs 浏览器）发生在 `GameLauncher.launch` 内部，适配器不需要知道。
    func launch(_ entry: GameEntry, options: LaunchOptions, log: SessionLog?) async throws -> LaunchHandle {
        let logger = log ?? self.log
        let gameRoot = URL(fileURLWithPath: entry.path, isDirectory: true)
        stateHandler?(.launching)
        let handle = try await launcher.launch(
            entry: entry,
            gameRoot: gameRoot,
            options: options,
            log: logger
        )
        currentHandle = handle
        return handle
    }

    // MARK: attach

    /// 分流：内置内核（v0.4）与 CDP（v0.1/v0.2）**两条路都必须能单独跑通**。
    ///
    /// `transport` 决定走哪条；`--headless` / `--browser` 永远落在 CDP 分支
    /// （`LaunchOptions.kernel` 在 `GameLauncher.launch` 里已经定好）。
    func attach(
        _ handle: LaunchHandle,
        sessionToken: String,
        config: AgentConfig,
        onAgentMessage: @escaping @Sendable (AgentEnvelope) -> Void,
        onStateChange: @escaping @Sendable (AdapterState) -> Void
    ) async throws -> AttachInfo {
        self.messageHandler = onAgentMessage
        self.stateHandler = onStateChange
        currentHandle = handle
        if handle.transport == .embeddedKernel {
            return try await attachViaKernel(
                handle,
                sessionToken: sessionToken,
                config: config,
                onStateChange: onStateChange
            )
        }
        return try await attachViaCDP(
            handle,
            sessionToken: sessionToken,
            config: config,
            onStateChange: onStateChange
        )
    }

    // MARK: - 内置内核路径（v0.4）

    /// 没有 CDP 目标列表可挑：内核只有一个窗口，通道由内核直接给。
    ///
    /// 与 CDP 路径**同序**（早装 → 判符号 → hello → config），因为顺序本身就是正确性：
    /// 早装能赶在 MZ 画第一屏之前把 hook 挂上，晚一步开场对白就永远采不到。
    private func attachViaKernel(
        _ handle: LaunchHandle,
        sessionToken: String,
        config: AgentConfig,
        onStateChange: @escaping @Sendable (AdapterState) -> Void
    ) async throws -> AttachInfo {
        onStateChange(.discovering)
        guard let descriptor = handle.embedded else {
            throw MochiBoxError(
                code: .kernelLoadFailed,
                message: "内置内核启动句柄缺少描述符（kernel_reason=not_registered）"
            )
        }
        guard let kernel = await launcher.embeddedKernel(sessionKey: descriptor.sessionKey) else {
            throw MochiBoxError(
                code: .kernelLoadFailed,
                message: "内置内核会话已丢失（sessionKey=\(descriptor.sessionKey)）"
            )
        }
        self.kernel = kernel
        guard await kernel.isAlive() else {
            throw MochiBoxError(code: .kernelLoadFailed, message: "内置内核窗口已关闭")
        }

        onStateChange(.attaching)
        let channel = await kernel.makeChannel()
        self.channel = channel

        onStateChange(.injecting)
        let tail = try await attachAfterChannel(
            channel: channel,
            sessionToken: sessionToken,
            config: config,
            onStateChange: onStateChange,
            installEagerHooks: { injector in
                await injector.installEagerly(timeoutSec: K.kernelAttachTimeoutSec)
            },
            checkGameSymbols: {
                // 早装失败时才退回符号判定，给出**准确**的错误（"这不是 RPG Maker 页面"），
                // 而不是让用户看到一句"Agent 注入后未收到握手"去乱猜。
                try await Self.waitForGameSymbols(
                    channel: channel,
                    allowRetry: true,
                    log: log
                )
            }
        )
        guard case .ready(let hello) = tail else {
            throw MochiBoxError(
                code: .engineSymbolsMissing,
                message: "内置内核加载的页面不是 RPG Maker 页面：\(descriptor.pageURL)"
            )
        }

        onStateChange(.attached(AdapterState.Start(
            port: descriptor.httpPort,
            pageURL: descriptor.pageURL,
            usedFlatten: false
        )))
        return AttachInfo(
            pageURL: descriptor.pageURL,
            browserVersion: "WebKit(embedded)",
            agentVersion: hello.agentVersion,
            hooks: hello.hooks,
            usedFlatten: false,
            allowOriginsRetryUsed: false
        )
    }

    // MARK: - CDP 路径（v0.1 / v0.2，逐字保留）

    private func attachViaCDP(
        _ handle: LaunchHandle,
        sessionToken: String,
        config: AgentConfig,
        onStateChange: @escaping @Sendable (AdapterState) -> Void
    ) async throws -> AttachInfo {
        onStateChange(.discovering)
        let client = CDPClient(port: handle.port)
        self.cdp = client

        try await client.waitForReady(timeoutSec: max(5, K.cdpAttachTimeoutSec))
        let version = try await client.browserVersion()
        onStateChange(.handshaking)
        try await client.connect(webSocketURL: version.webSocketDebuggerUrl)

        let targets = try await client.listTargets()
        let pages = targets.filter { $0.type == "page" }
        guard !pages.isEmpty else {
            throw MochiBoxError(code: .attachFailed, message: "调试端口上没有 page 目标（端口=\(handle.port)）")
        }
        onStateChange(.attaching)

        // 优先 index.html 的页面（PRD §A.2 步 5）。
        let ordered = pages.sorted { lhs, rhs in
            let lhsIndex = lhs.url.contains("index.html") ? 0 : 1
            let rhsIndex = rhs.url.contains("index.html") ? 0 : 1
            return lhsIndex < rhsIndex
        }

        var lastError: MochiBoxError?
        var attempted: [String] = []

        for target in ordered.prefix(K.maxTargetAttempts) {
            attempted.append(target.url)
            do {
                let session = try await client.attach(to: target.id)
                self.cdpSessionId = session.sessionId
                try await client.enablePage(session)
                try await client.enableRuntime(session)

                // web 传输方式下**先早装 hook，再判符号**（顺序是刻意的）：
                // 早装能赶在 MZ 画第一屏之前把 hook 挂上（否则开场对白/标题菜单会被漏掉，
                // 游戏随后停在等输入上，整轮 captured 就只有 boot 期的一两个杂字）；
                // 而早装成功本身就证明"这是 RPG Maker 页面"（`install()` 需要 Window_Base）。
                // 早装失败时才退回符号判定，给出准确错误。
                onStateChange(.injecting)
                // 通道记在适配器上：`probeSceneActivity()`（矩阵 E15）与 `captureScreenshotPNG()`
                // 都要用它。漏记的症状是"`--play` 走到场景探针就抛 attachFailed: 页面通道不存在"。
                let pageChannel = CDPSessionChannel(cdp: client, session: session)
                self.channel = pageChannel

                let tail = try await attachAfterChannel(
                    channel: pageChannel,
                    sessionToken: sessionToken,
                    config: config,
                    onStateChange: onStateChange,
                    installEagerHooks: { injector in
                        guard handle.transport != .nwjs else { return false }
                        return await injector.installEagerly(timeoutSec: K.webBrowserReadyTimeoutSec)
                    },
                    checkGameSymbols: {
                        // 页面 target 出现 ≠ 游戏脚本已执行：`--attach`（附着到别人已开好的页面）
                        // 保持 v0.1 的一次性判定，行为零变化。
                        try await Self.waitForGameSymbols(
                            client: client,
                            session: session,
                            allowRetry: handle.transport != .nwjs,
                            log: log
                        )
                    }
                )
                guard case .ready(let hello) = tail else {
                    try? await client.detach(session)
                    lastError = MochiBoxError(code: .engineSymbolsMissing, message: "目标不是 RPG Maker 页面：\(target.url)")
                    continue
                }

                onStateChange(.attached(AdapterState.Start(port: handle.port, pageURL: target.url, usedFlatten: session.flatten)))

                return AttachInfo(
                    pageURL: target.url,
                    browserVersion: version.browser,
                    agentVersion: hello.agentVersion,
                    hooks: hello.hooks,
                    usedFlatten: session.flatten,
                    allowOriginsRetryUsed: false
                )
            } catch let error as MochiBoxError {
                lastError = error
                self.channel = nil       // 这个 target 的通道作废，别让探针读到上一个页面的状态
                self.cdpSessionId = nil
                continue
            } catch {
                lastError = MochiBoxError(code: .attachFailed, underlying: "\(error)")
                self.channel = nil
                self.cdpSessionId = nil
                continue
            }
        }

        let message = "所有候选页面都未能注入（尝试过：\(attempted.joined(separator: " | "))）"
        throw lastError ?? MochiBoxError(code: .attachFailed, message: message)
    }

    // MARK: - 两条 attach 路径共用的注入收尾

    /// `attachAfterChannel` 的结果。`symbolMismatch` 怎么处置由调用方决定：
    /// 内核直接抛 `engineSymbolsMissing`，CDP 换下一个 target。
    private enum AttachTail {
        case ready(HelloPayload)
        case symbolMismatch
    }

    /// 通道就绪之后的统一收尾 —— **这个顺序本身就是正确性**：
    /// 早装 hook 必须赶在 MZ 画第一屏之前（晚一步开场对白就永远采不到）；
    /// 早装失败才退回符号判定；拿到 hello 立刻记下 injector，随后推 config。
    /// 两条路径各写一遍迟早漂移，因此只留这一份。
    ///
    /// 路径差异只经由两个闭包显式传入，不靠默认值抹平：
    /// - `installEagerHooks`：内核固定用 `K.kernelAttachTimeoutSec`，CDP 在 nwjs 下压根不早装。
    /// - `checkGameSymbols`：内核走通道判定，CDP 走 client + session 判定。
    ///
    /// `.injecting` 的 emit **不在本方法内**：内核在记完 `self.channel` 之后发，CDP 在
    /// 创建/记录通道之前发。这条相对位置是两条路径的既存差异，交回调用方各自保留。
    private func attachAfterChannel(
        channel: any PageChannel,
        sessionToken: String,
        config: AgentConfig,
        onStateChange: @escaping @Sendable (AdapterState) -> Void,
        installEagerHooks: (AgentInjector) async -> Bool,
        checkGameSymbols: () async throws -> Bool
    ) async throws -> AttachTail {
        let injector = try AgentInjector(channel: channel, sessionToken: sessionToken, log: log)
        let hooksInstalledEarly = await installEagerHooks(injector)
        if !hooksInstalledEarly {
            let isGamePage = try await checkGameSymbols()
            if !isGamePage { return .symbolMismatch }
        }

        onStateChange(.awaitingHello)
        let hello = try await injector.injectAndHandshake()
        self.agentInjector = injector
        try await injector.push(.config(config))
        return .ready(hello)
    }

    // MARK: - 符号就绪判定

    /// 判断目标页面是否真的是 RPG Maker 页面（CDP 入口：包装成通道后走同一份实现）。
    ///
    /// - Parameter allowRetry: `true` 时在 `K.webBrowserReadyTimeoutSec` 内轮询
    ///   （我们刚拉起的浏览器/内核，脚本还没执行完是**正常中间态**）；
    ///   `false` 时只判一次（v0.1 的 `--attach` 行为，附着对象早已加载完毕）。
    static func waitForGameSymbols(
        client: CDPClient,
        session: CDPSession,
        allowRetry: Bool,
        log: SessionLog?
    ) async throws -> Bool {
        let channel = CDPSessionChannel(cdp: client, session: session)
        return try await waitForGameSymbols(channel: channel, allowRetry: allowRetry, log: log)
    }

    /// 符号就绪判定的**唯一实现**（两个通道共用：两套过滤必然漂移）。
    static func waitForGameSymbols(
        channel: any PageChannel,
        allowRetry: Bool,
        log: SessionLog?
    ) async throws -> Bool {
        let expression = "typeof window.Window_Base !== 'undefined' || typeof window.SceneManager !== 'undefined' || typeof window.Bitmap !== 'undefined'"
        let deadline = Date().addingTimeInterval(allowRetry ? K.webBrowserReadyTimeoutSec : 0)
        var attempts = 0
        while true {
            attempts += 1
            let probe = try await channel.evaluate(expression, timeout: K.evaluateTimeoutSec)
            if probe.value?.boolValue == true {
                if attempts > 1 {
                    log?.info("MVAdapter", "游戏脚本已就绪", ["attempts": "\(attempts)", "channel": channel.kind])
                }
                return true
            }
            if Date() >= deadline { return false }
            if attempts == 1 {
                log?.info("MVAdapter", "页面尚无引擎符号，等待脚本加载", [
                    "timeout": "\(Int(K.webBrowserReadyTimeoutSec))",
                    "channel": channel.kind
                ])
            }
            try? await Task.sleep(nanoseconds: UInt64(K.drainPollMs) * 1_000_000)
        }
    }

    // MARK: text pump

    func startTextPump() async {
        guard let injector = agentInjector else { return }
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    let envelopes = try await injector.drain()
                    consecutiveFailures = 0
                    if let handler = self?.messageHandler {
                        for envelope in envelopes {
                            handler(envelope)
                        }
                    }
                } catch {
                    consecutiveFailures += 1
                    // 窗口被用户关掉（矩阵 E12）：这**不是**错误，但要立刻收敛 ——
                    // 打一条 `window_closed=1` 并回报 `.stopped`，否则 GUI 会一直显示"已连接"，
                    // CLI 会白等满 duration 才退出。
                    if self?.currentHandle?.closed?.isClosed == true {
                        let reason = self?.currentHandle?.closed?.reason ?? "unknown"
                        self?.log?.warn("MVAdapter", "窗口已关闭，停止轮询", [
                            "window_closed": "1",
                            "reason": reason
                        ])
                        self?.stateHandler?(.stopped)
                        // 用户点红叉关窗后**必须**走完整 stop()：
                        //   1) 只报 `.stopped` 会留下静态 HTTP 监听与内核注册表项 ——
                        //      端口一直被占，下一次启动假 `web_port_busy`；
                        //   2) WKWebView 不销毁，进程继续吃 CPU/GPU（用户实测的
                        //      "关了窗口后台还在跑"）。
                        // 用 Task 脱离当前 pump：stop() 的第一件事就是 cancel 这个 pump。
                        if let adapter = self {
                            Task { await adapter.stop() }
                        }
                        return
                    }
                    if consecutiveFailures >= 5 {
                        self?.log?.warn("MVAdapter", "drain 连续失败，停止轮询")
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(K.drainPollMs) * 1_000_000)
            }
        }
    }

    // MARK: send

    func send(_ command: HostCommand) async throws {
        guard let injector = agentInjector else {
            throw MochiBoxError(code: .attachFailed, message: "尚未注入 Agent")
        }
        try await injector.push(command)
    }

    // MARK: stop

    func stop() async {
        // 幂等：pump 里"窗口已关"的 Task 与 UI 的「停止」会并发进来；
        // 第二次直接返回，避免重复 uninstall / 重复 terminate（后者会撞幂等表，
        // 本身安全，但会把状态机 `.stopping` 打两遍）。
        stopLock.lock()
        if isStopping {
            stopLock.unlock()
            return
        }
        isStopping = true
        stopLock.unlock()

        stateHandler?(.stopping)
        pumpTask?.cancel()
        pumpTask = nil

        if let injector = agentInjector {
            // 窗口已经被用户关掉时，页面/通道都已死：
            // 再去 `push(config)` / `uninstall()` 只会白等 5s 超时，
            // 期间静态服务还占着端口 —— 这正是用户看到的"关了窗口还在后台转"。
            let windowClosed = currentHandle?.closed?.isClosed == true
            if windowClosed {
                log?.info("MVAdapter", "窗口已关闭，跳过 Agent uninstall（通道已 dead）")
            } else {
                // 尽力而为：先停 Agent（5s 超时不阻塞整体退出）。
                let disabled = AgentConfig(enabled: false, fontScale: 1.0, srcLang: "ja", tgtLang: "zh-Hans")
                try? await injector.push(.config(disabled))
                await injector.uninstall()
            }
        }
        agentInjector = nil

        if let client = cdp {
            // CDP 专属收尾：内置内核没有 WebSocket 要关（窗口由 launcher.terminate 收）。
            await client.close()
        }
        cdp = nil
        cdpSessionId = nil
        channel = nil
        kernel = nil

        if let handle = currentHandle {
            await launcher.terminate(handle)
        }
        currentHandle = nil
        stateHandler?(.stopped)
    }

    // MARK: ensureAgentAlive

    func ensureAgentAlive() async {
        guard let injector = agentInjector else { return }
        do {
            let installed = try await injector.isInstalled()
            if !installed {
                log?.warn("MVAdapter", "Agent hook 已失效，重新注入", ["hook_lost": "1"])
                _ = try await injector.injectAndHandshake()
            }
        } catch {
            log?.warn("MVAdapter", "ensureAgentAlive 失败", ["error": "\(error)"])
        }
    }

    // MARK: 截图（E2E 自证用）

    /// 按 transport 分流：CDP 走 `Page.captureScreenshot`，内置内核走 `takeSnapshot`。
    ///
    /// 两者都**不算 AC-8 证据**（进程内渲染 ≠ 用户桌面上看见了窗口），AC-8 只认
    /// `screencapture -l<CGWindowID>`（架构 v0.4 §7.1）。
    func captureScreenshotPNG() async throws -> Data? {
        if currentHandle?.transport == .embeddedKernel {
            guard let kernel = kernel else { return nil }
            return try await kernel.snapshotPNG()
        }
        // CDP 截图必须带 sessionId。sessionId 从 `AgentInjector` 移走后只剩这一个用途，
        // 因此记在适配器上（架构 v0.4 §3.1 表末行）。
        guard let client = cdp, let sessionId = cdpSessionId else { return nil }
        let result = try await client.send(
            "Page.captureScreenshot",
            params: .object(["format": .string("png")]),
            sessionId: sessionId,
            timeout: K.evaluateTimeoutSec
        )
        guard let base64 = result["data"]?.stringValue else { return nil }
        return Data(base64Encoded: base64)
    }

    /// 页面侧 `__mochibox.probe()` 的 JSON 文本（E2E 取证用：`replaced > 0` 证明译文真的回绘了）。
    ///
    /// 返回 nil = 还没注入 / 页面已被销毁；调用方按"拿不到证据"处理，不得当成 0。
    func agentProbeJSON() async -> String? {
        guard let injector = agentInjector else { return nil }
        return await injector.evaluateString(
            "window.__mochibox && window.__mochibox.probe ? window.__mochibox.probe() : null"
        )
    }

    // MARK: 控制通道（v0.6 E2E）

    /// 把一次求值**原样**转发给当前页通道（`--control` 的 `eval` op）。
    ///
    /// 与 `agentProbeJSON()` 的区别：那个固定表达式、吞异常、只回字符串；控制通道要的是
    /// 三态分明（值 / 页面异常 / 通道故障），所以这里**不 catch**：超时抛 `.cdpTimeout`、
    /// 通道死抛 `.attachFailed`，与 `PageChannel` 的语义约定逐条对齐。
    func controlEvaluate(_ expression: String, timeout: TimeInterval) async throws -> JSEvalResult {
        guard let channel = channel else {
            throw MochiBoxError(code: .attachFailed, message: "页面通道不存在（尚未 attach 或已 stop）")
        }
        return try await channel.evaluate(expression, timeout: timeout)
    }

    // MARK: 场景活性（矩阵 E15）

    /// 一次场景观测：`scene` 是 `SceneManager._scene.constructor.name`，`video` 是
    /// `<readyState>/<paused>/<error>`。
    ///
    /// 为什么把两件事放在**一条表达式**里：分两次 evaluate 会得到"两个时刻"的画面，
    /// 日志上就会出现"scene=Scene_Map 但 video=0/true"这种自相矛盾的组合，
    /// 而这条日志的全部价值就是让人一眼分清"内核没起来"和"游戏在播影片"。
    struct SceneActivity: Sendable, Equatable {
        var scene: String
        var video: String

        /// `scene=Scene_Boot video=2/false/null`（`play: ` 前缀由调用方加，格式见 §5.2 E15）。
        var summary: String { return "scene=\(scene) video=\(video)" }

        var videoReadyState: Int { return Int(video.split(separator: "/").first ?? "") ?? -1 }
    }

    /// 取值表达式。**不白名单场景名**：本作 97 个插件会自造 `Scene_*`，白名单必然误判。
    ///
    /// 视频来源是 **DOM ∪ PIXI 纹理缓存**：RPG Maker MZ 的影片插件（某影片插件、
    /// MpiTitleMovie 等）普遍 `document.createElement('video')` 后**不 appendChild**，
    /// 正在播的 `<video>` 永远不在 DOM 里；只查 `document.querySelector('video')` 会把
    /// "在播"误判成 `none/true/null`。PIXI 5 的非 DOM 视频纹理挂在
    /// `PIXI.utils.BaseTextureCache`（值为 BaseTexture）与 `PIXI.utils.TextureCache`
    /// （值为 Texture，取 `.baseTexture`）上，两处都兜一遍，按**元素引用**去重
    /// （同一 src 可能对应多个元素，按 src 去重会丢）。PIXI/HTMLVideoElement 缺失时
    /// 安静退回只数 DOM——这段字符串会被 evaluate，抛异常等于整条诊断失效。
    /// 取值优先级：第一个 `readyState >= 2`（能播）的元素 → 第一个元素 → none。
    static let sceneProbeScript: String = """
    (function(){
      var scene = (typeof SceneManager !== 'undefined' && SceneManager._scene)
        ? SceneManager._scene.constructor.name : 'none';
      function collectVideos(){
        var out = [];
        function add(el){
          if (!el || typeof HTMLVideoElement === 'undefined'
              || !(el instanceof HTMLVideoElement)) return;
          if (out.indexOf(el) === -1) out.push(el);
        }
        try {
          var nodes = document.querySelectorAll('video');
          for (var i = 0; i < nodes.length; i++) add(nodes[i]);
        } catch (e) {}
        try {
          if (typeof PIXI !== 'undefined' && PIXI && PIXI.utils) {
            var caches = [PIXI.utils.BaseTextureCache, PIXI.utils.TextureCache];
            for (var c = 0; c < caches.length; c++) {
              var cache = caches[c];
              if (!cache) continue;
              for (var key in cache) {
                var item = cache[key];
                var bt = (item && item.baseTexture) ? item.baseTexture : item;
                add(bt && bt.resource ? bt.resource.source : null);
              }
            }
          }
        } catch (e) {}
        return out;
      }
      var pool = collectVideos();
      var v = null;
      for (var j = 0; j < pool.length; j++) {
        if (pool[j].readyState >= 2) { v = pool[j]; break; }
      }
      if (!v && pool.length) v = pool[0];
      var video = v ? (v.readyState + '/' + v.paused + '/' + (v.error ? v.error.code : 'null'))
                    : 'none/true/null';
      return scene + '|' + video;
    })()
    """

    /// 读一次场景活性。通道已死时抛 `.attachFailed`（**不**吞掉异常）：
    /// 吞掉会让 `scene=none` 与"通道死了"混成同一个症状，排障时没法区分。
    func probeSceneActivity() async throws -> SceneActivity {
        guard let channel = channel else {
            throw MochiBoxError(code: .attachFailed, message: "场景探针失败：页面通道不存在")
        }
        let result = try await channel.evaluate(Self.sceneProbeScript, timeout: K.evaluateTimeoutSec)
        let text = result.value?.stringValue ?? ""
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw MochiBoxError(
                code: .attachFailed,
                message: "场景探针返回了无法解析的值：\(text.isEmpty ? "(空)" : text)"
            )
        }
        return SceneActivity(scene: parts[0], video: parts[1])
    }
}
