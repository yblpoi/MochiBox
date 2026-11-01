//
//  RGBSGameFile.swift
//  MochiBox
//
//  按文件名派发 RGSS 数据文件，并把"解析 / 取文本 / 写回"包成 RGSSDocument。
//
//  文件 -> 版本（按扩展名，最可靠）：
//    *.rxdata  -> RGSS1 (XP)
//    *.rvdata  -> RGSS2 (VX)
//    *.rvdata2 -> RGSS3 (VX Ace)
//  同一个引擎的 Game.ini 里 Library=RGSS1|RGSS2|RGSS3 也可作为补充证据。
//

import Foundation

enum RGSSVersion: String, CaseIterable {
    case rgss1
    case rgss2
    case rgss3

    /// 实测：RGSS1/2 的字符串无 :E，内容为 CP932；RGSS3 是 UTF-8 + :E => true。
    var defaultEncoding: RGBSTextEncoding {
        switch self {
        case .rgss1, .rgss2: return .shiftJIS
        case .rgss3: return .utf8
        }
    }

    var libraryName: String { rawValue.uppercased() }

    var dataExtensions: [String] {
        switch self {
        case .rgss1: return ["rxdata"]
        case .rgss2: return ["rvdata"]
        case .rgss3: return ["rvdata2"]
        }
    }

    static func fromLibrary(_ name: String) -> RGSSVersion? {
        RGSSVersion(rawValue: name.lowercased())
    }

    static func fromExtension(_ ext: String) -> RGSSVersion? {
        switch ext.lowercased() {
        case "rxdata": return .rgss1
        case "rvdata": return .rgss2
        case "rvdata2": return .rgss3
        default: return nil
        }
    }
}

struct RGBSGameFile {
    enum Kind: Equatable {
        case actors, classes, skills, items, weapons, armors, enemies, states
        case animations, tilesets, troops, commonEvents, system, mapInfos
        case map(Int)
        case scripts
        case other(String)

        /// 提取路径的前缀：数组型数据库用复数文件名。
        var collectionName: String {
            switch self {
            case .actors: return "actors"
            case .classes: return "classes"
            case .skills: return "skills"
            case .items: return "items"
            case .weapons: return "weapons"
            case .armors: return "armors"
            case .enemies: return "enemies"
            case .states: return "states"
            case .animations: return "animations"
            case .tilesets: return "tilesets"
            case .troops: return "troops"
            case .commonEvents: return "common_events"
            case .system: return "system"
            case .mapInfos: return "map_infos"
            case .map(let id): return "maps[\(id)]"
            case .scripts: return "scripts"
            case .other(let name): return name
            }
        }

        var isScripts: Bool { if case .scripts = self { return true }; return false }
    }

    let fileName: String
    let kind: Kind
    let version: RGSSVersion

    /// 按文件名识别。版本默认由扩展名决定，也可显式覆盖（例如 Game.ini 说是 RGSS3）。
    static func detect(fileName: String, version: RGSSVersion? = nil) -> RGBSGameFile? {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let resolvedVersion = version ?? RGSSVersion.fromExtension(ext)
        guard let resolvedVersion else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        let kind: Kind
        switch lower {
        case "actors": kind = .actors
        case "classes": kind = .classes
        case "skills": kind = .skills
        case "items": kind = .items
        case "weapons": kind = .weapons
        case "armors": kind = .armors
        case "enemies": kind = .enemies
        case "states": kind = .states
        case "animations": kind = .animations
        case "tilesets": kind = .tilesets
        case "troops": kind = .troops
        case "commonevents": kind = .commonEvents
        case "system": kind = .system
        case "mapinfos": kind = .mapInfos
        case "scripts": kind = .scripts
        default:
            if lower.hasPrefix("map"), let id = Int(stem.dropFirst(3)) {
                kind = .map(id)
            } else {
                kind = .other(stem)
            }
        }
        return RGBSGameFile(fileName: fileName, kind: kind, version: resolvedVersion)
    }
}

/// 一个已解析的 RGSS 数据文件。
final class RGSSDocument {
    let file: RGBSGameFile
    let root: MarshalValue
    /// 原始字节，用来验证"没改就字节完全相同"。
    let source: Data
    var options: RGBSExtractOptions

    init(parsing data: Data,
         file: RGBSGameFile,
         options: RGBSExtractOptions = RGBSExtractOptions()) throws {
        self.file = file
        self.source = data
        self.options = options
        self.root = try MarshalReader.load(data)
    }

    static func load(url: URL,
                     version: RGSSVersion? = nil,
                     options: RGBSExtractOptions = RGBSExtractOptions()) throws -> RGSSDocument {
        guard let file = RGBSGameFile.detect(fileName: url.lastPathComponent, version: version) else {
            throw MarshalError(kind: .badHeader, offset: 0,
                               detail: "不认识的文件名/扩展名：\(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        return try RGSSDocument(parsing: data, file: file, options: options)
    }

    func textEntries() -> [RGBSTextEntry] {
        RGBSTextExtractor.extract(from: root, file: file, options: options)
    }

    /// 只对文本节点做替换后的整体序列化。未改动时应与 source 逐字节相同。
    func serialize() throws -> Data {
        try MarshalWriter.dump(root)
    }

    /// 往返自检：解析 -> 重新序列化，字节是否完全一致。
    func hasLosslessRoundTrip() throws -> Bool {
        try serialize() == source
    }
}
