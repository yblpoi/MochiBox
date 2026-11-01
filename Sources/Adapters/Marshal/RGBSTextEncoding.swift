//
//  RGBSTextEncoding.swift
//  MochiBox
//
//  RGSS 数据的字符串编码。三档实测结论：
//  · RGSS1 / RGSS2（XP / VX，Ruby 1.8）：字符串无 :E ivar，内容是 Windows-31J(CP932)
//  · RGSS3（VX Ace，Ruby 1.9）：UTF-8 字符串带 :E => true
//  · 民间汉化版把 CP932 换成 GB18030 或 UTF-8 的情况都存在，所以既支持显式指定，
//    也提供按字节猜测的保守启发式。
//
//  注意：CP932（Windows）与 Shift_JIS（JIS X 0208）不是一回事，用 CP932 才能解出
//  ①②③、㈱ 这类 Windows 扩展字符；解码失败再退回严格的 Shift_JIS。
//

import Foundation

enum RGBSTextEncoding: String, CaseIterable, Equatable {
    case shiftJIS = "Shift_JIS"
    case utf8 = "UTF-8"
    case gb18030 = "GB18030"

    /// UTF-8 之外的两种都是"字节型"编码：解码失败要能察觉，不能静默替换。
    var isStrict: Bool { self != .utf8 }

    /// Foundation 里对应的编码。CP932 用 CFString 的 DOSJapanese。
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .shiftJIS:
            return RGBSTextEncoding.cfEncoding(CFStringEncodings.dosJapanese)
        case .gb18030:
            return RGBSTextEncoding.cfEncoding(CFStringEncodings.GB_18030_2000)
        }
    }

    private static func cfEncoding(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }

    // MARK: - 编解码

    /// 严格解码：字节不合法返回 nil（不替换成 U+FFFD，避免"看起来成功"）。
    func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        if let text = String(data: data, encoding: stringEncoding) { return text }
        // CP932 失败时退回严格 Shift_JIS：少数数据是 JIS 而非 Windows 扩展。
        if self == .shiftJIS, let text = String(data: data, encoding: .shiftJIS) { return text }
        return nil
    }

    /// 编码。新文本里有目标编码表达不了的字符时返回 nil（调用方据此报错）。
    func encode(_ text: String) -> Data? {
        if text.isEmpty { return Data() }
        if let data = text.data(using: stringEncoding, allowLossyConversion: false) { return data }
        if self == .shiftJIS, let data = text.data(using: .shiftJIS, allowLossyConversion: false) { return data }
        return nil
    }

    /// 宽松解码：解不出来就把非法字节替换掉，只用于展示/兜底。
    func decodeLossy(_ data: Data) -> String {
        if let text = decode(data) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 判定

    /// Ruby 的 :encoding ivar 给的名称（"Shift_JIS" / "UTF-8" / "GB18030" / "Windows-31J"）。
    static func fromRubyName(_ name: String) -> RGBSTextEncoding? {
        switch name.uppercased().replacingOccurrences(of: "-", with: "_") {
        case "UTF_8", "UTF8": return .utf8
        case "SHIFT_JIS", "SJIS", "WINDOWS_31J", "CP932", "MS_KANJI": return .shiftJIS
        case "GB18030", "GB_18030", "GBK", "CP936": return .gb18030
        default: return nil
        }
    }

    /// 字节启发式：只用于"没有任何编码声明"的字符串。
    ///
    /// 顺序：合法 UTF-8 且含多字节 -> UTF-8；否则默认编码能解 -> 默认；再否则依次试。
    /// 单靠"某编码能解"判不出来（UTF-8 的日文字节在 CP932 里往往也能解成别的汉字），
    /// 所以 UTF-8 优先用严格的字节合法性判定。
    static func detect(_ data: Data, preferring preferred: RGBSTextEncoding) -> RGBSTextEncoding {
        if data.allSatisfy({ $0 < 0x80 }) { return preferred }
        if data.contains(where: { $0 >= 0x80 }), String(data: data, encoding: .utf8) != nil {
            return .utf8
        }
        if preferred.decode(data) != nil { return preferred }
        for candidate in RGBSTextEncoding.allCases where candidate != preferred {
            if candidate.decode(data) != nil { return candidate }
        }
        return preferred
    }
}
