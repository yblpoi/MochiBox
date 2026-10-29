//
//  GlossaryModels.swift
//  MochiBox
//
//  术语表与文本类别（V0.7 全文翻译质量）。
//
//  设计要点（docs/architecture-v0.7-glossary.md）：
//  · 术语表只做两件事：**整串命中短路**（不请求模型）与**子串提示注入**（约束模型）。
//    **不做运行时文本替换** —— 中日文没有词边界，替换会把「回復魔法」改成「恢复魔法」之外的怪东西。
//  · 归一化只用于匹配，不改写原文/译文；对外的 source/target 永远保持原样。
//  · 同一原文多译名：保留首次锁定的那条，不静默改（否则跨批一致性反而被破坏）。
//
//  本文件只 import Foundation（Scripts/build.sh 的分层门禁）。
//

import Foundation
import CryptoKit

// MARK: - 文本类别

/// 一条文本在游戏里的用途。决定提示词规则与翻译顺序。
enum TranslationCategory: String, Codable, Sendable, CaseIterable {
    /// `$dataSystem.terms.*` / currencyUnit / 类型名：界面术语。
    case systemTerm
    /// 技能 / 物品 / 武器 / 防具 / 状态 / 敌人 / 角色 / 职业的名字。
    case entityName
    /// 地图名。
    case place
    /// 物品/技能描述、角色简介。
    case description
    /// 事件对话、选项、战斗消息。
    case dialogue
    case other

    /// 从小到大：先翻术语与名称，再翻描述与对话。
    var rank: Int {
        switch self {
        case .systemTerm: return 0
        case .entityName: return 1
        case .place: return 2
        case .description: return 3
        case .dialogue: return 4
        case .other: return 5
        }
    }

    var uiLabel: String {
        switch self {
        case .systemTerm: return "术语"
        case .entityName: return "名称"
        case .place: return "地名"
        case .description: return "描述"
        case .dialogue: return "对话"
        case .other: return "其他"
        }
    }

    /// 单字术语（運/炎/氷）只对系统术语/名称/地名放行；对话里子串误伤太多。
    /// 入队、质量校验、实时重算三处必须共用这一个判断。
    var allowsSingleCharTerms: Bool {
        switch self {
        case .systemTerm, .entityName, .place: return true
        case .description, .dialogue, .other: return false
        }
    }

    /// 注入 system prompt 的类别规则。`nil` = 不加额外规则。
    var promptRule: String? {
        switch self {
        case .systemTerm:
            return "本条是游戏界面术语：对齐 RPG Maker 官方简体中文；HP/MP/TP/EXP/Lv 保留英文原样。"
        case .entityName:
            return "本条是游戏内的名称（技能/物品/状态/角色等）：2–8 字，用玩家惯用的译名；不加解释性括号、不加书名号、结尾不加句号。"
        case .place:
            return "本条是地名：简短、像地名，不加「之地」之类扩写。"
        case .description:
            return "本条是说明文字：保留原句式与省略号，不补主语、不加译者注、不解释术语。"
        case .dialogue, .other:
            return nil
        }
    }

    /// 从扫描条目的 `source` / `path` 推导。无法判断时按对话处理（全文里占比最大）。
    static func inferred(source: String, path: String) -> TranslationCategory {
        if path.hasPrefix("system.terms.") || path == "system.currencyUnit"
            || path.hasPrefix("system.elements") || path.hasPrefix("system.skillTypes")
            || path.hasPrefix("system.weaponTypes") || path.hasPrefix("system.armorTypes")
            || path.hasPrefix("system.equipTypes") {
            return .systemTerm
        }
        if path.hasPrefix("mapInfo.") { return .place }
        if path.hasSuffix(".name") || path.hasSuffix(".nickname") {
            if source == "actor" || source == "class" { return .entityName }
            if source == "skill" || source == "item" || source == "weapon"
                || source == "armor" || source == "state" || source == "enemy" {
                return .entityName
            }
            return .other
        }
        if path.hasSuffix(".description") || path.hasSuffix(".profile") { return .description }
        if source == "map" || source == "common_event" || source == "troop" || source == "runtime" {
            return .dialogue
        }
        return .other
    }
}

// MARK: - 术语

enum GlossaryKind: String, Codable, Sendable {
    case system
    case type
    case asset
    case actor
    case place
    case user

    /// 来源优先级：用户 > 内容名 > 引擎术语 > 导入。
    var priority: Int {
        switch self {
        case .user: return 3
        case .asset, .actor: return 2
        case .system, .type: return 1
        case .place: return 2
        }
    }

    var uiLabel: String {
        switch self {
        case .system: return "系统"
        case .type: return "类型"
        case .asset: return "资产"
        case .actor: return "角色"
        case .place: return "地名"
        case .user: return "自定义"
        }
    }
}

struct GlossaryEntry: Codable, Sendable, Equatable {
    /// 原文（保持原样，不做归一化）。
    var source: String
    /// 锁定译文。`keepAsIs == true` 时与 source 相同，且永不送翻。
    var target: String
    var kind: GlossaryKind
    /// 注入时用「必须」措辞。
    var locked: Bool
    /// HP/MP/TP/EXP/Lv 这类：命中即不翻。
    var keepAsIs: Bool
    /// 人工编辑过；自动学习不得覆盖。
    var edited: Bool

    init(
        source: String,
        target: String,
        kind: GlossaryKind,
        locked: Bool = true,
        keepAsIs: Bool = false,
        edited: Bool = false
    ) {
        self.source = source
        self.target = target
        self.kind = kind
        self.locked = locked
        self.keepAsIs = keepAsIs
        self.edited = edited
    }

    enum CodingKeys: String, CodingKey {
        case source, target, kind, locked, keepAsIs, edited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = c.tolerantValue(String.self, forKey: .source, "")
        self.target = c.tolerantValue(String.self, forKey: .target, "")
        self.kind = GlossaryKind(rawValue: c.tolerantValue(String.self, forKey: .kind, "")) ?? .system
        self.locked = c.tolerantValue(Bool.self, forKey: .locked, true)
        self.keepAsIs = c.tolerantValue(Bool.self, forKey: .keepAsIs, false)
        self.edited = c.tolerantValue(Bool.self, forKey: .edited, false)
    }
}

/// 送给后端的术语对（只保留渲染需要的两个字段）。
struct GlossaryPair: Codable, Sendable, Equatable, Hashable {
    var source: String
    var target: String
}

/// 术语表（值类型：一次快照在整批内保持不变）。
struct Glossary: Sendable, Equatable {
    /// key = `GlossaryKey.normalize(source)`。
    private(set) var entries: [String: GlossaryEntry] = [:]

    init() {}

    init(_ list: [GlossaryEntry]) {
        for entry in list { upsert(entry) }
    }

    var isEmpty: Bool { return entries.isEmpty }
    var count: Int { return entries.count }

    var all: [GlossaryEntry] {
        return entries.values.sorted { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority > rhs.kind.priority }
            return lhs.source.utf8.lexicographicallyPrecedes(rhs.source.utf8)
        }
    }

    func entry(for source: String) -> GlossaryEntry? {
        return entries[GlossaryKey.normalize(source)]
    }

    /// 整串命中。调用方需自行保证「单文本段」——多段条目不可能整串等于一个术语。
    func exact(_ text: String) -> GlossaryEntry? {
        let key = GlossaryKey.normalize(text)
        guard !key.isEmpty else { return nil }
        return entries[key]
    }

    /// 整串命中后真正该显示的文本。
    ///
    /// keepAsIs（HP/MP/LV）必须返回**输入原文**：归一化会 lowercased，
    /// 用 entry.target 回写会把屏幕上的 `LV` 改成 `Lv`。
    func exactOutput(for text: String) -> String? {
        guard let entry = exact(text) else { return nil }
        return entry.keepAsIs ? text : entry.target
    }

    /// 文本里出现过的术语，按原文长度降序（长词优先），最多 `limit` 条。
    ///
    /// - Parameter includeSingleChar: 单字术语（運/炎/氷）。**只对系统术语/名称/地名开放**：
    ///   对话里单字子串命中率太高（「運動」里的「運」），会污染提示。
    /// - 匹配用 NFKC + 小写的 haystack/needle，解决 `最大ＨＰ` 与 `最大HP` 不互命中的问题；
    ///   渲染仍用原串。纯 ASCII 术语要求左右不是字母数字（HP 不命中 HPPotion）。
    func terms(in text: String, limit: Int = 40, includeSingleChar: Bool = false) -> [GlossaryEntry] {
        guard !text.isEmpty else { return [] }
        let haystack = GlossaryKey.matchKey(text)
        guard !haystack.isEmpty else { return [] }
        var hits: [GlossaryEntry] = []
        for entry in entries.values {
            guard !entry.target.isEmpty else { continue }
            let minimum = includeSingleChar ? 1 : 2
            guard entry.source.count >= minimum else { continue }
            let needle = GlossaryKey.matchKey(entry.source)
            guard !needle.isEmpty else { continue }
            if GlossaryKey.contains(haystack, needle) { hits.append(entry) }
        }
        hits.sort { lhs, rhs in
            if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
            return lhs.source.utf8.lexicographicallyPrecedes(rhs.source.utf8)
        }
        if hits.count > limit { hits.removeLast(hits.count - limit) }
        return hits
    }

    /// 本批需要注入的术语对（去重、限量、按字数封顶）。
    func pairs(
        in texts: [String],
        limit: Int = 40,
        maxChars: Int = 1200,
        includeSingleChar: Bool = false
    ) -> [GlossaryPair] {
        var seen: Set<String> = []
        var output: [GlossaryPair] = []
        var chars = 0
        for text in texts {
            for entry in terms(in: text, limit: limit, includeSingleChar: includeSingleChar) {
                // keepAsIs（HP/MP）也要进提示：句子里出现「最大HP」时模型要知道保留缩写。
                guard entry.locked else { continue }
                let key = GlossaryKey.normalize(entry.source)
                guard seen.insert(key).inserted else { continue }
                let cost = entry.source.count + entry.target.count + 6
                if output.count >= limit || chars + cost > maxChars { return output }
                output.append(GlossaryPair(source: entry.source, target: entry.target))
                chars += cost
            }
        }
        return output
    }

    /// 译文里没遵守的锁定术语（只报告，不改写）。
    ///
    /// · `keepAsIs`（HP/MP/LV）：译文里必须仍能看到 source（NFKC 匹配）；
    /// · 其它：译文里必须含 target（`GlossaryKey.contains`：纯 ASCII 术语带词边界）。
    ///
    /// 返回**具体的**术语对（去重、按 source 长度降序，与 `terms(in:)` 同序），
    /// 供「术语违例自动重译」拼强调段；只返回空/非空不足以决定重译什么。
    ///
    /// - Parameter raw: 源文本（调用方传剥码后的 `Segmenter.joinForBackend`，与提示注入同口径）。
    func violations(raw: String, translated: String, category: TranslationCategory) -> [GlossaryPair] {
        guard !isEmpty, !raw.isEmpty else { return [] }
        let haystack = GlossaryKey.matchKey(translated)
        var seen: Set<String> = []
        var output: [GlossaryPair] = []
        for entry in terms(in: raw, includeSingleChar: category.allowsSingleCharTerms) where entry.locked {
            let expected = entry.keepAsIs ? entry.source : entry.target
            guard !expected.isEmpty else { continue }
            if GlossaryKey.contains(haystack, GlossaryKey.matchKey(expected)) { continue }
            guard seen.insert(GlossaryKey.normalize(entry.source)).inserted else { continue }
            output.append(GlossaryPair(source: entry.source, target: expected))
        }
        return output
    }

    /// 插入或覆盖。人工编辑过的条目不会被更低优先级的来源覆盖。
    mutating func upsert(_ entry: GlossaryEntry) {
        let key = GlossaryKey.normalize(entry.source)
        guard !key.isEmpty, !entry.target.isEmpty else { return }
        if let existing = entries[key] {
            if existing.edited && !entry.edited { return }
            if existing.kind.priority > entry.kind.priority && !entry.edited { return }
            if existing.locked && !entry.locked { return }
        }
        entries[key] = entry
    }

    mutating func remove(source: String) {
        entries.removeValue(forKey: GlossaryKey.normalize(source))
    }

    /// 从一条已翻译的语料学习术语；只接受名称/系统术语类条目。
    @discardableResult
    mutating func learn(source: String, target: String, kind: GlossaryKind) -> Bool {
        let key = GlossaryKey.normalize(source)
        guard !key.isEmpty, !target.isEmpty, source.count >= 1 else { return false }
        if let existing = entries[key] {
            if existing.edited { return false }
            // 同名不同译：保留首次锁定的译名，让 termMiss 去暴露不一致。
            return false
        }
        entries[key] = GlossaryEntry(source: source, target: target, kind: kind)
        return true
    }

}

enum GlossaryKey {
    /// NFKC + 全角空格→半角 + 去首尾空白 + 小写。
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.lowercased()
    }

    /// 子串匹配用的键（与 `normalize` 同口径；单独命名是为了让调用点意图明确）。
    static func matchKey(_ text: String) -> String {
        return normalize(text)
    }

    /// 子串命中：纯 ASCII 术语要求左右不是字母数字（`HP` 不命中 `HPPotion`）。
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard let range = haystack.range(of: needle) else { return false }
        let asciiOnly = needle.unicodeScalars.allSatisfy { $0.isASCII }
        guard asciiOnly else { return true }
        if range.lowerBound != haystack.startIndex {
            let previous = haystack[haystack.index(before: range.lowerBound)]
            if previous.isLetter || previous.isNumber { return false }
        }
        if range.upperBound != haystack.endIndex {
            let next = haystack[range.upperBound]
            if next.isLetter || next.isNumber { return false }
        }
        return true
    }
}

// MARK: - 线程安全快照

/// 术语表在「全文控制器（MainActor）」与「实时翻译路径（MainActor）」之间共享。
/// 用锁而不是 actor：读取点都是同步的，且一次批量翻译只需要一个快照。
final class GlossaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Glossary()

    func snapshot() -> Glossary {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ glossary: Glossary) {
        lock.lock()
        value = glossary
        lock.unlock()
    }
}
