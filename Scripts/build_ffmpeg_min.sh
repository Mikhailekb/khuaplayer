#!/bin/bash
# Khua — reproducible minimal static FFmpeg for Apple Silicon.
# Output: ThirdParty/ffmpeg-min/{include,lib}; source/output are not committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/build_common.sh
source "$SCRIPT_DIR/lib/build_common.sh"
sp_reset_build_env

NAME=ffmpeg
VERSION="$(sp_lock_get "$NAME" version)"
if [ -n "${1:-}" ] && [ "$1" != "$VERSION" ]; then
  sp_die "FFmpeg is locked to version $VERSION in deps.lock.json (received $1)"
fi

# FFmpeg's libdav1d detection and static link are part of this recipe. Always
# ensure that dependency first; its own recipe stamp makes a hit a cheap no-op.
"$SP_ROOT/Scripts/build_dav1d.sh"
"$SP_ROOT/Scripts/build_speex.sh"

URL="$(sp_lock_get "$NAME" url)"
ARCHIVE_NAME="$(sp_lock_get "$NAME" archive)"
SOURCE_DIR="$(sp_lock_get "$NAME" source_dir)"
SHA256="$(sp_lock_get "$NAME" sha256)"
PATCH_REL="$(sp_lock_get "$NAME" patches 0 path)"
PATCH_SHA="$(sp_lock_get "$NAME" patches 0 sha256)"
PATCH="$SP_ROOT/$PATCH_REL"
SPEEX_PATCH="$SP_ROOT/$(sp_lock_get "$NAME" patches 1 path)"
ANNEXB_PATCH="$SP_ROOT/$(sp_lock_get "$NAME" patches 2 path)"
ANNEXB_SEEK_PATCH="$SP_ROOT/$(sp_lock_get "$NAME" patches 3 path)"
DOVI_PATCH="$SP_ROOT/$(sp_lock_get "$NAME" patches 4 path)"
PREFIX="$SP_THIRDPARTY/ffmpeg-min"
STAMP="$PREFIX/.build-stamp.json"
REQUIRED_OUTPUTS=(
  "$PREFIX/lib/libavformat.a"
  "$PREFIX/lib/libavcodec.a"
  "$PREFIX/lib/libavutil.a"
  "$PREFIX/lib/libswscale.a"
  "$PREFIX/lib/libswresample.a"
  "$PREFIX/lib/pkgconfig/libavformat.pc"
  "$PREFIX/include/libavformat/avformat.h"
  "$PREFIX/include/libavcodec/avcodec.h"
  "$PREFIX/include/libavcodec/sp_dovi_rpu.h"
  "$PREFIX/include/libavutil/avutil.h"
  "$PREFIX/share/ffmpeg-capabilities.json"
)
DAV1D_PREFIX="$SP_THIRDPARTY/dav1d-min"
DAV1D_STAMP="$DAV1D_PREFIX/.build-stamp.json"
SPEEX_PREFIX="$SP_THIRDPARTY/speex-min"
MAKE="$(sp_find_tool make /usr/bin/make)"
NM_TOOL="$(sp_find_tool nm /usr/bin/nm)"
PKG_CONFIG_BIN="$(sp_find_tool pkg-config /opt/homebrew/bin/pkg-config)"
JOBS="$(sysctl -n hw.ncpu)"

[ "$(sp_sha256 "$PATCH")" = "$PATCH_SHA" ] || sp_die "FFmpeg patch SHA-256 does not match the lock"
[ "$(sp_sha256 "$SPEEX_PATCH")" = "$(sp_lock_get "$NAME" patches 1 sha256)" ] || sp_die "FFmpeg Speex patch SHA-256 does not match the lock"
[ "$(sp_sha256 "$ANNEXB_PATCH")" = "$(sp_lock_get "$NAME" patches 2 sha256)" ] || sp_die "FFmpeg Annex-B patch SHA-256 does not match the lock"
[ "$(sp_sha256 "$ANNEXB_SEEK_PATCH")" = "$(sp_lock_get "$NAME" patches 3 sha256)" ] || sp_die "FFmpeg Annex-B seek patch SHA-256 does not match the lock"
[ "$(sp_sha256 "$DOVI_PATCH")" = "$(sp_lock_get "$NAME" patches 4 sha256)" ] || sp_die "FFmpeg Dolby Vision patch SHA-256 does not match the lock"
[ -f "$DAV1D_PREFIX/lib/pkgconfig/dav1d.pc" ] || sp_die "dav1d installation is incomplete"
[ -f "$DAV1D_STAMP" ] || sp_die "dav1d build stamp is missing"

RECIPE_ARGS=(
  --dependency "$NAME"
  --input "$SP_ROOT/Scripts/build_ffmpeg_min.sh"
  --input "$SP_ROOT/Scripts/lib/build_common.sh"
  --input "$SP_ROOT/Scripts/lib/deps_lock.py"
  --input "$SP_ROOT/Scripts/lib/ffmpeg_capabilities.c"
  --input "$SP_ROOT/Scripts/lib/sp_dovi_rpu.c"
  --input "$SP_ROOT/Scripts/lib/sp_dovi_rpu.h"
  --input "$PATCH"
  --input "$SPEEX_PATCH"
  --input "$ANNEXB_PATCH"
  --input "$ANNEXB_SEEK_PATCH"
  --input "$DOVI_PATCH"
  --stamp "$DAV1D_STAMP"
  --stamp "$SPEEX_PREFIX/.build-stamp.json"
  --tool "ar=$AR"
  --tool "clang=$CC"
  --tool "ld=$LD"
  --tool "make=$MAKE"
  --tool "nm=$NM_TOOL"
  --tool "pkg-config=$PKG_CONFIG_BIN"
  --tool "ranlib=$RANLIB"
  --tool "xcodebuild=/usr/bin/xcodebuild"
  --parameter "prefix=$PREFIX"
  --parameter "system_compression=bzlib,zlib"
  --parameter "sdk_version=$SP_SDK_VERSION"
)
RECIPE_HASH="$(sp_recipe_hash "${RECIPE_ARGS[@]}")"
if sp_all_files_exist "${REQUIRED_OUTPUTS[@]}" && sp_stamp_matches "$STAMP" "$RECIPE_HASH"; then
  echo "==> FFmpeg $VERSION already matches the current recipe"
  exit 0
fi

mkdir -p "$SP_DOWNLOADS"
ARCHIVE="$SP_DOWNLOADS/$ARCHIVE_NAME"
sp_verified_download "$URL" "$SHA256" "$ARCHIVE"

WORK="$(mktemp -d "$SP_THIRDPARTY/.ffmpeg-build.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
sp_extract_archive "$ARCHIVE" "$WORK/src"
SOURCE="$WORK/src/$SOURCE_DIR"
[ -d "$SOURCE" ] || sp_die "FFmpeg source directory does not match the lock: $SOURCE_DIR"

echo "==> Applying the locked MOV multi-stsd seek patch"
(cd "$SOURCE" && patch --batch -F 0 -p1 < "$PATCH")
(cd "$SOURCE" && patch --batch -F 0 -p1 < "$SPEEX_PATCH")
(cd "$SOURCE" && patch --batch -F 0 -p1 < "$ANNEXB_PATCH")
(cd "$SOURCE" && patch --batch -F 0 -p1 < "$ANNEXB_SEEK_PATCH")
(cd "$SOURCE" && patch --batch -F 0 -p1 < "$DOVI_PATCH")

# GitHub tag archives lack the release VERSION file. Without it FFmpeg may
# embed the enclosing checkout's Git identity instead of the locked version.
printf '%s\n' "$VERSION" > "$SOURCE/VERSION"

# White lists: common playback demuxers/codecs/parsers only.
DEMUXERS=mov,matroska,mpegts,mpegps,avi,asf,flv,ogg,wav,mp3,flac,aac,ac3,eac3,dts,m4v,h264,hevc,ivf,mpegvideo,srt,ass,webvtt,rm,wv,ape,tta,aiff,amr,mxf,av1,obu,dv,vvc,cavsvideo,dnxhd
VDEC=h264,hevc,mpeg2video,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,vp8,vp9,prores,mjpeg,theora,flv,h263,rawvideo,libdav1d,rv30,rv40,mpeg1video,vp6,vp6f,vp6a,rv10,rv20,svq1,svq3,dvvideo,huffyuv,utvideo,vvc,cavs,dnxhd,jpeg2000,ffv1
ADEC=aac,aac_latm,ac3,eac3,mp3,mp2,mp1,opus,vorbis,flac,alac,dca,truehd,mlp,wmav1,wmav2,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw,adpcm_ima_wav,adpcm_ms,cook,sipr,ra_144,ra_288,pcm_bluray,pcm_dvd,wavpack,ape,tta,amrnb,amrwb,libspeex,wmalossless
SDEC=subrip,ass,ssa,webvtt,mov_text,text
PARSERS=h264,hevc,mpeg4video,mpegvideo,mjpeg,prores,vp8,vp9,av1,aac,aac_latm,ac3,mpegaudio,opus,vorbis,flac,dca,mlp,vvc,cavsvideo,dnxhd,jpeg2000,ffv1
BSFS=extract_extradata,av1_frame_merge

DESTDIR="$WORK/dest"
export PKG_CONFIG="$PKG_CONFIG_BIN"
export PKG_CONFIG_LIBDIR="$DAV1D_PREFIX/lib/pkgconfig:$SPEEX_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export PKG_CONFIG_SYSROOT_DIR=""
EXTRA_CFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2 -I$DAV1D_PREFIX/include"
EXTRA_LDFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$DAV1D_PREFIX/lib"

echo "==> Configuring FFmpeg $VERSION (hermetic arm64 / macOS $MACOSX_DEPLOYMENT_TARGET)"
cd "$SOURCE"
if ! ./configure \
    --prefix="$PREFIX" \
    --arch=arm64 --cc="$CC" \
    --extra-cflags="$EXTRA_CFLAGS" \
    --extra-ldflags="$EXTRA_LDFLAGS" \
    --enable-static --disable-shared \
    --disable-programs --disable-doc \
    --disable-avdevice --disable-avfilter \
    --disable-network --disable-autodetect \
    --disable-everything \
    --enable-bzlib --enable-zlib \
    --enable-libdav1d --enable-libspeex \
    --enable-demuxer="$DEMUXERS" \
    --enable-decoder="$VDEC,$ADEC,$SDEC" \
    --enable-parser="$PARSERS" \
    --enable-bsf="$BSFS" \
    --enable-protocol=file \
    --disable-iconv --disable-lzma --disable-securetransport \
    --disable-audiotoolbox --disable-videotoolbox --disable-coreimage \
    --disable-hwaccels --disable-xlib --disable-vulkan \
    --disable-debug \
    >"$WORK/configure.log" 2>&1; then
  tail -50 "$WORK/configure.log" >&2
  exit 1
fi

for feature in CONFIG_BZLIB CONFIG_ZLIB; do
  grep -qx "$feature=yes" "$SOURCE/ffbuild/config.mak" || \
    sp_die "required FFmpeg compression feature is not enabled: $feature"
done

python3 "$SP_DEPS_HELPER" verify-ffmpeg-config \
  --config "$SOURCE/ffbuild/config.mak" \
  --allow-root "$SOURCE" \
  --allow-root "$PREFIX" \
  --allow-root "$DAV1D_PREFIX" \
  --allow-root "$SPEEX_PREFIX"

echo "==> Building FFmpeg (-j$JOBS)"
if ! "$MAKE" -j"$JOBS" >"$WORK/make.log" 2>&1; then
  tail -50 "$WORK/make.log" >&2
  exit 1
fi
# Build against the pinned parser internals without exposing them in the app ABI.
"$CC" -std=c11 -O2 -isysroot "$SDKROOT" -arch arm64 \
  -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -I "$SOURCE" -I "$SP_ROOT/Scripts/lib" \
  -c "$SP_ROOT/Scripts/lib/sp_dovi_rpu.c" -o "$WORK/sp_dovi_rpu.o"
"$AR" r libavcodec/libavcodec.a "$WORK/sp_dovi_rpu.o"
"$RANLIB" libavcodec/libavcodec.a
if ! "$MAKE" DESTDIR="$DESTDIR" install >"$WORK/install.log" 2>&1; then
  tail -50 "$WORK/install.log" >&2
  exit 1
fi

STAGED_PREFIX="$DESTDIR$PREFIX"
cp "$SP_ROOT/Scripts/lib/sp_dovi_rpu.h" "$STAGED_PREFIX/include/libavcodec/sp_dovi_rpu.h"
# Check actual registration, not only configure's accepted component names.
"$CC" -std=c11 -Wall -Wextra -Werror -isysroot "$SDKROOT" -arch arm64 \
  -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -I "$STAGED_PREFIX/include" "$SP_ROOT/Scripts/lib/ffmpeg_capabilities.c" \
  -L "$STAGED_PREFIX/lib" -L "$DAV1D_PREFIX/lib" -L "$SPEEX_PREFIX/lib" \
  -lavformat -lavcodec -lswresample -lavutil -ldav1d -lspeex -lz -lbz2 \
  -o "$WORK/ffmpeg-capabilities"
mkdir -p "$STAGED_PREFIX/share"
"$WORK/ffmpeg-capabilities" > "$STAGED_PREFIX/share/ffmpeg-capabilities.json"
missing_result=0
"$WORK/ffmpeg-capabilities" --require-decoder khua_missing_decoder \
  >"$WORK/missing-capability.json" 2>"$WORK/missing-capability.log" || missing_result=$?
[ "$missing_result" -eq 1 ] || sp_die "FFmpeg missing-decoder gate must return 1, received $missing_result"
BUILT_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["ffmpeg_version"])' \
  "$STAGED_PREFIX/share/ffmpeg-capabilities.json")" || sp_die "FFmpeg capability report has no version"
[ "$BUILT_VERSION" = "$VERSION" ] || sp_die "FFmpeg embedded version $BUILT_VERSION does not match lock $VERSION"
echo "==> Verified FFmpeg $BUILT_VERSION"
LIBRARY="$STAGED_PREFIX/lib/libavformat.a"
for output in "${REQUIRED_OUTPUTS[@]}"; do
  staged_output="$STAGED_PREFIX/${output#"$PREFIX/"}"
  [ -s "$staged_output" ] || sp_die "FFmpeg installation is missing: ${output#"$PREFIX/"}"
done
ARCHS="$(lipo -archs "$LIBRARY")"
[ "$ARCHS" = "arm64" ] || sp_die "FFmpeg has an unexpected architecture: $ARCHS"
FORMAT_SYMBOLS="$("$NM_TOOL" -u "$LIBRARY")"
case "$FORMAT_SYMBOLS" in
  *"_inflate"*) ;;
  *) sp_die "FFmpeg artifact is missing the Matroska zlib decompression path" ;;
esac
case "$FORMAT_SYMBOLS" in
  *"_BZ2_bzDecompress"*) ;;
  *) sp_die "FFmpeg artifact is missing the Matroska bzlib decompression path" ;;
esac
FORMAT_PC_LIBS=" $(awk '/^Libs:/ { sub(/^Libs:[[:space:]]*/, ""); print; exit }' \
  "$STAGED_PREFIX/lib/pkgconfig/libavformat.pc") "
for compression_lib in -lbz2 -lz; do
  case "$FORMAT_PC_LIBS" in
    *" $compression_lib "*) ;;
    *) sp_die "FFmpeg pkg-config does not export static dependency: $compression_lib" ;;
  esac
done
sp_write_stamp "$STAGED_PREFIX/.build-stamp.json" "${RECIPE_ARGS[@]}"
sp_atomic_replace_directory "$STAGED_PREFIX" "$PREFIX"

echo "==> Complete: $PREFIX (recipe ${RECIPE_HASH:0:12})"
