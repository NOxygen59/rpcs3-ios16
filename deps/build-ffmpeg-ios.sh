#!/usr/bin/env bash
# FFmpeg 8.1.1 for the RPCS3 iOS core (RPCS3_FFMPEG_ROOT): static libraries for iOS arm64, iOS 16.0
# minimum, with the codecs RPCS3's desktop builds enable (RPCS3/ffmpeg-core's ffmpeg.patch).
#
#   ./build-ffmpeg-ios.sh   ->  ffmpeg/{include,lib}
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=8.1.1
SRC="$HERE/ffmpeg-src/ffmpeg-$VERSION"
OUT="$HERE/ffmpeg"
MIN=16.0

mkdir -p "$HERE/ffmpeg-src"
if [ ! -d "$SRC" ]; then
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$HERE/ffmpeg-src/ffmpeg-$VERSION.tar.xz"
  tar -xf "$HERE/ffmpeg-src/ffmpeg-$VERSION.tar.xz" -C "$HERE/ffmpeg-src"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN"

BUILD="$HERE/ffmpeg-build"
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"
cd "$BUILD"
"$SRC/configure" \
  --prefix="$OUT" \
  --enable-cross-compile --target-os=darwin --arch=aarch64 \
  --cc="$CC" --as="$CC" \
  --extra-cflags="$FLAGS" --extra-ldflags="$FLAGS" \
  --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-everything --disable-network \
  --disable-openssl --disable-securetransport --disable-videotoolbox --disable-audiotoolbox \
  --disable-iconv --disable-bzlib --disable-lzma --disable-sdl2 --disable-xlib --disable-libxcb \
  --enable-decoder=aac --enable-decoder=aac_latm --enable-decoder=atrac3 --enable-decoder=atrac3p --enable-decoder=atrac9 \
  --enable-decoder=mp3 --enable-decoder=pcm_s16le --enable-decoder=pcm_s8 \
  --enable-decoder=h264 --enable-decoder=mpeg4 --enable-decoder=mpeg2video --enable-decoder=mjpeg --enable-decoder=mjpegb \
  --enable-encoder=pcm_s16le --enable-encoder=ac3 --enable-encoder=aac \
  --enable-encoder=ffv1 --enable-encoder=mpeg4 --enable-encoder=mjpeg \
  --enable-muxer=avi --enable-muxer=h264 --enable-muxer=mjpeg --enable-muxer=mp4 \
  --enable-demuxer=h264 --enable-demuxer=m4v --enable-demuxer=mp3 --enable-demuxer=mpegvideo --enable-demuxer=mpegps \
  --enable-demuxer=mjpeg --enable-demuxer=mov --enable-demuxer=avi --enable-demuxer=aac --enable-demuxer=pmp \
  --enable-demuxer=oma --enable-demuxer=pcm_s16le --enable-demuxer=pcm_s8 --enable-demuxer=wav \
  --enable-parser=h264 --enable-parser=mpeg4video --enable-parser=mpegaudio --enable-parser=mpegvideo \
  --enable-parser=mjpeg --enable-parser=aac --enable-parser=aac_latm \
  --enable-protocol=file --enable-bsf=mjpeg2jpeg \
  > "$HERE/ffmpeg-configure.log"
make -j"$(sysctl -n hw.ncpu)" > "$HERE/ffmpeg-make.log"
make install > /dev/null
grep -q "\"$VERSION\"" "$OUT/include/libavutil/ffversion.h" || echo "warning: ffversion.h doesn't say $VERSION" >&2
ls "$OUT/lib"
