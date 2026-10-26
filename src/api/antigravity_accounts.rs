//! Which connected Google Antigravity account serves, and when to switch.
//!
//! Several Antigravity logins can be connected through CLIProxyAPI. Each
//! auth file carries a numeric `priority` (larger wins, CLIProxyAPI's own
//! convention). This module keeps, per auth file:
//! - eligibility: Google refuses to onboard some accounts until the owner
//!   verifies them (`loadCodeAssist` returns no companion project and an
//!   `ineligibleTiers` entry such as `VALIDATION_REQUIRED`). Such an account
//!   cannot serve a single request, so it is excluded from Core routing,
//!   demoted below every eligible login in CLIProxyAPI, and never handed to a
//!   machine as the native sign-in;
//! - remaining Gemini quota (`retrieveUserQuota`), so the native sign-in moves
//!   to an account with quota left when the preferred one is exhausted, and
//!   back once its window resets.
//!
//! Eligibility is re-checked periodically: once the owner verifies the
//! account, its project id is written to the auth file (CLIProxyAPI watches
//! the directory), its configured priority is restored, and it becomes the
//! routing and machine sign-in again without any manual step.
use std::collections::HashMap;
use std::path::Path;
use std::sync::{LazyLock, RwLock};

use serde_json::{json, Value};

/// Base priority Core restores when an account becomes eligible again.
const BASE_PRIORITY_KEY: &str = "sandboxed_base_priority";
/// CLIProxyAPI priority of an account Google refuses to serve: below any
/// eligible login, so the proxy only reaches it when nothing else is left.
const DEMOTED_PRIORITY: i64 = -1000;
const REFRESH_EVERY: std::time::Duration = std::time::Duration::from_secs(300);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Eligibility {
    Eligible,
    /// Google requires the owner to verify the account before it serves.
    NeedsVerification,
    /// Not checked yet, or the check failed transiently.
    Unknown,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Health {
    pub eligibility: Eligibility,
    /// Lowest remaining fraction across Gemini models, if reported.
    pub gemini_remaining: Option<f64>,
    /// When that Gemini window resets (Unix seconds).
    pub gemini_reset: Option<i64>,
    /// Same for the "Claude and GPT models" pool.
    pub claude_remaining: Option<f64>,
    pub claude_reset: Option<i64>,
    /// A native run was refused with "Individual quota reached" on this
    /// login: unusable until then (Unix seconds), whatever the figures say.
    pub refused_until: Option<i64>,
}

/// Below this remaining fraction Google refuses requests ("Individual quota
/// reached"): quota is charged per request cost, so a login at 0.5 % left is
/// spent in practice.
const SPENT_FRACTION: f64 = 0.02;

static HEALTH: LazyLock<RwLock<HashMap<String, Health>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));
static CHOSEN: LazyLock<RwLock<Option<String>>> = LazyLock::new(|| RwLock::new(None));

pub(crate) fn health(file: &str) -> Option<Health> {
    HEALTH.read().ok()?.get(file).cloned()
}

fn set_health(file: &str, health: Health) {
    if let Ok(mut map) = HEALTH.write() {
        map.insert(file.to_string(), health);
    }
}

/// True when Google refuses to serve this auth file until it is verified.
pub(crate) fn needs_verification(file: &str) -> bool {
    health(file).is_some_and(|h| h.eligibility == Eligibility::NeedsVerification)
}

/// Eligibility from a `loadCodeAssist` response.
pub(crate) fn eligibility(assist: &Value) -> Eligibility {
    let has_project = assist["cloudaicompanionProject"]
        .as_str()
        .or_else(|| assist["cloudaicompanionProject"]["id"].as_str())
        .is_some_and(|p| !p.trim().is_empty());
    if has_project {
        return Eligibility::Eligible;
    }
    let ineligible = assist["ineligibleTiers"]
        .as_array()
        .is_some_and(|tiers| !tiers.is_empty());
    let onboarded = assist["currentTier"].is_object() || assist["paidTier"].is_object();
    if ineligible && !onboarded {
        Eligibility::NeedsVerification
    } else if onboarded {
        // Onboarded without a project id in this response: still serves.
        Eligibility::Eligible
    } else {
        Eligibility::Unknown
    }
}

pub(crate) fn project(assist: &Value) -> Option<String> {
    assist["cloudaicompanionProject"]
        .as_str()
        .or_else(|| assist["cloudaicompanionProject"]["id"].as_str())
        .filter(|p| !p.trim().is_empty())
        .map(str::to_string)
}

fn is_gemini(model: &str) -> bool {
    let m = model.to_ascii_lowercase();
    m.contains("gemini") || m.starts_with("agy-")
}

fn is_claude_or_gpt(model: &str) -> bool {
    super::antigravity_usage::quota_pool(model) == "claude-gpt"
}

/// Lowest remaining Gemini fraction and its earliest reset, from either
/// `retrieveUserQuota` (`buckets[]`) or `fetchAvailableModels`
/// (`models{id: {quotaInfo}}`). Google omits `remainingFraction` when it is
/// zero (proto3 default), so a bucket with a reset and no fraction is empty.
pub(crate) fn gemini_quota(payload: &Value) -> (Option<f64>, Option<i64>) {
    pool_quota(payload, is_gemini)
}

/// [`gemini_quota`] for the models `in_pool` selects.
pub(crate) fn pool_quota(payload: &Value, in_pool: fn(&str) -> bool) -> (Option<f64>, Option<i64>) {
    let mut entries: Vec<(&str, &Value)> = Vec::new();
    for bucket in payload["buckets"].as_array().into_iter().flatten() {
        if let Some(id) = bucket["modelId"].as_str() {
            entries.push((id, bucket));
        }
    }
    for (id, model) in payload["models"].as_object().into_iter().flatten() {
        entries.push((id.as_str(), &model["quotaInfo"]));
    }
    let mut remaining: Option<f64> = None;
    let mut reset: Option<i64> = None;
    for (id, info) in entries {
        if !in_pool(id) {
            continue;
        }
        let at = info["resetTime"]
            .as_str()
            .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
            .map(|t| t.timestamp());
        let fraction = match info["remainingFraction"].as_f64() {
            Some(f) if f.is_finite() => f.clamp(0.0, 1.0),
            Some(_) => continue,
            None if at.is_some() => 0.0,
            None => continue,
        };
        remaining = Some(remaining.map_or(fraction, |r: f64| r.min(fraction)));
        if fraction < 1.0 {
            reset = match (reset, at) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
        }
    }
    (remaining, reset)
}

/// One connected Antigravity login, as needed to pick between them.
#[derive(Clone, Debug)]
pub(crate) struct Candidate {
    pub file: String,
    /// Configured priority (larger wins).
    pub priority: i64,
    pub expires_at: i64,
}

fn pool_spent(remaining: Option<f64>, reset: Option<i64>, now: i64) -> bool {
    remaining.is_some_and(|r| r < SPENT_FRACTION) && reset.is_none_or(|at| at > now)
}

/// Every pool has quota and no native run was refused recently. A machine
/// holds one sign-in for every model, so a login spent on one pool gives way
/// to a sibling that can serve them all.
fn has_quota(health: Option<&Health>, now: i64) -> bool {
    health.is_none_or(|h| {
        !pool_spent(h.gemini_remaining, h.gemini_reset, now)
            && !pool_spent(h.claude_remaining, h.claude_reset, now)
            && h.refused_until.is_none_or(|at| at <= now)
    })
}

/// How many pools are spent or refused: with no login usable for every
/// model, the one that still serves some pools beats one that serves none.
fn spent_pools(health: Option<&Health>, now: i64) -> u64 {
    let Some(h) = health else { return 0 };
    if h.refused_until.is_some_and(|at| at > now) {
        return 2;
    }
    u64::from(pool_spent(h.gemini_remaining, h.gemini_reset, now))
        + u64::from(pool_spent(h.claude_remaining, h.claude_reset, now))
}

/// When a spent login is expected back (its latest blocking reset).
fn usable_again(health: Option<&Health>, now: i64) -> i64 {
    let Some(h) = health else { return now };
    [
        pool_spent(h.gemini_remaining, h.gemini_reset, now)
            .then(|| h.gemini_reset.unwrap_or(i64::MAX)),
        pool_spent(h.claude_remaining, h.claude_reset, now)
            .then(|| h.claude_reset.unwrap_or(i64::MAX)),
        h.refused_until.filter(|at| *at > now),
    ]
    .into_iter()
    .flatten()
    .max()
    .unwrap_or(now)
}

/// The login that should serve native runs: highest priority among eligible
/// accounts with quota left in every pool; failing that, the eligible one
/// with the fewest spent pools, then the one that comes back first; never an account Google refuses to serve.
pub(crate) fn choose<'a>(
    candidates: &'a [Candidate],
    health: &HashMap<String, Health>,
    now: i64,
) -> Option<&'a Candidate> {
    let mut eligible: Vec<&Candidate> = candidates
        .iter()
        .filter(|c| {
            health
                .get(&c.file)
                .is_none_or(|h| h.eligibility != Eligibility::NeedsVerification)
        })
        .collect();
    eligible.sort_by(|a, b| {
        b.priority
            .cmp(&a.priority)
            .then_with(|| b.expires_at.cmp(&a.expires_at))
            .then_with(|| a.file.cmp(&b.file))
    });
    let now_epoch = now.max(0) as u64;
    let any_has_quota = eligible.iter().any(|c| has_quota(health.get(&c.file), now));
    let route_candidates: Vec<crate::orb_spec::RouteCandidate> = eligible
        .iter()
        .enumerate()
        .map(|(rank, c)| {
            let c_has_quota = has_quota(health.get(&c.file), now);
            let reset_at = usable_again(health.get(&c.file), now).max(0) as u64;
            if any_has_quota {
                crate::orb_spec::RouteCandidate {
                    account_id: (rank + 1) as u32,
                    score: rank as u64,
                    is_rejected: !c_has_quota,
                    reset_epoch: if c_has_quota {
                        0
                    } else {
                        reset_at.max(now_epoch.saturating_add(1))
                    },
                }
            } else {
                crate::orb_spec::RouteCandidate {
                    account_id: (rank + 1) as u32,
                    score: (spent_pools(health.get(&c.file), now) << 56).saturating_add(
                        reset_at
                            .min(1 << 45)
                            .saturating_mul(1000)
                            .saturating_add(rank as u64),
                    ),
                    is_rejected: false,
                    reset_epoch: 0,
                }
            }
        })
        .collect();
    let host_choice = eligible
        .iter()
        .copied()
        .find(|c| has_quota(health.get(&c.file), now))
        .or_else(|| {
            eligible.iter().copied().min_by_key(|c| {
                let h = health.get(&c.file);
                (spent_pools(h, now), usable_again(h, now))
            })
        });
    let host_id = host_choice.and_then(|chosen| {
        eligible
            .iter()
            .position(|c| std::ptr::eq(*c, chosen))
            .map(|idx| (idx + 1) as u32)
    });
    let lean_id = crate::provider_health::observe_argmin_selection_shadow(
        None,
        now_epoch,
        &route_candidates,
        host_id,
    );
    lean_id
        .and_then(|id| eligible.get((id as usize).wrapping_sub(1)).copied())
        .or(host_choice)
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// Configured priority of an auth file: the base Core saved before demoting
/// it, else its CLIProxyAPI priority, else 0.
fn base_priority(value: &Value) -> i64 {
    value[BASE_PRIORITY_KEY]
        .as_i64()
        .or_else(|| value["priority"].as_i64())
        .unwrap_or(0)
}

/// Connected, enabled Antigravity logins in the routing namespace.
pub(crate) fn candidates(dir: &Path) -> Vec<Candidate> {
    super::cli_proxy_accounts::accounts_in(dir)
        .into_iter()
        .filter(|a| {
            a.provider == crate::ai_providers::ProviderType::Antigravity
                && !a.disabled
                && a.prefix.as_deref() == Some("antigravity")
        })
        .map(|a| Candidate {
            priority: read_json(&dir.join(&a.file))
                .map(|v| base_priority(&v))
                .unwrap_or(0),
            expires_at: a.oauth.expires_at,
            file: a.file,
        })
        .collect()
}

/// The auth file native runs should use now.
pub(crate) fn chosen_file(dir: &Path) -> Option<String> {
    let candidates = candidates(dir);
    let map = HEALTH.read().map(|m| m.clone()).unwrap_or_default();
    choose(&candidates, &map, chrono::Utc::now().timestamp()).map(|c| c.file.clone())
}

/// Desired edits to an auth file for its eligibility; `None` when unchanged.
pub(crate) fn reconcile_file(
    value: &Value,
    eligibility: Eligibility,
    project: Option<&str>,
) -> Option<Value> {
    let mut next = value.clone();
    let obj = next.as_object_mut()?;
    match eligibility {
        Eligibility::NeedsVerification => {
            if !obj.contains_key(BASE_PRIORITY_KEY) {
                let base = obj.get("priority").and_then(Value::as_i64).unwrap_or(0);
                obj.insert(BASE_PRIORITY_KEY.into(), json!(base));
            }
            obj.insert("priority".into(), json!(DEMOTED_PRIORITY));
        }
        Eligibility::Eligible => {
            if let Some(base) = obj.remove(BASE_PRIORITY_KEY) {
                obj.insert("priority".into(), base);
            }
            let missing = obj
                .get("project_id")
                .and_then(Value::as_str)
                .is_none_or(|p| p.trim().is_empty());
            if let (true, Some(project)) = (missing, project) {
                obj.insert("project_id".into(), json!(project));
            }
        }
        Eligibility::Unknown => return None,
    }
    (next != *value).then_some(next)
}

/// CLIProxyAPI priority for the account ranked `rank` of `count` in the
/// user's order: CLIProxyAPI tries higher values first.
pub(crate) fn ranked_priority(rank: usize, count: usize) -> i64 {
    (count.saturating_sub(rank) as i64) * 10
}

/// Desired auth file for a new configured priority; `None` when unchanged.
/// A demoted (unverified) login keeps its demotion and stores the priority
/// as the base it is restored to.
pub(crate) fn with_priority(value: &Value, priority: i64) -> Option<Value> {
    let mut next = value.clone();
    let obj = next.as_object_mut()?;
    let key = if obj.contains_key(BASE_PRIORITY_KEY) {
        BASE_PRIORITY_KEY
    } else {
        "priority"
    };
    obj.insert(key.into(), json!(priority));
    (next != *value).then_some(next)
}

/// Mirror the user's account order into the CLIProxyAPI auth files, which
/// pick the login for pooled providers (Antigravity, Muse Code).
pub(crate) fn sync_cli_proxy_priorities(accounts: &[crate::ai_providers::AIProvider]) {
    let Some(dir) = super::cli_proxy_accounts::auth_dir() else {
        return;
    };
    let files: Vec<&str> = accounts
        .iter()
        .filter_map(|a| a.cli_proxy_auth_file.as_deref())
        .collect();
    for (rank, file) in files.iter().enumerate() {
        if file.contains('/') || file.contains("..") {
            continue;
        }
        let path = dir.join(file);
        let Some(value) = read_json(&path) else {
            continue;
        };
        if let Some(next) = with_priority(&value, ranked_priority(rank, files.len())) {
            if let Err(error) = write_auth_file(&path, &next) {
                tracing::warn!(file, %error, "Could not update CLIProxyAPI login priority");
            }
        }
    }
}

/// Auth file key holding the last Gemini weekly window seen for the login.
const GEMINI_WEEKLY_KEY: &str = "sandboxed_gemini_weekly";

/// Show the login's last-seen Gemini weekly window when Google reports only
/// the 5-hour one, and store a fresh weekly reading in its auth file.
pub(crate) fn remember_gemini_weekly(file: &str, windows: &mut Vec<Value>) {
    let Some(dir) = super::cli_proxy_accounts::auth_dir() else {
        return;
    };
    if file.contains('/') || file.contains("..") {
        return;
    }
    let path = dir.join(file);
    let Some(value) = read_json(&path) else {
        return;
    };
    let stored = value.get(GEMINI_WEEKLY_KEY);
    let next = super::antigravity_usage::with_remembered_gemini_weekly(
        windows,
        stored,
        chrono::Utc::now().timestamp(),
    );
    if next.as_ref() == stored {
        return;
    }
    let mut value = value.clone();
    let Some(obj) = value.as_object_mut() else {
        return;
    };
    match next {
        Some(next) => obj.insert(GEMINI_WEEKLY_KEY.into(), next),
        None => obj.remove(GEMINI_WEEKLY_KEY),
    };
    if let Err(error) = write_auth_file(&path, &value) {
        tracing::warn!(file, %error, "Could not store the Antigravity Gemini weekly window");
    }
}

/// Rewrite an auth file atomically, keeping its owner and 0600 mode.
fn write_auth_file(path: &Path, value: &Value) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let meta = std::fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Err(std::io::Error::other("refusing a symlinked auth file"));
    }
    let tmp = path.with_extension("json.sandboxed-tmp");
    let _ = std::fs::remove_file(&tmp);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)?;
    file.write_all(&serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?)?;
    file.sync_all()?;
    drop(file);
    let _ = std::os::unix::fs::chown(&tmp, Some(meta.uid()), Some(meta.gid()));
    std::fs::rename(&tmp, path)
}

/// Re-check every connected login once; returns the chosen file when the
/// native sign-in changed (including the first selection after startup).
pub(crate) async fn refresh_once(client: &reqwest::Client) -> Option<String> {
    let dir = super::cli_proxy_accounts::auth_dir()?;
    for account in super::cli_proxy_accounts::accounts_in(&dir) {
        if account.provider != crate::ai_providers::ProviderType::Antigravity
            || account.disabled
            || account.prefix.as_deref() != Some("antigravity")
        {
            continue;
        }
        let token = &account.oauth.access_token;
        let assist = super::antigravity_usage::call(
            client,
            token,
            "loadCodeAssist",
            super::antigravity_usage::assist_body(),
        )
        .await
        .ok();
        let eligibility = assist.as_ref().map_or(Eligibility::Unknown, eligibility);
        let project = assist.as_ref().and_then(project);
        let previous = health(&account.file);
        if eligibility == Eligibility::NeedsVerification
            && previous.as_ref().map(|h| h.eligibility) != Some(Eligibility::NeedsVerification)
        {
            tracing::warn!(
                account = %account.identity,
                "Antigravity account needs Google verification; excluded from routing and machine sign-in"
            );
        }
        let path = dir.join(&account.file);
        if let Some(value) = read_json(&path) {
            if let Some(next) = reconcile_file(&value, eligibility, project.as_deref()) {
                if let Err(error) = write_auth_file(&path, &next) {
                    tracing::warn!(account = %account.identity, "Antigravity auth file not updated: {error}");
                } else {
                    tracing::info!(account = %account.identity, ?eligibility, "Antigravity routing priority reconciled");
                }
            }
        }
        let ((gemini_remaining, gemini_reset), (claude_remaining, claude_reset)) = if eligibility
            == Eligibility::Eligible
        {
            let body = project
                .as_deref()
                .map_or_else(|| json!({}), |p| json!({"project": p}));
            match super::antigravity_usage::call(client, token, "retrieveUserQuota", body).await {
                Ok(quota) => (gemini_quota(&quota), pool_quota(&quota, is_claude_or_gpt)),
                Err(_) => previous.as_ref().map_or(((None, None), (None, None)), |h| {
                    (
                        (h.gemini_remaining, h.gemini_reset),
                        (h.claude_remaining, h.claude_reset),
                    )
                }),
            }
        } else {
            ((None, None), (None, None))
        };
        set_health(
            &account.file,
            Health {
                eligibility: match (eligibility, previous.as_ref()) {
                    // Keep the last known verdict through a transient failure.
                    (Eligibility::Unknown, Some(h)) => h.eligibility,
                    (e, _) => e,
                },
                gemini_remaining,
                gemini_reset,
                claude_remaining,
                claude_reset,
                refused_until: previous.as_ref().and_then(|h| h.refused_until),
            },
        );
    }
    let chosen = chosen_file(&dir);
    let mut last = CHOSEN.write().ok()?;
    if *last != chosen {
        // Also on the first pass after startup, so a priority change made
        // while Core was down reaches every machine; installing the login a
        // machine already holds is a no-op.
        tracing::info!(from = ?*last, to = ?chosen, "Antigravity machine sign-in selected");
        last.clone_from(&chosen);
        return chosen;
    }
    None
}

/// A native run was refused with "Individual quota reached": the machine
/// sign-in at that moment is spent until the announced reset, whatever its
/// quota figures say. Returns the (spent, next) logins' identities when the
/// choice moves to another login; the next dispatch pushes it to its node.
///
/// "Eligibility check failed" means Google wants the owner to verify that
/// login: it is marked unverified so the machine moves to a sibling, and the
/// periodic check restores it once verified.
pub(crate) fn note_native_quota_refusal(failure: &str) -> Option<(String, Option<String>)> {
    let ineligible = is_eligibility_refusal(failure);
    if !ineligible && !is_individual_quota_refusal(failure) {
        return None;
    }
    let dir = super::cli_proxy_accounts::auth_dir()?;
    let spent = chosen_file(&dir)?;
    let now = chrono::Utc::now();
    let until = crate::account_limits::parse_limit_reset(
        failure,
        now,
        crate::account_limits::Zone::system(),
    )
    .unwrap_or(now + chrono::Duration::hours(1))
    .timestamp()
    .min(now.timestamp() + MAX_REFUSAL_SECS);
    {
        let mut map = HEALTH.write().ok()?;
        let health = map.entry(spent.clone()).or_insert(Health {
            eligibility: Eligibility::Unknown,
            gemini_remaining: None,
            gemini_reset: None,
            claude_remaining: None,
            claude_reset: None,
            refused_until: None,
        });
        if ineligible {
            health.eligibility = Eligibility::NeedsVerification;
        } else {
            health.refused_until = Some(until);
        }
    }
    let next = chosen_file(&dir).filter(|next| *next != spent);
    let identity = |file: &str| {
        super::cli_proxy_accounts::accounts_in(&dir)
            .into_iter()
            .find(|a| a.file == file)
            .map_or_else(|| file.to_string(), |a| a.identity)
    };
    let switched = next.as_deref().map(identity);
    tracing::warn!(
        spent = %identity(&spent),
        next = ?switched,
        until,
        "Antigravity login refused a native run on its quota; machine sign-in moves on"
    );
    Some((identity(&spent), switched))
}

/// Google's per-login allowance refusal, as `agy` reports it: the message
/// inside its RESOURCE_EXHAUSTED (429) envelope. The words alone may come
/// from model output, which must not move the shared machine sign-in.
pub(crate) fn is_individual_quota_refusal(failure: &str) -> bool {
    let lower = failure.to_ascii_lowercase();
    lower.contains("individual quota reached")
        && lower.contains("resource_exhausted")
        && lower.contains("429")
}

/// `agy` refusing the signed-in login until its owner verifies it: a line of
/// the CLI's own error output, not the phrase anywhere (model output may
/// quote it, and must not move the shared machine sign-in). Wrongly marking
/// a login is also bounded: the periodic eligibility check restores it.
pub(crate) fn is_eligibility_refusal(failure: &str) -> bool {
    failure.lines().any(|line| {
        let lower = line.trim_start().to_ascii_lowercase();
        ["cli error: ", "error: "].iter().any(|prefix| {
            lower.strip_prefix(prefix).is_some_and(|rest| {
                rest.starts_with("eligibility check failed: your current account is not eligible for antigravity")
            })
        })
    })
}

/// Longest real Antigravity quota window (weekly), plus margin.
const MAX_REFUSAL_SECS: i64 = 8 * 24 * 3600;

/// Periodic eligibility/quota check; pushes the new sign-in to every static
/// node when the choice changes (managed VMs pick it up at their next run).
pub(crate) fn spawn_refresh_loop(state: std::sync::Arc<super::routes::AppState>) {
    tokio::spawn(async move {
        loop {
            if super::oauth_owner::management_enabled()
                && refresh_once(&state.http_client).await.is_some()
            {
                {
                    let ids: Vec<String> = state
                        .config
                        .remote_nodes
                        .nodes
                        .iter()
                        .map(|n| n.id.clone())
                        .collect();
                    for id in ids {
                        match super::antigravity_native::sync_node(&state, &id).await {
                            Ok(sync) => {
                                tracing::info!(node = %id, ?sync, "Antigravity sign-in switched")
                            }
                            Err(error) => {
                                tracing::warn!(node = %id, "Antigravity sign-in not switched: {error}")
                            }
                        }
                    }
                }
            }
            tokio::time::sleep(REFRESH_EVERY).await;
        }
    });
}

/// Providers whose catalog is the proxy's own per-login model list, so a
/// model missing from every discovered catalog is genuinely not offered.
const CATALOG_SCOPED: &[&str] = &["antigravity"];

/// Pure check: `Some(true)` when every complete catalog of `provider` lacks
/// `model`, `None` when there is no complete catalog to judge by.
pub(crate) fn unoffered_in(
    state: &crate::model_catalog::DiscoveryState,
    provider: &str,
    model: &str,
) -> Option<bool> {
    let mut judged = false;
    for o in state
        .connections
        .iter()
        .filter(|o| o.provider_id == provider)
    {
        let Some(success) = o.last_success.as_ref() else {
            continue;
        };
        if success.completeness != crate::model_catalog::Completeness::Complete {
            return None;
        }
        judged = true;
        if success.models.iter().any(|m| m.id == model) {
            return Some(false);
        }
    }
    judged.then_some(true)
}

/// Pure check: `true` when `connection`'s own complete catalog lacks `model`.
/// Google rolls models out per account (one Ultra login may list Opus 5.5
/// while another still lists only Opus 4.6), and CLIProxyAPI routes a model
/// only to the logins that list it.
pub(crate) fn connection_lacks(
    state: &crate::model_catalog::DiscoveryState,
    connection: &str,
    model: &str,
) -> bool {
    state
        .connections
        .iter()
        .find(|o| o.connection == connection)
        .and_then(|o| o.last_success.as_ref())
        .is_some_and(|s| {
            s.completeness == crate::model_catalog::Completeness::Complete
                && !s.models.iter().any(|m| m.id == model)
        })
}

/// True when this account's own discovered catalog lacks the model. Its
/// requests would land on a sibling login, and that login's 429 would be
/// charged to this account.
pub(crate) fn account_lacks_model(
    chains_path: &Path,
    account: &crate::ai_providers::AIProvider,
    model: &str,
) -> bool {
    if !CATALOG_SCOPED.contains(&account.provider_type.id()) {
        return false;
    }
    let route = crate::model_discovery::route(account);
    let connection =
        crate::model_catalog::route_key(&account.id.to_string(), &route.base, &route.profile);
    with_catalog(chains_path, |state| {
        connection_lacks(state, &connection, model)
    })
    .unwrap_or(false)
}

fn with_catalog<T>(
    chains_path: &Path,
    f: impl Fn(&crate::model_catalog::DiscoveryState) -> T,
) -> Option<T> {
    let fresh = CATALOG.read().ok().and_then(|c| {
        c.as_ref()
            .filter(|(at, _)| at.elapsed().as_secs() < 60)
            .map(|(_, s)| f(s))
    });
    if fresh.is_some() {
        return fresh;
    }
    let root = chains_path.parent().and_then(Path::parent)?;
    let state = crate::model_catalog::read_state(root);
    let v = f(&state);
    if let Ok(mut c) = CATALOG.write() {
        *c = Some((std::time::Instant::now(), state));
    }
    Some(v)
}

type CatalogCache = Option<(std::time::Instant, crate::model_catalog::DiscoveryState)>;
static CATALOG: LazyLock<RwLock<CatalogCache>> = LazyLock::new(|| RwLock::new(None));
static LOGGED_UNOFFERED: LazyLock<std::sync::Mutex<std::collections::HashSet<String>>> =
    LazyLock::new(Default::default);

/// True when a chain entry's model is offered by no connected account of a
/// catalog-scoped provider (logged once per model). `chains_path` is the
/// model-chain store file; the discovery state lives next to it.
pub(crate) fn model_unoffered(chains_path: &Path, provider: &str, model: &str) -> bool {
    if !CATALOG_SCOPED.contains(&provider) {
        return false;
    }
    let verdict = with_catalog(chains_path, |state| unoffered_in(state, provider, model));
    let unoffered = verdict == Some(Some(true));
    if unoffered {
        if let Ok(mut logged) = LOGGED_UNOFFERED.lock() {
            if logged.insert(format!("{provider}/{model}")) {
                tracing::warn!(
                    provider,
                    model,
                    "Chain entry skipped: no connected account offers this model"
                );
            }
        }
    }
    unoffered
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(file: &str, priority: i64) -> Candidate {
        Candidate {
            file: file.into(),
            priority,
            expires_at: 0,
        }
    }

    fn h(e: Eligibility, remaining: Option<f64>, reset: Option<i64>) -> Health {
        Health {
            eligibility: e,
            gemini_remaining: remaining,
            gemini_reset: reset,
            claude_remaining: None,
            claude_reset: None,
            refused_until: None,
        }
    }

    #[test]
    fn login_without_the_model_in_its_own_catalog_lacks_it() {
        use crate::model_catalog::{Completeness, DiscoveryState, Observation, Success};
        let obs = |connection: &str, models: &[&str], completeness| Observation {
            connection: connection.into(),
            provider_id: "antigravity".into(),
            access_profile: "oauth".into(),
            exportable: false,
            checked_at: chrono::Utc::now(),
            status: "discovered".into(),
            diagnostic: None,
            last_success: Some(Success {
                observed_at: chrono::Utc::now(),
                completeness,
                models: models
                    .iter()
                    .map(|id| crate::api::providers::ProviderModel {
                        id: (*id).into(),
                        name: (*id).into(),
                        description: None,
                    })
                    .collect(),
            }),
            fallback_models: vec![],
        };
        let state = DiscoveryState {
            connections: vec![
                obs("new", &["claude-opus-5-5-high"], Completeness::Complete),
                obs("old", &["claude-opus-4-6-thinking"], Completeness::Complete),
                obs("partial", &[], Completeness::Partial),
            ],
            ..Default::default()
        };
        assert!(!connection_lacks(&state, "new", "claude-opus-5-5-high"));
        assert!(connection_lacks(&state, "old", "claude-opus-5-5-high"));
        assert!(!connection_lacks(&state, "partial", "claude-opus-5-5-high"));
        assert!(!connection_lacks(&state, "unknown", "claude-opus-5-5-high"));
        assert_eq!(
            unoffered_in(&state, "antigravity", "claude-opus-5-5-high"),
            Some(false)
        );
    }

    #[test]
    fn user_order_becomes_descending_cli_proxy_priority() {
        assert_eq!(
            (0..3).map(|r| ranked_priority(r, 3)).collect::<Vec<_>>(),
            vec![30, 20, 10]
        );
        let plain = json!({"priority": 100, "email": "a"});
        assert_eq!(with_priority(&plain, 10).unwrap()["priority"], 10);
        assert_eq!(with_priority(&plain, 100), None);
        let demoted = json!({"priority": DEMOTED_PRIORITY, BASE_PRIORITY_KEY: 100});
        let next = with_priority(&demoted, 20).unwrap();
        assert_eq!(next["priority"], DEMOTED_PRIORITY, "demotion is kept");
        assert_eq!(next[BASE_PRIORITY_KEY], 20);
    }

    #[test]
    fn unverified_account_is_never_chosen() {
        let c = [cand("new", 100), cand("old", 10)];
        let mut m = HashMap::new();
        m.insert("new".into(), h(Eligibility::NeedsVerification, None, None));
        assert_eq!(choose(&c, &m, 0).unwrap().file, "old");
        m.insert("old".into(), h(Eligibility::NeedsVerification, None, None));
        assert!(choose(&c, &m, 0).is_none());
    }

    #[test]
    fn priority_wins_then_fails_over_on_exhausted_quota_and_back_after_reset() {
        let c = [cand("old", 10), cand("new", 100)];
        let mut m = HashMap::new();
        assert_eq!(
            choose(&c, &m, 0).unwrap().file,
            "new",
            "unchecked keeps priority"
        );
        m.insert("new".into(), h(Eligibility::Eligible, Some(0.0), Some(500)));
        m.insert("old".into(), h(Eligibility::Eligible, Some(0.4), None));
        assert_eq!(choose(&c, &m, 100).unwrap().file, "old");
        assert_eq!(choose(&c, &m, 500).unwrap().file, "new", "window reset");
    }

    #[test]
    fn a_nearly_spent_or_refused_pool_hands_the_machine_to_the_sibling() {
        // Production 2026-10-25: her3sy kept 0.53 % of its Gemini week and
        // Google refused every native run with "Individual quota reached".
        let c = [cand("her3sy", 100), cand("marchand", 10)];
        let mut m = HashMap::new();
        m.insert(
            "her3sy".into(),
            h(Eligibility::Eligible, Some(0.0053), Some(900)),
        );
        m.insert(
            "marchand".into(),
            h(Eligibility::Eligible, Some(0.98), Some(400)),
        );
        assert_eq!(choose(&c, &m, 0).unwrap().file, "marchand");

        // A spent Claude & GPT pool also gives the sign-in away.
        let mut claude_spent = h(Eligibility::Eligible, Some(1.0), None);
        claude_spent.claude_remaining = Some(0.002);
        claude_spent.claude_reset = Some(900);
        m.insert("her3sy".into(), claude_spent);
        assert_eq!(choose(&c, &m, 0).unwrap().file, "marchand");
        assert_eq!(choose(&c, &m, 900).unwrap().file, "her3sy", "pool reset");

        // A refusal counts whatever the figures say, until its reset.
        let mut refused = h(Eligibility::Eligible, Some(0.6), None);
        refused.refused_until = Some(500);
        m.insert("her3sy".into(), refused);
        assert_eq!(choose(&c, &m, 0).unwrap().file, "marchand");
        assert_eq!(choose(&c, &m, 500).unwrap().file, "her3sy");

        // Both spent: the login back first.
        let mut both = h(Eligibility::Eligible, Some(0.0), Some(300));
        both.refused_until = Some(800);
        m.insert("marchand".into(), both);
        assert_eq!(choose(&c, &m, 0).unwrap().file, "her3sy");
    }

    #[test]
    fn eligibility_refusal_is_recognized() {
        assert!(is_eligibility_refusal("CLI error: Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue."));
        assert!(!is_eligibility_refusal("Eligibility check failed: network"));
        assert!(!is_eligibility_refusal(
            "The model said: CLI error: Eligibility check failed: Your current account is not eligible for Antigravity."
        ));
    }

    #[test]
    fn individual_quota_refusal_is_recognized() {
        let raw = "CLI error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 129h43m31s. (RESOURCE_EXHAUSTED (code 429))";
        assert!(is_individual_quota_refusal(raw));
        assert!(crate::account_limits::is_usage_limit_message(raw));
        assert!(!is_individual_quota_refusal(
            "RESOURCE_EXHAUSTED: please retry in 12s"
        ));
        // The words alone, e.g. echoed by the model, are not a refusal.
        assert!(!is_individual_quota_refusal(
            "The docs say: Individual quota reached. Resets in 2h."
        ));
        let now = chrono::Utc::now();
        let reset =
            crate::account_limits::parse_limit_reset(raw, now, crate::account_limits::Zone::UTC)
                .unwrap();
        assert_eq!((reset - now).num_minutes(), 129 * 60 + 43);
    }

    #[test]
    fn with_no_fully_usable_login_the_one_still_serving_a_pool_wins() {
        // Screenshot 2026-10-26: 1st login spent on both pools, 2nd spent on
        // Gemini only. Claude must keep flowing through the 2nd.
        let c = [cand("first", 20), cand("second", 10)];
        let mut both = h(Eligibility::Eligible, Some(0.0), Some(500));
        both.claude_remaining = Some(0.0);
        both.claude_reset = Some(400);
        let mut gemini_only = h(Eligibility::Eligible, Some(0.0), Some(900));
        gemini_only.claude_remaining = Some(1.0);
        let m = HashMap::from([("first".into(), both), ("second".into(), gemini_only)]);
        let before = crate::provider_health::proxy_shadow_snapshot();
        assert_eq!(choose(&c, &m, 100).unwrap().file, "second");
        let after = crate::provider_health::proxy_shadow_snapshot();
        assert_eq!(after.total_divergences, before.total_divergences);
    }

    #[test]
    fn all_exhausted_picks_the_earliest_reset() {
        let before = crate::provider_health::proxy_shadow_snapshot();
        let c = [cand("a", 100), cand("b", 10)];
        let mut m = HashMap::new();
        m.insert("a".into(), h(Eligibility::Eligible, Some(0.0), Some(900)));
        m.insert("b".into(), h(Eligibility::Eligible, Some(0.0), Some(300)));
        assert_eq!(choose(&c, &m, 0).unwrap().file, "b");
        let after = crate::provider_health::proxy_shadow_snapshot();
        assert!(after.total_steps > before.total_steps);
        assert_eq!(after.total_divergences, 0);
    }

    #[test]
    fn eligibility_reads_validation_required_and_projects() {
        let unverified = json!({"allowedTiers":[{"id":"standard-tier"}],"ineligibleTiers":[{"reasonCode":"VALIDATION_REQUIRED","tierId":"free-tier"}]});
        assert_eq!(eligibility(&unverified), Eligibility::NeedsVerification);
        let ok =
            json!({"currentTier":{"id":"free-tier"},"cloudaicompanionProject":"aicode-consumers"});
        assert_eq!(eligibility(&ok), Eligibility::Eligible);
        assert_eq!(project(&ok).as_deref(), Some("aicode-consumers"));
        assert_eq!(eligibility(&json!({})), Eligibility::Unknown);
    }

    #[test]
    fn gemini_quota_treats_missing_fraction_with_reset_as_empty() {
        let models = json!({"models":{
            "gemini-3.8-flash-tiered":{"quotaInfo":{"resetTime":"2026-10-24T09:51:51Z"}},
            "claude-sonnet-4-6":{"quotaInfo":{"remainingFraction":1,"resetTime":"2026-10-24T09:43:30Z"}}}});
        let (r, at) = gemini_quota(&models);
        assert_eq!(r, Some(0.0));
        assert_eq!(at, Some(1_792_835_511));
        let buckets = json!({"buckets":[
            {"modelId":"gemini-3-flash","remainingFraction":0.5,"resetTime":"2026-10-24T09:51:51Z"},
            {"modelId":"chat_20706","remainingFraction":1},
            {"modelId":"claude-opus-4-6-thinking","remainingFraction":0.0}]});
        assert_eq!(gemini_quota(&buckets).0, Some(0.5));
        assert_eq!(gemini_quota(&json!({})), (None, None));
    }

    #[test]
    fn reconcile_demotes_then_restores_priority_and_fills_project() {
        let start = json!({"type":"antigravity","priority":100});
        let demoted = reconcile_file(&start, Eligibility::NeedsVerification, None).unwrap();
        assert_eq!(demoted["priority"], json!(DEMOTED_PRIORITY));
        assert_eq!(demoted[BASE_PRIORITY_KEY], json!(100));
        assert_eq!(base_priority(&demoted), 100);
        assert!(reconcile_file(&demoted, Eligibility::NeedsVerification, None).is_none());
        assert!(reconcile_file(&demoted, Eligibility::Unknown, None).is_none());
        let restored = reconcile_file(&demoted, Eligibility::Eligible, Some("proj")).unwrap();
        assert_eq!(restored["priority"], json!(100));
        assert_eq!(restored["project_id"], json!("proj"));
        assert!(restored.get(BASE_PRIORITY_KEY).is_none());
        assert!(reconcile_file(&restored, Eligibility::Eligible, Some("other")).is_none());
    }

    #[test]
    fn unoffered_needs_a_complete_catalog_without_the_model() {
        use crate::model_catalog::{Completeness, DiscoveryState};
        let state: DiscoveryState = serde_json::from_value(json!({
            "schema_version": 1,
            "connections": [{
                "connection": "x", "provider_id": "antigravity", "access_profile": "oauth",
                "exportable": false, "checked_at": "2026-10-24T04:39:17Z", "status": "discovered",
                "diagnostic": null,
                "last_success": {"observed_at": "2026-10-24T04:39:17Z", "completeness": "complete",
                    "models": [{"id": "gemini-3.8-flash-high", "name": "Gemini 3.8 Flash"}]}
            }]
        }))
        .unwrap();
        assert_eq!(
            unoffered_in(&state, "antigravity", "gemini-4-argon-high"),
            Some(true)
        );
        assert_eq!(
            unoffered_in(&state, "antigravity", "gemini-3.8-flash-high"),
            Some(false)
        );
        assert_eq!(unoffered_in(&state, "openai", "gpt"), None);
        let mut partial = state.clone();
        partial.connections[0]
            .last_success
            .as_mut()
            .unwrap()
            .completeness = Completeness::Partial;
        assert_eq!(
            unoffered_in(&partial, "antigravity", "gemini-4-argon-high"),
            None
        );
        assert!(!model_unoffered(
            Path::new("/nonexistent/x/model_chains.json"),
            "openai",
            "m"
        ));
    }

    #[test]
    fn write_keeps_private_mode() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("antigravity-a.json");
        std::fs::write(&path, b"{}").unwrap();
        write_auth_file(&path, &json!({"priority":1})).unwrap();
        assert_eq!(read_json(&path).unwrap()["priority"], json!(1));
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
