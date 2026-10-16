//! Live subscription quotas for providers whose public APIs omit them.
//!
//! - Muse Code: `POST https://api.meta.ai/muse-code/key` with the CLI device
//!   credential (the same call CLIProxyAPI makes at login) returns the plan and
//!   the 5-hour / weekly windows. It is idempotent: it returns the existing
//!   inference key, which is discarded here.
//! - Mistral Vibe: the console's own `billing.vibeUsage` tRPC call returns the
//!   monthly plan percentage and reset. It needs a signed-in console session
//!   (`ory_session_*` + `csrftoken` cookies); an API key cannot read it.
//!
//! Both are undocumented and may change; failures degrade to "not reported".
use serde_json::{json, Map, Value};

pub const MUSE_KEY_URL: &str = "https://api.meta.ai/muse-code/key";
pub const MISTRAL_VIBE_USAGE_URL: &str = "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D";
pub const MISTRAL_WHOAMI_URL: &str = "https://console.mistral.ai/api/vibe/whoami";

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
}
