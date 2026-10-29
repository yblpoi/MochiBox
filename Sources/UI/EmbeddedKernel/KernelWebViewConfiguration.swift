//
//  KernelWebViewConfiguration.swift
//  MochiBox
//
//  内核 `WKWebViewConfiguration` 的**唯一**构造入口（架构 v0.4 §3.6 的 P1 待办 / 欠账 D1）。
//
//  为什么必须只有一处：产品路径（`WKEmbeddedKernel.startOnMain`，`--play` 窗口模式与 GUI）
//  与诊断路径（`KernelSmokeMain.makeWebView`，`--kernel-smoke`）此前各自新建一份 configuration。
//  这两条配置里有两项是"窗口在、`didFinish` 成功、游戏却不动"的唯二成因：
//    1. `mediaTypesRequiringUserActionForPlayback = []`（自动播放）
//    2. `addUserScript(.atDocumentStart)` **在** `WKWebView(frame:configuration:)` **之前**
//  一旦两边并行实现漂移，`--kernel-smoke` 的 PASS 就**不能**迁移到产品路径 —— 等于给假绿
//  开了一条路。所以两处现在都由本文件产出，差异位只有一个：**注入哪些脚本**。
//
//  配置取**并集**（两条路径原来各写一份，凡是任一侧写了、且理由是"缺了就出已知故障"的
//  开关，这里全部保留。少留一条就是悄悄放宽产品路径；多留一条只是让诊断路径同样严格）：
//    · `mediaTypesRequiringUserActionForPlayback = []` —— 产品/诊断都有：缺它开场 WebM 抛
//      `NotAllowedError` → MZ `catchNormalError` → 卡在错误页。
//    · `websiteDataStore = .default()` —— 存档（MZ 走 localforage/IndexedDB）必须持久化，
//      **不要** `.nonPersistent()`；诊断路径同值才能保证 smoke 验的是同一套存储形态。
//    · `defaultWebpagePreferences.allowsContentJavaScript = true` —— 关掉 JS 内核等于空壳。
//    · `preferences.javaScriptCanOpenWindowsAutomatically = false` —— 页面不许自己开新窗口，
//      否则那条窗口既不在我们的捕获面里、也没有 Agent 注入。
//    · `suppressesIncrementalRendering = false` —— 增量渲染会让像素判据偶发抓到空白帧。
//
//  本文件属于 `Sources/UI/**`：分层门禁（`Scripts/build.sh` 的 UI gate）允许这里 import WebKit。
//

import Foundation
import WebKit

/// 内核 `WKWebViewConfiguration` / `WKUserScript` 的唯一工厂。
///
/// `@MainActor`：`WebKit` 的 configuration 与 `userContentController` 都不是 `Sendable`，
/// 把它们当主线程独占值用（真实调用点也全在主线程）比标 `@unchecked Sendable` 诚实。
@MainActor
enum KernelWebViewConfiguration {

    /// 构造内核用的 configuration，并在返回前把脚本**全部**注册好。
    ///
    /// - Parameter userScripts: 需要在 `WKWebView(frame:configuration:)` **之前**注入的脚本。
    ///   这是两条路径**唯一**允许的差异位：产品路径传 `agent_mvmz.js` 原文，
    ///   `--kernel-smoke` 传那个 4 行 marker（它存在的意义就是证明 `atDocumentStart` 真生效）。
    /// - Returns: 已完成全部配置与脚本注册的 configuration。
    ///
    /// **不变量（调用方必须遵守）**：拿到返回值之后才允许 `WKWebView(frame:configuration:)`。
    /// 脚本晚一步注入 → 首屏（标题菜单 / 开场对白）整段漏采，整轮 captured 只剩 boot 期杂字。
    static func make(userScripts: [WKUserScript]) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        // 1) 自动播放：等于 Chromium 的 `--autoplay-policy=no-user-gesture-required`。
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // 2) 持久化存储：存档要留得住，所以默认 store，不是 `.nonPersistent()`。
        configuration.websiteDataStore = .default()

        // 3) 页面 JS 必须能跑（Agent 早装的前提）。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // 4) 页面不许自己开窗口（开了就没有我们的代理与捕获）。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // 5) 增量渲染：关掉，避免像素判据抓到半帧/空白帧。
        configuration.suppressesIncrementalRendering = false

        // 早装（`Page.addScriptToEvaluateOnNewDocument` 的等价物）：
        // **必须**发生在 `WKWebView(frame:configuration:)` 之前（见文件头不变量）。
        for script in userScripts {
            configuration.userContentController.addUserScript(script)
        }
        return configuration
    }

    /// `WKUserScript(.atDocumentStart, forMainFrameOnly: true)` 的唯一构造点。
    ///
    /// 三处注入（产品 `agent_mvmz.js`、诊断 marker）都走这里：`injectionTime` 与
    /// `forMainFrameOnly` 是"早装能不能生效"的全部内容，不该由调用方各自决定。
    static func documentStartScript(_ source: String) -> WKUserScript {
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}
