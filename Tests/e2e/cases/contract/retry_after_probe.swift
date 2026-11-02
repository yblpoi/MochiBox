//
//  retry_after_probe.swift —— 429 Retry-After 的解析、上限与实际退避探针
//
//  不属于产品源码：被测文件 + 本文件由 21_retry_after.mjs 现编现跑，产物落 mkdtemp。
//
//  覆盖：
//    RA-1  delta-seconds：1 / 2（带空白）/ 0
//    RA-2  上限：60s 截到 K.retryAfterCapMs（10s）
//    RA-3  HTTP-date：IMF-fixdate / RFC 850 换算成相对毫秒
//    RA-4  HTTP-date 已过期 → 0
//    RA-5  非法值 / 空值 → nil（回落固定退避，不卡死）
//    RA-6  mapStatus(429) 把值带进 MochiBoxError；无头时为 nil
//    RA-7  401 仍不可重试（Retry-After 只属于 429）
//    RA-8  真实等待：带 Retry-After: 1 的 429 → 第二次调用在 ~1s 后，不是 500ms
//    RA-9  对照：不带该头的 429 → 第二次调用在 ~500ms 后（固定表仍在）
//
//  时间断言用 900ms / 1800ms 的宽窗：CI 上 Task.sleep 的唤醒误差远小于 400ms，
//  而两档退避相差 500ms，窗口不会把两者混为一谈。
//

import Foundation

final class Reporter {
    private var total = 0
    private var pass = 0
    private var fail = 0

    func check(_ id: String, _ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok { pass += 1 } else { fail += 1 }
        let label = name.replacingOccurrences(of: "\n", with: " ")
        if ok {
            print("ok \(total) - \(id) \(label)")
        } else {
            print("not ok \(total) - \(id) \(label) # 断言不成立")
            for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
                print("#   \(line)")
            }
        }
    }

    func eq(_ id: String, _ name: String, _ actual: String, _ expected: String) {
        check(id, name, actual == expected, "期望: \(expected)\n实际: \(actual)")
    }

    func finish() -> Int32 {
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        return fail == 0 ? 0 : 1
    }
}

/// 第一次抛指定错误、之后成功；记录每次调用的墙钟时刻。
final class RetryStub: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var recorded: [Date] = []
    private let failure: MochiBoxError

    init(failure: MochiBoxError) {
        self.failure = failure
    }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        let attempt = lock.withLock { () -> Int in
            recorded.append(Date())
            return recorded.count
        }
        if attempt == 1 { throw failure }
        guard let request = batch.first else { return [] }
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

    var times: [Date] { lock.withLock { recorded } }
    var callCount: Int { lock.withLock { recorded.count } }
}

@main
struct RetryAfterProbe {
    static func makeRequest() -> TranslationRequest {
        let item = TranslationRequestItem(
            key: "k1",
            text: "テスト",
            segments: [Segment(kind: .text, value: "テスト")]
        )
        return TranslationRequest(
            items: [item], srcLang: "ja", tgtLang: "zh-Hans", backend: .openai,
            timeoutMs: 5000, requestId: UUID().uuidString
        )
    }

    static func main() async {
        let tap = Reporter()

        // MARK: - 解析

        tap.eq("RA-1a", "整数秒 1 → 1000ms", "\(RetryAfter.parse("1") ?? -1)", "1000")
        tap.eq("RA-1b", "整数秒带空白 2 → 2000ms", "\(RetryAfter.parse(" 2 ") ?? -1)", "2000")
        tap.eq("RA-1c", "0 秒 → 0ms", "\(RetryAfter.parse("0") ?? -1)", "0")
        tap.eq("RA-2", "60s 截断到上限", "\(RetryAfter.parse("60") ?? -1)", "\(K.retryAfterCapMs)")
        tap.eq("RA-2b", "上限常量是 10s", "\(K.retryAfterCapMs)", "10000")

        // 784111775 = 1994-11-06 08:49:35 GMT
        let now = Date(timeIntervalSince1970: 784_111_775)
        tap.eq("RA-3", "HTTP-date 差 2s → 2000ms",
               "\(RetryAfter.parse("Sun, 06 Nov 1994 08:49:37 GMT", now: now) ?? -1)", "2000")
        tap.eq("RA-3b", "RFC 850 日期同样可解析",
               "\(RetryAfter.parse("Sunday, 06-Nov-94 08:49:37 GMT", now: now) ?? -1)", "2000")
        tap.eq("RA-4", "过期 HTTP-date → 0",
               "\(RetryAfter.parse("Sun, 06 Nov 1994 08:49:30 GMT", now: now) ?? -1)", "0")
        tap.eq("RA-5a", "非法字符串 → nil", "\(RetryAfter.parse("soon") ?? -1)", "-1")
        tap.eq("RA-5b", "空字符串 → nil", "\(RetryAfter.parse("   ") ?? -1)", "-1")
        tap.eq("RA-5c", "nil → nil", "\(RetryAfter.parse(nil) ?? -1)", "-1")

        // MARK: - mapStatus 携带

        let body = Data("{\"error\":\"slow down\"}".utf8)
        let limited = HTTPPoster.mapStatus(429, body: body, retryAfterMs: 1000)
        tap.eq("RA-6a", "429 → rate_limited", limited?.code.rawValue ?? "-", "rate_limited")
        tap.eq("RA-6b", "429 携带 retryAfterMs", "\(limited?.retryAfterMs ?? -1)", "1000")
        tap.check("RA-6c", "429 仍可重试", limited?.retryable == true)
        let limitedNoHeader = HTTPPoster.mapStatus(429, body: body)
        tap.eq("RA-6d", "无 Retry-After 时 retryAfterMs 为 nil",
               "\(limitedNoHeader?.retryAfterMs ?? -1)", "-1")
        let auth = HTTPPoster.mapStatus(401, body: body, retryAfterMs: 1000)
        tap.eq("RA-7a", "401 → auth_failed", auth?.code.rawValue ?? "-", "auth_failed")
        tap.check("RA-7b", "401 不可重试（Retry-After 不改变语义）", auth?.retryable == false)

        // MARK: - 实际等待（对照组先跑，避免缓存/顺序影响）

        let ignored = MochiBoxError(code: .rateLimited)
        tap.eq("RA-9a", "对照：不带头的 429 retryAfterMs 为 nil", "\(ignored.retryAfterMs ?? -1)", "-1")

        let fixedStub = RetryStub(failure: ignored)
        let fixedResult = await TranslationPipeline.runWithRetries(
            provider: fixedStub, request: makeRequest(), delays: [500, 1000, 2000]
        )
        if case .success = fixedResult {
            tap.check("RA-9b", "对照：固定退避重试后成功", true)
        } else {
            tap.check("RA-9b", "对照：固定退避重试后成功", false, "未成功")
        }
        let fixedGapMs = fixedStub.callCount >= 2
            ? Int(fixedStub.times[1].timeIntervalSince(fixedStub.times[0]) * 1000)
            : -1
        tap.check("RA-9c", "对照：第二次调用约 500ms 后（固定表）",
                  fixedGapMs >= 400 && fixedGapMs < 900, "实测 \(fixedGapMs)ms")

        let instructed = MochiBoxError(code: .rateLimited, httpStatus: 429, retryAfterMs: 1000)
        let retryStub = RetryStub(failure: instructed)
        let retryResult = await TranslationPipeline.runWithRetries(
            provider: retryStub, request: makeRequest(), delays: [500, 1000, 2000]
        )
        if case .success = retryResult {
            tap.check("RA-8a", "带 Retry-After 的 429 重试后成功", true)
        } else {
            tap.check("RA-8a", "带 Retry-After 的 429 重试后成功", false, "未成功")
        }
        tap.eq("RA-8b", "只重试一次", "\(retryStub.callCount)", "2")
        let retryGapMs = retryStub.callCount >= 2
            ? Int(retryStub.times[1].timeIntervalSince(retryStub.times[0]) * 1000)
            : -1
        tap.check("RA-8c", "第二次调用约 1000ms 后（服务端指示，不是 500ms）",
                  retryGapMs >= 900 && retryGapMs < 1800, "实测 \(retryGapMs)ms")
        tap.check("RA-8d", "实际等待明显长于固定退避", retryGapMs > fixedGapMs + 300,
                  "retryAfter=\(retryGapMs)ms fixed=\(fixedGapMs)ms")

        exit(tap.finish())
    }
}
