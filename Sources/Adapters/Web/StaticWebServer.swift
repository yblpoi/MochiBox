//
//  StaticWebServer.swift
//  MochiBox
//
//  静态 Web 服务的**传输层**：`NWListener` 只绑回环、连接接受/复用/超时、
//  流式分块发送（`FileHandle` 链式发送，**禁止整读**）、`stop()` 时取消监听与全部连接。
//
//  约束（docs/archive/v0.2/architecture-v0.2-web-runner.md §2.1 N2、§4）：
//    · 只用 Network + Foundation + Darwin；不得 import AppKit / SwiftUI；
//    · 本目录"禁整读"门禁必须 **0 命中** —— 800MB 的 `.ogg` 整读会直接把内存打爆；
//    · 绑定必须只回环：`params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), …)`。
//

import Foundation
import Network
import Darwin

// MARK: - 单发续体

/// 只能被填一次、且"先填后装"也安全的续体盒。
///
/// 为什么不直接用 `withCheckedThrowingContinuation` + 一个 `Bool`：
/// `NWListener` 的 `.ready` / `.failed` 回调与超时任务是**两个线程**，而且可能
/// 在续体安装之前就到达（`.failed` 常常是同步的）。少一个状态位就是
/// "resumed twice" 崩溃或永久挂起。
final class OnceContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var filled = false

    func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending = pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        if filled {
            lock.unlock()
            return
        }
        filled = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

// MARK: - 回环端口探活

/// BSD socket 探活（只绑 `127.0.0.1`）。
///
/// 与 `GameLauncher.isPortFree` 共用**同一份**实现：两份必然漂移，
/// 症状是"启动前探测说空闲、bind 说占用"。
enum LoopbackPort {
    static func isFree(_ port: Int) -> Bool {
        guard port > 0, port <= 65535 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(K.loopbackHost))
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                return bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 等到端口真正可再绑（`listener.cancel()` 是异步生效的）。
    static func waitUntilFree(_ port: Int, timeoutSec: Double = 2.0) async -> Bool {
        if isFree(port) { return true }
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if isFree(port) { return true }
        }
        return isFree(port)
    }
}

// MARK: - 连接注册表

/// 连接登记表（**非 actor**）。
///
/// `stop()` 必须能"立刻、同步地"把全部在飞连接和 `FileHandle` 收干净；
/// 走 actor 隔离就得 `await` 一串回调，而回调又可能回到同一个队列 ——
/// 死锁风险与"停止后端口还被占"的残留都从这里来。
final class WebConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ObjectIdentifier: StaticWebConnection] = [:]
    private var acceptedTotal: Int = 0
    private var servedTotal: Int = 0

    /// 超过并发上限时返回 false（调用方回 503）。
    func register(_ connection: StaticWebConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if items.count >= K.webMaxConcurrentConnections { return false }
        items[ObjectIdentifier(connection)] = connection
        acceptedTotal += 1
        return true
    }

    func unregister(_ connection: StaticWebConnection) {
        lock.lock()
        items.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func noteRequestServed() {
        lock.lock()
        servedTotal += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    var totalAccepted: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedTotal
    }

    var totalServed: Int {
        lock.lock()
        defer { lock.unlock() }
        return servedTotal
    }

    func closeAll() {
        lock.lock()
        let snapshot = Array(items.values)
        items.removeAll()
        lock.unlock()
        for connection in snapshot {
            connection.forceClose()
        }
    }
}

// MARK: - 单连接

/// 单条 TCP 连接上的 HTTP/1.1 状态机（keep-alive，**不做 pipelining**）。
///
/// 所有回调都跑在同一个串行队列上（`connection.start(queue:)` 决定），
/// 因此 `buffer` / `served` 是队列私有状态；只有 `closed` 与在飞 `FileHandle`
/// 需要跨线程（`forceClose()` 来自 `stop()`）而加锁。
final class StaticWebConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let root: URL
    private let queue: DispatchQueue
    private let log: SessionLog?
    private let registry: WebConnectionRegistry
    /// 带 alpha 的 .mpon 按需转成 HEVC-with-alpha；返回 nil 就照原样服务（.webm 一律不换，见该文件注释）。
    private let renditions: MediaRenditions

    private let stateLock = NSLock()
    private var closed = false
    private var handles: [FileHandle] = []

    // 队列私有状态（只在该串行队列上访问）
    private var buffer = Data()
    private var served = 0
    private var idleGeneration = 0

    init(
        connection: NWConnection,
        root: URL,
        queue: DispatchQueue,
        log: SessionLog?,
        registry: WebConnectionRegistry,
        renditions: MediaRenditions
    ) {
        self.connection = connection
        self.root = root
        self.queue = queue
        self.log = log
        self.registry = registry
        self.renditions = renditions
    }

    // MARK: 生命周期

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
            case .failed(let error):
                self.log?.debug("StaticWebServer", "连接失败", ["error": "\(error)"])
                self.close()
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// 并发上限命中：直接回 503 再关（不注册、不进状态机）。
    func startRejected() {
        let body = Data("503 service_unavailable\n".utf8)
        let head = StaticWebRequest.responseHead(status: 503, headers: [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close"
        ])
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: queue)
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    /// `stop()` 走这条路：幂等、可重入、关掉全部在飞 `FileHandle`。
    func forceClose() {
        close()
    }

    private func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let openHandles = handles
        handles.removeAll()
        stateLock.unlock()

        for handle in openHandles {
            try? handle.close()
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        registry.unregister(self)
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func track(_ handle: FileHandle) -> Bool {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            try? handle.close()
            return false
        }
        handles.append(handle)
        stateLock.unlock()
        return true
    }

    private func untrack(_ handle: FileHandle) {
        stateLock.lock()
        handles.removeAll { $0 === handle }
        stateLock.unlock()
        try? handle.close()
    }

    // MARK: 接收

    private func receiveLoop() {
        if isClosed { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, !self.isClosed else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
            }
            if let error = error {
                self.log?.debug("StaticWebServer", "连接读失败", ["error": "\(error)"])
                self.close()
                return
            }
            self.pumpRequests()
        }
    }

    /// 把缓冲区里的请求一条条处理掉（残留字节当作下一条请求的开头）。
    private func pumpRequests() {
        if isClosed { return }
        idleGeneration += 1

        if buffer.isEmpty {
            armIdleTimer()
            receiveLoop()
            return
        }

        guard let parsed = StaticWebRequest.parseHead(buffer) else {
            if buffer.count > K.webMaxHeadBytes {
                // 头部超限：回 431 并关连接（继续收只会被同样的垃圾撑爆内存）。
                sendSimple(status: 431, reason: "request_header_too_large", extraHeaders: [], closeAfter: true)
            } else {
                receiveLoop()
            }
            return
        }

        buffer.removeFirst(parsed.consumed)
        respond(to: parsed.head)
    }

    /// keep-alive 空闲计时：到点且期间没有任何新请求就关。
    private func armIdleTimer() {
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + K.webKeepAliveIdleSec) { [weak self] in
            guard let self = self, !self.isClosed else { return }
            guard self.idleGeneration == generation, self.buffer.isEmpty else { return }
            self.close()
        }
    }

    // MARK: 响应

    private func respond(to head: StaticWebRequest.RequestHead) {
        let keepAlive = !head.wantsClose
        trace("\(head.method) \(head.target)")

        guard head.method == "GET" || head.method == "HEAD" else {
            sendSimple(
                status: 405,
                reason: "method_not_allowed",
                extraHeaders: ["Allow: GET, HEAD"],
                closeAfter: true
            )
            return
        }

        let resolvedURL: URL
        do {
            switch try StaticWebRequest.resolve(target: head.target, root: root) {
            case .file(let url), .directoryIndex(let url):
                resolvedURL = url
            }
        } catch let error as StaticWebRequest.ResolutionError {
            trace("  -> \(error.status) \(error.reason)")
            sendSimple(
                status: error.status,
                reason: error.reason,
                extraHeaders: [],
                closeAfter: error.status == 400
            )
            return
        } catch {
            sendSimple(status: 404, reason: "not_found", extraHeaders: [], closeAfter: false)
            return
        }

        // 按需转码：解析与越权校验都已通过（resolvedURL 一定落在 root 内），
        // 替换发生在校验**之后**、stat 之前，所以不会绕过 root 检查。
        // 返回 nil（无 ffmpeg / 无 alpha / 转码失败）时就照原样服务原始字节。
        let fileURL = renditions.rendition(for: resolvedURL.path)
            .map { URL(fileURLWithPath: $0) } ?? resolvedURL

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeNumber = attributes?[.size] as? NSNumber
        guard let sizeNumber = sizeNumber else {
            sendSimple(status: 404, reason: "not_found", extraHeaders: [], closeAfter: false)
            return
        }
        let fileSize = sizeNumber.int64Value

        var status = 200
        var offset: Int64 = 0
        var bodyLength: Int64 = fileSize
        var extraHeaders: [String] = []

        if let rawRange = head.rangeHeader, !rawRange.isEmpty {
            switch StaticWebRequest.parseRange(rawRange, fileSize: fileSize) {
            case .satisfiable(let range):
                status = 206
                offset = range.start
                bodyLength = range.length
                extraHeaders.append("Content-Range: bytes \(range.start)-\(range.end)/\(fileSize)")
            case .unsatisfiable:
                sendSimple(
                    status: 416,
                    reason: "range_not_satisfiable",
                    extraHeaders: ["Content-Range: bytes */\(fileSize)"],
                    closeAfter: !keepAlive
                )
                return
            case .none, .ignore:
                break
            }
        }

        var headers = extraHeaders
        headers.append("Content-Type: \(StaticWebRequest.mimeType(forPath: fileURL.path))")
        headers.append("Content-Length: \(bodyLength)")
        headers.append("Connection: \(keepAlive ? "keep-alive" : "close")")

        var headText = "HTTP/1.1 \(status) \(StaticWebRequest.statusText(status))\r\n"
        for line in headers { headText += line + "\r\n" }
        headText += StaticWebRequest.commonHeaders(
            cacheMaxAge: StaticWebRequest.cacheMaxAge(forPath: fileURL.path)
        )
        headText += "\r\n"

        trace("  -> \(status) bytes=\(bodyLength) type=\(StaticWebRequest.mimeType(forPath: fileURL.path))")
        let isHeadOnly = head.method == "HEAD"
        let hasBody = !isHeadOnly && bodyLength > 0
        send(
            data: Data(headText.utf8),
            isComplete: !hasBody,
            completion: { [weak self] ok in
                guard let self = self else { return }
                if !ok {
                    self.close()
                    return
                }
                self.registry.noteRequestServed()
                if !hasBody {
                    self.responseFinished(keepAlive: keepAlive)
                    return
                }
                self.streamFile(url: fileURL, offset: offset, length: bodyLength, keepAlive: keepAlive)
            }
        )
    }

    /// 流式分块发送：`send` 完成回调里才读下一块 → 单连接在飞数据恒定 ≈ 1 块。
    private func streamFile(url: URL, offset: Int64, length: Int64, keepAlive: Bool) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            log?.warn("StaticWebServer", "打开文件失败", ["path": url.path, "error": "\(error)"])
            sendSimple(status: 500, reason: "io_error", extraHeaders: [], closeAfter: true)
            return
        }
        guard track(handle) else { return }

        var remaining = length
        let chunkSize = K.webChunkBytes

        func pump() {
            if isClosed {
                untrack(handle)
                return
            }
            if remaining <= 0 {
                untrack(handle)
                responseFinished(keepAlive: keepAlive)
                return
            }
            let want = Int(min(Int64(chunkSize), remaining))
            // `read(upToCount:)` 的 **nil 是 EOF，不是错误**（QA 门禁条：静态服务禁整读，
            // 唯一允许的读法就是 seek + read(upToCount:)，所以这里必须把两种失败分开）。
            // 把它一律当错误会在"文件比 Content-Length 短"时多一次无意义 warn；
            // 更要紧的是别写成"只读一次就返回"—— 那会丢最后一块，
            // 症状是音频播到 99% 卡住（浏览器等最后那几个字节）。
            let readResult: Data?
            do {
                readResult = try handle.read(upToCount: want)
            } catch {
                log?.warn("StaticWebServer", "读文件失败", ["path": url.path, "error": "\(error)"])
                untrack(handle)
                close()
                return
            }
            guard let chunk = readResult, !chunk.isEmpty else {
                // EOF：`length` 由 fileSize 算出，正常路径不可达 —— 只有文件在发送过程中
                // 被截断才会提前 EOF。`Content-Length` 已经发出去了，没法"补"；
                // 关连接让浏览器看到中断并重试，比假装发送成功更诚实。
                if remaining > 0 {
                    log?.warn("StaticWebServer", "文件提前结束（可能被截断）", [
                        "path": url.path,
                        "remaining": "\(remaining)"
                    ])
                }
                untrack(handle)
                close()
                return
            }
            remaining -= Int64(chunk.count)
            send(data: chunk, isComplete: remaining == 0, completion: { ok in
                if !ok {
                    self.untrack(handle)
                    self.close()
                    return
                }
                pump()
            })
        }
        pump()
    }

    private func sendSimple(
        status: Int,
        reason: String,
        extraHeaders: [String],
        closeAfter: Bool
    ) {
        let body = Data("\(status) \(reason)\n".utf8)
        var headers = extraHeaders
        headers.append("Content-Type: text/plain; charset=utf-8")
        headers.append("Content-Length: \(body.count)")
        headers.append("Connection: \(closeAfter ? "close" : "keep-alive")")
        let headText = StaticWebRequest.responseHead(status: status, headers: headers)
        send(data: Data(headText.utf8) + body, isComplete: true, completion: { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                self.close()
                return
            }
            self.registry.noteRequestServed()
            self.responseFinished(keepAlive: !closeAfter)
        })
    }

    private func send(data: Data, isComplete: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: isComplete,
            completion: .contentProcessed { error in
                completion(error == nil)
            }
        )
    }

    /// 请求追踪（`MOCHI_WEB_TRACE=1` 时打到 stderr）。
    ///
    /// 为什么留着：`--play` 挂起时（游戏卡在黑屏/加载页）唯一能问的是"页面到底请求了什么、
    /// 哪个没回"。`--selftest` 与 E2E 都不开它，正常路径零开销（一个静态 bool）。
    static let traceEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["MOCHI_WEB_TRACE"] ?? ""
        return !value.isEmpty && value != "0"
    }()

    private func trace(_ message: String) {
        guard StaticWebConnection.traceEnabled else { return }
        FileHandle.standardError.write(Data("[web] \(message)\n".utf8))
    }

    private func responseFinished(keepAlive: Bool) {
        served += 1
        if !keepAlive || served >= K.webMaxRequestsPerConnection || isClosed {
            close()
            return
        }
        pumpRequests()
    }
}

// MARK: - 服务器

/// 静态文件服务器（actor：`start` / `stop` / `activeConnections` 都是串行入口）。
actor StaticWebServer {
    private let root: URL
    private let requestedPort: Int
    private let log: SessionLog?

    private let listenerQueue = DispatchQueue(label: "mochibox.web.listener")
    private let connectionQueue = DispatchQueue(label: "mochibox.web.conn", attributes: .concurrent)
    private let registry = WebConnectionRegistry()
    /// 整个服务器共享一份（探测结论与转码产物按源文件缓存，翻页/重播不再 spawn）。
    private let renditions: MediaRenditions

    private var listener: NWListener?
    private var boundPort: Int = 0

    init(root: URL, port: Int, log: SessionLog? = nil) {
        self.root = root.standardizedFileURL
        self.requestedPort = port
        self.log = log
        self.renditions = MediaRenditions(log: log)
    }

    /// 实际绑定端口（`start()` 之前为 0）。
    var port: Int { return boundPort }

    var activeConnections: Int { return registry.count }

    var totalRequestsServed: Int { return registry.totalServed }

    var totalConnectionsAccepted: Int { return registry.totalAccepted }

    /// 起监听并等到 `.ready`。返回实际绑定端口。
    ///
    /// `.failed(.posix(.EADDRINUSE))` → `web_port_busy`；其余 → `web_server_failed`。
    /// 启动前的 `LoopbackPort.isFree` 只是**快路径**（省一条日志），不能据此认为绑定一定成功
    /// （探测与 bind 之间端口可能被抢，TOCTOU 两条路径都必须处理）。
    func start() async throws -> Int {
        if listener != nil, boundPort > 0 { return boundPort }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: requestedPort)) else {
            throw MochiBoxError(
                code: .webServerFailed,
                message: "静态服务端口 \(requestedPort) 超出 1–65535（detail: web_server_failed）"
            )
        }

        let parameters = NWParameters.tcp
        // 重启后不吃 TIME_WAIT。
        parameters.allowLocalEndpointReuse = true
        // **只绑回环**：绝不能落到 0.0.0.0（PRD 合规声明 + AGENTS 记忆）。
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            throw MochiBoxError(
                code: .webServerFailed,
                message: "无法创建静态服务监听器（端口 \(requestedPort)）",
                underlying: "\(error)"
            )
        }

        let gate = OnceContinuation<Int>()
        let root = self.root
        let log = self.log
        let registry = self.registry
        let connectionQueue = self.connectionQueue
        let requestedPort = self.requestedPort
        let renditions = self.renditions

        created.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.resolve(.success(Int(created.port?.rawValue ?? 0)))
            case .failed(let error):
                gate.resolve(.failure(StaticWebServer.mapListenerError(error, port: requestedPort)))
            case .cancelled:
                gate.resolve(.failure(MochiBoxError(
                    code: .webServerFailed,
                    message: "静态服务监听器被取消（端口 \(requestedPort)）"
                )))
            default:
                break
            }
        }
        created.newConnectionHandler = { connection in
            let handler = StaticWebConnection(
                connection: connection,
                root: root,
                queue: connectionQueue,
                log: log,
                registry: registry,
                renditions: renditions
            )
            if registry.register(handler) {
                handler.start()
            } else {
                log?.warn("StaticWebServer", "并发连接数已达上限，回 503", [
                    "limit": "\(K.webMaxConcurrentConnections)"
                ])
                handler.startRejected()
            }
        }
        created.start(queue: listenerQueue)
        listener = created

        let timeoutTask = Task { () -> Void in
            try? await Task.sleep(nanoseconds: UInt64(K.webListenerReadyTimeoutSec * 1_000_000_000))
            gate.resolve(.failure(MochiBoxError(
                code: .webServerFailed,
                message: "静态服务 \(Int(K.webListenerReadyTimeoutSec))s 内未就绪（端口 \(requestedPort)）"
            )))
        }

        do {
            let readyPort = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int, Error>) in
                gate.setContinuation(continuation)
            }
            timeoutTask.cancel()
            boundPort = readyPort
            log?.info("StaticWebServer", "静态服务已就绪", [
                "root": root.path,
                "port": "\(readyPort)",
                "loopback": K.loopbackHost
            ])
            return readyPort
        } catch {
            timeoutTask.cancel()
            created.stateUpdateHandler = nil
            created.newConnectionHandler = nil
            created.cancel()
            listener = nil
            boundPort = 0
            throw error
        }
    }

    /// 幂等：1) cancel listener 2) 逐连接 cancel 并关在飞 `FileHandle` 3) 清空集合。
    func stop() async {
        let current = listener
        let port = boundPort
        listener = nil
        boundPort = 0

        current?.stateUpdateHandler = nil
        current?.newConnectionHandler = nil
        current?.cancel()
        registry.closeAll()

        if port > 0 {
            // `cancel()` 是异步生效的：等端口真正可再绑，否则立刻重启会假 `web_port_busy`。
            _ = await LoopbackPort.waitUntilFree(port)
            log?.info("StaticWebServer", "静态服务已停止", ["port": "\(port)"])
        }
    }

    /// `.failed` 的 `NWError` → 产品错误码（macOS 上只有 `.posix` / `.dns` / `.tls`）。
    nonisolated static func mapListenerError(_ error: NWError, port: Int) -> MochiBoxError {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return MochiBoxError(
                code: .webPortBusy,
                message: "静态服务端口 \(port) 已被占用（detail: web_port_busy）。"
                    + "可能是上一次会话的浏览器/服务没退干净：先退出正在运行的游戏再重试。",
                underlying: "\(error)"
            )
        }
        return MochiBoxError(
            code: .webServerFailed,
            message: "静态服务监听失败（端口 \(port)）",
            underlying: "\(error)"
        )
    }
}
