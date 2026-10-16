//! Google Antigravity plan and quota windows.
//!
//! The Cloud Code backend the Antigravity CLI talks to reports them without
//! spending any quota:
//! - `v1internal:loadCodeAssist` names the plan (`paidTier`, e.g. "Google AI
//!   Ultra", else `currentTier`) and the companion project;
//! - `v1internal:retrieveUserQuota` returns one bucket per model with
//!   `remainingFraction` and, when the model is metered, `resetTime`.
//!
//! Google meters model families separately and sets the window length per
//! plan (5 hours, weekly…), so windows are grouped by family and carry the
//! reported reset instead of a hard-coded duration. Both endpoints are
//! undocumented; a failure degrades to "not reported".
use serde_json::{json, Map, Value};

use super::subscription_usage::Quota;

const CLOUD_CODE: &str = "https://cloudcode-pa.googleapis.com/v1internal";

/// Display family of a metered model, or `None` for models Google does not
/// meter separately (tab completion, internal chat ids).
fn family(model: &str) -> Option<&'static str> {
    let m = model.to_ascii_lowercase();
    if m.contains("claude") {
        Some("Claude")
    } else if m.contains("gpt") {
        Some("GPT-OSS")
    } else if m.contains("image") {
        Some("Image")
    } else if m.contains("gemini") && m.contains("pro") {
        Some("Gemini Pro")
    } else if m.contains("gemini") && m.contains("flash") {
        Some("Gemini Flash")
    } else if m.starts_with("agy-") {
        Some("Gemini Agent")
    } else {
        None
    }
}

/// Merge per-model buckets into one window per family: the most used model
/// and the earliest reset. A bucket with neither a reset nor any usage is not
/// metered and is skipped, so an unmetered family never shows a fake 0%.
pub fn parse_quota(payload: &Value) -> Vec<Value> {
    struct Window {
        label: &'static str,
        used: f64,
        reset: Option<i64>,
    }
    let mut windows: Vec<Window> = Vec::new();
    for bucket in payload["buckets"].as_array().into_iter().flatten() {
        let Some(label) = bucket["modelId"].as_str().and_then(family) else {
            continue;
        };
        let Some(remaining) = bucket["remainingFraction"]
            .as_f64()
            .filter(|f| f.is_finite())
        else {
            continue;
        };
        let used = (1.0 - remaining).clamp(0.0, 1.0) * 100.0;
        let reset = bucket["resetTime"]
            .as_str()
            .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
            .map(|t| t.timestamp());
        if reset.is_none() && used == 0.0 {
            continue;
        }
        match windows.iter_mut().find(|w| w.label == label) {
            Some(w) => {
                w.used = w.used.max(used);
                w.reset = match (w.reset, reset) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
            }
            None => windows.push(Window { label, used, reset }),
        }
    }
    windows
        .into_iter()
        .map(|w| {
            let mut v = json!({"label": w.label, "used_percent": (w.used * 10.0).round() / 10.0});
            if let Some(reset) = w.reset {
                v["reset_at"] = json!(reset);
            }
            v
        })
        .collect()
}

/// Plan name: the paid Google One tier when present, else the base tier.
pub fn parse_plan(payload: &Value) -> Option<String> {
    ["paidTier", "currentTier"].iter().find_map(|tier| {
        payload[tier]["name"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .map(str::to_string)
    })
}

async fn call(
    client: &reqwest::Client,
    token: &str,
    method: &str,
    body: Value,
) -> Result<Value, Quota> {
    let response = client
        .post(format!("{CLOUD_CODE}:{method}"))
        .bearer_auth(token)
        .header("User-Agent", "antigravity")
        .json(&body)
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| Quota::Unavailable(format!("Antigravity quota unreachable: {e}")))?;
    match response.status().as_u16() {
        200..=299 => response
            .json()
            .await
            .map_err(|e| Quota::Unavailable(format!("Unreadable Antigravity quota: {e}"))),
        401 | 403 => Err(Quota::Unauthorized),
        status => Err(Quota::Unavailable(format!(
            "Antigravity quota returned HTTP {status}"
        ))),
    }
}

/// Read the plan and windows with the routing login's access token.
pub async fn read(client: &reqwest::Client, access_token: &str) -> Quota {
    let assist = match call(
        client,
        access_token,
        "loadCodeAssist",
        json!({"metadata": {"ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"}}),
    )
    .await
    {
        Ok(v) => v,
        Err(q) => return q,
    };
    let mut fields = Map::new();
    if let Some(plan) = parse_plan(&assist) {
        fields.insert("antigravity_plan".into(), json!(plan));
    }
    let body = match assist["cloudaicompanionProject"].as_str() {
        Some(project) => json!({"project": project}),
        None => json!({}),
    };
    match call(client, access_token, "retrieveUserQuota", body).await {
        Ok(quota) => {
            fields.insert(
                "antigravity_windows".into(),
                Value::Array(parse_quota(&quota)),
            );
        }
        Err(Quota::Unauthorized) => return Quota::Unauthorized,
        Err(_) => {}
    }
    Quota::Fields(fields)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_buckets_by_family_with_most_used_and_earliest_reset() {
        let payload = json!({"buckets": [
            {"modelId": "claude-opus-4-6-thinking", "remainingFraction": 0.4, "resetTime": "2026-10-16T19:22:22Z", "tokenType": "WTUS"},
            {"modelId": "claude-sonnet-4-6", "remainingFraction": 0.9, "resetTime": "2026-10-16T18:00:00Z"},
            {"modelId": "gemini-3.1-pro-high", "remainingFraction": 1, "resetTime": "2026-10-16T19:22:22Z"},
            {"modelId": "gemini-3.5-flash", "remainingFraction": 1, "resetTime": "2026-10-23T00:00:00Z"},
            {"modelId": "agy-demo-high", "remainingFraction": 1},
            {"modelId": "chat_20706", "remainingFraction": 0.1},
            {"modelId": "tab_flash_lite_preview", "remainingFraction": 1}
        ]});
        let windows = parse_quota(&payload);
        let labels: Vec<_> = windows
            .iter()
            .map(|w| w["label"].as_str().unwrap())
            .collect();
        assert_eq!(labels, ["Claude", "Gemini Pro", "Gemini Flash"]);
        assert_eq!(windows[0]["used_percent"], 60.0);
        assert_eq!(
            windows[0]["reset_at"],
            chrono::DateTime::parse_from_rfc3339("2026-10-16T18:00:00Z")
                .unwrap()
                .timestamp()
        );
        assert_eq!(windows[1]["used_percent"], 0.0);
    }

    #[test]
    fn plan_prefers_the_paid_tier() {
        let payload = json!({
            "currentTier": {"id": "free-tier", "name": "Antigravity"},
            "paidTier": {"id": "g1-ultra-tier", "name": "Google AI Ultra"}
        });
        assert_eq!(parse_plan(&payload).as_deref(), Some("Google AI Ultra"));
        assert_eq!(
            parse_plan(&json!({"currentTier": {"name": "Antigravity"}})).as_deref(),
            Some("Antigravity")
        );
    }
}
