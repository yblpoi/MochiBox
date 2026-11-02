# RPG Maker 全版本运行时实测记录

**日期**：2026-11-02
**机器**：Apple Silicon（arm64；GL Renderer 报 `Apple A18 Pro`），macOS 27.2（26B123）
**测试口径**：合成 fixture + 本地素材（占位 PNG），不含任何版权文件。运行时二进制、
Enterbrain 默认脚本、第三方脚本集**全部只在临时目录**，不入库、不进 `.app`。

## 汇总表

| 版本 | RGSS | 运行时 | 状态 | 证据强度 |
|---|---|---|---|---|
| 2000 / 2003 | — | EasyRPG Player 0.8.1（内置，33.9 MB universal） | 跑通：消息框与菜单渲染出中文 | A |
| XP | RGSS1 | mkxp-z（自建，`f02d586`） | 跑通：标题→New Game→Map001→事件中文→菜单→行走 Step 0→5 | A |
| VX | RGSS2 | mkxp-z 同一份 | 跑通：标题→地图→菜单→行走；脚本 = 官方默认集 + VX_SP2 + 3 行字体垫片 | B+ |
| VX Ace | RGSS3 | mkxp-z 同一份 | 跑通：标题→地图→菜单；脚本 = 默认集 + **第三方 QuestSystem** + 字体垫片 | B |

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
  也就是日志停在 `Loading path cache...` 之后。当前这份二进制**没有**该问题
  （原因见上：构建配置不同，不是改代码绕的）。
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

  它解决的是日志里的 `Primary font not found: UmePlus Gothic` —— 测试机没有装 VX 的默认字体。
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
- **是否被改过（审计结论）**：**这不是"原版默认脚本"，是"默认脚本 + 一个第三方插件"**。
  - 130 段是 RGSS3 默认布局：`▼ Modules`（Vocab/Sound/Cache/DataManager/SceneManager/BattleManager）、
    `▼ Game Objects`、`▼ Sprites`、`▼ Windows`、`▼ Scenes`、
    **`▼ Bug Fixes`（Star Passability Bug Fix / Event Jitter Fix，Enterbrain 官方自带）**、
    `▼ Materials / ( Insert here )`、`▼ Main Process / Main`。
  - 第 125 段 `QuestSystem` 是第三方脚本：`Basic Quest System v1.3f`，作者 V.M of D.T，
    28,779 B / 979 行，重开了 `DataManager` / `Game_Party` / `Game_Player` / `Game_Event` /
    `Game_Interpreter` / `Window_MenuCommand` / `Scene_Base` / `Scene_Map` / `Scene_Menu`。
  - 默认段里被二次打开的类只有 `Game_Map`（被官方 `▼ Bug Fixes` 的两段改），
    符合"默认脚本 + 官方修复"的原样形态。
  - 中文仍只出现在垫片段。
- **证据**：标题（OCR 出作者工程的标题文字）→ 地图（真实地图数据，能出画面）→ 菜单
  （截图与 OCR）。行走只记录了"按键后画面变化"，**没有坐标读数**。
- **限制**：
  - 脚本集含第三方插件，不能拿来证明"Enterbrain 默认脚本逐字兼容"；证明的是
    "mkxp-z 能执行 RGSS3 脚本集（默认 130 段 + 第三方 979 行）"。
  - 素材是作者的原创图（CC0），不是 RTP；音频全缺（`No soundfont specified, sound might be mute`）。
  - 行走证据强度低于 XP。

## 脚本来源审计（结论先写）

| 项目 | VX（`Scripts.rvdata`） | VX Ace（`Scripts.rvdata2`） |
|---|---|---|
| 来源 | rgssad-rs 测试工程 `RPGMakerVXTestGame`（Git LFS 实体） | `caynine9/Jimicization-Project`（作者自建工程 `PJSRH`） |
| 许可 | MIT 或 Apache-2.0（双许可，任选其一） | CC0-1.0 |
| 原始大小 | 108,286 B / 98 段 | 143,430 B / 131 段 |
| 入库状态 | **不入库**，只在临时目录 | **不入库**，只在临时目录 |
| 我们的改动 | 追加 3 行 `MKXP Font Shim`（+201 B，尾段） | 同左（+200 B，尾段） |
| 默认脚本是否被动过 | 没有。`VX_SP2` 是 Enterbrain 官方补丁段（`eb_sp1_`/`eb_sp2_` 前缀、日文官方注释） | 没有。默认段只被官方 `▼ Bug Fixes` 重开 |
| 额外内容 | 无 | `QuestSystem`（第三方，Basic Quest System v1.3f） |
| 能不能说"默认脚本兼容" | **能**，限定为"VX 默认脚本集（含官方 VX_SP2 补丁）" | **不能**，只能说"引擎能执行 RGSS3 脚本集" |

为什么不下"逐字节等于 Enterbrain 官方文件"的结论：这台机器上没有装 RPG Maker，
拿不到官方安装目录里的那份 `Scripts.*` 做 byte-diff。上面的结论来自**结构审计**
（段名/顺序、类重开范围、非 ASCII 扫描），不是哈希对比 —— 这一点必须写明，别把
"没发现改动"说成"证明没改动"。

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
4. **字体**：测试机没有 `UmePlus Gothic` / `VL Gothic` / `Arial`，中文靠垫片指到系统字体；
   垫片必须放在脚本归档的**最后一段**（`Main` 之后），否则 `Font.default_name` 会被
   默认脚本覆盖。
5. **合成地图的通行性**：VX 的 `Map001` 若全铺同一种图块，先查
   `System.rvdata` 的 `@passages[tile_id]`（8192 项、int16）。方向位含义：
   `0x01` 下 / `0x02` 左 / `0x04` 右 / `0x08` 上，`0x10` = 不影响通行，`0x0f` = 四向全挡。
   不通行时先怀疑这里，不要先怀疑引擎。

## 已知缺口

1. **没有官方默认脚本的字节级副本**：本机未安装 RPG Maker，无法做
   "解出来的段 == 安装目录里的段"的 byte-diff。VX/VX Ace 的"未改动"是结构审计结论。
2. **VX Ace 脚本集含第三方插件**（QuestSystem），因此 VX Ace 的结论只能是
   "引擎能执行 RGSS3 脚本"，不是"默认脚本兼容"。
3. **VX 行走没有数值读数**：本次用帧差分证明位移（8,192 px），旧记录里的 "x 8→99"
   没有留存读数，不要当证据引用。
4. **mkxp-z 还没打包进 `.app`**：`Contents/Resources/runtime/` 目前只有
   `easyrpg-player`；`LaunchBackend` 也没有 `mkxpz` 这一档，所以
   `EngineKind.rgss1/2/3.launchBackend` 仍是 `nil`（`Tests/e2e/cases/contract/qa_probe.swift`
   的 V6-30..33 钉住这个状态，接后端时会红，提醒同步本文）。
5. **没有音频、没有 RTP**：三代都用占位图，`No soundfont specified` 是预期日志。
6. **未验证任何商业游戏**：四个 fixture 都是测试工程/合成工程，
   真实国产 XP/VX 游戏常依赖 Win32API 与外部 DLL，mkxp-z 跑不动。
