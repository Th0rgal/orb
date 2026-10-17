//! Google Antigravity plan and quota windows.
//!
//! The Cloud Code backend the Antigravity CLI talks to reports them without
//! spending any quota:
//! - `v1internal:loadCodeAssist` names the plan (`paidTier`, e.g. "Google AI
//!   Ultra", else `currentTier`) and the companion project;
//! - `v1internal:retrieveUserQuotaSummary` (what the CLI's quota screen reads)
//!   returns model groups ("Gemini Models", "Claude and GPT models"), each
//!   with a shared 5-hour and weekly bucket: `window`, `remainingFraction`,
//!   `resetTime`. Quota is consumed in proportion to token cost.
//! - `v1internal:retrieveUserQuota` is the older per-model 5-hour view, kept
//!   as a fallback when the summary is unavailable.
//!
//! All endpoints are undocumented; a failure degrades to "not reported".
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

/// Short card name of a quota group.
fn group_label(group: &Value) -> String {
    let buckets = group["buckets"].as_array().into_iter().flatten();
    let ids: Vec<&str> = buckets.filter_map(|b| b["bucketId"].as_str()).collect();
    if ids.iter().any(|id| id.starts_with("gemini-")) {
        return "Gemini".into();
    }
    if ids.iter().any(|id| id.starts_with("3p-")) {
        return "Claude & GPT".into();
    }
    group["displayName"]
        .as_str()
        .map(|s| s.trim_end_matches(" models").trim_end_matches(" Models"))
        .filter(|s| !s.is_empty())
        .unwrap_or("Models")
        .to_string()
}

/// One window per (group, bucket) from `retrieveUserQuotaSummary`, labelled
/// "Gemini · 5h", "Claude & GPT · Weekly". Unknown window names are kept
/// verbatim so a new period (daily, monthly) still shows up.
pub fn parse_summary(payload: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for group in payload["groups"].as_array().into_iter().flatten() {
        let name = group_label(group);
        let mut buckets: Vec<&Value> = group["buckets"].as_array().into_iter().flatten().collect();
        // Shortest window first, so 5h precedes Weekly in every client.
        buckets.sort_by_key(|b| match b["window"].as_str() {
            Some("5h") => 0,
            Some("daily") => 1,
            Some("weekly") => 2,
            _ => 3,
        });
        for bucket in buckets {
            let Some(remaining) = bucket["remainingFraction"]
                .as_f64()
                .filter(|f| f.is_finite())
            else {
                continue;
            };
            let window = match bucket["window"].as_str().unwrap_or("") {
                "5h" => "5h".to_string(),
                "weekly" => "Weekly".to_string(),
                "daily" => "Daily".to_string(),
                "" => continue,
                other => other.to_string(),
            };
            let used = (1.0 - remaining).clamp(0.0, 1.0) * 100.0;
            let mut v = json!({"label": format!("{name} · {window}"), "used_percent": (used * 10.0).round() / 10.0});
            if let Some(reset) = bucket["resetTime"]
                .as_str()
                .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
            {
                v["reset_at"] = json!(reset.timestamp());
            }
            out.push(v);
        }
    }
    out
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
    match call(
        client,
        access_token,
        "retrieveUserQuotaSummary",
        body.clone(),
    )
    .await
    {
        Ok(summary) => {
            let windows = parse_summary(&summary);
            if !windows.is_empty() {
                fields.insert("antigravity_windows".into(), Value::Array(windows));
                return Quota::Fields(fields);
            }
        }
        Err(Quota::Unauthorized) => return Quota::Unauthorized,
        Err(_) => {}
    }
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
    fn summary_gives_shared_5h_and_weekly_windows_per_group() {
        let payload = json!({"groups": [
            {"displayName": "Gemini Models", "buckets": [
                {"bucketId": "gemini-weekly", "window": "weekly", "resetTime": "2026-10-23T15:16:17Z", "remainingFraction": 0.9972415},
                {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-10-17T14:32:07Z", "remainingFraction": 1}
            ]},
            {"displayName": "Claude and GPT models", "buckets": [
                {"bucketId": "3p-weekly", "window": "weekly", "resetTime": "2026-10-24T09:32:07Z", "remainingFraction": 0.25},
                {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.5}
            ]}
        ]});
        let w = parse_summary(&payload);
        let labels: Vec<_> = w.iter().map(|v| v["label"].as_str().unwrap()).collect();
        assert_eq!(
            labels,
            [
                "Gemini · 5h",
                "Gemini · Weekly",
                "Claude & GPT · 5h",
                "Claude & GPT · Weekly"
            ]
        );
        assert_eq!(w[1]["used_percent"], 0.3);
        assert_eq!(w[1]["reset_at"], 1792768577);
        assert_eq!(w[3]["used_percent"], 75.0);
        assert!(w[2].get("reset_at").is_none());
        assert!(parse_summary(&json!({})).is_empty());
    }

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
