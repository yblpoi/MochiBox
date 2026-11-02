# RGSS 文本通道：可行性验证与 hook 协议

面向：准备把 XP / VX / VX Ace 的**屏上文本**接进 MochiBox 的人。
脚本：`Resources/rgss/mochi_rgss_hook.rb`（可复用骨架，尚未接入 `GameLauncher`）。
结论一句话：**不要用 `customScript`；用 `preloadScript` + `TracePoint(:end)` 延迟挂钩，三版分别认
`process_all_text` / `start_message` / `refresh`，协议手写，失败一律放行原文。**

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
← MochiBox:  RESP	<seq>	<base64(译文)>
```

| 字段 | 说明 |
|---|---|
| `seq` | 进程内自增十进制；响应必须原样带回，不匹配就丢弃 |
| `version` | `RGSS1` / `RGSS2` / `RGSS3`，不要用带空格的 “VX Ace” |
| `base64` | UTF-8 字节的 `pack('m0')`，严格模式、无换行；解码用 `unpack1('m0')` |
| 原文 | 可以含 `\n`（XP 的多行是一个字符串）；base64 把它藏起来，不会破坏行协议 |
| 多行 | VX/VX Ace 的 `texts` 数组**每个元素一条 TEXT**；XP 整串一条 |

服务端约束：

- 必须在同一条连接上回到对应 `seq`；
- 译文必须是合法 UTF-8；空串或非法 UTF-8 会被 hook 丢弃；
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
- 失败后 2 s 冷却，避免服务端没起时每条消息都卡 0.2 s；
- 整个 hook 体 `rescue Exception`，**绝不让异常冒到游戏主循环**；
- 实测：黑洞服务端（accept 后不回复）阻塞 `0.206 s` 后放行原文（§7.2）。

### 6.4 缓存

- `原文 -> 译文` 和 `译文 -> 译文` 都进缓存（最多 256 条）；
- 反向登记是为了防止下一轮 `refresh` / `process_all_text` 拿到已经替换过的译文再请求一次；
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
3. **控制符会被整段替换。** 当前骨架把整行当不透明文本发给服务端；`\C[n]`、`\N[n]`、`\.`、`\|`、
   `\!`、`\>` 等控制符不会自动保留。接产品前必须做“控制符分段 + 只翻可见文本”，否则中文能显示，
   但颜色、停顿、名字替换会坏。
4. **编码。** hook 把 Ruby 字符串原样 base64，不做转码；本次 XP fixture 是 UTF-8。RGSS1/2 的
   CP932 工程或 GB18030 汉化工程，服务端要先按工程编码解码，否则会乱码或解码失败（见 §5）。
5. **字体。** 译文含中文时需要 CJK 字体；测试机有 `Primary font not found: Arial` 警告，但中文
   仍正常渲染（mkxp-z 回退字体）。
6. **延迟。** 请求在游戏主线程同步执行；单行最坏 0.2 s，多行消息会累加。缓存和 2 s 冷却只能兜底，
   产品化建议预取/批量/异步，或把超时再压小。
7. **安全。** 默认只连 `127.0.0.1`；协议无认证、无加密。不要监听公网，也不要把端口暴露给不可信进程。
8. **未接入产品。** `GameLauncher` 没有改；本文件只交付脚本与文档。

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

## 10. 后续接入（本次不做）

- 由 `GameLauncher` 在启动前把 hook 写到游戏可写目录，或使用 app 资源里的**绝对路径**注入
  `preloadScript`；退出时清理。
- 服务端持久化连接、批量请求、控制符感知分段、失败指标与超时策略。
- 只对白名单场景（对话、选项、滚动文本）开启，避免把菜单/调试文本也送进翻译管线。
