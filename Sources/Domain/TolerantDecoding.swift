//
//  TolerantDecoding.swift
//  MochiBox
//
//  统一的"宽容解码"：字段缺失 / JSON null / 类型不匹配 / 内层解码失败，一律回落，
//  不抛错、不记日志。
//
//  它把原先散在四处等价实现（CheatModels 的 `cheatValue`/`cheatOptional`、
//  AgentRPC / FullTextStore / FullTextModels / Models 的内联 `try? ... ?? nil ?? 默认值`、
//  Stores.Settings 的私有 `value(_:_:_:)`）收敛成一处：语义此前已逐一核对**完全相同**，
//  保留多套只会让"回落"的边界在后续改动里慢慢漂移。
//
//  为什么不直接用 `decodeIfPresent` + `??`：它对类型不匹配会 throw，而这里要的是
//  "认不出来就用默认值"。`try?` 会把 `T?` 摊平成 `T?`（Swift 5 起 SE-0230），
//  所以只剩一层可解包。
//
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

extension KeyedDecodingContainer {
    /// 解码失败（含类型不匹配）时返回 `fallback`。
    func tolerantValue<T: Decodable>(_ type: T.Type, forKey key: Key, _ fallback: T) -> T {
        if let value = try? decodeIfPresent(type, forKey: key) {
            return value
        }
        return fallback
    }

    /// 解码失败（含类型不匹配）时返回 `nil`。
    func tolerantOptional<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        if let value = try? decodeIfPresent(type, forKey: key) {
            return value
        }
        return nil
    }
}
