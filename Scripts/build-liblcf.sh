#!/usr/bin/env bash
#
# build-liblcf.sh -- 为 MochiBox 构建可复现的静态 liblcf（arm64 / macOS）。
#
# 产出:
#   vendor/liblcf-build/install/include/lcf/**    头文件（含生成的 config.h）
#   vendor/liblcf-build/install/lib/liblcf.a      静态库（约 5MB）
#   vendor/liblcf-build/COMMIT                    实际构建的上游 sha（幂等判据）
#
# 为什么要自带一份 liblcf:
#   RPG Maker 2000/2003 的数据库（RPG_RT.ldb）是二进制 LCF 格式，字段由反射式
#   schema 描述。自己解析要重写整套结构定义并跟着版本漂移，liblcf 已经把
#   2000/2003 的全字段与读写实现做完，且 MIT 许可、可静态链。
#
# 关键构建约束（实测结论，别按直觉改）:
#   · LIBLCF_WITH_ICU=OFF：本机没有 ICU 开发头，且**无 ICU 时
#     DetectEncodings() 会硬编码返回 {"windows-1252"}**，一旦让 liblcf 自动检测
#     就会把 Shift-JIS / GBK 文本按 cp1252 转码而损坏数据。因此 shim 一律以
#     encoding="" 加载（原始字节直通），转码由 Swift 侧 LCFTextCodec 负责。
#   · LIBLCF_WITH_XML / INI / TOOLS / TESTS 全 OFF：用不到，去掉后零 brew 依赖。
#   · 部署目标与 Scripts/build.sh 一致（13.0），架构只出 arm64。
#
# 许可证:
#   liblcf  MIT（上游 COPYING）。可静态链接、可再分发；分发二进制时附许可证文本。
#
# 用法:
#   bash Scripts/build-liblcf.sh            # 幂等：commit 匹配就跳过
#   bash Scripts/build-liblcf.sh --force    # 强制重编
#   bash Scripts/build-liblcf.sh --check    # 只报告状态，不构建（exit 0=就绪 1=缺失）
#
# 可覆盖的环境变量:
#   LIBLCF_COMMIT  默认固定的上游 sha（不要改成浮动分支名，构建必须可复现）
#   MIN_MACOS      默认 13.0
#   JOBS           默认 sysctl -n hw.ncpu
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 固定 commit：liblcf 0.8.1（HEAD 6854310）。换版本必须重跑全量 e2e 并更新这里。
LIBLCF_COMMIT="${LIBLCF_COMMIT:-6854310c3432e553fd4ae672ce861899c80c3bd0}"
LIBLCF_URL="${LIBLCF_URL:-https://github.com/EasyRPG/liblcf.git}"
MIN_MACOS="${MIN_MACOS:-13.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

SRC="${LIBLCF_SRC:-$ROOT/vendor/liblcf-src}"
BLD="${LIBLCF_BUILD:-$ROOT/vendor/liblcf-build}"
PREFIX="$BLD/install"
STAMP="$BLD/COMMIT"
LIB="$PREFIX/lib/liblcf.a"

FORCE=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "warn: 忽略未知参数 $arg" >&2 ;;
  esac
done

stage() { printf '\n==> %s\n' "$*"; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

report() {
  printf '  lib:    %s (%s)\n' "$LIB" "$(ls -lh "$LIB" | awk '{print $5}')"
  printf '  include: %s\n' "$PREFIX/include"
  printf '  commit: %s\n' "$(cat "$STAMP" 2>/dev/null || echo '?')"
}

# 就绪判据：库文件存在 **且** commit 标记与目标一致（避免换了 sha 却复用旧产物）。
is_ready() {
  [ -f "$LIB" ] || return 1
  [ -f "$STAMP" ] || return 1
  [ "$(tr -d '[:space:]' < "$STAMP")" = "$LIBLCF_COMMIT" ] || return 1
  [ -d "$PREFIX/include/lcf" ] || return 1
  return 0
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  if is_ready; then echo "liblcf: ready"; report; exit 0; fi
  echo "liblcf: missing（跑 bash Scripts/build-liblcf.sh 生成）"; exit 1
fi

if [ "$FORCE" -eq 0 ] && is_ready; then
  echo "skip: vendor/liblcf-build 已是 $LIBLCF_COMMIT"
  report
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 0 -- 工具链门槛（缺什么就说怎么装，然后非 0 退出，不做半截构建）
# ---------------------------------------------------------------------------
stage "工具链检查"
missing=""
for t in git cmake ninja; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  echo "error: 缺少构建工具:$missing" >&2
  echo "       安装: brew install cmake ninja（git 随 Command Line Tools）" >&2
  exit 1
fi
[ "$(uname -m)" = "arm64" ] || die "本脚本只产出 arm64 产物（当前 $(uname -m)）"
echo "  cmake: $(cmake --version | head -1)"
echo "  ninja: $(ninja --version)"

# ---------------------------------------------------------------------------
# Step 1 -- 浅克隆固定 commit
#
# 用 init + fetch <sha> --depth 1 而不是 clone --depth 1（后者只给分支尖端，
# 一旦上游前进就取不到我们锁的 sha）。
# ---------------------------------------------------------------------------
stage "取源码 $LIBLCF_COMMIT"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$LIBLCF_URL"
fi
have="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo '')"
if [ "$have" != "$LIBLCF_COMMIT" ] || [ ! -f "$SRC/CMakeLists.txt" ]; then
  git -C "$SRC" fetch --depth 1 -q origin "$LIBLCF_COMMIT" \
    || die "取不到 $LIBLCF_COMMIT（检查网络或 LIBLCF_URL）"
  git -C "$SRC" checkout -q -f FETCH_HEAD
fi
echo "  src: $SRC @ $(git -C "$SRC" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# Step 2 -- 构建（无 ICU / 无 XML / 无 INI / 无工具 / 无测试）
# ---------------------------------------------------------------------------
stage "configure"
rm -rf "$BLD"
mkdir -p "$BLD"
cmake -S "$SRC" -B "$BLD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DLIBLCF_WITH_ICU=OFF \
  -DLIBLCF_WITH_XML=OFF \
  -DLIBLCF_WITH_INI=OFF \
  -DLIBLCF_ENABLE_TOOLS=OFF \
  -DLIBLCF_ENABLE_TESTS=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 >"$BLD/configure.log" 2>&1 \
  || { echo "error: cmake configure 失败，日志: $BLD/configure.log" >&2; tail -30 "$BLD/configure.log" >&2; exit 1; }

stage "build"
started=$(date +%s)
cmake --build "$BLD" --parallel "$JOBS" >"$BLD/build.log" 2>&1 \
  || { echo "error: 编译失败，日志: $BLD/build.log" >&2; tail -40 "$BLD/build.log" >&2; exit 1; }
elapsed=$(( $(date +%s) - started ))

stage "install"
cmake --install "$BLD" --prefix "$PREFIX" >"$BLD/install.log" 2>&1 \
  || { echo "error: install 失败，日志: $BLD/install.log" >&2; tail -30 "$BLD/install.log" >&2; exit 1; }

[ -f "$LIB" ] || { echo "error: 没有产出 $LIB（安装布局变了？）" >&2; find "$PREFIX" -name 'liblcf.a' >&2; exit 1; }
cfg="$PREFIX/include/lcf/config.h"
[ -f "$cfg" ] || die "没有安装 lcf/config.h（shim 编译需要它）"
grep -q 'define LCF_SUPPORT_ICU 0' "$cfg" \
  || die "config.h 里 ICU 不是关闭状态，加载会走 cp1252 自动检测并损坏文本"

printf '%s\n' "$LIBLCF_COMMIT" >"$STAMP"

stage "完成（编译 ${elapsed}s）"
report
