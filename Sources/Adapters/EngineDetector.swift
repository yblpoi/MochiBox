//
//  EngineDetector.swift
//  MochiBox
//
//  PRD §A.1 的 14 条固定优先级引擎识别规则。纯磁盘扫描，深度 ≤2，无 IO 副作用。
//

import Foundation

struct DetectionResult: Sendable {
    var engine: EngineKind
    var confidence: EngineConfidence
    var evidence: [String]
    var supportLevel: SupportLevel
    var reason: EngineReason?

    static func unknown(_ reason: EngineReason) -> DetectionResult {
        return DetectionResult(
            engine: .unknown,
            confidence: .low,
            evidence: [],
            supportLevel: .unknown,
            reason: reason
        )
    }
}

enum EngineDetector {

    /// Godot 的 `*.pck` 通配**不得**吞掉的精确文件名（PRD §A.1 v0.3.5）。
    ///
    /// 目前只有 `Scene.pck` —— 它是 SiglusEngine 的包名，同时匹配 godot 的 `*.pck`。
    /// 精确名优先于通配，这条优先关系写在匹配器里，不靠签名表的行序表达。
    static let godotPckExclusions: Set<String> = ["scene.pck"]

    // MARK: - 扫描根归一

    /// 若输入是 `.app` 且存在 `Contents/Resources/app.nw`，以它作为扫描根。
    static func normalizedScanRoot(_ input: URL) -> URL {
        let manager = FileManager.default
        let appNW = input.appendingPathComponent("Contents/Resources/app.nw", isDirectory: true)
        if input.pathExtension.lowercased() == "app", manager.fileExists(atPath: appNW.path) {
            return appNW
        }
        return input
    }

    // MARK: - 识别

    static func detect(_ input: URL) -> DetectionResult {
        let manager = FileManager.default
        let rawPath = input.standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: rawPath, isDirectory: &isDirectory) else {
            return .unknown(.notADirectory)
        }
        guard isDirectory.boolValue else {
            return .unknown(.notADirectory)
        }

        let root = normalizedScanRoot(input.standardizedFileURL)
        let context: ScanContext
        do {
            context = try ScanContext(root: root)
        } catch {
            return .unknown(.permissionDenied)
        }
        if context.isEmptyRoot {
            return .unknown(.emptyDirectory)
        }

        var matches: [(engine: EngineKind, confidence: EngineConfidence, evidence: [String])] = []
        for signature in signatures {
            let evidence = signature.evaluate(context)
            if !evidence.isEmpty {
                matches.append((signature.engine, signature.confidence, Array(evidence.prefix(5))))
            }
        }

        guard !matches.isEmpty else {
            return .unknown(.noSignatureMatched)
        }

        let sorted = matches.sorted { $0.engine.priority < $1.engine.priority }
        guard let winner = sorted.first else {
            return .unknown(.noSignatureMatched)
        }
        let reason: EngineReason? = sorted.count > 1 ? .signatureConflict : nil
        return DetectionResult(
            engine: winner.engine,
            confidence: winner.confidence,
            evidence: winner.evidence,
            supportLevel: winner.engine.declaredSupportLevel,
            reason: reason
        )
    }

    /// 生成入库条目。
    static func makeEntry(path: String, result: DetectionResult) -> GameEntry {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        return GameEntry(
            name: name,
            path: path,
            engine: result.engine,
            engineConfidence: result.confidence,
            engineEvidence: result.evidence,
            supportLevel: result.supportLevel,
            reason: result.reason
        )
    }

    // MARK: - 规则表

    private struct Signature {
        let engine: EngineKind
        let confidence: EngineConfidence
        let evaluate: (ScanContext) -> [String]
    }

    private static let signatures: [Signature] = [
        // 1. Ren'Py
        Signature(engine: .renpy, confidence: .high) { context in
            var evidence: [String] = []
            for suffix in [".rpy", ".rpyc"] {
                if let file = context.firstFile(inDirectory: "game", withSuffix: suffix) {
                    evidence.append("game/\(file)")
                    break
                }
            }
            if context.isDirectory("renpy") { evidence.append("renpy/") }
            if context.isDirectory("lib/py3-mac-universal") { evidence.append("lib/py3-mac-universal/") }
            return evidence
        },
        // 2. 吉里吉里
        Signature(engine: .kirikiri, confidence: .high) { context in
            var evidence: [String] = []
            if let xp3 = context.anyFile(withSuffix: ".xp3", maxDepth: 2) {
                evidence.append(xp3)
            }
            for name in ["tvpwin32.exe", "krkr.exe"] where context.exists(name) {
                evidence.append(name)
            }
            if context.exists("data/startup.tjs") { evidence.append("data/startup.tjs") }
            return evidence
        },
        // 3. RPG Maker MZ
        Signature(engine: .mz, confidence: .high) { context in
            return context.exists("js/rmmz_core.js") ? ["js/rmmz_core.js"] : []
        },
        // 4. RPG Maker MV
        Signature(engine: .mv, confidence: .high) { context in
            var evidence: [String] = []
            if context.exists("www/js/rpg_core.js") { evidence.append("www/js/rpg_core.js") }
            return evidence
        },
        // 5. EasyRPG (2000/2003)
        Signature(engine: .easyrpg, confidence: .high) { context in
            if context.exists("RPG_RT.ldb") && context.exists("RPG_RT.lmt") {
                return ["RPG_RT.ldb", "RPG_RT.lmt"]
            }
            return []
        },
        // 6. VX Ace
        Signature(engine: .rgss3, confidence: .high) { context in
            var evidence: [String] = []
            if context.fileContains("Game.ini", needle: "Library=RGSS3") { evidence.append("Game.ini#Library=RGSS3") }
            if let file = context.firstFile(inDirectory: "Data", withSuffix: ".rvdata2") { evidence.append("Data/\(file)") }
            if context.exists("Game.rgss3a") { evidence.append("Game.rgss3a") }
            return evidence
        },
        // 7. VX
        Signature(engine: .rgss2, confidence: .high) { context in
            var evidence: [String] = []
            if context.fileContains("Game.ini", needle: "Library=RGSS2") { evidence.append("Game.ini#Library=RGSS2") }
            if let file = context.firstFile(inDirectory: "Data", withSuffix: ".rvdata") { evidence.append("Data/\(file)") }
            if context.exists("Game.rgss2a") { evidence.append("Game.rgss2a") }
            return evidence
        },
        // 8. XP
        Signature(engine: .rgss1, confidence: .high) { context in
            var evidence: [String] = []
            if context.fileContains("Game.ini", needle: "Library=RGSS1") { evidence.append("Game.ini#Library=RGSS1") }
            if let file = context.firstFile(inDirectory: "Data", withSuffix: ".rxdata") { evidence.append("Data/\(file)") }
            if context.exists("Game.rgssad") { evidence.append("Game.rgssad") }
            return evidence
        },
        // 9. TyranoBuilder
        Signature(engine: .tyrano, confidence: .medium) { context in
            guard context.exists("data/system/Config.tjs") else { return [] }
            var evidence: [String] = ["data/system/Config.tjs"]
            if context.exists("tyrano/tyrano.js") {
                evidence.append("tyrano/tyrano.js")
            } else if context.fileContains("index.html", needle: "tyrano") {
                evidence.append("index.html#tyrano")
            } else {
                return []
            }
            return evidence
        },
        // 10. WOLF RPG Editor
        Signature(engine: .wolf, confidence: .high) { context in
            var evidence: [String] = []
            if context.exists("Data.wolf") { evidence.append("Data.wolf") }
            if let file = context.firstFile(inDirectory: "BasicData", withSuffix: ".dat") {
                evidence.append("BasicData/\(file)")
            }
            return evidence
        },
        // 11. Unity
        Signature(engine: .unity, confidence: .high) { context in
            var evidence: [String] = []
            for directory in context.directories(withSuffix: "_Data") {
                if context.exists("\(directory)/globalgamemanagers") {
                    evidence.append("\(directory)/globalgamemanagers")
                }
            }
            if let managed = context.anyFile(named: "Assembly-CSharp.dll", maxDepth: 5) {
                evidence.append(managed)
            }
            if evidence.isEmpty, let marker = context.anyFile(named: "globalgamemanagers", maxDepth: 5) {
                evidence.append(marker)
            }
            return evidence
        },
        // 12. Godot
        // 规则：`project.godot`；或根下 `*.pck`。
        // **`Scene.pck` 显式排除**：它同时匹配规则 13 的 siglus（PRD §A.1 v0.3.5 已写明），
        // 而 `*.pck` 是通配模式。按 PRD 新增原则「精确文件名必须先于通配模式命中，
        // 且该优先关系不得靠行序表达」，这里在**匹配器内部**排除，不动签名表的顺序 ——
        // 靠调整行序会让"行序"同时承担两种语义，后面任何人插一条规则都可能悄悄改变结果。
        Signature(engine: .godot, confidence: .high) { context in
            var evidence: [String] = []
            if context.exists("project.godot") { evidence.append("project.godot") }
            if let pck = context.topLevelFile(withSuffix: ".pck", excluding: EngineDetector.godotPckExclusions) {
                evidence.append(pck)
            }
            return evidence
        },
        // 13. SiglusEngine
        Signature(engine: .siglus, confidence: .high) { context in
            var evidence: [String] = []
            if context.exists("Scene.pck") { evidence.append("Scene.pck") }
            if context.exists("Gameexe.ini") { evidence.append("Gameexe.ini") }
            return evidence
        }
    ]
}

// MARK: - 扫描上下文

/// 只读目录快照，避免重复 stat（缓存可写，故用 class）。
final class ScanContext {
    let root: URL
    private let manager = FileManager.default
    private var listingCache: [String: [String]] = [:]

    init(root: URL) throws {
        self.root = root
        _ = try manager.contentsOfDirectory(atPath: root.path)
    }

    var isEmptyRoot: Bool {
        return names(in: "").isEmpty
    }

    /// 相对目录下的条目名（`""` 表示根）。
    func names(in relativeDirectory: String) -> [String] {
        if let cached = listingCache[relativeDirectory] { return cached }
        var directory = root
        if !relativeDirectory.isEmpty {
            directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        }
        let entries = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        var result = entries.filter { !$0.hasPrefix(".") }
        result.sort()
        return result
    }

    func exists(_ relativePath: String) -> Bool {
        let url = root.appendingPathComponent(relativePath)
        return manager.fileExists(atPath: url.path)
    }

    func isDirectory(_ relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        let url = root.appendingPathComponent(relativePath)
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    func firstFile(inDirectory relativeDirectory: String, withSuffix suffix: String) -> String? {
        if !relativeDirectory.isEmpty, !isDirectory(relativeDirectory) { return nil }
        for name in names(in: relativeDirectory) where name.lowercased().hasSuffix(suffix.lowercased()) {
            let relative = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            if !isDirectory(relative) { return name }
        }
        return nil
    }

    func topLevelFile(withSuffix suffix: String, excluding excluded: Set<String> = []) -> String? {
        for name in names(in: "") where name.lowercased().hasSuffix(suffix.lowercased()) {
            if excluded.contains(name.lowercased()) { continue }
            if !isDirectory(name) { return name }
        }
        return nil
    }

    func directories(withSuffix suffix: String) -> [String] {
        var result: [String] = []
        for name in names(in: "") where name.hasSuffix(suffix) {
            if isDirectory(name) { result.append(name) }
        }
        return result
    }

    /// 深度 ≤ maxDepth 的任意文件（返回相对路径）。
    func anyFile(withSuffix suffix: String, maxDepth: Int) -> String? {
        return searchFile(maxDepth: maxDepth) { name in
            return name.lowercased().hasSuffix(suffix.lowercased())
        }
    }

    func anyFile(named target: String, maxDepth: Int) -> String? {
        return searchFile(maxDepth: maxDepth) { name in
            return name.lowercased() == target.lowercased()
        }
    }

    private func searchFile(maxDepth: Int, match: (String) -> Bool) -> String? {
        var queue: [(path: String, depth: Int)] = [("", 0)]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for name in names(in: current.path) {
                let relative = current.path.isEmpty ? name : "\(current.path)/\(name)"
                if isDirectory(relative) {
                    if current.depth + 1 < maxDepth {
                        queue.append((relative, current.depth + 1))
                    }
                } else if match(name) {
                    return relative
                }
            }
        }
        return nil
    }

    func fileContains(_ relativePath: String, needle: String) -> Bool {
        let url = root.appendingPathComponent(relativePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.contains(needle)
    }
}
