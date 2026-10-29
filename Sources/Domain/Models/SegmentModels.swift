//
//  SegmentModels.swift
//  MochiBox
//
//  文本分段：SegmentKind / Segment（独立成叶子，避免 TextEvent ↔ Translation 循环依赖）。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

// MARK: - 文本事件

enum SegmentKind: String, Codable, Sendable {
    case text
    case code
}

struct Segment: Codable, Sendable, Equatable, Hashable {
    var kind: SegmentKind
    var value: String

    init(kind: SegmentKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

