//
//  Stores.swift
//  MochiBox
//
//  基础设施层：路径、原子写、会话日志、library.json / settings.json / credentials.json / cache.jsonl。
//  依据 docs/architecture.md §7.4、§7.2；docs/prd.md §5.6–5.8。
//

import Foundation

// MARK: - 路径

/// 运行时目录解析。`--selftest` 时由调用方注入临时根，保证不写用户目录。
final class AppPaths: @unchecked Sendable {
    static let shared = AppPaths()

    let root: URL

    init(root: URL? = nil) {
        if let root = root {
            self.root = root.standardizedFileURL
        } else if let override = AppPaths.environmentRoot() {
            // 测试 / E2E / CI 用：把整个运行时目录挪走（存档、profile、端口表全跟着走）。
            // 为什么需要它：E2E 要在**同一份构建**上反复起浏览器，而 Chromium 的 profile
            // 会留下单实例锁（SingletonLock 等）；如果运行时目录落在用户目录且不可写，
            // 清理就会失败并被 Chrome 报成 `browser_exited_early` —— 那是环境问题，
            // 却长得像产品缺陷。把它挪到可写目录后，这条噪声从根上消失。
            self.root = override.standardizedFileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.root = base.appendingPathComponent("MochiBox", isDirectory: true)
        }
    }

    /// `MOCHI_DATA_DIR` 覆盖（空字符串视为未设置）。
    static func environmentRoot() -> URL? {
        let value = ProcessInfo.processInfo.environment["MOCHI_DATA_DIR"] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    var libraryURL: URL { return root.appendingPathComponent("library.json") }
    var settingsURL: URL { return root.appendingPathComponent("settings.json") }
    var credentialsURL: URL { return root.appendingPathComponent("credentials.json") }
    var cacheDirectory: URL { return root.appendingPathComponent("cache", isDirectory: true) }
    var logsDirectory: URL { return root.appendingPathComponent("logs", isDirectory: true) }
    var exportDirectory: URL { return root.appendingPathComponent("export", isDirectory: true) }

    /// 浏览器 profile 根（v0.2）：`<root>/browser-profiles/`。
    ///
    /// 每个游戏一个子目录（`<gameHash>/`）：MZ 的存档（localforage/IndexedDB）
    /// 按 profile + origin 隔离，共用 profile 会让两个游戏的存档互相污染。
    var browserProfilesDirectory: URL {
        return root.appendingPathComponent(K.webProfileDirectoryName, isDirectory: true)
    }

    /// Web 端口分配持久表（`web-ports.json`，原子写、0600）。
    var webPortsURL: URL {
        return root.appendingPathComponent(K.webPortAssignmentFileName)
    }

    func cacheShardURL(for pair: LanguagePair) -> URL {
        return cacheDirectory.appendingPathComponent(pair.cacheShard)
    }

    @discardableResult
    func ensureDirectories() -> Bool {
        let manager = FileManager.default
        do {
            for directory in [root, cacheDirectory, logsDirectory, exportDirectory] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            // profile 根用 0700：里面是浏览器的完整用户数据（含 IndexedDB 存档），
            // 不需要也不应该让同机其它账户读到。
            try manager.createDirectory(
                at: browserProfilesDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browserProfilesDirectory.path)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 文件读写

enum FileIO {
    /// 原子写：临时文件 → chmod → rename。
    static func atomicWrite(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [.atomic])
            if let permissions = permissions {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            try manager.moveItem(at: temporary, to: url)
            if let permissions = permissions {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw MochiBoxError(code: .ioError, message: "写入 \(url.lastPathComponent) 失败", underlying: "\(error)")
        }
    }

    static func readData(_ url: URL) -> Data? {
        return try? Data(contentsOf: url)
    }

    static func exists(_ url: URL) -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        let size = attributes[.size] as? NSNumber
        return size?.intValue ?? 0
    }

    static func tailLines(_ url: URL, count: Int) -> [String] {
        guard let data = readData(url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count <= count { return lines }
        return Array(lines.suffix(count))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

// MARK: - 会话日志

/// 会话日志（actor 语义用锁实现，可安全从任意隔离域调用）。
final class SessionLog: @unchecked Sendable {
    enum Level: String, Comparable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warn: return 2
            case .error: return 3
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            return lhs.rank < rhs.rank
        }
    }

    private let lock = NSLock()
    private var handle: FileHandle?
    private let url: URL?
    private let minLevel: Level
    private let sessionTag: String
    private let echoToStderr: Bool

    init(directory: URL?, sessionId: String, minLevel: Level = .info, echoToStderr: Bool = false) {
        self.minLevel = minLevel
        self.sessionTag = String(sessionId.prefix(4))
        self.echoToStderr = echoToStderr
        if let directory = directory {
            let manager = FileManager.default
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "session-\(Timestamp.fileStamp()).log"
            let fileURL = directory.appendingPathComponent(name)
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            }
            self.url = fileURL
            self.handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? self.handle?.seekToEnd()
        } else {
            self.url = nil
            self.handle = nil
        }
        // PRD §7.3：会话日志首行声明用户自证所有权。
        write(level: .info, component: "SessionLog", message: "userAttestsOwnership=true", fields: [:])
        // 会话创建时裁剪一次旧日志。放在首行声明**之后**：轮转记录不能把首行挤走。
        rotateIfNeeded()
    }

    var fileURL: URL? { return url }

    func debug(_ component: String, _ message: String, _ fields: [String: String] = [:]) {
        write(level: .debug, component: component, message: message, fields: fields)
    }

    func info(_ component: String, _ message: String, _ fields: [String: String] = [:]) {
        write(level: .info, component: component, message: message, fields: fields)
    }

    func warn(_ component: String, _ message: String, _ fields: [String: String] = [:]) {
        write(level: .warn, component: component, message: message, fields: fields)
    }

    func error(_ component: String, _ message: String, _ fields: [String: String] = [:]) {
        write(level: .error, component: component, message: message, fields: fields)
    }

    /// 按 level 分发到上面四个具名方法。
    /// `AgentDiagGate` 这类策略只决定"该写哪一级"，不该逼调用点写一个四级 switch。
    func emit(_ level: Level, _ component: String, _ message: String, _ fields: [String: String] = [:]) {
        write(level: level, component: component, message: message, fields: fields)
    }

    private func write(level: Level, component: String, message: String, fields: [String: String]) {
        guard level >= minLevel else { return }
        var line = "[\(Timestamp.iso8601Ms())][\(level.rawValue)][session=\(sessionTag)][\(component)] \(message)"
        if !fields.isEmpty {
            let suffix = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
            line += " " + suffix
        }
        let masked = SecretMask.mask(line)
        guard let data = (masked + "\n").data(using: .utf8) else { return }
        lock.lock()
        if let handle = handle {
            _ = try? handle.write(contentsOf: data)
        }
        lock.unlock()
        if echoToStderr {
            FileHandle.standardError.write(data)
        }
    }

    /// 会话创建时调用一次：把目录裁剪到最近 `K.logRetentionCount` 份会话日志。
    ///
    /// 为什么不是「每次 write 检查大小」：文件名带秒级时间戳，一次启动就是一个新文件，
    /// 会无界增长的是**份数**而不是单份大小；每次 write 扫目录既慢又不解决问题。
    ///
    /// 三条安全约束（按优先级）：
    /// 1. **当前文件永不删除** —— 即便它排在最旧（时钟回拨，或目录里有未来时间戳的
    ///    文件），删了就等于把正在写的句柄扔进 unlinked inode；
    /// 2. **只认 `session-yyyyMMdd-HHmmss.log`** —— 目录里可能有用户自己导出的诊断
    ///    （`notes.txt` / `session-backup.log`），一律不动；
    /// 3. **删除失败只记 warn** —— 权限 / 占用不该把日志写入带崩。
    ///
    /// 份数按**文件**算：同秒启动两次命中的是同一个文件（init 里先判存在、再追加），
    /// 不会因为「两次会话」而虚增两份。
    ///
    /// 不加锁：本函数只操作**其它**文件，从不碰 `handle`；当前文件已被约束 1 排除，
    /// 与并发 write 无交集。
    func rotateIfNeeded() {
        guard let url = url else { return }
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        // 时间戳定长（yyyyMMdd-HHmmss），字典序即时间序：省掉逐个 stat 与日期解析。
        let sessions = names.filter(SessionLog.isSessionLogName).sorted()
        guard sessions.count > K.logRetentionCount else { return }
        let current = url.lastPathComponent
        // dropLast 即「最新的 N 份」，再剔掉当前文件：它永远活下来。
        let doomed = sessions.dropLast(K.logRetentionCount).filter { $0 != current }
        var deleted = 0
        for name in doomed {
            do {
                try manager.removeItem(at: directory.appendingPathComponent(name))
                deleted += 1
            } catch {
                warn("SessionLog", "rotate_delete_failed", ["file": name, "error": "\(error.localizedDescription)"])
            }
        }
        guard deleted > 0 else { return }
        info("SessionLog", "rotate", ["deleted": "\(deleted)", "kept": "\(sessions.count - deleted)"])
    }

    /// `session-yyyyMMdd-HHmmss.log` 的**字面**形状判定（不校验日期是否真实存在）。
    ///
    /// 逐字符比对而非 `NSRegularExpression`：每次会话创建都要对目录里所有文件名跑一遍，
    /// 而「定长数字 + 一个连字符」一眼就能判死。`isASCII` 是为了挡住全角/阿拉伯数字
    /// —— `Character.isNumber` 对它们也返回 true。
    static func isSessionLogName(_ name: String) -> Bool {
        let prefix = "session-"
        let suffix = ".log"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let core = Array(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard core.count == 15, core[8] == "-" else { return false }
        for index in core.indices where index != 8 {
            guard core[index].isASCII, core[index].isNumber else { return false }
        }
        return true
    }

    func tail(_ count: Int) -> [String] {
        guard let url = url else { return [] }
        return FileIO.tailLines(url, count: count)
    }

    func close() {
        lock.lock()
        _ = try? handle?.close()
        handle = nil
        lock.unlock()
    }
}

// MARK: - Agent 诊断信封分级

/// Agent 诊断信封（`start_message_*`）的分级与节流。
///
/// **为什么单独成类型**：这条策略带着两处状态 —— "累计第几条"与"会话重启归零"。
/// 只抽一个 `code -> level` 的纯函数钉不住真正容易写错的三件事（首条立即报 /
/// 每 200 条补一行 / reset 后又是首条），而它们就是诊断分流接口的全部行为面。
///
/// 判定规则：
///   · `start_message_` 前缀 → `.info`（诊断，不是故障），并消耗节流计数；
///   · 其它 code → `.warn`（保持"Agent 内部错误"的既有语义），**不消耗**计数。
struct AgentDiagGate {
    enum Decision: Equatable {
        /// 该写这一行；正文由这里给，fields 由调用点补齐（信封内容不变）。
        case emit(SessionLog.Level, String)
        /// 节流命中：这一条什么都不写。
        case drop
    }

    /// 诊断信封累计条数。只统计 `start_message_*`。
    private(set) var count: Int = 0

    /// 会话重启归零。不归零，"首条立即报"只在第一个会话成立，之后要等第 400 条。
    mutating func reset() {
        count = 0
    }

    mutating func consume(code: String) -> Decision {
        guard code.hasPrefix("start_message_") else {
            return .emit(.warn, "Agent 内部错误")
        }
        count += 1
        // 与 SessionController.protocolMismatchDropped 的既有节流一致：首条立即，之后每 200 条。
        guard count == 1 || count % 200 == 0 else { return .drop }
        return .emit(.info, "Agent 诊断：消息部分行未命中译文")
    }
}

// MARK: - 设置

struct Credentials: Codable, Sendable, Equatable {
    var apiKey: String
    var deeplApiKey: String

    init(apiKey: String = "", deeplApiKey: String = "") {
        self.apiKey = apiKey
        self.deeplApiKey = deeplApiKey
    }

    enum CodingKeys: String, CodingKey { case apiKey, deeplApiKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiKey = container.tolerantValue(String.self, forKey: .apiKey, "")
        self.deeplApiKey = container.tolerantValue(String.self, forKey: .deeplApiKey, "")
    }
}

struct Settings: Codable, Sendable, Equatable {
    /// 设置 schema 版本。
    ///
    /// v2（v0.7）：`maxBatch` 20→60、`maxConcurrent` 2→4。**只改默认值不够**：
    /// 存量 `settings.json` 里已经把 20/2 写死了，读回来仍是旧值，提速对他们为 0。
    /// 因此 `init(from:)` 见到 < 2 就把这两个字段迁到新默认（用户手动改过的 7 也会被覆盖，
    /// 迁移只发生一次，之后保存写回 2）。
    var schemaVersion: Int = 2
    var backendType: BackendKind = .passthrough
    var endpoint: String = ""
    var model: String = "gpt-4o-mini"
    // MARK: - 语言
    // 字段名只能用 `srcLang` / `tgtLang`（PRD §5.4 显式禁止 `fromLang` / `toLang` 别名）。
    // **P0 恒为 `ja` / `zh-Hans`**（PRD v0.3 D-1）：设置页只读展示、`normalized()` 强制回落，
    // 写盘不会出现别的值。保留为可变字段只是给 P1 多语言留位。

    var srcLang: String = K.fixedSrcLang
    var tgtLang: String = K.fixedTgtLang
    var timeoutSec: Int = K.requestTimeoutSec
    var batchWindowMs: Int = K.batchWindowMs
    var maxBatch: Int = K.maxBatch
    var maxConcurrent: Int = K.maxConcurrent
    /// 单请求输入字数上限（`item.text.count` 累加）；块内再按它切子块。
    var batchCharBudget: Int = K.batchCharBudget
    /// OpenAI 兼容后端的 `max_tokens`；0 = 按输入自动估算。
    var maxOutputTokens: Int = K.maxOutputTokens
    /// 关闭推理的字段选择（ReasoningOffMode.rawValue）。
    ///
    /// 存 String 而不是 enum：手改 settings.json 写错值时能回落 auto，而不是让整份设置解码失败。
    /// 默认 auto 即"DeepSeek 端点自动关思考"，不需要 schemaVersion 迁移。
    var reasoningOffMode: String = ReasoningOffMode.auto.rawValue
    var attachTimeoutSec: Int = Int(K.cdpAttachTimeoutSec)
    var debugPortRange: [Int] = [K.debugPortLow, K.debugPortHigh]
    var agentEnabled: Bool = true
    var fontScale: Double = 1.0
    /// 游戏内绘制字体族（空 = 自动：苹方系）。
    ///
    /// 原版 MTool 推荐 Unifont Smooth，但字节级字体文件不随包分发（合规）：
    /// 这里只存**族名**，装没装由用户机器决定；Agent 侧再拼一条回退链兜底。
    var gameFontFamily: String = ""
    /// 数据回写总开关：把译文写进 `$data*` 的 name / messageN 等字段（Agent 侧的
    /// `dataPatchEnabled`）。默认开 —— 关掉就没有「缪特正在保护自己。」这种运行时拼接的译文。
    ///
    /// 缺键必须按 `true` 处理：老 settings.json 里没有这两个键，走 `tolerantValue` 的
    /// 默认值即可，不需要（也不许）抬 schemaVersion。
    var dataPatchEnabled: Bool = true
    /// 数据回写的子开关：是否连 `name` / `nickname`（含 `Game_Actor._name`）一起回写。
    ///
    /// Live2DInterfaceMZ 一类插件把 `$dataArmors[].name` 当服装动效表的 key、把 `_name`
    /// 拿去做换装联动比较，这类游戏要关的是**这个**，而不是整个数据回写。
    var dataPatchNames: Bool = true
    var maxTextRows: Int = K.maxTextRows
    var maxCacheEntries: Int = K.maxCacheEntries
    var cacheRetranslateOnBackendChange: Bool = false
    var allowSendTextToBackend: Bool = true
    var telemetryEnabled: Bool = false
    var logLevel: String = "info"
    var complianceAckVersion: Int = 0
    var uiLanguage: String = "zh-Hans"
    var extraLaunchArgs: [String] = []
    /// v0.2：浏览器可执行文件路径（`.app` 或可执行文件皆可）。
    ///
    /// 设置页**本轮没有输入框**（`MainWindow.swift` 冻结），只能手改
    /// `~/Library/Application Support/MochiBox/settings.json` 或设 `MOCHI_BROWSER_PATH`。
    /// 空串 = 走自动发现（`/Applications` → Playwright 缓存）。
    var browserPath: String = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, backendType, endpoint, model, srcLang, tgtLang
        case timeoutSec, batchWindowMs, maxBatch, maxConcurrent, attachTimeoutSec
        case batchCharBudget, maxOutputTokens, reasoningOffMode
        case debugPortRange, agentEnabled, fontScale, gameFontFamily
        case dataPatchEnabled, dataPatchNames, maxTextRows, maxCacheEntries
        case cacheRetranslateOnBackendChange, allowSendTextToBackend, telemetryEnabled
        case logLevel, complianceAckVersion, uiLanguage, extraLaunchArgs, browserPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        // 缺键 = v1 之前的旧文件，必须按 1 处理才能走到下面的迁移。
        // 不能直接用 tolerantValue 的默认值：默认值是 2，缺键文件会被误判成"已迁移"，
        // 20/2 原样留下 —— 这正是只改声明默认值不起作用的那条路径。
        if c.contains(.schemaVersion) {
            self.schemaVersion = c.tolerantValue(Int.self, forKey: .schemaVersion, 1)
        } else {
            self.schemaVersion = 1
        }
        self.backendType = c.tolerantValue(BackendKind.self, forKey: .backendType, defaults.backendType)
        self.endpoint = c.tolerantValue(String.self, forKey: .endpoint, defaults.endpoint)
        self.model = c.tolerantValue(String.self, forKey: .model, defaults.model)
        self.srcLang = c.tolerantValue(String.self, forKey: .srcLang, defaults.srcLang)
        self.tgtLang = c.tolerantValue(String.self, forKey: .tgtLang, defaults.tgtLang)
        self.timeoutSec = c.tolerantValue(Int.self, forKey: .timeoutSec, defaults.timeoutSec)
        self.batchWindowMs = c.tolerantValue(Int.self, forKey: .batchWindowMs, defaults.batchWindowMs)
        self.maxBatch = c.tolerantValue(Int.self, forKey: .maxBatch, defaults.maxBatch)
        self.maxConcurrent = c.tolerantValue(Int.self, forKey: .maxConcurrent, defaults.maxConcurrent)
        self.batchCharBudget = c.tolerantValue(Int.self, forKey: .batchCharBudget, defaults.batchCharBudget)
        self.maxOutputTokens = c.tolerantValue(Int.self, forKey: .maxOutputTokens, defaults.maxOutputTokens)
        // 非法值（手改文件写错、或降级自更新的版本）回落 auto，而不是让整份设置解码失败。
        let rawReasoningOffMode = c.tolerantValue(String.self, forKey: .reasoningOffMode, defaults.reasoningOffMode)
        self.reasoningOffMode = ReasoningOffMode(rawValue: rawReasoningOffMode)?.rawValue ?? defaults.reasoningOffMode
        self.attachTimeoutSec = c.tolerantValue(Int.self, forKey: .attachTimeoutSec, defaults.attachTimeoutSec)
        self.debugPortRange = c.tolerantValue([Int].self, forKey: .debugPortRange, defaults.debugPortRange)
        self.agentEnabled = c.tolerantValue(Bool.self, forKey: .agentEnabled, defaults.agentEnabled)
        self.fontScale = c.tolerantValue(Double.self, forKey: .fontScale, defaults.fontScale)
        self.gameFontFamily = c.tolerantValue(String.self, forKey: .gameFontFamily, defaults.gameFontFamily)
        // 缺键 = 老配置文件：取默认 true（不抬 schemaVersion）。类型写坏同样按 true 处理 ——
        // 回写是默认行为，宁可开着让用户手动关，不要因为一个坏字段把功能静默关掉。
        self.dataPatchEnabled = c.tolerantValue(Bool.self, forKey: .dataPatchEnabled, defaults.dataPatchEnabled)
        self.dataPatchNames = c.tolerantValue(Bool.self, forKey: .dataPatchNames, defaults.dataPatchNames)
        self.maxTextRows = c.tolerantValue(Int.self, forKey: .maxTextRows, defaults.maxTextRows)
        self.maxCacheEntries = c.tolerantValue(Int.self, forKey: .maxCacheEntries, defaults.maxCacheEntries)
        self.cacheRetranslateOnBackendChange = c.tolerantValue(Bool.self, forKey: .cacheRetranslateOnBackendChange, defaults.cacheRetranslateOnBackendChange)
        self.allowSendTextToBackend = c.tolerantValue(Bool.self, forKey: .allowSendTextToBackend, defaults.allowSendTextToBackend)
        self.telemetryEnabled = c.tolerantValue(Bool.self, forKey: .telemetryEnabled, defaults.telemetryEnabled)
        self.logLevel = c.tolerantValue(String.self, forKey: .logLevel, defaults.logLevel)
        self.complianceAckVersion = c.tolerantValue(Int.self, forKey: .complianceAckVersion, defaults.complianceAckVersion)
        self.uiLanguage = c.tolerantValue(String.self, forKey: .uiLanguage, defaults.uiLanguage)
        self.extraLaunchArgs = c.tolerantValue([String].self, forKey: .extraLaunchArgs, defaults.extraLaunchArgs)
        self.browserPath = c.tolerantValue(String.self, forKey: .browserPath, defaults.browserPath)

        // 存量迁移（schemaVersion < 2）：旧文件把 20/2 写死了，只改声明默认值等于没改。
        // 顺带把版本号抬到 2，下次保存就落在新 schema 上，不会反复迁移。
        if self.schemaVersion < defaults.schemaVersion {
            self.schemaVersion = defaults.schemaVersion
            self.maxBatch = defaults.maxBatch
            self.maxConcurrent = defaults.maxConcurrent
        }
    }

    /// 实际生效的后端（合规开关向下强制直通）。
    var effectiveBackend: BackendKind {
        if !allowSendTextToBackend { return .passthrough }
        return backendType
    }

    var languagePair: LanguagePair {
        return LanguagePair(src: srcLang, tgt: tgtLang)
    }

    /// 越界回落 + 告警收集（PRD P0-20：不崩溃、记日志）。
    func normalized() -> (settings: Settings, warnings: [String]) {
        var result = self
        var warnings: [String] = []

        func clampInt(_ name: String, _ value: Int, _ lower: Int, _ upper: Int) -> Int {
            if value < lower {
                warnings.append("\(name)=\(value) 低于下限，回落为 \(lower)")
                return lower
            }
            if value > upper {
                warnings.append("\(name)=\(value) 高于上限，回落为 \(upper)")
                return upper
            }
            return value
        }

        result.timeoutSec = clampInt("timeoutSec", timeoutSec, 1, 120)
        result.batchWindowMs = clampInt("batchWindowMs", batchWindowMs, 0, 2000)
        result.maxBatch = clampInt("maxBatch", maxBatch, 1, 200)
        result.maxConcurrent = clampInt("maxConcurrent", maxConcurrent, 1, 8)
        result.batchCharBudget = clampInt("batchCharBudget", batchCharBudget, 500, 20000)
        result.maxOutputTokens = clampInt("maxOutputTokens", maxOutputTokens, 0, 32768)
        result.attachTimeoutSec = clampInt("attachTimeoutSec", attachTimeoutSec, 5, 120)
        result.maxTextRows = clampInt("maxTextRows", maxTextRows, 100, 200000)
        result.maxCacheEntries = clampInt("maxCacheEntries", maxCacheEntries, 100, 10000000)

        // P0 语言对固定（PRD v0.3 D-1）：任何越界值都回落，不崩溃、记日志。
        if result.srcLang != K.fixedSrcLang {
            warnings.append("srcLang=\(result.srcLang) 在 P0 不支持，回落为 \(K.fixedSrcLang)")
            result.srcLang = K.fixedSrcLang
        }
        if result.tgtLang != K.fixedTgtLang {
            warnings.append("tgtLang=\(result.tgtLang) 在 P0 不支持，回落为 \(K.fixedTgtLang)")
            result.tgtLang = K.fixedTgtLang
        }

        if fontScale < 0.8 {
            warnings.append("fontScale=\(fontScale) 低于下限，回落为 0.8")
            result.fontScale = 0.8
        } else if fontScale > 1.3 {
            warnings.append("fontScale=\(fontScale) 高于上限，回落为 1.3")
            result.fontScale = 1.3
        }

        if debugPortRange.count != 2 || debugPortRange[0] < 1024 || debugPortRange[0] >= debugPortRange[1] || debugPortRange[1] > 65535 {
            warnings.append("debugPortRange 非法，回落为 [\(K.debugPortLow),\(K.debugPortHigh)]")
            result.debugPortRange = [K.debugPortLow, K.debugPortHigh]
        }

        // `browserPath` 只 trim：填错不在这里判死（用户可能手滑多了个空格，
        // 也可能填了 `.app` 目录）。真正的解析与"填错就继续下一级"在 `BrowserResolver`。
        result.browserPath = browserPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // 字体族名只 trim，不夹取：本机没装的族名由 Agent 的回退链兜底，
        // 在设置层判死会把"换个机器就有这个字体"的用户挡住。
        result.gameFontFamily = gameFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)

        // 放在 endpoint 校验之前：endpoint 非法会提前 return，此时也要能记下这条告警。
        if ReasoningOffMode(rawValue: result.reasoningOffMode) == nil {
            warnings.append("reasoningOffMode=\(result.reasoningOffMode) 非法，回落为 auto")
            result.reasoningOffMode = ReasoningOffMode.auto.rawValue
        }

        if !result.endpoint.isEmpty {
            let trimmed = result.endpoint.endpointBase
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                warnings.append("endpoint 不是合法的 http(s) 地址，已清空")
                result.endpoint = ""
                return (result, warnings)
            }
            result.endpoint = trimmed
        }

        if !["debug", "info", "warn", "error"].contains(result.logLevel) {
            warnings.append("logLevel=\(result.logLevel) 非法，回落为 info")
            result.logLevel = "info"
        }

        return (result, warnings)
    }

    var hasUsableBackend: Bool {
        switch effectiveBackend {
        case .passthrough: return true
        case .openai, .deepl: return !endpoint.isEmpty
        }
    }
}

// MARK: - 游戏库存储

final class LibraryStore: @unchecked Sendable {
    private let url: URL
    private let log: SessionLog?

    init(url: URL, log: SessionLog? = nil) {
        self.url = url
        self.log = log
    }

    /// 读取；损坏时把原文件改名为 `library.json.bak-<ts>` 并以空库启动。
    ///
    /// 备份名精确到秒，同一秒内的第二次损坏顺延 `-2` / `-3`…；
    /// **绝不删除**既有备份 —— 每一份损坏都要留下独立的原始字节（P0-04 证据保留）。
    func load() -> LibraryFile {
        guard let data = FileIO.readData(url) else {
            return LibraryFile()
        }
        do {
            let file = try FileIO.decoder.decode(LibraryFile.self, from: data)
            return LibraryFile(schemaVersion: file.schemaVersion, games: file.games)
        } catch {
            let backup = backupURL()
            try? FileManager.default.moveItem(at: url, to: backup)
            log?.warn("LibraryStore", "library.json 解析失败，已改名备份并以空库启动", ["backup": backup.lastPathComponent])
            return LibraryFile()
        }
    }

    func save(_ file: LibraryFile) throws {
        let data = try FileIO.encoder.encode(file)
        try FileIO.atomicWrite(data, to: url, permissions: 0o644)
    }

    /// 损坏文件的备份目标。同秒重名时顺延 `-2` / `-3`…，**不覆盖**任何既有备份：
    /// 先删后移会在 `moveItem` 失败时连上一份证据一起丢掉。
    private func backupURL() -> URL {
        let directory = url.deletingLastPathComponent()
        let stamp = Timestamp.fileStamp()
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent("library.json.bak-\(stamp)")
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("library.json.bak-\(stamp)-\(index)")
            index += 1
        }
        return candidate
    }
}

// MARK: - 设置存储

final class SettingsStore: @unchecked Sendable {
    private let settingsURL: URL
    private let credentialsURL: URL
    private let log: SessionLog?

    init(settingsURL: URL, credentialsURL: URL, log: SessionLog? = nil) {
        self.settingsURL = settingsURL
        self.credentialsURL = credentialsURL
        self.log = log
    }

    func loadSettings() -> Settings {
        guard let decoded = loadSettingsFromDisk() else {
            log?.warn("SettingsStore", "settings.json 缺失或解析失败，使用默认值")
            return Settings()
        }
        return decoded
    }

    /// 磁盘上的设置；文件缺失或解析失败时返回 nil，而不是默认值。
    ///
    /// 供"只回写单个字段"的场景（字号滑杆）判断基线是否存在：拿不到磁盘版本时
    /// 不能把默认值当基线写回去，否则会把用户已保存的设置冲成默认。
    func loadSettingsFromDisk() -> Settings? {
        guard let data = FileIO.readData(settingsURL) else { return nil }
        guard let decoded = try? FileIO.decoder.decode(Settings.self, from: data) else {
            return nil
        }
        let normalized = decoded.normalized()
        for warning in normalized.warnings {
            log?.warn("SettingsStore", warning)
        }
        return normalized.settings
    }

    func saveSettings(_ settings: Settings) throws {
        let normalized = settings.normalized()
        for warning in normalized.warnings {
            log?.warn("SettingsStore", warning)
        }
        let data = try FileIO.encoder.encode(normalized.settings)
        try FileIO.atomicWrite(data, to: settingsURL, permissions: 0o600)
    }

    func loadCredentials() -> Credentials {
        guard let data = FileIO.readData(credentialsURL) else { return Credentials() }
        return (try? FileIO.decoder.decode(Credentials.self, from: data)) ?? Credentials()
    }

    func saveCredentials(_ credentials: Credentials) throws {
        let data = try FileIO.encoder.encode(credentials)
        try FileIO.atomicWrite(data, to: credentialsURL, permissions: 0o600)
    }
}

// MARK: - 翻译缓存（追加写 JSONL）

actor TranslationCache {
    struct Entry: Sendable, Equatable {
        var text: String
        var translatedText: String
        var backend: String
        var seq: Int
        /// 写入时刻（落盘记录里的 `ts`）。
        var ts: Double
        /// 最近一次被 `get()` 命中的时刻。淘汰按它排序，`ts` 只在写入时前进。
        var lastUsed: Double
        var hitCount: Int
    }

    private let url: URL
    private let maxEntries: Int
    private let log: SessionLog?
    private var index: [String: Entry] = [:]
    private var seqCounter: Int = 0
    private var pendingHits: [String: Int] = [:]
    private var pendingHitTotal: Int = 0
    private var totalHits: Int = 0
    private var totalStores: Int = 0
    private var handle: FileHandle?
    private var loadSkippedLines: Int = 0
    /// appendRecord 的失败数：只在第一次失败时打 warn（避免磁盘满时刷屏）。
    private var appendFailureCount: Int = 0

    init(url: URL, maxEntries: Int = K.maxCacheEntries, log: SessionLog? = nil) {
        self.url = url
        self.maxEntries = maxEntries
        self.log = log
    }

    // MARK: 生命周期

    func load() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        guard let data = FileIO.readData(url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let entry = try? FileIO.decoder.decode(CacheEntry.self, from: lineData) else {
                loadSkippedLines += 1
                continue
            }
            seqCounter = max(seqCounter, entry.seq)
            if var existing = index[entry.key] {
                existing.hitCount += entry.hitCount
                if entry.seq >= existing.seq {
                    existing.text = entry.text
                    existing.translatedText = entry.translatedText
                    existing.backend = entry.backend
                    existing.seq = entry.seq
                    existing.ts = entry.ts
                }
                // 同一 key 有多条记录（写入 + 若干次命中落盘）时，「重启后的使用
                // 时刻起点」必须跟到最新那条记录 —— 停在最早一条会让命中过多次的
                // 热句按首次写入时刻参与淘汰，重启后先于真正的冷句被清掉。
                existing.lastUsed = max(existing.lastUsed, entry.ts)
                index[entry.key] = existing
            } else {
                index[entry.key] = Entry(
                    text: entry.text,
                    translatedText: entry.translatedText,
                    backend: entry.backend,
                    seq: entry.seq,
                    ts: entry.ts,
                    // 落盘记录不持久化使用时刻：重启后以写入时刻为起点，
                    // 之后每次命中照常刷新。
                    lastUsed: entry.ts,
                    hitCount: entry.hitCount
                )
            }
        }
        if loadSkippedLines > 0 {
            log?.warn("TranslationCache", "缓存有坏行已跳过", ["skipped": "\(loadSkippedLines)"])
        }
        evictIfNeeded()
        openHandle()
    }

    private func openHandle() {
        if handle == nil {
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
    }

    // MARK: 读写

    /// 命中即刷新 `lastUsed`（P0-10 的"最久未用"必须真的按使用时刻淘汰）。
    func get(_ key: String) -> Entry? {
        guard var entry = index[key] else { return nil }
        entry.lastUsed = Timestamp.nowMs()
        index[key] = entry
        return entry
    }

    func put(key: String, text: String, translatedText: String, backend: String) {
        seqCounter += 1
        let now = Timestamp.nowMs()
        let entry = Entry(
            text: text,
            translatedText: translatedText,
            backend: backend,
            seq: seqCounter,
            ts: now,
            lastUsed: now,
            hitCount: 0
        )
        index[key] = entry
        totalStores += 1
        appendRecord(CacheEntry(
            key: key,
            text: text,
            translatedText: translatedText,
            srcLang: "",
            tgtLang: "",
            backend: backend,
            seq: entry.seq,
            ts: entry.ts,
            hitCount: 0
        ))
        evictIfNeeded()
    }

    func noteHit(_ key: String) {
        totalHits += 1
        pendingHits[key, default: 0] += 1
        pendingHitTotal += 1
        if let existing = index[key] {
            var updated = existing
            updated.hitCount += 1
            index[key] = updated
        }
        if pendingHitTotal >= K.cacheHitFlushEvery {
            flushLocked()
        }
    }

    /// 把内存里的命中计数落盘（每 200 次或退出时）。
    func flush() {
        flushLocked()
        _ = try? handle?.synchronize()
    }

    private func flushLocked() {
        guard !pendingHits.isEmpty else { return }
        for (key, delta) in pendingHits {
            guard let existing = index[key] else { continue }
            seqCounter += 1
            appendRecord(CacheEntry(
                key: key,
                text: existing.text,
                translatedText: existing.translatedText,
                srcLang: "",
                tgtLang: "",
                backend: existing.backend,
                seq: seqCounter,
                ts: Timestamp.nowMs(),
                hitCount: delta
            ))
            index[key] = Entry(
                text: existing.text,
                translatedText: existing.translatedText,
                backend: existing.backend,
                seq: existing.seq,
                ts: existing.ts,
                lastUsed: existing.lastUsed,
                hitCount: existing.hitCount
            )
        }
        pendingHits.removeAll()
        pendingHitTotal = 0
    }

    /// 追加一条落盘记录。
    ///
    /// 写缓存是**尽力而为**（内存索引已经更新，丢一行不会让本次会话出错），所以这里
    /// 不抛错；但不能像旧实现那样用 try? 静默吞掉 —— 磁盘满 / 权限变化时缓存会
    /// 悄悄退化成"只在内存里有效"，重启后整批重新计费。首次失败打一行 warn
    /// （带 key 前缀），后续失败计数不再刷屏。
    private func appendRecord(_ record: CacheEntry) {
        openHandle()
        guard let handle = handle else {
            if appendFailureCount == 0 {
                log?.warn("TranslationCache", "缓存写入失败：没有可用的文件句柄", [
                    "key": String(record.key.prefix(8))
                ])
            }
            appendFailureCount += 1
            return
        }
        let data: Data
        do {
            data = try FileIO.encoder.encode(record)
        } catch {
            if appendFailureCount == 0 {
                log?.warn("TranslationCache", "缓存记录编码失败", [
                    "key": String(record.key.prefix(8)),
                    "error": "\(error)"
                ])
            }
            appendFailureCount += 1
            return
        }
        var payload = data
        payload.append(0x0A)
        do {
            try handle.write(contentsOf: payload)
        } catch {
            if appendFailureCount == 0 {
                log?.warn("TranslationCache", "缓存写入失败", [
                    "key": String(record.key.prefix(8)),
                    "error": "\(error)"
                ])
            }
            appendFailureCount += 1
        }
    }

    func clearAll() throws {
        index.removeAll()
        pendingHits.removeAll()
        pendingHitTotal = 0
        seqCounter = 0
        _ = try? handle?.close()
        handle = nil
        try FileIO.atomicWrite(Data(), to: url, permissions: 0o600)
        openHandle()
    }

    func stats() -> CacheStats {
        return CacheStats(
            entries: index.count,
            bytes: FileIO.fileSize(url),
            hits: totalHits,
            stores: totalStores
        )
    }

    var skippedLineCount: Int { return loadSkippedLines }

    // MARK: 淘汰

    private func evictIfNeeded() {
        guard index.count > maxEntries, maxEntries > 0 else { return }
        let overflow = index.count - maxEntries
        let sorted = index.sorted { lhs, rhs in lhs.value.lastUsed < rhs.value.lastUsed }
        for (key, _) in sorted.prefix(overflow) {
            index.removeValue(forKey: key)
        }
        log?.info("TranslationCache", "按最久未用淘汰缓存", ["evicted": "\(overflow)"])
    }
}
