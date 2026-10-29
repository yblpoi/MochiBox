//
//  AgentRPC.swift
//  MochiBox
//
//  Host → Agent 的调用—返回通道（docs/architecture-v0.6-cheat-and-fulltext.md §2.2）。
//
//  为什么需要第二套通行方式（而不是给 `inbox` 加个回执）：
//  `inbox` 的语义是 fire-and-forget，作弊面板要的是"调用 → 结果/错误码"，并且必须能
//  把"回包"和"发出去的请求"对上号。所以这里维护一张 `id → 等待者` 的表，
//  回包由**现有的 drain pump**（`SessionController.handleEnvelope`）驱动 ——
//  **不新增第二条 drain 循环**：两条 pump 会互相抢 `__mochibox.drain()` 的配额，
//  症状是文本偶发丢句、RPC 偶发超时（都很像"游戏卡"）。
//
//  传输层是一个闭包（`adapter.send(.rpc(...))`）而不是 `PageChannel`：
//  通道的持有者是 `MVAdapter`/`AgentInjector`，绕过去就要在 Adapters 层开洞；
//  而 `inbox` 本来就是 Host 唯一的出口（架构 §3.5），复用它是正确的那条缝。
//

import Foundation

// MARK: - 协议载荷

/// `{"v":1,"type":"rpcResult","payload":{"id","ok","data","error"}}`
struct AgentRPCResultPayload: Decodable, Sendable {
    var id: String
    var ok: Bool
    var data: JSONValue?
    var error: AgentRPCErrorPayload?

    enum CodingKeys: String, CodingKey { case id, ok, data, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerantValue(String.self, forKey: .id, "")
        self.ok = c.tolerantValue(Bool.self, forKey: .ok, false)
        self.data = c.tolerantOptional(JSONValue.self, forKey: .data)
        self.error = c.tolerantOptional(AgentRPCErrorPayload.self, forKey: .error)
    }
}

struct AgentRPCErrorPayload: Decodable, Sendable, Equatable {
    var code: String
    var message: String

    enum CodingKeys: String, CodingKey { case code, message }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = c.tolerantValue(String.self, forKey: .code, "rpc_error")
        self.message = c.tolerantValue(String.self, forKey: .message, "")
    }
}

/// Agent 在 `text.scanStart` 里顺带回来的界面术语（`$dataSystem.terms` 等）。
///
/// **不走 scanCandidate**：扫描语料会丢掉「纯 ASCII 且无空白」（HP/MP/TP/EXP/Lv）
/// 与单字串（運），而这些正是最需要统一译名的界面术语。
struct ScanTerm: Decodable, Sendable, Equatable {
    var raw: String
    /// `system`（terms.*/currencyUnit）或 `type`（elements/skillTypes/…）。
    var kind: String
    var path: String

    enum CodingKeys: String, CodingKey { case raw, kind, path }

    init(raw: String, kind: String = "", path: String = "") {
        self.raw = raw
        self.kind = kind
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = c.tolerantValue(String.self, forKey: .raw, "")
        self.kind = c.tolerantValue(String.self, forKey: .kind, "")
        self.path = c.tolerantValue(String.self, forKey: .path, "")
    }
}

/// `text.scanStart` 的立即回包。
struct ScanStartPayload: Decodable, Sendable, Equatable {
    var scanId: String
    /// 扫描开始时的已知条数（地图 fetch 的部分还不算在内，只用于进度条的初值）。
    var estimated: Int
    /// 界面术语（旧 Agent 没有这个字段 → 空数组）。
    var terms: [ScanTerm]

    enum CodingKeys: String, CodingKey { case scanId, estimated, terms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scanId = c.tolerantValue(String.self, forKey: .scanId, "")
        self.estimated = c.tolerantValue(Int.self, forKey: .estimated, 0)
        self.terms = c.tolerantValue([ScanTerm].self, forKey: .terms, [])
    }
}

struct ScanItem: Decodable, Sendable, Equatable {
    var raw: String
    /// `actor|class|skill|item|weapon|armor|enemy|troop|state|animation|tileset|common_event|system|map|runtime`
    var source: String
    var path: String

    enum CodingKeys: String, CodingKey { case raw, source, path }

    init(raw: String, source: String = "", path: String = "") {
        self.raw = raw
        self.source = source
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = c.tolerantValue(String.self, forKey: .raw, "")
        self.source = c.tolerantValue(String.self, forKey: .source, "")
        self.path = c.tolerantValue(String.self, forKey: .path, "")
    }
}

struct ScanChunkPayload: Decodable, Sendable {
    var scanId: String
    var seq: Int
    var items: [ScanItem]

    enum CodingKeys: String, CodingKey { case scanId, seq, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scanId = c.tolerantValue(String.self, forKey: .scanId, "")
        self.seq = c.tolerantValue(Int.self, forKey: .seq, 0)
        self.items = c.tolerantValue([ScanItem].self, forKey: .items, [])
    }
}

struct ScanDonePayload: Decodable, Sendable {
    var scanId: String
    var total: Int
    var skipped: Int
    var cancelled: Bool

    enum CodingKeys: String, CodingKey { case scanId, total, skipped, cancelled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scanId = c.tolerantValue(String.self, forKey: .scanId, "")
        self.total = c.tolerantValue(Int.self, forKey: .total, 0)
        self.skipped = c.tolerantValue(Int.self, forKey: .skipped, 0)
        self.cancelled = c.tolerantValue(Bool.self, forKey: .cancelled, false)
    }
}

// MARK: - 常量

/// RPC 专用常量。刻意**不**放进 `K`：`Sources/App/Constants.swift` 不在 T02 的
/// 改动范围（§7 冲突规则），而且这三个值只有本文件与 `FullTextController` 用。
enum AgentRPCConfig {
    /// 普通调用超时（契约 §2.2）。
    static let callTimeoutSec: Double = 5
    /// 扫描类调用超时（`text.scan*`；地图 fetch + 10k 条语料的枚举可能跨秒）。
    static let scanTimeoutSec: Double = 30
    /// 扫描前缀：命中即用 30s 超时。
    static let scanPrefix = "text.scan"
}

// MARK: - 客户端

/// 请求-应答通道。actor：等待表会被「发送 / 收包 / 超时 / 关闭」四条路径同时改。
///
/// 失败语义统一成 `MochiBoxError`：
///   · Agent 回 `ok:false` → 按 `code` 映射（`cheat_unavailable` 等，见 `mapError`）；
///   · 超时 → `.rpcTimeout`；
///   · 发送失败（通道已死 / 未注入）→ 原样抛（通常是 `.attachFailed`）；
///   · `close()` → 所有在飞请求立刻以 `.attachFailed` 结束，**不留下永远挂起的 continuation**。
actor AgentRPC {
    /// 唯一依赖：把一个 `HostCommand` 推进页面 inbox。
    typealias Transport = @Sendable (HostCommand) async throws -> Void

    private struct Pending {
        var continuation: CheckedContinuation<JSONValue, Error>
        var timer: Task<Void, Never>
    }

    private let transport: Transport
    private let log: SessionLog?
    private var seq: Int = 0
    private var pending: [String: Pending] = [:]
    private var closed: Bool = false

    init(transport: @escaping Transport, log: SessionLog? = nil) {
        self.transport = transport
        self.log = log
    }

    /// 在飞请求数（诊断 / 自测用）。
    var pendingCount: Int { return pending.count }

    /// 调用一个 Agent 方法。
    ///
    /// - Parameters:
    ///   - args: **必须是 object**（Agent 直接 `args.from` 取值）。
    ///   - timeout: `nil` = 按方法名自动选（`text.scan*` 30s，其余 5s）。
    func call(
        method: String,
        args: JSONValue = .object([:]),
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        if closed {
            throw MochiBoxError(code: .attachFailed, message: "RPC 通道已关闭（会话已停止）")
        }
        let seconds = timeout ?? (method.hasPrefix(AgentRPCConfig.scanPrefix)
            ? AgentRPCConfig.scanTimeoutSec
            : AgentRPCConfig.callTimeoutSec)
        seq += 1
        let id = "c-\(seq)"

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            // detached：不继承本 actor 的隔离域，`await self?.expire` 才是真的跨域调用
            // （继承隔离会得到"no async operations occur within await"的告警）。
            let timer = Task.detached { [weak self] in
                let nanos = UInt64(max(0.05, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                await self?.expire(id: id, timeout: seconds)
            }
            pending[id] = Pending(continuation: continuation, timer: timer)

            let command = HostCommand.rpc(id: id, method: method, args: args)
            Task.detached { [weak self, transport] in
                do {
                    try await transport(command)
                } catch {
                    await self?.failSend(id: id, error: error)
                }
            }
        }
    }

    /// 收包入口（由 `SessionController.handleEnvelope` 调用）。
    func deliver(_ payload: AgentRPCResultPayload) {
        guard !payload.id.isEmpty else { return }
        if payload.ok {
            finish(id: payload.id, result: .success(payload.data ?? .null))
            return
        }
        let error = AgentRPC.mapError(payload.error)
        log?.debug("AgentRPC", "调用失败", [
            "id": payload.id,
            "code": error.code.rawValue
        ])
        finish(id: payload.id, result: .failure(error))
    }

    /// 会话停止 / 重连：把所有等待者叫醒，别让 UI 的 `await` 永远挂着。
    func close(reason: ErrorInfo = ErrorInfo(code: .attachFailed, message: "会话已停止")) {
        closed = true
        let error = MochiBoxError(code: reason.code, message: reason.message)
        let ids = Array(pending.keys)
        for id in ids {
            finish(id: id, result: .failure(error))
        }
    }

    // MARK: - 内部

    private func finish(id: String, result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result)
    }

    private func expire(id: String, timeout: Double) {
        guard pending.keys.contains(id) else { return }
        log?.warn("AgentRPC", "调用超时", ["id": id, "timeout": "\(Int(timeout))"])
        finish(id: id, result: .failure(MochiBoxError(
            code: .rpcTimeout,
            message: "Agent 未在 \(Int(timeout))s 内回应（页面可能卡住或 Agent 已卸载）"
        )))
    }

    private func failSend(id: String, error: Error) {
        let wrapped: Error
        if let mochiError = error as? MochiBoxError {
            wrapped = mochiError
        } else {
            wrapped = MochiBoxError(code: .attachFailed, message: "RPC 下发失败", underlying: "\(error)")
        }
        finish(id: id, result: .failure(wrapped))
    }

    // MARK: - 错误映射

    /// Agent 的 `error.code` → `MochiBoxError`。
    ///
    /// 认得的码一一对应，认不得的落到 `.agentError` 但**保留原始 code**在 message 里：
    /// 排障时"到底哪一句被拒绝"比一个笼统的枚举值重要。
    static func mapError(_ payload: AgentRPCErrorPayload?) -> MochiBoxError {
        let rawCode = payload?.code ?? "rpc_error"
        let message = payload?.message ?? "Agent 未给出错误描述"
        let mapped: ErrorCode
        switch rawCode {
        case "cheat_unavailable":
            mapped = .cheatUnavailable
        case "cheat_out_of_range":
            mapped = .cheatOutOfRange
        case "cheat_bad_args", "rpc_bad_request":
            mapped = .cheatBadArgs
        case "cheat_forbidden":
            mapped = .cheatForbidden
        case "rpc_unknown_method":
            mapped = .rpcUnknownMethod
        default:
            mapped = .agentError
        }
        if mapped == .agentError || mapped == .cheatBadArgs {
            return MochiBoxError(code: mapped, message: "\(rawCode): \(message)")
        }
        return MochiBoxError(code: mapped, message: message)
    }
}
