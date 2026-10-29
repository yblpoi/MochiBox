//
//  WKEmbeddedKernel.swift
//  MochiBox
//
//  内置 WebKit 内核（架构 v0.4 §4.3）：一个 **NSWindow + WKWebView**，内容区点尺寸 = 游戏分辨率。
//
//  三条 Retina 硬规则（§4.3，缺一条画面就糊或留边）：
//    1. **点 = 游戏分辨率**：`contentRect` 用 `System.json` 的 `screenWidth/Height`（单位点），
//       `styleMask` **不含 `.resizable`** —— 一拉大，MZ 的 `Graphics._canvas` 会被 CSS 拉伸。
//    2. **不碰 `backingType` / `pageZoom` / `magnification`**：WebKit 自己按
//       `devicePixelRatio = backingScaleFactor` 渲染，Retina 上 `_realCanvas` 自动是 1632×1248。
//    3. **截图/像素判据必须乘 `backingScale`**（`screencapture` 出来是 816×624 × 2）。
//
//  隔离：`NSWindow` / `WKWebView` 只能主线程。本类**不在类型上标 `@MainActor`**
//  （否则 `WKNavigationDelegate` 的 nonisolated 回调无法读自己的状态），而是把所有
//  AppKit/WebKit 访问收进 `@MainActor` 私有方法，对外入口保持 nonisolated + hop。
//

import Foundation
import AppKit
import WebKit

final class WKEmbeddedKernel: NSObject, @unchecked Sendable, EmbeddedKernelSession {
    // 下面这些状态**只**在主线程读写（所有 @MainActor 方法）。
    private var window: NSWindow?
    private var webView: WKWebView?
    private var channel: WKPageChannel?
    private var closeSignal: WindowCloseSignal?
    private var log: SessionLog?
    private var windowTitle: String = ""
    /// 主动关窗标记：区分"我们关的"与"用户点红叉"（§4.3 关闭回传）。
    private var isProgrammaticClose: Bool = false

    /// 首次导航的结果（`start()` 用它决定要不要抛错）。
    private enum NavigationOutcome {
        case loading
        /// 打开成功（**注意：这不是"跑通"的判据**，错误页也会触发 `didFinish`）
        case finished
        case failed(MochiBoxError)
    }

    private var navigation: NavigationOutcome = .loading

    // MARK: - EmbeddedKernelSession

    func start(_ spec: EmbeddedKernelSpec) async throws -> EmbeddedKernelHandle {
        return try await startOnMain(spec)
    }

    func makeChannel() async -> any PageChannel {
        return await makeChannelOnMain()
    }

    func snapshotPNG() async throws -> Data? {
        return try await snapshotOnMain()
    }

    func closeWindow() async {
        await closeWindowOnMain()
    }

    func isAlive() async -> Bool {
        return await isAliveOnMain()
    }

    /// 模拟"用户点红叉关窗"（欠账 D4：把矩阵 E12 变成自动门禁）。
    ///
    /// **必须**走 `windowWillClose` 的**用户关闭**分支：`isProgrammaticClose = false` 之后
    /// 再 `window.close()`，于是 `reason=user`。这里刻意**不复用** `closeWindowOnMain()` ——
    /// 那条是 `reason=programmatic`，测的是我们自己关窗的路径，E12 量不到任何东西。
    func simulateUserClose() async {
        await simulateUserCloseOnMain()
    }

    // MARK: - 起窗

    @MainActor
    private func startOnMain(_ spec: EmbeddedKernelSpec) async throws -> EmbeddedKernelHandle {
        guard let url = URL(string: spec.pageURL), url.scheme != nil else {
            throw MochiBoxError(
                code: .kernelLoadFailed,
                message: "非法的页面地址：\(spec.pageURL)（kernel_reason=navigation）"
            )
        }
        self.closeSignal = spec.closeSignal
        self.log = spec.log
        self.windowTitle = spec.windowTitle
        self.isProgrammaticClose = false
        self.navigation = .loading

        // 配置来自**唯一**工厂（架构 v0.4 §3.6 / 欠账 D1）：本路径与 `--kernel-smoke` 共用
        // 同一份开关，差异位只有"注入哪些脚本"。这里绝不再自己新建一份 configuration：
        // 一旦两份漂移，`--kernel-smoke` 的 PASS 就不能迁移到这条产品路径。
        //
        // **早装**（`Page.addScriptToEvaluateOnNewDocument` 的等价物）：脚本在工厂里就已注册进
        // configuration，所以下面 `WKWebView(frame:configuration:)` 一定晚于它 ——
        // 否则首屏（标题菜单 / 开场对白）漏采，整轮 captured 只剩 boot 期杂字（v0.2 的根因）。
        var userScripts: [WKUserScript] = []
        if !spec.agentScript.isEmpty {
            userScripts.append(KernelWebViewConfiguration.documentStartScript(spec.agentScript))
        }
        let configuration = KernelWebViewConfiguration.make(userScripts: userScripts)

        let width = CGFloat(max(1, spec.screenWidth))
        let height = CGFloat(max(1, spec.screenHeight))
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)

        // **不设置 `customUserAgent`**：默认 UA 里没有 HeadlessChrome、没有 automation 痕迹，
        // 而 MZ 的 `Utils.isMobileDevice` 只认 iPhone/iPad/Android，不会命中。
        let webView = WKWebView(frame: contentRect, configuration: configuration)
        webView.allowsMagnification = false            // 双指缩放会改布局
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self

        // `styleMask` **不含 `.resizable`**：见文件头第 1 条。
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = spec.windowTitle
        // `isReleasedWhenClosed = false`：否则 ARC 下会二次释放崩溃。
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 直接当 contentView（**不要**塞 NSScrollView，否则多出滚动条与 4px 边距）。
        window.contentView = webView
        window.setContentSize(NSSize(width: width, height: height))
        window.center()

        self.window = window
        self.webView = webView

        webView.frame = window.contentView?.bounds ?? contentRect

        // 上屏三连（顺序是刻意的，见 §4.3 与 team-lead 的窗口上屏实验）：
        //   `makeKeyAndOrderFront` 只对"已经是 key window 的 app"生效；
        //   `--play` 是裸二进制（不是 .app 启动），`activate(ignoringOtherApps:)` 经常
        //   不把窗口带到前台 → 窗口被 IDE/终端挡住 → WebKit 停 rAF/合成 → 画面停在 boot，
        //   症状是"标题、尺寸都对，`screencapture` 出来全黑"。
        //   `orderFrontRegardless()` 不依赖 app 是否激活，是唯一无条件把窗口提上来的调用。
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()

        log?.info("WKEmbeddedKernel", "内置内核窗口已创建", [
            "window_id": "\(window.windowNumber)",
            "title": spec.windowTitle,
            "content": "\(spec.screenWidth)x\(spec.screenHeight)",
            "scale": "\(window.backingScaleFactor)",
            "page": spec.pageURL
        ])

        webView.load(URLRequest(url: url))

        // 等首次导航有结论（成功 / 失败 / 超时）。**`didFinish` 只用来结束等待**：
        // 错误页同样会 `didFinish`，所以"跑通"的判据永远是 `captured > 0`（不在这里）。
        var waited: Double = 0
        while case .loading = navigation, waited < K.webBrowserReadyTimeoutSec {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        switch navigation {
        case .failed(let error):
            throw error
        case .loading:
            log?.error("WKEmbeddedKernel", "首次导航超时", [
                "nav_error": "timeout",
                "timeout": "\(Int(K.webBrowserReadyTimeoutSec))"
            ])
            throw MochiBoxError(
                code: .kernelLoadFailed,
                message: "内置内核首次导航超时（kernel_reason=navigation nav_error=timeout）"
            )
        case .finished:
            break
        }

        // `System.json` 只是**先验**：MV 的 canvas 固定 816×624（插件可改 `boxWidth`），
        // 而发行版里的 `System.json` 未必和它一致。窗口小于画布时 CSS 会把画面裁掉，
        // 症状是右侧/底部少一截、按钮点不到（"部分游戏分辨率有问题"）。
        // 导航完成后读一次**运行时**画布，只放大不缩小（缩小会让 MZ 画面突然变小）。
        let fitted = await fitWindowToCanvas(
            window: window,
            webView: webView,
            initialWidth: width,
            initialHeight: height
        )

        // `windowNumber` 只有 `makeKeyAndOrderFront` 之后才有效，所以这里才读（AC-8 的 window_id）。
        return EmbeddedKernelHandle(
            windowNumber: window.windowNumber,
            contentWidth: Int(fitted.width.rounded()),
            contentHeight: Int(fitted.height.rounded()),
            backingScale: Double(window.backingScaleFactor),
            title: spec.windowTitle
        )
    }

    // MARK: - 运行时尺寸校正

    /// 读页面里**实际**画布尺寸，并把窗口放大到能完整容纳它。
    ///
    /// 判据优先级：`Graphics.boxWidth/boxHeight`（MV/MZ 的逻辑分辨率）→
    /// `document.querySelector('canvas')` 的 CSS 尺寸。两者都取不到就用调用方给的先验值。
    ///
    /// **只放大不缩小**：MZ 会把 canvas 的 CSS 尺寸拉伸到窗口大小（probe 得到的就是当前窗口），
    /// 一旦允许缩小，第二次导航/重绘后窗口会被越收越小。
    @MainActor
    private func fitWindowToCanvas(
        window: NSWindow,
        webView: WKWebView,
        initialWidth: CGFloat,
        initialHeight: CGFloat
    ) async -> NSSize {
        let probe = """
        (function () {
          try {
            var g = window.Graphics;
            if (g && g.boxWidth > 0 && g.boxHeight > 0) {
              return String(g.boxWidth) + 'x' + String(g.boxHeight);
            }
            var canvas = document.querySelector('canvas');
            if (canvas) {
              var rect = canvas.getBoundingClientRect();
              if (rect.width > 0 && rect.height > 0) {
                return String(Math.round(rect.width)) + 'x' + String(Math.round(rect.height));
              }
            }
          } catch (e) {}
          return '';
        })()
        """

        var target = NSSize(width: initialWidth, height: initialHeight)
        // 页面刚 `didFinish` 时 `Graphics` 可能还没建好：短轮询 1s，读不到就保持先验值。
        for _ in 0..<10 {
            if let text = await evaluateStringOnMain(probe), let parsed = Self.parseCanvasSize(text) {
                target.width = max(initialWidth, parsed.width)
                target.height = max(initialHeight, parsed.height)
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // 别把窗口撑到屏幕外：超出的部分连标题栏都抓不到。
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            target.width = min(target.width, max(320, visible.width - 40))
            target.height = min(target.height, max(240, visible.height - 80))
        }

        if abs(target.width - initialWidth) > 0.5 || abs(target.height - initialHeight) > 0.5 {
            window.setContentSize(target)
            window.center()
            log?.info("WKEmbeddedKernel", "按运行时画布校正窗口尺寸", [
                "from": "\(Int(initialWidth))x\(Int(initialHeight))",
                "to": "\(Int(target.width))x\(Int(target.height))"
            ])
        }
        return target
    }

    /// 在页面里求值并取字符串结果（超时 1s，失败即 nil —— 尺寸校正不该拖住启动）。
    @MainActor
    private func evaluateStringOnMain(_ expression: String) async -> String? {
        guard let webView = webView else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var resumed = false
            webView.evaluateJavaScript(expression) { value, _ in
                if resumed { return }
                resumed = true
                continuation.resume(returning: value as? String)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if resumed { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// 解析 `"816x624"`。脏值（空串 / 非正数）一律 nil，交给调用方保持先验值。
    private static func parseCanvasSize(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width >= 1, height >= 1 else { return nil }
        return NSSize(width: width, height: height)
    }

    // MARK: - 通道 / 截图

    @MainActor
    private func makeChannelOnMain() -> any PageChannel {
        let signal = closeSignal ?? WindowCloseSignal()
        let channel = WKPageChannel(webView: webView, closeSignal: signal)
        self.channel = channel
        return channel
    }

    /// 进程内渲染快照。**不算 AC-8 证据**（`docs/qa-addendum.md`：它证明"WebKit 渲染出了这一帧"，
    /// 不证明"用户桌面上看见了这个窗口"）。AC-8 只认 `screencapture -l<CGWindowID>`。
    @MainActor
    private func snapshotOnMain() async throws -> Data? {
        guard let webView = webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image: NSImage? = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            var resumed = false
            webView.takeSnapshot(with: configuration) { snapshot, _ in
                if resumed { return }
                resumed = true
                continuation.resume(returning: snapshot)
            }
            // 合成延迟兜底：宁可返回 nil（E13：不失败），也不要让 `--screenshot` 挂住退出流程。
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if resumed { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
        guard let image = image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - 关窗

    @MainActor
    private func closeWindowOnMain() {
        isProgrammaticClose = true
        closeSignal?.markClosed(reason: "programmatic")
        channel?.markDead()
        webView?.stopLoading()
        if let window = window {
            window.close()   // → windowWillClose → 状态归零
        }
        window = nil
        webView = nil
        channel = nil
    }

    @MainActor
    private func isAliveOnMain() -> Bool {
        return window != nil
    }

    /// 用户关窗的替身（D4）：只做"把标记打回 false，然后像用户那样关窗"。
    ///
    /// 与 `closeWindowOnMain()` 的区别（两者不许合并）：
    ///   · `closeWindowOnMain()` 先 `markClosed(reason: "programmatic")`，测的是产品主动收尾；
    ///   · 本方法**不预先 markClosed**，让 `windowWillClose` 自己按 `isProgrammaticClose == false`
    ///     写成 `reason=user` —— 那才是 E12（用户点红叉）走的那条路。
    ///
    /// 窗口已经不在（用户早关了 / 已 programmatic 关掉）→ 空操作并记一行日志：
    /// 门禁要能分辨"关窗没触发"和"根本没窗口"。
    @MainActor
    private func simulateUserCloseOnMain() {
        guard let window = window else {
            // **不写 `window_closed`**：这里什么也没关（窗口早就不在），
            // 打一个 `window_closed: 1` 会让读日志的人以为 E12 走到了。
            log?.info("WKEmbeddedKernel", "模拟用户关窗：窗口已不存在（空操作）", [
                "reason": "user",
                "skipped": "no_window"
            ])
            return
        }
        isProgrammaticClose = false
        log?.info("WKEmbeddedKernel", "模拟用户关窗（走 windowWillClose 的用户分支）", [
            "reason": "user",
            "window_id": "\(window.windowNumber)",
            "title": windowTitle
        ])
        // 只关窗，**不**停静态服务、不清端口：资源回收仍由 `GameLauncher.terminate` 负责，
        // 否则 `--play` 收尾时会拿到一个已经被拆掉的会话（假 web_port_busy 的来源之一）。
        window.close()   // → windowWillClose → reason=user
    }

    /// 导航失败的分类（失败矩阵 E5 / E6 / E7）。
    ///
    /// | 现象 | 码 | 理由 |
    /// |---|---|---|
    /// | 连不上本机静态服务（`NSURLErrorCannotConnectToHost` / `ConnectionRefused`） | `.webServerFailed` | 换台机器/换个时机能自己好 → 环境缺口 |
    /// | 其余导航错误（TLS/自定义协议/被取消） | `.kernelLoadFailed` | 系统层/页面层，重试通常无用 |
    ///
    /// HTTP 404 **不会**走到这里：WebKit 把 404 当作一个正常文档交付（随后 `didFinish`），
    /// 所以 E6 的真实判据是"`captured == 0` + 静态服务日志里 404"，不是导航回调。
    private func mapNavigationError(_ error: Error) -> MochiBoxError {
        let nsError = error as NSError
        let detail = "nav_error=\(nsError.domain)/\(nsError.code)"
        let connectionCodes: Set<Int> = [
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorResourceUnavailable,
            NSURLErrorNotConnectedToInternet
        ]
        if nsError.domain == NSURLErrorDomain, connectionCodes.contains(nsError.code) {
            return MochiBoxError(code: .webServerFailed, message: "内置内核连不上本地静态服务（\(detail)）")
        }
        if nsError.code == 404 || nsError.code == 410 {
            return MochiBoxError(code: .webRootMissing, message: "内置内核请求的页面不存在（\(detail)）")
        }
        return MochiBoxError(code: .kernelLoadFailed, message: "内置内核导航失败（kernel_reason=navigation \(detail)）")
    }
}

// MARK: - WKNavigationDelegate

extension WKEmbeddedKernel: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // 只是"首次导航有结论了"，**不是**成功判据：MZ 的错误页也会走到这里。
            if case .loading = self.navigation {
                self.navigation = .finished
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        recordNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        recordNavigationFailure(error)
    }

    private nonisolated func recordNavigationFailure(_ error: Error) {
        Task { @MainActor in
            let mapped = self.mapNavigationError(error)
            self.log?.error("WKEmbeddedKernel", "内置内核导航失败", [
                "nav_error": "\((error as NSError).domain)/\((error as NSError).code)",
                "code": mapped.code.rawValue
            ])
            if case .loading = self.navigation {
                self.navigation = .failed(mapped)
            }
            // 通道立刻置死：pump 侧随后的 evaluate 必须抛 `.attachFailed`（不是 `.cdpTimeout`），
            // 这样"连续 5 次失败"会快速收敛并打出一条 window_closed。
            self.channel?.markDead()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.log?.error("WKEmbeddedKernel", "WebContent 进程已终止", [
                "kernel_reason": "webcontent_terminated"
            ])
            self.channel?.markDead()
            self.closeSignal?.markClosed(reason: "webcontent")
            if case .loading = self.navigation {
                self.navigation = .failed(MochiBoxError(
                    code: .kernelLoadFailed,
                    message: "内置内核 WebContent 进程已终止（kernel_reason=webcontent_terminated）"
                ))
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension WKEmbeddedKernel: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            let programmatic = self.isProgrammaticClose
            self.closeSignal?.markClosed(reason: programmatic ? "programmatic" : "user")
            self.channel?.markDead()
            self.webView?.stopLoading()
            self.window = nil
            self.webView = nil
            self.channel = nil
            self.log?.info("WKEmbeddedKernel", programmatic ? "内置内核窗口已关闭" : "用户关闭了内置内核窗口", [
                "window_closed": "1",
                "reason": programmatic ? "programmatic" : "user",
                "title": self.windowTitle
            ])
        }
    }
}
