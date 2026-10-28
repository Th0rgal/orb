//! Mission events, alerts feed and snapshot handlers.

use super::*;

/// Query params for the unified mission events endpoint (P3-#18).
///
/// `GET /api/control/missions/:id/events` is the canonical cursor
/// endpoint for fetching persisted events. With `since_seq=N` it returns
/// events strictly after sequence N. With `before_seq=N` it pages backwards.
/// Use `view=transcript|trace|history|all` or explicit `types=` filters.
#[derive(Debug, Clone, Deserialize)]
pub struct GetEventsQuery {
    /// Comma-separated event types to filter (e.g., "tool_call,tool_result")
    #[serde(default)]
    pub types: Option<String>,
    /// Preset event type view. `transcript` returns user/assistant rows,
    /// `trace` returns intermediate activity, and `all` disables filtering.
    #[serde(default)]
    pub view: Option<String>,
    /// Maximum number of events to return
    #[serde(default)]
    pub limit: Option<usize>,
    /// If set, return only events with `sequence > since_seq`, ordered
    /// by sequence ASC. Used by the client for delta reconnect to
    /// avoid redownloading the full event tail on every focus/reopen.
    #[serde(default)]
    pub since_seq: Option<i64>,
    /// If set, return only events with `sequence < before_seq`, ordered
    /// by sequence ASC (oldest first). Used by the client for backwards
    /// pagination — pass the lowest sequence already seen to fetch the
    /// next page of older events. Takes precedence over `since_seq`
    /// when provided.
    #[serde(default)]
    pub before_seq: Option<i64>,
    /// Whether to include total/count headers. Delta polling only needs
    /// `X-Max-Sequence`; skipping counts avoids an extra indexed DB scan.
    #[serde(default = "default_include_event_counts")]
    pub include_counts: bool,
    /// Optional response profile. `conversation` keeps the recent transcript
    /// hydrated while collapsing older tool payloads into lazy stubs.
    #[serde(default)]
    pub profile: Option<String>,
    /// Number of recent tool call/result pairs to keep fully hydrated for
    /// `profile=conversation`.
    #[serde(default)]
    pub trace_tail: Option<usize>,
    /// Truncate tool call/result payloads larger than this many bytes to
    /// their head and tail, marked `metadata.truncated` with
    /// `metadata.full_bytes`. The full rows come from
    /// `/api/control/missions/:id/tool-calls/:tool_call_id`.
    #[serde(default)]
    pub max_payload: Option<usize>,
}

/// Smallest accepted `max_payload`, so a row always keeps a useful excerpt.
pub(super) const MIN_MAX_PAYLOAD: usize = 1024;

/// Head (three quarters) and tail (one quarter) of `text` in `max` bytes.
fn excerpt(text: &str, max: usize) -> String {
    let mut head = max * 3 / 4;
    while !text.is_char_boundary(head) {
        head -= 1;
    }
    let mut tail = text.len() - (max - head);
    while !text.is_char_boundary(tail) {
        tail += 1;
    }
    format!(
        "{}\n… {} bytes omitted …\n{}",
        &text[..head],
        tail - head,
        &text[tail..]
    )
}

/// Shorten every string longer than `max` inside a JSON value.
fn shorten_strings(value: &mut serde_json::Value, max: usize) {
    match value {
        serde_json::Value::String(text) if text.len() > max => *text = excerpt(text, max),
        serde_json::Value::Array(items) => items.iter_mut().for_each(|v| shorten_strings(v, max)),
        serde_json::Value::Object(map) => map.values_mut().for_each(|v| shorten_strings(v, max)),
        _ => {}
    }
}

/// Shorten tool payloads larger than `max` bytes. JSON keeps its shape (each
/// long string keeps its head and tail), so args still name their target;
/// other text keeps its head and tail. Interactive UI tools stay whole.
pub(super) fn truncate_tool_payloads(events: &mut [mission_store::StoredEvent], max: usize) {
    let max = max.max(MIN_MAX_PAYLOAD);
    for event in events {
        if !matches!(event.event_type.as_str(), "tool_call" | "tool_result")
            || event.content.len() <= max
            || event
                .tool_name
                .as_deref()
                .is_some_and(is_interactive_ui_tool)
        {
            continue;
        }
        let full = event.content.len();
        let shaped = serde_json::from_str::<serde_json::Value>(&event.content)
            .ok()
            .filter(|v| v.is_object() || v.is_array())
            .and_then(|mut v| {
                shorten_strings(&mut v, max / 2);
                serde_json::to_string(&v).ok()
            })
            .filter(|text| text.len() <= max * 2);
        event.content = shaped.unwrap_or_else(|| excerpt(&event.content, max));
        let mut metadata = event.metadata.as_object().cloned().unwrap_or_default();
        metadata.insert("truncated".to_string(), serde_json::json!(true));
        metadata.insert("full_bytes".to_string(), serde_json::json!(full));
        event.metadata = serde_json::Value::Object(metadata);
    }
}

pub(super) fn default_include_event_counts() -> bool {
    true
}

pub(super) const INACTIVE_EVENT_SUMMARY_AFTER: chrono::Duration = chrono::Duration::minutes(5);
pub(super) const CONVERSATION_PROFILE_TRACE_TAIL: usize = 10;

#[derive(Debug, Clone)]
pub(super) struct EventSummary {
    pub(super) events: Vec<mission_store::StoredEvent>,
    pub(super) original_count: usize,
    pub(super) summarized_count: usize,
}

impl EventSummary {
    pub(super) fn unchanged(events: Vec<mission_store::StoredEvent>) -> Self {
        let count = events.len();
        Self {
            events,
            original_count: count,
            summarized_count: count,
        }
    }
}

/// Gate for the event-logger task: which broadcast events get persisted.
///
/// Incremental thinking deltas (`done: false`) are broadcast-only — they
/// exist for live streaming and each carries the cumulative block buffer, so
/// persisting them is O(n²) in storage (some missions accumulated 100k+ rows).
/// Only the block-final `done: true` event, which carries the full block
/// content, is persisted.
pub(super) fn should_persist_event(event: &AgentEvent) -> bool {
    !matches!(event, AgentEvent::Thinking { done: false, .. })
}

pub(super) fn thinking_event_is_done(event: &mission_store::StoredEvent) -> bool {
    event
        .metadata
        .get("done")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

pub(super) fn should_summarize_events(mission: &Mission) -> bool {
    if mission.status == MissionStatus::Active {
        return false;
    }

    let Ok(updated_at) = chrono::DateTime::parse_from_rfc3339(&mission.updated_at) else {
        return false;
    };
    chrono::Utc::now().signed_duration_since(updated_at.with_timezone(&chrono::Utc))
        > INACTIVE_EVENT_SUMMARY_AFTER
}

pub(super) fn summarize_inactive_stream_events(
    events: Vec<mission_store::StoredEvent>,
) -> EventSummary {
    if events.len() < 2 {
        return EventSummary::unchanged(events);
    }

    let original_count = events.len();
    let mut summarized = Vec::with_capacity(events.len());
    // text_delta keeps the legacy last-wins collapse: deltas are cumulative
    // snapshots and only the latest matters.
    let mut pending_text: Option<mission_store::StoredEvent> = None;
    // Thinking collapses per *block*, not per run: a `done: true` row is a
    // block boundary and rows are never merged across it. Within a block we
    // keep one row carrying the last non-empty content (legacy data persisted
    // cumulative snapshots followed by an empty `done: true` finalizer;
    // current data persists exactly one full-content `done: true` row per
    // block, which passes through unchanged).
    let mut pending_thinking: Option<mission_store::StoredEvent> = None;
    let mut thinking_last_nonempty: Option<String> = None;

    fn flush_thinking(
        pending: &mut Option<mission_store::StoredEvent>,
        last_nonempty: &mut Option<String>,
        out: &mut Vec<mission_store::StoredEvent>,
    ) {
        if let Some(mut event) = pending.take() {
            if event.content.trim().is_empty() {
                if let Some(content) = last_nonempty.take() {
                    event.content = content;
                } else {
                    // A block that never produced content (legacy empty
                    // finalizer with no preceding deltas) — drop it.
                    return;
                }
            }
            // Force the kept row to close its block so the frontend renders
            // it as a finished thought.
            event.metadata["done"] = serde_json::Value::Bool(true);
            out.push(event);
        }
        *last_nonempty = None;
    }

    for event in events {
        if event.event_type == "thinking" {
            // Preserve interleaving: an open text_delta run ends here.
            if let Some(pending) = pending_text.take() {
                summarized.push(pending);
            }
            let is_boundary = thinking_event_is_done(&event);
            if !event.content.trim().is_empty() {
                thinking_last_nonempty = Some(event.content.clone());
            }
            pending_thinking = Some(event);
            if is_boundary {
                flush_thinking(
                    &mut pending_thinking,
                    &mut thinking_last_nonempty,
                    &mut summarized,
                );
            }
            continue;
        }

        // Any non-thinking event closes an open thinking run first to
        // preserve ordering.
        flush_thinking(
            &mut pending_thinking,
            &mut thinking_last_nonempty,
            &mut summarized,
        );

        if event.event_type == "text_delta" {
            pending_text = Some(event);
            continue;
        }

        if let Some(pending) = pending_text.take() {
            summarized.push(pending);
        }
        summarized.push(event);
    }

    flush_thinking(
        &mut pending_thinking,
        &mut thinking_last_nonempty,
        &mut summarized,
    );
    if let Some(pending) = pending_text {
        summarized.push(pending);
    }

    EventSummary {
        original_count,
        summarized_count: summarized.len(),
        events: summarized,
    }
}

pub(super) fn conversation_profile_enabled(profile: Option<&str>) -> bool {
    matches!(profile, Some("conversation"))
}

/// Interactive/frontend tools whose call args (the question payload) must
/// survive history projection so the dashboard can render the item — even
/// after it's answered. Mirrors the dashboard's `isUiTool` check.
pub(super) fn is_interactive_ui_tool(name: &str) -> bool {
    name == "question" || name == "AskUserQuestion" || name.starts_with("ui_")
}

pub(super) fn project_conversation_events(
    events: Vec<mission_store::StoredEvent>,
    keep_full_tool_call_ids: &HashSet<String>,
    tool_summaries: &HashMap<String, mission_store::ToolCallSummary>,
) -> Vec<mission_store::StoredEvent> {
    if events.is_empty() {
        return events;
    }

    #[derive(Default)]
    struct ToolPair {
        latest_sequence: i64,
        has_result: bool,
        result_sequence: Option<i64>,
        result_timestamp: Option<String>,
        call_content_bytes: usize,
        result_content_bytes: usize,
    }

    let mut pairs: HashMap<String, ToolPair> = HashMap::new();
    for event in &events {
        if !matches!(event.event_type.as_str(), "tool_call" | "tool_result") {
            continue;
        }
        let Some(tool_call_id) = event.tool_call_id.as_ref() else {
            continue;
        };
        let pair = pairs.entry(tool_call_id.clone()).or_default();
        pair.latest_sequence = pair.latest_sequence.max(event.sequence);
        if event.event_type == "tool_call" {
            pair.call_content_bytes = event.content.len();
        } else {
            pair.has_result = true;
            pair.result_sequence = Some(event.sequence);
            pair.result_timestamp = Some(event.timestamp.clone());
            pair.result_content_bytes = event.content.len();
        }
    }

    let mut projected = Vec::with_capacity(events.len());
    for mut event in events {
        if !matches!(event.event_type.as_str(), "tool_call" | "tool_result") {
            projected.push(event);
            continue;
        }
        let Some(tool_call_id) = event.tool_call_id.clone() else {
            projected.push(event);
            continue;
        };
        if keep_full_tool_call_ids.contains(&tool_call_id) {
            projected.push(event);
            continue;
        }
        // Interactive UI tools (question / AskUserQuestion / ui_*) carry the
        // question payload the dashboard needs to render the item even after
        // it's answered. Stubbing them drops the args, so an answered question
        // would reload as an empty "reply below" prompt. Never stub them or
        // their results, regardless of the recency window.
        if event
            .tool_name
            .as_deref()
            .is_some_and(is_interactive_ui_tool)
        {
            projected.push(event);
            continue;
        }
        if event.event_type == "tool_result" {
            continue;
        }

        if let Some(pair) = pairs.get(&tool_call_id) {
            let persisted = tool_summaries.get(&tool_call_id);
            let has_result = persisted.map_or(pair.has_result, |summary| summary.has_result);
            if !has_result {
                projected.push(event);
                continue;
            }
            event.event_type = "tool_stub".to_string();
            event.content.clear();
            let mut metadata = event.metadata.as_object().cloned().unwrap_or_default();
            metadata.insert("lazy".to_string(), serde_json::json!(true));
            metadata.insert("has_result".to_string(), serde_json::json!(has_result));
            metadata.insert(
                "call_sequence".to_string(),
                serde_json::json!(event.sequence),
            );
            metadata.insert(
                "result_sequence".to_string(),
                serde_json::json!(persisted
                    .and_then(|summary| summary.result_sequence)
                    .or(pair.result_sequence)),
            );
            metadata.insert(
                "result_timestamp".to_string(),
                serde_json::json!(persisted
                    .and_then(|summary| summary.result_timestamp.clone())
                    .or_else(|| pair.result_timestamp.clone())),
            );
            metadata.insert(
                "call_content_bytes".to_string(),
                serde_json::json!(persisted.map_or(pair.call_content_bytes, |summary| {
                    summary.call_content_bytes
                })),
            );
            metadata.insert(
                "result_content_bytes".to_string(),
                serde_json::json!(persisted.map_or(pair.result_content_bytes, |summary| {
                    summary.result_content_bytes
                })),
            );
            event.metadata = serde_json::Value::Object(metadata);
        }
        projected.push(event);
    }

    projected
}

/// Get events for a mission (for debugging/replay).
///
/// Response includes `X-Total-Events` (total count matching the type
/// filter) and `X-Max-Sequence` (highest sequence stored for this
/// mission) headers so the client can decide whether it's caught up
/// without issuing a second request.
pub(super) fn event_page_cursor(
    first: Option<i64>,
    last: Option<i64>,
    count: usize,
    limit: Option<usize>,
    backward: bool,
) -> (Option<i64>, bool) {
    (
        if backward { first } else { last },
        limit.is_some_and(|limit| limit > 0 && count == limit),
    )
}

pub async fn get_mission_events(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    axum::extract::Query(query): axum::extract::Query<GetEventsQuery>,
) -> Result<Response, (StatusCode, String)> {
    state.control_metrics.record_events_request();
    let metrics_start = Instant::now();
    let control = control_for_user(&state, &user).await;

    // Check mission exists
    let mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "Mission not found".to_string()))?;

    let type_names = event_types_for_query(&query);
    let types: Option<Vec<&str>> = type_names
        .as_ref()
        .map(|t| t.iter().map(String::as_str).collect());

    let events = if let Some(before_seq) = query.before_seq {
        control
            .mission_store
            .get_events_before(mission_id, before_seq, types.as_deref(), query.limit)
            .await
            .map_err(internal_error)?
    } else if let Some(since_seq) = query.since_seq {
        control
            .mission_store
            .get_events_since(mission_id, since_seq, types.as_deref(), query.limit)
            .await
            .map_err(internal_error)?
    } else {
        // No cursor: default to the NEWEST `limit` events (the tail), returned
        // ascending within the page — i.e. behave as `before_seq=MAX`. "Latest
        // activity" is the overwhelmingly common need (dashboards, debugging a
        // live mission), so paging from the oldest row by default is a footgun.
        // Callers that genuinely want a forward replay from the start pass
        // `since_seq=0` explicitly, which is handled above and is unaffected.
        control
            .mission_store
            .get_events_before(mission_id, i64::MAX, types.as_deref(), query.limit)
            .await
            .map_err(internal_error)?
    };
    // Advance through raw rows, not the projected/condensed response.
    let page_max = events.last().map(|event| event.sequence);
    let (next_cursor, has_more) = event_page_cursor(
        events.first().map(|event| event.sequence),
        page_max,
        events.len(),
        query.limit,
        query.before_seq.is_some() || query.since_seq.is_none(),
    );
    let mut summary = if should_summarize_events(&mission) {
        summarize_inactive_stream_events(events)
    } else {
        EventSummary::unchanged(events)
    };
    if conversation_profile_enabled(query.profile.as_deref()) {
        let keep_full_tool_call_ids: HashSet<String> = control
            .mission_store
            .get_recent_tool_call_ids(
                mission_id,
                query.trace_tail.unwrap_or(CONVERSATION_PROFILE_TRACE_TAIL),
            )
            .await
            .map_err(internal_error)?
            .into_iter()
            .collect();
        let tool_call_ids = summary
            .events
            .iter()
            .filter_map(|event| event.tool_call_id.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let tool_summaries = control
            .mission_store
            .get_tool_call_summaries(mission_id, &tool_call_ids)
            .await
            .map_err(internal_error)?;
        summary.events =
            project_conversation_events(summary.events, &keep_full_tool_call_ids, &tool_summaries);
        summary.summarized_count = summary.events.len();
    }

    if let Some(max) = query.max_payload {
        truncate_tool_payloads(&mut summary.events, max);
    }

    // Metadata headers let the client decide whether it's caught up
    // without a second round-trip. Failures here are non-fatal — we just
    // skip the header rather than breaking the whole response.
    let total = if query.include_counts {
        control
            .mission_store
            .count_events(mission_id, types.as_deref())
            .await
            .ok()
    } else {
        None
    };
    let max_seq = control
        .mission_store
        .max_event_sequence(mission_id)
        .await
        .ok();

    let payload_bytes = serde_json::to_vec(&summary.events)
        .map(|bytes| bytes.len())
        .unwrap_or(0);
    state.control_metrics.record_events_response(
        metrics_start.elapsed(),
        payload_bytes,
        summary.original_count,
        summary.summarized_count,
    );

    let mut response = Json(summary.events).into_response();
    let headers = response.headers_mut();
    for (name, value) in [
        ("X-Next-Cursor", next_cursor),
        ("X-Page-Max-Sequence", page_max),
    ] {
        if let Some(value) = value {
            headers.insert(
                name,
                header::HeaderValue::from_str(&value.to_string()).map_err(internal_error)?,
            );
        }
    }
    headers.insert(
        "X-Orb-Events-Protocol",
        header::HeaderValue::from_static("1"),
    );
    headers.insert(
        "X-Has-More",
        header::HeaderValue::from_static(if has_more { "true" } else { "false" }),
    );

    if let Some(total) = total {
        if let Ok(v) = header::HeaderValue::from_str(&total.to_string()) {
            headers.insert("X-Total-Events", v);
        }
    }
    if let Some(max_seq) = max_seq {
        if let Ok(v) = header::HeaderValue::from_str(&max_seq.to_string()) {
            headers.insert("X-Max-Sequence", v);
        }
    }
    if summary.summarized_count < summary.original_count {
        if let Ok(v) = header::HeaderValue::from_str(&summary.original_count.to_string()) {
            headers.insert("X-Original-Event-Count", v);
        }
        if let Ok(v) = header::HeaderValue::from_str(&summary.summarized_count.to_string()) {
            headers.insert("X-Summarized-Event-Count", v);
        }
    }
    // CORS exposure so browsers can read these headers from JS.
    headers.insert(
        header::ACCESS_CONTROL_EXPOSE_HEADERS,
        header::HeaderValue::from_static(
            "X-Total-Events, X-Max-Sequence, X-Original-Event-Count, X-Summarized-Event-Count, X-Next-Cursor, X-Page-Max-Sequence, X-Has-More, X-Orb-Events-Protocol",
        ),
    );

    Ok(response)
}

#[derive(Debug, Deserialize)]
pub struct AlertsFeedQuery {
    /// Comma-separated mission statuses to keep (e.g. `awaiting_user,failed`).
    pub statuses: Option<String>,
    /// When true, keep only alerts that are themselves a current operator
    /// page (`awaiting_user` or live AskUserQuestion). Current-state: the
    /// mission must still `needs_operator` now. The handler walks the raw
    /// status-event feed until `limit` matches so a sparse page is not empty.
    pub needs_operator: Option<bool>,
    /// Timestamp cursor: return alerts strictly older than this.
    pub before: Option<String>,
    pub limit: Option<usize>,
}

#[derive(Debug, Serialize)]
pub struct AlertFeedDelivery {
    pub channel: &'static str,
    pub status: String,
    pub sent_at: Option<String>,
    pub acknowledged_at: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AlertFeedEntry {
    pub mission_id: Uuid,
    pub status: String,
    pub summary: String,
    pub timestamp: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mission: Option<mission_store::MissionSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery: Option<AlertFeedDelivery>,
}

#[derive(Debug, Serialize)]
pub struct AlertsFeedResponse {
    pub alerts: Vec<AlertFeedEntry>,
    pub next_cursor: Option<String>,
}

pub(super) fn telegram_delivery_for_status(
    telegram_alerts: &[crate::api::mission_store::TelegramAlert],
    mission_id: Uuid,
    status: &str,
) -> Option<AlertFeedDelivery> {
    let class = format!("mission_{status}");
    telegram_alerts
        .iter()
        .find(|alert| {
            alert.mission_id == Some(mission_id)
                && alert
                    .event_kind
                    .split(':')
                    .next()
                    .unwrap_or(&alert.event_kind)
                    == class
        })
        .map(|alert| AlertFeedDelivery {
            channel: "telegram",
            status: alert.status.clone(),
            sent_at: alert.sent_at.clone(),
            acknowledged_at: alert.acknowledged_at.clone(),
            last_error: alert.last_error.clone(),
        })
}

/// Synthesize a current-state alert for a live AskUserQuestion so Needs You
/// does not depend on the mission's (possibly ancient) `active` status event
/// still sitting inside the historical scan window.
pub(super) fn live_wait_alert_entry(
    mission_id: Uuid,
    summary: mission_store::MissionSummary,
    wait_started_at: Option<&str>,
    now: &str,
    delivery: Option<AlertFeedDelivery>,
) -> AlertFeedEntry {
    AlertFeedEntry {
        mission_id,
        status: "active".to_string(),
        summary: "Waiting for user input".to_string(),
        timestamp: wait_started_at.unwrap_or(now).to_string(),
        mission: Some(summary),
        delivery,
    }
}

pub(super) fn refresh_summary_for_waiting_user(
    summary: &mut mission_store::MissionSummary,
    waiting_for_user_tool: bool,
    wait_started_at: Option<&str>,
    now: chrono::DateTime<chrono::Utc>,
) {
    if !waiting_for_user_tool {
        return;
    }
    let parsed_status = serde_json::from_value(serde_json::Value::String(summary.status.clone()))
        .unwrap_or(MissionStatus::Active);
    summary.needs_operator = super::super::operator_attention::needs_operator(
        &super::super::operator_attention::OperatorAttentionInput {
            status: parsed_status,
            awaiting_kind: summary.awaiting_kind.as_deref(),
            has_origin_session: summary
                .origin_session_id
                .as_deref()
                .is_some_and(|id| !id.is_empty()),
            updated_at: &summary.updated_at,
            waiting_for_user_tool: true,
            wait_started_at,
        },
        now,
    );
}

/// Cross-mission feed of status-change alerts, newest first. Source of truth
/// is `mission_events` (`mission_status_changed`), decorated best-effort with
/// mission summaries and Telegram delivery state.
pub async fn get_alerts_feed(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    axum::extract::Query(query): axum::extract::Query<AlertsFeedQuery>,
) -> Result<Json<AlertsFeedResponse>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let needs_operator_only = query.needs_operator == Some(true);
    let wanted: Option<Vec<String>> = query.statuses.as_deref().map(|s| {
        s.split(',')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect()
    });
    let active_runs = control
        .mission_store
        .list_active_mission_runs()
        .await
        .unwrap_or_default();
    let waiting_user_waits =
        user_wait_starts_for_runs(control.mission_store.as_ref(), &active_runs).await;
    let now = chrono::Utc::now();

    // `needs_operator` is sparse, so walk raw pages until we fill `limit`
    // (or exhaust) instead of returning an empty 30-row window.
    const MAX_OPERATOR_PAGES: usize = 10;
    let max_pages = if needs_operator_only {
        MAX_OPERATOR_PAGES
    } else {
        1
    };
    let mut before = query.before.clone();
    let mut entries: Vec<AlertFeedEntry> = Vec::new();
    let mut next_cursor = None;
    let mut seen_ids: HashSet<Uuid> = HashSet::new();
    let mut seeded_live: HashSet<Uuid> = HashSet::new();
    let mut summaries: HashMap<Uuid, mission_store::MissionSummary> = HashMap::new();
    let mut telegram_alerts = Vec::new();

    // Current live waits belong on the first Needs You page even when the
    // mission's last status event is older than the historical window.
    if needs_operator_only && query.before.is_none() && !waiting_user_waits.is_empty() {
        let live_ids: Vec<Uuid> = waiting_user_waits.keys().copied().collect();
        let fetched = control
            .mission_store
            .get_mission_summaries(&live_ids)
            .await
            .map_err(internal_error)?;
        summaries.extend(fetched);
        telegram_alerts.extend(
            control
                .mission_store
                .list_telegram_alerts_for_missions(&live_ids)
                .await
                .unwrap_or_default(),
        );
        let now_rfc = now.to_rfc3339();
        for (mission_id, started_at) in &waiting_user_waits {
            if let Some(wanted) = &wanted {
                if !wanted.iter().any(|status| status == "active") {
                    continue;
                }
            }
            let Some(summary) = summaries.get_mut(mission_id) else {
                continue;
            };
            refresh_summary_for_waiting_user(summary, true, started_at.as_deref(), now);
            if !summary.needs_operator {
                continue;
            }
            entries.push(live_wait_alert_entry(
                *mission_id,
                summary.clone(),
                started_at.as_deref(),
                &now_rfc,
                telegram_delivery_for_status(&telegram_alerts, *mission_id, "awaiting_user")
                    .or_else(|| {
                        telegram_delivery_for_status(&telegram_alerts, *mission_id, "active")
                    }),
            ));
            seeded_live.insert(*mission_id);
            seen_ids.insert(*mission_id);
        }
        entries.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
    }

    for _ in 0..max_pages {
        let events = control
            .mission_store
            .get_status_events_global(before.as_deref(), limit)
            .await
            .map_err(internal_error)?;
        let page_len = events.len();
        next_cursor = if page_len == limit {
            events.last().map(|e| e.timestamp.clone())
        } else {
            None
        };

        let mut page: Vec<AlertFeedEntry> = events
            .into_iter()
            .filter_map(|e| {
                let status = e.metadata.get("status")?.as_str()?.to_string();
                if let Some(wanted) = &wanted {
                    if !wanted.contains(&status) {
                        return None;
                    }
                }
                Some(AlertFeedEntry {
                    mission_id: e.mission_id,
                    status,
                    summary: e.content,
                    timestamp: e.timestamp,
                    mission: None,
                    delivery: None,
                })
            })
            .collect();

        let new_ids: Vec<Uuid> = {
            let mut ids: Vec<Uuid> = page
                .iter()
                .map(|e| e.mission_id)
                .filter(|id| seen_ids.insert(*id))
                .collect();
            ids.sort();
            ids.dedup();
            ids
        };
        if !new_ids.is_empty() {
            let fetched = control
                .mission_store
                .get_mission_summaries(&new_ids)
                .await
                .map_err(internal_error)?;
            summaries.extend(fetched);
            telegram_alerts.extend(
                control
                    .mission_store
                    .list_telegram_alerts_for_missions(&new_ids)
                    .await
                    .unwrap_or_default(),
            );
        }

        for entry in &mut page {
            if let Some(summary) = summaries.get_mut(&entry.mission_id) {
                let waiting = waiting_user_waits.contains_key(&entry.mission_id);
                refresh_summary_for_waiting_user(
                    summary,
                    waiting,
                    waiting_user_waits
                        .get(&entry.mission_id)
                        .and_then(|started| started.as_deref()),
                    now,
                );
                entry.mission = Some(summary.clone());
            }
            entry.delivery =
                telegram_delivery_for_status(&telegram_alerts, entry.mission_id, &entry.status);
        }

        if needs_operator_only {
            page.retain(|entry| {
                if seeded_live.contains(&entry.mission_id) {
                    return false;
                }
                super::super::operator_attention::alert_event_is_operator_page(
                    &entry.status,
                    entry
                        .mission
                        .as_ref()
                        .is_some_and(|summary| summary.needs_operator),
                    waiting_user_waits.contains_key(&entry.mission_id),
                )
            });
        }
        entries.extend(page);
        if entries.len() >= limit || next_cursor.is_none() {
            break;
        }
        before = next_cursor.clone();
    }
    let truncated = entries.len() > limit;
    let had_more_raw = next_cursor.is_some();
    entries.truncate(limit);
    // After a filter walk, leftover matches sit on the truncated tail of
    // this page. Point the cursor at the last *kept* event so Load older
    // does not skip them (the raw-page cursor would).
    if needs_operator_only && (truncated || (entries.len() == limit && had_more_raw)) {
        if let Some(last) = entries.last() {
            next_cursor = Some(last.timestamp.clone());
        }
    }

    Ok(Json(AlertsFeedResponse {
        alerts: entries,
        next_cursor,
    }))
}

pub async fn get_mission_tool_call_events(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path((mission_id, tool_call_id)): Path<(Uuid, String)>,
) -> Result<Json<Vec<mission_store::StoredEvent>>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mission_exists = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?;
    if mission_exists.is_none() {
        return Err((StatusCode::NOT_FOUND, "Mission not found".to_string()));
    }

    let events = control
        .mission_store
        .get_events_for_tool_call(mission_id, &tool_call_id)
        .await
        .map_err(internal_error)?;
    if events.is_empty() {
        return Err((StatusCode::NOT_FOUND, "Tool call not found".to_string()));
    }
    Ok(Json(events))
}

pub(super) const TRANSCRIPT_EVENT_TYPES: &[&str] = &[
    "user_message",
    "assistant_message",
    "assistant_message_canonical",
];
pub(super) const TRACE_EVENT_TYPES: &[&str] = &[
    "thinking",
    "tool_call",
    "tool_result",
    "text_delta",
    "text_op",
    "error",
    "phase",
    "status",
];
pub(super) const HISTORY_EVENT_TYPES: &[&str] = &[
    "user_message",
    "assistant_message",
    "assistant_message_canonical",
    "tool_call",
    "tool_result",
    "text_delta",
    "text_op",
    "thinking",
    "goal_iteration",
    "goal_status",
];
/// Conversation message types used to anchor the snapshot tail. The snapshot
/// guarantees the most recent `SNAPSHOT_CONVERSATIONAL_MESSAGES` of these are
/// loaded (plus every tool call between them), so a tool-heavy mission opens
/// on the actual conversation instead of a wall of tool output.
pub(super) const SNAPSHOT_ANCHOR_TYPES: &[&str] = &[
    "user_message",
    "assistant_message",
    "assistant_message_canonical",
];
/// How many recent conversation messages the snapshot guarantees.
pub(super) const SNAPSHOT_CONVERSATIONAL_MESSAGES: usize = 10;
/// Hard cap on snapshot size. Bounds payload if the recent conversation
/// happens to span an unusually large number of tool calls; the rest stays
/// reachable via backwards pagination ("Load older messages").
pub(super) const SNAPSHOT_MAX_EVENTS: usize = 1500;

pub(super) fn event_types_for_query(query: &GetEventsQuery) -> Option<Vec<String>> {
    if let Some(types) = query.types.as_ref() {
        return Some(
            types
                .split(',')
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(ToString::to_string)
                .collect(),
        );
    }

    match query.view.as_deref() {
        Some("transcript") => Some(
            TRANSCRIPT_EVENT_TYPES
                .iter()
                .map(|s| s.to_string())
                .collect(),
        ),
        Some("trace") => Some(TRACE_EVENT_TYPES.iter().map(|s| s.to_string()).collect()),
        Some("history") => Some(HISTORY_EVENT_TYPES.iter().map(|s| s.to_string()).collect()),
        Some("all") | None => None,
        Some(_) => None,
    }
}

pub(super) fn event_visibility(event_type: &str) -> &'static str {
    match event_type {
        "user_message"
        | "assistant_message"
        | "assistant_message_canonical"
        | "mission_status_changed" => "transcript",
        "thinking" | "tool_call" | "tool_result" | "text_delta" | "text_op" | "phase"
        | "status" | "error" => "trace",
        _ => "debug",
    }
}

#[derive(Debug, Serialize)]
pub struct MissionSnapshotResponse {
    pub mission: Mission,
    pub execution: Option<serde_json::Value>,
    pub events: Vec<mission_store::StoredEvent>,
    pub event_counts: HashMap<String, usize>,
    pub counts: HashMap<String, usize>,
    pub visibility_counts: HashMap<String, usize>,
    pub total_events: usize,
    pub latest_sequence: i64,
    pub child_missions: Vec<Mission>,
    pub running: Option<super::super::mission_runner::RunningMissionInfo>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SnapshotQuery {
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub trace_tail: Option<usize>,
}

/// Single first-paint payload for clients. It returns the latest visible event
/// tail plus metadata needed to avoid the old transcript-then-trace redraw.
pub async fn get_mission_snapshot(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    axum::extract::Query(query): axum::extract::Query<SnapshotQuery>,
) -> Result<Json<MissionSnapshotResponse>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mut mission = control
        .mission_store
        .get_mission(mission_id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "Mission not found".to_string()))?;

    if let Some(workspace) = state.workspaces.get(mission.workspace_id).await {
        mission.workspace_name = Some(workspace.name);
    }

    // Conversation-anchored snapshot tail: load everything from the
    // Nth-most-recent conversation message to the head, so the recent
    // back-and-forth is always present even when tool calls dominate the
    // raw event stream. Falls back to a plain recent-events tail when the
    // mission has fewer than N conversation messages, or (degenerate) when
    // the anchored span would exceed the hard cap.
    let anchor_seq = control
        .mission_store
        .nth_recent_event_sequence(
            mission_id,
            SNAPSHOT_ANCHOR_TYPES,
            SNAPSHOT_CONVERSATIONAL_MESSAGES,
        )
        .await
        .map_err(internal_error)?;
    let events = match anchor_seq {
        Some(anchor) => {
            // `get_events_since` is `sequence > since`, so subtract one to
            // include the anchor itself. Fetch one past the cap to detect
            // overflow without a separate count query.
            let anchored = control
                .mission_store
                .get_events_since(
                    mission_id,
                    anchor.saturating_sub(1),
                    Some(HISTORY_EVENT_TYPES),
                    Some(SNAPSHOT_MAX_EVENTS + 1),
                )
                .await
                .map_err(internal_error)?;
            if anchored.len() > SNAPSHOT_MAX_EVENTS {
                // The recent conversation spans more than the cap of tool
                // calls. `get_events_since` returned the OLDEST events after
                // the anchor (ASC), which would miss the newest — so fall
                // back to the most-recent capped tail instead.
                control
                    .mission_store
                    .get_events_before(
                        mission_id,
                        i64::MAX,
                        Some(HISTORY_EVENT_TYPES),
                        Some(SNAPSHOT_MAX_EVENTS),
                    )
                    .await
                    .map_err(internal_error)?
            } else {
                anchored
            }
        }
        None => control
            .mission_store
            .get_events_before(
                mission_id,
                i64::MAX,
                Some(HISTORY_EVENT_TYPES),
                Some(SNAPSHOT_MAX_EVENTS),
            )
            .await
            .map_err(internal_error)?,
    };
    let mut summary = if should_summarize_events(&mission) {
        summarize_inactive_stream_events(events)
    } else {
        EventSummary::unchanged(events)
    };
    if conversation_profile_enabled(query.profile.as_deref()) {
        let keep_full_tool_call_ids: HashSet<String> = control
            .mission_store
            .get_recent_tool_call_ids(
                mission_id,
                query.trace_tail.unwrap_or(CONVERSATION_PROFILE_TRACE_TAIL),
            )
            .await
            .map_err(internal_error)?
            .into_iter()
            .collect();
        let tool_call_ids = summary
            .events
            .iter()
            .filter_map(|event| event.tool_call_id.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let tool_summaries = control
            .mission_store
            .get_tool_call_summaries(mission_id, &tool_call_ids)
            .await
            .map_err(internal_error)?;
        summary.events =
            project_conversation_events(summary.events, &keep_full_tool_call_ids, &tool_summaries);
        summary.summarized_count = summary.events.len();
    }
    let event_counts = control
        .mission_store
        .count_events_by_type(mission_id, Some(HISTORY_EVENT_TYPES))
        .await
        .map_err(internal_error)?;
    let total = event_counts.values().copied().sum();
    let mut visibility_counts: HashMap<String, usize> = HashMap::new();
    for (event_type, count) in &event_counts {
        *visibility_counts
            .entry(event_visibility(event_type).to_string())
            .or_insert(0) += *count;
    }
    let latest_sequence = control
        .mission_store
        .max_event_sequence(mission_id)
        .await
        .map_err(internal_error)?;
    let child_missions = control
        .mission_store
        .get_child_missions(mission_id)
        .await
        .unwrap_or_default();
    let running = get_running_missions(&control)
        .await?
        .into_iter()
        .find(|info| info.mission_id == mission_id);
    let execution = control
        .mission_store
        .get_latest_mission_run(mission_id)
        .await
        .map_err(internal_error)?
        .as_ref()
        .map(|run| mission_execution_projection(run, mission.status));

    Ok(Json(MissionSnapshotResponse {
        mission,
        execution,
        events: summary.events,
        counts: event_counts.clone(),
        event_counts,
        visibility_counts,
        total_events: total,
        latest_sequence,
        child_missions,
        running,
    }))
}

// ==================== Parallel Mission Endpoints ====================

/// List currently running missions.
pub async fn list_running_missions(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Result<Json<Vec<super::super::mission_runner::RunningMissionInfo>>, (StatusCode, String)> {
    state.control_metrics.record_running_request();
    let control = control_for_user(&state, &user).await;
    let running = get_running_missions(&control).await?;
    Ok(Json(running))
}

/// P0-#3: in-process metrics snapshot for perf validation.
pub async fn get_control_metrics(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
) -> Json<super::super::control_metrics::MetricsSnapshot> {
    Json(state.control_metrics.snapshot())
}

/// P5-#25: client telemetry sink. Dashboard POSTs here when its 5-second
/// longtask budget breaches the 2s threshold so we can correlate freezes
/// with mission shape (event count, heap).
pub async fn post_control_telemetry_perf(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(report): Json<super::super::control_metrics::HealthReport>,
) -> StatusCode {
    state.control_metrics.record_health_report(report);
    StatusCode::ACCEPTED
}

#[cfg(test)]
mod payload_tests {
    use super::*;

    fn event(event_type: &str, tool: &str, content: &str) -> mission_store::StoredEvent {
        mission_store::StoredEvent {
            id: 1,
            mission_id: Uuid::nil(),
            sequence: 1,
            event_type: event_type.into(),
            timestamp: String::new(),
            event_id: None,
            tool_call_id: Some("c1".into()),
            tool_name: Some(tool.into()),
            content: content.into(),
            metadata: serde_json::json!({"keep": 1}),
        }
    }

    #[test]
    fn large_tool_payloads_keep_head_and_tail() {
        let big = format!("{}{}", "a".repeat(6000), "é".repeat(2000));
        let mut events = vec![
            event("tool_result", "Bash", &big),
            event("tool_call", "Bash", "{\"command\":\"ls\"}"),
            event("assistant_message", "", &big),
            event("tool_call", "AskUserQuestion", &big),
        ];
        truncate_tool_payloads(&mut events, 2048);
        let cut = &events[0];
        assert!(cut.content.len() < 2100);
        assert!(cut.content.starts_with("aaaa") && cut.content.ends_with('é'));
        assert_eq!(cut.metadata["truncated"], true);
        assert_eq!(cut.metadata["full_bytes"], big.len());
        assert_eq!(cut.metadata["keep"], 1);
        assert_eq!(events[1].content, "{\"command\":\"ls\"}");
        assert_eq!(events[2].content, big);
        assert_eq!(events[3].content, big);
    }

    #[test]
    fn json_payloads_keep_their_shape() {
        let args =
            serde_json::json!({"file_path": "src/a.rs", "content": "x".repeat(20_000)}).to_string();
        let mut events = vec![event("tool_call", "Write", &args)];
        truncate_tool_payloads(&mut events, 4096);
        let v: serde_json::Value = serde_json::from_str(&events[0].content).unwrap();
        assert_eq!(v["file_path"], "src/a.rs");
        assert!(v["content"].as_str().unwrap().contains("bytes omitted"));
        assert!(events[0].content.len() < 4200);
        assert_eq!(events[0].metadata["full_bytes"], args.len());
    }

    #[test]
    fn max_payload_has_a_floor() {
        let mut events = vec![
            event("tool_result", "Bash", &"x".repeat(1000)),
            event("tool_result", "Bash", &"x".repeat(5000)),
        ];
        truncate_tool_payloads(&mut events, 10);
        assert_eq!(events[0].content.len(), 1000);
        assert!(events[1].content.len() < 1100);
        assert!(events[1].content.len() >= MIN_MAX_PAYLOAD);
    }
}
