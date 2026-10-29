//
//  CheatPanel.swift
//  MochiBox
//
//  V0.6 修改器面板（docs/architecture-v0.6-cheat-and-fulltext.md §3 / §6）。
//
//  形态取自 MTool 的 `mvlang` 功能面（docs/re-cheat-and-fulltext.md §2）：
//  左侧分组 + 右侧表单，而不是一堆散落的按钮 —— 因为条目本来就有 40+ 项，
//  按"玩家想改什么"分组比按"引擎 API 叫什么"分组更容易找。
//
//  两条硬约束（都在这里落地）：
//    1. 顶部快照 **1 s 刷新只在页面可见时跑**：`.onAppear` 起 `.onDisappear` 停，
//       切回翻译流 / 关窗都不留定时器；
//    2. 危险操作（全开关、强制战败、任意对象写入）走本文件统一的二次确认 alert，
//       具体页面只调 `onDanger`，不自己弹窗。
//

import SwiftUI
import Combine

// MARK: - 分组

enum CheatSection: String, CaseIterable, Identifiable {
    case status = "状态"
    case numbers = "数值"
    case items = "物品"
    case actors = "角色"
    case world = "世界"
    case flow = "流程"
    case advanced = "高级"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .status: return "gauge"
        case .numbers: return "number"
        case .items: return "shippingbox"
        case .actors: return "person.2"
        case .world: return "map"
        case .flow: return "play.rectangle"
        case .advanced: return "terminal"
        }
    }
}

// MARK: - 危险操作

/// 需要二次确认的动作。确认文案由这里给出，避免各页面各写一套。
enum CheatDanger: Identifiable {
    case allSwitches(Bool)
    case battleLose
    case objectWrite(path: String, value: JSONValue)

    var id: String {
        switch self {
        case .allSwitches(let on): return "all-switches-\(on)"
        case .battleLose: return "battle-lose"
        case .objectWrite(let path, _): return "write-\(path)"
        }
    }

    var title: String {
        switch self {
        case .allSwitches: return "切换全部开关？"
        case .battleLose: return "强制战败？"
        case .objectWrite: return "写入游戏对象？"
        }
    }

    var message: String {
        switch self {
        case .allSwitches(let on):
            return on
                ? "会把数据里所有开关置为 ON。剧情进度、事件页判定都会同时改变，通常无法逐条还原。"
                : "会把数据里所有开关置为 OFF。剧情进度、事件页判定都会同时改变。"
        case .battleLose:
            return "会把队伍 HP 压到 1 后判负。如果游戏没有战斗场景，可能直接进入 Game Over。"
        case .objectWrite(let path, let value):
            return "路径：\(path)\n值：\(value.cheatDisplayText)\n\n直接改运行时对象的字段，可能破坏存档/事件状态。"
        }
    }

    var confirmLabel: String {
        switch self {
        case .allSwitches: return "全部切换"
        case .battleLose: return "判负"
        case .objectWrite: return "写入"
        }
    }
}

// MARK: - 面板

struct CheatPanel: View {
    private final class UIState: ObservableObject {
        @Published var section: CheatSection? = .status
        @Published var ticker: AnyCancellable? = nil
        @Published var danger: CheatDanger? = nil
        @Published var showDanger: Bool = false
    }
    @StateObject private var state = UIState()
    @ObservedObject var controller: CheatController

    /// 1 s 心跳：**只有持有它的时候才有定时器**（`onDisappear` 里置 nil）。

    var body: some View {
        VStack(spacing: 0) {
            CheatSnapshotBar(controller: controller)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            CheatFooter(controller: controller)
        }
        .onAppear {
            startTicker()
            Task { await controller.refreshAll() }
        }
        .onDisappear {
            stopTicker()
        }
        .alert("确认操作", isPresented: $state.showDanger, presenting: state.danger) { pending in
            Button("取消", role: .cancel) { state.danger = nil }
            Button(pending.confirmLabel, role: .destructive) { run(pending) }
        } message: { pending in
            Text(pending.message)
        }
    }

    // MARK: 分组栏

    private var sidebar: some View {
        List(selection: $state.section) {
            ForEach(CheatSection.allCases) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .font(.system(size: 12))
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        // 同 libraryPane：露出手底下的整窗材质，别自己再画一层系统 sidebar 背景。
        .scrollContentBackground(.hidden)
        .frame(width: 150)
    }

    @ViewBuilder
    private var page: some View {
        switch state.section ?? .status {
        case .status:
            CheatStatusPage(controller: controller)
        case .numbers:
            CheatNumbersPage(controller: controller, onDanger: requestDanger)
        case .items:
            CheatItemsPage(controller: controller)
        case .actors:
            CheatActorsPage(controller: controller)
        case .world:
            CheatWorldPage(controller: controller)
        case .flow:
            CheatFlowPage(controller: controller, onDanger: requestDanger)
        case .advanced:
            CheatAdvancedPage(controller: controller, onDanger: requestDanger)
        }
    }

    // MARK: 心跳与确认

    private func startTicker() {
        stopTicker()
        state.ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                // 页面不可见时 sink 已随 cancellable 一起销毁；这里再挡两种情况：
                // 未接线（刷新只会反复写 lastError）与已有请求在飞（避免排队）。
                guard controller.isAvailable, !controller.isBusy else { return }
                Task { await controller.refreshSnapshot() }
            }
    }

    private func stopTicker() {
        state.ticker?.cancel()
        state.ticker = nil
    }

    private func requestDanger(_ item: CheatDanger) {
        state.danger = item
        state.showDanger = true
    }

    private func run(_ item: CheatDanger) {
        state.danger = nil
        Task {
            switch item {
            case .allSwitches(let on):
                await controller.setAllSwitches(on: on)
            case .battleLose:
                await controller.battle(.lose)
            case .objectWrite(let path, let value):
                await controller.writeObjectPath(path, value: value)
            }
        }
    }
}

// MARK: - 快照条

struct CheatSnapshotBar: View {
    @ObservedObject var controller: CheatController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let snapshot = controller.snapshot {
                    chip("场景", snapshot.scene.isEmpty ? "—" : snapshot.scene, mono: true)
                    chip("地图", mapText(snapshot), mono: false)
                    chip("金币", "\(snapshot.gold)", mono: true)
                    if let player = snapshot.player {
                        chip("坐标", "\(player.x),\(player.y) \(player.directionLabel)", mono: true)
                    }
                    chip("倍速", String(format: "×%.2f", snapshot.speed), mono: true)
                    partyChips(snapshot.party)
                } else {
                    Text("等待游戏进入场景…（未进入地图时引擎没有 $gameMap）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mapText(_ snapshot: CheatSnapshot) -> String {
        guard snapshot.mapId > 0 else { return "—" }
        return snapshot.mapName.isEmpty
            ? "\(snapshot.mapId)"
            : "\(snapshot.mapId) \(snapshot.mapName)"
    }

    private func chip(_ title: String, _ value: String, mono: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func partyChips(_ party: [CheatPartyMember]) -> some View {
        ForEach(party.prefix(6)) { member in
            HStack(spacing: 4) {
                Text(member.name.isEmpty ? "#\(member.id)" : member.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text("Lv\(member.level)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("HP \(member.hp)/\(member.mhp)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(member.hp * 4 < max(1, member.mhp) ? .red : .secondary)
                Text("MP \(member.mp)/\(member.mmp)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 页脚

struct CheatFooter: View {
    @ObservedObject var controller: CheatController

    var body: some View {
        HStack(spacing: 8) {
            if let error = controller.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                Text("\(error.code.rawValue)：\(error.message)")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if !controller.lastAction.isEmpty {
                Text(controller.lastAction)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text(controller.isAvailable ? "就绪" : "未连接")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if controller.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - 状态页

struct CheatStatusPage: View {
    @ObservedObject var controller: CheatController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("运行状态")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("刷新全部") {
                        Task { await controller.refreshAll() }
                    }
                    .disabled(locked)
                }

                if let snapshot = controller.snapshot {
                    VStack(alignment: .leading, spacing: 4) {
                        CheatKeyValue(key: "场景", value: snapshot.scene.isEmpty ? "—" : snapshot.scene)
                        CheatKeyValue(key: "地图", value: snapshot.mapName.isEmpty ? "\(snapshot.mapId)" : "\(snapshot.mapId) \(snapshot.mapName)")
                        CheatKeyValue(key: "金币", value: "\(snapshot.gold)")
                        CheatKeyValue(key: "帧数", value: "\(snapshot.frames)")
                        CheatKeyValue(key: "倍速", value: String(format: "×%.2f", snapshot.speed))
                        CheatKeyValue(key: "无敌", value: snapshot.godMode ? "开" : "关")
                        if let player = snapshot.player {
                            CheatKeyValue(
                                key: "玩家",
                                value: "(\(player.x),\(player.y)) 朝向\(player.directionLabel)\(player.through ? " · 穿墙" : "")"
                            )
                        }
                    }
                } else {
                    Text("还没有快照：游戏进入地图后每秒自动刷新一次。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                Text("队伍")
                    .font(.system(size: 12, weight: .semibold))
                let party = controller.snapshot?.party ?? []
                if party.isEmpty {
                    Text("队伍为空（还在标题画面时是正常的）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(party) { member in
                        HStack(spacing: 10) {
                            Text(member.name.isEmpty ? "#\(member.id)" : member.name)
                                .font(.system(size: 12))
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)
                            Text("Lv\(member.level)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 44, alignment: .leading)
                            Text("HP \(member.hp)/\(member.mhp)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(member.hp * 4 < max(1, member.mhp) ? .red : .secondary)
                            Text("MP \(member.mp)/\(member.mmp)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }

                Divider()

                Text("快捷修复")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    Button("恢复全队") {
                        Task { await controller.recoverParty() }
                    }
                    Button("修复卡死") {
                        Task { await controller.repair() }
                    }
                    Button("修复错误") {
                        Task { await controller.fixError() }
                    }
                    Button("解锁装备槽") {
                        Task { await controller.unlockEquipmentSlots() }
                    }
                    Button("解除选项锁") {
                        Task { await controller.unlockChoices() }
                    }
                    Spacer()
                }
                .disabled(locked)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }
}

// MARK: - 数值页

struct CheatNumbersPage: View {
    private final class UIState: ObservableObject {
        @Published var tab: Tab = .variables
        @Published var goldText: String = ""
        @Published var query: String = ""
        @Published var page: Int = 0
        @Published var onlyOn: Bool = false
        @Published var drafts: [Int: String] = [:]
    }
    @StateObject private var state = UIState()
    enum Tab: String, CaseIterable, Identifiable {
        case variables = "变量"
        case switches = "开关"
        var id: String { rawValue }
    }

    @ObservedObject var controller: CheatController
    var onDanger: (CheatDanger) -> Void

    /// `id → 输入框草稿`：不写回控制器（它是 `private(set)`），只在本地暂存。

    private let pageSize: Int = 100

    var body: some View {
        VStack(spacing: 0) {
            goldSection
            Divider()
            controls
            Divider()
            if state.tab == .variables {
                variableList
            } else {
                List {
                    ForEach(filteredSwitches) { item in
                        CheatSwitchRow(controller: controller, item: item, locked: locked)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if filteredSwitches.isEmpty {
                        Text(emptyHint).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Divider()
            switchBulkBar
        }
        .onAppear {
            if state.goldText.isEmpty, let snapshot = controller.snapshot {
                state.goldText = "\(snapshot.gold)"
            }
            reload()
        }
        .onChange(of: state.tab) { _ in
            state.page = 0
            state.drafts.removeAll()
            reload()
        }
        .onChange(of: state.onlyOn) { _ in
            state.page = 0
            reload()
        }
    }

    // MARK: 金币

    private var goldSection: some View {
        HStack(spacing: 8) {
            Text("金币")
                .font(.system(size: 12, weight: .semibold))
            CheatNumberField(text: $state.goldText, width: 110)
            Button("应用") {
                guard let value = CheatValueParser.int(state.goldText) else { return }
                Task { await controller.setGold(value) }
            }
            .disabled(locked || CheatValueParser.int(state.goldText) == nil)

            Button("+1000") { Task { await controller.addGold(1_000) } }
                .disabled(locked)
            Button("+10000") { Task { await controller.addGold(10_000) } }
                .disabled(locked)
            Button("上限") {
                state.goldText = "99999999"
                Task { await controller.setGold(99_999_999) }
            }
            .disabled(locked)
            Spacer()
            if let gold = controller.snapshot?.gold {
                Text("当前 \(gold)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 工具条

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $state.tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("搜索名称或 id", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 150)
            }

            if state.tab == .switches {
                Toggle("仅显示开启", isOn: $state.onlyOn)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            Spacer()

            Button("刷新") { reload() }
                .disabled(locked)

            HStack(spacing: 4) {
                Button {
                    state.page = max(0, state.page - 1)
                    reload()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(locked || state.page == 0)
                Text("第 \(state.page + 1) 页")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button {
                    state.page += 1
                    reload()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(locked)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 列表

    private var variableList: some View {
        List {
            ForEach(filteredVariables) { item in
                HStack(spacing: 8) {
                    Text(item.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                    TextField("", text: draftBinding(item))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("应用") {
                        let text = state.drafts[item.id] ?? item.value.cheatDisplayText
                        Task { await controller.setVariable(id: item.id, value: CheatValueParser.json(text)) }
                    }
                    .disabled(locked)
                }
                .padding(.vertical, 1)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if filteredVariables.isEmpty {
                Text(emptyHint).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var switchBulkBar: some View {
        HStack(spacing: 8) {
            if state.tab == .switches {
                Text("批量")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button("全开…") { onDanger(.allSwitches(true)) }
                    .disabled(locked)
                Button("全关…") { onDanger(.allSwitches(false)) }
                    .disabled(locked)
            }
            Spacer()
            Text(state.tab == .variables ? "\(controller.variables.count) 条已加载" : "\(controller.switches.count) 条已加载")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .weakFill(0.05)
    }

    // MARK: 过滤与加载

    private var filteredVariables: [CheatVariable] {
        let items = controller.variables
        guard !state.query.isEmpty else { return items }
        return items.filter { item in
            item.displayName.localizedCaseInsensitiveContains(state.query)
                || String(item.id) == state.query
        }
    }

    private var filteredSwitches: [CheatSwitch] {
        let items = controller.switches
        guard !state.query.isEmpty else { return items }
        return items.filter { item in
            item.displayName.localizedCaseInsensitiveContains(state.query)
                || String(item.id) == state.query
        }
    }

    private var emptyHint: String {
        controller.isAvailable ? "这一页没有匹配的条目" : "未连接游戏"
    }

    private func draftBinding(_ item: CheatVariable) -> Binding<String> {
        Binding(
            get: { state.drafts[item.id] ?? item.value.cheatDisplayText },
            set: { state.drafts[item.id] = $0 }
        )
    }

    private func reload() {
        let from = state.page * pageSize + 1
        Task {
            if state.tab == .variables {
                await controller.refreshVariables(from: from, count: pageSize)
            } else {
                await controller.refreshSwitches(from: from, count: pageSize, onlyOn: state.onlyOn)
            }
        }
    }

    private var locked: Bool { controller.isBusy || !controller.isAvailable }
}

private struct CheatSwitchRow: View {
    @ObservedObject var controller: CheatController
    let item: CheatSwitch
    let locked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.value },
                set: { on in Task { await controller.setSwitch(id: item.id, on: on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(locked)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - 小部件

/// 窄数字输入（面板里出现十几次，统一宽度与等宽字体）。
struct CheatNumberField: View {
    var title: String = ""
    @Binding var text: String
    var width: CGFloat = 78

    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
        }
    }
}

struct CheatKeyValue: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 取值

enum CheatValueParser {
    static func int(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    static func double(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// 输入框 → JSON 值。只认严格的整数/小数、`true`/`false`，其余全是字符串：
    /// `"007"` 必须保持字符串（变量常拿来做编号/电话号码）。
    static func json(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if isStrictNumber(trimmed), let value = Double(trimmed) { return .number(value) }
        return .string(text)
    }

    static func isStrictNumber(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.range(of: "^[+-]?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil
    }
}

extension JSONValue {
    /// 输入框回填用的紧凑文本（对象/数组退化成 JSON）。
    var cheatDisplayText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value == value.rounded() && abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .string(let value): return value
        case .array, .object: return jsonText()
        }
    }
}
