//
//  EscapeCaseSupport.swift
//  MochiBox
//
//  `--selftest` F 组：转义码大小写不敏感改造（v0.2）的双端护栏。
//
//  为什么必须有这一组（docs/archive/v0.2/architecture-v0.2-web-runner.md §8.4 / §11 R7）：
//    `Resources/agent_mvmz.js` 与 `Sources/Domain/Segmenter.swift` 是**两份**分段实现。
//    只要有一处不同步，症状就是"翻译成功、缓存也写了，游戏里永远是原文"
//    —— 不报错、不崩溃，靠人肉根本查不出来。唯一的自动化护栏就是这里：
//    用 JavaScriptCore 载入**真实** agent 脚本，与 Swift 逐段比对 `kind` / `value` / `mapKey`。
//

import Foundation
import JavaScriptCore

extension SelfTestRunner {

    /// §8.6 的对照表（改造后必须逐条成立）。
    ///
    /// 注意 `\n[1]` 是"反斜杠 + n"（MZ 的人名替换码），**不是换行**；
    /// 在 Swift 字符串里必须写 `\\n`，否则会变成真换行、断言看起来"莫名其妙"。
    static let escapeCasesTable: [(raw: String, kinds: [String], values: [String], mapKey: String)] = [
        ("\\c[3]魔法", ["code", "text"], ["\\c[3]", "魔法"], "魔法"),
        ("\\i[17]回复药", ["code", "text"], ["\\i[17]", "回复药"], "回复药"),
        ("\\n[1]获得", ["code", "text"], ["\\n[1]", "获得"], "获得"),
        ("\\g", ["code"], ["\\g"], "\\g"),
        // `\z[1]` 判 **text** 是刻意设计：MZ 只认它那张表，把"所有字母"都收进码表
        // 会把真正的正文（比如误输入的 `\z`）吃掉，而且与 MZ 实际行为不符。
        ("\\z[1]", ["text"], ["\\z[1]"], "\\z[1]"),
        // 回归锚点：全大写形态改造前后必须**完全一致**。
        ("\\C[2]魔物\\G", ["code", "text", "code"], ["\\C[2]", "魔物", "\\G"], "魔物")
    ]

    /// 双端 parity 的 20 条 sample（含小写码、缺右括号、单反斜杠、连续码、无码正文）。
    static let escapeParitySamples: [String] = [
        "\\c[3]魔法",
        "\\C[3]魔法",
        "\\i[17]回复药",
        "\\I[3]道具",
        "\\n[1]获得",
        "\\N[1]",
        "\\v[104]テキスト",
        "\\V[11]",
        "\\g",
        "\\G",
        "\\z[1]",
        "\\Z[1]",
        "\\FS[20]\\c[2]x",
        "\\PX[1]\\PY[2]",
        "\\p[3]",
        // 有 `[` 无 `]`：两端都必须当普通文本（返回 nil / -1 的同一语义）。
        "\\c[3",
        // 双反斜杠 + 单反斜杠（`\\` 是单字符码，末尾孤立的 `\` 是正文）。
        "\\\\",
        "\\",
        // 完全无码。
        "こんにちは",
        // 码在中间、尾部有正文。
        "前缀\\c[0]后缀"
    ]

    static var escapeCases: [SelfTestCase] {
        return [
            SelfTestCase(group: "F", name: "escape_case_insensitive") { _ in
                // 码表版本必须两端同值（改一端就红）。
                try expectEqual(K.escapeTableVersion, 2, "Swift 码表版本")
                for row in escapeCasesTable {
                    let segments = Segmenter.splitSegments(raw: row.raw, engineFamily: K.engineFamily)
                    try expectEqual(segments.count, row.kinds.count, "\(row.raw) 段数")
                    for (index, segment) in segments.enumerated() {
                        let expectedKind = row.kinds[index] == "code" ? SegmentKind.code : SegmentKind.text
                        try expectEqual(segment.kind, expectedKind, "\(row.raw) 第 \(index + 1) 段 kind")
                        try expectEqual(segment.value, row.values[index], "\(row.raw) 第 \(index + 1) 段 value")
                    }
                    // 段值必须**原样保留**：`\c[3]` 不能被上转成 `\C[3]`。
                    try expectEqual(Segmenter.mapKey(segments), row.mapKey, "\(row.raw) 的 mapKey")
                }
            },
            SelfTestCase(group: "F", name: "escape_parity_js_vs_swift") { _ in
                let context = try makeAgentContext()

                let jsTableVersion = context.evaluateScript("window.__mochibox.escapeTableVersion")?.toInt32() ?? -1
                try expectEqual(Int(jsTableVersion), K.escapeTableVersion, "JS 与 Swift 的码表版本必须同值")

                // 把 sample 用 JSON 传进 JS：避免手拼字符串时被转义规则坑（`\n` 之类）。
                let samplesData = try JSONSerialization.data(withJSONObject: escapeParitySamples, options: [])
                guard let samplesJSON = String(data: samplesData, encoding: .utf8) else {
                    throw SelfTestFailure(message: "samples 序列化失败")
                }
                let script = """
                (function () {
                  var samples = \(samplesJSON);
                  var out = [];
                  for (var i = 0; i < samples.length; i++) {
                    out.push({
                      segments: window.__mochibox.splitSegments(samples[i]),
                      key: window.__mochibox.mapKeyOf(samples[i])
                    });
                  }
                  return JSON.stringify(out);
                })()
                """
                guard let raw = context.evaluateScript(script)?.toString(),
                      let rawData = raw.data(using: .utf8),
                      let list = (try? JSONSerialization.jsonObject(with: rawData)) as? [[String: Any]] else {
                    throw SelfTestFailure(message: "JS 侧 splitSegments 输出无法解析：\(context.evaluateScript(script)?.toString() ?? "nil")")
                }
                try expectEqual(list.count, escapeParitySamples.count, "sample 数量")

                for (index, sample) in escapeParitySamples.enumerated() {
                    let swiftSegments = Segmenter.splitSegments(raw: sample, engineFamily: K.engineFamily)
                    let entry = list[index]
                    let jsSegments = (entry["segments"] as? [[String: Any]]) ?? []
                    let jsKey = (entry["key"] as? String) ?? ""

                    try expectEqual(jsSegments.count, swiftSegments.count,
                                    "\(sample) 段数（JS \(jsSegments.count) / Swift \(swiftSegments.count)）")
                    for (offset, segment) in swiftSegments.enumerated() {
                        let jsKind = (jsSegments[offset]["kind"] as? String) ?? ""
                        let jsValue = (jsSegments[offset]["value"] as? String) ?? ""
                        try expectEqual(jsKind, segment.kind.rawValue, "\(sample) 第 \(offset + 1) 段 kind")
                        try expectEqual(jsValue, segment.value, "\(sample) 第 \(offset + 1) 段 value")
                    }
                    try expectEqual(jsKey, Segmenter.mapKey(swiftSegments), "\(sample) 的 mapKey")
                }
            }
        ]
    }
}
