//
//  Segmenter.swift
//  MochiBox
//
//  PRD §5.1 的唯一权威实现：分段 / 归一化 / 缓存键 / 回填。
//  与 Resources/agent_mvmz.js 里的 `splitSegments` / `mapKeyOf` 逐字节一致；
//  归一化与哈希**只在本文件**（§6.2.1：Agent 不归一、不哈希）。
//

import Foundation
import CryptoKit

enum Segmenter {

    // MARK: - 分段

    /// 把混合串切成 `code` / `text` 段。`code` 段为 MV/MZ 的转义码，回填时原样保留。
    static func splitSegments(raw: String, engineFamily: String) -> [Segment] {
        guard !raw.isEmpty else { return [] }
        guard engineFamily == "mvmz" else {
            return [Segment(kind: .text, value: raw)]
        }

        let chars = Array(raw)
        var segments: [Segment] = []
        var buffer = ""
        var index = 0

        func flushBuffer() {
            if !buffer.isEmpty {
                segments.append(Segment(kind: .text, value: buffer))
                buffer = ""
            }
        }

        while index < chars.count {
            let current = chars[index]
            if current == "\\", index + 1 < chars.count {
                if let length = bracketedCodeLength(chars, start: index) {
                    flushBuffer()
                    segments.append(Segment(kind: .code, value: String(chars[index..<(index + length)])))
                    index += length
                    continue
                }
                let next = chars[index + 1]
                if singleCharCodeSet.contains(asciiUpper(next)) {
                    flushBuffer()
                    segments.append(Segment(kind: .code, value: String(chars[index...index + 1])))
                    index += 2
                    continue
                }
            }
            buffer.append(current)
            index += 1
        }
        flushBuffer()
        return segments
    }

    /// 把字符按 **ASCII** 折叠成大写，其它字符原样返回。
    ///
    /// 为什么不用 `String.uppercased()` / `Character.toUpperCase()`：
    /// Unicode 大小写映射（土耳其 `ı`、德文 `ß`、希腊终结 sigma）在不同运行时/不同版本上
    /// 结果可能不同，而码表里只有 ASCII 字母。折叠规则必须是**可断言**的，不能绑在平台实现上。
    ///
    /// **只用于比对，绝不改写段值**：`\c[3]` 必须仍然以 `\c[3]` 拼回去 ——
    /// 若上转成 `\C[3]`，`mapKey` 会跟着变，双端键就全错（架构 §8.2 规则 2）。
    @inline(__always)
    private static func asciiUpper(_ character: Character) -> Character {
        guard let ascii = character.asciiValue, ascii >= 97, ascii <= 122 else { return character }
        return Character(UnicodeScalar(ascii - 32))
    }

    /// `\X[..] \N[..] \V[..] \P[..] \PX[..] \PY[..] \FS[..] \C[..] \I[..]`，返回含反斜杠的总长度。
    ///
    /// 字母按 ASCII 大写折叠后比对：MZ 自己的 `convertEscapeCharacters` 用的就是
    /// `/\x1bV\[(\d+)\]/gi`（全带 `i`），真实数据里小写 `\c` 出现 533 次、`\v` 104 次。
    /// 认不出它们 = 把转义码当正文送后端（模型一改写，颜色/变量/图标就废了）。
    private static func bracketedCodeLength(_ chars: [Character], start: Int) -> Int? {
        // 顺序敏感：长前缀必须先试（`PX`/`PY`/`FS` 必须先于 `P`/`X`）。`I` 放末尾只为 diff 好读。
        let prefixes: [[Character]] = [Array("FS"), Array("PX"), Array("PY"),
                                      Array("X"), Array("N"), Array("V"), Array("P"),
                                      Array("C"), Array("I")]
        for prefix in prefixes {
            var matched = true
            for (offset, expected) in prefix.enumerated() {
                let position = start + 1 + offset
                if position >= chars.count || asciiUpper(chars[position]) != expected {
                    matched = false
                    break
                }
            }
            guard matched else { continue }
            let bracketPosition = start + 1 + prefix.count
            guard bracketPosition < chars.count, chars[bracketPosition] == "[" else { continue }
            var scan = bracketPosition + 1
            while scan < chars.count {
                if chars[scan] == "]" {
                    return scan - start + 1
                }
                scan += 1
            }
            // 有 `[` 无 `]`：按普通字符处理，不做 code 段。
            return nil
        }
        return nil
    }

    /// 单字符转义码（反斜杠后一个字符）。符号折叠是恒等，只有 `G` 受折叠影响（`\g`）。
    ///
    /// `I` **刻意不进这里**：`\I` 不带 `[n]` 在 MZ 里不是码（`processEscapeCharacter` 只在
    /// `\I[n]` 形式生效），认了会把 `\I` 后面的正文开头吃掉（架构 §8.7）。
    private static let singleCharCodeSet: Set<Character> = [
        "{", "}", "|", "!", ".", "$", ">", "<", "^", "\\", "G"
    ]

    // MARK: - 归一化

    /// NFKC + 空白折叠 + trim。
    ///
    /// 只做三件事，**不剥控制码**：控制码在 `splitSegments` 阶段已经进了 `code` 段，
    /// `join(textSegments)` 本来就不含它们。在这里再写一次剥码就是**第二套剥码逻辑**，
    /// 两套必然漂移（一套认 `\X[..]`、另一套不认，或对 `\$` 处理不同），
    /// 而漂移的症状是"缓存键时对时不对"——最难查。不认识的字符一律原样保留。
    ///
    /// 折叠只作用于**显式白名单**（`isFoldableWhitespace`），不用
    /// `CharacterSet.whitespaces` / `\s` / `\p{Z}` 这类平台集合，理由三条：
    ///   1. 三个集合的覆盖范围各不相同，用它算键意味着"同一句在不同环境算出不同键"，
    ///      不报错、难定位（与"不得依赖正则方言"是同一条原则）；
    ///   2. "顺手升级"风险：有人为清理控制字符把 `.whitespaces` 换成 `.controlCharacters`，
    ///      那时才会真吃掉 `U+001F` —— 段分隔符没了，`"AB"+"C"` 与 `"A"+"BC"` 会撞同一个键
    ///      （PRD §5.1 特意用 `U+001F` 就是为了防这个碰撞）。白名单不给人这种"顺手"的机会；
    ///   3. 契约可断言：哪几个字符参与折叠是契约的一部分，不能绑在平台实现上。
    static func normalizeForKey(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(nfkc.unicodeScalars.count)
        var pendingSpace = false
        var started = false
        for scalar in nfkc.unicodeScalars {
            if isFoldableWhitespace(scalar) {
                if started { pendingSpace = true }
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
            started = true
        }
        var view = String.UnicodeScalarView()
        for scalar in scalars { view.append(scalar) }
        return String(view)
    }

    /// 参与"空白折叠"的字符**白名单** = PRD §5.1 列举的 5 个：
    /// `U+0009`(TAB) / `U+000A`(LF) / `U+000D`(CR) / `U+0020`(SPACE) / `U+3000`(全角空格)。
    /// 其余字符（含 `U+001F` 与其它控制字符）**原样透传**。
    static func isFoldableWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009, 0x000A, 0x000D, 0x0020, 0x3000:
            return true
        default:
            return false
        }
    }

    /// 移除"折叠白名单"里的 5 个码位（与 `normalizeForKey` **同一份**白名单，不另写一组）。
    ///
    /// 只用于 `punctuation` 判定：`"! !"` 必须与 `"!!"` 同判（架构 §7.7 双端一致）。
    /// 判据里刻意**不含任何平台字符类**（`\s` / `\p{Z}` / `CharacterSet.whitespaces`）：
    /// 三者的覆盖范围互不相同（`\s` 含 U+FEFF、`.whitespaces` 不含），用它只会把一个
    /// 不一致换成另一个；`\p{P}` / `\p{S}` 是 Unicode 类别，两端语义相同。
    static func strippingFoldableWhitespace(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars where !isFoldableWhitespace(scalar) {
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    /// 判断字符是否属于 Unicode 标点（`P*`）或符号（`S*`）。**不含**空白类（见上）。
    static func isPunctuationOrSymbol(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.punctuationCharacters.contains(scalar) { return true }
        if CharacterSet.symbols.contains(scalar) { return true }
        return false
    }

    // MARK: - 缓存键
    //
    // 两级 key，两侧语义**不共享**（docs/architecture.md §6.2.1）：
    //   · `mapKey`   —— 页面侧译文映射键，Agent 计算，纯字符串（text 段 U+001F join）。
    //   · `cacheKey` —— 持久化缓存键，**只有本文件计算**（CryptoKit.SHA256 小写 hex）。
    // Agent 侧不含任何哈希实现；Host 收到 Agent 上报的 `key`(mapKey) 一律丢弃并用
    // `cacheKey(...)` 重算，`mapKey` 只进日志对账。

    static func textSegments(_ segments: [Segment]) -> [Segment] {
        return segments.filter { $0.kind == .text }
    }

    static func textSegmentCount(_ segments: [Segment]) -> Int {
        return segments.reduce(0) { partial, segment in
            return segment.kind == .text ? partial + 1 : partial
        }
    }

    /// 送后端的原文（U+001F 连接，保留原始空白）。
    static func joinForBackend(_ segments: [Segment]) -> String {
        return textSegments(segments).map { $0.value }.joined(separator: K.unitSeparatorString)
    }

    /// 页面侧译文映射键 = Agent 的 `mapKeyOf(raw)`。
    ///
    /// **必须**用 Agent 上报的 `segments` 重建，不得用本端 `splitSegments(raw)` 重切：
    /// 两侧分段器只要有一处细微差异，键就会与 Agent 的 Map 错开，
    /// 症状是"翻译成功、缓存也写了、但游戏里永远是原文"（§6.2.1 第 4 条）。
    /// 全部为 `code` 段时退回原串拼接（与 Agent 的 `mapKeyOf` 对齐）。
    static func mapKey(_ segments: [Segment]) -> String {
        let joined = joinForBackend(segments)
        if joined.isEmpty {
            return segments.map { $0.value }.joined()
        }
        return joined
    }

    /// 缓存键材料（便于两侧对照调试）。
    ///
    /// **归一化作用于"join 之后的整串"**，不是"逐段归一后再 join"（两者对首尾空白处理不同）。
    /// 依据：`normalizeForKey(text)` 的签名接的是**一个字符串**，且 PRD §5.1 把它写在
    /// `key = SHA256(prefix + join(text…))` 之前。选错会让 `"こんにちは"` 与 `"こんにちは "`
    /// 变成两个缓存条目 —— 重复计费 + 命中率虚低，而界面上完全看不出来。
    ///
    /// 注意 `mapKey` 侧**绝不归一**（§6.2.1 契约 1：Agent 不做 NFKC/空白折叠，
    /// 否则会改变要绘制的字符串），所以 `mapKey ≠ normalizeForKey(mapKey)` 是设计如此。
    static func keyMaterial(
        engineFamily: String,
        srcLang: String,
        tgtLang: String,
        segments: [Segment],
        profile: String? = nil
    ) -> String {
        let joined = textSegments(segments).map { $0.value }.joined(separator: K.unitSeparatorString)
        let normalized = normalizeForKey(joined)
        // profile 为空时**必须**与旧公式逐字节一致：否则升级即全量缓存失效。
        if let profile = profile, !profile.isEmpty {
            return "\(engineFamily)|\(srcLang)|\(tgtLang)|\(profile)|\(normalized)"
        }
        return "\(engineFamily)|\(srcLang)|\(tgtLang)|\(normalized)"
    }

    /// 持久化缓存键：`lowerHex(SHA256(engine|src|tgt|normalizedMapKey))`。
    /// **本工程中唯一的哈希计算点**；Agent 侧没有、也不应有任何等价实现。
    static func cacheKey(
        engineFamily: String,
        srcLang: String,
        tgtLang: String,
        segments: [Segment],
        profile: String? = nil
    ) -> String {
        let material = keyMaterial(
            engineFamily: engineFamily,
            srcLang: srcLang,
            tgtLang: tgtLang,
            segments: segments,
            profile: profile
        )
        return sha256Hex(material)
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { byte in String(format: "%02x", byte) }.joined()
    }

    // MARK: - 回填

    /// 把译文切成与期望段数对齐的 pieces。
    ///
    /// 段数不符时**先剔掉空段再比一次**。依据是一条不变量：原文的 `text` 段永远非空
    /// （`splitSegments` 的 `flushBuffer` 只在 buffer 非空时 append，Agent 侧同构），
    /// 所以译文里出现的空段只可能是模型多写的分隔符 ——
    /// 尾随（`…呜啊\u{1F}`）、连续（`A\u{1F}\u{1F}B`）两种形态在真机日志里都出现过。
    /// 这是纯噪声清洗：不改变任何段的顺序与内容，也不会把相邻两段并成一段。
    ///
    /// **只在“剔除后恰好对上”时采用**；否则原样返回，由调用方按段数不符抛错。
    /// 不做“按比例重切”：段边界对应 `code` 段的位置，重切会把 `\N[1]` 画到别处，
    /// 属于比漏译更严重的语义错误（见 `mergeBySkeleton` 的注释）。
    private static func alignedPieces(_ translatedText: String, expected: Int) -> [String] {
        let pieces = translatedText.components(separatedBy: K.unitSeparatorString)
        guard pieces.count != expected else { return pieces }
        let compacted = pieces.filter { !$0.isEmpty }
        return compacted.count == expected ? compacted : pieces
    }

    /// 把译文按 `text` 段顺序回填，`code` 段原样保留。
    /// 段数不一致 → 抛 `segment_mismatch`（调用方必须整条丢弃且不写缓存）。
    static func reassemble(segments: [Segment], translatedText: String) throws -> String {
        let expected = textSegmentCount(segments)
        if expected == 0 {
            if translatedText.isEmpty {
                return segments.map { $0.value }.joined()
            }
            throw MochiBoxError(code: .segmentMismatch, message: "原文没有可翻译段，但收到了译文")
        }
        let pieces = alignedPieces(translatedText, expected: expected)
        guard pieces.count == expected else {
            throw MochiBoxError(
                code: .segmentMismatch,
                message: "译文分段数 \(pieces.count) ≠ 原文分段数 \(expected)",
                rawSnippet: translatedText
            )
        }
        var output = ""
        var cursor = 0
        for segment in segments {
            if segment.kind == .code {
                output += segment.value
            } else {
                output += pieces[cursor]
                cursor += 1
            }
        }
        return output
    }

    /// 生成回填后的段数组（供 `TextEvent.translatedSegments` 与下发 Agent 使用）。
    static func translatedSegments(segments: [Segment], translatedText: String) throws -> [Segment] {
        let expected = textSegmentCount(segments)
        let pieces = alignedPieces(translatedText, expected: expected)
        if expected == 0 {
            if translatedText.isEmpty { return segments }
            throw MochiBoxError(code: .segmentMismatch, message: "原文没有可翻译段，但收到了译文")
        }
        guard pieces.count == expected else {
            throw MochiBoxError(
                code: .segmentMismatch,
                message: "译文分段数 \(pieces.count) ≠ 原文分段数 \(expected)",
                rawSnippet: translatedText
            )
        }
        var output: [Segment] = []
        var cursor = 0
        for segment in segments {
            if segment.kind == .code {
                output.append(segment)
            } else {
                output.append(Segment(kind: .text, value: pieces[cursor]))
                cursor += 1
            }
        }
        return output
    }

    // MARK: - 按本行骨架重组（BUG-11 的 Host 侧同型点）

    /// 取出译文**文本段队列**：`code` 段故意丢弃 —— 那是"先到那一行"的码值，
    /// 不是正在绘制的这一行的。
    static func translatedTextPieces(_ translatedSegments: [Segment]) -> [String] {
        return translatedSegments.filter { $0.kind == .text }.map { $0.value }
    }

    /// 用**本行自己的骨架**重组译文：`code` 段发本行的值（大小写原样），`text` 段按序取译文。
    ///
    /// 与 Agent 侧 `mergeBySkeleton` 是**同一套规则的两端实现**，判据必须逐值一致：
    /// 本行无文本段、或文本段数与译文条数不符 → 返回 nil，调用方**不得**拿别的行的
    /// 整串（`translatedRaw`）兜底。理由：`\N[1]` 画到 `\N[2]` 的行上是把人名画错，
    /// 属于语义错误，比"这一行不翻译"严重得多。
    static func mergeBySkeleton(skeleton: [Segment], translatedTexts: [String]) -> String? {
        let expected = textSegmentCount(skeleton)
        guard expected > 0, translatedTexts.count == expected else { return nil }
        var output = ""
        var cursor = 0
        for segment in skeleton {
            if segment.kind == .code {
                output += segment.value
            } else {
                output += translatedTexts[cursor]
                cursor += 1
            }
        }
        return output
    }

    /// 与 `mergeBySkeleton` 同源，产出段数组（写入 `TextEvent.translatedSegments`）。
    /// 失败条件与拼接完全一致：两者不能各判各的，否则显示串和导出段会不一致。
    static func mergeSegments(skeleton: [Segment], translatedTexts: [String]) -> [Segment]? {
        let expected = textSegmentCount(skeleton)
        guard expected > 0, translatedTexts.count == expected else { return nil }
        var output: [Segment] = []
        var cursor = 0
        for segment in skeleton {
            if segment.kind == .code {
                output.append(segment)
            } else {
                output.append(Segment(kind: .text, value: translatedTexts[cursor]))
                cursor += 1
            }
        }
        return output
    }
}

/// 跳过规则：纯数字 / 纯标点符号空白 / 已是中文 / 过短 / 已暂停。
///
/// **判定顺序是规范**（docs/architecture.md §7.8，不得重排）：
/// `normalizeForKey → skipReason → TranslationCache.get → 入队`。
/// 命中本规则即终止：不入队、不查缓存、**不写缓存**，`status` 必须是 `.skipped`（不得冒充 `.hit`）。
enum SkipRules {
    /// 返回 nil 表示需要翻译。
    ///
    /// 入参应传"剥码后的原文"（`Segmenter.mapKey(segments)`）：多段以 U+001F 分隔时逐段判定，
    /// **任一段需要翻译则整条需要翻译**。
    ///
    /// ⚠ 判据**自己守住自己的前置条件**：入口先做与 `Segmenter.normalizeForKey` 同一套归一，
    /// 不依赖调用方是否归一。否则 `"350 "`（尾空格）、`"３５０"`（全角）判不出 `numeric`
    /// → 漏跳 → 多发一次请求 + 写一条脏缓存，而界面没有任何异常。
    /// 归一只能有**一份实现**，所以这里直接复用 `normalizeForKey`，不另写 trim/折叠。
    static func skipReason(for normalizedText: String, enabled: Bool, minLength: Int) -> String? {
        if !enabled { return "disabled" }
        // 整串先判（不是逐段）：中文判据看的是“这一屏到底是不是中文”，
        // 逐段判会让 3 段 × 5 字的中文对白永远凑不够 8 个汉字，一段都跳不掉。
        // 顺序是规范：whitespace → numeric → punctuation → chinese → tooShort。
        let whole = Segmenter.normalizeForKey(normalizedText)
        if let reason = wholeReason(for: whole) { return reason }

        let parts = normalizedText.components(separatedBy: K.unitSeparatorString)
        var first: String?
        for part in parts {
            guard let reason = singleReason(for: part, minLength: minLength) else {
                return nil
            }
            if first == nil { first = reason }
        }
        return first ?? "whitespace"
    }

    /// 整串判定（多段以 U+001F 连接时也当一整句看）。
    ///
    /// 只回答“整串自己是否已经无需翻译”；任何一项不成立都返回 nil，交给逐段逻辑
    /// 处理 tooShort（多段里每段都过短时仍按原规则跳过）。
    private static func wholeReason(for normalized: String) -> String? {
        if normalized.isEmpty { return "whitespace" }
        if normalized.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return "numeric"
        }
        let core = Segmenter.strippingFoldableWhitespace(normalized)
        if core.isEmpty { return "whitespace" }
        if core.unicodeScalars.allSatisfy({ Segmenter.isPunctuationOrSymbol($0) }) {
            return "punctuation"
        }
        if isPredominantlyChinese(normalized) { return "chinese" }
        return nil
    }

    /// 无平假名/片假名。
    ///
    /// 覆盖 0x3040...0x309F（平假名）、0x30A0...0x30FF（片假名）、
    /// 0xFF66...0xFF9D（半角片假名）。有假名就说明是日文（或混排），一律不按中文跳过。
    static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x3040...0x309F).contains(value)
                || (0x30A0...0x30FF).contains(value)
                || (0xFF66...0xFF9D).contains(value) {
                return true
            }
        }
        return false
    }

    /// 判据里刻意只收“高频虚词”，且**不含 我 / 他 / 了 / 是**：
    /// 那几个字在日文汉字词里太常见（“目的” / “了解” / “我々”），
    /// 收进来会把日文汉字句误判成中文而整句漏译 —— 漏译比多译一句贵得多。
    private static let chineseFunctionCharacters: Set<Unicode.Scalar> = Set(
        "的们吗吧呢这那你您着过把被给让".unicodeScalars
    )

    /// 已是中文：无假名 + 汉字 ≥ 8 + 至少 2 个**不同**的虚词。
    ///
    /// 三条一起才成立，是为了保守：单看汉字数会把日文汉字句吞掉；
    /// 单看虚词会把只有一句“这的”的噪声吞掉。与 agent_mvmz.js 的
    /// isPredominantlyChinese 逐条一致（双端 parity 探针会钉住）。
    static func isPredominantlyChinese(_ text: String) -> Bool {
        guard !containsKana(text) else { return false }
        var hanziCount = 0
        var distinctFunctionWords = 0
        var seen: Set<Unicode.Scalar> = []
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) {
                hanziCount += 1
            }
            if chineseFunctionCharacters.contains(scalar), !seen.contains(scalar) {
                seen.insert(scalar)
                distinctFunctionWords += 1
            }
        }
        return hanziCount >= 8 && distinctFunctionWords >= 2
    }

    /// 单段判定。无 US 分隔时即整串判定。
    ///
    /// 入参在函数内先 `normalizeForKey`（NFKC + 空白折叠 + trim）。这条不是"防御性编程"，
    /// 而是 `^\d+$` 成立的前提：全角数字与尾随空格在归一前都匹配不上。
    ///
    /// 判定顺序（与 `agent_mvmz.js` 的 `skipReasonOf` **逐条对应**）：
    ///   空串 → `whitespace`；整串锚定纯数字 → `numeric`；
    ///   移除 5 个折叠码位后仍非空且全是 P/S → `punctuation`；否则 `tooShort` / nil。
    static func singleReason(for raw: String, minLength: Int) -> String? {
        let normalized = Segmenter.normalizeForKey(raw)
        if normalized.isEmpty { return "whitespace" }

        // `numeric` 语义是"**纯**数字"，因此等价于锚定的 `^[0-9]+$`：
        // 整串全部是数字才跳过。**不得**用未锚定的 `\d+` ——
        // 那会把 "10秒後" / "第2章" / "350G" 判成数字而整句漏译，且界面无任何提示（§7.8）。
        // 注意这里用**未剥白名单**的整串：`"3 5 0"` 不是纯数字（中间有空格），必须翻译。
        if normalized.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return "numeric"
        }

        // `punctuation`：先移除 5 个折叠码位再测 P/S —— `"! !"` 与 `"!!"` 必须同判，
        // 否则 Swift 跳过、JS 不跳过（§7.7 双端一致）。
        let core = Segmenter.strippingFoldableWhitespace(normalized)
        if core.isEmpty { return "whitespace" }
        if core.unicodeScalars.allSatisfy({ Segmenter.isPunctuationOrSymbol($0) }) {
            return "punctuation"
        }

        if normalized.count < minLength { return "tooShort" }
        return nil
    }
}
