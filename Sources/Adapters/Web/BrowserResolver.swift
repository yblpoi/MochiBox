//
//  BrowserResolver.swift
//  MochiBox
//
//  Chromium 内核浏览器的可执行文件解析 + 启动参数构造。
//
//  为什么需要"四级解析"（docs/archive/v0.2/architecture-v0.2-web-runner.md §5.1）：
//  开发机/CI 上常常**没有** Google Chrome（本机只有 Playwright 的 `chromium-1248`），
//  只认 `/Applications/Google Chrome.app` 的实现等于"功能没做"。
//  而 Safari 不支持 CDP，所以必须有"找到 Safari 也没用"的明确指引（AC-6）。
//
//  约束：不得 import AppKit（不能用 `NSWorkspace`），只用 Foundation。
//

import Foundation

/// 一次浏览器启动所需的全部输入。
struct BrowserLaunchSpec: Sendable {
    var executable: URL
    var pageURL: String
    var debugPort: Int
    var profileDir: URL
    var headless: Bool
    var windowSize: String
    var extra: [String]
}

enum BrowserResolver {

    /// 解析结果。
    struct BrowserCandidate: Sendable, Equatable {
        /// `…/Foo.app/Contents/MacOS/Foo`
        var executable: URL
        /// `…/Foo.app`
        var bundlePath: String
        /// `explicit` | `env` | `settings` | `applications` | `playwright-cache`
        var source: String
        var version: String?
    }

    /// `/Applications` 与 `~/Applications` 下按序尝试的 Chrome 族（§5.1 第 3 级）。
    static let applicationBundleNames: [String] = [
        "Google Chrome.app",
        "Google Chrome Canary.app",
        "Chromium.app",
        "Microsoft Edge.app",
        "Brave Browser.app",
        "Vivaldi.app"
    ]

    /// 环境变量名（第 2 级）。
    static let environmentKey = "MOCHI_BROWSER_PATH"

    /// Playwright 缓存根。
    static var playwrightCacheRoot: URL {
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/ms-playwright", isDirectory: true)
    }

    // MARK: - 解析

    /// 四级解析（缺一不可）。
    ///
    /// - Parameters:
    ///   - explicit: 命令行显式指定的路径（`--browser`）。**解析失败即报错**：
    ///     用户明确点名了一个内核，静默换成另一个会让 E2E 与排障变成"看起来成功"。
    ///   - configured: `Settings.browserPath`（手改 `settings.json`）。填错只记 warning
    ///     并继续下一级 —— 那是配置项，不该因为一个月前填错一个路径就整体不可用。
    ///   - log: 记录每一级的失败原因（"为什么没用我指定的那个"必须能在日志里查到）。
    static func resolve(
        explicit: String?,
        configured: String?,
        log: SessionLog? = nil
    ) throws -> BrowserCandidate {
        // 第 0 级：命令行显式指定（比配置更"当下"，必须最优先且失败即错）。
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            guard let candidate = candidate(fromPath: explicit, source: "explicit") else {
                // 第一行点名"你给的那个路径不行"，后面**必须**接完整的 AC-6 四要素。
                // 只丢一句 `explicit_path_invalid` 是最糟的选择：首行错在用户手上，
                // 而用户恰恰是"本机没装 Chrome 才去 --browser 指路"的那批人 ——
                // 他们最需要"装哪个 / 怎么配 / Safari 为什么不行"，不是一句 invalid。
                throw MochiBoxError(
                    code: .browserNotFound,
                    message: "你指定的浏览器路径不可用：\(explicit)"
                        + "（该路径必须存在且是可执行文件，或是含 `Contents/MacOS/<executable>` 的 `.app`；"
                        + "detail: explicit_path_invalid）\n"
                        + failureMessage(explicit: explicit, configured: configured)
                )
            }
            log?.info("BrowserResolver", "使用命令行指定的浏览器", [
                "source": candidate.source,
                "executable": candidate.executable.path
            ])
            return candidate
        }

        // 第 1 级：环境变量。
        let environmentPath = ProcessInfo.processInfo.environment[environmentKey]
        if let environmentPath = environmentPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentPath.isEmpty {
            if let candidate = candidate(fromPath: environmentPath, source: "env") {
                log?.info("BrowserResolver", "使用环境变量指定的浏览器", [
                    "key": environmentKey,
                    "executable": candidate.executable.path
                ])
                return candidate
            }
            log?.warn("BrowserResolver", "环境变量指向的浏览器不可用，继续下一级", [
                "key": environmentKey,
                "path": environmentPath
            ])
        }

        // 第 2 级：设置里的 `browserPath`。
        if let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            if let candidate = candidate(fromPath: configured, source: "settings") {
                log?.info("BrowserResolver", "使用 settings.json 里的 browserPath", [
                    "executable": candidate.executable.path
                ])
                return candidate
            }
            log?.warn("BrowserResolver", "settings.json 的 browserPath 不可用，继续自动发现", [
                "path": configured
            ])
        }

        // 第 3 级：/Applications 与 ~/Applications 的 Chrome 族。
        for bundleName in applicationBundleNames {
            for base in applicationDirectories() {
                let bundle = base.appendingPathComponent(bundleName, isDirectory: true)
                guard FileManager.default.fileExists(atPath: bundle.path) else { continue }
                if let executable = AppBundleLocator.executableInside(appURL: bundle) {
                    let candidate = BrowserCandidate(
                        executable: executable,
                        bundlePath: bundle.path,
                        source: "applications",
                        version: AppBundleLocator.shortVersion(appURL: bundle)
                    )
                    log?.info("BrowserResolver", "命中 /Applications 下的 Chromium 内核", [
                        "bundle": bundleName,
                        "executable": executable.path
                    ])
                    return candidate
                }
            }
        }

        // 第 4 级：Playwright 缓存（本机**唯一**的真实路径）。
        if let candidate = playwrightCandidate(log: log) {
            return candidate
        }

        throw MochiBoxError(code: .browserNotFound, message: failureMessage(explicit: explicit, configured: configured))
    }

    /// 只是"找过哪些地方"的清单（失败文案与日志共用，避免两套描述漂移）。
    static func searchedPaths(explicit: String?, configured: String?) -> [String] {
        var paths: [String] = []
        if let explicit = explicit, !explicit.isEmpty { paths.append(explicit + "（--browser）") }
        if let environment = ProcessInfo.processInfo.environment[environmentKey], !environment.isEmpty {
            paths.append(environment + "（\(environmentKey)）")
        }
        if let configured = configured, !configured.isEmpty { paths.append(configured + "（settings.json）") }
        for bundleName in applicationBundleNames {
            for base in applicationDirectories() {
                paths.append(base.appendingPathComponent(bundleName).path)
            }
        }
        paths.append(playwrightCacheRoot.path + "/chromium-*/chrome-mac*/*.app")
        return paths
    }

    /// AC-6 要求的失败文案：**可执行指引**，不是"崩溃"也不是"假装成功"。
    ///
    /// 四要素必须有：安装哪个、怎么在 settings.json 里写、怎么用环境变量、
    /// 以及"Safari 不支持 CDP"（用户看到自己有 Safari 却没用时必然会来报 bug）。
    static func failureMessage(explicit: String?, configured: String?) -> String {
        let tried = searchedPaths(explicit: explicit, configured: configured)
        var message = "找不到 Chromium 内核浏览器（detail: browser_not_found）。\n已尝试：\n"
        for path in tried {
            message += "  " + path + "\n"
        }
        message += "请安装 Google Chrome / Chromium / Microsoft Edge / Brave / Vivaldi 之一，或：\n"
        message += "  · 在 ~/Library/Application Support/MochiBox/settings.json 里填写 \"browserPath\"\n"
        message += "  · 或设置环境变量 \(environmentKey) 指向可执行文件（或 .app 路径）\n"
        message += "  · 或运行时加 --browser <路径>\n"
        message += "（Safari 不支持 CDP，无法用于本功能。）"
        return message
    }

    // MARK: - 启动参数

    /// 启动参数清单（架构 §5.2，**每一条都不能删**，删了对应的副作用见文档）。
    static func launchArguments(_ spec: BrowserLaunchSpec) -> [String] {
        var arguments: [String] = []
        // 产品唯一的采集通道：缺了 `--attach` 链路整条断。
        arguments.append("--remote-debugging-port=\(spec.debugPort)")
        // ① 默认 profile 上 Chrome 会忽略调试端口 ② 存档按 profile+origin 隔离
        // ③ 绝不能碰用户真实 Chrome 配置。
        arguments.append("--user-data-dir=\(spec.profileDir.path)")
        // brief §0.2 实测：不带就 NotAllowedError → MZ 把游戏钉在错误页。这是功能不是优化。
        arguments.append("--autoplay-policy=no-user-gesture-required")
        // 无地址栏独立窗口；页面是唯一 target，`listTargets` 不会混进扩展页。
        arguments.append("--app=\(spec.pageURL)")
        arguments.append("--window-size=\(spec.windowSize)")
        // 首次运行对话框会盖在游戏窗口上抢焦点，并改写 profile。
        arguments.append("--no-first-run")
        arguments.append("--no-default-browser-check")
        // Chrome 内置翻译条会改写 DOM 文本 → 采集到的入参与回绘结果不一致。
        arguments.append("--disable-features=Translate,TranslateUI")
        // 三件套：窗口被遮挡/最小化时 Chromium 会把 rAF/setTimeout 降到 1Hz，
        // 表现为"游戏不推进、翻译停了"。
        arguments.append("--disable-background-timer-throttling")
        arguments.append("--disable-backgrounding-occluded-windows")
        arguments.append("--disable-renderer-backgrounding")
        // 加载 800MB 素材时主线程会短暂无响应。
        arguments.append("--disable-hang-monitor")
        // 触控板双指横滑会触发页面前进/后退 → 游戏白屏。
        arguments.append("--disable-pinch")
        arguments.append("--overscroll-history-navigation=0")
        if spec.headless {
            arguments.append("--headless=new")
            // 沙箱在无图形会话下起不来会直接退出。**窗口模式绝不加**。
            arguments.append("--no-sandbox")
            // ⚠ **不加 `--disable-gpu`**（与此前设计稿的差异，实测证据见下）：
            // MZ 启动时就要建 WebGL 上下文；把 GPU 关掉后页面直接变成
            // "Error / Your browser does not support WebGL." 并**停在错误页**
            // —— 一句对白都采集不到（截图 `Tests/e2e` 里有留档）。
            // headless 下改用 SwiftShader 软件渲染：Chrome 129+ 起必须显式
            // `--enable-unsafe-swiftshader` 才允许软件 WebGL。
            arguments.append("--enable-unsafe-swiftshader")
        }
        arguments += spec.extra
        return arguments
    }

    // MARK: - 各级实现

    private static func applicationDirectories() -> [URL] {
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// 把一个用户给的路径（`.app` 或可执行文件）解析成候选。
    static func candidate(fromPath path: String, source: String) -> BrowserCandidate? {
        let expanded = (path as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded)
        // 允许直接给 `.app` 里的可执行文件路径。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue && url.pathExtension.lowercased() == "app" {
            // `.app` 是目录，这条实际不会命中；保留给"路径确实是个文件"的兜底。
            guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
            return BrowserCandidate(executable: url, bundlePath: url.path, source: source, version: nil)
        }
        if isDirectory.boolValue {
            if url.pathExtension.lowercased() == "app" {
                guard let executable = AppBundleLocator.executableInside(appURL: url) else { return nil }
                return BrowserCandidate(
                    executable: executable,
                    bundlePath: url.path,
                    source: source,
                    version: AppBundleLocator.shortVersion(appURL: url)
                )
            }
            // 目录但不是 .app：把"目录里的 .app"再试一次（用户可能给了 /Applications）。
            let names = DirectoryReader.entryNames(url)
            if !names.isEmpty {
                for name in names.sorted() where name.lowercased().hasSuffix(".app") {
                    let bundle = url.appendingPathComponent(name, isDirectory: true)
                    if let executable = AppBundleLocator.executableInside(appURL: bundle) {
                        return BrowserCandidate(
                            executable: executable,
                            bundlePath: bundle.path,
                            source: source,
                            version: AppBundleLocator.shortVersion(appURL: bundle)
                        )
                    }
                }
            }
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        // 把 bundle 推断成 `…/Foo.app`（如果路径形如 `…/Foo.app/Contents/MacOS/Foo`）。
        var bundlePath = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        if !bundlePath.lowercased().hasSuffix(".app") { bundlePath = "" }
        url = url.standardizedFileURL
        return BrowserCandidate(executable: url, bundlePath: bundlePath, source: source, version: nil)
    }

    /// 第 4 级：`chromium-*` 按数字后缀**降序**取第一个含 `.app` 的。
    private static func playwrightCandidate(log: SessionLog?) -> BrowserCandidate? {
        let manager = FileManager.default
        let names = DirectoryReader.entryNames(playwrightCacheRoot)
        guard !names.isEmpty else { return nil }

        let versions: [(number: Int, name: String)] = names.compactMap { name in
            guard name.hasPrefix("chromium-") else { return nil }
            let suffix = String(name.dropFirst("chromium-".count))
            guard let number = Int(suffix) else { return nil }
            return (number, name)
        }.sorted { $0.number > $1.number }

        for entry in versions {
            let base = playwrightCacheRoot.appendingPathComponent(entry.name, isDirectory: true)
            let children = DirectoryReader.entryNames(base)
            guard !children.isEmpty else { continue }
            // `chrome-mac-arm64` / `chrome-mac` / `chrome-mac-x64` 都接受。
            for child in children.sorted() where child.hasPrefix("chrome-mac") {
                let childURL = base.appendingPathComponent(child, isDirectory: true)
                let inner = DirectoryReader.entryNames(childURL)
                guard !inner.isEmpty else { continue }
                for name in inner.sorted() where name.lowercased().hasSuffix(".app") {
                    let bundle = childURL.appendingPathComponent(name, isDirectory: true)
                    if let executable = AppBundleLocator.executableInside(appURL: bundle) {
                        let candidate = BrowserCandidate(
                            executable: executable,
                            bundlePath: bundle.path,
                            source: "playwright-cache",
                            version: AppBundleLocator.shortVersion(appURL: bundle)
                        )
                        log?.info("BrowserResolver", "命中 Playwright 缓存的 Chromium（本机无 Chrome 时的正常路径）", [
                            "executable": executable.path
                        ])
                        return candidate
                    }
                }
            }
        }
        return nil
    }
}
