#!/bin/zsh
set -euo pipefail

CAPBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$CAPBAR_ROOT/scripts/package-app.sh"

CAPBAR_APP="$CAPBAR_ROOT/dist/CapBar.app"
CAPBAR_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CAPBAR_APP/Contents/Info.plist")"
CAPBAR_PACKAGE="$CAPBAR_ROOT/dist/CapBar-$CAPBAR_VERSION.pkg"
CAPBAR_STAGE="$(mktemp -d "$CAPBAR_ROOT/dist/.package-stage.XXXXXX")"
trap 'rm -rf "$CAPBAR_STAGE"' EXIT
mkdir -p "$CAPBAR_STAGE/root"
ditto "$CAPBAR_APP" "$CAPBAR_STAGE/root/CapBar.app"

pkgbuild \
  --root "$CAPBAR_STAGE/root" \
  --component-plist "$CAPBAR_ROOT/scripts/CapBar.component.plist" \
  --install-location /Applications \
  --identifier com.kikkimo.CapBar \
  --version "$CAPBAR_VERSION" \
  "$CAPBAR_PACKAGE"

pkgutil --expand "$CAPBAR_PACKAGE" "$CAPBAR_STAGE/expanded"
CAPBAR_INSTALL_LOCATION="$(xmllint --xpath 'string(/pkg-info/@install-location)' "$CAPBAR_STAGE/expanded/PackageInfo")"
CAPBAR_RELOCATIONS="$(xmllint --xpath 'count(/pkg-info/relocate/bundle)' "$CAPBAR_STAGE/expanded/PackageInfo")"
if [[ "$CAPBAR_INSTALL_LOCATION" != "/Applications" || "$CAPBAR_RELOCATIONS" != "0" ]]; then
  print -u2 "Installer must place CapBar in /Applications without relocation"
  exit 1
fi

pkgutil --check-signature "$CAPBAR_PACKAGE" || true
print "Installer ready: $CAPBAR_PACKAGE"
