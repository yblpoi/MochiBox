#!/usr/bin/env bash
#
# build-ffmpeg.sh -- 为 MochiBox 构建可复现的精简静态 ffmpeg（arm64 / macOS）。
#
# 产出:
#   vendor/media/ffmpeg                          单文件、静态链接、stripped、无 Homebrew 依赖
#   vendor/media/licenses/ffmpeg-COPYING.LGPLv2.1
#   vendor/media/licenses/libvpx-LICENSE
#
# 为什么要自带一份 ffmpeg:
#   .mpon 是 WebM(V_VP9 + Opus)，alpha 平面放在 Matroska BlockAdditions 里。
#   VideoToolbox 不向第三方提供 VP9 解码器（VTDecompressionSessionCreate 返回
#   -12906），所以 VP9 解码必须由 libvpx 完成；编码则必须走 hevc_videotoolbox +
#   -alpha_quality>0 + -vtag hvc1（hev1 在 WKWebView 里直接 NotSupportedError）。
#   系统里没有能同时做这两件事的可执行文件，于是把它静态链进来。
#
# 许可证:
#   ffmpeg 主体  LGPL-2.1-or-later（本脚本从不传 --enable-gpl / --enable-nonfree，
#                也不启用 x264 / x265 / xvid / fdk-aac 等 GPL 组件）
#   libvpx       BSD-3-Clause
#   两者都可再分发；随二进制把许可证文本复制到 vendor/media/licenses/。
#
# 用法:
#   bash Scripts/build-ffmpeg.sh                 # 增量：已构建过就直接跑自检
#   bash Scripts/build-ffmpeg.sh --force         # 强制重编
#   MOCHI_MEDIA_SAMPLE=/path/x.mpon bash Scripts/build-ffmpeg.sh   # 带真实素材自检
#
# 版本下限（实测结论，别抄作业抄回老版本）:
#   先用 ffmpeg 7.1.5 编了一版，转码能跑、tag 也是 hvc1，但 hvcC 里**只有一组**
#   VPS/SPS/PPS —— alpha 层根本没进码流，WKWebView 里就是一张不透明的图。
#   7.1.5 的 videotoolboxenc.c 只在 `avctx->pix_fmt == AV_PIX_FMT_BGRA` 时下发
#   TargetQualityForAlpha（9.0.2 改成了只看 codec_id + alpha_quality），实测即便
#   显式 -pix_fmt bgra 也编不出 alpha。换成 9.0.2（与验证路线同版本）后
#   hvcC 立刻变成 SPS=2/PPS=2。所以默认锁 9.x，构建末尾也会检查 SPS 数量。
#
# 可覆盖的环境变量:
#   FFMPEG_VERSION  默认 9.0.2（别随便降版本，见上面"版本下限"）
#   LIBVPX_VERSION  默认 1.15.0
#   OUT             默认 <repo>/vendor/media/ffmpeg
#   WORK            默认 <repo>/build/media-toolchain
#   JOBS            默认 sysctl -n hw.ncpu
#   MIN_MACOS       默认 13.0（与 Scripts/build.sh 的部署目标一致）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
LIBVPX_VERSION="${LIBVPX_VERSION:-1.15.0}"
OUT="${OUT:-$ROOT/vendor/media/ffmpeg}"
WORK="${WORK:-$ROOT/build/media-toolchain}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
MIN_MACOS="${MIN_MACOS:-13.0}"
SAMPLE="${MOCHI_MEDIA_SAMPLE:-}"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "warn: 忽略未知参数 $arg" >&2 ;;
  esac
done

SRC="$WORK/src"
DL="$WORK/downloads"
BLD="$WORK/build"
PREFIX="$WORK/prefix/libvpx"          # 只给 libvpx 用；ffmpeg 不 install，直接取二进制
LICDIR="$(dirname "$OUT")/licenses"

stage() { printf '\n==> %s\n' "$*"; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$SRC" "$DL" "$BLD" "$(dirname "$OUT")" "$LICDIR"

CFLAGS_COMMON="-arch arm64 -mmacosx-version-min=$MIN_MACOS -O3"

# ---------------------------------------------------------------------------
# Step 0 -- 工具链门槛
#
# nasm/yasm 只对 x86 汇编有意义；arm64 的 libvpx 用 clang 直接吃 .S，不需要它们。
# pkg-config 也不需要：ffmpeg 的 configure 里 libvpx 是
#   check_pkg_config ... || check_lib ... "-lvpx"
# （9.0.2 在 configure:7477），探测不到 .pc 时会回落到普通 -lvpx 链接测试，
# 只要用 --extra-cflags/-ldflags 把 -I/-L 指到自己的 prefix 即可。
# ---------------------------------------------------------------------------
stage "工具链检查"
for t in clang make curl tar strip otool; do
  command -v "$t" >/dev/null 2>&1 || die "缺少 $t（装了 Command Line Tools 就有）"
done
[ "$(uname -m)" = "arm64" ] || die "本脚本只产出 arm64 产物（当前 $(uname -m)）"
echo "    clang $(clang -dumpversion 2>/dev/null || echo '?') / jobs=$JOBS / min-macos=$MIN_MACOS"

fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then
    echo "    已存在 $(basename "$dest") ($(du -h "$dest" | cut -f1))"
    return 0
  fi
  echo "    download $url"
  curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" \
    || die "下载失败: $url"
  [ -s "$dest.part" ] || die "下载得到空文件: $url"
  mv "$dest.part" "$dest"
  [ -s "$dest" ] || die "下载产物为空: $dest"
  echo "    ok $(basename "$dest") ($(du -h "$dest" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Step 1 -- 源码
#
# ffmpeg  : 官方 release tarball（ffmpeg.org 是权威源，tarball 自带 configure）
# libvpx  : 官方 Git 的 tag 归档。注意这是 **扁平** 归档（没有顶层目录），
#           所以解到 libvpx-$LIBVPX_VERSION/ 子目录里。git archive 不含
#           vpx_version.h，但那个文件本来就是 build 期生成的。
#           没用 GitHub mirror：chromium.googlesource.com 就是上游本体。
# ---------------------------------------------------------------------------
stage "源码"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
      "$DL/ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch "https://chromium.googlesource.com/webm/libvpx/+archive/refs/tags/v$LIBVPX_VERSION.tar.gz" \
      "$DL/libvpx-$LIBVPX_VERSION.tar.gz"

if [ ! -f "$SRC/ffmpeg-$FFMPEG_VERSION/configure" ]; then
  echo "    解包 ffmpeg"
  rm -rf "$SRC/ffmpeg-$FFMPEG_VERSION"
  mkdir -p "$SRC/ffmpeg-$FFMPEG_VERSION"
  tar xf "$DL/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$SRC" || die "ffmpeg 解包失败"
  [ -f "$SRC/ffmpeg-$FFMPEG_VERSION/configure" ] || die "ffmpeg 解包后没有 configure"
fi
if [ ! -f "$SRC/libvpx-$LIBVPX_VERSION/configure" ]; then
  echo "    解包 libvpx"
  rm -rf "$SRC/libvpx-$LIBVPX_VERSION"
  mkdir -p "$SRC/libvpx-$LIBVPX_VERSION"
  tar xf "$DL/libvpx-$LIBVPX_VERSION.tar.gz" -C "$SRC/libvpx-$LIBVPX_VERSION" \
    || die "libvpx 解包失败"
  [ -f "$SRC/libvpx-$LIBVPX_VERSION/configure" ] || die "libvpx 解包后没有 configure"
fi
echo "    ffmpeg $FFMPEG_VERSION / libvpx $LIBVPX_VERSION"

# ---------------------------------------------------------------------------
# Step 2 -- libvpx（只要 VP9 解码器 + alpha）
#
# 只保留解码：vp8 和 vp9 编码器、webm/libyuv/examples/tools/docs 全关，
# --enable-small 用 -Os。不启用 vp9-highbitdepth：源是 8bit yuv420p(tv)，
# alpha 平面也是 8bit，10/12bit 用不上。
#
# --target 必须是 arm64-darwin<NN>-gcc（带版本号），不能写 arm64-darwin-gcc：
# 后者在 libvpx 的 configure.sh 里命中 `arm*-darwin-*` 分支（第 929 行），
# 会被当成 **iOS** 目标加 -miphoneos-version-min=7.0 / -isysroot <iphoneos>，
# 于是和我们的 -mmacosx-version-min 冲突，报
#   "Requested extra CFLAGS ... not supported by compiler"。
# darwin20..23 那几个才是 macOS：只加 -arch arm64、用 macosx SDK。
# 23 是这份 libvpx 认识的最高编号，正好（部署目标由我们自己的 -mmacosx-version-min 决定）。
# ---------------------------------------------------------------------------
LIBVPX_STAMP="$WORK/.libvpx-$LIBVPX_VERSION.stamp"
if [ "$FORCE" = 1 ] || [ ! -f "$PREFIX/lib/libvpx.a" ] || [ ! -f "$LIBVPX_STAMP" ]; then
  stage "libvpx $LIBVPX_VERSION (静态, 仅 VP9 解码)"
  rm -rf "$BLD/libvpx" "$PREFIX" "$LIBVPX_STAMP"
  mkdir -p "$BLD/libvpx" "$PREFIX"
  (
    cd "$BLD/libvpx"
    "$SRC/libvpx-$LIBVPX_VERSION/configure" \
      --target=arm64-darwin23-gcc \
      --prefix="$PREFIX" \
      --disable-shared --enable-static \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --disable-vp8 --disable-vp9-encoder \
      --disable-webm-io --disable-libyuv \
      --enable-small \
      --extra-cflags="$CFLAGS_COMMON" \
      > configure.log 2>&1
  ) || { tail -40 "$BLD/libvpx/configure.log" >&2; die "libvpx configure 失败（日志 $BLD/libvpx/configure.log）"; }

  stage "libvpx make -j$JOBS"
  make -C "$BLD/libvpx" -j"$JOBS" > "$BLD/libvpx/build.log" 2>&1 \
    || { tail -40 "$BLD/libvpx/build.log" >&2; die "libvpx 编译失败（日志 $BLD/libvpx/build.log）"; }
  make -C "$BLD/libvpx" install >> "$BLD/libvpx/build.log" 2>&1 \
    || { tail -40 "$BLD/libvpx/build.log" >&2; die "libvpx install 失败"; }
  [ -f "$PREFIX/lib/libvpx.a" ] || die "libvpx install 后没有 libvpx.a"
  touch "$LIBVPX_STAMP"
  echo "    libvpx.a $(du -h "$PREFIX/lib/libvpx.a" | cut -f1)"
else
  stage "libvpx $LIBVPX_VERSION (已构建，跳过)"
fi

# ---------------------------------------------------------------------------
# Step 3 -- ffmpeg configure
#
# 白名单逐条理由（都是踩过的坑，别顺手删）:
#   --disable-everything       关掉所有 codec/parser/filter/hwaccel/protocol...
#   --disable-autodetect       **不会**自动带上 videotoolbox：configure 里
#                              videotoolbox 属于 HWACCEL_AUTODETECT_LIBRARY_LIST，
#                              --disable-autodetect 会 disable_weak 它（configure:4797），
#                              于是 hevc_videotoolbox 编码器的依赖不成立、被静默丢弃。
#                              所以下面必须显式 --enable-videotoolbox。
#   --enable-hwaccel=hevc_videotoolbox  --disable-everything 连 hwaccel 一起关；
#                              要 HEVC 硬解就得显式给（会 select hevc_decoder）。
#   --enable-swscale           VP9 解出来的 yuva420p 要转成 BGRA 才能走
#                              hevc_videotoolbox 的 alpha 路径（videotoolboxenc.c:1357
#                              只有输入 pix_fmt 带 alpha 位时才下发 TargetQualityForAlpha）。
#   --enable-swresample        opus(fltp) -> aac(fltp) 的音频链路。
#   avfilter 不能关：configure 写着
#                              ffmpeg_deps="avcodec avfilter avformat threads"（configure:4377）。
#                              --disable-everything 又把滤镜全关了，而 fftools 会**写死**插入
#                              buffer/buffersink/abuffer/abuffersink/format/aformat/scale。
#                              buffer*/buffersink* 不受 CONFIG 开关控制（configure 里根本
#                              没有这几个组件名，传了会警告），format/aformat/scale 则靠
#                              configure 的 ffmpeg_select（configure:4378）自动带，
#                              这里仍显式列出来，免得将来 select 表变了静默少滤镜。
#   alphaextract + null/rawvideo muxer  只为自检：要证明"静态链进来的 libvpx
#                              能解出 alpha 平面"，就得在**没有 brew/ffprobe 的机器上**
#                              也能跑 alphaextract 把灰度 alpha 平面吐出来。原生 vp9
#                              解码器不读 Matroska BlockAdditions 里的 alpha，会报
#                              "Requested planes not available"（0 字节输出），
#                              这条断言就是防这个。代价约 10KB。
#   不启用任何 GPL 组件（--enable-gpl 不出现），产物是 LGPL-2.1+。
# ---------------------------------------------------------------------------
FF_ARGS=(
  --prefix="$WORK/prefix/ffmpeg"
  --target-os=darwin
  --arch=arm64
  --cc=clang
  --disable-shared --enable-static
  --disable-programs --disable-doc --disable-debug
  --disable-network --disable-autodetect
  --disable-everything
  --enable-small
  --enable-ffmpeg
  --enable-videotoolbox
  --enable-libvpx
  --enable-decoder=libvpx_vp9,opus
  --enable-parser=vp9,opus
  --enable-encoder=hevc_videotoolbox,aac,rawvideo
  --enable-hwaccel=hevc_videotoolbox
  --enable-demuxer=matroska
  --enable-muxer=mov,null,rawvideo
  --enable-protocol=file
  --enable-swscale
  --enable-swresample
  --enable-filter=format,aformat,scale,aresample,null,anull,trim,atrim
  --enable-filter=alphaextract
  --extra-cflags="$CFLAGS_COMMON -I$PREFIX/include"
  --extra-ldflags="-arch arm64 -mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib"
  --extra-libs="-lpthread -lm"
)

ARGS_HASH="$(printf '%s\n' "${FF_ARGS[@]}" | shasum | cut -d' ' -f1)"
FF_STAMP="$WORK/.ffmpeg-$FFMPEG_VERSION-$ARGS_HASH.stamp"

if [ "$FORCE" = 1 ] || [ ! -f "$BLD/ffmpeg/ffmpeg" ] || [ ! -f "$FF_STAMP" ]; then
  stage "ffmpeg $FFMPEG_VERSION configure"
  rm -rf "$BLD/ffmpeg" "$FF_STAMP"
  mkdir -p "$BLD/ffmpeg"
  ( cd "$BLD/ffmpeg" && "$SRC/ffmpeg-$FFMPEG_VERSION/configure" "${FF_ARGS[@]}" ) \
    > "$BLD/ffmpeg/configure.log" 2>&1 \
    || { grep -iE 'ERROR' "$BLD/ffmpeg/configure.log" | head -20 >&2
         tail -40 "$BLD/ffmpeg/configure.log" >&2
         die "ffmpeg configure 失败（日志 $BLD/ffmpeg/configure.log）"; }

  # configure 对"依赖不成立"的组件只会静默丢弃，这里显式验一遍，
  # 免得编出一个缺功能却看不出来的二进制。
  stage "configure 结果校验"
  # 组件开关写在 config_components.h（#define CONFIG_X 1），不在 config.h 里。
  need_cfg() {
    grep -q "^#define $1 1" "$BLD/ffmpeg/config_components.h" \
      || die "configure 后 $1 没启用（依赖没满足，见 configure.log）"
    echo "    $1=1"
  }
  need_cfg CONFIG_LIBVPX_VP9_DECODER
  need_cfg CONFIG_OPUS_DECODER
  need_cfg CONFIG_HEVC_VIDEOTOOLBOX_ENCODER
  need_cfg CONFIG_AAC_ENCODER
  need_cfg CONFIG_MATROSKA_DEMUXER
  need_cfg CONFIG_MOV_MUXER
  need_cfg CONFIG_FILE_PROTOCOL
  need_cfg CONFIG_SCALE_FILTER
  need_cfg CONFIG_FORMAT_FILTER
  grep -q '^#define CONFIG_GPL 0' "$BLD/ffmpeg/config.h" || die "配置里带了 GPL，违反 LGPL 约定"

  stage "ffmpeg make -j$JOBS"
  make -C "$BLD/ffmpeg" -j"$JOBS" > "$BLD/ffmpeg/build.log" 2>&1 \
    || { tail -40 "$BLD/ffmpeg/build.log" >&2; die "ffmpeg 编译失败（日志 $BLD/ffmpeg/build.log）"; }
  [ -x "$BLD/ffmpeg/ffmpeg" ] || die "make 之后没有生成 ffmpeg 可执行文件"
  touch "$FF_STAMP"
else
  stage "ffmpeg $FFMPEG_VERSION (已构建，跳过)"
fi

# ---------------------------------------------------------------------------
# Step 4 -- strip + 落盘
# ---------------------------------------------------------------------------
stage "strip + 安装到 $OUT"
cp "$BLD/ffmpeg/ffmpeg" "$OUT.tmp"
chmod +x "$OUT.tmp"
strip "$OUT.tmp" 2>/dev/null || strip -x "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "    $(ls -l "$OUT" | awk '{print $5" bytes"}')  $(du -h "$OUT" | cut -f1)"
file "$OUT" | sed 's/^/    /'

# 许可文本随产物一起走（LGPL-2.1 要求分发时附许可证；libvpx 是 BSD，要求保留声明）
stage "许可文本"
cp "$SRC/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$LICDIR/ffmpeg-COPYING.LGPLv2.1"
[ -f "$SRC/libvpx-$LIBVPX_VERSION/LICENSE" ] || die "libvpx 源码里找不到 LICENSE"
cp "$SRC/libvpx-$LIBVPX_VERSION/LICENSE" "$LICDIR/libvpx-LICENSE"
ls -l "$LICDIR" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 5 -- 自检
# ---------------------------------------------------------------------------
stage "自检: 二进制本身"
"$OUT" -version 2>&1 | sed -n '1p;/configuration:/p' | sed 's/^/    /'
BUILDCONF="$("$OUT" -hide_banner -buildconf 2>&1)"
if grep -q -- '--enable-gpl' <<< "$BUILDCONF"; then
  die "buildconf 里出现了 --enable-gpl"
fi

# 注意：不要写成 `"$OUT" ... | grep -q`。set -o pipefail 下 grep -q 命中即退出，
# ffmpeg 会因为 SIGPIPE 拿到 141，整个管道被判为失败 —— 输出越长越容易误报
# （-i 读素材时必现）。统一先落到变量，再用 here-string 匹配。
need_list() { # need_list <flag> <pattern> <中文说明>
  local listing
  listing="$("$OUT" -hide_banner "$1" 2>&1)"
  if ! grep -qi -- "$2" <<< "$listing"; then
    die "自检失败: $1 里没有 $2（$3）"
  fi
  echo "    $1 | grep $2 -> ok"
}
need_list -encoders 'hevc_videotoolbox' 'HEVC alpha 编码器'
need_list -decoders 'libvpx[-_]vp9'     'VP9 解码器'
need_list -formats  'matroska'          'webm/mkv 解封装'
need_list -muxers   'mov'               'mov 封装'

stage "自检: 动态库依赖"
LINKED="$(otool -L "$OUT")"
printf '%s\n' "$LINKED" | sed 's/^/    /'
if printf '%s\n' "$LINKED" | grep -q '/opt/homebrew\|/usr/local/Cellar\|/usr/local/lib'; then
  die "产物依赖了 Homebrew/本地库，不是自包含的"
fi

# ---------------------------------------------------------------------------
# Step 6 -- 真实素材转码（可选）
#
# MOCHI_MEDIA_SAMPLE 没给就 SKIP：CI / 干净机器上没有游戏素材。
# 下面这条命令就是 MochiBox 运行时真正会执行的那条。
# ---------------------------------------------------------------------------
stage "自检: 真实素材转码"
if [ -z "$SAMPLE" ] || [ ! -f "$SAMPLE" ]; then
  if [ -n "$SAMPLE" ]; then
    echo "    SKIP: MOCHI_MEDIA_SAMPLE 指向的文件不存在: $SAMPLE"
  else
    echo "    SKIP: 未设置 MOCHI_MEDIA_SAMPLE（例:"
    echo "          MOCHI_MEDIA_SAMPLE=/path/to/xxx.mpon bash Scripts/build-ffmpeg.sh）"
  fi
else
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/mochi-ffmpeg-check.XXXXXX")"
  trap 'rm -rf "$TMPD"' EXIT
  MOV="$TMPD/out.mov"

  echo "    源 $(ls -l "$SAMPLE" | awk '{print $5}') bytes: $(basename "$SAMPLE")"
  # 探测 alpha 标记（用途 2）: matroska 的 alpha_mode 是 stream tag，
  # 不需要 ffprobe，ffmpeg -i 的 stderr 里就带着。
  SRCINFO="$("$OUT" -hide_banner -i "$SAMPLE" 2>&1 || true)"
  if grep -q 'alpha_mode *: *1' <<< "$SRCINFO"; then
    echo "    源 alpha_mode=1 -> ok"
  else
    echo "    warn: 源里没看到 alpha_mode=1（素材本身没有 alpha？）"
  fi

  # 硬断言 1：alpha 平面必须能解出来，而且**必须走 libvpx**。
  # 原生 vp9 解码器不读 Matroska BlockAdditions 里的 alpha，会报
  # "Requested planes not available" 并吐 0 字节；只 --disable-everything 留着原生
  # 解码器的构建就是在这里现原形的。这条命令过不了 = 整条路线作废，直接 die。
  if ! "$OUT" -hide_banner -nostdin -v error -c:v libvpx-vp9 -i "$SAMPLE" \
        -frames:v 1 -vf alphaextract -f rawvideo -pix_fmt gray \
        -y "$TMPD/alpha.raw" 2> "$TMPD/alpha.log"; then
    cat "$TMPD/alpha.log" >&2
    die "VP9 alpha 解码失败（libvpx 静态链路没生效？）"
  fi
  [ -s "$TMPD/alpha.raw" ] \
    || die "alphaextract 输出 0 字节：alpha 平面没解出来（原生 vp9 解码器不带 alpha）"
  echo "    硬断言: -c:v libvpx-vp9 + alphaextract -> $(stat -f %z "$TMPD/alpha.raw") bytes ok"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$TMPD/alpha.raw" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
n = len(d)
a0 = d.count(0)
a255 = d.count(255)
print("    alpha 分布: a0=%.1f%% a255=%.1f%% min=%d max=%d avg=%.1f"
      % (100.0 * a0 / n, 100.0 * a255 / n, min(d), max(d), sum(d) / n))
if min(d) == 255:
    sys.exit("    alpha 全不透明: 这个素材本来就没透明，或 alpha 平面丢了")
PY
  fi

  start=$(date +%s)
  if ! /usr/bin/time -p "$OUT" -hide_banner -nostdin -v error \
        -c:v libvpx-vp9 -i "$SAMPLE" \
        -c:v hevc_videotoolbox -allow_sw 1 -alpha_quality 0.75 -vtag hvc1 \
        -movflags +faststart -c:a aac -b:a 128k -y "$MOV" 2>"$TMPD/time.log"; then
    cat "$TMPD/time.log" >&2
    die "转码失败（上面是 ffmpeg 的输出）"
  fi
  end=$(date +%s)
  grep -E '^(real|user|sys)' "$TMPD/time.log" | sed 's/^/    time /'
  echo "    耗时 $((end - start))s / 产物 $(ls -l "$MOV" | awk '{print $5}') bytes"

  # 容器侧: tag 必须是 hvc1（hev1 在 WKWebView 必挂）
  if command -v ffprobe >/dev/null 2>&1; then
    TAG="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_tag_string \
            -of default=nk=1:nw=1 "$MOV" 2>/dev/null | head -1)"
    echo "    ffprobe codec_tag_string=$TAG"
    [ "$TAG" = "hvc1" ] || die "产物 tag 不是 hvc1（得到 '$TAG'）"
  else
    echo "    SKIP: 没有 ffprobe，跳过容器 tag 检查"
  fi

  # 码流侧: Apple 的 HEVC alpha 是"双层"——hvcC 里会出现两组 VPS/SPS/PPS。
  # 这是最硬的证据：alpha 层真的进了码流，而不只是写了个标记。
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MOV" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
i = data.find(b'hvcC')
if i < 0:
    sys.exit('    没有 hvcC box: 不是 HEVC')
size = int.from_bytes(data[i - 4:i], 'big')
box = data[i + 4:i - 4 + size]
counts, off = {}, 23
while off < len(box):
    nal_type = box[off] & 0x3F
    n = int.from_bytes(box[off + 1:off + 3], 'big')
    off += 3
    counts[nal_type] = counts.get(nal_type, 0) + n
    for _ in range(n):
        ln = int.from_bytes(box[off:off + 2], 'big')
        off += 2 + ln
print("    hvcC: VPS=%d SPS=%d PPS=%d" % (counts.get(32, 0), counts.get(33, 0), counts.get(34, 0)))
if counts.get(33, 0) < 2:
    sys.exit('    只有一组 SPS: alpha 层没进码流')
print("    -> 两组 SPS: alpha 层存在")
PY
  else
    echo "    SKIP: 没有 python3，跳过 hvcC 参数集检查"
  fi
fi

# ---------------------------------------------------------------------------
stage "完成"
echo "    产物: $OUT"
echo "    下一步: bash Scripts/build.sh   # 会把它塞进 MochiBox.app/Contents/Resources/media/"
