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

