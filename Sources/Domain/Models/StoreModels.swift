//
//  StoreModels.swift
//  MochiBox
//
//  缓存与工具：CacheEntry / formatHitRatePercent / CacheStats / StreamStats / RandomHex / Timestamp。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

// MARK: - 缓存

struct CacheEntry: Codable, Sendable {
    var key: String
    var text: String
    var translatedText: String
    var srcLang: String
    var tgtLang: String
    var backend: String
    var seq: Int
    var ts: Double
    var hitCount: Int

    init(key: String, text: String, translatedText: String, srcLang: String, tgtLang: String, backend: String, seq: Int, ts: Double, hitCount: Int) {
        self.key = key
        self.text = text
        self.translatedText = translatedText
        self.srcLang = srcLang
        self.tgtLang = tgtLang
        self.backend = backend
        self.seq = seq
        self.ts = ts
        self.hitCount = hitCount
    }
}

/// 命中率 → `%.0f%%` 文本（`CacheStats` / `StreamStats` 共用，格式必须逐字节一致）。
private func formatHitRatePercent(_ rate: Double) -> String {
    return String(format: "%.0f%%", rate * 100)
}

struct CacheStats: Sendable, Equatable {
    var entries: Int = 0
    var bytes: Int = 0
    var hits: Int = 0
    var stores: Int = 0

    var hitRate: Double {
        let denominator = hits + stores
        guard denominator > 0 else { return 0 }
        return Double(hits) / Double(denominator)
    }

    var hitRatePercentText: String {
        return formatHitRatePercent(hitRate)
    }
}

struct StreamStats: Sendable, Equatable {
    var total: Int = 0
    var hits: Int = 0
    var fresh: Int = 0
    var skipped: Int = 0
    var errors: Int = 0

    var hitRate: Double {
        let denominator = hits + fresh
        guard denominator > 0 else { return 0 }
        return Double(hits) / Double(denominator)
    }

    var hitRatePercentText: String {
        return formatHitRatePercent(hitRate)
    }
}

// MARK: - 小工具

enum RandomHex {
    static func make(_ length: Int) -> String {
        let alphabet = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            let index = Int.random(in: 0..<alphabet.count)
            out.append(alphabet[index])
        }
        return out
    }
}

enum Timestamp {
    static func nowMs() -> Double {
        return Date().timeIntervalSince1970 * 1000
    }

    static func fileStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 复用的 ISO8601 formatter（每次新建实测 ~40µs，复用 ~1µs）。
    ///
    /// 线程安全：`DateFormatter` 自 macOS 10.9 / iOS 7 起，只读的格式化调用
    /// （`string(from:)`）是线程安全的；并发修改属性才不安全。这里用
    /// `static let` + 一次性闭包初始化（Swift 保证 exactly-once 且带内存屏障），
    /// 建好之后不再改动任何属性，因此所有线程只做只读格式化，无需加锁。
    ///
    /// 行为差异（唯一一处）：旧实现每次新建 formatter、且未显式设置 `timeZone`，
    /// 取的是「创建那一刻」的系统时区；复用后时区在首次调用时固定，运行中切换
    /// 系统时区不再实时生效（重启进程后生效）。
    private static let iso8601Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return formatter
    }()

    static func iso8601Ms(_ date: Date = Date()) -> String {
        return iso8601Formatter.string(from: date)
    }
}

