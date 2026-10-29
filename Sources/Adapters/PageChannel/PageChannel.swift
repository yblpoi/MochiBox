//
//  PageChannel.swift
//  MochiBox
//
//  页通道抽象（架构 v0.4 §3.2）：**"能执行 JS 并取回值"** 的最小能力面。
//
//  为什么必须解耦（§3.1）：`AgentInjector` 对 CDP 的依赖只有三件事 —— 9 处 evaluate、
//  一组「刷新后仍在」的 startup script、一次卸载。前两类进协议；截图不进（那是 CDP 专属，
//  由 `MVAdapter` 按 transport 分流）。
//
//  **本文件只 import Foundation**（`Scripts/build.sh:27-35` 的分层门禁）：
//  Adapters 层出现 `import SwiftUI` / `import AppKit` 直接 exit 2，因为
//  `--selftest` / `--attach` 必须在无图形会话（SSH）下也能跑。
//

import Foundation

// MARK: - 求值结果

/// 跨实现的求值结果。Shape 与旧的 `CDPEvaluateResult` 完全一致
/// （value 是 `returnByValue` 的 JSON；undefined 与 null 都表现为 value == nil）。
struct JSEvalResult: Sendable {
    /// 页面内求值得到的值。`nil` 表示 `undefined` / `null` / 无法桥接（见 WK 侧桥接表）。
    var value: JSONValue?
    /// 非 nil = 页面内抛了异常（JS 层错误，**不是**通道故障）。
    var exceptionText: String?
    /// 给日志用：`cdp` / `wk`。两个实现必须写出自己的名字，排障时一眼看出走的是哪条通道。
    var channelKind: String
}

// MARK: - 协议

/// 页通道：两个实现（`CDPSessionChannel` / `WKPageChannel`）必须**同构**。
///
/// 语义约定（§3.4 / §9.4），两个实现缺一条就会让 `startTextPump` 的"连续 5 次失败"
/// 被误触发：
///   · 超时 → 抛 `MochiBoxError(code: .cdpTimeout)`（WK 也用这个码，不新增 `kernel_eval_timeout`）；
///   · 页面抛异常 → `exceptionText` 非 nil，**不 throw**；
///   · 通道已死（WebSocket 断 / 窗口关闭 / WebContent 亡）→ 抛 `.attachFailed`；
///   · `addStartupScript` 幂等（第二次调用必须返回第一次的 identifier）。
///
/// 隔离域刻意**不**在协议上固定：CDP 实现是 actor（`CDPClient`）+ 薄壳，
/// WK 实现必须主线程（`WKEvaluateJavaScript` 只能在主线程调用）。协议只声明 `async`。
protocol PageChannel: AnyObject, Sendable {
    /// `"cdp"` | `"wk"`，只进日志，不参与任何判定。
    var kind: String { get }

    /// 执行 JS。超时**必须**抛 `MochiBoxError(code: .cdpTimeout)`。
    /// 通道故障（WebSocket 断 / WebContent 亡 / 窗口已关）抛 `.attachFailed`。
    func evaluate(_ expression: String, timeout: TimeInterval) async throws -> JSEvalResult

    /// 下次文档加载时自动执行（CDP: `Page.addScriptToEvaluateOnNewDocument`；
    /// WK: `WKUserScript(.atDocumentStart)`）。返回 identifier，重复调用必须幂等。
    func addStartupScript(_ source: String) async throws -> String

    /// 卸载 startup script（尽力而为，失败不抛）。
    func removeStartupScript(_ identifier: String) async
}
