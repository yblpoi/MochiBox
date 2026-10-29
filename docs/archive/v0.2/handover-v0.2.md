# MochiBox V0.2 交接文档

- 交接日期：2026-10-22 08:50（GMT+8）
- 交接人：主理人（交付总监）
- 接手对象：下一轮开发者 / 下一次会话的 Agent
- 一句话现状：**真实 MZ 游戏 `RJxxxxxx` 已能在 macOS 上启动、采集、翻译、回绘（不需要 Wine）；但最后一轮 4 项修复只完成到「源码已落地 + 自检与错误路径已复测」，全量 E2E 与 QA 复核尚未在最终二进制上跑完。**

---

## 1. 先看这三件事

1. **不要装 Wine。** Windows 版 MV/MZ 的 `Game.exe` 只是 NW.js 壳，游戏逻辑是纯 JS/HTML。本产品用「本地静态 HTTP 服务 + Chromium 内核」运行，V0.2 已实现并在真游戏上跑通。
2. **所有验证结论必须绑定 sha256。** 本项目历史上出现过 4 次「引用旧二进制/半写源码的验证结果」。本文每条结论都写了对应 sha；不要拿旧结论套新二进制。
3. **测试游戏的数据本身是简体中文**（19507 条对白全中文），而产品语言对写死 `ja → zh-Hans`。所以对它而言"翻译"是恒等映射，**只能用回声后端证明通道，不能证明译文质量**。

---

## 2. 构建与运行

```bash
cd /path/to/Mtool-M

# 构建（只依赖 Command Line Tools，无第三方依赖）
bash Scripts/build.sh                 # 产物 build/MochiBox.app（ad-hoc 签名）

# 自检（TAP；无图形会话可跑；不写用户目录）
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest

# 真游戏端到端（走产品真实启动路径；本机唯一 Chromium 内核在 Playwright 缓存里）
./build/MochiBox.app/Contents/MacOS/MochiBox --play RJxxxxxx \
  --provider passthrough --duration 150 --headless \
  --out /tmp/play.jsonl --screenshot /tmp/play.png

# 带译文（回声后端：每段前加 ◇，用于肉眼确认回绘）
node Fixtures/mock_openai_server.mjs --echo 8789 &
./build/MochiBox.app/Contents/MacOS/MochiBox --play RJxxxxxx \
  --provider openai --endpoint http://127.0.0.1:8789 --duration 150 \
  --out /tmp/echo.jsonl --screenshot /tmp/echo.png      # 去掉 --headless = 真窗口（用户可见）

# 旧入口（不变）：附着到已带调试端口的页面
./build/MochiBox.app/Contents/MacOS/MochiBox --attach <debugPort> --provider passthrough --duration 10
```

**`--duration` 为什么是 150**：`RJxxxxxx` 启动先播 `movies/LOGO.webm` + `movies/OPFULL.webm`（约 135 秒）+ 开场演出，之后才到标题。用 15 秒测必然 `captured≈0`，这是作品开场长度，不是功能没做。

### GUI
首次打开会被 Gatekeeper 拦（ad-hoc 签名、未公证）：Finder 右键 → 打开 → 再点「打开」。
UI 里的「启动」按钮和 `--play` 走**同一条** `GameLauncher` 分流逻辑。

---

## 3. 这一轮（V0.2）做了什么

| 项 | 内容 | 主要文件 |
|---|---|---|
| Web 运行后端 | 本地静态 HTTP 服务（NWListener，Range/206、流式分块、路径穿越防护）+ 浏览器解析与启动 | `Sources/Adapters/Web/StaticWebRequest.swift`、`StaticWebServer.swift`、`BrowserResolver.swift`、`WebGameRunner.swift` |
| 启动分流 | `resolveExecutable` → `resolveStrategy`：macOS `nwjs.app` 优先 → Web 后端 → 明确报错 | `Sources/Adapters/Launcher/GameLauncher.swift` |
| 端口确定性 | `sha256(canonicalPath)` 派生 + `web-ports.json` 持久表（**存档按 origin 隔离，端口漂 = 丢档**） | `Sources/Adapters/Launcher/WebPortAssignments.swift` |
| `--play` CLI | 新增入口，复用 `--attach` 的 drain 循环（四段切分，判定逻辑未改） | `Sources/App/AttachCLI.swift`、`AppMain.swift` |
| 转义码修正 | 双端改 ASCII 大小写不敏感 + 补 `\I[n]`；**只折叠比对，段值不上转** | `Sources/Domain/Segmenter.swift`、`Resources/agent_mvmz.js` |
| 错误码 | 新增 `browser_not_found` / `web_root_missing` / `web_server_failed` / `web_port_busy` / `browser_exited_early` | `Sources/Domain/Models.swift` |
| 自检 | 29 → **45** 条（新增 F 组 16 条：HTTP/端口/浏览器文案/转义码 parity/半途 stop） | `Sources/SelfTest/*CaseSupport.swift` |
| E2E | `Tests/e2e/play_e2e.sh`：真游戏 + 真浏览器，AC-2/3/4/7 硬门禁 | `Tests/e2e/play_e2e.sh` |

### 为什么转义码必须改
MZ 认码是**大小写不敏感**的（`/\x1bV\[(\d+)\]/gi` 等），且 `\I[n]`（图标）是正式码；而旧实现是大写精确匹配且没有 `I`。
本游戏 401 文本行里小写 `\c` 533 次、`\v` 104 次、`\n` 6 次；全量 37855 行里 **938 行**的转义码会被当正文送后端（模型改写即丢颜色/丢变量/丢人名）。

---

## 4. 验证到哪一步（按 sha 分，别混）

| sha256（前16） | 时间 | 做了什么 | 结果 |
|---|---|---|---|
| `26ff093cd82f5c09` | 02:18 | QA 干净重建 + 全量验收（含**窗口模式** AC-8） | AC-1/2/3/4/5/7/8 **PASS**；**AC-6 FAIL**；`play_e2e.sh` → `# pass 11 fail 0`、`# PLAY_E2E_PASS` |
| `834d603d3f3a69f8` | 08:45 | 主理人干净重建（含 F1–F4 修复源码） | `--selftest` **pass 45 fail 0**；F1/F2 已实测修好（见下）；**全量 E2E 与 QA 复核未做** |

- **AC-6 已修**（在 `834d603d` 上实测）：`--play RJxxxxxx --browser /nonexistent` → **exit 3**，文案含四要素——"请安装…"、"settings.json"、"MOCHI_BROWSER_PATH"、"（Safari 不支持 CDP…）"（`grep -E` 命中 4）。
- **非游戏目录已修**：`--play /tmp/not-a-game` → **exit 3** + `error_code: launcher_no_executable` + `play failed:` 前缀（此前是 exit 1、无 error_code、误写 `attach failed:`）。
- **F3 孤儿浏览器回收**：代码已落地（`WebGameRunner.reclaimOrphanBrowser()`：读 `<profileDir>/.mochibox-browser.pid`，仅当进程存活**且**命令行含本 profile 的 `--user-data-dir` 才 SIGTERM→SIGKILL；死 pid 则清 `SingletonLock/SingletonSocket/SingletonCookie`；e2e 脚本加 `trap cleanup_spawned`），**但未在 `834d603d` 上做运行期实测**（交接时按要求把所有后台 Chrome 停了）。
- **QA 未复核 `834d603d`**：`docs/qa-report-v0.2.md` 的结论只对 `26ff093cd82f5c09` 成立。

> 工程师在 03:19–03:21 落地 F1–F4 后，其进程因网络 502 中断，没有提交修复后的验收报告。08:45 的重建与 F1/F2 复测由主理人补做；F3 与全量 E2E 仍待补。

---

## 5. 接手后第一件该做的事（按顺序）

```bash
# 1) 确认 sha 与自检（约 30s）
bash Scripts/build.sh && shasum -a 256 build/MochiBox.app/Contents/MacOS/MochiBox
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest | tail -1     # 期望 pass 45 fail 0

# 2) 跑全量 E2E（约 8 分钟；会开真 Chrome，结束自动清）
bash Tests/e2e/play_e2e.sh                                            # 期望 # PLAY_E2E_PASS

# 3) 窗口模式 AC-8（约 3 分钟；屏幕上会真的出现游戏窗口）
node Fixtures/mock_openai_server.mjs --echo 8789 &
./build/MochiBox.app/Contents/MacOS/MochiBox --play RJxxxxxx \
  --provider openai --endpoint http://127.0.0.1:8789 --duration 150 \
  --out /tmp/ac8.jsonl --screenshot /tmp/ac8.png
# 打开 /tmp/ac8.png 肉眼确认文字带 ◇（headless 截图不算 AC-8 证据）

# 4) F3 运行期取证（造残留再启动）
#    在 browser-profiles/<gameHash>/ 下写一个 "活着的、命令行不带本 profile" 的假 pid 文件，
#    确认它不被误杀；再写一个真实的 Chromium pid，确认启动时被回收。
```

---

## 6. 已知问题与坑（按踩坑概率排序）

1. **profile 单实例锁 + 孤儿浏览器**（最高危）。用户强退/断电后，下次启动可能撞 `Failed to create a ProcessSingleton`，表现为 `browser_exited_early`。V0.2 已加 pid 文件回收与锁清理，但**运行期未验**。手工清理：
   ```bash
   lsof -nP -iTCP:39200-39409 -sTCP:LISTEN        # 看谁还占着调试端口
   pgrep -fl "ms-playwright"                      # 看还有没有 Playwright 的 Chromium
   pkill -f "user-data-dir=$HOME/Library/Application Support/MochiBox/browser-profiles"
   ```
2. **本机没有 Chrome / Edge / Brave**，只有 Safari（不支持 CDP）。唯一可用内核是 Playwright 缓存：`~/Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app`。`/Applications/Google Chrome.app` 那一级**代码有、未实测**。
3. **存档不在游戏 `save/` 目录**：浏览器模式走 localforage/IndexedDB，存在 `~/Library/Application Support/MochiBox/browser-profiles/<gameHash>/`，按 **origin（含端口）** 隔离。改端口 = 换 origin = 看不到旧存档（`web-ports.json` 里持久记录端口，别手改）。
4. **BUG-11 未修**（P1）：`agent_mvmz.js` 的 `lookup(raw, key)` 收了 `raw` 但没用，同一 `mapKey` 不同 `raw` 之间会串颜色码（`\C[2]350` 与 `350`）。修法需改下发协议或按 raw 本地重组；`Tests/qa/lookup_variant_probe.mjs` 是它的 xfail 探针。
5. **Host 侧去重仍是 16ms 帧桶**（Agent 侧是 800ms 滑动窗口，两端不同构）。修的时候必须同批改 `Tests/qa/store_probe.swift`（那里 `ts` 恒 1，会假红）。
6. **`docs/manual-acceptance.md` 的 20 项 P0 手工验收仍是"未验证"**；AC-8 只覆盖了"标题/设置窗口里能看到 ◇"。
7. **未验证清单**：MV 引擎、其它 MZ 作品、Intel 架构、Retina/多显示器缩放、长时（>10 分钟）内存曲线、真实翻译质量、GUI 人工点测。

---

## 7. 文件地图（本轮新增/修改）

新增：
```
Sources/Adapters/Web/StaticWebRequest.swift     402 行  纯逻辑：请求头/路径/穿越防护/Range/MIME
Sources/Adapters/Web/StaticWebServer.swift      737 行  NWListener 传输层：keep-alive/分块/连接管理
Sources/Adapters/Web/BrowserResolver.swift      335 行  四级浏览器解析 + 启动参数 + 失败文案
Sources/Adapters/Web/WebGameRunner.swift        508 行  编排：校验→服务→浏览器→就绪→回滚/收尾/孤儿回收
Sources/Adapters/Launcher/WebPortAssignments.swift 179 行 确定性端口 + web-ports.json
Sources/SelfTest/WebCaseSupport.swift           470 行  F 组 HTTP/端口/直连真 socket 用例
Sources/SelfTest/EscapeCaseSupport.swift        130 行  转义码表 + JS↔Swift parity
Sources/SelfTest/LauncherCaseSupport.swift      392 行  web 根/端口/文案/分流/半途 stop
Tests/e2e/play_e2e.sh                           222 行  真游戏真浏览器硬门禁
```
修改（要点）：`GameLauncher.swift`（分流/回滚/terminateWeb）、`EngineAdapter.swift`（`LaunchTransport`/`WebRunDescriptor`/`LaunchOptions`/早装注入）、`AgentInjector.swift`（`installEagerly`/`evaluateString`/hello 取最后一条）、`AttachCLI.swift`（四段切分 + `--play`）、`AppMain.swift`、`Models.swift`、`Constants.swift`、`Stores.swift`、`Segmenter.swift`、`Resources/agent_mvmz.js`、`Fixtures/mock_openai_server.mjs`（`--echo`）、`Tests/qa/skip_parity.*`（+2 样例）。

**未改**：`Sources/UI/MainWindow.swift`（mtime 仍是 10-20 12:43，`play|web|browser` 零命中）。

---

## 8. 设计约束（改代码前必读）

- 核心层（`Domain|Adapters|Infra|SelfTest` 与 `App/{AttachCLI,Constants}.swift`）**不得 import SwiftUI/AppKit**；`Scripts/build.sh` 第一步会以退出码 2 拦。
- 三种身份不得混用：**行身份** `surface + raw`、**翻译身份** `mapKey`、**缓存键** `cacheKey`。
- `agent_mvmz.js` 与 `Segmenter.swift` 的码表/跳过判据必须**逐值一致**（`Tests/qa/skip_parity.sh` 守这条）；改一端必须同批改另一端。
- 静态服务不得整读文件：唯一允许读法是 `FileHandle.seek(toOffset:)` + `read(upToCount:)`（**nil = EOF，不是错误**，当错误会丢最后一块，症状是音频 99% 卡住）。门禁：
  ```bash
  grep -rn "contentsOf\|readToEnd\|Data(seeking:" Sources/Adapters/Web/   # 必须 0 命中
  ```
- `LaunchHandle.port` 语义仍是**调试端口**；静态服务端口在 `WebRunDescriptor.httpPort`。

---

## 9. 文档索引

| 文档 | 用途 |
|---|---|
| `.workbuddy/briefs/2026-10-22-real-game-v02.md` | 本轮立项说明（实机侦察结论 0.1–0.7、范围、验收标准） |
| `docs/archive/v0.2/architecture-v0.2-web-runner.md` | 架构设计（HTTP/浏览器参数/分流回滚/`--play`/转义码/风险，1243 行） |
| `docs/qa-report-v0.2.md` | QA 独立验收（**只对 `26ff093c` 成立**；AC-6 判红与 5 条不一致记录在这里） |
| `docs/archive/v0.2/delivery-scope-v0.2.md` | 本轮实际交付范围与取舍 |
| `docs/qa-addendum.md` | 历史 QA 结论 + 本轮追加（小写码缓存不命中属预期、headless 截图不算 AC-8） |
| `Scripts/VERIFY.md` | 更早的工程师实测记录（V0.1 快照） |
| `docs/prd.md` / `docs/architecture.md` | V0.1 需求与设计（未改） |

---

## 10. 下一轮建议（按性价比）

1. **补 F3 运行期验证 + 加 `profile_locked` 错误码**：把"锁清不掉"从"浏览器起不来"里拆出来，文案直接指向处置动作。
2. **修 BUG-11**：按 raw 本地重组可绘制串（译文文本按 `cacheKey` 共享，控制码按 raw 各自重组），这是唯一还影响"看得见"的老问题。
3. **把 `Settings.browserPath` 接进设置页**（本轮 `MainWindow.swift` 冻结，只能手改 json / `MOCHI_BROWSER_PATH`）。
4. 语言对可选（PRD D-1 目前冻结 `ja→zh-Hans`）——遇到中文游戏时产品语义会变成"什么都不翻"，需要产品决策。

---

## 11. 环境快照（交接时）

- macOS 27.0.1 / arm64；Swift Command Line Tools；Node 22（仅测试脚本用）
- **后台 Chrome：0 个**（已停）。调试端口区间 `39200–39409` 无监听。
- 探针服务（`python -m http.server 8899` / echo mock `8788`）也已停。
- Playwright 缓存 Chromium：`chromium-1248`（唯一可用内核）
- 无 Wine、无 CrossOver、无 Google Chrome/Edge/Brave；有 Safari（不支持 CDP）
