//
//  AppMain.swift
//  MochiBox
//
//  入口：先分流 `--selftest` / `--attach`（绝不初始化 NSApplication），再进入 SwiftUI App。
//

import SwiftUI
import AppKit
import Darwin

// MARK: - 入口

@main
enum MochiBoxMain {
    static func main() {
        let arguments = CommandLine.arguments

        // `--help` / `-h`：任何模式下都先响应，不参与后续校验。
        // 用户想看用法时不应先被告知"参数错误"（`--attach 9000 --help` 也照样给用法）。
        if arguments.contains("--help") || arguments.contains("-h") {
            print(ArgumentValidation.helpText())
            fflush(stdout)
            exit(0)
        }

        // 分流之前的统一校验：未知旗标 / 互斥模式 / 放错模式的旗标一律 exit 2。
        // 为什么必须在这里：下面的分流全是 `arguments.contains(...)`，不认识的参数会被
        // 静默吃掉，进程直接落到 `MochiBoxApp.main()` 起一个空窗口 —— 用户看到的是"卡住"。
        // 取值缺失（`--attach` 没端口等）仍由各解析器判，退出码与文案不变。
        if let failure = ArgumentValidation.validate(arguments) {
            print("error_code: " + failure.code)
            for line in failure.lines {
                print(line)
            }
            fflush(stdout)
            exit(2)
        }

        // 品牌迁移（旧品牌目录 → MochiBox）：放在 `--help` / `-h` / 参数校验之后，
        // 所有真实模式分派之前。放太早会让 `--help`、`-h`、参数写错这几条只打印用法的
        // 路径也去搬用户真实目录；放太晚则新目录已被 AppPaths 创建，旧数据再也搬不动 ——
        // 这里正是唯一的窗口期，也是唯一的统一入口（下面的 GUI 兜底路径也覆盖）。
        // 失败只 NSLog、不 crash：迁移是尽力而为，不能拦住启动。
        LegacyMigration.runIfNeeded()

        if arguments.contains("--selftest") {
            // Never 返回：内部 dispatchMain()，全程不创建 NSApplication。
            SelfTestRunner.bootstrap(arguments)
        }
        if arguments.contains("--attach") {
            AttachCLI.bootstrap(arguments)
        }
        // v0.4 T03：`--kernel-smoke <游戏目录>` 是最小内核的诊断入口（不进 `--play` 参数面、
        // 不进 `environmentCodes`、不进 `--selftest` 的 45 条计数）。
        // **必须排在 `--play` 之前**：两者都吃一个目录参数，顺序反了会互相把对方当目录名。
        if arguments.contains("--kernel-smoke") {
            // Never 返回：内部起 NSApplication 跑完冒烟后 exit()。
            KernelSmokeMain.bootstrap(arguments)
        }
        // v0.2：`--play <游戏目录>` 走真实产品启动路径（静态服务 + 浏览器 + attach）。
        // 放在 `--attach` 之后、`MochiBoxApp.main()` 之前：两者都绝不初始化 NSApplication。
        //
        // v0.4 分流（架构 v0.4 §4.4）：**窗口模式（默认）走应用内 WKWebView**，必须起
        // `NSApplication` 才有 `NSWindow` 与主 run loop；`--headless` / `--browser` /
        // `--kernel chromium` 仍然走 v0.2 的 Chromium + 纯 CLI 路径（SSH 下可跑，行为零变化）。
        if arguments.contains("--play") {
            let wantsChromium = arguments.contains("--headless")
                || arguments.contains("--browser")
                || arguments.contains("--kernel") && arguments.contains("chromium")
            if !wantsChromium {
                // Never 返回：内部起 NSApplication 并注册内置内核。
                EmbeddedKernelApp.bootstrap(arguments)
            }
            AttachCLI.bootstrap(arguments)
        }
        MochiBoxApp.main()
    }
}

// MARK: - SwiftUI App

struct MochiBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // GUI 点「启动」也走内置内核（`LaunchOptions()` 默认非 headless）。
        // 没有这一行，GUI 会在 `KernelRegistry.make()` 上拿到 nil → kernel_load_failed（矩阵 E2）。
        EmbeddedKernelApp.registerKernel()
    }

    var body: some Scene {
        WindowGroup("MochiBox") {
            MainWindow()
                .environmentObject(appState)
        }
        // 初始窗口尺寸（V0.6 T04 验收：仍 920×580）。
        //
        // 不写这两行时，SwiftUI 按**内容的 ideal 尺寸**开窗：右栏多了作弊/全文两页后，
        // 内容 ideal 被推到 1221×713（实测 CGWindowList），与"保持 920×580"的验收不符。
        // `.contentMinSize` 让窗口仍可放大、但不会小于 `MainWindow` 的 minWidth/minHeight。
        .defaultSize(width: 920, height: 580)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加游戏…") {
                    NotificationCenter.default.post(name: .mochiBoxAddGame, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("放大字号") {
                    NotificationCenter.default.post(name: .mochiBoxFontUp, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("缩小字号") {
                    NotificationCenter.default.post(name: .mochiBoxFontDown, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 残留浏览器清扫（用户实测：跑过 Chromium 窗口模式后 Dock 里一直挂着 Chrome 图标）。
        // 只清「带本 App profile」的进程，用户自己的 Chrome 不会被误杀。
        let swept = BrowserProcessSweeper.sweep()
        if !swept.killed.isEmpty {
            NSLog("MochiBox: reclaimed %d leftover browser process(es): %@",
                  swept.killed.count, swept.killed.map(String.init).joined(separator: ","))
        }

        // GUI 路径的内核注册点（架构 v0.4 §4.4 / T04 第 6 条验收）：
        // `--play` 由 `EmbeddedKernelApp.bootstrap` 自己注册，GUI 没有那条入口，
        // 漏了这一行点「启动」就是 `kernel_load_failed / kernel_reason=not_registered`
        // （**故意的硬失败**，不许改成静默回退 Chromium）。
        // 实现体留在 `Sources/UI/EmbeddedKernel/`：放到 Domain 层会撞 `build.sh:27-35` 的 UI 门禁。
        EmbeddedKernelApp.registerKernel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // ⌘Q / 退出：同步清理子进程（异步清理在主线程退出时不可靠）。
        ChildProcessRegistry.shared.terminateAll()
        // 再扫一遍 profile 里的 pid 文件：覆盖「进程已不是我们登记的 pid」的情况
        // （例如 Chromium 自己重启过、或上一轮被 SIGKILL 后 pid 文件还在）。
        BrowserProcessSweeper.sweep(graceSec: 0.5)
    }
}

// MARK: - 子进程登记（退出兜底）

/// 供 `applicationWillTerminate` 使用的同步登记表：保证 ⌘Q 后不留残余游戏进程。
final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    private var pids: Set<Int32> = []

    func register(_ pid: Int32) {
        guard pid > 0 else { return }
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    func unregister(_ pid: Int32) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let snapshot = pids
        pids.removeAll()
        lock.unlock()
        // 批量：TERM 全部 → 等 0.3s（一次）→ 对仍活着的补 KILL。
        // 总耗时与 pid 数量无关 —— 退出路径不能 N × 宽限。
        ProcessTerminator.terminateAll(pids: Array(snapshot), graceSec: 0.3)
    }
}

// MARK: - 菜单动作通知

extension Notification.Name {
    static let mochiBoxAddGame = Notification.Name("mochibox.addGame")
    /// 主窗口即将关闭（由 `WindowChrome` 的 `NSWindow.willCloseNotification` 转发）。
    static let mochiBoxMainWindowWillClose = Notification.Name("mochibox.mainWindowWillClose")
    static let mochiBoxFontUp = Notification.Name("mochibox.fontUp")
    static let mochiBoxFontDown = Notification.Name("mochibox.fontDown")
}
