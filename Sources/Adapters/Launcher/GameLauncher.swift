//
//  GameLauncher.swift
//  MochiBox
//
//  进程启动器：
//    · 启动策略解析（macOS nwjs 布局优先 → Web 运行后端 → 报错）
//    · 端口分配 + 探活（调试端口随机区间、静态服务端口确定性派生）
//    · Process 启动 + 日志落盘 + SIGTERM→SIGKILL
//    · Web 路径的生命周期（浏览器进程 + HTTP 监听 + 全部在飞连接一起收）
//
//  依据 docs/prd.md §A.2 步 1–3、P0-05；docs/archive/v0.2/architecture-v0.2-web-runner.md §6。
//

import Foundation
import Darwin

// MARK: - .app 内部的 可执行文件定位

/// `.app` → 内部可执行文件 / 版本号的**唯一**实现。
///
/// 为什么必须只有一份：`GameLauncher`（找 nwjs）与 `BrowserResolver`（找 Chromium）
/// 都要做这件事。两份必然漂移（一份认 `Info.plist` 的 `CFBundleExecutable`、
/// 另一份只认名字叫 `chrome` 的文件），症状是"能把 app 列出来但启动失败"。
enum AppBundleLocator {

    /// `Contents/Info.plist → CFBundleExecutable` → `MacOS/` 下按名找 → 目录里第一个可执行文件。
    static func executableInside(appURL: URL, noteTried: ((URL) -> Void)? = nil) -> URL? {
        let manager = FileManager.default
        let macos = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")

        if let data = try? Data(contentsOf: plistURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let name = plist["CFBundleExecutable"] as? String {
            let candidate = macos.appendingPathComponent(name)
            noteTried?(candidate)
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for name in ["nwjs", "nw"] {
            let candidate = macos.appendingPathComponent(name)
            noteTried?(candidate)
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if let items = try? manager.contentsOfDirectory(atPath: macos.path) {
            for item in items.sorted() {
                let candidate = macos.appendingPathComponent(item)
                noteTried?(candidate)
                if manager.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// `CFBundleShortVersionString`（拿不到就 nil，不用 `NSBundle` 以免引入 AppKit 依赖）。
    static func shortVersion(appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// `…/Foo.app/Contents/MacOS/Foo` → `…/Foo.app`（不在 app 里就返回空串）。
    static func bundlePath(forExecutable url: URL) -> String {
        let parts = url.pathComponents
        guard let contentsIndex = parts.firstIndex(of: "Contents"), contentsIndex >= 1 else { return "" }
        return NSString.path(withComponents: Array(parts[0..<contentsIndex]))
    }
}

// MARK: - 启动策略

/// 启动策略：先 macOS nwjs 布局，其次 Web 运行后端。
enum LaunchStrategy: Sendable {
    case nwjsApp(executable: URL, layout: LaunchLayout)
    case webBrowser(webRoot: URL, engine: EngineKind)
    /// 原生运行时（EasyRPG Player）：自己就是一个进程，没有调试端口、没有静态服务。
    case nativeRuntime(executable: URL, engine: EngineKind)
}

// MARK: - 启动器

actor GameLauncher {
    private var running: [Int32: Process] = [:]
    /// 调试端口（CDP）占位。
    private var usedPorts: Set<Int> = []
    /// 静态服务端口占位。
    private var usedWebPorts: Set<Int> = []
    private var recentFailures: [Int: Date] = [:]
    private var webRuns: [String: WebGameRunner] = [:]
    /// 内置内核会话（v0.4）：`sessionKey → 内核`。Adapters 只认 `EmbeddedKernelSession` 协议。
    private var kernels: [String: any EmbeddedKernelSession] = [:]
    /// 内置内核路径的静态服务（`launchWeb` 走的是 `WebGameRunner` 自带的监听，
    /// 这里没有浏览器进程，监听必须由 launcher 自己持有，否则 `terminate` 收不掉）。
    private var webServers: [String: StaticWebServer] = [:]
    /// 已经 terminate 过的会话键（`terminate` 幂等：第二次不得去 kill 一个可能被复用的 pid）。
    private var terminatedSessions: Set<String> = []
    /// mkxp-z 的 `mkxp.json` 覆盖现场（pid → 还原所需的一切）。
    ///
    /// 只在这里留引用：`terminate` 是唯一能保证"进程已经不在读配置"的收口点，
    /// 启动失败的分支自己就地还原（那时还没有 pid）。
    private var mkxpOverlays: [Int32: MKXPZGameConfig.Overlay] = [:]

    private let webPorts: WebPortAssignments
    /// 运行期目录（`--selftest` 用临时根注入，保证不写用户目录）。
    private let paths: AppPaths

    init(paths: AppPaths = AppPaths.shared) {
        self.paths = paths
        self.webPorts = WebPortAssignments(paths: paths)
    }

    // MARK: - 策略解析（纯磁盘，不启动任何东西）

    /// 0) 原生运行时后端（EasyRPG）→ 1) macOS nwjs 布局 → 2) Web 运行后端 → 3) 报错。
    ///
    /// **第 0 优先必须排在 nwjs 规则之前**：RM2000/2003 的发行目录里经常带着
    /// `EasyRPG Player.app`，落到"根下任意 *.app"那条规则就会被当成 nwjs 启动。
    func resolveStrategy(gameRoot: URL, engine: EngineKind) throws -> LaunchStrategy {
        let root = EngineDetector.normalizedScanRoot(gameRoot)

        switch engine.launchBackend {
        case .easyrpg:
            return try GameLauncher.resolveEasyRPGStrategy(gameRoot: root)
        case .mkxpz:
            return try GameLauncher.resolveMKXPZStrategy(gameRoot: root, engine: engine)
        case .nwjsWeb, .none:
            break
        }

        // ── 第 1 优先：v0.1 的 4 条 nwjs 规则，一行不改 ──
        if let hit = GameLauncher.legacyNWJSExecutable(gameRoot: root, engine: engine) {
            return .nwjsApp(executable: hit.url, layout: hit.layout)
        }

        // ── 第 2 优先：Web 运行后端（Windows 版 MV/MZ 走这里）──
        if let webRoot = try? GameLauncher.detectWebRoot(gameRoot: root, engine: engine) {
            return .webBrowser(webRoot: webRoot, engine: engine)
        }

        // ── 第 3：报错。mv/mz 走 web_root_missing（缺的是 index.html，不是 Wine）──
        if engine == .mv || engine == .mz {
            throw MochiBoxError(
                code: .webRootMissing,
                message: GameLauncher.webRootMissingMessage(gameRoot: root, engine: engine)
            )
        }
        throw MochiBoxError(
            code: .launcherNoExecutable,
            message: GameLauncher.noExecutableMessage(gameRoot: root)
        )
    }

    /// v0.1 的 `resolveExecutable` 函数体：只把最终 `throw` 换成 `return nil`。
    ///
    /// **不要重写这段逻辑** —— 它的 `CFBundleExecutable` 兜底规则被 4 种布局依赖。
    ///
    /// 两条"任意 .app 都算 nwjs"的规则（输入本身是 .app / 根下任意 *.app）只在
    /// `engine.launchBackend == .nwjsWeb` 时生效：EasyRPG 游戏的目录里带
    /// `EasyRPG Player.app`、RGSS 游戏的目录里带 `Game.app` 都是常态，
    /// 无条件认领会把它们误判成 nwjs 启动（随后 CDP 探测必然失败）。
    /// 反过来 `nwjs.app/` 与 `Contents/MacOS/nwjs` 两条是**结构性证据**，不受此限。
    nonisolated static func legacyNWJSExecutable(
        gameRoot: URL,
        engine: EngineKind? = nil
    ) -> (url: URL, layout: LaunchLayout)? {
        let manager = FileManager.default
        // **不要写 `engine?.launchBackend ?? .nwjsWeb`**：`launchBackend` 自身是可选，
        // `engine?.launchBackend` 因此是 `LaunchBackend??`，`??` 只合并**外层** Optional。
        // engine 为 nil 时结果是 "内层仍是 nil" 的 `.some(nil)`，再与 `.nwjsWeb` 比较
        // 得到 false —— 旧写法却让 nil 落进默认值 `.nwjsWeb`，门禁恒为 true（空操作）。
        // 直接比较 `LaunchBackend?` 与 `LaunchBackend`：nil 时自然为 false（不放行）。
        let allowAppBundles = (engine?.launchBackend == .nwjsWeb)

        // 1) 输入本身是 .app
        if allowAppBundles, gameRoot.pathExtension.lowercased() == "app" {
            if let url = AppBundleLocator.executableInside(appURL: gameRoot) {
                return (url, .outerAppBundle)
            }
        }

        // 2) <root>/nwjs.app/...
        let nwjsApp = gameRoot.appendingPathComponent("nwjs.app", isDirectory: true)
        if manager.fileExists(atPath: nwjsApp.path) {
            if let url = AppBundleLocator.executableInside(appURL: nwjsApp) {
                return (url, .nwjsSubBundle)
            }
        }

        // 3) 根下任意 *.app（仅 nwjs 后端：其它引擎的同名 .app 不是 nwjs）
        if allowAppBundles, let items = try? manager.contentsOfDirectory(atPath: gameRoot.path) {
            for item in items.sorted() where item.lowercased().hasSuffix(".app") {
                let appURL = gameRoot.appendingPathComponent(item)
                if let url = AppBundleLocator.executableInside(appURL: appURL) {
                    return (url, .innerAppBundle)
                }
            }
        }

        // 4) <root>/Contents/MacOS/nwjs（输入是 app.nw 之类）
        //
        // **结构性证据，不受 `allowAppBundles` 限制**（与 `legacyNWJSExecutable` 的文档注释一致）：
        // 这个名字只可能出现在 nwjs 工程里，不是"根下碰巧有个 .app"。
        // 早先把它写在上面 `if allowAppBundles` 块内，引擎为 unknown（门禁为 false）
        // 时连这条也会被跳过 —— 代码与注释相反。
        let directNW = gameRoot.appendingPathComponent("Contents/MacOS/nwjs")
        if manager.isExecutableFile(atPath: directNW.path) {
            return (directNW, .outerAppBundle)
        }
        return nil
    }

    // MARK: - 原生运行时查找（EasyRPG Player）

    /// EasyRPG Player 的三段式查找，顺序照 `MediaRenditions` 解析 ffmpeg 的那一套：
    ///  1. `Bundle.main.bundleURL/Contents/Resources/runtime/easyrpg-player`（打包产物）
    ///  2. `Bundle.main.resourceURL/runtime/easyrpg-player`（同一个位置的另一种取法）
    ///  3. `<repo>/vendor/runtime/easyrpg-player`（开发期，`Scripts/fetch-easyrpg.sh` 的产物）
    ///
    /// "存在但不可执行"与"压根不存在"**分成两个错误码**：前者 `chmod +x` 就能好，
    /// 后者要跑 `Scripts/fetch-easyrpg.sh`（或整包重装），用户照着同一句文案排错会白忙。
    /// - Parameter runtimeCandidates: 运行时候选路径（`--selftest` 注入用）。
    ///   生产调用传 nil → 走上面的内置三段式查找；自测在临时目录造
    ///   `vendor/runtime/easyrpg-player` 后直接传进来，不依赖开发机 `vendor/` 的真实产物
    ///   （否则"缺失/不可执行"这两条永远被真实产物抢先命中，测不出来）。
    nonisolated static func resolveEasyRPGStrategy(
        gameRoot: URL,
        runtimeCandidates: [URL]? = nil
    ) throws -> LaunchStrategy {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let runtimeCandidates {
            candidates = runtimeCandidates
        } else {
            candidates.append(
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/easyrpg-player")
            )
            if let resource = Bundle.main.resourceURL {
                candidates.append(resource.appendingPathComponent("runtime/easyrpg-player"))
            }
            if let repo = repositoryRoot() {
                candidates.append(repo.appendingPathComponent("vendor/runtime/easyrpg-player"))
            }
        }

        var tried: [String] = []
        var notExecutable: [String] = []
        for candidate in candidates {
            tried.append(candidate.path)
            guard manager.fileExists(atPath: candidate.path) else { continue }
            if manager.isExecutableFile(atPath: candidate.path) {
                return .nativeRuntime(executable: candidate, engine: .easyrpg)
            }
            notExecutable.append(candidate.path)
        }

        if !notExecutable.isEmpty {
            throw MochiBoxError(
                code: .runtimeNotExecutable,
                message: "内置 EasyRPG 运行时没有执行权限（detail: runtime_not_executable）。路径："
                    + notExecutable.joined(separator: " | ")
                    + "（chmod +x 即可）"
            )
        }
        throw MochiBoxError(
            code: .runtimeMissing,
            message: "找不到内置 EasyRPG 运行时（detail: runtime_missing）。已尝试："
                + tried.joined(separator: " | ")
                + "。修复：bash Scripts/fetch-easyrpg.sh 后重新构建"
        )
    }

    // MARK: - 原生运行时查找（mkxp-z，RGSS1/2/3）

    /// mkxp-z 的三段式查找，与 `resolveEasyRPGStrategy` 同构（顺序、错误码语义都一致）。
    ///
    /// 与 EasyRPG 的差别只有一处：mkxp-z 的挂载根**不是命令行参数**，而是进程的当前工作目录
    /// （见 `launchMKXPZ`）。这里只负责找到二进制。
    nonisolated static func resolveMKXPZStrategy(
        gameRoot: URL,
        engine: EngineKind,
        runtimeCandidates: [URL]? = nil
    ) throws -> LaunchStrategy {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let runtimeCandidates {
            candidates = runtimeCandidates
        } else {
            candidates.append(
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/mkxp-z")
            )
            if let resource = Bundle.main.resourceURL {
                candidates.append(resource.appendingPathComponent("runtime/mkxp-z"))
            }
            if let repo = repositoryRoot() {
                candidates.append(repo.appendingPathComponent("vendor/runtime/mkxp-z"))
            }
        }

        var tried: [String] = []
        var notExecutable: [String] = []
        for candidate in candidates {
            tried.append(candidate.path)
            guard manager.fileExists(atPath: candidate.path) else { continue }
            if manager.isExecutableFile(atPath: candidate.path) {
                return .nativeRuntime(executable: candidate, engine: engine)
            }
            notExecutable.append(candidate.path)
        }

        if !notExecutable.isEmpty {
            throw MochiBoxError(
                code: .runtimeNotExecutable,
                message: "内置 mkxp-z 运行时没有执行权限（detail: runtime_not_executable）。路径："
                    + notExecutable.joined(separator: " | ")
                    + "（chmod +x 即可）"
            )
        }
        throw MochiBoxError(
            code: .runtimeMissing,
            message: "找不到内置 mkxp-z 运行时（detail: runtime_missing）。已尝试："
                + tried.joined(separator: " | ")
                + "。修复：bash Scripts/fetch-mkxpz.sh 后重新构建"
        )
    }

    // MARK: - mkxp-z 前置校验（Game.ini）

    /// 读 Game.ini 的 `Library=` 并映射到引擎；映射不出来返回 nil。
    ///
    /// 只看前缀而不是全等：真实工程里这一行是各样的 DLL——RGSS104E.dll（XP 1.04）、
    /// RGSS202E.dll（VX 2.02）、RGSS300.dll / RGSS301.dll（VX Ace）、日文版的
    /// RGSS103J.dll、民间汉化改名的 RGSS202E_cn.dll……全等匹配会把大半游戏挡在门外。
    nonisolated static func mkxpzEngine(forLibrary library: String) -> EngineKind? {
        let name = library.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if name.hasPrefix("RGSS3") { return .rgss3 }
        if name.hasPrefix("RGSS2") { return .rgss2 }
        if name.hasPrefix("RGSS1") { return .rgss1 }
        return nil
    }

    /// 从游戏目录读 Game.ini 的 `Library=` 原始值。缺失/读不出这一行 → `gameIniMissing`。
    ///
    /// 编码：Game.ini 由 RM 编辑器写出，可能是 ANSI（按系统代码页）或 UTF-16LE（带 BOM）。
    /// `Library=` 本身是纯 ASCII，所以两条解码路径都能拿到它；解不出可读文本时退回
    /// Latin-1（逐字节保真），只求不把 ASCII 行弄丢。
    nonisolated static func mkxpzGameIniLibrary(gameRoot: URL) throws -> String {
        let url = gameRoot.appendingPathComponent("Game.ini")
        guard let data = try? Data(contentsOf: url) else {
            throw MochiBoxError(
                code: .gameIniMissing,
                message: "游戏目录里没有 Game.ini（detail: game_ini_missing）。路径：\(url.path)"
                    + "。mkxp-z 靠它读 Library= 与 Scripts=，缺了只会黑屏。"
            )
        }

        let text: String
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // 逐字节保真：只求不把 ASCII 的 `Library=` 行弄丢。
            text = String(data: data, encoding: .isoLatin1) ?? ""
        }

        // 必须用 CharacterSet.newlines 而不是与 "\n" 比较：Swift 把 CRLF 当成**一个**
        // Character（grapheme cluster），`$0 == "\n"` 在 CRLF 上恒为 false ——
        // 而 RM 编辑器写出的 Game.ini 正是 CRLF（自测 mkxpz_game_ini_missing 抓到的）。
        for rawLine in text.components(separatedBy: CharacterSet.newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "library" {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        throw MochiBoxError(
            code: .gameIniMissing,
            message: "Game.ini 里没有 Library= 行（detail: game_ini_missing）。路径：\(url.path)"
        )
    }

    /// 启动前的一致性门禁：Game.ini 的 Library 必须与检测到的引擎对得上。
    ///
    /// 为什么必须挡：mkxp-z 的 RGSS 版本由 Library 决定，而我们的引擎标签来自目录特征
    /// （Data/*.rvdata2、Game.rgss3a…）。两者不一致时进程**照样起得来**，只是脚本引擎
    /// 与数据格式错配 —— 用户看到的是一块黑屏或立刻退出，没有任何错误提示。
    nonisolated static func validateMKXPZGameIni(gameRoot: URL, engine: EngineKind) throws {
        let library = try mkxpzGameIniLibrary(gameRoot: gameRoot)
        guard let declared = mkxpzEngine(forLibrary: library) else {
            throw MochiBoxError(
                code: .runtimeVersionMismatch,
                message: "Game.ini 的 Library=\(library) 不是已知的 RGSS 版本（detail: runtime_version_mismatch）。"
                    + "检测到的引擎：\(engine.displayName)（\(engine.rawValue)）。路径："
                    + gameRoot.appendingPathComponent("Game.ini").path
            )
        }
        guard declared == engine else {
            throw MochiBoxError(
                code: .runtimeVersionMismatch,
                message: "Game.ini 的 Library=\(library) 对应 \(declared.displayName)，"
                    + "但目录被识别为 \(engine.displayName)（detail: runtime_version_mismatch）。路径："
                    + gameRoot.appendingPathComponent("Game.ini").path
            )
        }
    }

    /// 开发期定位仓库根：从 `#filePath` 逐级往上找含 `Scripts/build.sh` 的目录。
    ///
    /// 打包后的 .app 里 `#filePath` 指向编译机上的源码路径（用户机器上通常不存在），
    /// 于是返回 nil —— 只影响开发期兜底那条候选，bundle 内的两条照旧。
    nonisolated static func repositoryRoot() -> URL? {
        let manager = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if manager.fileExists(atPath: dir.appendingPathComponent("Scripts/build.sh").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    /// Web 根识别（架构 §6.2）。命中返回**可托管的目录**，否则抛 `web_root_missing`。
    nonisolated static func detectWebRoot(gameRoot: URL, engine: EngineKind) throws -> URL {
        let root = EngineDetector.normalizedScanRoot(gameRoot)
        let manager = FileManager.default
        let wwwRoot = root.appendingPathComponent("www", isDirectory: true)

        let mzIndex = StaticWebRequest.directoryIndex(in: root)
        let mvIndex = StaticWebRequest.directoryIndex(in: wwwRoot)
        let mzCore = manager.fileExists(atPath: root.appendingPathComponent("js/rmmz_core.js").path)
        let mvCore = manager.fileExists(atPath: wwwRoot.appendingPathComponent("js/rpg_core.js").path)
        let mzData = manager.fileExists(atPath: root.appendingPathComponent("data/System.json").path)
        let mvData = manager.fileExists(atPath: wwwRoot.appendingPathComponent("data/System.json").path)
        let mzJS = manager.fileExists(atPath: root.appendingPathComponent("js").path)

        switch engine {
        case .mz:
            if mzIndex != nil && mzCore { return root }
            if mvIndex != nil && mvCore { return wwwRoot }
            if mzIndex != nil && (mzJS || mzData) { return root }
            if mvIndex != nil && mvData { return wwwRoot }
        case .mv:
            if mvIndex != nil && mvCore { return wwwRoot }
            if mvIndex != nil && mvData { return wwwRoot }
            if mzIndex != nil && mzCore { return root }
            if mzIndex != nil && (mzJS || mzData) { return root }
        default:
            break
        }

        // 跨版本兜底：engine 判不准时，谁有 index.html 用谁（两者都在按 engine 优先）。
        if engine == .mv || engine == .mz {
            if engine == .mv, mvIndex != nil { return wwwRoot }
            if mzIndex != nil { return root }
            if mvIndex != nil { return wwwRoot }
        }
        throw MochiBoxError(code: .webRootMissing, message: webRootMissingMessage(gameRoot: root, engine: engine))
    }

    /// `web_root_missing` 的文案：tried 清单 + 目录里前 20 个名字 + "不需要 Wine"。
    ///
    /// 用户看到自己目录里那个 `index.htm`（少了 `l`）会立刻明白问题在哪；
    /// 只写"找不到 index.html"则只能来问人。
    nonisolated static func webRootMissingMessage(gameRoot: URL, engine: EngineKind) -> String {
        let manager = FileManager.default
        let wwwRoot = gameRoot.appendingPathComponent("www", isDirectory: true)
        var tried: [String] = [
            gameRoot.path,
            gameRoot.appendingPathComponent(K.webDirectoryIndexName).path,
            wwwRoot.path,
            wwwRoot.appendingPathComponent(K.webDirectoryIndexName).path
        ]
        if gameRoot.pathExtension.lowercased() == "app" {
            tried.append(EngineDetector.normalizedScanRoot(gameRoot).path)
        }

        var names: [String] = []
        if let items = try? manager.contentsOfDirectory(atPath: gameRoot.path) {
            names = items.sorted().prefix(20).map { $0 }
        }
        var message = "游戏目录里没有可托管的 index.html（detail: web_root_missing，引擎 \(engine.displayName)）。\n"
        message += "已尝试：\n"
        for path in tried { message += "  " + path + "\n" }
        if names.isEmpty {
            message += "目录不可读或为空。\n"
        } else {
            message += "目录里前 \(names.count) 个条目：\(names.joined(separator: ", "))\n"
        }
        // Windows 版发行目录里必然有 Game.exe —— 用户很容易以为是"缺 Wine"。
        let windowsShells = ["Game.exe", "nw.exe"]
        for shell in windowsShells where manager.fileExists(atPath: gameRoot.appendingPathComponent(shell).path) {
            message += "检测到 Windows 版启动器 \(shell) —— 本产品不需要 Wine，也不需要运行它；缺的是 index.html。"
            break
        }
        return message
    }

    nonisolated static func noExecutableMessage(gameRoot: URL) -> String {
        let managed = FileManager.default
        var tried: [String] = [gameRoot.path]
        tried.append(gameRoot.appendingPathComponent("Contents/MacOS/nwjs").path)
        tried.append(gameRoot.appendingPathComponent("nwjs.app/Contents/MacOS/nwjs").path)
        tried.append(gameRoot.appendingPathComponent("app.nw/Contents/MacOS/nwjs").path)
        if let items = try? managed.contentsOfDirectory(atPath: gameRoot.path) {
            for item in items.sorted() where item.lowercased().hasSuffix(".app") {
                tried.append(gameRoot.appendingPathComponent(item).path)
            }
        }
        let triedText = tried.isEmpty ? "（无候选路径）" : tried.joined(separator: " | ")
        return "找不到可执行文件（detail: no_executable_found）。已尝试：\(triedText)"
    }

    // MARK: - 端口

    /// BSD socket 探活（只绑回环）。实现集中在 `LoopbackPort`，避免两份漂移。
    func isPortFree(_ port: Int) -> Bool {
        return LoopbackPort.isFree(port)
    }

    func allocatePort(low: Int = K.debugPortLow, high: Int = K.debugPortHigh) throws -> Int {
        var attempts = 0
        while attempts < K.portProbeAttempts {
            attempts += 1
            let port = Int.random(in: low...high)
            if usedPorts.contains(port) { continue }
            if let failedAt = recentFailures[port], Date().timeIntervalSince(failedAt) < 30 { continue }
            if isPortFree(port) {
                usedPorts.insert(port)
                return port
            }
            recentFailures[port] = Date()
        }
        throw MochiBoxError(code: .portUnavailable, message: "端口 \(low)–\(high) 内没有可用端口（已尝试 \(attempts) 次）")
    }

    /// 静态服务端口：**确定性派生**（同一 `webRoot` 每次同值 → 存档 origin 不漂）。
    func allocateWebPort(webRoot: URL) async throws -> Int {
        let inUse = usedWebPorts
        let port = try await webPorts.assign(
            webRoot: webRoot,
            low: K.webPortLow,
            high: K.webPortHigh,
            isFree: { candidate in
                return !inUse.contains(candidate) && LoopbackPort.isFree(candidate)
            }
        )
        usedWebPorts.insert(port)
        return port
    }

    // MARK: - 启动

    func launch(
        entry: GameEntry,
        gameRoot: URL,
        options: LaunchOptions = LaunchOptions(),
        log: SessionLog?
    ) async throws -> LaunchHandle {
        switch try resolveStrategy(gameRoot: gameRoot, engine: entry.engine) {
        case .nwjsApp(let executable, let layout):
            return try launchNWJS(executable: executable, layout: layout, gameRoot: gameRoot, log: log)
        case .nativeRuntime(let executable, let engine):
            if engine.launchBackend == .mkxpz {
                return try launchMKXPZ(executable: executable, engine: engine, gameRoot: gameRoot, log: log)
            }
            return try launchNativeRuntime(
                executable: executable,
                engine: engine,
                gameRoot: gameRoot,
                log: log
            )
        case .webBrowser(let webRoot, let engine):
            // 内核选择（v0.4 §4.4）：`--headless` / 显式 `--browser` 永远走 Chromium，
            // 其余走应用内 WKWebView。`options.kernel` 显式给了就听它的。
            let kernel = options.kernel
                ?? ((options.headless || options.browserPathOverride != nil) ? .chromium : .embedded)
            // 用户可见性的一条硬证据：GUI / `--play` 默认必须是 embedded。
            // 只要日志里出现 `kernel=chromium`，就说明走了 `--browser` / `--headless`，
            // Dock 里出现 Chrome 图标是**预期**而不是泄漏。
            log?.info("GameLauncher", "内核选择", [
                "kernel": kernel.rawValue,
                "headless": options.headless ? "1" : "0",
                "browser": options.browserPathOverride ?? ""
            ])
            switch kernel {
            case .chromium:
                return try await launchWeb(
                    webRoot: webRoot,
                    engine: engine,
                    gameRoot: gameRoot,
                    options: options,
                    log: log
                )
            case .embedded:
                return try await launchEmbedded(
                    webRoot: webRoot,
                    engine: engine,
                    gameRoot: gameRoot,
                    options: options,
                    log: log
                )
            }
        }
    }

    /// v0.1 的启动路径（原样保留）。
    private func launchNWJS(
        executable: URL,
        layout: LaunchLayout,
        gameRoot: URL,
        log: SessionLog?
    ) throws -> LaunchHandle {
        let port = try allocatePort()

        let pathProvider = paths
        pathProvider.ensureDirectories()
        let logURL = pathProvider.logsDirectory
            .appendingPathComponent("game-\(Timestamp.fileStamp())-\(port).log")
        let arguments = ["--remote-debugging-port=\(port)"]

        log?.info("GameLauncher", "启动游戏进程", [
            "exe": executable.path,
            "layout": layout.rawValue,
            "args": arguments.joined(separator: " "),
            "cwd": gameRoot.path,
            "port": "\(port)"
        ])

        // 日志文件 0600 / 句柄 / Process 装配 / run() 走共用实现；
        // 失败码仍是 launcher_no_executable（与 Web 路径的 browser_exited_early 不同）。
        let process: Process
        do {
            process = try ChildProcessLauncher.launch(
                executable: executable,
                arguments: arguments,
                workingDirectory: gameRoot,
                logURL: logURL
            ).process
        } catch {
            usedPorts.remove(port)
            throw MochiBoxError(
                code: .launcherNoExecutable,
                message: "启动失败：\(error.localizedDescription)",
                underlying: "\(error)"
            )
        }

        running[process.processIdentifier] = process
        ChildProcessRegistry.shared.register(process.processIdentifier)
        let handle = LaunchHandle(
            pid: process.processIdentifier,
            port: port,
            executableURL: executable,
            arguments: arguments,
            gameRoot: gameRoot,
            logURL: logURL,
            startedAt: Date(),
            transport: .nwjs,
            web: nil
        )
        log?.info("GameLauncher", "游戏进程已启动", ["pid": "\(handle.pid)", "port": "\(port)"])
        return handle
    }

    /// 原生运行时启动（EasyRPG Player）：单进程，没有调试端口、没有静态服务、没有 CDP。
    ///
    /// 参数只给 0.8.1 **确实有**的开关：
    ///   · `--project-path`：游戏目录（含 RPG_RT.ldb 的那一层）；
    ///   · `--language`：Player 自身的界面语言；
    ///   · `--save-path`：存档目录按 gameHash 隔离（同名游戏放不同目录不能串档）；
    ///   · `--no-audio`：本产品只做文本翻译，音频不参与链路，静音启动最稳。
    ///
    /// **不传 `--language-path`**：那是 gettext 的 PO 目录（运行时翻译的正规入口），
    /// 但官方 **0.8.1 没有这个开关**（只有 master 有），传了会被当成未知参数。
    /// 所以 2000/2003 的译文只能走静态路径（L1 预翻译），没有实时注入通道。
    private func launchNativeRuntime(
        executable: URL,
        engine: EngineKind,
        gameRoot: URL,
        log: SessionLog?
    ) throws -> LaunchHandle {
        paths.ensureDirectories()

        // 存档隔离：`sha256(canonicalPath)` 前 16 hex，与 Web 后端的 gameHash 同源同算法
        // （同一款游戏无论走哪个后端，目录名一致，用户不会看到两份存档目录）。
        let gameHash = WebPortAssignments.gameHash(for: gameRoot)
        let saveRoot = paths.root
            .appendingPathComponent("saves", isDirectory: true)
            .appendingPathComponent(gameHash, isDirectory: true)
        // 建不出来不算致命：EasyRPG 自己会 create_path，失败时退回它自己的默认位置。
        try? FileManager.default.createDirectory(at: saveRoot, withIntermediateDirectories: true)

        let logURL = paths.logsDirectory
            .appendingPathComponent("easyrpg-\(Timestamp.fileStamp())-\(gameHash.prefix(8)).log")
        let arguments = [
            "--project-path", gameRoot.path,
            "--language", "zh_CN",
            "--save-path", saveRoot.path,
            "--no-audio"
        ]

        log?.info("GameLauncher", "启动原生运行时", [
            "exe": executable.path,
            "engine": engine.rawValue,
            "args": arguments.joined(separator: " "),
            "cwd": gameRoot.path,
            "gameHash": gameHash
        ])

        let process: Process
        do {
            process = try ChildProcessLauncher.launch(
                executable: executable,
                arguments: arguments,
                workingDirectory: gameRoot,
                logURL: logURL
            ).process
        } catch {
            throw MochiBoxError(
                code: .runtimeNotExecutable,
                message: "内置 EasyRPG 运行时启动失败：\(error.localizedDescription)",
                underlying: "\(error)"
            )
        }

        running[process.processIdentifier] = process
        ChildProcessRegistry.shared.register(process.processIdentifier)
        // `port: 0`：没有调试端口。`terminate` 只会判 `.embeddedKernel` / `.webBrowser`
        // 两个分支，新 transport 会落到通用 pid 分支 —— 这正是我们要的。
        let handle = LaunchHandle(
            pid: process.processIdentifier,
            port: 0,
            executableURL: executable,
            arguments: arguments,
            gameRoot: gameRoot,
            logURL: logURL,
            startedAt: Date(),
            transport: .nativeRuntime,
            web: nil,
            embedded: nil,
            closed: nil
        )
        log?.info("GameLauncher", "原生运行时已启动", [
            "pid": "\(handle.pid)",
            "engine": engine.rawValue,
            "save": saveRoot.path
        ])
        return handle
    }

    /// mkxp-z 启动（RGSS1/2/3）：单进程，没有调试端口、没有静态服务、没有 Agent。
    ///
    /// **挂载根 = 子进程的当前工作目录**。这不是猜的：`src/main.cpp` 在没有
    /// `WORKDIR_CURRENT` 时会把 cwd 强制成"可执行文件所在目录"（在 .app 里则是包外目录），
    /// 所以 `cd` 之后启动无效、`mkxp.json` 的 `gameFolder` 也只对包外二进制有效。
    /// 随包分发的 mkxp-z 用 `-Dworkdir_current=true` 构建（Scripts/fetch-mkxpz.sh），
    /// 这里把 `workingDirectory` 设成游戏目录即可。**不要**改成把二进制复制进游戏目录。
    ///
    /// 不传任何参数：mkxp-z 的 argv 只认 `debug` / `test` / `btest` 三个词，其余会被塞进
    /// Ruby 的 `$ARGV`；`--no-audio` 之类并不存在，传了等于给游戏塞脏参数。
    ///
    /// 每游戏数据目录：启动前在 `<gameRoot>/mkxp.json` 里注入
    /// `dataPathOrg`/`dataPathApp`（见 `MKXPZGameConfig`），退出时还原。
    /// 注入失败不挡启动，但一定留痕（会话日志 + NSLog）。
    ///
    /// **不承诺搬走 RGSS 存档**：mkxp-z 的 `Kernel#save_data` 按进程 cwd 写文件，
    /// 没有 savePath/环境变量入口；这里能隔离的是 mkxp-z 自己的每游戏数据目录。
    private func launchMKXPZ(
        executable: URL,
        engine: EngineKind,
        gameRoot: URL,
        log: SessionLog?
    ) throws -> LaunchHandle {
        try GameLauncher.validateMKXPZGameIni(gameRoot: gameRoot, engine: engine)

        paths.ensureDirectories()
        let gameHash = WebPortAssignments.gameHash(for: gameRoot)
        let logURL = paths.logsDirectory
            .appendingPathComponent("mkxpz-\(Timestamp.fileStamp())-\(gameHash.prefix(8)).log")

        // 每游戏数据目录的注入必须发生在 `Process.run()` **之前**：mkxp-z 只在 Config::read
        // 读一次 cwd 下的 mkxp.json，进程起来之后再写等于没写。
        let preparation = MKXPZGameConfig.prepare(
            gameRoot: gameRoot,
            gameHash: gameHash,
            stateRoot: paths.root
        )
        if let note = preparation.note {
            log?.warn("GameLauncher", "mkxp.json 未注入", ["reason": note])
            // `--play-native` 没有 SessionLog，失败原因只能走系统日志；静默失败等于"隔离悄悄没生效"。
            NSLog("MochiBox: mkxp.json 未注入：%@", note)
        }

        log?.info("GameLauncher", "启动 mkxp-z", [
            "exe": executable.path,
            "engine": engine.rawValue,
            "cwd": gameRoot.path,
            "gameHash": gameHash,
            "pref": MKXPZGameConfig.applicationName(gameHash: gameHash),
            "configInjected": preparation.overlay == nil ? "0" : "1"
        ])

        let process: Process
        do {
            process = try ChildProcessLauncher.launch(
                executable: executable,
                arguments: [],
                workingDirectory: gameRoot,
                logURL: logURL
            ).process
        } catch {
            // 进程没起来：覆盖必须当场还原，否则用户的 mkxp.json 会一直带着我们的两个键。
            if let overlay = preparation.overlay {
                _ = MKXPZGameConfig.restore(overlay)
            }
            throw MochiBoxError(
                code: .runtimeNotExecutable,
                message: "内置 mkxp-z 运行时启动失败：\(error.localizedDescription)",
                underlying: "\(error)"
            )
        }

        running[process.processIdentifier] = process
        ChildProcessRegistry.shared.register(process.processIdentifier)
        if let overlay = preparation.overlay {
            mkxpOverlays[process.processIdentifier] = overlay
        }
        let handle = LaunchHandle(
            pid: process.processIdentifier,
            port: 0,
            executableURL: executable,
            arguments: [],
            gameRoot: gameRoot,
            logURL: logURL,
            startedAt: Date(),
            transport: .nativeRuntime,
            web: nil,
            embedded: nil,
            closed: nil
        )
        log?.info("GameLauncher", "mkxp-z 已启动", ["pid": "\(handle.pid)", "engine": engine.rawValue])
        return handle
    }

    /// v0.2 的 Web 运行后端：起服务 + 拉浏览器，失败按矩阵回滚。
    private func launchWeb(
        webRoot: URL,
        engine: EngineKind,
        gameRoot: URL,
        options: LaunchOptions,
        log: SessionLog?
    ) async throws -> LaunchHandle {
        let debugPort = try allocatePort()

        let httpPort: Int
        do {
            httpPort = try await allocateWebPort(webRoot: webRoot)
        } catch {
            usedPorts.remove(debugPort)
            throw error
        }

        let key = RandomHex.make(16)
        paths.ensureDirectories()
        let gameHash = WebPortAssignments.gameHash(for: webRoot)
        let profileDir = paths.browserProfilesDirectory
            .appendingPathComponent(gameHash, isDirectory: true)
        let logURL = paths.logsDirectory
            .appendingPathComponent("browser-\(Timestamp.fileStamp())-\(debugPort).log")

        // Windows 版壳只记一行日志，不报错、不动用户盘上的文件（架构 §6.3）。
        let windowsShells = ["Game.exe", "nw.exe"]
        for shell in windowsShells {
            let shellURL = gameRoot.appendingPathComponent(shell)
            if FileManager.default.fileExists(atPath: shellURL.path) {
                log?.info("GameLauncher", "检测到 Windows 版启动器（本产品不需要 Wine，也不会运行它）", [
                    "windowsShell": shell
                ])
                break
            }
        }

        var extraArgs = options.extraBrowserArgs
        // 既有设置项复用（排障用）：只在没有显式传参时补上。
        let storedSettings = SettingsStore(
            settingsURL: paths.settingsURL,
            credentialsURL: paths.credentialsURL,
            log: nil
        ).loadSettings()
        if extraArgs.isEmpty {
            extraArgs = storedSettings.extraLaunchArgs
        }
        let configuredBrowserPath = storedSettings.browserPath

        let config = WebRunnerConfig(
            webRoot: webRoot,
            engine: engine,
            debugPort: debugPort,
            httpPort: httpPort,
            headless: options.headless,
            browserPathOverride: options.browserPathOverride,
            configuredBrowserPath: configuredBrowserPath,
            windowSize: options.windowSize,
            extraBrowserArgs: extraArgs,
            profileDir: profileDir,
            logURL: logURL,
            log: log
        )
        let runner = WebGameRunner(config: config)
        webRuns[key] = runner

        do {
            let run = try await runner.start()
            ChildProcessRegistry.shared.register(run.browserPid)
            let descriptor = WebRunDescriptor(
                sessionKey: key,
                httpPort: run.httpPort,
                webRoot: run.webRoot,
                pageURL: run.pageURL,
                profileDir: run.profileDir,
                browserBundlePath: AppBundleLocator.bundlePath(forExecutable: run.browserExecutable)
            )
            log?.info("GameLauncher", "Web 运行后端已启动", [
                "http": "\(run.httpPort)",
                "debug": "\(run.debugPort)",
                "page": run.pageURL,
                "gameHash": gameHash
            ])
            return LaunchHandle(
                pid: run.browserPid,
                port: run.debugPort,
                executableURL: run.browserExecutable,
                arguments: run.arguments,
                gameRoot: gameRoot,
                logURL: logURL,
                startedAt: Date(),
                transport: .webBrowser,
                web: descriptor,
                // 矩阵 E15：`--play` 拉起的页面要判"游戏真的在跑"；`--attach` 不会置它。
                requiresSceneProbe: options.requiresSceneProbe
            )
        } catch {
            // 回滚矩阵（架构 §6.4）：一条都不能漏，否则下一次启动就是假 `web_port_busy`。
            await runner.stop()
            webRuns.removeValue(forKey: key)
            usedPorts.remove(debugPort)
            await releaseWebSessionPort(httpPort, webRoot: webRoot)
            throw error
        }
    }

    // MARK: - 内置内核（v0.4）

    /// 内置内核启动：起静态服务 → 取内核 → 建窗。
    ///
    /// 与 `launchWeb` 的差异只有三处（架构 v0.4 §4.4）：
    ///   1. **没有 debugPort**（没有浏览器进程可调试），只有确定性的 httpPort（它是 origin）；
    ///   2. 内核来自 `KernelRegistry`，不是 `WebGameRunner` + `BrowserResolver`；
    ///   3. 句柄 `pid = 0`（写死，绝不 `getpid()`：`terminate` 的 `.nwjs` 分支会 `kill(pid)`）。
    ///
    /// 失败回滚与 `launchWeb` 同形：**一条都不能漏**，否则下一次启动就是假 `web_port_busy`。
    private func launchEmbedded(
        webRoot: URL,
        engine: EngineKind,
        gameRoot: URL,
        options: LaunchOptions,
        log: SessionLog?
    ) async throws -> LaunchHandle {
        let httpPort = try await allocateWebPort(webRoot: webRoot)
        let key = RandomHex.make(16)

        // 尺寸/标题来自 System.json（纯 IO，读不到就回落 816×624 并记 screen_fallback）。
        let metrics = GameScreenMetrics.read(gameRoot: gameRoot)
        if metrics.usedFallback {
            log?.info("GameLauncher", "游戏分辨率回落到默认值", [
                "screen_fallback": "\(metrics.screenWidth)x\(metrics.screenHeight)"
            ])
        }

        paths.ensureDirectories()
        let logURL = paths.logsDirectory
            .appendingPathComponent("kernel-\(Timestamp.fileStamp())-\(httpPort).log")
        let pageURL = "http://\(K.loopbackHost):\(httpPort)/\(K.webDirectoryIndexName)"

        let server = StaticWebServer(root: webRoot, port: httpPort, log: log)
        do {
            _ = try await server.start()
        } catch {
            await releaseWebSessionPort(httpPort, webRoot: webRoot)
            throw error
        }
        webServers[key] = server

        guard let kernel = await KernelRegistry.make() else {
            // E2：未注册 = 硬失败（不静默回退 Chromium：那会让用户要的"应用自己的窗口"悄悄失效）。
            await stopEmbeddedWebServer(key: key)
            await releaseWebSessionPort(httpPort, webRoot: webRoot)
            log?.error("GameLauncher", "内置内核未注册", ["kernel_reason": "not_registered"])
            throw MochiBoxError(
                code: .kernelLoadFailed,
                message: "内置浏览器内核未注册（kernel_reason=not_registered）"
            )
        }
        kernels[key] = kernel

        let agentScript: String
        do {
            agentScript = try AgentInjector.loadScript()
        } catch {
            kernels.removeValue(forKey: key)
            await kernel.closeWindow()
            await stopEmbeddedWebServer(key: key)
            await releaseWebSessionPort(httpPort, webRoot: webRoot)
            throw MochiBoxError(
                code: .kernelLoadFailed,
                message: "读取 agent_mvmz.js 失败（内置内核无法早装）",
                underlying: "\(error)"
            )
        }

        let closeSignal = WindowCloseSignal()
        let spec = EmbeddedKernelSpec(
            pageURL: pageURL,
            screenWidth: metrics.screenWidth,
            screenHeight: metrics.screenHeight,
            windowTitle: metrics.title,
            agentScript: agentScript,
            log: log,
            closeSignal: closeSignal
        )

        do {
            let opened = try await kernel.start(spec)
            log?.info("GameLauncher", "内置内核已启动", [
                "http": "\(httpPort)",
                "kernel": "embedded",
                "kernel_window_id": "\(opened.windowNumber)",
                "kernel_content": "\(opened.contentWidth)x\(opened.contentHeight)",
                "kernel_scale": "\(opened.backingScale)",
                "engine": engine.rawValue
            ])
            let descriptor = EmbeddedRunDescriptor(
                sessionKey: key,
                httpPort: httpPort,
                webRoot: webRoot,
                pageURL: pageURL,
                screenWidth: opened.contentWidth,
                screenHeight: opened.contentHeight,
                backingScale: opened.backingScale,
                windowNumber: opened.windowNumber,
                windowTitle: opened.title
            )
            return LaunchHandle(
                pid: 0,                       // ← 写死：内置内核没有可 kill 的子进程
                port: httpPort,
                executableURL: URL(fileURLWithPath: "/"),
                arguments: [],
                gameRoot: gameRoot,
                logURL: logURL,
                startedAt: Date(),
                transport: .embeddedKernel,
                web: nil,
                embedded: descriptor,
                closed: closeSignal,
                requiresSceneProbe: options.requiresSceneProbe
            )
        } catch {
            await kernel.closeWindow()
            kernels.removeValue(forKey: key)
            await stopEmbeddedWebServer(key: key)
            await releaseWebSessionPort(httpPort, webRoot: webRoot)
            throw error
        }
    }

    /// 内置内核的终止：幂等（复用 `terminatedSessions`），先关窗再停监听。
    private func terminateEmbedded(handle: LaunchHandle, descriptor embedded: EmbeddedRunDescriptor) async {
        let key = embedded.sessionKey
        guard !terminatedSessions.contains(key) else { return }
        terminatedSessions.insert(key)

        if let kernel = kernels[key] {
            await kernel.closeWindow()
            let deadline = Date().addingTimeInterval(K.killGraceSec)
            while Date() < deadline {
                if await kernel.isAlive() == false { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            kernels.removeValue(forKey: key)
        }

        await stopEmbeddedWebServer(key: key)

        // 只清运行期占位，持久记录保留（清了下次换端口 = 换 origin = 丢存档）。
        await releaseWebSessionPort(embedded.httpPort, webRoot: embedded.webRoot)
    }

    /// `MVAdapter.attach` 用 `sessionKey` 找回内核（Adapters 只认协议）。
    func embeddedKernel(sessionKey: String) -> (any EmbeddedKernelSession)? {
        return kernels[sessionKey]
    }

    /// 模拟"用户点红叉关窗"（欠账 D4：把矩阵 E12 从"只能人工点"变成自动门禁）。
    ///
    /// 三个刻意的约束：
    ///   1. **只关窗**：不动静态服务、不动端口、不写 `terminatedSessions` —— 资源回收仍归
    ///      `terminate()`。这里若顺手把服务也停了，`--play` 收尾会拿到一个已被拆掉的会话，
    ///      症状是下一次启动假 `web_port_busy`。
    ///   2. **走内核的用户分支**：`simulateUserClose()` 而不是 `closeWindow()`，
    ///      否则日志会是 `reason=programmatic`，E12 真实路径一条也没走到。
    ///   3. 非 embedded（Chromium / nwjs）没有应用内窗口 → 空操作。日志由调用方打
    ///      （本类是 actor，手上没有 `SessionLog`；Adapters 层也不该直接 print）。
    func simulateUserClose(_ handle: LaunchHandle) async {
        guard let embedded = handle.embedded else { return }
        guard let kernel = kernels[embedded.sessionKey] else { return }
        await kernel.simulateUserClose()
    }

    // MARK: - 会话回收（端口 / 监听 / 会话表）

    /// 释放一次 Web 会话占用的静态服务端口：**内存占位 + 持久分配表**。
    ///
    /// 两件事必须成对发生。源码里原本这两行在 7 条失败/收尾路径上各抄一遍，
    /// 漏掉任意一行，下一次启动就是假 `web_port_busy`（或换端口 = 换 origin = 丢存档）。
    ///
    /// 刻意**不**把 debugPort / 浏览器进程 / 内核一起塞进来：那几样在不同路径上
    /// 归属不同（有的归 WebGameRunner、有的归 webServers/kernels），合并就会改变顺序。
    private func releaseWebSessionPort(_ httpPort: Int, webRoot: URL) async {
        usedWebPorts.remove(httpPort)
        await webPorts.release(webRoot: webRoot)
    }

    /// 停掉内置内核路径的静态服务并摘表。
    ///
    /// 顺序不能反：先 `stop()`（等在飞连接与监听器收干净）再摘表，
    /// 否则同端口的下一次绑定会撞上"看起来空闲但监听器还没释放"。
    private func stopEmbeddedWebServer(key: String) async {
        if let server = webServers[key] {
            await server.stop()
        }
        webServers.removeValue(forKey: key)
    }

    // MARK: - 终止

    /// 分流：`.embeddedKernel` **必须排在最前**（它 `pid == 0`，掉进 `.nwjs` 分支
    /// 会去 `kill(0, SIGTERM)` = 杀自己/杀整个进程组）。
    func terminate(_ handle: LaunchHandle) async {
        if handle.transport == .embeddedKernel, let embedded = handle.embedded {
            await terminateEmbedded(handle: handle, descriptor: embedded)
            return
        }
        if handle.transport == .webBrowser, let web = handle.web {
            await terminateWeb(handle: handle, descriptor: web)
            return
        }
        guard handle.pid > 0 else {
            usedPorts.remove(handle.port)
            return
        }
        if let process = running[handle.pid] {
            // 宽限 3s、100ms 轮询 —— 与原实现同值，不要归一化。
            await ProcessTerminator.terminateAsync(
                pid: handle.pid,
                graceSec: K.killGraceSec,
                pollMs: 100,
                isAlive: { _ in process.isRunning }
            )
            running.removeValue(forKey: handle.pid)
        } else {
            // 没有 Process 对象可探测：只睡满宽限再补一刀（pollMs: 0 = 固定等待）。
            await ProcessTerminator.terminateAsync(
                pid: handle.pid,
                graceSec: K.killGraceSec,
                pollMs: 0
            )
        }
        usedPorts.remove(handle.port)
        ChildProcessRegistry.shared.unregister(handle.pid)
        restoreMKXPOverlay(pid: handle.pid)
    }

    /// 还原 mkxp-z 的 `mkxp.json` 覆盖（没登记过就是空操作）。
    ///
    /// 位置在通用 pid 收尾里：`--play-native`、GUI 的 `MKXPZAdapter.stop`、以及
    /// "进程自己先退出、随后才 terminate" 都走这里。进程被 SIGKILL / 本进程崩溃时走不到，
    /// 那种残骸由下一次 `MKXPZGameConfig.prepare` 的崩溃恢复兜住。
    private func restoreMKXPOverlay(pid: Int32) {
        guard let overlay = mkxpOverlays.removeValue(forKey: pid) else { return }
        if let note = MKXPZGameConfig.restore(overlay) {
            NSLog("MochiBox: mkxp.json 还原提示：%@", note)
        }
    }

    /// Web 句柄的终止：幂等（第二次直接返回，绝不 kill 一个可能已被复用的 pid）。
    private func terminateWeb(handle: LaunchHandle, descriptor web: WebRunDescriptor) async {
        let key = web.sessionKey
        guard !terminatedSessions.contains(key) else { return }
        terminatedSessions.insert(key)

        if let runner = webRuns[key] {
            await runner.stop()
            webRuns.removeValue(forKey: key)
        } else if handle.pid > 0 {
            // runner 已不在（进程内重建等）：按 pid 兜底收。
            // pollMs: 0 = 只睡满宽限、无条件补 SIGKILL（原有语义）。
            await ProcessTerminator.terminateAsync(
                pid: handle.pid,
                graceSec: K.killGraceSec,
                pollMs: 0
            )
        }

        ChildProcessRegistry.shared.unregister(handle.pid)
        usedPorts.remove(handle.port)
        // 只清运行期占位，持久记录保留（清了下次换端口 = 换 origin = 丢存档）。
        await releaseWebSessionPort(web.httpPort, webRoot: web.webRoot)
    }

    func isRunning(pid: Int32) -> Bool {
        guard let process = running[pid] else { return false }
        return process.isRunning
    }

    /// 排障：当前登记的 Web 会话数。
    func activeWebSessions() -> Int {
        return webRuns.count
    }
}
