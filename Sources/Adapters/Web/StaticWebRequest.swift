//
//  StaticWebRequest.swift
//  MochiBox
//
//  静态 Web 服务的**纯函数层**：请求行/头解析、目标路径解码、路径穿越防护、
//  `Range` 解析、MIME 表、响应头拼装。
//
//  约束（docs/archive/v0.2/architecture-v0.2-web-runner.md §2.1 N1）：
//    · 零 socket、零 I/O 副作用 —— 读文件由调用方（`StaticWebServer`）做；
//    · 不得出现任何 `NWConnection` 类型 —— 因此这一层能被 `--selftest` 直接调用；
//    · 不得 import AppKit / SwiftUI。
//

import Foundation
import Darwin

/// 半开闭区间 `[start, end]`（`end` 含）。长度用 `Int64`：单个大 `.ogg` 可能 > 2GB。
struct ByteRange: Sendable, Equatable {
    var start: Int64
    var end: Int64

    var length: Int64 { return end - start + 1 }
}

enum StaticWebRequest {

    // MARK: - 类型

    /// 解析出的请求头（只保留我们真正用到的字段）。
    struct RequestHead: Sendable, Equatable {
        var method: String
        /// 原始 target（可能含 query，可能是 absolute-form）。
        var target: String
        var httpVersion: String
        var rangeHeader: String?
        /// `Connection: close`，或 HTTP/1.0 且没有 `keep-alive`。
        var wantsClose: Bool
    }

    /// `Range` 头的判定结果。
    enum RangeOutcome: Sendable, Equatable {
        /// 无 Range 头 → 200 全量。
        case none
        /// 命中 → 206 + `Content-Range` + 区间 body。
        case satisfiable(ByteRange)
        /// 起点越过文件尾 → 416 + `Content-Range: bytes */size`。
        case unsatisfiable
        /// 多段/语法不合法 → 忽略 Range，200 全量（多段不实现，宁可全量）。
        case ignore
    }

    /// 目标路径的磁盘落点。
    enum Resolution: Sendable, Equatable {
        case file(URL)
        /// 请求的是目录，且目录下有索引文件（`index.html`）。
        case directoryIndex(URL)
    }

    /// 解析失败（对应 400 / 403 / 404）。**不用** `MochiBoxError`：这里不是产品错误面，
    /// 是 HTTP 状态码，且需要能被纯函数单测直接比对。
    struct ResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
        var status: Int
        var reason: String

        var description: String { return "\(status) \(reason)" }
    }

    // MARK: - 常量

    /// 请求头的边界标记。
    static let headTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    /// MIME 表（架构 §4.6）。未命中一律 `application/octet-stream`：
    /// 猜错类型比 `octet-stream` 更糟 —— Chromium 会按 `Content-Type` 走不同的解码器。
    static let mimeTable: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "webm": "video/webm",
        "mp4": "video/mp4",
        // 按需转码的产物（HEVC-with-alpha）：WKWebView 只认 hvc1 的 mp4/mov 容器。
        "mov": "video/mp4",
        "wasm": "application/wasm",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "efkefc": "application/octet-stream"
    ]

    /// 命中这些扩展名的资源必须 `no-cache`（每次带条件请求），而不是 `no-store`。
    ///
    /// 理由：MZ 用 `fetch('data/System.json')`，`no-store` 在某些 Chromium 版本上会连带
    /// 禁用媒体流的续传缓存 → 素材被反复重下；而 `no-cache` 在本地回环上的代价 ≈ 0。
    static let noCacheExtensions: Set<String> = ["html", "htm", "js", "mjs", "json", "css", "txt"]

    // MARK: - 请求头解析

    /// 从缓冲区里切出请求头（到 `\r\n\r\n`）。
    ///
    /// - Returns: `nil` 表示"还没收全"（调用方继续 receive，超过
    ///   `K.webMaxHeadBytes` 则由调用方回 431）。
    static func parseHead(_ buffer: Data) -> (head: RequestHead, consumed: Int)? {
        guard let markerRange = buffer.range(of: headTerminator) else { return nil }
        let headData = buffer[buffer.startIndex..<markerRange.lowerBound]
        // 请求头按 HTTP 规范是 ASCII/latin1；用 UTF-8 解不出来就退回 latin1，
        // 绝不因为一个人为构造的字节序列把连接搞死。
        let text = String(data: Data(headData), encoding: .utf8)
            ?? String(data: Data(headData), encoding: .isoLatin1)
        guard let headText = text else { return nil }

        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]
        let version = parts.count >= 3 ? parts[2] : "HTTP/1.0"

        var rangeHeader: String?
        var connectionHeader: String?
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "range":
                rangeHeader = value
            case "connection":
                connectionHeader = value.lowercased()
            default:
                break
            }
        }

        let isHTTP10 = version.uppercased().hasPrefix("HTTP/1.0")
        let wantsClose: Bool
        if let connectionHeader = connectionHeader {
            wantsClose = connectionHeader.contains("close")
        } else {
            // HTTP/1.0 默认短连接；HTTP/1.1 默认 keep-alive。
            wantsClose = isHTTP10
        }

        let head = RequestHead(
            method: method,
            target: target,
            httpVersion: version,
            rangeHeader: rangeHeader,
            wantsClose: wantsClose
        )
        let consumed = buffer.distance(from: buffer.startIndex, to: markerRange.upperBound)
        return (head, consumed)
    }

    // MARK: - 路径解析与穿越防护

    /// 把请求 target 映射成磁盘路径（架构 §4.5 的六条断言全靠这里）。
    ///
    /// 顺序不可调换：切 query → 取 absolute-form 的 path → **解码一次** → NUL/反斜杠拒绝
    /// → 词法规范化 → 符号链接解析后仍在 root 之内 → 目录补索引。
    static func resolve(target: String, root: URL) throws -> Resolution {
        var raw = target
        if let cut = raw.firstIndex(of: "?") { raw = String(raw[raw.startIndex..<cut]) }
        if let cut = raw.firstIndex(of: "#") { raw = String(raw[raw.startIndex..<cut]) }

        // absolute-form："http://127.0.0.1:39310/a.js"
        let lowered = raw.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            if let parsed = URL(string: raw) { raw = parsed.path }
        }

        // 百分号解码**只做一次**：递归解码会把 `%252e%252e` 变成 `..`（那是漏洞不是特性）。
        guard let decoded = raw.removingPercentEncoding else {
            throw ResolutionError(status: 400, reason: "bad_percent_encoding")
        }
        guard !decoded.contains("\u{0}") else {
            throw ResolutionError(status: 400, reason: "nul_byte")
        }
        // MZ 的素材路径不含反斜杠；出现反斜杠只可能是构造穿越（Windows 风格）。
        guard !decoded.contains("\\") else {
            throw ResolutionError(status: 403, reason: "backslash_rejected")
        }

        var relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded

        // 解码后出现 `..` 段一律拒绝（不只是"跑出 root"）：`/a/../b` 词法上仍落在 root 内，
        // 但它 100% 是构造出来的探针（真实素材路径不含 `..`）。宁可 403 也不做"聪明的
        // 归一化后放行"——那条路一不小心就变成穿越漏洞。
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
            throw ResolutionError(status: 403, reason: "path_traversal")
        }

        // 空路径（`/`）就是 root 本身：交给下面的"目录 → 补索引"分支处理，
        // 这样 `Resolution` 能如实报出 `.directoryIndex`（而不是假装请求了 index.html）。
        let candidate = relative.isEmpty
            ? root.standardizedFileURL
            : root.appendingPathComponent(relative).standardizedFileURL
        let rootCanonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidateCanonical = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let insideRoot = candidateCanonical == rootCanonical
            || candidateCanonical.hasPrefix(rootCanonical + "/")
        guard insideRoot else {
            // `../`、`..%2F`、`%2e%2e`、以及"root 下建一个指向 /etc 的符号链接"全落这里。
            throw ResolutionError(status: 403, reason: "path_traversal")
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw ResolutionError(status: 404, reason: "not_found")
        }
        if !isDirectory.boolValue {
            return .file(candidate)
        }

        // 目录：只补索引文件，**绝不列目录**（列目录会把用户盘上的文件名泄给页面）。
        guard let indexURL = directoryIndex(in: candidate) else {
            throw ResolutionError(status: 404, reason: "no_directory_index")
        }
        return .directoryIndex(indexURL)
    }

    /// 目录下的索引文件：先按精确名找，再按大小写不敏感找
    /// （macOS 默认大小写不敏感，但用户可能在大小写敏感卷上放 `Index.html`）。
    static func directoryIndex(in directory: URL) -> URL? {
        let manager = FileManager.default
        let exact = directory.appendingPathComponent(K.webDirectoryIndexName)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: exact.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return exact
        }
        let names = DirectoryReader.entryNames(directory)
        guard !names.isEmpty else { return nil }
        let wanted = K.webDirectoryIndexName.lowercased()
        for name in names.sorted() where name.lowercased() == wanted {
            let url = directory.appendingPathComponent(name)
            var childIsDirectory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &childIsDirectory), !childIsDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    // MARK: - Range

    /// 只实现单段 `Range`（架构 §4.4 的表逐行对应）。
    static func parseRange(_ header: String, fileSize: Int64) -> RangeOutcome {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("bytes=") else { return .ignore }
        let spec = String(trimmed.dropFirst("bytes=".count))
        // 多段不实现：宁可全量 200，也不实现半吊子的 multipart/byteranges。
        guard !spec.contains(",") else { return .ignore }
        let pieces = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .ignore }

        let firstText = pieces[0].trimmingCharacters(in: .whitespaces)
        let secondText = pieces[1].trimmingCharacters(in: .whitespaces)

        if firstText.isEmpty {
            // `bytes=-200`：最后 200 字节。
            guard let suffix = Int64(secondText), suffix > 0 else { return .ignore }
            guard fileSize > 0 else { return .unsatisfiable }
            let start = max(Int64(0), fileSize - suffix)
            return .satisfiable(ByteRange(start: start, end: fileSize - 1))
        }

        guard let start = Int64(firstText), start >= 0 else { return .ignore }
        if secondText.isEmpty {
            // `bytes=500-`
            guard start < fileSize else { return .unsatisfiable }
            return .satisfiable(ByteRange(start: start, end: fileSize - 1))
        }
        guard let endRaw = Int64(secondText), endRaw >= start else { return .ignore }
        guard start < fileSize else { return .unsatisfiable }
        // `bytes=0-999999999` 很常见：终点必须夹紧到 `fileSize-1`。
        let end = min(endRaw, fileSize - 1)
        return .satisfiable(ByteRange(start: start, end: end))
    }

    // MARK: - MIME / 缓存

    /// 取最后一个点之后的扩展名并小写（`.tar.gz` → `gz`）。
    static func fileExtension(ofPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    static func mimeType(forExtension ext: String) -> String {
        let key = ext.lowercased()
        return mimeTable[key] ?? "application/octet-stream"
    }

    static func mimeType(forPath path: String) -> String {
        return mimeType(forExtension: fileExtension(ofPath: path))
    }

    /// 返回值语义：`0` = `no-cache`（每次带条件请求）；`> 0` = `public, max-age=N`。
    static func cacheMaxAge(forPath path: String) -> Int {
        let ext = fileExtension(ofPath: path)
        if noCacheExtensions.contains(ext) { return 0 }
        return K.webAssetCacheMaxAgeSec
    }

    /// 公共响应头（架构 §4.7）。
    ///
    /// **约定**：返回的字符串每一行都以 `\r\n` 结尾（不含末尾空行），调用方可直接拼接
    /// 状态行与 `Content-Length` 之后再用一个 `\r\n` 收尾。
    static func commonHeaders(cacheMaxAge: Int) -> String {
        var lines = [
            "Accept-Ranges: bytes",
            "X-Content-Type-Options: nosniff"
        ]
        if cacheMaxAge <= 0 {
            lines.append("Cache-Control: no-cache")
        } else {
            lines.append("Cache-Control: public, max-age=\(cacheMaxAge)")
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    // MARK: - 状态行

    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    /// 拼装完整响应头（含末尾空行）。
    static func responseHead(status: Int, headers: [String]) -> String {
        var text = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        for line in headers {
            text += line + "\r\n"
        }
        text += "\r\n"
        return text
    }
}

/// 目录条目读取（POSIX `readdir`）。
///
/// 为什么不用 `FileManager` 的目录列举方法：静态服务的"禁整读"门禁是一条**子串** grep，
/// 那个 API 的名字与禁读 API 同词根，会让门禁在完全合法的代码上假红 —— 而"假红"的下一步
/// 通常是有人去给门禁加豁免，门禁随即失效。这里直接走 `readdir`：真·不读文件内容，
/// 门禁保持 0 命中且仍然可执行。
///
/// 语义与"读目录名列表"一致：不含 `.` / `..`，不保证顺序（调用方各自 `sorted()`）。
enum DirectoryReader {
    static func entryNames(_ directory: URL) -> [String] {
        guard let handle = opendir(directory.path) else { return [] }
        defer { closedir(handle) }

        var names: [String] = []
        while let entry = readdir(handle) {
            var rawName = entry.pointee.d_name
            // 先把长度算出来再取指针：在 `withUnsafePointer(to: &rawName)` 的闭包里再读
            // `rawName` 会触发独占访问检查（overlapping accesses）而编译失败。
            let nameCapacity = MemoryLayout.size(ofValue: rawName)
            let name = withUnsafePointer(to: &rawName) { pointer -> String in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { chars in
                    String(cString: chars)
                }
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }
}
