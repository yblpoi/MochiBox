//
// 19_marshal_probe.swift —— Ruby Marshal / RGSS 数据往返探针（不属于产品源码）
//
// 断言分两层（分工来自实测：外部样本的事件层是空壳，只有数据库/术语层有文本）：
//
//   Level-1 外部真实样本（Fixtures/rmxp-real|rmvx-real|rmvxace-real）
//     M-L1-XP-* / M-L1-VX-*   只证"能读、能原样写回"：Marshal 4.8 头、RPG::System /
//               RPG::Map / Table 结构、@words/@terms 形状、往返字节相同、数据库层精确条数。
//              这两份工程不含 101/401 对话：@events{} 是空哈希、EventCommand 只有 code=0
//              终止符 —— 所以对话断言放在 Level-2 与 M-L1-VXA。
//     M-L1-VXA-*  第三份真实样本是 CC0 的 VX Ace 工程，事件层**非空**：236 条
//              对话/指令文本、Terms 是 4 个容器、浮点带 RGSS3 尾随字节。
//
//   Level-2 合成样本（Fixtures/rmxp|rmvx|rmvxace）—— 证文本路径与编码/边界
//     M-L2-*   101/401/102/402/404/405 路径与文本、三版本各不相同的用语表形状、
//              编码判定、空串/超长串/控制序列/中日英混排、Table 结构
//
//   引擎无关：M-INT（整数编解码逐字节对照 ruby）、M-ENC、M-LINK（对象表）、M-WB（写回）、M-BAD（畸形输入）
//
// 编译与运行：node Tests/e2e/cases/contract/19_marshal.mjs（仓库根作为 argv[1] 传入）
//

import Foundation
import Darwin

final class Reporter {
    private var pass = 0
    private var fail = 0
    private var total = 0

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

    func finish() -> Int32 {
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        return fail == 0 ? 0 : 1
    }
}

/// 仓库根：由 19_marshal.mjs 作为第一个参数传入（不依赖启动时的 cwd）。
let repoRoot: String = {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    return FileManager.default.currentDirectoryPath
}()

func pathInRepo(_ relative: String) -> URL {
    URL(fileURLWithPath: repoRoot).appendingPathComponent(relative)
}

func documentInRepo(_ relative: String) -> RGSSDocument? {
    let url = pathInRepo(relative)
    guard let file = RGBSGameFile.detect(fileName: url.lastPathComponent),
          let data = try? Data(contentsOf: url),
          let doc = try? RGSSDocument(parsing: data, file: file) else { return nil }
    return doc
}

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

@main
struct MarshalProbe {
    static func main() {
        let reporter = Reporter()
        integerCodec(reporter)

        // Level-1：外部真实样本
        externalSamples(reporter, dir: "rmxp-real", ext: "rxdata", tag: "XP",
                        expectedFiles: 15, expectedEntries: 620, expectedActors: 8,
                        termsClass: "RPG::System::Words", termsField: "words", termsCount: 20,
                        mapSize: (20, 15, 3, 900))
        externalSamples(reporter, dir: "rmvx-real", ext: "rvdata", tag: "VX",
                        expectedFiles: 14, expectedEntries: 769, expectedActors: 8,
                        termsClass: "RPG::System::Terms", termsField: "terms", termsCount: 33,
                        mapSize: (100, 100, 3, 30000))
        realVXAceSample(reporter)
        realGameIni(reporter)

        // Level-2：合成样本
        synthesizedFixtures(reporter)

        // 引擎无关
        encodingResolution(reporter)
        sharedObjects(reporter)
        writeBack(reporter)
        malformedInputs(reporter)
        exit(reporter.finish())
    }

    // MARK: - M-INT 整数编解码
    //
    // 期望值全部来自 ruby 2.6 的 Marshal.dump 实际输出。整数编码错了整个格式就废了，
    // 所以这里逐字节比对，而不是"回读等于原值"这种自洽断言。

    static let integerCases: [(Int64, String)] = [
        (0, "04 08 69 00"),
        (1, "04 08 69 06"),
        (-1, "04 08 69 fa"),
        (2, "04 08 69 07"),
        (122, "04 08 69 7f"),
        (123, "04 08 69 01 7b"),
        (124, "04 08 69 01 7c"),
        (255, "04 08 69 01 ff"),
        (256, "04 08 69 02 00 01"),
        (257, "04 08 69 02 01 01"),
        (300, "04 08 69 02 2c 01"),
        (-123, "04 08 69 80"),
        (-124, "04 08 69 ff 84"),
        (-255, "04 08 69 ff 01"),
        (-256, "04 08 69 ff 00"),
        (-257, "04 08 69 fe ff fe"),
        (-300, "04 08 69 fe d4 fe"),
        (65535, "04 08 69 02 ff ff"),
        (65536, "04 08 69 03 00 00 01"),
        (-65536, "04 08 69 fe 00 00"),
        (1073741823, "04 08 69 04 ff ff ff 3f"),
        (1073741824, "04 08 6c 2b 07 00 00 00 40"),
        (-1073741824, "04 08 69 fc 00 00 00 c0"),
        (-1073741825, "04 08 6c 2d 07 01 00 00 40"),
        (2147483647, "04 08 6c 2b 07 ff ff ff 7f"),
        (2147483648, "04 08 6c 2b 07 00 00 00 80"),
        (-2147483648, "04 08 6c 2d 07 00 00 00 80"),
        (4294967296, "04 08 6c 2b 08 00 00 00 00 01 00"),
        (1099511627776, "04 08 6c 2b 08 00 00 00 00 00 01"),
        (4611686018427387903, "04 08 6c 2b 09 ff ff ff ff ff ff ff 3f"),
        (9223372036854775807, "04 08 6c 2b 09 ff ff ff ff ff ff ff 7f"),
        (-9223372036854775808, "04 08 6c 2d 09 00 00 00 00 00 00 00 80")
    ]

    static func integerCodec(_ r: Reporter) {
        let groups: [(String, String, Range<Int>)] = [
            ("M-INT-01", "Fixnum 单字节段（0/1/-1/2/122）逐字节符合 ruby", 0..<5),
            ("M-INT-02", "Fixnum 多字节段（含负数补码小端）逐字节符合 ruby", 5..<20),
            ("M-INT-03", "Fixnum/Bignum 分界（±2^30）逐字节符合 ruby", 20..<27),
            ("M-INT-04", "大 Bignum（2^32 … 2^63-1、-2^63）逐字节符合 ruby", 27..<32)
        ]
        for (id, name, range) in groups {
            var mismatches: [String] = []
            for index in range {
                let (value, expected) = integerCases[index]
                do {
                    let data = try MarshalWriter.dump(MarshalValue.integer(value))
                    let actual = hexString(data)
                    if actual != expected {
                        mismatches.append("\(value): 期望 \(expected) 实际 \(actual)")
                    }
                    let back = try MarshalReader.load(data)
                    if try MarshalWriter.dump(back) != data {
                        mismatches.append("\(value): 二次往返不一致")
                    }
                } catch {
                    mismatches.append("\(value): 抛错 \(error)")
                }
            }
            r.check(id, name, mismatches.isEmpty, mismatches.joined(separator: "\n"))
        }
    }

    // MARK: - M-L1 外部真实样本
    //
    // 只断言"结构解析 + 字节往返 + 已知的层分布"。
    // 这两个工程的事件层是空壳（@events{} 为空、EventCommand 只有 code=0），
    // 所以这里如实断言事件层 0 条 —— 不把"数据库层有文本"说成"对话能提取"。

    static func externalSamples(_ r: Reporter,
                                dir: String,
                                ext: String,
                                tag: String,
                                expectedFiles: Int,
                                expectedEntries: Int,
                                expectedActors: Int,
                                termsClass: String,
                                termsField: String,
                                termsCount: Int,
                                mapSize: (x: Int, y: Int, z: Int, n: Int)) {
        let base = "Fixtures/\(dir)/Data"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pathInRepo(base).path))?
            .filter { $0.hasSuffix("." + ext) }.sorted() ?? []

        var headerProblems: [String] = []
        var roundTripProblems: [String] = []
        var totalEntries = 0
        var eventEntries = 0
        for name in names {
            let url = pathInRepo("\(base)/\(name)")
            guard let data = try? Data(contentsOf: url) else {
                headerProblems.append("\(name): 读不到")
                continue
            }
            if data.count < 2 || data[0] != 0x04 || data[1] != 0x08 {
                headerProblems.append("\(name): 头不是 04 08，实际 \(hexString(data.prefix(2)))")
            }
            do {
                let doc = try RGSSDocument.load(url: url)
                if try doc.serialize() != doc.source { roundTripProblems.append("\(name): 往返字节不一致") }
                let entries = doc.textEntries()
                totalEntries += entries.count
                eventEntries += entries.filter { $0.path.contains(".list[") }.count
            } catch {
                roundTripProblems.append("\(name): \(error)")
            }
        }

        r.check("M-L1-\(tag)-HEADER",
                "\(tag) 的 \(names.count) 个文件都是 Marshal 4.8 头（04 08）",
                names.count == expectedFiles && headerProblems.isEmpty,
                "文件数 \(names.count)（期望 \(expectedFiles)）\n" + headerProblems.joined(separator: "\n"))

        r.check("M-L1-\(tag)-RT",
                "\(tag) 的 \(names.count) 个真实数据文件全部解析且往返字节完全相同",
                !names.isEmpty && roundTripProblems.isEmpty,
                roundTripProblems.joined(separator: "\n"))

        // 结构：System 的类名 + 用语表形状（XP words 扁平 20 / VX terms 扁平 33）
        var structureDetail: [String] = []
        var structureOK = false
        if let system = documentInRepo("\(base)/System.\(ext)") {
            let className = system.root.className ?? "-"
            let terms = system.root.ivar(named: termsField)?.record
            let flatStrings = terms?.ivars.allSatisfy { $0.value.stringValue != nil } ?? false
            structureOK = className == "RPG::System"
                && terms?.className.name == termsClass
                && terms?.ivars.count == termsCount
                && flatStrings
            structureDetail.append("System 类=\(className) 用语表=\(terms?.className.name ?? "-") ivar=\(terms?.ivars.count ?? -1) 全字符串=\(flatStrings)")
        } else {
            structureDetail.append("读不到 System.\(ext)")
        }

        var mapOK = false
        if let mapDoc = documentInRepo("\(base)/Map001.\(ext)") {
            let map = RGSSMapData(mapDoc.root)
            let table = map?.table
            mapOK = mapDoc.root.className == "RPG::Map"
                && table?.dimension == 3
                && table?.xSize == mapSize.x
                && table?.ySize == mapSize.y
                && table?.zSize == mapSize.z
                && table?.values.count == mapSize.n
            structureDetail.append("Map001 类=\(mapDoc.root.className ?? "-") Table=dim\(table?.dimension ?? -1) \(table?.xSize ?? -1)x\(table?.ySize ?? -1)x\(table?.zSize ?? -1) n=\(table?.values.count ?? -1)")
        } else {
            structureDetail.append("读不到 Map001.\(ext)")
        }
        r.check("M-L1-\(tag)-STRUCT",
                "\(tag) 的 RPG::System / \(termsClass) / RPG::Map / Table 结构解析正确",
                structureOK && mapOK,
                structureDetail.joined(separator: "\n"))

        // 事件层：如实断言为空（不做"提取到 N 条对话"的假断言）
        var emptyDetail: [String] = ["事件指令参数条目 \(eventEntries) 条"]
        var emptyOK = eventEntries == 0
        if let mapDoc = documentInRepo("\(base)/Map001.\(ext)") {
            let count = mapDoc.root.ivar(named: "events")?.hashPairs?.count ?? -1
            emptyDetail.append("Map001 @events 哈希 \(count) 个")
            emptyOK = emptyOK && count == 0
        }
        r.check("M-L1-\(tag)-EMPTY",
                "\(tag) 真实样本事件层为空（\(eventEntries) 条事件指令文本、@events 为 0）",
                emptyOK,
                emptyDetail.joined(separator: "\n"))

        // 数据库层：真实样本确实有文本，精确条数作为回归基线
        let actorEntries = documentInRepo("\(base)/Actors.\(ext)")?.textEntries() ?? []
        let nonEmptyActors = actorEntries.filter { $0.path.hasSuffix(".name") && !($0.text ?? "").isEmpty }
        r.check("M-L1-\(tag)-DB",
                "\(tag) 数据库层有真文本：\(nonEmptyActors.count) 个角色名非空、全工程 \(totalEntries) 条",
                nonEmptyActors.count == expectedActors && totalEntries == expectedEntries,
                "角色名 \(nonEmptyActors.count)（期望 \(expectedActors)），总条目 \(totalEntries)（期望 \(expectedEntries)）")
    }

    // MARK: - M-L1-VXA 真实 VX Ace 样本
    //
    // Fixtures/rmvxace-real 是 CC0-1.0 的真实 1.02 工程。它与 XP / VX 两份不同：
    // 事件层不是空壳（Map001 有事件，全工程 236 条 101/401 对话文本），
    // 所以这里除结构与往返外，还能断言"真实对话路径"。
    //
    // 顺带回归一个只有真实 Ace 数据才有的怪癖：Armors / Classes / Enemies / States /
    // Weapons / Skills 里的 Float，长度比 %0.17g 文本多 3 字节（文本后有 NUL + 2 字节），
    // MRI 用 strtod 解析所以照读不误。见 Fixtures/rmvxace-real/PROVENANCE.md。

    static func realVXAceSample(_ r: Reporter) {
        let base = "Fixtures/rmvxace-real/Data"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pathInRepo(base).path))?
            .filter { $0.hasSuffix(".rvdata2") }.sorted() ?? []

        var headerProblems: [String] = []
        var roundTripProblems: [String] = []
        var totalEntries = 0
        var eventEntries = 0
        var nonUTF8Entries = 0
        var undeclaredEntries = 0

        for name in names {
            let url = pathInRepo("\(base)/\(name)")
            guard let data = try? Data(contentsOf: url) else {
                headerProblems.append("\(name): 读不到")
                continue
            }
            if data.count < 2 || data[0] != 0x04 || data[1] != 0x08 {
                headerProblems.append("\(name): 头不是 04 08，实际 \(hexString(data.prefix(2)))")
            }
            do {
                let doc = try RGSSDocument.load(url: url)
                if try doc.serialize() != doc.source { roundTripProblems.append("\(name): 往返字节不一致") }
                let entries = doc.textEntries()
                totalEntries += entries.count
                eventEntries += entries.filter { $0.path.contains(".list[") }.count
                nonUTF8Entries += entries.filter { $0.encoding != .utf8 }.count
                // 实测：RGSS3 只给含非 ASCII 的字符串写 :E => true，纯 ASCII 的短串没有。
                // 所以"缺 :E"本身不是错，缺 :E 却不是纯 ASCII 才是。
                undeclaredEntries += entries.filter {
                    $0.declared != .flag(true) && !$0.raw.allSatisfy { $0 < 0x80 }
                }.count
            } catch {
                roundTripProblems.append("\(name): \(error)")
            }
        }

        r.check("M-L1-VXA-HEADER",
                "VXA 的 \(names.count) 个 Data/*.rvdata2 都是 Marshal 4.8 头（04 08）",
                names.count == 27 && headerProblems.isEmpty,
                "文件数 \(names.count)（期望 27）\n" + headerProblems.joined(separator: "\n"))

        r.check("M-L1-VXA-RT",
                "VXA 的 \(names.count) 个真实数据文件全部解析且往返字节完全相同",
                !names.isEmpty && roundTripProblems.isEmpty,
                roundTripProblems.joined(separator: "\n"))

        // 结构：System 的用语表是**容器形态**（4 个数组），不是 VX 的 33 个扁平字符串
        var structureDetail: [String] = []
        var termsOK = false
        if let system = documentInRepo("\(base)/System.rvdata2") {
            let className = system.root.className ?? "-"
            let terms = system.root.ivar(named: "terms")?.record
            var counts: [String: Int] = [:]
            for ivar in terms?.ivars ?? [] {
                let key = ivar.name.name.hasPrefix("@")
                    ? String(ivar.name.name.dropFirst()) : ivar.name.name
                counts[key] = ivar.value.arrayElements?.count
                    ?? ivar.value.hashPairs?.count ?? -1
            }
            let expected = ["basic": 8, "params": 8, "etypes": 5, "commands": 24]
            termsOK = className == "RPG::System"
                && terms?.className.name == "RPG::System::Terms"
                && counts == expected
            structureDetail.append("System 类=\(className) 用语表=\(terms?.className.name ?? "-") "
                + "容器=\(counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        } else {
            structureDetail.append("读不到 System.rvdata2")
        }

        var mapOK = false
        if let mapDoc = documentInRepo("\(base)/Map001.rvdata2") {
            let map = RGSSMapData(mapDoc.root)
            let table = map?.table
            mapOK = mapDoc.root.className == "RPG::Map"
                && table?.dimension == 3
                && table?.xSize == 17
                && table?.ySize == 13
                && table?.zSize == 4
                && table?.values.count == 884
            structureDetail.append("Map001 类=\(mapDoc.root.className ?? "-") "
                + "Table=dim\(table?.dimension ?? -1) \(table?.xSize ?? -1)x\(table?.ySize ?? -1)x\(table?.zSize ?? -1) n=\(table?.values.count ?? -1)")
        } else {
            structureDetail.append("读不到 Map001.rvdata2")
        }
        r.check("M-L1-VXA-STRUCT",
                "VXA 的 RPG::System / RPG::System::Terms（4 个容器）/ RPG::Map / Table 结构解析正确",
                termsOK && mapOK,
                structureDetail.joined(separator: "\n"))

        // 事件层：这份样本**不是**空壳，236 条事件指令文本，Map001 有 1 个事件
        var eventDetail: [String] = ["事件指令参数条目 \(eventEntries) 条（期望 236）"]
        var eventOK = eventEntries == 236
        if let mapDoc = documentInRepo("\(base)/Map001.rvdata2") {
            let count = RGSSMapData(mapDoc.root)?.events.count ?? -1
            eventDetail.append("Map001 @events \(count) 个（期望 1）")
            eventOK = eventOK && count == 1
        }
        r.check("M-L1-VXA-EVENTS",
                "VXA 真实样本事件层非空：\(eventEntries) 条对话/指令文本，Map001 有 1 个事件",
                eventOK,
                eventDetail.joined(separator: "\n"))

        // 数据库层：全工程 1463 条，10 个角色名非空
        let actorEntries = documentInRepo("\(base)/Actors.rvdata2")?.textEntries() ?? []
        let nonEmptyActors = actorEntries.filter { $0.path.hasSuffix(".name") && !($0.text ?? "").isEmpty }
        r.check("M-L1-VXA-DB",
                "VXA 数据库层有真文本：\(nonEmptyActors.count) 个角色名非空、全工程 \(totalEntries) 条",
                nonEmptyActors.count == 10 && totalEntries == 1463,
                "角色名 \(nonEmptyActors.count)（期望 10），总条目 \(totalEntries)（期望 1463）")

        // 编码：RGSS3 一律 UTF-8 且带 :E => true
        r.check("M-L1-VXA-ENC",
                "VXA 的 \(totalEntries) 条文本全部判定为 UTF-8；缺 :E 的 11 条都是纯 ASCII",
                totalEntries > 0 && nonUTF8Entries == 0 && undeclaredEntries == 0,
                "非 UTF-8 \(nonUTF8Entries) 条，缺 :E 且不是纯 ASCII \(undeclaredEntries) 条")

        // 浮点怪癖回归：这 6 个文件当初直接 badNumber
        let floatFiles = ["Armors", "Classes", "Enemies", "States", "Weapons", "Skills"]
        var floatProblems: [String] = []
        var quirks = 0
        var sampleDetail = "未找到带尾随字节的 Float"
        for name in floatFiles {
            guard let doc = documentInRepo("\(base)/\(name).rvdata2") else {
                floatProblems.append("\(name): 解析失败")
                continue
            }
            var floats: [MarshalFloat] = []
            collectFloats(doc.root, into: &floats)
            let quirky = floats.filter { ($0.rawBytes?.count ?? 0) > $0.text.utf8.count }
            quirks += quirky.count
            if quirky.isEmpty { floatProblems.append("\(name): \(floats.count) 个 Float 里没有带尾随字节的") }
            if name == "Armors", let first = quirky.first {
                sampleDetail = "Armors 里 \(quirky.count)/\(floats.count) 个 Float 带尾随字节，"
                    + "例：\(first.text)（\(first.value)）线上 \(first.rawBytes?.count ?? -1) 字节"
            }
        }
        r.check("M-L1-VXA-FLOAT",
                "RGSS3 浮点的尾随字节被原样保留（6 个含 Float 的文件都能解析并往返）",
                floatProblems.isEmpty,
                (floatProblems + [sampleDetail]).joined(separator: "\n"))

        // Game.ini：真实 VX Ace 写的是 Library=System\RGSS301.dll。
        // 注意 EngineDetector 的 needle 是 "Library=RGSS3"，子串**不命中**这一行
        // （中间隔着 "System\"）；这份工程能被认出来靠的是 Data/*.rvdata2 那条证据。
        let ini = (try? String(contentsOf: pathInRepo("Fixtures/rmvxace-real/Game.ini"), encoding: .utf8)) ?? ""
        let hasLibraryLine = ini.contains("Library=System\\RGSS301.dll")
        let needleHits = ini.contains("Library=RGSS3")
        r.check("M-L1-VXA-GAMEINI",
                "VXA 的 Game.ini 写的是 Library=System\\RGSS301.dll（Library=RGSS3 这个 needle 不命中，检测靠 Data/*.rvdata2）",
                hasLibraryLine && !needleHits && ini.contains("RTP=RPGVXAce"),
                "Library 行=\(hasLibraryLine) needle 命中=\(needleHits)")
    }

    /// 深度优先收集 Float（对象表可能有环，限深）。
    static func collectFloats(_ value: MarshalValue, into out: inout [MarshalFloat], depth: Int = 0) {
        if case .float(let float) = value.kind { out.append(float) }
        guard depth < 32 else { return }
        for ivar in value.record?.ivars ?? [] { collectFloats(ivar.value, into: &out, depth: depth + 1) }
        for element in value.arrayElements ?? [] { collectFloats(element, into: &out, depth: depth + 1) }
        for pair in value.hashPairs ?? [] { collectFloats(pair.value, into: &out, depth: depth + 1) }
    }

    /// OpenXP 的 Game.ini 写的是 Library=RGSS104E.dll，而 EngineDetector 的 needle 是
    /// "Library=RGSS1" —— 子串命中，所以这份样本可直接当 XP 识别正例（不需要改检测代码）。
    static func realGameIni(_ r: Reporter) {
        let url = pathInRepo("Fixtures/rmxp-real/Game.ini")
        let ini = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        r.check("M-L1-GAMEINI",
                "OpenXP 的 Game.ini 是 Library=RGSS104E.dll，且包含 EngineDetector 的 needle Library=RGSS1",
                ini.contains("Library=RGSS104E.dll") && ini.contains("Library=RGSS1"),
                "实际内容: \(ini.replacingOccurrences(of: "\n", with: " | "))")
    }

    // MARK: - M-L2 合成样本（文本路径 / 编码 / 边界）

    struct FixtureSpec {
        let dir: String
        let ext: String
        let encoding: RGBSTextEncoding
        let tag: String
        /// 用语表探针路径：三版本形状不同（XP words 扁平、VX terms 扁平、VXAce terms 容器）
        let termsPath: String
        let termsValue: String
        let commandPath: String
        let commandValue: String
        let systemCount: Int
        let itemsCount: Int
        let mapCount: Int
    }

    static let fixtures: [FixtureSpec] = [
        FixtureSpec(dir: "rmxp", ext: "rxdata", encoding: .shiftJIS, tag: "RGSS1",
                    termsPath: "system.words.gold", termsValue: "ゴールド",
                    commandPath: "system.words.attack", commandValue: "攻撃",
                    systemCount: 22, itemsCount: 16, mapCount: 10),
        FixtureSpec(dir: "rmvx", ext: "rvdata", encoding: .shiftJIS, tag: "RGSS2",
                    termsPath: "system.terms.level_a", termsValue: "レベル",
                    commandPath: "system.terms.fight", commandValue: "戦う",
                    systemCount: 35, itemsCount: 16, mapCount: 10),
        FixtureSpec(dir: "rmvxace", ext: "rvdata2", encoding: .utf8, tag: "RGSS3",
                    termsPath: "system.terms.basic[0]", termsValue: "レベル",
                    commandPath: "system.terms.commands[" + String(UnicodeScalar(34)) + "fight" + String(UnicodeScalar(34)) + "]",
                    commandValue: "戦う",
                    systemCount: 44, itemsCount: 20, mapCount: 11)
    ]

    static let fixtureFiles = ["Actors", "Items", "CommonEvents", "Troops", "MapInfos", "Map001", "System", "Scripts"]

    static func synthesizedFixtures(_ r: Reporter) {
        for spec in fixtures {
            let base = "Fixtures/\(spec.dir)/Data"
            var problems: [String] = []
            var docs: [String: RGSSDocument] = [:]
            for name in fixtureFiles {
                let relative = "\(base)/\(name).\(spec.ext)"
                guard FileManager.default.fileExists(atPath: pathInRepo(relative).path) else {
                    problems.append("缺少 \(name).\(spec.ext)")
                    continue
                }
                do {
                    let doc = try RGSSDocument.load(url: pathInRepo(relative))
                    docs[name] = doc
                    if try doc.serialize() != doc.source {
                        problems.append("\(name): 往返字节不一致")
                    }
                } catch {
                    problems.append("\(name): 解析失败 \(error)")
                }
            }
            r.check("M-L2-RT-\(spec.tag)",
                    "\(spec.dir) 的 8 个合成文件解析后序列化字节完全相同",
                    problems.isEmpty,
                    problems.joined(separator: "\n"))

            // 事件指令：101/401/102/402/404/405 的路径与文本
            let mapDoc = docs["Map001"]
            let mapEntries = mapDoc?.textEntries() ?? []
            let dialogue = mapEntries.first { $0.path == "maps[1].events[1].pages[0].list[1].parameters[0]" }
            let dialogue2 = mapEntries.first { $0.path == "maps[1].events[1].pages[0].list[2].parameters[0]" }
            let choice0 = mapEntries.first { $0.path == "maps[1].events[1].pages[0].list[3].parameters[0][0]" }
            let choice1 = mapEntries.first { $0.path == "maps[1].events[1].pages[0].list[3].parameters[0][1]" }
            let branch1 = mapEntries.first { $0.path == "maps[1].events[1].pages[0].list[4].parameters[1]" }
            let branch2 = mapEntries.first { $0.path == "maps[1].events[1].pages[0].list[5].parameters[1]" }
            let scroll = mapEntries.first { $0.path == "maps[1].events[1].pages[1].list[2].parameters[0]" }
            r.check("M-L2-EVENT-\(spec.tag)",
                    "\(spec.dir) 101/401 对话、102/402 选项、405 滚动文本路径与内容正确",
                    dialogue?.text == "旅の人？　この村は初めてかい？"
                        && dialogue2?.text == "ようこそ、始まりの村へ。"
                        && choice0?.text == "はい"
                        && choice1?.text == "いいえ"
                        && branch1?.text == "はい"
                        && branch2?.text == "いいえ"
                        && scroll?.text == "（村人は遠くを見つめている）",
                    "dialogue=\(dialogue?.text ?? "nil")\nchoice=\(choice0?.text ?? "nil")/\(choice1?.text ?? "nil")\nbranch=\(branch1?.text ?? "nil")/\(branch2?.text ?? "nil")\nscroll=\(scroll?.text ?? "nil")\n实际路径 \(mapEntries.map { $0.path })")

            // 指令码序列：验证解析出的 EventCommand 结构，而不只是文本
            var codes: [Int] = []
            if let map = mapDoc.flatMap({ RGSSMapData($0.root) }) {
                codes = map.events.first?.event.pages[0].commands.map { $0.code } ?? []
            }
            r.check("M-L2-CODES-\(spec.tag)",
                    "\(spec.dir) Map001 第一页指令码序列为 101,401,401,102,402,402,404,0",
                    codes == [101, 401, 401, 102, 402, 402, 404, 0],
                    "实际 \(codes)")

            // 用语表：三版本形状不同，各自按真实字段名断言
            let systemEntries = docs["System"]?.textEntries() ?? []
            let title = systemEntries.first { $0.path == "system.game_title" }
            let terms = systemEntries.first { $0.path == spec.termsPath }
            let command = systemEntries.first { $0.path == spec.commandPath }
            r.check("M-L2-TERMS-\(spec.tag)",
                    "\(spec.dir) 用语表形状正确（\(spec.termsPath) 与 \(spec.commandPath)）",
                    systemEntries.count == spec.systemCount
                        && terms?.text == spec.termsValue
                        && command?.text == spec.commandValue
                        && (title?.text?.contains("モチボックス") == true || title?.text?.contains("摩奇箱") == true),
                    "条目 \(systemEntries.count)（期望 \(spec.systemCount)）\n\(spec.termsPath)=\(terms?.text ?? "nil")\n\(spec.commandPath)=\(command?.text ?? "nil")")

            // 边界值：空串 / 超长串 / 控制序列 / 混排
            let itemEntries = docs["Items"]?.textEntries() ?? []
            let emptyName = itemEntries.first { $0.path == "items[3].name" }
            let longText = itemEntries.first { $0.path == "items[4].description" }
            let control = itemEntries.first { $0.path == "items[4].name" }
            var edgeOK = itemEntries.count == spec.itemsCount
                && emptyName?.text == ""
                && emptyName?.raw.isEmpty == true
                && (longText?.text?.count ?? 0) > 500
                && (longText?.raw.count ?? 0) > 255
                && control?.text == "\\C[2]毒消し\\C[0]"
            var edgeDetail = "条目 \(itemEntries.count)（期望 \(spec.itemsCount)）空串=\(emptyName?.text ?? "nil") 长串字符=\(longText?.text?.count ?? -1) 长串字节=\(longText?.raw.count ?? -1) 控制序列=\(control?.text ?? "nil")"
            if spec.tag == "RGSS3" {
                let mixed = itemEntries.first { $0.path == "items[5].name" }
                edgeOK = edgeOK && mixed?.text == "测试用アイテムTest"
                edgeDetail += " 混排=\(mixed?.text ?? "nil")"
            }
            r.check("M-L2-EDGE-\(spec.tag)",
                    "\(spec.dir) 边界值：空串保留、超长串（>255 字节）、反斜杠 C 控制序列\(spec.tag == "RGSS3" ? "、中日英混排" : "")",
                    edgeOK, edgeDetail)

            // 编码：全部条目可解码且与版本默认一致
            let allEntries = docs.values.flatMap { $0.textEntries() }
            let undecodable = allEntries.filter { !$0.isDecodable }
            let wrongEncoding = allEntries.filter { $0.encoding != spec.encoding }
            r.check("M-L2-ENC-\(spec.tag)",
                    "\(spec.dir) 全部 \(allEntries.count) 条都能解码且编码判定为 \(spec.encoding.rawValue)",
                    !allEntries.isEmpty && undecodable.isEmpty && wrongEncoding.isEmpty,
                    "解码失败 \(undecodable.map { $0.path })\n编码不符 \(wrongEncoding.map { "\($0.path)=\($0.encoding.rawValue)" })")

            // 计数：Actors 6、Map001、System 的条数作为回归基线
            let actorEntries = docs["Actors"]?.textEntries() ?? []
            r.check("M-L2-COUNT-\(spec.tag)",
                    "\(spec.dir) Actors 6 条、Map001 \(spec.mapCount) 条、System \(spec.systemCount) 条",
                    actorEntries.count == 6 && mapEntries.count == spec.mapCount && systemEntries.count == spec.systemCount,
                    "Actors=\(actorEntries.count) Map001=\(mapEntries.count) System=\(systemEntries.count)")

            // Table + 事件结构
            let map = mapDoc.flatMap { RGSSMapData($0.root) }
            let table = map?.table
            r.check("M-L2-TABLE-\(spec.tag)",
                    "\(spec.dir) Map001 的 Table 解出 dim=3 20x15x1 共 300 值，事件 1 个 2 页",
                    table?.dimension == 3 && table?.xSize == 20 && table?.ySize == 15
                        && table?.zSize == 1 && table?.values.count == 300
                        && map?.events.count == 1 && map?.events.first?.event.pages.count == 2,
                    "dim=\(table?.dimension ?? -1) \(table?.xSize ?? -1)x\(table?.ySize ?? -1)x\(table?.zSize ?? -1) values=\(table?.values.count ?? -1) events=\(map?.events.count ?? -1)")

            let mapInfos = docs["MapInfos"]?.textEntries() ?? []
            r.check("M-L2-MAPINFO-\(spec.tag)",
                    "\(spec.dir) MapInfos（真实形态是哈希）提取到两个地图名",
                    mapInfos.contains { $0.path == "map_infos[1].name" && $0.text == "始まりの村" }
                        && mapInfos.contains { $0.path == "map_infos[2].name" && $0.text == "村はずれの森" },
                    mapInfos.map { "\($0.path)=\($0.text ?? "nil")" }.joined(separator: "\n"))

            let scriptEntries = docs["Scripts"]?.textEntries() ?? []
            r.check("M-L2-SCRIPTS-\(spec.tag)",
                    "\(spec.dir) Scripts 能解析、往返相同、不产生翻译条目",
                    docs["Scripts"] != nil && scriptEntries.isEmpty,
                    "条目数 \(scriptEntries.count)")
        }
    }

    // MARK: - M-ENC 编码判定

    static func encodingResolution(_ r: Reporter) {
        let jp = "日本語のテキスト"
        r.check("M-ENC-01",
                "CP932 能往返日文，且拒绝表达不了的中文",
                RGBSTextEncoding.shiftJIS.encode(jp).flatMap { RGBSTextEncoding.shiftJIS.decode($0) } == jp
                    && RGBSTextEncoding.shiftJIS.encode("测试中文") == nil,
                "往返=\(RGBSTextEncoding.shiftJIS.encode(jp).flatMap { RGBSTextEncoding.shiftJIS.decode($0) } ?? "nil") 中文编码=\(String(describing: RGBSTextEncoding.shiftJIS.encode("测试中文")))")

        r.check("M-ENC-02",
                "detect 把 UTF-8 字节判成 UTF-8、CP932 字节判成 Shift_JIS",
                RGBSTextEncoding.detect(Data(jp.utf8), preferring: .shiftJIS) == .utf8
                    && RGBSTextEncoding.detect(RGBSTextEncoding.shiftJIS.encode(jp)!, preferring: .shiftJIS) == .shiftJIS)

        let xpEntry = documentInRepo("Fixtures/rmxp/Data/Actors.rxdata")?.textEntries().first { $0.path == "actors[1].name" }
        let aceEntry = documentInRepo("Fixtures/rmvxace/Data/Actors.rvdata2")?.textEntries().first { $0.path == "actors[1].name" }

        r.check("M-ENC-03",
                "RGSS1 字符串无 :E ivar 且按 CP932 解出日文（不是 UTF-8）",
                xpEntry?.declared == nil
                    && xpEntry?.node.stringValue?.ivars.isEmpty == true
                    && xpEntry?.encoding == .shiftJIS
                    && xpEntry?.text == "アレン",
                "declared=\(String(describing: xpEntry?.declared)) ivars=\(String(describing: xpEntry?.node.stringValue?.ivars.count)) encoding=\(xpEntry?.encoding.rawValue ?? "nil") text=\(xpEntry?.text ?? "nil")")

        r.check("M-ENC-04",
                "RGSS3 字符串带 :E => true 且按 UTF-8 解出日文",
                aceEntry?.declared == .flag(true)
                    && aceEntry?.node.stringValue?.ivars.isEmpty == false
                    && aceEntry?.encoding == .utf8
                    && aceEntry?.text == "アレン",
                "declared=\(String(describing: aceEntry?.declared)) encoding=\(aceEntry?.encoding.rawValue ?? "nil")")

        do {
            var ok = false
            var detail = "GB18030 编码失败"
            if let bytes = RGBSTextEncoding.gb18030.encode("测试中文") {
                let root = MarshalValue(.object(MarshalRecord(className: MarshalSymbol("RPG::System"), ivars: [
                    MarshalIVar(name: MarshalSymbol("@game_title"),
                                value: MarshalValue(.string(MarshalString(bytes: bytes))))
                ])))
                let data = try MarshalWriter.dump(root)
                let file = RGBSGameFile.detect(fileName: "System.rxdata")!
                let options = RGBSExtractOptions(defaultEncoding: .gb18030, detectEncoding: false)
                let doc = try RGSSDocument(parsing: data, file: file, options: options)
                let entry = doc.textEntries().first
                let before = entry?.text
                try entry?.setText("新的中文")
                let back = try RGSSDocument(parsing: try doc.serialize(), file: file, options: options)
                ok = before == "测试中文" && back.textEntries().first?.text == "新的中文"
                detail = "改前=\(before ?? "nil") 写回后=\(back.textEntries().first?.text ?? "nil")"
            }
            r.check("M-ENC-05", "GB18030 显式编码能解出中文并可原编码写回", ok, detail)
        } catch {
            r.check("M-ENC-05", "GB18030 显式编码能解出中文并可原编码写回", false, "\(error)")
        }
    }

    // MARK: - M-LINK 对象表

    static func sharedObjects(_ r: Reporter) {
        let tableBytes = Data([3, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0,
                               1, 0, 2, 0, 3, 0, 4, 0])
        let shared = MarshalValue(.userDef(MarshalUserDef(className: MarshalSymbol("Table"), bytes: tableBytes)))
        func command(_ code: Int64) -> MarshalValue {
            MarshalValue(.object(MarshalRecord(className: MarshalSymbol("RPG::EventCommand"), ivars: [
                MarshalIVar(name: MarshalSymbol("@code"), value: MarshalValue.integer(code)),
                MarshalIVar(name: MarshalSymbol("@indent"), value: MarshalValue.integer(0)),
                MarshalIVar(name: MarshalSymbol("@parameters"), value: MarshalValue(.array([])))
            ])))
        }
        let page = MarshalValue(.object(MarshalRecord(className: MarshalSymbol("RPG::Event::Page"), ivars: [
            MarshalIVar(name: MarshalSymbol("@list"), value: MarshalValue(.array([command(401)])))
        ])))
        let event = MarshalValue(.object(MarshalRecord(className: MarshalSymbol("RPG::Event"), ivars: [
            MarshalIVar(name: MarshalSymbol("@id"), value: MarshalValue.integer(1)),
            MarshalIVar(name: MarshalSymbol("@pages"), value: MarshalValue(.array([page])))
        ])))
        let map = MarshalValue(.object(MarshalRecord(className: MarshalSymbol("RPG::Map"), ivars: [
            MarshalIVar(name: MarshalSymbol("@data"), value: shared),
            MarshalIVar(name: MarshalSymbol("@another_data"), value: shared),
            MarshalIVar(name: MarshalSymbol("@events"), value: MarshalValue(.hash(MarshalHash(pairs: [
                (key: MarshalValue.integer(1), value: event)
            ]))))
        ])))

        do {
            let data = try MarshalWriter.dump(map)
            let parsed = try MarshalReader.load(data)
            let a = parsed.ivar(named: "data")
            let b = parsed.ivar(named: "another_data")
            let reserialized = try MarshalWriter.dump(parsed)
            r.check("M-LINK-01",
                    "同一 Table 两处引用：解析后是同一实例，序列化字节与原始完全相同（含 @ 链接）",
                    a != nil && b != nil && a === b && reserialized == data,
                    "原始 \(hexString(data.prefix(48)))\n回写 \(hexString(reserialized.prefix(48)))")

            r.check("M-LINK-02",
                    "共享 Table 的结构可读（dim=3 2x2x1 共 4 值）",
                    RGBSTableData.parse(a!)?.dimension == 3
                        && RGBSTableData.parse(a!)?.xSize == 2
                        && RGBSTableData.parse(a!)?.values.count == 4,
                    "\(String(describing: a.map { RGBSTableData.parse($0) }))")

            // 换成一张 1 维 4 元素、内容不同的 Table（dim/x/y/z/count 必须自洽）
            let replacement = Data([1, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0,
                                    7, 0, 8, 0, 9, 0, 10, 0])
            a?.kind = .userDef(MarshalUserDef(className: MarshalSymbol("Table"), bytes: replacement))
            let after = try MarshalWriter.dump(parsed)
            let reparsed = try MarshalReader.load(after)
            let sharedStillShared = reparsed.ivar(named: "data") === reparsed.ivar(named: "another_data")
            let newValues = RGBSTableData.parse(reparsed.ivar(named: "another_data")!)?.values
            r.check("M-LINK-03",
                    "改一处后写回，另一处读到同一份新数据（链接没有退化成两份拷贝）",
                    sharedStillShared && newValues == [7, 8, 9, 10],
                    "stillShared=\(sharedStillShared) another_data values=\(String(describing: newValues))")

            let selfRef = MarshalValue(.array([]))
            selfRef.kind = .array([selfRef])
            let selfData = try MarshalWriter.dump(selfRef)
            let selfBack = try MarshalReader.load(selfData)
            let selfAgain = try MarshalWriter.dump(selfBack)
            r.check("M-LINK-04",
                    "自引用数组（a << a）能解析且往返字节相同",
                    selfBack.arrayElements?.first === selfBack && selfAgain == selfData,
                    hexString(selfData))
        } catch {
            r.check("M-LINK-01", "对象表链接用例", false, "\(error)")
        }
    }

    // MARK: - M-WB 写回

    static func writeBack(_ r: Reporter) {
        for (dir, ext, tag) in [("rmxp", "rxdata", "RGSS1"), ("rmvxace", "rvdata2", "RGSS3")] {
            let relative = "Fixtures/\(dir)/Data/Actors.\(ext)"
            do {
                let doc = try RGSSDocument.load(url: pathInRepo(relative))
                guard let entry = doc.textEntries().first(where: { $0.path == "actors[1].name" }) else {
                    r.check("M-WB-\(tag)", "\(dir) 写回", false, "找不到 actors[1].name")
                    continue
                }
                let original = entry.text ?? ""
                try entry.setText("テスト名")
                let modified = try doc.serialize()
                let file = RGBSGameFile.detect(fileName: "Actors.\(ext)")!
                let reloaded = try RGSSDocument(parsing: modified, file: file)
                let newEntry = reloaded.textEntries().first { $0.path == "actors[1].name" }
                let newValue = newEntry?.text
                let untouched = reloaded.textEntries().first { $0.path == "actors[1].description" }?.text
                try newEntry?.setText(original)
                let restored = try reloaded.serialize()
                r.check("M-WB-\(tag)",
                        "\(dir) 改 actors[1].name 后重解析得新值、其它字段不变、改回后字节完全还原",
                        modified != doc.source
                            && newValue == "テスト名"
                            && untouched?.contains("主人公") == true
                            && restored == doc.source,
                        "新值=\(newValue ?? "nil") 描述=\(untouched ?? "nil") 还原=\(restored == doc.source)")
            } catch {
                r.check("M-WB-\(tag)", "\(dir) 写回", false, "\(error)")
            }
        }

        do {
            let doc = try RGSSDocument.load(url: pathInRepo("Fixtures/rmxp/Data/Actors.rxdata"))
            let entry = doc.textEntries().first { $0.path == "actors[1].name" }
            var threw = false
            do {
                try entry?.setText("测试中文")
            } catch {
                threw = true
            }
            r.check("M-WB-CP932",
                    "CP932 样本里写入中文抛错且原值不被改动（不静默写问号）",
                    threw && entry?.text == "アレン",
                    "抛错=\(threw) 现值=\(entry?.text ?? "nil")")
        } catch {
            r.check("M-WB-CP932", "CP932 写中文必须失败", false, "\(error)")
        }
    }

    // MARK: - M-BAD 畸形输入

    static func malformedInputs(_ r: Reporter) {
        let cases: [(String, Data)] = [
            ("空数据", Data()),
            ("只有头", Data([0x04, 0x08])),
            ("坏头", Data([0x04, 0x09, 0x69, 0x06])),
            ("未知类型", Data([0x04, 0x08, 0x99])),
            ("截断字符串", Data([0x04, 0x08, 0x22, 0x50])),
            ("数组长度过亿", Data([0x04, 0x08, 0x5b, 0x04, 0xff, 0xff, 0xff, 0x7f])),
            ("对象链接越界", Data([0x04, 0x08, 0x40, 0x20])),
            ("符号链接越界", Data([0x04, 0x08, 0x3b, 0x20])),
            ("Bignum word 数过大", Data([0x04, 0x08, 0x6c, 0x2b, 0x04, 0xff, 0xff, 0xff, 0x7f]))
        ]
        var survivors: [String] = []
        for (name, data) in cases {
            do {
                _ = try MarshalReader.load(data)
                survivors.append("\(name) 没有报错")
            } catch {
                continue
            }
        }
        r.check("M-BAD-01", "9 种畸形输入全部返回错误（不崩、不静默成功）",
                survivors.isEmpty, survivors.joined(separator: "\n"))

        var deep = Data([0x04, 0x08])
        deep.append(contentsOf: [UInt8](repeating: 0x5b, count: 5000))
        deep.append(contentsOf: [UInt8](repeating: 0x06, count: 5000))
        var depthError = false
        do {
            _ = try MarshalReader.load(deep)
        } catch let error as MarshalError {
            depthError = error.kind == .depthExceeded
        } catch {
            depthError = false
        }
        r.check("M-BAD-02", "5000 层嵌套返回 depthExceeded（不栈溢出）", depthError)
    }
}
