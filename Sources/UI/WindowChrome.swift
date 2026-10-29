//
//  WindowChrome.swift
//  MochiBox
//
//  主窗口的窗口级毛玻璃。
//
//  为什么不用 SwiftUI 的 .ultraThinMaterial：那个材质只作用于**视图层**，
//  下面仍然是窗口自己的不透明背景 —— 视觉上就是一块灰扑扑的色块（用户报的
//  "毛玻璃效果不好看"）。真正的窗口级模糊必须让 NSWindow 变成非不透明，
//  再把 NSVisualEffectView(.underWindowBackground, .behindWindow) 垫在
//  内容视图**之下**。
//
//  关键点：`contentView.addSubview(effect, positioned: .below)` 是**错**的 ——
//  `positioned:` 只决定它在"其它子视图"里的顺序，材质仍然绘制在 contentView
//  自身内容之上。那样做出来是一整块均匀灰、SwiftUI 界面全被盖住（已验证）。
//  正确做法是把原 contentView 包进一个容器：容器 → 材质 → hostingView。
//
//  隔离：本文件在 Sources/UI/**，允许 import AppKit（build.sh 的分层门禁）。
//

import SwiftUI
import AppKit

/// 只做布局锚点的透明视图：**绝不能吃掉鼠标事件**，否则整块内容区点不动。
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }
}

/// 安装窗口级毛玻璃背景（幂等：多次 update 只会包一次）。
struct WindowChrome: NSViewRepresentable {
    private static let containerID = NSUserInterfaceItemIdentifier("mochibox.window.container")

    /// 持有窗口关闭通知的观察者（视图销毁时一并注销）。
    final class Coordinator {
        var closeObserver: NSObjectProtocol?
        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let anchor = AnchorView(frame: .zero)
        DispatchQueue.main.async { install(on: anchor.window, coordinator: context.coordinator) }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { install(on: nsView.window, coordinator: context.coordinator) }
    }

    private func install(on window: NSWindow?, coordinator: Coordinator) {
        guard let window = window else { return }
        // 让窗口能透出背后的桌面：.behindWindow 材质依赖这两个开关。
        window.isOpaque = false
        window.backgroundColor = .clear

        // 主窗口关闭 = 结束会话。**必须用 AppKit 的通知**：SwiftUI 的
        // `.onDisappear` 在 WindowGroup 关窗时并不可靠（scene 会被保留以便
        // 重新打开），实测收不到 —— 于是游戏窗口、静态服务、WebContent 进程
        // 全都留在后台（用户报的"关闭窗口后后台还在跑"）。
        if coordinator.closeObserver == nil {
            coordinator.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                NotificationCenter.default.post(name: .mochiBoxMainWindowWillClose, object: nil)
            }
        }

        // 已经包过（hosting view 的父级就是我们的容器）→ 什么都不做。
        if window.contentView?.identifier == Self.containerID { return }
        guard let hosting = window.contentView else { return }

        let container = NSView(frame: hosting.frame)
        container.identifier = Self.containerID
        container.autoresizingMask = [.width, .height]

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        // .active 而不是 .followsWindowActiveState：窗口失焦（用户去玩游戏的
        // 时候）材质会从毛玻璃塌成一块死灰，看起来像"效果坏了"。
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        hosting.removeFromSuperview()
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        window.contentView = container
    }
}
