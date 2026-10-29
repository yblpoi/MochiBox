//
//  WKPageChannel.swift
//  MochiBox
//
//  `PageChannel` 的 WebKit 实现（架构 v0.4 §3.2 / §3.3 / §3.4）。
//
//  三件事必须和 CDP 实现**逐条同构**，否则 `startTextPump` 的"连续 5 次失败"会被误触发：
//    1. 超时 → 抛 `.cdpTimeout`（WK 也用这个码，**不**新增 `kernel_eval_timeout`）；
//    2. 页面抛异常 → `exceptionText` 非 nil，**不 throw**；
//    3. 通道已死（窗口关闭 / WebContent 进程亡）→ 抛 `.attachFailed`。
//
//  隔离：`evaluateJavaScript` 必须在主线程，而本类要被 `AgentInjector`（非隔离）持有，
//  所以**协议方法一律 nonisolated 入口 + 内部 hop 到主线程**（架构 §3.5 的"退化写法"，
//  好处是不依赖编译器对 `@MainActor` witness 的宽容度，`-swift-version 5` 下零诊断）。
//

import Foundation
import WebKit

final class WKPageChannel: PageChannel, @unchecked Sendable {
    /// `nil` = 窗口/内核已经没了（此时 `evaluate` 一律抛 `.attachFailed`）。
    ///
    /// 用 optional 而不是"永远指向一个 webView"：窗口关闭后 `WKWebView` 不可再求值，
    /// 留一个看起来可用的引用只会让失败点从"求值"漂移到别处。
    private let webView: WKWebView?
    private let closeSignal: WindowCloseSignal

    private let lock = NSLock()
    private var dead: Bool = false
    private var startupIdentifier: String?

    /// 日志用的通道名。只进日志，不参与任何判定。
    var kind: String { return "wk" }

    init(webView: WKWebView?, closeSignal: WindowCloseSignal) {
        self.webView = webView
        self.closeSignal = closeSignal
    }

    /// 标记通道彻底不可用（WebContent 进程被系统杀掉时由内核调用）。
    func markDead() {
        lock.lock()
        dead = true
        lock.unlock()
    }

    private var isDead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dead
    }

    /// 同步取/存 startup identifier。
    ///
    /// 刻意写成**同步**小函数：`NSLock.lock()` 出现在 `async` 上下文里在 Swift 6 语言模式
    /// 下是错误（"instance method 'lock' is unavailable from asynchronous contexts"）。
    /// 加锁本身仍需要（`isDead` 在非隔离上下文读）。
    private func takeStartupIdentifier() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return startupIdentifier
    }

    private func storeStartupIdentifier(_ value: String?) {
        lock.lock()
        startupIdentifier = value
        lock.unlock()
    }

    // MARK: - PageChannel

    func evaluate(_ expression: String, timeout: TimeInterval) async throws -> JSEvalResult {
        if isDead {
            throw MochiBoxError(code: .attachFailed, message: "WebContent 进程已终止")
        }
        if closeSignal.isClosed {
            throw MochiBoxError(code: .attachFailed, message: "窗口已关闭")
        }
        let result = await evaluateOnMain(expression, timeout: timeout)
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    func addStartupScript(_ source: String) async throws -> String {
        if isDead {
            throw MochiBoxError(code: .attachFailed, message: "WebContent 进程已终止")
        }
        return await addStartupScriptOnMain(source)
    }

    func removeStartupScript(_ identifier: String) async {
        await removeStartupScriptOnMain(identifier)
    }

    // MARK: - 主线程实现

    @MainActor
    private func evaluateOnMain(
        _ expression: String,
        timeout: TimeInterval
    ) async -> Result<JSEvalResult, Error> {
        guard let webView = webView else {
            return .failure(MochiBoxError(code: .attachFailed, message: "窗口已关闭"))
        }
        // 竞速：求值 vs 超时，谁先完成用谁。`WKWebView` **不支持取消**，
        // 所以超时之后那次求值的回调仍会到达 —— 用 `resumed` 保证续体只被 resume 一次。
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<JSEvalResult, Error>, Never>) in
            var resumed = false
            let once: (Result<JSEvalResult, Error>) -> Void = { outcome in
                if resumed { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            webView.evaluateJavaScript(expression) { value, error in
                once(WKPageChannel.bridge(value: value, error: error))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once(.failure(MochiBoxError(code: .cdpTimeout, message: "WK evaluate 超时")))
            }
        }
    }

    /// `WKUserScript` 只能在主线程改（`userContentController` 不是线程安全的）。
    ///
    /// **幂等**：第二次调用返回第一次的 identifier（协议要求；否则 `installEagerly`
    /// 每轮都会往页面里叠一份脚本）。
    @MainActor
    private func addStartupScriptOnMain(_ source: String) async -> String {
        if let existing = takeStartupIdentifier() { return existing }

        let identifier = "wk-user-script-\(UUID().uuidString)"
        if let webView = webView, !source.isEmpty {
            let script = WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(script)
        }
        storeStartupIdentifier(identifier)
        return identifier
    }

    @MainActor
    private func removeStartupScriptOnMain(_ identifier: String) {
        // WK 侧没有"按下标删一条"的 API（只能整组清空），而早装脚本必须活到页面销毁。
        // 这里只把 identifier 释放掉，让下一次 `addStartupScript` 能重新登记；
        // 副作用是"卸载后刷新仍会注入一次"，与 CDP 侧的 best-effort 卸载语义一致。
        if takeStartupIdentifier() == identifier {
            storeStartupIdentifier(nil)
        }
    }

    // MARK: - Any? → JSONValue 桥接（§3.3 表，最容易出"true 变成 1"的地方）

    /// `evaluateJavaScript` 的回调值 → `JSEvalResult`。
    ///
    /// 规则写死成表（架构 v0.4 §3.3）：
    /// | 回调值 | JSONValue | 说明 |
    /// |---|---|---|
    /// | `nil`（undefined） | `nil` | 与 CDP 一致（`result.value` 此时不存在） |
    /// | `NSNull` | `nil` | **不要**映射成 `.null`，否则 `value?.boolValue` 语义分叉 |
    /// | `NSString` | `.string` | 主路径：`__mochibox.drain()` / `probe()` 返回 JSON 字符串 |
    /// | `NSNumber`(Boolean) | `.bool` | 必须先判 Boolean，否则 `true` 会变 `1` |
    /// | `NSNumber` 其他 | `.number` | |
    /// | `NSArray` / `NSDictionary` | `.array` / `.object` | 逐项递归 |
    /// | 其他 | `nil` + `exceptionText` | 走异常分支，不当成通道故障 |
    static func bridge(value: Any?, error: Error?) -> Result<JSEvalResult, Error> {
        if let error = error {
            // JS 层抛异常（含 `WKError`）：这是**页面**的问题，不是通道故障 → 不 throw。
            return .success(JSEvalResult(
                value: nil,
                exceptionText: "\(error)",
                channelKind: "wk"
            ))
        }
        return .success(JSEvalResult(
            value: jsonValue(from: value),
            exceptionText: nil,
            channelKind: "wk"
        ))
    }

    /// 单个值的桥接（递归）。无法桥接的类型返回 `nil`（调用方按 undefined 处理）。
    static func jsonValue(from value: Any?) -> JSONValue? {
        guard let value = value else { return nil }
        if value is NSNull { return nil }
        if let text = value as? String { return .string(text) }
        if let number = value as? NSNumber {
            // 必须先判 Boolean：`NSNumber` 的 `boolValue` 在 `.number(1)` 上是 1 → `.bool` 会失真；
            // 反过来若先当 number，`true` 就变成 `1`，`result.value?.boolValue` 直接变 nil。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let array = value as? [Any] {
            return .array(array.map { jsonValue(from: $0) ?? .null })
        }
        if let dictionary = value as? [String: Any] {
            var object: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                object[key] = jsonValue(from: item) ?? .null
            }
            return .object(object)
        }
        return nil
    }
}
