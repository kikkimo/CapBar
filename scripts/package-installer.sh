#!/bin/zsh
set -euo pipefail

CAPBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$CAPBAR_ROOT/scripts/package-app.sh"

CAPBAR_APP="$CAPBAR_ROOT/dist/CapBar.app"
CAPBAR_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CAPBAR_APP/Contents/Info.plist")"
CAPBAR_PACKAGE="$CAPBAR_ROOT/dist/CapBar-$CAPBAR_VERSION.pkg"

pkgbuild \
  --component "$CAPBAR_APP" \
  --install-location /Applications \
  --identifier com.kikkimo.CapBar \
  --version "$CAPBAR_VERSION" \
  "$CAPBAR_PACKAGE"

pkgutil --check-signature "$CAPBAR_PACKAGE" || true
print "Installer ready: $CAPBAR_PACKAGE"
