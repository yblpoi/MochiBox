//
//  Translators.swift
//  MochiBox
//
//  翻译后端：passthrough / openai / deepl + HTTP 封装 + 韧性策略（批量窗口、并发闸门、退避、熔断）。
//  依据 docs/prd.md §5.4；docs/architecture.md §3.4、§7.6。
//

import Foundation

// MARK: - endpoint 归一化

extension String {
    /// 拼接路径前去掉结尾的 `/`（用户可能把 endpoint 填成 `https://host/`）。
    var endpointBase: String {
        return hasSuffix("/") ? String(dropLast()) : self
    }
}

// MARK: - HTTP 封装

/// 薄封装 `URLSession`：JSON POST、超时、状态码分流、响应体截断脱敏。
struct HTTPPoster: Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Double(K.requestTimeoutSec)
            configuration.timeoutIntervalForResource = Double(K.requestTimeoutSec) * 2
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 返回 (HTTP 状态码, 响应体)。网络层错误统一转 `MochiBoxError`。
    func postJSON(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch let error as URLError {
            throw HTTPPoster.mapURLError(error)
        } catch {
            throw MochiBoxError(code: .network, message: "网络请求失败", underlying: "\(error)")
        }
    }

    /// 返回 (HTTP 状态码, 响应体)，供 `/json/list` 之类的 GET 探测使用。
    func getJSON(url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch let error as URLError {
            throw HTTPPoster.mapURLError(error)
        } catch {
            throw MochiBoxError(code: .network, message: "网络请求失败", underlying: "\(error)")
        }
    }

    static func mapURLError(_ error: URLError) -> MochiBoxError {
        switch error.code {
        case .timedOut:
            return MochiBoxError(code: .timeout, message: "请求超时", underlying: "\(error.code.rawValue)")
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed,
             .appTransportSecurityRequiresSecureConnection:
            return MochiBoxError(code: .network, message: "网络不可达（\(error.localizedDescription)）", underlying: "\(error.code.rawValue)")
        case .cancelled:
            return MochiBoxError(code: .network, message: "请求已取消", underlying: "cancelled")
        default:
            return MochiBoxError(code: .network, message: "网络错误：\(error.localizedDescription)", underlying: "\(error.code.rawValue)")
        }
    }

    /// 状态码 → `MochiBoxError`（六种响应形状均有明确错误码）。
    static func mapStatus(_ status: Int, body: Data) -> MochiBoxError? {
        let snippet = String(decoding: body.prefix(K.rawSnippetLimit), as: UTF8.self)
        if status == 200 || status == 201 {
            return nil
        }
        if status == 401 || status == 403 {
            return MochiBoxError(code: .authFailed, httpStatus: status, rawSnippet: snippet)
        }
        if status == 402 || status == 456 {
            return MochiBoxError(code: .quotaExceeded, httpStatus: status, rawSnippet: snippet)
        }
        if status == 429 {
            return MochiBoxError(code: .rateLimited, httpStatus: status, rawSnippet: snippet)
        }
        if status >= 500 {
            return MochiBoxError(
                code: .badResponse,
                message: "后端服务错误（HTTP \(status)）",
                retryable: true,
                httpStatus: status,
                rawSnippet: snippet
            )
        }
        return MochiBoxError(code: .badResponse, message: "后端返回异常状态码 \(status)", httpStatus: status, rawSnippet: snippet)
    }
}

// MARK: - Provider 协议

protocol TranslatorProvider: Sendable {
    var kind: BackendKind { get }
    /// 单批上限由调用方（ResiliencePolicy）保证；实现内部不得自行拆分。
    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult]
}

extension TranslatorProvider {
    /// 设置页"测试连接"。
    func probe(timeoutMs: Int) async -> (ok: Bool, status: Int?, latencyMs: Int, error: ErrorInfo?) {
        let started = Date()
        let item = TranslationRequestItem(key: "probe", text: "こんにちは", segments: [Segment(kind: .text, value: "こんにちは")])
        let request = TranslationRequest(
            items: [item],
            srcLang: "ja",
            tgtLang: "zh-Hans",
            backend: kind,
            timeoutMs: timeoutMs,
            requestId: UUID().uuidString
        )
        do {
            _ = try await translate([request])
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return (true, 200, latency, nil)
        } catch let error as MochiBoxError {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return (false, error.httpStatus, latency, error.asErrorInfo)
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return (false, nil, latency, MochiBoxError(code: .network, underlying: "\(error)").asErrorInfo)
        }
    }
}

/// 逐条请求的后端：`translate(_ batch:)` 的外壳由扩展统一提供，实现只写 `translateOne`。
protocol BatchTranslationProvider: TranslatorProvider {
    func translateOne(_ request: TranslationRequest) async throws -> TranslationResult
}

extension BatchTranslationProvider {
    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        var results: [TranslationResult] = []
        for request in batch {
            results.append(try await translateOne(request))
        }
        return results
    }
}

// MARK: - 直通

struct PassthroughProvider: TranslatorProvider {
    var kind: BackendKind { return .passthrough }

    func translate(_ batch: [TranslationRequest]) async throws -> [TranslationResult] {
        return batch.map { request in
            let items = request.items.map { item in
                TranslationResultItem(
                    key: item.key,
                    translatedText: item.text,
                    translatedSegments: item.segments,
                    cached: false,
                    latencyMs: 0
                )
            }
            return TranslationResult(requestId: request.requestId, items: items, backend: .passthrough, error: nil)
        }
    }
}

// MARK: - OpenAI 兼容

struct OpenAICompatibleProvider: BatchTranslationProvider {
    let endpoint: String
    let apiKey: String
    let model: String
    let poster: HTTPPoster
    /// 用户配置的单请求输出上限；0 = 按输入字数自动估算。
    let maxOutputTokens: Int
    /// 如何关闭推理（思考）。默认 auto：只对 DeepSeek 端点生效。
    let reasoningOffMode: ReasoningOffMode

    init(
        endpoint: String,
        apiKey: String,
        model: String,
        maxOutputTokens: Int = 0,
        reasoningOffMode: ReasoningOffMode = .auto,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.reasoningOffMode = reasoningOffMode
        self.poster = HTTPPoster(session: session)
    }

    var kind: BackendKind { return .openai }

    /// 空 content 错误的固定前缀。
    ///
    /// `TranslationPipeline.runSubchunk` 用它判定「不拆块」（空内容与块大小无关）。
    /// 改文案时必须两边一起改 —— 前缀失配的后果是 5 条失败拆成 9 次请求。
    static let emptyContentMessagePrefix = "模型返回空内容"

    /// 基础提示词。改动措辞时**必须升 `TranslationPrompt.version`**：
    /// profile 只有版本号参与，不升的话旧缓存会被当成新规则的产物复用。
    static let baseSystemPrompt = """
    你是游戏文本翻译器。用户会给一个 JSON 字符串数组，每个字符串是一行待翻译文本；\
    每个字符串内部可能含有 U+001F（不可见分隔符）分隔的多个段落。\
    要求：逐条翻译，保持数组长度、顺序与每条的段落数量完全不变，段落之间仍用 U+001F 连接；\
    不要翻译数字、占位符（如 %1）、转义码与符号；仅输出一个 JSON 字符串数组，不要解释，不要 Markdown 围栏。
    """

    /// 在基础提示词后追加「目标语言 + 类别规则 + 术语表」。
    ///
    /// 输出形状固定为：`baseSystemPrompt` + 目标语言 + 可选类别规则/术语 + 尾部输出约束。
    /// **目标语言无条件追加**，所以不要再写"空上下文时逐字节等于 base"的假设。
    /// - **只能放 system message**：mock 与真实解析都要求 user 是纯 JSON 数组。
    /// - Parameter emphasis: 上一版译文违反的术语对。只用于修复请求；为空时逐字节等于
    ///   正常请求的提示词（因此**不需要**升 `TranslationPrompt.version`，旧缓存继续有效）。
    static func systemPrompt(
        categories: [TranslationCategory],
        glossary: [GlossaryPair],
        emphasis: [GlossaryPair] = []
    ) -> String {
        var rules: [String] = []
        for category in categories {
            guard let rule = category.promptRule else { continue }
            if !rules.contains(rule) { rules.append(rule) }
        }
        // 目标语言**无条件**追加：原提示词里根本没写译成什么语言，实时流又常常没有类别/术语，
        // 只靠模型从中文 system prompt 猜方向（可能出繁体或英文）。
        var lines = [baseSystemPrompt, "", "目标语言：简体中文（zh-Hans）。"]
        if !rules.isEmpty {
            lines.append("按文本用途遵守以下规则：")
            for rule in rules { lines.append("- \(rule)") }
        }
        // keepAsIs（HP/MP/LV）单独成段：混在 `HP => HP` 里，模型有概率把它"顺"成中文。
        let keep = glossary.filter { GlossaryKey.normalize($0.source) == GlossaryKey.normalize($0.target) }
        let translate = glossary.filter { GlossaryKey.normalize($0.source) != GlossaryKey.normalize($0.target) }
        if !translate.isEmpty {
            lines.append("术语表（必须严格使用；不得改译、不得加括号或说明）：")
            for pair in translate { lines.append("\(pair.source) => \(pair.target)") }
        }
        if !keep.isEmpty {
            lines.append("以下词保持原文，不要翻译：")
            lines.append(keep.map { $0.source }.joined(separator: "、"))
        }
        // 修复请求专用：只列上一版**违背**的译名，措辞比术语表更硬。
        // 位置在术语表之后、输出约束之前 —— 两类约束都读完了才收尾。
        if !emphasis.isEmpty {
            lines.append("上一版译文未遵守下列译名，必须逐字使用，不得改写或使用同义译名：")
            for pair in emphasis { lines.append("\(pair.source) => \(pair.target)") }
        }
        // 把最关键的输出约束再放到最后：base 里的同义句已经被前面几段推远了，
        // 模型对「最后一条指令」的遵守率明显更高。
        lines.append("")
        lines.append("只输出 JSON 字符串数组；长度、顺序、每条的 U+001F 分段数必须与输入完全一致。")
        return lines.joined(separator: "\n")
    }

    /// 单请求输出上限：用户配置 > 0 时用它，否则按输入字数估算（下限 512、上限 4096）。
    ///
    /// 上限是 4096 而不是 8192：deepseek 这类模型的单次输出上限常见就是 4096，
    /// 传更大的值不会多给预算；而 **reasoning 型模型会把预算先花在思维链上**，
    /// 预算给得越大，content 反而越容易是空串或半截 JSON（解析失败 → 整块重来）。
    func outputTokenBudget(inputs: [String]) -> Int {
        if maxOutputTokens > 0 { return maxOutputTokens }
        let characters = inputs.reduce(0) { $0 + $1.count }
        return min(4096, max(512, characters * 2))
    }

    /// 关闭推理要注入的字段（一次只返回一组，同时发两套会被部分后端直接判 400）。
    ///
    /// `auto` 只对 DeepSeek 官方端点生效：那几个模型默认开启思考，思维链会把
    /// `max_tokens` 先花光 → `content` 空、`finish_reason=length`，表现就是"翻译全失败"。
    /// 未知 host 一律不发：多数第三方兼容端点见到不认识的字段会返回 400。
    func reasoningOffField() -> [String: Any]? {
        switch reasoningOffMode {
        case .auto:
            let host = URL(string: endpoint)?.host?.lowercased() ?? ""
            guard host.contains("deepseek") else { return nil }
            return ["thinking": ["type": "disabled"]]
        case .thinkingDisabled:
            return ["thinking": ["type": "disabled"]]
        case .reasoningEffortNone:
            return ["reasoning_effort": "none"]
        case .openRouterEffortNone:
            return ["reasoning": ["effort": "none"]]
        case .vllmEnableThinkingFalse:
            return ["chat_template_kwargs": ["enable_thinking": false]]
        case .siliconflowEnableThinkingFalse:
            return ["enable_thinking": false]
        case .never:
            return nil
        }
    }

    func translateOne(_ request: TranslationRequest) async throws -> TranslationResult {
        let started = Date()
        guard !endpoint.isEmpty else {
            throw MochiBoxError(code: .backendNotConfigured)
        }
        let base = endpoint.endpointBase
        guard let url = URL(string: base + "/v1/chat/completions") else {
            throw MochiBoxError(code: .backendNotConfigured, message: "endpoint 非法：\(endpoint)")
        }
        let inputs = request.items.map { $0.text }
        guard let inputsData = try? JSONSerialization.data(withJSONObject: inputs, options: [.sortedKeys]),
              let inputsText = String(data: inputsData, encoding: .utf8) else {
            throw MochiBoxError(code: .badResponse, message: "无法构造请求体")
        }
        let categories = request.items.compactMap { $0.category }
        let system = OpenAICompatibleProvider.systemPrompt(
            categories: categories,
            glossary: request.glossary ?? [],
            emphasis: request.emphasis ?? []
        )
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // 不显式给 max_tokens 时，很多兼容后端按 256/512 截断：60 条一批会被砍成半句。
            // 0 = 自动：中文字符大致 1 token/字，长文按 2×输入字数给，夹在 512...4096。
            "max_tokens": outputTokenBudget(inputs: inputs),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": inputsText]
            ]
        ]
        // 关闭推理：注入一组字段（auto 只对 DeepSeek 生效）。关闭后 temperature 才真正生效，
        // 不关闭时思维链会先吃掉 max_tokens，content 直接是空串。
        let reasoningField = reasoningOffField()
        if let field = reasoningField {
            body.merge(field) { _, new in new }
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            throw MochiBoxError(code: .badResponse, message: "无法构造请求体")
        }
        let headers = ["Authorization": "Bearer \(apiKey)"]
        let timeout = TimeInterval(request.timeoutMs) / 1000.0
        var (status, data) = try await poster.postJSON(url: url, headers: headers, body: bodyData, timeout: timeout)
        // 400/422 = 后端不认识这个字段（第三方兼容端点常见）。去掉它重发**同一请求**一次：
        // 宁可退回"带思考"的旧行为，也不要因为一个可选开关让整批翻译彻底失败。
        if (status == 400 || status == 422), let field = reasoningField {
            var plain = body
            for key in field.keys { plain.removeValue(forKey: key) }
            if let plainData = try? JSONSerialization.data(withJSONObject: plain, options: []) {
                (status, data) = try await poster.postJSON(url: url, headers: headers, body: plainData, timeout: timeout)
            }
        }
        if let error = HTTPPoster.mapStatus(status, body: data) {
            throw error
        }
        let translated = try OpenAICompatibleProvider.parseContent(data: data, expected: inputs.count)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        var items: [TranslationResultItem] = []
        for (index, item) in request.items.enumerated() {
            let text = index < translated.count ? translated[index] : item.text
            items.append(TranslationResultItem(
                key: item.key,
                translatedText: text,
                translatedSegments: nil,
                cached: false,
                latencyMs: latency
            ))
        }
        return TranslationResult(requestId: request.requestId, items: items, backend: .openai, error: nil)
    }

    /// 从 `choices[0].message.content` 取 JSON 数组，剥离 ``` 围栏后**宽容**解析。
    ///
    /// 真实模型不总是吐纯净数组：可能前后带一句解释、包进 `{"items": ...}`，
    /// 或被 max_tokens 截断。只认一种形状时，一次 80 条的大块会整块失败，
    /// 而日志里连失败的片段都没有 —— 这是"翻译几乎全失败"那一轮的最直接原因。
    static func parseContent(data: Data, expected: Int) throws -> [String] {
        let rawSnippet = String(decoding: data.prefix(K.rawSnippetLimit), as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any] else {
            throw MochiBoxError(
                code: .badResponse,
                message: "响应不是 JSON 对象",
                rawSnippet: rawSnippet
            )
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw MochiBoxError(
                code: .badResponse,
                message: "响应缺少 choices[0]（finish_reason=unknown）",
                rawSnippet: rawSnippet
            )
        }
        // finish_reason 是"为什么没有可用内容"的唯一线索：length = 输出被 max_tokens 砍断，
        // stop = 模型自认为说完了（多是拒答或换了形状）。不记它时，空 content 的日志里
        // 只剩 httpStatus=0，用户无从判断该调 token 预算还是该减小批量。
        let finishReason = (first["finish_reason"] as? String) ?? "unknown"
        let message = first["message"] as? [String: Any]
        let content = (message?["content"] as? String) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 空内容不做宽容解析：没有字符可解析，重试同一批只会再拿到空串。
            // reasoning 型模型会把 max_tokens 先花在思维链上，这类空 content 的
            // finish_reason 常常就是 length —— 文案必须直接指向可操作的开关。
            let reason = finishReason == "length"
                ? "输出被截断，可能是最大输出 tokens 不足或该模型把预算用于推理；可在设置→高级设置调大最大输出 tokens，或减小单批条数"
                : "模型没有返回可解析的 JSON 数组"
            throw MochiBoxError(
                code: .badResponse,
                message: Self.emptyContentMessagePrefix + "（finish_reason=\(finishReason)）：\(reason)",
                // content 为空时 cleaned 也是空串，保留整段响应更能说明问题：
                // usage 里的 completion/reasoning tokens 能看出预算被花到哪去了。
                rawSnippet: rawSnippet
            )
        }
        let cleaned = stripFences(content)
        // 宽容解析：模型偶尔在数组前后加一句解释，或把数组包进 {"items": [...]} /
        // {"translations": [...]}。元素语义不变（仍是字符串），输出要求（长度/顺序/分段）
        // 也不变，所以不升 prompt 版本、不动缓存键。
        guard let array = firstArray(in: cleaned) else {
            // 只写"content 不是 JSON 数组"时，日志里既看不出是截断、拒答还是换了形状；
            // 带上可读片段才能一眼分辨（截断 → 尾部没有 ]，拒答 → 开头是中文说明）。
            throw MochiBoxError(
                code: .badResponse,
                message: "content 不是 JSON 数组；前 160 字：" + readableSnippet(cleaned)
                    + "（finish_reason=\(finishReason)）",
                rawSnippet: String(cleaned.prefix(300))
            )
        }
        var output: [String] = []
        for element in array {
            if let text = element as? String {
                output.append(text)
            } else if let number = element as? NSNumber {
                output.append(number.stringValue)
            } else {
                output.append("")
            }
        }
        if output.count != expected {
            throw MochiBoxError(
                code: .badResponse,
                message: "译文条数不匹配：后端返回 \(output.count) 条，期望 \(expected) 条",
                rawSnippet: cleaned
            )
        }
        return output
    }

    /// 依次尝试三种形状，返回第一个能解析成数组的结果：
    ///   ① 整段（含剥离围栏后）；② 第一个 `[` 到最后一个 `]` 的子串（前后有解释）；
    ///   ③ 包装对象里的 `items` / `translations` 数组。
    /// 都不行返回 nil，由调用方抛带片段的 `badResponse`。
    static func firstArray(in text: String) -> [Any]? {
        var candidates: [String] = [text]
        if let open = text.firstIndex(of: "["),
           let close = text.lastIndex(of: "]"),
           open < close {
            candidates.append(String(text[open...close]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) else { continue }
            if let array = object as? [Any] { return array }
            if let wrapper = object as? [String: Any] {
                for key in ["items", "translations"] {
                    if let inner = wrapper[key] as? [Any] { return inner }
                }
            }
        }
        return nil
    }

    /// 把 content 压成一行可读片段（换行/制表转义），给 `error.message` 用。
    /// 截断的 JSON 会把换行留在尾部 —— 不转义的话日志一条记录会被拆成好几行。
    static func readableSnippet(_ text: String, limit: Int = 160) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let flattened = trimmed
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return String(flattened.prefix(limit))
    }

    static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let lastFence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[trimmed.startIndex..<lastFence.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

// MARK: - DeepL

struct DeepLProvider: BatchTranslationProvider {
    let endpoint: String
    let apiKey: String
    let poster: HTTPPoster

    init(endpoint: String, apiKey: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.poster = HTTPPoster(session: session)
    }

    var kind: BackendKind { return .deepl }

    func translateOne(_ request: TranslationRequest) async throws -> TranslationResult {
        let started = Date()
        guard !endpoint.isEmpty else {
            throw MochiBoxError(code: .backendNotConfigured)
        }
        let base = endpoint.endpointBase
        guard let url = URL(string: base + "/v2/translate") else {
            throw MochiBoxError(code: .backendNotConfigured, message: "endpoint 非法：\(endpoint)")
        }
        // DeepL 没有 system prompt，只能把同一段提示塞进 `context`（best-effort）。
        // 它不保证术语，但比"完全看不见"强；UI 仍标注约束弱于 OpenAI 兼容后端。
        let hint = OpenAICompatibleProvider.systemPrompt(
            categories: request.items.compactMap { $0.category },
            glossary: request.glossary ?? []
        )
        let body: [String: Any] = [
            "text": request.items.map { $0.text },
            "source_lang": DeepLProvider.upper(request.srcLang),
            "target_lang": DeepLProvider.targetCode(request.tgtLang),
            "preserve_formatting": true,
            "context": hint
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw MochiBoxError(code: .badResponse, message: "无法构造请求体")
        }
        let headers = ["Authorization": "DeepL-Auth-Key \(apiKey)"]
        let (status, data) = try await poster.postJSON(
            url: url,
            headers: headers,
            body: bodyData,
            timeout: TimeInterval(request.timeoutMs) / 1000.0
        )
        if let error = HTTPPoster.mapStatus(status, body: data) {
            if status == 456 {
                throw MochiBoxError(code: .quotaExceeded, httpStatus: status,
                                 rawSnippet: String(decoding: data.prefix(K.rawSnippetLimit), as: UTF8.self))
            }
            throw error
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any],
              let translations = root["translations"] as? [[String: Any]] else {
            throw MochiBoxError(
                code: .badResponse,
                message: "响应缺少 translations",
                rawSnippet: String(decoding: data.prefix(K.rawSnippetLimit), as: UTF8.self)
            )
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        var items: [TranslationResultItem] = []
        for (index, item) in request.items.enumerated() {
            let text = index < translations.count ? (translations[index]["text"] as? String ?? item.text) : item.text
            items.append(TranslationResultItem(
                key: item.key,
                translatedText: text,
                translatedSegments: nil,
                cached: false,
                latencyMs: latency
            ))
        }
        return TranslationResult(requestId: request.requestId, items: items, backend: .deepl, error: nil)
    }

    static func upper(_ lang: String) -> String {
        let mapping = ["ja": "JA", "en": "EN", "zh-hans": "ZH", "zh-hant": "ZH"]
        return mapping[lang.lowercased()] ?? lang.uppercased()
    }

    static func targetCode(_ lang: String) -> String {
        let mapping = ["ja": "JA", "en": "EN", "zh-hans": "ZH", "zh-hant": "ZH-HANT"]
        return mapping[lang.lowercased()] ?? lang.uppercased()
    }
}

// MARK: - Provider 工厂

enum TranslationProviderFactory {
    /// 按设置创建后端；合规开关关闭时强制直通。
    static func make(settings: Settings, credentials: Credentials) -> TranslatorProvider {
        switch settings.effectiveBackend {
        case .passthrough:
            return PassthroughProvider()
        case .openai:
            return OpenAICompatibleProvider(
                endpoint: settings.endpoint,
                apiKey: credentials.apiKey,
                model: settings.model,
                maxOutputTokens: settings.maxOutputTokens,
                // 手改 settings.json 写错值时回落 auto：非法枚举不该让 provider 建不起来。
                reasoningOffMode: ReasoningOffMode(rawValue: settings.reasoningOffMode) ?? .auto
            )
        case .deepl:
            return DeepLProvider(
                endpoint: settings.endpoint,
                apiKey: credentials.deeplApiKey
            )
        }
    }
}

// MARK: - 韧性策略
/// 批量窗口 / 并发闸门 / 退避 / 熔断参数集中定义。
struct ResiliencePolicy: Sendable {
    var batchWindowMs: Int = K.batchWindowMs
    var maxBatch: Int = K.maxBatch
    var maxConcurrent: Int = K.maxConcurrent
    var retryDelaysMs: [Int] = K.retryDelaysMs
    var breakerThreshold: Int = K.circuitBreakerThreshold
    var breakerOpenSec: Double = K.circuitBreakerOpenSec

    init() {}

    init(settings: Settings) {
        self.batchWindowMs = settings.batchWindowMs
        self.maxBatch = settings.maxBatch
        self.maxConcurrent = settings.maxConcurrent
        self.retryDelaysMs = K.retryDelaysMs
        self.breakerThreshold = K.circuitBreakerThreshold
        self.breakerOpenSec = K.circuitBreakerOpenSec
    }
}

/// 熔断器：连续 N 次失败 → 打开 30s → 半开一次试探。
final class CircuitBreaker: @unchecked Sendable {
    private var consecutiveFailures: Int = 0
    private var openedAt: Date?
    private let threshold: Int
    private let openSeconds: Double

    init(threshold: Int = K.circuitBreakerThreshold, openSeconds: Double = K.circuitBreakerOpenSec) {
        self.threshold = threshold
        self.openSeconds = openSeconds
    }

    /// 是否允许发起请求（含半开试探）。
    func canAttempt(now: Date = Date()) -> Bool {
        guard let opened = openedAt else { return true }
        return now.timeIntervalSince(opened) >= openSeconds
    }

    var isOpen: Bool {
        guard let opened = openedAt else { return false }
        return Date().timeIntervalSince(opened) < openSeconds
    }

    var openUntil: Date? {
        guard let opened = openedAt else { return nil }
        return opened.addingTimeInterval(openSeconds)
    }

    func recordSuccess() {
        consecutiveFailures = 0
        openedAt = nil
    }

    func recordFailure(now: Date = Date()) {
        consecutiveFailures += 1
        if consecutiveFailures >= threshold {
            openedAt = now
            consecutiveFailures = 0
        }
    }
}
