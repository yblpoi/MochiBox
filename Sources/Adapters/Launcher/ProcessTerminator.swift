//
//  ProcessTerminator.swift
//  MochiBox
//
//  「SIGTERM → 等宽限 → SIGKILL」的**唯一**实现。
//
//  为什么必须只有一份：这套逻辑原本在 6 处各写一遍（GameLauncher ×2、WebGameRunner ×2、
//  BrowserProcessSweeper、ChildProcessRegistry），宽限有 3s / 1s / 0.3s，轮询有 100ms /
//  固定睡满两种。任何一处把「等多久」或「要不要补 SIGKILL」抄错，症状都是残留浏览器
//  占着 profile 锁 + 假 web_port_busy，而**没有任何用例会红**。
//
//  **只统一机制，不统一参数**：宽限与轮询间隔由调用方传入，各自保持原值；
//  日志也留在调用方（本类型不持有 SessionLog，也不知道是谁在收谁）。
//
//  两种等待语义，调用方按原有行为选：
//    · pollMs > 0：每 pollMs 检查一次 isAlive，提前死就提前返回（最多等 graceSec）；
//    · pollMs <= 0：不看进程状态，只睡满 graceSec，然后**无条件** SIGKILL。
//      这是 GameLauncher.terminate 的 pid 兜底分支原有语义，不要「顺手」改成轮询。
//
//  同步版给退出路径（applicationWillTerminate / 启动时清扫）用；
//  异步版给 actor 内用（等待期间让出执行器，不阻塞其他消息）。
//

import Foundation
import Darwin

enum ProcessTerminator {

    /// 一次收尾的结论（日志与「补一刀之后还要等多久」由调用方决定）。
    struct Outcome: Sendable, Equatable {
        /// 宽限期结束时进程仍在，已补发 SIGKILL。
        var escalated: Bool
    }

    /// 同步收尾：SIGTERM → 等（轮询或睡满）→ 仍在则 SIGKILL。
    ///
    /// 会阻塞当前线程最多 graceSec，只用于进程退出 / 启动清扫这类同步路径。
    @discardableResult
    static func terminate(
        pid: Int32,
        graceSec: Double,
        pollMs: Int,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> Outcome {
        // pid <= 0 绝不发信号：kill(-1, …) 会打到当前用户的所有进程。
        guard pid > 0 else { return Outcome(escalated: false) }
        kill(pid, SIGTERM)
        if pollMs <= 0 {
            usleep(useconds_t(max(graceSec, 0) * 1_000_000))
            kill(pid, SIGKILL)
            return Outcome(escalated: true)
        }
        let deadline = Date().addingTimeInterval(graceSec)
        while Date() < deadline {
            if !isAlive(pid) { return Outcome(escalated: false) }
            usleep(useconds_t(pollMs * 1000))
        }
        if isAlive(pid) {
            kill(pid, SIGKILL)
            return Outcome(escalated: true)
        }
        return Outcome(escalated: false)
    }

    /// 异步收尾：与 terminate 逐条同语义，只把 usleep 换成 Task.sleep。
    /// 改动其中一份时必须同步另一份（两者唯一的差别就是睡眠方式）。
    @discardableResult
    static func terminateAsync(
        pid: Int32,
        graceSec: Double,
        pollMs: Int,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) async -> Outcome {
        guard pid > 0 else { return Outcome(escalated: false) }
        kill(pid, SIGTERM)
        if pollMs <= 0 {
            try? await Task.sleep(nanoseconds: UInt64(max(graceSec, 0) * 1_000_000_000))
            kill(pid, SIGKILL)
            return Outcome(escalated: true)
        }
        let deadline = Date().addingTimeInterval(graceSec)
        while Date() < deadline {
            if !isAlive(pid) { return Outcome(escalated: false) }
            try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
        }
        if isAlive(pid) {
            kill(pid, SIGKILL)
            return Outcome(escalated: true)
        }
        return Outcome(escalated: false)
    }

    /// 批量收尾（应用退出路径）：先对所有 pid 发 SIGTERM，等**一次** graceSec，
    /// 再对仍活着的补 SIGKILL。
    ///
    /// 为什么不是循环调用 terminate：那会让总耗时变成 N × 宽限。
    /// 主线程退出路径上多等几百毫秒就会卡住 Dock 的「退出」。
    static func terminateAll(
        pids: [Int32],
        graceSec: Double,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) {
        guard !pids.isEmpty else { return }
        for pid in pids where pid > 0 { kill(pid, SIGTERM) }
        usleep(useconds_t(max(graceSec, 0) * 1_000_000))
        for pid in pids where pid > 0 && isAlive(pid) { kill(pid, SIGKILL) }
    }
}
