# RPG Maker 经典版本兼容 · 架构决策记录（P2-01）

> **本文档的定位**：这是为 P2-01（RGSS XP/VX/VX Ace）与 EasyRPG（2000/2003）两条路线补的架构决策记录，**补充而非替代** `docs/prd.md` §A.1。§A.1 规定"认成什么引擎"，本文规定"认出来之后能不能跑、跑什么、代价多少"。识别口径以 §A.1 为准；本文新立的口径（`launchBackend`、`--play-native`、迁移钩子）须回写 PRD 才成为验收依据。

| 项 | 内容 |
|---|---|
| 文档 | RPG Maker 2000/2003/XP/VX/VX Ace 兼容架构决策 |
| 分支 | `feat/rpgmaker-classic-compat` |
| 输入 | P2-01 条目、`re-findings.md` §11、MTool APK 符号级实测（§三）、liblcf / mkxp-z 源码级实测（§五 ADR-1） |
| 不含 | 引擎识别优先级与 `reason` 枚举（`prd.md` §A.1）、MV/MZ 现有链路（`architecture.md`） |
| 证据口径 | **实测** = 有可复现命令、符号名或 `file:line`；**推测：** = 无直接证据的判断。两者不混写 |

## 一、目标与范围

把五个版本从"识别得出、跑不起来"推进到"数据层可读可写、运行时可启动"。缺口集中在一个属性上：

| 层 | 现状 | 位置 |
|---|---|---|
| 识别 | **已完成**：easyrpg / rgss1 / rgss2 / rgss3 四条 high 置信签名齐备 | `Sources/Adapters/EngineDetector.swift:159-188` |
| 库模型 | `isLaunchable` 只认 mv/mz，与 `supportLevel` 无关（撰写时） | `Sources/Domain/Models/LibraryModels.swift:26-30` |
| 数据层 | 无 LCF 与 Marshal 读写能力 | 不存在 |
| 运行时 | 只有 NW.js + CDP 一条通道 | `Sources/Adapters/` |

> 上表是**撰写时**的现状快照，不是当前状态：运行时已有内置 EasyRPG 与自建 mkxp-z 两条子进程通道。落地结果见 §八 的状态行，实测证据见 [`rpgmaker-runtime-verification.md`](rpgmaker-runtime-verification.md)。

边界：不引入 Wine（需关 SIP / root，不可分发，`re-findings.md` §11 已判死）；不做存档编辑与内购解锁（P2-07 口径）。

## 二、五版本格式矩阵

| 版本 | 工程文件 | 数据文件 | 加密包 | 原始运行时 | 文本所在层 | 编码 |
|---|---|---|---|---|---|---|
| 2000 | **无** | `RPG_RT.ldb`、`RPG_RT.lmt`、`MapXXXX.lmu`、`SaveXX.lsd` | 无 | `RPG_RT.exe`（Win32 + DirectX） | LDB 的角色/技能/物品/敌人段与术语段；LMU 的事件指令 | ANSI 代码页：日文 Shift-JIS，简中汉化常为 GBK，繁中汉化常为 Big5 |
| 2003 | **无**（同 2000） | 同上，另有仅 2003 的 BattleCommands / Classes / BattlerAnimations 段 | 无 | `RPG_RT.exe`（Win32 + DirectX） | 同上 | 同上 |
| XP | `.rxproj` | `Data/*.rxdata` | `.rgssad` | `Game.exe` + `RGSS` DLL（Ruby 1.8.1） | `RPG::Actor#name` 等字段、`RPG::EventCommand#parameters` | 无 encoding ivar |
| VX | `.rvproj` | `Data/*.rvdata` | `.rgss2a` | `Game.exe` + `RGSS2` DLL（Ruby 1.8.1） | 同上 | 无 encoding ivar |
| VX Ace | `.rvproj2` | `Data/*.rvdata2` | `.rgss3a` | `Game.exe` + `RGSS3` DLL（Ruby 1.9.2） | 同上 | 带 `:E` encoding ivar |

七条跨版本事实：

1. 2000/2003 的数据是 **LCF 二进制**：BER-VLQ 变长整数 + 长度前缀字符串，无文本格式可言，必须用库读写。
2. XP/VX/VX Ace 的数据是 **Ruby Marshal**，版本号**始终 4.8**，跨 Ruby 1.8～3.x 不变；`Table` 走 `u:` 自定义序列化（5×int32 LE 头 + n×int16）。
3. Marshal 的唯一差异是 Ruby 1.9 引入的 `:E` encoding ivar，且方向**单向**：1.8 写的数据 3.x 能读，反之不能；数组内的字符串同样要递归处理。这决定了 VX Ace 的样本不能降级冒充 XP/VX。
4. RGSS 的事件指令 code 稳定：`101` 首行 / `401` 续行 / `102`·`402` 选项，VX / VX Ace 另有 `405` 滚动文本。2000/2003 **不在这套编号体系内**：ShowMessage=`10110`、ShowChoices=`10140`、选项分支=`20140`/`20141`，指令是 `(code, indent, string, parameters)` 四元组。
5. 加密包分两代：`.rgssad` / `.rgss2a` 是 v1（固定初始 key `0xDEADCAFE`，逐字节 key*7+3；文件头是 `RGSSAD` + version 字段），`.rgss3a` 是 v3（随机 base key + 每文件 file_key）。`Scripts.*` 是 `[id, name, zlib 源码]` 三元组。
6. 2000 与 2003 的**权威判据是解析后的 `db.system.ldb_id == 2003`**（本仓库 `vendor/liblcf-src/src/saveopt.cpp:6-11` 的 GetEngineVersion），不是文件名，也不是某个 chunk 在不在。writer 完全看 `ldb_id`：`ldb_id=0` 时 `Save` 返回成功，但仅 2003 的 `0x1D` battlecommands / `0x1E` classes / `0x1F` battleranimations（另有 `0x1B`/`0x1C` 的 D2/D3）**静默丢失**；chunk 是否存在只反映写入时的编码方式，不能反推版本或数据是否存在——判版本只认 `ldb_id`。反例：2k3 清空 classes 后仍判 2003；2k 塞入 classes 再 Save（被丢弃）仍判 2000。**检测层只能到 `engine=easyrpg`**，版本另存可选 `rmVersion`，不新增 `EngineKind`。
7. 术语字段三版形状不同：XP `RPG::System` 的 `@words` 扁平 20 条；VX 的 `@terms` 扁平 33 条；VX Ace 的 `@terms` 嵌套 `@basic`/`@commands`/`@params`/`@messages`。

## 三、MTool Android 端逆向（符号级实测）

对象：`mtool_easyrpg_v10001_1.apk`、`mtool_mkxpz_v68_1.apk`。方法：`.so` 符号表 + 交叉引用。

| 版本 | 引擎 | 注入层 |
|---|---|---|
| 2000 / 2003 | EasyRPG Player 0.8.1（内嵌 liblcf 静态） | C++ `Text::Draw` + `Text::GetSize` **双点**替换，另有 `Window_Help::AddText`、`Window_Message::UpdateCursorRect` |
| XP / VX / VX Ace | mkxp-z 2.4 自建分叉，三套 MRI 并行 | Ruby 脚本层全局 `fixString(str, len)`，**就地改写 Ruby String 字节缓冲** |

关键证据：

- `lib/arm64-v8a/libeasyrpg_android.so` 15.6MB，含 `lcf::rpg::*` 模板符号、`MtoolRpc::Translate`、`MtoolExtract::ExtractAllJson`。
- `libmkxp-z.so`（Ruby 3.1.3）/ `libmkxp-z-187.so`（Ruby 1.8.7）/ `libmkxp-z-193.so`（Ruby 1.9.3），三个 `libruby*.so` 并存。
- `fixString` @0x40fb6c 的**唯一调用者**是 `rb_mri_fixString`（注册给 Ruby 的全局函数），C++ 绘制路径完全不碰翻译 → **RGSS 的钩子只在 Ruby 层**。
- 两端共用 C++ 组件：`mtool::TranslationCache{get,put,clear,adaptiveAdjust}` + `loader_common::ws::{MToolSocketTransport,TextRpcRuntime}`，走 `127.0.0.1:$MTOOL_PORT` 的 WebSocket JSON-RPC，`$MTOOL_AUTH_TOKEN` 鉴权。
- Android 的 `.so` 是 ELF aarch64，macOS 要 Mach-O，**不可直接用**，必须从上游源码编。
- Ruby 注入脚本正文**不在 APK 内**（`loader.bin.ff` 只有文件名，无 zlib 流、无 `class Window_` 正文），由服务端下发 → 想复刻只能自己写 dispatcher。

**双点替换的必要性**：只改 `Text::Draw` 不改 `Text::GetSize`，中文按日文原宽测量 → 换行与居中错位。这是"运行时不改数据"方案的硬要求。

## 四、可用开源运行时

| 项目 | 许可证 | 覆盖 | 注入面 | 上游 |
|---|---|---|---|---|
| EasyRPG Player | GPL-3.0 | 2000 / 2003 | 官方 PO 翻译（`Language/<name>/Meta.ini` + `lcftrans` 生成，免 fork），**无**逐句回调 | `EasyRPG/Player` |
| liblcf | MIT | 2000 / 2003 数据层 | LCF 读写，可编成零依赖静态库 | `EasyRPG/liblcf` |
| mkxp-z | GPL-2.0+ | XP / VX / VX Ace | `mkxp.json` 的 `preloadScript` / `postloadScript` / `patches` 三个注入点；实时翻译需 alias `Window_Base#draw_text_ex` | `mkxp-z/mkxp-z` |

许可证组合：本项目是 AGPL-3.0。GPL-3.0 可依 AGPLv3 §13 直接组合；GPL-2.0+ 可升 GPLv3 后同样兼容；liblcf MIT 无约束。但 **GPL 与 App Store DRM 冲突**——这是分发渠道的约束，不是代码问题，走官网直发可绕开。

**minos 约束**：Homebrew 的 `liblcf` / `easyrpg-player` bottle 是 `arm64_golden_gate`，实测 minos **27.0**，与 `Scripts/build.sh:15` 的 `arm64-apple-macos13.0` 冲突。链接只 warning，产物 minos 仍是 13.0，但在 macOS 13–26 上 dyld 拒载。**必须源码编**并显式指定 `-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0`。

EasyRPG Player 本体依赖太多（SDL2 等），不做静态内链，只能内置独立可执行 + 子进程（§九「独立窗口」风险的来源）。

**2000/2003 的译文载体是 PO，不是改 LDB**：`--language <LANG>` 与 `--save-path <存档目录>` 0.8.1 即有；`--language-path` **只有 master 有**，0.8.1 只读 `<游戏目录>/language/<LANG>/`——"外部语言目录 + 零写盘"要么自编 master，要么把整棵游戏目录复制到自有位置、保持原树形不改任何文件，再用 `--project-path` 指过去（`--save-path` 把存档挪出）；依赖 RTP 的游戏不会因复制而完整。布局 `PATH/<LANG>/meta.ini` + `*.po`，五类：`rpg_rt.ldb.po`、`rpg_rt.ldb.common.po`、`rpg_rt.ldb.battle.po`、`rpg_rt.lmt.po`、`mapNNNN.po`。msgid/msgstr 用**完整原串**（含 `\n[1]`、`\v[1]`），变量在译文后展开，码不能剥。数据库字段 msgctxt 必须**非索引**（`actors.name`）：0.8.1 只查非索引，`actors.1.name` 全落空。`meta.ini` 必须写在 **`[Language]` section** 下（`translation.cpp:117-125` 写死），键 6 个：`Name`/`Code`/`Term`/`GameTitle`/`Font` 与可选的 `Description`（`Term` 默认 `Language`）、**写错 section 会被静默忽略**。`vendor/liblcf-src/src/inireader.cpp:164-169` 的 `MakeKey` 是 `section+"="+name` 再小写，但只解释机制，不能反推 section。

## 五、架构决策

### ADR-1：liblcf 零依赖静态构建 + C shim

实测参数（27s 完成，产物 `liblcf.a` 5.0MB / 156 个 `.o`、shim 1.1MB；最终 Swift 程序 1.2MB，`otool -L` 只剩 libc++/libSystem/Foundation/libswift*，ICU 符号 **0** 个，`vtool` minos 13.0，零 brew 依赖）：

```
-DBUILD_SHARED_LIBS=OFF -DLIBLCF_WITH_ICU=OFF -DLIBLCF_WITH_XML=OFF
-DLIBLCF_WITH_INI=OFF -DLIBLCF_ENABLE_TOOLS=OFF -DLIBLCF_ENABLE_TESTS=OFF -DLIBLCF_ENABLE_INSTALL=OFF
-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=arm64
```

shim 是必需品而非优化：Swift 的 clang importer 按 C 解析头文件，桥接头里出现 `class` 直接报 `unknown type name 'class'`。`.cc` 也不能随 `swiftc` 一起编（`-Xcc -I` 传不进去），必须 `clang++ -c` 先出 `.o`；shim 用 STL 时补 `-lc++`。

**编码判定（候选集含 Big5）**：LDB 里存的是裸字节，文件头不标编码，而且同一份 .ldb 里日文原文与汉化文本混排是常态（实测 Chi-Hsin/reversestone：3004 条非空字段里 2528 条繁体中文、476 条仍是日文），所以判定只能**逐字段**做。候选集是 Shift-JIS / GB18030 / **Big5** / UTF-8：先看两条确定性信号（合法 UTF-8 且解出 CJK → UTF-8；合法 Shift-JIS 且含全角假名 → Shift-JIS），再按字符类打分；最后——**只在 GB18030 已经胜出时**——让 Big5 用"常用字命中率"挑战一次。

为什么最后一步必须换成语义判据：GB18030 与 Big5 的字节域几乎完全重叠（Big5 首 `0xA1–0xF9`、尾 `0x40–0x7E`/`0xA1–0xFE` 全部落在 GB18030 的合法范围内），**每个合法 Big5 字节串都是合法 GB18030**，纯字节范围判不出来；两者解出来的又都是汉字，按字符类的"可读性"打分给它们同分，而"同分取先试的"意味着 Big5 只要排在候选里就永远输。能分开它们的只有"像不像人话"：正确编码解出常用字，错误编码解出生僻字或 PUA（实测 2528 条里 1511 条按 GB18030 解出 PUA）。所以两张常用字表（各约 1590 字，简体/繁体同源同序）加一个扣分项（PUA / 半角片假名 / 西里尔），分数高者胜。实现在 `Sources/Adapters/LCF/LCFTextCodec.swift`（判定）与 `LCFCommonChars.swift`（字表）。

局限与覆盖：真机验证过两份繁体工程（2026-11-02）—— Chi-Hsin/reversestone 2419/2528 判为 Big5、RenaWevin/MyFireDragon 315/320；剩下的是两种解码都像人话的短名（104 条平局，如 龐斯/胑吹），要靠语言模型才能再分。**GBK 仍只有合成样本**，别对外宣称已覆盖简体汉化版（依据与重开条件见 [known-limits.md#L1](known-limits.md#L1)）。

**编码策略**：`LDB_Reader::Load(path, "")` 的空串 = **原始字节直通**，不做转码。无 ICU 时 `DetectEncodings()` 硬编码返回 `{"windows-1252"}`，所以**只能传 ""**；转码 100% 落在 Swift 侧（`String.Encoding.shiftJIS` 与 `CFStringEncodings.GB_18030_2000`）。直通与转码是同一条路径的两个模式：`src/encoder.cpp:65` 首行 `if (_encoding.empty()) return;`，一个字节都不转。实测 GBK `d6d0cec4`、CP932 `836583588367` 往返逐字节不变，ICU=ON 与 OFF 对 `Load(path, "")` 输出一致。

反向守卫是必需的：ICU=OFF 时传 `"gbk"` 不报错，会走 windows-1252 **静默损坏**。shim 只允许空串，非空直接拒绝。`LIBLCF_WITH_XML=OFF` 是因为用不上，不是因为缺库（expat 2.7.4 在 CLT SDK 里，`-lexpat` 可编）。

**字段路径**：反射层 `ForEachString(obj, cb, ctx)` 给出 `actors[0].name`、`commonevents[0].event_commands[1].string` 这类稳定唯一路径，可直接作翻译记忆的 key。

**写中文的约束**：cp932 表示不了简体字，整库必须统一转 GB18030 或 UTF-8，且运行时引擎按同一编码读。这是产品决策点，不是实现细节——定了就不能半途换。作用域仅限"导出整包译制版"；会话内的翻译通道走 PO，不写 LDB。

### ADR-2：静态能力表取代适配器注册表

`isLaunchable` 是 Domain 纯值类型的计算属性，有四个调用点（`SessionController.swift:235`、`MainWindow.swift:316`/`:395`、`probe_store.swift:179`）。查可变全局注册表会：破坏 `EngineModels.swift:6-8` 的无环 DAG、让属性依赖注册时序、破坏 `Hashable` 稳定性。**且代码里根本不存在适配器注册表**——`architecture.md:831` 的 `EngineAdapterRegistry` 从未落地（`grep` 零命中），`SessionController.swift:269` 直接构造 `MVAdapter`。

决策：`EngineKind` 上加穷举 switch 的 `launchBackend: LaunchBackend?`（`nwjsWeb` / `easyrpg` / `mkxpz`，其余 `nil`），`isLaunchable = (launchBackend != nil) && !missing`，`SessionController` 的适配器构造共用同一张表。新增引擎时编译器强制回答"能不能跑"。

**不要用 `supportLevel == .p0` 当闸门**：Tyrano 的 `declaredSupportLevel` 是 `.p0`（`EngineModels.swift:80`）但不可启动，照抄 `architecture.md:493` 的公式会把它误判为可启动。

### ADR-3：启动能力与 supportLevel 解耦，展示层派生

`supportLevel` 是**入库快照**：`EngineDetector.swift:94` 只在识别时写入，旧库不重跑识别，记 p2。

`schemaVersion` 做迁移是**空操作**：所有保存点都走 `LibraryFile(games:)` 的默认 `init(schemaVersion: 1)`（`LibraryModels.swift:64`；保存点 `SessionController.swift:1081/1107/1122/1150`），下次保存写回 1。

`SupportLevel` 是落盘枚举，新增 case 会让旧 App 整库解码失败、空库启动。改用 `GameEntry.displaySupportLevel` 派生：`launchBackend != nil && supportLevel == .p2` →「可启动（内置运行时）」，其余用 `uiLabel`；旧库读入即正确，不写盘。

### ADR-4：测试契约保持不变，启动能力另立断言

`Tests/e2e/cases/contract/qa_probe.swift` 的 V6-06（easyrpg→p2，:207）、V6-07（rgss3→p2，:210）、V6-17（rgss2→p2，:244）、V6-22（rgss3 大小写→p2，:259）钉的是 PRD §A.1 表。**这 4 条不改**，新增 V6-26+ 只断言 `isLaunchable`。识别契约与启动能力就此解耦。

`--play` 不走 `isLaunchable`：`AttachCLI.swift:633-684` 直接构造 `MVAdapter` 并 launch，且 `play: http=` 是 kernel/faults 层的硬契约（`Tests/e2e/cases/_kernel_kit.mjs:111` 的正则带行尾 `$`）。老引擎无 HTTP 端口 → **不能改这一行**，必须新增 `--play-native` 输出 `play: backend=...` 并开独立 suite。

**`--play-native` 不是"多打一行日志"**：`--play` 的退出码语义绑在 `AttachCLI.swift:611-625` 的 `environmentCodes`（环境缺口 → exit 3 + `error_code:` + `play: environment=`）。新模式的 `runtimeMissing` / `runtimeNotExecutable` **必须加进这张表**，否则掉回 exit 1、脚本无法按码分支。现成模板是 `Tests/e2e/cases/faults/07_unknown_engine.mjs:24-35`（空目录 → exit 3 + `launcher_no_executable`）。`launcherNoExecutable` 语义不动，两个新码只用于"引擎已判 easyrpg / rgss，但运行时缺失"。suite 必须新开，不复用 `play: http=` 的 kernel / faults 分层。

> **落地差异（2026-11-02）**：没有新开 suite，两条用例作为 **F11 / F12 并入 `faults`**（`11_play_on_native_engine.mjs` 验 `--play` 拒绝原生后端，`12_native_engine_faults.mjs` 验缺 `Game.ini` / `Library=` 错配）。`play: http=` 那行正则与既有 kernel / faults 断言未动，ADR-4 的**目的**（识别契约与启动能力解耦）仍成立。

### ADR-5：「仅 MV/MZ」的六处硬编码

| # | 位置 | 性质 | 处理 |
|---|---|---|---|
| 1 | `MainWindow.swift:191`「仅 MV/MZ」 | 文案 | 按 `launchBackend` 改写 |
| 2 | `FullTextPanel.swift:551`「仅支持 MV/MZ」 | 文案 | 同上 |
| 3 | `EngineModels.swift:132` p2 文案「暂不支持（需 Wine 后端）」 | 文案 | 视图层已按 ADR-3 派生；p2 原文案保留给无后端引擎 |
| 4 | `CheatController.swift:57` `isAvailable` | 能力门 | 按 `rpcCheats` 判断（§六） |
| 5 | `MainWindow.swift:155-158` `isMVMZ` | 能力门 | 按 `rpcCheats` / `fullTextScan` 分别判断 |
| 6 | `CheatController.swift:178`「仅 MV/MZ 支持修改器」 | 文案 | 写本文时补查所得，同样要改 |

> 落地状态（2026-11-02）：1 / 2 / 3 / 6 的文案已改写（`grep '仅 MV/MZ' Sources/` 只剩 `FullTextPanel.swift:44` 的一条注释，不再是用户可见文案）；4 / 5 已改为按 `RuntimeCapabilities.rpcCheats` / `fullTextScan` 分轴判断。

4、5 是功能开关不是文案：跑得起来（`launchBackend`）与能作弊（`RuntimeCapabilities`）是两件事，见 §六。

**注意**：`Tests/e2e/cases/contract/03_rpc_table.mjs` 的 T-000c 是**双向集合比**，直接读 `Resources/agent_mvmz.js` 的 `var RPC` 块（:365 起）。老引擎的 RPC 必须放在**另一个 js 文件**里，否则该用例立刻红。

## 六、能力模型：三轴，不是两轴

| 轴 | 载体 | 谁能写 | 管什么 |
|---|---|---|---|
| `supportLevel` | 入库快照，落 `library.json`（`LibraryModels.swift:19`） | 只有 `EngineDetector.swift:94` | 展示与 PRD §A.1 契约 |
| `launchBackend` | `EngineKind` 上的静态穷举表 | 编译期固定 | 启动闸门 + 适配器构造 |
| `RuntimeCapabilities` | 运行时上报，挂在 `AttachInfo`（`EngineAdapter.swift:111-118` 是值类型，加带默认值的字段零破坏） | 适配器 | 作弊 / 全文 / 注入 |

三个字段：`rpcCheats`（45 项 RPC = 42 个在用 `cheat.*` + 1 个别名 `cheat.recover` + 2 个 `text.scan*`）、`fullTextScan`（`text.scanStart` / `text.scanCancel`）、`jsInjection`（AgentInjector）。离线扫描另立 `offlineScan`，**不并入 `fullTextScan`**——它不是 `EngineAdapter.probe` 那条管道（无调用方，`dataRoot`/`launchLayout` 只写不读），是直读磁盘的新链。

按引擎的预期（**预期**，非实测）：

| 引擎 | `launchBackend` | `rpcCheats` | `fullTextScan` | `offlineScan` | `jsInjection` |
|---|---|---|---|---|---|
| MV / MZ | `nwjsWeb` | ✓ | ✓ | — | ✓ |
| EasyRPG | `easyrpg` | ✗ | ✗ | ✓ | ✗ |
| mkxp-z | `mkxpz` | 视 Ruby 桥 | 视 Ruby 桥 | ✓ | ✗ |

两条：

1. **同一条判断现在硬编码了三遍**：`MainWindow.swift:155-158` 的 `isMVMZ` 同时喂提示文案（:190-195）与 `FullTextPanel` 门禁（:218），`CheatController.swift:57` 又单独判一次。绑成"是 MV/MZ"一个布尔，EasyRPG 跑得起来却整块功能消失，也无法表达"RGSS 有桥就能作弊"。
2. **`rpcCheats=true` 只表示"有桥"，不表示 45 项都在**。RGSS 上不可能一一对应，必须另给方法 profile 并在 `CheatController.perform` 前置拒绝，否则面板上出现点了没反应的按钮，还要吃满超时（`text.scanStart` 单次 30s——不是总预算——其余 5s，`AgentRPC.swift:163-165`）。权威源是 `agent_mvmz.js:2960-3007` 的 `var RPC`（45 项）；Host 侧 `CheatMethod` 是 42 个 case（`CheatController.swift:709-750`），差集只有 `cheat.recover` 与两个 `text.scan*`。Swift enum 的 rawValue 应对 `var RPC` 做双向守卫：新增一条 e2e 读 `CheatController.swift` 的 case 字面量与 `agent_mvmz.js` 的 `var RPC` 双向比集合，期望 45 == 45。

## 七、测试样本来源与许可证

| 版本 | 来源 | 许可 | 体积 / 形态 | 备注 |
|---|---|---|---|---|
| 2000 | `EasyRPG/TestGame`（TestGame-2000） | GPL-3.0 | ~240KB：LDB + LMT + ini + 3 个 LMU | 素材是 EasyRPG 自制的 CC-BY 替代品，**不是 Enterbrain RTP** |
| 2003 | 同上（TestGame-2003） | GPL-3.0 | ~450KB：同结构 | 同上 |
| XP | `aphadeon/OpenXP` | MIT | 492KB，15 个真实 `.rxdata` | 含 Actors / Items / `@words` 真文本，事件层为空 |
| VX | `nathaniel-daniel/rgssad-rs` | Apache-2.0 | ~340KB，14 个 `.rvdata`（Git LFS，需 `media.githubusercontent.com` 取真身） | 数据库层有真文本，事件层为空 |
| VX Ace | `caynine9/Jimicization-Project` | CC0-1.0 | 27 个真实 `.rvdata2` + `Game.ini` / `Game.rvproj2`（470,061 B） | 数据库 + 事件层都有真文本（1,463 条）；**默认脚本仍无官方字节级副本**，见 `rpgmaker-runtime-verification.md` |

XP / VX 两个外部样本**事件层**为空（Map 的 `@events` 空、`CommonEvents` 只有 code=0）；VX Ace 的真实样本事件层非空（236 条 101/401 文本）。数据库层三个样本都有真文本：

- XP Level-1 = OpenXP 的 15 个 `.rxdata` 全解；Level-2 = 数据库 / 术语 ✅（Actors 9 个 name、Items 33 条 name+description、`@words` 20 条）+ 事件 ❌ → 合成 `Map002.rxdata`（101×3 / 401 / 102 / 402 / 404，3,060 B，已 PASS）补事件层。
- VX Level-1 = 14 个 `.rvdata` 全解；Level-2 = 数据库 / 术语 ✅（Skills 82 全带 description、Items 20、Weapons 30、Armors 30、States 16、`@terms` 33 字段全非空）+ 事件 ❌（40 条 EventCommand 全是 code=0，合成器未做）。
- VX Ace Level-1 = `Fixtures/rmvxace-real/` 的 27 个 `.rvdata2` 逐个解析并往返字节相同（1,463 条文本，`@terms` 4 个容器）；Level-2 的合成样本只补 `terms.commands` 哈希键路径。**默认脚本集是 CC0 工程的结构审计结论，不是官方安装副本**（本机未装 RPG Maker，做不了 byte-diff）。
- 2000/2003：TestGame 的 LDB + LMT + ini + 3 个 LMU，**不含位图/音频**（LCF 只存文件名）；LMU 有 176 条可读字符串且带 `\s[1]` 转义码。

因此「XP 文本支持」只在数据库 + 术语 + 合成事件三层成立，**不得写成已验收**；VX Ace 有真实事件层，但默认脚本仍只有结构审计。附带一条：`OpenXP` 的 `Game.ini` 是 `Library=RGSS104E.dll`，子串命中 `EngineDetector.swift:184` 的 `"Library=RGSS1"`，可直接作 XP 识别正例。

许可侧：以 `Fixtures/README.md` 为准。

自合成可行性（实测）：系统 ruby 2.6.10，`Marshal.dump(1)[0,2].bytes = [4,8]`。RGSS1/2 用 `.b`（ASCII-8BIT）得到**无** `:E` ivar 的字符串，与真实 VX 文件逐字节一致；RGSS3 用默认 UTF-8 得到**带** `:E`。**不需要 Ruby 1.8**（本机没有，brew 也无 formula）。

明确不做：不下载整份 TestGame（54MB）；不碰带 `VXACE_EULA.rtf` / `Game.exe` / `RGSS*.dll` / VL Gothic 的工程；不引 RPGMakerDecrypter 的加密归档样本（内容版权不明）。

## 八、分阶段落地

| 阶段 | 内容 | 产出判据 |
|---|---|---|
| **Phase 1** ✅ | 2000/2003 的 LCF 数据层 | liblcf 零依赖构建 + C shim + Swift 封装 + 真实 LDB 文本提取；**回写只服务"导出整包译制版"，不是会话内通道** |
| Phase 2 | RGSS 三版的 Marshal 数据层：**XP 先**（OpenXP + 合成 Map002 双 fixture 已齐），VX 紧随（14 个 `.rvdata` 已解，事件合成未做），VX Ace 最后（CC0 真实样本已入库） | 纯 Swift 解析/写回 + 三版本样本 + 文本路径提取；mkxp-z 构建已通（见 §九） |
| Phase 3 | 接线 | `launchBackend` 静态表、`LaunchStrategy.nativeRuntime`、适配器构造、`displaySupportLevel` 派生、六处能力门、`--play-native` |
| Phase 4 | 运行时 | 2000/2003 走 EasyRPG + PO 预翻译（0.8.1 只认游戏目录内的 language/：自编 master，或复制数据 + `--project-path`）；**游戏内无实时通道**，文本流只在 MochiBox 侧可见；静态文本接近全覆盖，脚本生成的内容盖不住。RGSS 三版用 mkxp-z + Ruby hook 做实时 |

落地状态（2026-11-02）：**Phase 1–3 已完成**；Phase 4 的**启动**与 **RGSS 实时文本通道**都已完成：EasyRPG 与 mkxp-z 都装进 `.app`，`--play-native` 能拉起；XP / VX / VX Ace 的 Ruby hook 已由 `GameLauncher` 注入 `preloadScript`，覆盖 message / menu / choice / help / battle 五个面，五个面默认全开。首遍仍显示原文，缓存命中后显示中文；只改显示层，不动存档与事件状态。2000/2003 仍只有 EasyRPG + PO 预翻译，没有游戏内实时通道。实现、入口清单与真机证据见 [`rgss-text-channel.md`](rgss-text-channel.md) §0.1。上表保留为决策记录。

若要做 2000/2003 的**实时**翻译，需 fork EasyRPG 加 IPC 回调，XL 成本，非刚需不做。

## 九、已知风险

- EasyRPG 的 PO 只覆盖预翻译，无逐句回调、无作弊接口；CJK 字体需随包提供。
- mkxp-z 跑不动依赖 Win32API / 外部 DLL 的国产游戏。
- mkxp-z / EasyRPG 是**独立 SDL 窗口**，塞不进 WKWebView，只能"独立窗口 + 透明浮层"。SDL3 子进程可被 `Process` 拉起并获得焦点，但不能跨进程挂子窗口，需 `CGWindowList` / Accessibility 取 frame + 独立 floating `NSWindow`；裸二进制无 Dock/菜单，需最小 `.app` 壳或 `LSUIElement`。
- `lcf2xml` → `edb` → `ldb` **不字节保真**（未改动的 GBK 行也可能换码），XML 只能检视，写回必须二进制原地改；`LDB_Reader::Save` 会把默认值显式写出，体积会变大（883B → 2.0K）。
- 回写前必须确认 `db.system.ldb_id`：writer 由它决定写不写 2003-only 段，`ldb_id=0` 时 `Save` 返回成功但 `0x1D`/`0x1E`/`0x1F` 直接消失，且无法从 chunk 反推。
- 分段器对非 mvmz family 返回单段、不剥码（`Segmenter.swift:18-22`），控制码会进译文。`K.engineFamily` 是全局常量（`Constants.swift:46`），`Sources/` 内 36 处引用、`engineFamily` 标识符共 54 处。改 per-engine family 会改 `cacheKey` → 全部历史缓存 miss，**必须保证** `.mv.family == "mvmz"` 逐字不变。
- `GameLauncher.resolveStrategy` 的 nwjs 规则**不看 engine**（`GameLauncher.swift:139-146` / `:156-169`）：带 `EasyRPG Player.app` 的游戏目录会被当 nwjs 启动，必须按 engine 收窄。
- mkxp-z 已端到端打通：`forcefallback` 全源码构建 2586/2586（约 10 分钟），构建产物 42,387,520 B（40.4 MiB）、strip 后分发 35,513,696 B（33.9 MiB）、minos 13.0、`otool -L` 里 `/opt/homebrew` 计数 **0**；三版默认脚本集都已跑通（XP：标题→New Game→Map001→事件弹两行中文→菜单→行走 `Step Count` 0→5；VX：标题→地图→菜单→行走；VX Ace：标题→New Game→开场文本→行走，坐标 `(3,5)→(7,5)→(7,7)`），ANGLE→Metal 正常。两条限制（均已作为负结论关闭，见 [known-limits.md#L2](known-limits.md#L2) / [known-limits.md#L3](known-limits.md#L3)）：① 设置菜单要 `macos/views/meson.build:13` 的 `ibtool`（只有完整 Xcode 提供）。2026-11-02 在 Xcode 许可证/首启组件就位后用真 `ibtool` 重建，F1 设置菜单**已实测可用**（L2 已销）；只有 CLT 的机器仍会退化成「菜单不可用」。② Ruby 只能 3.1.3（仓库只有 `ruby-3.1.wrap`）。**老 RGSS 的 1.8 语义风险**已对**默认脚本集**实测消解（三版都在 Ruby 3.1.3 上跑通），但**第三方 / 商业脚本**仍未验证——只影响运行时兼容，不影响构建。官方无 macOS 二进制（0 release），CI 目标 11.0，自建可改 13.0。
- **mkxp-z 是自建二进制**：`vendor/mkxpz/mochibox-macos-fixes.patch` 共 **3 个** macOS 补丁（字体固定、`iconv_open` 失败防护、`PHYSFS_stat` 失败分支），再加上 `ibtool` 编 `settingsmenu.nib` 这一步（要完整 Xcode）；上游没有官方 macOS 二进制可依赖。
- **分发体积**：整包 `.app` 约 **77 MB**（EasyRPG 33.9 MB + strip 后 mkxp-z 33.8 MiB + 产品本体 7.3 MB；strip 前 83 MB），显著大于纯 MV/MZ 版本。
- **未验证**：除 TestGame-2000 之外的第三方 LDB / LMT / LMU、`LSD` 存档、**任何商业游戏**（现有 fixture 都是测试 / 合成工程；依赖 Win32API 与外部 DLL 的国产游戏仍跑不动）、Wine 路线。
- **已实测到交互层**：XP / VX / VX Ace 的 mkxp-z 链路都过了标题、地图、菜单与行走；XP 有 `Step Count` 读数，VX Ace 有坐标读数，VX 只有像素位移证据。证据强度（A / A-）与复现步骤见 [`rpgmaker-runtime-verification.md`](rpgmaker-runtime-verification.md)。
- **脚本仍是限定条件**：VX 相对官方 EN 默认集 **94/95 段逐字节一致**、`Game_Interpreter` 差 **2 行**（社区修补）；VX Ace 的 129 段来自 CC0 工程，只有与工程原文件的逐段比对 + 结构审计，**没有官方安装副本的 byte-diff**。

## 十、已知不一致（文档 vs 代码）

| # | 文档说法 | 代码事实 | 处置 |
|---|---|---|---|
| 1 | 旧版 `architecture.md`：`isLaunchable` = `supportLevel == .p0 && !missing` | `launchBackend != nil && !missing`（`LibraryModels.swift:29`）。照旧文档公式，Tyrano（p0 但无适配器）会被误判可启动 | **已修订**：`architecture.md:495` 的代码草图已改成 `launchBackend` 口径 |
| 2 | `architecture.md:834` 有 `EngineAdapterRegistry` | `Sources/` 零命中，`SessionController.swift:269` 直接构造 `MVAdapter` | 文档写的是目标态；ADR-2 明确**不补**这个抽象 |
| 3 | `EngineModels.swift:132` p2 文案「暂不支持（需 Wine 后端）」 | 该文案仍是 p2 的兜底（kirikiri / wolf 等无后端引擎）；easyrpg / rgss1-3 已按 ADR-3 的 `displaySupportLevel` 显示「可启动（内置运行时）」 | 视图层已派生，p2 原文案保留；旧行号 `:100` 已漂移到 `launchBackend` |
| 4 | 交接口径「仅 MV/MZ 的 5 处硬编码」 | 实为 6 处（多出 `CheatController.swift:178`） | 已并入 ADR-5 表 |

## 附录 A · 复现方式

§三 与 §五 的实测结论对应下列命令（`<…>` 为产物占位，按实际路径替换）：

| 结论 | 命令 |
|---|---|
| 静态产物只剩系统库 | `otool -L <shim 或链接后的可执行>` |
| 产物 minos = 13.0 | `vtool -show-build <静态库或可执行>` |
| APK 内 liblcf 为静态内嵌 | `nm -C <libeasyrpg_android.so> \| grep -c 'lcf::rpg::'` |
| `fixString` 唯一调用者是 `rb_mri_fixString` | `nm -C <libmkxp-z.so> \| grep fixString`，再用 `otool -tv` 反查 `bl` 目标 |
| Marshal 版本号恒为 4.8 | `ruby -e 'p Marshal.dump(1)[0,2].bytes'` → `[4, 8]` |
| 四条识别签名齐备 | `grep -n 'easyrpg\|rgss' Sources/Adapters/EngineDetector.swift` |
| 启动能力仍是硬编码 | `grep -rn 'isLaunchable' Sources/` |

## 附录 B · Phase 2 待办清单

VX 合成器约 1.5 倍 XP 工作量：Map 的 ivar 从 11 涨到 18（净增 7）、`@bgm`/`@bgs` 由 XP 的 `RPG::AudioFile` 改为 `RPG::BGM`/`RPG::BGS`、字段序也不同、无 `@tileset_id`（XP 恒为 1）、新增 6 个 parallax 字段。
