//! Paloma decisions, scheduler jobs, mission cards, cooldowns and preferences.

use super::*;

pub(super) fn row_to_paloma_decision(row: &rusqlite::Row<'_>) -> rusqlite::Result<PalomaDecision> {
    let id_str: String = row.get(0)?;
    let mission_id_str: Option<String> = row.get(2)?;
    let allowed: i32 = row.get(7)?;
    Ok(PalomaDecision {
        id: Uuid::parse_str(&id_str).unwrap_or_default(),
        event_source: row.get(1)?,
        mission_id: mission_id_str.and_then(|id| Uuid::parse_str(&id).ok()),
        user_id: row.get(3)?,
        channel: row.get(4)?,
        reason_code: row.get(5)?,
        proposed_action: row.get(6)?,
        allowed: allowed != 0,
        suppression_reason: row.get(8)?,
        policy_snapshot_json: row.get(9)?,
        generated_text_hash: row.get(10)?,
        generated_text_preview: row.get(11)?,
        created_at: row.get(12)?,
    })
}

pub(super) fn row_to_paloma_user_preferences(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<PalomaUserPreferences> {
    let failure_override: i64 = row.get(6)?;
    Ok(PalomaUserPreferences {
        telegram_user_id: row.get(0)?,
        timezone: row.get(1)?,
        quiet_hours_start: row.get(2)?,
        quiet_hours_end: row.get(3)?,
        max_interrupts_per_hour: row.get(4)?,
        max_interrupts_per_day: row.get(5)?,
        failure_override_quiet: failure_override != 0,
        alert_class_overrides_json: row.get(7)?,
        mission_overrides_json: row.get(8)?,
        digest_cadence: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

pub(super) fn row_to_paloma_cooldown_state(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<PalomaCooldownState> {
    let mission_id_str: String = row.get(0)?;
    Ok(PalomaCooldownState {
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        alert_class: row.get(1)?,
        telegram_user_id: row.get(2)?,
        last_sent_at: row.get(3)?,
        next_eligible_at: row.get(4)?,
        backoff_step: row.get(5)?,
    })
}

pub(super) fn row_to_paloma_mission_card(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<PalomaMissionCard> {
    let mission_id_str: String = row.get(0)?;
    let channel_id_str: String = row.get(2)?;
    let archived: i64 = row.get(9)?;
    Ok(PalomaMissionCard {
        mission_id: Uuid::parse_str(&mission_id_str).unwrap_or_default(),
        telegram_user_id: row.get(1)?,
        channel_id: Uuid::parse_str(&channel_id_str).unwrap_or_default(),
        chat_id: row.get(3)?,
        message_id: row.get(4)?,
        content_hash: row.get(5)?,
        anchor_ts: row.get(6)?,
        last_edit_ts: row.get(7)?,
        version: row.get(8)?,
        archived: archived != 0,
    })
}

pub(super) fn row_to_paloma_scheduler_job(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<PalomaSchedulerJob> {
    Ok(PalomaSchedulerJob {
        name: row.get(0)?,
        lease_owner: row.get(1)?,
        lease_expires_at: row.get(2)?,
        last_started_at: row.get(3)?,
        last_finished_at: row.get(4)?,
        last_error: row.get(5)?,
        run_count: row.get(6)?,
        updated_at: row.get(7)?,
    })
}
impl SqliteMissionStore {
    pub(super) async fn create_paloma_decision(
        &self,
        decision: PalomaDecision,
    ) -> Result<PalomaDecision, String> {
        let conn = self.conn.clone();
        let stored = decision.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_decisions (
                    id, event_source, mission_id, user_id, channel, reason_code,
                    proposed_action, allowed, suppression_reason, policy_snapshot_json,
                    generated_text_hash, generated_text_preview, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    decision.id.to_string(),
                    decision.event_source,
                    decision.mission_id.map(|id| id.to_string()),
                    decision.user_id,
                    decision.channel,
                    decision.reason_code,
                    decision.proposed_action,
                    if decision.allowed { 1 } else { 0 },
                    decision.suppression_reason,
                    decision.policy_snapshot_json,
                    decision.generated_text_hash,
                    decision.generated_text_preview,
                    decision.created_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            // Only the latest decisions are ever read. Without a bound, one
            // week of a looping scheduler left 16 million rows (13.6 GB with
            // indexes) in the production database.
            if conn.last_insert_rowid() % PALOMA_DECISION_PRUNE_EVERY == 0 {
                conn.execute(
                    "DELETE FROM paloma_decisions WHERE created_at < (
                         SELECT created_at FROM paloma_decisions
                         ORDER BY created_at DESC LIMIT 1 OFFSET ?1)",
                    params![PALOMA_DECISIONS_KEPT],
                )
                .map_err(|e| e.to_string())?;
            }
            Ok(stored)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_paloma_decisions(
        &self,
        limit: usize,
    ) -> Result<Vec<PalomaDecision>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT id, event_source, mission_id, user_id, channel, reason_code,
                            proposed_action, allowed, suppression_reason, policy_snapshot_json,
                            generated_text_hash, generated_text_preview, created_at
                     FROM paloma_decisions
                     ORDER BY created_at DESC
                     LIMIT ?1",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![limit as i64], row_to_paloma_decision)
                .map_err(|e| e.to_string())?;
            let mut decisions = Vec::new();
            for row in rows {
                decisions.push(row.map_err(|e| e.to_string())?);
            }
            Ok(decisions)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn claim_paloma_scheduler_job(
        &self,
        name: &str,
        lease_owner: &str,
        now: &str,
        lease_expires_at: &str,
    ) -> Result<bool, String> {
        let conn = self.conn.clone();
        let name = name.to_string();
        let lease_owner = lease_owner.to_string();
        let now = now.to_string();
        let lease_expires_at = lease_expires_at.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT OR IGNORE INTO paloma_scheduler_jobs
                 (name, run_count, updated_at)
                 VALUES (?1, 0, ?2)",
                params![name, now],
            )
            .map_err(|e| e.to_string())?;
            let changed = conn
                .execute(
                    "UPDATE paloma_scheduler_jobs
                     SET lease_owner = ?2,
                         lease_expires_at = ?4,
                         last_started_at = ?3,
                         updated_at = ?3
                     WHERE name = ?1
                       AND (lease_expires_at IS NULL OR lease_expires_at <= ?3 OR lease_owner = ?2)",
                    params![name, lease_owner, now, lease_expires_at],
                )
                .map_err(|e| e.to_string())?;
            Ok(changed > 0)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn finish_paloma_scheduler_job(
        &self,
        name: &str,
        lease_owner: &str,
        finished_at: &str,
        error: Option<&str>,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let name = name.to_string();
        let lease_owner = lease_owner.to_string();
        let finished_at = finished_at.to_string();
        let error = error.map(ToOwned::to_owned);
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE paloma_scheduler_jobs
                 SET lease_owner = NULL,
                     lease_expires_at = NULL,
                     last_finished_at = ?3,
                     last_error = ?4,
                     run_count = run_count + 1,
                     updated_at = ?3
                 WHERE name = ?1 AND lease_owner = ?2",
                params![name, lease_owner, finished_at, error],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_paloma_scheduler_jobs(
        &self,
    ) -> Result<Vec<PalomaSchedulerJob>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT name, lease_owner, lease_expires_at, last_started_at,
                            last_finished_at, last_error, run_count, updated_at
                     FROM paloma_scheduler_jobs
                     ORDER BY name ASC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map([], row_to_paloma_scheduler_job)
                .map_err(|e| e.to_string())?;
            let mut jobs = Vec::new();
            for row in rows {
                jobs.push(row.map_err(|e| e.to_string())?);
            }
            Ok(jobs)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_paloma_mission_card(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<PalomaMissionCard>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT mission_id, telegram_user_id, channel_id, chat_id, message_id,
                            content_hash, anchor_ts, last_edit_ts, version, archived
                     FROM paloma_mission_cards
                     WHERE mission_id = ?1",
                )
                .map_err(|e| e.to_string())?;
            let mut rows = stmt
                .query_map(params![mission_id.to_string()], row_to_paloma_mission_card)
                .map_err(|e| e.to_string())?;
            match rows.next() {
                Some(row) => Ok(Some(row.map_err(|e| e.to_string())?)),
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_paloma_mission_card(
        &self,
        card: PalomaMissionCard,
    ) -> Result<PalomaMissionCard, String> {
        let conn = self.conn.clone();
        let c = card.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_mission_cards
                 (mission_id, telegram_user_id, channel_id, chat_id, message_id,
                  content_hash, anchor_ts, last_edit_ts, version, archived)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT(mission_id) DO UPDATE SET
                    telegram_user_id = excluded.telegram_user_id,
                    channel_id = excluded.channel_id,
                    chat_id = excluded.chat_id,
                    message_id = excluded.message_id,
                    content_hash = excluded.content_hash,
                    anchor_ts = excluded.anchor_ts,
                    last_edit_ts = excluded.last_edit_ts,
                    version = excluded.version,
                    archived = excluded.archived",
                params![
                    c.mission_id.to_string(),
                    c.telegram_user_id,
                    c.channel_id.to_string(),
                    c.chat_id,
                    c.message_id,
                    c.content_hash,
                    c.anchor_ts,
                    c.last_edit_ts,
                    c.version,
                    if c.archived { 1 } else { 0 },
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(card)
    }

    pub(super) async fn touch_paloma_mission_card(
        &self,
        mission_id: Uuid,
        content_hash: &str,
        last_edit_ts: &str,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let mission_id = mission_id.to_string();
        let content_hash = content_hash.to_string();
        let last_edit_ts = last_edit_ts.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE paloma_mission_cards
                 SET content_hash = ?2,
                     last_edit_ts = ?3,
                     version = version + 1
                 WHERE mission_id = ?1",
                params![mission_id, content_hash, last_edit_ts],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn archive_paloma_mission_card(&self, mission_id: Uuid) -> Result<(), String> {
        let conn = self.conn.clone();
        let mission_id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "UPDATE paloma_mission_cards SET archived = 1 WHERE mission_id = ?1",
                params![mission_id],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn list_active_paloma_mission_cards(
        &self,
        telegram_user_id: i64,
    ) -> Result<Vec<PalomaMissionCard>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT mission_id, telegram_user_id, channel_id, chat_id, message_id,
                            content_hash, anchor_ts, last_edit_ts, version, archived
                     FROM paloma_mission_cards
                     WHERE telegram_user_id = ?1 AND archived = 0
                     ORDER BY last_edit_ts DESC",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map(params![telegram_user_id], row_to_paloma_mission_card)
                .map_err(|e| e.to_string())?;
            let mut cards = Vec::new();
            for row in rows {
                cards.push(row.map_err(|e| e.to_string())?);
            }
            Ok(cards)
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_paloma_cooldown_state(
        &self,
        telegram_user_id: i64,
        mission_id: Uuid,
        alert_class: &str,
    ) -> Result<Option<PalomaCooldownState>, String> {
        let conn = self.conn.clone();
        let alert_class = alert_class.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT mission_id, alert_class, telegram_user_id,
                            last_sent_at, next_eligible_at, backoff_step
                     FROM paloma_cooldown_state
                     WHERE mission_id = ?1 AND alert_class = ?2 AND telegram_user_id = ?3",
                )
                .map_err(|e| e.to_string())?;
            let mut rows = stmt
                .query_map(
                    params![mission_id.to_string(), alert_class, telegram_user_id],
                    row_to_paloma_cooldown_state,
                )
                .map_err(|e| e.to_string())?;
            match rows.next() {
                Some(row) => Ok(Some(row.map_err(|e| e.to_string())?)),
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_paloma_cooldown_state(
        &self,
        state: PalomaCooldownState,
    ) -> Result<PalomaCooldownState, String> {
        let conn = self.conn.clone();
        let s = state.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_cooldown_state
                 (mission_id, alert_class, telegram_user_id,
                  last_sent_at, next_eligible_at, backoff_step)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(mission_id, alert_class, telegram_user_id) DO UPDATE SET
                    last_sent_at = excluded.last_sent_at,
                    next_eligible_at = excluded.next_eligible_at,
                    backoff_step = excluded.backoff_step",
                params![
                    s.mission_id.to_string(),
                    s.alert_class,
                    s.telegram_user_id,
                    s.last_sent_at,
                    s.next_eligible_at,
                    s.backoff_step,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(state)
    }

    pub(super) async fn reset_paloma_cooldown_for_mission(
        &self,
        mission_id: Uuid,
    ) -> Result<(), String> {
        let conn = self.conn.clone();
        let mission_id = mission_id.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "DELETE FROM paloma_cooldown_state WHERE mission_id = ?1",
                params![mission_id],
            )
            .map_err(|e| e.to_string())?;
            Ok(())
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn get_paloma_user_preferences(
        &self,
        telegram_user_id: i64,
    ) -> Result<Option<PalomaUserPreferences>, String> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare(
                    "SELECT telegram_user_id, timezone, quiet_hours_start, quiet_hours_end,
                            max_interrupts_per_hour, max_interrupts_per_day,
                            failure_override_quiet, alert_class_overrides_json,
                            mission_overrides_json, digest_cadence, created_at, updated_at
                     FROM paloma_user_preferences
                     WHERE telegram_user_id = ?1",
                )
                .map_err(|e| e.to_string())?;
            let mut rows = stmt
                .query_map(params![telegram_user_id], row_to_paloma_user_preferences)
                .map_err(|e| e.to_string())?;
            match rows.next() {
                Some(row) => Ok(Some(row.map_err(|e| e.to_string())?)),
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub(super) async fn upsert_paloma_user_preferences(
        &self,
        preferences: PalomaUserPreferences,
    ) -> Result<PalomaUserPreferences, String> {
        let conn = self.conn.clone();
        let p = preferences.clone();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO paloma_user_preferences
                 (telegram_user_id, timezone, quiet_hours_start, quiet_hours_end,
                  max_interrupts_per_hour, max_interrupts_per_day, failure_override_quiet,
                  alert_class_overrides_json, mission_overrides_json, digest_cadence,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                 ON CONFLICT(telegram_user_id) DO UPDATE SET
                    timezone = excluded.timezone,
                    quiet_hours_start = excluded.quiet_hours_start,
                    quiet_hours_end = excluded.quiet_hours_end,
                    max_interrupts_per_hour = excluded.max_interrupts_per_hour,
                    max_interrupts_per_day = excluded.max_interrupts_per_day,
                    failure_override_quiet = excluded.failure_override_quiet,
                    alert_class_overrides_json = excluded.alert_class_overrides_json,
                    mission_overrides_json = excluded.mission_overrides_json,
                    digest_cadence = excluded.digest_cadence,
                    updated_at = excluded.updated_at",
                params![
                    p.telegram_user_id,
                    p.timezone,
                    p.quiet_hours_start,
                    p.quiet_hours_end,
                    p.max_interrupts_per_hour,
                    p.max_interrupts_per_day,
                    if p.failure_override_quiet { 1 } else { 0 },
                    p.alert_class_overrides_json,
                    p.mission_overrides_json,
                    p.digest_cadence,
                    p.created_at,
                    p.updated_at,
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<_, String>(())
        })
        .await
        .map_err(|e| e.to_string())??;
        Ok(preferences)
    }

    pub(super) async fn count_paloma_sent_alerts_since(
        &self,
        telegram_user_id: i64,
        since: &str,
    ) -> Result<i64, String> {
        let conn = self.conn.clone();
        let since = since.to_string();
        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            // Rate-limit budget is "how many Telegram messages did we send
            // to this user in the window", not "how many alert rows we
            // marked sent". A digest folds N alerts into one Telegram
            // message; counting the rows would burn the user's budget N×
            // faster than reality.
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(DISTINCT telegram_message_id) FROM telegram_alerts
                     WHERE telegram_user_id = ?1
                       AND status = 'sent'
                       AND sent_at IS NOT NULL
                       AND telegram_message_id IS NOT NULL
                       AND sent_at >= ?2",
                    params![telegram_user_id, since],
                    |row| row.get(0),
                )
                .map_err(|e| e.to_string())?;
            Ok(count)
        })
        .await
        .map_err(|e| e.to_string())?
    }
}
