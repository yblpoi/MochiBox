# MochiBox V0.1 · 交付范围裁定

> 本文是交付总监（齐活林）对 `docs/prd.md`（v0.2，P0-01…P0-20）的**实际交付范围裁定**。
> 冲突时以本文为准；PRD 的验收标准不改写，只标注本轮是否交付。

## 裁定原则

1. **先能跑，再全面**：一个能编译、能启动、能attach、能采集、能回绘、自检全绿的最小闭环，胜过 20 条需求全码但一条都跑不通。
2. **凡是"证明这条路在 macOS 上成立"所必需的，一条不减**；凡是"产品化打磨"的，一律后移。
3. 被移出的需求**不删文档、不降标准**，只标注为「未交付（下一轮）」，防止下一轮重新发明。

## V0.1 交付（本轮）

| 能力 | 对应 PRD | 说明 |
|---|---|---|
| 工程骨架 + 构建 + 签名 | — | `Scripts/build.sh` → `build/MochiBox.app`，ad-hoc 签名（已实测） |
| 领域模型与协议编解码 | P0-08/P0-10 的前置 | `TextEvent`/`AgentProtocol`/`JSONValue` |
| 控制码分段 + 归一化 key | P0-09/P0-10 | `\C[n]`/`\N[n]` 保护，只翻自然语言段 |
| 引擎识别 | P0-03 | 9 类引擎 + `unknown` + 原因枚举；含 `.app/Contents/Resources/app.nw` 布局 |
| MV/MZ 启动器 | P0-05 | `Process` 直启 + `--remote-debugging-port` + 端口 39200–39300 |
| CDP 通道 | P0-06 | **browser 级端点 + attachToTarget(flatten) + sessionId**（page 级端点不可用，已实测） |
| Agent 注入与文本回绘 | P0-07/P0-08/P0-09 | `drawText`/`drawTextEx`/`Bitmap.drawText` hook，幂等、失败降级 |
| 本地缓存 | P0-10 | `cache.jsonl` 追加写 + 命中率 |
| 翻译后端 | P0-11/P0-12 | `passthrough`（默认，零联网）/ `openai` / `deepl` |
| 管线韧性 | P0-13 | 批合并 120ms、单批 60 条、并发 4、字数预算切块、重试退避、熔断 |
| 最小 UI | P0-02/P0-04/P0-14/P0-15/P0-20 | 单窗口：库列表 / 会话控制 / 四列文本流 / 设置 sheet / 首启合规 |
| `--selftest` | P0-18 | TAP，≥12 用例，无图形会话可跑，不写用户目录 |
| `--attach` CLI（新增） | — | 端到端验证入口：attach 已运行端口 → 注入 → 采集 → 翻译 → 回推 → JSONL + 截图 |
| 端到端 fixture | P0-18 的延伸 | 合成 MV 替身页面 + 零依赖 mock 翻译服务 |

## 未交付（明确后移）

| PRD | 原因 |
|---|---|
| P0-19 会话日志滚动 + 诊断导出 | 产品化能力，不阻碍验证通道 |
| P0-17 断网降级的"不崩溃"专项验证 | 依赖 P0-13 熔断；本轮只保证 passthrough 与错误码不崩 |
| P1-10 静态预翻译（L1） | 需要稳定的 CDP 通道与缓存先行；已设计，下一轮第一优先 |
| Onboarding 向导 / DetailPane / StatusBar 独立文件 / Keychain / 缓存 compaction / 设置迁移 | UI 打磨与运维能力 |
| Ren'Py 适配器、RGSS（mkxp-z / Wine）、WOLF、吉里吉里、Siglus、Unity/Godot | P1/P2，需独立一轮 |

## 已知未验证项（必须写进交付报告）

1. **未在真实 RPG Maker MV/MZ 游戏上验证**。本机无游戏样本，E2E 使用**合成替身页面**（显式标注，非真实运行时）。因此结论只能表述为"通道与管线在合成页面上跑通"，**不得**表述为"兼容 MV/MZ"。
2. 未验证 NW.js 各版本对 `--remote-debugging-port` 的一致性（本机用 Chrome for Testing 156 代替）。
3. 未验证 Apple Silicon 之外架构（构建目标仅 arm64）。
4. 未验证中文/CJK 字体在游戏内的排版溢出（P1-03/P1-07 未做）。
