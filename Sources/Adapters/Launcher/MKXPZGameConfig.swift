//
//  MKXPZGameConfig.swift
//  MochiBox
//
//  mkxp-z 的每游戏数据目录覆盖：启动前把 dataPathOrg / dataPathApp 写进
//  <gameRoot>/mkxp.json，退出时还原（含上次崩溃留下的残骸）。
//
//  为什么是这一对键（实测 + 源码，vendor/mkxpz 对应的上游 commit f02d586）：
//    · mkxp-z **没有** savePath / SAVE_PATH / getSavePath，也没有任何环境变量入口
//      （src/config.cpp 只有 SDL_getenv 的 MKXPZ_WINDOWS_CONSOLE / MKXPZ_FOLDER_SELECT，
//       main.cpp 只有 SRCDIR / ANGLE_DEFAULT_PLATFORM）；
//    · 每游戏目录由 src/config.cpp:430 的
//      `customDataPath = SDL_GetPrefPath(dataPathOrg, dataPathApp)` 决定，
//      默认 dataPathOrg="."、dataPathApp=Game.ini 的 [Game] Title；
//    · 在 macOS 上 SDL_GetPrefPath 就是 `~/Library/Application Support/<org>/<app>/`。
//  所以能改的只有 dataPathOrg/dataPathApp —— 它们把 mkxp-z 自己存的每游戏数据
//  （键位、F1 设置写回的 mkxp.json、MKXP.data_directory）收到我们自己的目录下，
//  并且按 gameHash 分家。
//
//  **它不搬 RGSS 的存档文件**：Kernel#save_data 走 binding/filesystem-binding.cpp:205 的
//  `rb_file_open_str(filename, "wb")`，相对路径由 Ruby 按**进程 cwd** 解析；cwd 是游戏目录
//  （-Dworkdir_current=true 下 main.cpp 不再 chdir），实测 save_data 写出的文件落在游戏目录。
//  mkxp-z 没有把存档文件重定向到 pref 目录的开关，这里也不假装有：本文件隔离的是
//  mkxp-z 自己的每游戏数据目录（键位 / 设置 / MKXP.data_directory），不是 Save*.rxdata。
//
//  合并而不是覆盖：
//    · 用户自己的 mkxp.json（RTP / patches / 分辨率…）必须继续生效；
//    · 我们的两个键插在**第一个 `{` 之后**，因为 json5pp 用 std::map::emplace 存键，
//      **先出现的赢** —— 追加到末尾会被用户自己的 dataPathApp 顶掉。
//

import Foundation
import CryptoKit

enum MKXPZGameConfig {

    /// 与 mkxp-z 的 `#define CONF_FILE` 一致。
    static let fileName = "mkxp.json"
    /// pref 目录的第一段：把 mkxp-z 的每游戏数据收进 MochiBox 自己的目录，
    /// 不再在 `~/Library/Application Support/` 顶层按游戏标题建目录。
    static let organizationName = "MochiBox"
    private static let stateFileName = "state.json"
    private static let originalFileName = "original.bin"

    /// `mkxpz-<gameHash>`：与 `saves/<gameHash>`、`browser-profiles/<gameHash>` 同一个哈希，
    /// 同一款游戏各后端目录名一致，用户不会看到两套命名。
    static func applicationName(gameHash: String) -> String {
        return "mkxpz-\(gameHash)"
    }

    /// 一次覆盖的现场：还原所需的一切都在这里，调用方不用再记路径。
    struct Overlay: Sendable {
        let configURL: URL
        /// 覆盖前 `<gameRoot>/mkxp.json` 的原始字节；nil = 原本没有这个文件。
        let original: Data?
        /// 我们写下去的字节的 sha256：还原时用它判断"这期间有没有人改过"。
        let digest: String
        /// 崩溃恢复用的状态目录（在 AppPaths 根下，不落在用户游戏目录里）。
        let stateDirectory: URL
    }

    /// 一次 `prepare` 的结果。`note` 非空 = 没注入，原因要进会话日志。
    struct Preparation {
        let overlay: Overlay?
        let note: String?
    }

    // MARK: - 注入

    /// 在 `<gameRoot>/mkxp.json` 里注入 dataPathOrg/dataPathApp 并返回还原现场。
    ///
    /// 失败一律**不阻断启动**（返回 overlay=nil + note）：只读介质 / 只读目录里的游戏
    /// 本来就能跑 mkxp-z，为了"隔离设置目录"把游戏挡在门外是本末倒置。
    /// 但失败必须留痕 —— 调用方把 note 写进会话日志。
    static func prepare(gameRoot: URL, gameHash: String, stateRoot: URL) -> Preparation {
        let manager = FileManager.default
        let configURL = gameRoot.appendingPathComponent(fileName)
        let stateDirectory = stateRoot
            .appendingPathComponent("mkxp-overlay", isDirectory: true)
            .appendingPathComponent(gameHash, isDirectory: true)

        // 上一次没收干净（进程被 SIGKILL / 崩溃）：先按当时记下的原样还原，再重新注入。
        // 不做这一步，覆盖会一直留在用户游戏目录里，而且下一次的"原文件"就是被我们改过的版本。
        if manager.fileExists(atPath: stateDirectory.appendingPathComponent(stateFileName).path) {
            _ = restoreFromState(configURL: configURL, stateDirectory: stateDirectory)
        }

        var original: Data?
        if manager.fileExists(atPath: configURL.path) {
            guard let data = try? Data(contentsOf: configURL) else {
                return Preparation(overlay: nil, note: "读不出现有的 \(configURL.path)，本次不注入 dataPathApp/dataPathOrg")
            }
            original = data
        }

        // 没有文件 = mkxp-z 眼里的空配置（readConfFile 返回 {}）。以 "{}" 为底，
        // 合并结果就是一个只含我们两个键的对象；空文件同理。
        var text = "{}"
        if let original = original {
            guard let decoded = String(data: original, encoding: .utf8) else {
                // UTF-16 之类的配置：不猜编码、不动文件（宁可这台游戏不隔离，也不写坏它）。
                return Preparation(overlay: nil, note: "\(configURL.path) 不是 UTF-8，无法安全合并，本次不注入 dataPathApp/dataPathOrg")
            }
            text = decoded
        }

        guard let mergedText = merge(
            text: text,
            org: organizationName,
            app: applicationName(gameHash: gameHash)
        ) else {
            return Preparation(overlay: nil, note: "\(configURL.path) 的顶层不是 JSON 对象，无法安全合并，本次不注入 dataPathApp/dataPathOrg")
        }
        let merged = Data(mergedText.utf8)

        do {
            // 顺序不能换：先把"原样 + 摘要"落盘，再动用户的文件。
            // 反过来的话，写完新文件、状态还没落盘时崩溃 = 原文件永久丢失。
            try manager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            if let original = original {
                try original.write(to: stateDirectory.appendingPathComponent(originalFileName))
            }
            let state: [String: Any] = [
                "existed": original != nil,
                "mergedSHA256": sha256Hex(merged)
            ]
            let stateData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try stateData.write(to: stateDirectory.appendingPathComponent(stateFileName))
            try merged.write(to: configURL, options: .atomic)
        } catch {
            // 半成品状态必须清掉：留着它，下一次 prepare 会把一个从没生效过的备份当成"残骸"还原。
            try? manager.removeItem(at: stateDirectory)
            return Preparation(overlay: nil, note: "写不进 \(configURL.path)（\(error.localizedDescription)），本次不注入 dataPathApp/dataPathOrg")
        }

        return Preparation(
            overlay: Overlay(
                configURL: configURL,
                original: original,
                digest: sha256Hex(merged),
                stateDirectory: stateDirectory
            ),
            note: nil
        )
    }

    // MARK: - 还原

    /// 还原一次覆盖。返回非空 = 需要人看一眼的情况（已写进会话日志 / NSLog）。
    @discardableResult
    static func restore(_ overlay: Overlay) -> String? {
        let manager = FileManager.default
        var note: String?

        // 这期间文件被改过（用户手改 / 另一个实例）：仍然还原成启动前的内容 ——
        // "退出时还原"是对用户的承诺，不能因为我们认不出内容就把注入的两个键留在人家目录里。
        if let current = try? Data(contentsOf: overlay.configURL), sha256Hex(current) != overlay.digest {
            note = "\(overlay.configURL.path) 在运行期间被修改过，仍按启动前的内容还原"
        }

        if let original = overlay.original {
            do {
                try original.write(to: overlay.configURL, options: .atomic)
            } catch {
                return "还原 \(overlay.configURL.path) 失败：\(error.localizedDescription)（原文件保存在 \(overlay.stateDirectory.path)）"
            }
        } else {
            // 原本没有这个文件：删掉我们建的。删不掉就保留状态目录，下次启动还能重试。
            if manager.fileExists(atPath: overlay.configURL.path) {
                do {
                    try manager.removeItem(at: overlay.configURL)
                } catch {
                    return "删除 \(overlay.configURL.path) 失败：\(error.localizedDescription)（状态保留在 \(overlay.stateDirectory.path)）"
                }
            }
        }

        try? manager.removeItem(at: overlay.stateDirectory)
        return note
    }

    /// 按崩溃现场还原（`prepare` 在没有 Overlay 对象时用）。
    private static func restoreFromState(configURL: URL, stateDirectory: URL) -> String? {
        let manager = FileManager.default
        let stateURL = stateDirectory.appendingPathComponent(stateFileName)
        guard let stateData = try? Data(contentsOf: stateURL),
              let state = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any]
        else {
            // 状态坏了：留着备份没有意义，但也不能瞎猜原文件内容 —— 直接清掉，下一次重新注入。
            try? manager.removeItem(at: stateDirectory)
            return nil
        }

        let existed = (state["existed"] as? Bool) ?? false
        var note: String?
        if existed {
            let originalURL = stateDirectory.appendingPathComponent(originalFileName)
            if let original = try? Data(contentsOf: originalURL) {
                do {
                    try original.write(to: configURL, options: .atomic)
                } catch {
                    return "崩溃恢复失败：写不回 \(configURL.path)（\(error.localizedDescription)），备份保留在 \(stateDirectory.path)"
                }
            } else {
                note = "崩溃恢复：\(stateDirectory.path) 里少了 original.bin，未改动 \(configURL.path)"
            }
        } else if manager.fileExists(atPath: configURL.path) {
            do {
                try manager.removeItem(at: configURL)
            } catch {
                return "崩溃恢复失败：删不掉 \(configURL.path)（\(error.localizedDescription)）"
            }
        }

        try? manager.removeItem(at: stateDirectory)
        return note
    }

    // MARK: - 合并（JSON5 文本层）

    /// 在顶层对象的第一个 `{` 之后插入我们的两个键。
    ///
    /// 只做**这一件事**：不解析、不重排、不删除用户的任何内容（注释、尾逗号、单引号全留着）。
    /// 顶层不是对象（数组 / 纯标量）时返回 nil —— 那时的文件 mkxp-z 本来就会当空配置，
    /// 我们也不去改一个看不懂的文件。
    static func merge(text: String, org: String, app: String) -> String? {
        let bytes = Array(text.utf8)
        guard let brace = firstStructuralBrace(bytes) else { return nil }
        // 空对象（`{}` / 只有注释）不需要尾逗号 —— 空文件时写出来的是干净的两行，
        // 用户在游戏目录里瞄一眼也不会以为是自己写坏了。
        let emptyObject = nextSignificantByte(bytes, from: brace + 1) == 0x7D   // '}'
        let tail = emptyObject ? "" : ","
        let insertion = "\n    \"dataPathOrg\": \(quoted(org)),\n    \"dataPathApp\": \(quoted(app))\(tail)"
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + insertion.utf8.count)
        out.append(contentsOf: bytes[0...brace])
        out.append(contentsOf: Array(insertion.utf8))
        out.append(contentsOf: bytes[(brace + 1)...])
        return String(bytes: out, encoding: .utf8)
    }

    /// 第一个"结构性"的 `{`：跳过 BOM、空白、`//` 与 `/* */` 注释；
    /// 而且要求它是**第一个非平凡字符**（否则顶层就不是对象，返回 nil）。
    ///
    /// 为什么必须跳注释：真实配置的第一行就是 `// Lines starting with '//' are comments.`，
    /// mkxp-z 自带的 mkxp.json 里注释甚至提到 `{gameFolder}`。
    private static func firstStructuralBrace(_ bytes: [UInt8]) -> Int? {
        var index = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            index = 3
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {   // 空白
                index += 1
                continue
            }
            if byte == 0x2F, index + 1 < bytes.count {                          // '/'
                if bytes[index + 1] == 0x2F {                                    // 行注释
                    while index < bytes.count && bytes[index] != 0x0A { index += 1 }
                    continue
                }
                if bytes[index + 1] == 0x2A {                                    // 块注释
                    index += 2
                    while index + 1 < bytes.count,
                          !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) {
                        index += 1
                    }
                    index = min(index + 2, bytes.count)
                    continue
                }
            }
            return byte == 0x7B ? index : nil                                     // '{'
        }
        return nil
    }

    /// 从 `start` 起第一个非空白、非注释的字节（越过行注释 / 块注释）。
    private static func nextSignificantByte(_ bytes: [UInt8], from start: Int) -> UInt8? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {   // 空白
                index += 1
                continue
            }
            if byte == 0x2F, index + 1 < bytes.count {                          // '/'
                if bytes[index + 1] == 0x2F {                                    // 行注释
                    while index < bytes.count && bytes[index] != 0x0A { index += 1 }
                    continue
                }
                if bytes[index + 1] == 0x2A {                                    // 块注释
                    index += 2
                    while index + 1 < bytes.count,
                          !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) {
                        index += 1
                    }
                    index = min(index + 2, bytes.count)
                    continue
                }
            }
            return byte
        }
        return nil
    }

    /// 只用于 org/app 这种我们自己生成的短 ASCII；仍按 JSON 规则转义，免得将来有人传路径进来。
    private static func quoted(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    // MARK: - 内部

    private static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { byte in String(format: "%02x", byte) }.joined()
    }
}
