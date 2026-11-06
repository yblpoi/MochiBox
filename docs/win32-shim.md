# Win32API shim（macOS / mkxp-z）

> 一句话结论：mkxp-z 在 macOS 上能注册 `Win32API`，但 `.new` 会把 dll 名当相对路径做 `dlopen`，任何用 Win32API 的 XP / VX / VX Ace 游戏都在 `Win32API.new` 阶段 `RuntimeError` 崩掉。[`Resources/rgss/mochi_win32_shim.rb`](../Resources/rgss/mochi_win32_shim.rb) 在 preload 阶段 reopen `Win32API.new`，按 `(dll, func)` 分派到纯 Ruby 安全实现；未知 API 按声明类型返回安全默认并记一次日志，**任何路径都不 raise**。不改 mkxp-z 二进制，默认开启。

## 1. 动机：不是"没兼容"，是 new 就崩

在 macOS 的 mkxp-z（`vendor/runtime/mkxp-z`，35,513,696 B）里实测：

```text
[1] Win32API 是 Class，ancestors = [MiniFFI, Object, Kernel, BasicObject]
[2] Win32API.new('kernel32', 'GetPrivateProfileStringA', 'PPPPLLP', 'L')
    RuntimeError: Failed loading /private/tmp/win32probe/kernel32:
      dlopen(/private/tmp/win32probe/kernel32, 0x0006): tried:
      '/private/tmp/win32probe/kernel32' (no such file), ...
[3] user32 同理；libc.dylib 也被拼成 cwd 下的相对路径
[4] Win32API 与 MiniFFI 是同一个类对象（上游 miniffi-binding.cpp 末尾
    rb_define_const(rb_cObject, "Win32API", cMiniFFI)），reopen 一个等于覆盖两个
```

后果不是"某些函数不可用"，而是**脚本在 `Win32API.new` 那一行就抛异常**，游戏主循环还没开始。这是 [`rpgmaker-classic-compat.md`](rpgmaker-classic-compat.md) 里「mkxp-z 跑不动依赖 Win32API / 外部 DLL 的国产游戏」的根因层。

上游行为（dlopen 相对路径）在 macOS 上没有"正确"可解：Windows 的 `kernel32` / `user32` 本来就不存在于 macOS。所以这里不做 DLL 加载，只做**语义降级**：让脚本拿到形状正确、类型正确、值保守的返回值，继续往下跑。

## 2. 架构

```text
mkxp.json preloadScript
  └─ Resources/rgss/mochi_rgss_hook.rb        （GameLauncher 注入的绝对路径）
       ├─ 文件顶部（早于 MOCHI_RGSS_HOOK=off 的提前返回）:
       │    load File.join(__dir__, 'mochi_win32_shim.rb')
       │    MochiWin32Shim.install!            ← 失败只记日志，不阻断 hook
       └─ 原有 socket / 翻译逻辑（未改动）

MochiWin32Shim.install!
  └─ reopen Win32API（= MiniFFI）的单例方法 new(dll, func, imports, exports)
       └─ 返回 MochiWin32Shim::Api（只提供 call / Call，任意参数个数）
            └─ dispatch → HANDLERS[dll][func]
                 ├─ 命中：纯 Ruby handler（INI、tick、MCI 状态机……）
                 └─ 未命中：handle_unknown → 按 exports 安全默认 + 记一次日志
```

要点：

* **不改二进制**。覆盖只影响之后的 `Win32API.new`；覆盖前保存的 `orig = Win32API.method(:new)` 仍会抛原生 `RuntimeError`（实测）。因此不需要 patch mkxp-z，也不影响 MiniFFI 的其它用法。
* **`Win32API` 与 `MiniFFI` 是同一个类对象**，`install!` 同时检查 `defined?(Win32API)` / `defined?(MiniFFI)` 并去重；游戏若直接 `MiniFFI.new` 也走 shim。
* **常量幂等**：所有常量都带 `unless const_defined?(..., false)`，重复 `load` 不告警；`install!` 用 `$mochi_win32_shim_installed` + 类实例变量 `@mochi_win32_shim_new` 双重防重复覆盖。
* **安装顺序**：hook 里的 load 放在 `ENV['MOCHI_RGSS_HOOK'] == 'off'` 提前返回**之前**。翻译通道关掉时 shim 仍然生效；`MOCHI_WIN32_SHIM=off` 只关 shim，不动 hook。
* **打包**：[`Scripts/build.sh`](../Scripts/build.sh) 在复制 hook 的同一目录（`Contents/Resources/rgss/`）复制 shim；hook 用 `__dir__` 相对加载，不能拆开放。

## 3. 支持矩阵

所有 handler 都自己 `rescue`，`dispatch` 再兜一层；参数缺失 / nil / 类型不对都返回该函数的保守默认，不抛异常。

### 3.1 kernel32

| API（A/W 共用） | 行为 | 返回值 |
|---|---|---|
| `GetPrivateProfileStringA/W` | 真读 INI，路径相对 `Dir.pwd`；section/key 大小写不敏感；缺失用默认值；`P` 参数是调用方 String 时原地 `replace` 成 `"value\0"`（A=UTF-8 字节，W=UTF-16LE 码元） | 写入长度（不含结尾 NUL），截断时返回实际写入量 |
| `GetPrivateProfileIntA/W` | 真读 INI；十进制、`0x` 十六进制、负号；非数字按 atoi 语义得 0 | 整数 |
| `WritePrivateProfileStringA/W` | 真写 INI；保留注释 / 顺序 / 其它 key，原地改值并保留磁盘上的原 key 拼写；`value=nil` 删 key，`key=nil` 删整段 | 1 成功 / 0 失败（空 section、空文件名、目录不存在等） |
| `GetTickCount` / `GetTickCount64` | 单调毫秒（进程内基准） | 32 位截断 / 64 位整数 |
| `Sleep(ms)` | 真睡，但**单次封顶 16 ms**（`SLEEP_MAX_MS`），避免主线程被商业脚本的长等待卡死 | nil |
| `QueryPerformanceCounter` / `Frequency` | 单调纳秒 / 固定 `1_000_000_000` | 整数 |
| `GetModuleHandleA/W` | 不假装模块句柄 | 0 |
| `GetModuleFileNameA/W` | 写 `Dir.pwd/Game.ini`（脚本 `dirname` 后正好是游戏目录） | 写入长度 |
| `lstrlenA/W` | 按 UTF-8 字节数（A 语义） | 字节数 |
| `RtlMoveMemory` | no-op（不搬运内存） | nil |
| `GlobalAlloc` / `GlobalFree` | 不假造内存：分配返回 0；释放返回 1 | 0 / 1 |
| `GetCommandLineA/W` | 无命令行概念 | `""` |
| `GetLastError` / `SetLastError` / `GetVersion` | 恒 0 / no-op / 0 | 0 / nil / 0 |

INI 编码优先级：UTF-16LE BOM → UTF-8 BOM → 合法 UTF-8 → GBK/CP936 → `scrub`。任何编码问题都降级成替换字符，**绝不 raise**。写回统一 UTF-8。

### 3.2 user32

| API | 行为 | 返回值 |
|---|---|---|
| `GetAsyncKeyState` / `GetKeyState` | 恒 0：mkxp-z 的按键走 SDL，不经过 Win32，无法如实映射 | 0 |
| `GetKeyboardState` | 若缓冲区 ≥256 字节则清零 | 0 |
| `GetCursorPos` / `SetCursorPos` | 若缓冲区 ≥8 字节则写 0,0 / no-op | 1 / 1 |
| `MessageBoxA/W` | **只记日志，不弹窗**（真弹窗会卡死无头/自动化），文本截断 80 字 | 1 = IDOK |
| `FindWindowA/W` | 不假装找到窗口 | 0 |
| `SetWindowTextA/W` | no-op | 1 |
| `GetSystemMetrics` | 0→1024、1→768，其余 0 | 整数 |
| `ShowCursor` | no-op | 0 |
| `GetForegroundWindow` / `GetActiveWindow` | 无窗口句柄概念 | 0 |
| `GetDC` / `ReleaseDC` | 不提供真实 DC | 0 / 1 |
| `keybd_event` / `mouse_event` | no-op | nil |
| `GetDoubleClickTime` | 与 Windows 默认一致 | 500 |

### 3.3 winmm

| API | 行为 | 返回值 |
|---|---|---|
| `mciSendStringA/W` | 只维护最小状态机，**不实现播放**：`open ... alias X`→open，`play X`→playing，`stop/pause X`→paused，`close X`→删除，`status X mode` 写 `playing`/`paused`/`stopped`/`""`。未知命令同样返回 0，避免脚本卡在错误分支 | 0（始终） |
| `PlaySoundA/W` | 不播放 | 1 |
| `timeGetTime` | 单调毫秒（32 位） | 整数 |
| `timeBeginPeriod` / `timeEndPeriod` | no-op | 0 |

MCI 的关键不是"能放音乐"，而是 `status bgm mode` 不会永远返回 `""` 让脚本死循环。状态机按 alias 名（大小写不敏感）记在模块级 hash 里。

### 3.4 version / gdi32 / advapi32

| DLL | API | 返回 |
|---|---|---|
| version | `GetFileVersionInfoSizeA/W`、`GetFileVersionInfoA/W`、`VerQueryValueA/W` | 0（统一"没有版本资源"，让脚本走 fallback 分支） |
| gdi32 | `CreateFontIndirectA/W`、`GetDeviceCaps` | 0 |
| gdi32 | `DeleteObject` | 1 |
| advapi32 | `RegOpenKeyExA/W`、`RegCreateKeyExA/W` | 2 = `ERROR_FILE_NOT_FOUND`，并把 `phkResult` 写 0 |
| advapi32 | `RegQueryValueExA/W`、`RegSetValueExA/W` | 2（安全失败，不假造注册表值） |
| advapi32 | `RegCloseKey` | 0 |

注册表故意不模拟成功：商业游戏常见逻辑是"读不到就用默认配置/写自己的 INI"，假造成功反而会让它读到空值。

### 3.5 未知 API

未注册的 `(dll, func)` 按 **exports** 首字符兜底：

| exports | 返回 |
|---|---|
| `P` / `p` | `""` |
| `L` / `N` / `I` / `Q` / `H` / `B` / `C` | 0 |
| `V` / `v` / 空串 / nil | `nil` |
| `F` / `D` | 0（浮点的安全默认） |
| Array / Integer / Symbol / 其它 | 取首字符或按整数类型码映射；解析失败按整数 0 |

未知 API 每个 `(dll, func)` **只记一次**日志，带参数个数和类型摘要（值截断 24 字符），避免把密钥/路径整段写进日志。

## 4. 安全降级与日志

* **任何路径不 raise**：handler 自身 rescue → dispatch rescue → `Api#call` rescue → `Win32API.new` 构造兜底（`Api.allocate`）。用户看到的最坏结果是"返回值不对"，不是"启动崩溃"。
* 日志复用 `MOCHI_RGSS_LOG`（默认 `/tmp/mochi-rgss.log`），前缀 `[win32]`，与 hook 的 `[mochi-rgss]` 同文件；超过 1 MB 自动截断。写日志失败静默。
* 记录的事件：安装（reopened MiniFFI / handlers=N）、未知 API 首次、INI 读写失败、MessageBox 文本、MCI 命令（截断 80 字）、`MOCHI_WIN32_SHIM=off`。MCI/MessageBox 也按 key 只记一次，避免每帧刷屏。

## 5. 关闭方式

```bash
MOCHI_WIN32_SHIM=off   # 完全不安装：Win32API 恢复原生行为（用即崩，仅用于对照）
MOCHI_RGSS_HOOK=off    # 只关翻译通道；shim 仍然安装（hook 顶部先装 shim 再判断开关）
```

两个开关互不牵连。

## 6. 已知限制

* **按键 / 光标未映射**：`GetAsyncKeyState` 恒 0，依赖热键/作弊键的脚本不工作（但不崩）。
* **MCI 不真播放**：只维护状态机；音频仍由 mkxp-z 自己的 Audio 模块负责，脚本若绕开 RGSS 用 MCI 放 BGM，实际无声。
* **内存 / 指针未模拟**：`GlobalAlloc` 返回 0，`RtlMoveMemory` no-op。任何"分配 + 写结构体 + 传给另一个 API"的脚本拿到的是无效指针，可能读到空数据，但不会越界写 Ruby 对象。
* **QPC 返回语义**：真 Win32 的 `QueryPerformanceCounter` 写指针参数，这里直接返回整数；把返回值当指针解引用的脚本会得到错误结果。
* **`lstrlenA/W` 都按 UTF-8 字节数**，W 变体没有按 UTF-16 码元数计算。
* **`GetModuleFileName` 返回 `cwd/Game.ini`**，不是真实的 exe 路径（mkxp-z 是单二进制，没有意义）。
* **未知 void API 返回 nil**：若脚本拿它做算术会 `NoMethodError`；这是"按声明返回"的代价，可在日志里看到 `unknown api` 后补 handler。
* **只覆盖上表 API**：其它 dll/函数一律走未知兜底；不真正加载任何 DLL。
* **INI 写入不与外部进程同步**：shim 改的文件可能被游戏或用户同时改，没有文件锁。
* **无商业游戏样本实测**：现有 fixture 是合成 XP 工程；对真实国产游戏的兼容性只到"API 层面不崩"，业务层行为仍需逐游戏验证。

## 7. 验证命令与证据等级

### 7.1 纯 Ruby 合同测试（确定性，CI 可跑）

```bash
# 只跑本 case（6 个场景，173 条断言）
node Tests/e2e/cases/contract/23_win32_shim.mjs

# 全量 contract suite（23 个 case）
node Tests/e2e/lib/run.mjs --suite contract
```

`23_win32_shim.mjs` 的场景：

| 场景 | 覆盖 |
|---|---|
| `contract` | stub Win32API 后 load shim：安装/幂等、8 种 imports/exports 形状、未知兜底、call/Call 等价、INI 全矩阵（A/W、大小写、缺失默认、缓冲区写入/截断、GBK、BOM、删 key/段）、6 个 DLL 的安全返回值、全 nil 参数不 raise |
| `disabled` | `MOCHI_WIN32_SHIM=off` 保留原 `new`（仍抛错） |
| `no-host` | 宿主没有 Win32API 时 `install!` 返回 false，之后定义 stub 可重试 |
| `hook-on` | preload 链上 shim 生效，hook 正常安装 |
| `hook-off-shim-on` | `MOCHI_RGSS_HOOK=off` 时 hook 提前返回，但 shim 仍安装 |
| `hook-missing-shim` | shim 文件缺失时 hook 不抛异常、照常安装并记录失败 |

最近一次结果：`# pass 173 fail 0`；全量 contract `cases=23 assertions=1199 fail=0`。

### 7.2 mkxp-z 实跑（真实二进制，合成 XP fixture）

在一个**临时副本**里做（不要改原 fixture，例：`cp -R /tmp/xp-run /tmp/win32-shim-run`），把 `mkxp.json` 的 `preloadScript` 指向 hook，并另加一个 probe 脚本；probe 里 `Win32API.new(...).call` 调 `GetPrivateProfileStringA` / `GetTickCount` / `GetAsyncKeyState` / 未知函数，写日志后 `exit!`（无窗口）。实测输出：

```text
probe: Win32API class=Class new_owner=#<Class:MiniFFI>
probe: GetPrivateProfileStringA call=11
probe: WritePrivateProfileStringA=1
probe: GetTickCount=410643680 integer=true
probe: GetAsyncKeyState=0
probe: unknown=0
probe: read-back n=2 buf="ok\x00..."
[win32] installed: reopened MiniFFI; handlers=71
[win32] unknown api kernel32!mochitotallyunknownapi export=int argc=2 ...
```

再以真实启动路径（`preloadScript` 只有 hook）拉起 XP 工程，日志出现 `[win32] installed` 与 `surfaces enabled`，窗口正常创建、脚本无异常。证据等级：**A-**（真实 mkxp-z + Ruby 3.1，合成 fixture）。

### 7.3 什么还没验证（证据等级 C）

* **任何商业 XP/VX/VX Ace 游戏**：没有样本，只能保证 Win32API 调用层不崩。
* 依赖真实 DLL 语义的脚本（内存读写、注册表实际读取、MCI 播放、按键轮询）。
* Windows 之外的 dll 名变体（`kernelbase` 已别名到 kernel32；其它不认）。

## 8. 如何新增一个 API

1. 在 [`Resources/rgss/mochi_win32_shim.rb`](../Resources/rgss/mochi_win32_shim.rb) 的 `HANDLERS` 里加 `'kernel32' => { 'newfunc' => :handle_new_func }`（dll/func 都用小写、去掉扩展名）；
2. 写 `def handle_new_func(args, func)`，内部自己 rescue，返回值必须符合 exports 类型；
3. 在 `Tests/e2e/cases/contract/win32_shim_probe.rb` 的 contract 场景补断言，跑 `node Tests/e2e/cases/contract/23_win32_shim.mjs`；
4. 更新本文件的矩阵。
