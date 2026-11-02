# 真实 provider 延迟与失败面证据（2026-11-02）

本目录是 `docs/rgss-text-channel.md` §8.2 的原始数据。

## 环境

- endpoint：DeepSeek 官方 `https://api.deepseek.com`（Key 不落盘、不打印）
- `model=deepseek-flash`，`timeoutSec=15`，`maxBatch=120`，`maxConcurrent=4`，
  `batchCharBudget=1500`，`batchWindowMs=120`
- 10 条日文 RPG 台词，206 字；第 4 条含 `\C[2]…\C[0]`，第 8 条含 `\N[1]`

## 文件

- `latency.txt` —— 任务 1 的完整输出：批次 / 8 条单条 / usage。
- `429/` —— mock `--mode 429-retry --fail-count 1 --retry-after 1`：
  `app.txt`（CLI）、`bridge.txt`（TEXT/TIMEOUT/LATE）、`session.txt`（rate_limited +
  `delaySource=retry-after`）、`requests.txt`（两次请求的毫秒时间戳）。
- `401/` —— mock `--mode 401`：每条一次请求，`auth_failed`，不重试。
- `500/` —— mock `--mode 500`：同一请求体 4 次（500/1000/2000 退避）后放弃；
  两行文本共 8 次请求。
- `nonjson/` —— mock `--mode nonjson`：200 + 非 JSON，`bad_response`，不重试，
  桥回 PENDING + 原文。

## 复现

```bash
node Fixtures/mock_translate_server.mjs --port 0 --mode 429-retry \
  --fail-count 1 --retry-after 1 --record /tmp/ev/429

MOCHI_DATA_DIR=/tmp/ev/data MOCHI_INJECT='\C[2]赤い\C[0]' \
  ./build/MochiBox.app/Contents/MacOS/MochiBox --play-native /tmp/vx-run \
  --provider openai --endpoint http://127.0.0.1:<port> --api-key test --duration 16
```

`MOCHI_INJECT` 只用于让测试注入器把游戏推进到 `Scene_Map` 并塞一条消息；
不需要截图或按键。桥日志默认在 `/tmp/mochi-rgss-bridge.log`，会话日志路径由
`rgss: log=…` 打印。
