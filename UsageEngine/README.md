# CapBar ccusage rendering bridge

Core: ccusage 20.0.44, revision `e351d846191a0176520e8b3d8151dd80a60bc7e4`.

`Vendor/ccusage/` contains the unmodified upstream Rust tree, tests, pinned models.dev catalog/rules and the LiteLLM snapshot pinned by upstream flake.lock. `UPSTREAM.json` records all 287 upstream file hashes. No parser, deduplication, replay, token normalization, speed/long-context pricing or aggregation rule is maintained in Swift.

`src/main.rs` calls public upstream functions and serializes their daily/model results. It supplies only application inputs: one configured account root per invocation (environment), local time zone, JSON output, calculate mode and offline pricing. It does not install an HTTP fetcher. Claude calls `load_daily_summaries`; Codex calls `load_groups`, `resolve_codex_speed`, `non_cached_input_tokens`, `calculate_codex_model_cost` and `codex_model_missing_pricing`. Swift receives the amounts already calculated by the core. Swift date filters, display groupings and chart tooltips consume those rows.

Rebuild the bundled Apple Silicon helper with Rust 1.97.1:

```sh
./scripts/build-usage-engine.sh
python3 scripts/verify-usage-engine.py
```

The helper is bundled with the application; users need neither Rust, Node, Homebrew nor an installed ccusage. Ordinary Swift builds use the checked-in, source-built helper; its source/binary hashes are checked before packaging. `CAPBAR_ENGINE_CARGO` can select a cargo executable when rebuilding. Swift bounds concurrent account invocations to two and associates every returned row with that account path. This preserves upstream behavior within each account without relabeling a merged provider total as the first account. The runtime summary cache contains account/daily/model rows, not per-request conversations or tool output.

Upstream tests run unchanged:

```sh
CCUSAGE_PRICING_JSON_PATH="$PWD/Vendor/ccusage/litellm-pricing.json" cargo +1.97.1 test --locked --release --manifest-path Vendor/ccusage/rust/Cargo.toml -p ccusage-adapter-claude -p ccusage-adapter-codex -p ccusage-adapter-common -p ccusage-core --lib
```

Licenses: upstream MIT in `Vendor/ccusage/LICENSE`; transitive dependency notices are shipped as `ccusage-THIRD-PARTY-NOTICES.txt` in application resources. Engine build output is ignored by Git.
