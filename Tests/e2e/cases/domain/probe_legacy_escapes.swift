//
//  probe_legacy_escapes.swift
//  MochiBox · E2E 领域层探针（RPG Maker 经典引擎文本控制码）
//
//  覆盖 D22：Sources/Domain/LegacyEscapeCodec.swift 的五条契约 ——
//   · 真实语料（EasyRPG TestGame-2000/Map0001.lmu 经 lcf2xml 转出的消息串）里的
//     \c[n] / \s[n] / \n[n] / \v[n] / \$ / \! 一条不漏地进非 text token；
//   · 边界：空串、只有控制码、\\ 字面反斜杠、\\c[12] 多位数、未知 \\z、串尾裸 \\、
//     \\c[12 未闭合、\\s 不带 [n]、0x00–0x1F/0x7F 控制字节、CRLF；
//   · 往返：tokenize → translatableSegments → reassemble(原样) 逐字符且逐 UTF-8 字节相等；
//   · 保护：改 id / 丢替换符 / 凭空多出控制码都必须被 validateControlCodesPreserved 报出，
//     正常回填不许误报；
//   · 家族独立：\\G/\\I[5] 只属 RGSS，\\$/\\_ 只属 2k，\\C[n] 两族都认（EasyRPG 源码实证）。
//
//  期望值一律来自引擎源码（/tmp/lcf-probe/player/src/window_message.cpp:586-712、
//  pending_message.cpp:149-170）与真实语料，不是"跑出来是什么就写什么"。
//

import Foundation

@main
struct LegacyEscapeProbe {

    static func main() {
        let args = ProbeArgs()
        switch args.only {
        case "", "D22": d22()
        default: TAP.ok("probe", "未知 --only 参数", false, "only=\(args.only)")
        }
        exit(TAP.finish())
    }

    // MARK: - 语料

    /// EasyRPG TestGame-2000/Map0001.lmu（lcf2xml 转出）里的真实消息串，逐字节搬运。
    static let corpus: [(String, String)] = [
        ("speed20", "\\s[20]Cras\\s[8] in lorem\\s[1] mi. "),
        ("mixedCase", "\\>\\C[4]1234\\C[0]\\<\\S[5]\\V[0003] \\..\\..\\..\\|\\^"),
        ("nestedSub", "\\N[\\v[0009]]"),
        ("repeatName", "\\n[0] \\n[0] \\n[0] \\n[0] \\n[0] \\n[0] \\n[0] \\n[0]"),
        ("colorFloat", "\\c[3.1415]Test"),
        ("colorPadded", "\\c[0001]Test"),
        ("varNegative", "\\v[-0003]"),
        ("nameLetter", "\\n[a]"),
        ("escapedBackslashRun", "\\\\ \\\\ \\\\ \\\\"),
        ("tripleBackslash", "\\\\\\"),
        ("pipes", "\\|1\\|2\\|3"),
        ("plain", "Testing message speed:"),
        ("lineBreakTail", "\\s[20]Cras\\s[8] in lorem\\s[1] mi.\n")
    ]

    static let edges: [String] = [
        "",
        "\\c[3]",
        "abc\\",
        "あ\\zい",
        "A\u{0A}B",
        "\\c[12",
        "\\s abc",
        "\\N[\\v[0009]]"
    ]

    // MARK: - D22

    static func d22() {
        corpusCodes()
        boundaries()
        roundTrip()
        protection()
        families()
        tailByteTrap()
        segmentBridge()
        assemblerParity()
        engineFamilies()
        validationDispatch()
    }

    /// 真实语料里的控制码/替换符条数（数错一条 = 那条码会裸奔进翻译队列）。
    static func corpusCodes() {
        let expected: [(String, Int)] = [
            ("\\s[20]Cras\\s[8] in lorem\\s[1] mi. ", 3),
            // \\> \\C[4] \\C[0] \\< \\S[5] \\V[0003] \\. ×3 \\| \\^ = 11
            ("\\>\\C[4]1234\\C[0]\\<\\S[5]\\V[0003] \\..\\..\\..\\|\\^", 11),
            ("\\N[\\v[0009]]", 1),
            ("\\n[0] \\n[0] \\n[0] \\n[0]", 4)
        ]
        for (index, entry) in expected.enumerated() {
            let tokens = LegacyEscapeCodec.tokenize(entry.0, family: .rm2k)
            let codes = tokens.filter { !$0.kind.isText }.count
            TAP.ok("D22.1", "语料第 \(index + 1) 条的控制码/替换符条数 = \(entry.1)",
                   codes == entry.1, "实际 \(codes)：\(dump(tokens))")
        }
        // 2000 工程里的大写 \\C / \\S / \\V 必须被识别（EasyRPG window_message.cpp 两种大小写都认）
        TAP.ok("D22.1", "大写 \\C[4] 在 2k 语料里被识别为控制码",
               LegacyEscapeCodec.tokenize("\\C[4]1234", family: .rm2k).first?.kind == .control("C"),
               dump(LegacyEscapeCodec.tokenize("\\C[4]1234", family: .rm2k)))
        // 嵌套括号按配平算：\\N[\\v[0009]] 是一个替换符，不是 "\\N[\\v[0009]" + "]"
        let nested = LegacyEscapeCodec.tokenize("\\N[\\v[0009]]", family: .rm2k)
        TAP.ok("D22.1", "嵌套 \\N[\\v[0009]] 整段是一个替换符",
               nested.count == 1 && nested[0].value == "\\N[\\v[0009]]" && nested[0].kind == .substitution("N"),
               dump(nested))
    }

    static func boundaries() {
        TAP.ok("D22.2", "空串 → 0 个 token", LegacyEscapeCodec.tokenize("", family: .rm2k).isEmpty)
        TAP.ok("D22.2", "空串 → 0 个可翻译段", LegacyEscapeCodec.translatableSegments("", family: .rm2k).isEmpty)

        let onlyCode = LegacyEscapeCodec.tokenize("\\c[3]", family: .rm2k)
        TAP.ok("D22.2", "只有控制码：1 个 token、0 个可翻译段",
               onlyCode.count == 1 && !onlyCode[0].kind.isText
                 && LegacyEscapeCodec.translatableSegments("\\c[3]", family: .rm2k).isEmpty,
               dump(onlyCode))

        let literal = LegacyEscapeCodec.tokenize("\\\\", family: .rm2k)
        TAP.ok("D22.2", "\\\\ 是字面反斜杠（单 token，不是转义起点）",
               literal.count == 1 && literal[0].kind == .control("\\") && literal[0].value == "\\\\",
               dump(literal))

        let multiDigit = LegacyEscapeCodec.tokenize("\\c[12]", family: .rm2k)
        TAP.ok("D22.2", "多位数参数 \\c[12] 整体成一个控制码",
               multiDigit.count == 1 && multiDigit[0].value == "\\c[12]", dump(multiDigit))

        let unknown = LegacyEscapeCodec.tokenize("あ\\zい", family: .rm2k)
        TAP.ok("D22.2", "未知转义 \\z 原样保留为文本（不丢字符）",
               unknown.count == 1 && unknown[0].kind == .text && unknown[0].value == "あ\\zい",
               dump(unknown))

        let trailing = LegacyEscapeCodec.tokenize("abc\\", family: .rm2k)
        TAP.ok("D22.2", "串尾裸反斜杠原样保留",
               trailing.count == 1 && trailing[0].value == "abc\\", dump(trailing))

        let unclosed = LegacyEscapeCodec.tokenize("\\c[12", family: .rm2k)
        TAP.ok("D22.2", "\\c[12 未闭合按文本保留",
               unclosed.count == 1 && unclosed[0].value == "\\c[12", dump(unclosed))

        let noArg = LegacyEscapeCodec.tokenize("\\s abc", family: .rm2k)
        TAP.ok("D22.2", "\\s 不带 [n] 不吞后面的正文",
               noArg.count == 1 && noArg[0].value == "\\s abc", dump(noArg))

        let raw = LegacyEscapeCodec.tokenize("A\u{0A}B\u{00}C\u{7F}", family: .rm2k)
        TAP.ok("D22.2", "0x0A/0x00/0x7F 各自成 rawControl，正文不被合并",
               raw.count == 6
                 && raw[0].value == "A"
                 && raw[1].kind == .rawControl(0x0A)
                 && raw[2].value == "B"
                 && raw[3].kind == .rawControl(0x00)
                 && raw[4].value == "C"
                 && raw[5].kind == .rawControl(0x7F),
               dump(raw))

        let crlf = LegacyEscapeCodec.tokenize("A\r\nB", family: .rm2k)
        TAP.ok("D22.2", "CRLF 按标量切成两个 rawControl（不按 grapheme 合并）",
               crlf.count == 4 && crlf[1].kind == .rawControl(0x0D) && crlf[2].kind == .rawControl(0x0A),
               dump(crlf))
    }

    static func roundTrip() {
        var failures: [String] = []
        for (label, raw) in corpus {
            let tokens = LegacyEscapeCodec.tokenize(raw, family: .rm2k)
            let pieces = LegacyEscapeCodec.translatableSegments(raw, family: .rm2k)
            do {
                let rebuilt = try LegacyEscapeCodec.reassemble(tokens, translations: pieces)
                if rebuilt != raw { failures.append("\(label): 字符不等") }
                if Array(rebuilt.utf8) != Array(raw.utf8) { failures.append("\(label): UTF-8 字节不等") }
            } catch {
                failures.append("\(label): 抛错 \(error)")
            }
            if tokens.map({ $0.value }).joined() != raw {
                failures.append("\(label): token.value 拼回不等")
            }
        }
        for raw in edges {
            let tokens = LegacyEscapeCodec.tokenize(raw, family: .rm2k)
            let pieces = LegacyEscapeCodec.translatableSegments(raw, family: .rm2k)
            let rebuilt = (try? LegacyEscapeCodec.reassemble(tokens, translations: pieces)) ?? "<抛错>"
            if rebuilt != raw { failures.append("edge[\(printable(raw))]: 不等") }
        }
        TAP.ok("D22.3", "往返恒等：13 条语料 + \(edges.count) 条边界（字符与 UTF-8 字节）",
               failures.isEmpty, failures.joined(separator: "\n"))

        var mismatch = "no-throw"
        do {
            _ = try LegacyEscapeCodec.reassemble(
                LegacyEscapeCodec.tokenize("\\c[3]あい", family: .rm2k),
                translations: ["あ", "い"]
            )
        } catch let error as MochiBoxError {
            mismatch = error.code.rawValue
        } catch {
            mismatch = "other"
        }
        TAP.eq("D22.3", "译文条数与段数不符 → segment_mismatch", mismatch, "segment_mismatch")
    }

    static func protection() {
        // (a) 模型把 \c[3] 改成 \c[4]
        let a = LegacyEscapeCodec.tokenize("\\c[3]こんにちは", family: .rm2k)
        let badA = "\\c[3]こんにちは\\c[4]"
        TAP.ok("D22.4", "多出 \\c[4] 能被报出",
               !LegacyEscapeCodec.validateControlCodesPreserved(original: a, reassembled: badA, family: .rm2k).isEmpty,
               "未报告：\(printable(badA))")

        // (b) 模型把 \n[1] 当正文翻译掉（替换符消失）
        let b = LegacyEscapeCodec.tokenize("\\n[1]は元気です", family: .rm2k)
        let badB = "太郎は元気です"
        TAP.ok("D22.4", "替换符 \\n[1] 丢失能被报出",
               !LegacyEscapeCodec.validateControlCodesPreserved(original: b, reassembled: badB, family: .rm2k).isEmpty,
               "未报告：\(printable(badB))")

        // (c) id 改动 \v[1] → \v[2]
        let c = LegacyEscapeCodec.tokenize("\\v[1]円", family: .rm2k)
        let problemsC = LegacyEscapeCodec.validateControlCodesPreserved(original: c, reassembled: "\\v[2]円", family: .rm2k)
        TAP.ok("D22.4", "id 被改（\\v[1]→\\v[2]）能被报出", !problemsC.isEmpty, "未报告")
        TAP.ok("D22.4", "报文里同时给出原文与重组后的字面",
               (problemsC.first?.contains("\\v[1]") ?? false) && (problemsC.first?.contains("\\v[2]") ?? false),
               problemsC.joined(separator: " | "))

        // (d) 正常回填不许误报
        let d = LegacyEscapeCodec.tokenize("\\c[3]こんにちは\\c[0]さようなら", family: .rm2k)
        let good = (try? LegacyEscapeCodec.reassemble(d, translations: ["你好", "再见"])) ?? ""
        let problemsD = LegacyEscapeCodec.validateControlCodesPreserved(original: d, reassembled: good, family: .rm2k)
        TAP.ok("D22.4", "正常回填不误报", problemsD.isEmpty, problemsD.joined(separator: " | "))
    }

    static func families() {
        func kinds(_ text: String, _ family: LegacyEscapeFamily) -> [String] {
            return LegacyEscapeCodec.tokenize(text, family: family).map { token -> String in
                switch token.kind {
                case .text: return "text"
                case .substitution(let letter): return "sub:\(letter)"
                case .control(let letter): return "ctl:\(letter)"
                case .rawControl(let byte): return String(format: "raw:%02X", byte)
                }
            }
        }
        TAP.ok("D22.5", "RGSS 认 \\C[3]",
               kinds("\\C[3]あ", .rgss) == ["ctl:C", "text"], "\(kinds("\\C[3]あ", .rgss))")
        TAP.ok("D22.5", "RGSS 不认 \\c[3]（只收官方大写写法）",
               kinds("\\c[3]あ", .rgss) == ["text"], "\(kinds("\\c[3]あ", .rgss))")
        TAP.ok("D22.5", "2k 认小写 \\c[3]",
               kinds("\\c[3]あ", .rm2k) == ["ctl:c", "text"], "\(kinds("\\c[3]あ", .rm2k))")
        TAP.ok("D22.5", "2k 也认大写 \\C[3]（EasyRPG 两种大小写都认）",
               kinds("\\C[3]あ", .rm2k) == ["ctl:C", "text"], "\(kinds("\\C[3]あ", .rm2k))")
        TAP.ok("D22.5", "\\G 只属 RGSS",
               kinds("\\G", .rgss) == ["ctl:G"] && kinds("\\G", .rm2k) == ["text"],
               "rgss=\(kinds("\\G", .rgss)) rm2k=\(kinds("\\G", .rm2k))")
        TAP.ok("D22.5", "\\$ 只属 2k",
               kinds("\\$", .rm2k) == ["ctl:$"] && kinds("\\$", .rgss) == ["text"],
               "rm2k=\(kinds("\\$", .rm2k)) rgss=\(kinds("\\$", .rgss))")
        TAP.ok("D22.5", "\\_ 只属 2k",
               kinds("\\_", .rm2k) == ["ctl:_"] && kinds("\\_", .rgss) == ["text"],
               "rm2k=\(kinds("\\_", .rm2k)) rgss=\(kinds("\\_", .rgss))")
        TAP.ok("D22.5", "\\I[5] 只属 RGSS",
               kinds("\\I[5]", .rgss) == ["ctl:I"] && kinds("\\I[5]", .rm2k) == ["text"],
               "rgss=\(kinds("\\I[5]", .rgss)) rm2k=\(kinds("\\I[5]", .rm2k))")
        TAP.ok("D22.5", "\\N[1] 在 RGSS 是替换符",
               kinds("\\N[1]", .rgss) == ["sub:N"], "\(kinds("\\N[1]", .rgss))")
    }

    /// 0x5C 是 SJIS 的合法尾字节：解码后拿到的 String 里根本没有反斜杠，
    /// 切分自然不该产生控制码。这条钉住"只吃已解码 String"这条约束。
    static func tailByteTrap() {
        let cases: [(String, [UInt8])] = [
            ("ソ", [0x83, 0x5C]),
            ("表", [0x95, 0x5C]),
            ("十", [0x8F, 0x5C]),
            ("予", [0x97, 0x5C])
        ]
        for (expected, bytes) in cases {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let decoded = String(data: Data(bytes), encoding: .shiftJIS) ?? "<解码失败>"
            let tokens = LegacyEscapeCodec.tokenize(decoded, family: .rm2k)
            TAP.ok("D22.6", "SJIS \(hex) 解码后是正文、不产生控制码",
                   decoded == expected && tokens.count == 1 && tokens[0].kind == .text && tokens[0].value == expected,
                   "解码[\(printable(decoded))] tokens=\(dump(tokens))")
        }
    }

    /// 缓存键只认 Segmenter：经典引擎的 token 必须先桥成 Segment 再算键。
    static func segmentBridge() {
        let raw = "\\c[3]こんにちは\\n[1]さようなら"
        let segments = LegacyEscapeCodec.segments(from: LegacyEscapeCodec.tokenize(raw, family: .rm2k))
        TAP.ok("D22.7", "桥接后的段形状 = code/text/code/text",
               segments.map { $0.kind } == [.code, .text, .code, .text],
               "\(segments.map { $0.kind.rawValue })")
        TAP.eq("D22.7", "Segmenter.mapKey 用 U+001F 连接可翻译段",
               Segmenter.mapKey(segments), "こんにちは\u{1F}さようなら")
    }

    /// 与现有 Segmenter 不漂移（touchpoint-map 的三条不变式）：
    ///   1) join(segments) 与原文逐字节相同（只切不改）；
    ///   2) 码值原样（\c[3] 不得被上转成 \C[3]）；
    ///   3) 跳过判据吃剥码后的 mapKey。
    /// 第 1、2 条同时钉住两套回填（Segmenter.reassemble 与 LegacyEscapeCodec.reassemble）
    /// 结果一致，避免"新起一套 join"慢慢漂移。
    static func assemblerParity() {
        var problems: [String] = []
        for (label, raw) in corpus {
            let tokens = LegacyEscapeCodec.tokenize(raw, family: .rm2k)
            let segments = LegacyEscapeCodec.segments(from: tokens)
            if segments.map({ $0.value }).joined() != raw { problems.append("\(label): join ≠ 原文") }
            // 原样译文（= joinForBackend 的结果）回填，两套回填器都必须还原原串
            let viaSegmenter = (try? Segmenter.reassemble(segments: segments, translatedText: Segmenter.joinForBackend(segments))) ?? "<抛错>"
            if viaSegmenter != raw { problems.append("\(label): Segmenter.reassemble ≠ 原文") }
            let viaCodec = (try? LegacyEscapeCodec.reassemble(tokens, translations: LegacyEscapeCodec.translatableSegments(raw, family: .rm2k))) ?? "<抛错>"
            if viaCodec != raw { problems.append("\(label): LegacyEscapeCodec.reassemble ≠ 原文") }
            if viaSegmenter != viaCodec { problems.append("\(label): 两套回填器结果不同") }
            // 码值原样：code 段必须与原文里的那段逐字符相同（不允许大小写折叠）
            let codeValues = segments.filter { $0.kind == .code }.map { $0.value }
            for value in codeValues where !raw.contains(value) {
                problems.append("\(label): 码值被改写 \(value)")
            }
        }
        TAP.ok("D22.8", "Segmenter 与 LegacyEscapeCodec 两套回填对 \(corpus.count) 条语料结果一致",
               problems.isEmpty, problems.joined(separator: "\n"))

        // 小写 \c[3] 过桥后仍是小写（历史坑：asciiUpper 只用于比对，不得改写段值）
        let lower = LegacyEscapeCodec.segments(from: LegacyEscapeCodec.tokenize("\\c[3]あ", family: .rm2k))
        TAP.eq("D22.8", "\\c[3] 过桥后码值原样保留小写",
               lower.first(where: { $0.kind == .code })?.value ?? "<无>", "\\c[3]")

        // 纯码行：只数 text 段，调用侧据此短路（textSegmentCount == 0 就不发请求）
        let onlyBracket = LegacyEscapeCodec.segments(from: LegacyEscapeCodec.tokenize("\\c[1]", family: .rm2k))
        let onlyBare = LegacyEscapeCodec.segments(from: LegacyEscapeCodec.tokenize("\\^", family: .rm2k))
        TAP.eq("D22.8", "纯码行 \\c[1] 的可翻译段数 = 0（调用侧必须短路，否则白发一次请求）",
               String(Segmenter.textSegmentCount(onlyBracket)), "0")
        TAP.eq("D22.8", "纯码行 \\^ 的可翻译段数 = 0", String(Segmenter.textSegmentCount(onlyBare)), "0")
        // 跳过判据吃 mapKey（剥码后）：单字符码落 punctuation，方括号码不落（这就是必须短路的原因）
        TAP.eq("D22.8", "\\^ 走 SkipRules 的 punctuation 跳过",
               SkipRules.skipReason(for: Segmenter.mapKey(onlyBare), enabled: true, minLength: 2) ?? "<需翻译>",
               "punctuation")
        TAP.eq("D22.8", "\\c[1] 不会被 SkipRules 跳过（所以 textSegmentCount==0 必须由调用侧短路）",
               SkipRules.skipReason(for: Segmenter.mapKey(onlyBracket), enabled: true, minLength: 2) ?? "<需翻译>",
               "<需翻译>")

        // 病态输入上的行为差异是**设计**（宽容 vs 严格），钉住免得下一个人"顺手统一"：
        // Segmenter 容忍译文里多出的 U+001F（剔空段再试），codec.reassemble 严格抛错。
        let noisyTokens = LegacyEscapeCodec.tokenize("\\c[3]あ\\c[0]い", family: .rm2k)
        let noisySegments = LegacyEscapeCodec.segments(from: noisyTokens)
        let lenient = (try? Segmenter.reassemble(segments: noisySegments, translatedText: "A\u{1F}B\u{1F}")) ?? "<抛错>"
        let strict = (try? LegacyEscapeCodec.reassemble(noisyTokens, translations: ["A", "B"])) ?? "<抛错>"
        TAP.eq("D22.8", "格式良好时宽容版（Segmenter）与严格版（codec）逐字符相同", lenient, strict)
        var strictThrew = false
        do { _ = try LegacyEscapeCodec.reassemble(noisyTokens, translations: ["A", "B", ""]) } catch { strictThrew = true }
        TAP.ok("D22.8", "多一条空译文：codec 严格抛错（管线不经过它，这是设计）", strictThrew)
    }

    /// 引擎族字符串与骨架分派（接线用）：mvmz 必须逐字节不变，rgss1/2/3 收敛成一个 rgss。
    static func engineFamilies() {
        TAP.eq("D22.9", "EngineKind.mv.family 逐字节仍为 mvmz", EngineKind.mv.family, "mvmz")
        TAP.eq("D22.9", "EngineKind.mz.family 逐字节仍为 mvmz", EngineKind.mz.family, "mvmz")
        TAP.ok("D22.9", "rgss1/2/3 收敛为同一个 rgss",
               EngineKind.rgss1.family == "rgss" && EngineKind.rgss2.family == "rgss" && EngineKind.rgss3.family == "rgss",
               "\(EngineKind.rgss1.family)/\(EngineKind.rgss2.family)/\(EngineKind.rgss3.family)")
        TAP.eq("D22.9", "easyrpg 是独立族", EngineKind.easyrpg.family, "easyrpg")

        // mvmz 走 MV 码表。MV 的表**大小写不敏感且已含 C/N/V/P/X/I**，所以 \\c[3] / \\n[1] 这类
        // 在 mvmz 下本来就被当 code（部分保护）；真正漏的是 \\s[n]（速度）与 \\_（半角空格），
        // 它们才是"接线前老引擎文本会裸奔进翻译队列"的那两个码 —— 这两条断言钉住这个事实。
        let mvColor = LegacyEscapeCodec.skeleton(raw: "\\c[3]あ", engineFamily: EngineKind.mv.family)
        TAP.ok("D22.9", "mvmz 骨架走 MV 码表：\\c[3] 本来就被识别（部分保护）",
               mvColor.map { $0.kind } == [.code, .text], "\(mvColor.map { $0.kind.rawValue })")
        let mvSpeed = LegacyEscapeCodec.skeleton(raw: "\\s[3]あ", engineFamily: EngineKind.mv.family)
        TAP.ok("D22.9", "mvmz 骨架漏 \\s[3]（MV 表没有 S）——这就是必须换族的原因",
               mvSpeed.count == 1 && mvSpeed[0].kind == .text, "\(mvSpeed.map { $0.kind.rawValue })")
        let mvUnder = LegacyEscapeCodec.skeleton(raw: "\\_あ", engineFamily: EngineKind.mv.family)
        TAP.ok("D22.9", "mvmz 骨架漏 \\_（MV 单字符表没有下划线）",
               mvUnder.count == 1 && mvUnder[0].kind == .text, "\(mvUnder.map { $0.kind.rawValue })")
        let legacySpeed = LegacyEscapeCodec.skeleton(raw: "\\s[3]あ", engineFamily: EngineKind.easyrpg.family)
        TAP.ok("D22.9", "easyrpg 骨架把 \\s[3] 切成 code（补上 mvmz 的漏）",
               legacySpeed.map { $0.kind } == [.code, .text], "\(legacySpeed.map { $0.kind.rawValue })")

        let legacy = LegacyEscapeCodec.skeleton(raw: "\\c[3]あ", engineFamily: EngineKind.easyrpg.family)
        TAP.ok("D22.9", "easyrpg 骨架把 \\c[3] 切成 code",
               legacy.map { $0.kind } == [.code, .text], "\(legacy.map { $0.kind.rawValue })")

        let rgss = LegacyEscapeCodec.skeleton(raw: "\\c[3]あ", engineFamily: EngineKind.rgss1.family)
        TAP.ok("D22.9", "rgss 骨架不认小写 \\c[3]（回退成正文）",
               rgss.count == 1 && rgss[0].kind == .text, "\(rgss.map { $0.kind.rawValue })")
    }

    /// 两个校验入口的族分派：mvmz 一律放行（不改变现有行为），legacy 才拦。
    static func validationDispatch() {
        TAP.ok("D22.10", "mvmz：码值被改也不拦（回退旧行为）",
               LegacyEscapeCodec.controlCodeProblems(raw: "\\c[3]あ", reassembled: "\\c[4]あ", engineFamily: "mvmz").isEmpty)
        TAP.ok("D22.10", "easyrpg：码值被改要拦",
               !LegacyEscapeCodec.controlCodeProblems(raw: "\\c[3]あ", reassembled: "\\c[4]あ", engineFamily: "easyrpg").isEmpty)
        TAP.ok("D22.10", "easyrpg：译文文本里混入码要拦",
               !LegacyEscapeCodec.translatedTextProblems("你好\\c[4]", engineFamily: "easyrpg").isEmpty)
        TAP.ok("D22.10", "easyrpg：干净译文放行",
               LegacyEscapeCodec.translatedTextProblems("你好\u{1F}再见", engineFamily: "easyrpg").isEmpty)
        TAP.ok("D22.10", "mvmz：译文里的反斜杠不拦（双端契约不重复判）",
               LegacyEscapeCodec.translatedTextProblems("你好\\c[4]", engineFamily: "mvmz").isEmpty)
        TAP.ok("D22.10", "rgss：小写 \\c[4] 不算码，不拦",
               LegacyEscapeCodec.translatedTextProblems("你好\\c[4]", engineFamily: "rgss").isEmpty)
    }

    // MARK: - 工具

    static func dump(_ tokens: [LegacyEscapeToken]) -> String {
        return tokens.map { token -> String in
            switch token.kind {
            case .text: return "T(\(printable(token.value)))"
            case .substitution(let letter): return "S[\(letter)](\(printable(token.value)))"
            case .control(let letter): return "C[\(letter)](\(printable(token.value)))"
            case .rawControl(let byte): return String(format: "R(0x%02X)", byte)
            }
        }.joined(separator: " ")
    }

    static func printable(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x0C: out += "\\f"
            case 0x00...0x1F, 0x7F: out += String(format: "\\x%02X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
