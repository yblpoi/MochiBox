# 欠账登记册（Backlog）

> **这份文件是唯一登记处。** 以前欠账散在 `archive/v0.3/handover-v0.3.md §10`、`archive/v0.4/architecture-v0.4-embedded-kernel.md §3.6/§10/§11`、
> `qa-report-v0.4.md §3` 和当日记忆里，读者要拼三份文档才知道"到底还欠什么"。从本轮起：**新增欠账只写这里**，
> 对应版本的设计/验收文档只保留"为什么这么做"的论述，不再各自维护待办列表。
>
> **状态只有五种**：`OPEN`（认账、没动）/ `DOING`（本轮在做）/ `CLOSED`（有证据还清）/ `DEFERRED`（本轮不做，写明归谁/为什么）/ `OBSOLETE`（目标本身已随代码删除而消失，无需也无法再还，写明失效它的 commit）。
> **"CLOSED" 的硬条件**：一条可复现命令 + 关键输出 + 它跑的那枚二进制 sha256。没有证据的"已修复"一律按 `OPEN` 处理。

- 建立：2026-10-22 13:25（GMT+8）
- 基线：`b549206`（tag `v0.4.0`），验证产物 `c5de5a5e…`（`docs/qa-report-v0.4.md`）
- 本轮目标：把 `OPEN` 里**能自动验证**的六项收口（D1–D6）；需要产品决策或人工点测的显式留给下一轮

---

## 一、本轮收口（D1–D6）

| ID | 来源 | 欠的是什么 | 判据（机器可判） | 状态 |
|---|---|---|---|---|
| **D1** | `architecture-v0.4 §3.6`（架构师明令"下一轮第一件事"） | 仓里**两处**构造 `WKWebViewConfiguration`（产品 `WKEmbeddedKernel` / 诊断 `KernelSmokeMain`）。配置一旦漂移，`--kernel-smoke` 的 PASS 不能迁移到产品路径 | 全仓 `WKWebViewConfiguration()` 构造点 **= 1**（工厂内），`grep -rn "WKWebViewConfiguration()" Sources` 只命中工厂；`--kernel-smoke` 仍 PASS | `CLOSED`（G5/G6） |
| **D2** | `architecture-v0.4 §11 D-5` / `qa-report-v0.4 §3.4` | `--play` **不带 `--out`** 时结尾打 `error: 有 1 行 JSONL 写入失败` 并 exit 1（`JSONLWriter.init(path:nil)` 声明可写，`write()` 的 `guard let handle else { return false }` 被计成失败） | `--play --headless --duration 8`（无 `--out`）→ 输出**无** `JSONL 写入失败`；退出码只由 `captured` 决定 | `CLOSED`（G7/G8） |
| **D3** | `qa-report-v0.4 §3.6` | `play_e2e.sh` 默认 `MOCHI_E2E_WORK=/tmp/mochibox-e2e` + 开头 `rm -f "$LOG_DIR"/*.log` → 两个实例互删日志，制造假失败 | 默认 work 目录按进程唯一；端口/端口占用时 **exit 2 + 明确文案**，不再表现为红用例 | `CLOSED`（G9） |
| **D4** | `qa-report-v0.4 §3.5` + 当日记忆"下一轮第一优先" | E12（用户点红叉关窗）需 TCC 辅助功能权限，`osascript` 返回 `-10004` → 永远只能人工。缺一个自关闭入口把它变成自动门禁 | `--play --close-after <s>` → 到点打 `play: window_closed=1`，日志 `reason=user`，进程提前结束且**退出码仍按 captured**（不伪造 exit 0） | `CLOSED`（G10/G11） |
| **D5** | `qa-report-v0.4 §3.1` | `--kernel-smoke` 在 `video == "absent"` 时直接 `return true`：没验 autoplay 也算 PASS，属**判据偏软**（盲区未被声明） | 输出显式区分 `autoplay=verified` / `autoplay=skipped(no video)`；无 video 时不得再隐含"自动播放已验证" | `CLOSED`（G6，见 §五） |
| **D6** | 当日记忆 v0.4 | OBS-1 的 R0（`ts` 不可用 → 同帧签名退化）与 R2（回拨 >60s → reload）**零探针覆盖**；R3（小幅回拨）同样没有断言 | `store_probe` 新增 R0/R2/R3 断言并全绿；既有 21 条断言期望值**一个不动** | `CLOSED`（G2） |

---

## 二、已还清，只等复核（D7–D8）

| ID | 来源 | 内容 | 复核方式 | 状态 |
|---|---|---|---|---|
| **D7** | `architecture-v0.4 §11 D-6` | `ac8_capture.sh` 里「变量名紧跟全角冒号」的 bash 3.2 陷阱（`$i：` → `i?: unbound variable`，脚本在抓帧前就死） | `grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' Scripts/ac8_capture.sh` 只命中注释 | `CLOSED`（G13 全跑通） |
| **D8** | `qa-report-v0.4 §3.3` | AC-8 脚本未消费 `play: scene=`，判据 2 无人执行 | 脚本判据 6 → 9 条，`scene` 已作为判据 9；v0.4 定稿轮 9/9 | `CLOSED`（G13 `scene=Scene_Map:1`） |

---

## 三、本轮不做，写明归谁（D9–D11）

| ID | 内容 | 为什么不做 | 归谁 |
|---|---|---|---|
| **D9** | BUG-12「窗口模式静默假成功」的诊断字段（`diagnosis: connected_no_output`） | `architecture-v0.4 §5.7 / R14` 已裁定：**诊断信号本身环境相关、假阳性率未取证**，且形态只能是不参与判定的诊断行。要做得先取证假阳性率，不是写十行代码的事。本轮不碰输出契约 | 下一轮，先做假阳性取证 |
| **D10** | `Settings.browserPath` 进设置页；语言对可选（PRD D-1 冻结 `ja→zh-Hans`） | 属**功能增量**，不是欠账修复；语言对还会改产品语义（中文游戏变成"什么都不翻"），要走 PRD 变更 | 产品（许清楚）→ 架构 → 工程 |
| **D11** | `manual-acceptance.md` 20 项 P0 手工验收仍全"未验证" | 需要真实 GUI 点测（20 项，含首次启动、添加目录、设置持久化等），本轮是命令行欠账收口 | 人工验收（按该文档逐项签） |

---

## 四、判据口径（避免下一轮重新发明）

1. **不许改既有验收语义**：`--play` 退出码（`captured==0 → 1`）、`status` 取值、`play: http=` 行首格式、`probe` 字段名，全部冻结。
2. **新增输出只能追加**：新字段一律加在行尾或独立新行，不动既有字段顺序（`play_e2e.sh:89` 用 `sed` 取端口）。
3. **"源码不晚于二进制"≠"二进制由这份源码构建"**：措辞只说前者（必要条件，不是充分条件）。
4. **验证只能有一个执行者**：`build.sh` 会 `rm -rf build`；别人的验证在飞时禁止重建。清理进程只许按本次 `--out` 精确匹配，禁止 `pkill -f "MochiBox --play"` / `pkill -x MochiBox`。
5. **每个验证通过的时点必须先提交源码**：`build/` 只留最新一次构建，版本由 git 管理，二进制 sha 会随重建漂移。

---

## 五、v0.5 证据（只有这一节里的数字算"已还清"）

- 被测二进制：`b178b7d1f6fbed258d26a7aec9a9b7551adf5cc3ffdb41c1ca62201b8db8ba4c`（`2592720` B，`2026-10-22 13:42:25 +0800`）
- 打包内 agent：`842a3c0b…`（与 `Resources/agent_mvmz.js` 逐字节相同，本轮零改动）
- provenance：`find Sources Resources Scripts -newer <bin> -type f` **为空**（措辞只到"源码不晚于二进制"，不升级为"同源构建"）
- 完整报告：`docs/qa-report-v0.5.md`（G1–G15，**15/15 PASS**，`ROUTING: NoOne`；该文件 2026-10-23 已并入 `qa-report.md` 并删除，原文按 `git show <commit>:docs/qa-report-v0.5.md` 取回）

| ID | 关键实测（全部来自 QA 独立复跑，非工程师自测转述） |
|---|---|
| D1 | `WKWebViewConfiguration()` 全仓 **1 处**（工厂 `KernelWebViewConfiguration.swift:49`）；`--kernel-smoke` → `smoke: PASS scene=Scene_Map canvas=816x624 startup_script=documentStart`，exit 0 |
| D2 | 无 `--out`：`captured=1` → **exit 0**、`JSONL 写入失败` **0 条**；反向对照 `--out /tmp` → **exit 1** + `无法写入 --out 指定的文件`（证明是"区分"不是"放宽"） |
| D3 | 占住 8789 → `play_e2e.sh` **exit 2** + 三行明确文案；两次调用生成两个不同 `mktemp -d` 目录（`mochibox-e2e.MDkpcr` / `mochibox-e2e.Ygqc6o`） |
| D4 | `--close-after 20` + `--duration 120` → **22s 结束**、`play: window_closed=1`、`closed=1 reason=user`、exit 由 `captured=1` 决定；`--close-after abc` / `--close-after 0` / `--attach` 同用 **均 exit 2** |
| D5 | 真游戏 → `autoplay=verified`；合成无 video 页 → `autoplay=skipped(no_video)` 且 exit 0（后者为**工程师自测**，QA 只复验了真游戏分支，见 §六 D14） |
| D6 | `store_probe` **25/0**；R0a/R0b/R2/R3 逐条 PASS；`--numstat = 63 0`（只增不删，既有 21 条期望值零改动） |
| D7/D8 | AC-8 脚本 9 条判据全中、exit 0：`translated=3` / `jsonl_diamond=3` / `replaced=3` / `error_codes=0` / `distinct=883` / `kernel=embedded` / `content=816x624` / `title` 非空 / `scene=Scene_Map` |

**回归面同时成立**：`--selftest` 45/0、`skip_parity` 9/9、`lookup_variant`（打包内 js）9/9、全量 E2E `pass 11 fail 0` + `PLAY_E2E_PASS`（AC-2 `captured=4`、AC-3 `translated=3 replaced=3`、AC-4 端口 `39366` 两次一致）。

> **口径提醒**：AC-8 判据 5（"肉眼看到 `◇`"）本轮由 QA **读图目视**（`◇新游戏/◇继续游戏/◇设置` 三行），**不是人类签字**。报告里已如此标注，别在对外材料里升级成"人工验收通过"。

---

## 六、v0.5 新登记（本轮发现，未修）

| ID | 内容 | 为什么没在本轮顺手改 | 状态 |
|---|---|---|---|
| **D12** | `Sources/UI/EmbeddedKernel/WKPageChannel.swift:137-142` 仍内联构造 `WKUserScript` 再 `addUserScript`。它不违反 D1 判据（判据只数 configuration 构造点 = 1，且这是运行期给已存在 webView 追脚本、属 CDP 兼容层），但与 D1 要消灭的"两处并行"**同形** | 改它要动已验证二进制，会让本轮 15 条证据整体作废；正确做法是下一轮改调 `KernelWebViewConfiguration.documentStartScript(_:)` 并重跑 G5/G6/G13 | `OPEN` |
| **D13** | ~~`Tests/e2e/play_e2e.sh` 的 work 目录名出现双斜杠（`${TMPDIR}` 自带尾斜杠）：`/var/folders/…/T//mochibox-e2e.xxx`~~ | 该脚本**已不存在**（`46902a3` 连同 CDP 探针一并删除，新 E2E 入口是 `Tests/e2e/run.sh`），问题无处可修 | `OBSOLETE`（随 `46902a3` 删除 `play_e2e.sh` 而失效） |
| **D14a** | `--kernel-smoke` 的 `autoplay=skipped(no_video)` 分支只有工程师自测，**QA 未独立复验**（`Sources/UI/EmbeddedKernel/KernelSmokeMain.swift:321` 仍会打出该 summary）；另有"两个 E2E 实例真并发互跑"仍无用例覆盖 | 要额外造无 `<video>` 的合成页、并起两个 E2E 实例抢同一 webRoot；本轮判据里不是必过项，如实留白比假绿好 | `OPEN`（P2） |
| **D14b** | ~~`concurrency_hint` 的 `web_port_busy` 文案分支只有代码审阅~~ | `concurrency_hint` 是 `Tests/e2e/play_e2e.sh` 内部函数（见 `36e95ec`），脚本删除后**全仓源码 0 命中**；产品侧 `webPortBusy` 错误码仍在，但已由新 E2E 的 `Tests/e2e/cases/faults/10_port_busy.mjs` 覆盖"候选被占自动绕开 / 全占报 port_unavailable"，与本条无关 | `OBSOLETE`（随 `46902a3` 删除 `play_e2e.sh` 而失效） |

---

## 七、2026-10-23 补登记（已修，绑 commit）

> 本节的 CLOSED 绑 **commit** 而非二进制 sha：这两条修复当时的验证产物未留 sha，按本册硬条件属"证据等级不足"。
> 复核时请从对应 commit 干净重建后重跑所列命令；补上 sha 后可升级为完整 CLOSED。

| ID | 来源 | 欠的是什么 | 修法与判据 | 状态 |
|---|---|---|---|---|
| **D15** | 2026-10-23 日志排查 | **握手期的信封被 `drain()` 读走即焚**：`hello` 之外的 `text`/`stats` 等在握手完成前到达时被丢弃，表现为 `captured=0` 且无报错 | `af2915d`：`Resources/agent_mvmz.js` 与 `Sources/Adapters/AgentInjector.swift` 双端改——非 `hello` 信封回灌 outbox，握手后重新可取。复核：`--selftest` + 真机/替身页 `captured > 0` | `CLOSED`（绑 `af2915d`；sha 未留档） |
| **D16** | 2026-10-23 日志排查 | **会话日志无轮转、无限增长**：`logs/` 只增不减，长期运行占满磁盘 | `aeec54d`：`Sources/App/Constants.swift` + `Sources/Infra/Stores.swift` 接上按份数保留**最近 50 份**，会话创建时裁一次。复核：连续建会话 >50 次后 `ls logs \| wc -l` ≤ 50 | `CLOSED`（绑 `aeec54d`；sha 未留档） |



---

## 八、2026-10-23 补登记（E2E 重写期间独立复核发现，已修）

> 这两条由 **E2E 重写期间的独立复核**发现，不是工程师自测转述。
> 发现时测试把现状钉为"当前行为快照"（断言写实际值）；**2026-10-23 已全部修复**，
> 断言已改回契约值，修复前后的 TAP 见各自 commit。回归判据见 `docs/testing.md` §7。

| ID | 来源 | 欠的是什么 | 现象 / 期望 | 状态 |
|---|---|---|---|---|
| **D17** | E2E 重写独立复核（= BUG-D1） | `requeue` 的批间去重表在"整批都是重复"时被清空，导致同一批信封**第三次**重放被重新接受 | 同一批 3 个 `text` 信封连续回灌：第 1 次 `accepted=3`、第 2 次 `duplicate=3`（正确）、第 3 次又 `accepted=3`（**修复前**）。**修复后**第 2、3 次都是 `accepted=0 / duplicate=3`、投递 0 | `CLOSED`（`6048d7f`） |
| **D18** | E2E 重写独立复核（= BUG-D2） | `cheat.giveItem` / `setItemCount` / `updateActor` 用 `clampInt(args.id, -1, 1, 99999)`，非数字 id 静默落到默认值 1；同文件的 `requireId()` 却明确"不夹取、越界报错" | `giveItem {kind:"item", id:"abc", count:2}` → **修复前** `ok:true`、`data.id=1`、item#1 数量 +2（3→5）。**修复后** `ok:false` + `cheat_bad_args`（非数字）/ `cheat_out_of_range`（越界），不改引擎状态 | `CLOSED`（`13041c7`） |

**复现命令**（无需 GUI，`node:vm` + 真 Agent）：

```bash
# D17
node --input-type=module -e '
import { createHarness } from "./Tests/e2e/lib/harness.mjs";
const h = createHarness({ fixture: false }); h.drainAll();
for (let i = 0; i < 3; i++) h.emit("text", { raw: "r" + i, surface: "s", ts: 1000 + i, frame: i });
const taken = h.drainAll();
for (let n = 1; n <= 3; n++) console.log(n, JSON.stringify(h.requeue(taken)), "delivered=" + h.drainAll().length);
'

# D18
node --input-type=module -e '
import { createHarness } from "./Tests/e2e/lib/harness.mjs";
const g = createHarness({ fixture: true }); g.drainAll();
console.log(JSON.stringify(g.rpc("cheat.giveItem", { kind: "item", id: "abc", count: 2 }).ack));
console.log("item#1 =", g.run("window.$gameParty.numItems(window.$dataItems[1])"));
'
```

**回归断言 ID**：D17 = `E-14b` / `E-14c`（`Tests/e2e/cases/contract/05_envelope.mjs`）；
D18 = `T-014-I` / `T-015-I` / `T-016-I`（`Tests/e2e/cases/contract/03_rpc_table.mjs`）。
两处原先带 `[BUG-D1]` / `[BUG-D2]` 前缀并写实际值；修复时已去掉前缀、改为契约值。


---

## 九、2026-10-23 补登记（E2E 领域层发现，已修）

> 这四条是 **E2E 领域层（domain / Swift 探针）重建过程中被读源码 + 探针对照发现**的，
> 不是自测转述，发现时也**没有**被夹具"顺手修掉"。
> **2026-10-23 已全部修复**：修复前测试只断言契约要求的那一半（缺口记在矩阵里），
> 修复时补上了能抓住缺陷的新断言（先红后绿），矩阵里的 `GAP-` 与 F 编号已随之关闭。

| ID | 一句话 | 位置 | 级别 | 状态 |
|---|---|---|---|---|
| **D19** | 短 `sk-` 密钥（`sk-` 后不足 8 字符）不脱敏，明文进日志 | `Sources/Domain/Models/ErrorModels.swift:241`（正则）、`:250`（mask） | P2（安全） | `CLOSED`（`e091c6e`） |
| **D20** | `library.json` 备份名只到秒，且**先删后移**：同一秒内第二次损坏会覆盖上一份证据 | `Sources/Infra/Stores.swift:516-518` | P2（可诊断性） | `CLOSED`（`1abfdd8`） |
| **D21** | 缓存淘汰按**写入时刻**排序、命中不回写时间戳，实际是 FIFO，日志却写"按最久未用" | `Sources/Infra/Stores.swift:674-676`（get）、`:788`（排序）、`:792`（日志措辞） | P3（语义偏差） | `CLOSED`（`eadaf0f`） |
| **D22** | `fulltext/` 的 0700 只在**首次创建**时生效；目录已存在（旧版本建的 0755）时不会收紧 | `Sources/Infra/FullTextStore.swift:129-137` | P3（安全/兼容） | `CLOSED`（`c71e68e`） |

### D19 · 短 `sk-` 密钥不脱敏（P0-12）

- **现象**：`SecretMask.mask("apiKey=sk-abc")` 原样返回 `apiKey=sk-abc`。
  触发词命中（`sk-` 在串里）走进正则分支，但正则 `sk-[A-Za-z0-9_\-]{8,}` 要求
  `sk-` 之后**至少 8 个字符**，短 key 一个 match 都没有 → `replaceSubrange` 一次都不执行。
- **期望**：PRD P0-12「apiKey 一律脱敏为 `sk-…后4位`」。`maskToken` 里本来就有
  `guard token.count >= 8 else { return "***" }` 的兜底（`ErrorModels.swift:303`），
  说明作者预期短 token 也要处理；只是正则把入口卡死了，兜底永远走不到。
  契约应是：短 key → `***`（或 `sk-…后2位`），**不得出现明文**。
- **复现**（无需 GUI）：在 `Tests/e2e/cases/domain/probe_store.swift` 的 D3 段加一行
  `TAP.eq("D3", "短 key", SecretMask.mask("apiKey=sk-abc"), "apiKey=***")`，
  `bash Tests/e2e/run.sh --suite domain` 即见实际值 `apiKey=sk-abc`。
  同一路径已有一条正例断言（`sk-abcdef123456` → `sk-…3456`，`probe_store.swift:274-277`）。
- **影响**：短 key 通常是**测试/占位密钥**，但也可能是用户粘贴错误被完整写进
  `logs/session-*.log`；日志是本产品明确承诺"可导出给他人排障"的文件（P0-19）。
- **发现来源**：E2E 领域层重建（`03_secret_mask.mjs` 注释已标注"见 F-1"，但当时未登记）。
- **修复**（`e091c6e`）：规则改为 `(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]+` —— 长度下限放到 1，
  短 key 进入 `maskToken` 的 `***` 兜底；同时补左边界，避免放开下限后把 `task-manager`
  里的 `sk-` 误伤成凭据。回归断言：D3「短 sk- key 一律脱敏（sk-abc → ***）」等 4 条。

### D20 · `library.json` 备份名只到秒且先删后移（P0-04 可诊断性）

- **现象**：损坏分支是
  `backup = library.json.bak-<Timestamp.fileStamp()>`（`yyyyMMdd-HHmmss`）
  → `removeItem(at: backup)` → `moveItem(at: url, to: backup)`。
  同秒内第二次损坏时，`removeItem` 先删掉**上一份**备份，再把自己的文件移过去：
  证据被覆盖，且 `moveItem` 失败时旧备份已经没了。
- **期望**：同一秒内多次损坏应留下多份证据（文件名加序号/毫秒/pid），
  且"先移后删"或"目标存在则改名"——任何失败路径都不得销毁既有备份。
- **复现**：现有 D1 探针刻意"等过一秒再制造第二次损坏"
  （`probe_store.swift:124-132`，注释写明"备份名只精确到秒"），说明该限制已知；
  去掉那次等待、同秒内连坏两次 → 目录里只剩 1 个 `bak-` 文件，第一份内容丢失。
- **影响**：用户连续两次遇到同一份坏库（例如磁盘故障/同步冲突）时，排障只剩最后一份。
  属"证据保留"类缺陷，不影响功能正确性。
- **发现来源**：E2E 领域层重建（domain D1 的注释把限制写在了夹具里，未进欠账册）。
- **修复**（`1abfdd8`）：备份目标改由 `backupURL()` 计算，同秒重名顺延 `-2` / `-3`…，
  并删除 `removeItem(at: backup)` —— 任何失败路径都不再销毁既有备份。
  回归断言：D1「同秒连续两次损坏 → 留 2 份备份（不覆盖）」与「两份备份内容分别是 A/B」。

### D21 · 缓存淘汰是 FIFO，不是 LRU（P0-10 语义偏差）

- **现象**：`get()` 直接 `return index[key]`（`Stores.swift:674-676`），不更新 `ts`、
  不累加 `hitCount`；`evictIfNeeded()` 按 `ts` 升序淘汰（`:788`）。
  `ts` 只在 `put()` 时写入 → 排序键就是"写入时刻" → 淘汰策略是 **FIFO**。
  而同一函数的日志写的是 `"按最久未用淘汰缓存"`（`:792`）。
- **期望**：PRD P0-10 与 `docs/architecture.md` 的口径是"最久未用（LRU）"：
  命中应刷新使用时刻（或至少刷新 `hitCount`），淘汰按使用时刻而非写入时刻。
  要么改实现，要么把日志与文档改成"按写入顺序（FIFO）"，二选一，现状是**说的和做的不一致**。
- **复现**：`maxEntries=3`，写 k1..k3 → `get("k1")`（命中）→ 写 k4 →
  期望 LRU 淘汰 k2，实际淘汰 k1（因为 k1 的 `ts` 最早）。
  现有 D7 断言（`probe_store.swift:426-431`）没有"先命中再超限"这一步，因此两种策略都能过。
- **影响**：热句被反复重译（费用/延迟），冷句反而常驻；命中率统计不受影响（`noteHit` 单独计数）。
- **发现来源**：E2E 领域层重建（domain D7 对照实现时发现）。
- **修复**（`eadaf0f`）：`Entry` 增加 `lastUsed`；`put()` 写入时初始化、`get()` 命中时回写，
  `evictIfNeeded()` 改按 `lastUsed` 排序 —— 日志文案不变，因为它描述的是真实行为了。
  回归断言：D7「命中刷新使用时刻：淘汰最久未用的 k2（不是最早写入的 k1）」与「被命中的 k1 仍在」。

### D22 · `fulltext/` 的 0700 只在首次创建生效（P0-19 兼容面）

- **现象**：`ensureDirectory()` 每次 save 都调 `createDirectory(withIntermediateDirectories: true,
  attributes: [.posixPermissions: 0o700])`。`FileManager` 的 `attributes` **只作用于新建**；
  目录已存在时既不报错也不改权限。升级前（或其它工具/用户手工）建出的 0755 目录会一直保持 0755，
  里面是用户翻过的全部对话。
- **期望**：目录已存在时显式 `setAttributes([.posixPermissions: 0o700])`（失败记日志、不阻断保存），
  即"每次打开会话都确认目录是 0700"。
- **复现**：`mkdir -m 755 <MOCHI_DATA_DIR>/fulltext` → 跑一次导出（domain D8）→
  `stat -f '%Lp' <MOCHI_DATA_DIR>/fulltext` 仍是 `755`。现有 D8 断言只覆盖"首次创建 → 0700"
  （`probe_fulltext.swift:45/169` 明确"不预先建目录"）。
- **影响**：同机其它本地账户可读译文全文；不涉及密钥，但违背文件头注释
  "`fulltext/` 用 0700：不需要让同机其它账户读到"的意图。
- **发现来源**：E2E 领域层重建（domain D8 的"不预先建目录"前置条件暴露了未覆盖分支）。
- **修复**（`c71e68e`）：`ensureDirectory()` 创建之后再显式 `setAttributes([.posixPermissions: 0o700])`；
  收紧失败只记 warn、不阻断保存。回归断言：D8「目录已存在时 save 仍收紧到 0700」。

## 十、2026-10-24 补登记（自检门禁自身缺陷，已修）

> 这两条是**追查 2026-10-24 00:09 那批孤儿 Chrome（pid 80349 等 8 个 + 2 个 crashpad）**
> 时定位的：那批进程是"注入真缺陷"实验故意不杀子进程留下的，但排查过程证明了两件事——
> `--selftest` **默认会拉起真 Chrome**，而且**只要有一步抛错就没人收尸**。两条同根，一起修。

| ID | 一句话 | 位置 | 级别 | 状态 |
|---|---|---|---|---|
| **D23** | `--selftest` 默认会真拉起 Chromium（占调试端口、写 profile、Dock 冒图标）；且没有 TAP skip 口径，"没跑"与"跑过且过"分不开 | `Sources/SelfTest/LauncherCaseSupport.swift`（`browser_launch_and_terminate`、`web_runner_stop_partial` (c)）、`Sources/SelfTest/SelfTestRunner.swift`（harness） | P1（默认行为的副作用） | `CLOSED`（`0bb93e2`） |
| **D24** | 浏览器用例的收尸只在"正常走完"和"HTTP 请求那一段"两条路径上；launch 返回后任一断言失败/超时/取消都会把整组 Chrome 留在机器上。且 `BrowserProcessSweeper` 只扫产品根，扫不到 selftest 临时根 | `Sources/SelfTest/LauncherCaseSupport.swift`、`Sources/Adapters/Web/BrowserProcessSweeper.swift` | P1（资源泄漏） | `CLOSED`（`0bb93e2`） |

### D23 · `--selftest` 默认拉起真 Chrome（opt-in 化）

- **现象**：默认跑 `--selftest` 会 `launch` 一次真 Chromium（`browser_launch_and_terminate`），
  `web_runner_stop_partial` 的 (c) 段还会再拉一次。用户机器上表现为"跑个自检，Dock 里闪出 Chrome"，
  机器忙时还会撞 `browser_exited_early` 假红。没有 skip 时，唯一"不跑"的办法是让用例自己
  `print + return`，末行仍是 `# pass N fail 0` —— 这与"真的验过"无法区分。
- **期望**：默认**不 spawn 任何浏览器**；要跑真浏览器生命周期必须显式 `MOCHI_SELFTEST_BROWSER=1`，
  未设置时输出真 TAP `ok N - … # SKIP <原因>`，末行带 `skip` 计数。opt-in 后的行为与修复前完全一致。
- **修复**（`0bb93e2`）：`SelfTestCase` 增加 `skip:` 字段，harness 打 `# SKIP` 并统计
  `# pass X fail Y skip Z`；两条真浏览器用例挂在 `skip: browserCaseSkipReason` 上；
  `web_runner_stop_partial` 只把 (c) 段包进 opt-in，(a)(b) 用假浏览器保持默认执行。
- **证据**：默认 `# pass 45 fail 0 skip 1`（连跑 5 次一致）；`MOCHI_SELFTEST_BROWSER=1` → `# pass 46 fail 0 skip 0`。
  canary：`MOCHI_BROWSER_PATH` 指向"打点后 exit 1"的脚本，默认跑完标记文件不存在；opt-in 再跑标记出现。
- **回归断言**：`ok 44 - [F] browser_launch_and_terminate # SKIP …`（默认）／`ok 44` + `ok 46`（opt-in）。

### D24 · 浏览器用例异常路径不收尸 + 清扫范围漏 selftest 根

- **现象**：`browser_launch_and_terminate` 只在两处调 `terminate`（`handle.web` 为空的 guard、
  HTTP 请求的 catch）以及末尾正常路径。`launch` 返回后的任一断言失败、`allocateWebPort` 抛错、
  任务取消，都会直接跳出函数 —— 浏览器进程、静态服务、调试端口全部留着（实测一次注入就留
  6 个 Chrome + crashpad，且父进程已 reparent 到 1，`ps` 里只剩 profile 路径可识别）。
  而 `BrowserProcessSweeper.sweep()` 只扫 `AppPaths.shared`，自检的 profile 在
  `/var/folders/…/MochiBox-selftest-<pid>` 下，**永远扫不到**。
- **期望**：拿到 handle 之后，无论断言失败、超时还是抛错，退出前都必须 `terminate`；
  并断言带该 profile 的 helper 也一起消失。任何一轮自检结束时，`pgrep -f <本次 tempRoot>` 必须为空。
- **修复**（`0bb93e2`）：launch 纳入 `do/catch`（catch 里 `terminate` 幂等收尸）；
  `BrowserProcessSweeper` 新增 `sweep(pathsList:)` 多根清扫；harness 末尾新增
  `no_orphan_browser` 门禁（先 `pgrep` 记账 → 记 fail → 再清扫），把"漏收尸"变成可见的红。
- **证据**：旧代码在 `launch` 后注入抛错 → 留 6 个进程（红）；新代码同一注入 → pgrep 空、
  `ok … no_orphan_browser`（绿）。反向自证：新代码故意删掉收尸 → `not ok … no_orphan_browser`
  并列出 6 个 pid，随后仍被清掉。
- **回归断言**：`ok 46 - [F] no_orphan_browser`（默认与 opt-in 两种跑法都必须有这一行）。


## 十一、2026-10-24 补登记（CLI 未知参数被静默忽略，已修）

| ID | 一句话 | 位置 | 级别 | 状态 |
|---|---|---|---|---|
| **D25** | 未知 `--` 旗标被静默吃掉：把 E2E 的 `--suite all` 打到产品二进制上不报错、不输出，直接起 GUI（看起来像挂住）；各模式也互不排斥（`--selftest --play x` 静默按 selftest 跑） | `Sources/App/AppMain.swift`（分流只有 `arguments.contains(...)`） | P1（可诊断性） | `CLOSED`（`102e4cb`） |

### D25 · 未知 CLI 旗标静默起 GUI

- **现象**：`./build/MochiBox.app/Contents/MacOS/MochiBox --suite all` 不报错、不输出，
  按"无模式 = GUI"起一个空窗口；用户以为在等测试结果，实测 5 秒 0 字节、只能用
  `timeout` 杀掉。`--help` 同样起 GUI。`--selftest --play x` 则静默按 `--selftest` 跑完
  （exit 0），`--play x` 被吃掉。
- **期望**：分流前统一校验 —— 未知旗标 `error_code: unknown_argument` + `exit 2`；
  互斥模式/放错模式的旗标 `error_code: conflicting_arguments` + `exit 2`；
  新增 `--help`/`-h` 按模式列出旗标与退出码（`exit 0`）。
  Finder/`open` 注入的 `-psn_0_…`、`-NSDocumentRevisionsDebugMode` 与裸参数必须放行。
- **修复**（`102e4cb`）：新增 `Sources/App/ArgumentValidation.swift`（仅 Foundation），
  在 `MochiBoxMain.main()` 分流之前调用；`--help` 优先于校验。模式自身缺取值
  （`--attach` 无端口 / `--play` 无目录）保持原解析器行为，退出码与用法文案不变。
- **证据**（同一台机器，记于 `Tests/qa/final-sha256-v0.6.txt` 末节）：
  - 旧二进制 `2d03d5ee…`（5179136 B）：`--suite all` → `timeout 5` 得 `124`，
    stdout/stderr 均 0 字节；`--help` → 同样 `124`。
  - 新二进制 `dd4d2db7…`（5180768 B）：
    `--suite all` → `exit 2`，0.52s，stdout =
    `error_code: unknown_argument` / `unknown option: --suite` / `see --help`；
    `--help` → `exit 0` 并打印用法；`--selftest --play x` →
    `error_code: conflicting_arguments` + `exit 2`。
  - 回归：`--selftest` `# pass 45 fail 0 skip 1`；`--selftest --filter skip` 4/0/0；
    `-psn_0_1234 --selftest` 仍 45/0/1；无参数启动 4s 后仍存活且无 `error_code`；
    `bash Tests/e2e/run.sh --suite all` → `E2E PASS suite=all cases=45 assertions=954`。

---

## 十二、2026-10-25 补登记（字体方案落地，已修）

| ID | 一句话 | 位置 | 级别 | 状态 |
|---|---|---|---|---|
| **D26** | PRD `P1-03`「字体替换」落地为**系统字体族版**：设置里选 `gameFontFamily`（空 = 自动苹方），Agent 拼 `PingFang SC → Hiragino Sans GB → Heiti SC → Unifont Smooth → Arial Unicode MS → Sun-ExtA` 回退链，并保留游戏自己的 `fontFace` | `Sources/Infra/Stores.swift`（`Settings.gameFontFamily`）、`Sources/UI/MainWindow.swift`（`fontSection`，只列同时覆盖「汉」「あ」的族）、`Resources/agent_mvmz.js`（`fontChainFor`） | P1（中文排版） | `CLOSED`（字体族 + 回退链版本） |

> 原条款里「用户指定本地 `.ttf/.otf` 并 `@font-face` 注入」**不在本次范围**（字体文件不分发，合规与体积原因），
> 仍按 `OPEN` 计；本条的 CLOSED 只覆盖"换族名 + 回退链"这一半，复核时别把两者混为一谈。
> 原版 MTool 的做法与字体清单见 `docs/re-findings.md §6`。

