//
//  EmbeddedKernelApp.swift
//  MochiBox
//
//  `--play`（窗口模式）的 NSApplication 引导（架构 v0.4 §4.4 / §4.6 时序图 2）。
//
//  为什么必须起 `NSApplication`：`--play` 的 headless 路径刻意**不**初始化 AppKit
//  （这样 SSH 下也能跑）；而内置内核需要 `NSWindow` + 主 run loop。两者是互斥的两条入口，
//  分流点在 `AppMain.main()`：`--play` 且非 `--headless` / 非 `--browser` / 非 `--kernel chromium`。
//
//  本文件属于 `Sources/UI/**`：分层门禁（`Scripts/build.sh:27-35`）允许这里 import AppKit/WebKit。
//

import Foundation
import AppKit
import CoreGraphics

enum EmbeddedKernelApp {

    /// 注册内置内核工厂（Adapters 侧只认 `EmbeddedKernelSession` 协议）。
    ///
    /// 两个调用点：本文件的 `bootstrap`（`--play` 窗口模式）与 `AppMain.MochiBoxApp.init()`
    /// （GUI 点「启动」）。**没有注册 = 矩阵 E2 硬失败**（不静默回退 Chromium）。
    @MainActor
    static func registerKernel() {
        KernelRegistry.register { WKEmbeddedKernel() }
    }

    /// 窗口模式入口。**不返回**（`app.run()` 之后由 `exit()` 收尾）。
    ///
    /// 失败矩阵 E1：无 Aqua 会话时不能"假装窗口开了"（`NSWindow` 会静默不显示，
    /// 表现为 `captured=0` 的假失败）——直接给 `kernel_no_desktop_session` + 退出码 3。
    static func bootstrap(_ arguments: [String]) -> Never {
        // `--control` 的门禁必须**排在起 NSApplication 之前**：这个入口不经过
        // `AttachCLI.bootstrap`，少这一句就等于窗口模式可以绕过 MOCHI_E2E 检查。
        AttachCLI.enforceControlGate(arguments)
        guard let options = AttachCLI.parse(arguments) else {
            FileHandle.standardError.write(Data((AttachCLI.usage() + "\n").utf8))
            exit(2)
        }

        // E1：没有登录桌面（SSH / 无 WindowServer / 已注销）。
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("kernel_reason=no_aqua")
            print("error_code: \(ErrorCode.kernelNoDesktopSession.rawValue)")
            print("play failed: \(ErrorCode.kernelNoDesktopSession.uiMessage)")
            print("play: environment=\(ErrorCode.kernelNoDesktopSession.rawValue)")
            fflush(stdout)
            exit(3)
        }

        let application = NSApplication.shared
        // `.regular`（U3 默认）：MZ 需要键盘输入，且"用户能看见窗口"是 AC-8 的前提。
        application.setActivationPolicy(.regular)

        Task { @MainActor in
            // 先注册再跑：`GameLauncher.launchEmbedded` 会在 `KernelRegistry.make()` 上等这一步。
            registerKernel()
            let code = await AttachCLI.run(options)
            fflush(stdout)
            exit(code)
        }

        // 主 run loop：服务 MainActor（WKWebView 回调、NSWindow 事件、drain 轮询全部在上面）。
        application.run()
        exit(0)
    }
}
