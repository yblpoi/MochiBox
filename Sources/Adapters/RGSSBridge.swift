//
//  RGSSBridge.swift
//  MochiBox
//
//  RGSS 文本通道的宿主侧：监听 loopback 随机端口，收 hook 发来的 TEXT，回 RESP。
//
//  协议（UTF-8 文本，TAB 分隔，LF 结尾，payload 是 base64）：
//    → TEXT\t<seq>\t<RGSS1|RGSS2|RGSS3>\t<base64(原文)>
//    ← RESP\t<seq>\t<base64(译文)>
//
//  三条硬约束：
//    1. **端口不写死**：bind 到 127.0.0.1:0，由内核选端口，getSockName 读回实际值；
//       调用方通过 MOCHI_RGSS_PORT 传给 mkxp-z 子进程。固定端口会在多实例/测试并行时打架。
//    2. **150ms 内必须回**：hook 侧读超时是 0.2s。定时器设 120ms（实测 ~135ms 到客户端），
//       没算完就回**空 RESP**，
//       hook 把它当"这次不翻"并放行原文 —— 游戏主线程最多等 0.2s，不会卡住。
//    3. **任何失败都不影响游戏**：连不上 / 协议错 / 解码错 / 客户端断开，一律只写日志。
//
//  翻译来源：当前是**测试词典**（RGSSBridge.testDictionary，抄自
//  Fixtures/mock_openai_server.mjs 的 15 条），只用于证明"读原文 → 回译文 → 渲染"这条通路。
//  它不是生产翻译：词典外的文本原样返回。接 LLM 是下一步，替换 RGSSTranslating 的实现即可。
//

import Foundation
import Darwin

/// 翻译来源的接缝。桥只依赖这一个方法，换 LLM 时不用改 socket / 协议 / 超时。
protocol RGSSTranslating: AnyObject {
    /// 返回 nil = 这个词条不认识，桥会把原文回给 hook（显示不变）。
    func translate(_ text: String, version: String) -> String?
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
        var translationSourceName: String = "test-dictionary"
    }

    /// **测试词典，不是生产翻译来源**。
    ///
    /// 15 条全部来自 Fixtures/mock_openai_server.mjs（E2E 用的合成替身）。它只证明：
    /// hook 能把真游戏里的原文送出来、桥能把中文送回去、Window_Message 能画出译文。
    /// 词典以外的句子会原样返回 —— 报告里必须按这个口径说，不能包装成"已支持翻译"。
    static let testDictionary: [String: String] = [
        "魔物が来た": "魔物来了",
        "こんにちは": "你好",
        "勇者よ、目を覚ませ": "勇者啊，醒醒吧",
        "おはよう": "早上好",
        "ありがとう": "谢谢你",
        "さようなら": "再见",
        "戦闘開始": "战斗开始",
        "回復した": "已恢复",
        "アイテムを手に入れた": "获得了道具",
        "セーブしますか？": "要保存吗？",
        "はい": "是",
        "いいえ": "否",
        "ゲームタイトル": "游戏标题",
        "経験値を獲得": "获得经验值",
        "レベルアップ": "升级了"
    ]

    private let config: Configuration
    private let translator: RGSSTranslating

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
        translator: RGSSTranslating? = nil
    ) {
        self.config = configuration
        self.translator = translator ?? RGSSDictionaryTranslator(entries: RGSSBridge.testDictionary)
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

        // 120ms 到点还没算完：回空 RESP。hook 会把它当"这次不翻"并放行原文。
        requestQueue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self = self, gate.claim() else { return }
            self.log("TIMEOUT seq=\(seq) -> 空 RESP")
            self.write(seq: seq, text: nil, connection: connection)
        }

        requestQueue.async { [weak self] in
            guard let self = self else { return }
            let translated = self.translator.translate(text, version: version)
            guard gate.claim() else { return }

            if let translated = translated, !translated.isEmpty {
                self.log("RESP seq=\(seq) text=\(translated.debugDescription)")
                self.write(seq: seq, text: translated, connection: connection)
            } else {
                // 词典不认识 ≠ 失败：回原文，hook 显示不变，也不会触发它的 2s 冷却。
                self.log("MISS seq=\(seq) -> 原文")
                self.write(seq: seq, text: text, connection: connection)
            }
        }
    }

    private func write(seq: String, text: String?, connection: ClientConnection) {
        let payload = (text ?? "").data(using: .utf8)?.base64EncodedString() ?? ""
        let line = "RESP\t\(seq)\t\(payload)\n"
        connection.send(Data(line.utf8))
    }

    // MARK: - 解码

    /// RGSS3 是 UTF-8；RGSS1/2 的工程文本多为 CP932（日文）或 GB18030（汉化）。
    /// base64 里是 Ruby 字符串的原始字节，先按 UTF-8 试，失败再按 Shift_JIS（CP932 超集）。
    /// GB18030 这里解不了：那类工程会走 MISS 显示原文，不会乱码或崩溃。
    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .shiftJIS) {
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

// MARK: - 词典实现

final class RGSSDictionaryTranslator: RGSSTranslating {
    private let entries: [String: String]

    init(entries: [String: String]) {
        self.entries = entries
    }

    func translate(_ text: String, version: String) -> String? {
        // XP 的 message_text 末尾带换行（整段文本），VX/VX Ace 是逐行数组。
        // 只剥尾部换行，不动首尾空格 —— 缩进是有意义的排版。
        var key = text
        while key.hasSuffix("\n") || key.hasSuffix("\r") {
            key.removeLast()
        }
        return entries[key]
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

/// 一次请求只允许一个应答：翻译先完成就回译文，超时先到就回空 RESP，后到的那个 claim 失败。
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
