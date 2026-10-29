//
//  TranslationModels.swift
//  MochiBox
//
//  翻译请求与结果：BackendKind / TranslationRequest / TranslationResult / LanguagePair / PipelineOutcome / PipelineBatchResult / BackendStatus。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

// MARK: - 翻译请求 / 响应

enum BackendKind: String, Codable, Sendable {
    case passthrough
    case openai
    case deepl

    var uiLabel: String {
        switch self {
        case .passthrough: return "直通（离线）"
        case .openai: return "OpenAI 兼容"
        case .deepl: return "DeepL"
        }
    }
}

/// 如何在请求体里关闭模型推理（思考）。
///
/// 背景：deepseek-flash 默认开启思考（effort=high），思维链会把 max_tokens
/// 预算吃光 —— content 为空、finish_reason=length，用户看到的是"翻译全失败、
/// 日语还是日语"。各家关闭字段互不相同，且**一次只能发一个**（同时发两套会被判 400）。
enum ReasoningOffMode: String, Codable, Sendable, CaseIterable {
    /// 默认：endpoint host 含 "deepseek" → 发 thinking.type=disabled；其它端点不发送。
    case auto
    /// DeepSeek 官方：thinking = {"type": "disabled"}。
    case thinkingDisabled
    /// DeepSeek / vLLM / OpenAI GPT-5.x：reasoning_effort = "none"。
    /// 注意 minimal 不等于关闭（官方映射成 low）。
    case reasoningEffortNone
    /// OpenRouter：reasoning = {"effort": "none"}。
    case openRouterEffortNone
    /// vLLM（Qwen 系模板）：chat_template_kwargs.enable_thinking = false。
    case vllmEnableThinkingFalse
    /// SiliconFlow：enable_thinking = false。
    case siliconflowEnableThinkingFalse
    /// 不发送任何字段（确认后端不需要/不接受时手动选）。
    case never

    var uiLabel: String {
        switch self {
        case .auto: return "自动（DeepSeek 端点关闭思考）"
        case .thinkingDisabled: return "thinking.type = disabled"
        case .reasoningEffortNone: return "reasoning_effort = none"
        case .openRouterEffortNone: return "reasoning.effort = none（OpenRouter）"
        case .vllmEnableThinkingFalse: return "enable_thinking = false（vLLM）"
        case .siliconflowEnableThinkingFalse: return "enable_thinking = false（SiliconFlow）"
        case .never: return "不发送（保持后端默认）"
        }
    }
}

struct TranslationRequestItem: Codable, Sendable, Equatable {
    var key: String
    var text: String
    var segments: [Segment]
    /// 文本用途；实时流不传（`nil`），全文模式按扫描路径推断。
    /// 可选字段：旧调用点与旧 JSON 都不需要改。
    var category: TranslationCategory? = nil
    /// 本条命中的术语对（由全文控制器算好）。管线按 chunk 取并集写进 request。
    var glossary: [GlossaryPair]? = nil
    /// 跳过缓存直接重发（术语违例重译用）。`nil`/`false` = 正常查缓存。
    /// 可选字段：旧调用点与旧 JSON 都不需要改。
    var ignoreCache: Bool? = nil
    /// 上一条译文没遵守、这次必须逐字使用的术语对。管线按 chunk 取并集写进 request：
    /// `systemPrompt` 是 request 级，放在 item 上 provider 取不到。
    var emphasis: [GlossaryPair]? = nil
}

struct TranslationRequest: Codable, Sendable, Equatable {
    var items: [TranslationRequestItem]
    var srcLang: String
    var tgtLang: String
    var backend: BackendKind
    var timeoutMs: Int
    var requestId: String
    /// 本批命中的术语对（只放出现过的，不放大表）。`nil` = 无约束。
    var glossary: [GlossaryPair]? = nil
    /// 本批**必须逐字使用**的术语对（上一版违例的那些）。`nil` = 无强调段。
    /// 不参与 `TranslationProfile`，也不进 `TranslationPrompt.version`：正常请求不变，
    /// 旧缓存继续有效。
    var emphasis: [GlossaryPair]? = nil
}

/// 提示词版本：进入缓存 profile。改 prompt 规则时必须升。
enum TranslationPrompt {
    static let version = "p2"
}

/// 缓存 profile 的**唯一**算法：类别 + 本条实际注入的术语束。
///
/// 全文与实时两条链路必须调同一个函数，否则同一句会算出两个 key：
/// 全文预译过的句子运行时命中不了，等于重复计费。
enum TranslationProfile {
    static func id(category: TranslationCategory, pairs: [GlossaryPair]) -> String {
        let material = pairs
            .sorted { lhs, rhs in
                if lhs.source != rhs.source {
                    return lhs.source.utf8.lexicographicallyPrecedes(rhs.source.utf8)
                }
                return lhs.target.utf8.lexicographicallyPrecedes(rhs.target.utf8)
            }
            .map { "\($0.source)\u{1F}\($0.target)" }
            .joined(separator: "\n")
        let hash = material.isEmpty ? "0" : String(Segmenter.sha256Hex(material).prefix(12))
        // `.other` 与 `.dialogue` 的提示规则相同（都是 nil）：profile 也归一到同一档，
        // 否则从落盘文件加载的条目（path 已丢、类别只能判成 other）永远命中不了实时缓存。
        let bucket = category == .other ? TranslationCategory.dialogue : category
        return "\(TranslationPrompt.version)|c:\(bucket.rawValue)|g:\(hash)"
    }
}

struct TranslationResultItem: Codable, Sendable, Equatable {
    var key: String
    var translatedText: String
    var translatedSegments: [Segment]?
    var cached: Bool
    var latencyMs: Int?
}

struct TranslationResult: Codable, Sendable, Equatable {
    var requestId: String
    var items: [TranslationResultItem]
    var backend: BackendKind
    var error: ErrorInfo?
}

struct LanguagePair: Codable, Sendable, Hashable {
    var src: String
    var tgt: String

    var cacheShard: String {
        return "cache.\(src)-\(tgt).jsonl"
    }
}

/// 管线单条结果。
enum PipelineOutcome: Sendable {
    case hit(TranslationResultItem)
    case pending
    case passthrough(TranslationResultItem)
    case failed(ErrorInfo)
    /// 命中 `SkipRules`（纯数字 / 纯标点 / 纯空白 / 过短 / 已暂停）。
    /// 该分支**不查缓存、不入队、不写缓存**（docs/architecture.md §7.8），
    /// 因此 `status` 必须是 `.skipped`，不得落在 `.hit` / `.translated` 冒充已翻译。
    case skipped(reason: String)
}

/// 管线一批结果回调载体。
struct PipelineBatchResult: Sendable {
    var requestId: String
    var items: [TranslationResultItem]
    var backend: BackendKind
    /// **块级**失败：整块请求失败 / 熔断 / 直通降级。
    var error: ErrorInfo?
    /// **单条**失败：key → 错误（段数不符且单条重试后仍失败）。
    ///
    /// 与 `error` 分开是因为两者的处置完全不同：`error` 会让整波降级、把本批所有
    /// 还没回来的 key 都标失败；这里只该把对应的那一行标失败。
    var itemErrors: [String: ErrorInfo] = [:]
}

enum BackendStatus: Sendable, Equatable {
    case ok
    case degraded(ErrorInfo)
    case circuitOpen(until: Date)

    var label: String {
        switch self {
        case .ok: return "后端正常"
        case .degraded(let info): return info.code.uiMessage
        // PRD P0-13：熔断期不得呈现为终局失败，也不要给"立即重试"的暗示。
        // 这里直接算剩余秒数，会话头才能显示"约 N 秒后自动重试"。
        case .circuitOpen(let until):
            let seconds = Int(ceil(until.timeIntervalSinceNow))
            // 窗口已过但还没拿到下一次结果：说明正在半开试探，别显示"约 0 秒"。
            if seconds <= 0 { return "后端熔断中（正在重试…）" }
            return "后端熔断中（约 \(seconds) 秒后自动重试）"
        }
    }
}

