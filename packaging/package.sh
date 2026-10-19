#!/usr/bin/env bash
# Builds RPCS3 for iOS 16 (iPad and iPhone) and packages it for TrollStore.
#
#   packaging/package.sh   -> dist/RPCS3-<version>-ios16.tipa
#
# Needs Xcode and the core built from XITRIX/rpcs3 (ios-port) for iOS 16:
#   ninja -C ../rpcs3-ios/build-ios RPCS3Core
# No Xcode project: the SwiftUI app (App/) is compiled by swiftc against the core's C API.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION=0.11.1
CORE="${RPCS3_CORE:-$ROOT/../rpcs3-ios/build-ios/rpcs3/libRPCS3Core.dylib}"  # see deps/build-core.sh
[ -f "$CORE" ] || { echo "Cœur introuvable : $CORE" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Payload/RPCS3.app"
mkdir -p "$APP/Frameworks"

# The core: stripped of local symbols, loaded from Frameworks/.
cp "$CORE" "$APP/Frameworks/libRPCS3Core.dylib"
strip -x "$APP/Frameworks/libRPCS3Core.dylib"

xcrun -sdk iphoneos swiftc -target arm64-apple-ios16.0 -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -module-name RPCS3 -import-objc-header include/Bridge.h -Iinclude \
  App/*.swift -L "$APP/Frameworks" -lRPCS3Core -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -o "$APP/RPCS3"
strip -x "$APP/RPCS3" 2>/dev/null || true

sed -e "s/@VERSION@/$VERSION/g" -e "s/@PLATFORM@/iPhoneOS/g" packaging/Info.plist.in >"$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' >"$APP/PkgInfo"

# RPCS3's in-game overlay icons and the core's translations (RPCS3Core.strings), from v0.11.
cp -R packaging/Resources/. "$APP/"

ICON=packaging/icon-512.png
for spec in "AppIcon60x60@2x:120" "AppIcon60x60@3x:180" "AppIcon76x76@2x~ipad:152" "AppIcon83.5x83.5@2x~ipad:167" "AppIcon76x76~ipad:76"; do
  sips -z "${spec##*:}" "${spec##*:}" "$ICON" --out "$APP/${spec%%:*}.png" >/dev/null
done

# Sign inside out; the app carries the JIT and memory entitlements.
codesign --force --sign - --timestamp=none "$APP/Frameworks/libRPCS3Core.dylib"
codesign --force --sign - --timestamp=none --entitlements packaging/entitlements.plist "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow || { echo "Entitlements perdus à la signature" >&2; exit 1; }

mkdir -p dist
OUT="$ROOT/dist/RPCS3-$VERSION-ios16.tipa"
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "$OUT"
