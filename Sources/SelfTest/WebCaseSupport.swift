//
//  WebCaseSupport.swift
//  MochiBox
//
//  `--selftest` F 组（Web 运行后端）的客户端设施与用例。
//
//  纪律（docs/archive/v0.2/architecture-v0.2-web-runner.md §11 R5「selftest 假绿」）：
//    · `web_live_*` 用例**开真 socket 发真请求**，不用 mock handler；
//    · 端口确定性、web 根识别、错误文案都用真函数断言，不断言"抛了错"就完；
//    · 用例失败路径也必须 `await server.stop()`：留一个孤儿监听会让后续用例假 `web_port_busy`。
//

import Foundation
import Network

// MARK: - 测试用 HTTP 客户端（走真 socket）

/// 一次 HTTP 响应的可断言形态。
struct TestHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        return headers[name.lowercased()]
    }
}

enum TestHTTP {

    /// 用一个**独立**的 `URLSession`（禁用缓存），避免"第二次请求吃到本地缓存"导致假绿。
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    static func request(
        port: Int,
        path: String,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> TestHTTPResponse {
        guard let url = URL(string: "http://\(K.loopbackHost):\(port)\(path)") else {
            throw SelfTestFailure(message: "非法 URL：\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SelfTestFailure(message: "响应不是 HTTPURLResponse")
        }
        var mapped: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            mapped[String(describing: key).lowercased()] = String(describing: value)
        }
        return TestHTTPResponse(status: http.statusCode, headers: mapped, body: data)
    }

    /// 在**同一条 TCP 连接**上连发多条请求，直到收到全部标记。
    ///
    /// 用来验证 keep-alive 真的生效：若服务端每条响应后都断开，
    /// 第二条请求的 body 就永远到不了同一个累积缓冲里。
    static func pipelinedRawGet(
        port: Int,
        paths: [String],
        markers: [String],
        timeoutSec: Double = 8
    ) async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw SelfTestFailure(message: "非法端口 \(port)")
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "mochibox.selftest.rawhttp")
        let gate = OnceContinuation<String>()
        let accumulator = DataBox()

        func finish(_ result: Result<String, Error>) {
            connection.stateUpdateHandler = nil
            connection.cancel()
            gate.resolve(result)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    accumulator.append(data)
                    let text = String(decoding: accumulator.snapshot(), as: UTF8.self)
                    if markers.allSatisfy({ text.contains($0) }) {
                        finish(.success(text))
                        return
                    }
                }
                if let error = error {
                    finish(.failure(error))
                    return
                }
                if isComplete {
                    finish(.success(String(decoding: accumulator.snapshot(), as: UTF8.self)))
                    return
                }
                receive()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var text = ""
                for path in paths {
                    text += "GET \(path) HTTP/1.1\r\nHost: \(K.loopbackHost):\(port)\r\n"
                        + "Connection: keep-alive\r\n\r\n"
                }
                connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                    if let error = error { finish(.failure(error)) }
                })
                receive()
            case .failed(let error):
                finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)

        let timeoutTask = Task { () -> Void in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
            gate.resolve(.failure(SelfTestFailure(
                message: "keep-alive 两个请求在 \(timeoutSec)s 内没有全部收到"
            )))
        }

        do {
            let text = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                gate.setContinuation(continuation)
            }
            timeoutTask.cancel()
            return text
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }
}

/// 跨队列累积字节（`NWConnection` 回调跑在专用队列上）。
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

// MARK: - 测试用目录 / 端口 / 服务

extension SelfTestRunner {

    /// 一个临时 web 根：按字典写 `相对路径 → 内容`。
    static func webRoot(_ context: SelfTestContext, _ name: String, files: [String: String]) throws -> URL {
        let root = try directory(context, name)
        for (path, contents) in files {
            try touch(root, path, contents: contents)
        }
        return root
    }

    /// 从固定区间里扫一个当前空闲的回环端口（不用随机，便于复现）。
    static func freeLoopbackPort(from low: Int = 39600, to high: Int = 39700) -> Int? {
        for port in low...high where LoopbackPort.isFree(port) {
            return port
        }
        return nil
    }

    /// 起服务 → 跑断言 → **无论成功失败都 stop**（端口必须还回去）。
    static func withServer<T>(root: URL, _ body: (Int) async throws -> T) async throws -> T {
        guard let port = freeLoopbackPort() else {
            throw SelfTestFailure(message: "找不到空闲回环端口（39600–39700）")
        }
        let server = StaticWebServer(root: root, port: port, log: nil)
        let bound = try await server.start()
        do {
            let value = try await body(bound)
            await server.stop()
            return value
        } catch {
            await server.stop()
            throw error
        }
    }

    /// 分块写大文件（避免测试进程自己先分配几十 MB 的 `Data`）。
    static func writeBigFile(at url: URL, size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw SelfTestFailure(message: "无法打开待写文件 \(url.path)")
        }
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x41, count: 256 * 1024)
        var written = 0
        while written < size {
            let want = min(chunk.count, size - written)
            try handle.write(contentsOf: Data(chunk.prefix(want)))
            written += want
        }
        try handle.synchronize()
    }
}

// MARK: - F 组：静态 HTTP 服务

extension SelfTestRunner {

    static var webCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "F", name: "web_mime_table") { _ in
                try expectEqual(StaticWebRequest.mimeType(forPath: "index.html"), "text/html; charset=utf-8", "html")
                try expectEqual(StaticWebRequest.mimeType(forPath: "js/rmmz_core.js"), "text/javascript; charset=utf-8", "js")
                try expectEqual(StaticWebRequest.mimeType(forPath: "data/System.json"), "application/json; charset=utf-8", "json")
                try expectEqual(StaticWebRequest.mimeType(forPath: "audio/bgm/a.ogg"), "audio/ogg", "ogg")
                // 按需转码的产物：WKWebView 只认 hvc1 的 mp4/mov 容器，类型必须报 video/mp4。
                try expectEqual(StaticWebRequest.mimeType(forPath: "cache/abc.mov"), "video/mp4", "mov")
                try expectEqual(StaticWebRequest.mimeType(forPath: "movies/a.mpon"), "application/octet-stream", "mpon 本身无类型")
                try expectEqual(StaticWebRequest.mimeType(forPath: "fonts/x.woff2"), "font/woff2", "woff2")
                try expectEqual(StaticWebRequest.mimeType(forPath: "audio/keys.efkefc"), "application/octet-stream", "efkefc")
                // 未命中一律 octet-stream：猜错类型会让 Chromium 走错解码器，比"不知道"更糟。
                try expectEqual(StaticWebRequest.mimeType(forPath: "weird.zzz"), "application/octet-stream", "unknown")
                try expectEqual(StaticWebRequest.fileExtension(ofPath: "pack.tar.gz"), "gz", "多点扩展名取最后一个")
                try expectEqual(StaticWebRequest.fileExtension(ofPath: "noext"), "", "无扩展名")
                // HTML/JS/JSON 必须 no-cache（否则覆盖安装游戏后仍跑旧 JS）。
                try expectEqual(StaticWebRequest.cacheMaxAge(forPath: "index.html"), 0, "html no-cache")
                try expect(StaticWebRequest.cacheMaxAge(forPath: "a.png") > 0, "png 应有 max-age")
                let headers = StaticWebRequest.commonHeaders(cacheMaxAge: 3600)
                try expect(headers.contains("Accept-Ranges: bytes"),
                           "必须给 Accept-Ranges，否则 <audio> 不会尝试 Range")
                try expect(headers.contains("X-Content-Type-Options: nosniff"), "必须给 nosniff")
                try expect(headers.contains("Cache-Control: public, max-age=3600"), "素材缓存头")
                try expect(StaticWebRequest.commonHeaders(cacheMaxAge: 0).contains("Cache-Control: no-cache"),
                           "no-cache 而非 no-store")
            },
            SelfTestCase(group: "F", name: "media_rendition_rules") { context in
                // 只处理 MZ 的视频素材扩展名（大小写不敏感）—— 其它路径必须零 IO 直接返回。
                try expect(MediaRenditions.isCandidate(path: "movies/a.mpon"), "mpon 是候选")
                try expect(MediaRenditions.isCandidate(path: "movies/a.MPON"), "扩展名大小写不敏感")
                // .webm **不**换：WKWebView 按 URL 扩展名选解复用器，MP4 字节挂在 .webm 上直接
                // NotSupportedError（实测 readyState=0）。这条断言防止有人"顺手"把它加回来。
                try expect(!MediaRenditions.isCandidate(path: "movies/titleback.webm"), "webm 不是候选")
                try expect(!MediaRenditions.isCandidate(path: "audio/a.ogg"), "ogg 不是候选")
                try expect(!MediaRenditions.isCandidate(path: "movies/a"), "无扩展名不是候选")

                // 缓存键：同输入同输出；尺寸 / mtime / 路径任一变化都必须换键，
                // 否则"换素材"或"热更新"后会复用旧产物（画面停留在上一版）。
                let key = MediaRenditions.cacheKey(sourcePath: "/g/movies/a.mpon", size: 100, mtime: 1_700_000_000)
                try expectEqual(key.count, 16, "16 位十六进制")
                try expectEqual(key,
                                MediaRenditions.cacheKey(sourcePath: "/g/movies/a.mpon", size: 100, mtime: 1_700_000_000),
                                "同输入同键")
                try expect(key != MediaRenditions.cacheKey(sourcePath: "/g/movies/a.mpon", size: 101, mtime: 1_700_000_000),
                           "尺寸变则换键")
                try expect(key != MediaRenditions.cacheKey(sourcePath: "/g/movies/a.mpon", size: 100, mtime: 1_700_000_001),
                           "mtime 变则换键")
                try expect(key != MediaRenditions.cacheKey(sourcePath: "/g/movies/b.mpon", size: 100, mtime: 1_700_000_000),
                           "路径变则换键")

                // stderr 判定：matroska 的 alpha_mode tag 与解码出的 yuva420p 都认；
                // 两者都没有（含空串）必须是 false —— 探测失败绝不能当成"有 alpha"。
                let tagged = "  Stream #0:0(eng): Video: vp9 (libvpx-vp9), yuv420p(tv), 1280x1280\n"
                    + "    alpha_mode      : 1\n"
                try expect(MediaRenditions.probeSaysAlpha(tagged), "alpha_mode tag")
                try expect(MediaRenditions.probeSaysAlpha("  Stream #0:0: Video: vp9, yuva420p, 640x480"), "yuva420p")
                try expect(!MediaRenditions.probeSaysAlpha("  Stream #0:0: Video: hevc, yuv420p, 1280x720"), "无 alpha")
                try expect(!MediaRenditions.probeSaysAlpha(""), "空 stderr 必须是 false")

                // 第 2/3 步的纯函数：时长解析 + alpha 平面最小值。
                try expectEqual(MediaRenditions.durationSeconds(fromProbe: "  Duration: 00:00:03.01, start: 0.000000"),
                                3.01, "秒级时长")
                try expectEqual(MediaRenditions.durationSeconds(fromProbe: "Duration: 00:01:02.50"), 62.5, "分秒时长")
                try expect(MediaRenditions.durationSeconds(fromProbe: "Duration: N/A") == nil, "N/A 取不到时长")
                try expect(MediaRenditions.durationSeconds(fromProbe: "") == nil, "空 stderr 取不到时长")

                // 长度必须正好 4096（64×64）；长度不对不能当"全不透明"，必须返回 nil。
                var gray = Data(repeating: 255, count: 64 * 64)
                gray[1234] = 200
                try expectEqual(MediaRenditions.alphaFloor(fromGray: gray), 200, "取最小 alpha")
                try expect(MediaRenditions.alphaFloor(fromGray: Data(repeating: 255, count: 4095)) == nil,
                           "长度不对 → nil")
                try expect(MediaRenditions.alphaFloor(fromGray: Data()) == nil, "空数据 → nil")
                try expectEqual(MediaRenditions.alphaFloor(fromGray: Data(repeating: 255, count: 4096)), 255,
                                "全不透明")

                // 回退不变量：没有 ffmpeg 时必须返回 nil，且不得创建缓存目录 / 写游戏目录。
                let directory = try directory(context, "f_rendition")
                let renditions = MediaRenditions(
                    binaryPath: directory.appendingPathComponent("no-such-ffmpeg").path,
                    cacheDirectory: directory.appendingPathComponent("media-cache")
                )
                try expect(renditions.rendition(for: directory.appendingPathComponent("x.png").path) == nil,
                           "非候选扩展名 → nil")
                try expect(renditions.rendition(for: directory.appendingPathComponent("x.mpon").path) == nil,
                           "二进制缺失 → 回退原始字节")
                try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("media-cache").path),
                           "回退路径不得创建缓存目录")
            },
            SelfTestCase(group: "F", name: "web_range_parse") { _ in
                // 架构 §4.4 的表逐行对应。
                try expectEqual(StaticWebRequest.parseRange("bytes=100-199", fileSize: 1000),
                                .satisfiable(ByteRange(start: 100, end: 199)), "bytes=100-199")
                try expectEqual(StaticWebRequest.parseRange("bytes=500-", fileSize: 1000),
                                .satisfiable(ByteRange(start: 500, end: 999)), "bytes=500-")
                try expectEqual(StaticWebRequest.parseRange("bytes=-200", fileSize: 1000),
                                .satisfiable(ByteRange(start: 800, end: 999)), "bytes=-200")
                try expectEqual(StaticWebRequest.parseRange("bytes=1000-", fileSize: 1000), .unsatisfiable, "越界")
                try expectEqual(StaticWebRequest.parseRange("bytes=0-9,20-29", fileSize: 1000), .ignore, "多段忽略")
                try expectEqual(StaticWebRequest.parseRange("bytes=abc", fileSize: 1000), .ignore, "语法不合法")
                try expectEqual(StaticWebRequest.parseRange("items=0-1", fileSize: 1000), .ignore, "单位不认")
                // 终点必须被 fileSize-1 夹紧（`bytes=0-999999999` 很常见）。
                try expectEqual(StaticWebRequest.parseRange("bytes=0-999999999", fileSize: 1000),
                                .satisfiable(ByteRange(start: 0, end: 999)), "终点夹紧")
                try expectEqual(StaticWebRequest.parseRange("bytes=990-2000", fileSize: 1000),
                                .satisfiable(ByteRange(start: 990, end: 999)), "尾部截断")
                try expectEqual(ByteRange(start: 100, end: 199).length, 100, "区间长度")
            },
            SelfTestCase(group: "F", name: "web_path_traversal") { context in
                let root = try webRoot(context, "f_traversal", files: [
                    "index.html": "<html></html>",
                    "a/file.txt": "hello",
                    "data/b.txt": "data"
                ])
                // 根下建一个指向 /etc 的符号链接：必须被 resolvingSymlinksInPath 兜住。
                let link = root.appendingPathComponent("link")
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc")

                func expectRejected(_ target: String, _ status: Int, _ label: String) throws {
                    do {
                        _ = try StaticWebRequest.resolve(target: target, root: root)
                        throw SelfTestFailure(message: "\(label) 应被拒绝（\(target)）")
                    } catch let error as StaticWebRequest.ResolutionError {
                        try expectEqual(error.status, status, "\(label) 状态码")
                    }
                }

                try expectRejected("/../etc/passwd", 403, "../ 穿越")
                try expectRejected("/..%2F..%2Fetc/passwd", 403, "编码后的 ../")
                try expectRejected("/a/%2e%2e/b", 403, "%2e%2e")
                try expectRejected("/link/passwd", 403, "符号链接逃逸")
                try expectRejected("/data/", 404, "目录不列（无 index.html）")
                try expectRejected("/%zz", 400, "非法百分号编码")
                try expectRejected("/a\\file.txt", 403, "反斜杠")
                try expectRejected("/nope.js", 404, "不存在")

                // 正常路径仍然可用。
                switch try StaticWebRequest.resolve(target: "/", root: root) {
                case .directoryIndex(let url):
                    try expect(url.lastPathComponent == K.webDirectoryIndexName,
                               "`/` → index.html，实际 \(url.lastPathComponent)")
                default:
                    throw SelfTestFailure(message: "`/` 应解析成目录索引")
                }
                switch try StaticWebRequest.resolve(target: "/a/file.txt", root: root) {
                case .file(let url):
                    try expect(url.lastPathComponent == "file.txt", "普通文件")
                default:
                    throw SelfTestFailure(message: "/a/file.txt 应解析成文件")
                }
                // 带 query 的请求（Chromium 有时会加 cache buster）。
                switch try StaticWebRequest.resolve(target: "/a/file.txt?t=1", root: root) {
                case .file(let url):
                    try expect(url.lastPathComponent == "file.txt", "query 不应参与路径")
                default:
                    throw SelfTestFailure(message: "带 query 的路径解析失败")
                }
            },
            SelfTestCase(group: "F", name: "web_live_get") { context in
                // 32MB 临时文件：断言「Content-Length 正确 + 收到的字节数正确」。
                //
                // 说明：这里**不**断言进程 RSS —— 内存断言在 CI/本机都会抖，写了就是假红；
                // 「没有整读」由 QA 侧 `grep -n "contentsOf" Sources/Adapters/Web/` 静态把关。
                let size = 32 * 1024 * 1024
                let root = try webRoot(context, "f_live_get", files: ["index.html": "<html></html>"])
                let bigURL = root.appendingPathComponent("big.bin")
                try writeBigFile(at: bigURL, size: size)
                defer { try? FileManager.default.removeItem(at: bigURL) }

                try await withServer(root: root) { port in
                    let response = try await TestHTTP.request(port: port, path: "/big.bin")
                    try expectEqual(response.status, 200, "状态码")
                    try expectEqual(response.header("content-length"), "\(size)", "Content-Length")
                    try expectEqual(response.body.count, size, "收到的字节数")
                    try expectEqual(response.header("accept-ranges"), "bytes", "Accept-Ranges")
                    try expectEqual(response.header("content-type"), "application/octet-stream", "MIME")
                }
            },
            SelfTestCase(group: "F", name: "web_live_range_206") { context in
                let root = try webRoot(context, "f_live_range", files: [
                    "index.html": "<html></html>",
                    "blob.bin": String(repeating: "A", count: 1000)
                ])
                try await withServer(root: root) { port in
                    let partial = try await TestHTTP.request(
                        port: port,
                        path: "/blob.bin",
                        headers: ["Range": "bytes=100-199"]
                    )
                    try expectEqual(partial.status, 206, "206 状态码")
                    try expectEqual(partial.header("content-range"), "bytes 100-199/1000", "Content-Range")
                    try expectEqual(partial.header("content-length"), "100", "Content-Length 是区间长度")
                    try expectEqual(partial.body.count, 100, "区间 body 字节数")

                    let openEnded = try await TestHTTP.request(
                        port: port,
                        path: "/blob.bin",
                        headers: ["Range": "bytes=500-"]
                    )
                    try expectEqual(openEnded.status, 206, "开区间 206")
                    try expectEqual(openEnded.header("content-range"), "bytes 500-999/1000", "开区间 Content-Range")

                    let suffix = try await TestHTTP.request(
                        port: port,
                        path: "/blob.bin",
                        headers: ["Range": "bytes=-200"]
                    )
                    try expectEqual(suffix.header("content-range"), "bytes 800-999/1000", "后缀区间")

                    let tooFar = try await TestHTTP.request(
                        port: port,
                        path: "/blob.bin",
                        headers: ["Range": "bytes=1000-"]
                    )
                    try expectEqual(tooFar.status, 416, "越界 416")
                    try expectEqual(tooFar.header("content-range"), "bytes */1000", "416 的 Content-Range")

                    // 多段 → 忽略 Range，回 200 全量（宁可全量也不写半吊子 multipart）。
                    let multi = try await TestHTTP.request(
                        port: port,
                        path: "/blob.bin",
                        headers: ["Range": "bytes=0-9,20-29"]
                    )
                    try expectEqual(multi.status, 200, "多段回 200")
                    try expectEqual(multi.body.count, 1000, "多段回全量")
                }
            },
            SelfTestCase(group: "F", name: "web_live_head_no_body") { context in
                let root = try webRoot(context, "f_live_head", files: [
                    "index.html": "<html></html>",
                    "blob.bin": String(repeating: "B", count: 500)
                ])
                try await withServer(root: root) { port in
                    let head = try await TestHTTP.request(port: port, path: "/blob.bin", method: "HEAD")
                    try expectEqual(head.status, 200, "HEAD 状态码")
                    try expectEqual(head.header("content-length"), "500", "HEAD 的 Content-Length 是全量")
                    try expectEqual(head.body.count, 0, "HEAD 不得发 body")

                    let ranged = try await TestHTTP.request(
                        port: port,
                        path: "/blob.bin",
                        method: "HEAD",
                        headers: ["Range": "bytes=0-9"]
                    )
                    try expectEqual(ranged.status, 206, "HEAD + Range 仍是 206")
                    try expectEqual(ranged.header("content-length"), "10", "HEAD + Range 的区间长度")

                    let missing = try await TestHTTP.request(port: port, path: "/nope.js")
                    try expectEqual(missing.status, 404, "不存在 → 404")
                }
            },
            SelfTestCase(group: "F", name: "web_keepalive_two_requests") { context in
                let root = try webRoot(context, "f_keepalive", files: [
                    "index.html": "<html></html>",
                    "a.txt": "MARK-A",
                    "b.txt": "MARK-B"
                ])
                try await withServer(root: root) { port in
                    let text = try await TestHTTP.pipelinedRawGet(
                        port: port,
                        paths: ["/a.txt", "/b.txt"],
                        markers: ["MARK-A", "MARK-B"]
                    )
                    try expect(text.contains("HTTP/1.1 200"), "第一条响应状态行")
                    try expect(text.contains("MARK-A"), "第一条 body")
                    try expect(text.contains("MARK-B"), "第二条 body（同一连接）")
                    try expect(text.contains("Connection: keep-alive"), "应回 keep-alive")
                }
            },
            SelfTestCase(group: "F", name: "web_stop_releases_port") { context in
                let root = try webRoot(context, "f_stop_port", files: ["index.html": "<html></html>"])
                guard let port = freeLoopbackPort() else {
                    throw SelfTestFailure(message: "找不到空闲回环端口")
                }
                let server = StaticWebServer(root: root, port: port, log: nil)
                let bound = try await server.start()
                try expectEqual(bound, port, "绑定端口")
                do {
                    let response = try await TestHTTP.request(port: bound, path: "/")
                    try expectEqual(response.status, 200, "服务可用")
                } catch {
                    await server.stop()
                    throw error
                }
                await server.stop()
                // `allowLocalEndpointReuse` + `stop()` 等端口真正释放：立刻重建必须成功。
                try expect(LoopbackPort.isFree(port),
                           "stop() 之后端口必须立刻空闲（否则下次启动就是假 web_port_busy）")
                let again = StaticWebServer(root: root, port: port, log: nil)
                let rebound = try await again.start()
                try expectEqual(rebound, port, "同端口重建")
                await again.stop()
                // 幂等：第二次 stop 不崩。
                await again.stop()
                try expectEqual(await again.activeConnections, 0, "stop 后连接数归零")
            }
        ]
    }
}
