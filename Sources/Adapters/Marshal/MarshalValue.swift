//
//  MarshalValue.swift
//  MochiBox
//
//  Ruby Marshal（4.8）的值模型。RGSS1/2/3 的 Data/*.rxdata|*.rvdata|*.rvdata2
//  都是这个二进制格式，Ruby 1.8~3.x 的格式版本号全为 4.8。
//
//  设计要点（全部按 MRI marshal.c 的实测行为）：
//  · 值用引用类型表达，因为 Marshal 有"对象表"：同一对象第二次出现写成 "@<index>"。
//    引用语义让"共享对象"在解析后仍然共享 —— 改一处两处都变，写回时自动恢复成链接。
//  · 链接索引按先序分配（MRI 的 w_remember 在写容器头之后、写元素之前调用），
//    因此解析与序列化的遍历顺序必须一致，否则链接编号会错位。
//  · 会进对象表的类型：String / Array / Hash / Object / UserDef / UserMarshal /
//    Struct / Regexp / Bignum / Float / Class / Module。
//    不进的：nil / true / false / Fixnum / Symbol（Symbol 有独立的符号表）。
//

import Foundation

/// 解析或序列化失败。带字节偏移，方便在 fixture 上定位坏字节。
struct MarshalError: Error, CustomStringConvertible, Equatable {
    enum Kind: String {
        case truncated           // 数据提前结束
        case badHeader           // 不是 4.8 头
        case unknownType         // 未知类型字节
        case depthExceeded       // 嵌套过深（防恶意数据把栈打穿）
        case badObjectLink       // @ 索引越界
        case badSymbolLink       // ; 索引越界
        case badNumber           // 整数/浮点/Bignum 编码不合法
        case badCollection       // 元素个数为负或超出剩余字节
        case unrepresentable     // 序列化时遇到格式表达不了的值
        case expectedType        // 调用方期望的类型与实际不符
    }

    let kind: Kind
    let offset: Int
    let detail: String

    var description: String { "MarshalError.\(kind.rawValue)(offset: \(offset)): \(detail)" }
}

// MARK: - 符号

/// Ruby 的 Symbol。保存原始字节而不只是 String —— RGSS 的 ivar 名/类名要按字节原样写回。
struct MarshalSymbol: Equatable {
    var bytes: Data
    /// "I:" 形式带的 ":E => true/false"。nil 表示无 ivar（Ruby 1.8 / 纯 ASCII）。
    var encodingIVar: Bool?

    init(bytes: Data, encodingIVar: Bool? = nil) {
        self.bytes = bytes
        self.encodingIVar = encodingIVar
    }

    init(_ name: String, encodingIVar: Bool? = nil) {
        self.bytes = Data(name.utf8)
        self.encodingIVar = encodingIVar
    }

    /// 符号名（UTF-8 解码，非法字节会被替换而不是崩）。
    var name: String { String(decoding: bytes, as: UTF8.self) }
}

/// :E / :encoding 这两种编码 ivar 的取值。
enum MarshalEncodingIVar: Equatable {
    case flag(Bool)          // :E => true / false
    case named(String)       // :encoding => "Shift_JIS"
    case unrecognized        // 形态认不出来，按原样保留

    var declaredName: String? {
        switch self {
        case .flag(true): return nil
        case .flag(false): return "US-ASCII"
        case .named(let name): return name
        case .unrecognized: return nil
        }
    }
}

// MARK: - 各类型的载荷

/// Marshal 字符串：原始字节 + ivar 列表（RGSS3 的 UTF-8 字符串带 :E => true）。
struct MarshalString {
    var bytes: Data
    var ivars: [MarshalIVar]

    init(bytes: Data, ivars: [MarshalIVar] = []) {
        self.bytes = bytes
        self.ivars = ivars
    }

    var encodingIVar: MarshalEncodingIVar? {
        for ivar in ivars {
            switch ivar.name.name {
            case "E":
                if case .bool(let flag) = ivar.value.kind { return .flag(flag) }
                return .unrecognized
            case "encoding":
                if case .string(let text) = ivar.value.kind {
                    return .named(String(decoding: text.bytes, as: UTF8.self))
                }
                return .unrecognized
            default:
                continue
            }
        }
        return nil
    }
}

struct MarshalIVar {
    var name: MarshalSymbol
    var value: MarshalValue
}

/// "o" —— 普通 Ruby 对象：类名 + ivar 列表。
struct MarshalRecord {
    var className: MarshalSymbol
    var ivars: [MarshalIVar]

    /// 去掉 ivar 名前缀 "@" 的短名字（RPG:: 数据字段习惯）。
    func ivar(named name: String) -> MarshalValue? {
        for ivar in ivars where ivar.name.name == "@" + name || ivar.name.name == name {
            return ivar.value
        }
        return nil
    }

    func string(named name: String) -> MarshalString? {
        guard case .string(let text)? = ivar(named: name)?.kind else { return nil }
        return text
    }
}

/// "u" —— UserDef：类名 + _dump 的原始字节（RGSS 的 Table 用它）。
struct MarshalUserDef {
    var className: MarshalSymbol
    var bytes: Data
}

/// "U" —— UserMarshal：类名 + 一个被 Marshal 编码的值。
struct MarshalUserMarshal {
    var className: MarshalSymbol
    var value: MarshalValue
}

/// "S" —— Struct：类名 + (成员名, 值) 列表。
/// 实测字节：53 :Foo 07 :x i 06 :y i 07 —— 成员名是符号，且占符号表。
struct MarshalStruct {
    var className: MarshalSymbol
    var members: [(name: MarshalSymbol, value: MarshalValue)]

    init(className: MarshalSymbol, members: [(name: MarshalSymbol, value: MarshalValue)]) {
        self.className = className
        self.members = members
    }
}

/// "/" —— Regexp：源码字节 + 选项位 + ivar 列表（Ruby 1.9+ 带 :E）。
struct MarshalRegexp {
    var bytes: Data
    var options: UInt8
    var ivars: [MarshalIVar]
}

struct MarshalHash {
    var pairs: [(key: MarshalValue, value: MarshalValue)]
    /// "}" 形式才有：默认值。
    var defaultValue: MarshalValue?

    init(pairs: [(key: MarshalValue, value: MarshalValue)], defaultValue: MarshalValue? = nil) {
        self.pairs = pairs
        self.defaultValue = defaultValue
    }
}

/// "l" —— Bignum：符号 + 16 位小端 limb（LSW 在前）+ 负数标记。
///
/// 注意：长度字段是**变长 long**（MRI 用 w_long 写 word 数），不是定长 short。
/// 实测 2**30 -> 6c 2b 07 00 00 00 40（07 = w_long(2) = 两个 word）。
struct MarshalBignum {
    /// 绝对值，最不重要的 16 位 limb 在前。
    var limbs: [UInt16]
    var negative: Bool

    init(limbs: [UInt16], negative: Bool) {
        var trimmed = limbs
        while let last = trimmed.last, last == 0 { trimmed.removeLast() }
        self.limbs = trimmed
        self.negative = negative && !trimmed.isEmpty
    }

    init(_ value: Int64) {
        var magnitude = value.magnitude
        var limbs: [UInt16] = []
        while magnitude > 0 {
            limbs.append(UInt16(truncatingIfNeeded: magnitude))
            magnitude >>= 16
        }
        self.init(limbs: limbs, negative: value < 0)
    }

    /// 能塞进 Int64 时给出数值，否则 nil。
    var int64Value: Int64? {
        guard limbs.count <= 4 else { return nil }
        var magnitude: UInt64 = 0
        for (index, limb) in limbs.enumerated() {
            magnitude |= UInt64(limb) << (16 * UInt64(index))
        }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            if magnitude == UInt64(Int64.max) + 1 { return Int64.min }
            return -Int64(magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(magnitude)
    }

    /// 十进制文本（任意长度，不依赖 BigInt）。
    var decimalString: String {
        if let value = int64Value { return String(value) }
        var digits: [UInt8] = []   // 十进制位，低位在前
        for limb in limbs.reversed() {
            var carry = UInt32(limb)
            for index in 0..<digits.count {
                let current = UInt32(digits[index]) * 65536 + carry
                digits[index] = UInt8(current % 10)
                carry = current / 10
            }
            while carry > 0 {
                digits.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        let text = String(digits.reversed().map { Character(UnicodeScalar($0 + 48)) })
        return negative ? "-" + text : text
    }
}

/// "f" —— Float。Ruby 写的是 ASCII 十进制文本（1.5 / nan / inf），
/// 原样保存才能做到字节级往返。
///
/// 实测：RGSS3（Enterbrain 的 Ruby 1.9.3 分支）写 Float 时，在 %0.17g 文本之后
/// 还会多带 3 个字节（如 0.8 -> "0.8…04" + 00 99 9a）。MRI 的 Marshal 读 Float
/// 走 strtod，遇到 NUL 就停，所以这 3 字节不影响取值 —— 真实 VX Ace 工程的
/// Armors/Classes/Enemies/States/Weapons/Skills 都是这个形态（见
/// Fixtures/rmvxace-real）。因此 text 只保存能解析的前缀，rawBytes 保存线上的
/// 完整字节，写回时按 rawBytes 原样吐出。
struct MarshalFloat: Equatable {
    /// 能解析为浮点的前缀（展示 / 取值用）。
    var text: String
    var value: Double
    /// 解析时读到的完整字节（含 RGSS3 的尾随字节），没有则按 text 的 UTF-8 写。
    var rawBytes: Data?

    init(text: String, value: Double, rawBytes: Data? = nil) {
        self.text = text
        self.value = value
        self.rawBytes = rawBytes
    }

    init(value: Double) {
        self.value = value
        if value.isNaN { self.text = "nan" }
        else if value.isInfinite { self.text = value > 0 ? "inf" : "-inf" }
        else { self.text = MarshalFloat.shortestText(value) }
    }

    /// 给程序化构造用的近似文本（不保证与 MRI 的 Float#to_s 完全一致，
    /// 往返用例走的是解析出来的 text）。
    static func shortestText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e16 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - 值

/// Marshal 的一个值。引用类型：对象表要求同一对象只有一个实例。
final class MarshalValue {
    enum Kind {
        case null
        case bool(Bool)
        case int(Int64)                       // i  Fixnum
        case bignum(MarshalBignum)            // l
        case float(MarshalFloat)              // f
        case string(MarshalString)            // "
        case symbol(MarshalSymbol)            // :
        case array([MarshalValue])            // [
        case hash(MarshalHash)                // { 或 }
        case object(MarshalRecord)            // o
        case userDef(MarshalUserDef)          // u
        case userMarshal(MarshalUserMarshal)  // U
        case structValue(MarshalStruct)       // S
        case regexp(MarshalRegexp)            // /
        case classRef(Data)                   // c
        case moduleRef(Data)                  // m 或 M
        case extended(module: MarshalSymbol, value: MarshalValue)  // e
        /// "I" 包在非 String/Symbol 上的情形：I<inner> + ivar 列表。
        case ivarWrapped(MarshalValue, [MarshalIVar])
    }

    var kind: Kind
    /// 解析时分配的对象表索引（未进对象表 = nil）。序列化时不依赖它，
    /// 只用于诊断与"是否共享"的判断。
    private(set) var linkIndex: Int?

    init(_ kind: Kind, linkIndex: Int? = nil) {
        self.kind = kind
        self.linkIndex = linkIndex
    }

    func assignLinkIndex(_ index: Int) { linkIndex = index }

    // MARK: 便捷访问

    var isNull: Bool { if case .null = kind { return true }; return false }

    var stringValue: MarshalString? {
        if case .string(let text) = kind { return text }
        return nil
    }

    var stringBytes: Data? { stringValue?.bytes }

    /// 字符串内容（UTF-8 宽松解码）。真正的编码判定在 RGBSTextEncoding 里。
    var text: String? {
        guard let bytes = stringBytes else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    var symbolValue: MarshalSymbol? {
        if case .symbol(let symbol) = kind { return symbol }
        return nil
    }

    var symbolName: String? { symbolValue?.name }

    var arrayElements: [MarshalValue]? {
        if case .array(let elements) = kind { return elements }
        return nil
    }

    var hashPairs: [(key: MarshalValue, value: MarshalValue)]? {
        if case .hash(let hash) = kind { return hash.pairs }
        return nil
    }

    var record: MarshalRecord? {
        if case .object(let record) = kind { return record }
        return nil
    }

    /// 类名（o / u / U / S 都带类名）。
    var className: String? {
        switch kind {
        case .object(let record): return record.className.name
        case .userDef(let def): return def.className.name
        case .userMarshal(let marshal): return marshal.className.name
        case .structValue(let value): return value.className.name
        default: return nil
        }
    }

    var nameValue: String? {
        switch kind {
        case .classRef(let bytes), .moduleRef(let bytes):
            return String(decoding: bytes, as: UTF8.self)
        default:
            return nil
        }
    }

    /// 在 o 记录里按字段名（不带 @）取值。
    func ivar(named name: String) -> MarshalValue? { record?.ivar(named: name) }

    func string(named name: String) -> MarshalString? { record?.string(named: name) }

    /// 该值是否占用对象表索引（决定写回时是否可能变成 @ 链接）。
    var occupiesObjectTable: Bool {
        switch kind {
        case .null, .bool, .int, .symbol:
            return false
        default:
            return true
        }
    }
}

// MARK: - 构造便利

extension MarshalValue {
    /// 按 Ruby 的 dump 策略构造整数：[-2^30, 2^30-1] 用 Fixnum（i），
    /// 之外用 Bignum（l）。MRI 对超出 32 位可表达范围的 Fixnum 也走 Bignum，
    /// 所以 2^30 以上在 ruby 眼里是 l —— 实测 1073741824 -> 6c 2b 07 00 00 00 40。
    static func integer(_ value: Int64) -> MarshalValue {
        if value > 0x3fff_ffff || value < -0x4000_0000 {
            return MarshalValue(.bignum(MarshalBignum(value)))
        }
        return MarshalValue(.int(value))
    }

    static func string(_ text: String, encodingIVar: Bool? = nil) -> MarshalValue {
        let bytes = Data(text.utf8)
        var ivars: [MarshalIVar] = []
        if let flag = encodingIVar {
            ivars.append(MarshalIVar(name: MarshalSymbol("E"), value: MarshalValue(.bool(flag))))
        }
        return MarshalValue(.string(MarshalString(bytes: bytes, ivars: ivars)))
    }

    static func array(_ elements: [MarshalValue]) -> MarshalValue {
        MarshalValue(.array(elements))
    }
}

