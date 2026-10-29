//
//  SelfTestRunner.swift
//  MochiBox
//
//  `--selftest`：TAP 风格输出，用例分组（A 引擎识别 / B 缓存与分段 / C HTTP 后端 /
//  D Agent via JavaScriptCore / E 协议编解码 / F Web 运行后端与启动 / G 会话设置同步）。
//  约束：全程不初始化 NSApplication、不写用户目录（临时目录隔离）、无网络也可运行，
//  **默认不拉起任何浏览器**（F 组的真浏览器用例要 `MOCHI_SELFTEST_BROWSER=1` 才跑，
//  否则打 TAP `# SKIP`；真浏览器的硬门禁是 `Tests/e2e/run.sh`）。
//

import Foundation
import JavaScriptCore
import Network

// MARK: - 基础设施

struct SelfTestContext: Sendable {
    var tempRoot: URL
    var verbose: Bool
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { return message }
}

struct SelfTestCase {
    let group: String
    let name: String
    /// 非 nil 时这条用例**不执行**，按 TAP 打印 `ok N - … # SKIP <原因>`。
    ///
    /// 只用于**主动 opt-in**（默认会拉起真浏览器的用例）；不能拿"环境里缺东西"
    /// 来冒充 skip —— 那会让"没测"看起来像"测过了"。
    var skip: String? = nil
    let run: (SelfTestContext) async throws -> Void
}

enum SelfTestRunner {

    // MARK: - 入口

    /// 阻塞式入口：用 `dispatchMain()` 驱动主队列（不创建 NSApplication）。
    static func bootstrap(_ args: [String]) -> Never {
        let verbose = args.contains("--verbose")
        var filter: String?
        if let index = args.firstIndex(of: "--filter"), index + 1 < args.count {
            filter = args[index + 1]
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MochiBox-selftest-\(getpid())", isDirectory: true)

        Task.detached {
            let code = await run(filter: filter, verbose: verbose, tempRoot: tempRoot)
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }

    static func run(filter: String?, verbose: Bool, tempRoot: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let context = SelfTestContext(tempRoot: tempRoot, verbose: verbose)

        print("TAP version 13")
        if verbose {
            // P0-18 的 `--verbose`：不是换个输出格式，而是把"被测对象的实际值"打到 stderr 侧，
            // 便于定位失败时不必重跑。默认关闭，避免正常输出被噪声淹没。
            // 编号比 cases.count 多 1：收尸自检（`no_orphan_browser`）是跑完所有用例后追加的一条。
            print("# verbose: cases=\(cases.count) (+1 orphan gate) filter=\(filter ?? "-") tempRoot=\(tempRoot.path)")
        }
        var index = 0
        var pass = 0
        var fail = 0
        var skip = 0

        for test in cases {
            if let filter = filter, !filter.isEmpty {
                let matches = test.group == filter
                    || test.name.contains(filter)
                    || "[\(test.group)]".contains(filter)
                if !matches { continue }
            }
            index += 1
            // 主动 opt-in 的用例（会真拉起浏览器）：默认整条跳过，但**必须**在 TAP 里
            // 留下 `# SKIP` 与原因，否则"没跑"会被读成"跑了并且过了"。
            if let reason = test.skip {
                skip += 1
                print("ok \(index) - [\(test.group)] \(test.name) # SKIP \(reason)")
                fflush(stdout)
                continue
            }
            let startedAt = Date()
            if verbose { print("# case [\(test.group)] \(test.name) …") }
            do {
                try await test.run(context)
                pass += 1
                print("ok \(index) - [\(test.group)] \(test.name)")
                if verbose {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    print("# case [\(test.group)] \(test.name) pass \(elapsed)ms")
                }
            } catch {
                fail += 1
                let detail = "\(error)"
                print("not ok \(index) - [\(test.group)] \(test.name): \(detail)")
                if verbose {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    print("# case [\(test.group)] \(test.name) fail \(elapsed)ms")
                }
            }
            fflush(stdout)
        }

        // 收尸自检：任何一条用例把浏览器丢在本次临时根里，这一轮就必须红
        // （注入缺陷实验留下的那批孤儿就是这么被抓住的）。报告后仍会尽力清掉，
        // 免得机器上越攒越多 —— 但**结果已经记成 fail**，不会被清理掩盖。
        index += 1
        let leaked = await reapSelftestBrowsers(tempRoot: tempRoot)
        if leaked.isEmpty {
            pass += 1
            print("ok \(index) - [F] no_orphan_browser")
        } else {
            fail += 1
            print("not ok \(index) - [F] no_orphan_browser: \(tempRoot.path) 下仍有浏览器进程 \(leaked)")
        }
        fflush(stdout)

        print("# pass \(pass) fail \(fail) skip \(skip)")
        try? FileManager.default.removeItem(at: tempRoot)
        return (fail == 0 && pass > 0) ? 0 : 1
    }

    /// 只在 `--verbose` 下输出的细节行（`# note …`）。
    static func note(_ context: SelfTestContext, _ message: @autoclosure () -> String) {
        if context.verbose { print("# note \(message())") }
    }

    // MARK: - 断言

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition {
            throw SelfTestFailure(message: message())
        }
    }

    static func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) throws {
        if lhs != rhs {
            throw SelfTestFailure(message: "\(label): 期望 \(rhs)，实际 \(lhs)")
        }
    }

    // MARK: - 临时目录工具

    static func directory(_ context: SelfTestContext, _ name: String) throws -> URL {
        let url = context.tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func touch(_ root: URL, _ relativePath: String, contents: String = "") throws {
        let url = root.appendingPathComponent(relativePath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = contents.data(using: .utf8) else { return }
        try data.write(to: url)
    }

    // MARK: - 用例表

    static var cases: [SelfTestCase] {
        // F 组（v0.2 Web 运行后端）的用例定义在 `WebCaseSupport.swift` 里，
        // 逃生码 parity（`escapeCaseCases`）定义在 `EscapeCaseSupport.swift` 里。
        return engineCases + cacheCases + httpCases + agentCases + codecCases
            + webCases + escapeCases + launcherCases + sessionCases
    }
}

// MARK: - A 组：引擎识别

extension SelfTestRunner {
    static var engineCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "A", name: "mz_signature") { context in
                let root = try directory(context, "a_mz")
                try touch(root, "js/rmmz_core.js", contents: "// rmmz core")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .mz, "engine")
                try expectEqual(result.supportLevel, .p0, "supportLevel")
                try expect(result.reason == nil, "reason 应为 nil，实际 \(String(describing: result.reason))")
                try expect(result.evidence.contains("js/rmmz_core.js"), "evidence 应含 js/rmmz_core.js")
            },
            SelfTestCase(group: "A", name: "mv_signature") { context in
                let root = try directory(context, "a_mv")
                try touch(root, "www/js/rpg_core.js", contents: "// rpg core")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .mv, "engine")
                try expectEqual(result.supportLevel, .p0, "supportLevel")
            },
            SelfTestCase(group: "A", name: "app_nw_layout") { context in
                let outer = try directory(context, "a_app_nw")
                let appURL = outer.appendingPathComponent("Sample.app", isDirectory: true)
                try touch(appURL, "Contents/Resources/app.nw/www/js/rpg_core.js", contents: "// rpg core")
                try touch(appURL, "Contents/Info.plist", contents: "<plist/>")
                let result = EngineDetector.detect(appURL)
                try expectEqual(result.engine, .mv, "engine(.app/Contents/Resources/app.nw)")
                try expectEqual(EngineDetector.normalizedScanRoot(appURL).lastPathComponent, "app.nw", "扫描根归一")
            },
            SelfTestCase(group: "A", name: "renpy_game_dir") { context in
                let root = try directory(context, "a_renpy")
                try touch(root, "game/script.rpy", contents: "label start:")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .renpy, "engine")
                try expectEqual(result.supportLevel, .p1, "supportLevel")
            },
            SelfTestCase(group: "A", name: "kirikiri_startup") { context in
                let root = try directory(context, "a_kirikiri")
                try touch(root, "data/startup.tjs", contents: "// tjs")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .kirikiri, "engine")
                try expectEqual(result.supportLevel, .p2, "supportLevel")
            },
            SelfTestCase(group: "A", name: "easyrpg_requires_both") { context in
                let root = try directory(context, "a_easyrpg")
                try touch(root, "RPG_RT.ldb", contents: "LDB")
                try touch(root, "RPG_RT.lmt", contents: "LMT")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .easyrpg, "engine")
                let partial = try directory(context, "a_easyrpg_partial")
                try touch(partial, "RPG_RT.ldb", contents: "LDB")
                let partialResult = EngineDetector.detect(partial)
                try expectEqual(partialResult.engine, .unknown, "只有 ldb 不应识别为 easyrpg")
            },
            SelfTestCase(group: "A", name: "rgss3_game_ini") { context in
                let root = try directory(context, "a_rgss3")
                try touch(root, "Game.ini", contents: "[Game]\nLibrary=RGSS3.dll\n")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .rgss3, "engine")
            },
            SelfTestCase(group: "A", name: "unity_data_dir") { context in
                let root = try directory(context, "a_unity")
                try touch(root, "Sample_Data/globalgamemanagers", contents: "binary")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .unity, "engine")
                try expectEqual(result.supportLevel, .none, "supportLevel")
            },
            SelfTestCase(group: "A", name: "tyrano_config") { context in
                let root = try directory(context, "a_tyrano")
                try touch(root, "data/system/Config.tjs", contents: "// config")
                try touch(root, "tyrano/tyrano.js", contents: "// tyrano")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .tyrano, "engine")
            },
            SelfTestCase(group: "A", name: "conflict_prefers_priority") { context in
                let root = try directory(context, "a_conflict")
                try touch(root, "js/rmmz_core.js", contents: "// mz")
                try touch(root, "www/js/rpg_core.js", contents: "// mv")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .mz, "冲突时应取优先级更小者（mz）")
                try expectEqual(result.reason, .signatureConflict, "reason")
            },
            SelfTestCase(group: "A", name: "empty_directory") { context in
                let root = try directory(context, "a_empty")
                let result = EngineDetector.detect(root)
                try expectEqual(result.engine, .unknown, "engine")
                try expectEqual(result.reason, .emptyDirectory, "reason")
                try expectEqual(result.supportLevel, .unknown, "supportLevel")
            },
            SelfTestCase(group: "A", name: "not_a_directory") { context in
                let root = try directory(context, "a_not_dir")
                try touch(root, "file.txt", contents: "x")
                let fileURL = root.appendingPathComponent("file.txt")
                let result = EngineDetector.detect(fileURL)
                try expectEqual(result.engine, .unknown, "engine")
                try expectEqual(result.reason, .notADirectory, "reason")
            }
        ]
    }
}

// MARK: - B 组：缓存与分段

extension SelfTestRunner {
    static var cacheCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "B", name: "key_normalization") { context in
                let a = Segmenter.splitSegments(raw: "\\C[2]魔物　が来た ", engineFamily: "mvmz")
                let b = Segmenter.splitSegments(raw: "\\C[2]魔物 が来た", engineFamily: "mvmz")
                let keyA = Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: a)
                let keyB = Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: b)
                try expectEqual(keyA, keyB, "NFKC/空白折叠后 key 应相同")
                try expectEqual(keyA.count, 64, "sha256 hex 长度")
                try expect(keyA.rangeOfCharacter(from: CharacterSet.uppercaseLetters) == nil, "key 必须是小写 hex")
                let keyOther = Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hant", segments: a)
                try expect(keyA != keyOther, "不同语言对必须产生不同 key")
                let fullwidth = Segmenter.normalizeForKey("ＡＢＣ")
                let narrow = Segmenter.normalizeForKey("ABC")
                try expectEqual(fullwidth, narrow, "NFKC 全角折叠")

                // 归一化必须作用于"join 之后的整串"（不是逐段归一后再 join）：
                // 否则尾随空格与全角数字会造出两个缓存条目 —— 重复计费 + 命中率虚低，
                // 而界面上完全看不出来（架构 T03 / PRD §5.1）。
                func cacheKeyOf(_ raw: String) -> String {
                    return Segmenter.cacheKey(
                        engineFamily: K.engineFamily,
                        srcLang: K.fixedSrcLang,
                        tgtLang: K.fixedTgtLang,
                        segments: Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
                    )
                }
                try expectEqual(cacheKeyOf("こんにちは "), cacheKeyOf("こんにちは"), "尾随空格必须归一到同一 key")
                try expectEqual(cacheKeyOf("３５０"), cacheKeyOf("350"), "全角数字必须归一到同一 key")
                try expect(cacheKeyOf("こんにちは") != cacheKeyOf("こんばんは"), "不同文本必须不同 key")

                // 归一化的两条边界（缺一条都会毁掉分段或让键"时对时不对"）：
                //  · 只折叠 PRD 列举的 5 个空白 → TAB 与空格等价，但空格不能被吃掉；
                //  · `U+001F` 是段分隔符，绝不能参与折叠（否则 "AB"+"C" 与 "A"+"BC" 撞键）。
                try expectEqual(cacheKeyOf("甲\t乙"), cacheKeyOf("甲 乙"), "TAB 与空格必须折叠成同一个键")
                try expect(cacheKeyOf("甲 乙") != cacheKeyOf("甲乙"), "空格不得被吃掉（否则两句撞键）")
                note(context, "key 对照：'こんにちは '=\(cacheKeyOf("こんにちは ").prefix(12)) " +
                             "'こんにちは'=\(cacheKeyOf("こんにちは").prefix(12)) " +
                             "'３５０'=\(cacheKeyOf("３５０").prefix(12)) '350'=\(cacheKeyOf("350").prefix(12)) " +
                             "'甲\\t乙'=\(cacheKeyOf("甲\t乙").prefix(12)) '甲 乙'=\(cacheKeyOf("甲 乙").prefix(12)) " +
                             "'甲乙'=\(cacheKeyOf("甲乙").prefix(12))")

                /// 按 U+001F 切分后逐段移除折叠白名单里的 5 个码位 —— 用来证明"段结构没被归一化破坏"。
                /// 不能用"比较 U+001F 的下标序列"：空白折叠会让后面所有字符下标前移，
                /// 正确实现也过不了（架构已撤回该判据）。
                func partsWithoutBlanks(_ text: String) -> [String] {
                    return text.components(separatedBy: K.unitSeparatorString)
                        .map { Segmenter.strippingFoldableWhitespace($0) }
                }
                let twoParts: [Segment] = [
                    Segment(kind: .text, value: "甲  "),
                    Segment(kind: .text, value: " 乙")
                ]
                let joinedTwo = Segmenter.joinForBackend(twoParts)
                let normalizedTwo = Segmenter.normalizeForKey(joinedTwo)
                let separatorsBefore = joinedTwo.components(separatedBy: K.unitSeparatorString).count - 1
                let separatorsAfter = normalizedTwo.components(separatedBy: K.unitSeparatorString).count - 1
                try expectEqual(separatorsBefore, 1, "两段之间的 U+001F 个数")
                try expectEqual(separatorsAfter, separatorsBefore, "归一后 U+001F 个数必须不变")
                try expectEqual(separatorsAfter, Segmenter.textSegmentCount(twoParts) - 1, "U+001F 个数必须 == text 段数 − 1")
                try expectEqual(partsWithoutBlanks(normalizedTwo), partsWithoutBlanks(joinedTwo),
                                "按 U+001F 切分后段内容序列必须完全一致")

                // `mapKey` 侧**绝不归一**（§6.2.1 契约 1）：它必须与页面字符串逐字节一致，
                // 否则 Agent 按 `inbox()` 的键查不到自己的 Map，症状是"翻译成功但画面永远是原文"。
                let rawWithSpace = Segmenter.splitSegments(raw: "こんにちは ", engineFamily: K.engineFamily)
                try expectEqual(Segmenter.mapKey(rawWithSpace), "こんにちは ", "mapKey 必须保留原始空白")
                try expect(Segmenter.mapKey(rawWithSpace) != Segmenter.normalizeForKey(Segmenter.mapKey(rawWithSpace)),
                           "mapKey ≠ normalizeForKey(mapKey) 是设计如此")
            },
            SelfTestCase(group: "B", name: "segment_key_distinct") { context in
                let ab: [Segment] = [Segment(kind: .text, value: "AB"), Segment(kind: .text, value: "C")]
                let a_bc: [Segment] = [Segment(kind: .text, value: "A"), Segment(kind: .text, value: "BC")]
                let key1 = Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: ab)
                let key2 = Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: a_bc)
                try expect(key1 != key2, "U+001F 分隔必须避免 AB|C 与 A|BC 撞 key")
                try expectEqual(Segmenter.textSegmentCount(ab), 2, "text 段数")
                let raw = try Segmenter.reassemble(segments: [
                    Segment(kind: .code, value: "\\C[2]"),
                    Segment(kind: .text, value: "魔物"),
                    Segment(kind: .code, value: "\\G")
                ], translatedText: "魔物")
                try expectEqual(raw, "\\C[2]魔物\\G", "回填必须保持转义码位置")
                do {
                    _ = try Segmenter.reassemble(segments: ab, translatedText: "只有一段")
                    throw SelfTestFailure(message: "段数不匹配时必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .segmentMismatch, "错误码")
                }

                // MARK: 三层身份（PRD P0-08）：行身份 = surface+raw，翻译身份 = cacheKey，行 id 唯一
                //
                // ⚠ 样本要成对看，单个样本只能测一件事（PM/架构都纠过一次）：
                //   样本 A：`350` + `\C[2]350` —— 都 `skipped`，**不产生任何请求**，只能验"行身份按 raw"；
                //          用它验"计费=1"是恒真（因为压根没请求），测不出"两行各发一次请求"的过度修复。
                //   样本 B：`こんにちは` + `\C[2]こんにちは` —— 剥码后 text 相同（同一 cacheKey）、raw 不同，
                //          都 `pending`，才能同时验"两行 + 一次计费 + 扇出"。
                let surface = "Window_Base.drawTextEx"

                func cacheKeyOf(_ raw: String) -> String {
                    return Segmenter.cacheKey(
                        engineFamily: K.engineFamily,
                        srcLang: K.fixedSrcLang,
                        tgtLang: K.fixedTgtLang,
                        segments: Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
                    )
                }

                // 用 `@Sendable` 闭包而不是局部 func：下面要在 `MainActor.run` 里并发执行它。
                let payloadOf: @Sendable (String, Int) throws -> AgentTextPayload = { raw, frame in
                    let segments = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
                    let segmentsData = try JSONEncoder().encode(segments)
                    let segmentsObject = try JSONSerialization.jsonObject(with: segmentsData)
                    let object: [String: Any] = [
                        "ts": 1000.0,
                        "frame": frame,
                        "surface": surface,
                        "raw": raw,
                        "segments": segmentsObject,
                        "text": Segmenter.joinForBackend(segments),
                        "key": Segmenter.mapKey(segments),
                        "status": "pending"
                    ]
                    return try JSONDecoder().decode(
                        AgentTextPayload.self,
                        from: try JSONSerialization.data(withJSONObject: object)
                    )
                }

                // ---- 样本 A：行身份按 raw（两条都 skipped，不碰后端）----
                try expectEqual(cacheKeyOf("350"), cacheKeyOf("\\C[2]350"), "350 与 \\C[2]350 必须共享 cacheKey")
                try expect(TextStreamStore.rowIdentity(surface: surface, raw: "350")
                            != TextStreamStore.rowIdentity(surface: surface, raw: "\\C[2]350"),
                           "行身份必须按 raw 区分（不能按 cacheKey）")
                let sampleA = try await MainActor.run { () -> (Int, Set<String>) in
                    let store = TextStreamStore(maxRows: 100)
                    let key = Segmenter.cacheKey(
                        engineFamily: K.engineFamily, srcLang: K.fixedSrcLang, tgtLang: K.fixedTgtLang,
                        segments: Segmenter.splitSegments(raw: "350", engineFamily: K.engineFamily)
                    )
                    _ = store.ingest(try payloadOf("350", 7), cacheKey: key, sessionId: "s", gameId: "g")
                    _ = store.ingest(try payloadOf("\\C[2]350", 7), cacheKey: key, sessionId: "s", gameId: "g")
                    return (store.rows.count, Set(store.rows.map { $0.key }))
                }
                try expectEqual(sampleA.0, 2, "同帧 350 与 \\C[2]350 必须是 2 行（行身份按 raw）")
                try expectEqual(sampleA.1.count, 1, "两行必须共享同一个 cacheKey")

                // ---- 样本 B：成功扇出（两行都离开 pending）+ 唯一计费身份 ----
                let sampleB = try await MainActor.run { () -> (Int, [String]) in
                    let store = TextStreamStore(maxRows: 100)
                    let key = Segmenter.cacheKey(
                        engineFamily: K.engineFamily, srcLang: K.fixedSrcLang, tgtLang: K.fixedTgtLang,
                        segments: Segmenter.splitSegments(raw: "こんにちは", engineFamily: K.engineFamily)
                    )
                    _ = store.ingest(try payloadOf("こんにちは", 8), cacheKey: key, sessionId: "s", gameId: "g")
                    _ = store.ingest(try payloadOf("\\C[2]こんにちは", 8), cacheKey: key, sessionId: "s", gameId: "g")
                    let rowCount = store.rows.count
                    // 一条后端结果（成功路径）：必须扇出填满两行。
                    store.applyTranslation(
                        cacheKey: key,
                        translatedRaw: "你好",
                        segments: [Segment(kind: .text, value: "你好")],
                        backend: .openai,
                        latencyMs: 3,
                        cached: false
                    )
                    return (rowCount, store.rows.map { $0.status.rawValue })
                }
                try expectEqual(sampleB.0, 2, "こんにちは 与 \\C[2]こんにちは 必须是 2 行")
                try expect(sampleB.1.allSatisfy { $0 == "translated" },
                           "一条结果必须扇出，两行都应变 translated（只改一行时另一行永久 pending），实际 \(sampleB.1)")

                // ---- 样本 B'：错误扇出（401 / 超时 / 段数不匹配走同一条路径）----
                let sampleBError = try await MainActor.run { () -> [String] in
                    let store = TextStreamStore(maxRows: 100)
                    let key = Segmenter.cacheKey(
                        engineFamily: K.engineFamily, srcLang: K.fixedSrcLang, tgtLang: K.fixedTgtLang,
                        segments: Segmenter.splitSegments(raw: "こんにちは", engineFamily: K.engineFamily)
                    )
                    _ = store.ingest(try payloadOf("こんにちは", 9), cacheKey: key, sessionId: "s", gameId: "g")
                    _ = store.ingest(try payloadOf("\\C[2]こんにちは", 9), cacheKey: key, sessionId: "s", gameId: "g")
                    store.applyError(cacheKey: key, error: ErrorInfo(code: .authFailed, message: "401"))
                    return store.rows.map { $0.status.rawValue }
                }
                try expect(sampleBError.allSatisfy { $0 == "error" },
                           "错误路径也必须扇出，两行都应变 error（只改一行 = 一行报错一行转圈），实际 \(sampleBError)")

                // ---- 计费身份：同一 cacheKey 只能产生 1 次后端调用（防"过度修复"）----
                let counter = CallCounter()
                let billingCacheURL = try directory(context, "b_billing").appendingPathComponent("cache.ja-zh-Hans.jsonl")
                let billingCache = TranslationCache(url: billingCacheURL, maxEntries: 100)
                await billingCache.load()
                var billingSettings = Settings()
                billingSettings.backendType = .openai
                billingSettings.endpoint = "http://127.0.0.1:1"
                let billingSnapshot = billingSettings
                let billingPipeline = TranslationPipeline(
                    cache: billingCache,
                    provider: { return CountingProvider(counter: counter) },
                    settings: { return billingSnapshot }
                )
                let billingKey = cacheKeyOf("こんにちは")
                let itemPlain = TranslationRequestItem(
                    key: billingKey,
                    text: "こんにちは",
                    segments: Segmenter.splitSegments(raw: "こんにちは", engineFamily: K.engineFamily)
                )
                let itemControl = TranslationRequestItem(
                    key: billingKey,
                    text: "こんにちは",
                    segments: Segmenter.splitSegments(raw: "\\C[2]こんにちは", engineFamily: K.engineFamily)
                )
                _ = await billingPipeline.resolve([itemPlain, itemControl])
                await billingPipeline.flush()
                try expectEqual(counter.value, 1, "同一 cacheKey 的两行只能产生 1 次后端调用（不重复计费）")
                await billingCache.flush()

                // `--verbose` 的 detail 行（`grep -i rowIdentity` 能看到实际值）。
                let identityPlain = TextStreamStore.rowIdentity(surface: surface, raw: "350")
                let identityControl = TextStreamStore.rowIdentity(surface: surface, raw: "\\C[2]350")
                note(context, "rowIdentity 350=[\(identityPlain)] control=[\(identityControl)] 两者不同=\(identityPlain != identityControl)")
                note(context, "样本A rows=\(sampleA.0) cacheKey数=\(sampleA.1.count)；" +
                             "样本B rows=\(sampleB.0) statuses=\(sampleB.1)；" +
                             "样本B' statuses=\(sampleBError)；计费计数=\(counter.value)")
            },
            SelfTestCase(group: "B", name: "cache_persist_no_second_call") { context in
                let root = try directory(context, "b_cache")
                let cacheURL = root.appendingPathComponent("cache.ja-zh-Hans.jsonl")
                let counter = CallCounter()

                let cache = TranslationCache(url: cacheURL, maxEntries: 1000)
                await cache.load()

                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                let settingsSnapshot = settings

                let pipeline = TranslationPipeline(
                    cache: cache,
                    provider: { return CountingProvider(counter: counter) },
                    settings: { return settingsSnapshot },
                    log: nil
                )

                let segments = [Segment(kind: .text, value: "こんにちは")]
                let item = TranslationRequestItem(
                    key: Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: segments),
                    text: "こんにちは",
                    segments: segments
                )

                let first = await pipeline.resolve([item])
                guard let firstOutcome = first.first else {
                    throw SelfTestFailure(message: "resolve 没有返回结果")
                }
                switch firstOutcome {
                case .pending:
                    break
                default:
                    throw SelfTestFailure(message: "首次 resolve 应为 pending，实际 \(firstOutcome)")
                }
                await pipeline.flush()
                try expectEqual(counter.value, 1, "首次应调用后端 1 次")
                await cache.flush()

                let second = await pipeline.resolve([item])
                guard let secondOutcome = second.first else {
                    throw SelfTestFailure(message: "第二次 resolve 没有返回结果")
                }
                switch secondOutcome {
                case .hit:
                    break
                default:
                    throw SelfTestFailure(message: "第二次 resolve 应为 hit，实际 \(secondOutcome)")
                }
                try expectEqual(counter.value, 1, "命中缓存后不得再次调用后端")

                // 重启模拟：重建缓存实例，仍能命中。
                let reopened = TranslationCache(url: cacheURL, maxEntries: 1000)
                await reopened.load()
                let cached = await reopened.get(item.key)
                try expect(cached != nil, "重建 store 后应命中同 key")
                try expectEqual((cached?.translatedText ?? ""), "译:こんにちは", "缓存内容")
            },
            SelfTestCase(group: "B", name: "segment_empty_piece_tolerance") { _ in
                let two: [Segment] = [
                    Segment(kind: .text, value: "甲"),
                    Segment(kind: .text, value: "乙")
                ]
                // 真机日志里最常见的形态：尾随分隔符（`啊…\u{1F}要去了…要去了…\u{1F}`）。
                try expectEqual(try Segmenter.reassemble(segments: two, translatedText: "甲\u{1F}乙\u{1F}"),
                                "甲乙", "尾随空段必须剔除")
                // 连续分隔符（模型在段边界多敲了一下）。
                try expectEqual(try Segmenter.reassemble(segments: two, translatedText: "甲\u{1F}\u{1F}乙"),
                                "甲乙", "连续空段必须剔除")
                // 两个函数必须同判：否则显示串与导出段会不一致。
                let segments = try Segmenter.translatedSegments(segments: two, translatedText: "甲\u{1F}乙\u{1F}")
                try expectEqual(Segmenter.translatedTextPieces(segments), ["甲", "乙"], "段数组同样要剔除空段")

                // 段数真的不够 → 仍要抛错，不能靠“补空段”蒙混过关。
                do {
                    _ = try Segmenter.reassemble(segments: two, translatedText: "只有一段")
                    throw SelfTestFailure(message: "段数不足必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .segmentMismatch, "错误码")
                }
                // 原文 1 段、译文被拆成 2 段**非空** → 仍抛错：不得把两句硬塞回一段。
                do {
                    _ = try Segmenter.reassemble(segments: [Segment(kind: .text, value: "让发出声")],
                                                 translatedText: "让\u{1F}发出声")
                    throw SelfTestFailure(message: "多出的非空段必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .segmentMismatch, "错误码")
                }
            },
            SelfTestCase(group: "B", name: "pipeline_segment_mismatch_retry") { context in
                // 段数漂移是模型输出抖动：首次多一段，单条重发拿回正确段数。
                let root = try directory(context, "b_segment_retry")
                let cache = TranslationCache(
                    url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"),
                    maxEntries: 1000
                )
                await cache.load()
                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.maxBatch = 10
                settings.maxConcurrent = 1
                settings.batchWindowMs = 0
                let snapshot = settings
                let provider = SegmentDriftProvider()
                let pipeline = TranslationPipeline(cache: cache, provider: { provider }, settings: { snapshot })
                let sink = PipelineSink()
                await pipeline.onResult { sink.append($0) }

                let segments: [Segment] = [
                    Segment(kind: .text, value: "テスト用の台詞です"),
                    Segment(kind: .text, value: "もう一つの台詞です")
                ]
                let item = TranslationRequestItem(
                    key: Segmenter.mapKey(segments),
                    text: Segmenter.joinForBackend(segments),
                    segments: segments
                )
                _ = await pipeline.resolve([item])
                await pipeline.flush()

                try expectEqual(provider.callCount, 2, "首次 + 单条重试")
                try expectEqual(sink.items.count, 1, "重试成功后必须交付")
                try expectEqual(sink.items.first?.translatedText,
                                "译0\u{1F}译1", "必须用第二次返回的译文")
                try expect(sink.itemErrors.isEmpty, "重试成功不得留下单条错误")
                try expect(sink.lastError == nil, "单条段数失败不得升级成块级 error")
                await cache.flush()
            },
            SelfTestCase(group: "B", name: "pipeline_segment_mismatch_item_error") { context in
                // 两次都漂移：只把这一条标失败，整块不得降级（熔断也不记账）。
                let root = try directory(context, "b_segment_item_error")
                let cache = TranslationCache(
                    url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"),
                    maxEntries: 1000
                )
                await cache.load()
                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.maxBatch = 10
                settings.maxConcurrent = 1
                settings.batchWindowMs = 0
                let snapshot = settings
                let provider = SegmentDriftProvider(alwaysDrift: true)
                let pipeline = TranslationPipeline(cache: cache, provider: { provider }, settings: { snapshot })
                let sink = PipelineSink()
                await pipeline.onResult { sink.append($0) }

                let segments: [Segment] = [
                    Segment(kind: .text, value: "テスト用の台詞です"),
                    Segment(kind: .text, value: "もう一つの台詞です")
                ]
                let item = TranslationRequestItem(
                    key: Segmenter.mapKey(segments),
                    text: Segmenter.joinForBackend(segments),
                    segments: segments
                )
                _ = await pipeline.resolve([item])
                await pipeline.flush()

                try expectEqual(provider.callCount, 2, "只重试一次，不循环计费")
                try expect(sink.items.isEmpty, "两次都漂移 → 不交付")
                try expectEqual(sink.itemErrors[item.key]?.code, .segmentMismatch, "单条错误必须按 key 落账")
                try expect(sink.lastError == nil, "不得升级成块级 error（否则整波标 degraded）")
                await cache.flush()
            },
            SelfTestCase(group: "B", name: "pipeline_split_on_parse_failure") { context in
                // 真机现场：41~120 条的大块全部 `bad_response` + httpStatus=0（HTTP 200 后解析失败），
                // 40 条以下 0 次失败。这里用"只对大块装傻"的后端复现：>2 条返回不可解析内容，
                // ≤2 条正常翻译 —— 递归拆块必须一路拆到能成功的粒度。
                let root = try directory(context, "b_parse_split")
                let cache = TranslationCache(url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"), maxEntries: 1000)
                await cache.load()
                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.maxBatch = 80
                settings.maxConcurrent = 4
                settings.batchWindowMs = 0
                settings.batchCharBudget = 4000
                let snapshot = settings
                let provider = BadBatchProvider()
                let pipeline = TranslationPipeline(cache: cache, provider: { provider }, settings: { snapshot })
                let sink = PipelineSink()
                await pipeline.onResult { result in sink.append(result) }

                func item(_ index: Int, _ prefix: String) -> TranslationRequestItem {
                    let text = prefix + "-" + String(index) + "-の台詞です"
                    let segments = [Segment(kind: .text, value: text)]
                    return TranslationRequestItem(key: Segmenter.mapKey(segments), text: text, segments: segments)
                }

                _ = await pipeline.resolve((0..<16).map { item($0, "A") })
                await pipeline.flush()

                let delivered = sink.items
                try expectEqual(Set(delivered.map { $0.key }).count, 16, "16 条必须全部拿到译文（递归拆块）")
                try expect(delivered.allSatisfy { $0.translatedText.hasPrefix("译:") },
                           "拆块后的译文必须是后端返回的，实际：\(delivered.map { $0.translatedText })")
                // 16 失败 → 8×2 失败 → 4×4 失败 → 2×8 成功 = 1+2+4+8 = 15 次请求。
                try expectEqual(provider.itemCounts.sorted(),
                                [2, 2, 2, 2, 2, 2, 2, 2, 4, 4, 4, 4, 8, 8, 16],
                                "拆块请求形状（16→8→4→2）")
                note(context, "拆块请求形状=\(provider.itemCounts) 交付=\(delivered.count)")

                // 自适应上限：这一波成功的最大的子块是 2 条 → 下一波不再先撞 16/80。
                let beforeSecond = provider.itemCounts.count
                _ = await pipeline.resolve((0..<10).map { item($0, "B") })
                await pipeline.flush()
                let secondSizes = Array(provider.itemCounts.dropFirst(beforeSecond))
                try expect(secondSizes.allSatisfy { $0 <= 2 },
                           "下一波必须按 ceiling=2 发（不再按 80 撞一次），实际：\(secondSizes)")
                try expectEqual(secondSizes.sorted(), [2, 2, 2, 2, 2], "10 条 × 2 条一块 = 5 次请求")
                try expectEqual(Set(sink.items.map { $0.key }).count, 26, "第二波 10 条也必须全部拿到译文")
                await cache.flush()
            },
            SelfTestCase(group: "B", name: "pipeline_split_depth_matches_batch") { context in
                // maxBatch 允许 200，拆块深度却写死 4 层：200 → 100 → 50 → 25 → 12/13 就到底，
                // 「>8 条必失败」的后端一条都交不出来（200 条全丢）。深度必须按本波最大块算：
                // ceil(log2(200)) = 8 层，叶子 6/7 条才能成功。
                let root = try directory(context, "b_split_depth")
                let cache = TranslationCache(
                    url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"),
                    maxEntries: 2000
                )
                await cache.load()
                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.maxBatch = 200
                settings.maxConcurrent = 4
                settings.batchWindowMs = 0
                // 不让字数预算先切：这一条测的是**条数**拆块。
                settings.batchCharBudget = 20_000
                let snapshot = settings
                let provider = LeafLimitProvider(limit: 8)
                let pipeline = TranslationPipeline(cache: cache, provider: { provider }, settings: { snapshot })
                let sink = PipelineSink()
                await pipeline.onResult { result in sink.append(result) }

                func item(_ index: Int) -> TranslationRequestItem {
                    let text = "S-" + String(index) + "-の台詞です"
                    let segments = [Segment(kind: .text, value: text)]
                    return TranslationRequestItem(key: Segmenter.mapKey(segments), text: text, segments: segments)
                }

                _ = await pipeline.resolve((0..<200).map { item($0) })
                await pipeline.flush()

                let counts = provider.itemCounts
                try expectEqual(Set(sink.items.map { $0.key }).count, 200,
                                "200 条必须全部交付（深度按本波最大块 200 算），请求形状=\(counts)")
                try expect(sink.items.allSatisfy { $0.translatedText.hasPrefix("译:") },
                           "拆块后的译文必须来自后端，实际前缀=\(Set(sink.items.map { $0.translatedText.hasPrefix("译:") }))")
                try expect(counts.contains { $0 <= 8 },
                           "请求序列里必须出现 ≤8 条的叶子（否则说明没拆到底），实际=\(counts)")
                try expect(counts.allSatisfy { $0 <= 200 }, "单次请求不得超过 maxBatch(200)，实际=\(counts)")
                note(context, "200 条请求数=\(counts.count) 最大=\(counts.max() ?? 0) 最小=\(counts.min() ?? 0) 交付=\(sink.items.count)")
                await cache.flush()
            },
            SelfTestCase(group: "B", name: "pipeline_no_split_on_empty_content") { context in
                // 空内容（finish_reason=length / 推理吃掉 token 预算）与块大小无关：
                // 5 条若按对半拆会发 1+2+4+2 = 9 次请求，失败后端直接变请求风暴。
                let root = try directory(context, "b_empty_content")
                let cache = TranslationCache(
                    url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"),
                    maxEntries: 200
                )
                await cache.load()
                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.batchWindowMs = 0
                let snapshot = settings
                let provider = EmptyContentProvider()
                let pipeline = TranslationPipeline(cache: cache, provider: { provider }, settings: { snapshot })
                let sink = PipelineSink()
                await pipeline.onResult { result in sink.append(result) }

                func item(_ index: Int) -> TranslationRequestItem {
                    let text = "E-" + String(index) + "-の台詞です"
                    let segments = [Segment(kind: .text, value: text)]
                    return TranslationRequestItem(key: Segmenter.mapKey(segments), text: text, segments: segments)
                }

                _ = await pipeline.resolve((0..<5).map { item($0) })
                await pipeline.flush()

                try expectEqual(provider.callCount, 1, "空内容只发 1 次请求（拆块会变成 9 次）")
                try expectEqual(sink.items.count, 0, "空内容不得交付任何译文")
                let message = sink.lastError?.message ?? ""
                try expect(message.hasPrefix(OpenAICompatibleProvider.emptyContentMessagePrefix),
                           "失败原因必须带空内容前缀，实际：\(message)")
                try expect(message.contains("finish_reason=length"),
                           "失败原因必须带 finish_reason，实际：\(message)")
                note(context, "空内容请求数=\(provider.callCount) 交付=\(sink.items.count) 原因=\(message)")
                await cache.flush()
            },
            SelfTestCase(group: "B", name: "skip_rules") { _ in
                try expectEqual(SkipRules.skipReason(for: "350", enabled: true, minLength: 2), "numeric", "纯数字")
                try expectEqual(SkipRules.skipReason(for: "！？", enabled: true, minLength: 2), "punctuation", "纯标点")
                try expectEqual(SkipRules.skipReason(for: "   ", enabled: true, minLength: 2), "whitespace", "纯空白")
                try expectEqual(SkipRules.skipReason(for: "あ", enabled: true, minLength: 2), "tooShort", "过短")
                try expectEqual(SkipRules.skipReason(for: "こんにちは", enabled: false, minLength: 2), "disabled", "已关闭")
                try expect(SkipRules.skipReason(for: "こんにちは", enabled: true, minLength: 2) == nil, "正常文本不应跳过")
                // `numeric` 必须锚定（等价 `^[0-9]+$`）。这三个反例若被判成 numeric，
                // 就是"整句漏译且界面无任何提示"的 P0 级回归（architecture §7.8）。
                try expect(SkipRules.skipReason(for: "10秒後", enabled: true, minLength: 2) == nil, "含数字的句子必须翻译")
                try expect(SkipRules.skipReason(for: "第2章", enabled: true, minLength: 2) == nil, "「第2章」必须翻译")
                try expect(SkipRules.skipReason(for: "350G", enabled: true, minLength: 2) == nil, "「350G」必须翻译")
                // `punctuation` 与 `whitespace` 的边界（架构 §7.7 双端一致）：
                // 先把 5 个折叠码位移除再测 P/S，所以 `"! !"` 与 `"!!"` 同判；
                // 而 `"3 5 0"` 中间有空格 → 不是纯数字 → 必须翻译（与 JS 侧一致）。
                try expectEqual(SkipRules.skipReason(for: "! !", enabled: true, minLength: 2), "punctuation", "「! !」应按标点跳过")
                try expectEqual(SkipRules.skipReason(for: "!!", enabled: true, minLength: 2), "punctuation", "「!!」应按标点跳过")
                try expect(SkipRules.skipReason(for: "3 5 0", enabled: true, minLength: 2) == nil, "「3 5 0」不是纯数字")
                // 单字符被 code 段夹住时，只判 text 段。
                let mixed = [Segment(kind: .code, value: "\\C[2]"), Segment(kind: .text, value: "350")]
                try expectEqual(SkipRules.skipReason(for: Segmenter.mapKey(mixed), enabled: true, minLength: 2), "numeric", "转义码包裹的纯数字仍应跳过")
            },
            // §7.8 的三个独立失败面各一条断言（缺一条即判失败）。
            SelfTestCase(group: "B", name: "skip_before_cache_no_write") { context in
                let root = try directory(context, "b_skip")
                let cacheURL = root.appendingPathComponent("cache.ja-zh-Hans.jsonl")
                let counter = CallCounter()
                let cache = TranslationCache(url: cacheURL, maxEntries: 1000)
                await cache.load()

                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.agentEnabled = true
                let snapshot = settings

                let pipeline = TranslationPipeline(
                    cache: cache,
                    provider: { return CountingProvider(counter: counter) },
                    settings: { return snapshot },
                    log: nil
                )

                func makeItem(_ text: String) -> TranslationRequestItem {
                    let segments = [Segment(kind: .text, value: text)]
                    return TranslationRequestItem(
                        key: Segmenter.cacheKey(
                            engineFamily: K.engineFamily,
                            srcLang: K.fixedSrcLang,
                            tgtLang: K.fixedTgtLang,
                            segments: segments
                        ),
                        text: text,
                        segments: segments
                    )
                }

                let linesBefore = SelfTestRunner.lineCount(of: cacheURL)
                let outcomes = await pipeline.resolve([makeItem("350"), makeItem("???")])
                await pipeline.flush()
                await cache.flush()

                // 失败面 (1) 计费：不发任何后端请求。
                try expectEqual(counter.value, 0, "跳过项不得触发后端请求")
                // 失败面 (3) 假译文：status 必须是 .skipped（不得 .hit / .translated）。
                try expectEqual(outcomes.count, 2, "outcomes 数量")
                for (index, outcome) in outcomes.enumerated() {
                    guard case .skipped(let reason) = outcome else {
                        throw SelfTestFailure(message: "第 \(index + 1) 条应为 skipped，实际 \(outcome)")
                    }
                    try expect(!reason.isEmpty, "skip 必须带 reason")
                }
                // 失败面 (2) 脏数据：cache.jsonl 条数不变。
                let linesAfter = SelfTestRunner.lineCount(of: cacheURL)
                try expectEqual(linesAfter, linesBefore, "跳过项不得写入 cache.jsonl")
                let stats = await cache.stats()
                try expectEqual(stats.entries, 0, "跳过项不得产生缓存条目")
            },
            SelfTestCase(group: "B", name: "repair_ignore_cache_and_emphasis") { context in
                // 术语违例重译的两个前提（名称一致性）：
                //  · ignoreCache：坏译文本身就在缓存里，不跳过查询就永远修不掉；
                //    修好的结果仍要按**原 key** 覆盖写回。
                //  · emphasis 必须升到 request 级：systemPrompt 是 request 级，
                //    只挂在 item 上 provider 根本看不到。
                let root = try directory(context, "b_repair")
                let cache = TranslationCache(url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"), maxEntries: 100)
                await cache.load()

                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.batchWindowMs = 0
                let snapshot = settings

                let recorder = EmphasisRecorder()
                let pipeline = TranslationPipeline(
                    cache: cache,
                    provider: { return RepairProvider(recorder: recorder) },
                    settings: { return snapshot },
                    log: nil
                )

                let raw = "噛みつきクラゲが現れた"
                let segments = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
                let key = Segmenter.cacheKey(
                    engineFamily: K.engineFamily,
                    srcLang: K.fixedSrcLang,
                    tgtLang: K.fixedTgtLang,
                    segments: segments
                )
                // 上一版坏译文（名字被模型改成了「刺人水母」）已经躺在缓存里。
                await cache.put(key: key, text: raw, translatedText: "刺人水母出现了", backend: "openai")

                // ① 正常请求：命中缓存、零请求（前置事实，不是被测行为）。
                let plain = TranslationRequestItem(key: key, text: raw, segments: segments)
                let hits = await pipeline.resolve([plain])
                var hitCached = false
                if let first = hits.first, case .hit(let result) = first { hitCached = result.cached }
                try expect(hitCached, "前置：正常请求应命中缓存")
                try expectEqual(recorder.calls, 0, "命中缓存时不得发请求")

                // ② 修复请求：同一 key + ignoreCache → 仍要发请求，结果覆盖原 key。
                let pair = GlossaryPair(source: "噛みつきクラゲ", target: "咬人水母")
                var repair = plain
                repair.ignoreCache = true
                repair.emphasis = [pair]
                let outcomes = await pipeline.resolve([repair])
                guard let outcome = outcomes.first, case .pending = outcome else {
                    throw SelfTestFailure(message: "ignoreCache 必须重新入队，实际 \(String(describing: outcomes.first))")
                }
                await pipeline.flush()

                try expectEqual(recorder.calls, 1, "ignoreCache 时同一 key 仍要发请求")
                try expectEqual(recorder.emphasis.count, 1, "强调术语应升到 request 级")
                try expectEqual(recorder.emphasis.first?.source ?? "-", "噛みつきクラゲ", "强调术语的源名")
                try expectEqual(recorder.emphasis.first?.target ?? "-", "咬人水母", "强调术语的译名")
                let updated = await cache.get(key)
                try expectEqual(updated?.translatedText ?? "-", "咬人水母出现了", "好结果必须覆盖原 key 上的坏译文")
            },
            SelfTestCase(group: "B", name: "circuit_open_pauses_queue") { context in
                // 真机事故：熔断分支把队列里的条目出队后回填"译文 = 原文"，
                // 13 秒内把 7687 条全部"处理"完，调用方当成成功译文写进语料。
                // 新语义：熔断期不消费队列、零请求、结果 items 为空；
                // 冷却结束后积压必须原样继续翻译。
                let root = try directory(context, "b_circuit")
                let cache = TranslationCache(url: root.appendingPathComponent("cache.ja-zh-Hans.jsonl"), maxEntries: 100)
                await cache.load()

                var settings = Settings()
                settings.backendType = .openai
                settings.endpoint = "http://127.0.0.1:1"
                settings.batchWindowMs = 0
                settings.maxBatch = 10
                settings.maxConcurrent = 2
                let snapshot = settings

                let provider = FlakyProvider(failWith: MochiBoxError(code: .authFailed))
                var policy = ResiliencePolicy()
                policy.retryDelaysMs = []
                // 真实窗口 30s；这里压到 1.5s，让"冷却后继续翻译"可测。
                policy.breakerOpenSec = 1.5
                let pipeline = TranslationPipeline(
                    cache: cache,
                    provider: { provider },
                    settings: { snapshot },
                    policy: policy
                )
                let sink = PipelineSink()
                await pipeline.onResult { result in sink.append(result) }

                func item(_ index: Int, _ text: String) -> TranslationRequestItem {
                    let segments = [Segment(kind: .text, value: text)]
                    return TranslationRequestItem(key: Segmenter.mapKey(segments), text: text, segments: segments)
                }

                for index in 0..<K.circuitBreakerThreshold {
                    _ = await pipeline.resolve([item(index, "失敗\(index)の台詞です")])
                    await pipeline.flush()
                }
                var isOpen = false
                if case .circuitOpen = await pipeline.backendStatus() { isOpen = true }
                try expect(isOpen, "连续 \(K.circuitBreakerThreshold) 个失败批次后应熔断")

                let callsBefore = provider.callCount
                let blocked = (0..<3).map { item(100 + $0, "熔断中の台詞\($0)です") }
                _ = await pipeline.resolve(blocked)
                let noticeDeadline = Date().addingTimeInterval(2)
                while sink.circuitNotifications.isEmpty && Date() < noticeDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                guard let notice = sink.circuitNotifications.first else {
                    throw SelfTestFailure(message: "熔断期未收到 circuit_open 通知")
                }
                try expectEqual(notice.items.count, 0, "熔断期结果必须为空（不得把原文当译文）")
                try expectEqual(notice.error?.code, .circuitOpen, "熔断期错误码")
                try expectEqual(notice.error?.retryable, false, "circuit_open 不得提示立即重试")
                try expect(notice.backend == .passthrough, "熔断播报的 backend 标记")
                try expectEqual(provider.callCount, callsBefore, "熔断期零后端请求")

                // 冷却后队列原样继续：3 条全部拿到真译文，且只发 1 次请求。
                provider.setFailure(nil)
                let deliveryDeadline = Date().addingTimeInterval(6)
                while sink.items.count < 3 && Date() < deliveryDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                try expectEqual(sink.items.count, 3, "冷却后队列必须原样继续翻译")
                try expectEqual(provider.callCount, callsBefore + 1, "冷却后一波只发 1 次请求")
                try expect(sink.items.allSatisfy { $0.translatedText.hasPrefix("译:") },
                           "冷却后交付的必须是真译文")
                await cache.flush()
            },
            SelfTestCase(group: "B", name: "fulltext_rejects_degraded_result") { _ in
                // FullTextController 的守卫条件（纯函数）：passthrough / circuit_open
                // 两种批次都不可信。旧实现在这里继续 for 循环，把 translatedText
                // （= 原文）通过 applyTranslated 写进语料。
                let segments = Segmenter.splitSegments(raw: "こんにちは", engineFamily: K.engineFamily)
                let fakeItem = TranslationResultItem(
                    key: Segmenter.mapKey(segments),
                    translatedText: "こんにちは",
                    translatedSegments: segments,
                    cached: false,
                    latencyMs: 0
                )
                let degraded = PipelineBatchResult(
                    requestId: "degraded",
                    items: [fakeItem],
                    backend: .passthrough,
                    error: ErrorInfo(code: .circuitOpen)
                )
                try expect(FullTextController.isUntranslatedResult(degraded), "passthrough 批次必须整批拒绝")

                let circuitOnly = PipelineBatchResult(
                    requestId: "circuit",
                    items: [],
                    backend: .openai,
                    error: ErrorInfo(code: .circuitOpen)
                )
                try expect(FullTextController.isUntranslatedResult(circuitOnly), "circuit_open 批次必须整批拒绝")

                let normal = PipelineBatchResult(
                    requestId: "normal",
                    items: [fakeItem],
                    backend: .openai,
                    error: nil
                )
                try expect(!FullTextController.isUntranslatedResult(normal), "正常批次不得被误拒")

                // 即便旧文件里已经落了假译文，清洗后也不得再有 translated == raw 的机翻条目。
                var corpus = FullTextCorpus()
                corpus.mergePersisted(
                    entries: ["こんにちは": "こんにちは"],
                    segments: nil,
                    origins: ["こんにちは": "machine"]
                )
                try expectEqual(corpus.translatedCount, 1, "前置：假译文确实在语料里")
                _ = corpus.purgePassthroughMachineTranslations()
                let leftovers = corpus.all.filter { entry in
                    entry.origin != .manual
                        && entry.isTranslated
                        && Segmenter.normalizeForKey(entry.translated ?? "") == Segmenter.normalizeForKey(entry.raw)
                }
                try expectEqual(leftovers.count, 0, "清理后不得再有 translated == raw 的机翻条目")
            }
        ]
    }

    /// 统计文件行数（用于"跳过后 cache.jsonl 条数不变"的断言）。
    static func lineCount(of url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return 0 }
        var count = data.reduce(0) { partial, byte in byte == 0x0A ? partial + 1 : partial }
        if data.last != 0x0A { count += 1 }
        return count
    }
}

/// 计数桩：验证"同句第二次不调用后端"。
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

struct CountingProvider: TranslatorProvider {
    let counter: CallCounter
    var kind: BackendKind { return .openai }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        counter.increment()
        return batch.map { request in
            let items = request.items.map { item in
                TranslationResultItem(
                    key: item.key,
                    translatedText: "译:" + item.text,
                    translatedSegments: nil,
                    cached: false,
                    latencyMs: 1
                )
            }
            return TranslationResult(requestId: request.requestId, items: items, backend: .openai, error: nil)
        }
    }
}

/// 记录 **request 级** emphasis 的桩：provider 只拿得到 request，拿不到 item ——
/// 强调术语若留在 item 上，这里读到的就是空数组。
final class EmphasisRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GlossaryPair] = []
    private var callCount = 0

    func record(_ request: TranslationRequest) {
        lock.lock()
        callCount += 1
        stored = request.emphasis ?? []
        lock.unlock()
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var emphasis: [GlossaryPair] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// 修复请求的桩：返回遵守了术语的译文（覆盖缓存里的坏译文）。
struct RepairProvider: TranslatorProvider {
    let recorder: EmphasisRecorder
    var kind: BackendKind { return .openai }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        return batch.map { request in
            recorder.record(request)
            let items = request.items.map { item in
                TranslationResultItem(
                    key: item.key,
                    translatedText: "咬人水母出现了",
                    translatedSegments: nil,
                    cached: false,
                    latencyMs: 1
                )
            }
            return TranslationResult(requestId: request.requestId, items: items, backend: .openai, error: nil)
        }
    }
}

/// 只对大块"装傻"的后端：>2 条返回不可解析内容（复现真机 41+ 条整块失败），
/// ≤2 条正常翻译。用来证明"解析失败 → 递归对半拆块"能救回全部条目。
final class BadBatchProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var recorded: [Int] = []

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        guard let request = batch.first else { return [] }
        lock.lock()
        recorded.append(request.items.count)
        lock.unlock()
        guard request.items.count <= 2 else {
            throw MochiBoxError(
                code: .badResponse,
                message: "content 不是 JSON 数组；前 160 字：好的，以下是译文：[\"译\"]…"
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

    var itemCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// 只在小块成功的后端：超过 limit 条一律 badResponse，不超过则正常翻译。
///
/// 用来证明拆块深度**跟着块大小走**：maxBatch=200 时写死 4 层只能拆到 12/13 条，
/// limit = 8 的后端一条都交不出来；按 ceil(log2(200)) = 8 层才能拆到 6/7 条。
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
        lock.lock()
        recorded.append(request.items.count)
        lock.unlock()
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

    var itemCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// 恒定返回「空内容」的后端（复现 finish_reason=length / 推理吃掉 token 预算）。
///
/// 空内容与块大小无关：拆块只会把 1 次失败放大成 2 的 depth 次方次请求。
final class EmptyContentProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var recorded = 0

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        lock.lock()
        recorded += 1
        lock.unlock()
        throw MochiBoxError(
            code: .badResponse,
            message: OpenAICompatibleProvider.emptyContentMessagePrefix
                + "（finish_reason=length）：输出被截断，可在设置→高级设置调大最大输出 tokens"
        )
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// 收集管线回调（`onResult` 的 handler 是 @Sendable 同步闭包，不能直接写外部 var）。
/// 可切换失败 / 成功的后端桩：先喂满熔断，再验证"冷却后队列仍能翻译"。
final class FlakyProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var failWith: MochiBoxError?
    private var recorded = 0

    init(failWith: MochiBoxError? = nil) {
        self.failWith = failWith
    }

    func setFailure(_ error: MochiBoxError?) {
        lock.lock()
        failWith = error
        lock.unlock()
    }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        lock.lock()
        recorded += 1
        let error = failWith
        lock.unlock()
        if let error = error { throw error }
        return batch.map { request in
            let items = request.items.map { item in
                TranslationResultItem(
                    key: item.key,
                    translatedText: "译:" + item.text,
                    translatedSegments: nil,
                    cached: false,
                    latencyMs: 1
                )
            }
            return TranslationResult(requestId: request.requestId, items: items, backend: kind, error: nil)
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// 段数漂移桩：首次请求返回 `原文段数 + 1` 段非空译文（模拟模型把一句拆成两句），
/// 单条重发时返回正确段数。`alwaysDrift = true` 用来验证"重试仍失败只落单条错误"。
final class SegmentDriftProvider: TranslatorProvider, @unchecked Sendable {
    let kind: BackendKind = .openai
    private let lock = NSLock()
    private var calls = 0
    private let alwaysDrift: Bool

    init(alwaysDrift: Bool = false) { self.alwaysDrift = alwaysDrift }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        lock.lock()
        calls += 1
        let isFirst = calls == 1
        lock.unlock()
        return batch.map { request in
            let items = request.items.map { item -> TranslationResultItem in
                let expected = max(1, Segmenter.textSegmentCount(item.segments))
                let drift = alwaysDrift || isFirst
                let count = drift ? expected + 1 : expected
                let text = (0..<count).map { "译\($0)" }.joined(separator: K.unitSeparatorString)
                return TranslationResultItem(
                    key: item.key,
                    translatedText: text,
                    translatedSegments: nil,
                    cached: false,
                    latencyMs: 1
                )
            }
            return TranslationResult(requestId: request.requestId, items: items, backend: kind, error: nil)
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class PipelineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineBatchResult] = []

    func append(_ result: PipelineBatchResult) {
        lock.lock()
        storage.append(result)
        lock.unlock()
    }

    var items: [TranslationResultItem] {
        lock.lock()
        defer { lock.unlock() }
        return storage.flatMap { $0.items }
    }

    /// 熔断窗口的播报（items 必须为空）。
    var circuitNotifications: [PipelineBatchResult] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.error?.code == .circuitOpen }
    }

    /// 所有**单条**错误的并集（段数校验失败场景用）。
    var itemErrors: [String: ErrorInfo] {
        lock.lock()
        defer { lock.unlock() }
        var output: [String: ErrorInfo] = [:]
        for result in storage { output.merge(result.itemErrors) { first, _ in first } }
        return output
    }

    /// 最后一条结果的 error（空内容场景要据此断言原因文案）。
    var lastError: ErrorInfo? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last?.error
    }
}

// MARK: - C 组：HTTP 后端

/// 极简 mock HTTP 服务（`NWListener`，仅 selftest 使用）。
final class MockHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mochibox.selftest.mock")
    /// (path, 原始请求文本（含头与 body）) → 响应。body 用于断言 max_tokens 之类只在请求体里的字段。
    private let handler: @Sendable (String, String) -> (status: Int, body: String)
    private(set) var port: Int = 0

    init(handler: @escaping @Sendable (String, String) -> (status: Int, body: String)) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: .any)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failureText: String?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = Int(self?.listener.port?.rawValue ?? 0)
                semaphore.signal()
            case .failed(let error):
                failureText = "\(error)"
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)
        if let failureText = failureText {
            throw SelfTestFailure(message: "mock server 启动失败：\(failureText)")
        }
        if port == 0 {
            throw SelfTestFailure(message: "mock server 未取得端口")
        }
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: String {
        return "http://127.0.0.1:\(port)"
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    /// 收到完整请求（头 + Content-Length 指定的 body）再回包。
    ///
    /// 不能假设一次 receive 就拿到全部：body 与 header 分两段到达时，只解析第一段会看到空 body。
    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var accumulated = buffer
            if let data = data { accumulated.append(data) }
            let text = String(decoding: accumulated, as: UTF8.self)
            if !isComplete && error == nil && !MockHTTPServer.hasFullBody(text) {
                self.receive(connection: connection, buffer: accumulated)
                return
            }
            let path = MockHTTPServer.path(of: text)
            let response = self.handler(path, text)
            let header = "HTTP/1.1 \(response.status) \(MockHTTPServer.reason(response.status))\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(response.body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
            let payload = Data((header + response.body).utf8)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// 请求是否已含完整 body（无 Content-Length 视为无 body）。
    static func hasFullBody(_ request: String) -> Bool {
        guard let separator = request.range(of: "\r\n\r\n") else { return false }
        var length = 0
        for line in request[..<separator.lowerBound].components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("content-length:") else { continue }
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return request[separator.upperBound...].utf8.count >= length
    }

    static func path(of request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return "/" }
        let parts = first.components(separatedBy: " ")
        return parts.count >= 2 ? parts[1] : "/"
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 456: return "Quota Exceeded"
        default: return "Status"
        }
    }
}

extension SelfTestRunner {
    /// C 组共用：单条 1 行请求（关闭推理的用例只关心请求体里的字段）。
    static func httpSimpleRequest() -> TranslationRequest {
        let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
        return TranslationRequest(
            items: items,
            srcLang: "ja",
            tgtLang: "zh-Hans",
            backend: .openai,
            timeoutMs: 5000,
            requestId: UUID().uuidString
        )
    }

    static var httpCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "C", name: "openai_success_shape") { _ in
                let server = try MockHTTPServer { _, _ in
                    let content = "[\"你好\"]"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    let body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}"
                    return (200, body)
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                let results = try await provider.translate([request])
                try expectEqual(results.count, 1, "结果批数")
                try expectEqual(results[0].items.first?.translatedText, "你好", "译文")
                try expectEqual(results[0].backend, .openai, "backend")
            },
            SelfTestCase(group: "C", name: "deepl_success_shape") { _ in
                let server = try MockHTTPServer { _, _ in
                    return (200, "{\"translations\":[{\"detected_source_language\":\"JA\",\"text\":\"你好\"}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = DeepLProvider(endpoint: server.baseURL, apiKey: "deepl-test")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .deepl, timeoutMs: 5000, requestId: UUID().uuidString)
                let results = try await provider.translate([request])
                try expectEqual(results[0].items.first?.translatedText, "你好", "DeepL 译文")
            },
            SelfTestCase(group: "C", name: "auth_failed_401") { _ in
                let server = try MockHTTPServer { _, _ in
                    return (401, "{\"error\":{\"message\":\"invalid api key\"}}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "bad", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "テスト", segments: [Segment(kind: .text, value: "テスト")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                do {
                    _ = try await provider.translate([request])
                    throw SelfTestFailure(message: "401 必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .authFailed, "错误码")
                    try expectEqual(error.httpStatus, 401, "httpStatus")
                    try expectEqual(error.retryable, false, "401 不可重试")
                    try expect(error.rawSnippet?.contains("invalid") == true, "应保留响应片段")
                }
            },
            SelfTestCase(group: "C", name: "rate_limited_429_and_non_json") { _ in
                let limited = try MockHTTPServer { _, _ in
                    return (429, "{\"error\":\"slow down\"}")
                }
                try limited.start()
                defer { limited.stop() }

                let provider = OpenAICompatibleProvider(endpoint: limited.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "テスト", segments: [Segment(kind: .text, value: "テスト")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                do {
                    _ = try await provider.translate([request])
                    throw SelfTestFailure(message: "429 必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .rateLimited, "错误码")
                    try expectEqual(error.retryable, true, "429 应可重试")
                }

                let broken = try MockHTTPServer { _, _ in
                    return (200, "this is not json")
                }
                try broken.start()
                defer { broken.stop() }
                let provider2 = OpenAICompatibleProvider(endpoint: broken.baseURL, apiKey: "sk-test", model: "m")
                do {
                    _ = try await provider2.translate([request])
                    throw SelfTestFailure(message: "非 JSON 必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .badResponse, "错误码")
                    try expectEqual(error.retryable, false, "非 JSON 不应重试")
                }
            },
            SelfTestCase(group: "C", name: "openai_max_tokens") { _ in
                // 请求体里必须有 max_tokens：不给时很多兼容后端按 256/512 截断，
                // 60 条一批会被砍成半句。0（默认）→ 按输入字数自动估算，下限 1024。
                let capture = RequestCapture()
                let server = try MockHTTPServer { _, request in
                    capture.set(request)
                    let content = "[\"你好\"]"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                _ = try await provider.translate([request])
                // 5 字 × 2 = 10 → 夹到下限 512（原下限 1024：deepseek 这类模型输出上限 4096，
                // 自动值给太大反而会被 reasoning 吃掉预算，content 变空/半截）。
                try expect(capture.text.contains("\"max_tokens\":512"),
                           "请求体应含 max_tokens=512（5 字 × 2 → 低于下限），实际：\(capture.text.prefix(400))")

                // 用户配置 > 0 时优先用它。
                let configured = RequestCapture()
                let configuredServer = try MockHTTPServer { _, request in
                    configured.set(request)
                    let content = "[\"你好\"]"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try configuredServer.start()
                defer { configuredServer.stop() }
                let configuredProvider = OpenAICompatibleProvider(
                    endpoint: configuredServer.baseURL,
                    apiKey: "sk-test",
                    model: "m",
                    maxOutputTokens: 2048
                )
                _ = try await configuredProvider.translate([request])
                try expect(configured.text.contains("\"max_tokens\":2048"),
                           "用户配置的 max_tokens 应优先，实际：\(configured.text.prefix(400))")

                // 自动值的上限是 4096（不是 8192）：3000 字 × 2 = 6000 也必须被夹住。
                let capped = RequestCapture()
                let cappedServer = try MockHTTPServer { _, request in
                    capped.set(request)
                    let content = "[\"你好\"]"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try cappedServer.start()
                defer { cappedServer.stop() }
                let cappedProvider = OpenAICompatibleProvider(endpoint: cappedServer.baseURL, apiKey: "sk-test", model: "m")
                let longText = String(repeating: "あ", count: 3000)
                let longItem = TranslationRequestItem(key: "k-long", text: longText, segments: [Segment(kind: .text, value: longText)])
                let longRequest = TranslationRequest(items: [longItem], srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                _ = try await cappedProvider.translate([longRequest])
                try expect(capped.text.contains("\"max_tokens\":4096"),
                           "自动 max_tokens 上限应为 4096，实际：\(capped.text.prefix(400))")
            },
            SelfTestCase(group: "C", name: "openai_items_wrapper") { _ in
                // 宽容解析：模型偶尔把数组包进 {"items": [...]}，元素仍是字符串。
                let server = try MockHTTPServer { _, _ in
                    let content = "{\"items\":[\"你好\"]}"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                let results = try await provider.translate([request])
                try expectEqual(results[0].items.first?.translatedText, "你好", "items 包裹的译文")
            },
            SelfTestCase(group: "C", name: "openai_explained_array") { _ in
                // 模型在数组前后加解释（真机上大块请求最常见的"不是数组"形态）：
                // 取第一个 `[` 到最后一个 `]` 之间的子串再解析。
                let server = try MockHTTPServer { _, _ in
                    let content = "好的，以下是译文：\n[\"你好\"]\n如需调整请告诉我。"
                    let escaped = content
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                let results = try await provider.translate([request])
                try expectEqual(results[0].items.first?.translatedText, "你好", "前后带解释的数组")
            },
            SelfTestCase(group: "C", name: "openai_translations_wrapper") { _ in
                // 与 items 同一类宽容：`{"translations": [...]}`。
                let server = try MockHTTPServer { _, _ in
                    let content = "{\"translations\":[\"你好\"]}"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                let results = try await provider.translate([request])
                try expectEqual(results[0].items.first?.translatedText, "你好", "translations 包裹的译文")
            },
            SelfTestCase(group: "C", name: "openai_truncated_diagnostic") { _ in
                // 被 max_tokens 截断：必须抛错，且 message / rawSnippet 里带可读片段 ——
                // 只写"content 不是 JSON 数组"时，真机日志里连是截断还是拒答都分不出来。
                let server = try MockHTTPServer { _, _ in
                    let content = "[\"你好\", \"这是第二段被截断的"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [
                    TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")]),
                    TranslationRequestItem(key: "k2", text: "さようなら", segments: [Segment(kind: .text, value: "さようなら")])
                ]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                do {
                    _ = try await provider.translate([request])
                    throw SelfTestFailure(message: "截断的 JSON 必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .badResponse, "错误码")
                    try expect(error.message.contains("这是第二段被截断的"),
                               "message 必须带可读片段，实际：\(error.message)")
                    try expect(error.rawSnippet?.contains("你好") == true,
                               "rawSnippet 必须保留原文片段，实际：\(error.rawSnippet ?? "nil")")
                }
            },
            SelfTestCase(group: "C", name: "openai_empty_content_length") { _ in
                // 真机现场：deepseek-flash 把 max_tokens 先花在思维链上，content 是空串、
                // finish_reason 却是 length。此时 snippet 也是空的，只有错误文案能告诉用户
                // 该调"最大输出 tokens"还是该减批量。
                let server = try MockHTTPServer { _, _ in
                    return (200, "{\"choices\":[{\"index\":0,\"finish_reason\":\"length\",\"message\":{\"role\":\"assistant\",\"content\":\"\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                do {
                    _ = try await provider.translate([request])
                    throw SelfTestFailure(message: "空 content 必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .badResponse, "错误码")
                    try expect(error.message.contains("length"),
                               "message 必须带 finish_reason=length，实际：\(error.message)")
                    try expect(error.message.contains("最大输出"),
                               "message 必须提示调大最大输出 tokens，实际：\(error.message)")
                }
            },
            SelfTestCase(group: "C", name: "openai_not_array_stop") { _ in
                // 非截断的非数组（拒答 / 换了形状）：finish_reason=stop 也要进 message，
                // 否则用户会照着"截断"去调 tokens，白花一次配额。
                let server = try MockHTTPServer { _, _ in
                    return (200, "{\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"不是 JSON\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let items = [TranslationRequestItem(key: "k1", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])]
                let request = TranslationRequest(items: items, srcLang: "ja", tgtLang: "zh-Hans", backend: .openai, timeoutMs: 5000, requestId: UUID().uuidString)
                do {
                    _ = try await provider.translate([request])
                    throw SelfTestFailure(message: "非 JSON 必须抛错")
                } catch let error as MochiBoxError {
                    try expectEqual(error.code, .badResponse, "错误码")
                    try expect(error.message.contains("stop"),
                               "message 必须带 finish_reason=stop，实际：\(error.message)")
                }
            },
            SelfTestCase(group: "C", name: "openai_emphasis_prompt") { _ in
                // 强调段是 request 级的（provider 只渲染一次 system message）：
                // 必须落在术语表之后、最后的输出约束之前；无 emphasis 的正常请求逐字节不变
                // —— 所以不用升 TranslationPrompt.version，旧缓存继续有效。
                let capture = RequestCapture()
                let server = try MockHTTPServer { _, request in
                    capture.set(request)
                    let content = "[\"咬人水母出现了\"]"
                    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                let segments = [Segment(kind: .text, value: "噛みつきクラゲが現れた")]
                let term = GlossaryPair(source: "レベル", target: "等级")
                let item = TranslationRequestItem(
                    key: "k1",
                    text: "噛みつきクラゲが現れた",
                    segments: segments,
                    glossary: [term]
                )
                let normal = TranslationRequest(
                    items: [item], srcLang: "ja", tgtLang: "zh-Hans", backend: .openai,
                    timeoutMs: 5000, requestId: UUID().uuidString, glossary: [term]
                )
                _ = try await provider.translate([normal])
                try expect(!capture.text.contains("上一版译文未遵守"), "正常请求不得含强调段")

                let repair = TranslationRequest(
                    items: [item], srcLang: "ja", tgtLang: "zh-Hans", backend: .openai,
                    timeoutMs: 5000, requestId: UUID().uuidString, glossary: [term],
                    emphasis: [GlossaryPair(source: "噛みつきクラゲ", target: "咬人水母")]
                )
                _ = try await provider.translate([repair])

                let body = capture.text
                let header = "上一版译文未遵守下列译名，必须逐字使用，不得改写或使用同义译名："
                try expect(body.contains(header), "强调段表头必须进 system message")
                try expect(body.contains("噛みつきクラゲ => 咬人水母"), "强调段要逐条列出 A => B")
                guard let emphasisAt = body.range(of: header),
                      let glossaryAt = body.range(of: "术语表（必须严格使用"),
                      let tailAt = body.range(of: "只输出 JSON 字符串数组") else {
                    throw SelfTestFailure(message: "强调段位置无法判定：\(body.prefix(600))")
                }
                try expect(glossaryAt.upperBound <= emphasisAt.lowerBound, "强调段必须在术语表之后")
                try expect(emphasisAt.upperBound <= tailAt.lowerBound, "强调段必须在最后的输出约束之前")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_auto") { _ in
                // auto 只对 DeepSeek 端点生效。mock 服务器只能监听 127.0.0.1，无法冒充 deepseek host，
                // 所以 host 判定直接断言 provider 构造出来的字段；落进请求体的路径由下面几条覆盖。
                let deepseek = OpenAICompatibleProvider(
                    endpoint: "https://api.deepseek.com",
                    apiKey: "sk-test",
                    model: "deepseek-flash",
                    reasoningOffMode: .auto
                )
                guard let field = deepseek.reasoningOffField() else {
                    throw SelfTestFailure(message: "auto + DeepSeek 端点必须注入关闭推理字段")
                }
                let encoded = try JSONSerialization.data(withJSONObject: field, options: [.sortedKeys])
                try expectEqual(String(decoding: encoded, as: UTF8.self),
                                 "{\"thinking\":{\"type\":\"disabled\"}}",
                                 "auto 在 DeepSeek 上应发 thinking.type=disabled")

                let other = OpenAICompatibleProvider(
                    endpoint: "https://api.openai.com",
                    apiKey: "sk-test",
                    model: "gpt-5",
                    reasoningOffMode: .auto
                )
                try expect(other.reasoningOffField() == nil, "auto 不得向非 DeepSeek 端点发送字段")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_auto_non_deepseek_body") { _ in
                // 非 DeepSeek + auto：请求体里两种字段都必须缺席（未知字段会被第三方端点判 400）。
                let capture = RequestCapture()
                let server = try MockHTTPServer { _, request in
                    capture.set(request)
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[\\\"你好\\\"]\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(endpoint: server.baseURL, apiKey: "sk-test", model: "m")
                _ = try await provider.translate([SelfTestRunner.httpSimpleRequest()])
                let body = capture.text
                try expect(!body.contains("\"thinking\""), "auto + 非 DeepSeek 不得发 thinking，实际：\(body.prefix(400))")
                try expect(!body.contains("reasoning_effort"), "auto + 非 DeepSeek 不得发 reasoning_effort")
                try expect(body.contains("\"temperature\":0"), "temperature 必须保持 0")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_thinking_disabled_body") { _ in
                let capture = RequestCapture()
                let server = try MockHTTPServer { _, request in
                    capture.set(request)
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[\\\"你好\\\"]\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(
                    endpoint: server.baseURL,
                    apiKey: "sk-test",
                    model: "m",
                    reasoningOffMode: .thinkingDisabled
                )
                _ = try await provider.translate([SelfTestRunner.httpSimpleRequest()])
                let body = capture.text
                try expect(body.contains("\"thinking\":{\"type\":\"disabled\"}"),
                           "请求体应含 thinking.type=disabled，实际：\(body.prefix(400))")
                try expect(!body.contains("reasoning_effort"), "一次只发一个字段：不得同时发 reasoning_effort")
                try expect(body.contains("\"temperature\":0"), "temperature 必须保持 0")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_effort_none_body") { _ in
                let capture = RequestCapture()
                let server = try MockHTTPServer { _, request in
                    capture.set(request)
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[\\\"你好\\\"]\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(
                    endpoint: server.baseURL,
                    apiKey: "sk-test",
                    model: "m",
                    reasoningOffMode: .reasoningEffortNone
                )
                _ = try await provider.translate([SelfTestRunner.httpSimpleRequest()])
                let body = capture.text
                try expect(body.contains("\"reasoning_effort\":\"none\""),
                           "请求体应含 reasoning_effort=none，实际：\(body.prefix(400))")
                try expect(!body.contains("\"thinking\""), "一次只发一个字段：不得同时发 thinking")
                try expect(body.contains("\"temperature\":0"), "temperature 必须保持 0")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_never_body") { _ in
                let capture = RequestCapture()
                let server = try MockHTTPServer { _, request in
                    capture.set(request)
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[\\\"你好\\\"]\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(
                    endpoint: server.baseURL,
                    apiKey: "sk-test",
                    model: "m",
                    reasoningOffMode: .never
                )
                _ = try await provider.translate([SelfTestRunner.httpSimpleRequest()])
                let body = capture.text
                try expect(!body.contains("\"thinking\""), "never 不得发 thinking")
                try expect(!body.contains("reasoning_effort"), "never 不得发 reasoning_effort")
                try expect(body.contains("\"temperature\":0"), "temperature 必须保持 0")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_400_retry") { _ in
                // 第三方兼容端点不认识 thinking 字段时会回 400。此时必须**去掉该字段重发一次**：
                // 一个可选开关不该让整批翻译彻底失败。
                let capture = RequestCapture()
                let tally = RequestTally()
                let server = try MockHTTPServer { _, request in
                    let attempt = tally.increment()
                    capture.set(request)
                    if attempt == 1 {
                        return (400, "{\"error\":\"unknown field: thinking\"}")
                    }
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[\\\"你好\\\"]\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(
                    endpoint: server.baseURL,
                    apiKey: "sk-test",
                    model: "m",
                    reasoningOffMode: .thinkingDisabled
                )
                let results = try await provider.translate([SelfTestRunner.httpSimpleRequest()])
                try expectEqual(results[0].items.first?.translatedText, "你好", "去掉字段后应成功")
                try expectEqual(tally.value, 2, "400 后应只重发一次")
                let body = capture.text
                try expect(!body.contains("\"thinking\""), "重发请求不得再带 thinking，实际：\(body.prefix(400))")
                try expect(body.contains("\"model\""), "重发请求仍是同一请求（保留 model）")
            },
            SelfTestCase(group: "C", name: "openai_reasoning_off_422_retry") { _ in
                // 422 同样视为"字段不被接受"：与 400 走同一条去字段重发路径。
                let capture = RequestCapture()
                let tally = RequestTally()
                let server = try MockHTTPServer { _, request in
                    let attempt = tally.increment()
                    capture.set(request)
                    if attempt == 1 {
                        return (422, "{\"error\":\"reasoning_effort is not supported\"}")
                    }
                    return (200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"[\\\"你好\\\"]\"}}]}")
                }
                try server.start()
                defer { server.stop() }

                let provider = OpenAICompatibleProvider(
                    endpoint: server.baseURL,
                    apiKey: "sk-test",
                    model: "m",
                    reasoningOffMode: .reasoningEffortNone
                )
                let results = try await provider.translate([SelfTestRunner.httpSimpleRequest()])
                try expectEqual(results[0].items.first?.translatedText, "你好", "422 后去掉字段应成功")
                try expectEqual(tally.value, 2, "422 后应只重发一次")
                try expect(!capture.text.contains("reasoning_effort"),
                           "重发请求不得再带 reasoning_effort，实际：\(capture.text.prefix(400))")
            }
        ]
    }
}

/// 线程安全的请求计数（400/422 重试要断言"恰好重发一次"）。
final class RequestTally: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    /// 记一次请求并返回它是第几次（从 1 开始）。
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 线程安全的请求文本捕获（mock 的 handler 是 @Sendable 闭包，不能直接写外部 var）。
final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func set(_ text: String) {
        lock.lock()
        value = text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - D 组：Agent 脚本（JavaScriptCore）

extension SelfTestRunner {
    static let agentStubJS = """
    var window = this;
    var __captured = [];
    var __lastDraw = null;
    function Bitmap() { this.contents = { fontSize: 24 }; this.fontSize = 24; this.fontFace = 'GameFont'; }
    // 与 MV 真源同型：Agent 重写它来注入中文字体链（自检据此断言）。
    Bitmap.prototype._makeFontNameText = function () {
      return (this.fontItalic ? 'italic ' : '') + this.fontSize + 'px ' + this.fontFace;
    };
    Bitmap.prototype.drawText = function (text, x, y, maxWidth, lineHeight, align) {
      __captured.push(String(text));
      return true;
    };
    function Window_Base() { this.contents = new Bitmap(); }
    Window_Base.prototype.drawText = function (text, x, y, maxWidth, align) {
      __captured.push(String(text));
      return this.contents.drawText(text, x, y, maxWidth, 24, align);
    };
    Window_Base.prototype.drawTextEx = function (text, x, y) {
      __lastDraw = String(text);
      __captured.push(String(text));
      return true;
    };
    function Window_Message() { Window_Base.call(this); }
    Window_Message.prototype = Object.create(Window_Base.prototype);
    Window_Message.prototype.constructor = Window_Message;
    Window_Message.prototype.startMessage = function () { return true; };
    var SceneManager = { _scene: null };
    var __mochiboxSessionToken = 'selftest-token';
    """

    static func makeAgentContext() throws -> JSContext {
        guard let context = JSContext() else {
            throw SelfTestFailure(message: "无法创建 JSContext")
        }
        context.exceptionHandler = { _, exception in
            if let exception = exception {
                FileHandle.standardError.write(Data("[jsc] \(exception)\n".utf8))
            }
        }
        context.evaluateScript(agentStubJS)
        let script = try AgentInjector.loadScript()
        context.evaluateScript(script)
        return context
    }

    static var agentCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "D", name: "agent_installs") { _ in
                let context = try makeAgentContext()
                let version = context.evaluateScript("window.__mochibox ? window.__mochibox.version : -1")?.toInt32() ?? -1
                // 断言必须跟着 `K.agentVersion` 走，不要写死 1/2：
                // V0.6 把 Agent 升到 v2（新增 rpc/cheat/scan），写死会让自检在
                // "脚本与常量同步升级"时假红，掩盖真正的不一致。
                try expectEqual(Int(version), K.agentVersion, "__mochibox.version")
                let installed = context.evaluateScript("window.__mochibox.installed")?.toBool() ?? false
                try expect(installed, "__mochibox.installed 应为 true")
                let hooks = context.evaluateScript("window.__mochibox.probe()")?.toString() ?? "{}"
                try expect(hooks.contains("Window_Base.drawTextEx"), "hooks 应含 Window_Base.drawTextEx，实际 \(hooks)")
                try expect(hooks.contains("\"errors\":0"), "errors 计数应为 0，实际 \(hooks)")
                let keys = context.evaluateScript("Object.keys(window.__mochibox).join(',')")?.toString() ?? ""
                for required in ["version", "installed", "state", "install", "uninstall", "inbox", "drain", "emit"] {
                    try expect(keys.contains(required), "__mochibox 缺少成员 \(required)")
                }
            },
            SelfTestCase(group: "D", name: "agent_emits_and_replaces") { _ in
                let context = try makeAgentContext()
                // 1) 采集
                context.evaluateScript("var w = new Window_Base(); w.drawTextEx('こんにちは', 0, 0);")
                let drained = context.evaluateScript("window.__mochibox.drain()")?.toString() ?? "[]"
                guard let drainedData = drained.data(using: .utf8),
                      let envelopes = try? JSONDecoder().decode([AgentEnvelope].self, from: drainedData) else {
                    throw SelfTestFailure(message: "drain 输出无法解析：\(drained)")
                }
                let texts = envelopes.filter { $0.type == "text" }
                try expectEqual(texts.count, 1, "一次绘制应产生 1 条 text 事件")
                let raw = texts.first?.payload["raw"]?.stringValue ?? ""
                try expectEqual(raw, "こんにちは", "raw")

                // 2) 上报的 key 必须是**页面侧 mapKey**（纯字符串，无哈希），
                //    且与 Host 的 `Segmenter.mapKey(segments)` 逐字节一致。
                let key = texts.first?.payload["key"]?.stringValue ?? ""
                let segments = Segmenter.splitSegments(raw: "こんにちは", engineFamily: K.engineFamily)
                try expectEqual(key, Segmenter.mapKey(segments), "Agent 上报的 key 必须等于 Host 的 mapKey")
                try expectEqual(key, "こんにちは", "mapKey 就是原文字符串本身")

                // 3) Host 侧唯一的哈希：cacheKey（64 位小写 hex），与 mapKey 不同层面。
                let cacheKey = Segmenter.cacheKey(
                    engineFamily: K.engineFamily,
                    srcLang: K.fixedSrcLang,
                    tgtLang: K.fixedTgtLang,
                    segments: segments
                )
                try expectEqual(cacheKey.count, 64, "cacheKey 长度")
                try expect(cacheKey != key, "cacheKey 与 mapKey 必须是两个不同层面的键")

                // 4) 下发译文后应替换形参（用 mapKey 查表）。
                let command = "window.__mochibox.inbox(JSON.stringify({type:'setTranslation',payload:{key:'\(key)',translatedRaw:'你好',segments:[{kind:'text',value:'你好'}]}}));"
                context.evaluateScript(command)
                context.evaluateScript("__lastDraw = null; var w2 = new Window_Base(); w2.drawTextEx('こんにちは', 10, 10);")
                let lastDraw = context.evaluateScript("__lastDraw")?.toString() ?? ""
                try expectEqual(lastDraw, "你好", "命中后形参应被替换为译文")
                let replaced = context.evaluateScript("window.__mochibox.state.replaced")?.toInt32() ?? 0
                try expect(replaced >= 1, "replaced 计数应 ≥ 1")
                let errors = context.evaluateScript("window.__mochibox.state.errors")?.toInt32() ?? -1
                try expectEqual(Int(errors), 0, "替换过程不应产生异常计数")
                // 5) Agent 不得暴露任何哈希实现（§6.2.1 第 1 条）。
                let exposed = context.evaluateScript("Object.keys(window.__mochibox).join(',')")?.toString() ?? ""
                try expect(!exposed.contains("sha256"), "Agent 不得暴露 sha256，实际成员：\(exposed)")
                try expect(!exposed.contains("normalizeForKey"), "Agent 不做文本归一化，实际成员：\(exposed)")
                try expect(exposed.contains("mapKeyOf"), "Agent 应暴露 mapKeyOf，实际成员：\(exposed)")
            },
            // BUG-7 后的契约（PRD P0-08 / P0-09）：跳过句**仍然上报**，但带 `status=skipped`
            // 与 `skipReason`，原文（含 `\C[2]`）原样保留，且不进待翻译集合（不花请求）。
            //
            // 早期实现是把跳过句直接丢弃（`return`）：文本流里凭空少一行，
            // 用户看到一句没被翻译、工具里查不到原因 —— 跳过是功能，功能必须可见。
            SelfTestCase(group: "D", name: "agent_skips_trivial_still_emit") { _ in
                let context = try makeAgentContext()
                _ = context.evaluateScript("window.__mochibox.drain()") // 清掉 install 产生的 hello
                let skippedBefore = context.evaluateScript("window.__mochibox.state.skipped")?.toInt32() ?? 0
                context.evaluateScript("__lastDraw = null; var w = new Window_Base(); w.drawTextEx('350', 0, 0); w.drawTextEx('！？', 0, 0);")
                let skippedAfter = context.evaluateScript("window.__mochibox.state.skipped")?.toInt32() ?? 0
                try expect(skippedAfter > skippedBefore, "纯数字/纯符号必须计入 skipped")

                let drained = context.evaluateScript("window.__mochibox.drain()")?.toString() ?? "[]"
                guard let data = drained.data(using: .utf8),
                      let envelopes = try? JSONDecoder().decode([AgentEnvelope].self, from: data) else {
                    throw SelfTestFailure(message: "drain 输出无法解析：\(drained)")
                }
                let texts = envelopes.filter { $0.type == "text" }
                try expectEqual(texts.count, 2, "跳过句也必须各产生 1 条 text 事件（P0-08）")
                let first = texts.first?.payload
                let second = texts.dropFirst().first?.payload
                try expectEqual(first?["raw"]?.stringValue ?? "", "350", "跳过句原文必须原样保留")
                try expectEqual(first?["status"]?.stringValue ?? "", "skipped", "跳过句 status 必须是 skipped")
                try expectEqual(first?["skipReason"]?.stringValue ?? "", "numeric", "350 的跳过理由")
                try expectEqual(second?["skipReason"]?.stringValue ?? "", "punctuation", "！？的跳过理由")
                let lastDraw = context.evaluateScript("__lastDraw")?.toString() ?? ""
                try expectEqual(lastDraw, "！？", "跳过项必须原样绘制（不得被改写）")

                // 剥码后仍判跳过，且**原文列**保留转义码（P0-09）。
                // 去重签名是 `surface + raw`（不是 mapKey）：`350` 与 `\C[2]350` 的 mapKey 相同
                // （都是 "350"），若按 mapKey 去重，后者会被静默吞掉、原文列再也看不到 `\C[2]350`。
                // 这里故意用**同一个 surface** 连画两次，就是为了钉住这条（QA BUG-8）。
                context.evaluateScript("window.__mochibox.drain(); __lastDraw = null; var w2 = new Window_Base(); w2.drawTextEx('\\\\C[2]350', 0, 0);")
                let drained2 = context.evaluateScript("window.__mochibox.drain()")?.toString() ?? "[]"
                guard let data2 = drained2.data(using: .utf8),
                      let envelopes2 = try? JSONDecoder().decode([AgentEnvelope].self, from: data2) else {
                    throw SelfTestFailure(message: "drain 输出无法解析：\(drained2)")
                }
                let controlTexts = envelopes2.filter { $0.type == "text" }
                try expectEqual(controlTexts.count, 1, "\\C[2]350 必须单独产生 1 条事件（不得被 350 的去重吞掉）")
                let control = controlTexts.first?.payload
                try expectEqual(control?["raw"]?.stringValue ?? "", "\\C[2]350", "原文必须保留 \\C[2]")
                try expectEqual(control?["skipReason"]?.stringValue ?? "", "numeric", "\\C[2]350 剥码后应判 numeric")
                let controlDraw = context.evaluateScript("__lastDraw")?.toString() ?? ""
                try expectEqual(controlDraw, "\\C[2]350", "跳过的控制码句不得被改写")

                // 可翻译句不得带 skipReason（否则下游无法区分"跳过"与"待翻译"）。
                context.evaluateScript("window.__mochibox.drain(); var w3 = new Window_Base(); w3.drawTextEx('こんにちは', 0, 0);")
                let drained3 = context.evaluateScript("window.__mochibox.drain()")?.toString() ?? "[]"
                guard let data3 = drained3.data(using: .utf8),
                      let envelopes3 = try? JSONDecoder().decode([AgentEnvelope].self, from: data3) else {
                    throw SelfTestFailure(message: "drain 输出无法解析：\(drained3)")
                }
                let normal = envelopes3.filter { $0.type == "text" }.first?.payload
                try expect(normal?["skipReason"]?.stringValue == nil,
                           "可翻译句不得带 skipReason，实际 payload=\(String(describing: normal))")
                try expectEqual(normal?["status"]?.stringValue ?? "", "pending", "可翻译句 status=pending")
            },
            SelfTestCase(group: "D", name: "agent_uninstall_restores") { _ in
                let context = try makeAgentContext()
                context.evaluateScript("window.__mochibox.uninstall();")
                let restoredEx = context.evaluateScript("Window_Base.prototype.drawTextEx === window.__mochibox._orig.drawTextEx")?.toBool() ?? false
                try expect(restoredEx, "uninstall 后 drawTextEx 应复原")
                let restoredText = context.evaluateScript("Window_Base.prototype.drawText === window.__mochibox._orig.drawText")?.toBool() ?? false
                try expect(restoredText, "uninstall 后 drawText 应复原")
                let installed = context.evaluateScript("window.__mochibox.installed")?.toBool() ?? true
                try expect(!installed, "uninstall 后 installed 应为 false")
                // 重复 install 不应叠加
                context.evaluateScript("window.__mochibox.install(); var first = Window_Base.prototype.drawTextEx; window.__mochibox.install();")
                let noDoubleHook = context.evaluateScript("Window_Base.prototype.drawTextEx === first")?.toBool() ?? false
                try expect(noDoubleHook, "重复 install 不得叠加 hook")
            },
            // 字体链：游戏自带的是**日文字体**，它有汉字字形 —— 排在前面就会把简体
            // 中文画成日文字形，等于没修。这里钉住三件事：默认苹方打头、选了族名排最前、
            // 游戏 fontFace 仍保留（只作符号兜底，必须在中文字体之后）。
            SelfTestCase(group: "D", name: "agent_font_chain") { _ in
                let context = try makeAgentContext()
                let auto = context.evaluateScript("new Bitmap()._makeFontNameText()")?.toString() ?? ""
                try expect(auto.hasPrefix("24px \"PingFang SC\","), "空字体族时字号后第一个族名必须是 PingFang SC，实际 \(auto)")
                try expect(auto.contains("GameFont"), "游戏自己的 fontFace 应保留（符号兜底），实际 \(auto)")
                if let pingIndex = auto.range(of: "PingFang SC")?.lowerBound,
                   let gameIndex = auto.range(of: "GameFont")?.lowerBound {
                    try expect(gameIndex > pingIndex, "游戏日文字体必须排在中文字体之后，实际 \(auto)")
                } else {
                    throw SelfTestFailure(message: "字体链缺族名，实际 \(auto)")
                }

                context.evaluateScript("window.__mochibox.inbox(JSON.stringify({type:'config',payload:{gameFontFamily:'Unifont Smooth'}}))")
                let chosen = context.evaluateScript("new Bitmap()._makeFontNameText()")?.toString() ?? ""
                try expect(chosen.hasPrefix("24px \"Unifont Smooth\","), "用户族名必须带引号排在最前，实际 \(chosen)")
                try expect(chosen.contains("GameFont"), "用户选字体时游戏 fontFace 仍应保留，实际 \(chosen)")
                try expect(chosen.contains("PingFang SC"), "默认链仍应兜底，实际 \(chosen)")

                let sized = context.evaluateScript("var s = new Bitmap(); s.fontSize = 32; s._makeFontNameText()")?.toString() ?? ""
                try expect(sized.hasPrefix("32px "), "字号 32 时前缀应是 32px，实际 \(sized)")

                let italic = context.evaluateScript("var b = new Bitmap(); b.fontItalic = true; b._makeFontNameText()")?.toString() ?? ""
                try expect(italic.hasPrefix("italic "), "斜体前缀由自己拼（不委托 base），实际 \(italic)")
                let errors = context.evaluateScript("window.__mochibox.state.errors")?.toInt32() ?? -1
                try expectEqual(Int(errors), 0, "字体注入不应产生异常")
            },
            // 关闭翻译**不得串消息**：replacedTextsByIndex 是"下标 → 原文"，只描述
            // 当前这条消息。早先它在消息之间累积（只在 enabled=false 时清空），
            // 于是本条没有任何替换（如整条纯标点）时，映射里仍是上一条的下标 ——
            // 点"关闭翻译"就把上一条的原文写进了当前消息窗。
            SelfTestCase(group: "D", name: "agent_disable_keeps_current_message") { _ in
                let context = try makeAgentContext()
                _ = context.evaluateScript("window.__mochibox.drain()")

                func pushTranslation(_ raw: String, _ translated: String) {
                    context.evaluateScript("window.__mochibox.inbox(JSON.stringify({type:'setTranslation',payload:{key:'\(raw)',translatedRaw:'\(translated)',segments:[{kind:'text',value:'\(translated)'}]}}));")
                }
                func startMessage(_ texts: [String]) {
                    let literal = texts.map { "'\($0)'" }.joined(separator: ",")
                    context.evaluateScript("$gameMessage = { _texts: [\(literal)] }; new Window_Message().startMessage();")
                }
                func currentTexts() -> String {
                    return context.evaluateScript("$gameMessage._texts.join('|')")?.toString() ?? ""
                }

                // 消息 A：三行都有译文 → 整句替换，映射记下 A 的下标。
                let aTexts = ["あさひ", "ひるひ", "ゆうべ"]
                pushTranslation(aTexts[0], "朝阳")
                pushTranslation(aTexts[1], "正午")
                pushTranslation(aTexts[2], "昨晚")
                startMessage(aTexts)
                try expectEqual(currentTexts(), "朝阳|正午|昨晚", "消息 A 应整句替换")

                // 消息 B：中间一行没有译文 → 逐行降级：有译文的行照样替换，没译文的行留原文。
                // 旧实现是"任一行未命中则整句不替换"，一行纯标点就能把整条消息拖回日文。
                let bTexts = ["よなか", "あけがた", "ひるとき"]
                pushTranslation(bTexts[0], "深夜")
                pushTranslation(bTexts[2], "正午时分")
                startMessage(bTexts)
                try expectEqual(currentTexts(), "深夜|あけがた|正午时分", "有一行未命中时其余行仍应逐行替换")

                // 关闭翻译：只能恢复 B 自己的原文 —— 被替换的两行回到日文，未命中的那行本来就没动。
                context.evaluateScript("window.__mochibox.inbox(JSON.stringify({type:'config',payload:{enabled:false}}))")
                let afterDisable = currentTexts()
                try expectEqual(afterDisable, bTexts.joined(separator: "|"),
                               "关闭翻译不得把上一条消息的原文写进当前消息，实际 \(afterDisable)")
                for leaked in aTexts {
                    try expect(!afterDisable.contains(leaked),
                               "当前消息窗出现了上一条消息的原文 \(leaked)：\(afterDisable)")
                }

                // 反向保护：重新开启后，当前这条**全译**消息关闭时仍要恢复原文
                // （清空映射不能把 restore 本身废掉）。
                context.evaluateScript("window.__mochibox.inbox(JSON.stringify({type:'config',payload:{enabled:true}}))")
                let cTexts = ["さむい", "あつい", "ぬるい"]
                pushTranslation(cTexts[0], "冷")
                pushTranslation(cTexts[1], "热")
                pushTranslation(cTexts[2], "温")
                startMessage(cTexts)
                try expectEqual(currentTexts(), "冷|热|温", "消息 C 应整句替换")
                context.evaluateScript("window.__mochibox.inbox(JSON.stringify({type:'config',payload:{enabled:false}}))")
                try expectEqual(currentTexts(), cTexts.joined(separator: "|"), "关闭翻译应恢复当前消息的原文")
                let errors = context.evaluateScript("window.__mochibox.state.errors")?.toInt32() ?? -1
                try expectEqual(Int(errors), 0, "开关翻译不应产生异常计数")
            }
        ]
    }
}

// MARK: - E 组：协议编解码

extension SelfTestRunner {
    static var codecCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "E", name: "text_event_roundtrip") { _ in
                let event = TextEvent(
                    ts: 1763600000000,
                    lastSeenTs: 1763600000001,
                    sessionId: "s1",
                    gameId: "g1",
                    engine: "mvmz",
                    surface: "Window_Message",
                    sceneClass: "Scene_Map",
                    order: 3,
                    raw: "\\C[2]魔物が来た",
                    segments: Segmenter.splitSegments(raw: "\\C[2]魔物が来た", engineFamily: "mvmz"),
                    text: "魔物が来た",
                    key: String(repeating: "a", count: 64),
                    status: .translated,
                    translated: "\\C[2]魔物来了",
                    translatedSegments: nil,
                    backend: .openai,
                    latencyMs: 120,
                    cached: false,
                    occurrences: 2,
                    skipReason: nil,
                    error: nil
                )
                let data = try FileIO.encoder.encode(event)
                let decoded = try JSONDecoder().decode(TextEvent.self, from: data)
                try expectEqual(decoded.key, event.key, "key")
                try expectEqual(decoded.raw, event.raw, "raw")
                try expectEqual(decoded.segments.count, event.segments.count, "segments")
                try expectEqual(decoded.status, event.status, "status")
                try expectEqual(decoded.occurrences, 2, "occurrences")
                // PRD v0.3 §5.2 契约字段：order 从 1 开始、surfaceKind 由 surface 派生。
                try expectEqual(decoded.order, 3, "order")
                try expectEqual(decoded.surfaceKind ?? "", SurfaceKind.dialogue, "Window_Message → dialogue")
                try expectEqual(SurfaceKind.of(surface: "Window_Base.drawText"), SurfaceKind.menu, "Window_Base → menu")
                try expectEqual(SurfaceKind.of(surface: "Bitmap.drawText"), SurfaceKind.system, "Bitmap → system")
                try expect(SurfaceKind.of(surface: "unknown") == nil, "其余 surface 应留 nil")
            },
            SelfTestCase(group: "E", name: "envelope_unknown_fields_and_type") { _ in
                let json = """
                {"v":1,"type":"future_type","sessionToken":"abcd","payload":{"a":1},"unknownField":"x"}
                """
                let data = Data(json.utf8)
                let envelope = try JSONDecoder().decode(AgentEnvelope.self, from: data)
                try expectEqual(envelope.type, "future_type", "未知 type 不应报错")
                try expectEqual(envelope.sessionToken, "abcd", "sessionToken")
                try expectEqual(envelope.payload["a"]?.intValue, 1, "payload 透传")
            },
            SelfTestCase(group: "E", name: "protocol_version_mismatch_detectable") { _ in
                let json = "{\"v\":2,\"type\":\"text\",\"sessionToken\":\"t\",\"payload\":{}}"
                let envelope = try JSONDecoder().decode(AgentEnvelope.self, from: Data(json.utf8))
                try expect(envelope.v != K.protocolVersion, "v=2 必须可被判别为不兼容")
                try expectEqual(ErrorCode.unsupportedProtocol.retryable, false, "unsupported_protocol 不可重试")
            },
            SelfTestCase(group: "E", name: "host_command_json") { _ in
                let item = TranslationPushItem(
                    key: "k1",
                    translatedRaw: "\\C[2]你好",
                    segments: [Segment(kind: .code, value: "\\C[2]"), Segment(kind: .text, value: "你好")]
                )
                let text = try HostCommand.setTranslations([item]).jsonText()
                guard let data = text.data(using: .utf8),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    throw SelfTestFailure(message: "HostCommand JSON 不可解析")
                }
                try expectEqual(value["type"]?.stringValue, "setTranslations", "type")
                let items = value["payload"]?["items"]?.arrayValue ?? []
                try expectEqual(items.count, 1, "items 数量")
                try expectEqual(items.first?["key"]?.stringValue, "k1", "key")
                let expression = try HostCommand.setTranslation(item).evaluateExpression()
                try expect(expression.contains("__mochibox.inbox"), "表达式应调用 inbox")
                try expect(expression.contains("setTranslation"), "表达式应含命令类型")
            },
            SelfTestCase(group: "E", name: "host_command_config_font_family") { _ in
                // 字体族必须随 config 一起下发；旧字段一个都不能少（Agent 只认完整配置）。
                let config = AgentConfig(
                    enabled: false,
                    fontScale: 1.1,
                    srcLang: "ja",
                    tgtLang: "zh-Hans",
                    maxMapSize: 1234,
                    gameFontFamily: "Unifont Smooth"
                )
                let json = try HostCommand.config(config).jsonText()
                try expect(json.contains("\"gameFontFamily\":\"Unifont Smooth\""), "config 缺少 gameFontFamily，实际 \(json)")
                try expect(json.contains("\"enabled\":false"), "config 缺少 enabled，实际 \(json)")
                try expect(json.contains("\"fontScale\":1.1"), "config 缺少 fontScale，实际 \(json)")
                try expect(json.contains("\"maxMapSize\":1234"), "config 缺少 maxMapSize，实际 \(json)")
                try expect(json.contains("\"srcLang\":\"ja\"") && json.contains("\"tgtLang\":\"zh-Hans\""), "config 缺少语言对，实际 \(json)")
            }
        ]
    }
}

// MARK: - G 组：会话设置同步（管线侧）

extension SelfTestRunner {
    static var sessionCases: [SelfTestCase] {
        return [
            // 关闭翻译必须同时落到**管线**的设置：实时链路读 `SessionController.settings`，
            // 全文翻译走 `FullTextController → TranslationPipeline.resolve → settings().agentEnabled`。
            // 早先 `setTranslationEnabled` 只改本地 settings，`settingsBox` 不动 —— 开关关了，
            // 全文翻译仍按 enabled=true 继续请求后端（继续计费）。
            SelfTestCase(group: "G", name: "translation_toggle_syncs_pipeline_settings") { context in
                let root = try directory(context, "g_toggle")
                let controller = await MainActor.run { () -> SessionController in
                    let log = SessionLog(
                        directory: root.appendingPathComponent("logs"),
                        sessionId: "selftest",
                        minLevel: .error
                    )
                    var settings = Settings()
                    settings.agentEnabled = true
                    return SessionController(
                        stream: TextStreamStore(maxRows: 20),
                        cache: TranslationCache(url: root.appendingPathComponent("cache.json"), log: log),
                        log: log,
                        settings: settings,
                        paths: AppPaths(root: root),
                        credentialsProvider: { Credentials() }
                    )
                }
                let initial = await MainActor.run { controller.settingsBox.settings.agentEnabled }
                try expect(initial, "初始应为开启")

                await controller.setTranslationEnabled(false)
                let disabled = await MainActor.run { controller.settingsBox.settings.agentEnabled }
                try expect(!disabled,
                           "关闭翻译后 settingsBox.settings.agentEnabled 必须为 false，否则全文翻译仍会继续计费")

                await controller.setTranslationEnabled(true)
                let enabled = await MainActor.run { controller.settingsBox.settings.agentEnabled }
                try expect(enabled, "重新开启后 settingsBox 应同步回 true")
            }
        ]
    }
}
