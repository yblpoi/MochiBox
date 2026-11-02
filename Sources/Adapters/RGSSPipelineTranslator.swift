//
//  RGSSPipelineTranslator.swift
//  MochiBox
//
//  RGSS 文本通道（XP/VX/VX Ace）的翻译来源：把桥收到的整行文本送进**现有**翻译管线
//  （TranslationPipeline → TranslationCache / TranslatorProvider），不再维护测试词典。
//
//  ## 一条文本的完整链路
//
//    hook（Ruby，游戏主线程）
//      → RGSSBridge（loopback socket，120ms 应答闸）
//      → RGSSPipelineTranslator（本文件）
//      → LegacyEscapeCodec.skeleton(raw:engineFamily:"rgss")   // 控制符切成 code 段
//      → Segmenter.joinForBackend / mapKey 同族 cacheKey        // 只送 text 段
//      → TranslationPipeline.resolve
//          · 命中 → PipelineOutcome.hit（同步回，<120ms）
//          · 未命中 → 入队 + 后台请求 → PipelineBatchResult → cache.put（落盘）
//      → Segmenter.reassemble（按本行自己的骨架拼回控制符）
//      → LegacyEscapeCodec 控制码校验（逐项、按顺序、按字面）
//      → RGSSBridge 回 RESP
//
//  ## 为什么第一遍是原文
//
//  hook 的读超时是 0.2s，桥必须在 120ms 内回。LLM 是秒级，所以：
//    · 首次 TEXT：120ms 内没结果 → 回 **PENDING + 原文** → hook 显示原文（游戏不卡）；
//    · 请求继续在后台跑 → 结果写进 TranslationCache（内存 + JSONL）；
//    · 同一原文下一次出现 → TranslationCache 命中 → 120ms 内回中文。
//  这是刻意的取舍：以"首屏晚一拍"换"游戏主线程绝不等网络"。**不要**把它改成同步等待。
//
//  ## 控制符
//
//  分段只复用 LegacyEscapeCodec（RGSS 码表：\\C[n] \\N[n] \\V[n] \\G \\I[n] \\| \\. \\! \\> \\< \\^ …），
//  另写一份码表就会和全文链路对同一条文本算出两个结果。示例：
//    \\C[2]赤い\\C[0]  → 送翻 "赤い" → \\C[2]<译文>\\C[0]
//  模型若把控制码写进译文，translatedTextProblems 会拦下；拼回后还会用本行的原始
//  反斜杠序列逐项比对（controlCodeProblems），不一致就整条丢弃（这一行显示原文）。
//
//  ## 缓存键
//
//  与 SessionController.handleText **同一个公式**：
//    TranslationProfile.id(category: .dialogue, pairs: 术语命中)
//    Segmenter.cacheKey(engineFamily: "rgss", srcLang, tgtLang, segments, profile)
//  engineFamily 收敛成 "rgss"（不是 rgss1/2/3）：三版共用同一套控制符，同一句不该存三份。
//  控制码段不参与 key（与 MV/MZ 一致）：\\C[2]350 与 \\C[3]350 共享一条缓存，
//  回填时各用各的骨架。
//

import Foundation

// MARK: - 环境

/// 桥接翻译需要的运行期依赖。**全部是现有对象**：不新建缓存、不新建 provider。
struct RGSSPipelineEnvironment {
    /// 会话的翻译管线（产品路径与 SessionController 共用同一个实例）。
    var pipeline: TranslationPipeline
    /// 同一个 TranslationCache 实例：CLI 退出前 flush、报告命中率用。
    var cache: TranslationCache
    /// 与实时链路共用术语快照；nil = 不使用术语。
    var glossaryBox: GlossaryBox?
    var srcLang: String
    var tgtLang: String
    /// 等待后台结果的上限（秒）。取 settings.timeoutSec 的 3 倍左右，见 init 调用点。
    var timeoutSec: Int
    var log: SessionLog?
}

// MARK: - 翻译器

actor RGSSPipelineTranslator: RGSSTranslating {

    /// 唯一合法的 RGSS 族名：进 cacheKey，不能按 rgss1/2/3 拆（见文件头）。
    private static let engineFamily = "rgss"

    private let environment: RGSSPipelineEnvironment
    private var handlerInstalled = false

    /// 等待中的 key → continuation。同一句被多行同时请求时共享一次后台结果。
    private var waiters: [String: [CheckedContinuation<String?, Never>]] = [:]
    /// 后台结果比等待者先到（resolve 与 wait 之间）时的暂存。
    private var earlyResults: [String: String] = [:]
    /// 本翻译器正在等的 key。管线是共享的，回调会收到别的会话的结果，必须按 key 过滤。
    private var waitingKeys: Set<String> = []

    init(environment: RGSSPipelineEnvironment) {
        self.environment = environment
    }

    // MARK: 接口

    func translate(_ text: String, version: String) async -> RGSSBridgeReply? {
        await installHandlerIfNeeded()

        // 控制符分段：只把 .text 段送翻译。空行 / 纯控制符直接不翻。
        let skeleton = LegacyEscapeCodec.skeleton(raw: text, engineFamily: Self.engineFamily)
        guard Segmenter.textSegmentCount(skeleton) > 0 else {
            return nil
        }
        let joined = Segmenter.joinForBackend(skeleton)
        let category = TranslationCategory.dialogue
        // 术语命中要与实时链路同源：同一句在两条链路里算出同一个 profile，才能共享缓存。
        let hints = environment.glossaryBox?.pairs(
            in: joined,
            includeSingleChar: category.allowsSingleCharTerms
        ) ?? []
        let profile = TranslationProfile.id(category: category, pairs: hints)
        let key = Segmenter.cacheKey(
            engineFamily: Self.engineFamily,
            srcLang: environment.srcLang,
            tgtLang: environment.tgtLang,
            segments: skeleton,
            profile: profile
        )
        let item = TranslationRequestItem(
            key: key,
            text: joined,
            segments: skeleton,
            category: category,
            glossary: hints
        )

        switch await resolve(item: item, skeleton: skeleton, raw: text) {
        case .reply(let reply):
            return reply
        case .failed:
            return nil
        case .corrupt(let translatedText):
            // 缓存里是一条坏译文（模型写了控制码 / 段数漂移）。用管线的 ignoreCache
            // 重发一次：这是管线为"修复坏译文"设计的入口，成功会覆盖同一个 key。
            environment.log?.warn("RGSSPipeline", "译文控制码不一致，绕缓存重试一次", [
                "key": String(key.prefix(8)),
                "text": TranslationPipeline.oneLineSnippet(translatedText)
            ])
            var retry = item
            retry.ignoreCache = true
            if case .reply(let reply) = await resolve(item: retry, skeleton: skeleton, raw: text) {
                return reply
            }
            return nil
        }
    }

    // MARK: 管线交互

    private enum Resolution {
        case reply(RGSSBridgeReply)
        /// 译文存在但不可用（控制码被改 / 段数不符）。调用方最多再重试一次。
        case corrupt(String)
        case failed
    }

    private func resolve(
        item: TranslationRequestItem,
        skeleton: [Segment],
        raw: String
    ) async -> Resolution {
        let key = item.key
        // 必须在 resolve 之前登记：管线回调可能在本函数 await 期间到达，
        // 晚一步登记就会漏掉结果、一路等到超时。
        waitingKeys.insert(key)

        let outcomes = await environment.pipeline.resolve([item])
        guard let outcome = outcomes.first else {
            waitingKeys.remove(key)
            return .failed
        }

        switch outcome {
        case .hit(let result):
            waitingKeys.remove(key)
            return evaluate(result.translatedText, skeleton: skeleton, raw: raw, source: .cacheHit)
        case .pending:
            guard let translated = await wait(key: key) else {
                return .failed
            }
            return evaluate(translated, skeleton: skeleton, raw: raw, source: .fresh)
        case .passthrough:
            waitingKeys.remove(key)
            // 直通 = 不翻译。把原文回给 hook 会让它把"原文→原文"缓存一整局，
            // 所以这里返回 nil（桥回 PENDING + 原文，hook 下次还会再问）。
            return .failed
        case .skipped(let reason):
            waitingKeys.remove(key)
            environment.log?.debug("RGSSPipeline", "跳过", ["reason": reason, "key": String(key.prefix(8))])
            return .failed
        case .failed(let error):
            waitingKeys.remove(key)
            environment.log?.warn("RGSSPipeline", "请求失败", [
                "code": error.code.rawValue,
                "key": String(key.prefix(8))
            ])
            return .failed
        }
    }

    /// 用本行的骨架拼回译文，并做两道控制码校验。
    private func evaluate(
        _ translatedText: String,
        skeleton: [Segment],
        raw: String,
        source: RGSSBridgeReply.Source
    ) -> Resolution {
        // ① 模型给的文本段里不许混入控制码（与行无关，能覆盖共享 key 的所有行）。
        let textProblems = LegacyEscapeCodec.translatedTextProblems(
            translatedText,
            engineFamily: Self.engineFamily
        )
        guard textProblems.isEmpty else {
            environment.log?.warn("RGSSPipeline", "译文混入控制码", [
                "problems": textProblems.joined(separator: " | ")
            ])
            return .corrupt(translatedText)
        }
        // ② 拼回后的控制码必须与本行原文逐项一致（顺序 + 字面 + id）。
        guard let output = try? Segmenter.reassemble(segments: skeleton, translatedText: translatedText) else {
            return .corrupt(translatedText)
        }
        let codeProblems = LegacyEscapeCodec.controlCodeProblems(
            raw: raw,
            reassembled: output,
            engineFamily: Self.engineFamily
        )
        guard codeProblems.isEmpty else {
            environment.log?.warn("RGSSPipeline", "拼回后控制码不一致", [
                "problems": codeProblems.joined(separator: " | ")
            ])
            return .corrupt(translatedText)
        }
        return .reply(RGSSBridgeReply(text: output, source: source))
    }

    // MARK: 后台结果分发

    private func installHandlerIfNeeded() async {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        await environment.pipeline.onResult { [weak self] result in
            guard let self else { return }
            Task { await self.deliver(result) }
        }
    }

    private func deliver(_ result: PipelineBatchResult) {
        for item in result.items where waitingKeys.contains(item.key) {
            guard let continuations = waiters.removeValue(forKey: item.key), !continuations.isEmpty else {
                // resolve 已返回 .pending 但 wait 还没登记：先存着，wait 会立刻取走。
                earlyResults[item.key] = item.translatedText
                continue
            }
            for continuation in continuations {
                continuation.resume(returning: item.translatedText)
            }
        }

        for (key, error) in result.itemErrors where waitingKeys.contains(key) {
            environment.log?.warn("RGSSPipeline", "单条译文不可用", [
                "code": error.code.rawValue,
                "key": String(key.prefix(8))
            ])
            if let continuations = waiters.removeValue(forKey: key) {
                for continuation in continuations {
                    continuation.resume(returning: nil)
                }
            }
            earlyResults.removeValue(forKey: key)
        }

        // 块级失败（401/429/超时/熔断）：items 为空，**不在这里唤醒所有等待者**。
        // 管线是会话共享的，这一批失败不代表别的批次里的 RGSS 行也失败；错误的
        // "全部失败" 会让本可以命中的行退回原文。每条等待由自己的 timeout 兜底。
        if let error = result.error {
            environment.log?.warn("RGSSPipeline", "块级失败（等待超时兜底）", [
                "code": error.code.rawValue,
                "waiters": "\(waiters.count)"
            ])
        }
    }

    private func wait(key: String) async -> String? {
        let translated: String? = await withCheckedContinuation { continuation in
            if let early = earlyResults.removeValue(forKey: key) {
                continuation.resume(returning: early)
                return
            }
            waiters[key, default: []].append(continuation)

            let timeout = max(5, environment.timeoutSec)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                await self?.expire(key: key)
            }
        }
        waitingKeys.remove(key)
        earlyResults.removeValue(forKey: key)
        return translated
    }

    private func expire(key: String) {
        guard let continuations = waiters.removeValue(forKey: key) else { return }
        for continuation in continuations {
            continuation.resume(returning: nil)
        }
        waitingKeys.remove(key)
        earlyResults.removeValue(forKey: key)
    }
}
