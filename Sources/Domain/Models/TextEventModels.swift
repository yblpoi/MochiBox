//
//  TextEventModels.swift
//  MochiBox
//
//  文本事件：TextStatus / SurfaceKind / TextEvent。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

enum TextStatus: String, Codable, Sendable {
    case hit
    case miss
    case pending
    case translated
    case passthrough
    case skipped
    case error
    case paused

    var uiLabel: String {
        switch self {
        case .hit: return "命中"
        case .miss: return "新译"
        case .pending: return "翻译中"
        case .translated: return "新译"
        case .passthrough: return "直通"
        case .skipped: return "跳过"
        case .error: return "错误"
        case .paused: return "已暂停"
        }
    }
}

/// `TextEvent.surfaceKind` 的派生规则（PRD v0.3 §5.2，契约内字段）。
///
/// 由 Agent 上报的 `surface`（被 hook 的方法名）派生；P0 **只写不读**（UI 不展示、逻辑不依赖）。
enum SurfaceKind {
    static let dialogue = "dialogue"
    static let menu = "menu"
    static let system = "system"

    /// `Window_Message*` → `dialogue`；`Window_Base*` → `menu`；`Bitmap*` → `system`；其余 `nil`。
    static func of(surface: String) -> String? {
        if surface.hasPrefix("Window_Message") { return dialogue }
        if surface.hasPrefix("Window_Base") { return menu }
        if surface.hasPrefix("Bitmap") { return system }
        return nil
    }
}

struct TextEvent: Codable, Identifiable, Sendable {
    var id: String
    var ts: Double
    var lastSeenTs: Double
    var sessionId: String
    var gameId: String
    var engine: String
    var surface: String
    /// 由 `surface` 派生的显示面分类（PRD v0.3 §5.2 契约字段，P0 只写不读）。
    var surfaceKind: String?
    var sceneClass: String?
    /// 会话内单调递增，**从 1 开始**（PRD v0.3 §5.2）。
    var order: Int
    var raw: String
    var segments: [Segment]
    var text: String
    var key: String
    var status: TextStatus
    var translated: String?
    var translatedSegments: [Segment]?
    var backend: BackendKind?
    var latencyMs: Int?
    var cached: Bool
    var occurrences: Int
    var skipReason: String?
    var error: ErrorInfo?

    init(
        id: String = UUID().uuidString,
        ts: Double,
        lastSeenTs: Double,
        sessionId: String,
        gameId: String,
        engine: String,
        surface: String,
        surfaceKind: String? = nil,
        sceneClass: String?,
        order: Int,
        raw: String,
        segments: [Segment],
        text: String,
        key: String,
        status: TextStatus,
        translated: String? = nil,
        translatedSegments: [Segment]? = nil,
        backend: BackendKind? = nil,
        latencyMs: Int? = nil,
        cached: Bool = false,
        occurrences: Int = 1,
        skipReason: String? = nil,
        error: ErrorInfo? = nil
    ) {
        self.id = id
        self.ts = ts
        self.lastSeenTs = lastSeenTs
        self.sessionId = sessionId
        self.gameId = gameId
        self.engine = engine
        self.surface = surface
        self.surfaceKind = surfaceKind ?? SurfaceKind.of(surface: surface)
        self.sceneClass = sceneClass
        self.order = order
        self.raw = raw
        self.segments = segments
        self.text = text
        self.key = key
        self.status = status
        self.translated = translated
        self.translatedSegments = translatedSegments
        self.backend = backend
        self.latencyMs = latencyMs
        self.cached = cached
        self.occurrences = occurrences
        self.skipReason = skipReason
        self.error = error
    }
}

