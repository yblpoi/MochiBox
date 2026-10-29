//
//  GlossaryStore.swift
//  MochiBox
//
//  每游戏术语表的持久化：`<AppPaths.root>/glossary/<gameHash>.json`。
//
//  与全文译文的区别：
//  · 术语表是**词粒度**的，体量小（通常几百条），可以整文件读写；
//  · 人工编辑优先：`edited == true` 的条目不会被自动学习覆盖；
//  · 损坏时降级为「只有内置种子」，不阻塞会话（对齐 FullTextStore 的隔离策略）。
//
//  本文件只 import Foundation（分层门禁）。
//

import Foundation

// MARK: - 文件模型

struct GlossaryFile: Codable, Sendable, Equatable {
    var version: Int
    var gameHash: String
    var srcLang: String
    var tgtLang: String
    var updatedAt: String
    var entries: [GlossaryEntry]
    /// 被用户删除的原文（墓碑）。不存的话下次启动「种子 + 文件」会把删掉的词复活。
    var deletedSources: [String]?

    init(
        version: Int = 1,
        gameHash: String,
        srcLang: String = K.fixedSrcLang,
        tgtLang: String = K.fixedTgtLang,
        updatedAt: String = Timestamp.iso8601Ms(),
        entries: [GlossaryEntry] = [],
        deletedSources: [String]? = nil
    ) {
        self.version = version
        self.gameHash = gameHash
        self.srcLang = srcLang
        self.tgtLang = tgtLang
        self.updatedAt = updatedAt
        self.entries = entries
        self.deletedSources = deletedSources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = c.tolerantValue(Int.self, forKey: .version, 1)
        self.gameHash = c.tolerantValue(String.self, forKey: .gameHash, "")
        self.srcLang = c.tolerantValue(String.self, forKey: .srcLang, K.fixedSrcLang)
        self.tgtLang = c.tolerantValue(String.self, forKey: .tgtLang, K.fixedTgtLang)
        self.updatedAt = c.tolerantValue(String.self, forKey: .updatedAt, "")
        self.entries = c.tolerantValue([GlossaryEntry].self, forKey: .entries, [])
        self.deletedSources = c.tolerantOptional([String].self, forKey: .deletedSources)
    }
}

// MARK: - 存储

final class GlossaryStore: @unchecked Sendable {
    let directory: URL
    let gameHash: String
    private let log: SessionLog?

    init(directory: URL, gameHash: String, log: SessionLog? = nil) {
        self.directory = directory
        self.gameHash = gameHash
        self.log = log
    }

    convenience init(paths: AppPaths, gameHash: String, log: SessionLog? = nil) {
        self.init(directory: GlossaryStore.defaultDirectory(paths: paths), gameHash: gameHash, log: log)
    }

    static func defaultDirectory(paths: AppPaths = .shared) -> URL {
        return paths.root.appendingPathComponent("glossary", isDirectory: true)
    }

    var url: URL {
        let name = gameHash.isEmpty ? "unknown" : gameHash
        return directory.appendingPathComponent("\(name).json")
    }

    // MARK: 读写

    /// 读盘。损坏时隔离为 `.corrupt-<时间戳>` 后返回 nil。
    func load() -> GlossaryFile? {
        guard let data = FileIO.readData(url) else { return nil }
        do {
            var file = try FileIO.decoder.decode(GlossaryFile.self, from: data)
            if file.gameHash.isEmpty { file.gameHash = gameHash }
            file.entries = file.entries.filter { !$0.source.isEmpty && !$0.target.isEmpty }
            return file
        } catch {
            quarantine(reason: "decode_failed")
            return nil
        }
    }

    func save(_ file: GlossaryFile) throws {
        var payload = file
        payload.updatedAt = Timestamp.iso8601Ms()
        let data = try FileIO.encoder.encode(payload)
        try ensureDirectory()
        try FileIO.atomicWrite(data, to: url, permissions: 0o600)
    }

    // MARK: 导入 / 导出

    /// 导出纯 `{原文:译文}`（与 MTool 的人工译文同构，便于外部工具处理）。
    func export(_ glossary: Glossary, to target: URL) throws {
        var map: [String: String] = [:]
        for entry in glossary.all {
            // keepAsIs 也导出（HP: HP）：否则导出→导入一轮就丢了保留词。
            map[entry.source] = entry.keepAsIs ? entry.source : entry.target
        }
        let data = try JSONSerialization.data(
            withJSONObject: map,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileIO.atomicWrite(data, to: target, permissions: 0o644)
    }

    /// 导入 `{原文:译文}` 或 `{version, entries:[...]}`；导入的一律标成 `user` + `locked`。
    /// - Returns: 实际接受的条数。
    @discardableResult
    func importFile(from source: URL, into glossary: inout Glossary) throws -> Int {
        guard let data = FileIO.readData(source) else {
            throw MochiBoxError(code: .ioError, message: "无法读取术语表：\(source.lastPathComponent)")
        }
        var pairs: [(String, String)] = []
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let map = object as? [String: String] {
            pairs = map.map { ($0.key, $0.value) }
        } else if let file = try? FileIO.decoder.decode(GlossaryFile.self, from: data) {
            pairs = file.entries.map { ($0.source, $0.target) }
        } else {
            throw MochiBoxError(code: .ioError, message: "术语表格式不支持（需要 {原文:译文}）")
        }
        var accepted = 0
        for (rawSource, rawTarget) in pairs {
            let sourceText = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetText = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceText.isEmpty, !targetText.isEmpty else { continue }
            let keepAsIs = GlossaryKey.normalize(sourceText) == GlossaryKey.normalize(targetText)
            glossary.upsert(GlossaryEntry(
                source: sourceText,
                target: keepAsIs ? sourceText : targetText,
                kind: .user,
                locked: true,
                keepAsIs: keepAsIs,
                edited: true
            ))
            accepted += 1
        }
        return accepted
    }

    // MARK: 私有

    private func ensureDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func quarantine(reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = directory.appendingPathComponent("\(gameHash).\(reason)-\(stamp).corrupt")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            log?.warn("GlossaryStore", "术语表损坏，已隔离", ["reason": reason, "to": target.lastPathComponent])
        } catch {
            log?.warn("GlossaryStore", "术语表损坏且无法隔离", ["reason": reason])
        }
    }
}
