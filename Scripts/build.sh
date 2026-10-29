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
  local dev_dir sdk
  # SDK 根目录从 `xcode-select -p` 推导，不再写死绝对路径：CLT 下是 <dev>/SDKs；
  # 选了 Xcode 时该目录不存在 -> 探测为空 -> 走上面那条"不加 -sdk"的旧行为。
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  for sdk in $(ls -d "${dev_dir%/}/SDKs"/MacOSX*.sdk 2>/dev/null | sort -r); do
    [ -d "$sdk/usr/include" ] || continue
    if swiftc -swift-version 5 -typecheck -sdk "$sdk" -target "$DEFAULT_TARGET" "$probe" >/dev/null 2>&1; then
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
  swiftc -O -wmo \
    -swift-version 5 \
    -parse-as-library \
    -module-name MochiBox \
    -target "$1" \
    ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} \
    $SOURCES \
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

echo "==> ad-hoc sign"
if codesign -s - --force --deep "$APP" 2>/dev/null; then
  echo "==> signed (ad-hoc)"
else
  echo "warn: codesign failed, artifact is still runnable locally"
fi

echo "==> artifact: ${APP}"
ls -l "$APP/Contents/MacOS" "$APP/Contents/Resources"
