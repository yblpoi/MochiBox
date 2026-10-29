//
//  EmbeddedKernel.swift
//  MochiBox
//
//  内置内核（`WKWebView`）在 **Adapters 侧** 的全部可见面：规格、句柄、描述符、协议、注册表、
//  关闭信号盒。本文件只 import Foundation —— 真正的 WebKit 代码在 `Sources/UI/EmbeddedKernel/**`
//  （架构 v0.4 §2.1：`Sources/UI/**` 是 WebKit 的合法落点，Adapters 只认协议）。
//
//  注入点：`KernelRegistry`（`@MainActor`）在 UI 层启动时 `register`，
//  `GameLauncher` 只 `await KernelRegistry.make()`。**未注册 = 硬失败**（矩阵 E2，
//  不静默回退到 Chromium：静默回退会让"用户要应用自己的窗口"这件事悄悄失效）。
//

import Foundation

// MARK: - 关闭信号

/// 跨隔离域传"窗口关了没有"的盒子。
///
/// 为什么不用 `@Published` / `NotificationCenter`：它被三处共享 —— `LaunchHandle.closed`
/// （adapter 侧轮询）、`EmbeddedRunDescriptor`（launcher 侧）、`PlayControl`（`--play` 侧），
/// 其中两处在非主线程。`NSLock + Bool` 是唯一不引入 SwiftUI 依赖、也不会丢事件的形状。
final class WindowCloseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var closed: Bool = false
    private var reasonText: String = ""

    /// 窗口是否已关闭（用户点红叉 / ⌘W / 程序主动关）。
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// `"user"`（用户关的）/ `"programmatic"`（我们关的）；未关闭时为空串。
    var reason: String {
        lock.lock()
        defer { lock.unlock() }
        return reasonText
    }

    /// 幂等：第二次调用不会覆盖第一次的 reason（先发生的才是真相）。
    func markClosed(reason: String = "programmatic") {
        lock.lock()
        if !closed {
            closed = true
            reasonText = reason
        }
        lock.unlock()
    }
}

// MARK: - 规格 / 句柄 / 描述符

/// 起窗所需的全部输入。**全部是值**，可跨隔离域传递。
struct EmbeddedKernelSpec: Sendable {
    /// `http://127.0.0.1:<httpPort>/index.html`
    var pageURL: String
    /// 内容区点宽（`System.json → advanced.screenWidth`）。
    var screenWidth: Int
    /// 内容区点高。
    var screenHeight: Int
    /// 窗口标题（`System.json → gameTitle`，缺失回落目录名）。
    var windowTitle: String
    /// `AgentInjector.loadScript()` 的原文（早装的全部基础：`WKUserScript(.atDocumentStart)`）。
    var agentScript: String
    var log: SessionLog?
    /// 主线程写、其它线程读的关闭标记。
    var closeSignal: WindowCloseSignal
}

/// 起窗结果。`windowNumber` 就是 `CGWindowID`，可直接喂 `screencapture -l`（AC-8）。
struct EmbeddedKernelHandle: Sendable {
    /// `== NSWindow.windowNumber == CGWindowID`（AC-8 取证件用）。
    var windowNumber: Int
    /// 内容区宽度（**点**，= 游戏分辨率）。
    var contentWidth: Int
    /// 内容区高度（**点**）。
    var contentHeight: Int
    /// 2.0 on Retina：截图/像素判据要乘它（`816×624 × 2 = 1632×1248`）。
    var backingScale: Double
    var title: String
}

/// 内置内核运行态的可传递描述符（`LaunchHandle.embedded`）。
///
/// 与 `WebRunDescriptor` 同型：**只放能在 actor 之外安全传递的值**，
/// 内核本体留在 `GameLauncher.kernels` 里，由 `sessionKey` 找回。
struct EmbeddedRunDescriptor: Sendable {
    /// 在 `GameLauncher.kernels` 里找回内核的键。
    var sessionKey: String
    var httpPort: Int
    var webRoot: URL
    var pageURL: String
    var screenWidth: Int
    var screenHeight: Int
    var backingScale: Double
    var windowNumber: Int
    var windowTitle: String
}

// MARK: - 内核协议

/// 一个内置内核会话（实现者：`WKEmbeddedKernel`）。
///
/// 隔离约定（§3.5）：协议 `AnyObject, Sendable`；实现 `@MainActor`（`NSWindow` / `WKWebView`
/// 只能主线程）。协议方法全 `async`，实现侧用 nonisolated 入口 + 主线程内部实现来满足它。
protocol EmbeddedKernelSession: AnyObject, Sendable {
    /// 建窗 + 挂 `WKUserScript(.atDocumentStart)` + 加载页面，返回 `windowNumber`。
    func start(_ spec: EmbeddedKernelSpec) async throws -> EmbeddedKernelHandle

    /// 产出页通道（`AgentInjector` 只认它）。
    func makeChannel() async -> any PageChannel

    /// 进程内渲染快照（`--screenshot` 的诊断产物，**不算 AC-8 证据**）。
    func snapshotPNG() async throws -> Data?

    /// 关窗（幂等）。关完之后 `isAlive()` 必须很快变 false。
    func closeWindow() async

    /// 模拟"用户点红叉关窗"（欠账 D4：矩阵 E12 的自动门禁）。
    ///
    /// 与 `closeWindow()` 的语义差异是**必须**保留的：`closeWindow()` 是产品主动收尾
    /// （`reason=programmatic`），本方法是替用户按下关闭按钮（`reason=user`）。
    /// 实现方**绝不允许**用 `closeWindow()` 顶替它 —— 那样门禁量到的还是 programmatic 路径，
    /// 等于什么都没验。窗口已不存在时按幂等空操作处理。
    func simulateUserClose() async

    /// 窗口是否还在。
    func isAlive() async -> Bool
}

// MARK: - 注册表

/// 内核注册表：Adapters 只认协议，UI 层注册实现。
///
/// 为什么是"注册"而不是"直接用"：`GameLauncher` 在 Adapters 层（禁止 import AppKit），
/// 而 `WKWebView` 必须 AppKit。注册表把这条依赖倒过来，且让"未注册"成为一个**显式失败**
/// 而不是编译期硬绑。
@MainActor
enum KernelRegistry {
    private static var factory: (@MainActor @Sendable () -> any EmbeddedKernelSession)?

    /// UI 层启动时调用（`--play` 的 `EmbeddedKernelApp.bootstrap` 与 GUI 的 `MochiBoxApp`）。
    static func register(_ make: @escaping @MainActor @Sendable () -> any EmbeddedKernelSession) {
        factory = make
    }

    /// `nil` = 没注册（矩阵 E2：`GameLauncher.launchEmbedded` 抛 `.kernelLoadFailed`）。
    static func make() -> (any EmbeddedKernelSession)? {
        return factory?()
    }

    static var isRegistered: Bool {
        return factory != nil
    }
}
