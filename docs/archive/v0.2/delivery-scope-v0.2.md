# 交付范围 · V0.2（Web 运行后端）

> 对应设计：`docs/archive/v0.2/architecture-v0.2-web-runner.md`（任务表 §10，T1–T5）。
> V0.1 的范围见 `docs/archive/v0.1/delivery-scope-v0.1.md`，本文只写 V0.2 增量。

## 一句话

**Windows 发行版（带 `Game.exe` 的 MV/MZ 目录）现在能在 macOS 上直接跑起来并逐句翻译，不需要 Wine。**

原因不是"我们兼容了 Windows"，而是那类发行版本质是**一个静态网站 + 一个 NW.js 外壳**：
`Game.exe` 只是 NW.js 的 Windows 启动器。把目录静态托管在回环地址上、让 Chromium 内核打开
`index.html`，引擎就跑起来了 —— 与"在 Windows 上双击 `Game.exe`"是同一条代码路径。

## 交付了什么

| 能力 | 用户可见行为 |
|---|---|
| Web 运行后端 | `--play <游戏目录>`：一条命令完成"起静态服务 → 拉浏览器 → 注入 Agent → 采集/翻译 → 收尾" |
| 静态托管 | 只读、**只绑回环**（`127.0.0.1`）、HTTP/1.1 keep-alive + Range（206/416）+ HEAD |
| 端口确定性 | 同一 `webRoot` 永远同一个端口（`39310–39409`），持久化在 `web-ports.json` |
| 浏览器解析 | 四级：`--browser` → `MOCHI_BROWSER_PATH` → `settings.json.browserPath` → `/Applications` Chrome 族 → Playwright 缓存 |
| 失败回滚 | 任一步失败都收干净：浏览器进程、监听端口、在飞连接、profile 锁 |
| 转义码表 | 大小写不敏感（MZ 自身正则就是 `/gi`），补齐官方 `\I[n]`；双端（Swift / JS）同版本号 |
| 测试资产 | `mock_openai_server.mjs --echo`（回声后端）、`Tests/e2e/play_e2e.sh`（真游戏硬门禁） |

## 刻意不做（范围内明确排除）

1. **不跑 `Game.exe`、不用 Wine**：检测到只记一行日志。不改、不删、不重命名用户盘上任何文件。
2. **不声称"支持所有 MV/MZ"**：真机只验过 `RJxxxxxx`（MZ 1.5.0 + 自定义运行时 + 插件）。
   其他作品属未验证范围，遇到问题按"新作品适配"处理，不是"回归"。
3. **不做字体注入**：中文是否显示取决于游戏自带字体（部分作品会缺字形）。
4. **不修 BUG-11**（同 mapKey 不同 raw 时控制码可能丢/加，P1）：按范围约定本迭代不修。
5. **不做窗口内可见性验收**：`--headless` 只证明"服务/注入/捕获/回绘"链路，
   "用户肉眼能看到译文"由 QA 的窗口模式任务负责。

## 验收证据（本机实测，2026-10-22）

### 自动化

```
bash Scripts/build.sh                        → exit 0（无 error）
--selftest                                   → pass 45 fail 0（含 F 组 16 条）
bash Tests/qa/skip_parity.sh                 → pass=9 fail=0
node Tests/qa/emit_contract_probe.mjs        → pass=7 fail=0
bash Tests/e2e/play_e2e.sh                   → pass 11 fail 0（PLAY_E2E_PASS，真游戏 + 真浏览器）
```

`play_e2e.sh` 的逐项输出（本轮实跑）：

```
ok   - AC-2 退出码 0
ok   - AC-2 captured=4 > 0
ok   - AC-2 采集落盘非空（4 行）
ok   - AC-2 打印了 http/debug 端口（http=39360 debug=39227 …）
ok   - AC-2 结束后静态端口 39360 已释放
ok   - AC-3 退出码 0
ok   - AC-3 translated=3 > 0
ok   - AC-3 页面 __mochibox.probe().replaced=3 > 0（回绘成立）
ok   - AC-3 jsonl 里有 status=translated 的行（3 条）
ok   - AC-3 译文带 echo 前缀 ◇（肉眼可辨，证明确实是后端返回的文本）
ok   - AC-4 两次运行静态端口一致（39360）—— 存档 origin 不会漂
```

### 真游戏（`RJxxxxxx`）

| 验收 | 命令要点 | 结果 |
|---|---|---|
| AC-2 | `--play RJxxxxxx --headless --provider passthrough --duration 150` | `captured=4 translated=3`；落盘文本是标题菜单 **新游戏 / 继续游戏 / 设置** |
| AC-3 | 同上 + `--provider openai --endpoint <echo>` | `translated=3`、页面 `probe().replaced=3`，jsonl 里译文为 `◇新游戏 / ◇继续游戏 / ◇设置` |
| AC-4 | 同一 `webRoot` 两次运行 | 两次都是 `39360`，存档 origin 不漂 |
| AC-7 | 运行结束 | 浏览器进程退出、静态端口 39360 立刻空闲、会话表归零 |

### 一个必须写清的实测事实

`RJxxxxxx` **启动会先播一段 135 秒的 OP 影片**，播完才进标题。所以：

- `--duration 15` 的 `captured` 只能是 0/1 —— 画面里还没有任何引擎文本；
- `--duration 150` 才能看到标题菜单被捕获并回绘。

**这不是功能没做，是作品自己的开场长度。** E2E 默认 `MOCHI_E2E_DURATION=150`，
换别的作品可以调小。

## 关键设计取舍（为什么这么做）

1. **早装 hook，而不是"等引擎符号就绪再注入"**：MZ 从 boot 到"画完第一屏并停下等输入"
   只要 1–2 秒。等 `Window_Base` 就绪再注入，开场白已经画完；玩家不动，页面就再也不会
   `drawText`，整轮 `captured` 只有 boot 期的一两个杂字。现在改为**反复尝试 `install()`，
   一有 `Window_Base` 立即挂上**（轮询 80ms，每次只是一条 `Runtime.evaluate`）。
2. **静态端口确定性派生**：MZ 存档在 IndexedDB，按 **origin** 隔离；端口一变就等于丢档。
   所以端口不是"随便找一个空的"，而是 `sha256(路径)` 派生 + 持久表 + 线性探测。
3. **禁整读**：800MB 的 `.ogg` 整读会直接打爆内存。静态服务只允许
   `FileHandle.seek(toOffset:)` + `read(upToCount:)` 分块链式发送；
   目录列举走 `readdir`（`Sources/Adapters/Web/` 里 `contentsOf` 门禁 0 命中）。
4. **`stop()` 与 `start()` 共用同一条收尾路径**：`start()` 可能停在
   "浏览器已起 / CDP 未就绪"，只停服务会把浏览器留在那里占端口 —— 下一次启动就变成
   假 `browser_exited_early`。自测 `web_runner_stop_partial` 对三种中途状态各断言一次。
5. **残留单实例锁的判定不只看 `kill(pid, 0)`**：僵尸进程与 pid 复用都会让它返回 0，
   于是"清不掉的锁"被当成"有实例在用"，下次启动直接失败。改用 `proc_pidpath` 确认
   pid 真的是浏览器。

## 未验证（诚实清单）

- 只在一台机器（Apple Silicon / macOS 26）上验过；Intel、外接显示器、多显示器缩放未验。
- 只用 Playwright 缓存的 Chromium 1248 验过；`/Applications/Google Chrome.app` 这一级
  在本机不存在，属"代码有、未实测"。
- 除 `RJxxxxxx` 外的作品（含 MV）未做真机验证。
- 长时运行（>10 分钟）的内存曲线未测；架构 §11 R3 的"RSS 增长 < 8MB"按主理人裁定
  改为"32MB 大文件单次 GET 断言 `Content-Length` 与收到字节数"，不做进程内存断言。
- 窗口模式下的可见性、缩放、Retina 渲染未验（QA 负责）。
