#!/usr/bin/env bash
# Builds the RPCS3 core (libRPCS3Core.dylib) for iOS 16 from NOxygen59/rpcs3, branch ipad-ios16
# (= XITRIX/rpcs3 ios-port, commit af64aca).
#
#   deps/build-core.sh [checkout-dir]    (default: ../rpcs3-ios next to this repository)
#
# Heavy: ~3100 steps, LLVM 22 included; several hours and a hot Mac. It runs at low priority
# with half the cores (JOBS=n to change); ninja resumes where it stopped if interrupted.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${1:-$HERE/../../rpcs3-ios}"
JOBS="${JOBS:-$(( $(sysctl -n hw.ncpu) / 2 ))}"

if [ ! -d "$CORE/.git" ]; then
  git clone --branch ipad-ios16 https://github.com/NOxygen59/rpcs3.git "$CORE"
fi
git -C "$CORE" submodule update --init --recursive --depth 1

[ -d "$HERE/moltenvk/MoltenVK" ] || "$HERE/fetch-moltenvk.sh"
[ -d "$HERE/ffmpeg/lib" ] || "$HERE/build-ffmpeg-ios.sh"

cd "$CORE"
[ -f build-ios/build.ninja ] || cmake -S . -B build-ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_BUILD_TYPE=Release -DRPCS3_FRONTEND=IOS \
  -DBUILD_LLVM=ON -DWITH_LLVM=ON -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_HOST_TRIPLE=arm64-apple-ios16.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios16.0 \
  -DLLVM_NO_DEAD_STRIP=ON \
  -DRPCS3_MOLTENVK_ROOT="$HERE/moltenvk/MoltenVK" -DRPCS3_FFMPEG_ROOT="$HERE/ffmpeg" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
nice -n 15 ninja -C build-ios -j "$JOBS" RPCS3Core
ls -la build-ios/rpcs3/libRPCS3Core.dylib
