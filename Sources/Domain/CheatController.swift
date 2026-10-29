//
//  CheatController.swift
//  MochiBox
//
//  V0.6 修改器面板的宿主侧控制器（docs/architecture-v0.6-cheat-and-fulltext.md §3）。
//
//  定位：**薄封装**。这里不做引擎语义（"金币怎么写"在 Agent 里，§1 D2），只做三件事：
//    1. 参数校验（在发出去之前挡掉明显非法的值，省一次往返）；
//    2. 调用 `AgentRPC`；
//    3. 把错误统一成 `ErrorInfo` + 写操作成功后刷新相关列表。
//
//  **危险操作不做二次确认**（`setObjectPath` / `toggleAllSwitches` / `battle(.lose)`）：
//  确认是 UI 的职责（§6），控制器一旦自己弹窗就无法在 CLI / 自测里复用。
//  但**参数校验一定要有** —— 确认框点"是"之后才被 Agent 拒绝，体验最差。
//

import Foundation
import Combine

@MainActor
final class CheatController: ObservableObject {
    // MARK: - 状态

    @Published private(set) var snapshot: CheatSnapshot?
    @Published private(set) var variables: [CheatVariable] = []
    @Published private(set) var switches: [CheatSwitch] = []
    @Published private(set) var items: [CheatItem] = []
    @Published private(set) var actors: [CheatActor] = []
    @Published private(set) var transferPoints: [TransferPoint] = []
    @Published private(set) var mapEvents: [CheatMapEvent] = []
    @Published private(set) var objectValue: CheatObjectValue?

    /// 最近一次失败（成功调用会清空）。
    @Published private(set) var lastError: ErrorInfo?
    /// 最近一次成功的动作名（UI 可做"已应用"提示）。
    @Published private(set) var lastAction: String = ""
    /// 有请求在飞（UI 用来禁用按钮；并发调用时按计数收敛）。
    @Published private(set) var isBusy: Bool = false
    /// RPC 已接线且引擎是 MV/MZ。
    @Published private(set) var isAvailable: Bool = false

    private var rpc: AgentRPC?
    private var log: SessionLog?
    private var busyCount: Int = 0
    /// 心跳快照是否在飞：防止上一次 `cheat.snapshot` 还没回来就叠下一次。
    private var snapshotInFlight: Bool = false

    init(log: SessionLog? = nil) {
        self.log = log
    }

    // MARK: - 接线

    func attach(rpc: AgentRPC, engine: EngineKind?, log: SessionLog? = nil) {
        self.rpc = rpc
        if let log = log { self.log = log }
        self.isAvailable = (engine == .mv || engine == .mz)
        self.lastError = nil
        self.lastAction = ""
    }

    func detach() {
        rpc = nil
        isAvailable = false
        busyCount = 0
        isBusy = false
        snapshot = nil
        variables = []
        switches = []
        items = []
        actors = []
        transferPoints = []
        mapEvents = []
        objectValue = nil
    }

    /// 会话重新连上（页面重载）后清掉旧快照，避免 UI 显示上一个进程的血条。
    func invalidateSnapshot() {
        snapshot = nil
        objectValue = nil
    }

    // MARK: - 只读

    /// 刷新快照。**心跳路径**（面板每秒一次）必须保持"安静"：
    ///
    /// 1. 不进 `isBusy`：否则所有按钮的禁用态和页脚的转圈每秒亮/灭一次，
    ///    用户看到的就是"作弊面板一直在闪"；
    /// 2. 不重入：上一拍还没回来就跳过这一拍（游戏卡顿时 RPC 可能超过 1s）；
    /// 3. 值没变不赋值：`@Published` 每次赋值都会让整页 body 重算。
    @discardableResult
    func refreshSnapshot() async -> Bool {
        // 心跳正在飞：跳过这一拍，但**不算失败** —— `refreshAll()` 靠这个返回值
        // 决定要不要继续刷新列表，返回 false 会让用户点「刷新全部」直接什么都不做。
        guard !snapshotInFlight else { return true }
        snapshotInFlight = true
        defer { snapshotInFlight = false }
        guard let value = await perform(.snapshot, [:], busy: false) else { return false }
        guard let decoded: CheatSnapshot = decode(value, .snapshot) else { return false }
        if decoded != snapshot { snapshot = decoded }
        return true
    }

    @discardableResult
    func refreshVariables(from: Int = 1, count: Int = 200) async -> Bool {
        let args: [String: JSONValue] = [
            "from": .number(Double(max(1, from))),
            "count": .number(Double(min(500, max(1, count))))
        ]
        guard let value = await perform(.listVariables, args) else { return false }
        guard let decoded: [CheatVariable] = decode(value, .listVariables) else { return false }
        if decoded != variables { variables = decoded }
        return true
    }

    @discardableResult
    func refreshSwitches(from: Int = 1, count: Int = 200, onlyOn: Bool = false) async -> Bool {
        let args: [String: JSONValue] = [
            "from": .number(Double(max(1, from))),
            "count": .number(Double(min(500, max(1, count)))),
            "onlyOn": .bool(onlyOn)
        ]
        guard let value = await perform(.listSwitches, args) else { return false }
        guard let decoded: [CheatSwitch] = decode(value, .listSwitches) else { return false }
        if decoded != switches { switches = decoded }
        return true
    }

    @discardableResult
    func refreshItems(kind: CheatItemKind = .item, ownedOnly: Bool = false) async -> Bool {
        let args: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "ownedOnly": .bool(ownedOnly)
        ]
        guard let value = await perform(.listItems, args) else { return false }
        guard let decoded: [CheatItem] = decode(value, .listItems) else { return false }
        if decoded != items { items = decoded }
        return true
    }

    @discardableResult
    func refreshActors() async -> Bool {
        guard let value = await perform(.listActors, [:]) else { return false }
        guard let decoded: [CheatActor] = decode(value, .listActors) else { return false }
        if decoded != actors { actors = decoded }
        return true
    }

    @discardableResult
    func refreshMapEvents(mapId: Int = 0) async -> Bool {
        let args: [String: JSONValue] = ["mapId": .number(Double(max(0, mapId)))]
        guard let value = await perform(.listMapEvents, args) else { return false }
        guard let decoded: [CheatMapEvent] = decode(value, .listMapEvents) else { return false }
        if decoded != mapEvents { mapEvents = decoded }
        return true
    }

    @discardableResult
    func refreshTransferPoints(mapId: Int = 0) async -> Bool {
        let args: [String: JSONValue] = ["mapId": .number(Double(max(0, mapId)))]
        guard let value = await perform(.transferPoints, args) else { return false }
        guard let decoded: [TransferPoint] = decode(value, .transferPoints) else { return false }
        if decoded != transferPoints { transferPoints = decoded }
        return true
    }

    /// 作弊页打开时的"一把梭"：快照 + 五张列表。
    ///
    /// 不并发发：Agent 侧一个 RPC 尚未返回时再来一个也只有一个 outbox，
    /// 并发只会让错误更难定位（且面板本来就是一屏一屏地看）。
    ///
    /// **整个序列共用一次 busy 区段**：六个 RPC 是串行 await 的，如果让每个
    /// `perform` 各自 `beginBusy/endBusy`，`isBusy` 会在 true/false 之间来回切
    /// 六次 —— 按钮禁用态跟着闪六下，看起来就是"点一下刷新整页闪"。
    @discardableResult
    func refreshAll() async -> Bool {
        guard isAvailable else {
            lastError = ErrorInfo(code: .cheatUnavailable, message: "尚未连接游戏（仅 MV/MZ 支持修改器）")
            return false
        }
        beginBusy()
        defer { endBusy() }
        guard await refreshSnapshot() else { return false }
        _ = await refreshVariables()
        _ = await refreshSwitches()
        _ = await refreshItems()
        _ = await refreshActors()
        _ = await refreshTransferPoints()
        // 标题画面 / 尚未进地图时 `$gameParty` 不存在，五张列表都会以
        // `cheat_unavailable` 失败。这是"还没到那一步"，不是故障：面板顶部已经
        // 写着"等待游戏进入场景"，再挂一条红色错误只会让人以为修改器坏了。
        if lastError?.code == .cheatUnavailable {
            lastError = nil
        }
        return lastError == nil
    }

    @discardableResult
    func readObjectPath(_ path: String) async -> Bool {
        guard let normalized = CheatPath.validate(path, error: &lastError) else { return false }
        guard let value = await perform(.objectPath, ["path": .string(normalized)]) else { return false }
        guard let decoded: CheatObjectValue = decode(value, .objectPath) else { return false }
        objectValue = decoded
        lastAction = "读取 \(normalized)"
        return true
    }

    // MARK: - 写入：数值 / 变量 / 开关

    @discardableResult
    func setGold(_ value: Int) async -> Bool {
        guard value >= 0 && value <= 99_999_999 else {
            return badArgs("金币必须在 0…99999999 之间")
        }
        guard await perform(.setGold, ["value": .number(Double(value))]) != nil else { return false }
        lastAction = "金币 = \(value)"
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func addGold(_ delta: Int) async -> Bool {
        guard delta != 0, abs(delta) <= 99_999_999 else {
            return badArgs("金币增减量非法")
        }
        guard await perform(.setGold, ["delta": .number(Double(delta))]) != nil else { return false }
        lastAction = "金币 \(delta > 0 ? "+" : "")\(delta)"
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func setVariable(id: Int, value: JSONValue) async -> Bool {
        guard id >= 1 else { return badArgs("变量 id 必须 ≥ 1") }
        let args: [String: JSONValue] = ["id": .number(Double(id)), "value": value]
        guard let returned = await perform(.setVariable, args) else { return false }
        if let updated: CheatVariable = decode(returned, .setVariable) {
            if let index = variables.firstIndex(where: { $0.id == id }) {
                variables[index].value = updated.value
            } else {
                variables.append(updated)
                variables.sort { $0.id < $1.id }
            }
        }
        lastAction = "变量 #\(id) 已写入"
        return true
    }

    @discardableResult
    func setSwitch(id: Int, on: Bool) async -> Bool {
        guard id >= 1 else { return badArgs("开关 id 必须 ≥ 1") }
        let args: [String: JSONValue] = ["id": .number(Double(id)), "on": .bool(on)]
        guard await perform(.setSwitch, args) != nil else { return false }
        if let index = switches.firstIndex(where: { $0.id == id }) {
            switches[index].value = on
        } else {
            switches.append(CheatSwitch(id: id, value: on))
            switches.sort { $0.id < $1.id }
        }
        lastAction = "开关 #\(id) = \(on ? "ON" : "OFF")"
        return true
    }

    @discardableResult
    func setSelfSwitch(mapId: Int, eventId: Int, letter: String, on: Bool) async -> Bool {
        let normalized = letter.uppercased()
        guard mapId >= 1 && eventId >= 1 else { return badArgs("mapId / eventId 必须 ≥ 1") }
        guard ["A", "B", "C", "D"].contains(normalized) else { return badArgs("独立开关只能是 A–D") }
        let args: [String: JSONValue] = [
            "mapId": .number(Double(mapId)),
            "eventId": .number(Double(eventId)),
            "letter": .string(normalized),
            "on": .bool(on)
        ]
        guard await perform(.setSelfSwitch, args) != nil else { return false }
        lastAction = "独立开关 \(mapId)/\(eventId)/\(normalized) = \(on ? "ON" : "OFF")"
        return true
    }

    /// 全开关批量切换（**危险**：会同时改掉剧情进度判定，UI 应二次确认）。
    @discardableResult
    func setAllSwitches(on: Bool) async -> Bool {
        guard let returned = await perform(.toggleAllSwitches, ["on": .bool(on)]) else { return false }
        let changed = returned["changed"]?.intValue ?? 0
        lastAction = "全开关 → \(on ? "ON" : "OFF")（\(changed) 个）"
        _ = await refreshSwitches(onlyOn: on)
        return true
    }

    @discardableResult
    func setAllSelfSwitches(on: Bool) async -> Bool {
        guard let returned = await perform(.toggleAllSelfSwitches, ["on": .bool(on)]) else { return false }
        let changed = returned["changed"]?.intValue ?? 0
        lastAction = "本图独立开关 → \(on ? "ON" : "OFF")（\(changed) 个）"
        return true
    }

    // MARK: - 写入：物品 / 队伍 / 角色

    @discardableResult
    func giveItem(kind: CheatItemKind = .item, id: Int, count: Int) async -> Bool {
        guard id >= 1 else { return badArgs("物品 id 必须 ≥ 1") }
        guard count != 0, abs(count) <= 9999 else { return badArgs("数量必须在 -9999…9999 之间") }
        let args: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "id": .number(Double(id)),
            "count": .number(Double(count))
        ]
        guard let returned = await perform(.giveItem, args) else { return false }
        let total = returned["count"]?.intValue ?? 0
        if let index = items.firstIndex(where: { $0.id == id && $0.kind == kind }) {
            items[index].count = total
        }
        lastAction = "\(kind.uiLabel) #\(id) \(count > 0 ? "+" : "")\(count)（现有 \(total)）"
        return true
    }

    @discardableResult
    func setItemCount(kind: CheatItemKind = .item, id: Int, count: Int) async -> Bool {
        guard id >= 1 else { return badArgs("物品 id 必须 ≥ 1") }
        guard count >= 0 && count <= 9999 else { return badArgs("数量必须在 0…9999 之间") }
        let args: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "id": .number(Double(id)),
            "count": .number(Double(count))
        ]
        guard let returned = await perform(.setItemCount, args) else { return false }
        let total = returned["count"]?.intValue ?? count
        if let index = items.firstIndex(where: { $0.id == id && $0.kind == kind }) {
            items[index].count = total
        }
        lastAction = "\(kind.uiLabel) #\(id) = \(total)"
        return true
    }

    @discardableResult
    func updateActor(id: Int, patch: CheatActorPatch) async -> Bool {
        guard id >= 1 else { return badArgs("角色 id 必须 ≥ 1") }
        guard !patch.isEmpty else { return badArgs("没有任何要修改的字段") }
        if let level = patch.level, level < 1 || level > 99 { return badArgs("等级必须在 1…99 之间") }
        if let exp = patch.exp, exp < 0 { return badArgs("经验不能为负") }
        if let hp = patch.hp, hp < 0 { return badArgs("HP 不能为负") }
        if let mp = patch.mp, mp < 0 { return badArgs("MP 不能为负") }
        if let tp = patch.tp, tp < 0 || tp > 100 { return badArgs("TP 必须在 0…100 之间") }
        if let classId = patch.classId, classId < 1 { return badArgs("职业 id 必须 ≥ 1") }
        if let states = patch.states, states.contains(where: { $0 < 0 }) { return badArgs("状态 id 不能为负") }
        if let equips = patch.equips, equips.contains(where: { $0.slotId < 0 || $0.slotId > 4 }) {
            return badArgs("装备槽必须在 0…4 之间")
        }

        var args: [String: JSONValue] = ["id": .number(Double(id))]
        if let level = patch.level { args["level"] = .number(Double(level)) }
        if let exp = patch.exp { args["exp"] = .number(Double(exp)) }
        if let hp = patch.hp { args["hp"] = .number(Double(hp)) }
        if let mp = patch.mp { args["mp"] = .number(Double(mp)) }
        if let tp = patch.tp { args["tp"] = .number(Double(tp)) }
        if let nickname = patch.nickname { args["nickname"] = .string(nickname) }
        if let classId = patch.classId { args["classId"] = .number(Double(classId)) }
        if let params = patch.params {
            args["params"] = .array(params.map { .number(Double($0)) })
        }
        if let states = patch.states {
            args["states"] = .array(states.map { .number(Double($0)) })
        }
        if let equips = patch.equips {
            args["equips"] = .array(equips.map { slot in
                var object: [String: JSONValue] = [
                    "slotId": .number(Double(slot.slotId)),
                    "kind": .string(slot.kind.rawValue)
                ]
                if let itemId = slot.itemId { object["itemId"] = .number(Double(itemId)) }
                return .object(object)
            })
        }

        guard let returned = await perform(.updateActor, args) else { return false }
        let changed = (returned["changed"]?.arrayValue ?? []).compactMap { $0.stringValue }
        lastAction = "角色 #\(id) 已更新（\(changed.joined(separator: ","))）"
        _ = await refreshActors()
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func recoverParty() async -> Bool {
        guard let returned = await perform(.recoverAll, ["scope": .string("party")]) else { return false }
        let count = returned["count"]?.intValue ?? 0
        lastAction = "全队回复（\(count) 人）"
        _ = await refreshActors()
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func addPartyMember(actorId: Int) async -> Bool {
        guard actorId >= 1 else { return badArgs("角色 id 必须 ≥ 1") }
        guard await perform(.addPartyMember, ["actorId": .number(Double(actorId))]) != nil else { return false }
        lastAction = "加入队伍：角色 #\(actorId)"
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func removePartyMember(actorId: Int) async -> Bool {
        guard actorId >= 1 else { return badArgs("角色 id 必须 ≥ 1") }
        guard await perform(.removePartyMember, ["actorId": .number(Double(actorId))]) != nil else { return false }
        lastAction = "移出队伍：角色 #\(actorId)"
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func setGodMode(on: Bool, lockHp: Bool = true, lockMp: Bool = false) async -> Bool {
        let args: [String: JSONValue] = [
            "on": .bool(on),
            "lockHp": .bool(lockHp),
            "lockMp": .bool(lockMp)
        ]
        guard await perform(.godMode, args) != nil else { return false }
        lastAction = "无敌模式 \(on ? "开" : "关")"
        _ = await refreshSnapshot()
        return true
    }

    /// 任意对象写入（**危险**：可改 `$gameSystem` 之类结构性状态，UI 必须二次确认）。
    @discardableResult
    func writeObjectPath(_ path: String, value: JSONValue) async -> Bool {
        guard let normalized = CheatPath.validate(path, error: &lastError) else { return false }
        switch value {
        case .string, .number, .bool:
            break
        default:
            return badArgs("只允许写入字符串 / 数字 / 布尔值")
        }
        guard let returned = await perform(.setObjectPath, ["path": .string(normalized), "value": value]) else {
            return false
        }
        if let decoded: CheatObjectValue = decode(returned, .setObjectPath) {
            objectValue = decoded
        }
        lastAction = "写入 \(normalized)"
        return true
    }

    // MARK: - 世界 / 流程

    @discardableResult
    func setNoclip(_ on: Bool) async -> Bool {
        guard await perform(.noclip, ["on": .bool(on)]) != nil else { return false }
        lastAction = "穿墙 \(on ? "开" : "关")"
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func setEncounterEnabled(_ on: Bool) async -> Bool {
        guard await perform(.encounter, ["on": .bool(on)]) != nil else { return false }
        lastAction = "遇敌 \(on ? "开" : "关")"
        return true
    }

    @discardableResult
    func setAlwaysDash(_ on: Bool) async -> Bool {
        guard await perform(.alwaysDash, ["on": .bool(on)]) != nil else { return false }
        lastAction = "常时奔跑 \(on ? "开" : "关")"
        return true
    }

    @discardableResult
    func setFollowersVisible(_ on: Bool) async -> Bool {
        guard await perform(.followers, ["on": .bool(on)]) != nil else { return false }
        lastAction = "队列显示 \(on ? "开" : "关")"
        return true
    }

    @discardableResult
    func unlockEquipmentSlots() async -> Bool {
        guard let returned = await perform(.unlockEquip, [:]) else { return false }
        let touched = returned["touched"]?.intValue ?? 0
        lastAction = "解锁装备槽（\(touched) 个角色）"
        _ = await refreshActors()
        return true
    }

    @discardableResult
    func unlockChoices() async -> Bool {
        guard await perform(.unlockChoice, [:]) != nil else { return false }
        lastAction = "已解除选项锁"
        return true
    }

    @discardableResult
    func setSpeedMultiplier(_ multiplier: Double) async -> Bool {
        guard multiplier >= 0.25 && multiplier <= 8 else {
            return badArgs("倍速必须在 0.25…8 之间")
        }
        let args: [String: JSONValue] = ["multiplier": .number(multiplier)]
        guard await perform(.speed, args) != nil else { return false }
        lastAction = String(format: "变速 ×%.2f", multiplier)
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func setMoveSpeedDelta(_ delta: Int) async -> Bool {
        guard delta != 0, abs(delta) <= 5 else { return badArgs("移动速度增减量必须在 ±5 以内") }
        let args: [String: JSONValue] = ["delta": .number(Double(delta))]
        guard let returned = await perform(.moveSpeed, args) else { return false }
        let speed = returned["moveSpeed"]?.intValue ?? 0
        lastAction = "移动速度 = \(speed)（\(delta > 0 ? "+" : "")\(delta)）"
        return true
    }

    @discardableResult
    func setMoveSpeedValue(_ value: Int) async -> Bool {
        guard value >= 1 && value <= 6 else { return badArgs("移动速度必须在 1…6 之间") }
        let args: [String: JSONValue] = ["value": .number(Double(value))]
        guard let returned = await perform(.moveSpeed, args) else { return false }
        let speed = returned["moveSpeed"]?.intValue ?? value
        lastAction = "移动速度 = \(speed)"
        return true
    }

    @discardableResult
    func teleport(mapId: Int, x: Int, y: Int, dir: Int = 0) async -> Bool {
        guard mapId >= 1 else { return badArgs("地图 id 必须 ≥ 1") }
        guard x >= 0, y >= 0 else { return badArgs("坐标不能为负") }
        guard dir == 0 || [2, 4, 6, 8].contains(dir) else { return badArgs("方向只能是 2/4/6/8 或 0（保持）") }
        let args: [String: JSONValue] = [
            "mapId": .number(Double(mapId)),
            "x": .number(Double(x)),
            "y": .number(Double(y)),
            "dir": .number(Double(dir))
        ]
        guard await perform(.teleport, args) != nil else { return false }
        lastAction = "传送到 \(mapId):(\(x),\(y))"
        return true
    }

    @discardableResult
    func openScene(_ scene: CheatSceneName) async -> Bool {
        guard await perform(.scene, ["name": .string(scene.rawValue)]) != nil else { return false }
        lastAction = "打开\(scene.uiLabel)"
        return true
    }

    @discardableResult
    func popScene() async -> Bool {
        guard await perform(.scenePop, [:]) != nil else { return false }
        lastAction = "返回上一场景"
        return true
    }

    /// 战斗操作（`lose` 是**危险**操作：会真的判失败，UI 应二次确认）。
    @discardableResult
    func battle(_ op: CheatBattleOp) async -> Bool {
        guard await perform(.battle, ["op": .string(op.rawValue)]) != nil else { return false }
        lastAction = op.uiLabel
        _ = await refreshSnapshot()
        return true
    }

    @discardableResult
    func clearPictures() async -> Bool {
        guard await perform(.clearPictures, [:]) != nil else { return false }
        lastAction = "已清除立绘"
        return true
    }

    @discardableResult
    func eraseCurrentEvent() async -> Bool {
        guard let returned = await perform(.clearEvent, [:]) else { return false }
        let erased = returned["erased"]?.boolValue ?? false
        lastAction = erased ? "已抹除当前事件" : "当前没有正在执行的事件"
        return true
    }

    @discardableResult
    func clearMoveRoute() async -> Bool {
        guard await perform(.clearMoveRoute, [:]) != nil else { return false }
        lastAction = "已清除移动路线"
        return true
    }

    @discardableResult
    func closeAllWindows() async -> Bool {
        guard let returned = await perform(.closeAllWindows, [:]) else { return false }
        let closed = returned["closed"]?.intValue ?? 0
        lastAction = "已关闭 \(closed) 个窗口"
        return true
    }

    @discardableResult
    func fadeIn() async -> Bool {
        guard await perform(.fadeIn, [:]) != nil else { return false }
        lastAction = "已淡入"
        return true
    }

    @discardableResult
    func recover() async -> Bool {
        return await recoverParty()
    }

    @discardableResult
    func repair() async -> Bool {
        guard let returned = await perform(.repair, [:]) else { return false }
        let fixed = (returned["fixed"]?.arrayValue ?? []).compactMap { $0.stringValue }
        lastAction = fixed.isEmpty ? "没有发现可修复的卡死状态" : "已修复：\(fixed.joined(separator: ","))"
        return true
    }

    @discardableResult
    func fixError() async -> Bool {
        guard let returned = await perform(.fixError, [:]) else { return false }
        let fixed = (returned["fixed"]?.arrayValue ?? []).compactMap { $0.stringValue }
        lastAction = fixed.isEmpty ? "没有发现错误状态" : "已修复：\(fixed.joined(separator: ","))"
        return true
    }

    /// 打开开发者工具。返回 `hint`（浏览器内核下拿不到 NW.js 窗口）。
    @discardableResult
    func openDevTools() async -> Bool {
        guard let returned = await perform(.devTools, [:]) else { return false }
        let opened = returned["opened"]?.boolValue ?? false
        if opened {
            lastAction = "已打开开发者工具"
            return true
        }
        let hint = returned["hint"]?.stringValue ?? "当前内核不支持开发者工具"
        lastError = ErrorInfo(code: .agentError, message: hint)
        return false
    }

    // MARK: - 内部

    /// 发一个 RPC。返回 `nil` 表示失败（`lastError` 已写好）。
    ///
    /// - Parameter busy: `false` 用于**心跳**类调用（`cheat.snapshot` 每秒一次）。
    ///   它们不该驱动「忙碌」指示，否则按钮与转圈会以 1Hz 频闪。
    private func perform(
        _ method: CheatMethod,
        _ args: [String: JSONValue],
        busy: Bool = true
    ) async -> JSONValue? {
        guard let rpc = rpc else {
            lastError = ErrorInfo(code: .attachFailed, message: "尚未连接游戏")
            return nil
        }
        if busy { beginBusy() }
        defer { if busy { endBusy() } }
        do {
            let value = try await rpc.call(method: method.rawValue, args: .object(args))
            lastError = nil
            return value
        } catch let error as MochiBoxError {
            lastError = error.asErrorInfo
            log?.debug("CheatController", "作弊调用失败", [
                "method": method.rawValue,
                "code": error.code.rawValue
            ])
            return nil
        } catch {
            lastError = ErrorInfo(code: .agentError, message: "\(method.rawValue): \(error)")
            return nil
        }
    }

    private func decode<T: Decodable>(_ value: JSONValue, _ method: CheatMethod) -> T? {
        do {
            return try value.decoded(T.self)
        } catch {
            lastError = ErrorInfo(
                code: .agentError,
                message: "\(method.rawValue) 的返回值无法解析：\(error)"
            )
            return nil
        }
    }

    @discardableResult
    private func badArgs(_ message: String) -> Bool {
        lastError = ErrorInfo(code: .cheatBadArgs, message: message)
        return false
    }

    private func beginBusy() {
        busyCount += 1
        if !isBusy { isBusy = true }
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0 && isBusy { isBusy = false }
    }
}

// MARK: - RPC 方法名

/// `cheat.*` 的 RPC 方法名 —— **跨语言协议**，不是内部标识符。
///
/// `Resources/agent_mvmz.js` 按同一批字符串分发，所以每个 `rawValue` 都必须与改前逐字符相同；
/// 换成枚举只为把「拼错的自由」拿掉：拼错在编译期就报错，而不是运行时退化成
/// `rpc_timeout` / `cheat_bad_args`（面板上只会显示一句"操作失败"，排查要翻日志）。
///
/// 新增方法必须**同时**改 JS 侧，否则 Host 编译得过、调用必然超时。
/// 顺序按字母排列，只为便于与 Agent 侧清单对照，不承载语义。
enum CheatMethod: String {
    case addPartyMember = "cheat.addPartyMember"
    case alwaysDash = "cheat.alwaysDash"
    case battle = "cheat.battle"
    case clearEvent = "cheat.clearEvent"
    case clearMoveRoute = "cheat.clearMoveRoute"
    case clearPictures = "cheat.clearPictures"
    case closeAllWindows = "cheat.closeAllWindows"
    case devTools = "cheat.devTools"
    case encounter = "cheat.encounter"
    case fadeIn = "cheat.fadeIn"
    case fixError = "cheat.fixError"
    case followers = "cheat.followers"
    case giveItem = "cheat.giveItem"
    case godMode = "cheat.godMode"
    case listActors = "cheat.listActors"
    case listItems = "cheat.listItems"
    case listMapEvents = "cheat.listMapEvents"
    case listSwitches = "cheat.listSwitches"
    case listVariables = "cheat.listVariables"
    case moveSpeed = "cheat.moveSpeed"
    case noclip = "cheat.noclip"
    case objectPath = "cheat.objectPath"
    case recoverAll = "cheat.recoverAll"
    case removePartyMember = "cheat.removePartyMember"
    case repair = "cheat.repair"
    case scene = "cheat.scene"
    case scenePop = "cheat.scenePop"
    case setGold = "cheat.setGold"
    case setItemCount = "cheat.setItemCount"
    case setObjectPath = "cheat.setObjectPath"
    case setSelfSwitch = "cheat.setSelfSwitch"
    case setSwitch = "cheat.setSwitch"
    case setVariable = "cheat.setVariable"
    case snapshot = "cheat.snapshot"
    case speed = "cheat.speed"
    case teleport = "cheat.teleport"
    case toggleAllSelfSwitches = "cheat.toggleAllSelfSwitches"
    case toggleAllSwitches = "cheat.toggleAllSwitches"
    case transferPoints = "cheat.transferPoints"
    case unlockChoice = "cheat.unlockChoice"
    case unlockEquip = "cheat.unlockEquip"
    case updateActor = "cheat.updateActor"
}

// MARK: - 路径校验

/// `cheat.objectPath` / `cheat.setObjectPath` 的 Host 侧边界（与 Agent 的
/// `assertSafePath` **同规则但独立实现**：两处都要挡，不能只靠页面侧。
/// 页面侧的检查在攻击面上是不可信的 —— 站在 Host 的角度，它只是一段被注入的脚本）。
enum CheatPath {
    /// 首段必须是 `$game*` / `$data*`（含 `$gameTemp`），深度 2…8。
    static let maxDepth = 8

    static func validate(_ path: String, error: inout ErrorInfo?) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = ErrorInfo(code: .cheatBadArgs, message: "路径不能为空")
            return nil
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= maxDepth else {
            error = ErrorInfo(code: .cheatBadArgs, message: "路径深度必须是 2…\(maxDepth) 段")
            return nil
        }
        let head = parts[0]
        guard head.hasPrefix("$game") || head.hasPrefix("$data") else {
            error = ErrorInfo(code: .cheatForbidden, message: "只允许 $game* / $data* 开头的路径")
            return nil
        }
        // 中间段不许为空（`$gameParty.._gold`）也不许是原型链逃逸。
        for part in parts {
            guard !part.isEmpty else {
                error = ErrorInfo(code: .cheatBadArgs, message: "路径里不能有空段")
                return nil
            }
            if part == "__proto__" || part == "constructor" || part == "prototype" {
                error = ErrorInfo(code: .cheatForbidden, message: "禁止的路径段：\(part)")
                return nil
            }
        }
        // 宿主对象不用单独挡：首段白名单已经把它们全部排除（location/document/fetch/require）。
        return trimmed
    }
}
