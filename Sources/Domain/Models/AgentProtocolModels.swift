//
//  AgentProtocolModels.swift
//  MochiBox
//
//  Agent 协议：AgentEnvelope / HelloPayload / AgentTextPayload / AgentErrorPayload / AgentConfig / TranslationPushItem / HostCommand。
//  自 Models.swift 拆分而来：仅搬移、零逻辑改动（拆分后依赖为无环 DAG）。
//  本文件不得 import SwiftUI / AppKit（`Scripts/build.sh` 的分层门禁）。
//

import Foundation

// MARK: - Agent 协议

/// 信封。两段解码：先解 header，再按 type 解 payload；未知 type 不报错。
struct AgentEnvelope: Decodable, Sendable {
    var v: Int
    var type: String
    var sessionToken: String
    var payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case v
        case type
        case sessionToken
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.v = container.tolerantValue(Int.self, forKey: .v, K.protocolVersion)
        self.type = container.tolerantValue(String.self, forKey: .type, "unknown")
        self.sessionToken = container.tolerantValue(String.self, forKey: .sessionToken, "")
        self.payload = container.tolerantValue(JSONValue.self, forKey: .payload, JSONValue.object([:]))
    }
}

struct HelloPayload: Decodable, Sendable {
    var agentVersion: Int
    var ua: String
    var href: String
    var engineGuess: String
    var hooks: [String]

    enum CodingKeys: String, CodingKey {
        case agentVersion, ua, href, engineGuess, hooks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agentVersion = c.tolerantValue(Int.self, forKey: .agentVersion, 0)
        self.ua = c.tolerantValue(String.self, forKey: .ua, "")
        self.href = c.tolerantValue(String.self, forKey: .href, "")
        self.engineGuess = c.tolerantValue(String.self, forKey: .engineGuess, "")
        self.hooks = c.tolerantValue([String].self, forKey: .hooks, [])
    }
}

struct AgentTextPayload: Decodable, Sendable {
    var ts: Double
    var frame: Int
    var surface: String
    var sceneClass: String?
    var raw: String
    var segments: [Segment]
    var text: String
    var key: String
    /// Agent 侧自己的跳过结论（`skipped` / `pending`）。**只作参考**：
    /// 产品路径的 `status` 一律由 Host 的 `SkipRules` 决定（双端判定，Host 说了算）；
    /// `--attach` 没有 SkipRules，才用这个字段避免把跳过句送后端。
    var status: String?
    /// `numeric` / `punctuation` / `whitespace`，仅当 `status == "skipped"`。
    var skipReason: String?

    enum CodingKeys: String, CodingKey {
        case ts, frame, surface, sceneClass, raw, segments, text, key, status, skipReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ts = c.tolerantValue(Double.self, forKey: .ts, Date().timeIntervalSince1970 * 1000)
        self.frame = c.tolerantValue(Int.self, forKey: .frame, 0)
        self.surface = c.tolerantValue(String.self, forKey: .surface, "unknown")
        self.sceneClass = c.tolerantOptional(String.self, forKey: .sceneClass)
        self.raw = c.tolerantValue(String.self, forKey: .raw, "")
        self.segments = c.tolerantValue([Segment].self, forKey: .segments, [])
        self.text = c.tolerantValue(String.self, forKey: .text, "")
        self.key = c.tolerantValue(String.self, forKey: .key, "")
        self.status = c.tolerantOptional(String.self, forKey: .status)
        self.skipReason = c.tolerantOptional(String.self, forKey: .skipReason)
    }
}

struct AgentErrorPayload: Decodable, Sendable {
    var code: String
    var message: String
    var stack: String?

    enum CodingKeys: String, CodingKey { case code, message, stack }
}

/// Host → Agent 的全量配置。
struct AgentConfig: Codable, Sendable, Equatable {
    var enabled: Bool
    var fontScale: Double
    var srcLang: String
    var tgtLang: String
    var maxMapSize: Int
    /// 游戏绘制字体族（空 = 自动：Agent 侧用苹方系回退链）。
    var gameFontFamily: String
    /// 数据回写总开关（`$data*` 的 name / messageN）。
    var dataPatchEnabled: Bool
    /// 数据回写的名字类子开关（`name` / `nickname` / `Game_Actor._name`）。
    var dataPatchNames: Bool

    init(
        enabled: Bool = true,
        fontScale: Double = 1.0,
        srcLang: String = "ja",
        tgtLang: String = "zh-Hans",
        maxMapSize: Int = K.maxAgentMapSize,
        gameFontFamily: String = "",
        dataPatchEnabled: Bool = true,
        dataPatchNames: Bool = true
    ) {
        self.enabled = enabled
        self.fontScale = fontScale
        self.srcLang = srcLang
        self.tgtLang = tgtLang
        self.maxMapSize = maxMapSize
        self.gameFontFamily = gameFontFamily
        self.dataPatchEnabled = dataPatchEnabled
        self.dataPatchNames = dataPatchNames
    }
}

struct TranslationPushItem: Codable, Sendable, Equatable {
    var key: String
    var translatedRaw: String
    var segments: [Segment]

    init(key: String, translatedRaw: String, segments: [Segment]) {
        self.key = key
        self.translatedRaw = translatedRaw
        self.segments = segments
    }
}

/// Host → Agent 的唯一出口（拼成 `window.__mochibox.inbox(<json 字符串>)`）。
enum HostCommand: Sendable {
    case config(AgentConfig)
    case setTranslation(TranslationPushItem)
    case setTranslations([TranslationPushItem])
    case drop([String])
    case clear
    case ping(Double)
    /// v0.6：调用—返回（架构 v0.6 §2.2）。`id` 由 Host 生成，Agent 原样回填。
    case rpc(id: String, method: String, args: JSONValue)

    var typeName: String {
        switch self {
        case .config: return "config"
        case .setTranslation: return "setTranslation"
        case .setTranslations: return "setTranslations"
        case .drop: return "drop"
        case .clear: return "clear"
        case .ping: return "ping"
        case .rpc: return "rpc"
        }
    }

    /// 产出信封 JSON 文本：`{"type":..,"payload":{..}}`。
    func jsonText() throws -> String {
        var payload: [String: JSONValue] = [:]
        switch self {
        case .config(let config):
            payload = [
                "enabled": .bool(config.enabled),
                "fontScale": .number(config.fontScale),
                "srcLang": .string(config.srcLang),
                "tgtLang": .string(config.tgtLang),
                "maxMapSize": .number(Double(config.maxMapSize)),
                "gameFontFamily": .string(config.gameFontFamily),
                "dataPatchEnabled": .bool(config.dataPatchEnabled),
                "dataPatchNames": .bool(config.dataPatchNames)
            ]
        case .setTranslation(let item):
            payload = HostCommand.pushItemToJSON(item)
        case .setTranslations(let items):
            payload = ["items": .array(items.map { JSONValue.object(HostCommand.pushItemToJSON($0)) })]
        case .drop(let keys):
            payload = ["keys": .array(keys.map { JSONValue.string($0) })]
        case .clear:
            payload = [:]
        case .ping(let t):
            payload = ["t": .number(t)]
        case .rpc(let id, let method, let args):
            payload = [
                "id": .string(id),
                "method": .string(method),
                "args": args
            ]
        }
        let envelope: JSONValue = .object([
            "type": .string(typeName),
            "payload": .object(payload)
        ])
        return envelope.jsonText()
    }

    private static func pushItemToJSON(_ item: TranslationPushItem) -> [String: JSONValue] {
        let segments: [JSONValue] = item.segments.map { seg in
            .object(["kind": .string(seg.kind.rawValue), "value": .string(seg.value)])
        }
        return [
            "key": .string(item.key),
            "translatedRaw": .string(item.translatedRaw),
            "segments": .array(segments)
        ]
    }

    /// 可直接交给 `Runtime.evaluate` 的表达式。
    func evaluateExpression() throws -> String {
        let json = try jsonText()
        let quoted = try HostCommand.jsonStringLiteral(json)
        return "window.__mochibox && window.__mochibox.inbox(\(quoted))"
    }

    /// 把任意文本编码为 JS 字符串字面量（含引号）。
    static func jsonStringLiteral(_ text: String) throws -> String {
        let data = try JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }
}

