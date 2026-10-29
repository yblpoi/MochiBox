//
//  probe_fulltext.swift
//  MochiBox · E2E 领域层探针（全文翻译导出/导入 AC-10.3 / AC-10.4）
//
//  用 --only D8 跑。依据：docs/prd.md §3.4 AC-10.3/AC-10.4；
//  Sources/Infra/FullTextStore.swift:150-250（exportManual / importManual /
//  exportToGameDirectory）；Sources/Domain/FullTextModels.swift:23-35（FullTextConfig）。
//
//  关键口径：
//   · ManualTransFile.json 是 MTool 的纯 {原文: 译文} 对象（§4.4）——不带 version/entries 外壳；
//   · 「原文 == 译文」视为未译（§4.5），不计入 accepted；
//   · 导出用 JSONEncoder.sortedKeys，同一内容两次导出必须逐字节相同（否则 diff 不可用）；
//   · 全部文件都写在 --work 的临时目录里，**不碰** Fixtures/e2e_game（那是 D9 的被测对象）。
//

import Foundation

@main
struct DomainFullTextProbe {
    static func main() {
        let args = ProbeArgs()
        switch args.only {
        case "D8": d8(args)
        case "D18": d18()
        case "D20": d20()
        default: TAP.ok("probe", "未知 --only 参数", false, "only=\(args.only)")
        }
        exit(TAP.finish())
    }

    static func entries() -> [FullTextEntry] {
        return [
            FullTextEntry(raw: "こんにちは", source: "runtime", path: "map.1", translated: "你好", origin: .machine),
            FullTextEntry(raw: "\\C[2]さようなら", source: "runtime", path: "map.2", translated: "\\C[2]再见", origin: .manual),
            FullTextEntry(raw: "ありがとう", source: "item", path: "items.7.name", translated: nil, origin: .machine),
            FullTextEntry(raw: "おはよう", source: "actor", path: "actors.3.name", translated: nil, origin: .machine),
            FullTextEntry(raw: "またね", source: "map", path: "map.9", translated: nil, origin: .machine)
        ]
    }

    static func untranslatedCount(_ entries: [FullTextEntry]) -> Int {
        return entries.filter { ($0.translated ?? "").isEmpty }.count
    }

    // MARK: - D20 一轮翻译的收尾判定

    /// 最终验收现场：整轮 0 条新增、N 条失败，界面却是绿色「已完成」，
    /// 原因（finish_reason=length / 调大最大输出 tokens）只写在日志里。
    /// 收尾判定必须是纯函数，四种形状逐一钉住。
    static func d20() {
        let nothing = FullTextOutcome.summary(
            translatedThisRun: 0,
            failedCount: 3,
            firstMessage: "模型返回空内容（finish_reason=length）：输出被截断"
        )
        TAP.eq("D20", "0 新增 + 有失败 → 阶段必须是 failed（不能报「已完成」）",
               nothing.phase.rawValue, "failed")
        TAP.ok("D20", "错误文案说明本轮没有任何新增",
               nothing.error?.contains("本轮没有任何新增译文，失败 3 条") == true, nothing.error ?? "-")
        TAP.ok("D20", "错误文案带第一条失败的具体原因（finish_reason/token 预算）",
               nothing.error?.contains("finish_reason=length") == true, nothing.error ?? "-")
        TAP.ok("D20", "0 新增时不写 notice（原因由 lastError 承担）",
               nothing.notice.isEmpty, nothing.notice)

        let partial = FullTextOutcome.summary(
            translatedThisRun: 12,
            failedCount: 2,
            firstMessage: "译文条数不匹配：后端返回 7 条，期望 8 条"
        )
        TAP.eq("D20", "有新增 + 有失败 → 阶段仍是 done（部分成功不是失败）",
               partial.phase.rawValue, "done")
        TAP.ok("D20", "notice 同时给出新增数、失败数与原因",
               partial.notice.contains("本轮新增 12 条，失败 2 条")
                && partial.notice.contains("译文条数不匹配"), partial.notice)
        TAP.ok("D20", "部分成功不置 lastError（红色横幅会让整轮看起来全灭）",
               partial.error == nil, partial.error ?? "-")

        let clean = FullTextOutcome.summary(translatedThisRun: 8, failedCount: 0, firstMessage: "不应出现")
        TAP.eq("D20", "全成功 → done", clean.phase.rawValue, "done")
        TAP.ok("D20", "全成功不打扰用户（notice / error 都为空）",
               clean.notice.isEmpty && clean.error == nil, "notice=\(clean.notice) error=\(clean.error ?? "-")")

        let silent = FullTextOutcome.summary(translatedThisRun: 0, failedCount: 1, firstMessage: nil)
        TAP.ok("D20", "失败但没有 message 时也必须给出可读原因",
               silent.error?.contains("没有返回可读的错误信息") == true, silent.error ?? "-")
    }

    static func d8(_ args: ProbeArgs) {
        let root = args.root
        // 不预先建目录：0700 断言验的是 FullTextStore 首次创建目录的那条路径。
        // （目录已存在时实现不会收紧权限 —— 见报告 F-4，不在此断言为正确。）
        let dir = root.appendingPathComponent("fulltext", isDirectory: true)
        let store = FullTextStore(directory: dir, gameHash: "gamehash01")

        // ① 导出用的字典：只含已译条目
        let corpus = entries()
        let manual = FullTextStore.manualDictionary(from: corpus)
        let rawKeys = manual.keys.sorted()
        TAP.eqInt("D8", "manualDictionary 只导出已译条目（5 条语料 → 2 条）", manual.count, 2)
        TAP.eq("D8", "导出键集合 = 已译原文（逐条）", rawKeys.joined(separator: "|"),
               "\\C[2]さようなら|こんにちは")
        TAP.eq("D8", "导出值 = 译文整串（含控制码）", manual["\\C[2]さようなら"] ?? "-", "\\C[2]再见")

        // ② 落盘形态：MTool 的纯 {原文:译文}，没有外壳键
        let destination = root.appendingPathComponent("ManualTransFile.json")
        do {
            try store.exportManual(manual, to: destination)
            TAP.ok("D8", "exportManual 产出 ManualTransFile.json", FileManager.default.fileExists(atPath: destination.path))
        } catch {
            TAP.ok("D8", "exportManual 产出 ManualTransFile.json", false, "\(error)")
        }
        let bytes = FileIO.readData(destination) ?? Data()
        let text = String(decoding: bytes, as: UTF8.self)
        let parsed = Fs.json(destination)
        TAP.ok("D8", "导出文件是合法 JSON 对象", parsed != nil)
        TAP.eqInt("D8", "顶层键数 = 2（没有 version/entries 之类外壳）", parsed?.count ?? -1, 2)
        TAP.eq("D8", "顶层键就是原文", ((parsed?.keys.map { $0 } ?? []).sorted()).joined(separator: "|"),
               "\\C[2]さようなら|こんにちは")
        TAP.eq("D8", "导出值逐条等于译文", (parsed?["こんにちは"] as? String) ?? "-", "你好")
        TAP.ok("D8", "导出文件是 UTF-8 原文（CJK 未被转义成 \\uXXXX）",
               text.contains("こんにちは") && !text.contains("\\u3053"), text.prefix(80).description)
        TAP.eqInt("D8", "导出文件权限 0644（用户文件，非 0600）", Fs.mode(destination), 0o644)

        // 同一内容两次导出必须逐字节相同（sortedKeys 确定性；否则导出 diff 不可用）
        let destination2 = root.appendingPathComponent("ManualTransFile-2.json")
        try? store.exportManual(manual, to: destination2)
        let bytes2 = FileIO.readData(destination2) ?? Data()
        TAP.ok("D8", "同一内容两次导出逐字节相同（键序确定）", bytes == bytes2,
               "第一次 \(bytes.count) 字节，第二次 \(bytes2.count) 字节")

        // ③ 往返：导出 → 导入，映射逐条相等（AC-10.3）
        do {
            let round = try store.importManual(from: destination, existing: [:])
            TAP.eqInt("D8", "往返导入 accepted = 2", round.result.accepted, 2)
            TAP.eqInt("D8", "往返导入 untranslated = 0", round.result.untranslated, 0)
            TAP.eqInt("D8", "往返导入 conflicts = 0（现有为空）", round.result.conflicts, 0)
            TAP.ok("D8", "往返后译文映射逐条相等（diff 为空）", round.entries == manual,
                   "导入 \(round.entries.count) 条，导出 \(manual.count) 条")
        } catch {
            TAP.ok("D8", "往返导入不应抛错", false, "\(error)")
        }

        // ④ MTool 人工译文导入：未译条数必须严格下降（AC-10.4）
        let before = untranslatedCount(corpus)
        let incoming: [String: String] = [
            "ありがとう": "谢谢",
            "おはよう": "早上好",
            "またね": "またね",          // 原文 == 译文 → 视为未译
            "さよなら": ""                 // 空译文 → 视为未译
        ]
        let incomingURL = root.appendingPathComponent("ManualTransFile.incoming.json")
        Fs.write((try? String(data: FileIO.encoder.encode(incoming), encoding: .utf8)) ?? "{}", to: incomingURL)
        do {
            let imported = try store.importManual(from: incomingURL, existing: manual)
            TAP.eqInt("D8", "导入 4 对：accepted = 2", imported.result.accepted, 2)
            TAP.eqInt("D8", "导入 4 对：total = 4", imported.result.total, 4)
            TAP.eqInt("D8", "导入 4 对：untranslated = 2（原文==译文 + 空译文）", imported.result.untranslated, 2)
            TAP.eqInt("D8", "导入 4 对：conflicts = 0（新旧不同才算覆盖）", imported.result.conflicts, 0)

            var merged = corpus
            for index in merged.indices {
                if let translated = imported.entries[merged[index].raw] {
                    merged[index].translated = translated
                    merged[index].origin = .manual
                }
            }
            let after = untranslatedCount(merged)
            TAP.eqInt("D8", "导入前未译条数 = 3", before, 3)
            TAP.eqInt("D8", "导入后未译条数 = 1（严格下降）", after, 1)
            TAP.ok("D8", "未译条数严格下降（3 → 1，AC-10.4）", after < before, "before=\(before) after=\(after)")
            TAP.eq("D8", "被覆盖的条目 origin 变为 manual", merged.first { $0.raw == "ありがとう" }?.origin.rawValue ?? "-", "manual")
        } catch {
            TAP.ok("D8", "人工译文导入不应抛错", false, "\(error)")
        }

        // 冲突计数：已有旧译文且新值不同
        let conflictIn: [String: String] = ["こんにちは": "您好"]
        let conflictURL = root.appendingPathComponent("conflict.json")
        Fs.write((try? String(data: FileIO.encoder.encode(conflictIn), encoding: .utf8)) ?? "{}", to: conflictURL)
        if let conflict = try? store.importManual(from: conflictURL, existing: manual) {
            TAP.eqInt("D8", "新旧译文不同 → conflicts = 1", conflict.result.conflicts, 1)
            TAP.eq("D8", "冲突时采用导入值（人工译文优先）", conflict.entries["こんにちは"] ?? "-", "您好")
        } else {
            TAP.ok("D8", "冲突导入不应抛错", false)
        }

        // ⑤ 显式导出到游戏目录（§4.4）：文件名固定 + 已存在时留 .bak
        let gameRoot = root.appendingPathComponent("fake-game", isDirectory: true)
        Fs.make(gameRoot)
        let oldTarget = gameRoot.appendingPathComponent("ManualTransFile.json")
        Fs.write("{\"旧\":\"旧译\"}", to: oldTarget)
        do {
            let target = try store.exportToGameDirectory(manual, gameRoot: gameRoot)
            TAP.eq("D8", "导出到游戏目录的文件名固定为 ManualTransFile.json",
                   target.lastPathComponent, FullTextConfig.manualFileName)
            let backup = target.appendingPathExtension("bak")
            TAP.ok("D8", "已存在旧文件时生成 .bak 备份", FileManager.default.fileExists(atPath: backup.path))
            TAP.eq("D8", ".bak 保留旧内容", Fs.text(backup), "{\"旧\":\"旧译\"}")
            let exported = (try? FileIO.decoder.decode([String: String].self, from: FileIO.readData(target) ?? Data())) ?? [:]
            TAP.ok("D8", "导出到游戏目录的内容 = 导出字典（逐条）", exported == manual,
                   "导出 \(exported.count) 条，期望 \(manual.count) 条")
        } catch {
            TAP.ok("D8", "exportToGameDirectory 不应抛错", false, "\(error)")
        }

        // ⑥ 落盘形态：fulltext/<gameHash>.json（0600、目录 0700）
        var file = FullTextFile(gameHash: "gamehash01", entries: manual)
        file.segments = ["こんにちは": [Segment(kind: .text, value: "こんにちは")]]
        do {
            try store.save(file)
            TAP.ok("D8", "fulltext/<gameHash>.json 已写入", FileManager.default.fileExists(atPath: store.url.path))
            TAP.eq("D8", "全文译文文件名 = <gameHash>.json", store.url.lastPathComponent, "gamehash01.json")
            TAP.eqInt("D8", "全文译文文件权限 0600", Fs.mode(store.url), 0o600)
            TAP.eqInt("D8", "fulltext 目录权限 0700", Fs.mode(dir), 0o700)
            if let loaded = store.load() {
                TAP.ok("D8", "save → load 后 entries 逐条相等", loaded.entries == manual,
                       "loaded=\(loaded.entries.count) 期望=\(manual.count)")
                TAP.ok("D8", "load 后 updatedAt 是 ISO8601 毫秒串",
                       loaded.updatedAt.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T", options: .regularExpression) != nil,
                       loaded.updatedAt)
                TAP.ok("D8", "load 后 segments 附加字段保留",
                       loaded.segments?["こんにちは"]?.first?.value == "こんにちは")
            } else {
                TAP.ok("D8", "save → load 应返回文件", false)
            }
        } catch {
            TAP.ok("D8", "FullTextStore.save 不应抛错", false, "\(error)")
        }

        // ⑦ 空原文/空译文在 load 时被清理
        var dirty = file
        dirty.entries = ["": "空键", "空值": "", "正常": "正常译"]
        try? store.save(dirty)
        let cleaned = store.load()
        TAP.eqInt("D8", "load 过滤空原文与空译文（3 条脏数据 → 1 条）", cleaned?.entries.count ?? -1, 1)
        TAP.eq("D8", "过滤后只留有效条目", cleaned?.entries.keys.sorted().joined(separator: ",") ?? "-", "正常")

        // ⑧ 损坏文件：不阻塞启动，隔离为 .corrupt-<ts>
        Fs.write("{ broken", to: store.url)
        let corrupt = store.load()
        TAP.ok("D8", "全文译文文件损坏 → load 返回 nil（不抛错）", corrupt == nil)
        let quarantined = Fs.names(dir).filter { $0.contains(".corrupt-") }
        TAP.eqInt("D8", "损坏文件被隔离为 1 个 *.corrupt-<ts>", quarantined.count, 1)
        if let name = quarantined.first {
            TAP.ok("D8", "隔离文件名带 yyyyMMdd-HHmmss 时间戳",
                   name.range(of: "^gamehash01\\.json\\.corrupt-[0-9]{8}-[0-9]{6}$", options: .regularExpression) != nil,
                   name)
        }

        // ⑧b 同秒连续两次损坏：每次都要留下独立证据。旧实现先 removeItem 再
        // moveItem，备份名只到秒 —— 同秒第二份会把第一份删掉。
        let rapidDir = root.appendingPathComponent("fulltext-rapid", isDirectory: true)
        Fs.make(rapidDir)
        let rapidStore = FullTextStore(directory: rapidDir, gameHash: "gamehash03")
        Fs.write("{ rapid-A", to: rapidStore.url)
        TAP.ok("D8", "同秒损坏 #1 → load 返回 nil", rapidStore.load() == nil)
        Fs.write("{ rapid-B", to: rapidStore.url)
        TAP.ok("D8", "同秒损坏 #2 → load 返回 nil", rapidStore.load() == nil)
        let rapidBackups = Fs.names(rapidDir).filter { $0.contains(".corrupt-") }
        TAP.eqInt("D8", "同秒连续两次损坏 → 留 2 份隔离文件（不覆盖）", rapidBackups.count, 2)
        let rapidContents = Set(rapidBackups.compactMap { name -> String? in
            FileIO.readData(rapidDir.appendingPathComponent(name)).flatMap { String(data: $0, encoding: .utf8) }
        })
        TAP.eq("D8", "两份隔离文件内容分别是 A/B（第一份未被覆盖）",
               rapidContents.sorted().joined(separator: "|"), "{ rapid-A|{ rapid-B")

        // ⑩ 目录已存在（旧版本/其它工具建的 0755）时也要收紧到 0700
        let legacyDir = root.appendingPathComponent("fulltext-legacy", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyDir.path)
        TAP.eqInt("D8", "前置：目录已存在且权限 0755", Fs.mode(legacyDir), 0o755)
        let legacyStore = FullTextStore(directory: legacyDir, gameHash: "gamehash02")
        try? legacyStore.save(FullTextFile(gameHash: "gamehash02", entries: ["a": "b"]))
        TAP.eqInt("D8", "目录已存在时 save 仍收紧到 0700", Fs.mode(legacyDir), 0o700)

        // ⑨ 文件缺失：返回 nil（首启不崩）
        let absent = FullTextStore(directory: root.appendingPathComponent("absent", isDirectory: true), gameHash: "none")
        TAP.ok("D8", "全文译文文件不存在 → load 返回 nil", absent.load() == nil)

        // ⑪ 语料清理：熔断降级写进来的"译文 == 原文"必须能识别并清除。
        // 旧版本在熔断期把原文当译文回填，文件里 7000+ 条的 translated 等于 raw、
        // origin 是 machine/cache —— 不清理的话重跑全文翻译会因为"已译"直接跳过。
        var polluted = FullTextCorpus()
        polluted.mergePersisted(
            entries: [
                "こんにちは": "こんにちは",
                "おはよう": "おはよう",
                "HP": "HP",
                "ありがとう": "谢谢"
            ],
            segments: nil,
            origins: [
                "こんにちは": "machine",
                "おはよう": "cache",
                "HP": "manual",
                "ありがとう": "machine"
            ]
        )
        let purged = polluted.purgePassthroughMachineTranslations()
        TAP.eqInt("D8", "清理只命中 machine/cache 且 translated == raw 的 2 条", purged, 2)
        TAP.ok("D8", "machine 假译文回到未译", polluted.entry(for: "こんにちは")?.isTranslated == false)
        TAP.ok("D8", "cache 假译文回到未译", polluted.entry(for: "おはよう")?.isTranslated == false)
        TAP.ok("D8", "人工条目原样保留（HP == HP 是合法恒等）",
               polluted.entry(for: "HP")?.translated == "HP")
        TAP.ok("D8", "正常机翻不受清理影响", polluted.entry(for: "ありがとう")?.translated == "谢谢")
        TAP.eqInt("D8", "清理后条目仍在语料里（只清译文，不删条目）", polluted.count, 4)
        TAP.ok("D8", "清理同时清空 segments 与 issues",
               polluted.entry(for: "こんにちは")?.segments == nil
                   && (polluted.entry(for: "こんにちは")?.issues.isEmpty ?? false))
        TAP.eqInt("D8", "清理后已译数只剩人工与正常机翻", polluted.translatedCount, 2)
    }

    // MARK: - D18 名称一致性

    /// 名称一致性（docs 计划 §4）：怪物名在名称字段是 A、在同批台词里被模型译成 B。
    /// 根因之一是「名称与引用句混批」，之二是「术语只是软提示、违例只标不修」。
    /// 这里只钉两件可纯函数验证的事实：违例能定位到**具体术语对**、取批**不跨 rank**。
    static func d18() {
        d18Violations()
        d18WorkOrder()
        d18Corpus()
        d18Prompt()
    }

    /// `beginRepair` 的契约：只清译文/分段/issue，**保留 origin 与 profile**。
    /// 这层保护是「自动重译不丢数据」的前提：resetTranslation 会把 origin 打成 machine、
    /// 把 profile 清空，人工译文也会被顺带覆盖。
    static func d18Corpus() {
        var corpus = FullTextCorpus()
        corpus.insert(raw: "噛みつきクラゲ", source: "enemy", path: "enemies.3.name")
        corpus.applyTranslation(
            raw: "噛みつきクラゲ",
            translated: "刺人水母",
            segments: [Segment(kind: .text, value: "刺人水母")],
            origin: .cache,
            profile: "p2|c:entityName|g:abc123",
            issues: [QualityIssue.glossaryViolation.rawValue]
        )
        TAP.eqInt("D18", "前置：条目已译且带违例", corpus.translatedCount, 1)

        corpus.beginRepair(raw: "噛みつきクラゲ")
        let entry = corpus.entry(for: "噛みつきクラゲ")
        TAP.ok("D18", "beginRepair 清掉译文", entry?.isTranslated == false)
        TAP.ok("D18", "beginRepair 清掉分段与 issue",
               (entry?.segments == nil) && (entry?.issues.isEmpty ?? false))
        TAP.eq("D18", "beginRepair 保留 origin（不被打成 machine）", entry?.origin.rawValue ?? "-", "cache")
        TAP.eq("D18", "beginRepair 保留 profile", entry?.profile ?? "-", "p2|c:entityName|g:abc123")

        // 对照：resetTranslation 会改写 origin/profile（所以修复路径不能用它）。
        corpus.applyTranslation(
            raw: "噛みつきクラゲ",
            translated: "刺人水母",
            segments: [Segment(kind: .text, value: "刺人水母")],
            origin: .cache,
            profile: "p2|c:entityName|g:abc123",
            issues: [QualityIssue.glossaryViolation.rawValue]
        )
        corpus.resetTranslation(raw: "噛みつきクラゲ")
        let reset = corpus.entry(for: "噛みつきクラゲ")
        TAP.eq("D18", "对照：resetTranslation 把 origin 打成 machine、profile 清空",
               "\(reset?.origin.rawValue ?? "-")|\(reset?.profile ?? "-")", "machine|")
    }

    static func d18Violations() {
        var glossary = Glossary()
        glossary.upsert(GlossaryEntry(source: "噛みつきクラゲ", target: "咬人水母", kind: .asset))
        glossary.upsert(GlossaryEntry(source: "呪い", target: "诅咒", kind: .asset))
        glossary.upsert(GlossaryEntry(source: "HP", target: "HP", kind: .system, keepAsIs: true))
        glossary.upsert(GlossaryEntry(source: "炎", target: "炎", kind: .type))

        // ① 命中：译名被换掉 → 必须报出**具体**术语对（重译靠它拼强调段）
        let bad = glossary.violations(raw: "噛みつきクラゲが現れた", translated: "刺人水母出现了", category: .dialogue)
        TAP.eqInt("D18", "违例命中：报 1 条术语对", bad.count, 1)
        TAP.eq("D18", "违例术语对 = 源名 → 锁定译名", "\(bad.first?.source ?? "-")→\(bad.first?.target ?? "-")",
               "噛みつきクラゲ→咬人水母")

        // ② 不命中：译名逐字用上了
        let good = glossary.violations(raw: "噛みつきクラゲが現れた", translated: "咬人水母出现了", category: .dialogue)
        TAP.eqInt("D18", "违例不命中：译文用了锁定译名 → 0 条", good.count, 0)

        // ③ keepAsIs：原文缩写必须留在译文里；违例对的 target 回落到 source 本身。
        //    （纯 ASCII 术语带词边界，`HP が` 这种紧贴假名的写法本来就不算命中；
        //    这里用空格边界，与种子表实际遇到的 `HP: 100` 同类。）
        let keepBad = glossary.violations(raw: "HP が 0 になった", translated: "血量 变成 0 了", category: .dialogue)
        TAP.eq("D18", "keepAsIs 违例：HP → 保留原文",
               "\(keepBad.count)|\(keepBad.first?.source ?? "-")|\(keepBad.first?.target ?? "-")", "1|HP|HP")
        let keepGood = glossary.violations(raw: "HP が 0 になった", translated: "HP 变成 0 了", category: .dialogue)
        TAP.eqInt("D18", "keepAsIs 保留原样 → 0 条", keepGood.count, 0)

        // ④ 单字术语：对话不放行（子串误伤太多），名称类放行
        let singleDialogue = glossary.violations(raw: "炎の剣", translated: "火焰之剑", category: .dialogue)
        TAP.eqInt("D18", "单字术语在对话里不放行（不误报）", singleDialogue.count, 0)
        let singleName = glossary.violations(raw: "炎の剣", translated: "火焰之剑", category: .entityName)
        TAP.eqInt("D18", "单字术语在名称类放行（报 1 条）", singleName.count, 1)

        // ⑤ 多条违例：去重 + 按 source 长度降序（长词优先，与 terms(in:) 同序）
        let many = glossary.violations(raw: "噛みつきクラゲの呪い", translated: "刺人水母的咒术", category: .dialogue)
        TAP.eq("D18", "多条违例按源名长度降序",
               many.map { $0.source }.joined(separator: "|"), "噛みつきクラゲ|呪い")

        // ⑥ 与质量校验的接线：多条术语同时违例，issue 仍然只记一条（重译只看它一次）
        let issues = FullTextQuality.check(
            raw: "噛みつきクラゲの呪い",
            translated: "刺人水母的咒术",
            segments: [Segment(kind: .text, value: "噛みつきクラゲの呪い")],
            category: .dialogue,
            glossary: glossary,
            srcLang: "ja"
        )
        TAP.eqInt("D18", "两条术语同时违例 → glossary_violation 只记一次",
                  issues.filter { $0 == .glossaryViolation }.count, 1)

        // ⑦ 空译文 / 空术语表：不崩，且空术语表不报
        TAP.eqInt("D18", "空译文按「全违例」处理（不是静默通过）",
                  glossary.violations(raw: "呪い", translated: "", category: .dialogue).count, 1)
        TAP.eqInt("D18", "空术语表 → 0 条", Glossary().violations(raw: "呪い", translated: "x", category: .dialogue).count, 0)
    }

    static func d18WorkOrder() {
        // name(1) → place(2) → dialogue(4)：模拟「怪物名 → 地名 → 台词」的交界。
        let order = ["名前1", "名前2", "地名1", "台詞1", "台詞2", "台詞3"]
        let ranks = ["名前1": 1, "名前2": 1, "地名1": 2, "台詞1": 4, "台詞2": 4, "台詞3": 4]

        func batch(
            cursor: inout Int,
            translated: Set<String> = [],
            blocked: Set<String> = [],
            limit: Int
        ) -> [String] {
            return FullTextWorkOrder.nextBatch(
                order: order,
                rankOf: { ranks[$0] ?? 5 },
                cursor: &cursor,
                isTranslated: { translated.contains($0) },
                isBlocked: { blocked.contains($0) },
                limit: limit
            )
        }

        // ① 名称组先出：limit 再大也不与后面的对话混批（这就是「咬人水母」的根因）
        var cursor = 0
        let first = batch(cursor: &cursor, limit: 10)
        TAP.eq("D18", "名称组先出且不跨 rank 混批", first.joined(separator: "|"), "名前1|名前2")
        TAP.eqInt("D18", "只消费到名称组末尾（游标=2）", cursor, 2)

        // ② 整组已译/blocked 时必须推进到下一个 rank，**不能返回空**：
        //    translate() 的 while 一看到空数组就 break，后面的对话永远不会翻。
        var skipCursor = 2
        let second = batch(cursor: &skipCursor, translated: ["名前1", "名前2"], blocked: ["地名1"], limit: 10)
        TAP.eq("D18", "整组 blocked → 推进到下一个 rank 继续", second.joined(separator: "|"), "台詞1|台詞2|台詞3")
        TAP.eqInt("D18", "跳过的组不会把游标留在原地", skipCursor, 6)

        // ③ limit 截断：只取组内前 N 条，游标停在组内，下次接着取同一组
        var limitCursor = 3
        let cut = batch(cursor: &limitCursor, limit: 2)
        TAP.eq("D18", "limit 截断：同组只取 2 条", cut.joined(separator: "|"), "台詞1|台詞2")
        TAP.eqInt("D18", "截断后游标停在组内（下次同组继续）", limitCursor, 5)
        let rest = batch(cursor: &limitCursor, limit: 2)
        TAP.eq("D18", "下次从组内继续取剩下的", rest.joined(separator: "|"), "台詞3")
        TAP.eqInt("D18", "组取完 → 游标到末尾", limitCursor, 6)

        // ④ 真的没活了才返回空（这是唯一允许 translate() break 的情形）
        let empty = batch(cursor: &limitCursor, limit: 10)
        TAP.eqInt("D18", "全部取完 → 返回空", empty.count, 0)
        TAP.eqInt("D18", "游标不越过末尾", limitCursor, order.count)

        // ⑤ 已译条目在组内被跳过，但不会让整组提前返回
        var mixedCursor = 3
        let mixed = batch(cursor: &mixedCursor, translated: ["台詞1"], limit: 10)
        TAP.eq("D18", "组内已译条目跳过、其余照常出批", mixed.joined(separator: "|"), "台詞2|台詞3")

        // ⑥ limit ≤ 0 不做任何消费（防御：不能死循环也不能吞游标）
        var zeroCursor = 0
        let zero = batch(cursor: &zeroCursor, limit: 0)
        TAP.eq("D18", "limit=0 → 空批且不动游标", "\(zero.count)|\(zeroCursor)", "0|0")
    }

    static func d18Prompt() {
        // 强调段只用于修复请求：正常请求的提示词必须**逐字节不变**（旧缓存继续有效）。
        let terminology = [GlossaryPair(source: "レベル", target: "等级")]
        let emphasis = [GlossaryPair(source: "噛みつきクラゲ", target: "咬人水母")]
        let normal = OpenAICompatibleProvider.systemPrompt(categories: [.dialogue], glossary: terminology)
        let repaired = OpenAICompatibleProvider.systemPrompt(
            categories: [.dialogue],
            glossary: terminology,
            emphasis: emphasis
        )
        TAP.eq("D18", "正常请求提示词逐字节不变（不升 prompt version）",
               normal, OpenAICompatibleProvider.systemPrompt(categories: [.dialogue], glossary: terminology, emphasis: []))
        TAP.ok("D18", "正常请求不含强调段", !normal.contains("上一版译文未遵守"))

        let header = "上一版译文未遵守下列译名，必须逐字使用，不得改写或使用同义译名："
        TAP.ok("D18", "修复请求含强调段表头", repaired.contains(header), repaired.suffix(200).description)
        TAP.ok("D18", "修复请求逐条列出 A => B", repaired.contains("噛みつきクラゲ => 咬人水母"))

        // 位置：术语表之后、最后的输出约束之前（两类约束都读完才收尾）。
        let glossaryAt = repaired.range(of: "术语表（必须严格使用")
        let emphasisAt = repaired.range(of: header)
        let tailAt = repaired.range(of: "只输出 JSON 字符串数组；长度、顺序")
        if let glossaryAt = glossaryAt, let emphasisAt = emphasisAt, let tailAt = tailAt {
            TAP.ok("D18", "强调段在术语表之后", glossaryAt.upperBound <= emphasisAt.lowerBound)
            TAP.ok("D18", "强调段在最后的输出约束之前", emphasisAt.upperBound <= tailAt.lowerBound)
        } else {
            TAP.ok("D18", "强调段位置可判定（三段都在）", false)
        }
    }
}
