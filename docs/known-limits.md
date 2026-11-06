# 已知限制与已关闭的负结论

本文档记录「我们确认做不到」的事，以及每一条的依据。
列在这里的项**不再作为待办**；如果要重开，必须提供新证据。

进这份文档的门槛是三条同时成立：

1. 有可复现的核查动作（命令 / 检索式 / 下载验证）；
2. 有明确的否定观测，而不是「我没找到」；
3. 写清**现存覆盖**与**残留风险**——关闭一项不等于风险消失。

---

<a id="L1"></a>
## L1 真实简体 GBK 的 RM2000/2003 工程样本

**状态**：已关闭 —— 不存在可分发样本

### 搜索范围（一次性做完，记录在此，不重做）

- WebSearch 10 个方向；
- GitHub 代码搜索 `filename:RPG_RT.ldb` → **281 条命中，全是 `.po`**（二进制不被 GitHub 索引）；
  `filename:RPG_RT.ini` → **100 条 / 60 个仓库**；
- GitHub topic 枚举 `rpg-maker-2000` / `rpg-maker-2003` / `rm2k` / `rm2k3` / `easyrpg` → **34 个仓库**。

### 逐个查 license 并下载验证的 11 个候选

| # | 仓库 | 许可 | 验证结果 |
|---|---|---|---|
| 1 | EasyRPG/TestGame | GPL-3.0 | 5 个 `.ldb` 全是 Shift-JIS，**0 条中文** |
| 2 | optimus-code/LcfSharp | NOASSERTION | Shift-JIS |
| 3 | depuschm/godot-lcf-editor | MIT | 4,239 B，**无任何高位字节** |
| 4 | ayoungco/funnyguyrpg | 无许可 | 英文 |
| 5 | TheWhiteCanvas/SaintSeiyaRPG2K_Cherry | 无许可 | 日文 |
| 6 | Chi-Hsin/reversestone | 无许可 | **真中文，但是 Big5** |
| 7 | RenaWevin/RM2K3Game-RME25W | 无许可 | **真中文，但是 Big5** |
| 8 | sivmatt/rm2k3-project-1 | CC0 | 仓库里**没有 `.ldb`** |
| 9 | timothy-opensource/jinandbeb | Apache-2.0 | 仓库里**没有 `.ldb`** |
| 10 | RPG-Maker-Translation-Tools/rm2k-lib | WTFPL | 样本是**现场合成的** |
| 11 | JinAsukin/rm2k-lcf-tools | MIT | **没有数据文件** |

按许可归类，11 个候选没有一个同时满足「许可明确 + 真含 GBK」：

- **许可明确、可再分发的 6 个**（#1 GPL-3.0、#3 MIT、#8 CC0、#9 Apache-2.0、#10 WTFPL、#11 MIT）：
  #8 #9 仓库里根本没有 `.ldb`，#10 的样本是现场合成的，#3 只有 4,239 B 且无高位字节，
  #11 没有数据文件，#1 是 Shift-JIS —— **含中文的为 0**。
- **无许可的 4 个**（#4 #5 #6 #7）：英文 1、日文 1、**真中文 2 但都是 Big5**。没有许可就不能入库。
- **NOASSERTION 的 1 个**（#2）：Shift-JIS。

### 规模性旁证

`lychees/rm-lib` 的 `games.json` 收录 **27,235** 款 RM2k/2k3 游戏，编码分布：

| 代码页 | 数量 | 占比 |
|---|---|---|
| 932（Shift-JIS） | 23,784 | 87.3% |
| 未知 | 3,443 | 12.6% |
| 950（Big5） | 8 | 0.03% |
| **936（GBK）** | **0** | **0%** |

被索引器标为「中文」的 8 条**全是 Big5**；GBK 一条都没有。

### 结论

不存在「许可明确 + 真含 GBK 简体」的 RM2000/2003 工程。原因是结构性的，不是搜索技巧问题：

1. **简体汉化版都是日文商业游戏的衍生作品**——文本版权在原开发商，汉化组自身也无权给出 OSI/CC 许可，
   所以任何可分发许可都不可能覆盖这类工程；
2. **GitHub 上能找到的中文 RM2k 工程实际都是 Big5 且无许可**（#6 #7）。简体原创工程在这个圈子里
   本来就少，且发布渠道是论坛/网盘而非 GitHub；
3. **有许可的工程里没有一份含中文**——GPL/CC0 的测试工程都是英文或日文原版。

### 现存覆盖

- **判据本身**：`Sources/Adapters/LCF/LCFTextCodec.swift` 用打分区分「GBK/GB18030 与 UTF-8 互相冒充」，
  Big5 追加为候选后不再被误判成 GB18030。
- **GBK 只有合成覆盖**：`Tests/e2e/cases/contract/lcf_probe.swift:237` 的 L17 现场 `encode("药水", .gb18030)`
  造字节再判，断言名本身写着「仅合成覆盖，仓库无汉化 `.ldb`」；`LCFTextCodec.swift:45` 有同样的注释。
  探针落盘产物 `/tmp/lcf-probe/out/test_gbk.ldb`（1,998 B）只是这次跑出来的，**不是仓库资产**，随时可重生成。
- **Shift-JIS 与 Big5 有真实样本**：EasyRPG/TestGame（CP932）与两份繁体工程（2026-11-02 判据修复
  `27a40cb` 时真机验证，Chi-Hsin/reversestone 2419/2528 判 Big5、RenaWevin/MyFireDragon 315/320）。

### 残留风险

- **首次遇到真实 GBK 工程时仍可能暴露新问题**。真实汉化 `.ldb` 里常见**混排**：汉化组改过的字段是 GBK，
  没改的字段还是 Shift-JIS 原日文。判据目前只在「整段同一编码」的合成字节上验证过，混排没有样本可测。
- **短字段误判风险更高**。Big5 实测里已有 104 条「两种解码都像人话」的平局（如 龐斯/胑吹），
  汉字人名 2–4 字时同样可能平局，GBK 侧没有任何真实数据来估这个概率。
- 因此**不得对外宣称「已覆盖简体汉化版」**；正确说法是「GBK 判据已实现，仅有合成样本验证」。

### 重开条件

出现一份**带 OSI/CC 许可的简体中文 RM2k/2k3 工程**（含 `.ldb`），或自建一份可入库的原创简体工程并附许可。
只有「无许可的下载链接」不算重开依据。

---

<a id="L2"></a>
## L2 mkxp-z 设置菜单（F1 Keybindings）

**状态**：**已解决（2026-11-02）** —— 许可证与首启组件就位后，用真 `ibtool` 重建，F1 设置菜单实测可用

### 结论（2026-11-02 实测）

用户在本机执行了两条管理员命令（顺序不能反）：

```bash
sudo xcodebuild -license accept      # 1) 先接受 Xcode 许可证
sudo xcodebuild -runFirstLaunch      # 2) 再安装首次启动组件
```

之后 `xcodebuild -license check` / `-checkFirstLaunchStatus` 都是 **0**，
`xcrun --find ibtool` → `/Applications/Xcode.app/Contents/Developer/usr/bin/ibtool`，
`ibtool --version` → **27.2（bundle 25408）**。

用**全新的** meson builddir 重建（旧 builddir 里 `find_program('ibtool')` 已固化成假桩路径，
增量构建会继续产出桩，必须重新 setup）：

| 项 | 值 |
| --- | --- |
| `strings <产物> \| grep -c FAKE-NIB` | **0** |
| `builddir/macos/views/settingsmenu.nib` | 51.9 KB 的 `NIBArchive`（桩版本是 8 B） |
| 未 strip 产物 | 42,387,520 B |
| strip 后分发 | **35,513,696 B**（比桩版本 35,448,032 B 多 65,664 B，差值就是嵌入的真 nib） |
| 符号数（`nm -a`） | 1,929（与桩版本相同） |

**构建参数有一处必须补**：标准参数组要带 `-Dcjk_fallback_font=true`。
`mochibox-macos-fixes.patch` 把 `src/display/font.cpp` 改成无条件
`#include "wqymicrohei.ttf.xxd"`，而这个 xxd 只在 `cjk_fallback_font=true` 时才由
`assets/meson.build` 生成。漏掉它会在 `font.cpp:49` 报
`fatal error: 'wqymicrohei.ttf.xxd' file not found`。旧 builddir 里残留着这个文件，
所以历史构建看不出缺口。

### 验收证据：F1 + 截屏 + OCR

以 `/tmp/vx-run`（VX 测试工程）为 cwd 启动新二进制，按 **F1**（`SDL_SCANCODE_F1`，
CGKeyCode 122）后，`CGWindowListCopyWindowInfo` 里出现了第二个窗口：

```text
id=7704 pid=16858 owner=mkxp-z name=Keybindings bounds=702x339
id=7699 pid=16858 owner=mkxp-z name=VX Test      bounds=544x448
```

`screencapture -x -o -l7704` 抓帧后用 Vision（`VNRecognizeTextRequest`）OCR，54 行，节选：

```text
Keybindings
Select a binding. Click an empty slot to bind an action, and click a full slot to remove the binding.
Action   Binding 1   Binding 2   Binding 3    Binding 4
Down     Down        Pad Down    LStick Y+
Left     Left        Pad Left    LStick X-
Right    Right       Pad Right   LStick X+
Up       Up          Pad Up      LStick Y-
A        Shift       Pad X
B        Escape      Keypad 0    X            Pad B
C        Space       Return      Z            Pad A
X        A           Pad Y
Y        S           Pad LS
Z        D           Pad RS
L        Q           Pad LB
R        W           Pad RB
Accept   Cancel      Reset to Default
```

窗口标题、说明文字、四列绑定表、三个按钮全部渲染出来 —— 不是"nib 不是假桩"的间接推断，
而是 F1 真的把设置界面弹了出来。

### 历史依据（修复前复核，命令 + 退出码）

```text
$ xcodebuild -version
Xcode 27.2
Build version 27B52

$ xcodebuild -license check ; echo $?
You have not agreed to the Xcode license agreements. Please run
'sudo xcodebuild -license' from within a Terminal window to review and agree
to the Xcode and Apple SDKs license.
69                                  # 许可证未接受

$ xcodebuild -checkFirstLaunchStatus ; echo $?
69                                  # 首次启动组件未安装

$ ls /Library/Developer
CommandLineTools/                   # 只有 CLT，Xcode 的首次启动内容没装进来

$ xcrun --find ibtool ; echo $?
You have not agreed to the Xcode license agreements. …
69                                  # 走 xcrun，撞许可证

$ /Applications/Xcode.app/Contents/Developer/usr/bin/ibtool --version ; echo $?
A required plugin failed to load. Please ensure system content is up-to-date
— try running 'xcodebuild -runFirstLaunch'.
ibtoold failed IDE initialization: Loading a plug-in failed.
255                                 # 绕开 xcrun 直调，撞"插件没装"

$ sudo -n true ; echo $?
sudo: a password is required
1                                   # 非交互 sudo 不可用

$ ls -ld /Library/Preferences
drwxr-xr-x  root  wheel              # 755：组不可写
$ id -Gn                             # … admin …
                                     # 用户在 admin 组，但该组对这层目录没有写权限
```

**当时的结论**：这台机器上 `ibtool` 两条路都不通 —— `xcrun` 侧卡许可证（69），
直调真身卡插件加载（255）。**不是「没装 Xcode」**，而是**装了 Xcode 27.2（27B52）、
许可证未接受、首次启动组件未安装**。两条修复命令都要 root，而本机 `sudo -n` 直接失败
（需要密码），脚本里不能替用户执行，也不能靠降权绕过。

早先「本机只有 Command Line Tools，`/usr/bin/ibtool` 是桩」的记录已被本轮观测取代，
以本节命令输出为准。

**同源的副作用（已另行修复）**：许可证拦的不是 `ibtool` 一个，而是 `/usr/bin` 下整批
Xcode shim —— `swiftc`、`clang++`、`git`、`xcrun`、`python3` 全部返回退出码 69 与同一句
license 提示。工具链**真身**（`<Developer>/Toolchains/…`、`<Developer>/usr/bin/`）不受影响，
所以 E2E 与构建脚本已改为「优先 xcrun，失败回退真身并补 `-sdk`/`-target`/`-isysroot`」
（`Tests/e2e/lib/toolchain.mjs`、`Scripts/build.sh`、`Scripts/build-liblcf.sh`）。
那条改动只影响**怎么找到编译器**，与本节的 `ibtool` 无关 —— `ibtool` 没有可用的真身替换。

### 历史：修复前的现象

构建走**假 `ibtool` 桩**：`macos/views/meson.build` 的 `custom_target` 把 `settingsmenu.xib` 编成
`settingsmenu.nib`，桩只写出 8 字节 `FAKE-NIB`。运行时 `SettingsMenuController.mm` 用
`[[NSNib alloc] initWithNibData:…]` 加载这 8 字节，返回 nil 后抛
`could not load settingsmenu.nib`（`NSInternalInconsistencyException`）。

具体到功能面：

- **不可用**：运行中按 **F1** 想打开 Keybindings 窗口 —— 这是唯一受影响的入口；
- **不受影响**：游戏启动、渲染、输入、事件解释器、文本通道（RGSS hook）、存档。
  我们的启动路径不经过设置菜单（`GameLauncher` 注入的 `mkxp.json` 不含键位配置）。

### 历史：本机是怎么修的（保留供其它机器复现）

**第一条路（本机走通了，需要用户手工执行两条命令，顺序不能反）**：

```bash
sudo xcodebuild -license accept     # 1) 先接受 Xcode 许可证
sudo xcodebuild -runFirstLaunch     # 2) 再安装首次启动组件
```

**顺序不能反**：许可证没接受时，`xcodebuild -runFirstLaunch` 自己也会被拦，
只打印 `You have not agreed to the Xcode license agreements`；先 accept 之后它才会真正去装组件。

两条都成功后先自检，三条都要有输出：

```bash
xcodebuild -checkFirstLaunchStatus ; echo $?   # 期望 0
xcrun --find ibtool                            # 期望打印路径
ibtool --version                               # 期望打印版本号
```

然后**重建** mkxp-z 并重新入库：

```bash
# 必须用**全新 builddir**：find_program('ibtool') 的结果已固化进 build.ninja，
# 旧 builddir 增量构建会继续用假桩路径，nib 还是 8 字节 FAKE-NIB。
# --reconfigure 也不够保险，只在删掉 builddir/macos/views/settingsmenu.nib* 后才可能生效。
rm -rf <builddir> && meson setup <builddir> <src> --buildtype=release \
  -Dworkdir_current=true -Dcjk_fallback_font=true \
  -Diconv_system=enabled -Dwrap_mode=forcefallback \
  -Dc_args=-mmacosx-version-min=13.0 -Dcpp_args=-mmacosx-version-min=13.0 \
  -Dobjcpp_args=-mmacosx-version-min=13.0 -Dc_link_args=-mmacosx-version-min=13.0 \
  -Dcpp_link_args=-mmacosx-version-min=13.0 -Dobjcpp_link_args=-mmacosx-version-min=13.0
ninja -C <builddir>
strings <builddir>/mkxp-z.aarch64 | grep -c FAKE-NIB   # 必须是 0
bash Scripts/fetch-mkxpz.sh --force          # 重新拷贝 + strip + ad-hoc 重签
bash Scripts/build.sh                        # 重新打包 .app
```

`-Dcjk_fallback_font=true` 不能漏（原因见本节开头）；`Scripts/fetch-mkxpz.sh` 会在
`MKXPZ_BINARY` 指向的产物旁读 `meson-info/intro-buildoptions.json`，只核对
`workdir_current`，不会替你发现漏掉的字体选项。

`--force` 不能省：`fetch-mkxpz.sh` 在 `vendor/runtime/mkxp-z` 已存在且 sha256 与记录一致时
会直接跳过拷贝，不加它拿到的还是旧二进制。重建后 F1 设置菜单可用。

**第二条路（根治，换到任何机器都有效）**：在一台 `ibtool --version` 能打印版本号的机器上
生成一次 `settingsmenu.nib` 并入库，把 `macos/views/meson.build` 里那个 `custom_target` 换成
`copy`——这样只有 CLT 的机器也能编出带可用设置菜单的二进制，不再依赖现场的 `ibtool`。
详细步骤见 [`vendor/mkxpz/BUILD.md`](../vendor/mkxpz/BUILD.md) 的「有真 Xcode 时怎么让设置菜单可用」。

---

<a id="L3"></a>
## L3 Ruby 3.2+

**状态**：已关闭 —— 上游约束

### 依据

- 上游 pin 在 `f02d586`（版本 `2.4.2`）。它的 `meson_options.txt` 里 Ruby 只有一项
  `mri_version`（默认 `3.1`），`subprojects/` 下也只有 `ruby-3.1.wrap` 这一个 Ruby wrap，
  且指向 `https://github.com/ruby/ruby/archive/refs/tags/v3_1_3.tar.gz`。
- 该 wrap 的 `patch_directory = ruby-3.1`，带 **28 个 `ruby-3.1-*.patch`**，是为 3.1 源码写的；
  换 3.2 要重做这一整套，属上游工作量，不是改个版本号。
- 产物内嵌版本可自查：
  ```text
  $ grep -a -o 'ruby 3\.[0-9]*\.[0-9]*p[0-9]*' vendor/runtime/mkxp-z | sort -u
  ruby 3.1.3p185
  ```
- 我们自己的 `vendor/mkxpz/mochibox-macos-fixes.patch` 只动 `src/display/font.cpp`、
  `src/filesystem/filesystem.cpp`、`src/filesystem/filesystemImplApple.mm`，**不涉及 Ruby**，
  所以升级的阻力完全来自上游 wrap。

### 影响

Ruby 3.1.3 已能跑通三个版本的默认脚本集：VX 相对官方 EN 默认集 **94/95 段逐字节一致**
（`Game_Interpreter` 差 2 行社区修补），XP / VX Ace 的跑通记录见
[`rpgmaker-runtime-verification.md`](rpgmaker-runtime-verification.md)。
升级到 3.2+ 的收益不明确（默认脚本用不到新语法），风险却是整套 patch 重做 + 三版回归重跑；
**老 RGSS 的 1.8 语义风险已对默认脚本集实测消解，第三方 / 商业脚本仍未验证**，那部分不会因为换 Ruby 版本自动变好。

### 重开条件

上游发布 3.2+ 的 wrap 与对应 patch（我们只做集成验证），或者我们决定承担移植成本——
届时必须先给出「默认脚本三版仍逐字节一致」的回归证据，否则不换。

---

<a id="L4"></a>
## L4 RGSS 启动预译的覆盖边界

**状态**：已知边界 —— 已实现，非缺陷

### 依据

- `Sources/Domain/RGSSPrewarm.swift` 只读扫描 `Data/` 的 `System` / `CommonEvents` / `Map*`（`prewarmIncludeTroops`
  时加 `Troops`）与数据库字段；事件指令只取白名单 `101[0]`（仅 XP）、`401[0]`、`405[0]`、`102[0][*]`，
  `101[1]` 是头像文件名（VX / VX Ace 的 `101[0]` 也是），一律不进缓存。
- 脚本里拼接的文本、`\N[1]` / `\V[1]` 代入后才成形的文本、以及运行后改写的数据不在扫描范围：
  静态读取 Marshal 拿不到运行期值。
- XP 的 101 + 后续 401 **以及 102 选项**必须按整段 `+ "\n"` 累积（带尾随换行）才有与运行时相同的
  cacheKey；`join("\n")` 会少尾随换行、漏选项，必然 miss。VX / VX Ace 逐行 —— 两者分别对应 hook 的
  请求粒度，不能统一成一种。
- **时序边界**：预译在启动后异步跑，autorun 型工程（启动即弹对话）在 1s 内就显示首句，通常来不及入缓存；
  标题画面型工程有数秒余量。这是网络往返量级的固有限制，不是接线缺陷（缓存命中率与后续对话不受影响）。
  实测对照：同一新缓存目录 + 同一工程，加 6s 启动延迟后首句 `source=hit`（预译 40ms 扫描 + 首批往返完成于显示前），
  无延迟时首句仍是 `TIMEOUT -> PENDING`（`docs/rgss-text-channel.md` §10 证据 ④）。

### 影响

- 未覆盖的句子首次显示仍是原文，下一次显示命中缓存后才是中文（与未做预译时一致）；
- 预译失败、超时、关闭或后端未配置时只降级为运行时翻译，启动耗时与首句行为不变，不改变会话状态；
- 纯数字 / 纯符号 / 已中文 / 过短 / 资源文件名不进候选（SkipRules + 白名单），缓存不会被污染。

### 重开条件

- 要覆盖动态文本，只能在 hook 侧“显示前等待”（会阻塞游戏主线程，当前 120ms 上限下不可行），
  或由用户手动跑全文翻译；两者都不属于“预译”的范围，不随本次实现变化。
