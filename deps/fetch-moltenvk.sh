#!/usr/bin/env bash
# MoltenVK 1.4.2 for the RPCS3 iOS core (RPCS3_MOLTENVK_ROOT): the official static iOS build
# from KhronosGroup's releases (minos 15.0).
#
#   ./fetch-moltenvk.sh   ->  moltenvk/MoltenVK/{include,static/MoltenVK.xcframework}
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/moltenvk"
cd "$HERE/moltenvk"
[ -f MoltenVK-ios.tar ] || curl -fsSL https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar -o MoltenVK-ios.tar
tar -xf MoltenVK-ios.tar
ls MoltenVK
