# V0.6 设计：修改器面板 + 全文翻译

> 依据：`docs/re-cheat-and-fulltext.md`（证据）、`docs/prd.md`（验收口径，本轮需改三处排除项）、
> `docs/architecture.md`（现有分层与协议）。
>
> 范围：**只做 RPG Maker MV / MZ**，只走已有的 CDP + 页面内 Agent 通路。
> 不做存档文件改写、不做内购/DRM 绕过、不接入 MTool 的加密译文容器。

---

## 1. 决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | 修改器走**新增的 `rpc` 通道**，不复用 `inbox` 的 fire-and-forget 语义 | 作弊操作需要"调用—返回结果—错误码"，现有 `inbox` 只有单向 |
| D2 | 全部作弊动作在 Agent 内按 **MV/MZ 对象模型**实现，宿主只发方法名与参数 | 与 MTool 的"通用求值桥 + 引擎脚本"同构；宿主不掺引擎知识 |
| D3 | 作弊写操作**逐条白名单**，不提供任意表达式求值 | 不把 `eval` 暴露给 UI；`cheat.objectPath` 只允许点路径读写且要二次确认 |
| D4 | 全文语料 = **静态数据对象 + 全量地图 JSON + 运行期采集**三源合并，按原文去重 | 用户已选；MTool 的证据（导出原文→原文）要求先拿全量 |
| D5 | 译文持久化在 **`<App Support>/MochiBox/fulltext/<gameHash>.json`**，另提供"导出到游戏目录" | 用户已选；默认不污染游戏目录 |
| D6 | 导入/导出格式与 MTool 的 `ManualTransFile.json` **兼容**（纯 `{原文:译文}`） | 可直接吃现成的人工译文 |
| D7 | 扫描**分片 + 可取消**，每片让出事件循环 | `trsLoading` 证明原版会卡住数秒~数十分钟；我们不允许卡 UI |

---

## 2. 协议扩展（Agent ↔ Host）

### 2.1 现有信封

```json
{"v":1,"type":"text|hello|error|stats|pong","payload":{...}}
```

### 2.2 新增：`rpc` / `rpcResult`

Host → Agent（仍走 `window.__mochibox.inbox(<json>)`）：

```json
{"type":"rpc","payload":{"id":"r7","method":"cheat.snapshot","args":{}}}
```

Agent → Host（进 outbox，由 `drain()` 取走）：

```json
{"v":1,"type":"rpcResult","payload":{"id":"r7","ok":true,"data":{...}}}
{"v":1,"type":"rpcResult","payload":{"id":"r7","ok":false,"error":{"code":"cheat_unavailable","message":"$gameParty 不存在"}}}
```

约定：

- `id` 由 Host 生成（`c-<递增>`），Agent 原样回填；Host 侧 5 s 超时（`scan*` 除外，30 s）。
- Agent **必须**在 `try/catch` 内执行，任何异常都转成 `ok:false`，不得抛给游戏。
- 未识别 `method` → `ok:false, code:"rpc_unknown_method"`。
- 返回值必须可 `JSON.stringify`；函数/循环引用用 `null` 或摘要替代。

### 2.3 新增：扫描流

```json
{"type":"rpc","payload":{"id":"s1","method":"text.scanStart","args":{"includeMaps":true,"includeRuntime":true}}}
```
立即返回：
```json
{"type":"rpcResult","payload":{"id":"s1","ok":true,"data":{"scanId":"scan-3","estimated":12345}}}
```
随后 Agent 分片推送（每片 ≤ 200 条，`setTimeout(0)` 让出）：
```json
{"v":1,"type":"scanChunk","payload":{"scanId":"scan-3","seq":0,"items":[{"raw":"薬草","source":"item","path":"items.7.name"}]}}
```
结束：
```json
{"v":1,"type":"scanDone","payload":{"scanId":"scan-3","total":9876,"skipped":321,"cancelled":false}}
```
取消：`text.scanCancel {scanId}` → `scanDone` 带 `cancelled:true`。

`source` 枚举：`actor|class|skill|item|weapon|armor|enemy|troop|state|animation|tileset|common_event|system|map|runtime`。

### 2.4 新增：批量下发（复用现有 `setTranslations`）

不改协议；Host 仍按 `K.setTranslationsChunk = 200` 切片。
全文翻译完成后一次性灌入 Agent，后续绘制直接命中。

---

## 3. 作弊方法表（MV/MZ）

> 列 `API` 是 **Agent 内**的实现方式（观测到的 MTool 能力面 → MV/MZ 引擎 API 的映射，属推断）。
> 所有方法在 `$game*` 缺失时返回 `cheat_unavailable`，不抛异常。

### 3.1 只读

| method | args | 返回 | API |
|---|---|---|---|
| `cheat.snapshot` | `{}` | `{scene,mapId,mapName,gold,frames,player:{x,y,dir,through},party:[…],speed}` | `SceneManager._scene`, `$gameMap`, `$gameParty`, `$gamePlayer` |
| `cheat.listVariables` | `{from,count}` | `[{id,value}]` | `$gameVariables.value(id)` |
| `cheat.listSwitches` | `{from,count,onlyOn}` | `[{id,value}]` | `$gameSwitches.value(id)` |
| `cheat.listItems` | `{kind,ownedOnly}` | `[{id,name,description,iconIndex,price,count}]` | `$dataItems/$dataWeapons/$dataArmors`, `$gameParty.numItems` |
| `cheat.listActors` | `{}` | `[{id,name,classId,className,level,exp,hp,mhp,mp,mmp,tp,params,equips,states,nickname}]` | `$dataActors`, `$gameActors.actor(id)` |
| `cheat.listMapEvents` | `{mapId}` | `[{id,name,x,y,note}]` | `$dataMap.events` / `fetch` |
| `cheat.transferPoints` | `{}` | `[{mapId,mapName,eventId,name,x,y,kind}]` | 扫 `$dataMap.events[].list` 的命令码 201（场所移动）与 `<TP>` 注释 |
| `cheat.objectPath` | `{path}` | `{path,type,value}` | `path.split('.')` 逐层读 `window`；值做 JSON 安全化 |

### 3.2 写入

| method | args | API |
|---|---|---|
| `cheat.setGold` | `{value}` 或 `{delta}` | `$gameParty._gold` + `gainGold` |
| `cheat.setVariable` | `{id,value}` | `$gameVariables.setValue(id,value)` |
| `cheat.setSwitch` | `{id,on}` | `$gameSwitches.setValue(id,!!on)` |
| `cheat.setSelfSwitch` | `{mapId,eventId,letter,on}` | `$gameSelfSwitches.setValue([mapId,eventId,letter],!!on)` |
| `cheat.toggleAllSwitches` | `{on}` | 遍历 `$dataSystem.switches` |
| `cheat.toggleAllSelfSwitches` | `{on}` | 遍历当前地图事件 `A..D` |
| `cheat.giveItem` | `{kind,id,count}` | `$gameParty.gainItem($dataX[id], count)` |
| `cheat.setItemCount` | `{kind,id,count}` | 先 `loseItem` 再 `gainItem` 到目标 |
| `cheat.updateActor` | `{id,level?,exp?,hp?,mp?,tp?,nickname?,classId?,params?,equips?,states?}` | `$gameActors.actor(id)` 的 setter |
| `cheat.recoverAll` | `{scope}` | `actor.recoverAll()` |
| `cheat.addPartyMember` / `removePartyMember` | `{actorId}` | `$gameParty.addActor/removeActor` |
| `cheat.godMode` | `{on,lockHp,lockMp}` | 记录 `_godMode`，在 `Game_Actor.gainHp` 前后钳制；`lockHp` 时每帧回满 |
| `cheat.setObjectPath` | `{path,value}` | 仅允许 `$game*` / `$data*` 开头的路径；写前二次确认 |

### 3.3 世界/流程

| method | args | API |
|---|---|---|
| `cheat.noclip` | `{on}` | `$gamePlayer.setThrough(!!on)` |
| `cheat.encounter` | `{on}` | `$gameSystem._encounterEnabled` / `enableEncounter` |
| `cheat.alwaysDash` | `{on}` | `$gameSystem._alwaysDash` |
| `cheat.followers` | `{on}` | `$gamePlayer._followers._visible` |
| `cheat.unlockEquip` | `{}` | 解锁全部装备槽（`_equipSlots` 补齐到最大） |
| `cheat.unlockChoice` | `{}` | 解掉选项锁（`$gameSystem._choiceLock` 等，按存在性） |
| `cheat.speed` | `{multiplier}` | hook `Graphics.render`/`SceneManager.update` 的 delta，倍率 0.25–8 |
| `cheat.moveSpeed` | `{delta}` | `$gamePlayer._moveSpeed += delta`（钳 1–6） |
| `cheat.teleport` | `{mapId,x,y,dir?}` | `$gamePlayer.reserveTransfer` + `SceneManager.goto(Scene_Map)` |
| `cheat.scene` | `{name}` | `menu/save/load/options/status/equip/skill/item/formation/debug/title/map` → `SceneManager.push/goto` |
| `cheat.scenePop` | `{}` | `SceneManager.pop()` |
| `cheat.battle` | `{op}` | `win/escape/killAll` → `BattleManager`；`lose` → 全队 HP=1 后强制战败 |
| `cheat.clearPictures` | `{}` | `$gameScreen.clearPictures()` |
| `cheat.clearEvent` | `{}` | 当前事件 `erase()` |
| `cheat.clearMoveRoute` | `{}` | `$gamePlayer.clearMoveRoute()` + 当前事件 |
| `cheat.closeAllWindows` | `{}` | 场景内 `Window` 逐个 `close()` |
| `cheat.fadeIn` | `{}` | `$gameScreen.startFadeIn(30)` |
| `cheat.recover` | `{}` | 全队 `recoverAll` + 清状态 |
| `cheat.repair` | `{}` | 修复常见卡死：清 `_waitCount`、恢复 `Graphics`、`SceneManager._scene` 活性检查 |
| `cheat.fixError` | `{}` | 清 `$gameTemp._error`、`Graphics._errorShowed`，重绘 |
| `cheat.devTools` | `{}` | NW.js：`require('nw.gui').Window.get().showDevTools()`；浏览器：返回 `unsupported` 提示 |

### 3.4 安全边界

- `cheat.setObjectPath` **不**接受 `location`/`document`/`fetch`/`require` 等宿主对象；
  只允许 `$game` / `$data` / `$gameTemp` / `$gameSystem` 前缀。
- 所有写入前校验 id 范围（1..N），越界返回 `cheat_out_of_range`。
- Agent 内维护 `_cheatLog`（最近 50 条），`cheat.snapshot` 一并回传，便于排障。

---

## 4. 全文翻译管线

```
① 扫描（Agent）           ② 归并（Host）          ③ 翻译（现有管线）      ④ 落盘/下发
text.scanStart  ──chunk──▶ FullTextCorpus      ──▶ TranslationPipeline ──▶ FullTextStore
   $data* / maps            去重/过滤/序号           按设置的批量/并发         setTranslations
   runtime seenTexts        与缓存比对               熔断/重试                  Agent Map
```

### 4.1 扫描规则（Agent 侧）

- 数据源：`$dataActors/$dataClasses/$dataSkills/$dataItems/$dataWeapons/$dataArmors/$dataEnemies/
  $dataTroops/$dataStates/$dataAnimations/$dataTilesets/$dataCommonEvents/$dataSystem/$dataMapInfos`。
- 地图：`$dataMapInfos` 的每个 `id` → `fetch('data/Map%03d.json')`（同源，静态服务器已托管）；
  失败则退化为只扫 `$dataMap`。
- 递归字符串字段：`name` / `description` / `nickname` / `profile` / `message1..4` /
  `note`（**跳过** `<...>` 插件指令整行与纯 ASCII 标识符）/ `text` / `help`。
- 运行期：hook 里每个 `raw` 都进 `runtimeSeen`（上限 20k，FIFO）。
- 过滤：`trim().length >= 2`；排除纯数字/纯符号/文件路径/URL/`\N[...]` 变量占位；
  **保留**含控制码的原始串（由 Host 用现有 `splitSegments` 处理）。
- 每片 `200` 条，`setTimeout(0)`；`scanCancel` 在片间检查。

### 4.2 归并（Host 侧）

- 键：**原文 raw**（不是 `cacheKey`）。同一 raw 只翻一次。
- 与 `TranslationCache` 比对：命中直接进"可用"集合，不送后端。
- 过滤：长度 > 500 的串单独成批（避免撑爆单请求）；含 `<`/`>` 的插件行默认跳过（可开关）。

### 4.3 翻译

- 复用 `TranslationPipeline`（批大小/并发/超时全部取设置，默认 `maxBatch=60`、`maxConcurrent=4`；熔断 5 次/30 s（熔断期零请求、不消费队列、不产出译文，冷却后自动继续）、退避 0.5/1/2 s）。
- 全文模式**不再写死小批**：一批 = `min(120, maxBatch×maxConcurrent)` 条（默认 **120**），等待上限 = `波数×timeoutSec×4+30` 秒（默认 **90 s**）；进度回调 `(done,total)`。
- 失败项保留在"未译"集合，可重试；不阻塞其余项。**熔断结果（`error.code = circuit_open`）与 `backend == .passthrough` 的整批结果一律按失败落账**，绝不把原文写进语料。

### 4.4 持久化

`~/Library/Application Support/MochiBox/fulltext/<gameHash>.json`：

```json
{
  "version": 1,
  "gameHash": "…",
  "engine": "mvmz",
  "srcLang": "ja",
  "tgtLang": "zh-Hans",
  "updatedAt": "2026-10-22T12:00:00Z",
  "entries": { "薬草": "药草", "…": "…" },
  "meta": { "translated": 9876, "backend": "openai", "model": "…" }
}
```

- 原子写（复用 `FileIO.writeAtomic`），权限 `0600`。
- 启动会话时自动加载并下发（`setTranslations` 分片）。
- 加载时清理历史上的假译文：`origin != .manual` 且归一后 `translated == raw` 的条目清回未译（只清译文/分段/问题，条目本身保留），计数写日志并在界面提示，**立即落盘**（否则下次启动又读回来）。本次清过的，首次下发前先向 Agent 发 `clear` 再重发全部有效译文（否则页面内存里仍是旧值）。
- "导出到游戏目录"写出 `<game>/ManualTransFile.json`（MTool 兼容）+ 可选备份。
  **不写 `MToolData_`**，也不改任何游戏数据文件——与 MTool 的差别要在 UI 上写明。

### 4.5 人工译文导入

- 接受 `{原文:译文}` 的 JSON；`原文==译文` 视为未译。
- 合并策略：导入优先于机翻；冲突计数在 UI 展示。

---

## 5. Swift 数据模型（新文件）

`Sources/Domain/CheatModels.swift`

```swift
struct CheatSnapshot: Codable, Sendable, Equatable {
    var scene: String; var mapId: Int; var mapName: String
    var gold: Int; var frames: Int; var speed: Double
    var player: CheatPlayer
    var party: [CheatPartyMember]
}
struct CheatPlayer: Codable, Sendable, Equatable { var x: Int; var y: Int; var dir: Int; var through: Bool }
struct CheatPartyMember: Codable, Sendable, Equatable { var id: Int; var name: String; var level: Int; var hp: Int; var mhp: Int; var mp: Int; var mmp: Int }

struct CheatVariable: Codable, Sendable, Equatable, Identifiable { var id: Int; var value: JSONValue ... }
struct CheatItem: ... // id,name,description,iconIndex,price,count
struct CheatActor: ... // 见 3.1
struct TransferPoint: ...
```

`Sources/Domain/AgentRPC.swift`：`actor AgentRPC`，持 `PageChannel`，`call(method:args:timeout:)`。

`Sources/Domain/FullTextModels.swift`：`FullTextEntry` / `FullTextCorpus` / `FullTextProgress`。

`Sources/Domain/CheatController.swift`（@MainActor ObservableObject）。
`Sources/Domain/FullTextController.swift`（@MainActor ObservableObject）。

`Sources/Infra/FullTextStore.swift`：加载/保存/导出/导入。

---

## 6. UI

右栏顶部加**三段切换**：`翻译流` / `作弊` / `全文`（`.pickerStyle(.segmented)`）。

- **作弊**：左侧分组列表（状态 / 数值 / 物品 / 角色 / 世界 / 流程），右侧表单。
  - 数值类：输入框 + "应用"；开关类：`Toggle` 即发。
  - 危险操作（`setObjectPath`、`battle.lose`、`toggleAllSwitches`）二次确认。
  - 顶部显示 `scene / map / gold / party` 快照，1 s 刷新（仅在作弊页可见时）。
- **全文**：`扫描`（进度条 + 已发现条数）→ `翻译`（进度 + 失败数）→ `导出/导入`。
  - 统计卡：语料数 / 已译 / 未译 / 命中缓存。
  - 失败列表可"重试失败项"。

---

## 7. 任务与文件归属（并行开发用）

| 任务 | 归属文件 | 依赖 |
|---|---|---|
| T01 Agent：`rpc` 通道 + 57 项作弊 + `text.scanStart/Chunk/Done/Cancel` | `Resources/agent_mvmz.js` | 契约 §2/§3/§4.1 |
| T02 Swift 核心：`CheatModels` / `AgentRPC` / `CheatController` / `FullTextController` / `FullTextStore` / `SessionController` 接线 | `Sources/Domain/*`、`Sources/Infra/FullTextStore.swift` | T01 契约（可先按契约写） |
| T03 Fixture/探针：`mv_stub` 增加 `$game*`/`$data*` 假对象 + `rpc_probe.mjs` | `Fixtures/**`、`Tests/qa/**` | 契约 |
| T04 UI：作弊面板 + 全文页 + 分段切换 | `Sources/UI/**`、`Sources/App/AppMain.swift`（仅接线） | T02 |
| T05 集成：构建、`--selftest`、E2E、文档、PRD 口径 | 全仓 | T01–T04 |

**冲突规则**：T01 只碰 `Resources/agent_mvmz.js`；T02 不碰 `Sources/UI`；T04 不改 `Sources/Domain`；
T03 不改 `Sources/`。任何跨文件改动由主理人合并。

---

## 8. 验收标准（AC-9 / AC-10）

| 编号 | 断言 | 取证 |
|---|---|---|
| AC-9.1 | 连接后 `cheat.snapshot` 返回 `scene/mapId/gold/party`，值来自引擎而非伪造 | `rpc_probe.mjs` 对 stub 与真游戏各跑一次 |
| AC-9.2 | `setGold` 后快照金币变化，且游戏内菜单显示一致 | 截图 + 快照前后对比 |
| AC-9.3 | 变量/开关/物品/角色各至少一条写入路径可用；越界 id 返回 `cheat_out_of_range` 且游戏不崩 | 探针 12 条 |
| AC-9.4 | `noclip` / `encounter` / `speed` 生效可观测（穿墙位移、遇敌计数、帧率） | 手工 + 截图 |
| AC-10.1 | 扫描在 30 s 内完成或可取消；UI 不卡（主线程 60 fps） | 扫描 10k 条语料 |
| AC-10.2 | 全文翻译完成后，重启游戏自动加载译文（无网络） | 断网重启 |
| AC-10.3 | 导出 `ManualTransFile.json` 可被重新导入，译文一致 | 往返 diff |
| AC-10.4 | 导入 MTool 格式人工译文后，未译数下降 | 样本 200 条 |
| AC-10.5 | 扫描/翻译/下发全链路不修改游戏目录（除非点"导出到游戏目录"） | 目录 mtime 对比 |

---

## 9. 失败模式

| 现象 | 处理 |
|---|---|
| `$gameParty` 不存在（还没进标题） | `cheat_unavailable`，UI 显示"等待游戏进入场景" |
| 页面刷新 / 重连 | Agent 重新 `hello`，Host 重放 `config` + 全文译文 |
| 扫描中途切场景 | 数据对象仍在；地图 fetch 独立于场景，不中断 |
| 译文文件损坏 | 忽略并重命名 `.corrupt`，不阻塞启动 |
| 后端 401/429 | 沿用现有熔断：熔断期不消费队列、零请求、不产出译文；在飞条目按失败落账（可重试），冷却后队列自动继续；已完成项保留 |
| 旧版本留下的假译文（`translated == raw`） | 加载时自动清理（仅 `origin != .manual`），计数写日志 + 界面提示，立即落盘；首次下发前先 `clear` 再重发 |
| 游戏是非 MV/MZ | 扫描/作弊入口禁用，提示"仅支持 MV/MZ" |

---

## 10. `mvlang` 57 项逐条对照

> 左两列来自证据（`LangTL.json` → `ja.mvlang`）；右两列是本轮实现。
> `状态`：`P0` = 本轮实现并验收；`UI` = 只是界面文案/按钮，不产生独立动作；
> `—` = 明确不做（与 MTool 的差异）。

| `mvlang` 键 | MTool 标签（ja） | 我们的实现 | 状态 |
|---|---|---|---|
| `main` | ホームページ | 宿主首页（不是游戏内动作） | UI |
| `gold` | ゴールド | `cheat.setGold` | P0 |
| `saveWithRaw` | アニメーション付きセーブ | 存档写入，明确不做 | — |
| `fixResErrorCatch` | リソースエラーを修正 | `cheat.repair` | P0 |
| `noclip` | 壁抜け | `cheat.noclip` | P0 |
| `clickToTeleport` | Click to teleport. | 本轮用 `cheat.teleport` 填坐标；画布点击映射留 P2 | — |
| `encounter` | エンカウント | `cheat.encounter` | P0 |
| `menu` | メニュー | `cheat.scene{name:"menu"}` | P0 |
| `save` | セーブ | `cheat.scene{name:"save"}` | P0 |
| `formation` | 隊列編成 | `cheat.scene{name:"formation"}` | P0 |
| `followersVisible` | Display Followers | `cheat.followers` | P0 |
| `unlockEquip` | 装備スロットをアンロック | `cheat.unlockEquip` | P0 |
| `alwaysDash` | 常時ダッシュ | `cheat.alwaysDash` | P0 |
| `unlockChoice` | オプションのロック解除 | `cheat.unlockChoice`（尽力而为） | P0 |
| `sceneManager` | シーンマネージャー | UI 场景下拉（`cheat.scene`） | UI |
| `status` | 状態 | `cheat.scene{name:"status"}` | P0 |
| `equip` | 装備 | `cheat.scene{name:"equip"}` | P0 |
| `skill` | スキル | `cheat.scene{name:"skill"}` | P0 |
| `item` | アイテム | `cheat.scene{name:"item"}` | P0 |
| `load` | 読み込み | `cheat.scene{name:"load"}` | P0 |
| `options` | 設定 | `cheat.scene{name:"options"}` | P0 |
| `debug` | デバッグ | `cheat.scene{name:"debug"}`（MZ 无 Scene_Debug 时返回 `cheat_bad_args`） | P0 |
| `scenePop` | シーンをポップ | `cheat.scenePop` | P0 |
| `eraseAllScreenPicture` | 全画像をクリア | `cheat.clearPictures` | P0 |
| `clearCurrEvent` | 現在のイベントをクリア | `cheat.clearEvent` | P0 |
| `ClearMoveRoute` | 移動ルートをクリア | `cheat.clearMoveRoute` | P0 |
| `closeAllWindow` | 全ウィンドウを閉じる | `cheat.closeAllWindows` | P0 |
| `gotoTitle` | タイトルへ切り替え | `cheat.scene{name:"title"}` | P0 |
| `gotoMap` | マップへ切り替え | `cheat.scene{name:"map"}` + `cheat.teleport` | P0 |
| `fadeInScreen` | Fade In Screen | `cheat.fadeIn` | P0 |
| `fixGameCrashAndFreeze` | エラー修正後のフリーズ | `cheat.repair` | P0 |
| `fixError` | エラー修正 | `cheat.fixError` | P0 |
| `godModeSetting` | ゴッドモード設定 | `cheat.godMode` | P0 |
| `lock` | ロック | `cheat.godMode{lockHp:true}` | P0 |
| `lockMax` | 最大 | UI：HP/MP/TP 设为上限 | UI |
| `enemy` | 敵 | `cheat.battle{op:"killAll"}` | P0 |
| `win` | 勝利 | `cheat.battle{op:"win"}` | P0 |
| `lose` | 失敗 | `cheat.battle{op:"lose"}` | P0 |
| `escape` | 逃走 | `cheat.battle{op:"escape"}` | P0 |
| `party` | パーティー | `cheat.listActors` + `add/removePartyMember` | P0 |
| `recover` | Recovery | `cheat.recover` | P0 |
| `repair` | Fix | `cheat.repair` | P0 |
| `open` | 開く | UI 按钮 | UI |
| `devTools` | 開発者コンソール | `cheat.devTools`（NW.js）；浏览器内核返回提示 | P0 |
| `speedup` | 加速 | `cheat.speed{multiplier}` | P0 |
| `multiply` | 倍率 | 同 `cheat.speed`（UI 倍数输入） | UI |
| `always` | 常時 | 同 `cheat.speed`（UI 常驻开关） | UI |
| `moveSpeedAdd` | 移動速度増加 | `cheat.moveSpeed{delta}` | P0 |
| `keySetting` | キー設定 | 宿主快捷键设置，P2 | — |
| `value` | 值 | UI 输入框 | UI |
| `enable` | 有効 | UI 开关 | UI |
| `really` | 本当に | UI 二次确认 | UI |
| `holdToSpeedUp` | Hold to Accelerate | 宿主按键加速，P2 | — |
| `updateData` | データを更新 | `cheat.snapshot` 刷新 | UI |
| `applyToGame` | ゲームに適用 | 各 `cheat.set*` 的提交按钮 | UI |
| `updating` | 更新中 | UI 忙碌态 | UI |
| `dataUpdated` | データ更新済み | UI 成功提示 | UI |

统计：**P0 动作 40 项**，UI/文案 13 项，明确不做 4 项（`saveWithRaw`、`clickToTeleport`、
`keySetting`、`holdToSpeedUp`；后两项留 P2）。合计 57 项，与 `mvlang` 一一对应。

---

## 11. 与 MTool 的明确差异（写进产品说明）

1. **不写存档**：MTool 的存档备份/改写/自动备份整条线不做；本工具的修改只存在于当前进程内存，
   退出游戏即消失。用户若需要持久化，用游戏自带存档。
2. **不写游戏数据文件**：MTool 会把译文数据与 `MToolData_` 缓存写进游戏目录；我们默认写
   `~/Library/Application Support/MochiBox/fulltext/`，只有显式"导出到游戏目录"才写
   `ManualTransFile.json`（不写 `MToolData_`，不改 `data/*.json`）。
3. **不复刻加密容器**：`MTRS2` 的 md5/key/加密/公开标志不复刻；我们用自己的明文 JSON，
   格式在 `FullTextStore` 内版本化。
4. **不接入 MTool 的翻译服务**：只用用户自备的 OpenAI 兼容 / DeepL / 直通后端。
5. **不提供任意表达式求值**：MTool 的宿主可在游戏 VM 内跑任意脚本；我们只暴露白名单方法 +
   受控的 `$game*`/`$data*` 点路径。

---

## 12. 生命周期与资源回收（V0.6 同步修复）

用户实测反馈："关掉游戏窗口后后台还在跑；Dock 里一直挂着 Chrome 图标。"
根因有三处，全部在本轮修掉：

| # | 根因 | 修复 |
|---|---|---|
| L1 | 用户点红叉后，`MVAdapter` 的 pump 只回报 `.stopped`，没有 `launcher.terminate` → 静态 HTTP 服务、内核注册表项、WKWebView 都还在 | `pump` 在窗口关闭分支里追加 `Task { await adapter.stop() }`；`stop()` 用 `NSLock` 幂等闸防并发重入 |
| L2 | `SessionController.handleAdapterState(.stopped)` 只落 UI + 关 RPC，不 cancel `TranslationPipeline`、不 flush 缓存 | `stopRequested` 闸 + `.stopped` 时补 `Task { await stop() }`；`stop()` 顺序固定为 `disconnectAgentFeatures → pipeline.cancelAll → adapter.stop → cache.flush` |
| L3 | 早期 Chromium 会话被 Ctrl-C / SIGKILL 后留下浏览器进程与 pid 文件；只有"同一个游戏再次启动"才会回收 | 新增 `BrowserProcessSweeper`：App 启动与 `applicationWillTerminate` 各扫一次 `browser-profiles/*/.mochibox-browser.pid`，只杀 `ProcessInspector.isBrowser` 认得出的（argv 带本 profile） |

配套约束：

- **GUI 默认内核必须是 embedded**：`GameLauncher.launch` 打一行 `内核选择 kernel=embedded|chromium`，
  只有显式 `--browser`/`--headless`/`--kernel chromium` 才会出现 Chrome 与 Dock 图标。
- **测试必须自己收尾**：`Tests/qa/run_stub_probes.sh` 用 `trap` 起停 headless Chrome；
  `play_e2e.sh` 的 clean-up 增加 `pkill -9` 兜底与 `wait`。
  （这两个脚本都已随 E2E 重写移除，历史实现见 git 历史；当前测试入口见 `docs/testing.md`。
  内核层的收尾改由每个 case 的 `app.dispose()` 负责：SIGTERM → 3s → SIGKILL，且进程退出钩子兜底。）
- **窗口已关时跳过 Agent uninstall**：通道已 dead，再 `push(config)` 只会白等 5s 超时，
  期间静态服务还占着端口。

验收：关窗后 1s 内 `lsof -i :<httpPort>` 为空；`pgrep -f "user-data-dir=<本 profile>"` 为空；
Dock 无 Chrome 图标；`--play` 到点后进程退出。
