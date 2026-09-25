#!/bin/zsh
set -euo pipefail

CAPBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPBAR_IMAGES="$CAPBAR_ROOT/docs/images"

swift run --package-path "$CAPBAR_ROOT" CapBarChecks --render-popover
mkdir -p "$CAPBAR_IMAGES"
cp /tmp/capbar-preview-dark.png "$CAPBAR_IMAGES/overview-dark.png"
cp /tmp/capbar-preview-light.png "$CAPBAR_IMAGES/overview-light.png"
cp /tmp/capbar-preview-settings.png "$CAPBAR_IMAGES/settings.png"

print "README screenshots ready in $CAPBAR_IMAGES"
