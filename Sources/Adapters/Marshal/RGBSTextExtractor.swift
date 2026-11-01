//
//  RGBSTextExtractor.swift
//  MochiBox
//
//  从 RGSS 数据里把"该翻译的字符串"按路径提出来，并给出可写回的句柄。
//
//  路径约定（与 e2e 用例一致）：
//    actors[1].name
//    items[3].description
//    system.terms.elements[0]
//    maps[1].events[2].pages[0].list[5].parameters[0]
//    common_events[3].list[0].parameters[0]
//    troops[1].pages[0].list[2].parameters[0]
//
//  entry.node 指向解析树里的那个字符串对象：同一个对象被两处引用时，两处 entry
//  的 node 是同一个实例 —— 改一处两处都变，写回时自动变成 Marshal 的 @ 链接。
//

import Foundation

enum RGBSTextError: Error, CustomStringConvertible {
    case cannotDecode(path: String, encoding: RGBSTextEncoding)
    case cannotEncode(path: String, encoding: RGBSTextEncoding, text: String)
    case notAString(path: String)

    var description: String {
        switch self {
        case .cannotDecode(let path, let encoding):
            return "RGBSTextError: \(path) 无法按 \(encoding.rawValue) 解码"
        case .cannotEncode(let path, let encoding, let text):
            return "RGBSTextError: \(path) 的新文本 \"\(text)\" 无法编码成 \(encoding.rawValue)"
        case .notAString(let path):
            return "RGBSTextError: \(path) 不是字符串节点"
        }
    }
}

struct RGBSExtractOptions {
    /// nil = 按版本取默认（RGSS1/2 -> CP932，RGSS3 -> UTF-8）。
    var defaultEncoding: RGBSTextEncoding? = nil
    /// 没有 :E / :encoding 声明时，是否用字节启发式再判一次编码。
    var detectEncoding: Bool = true
}

/// 一条可翻译文本。
struct RGBSTextEntry {
    /// 形如 actors[1].name 的定位路径。
    let path: String
    /// 解析树里的字符串节点（同一对象可能被多条 entry 共享）。
    let node: MarshalValue
    let encoding: RGBSTextEncoding
    /// 数据里原有的编码声明（:E => true / :encoding => "Shift_JIS"），没有则 nil。
    let declared: MarshalEncodingIVar?

    var raw: Data { node.stringBytes ?? Data() }
    var text: String? { encoding.decode(raw) }
    var isDecodable: Bool { text != nil }

    /// 写回。默认沿用解析时定下的编码；新文本表达不了会抛错而不是写成问号。
    func setText(_ newText: String, encoding override: RGBSTextEncoding? = nil) throws {
        guard let existing = node.stringValue else {
            throw RGBSTextError.notAString(path: path)
        }
        let target = override ?? encoding
        guard let bytes = target.encode(newText) else {
            throw RGBSTextError.cannotEncode(path: path, encoding: target, text: newText)
        }
        // ivar 形态原样保留：RGSS3 的 :E => true 不能丢，RGSS1/2 也不能凭空多出来。
        node.kind = .string(MarshalString(bytes: bytes, ivars: existing.ivars))
    }
}

enum RGBSTextExtractor {

    /// 数据库记录里值得翻译的字段（不存在的字段自然跳过）。
    static let recordTextFields = [
        "name", "description", "nickname",
        "message1", "message2", "message3", "message4"
    ]

    static func extract(from root: MarshalValue,
                        file: RGBSGameFile,
                        options: RGBSExtractOptions = RGBSExtractOptions()) -> [RGBSTextEntry] {
        let collector = Collector(file: file, options: options)
        collector.run(root: root)
        return collector.entries
    }

    // MARK: - 实现

    private final class Collector {
        let file: RGBSGameFile
        let options: RGBSExtractOptions
        var entries: [RGBSTextEntry] = []
        /// 环检测：Marshal 允许自引用容器，递归前先记一笔。
        private var visiting: Set<ObjectIdentifier> = []

        init(file: RGBSGameFile, options: RGBSExtractOptions) {
            self.file = file
            self.options = options
        }

        var defaultEncoding: RGBSTextEncoding {
            options.defaultEncoding ?? file.version.defaultEncoding
        }

        func run(root: MarshalValue) {
            switch file.kind {
            case .system:
                collectSystem(root)
            case .map(let id):
                collectMap(root, id: id)
            case .commonEvents:
                collectRecordCollection(root, name: "common_events", includeName: true) { value, path in
                    self.collectCommandList(value.ivar(named: "list"), path: path + ".list", depth: 0)
                }
            case .troops:
                collectRecordCollection(root, name: "troops", includeName: true) { value, path in
                    self.collectPageLists(value, path: path, depth: 0)
                }
            case .mapInfos:
                collectRecordCollection(root, name: "map_infos", includeName: true) { _, _ in }
            case .scripts, .other:
                return
            case .actors, .classes, .skills, .items, .weapons, .armors, .enemies, .states,
                 .animations, .tilesets:
                collectRecordCollection(root, name: file.kind.collectionName, includeName: true) { _, _ in }
            }
        }

        // MARK: 编码判定

        private func resolveEncoding(_ string: MarshalString) -> (RGBSTextEncoding, MarshalEncodingIVar?) {
            if let declared = string.encodingIVar {
                switch declared {
                case .flag(true):
                    return (.utf8, declared)      // :E => true = 默认内部编码（RGSS3 即 UTF-8）
                case .flag(false):
                    let guess = options.detectEncoding
                        ? RGBSTextEncoding.detect(string.bytes, preferring: .utf8)
                        : .utf8
                    return (guess, declared)      // :E => false = US-ASCII
                case .named(let name):
                    if let known = RGBSTextEncoding.fromRubyName(name) { return (known, declared) }
                    return (defaultEncoding, declared)
                case .unrecognized:
                    return (defaultEncoding, declared)
                }
            }
            let resolved = options.detectEncoding
                ? RGBSTextEncoding.detect(string.bytes, preferring: defaultEncoding)
                : defaultEncoding
            return (resolved, nil)
        }

        private func add(path: String, value: MarshalValue) {
            guard case .string(let string) = value.kind else { return }
            let (encoding, declared) = resolveEncoding(string)
            entries.append(RGBSTextEntry(path: path, node: value, encoding: encoding, declared: declared))
        }

        // MARK: 数据库记录

        /// 数据库文件既可能是数组（Actors/Items/...），也可能是哈希
        /// （真实的 MapInfos.rxdata 就是 {地图 id => RPG::MapInfo} —— 实测 XP/VX 都是）。
        private func collectRecordCollection(_ root: MarshalValue,
                                            name: String,
                                            includeName: Bool,
                                            extra: (MarshalValue, String) -> Void) {
            if let items = root.arrayElements {
                for (index, item) in items.enumerated() {
                    let path = "\(name)[\(index)]"
                    collectRecordFields(item, path: path)
                    if includeName { extra(item, path) }
                }
                return
            }
            if let pairs = root.hashPairs {
                var fallback = 0
                for pair in pairs {
                    let key: String
                    switch pair.key.kind {
                    case .int(let number): key = "\(number)"
                    case .string(let text): key = String(UnicodeScalar(34)) + text.stringText + String(UnicodeScalar(34))
                    case .symbol(let symbol): key = ":" + symbol.name
                    default: key = "\(fallback)"
                    }
                    fallback += 1
                    let path = "\(name)[\(key)]"
                    collectRecordFields(pair.value, path: path)
                    if includeName { extra(pair.value, path) }
                }
            }
        }

        private func collectRecordFields(_ value: MarshalValue, path: String) {
            guard let record = value.record else { return }
            for ivar in record.ivars {
                let field = RGSSRecordView.shortName(ivar.name.name)
                guard RGBSTextExtractor.recordTextFields.contains(field) else { continue }
                add(path: path + "." + field, value: ivar.value)
            }
        }

        // MARK: System

        private func collectSystem(_ root: MarshalValue) {
            guard let record = root.record else { return }
            for ivar in record.ivars {
                let field = RGSSRecordView.shortName(ivar.name.name)
                switch field {
                case "game_title", "currency_unit":
                    add(path: "system." + field, value: ivar.value)
                case "terms", "words":
                    collectAllStrings(ivar.value, path: "system." + field, depth: 0)
                default:
                    continue
                }
            }
        }

        // MARK: 事件指令

        private func collectPageLists(_ value: MarshalValue, path: String, depth: Int) {
            guard let pages = value.ivar(named: "pages")?.arrayElements else { return }
            for (index, page) in pages.enumerated() {
                collectCommandList(page.ivar(named: "list"),
                                   path: "\(path).pages[\(index)].list",
                                   depth: depth + 1)
            }
        }

        private func collectCommandList(_ value: MarshalValue?, path: String, depth: Int) {
            guard depth < 64, let commands = value?.arrayElements else { return }
            for (index, command) in commands.enumerated() {
                guard let parameters = command.ivar(named: "parameters") else { continue }
                collectAllStrings(parameters,
                                  path: "\(path)[\(index)].parameters",
                                  depth: depth + 1)
            }
        }

        // MARK: Map

        private func collectMap(_ root: MarshalValue, id: Int) {
            let prefix = "maps[\(id)]"
            guard let record = root.record else { return }
            for ivar in record.ivars {
                let field = RGSSRecordView.shortName(ivar.name.name)
                switch field {
                case "display_name":
                    add(path: prefix + ".display_name", value: ivar.value)
                case "events":
                    collectEvents(ivar.value, path: prefix + ".events", depth: 0)
                default:
                    continue
                }
            }
        }

        private func collectEvents(_ value: MarshalValue, path: String, depth: Int) {
            guard depth < 64, let pairs = value.hashPairs else { return }
            guard markVisited(value) else { return }
            defer { unmarkVisited(value) }
            for pair in pairs {
                let eventPath = "\(path)[\(Collector.subscriptKey(pair.key))]"
                collectPageLists(pair.value, path: eventPath, depth: depth + 1)
            }
        }

        // MARK: 递归收集任意层级的字符串

        private func collectAllStrings(_ value: MarshalValue, path: String, depth: Int) {
            guard depth < 64 else { return }
            switch value.kind {
            case .string:
                add(path: path, value: value)
            case .array(let elements):
                guard markVisited(value) else { return }
                defer { unmarkVisited(value) }
                for (index, element) in elements.enumerated() {
                    collectAllStrings(element, path: "\(path)[\(index)]", depth: depth + 1)
                }
            case .hash(let hash):
                guard markVisited(value) else { return }
                defer { unmarkVisited(value) }
                for (index, pair) in hash.pairs.enumerated() {
                    // 键能渲染就用键（system.terms.commands["fight"]），否则退回序号
                    let key = Collector.renderableKey(pair.key) ?? "\(index)"
                    collectAllStrings(pair.value, path: "\(path)[\(key)]", depth: depth + 1)
                }
            case .object(let record):
                guard markVisited(value) else { return }
                defer { unmarkVisited(value) }
                for ivar in record.ivars {
                    let field = RGSSRecordView.shortName(ivar.name.name)
                    collectAllStrings(ivar.value, path: path + "." + field, depth: depth + 1)
                }
            default:
                return
            }
        }

        /// 数组/哈希下标里用的键文本；渲染不出来返回 nil。
        static func renderableKey(_ value: MarshalValue) -> String? {
            switch value.kind {
            case .int(let number): return "\(number)"
            case .string(let text): return "\"" + text.stringText + "\""
            case .symbol(let symbol): return ":" + symbol.name
            default: return nil
            }
        }

        static func subscriptKey(_ value: MarshalValue) -> String {
            renderableKey(value) ?? "?"
        }

        private func markVisited(_ value: MarshalValue) -> Bool {
            visiting.insert(ObjectIdentifier(value)).inserted
        }

        private func unmarkVisited(_ value: MarshalValue) {
            visiting.remove(ObjectIdentifier(value))
        }
    }
}
