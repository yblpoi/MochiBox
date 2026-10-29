# MochiBox V0.3 交接文档

- 交接日期：2026-10-22 10:20（GMT+8）
- 交接人：主理人（交付总监）
- 接手对象：下一轮开发者 / 下一次会话的 Agent
- 一句话现状：**V0.2 遗留的两项待修（BUG-11 控制码串味、`profile_locked` 错误码）已修复并在新二进制 `96a87474` 上通过全量回归；唯一没拿到的是 AC-8 窗口模式（受管环境无法取证，成因未定位）。**

---

## 1. 先看这三件事

1. **不要装 Wine。** Windows 版 MV/MZ 的 `Game.exe` 只是 NW.js 壳；本产品用「本地静态 HTTP + Chromium 内核」运行，V0.2 已实现。
2. **所有验证结论必须绑定 sha256。** 本轮又栽了一次：基线 `834d603d` 在 09:54 被一次**有意的**重建覆盖，二进制不可恢复、源码也已变更，**任何新结论都不能再引用它**（详见 §4）。
3. **AC-8 是未验证项，不是已通过项。** 历史文档（`../v0.2/handover-v0.2.md` §4、`qa-addendum.md`）里"AC-8 PASS"的说法，在受管执行环境下**不可复现**。别把它当既成事实。

---

## 2. 构建与运行

```bash
cd /path/to/Mtool-M

# 构建（只依赖 Command Line Tools）
bash Scripts/build.sh                 # → build/MochiBox.app（ad-hoc 签名）
shasum -a 256 build/MochiBox.app/Contents/MacOS/MochiBox
shasum -a 256 build/MochiBox.app/Contents/Resources/agent_mvmz.js   # 必须与 Resources/agent_mvmz.js 同 sha

# 自检（期望 pass 45 fail 0）
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest | tail -1

# 全量 E2E（真游戏 + 真 Chromium，约 5.5 分钟；全程 headless）
bash Tests/e2e/play_e2e.sh            # 期望 # PLAY_E2E_PASS

# 双端一致 + BUG-11 探针
bash Tests/qa/skip_parity.sh          # 期望 pass=9 fail=0
node Tests/qa/lookup_variant_probe.mjs build/MochiBox.app/Contents/Resources/agent_mvmz.js   # 期望 9/9

# 真游戏手动跑（窗口模式；本机唯一内核在 Playwright 缓存）
node Fixtures/mock_openai_server.mjs --echo 8789 &
./build/MochiBox.app/Contents/MacOS/MochiBox --play RJxxxxxx \
  --provider openai --endpoint http://127.0.0.1:8789 --duration 240 \
  --out /tmp/ac8.jsonl --screenshot /tmp/ac8.png
```

**为什么 `--duration` 至少要 150 / 窗口模式要 240**：`RJxxxxxx` 开场播 LOGO + OP 约 135 秒。headless 下标题菜单文本出现在 `ts≈145s`（本轮实测 3 条），所以 150 秒是**必需**而非浪费；窗口模式下同一时刻仍在黑帧，需要 ≥240s。

**构建纪律（本轮新增）**：验证在飞时**禁止** `rm -rf build`。要留记录就产出到 `build/archive/<sha前8>/`。本轮的基线就是被我放行的一次原地重建打掉的。

---

## 3. 这一轮（V0.3）做了什么

| 项 | 内容 | 主要文件 |
|---|---|---|
| BUG-11 修复 | `lookup(raw, key, rawSegments)` 按 **raw 骨架** 本地重组：code 段发本行自己的码值、text 段取下发译文段 | `Resources/agent_mvmz.js`（831→952 行） |
| 三条出口（关键设计） | ①有 segments 且段数不符 → **画原文**（绝不重放别人的码值，宁可不译也不串人名）②无 segments → 回退 `translatedRaw` ③空串 → 未命中 | 同上 `lookup:374-398` |
| 可观测降级 | `state.mergeFallback` 计数进 `probe()`，正常会话必须为 0 | 同上 |
| 探针升级 | `lookup_variant_probe.mjs` 从"只打印 XFAIL、退出码恒 0"改成 **C1–C9 表驱动硬门禁**，失败即 exit 1 | `Tests/qa/lookup_variant_probe.mjs` |
| `profile_locked` 错误码 | 新增 `case profileLocked = "profile_locked"`；`AttachCLI.environmentCodes` 同步（漏了会掉回 exit 1 且不打 `error_code:`） | `Sources/Domain/Models.swift`、`Sources/App/AttachCLI.swift` |
| 锁门禁 | `clearStaleSingletonLocks` 改为返回 `ProfileLockState{clear / heldByLiveBrowser / unremovable}`；门禁插在 **回收之后、起监听之前** | `Sources/Adapters/Web/WebGameRunner.swift:70-105, 148-162, 478-536` |
| 一个码两种文案 | held 给"关掉占用实例 + `pkill`"；unremovable 给 `chflags -h nouchg` + `rm -f` + `ls -ldO` + `MOCHI_DATA_DIR` 逃生；`underlying` 带 `reason=held|unremovable` | 同上 `profileLockError:542+` |

### 为什么 BUG-11 只能本地重组
`SessionController.swift:435-445` 的 `delivered[cacheKey]` 命中分支**只写 stream 后 return，不下发**——"同一 mapKey 的不同 raw 各推一条"这条路根本不存在。所以修法只能是本地重组，**不改下发协议**。

### 为什么硬失败只认 `SingletonLock`
`SingletonSocket` / `SingletonCookie` 残留清不掉时 Chromium 其实还能起来；对它们硬失败会把"本来能跑"的机器挡在门外。误报比文案误导更难受。

---

## 4. 验证到哪一步（按 sha 分，别混）

| sha256（前16） | 时间 | 状态 | 结果 |
|---|---|---|---|
| `834d603d3f3a69f8` | 09:37–09:43 | **二进制已被覆盖，不可复现** | selftest 45/0；E2E 11/0 `PLAY_E2E_PASS`；§8 门禁 0 命中。**不可再引用做新结论** |
| `96a87474adb67d75` | 09:54–10:15 | **当前有效** | 见下，11 项 |

`96a87474` 实测（全值 `96a87474adb67d75364a2e040c45fb91eda715f4cdd561b7b0573f7f518b7279`，2403888 B；冻结副本 `/tmp/MochiBox-96a87474.app`）：

| 项 | 结果 |
|---|---|
| `--selftest` | **pass 45 fail 0**，exit 0 |
| `play_e2e.sh` | **pass 11 fail 0** + `PLAY_E2E_PASS`，5m37s；AC-2 captured=4、AC-3 translated=3 / `replaced=3`、AC-4 两次均 39360；跑前跑后 sha 一致 |
| `skip_parity.sh` | pass=9 fail=0 |
| BUG-11 探针（**打包内** agent） | **9/9 PASS**，exit 0（C1–C9 含小写码不上转、`\N[2]` 不串人名、段数不符画原文） |
| `profile_locked` / held | exit **3**，`error_code: profile_locked`，`reason=held`，`ProcessSingleton` 0 行（门禁确在拉浏览器前） |
| `profile_locked` / unremovable | exit **3**，`reason=unremovable`（`chflags -h uchg` 构造），`ProcessSingleton` 0 行 |
| 误报证伪 R1 干净 profile | exit 0，无 `error_code` |
| 误报证伪 R2 死 pid 残锁 / 可清残锁 | exit 0、连续两跑均 exit 0，旧锁被静默清掉 |
| F3 负例 | `.mochibox-browser.pid` 指向活 `sleep`(pid **19357**) → 启动前后均 **ALIVE**，未误杀 |
| F3 正例 | 残留 Chrome(pid **19452**) → `kill -0` **ALIVE→DEAD**，新实例正常起，`browser_exited_early` 0 次 |
| AC-8 窗口模式 | **未覆盖**（见 §6） |

---

## 5. 接手后第一件该做的事

```bash
# 1) 确认二进制与资源没被动过（约 10s）
shasum -a 256 build/MochiBox.app/Contents/MacOS/MochiBox        # 期望 96a87474…
shasum -a 256 build/MochiBox.app/Contents/Resources/agent_mvmz.js # 期望 842a3c0b…
./build/MochiBox.app/Contents/MacOS/MochiBox --selftest | tail -1 # 期望 pass 45 fail 0

# 2) 补 AC-8（唯一硬缺口，约 4 分钟，必须有真实桌面会话）
node Fixtures/mock_openai_server.mjs --echo 8789 &
./build/MochiBox.app/Contents/MacOS/MochiBox --play RJxxxxxx \
  --provider openai --endpoint http://127.0.0.1:8789 --duration 240 \
  --out /tmp/ac8b.jsonl --screenshot /tmp/ac8b.png
# 判据（三条全中才算过）：jsonl 里 ≥1 条 status=translated；截图非空白；界面上能看见 ◇
```

---

## 6. 已知问题与坑（按踩坑概率排序）

1. **AC-8 未验证（最高危）**。共 4 次尝试，分两类症状：
   - 2 次被工具沙箱挡在删锁上 → 旧代码报 `browser_exited_early`（这正是 `profile_locked` 要替换的形态）；
   - 1 次跑满 150s：`probe.installed=true`、`captured=1`、**整帧纯黑**（像素采样 2560×1264、100% `(0,0,0)`、distinct=1）、0 条译文、exit 1、**无错误码**；`hooks` 只认出 `Bitmap.drawText`（`Window_Base.drawText*` / `Window_Message.startMessage` 全缺 → 游戏 JS 主逻辑未起）；
   - 1 次**全新 profile** 跑窗口模式：`captured=0`，浏览器日志直接给出 `sandbox initialization failed: Operation not permitted` → `aperitif: Failed to initialize sandbox` → `GPU process exited unexpectedly: exit_code=6` → `FATAL … GPU process isn't usable. Goodbye.` → 浏览器自杀 → `attach_failed`。
   
   **已排除**：①"沙箱挡 mach rendezvous 导致渲染死亡"（时间戳落在收尾 SIGTERM，已撤回）；②"真实 profile 累积状态"（全新 profile 同样失败）。
   **当前最合理解释**：产品只在 headless 分支加 `--no-sandbox`，本受管环境的 Chrome 自身 sandbox 初始化被拒。但**不可据此断言产品窗口模式有缺陷**——同一环境下 150s 那次确实连上过（`installed=true`）。真机是否正常**仍未取证**。
2. **BUG-12 候选（P1，本轮不修）**：窗口模式"静默假成功"——渲染没起来时产品仍报 `已连接 / 已注入 / probe.installed=true`，只有 `captured≈1` 与空白帧能看出来，**无任何错误码**。修法属产品决策（补渲染存活探针 vs 降级为显式错误）；**不得改退出码、不得改 status 语义**，否则 AC-2/AC-8 口径整体漂移。
3. **`TextStreamStore.swift:165` 是 BUG-11 的 Host 侧同型点（未修）**：`rows[index].translated = translatedRaw` 会把先到行的 raw 填给同 key 的所有行。只影响显示层，不影响计费/缓存/跳过/去重。
4. **受管环境的 unlink 凭证差异（易误判成 bug）**：本环境下真实 profile 的 `Singleton*` 在进程域里 unlink 返回 EPERM（`NSCocoaErrorDomain 513` / `NSPOSIXErrorDomain 1`），Chromium 自己同样 Abort，而提权 bash 可删。所以那时门禁报 `reason=unremovable` 是**真话**；**真机上不该出现**，别据此下"用户也会遇到"的结论。
5. **`lookup` 的空串契约是暗礁**：`processText:593` 用 `hit !== null` 判命中。当前三条出口都拦住了空串；谁把 `lookup` 改成"空串也算命中"，整行文字会被**静默擦白**（不报错、不计数，只有截图能发现）。
6. **存档按 origin 隔离**，在 `~/Library/Application Support/MochiBox/browser-profiles/<gameHash>/`（IndexedDB），不在游戏 `save/`。`web-ports.json` 里的端口别手改。
7. **未验证清单**：MV 引擎、其它 MZ 作品、Intel 架构、Retina/多显示器、长时（>10 分钟）内存曲线、真实翻译质量（本作数据本身是简体中文，ja→zh 等于恒等）、GUI 人工点测、`Settings.browserPath` 进设置页（`MainWindow.swift` 本轮仍冻结）。

---

## 7. 文件地图（本轮新增/修改）

```
修改：
Resources/agent_mvmz.js              831→952  lookup 三参 + mergeBySkeleton + mapKeyOfSegments 唯一实现 + mergeFallback
Sources/Domain/Models.swift          + profileLocked 错误码 / uiMessage 分支 / retryable=false
Sources/Adapters/Web/WebGameRunner.swift  + ProfileLockState / 门禁 148-162 / clearStaleSingletonLocks 改返回 / profileLockError
Sources/App/AttachCLI.swift          + environmentCodes 加 .profileLocked（漏了退出码会掉回 1）
Tests/qa/lookup_variant_probe.mjs    重写为 C1–C9 表驱动硬门禁（失败 exit 1）
Tests/qa/final-sha256.txt            重基线到 96a87474（含两个 agent sha 必须相等）

新增：
docs/archive/v0.3/architecture-v0.3-fixes.md      两项修复的设计（含 §3.3 降级矩阵、§⑦ 风险表 R1–R15）
docs/qa-baseline-834d603d.md         基线取证（三项 PASS + AC-8 三次尝试 + 基线被覆盖时间线）
docs/qa-report-v0.3.md               新 sha 回归（11 项 + 未验证清单 + BUG-12 候选）
docs/archive/v0.3/handover-v0.3.md                本文件
```

---

## 8. 设计约束（改代码前必读，含本轮新增）

- 核心层（`Domain|Adapters|Infra|SelfTest` 与 `App/{AttachCLI,Constants}.swift`）**不得 import SwiftUI/AppKit**；`build.sh` 第一步以退出码 2 拦。
- 三种身份不得混用：**行身份** `surface + raw`、**翻译身份** `mapKey`、**缓存键** `cacheKey`。**本轮新增推论**：同 mapKey 的译文文本可共享，但**控制码必须按本行 raw 重组**（这是 BUG-11 的正解）。
- **`mapKey` 只能有一个实现**：`agent_mvmz.js:215 mapKeyOfSegments`，`mapKeyOf` 是薄壳。别再长出第二份。
- `agent_mvmz.js` 与 `Segmenter.swift` 的码表/跳过判据必须**逐值一致**（`Tests/qa/skip_parity.sh` 守）；改一端必须同批改另一端。
- 静态服务不得整读文件：唯一允许读法是 `FileHandle.seek(toOffset:)` + `read(upToCount:)`（nil = EOF，不是错误）。门禁：
  ```bash
  grep -rn "contentsOf\|readToEnd\|Data(seeking:" Sources/Adapters/Web/   # 必须 0 命中
  ```
- 错误码要能被脚本判：**新增环境缺口类码必须同步加进 `AttachCLI.environmentCodes`**，否则 `--play` 掉回 exit 1、不打 `error_code:` 行。
- **"门禁在绑端口之前"只能靠代码位置证明，不能用运行时缺失去证明**。`play: http=` 那一行是 `launcher.launch()` **成功返回之后**才打印（`AttachCLI.swift:480` 附近），所以"没有这行"只等价于"launch 抛了"，分不清是在绑端口之前还是之后。反例就在本仓：F 组 selftest 的 `browserNotFound` 是在**起监听之后**才抛的，它同样没有 `play: http=` 行。要运行时证据就用 `nc -z` 断言端口不通，或断言缺"Web 运行后端已启动"日志。

---

## 9. 文档索引

| 文档 | 用途 |
|---|---|
| `docs/archive/v0.2/handover-v0.2.md` | 上一轮交接（V0.2 Web 后端；其 §4 的 AC-8 PASS 口径已被本文件 §6 推翻） |
| `docs/archive/v0.3/architecture-v0.3-fixes.md` | 本轮两项修复的设计与风险表（R13 空串暗礁 / R14 BUG-12 / R15 撤回的错归因） |
| `docs/qa-report-v0.3.md` | **当前有效的验收结论**（只对 `96a87474` 成立） |
| `docs/qa-baseline-834d603d.md` | 基线取证与"基线如何被自己打掉"的时间线 |
| `docs/archive/v0.2/architecture-v0.2-web-runner.md` | Web 后端设计（1243 行） |
| `docs/prd.md` / `docs/architecture.md` | V0.1 需求与设计（未改） |
| `Tests/qa/final-sha256.txt` | 终版快照（当前 = `96a87474`） |

---

## 10. 下一轮建议（按性价比）

1. **补 AC-8，并把"帧非空白 + ≥1 条 translated"做成脚本化判据**。这是唯一还挡在"窗口模式可用"这个结论前面的东西；顺带能判定 BUG-12 到底是环境特例还是真问题。
2. **BUG-12 立项**：先做隔离实验（全新 profile 的窗口跑 vs 真实 profile 的窗口跑），把"渲染没起来"变成一个**可判定的信号**（渲染存活探针），再决定是错误码还是降级。注意别用环境相关信号做硬失败。
3. **修 `TextStreamStore.swift:165`**（BUG-11 的 Host 侧同型点），修法与 agent 侧同构：按本行 raw 重组，译文文本按 cacheKey 共享。
4. **把 `Settings.browserPath` 接进设置页**（目前只能手改 json / `MOCHI_BROWSER_PATH`）。
5. **语言对可选**（PRD D-1 冻结 `ja→zh-Hans`）——遇到中文游戏时产品语义会变成"什么都不翻"。
6. **流程**：验证在飞时不要重建；构建产物归档到 `build/archive/<sha>/`。

---

## 11. 环境快照（交接时）

- macOS 27.0.1 / arm64；Swift Command Line Tools；Node 22（仅测试脚本用）
- 后台 Chrome：**0 个**；调试端口 `39200–39409` 无监听；echo 服务（8789）已停
- Playwright 缓存 Chromium：`chromium-1248`（唯一可用内核；无 Chrome/Edge/Brave，Safari 不支持 CDP）
- 真实 profile `browser-profiles/5f925f420b465c3f`：**`Singleton*` 三个文件均不存在**，目录 `0700`、`flags=-`
- 冻结副本：`/tmp/MochiBox-96a87474.app`（与本轮全部取证锚定）
- 无 Wine、无 CrossOver
