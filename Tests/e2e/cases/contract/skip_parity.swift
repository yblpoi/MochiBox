//
//  skip_parity.swift —— V4-14：跳过判据双端 parity 的 Swift 侧打印器。
//
//  把固定样例在 **Swift 侧**的判定结果打成机器可读的 `SWIFT|index|reason`，
//  由 `10_skip_parity.mjs` 与 Agent 侧（真实 Resources/agent_mvmz.js）逐值比对。
//
//  为什么必须比对"两端"：架构 §7.7 要求跳过规则双端一致（Host 判一次、Agent 判一次）。
//  两端各写一套正则/码段集合时必然漂移，症状是同一句在页面上 pending、在 Host 里 skipped。
//
//  判定对象是 **text**（剥掉控制码后的段内容，即 mapKey），不是 raw：
//  `\\C[2]350` 必须先剥码再判，否则两端会得出不同结论。
//
//  编译与运行见 `10_skip_parity.mjs`（swiftc 现编现跑，产物在 mkdtemp 目录）。
//
import Foundation

@main
struct SkipParityProbe {
    static func main() {
        let samples = [
            "350", "！？", "! !", "\u{3000}", "10秒後", "\\C[2]350", "3 5 0",
            // v0.2 转义码大小写不敏感后新增：小写码剥掉后同样是纯数字 → 必须同判 skip。
            "\\c[3]350",
            // 纯图标码：mapKey 退回原串 `\\i[17]`，含字母，不是纯数字/纯标点 → 必须翻译。
            "\\i[17]",
            // 已是中文：无假名 + 汉字 ≥8 + ≥2 个不同虚词 → chinese（排在 tooShort 之前）。
            "这是一段已经完全翻译好的中文对白，不需要再翻译。",
            "游戏设置里可以调整音量和画面亮度，您看这样合适吗？",
            // 反例：含假名、虚词只有「的」→ 不能跳过。
            "我々は目的を了解した"
        ]
        for (index, raw) in samples.enumerated() {
            let segments = Segmenter.splitSegments(raw: raw, engineFamily: K.engineFamily)
            let text = Segmenter.mapKey(segments)
            let reason = SkipRules.skipReason(for: text, enabled: true, minLength: K.minTranslateLength)
            print("SWIFT|\(index)|\(reason ?? "nil")")
        }
    }
}
