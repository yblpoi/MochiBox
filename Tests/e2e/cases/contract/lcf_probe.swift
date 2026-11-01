//
//  lcf_probe.swift
//  MochiBox · QA 探针（经典 RM 数据层：RPG Maker 2000/2003 的 RPG_RT.ldb）
//
//  为什么必须单独有这一支：LCF 层是唯一直接按字节读写第三方二进制格式的地方。
//  --attach 的 JSONL 里只有翻译事件，看不到「字段路径是否还寻得到址」「写回有没有
//  把没动的字段一起改坏」「保存后 2003 的专有结构还在不在」。这些只有本探针能钉。
//
//  被测源码：Sources/Adapters/LCF/{LCFDatabase,LCFTextCodec,LCFError}.swift
//  C 层：    Sources/Adapters/LCF/lcf_shim.cpp（+ vendor/liblcf-build 的 liblcf.a）
//  数据：    Fixtures/rm2000/RPG_RT.ldb、Fixtures/rm2003/RPG_RT.ldb
//            （EasyRPG/TestGame 原始数据，GPL-3.0，见 Fixtures/README.md）
//
//  断言清单（L1–L25）：
//   L1  rm2000 读到 8 个角色（结构真读进来了，不是空壳）
//   L2  rm2000 读到 88 个道具
//   L3  rm2000 反射摊平出 2882 个文本字段
//   L4  其中非空 1699 条 —— 与上游 lcfstrings 的独立输出逐条对齐
//   L5  2882 条路径互不重复（路径是身份，重复就无法寻址）
//   L6  actors[0].name == "Alex"
//   L7  skills[70].using_message1 的原始字节逐字节等于 fixture 里的 Shift-JIS
//   L8  同一条字节被 LCFTextCodec 判成 Shift-JIS 并解出「%S はテレポートを唱えた！」
//   L9  事件命令里的文本可按路径取到：commonevents[1].event_commands[0].string
//   L10 空字段返回空 Data 而不是 nil（「没有内容」与「没有这个字段」要分开）
//   L11 不存在的路径返回 nil
//   L12 对不存在的路径写入抛 unknownPath
//   L13 2000 库里没有任何 classes / battleranimations 字段（真实数据佐证版本差异）
//   L14 2003 库里有 classes[0].name / battleranimations[0].name
//   L15 UTF-8 的「あ」判成 UTF-8（不能被 Shift-JIS 抢走）
//   L16 UTF-8 的中文长句判成 UTF-8
//   L17 GBK 的「药水」判成 GB18030 —— 旧实现会判成 UTF-8 并解出「ҩˮ」
//   L18 纯 ASCII 按日文原版口径判成 Shift-JIS
//   L19 按路径把 GB18030 译文写进 items[0].name 并保存成功
//   L20 重新打开，该字段字节与写入的完全一致
//   L21 没动过的字段逐字节不变（actors[0].name / skills[70].using_message1）
//   L22 保存后字段路径集合与保存前完全一致（2003 专有结构没有被写丢）
//   L23 文件没有膨胀（<= 原体积 1.05 倍）
//   L24 打开不存在的文件抛 openFailed
//   L25 打开非 LCF 文件抛 parseFailed
//   L36 版本判据是 ldb_id：ldb_id=2003 且 classes 清空后仍报 2003（synthetic）
//   L37 classes 清空后 2k3 chunk 依然写出 —— chunk 存在只反映编码方式，不反映有无数据
//   L38 ldb_id=0 时塞进 classes/battleranimations → Save 返回 true 但回读为 0（synthetic）
//   L39 同一个库的顶层 chunk 里也没有 0x1D/0x1E/0x1F —— 静默丢弃，不报错（synthetic）
//   L40 chunk 扫描器自检：rm2000 的顶层 chunk 集合与 liblcf 已知布局一致
//
//  L36–L39 的文件由 lcf_synth.cpp 现场生成（不入库），见该文件头注释。
//
//  验：.ldb 的字段路径/写回/版本判定 + .lmu 的事件对话与地图树 .lmt 的 mapID/地图名；
//  不验：存档（.lsd）—— 数据层目前不碰存档格式；
//  事件命令的语义（哪条是 401、控制码怎么分段）由 Segmenter 与后续用例负责。
//
//  运行：node Tests/e2e/cases/contract/18_lcf_extract.mjs
//        （swiftc 现编现跑；两个 fixture 路径由 runner 以 argv 传入）
//

import Foundation

@main
struct LCFProbe {

    nonisolated(unsafe) static var pass = 0
    nonisolated(unsafe) static var fail = 0
    nonisolated(unsafe) static var total = 0
    static var exitCode: Int32 { fail == 0 ? 0 : 1 }

    static func check(_ id: String, _ desc: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { pass += 1 } else { fail += 1 }
        total += 1
        if ok {
            print("ok \(total) - \(id) \(desc)")
        } else {
            print("not ok \(total) - \(id) \(desc) # 断言不成立")
            for line in detail().split(separator: "\n", omittingEmptySubsequences: true) {
                print("#   \(line)")
            }
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// 诊断信息，不计入断言数（TAP 消费者只认 ok/not ok）。
    static func note(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            print("#   \(line)")
        }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 5 else {
            print("not ok 1 - argv 缺少路径 # 断言不成立")
            print("#   usage: lcf_probe <rm2000.ldb> <rm2003.ldb> <synth_empty_2k3.ldb> <synth_2k_with_classes.ldb>")
            print("1..1")
            exit(1)
        }
        do {
            try run(rm2000: URL(fileURLWithPath: args[1]),
                    rm2003: URL(fileURLWithPath: args[2]),
                    synthEmpty2k3: URL(fileURLWithPath: args[3]),
                    synth2kWithClasses: URL(fileURLWithPath: args[4]))
        } catch {
            check("LX", "探针执行中断", false, "\(error)")
        }
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        exit(exitCode)
    }

    // MARK: - 主体

    static func run(rm2000: URL, rm2003: URL, synthEmpty2k3: URL, synth2kWithClasses: URL) throws {
        let db = try LCFDatabase(contentsOf: rm2000)
        let entries = db.allStrings()
        let nonEmpty = entries.filter { !$0.raw.isEmpty }
        let paths = entries.map(\.path)

        // ---- 结构 ----
        check("L1", "rm2000 读到 8 个角色", db.actorCount == 8, "actorCount=\(db.actorCount)")
        check("L2", "rm2000 读到 88 个道具", db.itemCount == 88, "itemCount=\(db.itemCount)")
        check("L3", "反射摊平出 2882 个文本字段", entries.count == 2882, "entries=\(entries.count)")
        check("L4", "其中非空 1699 条（与上游 lcfstrings 对齐）", nonEmpty.count == 1699,
              "nonEmpty=\(nonEmpty.count)")
        check("L5", "路径互不重复", Set(paths).count == paths.count,
              "unique=\(Set(paths).count) total=\(paths.count)")

        // ---- 路径寻址 ----
        let alex = db.bytes(at: "actors[0].name")
        check("L6", "actors[0].name == Alex", alex == Data("Alex".utf8),
              "got=\(alex.map(hex) ?? "nil")")

        let wantSkill = Data([0x25, 0x53, 0x20, 0x82, 0xcd, 0x83, 0x65, 0x83, 0x8c, 0x83, 0x7c,
                              0x81, 0x5b, 0x83, 0x67, 0x82, 0xf0, 0x8f, 0xa5, 0x82, 0xa6,
                              0x82, 0xbd, 0x81, 0x49])
        let skillRaw = db.bytes(at: "skills[70].using_message1")
        check("L7", "skills[70].using_message1 保持 Shift-JIS 原始字节（未经转码）",
              skillRaw == wantSkill, "got=\(skillRaw.map(hex) ?? "nil")")

        let decoded = try LCFTextCodec.decode(skillRaw ?? Data())
        check("L8", "该字段被判成 Shift-JIS 并解出日文",
              decoded.encoding == .shiftJIS && decoded.text == "%S はテレポートを唱えた！",
              "encoding=\(decoded.encoding.rawValue) text=\(decoded.text)")

        // 编码回归：GB18030 解 SJIS「の攻撃！」得到的是「偺峌寕両」——**同样是汉字**，
        // 只看字符类分不出来，所以必须整库扫"判成 GB18030 却含假名"的字段。
        let mojibake2000 = nonEmpty.filter { entry in
            guard let decoded = try? LCFTextCodec.decode(entry.raw) else { return false }
            return decoded.encoding == .gb18030
                && decoded.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        }
        check("L8b", "rm2000 没有「判成 GB18030 却含假名」的字段", mojibake2000.isEmpty,
              "命中 \(mojibake2000.prefix(3).map(\.path))")

        let cmd = db.bytes(at: "commonevents[1].event_commands[0].string")
        check("L9", "事件命令文本可按路径寻址", cmd == Data("Hello from Common Event".utf8),
              "got=\(cmd.map(hex) ?? "nil")")

        let empty = db.bytes(at: "actors[1].skill_name")
        check("L10", "空字段返回空 Data 而不是 nil", empty == Data(), "got=\(String(describing: empty))")

        let missing = db.bytes(at: "actors[99].name")
        check("L11", "不存在的路径返回 nil", missing == nil, "got=\(String(describing: missing))")

        var unknownThrown = false
        do { try db.setBytes(Data("x".utf8), at: "actors[99].name") } catch LCFError.unknownPath { unknownThrown = true }
        check("L12", "对不存在的路径写入抛 unknownPath", unknownThrown, "没有抛错")

        // ---- 版本差异（真实数据）----
        let classPaths = paths.filter { $0.hasPrefix("classes[") || $0.hasPrefix("battleranimations[") }
        check("L13", "2000 库里没有任何 classes / battleranimations 字段",
              classPaths.isEmpty, "命中=\(classPaths.prefix(3))")

        let db3 = try LCFDatabase(contentsOf: rm2003)
        let cls = db3.bytes(at: "classes[0].name")
        let ba = db3.bytes(at: "battleranimations[0].name")
        check("L14", "2003 库里有 classes[0].name 与 battleranimations[0].name",
              cls == Data("Hero A".utf8) && ba == Data("Male Hero".utf8),
              "classes=\(cls.map(hex) ?? "nil") ba=\(ba.map(hex) ?? "nil")")

        // 日文假名是 Shift-JIS 的**决定性**信号：rm2003 的 skills[].using_message1 是
        // 原版日文（の攻撃！），一旦被判成 GB18030，翻译链路拿到的就是生僻字乱码。
        let skill3 = db3.bytes(at: "skills[0].using_message1")
        let wantSkill3 = Data([0x82, 0xcc, 0x8d, 0x55, 0x8c, 0x82, 0x81, 0x49])
        let decoded3 = try LCFTextCodec.decode(skill3 ?? Data())
        check("L14b", "rm2003 skills[0].using_message1 判成 Shift-JIS 并解出「の攻撃！」",
              skill3 == wantSkill3 && decoded3.encoding == .shiftJIS && decoded3.text == "の攻撃！",
              "bytes=\(skill3.map(hex) ?? "nil") encoding=\(decoded3.encoding.rawValue) text=\(decoded3.text)")

        let mojibake2003 = db3.allStrings().filter { entry in
            guard !entry.raw.isEmpty, let decoded = try? LCFTextCodec.decode(entry.raw) else { return false }
            return decoded.encoding == .gb18030
                && decoded.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        }
        check("L14c", "rm2003 没有「判成 GB18030 却含假名」的字段", mojibake2003.isEmpty,
              "命中 \(mojibake2003.prefix(3).map(\.path))")

        // ---- 编码判定 ----
        let aU8 = Data("あ".utf8)
        check("L15", "UTF-8 的「あ」判成 UTF-8", LCFTextCodec.detect(aU8) == .utf8,
              "got=\(LCFTextCodec.detect(aU8).rawValue)")
        let longZh = Data("这是简体中文的测试文本。".utf8)
        check("L16", "UTF-8 中文长句判成 UTF-8", LCFTextCodec.detect(longZh) == .utf8,
              "got=\(LCFTextCodec.detect(longZh).rawValue)")
        // 对抗样本：D2 A9 CB AE 同时是合法 UTF-8（解出西里尔「ҩˮ」）与合法 GB18030（解出「药水」）。
        // 所以"UTF-8 优先"不能只看能不能解开，还要看解出来的是不是 CJK —— 这条专门钉这个。
        //
        // 覆盖范围说明：**仓库里没有真实的中文汉化 .ldb 样本**（可分发来源里只有日文原版
        // EasyRPG/TestGame），GBK 判据目前只在合成字节上验证。要补真实样本，得先拿到
        // GPL 兼容的汉化工程；在那之前这里只能标"合成覆盖"，不能算作真机验证。
        let gbk = try LCFTextCodec.encode("药水", as: .gb18030)
        let gbkDetected = LCFTextCodec.detect(gbk)
        let gbkDecoded = try LCFTextCodec.decode(gbk)
        // note() 会被 tap.absorbTap 吞掉（只在失败时透出），所以覆盖范围写进**断言名**里：
        // 每次跑测试都能在 TAP 行上看见"仅合成样本"，不会被误读成已覆盖汉化版。
        check("L17", "GBK 的「药水」判成 GB18030（对抗样本；仅合成覆盖，仓库无汉化 .ldb）",
              gbkDetected == .gb18030 && gbkDecoded.text == "药水",
              "bytes=\(hex(gbk)) encoding=\(gbkDetected.rawValue) text=\(gbkDecoded.text)")
        let ascii = Data("Potion".utf8)
        check("L18", "纯 ASCII 按日文原版口径判成 Shift-JIS", LCFTextCodec.detect(ascii) == .shiftJIS,
              "got=\(LCFTextCodec.detect(ascii).rawValue)")

        // ---- 写回（在副本上做，fixture 只读）----
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("mochibox-lcf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent("RPG_RT.ldb")
        try FileManager.default.copyItem(at: rm2000, to: copy)

        let beforeSize = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.intValue ?? 0

        let editor = try LCFDatabase(contentsOf: copy)
        try editor.setBytes(gbk, at: "items[0].name")
        try editor.save(to: copy)
        check("L19", "按路径写入 GB18030 译文并保存成功", true, "")

        let reopened = try LCFDatabase(contentsOf: copy)
        let after = reopened.bytes(at: "items[0].name")
        check("L20", "重新打开后该字段字节与写入的一致", after == gbk,
              "want=\(hex(gbk)) got=\(after.map(hex) ?? "nil")")

        let alexAfter = reopened.bytes(at: "actors[0].name")
        let skillAfter = reopened.bytes(at: "skills[70].using_message1")
        check("L21", "没动过的字段逐字节不变", alexAfter == alex && skillAfter == wantSkill,
              "alex=\(alexAfter.map(hex) ?? "nil")\nskill=\(skillAfter.map(hex) ?? "nil")")

        let pathsAfter = reopened.allStrings().map(\.path)
        check("L22", "保存后字段路径集合与保存前完全一致", pathsAfter == paths,
              "before=\(paths.count) after=\(pathsAfter.count)\n"
              + "only-before=\(Set(paths).subtracting(pathsAfter).prefix(3)) "
              + "only-after=\(Set(pathsAfter).subtracting(paths).prefix(3))")

        let afterSize = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.intValue ?? 0
        check("L23", "文件没有膨胀（不超过原体积 1.05 倍）",
              Double(afterSize) <= Double(beforeSize) * 1.05,
              "before=\(beforeSize) after=\(afterSize)")

        // ---- 2003 写回：ldb_id 必须活下来 ----
        // 版本的唯一判据是 db.system.ldb_id == 2003（liblcf saveopt.cpp:6-11）。
        // 一旦保存把 ldb_id 写成 0，classes / battleranimations 会被当作 e2k 数据
        // **静默丢弃**，而 Save 照样返回 true。所以在 2003 的副本上改一条、存、重开，
        // 2003 专有结构必须还在（档的是"换版本"，不是"能加载"）。
        let copy3 = work.appendingPathComponent("RPG_RT_2003.ldb")
        try FileManager.default.copyItem(at: rm2003, to: copy3)
        let editor3 = try LCFDatabase(contentsOf: copy3)
        let heroNameBefore = editor3.bytes(at: "classes[0].name")
        let battlerBefore = editor3.bytes(at: "battleranimations[0].name")
        try editor3.setBytes(Data("Mochi".utf8), at: "items[0].name")
        try editor3.save(to: copy3)

        let reopened3 = try LCFDatabase(contentsOf: copy3)
        let heroNameAfter = reopened3.bytes(at: "classes[0].name")
        let battlerAfter = reopened3.bytes(at: "battleranimations[0].name")
        check("L26", "2003 保存后 ldb_id 仍为 2003（classes/battleranimations 未被静默丢弃）",
              heroNameAfter == heroNameBefore && battlerAfter == battlerBefore
                && heroNameBefore == Data("Hero A".utf8),
              "classes: \(heroNameBefore.map(hex) ?? "nil") -> \(heroNameAfter.map(hex) ?? "nil")\n"
              + "battleranimations: \(battlerBefore.map(hex) ?? "nil") -> \(battlerAfter.map(hex) ?? "nil")")

        let written3 = reopened3.bytes(at: "items[0].name")
        let untouched3 = reopened3.bytes(at: "skills[0].using_message1")
        check("L27", "2003 写回：改过的字段读回一致、未改的日文字段逐字节不变",
              written3 == Data("Mochi".utf8) && untouched3 == wantSkill3,
              "written=\(written3.map(hex) ?? "nil")\nuntouched=\(untouched3.map(hex) ?? "nil")\n"
              + "want=\(hex(wantSkill3))")

        // ---- 错误路径 ----
        var openFailed = false
        do { _ = try LCFDatabase(contentsOf: work.appendingPathComponent("nope.ldb")) } catch LCFError.openFailed { openFailed = true }
        check("L24", "打开不存在的文件抛 openFailed", openFailed, "没有抛 openFailed")

        let junk = work.appendingPathComponent("junk.ldb")
        try Data("not an lcf file".utf8).write(to: junk)
        var parseFailed = false
        do { _ = try LCFDatabase(contentsOf: junk) } catch LCFError.parseFailed { parseFailed = true }
        check("L25", "打开非 LCF 文件抛 parseFailed", parseFailed, "没有抛 parseFailed")

        // ---- 地图（.lmu） ----
        // 路径口径与 LDB 一致（liblcf 的反射上下文同一种拼法）。注意字段名是
        // event_commands 而不是编辑器里显示的 list —— 以 liblcf 的 schema 为准。
        let mapUrl2000 = rm2000.deletingLastPathComponent().appendingPathComponent("Map0001.lmu")
        let map2000 = try LCFMapFile(contentsOf: mapUrl2000)
        let mapStrings = map2000.allStrings()
        let eventCommandPaths = mapStrings.filter {
            $0.path.range(of: "^events\\[\\d+\\]\\.pages\\[\\d+\\]\\.event_commands\\[\\d+\\]\\.string$",
                           options: .regularExpression) != nil
        }
        check("L28", "rm2000 Map0001 提取到事件对话 > 100 条",
              eventCommandPaths.count > 100,
              "event_commands=\(eventCommandPaths.count) total=\(mapStrings.count)")

        var sampleEvent: (path: String, text: String)?
        for entry in eventCommandPaths where !entry.raw.isEmpty {
            if let decoded = try? LCFTextCodec.decode(entry.raw) {
                sampleEvent = (entry.path, decoded.text)
                break
            }
        }
        if let sampleEvent {
            note("rm2000 地图样本: \(sampleEvent.path) = \(sampleEvent.text)")
        }
        check("L29", "地图事件文本可按路径解出", sampleEvent != nil,
              "event_commands 里没有解得出文本的条目")

        // 控制码必须原样保留：翻译链路靠 \s[1] 这类码来定字号/停顿，剥掉就改了语义。
        // 这里钉死一条真实样本（EasyRPG/TestGame 的 "Testing message speed:" 系列）。
        let escapeBytes = Data([0x5C, 0x73, 0x5B, 0x31, 0x5D]) // 字面量 \s[1]
        let escapeRaw = Data("\\s[1]Speed 1".utf8)
        let escapeEntry = mapStrings.first { $0.raw == escapeRaw }
        check("L30", "含 \\s[1] 控制码的原文逐字节原样保留（不剥码）",
              escapeEntry != nil && escapeEntry!.raw.range(of: escapeBytes) != nil,
              "没有找到 \\s[1]Speed 1 的原文；含 \\s[1] 的条数=\(mapStrings.filter { $0.raw.range(of: escapeBytes) != nil }.count)")

        // ---- 地图树（.lmt） ----
        let treeUrl2000 = rm2000.deletingLastPathComponent().appendingPathComponent("RPG_RT.lmt")
        let tree2000 = try LCFMapTreeInfo.load(contentsOf: treeUrl2000)
        check("L31", "rm2000 RPG_RT.lmt 的 mapID 列表非空且含地图 1",
              tree2000.mapIDs.count > 1 && tree2000.mapIDs.contains(1),
              "ids=\(tree2000.mapIDs.count) 前 8 个=\(tree2000.mapIDs.prefix(8))")
        check("L31b", "rm2000 RPG_RT.lmt 提取到地图名文本", !tree2000.strings.isEmpty,
              "strings=\(tree2000.strings.count)")
        if let firstNamed = tree2000.strings.first(where: { !$0.raw.isEmpty }),
           let decoded = try? LCFTextCodec.decode(firstNamed.raw) {
            note("lmt 样本: \(firstNamed.path) = \(decoded.text)")
        }

        // ---- 版本判定（liblcf: system.ldb_id == 2003） ----
        check("L32", "RM2000 样本判为 2000、RM2003 样本判为 2003",
              db.rmVersion() == .rm2000 && db3.rmVersion() == .rm2003,
              "rm2000=\(db.rmVersion().rawValue) rm2003=\(db3.rmVersion().rawValue)")
        // 写回后再判一次：ldb_id 是随文件带过来的，换版本会静默丢 2003 chunk（L26 的根因）。
        check("L32b", "写回并重开后版本不变（ldb_id 未被归零）",
              reopened.rmVersion() == .rm2000 && reopened3.rmVersion() == .rm2003,
              "rm2000=\(reopened.rmVersion().rawValue) rm2003=\(reopened3.rmVersion().rawValue)")

        // ---- 反向守卫：encoding 恒为直通 ----
        // GB18030 里 0x81 是合法前导（「丂」= 81 40），而它在 Shift-JIS / cp1252 下
        // 不是同一个字。整条链路（写 → 存 → 重开 → 读）必须逐字节相等：
        // 只要中途有一处按 ICU/1252 转码，这 2 个字节就会变。
        let gbk81 = try LCFTextCodec.encode("丂", as: .gb18030)
        let copy81 = work.appendingPathComponent("RPG_RT_81.ldb")
        try FileManager.default.copyItem(at: rm2000, to: copy81)
        let editor81 = try LCFDatabase(contentsOf: copy81)
        try editor81.setBytes(gbk81, at: "items[0].name")
        try editor81.save(to: copy81)
        let reopened81 = try LCFDatabase(contentsOf: copy81)
        let read81 = reopened81.bytes(at: "items[0].name")
        check("L33", "GBK 0x81 前导字节经保存往返不变（证明没有 cp1252/UTF-8 转码）",
              gbk81.first == 0x81 && read81 == gbk81,
              "写入=\(hex(gbk81)) 读回=\(read81.map(hex) ?? "nil")")

        // ---- 2003 地图：加载 + 按 2003 格式写回 ----
        let mapUrl2003 = rm2003.deletingLastPathComponent().appendingPathComponent("Map0001.lmu")
        let map2003 = try LCFMapFile(contentsOf: mapUrl2003)
        let strings2003Map = map2003.allStrings()
        check("L34", "rm2003 Map0001 能加载且提取到 > 100 条文本",
              strings2003Map.count > 100, "total=\(strings2003Map.count)")

        let mapCopy3 = work.appendingPathComponent("Map0001.lmu")
        try FileManager.default.copyItem(at: mapUrl2003, to: mapCopy3)
        let mapEditor3 = try LCFMapFile(contentsOf: mapCopy3)
        let firstEventPath = strings2003Map.first {
            $0.path.range(of: "^events\\[\\d+\\]\\.pages\\[\\d+\\]\\.event_commands\\[\\d+\\]\\.string$",
                           options: .regularExpression) != nil
        }?.path
        let marker = Data("MochiBox map probe".utf8)
        if let firstEventPath { try mapEditor3.setBytes(marker, at: firstEventPath) }
        try mapEditor3.save(to: mapCopy3, engine: .rm2003)
        let mapReopened = try LCFMapFile(contentsOf: mapCopy3)
        let mapReadBack = firstEventPath.flatMap { mapReopened.bytes(at: $0) }
        check("L35", "2003 地图按 2003 格式写回后可重开，改过的文本读回一致",
              firstEventPath != nil && mapReadBack == marker
                && mapReopened.allStrings().count == strings2003Map.count,
              "path=\(firstEventPath ?? "nil") readBack=\(mapReadBack.map(hex) ?? "nil") "
              + "count=\(mapReopened.allStrings().count) want=\(strings2003Map.count)")

        // ---- 版本判据：ldb_id，而不是"扫得到 classes 就是 2003"（synthetic）----
        //
        // L13/L14 只证明了"有 2k3 结构 → 是 2003"。真正的坑在另外两边：
        //   · 2003 库把 classes 清空后 chunk 会消失 → 按 chunk 判会把 2003 误判成 2000；
        //   · 2000 库塞进 classes 会被 writer 静默丢弃 → Save 返回 true 但数据没了。
        // 两个库都由 lcf_synth.cpp 现场造（不入库），验证完随临时目录一起删。
        let synthClassPrefixes = ["classes[", "battleranimations["]
        func synthClassPaths(_ db: LCFDatabase) -> [String] {
            db.allStrings().map(\.path).filter { p in synthClassPrefixes.contains { p.hasPrefix($0) } }
        }

        let emptied = try LCFDatabase(contentsOf: synthEmpty2k3)
        check("L36", "ldb_id=2003 且 classes 清空后仍报 2003", emptied.rmVersion() == .rm2003,
              "version=\(emptied.rmVersion()) classPaths=\(synthClassPaths(emptied).count)")

        // 这里把结论钉反方向：liblcf 的 writer 是**按 ldb_id 决定写不写 2k3 chunk**，
        // 与数组是否为空无关 —— 清空 classes 之后 0x1D/0x1E/0x1F 照样出现。
        // 所以"chunk 出现"只能说明**写这个文件的人按 2003 编码**，不能说明里面真有
        // 2003 数据；反过来"chunk 不出现"则多半是 2000 写的。判版本仍然只认 ldb_id。
        let emptiedChunks = try topLevelChunkIDs(synthEmpty2k3)
        check("L37", "classes 清空后 2k3 chunk 依然写出（chunk 存在只反映编码方式，不反映有无数据）",
              emptiedChunks.contains(0x1D) && emptiedChunks.contains(0x1E) && emptiedChunks.contains(0x1F)
                && synthClassPaths(emptied).isEmpty,
              "chunks=\(emptiedChunks.map { String(format: "0x%02X", $0) }) classPaths=\(synthClassPaths(emptied).count)")

        let injected = try LCFDatabase(contentsOf: synth2kWithClasses)
        check("L38", "ldb_id=0 时塞进 classes/battleranimations，Save 成功但回读为 0",
              injected.rmVersion() == .rm2000 && synthClassPaths(injected).isEmpty,
              "version=\(injected.rmVersion()) classPaths=\(synthClassPaths(injected).count)")

        let injectedChunks = try topLevelChunkIDs(synth2kWithClasses)
        check("L39", "同一个库的顶层 chunk 里也没有 0x1D/0x1E/0x1F（静默丢弃，不报错）",
              !injectedChunks.contains(0x1D) && !injectedChunks.contains(0x1E) && !injectedChunks.contains(0x1F),
              "chunks=\(injectedChunks.map { String(format: "0x%02X", $0) })")

        // 扫描器自检：这一段要是错的，L37/L39 的"不存在"就毫无意义。
        let baseChunks = try topLevelChunkIDs(rm2000)
        // rm2000 是 RPG_RT 时代写的真文件：顶层只有 0x0B..0x1A（末位 0x1A 是 version），
        // 没有任何 2k3 chunk —— 这正是"按 chunk 判 2000"能成立的场景。
        let expectedChunks: Set<Int> = [0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
                                        0x15, 0x16, 0x17, 0x18, 0x19, 0x1A]
        check("L40", "chunk 扫描器自检：rm2000 的顶层 chunk 集合与已知布局一致",
              Set(baseChunks) == expectedChunks,
              "got=\(baseChunks.map { String(format: "0x%02X", $0) })")
        // ---- PO 导出（EasyRPG gettext） ----
        // 一条译文要能进文件，必须先被调用方按"解码后的原文"放进 translations；
        // 这里手工准备四条：数据库字段、公共事件消息、地图消息（含控制码）、地图名。
        let mapMessages2000 = map2000.allMessages()
        let firstMapMessage = mapMessages2000.isEmpty
            ? nil
            : try LCFTextCodec.decode(mapMessages2000[0].raw).text
        let treeName = tree2000.strings.first { !$0.raw.isEmpty }
            .map { (try? LCFTextCodec.decode($0.raw).text) ?? nil } ?? nil

        var translations: [String: String] = [
            "Alex": "阿历克斯",
            "Soldier": "士兵",
            "Hello from Common Event": "来自公共事件",
            // terms 的命令项：$A / $c 是 EasyRPG 的控制后缀，属于 msgid 的一部分，
            // 必须逐字节保留（剥掉就永远查不到）。
            "Items$A": "物品$A",
            "End Game$c": "结束游戏$c"
        ]
        if let firstMapMessage {
            translations[firstMapMessage] = "测试消息速度：\\n\\\\s[1]速度 1"
        }
        if let treeName {
            translations[treeName] = "测试地图名"
        }

        let poRoot = work.appendingPathComponent("po", isDirectory: true)
        let poOptions = POExportOptions(languageID: "zh_CN",
                                        languageName: "简体中文",
                                        languageCode: "zh_CN",
                                        gameTitle: "TestGame")
        let dbSummary = try POExporter.exportDatabase(db, translations: translations, to: poRoot, options: poOptions)
        let treeSummary = try POExporter.exportMapTree(tree2000, translations: translations, to: poRoot, options: poOptions)
        let mapSummary = try POExporter.exportMaps([(id: 1, file: map2000)], translations: translations,
                                                   to: poRoot, options: poOptions)
        let poDirectory = poRoot.appendingPathComponent("zh_CN")
        let poFiles = Set((try FileManager.default.contentsOfDirectory(atPath: poDirectory.path)))
        note("PO 文件: " + poFiles.sorted().joined(separator: ", "))

        check("L41", "PO 按需生成：ldb / common / lmt / Map0001，没有译文的 battle 不生成",
              poFiles == ["meta.ini", "rpg_rt.ldb.po", "rpg_rt.ldb.common.po", "rpg_rt.lmt.po", "Map0001.po"],
              "实际=" + poFiles.sorted().joined(separator: ","))

        let metaText = try String(contentsOf: poDirectory.appendingPathComponent("meta.ini"), encoding: .utf8)
        let metaKeys = ["Name=", "Description=", "Code=", "Term=", "GameTitle=", "Font="]
        check("L42", "meta.ini 是 [Language] 段且六个键齐全",
              metaText.contains("[Language]") && metaKeys.allSatisfy { metaText.contains($0) },
              metaText.replacingOccurrences(of: "\n", with: " | "))

        let dbPO = try String(contentsOf: poDirectory.appendingPathComponent("rpg_rt.ldb.po"), encoding: .utf8)
        // msgctxt 必须是**非索引**形态：0.8.1 的 RewriteDatabase 索引分支以
        // ctxt.index >= 0 为闸门，而 scalar 字段的 ctxt.index 恒为 -1 ——
        // actors.1.name 实测一条都查不到（端到端截图确认过）。
        let dbContexts = dbPO.split(separator: "\n")
            .filter { $0.hasPrefix("msgctxt ") }
            .map(String.init)
        // 三层以上的真实路径（如 commonevents[0].event_commands[1].string）只能落空
        // msgctxt 兜底；直接从库里取一条，避免钉死某个结构。
        let deepPath = db.allStrings().map(\.path)
            .first { $0.split(separator: ".").count >= 3 } ?? ""
        check("L43", "数据库字段的 msgctxt 非索引（actors.name / system.title_name 原样 / 三层为空）",
              dbContexts.contains("msgctxt \"actors.name\"")
                && dbContexts.contains("msgctxt \"actors.title\"")
                && dbPO.contains("msgid \"Alex\"") && dbPO.contains("msgstr \"阿历克斯\"")
                && POExporter.context(for: "system.title_name") == "system.title_name"
                && POExporter.context(for: "terms.command_item") == "terms.command_item"
                && !deepPath.isEmpty && POExporter.context(for: deepPath) == "",
              dbContexts.prefix(6).joined(separator: " | ")
                + " || deepPath=\(deepPath) -> [\(POExporter.context(for: deepPath))]")

        // terms 的 path 由 liblcf 反射给出的是 **terms.<field>**（System.terms 在
        // Database::ForEachString 里是 system 的兄弟，不嵌套），与引擎查表的
        // "{parentName}.{fieldName}" 正好一致，所以不需要额外映射。
        check("L43b", "terms 命令项是 terms.command_item 且 $A / $c 控制后缀逐字节保留",
              dbPO.contains("msgctxt \"terms.command_item\"")
                && dbPO.contains("msgid \"Items$A\"") && dbPO.contains("msgstr \"物品$A\"")
                && dbPO.contains("msgctxt \"terms.menu_quit\"")
                && dbPO.contains("msgid \"End Game$c\"") && dbPO.contains("msgstr \"结束游戏$c\""),
              dbPO.split(separator: "\n").filter { $0.hasPrefix("msgid \"Item") || $0.hasPrefix("msgid \"End") }
                .joined(separator: " | "))

        let commonPO = try String(contentsOf: poDirectory.appendingPathComponent("rpg_rt.ldb.common.po"), encoding: .utf8)
        check("L44", "公共事件 msgid 是整条消息（10110 块），不是单条指令",
              commonPO.contains("msgid \"Hello from Common Event\"")
                && commonPO.contains("msgstr \"来自公共事件\""),
              commonPO.split(separator: "\n").prefix(10).joined(separator: " | "))

        let mapPO = try String(contentsOf: poDirectory.appendingPathComponent("Map0001.po"), encoding: .utf8)
        // 原文里是「Testing message speed:\\n\\s[1]Speed 1」：换行 -> 字面 \\n，
        // 控制码的单反斜杠 -> 两个反斜杠（引擎只认这三种转义，多一个反斜杠就整文件报错）。
        check("L45", "地图消息的 msgid 含续行（\\n 转义）与控制码（\\\\s[1] 转义）",
              mapPO.contains("msgid \"Testing message speed:\\n\\\\s[1]Speed 1\""),
              mapPO.split(separator: "\n").filter { $0.hasPrefix("msgid") }.prefix(3).joined(separator: " | "))

        // 回读校验：把生成的文件再按引擎规则解析一遍，条目必须与 summary 对得上。
        var readBackOK = true
        var readBackDetail = ""
        for (file, count) in dbSummary.entriesByFile {
            let text = try String(contentsOf: poDirectory.appendingPathComponent(file), encoding: .utf8)
            let parsed = try POExporter.parse(text)
            if parsed.count != count {
                readBackOK = false
                readBackDetail += file + ": 期望 " + String(count) + " 条，读回 " + String(parsed.count) + " 条; "
            }
        }
        let mapParsed = try POExporter.parse(mapPO)
        if mapParsed.count != (mapSummary.entriesByFile["Map0001.po"] ?? -1) {
            readBackOK = false
            readBackDetail += "Map0001.po 条目数不符; "
        }
        let treeParsed = try POExporter.parse(
            try String(contentsOf: poDirectory.appendingPathComponent("rpg_rt.lmt.po"), encoding: .utf8))
        if treeParsed.count != (treeSummary.entriesByFile["rpg_rt.lmt.po"] ?? -1) {
            readBackOK = false
            readBackDetail += "rpg_rt.lmt.po 条目数不符; "
        }
        check("L46", "生成的 PO 回读后条目数与写入一致", readBackOK, readBackDetail)

        // 反例：篡改一条 msgid，verify 必须报错（引擎侧失配是静默的，这里是唯一防线）。
        let tampered = mapPO.replacingOccurrences(of: "msgid \"Testing message speed:",
                                                 with: "msgid \"XTesting message speed:")
        var tamperCaught = false
        do {
            try POExporter.verify(tampered, expected: mapParsed)
        } catch let error as POExportError {
            if case .readBackMismatch = error { tamperCaught = true }
        }
        check("L47", "篡改 msgid 后回读校验必须报错", tamperCaught, "篡改没有被检出")

        // 回归守卫：所有 PO 的 msgctxt 都不许带数字下标。
        // 索引形态在 0.8.1 上实测无效（见 L43），"优化"回去等于悄悄关掉数据库翻译，
        // 而引擎失配是静默的 —— 只有这一层能拦住。
        var indexedContexts: [String] = []
        for file in poFiles.sorted() where file.hasSuffix(".po") {
            let text = try String(contentsOf: poDirectory.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("msgctxt ") {
                if line.range(of: "\\.\\d+\\.", options: .regularExpression) != nil {
                    indexedContexts.append(file + ":" + line)
                }
            }
        }
        check("L48", "所有 PO 的 msgctxt 都不含数字下标（\\.\\d+\\. 不命中）",
              indexedContexts.isEmpty, indexedContexts.joined(separator: " | "))
    }

    // MARK: - 顶层 chunk 扫描

    /// 读 LDB 的**顶层 chunk id 列表**（只跳块，不解析内容）。
    ///
    /// 格式见 vendor/liblcf-src/src/reader_lcf.cpp:86-105：整数是"7 位一组、高位续"的
    /// **大端**变长编码（不是小端 LEB128）。文件 = [变长 header 长度][header 字节]，
    /// 之后重复 [变长 chunk id][变长 chunk 长度][payload]。
    ///
    /// 为什么不直接搜字节：id 与长度都是变长的，裸搜 0x1E 会把 payload 里的任意字节
    /// 也算进去。这里是独立于 liblcf 的一份实现，用来交叉验证 L37/L39。
    static func topLevelChunkIDs(_ url: URL) throws -> [Int] {
        let bytes = [UInt8](try Data(contentsOf: url))
        var i = 0
        guard let headerLength = readVarInt(bytes, &i), headerLength >= 0,
              i + headerLength <= bytes.count else { return [] }
        i += headerLength
        var ids: [Int] = []
        while i < bytes.count {
            guard let id = readVarInt(bytes, &i),
                  let length = readVarInt(bytes, &i), length >= 0,
                  i + length <= bytes.count else { break }
            ids.append(id)
            i += length
        }
        return ids
    }

    /// 读一个 LCF 变长整数（大端、7 位一组、最高位表示续）。越界或过长返回 nil。
    static func readVarInt(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        var value = 0
        var loops = 0
        while true {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            value = (value << 7) | Int(byte & 0x7F)
            loops += 1
            if byte & 0x80 == 0 { return value }
            if loops > 5 { return nil }
        }


    }
}
