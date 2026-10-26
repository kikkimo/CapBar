#!/bin/zsh
set -euo pipefail

CAPBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPBAR_IMAGES="$CAPBAR_ROOT/docs/images"

swift run --package-path "$CAPBAR_ROOT" CapBarChecks --render-popover
swift run --package-path "$CAPBAR_ROOT" CapBarChecks --render-token-usage
mkdir -p "$CAPBAR_IMAGES"
cp /tmp/capbar-preview-dark.png "$CAPBAR_IMAGES/overview-dark.png"
cp /tmp/capbar-preview-light.png "$CAPBAR_IMAGES/overview-light.png"
cp /tmp/capbar-preview-settings.png "$CAPBAR_IMAGES/settings.png"
cp /tmp/capbar-preview-trend-dark.png "$CAPBAR_IMAGES/trend-dark.png"
cp /tmp/capbar-preview-trend-light.png "$CAPBAR_IMAGES/trend-light.png"
cp /tmp/capbar-preview-trend-expanded-dark.png "$CAPBAR_IMAGES/trend-expanded-dark.png"
cp /tmp/capbar-preview-trend-expanded-light.png "$CAPBAR_IMAGES/trend-expanded-light.png"
cp /tmp/capbar-preview-trend-individual-light.png "$CAPBAR_IMAGES/trend-individual-light.png"

cp /tmp/capbar-token-light.png "$CAPBAR_IMAGES/token-usage-light.png"
cp /tmp/capbar-token-dark.png "$CAPBAR_IMAGES/token-usage-dark.png"
cp /tmp/capbar-token-report.png "$CAPBAR_IMAGES/token-usage-report.png"
cp /tmp/capbar-token-settings-usage.png "$CAPBAR_IMAGES/token-usage-settings-usage.png"

for variant in hover-light hover-dark models account report-light report-dark report-search report-model; do
  cp "/tmp/capbar-token-${variant}.png" "$CAPBAR_IMAGES/token-usage-${variant}.png"
done

print "README screenshots ready in $CAPBAR_IMAGES"
