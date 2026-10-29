//
//  probe_support.swift
//  MochiBox · E2E 领域层探针的公共骨架（TAP 输出 + 文件小工具）
//
//  不是被测代码：它只被 Tests/e2e/cases/domain/*.swift 引用，由 _domain_kit.mjs
//  追加到每个探针的源码清单末尾。放在这里是为了让"编号/计数/失败详情"只有一份实现。
//

import Foundation

enum TAP {
    nonisolated(unsafe) static var total = 0
    nonisolated(unsafe) static var pass = 0
    nonisolated(unsafe) static var fail = 0

    static func oneLine(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func ok(_ id: String, _ desc: String, _ condition: Bool, _ detail: String = "") {
        total += 1
        if condition {
            pass += 1
            print("ok \(total) - \(id) \(oneLine(desc))")
        } else {
            fail += 1
            print("not ok \(total) - \(id) \(oneLine(desc)) # 断言不成立")
            for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
                print("#   \(line)")
            }
        }
    }

    static func eq(_ id: String, _ desc: String, _ actual: String, _ expected: String) {
        ok(id, desc, actual == expected, "期望: \(expected)\n实际: \(actual)")
    }

    static func eqInt(_ id: String, _ desc: String, _ actual: Int, _ expected: Int) {
        ok(id, desc, actual == expected, "期望: \(expected)\n实际: \(actual)")
    }

    static func skip(_ id: String, _ desc: String, _ reason: String) {
        total += 1
        pass += 1
        print("ok \(total) - \(id) \(oneLine(desc)) # SKIP \(reason)")
    }

    static func finish() -> Int32 {
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        return fail == 0 ? 0 : 1
    }
}

enum Fs {
    static func make(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func names(_ url: URL) -> [String] {
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    static func text(_ url: URL) -> String {
        guard let data = FileIO.readData(url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ text: String, to url: URL) {
        try? FileIO.atomicWrite(Data(text.utf8), to: url, permissions: 0o644)
    }

    static func mode(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func json(_ url: URL) -> [String: Any]? {
        guard let data = FileIO.readData(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    static func lineCount(_ url: URL) -> Int {
        return text(url).components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    static func hasTempResidue(_ url: URL) -> Bool {
        return names(url).contains { $0.contains(".tmp-") }
    }
}

/// 命令行解析：所有探针共用 --work / --only（--http-port 供 D6 用）。
struct ProbeArgs {
    var only = ""
    var work = NSTemporaryDirectory()
    var httpPort = 0

    init() {
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--only": only = iterator.next() ?? ""
            case "--work": work = iterator.next() ?? work
            case "--http-port": httpPort = Int(iterator.next() ?? "0") ?? 0
            default: break
            }
        }
    }

    var root: URL { return URL(fileURLWithPath: work, isDirectory: true) }
}
