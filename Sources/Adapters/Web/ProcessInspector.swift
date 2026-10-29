//
//  ProcessInspector.swift
//  MochiBox
//
//  进程身份判定（只读）：把「这个 pid 是不是我们拉起的那个浏览器」收敛成一处实现。
//
//  为什么单独成文件：
//   1. `WebGameRunner.reclaimOrphanBrowser()` 与 `BrowserProcessSweeper` 都要回答同一个问题；
//      各写一份判据，早晚会一份认 `--user-data-dir=`、另一份认路径前缀，残留就杀不干净。
//   2. 这里全是 `sysctl` / `proc_pidpath` 的系统调用，和启动编排无关；
//      放在 WebGameRunner 里会让那个 actor 继续膨胀。
//
//  **只做识别，不做决定**：杀不杀、怎么等，由调用方决定。
//

import Foundation
import Darwin

enum ProcessInspector {
    /// pid 是否还活着（僵尸进程也会返回 true；调用方需要自己区分）。
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// 可执行文件路径（`proc_pidpath`）。取不到（权限/已退出）返回 nil。
    static func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 可执行文件名里带浏览器标记（Chrome / Chromium / Edge / Brave / Vivaldi）。
    static func looksLikeBrowser(pid: Int32) -> Bool {
        guard let executable = executablePath(pid: pid) else { return false }
        let markers = ["Chrome", "Chromium", "chrome", "chromium", "Edge", "Brave", "Vivaldi"]
        return markers.contains { executable.contains($0) }
    }

    /// 从 `KERN_PROCARGS2` 读完整 argv。
    ///
    /// `KERN_PROCARGS2` 在部分 SDK 里没有 Swift 符号，按 `<sys/sysctl.h>` 的取值写死 49。
    static func arguments(pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        let kernProcArgs2: Int32 = 49
        var mib: [Int32] = [CTL_KERN, kernProcArgs2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<MemoryLayout<Int32>.size]))
            }
        }
        guard argc > 0, argc < 4096 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // 跳过 exec_path
        while index < size, buffer[index] == 0 { index += 1 }   // 跳过 NUL 填充

        var arguments: [String] = []
        for _ in 0..<Int(argc) {
            if index >= size { break }
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// `pid` 是否是我们用 `profileDir` 拉起的浏览器。
    ///
    /// 判据 = 活着的浏览器内核进程 **且** argv 里带 `--user-data-dir=<本 profile>`。
    /// 两个条件缺一不可：pid 可能被系统复用给无关 Chrome 用户，
    /// 只看"像浏览器"就杀是越界行为（会杀掉用户自己开着的 Chrome）。
    static func isBrowser(pid: Int32, profileDir: URL) -> Bool {
        guard isAlive(pid), looksLikeBrowser(pid: pid) else { return false }
        guard let arguments = arguments(pid: pid) else { return false }
        let flag = "--user-data-dir="
        let candidates = Set([
            profileDir.standardizedFileURL.path,
            profileDir.resolvingSymlinksInPath().path
        ])
        return arguments.contains { argument in
            guard argument.hasPrefix(flag) else { return false }
            var value = String(argument.dropFirst(flag.count))
            while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
            let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
            for candidate in candidates {
                if standardized == candidate { return true }
                // Chrome 的 helper 偶尔会把 profile 写成带尾斜杠/子路径的形式；
                // 只接受 **candidate + "/"** 前缀，避免 `/a/bc` 误命中 `/a/b`。
                if standardized.hasPrefix(candidate + "/") { return true }
            }
            return false
        }
    }
}
