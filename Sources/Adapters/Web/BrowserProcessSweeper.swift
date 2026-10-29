//
//  BrowserProcessSweeper.swift
//  MochiBox
//
//  启动/退出时的**残留浏览器清扫**：只清「带本 App profile 的 Chromium」。
//
//  背景（用户实测反馈）：早期版本跑过 Chromium 窗口模式后，如果进程被 Ctrl-C / SIGKILL
//  或者半路失败，浏览器会活下来：Dock 里一直挂着一个 Chrome 图标、profile 被占着单实例锁、
//  下一次启动直接 `browser_exited_early`。`WebGameRunner.reclaimOrphanBrowser()` 只在
//  **同一游戏再次启动**时才扫，跨游戏/换目录就扫不到。
//
//  本清扫器把范围扩大到 `browser-profiles/*/.mochibox-browser.pid`：
//    · 只认 pid 文件 + `ProcessInspector.isBrowser` 双重判据，绝不误杀用户自己的 Chrome；
//    · SIGTERM → 1s → SIGKILL，与 WebGameRunner 的收尾顺序一致；
//    · 无论杀没杀，pid 文件都删掉（死 pid 留着只会让下一轮误判）。
//
//  **不碰**：`--browser` 指向的外部浏览器（没有写 pid 文件、也没有我们的 profile）。
//

import Foundation

enum BrowserProcessSweeper {
    struct Result: Sendable, Equatable {
        var killed: [Int32] = []
        var stalePidFiles: Int = 0
        var scanned: Int = 0
    }

    /// 清扫所有 profile 目录里的残留。**同步**，可在 `applicationWillTerminate` 里直接调。
    @discardableResult
    static func sweep(paths: AppPaths = .shared, graceSec: Double = 1.0) -> Result {
        return sweep(pathsList: [paths], graceSec: graceSec)
    }

    /// 多根清扫。
    ///
    /// 为什么需要：产品根（`AppPaths.shared`）与 `--selftest` 的临时根是**两套**目录，
    /// 自检留下的浏览器全在 `/var/folders/…/MochiBox-selftest-<pid>/browser-profiles` 下。
    /// 只扫产品根，自检的孤儿永远发现不了 —— 那正是"注入缺陷实验"留下的那批进程。
    @discardableResult
    static func sweep(pathsList: [AppPaths], graceSec: Double = 1.0) -> Result {
        var result = Result()
        for paths in pathsList {
            let one = sweepOne(paths: paths, graceSec: graceSec)
            result.killed += one.killed
            result.stalePidFiles += one.stalePidFiles
            result.scanned += one.scanned
        }
        return result
    }

    private static func sweepOne(paths: AppPaths, graceSec: Double) -> Result {
        var result = Result()
        let manager = FileManager.default
        guard let profileDirs = try? manager.contentsOfDirectory(
            at: paths.browserProfilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }

        for dir in profileDirs {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let pidURL = dir.appendingPathComponent(K.webBrowserPidFileName)
            guard manager.fileExists(atPath: pidURL.path) else { continue }
            result.scanned += 1

            let pid = BrowserPidFile.read(pidURL)
            if let pid = pid, ProcessInspector.isBrowser(pid: pid, profileDir: dir) {
                // 宽限由调用方给（默认 1s）、100ms 轮询 —— 与原实现同值。
                let outcome = ProcessTerminator.terminate(
                    pid: pid,
                    graceSec: graceSec,
                    pollMs: 100,
                    isAlive: { ProcessInspector.isBrowser(pid: $0, profileDir: dir) }
                )
                if outcome.escalated {
                    // 给内核一点时间回收：紧接着的启动会重新绑定同一 profile。
                    usleep(200_000)
                }
                result.killed.append(pid)
            }

            // 无论进程在不在，pid 文件都已过期：删掉，避免下一轮念同一句。
            BrowserPidFile.remove(pidURL)
            result.stalePidFiles += 1
        }
        return result
    }
}
