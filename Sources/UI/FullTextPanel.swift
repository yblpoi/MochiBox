//
//  FullTextPanel.swift
//  MochiBox
//
//  V0.6 全文翻译页（docs/architecture-v0.6-cheat-and-fulltext.md §4 / §6）。
//
//  信息层级按"用户下一步要做什么"排：
//    ① 现在在干什么（阶段 + 进度条 + 计数）
//    ② 下一步点哪个（扫描 / 翻译 / 重试 / 取消）
//    ③ 译文怎么进出（导入 / 导出 / 导出到游戏目录）
//    ④ 具体是哪几条（前 500 条 + 搜索）
//
//  `FullTextController` 没有 `isBusy`：它的忙碌态就是 `phase.isRunning`，
//  所以这里的"并发保护"统一看那个。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FullTextPanel: View {
    private enum Pane: String, CaseIterable {
        case corpus = "语料"
        case glossary = "术语"
    }

    private final class UIState: ObservableObject {
        @Published var pane: Pane = .corpus
        @Published var query: String = ""
        @Published var showClear: Bool = false
        @Published var showGameExport: Bool = false
        @Published var showRetranslate: Bool = false
        @Published var importResult: ManualImportResult? = nil
        @Published var onlyQuality: Bool = false
        @Published var glossaryQuery: String = ""
        @Published var newSource: String = ""
        @Published var newTarget: String = ""
    }
    @StateObject private var state = UIState()
    @ObservedObject var controller: FullTextController
    /// `app.selectedGame?.path`：只有"导出到游戏目录"会用到。
    let gameRoot: URL?
    /// 非 MV/MZ 时扫描/翻译/作弊都没有意义（§9 最后一行）。
    let engineSupported: Bool


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panePicker
            Divider()
            if state.pane == .corpus {
                statsRow
                progressRow
                errorBanner
                Divider()
                actions
                Divider()
                fileActions
                if let result = state.importResult {
                    Text("导入结果：成功 \(result.accepted)/\(result.total) · 冲突 \(result.conflicts) · 未译跳过 \(result.untranslated)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
                Divider()
                listHeader
                entryList
            } else {
                glossaryToolbar
                Divider()
                glossaryList
            }
            Divider()
            footer
        }
        .alert("清空全文译文？", isPresented: $state.showClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await controller.clearAll() }
            }
        } message: {
            Text("会停止当前任务，清空本游戏的语料与已落盘的译文文件（\(controller.gameHash.isEmpty ? "当前游戏" : controller.gameHash)）。导入或重扫后才能恢复。")
        }
        .alert("按新术语重翻？", isPresented: $state.showRetranslate) {
            Button("取消", role: .cancel) {}
            Button("重翻") {
                Task { await controller.retranslateStale() }
            }
        } message: {
            Text("会清空 \(controller.staleCount) 条机翻/缓存译文，按当前术语表重新翻译。人工译文一条不动。")
        }
        .alert("导出到游戏目录？", isPresented: $state.showGameExport) {
            Button("取消", role: .cancel) {}
            Button("写入") {
                guard let root = gameRoot else { return }
                Task { await controller.exportToGameDirectory(root) }
            }
        } message: {
            Text("会写入：\n\(targetPathText)\n\n这是本工具唯一会写游戏目录的动作；不修改 data/*.json 或任何游戏数据文件。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("全文翻译")
                .font(.system(size: 12, weight: .semibold))
            Text(controller.phase.uiLabel)
                .font(.system(size: 11))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(phaseColor.opacity(0.14))
                .foregroundColor(phaseColor)
                .clipShape(Capsule())
            if !controller.gameHash.isEmpty {
                Text(controller.gameHash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !engineSupported {
                Text("仅支持 MV/MZ")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            } else if !controller.isAttached {
                Text("未连接")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Toggle("扫描地图", isOn: $controller.includeMaps)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            Toggle("纳入运行期文本", isOn: $controller.includeRuntime)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            Toggle("跳过插件行", isOn: $controller.skipPluginLines)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var panePicker: some View {
        HStack(spacing: 8) {
            Picker("", selection: $state.pane) {
                ForEach(Pane.allCases, id: \.self) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            if state.pane == .glossary && controller.staleCount > 0 {
                Text("\(controller.staleCount) 条可按新术语重翻")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .idle: return .secondary
        case .scanning, .translating: return .blue
        case .done: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    // MARK: 统计

    private var statsRow: some View {
        HStack(spacing: 16) {
            stat("已发现", "\(controller.discovered)")
            stat("已译", "\(controller.translated)", color: .green)
            stat("未译", "\(untranslated)", color: untranslated > 0 ? .orange : .secondary)
            stat("缓存命中", "\(controller.cachedCount)")
            stat("失败", "\(controller.failedCount)", color: controller.failedCount > 0 ? .red : .secondary)
            stat("扫描跳过", "\(controller.scanSkipped)")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var untranslated: Int {
        return max(0, controller.discovered - controller.translated)
    }

    private func stat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            if controller.phase == .scanning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("已收 \(controller.discovered) 条")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                ProgressView(value: min(1, max(0, controller.progress.fraction)))
                    .frame(width: 200)
                Text("\(controller.progress.percentText) · \(controller.translated)/\(max(0, controller.progress.pending))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 错误横幅

    /// 失败原因必须在**界面上**看得到：finish_reason=length / 调大最大输出 tokens
    /// 这类话以前只写进日志，用户只能看到一个绿色的「已完成」和一句都没翻的语料。
    /// 优先 lastError（本轮第一处失败），没有时退回第一条 failure 的 message。
    private var errorText: String? {
        if let error = controller.lastError {
            return "\(error.code.rawValue)：\(error.message)"
        }
        if let first = controller.failures.first {
            return "失败 \(controller.failedCount) 条，第一条：\(first.error.message)"
        }
        return nil
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = errorText {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("翻译失败原因：" + message)
        }
    }

    // MARK: 术语

    private var glossaryToolbar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("搜索原文或译名", text: $state.glossaryQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 220)
                }
                Text("显示 \(visibleTerms.count)/\(controller.glossaryRows.count) 条")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button("按术语重翻") { state.showRetranslate = true }
                    .disabled(!canOperate || controller.staleCount == 0)
                Button("导出…") { runGlossaryExport() }
                    .disabled(!canOperate)
                Button("导入…") { runGlossaryImport() }
                    .disabled(!canOperate)
                Button("恢复内置") {
                    Task { await controller.resetGlossary() }
                }
                .disabled(!canOperate)
            }
            HStack(spacing: 6) {
                TextField("原文（如 レベル）", text: $state.newSource)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 180)
                TextField("锁定译名（如 等级）", text: $state.newTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 180)
                Button("添加") {
                    let source = state.newSource
                    let target = state.newTarget
                    state.newSource = ""
                    state.newTarget = ""
                    controller.setTerm(source: source, target: target)
                }
                .disabled(!canOperate || state.newSource.isEmpty || state.newTarget.isEmpty)
                Spacer()
                Text("术语只用于提示与校验，不改写已译文本；DeepL 后端不支持术语约束")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var visibleTerms: [GlossaryEntry] {
        let all = controller.glossaryRows
        let query = state.glossaryQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(all.prefix(500)) }
        return Array(all.filter {
            $0.source.localizedCaseInsensitiveContains(query)
                || $0.target.localizedCaseInsensitiveContains(query)
        }.prefix(500))
    }

    private var glossaryList: some View {
        List {
            ForEach(visibleTerms, id: \.source) { entry in
                GlossaryRow(entry: entry) { target in
                    controller.setTerm(source: entry.source, target: target)
                }
                .contextMenu {
                    Button("删除术语", role: .destructive) {
                        controller.deleteTerm(source: entry.source)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if visibleTerms.isEmpty {
                Text(controller.glossaryRows.isEmpty
                     ? "还没有术语：扫描后会自动从名称与系统术语学习"
                     : "没有匹配的术语")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func runGlossaryExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "glossary.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "导出 \(controller.glossaryRows.count) 条术语（{原文:译文}）"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.exportGlossary(to: url) }
    }

    private func runGlossaryImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "导入术语表（{原文:译文} 或本工具导出的格式）"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.importGlossary(from: url) }
    }

    // MARK: 动作

    private var actions: some View {
        HStack(spacing: 8) {
            if controller.phase == .scanning {
                Button("取消扫描") {
                    Task { await controller.cancelScan() }
                }
            } else if controller.phase == .translating {
                Button("取消翻译") {
                    controller.cancel()
                }
            } else {
                Button(controller.discovered > 0 ? "重新扫描" : "扫描") {
                    Task { await controller.scan() }
                }
                .disabled(!canOperate)
            }

            Button("翻译未译项") {
                Task { await controller.translate() }
            }
            .disabled(!canOperate || controller.discovered == 0)

            Button("重试失败") {
                Task { await controller.retryFailed() }
            }
            .disabled(!canOperate || controller.failedCount == 0)

            Button("下发译文") {
                Task { await controller.pushAll(force: true) }
            }
            .disabled(!canOperate)

            Spacer()

            Button("清空…") { state.showClear = true }
                .disabled(!controller.isAttached)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var fileActions: some View {
        HStack(spacing: 8) {
            Button("导出…") { runExport() }
                .disabled(!canOperate)
            Button("导入…") { runImport() }
                .disabled(!canOperate)
            Button("导出到游戏目录…") { state.showGameExport = true }
                .disabled(!canOperate || gameRoot == nil)
            if controller.phase == .translating || controller.phase == .scanning {
                Text("任务进行中，导入/导出先等这一轮结束")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: 列表

    private var listHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("搜索原文或译文", text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 220)
                }
                Text("显示 \(visibleRows.count)/\(controller.rows.count) 条（上限 500）")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if controller.qualityCount > 0 {
                    Toggle("只看质量问题（\(controller.qualityCount)）", isOn: $state.onlyQuality)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            HStack(spacing: 0) {
                Text("原文").frame(maxWidth: .infinity, alignment: .leading)
                Text("译文").frame(maxWidth: .infinity, alignment: .leading)
                Text("来源").frame(width: 56, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 3)
        }
    }

    private var entryList: some View {
        List {
            ForEach(visibleRows) { entry in
                FullTextRow(entry: entry)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if visibleRows.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var emptyHint: String {
        if controller.rows.isEmpty {
            return "还没有语料：点「扫描」从游戏数据里枚举全部文本"
        }
        return "没有匹配的条目"
    }

    private var visibleRows: [FullTextEntry] {
        let all = state.onlyQuality ? controller.rows.filter { !$0.issues.isEmpty } : controller.rows
        if state.query.isEmpty {
            return Array(all.prefix(500))
        }
        var output: [FullTextEntry] = []
        for entry in all {
            if entry.raw.localizedCaseInsensitiveContains(state.query)
                || (entry.translated?.localizedCaseInsensitiveContains(state.query) ?? false) {
                output.append(entry)
                if output.count >= 500 { break }
            }
        }
        return output
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // 语料页的错误已经在上方横幅里（可选中的完整文案），footer 不重复一遍。
            if errorText != nil && state.pane == .corpus {
                Text(!controller.notice.isEmpty ? controller.notice : "见上方失败原因")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else if let error = controller.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                Text("\(error.code.rawValue)：\(error.message)")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if !controller.notice.isEmpty {
                Text(controller.notice)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else {
                Text(canOperate ? "就绪" : (engineSupported ? "连接游戏后可用" : "仅支持 MV/MZ"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: 状态

    /// 能发起新任务：已接线 + 引擎支持 + 当前没有在跑的轮次。
    private var canOperate: Bool {
        return controller.isAttached && engineSupported && !controller.phase.isRunning
    }

    private var targetPathText: String {
        guard let root = gameRoot else { return "（未选择游戏）" }
        return root.appendingPathComponent(FullTextConfig.manualFileName).path
    }

    // MARK: 面板

    private func runExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FullTextConfig.manualFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "导出 {原文:译文} 格式的 JSON"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.exportManual(to: url) }
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "导入 {原文:译文} 格式的人工译文（\(FullTextConfig.manualFileName)）"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            if let result = await controller.importManual(from: url) {
                state.importResult = result
            }
        }
    }
}

// MARK: - 行

private struct FullTextRow: View {
    let entry: FullTextEntry

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(flat(entry.raw))
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundColor(entry.isTranslated ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.translated.map(flat) ?? "—")
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundColor(entry.isTranslated ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.isTranslated ? entry.origin.uiLabel : "未译")
                    .font(.system(size: 10))
                    .foregroundColor(entry.isTranslated ? .secondary : .orange)
                if !entry.issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .help(entry.issues.joined(separator: "、"))
                }
            }
            .frame(width: 56, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    /// 对话里常有 `\n`；一行显示不下时压平成空格（与 `FullTextFailure.displayText` 同口径）。
    private func flat(_ text: String) -> String {
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - 术语行

private struct GlossaryRow: View {
    let entry: GlossaryEntry
    let onCommit: (String) -> Void

    @State private var draft: String

    init(entry: GlossaryEntry, onCommit: @escaping (String) -> Void) {
        self.entry = entry
        self.onCommit = onCommit
        _draft = State(initialValue: entry.target)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.source)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: $draft) {
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != entry.target {
                    onCommit(trimmed)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .frame(width: 220)
            Text(entry.kind.uiLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            if entry.edited {
                Text("人工")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
                    .frame(width: 28, alignment: .leading)
            } else {
                Color.clear.frame(width: 28)
            }
        }
        .padding(.vertical, 1)
    }
}
