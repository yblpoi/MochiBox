//
//  ChildProcessLauncher.swift
//  MochiBox
//
//  「日志落盘 + Process 装配 + run()」的唯一实现。
//
//  GameLauncher（nwjs）与 WebGameRunner（Chromium）原本各写一份，逐行对应，
//  只差错误码与 cwd —— 那两样留在调用方，因为它属于各自的失败语义。
//
//  句柄归属：本函数返回**已打开的** FileHandle（0600）。
//    · run() 失败时由本函数关掉（否则每失败一次泄漏一个 fd）；
//    · run() 成功后由调用方负责关闭 —— WebGameRunner 存起来在 shutdown 里关，
//      GameLauncher 交给 Process 持有（进程对象活多久它就活多久）。
//
//  目录创建故意留在调用方：两处的做法不同（一处靠 ensureDirectories、
//  一处显式 createDirectory 且失败要往上抛），不属于可统一的机制。
//

import Foundation

enum ChildProcessLauncher {

    /// 已启动的子进程 + 它的日志句柄。
    struct Launched {
        var process: Process
        /// 日志文件句柄（可能为 nil：日志文件打不开不该挡住启动）。
        var logHandle: FileHandle?
    }

    /// 建日志文件（0600）→ 装配 Process（stdout/stderr 都指向它）→ run()。
    ///
    /// 失败时抛**原始错误**：调用方要按自己的错误码与文案包装
    ///（launcher_no_executable / browser_exited_early），不在这里猜。
    static func launch(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        logURL: URL
    ) throws -> Launched {
        FileManager.default.createFile(
            atPath: logURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        let logHandle = try? FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let logHandle = logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            // 进程没起来 → 这个 fd 没人会再关，必须在这里收掉。
            try? logHandle?.close()
            throw error
        }
        return Launched(process: process, logHandle: logHandle)
    }
}
