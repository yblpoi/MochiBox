//
//  LauncherCaseSupport.swift
//  MochiBox
//
//  `--selftest` F 组：启动策略 / Web 根识别 / 端口确定性 / 错误文案 / 真浏览器生命周期。
//
//  这一组是 AC-4（端口确定性）、AC-6（找不到浏览器的可执行指引）、AC-7（启动失败后
//  进程与端口都被回收）的自动化证据。其中 `browser_launch_and_terminate` 与
//  `web_runner_stop_partial` 的 (c) 段会**真的拉起一次 Chromium**：它是唯一能证明
//  "浏览器 + HTTP 监听 + 在飞连接会被一起收干净"的方法，纯逻辑用例证明不了这件事
//  （架构 §11 R6）。
//
//  **默认不拉浏览器**：这些段要 `MOCHI_SELFTEST_BROWSER=1` 才跑，否则打印 TAP `# SKIP`。
//  理由：`--selftest` 是每次改完都会跑的重构护栏，不能在用户机器上无声拉起 Chrome、
//  占端口、写 profile。真浏览器的硬门禁是 `Tests/e2e/run.sh`（kernel/faults 层，不允许跳过）。
//

import Foundation
import Darwin

extension SelfTestRunner {

    static var launcherCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "F", name: "web_root_detection") { context in
                // MZ 主判据：index.html + js/rmmz_core.js → root 本身。
                let mz = try webRoot(context, "f_root_mz", files: [
                    "index.html": "<html></html>",
                    "js/rmmz_core.js": "// core"
                ])
                let mzDetected = try GameLauncher.detectWebRoot(gameRoot: mz, engine: .mz)
                try expectEqual(mzDetected.standardizedFileURL.path, mz.standardizedFileURL.path, "MZ 主判据")

                // MV：www/index.html + www/js/rpg_core.js → <root>/www。
                let mv = try webRoot(context, "f_root_mv", files: [
                    "www/index.html": "<html></html>",
                    "www/js/rpg_core.js": "// core"
                ])
                let mvDetected = try GameLauncher.detectWebRoot(gameRoot: mv, engine: .mv)
                try expectEqual(mvDetected.lastPathComponent, "www", "MV 主判据")

                // 降级 MZ：index.html + data/System.json（没有 rmmz_core.js 也算）。
                let degraded = try webRoot(context, "f_root_degraded", files: [
                    "index.html": "<html></html>",
                    "data/System.json": "{}"
                ])
                let degradedDetected = try GameLauncher.detectWebRoot(gameRoot: degraded, engine: .mz)
                try expectEqual(degradedDetected.standardizedFileURL.path,
                                degraded.standardizedFileURL.path, "降级 MZ")

                // 大小写不敏感：`Index.html` 也要认（大小写敏感卷上的真实情况）。
                let oddCase = try webRoot(context, "f_root_case", files: [
                    "Index.html": "<html></html>",
                    "js/rmmz_core.js": "// core"
                ])
                _ = try GameLauncher.detectWebRoot(gameRoot: oddCase, engine: .mz)

                // 缺失：必须抛 web_root_missing，且文案里要有"找过哪里 + 目录内容 + 不需要 Wine"。
                let missing = try webRoot(context, "f_root_missing", files: [
                    "data/System.json": "{}",
                    "Game.exe": "stub"
                ])
                do {
                    _ = try GameLauncher.detectWebRoot(gameRoot: missing, engine: .mz)
                    throw SelfTestFailure(message: "缺 index.html 时必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .webRootMissing, "错误码")
                    try expect(error.message.contains("index.html"), "文案应点名 index.html")
                    // 目录里前 20 个条目要列出来：用户看到自己那个 `index.htm`（少个 l）才能自查。
                    try expect(error.message.contains("Game.exe") && error.message.contains("data"),
                               "文案应列出目录里的条目（前 20 个），实际：\(error.message)")
                    try expect(error.message.contains("Game.exe"), "文案应提到检测到的 Windows 启动器")
                    try expect(error.message.contains("不需要 Wine"), "必须讲清不需要 Wine")
                }
            },
            SelfTestCase(group: "F", name: "web_port_determinism") { context in
                // AC-4：同一 webRoot 每次同端口；不同 webRoot 不同端口。
                // 用临时 AppPaths：不写用户目录（也就不会污染真实存档记录）。
                let paths = AppPaths(root: try directory(context, "f_ports_store"))
                let rootA = try webRoot(context, "f_port_a", files: ["index.html": "<html></html>"])
                let rootB = try webRoot(context, "f_port_b", files: ["index.html": "<html></html>"])

                let assignments = WebPortAssignments(paths: paths)
                let first = try await assignments.assign(webRoot: rootA, isFree: { _ in true })
                let second = try await assignments.assign(webRoot: rootA, isFree: { _ in true })
                try expectEqual(first, second, "同一 webRoot 两次必须同端口（否则存档 origin 漂移）")
                try expect(first >= K.webPortLow && first <= K.webPortHigh,
                           "端口应落在 \(K.webPortLow)–\(K.webPortHigh)，实际 \(first)")

                let other = try await assignments.assign(webRoot: rootB, isFree: { _ in true })
                try expect(other != first, "不同 webRoot 必须不同端口（webRoot=\(rootA.lastPathComponent)/\(rootB.lastPathComponent)）")

                // 持久化：换一个实例（模拟"第二天再启动"）仍然拿到同一端口。
                let reopened = WebPortAssignments(paths: paths)
                let persisted = await reopened.persistedPort(webRoot: rootA)
                try expectEqual(persisted, first, "重启后必须仍拿到同一端口")

                // 冲突探测：已被**别的游戏**持久占用的端口不得再分配（否则两个游戏会抢同一 origin）。
                let rootC = try webRoot(context, "f_port_c", files: ["index.html": "<html></html>"])
                do {
                    _ = try await assignments.assign(webRoot: rootC, low: first, high: first, isFree: { _ in true })
                    throw SelfTestFailure(message: "已被别的游戏持久占用的端口不得再分配")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .portUnavailable, "整段区间占满 → port_unavailable")
                }
                let table = await assignments.snapshot()
                try expectEqual(table.schemaVersion, 1, "持久表 schemaVersion")
                try expect(table.assignments.count >= 2, "至少两条记录")
            },
            SelfTestCase(group: "F", name: "browser_not_found_message") { _ in
                let message = BrowserResolver.failureMessage(explicit: "/nonexistent/chrome", configured: nil)
                // AC-6 的四要素，缺一条用户就只能来问人。
                try expect(message.contains("/nonexistent/chrome"), "文案应包含命令行指定的路径")
                try expect(message.contains("安装"), "文案应说明装哪个")
                try expect(message.contains("settings.json"), "文案应说明 settings.json 里写 browserPath")
                try expect(message.contains(BrowserResolver.environmentKey), "文案应说明环境变量")
                try expect(message.contains("Safari"), "必须写清 Safari 不支持 CDP")
                try expect(message.contains("chromium-*"), "文案应列出 Playwright 缓存这一级")

                // 显式指定但不可用 → 必须立刻报错，不能静默换一个内核。
                do {
                    _ = try BrowserResolver.resolve(explicit: "/nonexistent/chrome", configured: nil, log: nil)
                    throw SelfTestFailure(message: "显式指定不存在的浏览器必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .browserNotFound, "错误码")
                    try expectEqual(error.retryable, false, "browser_not_found 不可重试")
                }
            },
            SelfTestCase(group: "F", name: "launch_strategy_prefers_nwjs") { context in
                // 同时具备 nwjs 布局与可托管 web 根时，必须选 nwjs（v0.1 行为不能被抢走）。
                let root = try webRoot(context, "f_strategy", files: [
                    "index.html": "<html></html>",
                    "js/rmmz_core.js": "// core",
                    "nwjs.app/Contents/MacOS/nwjs": "#!/bin/sh\nexit 0\n"
                ])
                let nwjsBinary = root.appendingPathComponent("nwjs.app/Contents/MacOS/nwjs")
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nwjsBinary.path)

                let launcher = GameLauncher(paths: AppPaths(root: try directory(context, "f_strategy_store")))
                let strategy = try await launcher.resolveStrategy(gameRoot: root, engine: .mz)
                switch strategy {
                case .nwjsApp(let executable, let layout):
                    try expectEqual(layout, .nwjsSubBundle, "布局")
                    try expect(executable.path.hasSuffix("nwjs.app/Contents/MacOS/nwjs"),
                               "可执行文件，实际 \(executable.path)")
                case .webBrowser:
                    throw SelfTestFailure(message: "存在 nwjs 布局时必须优先 nwjs，不得走 Web 运行后端")
                }

                // 只有 web 根（Windows 发行版形态）→ 必须走 webBrowser，且不能因为存在
                // `Game.exe` 就报错（架构 §6.3：不报错、不提示阻断、不动用户盘上的文件）。
                let windowsStyle = try webRoot(context, "f_strategy_win", files: [
                    "index.html": "<html></html>",
                    "js/rmmz_core.js": "// core",
                    "Game.exe": "stub",
                    "package.json": "{\"main\":\"index.html\"}"
                ])
                let windowsStrategy = try await launcher.resolveStrategy(gameRoot: windowsStyle, engine: .mz)
                switch windowsStrategy {
                case .webBrowser(let webRoot, let engine):
                    try expectEqual(engine, .mz, "引擎")
                    try expectEqual(webRoot.standardizedFileURL.path,
                                    windowsStyle.standardizedFileURL.path, "web 根")
                    try expect(FileManager.default.fileExists(atPath: windowsStyle.appendingPathComponent("Game.exe").path),
                               "不得删除用户的 Game.exe")
                case .nwjsApp:
                    throw SelfTestFailure(message: "没有 nwjs 时不得返回 nwjs 策略")
                }
            },
            SelfTestCase(group: "F", name: "browser_launch_and_terminate", skip: browserCaseSkipReason) { context in
                // 真浏览器生命周期：启动 → HTTP 可达 → terminate → 进程/端口/连接全部回收。
                //
                // 走到这里说明调用方显式设了 MOCHI_SELFTEST_BROWSER=1（否则注册处已 TAP SKIP）。
                // 本机没有 Chromium 时仍按原行为打印一行说明并返回：`--selftest` 要能在任何
                // macOS 上全绿，真浏览器的硬门禁是 `Tests/e2e/run.sh` 的 kernel/faults 层。
                do {
                    _ = try BrowserResolver.resolve(explicit: nil, configured: nil, log: nil)
                } catch {
                    print("# note [F] browser_launch_and_terminate skipped: \(error)")
                    return
                }

                let gameRoot = try webRoot(context, "f_launch_game", files: [
                    "index.html": "<html><body>mochibox selftest</body></html>",
                    "js/rmmz_core.js": "// core"
                ])
                let paths = AppPaths(root: try directory(context, "f_launch_store"))
                let launcher = GameLauncher(paths: paths)

                let entry = GameEntry(
                    name: "selftest",
                    path: gameRoot.path,
                    engine: .mz,
                    engineConfidence: .high,
                    engineEvidence: ["js/rmmz_core.js"],
                    supportLevel: .p0,
                    reason: nil
                )
                // 收尸兜底：这条用例只要能拿到 handle，**无论**后面哪一步断言失败、
                // 请求超时、任务被取消，还是在 launch 刚返回就抛错，退出前都必须 terminate。
                // `terminate` 是幂等的（`terminatedSessions` 去重），正常路径已收过一次
                // 也不会二次等待。没有这层兜底，一次"注入缺陷"实验就能在机器上留下一整组
                // Chrome 进程（2026-10-24 清掉的那批孤儿就是这么来的）。
                var handle: LaunchHandle?
                do {
                    let launched = try await launcher.launch(
                        entry: entry,
                        gameRoot: gameRoot,
                        options: LaunchOptions(headless: true),
                        log: nil
                    )
                    handle = launched
                    try expectEqual(launched.transport, .webBrowser, "transport")
                    guard let web = launched.web else {
                        throw SelfTestFailure(message: "transport 是 webBrowser 时 handle.web 必须非空")
                    }
                    try expect(launched.port >= K.debugPortLow && launched.port <= K.debugPortHigh,
                               "调试端口应落在调试区间，实际 \(launched.port)")
                    try expect(web.httpPort >= K.webPortLow && web.httpPort <= K.webPortHigh,
                               "静态服务端口应落在 web 区间，实际 \(web.httpPort)")
                    try expect(web.pageURL.hasSuffix("/\(K.webDirectoryIndexName)"), "pageURL 应指向 index.html")
                    try expect(FileManager.default.fileExists(atPath: web.profileDir.path), "profile 目录必须存在")

                    let response = try await TestHTTP.request(port: web.httpPort, path: "/")
                    try expectEqual(response.status, 200, "静态服务应能返回 index.html")

                    // 端口确定性：同一 webRoot 再分配一次必须还是同一个端口（存档 origin 不漂）。
                    let again = try await launcher.allocateWebPort(webRoot: web.webRoot)
                    try expectEqual(again, web.httpPort, "同一 webRoot 的静态端口必须稳定")

                    await launcher.terminate(launched)

                    // AC-7：进程没了、端口空了、连接数归零。
                    try expect(kill(launched.pid, 0) != 0,
                               "terminate 之后浏览器进程必须已退出（pid=\(launched.pid)）")
                    // 不只主进程：任何带这个 profile 的 helper（gpu/renderer/network）也必须消失。
                    // 只断言主 pid，helper 留在那里照样握着 profile 与端口。
                    let survivors = await waitUntilGone(token: web.profileDir.path)
                    try expect(survivors.isEmpty,
                               "terminate 之后不得有带该 profile 的残留进程（pid=\(survivors)）")
                    try expect(LoopbackPort.isFree(web.httpPort),
                               "terminate 之后静态服务端口必须立刻空闲（http=\(web.httpPort)）")
                    try expect(LoopbackPort.isFree(launched.port),
                               "terminate 之后调试端口必须立刻空闲（debug=\(launched.port)）")
                    try expectEqual(await launcher.activeWebSessions(), 0, "会话登记表应清空")

                    // 立刻在同端口重建：这是"上次 attach 失败后端口必须可重用"的等价断言。
                    let server = StaticWebServer(root: web.webRoot, port: web.httpPort, log: nil)
                    let rebound = try await server.start()
                    try expectEqual(rebound, web.httpPort, "同端口重建必须成功")
                    await server.stop()
                } catch {
                    if let handle = handle { await launcher.terminate(handle) }
                    throw error
                }
            },
            SelfTestCase(group: "F", name: "web_runner_stop_partial") { context in
                // 架构补条：`stop()` 必须能在 `start()` **只完成一半**时安全调用。
                //
                // 为什么必须有用例：T5 的"attach 失败后端口可立刻重用"依赖这条。若某条失败
                // 分支把浏览器进程留在那里，下一次跑就是假 `web_port_busy` / 假
                // `browser_exited_early`，排查时会误以为是端口派生算法（会去动
                // `WebPortAssignments` —— 那是错的，那个文件没问题）。
                //
                // 三个中途状态各断言一次，断言统一是：不崩 / `activeConnections == 0` /
                // 同端口能立刻重新 `NWListener` 成功。
                let root = try webRoot(context, "f_partial_game", files: [
                    "index.html": "<html><body>partial</body></html>",
                    "js/rmmz_core.js": "// core"
                ])
                let store = AppPaths(root: try directory(context, "f_partial_store"))
                let gameHash = WebPortAssignments.gameHash(for: root)

                /// 与 makeConfig 用同一个公式：断言 pid 文件时要能算出产品的落点。
                func profileDir(_ httpPort: Int) -> URL {
                    return store.browserProfilesDirectory
                        .appendingPathComponent("\(gameHash)-partial-\(httpPort)", isDirectory: true)
                }

                func makeConfig(
                    _ httpPort: Int, _ debugPort: Int, browser: String?, ready: Double,
                    extraArgs: [String] = []
                ) -> WebRunnerConfig {
                    return WebRunnerConfig(
                        webRoot: root,
                        engine: .mz,
                        debugPort: debugPort,
                        httpPort: httpPort,
                        headless: true,
                        readyTimeoutSec: ready,
                        browserPathOverride: browser,
                        configuredBrowserPath: nil,
                        windowSize: K.browserWindowSize,
                        extraBrowserArgs: extraArgs,
                        profileDir: profileDir(httpPort),
                        logURL: store.logsDirectory.appendingPathComponent("partial-\(httpPort).log"),
                        log: nil
                    )
                }

                /// 同端口立刻重新起一次真的 `NWListener`（不是只看 `LoopbackPort.isFree`：
                /// 端口"看起来空闲"但监听器还没释放干净是这条最典型的假绿）。
                func assertPortReusable(_ port: Int, _ label: String) async throws {
                    let server = StaticWebServer(root: root, port: port, log: nil)
                    do {
                        let bound = try await server.start()
                        try expectEqual(bound, port, "\(label)：同端口必须能立刻重新监听")
                        await server.stop()
                    } catch {
                        await server.stop()
                        throw error
                    }
                }

                // (a) 监听已起 / 浏览器未起：解析浏览器就失败，静态服务已经绑上了端口。
                guard let portA = freeLoopbackPort(from: 39600, to: 39700),
                      let debugA = freeLoopbackPort(from: 39350, to: 39400) else {
                    throw SelfTestFailure(message: "找不到空闲回环端口")
                }
                let runnerA = WebGameRunner(config: makeConfig(
                    portA, debugA, browser: "/nonexistent/mochibox-no-such-browser", ready: 1
                ))
                do {
                    _ = try await runnerA.start()
                    throw SelfTestFailure(message: "(a) 显式指定不存在的浏览器必须让 start() 失败")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .browserNotFound, "(a) 错误码")
                }
                await runnerA.stop()
                let snapA = await runnerA.snapshot()
                try expectEqual(snapA.activeConnections, 0, "(a) 收尾后不得有在飞连接")
                try expectEqual(snapA.browserAlive, false, "(a) 不得残留浏览器进程")
                try expect(snapA.stopped, "(a) stop() 后 stopped 必须为真")
                try await assertPortReusable(portA, "(a)")

                // (b) 浏览器已起 / CDP 未就绪：起一个"活着但永远不开调试端口"的假浏览器。
                //
                //     判活**不看假浏览器自己写的 pid 文件**：`ready: 1` 到点后回滚会立刻
                //     SIGTERM，而"sh 还没被调度到 `echo $$`"（或正卡在 open 与 write 之间）
                //     和"脚本根本没被执行"在 pid 文件上长得一模一样 —— 那样会把**正常的
                //     回滚**报成 "假浏览器没写 pid"，而回滚其实一点问题都没有。
                //     唯一 token 在 exec 时就进了 argv：进程只要还在，`pgrep -f` 一定看得见。
                let binDir = try directory(context, "f_partial_bin")
                let fakeBrowser = binDir.appendingPathComponent("fake-browser.sh")
                let token = "mochibox-fake-browser-\(UUID().uuidString)"
                let script = """
                #!/bin/sh
                # 活着、永不开调试端口。token 由 extraBrowserArgs 追加进 argv。
                # 收到 TERM 先把 sleep 收掉再退，否则会留下 30s 的孤儿进程。
                trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null; fi; exit 0' TERM
                /bin/sleep 30 &
                child=$!
                wait "$child"
                """
                try script.write(to: fakeBrowser, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: fakeBrowser.path
                )

                guard let portB = freeLoopbackPort(from: 39600, to: 39700),
                      let debugB = freeLoopbackPort(from: 39350, to: 39400) else {
                    throw SelfTestFailure(message: "找不到空闲回环端口")
                }
                // ready 压到 1s：这条验的是收尾，不是等 CDP 的耐心。
                let runnerB = WebGameRunner(config: makeConfig(
                    portB, debugB, browser: fakeBrowser.path, ready: 1, extraArgs: [token]
                ))
                do {
                    _ = try await runnerB.start()
                    throw SelfTestFailure(message: "(b) 调试端口始终不可用，start() 必须失败")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .cdpTimeout, "(b) 错误码")
                }
                await runnerB.stop()
                let snapB = await runnerB.snapshot()
                try expectEqual(snapB.activeConnections, 0, "(b) 收尾后不得有在飞连接")
                try expectEqual(snapB.browserAlive, false, "(b) 不得残留浏览器进程")

                // 关键：start() 的失败回滚必须**已经**把浏览器杀掉。
                // 没有这条断言，回滚漏掉 process 也不会红（stop() 走的是另一条分支）。
                // `.cdpTimeout` 本身就证明"回滚那一刻进程还活着"（进程已死会走
                // `.browserExitedEarly`），所以这里不用再单独证明"它确实起来过"。
                let survivors = await waitUntilGone(token: token)
                try expect(survivors.isEmpty,
                           "(b) start() 回滚必须杀掉已拉起的浏览器（仍存活 pid=\(survivors)）")
                // 产品写在 profileDir 里的 pid 文件也必须清掉：留着会让下一次启动
                // 把一个已死的 pid 当成"上次的浏览器还活着"。
                let productPidFile = profileDir(portB).appendingPathComponent(K.webBrowserPidFileName)
                try expect(!FileManager.default.fileExists(atPath: productPidFile.path),
                           "(b) 回滚必须删掉产品的 pid 文件：\(productPidFile.path)")
                try await assertPortReusable(portB, "(b)")

                // (c) 正常路径：`stop()` 连调两次（幂等），端口仍可立刻重绑。
                //
                //     这一段会真拉起 Chromium，与 `browser_launch_and_terminate` 同一条
                //     opt-in 门禁；默认只跑上面两段假浏览器的（(a)(b) 不需要装了 Chrome 才能过）。
                if let reason = browserCaseSkipReason {
                    print("# note [F] web_runner_stop_partial (c) skipped: \(reason)")
                    return
                }
                do {
                    _ = try BrowserResolver.resolve(explicit: nil, configured: nil, log: nil)
                } catch {
                    print("# note [F] web_runner_stop_partial (c) skipped: \(error)")
                    return
                }
                guard let portC = freeLoopbackPort(from: 39600, to: 39700),
                      let debugC = freeLoopbackPort(from: 39350, to: 39400) else {
                    throw SelfTestFailure(message: "找不到空闲回环端口")
                }
                let runnerC = WebGameRunner(config: makeConfig(portC, debugC, browser: nil, ready: 20))
                do {
                    _ = try await runnerC.start()
                } catch {
                    await runnerC.stop()
                    throw error
                }
                await runnerC.stop()
                await runnerC.stop()  // 第二次必须立刻返回，不能崩、不能重复等 grace
                let snapC = await runnerC.snapshot()
                try expectEqual(snapC.activeConnections, 0, "(c) 收尾后不得有在飞连接")
                try expectEqual(snapC.browserAlive, false, "(c) 浏览器必须已退出")
                try expect(snapC.stopped, "(c) stopped")
                // 主进程之外，带这个 profile 的 helper 也必须一起消失。
                let survivorsC = await waitUntilGone(token: profileDir(portC).path)
                try expect(survivorsC.isEmpty, "(c) 不得有带该 profile 的残留进程（pid=\(survivorsC)）")
                try await assertPortReusable(portC, "(c)")
            }
        ]
    }

    /// 真浏览器用例的 opt-in 开关：`MOCHI_SELFTEST_BROWSER=1`。
    ///
    /// 为什么默认关：`--selftest` 是每次改完都会跑的重护栏，在用户机器上无声拉起 Chrome
    /// （占调试端口、写 profile、Dock 里冒图标、退出后还可能留孤儿）是不可接受的副作用。
    /// 真浏览器的硬门禁在 `Tests/e2e/run.sh`（kernel/faults 层真浏览器，不允许跳过）。
    static let browserCaseEnvKey = "MOCHI_SELFTEST_BROWSER"

    /// 非 nil = 这条用例默认不跑（TAP `# SKIP` 的原因文案）。
    static var browserCaseSkipReason: String? {
        let value = ProcessInfo.processInfo.environment[browserCaseEnvKey] ?? ""
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            return "未设置 \(browserCaseEnvKey)=1（避免拉起 Chrome）"
        }
        return nil
    }

    /// 收尸自检：把本次 selftest 临时根下残留的浏览器**先记账、再清掉**。
    ///
    /// 返回"清理前确实还活着"的 pid（空 = 干净）；调用方拿它当断言用 ——
    /// 清理是善后，不是免责，只要非空这一轮就得红。
    ///
    /// 扫描范围是 `AppPaths(root: tempRoot).browserProfilesDirectory`：产品的
    /// `BrowserProcessSweeper.sweep()` 只看用户目录，自检的 profile 全在临时根下，
    /// 只扫产品根等于永远看不见自检留下的孤儿。
    static func reapSelftestBrowsers(tempRoot: URL) async -> [Int32] {
        // 先看再杀：先杀的话这条断言永远不会红，"收尸漏了"就被清理自己掩盖了。
        let leaked = pids(matching: tempRoot.path)
        _ = BrowserProcessSweeper.sweep(pathsList: [AppPaths(root: tempRoot)], graceSec: 0.5)
        var survivors = await waitUntilGone(token: tempRoot.path, timeoutSec: 1.5)
        if !survivors.isEmpty {
            // pid 文件没写成 / 已被删的孤儿 sweep 抓不到；argv 里带本次 tempRoot 的一定是我们的。
            for pid in survivors { kill(pid, SIGKILL) }
            survivors = await waitUntilGone(token: tempRoot.path, timeoutSec: 1.5)
        }
        return Array(Set(leaked).union(survivors)).sorted()
    }

    /// 命令行里带这个 token 的进程 pid（空数组 = 一个都没有）。
    ///
    /// 为什么不用"假浏览器自己写 pid 文件"判活：那个 pid 是**子进程**写的，
    /// `start()` 的就绪超时不保证它已经被调度到（`open(O_TRUNC)` 之后、`write` 之前
    /// 也会被 SIGTERM 打断）。于是"回滚其实成功了"会被读成"脚本没被执行"——
    /// 一条只会在机器忙的时候偶发的假红。token 在 exec 时就进了 argv，进程只要
    /// 还在就一定看得见，没有这个调度窗口。
    private static func pids(matching token: String) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", token]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        // pgrep 退出码 1 = 没有匹配（不是错误）；只有 0 才有 pid 可读。
        return String(decoding: data ?? Data(), as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" })
            .compactMap { Int32(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// 轮询到这些进程消失（最多 `timeoutSec`），返回仍然存活的 pid。
    ///
    /// 给上限是因为 SIGTERM 之后"进程已退出"到"被回收"之间有个极短窗口；
    /// 真有残留时它会在超时后如实返回，不会把真缺陷放过。
    private static func waitUntilGone(token: String, timeoutSec: Double = 2) async -> [Int32] {
        let deadline = Date().addingTimeInterval(timeoutSec)
        var alive = pids(matching: token)
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            alive = pids(matching: token)
        }
        return alive
    }
}
