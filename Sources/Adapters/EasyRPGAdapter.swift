//
//  EasyRPGAdapter.swift
//  MochiBox
//
//  RPG Maker 2000/2003 适配器：驱动内置的 EasyRPG Player 进程。
//
//  与 `MVAdapter` 的根本差别：**没有页面通道**。EasyRPG 不是 JS 运行时，宿主既不能
//  注入 hook、也读不到 `$gameXxx`，所以实时链路（hello / config / drain / RPC）整体不存在。
//  能做的只有两件事：把游戏进程拉起来、把进程收干净；文本走**静态**路径
//  （磁盘上的 RPG_RT.ldb / 地图事件，由 LCF 数据层直读）。
//
//  这也是 `RuntimeCapabilities.staticTextOnly` 存在的原因：UI/CLI 要能问"能做哪几件事"，
//  而不是按引擎名硬编码 if。
//

import Foundation

final class EasyRPGAdapter: EngineAdapter, @unchecked Sendable {
    let engine: EngineKind
    private let launcher: GameLauncher
    private let log: SessionLog?

    private var currentHandle: LaunchHandle?
    private var stateHandler: (@Sendable (AdapterState) -> Void)?
    /// `stop()` 幂等闸：UI 点「停止」与进程自己退出可能前后脚到达。
    private let stopLock = NSLock()
    private var isStopping = false

    init(engine: EngineKind = .easyrpg, launcher: GameLauncher = GameLauncher(), log: SessionLog? = nil) {
        self.engine = engine
        self.launcher = launcher
        self.log = log
    }

    // MARK: probe

    /// 数据根就是游戏根：2000/2003 的 `RPG_RT.ldb` / `RPG_RT.lmt` 直接躺在游戏目录下，
    /// 没有 MV/MZ 那种 `www/data` 分层。
    func probe(_ gameRoot: URL) throws -> AdapterProbe {
        let root = EngineDetector.normalizedScanRoot(gameRoot)
        return AdapterProbe(dataRoot: root, launchLayout: .nativeRuntime, warnings: [])
    }

    // MARK: launch

    func launch(_ entry: GameEntry, log: SessionLog?) async throws -> LaunchHandle {
        let logger = log ?? self.log
        let gameRoot = URL(fileURLWithPath: entry.path, isDirectory: true)
        stateHandler?(.launching)
        let handle = try await launcher.launch(entry: entry, gameRoot: gameRoot, log: logger)
        currentHandle = handle
        log?.info("EasyRPGAdapter", "EasyRPG Player 已启动", [
            "pid": "\(handle.pid)",
            "exe": handle.executableURL.path
        ])
        return handle
    }

    // MARK: attach

    /// 没有握手可做：唯一有意义的事是确认进程还活着。
    ///
    /// 等 500ms 是必要的 —— EasyRPG 启动后立刻退出（缺数据文件、架构不匹配）时，
    /// `Process.run()` 照样成功；不等这一下就会把一个已死的 pid 当"已连接"交给 UI。
    func attach(
        _ handle: LaunchHandle,
        sessionToken: String,
        config: AgentConfig,
        onAgentMessage: @escaping @Sendable (AgentEnvelope) -> Void,
        onStateChange: @escaping @Sendable (AdapterState) -> Void
    ) async throws -> AttachInfo {
        self.stateHandler = onStateChange
        currentHandle = handle
        onStateChange(.attaching)

        try await Task.sleep(nanoseconds: 500_000_000)

        guard handle.pid > 0, await launcher.isRunning(pid: handle.pid) else {
            throw MochiBoxError(
                code: .processExited,
                message: "EasyRPG Player 启动后立即退出（pid=\(handle.pid)）。日志：\(handle.logURL.path)"
            )
        }

        onStateChange(.attached(AdapterState.Start(port: 0, pageURL: "", usedFlatten: false)))
        return AttachInfo(
            pageURL: "",                 // 没有页面：这个后端的"位置"就是游戏目录
            browserVersion: nil,
            agentVersion: 0,             // 没有 Agent
            hooks: [],
            usedFlatten: false,
            allowOriginsRetryUsed: false,
            capabilities: .staticTextOnly
        )
    }

    // MARK: startTextPump

    /// 空实现：没有实时通道可轮询。翻译走静态路径（L1 预翻译），不经过这里。
    func startTextPump() async {}

    // MARK: send

    /// **no-op 且不抛错**：`HostCommand`（改字号、下发译文、清屏…）全部是给页面 Agent 的，
    /// 这个后端一条也执行不了。抛错会让 UI 每次调设置都弹一次错误对话框 —— 用户什么也没做错，
    /// 只是这个引擎不支持实时链路（能力表里已经如实写明）。
    func send(_ command: HostCommand) async throws {}

    // MARK: stop

    func stop() async {
        stopLock.lock()
        if isStopping {
            stopLock.unlock()
            return
        }
        isStopping = true
        stopLock.unlock()

        stateHandler?(.stopping)
        if let handle = currentHandle {
            await launcher.terminate(handle)
        }
        currentHandle = nil
        stateHandler?(.stopped)
    }

    // MARK: ensureAgentAlive

    /// 没有 Agent 可重装：只报进程存活状态（UI 的"运行中"指示灯靠它）。
    func ensureAgentAlive() async {
        guard let handle = currentHandle, handle.pid > 0 else { return }
        let alive = await launcher.isRunning(pid: handle.pid)
        if !alive {
            log?.warn("EasyRPGAdapter", "游戏进程已退出", ["pid": "\(handle.pid)"])
        }
    }

    // MARK: - CLI 取证方法（与 MVAdapter 同名，供调用点按适配器类型分派）
    //
    // 这几个方法不在 `EngineAdapter` 协议里（协议只服务会话生命周期），MVAdapter 的版本
    // 是类上的独立实现。EasyRPG 必须给出**同名的诚实版本**：能答就答，不能答就明说。

    /// 没有页面可观测 → 永远 nil。
    func probeSceneActivity() async throws -> MVAdapter.SceneActivity? {
        return nil
    }

    /// 没有页面可截图 → 永远 nil。
    ///
    /// （进程级截图不属于这里：AC-8 只认 `screencapture -l<CGWindowID>`。）
    func captureScreenshotPNG() async throws -> Data? {
        return nil
    }

    /// 没有 JS 求值通道 → 抛 `attachFailed`（三态分明：通道不存在 ≠ 求值返回 null）。
    func controlEvaluate(_ expression: String, timeout: TimeInterval) async throws -> JSEvalResult {
        throw MochiBoxError(
            code: .attachFailed,
            message: "EasyRPG 后端没有 JS 通道，无法执行控制表达式"
        )
    }

    /// 没有 `__mochibox.probe()` → 回空对象（而不是 nil：调用方都在解析 JSON，
    /// nil 与"探针返回空"必须能区分）。
    func agentProbeJSON() async -> String? {
        return "{}"
    }
}
