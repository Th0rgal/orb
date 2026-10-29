//! Token/cost usage summary: window parsing, filters and aggregation.
//!
//! The store returns raw harness and router records
//! ([`crate::api::mission_store::UsageRecord`]); everything here is pure so
//! the summary semantics are unit-tested without a database.
use crate::api::mission_store::{UsageRecord, UsageSource};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Hourly buckets are returned for windows up to this long.
const HOURLY_MAX_HOURS: i64 = 24 * 7;
const MAX_WINDOW_HOURS: i64 = 24 * 366 * 10;

/// A parsed `window` query value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageWindow {
    /// Canonical label echoed back (e.g. "5h", "7d", "all").
    pub label: String,
    /// Window length in hours; `None` for all time.
    pub hours: Option<i64>,
}

impl UsageWindow {
    pub fn since(&self, now: chrono::DateTime<chrono::Utc>) -> Option<String> {
        self.hours
            .map(|h| (now - chrono::Duration::hours(h)).to_rfc3339())
    }

    pub fn hourly(&self) -> bool {
        self.hours.is_some_and(|h| h <= HOURLY_MAX_HOURS)
    }
}

/// Parse `all`, `Nh`, `Nd` or `Nw` (N >= 1). Anything else is an error, not
/// a silent fall back to all time.
pub fn parse_window(raw: Option<&str>) -> Result<UsageWindow, String> {
    let raw = raw
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("all");
    let lower = raw.to_ascii_lowercase();
    if lower == "all" {
        return Ok(UsageWindow {
            label: "all".into(),
            hours: None,
        });
    }
    let invalid = || {
        format!(
            "Invalid window {raw:?}: use all, or a number followed by h, d or w (e.g. 1h, 5h, 7d)"
        )
    };
    let (digits, unit) = lower.split_at(lower.len().saturating_sub(1));
    let per_unit = match unit {
        "h" => 1,
        "d" => 24,
        "w" => 24 * 7,
        _ => return Err(invalid()),
    };
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid());
    }
    let n: i64 = digits.parse().map_err(|_| invalid())?;
    let hours = n.checked_mul(per_unit).ok_or_else(invalid)?;
    if n == 0 || hours > MAX_WINDOW_HOURS {
        return Err(invalid());
    }
    Ok(UsageWindow {
        label: format!("{n}{unit}"),
        hours: Some(hours),
    })
}

/// Optional filters. Each accepts a comma-separated list; a record matches a
/// filter when its value equals any listed value (case-insensitive). Empty
/// filters match everything.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct UsageFilter {
    #[serde(default)]
    pub backend: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
    /// Mission id.
    #[serde(default)]
    pub mission: Option<String>,
    /// "harness" or "router".
    #[serde(default)]
    pub source: Option<String>,
    /// Proxy API key id.
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    /// Caller kind (mission, subagent, hermes, orb_ui, core, script, unknown).
    #[serde(default)]
    pub caller_kind: Option<String>,
}

fn matches(filter: &Option<String>, value: Option<&str>) -> bool {
    let Some(filter) = filter.as_deref().map(str::trim).filter(|f| !f.is_empty()) else {
        return true;
    };
    let Some(value) = value else {
        return false;
    };
    filter
        .split(',')
        .map(str::trim)
        .filter(|f| !f.is_empty())
        .any(|f| f.eq_ignore_ascii_case(value))
}

impl UsageFilter {
    pub fn matches(&self, r: &UsageRecord, provider: Option<&str>) -> bool {
        matches(&self.backend, r.backend.as_deref())
            && matches(&self.provider, provider)
            && matches(&self.mission, r.mission_id.as_deref())
            && matches(&self.source, Some(r.source.as_str()))
            && matches(&self.api_key, r.api_key_id.as_deref())
            && matches(&self.model, Some(&r.model))
            && matches(&self.caller_kind, Some(&r.caller_kind))
    }
}

/// Map a normalized model identifier to a provider type id.
pub fn infer_provider_for_model(model: &str) -> Option<String> {
    let m = model.to_lowercase();
    let provider = if m.starts_with("muse-code/") {
        "muse-code"
    } else if m.contains("claude") {
        "anthropic"
    } else if m.contains("gpt")
        || m.starts_with("o3")
        || m.starts_with("o4")
        || m.contains("openai")
    {
        "openai"
    } else if m.contains("gemini") || m.starts_with("agy-") {
        "google"
    } else if m.contains("grok") {
        "xai"
    } else if m.contains("glm") || m.contains("z-ai") || m.contains("zai") {
        "zai"
    } else if m.contains("minimax") || m.contains("abab") {
        "minimax"
    } else if m.contains("muse") {
        "muse"
    } else if m.contains("kimi") {
        "kimi"
    } else if m.contains("mistral") || m.contains("codestral") {
        "mistral"
    } else if m.contains("llama") && m.contains("groq") {
        "groq"
    } else if m.contains("command") || m.contains("cohere") {
        "cohere"
    } else if m.contains("qwen") || m.contains("deepseek") {
        // Common open-router / together-ai models; default to open-router
        "open-router"
    } else {
        return None;
    };
    Some(provider.to_string())
}

/// Token and cost totals shared by every aggregate row.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct UsageTotals {
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    /// Reasoning tokens (part of `output_tokens`; router only).
    pub reasoning_tokens: u64,
    /// Sum over records with a known cost.
    pub cost_cents: u64,
    /// Records whose model has no price: their cost is not in `cost_cents`.
    pub unknown_cost_requests: u64,
}

impl UsageTotals {
    fn add(&mut self, r: &UsageRecord) {
        self.requests += 1;
        self.input_tokens = self.input_tokens.saturating_add(r.input_tokens);
        self.output_tokens = self.output_tokens.saturating_add(r.output_tokens);
        self.cache_creation_tokens = self
            .cache_creation_tokens
            .saturating_add(r.cache_creation_tokens);
        self.cache_read_tokens = self.cache_read_tokens.saturating_add(r.cache_read_tokens);
        self.reasoning_tokens = self.reasoning_tokens.saturating_add(r.reasoning_tokens);
        if r.cost_known {
            self.cost_cents = self.cost_cents.saturating_add(r.cost_cents);
        } else {
            self.unknown_cost_requests += 1;
        }
    }
}

/// "known" when every record had a price, "unknown" when none did,
/// "partial" otherwise.
fn cost_status(t: &UsageTotals) -> &'static str {
    match t.unknown_cost_requests {
        0 => "known",
        n if n == t.requests => "unknown",
        _ => "partial",
    }
}

/// Per-(model, source) usage. Router and harness rows of the same model are
/// separate rows, not merged.
#[derive(Debug, Clone, Serialize)]
pub struct ModelUsageResponse {
    pub model: String,
    /// Provider type (e.g. "anthropic", "google") or `null` when unknown.
    pub provider: Option<String>,
    pub source: UsageSource,
    pub cost_status: &'static str,
    #[serde(flatten)]
    pub totals: UsageTotals,
}

/// A generic aggregate (provider, source, backend, mission, key, account).
#[derive(Debug, Clone, Serialize)]
pub struct UsageGroup {
    /// Grouping value; `null` for records without one (e.g. router traffic
    /// without a mission, or the internal proxy secret).
    pub key: Option<String>,
    /// Display label (mission title, key name), when known.
    pub label: Option<String>,
    pub cost_status: &'static str,
    #[serde(flatten)]
    pub totals: UsageTotals,
}

/// Total tokens (input + output + cache) of one record.
fn record_tokens(r: &UsageRecord) -> u64 {
    r.input_tokens
        .saturating_add(r.output_tokens)
        .saturating_add(r.cache_creation_tokens)
        .saturating_add(r.cache_read_tokens)
}

#[derive(Debug, Clone, Default)]
struct Bucket {
    totals: UsageTotals,
    router_requests: u64,
    by_caller_kind: BTreeMap<String, u64>,
}

impl Bucket {
    fn add(&mut self, r: &UsageRecord) {
        self.totals.add(r);
        self.router_requests += u64::from(r.source == UsageSource::Router);
        let tokens = self
            .by_caller_kind
            .entry(r.caller_kind.clone())
            .or_default();
        *tokens = tokens.saturating_add(record_tokens(r));
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct DailyUsageResponse {
    /// `YYYY-MM-DD` (UTC).
    pub day: String,
    #[serde(flatten)]
    pub totals: UsageTotals,
    pub router_requests: u64,
    /// Total tokens per caller kind in this bucket.
    pub by_caller_kind: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HourlyUsageResponse {
    /// `YYYY-MM-DDTHH` (UTC).
    pub hour: String,
    #[serde(flatten)]
    pub totals: UsageTotals,
    pub router_requests: u64,
    /// Total tokens per caller kind in this bucket.
    pub by_caller_kind: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UsageSummaryResponse {
    pub window: String,
    pub since: Option<String>,
    pub cost_status: &'static str,
    pub totals: UsageTotals,
    pub by_model: Vec<ModelUsageResponse>,
    pub by_provider: Vec<UsageGroup>,
    pub by_source: Vec<UsageGroup>,
    /// `proxy` or `harness_direct`.
    pub by_route: Vec<UsageGroup>,
    pub by_caller_kind: Vec<UsageGroup>,
    /// `core` usage per purpose (`mission_title`, `unspecified`, ...).
    pub by_purpose: Vec<UsageGroup>,
    pub by_backend: Vec<UsageGroup>,
    pub by_mission: Vec<UsageGroup>,
    /// Usage rolled up to top-level missions (subagents included).
    pub by_root_mission: Vec<UsageGroup>,
    pub by_api_key: Vec<UsageGroup>,
    pub by_account: Vec<UsageGroup>,
    /// Core selections, including historical requests with unverified upstream identity.
    pub by_selected_account: Vec<UsageGroup>,
    pub by_day: Vec<DailyUsageResponse>,
    /// Only populated for windows of 7 days or less.
    pub by_hour: Vec<HourlyUsageResponse>,
}

#[derive(Default)]
struct Group {
    label: Option<String>,
    totals: UsageTotals,
}

fn add_group(
    map: &mut BTreeMap<Option<String>, Group>,
    key: Option<&str>,
    label: Option<&str>,
    r: &UsageRecord,
) {
    let group = map.entry(key.map(str::to_string)).or_default();
    if group.label.is_none() {
        group.label = label.filter(|l| !l.is_empty()).map(str::to_string);
    }
    group.totals.add(r);
}

fn by_cost(a: &UsageTotals, b: &UsageTotals) -> std::cmp::Ordering {
    b.cost_cents
        .cmp(&a.cost_cents)
        .then_with(|| b.requests.cmp(&a.requests))
}

fn groups(map: BTreeMap<Option<String>, Group>) -> Vec<UsageGroup> {
    let mut out: Vec<UsageGroup> = map
        .into_iter()
        .map(|(key, g)| UsageGroup {
            key,
            label: g.label,
            cost_status: cost_status(&g.totals),
            totals: g.totals,
        })
        .collect();
    out.sort_by(|a, b| by_cost(&a.totals, &b.totals).then_with(|| a.key.cmp(&b.key)));
    out
}

/// Filter and aggregate `records` (already limited to the window).
pub fn summarize(
    records: &[UsageRecord],
    window: &UsageWindow,
    since: Option<String>,
    filter: &UsageFilter,
) -> UsageSummaryResponse {
    let hourly = window.hourly();
    let mut totals = UsageTotals::default();
    let mut models: BTreeMap<(String, UsageSource), (Option<String>, UsageTotals)> =
        BTreeMap::new();
    let mut providers = BTreeMap::new();
    let mut sources = BTreeMap::new();
    let mut routes = BTreeMap::new();
    let mut caller_kinds = BTreeMap::new();
    let mut purposes = BTreeMap::new();
    let mut backends = BTreeMap::new();
    let mut missions = BTreeMap::new();
    let mut root_missions = BTreeMap::new();
    let mut titles: BTreeMap<&str, &str> = BTreeMap::new();
    let mut keys = BTreeMap::new();
    let mut selected_accounts = BTreeMap::new();
    let mut accounts = BTreeMap::new();
    let mut days: BTreeMap<String, Bucket> = BTreeMap::new();
    let mut hours: BTreeMap<String, Bucket> = BTreeMap::new();

    for r in records {
        if let (Some(id), Some(title)) = (r.mission_id.as_deref(), r.mission_title.as_deref()) {
            titles.insert(id, title);
        }
    }
    for r in records {
        let provider = r
            .provider
            .clone()
            .filter(|p| !p.is_empty())
            .or_else(|| infer_provider_for_model(&r.model));
        if !filter.matches(r, provider.as_deref()) {
            continue;
        }
        totals.add(r);
        let model = models
            .entry((r.model.clone(), r.source))
            .or_insert_with(|| (provider.clone(), UsageTotals::default()));
        model.1.add(r);
        add_group(&mut providers, provider.as_deref(), None, r);
        add_group(&mut sources, Some(r.source.as_str()), None, r);
        add_group(&mut routes, Some(r.source.route()), None, r);
        add_group(&mut caller_kinds, Some(&r.caller_kind), None, r);
        if r.purpose.is_some() {
            add_group(&mut purposes, r.purpose.as_deref(), None, r);
        }
        add_group(&mut backends, r.backend.as_deref(), None, r);
        let root = r.root_mission_id.as_deref().or(r.mission_id.as_deref());
        add_group(
            &mut root_missions,
            root,
            root.and_then(|id| titles.get(id).copied()),
            r,
        );
        add_group(
            &mut missions,
            r.mission_id.as_deref(),
            r.mission_title.as_deref(),
            r,
        );
        if r.source == UsageSource::Router {
            add_group(
                &mut keys,
                r.api_key_id.as_deref(),
                r.api_key_name.as_deref(),
                r,
            );
            add_group(&mut selected_accounts, r.account_id.as_deref(), None, r);
            add_group(
                &mut accounts,
                r.account_id.as_deref().filter(|_| r.account_bound),
                None,
                r,
            );
        }
        if let Some(day) = r.timestamp.get(..10) {
            days.entry(day.to_string()).or_default().add(r);
        }
        if hourly {
            if let Some(hour) = r.timestamp.get(..13) {
                hours.entry(hour.to_string()).or_default().add(r);
            }
        }
    }

    let mut by_model: Vec<ModelUsageResponse> = models
        .into_iter()
        .map(|((model, source), (provider, totals))| ModelUsageResponse {
            provider: if model.is_empty() { None } else { provider },
            model,
            source,
            cost_status: cost_status(&totals),
            totals,
        })
        .collect();
    by_model.sort_by(|a, b| by_cost(&a.totals, &b.totals).then_with(|| a.model.cmp(&b.model)));

    UsageSummaryResponse {
        window: window.label.clone(),
        since,
        cost_status: cost_status(&totals),
        totals,
        by_model,
        by_provider: groups(providers),
        by_source: groups(sources),
        by_route: groups(routes),
        by_caller_kind: groups(caller_kinds),
        by_purpose: groups(purposes),
        by_backend: groups(backends),
        by_mission: groups(missions),
        by_root_mission: groups(root_missions),
        by_api_key: groups(keys),
        by_account: groups(accounts),
        by_selected_account: groups(selected_accounts),
        by_day: days
            .into_iter()
            .map(|(day, b)| DailyUsageResponse {
                day,
                totals: b.totals,
                router_requests: b.router_requests,
                by_caller_kind: b.by_caller_kind,
            })
            .collect(),
        by_hour: hours
            .into_iter()
            .map(|(hour, b)| HourlyUsageResponse {
                hour,
                totals: b.totals,
                router_requests: b.router_requests,
                by_caller_kind: b.by_caller_kind,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn historical_selection_is_not_promoted_to_bound_account() {
        let mut old = record(UsageSource::Router, "gpt-6-astra", "2026-10-28T12");
        old.account_id = Some("selected".into());
        old.input_tokens = 100;
        let mut bound = old.clone();
        bound.account_bound = true;
        bound.input_tokens = 200;
        let summary = summarize(
            &[old, bound],
            &parse_window(Some("all")).unwrap(),
            None,
            &UsageFilter::default(),
        );
        assert_eq!(summary.totals.input_tokens, 300);
        assert_eq!(
            summary
                .by_selected_account
                .iter()
                .find(|g| g.key.as_deref() == Some("selected"))
                .unwrap()
                .totals
                .input_tokens,
            300
        );
        assert_eq!(
            summary
                .by_account
                .iter()
                .find(|g| g.key.as_deref() == Some("selected"))
                .unwrap()
                .totals
                .input_tokens,
            200
        );
        assert_eq!(
            summary
                .by_account
                .iter()
                .find(|g| g.key.is_none())
                .unwrap()
                .totals
                .input_tokens,
            100
        );
    }

    fn record(source: UsageSource, model: &str, hour: &str) -> UsageRecord {
        UsageRecord {
            request_id: None,
            timestamp: format!("2026-10-19T{hour}:15:00+00:00"),
            source,
            model: model.into(),
            provider: None,
            backend: None,
            mission_id: None,
            mission_title: None,
            root_mission_id: None,
            caller_kind: match source {
                UsageSource::Harness => "mission".into(),
                UsageSource::Router => "script".into(),
            },
            purpose: None,
            api_key_id: None,
            api_key_name: None,
            account_id: None,
            account_bound: false,
            input_tokens: 100,
            output_tokens: 10,
            cache_creation_tokens: 0,
            cache_read_tokens: 50,
            reasoning_tokens: 0,
            cost_cents: 3,
            cost_known: true,
        }
    }

    #[test]
    fn windows_accept_any_hour_day_or_week_count() {
        for (raw, label, hours) in [
            ("1h", "1h", 1),
            ("5h", "5h", 5),
            ("24h", "24h", 24),
            ("36H", "36h", 36),
            ("7d", "7d", 168),
            ("90d", "90d", 2160),
            ("2w", "2w", 336),
        ] {
            let w = parse_window(Some(raw)).unwrap();
            assert_eq!((w.label.as_str(), w.hours), (label, Some(hours)), "{raw}");
        }
        assert_eq!(parse_window(None).unwrap().hours, None);
        assert_eq!(parse_window(Some("all")).unwrap().hours, None);
        for bad in [
            "0h",
            "h",
            "5",
            "5m",
            "-1d",
            "1.5h",
            "abc",
            "99999999999999999999d",
        ] {
            assert!(parse_window(Some(bad)).is_err(), "{bad} must be rejected");
        }
        assert!(parse_window(Some("5h")).unwrap().hourly());
        assert!(parse_window(Some("7d")).unwrap().hourly());
        assert!(!parse_window(Some("8d")).unwrap().hourly());
        assert!(!parse_window(Some("all")).unwrap().hourly());
        let now = chrono::Utc::now();
        let since = parse_window(Some("5h")).unwrap().since(now).unwrap();
        assert_eq!(since, (now - chrono::Duration::hours(5)).to_rfc3339());
    }

    #[test]
    fn router_and_harness_rows_stay_separate_per_model() {
        let records = vec![
            record(UsageSource::Harness, "gemini-4-argon", "08"),
            record(UsageSource::Router, "gemini-4-argon", "08"),
            record(UsageSource::Router, "gemini-4-argon", "09"),
        ];
        let w = parse_window(Some("24h")).unwrap();
        let s = summarize(&records, &w, None, &UsageFilter::default());
        assert_eq!(s.by_model.len(), 2);
        let router = s
            .by_model
            .iter()
            .find(|m| m.source == UsageSource::Router)
            .unwrap();
        assert_eq!(router.totals.requests, 2);
        assert_eq!(router.provider.as_deref(), Some("google"));
        assert_eq!(s.totals.requests, 3);
        assert_eq!(s.totals.cost_cents, 9);
        assert_eq!(s.by_source.len(), 2);
        assert_eq!(s.by_hour.len(), 2);
        assert_eq!(s.by_hour[0].router_requests, 1);
        assert_eq!(s.by_day.len(), 1);
        assert_eq!(s.by_day[0].router_requests, 2);
    }

    #[test]
    fn filters_narrow_by_backend_provider_mission_source_and_key() {
        let mut harness = record(UsageSource::Harness, "claude-opus-5-5", "08");
        harness.backend = Some("claudecode".into());
        harness.mission_id = Some("m-1".into());
        harness.mission_title = Some("Fix login".into());
        let mut keyed = record(UsageSource::Router, "gemini-4-argon", "09");
        keyed.provider = Some("google".into());
        keyed.api_key_id = Some("key-1".into());
        keyed.api_key_name = Some("Cursor".into());
        let mut mission_router = record(UsageSource::Router, "gpt-5.4", "10");
        mission_router.mission_id = Some("m-1".into());
        mission_router.backend = Some("opencode".into());
        let records = vec![harness, keyed, mission_router];
        let w = parse_window(Some("all")).unwrap();
        let run = |f: UsageFilter| summarize(&records, &w, None, &f).totals.requests;

        assert_eq!(
            run(UsageFilter {
                backend: Some("claudecode".into()),
                ..Default::default()
            }),
            1
        );
        assert_eq!(
            run(UsageFilter {
                backend: Some("claudecode, opencode".into()),
                ..Default::default()
            }),
            2
        );
        assert_eq!(
            run(UsageFilter {
                provider: Some("Google".into()),
                ..Default::default()
            }),
            1
        );
        assert_eq!(
            run(UsageFilter {
                provider: Some("anthropic".into()),
                ..Default::default()
            }),
            1
        );
        assert_eq!(
            run(UsageFilter {
                mission: Some("m-1".into()),
                ..Default::default()
            }),
            2
        );
        assert_eq!(
            run(UsageFilter {
                source: Some("router".into()),
                ..Default::default()
            }),
            2
        );
        assert_eq!(
            run(UsageFilter {
                api_key: Some("key-1".into()),
                ..Default::default()
            }),
            1
        );
        assert_eq!(
            run(UsageFilter {
                model: Some("gpt-5.4".into()),
                ..Default::default()
            }),
            1
        );
        assert_eq!(
            run(UsageFilter {
                mission: Some("nope".into()),
                ..Default::default()
            }),
            0
        );

        let s = summarize(&records, &w, None, &UsageFilter::default());
        let key = s
            .by_api_key
            .iter()
            .find(|k| k.key.as_deref() == Some("key-1"))
            .unwrap();
        assert_eq!(key.label.as_deref(), Some("Cursor"));
        let mission = s
            .by_mission
            .iter()
            .find(|m| m.key.as_deref() == Some("m-1"))
            .unwrap();
        assert_eq!(mission.totals.requests, 2);
        assert_eq!(mission.label.as_deref(), Some("Fix login"));
        // Hourly buckets are not built for all-time windows.
        assert!(s.by_hour.is_empty());
    }

    #[test]
    fn unpriced_usage_is_flagged_unknown_and_excluded_from_cost() {
        let mut unknown = record(UsageSource::Router, "mystery", "08");
        unknown.cost_known = false;
        unknown.cost_cents = 0;
        let records = vec![record(UsageSource::Router, "gpt-5.4", "08"), unknown];
        let w = parse_window(Some("5h")).unwrap();
        let s = summarize(&records, &w, None, &UsageFilter::default());
        assert_eq!(s.cost_status, "partial");
        assert_eq!(s.totals.unknown_cost_requests, 1);
        assert_eq!(s.totals.cost_cents, 3);
        let mystery = s.by_model.iter().find(|m| m.model == "mystery").unwrap();
        assert_eq!(mystery.cost_status, "unknown");
        let json = serde_json::to_value(mystery).unwrap();
        assert_eq!(json["source"], "router");
        assert_eq!(json["unknown_cost_requests"], 1);
    }

    #[test]
    fn provider_inference_covers_routed_families() {
        assert_eq!(
            infer_provider_for_model("gemini-4-argon").as_deref(),
            Some("google")
        );
        assert_eq!(
            infer_provider_for_model("agy-demo").as_deref(),
            Some("google")
        );
        assert_eq!(
            infer_provider_for_model("kimi-for-coding").as_deref(),
            Some("kimi")
        );
        assert_eq!(
            infer_provider_for_model("muse-code/muse-spark-1.3").as_deref(),
            Some("muse-code")
        );
        assert_eq!(infer_provider_for_model("unknown"), None);
    }

    #[test]
    fn caller_kind_purpose_and_root_mission_breakdowns() {
        let mut sub = record(UsageSource::Harness, "m", "10");
        sub.caller_kind = "subagent".into();
        sub.mission_id = Some("child".into());
        sub.root_mission_id = Some("root".into());
        let mut root = record(UsageSource::Harness, "m", "10");
        root.mission_id = Some("root".into());
        root.root_mission_id = Some("root".into());
        root.mission_title = Some("Root mission".into());
        let mut core = record(UsageSource::Router, "m", "11");
        core.caller_kind = "core".into();
        core.purpose = Some("mission_title".into());
        let s = summarize(
            &[sub, root, core],
            &parse_window(Some("24h")).unwrap(),
            None,
            &UsageFilter::default(),
        );
        let kinds: Vec<_> = s
            .by_caller_kind
            .iter()
            .map(|g| g.key.clone().unwrap())
            .collect();
        assert_eq!(kinds.len(), 3);
        assert!(kinds.contains(&"subagent".to_string()));
        assert_eq!(s.by_purpose.len(), 1);
        assert_eq!(s.by_purpose[0].key.as_deref(), Some("mission_title"));
        let root_group = s
            .by_root_mission
            .iter()
            .find(|g| g.key.as_deref() == Some("root"))
            .unwrap();
        assert_eq!(root_group.totals.requests, 2);
        assert_eq!(root_group.label.as_deref(), Some("Root mission"));
        assert_eq!(s.by_hour[0].by_caller_kind.get("subagent"), Some(&160));
        let routes: Vec<_> = s.by_route.iter().map(|g| g.key.clone().unwrap()).collect();
        assert!(
            routes.contains(&"proxy".to_string()) && routes.contains(&"harness_direct".to_string())
        );
        let core_only = summarize(
            &s_records(),
            &parse_window(Some("24h")).unwrap(),
            None,
            &UsageFilter {
                caller_kind: Some("core".into()),
                ..Default::default()
            },
        );
        assert_eq!(core_only.totals.requests, 0);
    }

    fn s_records() -> Vec<UsageRecord> {
        vec![record(UsageSource::Harness, "m", "10")]
    }
}
