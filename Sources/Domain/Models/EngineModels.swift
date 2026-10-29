//
//  EngineModels.swift
//  MochiBox
//
//  引擎识别：EngineKind / SupportLevel / EngineReason / EngineConfidence。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

// MARK: - 引擎

/// 引擎种类。`priority` 对应 PRD §A.1 的固定优先级（越小越先命中）。
enum EngineKind: String, Codable, Sendable, CaseIterable {
    case renpy
    case kirikiri
    case mz
    case mv
    case easyrpg
    case rgss3
    case rgss2
    case rgss1
    case tyrano
    case wolf
    case unity
    case godot
    case siglus
    case unknown

    var priority: Int {
        switch self {
        case .renpy: return 1
        case .kirikiri: return 2
        case .mz: return 3
        case .mv: return 4
        case .easyrpg: return 5
        case .rgss3: return 6
        case .rgss2: return 7
        case .rgss1: return 8
        case .tyrano: return 9
        case .wolf: return 10
        case .unity: return 11
        case .godot: return 12
        case .siglus: return 13
        case .unknown: return 99
        }
    }

    var displayName: String {
        switch self {
        case .renpy: return "Ren'Py"
        case .kirikiri: return "吉里吉里"
        case .mz: return "RPG Maker MZ"
        case .mv: return "RPG Maker MV"
        case .easyrpg: return "RPG Maker 2000/2003"
        case .rgss3: return "RPG Maker VX Ace"
        case .rgss2: return "RPG Maker VX"
        case .rgss1: return "RPG Maker XP"
        case .tyrano: return "TyranoBuilder"
        case .wolf: return "WOLF RPG Editor"
        case .unity: return "Unity"
        case .godot: return "Godot"
        case .siglus: return "SiglusEngine"
        case .unknown: return "未知"
        }
    }

    /// 缓存键里的 `engineFamily`。
    var family: String {
        switch self {
        case .mv, .mz: return "mvmz"
        default: return rawValue
        }
    }

    /// PRD §A.1 表中给出的 `supportLevel`。
    var declaredSupportLevel: SupportLevel {
        switch self {
        case .mv, .mz, .tyrano: return .p0
        case .renpy: return .p1
        case .kirikiri, .easyrpg, .rgss3, .rgss2, .rgss1, .wolf: return .p2
        case .unity, .godot, .siglus: return .none
        case .unknown: return .unknown
        }
    }
}

enum SupportLevel: String, Codable, Sendable {
    case p0
    case p1
    case p2
    case none
    case unknown

    var uiLabel: String {
        switch self {
        case .p0: return "可启动"
        case .p1: return "需 P1 适配器（未实现）"
        case .p2: return "暂不支持（需 Wine 后端）"
        case .none: return "不支持"
        case .unknown: return "未知"
        }
    }
}

enum EngineReason: String, Codable, Sendable {
    case noSignatureMatched = "no_signature_matched"
    case signatureConflict = "signature_conflict"
    case permissionDenied = "permission_denied"
    case emptyDirectory = "empty_directory"
    case notADirectory = "not_a_directory"

    var uiLabel: String {
        switch self {
        case .noSignatureMatched: return "未命中任何引擎特征"
        case .signatureConflict: return "多个引擎特征同时命中，已按优先级取其一"
        case .permissionDenied: return "无读取权限（请在系统设置-隐私与安全性中授权）"
        case .emptyDirectory: return "目录为空"
        case .notADirectory: return "路径不是目录"
        }
    }
}

enum EngineConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

