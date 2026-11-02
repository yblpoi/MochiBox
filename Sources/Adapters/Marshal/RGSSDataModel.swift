//
//  RGSSDataModel.swift
//  MochiBox
//
//  RGSS 数据的"薄视图"层：不建 15 个完整 struct，只建做文本定位与安全往返
//  所需要的那几个视图。每个视图都只是包着 MarshalValue 的只读投影 ——
//  真正的数据始终是解析出来的那棵对象树，所以视图之间天然共享同一个对象。
//

import Foundation

// MARK: - 通用记录视图

/// RPG::* 对象的字段访问（ivar 名带不带 @ 都认）。
struct RGSSRecordView {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    var className: String { value.className ?? "" }

    /// 字段短名（去掉 @）。
    var fieldNames: [String] {
        (value.record?.ivars ?? []).map { RGSSRecordView.shortName($0.name.name) }
    }

    func raw(_ field: String) -> MarshalValue? { value.ivar(named: field) }

    func string(_ field: String) -> MarshalString? { value.string(named: field) }

    func int(_ field: String) -> Int? {
        guard case .int(let number)? = raw(field)?.kind else { return nil }
        return Int(number)
    }

    func array(_ field: String) -> [MarshalValue]? { raw(field)?.arrayElements }

    func record(_ field: String) -> RGSSRecordView? { raw(field).flatMap(RGSSRecordView.init) }

    static func shortName(_ name: String) -> String {
        name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
}

// MARK: - Table

/// RGSS 的 Table 用 Marshal 的 UserDef（u）表达，_dump 布局：
/// [dim, xsize, ysize, zsize, data.size] 各 32 位小端 + data.size 个 16 位小端。
struct RGBSTableData {
    let dimension: Int
    let xSize: Int
    let ySize: Int
    let zSize: Int
    let values: [Int16]

    init?(dimension: Int, xSize: Int, ySize: Int, zSize: Int, values: [Int16]) {
        guard dimension >= 0, dimension <= 3 else { return nil }
        guard [xSize, ySize, zSize].allSatisfy({ $0 >= 0 && $0 <= 1 << 20 }) else { return nil }
        let expected = RGBSTableData.expectedCount(dimension: dimension, x: xSize, y: ySize, z: zSize)
        guard values.count == expected else { return nil }
        self.dimension = dimension
        self.xSize = xSize
        self.ySize = ySize
        self.zSize = zSize
        self.values = values
    }

    static func expectedCount(dimension: Int, x: Int, y: Int, z: Int) -> Int {
        switch dimension {
        case 0: return 1
        case 1: return x
        case 2: return x * y
        case 3: return x * y * z
        default: return 0
        }
    }

    /// 从 "u" 值解出 Table；其它形态返回 nil（不抛错，调用方按"没有 Table"处理）。
    static func parse(_ value: MarshalValue) -> RGBSTableData? {
        guard case .userDef(let def) = value.kind else { return nil }
        guard def.className.name == "Table" || def.className.name.hasSuffix("::Table") else { return nil }
        let bytes = [UInt8](def.bytes)
        guard bytes.count >= 20 else { return nil }

        func uint32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let dimension = uint32(0)
        let xSize = uint32(4)
        let ySize = uint32(8)
        let zSize = uint32(12)
        let count = uint32(16)
        guard count >= 0, count <= (bytes.count - 20) / 2 else { return nil }
        var values: [Int16] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            let offset = 20 + index * 2
            let raw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            values.append(Int16(bitPattern: raw))
        }
        return RGBSTableData(dimension: dimension, xSize: xSize, ySize: ySize, zSize: zSize, values: values)
    }
}

// MARK: - 事件指令

/// RPG::EventCommand：code / indent / parameters。
struct RGSSEventCommand {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    var code: Int { RGSSRecordView(value)?.int("code") ?? 0 }
    var indent: Int { RGSSRecordView(value)?.int("indent") ?? 0 }
    var parameters: [MarshalValue] { RGSSRecordView(value)?.array("parameters") ?? [] }

    /// 消息窗口的正文指令：101 之外还有 401（文本行）、102/402（选项）、405（滚动文本）。
    static let dialogueCodes: Set<Int> = [101, 401, 102, 402, 405]

    var isDialogue: Bool { RGSSEventCommand.dialogueCodes.contains(code) }
}

/// RPG::Event::Page：只有指令列表与条件分支是我们关心的。
struct RGBSEventPage {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    var commands: [RGSSEventCommand] {
        (RGSSRecordView(value)?.array("list") ?? []).compactMap(RGSSEventCommand.init)
    }
}

/// RPG::Event：id / name / pages。
struct RGBSEvent {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    var id: Int { RGSSRecordView(value)?.int("id") ?? 0 }
    var name: String? { RGSSRecordView(value)?.string("name")?.stringText }
    var pages: [RGBSEventPage] {
        (RGSSRecordView(value)?.array("pages") ?? []).compactMap(RGBSEventPage.init)
    }
}

/// RPG::Map：显示名 + 事件表 + 图块数据。
struct RGSSMapData {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    var displayName: MarshalString? { RGSSRecordView(value)?.string("display_name") }

    var table: RGBSTableData? {
        guard let data = RGSSRecordView(value)?.raw("data") else { return nil }
        return RGBSTableData.parse(data)
    }

    /// 事件按 @events 哈希的键（事件 id）索引。
    var events: [(id: Int, event: RGBSEvent)] {
        guard let pairs = RGSSRecordView(value)?.raw("events")?.hashPairs else { return [] }
        var result: [(id: Int, event: RGBSEvent)] = []
        for pair in pairs {
            guard let event = RGBSEvent(pair.value) else { continue }
            let id: Int
            if case .int(let number) = pair.key.kind { id = Int(number) } else { id = event.id }
            result.append((id: id, event: event))
        }
        return result
    }
}

// MARK: - 记录集合

/// 数据库文件的顶层形态拆包。
///
/// 实测 XP / VX / VX Ace 的 CommonEvents 与 Troops 都是"顶层 Array，索引 0 为 nil、
/// 其余是记录"（不是 VX 才有的结构）。但视图本身只包一条记录 —— 把容器形态
/// 硬塞进 init? 会让单个对象也没法用。所以两种形态都在这里接受，init? 不变。
enum RGSSRecordCollection {
    /// 单条记录 -> 1 条；Array -> 跳过 nil 后的全部记录；其它（nil / 非法根）-> 0 条。
    static func entries<View>(from value: MarshalValue, make: (MarshalValue) -> View?) -> [View] {
        if let elements = value.arrayElements {
            return elements.compactMap(make)
        }
        return make(value).map { [$0] } ?? []
    }
}

/// RPG::CommonEvent：name + list。
struct RGSSCommonEvent {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    /// CommonEvents 文件在 XP/VX/VX Ace 里都是"顶层 Array，索引 0 为 nil"，
    /// 但视图只认单条记录，容器形态由这里拆开。
    static func entries(from value: MarshalValue) -> [RGSSCommonEvent] {
        RGSSRecordCollection.entries(from: value, make: RGSSCommonEvent.init)
    }

    var id: Int { RGSSRecordView(value)?.int("id") ?? 0 }
    var name: String? { RGSSRecordView(value)?.string("name")?.stringText }
    var commands: [RGSSEventCommand] {
        (RGSSRecordView(value)?.array("list") ?? []).compactMap(RGSSEventCommand.init)
    }
}

/// RPG::Troop：name + pages[*].list。
struct RGSSTroop {
    let value: MarshalValue

    init?(_ value: MarshalValue) {
        guard value.record != nil else { return nil }
        self.value = value
    }

    /// Troops 文件同样是顶层 Array（索引 0 为 nil），见 RGSSCommonEvent.entries。
    static func entries(from value: MarshalValue) -> [RGSSTroop] {
        RGSSRecordCollection.entries(from: value, make: RGSSTroop.init)
    }

    var id: Int { RGSSRecordView(value)?.int("id") ?? 0 }
    var name: String? { RGSSRecordView(value)?.string("name")?.stringText }
    var pages: [RGBSEventPage] {
        (RGSSRecordView(value)?.array("pages") ?? []).compactMap(RGBSEventPage.init)
    }
}

extension MarshalString {
    /// 按 UTF-8 宽松解码（视图层只做展示；编码判定走 RGBSTextEncoding）。
    var stringText: String { String(decoding: bytes, as: UTF8.self) }
}
