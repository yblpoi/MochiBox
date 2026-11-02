//
//  rgss_bridge_probe.swift —— RGSS 文本桥的协议 / 分段 / 超时 / 缓存 / 降级探针
//
//  不属于产品源码：只编译被测文件 + 本文件，产物由 20_rgss_bridge.mjs 丢进 mkdtemp。
//
//  覆盖（编号与 20_rgss_bridge.mjs 的注释一一对应）：
//    RB-A 协议层：base64 往返（中文 / \n）、TEXT 字段容错、RESP 逐字节格式
//    RB-B 控制符分段：LegacyEscapeCodec.skeleton + Segmenter 直接测（不经过网络）
//    RB-C 超时：永不返回的 translator → ~120ms 回 PENDING + 原文；stop 后端口关闭
//    RB-D 缓存：真实 TranslationPipeline + TranslationCache；miss→落盘→hit；key 不含控制码
//    RB-E 降级：bind 失败只返回类型化错误；客户端发一半就 close 不崩
//
//  为什么协议层走真 socket 而不是调 private 方法：TEXT/RESP 的字节形态（TAB、base64、
//  PENDING 后缀、LF）本身就是 hook 的契约，只有对着环回端口读写才算测到。
//

import Foundation
import Darwin

// MARK: - TAP

final class Reporter {
    private var total = 0
    private var pass = 0
    private var fail = 0

    func check(_ id: String, _ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok { pass += 1 } else { fail += 1 }
        let label = name.replacingOccurrences(of: "\n", with: " ")
        if ok {
            print("ok \(total) - \(id) \(label)")
        } else {
            print("not ok \(total) - \(id) \(label) # 断言不成立")
            for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
                print("#   \(line)")
            }
        }
    }

    func eq(_ id: String, _ name: String, _ actual: String, _ expected: String) {
        check(id, name, actual == expected, "期望: \(expected)\n实际: \(actual)")
    }

    func finish() -> Int32 {
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        return fail == 0 ? 0 : 1
    }
}

// MARK: - 线程安全小工具

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class SettingsBox: @unchecked Sendable {
    var value: Settings
    init(_ value: Settings) { self.value = value }
}

// MARK: - 测试替身

/// 立即返回译文（source=fresh）。用来量 RESP 的字节形态。
final class ImmediateTranslator: RGSSTranslating, @unchecked Sendable {
    func translate(_ text: String, version: String) async -> RGSSBridgeReply? {
        return RGSSBridgeReply(text: "译:" + text, source: .fresh)
    }
}

/// 永不返回。用来验证 120ms 应答闸：桥必须先回 PENDING，后台 Task 不阻塞调用方。
final class NeverTranslator: RGSSTranslating, @unchecked Sendable {
    func translate(_ text: String, version: String) async -> RGSSBridgeReply? {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
    }
}

/// 计数 + 可替换文本变换的 provider。只实现管线真正调用的 translate(batch:)。
final class CountingProvider: TranslatorProvider, @unchecked Sendable {
    var kind: BackendKind { .openai }
    private let counter = Counter()
    private let transform: @Sendable (String) -> String

    init(transform: @escaping @Sendable (String) -> String) {
        self.transform = transform
    }

    var callCount: Int { counter.current() }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        _ = counter.increment()
        return batch.map { request in
            TranslationResult(
                requestId: request.requestId,
                items: request.items.map { item in
                    TranslationResultItem(
                        key: item.key,
                        translatedText: transform(item.text),
                        translatedSegments: nil,
                        cached: false,
                        latencyMs: 0
                    )
                },
                backend: .openai,
                error: nil
            )
        }
    }
}

// MARK: - 环回客户端

final class LineClient {
    let fd: Int32

    init(port: Int, connectTimeoutMs: Int = 1000) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MochiBoxError(code: .network, message: "socket 失败") }
        var timeout = timeval(
            tv_sec: connectTimeoutMs / 1000,
            tv_usec: Int32((connectTimeoutMs % 1000) * 1000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw MochiBoxError(code: .network, message: "connect 失败 errno=\(code)")
        }
        self.fd = fd
    }

    @discardableResult
    func send(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// 读到 LF 为止；超时 / 对端关闭返回 nil（测试用它断言"没有回包"）。
    func readLine(timeoutMs: Int = 2000) -> String? {
        var timeout = timeval(
            tv_sec: timeoutMs / 1000,
            tv_usec: Int32((timeoutMs % 1000) * 1000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let received = recv(fd, &chunk, chunk.count, 0)
            if received > 0 {
                buffer.append(chunk, count: received)
                if let newline = buffer.firstIndex(of: 0x0A) {
                    return String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                }
            } else if received == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    func close() {
        Darwin.close(fd)
    }
}

// MARK: - 桥工装

func makeLogURL(_ tag: String) -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mochibox-rgss-probe-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(tag).log")
}

func base64(_ text: String) -> String {
    return Data(text.utf8).base64EncodedString()
}

func decodeBase64(_ payload: String) -> String? {
    guard let data = Data(base64Encoded: payload) else { return nil }
    return String(data: data, encoding: .utf8)
}

func parseResponse(_ line: String) -> (seq: String, payload: String, pending: Bool)? {
    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard parts.count == 3 || parts.count == 4, parts[0] == "RESP" else { return nil }
    let pending = parts.count == 4 && parts[3] == "PENDING"
    if parts.count == 4 && parts[3] != "PENDING" { return nil }
    return (String(parts[1]), String(parts[2]), pending)
}

func textLine(seq: String, version: String, text: String) -> String {
    return "TEXT\t\(seq)\t\(version)\t\(base64(text))"
}

func startBridge(
    translator: (any RGSSTranslating)?,
    deadlineMs: Int = 120,
    host: String = "127.0.0.1",
    tag: String
) throws -> (bridge: RGSSBridge, port: Int) {
    var configuration = RGSSBridge.Configuration()
    configuration.responseDeadlineMs = deadlineMs
    configuration.host = host
    configuration.logURL = makeLogURL(tag)
    let bridge = RGSSBridge(configuration: configuration, translator: translator)
    let port = try bridge.start()
    return (bridge, port)
}

// MARK: - RB-A 协议层

func protocolSuite(_ report: Reporter) {
    guard let (bridge, port) = try? startBridge(translator: ImmediateTranslator(), tag: "protocol") else {
        report.check("RB-A0", "协议层桥启动", false, "start() 抛错")
        return
    }
    defer { bridge.stop() }

    // A1 base64 往返：中文 + 换行都必须逐字符回来（payload 里是 UTF-8 字节）。
    if let client = try? LineClient(port: port) {
        let original = "赤い\n二行目"
        client.send(textLine(seq: "1", version: "RGSS2", text: original))
        let line = client.readLine()
        let parsed = line.flatMap(parseResponse)
        report.check("RB-A1", "TEXT/RESP 的 base64 往返保留中文与 \\n",
                     parsed != nil && decodeBase64(parsed!.payload) == "译:赤い\n二行目",
                     "原始行: \(line ?? "nil")")
        report.check("RB-A1b", "正常 RESP 不带 PENDING 后缀", parsed?.pending == false,
                     "解析: \(String(describing: parsed))")
        client.close()
    } else {
        report.check("RB-A1", "协议层客户端连接", false, "connect 失败")
    }

    // A2 RESP 逐字节格式：RESP\t<seq>\t<base64>\n。
    if let client = try? LineClient(port: port) {
        client.send(textLine(seq: "42", version: "RGSS3", text: "赤い"))
        let line = client.readLine()
        let expected = "RESP\t42\t\(base64("译:赤い"))"
        report.eq("RB-A2", "RESP 逐字节符合 RESP\\t<seq>\\t<base64>", line ?? "nil", expected)
        client.close()
    } else {
        report.check("RB-A2", "协议层客户端连接", false, "connect 失败")
    }

    // A3 容错：少字段 / seq 非数字 / base64 非法 / 非 TEXT 行都必须拒绝且不崩。
    // 拒绝的判据是"同一连接上没有任何回包"；随后再发合法行必须照常回 —— 证明 handler 没死。
    if let client = try? LineClient(port: port) {
        var rejected = true
        let malformed: [(String, String)] = [
            ("RB-A3a", "TEXT\t7\tRGSS2"),
            ("RB-A3b", "TEXT\tabc\tRGSS2\t\(base64("赤い"))"),
            ("RB-A3c", "TEXT\t8\tRGSS2\t!!!!"),
            ("RB-A3d", "HELLO\t9\tRGSS2\t\(base64("赤い"))")
        ]
        for (id, line) in malformed {
            client.send(line)
            let response = client.readLine(timeoutMs: 250)
            report.check(id, "拒绝畸形行 \(line.prefix(24))", response == nil, "收到了: \(response ?? "nil")")
            if response != nil { rejected = false }
        }
        client.send(textLine(seq: "9", version: "RGSS2", text: "まだ生きている"))
        let line = client.readLine()
        let parsed = line.flatMap(parseResponse)
        report.check("RB-A3e", "畸形行之后同一连接仍能正常应答",
                     rejected && parsed?.seq == "9" && decodeBase64(parsed?.payload ?? "") == "译:まだ生きている",
                     "原始行: \(line ?? "nil")")
        client.close()
    } else {
        report.check("RB-A3", "协议层客户端连接", false, "connect 失败")
    }
}

// MARK: - RB-B 控制符分段

func segmentationSuite(_ report: Reporter) {
    let colored = "\\C[2]赤い\\C[0]"
    let skeleton = LegacyEscapeCodec.skeleton(raw: colored, engineFamily: "rgss")
    let texts = skeleton.filter { $0.kind == .text }.map { $0.value }
    let codes = skeleton.filter { $0.kind == .code }.map { $0.value }

    report.check("RB-B1", "\\C[2]赤い\\C[0] 只把「赤い」送翻译",
                 texts == ["赤い"] && Segmenter.joinForBackend(skeleton) == "赤い",
                 "texts=\(texts) join=\(Segmenter.joinForBackend(skeleton))")
    report.check("RB-B1b", "骨架里的控制码是原文的两条", codes == ["\\C[2]", "\\C[0]"],
                 "codes=\(codes)")

    if let output = try? Segmenter.reassemble(segments: skeleton, translatedText: "译文") {
        let outputCodes = LegacyEscapeCodec.tokenize(output, family: .rgss)
            .filter { !$0.kind.isText }.map { $0.value }
        report.check("RB-B2", "拼回后控制码序列与原文逐项相同",
                     outputCodes == codes && output == "\\C[2]译文\\C[0]",
                     "output=\(output) codes=\(outputCodes)")
        let problems = LegacyEscapeCodec.controlCodeProblems(
            raw: colored, reassembled: output, engineFamily: "rgss"
        )
        report.check("RB-B2b", "正常拼回不产生 controlCodeProblems", problems.isEmpty,
                     "problems=\(problems)")
    } else {
        report.check("RB-B2", "Segmenter.reassemble 正常返回", false, "reassemble 抛错")
    }

    let nameRaw = "\\N[1]こんにちは"
    let nameSkeleton = LegacyEscapeCodec.skeleton(raw: nameRaw, engineFamily: "rgss")
    let nameTexts = nameSkeleton.filter { $0.kind == .text }.map { $0.value }
    let nameCodes = nameSkeleton.filter { $0.kind == .code }.map { $0.value }
    let nameOutput = try? Segmenter.reassemble(segments: nameSkeleton, translatedText: "你好")
    report.check("RB-B3", "\\N[1]こんにちは 只送「こんにちは」",
                 nameTexts == ["こんにちは"] && nameCodes == ["\\N[1]"],
                 "texts=\(nameTexts) codes=\(nameCodes) output=\(nameOutput ?? "nil")")
    report.check("RB-B3b", "替换符拼回为 \\N[1]你好", nameOutput == "\\N[1]你好",
                 "output=\(nameOutput ?? "nil")")

    // 模型把控制码写进译文：必须被 translatedTextProblems 判 corrupt。
    let corrupt = LegacyEscapeCodec.translatedTextProblems("\\C[9]訳", engineFamily: "rgss")
    report.check("RB-B4", "译文混入 \\C[9] 被判 corrupt", !corrupt.isEmpty,
                 "problems=\(corrupt)")
    let clean = LegacyEscapeCodec.translatedTextProblems("訳", engineFamily: "rgss")
    report.check("RB-B4b", "干净译文不被误判 corrupt", clean.isEmpty, "problems=\(clean)")

    // 缓存键只认 text 段：两个不同颜色共用同一条缓存。
    let skeleton2 = LegacyEscapeCodec.skeleton(raw: "\\C[3]赤い\\C[0]", engineFamily: "rgss")
    let profile = TranslationProfile.id(category: .dialogue, pairs: [])
    let key1 = Segmenter.cacheKey(engineFamily: "rgss", srcLang: "ja", tgtLang: "zh-Hans",
                                  segments: skeleton, profile: profile)
    let key2 = Segmenter.cacheKey(engineFamily: "rgss", srcLang: "ja", tgtLang: "zh-Hans",
                                  segments: skeleton2, profile: profile)
    let material = Segmenter.keyMaterial(engineFamily: "rgss", srcLang: "ja", tgtLang: "zh-Hans",
                                         segments: skeleton, profile: profile)
    report.check("RB-B5", "\\C[2] 与 \\C[3] 的 cache key 相同", key1 == key2,
                 "key1=\(key1) key2=\(key2)")
    report.eq("RB-B5b", "keyMaterial 只含译文段（不含控制码）",
              material, "rgss|ja|zh-Hans|p2|c:dialogue|g:0|赤い")
    report.check("RB-B5c", "mapKey 等于「赤い」", Segmenter.mapKey(skeleton) == "赤い",
                 "mapKey=\(Segmenter.mapKey(skeleton))")
    // 文档 §8.1 的向量：sha256("rgss|ja|zh-Hans|p2|c:dialogue|g:0|赤い") = cdca5359…
    // 改 prompt 版本 / key 公式时这条会红 —— 那正是需要同步文档与缓存迁移的时刻。
    report.check("RB-B5d", "缓存键与文档向量 cdca5359… 一致", key1.hasPrefix("cdca5359"),
                 "key=\(key1)")
}

// MARK: - RB-C 超时与 PENDING

func timeoutSuite(_ report: Reporter) async {
    guard let (bridge, port) = try? startBridge(translator: NeverTranslator(), deadlineMs: 120, tag: "timeout") else {
        report.check("RB-C0", "超时桥启动", false, "start() 抛错")
        return
    }

    guard let client = try? LineClient(port: port) else {
        report.check("RB-C1", "超时桥客户端连接", false, "connect 失败")
        bridge.stop()
        return
    }

    let raw = "\\C[2]赤い\\C[0]"
    let started = Date()
    client.send(textLine(seq: "1", version: "RGSS2", text: raw))
    let line = client.readLine(timeoutMs: 2000)
    let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
    let parsed = line.flatMap(parseResponse)

    report.check("RB-C1", "120ms 到点回 PENDING + 原文",
                 parsed != nil && parsed!.pending && decodeBase64(parsed!.payload) == raw,
                 "原始行: \(line ?? "nil")")
    report.eq("RB-C1b", "PENDING 逐字节符合 RESP\\t<seq>\\t<base64>\\tPENDING",
              line ?? "nil", "RESP\t1\t\(base64(raw))\tPENDING")
    report.check("RB-C1c", "PENDING 在 100–600ms 内到达", elapsedMs >= 100 && elapsedMs <= 600,
                 "elapsed=\(elapsedMs)ms")
    client.close()

    // stop 之后监听端口必须拒绝连接（生命周期收敛；端口可重新绑定）。
    bridge.stop()
    var refused = false
    do {
        let probe = try LineClient(port: port)
        probe.close()
    } catch {
        refused = true
    }
    report.check("RB-C2", "stop() 后原端口拒绝连接", refused, "port=\(port) 仍可 connect")

    guard let (bridge2, port2) = try? startBridge(translator: ImmediateTranslator(), deadlineMs: 120, tag: "timeout-restart") else {
        report.check("RB-C3", "stop() 后可以启动新桥", false, "第二次 start() 抛错")
        return
    }
    defer { bridge2.stop() }
    if let client2 = try? LineClient(port: port2) {
        client2.send(textLine(seq: "1", version: "RGSS2", text: "赤い"))
        let line2 = client2.readLine()
        report.check("RB-C3", "stop() 后新桥仍能服务请求",
                     line2.flatMap(parseResponse) != nil, "原始行: \(line2 ?? "nil")")
        client2.close()
    } else {
        report.check("RB-C3", "stop() 后新桥仍能服务请求", false, "connect 失败")
    }
}

// MARK: - RB-D 缓存

func cacheSuite(_ report: Reporter) async {
    let cacheURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mochibox-rgss-probe-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("cache.ja-zh-Hans.jsonl")
    let cache = TranslationCache(url: cacheURL, maxEntries: 256)
    await cache.load()

    var settings = Settings()
    settings.backendType = .openai
    settings.allowSendTextToBackend = true
    settings.batchWindowMs = 0
    settings.timeoutSec = 5
    let settingsBox = SettingsBox(settings)
    let provider = CountingProvider { text in "译:" + text }
    let pipeline = TranslationPipeline(
        cache: cache,
        provider: { provider },
        settings: { settingsBox.value }
    )
    let environment = RGSSPipelineEnvironment(
        pipeline: pipeline,
        cache: cache,
        glossaryBox: nil,
        srcLang: "ja",
        tgtLang: "zh-Hans",
        timeoutSec: 5,
        log: nil
    )
    let translator = RGSSPipelineTranslator(environment: environment)

    let first = await translator.translate("\\C[2]赤い\\C[0]", version: "RGSS2")
    report.check("RB-D1", "首次未命中：返回 fresh 译文并拼回控制码",
                 first?.text == "\\C[2]译:赤い\\C[0]" && first?.source == .fresh,
                 "reply=\(String(describing: first))")
    report.check("RB-D1b", "首次只打一次后端", provider.callCount == 1,
                 "calls=\(provider.callCount)")

    let key = Segmenter.cacheKey(
        engineFamily: "rgss", srcLang: "ja", tgtLang: "zh-Hans",
        segments: LegacyEscapeCodec.skeleton(raw: "\\C[2]赤い\\C[0]", engineFamily: "rgss"),
        profile: TranslationProfile.id(category: .dialogue, pairs: [])
    )
    let stored = await cache.get(key)
    report.check("RB-D2", "首次译文已写入缓存（miss → put）",
                 stored?.translatedText == "译:赤い", "entry=\(String(describing: stored))")

    // 换一个控制码，key 必须仍命中同一条；回填用本行自己的骨架。
    let second = await translator.translate("\\C[3]赤い\\C[0]", version: "RGSS2")
    report.check("RB-D3", "同一文本第二次命中：返回 hit 且用本行控制码",
                 second?.text == "\\C[3]译:赤い\\C[0]" && second?.source == .cacheHit,
                 "reply=\(String(describing: second))")
    report.check("RB-D3b", "命中不再打后端", provider.callCount == 1,
                 "calls=\(provider.callCount)")
    let hitEntry = await cache.get(key)
    report.check("RB-D4", "命中的 hitCount 递增到 1", hitEntry?.hitCount == 1,
                 "hitCount=\(hitEntry?.hitCount ?? -1)")

    await cache.flush()
    let exists = FileManager.default.fileExists(atPath: cacheURL.path)
    let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int) ?? 0
    report.check("RB-D5", "缓存落盘文件存在且非空", exists && size > 0,
                 "path=\(cacheURL.path) size=\(size)")

    let reloaded = TranslationCache(url: cacheURL, maxEntries: 256)
    await reloaded.load()
    let loadedEntry = await reloaded.get(key)
    report.check("RB-D6", "load() 能读回落盘的译文",
                 loadedEntry?.translatedText == "译:赤い",
                 "entry=\(String(describing: loadedEntry))")
}

// MARK: - RB-B6 模型写回控制码：整条丢弃

func corruptSuite(_ report: Reporter) async {
    let cacheURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mochibox-rgss-probe-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("cache.ja-zh-Hans.jsonl")
    let cache = TranslationCache(url: cacheURL, maxEntries: 32)
    await cache.load()

    var settings = Settings()
    settings.backendType = .openai
    settings.allowSendTextToBackend = true
    settings.batchWindowMs = 0
    settings.timeoutSec = 5
    let settingsBox = SettingsBox(settings)
    // 模型在译文里自带 \C[9]：translatedTextProblems 必须拦下，桥不能把它回给 hook。
    let provider = CountingProvider { _ in "\\C[9]訳" }
    let pipeline = TranslationPipeline(
        cache: cache,
        provider: { provider },
        settings: { settingsBox.value }
    )
    let environment = RGSSPipelineEnvironment(
        pipeline: pipeline,
        cache: cache,
        glossaryBox: nil,
        srcLang: "ja",
        tgtLang: "zh-Hans",
        timeoutSec: 5,
        log: nil
    )
    let translator = RGSSPipelineTranslator(environment: environment)

    let reply = await translator.translate("\\C[2]赤い\\C[0]", version: "RGSS2")
    report.check("RB-B6", "模型返回混入控制码：整条丢弃（返回 nil）",
                 reply == nil, "reply=\(String(describing: reply))")
    report.check("RB-B6b", "corrupt 触发 ignoreCache 重试一次", provider.callCount == 2,
                 "calls=\(provider.callCount)")
}

// MARK: - RB-E 失败降级

func failureSuite(_ report: Reporter) async {
    // E1 bind 失败：用 TEST-NET-3 地址（不是本机接口）触发 EADDRNOTAVAIL。
    // 产品路径里 GameLauncher 捕获这个错误后继续启动（本次不翻译）；桥自身只承诺
    // "返回类型化错误、不崩、stop() 可重复调用"。
    var configuration = RGSSBridge.Configuration()
    configuration.host = "203.0.113.1"
    configuration.logURL = makeLogURL("bind-failure")
    let failing = RGSSBridge(configuration: configuration, translator: nil)
    var bindError: RGSSBridgeError?
    do {
        _ = try failing.start()
        report.check("RB-E1", "bind 失败返回类型化错误", false, "start() 竟然成功")
    } catch let error as RGSSBridgeError {
        bindError = error
        if case .bind = error {
            report.check("RB-E1", "bind 失败返回 .bind 错误", true)
        } else {
            report.check("RB-E1", "bind 失败返回 .bind 错误", false, "error=\(error)")
        }
    } catch {
        report.check("RB-E1", "bind 失败返回类型化错误", false, "error=\(error)")
    }
    failing.stop()
    report.check("RB-E1b", "bind 失败后 port=0 且 stop() 可重复调用",
                 failing.port == 0 && bindError != nil,
                 "port=\(failing.port) error=\(String(describing: bindError))")

    // E2 客户端发一半就 close / 发完立刻 close 都不能把桥打挂。
    guard let (bridge, port) = try? startBridge(translator: ImmediateTranslator(), tag: "half-close") else {
        report.check("RB-E2", "降级桥启动", false, "start() 抛错")
        return
    }
    defer { bridge.stop() }

    if let partial = try? LineClient(port: port) {
        partial.send("TEXT\t70\tRGSS2") // 没有 LF：handler 不会处理这一行
        partial.close()
    }
    if let abrupt = try? LineClient(port: port) {
        abrupt.send(textLine(seq: "71", version: "RGSS2", text: "赤い"))
        abrupt.close() // 不读回包：桥的 send 会撞 EPIPE，不能变成 SIGPIPE
    }
    try? await Task.sleep(nanoseconds: 200_000_000)

    if let client = try? LineClient(port: port) {
        client.send(textLine(seq: "72", version: "RGSS2", text: "まだ生きている"))
        let line = client.readLine()
        let parsed = line.flatMap(parseResponse)
        report.check("RB-E2", "半包/立刻断开后桥仍能服务新连接",
                     parsed?.seq == "72" && decodeBase64(parsed?.payload ?? "") == "译:まだ生きている",
                     "原始行: \(line ?? "nil")")
        client.close()
    } else {
        report.check("RB-E2", "半包/立刻断开后桥仍能服务新连接", false, "connect 失败")
    }
}

// MARK: - main

@main
struct RGSSBridgeProbe {
    static func main() async {
        let report = Reporter()
        protocolSuite(report)
        segmentationSuite(report)
        await timeoutSuite(report)
        await cacheSuite(report)
        await corruptSuite(report)
        await failureSuite(report)
        exit(report.finish())
    }
}
