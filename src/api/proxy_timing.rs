//! Per-request timing for the `/v1` LLM router.
//!
//! Every routed chat completion gets one [`TimingCell`]. The router fills it
//! as the request moves through the chain (queue wait, each upstream attempt,
//! time to headers and to first content, failure reasons, tokens) and the
//! cell emits one structured `proxy_timing` log line when the last reference
//! drops, which is when the client body has been fully sent or the client
//! went away. Finished records also land in a bounded in-memory ring that
//! `GET /api/ai/proxy/timing` summarises (p50/p90 per provider/model) and that
//! a periodic `proxy_timing_summary` log line reports every few minutes.
//!
//! Privacy: nothing here stores prompt or completion text, headers, URLs with
//! keys, or upstream error bodies. Prompt shape is reduced to byte/message
//! counts and a keyed, process-local 32-bit fingerprint of the system prompt
//! plus tool schema, used only to tell whether a conversation's cacheable
//! prefix stays stable between turns. The mission id comes from the
//! router's authenticated attribution, never from a raw client header.

use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

/// Finished records kept for the summary endpoint.
const RING_CAPACITY: usize = 5_000;

tokio::task_local! {
    static CURRENT: Arc<TimingCell>;
}

/// The cell of the routed request running on this task, if any.
pub fn current() -> Option<Arc<TimingCell>> {
    CURRENT.try_with(Arc::clone).ok()
}

/// Run `fut` with `cell` as the task's current timing cell.
pub async fn scope<F: std::future::Future>(cell: Arc<TimingCell>, fut: F) -> F::Output {
    CURRENT.scope(cell, fut).await
}

/// Whether a request was the primary or the hedge of a hedged pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HedgeRole {
    Primary,
    Hedge,
}

impl HedgeRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Primary => "primary",
            Self::Hedge => "hedge",
        }
    }
}

/// One upstream attempt (one chain entry; same-entry retries fold in).
#[derive(Debug, Clone, Default, Serialize)]
pub struct Attempt {
    pub provider: String,
    pub model: String,
    pub account_id: String,
    /// Requests already in flight to this provider / account when it started.
    pub inflight_provider: i64,
    pub inflight_account: i64,
    /// Offset of the attempt from the request start.
    pub start_ms: u64,
    pub headers_ms: Option<u64>,
    pub first_content_ms: Option<u64>,
    pub http_status: Option<u16>,
    pub http_version: Option<&'static str>,
    /// Failure reasons in order (cooldown reason names, `timeout`, …).
    pub failures: Vec<String>,
    /// Upstream byte chunks received and the longest silence between two
    /// of them after the first (raw transport bytes: keepalive comments and
    /// thought chunks count, whatever the translator later drops).
    pub upstream_chunks: u64,
    pub max_upstream_gap_ms: u64,
    /// Upstream gaps longer than 10 s / 30 s.
    pub upstream_gaps_over_10s: u32,
    pub upstream_gaps_over_30s: u32,
}

/// Request shape, no content.
#[derive(Debug, Clone, Default, Serialize)]
pub struct RequestShape {
    pub prompt_bytes: usize,
    pub messages: usize,
    pub tools: usize,
    pub max_tokens: Option<u64>,
    pub reasoning_effort: Option<String>,
    /// Keyed fingerprint of system prompt + tool schema (8 hex chars).
    pub prefix_fp: Option<String>,
}

/// Everything known about one routed request.
#[derive(Debug, Clone, Default, Serialize)]
pub struct TimingRecord {
    pub chain: String,
    pub stream: bool,
    pub mission_id: Option<uuid::Uuid>,
    /// Name of the authenticated proxy key (`internal` for the core secret).
    pub caller: Option<String>,
    /// Closed-enum caller kind (`usage_attribution::CallerKind`); empty only
    /// before attribution ran.
    pub caller_kind: &'static str,
    /// `core` calls only: the purpose (`mission_title`, `unspecified`, ...).
    pub purpose: Option<String>,
    pub hedge: Option<HedgeRole>,
    pub shape: RequestShape,
    pub queue_wait_ms: u64,
    pub attempts: Vec<Attempt>,
    pub total_ms: u64,
    /// `ok`, `error`, `client_disconnect`, `hedge_cancelled`.
    pub outcome: String,
    pub http_status: Option<u16>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub reasoning_tokens: u64,
    /// Longest silence between two chunks sent to the client.
    pub max_client_gap_ms: u64,
    /// Keepalive comments sent to the client during silences.
    pub keepalives: u32,
    /// Mid-stream stalls recovered by re-routing before content was sent.
    pub transparent_retries: u32,
}

impl TimingRecord {
    /// The attempt that produced content, else the last one.
    pub fn deciding_attempt(&self) -> Option<&Attempt> {
        self.attempts
            .iter()
            .rev()
            .find(|a| a.first_content_ms.is_some())
            .or_else(|| self.attempts.last())
    }
}

/// Client-supplied identifiers (the requested model id) go into a
/// key=value log line: keep a conservative charset and length so a caller
/// cannot forge fields or lines.
pub fn log_safe(value: &str) -> String {
    value
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | ':' | '-' | '@'))
        .take(96)
        .collect()
}

struct InflightGuard {
    keys: [String; 2],
}

impl Drop for InflightGuard {
    fn drop(&mut self) {
        let mut map = REGISTRY.inflight.lock().unwrap_or_else(|e| e.into_inner());
        for key in &self.keys {
            if let Some(v) = map.get_mut(key) {
                *v -= 1;
                if *v <= 0 {
                    map.remove(key);
                }
            }
        }
    }
}

struct CellState {
    record: TimingRecord,
    current_attempt: Option<usize>,
    attempt_started: Option<Instant>,
    inflight: Option<InflightGuard>,
    body_finished: bool,
    cancelled: bool,
    upstream_failed: Option<&'static str>,
    /// A stall the client wrapper has not looked at yet.
    pending_stall: bool,
    last_upstream: Option<tokio::time::Instant>,
}

/// Mutable timing state of one request. Emits on drop.
pub struct TimingCell {
    started: Instant,
    state: Mutex<CellState>,
}

impl TimingCell {
    pub fn new(chain: &str, stream: bool) -> Arc<Self> {
        Arc::new(Self {
            started: Instant::now(),
            state: Mutex::new(CellState {
                record: TimingRecord {
                    chain: log_safe(chain),
                    stream,
                    ..Default::default()
                },
                current_attempt: None,
                attempt_started: None,
                inflight: None,
                body_finished: false,
                cancelled: false,
                upstream_failed: None,
                pending_stall: false,
                last_upstream: None,
            }),
        })
    }

    fn with<R>(&self, f: impl FnOnce(&mut CellState) -> R) -> R {
        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard)
    }

    fn elapsed_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    pub fn set_request(
        &self,
        chain: &str,
        mission_id: Option<uuid::Uuid>,
        caller: Option<String>,
        shape: RequestShape,
    ) {
        self.with(|s| {
            s.record.chain = log_safe(chain);
            s.record.mission_id = mission_id;
            s.record.caller = caller.as_deref().map(log_safe);
            s.record.shape = shape;
        });
    }

    /// Authenticated attribution only (see `proxy::attribution_from`).
    pub fn set_attribution(&self, attribution: &crate::api::proxy::UsageAttribution) {
        let caller = match (&attribution.api_key_name, attribution.caller_kind) {
            (Some(name), _) => Some(log_safe(name)),
            (None, crate::api::usage_attribution::CallerKind::Unknown) => None,
            (None, _) => Some("internal".to_string()),
        };
        self.with(|s| {
            s.record.mission_id = attribution.mission_id;
            s.record.caller = caller;
            s.record.caller_kind = attribution.caller_kind.as_str();
            s.record.purpose = attribution.purpose.as_deref().map(log_safe);
        });
    }

    /// Raw upstream bytes arrived for the current attempt.
    pub fn upstream_activity(&self) {
        let now = tokio::time::Instant::now();
        self.note_mission_liveness();
        self.with(|s| {
            let gap = s
                .last_upstream
                .map(|t| now.duration_since(t).as_millis() as u64);
            s.last_upstream = Some(now);
            if let Some(a) = s.current_attempt.and_then(|i| s.record.attempts.get_mut(i)) {
                a.upstream_chunks += 1;
                if let Some(gap) = gap {
                    a.max_upstream_gap_ms = a.max_upstream_gap_ms.max(gap);
                    if gap > 10_000 {
                        a.upstream_gaps_over_10s += 1;
                    }
                    if gap > 30_000 {
                        a.upstream_gaps_over_30s += 1;
                    }
                }
            }
        });
    }

    /// The router is still legitimately waiting on this request: keep the
    /// mission's proxy liveness fresh so harness idle watchdogs agree with
    /// the router's own idle limit. Authenticated attribution only.
    pub fn note_mission_liveness(&self) {
        if let Some(mission) = self.with(|s| s.record.mission_id) {
            crate::api::proxy_liveness::note_activity(mission);
        }
    }

    /// Time since the current attempt last received upstream bytes.
    pub fn upstream_idle(&self) -> Option<Duration> {
        self.with(|s| s.last_upstream.map(|t| t.elapsed()))
    }

    /// Provider, model and account of the attempt in progress.
    pub fn current_entry(&self) -> Option<(String, String, String)> {
        self.with(|s| {
            s.current_attempt
                .and_then(|i| s.record.attempts.get(i))
                .map(|a| (a.provider.clone(), a.model.clone(), a.account_id.clone()))
        })
    }

    /// A silence of `gap` toward the client ended (or a keepalive was sent).
    pub fn client_gap(&self, gap: Duration, keepalive: bool) {
        if keepalive {
            self.note_mission_liveness();
        }
        self.with(|s| {
            s.record.max_client_gap_ms = s.record.max_client_gap_ms.max(gap.as_millis() as u64);
            if keepalive {
                s.record.keepalives += 1;
            }
        });
    }

    /// Consume a stall signalled by the upstream stream wrapper.
    pub fn take_stall(&self) -> bool {
        self.with(|s| std::mem::take(&mut s.pending_stall))
    }

    /// A stalled stream is being replaced transparently.
    pub fn note_transparent_retry(&self) {
        self.with(|s| {
            s.record.transparent_retries += 1;
            s.upstream_failed = None;
        });
    }

    /// Provider and model of the attempt in progress.
    pub fn current_target(&self) -> Option<(String, String)> {
        self.with(|s| {
            s.current_attempt
                .and_then(|i| s.record.attempts.get(i))
                .map(|a| (a.provider.clone(), a.model.clone()))
        })
    }

    pub fn set_chain(&self, chain: &str) {
        self.with(|s| s.record.chain = log_safe(chain));
    }

    pub fn set_hedge_role(&self, role: HedgeRole) {
        self.with(|s| s.record.hedge = Some(role));
    }

    pub fn add_queue_wait(&self, wait: Duration) {
        self.with(|s| s.record.queue_wait_ms += wait.as_millis() as u64);
    }

    /// A new upstream attempt begins; also counts it as in flight.
    pub fn attempt_start(&self, provider: &str, model: &str, account_id: uuid::Uuid) {
        // Release the previous attempt first so it is not counted as a
        // concurrent request of this one.
        self.with(|s| s.inflight = None);
        let account = account_id.to_string();
        let keys = [
            format!("provider:{provider}"),
            format!("account:{provider}:{account}"),
        ];
        let (inflight_provider, inflight_account) = {
            let mut map = REGISTRY.inflight.lock().unwrap_or_else(|e| e.into_inner());
            let p = map.entry(keys[0].clone()).or_insert(0);
            let before_p = *p;
            *p += 1;
            let a = map.entry(keys[1].clone()).or_insert(0);
            let before_a = *a;
            *a += 1;
            (before_p, before_a)
        };
        let start_ms = self.elapsed_ms();
        self.with(|s| {
            // Same entry again (pre-first-byte retry): keep one attempt row.
            let same = s
                .current_attempt
                .and_then(|i| s.record.attempts.get(i))
                .is_some_and(|a| {
                    a.provider == provider && a.model == model && a.account_id == account
                });
            // Replacing the guard first releases the previous attempt.
            s.inflight = Some(InflightGuard { keys });
            s.attempt_started = Some(Instant::now());
            s.last_upstream = None;
            if same {
                return;
            }
            s.record.attempts.push(Attempt {
                provider: provider.to_string(),
                model: model.to_string(),
                account_id: account,
                inflight_provider,
                inflight_account,
                start_ms,
                ..Default::default()
            });
            s.current_attempt = Some(s.record.attempts.len() - 1);
        });
    }

    fn attempt_offset(s: &CellState) -> Option<u64> {
        s.attempt_started.map(|t| t.elapsed().as_millis() as u64)
    }

    pub fn attempt_headers(&self, status: u16, version: reqwest::Version) {
        let version = match version {
            reqwest::Version::HTTP_09 => "0.9",
            reqwest::Version::HTTP_10 => "1.0",
            reqwest::Version::HTTP_11 => "1.1",
            reqwest::Version::HTTP_2 => "2",
            reqwest::Version::HTTP_3 => "3",
            _ => "?",
        };
        self.with(|s| {
            let offset = Self::attempt_offset(s);
            if let Some(a) = s.current_attempt.and_then(|i| s.record.attempts.get_mut(i)) {
                a.headers_ms = offset;
                a.http_status = Some(status);
                a.http_version = Some(version);
            }
        });
    }

    /// The current attempt delivered its first content chunk.
    pub fn attempt_first_content(&self) {
        self.with(|s| {
            let offset = Self::attempt_offset(s);
            if let Some(a) = s.current_attempt.and_then(|i| s.record.attempts.get_mut(i)) {
                if a.first_content_ms.is_none() {
                    a.first_content_ms = offset;
                }
            }
        });
    }

    pub fn attempt_failure(&self, reason: &str) {
        self.with(|s| {
            if let Some(a) = s.current_attempt.and_then(|i| s.record.attempts.get_mut(i)) {
                if a.failures.len() < 16 {
                    a.failures.push(reason.to_string());
                }
            }
            // A failed attempt is no longer in flight.
            s.inflight = None;
        });
    }

    pub fn set_response_status(&self, status: u16) {
        self.with(|s| s.record.http_status = Some(status));
    }

    pub fn set_tokens(&self, input: u64, output: u64, cache_read: u64, reasoning: u64) {
        self.with(|s| {
            let r = &mut s.record;
            r.input_tokens = r.input_tokens.max(input);
            r.output_tokens = r.output_tokens.max(output);
            r.cache_read_tokens = r.cache_read_tokens.max(cache_read);
            r.reasoning_tokens = r.reasoning_tokens.max(reasoning);
        });
    }

    /// The response body was sent to the end.
    pub fn body_finished(&self) {
        self.with(|s| s.body_finished = true);
    }

    /// The upstream stream stalled or errored after content started.
    pub fn mark_upstream_stream_failed(&self, reason: &'static str) {
        self.with(|s| {
            if reason == "stalled" {
                s.pending_stall = true;
            }
            s.upstream_failed = Some(reason);
            if let Some(a) = s.current_attempt.and_then(|i| s.record.attempts.get_mut(i)) {
                a.failures.push(reason.to_string());
            }
        });
    }

    /// This request lost a hedge race and was dropped on purpose.
    pub fn mark_cancelled(&self) {
        self.with(|s| s.cancelled = true);
    }

    /// The record as it would be emitted now.
    #[cfg(test)]
    pub fn snapshot(&self) -> TimingRecord {
        self.finish()
    }

    fn finish(&self) -> TimingRecord {
        let total_ms = self.elapsed_ms();
        self.with(|s| {
            s.inflight = None;
            let mut record = s.record.clone();
            record.total_ms = total_ms;
            let success = record.http_status.is_some_and(|c| (200..300).contains(&c));
            record.outcome = if s.cancelled {
                "hedge_cancelled"
            } else if !success {
                "error"
            } else if let Some(reason) = s.upstream_failed {
                reason
            } else if s.body_finished {
                "ok"
            } else {
                "client_disconnect"
            }
            .to_string();
            record
        })
    }
}

impl Drop for TimingCell {
    fn drop(&mut self) {
        let record = self.finish();
        emit(&record);
        REGISTRY.push(record);
    }
}

fn emit(record: &TimingRecord) {
    let deciding = record.deciding_attempt();
    let attempts = record
        .attempts
        .iter()
        .map(|a| {
            let mut s = format!(
                "{}/{}@{}+{}",
                a.provider,
                a.model,
                a.start_ms,
                a.headers_ms.map_or("-".to_string(), |v| v.to_string())
            );
            if let Some(code) = a.http_status {
                s.push_str(&format!(":{code}"));
            }
            if !a.failures.is_empty() {
                s.push_str(&format!("!{}", a.failures.join("|")));
            }
            s
        })
        .collect::<Vec<_>>()
        .join(",");
    tracing::info!(
        target: "sandboxed_sh::proxy_timing",
        chain = %record.chain,
        stream = record.stream,
        mission_id = %record.mission_id.map(|m| m.to_string()).unwrap_or_default(),
        caller = %record.caller.as_deref().unwrap_or(""),
        caller_kind = %record.caller_kind,
        purpose = %record.purpose.as_deref().unwrap_or(""),
        hedge = %record.hedge.map(HedgeRole::as_str).unwrap_or(""),
        provider = %deciding.map(|a| a.provider.as_str()).unwrap_or(""),
        model = %deciding.map(|a| a.model.as_str()).unwrap_or(""),
        outcome = %record.outcome,
        http_status = record.http_status.unwrap_or(0),
        total_ms = record.total_ms,
        queue_wait_ms = record.queue_wait_ms,
        pre_upstream_ms = record.attempts.first().map_or(0, |a| a.start_ms),
        headers_ms = deciding.and_then(|a| a.headers_ms).unwrap_or(0),
        first_content_ms = deciding.and_then(|a| a.first_content_ms).unwrap_or(0),
        http_version = %deciding.and_then(|a| a.http_version).unwrap_or(""),
        inflight_provider = deciding.map_or(0, |a| a.inflight_provider),
        inflight_account = deciding.map_or(0, |a| a.inflight_account),
        n_attempts = record.attempts.len(),
        attempts = %attempts,
        prompt_bytes = record.shape.prompt_bytes,
        messages = record.shape.messages,
        tools = record.shape.tools,
        max_tokens = record.shape.max_tokens.unwrap_or(0),
        reasoning_effort = %record.shape.reasoning_effort.as_deref().unwrap_or(""),
        prefix_fp = %record.shape.prefix_fp.as_deref().unwrap_or(""),
        input_tokens = record.input_tokens,
        output_tokens = record.output_tokens,
        cache_read_tokens = record.cache_read_tokens,
        reasoning_tokens = record.reasoning_tokens,
        max_upstream_gap_ms = deciding.map_or(0, |a| a.max_upstream_gap_ms),
        upstream_gaps_over_30s = deciding.map_or(0, |a| a.upstream_gaps_over_30s),
        upstream_chunks = deciding.map_or(0, |a| a.upstream_chunks),
        max_client_gap_ms = record.max_client_gap_ms,
        keepalives = record.keepalives,
        transparent_retries = record.transparent_retries,
        "proxy_timing"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Registry: in-flight gauges + finished ring
// ─────────────────────────────────────────────────────────────────────────────

struct Registry {
    inflight: Mutex<HashMap<String, i64>>,
    ring: Mutex<VecDeque<(Instant, TimingRecord)>>,
}

static REGISTRY: LazyLock<Registry> = LazyLock::new(|| Registry {
    inflight: Mutex::new(HashMap::new()),
    ring: Mutex::new(VecDeque::with_capacity(RING_CAPACITY)),
});

impl Registry {
    fn push(&self, record: TimingRecord) {
        let mut ring = self.ring.lock().unwrap_or_else(|e| e.into_inner());
        if ring.len() >= RING_CAPACITY {
            ring.pop_front();
        }
        ring.push_back((Instant::now(), record));
    }
}

/// Current in-flight counts (`provider:<id>` and `account:<provider>:<id>`).
pub fn inflight_snapshot() -> HashMap<String, i64> {
    REGISTRY
        .inflight
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// Recent successful first-content latencies (ms) of streams answered by
/// `provider/model`, newest last, within `window`.
pub fn recent_first_content_ms(provider: &str, model: &str, window: Duration) -> Vec<u64> {
    let ring = REGISTRY.ring.lock().unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    ring.iter()
        .filter(|(at, _)| now.duration_since(*at) <= window)
        .flat_map(|(_, r)| r.attempts.iter())
        .filter(|a| a.provider == provider && a.model == model)
        .filter_map(|a| a.first_content_ms)
        .collect()
}

/// Longest upstream gaps (ms) of recent streams on `provider/model` that
/// finished without a stall, newest last, within `window`.
pub fn recent_max_gaps_ms(provider: &str, model: &str, window: Duration) -> Vec<u64> {
    let ring = REGISTRY.ring.lock().unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    ring.iter()
        .filter(|(at, r)| now.duration_since(*at) <= window && r.outcome == "ok")
        .flat_map(|(_, r)| r.attempts.iter())
        .filter(|a| a.provider == provider && a.model == model && a.upstream_chunks > 1)
        .filter(|a| !a.failures.iter().any(|f| f == "stalled"))
        .map(|a| a.max_upstream_gap_ms)
        .collect()
}

/// Nearest-rank percentile of an unsorted sample (`q` in 0..=1).
pub fn percentile(values: &[u64], q: f64) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    let mut v = values.to_vec();
    v.sort_unstable();
    let rank = ((q.clamp(0.0, 1.0) * v.len() as f64).ceil() as usize).clamp(1, v.len());
    Some(v[rank - 1])
}

#[derive(Debug, Default, Serialize, PartialEq)]
pub struct Stat {
    pub n: usize,
    pub p50: Option<u64>,
    pub p90: Option<u64>,
    pub max: Option<u64>,
}

impl Stat {
    fn of(values: &[u64]) -> Self {
        Self {
            n: values.len(),
            p50: percentile(values, 0.5),
            p90: percentile(values, 0.9),
            max: values.iter().copied().max(),
        }
    }
}

#[derive(Debug, Default, Serialize)]
pub struct GroupSummary {
    pub requests: usize,
    pub outcomes: HashMap<String, usize>,
    pub failures: HashMap<String, usize>,
    pub headers_ms: Stat,
    pub first_content_ms: Stat,
    pub total_ms: Stat,
    pub queue_wait_ms: Stat,
    pub pre_upstream_ms: Stat,
    pub input_tokens: Stat,
    pub cache_read_tokens: Stat,
    pub reasoning_tokens: Stat,
    pub inflight_at_start: Stat,
    pub max_upstream_gap_ms: Stat,
    pub max_client_gap_ms: Stat,
    pub hedged: usize,
    pub keepalives: u64,
    pub transparent_retries: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct TimingSummary {
    pub window_secs: u64,
    pub requests: usize,
    /// Keyed by the provider/model that decided the request.
    pub by_model: std::collections::BTreeMap<String, GroupSummary>,
    /// Every attempt, keyed by provider/model (failed attempts included).
    pub attempts_by_model: std::collections::BTreeMap<String, GroupSummary>,
    pub inflight: HashMap<String, i64>,
}

/// Summarise finished records of the last `window`.
pub fn summary(window: Duration) -> TimingSummary {
    let records: Vec<TimingRecord> = {
        let ring = REGISTRY.ring.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        ring.iter()
            .filter(|(at, _)| now.duration_since(*at) <= window)
            .map(|(_, r)| r.clone())
            .collect()
    };
    let mut out = summarize_records(&records);
    out.window_secs = window.as_secs();
    out.inflight = inflight_snapshot();
    out
}

pub fn summarize_records(records: &[TimingRecord]) -> TimingSummary {
    #[derive(Default)]
    struct Acc {
        requests: usize,
        outcomes: HashMap<String, usize>,
        failures: HashMap<String, usize>,
        headers: Vec<u64>,
        first: Vec<u64>,
        total: Vec<u64>,
        queue: Vec<u64>,
        pre: Vec<u64>,
        input: Vec<u64>,
        cache: Vec<u64>,
        reasoning: Vec<u64>,
        inflight: Vec<u64>,
        up_gap: Vec<u64>,
        client_gap: Vec<u64>,
        hedged: usize,
        keepalives: u64,
        retries: u64,
    }
    let finish = |acc: Acc| GroupSummary {
        requests: acc.requests,
        outcomes: acc.outcomes,
        failures: acc.failures,
        headers_ms: Stat::of(&acc.headers),
        first_content_ms: Stat::of(&acc.first),
        total_ms: Stat::of(&acc.total),
        queue_wait_ms: Stat::of(&acc.queue),
        pre_upstream_ms: Stat::of(&acc.pre),
        input_tokens: Stat::of(&acc.input),
        cache_read_tokens: Stat::of(&acc.cache),
        reasoning_tokens: Stat::of(&acc.reasoning),
        inflight_at_start: Stat::of(&acc.inflight),
        max_upstream_gap_ms: Stat::of(&acc.up_gap),
        max_client_gap_ms: Stat::of(&acc.client_gap),
        hedged: acc.hedged,
        keepalives: acc.keepalives,
        transparent_retries: acc.retries,
    };
    let mut by_model: HashMap<String, Acc> = HashMap::new();
    let mut attempts: HashMap<String, Acc> = HashMap::new();
    for r in records {
        for a in &r.attempts {
            let acc = attempts
                .entry(format!("{}/{}", a.provider, a.model))
                .or_default();
            acc.requests += 1;
            let status = if a.first_content_ms.is_some() {
                "content".to_string()
            } else if let Some(f) = a.failures.last() {
                f.clone()
            } else if let Some(code) = a.http_status {
                format!("http_{code}")
            } else {
                "no_headers".to_string()
            };
            *acc.outcomes.entry(status).or_default() += 1;
            for f in &a.failures {
                *acc.failures.entry(f.clone()).or_default() += 1;
            }
            acc.headers.extend(a.headers_ms);
            acc.first.extend(a.first_content_ms);
            acc.inflight.push(a.inflight_provider.max(0) as u64);
            if a.upstream_chunks > 1 {
                acc.up_gap.push(a.max_upstream_gap_ms);
            }
        }
        let key = r
            .deciding_attempt()
            .map(|a| format!("{}/{}", a.provider, a.model))
            .unwrap_or_else(|| format!("{} (no attempt)", r.chain));
        let acc = by_model.entry(key).or_default();
        acc.requests += 1;
        *acc.outcomes.entry(r.outcome.clone()).or_default() += 1;
        if let Some(a) = r.deciding_attempt() {
            acc.headers.extend(a.headers_ms);
            acc.first.extend(a.first_content_ms);
            acc.inflight.push(a.inflight_provider.max(0) as u64);
        }
        acc.total.push(r.total_ms);
        acc.queue.push(r.queue_wait_ms);
        acc.pre.push(r.attempts.first().map_or(0, |a| a.start_ms));
        if r.input_tokens > 0 {
            acc.input.push(r.input_tokens);
            acc.cache.push(r.cache_read_tokens);
            acc.reasoning.push(r.reasoning_tokens);
        }
        if r.hedge.is_some() {
            acc.hedged += 1;
        }
        if r.stream && r.max_client_gap_ms > 0 {
            acc.client_gap.push(r.max_client_gap_ms);
        }
        acc.keepalives += u64::from(r.keepalives);
        acc.retries += u64::from(r.transparent_retries);
    }
    TimingSummary {
        window_secs: 0,
        requests: records.len(),
        by_model: by_model.into_iter().map(|(k, v)| (k, finish(v))).collect(),
        attempts_by_model: attempts.into_iter().map(|(k, v)| (k, finish(v))).collect(),
        inflight: HashMap::new(),
    }
}

/// Log a compact per-model summary every `every` (started once at boot).
pub fn spawn_periodic_summary(every: Duration) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(every);
        tick.tick().await;
        loop {
            tick.tick().await;
            let s = summary(every);
            for (model, g) in &s.by_model {
                tracing::info!(
                    target: "sandboxed_sh::proxy_timing",
                    window_secs = s.window_secs,
                    model = %model,
                    requests = g.requests,
                    headers_p50 = g.headers_ms.p50.unwrap_or(0),
                    headers_p90 = g.headers_ms.p90.unwrap_or(0),
                    first_content_p50 = g.first_content_ms.p50.unwrap_or(0),
                    first_content_p90 = g.first_content_ms.p90.unwrap_or(0),
                    total_p50 = g.total_ms.p50.unwrap_or(0),
                    total_p90 = g.total_ms.p90.unwrap_or(0),
                    queue_wait_p90 = g.queue_wait_ms.p90.unwrap_or(0),
                    input_tokens_p50 = g.input_tokens.p50.unwrap_or(0),
                    inflight_p90 = g.inflight_at_start.p90.unwrap_or(0),
                    hedged = g.hedged,
                    max_upstream_gap_p90 = g.max_upstream_gap_ms.p90.unwrap_or(0),
                    max_client_gap_p90 = g.max_client_gap_ms.p90.unwrap_or(0),
                    keepalives = g.keepalives,
                    transparent_retries = g.transparent_retries,
                    outcomes = %serde_json::to_string(&g.outcomes).unwrap_or_default(),
                    "proxy_timing_summary"
                );
            }
        }
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Request shape
// ─────────────────────────────────────────────────────────────────────────────

static FP_KEY: LazyLock<[u8; 32]> = LazyLock::new(rand::random);

/// Content-free shape of an OpenAI chat body.
pub fn request_shape(body: &[u8], value: Option<&serde_json::Value>) -> RequestShape {
    use hmac::{Mac, SimpleHmac};
    let mut shape = RequestShape {
        prompt_bytes: body.len(),
        ..Default::default()
    };
    let Some(v) = value else {
        return shape;
    };
    let messages = v.get("messages").and_then(|m| m.as_array());
    shape.messages = messages.map_or(0, Vec::len);
    let tools = v.get("tools").and_then(|t| t.as_array());
    shape.tools = tools.map_or(0, Vec::len);
    shape.max_tokens = v
        .get("max_tokens")
        .or_else(|| v.get("max_completion_tokens"))
        .and_then(|m| m.as_u64());
    // Only well-known effort words; anything else is reported as `other` so
    // a client cannot push arbitrary text into the log.
    shape.reasoning_effort = v
        .get("reasoning_effort")
        .or_else(|| v.pointer("/reasoning/effort"))
        .and_then(|e| e.as_str())
        .map(|e| match e {
            "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" => e.to_string(),
            _ => "other".to_string(),
        });
    let Ok(mut mac) = SimpleHmac::<sha2::Sha256>::new_from_slice(&*FP_KEY) else {
        return shape;
    };
    for m in messages.into_iter().flatten() {
        let role = m.get("role").and_then(|r| r.as_str());
        if matches!(role, Some("system") | Some("developer")) {
            mac.update(
                m.get("content")
                    .map(|c| c.to_string())
                    .unwrap_or_default()
                    .as_bytes(),
            );
        }
    }
    if let Some(t) = tools {
        mac.update(serde_json::Value::Array(t.clone()).to_string().as_bytes());
    }
    let digest = mac.finalize().into_bytes();
    shape.prefix_fp = Some(digest[..4].iter().map(|b| format!("{b:02x}")).collect());
    shape
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentile_nearest_rank() {
        assert_eq!(percentile(&[], 0.5), None);
        assert_eq!(percentile(&[5], 0.9), Some(5));
        let v: Vec<u64> = (1..=10).collect();
        assert_eq!(percentile(&v, 0.5), Some(5));
        assert_eq!(percentile(&v, 0.9), Some(9));
        assert_eq!(percentile(&v, 1.0), Some(10));
    }

    #[test]
    fn shape_has_no_content_and_stable_fingerprint() {
        let body = br#"{"model":"m","messages":[{"role":"system","content":"SECRET-SYSTEM"},{"role":"user","content":"SECRET-USER"}],"tools":[{"type":"function","function":{"name":"t"}}],"max_tokens":100,"reasoning_effort":"high"}"#;
        let v: serde_json::Value = serde_json::from_slice(body).unwrap();
        let shape = request_shape(body, Some(&v));
        assert_eq!(shape.messages, 2);
        assert_eq!(shape.tools, 1);
        assert_eq!(shape.max_tokens, Some(100));
        assert_eq!(shape.reasoning_effort.as_deref(), Some("high"));
        let json = serde_json::to_string(&shape).unwrap();
        assert!(!json.contains("SECRET"));
        // Same prefix, different user turn: same fingerprint.
        let body2 = br#"{"model":"m","messages":[{"role":"system","content":"SECRET-SYSTEM"},{"role":"user","content":"other"}],"tools":[{"type":"function","function":{"name":"t"}}]}"#;
        let v2: serde_json::Value = serde_json::from_slice(body2).unwrap();
        assert_eq!(request_shape(body2, Some(&v2)).prefix_fp, shape.prefix_fp);
        // Changed system prompt: different fingerprint.
        let body3 = br#"{"model":"m","messages":[{"role":"system","content":"changed"}]}"#;
        let v3: serde_json::Value = serde_json::from_slice(body3).unwrap();
        assert_ne!(request_shape(body3, Some(&v3)).prefix_fp, shape.prefix_fp);
    }

    #[test]
    fn client_model_ids_cannot_forge_log_fields() {
        let cell = TimingCell::new("smart\nINFO fake=1 outcome=ok", true);
        let chain = cell.snapshot().chain;
        assert_eq!(chain, "smartINFOfake1outcomeok");
        cell.set_request(
            "x".repeat(500).as_str(),
            None,
            Some("key name\r".into()),
            Default::default(),
        );
        let r = cell.snapshot();
        assert_eq!(r.chain.len(), 96);
        assert_eq!(r.caller.as_deref(), Some("keyname"));
    }

    #[test]
    fn unknown_effort_is_not_echoed() {
        let body = br#"{"reasoning_effort":"injected text\nfake=1"}"#;
        let v: serde_json::Value = serde_json::from_slice(body).unwrap();
        assert_eq!(
            request_shape(body, Some(&v)).reasoning_effort.as_deref(),
            Some("other")
        );
    }

    #[tokio::test]
    async fn cell_tracks_attempts_inflight_and_outcome() {
        let provider = format!("test-{}", uuid::Uuid::new_v4());
        let account = uuid::Uuid::new_v4();
        let cell = TimingCell::new("builtin/smart", true);
        scope(cell.clone(), async {
            let c = current().expect("cell in scope");
            c.attempt_start(&provider, "m1", account);
            assert_eq!(
                inflight_snapshot().get(&format!("provider:{provider}")),
                Some(&1)
            );
            c.attempt_failure("timeout");
            assert_eq!(
                inflight_snapshot().get(&format!("provider:{provider}")),
                None
            );
            c.attempt_start(&provider, "m2", account);
            c.attempt_headers(200, reqwest::Version::HTTP_2);
            c.attempt_first_content();
            c.set_response_status(200);
            c.set_tokens(1000, 20, 800, 5);
        })
        .await;
        assert!(current().is_none());
        let record = cell.finish();
        assert_eq!(record.attempts.len(), 2);
        assert_eq!(record.attempts[0].failures, vec!["timeout"]);
        assert_eq!(record.deciding_attempt().unwrap().model, "m2");
        assert_eq!(record.deciding_attempt().unwrap().http_version, Some("2"));
        // Body never finished: the client went away.
        assert_eq!(record.outcome, "client_disconnect");
        cell.body_finished();
        assert_eq!(cell.finish().outcome, "ok");
        cell.mark_upstream_stream_failed("stalled");
        assert_eq!(cell.finish().outcome, "stalled");
        drop(cell);
        assert_eq!(
            inflight_snapshot().get(&format!("provider:{provider}")),
            None
        );
        let fc = recent_first_content_ms(&provider, "m2", Duration::from_secs(60));
        assert_eq!(fc.len(), 1);
    }

    #[test]
    fn keepalives_and_upstream_bytes_keep_mission_liveness_fresh() {
        let mission = uuid::Uuid::new_v4();
        let cell = TimingCell::new("c", true);
        cell.set_attribution(&crate::api::proxy::UsageAttribution {
            mission_id: Some(mission),
            ..Default::default()
        });
        assert!(crate::api::proxy_liveness::time_since_activity(mission).is_none());
        cell.client_gap(Duration::from_secs(15), true);
        assert!(
            crate::api::proxy_liveness::time_since_activity(mission).unwrap()
                < Duration::from_secs(5)
        );
        let other = uuid::Uuid::new_v4();
        let cell = TimingCell::new("c", true);
        cell.set_attribution(&crate::api::proxy::UsageAttribution {
            mission_id: Some(other),
            ..Default::default()
        });
        cell.upstream_activity();
        assert!(crate::api::proxy_liveness::time_since_activity(other).is_some());
    }

    #[test]
    fn next_attempt_does_not_count_its_predecessor_in_flight() {
        let provider = format!("p-{}", uuid::Uuid::new_v4());
        let cell = TimingCell::new("c", true);
        cell.attempt_start(&provider, "m1", uuid::Uuid::new_v4());
        // A 4xx moved the chain on without a recorded failure.
        cell.attempt_start(&provider, "m2", uuid::Uuid::new_v4());
        let r = cell.snapshot();
        assert_eq!(r.attempts[1].inflight_provider, 0);
    }

    #[test]
    fn same_entry_retry_folds_into_one_attempt() {
        let cell = TimingCell::new("c", true);
        let account = uuid::Uuid::new_v4();
        cell.attempt_start("p-fold", "m", account);
        cell.attempt_failure("server_error");
        cell.attempt_start("p-fold", "m", account);
        let r = cell.finish();
        assert_eq!(r.attempts.len(), 1);
        assert_eq!(r.attempts[0].failures, vec!["server_error"]);
        assert_eq!(r.outcome, "error");
    }

    #[test]
    fn summary_groups_by_deciding_model() {
        let mk = |model: &str, first: Option<u64>, failures: Vec<&str>| Attempt {
            provider: "google".into(),
            model: model.into(),
            first_content_ms: first,
            headers_ms: first,
            failures: failures.into_iter().map(String::from).collect(),
            ..Default::default()
        };
        let records = vec![
            TimingRecord {
                attempts: vec![mk("a", Some(100), vec![])],
                outcome: "ok".into(),
                total_ms: 500,
                ..Default::default()
            },
            TimingRecord {
                attempts: vec![mk("a", None, vec!["timeout"]), mk("b", Some(50), vec![])],
                outcome: "ok".into(),
                total_ms: 90_100,
                ..Default::default()
            },
        ];
        let s = summarize_records(&records);
        assert_eq!(s.requests, 2);
        assert_eq!(s.by_model["google/a"].requests, 1);
        assert_eq!(s.by_model["google/b"].total_ms.max, Some(90_100));
        assert_eq!(s.attempts_by_model["google/a"].requests, 2);
        assert_eq!(s.attempts_by_model["google/a"].failures["timeout"], 1);
    }
}
