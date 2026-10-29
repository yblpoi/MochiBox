//
//  CheatModels.swift
//  MochiBox
//
//  V0.6 修改器的值模型（docs/architecture-v0.6-cheat-and-fulltext.md §3 / §5）。
//  只描述"Agent 回什么"，不含任何调用逻辑；调用在 `CheatController`。
//
//  **解码一律宽容**：Agent 侧是游戏内的运行时对象（半初始化、插件改写过数据表都可能
//  让字段缺失或类型漂移）。一个字段认不出来不该让整个面板变空白 —— 缺省值 + 其余字段
//  照常展示，比"抛 decodingError 然后什么都不显示"有用得多。
//
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

// MARK: - 物品/装备种类

/// `cheat.listItems` / `giveItem` / `setItemCount` 的 `kind`。
///
/// 比契约 §3.1 多了 `skill` / `state`：Agent 的 `dataTableOf` 认这两个（技能书、状态
/// 附魔类插件会用到），Host 不暴露就等于把已经实现的能力藏起来。
enum CheatItemKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case item
    case weapon
    case armor
    case skill
    case state

    var id: String { rawValue }

    var uiLabel: String {
        switch self {
        case .item: return "道具"
        case .weapon: return "武器"
        case .armor: return "护甲"
        case .skill: return "技能"
        case .state: return "状态"
        }
    }
}

// MARK: - 快照

struct CheatPlayer: Codable, Sendable, Equatable {
    var x: Int
    var y: Int
    var dir: Int
    var through: Bool

    init(x: Int = 0, y: Int = 0, dir: Int = 2, through: Bool = false) {
        self.x = x
        self.y = y
        self.dir = dir
        self.through = through
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.x = c.tolerantValue(Int.self, forKey: .x, 0)
        self.y = c.tolerantValue(Int.self, forKey: .y, 0)
        self.dir = c.tolerantValue(Int.self, forKey: .dir, 2)
        self.through = c.tolerantValue(Bool.self, forKey: .through, false)
    }

    /// 方向 → 中文（报表/日志用，UI 可自行格式化）。
    var directionLabel: String {
        switch dir {
        case 2: return "下"
        case 4: return "左"
        case 6: return "右"
        case 8: return "上"
        default: return "\(dir)"
        }
    }
}

struct CheatPartyMember: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var level: Int
    var hp: Int
    var mhp: Int
    var mp: Int
    var mmp: Int

    init(id: Int = 0, name: String = "", level: Int = 1, hp: Int = 0, mhp: Int = 0, mp: Int = 0, mmp: Int = 0) {
        self.id = id
        self.name = name
        self.level = level
        self.hp = hp
        self.mhp = mhp
        self.mp = mp
        self.mmp = mmp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.level = c.tolerantValue(Int.self, forKey: .level, 1)
        self.hp = c.tolerantValue(Int.self, forKey: .hp, 0)
        self.mhp = c.tolerantValue(Int.self, forKey: .mhp, 0)
        self.mp = c.tolerantValue(Int.self, forKey: .mp, 0)
        self.mmp = c.tolerantValue(Int.self, forKey: .mmp, 0)
    }
}

struct CheatSnapshot: Codable, Sendable, Equatable {
    var scene: String
    var mapId: Int
    var mapName: String
    var gold: Int
    var frames: Int
    /// 变速倍率（1 = 原速）。
    var speed: Double
    /// Agent 侧的无敌开关状态（`cheat.godMode` 的镜像；只读）。
    var godMode: Bool
    var player: CheatPlayer?
    var party: [CheatPartyMember]

    init(
        scene: String = "",
        mapId: Int = 0,
        mapName: String = "",
        gold: Int = 0,
        frames: Int = 0,
        speed: Double = 1,
        godMode: Bool = false,
        player: CheatPlayer? = nil,
        party: [CheatPartyMember] = []
    ) {
        self.scene = scene
        self.mapId = mapId
        self.mapName = mapName
        self.gold = gold
        self.frames = frames
        self.speed = speed
        self.godMode = godMode
        self.player = player
        self.party = party
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scene = c.tolerantValue(String.self, forKey: .scene, "")
        self.mapId = c.tolerantValue(Int.self, forKey: .mapId, 0)
        self.mapName = c.tolerantValue(String.self, forKey: .mapName, "")
        self.gold = c.tolerantValue(Int.self, forKey: .gold, 0)
        self.frames = c.tolerantValue(Int.self, forKey: .frames, 0)
        self.speed = c.tolerantValue(Double.self, forKey: .speed, 1)
        self.godMode = c.tolerantValue(Bool.self, forKey: .godMode, false)
        self.player = c.tolerantOptional(CheatPlayer.self, forKey: .player)
        self.party = c.tolerantValue([CheatPartyMember].self, forKey: .party, [])
    }

    /// `Scene_Map · 地图 12 起始村`（UI 顶部一行摘要）。
    var placeLabel: String {
        var parts: [String] = []
        if !scene.isEmpty { parts.append(scene) }
        if mapId > 0 {
            parts.append(mapName.isEmpty ? "地图 \(mapId)" : "地图 \(mapId) \(mapName)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 变量 / 开关

struct CheatVariable: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    /// `$dataSystem.variables[id]`（Agent 在 V0.6 起一并回传）。
    var name: String
    /// 值可以是数字/字符串/布尔/数组/对象，原样保留。
    var value: JSONValue

    init(id: Int, name: String = "", value: JSONValue = .null) {
        self.id = id
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.value = c.tolerantValue(JSONValue.self, forKey: .value, .null)
    }

    var displayName: String {
        return name.isEmpty ? "#\(id)" : "#\(id) \(name)"
    }
}

struct CheatSwitch: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var value: Bool

    init(id: Int, name: String = "", value: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.value = c.tolerantValue(Bool.self, forKey: .value, false)
    }

    var displayName: String {
        return name.isEmpty ? "#\(id)" : "#\(id) \(name)"
    }
}

// MARK: - 物品 / 角色 / 事件

struct CheatItem: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var kind: CheatItemKind
    var name: String
    var description: String
    var iconIndex: Int
    var price: Int
    var count: Int

    init(
        id: Int,
        kind: CheatItemKind = .item,
        name: String = "",
        description: String = "",
        iconIndex: Int = 0,
        price: Int = 0,
        count: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
        self.iconIndex = iconIndex
        self.price = price
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        let rawKind = c.tolerantValue(String.self, forKey: .kind, CheatItemKind.item.rawValue)
        self.kind = CheatItemKind(rawValue: rawKind) ?? .item
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.description = c.tolerantValue(String.self, forKey: .description, "")
        self.iconIndex = c.tolerantValue(Int.self, forKey: .iconIndex, 0)
        self.price = c.tolerantValue(Int.self, forKey: .price, 0)
        self.count = c.tolerantValue(Int.self, forKey: .count, 0)
    }

    var displayName: String {
        return name.isEmpty ? "\(kind.uiLabel) #\(id)" : name
    }
}

struct CheatEquip: Codable, Sendable, Equatable {
    var slotId: Int
    var id: Int
    var name: String

    init(slotId: Int, id: Int, name: String = "") {
        self.slotId = slotId
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.slotId = c.tolerantValue(Int.self, forKey: .slotId, 0)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
    }
}

struct CheatStateRef: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String

    init(id: Int, name: String = "") {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
    }
}

struct CheatActor: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var nickname: String
    var classId: Int
    var className: String
    var level: Int
    var exp: Int
    var hp: Int
    var mhp: Int
    var mp: Int
    var mmp: Int
    var tp: Int
    /// 8 项基础能力值（MHP/MMP/ATK/DEF/MAT/MDF/AGI/LUK）。
    var params: [Int]
    /// 按槽位排列；空槽为 `nil`（Agent 用 `null` 表示）。
    var equips: [CheatEquip?]
    var states: [CheatStateRef]

    init(
        id: Int,
        name: String = "",
        nickname: String = "",
        classId: Int = 0,
        className: String = "",
        level: Int = 1,
        exp: Int = 0,
        hp: Int = 0,
        mhp: Int = 0,
        mp: Int = 0,
        mmp: Int = 0,
        tp: Int = 0,
        params: [Int] = [],
        equips: [CheatEquip?] = [],
        states: [CheatStateRef] = []
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.classId = classId
        self.className = className
        self.level = level
        self.exp = exp
        self.hp = hp
        self.mhp = mhp
        self.mp = mp
        self.mmp = mmp
        self.tp = tp
        self.params = params
        self.equips = equips
        self.states = states
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.nickname = c.tolerantValue(String.self, forKey: .nickname, "")
        self.classId = c.tolerantValue(Int.self, forKey: .classId, 0)
        self.className = c.tolerantValue(String.self, forKey: .className, "")
        self.level = c.tolerantValue(Int.self, forKey: .level, 1)
        self.exp = c.tolerantValue(Int.self, forKey: .exp, 0)
        self.hp = c.tolerantValue(Int.self, forKey: .hp, 0)
        self.mhp = c.tolerantValue(Int.self, forKey: .mhp, 0)
        self.mp = c.tolerantValue(Int.self, forKey: .mp, 0)
        self.mmp = c.tolerantValue(Int.self, forKey: .mmp, 0)
        self.tp = c.tolerantValue(Int.self, forKey: .tp, 0)
        self.params = c.tolerantValue([Int].self, forKey: .params, [])
        let equips = c.tolerantOptional([CheatEquip?].self, forKey: .equips) ?? []
        self.equips = equips
        self.states = c.tolerantValue([CheatStateRef].self, forKey: .states, [])
    }

    var displayName: String {
        return nickname.isEmpty ? name : "\(name)（\(nickname)）"
    }
}

/// `cheat.updateActor` 的部分更新载荷（`nil` = 不动该字段）。
struct CheatActorPatch: Sendable, Equatable {
    var level: Int?
    var exp: Int?
    var hp: Int?
    var mp: Int?
    var tp: Int?
    var nickname: String?
    var classId: Int?
    var params: [Int]?
    var states: [Int]?
    var equips: [CheatEquipSlot]?

    init(
        level: Int? = nil,
        exp: Int? = nil,
        hp: Int? = nil,
        mp: Int? = nil,
        tp: Int? = nil,
        nickname: String? = nil,
        classId: Int? = nil,
        params: [Int]? = nil,
        states: [Int]? = nil,
        equips: [CheatEquipSlot]? = nil
    ) {
        self.level = level
        self.exp = exp
        self.hp = hp
        self.mp = mp
        self.tp = tp
        self.nickname = nickname
        self.classId = classId
        self.params = params
        self.states = states
        self.equips = equips
    }

    var isEmpty: Bool {
        return level == nil && exp == nil && hp == nil && mp == nil && tp == nil
            && nickname == nil && classId == nil && params == nil
            && states == nil && equips == nil
    }
}

/// 装备槽写入（`itemId == nil` 表示卸下）。
struct CheatEquipSlot: Codable, Sendable, Equatable {
    var slotId: Int
    var kind: CheatItemKind
    var itemId: Int?

    init(slotId: Int, kind: CheatItemKind = .weapon, itemId: Int? = nil) {
        self.slotId = slotId
        self.kind = kind
        self.itemId = itemId
    }
}

struct CheatMapEvent: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var x: Int
    var y: Int
    var note: String

    init(id: Int, name: String = "", x: Int = 0, y: Int = 0, note: String = "") {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(Int.self, forKey: .id, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.x = c.tolerantValue(Int.self, forKey: .x, 0)
        self.y = c.tolerantValue(Int.self, forKey: .y, 0)
        self.note = c.tolerantValue(String.self, forKey: .note, "")
    }
}

struct TransferPoint: Codable, Sendable, Equatable, Identifiable {
    var mapId: Int
    var mapName: String
    var eventId: Int
    var name: String
    var x: Int
    var y: Int
    /// Agent 目前只产出 `event`（命令码 201 或 `<TP>` 注释命中）。
    var kind: String

    init(
        mapId: Int,
        mapName: String = "",
        eventId: Int,
        name: String = "",
        x: Int = 0,
        y: Int = 0,
        kind: String = "event"
    ) {
        self.mapId = mapId
        self.mapName = mapName
        self.eventId = eventId
        self.name = name
        self.x = x
        self.y = y
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mapId = c.tolerantValue(Int.self, forKey: .mapId, 0)
        self.mapName = c.tolerantValue(String.self, forKey: .mapName, "")
        self.eventId = c.tolerantValue(Int.self, forKey: .eventId, 0)
        self.name = c.tolerantValue(String.self, forKey: .name, "")
        self.x = c.tolerantValue(Int.self, forKey: .x, 0)
        self.y = c.tolerantValue(Int.self, forKey: .y, 0)
        self.kind = c.tolerantValue(String.self, forKey: .kind, "event")
    }

    /// 同一事件在不同地图上会重名，`mapId/eventId` 才是身份。
    var id: String { "\(mapId)/\(eventId)" }

    var displayName: String {
        let base = name.isEmpty ? "事件 #\(eventId)" : name
        return mapName.isEmpty ? base : "\(mapName)：\(base)"
    }
}

/// `cheat.objectPath` 的返回值（受控的任意对象读取）。
struct CheatObjectValue: Codable, Sendable, Equatable {
    var path: String
    /// JS `typeof` 的结果（`number` / `object` / `undefined` …）。
    var type: String
    var value: JSONValue

    init(path: String, type: String = "", value: JSONValue = .null) {
        self.path = path
        self.type = type
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = c.tolerantValue(String.self, forKey: .path, "")
        self.type = c.tolerantValue(String.self, forKey: .type, "")
        self.value = c.tolerantValue(JSONValue.self, forKey: .value, .null)
    }
}

// MARK: - 枚举参数（避免 UI 传字符串）

/// `cheat.battle` 的 `op`。
enum CheatBattleOp: String, Codable, Sendable, CaseIterable, Identifiable {
    case win
    case escape
    case killAll
    case lose

    var id: String { rawValue }

    var uiLabel: String {
        switch self {
        case .win: return "战斗胜利"
        case .escape: return "逃跑"
        case .killAll: return "秒杀敌群"
        case .lose: return "强制战败"
        }
    }

    var isDestructive: Bool { return self == .lose }
}

/// `cheat.scene` 的 `name`（Agent 侧映射到 `Scene_*` 构造器）。
enum CheatSceneName: String, Codable, Sendable, CaseIterable, Identifiable {
    case menu
    case save
    case load
    case options
    case status
    case equip
    case skill
    case item
    case formation
    case debug
    case title
    case map
    case gameover
    case shop

    var id: String { rawValue }

    var uiLabel: String {
        switch self {
        case .menu: return "菜单"
        case .save: return "存档"
        case .load: return "读档"
        case .options: return "设置"
        case .status: return "状态"
        case .equip: return "装备"
        case .skill: return "技能"
        case .item: return "物品"
        case .formation: return "编队"
        case .debug: return "调试"
        case .title: return "标题"
        case .map: return "地图"
        case .gameover: return "Game Over"
        case .shop: return "商店"
        }
    }
}
