#!/usr/bin/env bash
#
# Tests/e2e/run.sh —— E2E 统一入口（分层）。
#
#   --suite contract   协议层：Node vm + Swift 单元探针。零浏览器、零网络、零 GUI，可离线。
#   --suite domain     领域层：持久化/脱敏/日志/韧性/直通/缓存/全文翻译；零 GUI（D9 例外）。
#   --suite kernel     内核层：真 WKWebView（--play）下的采集/翻译/控制通道；需要 Aqua 桌面。
#   --suite faults     故障层：翻译后端 401/429/500/非 JSON/端口占用等失败必须可诊断；需要 Aqua 桌面。
#   --suite game       真游戏层：opt-in，需 MOCHI_E2E_GAME 指向一个 mv/mz 游戏目录；需要 Aqua 桌面。
#   --suite all        依次 contract → domain → kernel → faults → game，逐层汇总。
#
# 环境变量：
#   MOCHI_E2E_GAME       真游戏目录。未设置时 game 层打印 SKIP 并跳过（不算失败）。
#   MOCHI_E2E_PROVIDER   game 层的后端：passthrough（默认）| openai。
#   MOCHI_E2E_ENDPOINT   provider=openai 时的后端地址。
#   MOCHI_DATA_DIR       由各 case 自己 mkdtemp，无需手动设置。
#
# 降级规则（只对缺环境生效，绝不掩盖真实失败）：
#   · 无 Aqua 桌面（launchctl managername != Aqua）→ kernel/faults/game 打印
#     "SKIP ... reason=kernel_reason=no_aqua" 并继续，不算失败；
#   · 未设置 MOCHI_E2E_GAME → game 打印 "SKIP ... reason=MOCHI_E2E_GAME 未设置" 并继续。
#
# 退出码：0 = 本层全部通过（含明确 SKIP）；1 = 有断言失败；2 = 参数/环境/suite 错误。
# 末行固定为：E2E PASS suite=<suite> cases=<N> assertions=<M>
#         或：E2E FAIL suite=<suite> cases=<N> assertions=<M> failed_layers=<a,b>
#
# 每个 case 跑在独立子进程里（独立 MOCHI_DATA_DIR / 独立控制 socket），单 case 超时
# 180s 会被中断并在 TAP 里点名卡住的 case；任一层有 fail 即整体失败。
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

BIN="build/MochiBox.app/Contents/MacOS/MochiBox"
SUITE="contract"
LOG_DIR=""

cleanup() {
  if [ -n "$LOG_DIR" ] && [ -d "$LOG_DIR" ]; then rm -rf "$LOG_DIR"; fi
}
trap cleanup EXIT

usage() {
  sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --suite)
      if [ "$#" -lt 2 ]; then echo "error: --suite 缺少值" >&2; exit 2; fi
      SUITE="$2"; shift 2 ;;
    --suite=*) SUITE="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: 未知参数 $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$SUITE" in
  contract|domain|kernel|faults|game|all) ;;
  *) echo "error: 未知 suite \"$SUITE\"（可选 contract|domain|kernel|faults|game|all）" >&2; exit 2 ;;
esac

if ! command -v node >/dev/null 2>&1; then
  echo "error: 找不到 node（所有层的 case 与 Swift 探针驱动都需要它）" >&2
  exit 2
fi

# kernel/faults/game 都要拉起 --play 建 NSWindow，没有二进制就无从谈起。
needs_binary() {
  case "$1" in kernel|faults|game|all) return 0 ;; *) return 1 ;; esac
}

if needs_binary "$SUITE" && [ ! -x "$BIN" ]; then
  echo "error: 产品二进制不存在或不可执行：$BIN" >&2
  echo "       请先构建：bash Scripts/build.sh" >&2
  exit 2
fi

# Aqua 判定：拿不到 launchctl 就当有桌面，让 case 自己去撞（case 内部也会识别 no_aqua）。
aqua_missing() {
  command -v launchctl >/dev/null 2>&1 || return 1
  [ "$(launchctl managername 2>/dev/null)" != "Aqua" ]
}

LOG_DIR="$(mktemp -d -t mochibox-e2e-logs)"

# 跑一层；结果写进 LAYER_CASES / LAYER_ASSERTIONS，返回值 0=通过 1=失败。
LAYER_CASES=0
LAYER_ASSERTIONS=0

run_layer() {
  local suite="$1"
  local log="$LOG_DIR/$suite.tap"
  local status=0
  local summary=""
  # run.mjs 自己的汇总行留在日志里供解析，但不重复打印：本脚本末尾只出**一条**统一汇总。
  node Tests/e2e/lib/run.mjs --suite "$suite" 2>&1 | tee "$log" | grep -v -E '^E2E (PASS|FAIL) suite='
  status=${PIPESTATUS[0]}

  summary="$(grep -E '^E2E (PASS|FAIL) suite=' "$log" | tail -1)"
  if [ -z "$summary" ]; then
    echo "not ok - [$suite] 没有输出 E2E 汇总行（run.mjs exit=$status）"
    LAYER_CASES=0
    LAYER_ASSERTIONS=0
    return 1
  fi

  LAYER_CASES="$(printf '%s' "$summary" | sed -n 's/.*cases=\([0-9][0-9]*\).*/\1/p')"
  LAYER_ASSERTIONS="$(printf '%s' "$summary" | sed -n 's/.*assertions=\([0-9][0-9]*\).*/\1/p')"
  LAYER_CASES="${LAYER_CASES:-0}"
  LAYER_ASSERTIONS="${LAYER_ASSERTIONS:-0}"

  if [ "$status" -eq 0 ] && printf '%s' "$summary" | grep -q '^E2E PASS'; then
    return 0
  fi
  if [ "$status" -eq 2 ]; then
    echo "error: suite $suite 以 2 退出（参数/环境错误，不是断言失败）" >&2
  fi
  return 1
}

# 单层：环境不满足时打印一行明确的 SKIP，而不是把 0 条断言说成绿。
skip_layer() {
  local suite="$1" reason="$2" detail="$3"
  echo "SKIP suite=$suite reason=$reason —— $detail"
}

TOTAL_CASES=0
TOTAL_ASSERTIONS=0
FAILED_LAYERS=""

run_one() {
  local suite="$1"
  if [ "$suite" = "kernel" ] || [ "$suite" = "faults" ] || [ "$suite" = "game" ]; then
    if aqua_missing; then
      skip_layer "$suite" "kernel_reason=no_aqua" "无 Aqua 桌面会话，本层未运行（换一台有登录桌面的 Mac 再跑）"
      return 0
    fi
  fi
  if [ "$suite" = "game" ] && [ -z "${MOCHI_E2E_GAME:-}" ]; then
    skip_layer "game" "MOCHI_E2E_GAME 未设置" "真游戏冒烟未运行；设置 MOCHI_E2E_GAME=<mv|mz 游戏目录> 后重跑"
    return 0
  fi

  run_layer "$suite"
  local ok=$?
  TOTAL_CASES=$((TOTAL_CASES + LAYER_CASES))
  TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + LAYER_ASSERTIONS))
  if [ "$ok" -ne 0 ]; then
    FAILED_LAYERS="${FAILED_LAYERS:+${FAILED_LAYERS},}${suite}"
  fi
  return 0
}

if [ "$SUITE" = "all" ]; then
  for layer in contract domain kernel faults game; do
    run_one "$layer"
  done
  if [ -n "$FAILED_LAYERS" ]; then
    echo "E2E FAIL suite=all cases=$TOTAL_CASES assertions=$TOTAL_ASSERTIONS failed_layers=$FAILED_LAYERS"
    exit 1
  fi
  echo "E2E PASS suite=all cases=$TOTAL_CASES assertions=$TOTAL_ASSERTIONS"
  exit 0
fi

run_one "$SUITE"
if [ -n "$FAILED_LAYERS" ]; then
  echo "E2E FAIL suite=$SUITE cases=$TOTAL_CASES assertions=$TOTAL_ASSERTIONS"
  exit 1
fi
echo "E2E PASS suite=$SUITE cases=$TOTAL_CASES assertions=$TOTAL_ASSERTIONS"
exit 0
