//
//  FullTextStore.swift
//  MochiBox
//
//  全文译文的持久化（docs/architecture-v0.6-cheat-and-fulltext.md §4.4 / §4.5）。
//
//  位置：`<AppPaths.root>/fulltext/<gameHash>.json`，权限 0600，原子写。
//  为什么不用游戏目录：默认不污染游戏目录（§1 D5）—— 导出是显式动作。
//
//  兼容性：`ManualTransFile.json` 走 MTool 的纯 `{原文:译文}` 格式（§1 D6），
//  便于直接吃现成的人工译文；本文件自己的 JSON 则多带 `segments`（多文本段原文
//  必须有段证据才能安全重组，见 `Segmented` 说明）。
//
//  本文件只 import Foundation（分层门禁）。
//

import Foundation

// MARK: - 文件模型

/// `fulltext/<gameHash>.json` 的落盘形态（§4.4）。
struct FullTextFile: Codable, Sendable, Equatable {
    var version: Int
    var gameHash: String
    var engine: String
    var srcLang: String
    var tgtLang: String
    /// ISO8601（`Timestamp.iso8601Ms`）。
    var updatedAt: String
    /// 原文 → 译文整串（含控制码）。
    var entries: [String: String]
    /// 原文 → 译文分段。**附加字段**（旧版本/外部工具没有它也能读）：
    /// 只有一个文本段的原文可以只靠 `entries` 重组；含 `\C[2]` 之类码值的行必须有段证据。
    var segments: [String: [Segment]]?
    /// 原文 → 译文来源（`machine` / `manual` / `cache`）。**可选**：旧文件没有它，
    /// 加载时按 `.cache` 处理；新写入必须带上，否则「人工译文不被机翻覆盖」
    /// 只在单次会话内成立，一旦做「按术语重翻」就会静默毁掉用户导入的人工译文。
    var origins: [String: String]?
    /// 原文 → 翻译时的 profile（提示词版本 + 类别 + 稳定术语指纹）。
    var profiles: [String: String]?
    /// 原文 → 质量问题标记（`QualityIssue.rawValue`）。
    var issues: [String: [String]]?
    /// 原文 → 文本类别（`TranslationCategory.rawValue`）。
    /// 不落盘的话，重启后不重扫会让所有条目退回对话类别，实时链路每句都 miss。
    var categories: [String: String]?
    var meta: [String: JSONValue]?

    init(
        version: Int = 1,
        gameHash: String,
        engine: String = "mvmz",
        srcLang: String = K.fixedSrcLang,
        tgtLang: String = K.fixedTgtLang,
        updatedAt: String = Timestamp.iso8601Ms(),
        entries: [String: String] = [:],
        segments: [String: [Segment]]? = nil,
        origins: [String: String]? = nil,
        profiles: [String: String]? = nil,
        issues: [String: [String]]? = nil,
        categories: [String: String]? = nil,
        meta: [String: JSONValue]? = nil
    ) {
        self.version = version
        self.gameHash = gameHash
        self.engine = engine
        self.srcLang = srcLang
        self.tgtLang = tgtLang
        self.updatedAt = updatedAt
        self.entries = entries
        self.segments = segments
        self.origins = origins
        self.profiles = profiles
        self.issues = issues
        self.categories = categories
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = c.tolerantValue(Int.self, forKey: .version, 1)
        self.gameHash = c.tolerantValue(String.self, forKey: .gameHash, "")
        self.engine = c.tolerantValue(String.self, forKey: .engine, "mvmz")
        self.srcLang = c.tolerantValue(String.self, forKey: .srcLang, K.fixedSrcLang)
        self.tgtLang = c.tolerantValue(String.self, forKey: .tgtLang, K.fixedTgtLang)
        self.updatedAt = c.tolerantValue(String.self, forKey: .updatedAt, "")
        self.entries = c.tolerantValue([String: String].self, forKey: .entries, [:])
        self.segments = c.tolerantOptional([String: [Segment]].self, forKey: .segments)
        self.origins = c.tolerantOptional([String: String].self, forKey: .origins)
        self.profiles = c.tolerantOptional([String: String].self, forKey: .profiles)
        self.issues = c.tolerantOptional([String: [String]].self, forKey: .issues)
        self.categories = c.tolerantOptional([String: String].self, forKey: .categories)
        self.meta = c.tolerantOptional([String: JSONValue].self, forKey: .meta)
    }
}

// MARK: - 存储

/// 单游戏的全文译文文件。`@unchecked Sendable`：只持有一个不可变的 URL，
/// 所有读写都是 `FileIO` 的原子操作（无跨线程共享可变状态）。
final class FullTextStore: @unchecked Sendable {
    /// `<AppPaths.root>/fulltext`
    let directory: URL
    let gameHash: String
    private let log: SessionLog?

    init(directory: URL, gameHash: String, log: SessionLog? = nil) {
        self.directory = directory
        self.gameHash = gameHash
        self.log = log
    }

    convenience init(paths: AppPaths, gameHash: String, log: SessionLog? = nil) {
        self.init(directory: FullTextStore.defaultDirectory(paths: paths), gameHash: gameHash, log: log)
    }

    /// `<root>/fulltext/`（不依赖 `AppPaths.ensureDirectories`：那条路不建这个目录）。
    static func defaultDirectory(paths: AppPaths = .shared) -> URL {
        return paths.root.appendingPathComponent("fulltext", isDirectory: true)
    }

    var url: URL {
        let name = gameHash.isEmpty ? "unknown" : gameHash
        return directory.appendingPathComponent("\(name).json")
    }

    // MARK: 读写

    /// 读盘。损坏时把原文件改名 `.corrupt` 后返回 nil（§9：不阻塞启动）。
    func load() -> FullTextFile? {
        guard let data = FileIO.readData(url) else { return nil }
        do {
            var file = try FileIO.decoder.decode(FullTextFile.self, from: data)
            if file.gameHash.isEmpty { file.gameHash = gameHash }
            // 内容层面的清理：空原文/空译文不该进入下发路径。
            file.entries = file.entries.filter { !$0.key.isEmpty && !$0.value.isEmpty }
            return file
        } catch {
            quarantine(reason: "decode_failed")
            return nil
        }
    }

    func save(_ file: FullTextFile) throws {
        var payload = file
        payload.updatedAt = Timestamp.iso8601Ms()
        let data = try FileIO.encoder.encode(payload)
        try ensureDirectory()
        try FileIO.atomicWrite(data, to: url, permissions: 0o600)
    }

    /// `fulltext/` 用 0700：里面是用户翻过的全部对话，不需要让同机其它账户读到。
    ///
    /// `createDirectory(attributes:)` 的权限**只作用于新建**：目录已存在时
    /// （旧版本建的 0755、或用户/其它工具手工建的）既不报错也不改权限。
    /// 所以每次 save 都显式 `setAttributes` 确认一次；收紧失败只记日志，
    /// 不阻断保存（P0-19：宁可这次少一层保护，也不能让译文写不下去）。
    private func ensureDirectory() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MochiBoxError(code: .ioError, message: "创建 fulltext 目录失败", underlying: "\(error)")
        }
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            log?.warn("FullTextStore", "fulltext 目录权限收紧到 0700 失败", ["error": "\(error)"])
        }
    }

    /// 把坏文件挪走（保留证据，不静默删除）。
    ///
    /// 备份名精确到秒，同一秒内的第二次损坏顺延 `-2` / `-3`…；**绝不删除**既有
    /// 备份 —— 每一份损坏都要留下独立的原始字节，先删后移会在 `moveItem` 失败时
    /// 连上一份证据一起丢掉。
    private func quarantine(reason: String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        let backup = backupURL()
        do {
            try manager.moveItem(at: url, to: backup)
            log?.warn("FullTextStore", "全文译文文件损坏，已隔离", [
                "reason": reason,
                "backup": backup.lastPathComponent
            ])
        } catch {
            log?.warn("FullTextStore", "全文译文文件损坏且无法隔离", ["reason": reason])
        }
    }

    /// 损坏文件的备份目标：`<gameHash>.json.corrupt-<yyyyMMdd-HHmmss>`，
    /// 同秒重名时顺延 `-2` / `-3`…，不覆盖任何既有备份。
    private func backupURL() -> URL {
        let manager = FileManager.default
        let base = "\(gameHash.isEmpty ? "unknown" : gameHash).json.corrupt-\(Timestamp.fileStamp())"
        var candidate = directory.appendingPathComponent(base)
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index)")
            index += 1
        }
        return candidate
    }

    // MARK: 人工译文（MTool 兼容）

    /// 导出 `{原文: 译文}`（§4.4：MTool 的 `ManualTransFile.json` 格式）。
    static func manualDictionary(from entries: [FullTextEntry]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries {
            guard let translated = entry.translated, !translated.isEmpty else { continue }
            out[entry.raw] = translated
        }
        return out
    }

    /// 写到任意 URL（原子写、0644：导出物是用户的文件，不需要 0600）。
    func exportManual(_ entries: [String: String], to destination: URL) throws {
        let data = try FileIO.encoder.encode(entries)
        try FileIO.atomicWrite(data, to: destination, permissions: 0o644)
    }

    /// 导入 `{原文:译文}`。`原文 == 译文` 视为未译（§4.5）。
    ///
    /// - Parameter existing: 已有译文（用于统计"覆盖了几条"）。
    func importManual(from source: URL, existing: [String: String] = [:]) throws -> (entries: [String: String], result: ManualImportResult) {
        guard let data = FileIO.readData(source) else {
            throw MochiBoxError(code: .ioError, message: "读不到译文文件：\(source.lastPathComponent)")
        }
        let pairs: [String: String]
        do {
            pairs = try FileIO.decoder.decode([String: String].self, from: data)
        } catch {
            throw MochiBoxError(
                code: .badResponse,
                message: "译文文件不是 {原文:译文} 形式的 JSON",
                underlying: "\(error)"
            )
        }
        var accepted: [String: String] = [:]
        var untranslated = 0
        var conflicts = 0
        for (raw, translated) in pairs {
            guard !raw.isEmpty else { continue }
            guard !translated.isEmpty, translated != raw else {
                untranslated += 1
                continue
            }
            if let old = existing[raw], old != translated { conflicts += 1 }
            accepted[raw] = translated
        }
        let result = ManualImportResult(
            accepted: accepted.count,
            total: pairs.count,
            untranslated: untranslated,
            conflicts: conflicts
        )
        log?.info("FullTextStore", "导入了人工译文", [
            "accepted": "\(result.accepted)",
            "untranslated": "\(result.untranslated)",
            "conflicts": "\(result.conflicts)"
        ])
        return (accepted, result)
    }

    /// 导出到游戏目录（显式动作，§4.4）：
    /// `<game>/ManualTransFile.json`（+ 同名 `.bak` 备份，若已存在）。
    func exportToGameDirectory(_ entries: [String: String], gameRoot: URL) throws -> URL {
        let target = gameRoot.appendingPathComponent(FullTextConfig.manualFileName)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            let backup = target.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            try? manager.copyItem(at: target, to: backup)
        }
        let data = try FileIO.encoder.encode(entries)
        try FileIO.atomicWrite(data, to: target, permissions: 0o644)
        log?.info("FullTextStore", "已导出到游戏目录", [
            "path": target.lastPathComponent,
            "entries": "\(entries.count)"
        ])
        return target
    }
}
