# RPG Maker 全版本运行时实测记录

**日期**：2026-11-02
**机器**：Apple Silicon（arm64；GL Renderer 报 `Apple A18 Pro`），macOS 27.2（26B123）
**测试口径**：合成 fixture + 第三方开源工程的真实数据表 + 本地占位素材（占位 PNG），
不含任何版权媒体素材。运行时二进制、Enterbrain 默认脚本、第三方脚本集**全部只在临时目录**，
不入库、不进 `.app`；`Fixtures/*-real/` 里的数据表逐目录带 `PROVENANCE.md` 与许可证全文。

## 汇总表

| 版本 | RGSS | 运行时 | 状态 | 证据强度 |
|---|---|---|---|---|
| 2000 / 2003 | — | EasyRPG Player 0.8.1（内置，33.9 MB universal） | 跑通：消息框与菜单渲染出中文 | A |
| XP | RGSS1 | mkxp-z（自建，`f02d586`） | 跑通：标题→New Game→Map001→事件中文→菜单→行走 Step 0→5 | A |
| VX | RGSS2 | mkxp-z 同一份 | 跑通：标题→地图→菜单→行走；脚本 = 官方默认集 + VX_SP2 + 3 行字体垫片 | B+ |
| VX Ace | RGSS3 | mkxp-z 同一份 | 跑通：标题→New Game→地图→行走（坐标 3,5→7,5→7,7）；脚本 = 默认集 129 段，第三方脚本已剔除 | A |

**证据强度怎么算**（沿用 `acceptance-assertion-rules.md` 的分级思路）：

- **A**：引擎日志认出版本 + 画面 OCR 出**预期文本**（中文/数值），且观测手段与产物可复查。
- **B+**：同 A，但行走是像素位移证据、没有坐标读数；或脚本集不是纯默认，结论要限定范围。
- **B**：同 A，但关键一步（行走）只有画面变化，没有数值或文本读数。
- **C**：只有日志/窗口出现，没有画面内容证据（本次没有 C 级结论）。

## 每一版的详细记录

### RPG Maker 2000 / 2003

- **运行时**：内置 EasyRPG Player 0.8.1（`EasyRPG Player 0.8.1 (CI, 2025-04-07)`），
  33,990,032 B，Mach-O **universal**（x86_64 + arm64）。不涉及 RGSS。
- **启动方式**（产品代码 `GameLauncher` 的实际参数）：

  ```
  easyrpg-player --project-path <游戏根> --language zh_CN --save-path <隔离存档目录> --no-audio
  ```

  游戏根 = 含 `RPG_RT.ldb` 的那一层；工作目录同游戏根。
- **数据**：`Fixtures/rm2000`、`Fixtures/rm2003`（EasyRPG/TestGame 原始数据，GPL-3.0）。
- **证据**：译文由 PO 注入后，OCR 从截图像素认出
  「测试消息速度：」「速度 1」，菜单认出「技能 / 装备 / 存档」「阿列克斯」「金币」「铁剑」「布衣」。
  12 px 字形完整可读，不是豆腐块。修复前同机同位置 OCR 是英文（`Agility` / 英文物品描述），
  构成 A/B 对照：**中文是渲染出来的，不是日志推断**。
  （截图未入库，OCR 文字见上。）
- **过程中确认的一条运行时事实**：EasyRPG 0.8.1 的 PO 只认**非索引** `msgctxt`
  （scalar 字段的 `ctxt.index` 恒为 -1），`actors.1.name` 这类索引形态全部落空。
- **限制**：
  - 没有真实 GBK 汉化样本（上游不存在可分发的 `.ldb`），GBK 判据只有合成覆盖。
  - 只有静态 PO 路径：游戏内无实时文本通道，脚本生成的内容盖不住。

### RPG Maker XP（RGSS1）

- **运行时**：mkxp-z 自建。上游 commit `f02d586624dc53de373889cc16d9b1516da0a3a5`
  （2026-10-31，merge PR #390），meson + ninja 全源码构建（`forcefallback`），
  产物 **42,075,568 B（40.1 MiB）**，`minos 13.0`，`otool -L` 里 `/opt/homebrew` 计数 **0**。
- **版本识别原文**（日志首行）：

  ```
  RGSS version 1 (RPG Maker XP)
  ```

  同段还有 `GL Renderer : ANGLE (Apple, ANGLE Metal Renderer: Apple A18 Pro, ...)`，
  说明走的是 ANGLE→Metal，不是软件光栅。
- **链路**：标题画面 → New Game → Map001 → 地图 autorun 事件弹出两行中文 → 关闭 →
  菜单 → 方向键行走，`Step Count` 从 **0** 变 **5**。
  窗口出现只是起点；这里有画面、有输入、有事件解释器、有中文渲染。
- **改数据生效**：用 `Sources/Adapters/Marshal` 把 `Actors.rxdata` 里 1 号角色改名，
  文件从 **10,981 B → 10,993 B**（+12 B：18 B 中文替换 6 B 的 `Aluxes`，原地重写而非整体重排）。
  重启后菜单显示「桃箱改名成功 · Fighter · Lv1 · HP 741/741」，其余三人仍是 `Basil / Gloria / ...`。
- **已定位的 SIGSEGV 根因**：mkxp-z 上游 issue **#396**（open，检索于 2026-11-02）——
  静态 meson 构建链的是自带 `libiconv`，没有 Apple 专有的 `utf-8-mac`；
  `iconv_open()` 返回 `(iconv_t)-1` 但代码没检查，`toNFC()` 把该值交给 `iconv()`，
  崩在 `libiconv → CacheEnumData → PHYSFS_enumerate → FileSystem::createPathCache`，
  也就是日志停在 `Loading path cache...` 之后。验证用的二进制靠构建配置（`iconv_system=enabled`）
  避开了它；**随包分发的 mkxp-z 另有代码级防护**（`iconv_open` 失败即跳过归一化 +
  `PHYSFS_stat` 失败分支），见 `vendor/mkxpz/mochibox-macos-fixes.patch`。
- **限制**：脚本集取自 OpenXP 测试工程（MIT 覆盖不到 Enterbrain 默认脚本），
  本次**未逐节审计**；素材全是占位图；未验证任何商业 XP 游戏。

### RPG Maker VX（RGSS2）

- **运行时**：同一份 mkxp-z。日志首行：

  ```
  RGSS version 2 (RPG Maker VX)
  ```

- **脚本集**：`rgssad-rs`（nathaniel-daniel，MIT **或** Apache-2.0 双许可）测试工程
  `RPGMakerVXTestGame/Data/Scripts.rvdata` 的 LFS 实体（108,286 B），
  解出 **98 段**，末尾追加 **1 段** `MKXP Font Shim`，合计 **99 段 / 108,487 B**。
  98 段 = RPG Maker VX **默认脚本布局**（`▼ Modules` … `▼ Scenes` 的完整类清单）
  ＋ Enterbrain 官方的 `▼ Patch / VX_SP2` ＋ `▼ Materials / ( Insert here )` ＋ `▼ Main Process / Main`。
- **是否被改过（审计结论）**：**没有改默认脚本**，只加了一段 3 行垫片。
  三条可复查的判据（本次用 `Sources/Adapters/Marshal` 写工具解包逐段核对）：
  1. 所有段里被**二次打开**的类只有 `Sprite_Base` / `Window_NameEdit` / `Window_NameInput`，
     且都发生在 `VX_SP2` 段 —— 正是 Enterbrain 官方补丁的改动范围，别处没有重开类。
  2. 全量扫描非 ASCII：中文只出现在 `MKXP Font Shim` 段（日文假名是 `Window_NameInput`
     的默认表、`VX_SP2` 的官方注释）。
  3. 段名与顺序、`Game_Map#passable?(x, y, flag = 0x01)`、`Game_Player#map_passable?`
     等关键函数与 VX 默认实现一致（`map_passable?` 就是两参数版本，没有塞方向参数）。
  追加的垫片全文（3 行，182 B）：

  ```ruby
  # MKXP 平台适配垫片（仅测试工程，非 Enterbrain 默认脚本）
  Font.default_name = ["Hiragino Sans GB", "HiraginoSansGB-W3", "Arial Unicode MS"]
  Font.default_size = 20
  ```

  它原本是要解决日志里的 `Primary font not found: UmePlus Gothic`（测试机没装 VX 的默认字体）；
  但 RGSS2 的 `Main` 同样是阻塞的，这段垫片大概率也从没执行过（VX 这一版未单独插桩验证），
  出字应该是 mkxp-z 回退的结果。
- **证据**：标题（`VX Test` / `VX TITLE` / `New Game` / `Continue` / `Shutdown`）
  → 地图 → 菜单（OCR 出 `Item Skill Equip Status Save Game End` 与角色名/HP/MP）
  → 行走。行走本次重新取证：先按右 8 次（相机跟随，画面稳定不动），再连续向左 10 次
  越过相机夹边界（相机夹在 0），角色精灵从屏幕 x≈256 逻辑像素移到 x≈32，
  两帧差分 **8,192 px**，静止对照帧 **0 px**。移动是真的，但没有坐标读数。
- **复现时的一个坑**：fixture 的 `Map001` 是 100×100 全铺 **2048 号图块**的合成图，
  而 VX 的真实 `@passages[2048] = 0x09` 恰好挡下方向位 `0x01`（默认的"向下通行"判定），
  所以**原样跑不动**——这是引擎行为正确，不是兼容性问题。上一轮是把方向标志临时改传
  `0x04` 绕过去的，那份改动没有留下可复查的产物；本次改成在**数据层**把
  `passages[2048]` 置 `0x00`，脚本零改动即可行走。
- **限制**：`Tilesets.rvdata` 是我们补的 572 B 占位（VX 的通行表在 `System.rvdata` 里，
  `Tilesets` 只存名字/标签，运行时不读）；"x 8→99" 这个数值没有留存读数，
  所以证据强度记 B+ 而不是 A。

### RPG Maker VX Ace（RGSS3）

- **运行时**：同一份 mkxp-z。日志首行：

  ```
  RGSS version 3 (RPG Maker VX Ace)
  ```

  同段有 `BUG: Bitmap drawText with outline and translucent text is broken`（占位字体导致，
  不影响流程）。
- **脚本集**：`caynine9/Jimicization-Project`（**CC0-1.0**）的 `PJSRH/Data/Scripts.rvdata2`
  （143,430 B），解出 **131 段**，追加垫片后 **132 段 / 143,630 B**。
  本次把这 132 段逐段解包（用 `Sources/Adapters/Marshal` 写的一次性工具），
  **剔除 3 段非 Enterbrain 来源的脚本**，重写成 **129 段 / 136,078 B / 19,927 行** 再跑：

  | 原段号 | 段名 | 行数 | 判定依据 |
  |---|---|---|---|
  | 121 | `Star Passability Bug Fix` | 30 | 注释头署名 Neon Black，带 rpgmakerweb 论坛原帖链接 |
  | 122 | `Event Jitter Fix` | 38 | 同上 |
  | 125 | `QuestSystem` | 979 | `Basic Quest System v1.3f`，作者 V.M of D.T |

  合计移除 **1,047 行**。重写后逐段比对：**129 段的段名、脚本 ID、解压后源码与原文件逐字节相同，
  顺序不变**（同一工具读两份文件后按位比较）。

  > 前一轮把 `▼ Bug Fixes` 两段记成"Enterbrain 官方自带"，这个说法站不住：两段正文都写着
  > `by Neon Black`、给了社区论坛原帖链接，社区文档也把它们当"要自己加的修复片段"。
  > 无论 VX Ace 的默认工程模板里是否预置这两段，它们都不是 Enterbrain 署名脚本，一并不算默认集。

- **是否被改过（审计结论）**：
  - 129 段 = 111 段默认内容（110 段默认脚本 + `▼ Materials / ( Insert here )` 模板占位）
    + 17 个分区标题/空段 + 1 段我们的垫片。
  - 剔除后**没有任何类被二次打开**：全量 103 个 `class` 定义，每个只出现一次；`module` 同样无重开。
    剔除前唯一的重开是两段 Neon Black 补丁对 `Game_Map` 的改写。
  - 中文仍只出现在垫片段。
- **垫片其实不生效**（本轮实测）：垫片段排在 `Main` 之后，而 `Main` 里的 `SceneManager.run`
  会阻塞到游戏退出，所以它从未执行 —— 插桩读到的 `Font.default_name` 仍是 `VL Gothic`，
  日志里的 `Primary font not found: VL Gothic` 也没消失，文字是 mkxp-z 走系统字体回退渲染的。
  垫片保留原位置（不改工程结构），但**不能再当成"字体修复"引用**。
- **证据**：
  - 标题：OCR 出 `DETUALANGAN / JIMI / SI RAJA HAREM`（工程标题数据）与
    `Permainan Baru / Lanjutkan / Keluar`（New Game / Continue / Shutdown，默认
    `Window_TitleCommand` + `Vocab` 渲染）→ 确认键进 New Game。
  - 地图：进入 `Map001` 后先播一段 8 页开场文本（OCR 出印尼语剧情
    `Banjarmachine adalah sebuah negeri yang tenteram…`），逐页确认到结束。
  - 行走：静止对照 **0 px / 1.5 s**（地图完全静止，没有环境动画）；按右 4 格后帧差
    **4,352 px**、变化区 `300×64`；按下 2 格后帧差 **4,808 px**、变化区 `50×192`。
    每格 32 逻辑像素 = 64 设备像素，变化区尺寸与"4 格横移 / 2 格纵移 + 精灵宽度"的位移带吻合；
    原地踏步只会在约一格的范围里变化，拉不出整条带。
  - **坐标读数**（另跑一次，脚本集临时插一段只写日志的探针，测完即删）：`(3,5)`
    → 右 ×4 → `(7,5)` → 下 ×2 → `(7,7)`。这是唯一一次改动脚本集的运行，只用于读数。
  - 剔除前后对照：同一位置的地图画面与剔除前**逐像素相同（0 px 差）**；标题画面只有光标行不同。
  - 启动日志除 `Primary font not found` 与渲染后端 BUG 提示外，**没有** `NameError` /
    `uninitialized constant` / `LoadError`。
- **限制**：
  - 脚本集来自 CC0 游戏工程，**不是官方安装副本**：本机没装 RPG Maker，做不了 byte-diff。
    "默认脚本集"是结构审计结论（段名/顺序、无类重开、无第三方残留、剔除后能跑通），
    不是哈希相等；也没有对 110 段逐行做语义比对。**而且不是"零改动"** —— 有 2 个默认
    方法被作者改过，见下节《更正》。
  - 地图没有可 OCR 的文本，"地图可见"靠像素统计 + 与剔除前逐像素相同来证；
    行走的坐标读数来自插桩运行，干净那一次只有像素位移证据。
  - 素材是作者的原创图（CC0），不是 RTP；音频全缺（`No soundfont specified, sound might be mute`）。

## 脚本来源审计（结论先写）

| 项目 | VX（`Scripts.rvdata`） | VX Ace（`Scripts.rvdata2`） |
|---|---|---|
| 来源 | rgssad-rs 测试工程 `RPGMakerVXTestGame`（Git LFS 实体） | `caynine9/Jimicization-Project`（作者自建工程 `PJSRH`） |
| 许可 | MIT 或 Apache-2.0（双许可，任选其一） | CC0-1.0 |
| 原始大小 | 108,286 B / 98 段 | 143,430 B / 131 段（加垫片后 143,630 B / 132 段） |
| 入库状态 | **不入库**，只在临时目录 | **不入库**，只在临时目录 |
| 我们的改动 | 追加 3 行 `MKXP Font Shim`（+201 B，尾段） | 追加 4 行 `MKXP Font Shim`（+200 B，尾段）；**另剔除 3 段 / 1,047 行第三方脚本** |
| 剔除后 | — | 136,078 B / 129 段 / 19,927 行 |
| 默认脚本是否被动过 | 没有。`VX_SP2` 是 Enterbrain 官方补丁段（`eb_sp1_`/`eb_sp2_` 前缀、日文官方注释） | **动过 2 个方法**：`Game_System#japanese?`、`Game_Interpreter#command_225`（见下节《更正》）；剔除的 3 段第三方脚本都在默认清单之外，剔除后无类重开 |
| 额外内容 | 无 | 无（`QuestSystem` 与两段 Neon Black 补丁已剔除） |
| 能不能说"默认脚本兼容" | **能**，限定为"VX 默认脚本集（含官方 VX_SP2 补丁）" | **能**，限定为"VX Ace 默认脚本集（110 段），剔除第三方后能跑通，其中 2 个方法带社区修 bug 改动" |
| 数据层真实样本（`Data/*`） | `Fixtures/rmvx-real/`：14 个 `.rvdata`（MIT 或 Apache-2.0），往返字节相同 | `Fixtures/rmvxace-real/`：27 个 `.rvdata2` + `Game.ini`/`Game.rvproj2`（CC0-1.0，470,061 B），往返字节相同、1463 条文本 |

**VX Ace 数据层不再是"无真实样本"**（2026-11-02 入库）：`Fixtures/rmvxace-real/` 是
`caynine9/Jimicization-Project` @ `70b397b` 的原样数据表，许可 CC0-1.0 覆盖整个仓库
（含 `Data`，无独立 NOTICE），证据见该目录 `PROVENANCE.md`。`19_marshal` 的
`M-L1-VXA-PARSE/RT/TEXT/ENC/STRUCT` 分别钉住：27 个文件逐个可解析、序列化回去字节完全相同、
1463 条文本（门槛 > 50）、编码全判 UTF-8、`@terms` 的 4 个容器能取到值。

为什么不下"逐字节等于 Enterbrain 官方文件"的结论：这台机器上没有装 RPG Maker，
拿不到官方安装目录里的那份 `Scripts.*` 做 byte-diff。上面的结论来自**结构审计**
（段名/顺序、类重开范围、非 ASCII 扫描），不是哈希对比 —— 这一点必须写明，别把
"没发现改动"说成"证明没改动"。

## 更正：VX Ace 默认脚本**不是**零改动

本文早先把 VX Ace 的结论写成"剔除 3 段第三方脚本后零改动跑通"。**这个说法不成立**：逐段
复核工程脚本集后发现，两个默认方法被工程作者改过，两处都是社区流传的修 bug / 兼容补丁。

| 段 | 方法 | 官方默认 | 工程里的样子 | 为什么要改 |
|---|---|---|---|---|
| `Game_System`（011） | `japanese?` | `$data_system.japanese` | 取值那行被注释掉，硬编码 `return false` | 关掉"日语模式"（社区叫 "Custom Font Junk Symbol Fix" / "Japanese Mode" 补丁）：非日文 Windows 上该开关会让字形处理走日文分支，出现 junk symbol |
| `Game_Interpreter`（040） | `command_225`（屏幕震动） | `start_shake` 的 `@params` 下标错位（speed 位置又传了一次 power），等待条件也跟着错 | `screen.start_shake(@params[0], @params[1], @params[2])` + `wait(@params[2]) if @params[3]` | 官方 1.02a 的已知 bug：震动参数取错导致等待时长异常。工程里是修复版 |

所以对外只能说：**"VX Ace 默认脚本集（110 段）剔除 3 段第三方脚本后能跑通，其中 2 个方法
带社区修 bug 改动"**。不能说"零改动"，也不能把这份脚本集当成官方默认脚本的等价物 ——
它和 VX 那一栏（只加了自己的 3 行 shim、默认脚本确实没动）不是一回事。

## 复现步骤（给下一个人）

1. **挂载根 = exe 所在目录**（最容易踩的坑）。mkxp-z 以"可执行文件所在目录"为游戏根，
   所以先把 `mkxp-z` 二进制**复制进**游戏目录，再在该目录里执行它。
   用绝对路径从别处启动会得到空挂载，表现为找不到 `Data/*`。
2. **`Game.ini` 的 `Library=` 决定 RGSS 版本**（同一个二进制切三代）：

   | `Library=` | 认成 |
   |---|---|
   | `RGSS104E.dll` | `RGSS version 1 (RPG Maker XP)` |
   | `RGSS200E.dll` / `RGSS202E.dll` | `RGSS version 2 (RPG Maker VX)` |
   | `RGSS300.dll` / `RGSS301.dll` | `RGSS version 3 (RPG Maker VX Ace)` |

   `Scripts=` 指向脚本归档（`Data\Scripts.rxdata` / `.rvdata` / `.rvdata2`），
   路径用反斜杠，和工程文件里一致。
3. **素材占位尺寸**（合成工程够用，缺了会在 `Cache` 里抛 `Errno::ENOENT`）：

   | 版本 | 文件 | 尺寸 |
   |---|---|---|
   | XP | `Graphics/Titles/001-Title01.png` | 640×480 |
   | VX | `Graphics/System/Title.png` | 544×416 |
   | VX Ace | `Graphics/Titles1/<名字>.png` | 544×416 |
   | 三代 | `Graphics/System/Window.png` | 192×192（3×3 皮肤，64 px 格） |
   | XP / VX | `Graphics/Characters/*.png` | 384×256（8 个角色，单角色 96×128 = 3 帧 × 4 方向） |
   | VX Ace | `Graphics/Characters/*.png` | 96×128（单个角色，3 帧 × 4 方向） |

   窗口客户区：XP 640×480，VX / VX Ace 544×416（窗口外框多 32 px 标题栏）。
4. **字体**：测试机没有 `UmePlus Gothic` / `VL Gothic` / `Arial`，实际出字靠 mkxp-z 的
   系统字体回退。**垫片放在 `Main` 之后不会执行**：`Main` 里的 `SceneManager.run` 一直阻塞到
   游戏退出（VX Ace 实测 `Font.default_name` 仍是 `VL Gothic`）。要让垫片生效，得插在
   `Main` **之前**；本轮为保持工程结构没挪。
5. **合成地图的通行性**：VX 的 `Map001` 若全铺同一种图块，先查
   `System.rvdata` 的 `@passages[tile_id]`（8192 项、int16）。方向位含义：
   `0x01` 下 / `0x02` 左 / `0x04` 右 / `0x08` 上，`0x10` = 不影响通行，`0x0f` = 四向全挡。
   不通行时先怀疑这里，不要先怀疑引擎。

## 已知缺口

**2026-11-02 已闭环**：VX Ace 的**数据层**不再是"无真实样本"——上面的
`Fixtures/rmvxace-real/` 就是 CC0-1.0 的真实工程数据（27 个 `Data/*.rvdata2`，
逐文件 sha256 与许可证据见 `PROVENANCE.md`）。**仍然缺的是默认脚本的字节级副本**
（下面第 1、2 条），不是数据层。

1. **没有官方默认脚本的字节级副本**：本机未安装 RPG Maker，无法做
   "解出来的段 == 安装目录里的段"的 byte-diff。VX 的"未改动"是结构审计结论；
   VX Ace 已经知道有 2 个默认方法被改过（见《更正》）。
2. **VX Ace 的"默认脚本集"是结构审计结论**：129 段来自 CC0 工程，剔除 3 段第三方脚本后
   能跑通，但 **2 个默认方法被改过**（见《更正：VX Ace 默认脚本不是零改动》）；
   没有官方副本做 byte-diff，也没有对 110 段逐行做语义比对。
3. **VX 行走没有数值读数**：本次用帧差分证明位移（8,192 px），旧记录里的 "x 8→99"
   没有留存读数，不要当证据引用。
4. **mkxp-z 已接入产品路径（2026-11-02）**：`LaunchBackend` 新增 `mkxpz`，
   `rgss1/2/3.launchBackend` 不再是 `nil`；`Scripts/fetch-mkxpz.sh` 取运行时、
   `Scripts/build.sh` Step 2.7 打进 `Contents/Resources/runtime/mkxp-z`。
   启动前由 `GameLauncher.validateMKXPZGameIni` 校验 `Game.ini` 的 `Library=` 与
   检测引擎一致（错配抛 `runtime_version_mismatch`，缺 `Game.ini` 抛 `game_ini_missing`）。
   **挂载根靠构建选项 `-Dworkdir_current=true`**（不是命令行参数）：launcher 把子进程
   cwd 设成游戏目录即可，不复制二进制到用户目录。构建记录与补丁见 `vendor/mkxpz/`。
5. **没有音频、没有 RTP**：三代都用占位图，`No soundfont specified` 是预期日志。
6. **未验证任何商业游戏**：四个 fixture 都是测试工程/合成工程，
   真实国产 XP/VX 游戏常依赖 Win32API 与外部 DLL，mkxp-z 跑不动。
