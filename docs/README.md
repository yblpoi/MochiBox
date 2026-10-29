<div align="right">历史归档 → [`archive/`](archive/)</div>

# docs/ — 文档地图

当前有效 **14 份 .md**（含本索引）、**1 份 html**、`assets/` 2 张截图；
V0.1–V0.4 的历史文档与图表整齐归档在 [`archive/`](archive/)（18 个文件），不再混在根目录。

状态只有三种：`当前有效` / `历史证据（绑 <sha 或版本>）` / `存档`。

## 快照纪律（读任何验证数字前必看）

**所有验证数字必须绑定二进制 sha256。** 一句"已通过"若没有 sha，只能算声称，不能算证据。

- **sha256 的可复现范围是"同一 checkout 路径"**，不是"同一份源码"。实测：同源码在
  `/tmp/mochibox-mut` 连建两次都是 `f854adcc…`，换到 `/tmp/mochibox-mut3` 变成 `6c235519…`；
  两枚只差 116 字节，差异在 Mach-O 的 `LC_UUID`（随构建路径/链接环境变）。
  所以**跨路径核对 sha 必然不同**，那不是构建漂移，也不能据此判"二进制不一致"。
  核对基线只有两条路：① 在**原路径**干净重建后比对 sha256；
  ② 比对**可复现输入**（源码树 hash + `Resources/agent_mvmz.js` 的 hash）。
- **二进制锚点锚的是 sha256，不是 HEAD**：HEAD 只说明测试代码是哪一版；docs-only 提交会前移 HEAD
  而不改二进制，两者不是一一对应。
- **源码改动后旧结论即作废**：必须 `rm -rf build && bash Scripts/build.sh` 干净重建后再重跑探针。
- 版本由 git 管理，**不归档二进制**；别人的验证在飞时不要重建（`.app` 内的可执行文件会被删掉重建）。

## 一、当前有效

| 文件 | 职责 | 状态 |
|---|---|---|
| [README.md](README.md) | 本索引：文档分工、快照纪律、资源清单 | 当前有效 |
| [testing.md](testing.md) | **唯一测试入口**：分层模型、每层命令、fixture、控制通道、断言纪律、已知缺陷 | 当前有效 |
| [qa-report.md](qa-report.md) | **最近一次完整基线**（2026-10-24、`dev@102e4cb`）；其后的术语表 / 数据回写 / 媒体转码 / 逐行降级**未纳入** | 基线已过时 |
| [prd.md](prd.md) | 产品需求与验收标准（§3.1 为 P0 唯一验收口径，§3.4 为 AC-9/AC-10） | 当前有效 |
| [prd-changelog.md](prd-changelog.md) | PRD 口径修订流水（v0.3.4 存档 + 同日内部修订一…十二），从 `prd.md` 头部拆出 | 当前有效 |
| [architecture.md](architecture.md) | 分层与模块边界 + P0 任务分解；§5 是**全文翻译的扫描口径**（已落地，非草案） | 当前有效 |
| [architecture-v0.6-cheat-and-fulltext.md](architecture-v0.6-cheat-and-fulltext.md) | V0.6 设计契约：`rpc` / `scanChunk` 协议、作弊方法表、全文管线、AC-9/AC-10 | 当前有效 |
| [architecture-v0.7-glossary.md](architecture-v0.7-glossary.md) | V0.7 术语资产表：锁定映射、分类提示、译后校验、profile 缓存键 | 当前有效 |
| [acceptance-assertion-rules.md](acceptance-assertion-rules.md) | 验收断言怎么写、证据怎么分级（跨轮通用） | 当前有效 |
| [manual-acceptance.md](manual-acceptance.md) | 手工实测清单与运行时事实（P0 + AC-9/AC-10 多为「未验证」） | 当前有效 |
| [backlog.md](backlog.md) | 欠账登记册（**唯一登记处**，D1–D26；CLOSED 必须绑命令 + 输出 + sha/commit） | 当前有效 |
| [re-findings.md](re-findings.md) | 逆向证据档案（观测 / 推断 / 未知三分） | 当前有效 |
| [re-cheat-and-fulltext.md](re-cheat-and-fulltext.md) | V0.6 修改器 57 项与全文翻译容器的逆向证据 | 当前有效 |
| [media-compat-vp9-alpha.md](media-compat-vp9-alpha.md) | 媒体兼容：VP9-alpha 黑块与循环视频停帧的根因、修法与实测 | 当前有效 |

## 二、历史归档 [`archive/`](archive/)

归档文件里的相对链接已按新位置改写；正文提到的 `qa-report-v0.x` / `qa-addendum` 等文件
当年就已删除，只能按 git 历史取回（取法见 `qa-report.md` §5）。

| 目录 | 内容 | 状态 |
|---|---|---|
| [archive/v0.1/](archive/v0.1/) | `delivery-scope-v0.1.md`、`cdp-validation.md`（CDP 注入链路可行性）、`class-diagram.mermaid`、`sequence-diagram.mermaid` | 存档 |
| [archive/v0.2/](archive/v0.2/) | `architecture-v0.2-web-runner.md`（零 Wine、静态托管、端口确定性派生）、`delivery-scope-v0.2.md`、`handover-v0.2.md`、`web-runner-class/sequence.mermaid` | 历史证据（绑 V0.2） |
| [archive/v0.3/](archive/v0.3/) | `architecture-v0.3-fixes.md`、`handover-v0.3.md`、`bug11-host-fix.md`、`class-diagram-v0.3-fixes.mermaid`、`sequence-diagram-v0.3-fixes.mermaid` | 历史证据（绑 96a87474） |
| [archive/v0.4/](archive/v0.4/) | `architecture-v0.4-embedded-kernel.md`（`PageChannel`、失败矩阵 E1–E15、AC-8 取证）、`kernel-v0.4-class/sequence.mermaid` | 历史证据（绑 V0.4） |
| [archive/handover-2026-10-27-dialogue-line-fallback.md](archive/handover-2026-10-27-dialogue-line-fallback.md) | 对白翻译失效的根因与逐行降级修复（8778dc7）验收记录 | 已闭合 |

## 三、资源

- [assets/](assets/) — `e2e-final.png`、`e2e-translated.png`（e2e 输出截图）
- [mtool-reverse-engineering.html](mtool-reverse-engineering.html) — 逆向分析报告，浏览器直接打开

> 原 `assets/app-window.png`（3.4 MB）没有任何文档嵌入，已于 2026-10-30 移出仓库。
> 原 `archive/v0.1/` 下的两张 V0.1 基线图（`class-diagram.mermaid` / `sequence-diagram.mermaid`）同批删除，
> 现行图表以各版本架构文档里的 mermaid 块为准。

## 四、不在本目录的文档

- [../README.md](../README.md) — 面向使用者的说明（功能、三步开始、FAQ、已知限制）
- [../Scripts/VERIFY.md](../Scripts/VERIFY.md) — **V0.1 历史实测存档（2026-10-20）**，数字已被后续版本推翻
- [../Tests/qa/](../Tests/qa/) — sha 清单、控制通道冒烟、帧统计脚本，属测试资产而非文档
- 已删除的 V0.2–V0.5 分版 QA 报告：原文见 git 历史，合并结果见 `qa-report.md` §5
