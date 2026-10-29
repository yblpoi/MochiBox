# E2E 覆盖矩阵

本文件是五层 E2E 的断言台账。规则只有一条：**每一条断言的期望值都必须能追溯到需求 ID、
源码契约位置或已知缺陷编号**，不允许写「实现如此」。

## 总览

| 层 | cases | assertions | 需要桌面（Aqua） | 需要真游戏素材 |
| --- | --- | --- | --- | --- |
| 协议层 contract | 15 | 546 | 否 | 否 |
| 领域层 domain | 13 | 348 | 否（仅 D9 需要；无桌面时 D9 SKIP） | 否（用 `Fixtures/e2e_game` 只读） |
| 内核层 kernel | 14 | 165 | 是 | 否（用 `Fixtures/e2e_game`） |
| 故障层 faults | 10 | 55 | 是 | 否（用 `Fixtures/e2e_game` + mock 后端） |
| 真游戏层 game | 2 | 0（未设 `MOCHI_E2E_GAME` 时整层 SKIP）/ 11（实际跑） | 是 | 是（`MOCHI_E2E_GAME`） |
| **合计**（`--suite all`，无真游戏素材） | **52** | **1114** | — | — |

跑法：

```bash
bash Tests/e2e/run.sh --suite contract    # 零浏览器、零网络、零 GUI
bash Tests/e2e/run.sh --suite domain      # 领域层：零 GUI（D9 需要桌面，无桌面时 SKIP）
bash Tests/e2e/run.sh --suite kernel      # 需要 Aqua 桌面 + build/MochiBox.app
bash Tests/e2e/run.sh --suite faults      # 需要 Aqua 桌面 + build/MochiBox.app
MOCHI_E2E_GAME=<mv|mz 游戏目录> bash Tests/e2e/run.sh --suite game
bash Tests/e2e/run.sh --suite all         # 依次 contract → domain → kernel → faults → game
```

末行固定为 `E2E PASS|FAIL suite=<name> cases=<N> assertions=<M>`；缺桌面时 kernel/faults/game
打印 `SKIP ... reason=kernel_reason=no_aqua` 后继续，缺 `MOCHI_E2E_GAME` 时 game 打印
`SKIP ... MOCHI_E2E_GAME 未设置` 后继续 —— **SKIP 既不算通过，也不算失败**。

---

## 协议层（contract）

> 生成方式：`bash Tests/e2e/run.sh --suite contract` 的 TAP 输出逐条落表。
> **实测 546 条断言**（2026-10-26 末行 `E2E PASS suite=contract cases=15 assertions=546`）。
> **不再声明"断言数 = 行数"**：同一断言可能有别名行，也有用例的 TAP 名字不带稳定编号
> （`13_config_agent`、`14_update_actor_equips`、`15_agent_diag`），只能按用例名对账；
> 计数一律以 run.sh 的末行为准。历史别名 `V4-11a…g` 的 7 行仍各占一行（它们与
> `V4-2a/b/c/d/e`、`V4-3a`、`V4-5c` 是同一条断言的**两个历史编号**；别名带 `-A` 后缀，
> 表示它落在面A"可见性 + 原文逐字节保留"那一条上，见下方迁移对照）。
> 新增/删除断言时必须同步更新本表 —— 这张表是"每个既有断言都有归宿"的唯一凭证。

列说明：
- **断言ID**：TAP 名字里的稳定编号（跨文件唯一）。`R-*` / `A-*` / `P-*` / `E-*` / `SEG-*` /
  `T-*` / `V4*` / `V6*` / `V5*` 各自命名空间独立。
- **层**：本表固定为 `contract`（协议层：Node vm + Swift 单元探针，零浏览器 / 零外网）。
- **用例名**：`Tests/e2e/cases/contract/<文件>` / TAP group。
- **覆盖的 AC/P0**：对应 `docs/prd.md` 的验收项；无 AC 的（如安全边界）标架构章节。
- **依据**：判据来自哪份实现或文档 —— 断言的期望值必须能追溯到它，而不是"跑出来是什么就写什么"。

旧探针的迁移对照（删掉的文件 → 新归宿）：

| 旧文件 | 旧断言 | 新归宿 |
| --- | --- | --- |
| `Tests/qa/agent_rpc_smoke.mjs` | 57 条（R 系列） | `02_agent_rpc.mjs`（R-01…R-57，逐条保留） |
| `Tests/qa/dedupe_race_probe.mjs` | A1–A7 | `07_dedupe_race.mjs`（A1–A7 + A8–A11 补充） |
| `Tests/qa/emit_contract_probe.mjs` | V4-11a–g（7 条） | `08_skip_emit.mjs` 面A（与 V4-2*/3a/5c 同一样本，名字里并列两个 ID） |
| `Tests/qa/idempotency_probe.mjs` | V8-*（4 条） | `01_agent_api.mjs` A-09/A-16/A-20/A-24 |
| `Tests/qa/lookup_variant_probe.mjs` | C1–C9 | `09_lookup_variant.mjs`（C1–C9 渲染 + C*-state 状态不变量） |
| `Tests/qa/skip_probe.mjs` | V4-1a–V4-5d（18 样本 × 面A/面B） | `08_skip_emit.mjs` |
| `Tests/qa/skip_parity.{sh,mjs,swift}` | 9 样本 | `10_skip_parity.mjs` + `skip_parity.swift` |
| `Tests/qa/store_probe.{sh,swift}` | 25 条（S/W/R 系列） | `11_store.mjs` + `store_probe.swift` |
| `Tests/qa/qa_probe.swift` | 42 条（V4S-*/V6-*/V5-*） | `12_domain_qa.mjs` + `qa_probe.swift`（V6 从 16 条扩到 25 条） |

补充说明：
- `03_rpc_table.mjs` 是表驱动的新增覆盖：45 个方法 × H/I/N 三个维度 = 135 条；
  每个方法一行 `T-0nn-H/I/N`，H=正常入参、I=缺参/类型错误、N=无 `$game*` 的降级。
- `08_skip_emit.mjs` 里一条断言同时承担"可见性"与"原文逐字节保留"两件事 —— 它们本来就是
  同一条事实（见 P0-09），拆成两条会变成同一断言重复计数。
- `06_segment_escape.mjs` 验的是**纯函数**（`skipReasonOf` 的输入输出），`08_skip_emit.mjs`
  验的是**采集出口**（hook → payload.status / state.skipped）。两者不是同一条断言：
  前者能独立于绘制路径跑，后者才能证明「跳过句仍然出现在文本流里」。
- `12_domain_qa.mjs` 的 V5 组需要本地 `Tests/qa/error_server.py`（只监听 127.0.0.1），
  不读外网；端口现取空闲端口，退出即杀。

| 断言ID | 层 | 用例名 | 覆盖的 AC/P0 | 依据 |
| --- | --- | --- | --- | --- |
| A-01 | contract | 01_agent_api / 注入后向 outbox 推入 hello 信封 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-02 | contract | 01_agent_api / hello 的信封协议版本 v=1（与脚本能力版本 VERSION 是两件事） | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-03 | contract | 01_agent_api / hello 自述 agentVersion/engineGuess/caps | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-04 | contract | 01_agent_api / hello.hooks 列出 4 个 hook，ua/href 均为字符串 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-05 | contract | 01_agent_api / __mochibox.version 是 ≥2 的数字 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-06 | contract | 01_agent_api / __mochibox.escapeTableVersion 已暴露且 ≥2（Swift 侧靠它比对码表版本） | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-07 | contract | 01_agent_api / __mochibox.caps 逐项等于 rpc/cheat/scan | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-08 | contract | 01_agent_api / 注入后 installed=true | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-09 | contract | 01_agent_api / V8-IDEMPOTENT：二次 install() 不替换 drawTextEx（引用不变） | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-10 | contract | 01_agent_api / 二次 install() 后 hooks 仍为 4 条（不叠加） | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-11 | contract | 01_agent_api / hooks 无重复项 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-12 | contract | 01_agent_api / hooks 覆盖四个绘制面（drawTextEx/drawText/Bitmap.drawText/startMessage） | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-13 | contract | 01_agent_api / 二次 install() 不重复发 hello（重复握手由 hello() 单独负责） | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-14 | contract | 01_agent_api / probe() 的 10 个字段齐全且类型正确 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-15 | contract | 01_agent_api / 干净注入后 errors=0、mergeFallback=0 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-16 | contract | 01_agent_api / V8-NO-DOUBLE-EMIT：一次绘制只 emit 1 条 text | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-17 | contract | 01_agent_api / text 信封带 v/type/payload.raw/ts/surface | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-18 | contract | 01_agent_api / probe().emitted 与实际 emit 数一致 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-19 | contract | 01_agent_api / _orig 保存了四个原始函数引用 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-20 | contract | 01_agent_api / V8-UNINSTALL：uninstall() 复原 Window_Base.drawTextEx | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-21 | contract | 01_agent_api / uninstall() 同样复原 drawText / Bitmap.drawText / startMessage | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-22 | contract | 01_agent_api / uninstall() 后 installed=false、hooks 清空 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-23 | contract | 01_agent_api / 卸载后重新 install() 生效，且一次绘制仍只 emit 1 条 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| A-24 | contract | 01_agent_api / V8-ERROR-SWALLOWED：原函数抛异常不冒泡给游戏，且 state.errors 计数 | P0-07 / 架构 §6、§8.4 | Resources/agent_mvmz.js：install / uninstall / probe / hello |
| R-01 | contract | 02_agent_rpc / 夹具已在 vm 里跑起来（$gameParty 可读） | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-02 | contract | 02_agent_rpc / cheat.snapshot → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-03 | contract | 02_agent_rpc / snapshot 的 scene/mapId/gold 来自引擎对象 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-04 | contract | 02_agent_rpc / snapshot.party 来自 $gameParty.members() | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-05 | contract | 02_agent_rpc / setGold {value} → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-06 | contract | 02_agent_rpc / $gameParty._gold 被改写 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-07 | contract | 02_agent_rpc / setGold {delta} → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-08 | contract | 02_agent_rpc / delta 是叠加 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-09 | contract | 02_agent_rpc / setVariable #7 → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-10 | contract | 02_agent_rpc / $gameVariables.value(7) 往返 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-11 | contract | 02_agent_rpc / setSwitch #3 on → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-12 | contract | 02_agent_rpc / $gameSwitches.value(3) 往返 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-13 | contract | 02_agent_rpc / setSelfSwitch [3,1,B] → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-14 | contract | 02_agent_rpc / $gameSelfSwitches 往返 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-15 | contract | 02_agent_rpc / giveItem item#2 +4 → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-16 | contract | 02_agent_rpc / numItems 从 1 变 5 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-17 | contract | 02_agent_rpc / updateActor #1 level=33 → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-18 | contract | 02_agent_rpc / $gameActors.actor(1).level 被改写 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-19 | contract | 02_agent_rpc / listActors 反映新 level 并带 className | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-20 | contract | 02_agent_rpc / noclip on → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-21 | contract | 02_agent_rpc / $gamePlayer._through 被改写 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-22 | contract | 02_agent_rpc / godMode on lockHp → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-23 | contract | 02_agent_rpc / godMode+lockHp：引擎侧 setHp(1) 后 HP 仍等于 mhp | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-24 | contract | 02_agent_rpc / godMode off → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-25 | contract | 02_agent_rpc / encounter off → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-26 | contract | 02_agent_rpc / on=false → 禁止遇敌 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-27 | contract | 02_agent_rpc / encounter on → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-28 | contract | 02_agent_rpc / on=true → 允许遇敌 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-29 | contract | 02_agent_rpc / speed ×2 → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-30 | contract | 02_agent_rpc / speed ×2：一次 update 走两帧 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-31 | contract | 02_agent_rpc / speed 复位 ×1 → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-32 | contract | 02_agent_rpc / speed 复位后一次 update 只走一帧 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-33 | contract | 02_agent_rpc / transferPoints 从 $dataMap 的 201/<TP> 里取到至少一个点 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-34 | contract | 02_agent_rpc / teleport {mapId:1,x:5,y:7} → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-35 | contract | 02_agent_rpc / 传送落到 $gamePlayer._x/_y 且 mapId 切换 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-36 | contract | 02_agent_rpc / scene menu → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-37 | contract | 02_agent_rpc / SceneManager._scene = Scene_Menu | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-38 | contract | 02_agent_rpc / scenePop → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-39 | contract | 02_agent_rpc / scenePop 回到 Scene_Map | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-40 | contract | 02_agent_rpc / battle win → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-41 | contract | 02_agent_rpc / BattleManager 进入胜利态 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-42 | contract | 02_agent_rpc / objectPath 读到 $gameParty._gold | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-43 | contract | 02_agent_rpc / setObjectPath $gameVariables._data → ok:true 且带 data | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-44 | contract | 02_agent_rpc / 不在 $game*/$data* 前缀的路径 → cheat_forbidden | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-45 | contract | 02_agent_rpc / 越界 id → cheat_out_of_range（不夹取） | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-46 | contract | 02_agent_rpc / 错误路径之后 Agent 仍可用 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-47 | contract | 02_agent_rpc / 未知 method → rpc_unknown_method | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-48 | contract | 02_agent_rpc / scanStart 立即返回 scanId/estimated | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-49 | contract | 02_agent_rpc / scanDone 到达 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-50 | contract | 02_agent_rpc / total>0 且不小于实际收到的条目数 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-51 | contract | 02_agent_rpc / 同一次扫描内无重复 raw（Agent 侧已去重） | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-52 | contract | 02_agent_rpc / 每条 item 都有 raw/source/path | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-53 | contract | 02_agent_rpc / 未取消的扫描 cancelled=false | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-54 | contract | 02_agent_rpc / scanDone 带 skipped 计数 | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-55 | contract | 02_agent_rpc / scanCancel 返回 ok:true | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-56 | contract | 02_agent_rpc / 取消后 scanDone.cancelled === true | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| R-57 | contract | 02_agent_rpc / 取消结果仍带 total（可判定，不是空壳） | AC-9.1–9.4、AC-10.1 / P0-08 | Resources/agent_mvmz.js：handleRpc + Fixtures/mv_stub |
| T-000 | contract | 03_rpc_table / [用例表自检] 表固定 45 行（增删方法必须同步本文件与 COVERAGE.md） | AC-9.3 / v0.6 §2.2 | 用例表自检 —— 只证明本表行数，不证明产品 |
| T-000b | contract | 03_rpc_table / [用例表自检] 表内方法名无重复 | AC-9.3 / v0.6 §2.2 | 用例表自检 —— Set 去重后长度不变 |
| T-000c | contract | 03_rpc_table / 用例表的方法集合 === Resources/agent_mvmz.js 的 var RPC（双向） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：`var RPC = {` … `};` 的顶层 key（双向差集 + 顺序） |
| T-001-H | contract | 03_rpc_table / cheat.snapshot 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-001-I | contract | 03_rpc_table / cheat.snapshot 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-001-N | contract | 03_rpc_table / cheat.snapshot 无 $game* → 已定义的降级结果（不是 cheat_unavailable） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-002-H | contract | 03_rpc_table / cheat.listVariables 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-002-I | contract | 03_rpc_table / cheat.listVariables 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-002-N | contract | 03_rpc_table / cheat.listVariables 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-003-H | contract | 03_rpc_table / cheat.listSwitches 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-003-I | contract | 03_rpc_table / cheat.listSwitches 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-003-N | contract | 03_rpc_table / cheat.listSwitches 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-004-H | contract | 03_rpc_table / cheat.listItems 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-004-I | contract | 03_rpc_table / cheat.listItems 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-004-N | contract | 03_rpc_table / cheat.listItems 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-005-H | contract | 03_rpc_table / cheat.listActors 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-005-I | contract | 03_rpc_table / cheat.listActors 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-005-N | contract | 03_rpc_table / cheat.listActors 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-006-H | contract | 03_rpc_table / cheat.listMapEvents 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-006-I | contract | 03_rpc_table / cheat.listMapEvents 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-006-N | contract | 03_rpc_table / cheat.listMapEvents 无 $game* → 已定义的降级结果（不是 cheat_unavailable） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-007-H | contract | 03_rpc_table / cheat.transferPoints 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-007-I | contract | 03_rpc_table / cheat.transferPoints 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-007-N | contract | 03_rpc_table / cheat.transferPoints 无 $game* → 已定义的降级结果（不是 cheat_unavailable） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-008-H | contract | 03_rpc_table / cheat.setGold 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-008-I | contract | 03_rpc_table / cheat.setGold 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-008-N | contract | 03_rpc_table / cheat.setGold 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-009-H | contract | 03_rpc_table / cheat.setVariable 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-009-I | contract | 03_rpc_table / cheat.setVariable 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-009-N | contract | 03_rpc_table / cheat.setVariable 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-010-H | contract | 03_rpc_table / cheat.setSwitch 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-010-I | contract | 03_rpc_table / cheat.setSwitch 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-010-N | contract | 03_rpc_table / cheat.setSwitch 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-011-H | contract | 03_rpc_table / cheat.setSelfSwitch 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-011-I | contract | 03_rpc_table / cheat.setSelfSwitch 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-011-N | contract | 03_rpc_table / cheat.setSelfSwitch 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-012-H | contract | 03_rpc_table / cheat.toggleAllSwitches 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-012-I | contract | 03_rpc_table / cheat.toggleAllSwitches 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-012-N | contract | 03_rpc_table / cheat.toggleAllSwitches 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-013-H | contract | 03_rpc_table / cheat.toggleAllSelfSwitches 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-013-I | contract | 03_rpc_table / cheat.toggleAllSelfSwitches 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-013-N | contract | 03_rpc_table / cheat.toggleAllSelfSwitches 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-014-H | contract | 03_rpc_table / cheat.giveItem 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-014-I | contract | 03_rpc_table / cheat.giveItem 缺参/类型错误 → 明确错误码 `cheat_bad_args` | AC-9.3 / v0.6 §2.2 | `requireId()` 的契约（D18，`13041c7`）：非数字 id 不得夹到 #1 |
| T-014-N | contract | 03_rpc_table / cheat.giveItem 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-015-H | contract | 03_rpc_table / cheat.setItemCount 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-015-I | contract | 03_rpc_table / cheat.setItemCount 缺参/类型错误 → 明确错误码 `cheat_bad_args` | AC-9.3 / v0.6 §2.2 | `requireId()` 的契约（D18，`13041c7`）：非数字 id 不得夹到 #1 |
| T-015-N | contract | 03_rpc_table / cheat.setItemCount 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-016-H | contract | 03_rpc_table / cheat.updateActor 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-016-I | contract | 03_rpc_table / cheat.updateActor 缺参/类型错误 → 明确错误码 `cheat_bad_args` | AC-9.3 / v0.6 §2.2 | `requireId()` 的契约（D18，`13041c7`）：非数字 id 不得夹到 #1 |
| T-016-N | contract | 03_rpc_table / cheat.updateActor 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-017-H | contract | 03_rpc_table / cheat.recoverAll 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-017-I | contract | 03_rpc_table / cheat.recoverAll 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-017-N | contract | 03_rpc_table / cheat.recoverAll 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-018-H | contract | 03_rpc_table / cheat.addPartyMember 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-018-I | contract | 03_rpc_table / cheat.addPartyMember 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-018-N | contract | 03_rpc_table / cheat.addPartyMember 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-019-H | contract | 03_rpc_table / cheat.removePartyMember 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-019-I | contract | 03_rpc_table / cheat.removePartyMember 缺参/类型错误 → 明确错误码 cheat_out_of_range | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-019-N | contract | 03_rpc_table / cheat.removePartyMember 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-020-H | contract | 03_rpc_table / cheat.godMode 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-020-I | contract | 03_rpc_table / cheat.godMode 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-020-N | contract | 03_rpc_table / cheat.godMode 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-021-H | contract | 03_rpc_table / cheat.noclip 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-021-I | contract | 03_rpc_table / cheat.noclip 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-021-N | contract | 03_rpc_table / cheat.noclip 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-022-H | contract | 03_rpc_table / cheat.encounter 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-022-I | contract | 03_rpc_table / cheat.encounter 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-022-N | contract | 03_rpc_table / cheat.encounter 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-023-H | contract | 03_rpc_table / cheat.alwaysDash 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-023-I | contract | 03_rpc_table / cheat.alwaysDash 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-023-N | contract | 03_rpc_table / cheat.alwaysDash 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-024-H | contract | 03_rpc_table / cheat.followers 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-024-I | contract | 03_rpc_table / cheat.followers 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-024-N | contract | 03_rpc_table / cheat.followers 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-025-H | contract | 03_rpc_table / cheat.unlockEquip 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-025-I | contract | 03_rpc_table / cheat.unlockEquip 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-025-N | contract | 03_rpc_table / cheat.unlockEquip 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-026-H | contract | 03_rpc_table / cheat.unlockChoice 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-026-S | contract | 03_rpc_table / cheat.unlockChoice 返回形状稳定（键集合与值类型固定） | AC-9.3 / v0.6 §2.2 | `Resources/agent_mvmz.js` 的 `cheat.unlockChoice` 只返回 `{ok:true}`（键集合恰 1 个） |
| T-026-I | contract | 03_rpc_table / cheat.unlockChoice 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-026-N | contract | 03_rpc_table / cheat.unlockChoice 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-027-H | contract | 03_rpc_table / cheat.speed 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-027-I | contract | 03_rpc_table / cheat.speed 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-027-N | contract | 03_rpc_table / cheat.speed 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-028-H | contract | 03_rpc_table / cheat.moveSpeed 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-028-I | contract | 03_rpc_table / cheat.moveSpeed 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-028-N | contract | 03_rpc_table / cheat.moveSpeed 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-029-H | contract | 03_rpc_table / cheat.teleport 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-029-I | contract | 03_rpc_table / cheat.teleport 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-029-N | contract | 03_rpc_table / cheat.teleport 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-030-H | contract | 03_rpc_table / cheat.scene 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-030-I | contract | 03_rpc_table / cheat.scene 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-030-N | contract | 03_rpc_table / cheat.scene 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-031-H | contract | 03_rpc_table / cheat.scenePop 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-031-I | contract | 03_rpc_table / cheat.scenePop 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-031-N | contract | 03_rpc_table / cheat.scenePop 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-032-H | contract | 03_rpc_table / cheat.battle 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-032-I | contract | 03_rpc_table / cheat.battle 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-032-N | contract | 03_rpc_table / cheat.battle 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-033-H | contract | 03_rpc_table / cheat.clearPictures 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-033-S | contract | 03_rpc_table / cheat.clearPictures 返回形状稳定（键集合与值类型固定） | AC-9.3 / v0.6 §2.2 | `Resources/agent_mvmz.js` 的 `cheat.clearPictures` 只返回 `{ok:true}`（键集合恰 1 个） |
| T-033-I | contract | 03_rpc_table / cheat.clearPictures 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-033-N | contract | 03_rpc_table / cheat.clearPictures 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-034-H | contract | 03_rpc_table / cheat.clearEvent 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-034-I | contract | 03_rpc_table / cheat.clearEvent 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-034-N | contract | 03_rpc_table / cheat.clearEvent 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-035-H | contract | 03_rpc_table / cheat.clearMoveRoute 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-035-I | contract | 03_rpc_table / cheat.clearMoveRoute 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-035-N | contract | 03_rpc_table / cheat.clearMoveRoute 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-036-H | contract | 03_rpc_table / cheat.closeAllWindows 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-036-I | contract | 03_rpc_table / cheat.closeAllWindows 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-036-N | contract | 03_rpc_table / cheat.closeAllWindows 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-037-H | contract | 03_rpc_table / cheat.fadeIn 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-037-S | contract | 03_rpc_table / cheat.fadeIn 返回形状稳定（键集合与值类型固定） | AC-9.3 / v0.6 §2.2 | `Resources/agent_mvmz.js` 的 `cheat.fadeIn` 只返回 `{ok:true}`（键集合恰 1 个） |
| T-037-I | contract | 03_rpc_table / cheat.fadeIn 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-037-N | contract | 03_rpc_table / cheat.fadeIn 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-038-H | contract | 03_rpc_table / cheat.recover 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-038-I | contract | 03_rpc_table / cheat.recover 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-038-N | contract | 03_rpc_table / cheat.recover 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-039-H | contract | 03_rpc_table / cheat.repair 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-039-I | contract | 03_rpc_table / cheat.repair 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-039-N | contract | 03_rpc_table / cheat.repair 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-040-H | contract | 03_rpc_table / cheat.fixError 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-040-I | contract | 03_rpc_table / cheat.fixError 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-040-N | contract | 03_rpc_table / cheat.fixError 无 $game* → cheat_unavailable | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-041-H | contract | 03_rpc_table / cheat.devTools 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-041-I | contract | 03_rpc_table / cheat.devTools 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-041-N | contract | 03_rpc_table / cheat.devTools 无 $game* → 已定义的降级结果（不是 cheat_unavailable） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-042-H | contract | 03_rpc_table / cheat.objectPath 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-042-I | contract | 03_rpc_table / cheat.objectPath 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-042-N | contract | 03_rpc_table / cheat.objectPath 无 $game* → cheat_out_of_range | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-043-H | contract | 03_rpc_table / cheat.setObjectPath 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-043-I | contract | 03_rpc_table / cheat.setObjectPath 缺参/类型错误 → 明确错误码 cheat_bad_args | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-043-N | contract | 03_rpc_table / cheat.setObjectPath 无 $game* → cheat_out_of_range | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-044-H | contract | 03_rpc_table / text.scanStart 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-044-I | contract | 03_rpc_table / text.scanStart 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-044-N | contract | 03_rpc_table / text.scanStart 无 $game* → 已定义的降级结果（不是 cheat_unavailable） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-045-H | contract | 03_rpc_table / text.scanCancel 正常入参 → ok:true 且 data 符合契约 | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-045-I | contract | 03_rpc_table / text.scanCancel 缺参/类型错误 → 按实现定义的夹取/忽略规则返回 ok | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-045-N | contract | 03_rpc_table / text.scanCancel 无 $game* → 已定义的降级结果（不是 cheat_unavailable） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-999 | contract | 03_rpc_table / 所有 rpcResult 信封形状一致（id/ok/data/error，失败必带 error.code） | AC-9.3 / v0.6 §2.2 | Resources/agent_mvmz.js：var RPC（45 项） |
| T-998 | contract | 03_rpc_table / [用例表自检] H 维度覆盖 45 个不同方法（无漏项） | AC-9.3 / v0.6 §2.2 | 用例表自检 —— H 分支实际调用过的方法集合 |
| P-01 | contract | 04_safe_path / 深度 2 的合法路径放行（$gameParty._gold） | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-02 | contract | 04_safe_path / 深度 8 通过校验（失败在解析而非深度）：期望 cheat_out_of_range | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-03 | contract | 04_safe_path / 深度 9 被校验拒绝：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-04 | contract | 04_safe_path / 深度 1 被拒绝：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-05 | contract | 04_safe_path / 非 $game*/$data* 根：cheat_forbidden | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-06 | contract | 04_safe_path / 空根（.href）也算非白名单根：cheat_forbidden | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-07 | contract | 04_safe_path / $data* 根放行（$dataItems.1.name） | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-08 | contract | 04_safe_path / 显式列出的 $gameTemp 根放行，值为 null 也能返回 | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-09 | contract | 04_safe_path / __proto__ 段：cheat_forbidden | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-10 | contract | 04_safe_path / constructor 段：cheat_forbidden | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-11 | contract | 04_safe_path / prototype 段：cheat_forbidden | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-12 | contract | 04_safe_path / 禁用段在末位同样被拒绝（不是只查第一段） | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-13 | contract | 04_safe_path / 空串 path：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-14 | contract | 04_safe_path / 非字符串 path：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-15 | contract | 04_safe_path / 尾随点产生的空段不是"禁止段"，按路径不存在处理：cheat_out_of_range | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-16 | contract | 04_safe_path / 写入 string 放行 | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-17 | contract | 04_safe_path / 写入 number 放行 | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-18 | contract | 04_safe_path / 写入 boolean 放行 | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-19 | contract | 04_safe_path / 写入 object 被拒绝：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-20 | contract | 04_safe_path / 写入 array 被拒绝：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-21 | contract | 04_safe_path / 写入 null 被拒绝：cheat_bad_args | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-22 | contract | 04_safe_path / 父路径不存在：cheat_out_of_range | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-23 | contract | 04_safe_path / 被拒绝的写入不得凭空创建中间对象（$gameParty._ghost 仍不存在） | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-24 | contract | 04_safe_path / setObjectPath 同样受深度 8 上限约束 | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-25 | contract | 04_safe_path / 拒绝 __proto__ 写入后，Object.prototype 与引擎对象都未被污染 | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-26 | contract | 04_safe_path / 读到函数时 type=function、value=null（safeValue 不触发 getter/toJSON） | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| P-27 | contract | 04_safe_path / 深度 3 的对象键读得到（$gameParty._items.1 = 3） | AC-9.3（越界不崩） | Resources/agent_mvmz.js：assertSafePath / cheatSetObjectPath |
| E-01 | contract | 05_envelope / 未知 type 被忽略：outbox 不新增任何信封 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-02 | contract | 05_envelope / 未知 type 不记 error（不是异常路径） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-03 | contract | 05_envelope / 未知 type 不污染队列：随后一条 ping 恰好得到 1 条 pong | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-04 | contract | 05_envelope / 非法 JSON 不抛出，转为 1 条 error 信封（code=inbox_error） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-05 | contract | 05_envelope / null / 数字等非对象入站被静默忽略（不产生信封） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-06 | contract | 05_envelope / drain() 单次最多 50 条（第 1 批） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-07 | contract | 05_envelope / drain() 单次最多 50 条（第 2 批） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-08 | contract | 05_envelope / 剩余 20 条在第 3 批取出（120 = 50+50+20） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-09 | contract | 05_envelope / 队列空后再 drain 返回空数组 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-10 | contract | 05_envelope / 分片不改变顺序（首条 r0、末条 r119） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-11 | contract | 05_envelope / 取出 3 条用于回灌（前置） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-12 | contract | 05_envelope / requeue 一批新信封：total=3 accepted=3 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-13 | contract | 05_envelope / 回灌后按原序取回，内容逐条一致 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-14 | contract | 05_envelope / 同一批再回灌一次：accepted=0 duplicate=3（不产生重复投递） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-15 | contract | 05_envelope / 被吸重复的批次不再出现在 outbox | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-14b | contract | 05_envelope / 第三次重放同一批：accepted=0 duplicate=3（去重记忆不被全重复批次清空） | P0-07 / 架构 §6.1、v0.6 §2.2 | D17（`6048d7f`）：全重复批次不改写"最近一次被接受的批次"的签名表 |
| E-16 | contract | 05_envelope / 前置：先回灌 [あ, い] | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-17 | contract | 05_envelope / 部分重复：accepted=1 duplicate=2（新信封照常放回） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-18 | contract | 05_envelope / 部分重复时只把新信封插到队首（上批被吸掉的两条不重复投递） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-19 | contract | 05_envelope / 同一批里出现两条相同签名：只收 1 条 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-20 | contract | 05_envelope / 批内去重保留首次出现的位置 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-21 | contract | 05_envelope / 队列非空时仍接受回灌 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-22 | contract | 05_envelope / 回灌插到队首（最旧的信封先出，文本流不倒退） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-23 | contract | 05_envelope / 非数组 / 非 JSON / null 入参：accepted=0 且不抛错 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-24 | contract | 05_envelope / 非法回灌不破坏已有队列 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-25 | contract | 05_envelope / 空数组：total=0 accepted=0 | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| E-26 | contract | 05_envelope / 出站信封固定带 v=1/type/sessionToken/payload（Host 只认同一个协议版本） | P0-07 / 架构 §6.1、v0.6 §2.2 | Resources/agent_mvmz.js：inbox / drain / requeue |
| SEG-01 | contract | 06_segment_escape / 分句可回拼 "\\C[2]こんにちは" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-02 | contract | 06_segment_escape / 分句可回拼 "\\N[1]は元気" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-03 | contract | 06_segment_escape / 分句可回拼 "\\c[3]こんにちは" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-04 | contract | 06_segment_escape / 分句可回拼 "{勇者|ゆうしゃ}が来た" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-05 | contract | 06_segment_escape / 分句可回拼 "{漢字|かんじ}\\C[2]" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-06 | contract | 06_segment_escape / 分句可回拼 "\\FS[30]大きい" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-07 | contract | 06_segment_escape / 分句可回拼 "\\PX[10]\\PY[20]" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-08 | contract | 06_segment_escape / 分句可回拼 "\\i[17]" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-09 | contract | 06_segment_escape / 分句可回拼 "\\C[2]" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-10 | contract | 06_segment_escape / 分句可回拼 "\\C[2" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-11 | contract | 06_segment_escape / 分句可回拼 "\\{" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-12 | contract | 06_segment_escape / 分句可回拼 "\\\\" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-13 | contract | 06_segment_escape / 分句可回拼 "あ\\C[2]い" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-14 | contract | 06_segment_escape / 分句可回拼 "こんにちは\\N[1]" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-15 | contract | 06_segment_escape / 分句可回拼 "あ\nい" | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-16 | contract | 06_segment_escape / \C[2] 被识别为 code 段，文本段不含控制码 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-17 | contract | 06_segment_escape / \N[1] 被识别为 code 段（人名码） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-18 | contract | 06_segment_escape / 小写码值原样保留（\c[3] 不得上转成 \C[3]） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-19 | contract | 06_segment_escape / 两字母括号码 \FS[30] 被完整识别 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-20 | contract | 06_segment_escape / 连续两个括号码各成一段 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-21 | contract | 06_segment_escape / 纯文本的 mapKey 等于原文 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-22 | contract | 06_segment_escape / 带码行的 mapKey 剥掉控制码 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-23 | contract | 06_segment_escape / 多文本段用 U+001F 连接（与 Host 的 joinForBackend 同形） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-24 | contract | 06_segment_escape / 全 code 段时 mapKey 退回原串（否则会判成 whitespace） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-25 | contract | 06_segment_escape / ruby 记号不是控制码：整串作为文本，不做任何改写 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-26 | contract | 06_segment_escape / ruby 与后继控制码的分段边界正确 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-27 | contract | 06_segment_escape / 只有控制码的行仍是一段 code（不是空数组） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-28 | contract | 06_segment_escape / 全控制码行没有 text 段（lookup 不会尝试替换） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-29 | contract | 06_segment_escape / 未闭合的 \C[2 按文本处理，不被吞掉 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-30 | contract | 06_segment_escape / 空串分句得到空数组（不产生空文本段） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-31 | contract | 06_segment_escape / 空串的 mapKey 是空串 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-32 | contract | 06_segment_escape / skipReasonOf(key="350") = numeric | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-33 | contract | 06_segment_escape / skipReasonOf(key="３５０") = numeric | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-34 | contract | 06_segment_escape / skipReasonOf(key="350 ") = numeric | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-35 | contract | 06_segment_escape / skipReasonOf(key="！？") = punctuation | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-36 | contract | 06_segment_escape / skipReasonOf(key="! ?") = punctuation | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-37 | contract | 06_segment_escape / skipReasonOf(key="♪") = punctuation | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-38 | contract | 06_segment_escape / skipReasonOf(key="★") = punctuation | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-39 | contract | 06_segment_escape / skipReasonOf(key=" ") = whitespace | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-40 | contract | 06_segment_escape / skipReasonOf(key="　") = whitespace | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-41 | contract | 06_segment_escape / skipReasonOf(key="3 5 0") = null | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-42 | contract | 06_segment_escape / skipReasonOf(key="350G") = null | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-43 | contract | 06_segment_escape / skipReasonOf(key="３５０Ｇ") = null | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-44 | contract | 06_segment_escape / skipReasonOf(key="ＯＫ") = null | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-45 | contract | 06_segment_escape / skipReasonOf(key="10秒後") = null | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-46 | contract | 06_segment_escape / skipReasonOf(key="350") = numeric | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-47 | contract | 06_segment_escape / 空串不产生 text 事件（也不记 error） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-48 | contract | 06_segment_escape / 空串路径不增加 state.errors | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-49 | contract | 06_segment_escape / 6000 字超长句原样 emit（长度未被截断） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-50 | contract | 06_segment_escape / ruby 行原样 emit 且判为待翻译 | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| SEG-51 | contract | 06_segment_escape / 带人名码的行：raw 原样、key 剥码（原文列与控制码都不丢） | P0-08、P0-09 / PRD §5.1、架构 §8 | Resources/agent_mvmz.js：splitSegments / mapKeyOf / skipReasonOf |
| A1 | contract | 07_dedupe_race / 同帧 350 + \C[2]350 各得 1 条（身份=surface+raw，不是 mapKey） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A2 | contract | 07_dedupe_race / 同帧同一 raw 连画 10 次只 emit 1 条（防重绘风暴） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A3 | contract | 07_dedupe_race / 间隔 1600ms 后再画同一 raw 新增 1 条（不是永久去重） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A4 | contract | 07_dedupe_race / 持续可见（8×400ms）只 1 条（按滑动窗口抑制，不是按帧分桶） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A5 | contract | 07_dedupe_race / 续期：8×400ms 后 +100ms 再画仍不新增（不续期的实现会多 1 条，距首次已 > 800ms） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A6 | contract | 07_dedupe_race / 交错 A,B,A,B（100ms）得 2 条（抓"全局单一 lastSeen"） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A7 | contract | 07_dedupe_race / 同 raw 不同 surface 各得 1 条（身份=surface+raw 的组合） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A8 | contract | 07_dedupe_race / 窗口基准：首次绘制立即上报 | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A9 | contract | 07_dedupe_race / 距上次 < 800ms：抑制（且续期） | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A10 | contract | 07_dedupe_race / 若未续期此刻已距首次 1400ms，会误报；续期后仍抑制 | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| A11 | contract | 07_dedupe_race / 真正离开窗口（> 800ms 无重绘）后再现，重新上报 1 条 | P0-08 / AC3.1 | Resources/agent_mvmz.js：shouldEmitFor |
| V4-1a-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1a-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1b-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1b-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1c-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1c-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1d-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1d-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1e-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1e-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1f-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-1f-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2a-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11a-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2a-B | contract | 08_skip_emit / 面B status=skipped/numeric 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2b-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11b-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2b-B | contract | 08_skip_emit / 面B status=skipped/punctuation 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2c-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11c-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2c-B | contract | 08_skip_emit / 面B status=skipped/whitespace 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2d-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11d-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2d-B | contract | 08_skip_emit / 面B status=skipped/numeric 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2e-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11e-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-2e-B | contract | 08_skip_emit / 面B status=skipped/numeric 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-3a-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11g-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-3a-B | contract | 08_skip_emit / 面B status=skipped/numeric 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-3b-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-3b-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-4a-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-4a-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5a-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5a-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5b-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5b-B | contract | 08_skip_emit / 面B status=pending 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5c-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-11f-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5c-B | contract | 08_skip_emit / 面B status=skipped/punctuation 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5d-A | contract | 08_skip_emit / 面A 恰好 1 条 text、raw 逐字节保留、emitted +1 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| V4-5d-B | contract | 08_skip_emit / 面B status=skipped/punctuation 且 skipped 计数正确 | P0-08、P0-09 / PRD §5.1（BUG-7） | Resources/agent_mvmz.js：collect |
| C1 | contract | 09_lookup_variant / 纯文本译文 + 带码行：本行码值必须保留 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C1-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=0 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C2 | contract | 09_lookup_variant / 反向顺序：下发的是带码行，画无码行 → 不得凭空加色 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C2-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=0 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C3 | contract | 09_lookup_variant / 同文本不同码：\C[3] 不得沿用先前的 \C[2] | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C3-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=0 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C4 | contract | 09_lookup_variant / 小写码保留原大小写：\c[2] 不得被上转成 \C[2] | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C4-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=0 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C5 | contract | 09_lookup_variant / 人名码（最高危害样本）：\N[2] 不得被画成 \N[1] | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C5-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=0 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C6 | contract | 09_lookup_variant / 段数不匹配 → 拒绝拼接，画原文（码值一个都不许变） | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C6-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=1 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C7 | contract | 09_lookup_variant / 旧条目无 segments 字段：走 v0.2 兼容路径（translatedRaw） | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C7-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=1 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C8 | contract | 09_lookup_variant / 无该 key：不改写，画原文 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C8-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=0 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C9 | contract | 09_lookup_variant / 人名不串行（病态数据）：段数不符 → 画 \N[2] 原文，绝不画 \N[1] | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| C9-state | contract | 09_lookup_variant / 状态不变量：errors=0、mergeFallback=1 | P0-09 / BUG-11、架构 §6.3 | Resources/agent_mvmz.js：lookup / mergeBySkeleton |
| S-00 | contract | 10_skip_parity / Swift 侧打印了全部 9 个样例 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-01 | contract | 10_skip_parity / "350" 期望=skip，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-02 | contract | 10_skip_parity / "！？" 期望=skip，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-03 | contract | 10_skip_parity / "! !" 期望=skip，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-04 | contract | 10_skip_parity / "　" 期望=skip，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-05 | contract | 10_skip_parity / "10秒後" 期望=translate，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-06 | contract | 10_skip_parity / "\\C[2]350" 期望=skip，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-07 | contract | 10_skip_parity / "3 5 0" 期望=translate，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-08 | contract | 10_skip_parity / "\\c[3]350" 期望=skip，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S-09 | contract | 10_skip_parity / "\\i[17]" 期望=translate，两端一致 | 架构 §7.7（双端一致） | Sources/Domain/Segmenter.swift:SkipRules ↔ agent_mvmz.js |
| S1 | contract | 11_store / A 组：350 与 \C[2]350 同帧同 cacheKey → 2 行 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S2a | contract | 11_store / B 组：こんにちは 与 \C[2]こんにちは 同帧 → 2 行 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S2b | contract | 11_store / 一条译文扇出到两行（都 translated，无 pending 残留） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S2c | contract | 11_store / 一次结果只计一次（stats.fresh == 1，不重复计费） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S3 | contract | 11_store / 401 路径两行都进 error，不得留一行 pending | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S4 | contract | 11_store / 同一身份 3 条事件（间隔 2000ms > 800ms）→ 3 行，occurrences 1/2/3 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S5a | contract | 11_store / 插入 5001 条 → 只保留 5000 行 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S5b | contract | 11_store / 重新出现被淘汰的身份 → occurrences 按保留行重算 = 1（不得为 2） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S6 | contract | 11_store / clear 后 rows=0，再采同一身份 occurrences 从 1 开始 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S7 | contract | 11_store / 同帧同一身份连画 10 次（Agent 不会发出的形态）→ 1 行且 occurrences=1（PRD AC3.1-b） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| W1 | contract | 11_store / Store：同身份 8×400ms（持续可见）→ 1 行（AC3.1-b） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| W4a | contract | 11_store / Store：间隔 700ms（窗内）→ 1 行 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| W5 | contract | 11_store / Store：8×400ms 后 +100ms 再画（续期）→ 1 行 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| W6 | contract | 11_store / Store：A/B 交错（窗内）→ 2 行（A、B 各 1） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| R0a | contract | 11_store / ts 不可用 + 同帧同身份重复观测 → 1 行且 occurrences=1（严格同帧签名去重） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| R0b | contract | 11_store / ts 不可用 + 跨帧同身份 → 新行（rows=2，occurrences 1/2） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| R2 | contract | 11_store / 回拨 90000ms（< -60000）→ 时钟基重置，按新行处理（rows=2，occurrences 1/2） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| R3 | contract | 11_store / 回拨 10000ms（-60000 ≤ delta < 0）→ 抑制合并，occurrences 不变、lastSeenTs 不回退 | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S8a | contract | 11_store / 首行保留自己的 \N[1]（不得被改写） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S8b | contract | 11_store / 次行必须用自己的 \N[2]，不得复用首行的 \N[1] | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S8c | contract | 11_store / 两行都 translated（扇出仍然生效，不退化成一等一） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S8d | contract | 11_store / translatedSegments 与显示串同源（都按本行骨架） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S9a | contract | 11_store / 段数不符的次行落 error（不得静默 pending） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S9b | contract | 11_store / 次行不得出现首行码值 \N[1]（不串人名） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| S9c | contract | 11_store / 首行仍正常（本行骨架能对上） | P0-08 / AC2.2b、AC3.1（BUG-8/11 Host 侧） | Sources/Domain/TextStreamStore.swift |
| V4S-1a | contract | 12_domain_qa / SkipRules("今日は8月15日です") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-1b | contract | 12_domain_qa / SkipRules("宝箱が3つある") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-1c | contract | 12_domain_qa / SkipRules("HPは100/100") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-1d | contract | 12_domain_qa / SkipRules("10秒後") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-1e | contract | 12_domain_qa / SkipRules("第2章") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-1f | contract | 12_domain_qa / SkipRules("350G") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-2a | contract | 12_domain_qa / SkipRules("350") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-2b | contract | 12_domain_qa / SkipRules("！？") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-2c | contract | 12_domain_qa / SkipRules(" ") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-2d | contract | 12_domain_qa / SkipRules("３５０") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-2e | contract | 12_domain_qa / SkipRules("350 ") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-5a | contract | 12_domain_qa / SkipRules("３５０Ｇ") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-5b | contract | 12_domain_qa / SkipRules("ＯＫ") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-5c | contract | 12_domain_qa / SkipRules("♪") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-5d | contract | 12_domain_qa / SkipRules("★") | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-3a | contract | 12_domain_qa / \C[2]350 剥码后判为跳过 | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-3b | contract | 12_domain_qa / \C[2]350 分段原样可回拼 | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-3c | contract | 12_domain_qa / \C[2]10秒後 不得跳过 | PRD §5.1 / 架构 §7.7 | Sources/Domain/Segmenter.swift:SkipRules |
| V4S-4a | contract | 12_domain_qa / SkipRules 对「350 」与归一化后的键给出相同跳过判定 | PRD §5.1 / 架构 §7.7 | `Sources/Domain/Segmenter.swift:SkipRules`（两条入参同判；缺陷回归由 V4S-2e 钉住） |
| V4S-6a | contract | 12_domain_qa / 跳过句不产生缓存条目 | P0-10 / PRD §5.1 | TranslationPipeline + SkipRules（跳过不写缓存/不打后端） |
| V4S-6b | contract | 12_domain_qa / 跳过句不触发后端调用 | P0-10 / PRD §5.1 | TranslationPipeline + SkipRules（跳过不写缓存/不打后端） |
| V6-01 | contract | 12_domain_qa / detect(e_mz) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-02 | contract | 12_domain_qa / detect(e_mv) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-03 | contract | 12_domain_qa / detect(Sample.app) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-04 | contract | 12_domain_qa / detect(e_renpy) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-05 | contract | 12_domain_qa / detect(e_krkr) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-06 | contract | 12_domain_qa / detect(e_easyrpg) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-07 | contract | 12_domain_qa / detect(e_rgss3) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-08 | contract | 12_domain_qa / detect(e_tyrano) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-09 | contract | 12_domain_qa / detect(e_wolf) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-10 | contract | 12_domain_qa / detect(e_unity) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-11 | contract | 12_domain_qa / detect(e_godot) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-12 | contract | 12_domain_qa / detect(e_siglus) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-13 | contract | 12_domain_qa / detect(e_conflict) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-14 | contract | 12_domain_qa / detect(e_empty) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-15 | contract | 12_domain_qa / detect(e_file.txt) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-16 | contract | 12_domain_qa / detect(e_easyrpg_partial) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-17 | contract | 12_domain_qa / detect(e_rgss2) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-18 | contract | 12_domain_qa / detect(e_scenepck) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-19 | contract | 12_domain_qa / detect(e_godotpck) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-20 | contract | 12_domain_qa / detect(e_index) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-21 | contract | 12_domain_qa / detect(e_rgss_lower) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-22 | contract | 12_domain_qa / detect(e_rgss_upper) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-23 | contract | 12_domain_qa / detect(e_hidden) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-24 | contract | 12_domain_qa / detect(Sample.app) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V6-25 | contract | 12_domain_qa / detect(e_tyrano_partial) | AC1.1–1.3 / PRD §A.1 | Sources/Adapters/EngineDetector.swift |
| V5-01 | contract | 12_domain_qa / /401 | P0-12 / AC3.3 | Sources/Infra/Translators.swift + Tests/qa/error_server.py |
| V5-02 | contract | 12_domain_qa / /429 | P0-12 / AC3.3 | Sources/Infra/Translators.swift + Tests/qa/error_server.py |
| V5-03 | contract | 12_domain_qa / /500 | P0-12 / AC3.3 | Sources/Infra/Translators.swift + Tests/qa/error_server.py |
| V5-04 | contract | 12_domain_qa / /nonjson | P0-12 / AC3.3 | Sources/Infra/Translators.swift + Tests/qa/error_server.py |
| V5-05 | contract | 12_domain_qa / /slow | P0-12 / AC3.3 | Sources/Infra/Translators.swift + Tests/qa/error_server.py |
| CFG-01 | contract | 13_config_agent / P0-14 默认开关与缩放值：enabled=true、fontScale=1.0（agent_mvmz.js:71-72） | P0-14 / P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-02 | contract | 13_config_agent / P0-14 基线阳性对照：开启时缓存句命中并显示译文 | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-03 | contract | 13_config_agent / P0-14 基线计数：一次绘制 emitted=1、replaced=1 | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-04 | contract | 13_config_agent / P0-14 config.enabled=false 立即生效（probe().enabled=false） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-05 | contract | 13_config_agent / P0-14 关闭后画面显示原文（已缓存句子也不替换） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-06 | contract | 13_config_agent / P0-14 关闭后文本流继续采集（emitted 照常 +1，对应 UI「已暂停」） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-07 | contract | 13_config_agent / P0-14 关闭后不执行替换（replaced 不增、errors=0） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-08 | contract | 13_config_agent / P0-14 关闭后绘制参数未被改写（contents.fontSize 仍 24） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-09 | contract | 13_config_agent / P0-14 关闭期间新句子同样画原文 | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-10 | contract | 13_config_agent / P0-14 关闭期间新句子仍进入采集队列（emitted 再 +1） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-11 | contract | 13_config_agent / P0-14 config.enabled=true 立即生效 | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-12 | contract | 13_config_agent / P0-14 重开后此前已缓存的句子立即可用（无需等新一轮翻译） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-13 | contract | 13_config_agent / P0-14 重开后替换恢复（replaced +1） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-14 | contract | 13_config_agent / P0-14 全程 errors=0（开关切换不产生异常路径） | P0-14 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-15 | contract | 13_config_agent / P0-15 前置：窗口初始字号 24（缩放基准） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-16 | contract | 13_config_agent / P0-15 fontScale=0.8 下发生效 | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-17 | contract | 13_config_agent / P0-15 0.8 倍在绘制层生效：24×0.8=19.2→19（下限边界） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-18 | contract | 13_config_agent / P0-15 绘制结束后字号复原为 24（hook 的 finally） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-19 | contract | 13_config_agent / P0-15 fontScale=1.3 下发生效 | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-20 | contract | 13_config_agent / P0-15 1.3 倍在绘制层生效：24×1.3=31.2→31（上限边界） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-21 | contract | 13_config_agent / P0-15 1.3 倍绘制后同样复原为 24 | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-22 | contract | 13_config_agent / P0-15 fontScale=1.0 时不缩放（分支不进入） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-23 | contract | 13_config_agent / P0-15 fontScale=0 被忽略（agent_mvmz.js:2358 要求 >0） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-24 | contract | 13_config_agent / P0-15 越界 9.0 下仍能正常绘制（不抛异常、不改写文本）[GAP-P0-15] | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-25 | contract | 13_config_agent / P0-15 越界值下 errors=0 且绘制真的到达引擎（夹取在上游 Swift） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| CFG-26 | contract | 13_config_agent / P0-15 全程 errors=0（PRD「不出现文本绘制异常」的可观测面） | P0-15 | docs/prd.md:149-150（P0-14/P0-15 原文）；Resources/agent_mvmz.js:71-72/728-745/2092-2094/2357-2358 |
| AD-1 | contract | 15_agent_diag / 首条 `start_message_miss` → `emit(info)` 且 count=1（诊断首发必须可见） | 可观测性（架构 §3.3 code 约定） | `Sources/Infra/Stores.swift` 的 `AgentDiagGate.consume`；提交 94ef649 |
| AD-2 | contract | 15_agent_diag / #2…#199 共 198 条全部 `drop`（节流生效，不淹日志） | 可观测性（架构 §3.3 code 约定） | 同上（节流阈值与 `protocolMismatchDropped` 一致） |
| AD-3 | contract | 15_agent_diag / 第 200 条补一行 `emit(info)`，count=200（计数不静默） | 可观测性（架构 §3.3 code 约定） | 同上 |
| AD-4 | contract | 15_agent_diag / 非诊断 code 恒 `emit(warn)`，且不消耗节流计数（真故障不被诊断流量挤掉） | 可观测性（架构 §3.3 code 约定） | 同上 |
| AD-5 | contract | 15_agent_diag / `reset()` 后回到"首条立即报"（count 归零，与 `start()` 绑定） | 可观测性（架构 §3.3 code 约定） | 同上；`SessionController.start()` 调 `diagGate.reset()` |

---

## 领域层（domain）

入口：`bash Tests/e2e/run.sh --suite domain` —— **13 cases / 348 assertions**，实测末行
`E2E PASS suite=domain cases=13 assertions=348`。

约束：零 npm 依赖（只用 Node 内置模块 + `swiftc`）；每个 case 一个独立 node 子进程 +
独立 `mkdtemp` 工作目录，结束即删，**不读** `~/Library/Application Support`；
Swift 探针现编现跑（二进制落 mkdtemp，用完即删，避免"旧二进制掩盖编译失败"）。
**默认不需要 Aqua 桌面**：D1–D8 全部无 GUI；只有 D9 要起真会话，无桌面时打 SKIP，不算失败。

这一层的存在理由：审计确认 20 条 P0 里有 10 条零自动断言，其中 9 项不需要图形界面。
这里把"能自动化的那一半"补齐；**不可测 / 未实现的那一半逐条列在表下的 GAP 段**，
不写假断言、也不把"跑出来是什么"抄成期望值。

| 用例ID | 断言数 | 覆盖的 P0/AC | 关键断言 | 依据 |
| --- | --- | --- | --- | --- |
| D1 `01_library_persist` | 27 | P0-04 | 两条记录重载后 `id/name/path/engine/addedAt` 逐字段不变、顺序稳定；截断与非法 JSON 都 → 空库 + `library.json.bak-<ts>`（备份内容 = 损坏前原始字节）；目录移走后条目仍在；`missing` 可落盘且 `isLaunchable=false`；同秒连续两次损坏留 2 份备份（内容分别为 A/B，不覆盖） | PRD P0-04；`Sources/Infra/Stores.swift:497-530` |
| D2 `02_settings_persist` | 24 | P0-20 | 原子写后可完整解析、无 `.tmp-` 残留；字段缺失 / 类型非法 / 越界三类输入都回落默认（越界另记日志）；文件损坏 → 默认值；目录只读 → `io_error` 且旧文件内容不变 | PRD P0-20；`Stores.swift:94-100`（atomicWrite）、`:567-580`（saveSettings） |
| D3 `03_secret_mask` | 21 | P0-12 | `sk-` / `Bearer` / `DeepL-Auth-Key` 三种形态一律 → `sk-…后4位`；原文不出现；幂等；`MochiBoxError.rawSnippet` 构造即脱敏；日志落盘脱敏；`settings.json` / `credentials.json` / 日志都是 0600（stat）；短 key `sk-abc` → `***`（左边界：普通单词里的 sk- 不误伤） | PRD P0-12；`ErrorModels.swift:227-295`；`Stores.swift:567/585`（0o600）、`:190`（日志 0600） |
| D4 `04_session_log` | 19 | P0-19 | 文件名严格 `session-yyyyMMdd-HHmmss.log`（全角数字拒绝）；首行 `userAttestsOwnership=true`；55 份 → 50 份、只删最旧 6 份、非会话文件不动；`deleted=6` / `kept=50` 入日志；`minLevel` 过滤 | PRD P0-19；`Stores.swift:151/258-279`；`Constants.swift:200`（50） |
| D5 `05_resilience` | 31 | P0-13 | 50 条 → 6 次后端请求、单次 ≤10（maxBatch/并发）、峰值并发 ≤2、总条数 50、`timeoutMs=15000`；合并窗口实测 ≥110ms；重试 1+3 次 / 不可重试 1 次 / 空退避表 1 次；熔断 4 次不打开、第 5 次打开、29s 不可试探、30s 半开、成功清除；`circuit_open.retryable=false`；管线级熔断后零后端调用、结果 items 为空且队列不被消费（冷却后仍能翻译） | PRD P0-13；`Translators.swift:437-497`；`TranslationPipeline.swift:73-410` |
| D6 `06_passthrough` | 16 | P0-11 | 默认后端 = passthrough（`Settings` 默认 + `AttachCLI.swift:109`）；provider 与管线两层译文与原文**逐字节**相等（含 `\C[2]` 与 U+001F）；零 provider 调用、零缓存写入、本地监听器收到 0 个请求；合规开关 `allowSendTextToBackend=false` 强制直通 | PRD P0-11；`Translators.swift:175-190` / `:416-434`；`Stores.swift:408-411`（effectiveBackend） |
| D7 `07_cache_capacity` | 23 | P0-10 | 超限按 lastUsed（最久未用）淘汰、命中刷新使用时刻、内存只留 maxEntries、`evicted=1` 入日志、磁盘 jsonl 仍 4 行；重启后重新裁到上限；命中率 0%/20%/50%/75%/100% 与分母为 0 的 0%；缓存文件 0600；命中后再超限淘汰的是次久未用项（LRU 而非 FIFO） | PRD P0-10；`Stores.swift:589/678/785`；`StoreModels.swift`（CacheStats.hitRate） |
| D8 `08_fulltext_roundtrip` | 44 | AC-10.3 / AC-10.4 | `ManualTransFile.json` 是纯 `{原文:译文}`（顶层键 = 原文、无外壳、UTF-8 不转义、两次导出逐字节相同）；导出 → 导入映射逐条相等（diff 为空）；导入 4 对 → `accepted=2/untranslated=2`；语料未译条数 3 → 1；冲突 = 1 且人工优先；导出到游戏目录留 `.bak`；`fulltext/<gameHash>.json` 0600 / 目录 0700 / 过滤空值 / 损坏隔离 / 缺失 nil；目录已存在（0755）时 save 仍收紧到 0700 | PRD §3.4 AC-10.3/10.4；`FullTextStore.swift:106-250`；`FullTextModels.swift:33` |
| D9 `09_game_dir_untouched` | 13 | AC-10.5 | 运行前/后全目录逐文件 sha256 + 文件集合 + 汇总摘要完全一致；新增/删除/修改三条分别断言为空；未点导出时游戏目录没有 `ManualTransFile.json`；阳性对照：会话内采集 1 句且 exit 0（否则"目录没变"可能只是"什么都没跑"） | PRD AC-10.5；`FullTextStore.swift:8-10` |

合计 348 条断言。D9 无 Aqua 时打 `SKIP`（沿用 kernel 层的 `skipForNoAqua` 出口），
整层仍算通过 —— **SKIP 既不算通过，也不算失败**。

### GAP（未实现 / 不可测的那一半）

| 编号 | 需求原句 | 现状与原因 | 本层如何处理 |
| --- | --- | --- | --- |
| `GAP-P0-04` | P0-04："用户手动移走游戏目录后重启，条目仍在但标记 `missing`" | 自动打标记在 `SessionController.refreshMissingFlags()`（`SessionController.swift:838`，**private**），只有 `AppState.init`（`:800`）会调用；`AppState` 依赖整条适配器链（CDPClient / StaticWebServer / WK…），本层不为了测试去拼一个 AppState | 只断言"条目仍在 + `missing` 可落盘 + `isLaunchable=false`"；自动标记列为缺口 |
| `GAP-P0-19` | P0-19："日志滚动保留 5 个 × 上限 2MB" | 实现是**按份数**保留 `K.logRetentionCount=50`，没有按大小滚动；`Constants.swift:200` 的注释说明这是 v0.6 的有意替换（文件名带秒级时间戳，一次启动一份，无界增长的是份数） | 按源码常量断言份数语义，并单独断言"单份 >2MB 不触发滚动"，把偏差钉成可复核事实 |
| D5 不可测半句 | P0-13："429/5xx/网络错误重试 3 次（指数退避 0.5s/1s/2s）"、"30 秒后半开重试"、"单请求超时默认 15s" | 产品的退避用 `Task.sleep`、熔断用 `Date()`，**没有可注入的全局时钟**，真实等待 3.5s / 30s 不可控 | 用产品自带的接缝：`ResiliencePolicy.retryDelaysMs` 注入等长三档（30/30/30）验证"确实重试 3 次"、`CircuitBreaker.canAttempt(now:)` 注入时刻验证"29s 不可试探 / 30s 半开"；真实常量 500/1000/2000 与 30 单独断言。**真实 15s 网络超时未触发**（只断言 `request.timeoutMs=15000`）；超时 → `timeout` 的映射由 contract `V5-05` 覆盖 |

> `GAP-P0-12`（短 `sk-` 不脱敏）已随 D19 修复关闭（`e091c6e`），不再是缺口。

### 本层新发现（2026-10-23 已全部修复）

| 编号 | 位置 | 现象 | 影响 |
| --- | --- | --- | --- |
| F-1 | `ErrorModels.swift:250`（`sk-[A-Za-z0-9_-]{8,}`） | 少于 8 字符的 `sk-…` 串不匹配、保持明文 | 弱/占位 key 会整条出现在日志与诊断导出里，与 P0-12"一律脱敏"不一致 |
| F-2 | `Stores.swift:505-515`（LibraryStore.load） | 备份名只精确到秒，且 move 前先 `removeItem(at: backup)` | 同一秒内两次损坏 → 第二次覆盖第一次的 `.bak`，前一份证据丢失 |
| F-3 | `Stores.swift:785`（evictIfNeeded） | 淘汰按 `entry.ts`（写入时刻）排序，`get()` 不回写 ts | 实际是 FIFO 而非 LRU；与 P0-10"按最久未用淘汰"的字面语义有差距（日志文案也写"最久未用"） |
| F-4 | `FullTextStore.swift:129`（ensureDirectory） | `createDirectory(attributes: 0o700)` 只在**首次创建**时生效；目录已存在（如 0755）时不会收紧 | 旧版本/手工建过 `fulltext/` 的机器上，全文译文目录仍对同机其它账户可读 |

上表四条即 backlog 的 D19–D22，修复 commit 与回归断言见文末「已修复缺陷登记」；
矩阵里对应的缺口已关闭并绑定断言 ID，不再作为缺口计数。

---

## 内核层（kernel）

入口：`bash Tests/e2e/run.sh --suite kernel` —— **14 cases / 165 assertions**，实测末行
`E2E PASS suite=kernel cases=14 assertions=165`。

约束：每个 case 一个独立 node 子进程、独立 `MOCHI_DATA_DIR`、独立控制 socket（`--control`），
退出即回收（SIGTERM → SIGKILL），不依赖执行顺序；需要**已登录的 Aqua 桌面**（无桌面时
`run.sh` 打印 `SKIP suite=kernel reason=kernel_reason=no_aqua` 并跳过，不算失败）。
被测二进制：`build/MochiBox.app/Contents/MacOS/MochiBox`（`bash Scripts/build.sh`）。

| 用例ID | 断言数 | 覆盖的 P0/AC | 关键断言 | 依据 |
| --- | --- | --- | --- | --- |
| K1 `01_startup` | 11 | P0-05 / P0-06 / AC1.1 | `play: http=<port> … kernel=embedded content=816x624` 可解析；端口 ∈ 39310–39409；`title` 等于 `System.json` 的 `gameTitle`；场景探针到 `Scene_Map`；`quit` 后 exit 0 | PRD P0-05（端口须先确认可用）、P0-06（attach 后给出页面 URL）；`Fixtures/e2e_game/js/System.json` |
| K2 `02_agent_injection` | 12 | P0-07 | hello 的 hooks 恰四条且与 `probe.hooks` 顺序一致；页面 `__mochibox.version` 等于 `Resources/agent_mvmz.js` 的 `VERSION`；`probe.errors=0`；退出时仍 installed 且 hooks 完整 | PRD P0-07（注入幂等、探针字段）；`Resources/agent_mvmz.js:var VERSION` |
| K3 `03_capture_translate` | 18 | P0-08 / P0-09 / AC2.2c | 三句 `__e2e.push` → `captured=3 translated=3 skipped=0`；`--out` 三条按推送顺序、`status=translated`、`translated === "译:" + original`；`ts` 非递减；mock 后端至少收到 1 个请求 | PRD P0-08（每个绘制串 1 条 TextEvent）、AC2.2c（mock 后端 1s 内新译）、§5.4 |
| K4 `04_skip_rules` | 19 | P0-09 / §5.1 | `350`、`！？`、全角空格三句 `captured=3` 但 `skipped=3 translated=0`；`--out` 三条都在（跳过句不得消失）；`skipReason` 分别为 `numeric`/`punctuation`/`whitespace`；跳过项**不得写 `translated` 字段** | PRD P0-09 两条锚定正则 + §5.1（跳过项不写缓存、不得假译文） |
| K5 `05_dedupe_window` | 6 | P0-08 / AC3.1 | 800ms 窗内重复推送只 1 条；跨窗后再推产生第 2 条；两条 `ts` 间隔 ≥800ms | PRD P0-08（滑动续期去重）、AC3.1 a/b（窗内抑制、窗外必新增） |
| K6 `06_translation_cache` | 11 | P0-10 | 同一进程内重复句命中缓存时 mock 请求数不增加；重启后仍请求后端（实测 `--play` 无跨进程缓存） | PRD P0-10 只要求「同一 key 第二次不发 HTTP」；跨进程缓存属 P1-10，未纳入 P0 判据 |
| K7 `07_cheat_rpc` | 12 | AC-9.1 / AC-9.3 | `setGold/setSwitch/setVariable` 后用**另一次 evaluate** 读 `$gameParty.gold()` / `$gameSwitches.value(5)` / `$gameVariables.value(3)` 均为新值；未知方法 `ok=false` 且 `code=rpc_unknown_method` | PRD §3.4 AC-9.1（修改器生效）、AC-9.3（RPC 契约） |
| K8 `08_idempotent_restore` | 13 | P0-07 | 二次 `install()` 后 hooks 仍四条且 `errors=0`；`uninstall()` 后四个 hook 恢复**同一引用**；再次 `install()` 仍能装回 | PRD P0-07 修订（四）：uninstall 后重新注入仍能采集且 hook 不叠加 |
| K9 `09_window_close` | 8 | P0-16 / AC2.4 | 采集 1 句后 control `quit` → `play: window_closed=1`、exit 0、socket 文件已删除、报告行 `captured=1 translated=1` | PRD P0-16（停止与清理）、AC2.4（停止后进程退出） |
| K10 `10_no_browser` | 7 | P0-06 / 架构 §6 | `MOCHI_BROWSER_PATH` 指向无效路径时仍 `kernel=embedded`、无 `browser_not_found`、采集照常完成；**被测进程的子孙**里没有 Chrome/Chromium（就绪时与采集期间各取一次） | 架构 §6（WKWebView 内嵌内核，不依赖外部浏览器）；P0-06 |
| K12 `12_draw_parity` | 15 | P0-09 / P0-15 / P0-08 | 一页 3 句 → `drawLog` 最后 3 条绘制文本 = `"译:" + 原文`；绘制次数 ≥ 采集数；绘制字号 = `round(28 × fontScale)`；`enabled=false` 时画原文（阴性对照） | PRD P0-09（回绘的是译文）、P0-15（绘制层字号）；`Fixtures/e2e_game/engine_stub.js` 的 `__e2e.render()`/`drawLog` |
| K11 `11_control_codes` | 14 | P0-09 / §5.4 | `key` 只由 text 段组成（控制码剥离）；`\C[2]…\C[0]…\N[1]…` 分成 3 text + 3 code；译文回填 text 段，`\C[2]` 仍在行首、`\N[1]` 仍紧邻原文修饰的「だ」 | PRD P0-09（转义码位置不变）、§5.4（段数一致时按原段位重组） |
| K13 `13_control_large` | 7 | P0-16 / 控制通道 | 20000 / 12000 字符应答**完整送达**（旧实现单次 write 截在 8192）；大应答之后的下一请求仍能正常配对；quit 后 exit 0 | 提交 02a9d59（控制通道写满为止）；`Sources/Adapters/Control/ControlServer.swift` |
| K14 `14_message_partial` | 12 | P0-09 / §5.6（Host 分流见 contract `15_agent_diag` / AD-1…AD-5） | 一页 `['？？？','こんにちは']` → `$gameMessage._texts` 第 0 行保持 `？？？`、第 1 行变成译文、长度不变；`enabled=false` 后**逐字还原**本页原文、重新开启后仍能替换；整页纯标点一行都不改（`anyText` 守卫）；`probe.errors=0` | 提交 8778dc7（逐行降级）；`Resources/agent_mvmz.js` 的 `hookStartMessage` |

合计 162 条断言。无 Aqua 时整层 SKIP（`cases=0 assertions=0`），**不产生假绿**。

## 故障层（faults）

入口：`bash Tests/e2e/run.sh --suite faults` —— **10 cases / 55 assertions**，实测末行
`E2E PASS suite=faults cases=10 assertions=55`。

判据不是「退出码非 0」，而是四条同时成立：不崩（无信号 / 无 fatal error）、`translate failed:
<期望码>`、报告行 `captured=1 translated=0`、mock 确实收到过请求。只看退出码会把 attach 失败、
参数错误也当成后端故障。

| 用例ID | 断言数 | 覆盖的 P0/AC | 关键断言 | 依据 |
| --- | --- | --- | --- | --- |
| F1 `01_backend_401` | 5 | P0-12 / AC3.3 | `translate failed: auth_failed`；exit 1；`captured=1 translated=0`；mock 收到请求；无崩溃标记 | PRD P0-12 + §3.2 C 组失败样本（401 → `auth_failed`，`retryable=false`） |
| F2 `02_backend_429` | 5 | P0-12 / P0-13 | `translate failed: rate_limited`；exit 1；`captured=1 translated=0`；mock 收到请求；无崩溃标记 | PRD P0-12 + §3.2 C 组（429 → `rate_limited`，`retryable=true`，P0-13 决定重试） |
| F3 `03_backend_500` | 5 | P0-12 / P0-13 | `translate failed: bad_response`；exit 1；`captured=1 translated=0`；mock 收到请求；无崩溃标记 | PRD §3.2 C 组：500 归 `bad_response`（`retryable=true`），不另立错误码 |
| F4 `04_backend_nonjson` | 5 | P0-12 | `translate failed: bad_response`；exit 1；`captured=1 translated=0`；mock 收到请求；无崩溃标记 | PRD §3.2 C 组：非 JSON 与 500 同归 `bad_response`，差异进 `detail`（禁止凑「六个 code」） |
| F5 `05_endpoint_dead` | 4 | P0-12 / P0-17 | 回环端口无监听 → `translate failed: network`；exit 1；`captured=1 translated=0`；无崩溃标记 | PRD §3.2 C 组网络错误；P0-17（网络不可用时不得崩） |
| F6 `06_missing_index` | 6 | P0-05 | exit 3（环境缺口，**不是**后端失败）；`error_code: web_root_missing`；`play: environment=web_root_missing`；engine 仍识别为 mz | PRD P0-05「启动失败按两种情形分别验收」：环境缺失与运行失败要分开 |
| F7 `07_unknown_engine` | 6 | P0-03 / P0-05 | exit 3；`engine=unknown`；`error_code: launcher_no_executable`；`play: environment=launcher_no_executable` | PRD P0-03（无特征 → `unknown`）与 P0-05（无可执行文件属环境缺口） |
| F8 `08_control_gate` | 4 | 架构 §6 / P0-19 | 未设 `MOCHI_E2E=1` 时 `--control` → exit 2、`error_code: control_requires_e2e`，且没有 `play: http=`、没有 socket 文件 | 架构 §6：控制通道是测试专用入口，生产路径不得开启 |
| F9 `09_control_missing_arg` | 3 | 架构 §6 | `--control` 缺值 → exit 2；stderr 打印用法；参数错误时不启动会话 | 架构 §6（参数校验先于建窗口） |
| F10 `10_port_busy` | 11 | P0-05 | 候选端口被占时自动绕开且新端口仍落 39310–39409 并可正常采集；区间内 100 个端口全占 → exit 3 + `port_unavailable` | PRD P0-05（端口从区间选取且**启动前确认可用**）；`Sources/Adapters/Launcher/WebPortAssignments.swift` |

合计 55 条断言。无 Aqua 时整层 SKIP（`cases=0 assertions=0`）。

## 真游戏层（game）

入口：`MOCHI_E2E_GAME=<游戏目录> bash Tests/e2e/run.sh --suite game` —— **2 cases / 11 assertions**
（实际跑时）。未设 `MOCHI_E2E_GAME` 时 `run.sh` 打印 `SKIP suite=game reason=MOCHI_E2E_GAME 未设置`，
整层不运行（`cases=0`）——不要把它当成「真游戏已验收」。

可选环境变量：`MOCHI_E2E_PROVIDER=openai` + `MOCHI_E2E_ENDPOINT=<url>` 切真实后端，默认 `passthrough`。

| 用例ID | 断言数 | 覆盖的 P0/AC | 关键断言 | 依据 |
| --- | --- | --- | --- | --- |
| G1 `01_real_game` | 6 | AC1.1 / AC2.2a / P0-08 | `engine ∈ {mv,mz}`；窗口标题非空；`captured>0`；`translated>0`；exit 0；无崩溃标记 | PRD AC2.2a（采集上屏）、AC1.1（引擎识别）、P0-08 |
| G2 `02_close_after` | 5 | AC2.4 / P0-16 | `play: close_after=5s closed=1 reason=user`（走用户关窗分支，不是 programmatic）；`play: window_closed=1`；exit 0；`captured>0`；无崩溃标记 | PRD AC2.4（停止后退出）、P0-16（关闭清理） |

合计 11 条断言（设置 `MOCHI_E2E_GAME` 时）。

## 已修复缺陷登记（回归断言）

E2E 层不改产品，只负责把契约钉在断言里。2026-10-23 这一轮把下列六条产品缺陷全部修掉
（每条一个独立 commit）；发现时它们是"把现状钉成快照"的断言，修复时已改回契约值。
**回归断言 ID 就是防线**：谁改回去，对应层立刻红在这一条上。

| 缺陷 | 一句话 | 修复 commit | 回归断言 |
|---|---|---|---|
| D17 / BUG-D1 | `requeue` 在整批全重复时清空去重表，同一批信封第三次重放被重新接受 | `6048d7f` | `E-14b` / `E-14c`（`05_envelope.mjs`） |
| D18 / BUG-D2 | `cheat.giveItem` / `setItemCount` / `updateActor` 对非数字 `id` 静默夹到 1 | `13041c7` | `T-014-I` / `T-015-I` / `T-016-I`（`03_rpc_table.mjs`） |
| D19 / F-1 | 短 `sk-` 密钥明文进日志 | `e091c6e` | `D3` 短 key 4 条（`probe_store.swift`） |
| D20 / F-2 | `library.json` 备份同秒覆盖，证据丢失 | `1abfdd8` | `D1` 同秒两次损坏 2 条（`probe_store.swift`） |
| D21 / F-3 | 缓存淘汰实为 FIFO，与"最久未用"不符 | `eadaf0f` | `D7` LRU 2 条（`probe_store.swift`） |
| D22 / F-4 | `fulltext/` 的 0700 只在首次创建生效 | `c71e68e` | `D8` 目录已存在 2 条（`probe_fulltext.swift`） |

修复前后的 TAP 原文（`not ok` → `ok`）与根因见各自 commit 正文；`docs/testing.md` §7 是同一份清单的
面向测试流程的版本，两处内容必须一致。

**再次出现同类问题时的处理顺序**：
1. 先在 `docs/backlog.md` 登记（给 ID、现象、期望/实际、复现命令）；
2. 断言只写**契约值**，不要写"跑出来是什么"；
3. 修好后把 commit 与本表绑定，别让"已修复"只活在 commit message 里。
