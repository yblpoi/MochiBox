//
//  LCFTextCodec.swift
//  MochiBox
//
//  RPG Maker 2000/2003 文本的编码往返：Shift-JIS（日文原版）/ GB18030（简体汉化）/ UTF-8（已翻译）。
//
//  为什么需要"猜"：LCF 里存的是**裸字节**，文件头不标编码。同一份 .ldb 里
//  日文原文与汉化文本混排是常态，所以编码判断只能逐条做，不能整库定一次。
//
//  为什么不能"按固定顺序试解码"（下面的表是实测的，不是推测）:
//
//    字节                        UTF-8 解出    Shift-JIS 解出   GB18030 解出
//    UTF-8「药水」E8 8D AF…      药水 ✓        闕ｯ豌ｴ（能解）   鑽按（能解）
//    UTF-8「あ」E3 81 82         あ ✓          nil（解不开）    nil
//    GBK  「药水」D2 A9 CB AE    ҩˮ（能解！）  ﾒｩﾋｮ（能解）   药水 ✓
//    SJIS「のダメージ…」82 CC…    nil           のダメージ…✓    偺僟儊…（能解）
//
//  两个方向都会翻车：GBK 的两字节序列常常**恰好是合法 UTF-8**（D2 A9 CB AE → ҩˮ），
//  所以"先试 UTF-8"会把中文判成 UTF-8 再解出西里尔字母；而"先试 Shift-JIS"又会把
//  已经翻译成 UTF-8 的中文解成一堆汉字加半角片假。**任何固定顺序都至少错一类。**
//
//  所以这里改成**打分**：三种编码都试解，各自按"像不像人话"打分，取最高分。
//  判分依据是这几类字符在游戏文本里的出现概率（见 plausibility）：汉字/假名/ASCII
//  加分，西里尔/希腊/拉丁扩展/半角片假名这类"解错了才会出现"的字符扣分。
//  同分时按 utf8 → shiftJIS → gb18030 的次序取先出现的（正是候选数组的顺序），
//  这条用来保证「E8 8D AF…」这种 UTF-8 与 GB18030 都能解出汉字的字节判给 UTF-8。
//
//  纯 ASCII 在三种编码下字节相同，不走打分，直接按日文原版口径报 Shift-JIS。
//
//  本文件不得 import SwiftUI / AppKit（Scripts/build.sh 的分层门禁）。
//

import Foundation

enum LCFTextCodec {

    /// 支持的编码。2000/2003 的实际来源只有这几种。
    enum Encoding: String, CaseIterable {
        case shiftJIS = "Shift-JIS"
        case gb18030 = "GB18030"
        case utf8 = "UTF-8"

        /// 映射到 Foundation 的编码常量。
        /// GB18030 在 Foundation 里没有 `String.Encoding` 常量，只能从 CoreFoundation 的
        /// CFStringEncoding 转过来（CFStringEncodings.GB_18030_2000 = 0x0632）。
        var stringEncoding: String.Encoding? {
            switch self {
            case .shiftJIS: return .shiftJIS
            case .utf8: return .utf8
            case .gb18030:
                let cf = CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
                return String.Encoding(rawValue: cf)
            }
        }
    }

    /// 按指定编码解码；字节序列非法时抛 LCFError.encodeFailed。
    static func decode(_ data: Data, as encoding: Encoding) throws -> String {
        guard let raw = encoding.stringEncoding else {
            throw LCFError.encodeFailed(encoding: encoding.rawValue)
        }
        guard let text = String(data: data, encoding: raw) else {
            throw LCFError.encodeFailed(encoding: encoding.rawValue)
        }
        return text
    }

    /// 按指定编码编码；目标编码表示不了这些字符时抛 LCFError.encodeFailed。
    static func encode(_ text: String, as encoding: Encoding) throws -> Data {
        guard let raw = encoding.stringEncoding, let data = text.data(using: raw) else {
            throw LCFError.encodeFailed(encoding: encoding.rawValue)
        }
        return data
    }

    /// 猜一条字段的编码（永不抛错）。
    ///
    /// 实现是"三种编码各解一遍 + 按可读性打分取最高"，理由见文件头那张实测表 ——
    /// 固定顺序在 GBK 与 UTF-8 互相冒充这件事上无解。
    ///
    /// 一字节 / 空数据没有可判断的信息：空数据按 .utf8，纯 ASCII 按 .shiftJIS
    /// （三者字节相同，返回哪个都不影响往返）。
    static func detect(_ data: Data) -> Encoding {
        if data.isEmpty { return .utf8 }
        guard hasMultibyteRun(data) else { return .shiftJIS }

        // ── 先看两个**决定性**信号，再交给打分 ──
        //
        // 打分解决的是"GBK 与 UTF-8 互相冒充"，但它分不清"真日文"和"把日文按 GB18030
        // 解出来的生僻字"：两者都是汉字。实测反例（本仓库 Fixtures/rm2003 里就有）：
        //   SJIS「の攻撃！」82 CC 8D 55 8C 82 81 49 → 假名14+汉字12+汉字12+全角！4 = 10.5 分
        //   GB18030 同字节             → 偺峌寕両 = 汉字 12×4 = 12 分  ← 打分反而判给 GB18030
        // 也就是任何"假名 + 全角标点"的日文都会被解成生僻字再送进翻译。所以：
        //
        //   1) 合法 UTF-8 且解出 CJK/假名 → UTF-8。
        //      这是"已经翻译过"的强信号；GBK 字节冒充 UTF-8 时解出的是西里尔字母
        //      （GBK「药水」D2 A9 CB AE → ҩˮ），不含 CJK，不会被这条误判。
        //   2) Shift-JIS 能解且含假名 → Shift-JIS。
        //      假名几乎只出现在日文里；GBK 的常用前导字节（0xA1–0xF7）在 Shift-JIS
        //      里不是合法前导，中文文本解不出假名。
        if let text = try? decode(data, as: .utf8), containsCJKOrKana(text) {
            return .utf8
        }
        if let text = try? decode(data, as: .shiftJIS), containsKana(text) {
            return .shiftJIS
        }

        var best: (encoding: Encoding, score: Int)?
        // 顺序即同分时的优先级：UTF-8 优先，其次 Shift-JIS，最后 GB18030。
        for candidate in [Encoding.utf8, .shiftJIS, .gb18030] {
            guard let text = try? decode(data, as: candidate) else { continue }
            let score = plausibility(text)
            // 严格大于：同分时保留先试的那个。
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        return best?.encoding ?? .utf8
    }

    /// 文本"像不像游戏里真会出现的话"，返回**平均分 ×100**（消除长度影响，
    /// 否则同一段字节解出的字符数不同会让长的一方天然占优）。
    ///
    /// 加分的：ASCII 可打印、汉字、平假名、片假名、中日标点。
    /// 扣分的：半角片假名（把 GBK 当 Shift-JIS 解时的典型产物）、西里尔 / 希腊 /
    /// 拉丁扩展字母（把 GBK 当 UTF-8 解时的典型产物）、控制字符、未分配码点。
    private static func plausibility(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var total = 0
        for scalar in text.unicodeScalars {
            total += score(scalar.value)
        }
        return (total * 100) / text.unicodeScalars.count
    }

    private static func score(_ v: UInt32) -> Int {
        switch v {
        case 0x20...0x7E:                      return 10   // ASCII 可打印
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return 12   // 汉字
        case 0x3040...0x309F:                  return 14   // 平假名
        case 0x30A0...0x30FF:                  return 14   // 全角片假名
        case 0x3000...0x303F:                  return 8    // 中日标点
        case 0xFF01...0xFF5E:                  return 4    // 全角字母数字
        case 0xFF61...0xFF9F:                  return -14  // 半角片假名：判错的强信号
        case 0x0370...0x03FF, 0x0400...0x04FF: return -14  // 希腊 / 西里尔
        case 0x00C0...0x00FF:                  return -10  // 拉丁扩展字母
        case 0x00A0...0x00BF:                  return -4   // 拉丁符号
        case 0x0000...0x001F, 0x007F:          return -12  // 控制字符
        case 0x0080...0x009F:                  return -12  // C1 控制区
        default:                               return 0
        }
    }

    /// 解码入口：自动判断编码并解码，返回文本与判定结果。
    ///
    /// 判定失败时走有损 UTF-8（见文件头第 4 条），因此只有真正的实现缺失才会抛错。
    static func decode(_ data: Data) throws -> (text: String, encoding: Encoding) {
        let encoding = detect(data)
        if let text = try? decode(data, as: encoding) { return (text, encoding) }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        // ISO-8859-1 是无损兜底：任意字节序列都能映射成字符，保证不丢内容。
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .utf8) }
        throw LCFError.encodeFailed(encoding: encoding.rawValue)
    }

    /// 汉字 / 假名（全角片假名算）。用于判定"这段字节解出来像不像 CJK 文本"。
    private static func containsCJKOrKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    /// 只认全角假名（平假名 + 片假名）。半角片假名（U+FF61–FF9F）**不算**：
    /// 那是"把 GBK 字节按 Shift-JIS 解"的典型产物，不能拿它证明这是日文。
    private static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where (0x3040...0x30FF).contains(scalar.value) {
            return true
        }
        return false
    }

    /// 是否含非 ASCII 字节：纯 ASCII 在三种编码下等价，不需要走"试解码"。
    private static func hasMultibyteRun(_ data: Data) -> Bool {
        for byte in data where byte >= 0x80 { return true }
        return false
    }
}
