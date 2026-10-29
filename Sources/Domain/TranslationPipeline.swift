//
//  TranslationPipeline.swift
//  MochiBox
//
//  缓存优先 + 合并窗口（120ms）+ 并发上限（默认 4，可配置）+ 重试退避 + 熔断。
//  依据 docs/prd.md P0-10/P0-13；docs/architecture.md §3.7。
//

import Foundation

actor TranslationPipeline {
    enum Priority: Int, Sendable {
        case high = 0
        case low = 1
    }

    private let cache: TranslationCache
    /// **必须是闭包，不可"优化"成存储属性**。
    /// 这两个闭包同时承载两件事：`P0-12`「设置保存后立即生效无需重启」，
    /// 以及 `AC2.2c`「必须同进程内切到 mock 后端再开始计时」。
    /// 每批出队时重新取一次值，因此保存设置只改 `SettingsStore` 内存值 + 落盘，
    /// **不重建 pipeline**；若改成 `let provider: TranslatorProvider`，
    /// 后端切换就退化成"重启才生效"，症状是"看起来都正常、只有切后端不生效"。
    private let provider: @Sendable () -> TranslatorProvider
    private let settings: @Sendable () -> Settings
    private let policy: ResiliencePolicy
    private let breaker: CircuitBreaker
    private let log: SessionLog?

    private var queueHigh: [TranslationRequestItem] = []
    private var queueLow: [TranslationRequestItem] = []
    private var queuedKeys: Set<String> = []
    /// 已出队、请求尚未回来的 key。
    ///
    /// 没有它时，同一句在飞期间再次 resolve() 会：① 缓存未命中 → 返回 .pending，
    /// 但 enqueue 因 queuedKeys 里已经没有它而**第二次入队** → 二次计费；
    /// 反过来若修复请求想重发同 key，又会被静默丢掉。出队时从 queuedKeys 转入这里，
    /// 回包 / 失败 / 取消后移除。
    private var inFlightKeys: Set<String> = []
    private var handlers: [@Sendable (PipelineBatchResult) -> Void] = []
    private var worker: Task<Void, Never>?
    private var inFlight: Int = 0
    private var status: BackendStatus = .ok
    /// 代际号：cancelAll() 自增。在飞请求回来时若代际已变，结果直接丢弃。
    ///
    /// 只 cancel worker 不够：URLSession 的请求不会因为 Task 取消就一定立刻失败，
    /// 回包照样会 cache.put + 推流 —— 用户关掉翻译后页面还会跳一次译文。
    private var epoch: UInt64 = 0
    private var lastNoticeAt: [ErrorCode: Date] = [:]
    /// 已通知过的熔断窗口（= 这一轮的 openUntil）。
    ///
    /// 熔断期间 runLoop 每 500ms 醒一次，若每次都推一条结果，日志与 UI 会被同一条
    /// 状态刷屏；用窗口起点去重，同一个窗口只通知一次。队列里**新入队**的条目会把
    /// 它清空（见 enqueue）：新提交的一批同样需要立刻收到 circuit_open，
    /// 否则它只能等 waitForBatch 的超时兜底。
    private var announcedCircuitOpenUntil: Date?

    /// 自适应批量上限：某次**因解析失败拆块**后，压到"这次成功的最大的子块条数"，
    /// 下一波直接用这个尺寸，不再先撞一次注定失败的 80 条。
    ///
    /// `nil` = 没降过（用 `settings.maxBatch`）。整波没有解析失败时每次 +10 缓慢恢复，
    /// 恢复到位就清回 nil —— 后端升级/网络变好之后不必人工重启。
    private var adaptiveBatchCeiling: Int?

    /// 解析失败时最多对半拆几层。**按本波最大的块算**，不是写死 4。
    ///
    /// 写死 4 的边界：`maxBatch` 允许 200，200→100→50→25→12/13 就到底了；
    /// 「>8 条必失败」的后端一条都交不出来，整波 200 条全丢。`ceil(log2(n))`
    /// 保证一路拆到 1 条，同时 `runSubchunk` 仍有 `count > 1` 的终止条件。
    nonisolated static func splitDepth(forChunkSize chunkSize: Int) -> Int {
        let size = max(1, chunkSize)
        return max(1, Int(ceil(log2(Double(size)))))
    }

    /// - Parameters:
    ///   - provider: 每批重新取；**闭包，不是存储属性**（见上）。
    ///   - settings: 每批重新取；**闭包，不是存储属性**（见上）。
    init(
        cache: TranslationCache,
        provider: @escaping @Sendable () -> TranslatorProvider,
        settings: @escaping @Sendable () -> Settings,
        policy: ResiliencePolicy = ResiliencePolicy(),
        log: SessionLog? = nil
    ) {
        self.cache = cache
        self.provider = provider
        self.settings = settings
        self.policy = policy
        self.breaker = CircuitBreaker(threshold: policy.breakerThreshold, openSeconds: policy.breakerOpenSec)
        self.log = log
    }

    // MARK: - 回调

    func onResult(_ handler: @escaping @Sendable (PipelineBatchResult) -> Void) {
        handlers.append(handler)
    }

    // MARK: - 对外 API

    /// 同步查缓存：命中即时返回，未命中返回 `.pending` 且已入队。
    ///
    /// **这里是 `docs/architecture.md §7.8` 规范顺序的唯一实现**（不得重排）：
    /// ```
    /// ① normalizeForKey → ② SkipRules.skipReason → ③ TranslationCache.get → ④ 入队
    /// ```
    /// 命中 ② 即返回 `.skipped` 并终止：**不入队、不查缓存、不写缓存**。
    /// P1 的抽取管道必须复用同一份 `SkipRules`，不得另写一套。
    func resolve(_ items: [TranslationRequestItem]) async -> [PipelineOutcome] {
        let current = settings()
        let passthrough = current.effectiveBackend == .passthrough
        var outcomes: [PipelineOutcome] = []
        var missing: [TranslationRequestItem] = []
        for item in items {
            // ① normalizeForKey 已在 `mapKey` 内完成；② 跳过判定必须先于缓存查询。
            let mapKey = Segmenter.mapKey(item.segments)
            if let reason = SkipRules.skipReason(
                for: mapKey,
                enabled: current.agentEnabled,
                minLength: K.minTranslateLength
            ) {
                outcomes.append(.skipped(reason: reason))
                continue
            }
            if passthrough {
                outcomes.append(.passthrough(TranslationResultItem(
                    key: item.key,
                    translatedText: item.text,
                    translatedSegments: item.segments,
                    cached: false,
                    latencyMs: 0
                )))
                continue
            }
            // ③ 查缓存。`ignoreCache` 的修复请求绕开它 —— 上一版的坏译文正是从缓存里
            //    发出来的，不跳过就永远修不掉；结果仍按原 key 覆盖写回（见 drainOneBatch）。
            var hit: TranslationCache.Entry? = nil
            if item.ignoreCache != true {
                hit = await cache.get(item.key)
            }
            if let cached = hit {
                await cache.noteHit(item.key)
                outcomes.append(.hit(TranslationResultItem(
                    key: item.key,
                    translatedText: cached.translatedText,
                    translatedSegments: nil,
                    cached: true,
                    latencyMs: 0
                )))
            } else {
                outcomes.append(.pending)
                // 已在队列或在飞：不再入队（否则同一句会二次计费 / 修复请求被丢掉）。
                if !queuedKeys.contains(item.key) && !inFlightKeys.contains(item.key) {
                    missing.append(item)
                }
            }
        }
        // ④ 入队（只有通过 ②③ 的条目才会到这里）
        if !missing.isEmpty {
            enqueue(missing, priority: .high)
        }
        return outcomes
    }

    func submit(_ items: [TranslationRequestItem], priority: Priority) {
        enqueue(items, priority: priority)
    }

    /// 一个 chunk 内所有条目命中的术语取并集（去重、保持顺序、封顶 80 条 / 2000 字符）。
    /// 术语表放在 request 级而不是逐条发送：provider 只渲染一次，token 不会随条数增长。
    ///
    /// 40 → 80 条、1200 → 2000 字符：块从 10 条涨到 60 条后，尾段的术语很容易被截掉，
    /// 被截掉的术语会制造违例、再喂给修复环重复计费。
    private static func unionGlossary(_ items: [TranslationRequestItem]) -> [GlossaryPair]? {
        var seen: Set<String> = []
        var output: [GlossaryPair] = []
        var characters = 0
        for item in items {
            for pair in item.glossary ?? [] {
                guard seen.insert(pair.source).inserted else { continue }
                if output.count >= 80 { return output }
                let cost = pair.source.count + pair.target.count
                if !output.isEmpty && characters + cost > 2000 { return output }
                output.append(pair)
                characters += cost
            }
        }
        return output.isEmpty ? nil : output
    }

    /// 本块「上一版没遵守、这次必须逐字使用」的术语取并集（去重、封顶 20 对）。
    ///
    /// 上限 20 而不是 80：强调段是给**这一版**纠错的，塞满整张术语表反而稀释重点；
    /// 修复请求通常只涉及一两个名字（「咬人水母」），20 对足够跨块合并。
    /// 必须放 request 级 —— `systemPrompt` 是 request 级，放 item 上 provider 取不到。
    private static func unionEmphasis(_ items: [TranslationRequestItem]) -> [GlossaryPair]? {
        var seen: Set<String> = []
        var output: [GlossaryPair] = []
        for item in items {
            for pair in item.emphasis ?? [] {
                guard seen.insert(GlossaryKey.normalize(pair.source)).inserted else { continue }
                if output.count >= 20 { return output }
                output.append(pair)
            }
        }
        return output.isEmpty ? nil : output
    }

    func backendStatus() -> BackendStatus {
        if breaker.isOpen {
            return .circuitOpen(until: breaker.openUntil ?? Date())
        }
        return status
    }

    /// 等待队列清空（测试 / 退出前使用）。
    func flush() async {
        // 新超时公式下单请求就可能 30s，固定 20s 会让 flush 在最后一块回来前放弃。
        let budget = max(20, Double(settings().timeoutSec) * 4 + 15)
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if queueHigh.isEmpty && queueLow.isEmpty && inFlight == 0 {
                await cache.flush()
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await cache.flush()
    }

    func cancelAll() {
        // 代际自增必须在清队列之前：在飞请求回来时先看见新代际，结果才会被丢弃。
        epoch &+= 1
        queueHigh.removeAll()
        queueLow.removeAll()
        queuedKeys.removeAll()
        inFlightKeys.removeAll()
        worker?.cancel()
        worker = nil
    }

    // MARK: - 入队与批处理

    private func enqueue(_ items: [TranslationRequestItem], priority: Priority) {
        var added = false
        for item in items {
            if queuedKeys.contains(item.key) || inFlightKeys.contains(item.key) { continue }
            queuedKeys.insert(item.key)
            switch priority {
            case .high: queueHigh.append(item)
            case .low: queueLow.append(item)
            }
            added = true
        }
        if added {
            // 熔断窗口里去重标记只挡"同一批积压被重复通知"：新条目入队说明又有一批
            // 别人在等结果，必须再通知一次，否则它只能干等到 waitForBatch 超时。
            if !breaker.canAttempt() {
                announcedCircuitOpenUntil = nil
            }
            ensureWorker()
        }
    }

    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 熔断窗口的轮询间隔。
    static let circuitPollNs: UInt64 = 500_000_000

    /// 熔断窗口的一站式播报：更新状态 + 只在窗口变化时推一次空结果。
    ///
    /// **不携带任何 item**：熔断意味着"这批还没翻译"，不是"这批的译文就是原文"。
    /// 把原文当译文发出去会让调用方把日文写进语料并标记为已翻译（真机上 7000+ 条
    /// 就这么被污染了）。通知的唯一作用是让调用方把在飞条目落成 failed（可重试）。
    private func announceCircuitOpenIfNeeded() {
        let until = breaker.openUntil ?? Date().addingTimeInterval(policy.breakerOpenSec)
        status = .circuitOpen(until: until)
        guard announcedCircuitOpenUntil != until else { return }
        announcedCircuitOpenUntil = until
        let remaining = max(0, Int(ceil(until.timeIntervalSinceNow)))
        let error = ErrorInfo(
            code: .circuitOpen,
            message: "后端连续失败，已熔断（约 \(remaining) 秒后自动重试）"
        )
        log?.warn("TranslationPipeline", "熔断打开：队列暂停，冷却后继续", [
            "retryAfterSec": "\(remaining)",
            "queued": "\(queueHigh.count + queueLow.count)"
        ])
        notifyHandlers(PipelineBatchResult(
            requestId: UUID().uuidString,
            items: [],
            backend: .passthrough,
            error: error
        ))
    }

    private func runLoop() async {
        while true {
            if queueHigh.isEmpty && queueLow.isEmpty {
                worker = nil
                return
            }
            // 熔断打开：**不消费队列**（出队再丢掉等于静默丢译文），也不发伪造译文。
            // 每 500ms 醒一次检查半开，别忙转：30s 窗口里空转会烧满一个核。
            if !breaker.canAttempt() {
                announceCircuitOpenIfNeeded()
                try? await Task.sleep(nanoseconds: TranslationPipeline.circuitPollNs)
                if Task.isCancelled {
                    worker = nil
                    return
                }
                continue
            }
            // 合并窗口逐批从闭包读：设置页改了就立即生效，无需重启/重建管线。
            // 积压已经够一整批时不再等窗口：窗口只该用来"攒"第一条到一批之间。
            let current = settings()
            let backlogIsFull = queuedKeys.count >= max(1, current.maxBatch)
            if !backlogIsFull {
                let windowMs = max(0, current.batchWindowMs)
                if windowMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(windowMs) * 1_000_000)
                }
            }
            await drainOneBatch()
            if Task.isCancelled {
                worker = nil
                return
            }
        }
    }

    /// 单波：出队 → 均分成并发块 → 块内按字数切子块顺序发 → 汇总 → 一次推送。
    ///
    /// 分块规则是**测试断言的对象**（probe_resilience D5），改动前先对齐：
    ///   total = min(队列长度, maxBatch × maxConcurrent)
    ///   chunkCount = min(maxConcurrent, ceil(total / maxBatch))，均分
    /// 每块内部再按 batchCharBudget 切子块、顺序发送 —— 在飞请求数恒 ≤ maxConcurrent。
    private func drainOneBatch() async {
        // 熔断检查必须在**出队之前**：先把条目取出来再降级，等于把它们从队列里删掉，
        // 冷却后没法继续翻译（真机上 13 秒"处理"完 7687 条就是这么来的）。
        guard breaker.canAttempt() else {
            announceCircuitOpenIfNeeded()
            return
        }
        // 批量 / 并发上限同样每批读闭包（P0-12：保存即生效）。
        let current = settings()
        let epochAtStart = epoch
        // 自适应上限只压不抬：`ceil` 可能比用户新填的 maxBatch 大（用户后来调小了），
        // 所以取 min；用户调大时仍以设置值为准（下一波无解析失败会自增回来）。
        let configuredMaxBatch = max(1, current.maxBatch)
        let maxBatch = max(1, min(configuredMaxBatch, adaptiveBatchCeiling ?? configuredMaxBatch))
        let maxConcurrent = max(1, current.maxConcurrent)
        let limit = maxBatch * maxConcurrent

        var batch: [TranslationRequestItem] = []
        batch.reserveCapacity(min(limit, queuedKeys.count))
        while batch.count < limit {
            if !queueHigh.isEmpty {
                batch.append(queueHigh.removeFirst())
            } else if !queueLow.isEmpty {
                batch.append(queueLow.removeFirst())
            } else {
                break
            }
        }
        guard !batch.isEmpty else { return }
        for item in batch {
            queuedKeys.remove(item.key)
            inFlightKeys.insert(item.key)
        }

        let requestId = UUID().uuidString

        let provider = self.provider()
        let delays = policy.retryDelaysMs
        let logger = self.log
        let settingsSnapshot = current

        // ① 均分成至多 maxConcurrent 块。chunkCount 由 total/maxBatch 决定：
        //    50 条 / maxBatch 60 → 1 块 50 条；240 条 → 4 块 60 条。
        let chunkCount = min(maxConcurrent, max(1, Int(ceil(Double(batch.count) / Double(maxBatch)))))
        var chunks: [[TranslationRequestItem]] = []
        chunks.reserveCapacity(chunkCount)
        let base = batch.count / chunkCount
        let remainder = batch.count % chunkCount
        var cursor = 0
        for index in 0..<chunkCount {
            let size = base + (index < remainder ? 1 : 0)
            let end = min(cursor + size, batch.count)
            chunks.append(Array(batch[cursor..<end]))
            cursor = end
        }

        // 拆块深度必须是**整波最大块**的层数：按小块算，大块那一支就拆不到单条。
        // 200 条 + 4 层只能到 12/13 条，「>8 必失败」的后端会把整波丢掉。
        let splitDepth = TranslationPipeline.splitDepth(forChunkSize: chunks.map { $0.count }.max() ?? 1)
        if splitDepth > 1 {
            logger?.debug("TranslationPipeline", "本波拆块深度", [
                "maxChunk": "\(chunks.map { $0.count }.max() ?? 0)",
                "depth": "\(splitDepth)"
            ])
        }

        // ② 块间并发；块内子块顺序发送（runChunk 内部 await 串行）。
        inFlight += 1
        let collected: [(Int, TranslationPipeline.ChunkOutcome)] = await withTaskGroup(
            of: (Int, TranslationPipeline.ChunkOutcome).self,
            returning: [(Int, TranslationPipeline.ChunkOutcome)].self
        ) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let outcome = await TranslationPipeline.runChunk(
                        provider: provider,
                        settings: settingsSnapshot,
                        items: chunk,
                        delays: delays,
                        splitDepth: splitDepth,
                        log: logger
                    )
                    return (index, outcome)
                }
            }
            var output: [(Int, TranslationPipeline.ChunkOutcome)] = []
            for await item in group {
                output.append(item)
            }
            return output
        }
        inFlight -= 1

        // ③ 代际校验：cancelAll() 之后回来的结果一律丢弃（不写缓存、不推流）。
        guard epoch == epochAtStart else {
            logger?.warn("TranslationPipeline", "取消后回包，已丢弃", ["items": "\(batch.count)"])
            for item in batch {
                inFlightKeys.remove(item.key)
            }
            return
        }

        var textByKey: [String: String] = [:]
        textByKey.reserveCapacity(batch.count)
        for item in batch {
            textByKey[item.key] = item.text
        }

        var resultItems: [TranslationResultItem] = []
        var itemErrors: [String: ErrorInfo] = [:]
        var firstError: ErrorInfo?
        var backend: BackendKind = current.effectiveBackend
        var erroredChunks = 0
        var deliveredChunks = 0

        let ordered = collected.sorted { $0.0 < $1.0 }
        for (index, outcome) in ordered {
            let chunk = chunks[index]
            if let error = outcome.error {
                erroredChunks += 1
                if firstError == nil { firstError = error.asErrorInfo }
                // message / snippet 必须带上：只记 code + 条数时，`bad_response` 到底是
                // 截断、拒答还是换了输出形状，日志里完全看不出来（真机排查就卡在这里）。
                logger?.warn("TranslationPipeline", "后端请求失败", [
                    "code": error.code.rawValue,
                    "items": "\(chunk.count)",
                    "httpStatus": "\(error.httpStatus ?? 0)",
                    "message": error.message,
                    "snippet": TranslationPipeline.oneLineSnippet(error.rawSnippet)
                ])
            }
            if !outcome.items.isEmpty {
                deliveredChunks += 1
                backend = outcome.backend
            }
            // 单条校验失败：只记 key 与原因，**不改** firstError / backendStatus / 熔断。
            for (key, error) in outcome.itemErrors {
                itemErrors[key] = error.asErrorInfo
                logger?.warn("TranslationPipeline", "单条译文不可用", [
                    "key": String(key.prefix(8)),
                    "code": error.code.rawValue,
                    "message": error.message,
                    "snippet": TranslationPipeline.oneLineSnippet(error.rawSnippet ?? "")
                ])
            }
            for item in outcome.items {
                await cache.put(
                    key: item.key,
                    text: textByKey[item.key] ?? item.translatedText,
                    translatedText: item.translatedText,
                    backend: outcome.backend.rawValue
                )
                resultItems.append(item)
            }
        }

        // 自适应上限：这一波拆过块就压到"成功的最大的子块"，整波干净就 +10 恢复。
        // 只影响下一波的尺寸，与这一波的成功/失败判定无关（熔断仍按波记账）。
        updateAdaptiveCeiling(
            splitOutcomes: ordered.map { $0.1 }.filter { $0.didSplitForParse },
            configuredMaxBatch: configuredMaxBatch,
            logger: logger
        )

        // 熔断按"波"记账：全块成功 → 记成功；全块失败（一条都没交付）→ 记失败；
        // 部分成功不记 —— 否则 4 块里 1 块成功就永远喂不出熔断。
        if !ordered.isEmpty {
            if erroredChunks == 0 {
                breaker.recordSuccess()
                announcedCircuitOpenUntil = nil
                status = .ok
            } else if deliveredChunks == 0 {
                breaker.recordFailure()
                if let error = firstError {
                    status = .degraded(error)
                }
                if breaker.isOpen {
                    status = .circuitOpen(until: breaker.openUntil ?? Date().addingTimeInterval(policy.breakerOpenSec))
                }
            }
        }

        // 只有**所有块都没交付**才算直通降级：部分成功时把 backend 打成 passthrough，
        // SessionController 会把同一波里成功块的译文一起置空（translatedRaw = nil）。
        if !ordered.isEmpty && deliveredChunks == 0 {
            backend = .passthrough
        }

        if let error = firstError {
            noteErrorNotice(error)
        }

        // 先摘掉在飞标记再推结果：处理方可能在回调里立刻重新 resolve 同一句（修复环）。
        for item in batch {
            inFlightKeys.remove(item.key)
        }

        notifyHandlers(PipelineBatchResult(
            requestId: requestId,
            items: resultItems,
            backend: backend,
            error: firstError,
            itemErrors: itemErrors
        ))
    }

    /// 根据这一波是否拆过块调整下一波的批量上限。
    ///
    /// 降：`80` 拆成 `40` 成功 → 下一波直接发 `40`，不再每一波都先撞一次必然失败的 80
    /// （每撞一次都要整块重发，真机上这一撞就是 41~120 条全灭）。
    /// 升：整波没有解析失败 → +10，涨回 `settings.maxBatch` 就清掉降级标记。
    private func updateAdaptiveCeiling(
        splitOutcomes: [ChunkOutcome],
        configuredMaxBatch: Int,
        logger: SessionLog?
    ) {
        if !splitOutcomes.isEmpty {
            guard let best = splitOutcomes.compactMap({ $0.splitSuccessSize }).max() else {
                // 拆到叶子仍然全失败：这是一次真故障（鉴权/限流/模型不可用），
                // 没有"多大的块能成功"可参考，保持当前上限不动。
                logger?.warn("TranslationPipeline", "解析失败拆块后仍无成功子块", [
                    "chunks": "\(splitOutcomes.count)"
                ])
                return
            }
            let next = max(1, min(configuredMaxBatch, best))
            guard adaptiveBatchCeiling != next else { return }
            adaptiveBatchCeiling = next
            logger?.info("TranslationPipeline", "自适应批量上限下调", [
                "ceiling": "\(next)",
                "configured": "\(configuredMaxBatch)",
                "reason": "解析失败拆块"
            ])
            return
        }
        guard let ceiling = adaptiveBatchCeiling else { return }
        let next = min(configuredMaxBatch, ceiling + 10)
        adaptiveBatchCeiling = next >= configuredMaxBatch ? nil : next
        logger?.info("TranslationPipeline", "自适应批量上限恢复", [
            "ceiling": "\(next)",
            "configured": "\(configuredMaxBatch)"
        ])
    }

    /// 日志字段必须单行：响应片段里的换行会把一条日志拆成好几行。
    nonisolated static func oneLineSnippet(_ text: String?, limit: Int = 200) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return String(flattened.prefix(limit))
    }

    // MARK: - 分块与单块发送

    /// 单块结果。items 为可交付的译文（对半拆块后可能少于请求条数）。
    struct ChunkOutcome: Sendable {
        var items: [TranslationResultItem] = []
        var error: MochiBoxError?
        /// **单条**校验失败（段数不符、单条重试后仍失败）：key → 错误。
        ///
        /// 与 `error` 严格区分：`error` = 整块请求失败（网络 / 解析 / 超时），会让整波
        /// 降级、计入熔断；这里只是个别译文不可用，后端本身是好的，**不得**改
        /// `backendStatus`、不得计入熔断。旧实现把两者塞进同一个字段，119 条里坏 6 条
        /// 就把整块标成 degraded —— 用户看到的是“频繁报错”，实际成功率 95%。
        var itemErrors: [String: MochiBoxError] = [:]
        var backend: BackendKind = .openai
        /// 这块内部**因解析失败拆过块**（下一波的批量上限要据此下调）。
        var didSplitForParse: Bool = false
        /// 拆块树里成功返回的最大子块条数（没有成功叶子时保持 nil）。
        var splitSuccessSize: Int?
    }

    /// 单请求超时：条数越多给得越宽（15s 是给 1 条的，60 条不可能够）。
    nonisolated static func singleRequestTimeoutMs(settings: Settings, itemCount: Int) -> Int {
        return max(max(1, settings.timeoutSec) * 1000, 15_000 + max(0, itemCount) * 250)
    }

    /// 按输入字数切子块；至少 1 条（单条超预算也必须能发出去）。
    nonisolated static func splitByCharBudget(_ items: [TranslationRequestItem], budget: Int) -> [[TranslationRequestItem]] {
        let limit = max(1, budget)
        var output: [[TranslationRequestItem]] = []
        var current: [TranslationRequestItem] = []
        var characters = 0
        for item in items {
            let cost = item.text.count
            if !current.isEmpty && characters + cost > limit {
                output.append(current)
                current = []
                characters = 0
            }
            current.append(item)
            characters += cost
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    /// 一个并发块：块内子块顺序发送，单个子块失败只影响它自己。
    nonisolated static func runChunk(
        provider: TranslatorProvider,
        settings: Settings,
        items: [TranslationRequestItem],
        delays: [Int],
        splitDepth: Int,
        log: SessionLog?
    ) async -> ChunkOutcome {
        var outcome = ChunkOutcome(backend: settings.effectiveBackend)
        for subchunk in splitByCharBudget(items, budget: settings.batchCharBudget) {
            let part = await runSubchunk(
                provider: provider,
                settings: settings,
                items: subchunk,
                delays: delays,
                // 深度按整块算：子块本来就只会更小，多给的层数不会被用到。
                splitDepth: splitDepth,
                log: log
            )
            outcome.items.append(contentsOf: part.items)
            outcome.itemErrors.merge(part.itemErrors) { first, _ in first }
            if outcome.error == nil { outcome.error = part.error }
            if !part.items.isEmpty { outcome.backend = part.backend }
            if part.didSplitForParse {
                outcome.didSplitForParse = true
                if let size = part.splitSuccessSize {
                    outcome.splitSuccessSize = max(outcome.splitSuccessSize ?? 0, size)
                }
            }
        }
        return outcome
    }

    /// 发一个子块。**任何 `badResponse`** 且条数 > 1 时对半拆开重发，最多 `splitDepth` 层。
    ///
    /// 例外：**空内容**（`模型返回空内容（finish_reason=…）`）不拆 —— 它跟块大小无关，
    /// 拆开只是把同一次失败复制成 2^depth 次请求（5 条 → 9 次），失败后端直接变请求风暴。
    ///
    /// 不能靠 retryable：解析失败（截断 / 前后带解释 / 换了输出形状 / 条数不匹配）是
    /// badResponse，本身不可重试，整块重发只会再失败一次。对半拆能让没问题的另一半先落地，
    /// 也能把请求压到模型真能稳住的小块 —— 真机上 41~120 条的大块**全部**失败、
    /// 40 条以下 0 次失败，正是"块太大"而不是"后端坏了"。
    ///
    /// 只拆、不重发已成功的子块：递归返回后按原顺序合并，失败的那半再继续拆。
    nonisolated static func runSubchunk(
        provider: TranslatorProvider,
        settings: Settings,
        items: [TranslationRequestItem],
        delays: [Int],
        splitDepth: Int,
        log: SessionLog?
    ) async -> ChunkOutcome {
        let request = TranslationRequest(
            items: items,
            srcLang: settings.srcLang,
            tgtLang: settings.tgtLang,
            backend: settings.effectiveBackend,
            timeoutMs: singleRequestTimeoutMs(settings: settings, itemCount: items.count),
            requestId: UUID().uuidString,
            glossary: unionGlossary(items),
            emphasis: unionEmphasis(items)
        )
        switch await runWithRetries(provider: provider, request: request, delays: delays) {
        case .success(let translation):
            var outcome = ChunkOutcome(backend: translation.backend)
            // 段数不符先攒着，不立刻判死：单条重发一次能救回大部分模型输出抖动。
            var mismatched: [(item: TranslationRequestItem, error: MochiBoxError, latency: Int?)] = []
            for (index, item) in items.enumerated() {
                let translatedText = index < translation.items.count
                    ? translation.items[index].translatedText
                    : item.text
                let latency = index < translation.items.count ? translation.items[index].latencyMs : nil
                // 段数校验：不匹配 → 丢弃且不写缓存（在 drainOneBatch 里只写 outcome.items）。
                do {
                    let segments = try Segmenter.translatedSegments(segments: item.segments, translatedText: translatedText)
                    _ = try Segmenter.reassemble(segments: item.segments, translatedText: translatedText)
                    outcome.items.append(TranslationResultItem(
                        key: item.key,
                        translatedText: translatedText,
                        translatedSegments: segments,
                        cached: false,
                        latencyMs: latency
                    ))
                } catch let error as MochiBoxError {
                    mismatched.append((item, error, latency))
                } catch {
                    mismatched.append((item, MochiBoxError(code: .badResponse), latency))
                }
            }
            guard !mismatched.isEmpty else { return outcome }

            // 只有个别条失败才值得逐条重发：整块大面积漂移时重发会把请求量放大 2 倍，
            // 而结果大概率还是错的（见 `K.maxSegmentRetryPerChunk`）。
            for candidate in mismatched.prefix(K.maxSegmentRetryPerChunk) {
                log?.warn("TranslationPipeline", "译文分段校验失败，单条重试", [
                    "key": String(candidate.item.key.prefix(8)),
                    "expected": "\(Segmenter.textSegmentCount(candidate.item.segments))",
                    "message": candidate.error.message,
                    "snippet": TranslationPipeline.oneLineSnippet(candidate.error.rawSnippet ?? "")
                ])
                if let rescued = await retryAfterSegmentMismatch(
                    provider: provider,
                    settings: settings,
                    item: candidate.item,
                    glossary: request.glossary,
                    emphasis: request.emphasis,
                    log: log
                ) {
                    outcome.items.append(rescued)
                } else {
                    outcome.itemErrors[candidate.item.key] = candidate.error
                }
            }
            for candidate in mismatched.dropFirst(K.maxSegmentRetryPerChunk) {
                outcome.itemErrors[candidate.item.key] = candidate.error
                log?.warn("TranslationPipeline", "译文分段校验失败且超出重试额度", [
                    "key": String(candidate.item.key.prefix(8)),
                    "expected": "\(Segmenter.textSegmentCount(candidate.item.segments))",
                    "message": candidate.error.message,
                    "snippet": TranslationPipeline.oneLineSnippet(candidate.error.rawSnippet ?? "")
                ])
            }
            return outcome
        case .failure(let error):
            // 空内容不拆块：模型这次整段没吐可用 content（finish_reason=length 多为
            // max_tokens 被推理吃掉），同一后端、同一预算下拆成一半仍然是空串。
            // 拆只会把 1 次失败放大成 2^depth 次 —— 失败后端就是一场请求风暴。
            if error.message.hasPrefix(OpenAICompatibleProvider.emptyContentMessagePrefix) {
                log?.warn("TranslationPipeline", "空内容与块大小无关，不拆块", [
                    "items": "\(items.count)",
                    "code": error.code.rawValue,
                    "message": error.message
                ])
                return ChunkOutcome(items: [], error: error, backend: settings.effectiveBackend)
            }
            // 其余 badResponse 只看 code，不看 message 文案：之前要求消息里含「条数」，
            // 而真机上抛的是 "content 不是 JSON 数组"，于是拆块一次都没触发，整块 41~120 条全灭。
            guard splitDepth > 0, error.code == .badResponse, items.count > 1 else {
                return ChunkOutcome(items: [], error: error, backend: settings.effectiveBackend)
            }
            log?.warn("TranslationPipeline", "块解析失败，对半拆块重发", [
                "items": "\(items.count)",
                "remainingDepth": "\(splitDepth)",
                "code": error.code.rawValue,
                "message": error.message
            ])
            let middle = items.count / 2
            let left = await runSubchunk(
                provider: provider,
                settings: settings,
                items: Array(items[..<middle]),
                delays: delays,
                splitDepth: splitDepth - 1,
                log: log
            )
            let right = await runSubchunk(
                provider: provider,
                settings: settings,
                items: Array(items[middle...]),
                delays: delays,
                splitDepth: splitDepth - 1,
                log: log
            )
            var merged = ChunkOutcome(backend: left.items.isEmpty ? right.backend : left.backend)
            merged.items = left.items
            merged.items.append(contentsOf: right.items)
            // 一个叶子成功、另一个失败时**仍保留 error**：drainOneBatch 按"整波一条都没交付"
            // 判失败（熔断语义不变），但 FullTextController 需要这个 error 才能立刻把剩下的
            // key 标失败，而不是干等 90s 超时。
            merged.error = left.error ?? right.error
            merged.didSplitForParse = true
            // 记下"拆到多大就成功了"：父层据此更新自适应批量上限。
            let leftBest = left.didSplitForParse ? left.splitSuccessSize
                : (left.items.isEmpty ? nil : middle)
            let rightBest = right.didSplitForParse ? right.splitSuccessSize
                : (right.items.isEmpty ? nil : items.count - middle)
            merged.splitSuccessSize = [leftBest, rightBest].compactMap { $0 }.max()
            return merged
        }
    }

    /// 段数不符的条目**单独重发一次**。
    ///
    /// 为什么值得重试：段数漂移是模型输出层的随机偏差（多写一个分隔符、把相邻两段并成一句），
    /// 不是请求本身有问题。真机日志里一次全文翻译 5530 条中 20 条（0.36%）中招，
    /// 单独重发能救回其中大多数。
    ///
    /// **只重试一次，且由调用方限流**：再失败说明这条的段边界在中文里确实不可保
    /// （中文语序与日文不同，`如果|解放者|牵扯其中的话` 这类断点无法逐段对齐），
    /// 再发只会重复计费。
    ///
    /// - Returns: 校验通过的结果；仍失败返回 nil（调用方把原始错误记进 `itemErrors`）。
    nonisolated static func retryAfterSegmentMismatch(
        provider: TranslatorProvider,
        settings: Settings,
        item: TranslationRequestItem,
        glossary: [GlossaryPair]?,
        emphasis: [GlossaryPair]?,
        log: SessionLog?
    ) async -> TranslationResultItem? {
        let request = TranslationRequest(
            items: [item],
            srcLang: settings.srcLang,
            tgtLang: settings.tgtLang,
            backend: settings.effectiveBackend,
            timeoutMs: singleRequestTimeoutMs(settings: settings, itemCount: 1),
            requestId: UUID().uuidString,
            glossary: glossary,
            emphasis: emphasis
        )
        do {
            let results = try await provider.translate([request])
            guard let first = results.first?.items.first else { return nil }
            let segments = try Segmenter.translatedSegments(
                segments: item.segments,
                translatedText: first.translatedText
            )
            _ = try Segmenter.reassemble(segments: item.segments, translatedText: first.translatedText)
            return TranslationResultItem(
                key: item.key,
                translatedText: first.translatedText,
                translatedSegments: segments,
                cached: false,
                latencyMs: first.latencyMs
            )
        } catch let error as MochiBoxError {
            log?.warn("TranslationPipeline", "单条段数重试未取回可用译文", [
                "key": String(item.key.prefix(8)),
                "code": error.code.rawValue,
                "message": error.message
            ])
            return nil
        } catch {
            log?.warn("TranslationPipeline", "单条段数重试异常", [
                "key": String(item.key.prefix(8)),
                "message": "\(error)"
            ])
            return nil
        }
    }

    // MARK: - 重试

    nonisolated static func runWithRetries(
        provider: TranslatorProvider,
        request: TranslationRequest,
        delays: [Int]
    ) async -> Result<TranslationResult, MochiBoxError> {
        var attempt = 0
        while true {
            do {
                let results = try await provider.translate([request])
                if let first = results.first {
                    return .success(first)
                }
                return .failure(MochiBoxError(code: .badResponse, message: "后端没有返回任何结果"))
            } catch let error as MochiBoxError {
                let canRetry = error.retryable && attempt < delays.count
                if canRetry {
                    let delayMs = delays[attempt]
                    attempt += 1
                    if delayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    }
                    continue
                }
                return .failure(error)
            } catch {
                return .failure(MochiBoxError(code: .network, underlying: "\(error)"))
            }
        }
    }

    // MARK: - 通知

    private func notifyHandlers(_ result: PipelineBatchResult) {
        for handler in handlers {
            handler(result)
        }
    }

    private func noteErrorNotice(_ error: ErrorInfo) {
        let now = Date()
        if let last = lastNoticeAt[error.code], now.timeIntervalSince(last) < K.errorNoticeDedupSec {
            return
        }
        lastNoticeAt[error.code] = now
        log?.warn("TranslationPipeline", "后端错误", ["code": error.code.rawValue, "httpStatus": "\(error.httpStatus ?? 0)"])
    }
}
