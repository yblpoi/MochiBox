//
//  MKXPZAdapter.swift
//  MochiBox
//
//  RPG Maker XP/VX/VX Ace 适配器：驱动内置的 mkxp-z 进程。
//
//  与 EasyRPGAdapter 同构（**没有页面通道**）：mkxp-z 是 Ruby 运行时，但宿主既没有注入点、
//  也不该去管它的脚本环境，所以实时链路整体不存在。能做的只有拉起进程、收干净进程；
//  文本走静态路径（Data/*.rxdata|rvdata|rvdata2，由 Marshal 数据层直读）。
//
//  与 EasyRPG 的唯一流程差别在 GameLauncher 里：mkxp-z 的挂载根是子进程 cwd，
//  启动前还要校验 Game.ini 的 Library= 与引擎一致。
//

import Foundation

final class MKXPZAdapter: EngineAdapter, @unchecked Sendable {
    let engine: EngineKind
    private let launcher: GameLauncher
    private let log: SessionLog?

    private var currentHandle: LaunchHandle?
    private var stateHandler: (@Sendable (AdapterState) -> Void)?
    /// `stop()` 幂等闸：UI 点「停止」与进程自己退出可能前后脚到达。
    private let stopLock = NSLock()
    private var isStopping = false

    init(engine: EngineKind = .rgss3, launcher: GameLauncher = GameLauncher(), log: SessionLog? = nil) {
        self.engine = engine
        self.launcher = launcher
        self.log = log
    }

    // MARK: probe

    /// 数据根就是游戏根：XP/VX/VX Ace 的 Data/ 直接躺在游戏目录下。
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
        log?.info("MKXPZAdapter", "mkxp-z 已启动", [
            "pid": "\(handle.pid)",
            "exe": handle.executableURL.path
        ])
        return handle
    }

    // MARK: attach

    /// 没有握手可做：唯一有意义的事是确认进程还活着。
    ///
    /// 等 500ms 是必要的 —— mkxp-z 读不到 Game.ini / 数据文件时会立刻退出，
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
                message: "mkxp-z 启动后立即退出（pid=\(handle.pid)）。日志：\(handle.logURL.path)"
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

    /// 空实现：没有实时通道可轮询。翻译走静态路径（L1 预翻译）。
    func startTextPump() async {}

    // MARK: send

    /// **no-op 且不抛错**：`HostCommand` 全部是给页面 Agent 的，这个后端一条也执行不了。
    /// 抛错会让 UI 每次调设置都弹一次错误对话框（能力表里已经如实写明）。
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

    /// 没有 Agent 可重装：只报进程存活状态。
    func ensureAgentAlive() async {
        guard let handle = currentHandle, handle.pid > 0 else { return }
        let alive = await launcher.isRunning(pid: handle.pid)
        if !alive {
            log?.warn("MKXPZAdapter", "游戏进程已退出", ["pid": "\(handle.pid)"])
        }
    }

    // MARK: - CLI 取证方法（与 MVAdapter 同名，供调用点按适配器类型分派）

    /// 没有页面可观测 → 永远 nil。
    func probeSceneActivity() async throws -> MVAdapter.SceneActivity? {
        return nil
    }

    /// 没有页面可截图 → 永远 nil。
    func captureScreenshotPNG() async throws -> Data? {
        return nil
    }

    /// 没有 JS 求值通道 → 抛 `attachFailed`（通道不存在 ≠ 求值返回 null）。
    func controlEvaluate(_ expression: String, timeout: TimeInterval) async throws -> JSEvalResult {
        throw MochiBoxError(
            code: .attachFailed,
            message: "mkxp-z 后端没有 JS 通道，无法执行控制表达式"
        )
    }

    /// 没有 `__mochibox.probe()` → 回空对象（nil 与"探针返回空"必须能区分）。
    func agentProbeJSON() async -> String? {
        return "{}"
    }
}
