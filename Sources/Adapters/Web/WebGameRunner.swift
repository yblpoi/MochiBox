//
//  WebGameRunner.swift
//  MochiBox
//
//  Web 运行后端的**编排层**：校验 web 根 → 起静态服务 → 拉浏览器 → 等调试端口就绪
//  → 返回 `WebRunHandle`；`stop()` 按固定顺序收浏览器 + 监听 + 在飞连接。
//
//  为什么是 actor：`start()` / `stop()` 会被 `GameLauncher`（另一个 actor）与
//  取消路径同时调用，必须串行化。`stop()` 幂等且可重入 —— E2E 里最常见的残留就是
//  "attach 失败后浏览器还开着、端口还被占"，下一次直接假 `web_port_busy`。
//

import Foundation
import Darwin

/// `WebGameRunner` 的输入（全部值类型，可跨 actor 传递）。
struct WebRunnerConfig: Sendable {
    var webRoot: URL
    var engine: EngineKind
    /// CDP 调试端口（`GameLauncher.allocatePort()` 给出，39200–39300）。
    var debugPort: Int
    /// 静态服务端口（`GameLauncher.allocateWebPort()` 给出，确定性派生）。
    var httpPort: Int
    var headless: Bool
    /// 等 CDP 就绪的上限。生产路径恒为 `K.webBrowserReadyTimeoutSec`；
    /// 只有自测（"浏览器已起 / CDP 未就绪"这一格）会把它压到 1s 级别，
    /// 否则单条用例就得白等 15s。默认值 = 生产值，调用点不用改。
    var readyTimeoutSec: Double = K.webBrowserReadyTimeoutSec
    /// 命令行 `--browser`（显式，失败即错）。
    var browserPathOverride: String?
    /// `Settings.browserPath`（配置项，失败只告警）。
    var configuredBrowserPath: String?
    var windowSize: String
    var extraBrowserArgs: [String]
    var profileDir: URL
    /// 浏览器 stdout/stderr 落盘路径（0600）。
    var logURL: URL
    var log: SessionLog?
}

/// `start()` 的产出。
struct WebRunHandle: Sendable {
    var browserPid: Int32
    var browserExecutable: URL
    var arguments: [String]
    var debugPort: Int
    var httpPort: Int
    var pageURL: String
    var profileDir: URL
    var webRoot: URL
}

/// 排障快照。
struct WebRunnerSnapshot: Sendable {
    var httpPort: Int
    var debugPort: Int
    var activeConnections: Int
    var browserAlive: Bool
    var stopped: Bool
}

/// `clearStaleSingletonLocks` 的**终态结论**。
///
/// 为什么要有它：v0.2 清理残留锁失败时只 `warn`，于是"锁清不掉"最后一定表现为
/// Chromium 那句 `Failed to create a ProcessSingleton … Aborting now` + `browser_exited_early`。
/// 用户照着那句文案去查"是不是没装浏览器 / CPU 架构不匹配"永远查不到真因，脚本也判不出来。
///
/// 这里把"清理之后锁还在不在"变成返回值，让 `start()` 能在**起监听与拉浏览器之前**
/// 以 `profile_locked` 硬失败 —— 失败即无残留，日志里也不会有误导性的 Chromium 行。
enum ProfileLockState: Equatable, Sendable {
    /// 没有残留锁，或残留锁已清掉（含"pid 已死、删除成功"这一常见情形）。
    case clear
    /// 锁指向的 pid 活着，且确实是**本 profile** 的浏览器 → 同一存档正被另一个实例使用。
    case heldByLiveBrowser(pid: Int32, target: String)
    /// 清理尝试**之后**锁仍然存在（权限 / `uchg` / 受管策略）。
    case unremovable(path: String, target: String?, detail: String)

    /// 日志里的一行标识（`reason=…` 供脚本 grep，路径另打）。
    var logValue: String {
        switch self {
        case .clear:
            return "clear"
        case let .heldByLiveBrowser(pid, target):
            return "held_by_live_browser pid=\(pid) target=\(target)"
        case let .unremovable(path, target, detail):
            return "unremovable path=\(path) target=\(target ?? "-") detail=\(detail)"
        }
    }

    /// 可机读的分支标识，写进 `MochiBoxError.underlying`（`reason=held` / `reason=unremovable`）。
    ///
    /// 一个错误码配两种文案时，脚本靠它分支，不必去 grep 中文句子。
    var reasonCode: String? {
        switch self {
        case .clear:
            return nil
        case .heldByLiveBrowser:
            return "held"
        case .unremovable:
            return "unremovable"
        }
    }
}

actor WebGameRunner {
    private let config: WebRunnerConfig
    private var server: StaticWebServer?
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopped = false
    private var pageURL: String = ""
    private var boundHTTPPort: Int = 0

    init(config: WebRunnerConfig) {
        self.config = config
    }

    // MARK: - 启动

    /// 顺序：起监听 → 解析浏览器 → 拉浏览器 → 等调试端口就绪。
    ///
    /// 任一步失败都**回滚已起的部分**（架构 §6.4 失败回滚矩阵）：任何残留都会让
    /// 下一次启动变成假 `web_port_busy`。
    func start() async throws -> WebRunHandle {
        guard !stopped else {
            throw MochiBoxError(code: .webServerFailed, message: "运行器已停止，不能再次启动")
        }

        // 0) web 根自检：没有 index.html 的服务只会给用户一个 404 白屏。
        let indexURL = StaticWebRequest.directoryIndex(in: config.webRoot)
        guard indexURL != nil else {
            throw MochiBoxError(
                code: .webRootMissing,
                message: "web 根 \(config.webRoot.path) 里没有 index.html（detail: web_root_missing）"
            )
        }

        // 1) profile 目录（每游戏独立，0700），并回收上一次异常退出留下的浏览器与单实例锁。
        do {
            try createProfileDirectory()
        } catch {
            throw MochiBoxError(
                code: .ioError,
                message: "无法创建浏览器 profile 目录：\(config.profileDir.path)",
                underlying: "\(error)"
            )
        }
        reclaimOrphanBrowser()
        // 1b) 单实例锁门禁：清理**之后**锁还在（清不掉 / 被活实例持有）就立刻失败。
        //
        // 位置是刻意的：`reclaimOrphanBrowser()` 之后（回收才是把锁变成"可清理"的那一步，
        // 提前判定会对"本来能自愈"的残留误报）、起静态服务之前（`self.server` 还是 nil，
        // 没有端口被绑，失败即无残留）、拉浏览器之前（Chromium 那句
        // `Failed to create a ProcessSingleton … Aborting now` 根本不会写进日志）。
        let lockState = clearStaleSingletonLocks(manager: FileManager.default)
        if let lockError = profileLockError(for: lockState) {
            config.log?.error("WebGameRunner", "拒绝启动：profile 单实例锁未清空", [
                "state": lockState.logValue,
                "profile": config.profileDir.path
            ])
            throw lockError
        }

        pageURL = "http://\(K.loopbackHost):\(config.httpPort)/\(K.webDirectoryIndexName)"

        // 2) 静态服务。
        let server = StaticWebServer(root: config.webRoot, port: config.httpPort, log: config.log)
        self.server = server
        do {
            boundHTTPPort = try await server.start()
        } catch {
            self.server = nil
            throw error
        }

        do {
            // 3) 浏览器解析（失败 → 回滚监听）。
            let browser = try BrowserResolver.resolve(
                explicit: config.browserPathOverride,
                configured: config.configuredBrowserPath,
                log: config.log
            )

            // 4) 拉浏览器。
            let arguments = BrowserResolver.launchArguments(BrowserLaunchSpec(
                executable: browser.executable,
                pageURL: pageURL,
                debugPort: config.debugPort,
                profileDir: config.profileDir,
                headless: config.headless,
                windowSize: config.windowSize,
                extra: config.extraBrowserArgs
            ))
            let started = try launchProcess(browser: browser, arguments: arguments)

            // 5) 等调试端口就绪（`Process.run()` 成功 ≠ CDP 可用：
            //    Chromium 会先起 zygote/GPU 子进程）。
            let client = CDPClient(port: config.debugPort)
            do {
                try await client.waitForReady(timeoutSec: config.readyTimeoutSec)
            } catch {
                let alive = started.isRunning
                let tail = FileIO.tailLines(config.logURL, count: K.stderrTailLines)
                let tailText = tail.isEmpty ? "（浏览器日志为空）" : "\n" + tail.joined(separator: "\n")
                if !alive {
                    throw MochiBoxError(
                        code: .browserExitedEarly,
                        message: "浏览器进程启动后立即退出（detail: browser_exited_early）。常见原因："
                            + "上次异常退出留下的 profile 单实例锁（SingletonLock，日志里会出现 "
                            + "`Failed to create a ProcessSingleton … Aborting now`）、profile 目录权限、"
                            + "缺少 --no-sandbox（headless）、CPU 架构不匹配。日志尾部：\(tailText)",
                        underlying: "\(error)"
                    )
                }
                throw MochiBoxError(
                    code: .cdpTimeout,
                    message: "浏览器已启动但调试端口 \(config.debugPort) 在 "
                        + "\(Int(config.readyTimeoutSec))s 内不可用。日志尾部：\(tailText)",
                    underlying: "\(error)"
                )
            }

            // `start()` 中间有多个 await，`stop()` 完全可能在此时插进来（用户按了取消）。
            // 不检查就会返回一个"服务已停"的 handle，调用方拿它去 attach 必失败。
            if stopped {
                await shutdown()
                throw MochiBoxError(
                    code: .webServerFailed,
                    message: "启动过程中被取消（detail: cancelled）",
                    underlying: "stopped during start"
                )
            }

            config.log?.info("WebGameRunner", "浏览器已就绪", [
                "pid": "\(started.processIdentifier)",
                "debug": "\(config.debugPort)",
                "http": "\(boundHTTPPort)",
                "source": browser.source,
                "exe": browser.executable.path,
                "page": pageURL
            ])

            return WebRunHandle(
                browserPid: started.processIdentifier,
                browserExecutable: browser.executable,
                arguments: arguments,
                debugPort: config.debugPort,
                httpPort: boundHTTPPort,
                pageURL: pageURL,
                profileDir: config.profileDir,
                webRoot: config.webRoot
            )
        } catch {
            // 回滚必须和 `stop()` 走**同一条**收尾路径：`start()` 可能停在
            // "浏览器已拉起 / CDP 未就绪" 这一格，此时只 `server.stop()` 会把浏览器进程
            // 留在那里占着调试端口与 profile —— 下一次启动就是假 `browser_exited_early`。
            await shutdown()
            throw error
        }
    }

    // MARK: - 停止

    /// 幂等：第二次调用直接 return。
    ///
    /// 固定顺序（架构 §11 R6）：SIGTERM 浏览器 → 等 3s → SIGKILL → `server.stop()`
    /// （cancel listener + 逐连接 cancel + 关所有 `FileHandle`）。顺序不能反：
    /// 先关服务会让页面在浏览器还活着时疯狂重试，日志被噪声淹没。
    func stop() async {
        if stopped { return }
        stopped = true
        await shutdown()
        config.log?.info("WebGameRunner", "Web 运行后端已停止", ["http": "\(config.httpPort)"])
    }

    /// 收尾的实际动作（可重入，全部字段收完置 nil）。
    ///
    /// `start()` 的失败回滚与 `stop()` 都调它 —— 两处各写一份必然会漂：
    /// 回滚那份漏掉浏览器进程时，**没有**任何用例会红（`stop()` 走不到那条分支），
    /// 只有用户第二次启动才会看到假 `web_port_busy`。
    private func shutdown() async {
        if let process = process {
            let pid = process.processIdentifier
            // 宽限 3s、100ms 轮询 —— 与原实现同值。
            let outcome = await ProcessTerminator.terminateAsync(
                pid: pid,
                graceSec: K.killGraceSec,
                pollMs: 100,
                isAlive: { _ in process.isRunning }
            )
            if outcome.escalated {
                // 再给内核一点时间回收（不然同一端口立刻重启会偶发 busy）。
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.process = nil
        }
        closeLogHandle()

        if let server = server {
            // `stop()` 内部会等端口真正可再绑（`LoopbackPort.waitUntilFree`），
            // 否则调用方紧接着 rebind 会假 `web_port_busy`。
            await server.stop()
            self.server = nil
        }
        // 浏览器已收（或本来就没起来）：pid 文件继续留着只会在下一轮被当成"还活着"。
        BrowserPidFile.remove(pidFileURL)
    }

    // MARK: - 快照

    func snapshot() async -> WebRunnerSnapshot {
        let connections = await server?.activeConnections ?? 0
        return WebRunnerSnapshot(
            httpPort: boundHTTPPort > 0 ? boundHTTPPort : config.httpPort,
            debugPort: config.debugPort,
            activeConnections: connections,
            browserAlive: process?.isRunning ?? false,
            stopped: stopped
        )
    }

    // MARK: - 内部

    private func createProfileDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: config.profileDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.profileDir.path)
    }

    // MARK: - 孤儿浏览器回收

    private var pidFileURL: URL {
        return config.profileDir.appendingPathComponent(K.webBrowserPidFileName)
    }

    /// 上一次会话被 Ctrl-C / `kill -9` 时浏览器会活下来：它继续占着调试端口、继续握着
    /// profile 的单实例锁，于是**下一次启动必然失败**（Chrome 报 ProcessSingleton）。
    ///
    /// 这里按 pid 文件回收，但**只回收确认是我们的那个进程**：
    /// pid 可能被系统复用给无关进程，光看"还活着"就杀是越界行为。
    /// 判据 = 活着的 Chromium 内核进程 **且** 命令行里带 `--user-data-dir=<本 profile>`。
    /// 认不出来就什么都不做（宁可不杀，也不要误杀），退化成 `browser_exited_early` 的明确文案。
    private func reclaimOrphanBrowser() {
        let manager = FileManager.default
        let pidURL = pidFileURL
        guard manager.fileExists(atPath: pidURL.path) else { return }

        guard let pid = BrowserPidFile.read(pidURL), pid > 0 else {
            // 文件坏掉/为空：删掉，免得每轮都念同一句。
            BrowserPidFile.remove(pidURL)
            return
        }

        if isOurBrowser(pid: pid) {
            config.log?.warn("WebGameRunner", "发现上次异常退出遗留的浏览器，先回收再启动", ["pid": "\(pid)"])
            // 宽限 3s、100ms 轮询、判据仍是「这个 pid 是否还是本 profile 的浏览器」。
            let outcome = ProcessTerminator.terminate(
                pid: pid,
                graceSec: K.killGraceSec,
                pollMs: 100,
                isAlive: { isOurBrowser(pid: $0) }
            )
            if outcome.escalated {
                // 给它一点时间真正消失，否则紧接着的启动仍会撞上单实例锁。
                usleep(200_000)
            }
        } else {
            config.log?.info("WebGameRunner", "pid 文件里的进程已不在（或已不是本 profile 的浏览器），清理", [
                "pid": "\(pid)"
            ])
        }
        BrowserPidFile.remove(pidURL)
    }

    private func writePIDFile(_ pid: Int32) {
        do {
            try BrowserPidFile.write(pid, to: pidFileURL)
        } catch {
            // pid 文件只是"下次能回收"的保险，写不进去不该影响本次启动。
            config.log?.warn("WebGameRunner", "无法写入浏览器 pid 文件", ["error": "\(error)"])
        }
    }

    /// 这个 pid 是不是**我们这个 profile** 的浏览器。
    ///
    /// 判据已收敛到 `ProcessInspector`（与 `BrowserProcessSweeper` 共用一份）：
    /// 活着的浏览器内核 + argv 里的 `--user-data-dir=<本 profile>`。
    private func isOurBrowser(pid: Int32) -> Bool {
        return ProcessInspector.isBrowser(pid: pid, profileDir: config.profileDir)
    }

    /// 清掉上一次会话（尤其被 SIGKILL）残留的 Chromium 单实例锁，并**返回终态结论**。
    ///
    /// 不清的后果是**下一次启动直接失败**：
    /// `Failed to create a ProcessSingleton for your profile directory. … Aborting now`
    /// —— 于是 `--play` 第二次跑就是 `browser_exited_early` 假失败，用户看到的文案还完全误导。
    ///
    /// `SingletonLock` 的内容是 `<hostname>-<pid>` 形式的软链接。
    ///
    /// 判据不是"pid 还活着"，而是"那个 pid 确实是我们这个 profile 的浏览器"（`isOurBrowser`）：
    /// 僵尸进程和 pid 复用都会让 `kill(pid, 0)` 返回 0，照"活着"判就会把残留锁当成
    /// "有实例在用"而保留，下一次启动直接失败。只有**确认它还活着且就是这个 profile 的浏览器**
    /// 才保留；否则一律清掉（这一步已经在 `reclaimOrphanBrowser` 之后，孤儿浏览器此时已被回收）。
    ///
    /// **`.unremovable` 的判据是"删除之后终检还在不在"，不是"删除有没有抛错"**：
    /// 文件可能在"检查"与"删除"之间被别人删掉（TOCTOU），那种情形删除会失败但结果是干净的，
    /// 不应该硬失败把人挡在门外。
    private func clearStaleSingletonLocks(manager: FileManager) -> ProfileLockState {
        var heldState: ProfileLockState?
        var unremovableState: ProfileLockState?

        for name in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
            let url = config.profileDir.appendingPathComponent(name)
            let symlinkTarget = try? manager.destinationOfSymbolicLink(atPath: url.path)
            guard manager.fileExists(atPath: url.path) || symlinkTarget != nil else {
                continue
            }
            if name == "SingletonLock",
               let target = symlinkTarget,
               let pidText = target.split(separator: "-").last,
               let pid = Int32(pidText),
               isOurBrowser(pid: pid) {
                config.log?.warn("WebGameRunner", "profile 仍被活着的浏览器实例占用，保留单实例锁", [
                    "pid": "\(pid)"
                ])
                heldState = .heldByLiveBrowser(pid: pid, target: target)
                continue
            }
            var removeFailure: String?
            do {
                try manager.removeItem(at: url)
                config.log?.info("WebGameRunner", "清理残留的 Chromium 单实例锁", ["name": name])
            } catch {
                // 不能只 `try?`：清理失败时必须留痕，否则下一次启动会以 Chrome 那句
                // "Failed to create a ProcessSingleton … Aborting now" 报出来，
                // 而真实原因（删不掉残留锁）在日志里查不到。
                removeFailure = "\(error)"
                config.log?.warn("WebGameRunner", "清理残留单实例锁失败", [
                    "name": name,
                    "error": "\(error)"
                ])
            }
            // 终检：只看"现在还在不在"，不看上面那次 removeItem 成没成功（TOCTOU）。
            let stillExists = manager.fileExists(atPath: url.path)
                || (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
            guard stillExists else { continue }

            config.log?.warn("WebGameRunner", "单实例锁仍存在，启动可能会被 Chrome 拒绝", [
                "path": url.path
            ])
            // 硬失败只认 `SingletonLock`：Chromium 的 ProcessSingleton 争用它；
            // `SingletonSocket`/`SingletonCookie` 残留清不掉时仍按 v0.2 行为只留痕，
            // 免得把"浏览器其实能起来"的机器挡在门外（误报比文案误导更难受）。
            if name == "SingletonLock" {
                unremovableState = .unremovable(
                    path: url.path,
                    target: symlinkTarget,
                    detail: removeFailure ?? "清理后文件仍存在（原因未知）"
                )
            }
        }
        // 优先级：被活着的实例持有 > 删不掉（前者有更明确的动作指引：关掉那个窗口）。
        if let heldState { return heldState }
        if let unremovableState { return unremovableState }
        return .clear
    }

    /// 把锁状态翻成用户可执行的错误：**一个码（`profile_locked`）、两种文案**。
    ///
    /// 两种文案都写满项目惯例的四要素：做什么 / 改哪个文件或环境变量 / 具体命令 / 一条排除项。
    /// `uiMessage` 只给通用兜底，分支指引必须在这里 —— UI 显示 `code.rawValue + message`。
    private func profileLockError(for state: ProfileLockState) -> MochiBoxError? {
        guard let reason = state.reasonCode else { return nil }
        let profilePath = config.profileDir.path
        let lockPath = config.profileDir.appendingPathComponent("SingletonLock").path
        let cookiePath = config.profileDir.appendingPathComponent("SingletonCookie").path
        let socketPath = config.profileDir.appendingPathComponent("SingletonSocket").path

        switch state {
        case .clear:
            return nil

        case let .heldByLiveBrowser(pid, target):
            let message = "这个游戏的浏览器 profile 正被另一个实例占用，无法启动"
                + "（detail: profile_locked reason=held）。"
                + "\nprofile 目录：\(profilePath)"
                + "\n单实例锁：  \(lockPath) -> \(target)"
                + "\n请先关掉那个实例：本机另一个 MochiBox 窗口（或你手动用 Chrome/Chromium "
                + "打开过这个 profile 的窗口），关掉后重试："
                + "\n  pkill -f \"user-data-dir=\(profilePath)\""
                + "\n若你确认 pid=\(pid) 已经不是浏览器（pid 被系统复用给了别的进程），直接删锁："
                + "\n  rm -f \"\(lockPath)\" \"\(cookiePath)\" \"\(socketPath)\""
                + "\n（排除项：不是“找不到浏览器”（那是 browser_not_found），"
                + "也不是端口占用（换端口无效）。）"
            return MochiBoxError(code: .profileLocked, message: message, underlying: "reason=\(reason) pid=\(pid)")

        case let .unremovable(path, target, detail):
            let targetText = target ?? "无法解析"
            let message = "浏览器 profile 的单实例锁删不掉，启动被阻止（detail: profile_locked "
                + "reason=unremovable）。"
                + "\n文件：\(path)（指向 \(targetText)；清理结果：\(detail)）"
                + "\n请依次执行（权限 / 不可变标志会导致这里清不掉）："
                + "\n  chflags -h nouchg \"\(path)\"        # 若该文件被设为不可变（macOS 上 uchg 会拒绝 unlink）"
                + "\n  rm -f \"\(lockPath)\" \"\(cookiePath)\" \"\(socketPath)\""
                + "\n  ls -ldO \"\(profilePath)\"           # 需要 0700 且属主是你"
                + "\n若仍失败，把运行时目录指到可写位置即可绕开（存档/端口表一起搬）："
                + "\n  MOCHI_DATA_DIR=/tmp/mochi-data ./MochiBox --play \"<game>\""
                + "\n（排除项：不是浏览器缺失，也不是 CPU 架构/`--no-sandbox` 问题 —— "
                + "那两个只会在浏览器已经起来之后才表现为 browser_exited_early。）"
            return MochiBoxError(code: .profileLocked, message: message, underlying: "reason=\(reason) path=\(path)")
        }
    }

    private func launchProcess(browser: BrowserResolver.BrowserCandidate, arguments: [String]) throws -> Process {
        // 浏览器日志：目录先建好（失败要往上抛），文件 0600 与句柄由 ChildProcessLauncher 负责。
        try FileManager.default.createDirectory(
            at: config.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        config.log?.info("WebGameRunner", "启动浏览器进程", [
            "exe": browser.executable.path,
            "args": arguments.joined(separator: " "),
            "cwd": config.webRoot.path,
            "profile": config.profileDir.path
        ])

        // 失败码仍是 browser_exited_early（与 nwjs 路径的 launcher_no_executable 不同）。
        let launched: ChildProcessLauncher.Launched
        do {
            launched = try ChildProcessLauncher.launch(
                executable: browser.executable,
                arguments: arguments,
                workingDirectory: config.webRoot,
                logURL: config.logURL
            )
        } catch {
            closeLogHandle()
            throw MochiBoxError(
                code: .browserExitedEarly,
                message: "无法启动浏览器：\(browser.executable.path)"
                    + "（detail: browser_exited_early）请确认该文件可执行。",
                underlying: "\(error)"
            )
        }
        logHandle = launched.logHandle
        self.process = launched.process
        // pid 文件必须在**进程已起来**之后立刻写：CLI 随时可能被 Ctrl-C，
        // 没有这个文件，下一次启动就没有任何线索能认出"上次那个浏览器还活着"。
        writePIDFile(launched.process.processIdentifier)
        return launched.process
    }

    private func closeLogHandle() {
        try? logHandle?.synchronize()
        try? logHandle?.close()
        logHandle = nil
    }
}
