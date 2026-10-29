# QA 报告（最近一次完整基线：2026-10-24）

> **基线已过时**：本文数字全部绑在 §0 的 `dev@102e4cb` / 二进制 `dd4d2db7…` 上。其后落地的提交（V0.7 术语表、数据回写、媒体转码、对白逐行降级）**未纳入本文**；引用前先按 `docs/testing.md` 重跑并更新 §0。
>
> V0.1–V0.5 的分版报告已合并进本文，
> 原文见 git 历史（路径列表见 §5）。历史数字不再单独维护，只保留可追溯的缺陷与提交。
>
> 怎么跑测试见 `docs/testing.md`；逐需求覆盖见该文 §8 的矩阵（本文不重复整表）。

---

## 0. 适用基线

| 项 | 值 | 取法 |
|---|---|---|
| 分支 / 代码 HEAD | `dev` / `102e4cb`（CLI 未知旗标报错 + `--help`；其后仅文档提交） | `git rev-parse HEAD` |
| 产品二进制 sha256 | `dd4d2db7e127cc892d3597d94acd4613e9f22ef6d51c74ad6dd02ca1f7c317bf` | `shasum -a 256 build/MochiBox.app/Contents/MacOS/MochiBox` |
| 二进制 size / mtime | `5180768` B / `2026-10-24 10:36:18 +0800` | `stat -f '%z %Sm'` |
| 打包内 Agent sha256 | `19e4596a8d575dcfac058c50d05f962aef6bcd3491e0b8c593c05f0d197d6929` | 包内与 `Resources/agent_mvmz.js` **逐字节相同** |
| provenance | `find Sources Resources Scripts -newer <bin> -type f` → **空**（0 行） | 只证"源码不晚于二进制"，不是同源构建的充分证明 |

**已登记**：这枚二进制登记在 `Tests/qa/final-sha256-v0.6.txt` 末节
「参数校验后重基线（dev @ 102e4cb）」，含 sha256 / size / mtime / 各层实测与未验证清单；
上一枚见与它相邻的「selftest 浏览器用例 opt-in 后重基线（dev @ 0bb93e2）」。
本轮新增 `Sources/App/ArgumentValidation.swift` 并改了 `Sources/App/AppMain.swift`
（分流前的未知旗标/互斥模式校验与 `--help`），**必须重建**：
10:36 那次 `bash Scripts/build.sh`（脚本内部 `rm -rf` app bundle）产出 `dd4d2db7…`（5180768 B）。
§1 的所有数字都来自重建后的全量运行。

**二进制锚点锚的是 sha256，不是 HEAD**：HEAD 说明测试代码是哪一版（docs-only 提交也会前移 HEAD），
sha256 说明被验的是哪枚二进制。两者不是一一对应，引用数字时以 sha 为准。
另外 sha256 **只在同一 checkout 路径下可复现**（Mach-O `LC_UUID` 随路径变，跨路径必然不同），
核对基线的方法与实测见 `docs/README.md` §快照纪律。

---

## 1. 当前自动门禁

本机环境：macOS（Darwin 27.0.0，Apple Silicon），有 Aqua 登录桌面；本轮 `--suite all` 跑了两遍：
一遍不设 `MOCHI_E2E_GAME`（game 层 SKIP），一遍设 `MOCHI_E2E_GAME` 指向 `reference/test-games/` 下的真游戏。
实测时间：2026-10-24。

| 层 | 命令 | 期望 | 最近实测 |
|---|---|---|---|
| contract | `bash Tests/e2e/run.sh --suite contract` | `E2E PASS suite=contract` | `cases=14 assertions=528`，exit 0，约 10s（新增 `14_update_actor_equips` 17 条；R2/R4 的 id 三态与夹具修正） |
| domain | `bash Tests/e2e/run.sh --suite domain` | `E2E PASS suite=domain` | `cases=9 assertions=225`，exit 0，约 30s（R1 重启 LRU +2、R3 同秒隔离 +2；D9 需 Aqua，无桌面时 D9 SKIP） |
| kernel | `bash Tests/e2e/run.sh --suite kernel` | `E2E PASS suite=kernel` | `cases=12 assertions=146`，exit 0，约 22s（本轮未改内核层断言） |
| faults | `bash Tests/e2e/run.sh --suite faults` | `E2E PASS suite=faults` | `cases=10 assertions=55`，exit 0，3 次连跑 46.06s / 45.22s / 44.95s |
| game | `MOCHI_E2E_GAME=… bash Tests/e2e/run.sh --suite game` | 2 个 case 全绿 | `cases=2 assertions=11`，exit 0（G1 46.7s：`captured>0` / `translated>0`；G2 6.2s：`reason=user`）；未设环境变量时整层 SKIP |
| all | `bash Tests/e2e/run.sh --suite all` | `E2E PASS suite=all` | 设 `MOCHI_E2E_GAME`：`cases=47 assertions=965`；不设：`cases=45 assertions=954`。两者 exit 0；分层 contract 14/528、domain 9/225、kernel 12/146、faults 10/55、game 2/11 |
| 自检 | `./build/MochiBox.app/Contents/MacOS/MochiBox --selftest` | `# pass 45 fail 0 skip 1` | 45 pass / 0 fail / 1 skip，exit 0（连跑 5 次末行一致）。skip 的是 `browser_launch_and_terminate`（真要拉起 Chromium，默认不跑）；`MOCHI_SELFTEST_BROWSER=1` 时为 `# pass 46 fail 0 skip 0` |

口径说明：

- `contract` 的断言数随用例增删变化（V0.1 时代的 65 条、V0.6 快照里的 475 条都不是当前值），**以末行为准**。
- `kernel` / `faults` 需要 Aqua；无桌面时整层 SKIP，**SKIP 不得记为通过**。
- `game` 是 opt-in：`reference/` 不入库，干净 clone 上永久 SKIP（见 `docs/testing.md` §4）。

---

## 2. 需求验收状态

逐条状态（P0-01…P0-20 + AC-9.1–9.4 + AC-10.1–10.5 各自被哪一层覆盖、哪些仍手工）
**只在 `docs/testing.md` §8 的覆盖矩阵里维护**。本文只记三件不会被矩阵表达的事：

1. **自动化覆盖不等于验收通过**：`contract`/`kernel`/`faults` 证明的是协议与链路行为。
   PRD 里需要"人看到/人点到"的条目（首启合规弹窗、添加目录、设置页、字号滑杆、
   修改器面板、全文翻译面板）仍只能由 `docs/manual-acceptance.md` 记录。
2. **手工验收的现状**：截至 2026-10-23，`docs/manual-acceptance.md` §1 的
   **20 项 P0 + AC-9/AC-10 两行仍全部为"未验证"**，没有任何 `R-xxx` 记录。
   `--selftest` 通过**不能**把其中任何一项升级为"已验证"。
3. **AC-9 / AC-10 的自动化边界**：`cheat.*` 与 `text.scan*` 的协议语义在 `contract`
   有断言（含越界 id、未知方法、分段扫描、取消）；真游戏上的写入效果、全文翻译接真后端、
   导出/导入往返仍属未验证（详见 §6）。

---

## 3. 历史修复索引

> **这是本文最不可丢的部分**：每条缺陷保留它修复时绑定的 commit 或快照。
> `修复提交` 列里，`—` 表示修复发生在本仓库初始化（`f2fb0e5`）之前，
> 只在当时的 QA 快照里可考；这类条目不要试图在当前 git 历史里找到对应 commit。

### 3.1 V0.1–V0.3：协议与语言层缺陷

| 缺陷 | 一句话 | 修复提交 / 快照 | 原报告版本 |
|---|---|---|---|
| BUG-1 | 采集每帧一条（8s 66 条）→ 800ms 滑动窗口去重 | —（V0.1 终版快照 `1ca5b0c4`） | V0.1 |
| BUG-2 | 全角被误跳、符号被漏跳（码段近似 `\p{P}\p{S}`）→ NFKC + 正则 | —（`1ca5b0c4`） | V0.1 |
| BUG-3 | `"350 "` 未归一导致多一次请求与脏缓存 → `normalizeForKey` | —（`1ca5b0c4`） | V0.1 |
| BUG-4 | `Scene.pck` 同时命中 godot 与 siglus → PM 裁定规则优先级 | —（`1ca5b0c4`） | V0.1 |
| BUG-5 | `--out` 写失败静默 exit 0 → 明确 `error:` + exit 1 | —（`1ca5b0c4`） | V0.1 |
| BUG-6 | `--verbose` 空实现 → 每 case 输出 `# case … pass <ms>` | —（`1ca5b0c4`） | V0.1 |
| BUG-7 | 跳过句完全不出现在文本流 → 仍 emit，加 `status=skipped` | —（`1ca5b0c4`） | V0.1 |
| BUG-8 | 去重身份用 `mapKey`，`350` 与 `\C[2]350` 互吞 → `surface + raw` | —（`1ca5b0c4`） | V0.1 |
| BUG-9 | 跳过判据双端不一致 → 两端统一四步判据 | —（`96a87474` 上复验 6/6） | V0.1 / V0.2 |
| BUG-10 | Store 行身份仍用 `cacheKey` → `surface + U+0000 + raw`，四条写路径按 key 扇出 | —（快照 `87e5213c`） | V0.1 补遗 |
| BUG-11 | 同 `mapKey` 不同 `raw` 控制码丢失/加色 | Agent 侧：`96a87474`；Host 侧：`f49dd36` | V0.1 / V0.3 |
| BUG-12 | 5000 行淘汰后 `occurrences` 不复位 | —（`1ca5b0c4`） | V0.1 |
| V0.2-9.1 | `--browser <错路径>` 分支缺 AC-6 四要素文案 | **不可考**（V0.3 起未再复验） | V0.2 |
| V0.2-9.3 | `launcher_no_executable` 未映射到退出码 3 | **不可考**（同上） | V0.2 |

### 3.2 V0.4–V0.5：内核与欠账

| 缺陷 | 一句话 | 修复提交 / 快照 | 原报告版本 |
|---|---|---|---|
| D1 | 两处并行构造 `WKWebViewConfiguration`，配置可能漂移 | `36e95ec` | V0.4 |
| D2 | `--play` 无 `--out` 时打 `JSONL 写入失败` 并 exit 1 | `36e95ec` | V0.4 |
| D3 | `play_e2e.sh` 默认 work 目录共享 + 通配删日志，两实例互删 | `36e95ec` | V0.4 |
| D4 | 用户点红叉关窗无法自动化 → `--close-after` | `36e95ec` | V0.4 |
| D5 | `--kernel-smoke` 无 video 时隐含"autoplay 已验证" | `36e95ec` | V0.4 |
| D6 | OBS-1 的 R0/R2/R3 零探针覆盖 | `36e95ec` | V0.4 |
| D7 | `ac8_capture.sh` 全角冒号紧跟变量名，bash 3.2 下 unbound | `36e95ec` | V0.4 |
| D8 | AC-8 脚本未消费 `play: scene=` | `36e95ec` | V0.4 |

### 3.3 2026-10-23 日志排查（V0.6 之后）

| 缺陷 | 一句话 | 修复提交 | 来源 |
|---|---|---|---|
| D15 | 握手期非 `hello` 信封被 `drain()` 读走即焚，表现为 `captured=0` | `af2915d` | 会话日志排查 |
| D16 | 会话日志无轮转、无限增长 | `aeec54d` | 会话日志排查 |
| — | `hello` 解码失败漏告警，成功路径也不报 | `6ddcaa4` | 同上 |
| — | `circuitOpen` 的可重试标记与 PRD 相反 | `8f1c3d3` | 复核 |
| — | `fontScale` 落盘连带提交设置页未保存编辑 | `9eb4960` | 复核 |
| — | `fontScale` 多处数据源、滑杆抖动 | `bcb36f9` | 复核 |
| — | 编译失败复用旧二进制导致假绿 | `2b7c180` | 构建复核 |
| — | `play_e2e.sh` 前置条件与引擎签名互斥 | `885af37` | 脚本复核（随 `play_e2e.sh` 删除而失效） |

### 3.4 2026-10-23 六项缺陷修复（E2E 复核批次）

| 缺陷 | 一句话 | 修复提交 | 回归断言 |
|---|---|---|---|
| D17 / BUG-D1 | `requeue` 在整批全重复时清空去重表，同一批信封第三次重放被重新接受 | `6048d7f` | `E-14b` / `E-14c`（contract `05_envelope`） |
| D18 / BUG-D2 | `cheat.giveItem` / `setItemCount` / `updateActor` 非数字 id 静默夹到 1 | `13041c7` | `T-014-I` / `T-015-I` / `T-016-I`（contract `03_rpc_table`） |
| D19 / F-1 | 短 `sk-` 密钥（后接 <8 字符）不脱敏，明文进日志 | `e091c6e` | `D3` 短 key 4 条（domain `03_secret_mask`） |
| D20 / F-2 | `library.json` 备份名只到秒且先删后移，同秒二次损坏覆盖上一份证据 | `1abfdd8` | `D1` 同秒两次损坏 2 条（domain `01_library_persist`） |
| D21 / F-3 | 淘汰按写入时刻排序、命中不回写，实为 FIFO 而非日志所称 LRU | `eadaf0f` | `D7` LRU 2 条（domain `07_cache_capacity`） |
| D22 / F-4 | `fulltext/` 的 0700 只在首次创建生效 | `c71e68e` | `D8` 目录已存在 2 条（domain `08_fulltext_roundtrip`） |

每条都按同一流程走完：**先写新断言 → 对着旧实现跑红（`not ok` 原文留在 commit 正文）→ 改实现 → 跑绿**，
然后重建二进制、跑受影响层 + `--suite all` + `--selftest`，再单独提交。修复前后 TAP 与根因见各自
commit 正文；同一份清单（含断言 ID）在 `docs/testing.md` §7 与 `Tests/e2e/COVERAGE.md` 尾节。

改动范围：`Resources/agent_mvmz.js`（D17/D18）、`Sources/Domain/Models/ErrorModels.swift`（D19）、
`Sources/Infra/Stores.swift`（D20/D21）、`Sources/Infra/FullTextStore.swift`（D22）。
**`Scripts/build.sh` 未改**；六个 commit 之后工作树干净。

### 3.5 2026-10-24 自检门禁修复（D23 / D24）

| 缺陷 | 一句话 | 修复提交 | 回归断言 |
|---|---|---|---|
| D23 | `--selftest` 默认真拉起 Chromium（两条用例），且没有 TAP skip 口径，"没跑"与"跑过且过"分不开 | `0bb93e2` | 默认 `ok 44 - [F] browser_launch_and_terminate # SKIP …`；opt-in 时该条为 `ok` |
| D24 | 浏览器用例的异常路径（launch 返回后任一断言失败/超时/取消）不收尸；`BrowserProcessSweeper` 只扫产品根、扫不到 selftest 临时根 | `0bb93e2` | `ok 46 - [F] no_orphan_browser`（先 `pgrep` 记账再清扫，非空即 fail） |

证据：旧代码在 `launch` 后注入抛错 → 留下 6 个 Chrome 进程（红）；新代码同一注入 → pgrep 空、门禁 `ok`（绿）。
默认 `# pass 45 fail 0 skip 1`（连跑 5 次一致），`MOCHI_SELFTEST_BROWSER=1` → `# pass 46 fail 0 skip 0`。
根因与复现命令见 `docs/backlog.md` §十。

### 3.6 当前仍 OPEN（未修）

| 缺陷 | 一句话 | 状态 | 登记处 |
|---|---|---|---|
| D17–D22 | 本轮六条**已全部修掉**（见 §3.4），此表不再列产品缺陷 | CLOSED | `docs/backlog.md` §八/§九 |
| D9 | BUG-12 的诊断字段（`connected_no_output`）要先取证假阳性率 | 下一轮 | `docs/backlog.md` §三 |
| D10 | 设置页浏览器路径 / 语言对可选属功能增量，要走 PRD 变更 | 产品决策 | `docs/backlog.md` §三 |
| D11 | 20 项 P0 手工验收仍待人工逐项签 | 人工验收 | `docs/backlog.md` §三 |

复现命令与期望/实际：六条修复的完整记录见 `docs/testing.md` §7 与各 commit；D9–D11 见 `docs/backlog.md` §三
（它们不是产品缺陷或需要先做产品决策，本轮不动）。

---

## 4. 历史上被推翻的结论

| 曾经的结论 | 出处 | 当前事实 |
|---|---|---|
| "`--selftest` 29 条（或更早的 27 条）" | V0.1 / `Scripts/VERIFY.md` | **45 pass / 0 fail / 1 skip**（2026-10-24 实测；那 1 条 skip 是 default 不跑的真浏览器用例，`MOCHI_SELFTEST_BROWSER=1` 时为 46/0/0） |
| "SwiftUI `@State` 在本机编不过，写 UI 要绕开" | 早期构建记录 | `Scripts/build.sh` 自动探测能展开 `@State` 的 SDK（本机选 26.5）；`@State` 正常使用 |
| "BUG-11 未修，固化为 XFAIL" | V0.1 / V0.2 | Agent 侧 `96a87474` 修复；Host 侧 `f49dd36` 补齐；`contract` 的 C1–C9 是硬门禁 |
| "Host 去重是 16ms 帧桶" | V0.1 补遗 | 去重窗口在 **Agent 侧**：800ms 滑动窗口 + 被抑制时续期（`EMIT_DEDUPE_MS=800`）；Host `TextStreamStore` 只做同帧同身份合并，**没有**时间窗口（OBS-1，见 backlog D9） |
| "`captured=0`，握手期文本丢失是偶发环境问题" | `final-sha256-v0.6` 的 `3aeb5fe8` 节 | 是缺陷 D15；`af2915d` 修复后稳定 `captured>0` |
| "测试依赖 Chrome / Playwright / CDP" | V0.1–V0.5 各版 | 当前 E2E 链路**零外部浏览器**：`contract` 用 `node:vm`，其余用内置 WKWebView + `--control`；`--selftest` 里唯一会起 Chromium 的 F 组用例默认 SKIP（`MOCHI_SELFTEST_BROWSER=1` 才跑） |
| "V0.4 QA 报告是待填骨架" | `qa-report-v0.4.md` | 其中可执行部分已被 V0.5 的 G1–G15 取代；未闭合项转入 backlog |
| "`--selftest` 通过 = 需求已验证" | 口头口径 | `docs/manual-acceptance.md` 明确二者效力不同，不得互替 |

---

## 5. 版本化证据去哪了

以下文件已在 2026-10-23 合并进本报告并**删除工作区副本**；原文可从 git 历史取回：

```bash
git log --all --oneline -- docs/qa-report-v0.2.md   # 同理替换文件名
git show <commit>:docs/qa-report-v0.2.md
```

| 文件 | 绑定基线 |
|---|---|
| `docs/qa-report.md`（旧 V0.1 正文） | 二进制 `1ca5b0c4…`（2026-10-20 14:55 终版） |
| `docs/qa-report-v0.2.md` | `26ff093cd82f5c09…` |
| `docs/qa-report-v0.3.md` | `96a87474adb67d75…` |
| `docs/qa-report-v0.4.md` | 骨架（多数"待 QA 填"） |
| `docs/qa-report-v0.5.md` | `b178b7d1f6fbed25…`（G1–G15 全绿） |
| `docs/qa-addendum.md` | 快照 `87e5213c` / `1ca5b0c4` |
| `docs/qa-baseline-834d603d.md` | `834d603d`（二进制已被覆盖，不可复现） |

其余历史证据（不删除、只标注状态）：`docs/archive/v0.3/bug11-host-fix.md`、`docs/archive/v0.1/cdp-validation.md`、
`Scripts/VERIFY.md`（V0.1 存档）。当前锚点文件仍是 `Tests/qa/final-sha256-v0.6.txt`
（注意 §0 的"待校准"）。

---

## 6. 未覆盖 / 仅手工

搬运各版报告的"未验证"项，并标注**当前是否仍成立**：

| 项 | 来源 | 当前状态 |
|---|---|---|
| GUI 真人交互：首启弹窗、添加目录、设置页、字号滑杆、三段切换、危险操作确认 | V0.1 §5、V0.2 §10、`manual-acceptance.md` | **仍成立**（20 项 P0 全"未验证"） |
| AC-8 窗口内"肉眼看到 `◇`" | V0.4/V0.5 | **部分**：K12 断言消息窗**绘制文本**（`drawLog`）= 译文，但仍不是像素/字形/断行 |
| 真游戏上的作弊写入（AC-9） | `final-sha256-v0.6` 未验证 #2 | **仍成立**：协议层有断言，真机写入未验 |
| 全文翻译接真后端（RTT/配额/费用） | `final-sha256-v0.6` 未验证 #3 | **仍成立**：mock 链路已过 |
| `--close-after` 的用户关窗路径 | `final-sha256-v0.6` 未验证 #4 | **部分**：V0.5 的 D4 结论绑旧 sha；当前 `kernel/09_window_close` 覆盖受控关窗 |
| 断网降级（P0-17） | V0.1 §5 | **仍成立**（未测） |
| Intel / 非 arm64、真实 NW.js 版本 | V0.1 §5、V0.2 §10 | **仍成立**（只测 arm64） |
| 翻译质量（真实模型） | V0.2 §10 | **仍成立**（E2E 用 mock / passthrough） |
| 长时内存与 >10 分钟稳定性 | V0.2 §10 | **仍成立**（单次最长数分钟） |
| `autoplay=skipped(no_video)` 分支 | backlog D14 | **仍成立**：新 E2E 未覆盖该分支 |
| 窗口模式"静默假成功"（`probe.installed=true` 但整帧纯黑、无错误码）的诊断字段 | V0.3 §7.1 / backlog D9 | **仍成立**（DEFERRED：诊断信号假阳性率未取证） |
| `WKPageChannel` 内联构造 `WKUserScript`（与 D1 同形） | backlog D12 | **仍成立**（OPEN：改它会让已验证二进制整体作废） |
| 日志轮转的 50 份上限压力 | `final-sha256-v0.6` 未验证 #7 | **仍成立**（未做 >50 次会话实测） |
| 回灌的容量溢出分支、`evaluate` 超时后重放去重 | `final-sha256-v0.6` 未验证 #1/#2 | **仍成立**，且与 BUG-D1 同族 |
| 真实 MV 引擎（非 MZ）与除样本外的作品 | V0.2 §10 | **仍成立**：game 层只有 1 个样本 |
| `profile_locked` 在真实用户 profile 上的构造 | V0.3 §7.4 | **仍成立**（只用 `MOCHI_DATA_DIR` 构造） |
| `play_e2e.sh` 的 work 目录双斜杠（D13） | backlog | **随文件删除而失效** |
