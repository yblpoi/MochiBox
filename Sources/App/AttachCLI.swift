//
//  AttachCLI.swift
//  MochiBox
//
//  两个无图形会话下的端到端入口：
//    · `--attach <debugPort>`：附着到**已经开着**的浏览器（v0.1 行为，逐字不变）
//    · `--play <gameDir>`：走**真实产品启动路径**（解析策略 → 起静态服务 → 拉浏览器 → attach）
//
//  两个入口共用 `prepare / attachPhase / drainPhase / report` 四段：
//  drain 循环（JSONL、跳过判定、退出码语义）已经被三轮 QA 打磨过，**绝不复刻第二份**
//  —— 复制一份意味着以后修 bug 要改两处、而两处必然漂移。
//

import Foundation

enum AttachCLI {
    struct Options {
        // ── v0.1 ──
        var port: Int = 0
        var provider: String = "passthrough"
        var endpoint: String = ""
        var apiKey: String = ""
        var out: String?
        var screenshot: String?
        var duration: Double = 6
        // ── v0.2 ──
        /// 游戏目录；非 nil 时走 `runPlay`。
        var play: String? = nil
        /// 无图形会话下跑浏览器（`--headless=new --no-sandbox --disable-gpu`）。
        var headless: Bool = false
        /// 浏览器可执行文件（或 `.app`）路径。
        var browserPath: String? = nil
        // ── v0.4 ──
        /// `--kernel embedded|chromium`。`nil` = 自动：headless / `--browser` → chromium，否则 embedded。
        var kernel: WebKernelKind? = nil
        /// `--close-after <秒>`：启动成功 N 秒后**模拟用户关窗**（欠账 D4 / 矩阵 E12 的自动门禁）。
        ///
        /// `nil` = 不关（默认行为一字不变）。它只决定"窗口什么时候关"，
        /// **不改变任何判据**：退出码仍由 `captured` 决定，关窗不产生新错误码。
        var closeAfter: Double? = nil
        // ── 测试专用（v0.6 E2E）──
        /// `--control <unix socket 路径>`：开一个进程外控制通道（NDJSON，见 `ControlServer`）。
        ///
        /// **只有 `MOCHI_E2E=1` 时生效**（门禁 `enforceControlGate`）：它能在页面里跑任意 JS，
        /// 产品会话里绝不允许凭空多出这样一个入口。`nil` = 不开（默认行为一字不变）。
        var control: String? = nil
    }

    /// 一次运行里不变的东西，集中成值，避免六七个参数到处传。
    struct SessionEnv: Sendable {
        var settings: Settings
        var provider: TranslatorProvider
        var config: AgentConfig
        var collector: EnvelopeCollector
        var sessionToken: String
    }

    /// `--play` 的运行期控制块（v0.4）：让 drain 循环能在"窗口被用户关掉"时**提前收敛**。
    ///
    /// 为什么需要它：内置内核的窗口是用户能点的。用户点红叉之后若继续等满 `--duration`，
    /// 脚本要白等几分钟才拿到一个 `captured` 已经不会变的报告（矩阵 E12）。
    struct PlayControl: Sendable {
        /// 窗口关闭信号（`LaunchHandle.closed`；Chromium 路径为 nil）。
        var closeSignal: WindowCloseSignal?
        var windowNumber: Int
        var windowTitle: String
        /// `embedded` | `chromium`，只进日志。
        var kernel: String
    }

    /// 一次运行的累计结果（`--attach` 的局部变量收进这里，判定逻辑一字不改）。
    struct RunStats: Sendable {
        var captured = 0
        var translated = 0
        var skipped = 0
        var skippedReasons: [String: Int] = [:]
        var writeFailures = 0
        var attachFailed = false
        /// `--out` 打不开时的原始路径（原实现打印后立刻退出 1）。
        var outError: String? = nil
    }

    // MARK: - 参数解析

    static func parse(_ args: [String]) -> Options? {
        var options = Options()
        var hasMode = false

        if let attachIndex = args.firstIndex(of: "--attach") {
            guard attachIndex + 1 < args.count, let port = Int(args[attachIndex + 1]) else { return nil }
            options.port = port
            hasMode = true
        }
        if let playIndex = args.firstIndex(of: "--play") {
            guard playIndex + 1 < args.count else { return nil }
            let value = args[playIndex + 1]
            // `--play --headless` 这种"漏了目录"必须当参数错误，不能把 `--headless` 当目录。
            guard !value.hasPrefix("--"), !value.isEmpty else { return nil }
            options.play = value
            hasMode = true
        }
        guard hasMode else { return nil }

        func value(of flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        options.provider = value(of: "--provider") ?? "passthrough"
        options.endpoint = value(of: "--endpoint") ?? ""
        options.apiKey = value(of: "--api-key")
            ?? ProcessInfo.processInfo.environment["MOCHI_OPENAI_KEY"]
            ?? "test-key"
        options.out = value(of: "--out")
        options.screenshot = value(of: "--screenshot")
        options.headless = args.contains("--headless")
        options.browserPath = value(of: "--browser")
        if let kernelText = value(of: "--kernel") {
            // 非法值属于参数错误（退出码 2），不能静默忽略 —— 否则用户以为切了内核其实没切。
            guard let kind = WebKernelKind(rawValue: kernelText) else { return nil }
            options.kernel = kind
        }
        // `--headless` 是"没有桌面"的通道，`--kernel embedded` 是"必须在桌面上"的通道：
        // 同时给是自相矛盾的参数组合，直接 exit 2（连试都不试，避免"看起来跑通了"）。
        if options.kernel == .embedded, options.headless { return nil }
        if let durationText = value(of: "--duration") {
            if let duration = Double(durationText) {
                options.duration = max(1, duration)
            } else if options.play != nil {
                // `--play` 的 `--duration` 非数字属于参数错误（退出码 2）；
                // `--attach` 保持 v0.1 行为（忽略非法值、用默认 6s）。
                return nil
            }
        }
        if let closeAfterText = value(of: "--close-after") {
            // 非法值一律参数错误（退出码 2），**不静默忽略**：静默忽略会让用户以为
            // E12 门禁装上了，实际什么都没关（那比没有这个参数更糟）。
            guard let seconds = Double(closeAfterText), seconds.isFinite, seconds > 0 else { return nil }
            // `--attach` 没有 launcher、也没有应用内窗口，"替用户关窗"无从谈起 → 参数错误。
            guard options.play != nil else { return nil }
            options.closeAfter = seconds
        }
        if let controlIndex = args.firstIndex(of: "--control") {
            // 缺参数 / 下一个 token 是开关（`--control --headless`）→ 参数错误（退出码 2）。
            guard controlIndex + 1 < args.count else { return nil }
            let value = args[controlIndex + 1]
            guard !value.isEmpty, !value.hasPrefix("--") else { return nil }
            options.control = value
        }
        return options
    }

    static func usage() -> String {
        return "用法: MochiBox --attach <port> [--provider passthrough|openai] [--endpoint <url>] [--out <path.jsonl>] [--screenshot <path.png>] [--duration <sec>]\n"
            + "      MochiBox --play <游戏目录> [--provider passthrough|openai] [--endpoint <url>] [--api-key <k>] "
            + "[--out <path.jsonl>] [--screenshot <path.png>] [--duration <sec>] [--headless] [--browser <可执行文件路径>] "
            + "[--kernel embedded|chromium] [--close-after <秒>] [--control <socket 路径>]（--control 需 MOCHI_E2E=1）"
    }

    /// `--control` 的门禁（E2E 专用通道）：**没有 `MOCHI_E2E=1` 就 exit 2**。
    ///
    /// 为什么单独抽出来：`--play` 的窗口模式**不经过** `bootstrap`（它走
    /// `EmbeddedKernelApp.bootstrap` → `AttachCLI.run`），门禁只写在一个入口里就会被绕过。
    /// 必须在起 NSApplication / 拉浏览器**之前**拦住，否则用户会看到一个闪一下的窗口。
    static func enforceControlGate(_ args: [String]) {
        guard args.contains("--control") else { return }
        guard ProcessInfo.processInfo.environment["MOCHI_E2E"] == "1" else {
            print("error_code: control_requires_e2e")
            fflush(stdout)
            exit(2)
        }
    }

    /// 启动（阻塞；不初始化 NSApplication）。
    static func bootstrap(_ args: [String]) -> Never {
        Self.enforceControlGate(args)
        guard let options = parse(args) else {
            FileHandle.standardError.write(Data((usage() + "\n").utf8))
            exit(2)
        }
        Task.detached {
            let code = await run(options)
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }

    // MARK: - 跳过判定
    //
    // 优先采用 Agent 上报的结论（采集现场那一次判定），缺失时退回本端 `SkipRules`
    // （与产品路径同一实现），保证"跳过句不花请求"不被绕过。
    //
    // 注意：Agent 的 `skipReason` **不是**权威来源 —— 产品路径里 `status` 由 Host 的
    // `SkipRules` 决定（双端判定 Host 说了算）；这里只是因为 `--attach` 没有管线，
    // 才借用它，免得把 `350` / `\C[2]350` 送到收费接口。
    static func skipReason(of payload: AgentTextPayload, mapKey: String) -> String? {
        if let reported = payload.skipReason, !reported.isEmpty {
            return reported
        }
        if payload.status == "skipped" {
            return "skipped"
        }
        return SkipRules.skipReason(for: mapKey, enabled: true, minLength: K.minTranslateLength)
    }

    // MARK: - 入口分流

    static func run(_ options: Options) async -> Int32 {
        if options.play != nil {
            return await runPlay(options)
        }
        return await runAttach(options)
    }

    // MARK: - 四段（两个入口共用）

    /// 打印 + settings/provider/config/collector 构造。
    static func prepare(_ options: Options) -> SessionEnv {
        var settings = Settings()
        settings.backendType = (options.provider == "openai") ? .openai : .passthrough
        settings.endpoint = options.endpoint
        settings.allowSendTextToBackend = true
        let credentials = Credentials(apiKey: options.apiKey, deeplApiKey: options.apiKey)
        let provider = TranslationProviderFactory.make(settings: settings, credentials: credentials)

        let collector = EnvelopeCollector()
        let sessionToken = RandomHex.make(16)
        let config = AgentConfig(
            enabled: true,
            fontScale: 1.0,
            srcLang: settings.srcLang,
            tgtLang: settings.tgtLang,
            maxMapSize: K.maxAgentMapSize
        )
        return SessionEnv(
            settings: settings,
            provider: provider,
            config: config,
            collector: collector,
            sessionToken: sessionToken
        )
    }

    /// CDP 发现 → attach → 注入 → hello → config → 起 drain 轮询。
    ///
    /// `pid: 0` 的桩 handle 只用于"不启动、只附着"：`MVAdapter.stop()` 因此不会去 kill 任何进程。
    ///
    /// `transport` 必须由调用方如实传入：`--play` 是我们刚拉起的浏览器，页面里的
    /// `index.html` 脚本还在执行，符号探测要**允许重试**；`--attach` 附着的是别人已开好的
    /// 页面，沿用 v0.1 的一次性判定（行为零变化）。
    /// - Parameter handleOverride: 非 nil 时**直接用这个句柄**。
    ///   内置内核必须这样用：`MVAdapter.attach` 要靠 `handle.embedded.sessionKey` 找回内核，
    ///   而桩句柄里没有描述符（桩只够 CDP 用：CDP 只需要 `port`）。
    /// - Parameter sceneProbe: `true` 时在 hello 之后再判一次"游戏真的在跑"（矩阵 E15）。
    ///   **只有 `--play` 传 true**：`--attach` 附着的是别人早就开着的页面，v0.1 一次性
    ///   符号判定原样保留（team-lead 裁决：不许给 `--attach` 加场景探针）。
    /// - Returns: 场景探针的最后一次观测（`sceneProbe == false` 时为 nil）。
    ///   返回值只为控制通道的 `state` 提供 `scene` 字段，**不参与任何判定**。
    @discardableResult
    static func attachPhase(
        adapter: MVAdapter,
        port: Int,
        env: SessionEnv,
        transport: LaunchTransport = .nwjs,
        handleOverride: LaunchHandle? = nil,
        sceneProbe: Bool = false
    ) async throws -> MVAdapter.SceneActivity? {
        let handle = handleOverride ?? LaunchHandle(
            pid: 0,
            port: port,
            executableURL: URL(fileURLWithPath: "/"),
            arguments: [],
            gameRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            logURL: URL(fileURLWithPath: "/dev/null"),
            startedAt: Date(),
            transport: transport,
            web: nil
        )
        let info = try await adapter.attach(
            handle,
            sessionToken: env.sessionToken,
            config: env.config,
            onAgentMessage: { envelope in env.collector.push(envelope) },
            onStateChange: { state in print("[state] \(state.uiLabel)") }
        )
        print("attached: url=\(info.pageURL) hooks=[\(info.hooks.joined(separator: ","))] flatten=\(info.usedFlatten)")
        var scene: MVAdapter.SceneActivity? = nil
        if sceneProbe {
            scene = try await verifySceneActivity(adapter: adapter)
        }
        await adapter.startTextPump()
        return scene
    }

    // MARK: - 场景活性（矩阵 E15）

    /// hello 之后的场景判据：在宽限期内一直看不到场景、或一直停在 `Scene_Boot` 就判死。
    ///
    /// 为什么必须有这一条：MZ 的黑底黄字 Error 页**照样触发 `didFinish`**，也照样能 hello
    /// （`install()` 只要求 `Window_Base`，而错误页里全局符号其实都在）。只看导航回调或
    /// `installed=true` 就是 BUG-12 同型的假成功。
    ///
    /// **实测修正（v0.4 §5.2 E15 需更正）**：`hello` 之后**第一次**采样拿到 `scene=none` 是
    /// **正常中间态**——`hello` 在 `atDocumentStart` 装好 hook 时就来了，而 `Scene_Map` 要等
    /// MZ 的 `DataManager.setupNewGame()` 跑完（本作实测 1–2s）。所以判据是"在
    /// `kernelSceneBootGraceSec` 内看到非 `none` 的场景且不停在 `Scene_Boot`"，
    /// **不是**"第一次采样就必须非 none"。判据本身没放宽：宽限期一到还在 boot/none 就失败。
    ///
    /// 判据**不白名单场景名**（本作 97 个插件会自造 `Scene_*`）。失败码是
    /// `.engineSymbolsMissing`，**不进** `environmentCodes`（退出码 1，不是"换个环境就好"）。
    /// - Returns: 通过判据时的那一次观测（调用方只用来给控制通道的 `state.scene` 取值）。
    @discardableResult
    static func verifySceneActivity(adapter: MVAdapter) async throws -> MVAdapter.SceneActivity {
        let deadline = Date().addingTimeInterval(K.kernelSceneBootGraceSec)
        var last = MVAdapter.SceneActivity(scene: "none", video: "none/true/null")
        var lastLine = ""
        while true {
            last = try await adapter.probeSceneActivity()
            // scene 与 video 打**同一行**：这条日志的全部价值就是区分
            // "内核没起来"（scene=none 且 video=0/true）与"游戏在播影片"（Scene_Boot 且 readyState≥2）。
            let line = "play: \(last.summary)"
            if line != lastLine {
                Self.printFlush(line)
                lastLine = line
            }
            if last.scene != "none", last.scene != "Scene_Boot" {
                return last
            }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if last.scene == "none" {
            throw MochiBoxError(
                code: .engineSymbolsMissing,
                message: "\(last.summary)：\(Int(K.kernelSceneBootGraceSec))s 内 `SceneManager._scene` 一直为空"
                    + "（判据是「非 none 且不停留在 Scene_Boot」；内核已连上但游戏没跑起来）"
            )
        }
        throw MochiBoxError(
            code: .engineSymbolsMissing,
            message: "engine_symbols_missing: \(last.summary) —— scene=Scene_Boot"
                + " \(Int(K.kernelSceneBootGraceSec))s 未前进"
                + (last.videoReadyState >= 2
                    ? "（video.readyState≥2 说明影片在加载/播放，属正常等待；换游戏或加大时长复验）"
                    : "（video.readyState<2，内核可能没跑起来）")
        )
    }

    /// 轮询 drain → 批量翻译 → 写 JSONL → 下发译文。**逻辑与 v0.1 完全相同**，
    /// 只是把局部计数器收进了 `RunStats`。
    /// - Parameter live: 控制通道的实时观测面（`--control` 才会传）。本轮计数**照抄**进去，
    ///   `state` op 因此不需要（也**不允许**）自己触发一次 drain。
    static func drainPhase(
        adapter: MVAdapter,
        env: SessionEnv,
        options: Options,
        control: PlayControl? = nil,
        live: ControlLiveState? = nil
    ) async -> RunStats {
        var stats = RunStats()
        let settings = env.settings

        let writer = JSONLWriter(path: options.out)
        var translations: [String: String] = [:]
        var pushedKeys = Set<String>()
        if let out = options.out, !writer.isWritable {
            // 原实现同样在此处立刻退出 1（并且不打印 captured 行）。
            stats.outError = out
            return stats
        }
        let deadline = Date().addingTimeInterval(options.duration)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(K.drainPollMs) * 1_000_000)
            // 窗口被用户关掉 → 立刻收敛（矩阵 E12：这不是错误，但绝不允许伪造成功；
            // 退出码仍由 `report()` 按 captured 决定，所以"关窗口"永远变不出 exit 0）。
            if control?.closeSignal?.isClosed == true {
                Self.printFlush("play: window_closed=1")
                break
            }
            // 控制通道的 `quit`：与关窗同理立刻收敛（退出码由 runPlay 定成 0）。
            // `live == nil` 时这一句是死代码 —— 没开控制通道的行为一字不变。
            if live?.quitRequested == true { break }
            let envelopes = env.collector.drain()
            var payloads: [AgentTextPayload] = []
            for envelope in envelopes where envelope.type == "text" {
                if let payload = try? envelope.payload.decoded(AgentTextPayload.self) {
                    payloads.append(payload)
                }
            }
            guard !payloads.isEmpty else { continue }

            // 1) 找出未翻译的 key（去重、限批）。
            //
            // 两级 key（architecture §6.2.1）：本 CLI 不做持久化缓存，因此全程只用页面侧
            // `mapKey`（= `Segmenter.mapKey(segments)`，纯字符串）。**不用** sha256，
            // 因为 CLI 的目的是验证"通道与管线在合成页面上跑通"，不是验缓存键。
            //
            // 跳过句（P0-08/P0-09）：Agent 会照常上报，但**不得**送后端。
            // 理由优先取 Agent 上报的 `skipReason`（它就是采集现场那次判定的结论）；
            // 老版本 Agent 不带该字段时退回本端 `SkipRules`，避免静默把 `350` 送出去花钱。
            var batchKeys: [String] = []
            var batchItems: [TranslationRequestItem] = []
            for payload in payloads {
                let mapKey = Segmenter.mapKey(payload.segments)
                if Self.skipReason(of: payload, mapKey: mapKey) != nil { continue }
                if translations[mapKey] != nil { continue }
                if batchKeys.contains(mapKey) { continue }
                if batchKeys.count >= K.attachMaxBatch { continue }
                batchKeys.append(mapKey)
                batchItems.append(TranslationRequestItem(
                    key: mapKey,
                    text: payload.text,
                    segments: payload.segments
                ))
            }

            // 2) 送翻译（passthrough 直接返回原文）。
            if !batchItems.isEmpty {
                let request = TranslationRequest(
                    items: batchItems,
                    srcLang: settings.srcLang,
                    tgtLang: settings.tgtLang,
                    backend: settings.effectiveBackend,
                    timeoutMs: settings.timeoutSec * 1000,
                    requestId: UUID().uuidString
                )
                do {
                    let results = try await env.provider.translate([request])
                    if let first = results.first {
                        for item in first.items {
                            translations[item.key] = item.translatedText
                        }
                    }
                } catch {
                    print("translate failed: \(error)")
                }
            }

            // 3) 写 JSONL + 收集待下发译文。
            var pushItems: [TranslationPushItem] = []
            for payload in payloads {
                stats.captured += 1
                let mapKey = Segmenter.mapKey(payload.segments)
                let translatedText = translations[mapKey]
                let skipReason = Self.skipReason(of: payload, mapKey: mapKey)
                // `translated` 是**最终可绘制串**（转义码已回填）。passthrough 时必须留空：
                // 结果层 translatedText == text 是 PRD 要求，但写进 JSONL 的 `translated`
                // 若等于原文，读的人会以为"翻译成功"（假译文）。
                var translatedForRecord: String?
                var status = "pending"
                if let skipReason = skipReason {
                    // 跳过句：原文原样保留（`\C[2]350` 带着转义码），不写 `translated`。
                    status = "skipped"
                    stats.skipped += 1
                    stats.skippedReasons[skipReason, default: 0] += 1
                } else if let translatedText = translatedText {
                    if let reassembled = try? Segmenter.reassemble(segments: payload.segments, translatedText: translatedText) {
                        if settings.effectiveBackend == .passthrough {
                            translatedForRecord = nil
                            status = "passthrough"
                        } else {
                            translatedForRecord = reassembled
                            status = "translated"
                        }
                        stats.translated += 1
                    } else {
                        status = "segment_mismatch"
                    }
                }
                if !writer.write(
                    ts: payload.ts,
                    original: payload.raw,
                    translated: translatedForRecord,
                    status: status,
                    surface: payload.surface,
                    key: mapKey,
                    skipReason: skipReason
                ) {
                    stats.writeFailures += 1
                }
                if let translatedText = translatedText, skipReason == nil, !pushedKeys.contains(mapKey) {
                    pushedKeys.insert(mapKey)
                    if let segments = try? Segmenter.translatedSegments(segments: payload.segments, translatedText: translatedText) {
                        pushItems.append(TranslationPushItem(
                            key: mapKey,
                            translatedRaw: (try? Segmenter.reassemble(segments: payload.segments, translatedText: translatedText)) ?? payload.raw,
                            segments: segments
                        ))
                    }
                }
            }

            // 4) 下发译文（Agent 命中后重绘）。
            if !pushItems.isEmpty {
                do {
                    try await adapter.send(.setTranslations(pushItems))
                } catch {
                    print("inbox failed: \(error)")
                }
            }

            // 5) 控制通道的 `state` 读这里（只读快照，不改任何判定）。
            live?.updateCounters(
                captured: stats.captured,
                translated: stats.translated,
                skipped: stats.skipped,
                closed: control?.closeSignal?.isClosed == true
            )
        }

        writer.close()
        return stats
    }

    /// 截图（**必须在 `adapter.stop()` 之前**：stop 之后 CDP 会话已经关了）。
    static func captureScreenshotIfNeeded(adapter: MVAdapter, options: Options) async {
        guard let screenshotPath = options.screenshot else { return }
        let url = URL(fileURLWithPath: screenshotPath)
        do {
            let maybeData = try await adapter.captureScreenshotPNG()
            if let data = maybeData, !data.isEmpty {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url)
                print("screenshot: \(screenshotPath) bytes=\(data.count)")
            } else {
                print("screenshot: 未取到数据")
            }
        } catch {
            print("screenshot failed: \(error)")
        }
    }

    /// Retina 缩放比的日志写法：`2.0 → "2"`、`1.5 → "1.5"`。
    ///
    /// 为什么要省掉多余的 `.0`：AC-8 的取证脚本与文档里都写 `scale=2`，
    /// 日志里出现 `scale=2.0` 会让人以为判据变了。
    static func scaleText(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value.rounded())) }
        return String(format: "%.2f", value)
    }

    /// 打印并**立刻 flush**。
    ///
    /// 为什么必须 flush：`Scripts/ac8_capture.sh` 是**进程还活着的时候**循环 grep
    /// `play.log` 里的 `play: window_id=`（架构 v0.4 §7.3）。stdout 被重定向到文件时
    /// 是全缓冲（4–8KB），不 flush 的话这一行要等进程退出才落盘 ——
    /// 脚本会白等 30s 然后判"内核没起来"，而窗口其实好好开着（假失败）。
    static func printFlush(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// 打印 `captured=… translated=… skipped=…` 并给出退出码。
    static func report(_ stats: RunStats, env: SessionEnv, options: Options) -> Int32 {
        let reasonSummary = stats.skippedReasons.keys.sorted()
            .map { "\($0)=\(stats.skippedReasons[$0] ?? 0)" }
            .joined(separator: ",")
        print("captured=\(stats.captured) translated=\(stats.translated) skipped=\(stats.skipped)\(reasonSummary.isEmpty ? "" : " [\(reasonSummary)]")")

        // 退出码必须能反映"到底有没有跑通"：
        //   · 一条都没采到 → 失败（通道没打通）
        //   · 非 passthrough 却一条都没译出来 → 失败（后端不可用，不能以 0 退出冒充成功）
        if stats.captured == 0 { return 1 }
        if env.settings.effectiveBackend != .passthrough && stats.translated == 0 { return 1 }
        // 写证据失败不能当成功：否则"看起来跑通、实际上没有任何产物"。
        if stats.writeFailures > 0 {
            print("error: 有 \(stats.writeFailures) 行 JSONL 写入失败")
            return 1
        }
        return 0
    }

    // MARK: - `--attach`（v0.1 行为，逐字不变）

    static func runAttach(_ options: Options) async -> Int32 {
        print("attach: port=\(options.port) provider=\(options.provider) duration=\(options.duration)s")

        let env = prepare(options)
        let adapter = MVAdapter()
        do {
            try await attachPhase(adapter: adapter, port: options.port, env: env)
        } catch {
            print("attach failed: \(error)")
            return 1
        }

        let stats = await drainPhase(adapter: adapter, env: env, options: options)
        if let outError = stats.outError {
            // 与 v0.1 逐字相同：打印后立刻退出 1（也不打印 captured 行）。
            print("error: 无法写入 --out 指定的文件：\(outError)")
            return 1
        }

        await captureScreenshotIfNeeded(adapter: adapter, options: options)
        await adapter.stop()
        return report(stats, env: env, options: options)
    }

    // MARK: - `--play`（v0.2 真实产品启动路径）

    /// 环境缺口类错误码 → 退出码 3（并额外打印一行 `error_code: <raw>` 供脚本分支）。
    ///
    /// 不把这些码再拆成 3/4/5：码在 stdout 里，脚本 `grep -q 'error_code: browser_not_found'`
    /// 比记数字可靠得多。
    static let environmentCodes: Set<ErrorCode> = [
        .browserNotFound, .webRootMissing, .webServerFailed, .webPortBusy,
        .browserExitedEarly, .portUnavailable,
        // profile 单实例锁清不掉（门禁在起监听/拉浏览器之前）：
        // 漏了这条 `--play` 会掉回退出码 1、也不打 `error_code:` 行，QA 无法按码分支。
        .profileLocked,
        // `--play <非游戏目录>` 走的是启动阶段而不是 attach 阶段：漏了这条，
        // 退出码会掉回 1、也不打 `error_code:` 行，脚本没法按码分支。
        .launcherNoExecutable,
        // v0.4 内置内核（架构 v0.4 §5.3，硬约束 #4）：
        // 无 Aqua 会话 / WKWebView 起不来，两者都是"换台干净的有桌面的 Mac 可能就好"的
        // 环境缺口。漏了这两条，`--play` 会掉回 exit 1 且不打 `error_code:` 行。
        .kernelNoDesktopSession,
        .kernelLoadFailed
    ]

    static func runPlay(_ options: Options) async -> Int32 {
        guard let directoryArgument = options.play, !directoryArgument.isEmpty else { return 2 }
        let gameRoot = URL(
            fileURLWithPath: (directoryArgument as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let detection = EngineDetector.detect(gameRoot)
        print("play: root=\(gameRoot.path) engine=\(detection.engine.rawValue) provider=\(options.provider) duration=\(options.duration)s")

        let env = prepare(options)
        let launcher = GameLauncher()
        // 会话日志：`--play` 是**没有 GUI** 的入口，启动/握手/注入/场景判定全在这条路径上，
        // 早先这里传 `log: nil`，等于把整条链路的 warn/info 全部扔掉 —— 真游戏上偶发
        // `captured=0` 时手上只剩 stdout 的几行，看不出"是没走握手 drain 还是信封被丢了"。
        //
        // 落点与产品路径一致（`SessionController` 的 bootLog）：`<data>/logs/session-*.log`。
        // `AppPaths` 的根会读 `MOCHI_DATA_DIR`，因此 e2e 的日志落在 `<data>/logs/` 下，
        // 不碰用户目录。**只落文件**：`echoToStderr` 保持默认 false —— e2e 的断言读的是
        // stdout 行首格式（`play: http=` / `captured=`），多打一行就会把解析打偏。
        let paths = AppPaths.shared
        paths.ensureDirectories()
        let log = SessionLog(directory: paths.logsDirectory, sessionId: RandomHex.make(8), minLevel: .info)
        // **必须共用同一个 launcher**：内置内核登记在 launcher 的 `kernels` 表里，
        // 适配器用另一份 launcher 会拿到 nil（症状是 kernel_load_failed，看着像内核没起来）。
        let adapter = MVAdapter(launcher: launcher, log: log)
        let entry = GameEntry(
            name: gameRoot.lastPathComponent,
            path: gameRoot.path,
            engine: detection.engine,
            engineConfidence: detection.confidence,
            engineEvidence: detection.evidence,
            supportLevel: detection.supportLevel,
            reason: detection.reason
        )

        var stats = RunStats()
        var environmentCode: ErrorCode?
        var launched: LaunchHandle?
        var control: PlayControl?
        /// 控制通道（`--control`）。声明在 do 之外：**无论走哪条退出路径**都要 stop（删 socket）。
        var controlServer: ControlServer?
        var live: ControlLiveState?

        do {
            // 1) 真实产品路径：解析策略 → 起静态服务 → 拉内核/浏览器（含失败回滚）。
            let handle = try await launcher.launch(
                entry: entry,
                gameRoot: gameRoot,
                options: LaunchOptions(
                    headless: options.headless,
                    browserPathOverride: options.browserPath,
                    kernel: options.kernel,
                    // 矩阵 E15：`--play` 拉起的 web 页面（embedded / chromium）都要判场景活性。
                    requiresSceneProbe: true
                ),
                log: log
            )
            launched = handle

            switch handle.transport {
            case .embeddedKernel:
                guard let embedded = handle.embedded else {
                    await launcher.terminate(handle)
                    print("play failed: 内置内核句柄缺少描述符（transport=\(handle.transport.rawValue)）")
                    return 1
                }
                // **`play: http=` 必须永远在行首**（`Tests/e2e/play_e2e.sh:89` 用
                // `sed -n 's/^play: http=\([0-9]*\).*/\1/p'` 取端口）。新字段一律追加在行尾。
                Self.printFlush("play: http=\(embedded.httpPort) debug=0 page=\(embedded.pageURL) kernel=embedded "
                    + "content=\(embedded.screenWidth)x\(embedded.screenHeight) scale=\(Self.scaleText(embedded.backingScale))")
                // AC-8 取证入口：`NSWindow.windowNumber == CGWindowID`，可直接喂 `screencapture -l`。
                Self.printFlush("play: window_id=\(embedded.windowNumber) title=\(embedded.windowTitle)")
                control = PlayControl(
                    closeSignal: handle.closed,
                    windowNumber: embedded.windowNumber,
                    windowTitle: embedded.windowTitle,
                    kernel: "embedded"
                )
            case .webBrowser:
                guard let web = handle.web else {
                    await launcher.terminate(handle)
                    print("play failed: 启动句柄不是 Web 运行后端（transport=\(handle.transport.rawValue)）")
                    return 1
                }
                Self.printFlush("play: http=\(web.httpPort) debug=\(handle.port) page=\(web.pageURL) profile=\(web.profileDir.path) kernel=chromium")
                control = PlayControl(
                    closeSignal: handle.closed,
                    windowNumber: 0,
                    windowTitle: "",
                    kernel: "chromium"
                )
            case .nwjs:
                await launcher.terminate(handle)
                print("play failed: 启动句柄不是 Web 运行后端（transport=\(handle.transport.rawValue)）")
                return 1
            }

            // 2) `--close-after`：替用户按下关闭按钮（欠账 D4 / 矩阵 E12）。
            //
            //    放在这里（启动成功 + `control` 就绪之后、attach 之前）是为了让"到点关窗"
            //    与采集并行：E12 的真实形态就是"用户在看的过程中把窗口关了"。
            //    这个 Task **只**关窗：
            //      · 不改退出码（仍由 `report()` 按 captured 决定，关窗永远变不出 exit 0）；
            //      · 不新增错误码、不新增 `environmentCodes`；
            //      · 收资源仍由下面的 `adapter.stop()` / `launcher.terminate()` 负责。
            if let closeAfter = options.closeAfter {
                let transportName = handle.transport.rawValue
                let hasAppWindow = (handle.embedded != nil)
                Self.printFlush("play: close_after=\(Self.scaleText(closeAfter))s kernel=\(transportName)")
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64((closeAfter * 1_000_000_000).rounded()))
                    Self.printFlush("play: close_after=\(Self.scaleText(closeAfter))s fired=1")
                    if !hasAppWindow {
                        // Chromium / nwjs 没有应用内窗口：空操作并说明，不假装关了窗。
                        Self.printFlush("play: close_after skipped kernel=\(transportName) reason=no_app_window"
                            + "（Chromium 路径没有应用内窗口，--close-after 为空操作）")
                        return
                    }
                    await launcher.simulateUserClose(handle)
                    // 取证：把 `WindowCloseSignal` 记下的 reason 打到 stdout。
                    // **必须是 stdout**：脚本读的是进程输出，不是会话日志文件
                    // （`--play` 现在也有 `SessionLog` 了，但它的路径随 `MOCHI_DATA_DIR` 变，
                    //  e2e 的断言不该为此去猜目录）。日志文件是补充取证，不是判据。
                    // `reason=user` 才是 E12（用户点红叉）走到了；`programmatic` 说明实现退回了
                    // `closeWindow()`，门禁等于没装 —— 这一行就是分辨两者的唯一凭据。
                    var waited: Double = 0
                    while waited < 2 {
                        if let reason = handle.closed?.reason, !reason.isEmpty {
                            Self.printFlush("play: close_after=\(Self.scaleText(closeAfter))s"
                                + " closed=1 reason=\(reason)")
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        waited += 0.05
                    }
                    Self.printFlush("play: close_after=\(Self.scaleText(closeAfter))s"
                        + " closed=0 reason=timeout（关窗信号 2s 内没到：内核没收到 windowWillClose）")
                }
            }

            // 3) 交给既有 attach 链路（**完全不变**；只是把真实句柄传进去）。
            //    `sceneProbe: true` 只对 web 后端有意义（`.nwjs` 分支前面已经 return 了）。
            let scene = try await attachPhase(
                adapter: adapter,
                port: handle.port,
                env: env,
                transport: handle.transport,
                handleOverride: handle,
                sceneProbe: handle.requiresSceneProbe
            )

            // 3.5) 控制通道（测试专用）。**只在 attach 成功之后**开：之前的会话还没有
            //      `PageChannel`，`eval` 无从谈起。起不来只打一行、不打断主流程。
            if let socketPath = options.control {
                let liveState = ControlLiveState(kernel: control?.kernel ?? "embedded")
                liveState.setScene(scene?.scene)
                live = liveState
                let server = ControlServer(
                    path: socketPath,
                    live: liveState,
                    handlers: ControlServer.Handlers(
                        eval: { expression, timeout in
                            try await adapter.controlEvaluate(expression, timeout: timeout)
                        },
                        close: {
                            // 与 `--close-after` **同一实现**：E12 验的就是产品那条路径。
                            await launcher.simulateUserClose(handle)
                        }
                    )
                )
                do {
                    try server.start()
                    controlServer = server
                    Self.printFlush("play: control=ready path=\(socketPath) kernel=\(liveState.current.kernel)")
                } catch {
                    let reason = (error as? MochiBoxError)?.message ?? "\(error)"
                    Self.printFlush("play: control=disabled reason=\(reason)")
                }
            }

            // 4) 采集/翻译/回绘（`--close-after` 到点后由 drain 里的
            //    `closeSignal.isClosed` 立刻收敛并打 `play: window_closed=1`）。
            stats = await drainPhase(
                adapter: adapter,
                env: env,
                options: options,
                control: control,
                live: live
            )
        } catch let error as MochiBoxError {
            if Self.environmentCodes.contains(error.code) {
                environmentCode = error.code
                print("error_code: \(error.code.rawValue)")
                print("play failed: \(error.message)")
            } else {
                stats.attachFailed = true
                print("play failed: \(error)")
            }
        } catch {
            stats.attachFailed = true
            print("play failed: \(error)")
        }

        // 控制通道先收（停监听 + 删 socket 文件）：下面的收尾不该再有新请求进来，
        // 也保证进程退出后 /tmp 里不留残骸。失败/异常路径同样要走到这里。
        controlServer?.stop()

        // 4) 收资源：probe（在 stop 之前取）→ 截图（在 stop 之前）→ adapter.stop() → launcher.terminate()。
        //
        // 这里**不用** `defer { Task { await launcher.terminate(handle) } }`：
        // `defer` 里起 Task 不保证在进程退出前跑完，典型症状是"attach 失败后浏览器还开着、
        // 端口还被占"，下一次直接假 `web_port_busy`。所以每条路径都显式 await。
        if !stats.attachFailed, environmentCode == nil, stats.outError == nil {
            if let probe = await adapter.agentProbeJSON() {
                print("play: probe=\(probe)")
            }
            await captureScreenshotIfNeeded(adapter: adapter, options: options)
        }
        await adapter.stop()
        if let launched = launched {
            await launcher.terminate(launched)
        }

        if let outError = stats.outError {
            print("error: 无法写入 --out 指定的文件：\(outError)")
            return 1
        }
        if let code = environmentCode {
            print("play: environment=\(code.rawValue)")
            return 3
        }
        // `quit` 是驱动端主动收工（不是失败）：照常打 report 行给出证据，但退出码固定 0。
        if live?.quitRequested == true {
            _ = report(stats, env: env, options: options)
            return 0
        }
        return report(stats, env: env, options: options)
    }
}

// MARK: - 线程安全收集器

final class EnvelopeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [AgentEnvelope] = []

    func push(_ envelope: AgentEnvelope) {
        lock.lock()
        buffer.append(envelope)
        if buffer.count > 5000 {
            buffer.removeFirst(buffer.count - 5000)
        }
        lock.unlock()
    }

    func drain() -> [AgentEnvelope] {
        lock.lock()
        let items = buffer
        buffer.removeAll()
        lock.unlock()
        return items
    }
}

// MARK: - JSONL 写入

/// JSONL 追加写入器。
///
/// **失败必须可见**：早期版本用 `guard let handle else { return }` + `try?`，
/// `--out /System/...` 这类无权限路径会跑完全程、打印 `captured=N`、以 0 退出，
/// 而文件根本不存在 —— 验证入口产出"看起来成功、实际没有证据"。现在每次写返回 `Bool`，
/// 由调用方累计失败数并让退出码变成非 0。
///
/// **但"没要求写文件"不是失败**（欠账 D2 / 架构 §11 D-5）：`init(path: nil)` 把
/// `isWritable` 设成 true（未要求写文件，不算失败），而 `write()` 里
/// `guard let handle else { return false }` 却把"本来就不写"记成"写失败" ——
/// `--play` 不带 `--out` 时会因此打出 `error: 有 1 行 JSONL 写入失败` 并 exit 1。
/// 现在用 `wantsFile` 把两种形态分开：
///   · `wantsFile == false`（`path` 为空）→ `write()` 返回 **true**（什么都没要求，就没有失败）；
///   · `wantsFile == true` 却没有句柄 → 返回 **false**（要求写但写不了，必须计失败）。
final class JSONLWriter {
    private let handle: FileHandle?
    /// 调用方**是否要求**落文件（`path` 非空即 true）。区分"不需要写"与"写失败"的唯一依据。
    private let wantsFile: Bool
    private(set) var isWritable: Bool
    private(set) var lastError: String = ""

    init(path: String?) {
        guard let path = path, !path.isEmpty else {
            self.handle = nil
            self.wantsFile = false
            self.isWritable = true          // 未要求写文件，不算失败
            return
        }
        self.wantsFile = true
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                self.handle = nil
                self.isWritable = false
                self.lastError = "createFile 失败：\(path)"
                return
            }
            self.handle = FileHandle(forWritingAtPath: url.path)
            self.isWritable = (self.handle != nil)
            if self.handle == nil { self.lastError = "无法打开写入句柄：\(path)" }
        } catch {
            self.handle = nil
            self.isWritable = false
            self.lastError = "\(error)"
        }
    }

    /// 写一行。返回值语义（**三条返回路径逐条对齐，别只改一条**）：
    ///   · 没要求写文件、也没有句柄 → `true`（不写不是错）；
    ///   · 要求写却没句柄 / 序列化失败 / 写盘抛错 → `false`（这些都是真失败）。
    @discardableResult
    func write(
        ts: Double,
        original: String,
        translated: String?,
        status: String,
        surface: String,
        key: String,
        skipReason: String? = nil
    ) -> Bool {
        guard let handle = handle else { return !wantsFile }
        var payload: [String: Any] = [
            "ts": ts,
            "original": original,
            "status": status,
            "surface": surface,
            "key": key
        ]
        // passthrough / pending / skipped / segment_mismatch：没有可绘制的译文，字段不写
        // （读取方按"缺失或 null"判断"未翻译"）。写成原文会制造"假译文"。
        if let translated = translated {
            payload["translated"] = translated
        }
        if let skipReason = skipReason {
            payload["skipReason"] = skipReason
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            lastError = "JSON 序列化失败"
            return false
        }
        var line = data
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    /// 收尾。**返回 `Void`**（不参与失败计数）：没有句柄时 `synchronize()/close()` 都是 `nil`，
    /// `try?` 吞掉即可 —— "没要求写文件"在这里同样不是失败，因此不提供 `Bool` 返回值，
    /// 免得再长出一条与 `write()` 不一致的失败语义。
    func close() {
        try? handle?.synchronize()
        try? handle?.close()
    }
}
