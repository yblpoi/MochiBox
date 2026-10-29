//
//  ControlServer.swift
//  MochiBox
//
//  测试专用的进程外控制通道（v0.6 E2E）：unix domain socket + NDJSON，一行一请求一行一响应。
//
//  为什么需要它：`--play` 是个"跑完就退出"的黑盒 —— 进程外的 QA 脚本只能在开局布参数、
//  结束时读 stdout，**没法在会话中间**问一句"现在采到几条"、更没法驱动一次关窗。E12/E15
//  这类"要看中间态"的矩阵条目因此只能靠人盯屏幕。
//
//  三条刻意的约束：
//    1. **只有 MOCHI_E2E=1 才生效**（门禁在 `AttachCLI.bootstrap`）。这里能跑任意 JS，
//       产品会话里绝不允许凭空多出一个本地 socket。
//    2. **纯 Foundation + Darwin**：Adapters 层不许 import SwiftUI/AppKit（build.sh 门禁），
//       也不用 Network.framework —— 它没有公开的 UDS 端点（`NWEndpoint.unix` 是私有）。
//    3. **控制通道故障绝不影响主流程**：起不来就只打一行 `play: control=disabled`，
//       `--play` 照常跑到底。
//
//  协议（NDJSON，一行一条）：
//    请求 {"id": <string|number>, "op": "<name>", ...}
//    应答 {"id": <同值>, "ok": true, ...} / {"id": <同值>, "ok": false, "error": "<code>", "message": "<text>"}
//  op 只有五个：ping / eval / state / close / quit。**不要扩展**：每多一个 op 就多一条
//  能改变被测进程状态的路径，而这些路径在正式产品里没有任何对应物。
//

import Foundation
import Darwin

// MARK: - 实时观测面

/// drain 循环写、ControlServer 读的一小块共享状态。
///
/// 为什么单独存在：`RunStats` 是 `drainPhase` 的**局部值**，函数返回前外面拿不到；
/// `state` 要的是"此刻"，不是"结束时"。这里只放计数器与几个只读标签，
/// **不碰** drain 的任何判定逻辑（写进来只是照抄，绝不回写）。
final class ControlLiveState: @unchecked Sendable {
    struct Snapshot: Sendable {
        var captured: Int = 0
        var translated: Int = 0
        var skipped: Int = 0
        var closed: Bool = false
        /// E15 探针最后看到的场景名；`nil` = 还没探过。
        var scene: String? = nil
        /// `embedded` | `chromium`（只进日志/应答，不参与判定）。
        var kernel: String = "embedded"
        /// `quit` 已经把应答写回连接之后才置位（顺序见 `ControlServer.reply`）。
        var quitRequested: Bool = false

        init(kernel: String) {
            self.kernel = kernel
        }
    }

    private let lock = NSLock()
    private var snapshot: Snapshot

    init(kernel: String) {
        self.snapshot = Snapshot(kernel: kernel)
    }

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var quitRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.quitRequested
    }

    /// 由 drain 循环在每轮末尾调用（照抄 `RunStats`，不改它）。
    func updateCounters(captured: Int, translated: Int, skipped: Int, closed: Bool) {
        lock.lock()
        snapshot.captured = captured
        snapshot.translated = translated
        snapshot.skipped = skipped
        snapshot.closed = closed
        lock.unlock()
    }

    func setScene(_ scene: String?) {
        lock.lock()
        snapshot.scene = scene
        lock.unlock()
    }

    func requestQuit() {
        lock.lock()
        snapshot.quitRequested = true
        lock.unlock()
    }
}

// MARK: - 服务端

/// unix socket 控制服务端。生命周期由 `AttachCLI.runPlay` 掌握：
/// attach 成功之后 `start()`，drain 一结束就 `stop()`（删 socket 文件）。
final class ControlServer: @unchecked Sendable {
    /// 控制通道能做的两件"会改变被测进程"的事。求值走 `PageChannel`，关窗复用
    /// `GameLauncher.simulateUserClose` —— **同一实现**，不许在这里另写一份关窗逻辑，
    /// 否则 E12 验的就不是产品路径了。
    struct Handlers {
        var eval: @Sendable (_ expression: String, _ timeout: TimeInterval) async throws -> JSEvalResult
        var close: @Sendable () async -> Void
    }

    /// 一条请求的应答。`afterResponse` 在应答**写出之后**才执行 —— `quit` 依赖这个顺序：
    /// 先把 `{ok:true}` 送回连接，再让主流程收敛，否则对端可能什么都收不到进程就没了。
    private struct Reply {
        var object: [String: Any]
        var afterResponse: (@Sendable () -> Void)? = nil
    }

    private final class Client {
        let fd: Int32
        var buffer: [UInt8] = []
        var source: DispatchSourceRead?
        /// 同一连接上的请求串行处理（前一条的应答写完再处理下一条），
        /// 否则两个 `eval` 并发时应答顺序与请求顺序无关，驱动端无法按行配对。
        var tail: Task<Void, Never>?
        var isClosed = false

        init(fd: Int32) {
            self.fd = fd
        }
    }

    /// `sun_path` 在 Darwin 上是 104 字节（含结尾 NUL）。
    private static let maxPathBytes = 103
    /// 一条应答写不完时的总预算：超时就断开该连接（对端不读 = 通道已废，不能无限挂住）。
    private static let writeTimeout: TimeInterval = 5

    private let socketPath: String
    private let live: ControlLiveState
    private let handlers: Handlers
    private let startedAt = Date()

    /// **所有 socket 状态都只在这个串行队列上摸**（监听 fd、连接表、每个连接的收包缓冲）。
    private let queue = DispatchQueue(label: "com.mochibox.control.socket")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var stopped = false

    init(path: String, live: ControlLiveState, handlers: Handlers) {
        self.socketPath = path
        self.live = live
        self.handlers = handlers
    }

    // MARK: 启动 / 停止

    /// 建监听。失败**必须**能给出一个短原因（调用方照原样打 `reason=<...>`）。
    func start() throws {
        let pathBytes = Array(socketPath.utf8)
        guard !pathBytes.isEmpty else {
            throw MochiBoxError(code: .ioError, message: "empty_path")
        }
        guard pathBytes.count <= Self.maxPathBytes else {
            throw MochiBoxError(code: .ioError, message: "path_too_long")
        }

        // 上次进程被 kill -9 时会留下一个 bind 不进去的残骸。只删**确实是 socket** 的那个
        // 路径：无条件 unlink 会在路径填错时删掉用户的普通文件。
        var info = stat()
        if lstat(socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
            _ = unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MochiBoxError(code: .ioError, message: "socket_failed errno=\(errno)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }
        let nameLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, nameLength)
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw MochiBoxError(code: .ioError, message: "bind_failed errno=\(code)")
        }
        // 只有本用户能连：通道能跑任意 JS，不该让同机其他账号也进来。
        _ = chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            _ = unlink(socketPath)
            throw MochiBoxError(code: .ioError, message: "listen_failed errno=\(code)")
        }
        // 非阻塞：读源回调里要"排空到 EAGAIN"，阻塞 fd 会让监听队列只剩一条时卡死整个队列。
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        queue.sync {
            self.listenFD = fd
            self.listenSource = source
        }
        source.resume()
    }

    /// 幂等。停监听 → 断开所有连接 → 删 socket 文件。
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            listenSource?.cancel()
            listenSource = nil
            listenFD = -1
            for (_, client) in clients {
                client.isClosed = true
                client.source?.cancel()
                client.source = nil
            }
            clients.removeAll()
            _ = unlink(socketPath)
        }
    }

    // MARK: 接受连接

    private func acceptPending() {
        while true {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let fd = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    accept(listenFD, socketAddress, &length)
                }
            }
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            configureClient(fd)
        }
    }

    private func configureClient(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        // **必须**设：对端已关时 write 会触发 SIGPIPE，默认动作是杀进程 ——
        // 一个测试驱动脚本崩掉就能把被测会话一起带走。
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, client] in
            self?.pump(client)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        client.source = source
        clients[fd] = client
        source.resume()
    }

    /// 读到 EAGAIN → 拆行 → 逐行入队。返回时缓冲里只剩半行。
    private func pump(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(client.fd, buffer.baseAddress, 4096)
            }
            if count > 0 {
                client.buffer.append(contentsOf: chunk[0..<count])
                // 半行都不肯结束的对端：别让一个坏客户端把内存吃光。
                if client.buffer.count > 1 << 20 {
                    closeClient(client)
                    return
                }
            } else if count == 0 {
                closeClient(client)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                closeClient(client)
                return
            }
        }

        while let index = client.buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(client.buffer[0..<index])
            client.buffer.removeFirst(index + 1)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            guard !lineBytes.isEmpty else { continue }
            enqueue(client, String(decoding: lineBytes, as: UTF8.self))
        }
    }

    private func enqueue(_ client: Client, _ line: String) {
        let previous = client.tail
        client.tail = Task { [weak self, weak client] in
            // 串行化：等上一条处理完（含应答写回）再处理这一条。
            _ = await previous?.value
            guard let self = self, let client = client, !client.isClosed else { return }
            let reply = await self.reply(for: line)
            self.write(reply.object, to: client)
            reply.afterResponse?()
        }
    }

    private func closeClient(_ client: Client) {
        guard !client.isClosed else { return }
        client.isClosed = true
        clients.removeValue(forKey: client.fd)
        client.source?.cancel()
        client.source = nil
    }

    /// 写**完整一行**（NDJSON 帧）再返回。
    ///
    /// socket 是 `O_NONBLOCK`：旧实现遇到 `EAGAIN` 直接 return，超过内核发送缓冲
    /// （实测 8192 字节）的应答被静默截断、也不补换行，驱动端只能一直等到超时。
    /// 现在写满为止：`EAGAIN` 时用 `poll(POLLOUT)` 等可写，总预算 `writeTimeout`；
    /// 超时或对端关闭就记一行 stderr 并断开该连接 —— 宁可断线，也不发半帧。
    private func write(_ object: [String: Any], to client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            reportWriteFailure("serialize_failed", client: client, bytes: 0)
            return
        }
        var line = data
        line.append(0x0A)
        if let reason = writeLine(line, fd: client.fd,
                                  deadline: Date().addingTimeInterval(Self.writeTimeout)) {
            reportWriteFailure(reason, client: client, bytes: line.count)
        }
    }

    /// 把 `bytes` 全部写进 fd；成功返回 nil，失败返回原因。所有等待共享同一个 deadline。
    private func writeLine(_ bytes: Data, fd: Int32, deadline: Date) -> String? {
        var offset = 0
        while offset < bytes.count {
            let written: Int = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return "write_timeout" }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                // 分片等待：每片最多 1s，回到循环顶端重新检查总预算（避免一次 poll 睡过头）。
                let slice = Int32(max(1.0, min(remaining * 1000.0, 1000.0)))
                let ready = withUnsafeMutablePointer(to: &descriptor) { pointer in
                    poll(pointer, 1, slice)
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return "poll_failed errno=\(errno)"
                }
                if ready == 0 { continue }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    return "peer_closed"
                }
                continue
            }
            return "write_failed errno=\(errno)"
        }
        return nil
    }

    /// 写失败：一行 stderr + 断开连接（fd 的关闭必须在 socket 队列上做）。
    private func reportWriteFailure(_ reason: String, client: Client, bytes: Int) {
        FileHandle.standardError.write(Data(
            "control: write_failed reason=\(reason) bytes=\(bytes) fd=\(client.fd)\n".utf8
        ))
        queue.async { [weak self] in
            self?.closeClient(client)
        }
    }

    // MARK: 请求分发

    private func reply(for line: String) async -> Reply {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let request = parsed as? [String: Any] else {
            return Reply(object: Self.failure(id: NSNull(), code: "bad_request", message: "请求不是 JSON 对象"))
        }
        // id 原样回显：驱动端可能同时开着多条连接，靠它配对。
        let id: Any = request["id"] ?? NSNull()
        guard let op = request["op"] as? String else {
            return Reply(object: Self.failure(id: id, code: "bad_request", message: "缺少 op"))
        }

        switch op {
        case "ping":
            let current = live.current
            return Reply(object: [
                "id": id,
                "ok": true,
                "kernel": current.kernel,
                "pid": Int(getpid()),
                "uptimeSec": Date().timeIntervalSince(startedAt)
            ])

        case "state":
            // **只读**：不探场景、不碰 collector、更不触发一次 drain ——
            // 观测动作不能改变被观测对象的节奏（否则 E2E 测的是探针的副作用）。
            let current = live.current
            var scene: Any = NSNull()
            if let value = current.scene { scene = value }
            return Reply(object: [
                "id": id,
                "ok": true,
                "captured": current.captured,
                "translated": current.translated,
                "skipped": current.skipped,
                "closed": current.closed,
                "scene": scene,
                "kernel": current.kernel
            ])

        case "eval":
            return await evaluate(request, id: id)

        case "close":
            await handlers.close()
            return Reply(object: ["id": id, "ok": true])

        case "quit":
            return Reply(
                object: ["id": id, "ok": true],
                afterResponse: { [live] in live.requestQuit() }
            )

        default:
            return Reply(object: Self.failure(id: id, code: "unknown_op", message: "未知 op：\(op)"))
        }
    }

    private func evaluate(_ request: [String: Any], id: Any) async -> Reply {
        guard let expression = request["expression"] as? String else {
            return Reply(object: Self.failure(id: id, code: "bad_request", message: "eval 缺少 expression"))
        }
        var timeout: TimeInterval = 5
        if let raw = request["timeoutSec"] {
            guard let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else {
                return Reply(object: Self.failure(id: id, code: "bad_request", message: "timeoutSec 必须是正数"))
            }
            timeout = number.doubleValue
        }

        do {
            let result = try await handlers.eval(expression, timeout)
            // 页面抛异常 ≠ 通道故障（PageChannel 的语义约定）：前者 ok=false/js_error，
            // 后者 ok=false/channel_dead。两者混成一个码，驱动端就没法判断"该重试还是该收工"。
            if let exception = result.exceptionText {
                return Reply(object: Self.failure(id: id, code: "js_error", message: exception))
            }
            var object: [String: Any] = ["id": id, "ok": true]
            if let text = Self.textValue(result.value) {
                object["value"] = text
            } else {
                object["value"] = NSNull()
            }
            return Reply(object: object)
        } catch let error as MochiBoxError {
            if error.code == .cdpTimeout {
                return Reply(object: Self.failure(id: id, code: "eval_timeout", message: error.message))
            }
            return Reply(object: Self.failure(id: id, code: "channel_dead", message: error.message))
        } catch {
            return Reply(object: Self.failure(id: id, code: "channel_dead", message: "\(error)"))
        }
    }

    private static func failure(id: Any, code: String, message: String) -> [String: Any] {
        return ["id": id, "ok": false, "error": code, "message": message]
    }

    /// `JSEvalResult.value` → 应答里的 `value`（字符串或 null）。
    ///
    /// 数字按整数写法输出（`1+1` → `"2"` 而不是 `"2.0"`）：驱动端写断言时
    /// `"2.0"` 和 `"2"` 的差别纯属噪音。
    private static func textValue(_ value: JSONValue?) -> String? {
        guard let value = value else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let text):
            return text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            if number.isFinite, number == number.rounded(), abs(number) < 1e15 {
                return String(Int64(number))
            }
            return "\(number)"
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
