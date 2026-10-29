//
//  WebPortAssignments.swift
//  MochiBox
//
//  Web 运行后端的**端口确定性派生** + 分配持久表（`web-ports.json`）。
//
//  这是"存档不丢"的关键（docs/archive/v0.2/architecture-v0.2-web-runner.md §3.2.8、§11 R2）：
//  MZ 在浏览器模式下用 localforage/IndexedDB 存档，**按 origin 隔离**；
//  origin 里的端口一变，用户就看到"存档没了"。所以端口必须由 `webRoot` 的
//  规范路径**确定性派生**，并且持久记录（同一游戏下次开机仍是同一端口）。
//

import Foundation

/// 一次端口分配记录。
struct WebPortRecord: Codable, Sendable, Equatable {
    var port: Int
    var webRoot: String
    var updatedAt: Double
}

/// `web-ports.json` 的结构。
struct WebPortTable: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var assignments: [String: WebPortRecord]

    init() {
        self.schemaVersion = 1
        self.assignments = [:]
    }

    init(schemaVersion: Int, assignments: [String: WebPortRecord]) {
        self.schemaVersion = schemaVersion
        self.assignments = assignments
    }
}

actor WebPortAssignments {
    private let paths: AppPaths
    private var table: WebPortTable?
    /// 运行期占位（`release` 只清这里，绝不动持久记录）。
    private var runtimeHolds: [String: Int] = [:]

    init(paths: AppPaths) {
        self.paths = paths
    }

    /// 规范路径：符号链接与 `.`/`..` 都摊平后的小写不敏感身份。
    ///
    /// 不做小写化：APFS 默认大小写不敏感，但同一个目录用不同大小写传入是用户错误，
    /// 而我们**不能**把两套路径映射到同一 origin（`webRoot` 也参与 profile 目录名）。
    static func canonicalPath(_ url: URL) -> String {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `gameHash` = `sha256(canonicalPath)` 的前 16 个 hex 字符（也是 profile 目录名）。
    static func gameHash(for webRoot: URL) -> String {
        let digest = Segmenter.sha256Hex(canonicalPath(webRoot))
        return String(digest.prefix(16))
    }

    /// 派生种子：`sha256("mochibox-web-v1|" + canonicalPath)` 的前 4 字节。
    ///
    /// 前缀常量 `mochibox-web-v1` 是**版本盐**：将来改派生算法时换盐即可整体重排，
    /// 而不是"同一批游戏端口全变"却说不出原因。
    static func candidatePort(webRoot: URL, low: Int, high: Int) -> Int {
        let span = max(1, high - low + 1)
        let digest = Segmenter.sha256Hex("mochibox-web-v1|" + canonicalPath(webRoot))
        let seedHex = String(digest.prefix(8))
        let seed = UInt32(seedHex, radix: 16) ?? 0
        return low + Int(seed % UInt32(span))
    }

    /// 确定性分配端口。
    ///
    /// 规则（顺序不可换）：
    ///   1. 持久表里该 `gameHash` 有记录且没被别的 `gameHash` 占用 → 直接用它（存档 origin 不变）；
    ///   2. 否则从派生候选起线性探测，绕回 `low`，取第一个
    ///      「没被别的 `gameHash` 持久占用 且 `isFree(port)`」的端口；
    ///   3. 写入持久表（原子写、0600）。
    func assign(
        webRoot: URL,
        low: Int = K.webPortLow,
        high: Int = K.webPortHigh,
        isFree: @Sendable (Int) -> Bool
    ) throws -> Int {
        var load = loadTable()
        let hash = WebPortAssignments.gameHash(for: webRoot)
        let canonical = WebPortAssignments.canonicalPath(webRoot)

        // 别的 gameHash 已经占住的端口集合（自身除外）。
        func ownedByOthers() -> Set<Int> {
            var ports: Set<Int> = []
            for (key, record) in load.assignments where key != hash {
                ports.insert(record.port)
            }
            for (key, port) in runtimeHolds where key != hash {
                ports.insert(port)
            }
            return ports
        }

        if let record = load.assignments[hash], record.port >= low, record.port <= high,
           !ownedByOthers().contains(record.port) {
            runtimeHolds[hash] = record.port
            return record.port
        }

        var occupied = ownedByOthers()
        let start = WebPortAssignments.candidatePort(webRoot: webRoot, low: low, high: high)
        let span = high - low + 1
        var chosen: Int?
        var attempt = 0
        while attempt < min(max(span, 1), K.webPortProbeAttempts) {
            let port = low + ((start - low + attempt) % span)
            attempt += 1
            if occupied.contains(port) { continue }
            if !isFree(port) { continue }
            chosen = port
            break
        }
        guard let port = chosen else {
            throw MochiBoxError(
                code: .portUnavailable,
                message: "Web 端口 \(low)–\(high) 内没有可用端口（已尝试 \(attempt) 次）。"
                    + "可能同时开着多个游戏，或上次会话的静态服务没退干净。"
            )
        }

        load.assignments[hash] = WebPortRecord(port: port, webRoot: canonical, updatedAt: Timestamp.nowMs())
        table = load
        try saveTable(load)
        runtimeHolds[hash] = port
        return port
    }

    /// 只看持久记录，不做探测（排障用）。
    func persistedPort(webRoot: URL) -> Int? {
        let hash = WebPortAssignments.gameHash(for: webRoot)
        return loadTable().assignments[hash]?.port
    }

    /// 只清运行期占位，**不清持久记录**：清了下次就可能换端口 → 换 origin → 丢存档。
    func release(webRoot: URL) {
        let hash = WebPortAssignments.gameHash(for: webRoot)
        runtimeHolds.removeValue(forKey: hash)
    }

    /// 持久表快照（selftest / 排障用）。
    func snapshot() -> WebPortTable {
        return loadTable()
    }

    // MARK: 读写

    private func loadTable() -> WebPortTable {
        if let table = table { return table }
        let url = paths.webPortsURL
        guard let data = FileIO.readData(url) else {
            let empty = WebPortTable()
            table = empty
            return empty
        }
        guard let decoded = try? FileIO.decoder.decode(WebPortTable.self, from: data) else {
            // 损坏：不静默重写（重写会让所有游戏换端口 = 全丢存档），只记日志并以空表运行。
            let empty = WebPortTable()
            table = empty
            return empty
        }
        let normalized = WebPortTable(schemaVersion: decoded.schemaVersion, assignments: decoded.assignments)
        table = normalized
        return normalized
    }

    private func saveTable(_ value: WebPortTable) throws {
        let data = try FileIO.encoder.encode(value)
        try FileIO.atomicWrite(data, to: paths.webPortsURL, permissions: 0o600)
    }
}
