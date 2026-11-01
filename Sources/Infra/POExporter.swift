//
//  POExporter.swift
//  MochiBox
//
//  EasyRPG Player 的 gettext 翻译导出：把 LCF 语料写成 <root>/<LANG>/ 下的
//  meta.ini + PO 文件，运行时由 Player 在内存里替换文本，零写盘。
//
//  格式与行为全部以 Player 的 src/translation.cpp 为准（master 497a87ba；0.8.1 同一套）：
//
//  1) 目录与文件名
//       <root>/<LANG>/meta.ini
//       <root>/<LANG>/rpg_rt.ldb.po         数据库字段
//       <root>/<LANG>/rpg_rt.ldb.common.po  公共事件消息
//       <root>/<LANG>/rpg_rt.ldb.battle.po  敌群（troop）事件消息
//       <root>/<LANG>/rpg_rt.lmt.po         地图树名称
//       <root>/<LANG>/Map%04d.po            每张地图（编号取 LMT 里的 map ID，不是文件名序号）
//     "default" 是保留目录名（游戏原始语言），不能拿来当我们的语言目录。
//
//  2) meta.ini 是 [Language] 段，不是顶层键：写在顶层会被静默忽略、全部走默认值。
//
//  3) 数据库字段用 msgctxt，**不带下标**：actors[0].name -> actors.name。
//     实测 0.8.1 的 RewriteDatabase 先试索引形态（"actors.1.name"）再试非索引形态，
//     但索引分支的闸门是 ctxt.index >= 0 —— scalar 字段的 ctxt.index 恒为 -1，
//     所以索引形态一条都查不到；**非索引才是唯一生效的键**。
//     Player 只处理一层深（父上下文的父上下文必须为空），三层以上只能靠空 msgctxt 兜底。
//
//  4) 消息的 msgid 是**整条对话框**：10110 的 string + 紧随的 20110 用 \n 连起来、
//     结尾不留 \n、最多 4 行。拼接在 shim 里做（要看 code，Swift 侧看不到）。
//     注意真实码是 10110/20110，不是 RGSS 的 101/401。
//
//  5) PO 转义只认三种：反斜杠、\n、双引号。其它反斜杠转义会让 Player 的解析器
//     直接 Output::Error 中止整个文件。所以正文里的 \c[3] 必须写成 \\c[3]。
//
//  6) 匹配是逐字节精确比较，失配没有任何 warning —— 那条就是不翻译。
//     所以本文件写完每个 PO 都会**回读校验**（用同一套解析规则反解，逐条比对
//     msgctxt/msgid），不一致直接抛错。这是这条链路唯一的安全网。
//
//  本文件不得 import SwiftUI / AppKit（Scripts/build.sh 的分层门禁）。
//

#if !MOCHI_NO_LCF

import Foundation

struct POExportOptions {
    /// 语言目录名，如 "zh_CN"（不能是保留字 "default"）。
    var languageID: String
    /// meta.ini 的 Name（游戏内语言选择里显示的名字）。
    var languageName: String
    /// meta.ini 的 Code（语言代码，如 zh_CN）。
    var languageCode: String
    /// meta.ini 的 GameTitle。
    var gameTitle: String
    var languageTerm: String = "Language"
    var languageDescription: String = ""
    /// "builtin" 表示用 Player 内置字体。
    var font: String = "builtin"
    var projectName: String = "MochiBox"
}

struct POExportSummary: Equatable {
    /// 文件名 -> 条目数（只含真正写出的文件）。
    var entriesByFile: [String: Int] = [:]

    var totalEntries: Int { entriesByFile.values.reduce(0, +) }
}

enum POExportError: Error, LocalizedError, CustomStringConvertible {
    case readBackMismatch(String)
    case badPO(String)
    case writeFailed(String)

    var code: String {
        switch self {
        case .readBackMismatch: return "po_readback_mismatch"
        case .badPO: return "po_parse_failed"
        case .writeFailed: return "po_write_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .readBackMismatch(detail):
            return "PO 回读校验失败（写进去的 msgid 没能原样读回来）：\(detail)"
        case let .badPO(detail):
            return "PO 解析失败：\(detail)"
        case let .writeFailed(path):
            return "PO 写入失败：\(path)"
        }
    }

    var description: String { "POExportError(\(code)): \(errorDescription ?? "")" }
}

/// PO 里的一条（回读校验与测试用）。
struct POEntry: Equatable {
    var context: String
    var id: String
    var str: String
}

enum POExporter {

    static let databaseFile = "rpg_rt.ldb.po"
    static let commonFile = "rpg_rt.ldb.common.po"
    static let battleFile = "rpg_rt.ldb.battle.po"
    static let treeFile = "rpg_rt.lmt.po"

    // MARK: - 导出

    /// 写 meta.ini + 数据库的三个 PO（rpg_rt.ldb.po / .common.po / .battle.po）。
    ///
    /// translations 的键是**解码后的原文**（与 msgid 同一形态），值是译文；
    /// 没有译文、或译文为空的条目不写入（引擎缺文件是安全的，缺条目就等于不翻）。
    static func exportDatabase(
        _ db: LCFDatabase,
        translations: [String: String],
        to root: URL,
        options: POExportOptions
    ) throws -> POExportSummary {
        let languageDirectory = root.appendingPathComponent(options.languageID, isDirectory: true)
        try FileManager.default.createDirectory(at: languageDirectory, withIntermediateDirectories: true)
        try writeMeta(to: languageDirectory, options: options)

        var database: [POEntry] = []
        var common: [POEntry] = []
        var battle: [POEntry] = []

        // 逐字段：跳过公共事件 / 敌群事件里的指令文本 —— 那些必须以"整条消息"出现，
        // 单条指令的 string 在引擎的字典里查不到（会静默不翻）。
        for entry in db.allStrings() {
            if entry.path.hasPrefix("commonevents[") || entry.path.hasPrefix("troops[") { continue }
            let original = try LCFTextCodec.decode(entry.raw).text
            guard !original.isEmpty, let translated = translations[original], !translated.isEmpty else { continue }
            database.append(POEntry(context: context(for: entry.path), id: original, str: translated))
        }

        // 逐消息：msgid 是整条对话框（shim 已按 10110+20110 拼好）。
        for message in db.allMessages() {
            let original = try LCFTextCodec.decode(message.raw).text
            guard !original.isEmpty, let translated = translations[original], !translated.isEmpty else { continue }
            let entry = POEntry(context: "", id: original, str: translated)
            if message.path.hasPrefix("commonevents[") { common.append(entry) } else { battle.append(entry) }
        }

        var summary = POExportSummary()
        try write(entries: database, name: databaseFile, to: languageDirectory, options: options, summary: &summary)
        try write(entries: common, name: commonFile, to: languageDirectory, options: options, summary: &summary)
        try write(entries: battle, name: battleFile, to: languageDirectory, options: options, summary: &summary)
        return summary
    }

    /// 写 rpg_rt.lmt.po（地图树里的地图名）。
    static func exportMapTree(
        _ tree: LCFMapTreeInfo,
        translations: [String: String],
        to root: URL,
        options: POExportOptions
    ) throws -> POExportSummary {
        let languageDirectory = root.appendingPathComponent(options.languageID, isDirectory: true)
        try FileManager.default.createDirectory(at: languageDirectory, withIntermediateDirectories: true)

        var entries: [POEntry] = []
        for item in tree.strings {
            let original = try LCFTextCodec.decode(item.raw).text
            guard !original.isEmpty, let translated = translations[original], !translated.isEmpty else { continue }
            entries.append(POEntry(context: context(for: item.path), id: original, str: translated))
        }

        var summary = POExportSummary()
        try write(entries: entries, name: treeFile, to: languageDirectory, options: options, summary: &summary)
        return summary
    }

    /// 写每张地图一个 Map%04d.po。id 必须来自 LMT 的 map ID（引擎按运行时进图 id 查文件），
    /// 不是 LMU 的文件名序号 —— 两者不一致时拿文件名序号会整张图不生效。
    static func exportMaps(
        _ maps: [(id: Int, file: LCFMapFile)],
        translations: [String: String],
        to root: URL,
        options: POExportOptions
    ) throws -> POExportSummary {
        let languageDirectory = root.appendingPathComponent(options.languageID, isDirectory: true)
        try FileManager.default.createDirectory(at: languageDirectory, withIntermediateDirectories: true)

        var summary = POExportSummary()
        for (id, file) in maps {
            var entries: [POEntry] = []
            for message in file.allMessages() {
                let original = try LCFTextCodec.decode(message.raw).text
                guard !original.isEmpty, let translated = translations[original], !translated.isEmpty else { continue }
                entries.append(POEntry(context: "", id: original, str: translated))
            }
            let name = String(format: "Map%04d.po", id)
            try write(entries: entries, name: name, to: languageDirectory, options: options, summary: &summary)
        }
        return summary
    }

    // MARK: - msgctxt

    /// actors[0].name -> actors.name；system.title_name -> system.title_name。
    ///
    /// **不带下标**，这是实测口径而不是风格选择：EasyRPG 0.8.1 的 RewriteDatabase
    /// 只在 `ctxt.index >= 0` 时才查索引形态（"actors.1.name"），而 scalar 字段的
    /// ctxt.index 恒为 -1 —— 索引分支根本不进。写了也是死条目，只让 PO 变大。
    ///
    /// 代价：同一句原文只有一种译法，不能按槽位区分（actors[0].name 与 actors[1].name
    /// 同原文时只能共用一条译文）。actors/items 的原文天然能区分，可以接受。
    ///
    /// 只处理**一层深**：Player 的 sys 查表会跳过 parent->parent 不为空的上下文，
    /// 三层以上（如 system.terms.basic[0]）只能落空 msgctxt 兜底，所以这里返回 ""。
    static func context(for path: String) -> String {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return "" }
        let parent = parts[0]
        let field = parts[1]
        // 没有下标的父级（terms.command_item / system.title_name）原样保留。
        guard parent.hasSuffix("]"), let open = parent.lastIndex(of: "[") else {
            return parent + "." + field
        }
        let name = String(parent[parent.startIndex..<open])
        return name + "." + field
    }

    // MARK: - 写文件

    static func escape(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"   // 反斜杠
            case 0x0A: out += "\\n"      // 换行
            case 0x22: out += "\\\""   // 双引号
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func write(
        entries: [POEntry],
        name: String,
        to directory: URL,
        options: POExportOptions,
        summary: inout POExportSummary
    ) throws {
        let unique = dedupe(entries)
        guard !unique.isEmpty else { return }
        let text = render(unique, options: options)
        let url = directory.appendingPathComponent(name)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw POExportError.writeFailed(url.path)
        }
        // 回读校验：写完立刻按引擎规则反解一遍，逐条比对 msgctxt/msgid。
        try verify(text, expected: unique)
        summary.entriesByFile[name] = unique.count
    }

    private static func dedupe(_ entries: [POEntry]) -> [POEntry] {
        var seen = Set<String>()
        var out: [POEntry] = []
        for entry in entries {
            let key = entry.context + "\u{1}" + entry.id
            if seen.insert(key).inserted { out.append(entry) }
        }
        return out
    }

    private static func render(_ entries: [POEntry], options: POExportOptions) -> String {
        var lines: [String] = []
        // 标准 PO 头：第一条 msgstr 之前的内容引擎会整段丢弃，所以写在这里是安全的。
        lines.append("msgid \"\"")
        lines.append("msgstr \"\"")
        lines.append("\"Project-Id-Version: " + escape(options.projectName) + "\\n\"")
        lines.append("\"Content-Type: text/plain; charset=UTF-8\\n\"")
        lines.append("\"Language: " + escape(options.languageCode) + "\\n\"")
        lines.append("\"Plural-Forms: nplurals=1; plural=0;\\n\"")
        lines.append("")
        for entry in entries {
            if !entry.context.isEmpty {
                lines.append("msgctxt \"" + escape(entry.context) + "\"")
            }
            lines.append("msgid \"" + escape(entry.id) + "\"")
            lines.append("msgstr \"" + escape(entry.str) + "\"")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func writeMeta(to directory: URL, options: POExportOptions) throws {
        let lines = [
            "[Language]",
            "Name=" + options.languageName,
            "Description=" + options.languageDescription,
            "Code=" + options.languageCode,
            "Term=" + options.languageTerm,
            "GameTitle=" + options.gameTitle,
            "Font=" + options.font,
        ]
        let url = directory.appendingPathComponent("meta.ini")
        do {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        } catch {
            throw POExportError.writeFailed(url.path)
        }
    }

    // MARK: - 回读

    /// 回读校验：解析出来的 (msgctxt, msgid) 必须与写进去的完全一致（多重集相等）。
    static func verify(_ text: String, expected: [POEntry]) throws {
        let parsed = try parse(text)
        var actual = Set(parsed.map { $0.context + "\u{1}" + $0.id })
        var missing: [String] = []
        for entry in expected {
            let key = entry.context + "\u{1}" + entry.id
            if actual.contains(key) {
                actual.remove(key)
            } else {
                missing.append(key)
            }
        }
        if !missing.isEmpty || !actual.isEmpty {
            let missingText = missing.prefix(3).joined(separator: " | ")
            let extraText = actual.sorted().prefix(3).joined(separator: " | ")
            throw POExportError.readBackMismatch("missing=[" + missingText + "] unexpected=[" + extraText + "]")
        }
    }

    /// 按 Player 的规则解析 PO：只认 msgctxt / msgid / msgstr / 引号续行 / 注释 / 空行，
    /// 只认三种转义（反斜杠、n、双引号）；其它一律报错（引擎那边同样是硬失败）。
    ///
    /// msgid 为空的条目（标准文件头）会被跳过。
    static func parse(_ text: String) throws -> [POEntry] {
        var entries: [POEntry] = []
        var context = ""
        var identifier: String?
        var translation: String?
        var field = 0   // 0=无 1=msgctxt 2=msgid 3=msgstr

        func flush() {
            if let id = identifier, !id.isEmpty {
                entries.append(POEntry(context: context, id: id, str: translation ?? ""))
            }
            context = ""
            identifier = nil
            translation = nil
            field = 0
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                flush()
                continue
            }
            if line.hasPrefix("\"") {
                let value = try unescape(line)
                switch field {
                case 1: context += value
                case 2: identifier = (identifier ?? "") + value
                case 3: translation = (translation ?? "") + value
                default: break   // 第一条 msgstr 之前的文件头，整段丢弃
                }
                continue
            }
            if line.hasPrefix("msgctxt ") {
                if identifier != nil {
                    throw POExportError.badPO("msgctxt 出现在 msgid 之后：" + line)
                }
                context = try unescape(String(line.dropFirst("msgctxt ".count)))
                field = 1
            } else if line.hasPrefix("msgid ") {
                identifier = try unescape(String(line.dropFirst("msgid ".count)))
                field = 2
            } else if line.hasPrefix("msgstr ") {
                translation = try unescape(String(line.dropFirst("msgstr ".count)))
                field = 3
            } else {
                throw POExportError.badPO("无法识别的行：" + line)
            }
        }
        flush()
        return entries
    }

    /// 反解一个带引号的 PO 字符串。
    private static func unescape(_ quoted: String) throws -> String {
        guard quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else {
            throw POExportError.badPO("不是带引号的字符串：" + quoted)
        }
        let inner = quoted.dropFirst().dropLast()
        var out = String()
        out.reserveCapacity(inner.count)
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                out.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                throw POExportError.badPO("字符串以孤立的反斜杠结尾")
            }
            switch escaped {
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "\"": out.append("\"")
            default:
                throw POExportError.badPO("不支持的转义：\\" + String(escaped))
            }
        }
        return out
    }
}

#endif
