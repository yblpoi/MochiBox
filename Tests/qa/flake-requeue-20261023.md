# 握手期信封被读走即焚（captured=0）—— 修复与实测（2026-10-23）

> 缺陷自初始提交 f2fb0e5 起存在；本轮修复见 af2915d。本文只记**实测**，不重复实现细节。

## 缺陷一句话

`AgentInjector.injectAndHandshake()` 的握手循环用 `drain()` 把页面 outbox 整个 `splice` 走，
却只消费 `hello`。页面侧 `install()` 成功后立刻开始 emit（`state.enabled` 默认 true，不等宿主），
因此「早装完成 → 握手 drain」窗口里的文本被读走即焚，后续 pump 再也拿不到。
`--play` 当时传 `log: nil`，全程无日志 —— 这正是历史上那次 `probe emitted=3 / captured=0`
只有 stdout 可查的原因（见 `final-sha256-v0.6.txt` 重构后重基线一节的 AC-2 红记录）。

## 修复

- 页面：`window.__mochibox.requeue(json)` —— 按原序放回 outbox **队首**，容量沿用 `emit()` 的
  "丢最旧"，按信封签名（text 的 `ts/frame/surface/raw`、rpc 的 `payload.id`、scan 的 `scanId+seq`）
  只与**上一批**去重。`emit()` / `drain()` 一字未改。
- 宿主：握手循环收集非 `hello` / 非 `error` 信封，`flushHandshakeBacklog` 回灌；
  回灌失败只记 warn，**不**让 attach 失败。
- 可观测性：`--play` 接入 `SessionLog`（`<data>/logs/session-*.log`），stdout/stderr 一字未改。

## 实测 1 · 基线 10 轮（修复前构建）

```bash
MOCHI_DATA_DIR=<临时目录> MochiBox --play "<作品根>" --headless --provider passthrough \
  --duration 40 --out /tmp/flake-validation/pre-N.jsonl
```

串行 10 轮（并发会假红）：

| 结果 | 轮数 |
| --- | --- |
| exit=0，captured=3 | 10 |
| captured=0 | 0 |

**本机空闲负载下未复现**（低于 1/10），故不能拿"修复后 10 轮全绿"当证据 ——
证据见实测 2 的回灌计数与实测 3 的确定性 A/B。

## 实测 2 · 修复后 10 轮

| 结果 | 轮数 | 说明 |
| --- | --- | --- |
| captured=6（回灌 3 条 text） | 3（第 1/6/10 轮） | `握手期信封已回灌 outbox accepted=3 count=3 types=text=3` |
| captured=3（无回灌） | 7 | 窗口内没有文本，路径与修复前一致 |
| captured=0 | 0 | —— |

这 3 轮在修复前**必然**少 3 条（那 3 条已被握手 drain 吃掉），因此
"回灌 N>0 且 captured>0" 直接证明修复生效。

## 实测 3 · 确定性 A/B（同一枚二进制，只换页面脚本）

用 `MOCHI_AGENT_SCRIPT` 指向脚本副本：在 `install()` 成功当刻多吐一条 `text`（`RACE_PROBE`），
模拟"早装完成 → 握手 drain"窗口内的真实采集。

| 页面脚本 | 握手日志 | captured | jsonl 含 RACE_PROBE |
| --- | --- | --- | --- |
| 带 `requeue` | `已回灌 outbox accepted=4 count=4 types=text=4` | 7 | 1 |
| 去掉 `requeue`（模拟旧脚本） | `未能回灌 count=4 types=text=4` | 3 | 0 |

同一窗口内 4 条 text：有 `requeue` 全部救回，没有就全丢 —— 修复点与丢失点是同一处。

## 实测 4 · 完整 e2e

```
MOCHI_E2E_GAME=<作品根> MOCHI_E2E_WORK=/tmp/mt-e2e-requeue bash Tests/e2e/play_e2e.sh
# pass 11 fail 0 / # PLAY_E2E_PASS（5m26s，exit 0）
```

- AC-2：exit 0、captured=3（jsonl 3 行）、http=39393 结束后已释放
- AC-3：exit 0、translated=3、probe.replaced=3、3 条带 ◇ 前缀
- AC-4：两次运行端口一致（39393）

e2e 这一轮 4 次 `--play` 都没有触发回灌（窗口内无文本），属于正常路径。
