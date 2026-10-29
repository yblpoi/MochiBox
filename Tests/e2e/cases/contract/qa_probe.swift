//
// qa_probe.swift —— QA 独立探针（不属于产品源码；只编译被测文件 + 本文件）
//
// 覆盖：
//   V4S Swift 侧 SkipRules + 跳过不写缓存/不打后端（+ 与 Agent 侧的 9 样本 parity 在 10_skip_parity）
//   V6  EngineDetector（13 类引擎正例 + 冲突优先级 + 空目录/非目录/只有 index.html/大小写/隐藏文件）
//   V5  HTTP 错误码映射（401/429/500/非 JSON/超时）——需要传 --http-base <url>
//
// 编译与运行： node Tests/e2e/cases/contract/12_domain_qa.mjs
//   （swiftc 现编现跑，产物落 mkdtemp 目录；本地 error_server.py 由该脚本起停）
//

import Foundation
import Darwin

final class Reporter {
    private var pass = 0
    private var fail = 0
    private var total = 0

    /// TAP 13：run.mjs 会把本进程的编号重新并入总计划。
    /// 失败时把 detail 逐行作为诊断输出 —— 诊断里必须带"期望 vs 实际"，否则红了没法定位。
    func check(_ id: String, _ name: String, _ ok: Bool, _ detail: String) {
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

    func finish() -> Int32 {
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        return fail == 0 ? 0 : 1
    }
}

@main
struct QAProbe {
    static func main() async {
        let reporter = Reporter()
        skipRules(reporter)
        await cachePurity(reporter)
        engineDetection(reporter)
        await httpErrorMapping(reporter)
        exit(reporter.finish())
    }

    // MARK: - V4.3 跳过不写缓存（复刻 SessionController 的规范顺序）

    static func cachePurity(_ r: Reporter) async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MochiBox-qa-cache-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheURL = root.appendingPathComponent("cache.ja-zh-Hans.jsonl")

        let cache = TranslationCache(url: cacheURL, maxEntries: 100, log: nil)
        await cache.load()

        var settings = Settings()
        settings.backendType = .openai
        settings.endpoint = "http://127.0.0.1:1" // 不会被真正使用：命中跳过就不入队
        settings.allowSendTextToBackend = true
        let snapshot = settings
        let counter = Counter()
        let pipeline = TranslationPipeline(
            cache: cache,
            provider: { CountingProvider(counter: counter) },
            settings: { snapshot },
            log: nil
        )

        let samples = ["350", "！？", "   ", "３５０", "350 ", "こんにちは"]
        for raw in samples {
            let segments = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
            let mapKey = Segmenter.mapKey(segments)
            // SessionController.handleText 的规范顺序：先 skipReason，命中即 return（不入队/不查缓存/不写缓存）。
            if SkipRules.skipReason(for: mapKey, enabled: true, minLength: K.minTranslateLength) != nil {
                continue
            }
            let key = Segmenter.cacheKey(engineFamily: K.engineFamily, srcLang: "ja", tgtLang: "zh-Hans", segments: segments)
            _ = await pipeline.resolve([TranslationRequestItem(key: key, text: mapKey, segments: segments)])
            await pipeline.flush()
        }
        await cache.flush()

        let data = (try? Data(contentsOf: cacheURL)) ?? Data()
        let lines = String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let texts = lines.compactMap { line -> String? in
            guard let d = line.data(using: .utf8),
                  let entry = try? FileIO.decoder.decode(CacheEntry.self, from: d) else { return nil }
            return entry.text
        }
        let dirty = texts.filter { SkipRules.skipReason(for: $0, enabled: true, minLength: K.minTranslateLength) != nil }
        r.check("V4S-6a", "跳过句不产生缓存条目",
                dirty.isEmpty && texts.count == 1 && texts.first == "こんにちは",
                "entries=\(texts) dirty=\(dirty)")
        r.check("V4S-6b", "跳过句不触发后端调用", counter.value == 1, "backendCalls=\(counter.value) (期望仅『こんにちは』1 次)")

        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - V4 Swift 侧 SkipRules

    static func skipRules(_ r: Reporter) {
        func expectSkip(_ id: String, _ raw: String, _ want: String?, _ r: Reporter) {
            let actual = SkipRules.skipReason(for: raw, enabled: true, minLength: K.minTranslateLength)
            r.check(id, "SkipRules(\(json(raw)))", actual == want, "expected \(want ?? "nil") actual \(actual ?? "nil")")
        }

        // 含数字但非纯数字 —— 必须翻译
        expectSkip("V4S-1a", "今日は8月15日です", nil, r)
        expectSkip("V4S-1b", "宝箱が3つある", nil, r)
        expectSkip("V4S-1c", "HPは100/100", nil, r)
        expectSkip("V4S-1d", "10秒後", nil, r)
        expectSkip("V4S-1e", "第2章", nil, r)
        expectSkip("V4S-1f", "350G", nil, r)
        // 纯数字 / 纯标点 / 纯空白 —— 必须跳过
        expectSkip("V4S-2a", "350", "numeric", r)
        expectSkip("V4S-2b", "！？", "punctuation", r)
        expectSkip("V4S-2c", "   ", "whitespace", r)
        // PRD §5.1 明确要求：全角数字、尾空格必须与 "350" 同判
        expectSkip("V4S-2d", "３５０", "numeric", r)
        expectSkip("V4S-2e", "350 ", "numeric", r)
        // 全角拉丁字母/字母数字混合（不是 P/S）
        expectSkip("V4S-5a", "３５０Ｇ", nil, r)
        expectSkip("V4S-5b", "ＯＫ", nil, r)
        // 合法符号（So）
        expectSkip("V4S-5c", "♪", "punctuation", r)
        expectSkip("V4S-5d", "★", "punctuation", r)

        // 剥码后判定：\C[2]350 → mapKey "350"
        let controlRaw = "\\C[2]350"
        let segments = Segmenter.splitSegments(raw: controlRaw, engineFamily: K.engineFamily)
        let mapKey = Segmenter.mapKey(segments)
        let reason = SkipRules.skipReason(for: mapKey, enabled: true, minLength: K.minTranslateLength)
        r.check("V4S-3a", "\\C[2]350 剥码后判为跳过", reason == "numeric", "mapKey=\(json(mapKey)) reason=\(reason ?? "nil")")
        // 原文原样保留（分段不会丢掉 code 段）
        let rawRoundTrip = segments.map { $0.value }.joined()
        r.check("V4S-3b", "\\C[2]350 分段原样可回拼", rawRoundTrip == controlRaw, "roundTrip=\(json(rawRoundTrip))")

        let antiRaw = "\\C[2]10秒後"
        let antiSegments = Segmenter.splitSegments(raw: antiRaw, engineFamily: K.engineFamily)
        let antiReason = SkipRules.skipReason(for: Segmenter.mapKey(antiSegments), enabled: true, minLength: K.minTranslateLength)
        r.check("V4S-3c", "\\C[2]10秒後 不得跳过", antiReason == nil, "negative reason=\(antiReason ?? "nil")")

        // 归一化口径：cacheKey 与 skip 判定应同源。
        // 断言的**实际**内容是"两者给出一致的结论"（a == b），不是"存在缺陷"；
        // 缺陷回归靠 V4S-2e（"350 " 必须判 numeric）钉住。
        let a = SkipRules.skipReason(for: "350 ", enabled: true, minLength: K.minTranslateLength)
        let b = SkipRules.skipReason(for: Segmenter.normalizeForKey("350 "), enabled: true, minLength: K.minTranslateLength)
        r.check("V4S-4a", "SkipRules 对 '350 ' 与归一化后的键给出相同跳过判定", a == b, "raw=\(a ?? "nil") normalized=\(b ?? "nil")")
    }

    // MARK: - V6 引擎识别

    static func engineDetection(_ r: Reporter) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MochiBox-qa-engines-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        @discardableResult
        func touch(_ relative: String, _ contents: String = "x") -> URL {
            let url = root.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.data(using: .utf8)?.write(to: url)
            return url
        }

        func expect(_ id: String, _ path: URL, _ engine: EngineKind, _ level: SupportLevel, _ reason: EngineReason?) {
            let result = EngineDetector.detect(path)
            let ok = result.engine == engine && result.supportLevel == level && result.reason == reason
            r.check(id, "detect(\(path.lastPathComponent))",
                    ok,
                    "expected \(engine.rawValue)/\(level.rawValue)/\(reason?.rawValue ?? "nil") actual \(result.engine.rawValue)/\(result.supportLevel.rawValue)/\(result.reason?.rawValue ?? "nil") evidence=\(result.evidence)")
        }

        // 1 mz
        touch("e_mz/js/rmmz_core.js")
        expect("V6-01", root.appendingPathComponent("e_mz"), .mz, .p0, nil)
        // 2 mv
        touch("e_mv/www/js/rpg_core.js")
        expect("V6-02", root.appendingPathComponent("e_mv"), .mv, .p0, nil)
        // 3 .app/Contents/Resources/app.nw
        let appURL = root.appendingPathComponent("e_app/Sample.app", isDirectory: true)
        touch("e_app/Sample.app/Contents/Resources/app.nw/www/js/rpg_core.js")
        expect("V6-03", appURL, .mv, .p0, nil)
        // 4 renpy
        touch("e_renpy/game/script.rpy")
        expect("V6-04", root.appendingPathComponent("e_renpy"), .renpy, .p1, nil)
        // 5 kirikiri
        touch("e_krkr/data/startup.tjs")
        expect("V6-05", root.appendingPathComponent("e_krkr"), .kirikiri, .p2, nil)
        // 6 easyrpg（两文件缺一不可）
        touch("e_easyrpg/RPG_RT.ldb")
        touch("e_easyrpg/RPG_RT.lmt")
        expect("V6-06", root.appendingPathComponent("e_easyrpg"), .easyrpg, .p2, nil)
        // 7 rgss3
        touch("e_rgss3/Game.ini", "[Game]\nLibrary=RGSS3.dll\n")
        expect("V6-07", root.appendingPathComponent("e_rgss3"), .rgss3, .p2, nil)
        // 8 tyrano
        touch("e_tyrano/data/system/Config.tjs")
        touch("e_tyrano/tyrano/tyrano.js")
        expect("V6-08", root.appendingPathComponent("e_tyrano"), .tyrano, .p0, nil)
        // 9 wolf
        touch("e_wolf/Data.wolf")
        expect("V6-09", root.appendingPathComponent("e_wolf"), .wolf, .p2, nil)
        // 10 unity
        touch("e_unity/Sample_Data/globalgamemanagers")
        expect("V6-10", root.appendingPathComponent("e_unity"), .unity, .none, nil)
        // 11 godot
        touch("e_godot/project.godot")
        expect("V6-11", root.appendingPathComponent("e_godot"), .godot, .none, nil)
        // 12 siglus
        touch("e_siglus/Scene.pck")
        expect("V6-12", root.appendingPathComponent("e_siglus"), .siglus, .none, nil)
        // 13 冲突：mz + mv → 取优先级小者 + signature_conflict
        touch("e_conflict/js/rmmz_core.js")
        touch("e_conflict/www/js/rpg_core.js")
        expect("V6-13", root.appendingPathComponent("e_conflict"), .mz, .p0, .signatureConflict)
        // 14 空目录
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("e_empty"), withIntermediateDirectories: true)
        expect("V6-14", root.appendingPathComponent("e_empty"), .unknown, .unknown, .emptyDirectory)
        // 15 非目录
        let file = touch("e_file.txt")
        expect("V6-15", file, .unknown, .unknown, .notADirectory)
        // 16 easyrpg 缺 lmt → unknown
        touch("e_easyrpg_partial/RPG_RT.ldb")
        expect("V6-16", root.appendingPathComponent("e_easyrpg_partial"), .unknown, .unknown, .noSignatureMatched)

        // ---- 以下是本次迁移补齐的反例 / 优先级 / 大小写 ----
        // 17 rgss2：13 条签名里的最后一类，原探针只覆盖了 12 类正例
        touch("e_rgss2/Game.ini", "[Game]\nLibrary=RGSS2.dll\n")
        expect("V6-17", root.appendingPathComponent("e_rgss2"), .rgss2, .p2, nil)
        // 18 Scene.pck 是 siglus 的精确包名，必须优先于 godot 的 *.pck 通配
        touch("e_scenepck/Scene.pck")
        expect("V6-18", root.appendingPathComponent("e_scenepck"), .siglus, .none, nil)
        // 19 其它 *.pck → godot
        touch("e_godotpck/game.pck")
        expect("V6-19", root.appendingPathComponent("e_godotpck"), .godot, .none, nil)
        // 20 只有 index.html → 未命中任何签名（tyrano 还要求 data/system/Config.tjs）
        touch("e_index/index.html", "<html></html>")
        expect("V6-20", root.appendingPathComponent("e_index"), .unknown, .unknown, .noSignatureMatched)
        // 21 大小写反例：Game.ini 的值必须逐字匹配 Library=RGSS3
        touch("e_rgss_lower/Game.ini", "[Game]\nLibrary=rgss3\n")
        expect("V6-21", root.appendingPathComponent("e_rgss_lower"), .unknown, .unknown, .noSignatureMatched)
        // 22 大小写正例：后缀匹配按小写比较（Data/SCENARIO.RVDATA2 仍是 rgss3）
        touch("e_rgss_upper/Data/SCENARIO.RVDATA2")
        expect("V6-22", root.appendingPathComponent("e_rgss_upper"), .rgss3, .p2, nil)
        // 23 只有隐藏文件 → 视为空目录（.DS_Store 不得让识别"看起来有内容"）
        touch("e_hidden/.DS_Store")
        expect("V6-23", root.appendingPathComponent("e_hidden"), .unknown, .unknown, .emptyDirectory)
        // 24 .app 里没有 Contents/Resources/app.nw → 扫描根退回 .app 本身，未命中
        touch("e_app_nonw/Sample.app/Contents/Info.plist")
        expect("V6-24", root.appendingPathComponent("e_app_nonw/Sample.app"), .unknown, .unknown, .noSignatureMatched)
        // 25 tyrano 只有 Config.tjs、没有 tyrano.js / index.html#tyrano → 不算命中
        touch("e_tyrano_partial/data/system/Config.tjs")
        expect("V6-25", root.appendingPathComponent("e_tyrano_partial"), .unknown, .unknown, .noSignatureMatched)

        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - V5 HTTP 错误码

    static func httpErrorMapping(_ r: Reporter) async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--http-base"), index + 1 < args.count else {
            r.check("V5-00", "HTTP 错误映射前置条件", false, "未传 --http-base（本地 error_server 未启动）")
            return
        }
        let base = args[index + 1]

        func request() -> TranslationRequest {
            let items = [TranslationRequestItem(key: "k", text: "こんにちは",
                                                segments: [Segment(kind: .text, value: "こんにちは")])]
            return TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans",
                                      backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
        }

        func expect(_ id: String, _ path: String, _ code: ErrorCode, _ httpStatus: Int?, _ retryable: Bool) async {
            let provider = OpenAICompatibleProvider(endpoint: base + path, apiKey: "sk-qa-should-not-leak-1234", model: "m")
            do {
                _ = try await provider.translate([request()])
                r.check(id, path, false, "expected error \(code.rawValue), got success")
            } catch let error as MochiBoxError {
                let ok = error.code == code && error.httpStatus == httpStatus && error.retryable == retryable
                let leak = (error.message + (error.rawSnippet ?? "") + (error.underlying ?? "")).contains("sk-qa-should-not-leak")
                r.check(id, path, ok && !leak,
                        "expected \(code.rawValue)/\(httpStatus.map(String.init) ?? "nil")/retry=\(retryable) actual \(error.code.rawValue)/\(error.httpStatus.map(String.init) ?? "nil")/retry=\(error.retryable) keyLeak=\(leak)")
            } catch {
                r.check(id, path, false, "非 MochiBoxError：\(error)")
            }
        }

        await expect("V5-01", "/401", .authFailed, 401, false)
        await expect("V5-02", "/429", .rateLimited, 429, true)
        await expect("V5-03", "/500", .badResponse, 500, true)
        // 非 JSON：PRD 只要求"明确错误码"，未要求带 httpStatus；此处按 nil 断言，
        // 另外单列一条观察项，避免把实现细节当验收。
        await expect("V5-04", "/nonjson", .badResponse, nil, false)

        // 超时：服务端 sleep 3s，客户端 timeoutMs=500
        let provider = OpenAICompatibleProvider(endpoint: base + "/slow", apiKey: "sk-qa-should-not-leak-1234", model: "m")
        let items = [TranslationRequestItem(key: "k", text: "こんにちは",
                                            segments: [Segment(kind: .text, value: "こんにちは")])]
        let slowRequest = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans",
                                             backend: .openai, timeoutMs: 500, requestId: UUID().uuidString)
        do {
            _ = try await provider.translate([slowRequest])
            r.check("V5-05", "/slow", false, "expected timeout, got success")
        } catch let error as MochiBoxError {
            r.check("V5-05", "/slow", error.code == .timeout, "expected timeout actual \(error.code.rawValue)")
        } catch {
            r.check("V5-05", "/slow", false, "非 MochiBoxError：\(error)")
        }
    }

    static func json(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8), str.count >= 2 else { return "\"\(text)\"" }
        return String(str.dropFirst().dropLast())
    }
}

// MARK: - 测试桩

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}

struct CountingProvider: TranslatorProvider {
    let counter: Counter
    var kind: BackendKind { .openai }
    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        counter.increment()
        return batch.map { request in
            TranslationResult(
                requestId: request.requestId,
                items: request.items.map { item in
                    TranslationResultItem(key: item.key, translatedText: "译:" + item.text,
                                          translatedSegments: nil, cached: false, latencyMs: 1)
                },
                backend: .openai,
                error: nil
            )
        }
    }
}
