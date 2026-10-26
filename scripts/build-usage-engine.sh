#!/bin/zsh
set -euo pipefail
CAPBAR_ENGINE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPBAR_ENGINE_CARGO="${CAPBAR_ENGINE_CARGO:-cargo}"
export CCUSAGE_PRICING_JSON_PATH="$CAPBAR_ENGINE_ROOT/Vendor/ccusage/litellm-pricing.json"
"$CAPBAR_ENGINE_CARGO" +1.97.1 build --locked --release --manifest-path "$CAPBAR_ENGINE_ROOT/UsageEngine/Cargo.toml"
install -m 755 "$CAPBAR_ENGINE_ROOT/UsageEngine/target/release/capbar-usage-engine" "$CAPBAR_ENGINE_ROOT/Sources/CapBarCore/Resources/capbar-usage-engine"
python3 "$CAPBAR_ENGINE_ROOT/scripts/verify-usage-engine.py" --record-build
