//
//  GameScreenMetrics.swift
//  MochiBox
//
//  游戏窗口尺寸与标题的唯一读取点（纯文件 IO，可单测；**不碰 AppKit**）。
//
//  依据架构 v0.4 §4.3：窗口内容区点尺寸 = 游戏分辨率（`System.json → advanced.screenWidth/Height`）。
//  为什么要读它而不是写死 816×624：不同游戏分辨率不同（640×480 / 1280×720 / 自定），
//  写死会让画面被 CSS 拉伸、字发糊 —— 那正是 v0.2 用 `--window-size=1280,720` 留边距的原因。
//
//  本文件只 import Foundation（分层门禁）。
//

import Foundation

/// 游戏画面度量（`System.json` 的最小子集）。
struct GameScreenMetrics: Sendable, Equatable {
    /// 内容区宽度（点）。已夹取到 `K.kernelMinContent … K.kernelMaxContent`。
    var screenWidth: Int
    /// 内容区高度（点）。同上。
    var screenHeight: Int
    /// 窗口标题（`gameTitle`，缺失时回落目录名）。
    var title: String
    /// 是否用了回落值（`true` → 日志打 `screen_fallback=816x624`，见失败矩阵 E4）。
    var usedFallback: Bool

    /// 默认分辨率：MZ 新工程的默认值。
    static let defaultWidth: Int = 816
    static let defaultHeight: Int = 624

    /// 读取顺序（§4.3）：
    /// 1. `<root>/data/System.json`（MZ，根布局）→ `advanced.screenWidth/Height`
    /// 2. `<root>/www/data/System.json`（MV，Windows 发行版是根布局 + `www/`）
    /// 3. 上面两份都没有 `advanced` 时，读 `<www/>package.json` 的 `window.width/height`
    ///    —— NW.js/MV 发行版把真正的窗口尺寸写在这里。商业 MV 游戏常常**没有**
    ///    `System.json.advanced`（例：本机的 Magical Girl Celesphonia 是 1024×768），
    ///    只信 System.json 会退回 816×624，窗口比画布小，画面右侧/底部被直接裁掉。
    ///
    /// 解析失败 / 字段非法 / 文件不存在 → **不失败**（矩阵 E4），回落 816×624 并置
    /// `usedFallback = true`。标题回落目录名；**不剥控制码**（真游戏值是纯文本）。
    static func read(gameRoot: URL) -> GameScreenMetrics {
        let manager = FileManager.default
        let root = gameRoot.standardizedFileURL
        var metrics = GameScreenMetrics(
            screenWidth: defaultWidth,
            screenHeight: defaultHeight,
            title: root.lastPathComponent,
            usedFallback: true
        )
        var hasWidth = false
        var hasHeight = false

        let systemCandidates: [URL] = [
            root.appendingPathComponent("data/System.json"),
            root.appendingPathComponent("www/data/System.json")
        ]
        for candidate in systemCandidates {
            guard manager.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }
            if let width = value["advanced"]?["screenWidth"]?.intValue, width > 0 {
                metrics.screenWidth = clamp(width)
                hasWidth = true
            }
            if let height = value["advanced"]?["screenHeight"]?.intValue, height > 0 {
                metrics.screenHeight = clamp(height)
                hasHeight = true
            }
            if let title = value["gameTitle"]?.stringValue, !title.isEmpty {
                // 真游戏值是 `<作品窗口标题>`（纯文本）。这里不做任何改写：
                // 用户看到的窗口标题必须和游戏自己写的一致。
                metrics.title = title
            }
            break
        }

        // 兜底：NW.js 的窗口尺寸（`www/` 优先 —— root 的 package.json 可能属于外层启动器）。
        if !hasWidth || !hasHeight {
            let packageCandidates: [URL] = [
                root.appendingPathComponent("www/package.json"),
                root.appendingPathComponent("package.json")
            ]
            for candidate in packageCandidates {
                guard manager.fileExists(atPath: candidate.path),
                      let data = try? Data(contentsOf: candidate),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let window = value["window"] else {
                    continue
                }
                if !hasWidth, let width = window["width"]?.intValue, width > 0 {
                    metrics.screenWidth = clamp(width)
                    hasWidth = true
                }
                if !hasHeight, let height = window["height"]?.intValue, height > 0 {
                    metrics.screenHeight = clamp(height)
                    hasHeight = true
                }
                break
            }
        }

        // 只有两个字段**都**拿到时才算没回落；缺一项就仍然按回落记日志。
        metrics.usedFallback = !(hasWidth && hasHeight)
        return metrics
    }

    /// 夹取到合理区间：0 或 99999 之类的脏值不能变成 0 宽窗口（用户会以为"窗口没打开"）。
    static func clamp(_ value: Int) -> Int {
        return min(K.kernelMaxContent, max(K.kernelMinContent, value))
    }
}
