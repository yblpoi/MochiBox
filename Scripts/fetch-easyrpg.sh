#!/usr/bin/env bash
#
# fetch-easyrpg.sh -- 下载官方 EasyRPG Player 0.8.1（macOS）并抽出单文件运行时。
#
# 产出: vendor/runtime/easyrpg-player            （可执行文件，脚本会自动 chmod +x）
#       vendor/runtime/easyrpg-player.sha256     （本次产物的校验记录：zip + 二进制的 sha256）
#
# 为什么只要一个裸二进制、不要整个 .app:
#   运行时是**独立子进程**（GameLauncher 直接 exec 它），只需要一个可执行文件。
#   整个 .app 搬进 Contents/Resources 会带进 Info.plist / 图标 / 一条嵌套签名链，
#   `codesign --deep` 对嵌套 bundle 的处置还会随系统版本漂（用户见到的是"签名损坏"）。
#   裸二进制复制后重新 ad-hoc 签一次就够（见 Scripts/build.sh 的 Step 2.6）。
#
# 幂等: 已经存在就**不重复下载**，只打印现有 sha256 / 大小 / --version。
# 失败不阻断: 这是可选的开发/分发环节（与 build-ffmpeg.sh 同一口径）。
#   下载失败只意味着 RPG Maker 2000/2003 起不来，不影响构建出包。
#
set -uo pipefail    # 刻意不加 -e: 每一步失败都要能给出可读诊断，再决定退不退

VERSION="0.8.1"
URL="https://easyrpg.org/downloads/player/${VERSION}/easyrpg-player-${VERSION}-macos.app.zip"
# 上游 zip 的 sha256。留空 = 首跑，只记录不校验（之后可用环境变量固定）:
#   EASYRPG_ZIP_SHA256=<值> bash Scripts/fetch-easyrpg.sh --force
EASYRPG_ZIP_SHA256="${EASYRPG_ZIP_SHA256:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/vendor/runtime"
BIN="$DEST_DIR/easyrpg-player"
ZIP="$DEST_DIR/easyrpg-player-${VERSION}-macos.app.zip"
STAMP="$DEST_DIR/easyrpg-player.sha256"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# 从 .app 里抽出来的二进制带着**绑定 Info.plist** 的签名，离开原 bundle 后
# `codesign --verify` 报 "invalid Info.plist"，AMFI 直接把进程 SIGKILL
# （症状: 跑 `easyrpg-player --version` 显示 `Killed: 9`）。
# 所以 ad-hoc 重签是**必需步骤**，不是可选的美化。
ensure_signed() {
  if codesign --verify "$BIN" >/dev/null 2>&1; then return 0; fi
  echo "==> easyrpg: 重签 ${BIN}（原 bundle 签名离开 .app 后失效）"
  if ! codesign -s - --force --identifier org.easyrpg.player "$BIN" 2>/dev/null; then
    echo "warn: ad-hoc 重签失败 —— 该二进制大概率会被 AMFI 直接 SIGKILL" >&2
    return 1
  fi
  return 0
}

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
size() { stat -f%z "$1"; }
# 校验记录：**必须在重新签名之后写**，否则记下的是重签前的哈希（换一台机器核对不上）。
write_stamp() {
  local zip_sha="${1:-unknown}" zip_size="${2:-0}"
  printf 'version    %s\nzip-sha256 %s\nzip-size   %s\nbin-sha256 %s\nbin-size   %s\n' \
    "$VERSION" "$zip_sha" "$zip_size" "$(sha "$BIN")" "$(size "$BIN")" > "$STAMP"
}
report() {
  echo "    path:    $1"
  echo "    sha256:  $(sha "$1")"
  echo "    size:    $(size "$1") bytes"
  echo "    version: $("$BIN" --version 2>&1 | head -1)"
}

if [ -x "$BIN" ] && [ "$FORCE" -eq 0 ]; then
  echo "==> easyrpg: 已存在，跳过下载"
  ensure_signed
  # 保留首跑记录的 zip 校验值（zip 已经在抽完之后删掉了）
  PREV_ZIP_SHA="$(awk '$1 == "zip-sha256" {print $2}' "$STAMP" 2>/dev/null || true)"
  PREV_ZIP_SIZE="$(awk '$1 == "zip-size" {print $2}' "$STAMP" 2>/dev/null || true)"
  write_stamp "${PREV_ZIP_SHA:-unknown}" "${PREV_ZIP_SIZE:-0}"
  report "$BIN"
  [ -f "$ZIP" ] && echo "    zip:     $ZIP ($(sha "$ZIP"))"
  exit 0
fi

mkdir -p "$DEST_DIR" || { echo "error: 无法创建 $DEST_DIR" >&2; exit 1; }

echo "==> easyrpg: 下载 $URL"
if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 -o "$ZIP" "$URL"; then
  echo "warn: 下载失败（离线或站点不可达）。RPG Maker 2000/2003 本轮不可启动。" >&2
  rm -f "$ZIP"
  exit 1
fi

ZIP_SHA="$(sha "$ZIP")"
echo "==> easyrpg: zip sha256 = $ZIP_SHA"
if [ -n "$EASYRPG_ZIP_SHA256" ]; then
  if [ "$ZIP_SHA" != "$EASYRPG_ZIP_SHA256" ]; then
    echo "error: zip 的 sha256 不匹配（期望 ${EASYRPG_ZIP_SHA256}，实际 ${ZIP_SHA}）" >&2
    echo "       上游重发或传输被篡改都可能造成；已删除下载包。" >&2
    rm -f "$ZIP"
    exit 1
  fi
  echo "==> easyrpg: sha256 校验通过"
else
  echo "==> easyrpg: 未固定期望值（首跑）—— 只记录，不校验"
fi

# 取包内可执行文件（路径含空格，不能用 -j / 通配符拼 shell 词）
ENTRY="$(unzip -Z1 "$ZIP" 2>/dev/null | grep -m1 'Contents/MacOS/EasyRPG Player$' || true)"
if [ -z "$ENTRY" ]; then
  echo "error: 压缩包里找不到 Contents/MacOS/EasyRPG Player" >&2
  rm -f "$ZIP"
  exit 1
fi
echo "==> easyrpg: 抽出 $ENTRY"
if ! unzip -p "$ZIP" "$ENTRY" > "$BIN"; then
  echo "error: 解压失败" >&2
  rm -f "$BIN"
  exit 1
fi
chmod +x "$BIN" || { echo "error: chmod +x 失败" >&2; exit 1; }

# 重签必须在 chmod 之后（先有执行位再签，顺序反了签名仍会被判无效）。
ensure_signed || true

if ! "$BIN" --version >/dev/null 2>&1; then
  echo "warn: 抽出的二进制无法执行（架构不匹配或需要 Rosetta 2）" >&2
  echo "      在 Apple Silicon 上跑官方 x86_64 包需要: softwareupdate --install-rosetta" >&2
fi

write_stamp "$ZIP_SHA" "$(size "$ZIP")"

echo "==> easyrpg: 完成"
report "$BIN"
echo "    zip-sha: $ZIP_SHA ($(size "$ZIP") bytes)"
echo "    stamp:   $STAMP"
rm -f "$ZIP"
exit 0
