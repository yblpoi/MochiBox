//
//  KernelSmokeMain.swift
//  MochiBox
//
//  `--kernel-smoke <游戏目录>`（T03 的强制冒烟，诊断入口，与 `--selftest` 同级）。
//
//  它存在的唯一理由：在**最小内核**上单独排除两类"窗口在、`didFinish` 成功、游戏不动"的
//  配置漏项（BUG-12 那个假成功形状）——
//    1. `configuration.mediaTypesRequiringUserActionForPlayback = []`
//       缺了 → 开场 WebM 抛 `NotAllowedError` → MZ 的 `catchNormalError` 把错误页画出来；
//    2. `WKUserScript(source:, injectionTime: .atDocumentStart)` **在 `WKWebView(frame:)` 之前**
//       加进 `configuration.userContentController`
//       晚了 → 首屏（LOGO/标题菜单/开场对白）整段漏采。
//
//  **这两条配置不再由本文件自己写**（欠账 D1 / 架构 §3.6）：它们由
//  `KernelWebViewConfiguration.make(userScripts:)` 统一产出，产品路径与诊断路径共用，
//  本文件的差异位只有"注入哪些脚本"。
//
//  "最小内核"是刻意的：这里**不注入** `agent_mvmz.js`。要验的是内核配置本身，
//  把 Agent 混进来，一旦失败就分不清是"内核配错了"还是"注入脚本有问题"。
//  注入标记改用一个 4 行的小脚本（`window.__mochiboxSmokeAt = 'documentStart'`），
//  它的存在**就是**"`atDocumentStart` 真的生效了"的证据。
//
//  判据（任一不达标 → 非 0 退出）：
//    - `scene != none`（`SceneManager._scene` 有值；**不白名单场景名**，本作 97 个插件会自造 `Scene_*`）
//    - `canvas == <System.json 的 screenWidth>x<screenHeight>`（渲染分辨率对上了）
//    - 页面里存在 `video` 时，`readyState >= 2 && paused == false`（自动播放真的开了）
//      —— 没 `video` 元素**不判失败**（`video=absent`）：并非每款游戏都有开场影片。
//      但这是**盲区**，不是通过：summary 行尾的 `autoplay=skipped(no_video)` 就是那条声明
//      （欠账 D5：任何报告都不得再把这种 PASS 说成"自动播放已验证"）。
//    - `startup_script == documentStart`（`atDocumentStart` 注入生效）
//
//  三条"不许"（team-lead 第 2 条增量）：
//    1. **不进** `AttachCLI` 的参数面（`--play` 的参数面一个字段都不许变）；
//    2. **不进** `environmentCodes`（它是诊断，不是"换个环境就好"的环境缺口）；
//    3. **不许**塞进 `SelfTestRunner` 当 case（会把 `--selftest` 从 45 条变成 46 条 = 动基线）。
//
//  本文件属于 `Sources/UI/**`：分层门禁（`Scripts/build.sh:27-35`）允许这里 import AppKit/WebKit。
//

import Foundation
import AppKit
import CoreGraphics
import WebKit

// MARK: - 入口

enum KernelSmokeMain {

    /// 冒烟入口。**不返回**（`NSApplication.run()` 之后由 `exit()` 收尾）。
    ///
    /// 用法：`MochiBox --kernel-smoke <游戏目录> [--timeout 秒]`
    /// 退出码：0 = 全中；1 = 判据未满足；2 = 参数/环境问题；3 = 没有 Aqua 桌面会话。
    static func bootstrap(_ arguments: [String]) -> Never {
        guard let config = parse(arguments) else {
            FileHandle.standardError.write(Data((usage() + "\n").utf8))
            exit(2)
        }

        let root = URL(
            fileURLWithPath: (config.gamePath as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        let indexURL = root.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            print("smoke failed: 游戏目录不可用：\(indexURL.path) 不存在")
            fflush(stdout)
            exit(2)
        }

        // 与 `--play` 的内核路径同一条门禁：没有登录桌面就不假装窗口开了（矩阵 E1）。
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("smoke failed: 没有 Aqua 桌面会话（kernel_reason=no_aqua）")
            fflush(stdout)
            exit(3)
        }

        let metrics = GameScreenMetrics.read(gameRoot: root)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        Task { @MainActor in
            let code = await run(root: root, metrics: metrics, timeoutSec: config.timeoutSec)
            fflush(stdout)
            exit(code)
        }
        application.run()
        exit(0)
    }

    // MARK: - 参数

    struct Config {
        var gamePath: String
        var timeoutSec: Double
    }

    static func usage() -> String {
        return "用法: MochiBox --kernel-smoke <游戏目录> [--timeout 秒]\n"
            + "  诊断入口：在最小内核（不注 Agent）上验证自动播放与 atDocumentStart 注入。\n"
            + "  打印 scene= canvas= video= video_ready= video_paused= startup_script= autoplay=，失败非 0 退出。\n"
            + "  注意：页面里没有视频元素（DOM 或 PIXI 纹理缓存）时打 autoplay=skipped(no_video) —— 这种情况 exit 0，"
            + "但**自动播放这一条没有被验证**，不能当作已验证。"
    }

    /// 解析 `--kernel-smoke <目录> [--timeout N]`。
    ///
    /// 刻意**不复用** `AttachCLI.parse`：那个解析器是 `--play` / `--attach` 的产品参数面，
    /// 让诊断入口去改它，等于把"诊断"和"产品"耦合起来（team-lead 第 2 条增量的第 1 条禁令）。
    static func parse(_ arguments: [String]) -> Config? {
        guard let flagIndex = arguments.firstIndex(of: "--kernel-smoke") else { return nil }
        var path: String?
        var timeout: Double = K.kernelSmokeTimeoutSec
        var index = flagIndex + 1
        while index < arguments.count {
            let item = arguments[index]
            if item == "--timeout" {
                guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value > 0 else {
                    return nil
                }
                timeout = value
                index += 2
                continue
            }
            if item.hasPrefix("--") { return nil }
            if path == nil {
                path = item
            } else {
                return nil
            }
            index += 1
        }
        guard let gamePath = path, !gamePath.isEmpty else { return nil }
        return Config(gamePath: gamePath, timeoutSec: timeout)
    }

    // MARK: - 冒烟主体

    @MainActor
    private static func run(root: URL, metrics: GameScreenMetrics, timeoutSec: Double) async -> Int32 {
        // 端口：`--kernel-smoke` 不进端口分配表（那张表是给产品路径存档 origin 用的），
        // 这里只在调试区间之外找一个空闲端口，用完即关。
        guard let port = pickFreePort() else {
            print("smoke failed: 找不到空闲回环端口（39500–39599 全占）")
            return 2
        }
        let server = StaticWebServer(root: root, port: port, log: nil)
        // `StaticWebServer` 是 actor：端口只能在 `start()` 的返回值里拿，
        // 不能事后读 `server.port`（跨隔离域，编译器直接拒）。
        let boundPort: Int
        do {
            boundPort = try await server.start()
            print("smoke: root=\(root.path) port=\(boundPort) content=\(metrics.screenWidth)x\(metrics.screenHeight)"
                + " title=\(metrics.title) screen_fallback=\(metrics.usedFallback)")
            fflush(stdout)
        } catch {
            print("smoke failed: 静态服务起不来（\(error)）")
            return 2
        }

        let watcher = SmokeNavWatcher()
        let webView = makeWebView(metrics: metrics, watcher: watcher)
        let window = makeWindow(metrics: metrics, webView: webView, title: metrics.title)

        guard let url = URL(string: "http://\(K.loopbackHost):\(boundPort)/index.html") else {
            await server.stop()
            print("smoke failed: 页面地址拼不出来（port=\(boundPort)）")
            return 2
        }
        webView.load(URLRequest(url: url))

        // 等首次导航有结论（`didFinish` / `didFail` / 超时）。
        // **`didFinish` 不是成功判据**：MZ 的黑底黄字 Error 页照样 `didFinish`。
        // 这里只等"内核不再 loading"，成功与否由下面的 scene/canvas/video 判。
        var navWaited: Double = 0
        while !watcher.isSettled, navWaited < K.webBrowserReadyTimeoutSec {
            try? await Task.sleep(nanoseconds: 50_000_000)
            navWaited += 0.05
        }
        if let failure = watcher.failureText {
            // 导航层直接失败（连不上静态服务等）：不用再等，直接报。
            window.close()
            await server.stop()
            print("smoke failed: 首次导航失败（\(failure)）")
            return 1
        }

        // 轮询判据。本作从 boot 到 `Scene_Map` 实测 1–2s；给到 timeoutSec 是因为
        // 影片/插件初始化在各游戏间差异很大（本作 OP 约 135s，但它在 `Scene_Map` 里播）。
        let deadline = Date().addingTimeInterval(timeoutSec)
        var last = SmokeObservation.empty
        var lastLine = ""
        while true {
            last = await observe(webView: webView, metrics: metrics)
            let line = last.summary
            if line != lastLine {
                print("smoke: \(line)")
                fflush(stdout)
                lastLine = line
            }
            if last.isSatisfied(metrics: metrics) { break }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        window.close()
        await server.stop()

        if last.isSatisfied(metrics: metrics) {
            print("smoke: PASS \(last.summary)")
            return 0
        }
        print("smoke: FAIL reason=\(last.failureReason(metrics: metrics)) \(last.summary)")
        return 1
    }

    /// 39500–39599 里线性找一个空闲端口（与产品端口区间 39310–39409 不重叠）。
    private static func pickFreePort() -> Int? {
        for port in 39500...39599 where LoopbackPort.isFree(port) {
            return port
        }
        return nil
    }

    @MainActor
    private static func makeWebView(metrics: GameScreenMetrics, watcher: SmokeNavWatcher) -> WKWebView {
        // 配置来自**唯一**工厂（架构 v0.4 §3.6 / 欠账 D1）：与产品路径 `WKEmbeddedKernel` 共用
        // 同一份开关，差异位只有"注入哪些脚本"（这里注 marker，产品注 `agent_mvmz.js`）。
        //
        // 坑 2：`addUserScript` **必须**在 `WKWebView(frame:configuration:)` 之前。
        // 工厂内部就注册好了脚本，所以下面这行的顺序是硬保证，不靠调用方记性。
        // 这个 4 行脚本只做一件事：证明"注入时刻真的是 documentStart"。
        let marker = KernelWebViewConfiguration.documentStartScript("window.__mochiboxSmokeAt = 'documentStart';")
        let configuration = KernelWebViewConfiguration.make(userScripts: [marker])

        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(max(1, metrics.screenWidth)),
            height: CGFloat(max(1, metrics.screenHeight))
        )
        let webView = WKWebView(frame: contentRect, configuration: configuration)
        webView.navigationDelegate = watcher
        webView.allowsMagnification = false
        return webView
    }

    @MainActor
    private static func makeWindow(
        metrics: GameScreenMetrics,
        webView: WKWebView,
        title: String
    ) -> NSWindow {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(max(1, metrics.screenWidth)),
            height: CGFloat(max(1, metrics.screenHeight))
        )
        // 与产品路径**同一条 styleMask**（不含 `.resizable`）：冒烟要验的是产品窗口的形状，
        // 换一个可缩放窗口去测，测出来的东西跟产品无关。
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "kernel-smoke · \(title)"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setContentSize(NSSize(width: contentRect.width, height: contentRect.height))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    // MARK: - 观测

    /// 一次观测的原始值（全部来自页面，不在本进程里推断）。
    struct SmokeObservation: Sendable {
        var scene: String
        var canvas: String
        var video: String
        var videoReady: String
        var videoPaused: String
        var startupScript: String

        static let empty = SmokeObservation(
            scene: "none",
            canvas: "none",
            video: "none",
            videoReady: "none",
            videoPaused: "true",
            startupScript: "none"
        )

        /// 与 `docs/archive/v0.4/architecture-v0.4-embedded-kernel.md` §5.2 E15 / team-lead 裁决同格式：
        /// `scene=… canvas=WxH video=<readyState>/<paused>/<error> video_ready=… video_paused=… startup_script=… autoplay=…`
        ///
        /// `autoplay=` 是**追加**在行尾的新字段（欠账 D5）：`video=absent` 时旧 summary 与
        /// PASS 行完全一样，读的人分不清"自动播放验过了"和"页面里根本没有影片"。
        /// 现在把盲区写在报告里：`autoplay=verified` / `autoplay=skipped(no_video)` / `autoplay=unverified`。
        var summary: String {
            return "scene=\(scene) canvas=\(canvas) video=\(video) video_ready=\(videoReady)"
                + " video_paused=\(videoPaused) startup_script=\(startupScript)"
                + " autoplay=\(autoplay)"
        }

        /// 自动播放这一条判据到底"验过没有"（欠账 D5）。
        ///
        /// 三种取值，缺一不可：
        ///   · `verified` —— 页面里真有视频元素（DOM ∪ PIXI 纹理缓存），且 `readyState >= 2 && paused == false`
        ///     （这是"自动播放真的开了"的唯一证据）；
        ///   · `skipped(no_video)` —— 页面里没有任何视频元素（DOM 与 PIXI 缓存都没有）。**这不等于通过验证**：
        ///     没有影片的游戏不该判失败（判据不收紧），但报告必须明说这一条没验到；
        ///   · `unverified` —— 有 `<video>` 但没达到播放条件。此时 `isSatisfied` 已经返回 false，
        ///     这里记 `unverified` 而不是"verified"，避免失败行被读成"自动播放正常"。
        var autoplay: String {
            if video == "absent" { return "skipped(no_video)" }
            guard let ready = Int(videoReady), ready >= 2, videoPaused == "false" else {
                return "unverified"
            }
            return "verified"
        }

        func isSatisfied(metrics: GameScreenMetrics) -> Bool {
            guard scene != "none" else { return false }
            guard canvas == "\(metrics.screenWidth)x\(metrics.screenHeight)" else { return false }
            guard startupScript == "documentStart" else { return false }
            // 没有任何视频元素不算失败（并非每款游戏都有开场影片）——**判据不收紧**。
            // 但这一条不是"验过了"：盲区由 `autoplay=skipped(no_video)` 显式写在报告里，
            // 任何读报告的人都不得再把这种 PASS 说成"自动播放已验证"（欠账 D5）。
            if video == "absent" { return true }
            guard let ready = Int(videoReady), ready >= 2 else { return false }
            return videoPaused == "false"
        }

        func failureReason(metrics: GameScreenMetrics) -> String {
            if scene == "none" { return "scene=none（SceneManager 没有场景：内核连上了但游戏没跑起来）" }
            if canvas != "\(metrics.screenWidth)x\(metrics.screenHeight)" {
                return "canvas=\(canvas) 与 System.json 的 \(metrics.screenWidth)x\(metrics.screenHeight) 不一致（画面会被拉伸）"
            }
            if startupScript != "documentStart" {
                return "startup_script=\(startupScript)（WKUserScript 不是 documentStart 生效：首屏会漏采）"
            }
            if video != "absent" {
                if let ready = Int(videoReady), ready < 2 {
                    return "video.readyState=\(videoReady)（自动播放没开或影片没加载：检查 mediaTypesRequiringUserActionForPlayback）"
                }
                if videoPaused == "true" {
                    return "video.paused=true（影片被拦下了：检查 mediaTypesRequiringUserActionForPlayback）"
                }
            }
            return "未知不达标"
        }
    }

    /// 页面侧一条表达式取全部观测量（一次往返，避免"scene 与 video 不是一个时刻"）。
    ///
    /// 为什么不用白名单场景名：本作 97 个插件会自造 `Scene_*`，白名单必然误判；
    /// 判据只看"非 none"（外加 v0.4 §5.2 E15 的 `Scene_Boot` 停滞判定，那在 `--play` 侧）。
    ///
    /// 视频来源是 **DOM ∪ PIXI 纹理缓存**（同 `EngineAdapter.sceneProbeScript` 的理由）：
    /// MZ 影片插件普遍 `createElement('video')` 后不 appendChild，只查 DOM 会把
    /// "正在播 1280×720 影片"误报成 `video=absent` / `readyState=0` 并 FAIL。
    /// PIXI 5 的非 DOM 视频纹理在 `PIXI.utils.BaseTextureCache`（BaseTexture）与
    /// `PIXI.utils.TextureCache`（Texture→`.baseTexture`）里，两处都兜、按元素引用去重；
    /// PIXI / HTMLVideoElement 缺失时安静退回只数 DOM，绝不抛（抛了整条观测变 `.empty`）。
    /// 取值优先级：第一个 `readyState >= 2` 的元素 → 第一个元素 → absent。
    static let observationScript: String = """
    (function(){
      var scene = (typeof SceneManager !== 'undefined' && SceneManager._scene)
        ? SceneManager._scene.constructor.name : 'none';
      var canvas = document.querySelector('canvas');
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
      var video = null;
      for (var j = 0; j < pool.length; j++) {
        if (pool[j].readyState >= 2) { video = pool[j]; break; }
      }
      if (!video && pool.length) video = pool[0];
      return [
        scene,
        canvas ? (canvas.width + 'x' + canvas.height) : 'none',
        video ? ('r' + video.readyState) : 'absent',
        video ? String(video.readyState) : 'none',
        video ? String(video.paused) : 'true',
        (window.__mochiboxSmokeAt || 'none')
      ].join('|');
    })()
    """

    @MainActor
    private static func observe(webView: WKWebView, metrics: GameScreenMetrics) async -> SmokeObservation {
        do {
            let value = try await webView.evaluateJavaScript(observationScript)
            guard let text = value as? String else { return .empty }
            let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6 else { return .empty }
            // `parts[2]` 是 `r<readyState>` / `absent`，用于 summary 里给"有没有 video 元素"一个短标记；
            // 真正的数值在 `parts[3]`。
            let videoToken = parts[2].hasPrefix("r") ? parts[3] : parts[2]
            return SmokeObservation(
                scene: parts[0],
                canvas: parts[1],
                video: videoToken,
                videoReady: parts[3],
                videoPaused: parts[4],
                startupScript: parts[5]
            )
        } catch {
            return .empty
        }
    }
}

// MARK: - 导航观察者

/// 只记录"首次导航有没有结论"，**不**承担成功判据。
///
/// 为什么用 `NSLock` 而不是 `@MainActor` 状态：`WKNavigationDelegate` 的回调是
/// nonisolated 的，起 `Task { @MainActor in … }` 去写状态会让 `run()` 里的轮询
/// 与回调竞争（读到旧值再判定，就是 BUG-12 同型的假成功）。
final class SmokeNavWatcher: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Bool = false
    private var failure: String?

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    var failureText: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    private func settle(failure text: String?) {
        lock.lock()
        if !settled {
            settled = true
            failure = text
        }
        lock.unlock()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 只代表"导航结束了"，不代表"游戏跑起来了"（错误页也会走到这里）。
        settle(failure: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(failure: "\((error as NSError).domain)/\((error as NSError).code)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        settle(failure: "\((error as NSError).domain)/\((error as NSError).code)")
    }
}
