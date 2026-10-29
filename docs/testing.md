# 测试体系

> 这是仓库里**唯一**的测试入口文档。命令、层边界、fixture 约定、已知缺陷都以本文为准；
> 各版 QA 报告只提供历史证据，不再各自维护"怎么跑"。
>
> 当前锚点：代码 HEAD `102e4cb`（CLI 未知旗标报错 + `--help`；其后可能仅有文档提交），
> 二进制 `dd4d2db7…`，Agent `19e4596a…`（取法与漂移纪律见 `docs/README.md` §快照纪律）。
> **锚的是二进制 sha256，不是 HEAD**：sha 会随 checkout 路径变（见 §快照纪律），HEAD 只说明测试代码是哪一版。

---

## 0. 一分钟上手

```bash
cd /path/to/Mtool-M

# 前置：先有产品二进制。没有 build/ 时 kernel / faults / game 三层会直接 exit 2。
bash Scripts/build.sh

# 默认层：协议层。零 GUI、零网络、断网可跑。
bash Tests/e2e/run.sh --suite contract
# 末行：E2E PASS suite=contract cases=15 assertions=546

# 领域层：持久化/脱敏/日志/韧性/直通/缓存/全文往返；零 GUI（D9 例外）
bash Tests/e2e/run.sh --suite domain

# 其余三层（都需要 Aqua 图形会话；无桌面时整层 SKIP，不是失败）
bash Tests/e2e/run.sh --suite kernel     # 内置 WKWebView + 夹具
bash Tests/e2e/run.sh --suite faults     # 后端/端口/门禁的失败路径
MOCHI_E2E_GAME=/path/to/game bash Tests/e2e/run.sh --suite game   # opt-in 真游戏

# 一次跑完五层：contract → domain → kernel → faults → game
# （缺 MOCHI_E2E_GAME 时 game 层自动 SKIP）
bash Tests/e2e/run.sh --suite all

# 内建自检：不建窗口、不读网络、不写用户目录、默认不拉起浏览器
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest
# 末行：# pass 74 fail 0 skip 1
# 那 1 条 skip 是 browser_launch_and_terminate（真要拉起 Chromium）。
# 想连它一起跑（会真的起/杀一次 Chrome）：
MOCHI_SELFTEST_BROWSER=1 ./build/MochiBox.app/Contents/MacOS/MochiBox --selftest
# 末行：# pass 46 fail 0 skip 0

# 命令行用法：按模式分组列出旗标与退出码（exit 0）
./build/MochiBox.app/Contents/MacOS/MochiBox --help
```

成功时的末行固定为 `E2E PASS suite=<suite> cases=<N> assertions=<M>`；
失败时为 `E2E FAIL …` 且退出码 1。退出码含义：

| 退出码 | 含义 |
|---|---|
| 0 | 本层全部通过（含显式 SKIP） |
| 1 | 至少一条断言 `not ok` |
| 2 | 参数错误 / 缺 node / 缺二进制 / 环境不可用 |
| 3 | 产品侧 `port_unavailable` / `profile_locked` 等（由**被测进程**返回，用例把它当期望值断言） |

产品二进制自身的参数校验（`Sources/App/ArgumentValidation.swift`）在分流前执行：
未知旗标 → `error_code: unknown_argument` + `exit 2`；互斥模式/放错模式的旗标 →
`error_code: conflicting_arguments` + `exit 2`。所以把 `Tests/e2e/run.sh` 的
`--suite all` 误打到产品二进制上会立刻失败，而不是静默起 GUI。
`-psn_0_…`、`-NSDocumentRevisionsDebugMode`（Finder/`open` 注入）与裸参数仍放行。

---

## 1. 分层模型

| 层 | 依赖 | 用例 / 断言 | 运行时长量级 | 缺桌面时行为 | 覆盖什么 | 不覆盖什么 |
|---|---|---|---|---|---|---|
| `contract` | node ≥ 18；无网络、无 GUI、无二进制 | 15 / 546 | ~13 秒 | 照常跑 | Agent 协议语义：信封、去重窗口、跳过判据、rpc/cheat 表、scan 分片、路径安全、Swift 域模型探针 | 真 WebView 的布局/绘制时序、真实引擎 |
| `domain` | node ≥ 18 + 本机 `swiftc`（编译探针，只读 `Sources/`）；D9 另需二进制 + Aqua | 13 / 348 | ~37 秒 | 照常跑，D9 输出 SKIP（其余 8 个 case 不依赖桌面） | 持久化（库/设置）、脱敏与 0600、会话日志、韧性（合批/重试/熔断）、直通、缓存容量、全文导出/导入往返与语料清理、运行不改游戏目录 | 真实后端 RTT、真实游戏存档路径、UI 交互 |
| `kernel` | 产品二进制 + Aqua（WindowServer）+ 夹具 | 14 / 165 | ~22 秒 | 每个 case 输出一条 `# SKIP` 后返回，整层不判失败 | 真 WKWebView 里 `--play` 的启动识别、注入、采集→翻译→回写、控制通道、关窗收尾；消息窗**绘制文本与字号**（K12） | 真游戏内容、像素/字形/断行、真实后端 RTT |
| `faults` | 产品二进制 + Aqua | 10 / 55 | ~45 秒（F10 占满 100 个端口最慢） | 同 kernel | 401/429/500/非 JSON/endpoint 不可达/缺 index.html/未知引擎/控制门禁/端口占用 | 真实网络抖动、限流恢复曲线 |
| `game` | 产品二进制 + Aqua + `MOCHI_E2E_GAME` | 2（未设环境变量时整层 SKIP，`cases=0`） | 取决于作品（分钟级） | 同 kernel | 真实 MV/MZ 作品上的启动与关闭路径 | 翻译质量、全流程通关、修改器写盘 |
| `--selftest` | 仅产品二进制 | 75 条（74 pass / 1 skip） | 秒级 | 照常跑 | 域模型/Store/规则/CLI 分支的内建自检；C 组含 `reasoningOffMode` 的请求体字段与 400/422 去字段重发；**默认不拉浏览器**，`MOCHI_SELFTEST_BROWSER=1` 才有真浏览器生命周期用例 | 跨进程接线、GUI 交互 |

**为什么 kernel / faults / game 必须有桌面**：这三层跑的是产品真实的 `--play` 路径，
它会构造 `NSWindow` + `WKWebView`。WKWebView 的渲染与网络进程由 **WindowServer** 托管，
在无 Aqua 会话（SSH、launchd 的 non-GUI 上下文、CI 的 headless runner）里创建 WebView 会失败。
产品的行为是**明确退出 3**，stdout 出现：

```text
kernel_reason=no_aqua
error_code: kernel_no_desktop_session
```

用例识别这两行后走 SKIP，而不是把环境问题记成产品缺陷。

`contract` 与 `domain` 都不建窗口：前者用 `node:vm`，后者用 `swiftc` 编译小探针直接驱动产品类型
（`build.sh` 的 UI 依赖门禁保证核心层不 import AppKit/SwiftUI）。两者的差别是：`contract` 连二进制都不要，
是**唯一在无桌面、无构建产物的机器上能全量给出真实信号**的一层；`domain` 能跑 8/9，D9 需要真会话，
缺桌面时它会 SKIP。

---

## 2. 每层怎么跑

### 2.1 `contract`

```bash
bash Tests/e2e/run.sh --suite contract
# 或直接驱动执行器（等价）
node Tests/e2e/lib/run.mjs --suite contract
```

- 每个 case 是一个独立 node 进程，内部用 `node:vm` 载入**真** `Resources/agent_mvmz.js`；
  夹具用 `Fixtures/mv_stub/index.html` 的内联脚本原样跑（真 `$game*` / `$data*`）。
- 时钟注入、显式步进：同一命令重复跑结果一致。
- 13 个 case 覆盖：agent API、rpc/cheat 表、安全路径、信封协议、分段转义、去重竞态、
  跳过语义、查找变体、双端 parity、Store 探针、域模型 QA。

### 2.2 `domain`

```bash
bash Tests/e2e/run.sh --suite domain
```

- 零 GUI（D9 例外）：每个 case 用 `swiftc` 现编一支小探针（`Tests/e2e/cases/domain/probe_*.swift`），
  在 `mkdtemp` 出来的临时目录里直接驱动产品类型（Store / Pipeline / FullTextStore），
  不建窗口、不读 `~/Library`、不写用户目录。
- 需要 node ≥ 18 与本机 `swiftc`（Command Line Tools 自带），**不需要预先构建** `build/`；
  唯一的例外是 D9，它要跑一次真 `--play` 会话（`--close-after 5`），缺二进制或无 Aqua 时打 SKIP。
- 9 个 case：
  D1 库持久化、D2 设置持久化、D3 密钥脱敏与 0600、D4 会话日志、D5 韧性（合批/并发/重试/熔断）、
  D6 直通后端、D7 缓存容量、D8 全文翻译导出/导入往返与语料清理、D9 运行不改游戏目录。
- D5 的真实 3.5s 退避**不真等**：常量用断言钉住，行为用注入的退避表验证；熔断窗口在探针里压到 1.5s，**冷却与"队列继续翻译"是实测的**（见 `probe_resilience.swift` 文件头）。
- D5 的合批断言按 v0.7 语义重写（`maxBatch=60` / `maxConcurrent=4`）：**50 条 ≤ `maxBatch` → 1 块、
  1 次请求、每请求 `[50]`**（不再被 `maxConcurrent` 二次均分）；**240 条 → 4 块 × 60**；
  单请求超时逐条断言 `max(15000, 15000+条数×250)`；并用记录型 provider 断言**并发峰值 ≤ 4**、
  后端收到的条数总和 = 输入条数（无丢条/重复）。
- D5 熔断用例的新断言（`probe_resilience.swift` ⑥）：5 连败后 `backendStatus()` 为 `circuitOpen`；
  熔断期**零后端调用**、回调结果 **`items` 为空**（不得回填"译文 = 原文"）、`error.code = circuit_open`
  且 `retryable === false`；**队列不被消费** —— 解除失败后冷却结束，积压 3 条全部交付且只发 1 次请求。
- D8 追加"语料清理"用例（`probe_fulltext.swift` ⑪）：`origin` 为 `machine`/`cache` 且归一后
  `translated == raw` 的条目被清回未译（`segments` / `issues` 同时清空），`origin == manual`（如 `HP→HP`）
  与正常机翻不受影响；清理后条目仍在语料里，`translatedCount` 只统计后两者。

### 2.3 `kernel`

```bash
bash Tests/e2e/run.sh --suite kernel
```

- 必需：已构建的 `build/MochiBox.app`、当前用户有**登录的 Aqua 桌面**。
- 不需要 `MOCHI_E2E_GAME`：内核层固定用 `Fixtures/e2e_game`。
- 用例通过 `--control <unix socket>` 驱动页面（见 §5），不依赖截图。
- 12 个 case：启动识别、注入、采集翻译、跳过规则、去重窗口、缓存边界、作弊 rpc、
  幂等复原、关窗、无浏览器路径、控制码、消息窗绘制一致性（K12）。
- K12 是唯一读"屏幕上真的画了什么"的用例：夹具把消息窗的 `drawText`/`drawTextEx` 调用记进
  `__e2e.drawLog`，断言绘制文本 === 译文、绘制字号 === `round(基准 28 × fontScale)`，
  并用 `enabled=false` 做阴性对照（画原文）。没有它，把 `this._texts` 打空也能全绿。

无桌面时的真实输出（每条 case 一条，不判失败）：

```text
ok 1 - [kernel-k1] K1 # SKIP 无 Aqua 会话（kernel_reason=no_aqua，换一台有登录桌面的 Mac 再跑）
```

### 2.4 `faults`

```bash
bash Tests/e2e/run.sh --suite faults
```

- 同上需要 Aqua 与二进制。
- 10 个 case 的核心判据是**错误码 + 退出码**，不是"有没有报错"：

| case | 注入的故障 | 期望 |
|---|---|---|
| F1–F4 | 后端 401 / 429 / 500 / 返回非 JSON | `auth_failed` / `rate_limited` / `server_error` / `bad_response`，且退出码非 0 |
| F5 | endpoint 无监听 | `network` |
| F6 | 游戏目录缺 `index.html` | 明确错误码，不白屏 |
| F7 | 引擎无法识别 | `engine_unknown` 类错误 |
| F8 | 未设 `MOCHI_E2E=1` 却传 `--control` | `control_requires_e2e` + exit 2 + 不建 socket |
| F9 | `--control` 缺参数 | exit 2 + 用法，不把开关当路径 |
| F10 | 静态端口被占 | 自动顺延到相邻端口；100 个候选全占才 exit 3 + `port_unavailable` |

失败时的形态（真实 TAP，来自执行器重编号；下面的例子取自 game 层，详见 §2.5）：

```text
not ok 1 - [kernel-g1] G1 执行失败 # FATAL: 内核未就绪且进程已退出（exit=3）
# error_code: launcher_no_executable
```

### 2.5 `game`

```bash
MOCHI_E2E_GAME="/path/to/作品根" bash Tests/e2e/run.sh --suite game
```

- 未设置时：整层不执行，打印 `SKIP suite=game reason=MOCHI_E2E_GAME 未设置`，退出码 0（`cases=0`）。
- 设置后：2 个 case，分别验证真实作品能起会话、以及 `--close-after` 的关窗收尾。
- **设置错了会红**（这是真实的一次失败，把 `MOCHI_E2E_GAME` 指向非游戏目录即可复现）：

```text
#   play: root=/tmp engine=unknown provider=passthrough duration=45.0s
#   error_code: launcher_no_executable
# case 01_real_game: assertions=1 fail=1 25079ms
not ok 1 - [kernel-g1] G1 执行失败 # FATAL: 内核未就绪且进程已退出（exit=3）
1..2
# pass 0 fail 2
E2E FAIL suite=game cases=2 assertions=2
```
- 可选：`MOCHI_E2E_PROVIDER=passthrough|openai`、`MOCHI_E2E_ENDPOINT=…`。

### 2.6 全量

```bash
bash Tests/e2e/run.sh --suite all
```

逐层执行、逐层汇总；任一层有 `not ok` 即整体 exit 1 并打印 `failed_layers=`。
本机（2026-10-26、有 Aqua）的分层实跑末行：`contract 15/546`、`domain 14/373`、
`kernel 14/165`、`faults 10/55`、`game 2/11`。因此不设 `MOCHI_E2E_GAME` 时
`--suite all` 应为 **53 cases / 1139 assertions**（game SKIP）；设真游戏则 **55 / 1150**。

> 计数**只能**取自 run.sh 的末行，不要按套件手加：同一批用例在不同提交里出现过
> 218 / 225 / 528 / 954 / 965 五组互相矛盾的旧值，全部是手算或跨提交混算的产物。
> 本轮 `--suite all` 因真机验收占用 GUI 未跑，上表是四层**分别实跑**的末行求和，
> 与 all 的汇总口径一致（all 只是逐层执行后把 cases/assertions 相加）。

**TAP 可重放**：断言名只写判据，实测毫秒/临时端口一律放 `#` 诊断行或 `not ok` 的 `#` 原因里。
`--suite all` 连跑 2 次，`grep -E '^(ok|not ok)'` 的输出 `diff` 为空（断言名逐字节一致，状态不翻转）。
时间只出现在 `# case … <ms>` 这类诊断行里 —— 它不影响上述 diff，也不该被当作判据。

> 断言数会随用例增删而变化，**以 `run.sh` 末行为准**；本文所有数字是 2026-10-24 在本机实测的一次快照。
无桌面时 kernel/faults/game 三层各输出 SKIP（`domain` 的 D9 也 SKIP，其余 13 个 case 照跑），
整体仍为 PASS——**但报告里不得把 SKIP 写成"已覆盖"**。

**sha256 的可复现范围**：同一份源码在**同一 checkout 路径**下重复构建得到同一 sha256；
换一个路径（实测 `/tmp/mochibox-mut` → `/tmp/mochibox-mut3`）会得到不同 sha256 —— 两枚只差 116 字节，
差异在 Mach-O 的 `LC_UUID`。所以**跨路径核对 sha 必然不同**，不能据此判断"二进制漂移"。
核对基线的正确做法是二选一：
① 在原路径干净重建（`rm -rf build && bash Scripts/build.sh`）后比对 `Contents/MacOS/MochiBox` 的 sha256；
② 比对可复现输入（源码树 hash + `Resources/agent_mvmz.js` 的 hash）。
**二进制锚点锚的是 sha256，不是 HEAD**：docs-only 提交会前移 HEAD 而不改二进制。

---

## 3. 确定性 fixture：`Fixtures/e2e_game`

结构（`index.html` + `js/` + `data/` + `engine_stub.js`）：

| 文件 | 决定什么 |
|---|---|
| `js/rmmz_core.js` | `EngineDetector` 只要看到它存在就判 `engine=mz`（不读内容） |
| `data/System.json` | `gameTitle=E2E Fixture`、`advanced 816×624` —— 窗口标题与内容区尺寸的唯一来源 |
| `index.html` | 先 `<canvas id="game">`、后同步脚本；静态服务按发行版布局托管 |
| `engine_stub.js` | 四个 hook 的假引擎 + `window.__e2e` 驱动面 |
| `data/Map001.json` | 最小地图数据（夹具不跑地图逻辑） |

`window.__e2e` 只暴露驱动面，不绕过产品链路：

| 方法 | 语义 |
|---|---|
| `push(text)` | 走 `$gameMessage._texts` → `startMessage` → Agent hook → `emit('text')` |
| `pushMany([...])` | 一次多行消息，每行一条 TextEvent |
| `pushAt(index, text)` | 替换第 index 行后重新分页 |
| `drawTextEx(text)` / `drawBitmap(text)` | 直接打另外两个采集 surface |
| `render()` | 重新分页后让**消息窗真的画一次**（逐行走 `drawTextEx`），返回本次行数；绘制记入 `drawLog`（K12） |
| `drawLog()` / `drawCount()` | 消息窗绘制记录 `{kind,text,fontSize,x,y}`（上限 200 条）/ 总调用次数（不受上限影响） |
| `lastDrawn()` / `messageFontSize()` | 最近一次 `render()` 画出的文本 / 消息窗基准字号（未缩放，28） |
| `repaint()` | 只重绘 canvas，**不产生 TextEvent** |
| `version` / `originals` | 驱动面版本；`install()` 前的原始函数引用（供幂等复原断言） |

**为什么不用 `Fixtures/mv_stub` 当 `--play` 输入**：`mv_stub` 是单文件内联脚本，
目录形状不命中任何引擎签名，`EngineDetector` 认不出它，`--play` 会在启动前失败。
它只服务 `contract` 层的 `vm` 沙箱（那里需要的是假引擎对象，不是静态站点）。

**一改就会红的地方**：

1. 删/改 `js/rmmz_core.js` → 引擎识别变成 unknown，K1 起不来。
2. 改 `System.json` 的 `screenWidth/Height` 或 `gameTitle` → `content=816x624` 与标题断言失败。
3. 在夹具根放 `*.pck` / `Game.exe` / `project.godot` / `Game.ini` / `*.xp3` 等 →
   `EngineDetector` 按优先级先命中的是别的引擎，内核层整层失败。
4. 改 `engine_stub.js` 的 hook 名或在 `startMessage` 里再走一次 `drawTextEx` →
   同一句被两个 surface 各采一次，计数类断言（captured/translated）立刻漂移。
   绘制一律走 `render()`（K12），不要把它塞进 `push`：那会让所有计数类用例的 captured 都变大。
   反过来，把基类 `startMessage` 里的 `this._texts = texts.slice()` 改成 `[]`（消息窗不画任何东西），
   K3/K4/K5 仍然全绿 —— **只有 K12 会红**，这是这一层"绘制真的有断言"的唯一证据。
  5. 并行跑两个 kernel case → 同一 `webRoot` 的静态端口是确定性派生的（当前 `39330`），
   第二个实例拿不到端口。内核层必须**串行**执行（F10 才是刻意验端口冲突的用例）。
   上一次运行若留下未退出的 `--play` 进程，F10 会以 `listen EADDRINUSE 127.0.0.1:39330` 失败：
   先 `lsof -nP -iTCP:39330 -sTCP:LISTEN` 找出并（按 `--out` 精确匹配后）清理，再重跑。
   **本层自己不会再留下这类残留**（2026-10-23 修复）：`occupyPort().close()` 先 `destroy`
   已接受的连接再等 `server.close()` 回调（连接不断时回调永远不来，端口就留到下一个 case），
   F10 收尾还会逐个复查它占过的端口**能否重新 bind**，把"静默泄漏"变成一条具名断言。

---

## 4. 真游戏层（opt-in）

```bash
MOCHI_E2E_GAME="$PWD/reference/test-games/<示例作品>" \
  bash Tests/e2e/run.sh --suite game
```

- 本仓库唯一的真游戏素材是上述作品（RPG Maker MV 1.6.1，**846 MB**）。
- `reference/` 整体在 `.gitignore` 中：**干净 clone 跑不了 game 层**，这是设计而非缺陷。
- 它是 opt-in 的原因有三条：
  1. 体积与版权：素材不能入库，CI/新机器上没有；
  2. 时间：该作开场 OP 约 135 秒，标题菜单之前 `captured` 天然接近 0，
     固定短 `--duration` 会得到"看起来失败"的假红；
  3. 稳定性：真引擎的帧率/加载受机器影响，不适合当每次提交的硬门禁。
- 真游戏上的**作弊写入**（AC-9）与**全文翻译面板**（AC-10）仍属人工/专项验收，
  不在 game 层的 2 个 case 里。

---

## 5. 控制通道 `--control`

产品代码里的测试面：`Sources/Adapters/Control/ControlServer.swift`。

```bash
MOCHI_E2E=1 ./build/MochiBox.app/Contents/MacOS/MochiBox \
  --play Fixtures/e2e_game --control /tmp/e2e.sock --duration 20 --out /tmp/e2e.jsonl
```

- **门禁**：只有 `MOCHI_E2E=1` 时才生效。否则 `error_code: control_requires_e2e`、exit 2，
  且在创建窗口/socket 之前就被拦下。这条门禁是安全边界：通道能执行任意 JS。
- **协议**：unix socket 上的 NDJSON，一行一请求一行一应答；`id` 原样回显，用于并发配对。
- **只有 5 个 op**：

| op | 语义 | 关键返回 |
|---|---|---|
| `ping` | 存活探测 | `kernel` / `pid` / `uptimeSec` |
| `state` | **只读**快照，不触发 drain、不探场景 | `captured` / `translated` / `skipped` / `closed` / `scene` |
| `eval` | 在页面里执行表达式，可带 `timeoutSec` | 值或 `ok=false`；页面抛异常是 `js_error`，通道断了是 `channel_dead` |
| `close` | 模拟用户关窗 | `ok:true`，随后走正常收尾 |
| `quit` | 驱动端主动收工 | **先写应答再退出**，避免驱动端等不到回包 |

- 错误码分层：`bad_request`（请求形状）/ `unknown_op` / `js_error`（页面异常）/
  `channel_dead`（驱动层故障）。四者不可混用，否则用例无法判断"该重试还是该收工"。
- 为什么它是产品代码而不是测试脚本：它必须和 `--play` 共用同一个进程、同一个 WebView、
  同一份会话状态；外挂脚本无法在不引入第二套驱动的前提下做到这一点。门禁保证它不进入普通用户会话。

---

## 6. 断言纪律

规则全文见 `docs/acceptance-assertion-rules.md`，这里只列写用例时必须过的四关：

1. **期望值必须可追溯**：每条 `tap.eq` 的期望要么来自 PRD 条目号，要么来自源码契约
   （字段名、错误码、退出码）。禁止"跑出来是 3 就写 3"。
2. **禁止恒真断言**：`tap.ok(true, …)` 只能用于**显式 SKIP**，且必须带 `# SKIP` 后缀。
   任何"错误实现也能通过"的断言（只验不发生、不验阳性对照）都必须重写。
3. **失败必须可定位**：一条断言失败时要能指出哪一环坏（注入？采集？翻译？落盘？）。
   做不到就拆成更靠近故障点的多条断言，而不是加一句"整体失败"。
4. **口径只能走 PRD**：测试不得为了让现状变绿而放宽判据。现状与需求不一致时，
   要么开缺陷（`docs/backlog.md`），要么改 PRD，二选一。

补充约定：

- 每个 case 独立进程、独立 `MOCHI_DATA_DIR` 与 socket；用例之间不共享模块状态。
- 临时目录一律 `mkdtemp`，退出时清理；不写 `~/Library/Application Support`。
- 清理进程只按本次 `--out` 精确匹配，禁止 `pkill -f "MochiBox --play"`。
- 同一命令重复跑必须给出相同结论；依赖真实时间的断言一律注入时钟。

---

## 7. 已修复缺陷（含回归断言 ID）

2026-10-23 这一轮把 E2E 复核发现的六条产品缺陷全部修掉（每条一个独立 commit）。
原先"把现状钉成快照"的断言已改回契约值；下表给出修复记录与**回归断言 ID** ——
以后谁再改坏，跑对应层就会红在这一条上，而不是只红一个笼统的用例。

| 缺陷 | 一句话 | commit | 回归断言（层） |
|---|---|---|---|
| D17 / BUG-D1 | `requeue` 在"整批都是重复"时清空去重表，同一批信封第三次重放被重新接受 | `6048d7f` | `E-14b` / `E-14c`（contract `05_envelope`） |
| D18 / BUG-D2 | `cheat.giveItem` / `setItemCount` / `updateActor` 对非数字 `id` 静默夹到 1 | `13041c7` | `T-014-I` / `T-015-I` / `T-016-I`（contract `03_rpc_table`） |
| D19 / F-1 | 短 `sk-` 密钥（后接 <8 字符）不脱敏，明文进会话日志 | `e091c6e` | `D3` 短 key 4 条（domain `03_secret_mask`） |
| D20 / F-2 | `library.json` 备份名只到秒且先删后移，同秒第二次损坏覆盖上一份证据 | `1abfdd8` | `D1` 同秒两次损坏 2 条（domain `01_library_persist`） |
| D21 / F-3 | 缓存淘汰按写入时刻排序、命中不回写，实为 FIFO 却写"按最久未用" | `eadaf0f` | `D7` LRU 2 条（domain `07_cache_capacity`） |
| D22 / F-4 | `fulltext/` 的 0700 只在首次创建生效，已存在的 0755 不会收紧 | `c71e68e` | `D8` 目录已存在 2 条（domain `08_fulltext_roundtrip`） |

每条都按"先写新断言 → 对着旧实现跑红（留存 `not ok` 原文）→ 改实现 → 跑绿"走完，
红→绿的 TAP 与根因写在各自 commit 正文里，这里不重复。

**判据纪律（沿用）**：新增/修改断言一律写契约值，不写"跑出来是什么"。发现新缺陷时先在
`docs/backlog.md` 登记，再决定是修还是把缺口写进 §8 矩阵 —— 不允许把缺陷固化成期望值。

**本轮六条之外**，`docs/backlog.md` 仍有未收口的欠账（D9 诊断字段、D10 功能增量、D11 手工验收），
它们不是产品缺陷或需要先做产品决策，不在这张表里；§8 矩阵的"无/弱/缺口"是"没测过/未实现"，
不是"已知坏了还放着"。

---

## 8. 需求覆盖矩阵

<!-- 这张表是 P0-01…P0-20 + AC-9.1…9.4 + AC-10.1…10.5 共 29 条的**唯一**覆盖台账。
     强度口径：强 = 有阳性对照且失败可定位；中 = 主路径有断言但缺一条边；
     弱 = 只断了内部标志或「没崩」；无 = 没有自动化（不要读成「不需要验」）。
     改动用例时同步本表；「缺口」里的 GAP- / F- / D 编号指向 docs/backlog.md 或本文件 §7。 -->

| 需求ID | 需求摘要 | 覆盖层 | 承载用例 | 强度 | 缺口 |
|---|---|---|---|---|---|
| P0-01 | 首启合规提示 | — | 无自动化 | 无 | 仅手工（`manual-acceptance.md`）；弹窗文案与「勾选后不再出现」都无断言 |
| P0-02 | 添加目录三入口 + 去重 | — | 无自动化 | 无 | 仅手工；目录去重逻辑无断言 |
| P0-03 | 引擎识别 9 类 | contract | SelfTest A + contract `V6-01…V6-25` | 强 | RGSS1 无正例；「不阻塞 UI」零断言（见 §8.1） |
| P0-04 | 库持久化 | domain | D1 `01_library_persist` | 强 | `missing` 标志由 private 方法刷新，未直接断言 |
| P0-05 | 启动器 / 端口 / 两种失败 | kernel + faults | SelfTest F + `F06` / `F07` / `F10` | 中 | 进程非 0 退出 → stderr 前 20 行、完整命令行日志、`--remote-debugging-port` 实际传参均无断言 |
| P0-06 | CDP 端点等待 | — | 无自动化 | 无 | 产品主路径已改为内置内核（`kernel=embedded`）；该条对 chromium 后端仍适用，**架构已迁移，待产品确认是否废弃** |
| P0-07 | 注入 / 幂等 / 卸载复原 | contract | `01_agent_api`（A-09…A-24）+ kernel K2 / K8 | 强 | 页面 reload 后 hook 存活无断言 |
| P0-08 | 采集 / 行身份 / 800ms 滑窗 / 扇出 | contract | `06`–`09`、`11` + kernel K3 / K4 / K5 / K11 | 强 | 真实引擎的重绘节奏只有夹具级证据 |
| P0-09 | 回绘 / 跳过 | contract + kernel | `09_lookup_variant`、`08_skip_emit`、K11、K12 | 强 | K12 断到"消息窗真的画出译文"；真实绘制面的「数值类不被替换」仅手工 |
| P0-10 | 缓存 / 重启命中 / 命中率 / 淘汰 | domain | D7 `07_cache_capacity` + kernel K6 | 中 | 跨进程持久缓存未实现（GAP-P0-10）；淘汰已按 LRU 实现并断言（原 F-3 / D21，`eadaf0f`） |
| P0-11 | 直通后端 | domain | D6 `06_passthrough` | 强 | PRD 的 `translated === text` 主语未定义：passthrough 的 JSONL `translated` 字段**故意置 nil**（见 §8.1） |
| P0-12 | API / 设置 / 0600 / 脱敏 | contract + domain + faults | SelfTest C（含 `openai_reasoning_off_*`：auto / 显式模式的请求体字段、400/422 去字段重发）+ contract `V5-01…V5-05` + faults F1–F5 + domain D3 | 中 | 短 `sk-` 已脱敏并断言（原 F-1 / D19，`e091c6e`）；DeepL 401 无专测；`auto` 的 host 判定只断言 provider 构造结果（mock 只能监听 `127.0.0.1`，无法冒充 deepseek host） |
| P0-13 | 合批 / 重试 / 熔断 | domain | D5 `05_resilience` | 强 | 真实 0.5/1/2s 退避用注入接缝替代；熔断窗口在探针里压到 1.5s（常量仍用断言钉住），冷却后队列继续翻译已实测；真实网络超时未触发 |
| P0-14 | 翻译开关 | contract | `13_config_agent`（CFG-01…CFG-14） | 中 | 工具栏开关与「已暂停」状态列仅手工；Host→Agent 的 `config` 跨进程下发无 kernel 断言 |
| P0-15 | 字号缩放 | contract + kernel | `13_config_agent`（CFG-15…CFG-26）+ K12 | 中 | K12 断到内核层绘制字号 = round(28×fontScale)；滑杆 / ⌘+ / ⌘- 与数值持久化仅手工（持久化另见 D2）；Agent 侧不夹取越界（GAP-P0-15），夹取在 Swift 设置层（D2 已断 9.0→1.3） |
| P0-16 | 停止与清理 | kernel | K9 / K10 | 中 | SIGTERM→3s→SIGKILL 顺序、⌘Q、端口释放均无断言 |
| P0-17 | 无网络降级 | faults | F5 `05_endpoint_dead` | 弱 | `unsaved` 直通态与恢复网络后自愈未实现 / 无断言 |
| P0-18 | `--selftest` | 自检 | `--selftest` 71 条（70 pass，1 条真浏览器用例 opt-in skip） | 强 | TAP 格式、失败退出码、`--filter`、「不建 NSApplication」无断言 |
| P0-19 | 日志与导出 | domain | D4 `04_session_log` | 中 | 实现改为按份数保留 50（非 5×2MB，GAP-P0-19）；「导出诊断」未见实现 |
| P0-20 | 设置持久化 | domain | D2 `02_settings_persist` | 强 | —（缺字段 / 类型非法 / 越界 / 损坏 / 只读均有断言） |
| AC-9.1 | 状态快照 | contract | `02_agent_rpc` R-02 / R-03 / R-04 / T-001-H | 中 | 无「外部改引擎对象 → 快照跟随」的阳性对照 |
| AC-9.2 | 修改器数据可信 + 菜单显示一致 | contract | R-02 / R-03 / T-001-H（数据面） | 强 | 数据面有断言（读回原值 + 越界错误码）；**菜单显示一致无自动化**，仅手工（§8.2） |
| AC-9.3 | 作弊不崩、越界有错误码 | contract | R-09…R-19、R-45 / R-46、`04_safe_path`、`14_update_actor_equips`、K7 | 强 | 「游戏不崩」是代理断言（进程存活 + 无异常标记） |
| AC-9.4 | 穿墙 / 遇敌 / FPS 等效果 | contract | R-21 / R-26 / R-28 / R-30 / R-32（均为内部标志） | 弱 | 穿墙位移、遇敌次数、FPS 无真实观测量 |
| AC-10.1 | 扫描 30s 内完成或可取消；UI 不卡 | contract | R-48…R-57 + T-043 / T-044 | 中 | 30s 完成时限、主线程 60fps 无测法（见 §8.1） |
| AC-10.2 | 重启自动加载译文 | — | 无自动化 | 无 | 仅手工；「是否已实现」未确认 |
| AC-10.3 | 导出 ManualTransFile | domain | D8 `08_fulltext_roundtrip` | 强 | 真实游戏存档路径下的导出未验 |
| AC-10.4 | 导入后未译数下降 | domain | D8 `08_fulltext_roundtrip` | 强 | 「未译数下降」无量化口径（见 §8.1） |
| AC-10.5 | 不改游戏目录 | domain | D9 `09_game_dir_untouched` | 强 | 逐文件 sha256 + 文件集合 + 汇总摘要；无桌面时整条 SKIP |

> **强度为「无」的 4 条**（P0-01 / P0-02 / P0-06 / AC-10.2）不是「不需要验」，而是
> **当前没有任何自动化证据**。引用本表时不得把它们算进「已覆盖」。
> P0-06 还多一层：产品主路径已从外部 Chromium 迁到内置 WKWebView（`kernel=embedded`），
> 该条是否仍需保留要产品先拍板。

### 8.1 需求本身不可判定（原文引用）

下面这些句子在 PRD 原文里**没有可判定口径**，测试只能取可观测的替代物。
把它们列出来，是为了让「没测」和「测了但只测了半句」不被混为一谈。改 PRD 之前不要给它们标「强」。

| 条目 | 原文 | 为什么不可判定 | 测试实际断的是什么 |
|---|---|---|---|
| P0-03 | 「单目录扫描不阻塞 UI（>500ms 的操作不得在主线程）」 | 「主线程」是实现概念，PRD 未给基线机型与 500ms 的测法，也没有可注入时基 | 只断识别结果与 `reason`；**阻塞时长零断言** |
| P0-15 | 「缩放后不出现文本绘制异常（Agent `errors` 计数为 0）」 | 「异常」未定义（抛错？花屏？断行错位？），括号里只给了计数这一个代理 | `errors === 0` + 绘制层字号；**字形 / 断行 / 溢出无观测** |
| P0-19 | 「导出文件中不得出现明文 key 或完整游戏路径外的用户隐私内容」 | 「用户隐私内容」未枚举；游戏路径本身被允许出现，边界不可判 | 只断 `sk-` / `Bearer` / `DeepL-Auth-Key` 三种形态脱敏与 0600 权限 |
| P0-11 | 「`translated === text`」 | 主语未定义：Agent 的 `TextEvent.translated`、pipeline 的 `translatedText`、JSONL 的 `translated` 是三个不同的值。实现里 passthrough 的 JSONL 字段**故意置 `nil`**（`Sources/Domain/TextStreamStore.swift:295`：「passthrough 时 translated 一律置 nil」），只留 `status=passthrough` | 断 provider 与管线两层的译文逐字节等于原文 + 零网络请求；**不断 JSONL 的 translated 字段** |
| AC-10.4 | 「导入 MTool 格式人工译文后，未译数下降」 | 「下降」无量化：降 1 条算过？降到 0 才算过？ | 断导入后未译条目的具体数值（D8 的夹具口径），**不是「任意下降」** |
| AC-10.1 | 「UI 不卡（主线程 60 fps）」 | 无测法：采样窗口、允许掉帧比例、基线机型都未定义 | 只断扫描分片 / 取消的协议行为；**帧率零观测** |

### 8.2 只能手工验证

以下条目**没有**自动化证据，只有 `docs/manual-acceptance.md` 的人工签字路径：

- 首启合规弹窗：文案、勾选后不再出现、拒绝即退出（P0-01）
- 添加目录的三个入口与去重（菜单 / `⌘O` / 拖拽）（P0-02）
- 设置表单即时生效：模型、endpoint、语言对、后端切换、危险操作确认（P0-12 / P0-20）
- 字号滑杆与 `⌘+` / `⌘-` 的观感、是否真的「看起来变大了」（P0-15）
- 「导出诊断」产出的单个 `.txt` 内容是否齐全（P0-19）
- 画面内译文的实际渲染：断行、溢出、`◇` 标记、数值类不被替换（P0-09）
- 游戏内菜单与修改器面板显示是否一致（AC-9.2）
- 穿墙位移、遇敌次数、FPS 等「效果类」验收（AC-9.4）


---

## 9. 历史与口径

- **旧探针已移除**：`Tests/qa/probe_channel.mjs`、`rpc_probe.mjs`、`scan_probe.mjs`、
  `run_stub_probes.sh` 以及 `Tests/e2e/play_e2e.sh` 已随统一入口重写删除；
  它们的能力迁入 `contract` 的 13 个 case 与 `domain`/`kernel`/`faults` 层。
  `Tests/qa/` 现存 `control_smoke.mjs`（控制通道 TAP 冒烟）、`frame_stats.swift`（截图帧统计）、
  `error_server.py`（域模型 QA 用）与 sha 清单，它们不参与 `run.sh` 的分层调度。
- **Chromium / Playwright / CDP 不再是测试方式**：产品默认路径是内置 WKWebView，
  E2E 也不再借助外部浏览器驱动；`tools/` 的 Playwright 依赖声明已删除。
  唯一例外是 `--selftest` 的 `browser_launch_and_terminate`（真浏览器生命周期），
  它默认 SKIP，只有显式 `MOCHI_SELFTEST_BROWSER=1` 才会起 Chromium。
- **多版 QA 报告已合并**：`docs/qa-report.md` 是唯一当前有效报告；
  V0.2/V0.3/V0.4/V0.5 原文见 git 历史（路径列表见该报告 §5）。
- **`Scripts/VERIFY.md` 是 V0.1 存档**（2026-10-20），其中 27/29 条 selftest 等数字已被 71 条取代，
  只作回溯用。
