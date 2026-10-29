# V0.1 实测存档（2026-10-20）

> 本文是 **2026-10-20 的历史快照**，不是当前口径。当前口径见 [`docs/testing.md`](../docs/testing.md)（测试入口与命令）与 [`docs/qa-report.md`](../docs/qa-report.md)（当前态 QA 报告）。
> 文中"@State 不可用""BUG-11 未修""16ms 帧桶去重""selftest 29 条"等结论均已被后续版本推翻；正文结论保留不改，仅作历史证据。
> 唯一改动：**实测输出中的本机绝对路径已替换为占位符**（`/path/to/Mtool-M`），命令与输出内容本身未改。

环境：macOS 27.0.1 (arm64) · Swift 6.4 / `-swift-version 5` · 仅 Command Line Tools（无 Xcode）
时间：2026-10-20 12:48 – 13:15（本地时间）
仓库根：`/path/to/Mtool-M`

本文件记录 **2026-10-20 当时工作树**的实测结果（历史快照，不是当前工作树）。旧记录（27 条自检、`captured=54`）已被本轮取代，
原因不是"跑挂了"，而是**修掉了两个真缺陷后行数理应变小** —— 见 §3 与 §5。

---

## 0. 本轮修复清单（每条都有对应的自证）

| ID | 缺陷 | 修法 | 证据 |
|---|---|---|---|
| D1 | **同帧去重失效**：3 句对白 8 秒写 66 行 | Agent 侧 `surface+key` **滑动 800ms** 窗口；新会话（`hello`/`config.sessionToken`）重置窗口 | §3 `captured=3`；§3.5 连跑两次都是 3 |
| D2 | **`SkipRules` 未归一**：`"350 "`、`"３５０"`、`"\C[2]350"` 判不出 `numeric` | `singleReason` 入口先 `Segmenter.normalizeForKey`（与 key 归一**同一份实现**，不另写 trim） | §2.2 `qa_probe` V4S 全绿；`skip_probe` 18/18 |
| D3 | **JS `isTrivial` 用码段范围冒充 `\p{P}\p{S}`**：全角 `ＯＫ`/`３５０Ｇ` 误跳，`♪`/`★` 漏跳 | 改用 `^\p{P}\p{S}+$`（`u` 标志）；引擎不支持时**保守不跳**（宁可多译不可漏译） | §2.2 `skip_probe` V4-5a…d 全绿 |
| D4 | **`Scene.pck` 被判成 Godot** | Godot 的 `*.pck` **显式排除** `Scene.pck`（`topLevelFile(excluding:)`），**不动签名表行序** | §2.2 `qa_probe` V6-12 绿、V6-13 仍绿 |
| D5 | **`passthrough` 制造假译文**：`translated` 填了原文 | `TextEvent.translated` 在 `passthrough` 时置 `nil`；UI 按 `status` 渲染 | §3.4 每行 `translated` 字段缺失 |
| D6 | **`--out` 写失败静默**：无权限路径也 exit 0 | `JSONLWriter` 每次写返回 `Bool`、`isWritable`，失败累计后 exit 1 | §3.6 `error: 无法写入…` + `EXIT=1` |
| D7 | **`cacheKey` 归一化对象错**：逐段归一后再 join | 改为 **join 之后整串归一**（PRD §5.1 公式 + 架构 T03） | §2.1 自检新增两条断言 |
| D8 | 替身页把 `\C[2]` 画到屏幕上 | fixture 的绘制函数**剥掉控制码**（Agent 不剥，这是绘制侧职责） | §3.3 截图第三行已是 `勇者啊，醒醒吧` |
| D9 | **BUG-7：跳过句完全不 emit** → 文本流凭空少一行，`applySkip` 是死代码 | `collect()` 命中跳过时**仍 emit**，带 `status=skipped` + `skipReason`；原文 `raw` 逐字节保留（含 `\C[2]`） | §7.1 `emit_contract_probe` 7/0；§7.3 JSONL 出现 `\\C[2]350` 一行 |
| D10 | **BUG-8：去重签名用了 `mapKey`** → `350` 与 `\C[2]350` 撞签名，后者被静默吞掉 | 签名改 `surface + raw`（显示身份用实际画出的串，翻译身份才用 `mapKey`）；800ms 滑窗不变 | §7.3 同一页面 `350`/`\C[2]350` 各占一行（2 行） |
| D11 | **标点判据双端不一致**：`"! !"` Swift 跳过、JS 不跳 | 两端同一条判据：**移除 5 个折叠码位**后的余串非空且全为 `\p{P}`/`\p{S}` → `punctuation`；判据里不出现任何平台字符类（`\s` 含 U+FEFF、`.whitespaces` 不含） | §7.2 `skip_probe` faceB 18/18；自检 `"! !"`/`"!!"`/`"3 5 0"` 三条 |
| D12 | **BUG-6：`--verbose` 空实现**（只存不用） | `--verbose` 打 `# case … pass <ms>`、`# verbose: cases=…`，并在关键用例输出 `# note`（key 对照值） | §7.4 31 行 vs 61 行 |
| D13 | `occurrences` 同帧重复观测不累加 | `TextStreamStore.ingest` 同帧分支改为**累加** | 自检 + 代码审阅（页面侧 800ms 窗口下同一句只上报 1 次，故只在宿主层可观测） |

> D1 的修法说明：**滑窗**而不是"内容相同永久不 emit"。只要文字还在屏幕上连续重绘，时间戳就不断续期
> → 一句只记 1 条；等它离开画面超过 800ms 再回来，会重新上报（玩家反复确认同一句要计入次数）。

---

## 1. 构建

```
$ bash Scripts/build.sh
==> ui gate: ok
==> compile (target=arm64-apple-macos13.0)
==> compiled: /path/to/Mtool-M/build/MochiBox
==> assemble bundle
==> ad-hoc sign
==> signed (ad-hoc)
==> artifact: /path/to/Mtool-M/build/MochiBox.app
build/MochiBox.app/Contents/MacOS/MochiBox        1898240 bytes
build/MochiBox.app/Contents/Resources/agent_mvmz.js 27259 bytes
BUILD_EXIT=0
```

- `grep -c "error:" build/compile.log` → `0`；`grep -c "warning:" build/compile.log` → `0`。
- `-target arm64-apple-macos13.0` 直接成功（未走回落分支）。

### 1.1 UI 依赖门禁：正反两侧都实测

```
$ printf 'import SwiftUI\n' > Sources/Domain/__GateProbe.swift
$ bash Scripts/build.sh
error: core layer imports a UI framework (P0-18 violation):
/path/to/Mtool-M/Sources/Domain/__GateProbe.swift
GATE_EXIT=2
$ rm -f Sources/Domain/__GateProbe.swift
```

门禁清单按落地布局：禁止 `Sources/{Domain,Adapters,Infra,SelfTest}` 与
`Sources/App/{AttachCLI,Constants}.swift`；只有 `Sources/App/AppMain.swift` 与 `Sources/UI/**` 放行。

## 2. 自检与探针

### 2.1 `--selftest`（29 条）

```
$ ./build/MochiBox.app/Contents/MacOS/MochiBox --selftest
TAP version 13
ok 1 - [A] mz_signature
ok 2 - [A] mv_signature
ok 3 - [A] app_nw_layout
ok 4 - [A] renpy_game_dir
ok 5 - [A] kirikiri_startup
ok 6 - [A] easyrpg_requires_both
ok 7 - [A] rgss3_game_ini
ok 8 - [A] unity_data_dir
ok 9 - [A] tyrano_config
ok 10 - [A] conflict_prefers_priority
ok 11 - [A] empty_directory
ok 12 - [A] not_a_directory
ok 13 - [B] key_normalization
ok 14 - [B] segment_key_distinct
ok 15 - [B] cache_persist_no_second_call
ok 16 - [B] skip_rules
ok 17 - [B] skip_before_cache_no_write
ok 18 - [C] openai_success_shape
ok 19 - [C] deepl_success_shape
ok 20 - [C] auth_failed_401
ok 21 - [C] rate_limited_429_and_non_json
ok 22 - [D] agent_installs
ok 23 - [D] agent_emits_and_replaces
ok 24 - [D] agent_skips_trivial_without_emit
ok 25 - [D] agent_uninstall_restores
ok 26 - [E] text_event_roundtrip
ok 27 - [E] envelope_unknown_fields_and_type
ok 28 - [E] protocol_version_mismatch_detectable
ok 29 - [E] host_command_json
# pass 29 fail 0
```

`[B] key_normalization` 本轮新增三条断言（D7）：`cacheKey("こんにちは ") == cacheKey("こんにちは")`、
`cacheKey("３５０") == cacheKey("350")`、`cacheKey("こんにちは") != cacheKey("こんばんは")`。
`[B] skip_rules` 保持 `10秒後` / `第2章` / `350G` 必须翻译，并验 `\C[2]350` → `numeric`。

用户目录隔离（实测）：

```
$ rm -rf ~/Library/Application\ Support/MochiBox
$ ./build/MochiBox.app/Contents/MacOS/MochiBox --selftest >/dev/null 2>&1
SELFTEST_EXIT=0
$ ls -d ~/Library/Application\ Support/MochiBox
ls: ...: No such file or directory
$ ls /tmp | grep -c MochiBox-selftest
0
```

### 2.2 QA 探针（不改断言，只跑）

```
$ swiftc -swift-version 5 -parse-as-library \
    Sources/Domain/Models/*.swift Sources/Domain/TolerantDecoding.swift \
    Sources/Domain/Segmenter.swift Sources/Domain/TranslationPipeline.swift \
    Sources/App/Constants.swift Sources/Infra/Stores.swift Sources/Infra/Translators.swift \
    Sources/Adapters/EngineDetector.swift Tests/qa/qa_probe.swift -o /tmp/qa_probe
$ /tmp/qa_probe | tail -3
PASS | V6-16 | detect(e_easyrpg_partial) | expected unknown/unknown/no_signature_matched actual unknown/unknown/no_signature_matched evidence=[]
INFO | V5 跳过（未传 --http-base）
SUMMARY | pass=37 fail=0
```

> 探针编译需要额外带 `TranslationPipeline.swift`（探针内部构造管线验"跳过不产生缓存条目"）。
> 这是编译命令的差别，**没有改 Tests/qa/ 下任何一行**。

```
$ node Tests/qa/skip_probe.mjs | tail -1
SUMMARY | faceA(可见性) pass=18 fail=0 | faceB(判定) pass=18 fail=0
```

```
$ node Tests/qa/emit_contract_probe.mjs | tail -2
SUMMARY | pass=7 fail=0
NOTE | 修复前 fail=7 属预期（BUG-7）；修复后应 pass=7 fail=0。
```

```
$ node Tests/qa/idempotency_probe.mjs | tail -2
PASS | V8-UNINSTALL | uninstall 复原 drawTextEx | restored=true
PASS | V8-ERROR-SWALLOWED | 原函数抛异常不冒泡且计数 | threw=false errors=2
```
（连跑 3 次均 18/18）

## 3. 端到端（E2E，合成替身页）

### 3.1 起 Chromium 与 mock 后端

```
"$HOME/Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
  --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9370 \
  --user-data-dir=/tmp/mochibox-e2e-9370 \
  file:///path/to/Mtool-M/Fixtures/mv_stub/index.html

$ node Fixtures/mock_openai_server.mjs
[mock-openai] listening on http://127.0.0.1:8787
```

### 3.2 attach 主流程（8 秒）

```
$ ./build/MochiBox.app/Contents/MacOS/MochiBox --attach 9370 --provider openai \
      --endpoint http://127.0.0.1:8787 --out /tmp/e2e6.jsonl --screenshot /tmp/e2e6.png --duration 8
attached: url=file:///path/to/Mtool-M/Fixtures/mv_stub/index.html
          hooks=[Window_Base.drawTextEx,Window_Base.drawText,Bitmap.drawText,Window_Message.startMessage] flatten=true
screenshot: /tmp/e2e6.png bytes=15976
[state] 已停止
captured=3 translated=3
E2E_EXIT=0
```

**`captured=3`（修复前 66）** —— 8 秒 / 3 句，落在团队验收口径 3–9 内。

JSONL（全 3 行）：

```json
{"key":"魔物が来た","original":"魔物が来た","status":"translated","surface":"Window_Base.drawTextEx","translated":"魔物来了","ts":...}
{"key":"こんにちは","original":"こんにちは","status":"translated","surface":"Window_Base.drawTextEx","translated":"你好","ts":...}
{"key":"勇者よ、目を覚ませ","original":"\\C[2]勇者よ、目を覚ませ","status":"translated","surface":"Window_Base.drawTextEx","translated":"\\C[2]勇者啊，醒醒吧","ts":...}
```

`rows 3 / diff 3 / status ['translated']`；`key` 是 `mapKey`（原文串，不含 `\C[2]`）。

### 3.3 截图（控制码不进画面）

`/tmp/e2e6.png`（15976 bytes，人工查看）：

```
魔物来了
你好
勇者啊，醒醒吧          ← 修复前这里是 "\C[2]勇者啊，醒醒吧"
```

### 3.4 passthrough（同页面紧接着跑）

```
$ ./build/MochiBox.app/Contents/MacOS/MochiBox --attach 9370 --provider passthrough \
      --out /tmp/e2e4.jsonl --duration 5
captured=3 translated=3
PASS_EXIT=0

$ python3 …（逐行解析）
rows 3
status_set ['passthrough']
translated_present 0
{"key": "魔物が来た", "original": "魔物が来た", "status": "passthrough", "surface": "Window_Base.drawTextEx", "ts": ...}
{"key": "こんにちは", "original": "こんにちは", "status": "passthrough", ...}
{"key": "勇者よ、目を覚ませ", "original": "\\C[2]勇者よ、目を覚ませ", "status": "passthrough", ...}
```

`translated` 字段**缺失**（不是填原文），`status` 全为 `passthrough`。

### 3.5 连续两次 attach（验证窗口重置）

```
--- run1 ---  captured=3 translated=3
--- run2 (同一页面, 紧接着) ---  captured=3 translated=3
```

修复过程中发现并修掉的一个回归：滑动窗口在页面持续重绘时会被不断续期，
第二轮 `--attach` 若不清零窗口会得到 `captured=0`（连上但一句都没有）。
现在 `hello()` 与 `config`（sessionToken 变化）都会 `resetCaptureWindow()`。

### 3.6 `--out` 写失败不再静默

```
$ ./build/MochiBox.app/Contents/MacOS/MochiBox --attach 9370 --provider passthrough \
      --out /System/qa-no-perm.jsonl --duration 3
attached: url=file:///… hooks=[…] flatten=true
error: 无法写入 --out 指定的文件：/System/qa-no-perm.jsonl
NOOUT_EXIT=1
$ ls -l /System/qa-no-perm.jsonl
ls: /System/qa-no-perm.jsonl: No such file or directory
```

## 4. 静态合规检查（实测 grep）

| 检查 | 结果 |
|---|---|
| `grep -rn "/devtools/page/" Sources Resources` | 0 命中 |
| `grep -rn "0\.0\.0\.0" Sources Resources Scripts` | 仅 1 处中文注释「禁止 0.0.0.0」 |
| `grep -rn "import SwiftUI" Sources/Domain Sources/Adapters Sources/Infra Sources/SelfTest` | 0 命中（构建时门禁每次都跑） |
| `grep -rn "@Observable" Sources` | 仅 1 处注释 |
| `grep -rn "NavigationSplitView\|Table(" Sources` | 0 命中 |
| `grep -nE "sha256\|K256\|utf8Bytes" Resources/agent_mvmz.js` | 仅注释（Agent 无任何哈希实现） |
| `grep -rn "SHA256.hash" Sources` | 仅 `Segmenter.sha256Hex` 1 处 |
| `grep -rnE "fromLang\|toLang" Sources` | 仅 2 处注释，代码 0 使用 |

## 5. 与设计的偏离（及原因）

1. **`@State` 不可用 → UI 本地状态上移到 `AppState`**。本机 CLT 的 SDK 未带 `SwiftUIMacros`
   插件（`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`），
   `@StateObject` / `@ObservedObject` / `@EnvironmentObject` / `@Environment` 均正常。
2. **端口探活用 BSD `socket/bind(127.0.0.1)`**，不用 `NWListener`（后者仍用于 C 组 mock HTTP）。
3. **`SettingsBox`**（`SessionController.swift` 内，`@unchecked Sendable` + `NSLock`）：
   `@MainActor` 的 `SessionController` 无法给 `@Sendable` 闭包直接读属性，必须有线程安全盒子；
   它同时保证"只有设置签名变化才重建 provider"，避免每 120ms 新建一个 `URLSession`。
4. **§7.8 的 skip 顺序下沉到 `TranslationPipeline.resolve`**，`PipelineOutcome` 增加 `.skipped(reason:)`；
   `SessionController` 仍保留一次前置判定（双端判定，省一次 Task 跳转），两侧同一份 `SkipRules`。
5. **`MVAdapter` 放在 `EngineAdapter.swift`**；`isLaunchable` 收紧为 `engine ∈ {mv, mz} && !missing`。
6. **`godotPckExclusions`**：Godot 的 `*.pck` 排除 `Scene.pck`，写在匹配器里而不是调签名表行序
   （PRD §A.1 v0.3.5 的"精确名先于通配、且不靠行序表达"）。

## 6. 已知未做 / 未验证（如实记录）

- **未实现（裁定不做）**：L1 静态预翻译、`prewarm*` 字段、诊断导出、Onboarding、DetailPane、
  StatusBar 独立文件、缓存 compaction、设置迁移、Keychain。
- ~~**`SessionLog.rotateIfNeeded()` 未排程调用**~~（已修正）：轮转已接上 —— **会话创建时执行一次**，
  按**份数**保留最近 50 份（`K.logRetentionCount`），超出删最旧；只认
  `session-yyyyMMdd-HHmmss.log`，不动其它文件，**不删当前正在写的文件**。
- **真实 MV/MZ 游戏未验证**：只有 Chrome for Testing + 合成替身页 `Fixtures/mv_stub`
  （**合成替身，非真实 MV 运行时**）。E2E 结论只能表述为「**通道与管线在合成页面上跑通**」，
  PRD AC2.3 仍挂账。
- **`AC2.2c`（同进程切后端、1s 内收敛）未计时实测**：本机没有第二个真实后端可切，
  `SettingsBox` 只保证代码路径成立。
- **GUI 只做启动冒烟**：设置页只读语言项、清缓存确认框、四列文本流未人工点测。
- **`--out` 失败是在 attach 之后才报**：退出码与提示都正确，但更早失败会更好（未做）。

---

## 7. 本轮（BUG-7 / BUG-8 / BUG-6）复验 —— 原始输出

运行环境同上；`mtime` 说明：本轮改完后**重编两次**（第一次 `input file … was modified during the build`，
是编辑与编译撞车，第二次干净：`errors=0 warnings=0`）。

### 7.1 跳过句必须 emit（BUG-7）

```
$ node Tests/qa/emit_contract_probe.mjs
PASS | V4-11a | "350"        | raw="350" skipField=[["skipReason","numeric"]]
PASS | V4-11b | "！？"        | raw="！？" skipField=[["skipReason","punctuation"]]
PASS | V4-11c | "   "        | raw="   " skipField=[["skipReason","whitespace"]]
PASS | V4-11d | "３５０"      | raw="３５０" skipField=[["skipReason","numeric"]]
PASS | V4-11e | "350 "       | raw="350 " skipField=[["skipReason","numeric"]]
PASS | V4-11f | "♪"          | raw="♪" skipField=[["skipReason","punctuation"]]
PASS | V4-11g | "\\C[2]350"  | raw="\\C[2]350" skipField=[["skipReason","numeric"]]
INFO | agent state={"enabled":true,...,"emitted":7,"replaced":0,"skipped":7}
SUMMARY | pass=7 fail=0
```

### 7.2 双端跳过判据一致

```
$ node Tests/qa/skip_probe.mjs
SUMMARY | faceA(可见性) pass=18 fail=0 | faceB(判定) pass=18 fail=0
```

JS 侧逐值（`__mochibox.skipReasonOf`，Node 里跑真实文件）：

```
"350"=>numeric  "！？"=>punctuation  "! !"=>punctuation  "　"=>whitespace
"10秒後"=>null  "350 "=>numeric  "3 5 0"=>null  "３５０Ｇ"=>null  "♪"=>punctuation  "あ"=>null
```

Swift 侧同表（`--selftest` 的 `[B] skip_rules` 现在含 `"! !"`→punctuation、`"!!"`→punctuation、
`"3 5 0"`→nil），与 JS 逐值一致。

### 7.3 E2E（5 行页面：3 句对白 + `350` + `\C[2]350`）

页面是 `Fixtures/mv_stub/index.html` 的临时副本（`/tmp/mv_stub_skip.html`，**未改 Fixtures**），
Chromium CDP 9372、mock 后端 127.0.0.1:8787、8 秒。

```
$ ./build/MochiBox.app/Contents/MacOS/MochiBox --attach 9372 --provider openai \
      --endpoint http://127.0.0.1:8787 --out /tmp/e2e10.jsonl --screenshot /tmp/e2e10.png --duration 8
captured=5 translated=3 skipped=2 [numeric=2]
E2E_EXIT=0
```

JSONL（全 5 行，原文照抄）：

```
{"key":"魔物が来た","original":"魔物が来た","status":"translated","translated":"魔物来了",...}
{"key":"こんにちは","original":"こんにちは","status":"translated","translated":"你好",...}
{"key":"勇者よ、目を覚ませ","original":"\\C[2]勇者よ、目を覚ませ","status":"translated","translated":"\\C[2]勇者啊，醒醒吧",...}
{"key":"350","original":"350","skipReason":"numeric","status":"skipped",...}          ← 无 translated
{"key":"350","original":"\\C[2]350","skipReason":"numeric","status":"skipped",...}   ← 原文保留 \C[2]
```

- **`350` 与 `\C[2]350` 各占一行**（D10 的目标：签名用 `raw` 而不是 `mapKey`）；
- 跳过行**没有** `translated` 字段（假译文防线）；跳过行**有** `skipReason`；
- 后端请求**仍只有 1 次**：`[mock-openai] items=3 -> ["魔物来了","你好","勇者啊，醒醒吧"]`
  （跳过句没有进批次；日志里的 `items=1 -> ["x"]` 是我自己 curl 探活，不属于应用）。

### 7.4 `--verbose`（BUG-6）

```
$ … --selftest | wc -l              → 31 行
$ … --selftest --verbose | wc -l    → 61 行
```

`--verbose` 额外输出（节选）：

```
# verbose: cases=29 filter=- tempRoot=/var/folders/…/MochiBox-selftest-90848
# case [A] mz_signature …
# case [A] mz_signature pass 6ms
# note key 对照：'こんにちは '=046148632a8c 'こんにちは'=046148632a8c '３５０'=aa60bdb145d6
        '350'=aa60bdb145d6 '甲\t乙'=8cc659e9e451 '甲 乙'=8cc659e9e451 '甲乙'=afce282d8c23
```

`--verbose` 不改变断言与退出码（仍 `# pass 29 fail 0`、exit 0）。

### 7.5 无回归

```
$ … --selftest                        → # pass 29 fail 0   (exit 0)
$ /tmp/qa_probe                       → SUMMARY | pass=37 fail=0
$ … --attach 9373 (3 句主替身页, 8s)   → captured=3 translated=3 skipped=0
$ … --attach 9373 --provider passthrough (5s)
  rows 3 status ['passthrough'] translated_present 0
$ 连跑两次（同一页面）                  → captured=3 / captured=3
$ … --attach --out /System/…            → error: 无法写入 --out 指定的文件… / NOOUT_EXIT=1
```

---

## 8. BUG-10：宿主行身份漏改（架构裁定 (b)）

页面侧去重早已改成 `surface + raw`，但宿主 `TextStreamStore.ingest` 的行身份仍是 `cacheKey` ——
而 `cacheKey` 的材料正是"**剥码后的 text**"，`350` 与 `\C[2]350` 的 `cacheKey` 完全相同，
于是后者在 UI 上会被静默合并（P0-08 明确禁止用 `key`/`text` 当行身份）。本轮按 (b) 落地。

### 8.1 三层身份

| 用途 | 身份 | 代码位置 |
|---|---|---|
| 行身份（去重、`occurrences`、UI 合并/显示） | `surface + U+0000 + raw` | `TextStreamStore.rowIdentity(surface:raw:)` |
| 翻译身份（缓存查找、批量请求、`setTranslation`） | `cacheKey` | `TextEvent.key` / `delivered[...]` / `applyXXX(cacheKey:)` |
| 行唯一 id | `TextEvent.id`（UUID，每 emit 一条新行一个新 id） | `TextEvent` / `ForEach(...).tag(row.id)` |

### 8.2 改动点与"该保持"的点

| 位置 | 处理 |
|---|---|
| `TextStreamStore.ingest` | 行身份改 `rowIdentity(surface:raw:)`；同帧去重比 `(surface, raw)`；`occurrencesByIdentity` 随之改名 |
| `applySkip / applyTranslation / applyError / markPending` | 参数 `key:` → `cacheKey:`，语义写明"**扇出到所有共享该 cacheKey 的行**"（一条结果填满 `350` 与 `\C[2]350`，否则另一行永 `pending`，AC2.2b 失败） |
| `SessionController.retranslate(key:)` | **保持**按 `cacheKey` 重查，结果由 `applyTranslation` 扇出刷新（多行同时更新属预期） |
| `SessionController.delivered[cacheKey]` | **保持**（翻译身份；`350` 与 `\C[2]350` 共享，不重复下发/计费） |
| UI `ForEach(app.stream.rows)` / `.tag(row.id)` / 右键"重新翻译"用 `row.key` | **无需改**（本来就是行 `id` 选中、`cacheKey` 重译） |
| `--attach` JSONL | 每收到一条事件写一行（已是行身份语义），`key` 仍打 `mapKey`，**保持** |

### 8.3 错误 / 降级 / 失效也按 `cacheKey` 扇出（不只 translation）

`applySkip` / `applyTranslation` / `applyError` / `markPending` **共用** `rowsSharingCacheKey(_:)`，
不再四处各写一次过滤（两套过滤必然漂移）。另补两处产品路径的漏点：

| 漏点 | 后果 | 修法 |
|---|---|---|
| 批次整体失败时 `PipelineBatchResult.items` 为空，`handleBatchResult` 只更新 `backendStatus` | **没有任何行变 `error`**，全部永远 `pending`（看起来像"后端很慢"） | `SessionController` 维护 `inFlightCacheKeys`（已送出未落地的 `cacheKey`）；批次带 `error` 时把它们逐个 `applyError(cacheKey:)` 扇出，然后从中移除 |
| 单条 `items` 里 `translatedSegments == nil`（段数不匹配）时 `continue` | 该行静默留在 `pending` | 改为 `applyError(cacheKey: item.key, …)` 后再 `continue` |

### 8.4 新增断言（在 `[B] segment_key_distinct` 内，用例总数仍 29）

```
$ … --selftest | tail -1
# pass 29 fail 0
```

样本要成对看（PM/架构纠过一次"单样本既测行身份又测计费"是错的）：

| 样本 | 断言 | 测什么 |
|---|---|---|
| **A** `350` + `\\C[2]350` | 同帧 ingest → **2 行**，两行 `cacheKey` 相同 | 行身份按 `raw`（两条都 `skipped`，**不碰后端**；用它们验"计费=1"是恒真，测不出"两行各发一次请求"的过度修复） |
| **B** `こんにちは` + `\\C[2]こんにちは` | 2 行；一条 `applyTranslation(cacheKey:)` → **两行都 `translated`** | 成功路径扇出（只改一行时另一行永久 `pending`） |
| **B′** 同上 | 一条 `applyError(cacheKey:)` → **两行都 `error`** | 错误路径扇出（只改一行 = 一行报错一行转圈） |
| **计费** 同一 `cacheKey` 的两个 item 送管线（`CountingProvider` 计数） | `counter == 1` | 翻译身份去重（`rows=2` 且 `items=1` 同时成立） |

### 8.5 未在本轮跑 E2E 的原因（如实说明）

`TextStreamStore` 与 `SessionController.handleBatchResult` 只被产品路径使用，**不在 `--attach`
的代码路径上**（`AttachCLI` 自己写 JSONL、自己判跳过）。因此本轮改动由 §8.4 的断言覆盖，
E2E 只能证明"没回归"，不能证明"扇出生效" —— 这一点不美化。

本轮确实跑过（回归用，非扇出证据）：

```
$ bash Scripts/build.sh                                  → BUILD_EXIT=0, errors=0, warnings=0
$ … --selftest                                           → # pass 29 fail 0 (exit 0)
$ node Tests/qa/emit_contract_probe.mjs                  → SUMMARY | pass=7 fail=0
$ node Tests/qa/skip_probe.mjs                           → faceA 18/0 | faceB 18/0
$ /tmp/qa_probe                                          → SUMMARY | pass=37 fail=0
$ … --attach 9374 --provider openai --duration 8 (3 句页)  → captured=3 translated=3 skipped=0
$ shasum -a 256 build/…/MacOS/MochiBox | cut -c1-16      → 87e5213c22ad7141
$ stat -f "%Sm" build/…/MacOS/MochiBox                   → Oct 20 14:11:27 2026
$ shasum -a 256 build/…/Resources/agent_mvmz.js | cut -c1-16 → b53e1f6aa89dd669
```

---

## 9. 已知问题（本轮**不修**，已定位、已记录）

### 9.1 BUG-11：同 `mapKey` 不同 `raw` → 渲染丢码 / 加码（**不影响计费与缓存**）

链路：`agent_mvmz.js` 的 `lookup(raw, key)` 收了 `raw` 但没用，直接返回 `translations[mapKey].translatedRaw`；
而 `translations` 的键是 `mapKey`（剥码后的 text），两种 `raw` 共享同一格。

一次一进一出（必然发生，与 BUG-10 无关，早就存在）：

```
① 先请求 plain：请求 "こんにちは" → 译文"你好" → 下发 {key:"こんにちは", translatedRaw:"你好"}
② 页内另一处画 "\C[2]こんにちは"：mapKey 同为 "こんにちは" → lookup 返回 "你好"
③ 替换串 "你好" 交给 drawTextEx → 原本的 \C[2] **丢失**（颜色丢失）
反向顺序：① 下发 "\\C[2]你好"；② 之后画 plain "こんにちは" → 变成 "\\C[2]你好" → **凭空加色**
```

- **不影响**：计费、缓存键、跳过判定、采集去重（`delivered[cacheKey]` 与 `cacheKey` 都对）；
- **影响**：控制码（颜色/字号）在这两种画法之间串味；
- **根因**：译文文本可按 `cacheKey` 共享（不该翻两次），但**可绘制串必须按 `raw` 各自重组** ——
  `entry.segments` 存的是"请求那一次"的段，不能给另一种 `raw` 用；
- **修法要么**改下发协议（按行下发）、**要么**改 Agent 存储（存译文文本段、按本次绘制的 code 段本地重组），
  都是结构性改动，不在收尾阶段做（架构裁定：本轮不改）；
- **附带的已知副作用**：右键"重新翻译"取 `rows.last(where: { $0.key == key })`，
  哪个变体的 `segments` 被取到，就按它重组 —— 在 BUG-11 修好前，重译会让"错的那一行"换个错法。

### 9.2 Host 侧去重仍是 16ms 帧桶（未实现 800ms 窗口）

`TextStreamStore.ingest` 的 `signature = "\(payload.frame)|\(identity)"`，而 `frame` 是
`floor(nowMs()/16)` —— 同帧能合并，**跨帧一律新增行**。Agent 侧是 800ms 滑动窗口，**两端不同构**。

架构用可控 `payload.ts` 的探针实测：同身份 8×400ms → 期望 1 行、实测 8 行；窗内 700ms → 期望 1 行、实测 2 行。

- 真实链路上 Agent 的 800ms 先挡一道，用户大概率摸不到，架构建议排 **P1**，等主理人裁；
- **修的时候必须同批改探针**：`Tests/qa/store_probe.swift` 里 `ts` 恒为 1，一旦 Host 改看 `payload.ts`，
  所有事件间隔变 0 → S4/S5 会假红。探针是 QA 的文件，**不由我改**。
- 本文件 §8.4 的 S7 表述（同帧连画 10 次 → `occurrences=10`）与 PRD「窗内 `occurrences` 保持 1」冲突，
  也属上述同批修正范围。

### 9.3 `handleBatchResult` 的"error → 扇出"接线无自动化用例

`SessionController` 里 6 行（`inFlightCacheKeys` + `applyError` 扇出）目前**只有代码审阅**。
要自动化需要 SessionController 级 harness（假 adapter + 假管线），树里没有；
Store 层的扇出本身由 `store_probe` 的 S2b/S3 覆盖。

---

## 10. 运行入口与环境变量（本轮核实）

- **`MOCHI_AGENT_SCRIPT`**：自首次提交 `f2fb0e5` 就存在的调试入口 —— 用指定路径的 `.js`
  覆盖 bundle 内的 `agent_mvmz.js`（`AgentInjector.loadScript` 把它插在候选列表最前，
  优先级最高）。GUI 与 `--play` 共用同一条加载路径，**无作用域限制**。
  用途：改 Agent 脚本时不必重新打包。
- **`--play` 的日志目录**：未设 `MOCHI_DATA_DIR` 时写
  `~/Library/Application Support/MochiBox/logs`（与 GUI 同一目录），因此同样受
  「按份数保留最近 50 份」的裁剪约束；需要隔离运行时用 `MOCHI_DATA_DIR` 把整个根挪走。
