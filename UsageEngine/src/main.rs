//! Rendering bridge only. All discovery, parsing, deduplication, aggregation
//! and pricing below call unmodified ccusage 20.0.44 public functions.
use ccusage_adapter_claude as claude;
use ccusage_adapter_codex as codex;
use ccusage_cli::{AgentReportKind, CodexSpeed, CostMode, SharedArgs};
use ccusage_core::{PricingMap, pricing};
use serde_json::json;

fn main() -> ccusage_core::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).is_some_and(|s| s == "--version") {
        println!("ccusage 20.0.44 / e351d846191a0176520e8b3d8151dd80a60bc7e4"); return Ok(());
    }
    pricing::set_embedded_snapshots(pricing::EmbeddedSnapshots {
        litellm_pricing: ccusage_pricing_snapshots::LITELLM_PRICING,
        models_dev_pricing: ccusage_pricing_snapshots::MODELS_DEV_PRICING,
        models_dev_catalog_rules: ccusage_pricing_snapshots::MODELS_DEV_CATALOG_RULES,
    });
    // No HTTP fetcher is installed. Pricing stays offline, exactly as -O does.
    let shared = SharedArgs {
        json: true, breakdown: true, offline: true, mode: CostMode::Calculate,
        timezone: args.get(2).cloned(), ..SharedArgs::with_defaults()
    };
    let mut rows = Vec::new();
    match args.get(1).map(String::as_str) {
        Some("claude") => {
            for summary in claude::load_daily_summaries(&shared, None, false)? {
                for model in summary.model_breakdowns {
                    rows.push(json!({
                        "date": summary.date, "model": model.model_name,
                        "input": model.input_tokens, "output": model.output_tokens,
                        "cacheWrite": model.cache_creation_tokens, "cacheRead": model.cache_read_tokens,
                        "total": model.total_tokens(), "cost": model.cost,
                        "missingPricing": model.missing_pricing
                    }));
                }
            }
        }
        Some("codex") => {
            let pricing = PricingMap::load_with_overrides(true, false, shared.pricing_overrides.iter());
            let speed = codex::resolve_codex_speed(CodexSpeed::Auto);
            for (date, group) in codex::load_groups(&shared, AgentReportKind::Daily)? {
                for (name, model) in group.models {
                    rows.push(json!({
                        "date": date, "model": name,
                        "input": codex::non_cached_input_tokens(model.input_tokens, model.cached_input_tokens, model.cache_creation_tokens),
                        "output": model.output_tokens, "cacheWrite": model.cache_creation_tokens,
                        "cacheRead": model.cached_input_tokens, "total": model.total_tokens,
                        "cost": codex::calculate_codex_model_cost(&name, &model, &pricing, speed),
                        "missingPricing": codex::codex_model_missing_pricing(&name, &model, &pricing)
                    }));
                }
            }
        }
        _ => return Err(ccusage_core::cli_error("expected claude or codex"))
    }
    serde_json::to_writer(std::io::stdout().lock(), &json!({"version": "20.0.44", "rows": rows}))?;
    Ok(())
}
