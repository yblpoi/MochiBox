//
// agent_diag_probe.swift —— Agent 诊断信封分级/节流的独立探针（不属于产品源码）
//
// 被测类型：`AgentDiagGate`（Sources/Infra/Stores.swift）
// 编译：node Tests/e2e/cases/contract/15_agent_diag.mjs（swiftc 现编现跑，产物落 mkdtemp）
//
// 为什么要有这一条：分流逻辑落在 `SessionController.handleEnvelope` 里，而它是 private、
// 只有真实 adapter attach 才触达；`--play` 那条链路又完全不消费 error 信封。
// 把"分级 + 节流 + 归零"抽成无依赖类型后，这三件事才第一次有行为证据。
//
// 断言与 94ef649 的行为面一一对应：
//   AD-1 首条 start_message_miss → info，且被写出（count=1）
//   AD-2 紧随其后 198 条（#2…#199）全部静默
//   AD-3 第 200 条补一行
//   AD-4 非诊断 code 恒 warn，且不消耗节流计数
//   AD-5 reset() 后回到"首条立即报"
//

import Foundation

final class Reporter {
    private var pass = 0
    private var fail = 0
    private var total = 0

    func check(_ id: String, _ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok {
            pass += 1
            print("ok \(total) - \(id) \(name)")
        } else {
            fail += 1
            print("not ok \(total) - \(id) \(name) # 断言不成立")
            for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
                print("#   \(line)")
            }
        }
    }

    func finish() -> Int32 {
        print("1..\(total)")
        print("# pass \(pass) fail \(fail)")
        return fail == 0 ? 0 : 1
    }
}

@main
struct AgentDiagProbe {
    static let diagnostic = AgentDiagGate.Decision.emit(.info, "Agent 诊断：消息部分行未命中译文")
    static let internalError = AgentDiagGate.Decision.emit(.warn, "Agent 内部错误")

    static func describe(_ decision: AgentDiagGate.Decision) -> String {
        switch decision {
        case let .emit(level, message): return "emit(\(level.rawValue), \(message))"
        case .drop: return "drop"
        }
    }

    static func main() {
        let r = Reporter()
        var gate = AgentDiagGate()

        // AD-1 首条：立即写，且是 info（不是 warn）。
        let first = gate.consume(code: "start_message_miss")
        r.check("AD-1", "首条 start_message_miss → emit(info)，count=1",
                first == diagnostic && gate.count == 1,
                "决策: \(describe(first))\ncount: \(gate.count)（期望 1）")

        // AD-2 节流：接着的 198 条（#2…#199）一条都不能写。
        var dropped = 0
        for _ in 0..<198 where gate.consume(code: "start_message_miss") == .drop { dropped += 1 }
        r.check("AD-2", "#2…#199 共 198 条全部 drop，count=199",
                dropped == 198 && gate.count == 199,
                "drop: \(dropped)（期望 198）\ncount: \(gate.count)（期望 199）")

        // AD-3 第 200 条：补一行，仍是 info。
        let twoHundredth = gate.consume(code: "start_message_miss")
        r.check("AD-3", "第 200 条补一行（emit(info)），count=200",
                twoHundredth == diagnostic && gate.count == 200,
                "决策: \(describe(twoHundredth))\ncount: \(gate.count)（期望 200）")

        // AD-4 其它 code：恒 warn，且不动节流计数（真故障不能被诊断流量挤掉）。
        let other = gate.consume(code: "hook_error")
        r.check("AD-4", "非诊断 code 恒 emit(warn) 且不消耗节流计数",
                other == internalError && gate.count == 200,
                "决策: \(describe(other))\ncount: \(gate.count)（期望仍是 200）")

        // AD-5 会话重启：reset() 后又是"首条立即报"。
        gate.reset()
        let afterReset = gate.consume(code: "start_message_miss")
        r.check("AD-5", "reset() 后回到首条立即报（emit(info)，count=1）",
                afterReset == diagnostic && gate.count == 1,
                "决策: \(describe(afterReset))\ncount: \(gate.count)（期望 1）")

        exit(r.finish())
    }
}
