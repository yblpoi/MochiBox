//
//  TextStreamStore.swift
//  MochiBox
//
//  文本流模型：5000 行环形、**800ms 滑动窗口去重**、status 单点决策、命中率统计。
//  依据 docs/prd.md P0-08 / AC3.1；docs/architecture.md §3.7；docs/archive/v0.4/architecture-v0.4-embedded-kernel.md §6。
//
//  v0.4（OBS-1）：`ingest` 不再"按帧号去重"，而是按**时间窗口**（R0–R5，见 `ingest` 注释）。
//  规则与 `Resources/agent_mvmz.js:510-529` 的 `shouldEmitFor` **逐条同构**：
//  Agent 侧被绕过（重连 / 多客户端 / 页面自己重装 / 旧版 Agent）时，Store 也不能把
//  同一句话写成 10 行 —— AC3.1 问的是"这一行被画了几次"，不是"我们收到了几条事件"。
//

import Foundation
import Combine

@MainActor
final class TextStreamStore: ObservableObject {
    @Published private(set) var rows: [TextEvent] = []
    @Published private(set) var stats: StreamStats = StreamStats()
    @Published private(set) var paused: Bool = false

    var maxRows: Int

    /// R0 退化路径专用的"上一条事件签名"（`frame|identity`）。
    ///
    /// 只在 `ts` 不可用时使用；正常路径一律走时间窗口。**不要**把它挪回主判定：
    /// 按帧分桶是 PRD P0-08 明令禁止的（帧号与"距上次绘制多久"没有关系）。
    private var lastRawSignature: String = ""
    private var occurrencesByIdentity: [String: Int] = [:]
    /// 行身份 → 该身份**最后一行**的**绝对下标**（见 `evictedRowCount`）。
    ///
    /// 存绝对值而不是 `rows` 的相对下标：淘汰是从头部整段 `removeFirst`，相对下标会整体位移，
    /// 每次都把整张表重写一遍 —— 满窗口（5000 行）时每次追加都退化成 O(n) 全表重建。
    /// 绝对下标只增不减，淘汰时只需处理**被淘汰行自己**的条目，追加时 O(1) 插入。
    private var lastRowIndexByIdentity: [String: Int] = [:]
    /// 已从头部淘汰的行数 = `rows[0]` 的绝对下标。
    ///
    /// 绝对下标 − 本值 = `rows` 的相对下标。`clear()` 时归零（两者一起清空）。
    private var evictedRowCount: Int = 0
    private var orderCounter: Int = 0

    init(maxRows: Int = K.maxTextRows) {
        self.maxRows = max(1, maxRows)
    }

    // MARK: - 身份（三层，不得互相替代）

    /// 行身份 = `surface + U+0000 + raw`（PRD P0-08，与 Agent 侧去重签名**同一份**）。
    ///
    /// 用途：去重、`occurrences` 计数、UI 合并与显示。
    ///
    /// **不得**用 `cacheKey` 当行身份：`cacheKey` 的材料是 `normalize(join(text))`，
    /// 也就是"**剥码后的 text**" —— `350` 与 `\C[2]350` 的 `cacheKey` 完全相同，
    /// 拿它当身份会让后者被静默合并掉，原文列再也看不到 `\C[2]350`（P0-08/P0-09 反例）。
    /// 显示身份必须用**实际画出的串**。
    nonisolated static func rowIdentity(surface: String, raw: String) -> String {
        return surface + "\u{0000}" + raw
    }

    // 翻译身份 = `cacheKey`（缓存查找、批量请求、`setTranslation` 下发），存在 `TextEvent.key`。
    //
    // `350` 与 `\C[2]350` **共享**同一个 `cacheKey`（同一句原文），因此：
    //   · 只计费一次（一条批量请求项）；
    //   · 一条后端结果必须**扇出**填满所有共享该键的行（见 `applyTranslation`），
    //     否则其中一行会永远 `pending`，AC2.2b 的"5s 内收敛"直接判失败；
    //   · 这个共享是**设计**，不要"顺手"把它拆开 —— 拆开就是重复计费。
    // 行唯一 id 用 `TextEvent.id`（UUID，每 emit 一条新行一个新 id），UI 选中按它走。

    /// 采集一条 Agent 文本事件。返回刚落库（或被更新）的行。
    ///
    /// - Parameter cacheKey: Host 重算的持久化缓存键（`Segmenter.cacheKey`），写入 `TextEvent.key`
    ///   作为**翻译身份**；行身份另按 `rowIdentity(surface:raw:)` 计算（两者分层，见上）。
    ///   传入时忽略 Agent 上报的 `payload.key`（那个是页面侧 `mapKey`，只进日志）。
    ///
    /// ## 800ms 滑动窗口（R0–R5，架构 v0.4 §6.3；与 Agent `shouldEmitFor` 同构）
    ///
    /// 窗口键 = **行身份**（`surface + U+0000 + raw`），不是 `cacheKey`：
    /// `350` 与 `\C[2]350` 是屏幕上两行不同内容，各自有各自的"上次绘制时刻"。
    /// 用 `cacheKey` 当窗口键会把第二种画法并进第一种（BUG-8 的复现形态）。
    ///
    /// | 步骤 | 条件 | 行为 |
    /// |---|---|---|
    /// | R0 | `ts` 不可用（非有限 / ≤0） | 降级为**严格同帧签名去重**；不动窗口、不动 `occurrences` |
    /// | R1 | 该身份没有已存在的行 | 新行，`occurrences+1`，窗口基准 = `ts` |
    /// | R2 | `delta < -60000` | 时钟基重置（页面 reload）→ 按新行处理 |
    /// | R3 | `-60000 ≤ delta < 0` | 夹到 0 → 抑制；`lastSeenTs` 保持 max（不回退） |
    /// | R4 | `0 ≤ delta < 800` | 抑制：并入该身份最后一行，`lastSeenTs = ts`（续期），计数不变 |
    /// | R5 | `delta ≥ 800` | 新行，`occurrences+1`，窗口基准 = `ts` |
    ///
    /// 边界写死：**`delta == 800` 算"新一次出现"**（Agent 用的是 `< 800` 才抑制）。
    @discardableResult
    func ingest(
        _ payload: AgentTextPayload,
        cacheKey: String? = nil,
        sessionId: String,
        gameId: String,
        engine: String = "mvmz"
    ) -> TextEvent {
        let translationKey = cacheKey ?? payload.key
        let identity = TextStreamStore.rowIdentity(surface: payload.surface, raw: payload.raw)
        let ts = payload.ts

        // ── R0：ts 不可用 → 降级为严格同帧签名去重 ──
        //
        // 既不把 ts=0 当"很久以前"（否则每帧新增一行），也不当"刚刚"（否则永远吞掉）：
        // 只认"上一条事件的 frame|identity 完全相同"这一种形态，其余一律按新行落库。
        if !ts.isFinite || ts <= 0 {
            let signature = "\(payload.frame)|\(identity)"
            if signature == lastRawSignature, let index = rowIndex(for: identity) {
                // 同帧重复观测：不动窗口（`lastSeenTs` 会写进 0，污染后续判据），不动计数。
                lastRawSignature = signature
                return rows[index]
            }
            lastRawSignature = signature
            return appendRow(
                payload: payload,
                identity: identity,
                translationKey: translationKey,
                sessionId: sessionId,
                gameId: gameId,
                engine: engine
            )
        }

        // ── R1 / R2 / R3 / R4 / R5 ──
        guard let index = rowIndex(for: identity) else {
            // R1：窗口不存在 → 新行。
            return appendRow(
                payload: payload,
                identity: identity,
                translationKey: translationKey,
                sessionId: sessionId,
                gameId: gameId,
                engine: engine
            )
        }

        let lastSeen = rows[index].lastSeenTs
        let delta = ts - lastSeen

        if delta < -K.textStreamClockResetMs {
            // R2：时钟基重置（页面 reload 时 `performance.now()` 归零）。
            // 若把这种回退当"窗内"，reload 后第一句会被并进 reload 前的行 —— **丢句**。
            return appendRow(
                payload: payload,
                identity: identity,
                translationKey: translationKey,
                sessionId: sessionId,
                gameId: gameId,
                engine: engine
            )
        }

        if delta < 0 {
            // R3：轻微回拨（多客户端时钟差）→ 夹到 0 → 抑制。
            // `lastSeenTs` 保持 max：把窗口基准往回改会让真墙钟时间被系统性地拉短。
            return rows[index]
        }

        if delta < K.textStreamWindowMs {
            // R4：窗内 → 抑制合并 + **续期**（`lastSeenTs = ts`）。
            // 续期是关键：持续可见期间每 400ms 画一次，若窗口不续期，到 800ms 就会多出一行。
            // `occurrences` 与 `stats.total` 都不动（AC3.1-b：持续可见不重复计数）。
            rows[index].lastSeenTs = ts
            return rows[index]
        }

        // R5：窗外 → 新一次出现。
        return appendRow(
            payload: payload,
            identity: identity,
            translationKey: translationKey,
            sessionId: sessionId,
            gameId: gameId,
            engine: engine
        )
    }

    /// 取行身份对应的下标（做了两层防御：下标未越界 + 该位置的**行身份真的对得上**）。
    ///
    /// 第二层不是多余：任何淘汰/重排路径只要漏清一条索引，
    /// 就会把一条事件并进**别人的行**（症状是"屏幕上多了一句不相干的重复"）。
    /// 淘汰路径现在只清理被淘汰行自己的条目（见 `trimIfNeeded`），这层校验就是它的兜底。
    private func rowIndex(for identity: String) -> Int? {
        guard let absolute = lastRowIndexByIdentity[identity] else { return nil }
        let index = absolute - evictedRowCount
        guard index >= 0, index < rows.count else { return nil }
        let actual = TextStreamStore.rowIdentity(surface: rows[index].surface, raw: rows[index].raw)
        guard actual == identity else { return nil }
        return index
    }

    /// 落一条新行（R1 / R2 / R5 / R0 的新行分支共用）。
    private func appendRow(
        payload: AgentTextPayload,
        identity: String,
        translationKey: String,
        sessionId: String,
        gameId: String,
        engine: String
    ) -> TextEvent {
        // `order` 会话内单调递增，**从 1 开始**（PRD v0.3 §5.2）。
        orderCounter += 1
        let count = occurrencesByIdentity[identity, default: 0] + 1

        let event = TextEvent(
            ts: payload.ts,
            lastSeenTs: payload.ts,
            sessionId: sessionId,
            gameId: gameId,
            engine: engine,
            surface: payload.surface,
            surfaceKind: SurfaceKind.of(surface: payload.surface),
            sceneClass: payload.sceneClass,
            order: orderCounter,
            raw: payload.raw,
            segments: payload.segments,
            text: payload.text,
            key: translationKey,
            status: paused ? .paused : .pending,
            cached: false,
            occurrences: count
        )
        // 满窗口时"淘汰 1 行 + 追加 1 行"合并成**一次** `rows` 变更。
        //
        // 为什么不是 `append` 之后再 `trimIfNeeded()`：`rows` 是 `@Published`，每次子变更
        // 都会走一遍 get（返回共享存储的副本）→ 改 → set，触发整表 COW 深拷贝。拆成两步
        // 就是两次 5000 元素拷贝，比全表重建便宜但仍然白花一倍。
        let overflow = rows.count + 1 - maxRows
        if overflow > 0 {
            evictFront(overflow)
            // 一次整块赋值（= 一次 @Published 发布）：先拷一份独有的缓冲、原地淘汰 + 追加。
            // 不写成 `removeFirst` + `append`：那会把整表 COW 深拷贝做两次。
            var next = rows
            next.removeFirst(overflow)
            next.append(event)
            rows = next
        } else {
            rows.append(event)
        }
        // 计数**在淘汰之后**写回：`evictFront` 可能刚把这个身份的最后一行连同计数一起清掉，
        // 先写会被它删掉（新行的 occurrences 明明是 count，下一次却从 1 重来）。
        occurrencesByIdentity[identity] = count
        // + 淘汰基数：索引表存的是绝对下标，不能让 `removeFirst` 把它整体拽偏。
        lastRowIndexByIdentity[identity] = evictedRowCount + rows.count - 1
        stats.total += 1
        // 新行永远是最后一行（淘汰只从头部进行），返回它即可。
        return rows[rows.count - 1]
    }

    // MARK: - 按翻译身份扇出（译文 / 跳过 / 错误 / 待定共用）

    /// 按**翻译身份**（`cacheKey`）定位所有相关行的下标。
    ///
    /// 四条写状态路径（`applyTranslation` / `applySkip` / `applyError` / `markPending`）
    /// **必须共用这一个方法**，不许在四处各写一次过滤 —— 两套过滤必然漂移，而漂移的症状
    /// 是"两行里只有一行收敛"，看起来像后端慢，极难定位（与"两套剥码逻辑"同型）。
    ///
    /// 边界：行身份 `(surface, raw)` **只用于去重与 `occurrences`**；
    /// 译文 / 错误 / 降级 / 失效**一律按 `cacheKey` 扇出**（`350` 与 `\C[2]350` 共享同一个
    /// `cacheKey`，一条结果必须同时填两行，否则另一行永久 `pending`，撞 AC2.2b）。
    func rowsSharingCacheKey(_ cacheKey: String) -> [Int] {
        return rows.indices.filter { rows[$0].key == cacheKey }
    }

    /// 跳过（纯数字 / 纯符号 / 过短 / 已暂停）：不进管线。
    ///
    /// 参数是**翻译身份**（`cacheKey`）：同一句的多种画法（`350` / `\C[2]350`）共享它，
    /// 所以这里会扇出标记**所有**这些行；`stats.skipped` 只 +1（一次判定，不是一次计费）。
    func applySkip(cacheKey: String, reason: String) {
        var touched = false
        for index in rowsSharingCacheKey(cacheKey) {
            rows[index].status = (reason == "disabled") ? .paused : .skipped
            rows[index].skipReason = reason
            touched = true
        }
        if touched {
            stats.skipped += 1
        }
    }

    /// 写入译文。
    ///
    /// **必须按 `cacheKey` 扇出到所有行**：`350` 与 `\C[2]350` 是同一个 `cacheKey`，
    /// 一条后端结果要同时填满两行的译文列 —— 只更新一行，另一行会永远 `pending`，
    /// AC2.2b 的"5s 内收敛"直接判失败。
    ///
    /// **扇出 ≠ 整串复制**（BUG-11 的 Host 侧同型点）：同一 `cacheKey` 的几行 `raw` 不同
    /// （`\N[1]は元気` / `\N[2]は元気`），译文里的**控制码必须逐行重发本行的**。
    /// 因此 `segments` 只当"译文文本段队列"用，`code` 段一律丢弃，再按 `rows[i].segments`
    /// 这个**该行自己的骨架**重组；段数不符就落 `.error`（宁可不译，不把人名画串）。
    /// `translatedRaw` 只在**完全没有段证据**（旧调用方 / `segments` 为空）时整串回退。
    ///
    /// **`passthrough` 时 `translated` 一律置 `nil`**（只留 `status = .passthrough`）：
    /// 结果层 `translatedText == text` 是 PRD 要求，但把它塞进 `TextEvent.translated`
    /// 会让 UI 的"译文列"里出现**日文原文**，用户以为翻译成功 —— 这正是"假译文"。
    /// 语义规则：`translated` 只在 `status ∈ {hit, translated}` 时非 nil。
    func applyTranslation(
        cacheKey: String,
        translatedRaw: String?,
        segments: [Segment]?,
        backend: BackendKind,
        latencyMs: Int?,
        cached: Bool
    ) {
        var touched = false
        // 空数组等价于"没给"：与 Agent 侧 `hasSegments = segments.length > 0` 同一判据。
        var translatedTexts: [String]?
        if let segments = segments, !segments.isEmpty {
            translatedTexts = Segmenter.translatedTextPieces(segments)
        }
        for index in rowsSharingCacheKey(cacheKey) {
            if backend == .passthrough {
                rows[index].translated = nil
                rows[index].translatedSegments = nil
                rows[index].status = .passthrough
            } else if let texts = translatedTexts {
                // 本行自己的骨架：`rows[index].segments` 来自该行的 Agent 上报，
                // 不能重新 `splitSegments(raw)` 代替（两侧分段器的细微差异会算错段数）。
                let skeleton = rows[index].segments
                if let merged = Segmenter.mergeBySkeleton(skeleton: skeleton, translatedTexts: texts) {
                    rows[index].translated = merged
                    rows[index].translatedSegments = Segmenter.mergeSegments(skeleton: skeleton, translatedTexts: texts)
                    rows[index].status = cached ? .hit : .translated
                    rows[index].error = nil
                } else {
                    // 有译文但本行骨架对不上（病态数据）：绝不重放先到那一行的码值。
                    rows[index].translated = nil
                    rows[index].translatedSegments = nil
                    rows[index].status = .error
                    rows[index].error = ErrorInfo(code: .segmentMismatch)
                }
            } else {
                // 无段证据的兼容路径（v0.2 行为）：整串回退，此时没有骨架可比。
                rows[index].translated = translatedRaw
                rows[index].translatedSegments = nil
                rows[index].status = cached ? .hit : .translated
                rows[index].error = nil
            }
            rows[index].backend = backend
            rows[index].latencyMs = latencyMs
            rows[index].cached = cached
            touched = true
        }
        if touched {
            if backend == .passthrough {
                // 直通不计入命中率分母（PRD AC3.1：分母不含 skipped / passthrough）。
            } else if cached {
                stats.hits += 1
            } else {
                stats.fresh += 1
            }
        }
    }

    /// 写入错误（401/429/超时/段数不匹配）。
    ///
    /// **同样必须扇出**：只更新一行时，用户看到"一行报错、另一行永远转圈"——
    /// 症状与"后端慢"无法区分。错误路径的测试通常只放一条样本，天然测不出扇出。
    func applyError(cacheKey: String, error: ErrorInfo) {
        var touched = false
        for index in rowsSharingCacheKey(cacheKey) {
            rows[index].status = .error
            rows[index].error = error
            touched = true
        }
        if touched {
            stats.errors += 1
        }
    }

    func markPending(cacheKey: String) {
        for index in rowsSharingCacheKey(cacheKey) {
            if rows[index].status == .pending { continue }
            if rows[index].translated == nil {
                rows[index].status = .pending
            }
        }
    }

    // MARK: - 开关与清理

    func setPaused(_ value: Bool) {
        paused = value
        guard value else { return }
        for index in rows.indices where rows[index].status == .pending {
            rows[index].status = .paused
        }
    }

    /// 只清视图，清缓存不在此处。
    ///
    /// 窗口状态必须跟着清：`clear()` 之后同一身份要**从 1 重新开始**（`store_probe` 的 S6），
    /// 也要能被当成"新一次出现"（否则清屏后的第一句会被并进已不存在的行）。
    func clear() {
        rows.removeAll()
        stats = StreamStats()
        occurrencesByIdentity.removeAll()
        lastRowIndexByIdentity.removeAll()
        evictedRowCount = 0
        lastRawSignature = ""
        orderCounter = 0
    }

    func updateMaxRows(_ value: Int) {
        maxRows = max(1, value)
        trimIfNeeded()
    }

    /// 淘汰：从头部整段移除，**只处理被淘汰行自己的索引条目**。
    ///
    /// 旧实现在这里调 `rebuildStateFromRows()`：满窗口（5000 行）时每次追加都要为全部行
    /// 重拼 `rowIdentity`（`surface + U+0000 + raw`）并重建两张字典，O(n) 开销压在
    /// @MainActor 上；而 `drainPollMs = 250ms`，稳态下每轮都可能触发一次。
    ///
    /// 现在两条判据都只看被淘汰的那一行：
    ///  · **下标**：索引表存绝对下标，`removeFirst` 不改任何保留行的绝对下标，
    ///    因此只有"该身份的最后一行正是这行"时才删（此后它已无保留的后代）。
    ///  · **计数**：同一身份的 `occurrences` 随 append 单调递增（1,2,3…），淘汰又只从头部进行，
    ///    保留下来的一定是后缀 ⇒ 最大值就是最后一行那个值，无需重算；
    ///    仅当该身份**没有任何保留行**时才删，下次从 1 重新开始（`store_probe` S5b）。
    ///
    /// 与旧的整表重建逐项等价：整表重建取的是"各身份最大值 + 各身份最后一行下标"，
    /// 而这两项在"删掉的行不是该身份最后一行"时本来就不变。
    private func trimIfNeeded() {
        guard rows.count > maxRows else { return }
        let overflow = rows.count - maxRows
        evictFront(overflow)
        rows.removeFirst(overflow)
    }

    /// 为即将从头部移除的 `count` 行清理索引（`rows` 本身由调用方移除）。
    ///
    /// 必须在 `rows` 变更**之前**调用：这里要用旧的相对下标算绝对下标。
    private func evictFront(_ count: Int) {
        for index in 0..<count {
            let row = rows[index]
            let identity = TextStreamStore.rowIdentity(surface: row.surface, raw: row.raw)
            let absolute = evictedRowCount + index
            // 该身份还有更靠后的保留行 → 这条只是"旧的一次出现"，索引与计数都要留着。
            guard lastRowIndexByIdentity[identity] == absolute else { continue }
            lastRowIndexByIdentity[identity] = nil
            occurrencesByIdentity[identity] = nil
        }
        evictedRowCount += count
    }
}
