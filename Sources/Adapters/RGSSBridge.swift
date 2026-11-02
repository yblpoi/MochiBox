//
//  RGSSBridge.swift
//  MochiBox
//
//  RGSS 文本通道的宿主侧：监听 loopback 随机端口，收 hook 发来的 TEXT，回 RESP。
//
//  协议（UTF-8 文本，TAB 分隔，LF 结尾，payload 是 base64）：
//    → TEXT\t<seq>\t<RGSS1|RGSS2|RGSS3>\t<base64(原文)>
//    ← RESP\t<seq>\t<base64(译文)>                      正常译文
//    ← RESP\t<seq>\t<base64(原文的 UTF-8 版本)>\tPENDING  还没译好，先显示原文
//
//  三条硬约束：
//    1. **端口不写死**：bind 到 127.0.0.1:0，由内核选端口，getSockName 读回实际值；
//       调用方通过 MOCHI_RGSS_PORT 传给 mkxp-z 子进程。固定端口会在多实例/测试并行时打架。
//    2. **150ms 内必须回**：hook 侧读超时是 0.2s。定时器设 120ms（实测 ~135ms 到客户端），
//       没算完就回 **PENDING + 原文（UTF-8）**，
//       hook 显示原文但不缓存 —— 游戏主线程最多等 0.2s，不会卡住。
//    3. **任何失败都不影响游戏**：连不上 / 协议错 / 解码错 / 客户端断开，一律只写日志。
//
//  翻译来源：**现有翻译管线**（RGSSPipelineTranslator → TranslationPipeline →
//  TranslationCache / TranslatorProvider）。桥本身只认 RGSSTranslating 这个接缝。
//
//  **异步语义（刻意）**：缓存命中 → 120ms 内回中文；未命中 → 120ms 到点回
//  **PENDING + 原文的 UTF-8 重编码**，后台继续请求并写缓存。第一遍显示原文、
//  同一原文下一次出现（重绘 / 重新触发对话 / 重启后）才显示中文。不要为了
//  "首屏就有中文"把这里改成同步等待 —— 那会把游戏主线程钉在网络请求上
//  （hook 的读超时只有 0.2s，超时也只是放行原文）。
//
//  **PENDING 必须带原文**：不能回空（CP932 游戏原串会让这版 mkxp-z 的
//  Window_Message 抛 "invalid byte sequence"），也不能回普通 RESP 带原文
//  （hook 会把任何非 PENDING 的 RESP 当译文缓存，原文就被钉死一整局）。
//

import Foundation
import Darwin

/// 翻译来源的接缝。桥只依赖这一个方法，换实现时不用改 socket / 协议 / 超时。
protocol RGSSTranslating: AnyObject, Sendable {
    /// 返回 nil = 这次没有可用译文（未命中且后台未完成 / 跳过 / 失败），桥回 PENDING + 原文。
    /// 这个方法必须是异步的：桥要在 120ms 内先回，后台结果写进缓存供下次命中。
    func translate(_ text: String, version: String) async -> RGSSBridgeReply?
}

/// 一次可回给 hook 的译文，以及它来自缓存还是后台刚拿到的。
///
/// `source` 只用于日志：验证"第二遍才中文"靠的就是 hit / fresh 的计数。
struct RGSSBridgeReply: Sendable {
    enum Source: String, Sendable {
        case cacheHit = "hit"
        case fresh = "fresh"
    }

    var text: String
    var source: Source
}

/// 打开失败时给调用方看的错误（不参与控制流，调用方只需决定"这次不注入 hook"）。
enum RGSSBridgeError: LocalizedError {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case address(String)

    var errorDescription: String? {
        switch self {
        case .socket(let code): return "socket() 失败：errno=\(code)"
        case .bind(let code): return "bind(127.0.0.1:0) 失败：errno=\(code)"
        case .listen(let code): return "listen() 失败：errno=\(code)"
        case .address(let host): return "无法解析监听地址：\(host)"
        }
    }
}

final class RGSSBridge: @unchecked Sendable {

    struct Configuration {
        /// 只监听回环。协议没有认证，绝不能 bind 到 0.0.0.0。
        var host: String = "127.0.0.1"
        /// 必须小于 hook 的 0.2s 读超时。150ms 的定时器实测客户端要 164ms 才收到
        ///（Dispatch 唤醒 + 回包），余量只剩 36ms；压到 120ms，实测 ~135ms，留 65ms。
        var responseDeadlineMs: Int = 120
        /// 与 hook 的默认日志同一个口径（/tmp），便于两边的行对着看。
        var logURL: URL = URL(fileURLWithPath: "/tmp/mochi-rgss-bridge.log")
        /// 只进日志：pipeline（真的有翻译来源） / none（本次只放行原文）。
        var translationSourceName: String = "none"
    }

    private let config: Configuration
    /// nil = 没有翻译来源：所有 TEXT 都回 PENDING + 原文（游戏照常跑，显示原文）。
    private let translator: (any RGSSTranslating)?

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var boundPort: Int = 0
    private var running = false
    private var clients: [Int32: ClientConnection] = [:]

    private let acceptQueue = DispatchQueue(label: "mochibox.rgss.bridge.accept")
    /// 并发：多行消息 / 多个客户端同时到达时互不排队（单行翻译很快，但接 LLM 后必须并发）。
    private let requestQueue = DispatchQueue(
        label: "mochibox.rgss.bridge.requests",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let logLock = NSLock()

    init(
        configuration: Configuration = Configuration(),
        translator: (any RGSSTranslating)? = nil
    ) {
        self.config = configuration
        self.translator = translator
        try? FileManager.default.createDirectory(
            at: configuration.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// 已经绑定的端口（未 start 时为 0）。
    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    // MARK: - 生命周期

    /// 同步完成 socket / bind / listen，然后交给后台线程 accept。返回实际端口。
    func start() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return boundPort }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RGSSBridgeError.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, config.host, &address.sin_addr) == 1 else {
            close(fd)
            throw RGSSBridgeError.address(config.host)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw RGSSBridgeError.bind(code)
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            close(fd)
            throw RGSSBridgeError.bind(code)
        }

        guard Darwin.listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw RGSSBridgeError.listen(code)
        }

        listenerFD = fd
        boundPort = Int(UInt16(bigEndian: bound.sin_port))
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd)
        }
        log("LISTEN \(config.host):\(boundPort) source=\(config.translationSourceName) deadline=\(config.responseDeadlineMs)ms")
        return boundPort
    }

    /// 关监听、断所有在飞连接。可重复调用。
    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let fd = listenerFD
        listenerFD = -1
        let active = Array(clients.values)
        clients.removeAll()
        let stoppedPort = boundPort
        boundPort = 0
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        // 只 shutdown 不 close：fd 的所有权在各自的 handler，close 由它们自己做，
        // 避免"这里 close 了、fd 号立刻被别的 socket 复用、handler 又 close 一次"。
        for client in active {
            client.shutdown()
        }
        log("STOP port=\(stoppedPort)")
    }

    deinit {
        stop()
    }

    // MARK: - 监听 / 连接

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(fd, sockaddrPointer, &length)
                }
            }

            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            var yes: Int32 = 1
            setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            // 客户端先断（游戏退出 / hook 超时关 socket）时，send 返回 EPIPE 会变成 SIGPIPE
            // 直接把宿主进程杀掉。macOS 用 SO_NOSIGPIPE 关掉这条信号。
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            let connection = ClientConnection(fd: clientFD)
            lock.lock()
            if running {
                clients[clientFD] = connection
            }
            let stillRunning = running
            lock.unlock()

            guard stillRunning else {
                connection.close()
                break
            }

            log("ACCEPT \(peerDescription(peer))")
            requestQueue.async { [weak self] in
                self?.handle(connection)
            }
        }
    }

    private func handle(_ connection: ClientConnection) {
        defer {
            connection.close()
            lock.lock()
            clients.removeValue(forKey: connection.fd)
            lock.unlock()
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while isRunning {
            let received = recv(connection.fd, &chunk, chunk.count, 0)
            if received > 0 {
                buffer.append(chunk, count: received)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        process(line: line, connection: connection)
                    } else {
                        log("BADLINE 不是 UTF-8，已丢弃 \(lineData.count)B")
                    }
                }
            } else if received == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func process(line: String, connection: ClientConnection) {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let parts = trimmed.split(
            separator: "\t",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard parts.count == 4, parts[0] == "TEXT" else {
            log("BADLINE \(trimmed.prefix(120).debugDescription)")
            return
        }

        let seq = String(parts[1])
        let version = String(parts[2])
        let payload = String(parts[3])

        // seq 是 hook 的请求序号（Ruby 侧 @seq += 1，恒为十进制整数）。非数字的 seq
        // 无法与 hook 的回包匹配，属于协议错误 —— 丢掉这一行，不回复、不影响连接。
        guard !seq.isEmpty, seq.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            log("BADSEQ \(seq.debugDescription)")
            return
        }

        guard let raw = Data(base64Encoded: payload), !raw.isEmpty else {
            log("BADPAYLOAD seq=\(seq)")
            return
        }
        guard let text = Self.decode(raw), !text.isEmpty else {
            log("BADTEXT seq=\(seq) ver=\(version)")
            return
        }

        log("TEXT seq=\(seq) ver=\(version) text=\(text.debugDescription)")
        respond(seq: seq, text: text, version: version, connection: connection)
    }

    // MARK: - 翻译 + 超时

    private func respond(
        seq: String,
        text: String,
        version: String,
        connection: ClientConnection
    ) {
        let gate = RequestGate()
        let deadline = DispatchTime.now() + .milliseconds(config.responseDeadlineMs)

        // 120ms 到点还没算完：回 PENDING（载荷是**原文的 UTF-8 重编码**）。
        // 为什么不是空 RESP：RGSS1 的工程文本多为 CP932，当前 mkxp-z 构建会把游戏里的
        // CP932 字符串按 UTF-8 处理，直接绘制会抛 "invalid byte sequence in UTF-8"。
        // 把原文按 UTF-8 送回去让 hook 替换，既避免崩溃，又能让 hook 知道"这不是译文"、
        // 不要写进它自己的进程内缓存（否则原文会被钉死一整局）。
        //
        // 翻译任务**不取消**：结果会写进 TranslationCache，同一原文下次直接命中。
        requestQueue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self = self, gate.claim() else { return }
            self.log("TIMEOUT seq=\(seq) -> PENDING（后台请求中）")
            self.write(seq: seq, text: text, pending: true, connection: connection)
        }

        guard let translator = translator else {
            // 没有翻译来源（例如从源码直接跑 build/MochiBox、没有设置环境）：
            // 立刻回 PENDING，不留 120ms 的空等。
            if gate.claim() {
                log("NOSOURCE seq=\(seq) -> PENDING")
                write(seq: seq, text: text, pending: true, connection: connection)
            }
            return
        }

        Task { [weak self] in
            let reply = await translator.translate(text, version: version)
            guard let self = self else { return }

            let claimed = gate.claim()
            if let reply = reply, !reply.text.isEmpty {
                if claimed {
                    self.log("RESP seq=\(seq) source=\(reply.source.rawValue) text=\(reply.text.debugDescription)")
                    self.write(seq: seq, text: reply.text, pending: false, connection: connection)
                } else {
                    // 已经回过 PENDING：这次结果不再发给 hook，但缓存里已经有了。
                    self.log("LATE seq=\(seq) source=\(reply.source.rawValue) -> 已可命中")
                }
            } else if claimed {
                // 未命中 / 跳过 / 失败：回 PENDING + 原文（UTF-8）。
                // hook 会显示它但不缓存；下一次同一原文再问时，缓存里通常已经有译文。
                self.log("MISS seq=\(seq) -> PENDING")
                self.write(seq: seq, text: text, pending: true, connection: connection)
            } else {
                self.log("MISS seq=\(seq) -> 后台失败（原响应已超时）")
            }
        }
    }

    /// 4 字段协议：`RESP\t<seq>\t<base64>\tPENDING`。第 4 段省略 = 正常译文。
    ///
    /// 为什么 PENDING 也要带载荷：见 `respond` 里的编码说明 —— 空载荷会让 hook 放行
    /// 游戏原串（CP932），而这版 mkxp-z 在 Window_Message 里按 UTF-8 处理它会崩。
    private func write(seq: String, text: String, pending: Bool, connection: ClientConnection) {
        let payload = text.data(using: .utf8)?.base64EncodedString() ?? ""
        let suffix = pending ? "\tPENDING" : ""
        let line = "RESP\t\(seq)\t\(payload)\(suffix)\n"
        connection.send(Data(line.utf8))
    }

    // MARK: - 解码

    /// RGSS3 是 UTF-8；RGSS1/2 的工程文本多为 CP932（日文）或 GB18030（汉化）。
    /// base64 里是 Ruby 字符串的原始字节，按 UTF-8 → Shift_JIS（CP932 超集）→ GB18030 逐档试。
    ///
    /// 顺序有讲究：UTF-8 必须排第一（RGSS3 的 :E 字符串就是 UTF-8，且 CP932 字节流几乎
    /// 不可能同时是合法 UTF-8）；GB18030 放最后，因为它几乎能解任何字节，放在前面会把
    /// CP932 解成乱码。GB18030 用 CoreFoundation 的 GB_18030_2000（Foundation 没有直接常量）。
    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .shiftJIS) {
            return text
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        return nil
    }

    // MARK: - 日志

    private func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)\n"
        logLock.lock()
        defer { logLock.unlock() }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: config.logURL.path),
           let size = attributes[.size] as? Int,
           size > 1024 * 1024 {
            try? Data().write(to: config.logURL)
        }
        let fd = Darwin.open(config.logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        line.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
        close(fd)
    }

    private static func timestamp() -> String {
        var now = time(nil)
        var brokenDown = tm()
        localtime_r(&now, &brokenDown)
        var buffer = [CChar](repeating: 0, count: 32)
        strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &brokenDown)
        return String(cString: buffer)
    }

    private func peerDescription(_ peer: sockaddr_storage) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        var mutablePeer = peer
        let length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &mutablePeer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getnameinfo(
                    sockaddrPointer,
                    length,
                    &host,
                    socklen_t(host.count),
                    &port,
                    socklen_t(port.count),
                    NI_NUMERICHOST | NI_NUMERICSERV
                )
            }
        }
        guard result == 0 else { return "client" }
        return "\(String(cString: host)):\(String(cString: port))"
    }
}

// MARK: - 连接 / 单次应答闸

/// 一个客户端的写端。close 与 send 共用一把锁，避免 fd 号被复用时写到别的 socket。
private final class ClientConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !data.isEmpty else { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// 一次请求只允许一个应答：翻译先完成就回译文，超时先到就回 PENDING，后到的那个 claim 失败。
private final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
