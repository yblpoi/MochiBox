//
//  CheatPanelDetail.swift
//  MochiBox
//
//  `CheatPanel` 的五个具体页：物品 / 角色 / 世界 / 流程 / 高级。
//  拆文件只为编译速度与可读性：每个页只碰 `CheatController` 的公开方法，
//  危险动作一律通过 `onDanger` 交回根视图统一确认（见 CheatPanel.swift）。
//

import SwiftUI

// MARK: - 物品

struct CheatItemsPage: View {
    private final class UIState: ObservableObject {
        @Published var kind: CheatItemKind = .item
        @Published var ownedOnly: Bool = false
        @Published var selectedId: Int? = nil
        @Published var countText: String = "10"
        @Published var query: String = ""
    }
    @StateObject private var state = UIState()
    @ObservedObject var controller: CheatController


    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            List(selection: $state.selectedId) {
                ForEach(filteredItems) { item in
                    row(item).tag(item.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if filteredItems.isEmpty {
                    Text(controller.isAvailable ? "没有匹配的条目" : "未连接游戏")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            actions
        }
        .onAppear { reload() }
        .onChange(of: state.kind) { _ in
            state.selectedId = nil
            reload()
        }
        .onChange(of: state.ownedOnly) { _ in
            state.selectedId = nil
            reload()
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $state.kind) {
                ForEach(CheatItemKind.allCases) { item in
                    Text(item.uiLabel).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Toggle("仅显示已持有", isOn: $state.ownedOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("搜索名称", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 120)
            }

            Spacer()
            Button("刷新") { reload() }
                .disabled(locked)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func row(_ item: CheatItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !item.description.isEmpty {
                    Text(item.description.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if item.price > 0 {
                Text("\(item.price) G")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("×\(item.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(item.count > 0 ? .primary : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("给予 1") { give(1) }
            Button("给予 10") { give(10) }
            Button("给予 99") { give(99) }
            CheatNumberField(title: "设为", text: $state.countText, width: 60)
            Button("应用") {
                guard let item = selectedItem, let count = CheatValueParser.int(state.countText) else { return }
                Task { await controller.setItemCount(kind: state.kind, id: item.id, count: count) }
            }
            .disabled(locked || selectedItem == nil || CheatValueParser.int(state.countText) == nil)
            Spacer()
            if let item = selectedItem {
                Text("已选：\(item.displayName)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text("选择一条后操作")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(locked)
    }

    private var filteredItems: [CheatItem] {
        guard !state.query.isEmpty else { return controller.items }
        return controller.items.filter {
            $0.displayName.localizedCaseInsensitiveContains(state.query) || String($0.id) == state.query
        }
    }

    private var selectedItem: CheatItem? {
        guard let id = state.selectedId else { return nil }
        return controller.items.first { $0.id == id }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }

    private func give(_ count: Int) {
        guard let item = selectedItem else { return }
        Task { await controller.giveItem(kind: state.kind, id: item.id, count: count) }
    }

    private func reload() {
        Task { await controller.refreshItems(kind: state.kind, ownedOnly: state.ownedOnly) }
    }
}

// MARK: - 角色

struct CheatActorsPage: View {
    private final class UIState: ObservableObject {
        @Published var selectedId: Int? = nil
        @Published var levelText: String = ""
        @Published var expText: String = ""
        @Published var hpText: String = ""
        @Published var mpText: String = ""
        @Published var tpText: String = ""
        @Published var nickname: String = ""
    }
    @StateObject private var state = UIState()
    @ObservedObject var controller: CheatController


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("角色")
                        .font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $state.selectedId) {
                        Text("选择角色").tag(Int?.none)
                        ForEach(controller.actors) { actor in
                            Text("\(actor.name.isEmpty ? "#\(actor.id)" : actor.name)  Lv\(actor.level)")
                                .tag(Int?.some(actor.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 220)
                    Button("刷新") {
                        Task { await controller.refreshActors() }
                    }
                    .disabled(locked)
                    Spacer()
                    Button("恢复全队") {
                        Task { await controller.recoverParty() }
                    }
                    .disabled(locked)
                }

                if let actor = selectedActor {
                    GroupBox(label: Text("属性").font(.system(size: 11))) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                CheatNumberField(title: "等级", text: $state.levelText, width: 54)
                                CheatNumberField(title: "经验", text: $state.expText, width: 80)
                                CheatNumberField(title: "HP", text: $state.hpText, width: 54)
                                Text("/ \(actor.mhp)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                CheatNumberField(title: "MP", text: $state.mpText, width: 54)
                                Text("/ \(actor.mmp)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                CheatNumberField(title: "TP", text: $state.tpText, width: 46)
                            }
                            HStack(spacing: 8) {
                                Text("名字")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                TextField("", text: $state.nickname)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .frame(width: 180)
                                Button("应用修改") { apply(actor) }
                                    .disabled(locked || !hasChanges(actor))
                                Button("满 HP/MP") { fillMax(actor) }
                                    .disabled(locked)
                                Spacer()
                            }
                            HStack(spacing: 10) {
                                Button("加入队伍") {
                                    Task { await controller.addPartyMember(actorId: actor.id) }
                                }
                                Button("移出队伍") {
                                    Task { await controller.removePartyMember(actorId: actor.id) }
                                }
                                Spacer()
                            }
                            .disabled(locked)
                        }
                        .padding(6)
                    }

                    GroupBox(label: Text("只读").font(.system(size: 11))) {
                        VStack(alignment: .leading, spacing: 4) {
                            CheatKeyValue(key: "职业", value: actor.className.isEmpty ? "#\(actor.classId)" : "\(actor.className) #\(actor.classId)")
                            CheatKeyValue(key: "能力", value: paramsText(actor.params))
                            CheatKeyValue(key: "装备", value: equipsText(actor.equips))
                            CheatKeyValue(key: "状态", value: statesText(actor.states))
                        }
                        .padding(6)
                    }
                } else {
                    Text("选择角色后可以改等级 / 经验 / HP / MP / TP / 名字，并调整队伍成员。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            Task { await controller.refreshActors() }
            syncForm()
        }
        .onChange(of: state.selectedId) { _ in syncForm() }
        .onChange(of: controller.actors) { _ in
            if state.selectedId == nil { state.selectedId = controller.actors.first?.id }
            syncForm()
        }
    }

    private var selectedActor: CheatActor? {
        guard let id = state.selectedId else { return nil }
        return controller.actors.first { $0.id == id }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }

    private func syncForm() {
        guard let actor = selectedActor else { return }
        state.levelText = "\(actor.level)"
        state.expText = "\(actor.exp)"
        state.hpText = "\(actor.hp)"
        state.mpText = "\(actor.mp)"
        state.tpText = "\(actor.tp)"
        state.nickname = actor.nickname
    }

    private func hasChanges(_ actor: CheatActor) -> Bool {
        return CheatValueParser.int(state.levelText) != actor.level
            || CheatValueParser.int(state.expText) != actor.exp
            || CheatValueParser.int(state.hpText) != actor.hp
            || CheatValueParser.int(state.mpText) != actor.mp
            || CheatValueParser.int(state.tpText) != actor.tp
            || state.nickname != actor.nickname
    }

    /// 只发**真的改了**的字段：`updateActor` 的每个字段在 Agent 侧都是一次 setter
    /// （改 `level` 会重算 MHP/MPP），全量提交等于把没动过的属性也重算一遍。
    private func apply(_ actor: CheatActor) {
        var patch = CheatActorPatch()
        if let value = CheatValueParser.int(state.levelText), value != actor.level { patch.level = value }
        if let value = CheatValueParser.int(state.expText), value != actor.exp { patch.exp = value }
        if let value = CheatValueParser.int(state.hpText), value != actor.hp { patch.hp = value }
        if let value = CheatValueParser.int(state.mpText), value != actor.mp { patch.mp = value }
        if let value = CheatValueParser.int(state.tpText), value != actor.tp { patch.tp = value }
        if state.nickname != actor.nickname { patch.nickname = state.nickname }
        guard !patch.isEmpty else { return }
        Task { await controller.updateActor(id: actor.id, patch: patch) }
    }

    private func fillMax(_ actor: CheatActor) {
        var patch = CheatActorPatch()
        patch.hp = actor.mhp
        patch.mp = actor.mmp
        patch.tp = 100
        Task { await controller.updateActor(id: actor.id, patch: patch) }
    }

    private func paramsText(_ params: [Int]) -> String {
        guard !params.isEmpty else { return "—" }
        let names = ["MHP", "MMP", "ATK", "DEF", "MAT", "MDF", "AGI", "LUK"]
        return params.enumerated().map { index, value in
            let name = index < names.count ? names[index] : "#\(index)"
            return "\(name) \(value)"
        }.joined(separator: " · ")
    }

    private func equipsText(_ equips: [CheatEquip?]) -> String {
        guard !equips.isEmpty else { return "—" }
        return equips.enumerated().map { index, equip in
            guard let equip = equip else { return "槽\(index)空" }
            return "槽\(index):\(equip.name.isEmpty ? "#\(equip.id)" : equip.name)"
        }.joined(separator: " · ")
    }

    private func statesText(_ states: [CheatStateRef]) -> String {
        guard !states.isEmpty else { return "无" }
        return states.map { $0.name.isEmpty ? "#\($0.id)" : $0.name }.joined(separator: " · ")
    }
}

// MARK: - 世界

struct CheatWorldPage: View {
    private final class UIState: ObservableObject {
        @Published var noclip: Bool = false
        @Published var encounter: Bool = true
        @Published var alwaysDash: Bool = false
        @Published var followers: Bool = true
        @Published var godMode: Bool = false
        @Published var lockHp: Bool = true
        @Published var lockMp: Bool = false
        @Published var speedText: String = "1.0"
        @Published var moveSpeed: Int = 4
        @Published var mapIdText: String = ""
        @Published var xText: String = "0"
        @Published var yText: String = "0"
        @Published var direction: Int = 0
    }
    @StateObject private var state = UIState()
    @ObservedObject var controller: CheatController




    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                toggles
                speedSection
                teleportSection
                transferSection
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncFromSnapshot() }
        .onChange(of: controller.snapshot?.player?.through ?? false) { value in
            state.noclip = value
        }
        .onChange(of: controller.snapshot?.godMode ?? false) { value in
            state.godMode = value
        }
    }

    // MARK: 开关

    private var toggles: some View {
        GroupBox(label: Text("即时开关").font(.system(size: 11))) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("穿墙（state.noclip）", isOn: Binding(
                    get: { state.noclip },
                    set: { value in
                        state.noclip = value
                        Task { await controller.setNoclip(value) }
                    }
                ))
                Toggle("允许遇敌（state.encounter）", isOn: Binding(
                    get: { state.encounter },
                    set: { value in
                        state.encounter = value
                        Task { await controller.setEncounterEnabled(value) }
                    }
                ))
                Toggle("常时奔跑（state.alwaysDash）", isOn: Binding(
                    get: { state.alwaysDash },
                    set: { value in
                        state.alwaysDash = value
                        Task { await controller.setAlwaysDash(value) }
                    }
                ))
                Toggle("显示队列（state.followers）", isOn: Binding(
                    get: { state.followers },
                    set: { value in
                        state.followers = value
                        Task { await controller.setFollowersVisible(value) }
                    }
                ))

                Divider()

                Toggle("无敌模式（锁 HP/MP）", isOn: Binding(
                    get: { state.godMode },
                    set: { value in
                        state.godMode = value
                        Task { await controller.setGodMode(on: value, lockHp: state.lockHp, lockMp: state.lockMp) }
                    }
                ))
                HStack(spacing: 14) {
                    Toggle("锁 HP", isOn: Binding(
                        get: { state.lockHp },
                        set: { value in
                            state.lockHp = value
                            if state.godMode { Task { await controller.setGodMode(on: true, lockHp: value, lockMp: state.lockMp) } }
                        }
                    ))
                    Toggle("锁 MP", isOn: Binding(
                        get: { state.lockMp },
                        set: { value in
                            state.lockMp = value
                            if state.godMode { Task { await controller.setGodMode(on: true, lockHp: state.lockHp, lockMp: value) } }
                        }
                    ))
                    Spacer()
                }
                .padding(.leading, 18)

                if controller.snapshot?.godMode == true && !state.godMode {
                    Text("引擎侧仍报告无敌开着，等下一次快照会对齐。")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                Text("穿墙与无敌会被快照回读；遇敌 / 常时奔跑 / 队列没有只读接口，开关是本页的记录，重新打开面板会回到默认值。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(locked)
            .padding(6)
        }
    }

    // MARK: 变速

    private var speedSection: some View {
        GroupBox(label: Text("速度").font(.system(size: 11))) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("全局倍率")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    CheatNumberField(text: $state.speedText, width: 60)
                    Button("应用") {
                        guard let value = CheatValueParser.double(state.speedText) else { return }
                        Task { await controller.setSpeedMultiplier(value) }
                    }
                    .disabled(locked || CheatValueParser.double(state.speedText) == nil)
                    ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { preset in
                        Button(String(format: "×%g", preset)) {
                            state.speedText = String(preset)
                            Task { await controller.setSpeedMultiplier(preset) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("移动速度")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Stepper(value: $state.moveSpeed, in: 1...6) {
                        Text("\(state.moveSpeed)")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 16)
                    }
                    Button("应用") {
                        Task { await controller.setMoveSpeedValue(state.moveSpeed) }
                    }
                    Button("-1") { Task { await controller.setMoveSpeedDelta(-1) } }
                    Button("+1") { Task { await controller.setMoveSpeedDelta(1) } }
                    Spacer()
                }
                Text("倍率作用于引擎 delta（0.25–8）；移动速度是角色每帧的步进档位（1–6）。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .disabled(locked)
            .padding(6)
        }
    }

    // MARK: 传送

    private var teleportSection: some View {
        GroupBox(label: Text("传送").font(.system(size: 11))) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    CheatNumberField(title: "地图", text: $state.mapIdText, width: 60)
                    CheatNumberField(title: "x", text: $state.xText, width: 50)
                    CheatNumberField(title: "y", text: $state.yText, width: 50)
                    Picker("", selection: $state.direction) {
                        Text("保持朝向").tag(0)
                        Text("下").tag(2)
                        Text("左").tag(4)
                        Text("右").tag(6)
                        Text("上").tag(8)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 90)
                    Button("传送") {
                        guard let mapId = CheatValueParser.int(state.mapIdText),
                              let x = CheatValueParser.int(state.xText),
                              let y = CheatValueParser.int(state.yText) else { return }
                        Task { await controller.teleport(mapId: mapId, x: x, y: y, dir: state.direction) }
                    }
                    .disabled(locked
                        || CheatValueParser.int(state.mapIdText) == nil
                        || CheatValueParser.int(state.xText) == nil
                        || CheatValueParser.int(state.yText) == nil)
                    Spacer()
                    if let snapshot = controller.snapshot, snapshot.mapId > 0 {
                        Text("当前 \(snapshot.mapId):(\(snapshot.player?.x ?? 0),\(snapshot.player?.y ?? 0))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    private var transferSection: some View {
        GroupBox(label: Text("传送点（点击填入上面的坐标）").font(.system(size: 11))) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("共 \(controller.transferPoints.count) 个")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("刷新列表") {
                        Task { await controller.refreshTransferPoints(mapId: controller.snapshot?.mapId ?? 0) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(locked)
                }
                if controller.transferPoints.isEmpty {
                    Text("扫描不到传送点：地图事件里没有「场所移动」指令或 <TP> 注释。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(controller.transferPoints.prefix(80)) { point in
                        Button {
                            state.mapIdText = "\(point.mapId)"
                            state.xText = "\(point.x)"
                            state.yText = "\(point.y)"
                        } label: {
                            HStack(spacing: 8) {
                                Text(point.displayName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(point.mapId):(\(point.x),\(point.y))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                    }
                }
            }
            .padding(6)
        }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }

    private func syncFromSnapshot() {
        guard let snapshot = controller.snapshot else { return }
        state.noclip = snapshot.player?.through ?? false
        state.godMode = snapshot.godMode
        state.speedText = String(format: "%g", snapshot.speed > 0 ? snapshot.speed : 1)
        if state.mapIdText.isEmpty, snapshot.mapId > 0 { state.mapIdText = "\(snapshot.mapId)" }
        if let player = snapshot.player {
            state.xText = "\(player.x)"
            state.yText = "\(player.y)"
        }
        Task { await controller.refreshTransferPoints(mapId: snapshot.mapId) }
    }
}

// MARK: - 流程

struct CheatFlowPage: View {
    @ObservedObject var controller: CheatController
    var onDanger: (CheatDanger) -> Void

    /// `mvlang` 里的 12 个场景入口（§10 的 P0 行）。
    private let scenes: [CheatSceneName] = [
        .menu, .save, .load, .options, .status, .equip,
        .skill, .item, .formation, .debug, .title, .map
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Text("打开场景").font(.system(size: 11))) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(scenes) { scene in
                            Button(scene.uiLabel) {
                                Task { await controller.openScene(scene) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(6)
                    .disabled(locked)
                }

                GroupBox(label: Text("战斗").font(.system(size: 11))) {
                    HStack(spacing: 8) {
                        ForEach(CheatBattleOp.allCases) { op in
                            Button(op.uiLabel) {
                                if op == .lose {
                                    onDanger(.battleLose)
                                } else {
                                    Task { await controller.battle(op) }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundColor(op.isDestructive ? .red : .primary)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .disabled(locked)
                }

                GroupBox(label: Text("工具").font(.system(size: 11))) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        Button("返回上一场景") { Task { await controller.popScene() } }
                        Button("关闭所有窗口") { Task { await controller.closeAllWindows() } }
                        Button("画面淡入") { Task { await controller.fadeIn() } }
                        Button("清除立绘") { Task { await controller.clearPictures() } }
                        Button("抹除当前事件") { Task { await controller.eraseCurrentEvent() } }
                        Button("清除移动路线") { Task { await controller.clearMoveRoute() } }
                        Button("修复卡死") { Task { await controller.repair() } }
                        Button("修复错误") { Task { await controller.fixError() } }
                        Button("开发者工具") { Task { await controller.openDevTools() } }
                        Button("解锁装备槽") { Task { await controller.unlockEquipmentSlots() } }
                        Button("解除选项锁") { Task { await controller.unlockChoices() } }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(6)
                    .disabled(locked)
                }

                Text("场景按钮走 `cheat.scene`：MZ 没有 Scene_Debug 时会返回 cheat_bad_args，属正常。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }
}

// MARK: - 高级

struct CheatAdvancedPage: View {
    private final class UIState: ObservableObject {
        @Published var path: String = "$gameParty._gold"
        @Published var readError: String = ""
        @Published var writeType: WriteType = .number
        @Published var valueText: String = ""
        @Published var boolValue: Bool = true
    }
    @StateObject private var state = UIState()
    @ObservedObject var controller: CheatController
    var onDanger: (CheatDanger) -> Void

    enum WriteType: String, CaseIterable, Identifiable {
        case string = "字符串"
        case number = "数字"
        case boolean = "布尔"
        var id: String { rawValue }
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Text("读取").font(.system(size: 11))) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("$gameParty._gold", text: $state.path)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            Button("读取") { read() }
                                .disabled(locked || state.path.isEmpty)
                            Menu("常用") {
                                Button("$gameParty._gold") { state.path = "$gameParty._gold" }
                                Button("$gameSystem._encounterEnabled") { state.path = "$gameSystem._encounterEnabled" }
                                Button("$gameSystem._alwaysDash") { state.path = "$gameSystem._alwaysDash" }
                                Button("$gamePlayer._moveSpeed") { state.path = "$gamePlayer._moveSpeed" }
                                Button("$gamePlayer.x") { state.path = "$gamePlayer.x" }
                            }
                            .frame(width: 70)
                            .disabled(locked)
                        }
                        if !state.readError.isEmpty {
                            Text(state.readError)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                        if let value = controller.objectValue {
                            VStack(alignment: .leading, spacing: 3) {
                                CheatKeyValue(key: "路径", value: value.path)
                                CheatKeyValue(key: "类型", value: value.type.isEmpty ? "—" : value.type)
                                Text(value.value.jsonText())
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .weakFill(0.08)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox(label: Text("写入（二次确认）").font(.system(size: 11))) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Picker("", selection: $state.writeType) {
                                ForEach(WriteType.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)

                            if state.writeType == .boolean {
                                Toggle("true", isOn: $state.boolValue)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            } else {
                                TextField("值", text: $state.valueText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 220)
                            }

                            Button("写入…") { confirmWrite() }
                                .disabled(locked || makeValue() == nil || state.path.isEmpty)
                            Spacer()
                        }
                        Text("只允许 $game* / $data* 开头、2–8 段的点路径；值只能是字符串 / 数字 / 布尔。对象与数组请在对应的专用页里改。")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                Text("这一页直接修改运行时对象，不提供任意表达式求值。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }

    private func read() {
        let trimmed = state.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$game") || trimmed.hasPrefix("$data") else {
            state.readError = "只允许 $game* / $data* 开头的路径"
            return
        }
        state.readError = ""
        Task { await controller.readObjectPath(trimmed) }
    }

    private func makeValue() -> JSONValue? {
        switch state.writeType {
        case .string:
            return .string(state.valueText)
        case .number:
            guard CheatValueParser.isStrictNumber(state.valueText), let number = Double(state.valueText) else { return nil }
            return .number(number)
        case .boolean:
            return .bool(state.boolValue)
        }
    }

    private func confirmWrite() {
        let trimmed = state.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$game") || trimmed.hasPrefix("$data") else {
            state.readError = "只允许 $game* / $data* 开头的路径"
            return
        }
        guard let value = makeValue() else { return }
        state.readError = ""
        onDanger(.objectWrite(path: trimmed, value: value))
    }
}
