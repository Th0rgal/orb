//! Reliability knobs and monitoring for the `/v1` LLM router.
//!
//! * Timeouts: how long a stream may sit idle before its first content chunk
//!   (`PROXY_FIRST_TOKEN_TIMEOUT_SECS`, default 45 s) and after it
//!   (`PROXY_STREAM_IDLE_TIMEOUT_SECS`, default 60 s).
//! * Retry before first byte: a stream that errors, stalls or ends empty
//!   before its first content chunk is re-sent to the same entry up to
//!   `PROXY_PRE_FIRST_BYTE_RETRIES` times (default 2) with jittered backoff
//!   (250 ms, then 1 s) before the chain moves on. Nothing is retried once a
//!   byte of content has reached the client.
//! * Outcomes: one [`ProxyOutcomeRecord`] per client request, persisted in the
//!   mission store and summarised by `/api/ai/proxy/health`.
//! * Alerting: a WARN, once per dip, when a provider's 15-minute success rate
//!   falls below 90%.

use crate::api::mission_store::ProxyOutcomeRecord;
use crate::provider_health::CooldownReason;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

fn env_secs(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(default)
}

/// Longest a stream may stay idle before its first content chunk.
pub fn first_token_timeout() -> Duration {
    Duration::from_secs(env_secs("PROXY_FIRST_TOKEN_TIMEOUT_SECS", 45))
}

/// First-token limit for one chain entry. Gemini thinking models can think
/// silently (no chunks at all) for minutes on large prompts, so they get
/// `PROXY_GEMINI_FIRST_TOKEN_TIMEOUT_SECS` (default 90 s: longer than the
/// 45 s default, but under Cloudflare's 100 s origin limit, past which the
/// client gets a 524 and the proxy can no longer fall back). Any upstream
/// chunk — a thought part, a keepalive comment — resets the idle clock, so
/// this only fires on a stream that is truly silent.
pub fn first_token_timeout_for(provider: &str, model: &str) -> Duration {
    let gemini_provider = matches!(provider, "google" | "gemini" | "antigravity");
    if gemini_provider && crate::api::proxy::is_gemini_thinking_model(model) {
        return Duration::from_secs(env_secs("PROXY_GEMINI_FIRST_TOKEN_TIMEOUT_SECS", 90))
            .max(first_token_timeout());
    }
    first_token_timeout()
}

/// Longest a stream may stay idle once content is flowing.
pub fn stream_idle_timeout() -> Duration {
    Duration::from_secs(env_secs("PROXY_STREAM_IDLE_TIMEOUT_SECS", 60))
}

// ─────────────────────────────────────────────────────────────────────────────
// Hedged streams
// ─────────────────────────────────────────────────────────────────────────────

/// Hedging for one chain: after an adaptive delay without a first content
/// chunk, the same request also starts on `target` and the first successful
/// answer wins. Configured only through `PROXY_HEDGE_CHAINS`, because the
/// hedge target may be a different model than the chain's first entry.
#[derive(Debug, Clone, PartialEq)]
pub struct HedgeConfig {
    /// Chain or `provider/model` id the hedge is routed to.
    pub target: String,
    /// Never hedge earlier than this (`PROXY_HEDGE_MIN_SECS`, default 20).
    pub min: Duration,
    /// Always hedge by this point (`PROXY_HEDGE_MAX_SECS`, default 45).
    pub max: Duration,
    /// Latency quantile of the primary's recent first-content times that
    /// sets the delay between `min` and `max` (`PROXY_HEDGE_QUANTILE`, 0.75).
    pub quantile: f64,
    /// How far back latency samples count.
    pub window: Duration,
    /// Below this many samples the delay is `max`.
    pub min_samples: usize,
}

impl HedgeConfig {
    /// Delay before hedging, from recent first-content latencies (ms).
    pub fn delay_for(&self, samples_ms: &[u64]) -> Duration {
        if samples_ms.len() < self.min_samples {
            return self.max;
        }
        crate::api::proxy_timing::percentile(samples_ms, self.quantile)
            .map(Duration::from_millis)
            .unwrap_or(self.max)
            .clamp(self.min, self.max)
    }
}

/// `PROXY_HEDGE_CHAINS`: `chain=target` pairs separated by `;` or `,`,
/// e.g. `builtin/smart=xai/grok-4.7`. Empty or unset: no hedging.
pub fn parse_hedge_rules(raw: &str) -> Vec<(String, String)> {
    raw.split([';', ','])
        .filter_map(|pair| {
            let (chain, target) = pair.split_once('=')?;
            let (chain, target) = (chain.trim(), target.trim());
            (!chain.is_empty() && !target.is_empty() && chain != target)
                .then(|| (chain.to_string(), target.to_string()))
        })
        .collect()
}

pub fn hedge_rules_from_env() -> Vec<(String, String)> {
    std::env::var("PROXY_HEDGE_CHAINS")
        .map(|raw| parse_hedge_rules(&raw))
        .unwrap_or_default()
}

/// Hedge settings for a requested model id. `smart` matches `builtin/smart`
/// the same way the router resolves the alias.
pub fn hedge_config_for(requested: &str, rules: &[(String, String)]) -> Option<HedgeConfig> {
    let (_, target) = rules.iter().find(|(chain, _)| {
        chain == requested || chain.strip_prefix("builtin/") == Some(requested)
    })?;
    let min = Duration::from_secs(env_secs("PROXY_HEDGE_MIN_SECS", 20));
    let max = Duration::from_secs(env_secs("PROXY_HEDGE_MAX_SECS", 45)).max(min);
    let quantile = std::env::var("PROXY_HEDGE_QUANTILE")
        .ok()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|q| (0.0..=1.0).contains(q))
        .unwrap_or(0.75);
    Some(HedgeConfig {
        target: target.clone(),
        min,
        max,
        quantile,
        window: Duration::from_secs(30 * 60),
        min_samples: 20,
    })
}

/// Mid-stream idle limit for one provider/model.
///
/// Base: `PROXY_STREAM_IDLE_TIMEOUT_SECS_<PROVIDER>` (e.g. `_XAI`, `_GOOGLE`),
/// else `PROXY_STREAM_IDLE_TIMEOUT_SECS` (60 s). Adaptive: 1.5x the p95 of
/// the longest upstream silences seen in recent healthy streams of the same
/// model (a model that routinely pauses 70 s while it reasons or composes a
/// large tool call is not dead at 60 s). Never above
/// `PROXY_STREAM_IDLE_CEILING_SECS` (110 s: below the 120 s harness text-idle
/// limit), never below the base. Idleness is measured on raw upstream bytes,
/// so keepalive comments and thought chunks count as activity.
pub fn stream_idle_timeout_for(provider: &str, recent_max_gaps_ms: &[u64]) -> Duration {
    let key = format!(
        "PROXY_STREAM_IDLE_TIMEOUT_SECS_{}",
        provider
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            })
            .collect::<String>()
    );
    let base = std::env::var(&key)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v > 0)
        .map(Duration::from_secs)
        .unwrap_or_else(stream_idle_timeout);
    let ceiling = Duration::from_secs(env_secs("PROXY_STREAM_IDLE_CEILING_SECS", 110)).max(base);
    adaptive_idle(base, ceiling, recent_max_gaps_ms)
}

/// Pure part of [`stream_idle_timeout_for`]: needs 20 samples to adapt.
pub fn adaptive_idle(base: Duration, ceiling: Duration, recent_max_gaps_ms: &[u64]) -> Duration {
    if recent_max_gaps_ms.len() < 20 {
        return base;
    }
    let p95 = crate::api::proxy_timing::percentile(recent_max_gaps_ms, 0.95).unwrap_or(0);
    Duration::from_millis(p95.saturating_mul(3) / 2).clamp(base, ceiling)
}

/// Interval of SSE keepalive comments toward the client during silences
/// (`PROXY_SSE_KEEPALIVE_SECS`, default 15 s; well under Cloudflare's 100 s
/// and typical client read timeouts).
pub fn sse_keepalive_interval() -> Duration {
    Duration::from_secs(env_secs("PROXY_SSE_KEEPALIVE_SECS", 15))
}

/// Transparent re-routes of a stream that stalls before any content or tool
/// call reached the client (`PROXY_MID_STREAM_STALL_RETRIES`, default 2: the
/// same entry once, then the chain without the stalled entry).
pub fn mid_stream_stall_retries() -> u32 {
    std::env::var("PROXY_MID_STREAM_STALL_RETRIES")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok())
        .unwrap_or(2)
        .min(4)
}

/// Same-entry retries before the first content chunk.
#[derive(Debug, Clone)]
pub struct RetryPolicy {
    /// Backoff before retry `n` (0-based); its length is the retry budget.
    pub delays: Vec<Duration>,
    /// Jitter as a fraction of each delay (0.2 = ±20%).
    pub jitter: f64,
}

impl RetryPolicy {
    pub fn from_env() -> Self {
        let retries = std::env::var("PROXY_PRE_FIRST_BYTE_RETRIES")
            .ok()
            .and_then(|v| v.trim().parse::<usize>().ok())
            .unwrap_or(2)
            .min(5);
        let ladder = [250u64, 1000, 2000, 4000, 8000];
        Self {
            delays: ladder[..retries]
                .iter()
                .map(|ms| Duration::from_millis(*ms))
                .collect(),
            jitter: 0.2,
        }
    }

    /// No waiting: for tests.
    #[cfg(test)]
    pub fn immediate(retries: usize) -> Self {
        Self {
            delays: vec![Duration::ZERO; retries],
            jitter: 0.0,
        }
    }

    #[cfg(test)]
    pub fn max_retries(&self) -> u32 {
        self.delays.len() as u32
    }

    /// Backoff before retry `retry` (0-based), or `None` when the failure is
    /// not worth retrying on the same entry or the budget is spent. Only
    /// transient failures retry: a 402/401/429 answer would just repeat.
    pub fn delay(&self, retry: u32, reason: CooldownReason) -> Option<Duration> {
        if !is_retryable_before_first_byte(reason) {
            return None;
        }
        let base = *self.delays.get(retry as usize)?;
        if self.jitter <= 0.0 || base.is_zero() {
            return Some(base);
        }
        let spread = (rand::random::<f64>() * 2.0 - 1.0) * self.jitter;
        Some(base.mul_f64((1.0 + spread).max(0.0)))
    }
}

pub fn is_retryable_before_first_byte(reason: CooldownReason) -> bool {
    matches!(
        reason,
        CooldownReason::ServerError | CooldownReason::Timeout | CooldownReason::Overloaded
    )
}

/// How a routed request ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OutcomeStatus {
    Ok,
    ClientError,
    ServerError,
    Timeout,
    EmptyBeforeFirstChunk,
    Stalled,
}

impl OutcomeStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::ClientError => "client_error",
            Self::ServerError => "server_error",
            Self::Timeout => "timeout",
            Self::EmptyBeforeFirstChunk => "empty_before_first_chunk",
            Self::Stalled => "stalled",
        }
    }

    /// Outcome of a failed attempt that got an upstream HTTP status.
    pub fn from_http(code: u16) -> Self {
        if (400..500).contains(&code) {
            Self::ClientError
        } else {
            Self::ServerError
        }
    }
}

/// Error-breakdown key: `client_error:402`, `timeout`, ….
pub fn error_key(record: &ProxyOutcomeRecord) -> String {
    match (record.status.as_str(), record.http_status) {
        ("client_error", Some(code)) | ("server_error", Some(code)) => {
            format!("{}:{}", record.status, code)
        }
        (status, _) => status.to_string(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 15-minute success-rate alert
// ─────────────────────────────────────────────────────────────────────────────

const ALERT_WINDOW: Duration = Duration::from_secs(15 * 60);
const ALERT_THRESHOLD: f64 = 0.90;
/// Fewer requests than this in the window never alert (one failure out of
/// three is noise, not an outage).
const ALERT_MIN_REQUESTS: usize = 10;

#[derive(Default)]
struct ProviderWindow {
    samples: VecDeque<(Instant, bool)>,
    alerting: bool,
}

/// Sliding per-provider success rate that logs a WARN once when it drops
/// below 90% and re-arms when it recovers.
#[derive(Default)]
pub struct SuccessRateMonitor {
    providers: Mutex<HashMap<String, ProviderWindow>>,
}

impl SuccessRateMonitor {
    /// Record one outcome. Returns the success rate when this call crossed
    /// below the threshold (i.e. when it logged the WARN).
    pub fn observe(&self, provider: &str, ok: bool, now: Instant) -> Option<f64> {
        let mut providers = self.providers.lock().unwrap_or_else(|e| e.into_inner());
        let window = providers.entry(provider.to_string()).or_default();
        window.samples.push_back((now, ok));
        while window
            .samples
            .front()
            .is_some_and(|(at, _)| now.duration_since(*at) > ALERT_WINDOW)
        {
            window.samples.pop_front();
        }
        let total = window.samples.len();
        if total < ALERT_MIN_REQUESTS {
            return None;
        }
        let rate = window.samples.iter().filter(|(_, ok)| *ok).count() as f64 / total as f64;
        if rate < ALERT_THRESHOLD {
            if !window.alerting {
                window.alerting = true;
                tracing::warn!(
                    provider,
                    success_rate = format!("{:.1}%", rate * 100.0),
                    requests = total,
                    window_mins = ALERT_WINDOW.as_secs() / 60,
                    "Proxy provider success rate below 90% over the last 15 minutes"
                );
                return Some(rate);
            }
        } else {
            window.alerting = false;
        }
        None
    }
}

pub fn monitor() -> &'static SuccessRateMonitor {
    static MONITOR: std::sync::OnceLock<SuccessRateMonitor> = std::sync::OnceLock::new();
    MONITOR.get_or_init(SuccessRateMonitor::default)
}

// ─────────────────────────────────────────────────────────────────────────────
// /api/ai/proxy/health
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct ReliabilityStats {
    pub requests: u64,
    pub ok: u64,
    /// `ok / requests`, 0..=1. `None` without requests.
    pub success_rate: Option<f64>,
    pub ttft_p50_ms: Option<u64>,
    pub ttft_p95_ms: Option<u64>,
    pub latency_p50_ms: Option<u64>,
    pub latency_p95_ms: Option<u64>,
    /// Requests that needed at least one same-entry retry.
    pub retried: u64,
    /// Requests answered by a later chain entry than the first.
    pub fell_back: u64,
    /// Failure counts keyed by [`error_key`].
    pub errors: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ReliabilityGroup {
    pub provider: Option<String>,
    pub model: Option<String>,
    pub account_id: Option<uuid::Uuid>,
    #[serde(flatten)]
    pub stats: ReliabilityStats,
    /// Red flags for the UI: `low_success_rate`, `out_of_credit`,
    /// `auth_failed`, `slow_first_token`, `stalls`.
    pub flags: Vec<&'static str>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ProxyHealthResponse {
    pub window: String,
    pub since: Option<String>,
    pub totals: ReliabilityStats,
    /// One row per provider/model/account, worst success rate first.
    pub groups: Vec<ReliabilityGroup>,
    /// Per chain (e.g. `builtin/smart`), worst success rate first.
    pub chains: Vec<ChainReliability>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ChainReliability {
    pub chain_id: String,
    #[serde(flatten)]
    pub stats: ReliabilityStats,
}

fn percentile(sorted: &[u64], p: f64) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
    Some(sorted[rank - 1])
}

fn stats<'a>(records: impl Iterator<Item = &'a ProxyOutcomeRecord>) -> ReliabilityStats {
    let mut out = ReliabilityStats::default();
    let mut ttft = Vec::new();
    let mut latency = Vec::new();
    for r in records {
        out.requests += 1;
        if r.status == "ok" {
            out.ok += 1;
            latency.push(r.total_ms);
        } else {
            *out.errors.entry(error_key(r)).or_default() += 1;
        }
        if let Some(t) = r.ttft_ms {
            ttft.push(t);
        }
        if r.retries > 0 {
            out.retried += 1;
        }
        if r.status == "ok" && r.fallback_depth > 0 {
            out.fell_back += 1;
        }
    }
    ttft.sort_unstable();
    latency.sort_unstable();
    out.success_rate = (out.requests > 0).then(|| out.ok as f64 / out.requests as f64);
    out.ttft_p50_ms = percentile(&ttft, 0.50);
    out.ttft_p95_ms = percentile(&ttft, 0.95);
    out.latency_p50_ms = percentile(&latency, 0.50);
    out.latency_p95_ms = percentile(&latency, 0.95);
    out
}

/// Success rate under which a group is flagged (with enough traffic).
const FLAG_SUCCESS_RATE: f64 = 0.90;
const FLAG_MIN_REQUESTS: u64 = 5;
/// p95 time to first token above which a group is flagged as slow.
const FLAG_SLOW_TTFT_MS: u64 = 30_000;

fn flags(stats: &ReliabilityStats) -> Vec<&'static str> {
    let mut flags = Vec::new();
    if stats.requests >= FLAG_MIN_REQUESTS
        && stats.success_rate.is_some_and(|r| r < FLAG_SUCCESS_RATE)
    {
        flags.push("low_success_rate");
    }
    if stats.errors.contains_key("client_error:402") {
        flags.push("out_of_credit");
    }
    if stats.errors.contains_key("client_error:401")
        || stats.errors.contains_key("client_error:403")
    {
        flags.push("auth_failed");
    }
    if stats.ttft_p95_ms.is_some_and(|t| t > FLAG_SLOW_TTFT_MS) {
        flags.push("slow_first_token");
    }
    if stats.errors.contains_key("stalled") {
        flags.push("stalls");
    }
    flags
}

fn worst_first(a: Option<f64>, b: Option<f64>) -> std::cmp::Ordering {
    a.unwrap_or(1.0)
        .partial_cmp(&b.unwrap_or(1.0))
        .unwrap_or(std::cmp::Ordering::Equal)
}

pub fn summarize(
    records: &[ProxyOutcomeRecord],
    window: &str,
    since: Option<String>,
) -> ProxyHealthResponse {
    type Key = (Option<String>, Option<String>, Option<uuid::Uuid>);
    let mut by_group: BTreeMap<Key, Vec<&ProxyOutcomeRecord>> = BTreeMap::new();
    let mut by_chain: BTreeMap<&str, Vec<&ProxyOutcomeRecord>> = BTreeMap::new();
    for r in records {
        // Every attempt counts for the provider that served (or failed) it…
        by_group
            .entry((r.provider.clone(), r.model.clone(), r.account_id))
            .or_default()
            .push(r);
        // …but a request counts once for its chain and the totals.
        if !r.superseded {
            by_chain.entry(r.chain_id.as_str()).or_default().push(r);
        }
    }
    let mut groups: Vec<ReliabilityGroup> = by_group
        .into_iter()
        .map(|((provider, model, account_id), rows)| {
            let stats = stats(rows.into_iter());
            ReliabilityGroup {
                provider,
                model,
                account_id,
                flags: flags(&stats),
                stats,
            }
        })
        .collect();
    groups.sort_by(|a, b| {
        worst_first(a.stats.success_rate, b.stats.success_rate)
            .then(b.stats.requests.cmp(&a.stats.requests))
    });
    let mut chains: Vec<ChainReliability> = by_chain
        .into_iter()
        .map(|(chain_id, rows)| ChainReliability {
            chain_id: chain_id.to_string(),
            stats: stats(rows.into_iter()),
        })
        .collect();
    chains.sort_by(|a, b| {
        worst_first(a.stats.success_rate, b.stats.success_rate)
            .then(b.stats.requests.cmp(&a.stats.requests))
    });
    ProxyHealthResponse {
        window: window.to_string(),
        since,
        totals: stats(records.iter().filter(|r| !r.superseded)),
        groups,
        chains,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(
        provider: &str,
        status: &str,
        http: Option<u16>,
        ttft: Option<u64>,
    ) -> ProxyOutcomeRecord {
        ProxyOutcomeRecord {
            timestamp: "2026-10-20T00:00:00Z".into(),
            chain_id: "builtin/smart".into(),
            provider: Some(provider.into()),
            model: Some("m".into()),
            status: status.into(),
            http_status: http,
            ttft_ms: ttft,
            total_ms: 100,
            ..Default::default()
        }
    }

    #[test]
    fn retry_policy_only_retries_transient_failures_within_budget() {
        let policy = RetryPolicy::from_env();
        assert_eq!(policy.max_retries(), 2);
        let first = policy.delay(0, CooldownReason::ServerError).unwrap();
        assert!(first >= Duration::from_millis(200) && first <= Duration::from_millis(300));
        let second = policy.delay(1, CooldownReason::Timeout).unwrap();
        assert!(second >= Duration::from_millis(800) && second <= Duration::from_millis(1200));
        assert!(policy.delay(2, CooldownReason::ServerError).is_none());
        for reason in [
            CooldownReason::PaymentRequired,
            CooldownReason::AuthError,
            CooldownReason::RateLimit,
            CooldownReason::QuotaExhausted,
            CooldownReason::ClientError,
        ] {
            assert!(policy.delay(0, reason).is_none(), "{reason}");
        }
    }

    #[test]
    fn gemini_thinking_models_get_a_longer_first_token_limit() {
        assert_eq!(
            first_token_timeout_for("google", "gemini-4-argon-eap").as_secs(),
            90
        );
        assert_eq!(
            first_token_timeout_for("antigravity", "gemini-4-argon-high").as_secs(),
            90
        );
        assert_eq!(first_token_timeout_for("zai", "glm-5.3").as_secs(), 45);
        assert_eq!(
            first_token_timeout_for("google", "gemini-1.5-flash").as_secs(),
            45
        );
    }

    #[test]
    fn monitor_warns_once_per_dip_and_rearms_on_recovery() {
        let m = SuccessRateMonitor::default();
        let t = Instant::now();
        for _ in 0..8 {
            assert!(m.observe("minimax", true, t).is_none());
        }
        // 8/10 ok = 80% → crosses on the 10th sample, once.
        assert!(m.observe("minimax", false, t).is_none()); // 9 samples: below minimum
        assert!(m.observe("minimax", false, t).is_some());
        assert!(m.observe("minimax", false, t).is_none());
        for _ in 0..40 {
            m.observe("minimax", true, t);
        }
        // Recovered above 90%: the next dip warns again.
        let mut warned = false;
        for _ in 0..10 {
            warned |= m.observe("minimax", false, t).is_some();
        }
        assert!(warned);
        // Old samples leave the window.
        assert!(m
            .observe("minimax", true, t + Duration::from_secs(16 * 60))
            .is_none());
    }

    #[test]
    fn summarize_computes_rates_percentiles_and_flags() {
        let mut rows = Vec::new();
        for i in 0..8 {
            rows.push(rec("google", "ok", Some(200), Some(1000 + i * 100)));
        }
        rows.push(rec("google", "empty_before_first_chunk", Some(200), None));
        rows.push(rec("google", "stalled", Some(200), Some(40_000)));
        for _ in 0..5 {
            let mut attempt = rec("minimax", "client_error", Some(402), None);
            attempt.superseded = true;
            rows.push(attempt);
        }
        let health = summarize(&rows, "24h", None);
        // Superseded attempts count for MiniMax but not as requests.
        assert_eq!(health.totals.requests, 10);
        assert_eq!(health.totals.ok, 8);
        let minimax = &health.groups[0];
        assert_eq!(minimax.provider.as_deref(), Some("minimax"));
        assert_eq!(minimax.stats.success_rate, Some(0.0));
        assert_eq!(minimax.stats.errors["client_error:402"], 5);
        assert!(minimax.flags.contains(&"out_of_credit"));
        assert!(minimax.flags.contains(&"low_success_rate"));
        let google = &health.groups[1];
        assert_eq!(google.stats.success_rate, Some(0.8));
        assert_eq!(google.stats.ttft_p50_ms, Some(1400));
        assert_eq!(google.stats.ttft_p95_ms, Some(40_000));
        assert_eq!(google.stats.errors["empty_before_first_chunk"], 1);
        assert!(google.flags.contains(&"stalls"));
        assert!(google.flags.contains(&"slow_first_token"));
        assert_eq!(health.chains[0].chain_id, "builtin/smart");
    }

    #[test]
    fn hedge_rules_parse_and_match_alias() {
        let rules = parse_hedge_rules(" builtin/smart = xai/grok-4.7 ; bad ; x=x ; a=b");
        assert_eq!(
            rules,
            vec![
                ("builtin/smart".to_string(), "xai/grok-4.7".to_string()),
                ("a".to_string(), "b".to_string())
            ]
        );
        assert_eq!(
            hedge_config_for("smart", &rules).map(|c| c.target),
            Some("xai/grok-4.7".to_string())
        );
        assert!(hedge_config_for("builtin/smart", &rules).is_some());
        assert!(hedge_config_for("builtin/fast", &rules).is_none());
        assert!(hedge_config_for("smart", &[]).is_none());
    }

    #[test]
    fn hedge_delay_is_adaptive_and_clamped() {
        let cfg = HedgeConfig {
            target: "t".into(),
            min: Duration::from_secs(20),
            max: Duration::from_secs(45),
            quantile: 0.75,
            window: Duration::from_secs(60),
            min_samples: 4,
        };
        // Too few samples: wait the maximum.
        assert_eq!(cfg.delay_for(&[1_000]), Duration::from_secs(45));
        // Fast provider: floor.
        assert_eq!(
            cfg.delay_for(&[1_000, 2_000, 3_000, 4_000]),
            Duration::from_secs(20)
        );
        // p75 inside the band.
        assert_eq!(
            cfg.delay_for(&[10_000, 20_000, 30_000, 40_000]),
            Duration::from_secs(30)
        );
        // Slow provider: ceiling.
        assert_eq!(cfg.delay_for(&[90_000; 8]), Duration::from_secs(45));
    }

    #[test]
    fn idle_limit_adapts_to_observed_pauses_within_bounds() {
        let base = Duration::from_secs(60);
        let ceiling = Duration::from_secs(110);
        // Too few samples: the base.
        assert_eq!(adaptive_idle(base, ceiling, &[90_000; 5]), base);
        // Short pauses never lower the base.
        assert_eq!(adaptive_idle(base, ceiling, &[2_000; 40]), base);
        // 60 s pauses seen: 1.5x = 90 s.
        assert_eq!(
            adaptive_idle(base, ceiling, &[60_000; 40]),
            Duration::from_secs(90)
        );
        // Huge pauses: capped at the ceiling.
        assert_eq!(adaptive_idle(base, ceiling, &[600_000; 40]), ceiling);
    }
}
