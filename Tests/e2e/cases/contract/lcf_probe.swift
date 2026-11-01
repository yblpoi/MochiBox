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
//
//  不验：地图（.lmu）与存档（.lsd）—— 数据层目前只做 .ldb；
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

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("not ok 1 - argv 缺少 fixture 路径 # 断言不成立")
            print("#   usage: lcf_probe <rm2000.ldb> <rm2003.ldb>")
            print("1..1")
            exit(1)
        }
        do {
            try run(rm2000: URL(fileURLWithPath: args[1]), rm2003: URL(fileURLWithPath: args[2]))
        } catch {
            check("LX", "探针执行中断", false, "\(error)")
        }
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        exit(exitCode)
    }

    // MARK: - 主体

    static func run(rm2000: URL, rm2003: URL) throws {
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

        // ---- 编码判定 ----
        let aU8 = Data("あ".utf8)
        check("L15", "UTF-8 的「あ」判成 UTF-8", LCFTextCodec.detect(aU8) == .utf8,
              "got=\(LCFTextCodec.detect(aU8).rawValue)")
        let longZh = Data("这是简体中文的测试文本。".utf8)
        check("L16", "UTF-8 中文长句判成 UTF-8", LCFTextCodec.detect(longZh) == .utf8,
              "got=\(LCFTextCodec.detect(longZh).rawValue)")
        let gbk = try LCFTextCodec.encode("药水", as: .gb18030)
        let gbkDetected = LCFTextCodec.detect(gbk)
        let gbkDecoded = try LCFTextCodec.decode(gbk)
        check("L17", "GBK 的「药水」判成 GB18030 并解回原文",
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

        // ---- 错误路径 ----
        var openFailed = false
        do { _ = try LCFDatabase(contentsOf: work.appendingPathComponent("nope.ldb")) } catch LCFError.openFailed { openFailed = true }
        check("L24", "打开不存在的文件抛 openFailed", openFailed, "没有抛 openFailed")

        let junk = work.appendingPathComponent("junk.ldb")
        try Data("not an lcf file".utf8).write(to: junk)
        var parseFailed = false
        do { _ = try LCFDatabase(contentsOf: junk) } catch LCFError.parseFailed { parseFailed = true }
        check("L25", "打开非 LCF 文件抛 parseFailed", parseFailed, "没有抛 parseFailed")
    }
}
