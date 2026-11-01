//
//  MarshalReader.swift
//  MochiBox
//
//  Ruby Marshal 4.8 解析器。逐字节对照 MRI marshal.c 的行为：
//  · 整数（变长 long）：0 -> 00；1..122 -> v+5；-1..-123 -> v+251；
//    正数 -> 前缀 n(1..4) + n 字节小端；负数 -> 前缀 (256-n) + n 字节补码小端。
//    字节序是实测结论：256 -> 02 00 01，300 -> 02 2c 01。
//  · 对象表：String/Array/Hash/Object/UserDef/UserMarshal/Struct/Regexp/
//    Bignum/Float/Class/Module 先序注册；"@" 回指已注册对象。
//  · 符号表："：" 定义、"；" 回指，索引按出现顺序。
//
//  所有越界读都抛 MarshalError（带偏移），不崩；嵌套深度有上限。
//

import Foundation

struct MarshalReader {
    private let bytes: [UInt8]
    private var offset: Int = 0
    private var objects: [MarshalValue] = []
    private var symbols: [MarshalSymbol] = []
    private let maxDepth: Int

    /// - Parameter maxDepth: 嵌套上限。正常 RGSS 数据最深不到 30。
    init(_ data: Data, maxDepth: Int = 512) {
        self.bytes = [UInt8](data)
        self.maxDepth = maxDepth
    }

    /// 已消费字节数（调用方可据此判断尾部是否有多余数据）。
    var consumed: Int { offset }

    /// 对象表里的实例（诊断用：检查链接是否指到预期对象）。
    var registeredObjects: [MarshalValue] { objects }

    static func load(_ data: Data) throws -> MarshalValue {
        var reader = MarshalReader(data)
        return try reader.readDocument()
    }

    // MARK: - 入口

    mutating func readDocument() throws -> MarshalValue {
        guard bytes.count >= 2 else {
            throw MarshalError(kind: .badHeader, offset: 0, detail: "数据不足 2 字节，读不到 4.8 头")
        }
        guard bytes[0] == 4, bytes[1] <= 8 else {
            throw MarshalError(kind: .badHeader, offset: 0,
                               detail: String(format: "头部应为 04 08，实际 %02x %02x", bytes[0], bytes[1]))
        }
        offset = 2
        return try readValue(depth: 0)
    }

    // MARK: - 基础读取

    private func makeError(_ kind: MarshalError.Kind, _ detail: String) -> MarshalError {
        MarshalError(kind: kind, offset: offset, detail: detail)
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw makeError(.truncated, "读类型/数据字节时已到末尾")
        }
        let byte = bytes[offset]
        offset += 1
        return byte
    }

    private mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0 else { throw makeError(.badNumber, "长度为负：\(count)") }
        guard offset + count <= bytes.count, offset + count >= offset else {
            throw makeError(.truncated, "需要 \(count) 字节，剩余 \(bytes.count - offset)")
        }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    private mutating func readUInt16LE() throws -> UInt16 {
        let low = UInt16(try readByte())
        let high = UInt16(try readByte())
        return low | (high << 8)
    }

    /// 变长 long。规则见文件头注释；返回值限制在 32 位有符号范围内（与 MRI 一致）。
    private mutating func readLong() throws -> Int {
        let start = offset
        let first = Int(try readByte())
        if first == 0 { return 0 }
        if first > 4 && first < 128 { return first - 5 }          // 1..122
        if first >= 128 && first <= 250 { return first - 251 }    // -123..-1
        if first >= 1 && first <= 4 {                             // 正数 n 字节（小端）
            var value = 0
            for index in 0..<first {
                value |= Int(try readByte()) << (8 * index)
            }
            return value
        }
        // 251...255 -> 负数，读 (256 - first) 字节补码（小端）
        let count = 256 - first
        var raw = 0
        for index in 0..<count {
            raw |= Int(try readByte()) << (8 * index)
        }
        let value = raw - (1 << (8 * count))
        if value < Int(Int32.min) {
            throw MarshalError(kind: .badNumber, offset: start, detail: "long 超出 32 位：\(value)")
        }
        return value
    }

    /// 读一个"元素个数"，并做合理性检查，避免坏数据让我们按几十亿去预分配。
    private mutating func readCount(_ context: String) throws -> Int {
        let start = offset
        let count = try readLong()
        guard count >= 0 else {
            throw MarshalError(kind: .badCollection, offset: start, detail: "\(context) 个数为负：\(count)")
        }
        guard count <= bytes.count - offset else {
            throw MarshalError(kind: .badCollection, offset: start,
                               detail: "\(context) 声明 \(count) 个元素，剩余只有 \(bytes.count - offset) 字节")
        }
        return count
    }

    // MARK: - 值

    private mutating func readValue(depth: Int) throws -> MarshalValue {
        guard depth <= maxDepth else {
            throw makeError(.depthExceeded, "嵌套超过 \(maxDepth) 层")
        }
        let start = offset
        let marker = try readByte()
        if marker == 0x49 {   // 'I'：带 ivar 的对象
            let inner = try readByte()
            switch inner {
            case 0x22: return try readString(depth: depth, start: start, hasIvarWrapper: true)
            case 0x3a: return try readSymbol(hasIvarWrapper: true)
            case 0x2f: return try readRegexp(depth: depth, hasIvarWrapper: true)
            default:
                let value = try readBody(marker: inner, depth: depth, start: start)
                let ivars = try readIVarList(depth: depth + 1)
                return MarshalValue(.ivarWrapped(value, ivars))
            }
        }
        return try readBody(marker: marker, depth: depth, start: start)
    }

    private mutating func readBody(marker: UInt8, depth: Int, start: Int) throws -> MarshalValue {
        switch marker {
        case 0x30:  // '0'
            return MarshalValue(.null)
        case 0x54:  // 'T'
            return MarshalValue(.bool(true))
        case 0x46:  // 'F'
            return MarshalValue(.bool(false))
        case 0x69:  // 'i'
            return MarshalValue(.int(Int64(try readLong())))
        case 0x6c:  // 'l'
            return try readBignum()
        case 0x66:  // 'f'
            return try readFloat()
        case 0x22:  // '"'
            return try readString(depth: depth, start: start, hasIvarWrapper: false)
        case 0x3a:  // ':'
            return try readSymbol(hasIvarWrapper: false)
        case 0x3b:  // ';'
            return try readSymbolLink()
        case 0x5b:  // '['
            return try readArray(depth: depth)
        case 0x7b, 0x7d:  // '{' / '}'
            return try readHash(depth: depth, hasDefault: marker == 0x7d)
        case 0x6f:  // 'o'
            return try readObject(depth: depth)
        case 0x55:  // 'U'
            return try readUserMarshal(depth: depth)
        case 0x75:  // 'u'
            return try readUserDef()
        case 0x53:  // 'S'
            return try readStruct(depth: depth)
        case 0x2f:  // '/'
            return try readRegexp(depth: depth, hasIvarWrapper: false)
        case 0x63:  // 'c'
            return try readNamedType(kind: .classRef)
        case 0x6d, 0x4d:  // 'm' / 'M'
            return try readNamedType(kind: .moduleRef)
        case 0x40:  // '@'
            return try readObjectLink()
        case 0x65:  // 'e'
            return try readExtended(depth: depth)
        default:
            throw MarshalError(kind: .unknownType, offset: start,
                               detail: String(format: "未知类型字节 0x%02x", marker))
        }
    }

    private mutating func register(_ value: MarshalValue) {
        value.assignLinkIndex(objects.count)
        objects.append(value)
    }

    // MARK: 各类型

    private mutating func readString(depth: Int, start: Int, hasIvarWrapper: Bool) throws -> MarshalValue {
        let count = try readCount("字符串长度")
        let data = try readBytes(count)
        let node = MarshalValue(.string(MarshalString(bytes: data)))
        register(node)
        if hasIvarWrapper {
            let ivars = try readIVarList(depth: depth + 1)
            node.kind = .string(MarshalString(bytes: data, ivars: ivars))
        }
        return node
    }

    private mutating func readSymbol(hasIvarWrapper: Bool) throws -> MarshalValue {
        let count = try readCount("符号长度")
        let data = try readBytes(count)
        var symbol = MarshalSymbol(bytes: data)
        if hasIvarWrapper {
            let ivars = try readIVarList(depth: 1)
            for ivar in ivars where ivar.name.name == "E" {
                if case .bool(let flag) = ivar.value.kind { symbol.encodingIVar = flag }
            }
        }
        symbols.append(symbol)
        return MarshalValue(.symbol(symbol))
    }

    private mutating func readSymbolLink() throws -> MarshalValue {
        let index = try readLong()
        guard index >= 0, index < symbols.count else {
            throw makeError(.badSymbolLink, "符号索引 \(index) 越界（表内 \(symbols.count) 个）")
        }
        return MarshalValue(.symbol(symbols[index]))
    }

    private mutating func readArray(depth: Int) throws -> MarshalValue {
        let count = try readCount("数组长度")
        let node = MarshalValue(.array([]))
        register(node)
        var elements: [MarshalValue] = []
        elements.reserveCapacity(count)
        for _ in 0..<count {
            elements.append(try readValue(depth: depth + 1))
        }
        node.kind = .array(elements)
        return node
    }

    private mutating func readHash(depth: Int, hasDefault: Bool) throws -> MarshalValue {
        let count = try readCount("哈希长度")
        let node = MarshalValue(.hash(MarshalHash(pairs: [])))
        register(node)
        var pairs: [(key: MarshalValue, value: MarshalValue)] = []
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            let key = try readValue(depth: depth + 1)
            let value = try readValue(depth: depth + 1)
            pairs.append((key: key, value: value))
        }
        var defaultValue: MarshalValue?
        if hasDefault {
            defaultValue = try readValue(depth: depth + 1)
        }
        node.kind = .hash(MarshalHash(pairs: pairs, defaultValue: defaultValue))
        return node
    }

    private mutating func readObject(depth: Int) throws -> MarshalValue {
        let className = try readSymbolValue(context: "对象类名")
        let count = try readCount("ivar 个数")
        let node = MarshalValue(.object(MarshalRecord(className: className, ivars: [])))
        register(node)
        var ivars: [MarshalIVar] = []
        ivars.reserveCapacity(count)
        for _ in 0..<count {
            let name = try readSymbolValue(context: "ivar 名")
            let value = try readValue(depth: depth + 1)
            ivars.append(MarshalIVar(name: name, value: value))
        }
        node.kind = .object(MarshalRecord(className: className, ivars: ivars))
        return node
    }

    private mutating func readUserMarshal(depth: Int) throws -> MarshalValue {
        let className = try readSymbolValue(context: "UserMarshal 类名")
        let node = MarshalValue(.userMarshal(MarshalUserMarshal(className: className, value: MarshalValue(.null))))
        register(node)
        let value = try readValue(depth: depth + 1)
        node.kind = .userMarshal(MarshalUserMarshal(className: className, value: value))
        return node
    }

    private mutating func readUserDef() throws -> MarshalValue {
        let start = offset
        let className = try readSymbolValue(context: "UserDef 类名")
        let count = try readCount("UserDef 字节数")
        let data: Data
        do {
            data = try readBytes(count)
        } catch {
            throw MarshalError(kind: .badCollection, offset: start,
                               detail: "UserDef \(className.name) 的数据长度 \(count) 超出剩余字节")
        }
        let node = MarshalValue(.userDef(MarshalUserDef(className: className, bytes: data)))
        register(node)
        return node
    }

    private mutating func readStruct(depth: Int) throws -> MarshalValue {
        let className = try readSymbolValue(context: "Struct 类名")
        let count = try readCount("Struct 成员数")
        let node = MarshalValue(.structValue(MarshalStruct(className: className, members: [])))
        register(node)
        var members: [(name: MarshalSymbol, value: MarshalValue)] = []
        members.reserveCapacity(count)
        for _ in 0..<count {
            let name = try readSymbolValue(context: "Struct 成员名")
            let value = try readValue(depth: depth + 1)
            members.append((name: name, value: value))
        }
        node.kind = .structValue(MarshalStruct(className: className, members: members))
        return node
    }

    private mutating func readRegexp(depth: Int, hasIvarWrapper: Bool) throws -> MarshalValue {
        let count = try readCount("正则长度")
        let data = try readBytes(count)
        let options = try readByte()
        let node = MarshalValue(.regexp(MarshalRegexp(bytes: data, options: options, ivars: [])))
        register(node)
        if hasIvarWrapper {
            let ivars = try readIVarList(depth: depth + 1)
            node.kind = .regexp(MarshalRegexp(bytes: data, options: options, ivars: ivars))
        }
        return node
    }

    private mutating func readExtended(depth: Int) throws -> MarshalValue {
        let module = try readSymbolValue(context: "extend 模块名")
        let value = try readValue(depth: depth + 1)
        return MarshalValue(.extended(module: module, value: value))
    }

    private enum NamedType { case classRef, moduleRef }

    private mutating func readNamedType(kind: NamedType) throws -> MarshalValue {
        let count = try readCount("类/模块名长度")
        let data = try readBytes(count)
        let node = MarshalValue(kind == .classRef ? .classRef(data) : .moduleRef(data))
        register(node)
        return node
    }

    private mutating func readObjectLink() throws -> MarshalValue {
        let index = try readLong()
        guard index >= 0, index < objects.count else {
            throw makeError(.badObjectLink, "对象链接 \(index) 越界（表内 \(objects.count) 个）")
        }
        return objects[index]
    }

    private mutating func readBignum() throws -> MarshalValue {
        let start = offset
        let sign = try readByte()
        let negative: Bool
        switch sign {
        case 0x2b: negative = false      // '+'
        case 0x2d: negative = true       // '-'
        default:
            throw MarshalError(kind: .badNumber, offset: start,
                               detail: String(format: "Bignum 符号字节非法 0x%02x", sign))
        }
        let words = try readCount("Bignum word 数")
        var limbs: [UInt16] = []
        limbs.reserveCapacity(words)
        for _ in 0..<words {
            limbs.append(try readUInt16LE())
        }
        let node = MarshalValue(.bignum(MarshalBignum(limbs: limbs, negative: negative)))
        register(node)
        return node
    }

    private mutating func readFloat() throws -> MarshalValue {
        let start = offset
        let count = try readCount("浮点文本长度")
        let data = try readBytes(count)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw MarshalError(kind: .badNumber, offset: start, detail: "浮点文本不是 ASCII")
        }
        let value: Double
        switch text {
        case "nan": value = .nan
        case "inf": value = .infinity
        case "-inf": value = -.infinity
        default:
            guard let parsed = Double(text) else {
                throw MarshalError(kind: .badNumber, offset: start, detail: "浮点文本无法解析：\(text)")
            }
            value = parsed
        }
        let node = MarshalValue(.float(MarshalFloat(text: text, value: value)))
        register(node)
        return node
    }

    // MARK: 共用

    /// 读一个符号（类名/ivar 名都以 "：" 形式出现并进入符号表）。
    private mutating func readSymbolValue(context: String) throws -> MarshalSymbol {
        let marker = try readByte()
        let start = offset - 1
        switch marker {
        case 0x3a:
            let count = try readCount("\(context)长度")
            let data = try readBytes(count)
            let symbol = MarshalSymbol(bytes: data)
            symbols.append(symbol)
            return symbol
        case 0x3b:
            let index = try readLong()
            guard index >= 0, index < symbols.count else {
                throw MarshalError(kind: .badSymbolLink, offset: start,
                                   detail: "\(context) 符号索引 \(index) 越界（表内 \(symbols.count) 个）")
            }
            return symbols[index]
        default:
            throw MarshalError(kind: .unrepresentable, offset: start,
                               detail: String(format: "\(context) 期望符号，实际 0x%02x", marker))
        }
    }

    private mutating func readIVarList(depth: Int) throws -> [MarshalIVar] {
        guard depth <= maxDepth else {
            throw makeError(.depthExceeded, "ivar 嵌套超过 \(maxDepth) 层")
        }
        let count = try readCount("ivar 个数")
        var ivars: [MarshalIVar] = []
        ivars.reserveCapacity(count)
        for _ in 0..<count {
            let name = try readSymbolValue(context: "ivar 名")
            let value = try readValue(depth: depth + 1)
            ivars.append(MarshalIVar(name: name, value: value))
        }
        return ivars
    }
}
