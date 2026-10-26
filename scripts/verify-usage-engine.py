#!/usr/bin/env python3
"""Verify the immutable upstream tree and the bundled source-built engine."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parent.parent
vendor = root / "Vendor/ccusage"
upstream = json.loads((vendor / "UPSTREAM.json").read_text())
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
for name, expected in upstream["sha256"].items():
    if digest(vendor / name) != expected:
        raise SystemExit(f"Upstream source changed: {name}")
files = ["Sources/CapBarCore/Resources/capbar-usage-engine", "UsageEngine/src/main.rs", "UsageEngine/Cargo.toml", "UsageEngine/Cargo.lock"]
observed = {name: digest(root / name) for name in files}
info = root / "UsageEngine/build-info.json"
if "--record-build" in sys.argv:
    info.write_text(json.dumps({"upstream": upstream["revision"], "version": upstream["version"], "target": "aarch64-apple-darwin", "rust": "1.97.1", "sha256": observed}, indent=2) + "\n")
else:
    expected = json.loads(info.read_text())
    if expected["upstream"] != upstream["revision"] or expected["sha256"] != observed:
        raise SystemExit("Bundled engine is stale: run scripts/build-usage-engine.sh")
print(f"ccusage {upstream['version']}: {len(upstream['sha256'])} unchanged upstream files; engine/source hashes verified")
