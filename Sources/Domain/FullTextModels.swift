//
//  FullTextModels.swift
//  MochiBox
//
//  V0.6 全文翻译的语料模型（docs/architecture-v0.6-cheat-and-fulltext.md §4.2 / §4.4 / §5）。
//
//  与运行期文本流的关键差别：全文模式的**键是原文 `raw`**（不是 `cacheKey`）。
//  理由（§4.2）：同一句原文在数据表里可能出现几十次（同一个道具名出现在多个商店事件），
//  而 `cacheKey` 是 `sha256(engine|src|tgt|segments)` —— 它适合做缓存命中，不适合做
//  "这份语料还差多少条没翻"的账本（同一个键可能被 10 个不同 raw 共用？不会；但同一个
//  raw 会算出同一个键，反过来按 raw 记账才能把"扫描到的东西"与"翻过的东西"对齐）。
//
//  译文同时保留两种形态：
//    · `translated` —— 整串（含控制码），直接进 `TranslationPushItem.translatedRaw`；
//    · `segments`   —— 分段（code 段沿用原文码值），Agent 用它按**目标行自己的骨架**
//                      重组（BUG-11 的修复依赖这个字段，见 agent_mvmz.js `mergeBySkeleton`）。
//

import Foundation

// MARK: - 常量

enum FullTextConfig {
    /// 全文模式单批条数（§4.3：比实时管线的 20 更小，降低超时概率）。
    static let batchSize: Int = 10
    /// 单批等待上限（秒）。超时把该批判失败，避免一条坏数据卡死整轮。
    static let batchTimeoutSec: Double = 90
    /// 每翻译多少条落一次盘（避免 10k 条每次都整文件重写）。
    static let saveEvery: Int = 100
    /// 等待轮询间隔（毫秒）：主线程上的轻量 tick，不做 CPU 干活。
    static let waitTickMs: Int = 50
    /// 导出/导入的文件名（MTool 兼容，§4.4）。
    static let manualFileName: String = "ManualTransFile.json"
    /// 语料条数上限（防御：病态游戏的地图数据可能枚举出几十万条）。
    static let maxEntries: Int = 100_000
    /// 一轮里最多修几条术语违例（术语表本身有问题时不能把整轮翻译翻倍）。
    static let repairLimit: Int = 200
}

// MARK: - 取批顺序

/// 全文翻译的取批规则（纯函数：给定顺序与游标算出这一批，不碰语料）。
///
/// 为什么按 rank 分组、而不是全局排序后取前 N 条：名称（`entityName`）与对话
/// （`dialogue`）落在 rank 交界处时，一批里既有名称又有引用它的句子；而名称要等
/// **回包**才会被 `learnTermIfNeeded` 学进术语表，同批的引用句在发请求时就拿不到它，
/// 只能靠模型自由发挥（「咬人水母」被译成「刺人水母」）。
/// 分组取批让「名称整组翻完并锁进术语表」成为下一组启程的前置条件。
///
/// 语义（游标单调前进）：
///  · **peek 不消费**：先看游标所在的 rank 组，只有真正取走的条目才推进游标；
///  · 只取从游标起第一个「还有可翻条目」的 rank 组，最多 `limit` 条；
///  · 整组都是已译/blocked 时，游标整组推进后**继续看下一组** —— 绝不能因为这一组
///    没东西就返回空数组，否则 `translate()` 的 while 循环会直接 break，后面的
///    对话永远不会被翻译。
enum FullTextWorkOrder {
    static func nextBatch(
        order: [String],
        rankOf: (String) -> Int,
        cursor: inout Int,
        isTranslated: (String) -> Bool,
        isBlocked: (String) -> Bool,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        var position = min(max(0, cursor), order.count)
        while position < order.count {
            let rank = rankOf(order[position])
            var groupEnd = position
            while groupEnd < order.count && rankOf(order[groupEnd]) == rank {
                groupEnd += 1
            }
            var batch: [String] = []
            batch.reserveCapacity(min(limit, groupEnd - position))
            var index = position
            while index < groupEnd && batch.count < limit {
                let raw = order[index]
                index += 1
                if isTranslated(raw) || isBlocked(raw) { continue }
                batch.append(raw)
            }
            if !batch.isEmpty {
                // 停在**这一组内**：组里没取完的下次继续（不跨 rank 混批）。
                cursor = index
                return batch
            }
            // 整组没有可翻条目：消费掉这一组，继续往后找。
            position = groupEnd
            cursor = groupEnd
        }
        cursor = order.count
        return []
    }
}

// MARK: - 阶段

enum FullTextPhase: String, Codable, Sendable {
    case idle
    case scanning
    case translating
    case done
    case cancelled
    case failed

    var uiLabel: String {
        switch self {
        case .idle: return "未开始"
        case .scanning: return "扫描中…"
        case .translating: return "翻译中…"
        case .done: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        }
    }

    var isRunning: Bool {
        return self == .scanning || self == .translating
    }
}

/// 译文来源。人工译文优先于机翻（§4.5），导入时用它决定是否覆盖。
enum FullTextOrigin: String, Codable, Sendable {
    case machine
    case manual
    case cache

    var uiLabel: String {
        switch self {
        case .machine: return "机翻"
        case .manual: return "人工"
        case .cache: return "缓存"
        }
    }
}

// MARK: - 条目

struct FullTextEntry: Codable, Sendable, Equatable, Identifiable {
    /// 原文整串（含控制码）。**身份**，去重键。
    var raw: String
    /// `actor` / `item` / `map` / `runtime` …（`ScanItem.source`）。
    var source: String
    /// 数据表内的位置（`items.7.name`），只用于排障。
    var path: String
    /// 译文整串（含控制码）；`nil` = 未译。
    var translated: String?
    /// 译文分段（与 `raw` 的文本段数一致）；`nil` = 只有整串、没有段证据。
    var segments: [Segment]?
    var origin: FullTextOrigin
    /// 翻译这条时用的缓存 profile（提示词版本 + 类别 + 术语表指纹）。
    /// 空 = 旧数据（升级前写的）或没走模型（术语短路）。
    var profile: String = ""
    /// 质量问题（`FullTextQuality.Issue` 的 rawValue）。只标记，不自动重试。
    var issues: [String] = []

    /// 由扫描路径推导，不落盘（规则变化时不需要迁移旧文件）。
    var category: TranslationCategory {
        return TranslationCategory.inferred(source: source, path: path)
    }

    init(
        raw: String,
        source: String = "",
        path: String = "",
        translated: String? = nil,
        segments: [Segment]? = nil,
        origin: FullTextOrigin = .machine,
        profile: String = "",
        issues: [String] = []
    ) {
        self.raw = raw
        self.source = source
        self.path = path
        self.translated = translated
        self.segments = segments
        self.origin = origin
        self.profile = profile
        self.issues = issues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = c.tolerantValue(String.self, forKey: .raw, "")
        self.source = c.tolerantValue(String.self, forKey: .source, "")
        self.path = c.tolerantValue(String.self, forKey: .path, "")
        self.translated = c.tolerantOptional(String.self, forKey: .translated)
        self.segments = c.tolerantOptional([Segment].self, forKey: .segments)
        self.origin = FullTextOrigin(rawValue: c.tolerantValue(String.self, forKey: .origin, "")) ?? .machine
        self.profile = c.tolerantValue(String.self, forKey: .profile, "")
        self.issues = c.tolerantValue([String].self, forKey: .issues, [])
    }

    var id: String { raw }

    var isTranslated: Bool {
        guard let translated = translated else { return false }
        return !translated.isEmpty
    }
}

// MARK: - 语料

/// 扫描结果的归并容器。纯值类型（可测、可拷），去重与顺序都在这里。
struct FullTextCorpus: Sendable, Equatable {
    private(set) var byRaw: [String: FullTextEntry] = [:]
    /// 首次出现的顺序（决定翻译批次的顺序：数据表顺序比哈希顺序有意义）。
    private(set) var order: [String] = []

    init() {}

    var count: Int { return order.count }

    /// 已译条数。
    var translatedCount: Int {
        var total = 0
        for raw in order where byRaw[raw]?.isTranslated == true {
            total += 1
        }
        return total
    }

    /// 未译条数。
    var untranslatedCount: Int { return count - translatedCount }

    var all: [FullTextEntry] {
        var result: [FullTextEntry] = []
        result.reserveCapacity(order.count)
        for raw in order {
            if let entry = byRaw[raw] { result.append(entry) }
        }
        return result
    }

    func entry(for raw: String) -> FullTextEntry? {
        return byRaw[raw]
    }

    /// 插入或合并一条扫描结果。**不覆盖已有的译文**（重扫不该把翻好的丢掉）。
    ///
    /// - Returns: 是否是**新**原文。
    @discardableResult
    mutating func insert(raw: String, source: String, path: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if var existing = byRaw[raw] {
            // 只补齐缺失的定位信息；译文/分段一律不动。
            if existing.source.isEmpty { existing.source = source }
            if existing.path.isEmpty { existing.path = path }
            byRaw[raw] = existing
            return false
        }
        guard order.count < FullTextConfig.maxEntries else { return false }
        byRaw[raw] = FullTextEntry(raw: raw, source: source, path: path)
        order.append(raw)
        return true
    }

    /// 写入译文（机翻/缓存/人工都用这一条路径）。
    mutating func applyTranslation(
        raw: String,
        translated: String,
        segments: [Segment]?,
        origin: FullTextOrigin,
        profile: String = "",
        issues: [String] = []
    ) {
        guard var entry = byRaw[raw] else { return }
        // 人工译文不被机翻覆盖（§4.5：导入优先于机翻）。
        if entry.origin == .manual && origin != .manual { return }
        entry.translated = translated
        if let segments = segments { entry.segments = segments }
        entry.origin = origin
        entry.profile = profile
        entry.issues = issues
        byRaw[raw] = entry
    }

    /// 清掉译文但**保留 origin 与 profile**：术语违例重译专用。
    ///
    /// 不能用 `resetTranslation`：它把 origin 打成 `.machine`、清空 profile，
    /// 「按新术语重翻」的 stale 判定与人工译文保护都会错位（人工条目还会被顺带吃掉）。
    mutating func beginRepair(raw: String) {
        guard var entry = byRaw[raw] else { return }
        entry.translated = nil
        entry.segments = nil
        entry.issues = []
        byRaw[raw] = entry
    }

    /// 清掉一条的译文（保留原文/来源/路径）。「按术语重翻」用；人工条目由调用方跳过。
    mutating func resetTranslation(raw: String) {
        guard var entry = byRaw[raw] else { return }
        entry.translated = nil
        entry.segments = nil
        entry.origin = .machine
        entry.profile = ""
        entry.issues = []
        byRaw[raw] = entry
    }

    mutating func clear() {
        byRaw.removeAll()
        order.removeAll()
    }

    /// 用一份持久化文件（`{原文:译文}`）填充语料。已有的机翻被文件内容覆盖。
    ///
    /// - Parameter origins: 落盘的 per-entry 来源。缺省（旧文件）按 `.cache` 处理。
    mutating func mergePersisted(
        entries: [String: String],
        segments: [String: [Segment]]?,
        origins: [String: String]? = nil,
        profiles: [String: String]? = nil,
        issues: [String: [String]]? = nil
    ) {
        for (raw, translated) in entries {
            guard !raw.isEmpty, !translated.isEmpty else { continue }
            let origin = origins?[raw].flatMap(FullTextOrigin.init(rawValue:)) ?? .cache
            if byRaw[raw] == nil {
                byRaw[raw] = FullTextEntry(
                    raw: raw,
                    translated: translated,
                    segments: segments?[raw],
                    origin: origin,
                    profile: profiles?[raw] ?? "",
                    issues: issues?[raw] ?? []
                )
                order.append(raw)
            } else {
                applyTranslation(
                    raw: raw,
                    translated: translated,
                    segments: segments?[raw],
                    origin: origin,
                    profile: profiles?[raw] ?? "",
                    issues: issues?[raw] ?? []
                )
            }
        }
    }

    /// 清掉"熔断/直通降级"被当成译文写进来的假译文。
    ///
    /// 判据三条同时成立：
    ///   · 来源不是人工（origin != .manual）；
    ///   · 有译文；
    ///   · normalizeForKey(translated) == normalizeForKey(raw) —— 机翻把原文原样回填。
    ///
    /// 为什么只豁免人工：合法的"原文==译文"（HP / OK / 专有名词）来自人工导入或
    /// 术语表 keepAsIs 短路。keepAsIs 是 0 请求短路，清掉后重跑会自动补回；
    /// 而人工值是用户亲手写的，任何自动清理都不该碰。
    ///
    /// - Returns: 被清理的条数。只清这三个字段，raw/source/path/category 原样保留，
    ///   条目回到"未译"状态，下一轮全文翻译会重新请求。
    @discardableResult
    mutating func purgePassthroughMachineTranslations() -> Int {
        var purged = 0
        for raw in order {
            guard var entry = byRaw[raw] else { continue }
            guard entry.origin != .manual else { continue }
            guard let translated = entry.translated, !translated.isEmpty else { continue }
            guard Segmenter.normalizeForKey(translated) == Segmenter.normalizeForKey(raw) else { continue }
            entry.translated = nil
            entry.segments = nil
            entry.issues = []
            byRaw[raw] = entry
            purged += 1
        }
        return purged
    }
}

// MARK: - 进度

struct FullTextProgress: Sendable, Equatable {
    var phase: FullTextPhase = .idle
    /// 扫描已发现的条数（chunk 累加）。
    var discovered: Int = 0
    /// 已译条数。
    var translated: Int = 0
    /// 命中缓存条数（已计入 `translated`）。
    var cached: Int = 0
    /// 失败条数。
    var failed: Int = 0
    /// 扫描结束时 Agent 报的跳过条数（纯数字/纯 ASCII 等）。
    var scanSkipped: Int = 0
    /// 本轮待翻条数（翻译开始时固定，进度条分母）。
    var pending: Int = 0

    var remaining: Int { return max(0, pending - translated - failed) }

    /// 0…1；`pending == 0` 时按"无待办"给 1。
    var fraction: Double {
        guard pending > 0 else { return 1 }
        let done = min(pending, translated + failed)
        return Double(done) / Double(pending)
    }

    var percentText: String {
        return String(format: "%.0f%%", fraction * 100)
    }
}

// MARK: - 失败条目

/// 翻译失败的条目（UI 的"重试失败项"列表）。
struct FullTextFailure: Sendable, Equatable, Identifiable {
    var raw: String
    var error: ErrorInfo

    var id: String { raw }

    /// 列表行文案：原文压到一行，太长的截断（对话可能几百字）。
    var displayText: String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}

// MARK: - 一轮翻译的收尾判定

/// 一轮翻译结束后阶段 / 提示 / 错误的判定，**纯函数**（不碰 UI，可直接单测）。
///
/// 为什么需要它：整轮 0 条新增、N 条失败时，旧实现照样把阶段置成 .done（绿色
/// 「已完成」），失败原因（finish_reason=length / 调大最大输出 tokens）只写在日志里 ——
/// 用户看到的是一个"成功"的界面和一份一句都没翻的语料。
enum FullTextOutcome {
    /// 收尾动作：落到 FullTextController 的 phase / notice / lastError。
    struct Summary: Sendable, Equatable {
        var phase: FullTextPhase
        /// 非空才覆盖 notice（pushAll 之后应用，别被"已下发 N 条"盖掉）。
        var notice: String
        /// 非空才覆盖 lastError；文案里必须带第一条失败的具体原因。
        var error: String?
    }

    /// - Parameters:
    ///   - translatedThisRun: **本轮新增**的译文条数（不是累计）。
    ///   - failedCount: 本轮失败条数。
    ///   - firstMessage: failures.first?.error.message。
    static func summary(translatedThisRun: Int, failedCount: Int, firstMessage: String?) -> Summary {
        guard failedCount > 0 else {
            return Summary(phase: .done, notice: "", error: nil)
        }
        let reason = (firstMessage?.isEmpty == false ? firstMessage! : "后端没有返回可读的错误信息")
        if translatedThisRun <= 0 {
            return Summary(
                phase: .failed,
                notice: "",
                error: "本轮没有任何新增译文，失败 \(failedCount) 条：\(reason)"
            )
        }
        return Summary(
            phase: .done,
            notice: "本轮新增 \(translatedThisRun) 条，失败 \(failedCount) 条：\(reason)",
            error: nil
        )
    }
}

// MARK: - 人工译文导入结果

struct ManualImportResult: Sendable, Equatable {
    /// 实际可用的条目（已剔除"原文==译文"与空值）。
    var accepted: Int
    /// 文件里的总键数。
    var total: Int
    /// 原文==译文（视为未译）而被忽略的条数。
    var untranslated: Int
    /// 与已有译文不同的条数（UI 展示"覆盖了 N 条"）。
    var conflicts: Int

    var summary: String {
        return "导入 \(accepted)/\(total) 条（未译 \(untranslated)，覆盖 \(conflicts)）"
    }
}

// MARK: - 扫描过滤

/// Host 侧的扫描过滤（§4.2）。Agent 已经过滤了纯数字/纯 ASCII/纯符号，
/// 这里只补"插件指令行"这一条可开关的规则。
enum FullTextFilter {
    /// 形如 `<TP>`、`<Custom Move Route: ...>` 的行：给插件看的指令，翻它只会破坏功能。
    static func isPluginLine(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return true }
        // 注释里以 `<...>` 开头的行（MZ 插件常用 `<Word:xxx>` 做标记）。
        if trimmed.contains("<") && trimmed.contains(">") && trimmed.count < 120 {
            let firstOpen = trimmed.firstIndex(of: "<")
            let firstClose = trimmed.firstIndex(of: ">")
            if let open = firstOpen, let close = firstClose, close > open {
                let head = trimmed[trimmed.startIndex..<open]
                if head.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            }
        }
        return false
    }
}
