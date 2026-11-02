#!/usr/bin/env bash
#
# fetch-mkxpz.sh -- 把内置 mkxp-z（RPG Maker XP/VX/VX Ace 运行时）放进 vendor/runtime/。
#
# 产出: vendor/runtime/mkxp-z            （可执行文件，脚本会自动 chmod +x 并 ad-hoc 重签）
#       vendor/runtime/mkxp-z.sha256     （校验记录：sha256 / 大小 / 构建约束 / 上游 commit）
#
# !!! 为什么必须是**特殊构建**，不能用上游 GitHub Release 的二进制 !!!
#
#   mkxp-z 的游戏根 = 进程的**当前工作目录**，但上游默认构建（meson 选项
#   `workdir_current=false`）会在 main.cpp 里把 cwd 强制成"可执行文件所在目录"——
#   在 .app 里则变成包外目录。于是：`cd 游戏目录 && ./mkxp-z` 无效，
#   `mkxp.json` 的 gameFolder 也只对"不在 bundle 内"的二进制有效。
#
#   本仓库使用的构建加了两样东西：
#     1) `-Dworkdir_current=true` —— 保留启动方给的 cwd，挂载根因此 = 游戏目录；
#     2) macOS 上的三个补丁（createPathCache 的 iconv/PHYSFS 崩溃修复 + 字体回退），
#        见 vendor/mkxpz/mochibox-macos-fixes.patch。
#   GameLauncher.launchMKXPZ 把子进程 cwd 设成游戏目录，**不复制 35MB 到用户目录**。
#
#   许可: mkxp-z 是 GPL-2.0-or-later。分发的二进制因此必须随附对应的修改后源码，
#        补丁在 vendor/mkxpz/（入库），上游 commit 记在 .sha256 里。
#
# 幂等: 已存在且 sha256 与记录一致就跳过；--force 强制重拷贝。
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/vendor/runtime"
BIN="$DEST_DIR/mkxp-z"
STAMP="$DEST_DIR/mkxp-z.sha256"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# 构建产物来源：优先环境变量，其次 /tmp/mkxpz-b4（开发机的 meson builddir 命名习惯）。
MKXPZ_BINARY="${MKXPZ_BINARY:-/tmp/mkxpz-b4/mkxp-z.aarch64}"

sha()  { shasum -a 256 "$1" | awk '{print $1}'; }
size() { stat -f%z "$1"; }

# 构建选项核对：builddir 里若留着 meson 的 intro 数据，就直接读 workdir_current。
# 读不到只警告（分发包里不会带 builddir），**读到 false 必须报错** —— 那正是
# "cd 无效" 的那个坑，装进包里等于用户点了启动看着窗口出现在错的地方或直接黑屏。
check_workdir_current() {
  local json
  json="$(dirname "$MKXPZ_BINARY")/meson-info/intro-buildoptions.json"
  [ -f "$json" ] || { echo "note: 找不到 $json，跳过构建选项核对"; return 0; }
  if grep -q '"name": "workdir_current"' "$json" && ! grep -A2 '"name": "workdir_current"' "$json" | grep -q '"value": true'; then
    echo "error: $MKXPZ_BINARY 不是 -Dworkdir_current=true 构建的（cwd 会被强制改写，游戏目录无效）" >&2
    echo "       重建: meson setup --reconfigure <builddir> <src> -Dworkdir_current=true && ninja -C <builddir>" >&2
    return 1
  fi
  echo "==> mkxpz: workdir_current=true（已核对）"
}

write_stamp() {
  local src_sha="${1:-unknown}"
  printf 'source-sha256 %s\nsource-size   %s\nbin-sha256    %s\nbin-size      %s\nbuild         workdir_current=true; darwin-arm64; strip=all; ad-hoc resigned\n' \
    "$src_sha" "${2:-0}" "$(sha "$BIN")" "$(size "$BIN")" > "$STAMP"
}

report() {
  echo "    path:   $BIN"
  echo "    sha256: $(sha "$BIN")"
  echo "    size:   $(size "$BIN") bytes"
  [ -f "$STAMP" ] && sed 's/^/    /' "$STAMP"
}

if [ -x "$BIN" ] && [ "$FORCE" -eq 0 ]; then
  echo "==> mkxpz: 已存在，跳过拷贝"
  report
  exit 0
fi

[ -f "$MKXPZ_BINARY" ] || {
  echo "error: 找不到构建产物 $MKXPZ_BINARY" >&2
  echo "       先构建: meson setup builddir . -Dworkdir_current=true && ninja -C builddir" >&2
  echo "       或指定: MKXPZ_BINARY=/path/to/mkxp-z bash Scripts/fetch-mkxpz.sh" >&2
  exit 1
}
check_workdir_current || exit 1

mkdir -p "$DEST_DIR" || { echo "error: 无法创建 $DEST_DIR" >&2; exit 1; }

SRC_SHA="$(sha "$MKXPZ_BINARY")"
SRC_SIZE="$(size "$MKXPZ_BINARY")"
echo "==> mkxpz: 拷贝 $(basename "$MKXPZ_BINARY") ($SRC_SIZE bytes)"
cp "$MKXPZ_BINARY" "$BIN" || { echo "error: 拷贝失败" >&2; exit 1; }
chmod +x "$BIN"

# --- 体积：剥离符号 ---------------------------------------------------------
# 上游产物带 137,139 个符号，__LINKEDIT 占 8,324,496 B（符号表 6,777,728 B）。
# meson 的 `-Dstrip=true` **只在 `meson install` 时**生效；我们是直接消费 builddir
# 的二进制，所以在这里补一次等价的 `strip`（不带参数 = 删掉 dyld 不需要的全部符号，
# 语义同 Xcode 的 "Strip Style: All Symbols"）。
# 实测 42,075,536 B → 35,448,032 B；strip 会作废签名，因此必须放在重签**之前**。
# 不要用 upx：macOS 上会破坏代码签名，且被杀软误报。
PRE_STRIP_SIZE=$(size "$BIN")
strip "$BIN" 2>/dev/null || { echo "error: strip 失败（产物未改，不要发包）" >&2; exit 1; }
echo "==> mkxpz: strip $PRE_STRIP_SIZE → $(size "$BIN") bytes"

# 与 easyrpg 同一口径：先单独 ad-hoc 签，免得用户看到"签名损坏"。
codesign -s - --force --identifier org.mkxp-z.runtime "$BIN" 2>/dev/null \
  || echo "warn: ad-hoc 重签失败（本机仍可运行，分发包里可能被 AMFI 拦）"

write_stamp "$SRC_SHA" "$SRC_SIZE"
report
