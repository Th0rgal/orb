//! Live subscription quotas and banked usage-limit resets.
//!
//! - Muse Code: `POST https://api.meta.ai/muse-code/key` with the CLI device
//!   credential (the same call CLIProxyAPI makes at login) returns the plan and
//!   the 5-hour / weekly windows. It is idempotent: it returns the existing
//!   inference key, which is discarded here.
//! - Mistral Vibe: the console's own `billing.vibeUsage` tRPC call returns the
//!   monthly plan percentage and reset. It needs a signed-in console session
//!   (`ory_session_*` + `csrftoken` cookies); an API key cannot read it.
//! - Anthropic Claude Pro/Max/Team (`cedar_ember` / `juniper_tide`): reads
//!   banked resets from `GET /api/oauth/usage?cedar_ember=1&skip_spend=1` and
//!   redeems via `POST /api/organizations/{org_uuid}/reset_rate_limits`.
//! - OpenAI Codex / ChatGPT (`wham`): reads `rate_limit_reset_credits` from
//!   `GET /backend-api/wham/usage` + `/rate-limit-reset-credits` and redeems
//!   via `POST /backend-api/wham/rate-limit-reset-credits/consume`.
//!
//! All are undocumented or semi-private CLI endpoints and may evolve; read
//! failures degrade quietly without failing the provider usage card.
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tokio::sync::RwLock;

pub const MUSE_KEY_URL: &str = "https://api.meta.ai/muse-code/key";
pub const MISTRAL_VIBE_USAGE_URL: &str = "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D";
pub const MISTRAL_WHOAMI_URL: &str = "https://console.mistral.ai/api/vibe/whoami";

pub const ANTHROPIC_API_BASE: &str = "https://api.anthropic.com";
pub const CODEX_WHAM_BASE: &str = "https://chatgpt.com/backend-api";

/// Anthropic aggressively rate-limits `/api/oauth/usage` when polled tightly.
/// Keep normal reads cached for 15 minutes and back off 30 minutes on HTTP 429;
/// invalidate immediately when `unified_status` flips to `"rejected"` or after
/// redeeming a reset.
pub const ANTHROPIC_RESET_TTL: Duration = Duration::from_secs(15 * 60);
pub const ANTHROPIC_RESET_429_BACKOFF: Duration = Duration::from_secs(30 * 60);

/// One banked or promotional subscription usage-limit reset grant.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubscriptionResetGrant {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub clears: Vec<String>,
    pub resets_left: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    pub usable_now: bool,
    pub requires_limit: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
}

/// Normalized subscription reset inventory attached to `ProviderUsage` under
/// `subscription_resets` across Desktop, Web, iOS, and Android.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SubscriptionResets {
    pub available_count: u32,
    pub usable_now: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub grants: Vec<SubscriptionResetGrant>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
}

/// Outcome of redeeming a subscription usage-limit reset upstream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResetRedeemOutcome {
    Reset {
        resets_left: Option<u32>,
        cleared: Vec<String>,
    },
    AlreadyRedeemed,
    NothingToReset(String),
    Unauthorized,
    Unavailable(String),
}

/// Outcome of a quota read, mapped onto the provider usage card.
#[derive(Debug, PartialEq)]
pub enum Quota {
    /// Card fields to merge.
    Fields(Map<String, Value>),
    /// The credential/session was rejected; the user must reconnect it.
    Unauthorized,
    /// Transient or unexpected; keep the card without numbers.
    Unavailable(String),
}

/// Parse the Muse Code mint response. Meta omits `subs_usage` while the 5-hour
/// window is idle, so absence is not an error and never becomes a fake 0%.
pub fn parse_muse(payload: &Value) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(tier) = payload["subs_tier_name"].as_str().filter(|s| !s.is_empty()) {
        out.insert("muse_plan".into(), json!(tier));
    }
    if let Some(active) = payload["is_subs_active"].as_bool() {
        out.insert("muse_subscription_active".into(), json!(active));
    }
    let usage = &payload["subs_usage"];
    let mut window = |key: &str, pct: &str, reset: &str| {
        let w = &usage[key];
        if let Some(p) = w["used_percent"].as_f64().filter(|p| p.is_finite()) {
            out.insert(pct.into(), json!(p.clamp(0.0, 100.0)));
            if let Some(r) = w["resets_at"].as_i64().filter(|r| *r > 0) {
                out.insert(reset.into(), json!(r));
            }
        }
    };
    window("window", "muse_5h_used_percent", "muse_5h_reset");
    window("weekly", "muse_weekly_used_percent", "muse_weekly_reset");
    out
}

pub async fn muse_code(client: &reqwest::Client, device_token: &str) -> Quota {
    let response = client
        .post(MUSE_KEY_URL)
        .bearer_auth(device_token)
        .header("Content-Type", "application/json")
        .body("{}")
        .send()
        .await;
    match response {
        Ok(r) if r.status().is_success() => match r.json::<Value>().await {
            Ok(payload) => Quota::Fields(parse_muse(&payload)),
            Err(e) => Quota::Unavailable(format!("Unreadable Muse Code quota: {e}")),
        },
        Ok(r) if matches!(r.status().as_u16(), 401 | 403) => Quota::Unauthorized,
        Ok(r) => Quota::Unavailable(format!("Muse Code quota returned HTTP {}", r.status())),
        Err(e) => Quota::Unavailable(format!("Muse Code quota unreachable: {e}")),
    }
}

/// Keep only the cookies the console needs, from a raw `Cookie` header or a
/// `name=value; …` list. Returns `(cookie_header, csrf_token)`.
pub fn mistral_session(raw: &str) -> Option<(String, String)> {
    let mut kept = Vec::new();
    let mut csrf = None;
    let mut has_session = false;
    for part in raw.split(';') {
        let Some((name, value)) = part.trim().split_once('=') else {
            continue;
        };
        let (name, value) = (name.trim(), value.trim());
        if value.is_empty() || value.contains(['\r', '\n']) {
            continue;
        }
        if name == "csrftoken" {
            csrf = Some(value.to_string());
        } else if name.starts_with("ory_session_") {
            has_session = true;
        } else {
            continue;
        }
        kept.push(format!("{name}={value}"));
    }
    let csrf = csrf?;
    has_session.then(|| (kept.join("; "), csrf))
}

/// Parse the tRPC batch response `[{result:{data:{json:{usage_percentage, reset_at}}}}]`.
pub fn parse_mistral_vibe(payload: &Value) -> Option<Map<String, Value>> {
    let data = &payload[0]["result"]["data"]["json"];
    let pct = data["usage_percentage"]
        .as_f64()
        .filter(|p| p.is_finite() && (0.0..=100.0).contains(p))?;
    let mut out = Map::new();
    out.insert("mistral_monthly_used_percent".into(), json!(pct));
    if let Some(reset) = data["reset_at"]
        .as_str()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
    {
        out.insert("mistral_monthly_reset".into(), json!(reset.timestamp()));
    }
    Some(out)
}

pub async fn mistral_vibe(client: &reqwest::Client, stored_session: &str) -> Quota {
    let Some((cookie, csrf)) = mistral_session(stored_session) else {
        return Quota::Unauthorized;
    };
    let response = client
        .get(MISTRAL_VIBE_USAGE_URL)
        .header("Cookie", cookie)
        .header("X-CSRFToken", csrf)
        .header("Accept", "*/*")
        .header("Referer", "https://console.mistral.ai/")
        .send()
        .await;
    match response {
        // An expired session is redirected to the sign-in page.
        Ok(r) if r.status().is_redirection() || matches!(r.status().as_u16(), 401 | 403) => {
            Quota::Unauthorized
        }
        Ok(r) if r.status().is_success() => match r.json::<Value>().await {
            Ok(payload) => parse_mistral_vibe(&payload)
                .map(Quota::Fields)
                .unwrap_or_else(|| Quota::Unavailable("Unexpected Mistral usage response".into())),
            Err(_) => Quota::Unauthorized, // HTML sign-in page instead of JSON
        },
        Ok(r) => Quota::Unavailable(format!("Mistral usage returned HTTP {}", r.status())),
        Err(e) => Quota::Unavailable(format!("Mistral usage unreachable: {e}")),
    }
}

/// Plan name for a Mistral API key (`CHAT` / `INDIVIDUAL` …). Best effort.
pub async fn mistral_plan(client: &reqwest::Client, api_key: &str) -> Option<String> {
    let payload: Value = client
        .get(MISTRAL_WHOAMI_URL)
        .bearer_auth(api_key)
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()?;
    let name = payload["plan_name"].as_str()?.trim();
    let kind = payload["plan_type"].as_str().unwrap_or("").trim();
    let pretty = |s: &str| {
        let lower = s.to_lowercase().replace('_', " ");
        let mut c = lower.chars();
        c.next()
            .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
            .unwrap_or_default()
    };
    Some(match kind {
        "" => pretty(name),
        _ => format!("{} · {}", pretty(kind), pretty(name)),
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic Claude (`cedar_ember` / `juniper_tide`) subscription resets
// ─────────────────────────────────────────────────────────────────────────────

pub fn anthropic_window_label(window: &str) -> String {
    match window.trim() {
        "five_hour" => "5h".to_string(),
        "seven_day" | "seven_day_overage_included" => "Weekly".to_string(),
        "seven_day_opus" => "Weekly Opus".to_string(),
        "seven_day_sonnet" => "Weekly Sonnet".to_string(),
        "seven_day_cowork" => "Weekly Cowork".to_string(),
        "seven_day_oauth_apps" => "Weekly Apps".to_string(),
        other => {
            let clean = other.replace('_', " ");
            let mut chars = clean.chars();
            chars
                .next()
                .map(|c| c.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        }
    }
}

fn parse_epoch_or_rfc3339(value: &Value) -> Option<i64> {
    value.as_i64().filter(|ts| *ts > 0).or_else(|| {
        chrono::DateTime::parse_from_rfc3339(value.as_str()?)
            .ok()
            .map(|dt| dt.timestamp())
    })
}

fn humanize_anthropic_unavailable_reason(
    raw: Option<&str>,
    requires_limit: bool,
    at_limit: bool,
    paused: bool,
    cooldown_until: Option<i64>,
    now_unix: i64,
) -> Option<String> {
    if paused || raw == Some("paused") {
        return Some("Temporarily paused".to_string());
    }
    if raw == Some("cooldown") || cooldown_until.is_some_and(|until| until > now_unix) {
        return Some("Reset cooldown active".to_string());
    }
    if raw == Some("not_limited") || (requires_limit && !at_limit) {
        return Some("Available when a usage limit is reached".to_string());
    }
    if raw == Some("not_started") {
        return Some("Grant has not started yet".to_string());
    }
    raw.map(str::trim).filter(|s| !s.is_empty()).map(|s| {
        let text = s.replace('_', " ");
        let mut chars = text.chars();
        chars
            .next()
            .map(|c| c.to_uppercase().collect::<String>() + chars.as_str())
            .unwrap_or_default()
    })
}

/// Parse Anthropic `/api/oauth/usage` `cedar_ember` + `juniper_tide` fields into
/// a normalized [`SubscriptionResets`]. Returns `None` when the account has no
/// active reset grants.
pub fn parse_anthropic_resets(payload: &Value, now_unix: i64) -> Option<SubscriptionResets> {
    if let Some(ce) = payload.get("cedar_ember").filter(|v| v.is_object()) {
        let eligible = ce.get("eligible").and_then(Value::as_bool).unwrap_or(true);
        if eligible {
            let at_limit = ce.get("at_limit").and_then(Value::as_bool).unwrap_or(false);
            let cooldown_until = ce.get("cooldown_until").and_then(parse_epoch_or_rfc3339);
            let in_cooldown = cooldown_until.is_some_and(|until| until > now_unix);
            let next_grant_id = ce.get("next_grant_id").and_then(Value::as_str);

            let mut grants = Vec::new();
            if let Some(items) = ce.get("grants").and_then(Value::as_array) {
                for item in items {
                    let Some(id) = item
                        .get("id")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                    else {
                        continue;
                    };
                    let resets_left =
                        item.get("resets_left").and_then(Value::as_u64).unwrap_or(0) as u32;
                    if resets_left == 0 {
                        continue;
                    }
                    let raw_reason = item.get("unavailable_reason").and_then(Value::as_str);
                    if raw_reason == Some("expired") {
                        continue;
                    }
                    let expires_at = item.get("ends_at").and_then(parse_epoch_or_rfc3339);
                    if expires_at.is_some_and(|end| end <= now_unix) {
                        continue;
                    }
                    let starts_at = item.get("starts_at").and_then(parse_epoch_or_rfc3339);
                    let not_started = starts_at.is_some_and(|start| start > now_unix);
                    let paused = item.get("paused").and_then(Value::as_bool).unwrap_or(false);
                    let requires_limit = item
                        .get("use_requires_limit")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let gives_back_weekly = item
                        .get("gives_back_weekly")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);

                    let mut clears = Vec::new();
                    if let Some(arr) = item.get("clears").and_then(Value::as_array) {
                        for w in arr.iter().filter_map(Value::as_str) {
                            let label = anthropic_window_label(w);
                            if !label.is_empty() && !clears.contains(&label) {
                                clears.push(label);
                            }
                        }
                    }
                    if gives_back_weekly && !clears.iter().any(|c| c.starts_with("Weekly")) {
                        clears.push("Weekly (model share)".to_string());
                    }

                    let usable_now = item
                        .get("usable_now")
                        .and_then(Value::as_bool)
                        .unwrap_or_else(|| {
                            !paused
                                && !in_cooldown
                                && !not_started
                                && (!requires_limit || at_limit)
                                && raw_reason.is_none()
                        })
                        && !paused
                        && !in_cooldown
                        && !not_started;

                    let unavailable_reason = if usable_now {
                        None
                    } else {
                        let effective_raw = if not_started && raw_reason.is_none() {
                            Some("not_started")
                        } else {
                            raw_reason
                        };
                        humanize_anthropic_unavailable_reason(
                            effective_raw,
                            requires_limit,
                            at_limit,
                            paused,
                            cooldown_until,
                            now_unix,
                        )
                    };

                    let label = item
                        .get("label")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .unwrap_or("Usage limit reset")
                        .to_string();

                    grants.push(SubscriptionResetGrant {
                        id: id.to_string(),
                        label,
                        clears,
                        resets_left,
                        expires_at,
                        usable_now,
                        requires_limit,
                        unavailable_reason,
                    });
                }
            }

            if let Some(next_id) = next_grant_id {
                if let Some(pos) = grants.iter().position(|g| g.id == next_id) {
                    if pos > 0 {
                        let preferred = grants.remove(pos);
                        grants.insert(0, preferred);
                    }
                }
            }

            if !grants.is_empty() {
                let available_count: u32 = grants
                    .iter()
                    .filter(|g| g.unavailable_reason.as_deref() != Some("Temporarily paused"))
                    .map(|g| g.resets_left)
                    .sum();
                if available_count > 0 {
                    let usable_now = grants.iter().any(|g| g.usable_now);
                    let unavailable_reason = if usable_now {
                        None
                    } else {
                        grants.iter().find_map(|g| g.unavailable_reason.clone())
                    };
                    return Some(SubscriptionResets {
                        available_count,
                        usable_now,
                        grants,
                        unavailable_reason,
                    });
                }
            }
        }
    }

    // Legacy / promotional single-shot `juniper_tide` reset fallback.
    if payload
        .get("juniper_tide")
        .and_then(|jt| jt.get("available"))
        .and_then(Value::as_bool)
        == Some(true)
    {
        return Some(SubscriptionResets {
            available_count: 1,
            usable_now: true,
            grants: vec![SubscriptionResetGrant {
                id: "juniper_tide".to_string(),
                label: "Usage limit reset".to_string(),
                clears: vec!["5h".to_string(), "Weekly".to_string()],
                resets_left: 1,
                expires_at: None,
                usable_now: true,
                requires_limit: false,
                unavailable_reason: None,
            }],
            unavailable_reason: None,
        });
    }

    None
}

/// True when an Anthropic `/api/oauth/usage` payload shows the subscription is
/// currently exhausted (either `cedar_ember.at_limit` / `juniper_tide.at_limit`
/// is true or one of the rate-limit windows is at 100% / exceeded / rejected).
pub fn parse_anthropic_exhausted(payload: &Value) -> bool {
    if payload
        .get("cedar_ember")
        .and_then(|ce| ce.get("at_limit"))
        .and_then(Value::as_bool)
        == Some(true)
    {
        return true;
    }
    if payload
        .get("juniper_tide")
        .and_then(|jt| jt.get("at_limit"))
        .and_then(Value::as_bool)
        == Some(true)
    {
        return true;
    }
    [
        "five_hour",
        "seven_day",
        "seven_day_sonnet",
        "seven_day_opus",
        "seven_day_oauth_apps",
    ]
    .iter()
    .any(|key| {
        let Some(w) = payload.get(*key) else {
            return false;
        };
        w.get("is_exceeded").and_then(Value::as_bool) == Some(true)
            || w.get("status").and_then(Value::as_str) == Some("rejected")
            || w.get("utilization")
                .and_then(Value::as_f64)
                .is_some_and(|u| u >= 100.0)
    })
}

#[derive(Debug, Clone)]
pub struct AnthropicResetSnapshot {
    pub resets: Option<SubscriptionResets>,
    pub exhausted: bool,
}

#[derive(Debug)]
pub enum AnthropicResetReadError {
    RateLimited,
    Unauthorized,
    Other(String),
}

pub async fn fetch_anthropic_reset_snapshot_uncached(
    client: &reqwest::Client,
    api_base: &str,
    access_token: &str,
    at_wall: bool,
) -> Result<AnthropicResetSnapshot, AnthropicResetReadError> {
    let base = api_base.trim_end_matches('/');
    let url = if at_wall {
        format!("{base}/api/oauth/usage?at_wall=1&cedar_ember=1&skip_spend=1")
    } else {
        format!("{base}/api/oauth/usage?cedar_ember=1&skip_spend=1")
    };
    let resp = client
        .get(&url)
        .bearer_auth(access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("anthropic-version", "2023-06-01")
        .timeout(Duration::from_secs(12))
        .send()
        .await
        .map_err(|e| {
            AnthropicResetReadError::Other(format!("Anthropic reset check failed: {e}"))
        })?;

    let status = resp.status();
    if status.as_u16() == 429 {
        return Err(AnthropicResetReadError::RateLimited);
    }
    if matches!(status.as_u16(), 401 | 403) {
        return Err(AnthropicResetReadError::Unauthorized);
    }
    if !status.is_success() {
        return Err(AnthropicResetReadError::Other(format!(
            "Anthropic reset check returned HTTP {}",
            status.as_u16()
        )));
    }
    let payload: Value = resp.json().await.map_err(|e| {
        AnthropicResetReadError::Other(format!("Unreadable Anthropic reset response: {e}"))
    })?;
    Ok(AnthropicResetSnapshot {
        resets: parse_anthropic_resets(&payload, chrono::Utc::now().timestamp()),
        exhausted: parse_anthropic_exhausted(&payload),
    })
}

pub async fn fetch_anthropic_resets_uncached(
    client: &reqwest::Client,
    api_base: &str,
    access_token: &str,
    at_wall: bool,
) -> Result<Option<SubscriptionResets>, AnthropicResetReadError> {
    fetch_anthropic_reset_snapshot_uncached(client, api_base, access_token, at_wall)
        .await
        .map(|snap| snap.resets)
}

struct StoredAnthropicResets {
    resets: Option<SubscriptionResets>,
    fetched_at: Instant,
    fetched_at_wall: bool,
    ttl: Duration,
    backoff_until: Option<Instant>,
}

/// Throttled per-account cache for Anthropic `/api/oauth/usage?cedar_ember=1`.
#[derive(Default)]
pub struct AnthropicResetStore {
    entries: RwLock<HashMap<String, StoredAnthropicResets>>,
}

impl AnthropicResetStore {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn shared() -> &'static Arc<Self> {
        static SHARED: std::sync::LazyLock<Arc<AnthropicResetStore>> =
            std::sync::LazyLock::new(AnthropicResetStore::new);
        &SHARED
    }

    pub async fn invalidate(&self, key: &str) {
        self.entries.write().await.remove(key);
    }

    pub async fn get_or_fetch(
        &self,
        client: &reqwest::Client,
        api_base: &str,
        key: &str,
        access_token: &str,
        at_wall: bool,
    ) -> Option<SubscriptionResets> {
        let prev = {
            let entries = self.entries.read().await;
            if let Some(entry) = entries.get(key) {
                if entry
                    .backoff_until
                    .is_some_and(|until| Instant::now() < until)
                {
                    return entry.resets.clone();
                }
                if entry.fetched_at.elapsed() < entry.ttl && entry.fetched_at_wall == at_wall {
                    return entry.resets.clone();
                }
                entry.resets.clone()
            } else {
                None
            }
        };

        match fetch_anthropic_resets_uncached(client, api_base, access_token, at_wall).await {
            Ok(resets) => {
                self.entries.write().await.insert(
                    key.to_string(),
                    StoredAnthropicResets {
                        resets: resets.clone(),
                        fetched_at: Instant::now(),
                        fetched_at_wall: at_wall,
                        ttl: ANTHROPIC_RESET_TTL,
                        backoff_until: None,
                    },
                );
                resets
            }
            Err(AnthropicResetReadError::RateLimited) => {
                tracing::debug!(
                    provider = %key,
                    "Anthropic /api/oauth/usage returned 429; backing off 30m"
                );
                self.entries.write().await.insert(
                    key.to_string(),
                    StoredAnthropicResets {
                        resets: prev.clone(),
                        fetched_at: Instant::now(),
                        fetched_at_wall: at_wall,
                        ttl: ANTHROPIC_RESET_TTL,
                        backoff_until: Some(Instant::now() + ANTHROPIC_RESET_429_BACKOFF),
                    },
                );
                prev
            }
            Err(AnthropicResetReadError::Unauthorized) => {
                // Tokens minted without `user:profile` cannot read `/api/oauth/usage`;
                // cache the absence quietly so the 2-minute usage loop doesn't retry every tick.
                self.entries.write().await.insert(
                    key.to_string(),
                    StoredAnthropicResets {
                        resets: None,
                        fetched_at: Instant::now(),
                        fetched_at_wall: at_wall,
                        ttl: ANTHROPIC_RESET_TTL,
                        backoff_until: None,
                    },
                );
                None
            }
            Err(AnthropicResetReadError::Other(err)) => {
                tracing::debug!(provider = %key, %err, "Anthropic reset inventory check failed");
                self.entries.write().await.insert(
                    key.to_string(),
                    StoredAnthropicResets {
                        resets: prev.clone(),
                        fetched_at: Instant::now(),
                        fetched_at_wall: at_wall,
                        ttl: Duration::from_secs(120),
                        backoff_until: None,
                    },
                );
                prev
            }
        }
    }
}

/// Resolve an Anthropic organization UUID when `AIProvider.organization_id` has
/// not yet been populated by a `/v1/messages` response header.
pub async fn resolve_anthropic_org_id(
    client: &reqwest::Client,
    api_base: &str,
    access_token: &str,
    cached_org_id: Option<&str>,
) -> Option<String> {
    if let Some(org) = cached_org_id.map(str::trim).filter(|s| !s.is_empty()) {
        return Some(org.to_string());
    }
    let url = format!("{}/api/oauth/profile", api_base.trim_end_matches('/'));
    let resp = client
        .get(&url)
        .bearer_auth(access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("anthropic-version", "2023-06-01")
        .timeout(Duration::from_secs(12))
        .send()
        .await
        .ok()?;
    if let Some(hdr) = resp
        .headers()
        .get("anthropic-organization-id")
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return Some(hdr.to_string());
    }
    if !resp.status().is_success() {
        return None;
    }
    let body: Value = resp.json().await.ok()?;
    body.get("organization")
        .and_then(|o| o.get("uuid").or_else(|| o.get("id")))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub fn sanitize_reset_request_id(raw: Option<&str>) -> String {
    let cleaned: String = raw
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(64)
        .collect();
    if cleaned.is_empty() {
        uuid::Uuid::new_v4().to_string()
    } else {
        cleaned
    }
}

pub fn valid_anthropic_grant_id(grant_id: &str) -> bool {
    !grant_id.is_empty()
        && grant_id.len() <= 40
        && grant_id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// Redeem one Anthropic subscription usage-limit reset (`cedar_ember` or `juniper_tide`).
pub async fn redeem_anthropic_reset(
    client: &reqwest::Client,
    api_base: &str,
    access_token: &str,
    org_uuid: &str,
    grant_id: &str,
    request_id: &str,
) -> ResetRedeemOutcome {
    let org_uuid = org_uuid.trim();
    if org_uuid.is_empty() || org_uuid.contains('/') {
        return ResetRedeemOutcome::Unavailable(
            "Anthropic organization ID is missing; refresh usage first".to_string(),
        );
    }
    let body = if grant_id == "juniper_tide" {
        json!({ "program": "juniper_tide" })
    } else {
        if !valid_anthropic_grant_id(grant_id) {
            return ResetRedeemOutcome::Unavailable(format!("Invalid grant id: {grant_id}"));
        }
        json!({
            "program": "cedar_ember",
            "grant_id": grant_id,
            "request_id": sanitize_reset_request_id(Some(request_id)),
        })
    };

    let url = format!(
        "{}/api/organizations/{org_uuid}/reset_rate_limits",
        api_base.trim_end_matches('/')
    );
    let resp = match client
        .post(&url)
        .bearer_auth(access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("anthropic-version", "2023-06-01")
        .header("Content-Type", "application/json")
        .timeout(Duration::from_secs(20))
        .json(&body)
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            return ResetRedeemOutcome::Unavailable(format!(
                "Failed to reach Anthropic reset endpoint: {e}"
            ))
        }
    };

    let status = resp.status();
    if matches!(status.as_u16(), 401 | 403) {
        return ResetRedeemOutcome::Unauthorized;
    }
    let payload: Value = match resp.json().await {
        Ok(v) => v,
        Err(e) if !status.is_success() => {
            return ResetRedeemOutcome::Unavailable(format!(
                "Anthropic reset returned HTTP {} ({e})",
                status.as_u16()
            ));
        }
        Err(e) => {
            return ResetRedeemOutcome::Unavailable(format!(
                "Unreadable Anthropic reset response: {e}"
            ));
        }
    };

    if !status.is_success() && payload.get("result").is_none() {
        let msg = payload
            .get("error")
            .and_then(|err| err.get("message").or(Some(err)))
            .and_then(Value::as_str)
            .unwrap_or("Anthropic refused the reset request");
        return ResetRedeemOutcome::Unavailable(format!("{msg} (HTTP {})", status.as_u16()));
    }

    let result = payload
        .get("result")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let reason = payload
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());

    match result {
        "reset" => {
            let resets_left = payload
                .get("resets_left")
                .and_then(Value::as_u64)
                .map(|n| n as u32);
            let cleared = payload
                .get("cleared")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .map(anthropic_window_label)
                        .collect()
                })
                .unwrap_or_default();
            ResetRedeemOutcome::Reset {
                resets_left,
                cleared,
            }
        }
        "already_used" => ResetRedeemOutcome::AlreadyRedeemed,
        "not_limited" => ResetRedeemOutcome::NothingToReset(
            reason
                .unwrap_or("This grant can only be redeemed once a usage limit is reached")
                .to_string(),
        ),
        "cooldown" => ResetRedeemOutcome::Unavailable(
            reason
                .unwrap_or("A reset cooldown is active on this subscription; try again later")
                .to_string(),
        ),
        "ineligible" | "unavailable" => ResetRedeemOutcome::Unavailable(
            reason
                .unwrap_or("No eligible subscription reset is available right now")
                .to_string(),
        ),
        other => ResetRedeemOutcome::Unavailable(
            reason
                .map(str::to_string)
                .unwrap_or_else(|| format!("Unexpected Anthropic reset result: {other}")),
        ),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI Codex / ChatGPT (`wham`) subscription rate-limit reset credits
// ─────────────────────────────────────────────────────────────────────────────

fn codex_reset_type_clears(reset_type: Option<&str>) -> Vec<String> {
    match reset_type.unwrap_or("codex_rate_limits") {
        "codex_rate_limits" | "codexRateLimits" | "" => {
            vec!["5h".to_string(), "Weekly".to_string()]
        }
        other => {
            let clean = other.replace('_', " ");
            vec![clean]
        }
    }
}

fn synthetic_codex_resets(available_count: u32) -> SubscriptionResets {
    SubscriptionResets {
        available_count,
        usable_now: available_count > 0,
        grants: if available_count > 0 {
            vec![SubscriptionResetGrant {
                id: String::new(),
                label: "Codex usage reset credit".to_string(),
                clears: vec!["5h".to_string(), "Weekly".to_string()],
                resets_left: available_count,
                expires_at: None,
                usable_now: true,
                requires_limit: false,
                unavailable_reason: None,
            }]
        } else {
            Vec::new()
        },
        unavailable_reason: None,
    }
}

/// Parse `rate_limit_reset_credits` embedded in `/backend-api/wham/usage`.
pub fn parse_codex_reset_credits_summary(
    report: &Value,
    now_unix: i64,
) -> Option<SubscriptionResets> {
    let block = report.get("rate_limit_reset_credits")?;
    if block.is_null() {
        return None;
    }
    if let Some(detailed) = parse_codex_reset_credits_details(block, now_unix) {
        return Some(detailed);
    }
    let count = block
        .get("available_count")
        .or_else(|| block.get("availableCount"))
        .and_then(Value::as_u64)
        .unwrap_or(0) as u32;
    if count == 0 {
        return None;
    }
    Some(synthetic_codex_resets(count))
}

/// Parse `/backend-api/wham/rate-limit-reset-credits` response JSON.
pub fn parse_codex_reset_credits_details(
    payload: &Value,
    now_unix: i64,
) -> Option<SubscriptionResets> {
    let arr = payload.get("credits").and_then(Value::as_array)?;
    let mut grants = Vec::new();
    for item in arr {
        let status = item
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("available");
        if !status.eq_ignore_ascii_case("available") {
            continue;
        }
        let expires_at = item
            .get("expires_at")
            .or_else(|| item.get("expiresAt"))
            .and_then(parse_epoch_or_rfc3339);
        if expires_at.is_some_and(|exp| exp <= now_unix) {
            continue;
        }
        let id = item
            .get("id")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("")
            .to_string();
        let label = item
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("Codex usage reset credit")
            .to_string();
        let reset_type = item
            .get("reset_type")
            .or_else(|| item.get("resetType"))
            .and_then(Value::as_str);
        grants.push(SubscriptionResetGrant {
            id,
            label,
            clears: codex_reset_type_clears(reset_type),
            resets_left: 1,
            expires_at,
            usable_now: true,
            requires_limit: false,
            unavailable_reason: None,
        });
    }
    if grants.is_empty() {
        return None;
    }
    let reported_count = payload
        .get("available_count")
        .or_else(|| payload.get("availableCount"))
        .and_then(Value::as_u64)
        .map(|n| n as u32);
    let available_count = reported_count
        .unwrap_or(grants.len() as u32)
        .max(grants.len() as u32);
    Some(SubscriptionResets {
        available_count,
        usable_now: true,
        grants,
        unavailable_reason: None,
    })
}

/// Adjust `usable_now` on Codex reset credits using the account's current usage:
/// `/consume` returns `nothing_to_reset` when every rate-limit window is at 0%.
pub fn apply_codex_usage_eligibility(
    mut resets: SubscriptionResets,
    limit_reached: Option<bool>,
    primary_used_percent: Option<f64>,
    secondary_used_percent: Option<f64>,
) -> SubscriptionResets {
    let nothing_used = limit_reached == Some(false)
        && primary_used_percent.is_some_and(|p| p <= 0.0)
        && secondary_used_percent.unwrap_or(0.0) <= 0.0;
    if nothing_used {
        let reason = "Usage windows are already at 0%".to_string();
        resets.usable_now = false;
        resets.unavailable_reason = Some(reason.clone());
        for grant in &mut resets.grants {
            grant.usable_now = false;
            grant.unavailable_reason = Some(reason.clone());
        }
    }
    resets
}

/// Fetch credit details from `GET {wham_base}/wham/rate-limit-reset-credits`,
/// falling back to `fallback` (the count from `/wham/usage`) if rate-limited or
/// omitted.
pub async fn read_codex_reset_credits(
    client: &reqwest::Client,
    wham_base: &str,
    access_token: &str,
    account_id: &str,
    fallback: SubscriptionResets,
) -> SubscriptionResets {
    if fallback.available_count == 0 {
        return fallback;
    }
    let url = format!(
        "{}/wham/rate-limit-reset-credits",
        wham_base.trim_end_matches('/')
    );
    let Ok(resp) = client
        .get(&url)
        .bearer_auth(access_token)
        .header("chatgpt-account-id", account_id)
        .header("originator", "codex_cli_rs")
        .timeout(Duration::from_secs(12))
        .send()
        .await
    else {
        return fallback;
    };
    if !resp.status().is_success() {
        return fallback;
    }
    let Ok(payload) = resp.json::<Value>().await else {
        return fallback;
    };
    parse_codex_reset_credits_details(&payload, chrono::Utc::now().timestamp()).unwrap_or(fallback)
}

/// Redeem one Codex rate-limit reset credit via
/// `POST {wham_base}/wham/rate-limit-reset-credits/consume`.
pub async fn redeem_codex_reset(
    client: &reqwest::Client,
    wham_base: &str,
    access_token: &str,
    account_id: &str,
    credit_id: Option<&str>,
    request_id: &str,
) -> ResetRedeemOutcome {
    let url = format!(
        "{}/wham/rate-limit-reset-credits/consume",
        wham_base.trim_end_matches('/')
    );
    let mut body = json!({
        "redeem_request_id": sanitize_reset_request_id(Some(request_id)),
    });
    if let Some(cid) = credit_id.map(str::trim).filter(|s| !s.is_empty()) {
        body["credit_id"] = json!(cid);
    }

    let resp = match client
        .post(&url)
        .bearer_auth(access_token)
        .header("chatgpt-account-id", account_id)
        .header("originator", "codex_cli_rs")
        .header("Content-Type", "application/json")
        .timeout(Duration::from_secs(20))
        .json(&body)
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            return ResetRedeemOutcome::Unavailable(format!(
                "Failed to reach Codex reset endpoint: {e}"
            ))
        }
    };

    let status = resp.status();
    if matches!(status.as_u16(), 401 | 403) {
        return ResetRedeemOutcome::Unauthorized;
    }
    let payload: Value = match resp.json().await {
        Ok(v) => v,
        Err(e) if !status.is_success() => {
            return ResetRedeemOutcome::Unavailable(format!(
                "Codex reset returned HTTP {} ({e})",
                status.as_u16()
            ));
        }
        Err(e) => {
            return ResetRedeemOutcome::Unavailable(format!(
                "Unreadable Codex reset response: {e}"
            ));
        }
    };

    if !status.is_success() && payload.get("outcome").is_none() {
        let msg = payload
            .get("detail")
            .or_else(|| {
                payload
                    .get("error")
                    .and_then(|e| e.get("message").or(Some(e)))
            })
            .and_then(Value::as_str)
            .unwrap_or("Codex refused the reset request");
        return ResetRedeemOutcome::Unavailable(format!("{msg} (HTTP {})", status.as_u16()));
    }

    let outcome = payload
        .get("outcome")
        .or_else(|| payload.get("result"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    match outcome {
        "reset" => ResetRedeemOutcome::Reset {
            resets_left: payload
                .get("available_count")
                .or_else(|| payload.get("resets_left"))
                .and_then(Value::as_u64)
                .map(|n| n as u32),
            cleared: vec!["5h".to_string(), "Weekly".to_string()],
        },
        "already_redeemed" | "alreadyRedeemed" => ResetRedeemOutcome::AlreadyRedeemed,
        "nothing_to_reset" | "nothingToReset" => ResetRedeemOutcome::NothingToReset(
            "No Codex rate-limit usage needs resetting right now".to_string(),
        ),
        "no_credit" | "noCredit" => ResetRedeemOutcome::Unavailable(
            "No Codex usage-reset credit is available on this account".to_string(),
        ),
        other => {
            ResetRedeemOutcome::Unavailable(format!("Unexpected Codex reset outcome: {other}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn muse_windows_and_plan() {
        let payload = json!({
            "subs_tier_name": "Muse Code Power Usage", "is_subs_active": true,
            "api_key": "secret", "payment_method": "visa 4242",
            "subs_usage": {
                "window": {"used_percent": 12.5, "window_duration_mins": 300, "resets_at": 1792155529},
                "weekly": {"used_percent": 61, "resets_at": 1792368000}
            }
        });
        let out = parse_muse(&payload);
        assert_eq!(out["muse_plan"], "Muse Code Power Usage");
        assert_eq!(out["muse_5h_used_percent"], 12.5);
        assert_eq!(out["muse_5h_reset"], 1792155529);
        assert_eq!(out["muse_weekly_used_percent"], 61.0);
        assert!(!out.contains_key("api_key") && !out.values().any(|v| v == "secret"));
    }

    #[test]
    fn muse_idle_window_is_not_invented() {
        let out = parse_muse(&json!({"subs_tier_name": "Everyday", "subs_usage": null}));
        assert!(!out.contains_key("muse_5h_used_percent"));
        assert!(!out.contains_key("muse_weekly_used_percent"));
    }

    #[test]
    fn mistral_session_keeps_only_needed_cookies() {
        let (cookie, csrf) =
            mistral_session("_ga=1; ory_session_abc=SESSION; csrftoken=TOKEN; intercom=x").unwrap();
        assert_eq!(cookie, "ory_session_abc=SESSION; csrftoken=TOKEN");
        assert_eq!(csrf, "TOKEN");
        assert!(
            mistral_session("csrftoken=TOKEN").is_none(),
            "session required"
        );
        assert!(
            mistral_session("ory_session_a=S").is_none(),
            "csrf required"
        );
    }

    #[test]
    fn mistral_vibe_usage_parses_the_trpc_batch() {
        let payload = json!([{"result":{"data":{"json":{"usage_percentage": 37.2, "reset_at": "2026-11-01T00:00:00Z"}}}}]);
        let out = parse_mistral_vibe(&payload).unwrap();
        assert_eq!(out["mistral_monthly_used_percent"], 37.2);
        assert_eq!(out["mistral_monthly_reset"], 1793491200);
        assert!(parse_mistral_vibe(
            &json!([{"result":{"data":{"json":{"usage_percentage": 140}}}}])
        )
        .is_none());
    }

    #[test]
    fn parses_anthropic_cedar_ember_and_juniper_tide_grants() {
        let now = 1_790_000_000_i64;

        // Banked grant while not yet at limit (`use_requires_limit: true`).
        let idle = json!({
            "cedar_ember": {
                "eligible": true,
                "at_limit": false,
                "next_grant_id": "grant_weekly",
                "grants": [
                    {
                        "id": "grant_5h",
                        "label": "Session reset",
                        "resets_total": 2,
                        "resets_left": 1,
                        "clears": ["five_hour"],
                        "gives_back_weekly": true,
                        "usable_now": false,
                        "use_requires_limit": true,
                        "unavailable_reason": "not_limited"
                    },
                    {
                        "id": "grant_weekly",
                        "label": "Max weekly reset",
                        "resets_total": 1,
                        "resets_left": 1,
                        "ends_at": "2026-11-01T00:00:00Z",
                        "clears": ["five_hour", "seven_day"],
                        "usable_now": false,
                        "use_requires_limit": true,
                        "unavailable_reason": "not_limited"
                    }
                ]
            }
        });
        let parsed = parse_anthropic_resets(&idle, now).expect("banked resets");
        assert_eq!(parsed.available_count, 2);
        assert!(!parsed.usable_now);
        assert_eq!(
            parsed.unavailable_reason.as_deref(),
            Some("Available when a usage limit is reached")
        );
        // `next_grant_id` moves `grant_weekly` to index 0.
        assert_eq!(parsed.grants[0].id, "grant_weekly");
        assert_eq!(parsed.grants[0].clears, vec!["5h", "Weekly"]);
        assert_eq!(parsed.grants[0].expires_at, Some(1_793_491_200));
        // `gives_back_weekly` adds a weekly note when only `five_hour` is listed.
        assert_eq!(parsed.grants[1].clears, vec!["5h", "Weekly (model share)"]);

        // At limit: grant becomes usable immediately.
        let at_wall = json!({
            "cedar_ember": {
                "eligible": true,
                "at_limit": true,
                "grants": [{
                    "id": "grant_weekly",
                    "label": "Max weekly reset",
                    "resets_left": 1,
                    "clears": ["five_hour", "seven_day_opus"],
                    "usable_now": true,
                    "use_requires_limit": true
                }]
            }
        });
        let wall_resets = parse_anthropic_resets(&at_wall, now).expect("usable at wall");
        assert_eq!(wall_resets.available_count, 1);
        assert!(wall_resets.usable_now);
        assert!(wall_resets.grants[0].usable_now);
        assert_eq!(wall_resets.grants[0].clears, vec!["5h", "Weekly Opus"]);

        // Legacy `juniper_tide` fallback when `cedar_ember` has no grants.
        let jt = json!({
            "cedar_ember": { "eligible": false, "ineligible_reason": "wrong_plan" },
            "juniper_tide": { "available": true }
        });
        let jt_resets = parse_anthropic_resets(&jt, now).expect("juniper_tide");
        assert_eq!(jt_resets.available_count, 1);
        assert!(jt_resets.usable_now);
        assert_eq!(jt_resets.grants[0].id, "juniper_tide");
    }

    #[test]
    fn parses_codex_reset_credits_and_usage_gating() {
        let now = 1_790_000_000_i64;
        let summary = json!({
            "plan_type": "pro",
            "rate_limit": { "limit_reached": true },
            "rate_limit_reset_credits": { "available_count": 2 }
        });
        let base = parse_codex_reset_credits_summary(&summary, now).expect("summary credits");
        assert_eq!(base.available_count, 2);
        assert!(base.usable_now);

        let details = json!({
            "credits": [
                {
                    "id": "crd_live",
                    "reset_type": "codex_rate_limits",
                    "status": "available",
                    "granted_at": 1789000000,
                    "expires_at": 1793491200,
                    "title": "Pro promotional reset"
                },
                {
                    "id": "crd_used",
                    "reset_type": "codex_rate_limits",
                    "status": "redeemed",
                    "granted_at": 1788000000,
                    "expires_at": null
                }
            ]
        });
        let rich = parse_codex_reset_credits_details(&details, now).expect("detailed credits");
        assert_eq!(rich.available_count, 1);
        assert_eq!(rich.grants.len(), 1);
        assert_eq!(rich.grants[0].id, "crd_live");
        assert_eq!(rich.grants[0].label, "Pro promotional reset");
        assert_eq!(rich.grants[0].expires_at, Some(1_793_491_200));

        // 0% across all windows disables manual redemption until some quota is used.
        let gated = apply_codex_usage_eligibility(rich.clone(), Some(false), Some(0.0), Some(0.0));
        assert!(!gated.usable_now);
        assert_eq!(
            gated.unavailable_reason.as_deref(),
            Some("Usage windows are already at 0%")
        );

        // Partial usage keeps redemption enabled.
        let active = apply_codex_usage_eligibility(rich, Some(false), Some(14.0), Some(82.0));
        assert!(active.usable_now);
    }

    #[tokio::test]
    async fn redeems_anthropic_and_codex_resets_over_http() {
        use axum::{
            extract::Path,
            http::HeaderMap,
            routing::{get, post},
            Json, Router,
        };
        use std::sync::atomic::{AtomicUsize, Ordering};

        let usage_hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = Arc::clone(&usage_hits);

        let app = Router::new()
            .route(
                "/api/oauth/usage",
                get(move |headers: HeaderMap| {
                    let hits = Arc::clone(&hits_clone);
                    async move {
                        assert_eq!(
                            headers.get("anthropic-beta").and_then(|v| v.to_str().ok()),
                            Some("oauth-2025-04-20")
                        );
                        hits.fetch_add(1, Ordering::SeqCst);
                        Json(json!({
                            "cedar_ember": {
                                "eligible": true,
                                "at_limit": true,
                                "grants": [{
                                    "id": "grant_1",
                                    "label": "Usage limit reset",
                                    "resets_left": 1,
                                    "clears": ["five_hour", "seven_day"],
                                    "usable_now": true
                                }]
                            }
                        }))
                    }
                }),
            )
            .route(
                "/api/organizations/:org/reset_rate_limits",
                post(
                    |Path(org): Path<String>, Json(body): Json<Value>| async move {
                        assert_eq!(org, "org_abc");
                        assert_eq!(body["program"], "cedar_ember");
                        assert_eq!(body["grant_id"], "grant_1");
                        Json(json!({
                            "result": "reset",
                            "resets_left": 0,
                            "cleared": ["five_hour", "seven_day"]
                        }))
                    },
                ),
            )
            .route(
                "/wham/rate-limit-reset-credits/consume",
                post(|headers: HeaderMap, Json(body): Json<Value>| async move {
                    assert_eq!(
                        headers
                            .get("chatgpt-account-id")
                            .and_then(|v| v.to_str().ok()),
                        Some("acct_123")
                    );
                    assert_eq!(body["credit_id"], "crd_1");
                    assert!(body["redeem_request_id"].as_str().is_some());
                    Json(json!({ "outcome": "reset" }))
                }),
            )
            .with_state(());

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let client = reqwest::Client::new();
        let store = AnthropicResetStore::new();
        let first = store
            .get_or_fetch(&client, &base, "acct", "tok", false)
            .await
            .expect("first fetch");
        assert_eq!(first.available_count, 1);
        // Second read with same `at_wall` hits the 15-minute cache.
        let _second = store
            .get_or_fetch(&client, &base, "acct", "tok", false)
            .await
            .expect("cached fetch");
        assert_eq!(usage_hits.load(Ordering::SeqCst), 1);
        // Flipping `at_wall` bypasses the idle cache immediately.
        let _wall = store
            .get_or_fetch(&client, &base, "acct", "tok", true)
            .await
            .expect("at_wall fetch");
        assert_eq!(usage_hits.load(Ordering::SeqCst), 2);

        let anth_out =
            redeem_anthropic_reset(&client, &base, "tok", "org_abc", "grant_1", "req_1").await;
        assert_eq!(
            anth_out,
            ResetRedeemOutcome::Reset {
                resets_left: Some(0),
                cleared: vec!["5h".to_string(), "Weekly".to_string()],
            }
        );

        let codex_out = redeem_codex_reset(
            &client,
            &base,
            "tok",
            "acct_123",
            Some("crd_1"),
            "req_codex_1",
        )
        .await;
        assert_eq!(
            codex_out,
            ResetRedeemOutcome::Reset {
                resets_left: None,
                cleared: vec!["5h".to_string(), "Weekly".to_string()],
            }
        );
    }
}
