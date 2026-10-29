//
//  AgentInjector.swift
//  MochiBox
//
//  页面内 Agent 的注入器：双注入（addScriptToEvaluateOnNewDocument + Runtime.evaluate）、
//  等 hello（5s）、幂等校验、drain 拉取、inbox 推送。
//  依据 docs/architecture.md §6、§3.5；docs/prd.md P0-07。
//

import Foundation

final class AgentInjector: @unchecked Sendable {
    /// 页通道（v0.4 §3.2）。**只依赖这一个能力**：exec JS + 取返回值 + startup script。
    /// CDP 与 WKWebView 两个实现同构，因此本文件对"内核是谁"零知识。
    private let channel: any PageChannel
    private let sessionToken: String
    private let log: SessionLog?
    private let script: String
    private var scriptIdentifier: String?

    /// 通道种类（`cdp` / `wk`），只进日志。
    var channelKind: String { return channel.kind }

    /// 在页面里求值一个表达式并返回**字符串**结果（E2E 取证用，如 `__mochibox.probe()`）。
    ///
    /// 放在这里而不是 `MVAdapter` 里：通道是注入器的私有状态，
    /// 让适配器直接拼求值调用会把通道生命周期知识泄漏出去。
    func evaluateString(_ expression: String) async -> String? {
        do {
            let result = try await channel.evaluate(expression, timeout: K.evaluateTimeoutSec)
            return result.value?.stringValue
        } catch {
            log?.warn("AgentInjector", "页面求值失败", ["error": "\(error)", "channel": channel.kind])
            return nil
        }
    }

    init(channel: any PageChannel, sessionToken: String, log: SessionLog?) throws {
        self.channel = channel
        self.sessionToken = sessionToken
        self.log = log
        self.script = try AgentInjector.loadScript()
    }

    // MARK: - 脚本资源

    /// 依次尝试 bundle 资源、可执行文件旁、仓库 Resources 目录、环境变量覆盖。
    static func loadScript() throws -> String {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("agent_mvmz.js"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/agent_mvmz.js"))

        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
            .deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("../Resources/agent_mvmz.js").standardizedFileURL)

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Resources/agent_mvmz.js"))
        candidates.append(cwd.appendingPathComponent("../Resources/agent_mvmz.js").standardizedFileURL)

        if let override = ProcessInfo.processInfo.environment["MOCHI_AGENT_SCRIPT"], !override.isEmpty {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }

        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate), let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        let attempted = candidates.map { $0.path }.joined(separator: " | ")
        throw MochiBoxError(code: .agentNoHello, message: "找不到 agent_mvmz.js（已尝试：\(attempted)）")
    }

    // MARK: - 注入

    /// **早装**：不等引擎符号就绪，反复尝试 `install()`，一命中立刻返回。
    ///
    /// 为什么必须早（这是 `--play` 在真游戏上 `captured=1` 的根因）：
    /// 我们拉起的浏览器里，MZ 从 boot 到"画完开场对白、停在等输入"只要 1–2s。
    /// 等 `Window_Base` 出现再注入（v0.1 的顺序）时，第一屏已经画完；玩家不动，
    /// 页面就再也不会 `drawText` —— 于是整个 run 只留下一两条 boot 期的杂字，
    /// 看起来像"功能没做"，实际是**装晚了**。
    ///
    /// 代价：每次 `install()` 只是一次 CDP `Runtime.evaluate`（脚本本身只注入一次），
    /// 且 `install()` 内部在 `Window_Base` 还没定义时立即返回 false，没有副作用。
    ///
    /// - Returns: 是否在超时前装上了 hook。`false` 时调用方仍可走 v0.1 的
    ///   `waitForGameSymbols` 判定，给出"目标不是 RPG Maker 页面"这类准确错误。
    func installEagerly(timeoutSec: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        // 两个独立状态：登记"刷新后自动注入"只做一次（重复登记会不断加钩子脚本），
        // 而"在当前文档里注入一次"失败才有必要重试（页面可能还在导航中）。
        var registrationDone = false
        var scriptEvaluated = false
        var attempts = 0

        while Date() < deadline {
            attempts += 1
            if !registrationDone {
                registrationDone = true
                // 页面刷新后仍在（与原注入路径一致：这里先登记，重载也不丢）。
                do {
                    let identifier = try await channel.addStartupScript(script)
                    if !identifier.isEmpty { scriptIdentifier = identifier }
                } catch {
                    log?.warn("AgentInjector", "注册 startup script 失败，退化为仅 evaluate", [
                        "error": "\(error)",
                        "channel": channel.kind
                    ])
                }
            }
            if !scriptEvaluated {
                do {
                    _ = try await channel.evaluate(script, timeout: K.evaluateTimeoutSec)
                    scriptEvaluated = true
                } catch {
                    // 页面还在导航中时 evaluate 可能失败：下一轮再试，不算错误。
                    try? await Task.sleep(nanoseconds: UInt64(K.webEarlyInstallPollMs) * 1_000_000)
                    continue
                }
            }

            let expression = "typeof window.__mochibox !== 'undefined' && "
                + "(window.__mochibox.installed === true || (window.__mochibox.install(), window.__mochibox.installed === true))"
            if let result = try? await channel.evaluate(expression, timeout: K.evaluateTimeoutSec), result.value?.boolValue == true {
                log?.info("AgentInjector", "Agent 早装成功", ["attempts": "\(attempts)"])
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(K.webEarlyInstallPollMs) * 1_000_000)
        }
        log?.warn("AgentInjector", "Agent 早装超时", ["attempts": "\(attempts)", "timeout": "\(Int(timeoutSec))"])
        return false
    }

    /// 双注入 + 等 hello。失败重注入 1 次（PRD P0-07 / §7.6）。
    func injectAndHandshake() async throws -> HelloPayload {
        var lastError = MochiBoxError(code: .agentNoHello)
        let attempts = 1 + max(0, K.injectRetryCount)
        // 握手期读走但没消费的信封（见下面 flushHandshakeBacklog）。
        // 跨 attempt 累加：重试时页面里已经没有了，只能靠这里保住。
        var backlog: [AgentEnvelope] = []
        var droppedErrorCount = 0
        // hello 解码失败：既不算成功，也不能无声消失。旧代码用 `try?` 直接丢，
        // 于是"收到过 hello 但解不开"这个唯一线索在握手超时后完全查不到。
        // **按 attempt 计数**：每轮开头归零，两条出口（成功 / 抛错）各 flush 一次。
        // 只在超时路径上报会漏掉"先解不开、下一次握手成功"那次；不归零则计数跨轮累加，
        // 第 2 轮写 count=2 读起来像"本轮失败了两次"。
        var helloDecodeFailures = 0
        var helloDecodeLastError = ""

        // 把本轮累积的解码失败报一次并清零。
        func flushHelloDecodeFailures() {
            guard helloDecodeFailures > 0 else { return }
            log?.warn("AgentInjector", "hello 解码失败，信封已丢弃", [
                "count": "\(helloDecodeFailures)",
                "detail": helloDecodeLastError
            ])
            helloDecodeFailures = 0
            helloDecodeLastError = ""
        }

        for attempt in 1...attempts {
            // 计数按轮：上一轮即便有残留也不带进这一轮。
            helloDecodeFailures = 0
            helloDecodeLastError = ""
            do {
                // 1) 页面刷新后仍在（best effort）。
                if scriptIdentifier == nil {
                    do {
                        let identifier = try await channel.addStartupScript(script)
                        if !identifier.isEmpty { scriptIdentifier = identifier }
                    } catch {
                        log?.warn("AgentInjector", "注册 startup script 失败，退化为仅 evaluate", [
                            "attempt": "\(attempt)",
                            "channel": channel.kind
                        ])
                    }
                }
                // 2) 当前文档立即注入（幂等）。
                let expression = script + "\n;window.__mochibox && window.__mochibox.hello && window.__mochibox.hello();"
                let injected = try await channel.evaluate(expression, timeout: K.evaluateTimeoutSec)
                if let exception = injected.exceptionText {
                    log?.warn("AgentInjector", "注入时抛异常（已由 Agent 内部 try/catch 兜底）", ["detail": String(exception.prefix(200))])
                }

                // 3) 等 hello。
                //
                // **取最后一条 hello，不是第一条**：`install()` 每跑一次都会 emit 一条 hello，
                // 而"早装"阶段第一次 install() 时 `Window_Base` 还没定义 → 那条 hello 的
                // hooks 是空数组。若取第一条，`attached: … hooks=[]` 就会在真游戏上出现，
                // 看起来像"一个 hook 都没挂上"（实际四条都在，probe 可以证明）。
                //
                // **非 hello 的信封不能丢**（`backlog`）：页面侧 `install()` 成功后立刻开始
                // emit（`state.enabled` 默认 true，不等宿主），而 `drain()` 是整个 splice。
                // 早先这里只认 hello、其余读走即焚 —— 真游戏上表现为首屏几句消失、
                // `captured=0`（约 1/4 概率）。退到 `flushHandshakeBacklog` 放回队首。
                let deadline = Date().addingTimeInterval(K.agentHelloTimeoutSec)
                while Date() < deadline {
                    let envelopes = (try? await drain()) ?? []
                    var latest: HelloPayload?
                    for envelope in envelopes {
                        if envelope.type == "hello" {
                            // 解不开就计数（不进 backlog：它已经不是有效信封）。
                            do {
                                latest = try envelope.payload.decoded(HelloPayload.self)
                            } catch {
                                helloDecodeFailures += 1
                                helloDecodeLastError = AgentInjector.describeDecodeFailure(error)
                            }
                        } else if envelope.type == "error" {
                            // error 信封不重放（既有语义：握手期只消费 hello），
                            // 但**不许无声消失**：计数后随回灌那条日志一起报出去。
                            droppedErrorCount += 1
                        } else {
                            backlog.append(envelope)
                        }
                    }
                    if let hello = latest {
                        // 成功出口也要 flush：本轮可能先收到一条解不开的 hello。
                        flushHelloDecodeFailures()
                        log?.info("AgentInjector", "收到 Agent hello", [
                            "agentVersion": "\(hello.agentVersion)",
                            "hooks": hello.hooks.joined(separator: ",")
                        ])
                        await flushHandshakeBacklog(backlog, errorCount: droppedErrorCount)
                        return hello
                    }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                // 本轮等到 deadline 仍无 hello：先把解码失败的线索落盘。
                flushHelloDecodeFailures()
                lastError = MochiBoxError(code: .agentNoHello, message: "注入后 \(Int(K.agentHelloTimeoutSec))s 内未收到 hello（第 \(attempt) 次）")
            } catch let error as MochiBoxError {
                lastError = error
            } catch {
                lastError = MochiBoxError(code: .agentNoHello, underlying: "\(error)")
            }
            log?.warn("AgentInjector", "注入未成功，准备重试", ["attempt": "\(attempt)"])
        }
        // 彻底握手失败也要回灌：这些信封是页面真实产出的文本，跟着 attach 失败一起
        // 丢掉会让"连不上"变成"连不上且首屏文本永久消失"。
        await flushHandshakeBacklog(backlog, errorCount: droppedErrorCount)
        // 抛错出口的兜底：上面每条路径都已 flush，这里只防将来新增分支绕过去。
        flushHelloDecodeFailures()
        throw lastError
    }

    /// 把 hello 解码错误压成**只含字段名**的一行。
    ///
    /// 为什么不直接打 `"\(error)"`：`DecodingError.dataCorrupted` 的 `debugDescription`
    /// 会带一段原始 JSON（页面文本、`key` 等），整段进日志等于把台词抄进磁盘。
    /// 排障需要的是"哪个字段、什么类型的错"，字段名与 `codingPath` 足够。
    static func describeDecodeFailure(_ error: Error) -> String {
        guard let failure = error as? DecodingError else { return "errorType=\(type(of: error))" }
        func codingPath(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { $0.stringValue.isEmpty ? "[\($0.intValue ?? 0)]" : $0.stringValue }
            return parts.isEmpty ? "-" : parts.joined(separator: ".")
        }
        switch failure {
        case let .keyNotFound(key, context):
            return "keyNotFound(\(key.stringValue)) path=\(codingPath(context))"
        case let .typeMismatch(type, context):
            return "typeMismatch(\(type)) path=\(codingPath(context))"
        case let .valueNotFound(type, context):
            return "valueNotFound(\(type)) path=\(codingPath(context))"
        case let .dataCorrupted(context):
            return "dataCorrupted path=\(codingPath(context))"
        @unknown default:
            return "unknownDecodingError"
        }
    }

    // MARK: - 握手期回灌

    /// `window.__mochibox.requeue(<json>)` 的返回值（页面侧统计）。
    struct RequeueReport: Decodable, Sendable {
        var total: Int
        var accepted: Int
        var duplicate: Int
        var dropped: Int

        enum CodingKeys: String, CodingKey { case total, accepted, duplicate, dropped }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = c.tolerantValue(Int.self, forKey: .total, 0)
            accepted = c.tolerantValue(Int.self, forKey: .accepted, 0)
            duplicate = c.tolerantValue(Int.self, forKey: .duplicate, 0)
            dropped = c.tolerantValue(Int.self, forKey: .dropped, 0)
        }
    }

    /// 把握手期读走但没消费的信封**按原序**放回页面 outbox 队首。
    ///
    /// 为什么放队首：这批是全队列里最旧的（`drain()` 从头 splice）。放队尾会让
    /// 文本流乱序，而 `text` 事件的顺序就是屏幕上的台词顺序。
    ///
    /// **失败绝不让 attach 失败**：回灌不上最多是丢掉这几条；让 attach 失败会把
    /// "偶发少几句"升级成"整局连不上"。失败记 warn（提交 A 之后 `--play` 也有日志了）。
    ///
    /// - Returns: 页面侧统计；页面 Agent 不支持 `requeue`（老脚本）时为 nil。
    @discardableResult
    func requeue(_ envelopes: [AgentEnvelope]) async -> RequeueReport? {
        guard !envelopes.isEmpty else { return nil }
        let items: [JSONValue] = envelopes.map { envelope in
            .object([
                "v": .number(Double(envelope.v)),
                "type": .string(envelope.type),
                "sessionToken": .string(envelope.sessionToken),
                "payload": envelope.payload
            ])
        }
        let payloadJSON = JSONValue.array(items).jsonText()
        do {
            let quoted = try HostCommand.jsonStringLiteral(payloadJSON)
            // 老脚本没有 `requeue`：表达式回落到 `'[]'`，解码失败 → 返回 nil。
            let expression = "window.__mochibox && window.__mochibox.requeue ? window.__mochibox.requeue(\(quoted)) : '[]'"
            let result = try await channel.evaluate(expression, timeout: K.evaluateTimeoutSec)
            guard let text = result.value?.stringValue,
                  let data = text.data(using: .utf8),
                  let report = try? JSONDecoder().decode(RequeueReport.self, from: data) else {
                return nil
            }
            return report
        } catch {
            log?.warn("AgentInjector", "握手期信封回灌失败（这些信封已丢失）", [
                "count": "\(envelopes.count)",
                "error": "\(error)",
                "channel": channel.kind
            ])
            return nil
        }
    }

    /// 回灌 + 记一条 info（**验证修复是否生效的关键证据**：条数 + 类型分布 + 页面侧统计）。
    private func flushHandshakeBacklog(_ backlog: [AgentEnvelope], errorCount: Int) async {
        if errorCount > 0 {
            log?.warn("AgentInjector", "握手期丢弃 error 信封（按既有语义不重放）", ["count": "\(errorCount)"])
        }
        guard !backlog.isEmpty else { return }
        var byType: [String: Int] = [:]
        for envelope in backlog { byType[envelope.type, default: 0] += 1 }
        let distribution = byType.keys.sorted().map { "\($0)=\(byType[$0] ?? 0)" }.joined(separator: ",")
        if let report = await requeue(backlog) {
            log?.info("AgentInjector", "握手期信封已回灌 outbox", [
                "count": "\(backlog.count)",
                "types": distribution,
                "accepted": "\(report.accepted)",
                "duplicate": "\(report.duplicate)",
                "dropped": "\(report.dropped)"
            ])
        } else {
            log?.warn("AgentInjector", "握手期信封未能回灌（页面 Agent 可能不支持 requeue）", [
                "count": "\(backlog.count)",
                "types": distribution
            ])
        }
    }

    // MARK: - 收发

    /// 拉取 Agent 出站队列（每次最多 50 条）。
    func drain() async throws -> [AgentEnvelope] {
        let expression = "window.__mochibox ? window.__mochibox.drain() : '[]'"
        let result = try await channel.evaluate(expression, timeout: K.evaluateTimeoutSec)
        guard let text = result.value?.stringValue, let data = text.data(using: .utf8) else { return [] }
        guard let envelopes = try? JSONDecoder().decode([AgentEnvelope].self, from: data) else { return [] }
        return envelopes
    }

    /// 下发命令（config / setTranslation(s) / drop / clear / ping）。
    func push(_ command: HostCommand) async throws {
        let expression = try command.evaluateExpression()
        let result = try await channel.evaluate(expression, timeout: K.evaluateTimeoutSec)
        if let exception = result.exceptionText {
            log?.warn("AgentInjector", "inbox 调用抛异常", ["type": command.typeName, "detail": String(exception.prefix(200))])
        }
    }

    /// 当前是否已装 hook（幂等自检）。
    func isInstalled() async throws -> Bool {
        let result = try await channel.evaluate("window.__mochibox ? window.__mochibox.installed === true : false", timeout: K.evaluateTimeoutSec)
        return result.value?.boolValue ?? false
    }

    /// 尽力而为地卸载（不阻塞退出）。
    func uninstall() async {
        _ = try? await channel.evaluate("window.__mochibox && window.__mochibox.uninstall ? (window.__mochibox.uninstall(), true) : false", timeout: 2)
        if let identifier = scriptIdentifier {
            await channel.removeStartupScript(identifier)
            scriptIdentifier = nil
        }
        _ = sessionToken
    }
}
