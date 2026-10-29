# MochiBox · 产品需求文档（PRD）

| 项 | 内容 |
|---|---|
| 文档类型 | 简单 PRD（不含竞品分析） |
| Language | 中文 |
| Programming Language | Swift 6 / SwiftUI，仅用 `swiftc` + Command Line Tools 构建，无第三方运行时 |
| 最低系统 | macOS 13.0（构建产物默认 arm64） |
| Project Name | `MochiBox` |
| 依据 | `docs/re-findings.md`（MTool 逆向证据档案） |
| 版本 | **v0.6.0**（V0.6：新增 §3.4 AC-9 修改器 / AC-10 全文翻译的验收口径）<br>历次口径修订（v0.3.4 存档 + 同日内部修订一…十二）见 [prd-changelog.md](prd-changelog.md) |
| **交付范围** | **当前版本 V0.6（修改器 + 全文翻译）**；历史交付范围见 `docs/archive/v0.1/delivery-scope-v0.1.md`（V0.1）与 `docs/archive/v0.2/delivery-scope-v0.2.md`（V0.2）。V0.1 的范围窄于本 PRD 的 P0 全集（如 P0-19 日志滚动与诊断导出、Onboarding、DetailPane、静态预翻译等**不在 V0.1 交付**），属交付节奏取舍，**不代表验收标准变更** —— 未交付项的验收标准保持原文，作为后续轮次输入。 |

---

## 0. 原始需求复述

MTool 是 Windows/Android 上的"游戏进程内注入 + 文本总线 + 翻译渲染"工具，核心资产是一组按引擎分别注入的原生 DLL，注入手段（`CreateRemoteThread`+`LoadLibrary`、`winmm.dll` 劫持、命名管道、改 PE）在 macOS 上全部不可分发或不可用，官方也无 macOS 版本。

本产品在 macOS 上重新实现**同一条业务流的最小子集**：原生 Swift/SwiftUI 宿主 App，通过"给 NW.js/Chromium 系游戏追加 `--remote-debugging-port` 并用 CDP 注入 Agent"这一**唯一不需要签名豁免、不修改游戏文件**的通道，实现 RPG Maker MV/MZ 的原文采集、译文回绘与翻译缓存。范围严格限定在 P0 六项，不扩大。

---

## 1. 产品目标与非目标

### 1.1 产品目标（一句话）

> 在 macOS 上以不修改游戏文件、不需要系统权限或签名豁免的方式，为 RPG Maker MV/MZ 游戏提供"原文实时采集 → 缓存优先翻译 → 译文回绘到游戏画面"的可用链路，并保证同一句文本在本地只翻译一次。

### 1.2 目标拆解（3 个正交目标）

| # | 目标 | 判定方式 |
|---|---|---|
| G1 | **可进入**：用户能把游戏加进库，并看到"引擎是什么、能不能用、为什么不能用" | 库内每个条目都有 `engine` + `supportLevel` + `engineEvidence`，未知项必有 `reason` |
| G2 | **可打通**：MV/MZ 游戏能被本 App 启动并 attach，Agent 能采集到文本并回绘译文 | 会话状态机可观察（`idle→launching→attaching→attached→translating`），文本流出现"译文"列非空的行 |
| G3 | **可省钱/可降级**：同句只译一次；后端不可用或无网时显示原文且不崩溃，冷却后自动重试 | 缓存命中率可显示；断网场景下 App 不崩溃、文本流仍增长 |

### 1.3 非目标（本轮明确不做）

1. 不做 Windows / Android 端；Windows 侧 DLL 注入、命名管道、PE 改写一律不复刻。
2. 不随包分发、也不内置任何游戏资源、RTP、字体文件，以及 MTool 的二进制/DLL/字节码/加密模块。
3. 不做内购解锁、授权/DRM 绕过、存档文件改写（`Save_MTool` 之类一概不做）。
   运行期数值修改（修改器）**自 V0.6 起纳入范围**，但仅限单机 MV/MZ，见 §7.3 与
   `docs/architecture-v0.6-cheat-and-fulltext.md`。
4. 不做"汉化补丁打包"：不产出被翻译过的游戏副本，翻译只存在于运行时绘制层。
5. 不做图像/OCR 翻译、语音翻译、Unity/Godot/吉里吉里/WOLF 适配（P2 之外不承诺）。
6. 不做云端账号、云同步、在线译文社区、内购。
7. 不做 Ren'Py 适配器的**实现**（本轮只写需求，见 P1）。

---

## 2. 目标用户与用户故事

### 2.1 目标用户

| 画像 | 描述 | 关键诉求 |
|---|---|---|
| U1 日语苦手玩家 | 有正版日文 RPG Maker 游戏，macOS 上无汉化可用 | 打开就能看懂对话，不要配置 |
| U2 有 API 的技术用户 | 自己有 OpenAI/DeepL 兼容的 endpoint 与 key | 可控成本、不重复计费、能看原始请求 |
| U3 译者/校对者 | 想把游戏原文批量导出后自己翻译 | 文本流要可读、可复制、带上下文与出现次数 |

### 2.2 用户故事（含验收标准）

**US-1 添加并识别游戏**
> 作为 U1，我把游戏文件夹（或 `.app`）拖进窗口，就希望看到"这是什么引擎、这台机器上能不能用"，这样我不用去论坛问。

验收标准：
- AC1.1 拖入一个 MV 目录，3 秒内列表出现条目，`engine` 显示 `RPG Maker MV`，`supportLevel` 显示 `可启动`，证据区列出命中的 `www/js/rpg_core.js`。
- AC1.2 拖入 Unity 目录，`engine` 显示 `Unity`、`supportLevel` 显示 `不支持`，并给出"原因：macOS 无合法注入面（P2）"。
- AC1.3 拖入一个空目录，条目状态为 `未知`，原因码 `no_signature_matched`，并说明"未找到任何引擎特征文件"。
- AC1.4 关闭 App 再启动，库中条目全部还在，顺序不变。

**US-2 启动游戏并读到中文**
> 作为 U1，我点"启动"，游戏窗口出来、对话框里出现中文，并且我能看到"原文 / 译文 / 状态"三列对照。

验收标准：
- AC2.1 点击启动后，会话头状态依次出现 `启动中 → 连接中 → 已连接`；已连接时显示实际调试端口号与页面 URL。
- AC2.2a **采集（2s）**：游戏内出现第一句对话后 2 秒内，文本流新增一行，原文列等于该句原文（含转义码原样），状态列 ∈ {`命中`, `新译`, `pending`}。此条只考核"采集并上屏"，**不考核后端往返**。
- AC2.2b **收敛（5s）**：若该行状态为 `pending`，必须在 5 秒内转为 `新译` 或 `错误`；不得停留 `pending` 超过 5 秒，不得出现无状态空行。
- AC2.2c **确定性基线（1s）**：把后端切到 `--selftest` 自带的本地 mock 后端（RTT ≤50ms）后重复同一场景，该行必须在 1 秒内到达 `新译`，且原文与译文均非空。
  **强制前置步骤**：必须在**同一个进程内**先完成"切到 mock 后端"再开始计时；**不得**把"设置里改后端 → 重启 App"的耗时算进 1s。因默认后端是 `passthrough`（见 §6 D-2），未切 mock 时永远不会有 `新译` 状态 —— 缺这一步得到的 `passthrough` 结果不可判为失败，应判为用例执行错误。
  > QA 的**自动化**用例只断言 AC2.2c；AC2.2a / AC2.2b 为手工用例。说明：静态预翻译已降为 P1-10，首句必然走 `miss → pending → 网络 → 新译`，因此"2 秒内出现译文"不作为 P0 断言；真实后端的 RTT 差异由 AC2.2b 的 5 秒收敛上限兜住。
- AC2.3 译文列非空后，游戏画面内该句以译文渲染（人工判定）；数值类文本（金币数、HP 数字）不被替换或错位。
- AC2.4 点"停止"，游戏进程退出，App 状态回到 `未连接`，`ps` 中不残留该游戏进程。

**US-3 不重复计费、断网不崩**
> 作为 U2，我填了自己的 endpoint 和 key，同一句反复出现只应扣一次费；断网时 App 不能挂。

验收标准：
- AC3.1 **多行模型（五种情形必须分开断言；判定基准只有"间隔"，不用"离屏"）**
  - **a｜间隔 > 800ms 后再次出现**：同一 `surface` + 同一 `raw`，距**上次绘制**已 **> 800ms** 后再次出现 → **每次各成一行**；第 1 行 `新译`、后续 `命中`；`occurrences` 按**行**累计 `1/2/3`，**不回填已渲染行**（避免列表抖动）。
  - **b｜持续可见（阴性对照）**：同一条消息**连续重绘**（每次间隔 < 800ms，如每 400ms 整轮重绘 8 次）→ **只 1 行**，`occurrences` **保持 1 不增**。**这是正确行为；判为重复行、或判为缺陷，均为误判。**
  - **c｜续期判别（唯一能区分"续期"与"不续期"的用例）**：连续重绘 8×400ms 后，**立即（+100ms）再绘一次** → **仍为 1 行**。
    *为什么必须单独测*：若实现只在首次记录时间戳、不续期，则"距首次"已超 800ms，这一笔会新增行；而"每次重绘刷新时间戳"的正确实现不会。**a 与 b 各自都能被两种实现同时通过，只有 c 能分辨。**
  - **d｜多身份交错（区分"全局单一时间戳"缺陷）**：两个不同身份 A、B 交错出现，间隔均 < 800ms：
    `t=0 A → 1 行`；`t=100 B → 必须再 1 行`；`t=200 A → 不新增`；`t=300 B → 不新增`。**期望 A、B 各 1 行，共 2 行。**
    *若实现用单个全局 `lastSeen` 而非 per-identity，B 会被误吞，只得 1 行*（a/b/c 全是单身份场景，测不出这个缺陷）。
  - **e｜同 `raw`、不同 `surface`（区分"签名漏了 `surface`"缺陷）**：`Window_Message` 画 `こんにちは` → 1 行；100ms 后 `Window_ChoiceList` 画同一 `こんにちは` → **必须再 1 行**。
    **期望 2 行，且两行共享同一条缓存（`cacheKey` 相同）**。签名若只按 `raw`（漏 `surface`）会只得 1 行；本条同时验证"身份 = 两者的组合"，而不是"两者之一"。
  - **阳性断言（防"永久去重"）**：同一 `raw` → 间隔 **1.6s** → 再绘制 → **必须新增第 2 行**；若仍只有 1 行，判严重缺陷。
  - **断言写法要求**：不得用"事件总数"作判据（总数取决于重绘节奏，不是契约值）；应断言"**出现过哪些 `(surface, raw)`**"及各行的 `occurrences` 序列。
  - **边界取值要求（防 flaky）**：不得测 800ms 的精确边界（`sleep(800)` 会因调度抖动落在两侧）。**窗内用 ≤400ms、窗外用 ≥1600ms**；若要覆盖边界判定，只在实现内做单元级判断，不做 E2E。
  - **实测依据（可控时钟探针，`Date.now` 替换为受控变量）**：首绘后 `=1` → 隔 1600ms 再绘 `=2`（窗口到期会重新上报，**非永久去重**）→ 随后连续 8×400ms 重绘仍 `=2`（续期抑制，不重复上报）。
- AC3.2 拔掉网络后再触发新句，10 秒内该行状态变为 `直通`（或 `错误`+可重试），App 不崩溃；网络恢复后新句恢复正常翻译。
- AC3.3 设置页填错 key（401），界面出现"后端不可用：认证失败"提示，且不弹窗刷屏（同一错误 60 秒内只提示一次）。

---

## 3. 需求池

优先级：**P0 = 本轮必须交付（MVP）**；P1 = 本轮只写需求不实现；P2 = 仅列出。
所有 P0 条目必须可被 QA 以"操作 → 可观察结果"的方式单独验证。

### 3.1 P0 需求表

> **写断言时的"三问"（起草规则，非需求条款）**——每条验收断言落笔前必须逐问，缺一问就漏一类缺陷：
> ① **错误实现能通过吗？**（能否被证伪；通不过则断言形同虚设）
> ② **正确实现能通过吗？**（有无假阳性；通不过则会把正确行为"修坏"。反例：曾以"译文 == 原文"判假译文，误伤 `OK`/`BGM` 等恒等翻译）
>    *操作化*：**凡枚举样本，先分"成功组 / 失败组"，再分别写断言**。把正确路径混进失败判据是假阳性最常见的来源（反例：把 `200` 与 `401`/`429` 并列要求"返回错误码"；把 `passthrough` 的"译文=原文"与"假译文"并列禁止）。
> ③ **有阳性对照吗？**（不只验"不该发生"；缺这条时**沉默的实现最容易全绿**——不请求、不写缓存、不回填，阴性断言全过）
>
> 三问的共同点：问的是**断言自己会不会出错**，不是"覆盖了没有"。另：断言尽量落到**最靠近故障点**的可观测项，避免"一处失败但看不出是哪一环坏"。
>
> **枚举时的附加判据（"原因 ≠ 结果"）**：凡写"某集合里有这几个成员"，先问**这个集合是按结果分类还是按原因分类**。
> - 按**结果**分类（成功 / 失败）→ 可以直接枚举，但每个成员都必须有对应断言；
> - 按**原因**分类（`code` / error kind / 文本内容）→ **不得**用来推断结果属性（`retryable`、是否告警、是否算脏数据、是否展示），必须回到**条件**上判。
>
> 反例（同一类错误已出现 4 次）：用 `code` 推 `retryable`（`bad_response` 在 5xx/4xx 答案相反）、用"内容相等"推"是否假译文"（误伤恒等翻译）、把 `200` 与 4xx/5xx 并列要求"返回错误码"、把 `circuit_open` 顺手划进 `retryable=true`。
>
> **操作化对策：把定义贴在列表末尾。** 上述 4 例的成因不是"不懂定义"，而是**列到第 5 个成员时已切到"补全模式"**，按"直觉上像不像"补，不再回看定义。因此：
> - 凡枚举列表（code / 样本 / 字段取值），**定义必须同时写在列表头与列表尾**，或每个成员后附"→ 依据：<定义原文>"；
> - **新增成员时必须回引定义一次**，不得只凭"它也是错误/它也是样本"归类。

| ID | 需求 | 优先级 | 验收标准（QA 可逐条执行） |
|---|---|---|---|
| P0-01 | 首次启动合规提示 | P0 | 全新配置下启动，主界面不可交互，模态框显示"你需自行拥有游戏 / 本工具不绕过授权 / 文本会发送到你所配置的翻译后端"三项，须点"我已知悉"才进入；`settings.json` 写入 `complianceAckVersion`；删除该字段后重启，提示再次出现 |
| P0-02 | 添加游戏目录 | P0 | 支持三种入口：菜单"添加游戏"、`⌘O` 文件选择器（支持选文件夹与 `.app`）、把文件夹拖入窗口。每种入口成功后库内新增 1 条且不重复（同一路径二次添加时聚焦已有条目而非新建） |
| P0-03 | 引擎识别 | P0 | 按 §A.1 的固定优先级对 9 类引擎（MV/MZ/Ren'Py/RGSS1-3/WOLF/KiriKiri/EasyRPG/TyranoBuilder）各给出正确 `engine`；识别不了时 `engine=unknown` 且 `reason` 为 §A.1 的枚举值之一；扫描深度 ≥2 层，能识别 `.app/Contents/Resources/app.nw` 布局；单目录扫描不阻塞 UI（>500ms 的操作不得在主线程） |
| P0-04 | 游戏库持久化 | P0 | 库写入 `~/Library/Application Support/MochiBox/library.json`；重启后 `id/name/path/engine/addedAt` 不变；用户手动移走游戏目录后重启，条目仍在但标记 `missing`（不自动删除）；文件损坏时以空库启动并把坏文件改名为 `library.json.bak-<ts>` |
| P0-05 | MV/MZ 启动器 | P0 | 启动参数包含 `--remote-debugging-port=<port>`，`port` 从 `39200–39300` 中选取且启动前确认可用；启动前在会话日志打印完整命令行；支持"目录内 `nwjs.app/Contents/MacOS/nwjs`"与"目录本身是 `.app`"两种布局；**启动失败按两种情形分别验收**：① 进程非 0 退出 → 显示 stderr 前 20 行；② 可执行文件缺失（进程未起、**无 stderr**）→ 显示已尝试的路径列表，错误码 `launcher_no_executable`（`detail=no_executable_found`）。两种情形均使会话回到 `未连接` |
| P0-06 | CDP 端点等待与 attach | P0 | 轮询 `http://127.0.0.1:<port>/json/list`（间隔 250ms，上限 25s）直到出现 `type=page` 目标；attach 成功需完成 `Page.enable` + `Runtime.enable` 并显示页面 `url`；超时显示 `attach_failed` 并附最近一次 HTTP 响应体前 512 字符；若 `/json/version` 的 `Browser` 主版本 ≥111，追加 `--remote-allow-origins` 参数重试一次；端口/进程在"停止"与 App 退出时释放 |
| P0-07 | Agent 注入 | P0 | Agent 脚本作为独立资源 `Resources/agent_mvmz.js` 注入；同时用 `Page.addScriptToEvaluateOnNewDocument` 与 `Runtime.evaluate` 各注入一次（保证页面刷新后仍在）；注入后页面 `window.__mochibox.version === 1`；重复注入不重复 hook（`window.__mochibox.installed === true` 时跳过）；`window.__mochibox.uninstall()` 后原函数恢复（`drawText === __mochibox._orig.drawText`）；**阳性断言（不得只验"卸载成功"）**：`uninstall()` 后**再注入一次**，必须能重新采集（文本流继续新增行）、`installed === true`、`version === 1`，且 hook 不叠加（`drawText` 只被包一层，输出一条事件而非两条）——一个"卸载后不再装"或"重复包装导致重复 emit"的实现必须被这条拦住 |
| P0-08 | 原文采集与文本流 | P0 | hook `Window_Base.prototype.drawText`、`Window_Base.prototype.drawTextEx`、`Bitmap.prototype.drawText`；每个绘制字符串产生 1 条 `TextEvent`；**行身份 = `surface` + `raw`**（按 `raw`，**不得按 `key`/剥码后的 `text`**——否则 `350` 与 `\C[2]350` 签名相同，后者会被静默吞掉）；**去重窗口 = "距上次同身份绘制已超过 800ms"**（**滑动续期**，非固定分桶；连续可见期间每次重绘续期，故持续可见只出 1 行；**距上次绘制 > 800ms 后再次出现即新增一行**），**不得按帧号分桶**（跨帧重绘压不住，会重现行数风暴）；**窗口外再次出现必须新增一行——禁止"永久去重"**（同一身份在会话内只 emit 一次属严重缺陷，会让文本流变成"每句只出现一次"的假象）；**间隔必须用单调时钟计算**（`performance.now()`），**不得用 `Date.now()`**——墙钟会被系统校正或用户修改，产生**负间隔**（永不新增行、文本流卡住）或**巨间隔**（每次重绘都新增、行数暴增），两者都不报错；**清空视图（`clear`）只清视图，不清 Agent 侧去重状态**——因此清空后 **800ms 内**重绘同一句**不会新增行**，**超过 800ms** 后重绘**正常新增**；**这是预期行为，不是缺陷**（否则每次清空都会得到一条重复行）；**宿主侧行身份、扇出与计费断言（样本必须分开，一个样本只测一件事；现为 A / B / C 三个样本）**：① **样本 A｜`350` + `\C[2]350`**（两者都 `skipped(numeric)`、**不碰后端**）→ **只**断言 **`rows.count == 2`**（专验"行身份按 `raw` 而非 `cacheKey`"）；② **样本 B｜`こんにちは` + `\C[2]こんにちは`**（可翻译、剥码后同 `text` → 同 `cacheKey`）→ 断言 **`rows.count == 2` 且 `newTranslations == 1`**，且两行**都**须在 5s 内离开 `pending`（扇出）；③ **B + mock 401** → 两行**都是 `错误`**（不得一行错误、一行 `pending`）。<br>**⚠ 不得用样本 A 断言"不重复计费"**：A 的两条都被跳过、**一条请求都不发**，"计费为 1"在该样本下**恒真且无意义**，一个"两行各发一次请求"的过度修复用 A 也测不出来——**计费与扇出必须用 B**。<br>**⚠ B 组断言边界**：只验**行数 / 请求数 / 状态收敛**三件，**不验两行各自的转义码形态**（如"`\C[2]こんにちは` 的译文应以 `\C[2]` 开头"）——同一 `mapKey` 不同 `raw` 共享同一格译文，渲染可能丢码或凭空加色，属 **BUG-11（已知，本轮不修）**，该断言必红且属"已知缺陷被新断言撞上"，非实现退步；下轮修 BUG-11 后再补。<br>④ **样本 C｜同一批次内 `cacheKey` 不同**（`こんにちは` + `おはよう`，两句同时在飞行中）+ **mock 401** → **两行都是 `错误`**（专验 §5.4 的**整体失败**形态：`items` 为空时只在遍历 `items` 才落状态的实现**一行都不会变**，两行会永久 `pending`）。**③ 的批次只有 1 个 `item`，锁不住这一点——③、④ 必须同时存在，缺 ④ 即漏。**文本流显示时间/原文/译文/状态四列；超过 5000 行时仅保留最近 5000 行（内存上限可配置）；原文列**原样保留**转义码（如 `\C[2]魔物`） |
| P0-09 | 译文回绘 | P0 | 已知译文时，Agent 以译文替换 `drawTextEx`/`drawText` 的 text 形参后交给原函数；转义码位置不变；**跳过规则（两条正则均须锚定）**：`^\d+$`（纯数字）、`^[\p{P}\p{S}\s]*$`（纯符号/纯空白）命中即跳过，且**既不请求后端、也不写入缓存**；**判定对象是剥码后的 `text` 而非 `raw`**（见 §5.1：`\C[2]350` 剥码后为纯数字 → 跳过，但原文列仍显示 `\C[2]350`）；**全角数字同样算纯数字**（`３５０` 须跳过，不得依赖正则方言对 `\d` 的全角支持）；**判定前须做等价归一**（NFKC + 空白折叠 + trim）——`"350 "`（尾空格）、`"３５０"` 均须判为纯数字，不得因未归一而漏跳；**反例（不得跳过）**：`10秒後`、`第2章`、`350G`、`\C[2]10秒後` 这类"含数字但非纯数字"的句子**必须翻译**，判为 `skipped` 即失败（与 §5.2 `skipReason=numeric` 的"纯"字一致）；**判据边界对照（两条必须成对记，缺一会诱导"顺手统一"）**：`"3 5 0"`（数字间夹空格）**不跳过**——`numeric` 只认**整串**数字，**不剥内部空白**；`"! !"`（标点夹空格）**跳过且 reason=punctuation**——`punctuation` 才先移除 5 个折叠码位。**"剥不剥空白"是按 reason 分开决定的，不是全局规则**；替换后不抛异常（`window.__mochibox.state.errors` 计数为 0）；**跳过与回绘的三条并列断言（三条都必验，缺一即覆盖不全）**：(1) **计费**——`newTranslations` 计数不变、无 HTTP 出站；(2) **脏数据**——`cache` 条目数不新增（内存与落盘两处**判据同源**，不得各写一套）；(3) **假译文**——跳过项 `status` 必须为 `skipped`，**不得**落 `hit`/`translated`；且**缓存中不得存在"其 `text` 按同一跳过判据应被判为跳过"的条目**（**判据问来源、不问内容**：遍历条目取其 `text` → 跑同一个 `skipReason` → 返回非 nil 即脏条目）。<br>**⚠ 禁止以"`translatedRaw == raw`"作为假译文判据**：恒等翻译（`OK` / `BGM` / `HP` / `MP` / `SAVE` / `TITLE` 及拉丁缩写）是**合法且常见**的后端返回，据此判失败会造成**假阳性**，并可能诱导实现方把正确行为"修坏"（强行再翻或塞进跳过规则）。<br>**边界（仅作用于 `status`）**：`passthrough` 下 `translatedRaw == raw` 合法，但必须由 `status = passthrough` 显式标记（见 P0-11）并在界面提示，**不得静默标记为 `hit` 冒充译文** |
| P0-10 | 本地翻译缓存 | P0 | 缓存文件 `cache.jsonl`（追加写，一行一条）；同一 `key` 第二次请求**不发起任何 HTTP**（通过 mock 后端请求计数验证 = 1）；重启 App 后缓存仍命中；命中率 = `命中次数/(命中+新译)` 显示在底栏；`maxCacheEntries` 默认 100000，超限时按最久未用淘汰并在日志记录淘汰条数 |
| P0-11 | 直通后端（离线） | P0 | `backend=passthrough` 时 `translated === text`、`status=passthrough`、不产生任何网络请求；设为默认后端；此模式下整条链路（启动/采集/回绘）仍可跑通 |
| P0-12 | HTTP 翻译后端 + 设置 | P0 | 支持两种形状：`openai`（`POST {endpoint}/v1/chat/completions`，Bearer）与 `deepl`（`POST {endpoint}/v2/translate`，`DeepL-Auth-Key`）；设置页可填 `endpoint`/`apiKey`/`model`/`targetLang`/`timeout`；保存后立即生效（无需重启）；对 200/401/429/500/超时/非 JSON 六种响应都必须有明确错误码；`settings.json` 与 `credentials.json` 权限为 `0600`；日志与导出诊断中 `apiKey` 一律脱敏为 `sk-…后4位` |
| P0-13 | 批量与韧性 | P0 | 新译请求按 120ms 窗口合并；一次取 `maxBatch×maxConcurrent` 条，均分为 ≤`maxConcurrent` 块并发发送，块内再按 `batchCharBudget=4000` 字切子块顺序发送（积压时跳过合并窗口）；单批上限 `maxBatch=60`（1–200）、并发上限 4（1–8）；429/5xx/网络错误重试 3 次（指数退避 0.5s/1s/2s）；连续 5 次失败进入熔断，30 秒后半开重试；**熔断期间不产生译文**：零网络请求、**不消费队列、不生成"原文当译文"的 passthrough 条目**，新句不产生译文、游戏显示原文，实时流条目标记为失败并提示"约 N 秒后自动重试"，队列保留、冷却结束后自动继续（全文链路的条目保持未译/失败，可重试）；**熔断期间不得提供"立即重试"入口**（重试必立即失败），须显示"约 N 秒后自动重试"的倒计时，半开后自动恢复并清除提示；单请求超时 = `max(timeoutSec×1000, 15000+条数×250)`（默认 `timeoutSec=15`）；**熔断期断言**：`ErrorInfo.code = circuit_open` 且 **`retryable === false`**，批次结果 **`items` 为空**（不得回填"译文 = 原文"），熔断期后端请求数为 0，会话头出现"约 N 秒后自动重试"倒计时文案，**不出现**"立即重试"入口；冷却后队列中的条目**继续翻译**（不得在熔断期被消费掉），半开后提示自动清除。该断言用于防止后续把 `circuit_open` 顺手改回 `retryable = true` |
| P0-14 | 翻译开关 | P0 | 工具栏开关切换后立即下发给 Agent（`config.enabled`）；关闭时文本流继续采集（状态列显示 `已暂停`）但游戏画面显示原文；重新打开后此前已缓存的句子立即可用 |
| P0-15 | 字号缩放 | P0 | 滑杆 80%–130%（步长 5%）+ `⌘+`/`⌘-` 快捷；下发 `config.fontScale`；Agent 对 `drawTextEx` 的字号做乘法（`this.contents.fontSize`）并在窗口 `refresh` 时生效；缩放后不出现文本绘制异常（Agent `errors` 计数为 0）；数值持久化 |
| P0-16 | 停止与清理 | P0 | "停止"结束游戏进程（先 SIGTERM，3s 后 SIGKILL），关闭 WebSocket，释放端口；App 退出（含 `⌘Q`）时执行同样清理；验证方式：`ps -ax \| grep -c nwjs` 前后一致 |
| P0-17 | 无网络降级 | P0 | 断网状态下：App 不崩溃、不出现未捕获弹窗；新句进入 `直通` 状态并保留在缓存（`backend=passthrough` 不写缓存，标记 `unsaved`）；恢复网络后新句正常；`--selftest` 在断网下仍全绿 |
| P0-18 | `--selftest` 自检 | P0 | `MochiBox --selftest` 在**无游戏、无网络、无图形会话**（SSH 下）可运行，输出 TAP 风格 `ok N - <name>` / `not ok N - <name>: <detail>`，末行 `# pass X fail Y`，全绿退出码 0，任一失败退出码 1；总用例 ≥20 条且覆盖 §3.2 五组；支持 `--filter <pattern>` 与 `--verbose`；执行过程不初始化 `NSApplication`、不弹出任何窗口、不写用户库文件（使用临时目录） |
| P0-19 | 会话日志与诊断 | P0 | 每次会话写 `logs/session-<yyyyMMdd-HHmmss>.log`；日志滚动保留 5 个 × 上限 2MB；"导出诊断"产出单个 `.txt`（含环境信息、`library.json`、脱敏后的 `settings.json`、最近一次 selftest 输出、当前会话日志尾部 200 行）；导出文件中不得出现明文 key 或完整游戏路径外的用户隐私内容 |
| P0-20 | 设置持久化 | P0 | 所有设置项写入 `settings.json` 原子写（临时文件 + rename）；字段缺失或类型非法时回落默认值并记一条日志，不崩溃；`schemaVersion` 便于后续迁移 |

### 3.2 `--selftest` 五组覆盖清单（P0-18 的验证依据）

| 组 | 用例（≥） | 断言要点 |
|---|---|---|
| A 引擎识别 | 12 | 运行时在临时目录伪造 9 类引擎的特征文件各 1 例 + 冲突 1 例 + 空目录 1 例 + `.app/Contents/Resources/app.nw` 1 例；断言 `engine/supportLevel/reason` 完全匹配 |
| B 缓存 | 4 | key 稳定性（NFKC/空白归一）；写后读；重启（重新构造 store）后命中；同句第二次不调用后端（用计数桩） |
| C HTTP 桥 | 5 | 用 `NWListener` 在 `127.0.0.1:0` 起本地 mock 服务，分别响应 OpenAI 形状（200）、DeepL 形状（200）、401、429、500、非 JSON。**成功样本**：断言**无 `ErrorInfo`**、状态 `translated`、**必须写入缓存**；**失败样本**：断言 4 个 code（`auth_failed` / `rate_limited` / `bad_response`×2，即 500 与非 JSON 同归一类）与 `retryable`（401→`false`、429→`true`、500→`true`、非 JSON→`false`）。**⚠ `200` 属成功路径，若断言它"必须返回错误码"即为假阳性**；**⚠ 不要凑"六个 code"**——失败响应只有 4 个 code，500 与非 JSON 的差异进 `detail`。该 mock 服务同时是 AC2.2c 的确定性基线后端（RTT ≤50ms），两条用例复用同一实现 |
| D Agent 脚本 | 5 | 用 `JavaScriptCore` 的 `JSContext` 加载 `agent_mvmz.js`，注入 `window/SceneManager/Window_Base/Bitmap` 桩；断言：语法可求值、`__mochibox.version===1`、`drawTextEx` 触发 emit、注入译文后被替换、`uninstall()` 恢复原函数 |
| E 协议编解码 | 4 | `TextEvent`/`TranslateRequest`/`TranslateResult`/Agent 信封 的 encode→decode 往返相等；未知字段被忽略；`v` 版本不符时报 `unsupported_protocol` |

### 3.3 P1 需求（本轮只写需求，不实现）

| ID | 需求 | 说明 / 验收方向 |
|---|---|---|
| P1-01 | Ren'Py 适配器 | 投放可一键删除的 `game/mochibox_bridge.rpy`，通过 `config.say_menu_text_filter` 与回连 localhost socket 通信；验收：卸载后 `game/` 目录哈希与安装前一致 |
| P1-02 | 翻译记忆库导入导出 | 导出 CSV（`key,orig,trans,srcLang,tgtLang,backend,ts`）；导入时按 key 覆盖或跳过可选；验收：导出→清空缓存→导入，命中率恢复 |
| P1-03 | 字体替换 | 允许用户指定本地 `.ttf/.otf` 并通过 `@font-face` 注入页面，解决译文溢出；验收：切换字体后画面生效且刷新后仍生效 |
| P1-04 | attach 到运行中的游戏 | 用户手填端口直接连；验收：已运行游戏可 attach 且不重启 |
| P1-05 | apiKey 迁移到 Keychain | 用 Security framework 存储，`credentials.json` 仅留引用 |
| P1-06 | 文本流导出 | 导出当前会话为 `.csv` / `.txt`（供 U3 使用，不含真实游戏资源） |
| P1-07 | 自适应字号 | 译文长度超框时按宽度自动降一档字号（80% 下限） |
| P1-08 | 逐句重译 / 批量重译 | 选中行右键"重新翻译（忽略缓存）" |
| P1-09 | 新手引导 | 首启的三步引导（加游戏 → 选后端 → 启动） |
| P1-10 | 静态预翻译（**原 P0 项，已下调至此；不进 V0.1，仅作下一轮输入**） | 启动前扫描游戏脚本数据文件批量预译并灌入缓存，以减少游戏内实时等待。<br>**抽取范围**：仅 MV/MZ 的**对话与界面文本字段** —— `101`（**说话人名字，仅 MZ 有；MV 的 `101` 无此字段**）、`401`（正文行）、`405`（滚动文本续行）、`102`（选项）、`320`（改名）、`324`（改昵称）、`325`（改简介/Profile）以及 `System.terms`（界面术语）；**不碰** `note` 注释、插件参数、事件脚本（`355`/`655` 等）、以及**一切资源文件名**（如 `101` 的 `faceName`）。<br>**空值要求**：MZ 的 `101.parameters[4]`（说话人）在 MV 或未指定说话人时为空 → **必须 `guard` 跳过并记一次 `detail`**，不得崩溃、不得把空串送去翻译、不得回填。<br>**⚠ 指令码待核（P1 开工前置）**：上表号码为撰写时的记忆核对结果，**实现前必须对着 `rpg_objects.js` 的 `Game_Interpreter` 常量逐个复核**，不得直接照抄；**复核结果与本表不符时以源码为准**。已知易错处：`402`（When 分支）的分支名在 `parameters[0]`（**不是 `[1]`**）；`320`/`324`/`325` 的 `parameters[0]` 是 `actorId`、文本在 `parameters[1]`；`405` 的文本在 `parameters[0]`；`101` 的元素个数 **MV 与 MZ 不同**（MV 4 个、MZ 5 个），按 `parameters[4]` 取值在 MV 上必为空。<br>**合规**：只读本机游戏目录、不外传整文件、只传文本片段（同 §7.4）；因涉及"读取游戏数据文件"的合规复核，不进 P0。<br>**时序（实现契约）**：预译结果先写本地 `cache.jsonl`，这一步可在点"启动"之前或与启动**并行**完成；但**页内 Map 的灌入只能在 attach 成功后经 `inbox()` 批量下发**，物理上不可能在启动前完成。**预翻译是后台任务，不得阻塞启动按钮与 attach**；其超时或失败**只降级为运行时翻译**，不得让会话进入错误态。<br>**缓存纯度（可观测结果）**：`cache.jsonl` 中**不得存在**按"应跳过"判据（同 `P0-09`：纯数字/纯符号/纯空白，以及资源文件名等非自然语言标识）应被判为跳过的条目。*附注（非验收条件）*：实现上宜复用运行时同一套跳过判据，避免出现第二份定义导致两入口漂移。<br>**验收方向**：预译后同一场景在冷启动下首句直接 `命中`；抽取结果与"仅运行时采集"可对照出未覆盖字段；断网或预译失败时启动耗时不变、首句正常走运行时翻译；**缓存纯度断言三条并列**——(a) 构造 `"3"` / `"！？"` / `"Actor1.png"` 样本跑预译后，`cache.jsonl` 中不出现对应条目；(b) 同时 `newTranslations` 计数不变（只验 (a) 会让"送后端翻完再丢弃"的实现通过，照样产生计费）；(c) **来源校验**：缓存中不得存在"其 `text` 按同一跳过判据应被判为跳过"的条目（遍历条目取其 `text` 跑同一个 `skipReason`，非 nil 即脏；**不得用 `translatedRaw == raw` 判定**——恒等翻译合法，见 P0-09 的禁止条款） |

### 3.4 V0.6 追加验收（AC-9 修改器 / AC-10 全文翻译）

> 判定条件摘自 `docs/architecture-v0.6-cheat-and-fulltext.md` §8；设计与取证脚本见该文。
> 当前状态：**未验证**（手工项见 `docs/manual-acceptance.md`）。

| 编号 | 判定条件 |
|---|---|
| AC-9.1 | 连接后 `cheat.snapshot` 返回 `scene` / `mapId` / `gold` / `party`，值来自引擎而非伪造 |
| AC-9.2 | `setGold` 后快照金币变化，且游戏内菜单显示一致 |
| AC-9.3 | 变量 / 开关 / 物品 / 角色各至少一条写入路径可用；越界 id 返回 `cheat_out_of_range` 且游戏不崩 |
| AC-9.4 | `noclip` / `encounter` / `speed` 生效可观测（穿墙位移、遇敌计数、帧率） |
| AC-10.1 | 扫描在 30 s 内完成或可取消；UI 不卡（主线程 60 fps） |
| AC-10.2 | 全文翻译完成后，重启游戏自动加载译文（无网络） |
| AC-10.3 | 导出 `ManualTransFile.json` 可被重新导入，译文一致 |
| AC-10.4 | 导入 MTool 格式人工译文后，未译数下降 |
| AC-10.5 | 扫描 / 翻译 / 下发全链路不修改游戏目录（除非点"导出到游戏目录"）；未导出时游戏目录文件哈希与操作前一致 |

取证方式（脚本名 / 截图）见 `docs/architecture-v0.6-cheat-and-fulltext.md` §8 的"取证"列。

### 3.5 P2 需求（只列不做）

| ID | 需求 | 备注 |
|---|---|---|
| P2-01 | RGSS XP/VX/VXAce | 路线 A：`mkxp-z` 自编译 macOS 版 + Ruby 层 hook；路线 B：Wine/CrossOver 跑原版并复用 Windows DLL（成本最高） |
| P2-02 | WOLF RPG Editor | 仅 Windows，依赖 Wine 后端 |
| P2-03 | 吉里吉里（KAG3/krkrz） | 仅 Windows，依赖 Wine 后端 |
| P2-04 | SiglusEngine | COM 替换，仅 Windows |
| P2-05 | Unity / Godot | Mono/IL2CPP 与 GDScript 注入，需 entitlement 评估 |
| P2-06 | Wine 后端（Winlator 式） | macOS 上无对应成熟方案，暂不承诺 |
| P2-07 | 修改器类功能 | **V0.6 起提升为 P0（仅 MV/MZ 运行期数值修改）**；仍不做存档编辑与内购解锁 |

---

## 4. UI 设计稿（文本线框）

主窗口单窗口三区：**左 = 游戏库**，**中 = 翻译面板**，**设置以 sheet（右侧滑出/居中弹层）呈现**。整体沿用 macOS 外观，等宽字体用于文本流。

### 4.1 主窗口

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  MochiBox            日本語 → 简体中文   ▾        后端: passthrough   ● 就绪  │  ← 顶部工具栏
├─────────────────────────┬─────────────────────────────────────────────────────┤
│ 游戏库            [+]   │  ┌─ 会话 ─────────────────────────────────────────┐ │
│ ┌─────────────────────┐ │  │ サンプルRPG              RPG Maker MZ  [可启动]│ │
│ │▸サンプルRPG        ●│ │  │ 状态: ● 已连接   CDP 127.0.0.1:39231           │ │
│ │  RPG Maker MZ       │ │  │ 页面: file:///…/www/index.html                 │ │
│ │  上次: 2 分钟前      │ │  │ [ 启动 ] [ 停止 ] [ 重新连接 ] [ 清空文本流 ]   │ │
│ ├─────────────────────┤ │  │ 译文 [开 ▣]   字号 [—●———] 100%   缓存 128 条  │ │
│ │ 夜の図書館          │ │  └────────────────────────────────────────────────┘ │
│ │  Ren'Py  [P1 未实现] │ │  ┌─ 文本流 ───────────────────────────────────────┐ │
│ ├─────────────────────┤ │  │ 时间    原文              译文          状态   │ │
│ │ 未知游戏            │ │  │─────────┼─────────────────┼──────────────┼──────│ │
│ │  unknown  [?]        │ │  │ 12:01:03 こんにちは      你好          命中   │ │
│ ├─────────────────────┤ │  │ 12:01:05 勇者よ、目を覚 勇者啊，醒来吧  新译   │ │
│ │ + 添加游戏…          │ │  │ 12:01:09 \C[2]魔物が来た \C[2]魔物来了 命中   │ │
│ └─────────────────────┘ │  │ 12:01:12 350             —            跳过   │ │
│ [ 扫描目录… ]            │  │ 12:01:20 ???             后端不可用    错误   │ │
│ 共 4 个 · 1 可启动       │  └────────────────────────────────────────────────┘ │
│                         │  ┌─ 详情（跟随选中行） ───────────────────────────┐ │
│                         │  │ 原文: \C[2]魔物が来た                          │ │
│                         │  │ 分段: [code:\C[2]] [text:魔物が来た]           │ │
│                         │  │ key : 3f9a…d21c    出现: 3 次   延迟: 12ms     │ │
│                         │  │ 来源: Window_Message   后端: passthrough       │ │
│                         │  │ [ 复制原文 ] [ 复制译文 ] [ 重新翻译 ]         │ │
│                         │  └────────────────────────────────────────────────┘ │
├─────────────────────────┴─────────────────────────────────────────────────────┤
│ 缓存 128 条 · 命中率 76% · 本会话 42 句            [ 导出诊断 ]  [ 设置 ]     │  ← 状态栏
└───────────────────────────────────────────────────────────────────────────────┘
```

**交互说明**

| 元素 | 行为 |
|---|---|
| 游戏库列表 | 单选；选中项即右侧会话的目标；`●` 绿点 = 会话已连接，灰 = 未连接，`!` 黄 = 目录缺失 |
| `[+]` / `+ 添加游戏…` / 拖入 | 三个等价入口，均走 `NSOpenPanel` 或放量到 `processGameDirectory`；重复路径聚焦已有条目 |
| `[ 扫描目录… ]` | 选父目录，递归发现 ≥2 层内的游戏根（命中引擎特征的目录即视为一个根），结果以多选确认后入库 |
| `[ 启动 ]` | 仅 `supportLevel=可启动` 时可用；点击后按钮变 `[ 停止 ]`，会话头出现状态机文本，状态栏出现端口号 |
| `[ 重新连接 ]` | 仅 `attached` 前可用；重新轮询 `--remote-debugging-port` 端点，不重启进程；超过 25s 显示"重试中 (1/3)" |
| `[ 清空文本流 ]` | 只清视图，清缓存需去设置页（避免误删付费结果） |
| 文本流行 | 单击选中并更新详情区；双击复制译文；右键菜单：复制原文/复制译文/重新翻译/隐藏此类（按 `surface` 过滤，P1） |
| 文本流状态色 | `命中` 灰、`新译` 蓝、`直通` 橙、`跳过` 弱化灰、`错误` 红、`已暂停` 灰 |
| 译文开关 | 只影响回绘，不停采集；关闭时状态列由 `命中` 变为 `已暂停`（保留原状态于 tooltip） |
| 字号滑杆 | 80–130%，步长 5；拖动时 50ms 节流下发，松手下发一次最终值并持久化 |
| 状态栏 | 缓存条数/命中率/本会话句数实时刷新（≥1s 一次，不做逐事件重排）；命中率分母不含 `跳过` |

**异常态**

| 场景 | 展示 |
|---|---|
| 未选游戏 | 中区显示空态："从左侧选择一个游戏，或拖入游戏文件夹"，`启动` 禁用 |
| `supportLevel=不支持` | 中区显示原因卡片（如"Unity：macOS 无合法注入面，见 P2-05"），`启动` 禁用但保留"仅采集（不可用）"灰按钮说明 |
| attach 超时 | 会话头红条：`attach_failed — 25s 内未发现 CDP 端点`，可展开"最近响应"与"启动命令行" |
| 后端熔断 | 顶部条：`后端熔断中（约 N 秒后自动重试）`，保留"去设置"，**不提供"立即重试"**；熔断期游戏显示原文，冷却结束自动恢复 |

### 4.2 设置（sheet，480×640，左侧分组列表 + 右侧表单）

```
┌─ 设置 ────────────────────────────────────────────────────┐
│ ┌──────────┬────────────────────────────────────────────┐ │
│ │ 翻译后端 │  后端类型  ( ) 直通（离线）                │ │
│ │ 语言     │            (•) OpenAI 兼容                 │ │
│ │ 会话     │            ( ) DeepL 兼容                  │ │
│ │ 缓存     │                                            │ │
│ │ 合规     │  Endpoint  [ https://api.xxx.com        ]  │ │
│ │ 关于     │  API Key   [ ••••••••••••••  显示 ]        │ │
│ │          │  Model     [ gpt-4o-mini                ]  │ │
│ │          │  语言      日本語 → 简体中文   ( P0 固定 )  │
│ │          │  超时(s)   [ 15 ]   批量窗口(ms) [ 120 ]   │ │
│ │          │  最大并发  [ 4  ]                          │ │
│ │          │  [ 测试连接 ]  结果: ✅ 200 OK 412ms        │ │
│ │          ├────────────────────────────────────────────┤ │
│ │          │ ⚠ 文本会发送到你填写的服务；不发送游戏文件。│ │
│ └──────────┴────────────────────────────────────────────┘ │
│                                  [ 取消 ]  [ 保存 ]        │
└────────────────────────────────────────────────────────────┘
```

**分组内容**

| 分组 | 字段 | 校验/交互 |
|---|---|---|
| 翻译后端 | `backendType`、`endpoint`、`apiKey`；模型与吞吐调优项（`model`、`maxBatch`、`maxConcurrent`、`batchWindowMs`、`timeoutSec`、`batchCharBudget`、`maxOutputTokens`、`reasoningOffMode`）收在「高级设置」折叠组 | endpoint 必须 http(s)；`测试连接` 发一条固定探针句（"こんにちは"）并显示状态码+耗时；key 输入框默认掩码，可"显示"；「禁用推理」默认 `auto`（仅对 host 含 `deepseek` 的端点注入关闭字段），取值见 §5.8 |
| 语言 | `srcLang`、`tgtLang` | **P0 单向固定：`ja → zh-Hans`**（简体中文），不提供自由组合；两个值仍以 BCP-47 字符串存，为后续扩展留位。切换语言会**换缓存分片**（key 含语言），UI 明确提示"切换语言不会复用旧译文的缓存"。**验收断言**：界面上无法把语言改成 `ja → zh-Hans` 以外的组合（无下拉、无输入框），且 `settings.json` 两字段恒为 `"ja"` / `"zh-Hans"` |
| 会话 | `attachTimeoutSec`（默认 25）、`debugPortRange`、`maxTextRows`（默认 5000）、`fontScaleStep`、日志级别 | 端口范围非法时红字提示并阻止保存 |
| 字体 | `gameFontFamily`（空 = 自动） | 只列本机**同时覆盖中文与假名**的族；切换后下发 Agent 并重绘，刷新后仍生效；族不存在时由 Agent 回退链兜底 |
| 缓存 | 条数、文件大小、命中率、"查看路径"、"清空缓存"（二次确认，提示会重新计费）、`maxCacheEntries`、`cacheRetranslateOnBackendChange`（默认关） | 清空时先停写、再截断文件、再重建索引 |
| 合规 | 三个开关（仅记录偏好）：`allowSendTextToBackend`（关时后端强制 passthrough）、`showComplianceHintAgain`、`telemetryEnabled`（**默认关，且本轮不实现任何上报**） | 关闭 `allowSendTextToBackend` 会立刻把后端降级并提示 |
| 关于 | 版本、构建号、`--selftest` 入口按钮（在 App 内跑一次并展示结果）、开源许可 | "运行自检"复用 P0-18 的实现，结果只读展示 |

---

## 5. 数据契约

> 所有 JSON 字段为 **camelCase**，时间戳为 Unix 毫秒（`Double`），Hash 为 SHA-256 小写 hex。新增字段必须可选（消费者忽略未知字段），破坏性变更须升 `v`。

### 5.1 归一化与缓存键（唯一权威定义）

```
splitSegments(raw, engineFamily) -> [Segment]
  engineFamily == "mvmz" 时的转义码（整体作为一个 code 段，不做多字符判断）：
    \X[..]  \N[..]  \V[..]  \P[..]  \PX[..]  \PY[..]  \FS[..]  \C[..]
    \{  \}  \|  \!  \.  \$  \>  \<  \^  \\  \G
normalizeForKey(s) -> String
  1) precomposedStringWithCompatibilityMapping   // NFKC
  2) 空白折叠：**只用显式白名单** U+0009 / U+000A / U+000D / U+0020 / U+3000 → 各折叠为单个 U+0020
  3) trim（仅去首尾 U+0020）
key = lowerHex(SHA256(engineFamily + "|" + srcLang + "|" + tgtLang + "|" + normalizeForKey(join(segments.text, U+001F))))
  其中 join 使用 U+001F 作为分隔符，避免 "AB"+"C" 与 "A"+"BC" 撞 key
translateText = join(segments.text, U+001F)   // 送后端时保留 U+001F，要求逐段翻译
```

**归一与 join 的顺序（必须写死，不得各写各的）**

`key` 的归一对象是 **`join` 之后的整串**，即 `normalizeForKey(join(text))`，**不是** `join(map(normalizeForKey, text))`（逐段归一后再连接）。两者结果不同：

- 逐段归一：`["甲 ", "乙"]` → 段内 trim → `"甲\x1F乙"`；
- 整串归一：`"甲 \x1F乙"` → **`U+001F` 前后各有一个 U+0020** → `"甲 \x1F乙"` 的折叠结果与前者不同。

即**段内首尾空白的处理完全不同**，两种写法会得到不同的键空间。**以整串归一为准。**

**归一的三个不变量（三条必须同时成立，少一条就有一个面是空的；每条必须自带"一进一出"例子，无例子视为未定义）**

1. **显式折叠空白**：只折叠白名单 **U+0009 / U+000A / U+000D / U+0020 / U+3000**（含全角空格），各折叠为单个 U+0020；首尾只 trim U+0020。
   例：`"甲\t乙"` 与 `"甲  乙"` → **同 key**（都折叠为 `甲 U+0020 乙`）；`"３５０"` → NFKC → `"350"`。
   **禁止 `.whitespaces` / `.whitespacesAndNewlines` / 正则 `\s`**，理由三条：
   - ① **覆盖范围随平台/引擎/选项漂移**（Foundation `.whitespaces`、ICU `\p{Z}`、正则 `\s` 三者范围不同；U+3000、NBSP、行/段分隔符是否计入不一致）→ **同一句在不同环境算出不同键**，不报错、难查；
   - ② **被"顺手升级"的风险**：有人为清理控制字符把 `.whitespaces` 换成 `.controlCharacters`，**那时才真会吃掉 `U+001F`**——后果最重，且代码里看起来只是"换了个更严格的集合"；
   - ③ **契约可断言性**：显式白名单把"哪 5 个码位参与折叠"变成**契约的一部分**，可写成断言；用平台集合等于**把契约绑在实现上**，实现一换契约就静默变了。
2. **不得丢弃任何非空白字符**：`raw` 中的控制码在 `splitSegments` 阶段已进入 `code` 段，归一的对象只含 `text` 段拼接结果；**除空白折叠与首尾 trim 外，任何字符都不得被删除或改写**。
   例：`"\C[2]350"` → 分段为 `[code:\C[2]] [text:350]`；归一作用于 `350`，`\C[2]` **不进入哈希输入**，回填时仍在原位。
   失败实例：若把字符集换成含 C0 控制字符的集合（如 `.controlCharacters`），`甲␟乙` 会变成 `甲乙`（分隔符被吃掉、两段合并）——代码里看起来只是"换个更严格的字符集"，不会报错。
3. **分隔符不被丢弃、不被移动、段不被合并或重排**——拆成两条可测断言（**不得写成"位置/下标不变"**，理由见下）：
   - **3a 个数**：归一前后 `count(U+001F)` 相等，且 **`count == text 段数 − 1`**；
   - **3b 段内容**：以 `U+001F` 切分后，**逐段剥除上述 5 个白名单码位**，所得字符串**序列**与归一前完全一致。
   例：`text = ["甲  ", "乙"]` → join `甲␟乙`（`␟` 下标 3）→ 归一 `甲 ␟乙`（`␟` **下标 2**）。
   - 3a：`count == 1 == 2 − 1` ✅；3b：切分剥白得 `["甲","乙"]`，与归一前一致 ✅。
   - **下标位移是合法的**：折叠空白必然改变后续字符下标，所以**不得断言"位置/下标不变"**——那会在正确实现上失败。
   - 反例（应被抓住）：`甲␟乙` → `甲乙`（分隔符被吃）→ 3a 红；`甲␟乙` → `甲␟␟乙`（插入分隔符 / 空段）→ 3a/3b 均红；`甲␟乙` → `乙␟甲`（重排）→ 3b 红。

> **依据是规范，不是实测结论**：按 Unicode 类别，`U+001F` 属 **Cc**；Foundation `.whitespaces` = **Zs + U+0009**，`.whitespacesAndNewlines` 在此之上加 LF/CR；**两者都不含 Cc**。`.controlCharacters` 才是 Cc 集合。
> 故禁令的真实理由是上面的 ①覆盖漂移 与 ②被替换风险 与 ③可断言性，**不是**"`whitespaces` 本身会吃掉 `U+001F`"。这条按规范恒成立，不随系统版本变化；任何实测若与此不符，先怀疑实现而非规范。

**跳过判定的作用对象（易错，P0-09 的判定基准）**：`SkipRules` 的两条正则作用于**剥码后的自然语言段**（`segments` 中 `kind == "text"` 的拼接，即 `text`），**不是 `raw`**。

- `\C[2]350` → 剥码后为 `350` → **判为跳过**（不请求后端、不写缓存）；
- 但文本流"原文"列仍按 **P0-08 原样显示 `\C[2]350`**，不得改成渲染态——玩家要靠控制码判断问题是否出在脚本/绘制层。

反例（不得跳过）：`\C[2]10秒後` 剥码后为 `10秒後`，含数字但非纯数字 → **必须翻译且保留 `\C[2]` 原位**。

**归一化在这里的作用（需求口径，非实现顺序）**：跳过判定的输入必须是**等价归一后**的文本。可观测要求是"**纯数字的判定结果不得依赖字符宽度与首尾空白**"——`350`、`３５０`（全角）、`350 `（尾空格）三者必须得到同一个判定（跳过）。若三者判定不一致，即为缺陷。

`Segment`：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `kind` | `"text" \| "code"` | ✔ | `code` = 转义码，原样回填 |
| `value` | `String` | ✔ | 原文片段 |

### 5.2 文本事件 `TextEvent`（Host 侧模型 / 文本流一行）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | `String` | ✔ | UUID v4，行标识 |
| `ts` | `Double` | ✔ | 首次观测时间（ms） |
| `lastSeenTs` | `Double` | ✔ | 最近一次观测时间 |
| `sessionId` | `String` | ✔ | 会话 UUID |
| `gameId` | `String` | ✔ | 对应 `library.json` 的 `id` |
| `engine` | `String` | ✔ | `"mvmz"`（本轮唯一值，MV 与 MZ 共用 key 空间） |
| `surface` | `String` | ✔ | 绘制来源类名，如 `Window_Message` / `Bitmap` |
| `sceneClass` | `String?` | ✖ | `SceneManager._scene.constructor.name` |
| `raw` | `String` | ✔ | 原始字符串，含转义码，用于展示与"复制原文" |
| `segments` | `[Segment]` | ✔ | 分段结果 |
| `text` | `String` | ✔ | 自然语言段拼接（U+001F 连接），用于翻译 |
| `key` | `String` | ✔ | 见 5.1 |
| `status` | `String` | ✔ | `hit` `miss` `pending` `translated` `passthrough` `skipped` `error` `paused` |
| `translated` | `String?` | ✖ | 译后的 **raw 形态**（段位拼接后，转义码已回填） |
| `translatedSegments` | `[Segment]?` | ✖ | 段数校验通过时的段结果 |
| `backend` | `String?` | ✖ | `passthrough` `openai` `deepl` |
| `latencyMs` | `Int?` | ✖ | 后端往返耗时 |
| `cached` | `Bool` | ✔ | 是否来自本地缓存 |
| `occurrences` | `Int` | ✔ | 同 **`surface` + `raw`** 的**行序号**（= 该身份第几次"**距上次绘制 > 800ms 后再次出现**"，等价于截至本行的累计次数：首行恒 1，第 n 行为 n）。**持续可见期间的重复重绘不计入**（仍为 1）；**不回填已渲染行**。**基于当前保留行计算**：被 5000 行上限淘汰后，同一身份的序号**可重新从 1 开始**；**不得引入跨淘汰 / 跨会话的持久计数器**（用户无法核对的数字即假数字；且 `identity → count` 是无界增长，正是环形缓冲要防的东西）。**不是同 key**：`350` 与 `\C[2]350` 是**两行、同一个 key** |
| `skipReason` | `String?` | ✖ | `numeric` `punctuation` `whitespace` `tooShort` `disabled` |
| `order` | `Int?` | ✖ | 会话内单调递增的观测序号（从 1 开始），用于 P1-06 导出时还原阅读顺序。**P0 只写不读** |
| `surfaceKind` | `String?` | ✖ | `dialogue` / `menu` / `system`，由 `surface` 派生的语义分类，解决"`surface` 是类名、导出需要分类"的错位。**P0 只写不读** |
| `error` | `ErrorInfo?` | ✖ | 见 5.5 |

### 5.3 Agent ↔ Host 消息

**信封**

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `v` | `Int` | ✔ | 协议版本，本轮 = `1` |
| `type` | `String` | ✔ | 见下 |
| `payload` | `Object` | ✔ | 按 type 定义 |
| `sessionToken` | `String` | ✔ | 会话随机 token（16 hex），Host 拒绝不匹配的消息 |

Agent→Host（经 `Runtime.bindingCalled` 的 `__mochiboxEmit(jsonString)`）：

| `type` | payload | 说明 |
|---|---|---|
| `hello` | `{agentVersion:1, ua:String, href:String, engineGuess:"mvmz", hooks:[String]}` | 注入完成，握手 |
| `text` | `TextEvent` 子集：`{ts, surface, sceneClass, raw, segments, text, key}` | 采集到文本（不含 status/translated，由 Host 补全） |
| `error` | `{code:String, message:String, stack:String?}` | Agent 内部异常（被 try/catch 捕获，不冒泡到游戏） |
| `stats` | `{emitted:Int, replaced:Int, skipped:Int, errors:Int, queueLen:Int}` | 每 2s 上报一次 |
| `pong` | `{t:Double}` | 心跳应答 |

Host→Agent（经 `Runtime.evaluate` 调用 `window.__mochibox.inbox(<json>)`）：

| `type` | payload | 说明 |
|---|---|---|
| `config` | `{enabled:Bool, fontScale:Double, srcLang:String, tgtLang:String, maxMapSize:Int}` | 全量配置，幂等 |
| `setTranslation` | `{key:String, translatedRaw:String, segments:[Segment]}` | 单条译文下发 |
| `setTranslations` | `{items:[{key, translatedRaw, segments}]}` | 批量下发（上限 200/次） |
| `drop` | `{keys:[String]}` | 从页面 Map 移除（缓存被清空时） |
| `clear` | `{}` | 清空页面 Map 并全量重绘请求 |
| `ping` | `{t:Double}` | 心跳 |

页面侧对象（`window.__mochibox`）的必需成员，`--selftest` D 组据此断言：

```
window.__mochibox = {
  version: 1, installed: Bool, state: {enabled, fontScale, mapSize, errors},
  emit(type, payload), inbox(jsonString),
  install(), uninstall(), _orig: {drawText, drawTextEx, bitmapDrawText}
}
```

### 5.4 翻译请求 / 响应

**TranslateRequest**（Host 内部，提交给 `TranslationBackend` 协议）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `items` | `[{key, text, segments}]` | ✔ | `text` 为 U+001F 连接的原文；`segments` 仅用于上下文/校验 |
| `srcLang` | `String` | ✔ | BCP-47 字符串。**P0 固定 `ja`**；`zh-Hans` `zh-Hant` `en` 为保留值，本轮不可选 |
| `tgtLang` | `String` | ✔ | BCP-47 字符串。**P0 固定 `zh-Hans`**；字段名与 `srcLang` 成对，**不使用 `fromLang`/`toLang` 等别名**（与 `docs/architecture.md` v2 一致） |
| `backend` | `String` | ✔ | `passthrough` `openai` `deepl` |
| `timeoutMs` | `Int` | ✔ | 默认 15000 |
| `requestId` | `String` | ✔ | UUID，用于日志串联 |

**TranslateResult**

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `requestId` | `String` | ✔ | 回填 |
| `items` | `[{key, translatedText, translatedSegments, cached, latencyMs}]` | ✔ | `translatedText` 亦为 U+001F 连接 |
| `backend` | `String` | ✔ | 实际使用的后端。**熔断期为 `passthrough` 但只作降级标记**：`items` 为空、`error.code = circuit_open`，**不携带任何"译文"**（不得回填原文） |
| `error` | `ErrorInfo?` | ✖ | 整批失败时填，`items` 为空 |

**段数一致性校验**：`translatedText.split(U+001F).count != segments.text.count` → 先**剔除译文中的空段**再比一次（原文的 `text` 段永远非空，空段只可能是模型多写的分隔符：尾随 `…呜啊\u{1F}` 或连续 `A\u{1F}\u{1F}B`）；仍不一致 → **该条单独重试一次**（段数漂移是模型输出抖动，实测一次全文翻译 5530 条中 0.36% 中招，单条重发能救回大多数）；重试后仍不一致 → 整条丢弃，状态 `error`，`error.code = "segment_mismatch"`，**不写缓存**。

**单条失败不得升级为块级失败**：一条译文段数不符只影响该条（`PipelineBatchResult.itemErrors`），不得把同一块其余条目或整波 `backendStatus` 标成降级/熔断——块级 `error` 只承载“请求本身失败”（网络 / 解析 / 超时 / 熔断）。这条重试是管线内部的一次性补偿，**不改变** `segment_mismatch.retryable = false` 的对外语义。

**成功路径的阳性断言（不得只验"拒绝"）**：段数**一致**时必须按原段位重组——以 `\C[1]甲\C[0]乙`（2 个 text 段 + 2 个 code 段）为例，后端返回 2 段译文后，重组结果的 `code` 段**数量与位置**必须与原文完全一致，状态为 `translated` 且**该条必须写入缓存**。
> 只验"不匹配时丢弃"不足以证明成功路径可用——**一个"永远丢弃"的实现能通过全部阴性断言**。

**一条译文必须扇出到所有共享同一 `cacheKey` 的行**：同一 `cacheKey` 可能对应**多行**（如 `こんにちは` 与 `\C[2]こんにちは`，剥码后 `text` 相同 → `join(text)` 相同）。后端返回一条译文时，**必须填充所有共享该 `cacheKey` 的行**（含 `pending` 与已渲染行）；**只填首行会让另一行永久停在 `pending`**，违反 AC2.2b（5s 内必须收敛）——且现场表现像"后端慢"，极难定位。重译、缓存清理同样按 `cacheKey` 扇出。
> 反例（应判缺陷）：`applyTranslation(cacheKey)` 只更新首个匹配行 → 另一行 5s 后仍 `pending`。
> **⚠ 扇出不能用 `350` / `\C[2]350` 验**：两者都 `skipped`，**根本不产生请求**，永远不会有译文可扇出——用它们测扇出会得到"恒真"的假结论。

**失败也必须扇出（含 401 / 超时 / 熔断）**：错误结果同样要落到**所有**共享该 `cacheKey` 的行（状态转 `error`；熔断期同样是 `error` + "约 N 秒后自动重试"提示，**不得**转成 `passthrough` 把原文当译文）。配置为 `passthrough` 后端时仍按条返回、逐行标 `status = passthrough`（P0-11），这是功能而非降级。**两种失败形态都必须覆盖——后果不同，不得合并成一句话描述**：
> - **(a) 部分失败**（`items` 有内容，其中若干条自带 `error`）：只扇出成功项的实现会让**失败项对应的行**停在 `pending` 直到超时；症状是"每句少一半"。
> - **(b) 整体失败**（401 / 429 / 超时 / 熔断）：`items` **为空**，整批原因由批次级 `error` 承载。只在遍历 `items` 时才落状态的实现**一行都不会更新**——后果不是"另一行 `pending`"，而是**所有在飞行中的行全部停在 `pending`**。症状是"整个文本流冻住"，与"后端慢"几乎无法区分。
> **断言（两条都要，缺一即漏 (b)）**：(i) 401 场景下，共享同一 `cacheKey` 的两行**都**不得停留 `pending`；(ii) 401 场景下，**同一批次内 `cacheKey` 不同**的多个在飞行行也**都**不得停留 `pending`。**必须补 (ii)**：(i) 的批次只有 1 个 `item`，"只在有 `items` 时才落状态"的实现在 (i) 下仍可能通过，(ii) 才锁得住 (b)。
> **"在飞行中"的判定口径**：已发出请求、且尚未收到该 `cacheKey` 的落地结果（成功或失败）即算在飞行中；整批失败时，这个集合就是必须被落状态的行集合。**此处不规定实现用什么结构**，只要求这批行最终不留在 `pending`。

该校验是 `segment_mismatch` 的**唯一产出点**，同时覆盖"后端返回段数与请求不符"与"本地拼接段数不符"两种成因；二者**不拆成两个 code**，细分成因写入 `error.detail`（`"backend_segment_count"` / `"local_segment_count"`）。

**后端适配形状**

- `passthrough`：`translatedText = text`，`cached = false`，不写缓存，不发网络请求。
- `openai`：`POST {endpoint}/v1/chat/completions`，`Authorization: Bearer <key>`，`messages=[{system: 指令},{user: JSON 数组 of text}]`；指令要求"逐条翻译，条目用 U+001F 分隔的段落必须保持段数与顺序，仅输出 JSON 数组，不解释"。响应取 `choices[0].message.content`，剥离 ``` 围栏后按 JSON 解析。**DeepSeek 官方模型默认开启思考**，需在「高级设置 → 禁用推理」关闭（`auto` 对 DeepSeek 端点自动生效，字段见 §5.8）：不关闭时思维链会先吃光 `max_tokens`，表现为 `content` 为空、`finish_reason=length`（用户侧是"翻译全失败"）；关闭后 `temperature=0` 才真正生效。注入的关闭字段若被后端以 **400/422** 拒绝，须**去掉该字段重发同一请求一次**，仍失败才按 `bad_response` 上报。
- `deepl`：`POST {endpoint}/v2/translate`，头 `Authorization: DeepL-Auth-Key <key>`，体 `{text:[...], source_lang, target_lang, preserve_formatting:true}`；响应取 `translations[].text`，按 U+001F 段数校验。

### 5.5 `ErrorInfo`

| 字段 | 类型 | 说明 |
|---|---|---|
| `code` | `String` | 见下方枚举（**共 12 个**），**唯一对外判定字段**，UI 文案与 QA 断言只依赖它 |
| `message` | `String` | 面向用户的一句话（中/英按系统语言） |
| `retryable` | `Bool` | **语义 = "立即重试是否有意义"，不是"这个 code 是不是错误"**。`true`：429 / 5xx / `network` / `timeout`。`false`：`circuit_open`、`auth_failed`、`quota_exceeded`、`segment_mismatch`、`unsupported_protocol`、`launcher_no_executable`、`attach_failed`、`agent_no_hello`、以及 4xx+非 JSON 的 `bad_response`。<br>**⚠ 禁止简化成"按 code 查表"**——同一个 `bad_response`，`httpStatus=500`（瞬时 → `true`）与 `httpStatus=400` 且响应体非 JSON（语义错误 → `false`）答案不同。<br>**⚠ `circuit_open` 必须是 `false`**：熔断期立即重试**必然立即失败**，置 `true` 会让 UI 显示一个"点了就失败"的按钮。但 `false` **不等于"不可恢复"**——UI 须按 P0-13 显示"约 N 秒后自动重试"，**不得**呈现为终局失败 |
| `httpStatus` | `Int?` | 有 HTTP 时填 |
| `rawSnippet` | `String?` | 响应体 / stderr 前 512 字符（**脱敏**：不得含 key） |
| `detail` | `String?` | 机器可读的细分成因，**不参与 UI 与 QA 断言**，仅供日志与诊断导出 |

`code` 枚举（12 个，权威清单）：

`auth_failed` `rate_limited` `quota_exceeded` `network` `timeout` `bad_response` `segment_mismatch` `unsupported_protocol` `circuit_open` `launcher_no_executable` `attach_failed` `agent_no_hello`

**命名治理规则（防止同类歧义复发）**

1. 一个 `code` 只承载**一个语义**；同一语义不得存在两个 code。
2. 新增的细分成因一律进 `detail`，**不得**新增近似 code。
3. QA 只断言 `code`；工程师可在日志/诊断中依赖 `detail`。
4. 已删除 `cdp_timeout`（并入 `attach_failed`，`detail="discovery_timeout"`）与 `segment_count_mismatch`（并入 `segment_mismatch` 的 `detail`）。

**`attach_failed` 的边界**：覆盖"CDP 端点发现超时 / 端口耗尽 / WebSocket 握手失败 / 进程启动后立即非 0 退出"，`detail` 分别取 `discovery_timeout` / `port_exhausted` / `ws_handshake_failed` / `process_exited_early`。

**`agent_no_hello` 保持独立**：此时端口与 WebSocket 均已通，失败点在 Agent 自身（注入未生效 / 脚本异常），处置动作是**重新注入**而非重启进程，与 `attach_failed` 的用户可见文案和重试策略都不同。

### 5.6 缓存记录（`cache.jsonl`，一行一条）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `key` | `String` | ✔ | 见 5.1 |
| `text` | `String` | ✔ | 原文（U+001F 连接），便于调试与导出 |
| `translatedText` | `String` | ✔ | 译文（U+001F 连接） |
| `srcLang` | `String` | ✔ | |
| `tgtLang` | `String` | ✔ | |
| `backend` | `String` | ✔ | 产生该译文的实际后端 |
| `seq` | `Int` | ✔ | 单调递增，用于 compaction 取最新 |
| `ts` | `Double` | ✔ | 写入时间 |
| `hitCount` | `Int` | ✔ | 命中次数（compaction 时合并求和） |

规则：**只追加**；读取时按 `key` 取 `seq` 最大者；命中时内存计数不入盘，每 200 次命中或退出时追加一条同 `key` 的 `hitCount` 增量覆盖行；行数 > 2× 不同 key 数时触发 compaction（重写文件，保留每 key 最新一条）。

### 5.7 `library.json`

```json
{
  "schemaVersion": 1,
  "games": [{
    "id": "5e2a…", "name": "サンプルRPG", "path": "/path/to/Games/SampleRPG",
    "engine": "mz", "engineConfidence": "high",
    "engineEvidence": ["js/rmmz_core.js", "package.json"],
    "supportLevel": "p0", "reason": null,
    "addedAt": 1763600000000, "lastLaunchedAt": 1763600100000, "launchCount": 3,
    "missing": false
  }]
}
```

### 5.8 `settings.json`

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `schemaVersion` | `Int` | 2 | 迁移用；读入 `< 2` 的存量文件时把 `maxBatch`/`maxConcurrent` 迁到 60/4 |
| `backendType` | `String` | `passthrough` | `passthrough` `openai` `deepl` |
| `endpoint` | `String` | `""` | 不含尾部 `/` |
| `model` | `String` | `gpt-4o-mini` | 仅 openai 用 |
| `srcLang` / `tgtLang` | `String` | `ja` / `zh-Hans` | P0 单向固定，UI 不提供自由组合 |
| `timeoutSec` | `Int` | 15 | 1–120 |
| `batchWindowMs` | `Int` | 120 | 0–2000 |
| `maxBatch` | `Int` | 60 | 1–200 |
| `maxConcurrent` | `Int` | 4 | 1–8 |
| `batchCharBudget` | `Int` | 4000 | 500–20000；单请求输入字数上限（块内再按它切子块） |
| `maxOutputTokens` | `Int` | 0 | 0–32768；0 = 按输入字数自动估算 |
| `reasoningOffMode` | `String` | `auto` | 关闭模型推理（思考）要注入的请求体字段；取值见下表。**非法值回落 `auto`**（不让整份设置解码失败），一次只发一组字段 |
| `attachTimeoutSec` | `Int` | 25 | 5–120 |
| `debugPortRange` | `[Int]` | `[39200,39300]` | |
| `agentEnabled` | `Bool` | true | UI"译文开关" |
| `fontScale` | `Double` | 1.0 | 0.8–1.3 |
| `gameFontFamily` | `String` | `""` | 游戏内绘制字体族；空 = 自动（苹方系），Agent 再拼回退链兜底 |
| `maxTextRows` | `Int` | 5000 | |
| `maxCacheEntries` | `Int` | 100000 | |
| `cacheRetranslateOnBackendChange` | `Bool` | false | |
| `allowSendTextToBackend` | `Bool` | true | 关则强制 passthrough |
| `telemetryEnabled` | `Bool` | false | 本轮不实现上报，仅占位 |
| `logLevel` | `String` | `info` | `debug` `info` `warn` `error` |
| `complianceAckVersion` | `Int` | 0 | 需 = 当前 `kComplianceVersion` 才跳过提示 |
| `ui` | `Object` | `{"language":"zh-Hans"}` | **嵌套对象，不是拍平的 `uiLanguage` 键**；子字段见下表 |

`ui` 子对象：

| 子字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `ui.language` | `String` | `zh-Hans` | `zh-Hans` `en` |

**`ui` 的解码规则（P0-20 的字段回落以此为准）**：`ui` 整块缺失或类型非法 → **用默认块整体替换**，不做子字段逐项回落；`ui` 存在但某个子字段非法 → 仅该子字段回落默认值并记一条日志。

`reasoningOffMode` 取值（**一次只发一组**，同时发两套会被部分后端判 400）。取值与 `ReasoningOffMode.rawValue` **逐字一致**（camelCase，大小写敏感；写错会回落 `auto`，只在日志留一条告警）：

| 取值 | 请求体字段 |
|---|---|
| `auto`（默认） | endpoint host 含 `deepseek` → `{"thinking":{"type":"disabled"}}`；**其它 host 不发送**（未知字段会被第三方端点判 400） |
| `thinkingDisabled` | `{"thinking":{"type":"disabled"}}` |
| `reasoningEffortNone` | `{"reasoning_effort":"none"}`（`minimal` 不等于关闭，官方映射为 `low`） |
| `openRouterEffortNone` | `{"reasoning":{"effort":"none"}}` |
| `vllmEnableThinkingFalse` | `{"chat_template_kwargs":{"enable_thinking":false}}` |
| `siliconflowEnableThinkingFalse` | `{"enable_thinking":false}` |
| `never` | 不发送任何字段（确认后端不需要/不接受时手动选） |

`credentials.json`：`{"apiKey": "…", "deeplApiKey": "…"}`，权限 `0600`，**不得写入日志、不得进诊断导出**。

---

## 6. 决策记录（原"待确认问题"，**已全部结案；当前开放问题 = 0**）

> Q1–Q5 已由主理人裁定，无遗留待确认项。本节保留为审计记录，供后续轮次追溯"当初为什么这么定"。**未经主理人重新裁定，不得单方面推翻下列结论。**

| # | 原问题 | **结论（已生效）** | 落点 |
|---|---|---|---|
| D-1（原 Q1） | 首发语言对范围 | **`ja → zh-Hans` 单向**（简体中文），P0 不提供自由组合；两个值仍以 BCP-47 字符串存储（`srcLang`/`tgtLang`，不用 `fromLang`/`toLang` 别名），便于后续扩展 | §4.2 语言组、§5.4、§5.8 |
| D-2（原 Q2） | 默认翻译后端 | **`passthrough`**（只采集 + 缓存，零联网）。因此 **AC2.2c 的基线必须先切到 `--selftest` 的 mock 后端（RTT ≤50ms）再计时**，否则 `passthrough` 永远不产生 `新译` 状态 | §2.2 AC2.2c、§5.8 `backendType` |
| D-3（原 Q3） | 文本提取/导出是否进 P0 | **不进 P0，归 P1-06**；但 P0 的 `TextEvent` 必须**现在就带上** `surface`、`sceneClass`、`order`、`surfaceKind`（后两者 P0 只写不读），避免事后改协议 | §5.2、P1-06 |
| D-4（原 Q4） | 分发形态 | **源码 + `build.sh` → `MochiBox.app`，ad-hoc 签名**（`codesign -s - --force --deep`，已实测可用），**不公证**；README 写明 Gatekeeper 首次打开方式 | §A.3 |
| D-5（原 Q5） | 是否 App Sandbox | **不做沙盒**。采用"非沙盒 + 直接 `Process` spawn 游戏可执行文件 + 只监听 `127.0.0.1`"。**不进 Mac App Store 规划**；README 明写"未签名 / 未公证 / 非沙盒" | §A.2、§7.5、§7.6 |

**D-5 的后续约束（重要）**：若有朝一日要上架或启用沙盒，§A.2 的启动流程与 P0-05/P0-16 必须重写，属架构返工 —— 届时需要新的裁定，不能沿用本记录。

---

## 7. 约束与合规

### 7.1 净室实现（clean-room）

- **不随包分发**：任何游戏资源、RTP、字体（含 `mtool_renpy_font.ttf`、`mtool_PGMMV_font.ttf`）、MTool 的 `*.dll/*.exe/*.bin/*.js`（含 `loader.bin.*`、`data/*` 加密模块）、V8 字节码一律不得进入仓库与产物。
- **净室边界**：本次实现只依据 (a) 公开的 Chromium DevTools Protocol 文档、(b) RPG Maker MV/MZ 公开的 `rtscript`/插件 API 文档、(c) 本机自行抓取的运行时行为。**不得**反编译 MTool 的加密模块或字节码以复用其实现；`docs/re-findings.md` 只用于确定"产品形态与能力边界"，不得作为代码来源。
- 引擎识别规则只检查**文件名与目录结构**（公开的引擎发行包形态），不解析任何加密容器。

### 7.2 不修改游戏文件

- MV/MZ：仅通过启动参数与 CDP 在内存中注入，**磁盘零写入**。验收：启动→采集→停止后，对游戏目录做文件哈希前后比对，必须一致。
  唯一例外是用户显式点击"导出译文到游戏目录"：该动作有确认弹窗并展示目标路径，写出 `ManualTransFile.json`
  与备份；未点击时哈希必须一致（V0.6 AC-10.5）。
- 全文翻译默认持久化在 `<App Support>/MochiBox/fulltext/<gameHash>.json`，不碰游戏目录。
- Ren'Py（P1 才实现）：唯一例外，且必须提供"一键移除"，移除后 `game/` 目录哈希与安装前一致。

### 7.3 能力边界

- 不实现任何绕过授权/DRM/反调试/校验的功能；不提供内购解锁、不读改存档文件。
- **V0.6 起**提供单机 MV/MZ 的**运行期数值修改**（金币/变量/开关/物品/角色/队伍/传送/变速等），
  只经引擎公开的 `$game*` 对象模型写入内存，**不写存档、不改游戏文件、不改内存地址**；
  不做联机/服务端校验的绕过。能力清单与验收见 `docs/architecture-v0.6-cheat-and-fulltext.md` §3/§8。
- 不承诺"汉化补丁"产物；翻译结果只存在于运行时绘制层。
- 用户必须自行拥有游戏：首启模态合规提示（P0-01），每次新会话在日志首行写入 `userAttestsOwnership=true`。

### 7.4 隐私与网络

- 发送到后端的**只有**翻译文本片段（`text`）：不含文件路径、不含游戏名、不含用户标识。
- 首次配置非 `passthrough` 后端时，必须有一次显式确认："该后端的运营方将看到你游戏中的文本"。
- `telemetryEnabled` 默认关，本轮不实现任何上报代码。
- `apiKey` 只存本地 `0600` 文件；日志/导出/错误提示一律脱敏。
- 无网络时：按 `network` 退避重试，连续失败进入熔断；熔断期不消费队列、不产出译文（游戏显示原文），冷却后自动继续，不崩溃、不无限重试（P0-13/P0-17）。

### 7.5 本地端口安全

`--remote-debugging-port` 会给任何能访问该端口者**完全代码执行能力**。因此：

- 只绑定 `127.0.0.1`（不放宽到 `0.0.0.0`）；
- 端口在会话内随机且短线；
- 每条 Agent 消息带 `sessionToken`，Host 丢弃不匹配者；
- "停止"与 App 退出必须释放端口（P0-16）；
- App 不得在未经用户点击"启动"的情况下启动游戏或开端口。

### 7.6 工程约束

- 仅 `swiftc` + Command Line Tools；无 SPM / CocoaPods / Electron / Node / Python 运行时依赖（`JavaScriptCore`、`Network`、`Security` 为系统 framework，允许）。
- **非沙盒（D-5 结论）**：App 不做 App Sandbox，才能直接 `Process` spawn 用户机器上任意路径的游戏可执行文件。代价是**不进 Mac App Store**，README 须明写"未签名 / 未公证 / 非沙盒"。
- 不要求 Xcode 工程；不要求用户关闭 SIP、不给 App 申请调试类 entitlement。
- 所有网络与磁盘 IO 不阻塞主线程；UI 状态变更在主 actor。
- Swift 6 严格并发下编译无 error（warning 允许）。

---

## 附录 A. 技术规范（供架构师直接使用）

### A.1 引擎识别规则（固定优先级，先命中先返回）

扫描根：若输入是 `.app`，根 = `Contents/Resources/app.nw`（不存在则 `.app` 本身）；否则根 = 目录本身。扫描深度 ≤2。

| 序 | 引擎（`engine`） | 呈现名 | 特征（满足任一） | supportLevel |
|---|---|---|---|---|
| 1 | `renpy` | Ren'Py | `game/` 下存在 `*.rpy`/`*.rpyc`；或 `renpy/` 目录；或 `lib/py3-mac-universal/` | p1 |
| 2 | `kirikiri` | 吉里吉里 | 根下任意 `*.xp3`；或 `tvpwin32.exe`/`krkr.exe`；或 `data/startup.tjs` | p2 |
| 3 | `mz` | RPG Maker MZ | `js/rmmz_core.js` | p0 |
| 4 | `mv` | RPG Maker MV | `www/js/rpg_core.js` | p0 |
| 5 | `easyrpg` | RPG Maker 2000/2003 | `RPG_RT.ldb` **且** `RPG_RT.lmt` | p2 |
| 6 | `rgss3` | RPG Maker VX Ace | `Game.ini` 内 `Library=RGSS3*`；或 `Data/*.rvdata2`；或 `Game.rgss3a` | p2 |
| 7 | `rgss2` | RPG Maker VX | `Library=RGSS2*`；或 `Data/*.rvdata`；或 `Game.rgss2a` | p2 |
| 8 | `rgss1` | RPG Maker XP | `Library=RGSS1*`；或 `Data/*.rxdata`；或 `Game.rgssad` | p2 |
| 9 | `tyrano` | TyranoBuilder | `data/system/Config.tjs` **且**（`tyrano/tyrano.js` 或 `index.html` 含 `tyrano`） | p0 |
| 10 | `wolf` | WOLF RPG Editor | `Data.wolf`；或 `BasicData/*.dat` | p2 |
| 11 | `unity` | Unity | `*_Data/globalgamemanagers`；或 `Managed/Assembly-CSharp.dll` | none |
| 12 | `godot` | Godot | `project.godot`；或根下 `*.pck`（**排除 `Scene.pck`** —— 精确名优先于通配，见下表后原则） | none |
| 13 | `siglus` | SiglusEngine | `Scene.pck`；或 `Gameexe.ini` | none |
| 14 | `unknown` | 未知 | 上述皆不命中 | unknown |

**⚠ 表内包含关系原则（优先于"按序号先后"）**：同表特征之间存在**包含 / 重叠**关系时（如 `Scene.pck` ⊂ `*.pck`），**精确文件名必须先于通配模式命中**，且该优先关系**不得靠行序表达**——行序只决定"彼此无关的特征"谁先命中。理由：靠行序表达包含关系时，任何一次调序都会静默改变判定结果，而判定结果又会被缓存与验收用例继承。

`reason` 枚举（仅 `unknown` 或冲突时填写）：`no_signature_matched` / `signature_conflict`（多引擎命中且分差为 0，取序号小者并在 `reason` 记录） / `permission_denied` / `empty_directory` / `not_a_directory`。

`engineEvidence: [String]` 记录命中的相对路径（最多 5 条），供 UI"为什么这样判断"使用。`engineConfidence: high|medium|low`（命中强特征=high；仅弱特征如 `index.html`=low）。

`supportLevel` 映射：`p0`→UI"可启动"；`p1`→"需 P1 适配器（未实现）"；`p2`→"暂不支持（需 Wine 后端）"；`none`→"不支持"；`unknown`→"未知"。

### A.2 启动与 attach 流程（MV/MZ）

1. 从库取 `path`，解析可执行：
   - 若 `path/*.app` 存在 → `<app>/Contents/MacOS/<CFBundleExecutable>`；
   - 若 `path/nwjs.app/Contents/MacOS/nwjs` 存在 → 用它；
   - 若 `path/Contents/MacOS/nwjs`（输入本身是 `.app`）→ 用它；
   - 否则报 `launcher_no_executable`（附已尝试路径列表）。
2. 选端口：在 `debugPortRange` 内随机取，`bind(127.0.0.1:port)` 成功即用，失败重试 20 次。
3. `Process` 启动，`arguments = ["--remote-debugging-port=<port>"]`，`currentDirectoryURL = gameRoot`，stdout/stderr 重定向到会话日志。
4. 轮询 `GET http://127.0.0.1:<port>/json/list`：250ms 间隔，25s 超时。
5. 选取 target：`type == "page"` 且 `url` 含 `index.html` 优先；否则第一个 `page`。
6. WebSocket 连接 `webSocketDebuggerUrl` → `Page.enable` → `Runtime.enable` → `Runtime.addBinding {name:"__mochiboxEmit"}` → `Page.addScriptToEvaluateOnNewDocument {source: agentJS}` → `Runtime.evaluate {expression: agentJS}` → 等待 Agent 发 `hello`。
7. 进入 `attached`，下发 `config`（enabled/fontScale/langs）。

失败分支与对外错误码（`code` 唯一，细分进 `detail`，见 §5.5）：

| 分支 | `code` | `detail` | 处置 |
|---|---|---|---|
| 可执行文件解析不到 | `launcher_no_executable` | `no_executable_found` | 终止，展示已尝试路径列表 |
| 端口 20 次 bind 均失败 | `attach_failed` | `port_exhausted` | 终止，提示放宽 `debugPortRange` |
| 进程启动后立即非 0 退出 | `attach_failed` | `process_exited_early` | 终止，`rawSnippet` 放 stderr 前 512 字符 |
| CDP 端点 25s 未出现 | `attach_failed` | `discovery_timeout` | 终止，`rawSnippet` 放最近一次 `/json/list` 响应体 |
| WebSocket 握手失败 | `attach_failed` | `ws_handshake_failed` | 若 `/json/version` 主版本 ≥111 则加 `--remote-allow-origins` 重试一次 |
| Agent 5s 未发 `hello` | `agent_no_hello` | `injection_no_handshake` | **不重启进程**，重新注入一次；二次失败才终止 |

### A.3 构建与分发（CLT only）

`Scripts/build.sh`：
1. `swiftc -O -parse-as-library Sources/**/*.swift -o .build/MochiBox -framework SwiftUI -framework AppKit -framework Network -framework JavaScriptCore -framework Security`；
2. 组装 `MochiBox.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}`，拷贝 `Resources/agent_mvmz.js`；
3. `codesign -s - --force --deep MochiBox.app`（**ad-hoc 签名，已实测可用**；按 D-4 结论：**不公证**）；
4. `--universal` 时额外 `x86_64` 编译 + `lipo`，失败则仅 arm64 且打印提示（不阻塞 P0）。

**分发口径（D-4 / D-5 结论）**：产物为**未公证、非沙盒**的 ad-hoc 签名 `.app`。README 必须写明：① 首次打开被 Gatekeeper 拦截时的放行方式（右键 → 打开，或 `xattr -d com.apple.quarantine`）；② 本 App 未签名/未公证/非沙盒；③ 不进 Mac App Store（无规划）。

依赖清单：仅系统 framework（SwiftUI/AppKit/Foundation/Network/JavaScriptCore/Security/os）。**禁用** SPM/CocoaPods/Electron/Node/Python。

### A.4 目录布局（运行时数据）

```
~/Library/Application Support/MochiBox/
├── library.json          # 游戏库
├── settings.json         # 设置（0600）
├── credentials.json      # apiKey（0600）
├── cache/
│   └── cache.jsonl       # 追加写缓存，按语言对分片：cache.ja-zh-Hans.jsonl
├── logs/
│   └── session-20261020-120103.log
└── export/diagnostics-<ts>.txt
```

---

## 附录 B. 风险提示（供架构师排期参考，不含时间估算）

| 风险 | 影响 | 缓解 |
|---|---|---|
| 部分 MV/MZ 游戏打包为已签名 `.app`，注入参数被 `open` 吞掉 | 启动器对这类包无法 attach | 直接执行 `Contents/MacOS/nwjs` 而非 `open`；失败时给出手动"已运行游戏 + 用户手填端口"提示（P1-04） |
| `drawTextEx` 逐字符绘制，改写后断行位置改变 | 译文溢出对话框 | P0 提供手动字号缩放（P0-15）；自动适配放 P1-07 |
| 同一句在 `Window_Message` 与 `Window_ChoiceList` 重复出现 | 缓存重复、UI 噪声 | key 不含 `surface`（共享译文），UI 同帧按 `surface` 去重 |
| 译文含 U+001F 或后端擅自合并段落 | 段数校验失败 → 整条丢弃 | 已在 5.4 定义校验与错误码；prompt 明确要求 |
| 后端费用不可控 | 用户投诉 | 缓存 + 批量 + 并发上限 + 命中率可见（P0-10/P0-13） |
