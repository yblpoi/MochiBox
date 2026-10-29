//
//  probe_resilience.swift
//  MochiBox · E2E 领域层探针（韧性 P0-13 / 直通 P0-11）
//
//  用 --only D5 / D6 只跑对应段。
//
//  这一层为什么能测：产品把"传输层"做成了可注入的接缝 ——
//  TranslationPipeline 的 provider 是闭包（每批重新取），
//  ResiliencePolicy 的 retryDelaysMs / breakerThreshold / breakerOpenSec 都是可写字段，
//  CircuitBreaker 的 recordFailure(now:) / canAttempt(now:) 接受注入时钟。
//  所以这里**没有为了测试改产品**，也没有等真实的 3.5s 退避或 30s 熔断：
//  真实常量（500/1000/2000ms、30s）用常量断言钉住，行为用缩小后的延迟/注入时钟验证。
//
//  依据：docs/prd.md P0-13 / P0-11；Sources/Infra/Translators.swift:395-497；
//  Sources/Domain/TranslationPipeline.swift:252-409；Sources/App/Constants.swift。
//

import Foundation

// MARK: - 记录型 provider（产品自带的 TranslatorProvider 接缝）

final class RecordingProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var recorded: [(count: Int, timeoutMs: Int)] = []
    private var active = 0
    private var peak = 0

    var failWith: MochiBoxError?
    var delayNs: UInt64 = 0

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        guard let request = batch.first else { return [] }
        lock.withLock {
            recorded.append((request.items.count, request.timeoutMs))
            active += 1
            if active > peak { peak = active }
        }

        if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }

        lock.withLock { active -= 1 }

        if let error = failWith { throw error }
        let items = request.items.map { item in
            TranslationResultItem(
                key: item.key,
                translatedText: item.text,
                translatedSegments: nil,
                cached: false,
                latencyMs: 1
            )
        }
        return [TranslationResult(requestId: request.requestId, items: items, backend: kind, error: nil)]
    }

    var callCount: Int { return lock.withLock { recorded.count } }

    var itemCounts: [Int] { return lock.withLock { recorded.map { $0.count } } }

    var timeouts: [Int] { return lock.withLock { recorded.map { $0.timeoutMs } } }

    var peakConcurrency: Int { return lock.withLock { peak } }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineBatchResult] = []

    func append(_ result: PipelineBatchResult) {
        lock.withLock { storage.append(result) }
    }

    var all: [PipelineBatchResult] { return lock.withLock { storage } }

    var last: PipelineBatchResult? { return all.last }

    /// 熔断窗口的播报（items 必须为空）。
    var circuitNotifications: [PipelineBatchResult] {
        return all.filter { $0.error?.code == .circuitOpen }
    }

    /// 所有交付的译文（熔断播报不带 item，不会混进来）。
    var deliveredItems: [TranslationResultItem] {
        return all.flatMap { $0.items }
    }
}

/// 只在小块成功的后端：超过 limit 条一律 badResponse，不超过则正常翻译。
///
/// 复现「块太大」而不是「后端坏了」：真机上 41~120 条全灭、40 条以下 0 失败。
final class LeafLimitProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    let limit: Int
    private let lock = NSLock()
    private var recorded: [Int] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        guard let request = batch.first else { return [] }
        lock.withLock { recorded.append(request.items.count) }
        guard request.items.count <= limit else {
            throw MochiBoxError(
                code: .badResponse,
                message: "content 不是 JSON 数组；前 160 字：块太大（\(request.items.count) > \(limit)）"
            )
        }
        let items = request.items.map { item in
            TranslationResultItem(
                key: item.key,
                translatedText: "译:" + item.text,
                translatedSegments: nil,
                cached: false,
                latencyMs: 1
            )
        }
        return [TranslationResult(requestId: request.requestId, items: items, backend: .openai, error: nil)]
    }

    var itemCounts: [Int] { return lock.withLock { recorded } }
}

/// 恒定返回「空内容」的后端：finish_reason=length（推理吃掉 token 预算）。
final class EmptyContentProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var recorded = 0

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        lock.withLock { recorded += 1 }
        throw MochiBoxError(
            code: .badResponse,
            message: OpenAICompatibleProvider.emptyContentMessagePrefix
                + "（finish_reason=length）：输出被截断，可在设置→高级设置调大最大输出 tokens"
        )
    }

    var callCount: Int { return lock.withLock { recorded } }
}

// MARK: - 素材

enum Fixture {
    static func item(_ index: Int, _ text: String? = nil) -> TranslationRequestItem {
        let raw = text ?? ("こんにちは、" + String(index) + "番目の台詞です")
        let segments = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
        return TranslationRequestItem(key: Segmenter.mapKey(segments), text: raw, segments: segments)
    }

    static func request(_ items: [TranslationRequestItem], timeoutMs: Int = 15_000) -> TranslationRequest {
        return TranslationRequest(
            items: items,
            srcLang: K.fixedSrcLang,
            tgtLang: K.fixedTgtLang,
            backend: .openai,
            timeoutMs: timeoutMs,
            requestId: UUID().uuidString
        )
    }
}

@main
struct DomainResilienceProbe {
    static func main() async {
        let args = ProbeArgs()
        switch args.only {
        case "D5": await d5(args)
        case "D6": await d6(args)
        case "D19": await d19(args)
        default: TAP.ok("probe", "未知 --only 参数", false, "only=\(args.only)")
        }
        exit(TAP.finish())
    }

    // MARK: - D5 韧性（P0-13）

    static func d5(_ args: ProbeArgs) async {
        // ① 常量与 PRD 的对应关系（真实值不能被削弱）
        TAP.eq("D5", "K：窗口 120ms / maxBatch 60 / 并发 4 / 超时 15s",
               "\(K.batchWindowMs)|\(K.maxBatch)|\(K.maxConcurrent)|\(K.requestTimeoutSec)",
               "120|60|4|15")
        TAP.eq("D5", "K：attach 单发上限 20 / 单请求字数预算 4000 / max_tokens 0=自动",
               "\(K.attachMaxBatch)|\(K.batchCharBudget)|\(K.maxOutputTokens)", "20|4000|0")
        TAP.eq("D5", "K：重试退避 0.5s/1s/2s", K.retryDelaysMs.map { String($0) }.joined(separator: "/"), "500/1000/2000")
        TAP.eq("D5", "K：熔断阈值 5 次 / 打开 30s",
               "\(K.circuitBreakerThreshold)|\(Int(K.circuitBreakerOpenSec))", "5|30")
        TAP.eq("D5", "Settings 默认值透传同一组常量",
               "\(Settings().batchWindowMs)|\(Settings().maxBatch)|\(Settings().maxConcurrent)|\(Settings().timeoutSec)",
               "120|60|4|15")
        TAP.eq("D5", "Settings 默认单请求字数预算 / max_tokens（0=自动）",
               "\(Settings().batchCharBudget)|\(Settings().maxOutputTokens)", "4000|0")

        // ② 合批：50 条 ≤ maxBatch(60) → 1 块、1 次请求（不再被 maxConcurrent 二次均分）
        let dir = args.root.appendingPathComponent("pipeline")
        Fs.make(dir)
        var settings = Settings()
        settings.backendType = .openai
        settings.endpoint = "http://127.0.0.1:1"
        settings.batchWindowMs = 0          // 缩短等待：窗口行为单独用 120ms 测（见 ③）
        let pipelineSettings = settings
        let provider = RecordingProvider()
        provider.delayNs = 30_000_000       // 让块真正重叠，才能观测并发峰值
        let cache = TranslationCache(url: dir.appendingPathComponent("cache-a.jsonl"), maxEntries: 1000, log: nil)
        await cache.load()
        let pipeline = TranslationPipeline(
            cache: cache,
            provider: { provider },
            settings: { pipelineSettings },
            policy: ResiliencePolicy(),
            log: nil
        )

        let batch = (0..<50).map { Fixture.item($0) }
        let outcomes = await pipeline.resolve(batch)
        let pendingCount = outcomes.filter { if case .pending = $0 { return true }; return false }.count
        TAP.eqInt("D5", "50 条新译全部入队（pending=50）", pendingCount, 50)
        await pipeline.flush()

        let counts = provider.itemCounts.sorted()
        TAP.eqInt("D5", "50 条只发 1 次请求（≤ maxBatch 60 时不再二次均分）", provider.callCount, 1)
        TAP.eq("D5", "每次请求条数为 [50]（整批一块）",
               counts.map { String($0) }.joined(separator: ","), "50")
        TAP.ok("D5", "没有任何一次请求超过 maxBatch(60)", (counts.last ?? 0) <= K.maxBatch, counts.description)
        TAP.ok("D5", "并发峰值不超过 maxConcurrent(4)", provider.peakConcurrency <= K.maxConcurrent,
               "峰值=\(provider.peakConcurrency)")
        TAP.eqInt("D5", "后端收到的条目总数 = 50（无丢条/重复）", counts.reduce(0, +), 50)
        TAP.ok("D5", "每个请求超时 ≥15000ms（P0-13 下限）",
               provider.timeouts.allSatisfy { $0 >= 15_000 }, provider.timeouts.description)
        // 写死的公式：max(timeoutSec*1000, 15000 + 条数×250)。不是"全都 15000"了。
        let expectedTimeouts = counts.map { max(15_000, 15_000 + $0 * 250) }
        TAP.eq("D5", "超时 = max(15000, 15000 + 条数×250)",
               provider.timeouts.map { String($0) }.joined(separator: ","),
               expectedTimeouts.map { String($0) }.joined(separator: ","))
        let smallTimeouts = provider.timeouts

        // ②b 240 条 → 4 块 × 60（chunkCount = min(maxConcurrent, ceil(240/60)) = 4）
        let bulkProvider = RecordingProvider()
        bulkProvider.delayNs = 30_000_000
        let bulkCache = TranslationCache(url: dir.appendingPathComponent("cache-bulk.jsonl"), maxEntries: 2000, log: nil)
        await bulkCache.load()
        let bulkPipeline = TranslationPipeline(
            cache: bulkCache,
            provider: { bulkProvider },
            settings: { pipelineSettings },
            policy: ResiliencePolicy(),
            log: nil
        )
        let bulkItems = (0..<240).map { Fixture.item($0) }
        _ = await bulkPipeline.resolve(bulkItems)
        await bulkPipeline.flush()

        let bulkCounts = bulkProvider.itemCounts
        TAP.eqInt("D5", "240 条 → 4 次请求（maxBatch×maxConcurrent 封顶）", bulkProvider.callCount, 4)
        TAP.ok("D5", "每块不超过 maxBatch(60)", bulkCounts.allSatisfy { $0 <= K.maxBatch }, bulkCounts.description)
        TAP.ok("D5", "每块都非空（无空请求）", bulkCounts.allSatisfy { $0 > 0 }, bulkCounts.description)
        TAP.eqInt("D5", "4 块共 240 条（无丢条/重复）", bulkCounts.reduce(0, +), 240)
        TAP.ok("D5", "并发峰值不超过 maxConcurrent(4)", bulkProvider.peakConcurrency <= K.maxConcurrent,
               "峰值=\(bulkProvider.peakConcurrency)")
        TAP.ok("D5", "块间确实并发（峰值 ≥2）", bulkProvider.peakConcurrency >= 2,
               "峰值=\(bulkProvider.peakConcurrency)")
        TAP.ok("D5", "超时随条数单调：60 条的请求 > 50 条的请求",
               (bulkProvider.timeouts.max() ?? 0) > (smallTimeouts.max() ?? 0),
               "50条=\(smallTimeouts.max() ?? 0)ms 60条=\(bulkProvider.timeouts.max() ?? 0)ms")
        TAP.ok("D5", "240 条的块也满足超时 ≥15000ms",
               bulkProvider.timeouts.allSatisfy { $0 >= 15_000 }, bulkProvider.timeouts.description)

        // ③ 合并窗口：单条从入队到首次请求 ≥110ms（K.batchWindowMs=120）
        var windowSettings = settings
        windowSettings.batchWindowMs = K.batchWindowMs
        let windowSettingsSnapshot = windowSettings
        let windowProvider = RecordingProvider()
        let windowCache = TranslationCache(url: dir.appendingPathComponent("cache-b.jsonl"), maxEntries: 100, log: nil)
        await windowCache.load()
        let windowPipeline = TranslationPipeline(
            cache: windowCache,
            provider: { windowProvider },
            settings: { windowSettingsSnapshot },
            policy: ResiliencePolicy(),
            log: nil
        )
        let started = Date()
        _ = await windowPipeline.resolve([Fixture.item(999)])
        await windowPipeline.flush()
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        // 断言名只写判据；实测值放诊断行 —— 否则同一实现两次运行的 TAP 不能逐字节比对。
        TAP.ok("D5", "合并窗口生效：单条请求等待 ≥110ms（K.batchWindowMs=120）",
               elapsedMs >= 110 && elapsedMs <= 3_000, "实测 \(elapsedMs)ms（允许 110–3000）")
        TAP.eqInt("D5", "窗口内单条只发 1 次请求", windowProvider.callCount, 1)

        // ④ 重试：可重试错误 → 1 次首发 + 3 次重试 = 4 次；延迟用注入值（不真等 3.5s）
        let retryProvider = RecordingProvider()
        retryProvider.failWith = MochiBoxError(code: .badResponse, message: "HTTP 500", retryable: true)
        let retryStart = Date()
        let retryResult = await TranslationPipeline.runWithRetries(
            provider: retryProvider,
            request: Fixture.request([Fixture.item(1)]),
            delays: [30, 30, 30]
        )
        let retryElapsed = Date().timeIntervalSince(retryStart)
        TAP.eqInt("D5", "可重试错误重试 3 次（总尝试 4 次）", retryProvider.callCount, 4)
        TAP.ok("D5", "3 次退避确实执行（注入 30ms×3，累计 ≥85ms）",
               retryElapsed >= 0.085, "实测 \(Int(retryElapsed * 1000))ms")
        if case .failure(let error) = retryResult {
            TAP.eq("D5", "重试耗尽后返回原错误码 bad_response", error.code.rawValue, "bad_response")
        } else {
            TAP.ok("D5", "重试耗尽后返回原错误码 bad_response", false, "返回了 success")
        }

        let noRetryProvider = RecordingProvider()
        noRetryProvider.failWith = MochiBoxError(code: .authFailed)
        _ = await TranslationPipeline.runWithRetries(
            provider: noRetryProvider,
            request: Fixture.request([Fixture.item(2)]),
            delays: [30, 30, 30]
        )
        TAP.eqInt("D5", "不可重试错误（401 → auth_failed）不重试（1 次）", noRetryProvider.callCount, 1)

        let emptyDelaysProvider = RecordingProvider()
        emptyDelaysProvider.failWith = MochiBoxError(code: .network, retryable: true)
        _ = await TranslationPipeline.runWithRetries(
            provider: emptyDelaysProvider,
            request: Fixture.request([Fixture.item(3)]),
            delays: []
        )
        TAP.eqInt("D5", "退避表为空时只发 1 次（不无限重试）", emptyDelaysProvider.callCount, 1)

        // ⑤ 熔断器（注入时钟，不真等 30s）
        let breaker = CircuitBreaker(threshold: K.circuitBreakerThreshold, openSeconds: K.circuitBreakerOpenSec)
        for _ in 0..<4 { breaker.recordFailure() }
        TAP.ok("D5", "连续 4 次失败不熔断", !breaker.isOpen && breaker.canAttempt())
        breaker.recordFailure()
        TAP.ok("D5", "第 5 次失败 → 熔断打开", breaker.isOpen)
        TAP.ok("D5", "熔断期 canAttempt=false（请求不发出）", !breaker.canAttempt())
        if let until = breaker.openUntil {
            TAP.ok("D5", "打开后 29s 仍不可试探（半开时刻 = openedAt+30s）",
                   !breaker.canAttempt(now: until.addingTimeInterval(-1)))
            TAP.ok("D5", "30s 后自动半开（canAttempt=true）", breaker.canAttempt(now: until))
        } else {
            TAP.ok("D5", "openUntil 应为非空", false)
        }
        breaker.recordSuccess()
        TAP.ok("D5", "成功后熔断清除并可立即再试", !breaker.isOpen && breaker.canAttempt())
        TAP.ok("D5", "circuit_open 的 retryable 恒为 false（PRD 显式条款）",
               ErrorInfo(code: .circuitOpen).retryable == false)
        TAP.eq("D5", "熔断错误码字面量为 circuit_open", ErrorCode.circuitOpen.rawValue, "circuit_open")

        // ⑥ 管线级熔断：失败达到阈值后**不消费队列、不碰后端、不伪造译文**
        //
        // 真机事故：旧实现在熔断分支把队列里的条目出队后回填"译文 = 原文"，
        // 13 秒内把 7687 条全部"处理"完，调用方把它们当成功译文写进语料。
        // 这里的断言方向全部反过来：items 必须为空、队列必须还在、请求必须是 0。
        var circuitSettings = settings
        circuitSettings.batchWindowMs = 0
        let circuitSettingsSnapshot = circuitSettings
        let failing = RecordingProvider()
        failing.failWith = MochiBoxError(code: .authFailed)
        var policy = ResiliencePolicy()
        policy.retryDelaysMs = []
        // 真实值是 5 次 / 30s；阈值沿用 K，只把窗口压到 1.5s（与 D5 其余用例同口径：
        // 常量用断言钉住，行为用缩小后的时间验证，不把 case 拖 30 秒）。
        policy.breakerOpenSec = 1.5
        let circuitCache = TranslationCache(url: dir.appendingPathComponent("cache-c.jsonl"), maxEntries: 100, log: nil)
        await circuitCache.load()
        let box = ResultBox()
        let circuitPipeline = TranslationPipeline(
            cache: circuitCache,
            provider: { failing },
            settings: { circuitSettingsSnapshot },
            policy: policy,
            log: nil
        )
        await circuitPipeline.onResult { result in box.append(result) }
        for index in 0..<K.circuitBreakerThreshold {
            _ = await circuitPipeline.resolve([Fixture.item(100 + index)])
            await circuitPipeline.flush()
        }
        let status = await circuitPipeline.backendStatus()
        if case .circuitOpen = status {
            TAP.ok("D5", "连续 \(K.circuitBreakerThreshold) 个失败批次后 backendStatus = circuitOpen", true)
        } else {
            TAP.ok("D5", "连续 \(K.circuitBreakerThreshold) 个失败批次后 backendStatus = circuitOpen", false,
                   "实际: \(status.label)")
        }
        let callsBefore = failing.callCount
        let blocked = (0..<3).map { Fixture.item(500 + $0, "熔断中の台詞です" + String($0)) }
        _ = await circuitPipeline.resolve(blocked)
        // 通知在 worker 第一轮（≤500ms）发出；给 2s 上限，超时即判失败。
        if let notice = await waitForCircuitNotice(box, within: 2) {
            TAP.eqInt("D5", "熔断期结果 items 为空（不再伪造译文）", notice.items.count, 0)
            TAP.eq("D5", "熔断期错误码 = circuit_open", notice.error?.code.rawValue ?? "-", "circuit_open")
            TAP.ok("D5", "circuit_open.retryable = false（不得提示立即重试）", notice.error?.retryable == false)
            TAP.ok("D5", "熔断期 backend = passthrough（只作标记、不携带译文）",
                   notice.backend == .passthrough, "实际: \(notice.backend.rawValue)")
        } else {
            TAP.ok("D5", "熔断期应收到一条 circuit_open 通知", false, "2s 内没有任何结果回调")
        }
        TAP.eqInt("D5", "熔断期新请求不产生任何后端调用", failing.callCount, callsBefore)

        // 冷却结束后队列必须原样继续翻译：3 条全部交付，且只发 1 次请求。
        // 旧实现把条目在熔断期就消费掉了，这里会拿到 0 条、且 callCount 不动。
        failing.failWith = nil
        let deliveredAfterCooldown = await waitForDelivered(box, count: 3, within: 6)
        TAP.eqInt("D5", "冷却后队列未被消费：3 条全部交付", deliveredAfterCooldown, 3)
        TAP.eqInt("D5", "冷却后只发 1 次请求（积压原样保留）", failing.callCount, callsBefore + 1)
        await circuitPipeline.flush()
    }

    /// 等第一条 circuit_open 通知（熔断窗口的播报）。
    static func waitForCircuitNotice(_ box: ResultBox, within seconds: Double) async -> PipelineBatchResult? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let notice = box.circuitNotifications.last { return notice }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// 等到至少 count 条译文（返回实际条数，超时也返回当前值）。
    static func waitForDelivered(_ box: ResultBox, count: Int, within seconds: Double) async -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let delivered = box.deliveredItems.count
            if delivered >= count { return delivered }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return box.deliveredItems.count
    }

    // MARK: - D6 直通（P0-11）

    static func d6(_ args: ProbeArgs) async {
        // ① 默认后端 = passthrough
        TAP.ok("D6", "Settings() 默认 backendType = passthrough", Settings().backendType == .passthrough)
        TAP.ok("D6", "Settings() 默认 effectiveBackend = passthrough", Settings().effectiveBackend == .passthrough)
        let factoryDefault = TranslationProviderFactory.make(settings: Settings(), credentials: Credentials())
        TAP.ok("D6", "ProviderFactory 对默认设置返回 PassthroughProvider", factoryDefault.kind == .passthrough)

        // ② provider 层：translatedText 与原文逐字节相等，backend 标记 passthrough
        let item = Fixture.item(1, "\\C[2]こんにちは\u{001F}さようなら")
        let result = try? await PassthroughProvider().translate([Fixture.request([item])])
        if let first = result?.first?.items.first {
            TAP.ok("D6", "PassthroughProvider 译文与原文逐字节相等",
                   Array(first.translatedText.utf8) == Array(item.text.utf8), first.translatedText)
            TAP.ok("D6", "PassthroughProvider 回传的分段与原文一致", first.translatedSegments == item.segments)
        } else {
            TAP.ok("D6", "PassthroughProvider 应返回 1 条译文", false, "没有结果")
        }
        TAP.ok("D6", "PassthroughProvider 结果 backend = passthrough", result?.first?.backend == .passthrough)

        // ③ 管线层：passthrough 下不查缓存、不入队、不碰 provider
        let dir = args.root.appendingPathComponent("passthrough")
        Fs.make(dir)
        let recording = RecordingProvider()
        let cache = TranslationCache(url: dir.appendingPathComponent("cache.jsonl"), maxEntries: 100, log: nil)
        await cache.load()
        let pipeline = TranslationPipeline(
            cache: cache,
            provider: { recording },
            settings: { Settings() },
            policy: ResiliencePolicy(),
            log: nil
        )
        let items = [Fixture.item(10), Fixture.item(11), Fixture.item(12, "\\C[2]選択肢です")]
        let outcomes = await pipeline.resolve(items)
        var passthroughCount = 0
        var byteEqual = true
        for (index, outcome) in outcomes.enumerated() {
            if case .passthrough(let outcomeItem) = outcome {
                passthroughCount += 1
                if Array(outcomeItem.translatedText.utf8) != Array(items[index].text.utf8) { byteEqual = false }
            } else {
                byteEqual = false
            }
        }
        TAP.eqInt("D6", "管线对 3 条输入全部返回 passthrough", passthroughCount, 3)
        TAP.ok("D6", "管线输出的译文与原文逐字节相等（含 \\C[2] 与 U+001F）", byteEqual)
        TAP.eqInt("D6", "passthrough 不走 provider（0 次后端调用）", recording.callCount, 0)
        await pipeline.flush()
        TAP.eqInt("D6", "passthrough 不写缓存（缓存条目 0）", await cache.stats().entries, 0)

        // ④ 合规开关关闭时，即便 backendType=openai 也强制直通，且不产生网络请求
        var compliance = Settings()
        compliance.backendType = .openai
        compliance.endpoint = "http://127.0.0.1:" + String(args.httpPort)
        compliance.allowSendTextToBackend = false
        let complianceSnapshot = compliance
        let forced = TranslationProviderFactory.make(settings: compliance, credentials: Credentials(apiKey: "sk-abcdef123456"))
        TAP.ok("D6", "allowSendTextToBackend=false 时 openai 设置也返回 PassthroughProvider", forced.kind == .passthrough)
        TAP.ok("D6", "effectiveBackend 被强制为 passthrough", compliance.effectiveBackend == .passthrough)

        var enabled = compliance
        enabled.allowSendTextToBackend = true
        let openAI = TranslationProviderFactory.make(settings: enabled, credentials: Credentials(apiKey: "sk-abcdef123456"))
        TAP.ok("D6", "开关打开且 backendType=openai 时返回 OpenAICompatibleProvider（证明强制来自开关）",
               openAI.kind == .openai)

        let complianceProvider = RecordingProvider()
        let compliancePipeline = TranslationPipeline(
            cache: TranslationCache(url: dir.appendingPathComponent("cache-compliance.jsonl"), maxEntries: 100, log: nil),
            provider: { complianceProvider },
            settings: { complianceSnapshot },
            policy: ResiliencePolicy(),
            log: nil
        )
        _ = await compliancePipeline.resolve([Fixture.item(20)])
        await compliancePipeline.flush()
        TAP.eqInt("D6", "合规强制直通时 provider 调用 0 次", complianceProvider.callCount, 0)
    }

    // MARK: - D19 拆块深度与空内容（最终验收回归）

    /// 两个边界：
    ///   ① maxBatch 允许 200，拆块深度写死 4 层只能到 12/13 条 —— 「>8 条必失败」的后端
    ///      会让整波 200 条全丢。深度按本波最大块算（ceil(log2(200)) = 8）才能拆到 6/7 条。
    ///   ② 空内容（finish_reason=length）与块大小无关：5 条按对半拆会发 9 次请求，
    ///      失败后端直接变请求风暴。只允许 1 次。
    static func d19(_ args: ProbeArgs) async {
        let dir = args.root.appendingPathComponent("split")
        Fs.make(dir)

        var settings = Settings()
        settings.backendType = .openai
        settings.endpoint = "http://127.0.0.1:1"
        settings.maxBatch = 200
        settings.maxConcurrent = 4
        settings.batchWindowMs = 0
        // 不让字数预算先切：这一条测的是**条数**拆块。
        settings.batchCharBudget = 20_000
        let snapshot = settings

        // ① 200 条 + 「>8 条必失败」
        let provider = LeafLimitProvider(limit: 8)
        let cache = TranslationCache(url: dir.appendingPathComponent("cache-split.jsonl"), maxEntries: 2000, log: nil)
        await cache.load()
        let pipeline = TranslationPipeline(
            cache: cache,
            provider: { provider },
            settings: { snapshot },
            policy: ResiliencePolicy(),
            log: nil
        )
        let sink = ResultBox()
        await pipeline.onResult { result in sink.append(result) }
        _ = await pipeline.resolve((0..<200).map { Fixture.item($0) })
        await pipeline.flush()

        let counts = provider.itemCounts
        TAP.eqInt("D19", "200 条全部交付（深度按本波最大块 200 算）",
                  Set(sink.deliveredItems.map { $0.key }).count, 200)
        TAP.ok("D19", "请求序列里出现 ≤8 条的叶子（真的拆到底了）",
               counts.contains { $0 <= 8 }, "请求形状=\(counts)")
        TAP.eqInt("D19", "单次请求最大 = maxBatch(200): 不会超发",
                  counts.max() ?? 0, 200)
        TAP.eqInt("D19", "拆块请求数 = 63（1+2+4+8+16+32 失败 + 32 个叶子成功）",
                  counts.count, 63)
        TAP.ok("D19", "每个叶子都 ≤8 条时才成功", counts.filter { $0 <= 8 }.count == 32,
               "叶子数=\(counts.filter { $0 <= 8 }.count)")

        // ② 空内容 + 5 条
        let emptyProvider = EmptyContentProvider()
        let emptyCache = TranslationCache(url: dir.appendingPathComponent("cache-empty.jsonl"), maxEntries: 200, log: nil)
        await emptyCache.load()
        let emptyPipeline = TranslationPipeline(
            cache: emptyCache,
            provider: { emptyProvider },
            settings: { snapshot },
            policy: ResiliencePolicy(),
            log: nil
        )
        let emptySink = ResultBox()
        await emptyPipeline.onResult { result in emptySink.append(result) }
        _ = await emptyPipeline.resolve((1000..<1005).map { Fixture.item($0) })
        await emptyPipeline.flush()

        TAP.eqInt("D19", "空内容 5 条只发 1 次请求（拆块会变 9 次）", emptyProvider.callCount, 1)
        TAP.eqInt("D19", "空内容不交付任何译文", emptySink.deliveredItems.count, 0)
        let message = emptySink.last?.error?.message ?? ""
        TAP.ok("D19", "失败原因带 finish_reason（用户能据此调大输出 tokens）",
               message.contains("finish_reason=length"), "实际=\(message)")
        TAP.ok("D19", "同一条错误仍按 bad_response 上报（可重试语义不变）",
               emptySink.last?.error?.code == .badResponse, "实际=\(emptySink.last?.error?.code.rawValue ?? "-")")
    }
}
