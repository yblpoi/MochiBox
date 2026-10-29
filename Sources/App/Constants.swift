//
//  Constants.swift
//  MochiBox
//
//  全局常量集中定义处（端口 / 超时 / 批量 / 上限）。
//  设计依据：docs/architecture.md §7.5、§7.6；docs/prd.md §5。
//

import Foundation

/// 全工程唯一的常量表。任何模块都不得就地硬编码端口、超时、批量大小。
enum K {
    // MARK: - 版本

    /// App 版本（状态栏 / 关于页显示）。
    ///
    /// 唯一来源是 `Info.plist` 的 `CFBundleShortVersionString`：硬编码一份在 UI 里，
    /// 发版时必然忘记改（用户看到的就是"永远 v0.1.0"）。`--selftest` 这类裸二进制
    /// 没有 Info.plist，回落到这里登记的默认值。
    static var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        return "0.6.0"
    }

    // MARK: - 协议

    /// Agent 脚本版本（`window.__mochibox.version`）。
    /// v0.6：新增 `rpc` / `cheat.*` / `text.scanStart`，与 V0.5 的 v1 不兼容（旧页面需重注入）。
    static let agentVersion: Int = 3
    /// Agent ↔ Host **信封**协议版本（`agent_mvmz.js` 的 `PROTOCOL` 必须同值）。
    ///
    /// 注意它**不是** `agentVersion`：脚本能力每版都会涨，信封格式不必跟着变。
    /// 曾经 Agent 用 `VERSION` 填信封 `v`，结果 v0.6（脚本 v2）的每一条消息都被
    /// Host 当成不兼容丢掉 —— 文本流 0 句、作弊全 `rpc_timeout`。
    static let protocolVersion: Int = 1
    /// 合规模态版本（`complianceAckVersion` 需等于此值才跳过首启提示）。
    static let complianceVersion: Int = 1

    /// 段落分隔符 U+001F（送后端翻译时保留，用于段数校验）。
    static let unitSeparatorString: String = "\u{001F}"

    /// 引擎族标识：`cacheKey` 材料的第一段（`mvmz|ja|zh-Hans|…`）。
    static let engineFamily: String = "mvmz"

    // MARK: - 语言（P0 固定，不可由 UI 改写）

    /// P0 恒为 `ja → zh-Hans`（PRD v0.3 D-1 / §4.2：设置页只读展示）。
    static let fixedSrcLang: String = "ja"
    static let fixedTgtLang: String = "zh-Hans"

    // MARK: - Agent 轮询

    /// Host 用 `Runtime.evaluate` 轮询 `__mochibox.drain()` 的间隔。
    static let drainPollMs: Int = 250
    /// 单次 `drain()` 最多取出的消息条数（Agent 侧也按此上限 splice）。
    static let drainBatchLimit: Int = 50
    /// `setTranslations` 单批下发上限。
    static let setTranslationsChunk: Int = 200
    /// Agent outbox 环形上限。
    static let outboxLimit: Int = 2000
    /// Agent 页面侧译文 Map 上限。
    static let maxAgentMapSize: Int = 20000

    // MARK: - 翻译管线

    /// 新译请求合并窗口（毫秒）。
    static let batchWindowMs: Int = 120
    /// 单批上限（一次请求内最多多少条）。
    ///
    /// 20 → 60（v0.7）：每请求条数决定往返次数。旧值再被 `maxConcurrent` 二次均分，
    /// 实测每请求只有 5~10 条，1 万条要 1000~2000 次往返。
    static let maxBatch: Int = 60
    /// 并发上限（同时在飞的请求数）。
    static let maxConcurrent: Int = 4
    /// 单请求超时（秒）。实际超时另按条数放大，见 `TranslationPipeline.singleRequestTimeoutMs`。
    static let requestTimeoutSec: Int = 15
    /// 单请求输入字数上限（`item.text.count` 累加）：防止 60 条长文本撞后端上下文。
    static let batchCharBudget: Int = 4000
    /// `--attach` 的**单发**上限：它一次只等一个请求、超时仍是 15s，不能跟着 `maxBatch` 涨到 60。
    static let attachMaxBatch: Int = 20
    /// 单请求 `max_tokens`；0 = 按输入字数自动估算（见 `OpenAICompatibleProvider`）。
    static let maxOutputTokens: Int = 0
    /// 重试退避（毫秒）：0.5s / 1s / 2s。
    static let retryDelaysMs: [Int] = [500, 1000, 2000]
    /// 连续失败多少次进入熔断。
    static let circuitBreakerThreshold: Int = 5
    /// 熔断打开时长（秒）。
    static let circuitBreakerOpenSec: Double = 30
    /// 同一后端错误码在若干秒内只提示一次。
    static let errorNoticeDedupSec: Double = 60
    /// 单个块内因**段数不符**而逐条重试的最大条数。
    ///
    /// 段数漂移是模型输出抖动（实测一次全文翻译 5530 条里 0.36% 中招），
    /// 单条重发能救回大多数；但一整个块里几十条同时漂移说明这次模型整体不稳，
    /// 逐条重发只会把请求量放大，直接按失败落账更诚实。
    static let maxSegmentRetryPerChunk: Int = 8

    // MARK: - 端口

    static let debugPortLow: Int = 39200
    static let debugPortHigh: Int = 39300
    /// 端口探活重试次数。
    static let portProbeAttempts: Int = 20
    /// 本机回环地址（禁止 0.0.0.0）。
    static let loopbackHost: String = "127.0.0.1"

    // MARK: - 内置内核（v0.4，架构 v0.4 §4.3 / §6）

    /// Store 侧 800ms 滑动窗口（与 `Resources/agent_mvmz.js:510-529` 的 `EMIT_DEDUPE_MS` **同值**）。
    ///
    /// 这是**双端一致**项：改了这里必须回去对一遍 Agent，不一致时改 Store（不许改 Agent）。
    static let textStreamWindowMs: Double = 800
    /// 时钟基重置阈值（毫秒）：`delta < -60000` 视为页面 reload（`performance.now()` 归零），
    /// 按新行处理。见架构 v0.4 §6.3 R2 —— 把这种回退当"窗内"会**丢句**，比多一行难发现得多。
    static let textStreamClockResetMs: Double = 60_000
    /// 内置内核内容区最小边长（点）：脏的 `System.json` 不能变成 0 宽窗口。
    static let kernelMinContent: Int = 320
    /// 内置内核内容区最大边长（点）。
    static let kernelMaxContent: Int = 4096
    /// 内置内核的"早装"等待上限（秒）。与 Chromium 的 15s 同量级：
    /// MZ 从 boot 到画完第一屏只要 1–2s，等不到就是"这不是 RPG Maker 页面"。
    static let kernelAttachTimeoutSec: Double = 15
    /// 场景探针（矩阵 E15）里允许停留在 `Scene_Boot` 的时长（秒）。
    ///
    /// 判据**不放宽**：`Scene_Boot` 超过这个时长仍不前进就判失败（`.engineSymbolsMissing`），
    /// 只是失败文案会把 `video.readyState/paused` 一起打出来，好区分"内核没起来"与
    /// "游戏真的还在播开场影片"。为什么是 15s：MZ 从 boot 到 `Scene_Map` 实测 1–2s。
    static let kernelSceneBootGraceSec: Double = 15
    /// `--kernel-smoke` 的等待上限（秒）：等不到"场景非 none + canvas 尺寸对 + 影片在播"就失败。
    static let kernelSmokeTimeoutSec: Double = 40

    // MARK: - Web 运行后端（v0.2，架构 §3.2.8 / §4 / §5.2）

    /// 静态服务端口区间（与调试端口区间不重叠：39310–39409）。
    ///
    /// **确定性派生**：同一 `webRoot` 每次派生出同一端口。MZ 在浏览器模式下用
    /// localforage/IndexedDB 存档，存档按 **origin** 隔离 —— 端口漂移等于 `port` 变、
    /// `origin` 变、旧存档看不见（架构 §11 R2）。因此这里绝不能是随机区间。
    static let webPortLow: Int = 39310
    static let webPortHigh: Int = 39409
    /// 线性探测次数上限（= 区间大小，够绕一圈）。
    static let webPortProbeAttempts: Int = 100
    /// 端口分配持久表文件名（落在 `AppPaths.webPortsURL`）。
    static let webPortAssignmentFileName: String = "web-ports.json"
    /// 浏览器 profile 目录名（`<AppPaths.root>/browser-profiles/<gameHash>/`）。
    static let webProfileDirectoryName: String = "browser-profiles"
    /// 单次 `send` 读取的块大小（256KB）：800MB 单文件内存峰值 ≈ 块大小 × 连接数。
    static let webChunkBytes: Int = 256 * 1024
    /// 并发连接上限（超出 → 503 + close）。
    static let webMaxConcurrentConnections: Int = 32
    /// 单连接最多服务多少个请求后关闭（防长连接泄漏）。
    static let webMaxRequestsPerConnection: Int = 200
    /// keep-alive 空闲超时（秒）。
    static let webKeepAliveIdleSec: Double = 15
    /// 请求头缓冲上限（超过 → 431 + close）。
    static let webMaxHeadBytes: Int = 16 * 1024
    /// `NWListener` 就绪等待上限（秒）。
    static let webListenerReadyTimeoutSec: Double = 5
    /// 浏览器 `/json/version` 就绪等待上限（秒）。
    static let webBrowserReadyTimeoutSec: Double = 15
    /// 早装轮询间隔（毫秒）。为什么这么密：MZ 的第一屏（开场对白/标题菜单）画完
    /// 就不再 `drawText`，装晚 100ms 就可能整轮零捕获。每次只是一条 `Runtime.evaluate`。
    static let webEarlyInstallPollMs: Int = 80
    /// 浏览器 pid 文件名（落在 `<profileDir>` 里）。
    ///
    /// 为什么需要它：CLI 被 Ctrl-C / `kill -9` 时没有任何清理逻辑会跑，
    /// 浏览器就成了孤儿 —— 它继续占着调试端口、继续握着 profile 的单实例锁，
    /// 下一次启动直接 `browser_exited_early`。pid 文件是"上次是谁"的唯一线索。
    static let webBrowserPidFileName: String = ".mochibox-browser.pid"
    /// 素材（图片/音频/字体）的浏览器缓存时长（秒）；HTML/JS/JSON 走 `no-cache`。
    static let webAssetCacheMaxAgeSec: Int = 3600
    /// 目录请求的默认索引文件名。
    static let webDirectoryIndexName: String = "index.html"
    /// 浏览器窗口初始尺寸（`--window-size`）。
    static let browserWindowSize: String = "1280,720"
    /// 转义码码表版本（Swift 与 `agent_mvmz.js` 的 `ESCAPE_TABLE_VERSION` 必须同值）。
    ///
    /// v0.2 起：反斜杠后的字母按 ASCII 大写折叠后比对（MZ 自身就是大小写不敏感），
    /// 且补上 `\I[n]`。**段值不上转**（`\c[3]` 仍是 `\c[3]`），否则 `mapKey` 会跟着变。
    static let escapeTableVersion: Int = 2

    // MARK: - CDP

    /// 就绪轮询间隔（毫秒）。
    static let cdpDiscoverPollMs: Int = 250
    /// attach 总超时（秒）。
    static let cdpAttachTimeoutSec: Double = 25
    /// WebSocket 握手超时（秒）。
    static let wsHandshakeTimeoutSec: Double = 5
    /// 单次 `Runtime.evaluate` 超时（秒）。
    static let evaluateTimeoutSec: Double = 8
    /// 等待 Agent `hello` 的超时（秒）。
    static let agentHelloTimeoutSec: Double = 5
    /// `hello` 失败后的重注入次数。
    static let injectRetryCount: Int = 1
    /// 单页最大候选 target 数（避免广告页拖死 attach）。
    static let maxTargetAttempts: Int = 6

    // MARK: - 存储与展示

    /// 文本流内存上限（行）。
    static let maxTextRows: Int = 5000
    /// 缓存条目上限。
    static let maxCacheEntries: Int = 100000
    /// 每多少次命中落一次 `hitCount` 增量行。
    static let cacheHitFlushEvery: Int = 200
    /// 会话日志保留份数：会话创建时只留最近 N 份 `session-yyyyMMdd-HHmmss.log`。
    ///
    /// 为什么按**份数**而不是按单份大小（PRD P0-19 原文的「5 × 2MB」）：v0.6 起文件名
    /// 带秒级时间戳，一次启动天然是一个新文件，会无界增长的是份数；按大小切反而会在
    /// 目录里切出 `session.log.1` 这种不符合命名模式的残片。
    static let logRetentionCount: Int = 50

    // MARK: - 进程

    /// SIGTERM 到 SIGKILL 的等待（秒）。
    static let killGraceSec: Double = 3
    /// 启动失败时展示的 stderr 行数。
    static let stderrTailLines: Int = 20
    /// 纯文本最短长度（低于此长度不送翻译）。
    static let minTranslateLength: Int = 2
    /// 单批 HTTP 响应体截断长度。
    static let rawSnippetLimit: Int = 512
}
