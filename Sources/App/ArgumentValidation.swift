//
//  ArgumentValidation.swift
//  MochiBox
//
//  命令行参数校验：在入口分流（`--selftest` / `--attach` / `--kernel-smoke` / `--play` / GUI）
//  **之前**先跑一遍，把"未知旗标被静默忽略"变成显式失败。
//
//  为什么需要它：各模式的解析器都是 `args.contains("--x")` / `firstIndex(of:)` 风格，
//  不认识的参数既不报错也不提示。用户把 E2E 脚本的参数打到产品二进制上
//  （`--suite all`）时，进程会按"无模式 = GUI"起一个空窗口，看起来像挂住 ——
//  静默忽略比报错更贵：跑的人以为在等结果，其实什么都没发生。
//
//  约束：只依赖 Foundation。参数校验必须能在 `--selftest` 那条"不起 NSApplication"
//  的路径上跑（`Scripts/build.sh` 的 UI 门禁是同一套约束）。
//

import Foundation

enum ArgumentValidation {

    // MARK: - 模式

    /// 一次进程只允许走一个模式；都不给 = GUI。
    enum Mode: String {
        case gui = "gui"
        case selftest = "selftest"
        case attach = "attach"
        case kernelSmoke = "kernel-smoke"
        case play = "play"

        /// 诊断与帮助里显示的名字（GUI 没有模式旗标）。
        var display: String {
            switch self {
            case .gui: return "GUI"
            default: return "--" + rawValue
            }
        }
    }

    /// 校验失败：`code` 原样打进 `error_code: <code>`，`lines` 逐行打到 stdout。
    struct Failure {
        let code: String
        let lines: [String]
    }

    // MARK: - 各模式的合法旗标

    /// `SelfTestRunner` 实际读取的全部旗标。
    static let selftestFlags: Set<String> = ["--selftest", "--filter", "--verbose"]

    /// `AttachCLI.parse` 在 `--attach` 路径上实际读取的全集。
    ///
    /// `--control` 也在这里：它的语义（必须 `MOCHI_E2E=1`）由 `enforceControlGate` 单独把关，
    /// 校验层只判"这个旗标在这条路径上是否存在"，不重复判业务门禁。
    static let attachFlags: Set<String> = [
        "--attach", "--provider", "--endpoint", "--api-key", "--out", "--screenshot",
        "--duration", "--headless", "--browser", "--kernel", "--control"
    ]

    /// `--play` 共用 `--attach` 的采集参数，外加它自己的目录与关窗开关。
    static let playFlags: Set<String> = attachFlags.union(["--play", "--close-after"])

    /// `KernelSmokeMain.parse` 只认这两个（诊断入口刻意不共享产品参数面）。
    static let kernelSmokeFlags: Set<String> = ["--kernel-smoke", "--timeout"]

    /// GUI 不吃任何 `--` 旗标。Finder / `open` 注入的是**单横线**参数
    /// （`-psn_0_123`、`-NSDocumentRevisionsDebugMode YES`），不以 `--` 开头，天然放行；
    /// 同理 `open -a MochiBox <文件>` 的裸路径也不会被误判。
    static let guiFlags: Set<String> = []

    /// 所有模式旗标（同一进程出现两个即互斥冲突）。
    static let modeFlags = ["--selftest", "--attach", "--kernel-smoke", "--play"]

    /// 全仓所有合法旗标的并集（用于区分"未知"与"放错模式"）。
    static var knownFlags: Set<String> {
        return selftestFlags.union(attachFlags).union(playFlags).union(kernelSmokeFlags)
    }

    static func flags(for mode: Mode) -> Set<String> {
        switch mode {
        case .gui: return guiFlags
        case .selftest: return selftestFlags
        case .attach: return attachFlags
        case .kernelSmoke: return kernelSmokeFlags
        case .play: return playFlags
        }
    }

    // MARK: - 校验

    /// 返回 `nil` 表示可以继续分流；非 `nil` 时调用方负责打印并 `exit(2)`。
    ///
    /// 只看 `--` 开头的 token：
    /// · 裸参数在 GUI 模式可能是文档路径，在另外三个模式里是各自的取值（端口/目录/秒数），
    ///   都不能当错误；
    /// · `-psn_` / `-NSDocumentRevisionsDebugMode` 是 LaunchServices 注入的单横线参数，同样放行。
    ///
    /// 模式自身取值的缺失（`--attach` 没端口、`--play` 没目录）**不在这里判**：
    /// 那是各解析器的既有判定，退出码与用法文案一字不改。
    static func validate(_ arguments: [String]) -> Failure? {
        let present = modeFlags.filter { arguments.contains($0) }
        if present.count > 1 {
            return Failure(code: "conflicting_arguments",
                           lines: ["conflicting modes: " + present.joined(separator: " "),
                                   "see --help"])
        }

        let mode: Mode
        if present.first == "--selftest" {
            mode = .selftest
        } else if present.first == "--attach" {
            mode = .attach
        } else if present.first == "--kernel-smoke" {
            mode = .kernelSmoke
        } else if present.first == "--play" {
            mode = .play
        } else {
            mode = .gui
        }

        let allowed = flags(for: mode)
        for argument in arguments.dropFirst() where argument.hasPrefix("--") {
            guard knownFlags.contains(argument) else {
                // 完全没见过的旗标：最常见的是把别的工具（Tests/e2e/run.sh）的参数打进来。
                return Failure(code: "unknown_argument",
                               lines: ["unknown option: " + argument, "see --help"])
            }
            guard allowed.contains(argument) else {
                // 认识，但不属于当前模式（例如 `--selftest --play x`）。
                return Failure(code: "conflicting_arguments",
                               lines: ["option not allowed in " + mode.display + " mode: " + argument,
                                       "see --help"])
            }
        }
        return nil
    }

    // MARK: - 帮助

    /// `--help` / `-h` 的输出。按模式分组，每个旗标一行；退出码表放最后。
    static func helpText() -> String {
        return """
用法: MochiBox [--help | -h]

模式（互斥，最多给一个；都不给则启动图形界面）:

  MochiBox                                        启动 GUI
  MochiBox --selftest [选项]                      运行内置自检（TAP 输出）
  MochiBox --attach <端口> [选项]                  附着到已开调试端口的浏览器
  MochiBox --play <游戏目录> [选项]                走真实产品启动路径（静态服务 + 内核 + attach）
  MochiBox --kernel-smoke <游戏目录> [选项]        最小内核诊断（不注入 Agent）

--selftest
  --selftest              运行内置自检，末行 `# pass N fail M skip K`
  --filter <文本>          只跑组名或用例名包含该文本的用例
  --verbose               额外打印被测对象的实际值

--attach
  --attach <端口>          浏览器已开的 CDP 调试端口
  --provider <名>          翻译后端：passthrough（默认）| openai
  --endpoint <url>         openai 后端地址
  --api-key <key>          openai key（缺省读环境变量 MOCHI_OPENAI_KEY）
  --out <path.jsonl>       采集结果写出路径
  --screenshot <path.png>  截一张图到指定路径
  --duration <秒>          采集时长（默认 6）
  --headless               无窗口浏览器
  --browser <可执行文件>    指定 Chromium 内核浏览器
  --kernel <embedded|chromium>  指定内核
  --control <socket 路径>   进程外控制通道（需 MOCHI_E2E=1）

--play
  以上 --attach 的选项全部可用，另有:
  --play <游戏目录>         游戏目录（MV/MZ 的静态站点根或作品根）
  --close-after <秒>       启动成功 N 秒后模拟用户关窗

--kernel-smoke
  --kernel-smoke <游戏目录>  在最小内核上验证自动播放与注入
  --timeout <秒>           冒烟超时

退出码:
  0  成功
  1  断言失败（例如 --play 的 captured == 0）
  2  参数或环境准备错误（未知旗标、互斥组合、缺取值都在此列）
  3  无 Aqua 桌面 / 环境缺口

未知的 `--` 开头的参数会被拒绝:
  error_code: unknown_argument
  unknown option: <arg>
  see --help
"""
    }
}
