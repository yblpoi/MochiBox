//
//  ErrorModels.swift
//  MochiBox
//
//  错误码与错误类型：ErrorCode / ErrorInfo / MochiBoxError / SecretMask。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

enum ErrorCode: String, Codable, Sendable {
    case authFailed = "auth_failed"
    case rateLimited = "rate_limited"
    case quotaExceeded = "quota_exceeded"
    case network
    case timeout
    case badResponse = "bad_response"
    case segmentMismatch = "segment_mismatch"
    case unsupportedProtocol = "unsupported_protocol"
    case circuitOpen = "circuit_open"
    case launcherNoExecutable = "launcher_no_executable"
    case cdpTimeout = "cdp_timeout"
    case agentNoHello = "agent_no_hello"
    case portUnavailable = "port_unavailable"
    case processExited = "process_exited"
    case attachFailed = "attach_failed"
    case ioError = "io_error"
    case backendNotConfigured = "backend_not_configured"
    case engineSymbolsMissing = "engine_symbols_missing"
    // ── v0.2 Web 运行后端（架构 §9.1）──
    /// 找不到 Chromium 内核浏览器（四级解析全部落空）。
    case browserNotFound = "browser_not_found"
    /// 游戏目录里没有可托管的 `index.html`（Windows 版发行目录仍可能缺文件）。
    case webRootMissing = "web_root_missing"
    /// 静态服务监听失败（非端口占用，例如权限/资源限制）。
    case webServerFailed = "web_server_failed"
    /// 静态服务端口被占用（TOCTOU 之后 bind 失败也走这里）。
    case webPortBusy = "web_port_busy"
    /// 浏览器进程起来后立即退出（与"起来了但 CDP 不通"区分开）。
    case browserExitedEarly = "browser_exited_early"
    /// 浏览器 profile 的单实例锁清不掉：锁不可删（权限 / `uchg` / 受管策略），
    /// 或锁指向的实例仍活着（= 同一存档正被另一个窗口使用）。
    ///
    /// 与 `browserExitedEarly` 的区别是**谁先失败**：这里根本没去拉浏览器
    /// （门禁在起静态服务与 `Process.launch` 之前），所以日志里不会出现 Chromium 那句
    /// `Failed to create a ProcessSingleton … Aborting now`；而 `browserExitedEarly`
    /// 是浏览器真起来了才退出。混成一个码会让用户照着"缺浏览器/架构不匹配"去排错。
    case profileLocked = "profile_locked"
    // ── v0.4 内置内核（架构 v0.4 §5.1）──
    /// 无 Aqua 会话（无 WindowServer / 无登录用户）：内置内核无法建窗。
    ///
    /// 判据是"换一台干净的、有登录桌面的 Mac 会不会自己好" → 是 → 环境缺口（退出码 3）。
    case kernelNoDesktopSession = "kernel_no_desktop_session"
    /// `WKWebView` 起不来 / 导航失败 / WebContent 进程被杀（系统层，重试通常无用）。
    case kernelLoadFailed = "kernel_load_failed"
    // ── v0.6 Agent RPC / 修改器（架构 v0.6 §2.2 / §3.4）──
    /// RPC 在 Host 侧超时（Agent 没回 `rpcResult`）。
    case rpcTimeout = "rpc_timeout"
    /// Agent 不认识该方法（版本不匹配 / 方法名拼错）。
    case rpcUnknownMethod = "rpc_unknown_method"
    /// Agent 侧执行失败但没有更具体的码：`message` 里带原始 `code: message`。
    case agentError = "agent_error"
    /// `$game*` 不存在（还没进场景 / 不是 MV/MZ）。
    case cheatUnavailable = "cheat_unavailable"
    /// id 越界（数据表长度 / 事件 id / actor id）。
    case cheatOutOfRange = "cheat_out_of_range"
    /// 参数非法（Host 与 Agent 都会抛：缺字段、类型不对、枚举不认识）。
    case cheatBadArgs = "cheat_bad_args"
    /// 路径/写入目标被安全边界拒绝（`cheat.setObjectPath`）。
    case cheatForbidden = "cheat_forbidden"

    /// 每个错误码的元数据：是否值得重试 + 兜底文案。
    ///
    /// 合成一张**穷尽**表（无 `default`）：新增 case 时编译器会逼着两栏一起填，
    /// 不会像原来那样"重试一张表、文案另一张表"，漏填一边还能静默兜底。
    ///
    /// `badResponse` 的 5xx 由 HTTP 层显式覆盖为可重试（`Translators` 传
    /// `retryable: true`），调用方的显式覆盖始终优先于本表。
    private var metadata: (retryable: Bool, message: String) {
        switch self {
        // 端口被占 / 监听偶发失败：换个端口或换个时机可能就成功（架构 §9.1）。
        // `profileLocked` 刻意落进 default(false)：锁不清掉就必然同样失败，
        // "再试一次"只会把同一句文案念第二遍（对比 `webPortBusy`：换端口/换时机**可能**成功）。
        case .authFailed:
            return (false, "后端不可用：认证失败（请检查 API Key）")
        case .rateLimited:
            return (true, "后端不可用：请求过于频繁（429）")
        case .quotaExceeded:
            return (false, "后端不可用：额度已用尽")
        case .circuitOpen:
            // PRD §5.2 / P0-13：熔断期请求根本不发出，**立即**重试必然立即失败，故 retryable
            // 必须为 false。false 不等于"不可恢复"——出路是 30 秒后的自动半开，UI 须显示
            // "约 N 秒后自动重试"，不得给出"立即重试"入口。
            return (false, "后端连续失败，已熔断（冷却后自动重试）")
        case .network:
            return (true, "后端不可用：网络不可达")
        case .timeout:
            return (true, "后端不可用：请求超时")
        case .badResponse:
            return (false, "后端返回无法解析的内容")
        case .segmentMismatch:
            return (false, "译文分段与原文不一致，已丢弃该条")
        case .unsupportedProtocol:
            return (false, "Agent 协议版本不兼容")
        case .launcherNoExecutable:
            return (false, "找不到可执行文件")
        case .cdpTimeout:
            return (false, "等待调试端口超时")
        case .agentNoHello:
            return (false, "Agent 注入后未收到握手")
        case .portUnavailable:
            return (true, "调试端口全部被占用")
        case .processExited:
            return (false, "游戏进程已退出")
        case .attachFailed:
            return (false, "连接游戏页面失败")
        case .ioError:
            return (false, "本地文件读写失败")
        case .backendNotConfigured:
            return (false, "未配置翻译后端")
        case .engineSymbolsMissing:
            return (false, "该页面不是 RPG Maker 游戏页")
        case .browserNotFound:
            return (false, "找不到 Chromium 内核浏览器（请安装 Chrome/Chromium/Edge/Brave，或指定路径）")
        case .webRootMissing:
            return (false, "游戏目录里没有可托管的 index.html")
        // 端口被占 / 监听偶发失败：换个端口或换个时机可能就成功（架构 §9.1）。
        case .webServerFailed:
            return (true, "本地静态服务启动失败")
        case .webPortBusy:
            return (true, "静态服务端口被占用")
        case .browserExitedEarly:
            return (false, "浏览器进程启动后立即退出")
        // 分支处置指引（关哪个窗口 / 删哪个文件 / 具体命令）写在抛错点的 `message` 里：
        // UI 显示的是 `code.rawValue + message`（架构 §9.3），一行兜底文案不承载指引。
        // `profileLocked` 刻意不可重试：锁不清掉就必然同样失败，"再试一次"只会把
        // 同一句文案念第二遍（对比 `webPortBusy`：换端口/换时机**可能**成功）。
        case .profileLocked:
            return (false, "浏览器 profile 被占用，单实例锁无法清理（请关闭另一个实例或手动删锁）")
        case .kernelNoDesktopSession:
            return (false, "当前会话没有登录桌面，内置窗口不可用（请用 --headless）")
        case .kernelLoadFailed:
            return (false, "内置浏览器内核启动失败")
        case .rpcTimeout:
            return (false, "游戏内 Agent 未在超时内回应")
        case .rpcUnknownMethod:
            return (false, "游戏内 Agent 不认识该调用（版本可能不匹配）")
        case .agentError:
            return (false, "游戏内 Agent 执行失败")
        case .cheatUnavailable:
            return (false, "等待游戏进入场景（引擎对象尚未就绪）")
        case .cheatOutOfRange:
            return (false, "id 越界（超出游戏数据表范围）")
        case .cheatBadArgs:
            return (false, "参数非法")
        case .cheatForbidden:
            return (false, "该路径/操作被安全边界拒绝")
        }
    }

    /// 是否值得重试（429 / 5xx / 网络 / 超时 / 熔断 / 端口）。
    var retryable: Bool { metadata.retryable }

    /// 一行兜底文案；调用点可用 `message:` 显式覆盖。
    var uiMessage: String { metadata.message }
}

struct ErrorInfo: Codable, Sendable, Equatable {
    var code: ErrorCode
    var message: String
    var retryable: Bool
    var httpStatus: Int?
    var rawSnippet: String?

    init(code: ErrorCode, message: String? = nil, retryable: Bool? = nil, httpStatus: Int? = nil, rawSnippet: String? = nil) {
        self.code = code
        self.message = message ?? code.uiMessage
        self.retryable = retryable ?? code.retryable
        self.httpStatus = httpStatus
        self.rawSnippet = rawSnippet
    }
}

/// 边界处统一抛出的错误类型。所有对外错误必须是 `MochiBoxError`。
struct MochiBoxError: Error, Sendable, CustomStringConvertible {
    var code: ErrorCode
    var message: String
    var retryable: Bool
    var httpStatus: Int?
    var rawSnippet: String?
    var underlying: String?

    init(
        code: ErrorCode,
        message: String? = nil,
        retryable: Bool? = nil,
        httpStatus: Int? = nil,
        rawSnippet: String? = nil,
        underlying: String? = nil
    ) {
        self.code = code
        self.message = message ?? code.uiMessage
        self.retryable = retryable ?? code.retryable
        self.httpStatus = httpStatus
        self.rawSnippet = rawSnippet.map { SecretMask.mask(String($0.prefix(K.rawSnippetLimit))) }
        self.underlying = underlying
    }

    var asErrorInfo: ErrorInfo {
        return ErrorInfo(
            code: code,
            message: message,
            retryable: retryable,
            httpStatus: httpStatus,
            rawSnippet: rawSnippet
        )
    }

    var description: String {
        return "MochiBoxError(\(code.rawValue)): \(message)"
    }
}

// MARK: - 脱敏

enum SecretMask {
    /// 规则表：**字面前缀** + 对应的**已编译**正则。
    ///
    /// 为什么带前缀：每条规则都要求一个字面量，且前缀里没有可选项 / 字符类 ——
    ///   · `(?<![A-Za-z0-9_\-])sk-[A-Za-z0-9_\-]+` 必须含 `sk-`（且 `sk-` 前不是词字符）
    ///   · `Bearer\s+…`            必须含 `Bearer`
    ///   · `DeepL-Auth-Key\s+…`     必须含 `DeepL-Auth-Key`
    /// 当前串不含该前缀 ⇒ 这条正则**不可能**匹配，跳过它与直接跑它的输出完全一致。
    /// 这是等价变换，不是"看起来不会命中"的启发式。（反例：拿 `token` / `key` 这类
    /// 泛词当闸门会漏掉 `sk-…` —— 那种串里一个 `key` 都没有。）
    ///
    /// 为什么预编译：`NSRegularExpression(pattern:)` 的编译成本比匹配本身大一个量级，
    /// 而这条路径每写一行会话日志都要走（`SessionLog.write`）。旧实现每次 `mask` 现编三条。
    /// `sk-` 后**至少 1 个**字符就脱敏：短 key（`sk-abc`）同样是凭据，
    /// 漏掉它等于把明文写进会话日志。`(?<![A-Za-z0-9_\-])` 是**左边界**：
    /// 没有它，放开长度下限会让 `task-manager` 这类普通单词里的 `sk-` 也被打码。
    /// 长度不足 8 的 token 由 `maskToken` 的兜底整体打码，绝不回退明文。
    private static let rules: [(trigger: String, regex: NSRegularExpression)] = [
        ("sk-", "(?<![A-Za-z0-9_\\-])sk-[A-Za-z0-9_\\-]+"),
        ("Bearer", "Bearer\\s+[A-Za-z0-9_\\-.=]+"),
        ("DeepL-Auth-Key", "DeepL-Auth-Key\\s+[A-Za-z0-9_\\-:]+")
    ].compactMap { trigger, pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        return (trigger, regex)
    }

    /// `sk-abcdefghijkl` → `sk-…ijkl`；长度不足 8 → `***`。
    static func mask(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // 快速路径：绝大多数日志行不含任何凭据形态，整串扫一遍就返回。
        guard let firstHit = rules.firstIndex(where: { contains($0.trigger, in: text) }) else {
            return text
        }

        var result = text
        for rule in rules[firstHit...] where contains(rule.trigger, in: result) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = rule.regex.matches(in: result, options: [], range: range)
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result) else { continue }
                let token = String(result[matchRange])
                result.replaceSubrange(matchRange, with: maskToken(token))
            }
        }
        return result
    }

    /// 字面子串查找（ASCII 触发词）。
    ///
    /// 不用 `String.contains`：它走 ICU + 字形簇感知，实测 ~2.4µs/次（本机 -O），
    /// 三个触发词就是 ~7µs —— 比它要省掉的正则还贵。这里在 UTF-8 字节上做 `memmem`。
    ///
    /// 字节级匹配与字符级匹配在这里等价：UTF-8 里 ASCII 字节不会出现在多字节序列内部，
    /// 所以命中 ASCII 触发词 ⇔ 命中该子串。
    private static func contains(_ trigger: String, in text: String) -> Bool {
        let found = text.utf8.withContiguousStorageIfAvailable { buffer -> Bool in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return false }
            return trigger.utf8.withContiguousStorageIfAvailable { needle -> Bool in
                guard let needleBase = needle.baseAddress, needle.count > 0 else { return false }
                return memmem(base, buffer.count, needleBase, needle.count) != nil
            } ?? false
        }
        if let found = found { return found }
        // 非连续存储（桥接 NSString 等）→ 退回 Foundation 的字面量查找。
        return text.range(of: trigger, options: .literal) != nil
    }

    static func maskToken(_ token: String) -> String {
        guard token.count >= 8 else { return "***" }
        return "sk-…" + String(token.suffix(4))
    }
}

