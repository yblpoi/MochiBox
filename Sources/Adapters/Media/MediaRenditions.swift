//
//  MediaRenditions.swift
//  MochiBox
//
//  按需把「带 alpha 的 WebM」（MZ 的 movies/*.mpon、*.webm）转成 HEVC-with-alpha 的 .mov，
//  让 WKWebView 真正拿到带 alpha 的帧。
//
//  为什么需要它（实测结论，别按直觉改）：
//    · WKWebView 在**解析层**就丢掉 VP9 的 alpha（Matroska BlockAdditions 里的第二平面），
//      所以 .mpon 原样喂给 <video> 得到的是不透明黑 —— canvas 四角恒为 [0,0,0,255]；
//    · 把同一份素材转成 HEVC-with-alpha 的 .mov（hvc1）后，canvas 四角是 [0,0,0,0]，
//      半透明像素也保得住（64×64 网格里约 7% 落在 0<a<255）；
//    · 三条硬约束（少一条就白干）：`-c:v libvpx-vp9` 必须在 `-i` **之前**、
//      `-alpha_quality` 默认 0 等于不编 alpha、`-vtag` 必须是 `hvc1`（`hev1` 直接不可播）。
//
//  约束：
//    · Adapters 层：只 import Foundation / Darwin —— build.sh Step 0 的 UI 门禁会拦 AppKit/SwiftUI
//      （那会连带让 --selftest / --attach 在无桌面 SSH 下起不来）；
//    · 对外只有一个**同步**方法 `rendition(for:)`：调用点在 HTTP 处理线程上，
//      阻塞它可以接受；做成 async 会把传染面推到整个静态服务；
//    · **失败一律回退**：任何 nil / 异常 / 超时都返回 nil，调用方照原样服务原始字节，
//      行为与没有本文件时完全一致 —— 宁可这一次没 alpha，也不能把请求打成 500 或空响应；
//    · **绝不写游戏目录**：产物只落在数据根下的 media-cache/。
//

import Foundation
import Darwin

/// 静态服务的「按需转码」层（线程安全；实例由 StaticWebServer 持有）。
final class MediaRenditions: @unchecked Sendable {

    /// 已经得出的结论。命中缓存后不再 spawn 任何进程。
    private enum Verdict {
        /// 没有 alpha / 探测失败 / 转码失败 —— 一律按"照原样服务"处理。
        case passthrough
        /// 已转码完成，值是可直接服务的 .mov 绝对路径。
        case rendered(String)
    }

    private let lock = NSLock()
    private let log: SessionLog?

    /// 显式注入（自测用）；nil 表示按查找顺序解析。
    private let explicitBinary: String?
    /// 显式注入缓存目录（自测用）；nil 表示用数据根下的 media-cache。
    private let explicitCacheDirectory: URL?

    // 受 lock 保护的状态
    private var binary: String?
    private var disabled = false
    private var verdicts: [String: Verdict] = [:]
    private var inFlight: Set<String> = []
    private var loggedFailures: Set<String> = []

    /// 转码串行化：同一时刻只编一个（VideoToolbox 并发编码收益很低，反而抢内存）。
    private let transcodeLock = NSLock()

    /// 缓存上限：超过就按 mtime 从旧到新删（轻量清理，只在转码成功后做一次）。
    private static let cacheLimitBytes: Int64 = 4 * 1024 * 1024 * 1024

    init(log: SessionLog? = nil, binaryPath: String? = nil, cacheDirectory: URL? = nil) {
        self.log = log
        self.explicitBinary = binaryPath
        self.explicitCacheDirectory = cacheDirectory
    }

    // MARK: - 对外唯一入口

    /// 返回"可以用来服务这个源文件"的转码产物路径；nil = 照原样服务源文件。
    ///
    /// 同步、幂等、线程安全。第一次碰到某个文件最多阻塞约 1–2s（探测 ~40ms + 转码 ~1.1s / 3s 素材）。
    func rendition(for sourcePath: String) -> String? {
        guard MediaRenditions.isCandidate(path: sourcePath) else { return nil }

        lock.lock()
        if disabled {
            lock.unlock()
            return nil
        }
        if let verdict = verdicts[sourcePath] {
            lock.unlock()
            if case .rendered(let path) = verdict {
                // 缓存被用户/清理工具删掉了就当作没有：下次请求重新转一次，而不是回 404。
                return FileManager.default.fileExists(atPath: path) ? path : nil
            }
            return nil
        }
        if inFlight.contains(sourcePath) {
            // 同一文件的并发请求（Range 分段、预览+播放）不排队等，先按原样服务；
            // 等第一个完成后，后续请求自然命中 verdicts。
            lock.unlock()
            return nil
        }
        inFlight.insert(sourcePath)
        lock.unlock()

        let result = produce(sourcePath: sourcePath)

        lock.lock()
        inFlight.remove(sourcePath)
        if let result = result {
            verdicts[sourcePath] = result
        }
        lock.unlock()
        if case .rendered(let path)? = result { return path }
        return nil
    }

    // MARK: - 生产流程

    private func produce(sourcePath: String) -> Verdict? {
        guard let binary = resolveBinary() else { return .passthrough }

        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: sourcePath),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return .passthrough
        }
        let mtime = Int64((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let key = MediaRenditions.cacheKey(sourcePath: sourcePath, size: size, mtime: mtime)
        let directory = cacheDirectory()
        let output = directory.appendingPathComponent(key + ".mov")

        if manager.fileExists(atPath: output.path) {
            return .rendered(output.path)
        }

        // 1) 探测：只读 stderr，不产出文件。**非 0 退出是正常的**（没给输出目标）。
        let probe = run(binary, ["-hide_banner", "-nostdin", "-i", sourcePath], timeout: 10)
        guard MediaRenditions.probeSaysAlpha(probe.stderr) else {
            log?.debug("MediaRenditions", "media: rendition_skip", [
                "name": (sourcePath as NSString).lastPathComponent,
                "reason": probe.timedOut ? "probe_timeout" : "no_alpha_tag"
            ])
            return .passthrough
        }

        // 2)/3) 标签只说"容器声明有 alpha"，实测 20.5% 的带标签文件 alpha 平面其实是 100% 不透明
        // （titleback.webm 就是）。再看像素：首帧 min<255 → 转；min==255 → 补 0.8×duration 一帧，
        // 仍 255 才判"纯不透明，不转"。任一步失败/超时/输出长度不对 → **退化为标签为真就转**
        // （宁可变慢，不可漏透明）。
        if let decision = alphaNeeded(binary: binary, sourcePath: sourcePath, probeStderr: probe.stderr),
           decision == false {
            log?.debug("MediaRenditions", "media: rendition_skip", [
                "name": (sourcePath as NSString).lastPathComponent,
                "reason": "tag_but_opaque"
            ])
            return .passthrough
        }

        // 2) 转码：先写 .part，成功后原子 rename —— 半成品不能被读到。
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logFailed(key: key, name: sourcePath, reason: "mkdir_failed \(error)")
            return .passthrough
        }
        let part = directory.appendingPathComponent(key + ".mov.part")
        let started = Date()
        let command = [
            "-hide_banner", "-nostdin", "-v", "error",
            // 必须是 -i 之前的输入解码器：只有 libvpx 会解 Matroska BlockAdditions 里的 alpha 平面。
            "-c:v", "libvpx-vp9",
            "-i", sourcePath,
            "-c:v", "hevc_videotoolbox", "-allow_sw", "1",
            // 默认 0 = 不编 alpha（能播但全不透明），必须显式 >0。
            "-alpha_quality", "0.75",
            // hev1 在 WKWebView 里直接 NotSupportedError，只有 hvc1 可播。
            "-vtag", "hvc1",
            "-movflags", "+faststart",
            "-c:a", "aac", "-b:a", "128k",
            // 必须显式指定容器：产物落在 *.mov.part 上，ffmpeg 靠扩展名猜格式，
            // ".part" 猜不出来会直接 "Invalid argument" 退出（实测 exit=234）。
            "-f", "mov",
            "-y", part.path
        ]

        transcodeLock.lock()
        let outcome = run(binary, command, timeout: 120)
        var wrote = false
        if outcome.status == 0, manager.fileExists(atPath: part.path) {
            do {
                try? manager.removeItem(at: output)
                try manager.moveItem(at: part, to: output)
                wrote = true
            } catch {
                try? manager.removeItem(at: part)
                logFailed(key: key, name: sourcePath, reason: "rename_failed \(error)")
            }
        } else {
            try? manager.removeItem(at: part)
            logFailed(key: key, name: sourcePath, reason: MediaRenditions.failureReason(outcome))
        }
        if wrote {
            pruneLocked(directory: directory, keeping: output)
        }
        transcodeLock.unlock()

        guard wrote else { return .passthrough }

        let outSize = (try? manager.attributesOfItem(atPath: output.path))?[.size] as? NSNumber
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        log?.info("MediaRenditions", "media: rendition", [
            "name": (sourcePath as NSString).lastPathComponent,
            "src": "\(size)",
            "out": "\(outSize?.int64Value ?? 0)",
            "sec": seconds
        ])
        return .rendered(output.path)
    }

    // MARK: - alpha 内容判定（第 2、3 步）

    /// 返回 true = 需要转码；false = 确认纯不透明、不用转；nil = 判不了（调用方按标签转）。
    private func alphaNeeded(binary: String, sourcePath: String, probeStderr: String) -> Bool? {
        guard let firstMin = minAlpha(binary: binary, sourcePath: sourcePath, seek: nil) else {
            return nil
        }
        if firstMin < 255 { return true }

        // 首帧全不透明：可能是"整片都不透明"，也可能是慢热（实测 ev07-B-02-05 / ev07-B-03-03
        // 到 0.8×duration 才出现透明）。补一帧再判。
        guard let duration = MediaRenditions.durationSeconds(fromProbe: probeStderr), duration > 0 else {
            return nil
        }
        guard let lateMin = minAlpha(binary: binary, sourcePath: sourcePath, seek: duration * 0.8) else {
            return nil
        }
        return lateMin < 255
    }

    /// 解一帧 alpha 平面并降采样到 64×64，返回最小 alpha（0–255）。解不出来返回 nil。
    private func minAlpha(binary: String, sourcePath: String, seek: Double?) -> Int? {
        var arguments = ["-hide_banner", "-nostdin", "-v", "error"]
        if let seek = seek {
            // 输入侧 seek（在 -i 之前）只跳到最近关键帧，够用且不用解码前面几百帧。
            arguments += ["-ss", String(format: "%.3f", seek)]
        }
        // 输出到临时文件而不是 stdout：自带的精简 ffmpeg **没编 pipe 协议**
        // （"Error opening output pipe:: Protocol not found"），写 `-` 会 0 字节直接失败。
        // 4KB 的临时文件换掉一个构建配置依赖，划算。
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mochibox-alpha-\(UUID().uuidString).gray")
        defer { try? FileManager.default.removeItem(at: scratch) }

        arguments += [
            // 必须在 -i 之前：只有 libvpx 会解 Matroska BlockAdditions 里的 alpha 平面。
            "-c:v", "libvpx-vp9",
            "-i", sourcePath,
            "-frames:v", "1",
            "-vf", "alphaextract,scale=64:64",
            "-f", "rawvideo", "-pix_fmt", "gray",
            "-y", scratch.path
        ]
        let outcome = run(binary, arguments, timeout: 15)
        guard !outcome.timedOut, let data = try? Data(contentsOf: scratch) else {
            return nil
        }
        return MediaRenditions.alphaFloor(fromGray: data)
    }

    // MARK: - 二进制查找

    /// 第一次调用时解析一次；找不到就永久 disabled（之后零文件 IO）。
    private func resolveBinary() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let binary = binary { return binary }
        if disabled { return nil }

        if let explicit = explicitBinary {
            if FileManager.default.isExecutableFile(atPath: explicit) {
                binary = explicit
                return explicit
            }
            disabled = true
            return nil
        }

        let environment = ProcessInfo.processInfo.environment
        let toggle = (environment["MOCHI_MEDIA_RENDITION"] ?? "").lowercased()
        if toggle == "off" || toggle == "0" || toggle == "false" {
            disabled = true
            return nil
        }

        // 顺序与 AgentInjector.loadScript() 一致：环境覆盖 → bundle 资源 → bundle 路径 → 可执行文件旁的 ../Resources。
        var candidates: [URL] = []
        if let override = environment["MOCHI_FFMPEG"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("media/ffmpeg"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/media/ffmpeg"))
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
            .deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("../Resources/media/ffmpeg").standardizedFileURL)

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            binary = candidate.path
            return candidate.path
        }
        disabled = true
        log?.debug("MediaRenditions", "media: rendition_disabled", [
            "reason": "ffmpeg_missing",
            "tried": candidates.map { $0.path }.joined(separator: " | ")
        ])
        return nil
    }

    // MARK: - 缓存目录 / 清理

    private func cacheDirectory() -> URL {
        if let explicit = explicitCacheDirectory { return explicit }
        return AppPaths.shared.root.appendingPathComponent("media-cache", isDirectory: true)
    }

    /// 超过上限就按 mtime 从旧到新删，直到低于上限（keeping 是刚写好的那个，永不删）。
    private func pruneLocked(directory: URL, keeping: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var items: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for entry in entries where entry.pathExtension == "mov" {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            items.append((entry, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > MediaRenditions.cacheLimitBytes else { return }

        for item in items.sorted(by: { $0.date < $1.date }) {
            if item.url.standardizedFileURL == keeping.standardizedFileURL { continue }
            try? manager.removeItem(at: item.url)
            total -= item.size
            if total <= MediaRenditions.cacheLimitBytes { break }
        }
    }

    // MARK: - 日志

    private func logFailed(key: String, name: String, reason: String) {
        lock.lock()
        let first = loggedFailures.insert(key).inserted
        lock.unlock()
        guard first else { return }
        log?.warn("MediaRenditions", "media: rendition_failed", [
            "name": (name as NSString).lastPathComponent,
            "reason": reason
        ])
    }

    // MARK: - 进程执行

    private struct Outcome {
        var status: Int32
        var stderr: String
        var timedOut: Bool
    }

    /// 跑子进程，且**不因管道写满而死锁**：stderr 由后台线程读干净，主线程只等退出信号。
    private func run(_ binary: String, _ arguments: [String], timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        // 退出信号必须在 run() 之前装好：装晚了子进程可能已经退出，信号永远等不到。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return Outcome(status: -1, stderr: "\(error)", timedOut: false)
        }

        let collected = NSMutableData()
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
            reader.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        _ = reader.wait(timeout: .now() + 5)
        try? pipe.fileHandleForReading.close()

        let text = String(data: collected as Data, encoding: .utf8) ?? ""
        return Outcome(status: process.terminationStatus, stderr: text, timedOut: timedOut)
    }

    private static func failureReason(_ outcome: Outcome) -> String {
        if outcome.timedOut { return "transcode_timeout" }
        let lastLine = outcome.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        return "exit=\(outcome.status)" + (lastLine.isEmpty ? "" : " \(lastLine)")
    }

    // MARK: - 纯函数（--selftest 直接调用）

    /// 只处理 `.mpon` 这一种扩展名（大小写不敏感）。其它路径**立刻**返回，不做任何 IO。
    ///
    /// 为什么**故意不含 `.webm`**（实测，别"顺手补上"）：
    /// WKWebView 的媒体层按 **URL 扩展名**选解复用器，不只看 `Content-Type`。把一个 HEVC-alpha
    /// 的 MP4 字节按 `video/mp4` 挂在以 `.webm` 结尾的 URL 上，`<video>` 直接
    /// `NotSupportedError`、readyState=0（同一份字节挂在 `.mpon` 或 `.mov` 上则正常播放）。
    /// 游戏里的 URL 是它自己拼的，我们改不了，所以 `.webm` 只能照原样服务原始字节。
    /// 本作 1415 个素材里只有 1 个 `.webm`（titleback.webm，且 alpha 平面是全不透明），
    /// 这条限制的实际代价为零。
    static func isCandidate(path: String) -> Bool {
        return (path as NSString).pathExtension.lowercased() == "mpon"
    }

    /// 缓存文件名：源路径 + 尺寸 + mtime（秒）。
    ///
    /// 带 mtime 是为了"换素材/热更新"后不复用旧产物；FNV-1a 64 足够（同一目录里的哈希碰撞
    /// 只会让两个文件抢一个缓存名，表现为多转一次，不会串画面）。
    static func cacheKey(sourcePath: String, size: Int64, mtime: Int64) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(sourcePath)|\(size)|\(mtime)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// 从 ffmpeg 的 stderr 里取时长（`Duration: 00:00:03.01`）。取不到返回 nil。
    ///
    /// 只用来定位"补一帧"的位置（0.8×duration），取不到就退化成"按标签转"，不影响正确性。
    static func durationSeconds(fromProbe stderr: String) -> Double? {
        guard let range = stderr.range(of: "Duration:\\s*([0-9]{2}):([0-9]{2}):([0-9]{2}(?:\\.[0-9]+)?)",
                                       options: .regularExpression) else { return nil }
        // 先剥掉 "Duration:" 再切冒号：直接切会切出 ["Duration", " 00", "00", "03.01"] 四段。
        let time = String(stderr[range])
            .replacingOccurrences(of: "Duration:", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = time.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return total.isFinite && total > 0 ? total : nil
    }

    /// `alphaextract + scale=64:64` 的灰度平面 → 最小 alpha。
    ///
    /// 长度必须正好 64×64（4096）：长度不对说明管道被截断或滤镜没执行，此时**不能**当成
    /// "全不透明"（那会漏掉透明），调用方拿 nil 去走保守分支。
    static func alphaFloor(fromGray data: Data) -> Int? {
        guard data.count == 64 * 64 else { return nil }
        return data.min().map { Int($0) }
    }

    /// ffmpeg 探测输出的判定：matroska 的 stream tag alpha_mode : 1，或解码出的 yuva420p。
    ///
    /// 为什么两种都认：带 alpha 的 .mpon/.webm 一定会打 tag；有些封装丢了 tag 但解码器
    /// 仍报 yuva420p。**不要**因此认为 tag 一定准 —— 实测 titleback.webm 带 tag 但 alpha
    /// 平面 100% 不透明，属于假阳性（多转一次，画面正确）。
    static func probeSaysAlpha(_ stderr: String) -> Bool {
        if stderr.range(of: "alpha_mode\\s*:\\s*1", options: .regularExpression) != nil {
            return true
        }
        return stderr.contains("yuva420p")
    }
}
