# RGSS 文本通道：可行性验证与 hook 协议

面向：准备把 XP / VX / VX Ace 的**屏上文本**接进 MochiBox 的人。
脚本：`Resources/rgss/mochi_rgss_hook.rb`（已由 `GameLauncher` 注入 `preloadScript`）。
宿主：`Sources/Adapters/RGSSBridge.swift` + `Sources/Adapters/RGSSPipelineTranslator.swift`。
结论一句话：**不要用 `customScript`；用 `preloadScript` + `TracePoint(:end)` 延迟挂钩，三版分别认
`process_all_text` / `start_message` / `refresh`，协议手写；翻译走现有管线，首屏超时就回
PENDING + 原文，游戏主线程绝不等网络。**

## 0. 结论

- `customScript` 是二选一开关：设了它，游戏自己的全部 RGSS 脚本不会执行（见 §1）。
- `preloadScript` 在 `$RGSS_SCRIPTS` 解码之后、脚本执行循环之前运行；此时 `Window_Message` 还没定义，
  必须用 `TracePoint.new(:end)` 等类定义完成后再 `alias_method`。
- `postloadScript` 在 `rgss_main` 被调用时执行；XP 默认 `Main` 不调用 `rgss_main`，所以不能作为通用注入点。
- 三版入口不是同一个方法：XP = `Window_Message#refresh`，VX = `#start_message`，VX Ace = `#process_all_text`。
- Ruby 侧 `json` / `net/http` / `yaml` / `uri` / `time` / `date` 等一律 `LoadError`；协议必须手写。
- 实测 mkxp-z 的 socket 只有 `TCPSocket`，**没有 `Socket.tcp`**（hook 日志：`Socket.tcp=no TCPSocket=yes`）。

## 1. 为什么不能用 `customScript`

mkxp-z 的 `binding-mri.cpp:1297-1301`：

```cpp
std::string &customScript = conf.customScript;
if (!customScript.empty())
    runCustomScript(customScript);
else
    runRMXPScripts(btData);
```

这是**二选一**，不是叠加：

- 设了 `customScript`，只 `eval` 你给的那一个文件；
- `runRMXPScripts` 整个不执行，`$RGSS_SCRIPTS` 的解码与执行循环都被跳过；
- 后果：`Window_Message`、`Scene_Title`、`Main` 等游戏脚本都不存在。除非你的脚本自己把整份游戏脚本
  再加载一遍，否则游戏起不来。

所以 **`customScript` 不能用来做注入**。它可以做“完全替换运行时”，那是另一件事。

## 2. 正确的注入点

### 2.1 preload vs postload

| 注入点 | 源码位置 | 执行时机 | 此时 `Window_Message` | 依赖 | 取舍 |
|---|---|---|---|---|---|
| `preloadScript` | `binding-mri.cpp:1038-1044` | `$RGSS_SCRIPTS` 解码后、脚本执行循环前 | 未定义（实测 `WM=nil`） | 无 | **本项目选它**；必须自己等类定义 |
| `postloadScript` | `binding-mri.cpp:863-871` | `rgss_main` 被调用时 | 已定义 | 游戏必须调用 `rgss_main` | XP 默认 `Main` 不调用，不能通用 |

`preloadScript` 的循环（`binding-mri.cpp:1038`）：

```cpp
/* Execute preloaded scripts */
for (std::vector<std::string>::const_iterator i = conf.preloadScripts.begin();
     i != conf.preloadScripts.end(); ++i)
{
    if (shState->rtData().rqTerm)
        break;
    runCustomScript(*i);
}
```

它跑在脚本执行循环之前，所以适合“先装钩子，等游戏脚本自己定义 `Window_Message`”。

### 2.2 延迟挂钩

preload 阶段 `Window_Message` 还不存在（实测 `WM=nil`）。骨架的做法：

```ruby
$mochi_hook_trace = TracePoint.new(:end) do |tp|
  next unless tp.self.is_a?(Class) && tp.self.name == 'Window_Message'
  hook_window_message('tracepoint')
  $mochi_hook_trace.disable if $mochi_hook_entry
end
$mochi_hook_trace.enable
```

要点：

- `TracePoint(:end)` 对每个 class/module 定义都会触发；必须用 `tp.self.name == 'Window_Message'` 过滤。
- 挂钩成功后立刻 `disable`，不要一直带着 TracePoint 跑游戏。
- 如果类已经定义（例如 postload 或控制台加载），直接挂钩，不走 TracePoint。
- 如果类定义结束时还没找到入口方法（自定义脚本拆成多个 class 块），**不要 disable**，等下一次 class end。

## 3. 三版本的入口点

| 版本 | 入口 | 文本存储 | 已有实测证据 |
|---|---|---|---|
| XP (RGSS1) | `Window_Message#refresh` | `$game_temp.message_text`（单个字符串，带 `\n` 和控制符） | `MSG[refresh] message_text="...\n..."` |
| VX (RGSS2) | `Window_Message#start_message` | `$game_message.texts`（数组） | `MSG[start_message] texts=[...]` |
| VX Ace (RGSS3) | `Window_Message#process_all_text` | `$game_message.texts`（数组） | 之后走 `draw_text_ex` → `process_normal_character` → `Window_Base#draw_text` |

### 3.1 差异陷阱

- **XP 没有 `draw_text_ex`**；XP/VX 都没有 `process_all_text`。不能只认一个方法名。
- 入口按优先级判断，而不是硬编码版本号：

```ruby
ENTRY_TABLE = [
  [:process_all_text, 'RGSS3'],
  [:start_message,    'RGSS2'],
  [:refresh,          'RGSS1']
]
```

- 判断用 `method_defined?` **或** `private_method_defined?`；不要假设入口一定是 public。
- 如果方法是从父类继承的（`Window_Base#refresh` 之类），要考虑误判；默认脚本的入口都定义在
  `Window_Message` 自身。骨架按“存在即用”实现，接产品前建议加 owner 校验或白名单。

### 3.2 写回位置

在调用原方法**之前**改文本源，原方法就会渲染译文：

| 版本 | 写回 | 备注 |
|---|---|---|
| XP | `$game_temp.message_text = 译文` | `refresh` 会重新读这个字符串 |
| VX | `$game_message.texts.map! { ... }` | `start_message` 会重新拼 `@text` |
| VX Ace | `$game_message.texts.map! { ... }` | `process_all_text` 会重新读数组 |

三版都已实测渲染出替换文本（本次 XP 截图见 §7.1；VX/VX Ace 的入口与写回见 §3 的既有实测证据）。

## 4. Ruby 环境

mkxp-z 2.4.2（`2.4.2/f02d586`）实测 Ruby 3.1.3：

| 库 | 结果 | 说明 |
|---|---|---|
| `socket` | **可用（有限）** | `TCPSocket` 可用；**本构建没有 `Socket.tcp`**（见 §7.1 日志） |
| `zlib` `digest` `stringio` `strscan` `ripper` | 可用 | 可用于解压、哈希、扫描 |
| `json` `date` `time` `set` `open-uri` `net/http` `uri` `yaml` | `LoadError` | **协议不能依赖它们** |

补充：

- `Time.now` / `Time#strftime` 是 core，不受 `require 'time'` 失败影响；但 `Time.parse` 之类不可用。
- base64 不需要库：`[s].pack('m0')` / `s.unpack1('m0')` 是 String 内置。
- 骨架只 `require 'socket'`，并用 `defined?(TCPSocket)` 做能力判断。

## 5. 行协议

UTF-8 文本，TAB 分字段，LF 结尾，一行一条消息：

```text
→ MochiBox:  TEXT	<seq>	<RGSS1|RGSS2|RGSS3>	<base64(原文)>
← MochiBox:  RESP	<seq>	<base64(译文)>                      正常译文（hook 会缓存）
← MochiBox:  RESP	<seq>	<base64(原文的 UTF-8 版本)>	PENDING  还没译好：显示原文，不缓存
```

| 字段 | 说明 |
|---|---|
| `seq` | 进程内自增十进制；响应必须原样带回，不匹配就丢弃 |
| `version` | `RGSS1` / `RGSS2` / `RGSS3`，不要用带空格的 “VX Ace” |
| `base64` | UTF-8 字节的 `pack('m0')`，严格模式、无换行；解码用 `unpack1('m0')` |
| 第 4 段 | 省略 = 正常译文；`PENDING` = 这次没译好，载荷是原文（UTF-8 重编码） |
| 原文 | 可以含 `\n`（XP 的多行是一个字符串）；base64 把它藏起来，不会破坏行协议 |
| 多行 | VX/VX Ace 的 `texts` 数组**每个元素一条 TEXT**；XP 整串一条 |

服务端约束：

- 必须在同一条连接上回到对应 `seq`；
- 译文必须是合法 UTF-8；空串或非法 UTF-8 会被 hook 丢弃；
- **PENDING 的载荷必须非空**：它是原文的 UTF-8 重编码。回空会让 hook 放行游戏原串，
  而 RGSS1/2 的 CP932 原串在当前 mkxp-z 构建里会让 `Window_Message` 抛
  `invalid byte sequence in UTF-8`（实测，见 §8.1）；
- PENDING 不触发 2s 失败冷却；hook 按原文在本进程内记 1.5s 的“暂不重问”窗口；
- 不需要 JSON、HTTP、长度前缀——行协议本身足够；
- 默认只监听 `127.0.0.1:47123`，不要绑 `0.0.0.0`。

## 6. 骨架实现

文件：`Resources/rgss/mochi_rgss_hook.rb`。

### 6.1 版本分派

```ruby
ENTRY_TABLE.each do |name, ver|
  if cls.method_defined?(name) || cls.private_method_defined?(name)
    entry = name
    version = ver
    break
  end
end
```

### 6.2 幂等

- 全局标记 `$mochi_hook_installed`：重复 `load` 直接返回；
- 常量用 `const_defined?(..., false)` 保护，重复加载不会刷 `already initialized constant` 警告；
- 入口别名 `mochi_orig_<entry>`；已经挂过就不再挂。

### 6.3 失败降级与超时

- 连接 / 写 / 读都用**非阻塞 IO + 截止时间**，不是裸 `gets`；
- 连接 0.2 s，读写各 0.2 s；
- 连不上、超时、EOF、协议错、base64 错、非法 UTF-8 → 返回 `nil`，调用方保留原文；
- **PENDING 不是失败**：宿主 120ms 内没译好时回 `PENDING + 原文`，hook 显示原文但
  不写缓存、不触发 2s 冷却；同一句按原文记 1.5s 的“暂不重问”窗口；
- 真正的失败（连不上 / 超时 / 协议错）后 2 s 冷却，避免服务端没起时每条消息都卡 0.2 s；
- 整个 hook 体 `rescue Exception`，**绝不让异常冒到游戏主循环**；
- 实测：黑洞服务端（accept 后不回复）阻塞 `0.206 s` 后放行原文（§7.2）。

### 6.4 缓存

- `原文 -> 译文` 和 `译文 -> 译文` 都进缓存（最多 256 条）；
- 反向登记是为了防止下一轮 `refresh` / `process_all_text` 拿到已经替换过的译文再请求一次；
- PENDING 的原文**不进译文缓存**，单独记在 `pending` 表里（key → 可再次请求的时刻）；
- 缓存只影响显示层，不写存档。

### 6.5 日志

- 路径：`ENV['MOCHI_RGSS_LOG']`，默认 `/tmp/mochi-rgss.log`；
- 超过 1 MB 先截断再写；
- 只记事件与 `inspect` 后的文本，不改变游戏行为；
- `MOCHI_RGSS_HOOK=off` 时只记一条 disabled，不安装任何钩子。

## 7. 实测

测试环境：`/tmp/xp-run`，mkxp-z 2.4.2（`2.4.2/f02d586`），XP 工程（`Game.ini` 的 `Library=RGSS104E.dll`），
地图 `Map001` 的 EV001 是 `trigger=3`（autorun），进入 New Game 自动弹对话。

配置：

```json
{"preloadScript":["mochi_rgss_hook.rb"],"debugMode":false}
```

### 7.1 成功路径（服务端回【中文测试】）

hook 日志：

```text
[2026-11-02 16:48:04] socket probe: Socket.tcp=no TCPSocket=yes
[2026-11-02 16:48:04] tracepoint armed; waiting for Window_Message
[2026-11-02 16:48:04] hooked Window_Message#refresh as RGSS1 (trigger=tracepoint)
[2026-11-02 16:48:18] RESP seq=1 "【中文测试】"
```

服务端日志：

```text
16:48:18 ACCEPT 127.0.0.1:60050
16:48:18 TEXT seq=1 ver=RGSS1 text='MKXP-Z G1 冒烟：默认 RGSS1 脚本已在 Ruby 3.1 上启动。\n第二行：事件解释器、Window_Message、Bitmap 绘制均正常。\n'
16:48:18 RESP seq=1 text='【中文测试】'
```

截图（本次验证产物，未入库）：`/tmp/xp-run/hook-msg.png`。Vision OCR：

```text
OCR_COUNT 2
OCR [0.13,0.95] TestProject
OCR [0.17,0.26] 【中文测试】
```

对话框里显示的是 **【中文测试】**，不是原文；证明“读原文 → 服务端 → 写回 → 原方法渲染”整条链路成立。

### 7.2 失败路径

服务端停掉，仍用 `preloadScript`（这次用绝对路径 `/tmp/xp-run/mochi_rgss_hook.rb`）：

```text
[2026-11-02 16:48:54] socket probe: Socket.tcp=no TCPSocket=yes
[2026-11-02 16:48:54] tracepoint armed; waiting for Window_Message
[2026-11-02 16:48:54] hooked Window_Message#refresh as RGSS1 (trigger=tracepoint)
[2026-11-02 16:49:07] request failed seq=1: Errno::ECONNREFUSED: Connection refused - connect(2) for "127.0.0.1" port 47123
```

OCR 显示的是原文（窗口宽度裁掉了后半句）：

```text
OCR [0.15,0.26] MKXP-Z G1冒烟：默认 RGSS1 脚本已在 Ruby3.1 上后
OCR [0.16,0.19] 第二行：事件解释器、Window_Message、Bitmap 绘
```

游戏没有崩、没有卡死；失败只影响“这次不翻译”。

黑洞服务端（accept 后不回复）的宿主 Ruby 干跑：

```text
RENDERED="第一行\n第二行（原文）"
ELAPSED=0.206
[2026-11-02 16:44:32] read timeout/eof seq=1
```

### 7.3 `preloadScript` 的路径解析

源码：

- `runCustomScript` → `readFileSDL`（`src/util/sdl-util.h:78`）→ `RWFromFile` → `fopen(path, "rb")`（第 70 行）。
- 也就是说，**它就是相对进程当前工作目录的 `fopen`**，不是“相对 mkxp.json 所在目录”，也不是资源搜索路径。
- `Config::read` 在 `config.cpp:259` 如果设置了 `gameFolder` 会先 `setCurrentDirectory(gameFolder)`，
  然后才读 `Game.ini` 和脚本；所以 `gameFolder` 会改变相对路径的基准。
- 产品侧 `GameLauncher` 把子进程的 `workingDirectory` 设为游戏根目录（并随包分发带
  `-Dworkdir_current=true` 的 mkxp-z，不再强制改成二进制目录）。

实测：

| 写法 | cwd | 结果 |
|---|---|---|
| `"mochi_rgss_hook.rb"` | `/tmp/xp-run` | 加载成功（§7.1） |
| `"/tmp/xp-run/mochi_rgss_hook.rb"` | `/tmp/xp-run` | 加载成功（§7.2） |

**正确写法**：绝对路径，或者“相对于游戏根目录”的路径。不要写相对于仓库、相对于 mkxp.json、或
相对于 MochiBox.app 内资源目录的路径——mkxp-z 不会替你解析这些基准。

### 7.4 VX / VX Ace 分派

本次真机只跑了 XP。VX/VX Ace 的分派与数组改写用宿主 Ruby + 假 `Window_Message` 做了干跑：

```text
VERSION="RGSS2"  RENDERED=["【中文测试】", "【中文测试】"]
VERSION="RGSS3"  RENDERED=["【中文测试】"]
```

这验证的是“方法存在性 → 版本 → 写回字段”的代码路径；三版真实游戏渲染替换文本的既有实测
见 §3 的证据表。

## 8. 已知限制

1. **只改显示层，不改存档与事件状态。**
   - XP 改的是 `$game_temp.message_text`（临时显示源）；
   - VX/VX Ace 改的是 `$game_message.texts`（消息窗口的读取源）；
   - 事件命令里的 401 原文、存档、变量、分支判断都不变。
2. **重绘可能覆盖。** 如果游戏再次用原文调用入口，hook 会再翻一次（缓存挡住重复请求）；
   如果后续脚本重新 `alias` 或重定义入口，我们的别名可能被绕过。
3. ~~**控制符会被整段替换。**~~ **已解决**：宿主用 `LegacyEscapeCodec`（RGSS 码表）把一行切成
   `text` / `code` 段，只把 `text` 段送翻译，回填时按本行自己的骨架拼回，并逐项校验
   `\C[n]` / `\N[n]` / `\V[n]` / `\G` / `\I[n]` / `\|` / `\.` / `\!` / `\>` / `\<` / `\^`
   的顺序与字面（模型写进译文也会被拦下）。
4. **编码。** hook 把 Ruby 字符串原样 base64；宿主按 UTF-8 → Shift_JIS（CP932）→ GB18030
   逐档解（顺序不能换：GB18030 几乎能解任何字节，放前面会把 CP932 解成乱码）。GB18030 只是
   最后一档兜底：能被 CP932 解成“合法文本”的 GB18030 字节流仍可能解错。三档都解不了的字节流
   会走 PENDING 显示原文。RGSS1/2 的 CP932 原文在 PENDING 时会被**重编码成 UTF-8** 再回给
   hook —— 当前 mkxp-z 构建的 `Window_Message` 直接处理 CP932 原串会抛
   `invalid byte sequence in UTF-8`（§8.1 有实测）。
5. **字体。** 译文含中文时需要 CJK 字体；测试机有 `Primary font not found: Arial` 警告，但中文
   仍正常渲染（mkxp-z 回退字体）。
6. **延迟（已改为异步）。** 请求不再跑在游戏主线程上：桥 120ms 到点就回 `PENDING + 原文`，
   游戏最多等 0.2s。代价是**首遍显示原文**，同一原文下一次出现（重绘 / 重新触发对话 / 重启后）
   才显示中文。这是刻意的取舍；不要为了“首屏中文”把桥改成同步等待。
7. **安全。** 默认只连 `127.0.0.1`；协议无认证、无加密。不要监听公网，也不要把端口暴露给不可信进程。
8. **已接入现有翻译管线。** `GameLauncher` 注入 `preloadScript`，`RGSSBridge` 监听 loopback 随机端口；
   翻译来源是 `RGSSPipelineTranslator → TranslationPipeline → TranslationCache / TranslatorProvider`，
   与 MV/MZ 共用同一个缓存实现与 provider 工厂。`--play-native` 的 `--provider` / `--endpoint` /
   `--api-key` 现在真正生效（旧实现只把它们用在 `--play` 的浏览器路径上）。

### 8.1 宿主接线与三版实测（2026-11-02）

调用链（全部是现有实现，没有第二套缓存 / provider）：

```text
hook（Ruby，游戏主线程）
  → RGSSBridge（loopback，120ms 应答闸）
  → RGSSPipelineTranslator
  → LegacyEscapeCodec.skeleton(raw:engineFamily:"rgss")      只留 text 段
  → Segmenter.cacheKey(engineFamily:"rgss", profile:…)
  → TranslationPipeline.resolve
      · 命中 → PipelineOutcome.hit（≤120ms 回中文）
      · 未命中 → 入队 → TranslatorProvider.translate → TranslationCache.put（JSONL）
  → Segmenter.reassemble（按本行骨架拼回控制符）
  → LegacyEscapeCodec 控制码校验（逐项、按顺序、按字面）
  → RESP
```

缓存：`<AppPaths.root>/cache/cache.ja-zh-Hans.jsonl`（默认
`~/Library/Application Support/MochiBox/cache/`；`MOCHI_DATA_DIR` 可覆盖整个 root）。
追加写、0600、启动时 `load()`，重启后命中。

控制码段不进 key：`\C[2]赤い\C[0]` 在 XP / VX / VX Ace 三个工程里算出**同一个** key
（只取 text 段），实测都是
`sha256("rgss|ja|zh-Hans|p2|c:dialogue|g:0|赤い") = cdca5359…`。

**为什么不用 hook 侧 1.5s 等待窗口**：RGSS 是单线程，hook 的 `request` 跑在游戏主线程上；
把 1.5s 等待塞进 hook 等于每句冻结画面 1.5s（多行消息还会累加）。异步 + PENDING 只让
首屏晚一拍：主线程最多等 0.2s，PENDING 的 1.5s 只是“同一句暂不重问”的截止时刻，不阻塞
任何代码。两者实现量相当，但异步对游戏体验的伤害小一个量级。

验证用 `Fixtures/mock_translate_server.mjs --mode slow --delay-ms 800`（让首屏必定超过 120ms，
不靠时序碰运气），`--play-native` + `--provider openai --endpoint http://127.0.0.1:<port>`：

| 版本 | 首遍（空缓存） | 二遍 / 重启 | 缓存统计 |
|---|---|---|---|
| XP | OCR `赤い`；`TIMEOUT seq=N -> PENDING（后台请求中）`、`LATE seq=N source=fresh -> 已可命中` | OCR `译：赤い`；`RESP seq=N source=hit text=…`；重启首屏 `译：赤い` | 1/1 → 重启 1/0（100%） |
| VX | OCR `赤い`；同样两行（实测 seq=1） | **同一轮** OCR `译：赤い`；`RESP seq=2 source=hit text="\C[2]译:赤い\C[0]"`；重启也命中 | 同一轮 entries=1 hits=1 stores=1（50%）→ 重启 100% |
| VX Ace | OCR `赤い`；`TIMEOUT seq=N -> PENDING（后台请求中）` | 重启 OCR `译赤赤い`（OCR 把冒号并进字）；`RESP seq=N source=hit` | 重启 100% |

#### 8.1.1 同一轮内首遍原文、次遍中文（VX，2026-11-02 19:07）

上表 VX 的“同一轮”来自一次 `--play-native /tmp/vx-run`：测试注入器
`docs/evidence/rgss-bridge-2026-11-02/inject.rb` 在 `Scene_Map` 后 push 同一行两次，
第一次与第二次间隔 5.5s（避开 hook 的 1.5s PENDING 抑制窗口）。桥日志原文：

~~~text
[2026-11-02 19:07:36] TEXT seq=1 ver=RGSS2 text="\\C[2]赤い\\C[0]"
[2026-11-02 19:07:36] TIMEOUT seq=1 -> PENDING（后台请求中）
[2026-11-02 19:07:37] LATE seq=1 source=fresh -> 已可命中
[2026-11-02 19:07:41] TEXT seq=2 ver=RGSS2 text="\\C[2]赤い\\C[0]"
[2026-11-02 19:07:41] RESP seq=2 source=hit text="\\C[2]译:赤い\\C[0]"
~~~

- 第 1 次截图 `docs/evidence/rgss-bridge-2026-11-02/rgss-vx-first.png`，OCR `赤い`；
- 第 2 次截图 `docs/evidence/rgss-bridge-2026-11-02/rgss-vx-second.png`，OCR `译：赤い`；
- 完整 `bridge.txt` / `hook.txt` / `inject.txt` / `mock-requests.txt` / `cache.txt` 在同目录；
- `rgss-cache: entries=1 hits=1 stores=1 hitRate=50%`；
- mock 的 user content 是 `["赤い"]`，0 次包含 `\C[`。

**之前版本把这三行写成 `TIMEOUT → PENDING` / `LATE source=fresh`，少了 `seq=` 与 `->`，
按本节的原文为准。**

复现：

1. mock：`node Fixtures/mock_translate_server.mjs --port 64805 --mode slow --delay-ms 800 --record /tmp/rgss-evidence/mock`；
2. `mkxp.json` 的 `preloadScript` 指向测试注入器（`inject.rb`），`GameLauncher` 会把产品
   hook 排在最后；
3. 启动
   `MOCHI_DATA_DIR=/tmp/rgss-evidence/data ./build/MochiBox.app/Contents/MacOS/MochiBox --play-native /tmp/vx-run --provider openai --endpoint http://127.0.0.1:64805 --api-key test --duration 30`；
4. 标题画面按 `space` 进新游戏；第一次 push 后 1s 截第一张，`terminate_message` 后 1.5s
   再 push 同一行，1s 后截第二张。

**为什么重绘不行**：hook 收到 PENDING 后把同一 key 记入 1.5s 窗口；窗口内的
`refresh` / `process_all_text` 重绘不会再发 TEXT。要看到第二遍中文，必须让第一次消息
真正结束（`terminate_message` / 玩家按确认键）并在 1.5s 之后重新显示同一行。

控制符：桥日志 `RESP … text="\C[2]译:赤い\C[0]"`；mock 的 `requests.jsonl` 里 23 条已落盘请求
（mock 计数 24，含收尾时 1 条未落盘）的 user content 只有 `赤い` / `こんにちは` / `魔物が来た` /
`menyelamatkan dunia!` 等，**0 次**包含 `\C[` / `\N[` / `\V[` / `\G` / `\I[`。

CP932 首屏：原始 CP932 工程（`/tmp/xp-run` 的 Map001）在“回空 RESP”的旧实现下 OCR 到
`Script 'Window_Message' line 82 … invalid byte sequence in UTF-8`；改成
`PENDING + 原文(UTF-8)` 后 OCR `こんにちは`，游戏不崩。这就是 PENDING 必须带载荷的原因。

### 8.2 真实 provider 的延迟与首遍原文（2026-11-02）

环境：DeepSeek 官方 `https://api.deepseek.com`、`model=deepseek-flash`，
`timeoutSec=15`、`maxBatch=120`、`maxConcurrent=4`、`batchCharBudget=1500`、
`batchWindowMs=120`。10 条日文 RPG 台词（206 字），第 4 条含 `\C[2]…\C[0]`、
第 8 条含 `\N[1]`。原始输出在
`docs/evidence/rgss-real-provider-2026-11-02/latency.txt`。

#### 延迟

| 形态 | 请求数 | wall time |
|---|---|---|
| 10 条一批 | 1 | 1713ms（provider 1416ms + 120ms 合并窗口 + 落盘/唤醒） |
| 单条（n=8） | 8 | 823 / 932 / 936 / 997 / 1014 / 1029 / 1137 / 1227ms |

P50 = **997ms**，P90 = **1227ms**，min = 823ms（n=8）。10 条一批的 provider 耗时
1416ms，只比单条 P50 慢约 1.4 倍（含 120ms 合并窗口的墙钟 1713ms 约为 1.7 倍）：
批处理摊薄了固定开销（系统提示词、连接、排队），但**不改变首字节时间**——模型仍然要
先想完整批才吐 JSON。

token：一次 10 条请求的 `usage` 是 `prompt_tokens=331`（cache hit 128 / miss 203）、
`completion_tokens=115`、`total_tokens=446`。产品解析层只取 `choices[0].message.content`，
**不暴露 usage**；这个数字来自同一 endpoint / 模型 / 提示词的直连控制请求。

#### 与 120ms 闸的对比：首遍必原文是物理必然

- 120ms 闸 vs 最快 823ms：差 **6.9 倍**；vs P50 997ms：**8.3 倍**；vs P90 1227ms：**10.2 倍**。
- hook 的读超时是 0.2s，闸的理论上限约 180ms（留 20ms 回包），仍差 4.6 倍以上。
- 调闸没有意义：超过 200ms 后 hook 先超时，行为与 120ms 完全相同（照样显示原文）。
- 要让首屏同步出中文，只有两条路：
  1. **提前预译**：在文本显示前就入队（扫描事件页 / 数据表 / 进地图时预取），把
     “首次出现”变成缓存命中；
  2. 把 hook 改成阻塞等待 —— 每句冻结 0.8~1.2s，多行消息累加，不可接受。

结论：**首遍原文不是阈值调错，是网络 LLM 的延迟量级决定的**。120ms 闸能保证的是
“游戏主线程绝不等网络”；缓存命中时它同时满足“第二遍中文”（§8.1.1 的
`RESP … source=hit`，实测 <120ms）。

#### 译文质量

| # | 原文 | 译文（10 条一批） |
|---|---|---|
| 0 | おはよう、旅の人。この村は久しぶりに賑やかだね。 | 早上好，旅行者。这个村子好久没这么热闹了。 |
| 1 | 魔王の城は北の山の向こうにある。気をつけて行くんだぞ。 | 魔王城在北边山的那一头。路上小心啊。 |
| 2 | 薬草を三つ持ってきてくれれば、傷を治してやろう。 | 如果你能带来三株药草，我就帮你疗伤。 |
| 3 | `\C[2]鉄の剣\C[0]` | `\C[2]铁剑\C[0]` |
| 4 | お前の装備では、この先の洞窟は危険すぎる。 | 以你现在的装备，前面的洞窟太危险了。 |
| 5 | 村長がお呼びだ。広場の井戸のそばにいるよ。 | 村长在叫你。他在广场的水井旁边。 |
| 6 | 昨日の夜、森の奥で不思議な光を見たんだ……。 | 昨晚我在森林深处看到了一道奇怪的光…… |
| 7 | `\N[1]よ、よく戻った。無事で何よりだ。` | `\N[1]你、你回来了。平安无事比什么都好。` |
| 8 | 宝箱には気をつけろ。たまに罠が仕掛けられている。 | 小心宝箱。有时会设有陷阱。 |
| 9 | 旅の支度ができたら、宿屋の主人に声をかけてくれ。 | 准备好旅行后，跟旅店老板说一声。 |

- 10 条无漏译，中文通顺；控制符 **逐字保留**（`\C[2]…\C[0]`、`\N[1]` 的位置与 id 都没动）。
- 唯一瑕疵是 #7 的呼格「よ」：批次译成「你、你回来了」，单条重跑译成「哟，你回来了」。
  这是模型输出抖动，不影响控制码与段数校验；产品侧按“可接受译文”落缓存。
- #8 的「有时会设有陷阱」略生硬，但语义正确。

#### 429 的 `Retry-After`

`HTTPPoster` 现在把响应头里的 `Retry-After` 折算成毫秒并带进 `MochiBoxError`：

- 支持 **delta-seconds**（`1`）与 **HTTP-date**（IMF-fixdate / RFC 850 / asctime）；
- 上限 `K.retryAfterCapMs = 10_000`（秒数 60 → 按 10s 等；过期日期 → 0）；
- 解析失败 / 无该头 → `nil`，继续用固定退避 `500/1000/2000ms`；
- `runWithRetries` 用 `error.retryAfterMs ?? delays[attempt]`，并记一行
  `delaySource=retry-after|backoff`。

mock 证据（`--mode 429-retry --fail-count 1 --retry-after 1`）：第一次请求
`ts=1793620906009` 返回 429 + `Retry-After: 1`，第二次请求 `ts=1793620907040`，
间隔 **1031ms**（不是 500ms）。会话日志原文：

~~~text
[TranslationPipeline] 请求失败，按退避重试 attempt=1/3 code=rate_limited
  delayMs=1000 delaySource=retry-after httpStatus=429
~~~

桥日志对应 `TEXT seq=1 → TIMEOUT → LATE source=fresh`，两行最终都拿到译文
（`rgss-cache: entries=2 stores=2`）。原始文件在
`docs/evidence/rgss-real-provider-2026-11-02/429/`。

#### 其他失败面（mock）

| 模式 | 请求数 | 错误码 | 行为 |
|---|---|---|---|
| 401 | 2（每行 1 次） | `auth_failed` | 不重试；PENDING + 原文 |
| 500 | 8（每行 4 次：500/1000/2000 退避） | `bad_response` | 4 次后放弃；PENDING + 原文 |
| 坏 JSON（200 + 非 JSON） | 2（每行 1 次） | `bad_response` | 不重试、不崩溃；PENDING + 原文 |

500 的 4 次是**同一个请求体**的 4 次（首试 + 3 次重试）；两行各成一个单条块，
所以总数是 8。若一个多条目块在 4 次后仍失败，`runSubchunk` 会按
`badResponse` 对半拆块（已有的降级路径），总数会相应增加。

## 9. 本地复现

前置：`/tmp/xp-run` 里有 mkxp-z、XP 工程和 `mochi_rgss_hook.rb`。

1. 复制脚本：

```bash
cp Resources/rgss/mochi_rgss_hook.rb /tmp/xp-run/mochi_rgss_hook.rb
```

2. 写配置（相对游戏根目录）：

```json
{"preloadScript":["mochi_rgss_hook.rb"],"debugMode":false}
```

3. 起一个最小 TCP 服务（Python，收到 TEXT 就回 `【中文测试】`）：

```python
import base64, socket
REPLY = "【中文测试】".encode("utf-8")
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 47123))
srv.listen(8)
while True:
    conn, _ = srv.accept()
    f = conn.makefile("rwb")
    for raw in f:
        parts = raw.rstrip(b"\r\n").split(b"\t", 3)
        if len(parts) == 4 and parts[0] == b"TEXT":
            seq = parts[1]
            print("TEXT", seq.decode(), base64.b64decode(parts[3]).decode("utf-8"))
            f.write(b"RESP\t" + seq + b"\t" + base64.b64encode(REPLY) + b"\n")
            f.flush()
    conn.close()
```

4. 启动游戏并按确认键进 New Game：

```bash
cd /tmp/xp-run && ./mkxp-z
```

标题画面按 Space（或 Z/Enter）→ New Game。`Map001` 的 autorun 事件会自动弹出消息。

5. 截窗口并 OCR：

```bash
cd /tmp/xp-run && ./shot /tmp/xp-run/hook-msg.png
```

期望 OCR 出现 `【中文测试】`；hook 日志出现 `hooked Window_Message#refresh as RGSS1` 与 `RESP seq=...`。

## 10. 后续工作

- ~~由 `GameLauncher` 在启动前把 hook 写到游戏可写目录，或使用 app 资源里的**绝对路径**注入
  `preloadScript`；退出时清理。~~ 已完成：绝对路径注入 + 退出按原字节还原。
- ~~接真正的翻译来源（15 条测试词典）。~~ 已完成：`RGSSPipelineTranslator` 接现有
  `TranslationPipeline` / `TranslationCache` / `TranslatorProvider`；控制符分段复用
  `LegacyEscapeCodec`；缓存落盘、重启命中（§8.1）。
- ~~控制符感知分段。~~ 已完成（只送 text 段 + 回填后逐项校验）。
- 待做：服务端持久化连接 / 批量请求 / 失败指标；只对白名单场景（对话、选项、滚动文本）开启，
  避免把菜单/调试文本也送进翻译管线。
- 待做：把 RGSS 的**数据层**（Map / CommonEvent / Terms 的 401 文本）也预译进同一份缓存，
  这样首次对话就能命中，而不是“首遍原文、次遍中文”。
