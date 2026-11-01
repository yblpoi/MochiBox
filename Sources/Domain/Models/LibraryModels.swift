//
//  LibraryModels.swift
//  MochiBox
//
//  游戏库：GameEntry / LibraryFile。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

struct GameEntry: Codable, Identifiable, Sendable, Hashable {
    let id: String
    var name: String
    var path: String
    var engine: EngineKind
    var engineConfidence: EngineConfidence
    var engineEvidence: [String]
    var supportLevel: SupportLevel
    var reason: EngineReason?
    var addedAt: Double
    var lastLaunchedAt: Double?
    var launchCount: Int
    var missing: Bool

    /// 能不能启动由 `EngineKind.launchBackend` 决定，与 `supportLevel`（PRD 声明级别）无关：
    /// Tyrano 声明是 p0，但没有运行时后端，因此不可启动。
    var isLaunchable: Bool {
        return engine.launchBackend != nil && !missing
    }

    /// 展示口径：`supportLevel` 是入库快照（PRD §A.1 声明级别），不等于"现在能不能启动"。
    /// easyrpg 声明仍是 p2，但内置运行时已通 —— 不能再用「暂不支持（需 Wine 后端）」。
    ///
    /// 这里**不新增** `SupportLevel` case：它是 `String` 枚举且随 `library.json` 落盘，
    /// 旧版本 App 遇到未知 rawValue 会让 `LibraryStore.load` **整库解码失败**
    /// （改名备份 + 以空库启动）。派生值只活在内存里，旧库（p2）读进来即正确，无需迁移。
    var displaySupportLevel: String {
        if engine.launchBackend != nil && supportLevel == .p2 {
            return "可启动（内置运行时）"
        }
        return supportLevel.uiLabel
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        engine: EngineKind,
        engineConfidence: EngineConfidence,
        engineEvidence: [String],
        supportLevel: SupportLevel,
        reason: EngineReason?,
        addedAt: Double = Date().timeIntervalSince1970 * 1000,
        lastLaunchedAt: Double? = nil,
        launchCount: Int = 0,
        missing: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.engine = engine
        self.engineConfidence = engineConfidence
        self.engineEvidence = engineEvidence
        self.supportLevel = supportLevel
        self.reason = reason
        self.addedAt = addedAt
        self.lastLaunchedAt = lastLaunchedAt
        self.launchCount = launchCount
        self.missing = missing
    }
}

struct LibraryFile: Codable, Sendable {
    var schemaVersion: Int
    var games: [GameEntry]

    init(schemaVersion: Int = 1, games: [GameEntry] = []) {
        self.schemaVersion = schemaVersion
        self.games = games
    }
}

