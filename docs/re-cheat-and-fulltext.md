# MTool 逆向（二）：修改器与全文翻译

> 分析对象与哈希（同一份素材，可复核）：
>
> | 文件 | sha256 |
> |---|---|
> | `reference/pc/MTool.zip`（416 MB 解包后 / 1277 文件） | `f76728b0e7df054919024bb509648c01ed4e3fe6f49c80711a46c92dd82de623` |
> | `reference/apk/mtool_v55_24.apk` | `90c5b9cd72c0f698ef2647b8f5986b45c609c41baa89eb4f53790f58b84f934f` |
>
> 方法：静态分析（ZIP 结构、PE 字符串、UTF-16 字符串、V8 字节码常量池、JSON 资源）。
> **未执行** MTool 本体，也未运行任何 Windows/Android 组件。
>
> 本篇只覆盖两件事：**① 修改/作弊**、**② 全文翻译**。
> 注入方式、通信协议、各引擎 Hook DLL 见 `docs/re-findings.md`，不重复。

---

## 0. 一句话结论

MTool 的修改器与全文翻译**共用同一条通路**：

```
宿主 UI（加密的 Web 应用）
   │  RPC：taskHandles 命名任务
   ▼
游戏内 Agent（bytenode 字节码：Client.js / Server.js）
   │  vmeval / evalr / evalNoSerialize  ← 在游戏 VM 里求值任意 JS
   ▼
游戏引擎对象（$gameParty / $dataItems / $gameVariables …）
```

- **修改器**：宿主把"读取/写入某个引擎对象"的 JS 表达式发下去求值，再把结果回传渲染成面板。
  **不是**打包在 DLL 里的固定作弊逻辑。
- **全文翻译**：宿主先从游戏里**枚举出全部文本**（数据对象 + 运行期绘制文本），
  批量翻译后写成一个**游戏目录下的译文数据文件**，游戏启动时自动加载；
  运行期再由 Agent 把绘制形参替换为译文。

两条功能都不依赖原生 Hook 的具体实现，只依赖"能在游戏 VM 里求值"这一条能力。
这对我们（CDP + 页面内 Agent）是可平移的。

---

## 1. 证据 A：游戏内 Agent 是"通用求值桥"，不含任何引擎专有逻辑

**A1. 载体是 V8 字节码（bytenode）**

```bash
# 两个文件的头 8 字节完全相同
$ xxd -l 8 MTool/Tool/loaders/Client.js.arm64
00000000: f504 dec0 82a0 6935                      ........
$ xxd -l 8 MTool/Tool/loaders/Server.js.arm64
00000000: f504 dec0 82a0 6935                      ........
```

- 魔数 `F5 04 DE C0` = `0xC0DE04F5`（小端），即 bytenode 的 V8 字节码缓存。
- 大小：`Client.js.arm64` 276,840 B；`Server.js.arm64` 377,896 B。
- 与 `runtime/node/main.js` 里的 `bytenode.runBytecode(fs.readFileSync(clientPath))` 完全对应
  （见 `docs/re-findings.md` §10）。

**A2. 常量池里的能力清单（字节码未混淆字符串表）**

| 符号 | 文件 | 偏移 | 含义 |
|---|---|---|---|
| `vmeval` | `Client.js.arm64` | `0x10630` | 在游戏 VM 内求值 |
| `evalr` | `Client.js.arm64` | `0x01DD9` | 求值并返回结果 |
| `evalNoSerialize` | `Client.js.arm64` | `0x01F82` | 求值但不做序列化 |
| `dispatchKeyEv` | `Client.js.arm64` | `0x07B60` | 向游戏派发按键事件 |
| `taskHandles` / `taskHandlesDef` | `Client.js.arm64` | `0x0196F` | 命名 RPC 任务表 |
| `sendCmd` / `replyCmd` / `hasCmd` / `sentCmd` | `Client.js.arm64` | `0x42A30` / `0x14B2D` | 请求/应答 |
| `evalScriptInServer` | `Server.js.arm64` | `0x59697` | 服务端侧求值 |
| `runBytecode` | `Server.js.arm64` | `0x5971B` | 运行字节码 |
| `RESTRICTED_ALLOWED_CMDS` | `Server.js.arm64` | `0xA471` | 受限令牌的命令白名单 |

**A3. 反证：Agent 里没有任何引擎专有符号**

```bash
$ strings -n 4 Client.js.arm64 Server.js.arm64 | grep -E '\$game|SceneManager|Window_Base|Game_|RenPy|UnityEngine'
# 无输出
```

→ 结论（观测）：**MV/MZ/Ren'Py/Unity 的差异不在 Agent 里，而在宿主加密包发出的求值脚本里。**
因此"修改器怎么改金币"这类问题在静态层面只能看到**能力**与**UI 契约**，
看不到具体表达式；但这对复刻不构成障碍——我们本来就要按引擎 API 重新实现。

---

## 2. 证据 B：MV/MZ 修改器的功能面 = `LangTL.json` 的 `mvlang`

`MTool/Tool/www/rawres/LangTL.json` 是 19 种语言 × 1405 个 UI 键的资源表。
其中 `ja` 语言包里的 `mvlang` 是一个 **57 项**的字典（键=功能名，值=界面标签）：

```python
# 可复现：python3 读取 LangTL.json → d['ja']['mvlang']
['main','gold','saveWithRaw','fixResErrorCatch','noclip','clickToTeleport','encounter',
 'menu','save','formation','followersVisible','unlockEquip','alwaysDash','unlockChoice',
 'sceneManager','status','equip','skill','item','load','options','debug','scenePop',
 'eraseAllScreenPicture','clearCurrEvent','ClearMoveRoute','closeAllWindow','gotoTitle',
 'gotoMap','fadeInScreen','fixGameCrashAndFreeze','fixError','godModeSetting','lock',
 'lockMax','enemy','win','lose','escape','party','recover','repair','open','devTools',
 'speedup','multiply','always','moveSpeedAdd','keySetting','value','enable','really',
 'holdToSpeedUp','updateData','applyToGame','updating','dataUpdated']
```

同文件里还有一批**编辑器字段**，不在 `mvlang` 内，但明显属于同一个面板：

| 键 | 标签（ja） | 用途 |
|---|---|---|
| `variable` / `switche` / `selfSwitche` | 変数 / スイッチ / イベントスイッチ | 变量、开关、独立开关 |
| `toggleAllConditions` / `toggleAllSelfSwitch` | 全条件を切り替え / 全独立スイッチを切り替え | 批量开关 |
| `item` / `weapon` / `armor` / `amount` / `stock` / `unit` | アイテム / 武器 / 鎧 / 数量 / 在庫 / 単位 | 物品与库存 |
| `carryingItemsEeditor` / `carrying` / `selectOwned` | 所持アイテム編集 | 所持物品编辑器 |
| `actor` / `class` / `nickname` / `exp` / `param` / `plusValue` / `state` | アクター / クラス / 二つ名 / 経験値 / 能力値 / 加算値 / 状態 | 角色编辑器 |
| `commonEvent` / `event` / `tpTo` / `youAreHere` / `transferPoint` | コモンイベント / イベント / 転送 / 現在地 | 事件与传送 |
| `transferList` / `showTransferMarkers` / `tpVarDesignate` / `tpMapVarLabel` / `tpXVarLabel` / `tpYVarLabel` | テレポート地点リスト / 変数指定 | 传送点列表（地图/x/y 由变量指定） |
| `evLen` / `evInterpreter` / `viewNowEv` / `forceKill` | イベント長 / インタプリタ / 実行中イベント | 事件解释器 |
| `changecheatObjPath` | オブジェクトパスを変更 | **改任意对象路径**（通用取值/写值） |
| `godMode` / `lock` / `lockMax` / `dataLock` | 無敵モード / ロック / 最大 / データロック | 数值锁定 |
| `speedModify` / `moveSpeed` / `moveSpeedAdd` / `multiply` / `always` | 変速 / 移動速度 / 倍率 / 常時 | 变速 |
| `saveBackup` / `autoSave` / `saveLockStatus` / `BackupTheSavedataImmediately` | セーブバックアップ | 存档备份/自动保存 |

**观测**：`mvlang` 的键就是 MV/MZ 面板的条目，没有引擎前缀（其它引擎另有各自的键，如
`wolfDataMod` / `renpyCheat*` / `kd*`）。**推断**：这些条目一一对应 RPG Maker 的引擎 API
（`$gameParty.gainGold`、`$gameVariables.setValue`、`$gameSwitches.setValue`、
`$gameSelfSwitches.setValue([map,event,letter],bool)`、`SceneManager.push(Scene_Menu)`、
`$gamePlayer.setThrough(true)`、`$gameSystem.disableEncounter()` …），
因为 Agent 只提供求值，不提供语义。

**旁证（同族能力）**：Ren'Py 面板是**Cheat Engine 式变量扫描器**——
`renpyCheatScanKeyword` / `renpyCheatScanUnknown` / `renpyCheatScanInc` / `renpyCheatScanDec` /
`renpyCheatScanChanged` / `renpyCheatScanUnchanged` / `renpyCheatScanRecorded` /
`renpyCheatLock` / `renpyCheatUnlock`。说明 MTool 的修改器不是"写死几个地址"，
而是"**按引擎暴露的对象模型做通用读写**"。这一点决定了我们复刻时也应做**对象模型驱动**，
而不是给每个游戏写死偏移。

---

## 3. 证据 C：修改器的落点不只有运行期内存，还有存档与存档库

| 键 | 观测到的行为 |
|---|---|
| `saveBackup` / `openSaveBackups` / `changeSaveBasePath` | 独立的"存档备份库"目录，可改路径 |
| `BackupTheSavedataImmediately` | 立即备份当前存档 |
| `autoSaveHint` / `autoSaveNothingChange` | 每次检出"被修改过的存档"就自动备份，没变化则跳过 |
| `RGSSSaveFileWrong` | 工具生成的存档文件未正确删除会导致游戏异常 |
| `saveLockStatus` / `loadLockStatus` | 存档/读档的锁定状态 |
| `tryDeleteAllSaveDataBackupHint` | 删不掉存档时的兜底：**彻底删除目录内全部文档** |

`Server.js.arm64` 常量池里也出现了 `Save\d*\.r.data\d*$`（`0x945B`）——RGSS 系存档命名。
→ **推断**：MTool 的"修改"包含**存档层**（备份、替换、修复），不只是内存。
我们本轮若只做 MV/MZ 运行期修改，应在文档里明示"不含存档编辑"，
否则用户会拿 MTool 的存档能力来对比。

---

## 4. 证据 D：全文翻译的完整链路

### D1. 入口与状态文案（`LangTL.json`）

| 键 | 语义（以德/法/俄三语交叉校验） |
|---|---|
| `submitTrs` | 翻译开始 |
| `trsLoading` | "正在加载资源。游戏与工具可能无响应（数秒到数十分钟）…**不要最小化游戏窗口**，建议置于前台" |
| `trsLoadingCnt` | "已加载 N 个文件" |
| `TrsDataLoadError` | "游戏文本加载错误，请重启游戏后重新加载，否则可能无法翻译" |
| `processingTranslateData` | 正在处理翻译数据 |
| `exportManualTransFile` | 导出人工翻译文件 |
| `exportManualTransFileHint` | 导出 `ManualTransFile.json`，内容是 `{"原文1":"原文1", ...}`；把值改成译文后用"加载翻译文件"导入 |
| `openTrsNDataInput` | 加载翻译文件 |
| `restoreOriTrsN` | 还原原文 |
| `trsDataSaved` | 译文数据保存到游戏目录 `@fileName@`，并生成**完全相同的**备份 `@fileNameBackup@`；**游戏启动时自动加载**；会员过期也能加载 |
| `deleteTranslateData` | 删除已翻译数据 |
| `makeTranslateCache` | 生成翻译缓存（提升流畅度，需要时间） |
| `cacheAllMapData` | 缓存全部地图数据（加速地图切换） |
| `dontDeleteTranslateCache` | 不要改/删游戏目录下 `MToolData_` 里的文件，否则游戏可能无法正常运行 |

**观测到的三个关键事实**：

1. **译文是一个"可脱离工具存在"的游戏目录文件**，启动即加载，与会员状态无关；
2. **导出的是"原文→原文"的键值对**，说明**翻译前已经拿到全部原文**（而不是边玩边翻）；
3. 加载阶段会让游戏卡住数秒到数十分钟，且**必须让游戏窗口在前台** →
   枚举动作发生在**游戏进程内**，不是宿主直接读文件。

### D2. 译文容器：`MTRS2`

`Server.js.arm64` 偏移 `0xD312` 起是 `MTRS2` 字面量；紧随其后的常量池键（同段连续出现）：

```
rawTmpPath  dataHolder  dataArr  checkFuncs  noRealKey  checkFunc
checkFail   goBroke     isEnc    trsData     jd         isPub
dataArrLen  headBytes   keyStr   md5
```

同时存在 `readMTRSHeader`（`0xA3F1`）与 `initTranslateFileData`（`0xA40D`）。

**推断**：`MTRS2` 是带头部（`md5` / `keyStr` / `isEnc` / `isPub` / `headBytes` / `dataArrLen`）
的译文二进制容器，"public"译文（服务器下发）与"私有"译文（本机生成）走同一容器。
`checkFunc*` / `noRealKey` / `goBroke` 说明作者在容器上做了**防第三方复用**的校验
（与 UI 文案 `needUpdateToLoadCustomTrsFile` 的"防止第三方用本工具盈利"一致）。
**我们不复刻这套加密容器**：没有互操作需求，自建明文 JSON 更可维护。

### D3. 翻译引擎菜单

`enginePre` 选项键：`XiaoYiPre` / `BingPre` / `SugoiPre` / `Sugoi32BPre` / `ChatGPTPre` /
`DeepSeekPre` / `FreePre` / `TrsNTPre`。
→ MTool 把"**整包文本**"提交给自建翻译服务（`TrsNT`，默认）或第三方引擎。
`trsLoading` 的"数分钟"也包括**服务端排队/批量翻译**的时间。

### D4. 名词一致性与译后校对

| 键 | 语义 |
|---|---|
| `translateNameFix` / `translateNameFixHint` | 名词/名称统一（Lv.3 限定） |
| `nounOverrideTagLabel` / `nounOverrideBatchReplaceLabel` / `nounOverrideCustomTranslationPlaceholder` | 名词覆盖编辑器：按标签筛选、批量替换、自定义译文、只显示改动项 |
| `translated` / `unTranslated` / `showAsTranslated` / `exactly` / `onlyDisplay1000` | 译文浏览器：已译/未译过滤、精确搜索、以译文显示 |
| `trsnlateFixApplyInfo` / `viewChanges` / `replacementSteps` | 替换规则命中记录与差异查看 |

→ 全文翻译不是"一键机翻就完事"，还包含**译名统一 + 人工覆盖 + 可检索校对**。

### D5. 字体与排版（译文能不能显示）

`fixGameFont`（文字化け修正/字体替换）、`fontSizePercentScale`、`fontSizeChange`、
`cantUsePixelFont`（位图字体不可用）、`fontPvHint`（字体预览，含缺字提示）、
`fontSizeMayNeedRestartGame`、`tyranoFontSizeHint`。
→ 日文 UI 的排版宽度装不下中文，MTool 的解法是**换字体 + 缩字号 + 可选字距**，
而不是改 UI 布局。

---

## 5. 观测 / 推断 / 未知（三分表）

| # | 类型 | 结论 | 证据 |
|---|---|---|---|
| 1 | 观测 | Agent 是通用求值桥，无引擎语义 | A2 + A3 |
| 2 | 观测 | MV/MZ 修改器面板有 57 个条目 | B（`mvlang`） |
| 3 | 观测 | 修改器有存档备份/自动备份子系统 | C |
| 4 | 观测 | 译文持久化为游戏目录文件，启动自动加载 | D1（`trsDataSaved` 三语交叉） |
| 5 | 观测 | 翻译前已持有全量原文（可导出 `ManualTransFile.json`） | D1（`exportManualTransFileHint`） |
| 6 | 观测 | 文本枚举发生在游戏进程内，会阻塞数秒~数十分钟 | D1（`trsLoading`） |
| 7 | 观测 | 译文容器为 `MTRS2`，带 md5/key/加密/公开标志 | D2 |
| 8 | 观测 | 提供名词统一、译文浏览器、人工覆盖 | D4 |
| 9 | 观测 | 字体替换 + 字号百分比缩放是标准配置 | D5 |
| 10 | 推断 | 57 项作弊条目 → RPG Maker 引擎 API 的直接调用 | A3 + B |
| 11 | 推断 | 全量原文 = 引擎数据对象递归枚举 + 运行期绘制文本 | D1 三条事实 |
| 12 | 未知 | 宿主加密包中枚举/批处理的**具体顺序与批大小** | `loader.bin.ff` + `www/data/*` 加密 |
| 13 | 未知 | `MTRS2` 的**精确二进制布局与密钥派生** | 仅见常量池键名 |
| 14 | 未知 | `TrsNT` 服务端协议与计费 | 无网络侧样本 |

> 复现命令（全部只读）：
> ```bash
> unzip -p reference/pc/MTool.zip MTool/Tool/www/rawres/LangTL.json > /tmp/LangTL.json
> unzip -p reference/pc/MTool.zip MTool/Tool/loaders/Server.js.arm64 > /tmp/Server.js.arm64
> strings -n 4 /tmp/Server.js.arm64 | grep -nE 'MTRS2|initTranslateFileData|evalScriptInServer'
> python3 -c "import json;d=json.load(open('/tmp/LangTL.json'));print(d['ja']['mvlang'])"
> ```

---

## 6. 对我们的映射（只做 MV/MZ，只走 CDP）

| MTool 能力 | 我们的实现位置 | 说明 |
|---|---|---|
| 游戏内任意求值 | `agent_mvmz.js` 新增 `rpc` 通道 | 已有 `__mochibox.inbox`，加 `{type:"rpc",id,method,args}` |
| 57 项修改器 | 新增 `Sources/Domain/CheatModels.swift` + `Sources/UI/CheatPanel.swift` | 逐项映射到 MV/MZ API，见架构文档 §3 |
| 全量文本枚举 | Agent 新增 `text.scanAll`：递归 `$data*` + `fetch('data/Map*.json')` + 运行期采集 | 不阻塞游戏线程：分片、可取消 |
| 全文翻译 | 新增 `FullTextTranslator` actor：去重 → 批量走现有 `TranslationPipeline` → 落盘 | 复用现有翻译后端与熔断 |
| 译文持久化 | `<App Support>/MochiBox/fulltext/<gameHash>.json`；可选导出到游戏目录 | 用户已选"App 目录为主，可导出" |
| 人工翻译导入/导出 | 同 MTool 的 `ManualTransFile.json` 格式（纯键值对） | 便于复用现有人工译文 |
| 名词统一 / 人工覆盖 | 覆盖表 `nounOverrides`，翻译后、下发前应用 | 不依赖后端 |
| 字体/字号 | 已有 `fontScale`；补 `fontFamily` 注入与缺字提示 | 见 backlog |
| 存档备份 | **本轮不做**（与 MTool 对齐的部分明确列为"不做"） | PRD 合规口径 |

### 合规口径变更（需要写进 PRD）

`docs/prd.md` 当前有三处明确排除修改器：

- §2 第 42 行："不做修改器/作弊/内购解锁/存档编辑"
- §P2-07："修改器类功能 | 明确不在产品承诺范围（合规风险）"
- §602："不提供内购解锁、金币修改、作弊（不读改存档、不改内存数值）"

本轮按用户决策改为：**单机离线 MV/MZ 的运行期数值修改允许**；仍然**不做**
① 内购/DRM/授权绕过；② 存档文件改写；③ 联网游戏的数值修改。
PRD 的这三处必须在同一提交里改口径，否则代码与验收文档互相矛盾。
