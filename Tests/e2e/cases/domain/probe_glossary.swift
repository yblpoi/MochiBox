//
//  probe_glossary.swift
//  MochiBox · E2E 领域层探针（术语表 / 类别 / profile / 质量 / 存储）
//
//  只测纯值类型与文件存储，不拉浏览器、不发网络。
//

import Foundation

// MARK: - G1 模型与匹配

func g1() {
    var glossary = Glossary(GlossarySeed.entries)

    TAP.eq("G1-1", "种子：レベル→等级", glossary.exact("レベル")?.target ?? "nil", "等级")
    TAP.ok("G1-2", "HP 是 keepAsIs", glossary.exact("ＨＰ")?.keepAsIs == true)
    TAP.eq("G1-3", "keepAsIs 回显输入原文（LV 不被改写成 Lv）", glossary.exactOutput(for: "LV") ?? "nil", "LV")

    let hits = glossary.terms(in: "最大HPが下がった")
    TAP.eq("G1-4", "最长匹配优先：最大HP 在 HP 之前", hits.first?.source ?? "nil", "最大HP")

    let ascii = glossary.terms(in: "HPPotion")
    TAP.ok("G1-5", "ASCII 词边界：HPPotion 不命中 HP", !ascii.contains { $0.source == "HP" })

    var withSingle = Glossary(GlossarySeed.entries)
    withSingle.upsert(GlossaryEntry(source: "炎", target: "炎", kind: .type))
    TAP.ok("G1-6", "单字术语默认不注入", !withSingle.terms(in: "炎の剣").contains { $0.source == "炎" })
    TAP.ok("G1-7", "系统/名称类别放行单字术语", withSingle.terms(in: "炎の剣", includeSingleChar: true).contains { $0.source == "炎" })

    TAP.ok("G1-8", "首次学习生效", glossary.learn(source: "薬草", target: "药草", kind: .asset))
    TAP.ok("G1-9", "同名不同译不覆盖首次译名", !glossary.learn(source: "薬草", target: "草药", kind: .asset))
    TAP.eq("G1-10", "保留首次译名", glossary.exact("薬草")?.target ?? "nil", "药草")

    glossary.remove(source: "薬草")
    TAP.ok("G1-11", "删除后不再命中", glossary.exact("薬草") == nil)
}

// MARK: - G2 profile

func g2() {
    let a = GlossaryPair(source: "レベル", target: "等级")
    let b = GlossaryPair(source: "魔物", target: "魔物")
    let one = TranslationProfile.id(category: .entityName, pairs: [a, b])
    let two = TranslationProfile.id(category: .entityName, pairs: [b, a])
    TAP.eq("G2-1", "profile 与术语顺序无关", one, two)
    TAP.ok("G2-2", "不同类别不同 profile", one != TranslationProfile.id(category: .dialogue, pairs: [a, b]))
    TAP.eq("G2-3", "other 与 dialogue 归一", TranslationProfile.id(category: .other, pairs: [a]),
           TranslationProfile.id(category: .dialogue, pairs: [a]))
    TAP.ok("G2-4", "空束也是稳定值", TranslationProfile.id(category: .dialogue, pairs: []).hasSuffix("g:0"))
}

// MARK: - G3 质量

func g3() {
    var glossary = Glossary()
    glossary.upsert(GlossaryEntry(source: "レベル", target: "等级", kind: .system))
    let segments = [Segment(kind: .text, value: "レベルが上がった")]

    let lost = FullTextQuality.check(
        raw: "レベルが上がった %1", translated: "等级提升了",
        segments: [Segment(kind: .text, value: "レベルが上がった %1")],
        category: .dialogue, glossary: glossary, srcLang: "ja"
    )
    TAP.ok("G3-1", "占位符丢失", lost.contains(.placeholderLost))

    let kana = FullTextQuality.check(
        raw: "レベルが上がった", translated: "等级が上がった", segments: segments,
        category: .dialogue, glossary: glossary, srcLang: "ja"
    )
    TAP.ok("G3-2", "残留假名", kana.contains(.kanaLeft))

    let same = FullTextQuality.check(
        raw: "レベルが上がった", translated: "レベルが上がった", segments: segments,
        category: .dialogue, glossary: glossary, srcLang: "ja"
    )
    TAP.ok("G3-3", "译文==原文", same.contains(.identical))
    let suppressed = FullTextQuality.check(
        raw: "レベルが上がった", translated: "レベルが上がった", segments: segments,
        category: .dialogue, glossary: glossary, srcLang: "ja", suppressIdentical: true
    )
    TAP.ok("G3-4", "短路条目抑制 identical", !suppressed.contains(.identical))

    let violation = FullTextQuality.check(
        raw: "レベルが上がった", translated: "级别提升了", segments: segments,
        category: .dialogue, glossary: glossary, srcLang: "ja"
    )
    TAP.ok("G3-5", "锁定术语缺失", violation.contains(.glossaryViolation))

    let longRaw = String(repeating: "あ", count: 40)
    let short = FullTextQuality.check(
        raw: longRaw, translated: "短", segments: [Segment(kind: .text, value: longRaw)],
        category: .dialogue, glossary: Glossary(), srcLang: "ja"
    )
    TAP.ok("G3-6", "长度异常", short.contains(.lengthAnomaly))
}

// MARK: - G4 存储

func g4(_ work: URL) {
    let directory = work.appendingPathComponent("glossary", isDirectory: true)
    let store = GlossaryStore(directory: directory, gameHash: "g-test")

    var glossary = Glossary(GlossarySeed.entries)
    glossary.upsert(GlossaryEntry(source: "薬草", target: "药草", kind: .asset))
    let file = GlossaryFile(gameHash: "g-test", entries: Array(glossary.entries.values), deletedSources: ["運"])
    do {
        try store.save(file)
    } catch {
        TAP.ok("G4-1", "保存术语表", false, "\(error)")
        return
    }
    TAP.ok("G4-1", "保存术语表", true)
    TAP.eqInt("G4-2", "文件权限 0600", Fs.mode(store.url) & 0o777, 0o600)
    let loaded = store.load()
    TAP.ok("G4-3", "回读条目数一致", (loaded?.entries.count ?? -1) == file.entries.count)
    TAP.ok("G4-4", "回读墓碑", loaded?.deletedSources == ["運"])

    // 导出→导入：keepAsIs 必须闭合
    let exported = work.appendingPathComponent("glossary-export.json")
    do {
        try store.export(glossary, to: exported)
    } catch {
        TAP.ok("G4-5", "导出术语表", false, "\(error)")
        return
    }
    var imported = Glossary()
    let accepted = (try? store.importFile(from: exported, into: &imported)) ?? -1
    TAP.ok("G4-5", "导出→导入有条目", accepted > 0)
    TAP.ok("G4-6", "HP 导入后仍是 keepAsIs", imported.exact("HP")?.keepAsIs == true)

    // 损坏隔离
    Fs.write("{ broken", to: store.url)
    TAP.ok("G4-7", "损坏文件返回 nil", store.load() == nil)
    TAP.ok("G4-8", "损坏文件被隔离", Fs.names(directory).contains { $0.contains(".corrupt") })
}

// MARK: - G5 缓存键

func g5() {
    let segments = [Segment(kind: .text, value: "こんにちは")]
    TAP.eq("G5-1", "keyMaterial 旧公式逐字节不变",
           Segmenter.keyMaterial(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: segments),
           "mvmz|ja|zh-Hans|こんにちは")
    TAP.eq("G5-2", "cacheKey 旧值不变",
           Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: segments),
           "046148632a8ca4f458fefd498ff5f279e1860f5727b449ed148487a543cead0e")
    TAP.ok("G5-3", "带 profile 时 key 改变",
           Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans",
                              segments: segments, profile: "p2|c:dialogue|g:abc") !=
           Segmenter.cacheKey(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: segments))

    // 合成单段与原始多段等价（下发门禁的地基）
    let mixed = Segmenter.splitSegments(raw: "\u{5C}C[2]こんにちは\u{5C}N[1]元気", engineFamily: "mvmz")
    let mapKey = Segmenter.mapKey(mixed)
    let synthetic = [Segment(kind: .text, value: mapKey)]
    TAP.eq("G5-4", "合成段 keyMaterial 等价",
           Segmenter.keyMaterial(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: mixed, profile: "p"),
           Segmenter.keyMaterial(engineFamily: "mvmz", srcLang: "ja", tgtLang: "zh-Hans", segments: synthetic, profile: "p"))
}

// MARK: - G6 类别

func g6() {
    TAP.ok("G6-1", "system.terms → 系统术语",
           TranslationCategory.inferred(source: "system", path: "system.terms.basic[0]") == .systemTerm)
    TAP.ok("G6-2", "skill.N.name → 名称",
           TranslationCategory.inferred(source: "skill", path: "skill.12.name") == .entityName)
    TAP.ok("G6-3", "item.N.description → 描述",
           TranslationCategory.inferred(source: "item", path: "item.7.description") == .description)
    TAP.ok("G6-4", "map 事件 → 对话",
           TranslationCategory.inferred(source: "map", path: "map.12.ev3.p0[45].p0") == .dialogue)
    TAP.ok("G6-5", "mapInfo → 地名",
           TranslationCategory.inferred(source: "system", path: "mapInfo.2.name") == .place)
}

// MARK: - main

@main
enum GlossaryProbe {
    static func main() {
        var workDirectory: URL?
        var only = "all"
        var args = CommandLine.arguments
        var index = 1
        while index < args.count {
            switch args[index] {
            case "--work":
                index += 1
                if index < args.count { workDirectory = URL(fileURLWithPath: args[index]) }
            case "--only":
                index += 1
                if index < args.count { only = args[index] }
            default:
                break
            }
            index += 1
        }

        guard let work = workDirectory else {
            TAP.ok("G0", "缺少 --work 参数", false)
            exit(TAP.finish())
        }
        Fs.make(work)
        if only == "all" || only == "G1" { g1() }
        if only == "all" || only == "G2" { g2() }
        if only == "all" || only == "G3" { g3() }
        if only == "all" || only == "G4" { g4(work) }
        if only == "all" || only == "G5" { g5() }
        if only == "all" || only == "G6" { g6() }
        exit(TAP.finish())
    }
}
