//
//  LegacyEscapeCodec.swift
//  MochiBox
//
//  RPG Maker 经典引擎（2000/2003 = 2k/2k3；XP/VX/VX Ace = RGSS）的文本控制码编解码。
//  与 Segmenter.swift 是平行的两套码表：MV/MZ 用 \X[..]（见 Segmenter.splitSegments），
//  2k/2k3 用 \c[..] \s[..] \n[..] \v[..] \$ \! 等，RGSS 用 \C[..] \N[..] \V[..] \G 等。
//  纯函数、无副作用；本文件不得 import SwiftUI / AppKit（Scripts/build.sh 的分层门禁）。
//
//  ## 铁律一：只吃"已解码"的 String，绝不吃 Data
//
//  0x5C（反斜杠）是 GBK 与 Shift-JIS 的合法尾字节：
//    · GBK  尾字节范围 0x40–0xFE；
//    · SJIS 尾字节范围 0x40–0xFC（0x7F 除外）。
//  也就是说字节流里的 0x5C 有一半概率是"半个汉字"的尾巴。按字节扫反斜杠，会把
//  「ソ」= 0x83 0x5C、「十」= 0x8F 0x5C 这类字符撕成"控制码起点"，
//  后果是切出来的段在回写时整条文本被改写（漏字 + 假控制码），而且是静默的。
//  所以入口参数一律叫 decodedText：调用方必须先经 LCFTextCodec 把 LCF 里的
//  cp932/cp936 字节解码成 String，再进来。本文件不提供、也不接受 Data 入口。
//  这与 EasyRPG 的做法一致：PendingMessage 的替换是在 UTF-8 解出的字符串上做的
//  （player/src/pending_message.cpp:103-140 逐 code point 走 UTF8Next）。
//
//  ## 铁律二：未知序列一律按文本保留，不吞字符
//
//  \z / \s（不带 [n]）/ 结尾裸 \ / \[ 未闭合 … 全部当普通文本。理由：本组件的职责是
//  "把不可翻译的东西挡在翻译之外"，判错的代价分两档 ——
//    · 多认（把正文当控制码）：那句话不翻译，用户看得见，可逆；
//    · 少认（把控制码当正文）：模型改写它 → 游戏里颜色/速度/换行全乱，不可逆。
//  所以码表往"准"里做（只收引擎真认的），但兜底方向永远是"保留原文"。
//
//  ## 回填器权威：管线里只有 Segmenter.reassemble 那一个
//
//  本文件刻意**不**接管管线回填。legacy 文本的正规路径是：
//    tokenize → segments(from:) → 现有管线（Segmenter.mapKey / cacheKey /
//    Segmenter.reassemble / translatedSegments，全部与 MV/MZ 同一套实现）。
//  理由：SessionController.handleText 与 FullTextController 落地时走的都是 Segmenter
//  那一套，若这里另立一条回填链路，两条链路对同一条译文的接受度就会不同
//  （一个容忍译文里多出的 U+001F，一个直接抛错），而症状是"全文模式下能翻、实时模式下
//  整条丢弃"，极难定位。
//
//  所以本文件提供两样东西，各管一段：
//    · segments(from:)：把 token 桥成 Segment，让 legacy 文本进**现有**管线；
//    · reassemble(_:translations:)：**严格**变体，给手里直接握着 token 的调用方
//      （LCF 写回、单元测试）用 —— 段数不符就抛错，不做"剔空段再试"的噪声清洗。
//    两者在格式良好的输入上结果必须逐字符相同（Tests/e2e 的 D22.8 有平价断言）。
//
//  控制码完整性**不在回填里做**：回填完必须再调 validateControlCodesPreserved，
//  否则"模型把 \c[3] 改成 \c[4]"这类错会静默通过（Segmenter 只保证段数与顺序）。
//
//  ## 码表出处（EasyRPG Player，2026-11 快照）
//
//  替换型（引擎把内容填进去，id 不能改）—— pending_message.cpp:149-170：
//    if (ch == 'N' || ch == 'n')  → 角色名；
//    if (ch == 'V' || ch == 'v')  → 变量值。
//  **两种大小写都认**，这是引擎源码写死的，不是我们的宽容。
//  显示型 —— window_message.cpp:586-712：case 'c': case 'C': / case 's': case 'S':
//  以及 _ $ ! ^ > < . | ，同样两种大小写都认。
//  实测语料也印证：EasyRPG 的 TestGame-2000/Map0001 里就有 2000 工程的消息写着
//    \>\C[4]1234\C[0]\< \S[5]\V[0003] ...
//  （大写 C/S/V）。因此 rm2k 的字母集合大小写两套都收；只收小写会让这条真实的
//  2000 消息里的颜色码裸奔进翻译队列。
//
//  RGSS（XP/VX/VX Ace）只有大写：官方帮助文档与工程里的写法都是 \C[n] \N[n] \V[n] \G，
//  且 RGSS 运行库闭源、拿不到"大小写是否折叠"的一手证据，故按官方写法只收大写 ——
//  码表是数据不是逻辑，日后若拿到 case code.upcase 之类的实证，往集合里加小写即可。
//  RGSS 与 rm2k 的真实差别不在大小写而在字母本身：\G（显示金钱）只有 RGSS 有，
//  \$（显示金钱窗口）、\_（半角空格）只有 2k 有，\I[n]（图标）只有 VX Ace 有。
//
//  ## 控制字节
//
//  0x00–0x1F 与 0x7F 是 EasyRPG 的 Utils::IsControlCharacter（src/utils.h:435-437）。
//  其中 0x0A(LF)/0x0C(FF) 在 window_message.cpp:546-580 里被先于控制字符判定处理成
//  换行/翻页 —— 它们是排版骨架而不是"跳过"，更要原样钉住，故一并算 rawControl。
//  它们按 Unicode.Scalar 逐个判，不按 Character：Swift 里 "\r\n" 是一个 grapheme
//  cluster，按 Character 走会把 CRLF 当普通文本，两种扫描口径就不一致了。
//

import Foundation

// MARK: - 家族

/// 码表家族。只按"文本控制码语法"分，不按引擎版本分：
/// 2k/2k3 是同一套 LCF 语法，XP/VX/VX Ace 是同一套 RGSS 语法。
enum LegacyEscapeFamily: Equatable, Sendable {
    /// RPG Maker 2000 / 2003（LCF，EasyRPG 引擎读的那一套）。
    case rm2k
    /// RPG Maker XP / VX / VX Ace（RGSS1/2/3）。
    case rgss

    /// 由引擎种类取码表家族。认不出（MV/MZ/Ren'Py/…）返回 nil：
    /// 那些引擎的文本走 Segmenter.splitSegments，不该误用本文件的码表。
    init?(engineKind: EngineKind) {
        switch engineKind {
        case .easyrpg: self = .rm2k
        case .rgss1, .rgss2, .rgss3: self = .rgss
        default: return nil
        }
    }

    /// 由缓存键里的引擎族字符串（`EngineKind.family`）取码表家族。
    ///
    /// **只认这两个值**：`"easyrpg"` 与 `"rgss"`。其余（含 `"mvmz"`）一律 nil ——
    /// 管线据此分派，判错方向是"退回 MV 码表"，即保持改动前的行为，不会静默丢码。
    init?(engineFamily: String) {
        switch engineFamily {
        case "easyrpg": self = .rm2k
        case "rgss": self = .rgss
        default: return nil
        }
    }
}

// MARK: - Token

/// 一个文本片段，或一个不可翻译的单元。
struct LegacyEscapeToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 可翻译正文。
        case text
        /// 引擎替换型：\n[id] \v[id] \N[n] \V[n]。内容由引擎填，id 绝不能改。
        case substitution(String)
        /// 显示期控制码：\c[n] \s[n] \_ \$ \! \^ \> \< \. \| \\ 等。
        case control(String)
        /// 原始控制字节 0x00–0x1F / 0x7F（含换行 LF、翻页 FF）。
        case rawControl(UInt8)

        var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    /// substitution / control 的 payload 是码字母原样（"c" / "C" / "_"；字面反斜杠的
    /// 字母就是反斜杠本身），保留大小写便于日志与双端对账。
    /// 参数（id）在 value 里原样保存，校验时按整串比：\\c[3] 与 \\c[03] 也算不同。
    let kind: Kind
    /// 原始字面：text 段是原文，其余是控制码/字节的原文。
    let value: String

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

// MARK: - 码表

/// 一族码表。三个集合互不重叠，判定顺序：替换型 → 带参显示型 → 单字符型。
private struct LegacyEscapeTable {
    let substitutions: Set<Character>
    let bracketedControls: Set<Character>
    let bareControls: Set<Character>
}

// MARK: - 编解码

enum LegacyEscapeCodec {

    // MARK: 码表（唯一的字母来源；判定逻辑不认其它字母）

    /// 2000/2003。大小写两套都在，出处见文件头（EasyRPG 源码 + TestGame 实测）。
    private static let rm2kTable = LegacyEscapeTable(
        substitutions: ["n", "N", "v", "V"],
        bracketedControls: ["c", "C", "s", "S"],
        bareControls: ["_", "$", "!", "^", ">", "<", ".", "|", "\\"]
    )

    /// XP/VX/VX Ace。只收大写（官方写法）；\\G 与 \\I[n] 是 RGSS 独有。
    private static let rgssTable = LegacyEscapeTable(
        substitutions: ["N", "V"],
        bracketedControls: ["C", "I"],
        bareControls: ["G", "!", "^", ">", "<", ".", "|", "{", "}", "\\"]
    )

    private static func table(for family: LegacyEscapeFamily) -> LegacyEscapeTable {
        switch family {
        case .rm2k: return rm2kTable
        case .rgss: return rgssTable
        }
    }

    // MARK: 切分

    /// 把**已解码**的文本切成 token 序列。
    ///
    /// - Parameter decodedText: 必须是从 cp932/cp936 等字节解码出的 String。
    ///   **不要**在这里传 Data：0x5C 是 GBK/SJIS 的合法尾字节，按字节扫会把半个汉字
    ///   当转义起点（见文件头铁律一）。
    ///
    /// 未知反斜杠序列（\\z、结尾裸 \\、\\[ 未闭合、\\s 不带 [n]）按 .text 处理，
    /// 既不抛错也不丢字符。空串返回空数组。
    static func tokenize(_ decodedText: String, family: LegacyEscapeFamily) -> [LegacyEscapeToken] {
        guard !decodedText.isEmpty else { return [] }
        let table = table(for: family)
        let scalars = Array(decodedText.unicodeScalars)

        var tokens: [LegacyEscapeToken] = []
        var buffer = String.UnicodeScalarView()

        func flushText() {
            guard !buffer.isEmpty else { return }
            tokens.append(LegacyEscapeToken(kind: .text, value: String(buffer)))
            buffer = String.UnicodeScalarView()
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]

            // 控制字节优先：它们不是反斜杠，但必须单独成段（回写时按原样插回）。
            if isRawControl(scalar) {
                flushText()
                tokens.append(LegacyEscapeToken(kind: .rawControl(UInt8(scalar.value)), value: String(scalar)))
                index += 1
                continue
            }

            if scalar == "\\", index + 1 < scalars.count {
                // 带参码：反斜杠 + 字母 + [ … ]
                if let length = bracketedCodeLength(scalars, start: index) {
                    let letter = Character(scalars[index + 1])
                    if table.substitutions.contains(letter) {
                        flushText()
                        tokens.append(LegacyEscapeToken(
                            kind: .substitution(String(letter)),
                            value: String(String.UnicodeScalarView(scalars[index..<(index + length)]))
                        ))
                        index += length
                        continue
                    }
                    if table.bracketedControls.contains(letter) {
                        flushText()
                        tokens.append(LegacyEscapeToken(
                            kind: .control(String(letter)),
                            value: String(String.UnicodeScalarView(scalars[index..<(index + length)]))
                        ))
                        index += length
                        continue
                    }
                }
                // 单字符码：\\_ \\$ \\G 与字面反斜杠 \\\\ …
                let letter = Character(scalars[index + 1])
                if table.bareControls.contains(letter) {
                    flushText()
                    tokens.append(LegacyEscapeToken(
                        kind: .control(String(letter)),
                        value: String(String.UnicodeScalarView(scalars[index...index + 1]))
                    ))
                    index += 2
                    continue
                }
            }

            buffer.append(scalar)
            index += 1
        }
        flushText()
        return tokens
    }

    /// 只取可翻译段（与 Segmenter.textSegments 同责，但按本族码表切）。
    static func translatableSegments(_ decodedText: String, family: LegacyEscapeFamily) -> [String] {
        return tokenize(decodedText, family: family).compactMap { token in
            if case .text = token.kind { return token.value }
            return nil
        }
    }

    /// 用译文按顺序替换 .text 段，控制码与替换符原样插回。
    ///
    /// 数量必须**严格**等于可翻译段数：不做 Segmenter.reassemble 那种"剔空段再试"的
    /// 噪声清洗 —— 本函数的调用方（LCF 写回）一错就是整条消息错位，宁可抛错整条丢弃。
    static func reassemble(_ tokens: [LegacyEscapeToken], translations: [String]) throws -> String {
        let expected = textCount(tokens)
        guard translations.count == expected else {
            throw MochiBoxError(
                code: .segmentMismatch,
                message: "译文条数 \(translations.count) ≠ 原文可翻译段数 \(expected)",
                rawSnippet: translations.joined(separator: K.unitSeparatorString)
            )
        }
        var output = ""
        var cursor = 0
        for token in tokens {
            if token.kind.isText {
                output += translations[cursor]
                cursor += 1
            } else {
                output += token.value
            }
        }
        return output
    }

    /// 校验重组结果里的控制码是否与原文逐项一致（顺序 + 字面 + id）。
    ///
    /// 返回人类可读的不一致项；空数组 = 通过。用于拦"模型把 \\c[3] 改成 \\c[4]"、
    /// "模型把 \\n[1] 当正文翻成『名字』"、"译文里凭空多出一个 \\C[0]"这三类错。
    /// 判定方式是**重新切分**重组结果再比对非 text token —— 不靠字符串搜索，
    /// 因为 \\c[3] 也可能作为字面文本合法出现在译文里（那时它是 text 段，不算多出）。
    static func validateControlCodesPreserved(
        original: [LegacyEscapeToken],
        reassembled: String,
        family: LegacyEscapeFamily
    ) -> [String] {
        let before = codeLiterals(original)
        let after = codeLiterals(tokenize(reassembled, family: family))
        guard before != after else { return [] }

        var problems: [String] = []
        let shared = min(before.count, after.count)
        for position in 0..<shared where before[position] != after[position] {
            problems.append("第 \(position + 1) 个控制码被改动：原文“\(visible(before[position]))”，重组后“\(visible(after[position]))”")
        }
        if before.count > after.count {
            for position in shared..<before.count {
                problems.append("第 \(position + 1) 个控制码丢失：原文“\(visible(before[position]))”")
            }
        } else if after.count > before.count {
            for position in shared..<after.count {
                problems.append("第 \(position + 1) 个控制码多出：重组后“\(visible(after[position]))”")
            }
        }
        return problems
    }

    // MARK: 桥接

    /// token 序列 → Segment：text 归 .text，其余全部归 .code。
    ///
    /// 存在的理由只有一个：缓存键与 mapKey 只认 Segmenter（本项目唯一的归一/哈希实现）。
    /// 让经典引擎的文本也能进同一套 Segmenter.mapKey / cacheKey，而不是另写一份哈希。
    ///
    /// ⚠ 过桥会丢掉 substitution / control / rawControl 的区分（三者都压成 .code）。
    /// 需要区分"替换符"和"显示期控制码"的场合（PO 导出、日志、是否值得翻译的判定）
    /// 必须直接用 token，不要从 Segment 反推。
    static func segments(from tokens: [LegacyEscapeToken]) -> [Segment] {
        return tokens.map { token in
            Segment(kind: token.kind.isText ? .text : .code, value: token.value)
        }
    }

    // MARK: 按引擎族分派（管线唯一骨架入口）

    /// 按引擎族造骨架：`mvmz`（及其它非经典引擎）走 `Segmenter.splitSegments`，
    /// `easyrpg` / `rgss` 走本文件的码表。
    ///
    /// **这是管线里唯一该被调用的分段入口**。不要在 Segmenter.splitSegments 内部加 family
    /// 分支：那是与 agent_mvmz.js 同构的双端契约，多一个维度就多一处投影不对齐的机会
    /// （mapKey 一旦不一致，症状是"翻译成功、缓存也写了、游戏里永远是原文"）。
    static func skeleton(raw: String, engineFamily: String) -> [Segment] {
        guard let family = LegacyEscapeFamily(engineFamily: engineFamily) else {
            return Segmenter.splitSegments(raw: raw, engineFamily: engineFamily)
        }
        return segments(from: tokenize(raw, family: family))
    }

    /// 回填后的控制码完整性校验，按引擎族分派。
    ///
    /// `mvmz` 一律返回空数组：MV/MZ 的码值保序由页面侧 `mergeBySkeleton` 与本端
    /// `Segmenter.mergeBySkeleton` 共同保证，这里再判一次等于把双端契约复制一份。
    static func controlCodeProblems(raw: String, reassembled: String, engineFamily: String) -> [String] {
        guard let family = LegacyEscapeFamily(engineFamily: engineFamily) else { return [] }
        return validateControlCodesPreserved(
            original: tokenize(raw, family: family),
            reassembled: reassembled,
            family: family
        )
    }

    /// 模型产出的**文本**里混入了控制码（按引擎族分派，`mvmz` 返回空数组）。
    ///
    /// 为什么需要它、而不是在每个落地点都调 `controlCodeProblems`：
    /// 批量落地（`SessionController.handleBatchResult`）手里**没有原文 raw** ——
    /// `SessionController.swift:148-151` 明令不按 cacheKey 存 raw（同一个 cacheKey 的每行
    /// raw 可以不同：控制码差异不进 cacheKey，存首行会把人家的码值画到这一行）。
    /// legacy 族里"最终串里的每一个控制码都必须来自骨架"，所以只要模型给的文本段里
    /// 一个控制码都没有，逐行重组的码值就必然与各行自己的骨架一致 —— 这条判据与行无关，
    /// 因此能在不碰 raw 的前提下覆盖**所有**共享该 cacheKey 的行。
    static func translatedTextProblems(_ translatedText: String, engineFamily: String) -> [String] {
        guard let family = LegacyEscapeFamily(engineFamily: engineFamily) else { return [] }
        var problems: [String] = []
        let pieces = translatedText.components(separatedBy: K.unitSeparatorString)
        for (index, piece) in pieces.enumerated() {
            for token in tokenize(piece, family: family) where !token.kind.isText {
                problems.append("第 \(index + 1) 段译文里混入了控制码 “\(visible(token.value))”")
            }
        }
        return problems
    }

    // MARK: 内部

    private static func textCount(_ tokens: [LegacyEscapeToken]) -> Int {
        return tokens.reduce(0) { partial, token in token.kind.isText ? partial + 1 : partial }
    }

    /// 非 text token 的原始字面，按出现顺序（.rawControl 的 value 就是那个字节本身）。
    private static func codeLiterals(_ tokens: [LegacyEscapeToken]) -> [String] {
        return tokens.compactMap { token in token.kind.isText ? nil : token.value }
    }

    private static func isRawControl(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.value <= 0x1F || scalar.value == 0x7F
    }

    /// 反斜杠 + 单字母 + [ … ]，返回含反斜杠的总长度；括号**配平**计数。
    ///
    /// 为什么配平而不是"找第一个 ]"：真实数据里有嵌套 —— TestGame-2000 的 Map0001
    /// 就写着 \\N[\\v[0009]]（名字取变量 9 的序号）。找第一个 ] 会把 \\N[\\v[0009]
    /// 整段吞成一个替换符、留下一个孤 ]，回写虽然还能对上，但那条 \\v[0009] 的 id
    /// 就再也校验不到了。
    ///
    /// 括号不配平（到串尾都没有闭合）→ 返回 nil，调用方按普通文本处理，不吞字符。
    private static func bracketedCodeLength(_ scalars: [Unicode.Scalar], start: Int) -> Int? {
        let bracket = start + 2
        guard bracket < scalars.count, scalars[bracket] == "[" else { return nil }
        var depth = 0
        var scan = bracket
        while scan < scalars.count {
            let scalar = scalars[scan]
            if scalar == "[" {
                depth += 1
            } else if scalar == "]" {
                depth -= 1
                if depth == 0 { return scan - start + 1 }
            }
            scan += 1
        }
        return nil
    }

    /// 把控制字节渲染成可打印形式，只用于校验报告（否则 LF 会把报告拆行、NUL 直接吞掉）。
    private static func visible(_ literal: String) -> String {
        var output = ""
        for scalar in literal.unicodeScalars {
            switch scalar.value {
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0x0C: output += "\\f"
            case 0x00...0x1F, 0x7F:
                output += String(format: "\\x%02X", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
