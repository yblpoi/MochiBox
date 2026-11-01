//
//  MarshalWriter.swift
//  MochiBox
//
//  Ruby Marshal 4.8 序列化器。字节布局与 MRI 的 w_object 一一对应：
//  · 对象表按先序分配索引；再次遇到同一实例写 "@" + long(index)。
//  · 符号表按写出的先后分配索引；重复符号写 "；" + long(index)。
//  · 字符串的编码 ivar 原样重放（RGSS3 的 :E => true 不会被丢掉）。
//
//  写回的正确性用"解析 -> 序列化 -> 字节完全相同"来验证，不做近似。
//

import Foundation

struct MarshalWriter {
    private var out: [UInt8] = []
    private var objectIndices: [ObjectIdentifier: Int] = [:]
    private var symbolIndices: [Data: Int] = [:]
    private var symbolCount: Int = 0

    init() {}

    static func dump(_ value: MarshalValue) throws -> Data {
        var writer = MarshalWriter()
        return try writer.writeDocument(value)
    }

    mutating func writeDocument(_ value: MarshalValue) throws -> Data {
        out = [0x04, 0x08]
        objectIndices.removeAll()
        symbolIndices.removeAll()
        symbolCount = 0
        try writeValue(value)
        return Data(out)
    }

    // MARK: - long

    /// 变长 long。与 MRI 的 w_long 相同的分段：
    /// 0 -> [0]；1..122 -> v+5；-1..-123 -> v+251；
    /// 正数 -> n + n 字节小端；负数 -> 256-n + n 字节补码小端。
    static func encodeLong(_ value: Int) throws -> [UInt8] {
        if value == 0 { return [0] }
        if value > 0 && value <= 122 { return [UInt8(value + 5)] }
        if value < 0 && value >= -123 { return [UInt8(value + 251)] }

        if value > 0 {
            var count = 1
            while count < 4 && value >> (8 * count) != 0 { count += 1 }
            guard value >> (8 * count) == 0 else {
                throw MarshalError(kind: .unrepresentable, offset: 0,
                                   detail: "long 超出 32 位，MRI 会以 Bignum 表达：\(value)")
            }
            var bytes = [UInt8](repeating: 0, count: count)
            var remaining = UInt64(value)
            for index in 0..<count {
                bytes[index] = UInt8(remaining & 0xff)
                remaining >>= 8
            }
            return [UInt8(count)] + bytes
        }

        var count = 1
        while count < 4 && value >> (8 * count) != -1 {
            count += 1
        }
        guard value >> (8 * count) == -1 else {
            throw MarshalError(kind: .unrepresentable, offset: 0,
                               detail: "负 long 超出 32 位：\(value)")
        }
        var bytes = [UInt8](repeating: 0, count: count)
        var remaining = UInt64(bitPattern: Int64(value))
        for index in 0..<count {
            bytes[index] = UInt8(remaining & 0xff)
            remaining >>= 8
        }
        return [UInt8(256 - count)] + bytes
    }

    private mutating func writeLong(_ value: Int) throws {
        out.append(contentsOf: try MarshalWriter.encodeLong(value))
    }

    // MARK: - 值

    private func isRegistered(_ value: MarshalValue) -> Bool {
        switch value.kind {
        case .null, .bool, .int, .symbol:
            return false
        // I / e 只是包装：MRI 注册的是被包住的那个对象，包装本身不占索引。
        case .ivarWrapped, .extended:
            return false
        default:
            return true
        }
    }

    private mutating func writeValue(_ value: MarshalValue) throws {
        if isRegistered(value) {
            let key = ObjectIdentifier(value)
            if let index = objectIndices[key] {
                out.append(0x40)   // '@'
                try writeLong(index)
                return
            }
            objectIndices[key] = objectIndices.count
        }

        switch value.kind {
        case .null:
            out.append(0x30)
        case .bool(let flag):
            out.append(flag ? 0x54 : 0x46)
        case .int(let number):
            out.append(0x69)
            try writeLong(Int(number))
        case .bignum(let bignum):
            try writeBignum(bignum)
        case .float(let float):
            out.append(0x66)
            // 解析来的 Float 按原始字节写回（RGSS3 会带尾随字节）；
            // 程序化构造的没有 rawBytes，退回文本。
            let bytes = float.rawBytes.map { Array($0) } ?? Array(float.text.utf8)
            try writeLong(bytes.count)
            out.append(contentsOf: bytes)
        case .string(let string):
            try writeString(string)
        case .symbol(let symbol):
            try writeSymbol(symbol)
        case .array(let elements):
            out.append(0x5b)
            try writeLong(elements.count)
            for element in elements { try writeValue(element) }
        case .hash(let hash):
            out.append(hash.defaultValue == nil ? 0x7b : 0x7d)
            try writeLong(hash.pairs.count)
            for pair in hash.pairs {
                try writeValue(pair.key)
                try writeValue(pair.value)
            }
            if let fallback = hash.defaultValue { try writeValue(fallback) }
        case .object(let record):
            out.append(0x6f)
            try writeSymbol(record.className)
            try writeLong(record.ivars.count)
            for ivar in record.ivars {
                try writeSymbol(ivar.name)
                try writeValue(ivar.value)
            }
        case .userDef(let def):
            out.append(0x75)
            try writeSymbol(def.className)
            try writeLong(def.bytes.count)
            out.append(contentsOf: def.bytes)
        case .userMarshal(let marshal):
            out.append(0x55)
            try writeSymbol(marshal.className)
            try writeValue(marshal.value)
        case .structValue(let structValue):
            out.append(0x53)
            try writeSymbol(structValue.className)
            try writeLong(structValue.members.count)
            for member in structValue.members {
                try writeSymbol(member.name)
                try writeValue(member.value)
            }
        case .regexp(let regexp):
            if !regexp.ivars.isEmpty { out.append(0x49) }
            out.append(0x2f)
            try writeLong(regexp.bytes.count)
            out.append(contentsOf: regexp.bytes)
            out.append(regexp.options)
            if !regexp.ivars.isEmpty { try writeIVars(regexp.ivars) }
        case .classRef(let name):
            out.append(0x63)
            try writeLong(name.count)
            out.append(contentsOf: name)
        case .moduleRef(let name):
            out.append(0x6d)
            try writeLong(name.count)
            out.append(contentsOf: name)
        case .extended(let module, let inner):
            out.append(0x65)
            try writeSymbol(module)
            try writeValue(inner)
        case .ivarWrapped(let inner, let ivars):
            out.append(0x49)
            try writeValue(inner)
            try writeIVars(ivars)
        }
    }

    private mutating func writeIVars(_ ivars: [MarshalIVar]) throws {
        try writeLong(ivars.count)
        for ivar in ivars {
            try writeSymbol(ivar.name)
            try writeValue(ivar.value)
        }
    }

    private mutating func writeString(_ string: MarshalString) throws {
        if !string.ivars.isEmpty { out.append(0x49) }   // 'I'
        out.append(0x22)                                 // '"'
        try writeLong(string.bytes.count)
        out.append(contentsOf: string.bytes)
        if !string.ivars.isEmpty { try writeIVars(string.ivars) }
    }

    private mutating func writeSymbol(_ symbol: MarshalSymbol) throws {
        if let index = symbolIndices[symbol.bytes] {
            out.append(0x3b)    // ';'
            try writeLong(index)
            return
        }
        symbolIndices[symbol.bytes] = symbolCount
        symbolCount += 1
        if symbol.encodingIVar != nil { out.append(0x49) }   // 'I'
        out.append(0x3a)                                    // ':'
        try writeLong(symbol.bytes.count)
        out.append(contentsOf: symbol.bytes)
        if let flag = symbol.encodingIVar {
            try writeLong(1)
            try writeSymbol(MarshalSymbol("E"))
            out.append(flag ? 0x54 : 0x46)
        }
    }

    private mutating func writeBignum(_ bignum: MarshalBignum) throws {
        out.append(0x6c)                            // 'l'
        out.append(bignum.negative ? 0x2d : 0x2b)   // '-' / '+'
        try writeLong(bignum.limbs.count)
        for limb in bignum.limbs {
            out.append(UInt8(limb & 0xff))
            out.append(UInt8((limb >> 8) & 0xff))
        }
    }
}
