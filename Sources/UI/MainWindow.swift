//
//  MainWindow.swift
//  MochiBox
//
//  主窗口：库列表 + 会话控制 + 右栏（翻译流 / 作弊 / 全文）+ 设置 sheet + 首启合规 alert。
//  V0.6 起右栏是三段切换，作弊与全文分别在 CheatPanel.swift / FullTextPanel.swift。
//  仅使用 macOS 13 可用的 SwiftUI API（不使用 @Observable / Table 的 14+ 重载 / NavigationSplitView）。
//

import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

// MARK: - 右栏分段

/// 右栏三段：`翻译流` 是 P0 的既有主视图，`作弊` / `全文` 是 V0.6 新增
/// （docs/architecture-v0.6-cheat-and-fulltext.md §6）。后两段只在会话连上 MV/MZ 后可用。
enum RightPane: String, CaseIterable, Identifiable {
    case stream = "翻译流"
    case cheat = "作弊"
    case fullText = "全文"

    var id: String { rawValue }

    var isAgentPane: Bool { self != .stream }
}

// MARK: - 主窗口

struct MainWindow: View {
    private final class UIState: ObservableObject {
        @Published var rightPane: RightPane = .stream
    }
    @StateObject private var state = UIState()
    @EnvironmentObject private var app: AppState
    /// 滑杆是否正在被拖动：拖动中只改 `fontScaleDraft`（本地即时显示），不发 RPC。
    @State private var isFontSliderEditing = false
    /// 键盘快捷键的 debounce 句柄（连按时只提交最后那个值）。
    @State private var fontScaleCommitTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            libraryPane
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 380)
            VStack(spacing: 0) {
                sessionHeader
                Divider()
                rightPaneSwitcher
                Divider()
                rightPaneContent
                Divider()
                statusBar
            }
            .frame(minWidth: 620)
            // 右栏**不再**单独铺材质：全窗只有 `WindowChrome` 那一层 behindWindow 模糊，
            // 左右两栏都直接坐在它上面。原先这里再叠一层 .sidebar 材质，两层各自独立
            // 采样桌面再叠加，右栏被压暗洗掉一部分、左栏没有 → 左右色差（用户报的
            // "颜色与模糊不统一"）。层次改由 HSplitView 的分隔线与各区块的 Divider 表达。
        }
        .frame(minWidth: 920, minHeight: 580)
        // 内容区透出窗口级毛玻璃（`WindowChrome` 负责把材质装到窗口最底层）。
        .background(WindowChrome())
        // 压暗层：两个外观都是 0 —— 只剩一层模糊之后，0.22 的黑会把整窗压暗一档（见 Appearance.dim）。
        .dimOverlay()
        .toolbar { toolbarContent }
        .onAppear {
            app.onAppear()
            app.fontScaleDraft = app.settings.fontScale
        }
        .onChange(of: app.settings.fontScale) { newValue in
            app.fontScaleDraft = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .mochiBoxAddGame)) { _ in
            pickGames()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mochiBoxMainWindowWillClose)) { _ in
            // 关主窗口必须把游戏一起收：内置内核的 NSWindow 还在时，App 不会触发
            // `lastWindowClosed`，静态服务与 WebContent 进程就一直挂在后台。
            Task { await app.stopSession() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mochiBoxFontUp)) { _ in
            adjustFontScale(by: 0.05)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mochiBoxFontDown)) { _ in
            adjustFontScale(by: -0.05)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(isPresented: $app.showSettings) {
            SettingsSheet().environmentObject(app)
        }
        .alert("使用前须知", isPresented: $app.showCompliance) {
            Button("我已知悉") {
                app.acknowledgeCompliance()
            }
        } message: {
            Text("""
            1. 你需自行拥有所加载游戏的使用权；本工具不提供、不分发任何游戏内容，也不绕过任何授权或加密。
            2. 本工具不绕过授权：仅通过浏览器调试协议读取游戏运行时的绘制文本并回填译文。
            3. 采集到的文本会发送到你自行配置的翻译后端（默认「直通」模式不产生任何网络请求）。

            继续使用即表示你已知悉以上三点。
            """)
        }
        .alert("清空本地缓存？", isPresented: $app.showClearCacheConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await app.clearCache() }
            }
        } message: {
            Text("将删除 cache.jsonl 中的全部译文记录，此操作不可撤销。")
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 语言/后端/连通状态**不放在 toolbar**：toolbar 的最后一项会被窗口右上角
        // 的圆角压住（macOS 26 的圆角半径大于 toolbar 的默认右边距，用户实测
        // 文字仍然贴着圆角）。它们现在在 `sessionHeader` 的第二行，内容区自带
        // 12pt 内边距，窗口再窄也不会跑出圆角矩形。
        ToolbarItem(placement: .primaryAction) {
            Button {
                app.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置（⌘,）")
        }
    }

    private var readinessColor: Color {
        switch app.session.state {
        case .attached, .translating: return .green
        case .idle, .stopped: return .gray
        case .failed: return .red
        default: return .orange
        }
    }

    // MARK: 右栏切换

    /// 只有 `attached` / `translating` 才允许进入作弊与全文页（§6）。
    private var isSessionReady: Bool {
        switch app.session.state {
        case .attached, .translating: return true
        default: return false
        }
    }

    private var isMVMZ: Bool {
        guard let engine = app.selectedGame?.engine else { return false }
        return engine == .mv || engine == .mz
    }

    private var sessionGateReason: String {
        switch app.session.state {
        case .idle: return "未连接：先启动游戏并等待「已连接」"
        case .launching: return "启动中…"
        case .attaching: return "连接中…"
        case .stopped: return "会话已停止"
        case .failed: return "连接失败"
        case .attached, .translating: return ""
        }
    }

    private var rightPaneSwitcher: some View {
        HStack(spacing: 10) {
            // 三段永远可点：未连接时进作弊/全文看到的是 `lockedPane`（带原因与操作指引），
            // 比"点了没反应"清楚得多。曾经的"在 binding 上拒绝切换"确实能让用户
            // 不困在禁用页里，但代价是**点击完全无反馈** —— 那正是被当成 bug 报上来的行为。
            Picker("", selection: $state.rightPane) {
                ForEach(RightPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            if !isSessionReady {
                Text("可以先看面板，连上游戏后才会加载数据（\(sessionGateReason)）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if !isMVMZ {
                Text("当前引擎不支持修改器与全文扫描（仅 MV/MZ）")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var rightPaneContent: some View {
        switch state.rightPane {
        case .stream:
            textStream
        case .cheat:
            if isSessionReady {
                CheatPanel(controller: app.session.cheat)
            } else {
                lockedPane("作弊")
            }
        case .fullText:
            if isSessionReady {
                FullTextPanel(
                    controller: app.session.fullText,
                    gameRoot: app.selectedGame.map { URL(fileURLWithPath: $0.path) },
                    engineSupported: isMVMZ
                )
            } else {
                lockedPane("全文")
            }
        }
    }

    private func lockedPane(_ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
            Text("\(title)暂不可用")
                .font(.subheadline)
            Text(sessionGateReason)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 库

    private var libraryPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("游戏库")
                    .font(.headline)
                Spacer()
                Button {
                    pickGames()
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加游戏（⌘O）")
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: Binding(
                get: { app.selectedGameId },
                set: { newValue in
                    if let newValue = newValue { app.selectGame(id: newValue) }
                }
            )) {
                ForEach(app.games) { game in
                    GameRow(game: game, isRunning: app.runningGameId == game.id)
                        .tag(game.id)
                        .contextMenu {
                            Button("移除") { app.removeGame(id: game.id) }
                        }
                }
            }
            .listStyle(.sidebar)
            // 露出手底下那层整窗材质：不 hidden 的话这张 List 会吃系统的 sidebar 背景，
            // 左栏与右栏（各页都 hidden 了）就不是同一块玻璃。
            .scrollContentBackground(.hidden)
            .overlay {
                if app.games.isEmpty {
                    VStack(spacing: 8) {
                        Text("还没有游戏")
                            .font(.subheadline)
                        Text("点 + 选择目录或 .app，或把文件夹拖进来")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button("添加游戏…") { pickGames() }
                Spacer()
                Text("\(app.games.count) 个")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: 会话头

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(app.selectedGame?.name ?? "未选择游戏")
                    .font(.headline)
                Text(app.selectedGame?.engine.displayName ?? "-")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .weakFill(0.12)
                    .clipShape(Capsule())
                if let game = app.selectedGame, !game.isLaunchable {
                    Text(game.supportLevel.uiLabel)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
                Text(app.session.stateLabel)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                if app.session.port > 0 {
                    Text("端口 \(app.session.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if !app.session.pageURL.isEmpty {
                    Text(app.session.pageURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // 语言对 / 后端 / 连通状态：右对齐的一组静态信息。
                // 放在这里而不是 toolbar —— 见 `toolbarContent` 的注释。
                Text("日本語 → 简体中文")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(app.settings.backendType.uiLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .weakFill(0.15)
                    .clipShape(Capsule())
                // 熔断期必须显示"约 N 秒后自动重试"（PRD P0-13），不能只留一个红点
                // 让用户以为翻译彻底坏了、去点"立即重试"。
                if app.session.backendStatus != .ok {
                    Text(app.session.backendStatus.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .fixedSize()
                }
                Circle()
                    .fill(readinessColor)
                    .frame(width: 8, height: 8)
            }

            if let error = app.session.lastError {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error.message).font(.caption)
                        if let status = error.httpStatus {
                            Text("HTTP \(status)").font(.caption2).foregroundColor(.secondary)
                        }
                        if let snippet = error.rawSnippet {
                            Text(snippet)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("\(error.code.rawValue)：\(error.message)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            HStack(spacing: 8) {
                Button("启动") {
                    Task { await app.startSession() }
                }
                .disabled(!(app.selectedGame?.isLaunchable ?? false) || app.session.state != .idle && app.session.state != .stopped && app.session.state != .failed)

                Button("停止") {
                    Task { await app.stopSession() }
                }
                .disabled(app.session.state == .idle)

                Button("重连") {
                    Task { await app.reconnectSession() }
                }
                .disabled(app.session.state == .idle && app.selectedGame == nil)

                Button("清空文本流") {
                    app.clearStream()
                }

                Spacer()

                // 一个真相：全局 settings.agentEnabled（落盘见 AppState.setTranslationEnabled）。
                // 不做 per-game 字段：同一个开关换了游戏仍是同一个问题“这游戏要不要翻译”。
                Button(app.settings.agentEnabled ? "关闭翻译" : "开启翻译") {
                    app.setTranslationEnabled(!app.settings.agentEnabled)
                }
                .controlSize(.small)

                Text("字号")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: $app.fontScaleDraft, in: 0.8...1.3, step: 0.05) { editing in
                    isFontSliderEditing = editing
                    if editing {
                        // 开始拖动：作废上一轮还没落地的 debounce。
                        fontScaleCommitTask?.cancel()
                        fontScaleCommitTask = nil
                    } else {
                        commitFontScale()
                    }
                }
                .frame(width: 110)
                .onChange(of: app.fontScaleDraft) { _ in
                    // 拖动中一律不提交（松手由 onEditingChanged 负责）；其余来源
                    // （⌘+ / ⌘-）走 280ms debounce，连按只发最后一次。
                    guard !isFontSliderEditing else { return }
                    scheduleFontScaleCommit()
                }
                Text(String(format: "%.0f%%", app.fontScaleDraft * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
            }

            // 开关的说明单独占一行：controls 那一行还有字号滑杆，
            // 塞进去在 620pt 的右栏里会把滑杆挤没。
            Text("游戏自带中文时点这里，游戏内保留原文")
                .font(.caption2)
                .foregroundColor(.secondary)

            if app.chineseSuspected {
                HStack(spacing: 8) {
                    Text("检测到游戏文本已是中文，已自动跳过翻译")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("仍要翻译") {
                        app.chineseSuspected = false
                        app.setTranslationEnabled(true)
                    }
                    .controlSize(.small)
                }
            }

            if !app.notice.isEmpty {
                Text(app.notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: 文本流

    private var textStream: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("时间").frame(width: 92, alignment: .leading)
                Text("原文").frame(maxWidth: .infinity, alignment: .leading)
                Text("译文").frame(maxWidth: .infinity, alignment: .leading)
                Text("状态").frame(width: 78, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            List(selection: $app.selectedRowId) {
                ForEach(app.stream.rows) { row in
                    TextStreamRow(row: row)
                        .tag(row.id)
                        .contextMenu {
                            Button("复制原文") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.raw, forType: .string)
                            }
                            Button("复制译文") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.translated ?? "", forType: .string)
                            }
                            Button("重新翻译") {
                                Task { await app.session.retranslate(key: row.key) }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if app.stream.rows.isEmpty {
                    Text("等待游戏文本…（启动游戏后这里会出现四列文本流）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("缓存 \(app.cacheStats.entries) 条")
            Text("命中率 \(app.cacheStats.hitRatePercentText)")
            Text("本会话 \(app.stream.rows.count) 句")
            Text("命中 \(app.stream.stats.hits) / 新译 \(app.stream.stats.fresh)")
            if !app.settings.hasUsableBackend {
                Text("未配置翻译后端（直通模式）")
                    .foregroundColor(.orange)
            }
            Spacer()
            Button("清空缓存") { app.showClearCacheConfirm = true }
                .buttonStyle(.borderless)
            Button("设置…") { app.showSettings = true }
                .buttonStyle(.borderless)
            Text("v\(K.appVersion)")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 交互

    private func adjustFontScale(by delta: Double) {
        let next = min(1.3, max(0.8, (app.settings.fontScale * 100).rounded() / 100 + delta))
        // 与滑杆同一个写入口：持久化 → 会话 → 一次 .config。
        app.applyFontScale(next)
    }

    /// 键盘路径的 debounce 提交。
    private func scheduleFontScaleCommit() {
        fontScaleCommitTask?.cancel()
        fontScaleCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            app.applyFontScale(app.fontScaleDraft)
        }
    }

    /// 滑杆松手：立刻提交一次，并作废还在等待的 debounce。
    private func commitFontScale() {
        fontScaleCommitTask?.cancel()
        fontScaleCommitTask = nil
        app.applyFontScale(app.fontScaleDraft)
    }

    private func pickGames() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "选择游戏目录或 .app"
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await app.addGames(urls: urls) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                Task { @MainActor in
                    await app.addGame(url: url)
                }
            }
        }
    }
}

// MARK: - 行视图

private struct GameRow: View {
    let game: GameEntry
    /// 会话是否正跑在这个游戏上（`AppState.runningGameId == game.id`）。
    var isRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(game.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if isRunning {
                    Text("运行中")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.18))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
                if game.missing {
                    Text("已丢失")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text(game.engine.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                // 启动后显示「已启动」而不是一直挂着「可启动」——
                // 用户要从库里一眼看出"现在跑的是哪一个"。
                Text(isRunning ? "已启动" : game.supportLevel.uiLabel)
                    .font(.system(size: 10))
                    .foregroundColor(isRunning || game.supportLevel == .p0 ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TextStreamRow: View {
    let row: TextEvent

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.timeText(row.ts))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(row.raw)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.translated ?? "")
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundColor(row.translated == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(statusColor)
                .frame(width: 78, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var statusText: String {
        if let reason = row.skipReason {
            return "\(row.status.uiLabel)(\(reason))"
        }
        return row.status.uiLabel
    }

    private var statusColor: Color {
        switch row.status {
        case .hit: return .green
        case .translated, .miss: return .blue
        case .pending: return .orange
        case .passthrough: return .secondary
        case .skipped, .paused: return .secondary
        case .error: return .red
        }
    }

    static func timeText(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - 设置

struct SettingsSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    app.saveSettings()
                    dismiss()
                }
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    backendSection
                    advancedSection
                    languageSection
                    fontSection
                    dataPatchSection
                    sessionSection
                    cacheSection
                    complianceSection
                    aboutSection
                }
                .padding(16)
            }
            .frame(width: 520, height: 560)
        }
    }

    private var backendSection: some View {
        GroupBox(label: Text("翻译后端").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("后端", selection: $app.settings.backendType) {
                    Text("直通（离线，不发网络请求）").tag(BackendKind.passthrough)
                    Text("OpenAI 兼容").tag(BackendKind.openai)
                    Text("DeepL").tag(BackendKind.deepl)
                }
                .pickerStyle(.menu)

                TextField("Endpoint（如 http://127.0.0.1:8787）", text: $app.settings.endpoint)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key", text: $app.credentials.apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button(app.probeInProgress ? "测试中…" : "测试连接") {
                        runTest()
                    }
                    .disabled(app.probeInProgress)
                    if !app.probeResultText.isEmpty {
                        Text(app.probeResultText)
                            .font(.caption)
                            .foregroundColor(app.probeResultText.hasPrefix("成功") ? .green : .red)
                    }
                }

                Toggle("允许把文本发送到翻译后端（关闭则强制直通）", isOn: $app.settings.allowSendTextToBackend)
                    .toggleStyle(.checkbox)
                if !app.settings.allowSendTextToBackend {
                    Text("已关闭：保存后后端被强制为直通，不产生任何网络请求。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(6)
        }
    }

    /// 高级设置集中到一个折叠组：这些值只影响吞吐，默认对绝大多数人够用。
    /// 原先散在「翻译后端」（模型）与「会话」（批量/并发/窗口/超时）两处，
    /// 用户找不到"为什么一次只发 10 条"，也就没法对症调。
    private var advancedSection: some View {
        DisclosureGroup("高级设置（OpenAI 兼容）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("模型")
                    Spacer()
                    TextField("如 gpt-4o-mini", text: $app.settings.model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                numberRow("单批条数（1–200）", value: $app.settings.maxBatch)
                numberRow("并发请求数（1–8）", value: $app.settings.maxConcurrent)
                numberRow("合并窗口（毫秒，0–2000）", value: $app.settings.batchWindowMs)
                numberRow("单请求超时（秒，1–120）", value: $app.settings.timeoutSec)
                numberRow("每请求字数上限（500–20000）", value: $app.settings.batchCharBudget)
                numberRow("最大输出 tokens（0 = 自动）", value: $app.settings.maxOutputTokens)
                Picker("禁用推理", selection: $app.settings.reasoningOffMode) {
                    ForEach(ReasoningOffMode.allCases, id: \.rawValue) { mode in
                        Text(mode.uiLabel).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("DeepSeek 官方模型默认开启思考，会占用输出预算导致空内容；自动模式对 api.deepseek.com 发送 thinking.type=disabled，其它端点不发送。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("批量越大越快，但受后端上下文/限流限制；0 = 按输入自动估算。越界值在保存时按括号内范围夹取并记入日志。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    /// 游戏字体：原版 MTool 装 Unifont Smooth，我们默认走系统苹方。
    ///
    /// 只列本机**真能同时渲染中文与假名**的族：迁移到别的机器时族名可能不存在，
    /// Agent 侧还有一条回退链兜底，所以这里不夹取、只 trim（Stores.normalized）。
    private var fontSection: some View {
        GroupBox(label: Text("游戏字体").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("字体", selection: Binding(
                    get: { app.settings.gameFontFamily },
                    set: { app.setGameFontFamily($0) }
                )) {
                    Text("自动（苹方）").tag("")
                    ForEach(fontOptions, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)

                Text("默认使用系统苹方；也可选择本机已安装的字体。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    /// 数据回写：把译文写进 `$data*` 的 name / nickname / messageN 等字段。
    ///
    /// 没有它，「名字 + 状态播报」这类**运行时拼接**的句子没有整串可查（拼好的那句从来
    /// 没进过翻译表），只能保持日文。代价是会动插件也可能读的字段：Live2DInterfaceMZ
    /// 把 `$dataArmors[].name` 当服装动效表的 key、把 `Game_Actor._name` 拿去做换装联动比较。
    /// 两级开关就是给这类游戏留的退路：关子开关只保留播报文本，关总开关整块不写并还原。
    private var dataPatchSection: some View {
        GroupBox(label: Text("游戏数据").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("汉化游戏数据（角色名、状态播报）", isOn: Binding(
                    get: { app.settings.dataPatchEnabled },
                    set: { app.setDataPatchEnabled($0) }
                ))
                .toggleStyle(.checkbox)

                Toggle("包含角色/装备名", isOn: Binding(
                    get: { app.settings.dataPatchNames },
                    set: { app.setDataPatchNames($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!app.settings.dataPatchEnabled)

                Text("关掉「包含角色/装备名」后名字类字段回日文，状态播报、物品说明等仍是中文；若插件（如 Live2D 换装）把名字当表 key 导致功能异常，关它即可。关掉总开关则整块不写，已写的全部还原。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private var fontOptions: [String] {
        let list = Self.gameFontFamilies
        let selected = app.settings.gameFontFamily
        if !selected.isEmpty && !list.contains(selected) { return [selected] + list }
        return list
    }

    /// 探针字符：“汉”与“あ”。两个都得有字形 —— 只覆盖中文的字体画不出假名，
    /// 只覆盖日文的字体缺简化字，任一缺失都会让游戏里出现方块或怪字形。
    private static let gameFontFamilies: [String] = {
        let probes: [UniChar] = [0x6C49, 0x3042]
        var glyphs = [CGGlyph](repeating: 0, count: probes.count)
        return NSFontManager.shared.availableFontFamilies.filter { family in
            let font = CTFontCreateWithName(family as CFString, 13, nil)
            let covered = CTFontGetGlyphsForCharacters(font, probes, &glyphs, probes.count)
            return covered && glyphs.allSatisfy { $0 != 0 }
        }
    }()

    private func numberRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    /// 语言项在 P0 **只读**（PRD v0.3 D-1 / §4.2）：固定 `ja → zh-Hans`，不做下拉框。
    /// 字段仍保留 `srcLang` / `tgtLang`（禁止 `fromLang` / `toLang` 别名），只为 P1 留位。
    private var languageSection: some View {
        GroupBox(label: Text("语言").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("源语言")
                        .frame(width: 72, alignment: .leading)
                    Text("日本語（ja）")
                        .foregroundColor(.primary)
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    Text("简体中文（zh-Hans）")
                        .foregroundColor(.primary)
                    Spacer()
                }
                Text("P0 固定为 日本語 → 简体中文，不支持切换。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("语言对决定缓存分片（cache.ja-zh-Hans.jsonl）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    private var sessionSection: some View {
        GroupBox(label: Text("会话").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("attach 超时（秒）")
                    Spacer()
                    TextField("", value: $app.settings.attachTimeoutSec, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                Text("批量、并发、窗口、单请求超时等调优项在「高级设置」。越界值在保存时回落并记入日志。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    private var cacheSection: some View {
        GroupBox(label: Text("缓存").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("缓存条数")
                    Spacer()
                    Text("\(app.cacheStats.entries)")
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack {
                    Text("命中率")
                    Spacer()
                    Text(app.cacheStats.hitRatePercentText)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack {
                    Text("上限条数")
                    Spacer()
                    TextField("", value: $app.settings.maxCacheEntries, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                Button("清空缓存") {
                    Task { await app.clearCache() }
                }
            }
            .padding(6)
        }
    }

    private var complianceSection: some View {
        GroupBox(label: Text("合规").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("合规声明版本：\(app.settings.complianceAckVersion) / \(K.complianceVersion)")
                    .font(.caption)
                Text("本工具不随包分发任何游戏资源、字体或第三方工具二进制；仅通过本机回环端口与浏览器调试协议工作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    private var aboutSection: some View {
        GroupBox(label: Text("关于").font(.subheadline)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MochiBox \(K.appVersion)")
                    .font(.caption)
                Text("自检：在「终端」执行 …/MochiBox.app/Contents/MacOS/MochiBox --selftest")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    private func runTest() {
        app.probeInProgress = true
        app.probeResultText = ""
        let settings = app.settings
        let credentials = app.credentials
        Task {
            var result: (ok: Bool, status: Int?, latencyMs: Int, error: ErrorInfo?)
            switch settings.backendType {
            case .passthrough:
                result = (true, nil, 0, nil)
            case .openai:
                let provider = OpenAICompatibleProvider(
                    endpoint: settings.endpoint,
                    apiKey: credentials.apiKey,
                    model: settings.model
                )
                result = await provider.probe(timeoutMs: settings.timeoutSec * 1000)
            case .deepl:
                let provider = DeepLProvider(endpoint: settings.endpoint, apiKey: credentials.deeplApiKey)
                result = await provider.probe(timeoutMs: settings.timeoutSec * 1000)
            }
            await MainActor.run {
                app.probeInProgress = false
                if result.ok {
                    app.probeResultText = "成功（\(result.latencyMs)ms）"
                } else {
                    let status = result.status.map { "HTTP \($0)" } ?? "无状态码"
                    app.probeResultText = "失败：\(result.error?.code.rawValue ?? "unknown") \(status)"
                }
            }
        }
    }
}
