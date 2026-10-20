//! Telegram channels, users, alerts, chats, scheduled messages, memory and workflows.

use super::*;

pub(super) fn fold_search_char(ch: char) -> char {
    match ch {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => 'a',
        'ç' => 'c',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ñ' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ý' | 'ÿ' => 'y',
        _ => ch,
    }
}

pub(super) fn normalize_search_text(value: &str) -> String {
    let mut normalized = String::with_capacity(value.len());
    let mut prev_space = true;
    for ch in value.chars().flat_map(|ch| ch.to_lowercase()) {
        let folded = fold_search_char(ch);
        if folded.is_ascii_alphanumeric() {
            normalized.push(folded);
            prev_space = false;
        } else if !prev_space {
            normalized.push(' ');
            prev_space = true;
        }
    }
    normalized.trim().to_string()
}

pub(super) fn tokenize_search_text(value: &str) -> Vec<String> {
    normalize_search_text(value)
        .split_whitespace()
        .filter(|token| token.len() >= 2 && !TELEGRAM_MEMORY_SEARCH_STOPWORDS.contains(token))
        .map(ToOwned::to_owned)
        .collect()
}

pub(super) fn build_telegram_memory_search_text(entry: &TelegramStructuredMemoryEntry) -> String {
    let mut parts = Vec::new();
    if let Some(label) = entry.label.as_deref() {
        parts.push(label);
    }
    parts.push(entry.value.as_str());
    if let Some(display_name) = entry.subject_display_name.as_deref() {
        parts.push(display_name);
    }
    if let Some(username) = entry.subject_username.as_deref() {
        parts.push(username);
    }
    match entry.kind {
        TelegramStructuredMemoryKind::Fact => parts.push("fact"),
        TelegramStructuredMemoryKind::Preference => parts.push("preference"),
        TelegramStructuredMemoryKind::Task => parts.push("task"),
        TelegramStructuredMemoryKind::Note => parts.push("note"),
    }
    normalize_search_text(&parts.join(" "))
}

pub(super) fn build_fts_query_from_tokens(
    tokens: &[String],
    normalized_query: &str,
) -> Option<String> {
    if !tokens.is_empty() {
        return Some(
            tokens
                .iter()
                .map(|token| format!("\"{}\"*", token.replace('"', "\"\"")))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }

    if normalized_query.is_empty() {
        None
    } else {
        Some(format!("\"{}\"", normalized_query.replace('"', "\"\"")))
    }
}

pub(super) fn scope_rank(scope: &TelegramStructuredMemoryScope) -> i32 {
    match scope {
        TelegramStructuredMemoryScope::User => 0,
        TelegramStructuredMemoryScope::Chat => 1,
        TelegramStructuredMemoryScope::Channel => 2,
    }
}

pub(super) fn scope_score(scope: &TelegramStructuredMemoryScope) -> f64 {
    match scope {
        TelegramStructuredMemoryScope::User => 6.0,
        TelegramStructuredMemoryScope::Chat => 5.0,
        TelegramStructuredMemoryScope::Channel => 3.0,
    }
}

pub(super) fn recency_score(updated_at: &str) -> f64 {
    let Ok(updated_at) = chrono::DateTime::parse_from_rfc3339(updated_at) else {
        return 0.0;
    };
    let age_hours = (Utc::now() - updated_at.with_timezone(&Utc))
        .num_hours()
        .max(0) as f64;
    if age_hours <= 24.0 {
        4.0
    } else if age_hours <= 24.0 * 7.0 {
        2.0
    } else if age_hours <= 24.0 * 30.0 {
        1.0
    } else {
        0.0
    }
}

pub(super) fn score_memory_entry(
    entry: &TelegramStructuredMemoryEntry,
    normalized_query: &str,
    core_query: &str,
    query_tokens: &[String],
    fts_score: Option<f64>,
) -> Option<TelegramStructuredMemorySearchHit> {
    if normalized_query.is_empty() {
        return None;
    }

    let normalized_label = entry
        .label
        .as_deref()
        .map(normalize_search_text)
        .unwrap_or_default();
    let normalized_value = normalize_search_text(&entry.value);
    let normalized_subject = normalize_search_text(
        &[
            entry.subject_display_name.as_deref().unwrap_or_default(),
            entry.subject_username.as_deref().unwrap_or_default(),
        ]
        .join(" "),
    );
    let search_text = build_telegram_memory_search_text(entry);
    let entry_tokens: HashSet<String> = tokenize_search_text(&search_text).into_iter().collect();

    let mut score = 0.0;
    let mut reasons = Vec::new();
    let mut matched_terms = Vec::new();

    if !core_query.is_empty() {
        if !normalized_label.is_empty() && normalized_label == core_query {
            score += 95.0;
            reasons.push("exact_core_label".to_string());
        } else if !normalized_label.is_empty() && normalized_label.contains(core_query) {
            score += 48.0;
            reasons.push("label_contains_core_query".to_string());
        }

        if normalized_value == core_query {
            score += 80.0;
            reasons.push("exact_core_value".to_string());
        } else if normalized_value.contains(core_query) {
            score += 42.0;
            reasons.push("value_contains_core_query".to_string());
        }
    }

    if !normalized_label.is_empty() && normalized_label == normalized_query {
        score += 80.0;
        reasons.push("exact_label".to_string());
    } else if !normalized_label.is_empty() && normalized_label.contains(normalized_query) {
        score += 40.0;
        reasons.push("label_contains_query".to_string());
    }

    if normalized_value == normalized_query {
        score += 70.0;
        reasons.push("exact_value".to_string());
    } else if normalized_value.contains(normalized_query) {
        score += 35.0;
        reasons.push("value_contains_query".to_string());
    }

    if !normalized_subject.is_empty() && normalized_subject.contains(normalized_query) {
        score += 24.0;
        reasons.push("subject_contains_query".to_string());
    }

    if !normalized_label.is_empty()
        && normalized_label.split_whitespace().count() == 1
        && TELEGRAM_MEMORY_SEARCH_STOPWORDS.contains(&normalized_label.as_str())
    {
        score -= 36.0;
        reasons.push("suspicious_label".to_string());
    }

    let mut token_matches = 0usize;
    for token in query_tokens {
        if entry_tokens.contains(token) {
            token_matches += 1;
            matched_terms.push(token.clone());
        }
    }
    if token_matches > 0 {
        let ratio = token_matches as f64 / query_tokens.len().max(1) as f64;
        score += 30.0 * ratio;
        reasons.push("token_overlap".to_string());
    }

    if let Some(fts_score) = fts_score {
        score += fts_score;
        reasons.push("full_text".to_string());
    }

    // Require at least one relevance signal (token overlap or FTS match)
    // before adding scope/recency bonuses. Without this gate, every
    // candidate receives a positive base score from scope+recency alone.
    if score <= 0.0 {
        return None;
    }

    score += scope_score(&entry.scope);
    score += recency_score(&entry.updated_at);

    matched_terms.sort();
    matched_terms.dedup();
    reasons.sort();
    reasons.dedup();

    Some(TelegramStructuredMemorySearchHit {
        entry: entry.clone(),
        score,
        matched_terms,
        reasons,
    })
}

pub(super) fn telegram_user_role_to_str(role: TelegramUserRole) -> &'static str {
    match role {
        TelegramUserRole::Owner => "owner",
        TelegramUserRole::TrustedFriend => "trusted_friend",
        TelegramUserRole::Observer => "observer",
        TelegramUserRole::Blocked => "blocked",
    }
}

pub(super) fn parse_telegram_user_role(raw: String) -> TelegramUserRole {
    match raw.as_str() {
        "owner" => TelegramUserRole::Owner,
        "trusted_friend" => TelegramUserRole::TrustedFriend,
        "blocked" => TelegramUserRole::Blocked,
        _ => TelegramUserRole::Observer,
    }
}

pub(super) fn telegram_interest_to_str(level: TelegramMissionInterestLevel) -> &'static str {
    match level {
        TelegramMissionInterestLevel::Muted => "muted",
        TelegramMissionInterestLevel::Normal => "normal",
        TelegramMissionInterestLevel::High => "high",
    }
}

pub(super) fn parse_telegram_interest(raw: String) -> TelegramMissionInterestLevel {
    match raw.as_str() {
        "muted" => TelegramMissionInterestLevel::Muted,
        "high" => TelegramMissionInterestLevel::High,
        _ => TelegramMissionInterestLevel::Normal,
    }
}

pub(super) fn row_to_telegram_user(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramUser, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let role_str: String = row.get(4)?;
    Ok(TelegramUser {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        username: row.get(2)?,
        display_name: row.get(3)?,
        role: parse_telegram_user_role(role_str),
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

pub(super) fn row_to_telegram_user_cursor(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramUserCursor, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    Ok(TelegramUserCursor {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        last_status_at: row.get(2)?,
        last_dashboard_seen_at: row.get(3)?,
        last_alert_ack_at: row.get(4)?,
        last_digest_at: row.get(5)?,
        last_seen_event_sequence_by_mission_json: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

pub(super) fn row_to_telegram_mission_subscription(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramMissionSubscription, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let mission_id_str: String = row.get(2)?;
    let interest_str: String = row.get(3)?;
    Ok(TelegramMissionSubscription {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        interest_level: parse_telegram_interest(interest_str),
        reason: row.get(4)?,
        expires_at: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

pub(super) fn row_to_telegram_alert(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramAlert, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let mission_id_str: Option<String> = row.get(2)?;
    Ok(TelegramAlert {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        mission_id: mission_id_str
            .as_deref()
            .and_then(|value| Uuid::parse_str(value).ok()),
        event_kind: row.get(3)?,
        importance: row.get(4)?,
        title: row.get(5)?,
        body: row.get(6)?,
        status: row.get(7)?,
        telegram_message_id: row.get(8)?,
        last_error: row.get(9)?,
        created_at: row.get(10)?,
        sent_at: row.get(11)?,
        acknowledged_at: row.get(12)?,
    })
}

pub(super) fn row_to_telegram_alert_preference(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramAlertPreference, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let enabled: i32 = row.get(5)?;
    Ok(TelegramAlertPreference {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        scope: row.get(2)?,
        scope_value: row.get(3)?,
        rule_text: row.get(4)?,
        enabled: enabled != 0,
        created_from_message_id: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

/// Parse a Telegram channel from a SQLite row.
/// Column order: id(0), mission_id(1), bot_token(2), bot_username(3),
///   allowed_chat_ids(4), trigger_mode(5), active(6), webhook_secret(7),
///   instructions(8), created_at(9), updated_at(10),
///   auto_create_missions(11), default_backend(12), default_model_override(13),
///   default_model_effort(14), default_workspace_id(15), default_config_profile(16),
///   default_agent(17)
pub(super) fn row_to_telegram_channel(row: &rusqlite::Row<'_>) -> TelegramChannel {
    let id_str: String = row.get(0).unwrap_or_default();
    let mission_id_str: String = row.get(1).unwrap_or_default();
    let allowed_chat_ids_json: String = row.get(4).unwrap_or_else(|_| "[]".to_string());
    let trigger_mode_str: String = row.get(5).unwrap_or_else(|_| "direct_message".to_string());
    let default_ws_str: Option<String> = row.get(15).unwrap_or_default();

    TelegramChannel {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        bot_token: row.get(2).unwrap_or_default(),
        bot_username: row.get(3).unwrap_or_default(),
        allowed_chat_ids: serde_json::from_str(&allowed_chat_ids_json).unwrap_or_default(),
        trigger_mode: serde_json::from_value(serde_json::Value::String(trigger_mode_str))
            .unwrap_or_default(),
        active: row.get::<_, i32>(6).unwrap_or(0) != 0,
        webhook_secret: row.get(7).unwrap_or_default(),
        instructions: row.get(8).unwrap_or_default(),
        auto_create_missions: row.get::<_, i32>(11).unwrap_or(0) != 0,
        default_backend: row.get(12).unwrap_or_default(),
        default_model_override: row.get(13).unwrap_or_default(),
        default_model_effort: row.get(14).unwrap_or_default(),
        default_workspace_id: default_ws_str.and_then(|s| Uuid::parse_str(&s).ok()),
        default_config_profile: row.get(16).unwrap_or_default(),
        default_agent: row.get(17).unwrap_or_default(),
        created_at: row.get(9).unwrap_or_default(),
        updated_at: row.get(10).unwrap_or_default(),
    }
}

pub(super) fn parse_telegram_scheduled_status(raw: String) -> TelegramScheduledMessageStatus {
    match raw.as_str() {
        "sent" => TelegramScheduledMessageStatus::Sent,
        "failed" => TelegramScheduledMessageStatus::Failed,
        _ => TelegramScheduledMessageStatus::Pending,
    }
}

pub(super) fn row_to_telegram_scheduled_message(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramScheduledMessage, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let source_mission_id_str: Option<String> = row.get(2)?;
    let status_str: String = row.get(8)?;

    Ok(TelegramScheduledMessage {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        source_mission_id: source_mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        chat_id: row.get(3)?,
        chat_title: row.get(4)?,
        text: row.get(5)?,
        send_at: row.get(6)?,
        sent_at: row.get(7)?,
        status: parse_telegram_scheduled_status(status_str),
        last_error: row.get(9)?,
        created_at: row.get(10)?,
    })
}

pub(super) fn parse_telegram_structured_memory_kind(raw: String) -> TelegramStructuredMemoryKind {
    match raw.as_str() {
        "fact" => TelegramStructuredMemoryKind::Fact,
        "task" => TelegramStructuredMemoryKind::Task,
        "preference" => TelegramStructuredMemoryKind::Preference,
        _ => TelegramStructuredMemoryKind::Note,
    }
}

pub(super) fn parse_telegram_structured_memory_scope(raw: String) -> TelegramStructuredMemoryScope {
    match raw.as_str() {
        "user" => TelegramStructuredMemoryScope::User,
        "channel" => TelegramStructuredMemoryScope::Channel,
        _ => TelegramStructuredMemoryScope::Chat,
    }
}

pub(super) fn parse_telegram_action_execution_kind(raw: String) -> TelegramActionExecutionKind {
    match raw.as_str() {
        "reminder" => TelegramActionExecutionKind::Reminder,
        _ => TelegramActionExecutionKind::Send,
    }
}

pub(super) fn parse_telegram_action_execution_status(raw: String) -> TelegramActionExecutionStatus {
    match raw.as_str() {
        "sent" => TelegramActionExecutionStatus::Sent,
        "failed" => TelegramActionExecutionStatus::Failed,
        _ => TelegramActionExecutionStatus::Pending,
    }
}

pub(super) fn parse_telegram_conversation_message_direction(
    raw: String,
) -> TelegramConversationMessageDirection {
    match raw.as_str() {
        "outbound" => TelegramConversationMessageDirection::Outbound,
        _ => TelegramConversationMessageDirection::Inbound,
    }
}

pub(super) fn parse_telegram_workflow_kind(raw: String) -> TelegramWorkflowKind {
    match raw.as_str() {
        "request_reply" => TelegramWorkflowKind::RequestReply,
        _ => TelegramWorkflowKind::RequestReply,
    }
}

pub(super) fn parse_telegram_workflow_status(raw: String) -> TelegramWorkflowStatus {
    match raw.as_str() {
        "relayed_to_origin" => TelegramWorkflowStatus::RelayedToOrigin,
        "completed" => TelegramWorkflowStatus::Completed,
        "failed" => TelegramWorkflowStatus::Failed,
        "cancelled" => TelegramWorkflowStatus::Cancelled,
        _ => TelegramWorkflowStatus::WaitingExternal,
    }
}

pub(super) fn row_to_telegram_structured_memory(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramStructuredMemoryEntry, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let mission_id_str: Option<String> = row.get(3)?;
    let scope_str: String = row.get(4)?;
    let kind_str: String = row.get(5)?;
    Ok(TelegramStructuredMemoryEntry {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        chat_id: row.get(2)?,
        mission_id: mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        scope: parse_telegram_structured_memory_scope(scope_str),
        kind: parse_telegram_structured_memory_kind(kind_str),
        label: row.get(6)?,
        value: row.get(7)?,
        subject_user_id: row.get(8)?,
        subject_username: row.get(9)?,
        subject_display_name: row.get(10)?,
        source_message_id: row.get(11)?,
        source_role: row.get(12)?,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
    })
}

pub(super) fn row_to_telegram_memory_search_rank(
    row: &rusqlite::Row<'_>,
) -> Result<(String, f64), rusqlite::Error> {
    Ok((row.get(0)?, row.get(1)?))
}

pub(super) fn row_to_telegram_action_execution(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramActionExecution, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let source_mission_id_str: Option<String> = row.get(2)?;
    let action_kind_str: String = row.get(6)?;
    let scheduled_message_id_str: Option<String> = row.get(11)?;
    let status_str: String = row.get(12)?;

    Ok(TelegramActionExecution {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        source_mission_id: source_mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        source_chat_id: row.get(3)?,
        target_chat_id: row.get(4)?,
        target_chat_title: row.get(5)?,
        action_kind: parse_telegram_action_execution_kind(action_kind_str),
        target_kind: row.get(7)?,
        target_value: row.get(8)?,
        text: row.get(9)?,
        delay_seconds: row.get::<_, i64>(10)?.max(0) as u64,
        scheduled_message_id: scheduled_message_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        status: parse_telegram_action_execution_status(status_str),
        last_error: row.get(13)?,
        created_at: row.get(14)?,
        updated_at: row.get(15)?,
    })
}

pub(super) fn row_to_telegram_conversation(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramConversation, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let mission_id_str: Option<String> = row.get(3)?;
    Ok(TelegramConversation {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        chat_id: row.get(2)?,
        mission_id: mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        chat_title: row.get(4)?,
        chat_type: row.get(5)?,
        last_message_at: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

pub(super) fn row_to_telegram_conversation_message(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramConversationMessage, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let conversation_id_str: String = row.get(1)?;
    let channel_id_str: String = row.get(2)?;
    let mission_id_str: Option<String> = row.get(4)?;
    let workflow_id_str: Option<String> = row.get(5)?;
    let direction_str: String = row.get(7)?;
    Ok(TelegramConversationMessage {
        id: parse_uuid_or_nil(&id_str),
        conversation_id: parse_uuid_or_nil(&conversation_id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        chat_id: row.get(3)?,
        mission_id: mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        workflow_id: workflow_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        telegram_message_id: row.get(6)?,
        direction: parse_telegram_conversation_message_direction(direction_str),
        role: row.get(8)?,
        sender_user_id: row.get(9)?,
        sender_username: row.get(10)?,
        sender_display_name: row.get(11)?,
        reply_to_message_id: row.get(12)?,
        text: row.get(13)?,
        created_at: row.get(14)?,
    })
}

pub(super) fn row_to_telegram_workflow(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramWorkflow, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(1)?;
    let origin_conversation_id_str: String = row.get(2)?;
    let origin_mission_id_str: Option<String> = row.get(4)?;
    let target_conversation_id_str: Option<String> = row.get(5)?;
    let kind_str: String = row.get(12)?;
    let status_str: String = row.get(13)?;
    Ok(TelegramWorkflow {
        id: parse_uuid_or_nil(&id_str),
        channel_id: parse_uuid_or_nil(&channel_id_str),
        origin_conversation_id: parse_uuid_or_nil(&origin_conversation_id_str),
        origin_chat_id: row.get(3)?,
        origin_mission_id: origin_mission_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        target_conversation_id: target_conversation_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        target_chat_id: row.get(6)?,
        target_chat_title: row.get(7)?,
        target_chat_type: row.get(8)?,
        target_request_message_id: row.get(9)?,
        initiated_by_user_id: row.get(10)?,
        initiated_by_username: row.get(11)?,
        kind: parse_telegram_workflow_kind(kind_str),
        status: parse_telegram_workflow_status(status_str),
        request_text: row.get(14)?,
        latest_reply_text: row.get(15)?,
        summary: row.get(16)?,
        last_error: row.get(17)?,
        created_at: row.get(18)?,
        updated_at: row.get(19)?,
        completed_at: row.get(20)?,
    })
}

pub(super) fn row_to_telegram_workflow_event(
    row: &rusqlite::Row<'_>,
) -> Result<TelegramWorkflowEvent, rusqlite::Error> {
    let id_str: String = row.get(0)?;
    let workflow_id_str: String = row.get(1)?;
    let conversation_id_str: Option<String> = row.get(2)?;
    Ok(TelegramWorkflowEvent {
        id: parse_uuid_or_nil(&id_str),
        workflow_id: parse_uuid_or_nil(&workflow_id_str),
        conversation_id: conversation_id_str
            .as_deref()
            .map(parse_uuid_or_nil)
            .filter(|id| !id.is_nil()),
        event_type: row.get(3)?,
        payload_json: row.get(4)?,
        created_at: row.get(5)?,
    })
}
impl SqliteMissionStore {
    pub(super) fn ensure_telegram_memory_search_index(conn: &Connection) -> Result<(), String> {
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS telegram_structured_memory_fts
             USING fts5(
                entry_id UNINDEXED,
                channel_id UNINDEXED,
                chat_id UNINDEXED,
                scope UNINDEXED,
                subject_user_id UNINDEXED,
                search_text,
                tokenize = 'unicode61 remove_diacritics 2'
             );",
        )
        .map_err(|e| {
            format!(
                "Failed to create telegram_structured_memory_fts table: {}",
                e
            )
        })
    }

    pub(super) fn rebuild_telegram_memory_search_index(conn: &Connection) -> Result<(), String> {
        Self::ensure_telegram_memory_search_index(conn)?;

        conn.execute("DELETE FROM telegram_structured_memory_fts", [])
            .map_err(|e| format!("Failed to clear telegram memory search index: {}", e))?;

        let mut stmt = conn
            .prepare(
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory",
            )
            .map_err(|e| format!("Failed to scan telegram structured memory: {}", e))?;

        let entries = stmt
            .query_map([], row_to_telegram_structured_memory)
            .map_err(|e| format!("Failed to query telegram structured memory: {}", e))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Failed to collect telegram structured memory rows: {}", e))?;

        for entry in entries {
            conn.execute(
                "INSERT INTO telegram_structured_memory_fts (
                    entry_id, channel_id, chat_id, scope, subject_user_id, search_text
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    entry.id.to_string(),
                    entry.channel_id.to_string(),
                    entry.chat_id,
                    match entry.scope {
                        TelegramStructuredMemoryScope::Chat => "chat",
                        TelegramStructuredMemoryScope::User => "user",
                        TelegramStructuredMemoryScope::Channel => "channel",
                    },
                    entry.subject_user_id,
                    build_telegram_memory_search_text(&entry),
                ],
            )
            .map_err(|e| format!("Failed to populate telegram memory search index: {}", e))?;
        }

        Ok(())
    }

    pub(super) fn upsert_telegram_memory_search_index_entry(
        conn: &Connection,
        entry: &TelegramStructuredMemoryEntry,
    ) -> Result<(), String> {
        Self::ensure_telegram_memory_search_index(conn)?;

        conn.execute(
            "DELETE FROM telegram_structured_memory_fts WHERE entry_id = ?1",
            params![entry.id.to_string()],
        )
        .map_err(|e| {
            format!(
                "Failed to replace telegram memory search index entry: {}",
                e
            )
        })?;

        conn.execute(
            "INSERT INTO telegram_structured_memory_fts (
                entry_id, channel_id, chat_id, scope, subject_user_id, search_text
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                entry.id.to_string(),
                entry.channel_id.to_string(),
                entry.chat_id,
                match entry.scope {
                    TelegramStructuredMemoryScope::Chat => "chat",
                    TelegramStructuredMemoryScope::User => "user",
                    TelegramStructuredMemoryScope::Channel => "channel",
                },
                entry.subject_user_id,
                build_telegram_memory_search_text(entry),
            ],
        )
        .map_err(|e| format!("Failed to upsert telegram memory search index entry: {}", e))?;

        Ok(())
    }

    pub(super) fn load_telegram_structured_memory_for_upsert(
        conn: &Connection,
        entry: &TelegramStructuredMemoryEntry,
        scope: &str,
        kind: &str,
        normalized_label: &str,
    ) -> Result<Option<TelegramStructuredMemoryEntry>, String> {
        let sql = match entry.scope {
            TelegramStructuredMemoryScope::User if entry.subject_user_id.is_some() => {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND scope = ?2
                   AND subject_user_id = ?3
                   AND kind = ?4
                   AND normalized_label = ?5
                 LIMIT 1"
            }
            TelegramStructuredMemoryScope::Channel => {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND scope = ?2
                   AND kind = ?3
                   AND normalized_label = ?4
                 LIMIT 1"
            }
            _ => {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND scope = ?2
                   AND chat_id = ?3
                   AND kind = ?4
                   AND normalized_label = ?5
                 LIMIT 1"
            }
        };

        let mut stmt = conn.prepare(sql).map_err(|e| {
            format!(
                "Failed to prepare telegram structured memory lookup after upsert: {}",
                e
            )
        })?;

        let entry = match entry.scope {
            TelegramStructuredMemoryScope::User if entry.subject_user_id.is_some() => stmt
                .query_row(
                    params![
                        entry.channel_id.to_string(),
                        scope,
                        entry.subject_user_id,
                        kind,
                        normalized_label
                    ],
                    row_to_telegram_structured_memory,
                )
                .optional(),
            TelegramStructuredMemoryScope::Channel => stmt
                .query_row(
                    params![entry.channel_id.to_string(), scope, kind, normalized_label],
                    row_to_telegram_structured_memory,
                )
                .optional(),
            _ => stmt
                .query_row(
                    params![
                        entry.channel_id.to_string(),
                        scope,
                        entry.chat_id,
                        kind,
                        normalized_label
                    ],
                    row_to_telegram_structured_memory,
                )
                .optional(),
        }
        .map_err(|e| {
            format!(
                "Failed to load telegram structured memory row after upsert: {}",
                e
            )
        })?;

        Ok(entry)
    }
}
impl SqliteMissionStore {
    // === Telegram Channel methods ===

    pub(super) async fn create_telegram_channel(
        &self,
        channel: TelegramChannel,
    ) -> Result<TelegramChannel, String> {
        let conn = self.conn.clone();
        let c = channel.clone();
        let allowed_chat_ids_json =
            serde_json::to_string(&c.allowed_chat_ids).unwrap_or_else(|_| "[]".to_string());
        let trigger_mode_str = serde_json::to_value(&c.trigger_mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "direct_message".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_channels (id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
                params![
                    c.id.to_string(),
                    c.mission_id.to_string(),
                    c.bot_token,
                    c.bot_username,
                    allowed_chat_ids_json,
                    trigger_mode_str,
                    c.active as i32,
                    c.webhook_secret,
                    c.instructions,
                    c.created_at,
                    c.updated_at,
                    c.auto_create_missions as i32,
                    c.default_backend,
                    c.default_model_override,
                    c.default_model_effort,
                    c.default_workspace_id.map(|u| u.to_string()),
                    c.default_config_profile,
                    c.default_agent,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;

        Ok(channel)
    }

    pub(super) async fn get_telegram_channel(
        &self,
        id: Uuid,
    ) -> Result<Option<TelegramChannel>, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                 FROM telegram_channels WHERE id = ?1",
                params![id_str],
                |row| Ok(row_to_telegram_channel(row)),
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_channels(
        &self,
        mission_id: Uuid,
    ) -> Result<Vec<TelegramChannel>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                     FROM telegram_channels WHERE mission_id = ?1 ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let channels = stmt
                .query_map(params![mission_id_str], |row| Ok(row_to_telegram_channel(row)))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(channels)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_all_active_telegram_channels(
        &self,
    ) -> Result<Vec<TelegramChannel>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                     FROM telegram_channels WHERE active = 1",
                )
                .map_err(|e| e.to_string())?;
            let channels = stmt
                .query_map([], |row| Ok(row_to_telegram_channel(row)))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(channels)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_telegram_channel(
        &self,
        channel: TelegramChannel,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let allowed_chat_ids_json =
            serde_json::to_string(&channel.allowed_chat_ids).unwrap_or_else(|_| "[]".to_string());
        let trigger_mode_str = serde_json::to_value(&channel.trigger_mode)
            .ok()
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "direct_message".to_string());

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_channels SET bot_token = ?1, bot_username = ?2, allowed_chat_ids = ?3, trigger_mode = ?4, active = ?5, webhook_secret = ?6, instructions = ?7, updated_at = ?8, auto_create_missions = ?10, default_backend = ?11, default_model_override = ?12, default_model_effort = ?13, default_workspace_id = ?14, default_config_profile = ?15, default_agent = ?16 WHERE id = ?9",
                params![
                    channel.bot_token,
                    channel.bot_username,
                    allowed_chat_ids_json,
                    trigger_mode_str,
                    channel.active as i32,
                    channel.webhook_secret,
                    channel.instructions,
                    channel.updated_at,
                    channel.id.to_string(),
                    channel.auto_create_missions as i32,
                    channel.default_backend,
                    channel.default_model_override,
                    channel.default_model_effort,
                    channel.default_workspace_id.map(|u| u.to_string()),
                    channel.default_config_profile,
                    channel.default_agent,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn delete_telegram_channel(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let deleted = conn
                .execute(
                    "DELETE FROM telegram_channels WHERE id = ?1",
                    params![id_str],
                )
                .map_err(|e| e.to_string())?;
            Ok(deleted > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_all_telegram_channels(&self) -> Result<Vec<TelegramChannel>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, mission_id, bot_token, bot_username, allowed_chat_ids, trigger_mode, active, webhook_secret, instructions, created_at, updated_at, auto_create_missions, default_backend, default_model_override, default_model_effort, default_workspace_id, default_config_profile, default_agent
                     FROM telegram_channels ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let channels = stmt
                .query_map([], |row| Ok(row_to_telegram_channel(row)))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(channels)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_telegram_user(
        &self,
        user: TelegramUser,
    ) -> Result<TelegramUser, String> {
        let conn = self.conn.clone();
        let u = user.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_users
                 (id, telegram_user_id, username, display_name, role, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    username = excluded.username,
                    display_name = excluded.display_name,
                    role = excluded.role,
                    updated_at = excluded.updated_at",
                params![
                    u.id.to_string(),
                    u.telegram_user_id,
                    u.username,
                    u.display_name,
                    telegram_user_role_to_str(u.role),
                    u.created_at,
                    u.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(user)
    }

    pub(super) async fn get_telegram_user(
        &self,
        telegram_user_id: i64,
    ) -> Result<Option<TelegramUser>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, telegram_user_id, username, display_name, role, created_at, updated_at
                 FROM telegram_users WHERE telegram_user_id = ?1",
                params![telegram_user_id],
                row_to_telegram_user,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_or_create_telegram_user_cursor(
        &self,
        telegram_user_id: i64,
    ) -> Result<TelegramUserCursor, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            if let Some(cursor) = conn
                .query_row(
                    "SELECT id, telegram_user_id, last_status_at, last_dashboard_seen_at,
                            last_alert_ack_at, last_digest_at,
                            last_seen_event_sequence_by_mission_json, created_at, updated_at
                     FROM telegram_user_cursors WHERE telegram_user_id = ?1",
                    params![telegram_user_id],
                    row_to_telegram_user_cursor,
                )
                .optional()
                .map_err(|e| e.to_string())?
            {
                return Ok(cursor);
            }

            let now = now_string();
            let cursor = TelegramUserCursor {
                id: Uuid::new_v4(),
                telegram_user_id,
                last_status_at: None,
                last_dashboard_seen_at: None,
                last_alert_ack_at: None,
                last_digest_at: None,
                last_seen_event_sequence_by_mission_json: "{}".to_string(),
                created_at: now.clone(),
                updated_at: now,
            };
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_status_at, last_dashboard_seen_at, last_alert_ack_at,
                  last_digest_at, last_seen_event_sequence_by_mission_json, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    cursor.id.to_string(),
                    cursor.telegram_user_id,
                    cursor.last_status_at,
                    cursor.last_dashboard_seen_at,
                    cursor.last_alert_ack_at,
                    cursor.last_digest_at,
                    cursor.last_seen_event_sequence_by_mission_json,
                    cursor.created_at,
                    cursor.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(cursor)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_telegram_user_last_status_at(
        &self,
        telegram_user_id: i64,
        last_status_at: &str,
        last_seen_event_sequence_by_mission_json: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let last_status_at = last_status_at.to_string();
        let sequence_json = last_seen_event_sequence_by_mission_json.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_status_at, last_seen_event_sequence_by_mission_json, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    last_status_at = excluded.last_status_at,
                    last_seen_event_sequence_by_mission_json = excluded.last_seen_event_sequence_by_mission_json,
                    updated_at = excluded.updated_at",
                params![
                    Uuid::new_v4().to_string(),
                    telegram_user_id,
                    last_status_at,
                    sequence_json,
                    now,
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_telegram_user_last_digest_at(
        &self,
        telegram_user_id: i64,
        last_digest_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let last_digest_at = last_digest_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_digest_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    last_digest_at = excluded.last_digest_at,
                    updated_at = excluded.updated_at",
                params![
                    Uuid::new_v4().to_string(),
                    telegram_user_id,
                    last_digest_at,
                    now,
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_telegram_user_last_alert_ack_at(
        &self,
        telegram_user_id: i64,
        last_alert_ack_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let last_alert_ack_at = last_alert_ack_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now = now_string();
            conn.execute(
                "INSERT INTO telegram_user_cursors
                 (id, telegram_user_id, last_alert_ack_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    last_alert_ack_at = excluded.last_alert_ack_at,
                    updated_at = excluded.updated_at",
                params![
                    Uuid::new_v4().to_string(),
                    telegram_user_id,
                    last_alert_ack_at,
                    now,
                    now,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_telegram_mission_subscription(
        &self,
        subscription: TelegramMissionSubscription,
    ) -> Result<TelegramMissionSubscription, String> {
        let conn = self.conn.clone();
        let s = subscription.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_mission_subscriptions
                 (id, telegram_user_id, mission_id, interest_level, reason, expires_at, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(telegram_user_id, mission_id) DO UPDATE SET
                    interest_level = excluded.interest_level,
                    reason = excluded.reason,
                    expires_at = excluded.expires_at,
                    updated_at = excluded.updated_at",
                params![
                    s.id.to_string(),
                    s.telegram_user_id,
                    s.mission_id.to_string(),
                    telegram_interest_to_str(s.interest_level),
                    s.reason,
                    s.expires_at,
                    s.created_at,
                    s.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(subscription)
    }

    pub(super) async fn list_telegram_mission_subscriptions(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<TelegramMissionSubscription>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, mission_id, interest_level, reason, expires_at,
                            created_at, updated_at
                     FROM telegram_mission_subscriptions
                     WHERE telegram_user_id = ?1
                     ORDER BY updated_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                    params![telegram_user_id],
                    row_to_telegram_mission_subscription,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_alert_preference(
        &self,
        preference: TelegramAlertPreference,
    ) -> Result<TelegramAlertPreference, String> {
        let conn = self.conn.clone();
        let p = preference.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_alert_preferences
                 (id, telegram_user_id, scope, scope_value, rule_text, enabled,
                  created_from_message_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    p.id.to_string(),
                    p.telegram_user_id,
                    p.scope,
                    p.scope_value,
                    p.rule_text,
                    if p.enabled { 1 } else { 0 },
                    p.created_from_message_id,
                    p.created_at,
                    p.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(preference)
    }

    pub(super) async fn list_telegram_alert_preferences(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<TelegramAlertPreference>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, scope, scope_value, rule_text, enabled,
                            created_from_message_id, created_at, updated_at
                     FROM telegram_alert_preferences
                     WHERE telegram_user_id = ?1 AND enabled = 1
                     ORDER BY updated_at DESC, created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![telegram_user_id], row_to_telegram_alert_preference)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_alert_if_absent(
        &self,
        alert: TelegramAlert,
    ) -> Result<Option<TelegramAlert>, String> {
        let conn = self.conn.clone();
        let a = alert.clone();
        let inserted = tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "INSERT OR IGNORE INTO telegram_alerts
                     (id, telegram_user_id, mission_id, event_kind, importance, title, body,
                      status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                    params![
                        a.id.to_string(),
                        a.telegram_user_id,
                        a.mission_id.map(|id| id.to_string()),
                        a.event_kind,
                        a.importance,
                        a.title,
                        a.body,
                        a.status,
                        a.telegram_message_id,
                        a.last_error,
                        a.created_at,
                        a.sent_at,
                        a.acknowledged_at,
                    ],
                )
                .map_err(|e| e.to_string())?;
            Ok::<_, String>(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(inserted.then_some(alert))
    }

    pub(super) async fn list_pending_telegram_alerts(
        &self,
        telegram_user_id: i64,
        limit: usize,
    ) -> Result<Vec<TelegramAlert>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, mission_id, event_kind, importance, title, body,
                            status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at
                     FROM telegram_alerts
                     WHERE telegram_user_id = ?1 AND status = 'pending'
                     ORDER BY created_at ASC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![telegram_user_id, limit as i64], row_to_telegram_alert)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_alerts_for_missions(
        &self,
        mission_ids: &[Uuid],
    ) -> Result<Vec<TelegramAlert>, String> {
        if mission_ids.is_empty() {
            return Ok(vec![]);
        }
        let conn = self.conn.clone();
        let id_strings: Vec<String> = mission_ids.iter().map(|id| id.to_string()).collect();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let placeholders = vec!["?"; id_strings.len()].join(",");
            let sql = format!(
                "SELECT id, telegram_user_id, mission_id, event_kind, importance, title, body,
                        status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at
                 FROM telegram_alerts
                 WHERE mission_id IN ({placeholders})
                 ORDER BY created_at DESC"
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                    rusqlite::params_from_iter(id_strings.iter()),
                    row_to_telegram_alert,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(rows)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn mark_telegram_alert_sent(
        &self,
        id: Uuid,
        telegram_message_id: Option<i64>,
        sent_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let sent_at = sent_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_alerts
                 SET status = 'sent', telegram_message_id = ?2, sent_at = ?3, last_error = NULL
                 WHERE id = ?1",
                params![id.to_string(), telegram_message_id, sent_at],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_telegram_alert_by_message_id(
        &self,
        telegram_user_id: i64,
        telegram_message_id: i64,
    ) -> Result<Option<TelegramAlert>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, telegram_user_id, mission_id, event_kind, importance, title, body,
                            status, telegram_message_id, last_error, created_at, sent_at, acknowledged_at
                     FROM telegram_alerts
                     WHERE telegram_user_id = ?1
                       AND telegram_message_id = ?2
                     ORDER BY sent_at DESC, created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let alerts = stmt
                .query_map(params![telegram_user_id, telegram_message_id], row_to_telegram_alert)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            if alerts.is_empty() {
                return Ok(None);
            }
            let first_mission_id = alerts[0].mission_id;
            if alerts
                .iter()
                .any(|alert| alert.mission_id != first_mission_id)
            {
                return Err("ambiguous_digest_reply".to_string());
            }
            Ok(alerts.into_iter().next())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn acknowledge_pending_telegram_alerts_for_mission(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        acknowledged_at: &str,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let acknowledged_at = acknowledged_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "UPDATE telegram_alerts
                     SET status = 'acknowledged', acknowledged_at = ?3, last_error = NULL
                     WHERE telegram_user_id = ?1
                       AND mission_id = ?2
                       AND status = 'pending'",
                    params![telegram_user_id, mission_id.to_string(), acknowledged_at],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn acknowledge_pending_telegram_alert(
        &self,
        telegram_user_id: i64,
        alert_id: Uuid,
        acknowledged_at: &str,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let acknowledged_at = acknowledged_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "UPDATE telegram_alerts
                     SET status = 'acknowledged', acknowledged_at = ?3, last_error = NULL
                     WHERE telegram_user_id = ?1
                       AND id = ?2
                       AND status = 'pending'",
                    params![telegram_user_id, alert_id.to_string(), acknowledged_at],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn mark_telegram_alert_failed(
        &self,
        id: Uuid,
        error: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let error = error.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_alerts
                 SET status = 'pending', last_error = ?2
                 WHERE id = ?1 AND status = 'pending'",
                params![id.to_string(), error],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn recover_stale_telegram_alerts(
        &self,
        before: &str,
        limit: usize,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let before = before.to_string();
        let limit = limit.clamp(1, 10_000) as i64;
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let ids = {
                let mut stmt = conn
                    .prepare(
                        "SELECT id
                         FROM telegram_alerts
                         WHERE status = 'pending'
                           AND last_error IS NOT NULL
                           AND created_at <= ?1
                         ORDER BY created_at ASC
                         LIMIT ?2",
                    )
                    .map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map(params![before, limit], |row| row.get::<_, String>(0))
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                rows
            };

            for id in &ids {
                conn.execute(
                    "UPDATE telegram_alerts
                     SET last_error = NULL
                     WHERE id = ?1 AND status = 'pending'",
                    params![id],
                )
                .map_err(|e| e.to_string())?;
            }

            Ok(ids.len())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn refresh_pending_telegram_alert_body(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        event_kind: &str,
        title: &str,
        body: &str,
        importance: &str,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let event_kind = event_kind.to_string();
        let title = title.to_string();
        let body = body.to_string();
        let importance = importance.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let changed = conn
                .execute(
                    "UPDATE telegram_alerts
                     SET title = ?4, body = ?5, importance = ?6
                     WHERE telegram_user_id = ?1
                       AND mission_id = ?2
                       AND event_kind = ?3
                       AND status = 'pending'",
                    params![
                        telegram_user_id,
                        mission_id.to_string(),
                        event_kind,
                        title,
                        body,
                        importance,
                    ],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn consolidate_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<usize, String> {
        let conn = self.conn.clone();
        let channel_id = channel_id.to_string();
        let limit = limit.clamp(1, 10_000) as i64;
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "WITH ranked AS (
                         SELECT id, channel_id, scope, chat_id, subject_user_id, normalized_label,
                                ROW_NUMBER() OVER (
                                    PARTITION BY channel_id, scope, chat_id,
                                                 COALESCE(subject_user_id, -9223372036854775808),
                                                 normalized_label
                                    ORDER BY updated_at DESC, created_at DESC
                                ) AS row_rank,
                                MAX(updated_at) OVER (
                                    PARTITION BY channel_id, scope, chat_id,
                                                 COALESCE(subject_user_id, -9223372036854775808),
                                                 normalized_label
                                ) AS group_updated_at
                         FROM telegram_structured_memory
                         WHERE channel_id = ?1
                           AND kind IN ('fact', 'preference')
                           AND normalized_label IS NOT NULL
                           AND source_role = 'user'
                     ),
                     selected_groups AS (
                         SELECT DISTINCT channel_id, scope, chat_id, subject_user_id,
                                         normalized_label, group_updated_at
                         FROM ranked
                         ORDER BY group_updated_at DESC
                         LIMIT ?2
                     )
                     SELECT ranked.id
                     FROM ranked
                     WHERE ranked.row_rank > 1
                       AND EXISTS (
                           SELECT 1
                           FROM selected_groups
                           WHERE selected_groups.channel_id = ranked.channel_id
                             AND selected_groups.scope = ranked.scope
                             AND selected_groups.chat_id = ranked.chat_id
                             AND COALESCE(selected_groups.subject_user_id, -9223372036854775808)
                                 = COALESCE(ranked.subject_user_id, -9223372036854775808)
                             AND selected_groups.normalized_label = ranked.normalized_label
                       )",
                )
                .map_err(|e| e.to_string())?;
            let delete_ids = stmt
                .query_map(params![channel_id, limit], |row| row.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

            for id in &delete_ids {
                conn.execute(
                    "DELETE FROM telegram_structured_memory WHERE id = ?1",
                    params![id],
                )
                .map_err(|e| e.to_string())?;
                conn.execute(
                    "DELETE FROM telegram_structured_memory_fts WHERE entry_id = ?1",
                    params![id],
                )
                .map_err(|e| e.to_string())?;
            }

            Ok(delete_ids.len())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_telegram_chat_mission(
        &self,
        channel_id: Uuid,
        chat_id: i64,
    ) -> Result<Option<TelegramChatMission>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, channel_id, chat_id, mission_id, chat_title, created_at
                 FROM telegram_chat_missions WHERE channel_id = ?1 AND chat_id = ?2",
                params![channel_id_str, chat_id],
                |row| {
                    let id_str: String = row.get(0)?;
                    let ch_id_str: String = row.get(1)?;
                    let m_id_str: String = row.get(3)?;
                    Ok(TelegramChatMission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        channel_id: Uuid::parse_str(&ch_id_str).unwrap_or_default(),
                        chat_id: row.get(2)?,
                        mission_id: Uuid::parse_str(&m_id_str).unwrap_or_default(),
                        chat_title: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_chat_mission(
        &self,
        mapping: TelegramChatMission,
    ) -> Result<TelegramChatMission, String> {
        let conn = self.conn.clone();
        let m = mapping.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_chat_missions (id, channel_id, chat_id, mission_id, chat_title, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    m.id.to_string(),
                    m.channel_id.to_string(),
                    m.chat_id,
                    m.mission_id.to_string(),
                    m.chat_title,
                    m.created_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(mapping)
    }

    pub(super) async fn update_telegram_chat_mission_title(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        chat_title: Option<String>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_chat_missions
                 SET chat_title = ?3
                 WHERE channel_id = ?1 AND chat_id = ?2",
                params![channel_id_str, chat_id, chat_title],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_telegram_chat_mission_by_mission_id(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<TelegramChatMission>, String> {
        let conn = self.conn.clone();
        let mission_id_str = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.query_row(
                "SELECT id, channel_id, chat_id, mission_id, chat_title, created_at
                 FROM telegram_chat_missions WHERE mission_id = ?1 LIMIT 1",
                params![mission_id_str],
                |row| {
                    let id_str: String = row.get(0)?;
                    let channel_id_str: String = row.get(1)?;
                    let mission_id_str2: String = row.get(3)?;
                    Ok(TelegramChatMission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        channel_id: Uuid::parse_str(&channel_id_str).unwrap_or_default(),
                        chat_id: row.get(2)?,
                        mission_id: Uuid::parse_str(&mission_id_str2).unwrap_or_default(),
                        chat_title: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_chat_missions(
        &self,
        channel_id: Uuid,
    ) -> Result<Vec<TelegramChatMission>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, created_at
                     FROM telegram_chat_missions WHERE channel_id = ?1 ORDER BY created_at DESC",
                )
                .map_err(|e| e.to_string())?;
            let mappings = stmt
                .query_map(params![channel_id_str], |row| {
                    let id_str: String = row.get(0)?;
                    let ch_id_str: String = row.get(1)?;
                    let m_id_str: String = row.get(3)?;
                    Ok(TelegramChatMission {
                        id: Uuid::parse_str(&id_str).unwrap_or_default(),
                        channel_id: Uuid::parse_str(&ch_id_str).unwrap_or_default(),
                        chat_id: row.get(2)?,
                        mission_id: Uuid::parse_str(&m_id_str).unwrap_or_default(),
                        chat_title: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                })
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(mappings)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_scheduled_message(
        &self,
        message: TelegramScheduledMessage,
    ) -> Result<TelegramScheduledMessage, String> {
        let conn = self.conn.clone();
        let msg = message.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_scheduled_messages (
                    id, channel_id, source_mission_id, chat_id, chat_title, text,
                    send_at, sent_at, status, last_error, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    msg.id.to_string(),
                    msg.channel_id.to_string(),
                    msg.source_mission_id.map(|id| id.to_string()),
                    msg.chat_id,
                    msg.chat_title,
                    msg.text,
                    msg.send_at,
                    msg.sent_at,
                    match msg.status {
                        TelegramScheduledMessageStatus::Pending => "pending",
                        TelegramScheduledMessageStatus::Sent => "sent",
                        TelegramScheduledMessageStatus::Failed => "failed",
                    },
                    msg.last_error,
                    msg.created_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(message)
    }

    pub(super) async fn list_due_telegram_scheduled_messages(
        &self,
        channel_id: Uuid,
        send_at: &str,
        limit: usize,
    ) -> Result<Vec<TelegramScheduledMessage>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let send_at = send_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, source_mission_id, chat_id, chat_title, text,
                            send_at, sent_at, status, last_error, created_at
                     FROM telegram_scheduled_messages
                     WHERE channel_id = ?1
                       AND status = 'pending'
                       AND send_at <= ?2
                     ORDER BY send_at ASC
                     LIMIT ?3",
                )
                .map_err(|e| e.to_string())?;
            let messages = stmt
                .query_map(
                    params![channel_id_str, send_at, limit as i64],
                    row_to_telegram_scheduled_message,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(messages)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_scheduled_messages(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramScheduledMessage>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = if chat_id.is_some() {
                "SELECT id, channel_id, source_mission_id, chat_id, chat_title, text,
                        send_at, sent_at, status, last_error, created_at
                 FROM telegram_scheduled_messages
                 WHERE channel_id = ?1 AND chat_id = ?2
                 ORDER BY created_at DESC
                 LIMIT ?3"
            } else {
                "SELECT id, channel_id, source_mission_id, chat_id, chat_title, text,
                        send_at, sent_at, status, last_error, created_at
                 FROM telegram_scheduled_messages
                 WHERE channel_id = ?1
                 ORDER BY created_at DESC
                 LIMIT ?2"
            };
            let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
            let limit_i64 = limit as i64;
            let messages = if let Some(chat_id) = chat_id {
                stmt.query_map(
                    params![channel_id_str, chat_id, limit_i64],
                    row_to_telegram_scheduled_message,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            } else {
                stmt.query_map(
                    params![channel_id_str, limit_i64],
                    row_to_telegram_scheduled_message,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            };
            Ok(messages)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn claim_telegram_scheduled_message(&self, id: Uuid) -> Result<bool, String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let now = Utc::now().to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE telegram_scheduled_messages
                     SET status = 'sending', sent_at = ?2
                     WHERE id = ?1 AND status = 'pending'",
                    params![id_str, now],
                )
                .map_err(|e| e.to_string())?;
            Ok(updated > 0)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn recover_stale_sending_scheduled_messages(
        &self,
        max_age_secs: i64,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        let cutoff = (chrono::Utc::now() - chrono::Duration::seconds(max_age_secs)).to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE telegram_scheduled_messages
                     SET status = 'pending', sent_at = NULL
                     WHERE status = 'sending'
                       AND sent_at IS NOT NULL AND sent_at < ?1",
                    params![cutoff],
                )
                .map_err(|e| e.to_string())?;
            Ok(updated as u32)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn mark_telegram_scheduled_message_sent(
        &self,
        id: Uuid,
        sent_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let sent_at = sent_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_scheduled_messages
                 SET status = 'sent', sent_at = ?1, last_error = NULL
                 WHERE id = ?2",
                params![sent_at, id_str],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn mark_telegram_scheduled_message_failed(
        &self,
        id: Uuid,
        error: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let id_str = id.to_string();
        let error = error.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_scheduled_messages
                 SET status = 'failed', last_error = ?1
                 WHERE id = ?2",
                params![error, id_str],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_telegram_structured_memory(
        &self,
        entry: TelegramStructuredMemoryEntry,
    ) -> Result<TelegramStructuredMemoryEntry, String> {
        let conn = self.conn.clone();
        let entry_clone = entry.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let normalized_label = entry_clone
                .label
                .as_deref()
                .map(|label| label.trim().to_lowercase())
                .filter(|label| !label.is_empty());
            let kind = match entry_clone.kind {
                TelegramStructuredMemoryKind::Fact => "fact",
                TelegramStructuredMemoryKind::Note => "note",
                TelegramStructuredMemoryKind::Task => "task",
                TelegramStructuredMemoryKind::Preference => "preference",
            };
            let scope = match entry_clone.scope {
                TelegramStructuredMemoryScope::Chat => "chat",
                TelegramStructuredMemoryScope::User => "user",
                TelegramStructuredMemoryScope::Channel => "channel",
            };

            let is_upsertable_kind = matches!(
                entry_clone.kind,
                TelegramStructuredMemoryKind::Fact | TelegramStructuredMemoryKind::Preference
            ) && normalized_label.is_some();

            if is_upsertable_kind {
                let updated = match entry_clone.scope.clone() {
                    TelegramStructuredMemoryScope::User
                        if entry_clone.subject_user_id.is_some() =>
                    {
                        conn.execute(
                            "UPDATE telegram_structured_memory
                             SET mission_id = ?1,
                                 chat_id = ?2,
                                 value = ?3,
                                 subject_username = ?4,
                                 subject_display_name = ?5,
                                 source_message_id = ?6,
                                 source_role = ?7,
                                 updated_at = ?8
                             WHERE channel_id = ?9
                               AND scope = ?10
                               AND subject_user_id = ?11
                               AND kind = ?12
                               AND normalized_label = ?13",
                            params![
                                entry_clone.mission_id.map(|id| id.to_string()),
                                entry_clone.chat_id,
                                entry_clone.value.clone(),
                                entry_clone.subject_username.clone(),
                                entry_clone.subject_display_name.clone(),
                                entry_clone.source_message_id,
                                entry_clone.source_role.clone(),
                                entry_clone.updated_at.clone(),
                                entry_clone.channel_id.to_string(),
                                scope,
                                entry_clone.subject_user_id,
                                kind,
                                normalized_label,
                            ],
                        )
                        .map_err(|e| e.to_string())?;
                        conn.changes() > 0
                    }
                    TelegramStructuredMemoryScope::Channel => {
                        conn.execute(
                            "UPDATE telegram_structured_memory
                             SET mission_id = ?1,
                                 chat_id = ?2,
                                 value = ?3,
                                 source_message_id = ?4,
                                 source_role = ?5,
                                 updated_at = ?6
                             WHERE channel_id = ?7
                               AND scope = ?8
                               AND kind = ?9
                               AND normalized_label = ?10",
                            params![
                                entry_clone.mission_id.map(|id| id.to_string()),
                                entry_clone.chat_id,
                                entry_clone.value.clone(),
                                entry_clone.source_message_id,
                                entry_clone.source_role.clone(),
                                entry_clone.updated_at.clone(),
                                entry_clone.channel_id.to_string(),
                                scope,
                                kind,
                                normalized_label,
                            ],
                        )
                        .map_err(|e| e.to_string())?;
                        conn.changes() > 0
                    }
                    _ => {
                        conn.execute(
                            "UPDATE telegram_structured_memory
                             SET mission_id = ?1,
                                 value = ?2,
                                 source_message_id = ?3,
                                 source_role = ?4,
                                 updated_at = ?5
                             WHERE channel_id = ?6
                               AND scope = ?7
                               AND chat_id = ?8
                               AND kind = ?9
                               AND normalized_label = ?10",
                            params![
                                entry_clone.mission_id.map(|id| id.to_string()),
                                entry_clone.value.clone(),
                                entry_clone.source_message_id,
                                entry_clone.source_role.clone(),
                                entry_clone.updated_at.clone(),
                                entry_clone.channel_id.to_string(),
                                scope,
                                entry_clone.chat_id,
                                kind,
                                normalized_label,
                            ],
                        )
                        .map_err(|e| e.to_string())?;
                        conn.changes() > 0
                    }
                };

                if updated {
                    let updated_entry = Self::load_telegram_structured_memory_for_upsert(
                        &conn,
                        &entry_clone,
                        scope,
                        kind,
                        normalized_label.as_deref().unwrap_or_default(),
                    )?
                    .ok_or_else(|| {
                        "Updated telegram structured memory row could not be reloaded".to_string()
                    })?;
                    Self::upsert_telegram_memory_search_index_entry(&conn, &updated_entry)?;
                    return Ok::<_, String>(());
                }
            }

            conn.execute(
                "INSERT INTO telegram_structured_memory (
                    id, channel_id, chat_id, mission_id, scope, kind, label, normalized_label, value,
                    subject_user_id, subject_username, subject_display_name,
                    source_message_id, source_role, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
                params![
                    entry_clone.id.to_string(),
                    entry_clone.channel_id.to_string(),
                    entry_clone.chat_id,
                    entry_clone.mission_id.map(|id| id.to_string()),
                    scope,
                    kind,
                    entry_clone.label,
                    normalized_label,
                    entry_clone.value,
                    entry_clone.subject_user_id,
                    entry_clone.subject_username,
                    entry_clone.subject_display_name,
                    entry_clone.source_message_id,
                    entry_clone.source_role,
                    entry_clone.created_at,
                    entry_clone.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Self::upsert_telegram_memory_search_index_entry(&conn, &entry_clone)?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(entry)
    }

    pub(super) async fn list_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        subject_user_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Build WHERE clause dynamically so all filters are applied
            // before the LIMIT truncation.
            let mut where_clauses = vec!["channel_id = ?1".to_string()];
            let mut param_idx = 2u32;
            if chat_id.is_some() {
                where_clauses.push(format!("chat_id = ?{}", param_idx));
                param_idx += 1;
            }
            if subject_user_id.is_some() {
                where_clauses.push(format!("subject_user_id = ?{}", param_idx));
                param_idx += 1;
            }
            let sql = format!(
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE {}
                 ORDER BY updated_at DESC
                 LIMIT ?{}",
                where_clauses.join(" AND "),
                param_idx,
            );
            let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
            // Build params vec dynamically matching the WHERE clause above.
            let mut params_vec: Vec<Box<dyn rusqlite::types::ToSql>> =
                vec![Box::new(channel_id_str)];
            if let Some(cid) = chat_id {
                params_vec.push(Box::new(cid));
            }
            if let Some(suid) = subject_user_id {
                params_vec.push(Box::new(suid));
            }
            params_vec.push(Box::new(limit as i64));
            let param_refs: Vec<&dyn rusqlite::types::ToSql> =
                params_vec.iter().map(|p| p.as_ref()).collect();
            let entries = stmt
                .query_map(param_refs.as_slice(), row_to_telegram_structured_memory)
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn search_telegram_structured_memory(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let query = query.trim().to_lowercase();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = if chat_id.is_some() {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND chat_id = ?2
                   AND (
                     instr(lower(coalesce(label, '')), ?3) > 0
                     OR instr(lower(value), ?3) > 0
                   )
                 ORDER BY updated_at DESC
                 LIMIT ?4"
            } else {
                "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                        subject_user_id, subject_username, subject_display_name,
                        source_message_id, source_role, created_at, updated_at
                 FROM telegram_structured_memory
                 WHERE channel_id = ?1
                   AND (
                     instr(lower(coalesce(label, '')), ?2) > 0
                     OR instr(lower(value), ?2) > 0
                   )
                 ORDER BY updated_at DESC
                 LIMIT ?3"
            };
            let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
            let entries = if let Some(chat_id) = chat_id {
                stmt.query_map(
                    params![channel_id_str, chat_id, query, limit as i64],
                    row_to_telegram_structured_memory,
                )
            } else {
                stmt.query_map(
                    params![channel_id_str, query, limit as i64],
                    row_to_telegram_structured_memory,
                )
            }
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn search_telegram_structured_memory_hybrid(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        subject_user_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemorySearchHit>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let normalized_query = normalize_search_text(query.trim());
        let query_tokens = tokenize_search_text(query);
        let core_query = query_tokens.join(" ");
        let fts_query = build_fts_query_from_tokens(&query_tokens, &normalized_query);

        tokio::task::spawn_blocking(move || {
            if normalized_query.is_empty() {
                return Ok(Vec::new());
            }

            let conn = conn.blocking_lock();
            let candidate_limit = (limit.max(8) * 8).min(TELEGRAM_MEMORY_SEARCH_MAX_CANDIDATES);

            let mut stmt = match chat_id {
                Some(_) => conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'chat' AND chat_id = ?2)
                         OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                       )
                     ORDER BY updated_at DESC
                     LIMIT ?4",
                ),
                None if subject_user_id.is_some() => conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'user' AND subject_user_id = ?2)
                       )
                     ORDER BY updated_at DESC
                     LIMIT ?3",
                ),
                None => conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                     ORDER BY updated_at DESC
                     LIMIT ?2",
                ),
            }
            .map_err(|e| e.to_string())?;

            let mut candidates = match (chat_id, subject_user_id) {
                (Some(chat_id), subject_user_id) => stmt.query_map(
                    params![
                        channel_id_str.as_str(),
                        chat_id,
                        subject_user_id,
                        candidate_limit as i64
                    ],
                    row_to_telegram_structured_memory,
                ),
                (None, Some(subject_user_id)) => stmt.query_map(
                    params![
                        channel_id_str.as_str(),
                        subject_user_id,
                        candidate_limit as i64
                    ],
                    row_to_telegram_structured_memory,
                ),
                (None, None) => stmt.query_map(
                    params![channel_id_str.as_str(), candidate_limit as i64],
                    row_to_telegram_structured_memory,
                ),
            }
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;

            let mut fts_scores: HashMap<Uuid, f64> = HashMap::new();
            if let Some(fts_query) = fts_query {
                let mut stmt = match chat_id {
                    Some(_) => conn.prepare(
                        "SELECT entry_id, bm25(telegram_structured_memory_fts) AS rank
                         FROM telegram_structured_memory_fts
                         WHERE channel_id = ?1
                           AND (
                             scope = 'channel'
                             OR (scope = 'chat' AND chat_id = ?2)
                             OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                           )
                           AND telegram_structured_memory_fts MATCH ?4
                         ORDER BY rank
                         LIMIT ?5",
                    ),
                    None if subject_user_id.is_some() => conn.prepare(
                        "SELECT entry_id, bm25(telegram_structured_memory_fts) AS rank
                         FROM telegram_structured_memory_fts
                         WHERE channel_id = ?1
                           AND (
                             scope = 'channel'
                             OR (scope = 'user' AND subject_user_id = ?2)
                           )
                           AND telegram_structured_memory_fts MATCH ?3
                         ORDER BY rank
                         LIMIT ?4",
                    ),
                    None => conn.prepare(
                        "SELECT entry_id, bm25(telegram_structured_memory_fts) AS rank
                         FROM telegram_structured_memory_fts
                         WHERE channel_id = ?1
                           AND telegram_structured_memory_fts MATCH ?2
                         ORDER BY rank
                         LIMIT ?3",
                    ),
                }
                .map_err(|e| e.to_string())?;

                let rows = match (chat_id, subject_user_id) {
                    (Some(chat_id), subject_user_id) => stmt.query_map(
                        params![
                            channel_id_str.as_str(),
                            chat_id,
                            subject_user_id,
                            fts_query.as_str(),
                            limit.max(8) as i64
                        ],
                        row_to_telegram_memory_search_rank,
                    ),
                    (None, Some(subject_user_id)) => stmt.query_map(
                        params![
                            channel_id_str.as_str(),
                            subject_user_id,
                            fts_query.as_str(),
                            limit.max(8) as i64
                        ],
                        row_to_telegram_memory_search_rank,
                    ),
                    (None, None) => stmt.query_map(
                        params![
                            channel_id_str.as_str(),
                            fts_query.as_str(),
                            limit.max(8) as i64
                        ],
                        row_to_telegram_memory_search_rank,
                    ),
                }
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;

                for (entry_id, rank) in rows {
                    let entry_uuid = parse_uuid_or_nil(&entry_id);
                    if entry_uuid.is_nil() {
                        continue;
                    }
                    let weight = 18.0 / (1.0 + rank.abs());
                    fts_scores.insert(entry_uuid, weight);
                }
            }

            // Inject FTS-matched entries that fell outside the recency window
            // so older but highly relevant memories are not silently dropped.
            let candidate_ids: std::collections::HashSet<Uuid> =
                candidates.iter().map(|e| e.id).collect();
            for fts_id in fts_scores.keys() {
                if candidate_ids.contains(fts_id) {
                    continue;
                }
                let id_str = fts_id.to_string();
                if let Ok(mut stmt) = conn.prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE id = ?1",
                ) {
                    if let Ok(mut rows) =
                        stmt.query_map(params![id_str], row_to_telegram_structured_memory)
                    {
                        if let Some(Ok(entry)) = rows.next() {
                            candidates.push(entry);
                        }
                    }
                }
            }

            let mut hits = candidates
                .into_iter()
                .filter_map(|entry| {
                    score_memory_entry(
                        &entry,
                        &normalized_query,
                        &core_query,
                        &query_tokens,
                        fts_scores.get(&entry.id).copied(),
                    )
                })
                .collect::<Vec<_>>();

            hits.sort_by(|left, right| {
                right
                    .score
                    .total_cmp(&left.score)
                    .then_with(|| {
                        scope_rank(&left.entry.scope).cmp(&scope_rank(&right.entry.scope))
                    })
                    .then_with(|| right.entry.updated_at.cmp(&left.entry.updated_at))
            });
            hits.truncate(limit);
            Ok(hits)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_memory_context(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        subject_user_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'chat' AND chat_id = ?2)
                         OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                       )
                     ORDER BY
                       CASE scope
                         WHEN 'chat' THEN 0
                         WHEN 'user' THEN 1
                         ELSE 2
                       END,
                       updated_at DESC
                     LIMIT ?4",
                )
                .map_err(|e| e.to_string())?;
            let entries = stmt
                .query_map(
                    params![channel_id_str, chat_id, subject_user_id, limit as i64],
                    row_to_telegram_structured_memory,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn search_telegram_memory_context(
        &self,
        channel_id: Uuid,
        chat_id: i64,
        subject_user_id: Option<i64>,
        query: &str,
        limit: usize,
    ) -> Result<Vec<TelegramStructuredMemoryEntry>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let query = query.trim().to_lowercase();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, scope, kind, label, value,
                            subject_user_id, subject_username, subject_display_name,
                            source_message_id, source_role, created_at, updated_at
                     FROM telegram_structured_memory
                     WHERE channel_id = ?1
                       AND (
                         scope = 'channel'
                         OR (scope = 'chat' AND chat_id = ?2)
                         OR (?3 IS NOT NULL AND scope = 'user' AND subject_user_id = ?3)
                       )
                       AND (
                         instr(lower(coalesce(label, '')), ?4) > 0
                         OR instr(lower(value), ?4) > 0
                         OR instr(lower(coalesce(subject_display_name, '')), ?4) > 0
                         OR instr(lower(coalesce(subject_username, '')), ?4) > 0
                       )
                     ORDER BY
                       CASE scope
                         WHEN 'chat' THEN 0
                         WHEN 'user' THEN 1
                         ELSE 2
                       END,
                       updated_at DESC
                     LIMIT ?5",
                )
                .map_err(|e| e.to_string())?;
            let entries = stmt
                .query_map(
                    params![
                        channel_id_str,
                        chat_id,
                        subject_user_id,
                        query,
                        limit as i64
                    ],
                    row_to_telegram_structured_memory,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?;
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_action_execution(
        &self,
        execution: TelegramActionExecution,
    ) -> Result<TelegramActionExecution, String> {
        let conn = self.conn.clone();
        let execution_clone = execution.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_action_executions (
                    id, channel_id, source_mission_id, source_chat_id, target_chat_id, target_chat_title,
                    action_kind, target_kind, target_value, text, delay_seconds, scheduled_message_id,
                    status, last_error, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
                params![
                    execution_clone.id.to_string(),
                    execution_clone.channel_id.to_string(),
                    execution_clone.source_mission_id.map(|id| id.to_string()),
                    execution_clone.source_chat_id,
                    execution_clone.target_chat_id,
                    execution_clone.target_chat_title,
                    match execution_clone.action_kind {
                        TelegramActionExecutionKind::Send => "send",
                        TelegramActionExecutionKind::Reminder => "reminder",
                    },
                    execution_clone.target_kind,
                    execution_clone.target_value,
                    execution_clone.text,
                    execution_clone.delay_seconds as i64,
                    execution_clone.scheduled_message_id.map(|id| id.to_string()),
                    match execution_clone.status {
                        TelegramActionExecutionStatus::Pending => "pending",
                        TelegramActionExecutionStatus::Sent => "sent",
                        TelegramActionExecutionStatus::Failed => "failed",
                    },
                    execution_clone.last_error,
                    execution_clone.created_at,
                    execution_clone.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(execution)
    }

    pub(super) async fn list_telegram_action_executions(
        &self,
        channel_id: Uuid,
        chat_id: Option<i64>,
        limit: usize,
    ) -> Result<Vec<TelegramActionExecution>, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let sql = if chat_id.is_some() {
                "SELECT id, channel_id, source_mission_id, source_chat_id, target_chat_id,
                        target_chat_title, action_kind, target_kind, target_value, text,
                        delay_seconds, scheduled_message_id, status, last_error, created_at, updated_at
                 FROM telegram_action_executions
                 WHERE channel_id = ?1 AND target_chat_id = ?2
                 ORDER BY updated_at DESC
                 LIMIT ?3"
            } else {
                "SELECT id, channel_id, source_mission_id, source_chat_id, target_chat_id,
                        target_chat_title, action_kind, target_kind, target_value, text,
                        delay_seconds, scheduled_message_id, status, last_error, created_at, updated_at
                 FROM telegram_action_executions
                 WHERE channel_id = ?1
                 ORDER BY updated_at DESC
                 LIMIT ?2"
            };
            let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
            let limit_i64 = limit as i64;
            let entries = if let Some(chat_id) = chat_id {
                stmt.query_map(
                    params![channel_id_str, chat_id, limit_i64],
                    row_to_telegram_action_execution,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            } else {
                stmt.query_map(
                    params![channel_id_str, limit_i64],
                    row_to_telegram_action_execution,
                )
                .map_err(|e| e.to_string())?
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())?
            };
            Ok(entries)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn mark_telegram_action_execution_by_scheduled_message(
        &self,
        scheduled_message_id: Uuid,
        status: TelegramActionExecutionStatus,
        last_error: Option<&str>,
        updated_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let scheduled_message_id = scheduled_message_id.to_string();
        let updated_at = updated_at.to_string();
        let last_error = last_error.map(ToOwned::to_owned);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_action_executions
                 SET status = ?1,
                     last_error = ?2,
                     updated_at = ?3
                 WHERE scheduled_message_id = ?4",
                params![
                    match status {
                        TelegramActionExecutionStatus::Pending => "pending",
                        TelegramActionExecutionStatus::Sent => "sent",
                        TelegramActionExecutionStatus::Failed => "failed",
                    },
                    last_error,
                    updated_at,
                    scheduled_message_id,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_telegram_conversation(
        &self,
        conversation: TelegramConversation,
    ) -> Result<TelegramConversation, String> {
        let conn = self.conn.clone();
        let conversation_clone = conversation.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_conversations (
                    id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(channel_id, chat_id) DO UPDATE SET
                    mission_id = excluded.mission_id,
                    chat_title = coalesce(excluded.chat_title, telegram_conversations.chat_title),
                    chat_type = coalesce(excluded.chat_type, telegram_conversations.chat_type),
                    last_message_at = coalesce(excluded.last_message_at, telegram_conversations.last_message_at),
                    updated_at = excluded.updated_at",
                params![
                    conversation_clone.id.to_string(),
                    conversation_clone.channel_id.to_string(),
                    conversation_clone.chat_id,
                    conversation_clone.mission_id.map(|id| id.to_string()),
                    conversation_clone.chat_title.clone(),
                    conversation_clone.chat_type.clone(),
                    conversation_clone.last_message_at.clone(),
                    conversation_clone.created_at.clone(),
                    conversation_clone.updated_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;

            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                     FROM telegram_conversations
                     WHERE channel_id = ?1 AND chat_id = ?2",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![
                    conversation_clone.channel_id.to_string(),
                    conversation_clone.chat_id
                ],
                row_to_telegram_conversation,
            )
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_telegram_conversation_by_chat(
        &self,
        channel_id: Uuid,
        chat_id: i64,
    ) -> Result<Option<TelegramConversation>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                     FROM telegram_conversations
                     WHERE channel_id = ?1 AND chat_id = ?2",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![channel_id.to_string(), chat_id],
                row_to_telegram_conversation,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_conversations(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramConversation>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, chat_id, mission_id, chat_title, chat_type, last_message_at, created_at, updated_at
                     FROM telegram_conversations
                     WHERE channel_id = ?1
                     ORDER BY coalesce(last_message_at, updated_at) DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                params![channel_id.to_string(), limit as i64],
                row_to_telegram_conversation,
            )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_conversation_message(
        &self,
        message: TelegramConversationMessage,
    ) -> Result<TelegramConversationMessage, String> {
        let conn = self.conn.clone();
        let message_clone = message.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_conversation_messages (
                    id, conversation_id, channel_id, chat_id, mission_id, workflow_id, telegram_message_id,
                    direction, role, sender_user_id, sender_username, sender_display_name,
                    reply_to_message_id, text, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
                params![
                    message_clone.id.to_string(),
                    message_clone.conversation_id.to_string(),
                    message_clone.channel_id.to_string(),
                    message_clone.chat_id,
                    message_clone.mission_id.map(|id| id.to_string()),
                    message_clone.workflow_id.map(|id| id.to_string()),
                    message_clone.telegram_message_id,
                    match message_clone.direction {
                        TelegramConversationMessageDirection::Inbound => "inbound",
                        TelegramConversationMessageDirection::Outbound => "outbound",
                    },
                    message_clone.role.clone(),
                    message_clone.sender_user_id,
                    message_clone.sender_username.clone(),
                    message_clone.sender_display_name.clone(),
                    message_clone.reply_to_message_id,
                    message_clone.text.clone(),
                    message_clone.created_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;
            conn.execute(
                "UPDATE telegram_conversations
                 SET last_message_at = ?1, updated_at = ?1
                 WHERE id = ?2",
                params![message_clone.created_at, message_clone.conversation_id.to_string()],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(message_clone)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_conversation_messages(
        &self,
        conversation_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramConversationMessage>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, conversation_id, channel_id, chat_id, mission_id, workflow_id, telegram_message_id,
                            direction, role, sender_user_id, sender_username, sender_display_name,
                            reply_to_message_id, text, created_at
                     FROM telegram_conversation_messages
                     WHERE conversation_id = ?1
                     ORDER BY created_at DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                params![conversation_id.to_string(), limit as i64],
                row_to_telegram_conversation_message,
            )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_workflow(
        &self,
        workflow: TelegramWorkflow,
    ) -> Result<TelegramWorkflow, String> {
        let conn = self.conn.clone();
        let workflow_clone = workflow.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_workflows (
                    id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                    target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                    target_request_message_id, initiated_by_user_id, initiated_by_username, kind,
                    status, request_text, latest_reply_text, summary, last_error, created_at,
                    updated_at, completed_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)",
                params![
                    workflow_clone.id.to_string(),
                    workflow_clone.channel_id.to_string(),
                    workflow_clone.origin_conversation_id.to_string(),
                    workflow_clone.origin_chat_id,
                    workflow_clone.origin_mission_id.map(|id| id.to_string()),
                    workflow_clone.target_conversation_id.map(|id| id.to_string()),
                    workflow_clone.target_chat_id,
                    workflow_clone.target_chat_title.clone(),
                    workflow_clone.target_chat_type.clone(),
                    workflow_clone.target_request_message_id,
                    workflow_clone.initiated_by_user_id,
                    workflow_clone.initiated_by_username.clone(),
                    match workflow_clone.kind {
                        TelegramWorkflowKind::RequestReply => "request_reply",
                    },
                    match workflow_clone.status {
                        TelegramWorkflowStatus::WaitingExternal => "waiting_external",
                        TelegramWorkflowStatus::RelayedToOrigin => "relayed_to_origin",
                        TelegramWorkflowStatus::Completed => "completed",
                        TelegramWorkflowStatus::Failed => "failed",
                        TelegramWorkflowStatus::Cancelled => "cancelled",
                    },
                    workflow_clone.request_text.clone(),
                    workflow_clone.latest_reply_text.clone(),
                    workflow_clone.summary.clone(),
                    workflow_clone.last_error.clone(),
                    workflow_clone.created_at.clone(),
                    workflow_clone.updated_at.clone(),
                    workflow_clone.completed_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(workflow_clone)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn update_telegram_workflow(
        &self,
        workflow: TelegramWorkflow,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE telegram_workflows
                 SET target_conversation_id = ?1,
                     target_chat_id = ?2,
                     target_chat_title = ?3,
                     target_chat_type = ?4,
                     target_request_message_id = ?5,
                     status = ?6,
                     latest_reply_text = ?7,
                     summary = ?8,
                     last_error = ?9,
                     updated_at = ?10,
                     completed_at = ?11
                 WHERE id = ?12",
                params![
                    workflow.target_conversation_id.map(|id| id.to_string()),
                    workflow.target_chat_id,
                    workflow.target_chat_title,
                    workflow.target_chat_type,
                    workflow.target_request_message_id,
                    match workflow.status {
                        TelegramWorkflowStatus::WaitingExternal => "waiting_external",
                        TelegramWorkflowStatus::RelayedToOrigin => "relayed_to_origin",
                        TelegramWorkflowStatus::Completed => "completed",
                        TelegramWorkflowStatus::Failed => "failed",
                        TelegramWorkflowStatus::Cancelled => "cancelled",
                    },
                    workflow.latest_reply_text,
                    workflow.summary,
                    workflow.last_error,
                    workflow.updated_at,
                    workflow.completed_at,
                    workflow.id.to_string(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn timeout_stale_telegram_workflows(
        &self,
        max_age_secs: i64,
    ) -> Result<u32, String> {
        let conn = self.conn.clone();
        let now = now_string();
        // Calculate the cutoff timestamp in Rust (RFC 3339 format sorts lexicographically)
        let cutoff = chrono::Utc::now() - chrono::Duration::seconds(max_age_secs);
        let cutoff_str = cutoff.to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let updated = conn
                .execute(
                    "UPDATE telegram_workflows
                     SET status = 'failed',
                         last_error = 'Timed out waiting for external reply',
                         updated_at = ?1,
                         completed_at = ?1
                     WHERE status = 'waiting_external'
                       AND updated_at < ?2",
                    params![now, cutoff_str],
                )
                .map_err(|e| e.to_string())?;
            Ok(updated as u32)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn register_webhook_update(
        &self,
        channel_id: Uuid,
        update_id: i64,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let channel_id_str = channel_id.to_string();
        let now = now_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // INSERT OR IGNORE: if the row already exists, nothing happens
            // and changes() returns 0.
            let inserted = conn
                .execute(
                    "INSERT OR IGNORE INTO telegram_webhook_dedup (channel_id, update_id, seen_at)
                     VALUES (?1, ?2, ?3)",
                    params![channel_id_str, update_id, now],
                )
                .map_err(|e| e.to_string())?;
            Ok(inserted > 0)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn cleanup_webhook_dedup(&self, max_age_secs: i64) -> Result<u32, String> {
        let conn = self.conn.clone();
        let cutoff = (chrono::Utc::now() - chrono::Duration::seconds(max_age_secs)).to_rfc3339();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let deleted = conn
                .execute(
                    "DELETE FROM telegram_webhook_dedup
                     WHERE seen_at < ?1",
                    params![cutoff],
                )
                .map_err(|e| e.to_string())?;
            Ok(deleted as u32)
        })
        .await
        .map_err(|e| format!("Task join error: {}", e))?
    }

    pub(super) async fn list_telegram_workflows(
        &self,
        channel_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramWorkflow>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                            target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                            target_request_message_id, initiated_by_user_id, initiated_by_username,
                            kind, status, request_text, latest_reply_text, summary, last_error,
                            created_at, updated_at, completed_at
                     FROM telegram_workflows
                     WHERE channel_id = ?1
                     ORDER BY updated_at DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                params![channel_id.to_string(), limit as i64],
                row_to_telegram_workflow,
            )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_pending_telegram_workflow_for_target_chat(
        &self,
        channel_id: Uuid,
        target_chat_id: i64,
    ) -> Result<Option<TelegramWorkflow>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                            target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                            target_request_message_id, initiated_by_user_id, initiated_by_username,
                            kind, status, request_text, latest_reply_text, summary, last_error,
                            created_at, updated_at, completed_at
                     FROM telegram_workflows
                     WHERE channel_id = ?1
                       AND target_chat_id = ?2
                       AND status = 'waiting_external'
                     ORDER BY updated_at DESC
                     LIMIT 1",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![channel_id.to_string(), target_chat_id],
                row_to_telegram_workflow,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_pending_telegram_workflow_for_target_message(
        &self,
        channel_id: Uuid,
        target_chat_id: i64,
        request_message_id: i64,
    ) -> Result<Option<TelegramWorkflow>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, channel_id, origin_conversation_id, origin_chat_id, origin_mission_id,
                            target_conversation_id, target_chat_id, target_chat_title, target_chat_type,
                            target_request_message_id, initiated_by_user_id, initiated_by_username,
                            kind, status, request_text, latest_reply_text, summary, last_error,
                            created_at, updated_at, completed_at
                     FROM telegram_workflows
                     WHERE channel_id = ?1
                       AND target_chat_id = ?2
                       AND target_request_message_id = ?3
                       AND status = 'waiting_external'
                     ORDER BY updated_at DESC
                     LIMIT 1",
                )
                .map_err(|e| e.to_string())?;
            stmt.query_row(
                params![channel_id.to_string(), target_chat_id, request_message_id],
                row_to_telegram_workflow,
            )
            .optional()
            .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn create_telegram_workflow_event(
        &self,
        event: TelegramWorkflowEvent,
    ) -> Result<TelegramWorkflowEvent, String> {
        let conn = self.conn.clone();
        let event_clone = event.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO telegram_workflow_events (
                    id, workflow_id, conversation_id, event_type, payload_json, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    event_clone.id.to_string(),
                    event_clone.workflow_id.to_string(),
                    event_clone.conversation_id.map(|id| id.to_string()),
                    event_clone.event_type.clone(),
                    event_clone.payload_json.clone(),
                    event_clone.created_at.clone(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(event_clone)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_telegram_workflow_events(
        &self,
        workflow_id: Uuid,
        limit: usize,
    ) -> Result<Vec<TelegramWorkflowEvent>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, workflow_id, conversation_id, event_type, payload_json, created_at
                     FROM telegram_workflow_events
                     WHERE workflow_id = ?1
                     ORDER BY created_at DESC
                     LIMIT ?2",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(
                    params![workflow_id.to_string(), limit as i64],
                    row_to_telegram_workflow_event,
                )
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| e.to_string())?
    }
}
