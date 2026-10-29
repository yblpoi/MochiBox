# `Fixtures/e2e_game` —— 内置内核 E2E 的确定性 MZ 夹具

这是一个**合成替身**，不是 RPG Maker 运行时。它的存在只为一件事故取证：
「WKWebView 内核 + agent_mvmz.js + 翻译管线」这条链路能不能在**没有 Chrome / 没有 CDP** 的前提下，
从一个可重复的最小页面跑到 `--out` JSONL。

## 为什么不复用 `Fixtures/mv_stub/`

| | `mv_stub` | `e2e_game` |
| --- | --- | --- |
| 引擎识别 | 靠目录形状**不命中**任何引擎（它只给 contract 层用 `vm` 跑内联脚本） | 命中 `mz`：`js/rmmz_core.js` 存在即可（`EngineDetector.swift:149-151` 不读内容） |
| 页面布局 | 单文件内联脚本，无静态资源 | 真实发行版布局：`index.html` + `js/` + `data/`，由 `StaticWebServer` 托管 |
| 窗口尺寸 | canvas 816×400，与 `System.json` 无关 | canvas 与 `data/System.json` 都是 816×624，`fitWindowToCanvas` 不会二次放大 |
| 用途 | contract 层的 `vm` 沙箱 | 进程级 E2E（真 WKWebView、真 unix socket、真 HTTP 翻译后端） |

`mv_stub` 的 900 行里大部分是 contract 层需要的假引擎对象与绘制模拟；
内核层只需要"能装上四个 hook + 能被 `__e2e` 驱动"，所以这里刻意只留 350 行。

## 结构

```
Fixtures/e2e_game/
  index.html            # canvas 816x624（id="game"），先 canvas 后同步 script
  js/rmmz_core.js       # 空壳：唯一职责是让 EngineDetector 命中 MZ
  js/rmmz_objects.js    # 空壳
  data/System.json      # gameTitle=E2E Fixture / advanced 816x624（窗口标题与内容区尺寸的唯一来源）
  data/Map001.json      # 最小地图数据（夹具不跑地图逻辑）
  engine_stub.js        # 假引擎 + window.__e2e 测试驱动 API
  README.md
```

**根目录绝对不能出现** `*.pck` / `Gameexe.ini` / `project.godot` / `Data.wolf` /
`BasicData/*.dat` / `*_Data/globalgamemanagers` / `Game.ini` / `*.xp3` / `data/system/Config.tjs`，
否则 `EngineDetector` 会先命中别的引擎（优先级见 `EngineModels.swift`），内核不会启动。

## `window.__e2e` 驱动面

| 方法 | 语义 |
| --- | --- |
| `push(text)` | 走**真实链路**：`$gameMessage._texts = [text]` → `Window_Message.prototype.startMessage` → Agent 的 hook → `emit('text')` |
| `pushMany([...])` | 一次多行消息；每行各产生一条 TextEvent |
| `pushAt(index, text)` | 把第 `index` 行换成 `text` 后重新分页（其余行原样） |
| `drawTextEx(text)` / `drawBitmap(text)` | 直接打另两个采集 surface（`Window_Base.drawTextEx` / `Bitmap.drawText`） |
| `repaint()` | 等价于 `window.__stubRepaint()`：只画 canvas，**不产生 TextEvent** |
| `version` | 驱动面版本（当前 `1`） |
| `originals` | `install()` 之前的四个原始函数引用，供 K8 验证 `uninstall()` 是否真的复原原型 |

**不要绕过 `push` 直接往 `__mochibox` outbox 塞信封**：那样测不到 800ms 去重与
`skipReason` 判定（`Resources/agent_mvmz.js` 的 `shouldEmitFor` / `skipReasonOf` 都在
`collect()` 里，只有真实绘制路径会经过）。

## 并发注意

同一 `gameDir` 的静态服务端口是**确定性派生**的（当前 39330），所以内核层用例必须
**串行**执行；并行跑两个 case 会得到 `port_unavailable`（那是 F10 刻意验证的场景，不是夹具故障）。

## 手工验证

```bash
# 1) 构建
bash Scripts/build.sh

# 2) 跑夹具（passthrough：只验证采集，不联网）
DATA=$(mktemp -d)
MOCHI_E2E=1 MOCHI_DATA_DIR="$DATA" \
  ./build/MochiBox.app/Contents/MacOS/MochiBox \
  --play Fixtures/e2e_game --control /tmp/e2e-fixture.sock --duration 20 --out /tmp/e2e-fixture.jsonl

# 期望 stdout 里至少有三行：
#   play: ... engine=mz ...
#   play: http=<port> debug=0 page=http://127.0.0.1:<port>/index.html kernel=embedded content=816x624 scale=<s>
#   play: control=ready path=/tmp/e2e-fixture.sock kernel=embedded

# 3) 另开一个终端，用控制通道推一句
node -e '
const net=require("net");const s=net.createConnection("/tmp/e2e-fixture.sock");
s.setEncoding("utf8");
s.on("data",d=>{process.stdout.write(d);s.end();});
s.on("connect",()=>s.write(JSON.stringify({id:1,op:"eval",expression:"__e2e.push(\"こんにちは\")"})+"\n"));
'
wc -l /tmp/e2e-fixture.jsonl   # → 1
```

退出码约定由产品决定（`AttachCLI.report`）：`captured==0` 或非 passthrough 且
`translated==0` → `1`；否则 `0`。`quit` 控制指令固定 `0`（驱动端主动收工）。
