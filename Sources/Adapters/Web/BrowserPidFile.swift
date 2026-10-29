//
//  BrowserPidFile.swift
//  MochiBox
//
//  `<profileDir>/.mochibox-browser.pid` 的唯一读写实现。
//
//  为什么需要它：CLI 被 Ctrl-C / `kill -9` 时没有任何清理逻辑会跑，浏览器就成了孤儿，
//  下一次启动直接 `browser_exited_early`。pid 文件是「上次是谁」的唯一线索，所以
//  「读它的判据」「写它的权限」两处必须一字不差 —— 读的一侧原本在
//  `WebGameRunner` 与 `BrowserProcessSweeper` 里逐字重复了两份。
//
//  格式固定为纯数字 + 换行、权限 0600（pid 是本地信息，不需要也不应该让同机其它账户读到）。
//

import Foundation

enum BrowserPidFile {

    /// 读 pid：最多 64 字节 → 去首尾空白 → Int32。
    ///
    /// 任何一步失败都返回 nil（文件不在 / 空 / 不是数字）：调用方按「没有线索」处理，
    /// 不要在这里区分原因 —— 两种旧实现都是这么做的。
    static func read(_ url: URL) -> Int32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }

    /// 写 pid：内容 `<pid>\n`，权限 0600，原子替换（复用 `FileIO.atomicWrite`）。
    static func write(_ pid: Int32, to url: URL) throws {
        try FileIO.atomicWrite(Data("\(pid)\n".utf8), to: url, permissions: 0o600)
    }

    /// 删 pid 文件（不存在也算成功）。
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
