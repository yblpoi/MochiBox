#!/bin/bash
#
# ac8_capture.sh —— AC-8 取证自动化（架构 v0.4 §7）。
#
#   判据（九条，缺一条即 FAIL）：
#     1. `error_code:` 行数 = 0 且退出码 0（**不许**用 installed=true 冒充成功，BUG-12 候选）
#     2. `translated >= 1`，且 JSONL 里存在 `"status":"translated"` 行
#     3. `play: probe=… "replaced": >=1`（译文真的回绘到页面）
#     4. `screencapture -l<window_id>` 产出 PNG，且像素采样 `distinct_colors > 1`（帧非空白）
#     5. **人工肉眼**在 PNG 上看到 `◇` 前缀译文（脚本只打印路径与 JSONL 里的 ◇ 条数）
#     6. 以上全部绑定 binary sha256 与取证时刻
#     7. `play: http=` 行必须含 `kernel=embedded`，且 `content=WxH` 的宽高均 > 0
#        （证明走的是内置内核、且窗口按游戏素材尺寸开，不是默认窗口）
#        如需锁死具体尺寸：`MOCHI_AC8_EXPECT_CONTENT=816x624`
#     8. `play: window_id=… title=` 的标题非空（空标题说明窗口标题没取到素材名）
#     9. `play: scene=` 出现过非 `none`、非 `Scene_Boot` 的场景
#        ——「导航成功 ≠ 游戏跑起来」这条防假绿判据必须有机器执行者。
#        `Scene_Boot` 停留在宽限窗口内是正常的（本作 1–2s），但要**出现过**离开它的场景。
#
#   坑（2026-10-22 实测，务必别复发）：`$i：` 这种「变量名紧跟全角字符」写法在
#   `set -u` 下会被 bash 当成变量名的一部分 → `unbound variable` → 脚本整条中止。
#   本脚本 138 行曾因此必崩，导致 AC-8 永远走不到判据段（window.png 都不生成）。
#   **所有变量引用一律用 `${NAME}` 包裹。**
#
#   为什么必须是 `screencapture -l<CGWindowID>`：`takeSnapshot` 与 headless 截图都是
#   进程内渲染，它们证明"WebKit 渲染出了这一帧"，**不**证明"用户桌面上看见了这个窗口"
#   （docs/qa-addendum.md 已定）。AC-8 只认真实桌面像素。
#
#   **取证仪器已被实测排除怀疑**（team-lead 的独立探针，2026-10-22）：
#   `screencapture -x -o -l<id>` 能抓到 WKWebView 的 canvas 内容、文字、红框**以及 video 图层**
#   （同一次抓图里远程 `<video>` 的视频帧也在）。所以本脚本抓到黑图时，不要再怀疑
#   "screencapture 抓不到 WebKit 图层"——先怀疑"抓帧时刻画面本身就是黑的"。
#
#   **本作的黑图是正常现象**：开场 OP 里有大量近乎全黑的帧（只有一行白色字幕，
#   实测 `distinct=106 mean_luma=2.9`）。所以第 4 条改成**连抓 3 张取最不空的那张**，
#   单张黑图不再直接判 FAIL（判据本身没放宽：最终仍要求 `distinct_colors > 1`）。
#
#   用法：
#     bash Scripts/ac8_capture.sh                 # 自动选 reference/test-games/ 下唯一的作品
#     MOCHI_AC8_GAME=/path/to/game bash Scripts/ac8_capture.sh
#     MOCHI_AC8_DURATION=60 bash Scripts/ac8_capture.sh
#
#   退出码：0 = 机器判据全中（第 5 条要人看）；1 = 有判据未满足；2 = 环境问题
#
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2

BIN="build/MochiBox.app/Contents/MacOS/MochiBox"

# 作品路径：MOCHI_AC8_GAME 优先；否则仅当 reference/test-games/ 下**恰好一个**目录时自动选它。
# 不再写死某个作品名（旧默认 RJxxxxxx 已不存在，写死等于让脚本必然 exit 2 且提示误导）。
GAME="${MOCHI_AC8_GAME:-}"
if [ -z "$GAME" ]; then
  TEST_GAMES_DIR="$REPO/reference/test-games"
  CANDIDATES=()
  if [ -d "$TEST_GAMES_DIR" ]; then
    for entry in "$TEST_GAMES_DIR"/*/; do
      [ -d "$entry" ] || continue
      CANDIDATES+=("${entry%/}")
    done
  fi
  if [ "${#CANDIDATES[@]}" -eq 1 ]; then
    GAME="${CANDIDATES[0]}"
    echo "# 未设 MOCHI_AC8_GAME，自动使用 reference/test-games/ 下唯一的作品：$GAME"
  else
    echo "AC8 FAIL: 未设 MOCHI_AC8_GAME，且 ${TEST_GAMES_DIR#$REPO/} 下有 ${#CANDIDATES[@]} 个作品目录（自动选择要求恰好 1 个）" >&2
    echo "用法：MOCHI_AC8_GAME=/path/to/game bash Scripts/ac8_capture.sh" >&2
    echo "      作品目录须含 index.html（MV）或 www/index.html（MZ）；取证方式见脚本头部注释" >&2
    exit 2
  fi
fi
DURATION="${MOCHI_AC8_DURATION:-300}"
# 本作开场 OP 约 135s，实测等满 150s 画面仍在 OP（无任何可译文字）。默认给 300s：
# 抓帧现在等「第一条译文出现」才发生，duration 只负责留足余量，不再兼任计时器。
OP_WAIT_SEC="${MOCHI_AC8_OP_WAIT:-150}"
ECHO_PORT="${MOCHI_AC8_PORT:-8789}"
OUT="${MOCHI_AC8_OUT:-/tmp/ac8-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$OUT"
PLAY_LOG="$OUT/play.log"
JSONL="$OUT/text.jsonl"
ECHO_LOG="$OUT/echo.log"
PNG="$OUT/window.png"

if [ ! -x "$BIN" ]; then
  echo "AC8 FAIL: 找不到可执行文件 ${BIN}（先跑 bash Scripts/build.sh）"
  exit 2
fi
# MV 的入口在作品根，MZ 的在 www/ 下（本仓库 reference/test-games 里的作品是 MZ）。
if [ ! -f "$GAME/index.html" ] && [ ! -f "$GAME/www/index.html" ]; then
  echo "AC8 FAIL: 游戏目录不可用：$GAME 下既无 index.html 也无 www/index.html（用 MOCHI_AC8_GAME 指定）"
  exit 2
fi

SHA_FULL="$(shasum -a 256 "$BIN" | awk '{print $1}')"
SHA="${SHA_FULL:0:16}"
STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
echo "# AC-8 取证开始 sha=$SHA_FULL stamp=$STAMP"
echo "# 产物目录：$OUT"

# ---------------------------------------------------------------- 后端
node Fixtures/mock_openai_server.mjs --echo "$ECHO_PORT" >"$ECHO_LOG" 2>&1 &
ECHO_PID=$!
sleep 1
if ! kill -0 "$ECHO_PID" 2>/dev/null; then
  echo "AC8 FAIL: echo 后端没起来（端口 $ECHO_PORT 可能被占；用 MOCHI_AC8_PORT 换一个）"
  tail -5 "$ECHO_LOG"
  exit 2
fi

cleanup() {
  [ -n "${PLAY_PID:-}" ] && kill "$PLAY_PID" 2>/dev/null
  [ -n "${ECHO_PID:-}" ] && kill "$ECHO_PID" 2>/dev/null
  # 兜底：绝不留一个前台游戏窗口给下一个人。
  #
  # **必须按本次运行的 --out 路径精确匹配，不许 pkill -f "MochiBox --play"。**
  # 2026-10-22 实测：本机同时跑两个 E2E 时，宽匹配会杀掉别人正在跑的 --play 进程
  # （工程师的 AC-2 在 12:01:04 就是这样被 SIGTERM 打断的，exit 143）。
  if [ -n "${JSONL:-}" ]; then
    pkill -f -- "--out $JSONL" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 起窗口（**不带 --headless**）
"$BIN" --play "$GAME" --provider openai --endpoint "http://127.0.0.1:$ECHO_PORT" \
       --duration "$DURATION" --out "$JSONL" >"$PLAY_LOG" 2>&1 &
PLAY_PID=$!

# 1) 等 window_id 出现（最多 30s）。拿不到就是"内核没起来"，直接失败并打日志尾。
WID=""
for _ in $(seq 1 60); do
  WID=$(sed -n 's/^play: window_id=\([0-9]*\).*/\1/p' "$PLAY_LOG" | tail -1)
  [ -n "$WID" ] && break
  if ! kill -0 "$PLAY_PID" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ -z "$WID" ]; then
  echo "AC8 FAIL: 30s 内没有 play: window_id=（内核没起来）"
  echo "--- play.log 末 30 行 ---"
  tail -30 "$PLAY_LOG"
  grep -m1 '^error_code:' "$PLAY_LOG" || true
  exit 1
fi
echo "# window_id=$WID"

# 2) 等开场 OP 播完 **并且画面里真的出现了译文**，再抓帧。
#
# 为什么不用固定秒数：2026-10-22 实测，等满 150s 抓到的仍是开场 OP 的深蓝夜空帧
# （`1632 1312 627 22.2`，非空白但一个字都没有），而那时 `translated=0`——
# 抓帧时机与「标题菜单出现」之间没有固定对应关系，本作 OP 长度还会浮动。
# 改成**等第一个 `"status":"translated"` 落进 JSONL** 再抓：抓帧时刻必然与
# 「画面上已有可译文本」同一时刻，与 OP 长短解耦。
# 上限 = duration - 30s（跟着 duration 走，不跟着魔数走），等不到就照抓，
# 让后续判据去判 FAIL —— 不在这里替判据做决定。
WAITED=0
WAIT_CAP=$((DURATION - 30))
[ "$WAIT_CAP" -gt 0 ] || WAIT_CAP=30
echo "# 等译文出现（上限 ${WAIT_CAP}s = duration-30）…"
while [ "$WAITED" -lt "$WAIT_CAP" ]; do
  if grep -q '^play: window_closed=1' "$PLAY_LOG"; then
    echo "# 注意：等待期间窗口已关闭（window_closed=1），照常抓帧再由判据裁"
    break
  fi
  if ! kill -0 "$PLAY_PID" 2>/dev/null; then break; fi
  TRANS_NOW="$(grep -c '"status":"translated"' "$JSONL" 2>/dev/null || true)"
  if [ "${TRANS_NOW:-0}" -ge 1 ] 2>/dev/null; then
    echo "# 第 ${WAITED}s 出现第 1 条译文，开始抓帧"
    break
  fi
  sleep 3
  WAITED=$((WAITED + 3))
done
if [ "${TRANS_NOW:-0}" -lt 1 ] 2>/dev/null; then
  echo "# 警告：等满 ${WAITED}s 仍无译文，照常抓帧并由判据 2 判 FAIL"
fi

# 3) 抓真实桌面像素（`-x` 不播声音、`-o` 去掉窗口阴影）。
#
# **连抓 3 张、取 distinct_colors 最大的那张**：开场 OP 里有近乎全黑的帧（白字幕 + 全黑底），
# 单张抓图撞上黑场会假失败。判据没放宽 —— 最终仍要求选出来的那张 `distinct_colors > 1`。
xcrun swiftc -O Tests/qa/frame_stats.swift -o "$OUT/frame_stats" -framework AppKit 2>/dev/null
BEST_DISTINCT=0
BEST_PNG=""
for i in 1 2 3; do
  CAND="$OUT/window-$i.png"
  screencapture -x -o -l"$WID" "$CAND" 2>/dev/null
  if [ ! -s "$CAND" ]; then
    echo "# 抓帧 ${i}：screencapture 没有产出 PNG"
    sleep 2
    continue
  fi
  CAND_STATS="$("$OUT/frame_stats" "$CAND" 2>/dev/null)"
  CAND_DISTINCT="$(printf '%s' "$CAND_STATS" | awk '{print $3}')"
  echo "# 抓帧 ${i}：distinct=${CAND_DISTINCT:-?} stats=${CAND_STATS:-?} png=$CAND"
  if [ "${CAND_DISTINCT:-0}" -gt "$BEST_DISTINCT" ] 2>/dev/null; then
    BEST_DISTINCT="$CAND_DISTINCT"
    BEST_PNG="$CAND"
  fi
  sleep 2
done
if [ -z "$BEST_PNG" ]; then
  echo "AC8 FAIL: 3 次 screencapture 都没产出 PNG（window_id=${WID}）"
  exit 1
fi
cp "$BEST_PNG" "$PNG"
echo "# 采用 ${BEST_PNG}（distinct=${BEST_DISTINCT}）→ $PNG"

wait "$PLAY_PID"
PLAY_EXIT=$?
kill "$ECHO_PID" 2>/dev/null
ECHO_PID=""

# ---------------------------------------------------------------- 机器判据
xcrun swiftc -O Tests/qa/frame_stats.swift -o "$OUT/frame_stats" -framework AppKit 2>/dev/null
STATS="$("$OUT/frame_stats" "$PNG" 2>/dev/null)"
STATS_EXIT=$?
DISTINCT="$(printf '%s' "$STATS" | awk '{print $3}')"
ERROR_CODES="$(grep -c '^error_code:' "$PLAY_LOG" 2>/dev/null || true)"
[ -z "$ERROR_CODES" ] && ERROR_CODES=0
TRANS="$(grep -c '"status":"translated"' "$JSONL" 2>/dev/null || true)"
[ -z "$TRANS" ] && TRANS=0
DIAMOND="$(grep -c '◇' "$JSONL" 2>/dev/null || true)"
[ -z "$DIAMOND" ] && DIAMOND=0
PROBE="$(sed -n 's/^play: probe=//p' "$PLAY_LOG" | tail -1)"
REPLACED="$(printf '%s' "$PROBE" | sed -n 's/.*"replaced":\([0-9]*\).*/\1/p')"
[ -z "$REPLACED" ] && REPLACED=0
# 判据 3 的"无凭据"状态：`play: probe=` 是 drain 收尾时才打印的。内置内核下若窗口
# 先于收尾被关闭（用户点红叉 / 外部干预），这行就永远不会出现 —— 2026-10-22 实测：
# 一轮 `translated=3` 且像素里确有 `◇` 的取证，因为 `window_closed=1` 而没有 probe 行。
# 此时**不许**判 FAIL（那是否定像素事实），也**不许**判 PASS（那是拿别的证据冒充）。
# 单独给退出码 3 = "机器判据 n-1 条全中，判据 3 需人工签"。
CAPTURED="$(sed -n 's/.*captured=\([0-9]*\).*/\1/p' "$PLAY_LOG" | tail -1)"

# 判据 7/8 的原料：`play: http=` 与 `play: window_id=` 两行（架构师 P1-3，2026-10-22 复核要求）
HTTP_LINE="$(sed -n '/^play: http=/p' "$PLAY_LOG" | tail -1)"
WID_LINE="$(sed -n '/^play: window_id=/p' "$PLAY_LOG" | tail -1)"
CONTENT="$(printf '%s' "$HTTP_LINE" | sed -n 's/.*content=\([0-9]*x[0-9]*\).*/\1/p')"
TITLE="$(printf '%s' "$WID_LINE" | sed -n 's/^play: window_id=[0-9]* title=//p')"

KERNEL_OK=0
printf '%s' "$HTTP_LINE" | grep -q 'kernel=embedded' && KERNEL_OK=1

CONTENT_OK=0
if [ -n "$CONTENT" ]; then
  CONTENT_W="${CONTENT%x*}"
  CONTENT_H="${CONTENT#*x}"
  if [ "${CONTENT_W:-0}" -gt 0 ] 2>/dev/null && [ "${CONTENT_H:-0}" -gt 0 ] 2>/dev/null; then
    CONTENT_OK=1
  fi
fi
if [ -n "${MOCHI_AC8_EXPECT_CONTENT:-}" ]; then
  # 显式指定期望尺寸时按精确值判（本作为 816x624）
  CONTENT_OK=0
  [ "$CONTENT" = "$MOCHI_AC8_EXPECT_CONTENT" ] && CONTENT_OK=1
fi

TITLE_OK=0
[ -n "$TITLE" ] && TITLE_OK=1

# 判据 9：场景必须真的离开 Scene_Boot（导航成功 ≠ 游戏跑起来）
SCENE="$(sed -n 's/^play: scene=\([A-Za-z0-9_]*\).*/\1/p' "$PLAY_LOG" | tail -1)"
SCENE_OK=0
case "$SCENE" in
  ""|none|Scene_Boot) SCENE_OK=0 ;;
  *) SCENE_OK=1 ;;
esac

echo "AC8 sha=$SHA_FULL exit=$PLAY_EXIT window_id=$WID translated=$TRANS jsonl_diamond=$DIAMOND stats=$STATS captured=${CAPTURED:-?}"
echo "AC8 replaced=$REPLACED error_codes=$ERROR_CODES png=$PNG"
echo "AC8 kernel=embedded:${KERNEL_OK} content=${CONTENT:-?}:${CONTENT_OK} title=\"${TITLE}\":${TITLE_OK} scene=${SCENE:-?}:${SCENE_OK}"

FAIL=0
PENDING=0
if [ "$PLAY_EXIT" != "0" ]; then echo "AC8 FAIL[1]: 退出码 $PLAY_EXIT"; FAIL=1; fi
if [ "$ERROR_CODES" != "0" ]; then echo "AC8 FAIL[1]: 出现 $ERROR_CODES 行 error_code:"; FAIL=1; fi
if [ "${TRANS:-0}" -lt 1 ] 2>/dev/null; then echo "AC8 FAIL[2]: translated=${TRANS}（应为正数）"; FAIL=1; fi
if [ -z "$PROBE" ]; then
  # 没有 probe 行 ≠ 没回绘。窗口先于 drain 收尾关闭时这行结构化地拿不到。
  echo "AC8 PENDING[3]: 无 play: probe= 行（窗口在 drain 收尾前已关闭），replaced 无法机器判定"
  echo "                 → 必须人工确认 ${PNG} 里确有 ◇ 前缀译文；确认则判据 3 满足"
  PENDING=1
elif [ "${REPLACED:-0}" -lt 1 ] 2>/dev/null; then
  echo "AC8 FAIL[3]: probe.replaced=${REPLACED}（译文没回到画面）"
  FAIL=1
fi
if [ "${DISTINCT:-0}" -lt 2 ] 2>/dev/null || [ "$STATS_EXIT" = "3" ]; then
  echo "AC8 FAIL[4]: 截图疑似空白（distinct=${DISTINCT:-?} stats=$STATS png=${PNG}）"
  FAIL=1
fi
if [ "$KERNEL_OK" != "1" ]; then
  echo "AC8 FAIL[7]: 不是内置内核（play: http= 行缺 kernel=embedded）→ $HTTP_LINE"
  FAIL=1
fi
if [ "$CONTENT_OK" != "1" ]; then
  if [ -n "${MOCHI_AC8_EXPECT_CONTENT:-}" ]; then
    echo "AC8 FAIL[7]: 窗口内容尺寸 $CONTENT ≠ 期望 $MOCHI_AC8_EXPECT_CONTENT"
  else
    echo "AC8 FAIL[7]: 窗口内容尺寸缺失或非法（content=${CONTENT:-空}）→ $HTTP_LINE"
  fi
  FAIL=1
fi
if [ "$TITLE_OK" != "1" ]; then
  echo "AC8 FAIL[8]: 窗口标题为空 → $WID_LINE"
  FAIL=1
fi
if [ "$SCENE_OK" != "1" ]; then
  echo "AC8 FAIL[9]: 场景没离开 Scene_Boot（scene=${SCENE:-未打印}）——导航成功不等于游戏跑起来"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "--- 排查材料 ---"
  echo "play.log:  $PLAY_LOG"
  echo "text.jsonl: $JSONL"
  echo "echo.log:   $ECHO_LOG"
  echo "window.png: $PNG"
  echo "--- play.log 末 20 行 ---"
  tail -20 "$PLAY_LOG"
  echo "--- text.jsonl 末 10 行 ---"
  tail -10 "$JSONL" 2>/dev/null
  exit 1
fi

if [ "$PENDING" -ne 0 ]; then
  echo "AC8 INCOMPLETE：9 条判据中除判据 3 外全部命中；判据 3 **没有**机器凭据"
  echo "  sha=$SHA_FULL"
  echo "  为什么不算 PASS：判据 3（probe.replaced>=1）是「译文真的回绘到页面」的唯一机器证据。"
  echo "  人眼看截图不算 —— 那是不可复现的判断，正是 BUG-12「静默假成功」的形状。"
  echo "  为什么不算 FAIL：像素里可能确实有译文，判 FAIL 是否定事实。"
  echo "  → 处置：**重跑**（本脚本不提供人工签入口）。连跑两次都缺，就是产品缺陷："
  echo "     agentProbeJSON() 在窗口关闭后返回 nil（Sources/App/AttachCLI.swift:681），"
  echo "     内置内核下窗口先于收尾关闭时这行结构化地拿不到，需单独修。"
  exit 3
fi

echo "AC8 PASS（第 5 条需人工确认）：请肉眼查看 $PNG 里是否有 ◇ 前缀的译文"
echo "AC8 sha=$SHA_FULL stamp=$STAMP"
exit 0
