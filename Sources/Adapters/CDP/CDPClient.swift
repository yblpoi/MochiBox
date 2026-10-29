//
//  CDPClient.swift
//  MochiBox
//
//  Chrome DevTools Protocol 客户端。必须走 browser 级端点 + Target.attachToTarget(flatten) + sessionId
//  （docs/archive/v0.1/cdp-validation.md 坑 1：直连 page 级 WebSocket 在本机只握手成功、evaluate 永无响应）。
//

import Foundation

// MARK: - 数据类型

struct CDPTarget: Sendable, Decodable {
    var id: String
    var type: String
    var title: String?
    var url: String
    var webSocketDebuggerUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, url, webSocketDebuggerUrl
    }
}

struct CDPBrowserVersion: Sendable, Decodable {
    var browser: String
    var protocolVersion: String?
    var webSocketDebuggerUrl: String

    enum CodingKeys: String, CodingKey {
        case browser, protocolVersion, webSocketDebuggerUrl
    }
}

struct CDPSession: Sendable {
    var sessionId: String
    var targetId: String
    var url: String
    var flatten: Bool
}

/// 求值结果。
///
/// v0.4 起是 `JSEvalResult` 的**别名**（`Sources/Adapters/PageChannel/PageChannel.swift`）：
/// 两个通道实现必须产出同一个类型，否则 `AgentInjector` 里要写两份解码。
/// 旧名字保留一个版本，减少 churn（架构 v0.4 §3.2）。
typealias CDPEvaluateResult = JSEvalResult

struct CDPEvent: Sendable {
    var method: String
    var params: JSONValue?
    var sessionId: String?
}

struct CDPOptions: Sendable {
    var discoverPollMs: Int = K.cdpDiscoverPollMs
    var discoverTimeoutSec: Double = K.cdpAttachTimeoutSec
    var handshakeTimeoutSec: Double = K.wsHandshakeTimeoutSec
    var evaluateTimeoutSec: Double = K.evaluateTimeoutSec
}

// MARK: - 客户端

actor CDPClient {
    private enum PendingSlot {
        case waiting
        case done(JSONValue)
        case failed(MochiBoxError)
    }

    private let port: Int
    private let options: CDPOptions
    private let poster: HTTPPoster

    private var webSocket: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var nextId: Int = 1
    private var pending: [Int: PendingSlot] = [:]
    private var handlers: [@Sendable (CDPEvent) -> Void] = []
    private var targetURLs: [String: String] = [:]
    private var isClosed: Bool = false
    private var lastHTTPStatus: Int = 0
    private var lastHTTPBody: String = ""

    init(port: Int, options: CDPOptions = CDPOptions()) {
        self.port = port
        self.options = options
        self.poster = HTTPPoster()
    }

    // MARK: - HTTP 发现（仅用于"端口起来了没有"）

    func discoverTargets() async throws -> [CDPTarget] {
        guard let url = URL(string: "http://\(K.loopbackHost):\(port)/json/list") else {
            throw MochiBoxError(code: .attachFailed, message: "非法端口 \(port)")
        }
        let (status, data) = try await poster.getJSON(url: url, timeout: options.handshakeTimeoutSec)
        lastHTTPStatus = status
        lastHTTPBody = String(decoding: data.prefix(K.rawSnippetLimit * 2), as: UTF8.self)
        guard status == 200 else {
            throw MochiBoxError(code: .attachFailed, message: "GET /json/list 返回 \(status)", httpStatus: status, rawSnippet: lastHTTPBody)
        }
        guard let array = try? JSONDecoder().decode([CDPTarget].self, from: data) else {
            throw MochiBoxError(code: .attachFailed, message: "GET /json/list 响应不是目标数组", httpStatus: status, rawSnippet: lastHTTPBody)
        }
        return array
    }

    /// 轮询直到出现 `type == "page"` 的目标（250ms / 25s）。
    func waitForReady(timeoutSec: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSec)
        var attempts = 0
        while Date() < deadline {
            attempts += 1
            if let targets = try? await discoverTargets(), targets.contains(where: { $0.type == "page" }) {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(max(1, options.discoverPollMs)) * 1_000_000)
        }
        throw MochiBoxError(
            code: .cdpTimeout,
            message: "等待调试端口超时（\(Int(timeoutSec))s，端口 \(port)，轮询 \(attempts) 次）",
            httpStatus: lastHTTPStatus == 0 ? nil : lastHTTPStatus,
            rawSnippet: lastHTTPBody.isEmpty ? nil : lastHTTPBody
        )
    }

    func browserVersion() async throws -> CDPBrowserVersion {
        guard let url = URL(string: "http://\(K.loopbackHost):\(port)/json/version") else {
            throw MochiBoxError(code: .attachFailed, message: "非法端口 \(port)")
        }
        let (status, data) = try await poster.getJSON(url: url, timeout: options.handshakeTimeoutSec)
        let bodyText = String(decoding: data.prefix(K.rawSnippetLimit), as: UTF8.self)
        guard status == 200,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              // Chromium 的键名混用大小写：`Browser` / `Protocol-Version` / `webSocketDebuggerUrl`
              let socketURL = (value["webSocketDebuggerUrl"] ?? value["WebSocketDebuggerUrl"])?.stringValue,
              !socketURL.isEmpty else {
            throw MochiBoxError(
                code: .attachFailed,
                message: "GET /json/version 不可用（\(status)）",
                httpStatus: status,
                rawSnippet: bodyText
            )
        }
        let browser = (value["Browser"] ?? value["browser"])?.stringValue ?? ""
        let protocolVersion = (value["Protocol-Version"] ?? value["protocolVersion"])?.stringValue
        return CDPBrowserVersion(
            browser: browser,
            protocolVersion: protocolVersion,
            webSocketDebuggerUrl: socketURL
        )
    }

    // MARK: - WebSocket

    func connect(webSocketURL: String) async throws {
        guard let url = URL(string: webSocketURL) else {
            throw MochiBoxError(code: .attachFailed, message: "非法 WebSocket 地址：\(webSocketURL)")
        }
        isClosed = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = options.evaluateTimeoutSec
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.webSocketSession = session
        self.webSocket = task
        startReceiveLoop(task)

        // 握手探测：browser 级轻量请求。
        do {
            _ = try await request(
                method: "Target.getTargets",
                params: nil,
                sessionId: nil,
                timeout: options.handshakeTimeoutSec
            )
        } catch let error as MochiBoxError {
            await close()
            if error.message.contains("403") || error.message.contains("Handshake") {
                throw MochiBoxError(
                    code: .attachFailed,
                    message: "WebSocket 握手被拒绝（可能需要 --remote-allow-origins）：\(error.message)"
                )
            }
            throw error
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while true {
                if Task.isCancelled { return }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self?.handleIncoming(text)
                    case .data(let data):
                        await self?.handleIncoming(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        break
                    }
                } catch {
                    await self?.handleTransportClosed(error)
                    return
                }
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return
        }
        if let id = value["id"]?.intValue {
            if let errorObject = value["error"], errorObject != .null {
                let message = errorObject["message"]?.stringValue ?? "CDP 错误"
                pending[id] = .failed(MochiBoxError(
                    code: .attachFailed,
                    message: message,
                    rawSnippet: errorObject.jsonText()
                ))
            } else {
                pending[id] = .done(value["result"] ?? .null)
            }
            return
        }
        if let method = value["method"]?.stringValue {
            let event = CDPEvent(
                method: method,
                params: value["params"],
                sessionId: value["sessionId"]?.stringValue
            )
            for handler in handlers {
                handler(event)
            }
        }
    }

    private func handleTransportClosed(_ error: Error) {
        let failure = MochiBoxError(code: .attachFailed, message: "WebSocket 已断开：\(error)", underlying: "\(error)")
        for (id, slot) in pending {
            if case .waiting = slot {
                pending[id] = .failed(failure)
            }
        }
    }

    func onEvent(_ handler: @escaping @Sendable (CDPEvent) -> Void) {
        handlers.append(handler)
    }

    // MARK: - 请求/响应

    private func request(
        method: String,
        params: JSONValue?,
        sessionId: String?,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        guard let task = webSocket, !isClosed else {
            throw MochiBoxError(code: .attachFailed, message: "WebSocket 未连接")
        }
        let id = nextId
        nextId += 1

        var payload: [String: JSONValue] = [
            "id": .number(Double(id)),
            "method": .string(method)
        ]
        if let params = params { payload["params"] = params }
        if let sessionId = sessionId { payload["sessionId"] = .string(sessionId) }
        let text = JSONValue.object(payload).jsonText()

        pending[id] = .waiting
        do {
            try await task.send(.string(text))
        } catch {
            pending.removeValue(forKey: id)
            throw MochiBoxError(
                code: .attachFailed,
                message: "WebSocket 发送失败：\(error)",
                underlying: "\(error)"
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let slot = pending[id] {
                switch slot {
                case .done(let value):
                    pending.removeValue(forKey: id)
                    return value
                case .failed(let error):
                    pending.removeValue(forKey: id)
                    throw error
                case .waiting:
                    break
                }
            } else {
                throw MochiBoxError(code: .attachFailed, message: "CDP 请求 \(method) 已被关闭")
            }
            if Date() >= deadline {
                pending.removeValue(forKey: id)
                throw MochiBoxError(code: .cdpTimeout, message: "CDP 请求超时：\(method)")
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func send(
        _ method: String,
        params: JSONValue? = nil,
        sessionId: String? = nil,
        timeout: TimeInterval = K.evaluateTimeoutSec
    ) async throws -> JSONValue {
        return try await request(method: method, params: params, sessionId: sessionId, timeout: timeout)
    }

    // MARK: - Target

    /// `Target.getTargets`
    func listTargets() async throws -> [CDPTarget] {
        let result = try await request(method: "Target.getTargets", params: nil, sessionId: nil, timeout: options.evaluateTimeoutSec)
        var targets: [CDPTarget] = []
        guard let infos = result["targetInfos"]?.arrayValue else { return targets }
        for info in infos {
            guard let targetId = info["targetId"]?.stringValue else { continue }
            let url = info["url"]?.stringValue ?? ""
            targetURLs[targetId] = url
            targets.append(CDPTarget(
                id: targetId,
                type: info["type"]?.stringValue ?? "unknown",
                title: info["title"]?.stringValue,
                url: url,
                webSocketDebuggerUrl: nil
            ))
        }
        return targets
    }

    /// `Target.attachToTarget { flatten: true }` → `sessionId`
    func attach(to targetId: String) async throws -> CDPSession {
        let params: JSONValue = .object([
            "targetId": .string(targetId),
            "flatten": .bool(true)
        ])
        let result = try await request(
            method: "Target.attachToTarget",
            params: params,
            sessionId: nil,
            timeout: options.evaluateTimeoutSec
        )
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw MochiBoxError(code: .attachFailed, message: "attachToTarget 未返回 sessionId（该浏览器可能不支持 flatten）")
        }
        return CDPSession(
            sessionId: sessionId,
            targetId: targetId,
            url: targetURLs[targetId] ?? "",
            flatten: true
        )
    }

    func detach(_ session: CDPSession) async throws {
        let params: JSONValue = .object(["sessionId": .string(session.sessionId)])
        _ = try? await request(
            method: "Target.detachFromTarget",
            params: params,
            sessionId: nil,
            timeout: options.evaluateTimeoutSec
        )
    }

    // MARK: - 常用域封装

    func enablePage(_ session: CDPSession) async throws {
        _ = try await request(method: "Page.enable", params: nil, sessionId: session.sessionId, timeout: options.evaluateTimeoutSec)
    }

    func enableRuntime(_ session: CDPSession) async throws {
        _ = try await request(method: "Runtime.enable", params: nil, sessionId: session.sessionId, timeout: options.evaluateTimeoutSec)
    }

    /// 可选加速通道；失败不影响主链路（主链路是 drain 轮询）。
    func addBinding(_ session: CDPSession, name: String) async throws {
        let params: JSONValue = .object(["name": .string(name)])
        _ = try await request(method: "Runtime.addBinding", params: params, sessionId: session.sessionId, timeout: options.evaluateTimeoutSec)
    }

    func addScriptToEvaluateOnNewDocument(_ session: CDPSession, source: String) async throws -> String {
        let params: JSONValue = .object(["source": .string(source)])
        let result = try await request(
            method: "Page.addScriptToEvaluateOnNewDocument",
            params: params,
            sessionId: session.sessionId,
            timeout: options.evaluateTimeoutSec
        )
        return result["identifier"]?.stringValue ?? ""
    }

    func removeScriptToEvaluateOnNewDocument(_ session: CDPSession, identifier: String) async throws {
        let params: JSONValue = .object(["identifier": .string(identifier)])
        _ = try await request(
            method: "Page.removeScriptToEvaluateOnNewDocument",
            params: params,
            sessionId: session.sessionId,
            timeout: options.evaluateTimeoutSec
        )
    }

    func evaluate(
        _ session: CDPSession,
        expression: String,
        awaitPromise: Bool = false,
        timeout: TimeInterval = K.evaluateTimeoutSec
    ) async throws -> CDPEvaluateResult {
        let params: JSONValue = .object([
            "expression": .string(expression),
            "returnByValue": .bool(true),
            "awaitPromise": .bool(awaitPromise),
            "userGesture": .bool(false)
        ])
        let result = try await request(
            method: "Runtime.evaluate",
            params: params,
            sessionId: session.sessionId,
            timeout: timeout
        )
        let exceptionText = result["exceptionDetails"]?["text"]?.stringValue
        let value = result["result"]?["value"]
        return CDPEvaluateResult(value: value, exceptionText: exceptionText, channelKind: "cdp")
    }

    // MARK: - 关闭

    func close() async {
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        let failure = MochiBoxError(code: .attachFailed, message: "CDP 连接已关闭")
        for (id, slot) in pending {
            if case .waiting = slot {
                pending[id] = .failed(failure)
            }
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil
    }
}
