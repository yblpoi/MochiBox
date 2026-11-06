//
//  probe_prewarm.swift
//  MochiBox · E2E 领域层探针（D23：RGSS 启动预译）
//
//  这一支探针不碰 GUI / 不碰真实 provider：用 Marshal 现造 XP / VX Ace 数据文件，
//  真跑 RGSSPrewarm.scan + run + 真实 TranslationCache + TranslationPipeline，
//  假 provider 只负责计数与"段数合法"的译文。断言三件事：
//
//    · 预译写进缓存的 key 与运行时 RGSSPipelineTranslator.makeRequestItem 算出的**同一 key**
//      （XP 的 101+401 整段消息必须能命中的就是这条）；
//    · 缓存纯度：资源名 / 纯数字 / 纯符号 / 已中文 / 过短文本 0 请求、0 缓存条目；
//    · 不阻塞与降级：provider 卡住时 run() 仍然立刻返回；关闭 / 直通 / provider 失败
//      都只意味着"首句回落运行时翻译"，不抛错、不写坏缓存。
//
//  规模闸门（maxSegments）与设置层闸门（prewarmEnabled / passthrough / 上限 0）
//  也在这里断言，因为 SessionController 的接线只是"skipReason 非空就不建 Task"。
//

import Foundation

@main
struct DomainPrewarmProbe {
    static func main() async {
        let args = ProbeArgs()
        let root = args.root
        Fs.make(root)
        switch args.only {
        case "D23":
            await runD23(root: root)
        default:
            TAP.ok("prewarm-select", "未知的 --only：\(args.only)", false)
        }
        exit(TAP.finish())
    }
}

// MARK: - 假 provider

/// 记录每次真正发给后端的 item 文本；译文保证"文本段数 = 原文文本段数"，否则管线
/// 会按段数漂移丢弃（那样缓存永远是空的，测试会变成假失败）。
actor RecordingProvider: TranslatorProvider {
    nonisolated var kind: BackendKind { .openai }
    private(set) var texts: [String] = []
    private(set) var calls = 0
    private let gate: Gate?

    init(gate: Gate? = nil) {
        self.gate = gate
    }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        calls += 1
        if let gate {
            await gate.wait()
        }
        var results: [TranslationResult] = []
        results.reserveCapacity(batch.count)
        for request in batch {
            var items: [TranslationResultItem] = []
            for item in request.items {
                texts.append(item.text)
                let count = max(1, Segmenter.textSegmentCount(item.segments))
                let pieces = (0..<count).map { "译\($0)" }
                items.append(TranslationResultItem(
                    key: item.key,
                    translatedText: pieces.joined(separator: K.unitSeparatorString),
                    translatedSegments: nil,
                    cached: false,
                    latencyMs: 1
                ))
            }
            results.append(TranslationResult(
                requestId: request.requestId,
                items: items,
                backend: request.backend,
                error: nil
            ))
        }
        return results
    }
}

/// 直到 open() 之前都挂住 provider —— 用来证明 run() 不 await 译文。
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

actor CallCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

enum ProbeFailure: Error {
    case boom
}

struct FailingProvider: TranslatorProvider {
    var kind: BackendKind { .openai }
    let counter: CallCounter

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        await counter.bump()
        throw ProbeFailure.boom
    }
}

// MARK: - Fixture（程序化 Marshal）

enum PrewarmFixture {
    static let dialogueFirst = "こんにちは、これは最初の台詞です。"
    static let dialogueSecond = "二行目：English と記号を含む、401 の続行テスト。"
    /// 运行时形状：Interpreter#command_101 里 message_text = params[0] + "\n"，
    /// 每个 401 再 "+= text + \"\n\"" —— 尾部一定还有一枚换行。
    static let dialogueWhole = dialogueFirst + "\n" + dialogueSecond + "\n"
    /// XP 的 102 选项由 setup_choices 追加进同一条 message_text，不是独立窗口文本。
    static let choiceBlock = controlLine + "\n" + "はい" + "\n" + "いいえ" + "\n"
    static let chineseSentence = "这个句子已经是中文的了，不需要翻译。"
    static let controlLine = "\\C[1]赤い文字のテスト\\C[0]"
    static let troopLine = "トループの台詞です。"
    static let systemTitle = "テストゲーム"
    static let currency = "ゴールド"
    /// words.gold 与 currency_unit 用**不同**文本：否则同一句在同一份 System 里出现两次，
    /// 会再产生一条“重复”，把去重断言（1 条）和选中数（9 条）算错。
    static let goldWord = "所持金"

    static func string(_ text: String, rgss3: Bool = false) -> MarshalValue {
        return .string(text, encodingIVar: rgss3 ? true : nil)
    }

    static func command(_ code: Int64, _ parameters: [MarshalValue]) -> MarshalValue {
        return MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::EventCommand"),
            ivars: [
                MarshalIVar(name: MarshalSymbol("@code"), value: MarshalValue.integer(code)),
                MarshalIVar(name: MarshalSymbol("@indent"), value: MarshalValue.integer(0)),
                MarshalIVar(name: MarshalSymbol("@parameters"), value: .array(parameters))
            ]
        )))
    }

    /// XP：101 首行 + 401 续行 = 一条整段消息；其余行各自成段。
    static func xpMapList() -> [MarshalValue] {
        return [
            command(101, [string(dialogueFirst), string("Actor1"), .integer(0), .integer(2), .integer(0)]),
            command(401, [string(dialogueSecond)]),
            command(101, [string("12345"), string(""), .integer(0), .integer(2), .integer(0)]),
            command(101, [string("！！！？？？"), string(""), .integer(0), .integer(2), .integer(0)]),
            command(101, [string("a"), string(""), .integer(0), .integer(2), .integer(0)]),
            command(101, [string(chineseSentence), string(""), .integer(0), .integer(2), .integer(0)]),
            command(101, [string(controlLine), string(""), .integer(0), .integer(2), .integer(0)]),
            command(102, [.array([string("はい"), string("いいえ")]), .integer(2)]),
            command(0, [])
        ]
    }

    /// Map002 只放一条与 Map001 完全相同的整段消息：用来断言 cacheKey 去重，
    /// 顺带证明“同一句出现在两张地图”不会重复提交。
    static func xpDuplicateList() -> [MarshalValue] {
        return [
            command(101, [string(dialogueFirst), string(""), .integer(0), .integer(2), .integer(0)]),
            command(401, [string(dialogueSecond)]),
            command(0, [])
        ]
    }

    static func system(rgss3: Bool = false) -> MarshalValue {
        let commands = MarshalValue(.hash(MarshalHash(pairs: [
            (key: MarshalValue(.symbol(MarshalSymbol("fight"))), value: string("攻撃", rgss3: rgss3)),
            (key: MarshalValue(.symbol(MarshalSymbol("escape"))), value: string("逃げる", rgss3: rgss3))
        ])))
        let terms = MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::System::Terms"),
            ivars: [
                MarshalIVar(name: MarshalSymbol("@commands"), value: commands),
                MarshalIVar(name: MarshalSymbol("@basic"), value: .array([
                    string("レベル", rgss3: rgss3),
                    string("たいりょく", rgss3: rgss3)
                ]))
            ]
        )))
        let words = MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::System::Words"),
            ivars: [
                MarshalIVar(name: MarshalSymbol("@gold"), value: string(goldWord, rgss3: rgss3))
            ]
        )))
        return MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::System"),
            ivars: [
                MarshalIVar(name: MarshalSymbol("@game_title"), value: string(systemTitle, rgss3: rgss3)),
                MarshalIVar(name: MarshalSymbol("@currency_unit"), value: string(currency, rgss3: rgss3)),
                MarshalIVar(name: MarshalSymbol("@terms"), value: terms),
                MarshalIVar(name: MarshalSymbol("@words"), value: words)
            ]
        )))
    }

    static func map(displayName: String, list: [MarshalValue], rgss3: Bool = false) -> MarshalValue {
        let page = MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::Event::Page"),
            ivars: [MarshalIVar(name: MarshalSymbol("@list"), value: .array(list))]
        )))
        let event = MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::Event"),
            ivars: [MarshalIVar(name: MarshalSymbol("@pages"), value: .array([page]))]
        )))
        let events = MarshalValue(.hash(MarshalHash(pairs: [
            (key: MarshalValue.integer(1), value: event)
        ])))
        return MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::Map"),
            ivars: [
                MarshalIVar(name: MarshalSymbol("@display_name"), value: string(displayName, rgss3: rgss3)),
                MarshalIVar(name: MarshalSymbol("@events"), value: events)
            ]
        )))
    }

    static func troops() -> MarshalValue {
        let page = MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::Troop::Page"),
            ivars: [MarshalIVar(name: MarshalSymbol("@list"), value: .array([
                command(101, [string(troopLine), string(""), .integer(0), .integer(2), .integer(0)]),
                command(0, [])
            ]))]
        )))
        let troop = MarshalValue(.object(MarshalRecord(
            className: MarshalSymbol("RPG::Troop"),
            ivars: [MarshalIVar(name: MarshalSymbol("@pages"), value: .array([page]))]
        )))
        return .array([troop])
    }

    /// VX Ace：101[0] 是头像文件名（不取），401 / 405 逐行，102 选项逐个。
    static func vxAceMapList() -> [MarshalValue] {
        return [
            command(101, [string("Actor1", rgss3: true), .integer(0), .integer(0), .integer(2)]),
            command(401, [string("光る海の向こうへ。", rgss3: true)]),
            command(405, [string("Banjarmachine adalah mesin pembangkit listrik.", rgss3: true)]),
            command(102, [.array([string("はい", rgss3: true), string("いいえ", rgss3: true)]), .integer(2)]),
            command(401, [string("二行目です。", rgss3: true)]),
            command(0, [])
        ]
    }

    static func write(_ value: MarshalValue, to directory: URL, name: String) throws {
        Fs.make(directory)
        let data = try MarshalWriter.dump(value)
        try data.write(to: directory.appendingPathComponent(name))
    }

    static func prepare(root: URL) throws {
        let xpData = root.appendingPathComponent("happy").appendingPathComponent("Data")
        try write(system(), to: xpData, name: "System.rxdata")
        try write(map(displayName: "MAP001", list: xpMapList()), to: xpData, name: "Map001.rxdata")
        try write(map(displayName: "MAP002", list: xpDuplicateList()), to: xpData, name: "Map002.rxdata")
        try write(troops(), to: xpData, name: "Troops.rxdata")
        // Scripts 必须在扫描前被文件名排除：即使字节不是 Marshal，也不该计入 filesFailed。
        try Data("this is not a marshal payload".utf8)
            .write(to: xpData.appendingPathComponent("Scripts.rxdata"))

        let vxAceData = root.appendingPathComponent("vxace").appendingPathComponent("Data")
        try write(map(displayName: "MAP001", list: vxAceMapList(), rgss3: true),
                  to: vxAceData, name: "Map001.rvdata2")
    }
}

// MARK: - 探针骨架

struct PrewarmHarness {
    let cache: TranslationCache
    let pipeline: TranslationPipeline
    let environment: RGSSPipelineEnvironment
    let log: SessionLog
}

func makePrewarmHarness(root: URL, provider: @escaping @Sendable () -> TranslatorProvider) async -> PrewarmHarness {
    var settings = Settings()
    settings.backendType = .openai
    settings.endpoint = "https://example.invalid/v1"
    settings.model = "test-model"
    settings.agentEnabled = true
    settings.batchWindowMs = 0
    settings.timeoutSec = 5
    let snapshot = settings

    let log = SessionLog(directory: root.appendingPathComponent("logs"), sessionId: "prewarm", minLevel: .debug)
    let cache = TranslationCache(url: root.appendingPathComponent("cache.json"), maxEntries: 5000, log: log)
    await cache.load()
    let pipeline = TranslationPipeline(
        cache: cache,
        provider: provider,
        settings: { snapshot },
        policy: ResiliencePolicy(settings: snapshot),
        log: log
    )
    let environment = RGSSPipelineEnvironment(
        pipeline: pipeline,
        cache: cache,
        glossaryBox: nil,
        srcLang: K.fixedSrcLang,
        tgtLang: K.fixedTgtLang,
        timeoutSec: 30,
        log: log
    )
    return PrewarmHarness(cache: cache, pipeline: pipeline, environment: environment, log: log)
}

func prewarmKey(_ raw: String) -> String? {
    return RGSSPipelineTranslator.makeRequestItem(
        raw: raw,
        srcLang: K.fixedSrcLang,
        tgtLang: K.fixedTgtLang,
        glossaryBox: nil
    )?.key
}

func configuredSettings() -> Settings {
    var settings = Settings()
    settings.backendType = .openai
    settings.endpoint = "https://example.invalid/v1"
    settings.model = "test-model"
    settings.agentEnabled = true
    return settings
}

// MARK: - D23

func runD23(root: URL) async {
    do {
        try PrewarmFixture.prepare(root: root)
    } catch {
        TAP.ok("prewarm-fixture", "构造 Marshal fixture 失败：\(error)", false)
        return
    }

    await phaseScan(root: root)
    await phaseHappy(root: root)
    await phaseWarmCache(root: root)
    await phaseNonBlocking(root: root)
    await phaseDisabled(root: root)
    await phasePassthrough(root: root)
    await phaseTruncation(root: root)
    await phaseTroops(root: root)
    await phaseVxAce(root: root)
    await phaseProviderFailure(root: root)
    await phaseSettings()
    await phaseLog(root: root)
}

/// 只读扫描：候选数量 / 顺序 / XP 分组 / 资源名不进候选。
func phaseScan(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    let options = RGSSPrewarm.Options()
    let scan = RGSSPrewarm.scan(gameRoot: gameRoot, options: options)

    TAP.eqInt("prewarm-scan-files", "只统计识别的数据文件（Scripts/Troops 默认排除）", scan.filesScanned, 3)
    TAP.eqInt("prewarm-scan-failed", "非法 Scripts.rxdata 不进入解析（0 个失败文件）", scan.filesFailed, 0)
    TAP.eqInt("prewarm-scan-texts", "候选条数 = system 7 + Map001 6 + Map002 1", scan.textsScanned, 14)
    TAP.eq("prewarm-scan-first", "扫描顺序：system 最先", scan.candidates.first?.fileName ?? "", "System.rxdata")
    TAP.ok("prewarm-scan-xp-group", "XP 101+401 拼成整段消息",
           scan.candidates.contains { $0.raw == PrewarmFixture.dialogueWhole })
    TAP.ok("prewarm-scan-xp-runtime-shape",
           "整段消息与运行时 message_text 同形：每行都以 \"\\n\" 结尾（含尾部换行）",
           PrewarmFixture.dialogueWhole.hasSuffix("\n")
               && scan.candidates.contains { $0.raw == PrewarmFixture.dialogueWhole })
    TAP.ok("prewarm-scan-xp-path", "整段消息的路径定位到 101 的 parameters[0]",
           scan.candidates.contains {
               $0.raw == PrewarmFixture.dialogueWhole
                   && $0.path == "maps[1].events[1].pages[0].list[0].parameters[0]"
           })
    TAP.ok("prewarm-scan-choices", "XP 的 102 选项并进同一条整段消息（setup_choices 追加进 message_text）",
           scan.candidates.contains { $0.raw == PrewarmFixture.choiceBlock }
               && !scan.candidates.contains { $0.raw == "はい" || $0.raw == "いいえ" })
    TAP.ok("prewarm-scan-control-line", "含控制符的行保留原文（key 构造时再剥码），选项并进同一段",
           scan.candidates.contains { $0.raw == PrewarmFixture.choiceBlock })
    TAP.ok("prewarm-scan-no-face-name", "101[1] 头像文件名 Actor1 不进候选",
           !scan.candidates.contains { $0.raw == "Actor1" })
    TAP.ok("prewarm-scan-no-map-name", "地图 display_name 不进候选（资源/地图名不是对白）",
           !scan.candidates.contains { $0.raw == "MAP001" || $0.raw == "MAP002" })
    TAP.ok("prewarm-scan-no-troops", "troops 默认不扫",
           !scan.candidates.contains { $0.raw == PrewarmFixture.troopLine })

    var troopsOptions = options
    troopsOptions.includeTroops = true
    let withTroops = RGSSPrewarm.scan(gameRoot: gameRoot, options: troopsOptions)
    TAP.eqInt("prewarm-scan-troops-on", "prewarmIncludeTroops=true 时多 1 条（troops 页）",
              withTroops.textsScanned, 15)
}

/// Happy path：真实缓存 + 管线 + 假 provider。
func phaseHappy(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    let provider = RecordingProvider()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-happy"),
        provider: { provider }
    )
    let options = RGSSPrewarm.Options()
    let stats = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: options)

    TAP.eqInt("prewarm-happy-texts", "扫到 14 条候选", stats.textsScanned, 14)
    TAP.eqInt("prewarm-happy-skipped", "数字/符号/过短/已中文 4 条被 SkipRules 跳过", stats.skipped, 4)
    TAP.eqInt("prewarm-happy-duplicate", "Map002 与 Map001 同句 → 去重 1 条", stats.duplicate, 1)
    TAP.eqInt("prewarm-happy-selected", "选中 9 条（去重且通过 SkipRules）", stats.selected, 9)
    TAP.eqInt("prewarm-happy-submitted", "提交 9 条（.low）", stats.submitted, 9)
    TAP.eqInt("prewarm-happy-cachehit", "冷缓存首轮 0 命中", stats.cacheHit, 0)
    TAP.ok("prewarm-happy-not-truncated", "未触发规模闸门", !stats.truncated && stats.stopReason == nil)

    await harness.pipeline.flush()
    let entries = await harness.cache.stats().entries
    TAP.eqInt("prewarm-happy-cache-entries", "flush 后缓存 9 条", entries, 9)

    let texts = await provider.texts
    TAP.eqInt("prewarm-happy-provider-items", "provider 正好收到 9 条", texts.count, 9)
    // provider 拿到的是 joinForBackend 之后的文本（换行在骨架里是文本段分隔符，
    // 所以这里按“同一条请求里同时出现两行”断言，而不是逐字比对原始换行）。
    TAP.ok("prewarm-happy-provider-group", "provider 收到 XP 整段消息（两行在同一条请求里）",
           texts.contains {
               $0.contains(PrewarmFixture.dialogueFirst) && $0.contains(PrewarmFixture.dialogueSecond)
           })

    // 运行时 key：预译写进去的必须是同一把钥匙，否则首句仍要再翻一次。
    guard let wholeKey = prewarmKey(PrewarmFixture.dialogueWhole) else {
        TAP.ok("prewarm-happy-key", "XP 整段消息能构造 key", false)
        return
    }
    let hit = await harness.cache.get(wholeKey)
    TAP.ok("prewarm-happy-key", "XP 整段消息的运行时 cacheKey 已在缓存中", hit != nil)

    // 缓存纯度：这些文本一条都不许发请求、不许进缓存。
    let forbidden = [
        ("Actor1", "头像资源名"),
        ("MAP001", "地图 display_name"),
        ("12345", "纯数字"),
        ("！！！？？？", "纯符号"),
        ("a", "过短（< minTranslateLength）"),
        (PrewarmFixture.chineseSentence, "已是中文")
    ]
    for (raw, label) in forbidden {
        guard let key = prewarmKey(raw) else { continue }
        let cached = await harness.cache.get(key)
        TAP.ok("prewarm-pure-cache-\(raw)", "\(label) 不写缓存", cached == nil)
        TAP.ok("prewarm-pure-provider-\(raw)", "\(label) 不发请求",
               !texts.contains(raw))
    }
    TAP.ok("prewarm-pure-control", "控制符行剥码后以文本段入缓存（选项同段）",
           texts.contains { $0.contains("赤い文字のテスト") && $0.contains("はい") && $0.contains("いいえ") })
}

/// 热缓存：第二次预译只看缓存，不重复提交。
func phaseWarmCache(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    let provider = RecordingProvider()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-warm"),
        provider: { provider }
    )
    let options = RGSSPrewarm.Options()
    _ = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: options)
    await harness.pipeline.flush()

    let second = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: options)
    TAP.eqInt("prewarm-warm-cachehit", "第二轮全部命中缓存（9）", second.cacheHit, 9)
    TAP.eqInt("prewarm-warm-submitted", "第二轮没有重复提交", second.submitted, 0)
    await harness.pipeline.cancelAll()
}

/// 不阻塞：provider 被门卡住时 run() 仍然立刻返回；开门后缓存才被填充。
func phaseNonBlocking(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    let gate = Gate()
    let provider = RecordingProvider(gate: gate)
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-gate"),
        provider: { provider }
    )
    let started = Date()
    let stats = await RGSSPrewarm.run(
        environment: harness.environment,
        gameRoot: gameRoot,
        options: RGSSPrewarm.Options()
    )
    let elapsedSeconds = Date().timeIntervalSince(started)
    TAP.ok("prewarm-nonblocking-fast", "provider 挂起时 run() 仍然在 2s 内返回（不 await 译文）",
           elapsedSeconds < 2.0, "elapsed=\(elapsedSeconds)s")
    TAP.eqInt("prewarm-nonblocking-submitted", "条目已入队（9）", stats.submitted, 9)

    var providerEntered = false
    for _ in 0..<100 {
        if await provider.calls >= 1 { providerEntered = true; break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    TAP.ok("prewarm-nonblocking-entered", "provider 确实被调用并卡在门上", providerEntered)
    let entriesBefore = await harness.cache.stats().entries
    TAP.eqInt("prewarm-nonblocking-cache-empty", "译文还没回来时缓存仍为空", entriesBefore, 0)

    await gate.open()
    await harness.pipeline.flush()
    let entriesAfter = await harness.cache.stats().entries
    TAP.eqInt("prewarm-nonblocking-cache-filled", "开门并 flush 后缓存填充 9 条", entriesAfter, 9)
}

/// 关闭 / 直通：不扫描、不发请求、不写缓存（直通写原文进缓存会污染后续翻译）。
func phaseDisabled(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")

    var disabledOptions = RGSSPrewarm.Options()
    disabledOptions.translationEnabled = false
    let disabledProvider = RecordingProvider()
    let disabledHarness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-disabled"),
        provider: { disabledProvider }
    )
    let disabledStats = await RGSSPrewarm.run(
        environment: disabledHarness.environment, gameRoot: gameRoot, options: disabledOptions
    )
    TAP.eq("prewarm-disabled-reason", "翻译关闭时立即返回", disabledStats.stopReason ?? "", "translation_disabled")
    TAP.eqInt("prewarm-disabled-submitted", "翻译关闭时 0 条入队", disabledStats.submitted, 0)
    TAP.eqInt("prewarm-disabled-scanned", "翻译关闭时连扫描都不做", disabledStats.filesScanned, 0)
    let disabledCalls = await disabledProvider.calls
    TAP.eqInt("prewarm-disabled-requests", "翻译关闭时 0 请求", disabledCalls, 0)
    await disabledHarness.pipeline.cancelAll()

    var zeroOptions = RGSSPrewarm.Options()
    zeroOptions.maxSegments = 0
    let zeroProvider = RecordingProvider()
    let zeroHarness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-zero"),
        provider: { zeroProvider }
    )
    let zeroStats = await RGSSPrewarm.run(
        environment: zeroHarness.environment, gameRoot: gameRoot, options: zeroOptions
    )
    TAP.eq("prewarm-zero-reason", "maxPrewarmSegments=0 时立即返回", zeroStats.stopReason ?? "", "max_segments_zero")
    TAP.eqInt("prewarm-zero-submitted", "0 条入队", zeroStats.submitted, 0)
    await zeroHarness.pipeline.cancelAll()
}

func phasePassthrough(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    var options = RGSSPrewarm.Options()
    options.backend = .passthrough
    let provider = RecordingProvider()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-passthrough"),
        provider: { provider }
    )
    let stats = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: options)
    TAP.eq("prewarm-passthrough-reason", "直通后端时预译直接退出", stats.stopReason ?? "", "passthrough")
    TAP.eqInt("prewarm-passthrough-submitted", "直通时 0 条入队", stats.submitted, 0)
    await harness.pipeline.cancelAll()
    let entries = await harness.cache.stats().entries
    TAP.eqInt("prewarm-passthrough-cache", "直通不写缓存（避免原文自缓存挡路）", entries, 0)
}

/// 规模闸门：maxSegments 到顶即停，并给出截断原因。
func phaseTruncation(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    var options = RGSSPrewarm.Options()
    options.maxSegments = 3
    let provider = RecordingProvider()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-truncate"),
        provider: { provider }
    )
    let stats = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: options)
    TAP.eqInt("prewarm-truncate-selected", "maxSegments=3 时只选 3 条", stats.selected, 3)
    TAP.eqInt("prewarm-truncate-submitted", "只提交 3 条", stats.submitted, 3)
    TAP.ok("prewarm-truncate-flag", "标记为截断并记录原因", stats.truncated && stats.stopReason == "max_segments",
           "truncated=\(stats.truncated) reason=\(stats.stopReason ?? "nil")")
    await harness.pipeline.flush()
    let entries = await harness.cache.stats().entries
    TAP.eqInt("prewarm-truncate-cache", "缓存 3 条", entries, 3)
}

func phaseTroops(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    var options = RGSSPrewarm.Options()
    options.includeTroops = true
    let provider = RecordingProvider()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-troops"),
        provider: { provider }
    )
    let stats = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: options)
    TAP.eqInt("prewarm-troops-texts", "includeTroops=true 时多 1 条", stats.textsScanned, 15)
    await harness.pipeline.flush()
    let texts = await provider.texts
    TAP.ok("prewarm-troops-line", "战斗事件页的 101 文本被预译",
           texts.contains(PrewarmFixture.troopLine))
}

func phaseVxAce(root: URL) async {
    let gameRoot = root.appendingPathComponent("vxace")
    let provider = RecordingProvider()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-vxace"),
        provider: { provider }
    )
    let stats = await RGSSPrewarm.run(environment: harness.environment, gameRoot: gameRoot, options: RGSSPrewarm.Options())
    TAP.eqInt("prewarm-vxace-texts", "VX Ace 逐行：401×2 + 405×1 + 选项×2 = 5", stats.textsScanned, 5)
    TAP.eqInt("prewarm-vxace-submitted", "5 条全部提交", stats.submitted, 5)

    await harness.pipeline.flush()
    let texts = await provider.texts
    TAP.ok("prewarm-vxace-lines", "401/405 逐行，不拼接",
           texts.contains("光る海の向こうへ。")
               && texts.contains("二行目です。")
               && texts.contains("Banjarmachine adalah mesin pembangkit listrik.")
               && texts.contains("はい")
               && texts.contains("いいえ"))
    TAP.ok("prewarm-vxace-no-face", "VX Ace 的 101[0] 头像名不进请求", !texts.contains("Actor1"))
    TAP.ok("prewarm-vxace-no-join", "VX Ace 没有整段拼接的换行文本", !texts.contains(where: { $0.contains("\n") }))
}

/// provider 抛错：run 不抛、缓存不写、进程正常退出（只降级为运行时翻译）。
func phaseProviderFailure(root: URL) async {
    let gameRoot = root.appendingPathComponent("happy")
    let counter = CallCounter()
    let harness = await makePrewarmHarness(
        root: root.appendingPathComponent("run-fail"),
        provider: { FailingProvider(counter: counter) }
    )
    let stats = await RGSSPrewarm.run(
        environment: harness.environment, gameRoot: gameRoot, options: RGSSPrewarm.Options()
    )
    TAP.eqInt("prewarm-fail-submitted", "provider 失败前仍完成入队（9）", stats.submitted, 9)
    var calls = 0
    for _ in 0..<100 {
        calls = await counter.value
        if calls >= 1 { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    TAP.ok("prewarm-fail-called", "provider 确实被调用过", calls >= 1)
    await harness.pipeline.cancelAll()
    let entries = await harness.cache.stats().entries
    TAP.eqInt("prewarm-fail-cache", "失败后缓存仍为空（没有写坏条目）", entries, 0)
}

/// 设置层闸门与 tolerant 默认值。
func phaseSettings() async {
    let missingThree: [String: Any] = [
        "schemaVersion": 2,
        "backendType": "openai",
        "endpoint": "https://example.invalid/v1",
        "model": "test-model",
        "srcLang": "ja",
        "tgtLang": "zh-Hans",
        "agentEnabled": true
    ]
    if let data = try? JSONSerialization.data(withJSONObject: missingThree),
       let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
        TAP.ok("prewarm-settings-default-enabled", "缺键时 prewarmEnabled 默认 true", decoded.prewarmEnabled)
        TAP.eqInt("prewarm-settings-default-max", "缺键时 maxPrewarmSegments 默认 3000",
                  decoded.maxPrewarmSegments, 3000)
        TAP.ok("prewarm-settings-default-troops", "缺键时 prewarmIncludeTroops 默认 false",
               decoded.prewarmIncludeTroops == false)
    } else {
        TAP.ok("prewarm-settings-default-enabled", "缺三键的 JSON 能解码", false)
    }

    var clamped = configuredSettings()
    clamped.maxPrewarmSegments = 99_999
    let high = clamped.normalized().settings
    TAP.eqInt("prewarm-settings-clamp-high", "maxPrewarmSegments 上钳到 20000",
              high.maxPrewarmSegments, 20_000)
    clamped.maxPrewarmSegments = -1
    let low = clamped.normalized().settings
    TAP.eqInt("prewarm-settings-clamp-low", "maxPrewarmSegments 下钳到 0",
              low.maxPrewarmSegments, 0)

    if let data = try? JSONEncoder().encode(configuredSettings()),
       let text = String(data: data, encoding: .utf8),
       let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
        TAP.ok("prewarm-settings-encoded", "新设置字段随 Settings 一起落盘",
               text.contains("prewarmEnabled")
                   && text.contains("maxPrewarmSegments")
                   && text.contains("prewarmIncludeTroops"))
        TAP.eqInt("prewarm-settings-schema", "schemaVersion 仍为 2（不抬高）", decoded.schemaVersion, 2)
    } else {
        TAP.ok("prewarm-settings-encoded", "Settings 编解码往返成功", false)
    }

    // 设置层闸门（SessionController 用同一函数决定要不要建 Task）。
    var gateSettings = configuredSettings()
    TAP.ok("prewarm-gate-run", "正常配置可以预译", RGSSPrewarm.skipReason(settings: gateSettings) == nil)
    gateSettings.prewarmEnabled = false
    TAP.eq("prewarm-gate-disabled", "prewarmEnabled=false → 不跑（0 请求）",
           RGSSPrewarm.skipReason(settings: gateSettings) ?? "", "prewarm_disabled")
    gateSettings = configuredSettings()
    gateSettings.endpoint = ""
    TAP.eq("prewarm-gate-unconfigured", "后端未配置 → 不跑",
           RGSSPrewarm.skipReason(settings: gateSettings) ?? "", "backend_unconfigured")
    gateSettings = configuredSettings()
    gateSettings.backendType = .passthrough
    TAP.eq("prewarm-gate-passthrough", "直通 → 不跑",
           RGSSPrewarm.skipReason(settings: gateSettings) ?? "", "passthrough")
    gateSettings = configuredSettings()
    gateSettings.maxPrewarmSegments = 0
    TAP.eq("prewarm-gate-zero", "上限 0 → 不跑",
           RGSSPrewarm.skipReason(settings: gateSettings) ?? "", "max_segments_zero")

    // Options(settings:) 的映射：maxPrewarmSegments / includeTroops 要真的传下去。
    var mapped = configuredSettings()
    mapped.maxPrewarmSegments = 7
    mapped.prewarmIncludeTroops = true
    let options = RGSSPrewarm.Options(settings: mapped)
    TAP.eqInt("prewarm-options-max", "Options 透传 maxPrewarmSegments", options.maxSegments, 7)
    TAP.ok("prewarm-options-troops", "Options 透传 prewarmIncludeTroops", options.includeTroops == true)
}

/// 日志：扫描/选择/跳过/提交/耗时这些字段必须能被运维看见。
func phaseLog(root: URL) async {
    let logURL = root.appendingPathComponent("run-happy").appendingPathComponent("logs")
    let files = Fs.names(logURL).filter { $0.hasSuffix(".log") }
    let text = files.first.map { Fs.text(logURL.appendingPathComponent($0)) } ?? ""
    TAP.ok("prewarm-log-component", "日志含 RGSSPrewarm 组件与统计字段",
           text.contains("RGSSPrewarm") && text.contains("submitted=") && text.contains("skipped="),
           "log=\(text.suffix(400))")
}

// MARK: - 小工具

private func isNil(_ value: TranslationCache.Entry?) -> Bool { return value == nil }
