<div align="center">
  <img src="Design/mochibox-icon/Mochibox.iconset/icon_128x128@2x.png" width="112" alt="MochiBox">
  <h1>MochiBox</h1>
  <p><strong>拖进去，就能用中文玩。</strong></p>
  <p>macOS 上的 RPG Maker 游戏翻译与修改工具<br>
  实时翻译 · 全文汉化 · 术语统一 · 顺手改档</p>
  <p>不改动游戏文件 · 不需要 Wine · 不需要转区 · 数据只留在本机</p>

  ![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
  ![RPG Maker MV / MZ](https://img.shields.io/badge/RPG%20Maker-MV%20%7C%20MZ-8a63d2)
  ![License AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)

  **简体中文** | [English](README.en.md)
</div>

---

## 这是什么

MochiBox 给日文 RPG Maker 游戏加上中文：把游戏目录（或 `.app`）拖进窗口，选一个翻译后端，
点「启动」——对话、菜单、道具说明、战斗播报在渲染出来的那一刻就是中文，不用切窗口复制粘贴，
也不用等整包汉化补丁。

翻译发生在**画字这一层**。MochiBox 把游戏页面装进自己的内核窗口，注入一小段脚本，
在引擎调用绘制函数的那一刻拦下原文、换成译文，再交回原来的函数去画。所以：

- 游戏读到的脚本、素材、存档都是原样，**磁盘上的文件一个字节都不动**；
- 译文**按句缓存**，同一句话第二次出现不再请求后端；
- 直通模式下**完全不发网络请求**，断网也能玩。

它不是汉化补丁，也不是贴在画面上的悬浮字幕：因为钩的是引擎自己的绘制接口，菜单、
状态栏、战斗日志这些「运行时才拼出来」的文本同样能覆盖。

## 能做什么

### 实时翻译

游戏跑起来就翻。对话、系统提示、道具/技能说明、菜单选项、战斗播报都在绘制时替换，
不需要重启游戏，也不需要重开存档。

- 译文按句缓存，重复出现的句子零请求；
- 数字、`%1` 占位符、控制码照原样保留；段数对不上时宁可画原文，也不画错位的译文；
- 遇到的句子逐条列在「翻译流」里，可回看原文与译文。

### 全文翻译

想一口气翻完整个游戏、之后离线玩时，切到「全文」：

1. 扫描 `$data*`、每张地图和运行时见过的文本，按源文去重；
2. 分批送给后端，进度与失败项逐条可见；
3. 结果按游戏持久化，可导出，也可以回写进运行中的游戏。

全文翻译是**显式发起的事前批量处理**，不改变实时链路的行为。

### 术语表

人名、地名、技能名、系统术语一旦翻错，满屏都别扭。所以全文翻译不再把「专有名词」和
「对话描述」塞进同一条提示词：

- **锁定映射**：内置常用系统术语种子表，加上每款游戏自己的术语表；整串命中直接写回，不请求模型；
- **分类提示**：先翻系统术语与名称，翻完立即学进术语表，后面的描述和对话自动带上；
- **译后校验**：占位符丢失、残留假名、译文与原文相同、术语没遵循、长度异常，逐条标记，
  可在「语料」页按「只看质量问题」筛选；
- 术语可在「术语」页编辑、增删、导入导出，也能「按术语重翻」（只清机翻，人工改动不动）。

### 修改器

同一套通道顺手做成了修改器：金钱、物品、角色属性与等级、开关、变量、遇敌开关、
移动速度、坐标传送（带传送点列表）、字号缩放。改的是**运行中的内存**，不动存档文件；
危险操作（全开/全关开关之类）会先弹确认。

### 数据回写（可选）

角色名、状态播报这类「运行时拼出来」的句子没有整串可查，可以把译文写回 `$data*` 的名字字段。
这会动到插件也可能读的字段，所以给了两级开关：关掉名字类只保留播报文本，关掉总开关整块不写，
已写入的全部还原。

### 内嵌内核 · 零 Wine

RPG Maker 的 Windows 发行版本质是「一个静态网站 + 一个外壳」：`index.html` + `js/` + `data/`。
MochiBox 只做两件事——把目录**只读**托管在回环地址上，再用内置的 WebKit 窗口打开它。
**不装 Wine，也不执行 `Game.exe`**，Mac 版与 Windows 版走的是同一条路。

- 默认路径不拉起任何外部浏览器，Dock 里不会冒出 Chrome 图标；
- 关窗或点「停止」立刻收摊：取消翻译、关窗口、停服务、释放端口；
- 静态端口对同一款游戏**确定性派生**——端口一变，浏览器存档所在的 origin 就变，
  存档等于凭空消失，所以端口按游戏固定分配并记录下来。

### 本地优先

- 没有遥测（`telemetryEnabled` 恒为 `false`，且没有实现）；
- 设置、缓存、日志都在 `~/Library/Application Support/MochiBox/`，API Key 以 `0600` 落盘；
- 只有**文本片段**会发给你自己配置的翻译后端，游戏素材与存档不出本机。

## 三步开始

1. **配后端**：设置 → 翻译后端，选 OpenAI 兼容（填 endpoint / 模型 / Key）、DeepL（填 Key），
   或「直通」——直通不翻译也不联网，适合先确认游戏能正常跑。
2. **加游戏**：把游戏文件夹（或 `.app`）拖进窗口，或点「+」选择；识别到引擎后会进入游戏库。
3. **点启动**：右侧「翻译流」开始滚动就是接通了。连上之后「作弊」「全文」两页才会加载数据。

> 首次打开若被 Gatekeeper 拦下，见下面的常见问题。

## 支持范围

| 项 | 说明 |
|---|---|
| 平台 | macOS 13 及以上，构建产物为 Apple Silicon（arm64） |
| 引擎 | **RPG Maker MV / MZ** 可启动；XP / VX / VX Ace / 2000、Wolf、Ren'Py、吉里吉里、TyranoBuilder、Unity、Godot、Siglus 仅识别，不能起会话 |
| 发行版 | Windows 版（无需 Wine）、macOS 版 |
| 语言 | 日本語 → 简体中文（固定，设置页只读） |
| 翻译后端 | OpenAI 兼容 / DeepL / 直通（离线） |

## 常见问题

**打开时提示「已损坏，应移到废纸篓」或「无法验证开发者」？**

产物是 ad-hoc 签名、未公证的 `.app`，这就是未公证的正常表现，不是文件坏了。两种放行方式：
Finder 里右键 → 打开 → 再点「打开」（只需一次）；或

```bash
xattr -dr com.apple.quarantine /path/to/MochiBox.app
open /path/to/MochiBox.app
```

**会把我的游戏上传出去吗？**

不会。游戏目录只在本机以只读方式托管给内置窗口，发给后端的只有待翻译的文本片段。

**会改我的存档吗？**

不改存档文件。存档仍在游戏自己的浏览器存储里，按游戏隔离；MochiBox 只保证端口稳定，
让同一个 origin 一直指向同一份存档。

**刚进游戏怎么一直没有译文？**

采集只在引擎真的画文本时发生。有的作品开场先播一段影片，播完才进标题，
在那之前画面上没有任何可翻的字。影片、CG、纯图 UI 期间同理。

**中文显示成方块或缺字？**

默认用系统苹方渲染游戏文本，也可以在设置里换成本机已安装的字体。个别作品把文字预渲染成图片，
这类文本无法替换。

**想临时看回日文？**

游戏自带中文时 MochiBox 会自动跳过翻译；也可以把后端切成「直通」，或直接关掉翻译。

**能上架 Mac App Store 吗？**

不能，也不打算。核心功能是启动第三方程序并驱动其调试端口，而且需要用户自备 API Key。

## 从源码构建

只依赖 **Command Line Tools**（不需要 Xcode、不需要 SwiftPM / CocoaPods，运行期零第三方依赖）：

```bash
bash Scripts/build.sh
# 产物：build/MochiBox.app（ad-hoc 签名）
```

<details>
<summary>构建门禁、自检与可选的媒体工具链</summary>

`build.sh` 先跑一次 **UI 依赖门禁**：核心层（`Sources/Domain`、`Sources/Adapters`、`Sources/Infra`、
`Sources/SelfTest` 及 `Sources/App` 的部分文件）一旦出现 `import SwiftUI` / `import AppKit`
就以退出码 2 失败。这是 `--selftest` 能在无图形会话（SSH）下运行的结构性保证。

```bash
./build/MochiBox.app/Contents/MacOS/MochiBox --help       # 按模式分组的用法与退出码
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest   # 内建自检
```

带 alpha 的视频素材需要一次转码工具（可选，产物不入库）：WebKit 在解析层就丢掉 VP9 的 alpha 平面，
带透明的 `.webm/.mpon` 要先转成 HEVC-with-alpha 才能保住透明。根因与实测见
`docs/media-compat-vp9-alpha.md`。

```bash
bash Scripts/build-ffmpeg.sh    # 首次会下载源码并编译，产物在 vendor/media/ffmpeg
bash Scripts/build.sh           # 存在就一并打包；不存在则转码层自动停用，按原始字节服务素材
```

</details>

## 已知限制

- **不声称支持所有 MV/MZ 作品**：真机验证覆盖的是少量商业作品，其余属未验证范围；
  兼容问题通常出在插件改写了绘制逻辑、文字被预渲染成图片、或字体缺字。
- 语言对固定为日本語 → 简体中文。
- 实时链路不做离线预翻译，第一句译文要等后端往返；想彻底离线请先用全文翻译。
- 采集只发生在「引擎画字」这一刻：影片、CG、纯图 UI 期间天然没有可翻文本。
- 术语约束对 OpenAI 兼容后端是硬约束；DeepL 没有 system prompt，只能放进 `context`，属尽力而为。
- 运行期只有被扫描过的句子能拿到正确类别，没扫过的一律按「对话」处理。
- 术语保存的瞬间，已经在飞的旧结果可能晚到并覆盖一次，下一次重绘自愈。
- `System.terms.messages` 是带 `%1` 的模板句，运行时画的是代入后的实例，模板译文不会命中。

## 开发与文档

开发向内容都在 `docs/`，索引见 [docs/README.md](docs/README.md)：

```text
Sources/     Swift 源码：App / Domain / Adapters / Infra / UI / SelfTest
Resources/   agent_mvmz.js —— 注入游戏的 Agent 脚本（唯一运行时资源）
Scripts/     build.sh（唯一构建入口）、Info.plist、build-ffmpeg.sh
Tests/       e2e 分层测试入口（见 docs/testing.md）与 QA 探针
Fixtures/    合成替身：mock 翻译后端、mv_stub 测试页
Design/      应用图标源文件
docs/        架构 / 验收 / QA / 交接
```

入库的只有代码、测试、文档与构建脚本；构建产物、解包素材、实测游戏全部在 `.gitignore` 里。

<details>
<summary>测试分层</summary>

```bash
bash Tests/e2e/run.sh --suite contract   # 协议层：零 GUI、零网络
bash Tests/e2e/run.sh --suite domain     # 领域层：持久化 / 脱敏 / 日志 / 韧性 / 缓存 / 全文
bash Tests/e2e/run.sh --suite kernel     # 内核层：内置 WKWebView + 确定性夹具
bash Tests/e2e/run.sh --suite faults     # 故障层：401 / 429 / 500 / 非 JSON / 端口占用
bash Tests/e2e/run.sh --suite all        # 依次全跑
```

无图形桌面（SSH / CI）时 kernel / faults 会显式 SKIP 而不是失败。
完整模型、夹具与断言纪律见 `docs/testing.md`，当前态 QA 结果见 `docs/qa-report.md`。

</details>

## 特别鸣谢

- **[MTool](https://mtool.app/)** —— 感谢 MTool 项目在 RPG Maker 游戏翻译与修改上的开拓，
  本项目的功能设想、交互组织与兼容性认识都从中受益良多。

## 许可证

**GNU Affero General Public License v3.0**（AGPL-3.0），见 [LICENSE](LICENSE)。

可以自由使用、修改、分发；修改后的版本须同样以 AGPL-3.0 开源，
若作为网络服务提供给他人，也须提供对应源代码。

## 声明

MochiBox 是独立实现，不含任何游戏、引擎或其厂商的代码与素材。
它读取**你自己的**本地游戏目录，只把待翻译的文本片段发送到**你自己配置**的翻译后端。
请勿用它再分发游戏素材，或绕过任何授权与保护措施。
