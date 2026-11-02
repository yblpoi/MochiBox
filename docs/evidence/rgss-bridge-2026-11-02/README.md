# RGSS 文本桥：同一轮内首遍原文 / 次遍中文（VX 实测）

日期：2026-11-02 19:07（本机，macOS arm64）
对象：`/tmp/vx-run`（RPG Maker VX 测试工程），`build/MochiBox.app`（HEAD + 本次测试改动）
后端：`Fixtures/mock_translate_server.mjs --mode slow --delay-ms 800`

## 结论

同一轮游戏里把**同一行**文本显示两次：

| 次数 | 桥日志 | hook 日志 | 截图 OCR |
|---|---|---|---|
| 第 1 次（空缓存） | `TIMEOUT seq=1 -> PENDING（后台请求中）`，800ms 后 `LATE seq=1 source=fresh -> 已可命中` | `RESP seq=1 (pending)` + `PENDING (display original)` | `赤い` |
| 第 2 次（同一进程，约 5.5s 后） | `RESP seq=2 source=hit text="\\C[2]译:赤い\\C[0]"` | `RESP seq=2 "\\C[2]译:赤い\\C[0]"` | `译：赤い` |

截图：

- `rgss-vx-first.png` —— 第 1 次，原文 `赤い`
- `rgss-vx-second.png` —— 第 2 次，中文 `译：赤い`

两次截图来自同一次 `--play-native` 进程（`inject.txt` 的 `PUSH first` / `PUSH second` 时间戳与
`bridge.txt` 的 `TEXT seq=1` / `TEXT seq=2` 对齐）。第 2 次在第一次 PENDING 的 1.5s
抑制窗口之外（`PUSH first` 19:07:35.927 → `PUSH second` 19:07:41.445），所以 hook 会重新发请求。

## 完整日志

- `bridge.txt` —— `RGSSBridge`（`/tmp/mochi-rgss-bridge.log`）
- `hook.txt` —— `Resources/rgss/mochi_rgss_hook.rb`（`/tmp/mochi-rgss.log`）
- `inject.txt` —— 测试注入器（`/tmp/rgss-evidence/inject.log`）
- `app.txt` —— MochiBox CLI 输出（含 `rgss-cache` 统计）
- `mock-requests.txt` —— mock 后端收到的完整请求（`requests.jsonl`）
- `cache.txt` —— 落盘缓存（`cache/cache.ja-zh-Hans.jsonl`）
- `first.ocr.txt` / `second.ocr.txt` —— 截图 OCR 原始输出

关键行（原文照录）：

```text
[2026-11-02 19:07:36] TEXT seq=1 ver=RGSS2 text="\\C[2]赤い\\C[0]"
[2026-11-02 19:07:36] TIMEOUT seq=1 -> PENDING（后台请求中）
[2026-11-02 19:07:37] LATE seq=1 source=fresh -> 已可命中
[2026-11-02 19:07:41] TEXT seq=2 ver=RGSS2 text="\\C[2]赤い\\C[0]"
[2026-11-02 19:07:41] RESP seq=2 source=hit text="\\C[2]译:赤い\\C[0]"
```

缓存统计：

```text
rgss-cache: entries=1 hits=1 stores=1 hitRate=50% path=/tmp/rgss-evidence/data/cache/cache.ja-zh-Hans.jsonl
```

`mock-requests.txt` 的 `user` content 是 `["赤い"]`，**不含** `\C[`；说明控制码只留在宿主/
hook 侧，送后端的是纯文本段。`cache.txt` 的 key 是
`cdca5359304db63bf043945a12f17328ccea0200a3b04819ca8d1077ebf698ee`（`cdca5359…`），
与 `docs/rgss-text-channel.md §8.1` 的向量一致。

## 复现步骤

前置工具（本机已有，不随包分发）：

- `build/MochiBox.app`（`bash Scripts/build.sh`）
- `/tmp/vx-run`：VX 测试工程 + `mkxp-z` 运行时
- `/tmp/xp-run/key`：向指定 pid 发 `space`（开始新游戏）
- `/tmp/shotpid/shotpid`：按 pid 截窗口并 OCR

1. 起 mock 后端（故意 800ms，保证首遍超过 120ms 应答闸）：

```bash
node Fixtures/mock_translate_server.mjs \
  --port 64805 --mode slow --delay-ms 800 --record /tmp/rgss-evidence/mock
```

2. 把测试注入器写进 `mkxp.json`（`GameLauncher` 会保留用户 preload，并把产品 hook 排在最后）：

```json
{"preloadScript":["/tmp/rgss-evidence-inject.rb"]}
```

注入器的关键动作：等 `$scene` 变成 `Scene_Map` → push `"\\C[2]赤い\\C[0]"` →
4s 后调用 `Window_Message#terminate_message`（模拟玩家按确认键）→ 1.5s 后再 push 同一行。

3. 启动：

```bash
MOCHI_DATA_DIR=/tmp/rgss-evidence/data \
  ./build/MochiBox.app/Contents/MacOS/MochiBox \
  --play-native /tmp/vx-run --provider openai \
  --endpoint http://127.0.0.1:64805 --api-key test --duration 30
```

4. 标题画面按 `space` 进入新游戏；等 `bridge.txt` 出现 `TEXT seq=1` 后 1s 截第一张，
等 `TEXT seq=2` 后 1s 截第二张。

## 备注

- 本目录只放证据，不放产品代码；注入器是测试夹具，不属于 `Sources/`。
- 第 2 次显示中文依赖 `TranslationCache` 已在第 1 次后台请求中写入；不是重启后的缓存命中。
- 截图里的文字颜色由游戏自己的 Windowskin 决定；本次控制码 `\C[2]…\C[0]` 在桥返回值里
  原样保留（见 `bridge.txt` 的 `RESP ... text="\\C[2]译:赤い\\C[0]"`）。
