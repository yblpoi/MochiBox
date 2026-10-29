//
//  FullTextQuality.swift
//  MochiBox
//
//  译文质量校验：**只标记**，重试由调用方决定。
//
//  为什么不在这一层重试：
//  · 术语未遵循常常是「译文用了同义词」而不是真错，无限重试会反复计费且可能死循环；
//  · 用户要的是「能看见哪几条可疑」，不是再花一倍 token 换一个仍然可疑的结果。
//  出口是全文页的「质量问题」筛选 + 手动重翻；唯一的自动重试是
//  `FullTextController.repairGlossaryViolations`：**每条最多一次**，且带强调提示。
//
//  本文件只 import Foundation（分层门禁）。
//

import Foundation

enum QualityIssue: String, Codable, Sendable, CaseIterable {
    /// `%1` 等占位符在译文里丢失/变形。
    case placeholderLost = "placeholder_lost"
    /// 译文里残留平假名/片假名（疑似没翻）。
    case kanaLeft = "kana_left"
    /// 译文与原文完全相同。
    case identical
    /// 锁定术语的译名没出现在译文里。
    case glossaryViolation = "glossary_violation"
    /// 长度异常（过短/过长）。
    case lengthAnomaly = "length_anomaly"

    var uiLabel: String {
        switch self {
        case .placeholderLost: return "占位符"
        case .kanaLeft: return "残留日文"
        case .identical: return "未翻译"
        case .glossaryViolation: return "术语不符"
        case .lengthAnomaly: return "长度异常"
        }
    }
}

enum FullTextQuality {
    /// 校验一条译文。`translated == raw` 的短路条目由调用方传 `suppressIdentical`。
    static func check(
        raw: String,
        translated: String,
        segments: [Segment],
        category: TranslationCategory,
        glossary: Glossary,
        srcLang: String,
        suppressIdentical: Bool = false
    ) -> [QualityIssue] {
        var issues: [QualityIssue] = []
        let sourceText = Segmenter.joinForBackend(segments)
        let targetText = translated

        if placeholders(in: sourceText) != placeholders(in: targetText) {
            issues.append(.placeholderLost)
        }

        if containsKana(targetText) {
            // 源语言不是日文时，假名可能是有意保留（例如专有名词），不报。
            if srcLang == K.fixedSrcLang { issues.append(.kanaLeft) }
        }

        if !suppressIdentical && normalizedEqual(sourceText, targetText) {
            issues.append(.identical)
        }

        // 判定逻辑只有一份（`Glossary.violations`）：自动重译要拿它返回的具体术语对
        // 拼强调段，两处若各写一遍，标的与「标了却修什么」迟早会分叉。
        if !glossary.violations(raw: sourceText, translated: targetText, category: category).isEmpty {
            issues.append(.glossaryViolation)
        }

        if category == .description || category == .dialogue || category == .other {
            if lengthAnomalous(source: sourceText, target: targetText) {
                issues.append(.lengthAnomaly)
            }
        }

        return issues
    }

    // MARK: - 规则

    /// `%1`…`%9` 按多重集比较（顺序不重要，个数与编号必须一致）。
    static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%" {
                var cursor = text.index(after: index)
                var digits = ""
                while cursor < text.endIndex, text[cursor].isNumber, digits.count < 2 {
                    digits.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if !digits.isEmpty { found.append("%" + digits) }
                index = cursor
            } else {
                index = text.index(after: index)
            }
        }
        return found.sorted()
    }

    static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0xFF66...0xFF9D:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func normalizedEqual(_ lhs: String, _ rhs: String) -> Bool {
        return Segmenter.normalizeForKey(lhs) == Segmenter.normalizeForKey(rhs)
    }

    private static func lengthAnomalous(source: String, target: String) -> Bool {
        let sourceCount = source.count
        let targetCount = target.count
        guard sourceCount > 0 else { return false }
        if targetCount > sourceCount * 3 + 12 { return true }
        if sourceCount >= 16 && targetCount * 3 < sourceCount { return true }
        return false
    }
}
