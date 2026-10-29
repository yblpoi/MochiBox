//
//  CDPSessionChannel.swift
//  MochiBox
//
//  `PageChannel` 的 CDP 薄壳（架构 v0.4 §3.2 末尾）。
//
//  **这里不许出现任何新的 CDP 语义**：只做类型收窄（把 `cdp + session` 这一对收成一个
//  `PageChannel`），每个方法都是一次转发。要改 CDP 行为请改 `CDPClient`，
//  否则两处必然漂移（"两套过滤逻辑"同型坑）。
//
//  为什么需要薄壳而不是让 `CDPClient` 自己实现协议：
//  `CDPClient.evaluate(_ session:...)` 与协议 `evaluate(_ expression:...)` 首参类型不同，
//  重载共存虽能编译，但读代码的人会看错；薄壳把"哪个 session"变成构造参数，一眼可见。
//

import Foundation

/// `CDPClient` + `CDPSession` → `PageChannel`。
///
/// `@unchecked Sendable`：自身无状态（两个 let 都指向 actor 或值类型），
/// 所有状态都在 `CDPClient` 这个 actor 里。
final class CDPSessionChannel: PageChannel, @unchecked Sendable {
    private let cdp: CDPClient
    private let session: CDPSession

    var kind: String { return "cdp" }

    init(cdp: CDPClient, session: CDPSession) {
        self.cdp = cdp
        self.session = session
    }

    func evaluate(_ expression: String, timeout: TimeInterval) async throws -> JSEvalResult {
        let result = try await cdp.evaluate(
            session,
            expression: expression,
            awaitPromise: false,
            timeout: timeout
        )
        return JSEvalResult(
            value: result.value,
            exceptionText: result.exceptionText,
            channelKind: kind
        )
    }

    func addStartupScript(_ source: String) async throws -> String {
        return try await cdp.addScriptToEvaluateOnNewDocument(session, source: source)
    }

    func removeStartupScript(_ identifier: String) async {
        try? await cdp.removeScriptToEvaluateOnNewDocument(session, identifier: identifier)
    }
}
