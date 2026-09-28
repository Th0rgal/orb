//! Read-only subscription receipts; account identity must match before sharing
//! Cursor billing data obtained through the Grok Bot dashboard session.
use super::{cursor::Cursor, grok::Grok};
use crate::api::auth::AuthUser;
use axum::{Extension, Json};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::OnceLock,
    time::{Duration, Instant},
};

fn owner(name: &str, user: &str) -> bool {
    std::env::var(name).is_ok_and(|v| v == user)
}
fn percent(value: &Value) -> Option<f64> {
    value.as_f64().filter(|n| n.is_finite() && *n >= 0.0)
}
fn window(label: &str, value: &Value) -> Option<Value> {
    percent(value).map(|used| json!({"label":label,"used_percent":used}))
}
fn cursor_usage(value: &Value) -> Option<Value> {
    let plan = &value["planUsage"];
    let total = window("Total", &plan["totalPercentUsed"])?;
    let details: Vec<Value> = [
        ("Auto + Composer", "autoPercentUsed"),
        ("API", "apiPercentUsed"),
    ]
    .into_iter()
    .filter_map(|(label, key)| window(label, &plan[key]))
    .collect();
    Some(
        json!({"windows":[total],"details":details,"reset_at_ms":value["billingCycleEnd"],"source":"account_dashboard"}),
    )
}
fn grok_usage(value: &Value) -> Option<Value> {
    if value["usesPooledEnterpriseAllowance"] == true || value["hasNonZeroIncludedLimit"] != true {
        return None;
    }
    let quota = window("Weekly", &value["usagePercent"])?;
    Some(
        json!({"windows":[quota],"details":[],"reset_at":value["nextResetTimestampUtc"],"source":"account_dashboard"}),
    )
}
fn same_account(cursor: &Value, dashboard: &Value) -> bool {
    let a = cursor["userEmail"].as_str().unwrap_or("").trim();
    let b = dashboard["email"].as_str().unwrap_or("").trim();
    !a.is_empty() && !b.is_empty() && a.eq_ignore_ascii_case(b)
}

pub async fn get(Extension(user): Extension<AuthUser>) -> Json<Value> {
    // Permission checks precede cache access, including after an owner changes.
    let grok_owner = owner("GROK_BOT_OWNER", &user.id);
    let cursor_owner = owner("CURSOR_CLOUD_OWNER", &user.id);
    if !grok_owner {
        return Json(json!({"accounts":{}}));
    }
    type Cache = HashMap<(String, bool), (Instant, Value)>;
    static CACHE: OnceLock<tokio::sync::Mutex<Cache>> = OnceLock::new();
    let mut cache = CACHE.get_or_init(Default::default).lock().await;
    let key = (user.id.clone(), cursor_owner);
    if let Some((at, value)) = cache.get(&key) {
        if at.elapsed() < Duration::from_secs(60) {
            return Json(value.clone());
        }
    }
    let mut accounts = serde_json::Map::new();
    if let Ok(adapter) = Grok::from_account("grok-default") {
        let (sand, period, identity) = tokio::join!(
            adapter.dashboard_usage("GetSandUsageStatus"),
            adapter.dashboard_usage("GetCurrentPeriodUsage"),
            adapter.dashboard_usage("GetMe")
        );
        if let Ok(value) = sand {
            if let Some(usage) = grok_usage(&value) {
                accounts.insert("grok-default".into(), usage);
            }
        }
        if cursor_owner {
            if let (Ok(cursor), Ok(identity), Ok(period)) =
                (Cursor::from_account("cursor-default"), identity, period)
            {
                if let Ok(me) = cursor.request(reqwest::Method::GET, "me", None).await {
                    if same_account(&me, &identity) {
                        if let Some(usage) = cursor_usage(&period) {
                            accounts.insert("cursor-default".into(), usage);
                        }
                    }
                }
            }
        }
    }
    let result = json!({"accounts":accounts,"checked_at":chrono::Utc::now().to_rfc3339()});
    cache.retain(|_, (at, _)| at.elapsed() < Duration::from_secs(60));
    cache.insert(key, (Instant::now(), result.clone()));
    Json(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_provider_percentages_without_recomputing_total() {
        let result = cursor_usage(&json!({"planUsage":{"totalPercentUsed":5.95,"autoPercentUsed":4.9,"apiPercentUsed":37.57,"totalSpend":18468,"limit":40000}})).unwrap();
        assert_eq!(result["windows"][0]["used_percent"], 5.95);
        assert_eq!(result["details"][1]["used_percent"], 37.57);
        assert!(cursor_usage(&json!({"planUsage":{}})).is_none());
    }
    #[test]
    fn grok_percent_is_not_a_fraction_and_unknown_is_not_zero() {
        let result =
            grok_usage(&json!({"usagePercent":0.154522,"hasNonZeroIncludedLimit":true})).unwrap();
        assert_eq!(result["windows"][0]["used_percent"], 0.154522);
        assert!(grok_usage(&json!({"hasNonZeroIncludedLimit":true})).is_none());
        assert!(grok_usage(&json!({"usagePercent":0,"hasNonZeroIncludedLimit":true,"usesPooledEnterpriseAllowance":true})).is_none());
    }
    #[test]
    fn never_assigns_another_accounts_cursor_allowance() {
        assert!(same_account(
            &json!({"userEmail":"A@example.com"}),
            &json!({"email":"a@example.com"})
        ));
        assert!(!same_account(
            &json!({"userEmail":"a@example.com"}),
            &json!({"email":"b@example.com"})
        ));
        assert!(!same_account(&json!({}), &json!({})));
    }
}
