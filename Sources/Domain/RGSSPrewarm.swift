//
//  RGSSPrewarm.swift
//  MochiBox
//
//  RGSS（XP / VX / VX Ace）启动预译：游戏一启动就只读扫描 Data/ 的数据表与事件页，
//  把“将要显示的文本”按运行时**同一公式**算 cacheKey，命中缓存就跳过、未命中再
//  submit(.low) 进现有管线。于是首次显示时 cacheKey 已经在缓存里，hook 的 120ms 闸
//  内直接拿译文，不再等 P50≈997ms 的 provider。
//
//  ## 为什么是预译，不是调闸
//
//  hook 的读超时是 120ms（docs/rgss-text-channel.md §8.2），真实 provider P50=997ms、
//  P90=1227ms —— 差距 6.9~10.2 倍，任何“再等久一点”都只会卡游戏主线程。首遍原文是
// 刻意取舍，唯一的解法是把翻译提前到“显示之前”，即本文件。
//
//  ## 边界（刻意的）
//
//    · 不阻塞启动 / attach：SessionController 用 detached Task 调 run()，run() 只做
//      只读扫描 + 入队，**不 await provider 结果**（不做 flush、不等译文）。
//    · 不调 resolve()：resolve 会跑 SkipRules + 查缓存 + 以 .high 入队。预译必须自己
//      走 SkipRules → cache.get → submit(.low)：.low 让运行时的 .high 永远优先，
//      启动瞬间的对话不会被这 3000 条预热条目挡在后面。
//    · 只读：只解析 Marshal 字节，不调用 serialize()，不改游戏目录。
//    · 失败只降级：任何解析 / IO 错误只记日志与计数，不抛、不改会话状态。
//    · 关闭或直通时不写任何缓存：直通写进去的是“原文→原文”，会把后续正常翻译挡在
//      缓存外面（与 RGSSPipelineTranslator 对 .passthrough 的处理同一条理由）。
//
//  ## 取哪些文本（白名单，不是 textEntries 全量）
//
//  事件指令只按 command code + 参数下标取：
//    101  首行 —— **只对 XP**；VX / VX Ace 的 101[0] 是头像文件名（资源名，禁止入缓存）
//    401  对话框逐行 —— VX / VX Ace 各自一条；XP 归入前一条 101 的整段消息
//    405  滚动文章逐行 —— VX / VX Ace
//    102  选项文本（params[0] 数组，逐个）—— VX / VX Ace；XP 并入当前整段消息
//  其余指令的 parameters 一律不取（移动路线、文件名、脚本参数都不是显示文本）。
//
//  数据库只取会显示的字段：name / description / nickname / message1..4；
//  system 取 game_title / currency_unit / terms.* / words.*。
//  地图名、事件名、动画 / 图块名一律不取 —— 它们不是可见对白，进缓存即污染
//  （对应验收：资源文件名不得进缓存）。
//
//  ## XP 的整段消息
//
//  XP 的 Interpreter（Data/Scripts.rxdata 的 Interpreter 3）累积 message_text：
//  command_101 里 message_text = params[0] + "\n"，每个后续 401 追加
//  params[0] + "\n"，command_102 的 setup_choices 又把每个选项追加 text + "\n"；
//  hook 发的就是这个整串（**带尾随换行**，Resources/rgss/mochi_rgss_hook.rb
//  rewrite_rgss1）。所以 XP 必须按 101 开组，把 101 / 401 / 102 的文本都按
//  “text + \n”累加进同一条候选，到 402 分支或其它指令再 flush。
//  写成 join("\n") 会少一个尾随换行、选项还会被拆成独立候选，
//  与运行时的 message_text 永不相等，XP 首句永远命不中。
//  VX / VX Ace 的 hook 对 $game_message.texts 逐行请求，因此不分组。
//
//  ## 顺序与规模
//
//  system → common_events → maps（ID 升序）→ troops（可选）→ 其它数据库（文件名升序）。
//  同一段消息内先 101 组、再 102 选项。Set<cacheKey> 去重，最多 maxSegments 条，
//  submit 每 20 条一批（管线自己按 maxBatch 批处理）。
//

import Foundation

enum RGSSPrewarm {

    // MARK: - 配置

    struct Options: Sendable, Equatable {
        /// 翻译总开关（关闭时预译不跑：扫描无意义，也不该写缓存）。
        var translationEnabled: Bool = true
        /// 实际生效的后端。直通 = 不翻译，预译直接跳过。
        var backend: BackendKind = .openai
        /// 最多选多少条（cacheKey 去重后）。0 = 不预译。
        var maxSegments: Int = 3000
        var includeTroops: Bool = false
        /// 每批 submit 条数。管线到点自己按 maxBatch 再切，这里只控制入队频率。
        var batchSize: Int = 20
        /// 最多读多少个数据文件（防病态工程把启动后台任务拖满）。
        var maxFiles: Int = 2000
        /// 最多抽多少条候选文本（读文件阶段的上限，先于 maxSegments）。
        var maxScannedTexts: Int = 200_000
        /// 扫描阶段软预算（毫秒）：超时停止读文件，已入队的照常翻译。
        var maxScanMs: Int = 20_000

        init() {}

        init(settings: Settings) {
            self.translationEnabled = settings.agentEnabled
            self.backend = settings.effectiveBackend
            self.maxSegments = settings.maxPrewarmSegments
            self.includeTroops = settings.prewarmIncludeTroops
        }
    }

    /// 为什么这条会话/这份测试不该跑预译。nil = 可以跑。
    ///
    /// 与 run(options:) 的守卫同源：设置层的闸（prewarmEnabled / 后端未配置）先在这里
    /// 判掉，SessionController 才不会建一个注定空转的 detached Task；测试也能直接断言
    /// “prewarmEnabled=false 时根本不会发出请求”，不必起 GUI 会话。
    static func skipReason(settings: Settings) -> String? {
        if !settings.prewarmEnabled { return "prewarm_disabled" }
        if settings.effectiveBackend == .passthrough { return "passthrough" }
        if !settings.hasUsableBackend { return "backend_unconfigured" }
        if settings.maxPrewarmSegments <= 0 { return "max_segments_zero" }
        return nil
    }

    /// run(options:) 的守卫原因；与上面的设置层闸分成两个入口，避免把 Settings 拖进扫描器。
    static func skipReason(options: Options) -> String? {
        if !options.translationEnabled { return "translation_disabled" }
        if options.backend == .passthrough { return "passthrough" }
        if options.maxSegments <= 0 { return "max_segments_zero" }
        return nil
    }

    // MARK: - 结果

    /// 一条候选原文。path 只用于日志 / 测试定位（maps[1].events[2].pages[0].list[3].parameters[0]）。
    struct Candidate: Sendable, Equatable {
        var raw: String
        var path: String
        var fileName: String
    }

    struct ScanResult: Sendable, Equatable {
        var candidates: [Candidate] = []
        var filesScanned: Int = 0
        var filesFailed: Int = 0
        /// extractor / walker 产出的候选条数（去重、跳过之前）。
        var textsScanned: Int = 0
        var truncated: Bool = false
        var stopReason: String?
    }

    struct Stats: Sendable, Equatable {
        var filesScanned: Int = 0
        var filesFailed: Int = 0
        var textsScanned: Int = 0
        /// 去重后、通过 SkipRules 的条数（含已命中缓存的）。
        var selected: Int = 0
        /// 被 SkipRules / 无 text 段丢弃的条数。
        var skipped: Int = 0
        var duplicate: Int = 0
        var cacheHit: Int = 0
        var submitted: Int = 0
        var elapsedMs: Int = 0
        var truncated: Bool = false
        var stopReason: String?

        var summaryFields: [String: String] {
            var fields: [String: String] = [
                "files": "\(filesScanned)",
                "texts": "\(textsScanned)",
                "selected": "\(selected)",
                "skipped": "\(skipped)",
                "duplicate": "\(duplicate)",
                "cacheHit": "\(cacheHit)",
                "submitted": "\(submitted)",
                "elapsedMs": "\(elapsedMs)"
            ]
            if filesFailed > 0 { fields["failedFiles"] = "\(filesFailed)" }
            if truncated { fields["truncated"] = "true" }
            if let stopReason { fields["reason"] = stopReason }
            return fields
        }
    }

    // MARK: - 入口

    /// 启动预译。**只入队，不等结果**：调用方用 detached Task 调它，不得 await 译文。
    ///
    /// 任何失败都只降级为“运行时翻译”（也就是预译之前的既有行为），不抛错。
    @discardableResult
    static func run(
        environment: RGSSPipelineEnvironment,
        gameRoot: URL,
        options: Options
    ) async -> Stats {
        let started = Date()
        var stats = Stats()

        func finish(_ reason: String?) -> Stats {
            if let reason { stats.stopReason = reason }
            stats.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            environment.log?.info("RGSSPrewarm", "启动预译结束", stats.summaryFields)
            return stats
        }

        if let reason = skipReason(options: options) { return finish(reason) }

        let scan = scan(gameRoot: gameRoot, options: options)
        stats.filesScanned = scan.filesScanned
        stats.filesFailed = scan.filesFailed
        stats.textsScanned = scan.textsScanned
        stats.truncated = scan.truncated
        stats.stopReason = scan.stopReason

        var seen: Set<String> = []
        var batch: [TranslationRequestItem] = []
        batch.reserveCapacity(max(1, options.batchSize))

        for candidate in scan.candidates {
            if Task.isCancelled { return finish("cancelled") }
            // ① 与运行时同一个 raw → item 公式（含 control-code 骨架 / 术语 / profile）。
            guard let item = RGSSPipelineTranslator.makeRequestItem(
                raw: candidate.raw,
                srcLang: environment.srcLang,
                tgtLang: environment.tgtLang,
                glossaryBox: environment.glossaryBox
            ) else {
                stats.skipped += 1
                continue
            }
            // ② SkipRules 必须先于缓存查询：跳过项不能写缓存、不能发请求（§7.8 同一顺序）。
            if SkipRules.skipReason(
                for: Segmenter.mapKey(item.segments),
                enabled: options.translationEnabled,
                minLength: K.minTranslateLength
            ) != nil {
                stats.skipped += 1
                continue
            }
            // ③ 规模闸门在去重之前：到顶就不再挑新条目。
            if stats.selected >= options.maxSegments {
                stats.truncated = true
                stats.stopReason = stats.stopReason ?? "max_segments"
                break
            }
            if !seen.insert(item.key).inserted {
                stats.duplicate += 1
                continue
            }
            stats.selected += 1
            // ④ 已缓存：不重复提交（缓存查询也用来统计“预译命中率”，便于日志判断收益）。
            if await environment.cache.get(item.key) != nil {
                stats.cacheHit += 1
                continue
            }
            batch.append(item)
            if batch.count >= max(1, options.batchSize) {
                await environment.pipeline.submit(batch, priority: .low)
                stats.submitted += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty && !Task.isCancelled {
            await environment.pipeline.submit(batch, priority: .low)
            stats.submitted += batch.count
        }
        return finish(nil)
    }

    // MARK: - 扫描（同步、纯只读）

    /// 只读扫描 Data/，返回按“system → common_events → maps(ID 升序) → troops → 其它数据库”
    /// 排序的候选原文。单个文件解析失败只计数，不影响其它文件。
    nonisolated static func scan(gameRoot: URL, options: Options) -> ScanResult {
        var result = ScanResult()
        guard let dataRoot = dataDirectory(gameRoot) else {
            result.stopReason = "no_data_dir"
            return result
        }
        let started = Date()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dataRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var files: [(file: RGBSGameFile, url: URL)] = []
        for url in contents {
            guard let file = RGBSGameFile.detect(fileName: url.lastPathComponent) else { continue }
            if file.kind.isScripts { continue }
            switch file.kind {
            case .troops:
                guard options.includeTroops else { continue }
            case .mapInfos, .animations, .tilesets, .other:
                continue
            default:
                break
            }
            files.append((file, url))
        }
        files.sort { sortKey($0.file) < sortKey($1.file) }
        if files.count > options.maxFiles {
            files = Array(files.prefix(max(0, options.maxFiles)))
            result.truncated = true
            result.stopReason = "max_files"
        }

        for (file, url) in files {
            if Date().timeIntervalSince(started) * 1000 > Double(options.maxScanMs) {
                result.truncated = true
                result.stopReason = result.stopReason ?? "scan_time_budget"
                break
            }
            do {
                let document = try RGSSDocument.load(url: url, version: file.version)
                let resolver = TextResolver(entries: document.textEntries())
                let before = result.candidates.count
                collect(document: document, resolver: resolver, into: &result.candidates)
                result.textsScanned += result.candidates.count - before
                result.filesScanned += 1
            } catch {
                result.filesFailed += 1
            }
            if result.candidates.count >= options.maxScannedTexts {
                result.truncated = true
                result.stopReason = result.stopReason ?? "max_texts"
                break
            }
        }
        return result
    }

    // MARK: - 文本解码

    /// 用 extractor 已判定的编码结果按节点身份查文本。
    /// 直接读 MarshalValue.text 是 UTF-8 宽松解码，对 CP932 的 RGSS1/2 会乱码 ——
    /// 编码判定只该有 RGBSTextExtractor 一份。
    struct TextResolver {
        let entries: [RGBSTextEntry]
        private let byNode: [ObjectIdentifier: RGBSTextEntry]

        init(entries: [RGBSTextEntry]) {
            self.entries = entries
            var map: [ObjectIdentifier: RGBSTextEntry] = [:]
            map.reserveCapacity(entries.count)
            for entry in entries {
                map[ObjectIdentifier(entry.node)] = entry
            }
            self.byNode = map
        }

        func text(of value: MarshalValue?) -> String? {
            guard let value, let entry = byNode[ObjectIdentifier(value)] else { return nil }
            return entry.text
        }
    }

    // MARK: - 各文件类型

    private static func collect(document: RGSSDocument, resolver: TextResolver, into out: inout [Candidate]) {
        let file = document.file
        let name = file.fileName
        switch file.kind {
        case .system:
            collectSystem(root: document.root, fileName: name, resolver: resolver, into: &out)
        case .commonEvents:
            guard let records = document.root.arrayElements else { return }
            for (index, record) in records.enumerated() {
                guard let list = record.record?.ivar(named: "list") else { continue }
                collectCommands(
                    list, version: file.version, fileName: name,
                    path: "common_events[\(index)].list", resolver: resolver, into: &out
                )
            }
        case .map(let mapID):
            collectMap(
                root: document.root, mapID: mapID, version: file.version,
                fileName: name, resolver: resolver, into: &out
            )
        case .troops:
            guard let records = document.root.arrayElements else { return }
            for (index, troop) in records.enumerated() {
                guard let pages = troop.record?.ivar(named: "pages")?.arrayElements else { continue }
                for (pageIndex, page) in pages.enumerated() {
                    guard let list = page.record?.ivar(named: "list") else { continue }
                    collectCommands(
                        list, version: file.version, fileName: name,
                        path: "troops[\(index)].pages[\(pageIndex)].list", resolver: resolver, into: &out
                    )
                }
            }
        case .actors, .classes, .skills, .items, .weapons, .armors, .enemies, .states:
            // 这几类文件的 extractor 只产出 recordTextFields（name/description/nickname/message1..4），
            // 都是菜单 / 说明窗会显示的字段：直接复用它的路径与解码结果。
            for entry in resolver.entries {
                guard let text = entry.text, !text.isEmpty else { continue }
                out.append(Candidate(raw: text, path: entry.path, fileName: name))
            }
        default:
            return
        }
    }

    private static func collectSystem(
        root: MarshalValue,
        fileName: String,
        resolver: TextResolver,
        into out: inout [Candidate]
    ) {
        guard let record = root.record else { return }
        for field in ["game_title", "currency_unit"] {
            guard let text = resolver.text(of: record.ivar(named: field)), !text.isEmpty else { continue }
            out.append(Candidate(raw: text, path: "system.\(field)", fileName: fileName))
        }
        for section in ["terms", "words"] {
            guard let value = record.ivar(named: section) else { continue }
            collectStrings(
                value, path: "system.\(section)", fileName: fileName,
                resolver: resolver, into: &out, depth: 0
            )
        }
    }

    private static func collectStrings(
        _ value: MarshalValue,
        path: String,
        fileName: String,
        resolver: TextResolver,
        into out: inout [Candidate],
        depth: Int
    ) {
        guard depth < 8 else { return }
        if let text = resolver.text(of: value) {
            if !text.isEmpty {
                out.append(Candidate(raw: text, path: path, fileName: fileName))
            }
            return
        }
        if let array = value.arrayElements {
            for (index, element) in array.enumerated() {
                collectStrings(
                    element, path: "\(path)[\(index)]", fileName: fileName,
                    resolver: resolver, into: &out, depth: depth + 1
                )
            }
            return
        }
        if let pairs = value.hashPairs {
            for (key, element) in pairs {
                let label = key.symbolName ?? key.text ?? "?"
                collectStrings(
                    element, path: "\(path)[\(label)]", fileName: fileName,
                    resolver: resolver, into: &out, depth: depth + 1
                )
            }
            return
        }
        if let record = value.record {
            for ivar in record.ivars {
                collectStrings(
                    ivar.value, path: "\(path).\(ivar.name.name)", fileName: fileName,
                    resolver: resolver, into: &out, depth: depth + 1
                )
            }
        }
    }

    private static func collectMap(
        root: MarshalValue,
        mapID: Int,
        version: RGSSVersion,
        fileName: String,
        resolver: TextResolver,
        into out: inout [Candidate]
    ) {
        guard let eventsValue = root.record?.ivar(named: "events") else { return }
        let pairs = eventsValue.hashPairs ?? []
        let sorted = pairs.sorted { lhs, rhs in
            (intValue(lhs.key) ?? 0) < (intValue(rhs.key) ?? 0)
        }
        for (key, event) in sorted {
            let eventID = intValue(key) ?? 0
            guard let pages = event.record?.ivar(named: "pages")?.arrayElements else { continue }
            for (pageIndex, page) in pages.enumerated() {
                guard let list = page.record?.ivar(named: "list") else { continue }
                collectCommands(
                    list, version: version, fileName: fileName,
                    path: "maps[\(mapID)].events[\(eventID)].pages[\(pageIndex)].list",
                    resolver: resolver, into: &out
                )
            }
        }
    }

    // MARK: - 事件指令（白名单）

    /// XP 按 101 分组（101[0] 首行 + 后续 401[0] 用 "\n" 拼成整段，与 hook 发的
    /// $game_temp.message_text 完全一致）；VX / VX Ace 逐行取 401 / 405，101[0] 是头像文件名不取。
    private static func collectCommands(
        _ list: MarshalValue,
        version: RGSSVersion,
        fileName: String,
        path: String,
        resolver: TextResolver,
        into out: inout [Candidate]
    ) {
        guard let commands = list.arrayElements else { return }

        if version == .rgss1 {
            // 与 Interpreter#command_101 / command_401 / setup_choices 的累积完全同形：
            // message_text 是「每行文本 + \n」的顺次拼接，选项也并入同一串。
            var group = ""
            var groupPath = ""

            func flush() {
                guard !group.isEmpty else { return }
                out.append(Candidate(raw: group, path: groupPath, fileName: fileName))
                group = ""
                groupPath = ""
            }

            for (index, command) in commands.enumerated() {
                guard let record = command.record,
                      let code = intValue(record.ivar(named: "code")),
                      let params = record.ivar(named: "parameters")?.arrayElements else {
                    flush()
                    continue
                }
                switch code {
                case 101:
                    flush()
                    if let text = resolver.text(of: params.first) {
                        group = text + "\n"
                        groupPath = "\(path)[\(index)].parameters[0]"
                    }
                case 401:
                    guard let text = resolver.text(of: params.first) else { break }
                    group += text + "\n"
                    if groupPath.isEmpty {
                        groupPath = "\(path)[\(index)].parameters[0]"
                    }
                case 102:
                    // 选项不是窗口外的独立文本：setup_choices 把它们逐个追加进
                    // message_text，所以必须并进当前整段（XP 的选项就在消息窗里）。
                    if groupPath.isEmpty {
                        groupPath = "\(path)[\(index)].parameters[0]"
                    }
                    for choice in params.first?.arrayElements ?? [] {
                        guard let text = resolver.text(of: choice) else { continue }
                        group += text + "\n"
                    }
                default:
                    flush()
                }
            }
            flush()
            return
        }

        // RGSS2 / RGSS3：hook 对 $game_message.texts 逐行请求；空行不会被请求，跳过。
        for (index, command) in commands.enumerated() {
            guard let record = command.record,
                  let code = intValue(record.ivar(named: "code")),
                  let params = record.ivar(named: "parameters")?.arrayElements else { continue }
            switch code {
            case 401, 405:
                guard let text = resolver.text(of: params.first), !text.isEmpty else { break }
                out.append(Candidate(
                    raw: text,
                    path: "\(path)[\(index)].parameters[0]",
                    fileName: fileName
                ))
            case 102:
                appendChoices(
                    params, resolver: resolver, fileName: fileName,
                    path: "\(path)[\(index)].parameters[0]", into: &out
                )
            default:
                break
            }
        }
    }

    private static func appendChoices(
        _ params: [MarshalValue],
        resolver: TextResolver,
        fileName: String,
        path: String,
        into out: inout [Candidate]
    ) {
        guard let choices = params.first?.arrayElements else { return }
        for (index, choice) in choices.enumerated() {
            guard let text = resolver.text(of: choice), !text.isEmpty else { continue }
            out.append(Candidate(raw: text, path: "\(path)[\(index)]", fileName: fileName))
        }
    }

    private static func intValue(_ value: MarshalValue?) -> Int? {
        guard let value else { return nil }
        if case .int(let raw) = value.kind { return Int(raw) }
        return nil
    }

    // MARK: - 文件发现

    private static func dataDirectory(_ gameRoot: URL) -> URL? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        for name in ["Data", "data"] {
            let candidate = gameRoot.appendingPathComponent(name)
            if manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        // 少数自制包把数据直接放在根目录。
        return gameRoot
    }

    private static func sortKey(_ file: RGBSGameFile) -> String {
        switch file.kind {
        case .system: return "0|000000|"
        case .commonEvents: return "1|000000|"
        case .map(let id): return String(format: "2|%06d|", id)
        case .troops: return "3|000000|"
        default: return "4|000000|\(file.fileName.lowercased())"
        }
    }
}
