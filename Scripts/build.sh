#!/usr/bin/env bash
#
# build.sh -- build MochiBox.app with the Command Line Tools only.
#   1) compile every Sources/**/*.swift into a single Mach-O (no Xcode project, no SPM, no 3rd-party deps)
#   2) assemble the .app bundle (Info.plist / PkgInfo / Resources/agent_mvmz.js)
#   3) ad-hoc code sign (codesign -s - --deep, never notarized)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MochiBox.app"
BIN="$BUILD/MochiBox"
LOG="$BUILD/compile.log"
DEFAULT_TARGET="arm64-apple-macos13.0"

# ---------------------------------------------------------------------------
# Step -1 -- 工具链定位（为什么不能直接写 swiftc / clang++）
#
# Xcode 装了但许可证未接受时，/usr/bin 下那批 Xcode shim（swiftc、clang++、git、
# xcrun … 全是）一律拒绝执行：退出码 69 + "You have not agreed to the Xcode
# license agreements"。工具链**真身**不受影响：
#   <dev>/Toolchains/XcodeDefault.xctoolchain/usr/bin/   Xcode 安装
#   <dev>/usr/bin/                                       Command Line Tools
# 但真身脱离 xcrun 后拿不到 SDK 注入，必须自己补：
#   swiftc  -sdk <sdk>          否则 "unable to load standard library for target …"
#   clang++ -isysroot <sdk>     否则 "ld: library 'c++' not found"
#
# 探测顺序（正常机器行为不变）：优先 xcrun，其次 xcode-select -p 推导的真身。
# 与 Tests/e2e/lib/toolchain.mjs 是同一套判据，改一处要改另一处。
# ---------------------------------------------------------------------------
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
TOOLCHAIN_VIA_XCRUN=1

# 走哪条路由 SDK 注入决定：
#   /usr/bin/<tool> 是 Apple 放的小 shim，它经 xcrun 注入 SDKROOT，不需要额外参数
#   （改造前跑的就是它）；工具链真身没有这层注入，缺 -sdk / -isysroot 会立刻失败。
# 所以「xcrun 能用」就用 /usr/bin 的 shim，命令行与改造前逐字一致。
xcrun_works() { xcrun --find "$1" >/dev/null 2>&1; }

# 真身候选：Xcode 的 toolchain 目录，然后是 <dev>/usr/bin（CLT 布局）。
realpath_candidate() {
  local name="$1" candidate
  for candidate in \
    "$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/$name" \
    "$DEV_DIR/usr/bin/$name"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

SWIFTC=""
CLANGXX=""
if xcrun_works swiftc && xcrun_works clang++ && \
   [ -x /usr/bin/swiftc ] && [ -x /usr/bin/clang++ ]; then
  SWIFTC=/usr/bin/swiftc
  CLANGXX=/usr/bin/clang++
elif xcrun_works swiftc && xcrun_works clang++; then
  # 有 xcrun 但没有那层 shim（少见装机形态）：用 xcrun 给的路径，自己补 SDK。
  TOOLCHAIN_VIA_XCRUN=0
  SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
  CLANGXX="$(xcrun --find clang++ 2>/dev/null || true)"
else
  TOOLCHAIN_VIA_XCRUN=0
  SWIFTC="$(realpath_candidate swiftc || true)"
  CLANGXX="$(realpath_candidate clang++ || true)"
fi
if [ -z "$SWIFTC" ]; then
  echo "error: 没有可用的 Swift 编译器：/usr/bin/swiftc 被 Xcode 许可证拦住，工具链真身也不存在" >&2
  echo "       xcode-select -p = ${DEV_DIR:-(无输出)}" >&2
  echo "       修复: sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch" >&2
  exit 2
fi
if [ -z "$CLANGXX" ]; then
  echo "error: 没有可用的 C++ 编译器：/usr/bin/clang++ 被 Xcode 许可证拦住，工具链真身也不存在" >&2
  echo "       修复: sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch" >&2
  exit 2
fi

# SDK 根目录：xcrun 优先，其次按 xcode-select 的落点分两种布局找。
SYSROOT="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ ! -d "${SYSROOT:-/nonexistent}" ]; then
  SYSROOT=""
  if [ -d "$DEV_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
    SYSROOT="$DEV_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  else
    SYSROOT="$(ls -d "$DEV_DIR/SDKs"/MacOSX*.sdk 2>/dev/null | sort -r | head -1)"
  fi
fi

# 只有走真身时才补 -isysroot：正常机器（xcrun 可用）的命令行保持原样。
CLANGXX_SYSROOT_FLAGS=()
if [ "$TOOLCHAIN_VIA_XCRUN" -eq 0 ] && [ -n "$SYSROOT" ]; then
  CLANGXX_SYSROOT_FLAGS=(-isysroot "$SYSROOT")
fi
echo "==> toolchain: swiftc=$SWIFTC"
if [ "$TOOLCHAIN_VIA_XCRUN" -eq 0 ]; then
  echo "==> toolchain: xcrun 不可用（多半是 Xcode 许可证未接受），改用真身 + SDK=${SYSROOT:-未找到}"
fi

mkdir -p "$BUILD"

# ---------------------------------------------------------------------------
# Step 0 -- UI dependency gate (P0-18).
# Core layers must never import SwiftUI/AppKit: that is what makes
# `--selftest` / `--attach` runnable under a headless SSH session.
# Layout follows what is actually landed under Sources/ (architecture §0.2):
#   forbidden: Domain / Adapters / Infra / SelfTest  +  App/{AttachCLI,Constants}.swift
#   allowed  : UI/**  and  App/AppMain.swift (the only SwiftUI entry point)
#
# v0.4 note (architecture-v0.4 §2.1): `WKWebView` requires `import WebKit`, which
# pulls in AppKit -- so **all** WebKit code lives in `Sources/UI/EmbeddedKernel/**`.
# `Sources/Adapters/PageChannel/**` only declares protocols/value types and keeps
# the kernel discoverable through `KernelRegistry` (@MainActor). Do NOT move
# WebKit code into Adapters "to keep it close to the launcher": the gate below is
# the reason `--selftest` / `--attach` still work over SSH.
# ---------------------------------------------------------------------------
UI_HITS="$(grep -REl '^import (SwiftUI|AppKit)' \
  "$ROOT/Sources/Domain" "$ROOT/Sources/Adapters" "$ROOT/Sources/Infra" \
  "$ROOT/Sources/SelfTest" "$ROOT/Sources/App/AttachCLI.swift" \
  "$ROOT/Sources/App/Constants.swift" 2>/dev/null || true)"
if [ -n "$UI_HITS" ]; then
  echo "error: core layer imports a UI framework (P0-18 violation):" >&2
  echo "$UI_HITS" >&2
  exit 2
fi
echo "==> ui gate: ok"

SOURCES="$(find "$ROOT/Sources" -name '*.swift' | sort)"
if [ -z "$SOURCES" ]; then
  echo "error: no .swift files under Sources/" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 0.6 -- 经典 RM 数据层（RPG Maker 2000/2003 的 RPG_RT.ldb）。
#
# 由 Scripts/build-liblcf.sh 产出静态 liblcf，本仓库只提供一层 C shim
# （Sources/Adapters/LCF/lcf_shim.cpp）把它的反射式字段路径暴露给 Swift。
#
# 为什么是**可选**的（与 Step 2.5 的 ffmpeg 同一口径）：
#   liblcf 需要 cmake+ninja 现场编（约 30s，5MB 静态库），不是每个开发机都有。
#   没有它时产物照常可用，只是经典 RM 数据层不可用 —— **绝不能因此让构建失败**。
#   所以：产物缺失 → 定义 MOCHI_NO_LCF，Swift 侧 #if 掉整个 LCFDatabase。
#   反过来，产物在但 shim 编不过就是真错误，必须立刻炸（不许静默降级）。
#
# 为什么 .cpp 要单独处理：下面的 SOURCES 是 `find -name '*.swift'`，收不到 .cpp；
# 而 shim 必须和 liblcf 一起链进同一个二进制。
# ---------------------------------------------------------------------------
LCF_HEADER="$ROOT/Sources/Adapters/LCF/lcf_shim.h"
LCF_SHIM="$ROOT/Sources/Adapters/LCF/lcf_shim.cpp"
LCF_PREFIX="$ROOT/vendor/liblcf-build/install"
LCF_LIB="$LCF_PREFIX/lib/liblcf.a"
LCF_FLAGS=()
if [ -f "$LCF_LIB" ] && [ -f "$LCF_HEADER" ] && [ -d "$LCF_PREFIX/include/lcf" ]; then
  echo "==> lcf: $(ls -lh "$LCF_LIB" | awk '{print $5}') liblcf.a @ $(cat "$ROOT/vendor/liblcf-build/COMMIT" 2>/dev/null || echo '?')"
  mkdir -p "$BUILD/lcf"
  # -fvisibility=hidden 只作用于**这个 .o**：shim 里没标 visibility("default") 的
  # 符号（包括它自己用的 C++ 辅助函数）不外露，Swift 侧只看得到 lcf_shim.h 里
  # 声明的那 9 个函数。注意它管不到静态库那一侧 —— liblcf.a 是按上游默认选项编的，
  # 里面的 lcf:: 符号仍然是 global（应用进程内无人抢注，代价只是 nm 里多几百行）。
  "$CLANGXX" -std=c++17 -O2 -arch arm64 -mmacosx-version-min=13.0 -fvisibility=hidden \
    ${CLANGXX_SYSROOT_FLAGS[@]+"${CLANGXX_SYSROOT_FLAGS[@]}"} \
    -c "$LCF_SHIM" \
    -I "$ROOT/Sources/Adapters/LCF" -I "$LCF_PREFIX/include" \
    -o "$BUILD/lcf/lcf_shim.o" \
    || { echo "error: lcf_shim.cpp 编译失败（产物在就说明这是真错误，不降级）" >&2; exit 1; }
  LCF_FLAGS=(-import-objc-header "$LCF_HEADER" "$BUILD/lcf/lcf_shim.o" "$LCF_LIB" -lc++)
else
  # 三个条件分开报：早期版本一律说"vendor 不存在"，误导过排查（缺的其实是头文件）。
  LCF_MISSING=""
  [ -f "$LCF_LIB" ]               || LCF_MISSING="$LCF_MISSING vendor/liblcf-build/install/lib/liblcf.a"
  [ -d "$LCF_PREFIX/include/lcf" ] || LCF_MISSING="$LCF_MISSING vendor/liblcf-build/install/include/lcf"
  [ -f "$LCF_HEADER" ]            || LCF_MISSING="$LCF_MISSING Sources/Adapters/LCF/lcf_shim.h"
  echo "==> lcf: 缺$LCF_MISSING —— 经典 RM(2000/2003) 数据层不可用"
  echo "          （需要时跑: bash Scripts/build-liblcf.sh；打包流程不依赖它）"
  LCF_FLAGS=(-DMOCHI_NO_LCF)
fi

# ---------------------------------------------------------------------------
# Step 0.5 -- SDK selection (why this exists).
#
# 本机只装了 CommandLineTools，`xcode-select -p` 指向它；里面同时有
# MacOSX27.0.sdk（默认）与 MacOSX26.5.sdk。27.0 的 SwiftUI 把 `@State` 换成了
# external macro（`macro State`），而 CLT 的 toolchain 里**没有**
# `usr/lib/swift/host/plugins/libSwiftUIMacros.dylib`（那个 dylib 只随 Xcode 发布）。
# 症状：任何 `@State` 都报
#   external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
# 并在下游炸出 `cannot find '$xxx' in scope` / `'self' is immutable` 一大片假错误。
# 26.5 里 `@State` 仍是普通属性包装器，能正常编译，且产物照样部署到 macOS 13。
#
# 规则：按版本从高到低探测「3 行 @State 能否 typecheck」，选第一个能过的 SDK；
# 一个都过不了就**不加 -sdk**，保持旧行为（别把构建搞死，也方便将来 SDK 修好后自动回落）。
# 覆盖：`MOCHI_SDKROOT=/path/to.sdk bash Scripts/build.sh`。
# ---------------------------------------------------------------------------
SDK_FLAGS=()
SDK_LABEL="default"
pick_sdk() {
  if [ -n "${MOCHI_SDKROOT:-}" ]; then
    SDK_FLAGS=(-sdk "$MOCHI_SDKROOT")
    SDK_LABEL="$MOCHI_SDKROOT"
    echo "==> sdk: ${SDK_LABEL} (MOCHI_SDKROOT)"
    return 0
  fi
  local probe="$BUILD/.sdk-probe.swift"
  cat > "$probe" <<'PROBE'
import SwiftUI
struct __MochiSDKProbe: View {
    @State private var value = 1
    var body: some View { Text("\(value)") }
}
PROBE
  local sdk candidates
  # SDK 根目录从 `xcode-select -p` 推导，不再写死绝对路径：CLT 下是 <dev>/SDKs；
  # 选了 Xcode 时该目录不存在 —— 那种布局的 SDK 在 Platforms/MacOSX.platform 下，
  # 只有走真身（xcrun 被许可证拦住）时才用，正常机器保持"不加 -sdk"的旧行为。
  if [ "$TOOLCHAIN_VIA_XCRUN" -eq 0 ] && [ -n "$SYSROOT" ]; then
    candidates="$SYSROOT"
  else
    candidates="$(ls -d "${DEV_DIR%/}/SDKs"/MacOSX*.sdk 2>/dev/null | sort -r)"
  fi
  for sdk in $candidates; do
    [ -d "$sdk/usr/include" ] || continue
    if "$SWIFTC" -swift-version 5 -typecheck -sdk "$sdk" -target "$DEFAULT_TARGET" "$probe" >/dev/null 2>&1; then
      SDK_FLAGS=(-sdk "$sdk")
      SDK_LABEL="$sdk"
      break
    fi
  done
  rm -f "$probe"
  echo "==> sdk: ${SDK_LABEL}"
}

pick_sdk

compile() {
  # shellcheck disable=SC2086
  "$SWIFTC" -O -wmo \
    -swift-version 5 \
    -parse-as-library \
    -module-name MochiBox \
    -target "$1" \
    ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} \
    $SOURCES \
    ${LCF_FLAGS[@]+"${LCF_FLAGS[@]}"} \
    -o "$BIN" \
    -framework SwiftUI -framework AppKit -framework Network \
    -framework JavaScriptCore -framework Security \
    -framework WebKit
}

echo "==> compile (target=${DEFAULT_TARGET})"
if ! compile "$DEFAULT_TARGET" 2>"$LOG"; then
  echo "warn: -target ${DEFAULT_TARGET} failed, falling back to host macOS major version" >&2
  sed -n '1,80p' "$LOG" >&2
  FALLBACK="arm64-apple-macos$(sw_vers -productVersion | cut -d. -f1).0"
  echo "==> retry (target=${FALLBACK})"
  compile "$FALLBACK"
fi
echo "==> compiled: ${BIN}"

echo "==> assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MochiBox"
chmod +x "$APP/Contents/MacOS/MochiBox"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/agent_mvmz.js" "$APP/Contents/Resources/agent_mvmz.js"
# RGSS 文本通道 hook：GameLauncher 把它的**绝对路径**写进 mkxp.json 的 preloadScript。
# 必须放在 Contents/Resources/rgss/ 下（Bundle.main.resourceURL 的固定位置）。
# 缺文件时 GameLauncher 会跳过注入、游戏按原文跑 —— 所以这里 cp 失败要当场炸，
# 不能出一个"看起来构建成功、XP/VX 却永远不翻译"的包。
mkdir -p "$APP/Contents/Resources/rgss"
cp "$ROOT/Resources/rgss/mochi_rgss_hook.rb" "$APP/Contents/Resources/rgss/mochi_rgss_hook.rb"
cp "$ROOT/Design/mochibox-icon/Mochibox.icns" "$APP/Contents/Resources/Mochibox.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# Step 2.5 -- 自带媒体工具链（Scripts/build-ffmpeg.sh 的产物）
#
# 为什么需要: .mpon 是 VP9+alpha，VideoToolbox 不提供 VP9 解码器（-12906），
# 转成 WKWebView 能吃的 HEVC-alpha 必须用"libvpx 解码 + hevc_videotoolbox 编码"
# 的自带 ffmpeg。它是可选的：没有就照常出包，只是 alpha 视频不可用，
# **绝不能因此让构建失败**。
# 许可: ffmpeg 是 LGPL-2.1+、libvpx 是 BSD-3-Clause，分发时必须附许可证文本，
# 文本由 build-ffmpeg.sh 一起产出在 vendor/media/licenses/（来源: ffmpeg 源码的
# COPYING.LGPLv2.1 与 libvpx 源码的 LICENSE）。
# ---------------------------------------------------------------------------
MEDIA_SRC="$ROOT/vendor/media/ffmpeg"
MEDIA_LIC="$ROOT/vendor/media/licenses"
MEDIA_DST="$APP/Contents/Resources/media"
if [ -x "$MEDIA_SRC" ]; then
  echo "==> bundle media toolchain ($(du -h "$MEDIA_SRC" | cut -f1))"
  mkdir -p "$MEDIA_DST/licenses"
  cp "$MEDIA_SRC" "$MEDIA_DST/ffmpeg"
  chmod +x "$MEDIA_DST/ffmpeg"
  if [ -d "$MEDIA_LIC" ]; then
    cp "$MEDIA_LIC"/* "$MEDIA_DST/licenses/" 2>/dev/null || true
  fi
  echo "==> media: $MEDIA_DST/ffmpeg (+ licenses)"
else
  echo "==> media: vendor/media/ffmpeg 不存在 —— alpha 视频兼容性不可用"
  echo "          （需要时跑: bash Scripts/build-ffmpeg.sh；打包流程不依赖它）"
fi

# ---------------------------------------------------------------------------
# Step 2.6 -- 内置游戏运行时（Scripts/fetch-easyrpg.sh 的产物）
#
# RPG Maker 2000/2003 的启动后端是 EasyRPG Player 进程。与 Step 2.5 的 ffmpeg 同一口径：
# **可选**。没有它照常出包，只是经典 RM 点了启动会报 runtime_missing（文案里带修复命令）。
# 许可: EasyRPG Player 是 GPL-3.0+。这里只随包分发**未修改**的上游二进制、
#       不做静态链接，源码获取地址随上游发布页（easyrpg.org）。
#
# 为什么复制后要重新签名: 二进制是从上游 .app 里抽出来的，原签名与落位不再对应，
#       而外层 `codesign --deep` 只在它认得 bundle 结构时才可靠 —— 先单独 ad-hoc 签，
#       免得用户看到"签名损坏"。
# ---------------------------------------------------------------------------
RUNTIME_SRC="$ROOT/vendor/runtime/easyrpg-player"
RUNTIME_DST="$APP/Contents/Resources/runtime"
if [ -x "$RUNTIME_SRC" ]; then
  echo "==> bundle game runtime ($(du -h "$RUNTIME_SRC" | cut -f1))"
  mkdir -p "$RUNTIME_DST"
  cp "$RUNTIME_SRC" "$RUNTIME_DST/easyrpg-player"
  chmod +x "$RUNTIME_DST/easyrpg-player"
  codesign -s - --force "$RUNTIME_DST/easyrpg-player" 2>/dev/null \
    || echo "warn: runtime ad-hoc sign failed (artifact is still runnable locally)"
  echo "==> runtime: $RUNTIME_DST/easyrpg-player"
else
  echo "==> runtime: vendor/runtime/easyrpg-player 不存在 —— RPG Maker 2000/2003 不可启动"
  echo "          （需要时跑: bash Scripts/fetch-easyrpg.sh；打包流程不依赖它）"
fi

# ---------------------------------------------------------------------------
# Step 2.7 -- 内置 mkxp-z（RPG Maker XP/VX/VX Ace，Scripts/fetch-mkxpz.sh 的产物）
#
# 与 Step 2.6 完全同构：**可选**，缺失时 XP/VX/VX Ace 点了启动报 runtime_missing。
# 许可: mkxp-z 是 GPL-2.0-or-later。这里分发的是**带本地补丁的构建**（workdir_current
#       + 三个 macOS 崩溃修复），对应补丁随仓库提供：vendor/mkxpz/。
#
# 一个额外约束（不是美化）: 这个二进制必须用 -Dworkdir_current=true 构建 ——
#       否则 mkxp-z 会把 cwd 改成可执行文件目录，游戏目录永远挂不上。
#       fetch-mkxpz.sh 已经核过一次，这里的 cp 只是搬运。
# ---------------------------------------------------------------------------
MKXPZ_SRC="$ROOT/vendor/runtime/mkxp-z"
MKXPZ_DST="$APP/Contents/Resources/runtime"
if [ -x "$MKXPZ_SRC" ]; then
  echo "==> bundle mkxp-z runtime ($(du -h "$MKXPZ_SRC" | cut -f1))"
  mkdir -p "$MKXPZ_DST"
  cp "$MKXPZ_SRC" "$MKXPZ_DST/mkxp-z"
  chmod +x "$MKXPZ_DST/mkxp-z"
  codesign -s - --force --identifier org.mkxp-z.runtime "$MKXPZ_DST/mkxp-z" 2>/dev/null \
    || echo "warn: mkxp-z ad-hoc sign failed (artifact is still runnable locally)"
  echo "==> runtime: $MKXPZ_DST/mkxp-z"
else
  echo "==> runtime: vendor/runtime/mkxp-z 不存在 —— RPG Maker XP/VX/VX Ace 不可启动"
  echo "          （需要时跑: bash Scripts/fetch-mkxpz.sh；打包流程不依赖它）"
fi

echo "==> ad-hoc sign"
if codesign -s - --force --deep "$APP" 2>/dev/null; then
  echo "==> signed (ad-hoc)"
else
  echo "warn: codesign failed, artifact is still runnable locally"
fi

echo "==> artifact: ${APP}"
ls -l "$APP/Contents/MacOS" "$APP/Contents/Resources"
