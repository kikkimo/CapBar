#!/bin/zsh
set -euo pipefail

CAPBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPBAR_APP="$CAPBAR_ROOT/dist/CapBar.app"
CAPBAR_CONTENTS="$CAPBAR_APP/Contents"

swift run --package-path "$CAPBAR_ROOT" CapBarChecks
swift build --package-path "$CAPBAR_ROOT" -c release --product CapBar

mkdir -p "$CAPBAR_ROOT/dist"
rm -rf "$CAPBAR_APP"
mkdir -p "$CAPBAR_CONTENTS/MacOS" "$CAPBAR_CONTENTS/Resources"
cp "$CAPBAR_ROOT/.build/release/CapBar" "$CAPBAR_CONTENTS/MacOS/CapBar"
cp "$CAPBAR_ROOT/scripts/Info.plist" "$CAPBAR_CONTENTS/Info.plist"
cp -R "$CAPBAR_ROOT/.build/release/CapBar_CapBarCore.bundle" "$CAPBAR_CONTENTS/Resources/CapBar_CapBarCore.bundle"

CAPBAR_ICONSET="$CAPBAR_ROOT/dist/CapBar.iconset"
CAPBAR_ICON="$CAPBAR_ROOT/design/assets/capbar-app-icon.png"
rm -rf "$CAPBAR_ICONSET"
mkdir -p "$CAPBAR_ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$CAPBAR_ICON" --out "$CAPBAR_ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$CAPBAR_ICON" --out "$CAPBAR_ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$CAPBAR_ICONSET" -o "$CAPBAR_CONTENTS/Resources/CapBar.icns"
rm -rf "$CAPBAR_ICONSET"

plutil -lint "$CAPBAR_CONTENTS/Info.plist"
codesign --force --deep --sign - "$CAPBAR_APP"
xattr -cr "$CAPBAR_APP"
codesign --verify --deep --strict "$CAPBAR_APP"
"$CAPBAR_CONTENTS/MacOS/CapBar" --self-check
print "Packaged $CAPBAR_APP"
