# MTool 逆向分析 · 证据档案（工作稿）

> 分析对象：`MTool.zip`（Windows 客户端）、`mtool_v55_24.apk`（Android 主程序）、
> `mtool_mkxpz_v65_1.apk`、`mtool_renpy_v59_1.apk`、`mtool_easyrpg_v10000_1.apk`、
> `winlator_v3.1.71_1.apk`
> 方法：纯静态分析（ZIP 结构、PE 导入/字符串、V8 字节码字符串、AXML 字符串池、JSON 资源）。
> **未进行动态运行**（本机无 Windows/Android 运行环境）。凡属推断一律标注。

---

## 0. 一句话结论

MTool 不是一个"翻译器"，而是一个**游戏进程内注入框架 + 文本总线 + 翻译/渲染管线**：

```
宿主 UI（同一套 Web 应用）──WebSocket/命名管道──▶ 注入到游戏进程里的 Agent
                                                     │  eval 引擎脚本 / 拦截绘制文本
                                                     ▼
                                              游戏引擎（Ruby / JS / Python / TJS / .NET）
```

翻译只是"Agent 拦到文本 → 回传宿主 → 宿主查缓存/调翻译 → 把译文回灌绘制函数"的一条业务流。

---

## 1. 客户端是一个 NW.js 应用（不是 Electron）

证据 `MTool/Tool/package.json`：

```json
{ "name": "MToolClient_1792427847226198052270",
  "main": "www/index.html",
  "js-flags": "--expose-gc",
  "chromium-args": "--disable-web-security --enable-node-worker",
  "window": { "title": "MTool", "frame": false, "min_width": 1000, ... },
  "dependencies": { "legacy-encoding": "^3.0.0", "pe-library": "^0.3.0",
                    "resedit": "^1.6.0", "ws": "^7.5.2" } }
```

- 同目录存在 `nw.exe` / `nw.dll`(195MB) / `node.dll` / `icudtl.dat` / `v8_context_snapshot.bin`
  → 典型 NW.js 运行时。
- 依赖的含义很明确：
  - `ws` → 本地 WebSocket 服务端/客户端（宿主 ↔ Agent 总线）。
  - `legacy-encoding` → 处理 Shift-JIS / GBK 等老游戏文本编码。
  - `pe-library` + `resedit` → **直接改写 PE 文件**（导入表/资源），用于注入器与"容器分离启动"。
- `chromium-args: --disable-web-security` → 允许页面跨域访问本地服务。

## 2. 主逻辑被两层保护

`www/loader.js`（31KB，未混淆但压缩）里的两条加载路径：

1. NW.js 原生二进制字节码：
   ```js
   nodeRequire('nw.gui')['Window']['get']()['evalNWBin'](null, fsMod()['readFileSync'](nwBinPath));
   // nwBinPath = 'www/loader.bin.' + process.versions.nw
   ```
   产物 `www/loader.bin.0.67.2`（7.5MB）。**与 NW.js 版本强绑定**，版本不符即 `handleCoreOutdated()`。
2. 自定义字节码容器：
   ```js
   fetch('loader.bin.ff').then(async r => new MToolExt().ExecuteBytecodeArrayBuffer(await r.arrayBuffer()))
   ```
   `loader.bin.ff` 26MB，头部 `11 00 00 00` + 构建时间戳 `20260331040122-8l` + 若干哈希，
   之后是按名字索引的段（如 `gc_0x4d6d91`）。由原生扩展 `MToolExt` 执行。

另有 `www/data/` 下 **216 个数字命名模块（合计 11.2MB）**，熵 6.8~7.6。
对其中一个样本做过重复密钥 XOR 穷举（密钥长 1~64），可打印率无改善
→ 非短周期异或，判定为流式/分组加密。**结论：核心业务 JS 不可静态读取（负结果，已穷尽尝试）。**

附带发现：`loader.js` 自带增量更新器，按 `updateCRC` 请求
`https://apk.mtool.app/releases/MTool_<CRC>.zip`，分块下载可续传（`.mtupd/attempt.json`、`pendingDelete.json`）。

## 3. 注入层：每个引擎一个 DLL

`Tool/loaders/` 目录是整套方案的技术核心。按引擎列：

| 引擎 | 注入件 | 证据（字符串/导出） | 注入点 |
|---|---|---|---|
| RPG Maker XP/VX/VX Ace（RGSS） | `RGSSHook.dll` / `RGSSHook64.dll` | `rb_eval_string`、`rb_str_new_cstr`、`rb_thread_call_without_gvl`、`rb_define_global_function`、`RGSSEval`、`RGSSGetStringUTF8` | 进程内 Ruby VM |
| RPG Maker MV/MZ（NW.js） | `mzHook.dll` / `mzHook32.dll` | `if(typeof process === 'undefined'){MTool_CWD = \`…`、`mtoolenv` | 游戏页面 JS 上下文 |
| Ren'Py | `PythonHook.dll` / `PythonHook64.dll` | CPython C-API：`PyGILState_Ensure`、`PyImport_AddModule`、`PyObject_Str`；内嵌 Python 源码含 `callMToolTrs`、`callMToolServer`、`MtoolErr_ptracebackList = traceback.format_exception(...)` | 进程内 CPython |
| 吉里吉里 (KiriKiri 2 / KAG3 / krkrz) | `krkr2Hook.dll`、`krkrzHook32/64.dll` | C++ RTTI：`mtool_kag@@`、`NI_Mtool`（TJS2 命名接口）、`CloneTagObjectShallow` | TJS2 插件/命名接口 |
| SiglusEngine | `SRPGHook.dll` | COM/ATL：`CMToolATLCOMModule`、`IATLGraphicsManager`、`IATLStoryPreference`、`MToolSimpleObject` | COM 对象替换 |
| WOLF RPG Editor | `wolfHook1/3.dll`、`wolfHook.dll` | `.\Save_MTool\`、`Mtool_Dummy` | 插件 DLL + 存档旁路 |
| Unity / .NET | `MonoJunkiex86/64.dll` + `0Harmony.dll` | Harmony 运行时打补丁 | Mono 方法级 Hook |
| Godot | `GodotHook.dll`、`GodotHook_3_0_0.dll`、`GodotHook_4_2_0.dll` | 按引擎版本分档 | GDScript/场景层 |
| Pixel Game Maker MV | `AgtkHook.dll`、`mtool_PGMMV_font.ttf` | 需专用字体 | 引擎插件 |
| RPG Developer Bakin | `BakinLauncher.exe`、`BakinPlayerWrapper.exe` | 包装启动器 | 启动链替换 |
| TyranoBuilder | 复用 NW.js 路径（`mzHook`） | — | 页面 JS |

辅助件：`PidFinder.exe`、`PIDDLLInject64.exe`、`inject.bin`(941KB)、`ele64.exe`、`editbin/editbin.exe`、`editbin/link.exe`、`fontSetting.exe`、`CPUInstructionCheck.exe`、`JRubyFX.jar`。

## 4. 通信协议：本地 WebSocket + 可选命名管道

DLL 中提取到的协议字符串（多个 Hook 一致）：

```
ws://127.0.0.1:<port>
mtool-native/1.0          ← 握手标识 / User-Agent
mtoolsocket2              ← 通道标识
okmtool                   ← 握手成功应答
callMtoolServer / callMToolServer      ← 通用命令入口
doMToolEvals / callMToolTrs            ← 求值 / 翻译入口
only ws:// URIs are supported for native raw socket transport
WaitNamedPipeW / PeekNamedPipe / broken pipe   ← 命名管道回退
```

游戏内 Agent 是 V8 字节码（bytenode 风格，魔数 `C0DE04F5`）：
`loaders/Client.js.arm64`、`loaders/Server.js.arm64`。
从中提取到的符号说明其职责：

```
CmdMessageCtor / RetMessageCtor        ← 请求/应答消息模型
sendCmd / replyCmd / hasCmd / sentCmd
vmeval / evalr / evalNoSerialize / runInThisContext   ← 在游戏 VM 内执行代码
dispatchKeyEv                          ← 向游戏注入按键
/wslikecmd / /contextmenu / wslikecmdUrl
TextEncoder / TextDecoder / path / crc32 / zlib / WebSocket / gameCWD
```

→ **宿主拥有任意代码执行能力**（在游戏 VM 内），这是"改金币/解锁道具/改字体"等功能的基础。

## 5. 注入方式有 4 种（来自客户端自带的多语言 UI 文案）

`www/rawres/LangTL.json`（3.7MB，19 种语言，每语言 1405 个 UI 键）里，同一批键在不同语言下语义一致：

- `injectAtOEP` = 主动注入：由 `loaders\inject.exe` 启动游戏并注入（`injectAtOEPHint`）。
- `lazyInject` = 被动注入：把 `winmm.dll` 或 `version.dll` **写进游戏目录**，游戏启动时按 DLL 搜索顺序被加载 → 经典 DLL 劫持（`lazyInjectHint`）。
- `injectContainer` = 容器分离启动。
- `injectOnTheFly` = 注入运行中的游戏（`injectOnTheFlyHint`：支持 MV/MZ/XP/Vx/VxAce、TyranoBuilder、Ren'Py）。
- `makeLaunchBat` = 生成"和工具一起启动.bat"。

被动注入的实体证据在 `loaders/loaderDLL/` 下：`wm32`(274KB)、`wm64`(325KB)、`ver32`(250KB)、`ver64`(305KB)
——命名即 `winmm.dll` / `version.dll` 的替身。它们不是明文 PE（`file` 判为 `data`，熵 5.42–5.43），
文件头为 `57 57 55 50 50 44 4f 40 50 44 43 44 50 44 43 40 …`，尾部呈 `50 44 43 40` 周期性重复
（典型的"长零区 + 定长密钥混淆"特征）。
→ 载体以混淆态随包分发，运行时才还原成可被系统加载的 DLL 写进游戏目录（这也解释了 UI 里
`injectMakeFaild` 提到的"膨胀 inject.exe 以回避杀毒软件"）。

## 6. 文本与字体管线（决定译文能否"塞得进"原 UI）

UI 键即功能清单：`fontScale`、`fontSizePercentScale`、`fontKerning`、`fontOutlineCrop`、
`fontHeightReporting`、`fontHinting`、`fixGameFont`（= 文字化け修正）、`cantUsePixelFont`
（位图字体不可用）、`fontNoLoaderCopyHint`（Ren'Py / Pixel Game Maker MV 需引擎专用字体）。

随包分发的字体：`mtool_renpy_font.ttf`（21MB，Ren'Py APK 内）、`mtool_PGMMV_font.ttf`、
`loaders/mtool_PGMMV_font.ttf`。→ **翻译=换字体+缩字号+调字距**，因为日文原 UI 的排版宽度装不下中文。

> **对本工具的结论**：MTool 走"自带字体文件"路线（Ren'Py / PGMMV 各有专用 `.ttf`），并推荐用户安装
> **Unifont Smooth**（备选 Arial Unicode MS / Sun-ExtA）；我们不分发字体文件（合规 + 体积），默认用系统
> **PingFang SC**，`gameFontFamily` 只在系统已装的族里选，且始终保留游戏自己的 `fontFace` 与回退链。

翻译数据侧：引擎名 `TrsNT`（默认，`defEngine`/`defEngineS` 均为 `TrsNT`），
变体 `TrsNT + 名詞 修正/同期`；自定义译文导入 `openTrsNDataInput`；
服务域 `trsdev.mtool.app`、`mtool.app`。

## 7. Android 版：同一套 Web UI，换宿主

`mtool_v55_24.apk`（247MB）解包结论：

- 包名 `app.mtool.mtoolmobile`（另有 `.mkxpz`、`.easyrpg` 变体）。
- 进程/组件：`:MTOOL_MainActivity`、`:MTOOL_MToolBackend`、`:MTOOL_GeckoCrashHandler`；
  服务 `app.mtool.vfs.FdRelayService`、`VfsFdProviderContentProvider`、`AuthTokenProvider`、`FileProvider`。
- 双浏览器内核并存：
  - `lib/content_shell_content_view.so` 169MB + `assets/content_shell.pak`（Chromium）
  - `libxul.so` 162MB + `libmozglue.so` / `libnss3.so`（GeckoView）+ `www/rawres/gecko_pref.yaml`
  - `libnode.so` 49MB（Node.js 运行时）
- **Web 资源与 PC 完全同源**：`assets/node/mtoolWebRoot/www/{loader.js,loader.bin.0.67.2,loader.bin.ff,data/*}`，
  连 `crcData` 都逐字节相同（63445 B）。→ 一套前端，两个宿主。
- 原生 Hook 库：`libbytehook.so`、`libshadowhook.so`（ARM64 inline hook）。
- `app.mtool.vfs.*` → 自建虚拟文件系统，把 Android SAF 目录映射给 Node/Gecko 侧
  （LangTL 里 `mobileSafCannotUseWinlatorHint` 说明该 VFS 目录 Winlator 访问不到）。

## 8. 移动端各引擎怎么跑：换引擎实现，而不是模拟器

| APK | 引擎载体 | 证据 |
|---|---|---|
| `mtool_mkxpz_v65_1.apk` | **mkxp-z**（开源 RGSS 重实现） | `libmkxp-z.so` / `libmkxp-z-187.so` / `libmkxp-z-193.so`、`libruby187.so`、`libruby193.so`、`libruby313.so`、`libSDL2*.so`、`assets/RTP/RGSS{,2,3}/…`（XP/VX/VXAce 全套 RTP） |
| `mtool_renpy_v59_1.apk` | **Ren'Py 官方 Android 运行时** | `assets/main.py`、`assets/runtime-pack.tar.zst` 132MB、`assets/mtool_renpy_font.ttf` 21MB、`libLive2DCubismCore.so` |
| `mtool_easyrpg_v10000_1.apk` | **EasyRPG Player**（RM2000/2003） | `libeasyrpg_android.so` 15.6MB、`libSDL3.so`、`assets/RTP_EasyRPG/2000/…` |
| `winlator_v3.1.71_1.apk` 1.1GB | **Wine + Box64 + XServer** | 用于吉里吉里/WOLF/Unity/Siglus 等纯 Windows 引擎 |

LangTL 里 Winlator 相关键（`winlatorProton9/10/11Container`、`winlatorMonoInstalling`、
`winlatorRGSSRequiresX64`、`winlatorRecommendedRuntime`）证明：
**Android 上对 Windows 独占引擎不做移植，而是跑原版 Windows 二进制 + 注入原版 Windows DLL。**

移动端能力边界也写在文案里：`moblieEngineNotSuooprtHint` =
"移动端暂仅支持 RPG Maker XP/Vx/VxAce/MV/MZ | TyranoBuilder | Ren'Py"。

## 9. 没有 macOS 支持（负结果）

- 全量 `loaders/*.dll|exe`、`www/*`、`Tool/*.dll` 扫描：无 `darwin` / `dylib` / `.app` / `NSApplication` 相关字符串；
  仅 `winmm.dll`/`version.dll`/`WaitNamedPipeW` 等 Win32 API。
- `www/rawres/apkvers/` 只有 `MainAPKVersion`、`RenPyAPKVersion`、`MKXPAPKVersion`、
  `EasyRPGAPKVersion`、`WinlatorAPKVersion`——没有任何 Mac 目标。
- LangTL 中 `Winlator: 209` 处、`Android: 97` 处，无 macOS 文案。
→ **结论：官方无 macOS 方案；这是空白市场，也意味着没有现成协议可复用，必须自研。**

## 10. 直接命中源码级证据：`mtool-runtime` 运行时包（Android 侧的 Agent 引导）

`Tool/mtool-runtime`（813KB）不是普通文件，是**带 34 字节私头 + ZIP** 的运行时插件包。
按本地头逐条解析后得到 5 个条目，其中两个是**明文 JS**（已导出到 `analysis/pc/runtime/`）：

```
manifest.json          1108 B
node/main.js           4497 B   ← 主服务引导
node/GameNodeEMU.js    1646 B   ← 在"没有 Node 的游戏进程里伪造 Node 环境"
runtime.jar          642834 B   ← dex/runtime 实现
lib/arm64-v8a/libmtoolbackend.so  162032 B
```

`manifest.json` 暴露了宿主与运行时的**插件契约**：

```json
{ "version": "1.0.2074",
  "loaderApiVersion": 5, "minLoaderApiVersion": 5,
  "dex": "runtime.jar",
  "implementationClass": "app.mtool.mtoolmobile.mtool.runtime.MToolViewRuntimeImpl",
  "webViewImplementationClass": "...WebViewRuntimeImpl",
  "startupImplementationClass": "...MToolStartupRuntimeImpl",
  "backendImplementationClass": "...MToolBackendRuntimeImpl",
  "nativeLibraries": ["lib/arm64-v8a/libmtoolbackend.so"],
  "nodeScripts": ["node/main.js", "node/GameNodeEMU.js"],
  "sha256": { ... } }
```

→ 宿主只做壳，**运行时整包可热更新**（带 API 版本下限校验与逐文件 SHA-256）。

`node/main.js`（逐行可读）证明 Agent 是**以 bytenode 字节码形式注入 Node 进程**的：

```js
const Module = require("module");            // 劫持模块加载，仅放行
Module._load = function (request, parent, isMain) {
    if (["fs","http","https","crypto","net","tls","path","bytenode"].includes(request)) { ... }
    return originalLoad.apply(this, arguments);
};
bytenode = require('bytenode');
function launchServerWithBasePath(basePath) {
    const clientPath = `${basePath}/Client.js.${process.arch}`;
    const serverPath = `${basePath}/Server.js.${process.arch}`;
    bytenode.runBytecode(fs.readFileSync(clientPath));   // ← 先跑 Client
    bytenode.runBytecode(fs.readFileSync(serverPath));   // ← 再跑 Server（定义 initServer）
    process.chdir(process.mainModule.path + "/mtoolWebRoot");
    initServer();
}
launchServerWithBasePath(`mtoolWebRoot/loaders`);        // 失败写 serverStartFailed 文件
```

`node/GameNodeEMU.js` 证明**"给没有 Node 的引擎伪造 Node 环境"**的手法，
并直接给出握手与鉴权：

```js
global.require = require;  global.module = module;
global.WebSocket = require("ws");                        // ws 作为全局 WebSocket
bytenode.runBytecode(fs.readFileSync(`${basePath}/Client.js.${process.arch}`));
bytenode.runBytecode(fs.readFileSync(`${basePath}/Server.js.${process.arch}`));

let serverAddr = fs.readFileSync(process.mainModule.path + "/serverURI");   // 宿主写的地址文件
client = new Client();
client.taskHandles.whoareyou = function () { return "gameServer"; };        // ← 任务表注册身份
try { client.authToken = fs.readFileSync(... + "/mtoolAuthToken").toString().trim(); } catch (e) {}
client.webSocketConnect(`ws://${serverAddr}`);                              // ← 出站连接宿主
```

**这解决了本报告最关键的不确定性**：协议不是"宿主注入后主动连入游戏"，
而是 **Agent 主动连出（outbound WebSocket）到宿主**，再用 `taskHandles` 注册命名 RPC、
用 `authToken` 校验。这条设计对 macOS 直接可复用（出站连接不受任何系统限制），
也解释了为什么 Windows 侧还需要命名管道回退（`WaitNamedPipeW`）。

（`analysis/pc/runtime/main.js`、`GameNodeEMU.js` 为原始导出文件，可复核。）

---

## 11. 移植到 macOS 的技术判断（供架构设计用）

Windows 侧的根基（DLL 注入 + `winmm.dll` 劫持 + 命名管道）在 macOS 上全部不可用：

| Windows 手段 | macOS 现实 |
|---|---|
| `CreateRemoteThread` + `LoadLibrary` 远程注入 | 需 `task_for_pid`（SIP 下需 root + 关闭 SIP），不可分发 |
| `winmm.dll` / `version.dll` 搜索顺序劫持 | 无此机制 |
| 全局 inline hook (MinHook/ShadowHook) | 需 entitlement，且对已签名二进制破坏签名 |
| 命名管道 | 无（可用 Unix socket） |
| 直接改 PE | 无用（Mach-O） |

因此 macOS 版必须**按引擎分别走"合法可分发"的注入面**：

1. **RPG Maker MV/MZ、TyranoBuilder**（NW.js/Chromium）：启动时追加
   `--remote-debugging-port=<port>`，用 **CDP**（`/json/list` → WebSocket → `Runtime.evaluate`）
   在页面上下文注入 Agent。无需签名豁免、无需修改游戏文件。**可行性最高。**
2. **Ren'Py**：引擎自带 CPython，`game/` 目录下的任意 `.rpy` 会被自动加载执行
   → 投放一个 `mochibox_bridge.rpy`（可逆、不动原文件），在其中 `init python` 注册
   `config.say_menu_text_filter` / 包装 `Character` 渲染，再用 `socket` 回连宿主。
3. **RPG Maker XP/VX/VX Ace**：Windows 独占 → 两条路
   (a) macOS 上跑 **mkxp-z**（开源、可编译 macOS 版），hook Ruby 层；
   (b) 用 Wine/CrossOver 跑原版 + 复用 Windows 注入 DLL。**成本最高，放 P2。**
4. **RM2000/2003**：EasyRPG Player 有 macOS 构建，可在其文本 API 层挂钩。
5. **WOLF / 吉里吉里 / Siglus / Unity / Godot 商业包**：仅 Windows → 依赖 Wine 后端，P3。

**推荐产品形态**：原生 Swift/SwiftUI 宿主（不依赖 Electron/Node），
按"适配器"插件化，首批交付 MV/MZ 适配器，其余引擎留接口。
