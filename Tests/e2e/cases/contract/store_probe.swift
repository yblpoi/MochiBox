//
//  store_probe.swift
//  MochiBox · QA 探针（Store 层：行身份 / 扇出 / occurrences / 淘汰）
//
//  为什么必须单独有这一支：这些语义**只存在于 `TextStreamStore` 里**，
//  `--attach` 的 JSONL 是 CLI 自己写的（每条事件一行），E2E 看不到合并、扇出与计数。
//  工程师的自检也覆盖了一部分，但 `occurrences` 序列与淘汰重算没有独立证据。
//
//  依据：PRD P0-08（行身份 = surface + raw；翻译身份 = cacheKey）+ AC2.2b（5s 内收敛）+ AC3.1
//
//  断言清单：
//   S1  A 组：`350` 与 `\C[2]350` 同帧同 cacheKey → **2 行**（行身份按 raw）
//   S2  B 组：`こんにちは` 与 `\C[2]こんにちは` 同帧同 cacheKey → 2 行；
//       一条 applyTranslation → **两行都 translated**，且 stats.fresh == 1（一次计费）
//   S3  B/401：错误同样扇出 → **两行都 error**，不得一行 error、一行 pending
//   S4  AC3.1（Host 侧）：同一身份 3 条事件（不同帧）→ **3 行**，occurrences **1/2/3**
//   S5  淘汰：插入 5001 条不同身份 → 只留 5000；再插回"最早被淘汰"的身份 →
//       occurrences 必须 **按当前保留行重算 = 1**（不得是 2，不得有持久计数器）
//   S6  clear：清空后 rows=0；再采同一身份 → occurrences 从 1 重新开始
//   S7  同帧同一身份连画 10 次 → **1 行**，occurrences == 1（PRD AC3.1-b：持续可见不重复计数）
//   S8  BUG-11 Host 侧：同 cacheKey 的两行（`\N[1]…` / `\N[2]…`）→ 译文各发**本行**的控制码，
//       次行不得复用首行的 `\N[1]`；两行都 translated（扇出不退化）
//   S9  同 cacheKey 但本行文本段数与译文条数不符 → 该行 **error**（不得 pending、不得画首行码值），
//       能对上的首行仍正常
//   W1  同身份 8×400ms（持续可见）→ 1 行（AC3.1-b）
//   W4a 间隔 700ms（窗内）→ 1 行
//   W5  8×400ms 后再 +100ms 画（续期判别）→ 1 行
//   W6  A/B 交错（都在窗内）→ 2 行
//   R0a ts 不可用（≤0）+ 同帧同身份重复观测 → 1 行，occurrences = 1（严格同帧签名去重）
//   R0b ts 不可用 + 跨帧同身份 → 新行（rows=2，occurrences 1/2）
//   R2  回拨 < -60000ms（时钟基重置）→ 按新行处理（occurrences 1/2）
//   R3  -60000 ≤ 回拨 < 0 → 抑制合并：occurrences 不变、lastSeenTs 不回退
//
//  R0/R2/R3 是欠账 D6 补的三条：规则表（`TextStreamStore.ingest` 注释 R0–R5）里一直有，
//  探针此前零覆盖。**既有 21 条断言的期望值一个都没动。**
//
//  **不验**：Agent 侧 `lookup` 的骨架重组由 `09_lookup_variant.mjs` 负责（C1–C9）；
//  本探针的 S8/S9 只验 **Host 侧同型点**：同一 cacheKey 的多行，译文必须各发本行的控制码。
//
//  编译与运行： node Tests/e2e/cases/contract/11_store.mjs（swiftc 现编现跑，产物在 mkdtemp 目录）
//

import Foundation

@main
struct StoreProbe {

    static func main() async {
        await MainActor.run { runAll() }
        exit(exitCode)
    }

    // MARK: - 计数

    nonisolated(unsafe) static var pass = 0
    nonisolated(unsafe) static var fail = 0
    nonisolated(unsafe) static var total = 0
    static var exitCode: Int32 { fail == 0 ? 0 : 1 }

    /// TAP 13 输出：编号在本进程内自增，`run.mjs` 会把它重新编号进总计划。
    /// 失败时把 `detail` 作为诊断行输出（只能是单行 test 行 + `#   ` 详情）。
    static func check(_ id: String, _ desc: String, _ ok: Bool, _ detail: String) {
        if ok { pass += 1 } else { fail += 1 }
        total += 1
        let label = desc.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        if ok {
            print("ok \(total) - \(id) \(label)")
        } else {
            print("not ok \(total) - \(id) \(label) # 断言不成立")
            for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
                print("#   \(line)")
            }
        }
    }

    // MARK: - 构造事件

    /// `AgentTextPayload` 只有 `init(from:)`，所以按 Agent 的真实 JSON 形状解码。
    /// - Parameter ts: 页面侧 `performance.now()` 的时间戳（毫秒）。**时间间隔一律用它表达**，
    ///   不要用 `frame`：PRD P0-08 明令「不得按帧号分桶」，用 frame 冒充间隔等于给实现发许可证。
    static func payload(raw: String, mapKey: String, frame: Int, ts: Double) -> AgentTextPayload {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {"ts":\(ts),"frame":\(frame),"surface":"Window_Base.drawTextEx","sceneClass":"Scene_Map",\
        "raw":"\(escaped)","segments":[{"kind":"text","value":"\(escaped)"}],\
        "text":"\(escaped)","key":"\(mapKey)"}
        """
        guard let payload = try? JSONDecoder().decode(AgentTextPayload.self, from: Data(json.utf8)) else {
            fatalError("payload 构造失败：\(json)")
        }
        return payload
    }

    @MainActor
    static func ingest(
        _ store: TextStreamStore,
        raw: String,
        cacheKey: String,
        frame: Int,
        ts: Double
    ) {
        store.ingest(
            payload(raw: raw, mapKey: cacheKey, frame: frame, ts: ts),
            cacheKey: cacheKey,
            sessionId: "qa",
            gameId: "qa"
        )
    }

    /// 带**真实骨架**的 payload（BUG-11 用例专用）：`segments` 由调用方给定，
    /// 与 Agent 上报形状一致（`code` 段原样、`text` 段是原文文本）。
    static func payload(
        raw: String,
        segments: [Segment],
        mapKey: String,
        frame: Int,
        ts: Double
    ) -> AgentTextPayload {
        func escape(_ value: String) -> String {
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\u{1F}", with: "\\u001f")
        }
        let segmentsJSON = segments.map { segment in
            let kind = segment.kind == .code ? "code" : "text"
            return "{\"kind\":\"\(kind)\",\"value\":\"\(escape(segment.value))\"}"
        }.joined(separator: ",")
        let text = Segmenter.joinForBackend(segments)
        let json = """
        {"ts":\(ts),"frame":\(frame),"surface":"Window_Base.drawTextEx","sceneClass":"Scene_Map",\
        "raw":"\(escape(raw))","segments":[\(segmentsJSON)],"text":"\(escape(text))","key":"\(escape(mapKey))"}
        """
        guard let payload = try? JSONDecoder().decode(AgentTextPayload.self, from: Data(json.utf8)) else {
            fatalError("payload 构造失败：\(json)")
        }
        return payload
    }

    @MainActor
    static func ingest(
        _ store: TextStreamStore,
        raw: String,
        segments: [Segment],
        cacheKey: String,
        frame: Int,
        ts: Double
    ) {
        store.ingest(
            payload(raw: raw, segments: segments, mapKey: cacheKey, frame: frame, ts: ts),
            cacheKey: cacheKey,
            sessionId: "qa",
            gameId: "qa"
        )
    }

    @MainActor
    static func statuses(_ store: TextStreamStore) -> [String] {
        return store.rows.map { $0.status.rawValue }
    }

    // MARK: - 用例

    @MainActor
    static func runAll() {
        // ---- S1：A 组，行身份按 raw ----
        do {
            let store = TextStreamStore(maxRows: 100)
            ingest(store, raw: "350", cacheKey: "350", frame: 1, ts: 1_000)
            ingest(store, raw: "\\C[2]350", cacheKey: "350", frame: 1, ts: 1_000)
            check("S1", "A 组：350 与 \\C[2]350 同帧同 cacheKey → 2 行",
                  store.rows.count == 2,
                  "rows=\(store.rows.count) raws=\(store.rows.map { $0.raw })")
        }

        // ---- S2：B 组，一次译文扇出到两行，且只计一次 ----
        do {
            let store = TextStreamStore(maxRows: 100)
            ingest(store, raw: "こんにちは", cacheKey: "こんにちは", frame: 2, ts: 2_000)
            ingest(store, raw: "\\C[2]こんにちは", cacheKey: "こんにちは", frame: 2, ts: 2_000)
            let rowsBefore = store.rows.count
            store.applyTranslation(
                cacheKey: "こんにちは",
                translatedRaw: "你好",
                segments: [Segment(kind: .text, value: "你好")],
                backend: .openai,
                latencyMs: 12,
                cached: false
            )
            let allTranslated = store.rows.allSatisfy { $0.status == .translated }
            let oneCharge = store.stats.fresh == 1
            check("S2a", "B 组：こんにちは 与 \\C[2]こんにちは 同帧 → 2 行",
                  rowsBefore == 2, "rows=\(rowsBefore)")
            check("S2b", "一条译文扇出到两行（都 translated，无 pending 残留）",
                  allTranslated, "statuses=\(statuses(store))")
            check("S2c", "一次结果只计一次（stats.fresh == 1，不重复计费）",
                  oneCharge, "fresh=\(store.stats.fresh) hits=\(store.stats.hits)")
        }

        // ---- S3：错误路径也要扇出 ----
        do {
            let store = TextStreamStore(maxRows: 100)
            ingest(store, raw: "こんにちは", cacheKey: "こんにちは", frame: 3, ts: 3_000)
            ingest(store, raw: "\\C[2]こんにちは", cacheKey: "こんにちは", frame: 3, ts: 3_000)
            store.applyError(
                cacheKey: "こんにちは",
                error: ErrorInfo(code: .authFailed, message: "401", retryable: false, httpStatus: 401)
            )
            let allError = store.rows.allSatisfy { $0.status == .error }
            let noPending = store.rows.allSatisfy { $0.status != .pending }
            check("S3", "401 路径两行都进 error，不得留一行 pending",
                  allError && noPending, "statuses=\(statuses(store))")
        }

        // ---- S4：AC3.1 Host 侧，3 次出现 → 3 行 + occurrences 1/2/3 ----
        do {
            let store = TextStreamStore(maxRows: 100)
            // AC3.1-a：判据是「距上次绘制 > 800ms」，故用 ts 表达（2000ms 间隔），
            // 不是"帧号不同"—— 帧号不是 PRD 认可的去重依据（P0-08：不得按帧号分桶）。
            for step in 0..<3 {
                ingest(store, raw: "おはよう", cacheKey: "おはよう",
                       frame: 10 + step, ts: 10_000 + Double(step) * 2_000)
            }
            let occurrences = store.rows.map { $0.occurrences }
            check("S4", "同一身份 3 条事件（间隔 2000ms > 800ms）→ 3 行，occurrences 1/2/3",
                  store.rows.count == 3 && occurrences == [1, 2, 3],
                  "rows=\(store.rows.count) occurrences=\(occurrences)")
        }

        // ---- S5：淘汰后 occurrences 按保留行重算 ----
        do {
            let store = TextStreamStore(maxRows: 5000)
            for index in 0..<5001 {
                ingest(store, raw: "line-\(index)", cacheKey: "line-\(index)", frame: 100 + index, ts: Double(100 + index) * 1_000)
            }
            let retained = store.rows.count
            let firstEvicted = store.rows.first?.raw ?? ""
            // 再采一次"最早被淘汰"的那条身份
            ingest(store, raw: "line-0", cacheKey: "line-0", frame: 9000, ts: 9_000_000)
            let last = store.rows.last
            check("S5a", "插入 5001 条 → 只保留 5000 行",
                  retained == 5000, "rows=\(retained)")
            check("S5b", "重新出现被淘汰的身份 → occurrences 按保留行重算 = 1（不得为 2）",
                  last?.occurrences == 1,
                  "occurrences=\(String(describing: last?.occurrences)) evictedFirst=\(firstEvicted)")
        }

        // ---- S6：clear 后计数从 1 重来 ----
        do {
            let store = TextStreamStore(maxRows: 100)
            ingest(store, raw: "またね", cacheKey: "またね", frame: 20, ts: 20_000)
            ingest(store, raw: "またね", cacheKey: "またね", frame: 21, ts: 21_000)
            let beforeClear = store.rows.map { $0.occurrences }
            store.clear()
            let emptyAfterClear = store.rows.isEmpty
            ingest(store, raw: "またね", cacheKey: "またね", frame: 22, ts: 22_000)
            check("S6", "clear 后 rows=0，再采同一身份 occurrences 从 1 开始",
                  emptyAfterClear && store.rows.last?.occurrences == 1,
                  "beforeClear=\(beforeClear) afterClearRows=\(store.rows.count) occ=\(String(describing: store.rows.last?.occurrences))")
        }

        // ---- S7：同帧同一身份连画 10 次 → 1 行、occurrences=10 ----
        do {
            let store = TextStreamStore(maxRows: 100)
            for _ in 0..<10 {
                // 同一帧、同一时刻连画 10 次：这是"持续可见"的极端形态
                ingest(store, raw: "テスト", cacheKey: "テスト", frame: 30, ts: 30_000)
            }
            let occurrences = store.rows.map { $0.occurrences }
            // 期望值来源：PRD AC3.1-b（第 91 行）+ §5.2（第 383 行）——
            // 「持续可见期间的重复重绘不计入，occurrences 保持 1」。
            // 旧版这里写 occurrences == 10，是照抄 `TextStreamStore.swift:68` 的实现注释，
            // 属于"把实现当规范"（架构 R10）：同一现象在 Agent 侧会被 800ms 窗口压成 1 条，
            // 到了 Store 侧若按"每收一条 +1"，同一句就会永远显示成 10。
            check("S7", "同帧同一身份连画 10 次（Agent 不会发出的形态）→ 1 行且 occurrences=1（PRD AC3.1-b）",
                  store.rows.count == 1 && occurrences == [1],
                  "rows=\(store.rows.count) occurrences=\(occurrences)")
        }

        // ---- W 组：Store 层的时间窗口（期望值全部按 PRD AC3.1 a/b）
        // 注意：产品路径上 800ms 窗口由 Agent 保证，Store 只"收事件、找行、更新"。
        // v0.4 起这里不再有歧义（OBS-1 决策已做）：Store 自保窗口是**设计要求**，
        // 期望值来自 AC3.1 a/b，与 Agent 侧 `shouldEmitFor`（`Resources/agent_mvmz.js:510-529`）
        // 以及 `dedupe_race_probe.mjs` 的 A1–A7 **同构**。理由：`--attach` 可附着到别人已经
        // 开着的页面（Agent 可能是旧版本），且 Agent 的 `lastEmitAt` 在 `DEDUPE_CAP` 命中时
        // 会整体清空 —— 只靠页面侧自保，同一句就会被 Store 写成 10 行（S7 的旧红点）。
        // 期望值一个都不许动：动了就等于放宽 AC3.1。
        do {
            // W1：同身份 8×400ms（每次间隔 < 800ms）→ 期望 1 行（AC3.1-b）
            let store = TextStreamStore(maxRows: 100)
            for step in 0..<8 {
                ingest(store, raw: "W1", cacheKey: "W1",
                       frame: 40 + step, ts: 40_000 + Double(step) * 400)
            }
            check("W1", "Store：同身份 8×400ms（持续可见）→ 1 行（AC3.1-b）",
                  store.rows.count == 1, "rows=\(store.rows.count)")

            // W4a：间隔 700ms（窗内）→ 期望 1 行
            let store2 = TextStreamStore(maxRows: 100)
            ingest(store2, raw: "W4a", cacheKey: "W4a", frame: 50, ts: 50_000)
            ingest(store2, raw: "W4a", cacheKey: "W4a", frame: 51, ts: 50_700)
            check("W4a", "Store：间隔 700ms（窗内）→ 1 行",
                  store2.rows.count == 1, "rows=\(store2.rows.count)")

            // W5：8×400ms 后 +100ms 再画（续期判别）→ 期望 1 行
            let store3 = TextStreamStore(maxRows: 100)
            for step in 0..<8 {
                ingest(store3, raw: "W5", cacheKey: "W5",
                       frame: 60 + step, ts: 60_000 + Double(step) * 400)
            }
            ingest(store3, raw: "W5", cacheKey: "W5", frame: 68, ts: 60_000 + 7 * 400 + 100)
            check("W5", "Store：8×400ms 后 +100ms 再画（续期）→ 1 行",
                  store3.rows.count == 1, "rows=\(store3.rows.count)")

            // W6：A/B 交错、都在窗内 → 期望 2 行（A、B 各 1）
            let store4 = TextStreamStore(maxRows: 100)
            ingest(store4, raw: "A", cacheKey: "A", frame: 70, ts: 70_000)
            ingest(store4, raw: "B", cacheKey: "B", frame: 71, ts: 70_100)
            ingest(store4, raw: "A", cacheKey: "A", frame: 72, ts: 70_200)
            ingest(store4, raw: "B", cacheKey: "B", frame: 73, ts: 70_300)
            let raws = store4.rows.map { $0.raw }
            check("W6", "Store：A/B 交错（窗内）→ 2 行（A、B 各 1）",
                  raws == ["A", "B"], "rows=\(raws.count) raws=\(raws)")
        }

        // ---- R 组：R0 / R2 / R3（欠账 D6 —— 规则表里一直有、探针里一直没覆盖的三条）----
        //
        // 期望值的唯一来源是 `TextStreamStore.ingest` 的 R0–R5 规则表（架构 v0.4 §6.3，
        // 与 `Resources/agent_mvmz.js:510-529` 的 `shouldEmitFor` 同构），**不是**实现的行为：
        // 这三条此前零覆盖，写断言时按规则表推期望，再跑实现去对。
        do {
            // R0a：`ts` 不可用（非有限 / ≤0）→ 降级为**严格同帧签名去重**。
            // 同帧 + 同身份重复观测 → 1 行，`occurrences` 保持 1，且窗口基准不被写成 0。
            // 为什么允许"退化"：MZ 某些绘制路径拿不到 `performance.now()`；把 ts=0 当
            // "很久以前"会每帧新增一行，当"刚刚"又永远吞掉同一句 —— 只认"同帧同身份"这一种形态。
            let storeR0 = TextStreamStore(maxRows: 100)
            ingest(storeR0, raw: "R0", cacheKey: "R0", frame: 500, ts: 0)
            ingest(storeR0, raw: "R0", cacheKey: "R0", frame: 500, ts: 0)
            let r0Occurrences = storeR0.rows.map { $0.occurrences }
            check("R0a", "ts 不可用 + 同帧同身份重复观测 → 1 行且 occurrences=1（严格同帧签名去重）",
                  storeR0.rows.count == 1 && r0Occurrences == [1],
                  "rows=\(storeR0.rows.count) occurrences=\(r0Occurrences)")

            // R0b：同身份但**跨帧** → 算新行（同帧签名不再相同）。
            // 这一条是 R0a 的反面：退化路径不能退成"ts 不可用就一律吞掉"。
            ingest(storeR0, raw: "R0", cacheKey: "R0", frame: 501, ts: 0)
            let r0bOccurrences = storeR0.rows.map { $0.occurrences }
            check("R0b", "ts 不可用 + 跨帧同身份 → 新行（rows=2，occurrences 1/2）",
                  storeR0.rows.count == 2 && r0bOccurrences == [1, 2],
                  "rows=\(storeR0.rows.count) occurrences=\(r0bOccurrences)")

            // R2：`delta < -60000` → 时钟基重置（页面 reload 后 `performance.now()` 归零）→ 按新行处理。
            // 若当成"窗内"，reload 后第一句会被并进 reload 前的行 —— 那是**丢句**。
            let storeR2 = TextStreamStore(maxRows: 100)
            ingest(storeR2, raw: "R2", cacheKey: "R2", frame: 600, ts: 100_000)
            ingest(storeR2, raw: "R2", cacheKey: "R2", frame: 601, ts: 10_000)   // delta = -90_000
            let r2Occurrences = storeR2.rows.map { $0.occurrences }
            check("R2", "回拨 90000ms（< -60000）→ 时钟基重置，按新行处理（rows=2，occurrences 1/2）",
                  storeR2.rows.count == 2 && r2Occurrences == [1, 2]
                      && storeR2.rows.last?.lastSeenTs == 10_000,
                  "rows=\(storeR2.rows.count) occurrences=\(r2Occurrences)"
                      + " lastSeenTs=\(String(describing: storeR2.rows.last?.lastSeenTs))")

            // R3：`-60000 ≤ delta < 0` → 夹到 0 → 抑制合并。
            // 两个不许动的量：`occurrences`（不新增一次出现）与 `lastSeenTs`（不回退：
            // 把窗口基准往回改，真墙钟时间会被系统性地拉短，后续每次都判成"窗外"）。
            let storeR3 = TextStreamStore(maxRows: 100)
            ingest(storeR3, raw: "R3", cacheKey: "R3", frame: 700, ts: 100_000)
            ingest(storeR3, raw: "R3", cacheKey: "R3", frame: 701, ts: 90_000)   // delta = -10_000
            let r3Occurrences = storeR3.rows.map { $0.occurrences }
            check("R3", "回拨 10000ms（-60000 ≤ delta < 0）→ 抑制合并，occurrences 不变、lastSeenTs 不回退",
                  storeR3.rows.count == 1 && r3Occurrences == [1]
                      && storeR3.rows.first?.lastSeenTs == 100_000,
                  "rows=\(storeR3.rows.count) occurrences=\(r3Occurrences)"
                      + " lastSeenTs=\(String(describing: storeR3.rows.first?.lastSeenTs))")
        }

        // ---- S8：BUG-11 Host 侧——同 cacheKey 不同控制码，译文必须各发本行的码 ----
        do {
            let store = TextStreamStore(maxRows: 100)
            ingest(store, raw: "\\N[1]は元気",
                   segments: [Segment(kind: .code, value: "\\N[1]"), Segment(kind: .text, value: "は元気")],
                   cacheKey: "nk", frame: 80, ts: 80_000)
            ingest(store, raw: "\\N[2]は元気",
                   segments: [Segment(kind: .code, value: "\\N[2]"), Segment(kind: .text, value: "は元気")],
                   cacheKey: "nk", frame: 80, ts: 80_000)
            store.applyTranslation(
                cacheKey: "nk",
                translatedRaw: "\\N[1]你好",
                segments: [Segment(kind: .code, value: "\\N[1]"), Segment(kind: .text, value: "你好")],
                backend: .openai,
                latencyMs: 5,
                cached: false
            )
            let first = store.rows[0].translated
            let second = store.rows[1].translated
            check("S8a", "首行保留自己的 \\N[1]（不得被改写）",
                  first == "\\N[1]你好", "translated=\(String(describing: first))")
            check("S8b", "次行必须用自己的 \\N[2]，不得复用首行的 \\N[1]",
                  second == "\\N[2]你好", "translated=\(String(describing: second))")
            check("S8c", "两行都 translated（扇出仍然生效，不退化成一等一）",
                  store.rows.allSatisfy { $0.status == .translated }, "statuses=\(statuses(store))")
            check("S8d", "translatedSegments 与显示串同源（都按本行骨架）",
                  store.rows[1].translatedSegments == [Segment(kind: .code, value: "\\N[2]"), Segment(kind: .text, value: "你好")],
                  "segments=\(String(describing: store.rows[1].translatedSegments))")
        }

        // ---- S9：段数不符 → 落 error，绝不把首行码值画到次行（宁画原文/不译） ----
        do {
            let store = TextStreamStore(maxRows: 100)
            // 病态构造：首行两个文本段，次行正文里真带 U+001F（一个文本段），mapKey 却相同。
            ingest(store, raw: "\\N[1]は\u{1F}元気",
                   segments: [Segment(kind: .code, value: "\\N[1]"), Segment(kind: .text, value: "は"), Segment(kind: .text, value: "元気")],
                   cacheKey: "nk2", frame: 81, ts: 81_000)
            ingest(store, raw: "\\N[2]は\u{1F}元気",
                   segments: [Segment(kind: .code, value: "\\N[2]"), Segment(kind: .text, value: "は\u{1F}元気")],
                   cacheKey: "nk2", frame: 81, ts: 81_000)
            store.applyTranslation(
                cacheKey: "nk2",
                translatedRaw: "\\N[1]你好",
                segments: [Segment(kind: .code, value: "\\N[1]"), Segment(kind: .text, value: "你"), Segment(kind: .text, value: "好")],
                backend: .openai,
                latencyMs: 5,
                cached: false
            )
            let second = store.rows[1]
            check("S9a", "段数不符的次行落 error（不得静默 pending）",
                  second.status == .error, "status=\(second.status.rawValue) err=\(String(describing: second.error?.code))")
            check("S9b", "次行不得出现首行码值 \\N[1]（不串人名）",
                  second.translated == nil, "translated=\(String(describing: second.translated))")
            check("S9c", "首行仍正常（本行骨架能对上）",
                  store.rows[0].translated == "\\N[1]你好",
                  "translated=\(String(describing: store.rows[0].translated))")
        }

        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
    }
}
