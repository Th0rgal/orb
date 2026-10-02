//! Durable remote follow-ups. The existing dispatch admission lock serializes
//! cancellation and delivery; the node/run receipts make replay idempotent.
use super::super::projects_store::ProjectsStore;
use super::*;
use futures::StreamExt;
use rusqlite::{params, OptionalExtension};

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Entry {
    pub user_id: String,
    pub message: QueuedMessage,
    pub node_id: String,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub job_id: Option<Uuid>,
    pub assignment: serde_json::Value,
}

fn assignment(mission: &Mission) -> serde_json::Value {
    serde_json::json!({"project":mission.project.project,"track":mission.project.track,"pr":mission.project.github_pr,"backend":mission.backend})
}

pub(super) fn waiting(store: &ProjectsStore, user: Option<&str>) -> Result<Vec<Entry>, String> {
    let conn = store.lock()?;
    let mut stmt = conn.prepare("SELECT payload FROM remote_message_queue WHERE state='waiting' AND (?1 IS NULL OR user_id=?1) ORDER BY sequence").map_err(|e|e.to_string())?;
    let rows = stmt
        .query_map([user], |row| row.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    rows.map(|row| {
        serde_json::from_str(&row.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
    })
    .collect()
}
fn save(store: &ProjectsStore, entry: &Entry) -> Result<(), String> {
    store.lock()?.execute("INSERT INTO remote_message_queue(user_id,message_id,mission_id,payload) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id,message_id) DO NOTHING",params![entry.user_id,entry.message.id.to_string(),entry.message.mission_id.unwrap().to_string(),serde_json::to_string(entry).map_err(|e|e.to_string())?]).map_err(|e|e.to_string())?;
    Ok(())
}
pub(super) fn finish(
    store: &ProjectsStore,
    user: &str,
    id: Uuid,
    state: &str,
) -> Result<bool, String> {
    store.lock()?.execute("UPDATE remote_message_queue SET state=?3 WHERE user_id=?1 AND message_id=?2 AND state='waiting' AND (?3 != 'cancelled' OR (json_extract(payload,'$.job_id') IS NULL OR json_extract(payload,'$.delivery_abandonable')=1))",params![user,id.to_string(),state]).map(|n|n>0).map_err(|e|e.to_string())
}
pub(super) fn cancel_all(
    store: &ProjectsStore,
    user: &str,
    mission: Option<Uuid>,
) -> Result<usize, String> {
    store.lock()?.execute("UPDATE remote_message_queue SET state='cancelled' WHERE user_id=?1 AND state='waiting' AND (json_extract(payload,'$.job_id') IS NULL OR json_extract(payload,'$.delivery_abandonable')=1) AND (?2 IS NULL OR mission_id=?2)",params![user,mission.map(|id|id.to_string())]).map_err(|e|e.to_string())
}

/// Called under dispatch admission before any parent/child runner is stopped.
pub(super) async fn cancel_tree(
    store: &ProjectsStore,
    missions: &Arc<dyn MissionStore>,
    user: &str,
    root: Uuid,
) -> Result<(), String> {
    let mut pending = vec![root];
    let mut seen = HashSet::new();
    while let Some(id) = pending.pop() {
        if seen.insert(id) {
            pending.extend(
                missions
                    .get_child_missions(id)
                    .await?
                    .into_iter()
                    .map(|m| m.id),
            );
        }
    }
    let mut conn = store.lock()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    for id in seen {
        tx.execute("UPDATE remote_message_queue SET state='cancelled' WHERE user_id=?1 AND mission_id=?2 AND state='waiting' AND (json_extract(payload,'$.job_id') IS NULL OR json_extract(payload,'$.delivery_abandonable')=1)", params![user,id.to_string()]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())
}

pub(super) fn allow_abandon(store: &ProjectsStore, user: &str, id: Uuid) -> Result<(), String> {
    store.lock()?.execute("UPDATE remote_message_queue SET payload=json_set(payload,'$.delivery_abandonable',1) WHERE user_id=?1 AND message_id=?2 AND state='waiting'", params![user,id.to_string()]).map_err(|e|e.to_string())?;
    Ok(())
}

pub(super) async fn enqueue(
    state: &Arc<AppState>,
    control: &ControlState,
    user: &str,
    mid: Uuid,
    _placement: remote_grok::RemotePlacement,
    content: String,
    id: Uuid,
) -> Result<(), (StatusCode, String)> {
    let _guard = DISPATCH_ADMISSION.lock().await;
    let _file = dispatch_admission::durable_lock(&state.config)
        .await
        .map_err(internal_error)?;
    machine_transfer::guard(&control.mission_store, mid)
        .await
        .map_err(internal_error)?;
    let placement = remote_grok::placement(&state.config.working_dir, &control.mission_store, mid)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::CONFLICT, "Remote placement disappeared".into()))?;
    let mission = control
        .mission_store
        .get_mission(mid)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "mission not found".into()))?;
    if !matches!(
        mission.backend.as_str(),
        "grok" | "codex" | "claudecode" | "opencode"
    ) {
        return Err((
            StatusCode::CONFLICT,
            "This remote harness cannot continue its session".into(),
        ));
    }
    if !placement.live
        && mission
            .session_id
            .as_deref()
            .is_none_or(|id| id.trim().is_empty())
        && machine_transfer::committed(&control.mission_store, mid)
            .await
            .map_err(internal_error)?
            .is_none()
        && mission.backend != "opencode"
    {
        return Err((
            StatusCode::CONFLICT,
            format!(
                "{}: mission {mid} has no recorded native session",
                remote_grok::REMOTE_RESUME_REQUIRES_REPLACEMENT
            ),
        ));
    }
    // Keep existing continuation admission: a queued message must never turn
    // into a replacement mission or silently switch writer identity.
    let unsupported = mission.project.github_pr.is_some()
        || mission.project.tags.iter().any(|tag| tag == "pr-writer")
        || mission.project.track.as_ref().is_some_and(|track| {
            track != &crate::api::track_leases::generated_track_key(&mid.to_string())
        });
    if unsupported {
        let prefix = if placement.live {
            remote_grok::REMOTE_JOB_STILL_RUNNING
        } else {
            remote_grok::REMOTE_RESUME_REQUIRES_REPLACEMENT
        };
        return Err((
            StatusCode::CONFLICT,
            format!(
                "{prefix}: this mission's writer identity does not support native continuation"
            ),
        ));
    }
    let previous: Option<(String, String)> = state
        .projects
        .lock()
        .map_err(internal_error)?
        .query_row(
            "SELECT mission_id,state FROM remote_message_queue WHERE user_id=?1 AND message_id=?2",
            params![user, id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(internal_error)?;
    if let Some((owner, status)) = previous {
        if owner != mid.to_string() || status == "cancelled" {
            return Err((
                StatusCode::CONFLICT,
                "This message ID was already used or cancelled".into(),
            ));
        }
        return Ok(());
    }
    save(
        &state.projects,
        &Entry {
            user_id: user.into(),
            node_id: placement.node_id,
            // Older OpenCode jobs use a placeholder until the stream reports
            // their real session. Do not pin that placeholder as native identity.
            session_id: mission
                .session_id
                .clone()
                .filter(|id| mission.backend != "opencode" || id.starts_with("ses_")),
            job_id: None,
            message: QueuedMessage {
                id,
                content,
                agent: None,
                mission_id: Some(mid),
                source: Some("remote-queue".into()),
                inflight: false,
                queue_error: None,
            },
            assignment: assignment(&mission),
        },
    )
    .map_err(internal_error)
}

/// Called *inside* dispatch admission, immediately before checking the live run.
/// Re-read the inbox: a cancelled or overtaken timer snapshot has no authority.
pub(super) fn validate(
    store: &ProjectsStore,
    user: &str,
    id: Uuid,
    mission: &Mission,
    node: &str,
) -> Result<Entry, String> {
    if mission.status == MissionStatus::Paused {
        return Err("Mission is paused; resume it to deliver queued messages".into());
    }
    let entry = waiting(store, Some(user))?
        .into_iter()
        .find(|row| row.message.mission_id == Some(mission.id))
        .ok_or("Remote message is no longer queued")?;
    if entry.message.id != id {
        return Err("An earlier remote message is waiting".into());
    }
    if entry.node_id != node
        || entry.assignment != assignment(mission)
        || entry
            .session_id
            .as_ref()
            .is_some_and(|session| mission.session_id.as_ref() != Some(session))
    {
        return Err("Mission placement or assignment changed while the message was queued".into());
    }
    Ok(entry)
}

async fn retire_missing_mission(
    state: &Arc<AppState>,
    control: &ControlState,
    entry: &Entry,
) -> Result<bool, String> {
    let _guard = DISPATCH_ADMISSION.lock().await;
    let _file = dispatch_admission::durable_lock(&state.config).await?;
    if control
        .mission_store
        .get_mission(entry.message.mission_id.unwrap())
        .await?
        .is_some()
    {
        return Ok(false);
    }
    // Deletion is authoritative, including for a bound delivery receipt. Keep
    // the idempotency tombstone but never retry this orphan again.
    finish(&state.projects, &entry.user_id, entry.message.id, "deleted")?;
    Ok(true)
}

pub(super) fn start(state: std::sync::Weak<AppState>) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(3));
        loop {
            interval.tick().await;
            let Some(state) = state.upgrade() else { break };
            let entries = match waiting(&state.projects, None) {
                Ok(rows) => rows,
                Err(error) => {
                    tracing::warn!(%error,"Cannot read remote message queue");
                    continue;
                }
            };
            let mut seen = HashSet::new();
            let missions = entries
                .into_iter()
                .filter(|entry| seen.insert((entry.user_id.clone(), entry.message.mission_id)))
                .collect::<Vec<_>>();
            futures::stream::iter(missions).for_each_concurrent(8, |entry| {
                let state = state.clone();
                async move {
                let mid = entry.message.mission_id.unwrap();
                let user = AuthUser {
                    id: entry.user_id.clone(),
                    username: entry.user_id.clone(),
                };
                let control = control_for_user(&state, &user).await;
                match retire_missing_mission(&state, &control, &entry).await {
                    Ok(true) => return,
                    Ok(false) => {}
                    Err(error) => {
                        tracing::warn!(mission_id=%mid,%error,"Cannot verify queued mission existence");
                        return;
                    }
                }
                // No local fallback, even if placement is missing or transferred.
                let placement = match remote_grok::placement(
                    &state.config.working_dir,
                    &control.mission_store,
                    mid,
                )
                .await
                {
                    Ok(Some(p)) => p,
                    result => {
                        let error=result.err().unwrap_or_else(|| "Remote placement is unavailable; the message remains on its original node".into());
                        let _ = report_error(
                            &state.projects,
                            &entry.user_id,
                            entry.message.id,
                            Some(&error),
                        );
                        return;
                    }
                };
                if let Err((_, error)) = remote_grok::deliver_queued(
                    &state,
                    &control,
                    &entry.user_id,
                    mid,
                    placement,
                    entry.message.id,
                )
                .await
                {
                    let detail = (!error.contains(remote_grok::REMOTE_JOB_STILL_RUNNING))
                        .then_some(error.as_str());
                    let _ = report_error(&state.projects, &entry.user_id, entry.message.id, detail);
                    tracing::debug!(mission_id=%mid,%error,"Remote message remains queued");
                }
                }
            }).await;
        }
    });
}

pub(super) fn is_waiting(store: &ProjectsStore, user: &str, id: Uuid) -> Result<bool, String> {
    store
        .lock()?
        .query_row(
            "SELECT state='waiting' FROM remote_message_queue WHERE user_id=?1 AND message_id=?2",
            params![user, id.to_string()],
            |row| row.get(0),
        )
        .optional()
        .map(|value| value.unwrap_or(false))
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn stale_delivery_cannot_overtake_cancel_or_change_session() {
        let missions = crate::api::mission_store::InMemoryMissionStore::new();
        let mut mission = missions
            .create_mission(None, None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        mission.session_id = Some("native-session".into());
        let db = ProjectsStore::open_in_memory().unwrap();
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        for id in [first, second] {
            save(
                &db,
                &Entry {
                    user_id: "u".into(),
                    node_id: "nippur".into(),
                    session_id: mission.session_id.clone(),
                    job_id: None,
                    assignment: assignment(&mission),
                    message: QueuedMessage {
                        id,
                        content: "hello".into(),
                        agent: None,
                        mission_id: Some(mission.id),
                        source: Some("remote-queue".into()),
                        inflight: false,
                        queue_error: None,
                    },
                },
            )
            .unwrap();
        }
        assert!(validate(&db, "u", second, &mission, "nippur").is_err());
        assert!(validate(&db, "u", first, &mission, "other-node").is_err());
        let mut changed = mission.clone();
        changed.session_id = Some("another-session".into());
        assert!(validate(&db, "u", first, &changed, "nippur").is_err());
        assert!(finish(&db, "u", first, "cancelled").unwrap());
        assert!(validate(&db, "u", first, &mission, "nippur").is_err());
        mission.status = MissionStatus::Paused;
        assert!(validate(&db, "u", second, &mission, "nippur")
            .err()
            .unwrap()
            .contains("paused"));
        assert!(is_waiting(&db, "u", second).unwrap());
        mission.status = MissionStatus::Interrupted;
        assert!(validate(&db, "u", second, &mission, "nippur").is_ok());
        bind_job(&db, "u", second, Some(Uuid::new_v4())).unwrap();
        assert!(
            !finish(&db, "u", second, "cancelled").unwrap(),
            "cannot claim to withdraw a possibly accepted job"
        );
        assert_eq!(cancel_all(&db, "u", Some(mission.id)).unwrap(), 0);
        allow_abandon(&db, "u", second).unwrap();
        assert!(finish(&db, "u", second, "cancelled").unwrap());
        assert!(waiting(&db, Some("u")).unwrap().is_empty());
    }

    #[tokio::test]
    async fn stop_cancels_descendant_queues_without_touching_other_missions() {
        let missions: Arc<dyn MissionStore> =
            Arc::new(crate::api::mission_store::InMemoryMissionStore::new());
        let root = missions
            .create_mission(None, None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        let child = missions
            .create_mission_with_parent(
                None,
                None,
                None,
                None,
                None,
                false,
                Some("codex"),
                None,
                Some(root.id),
                None,
            )
            .await
            .unwrap();
        let grandchild = missions
            .create_mission_with_parent(
                None,
                None,
                None,
                None,
                None,
                false,
                Some("codex"),
                None,
                Some(child.id),
                None,
            )
            .await
            .unwrap();
        let other = missions
            .create_mission(None, None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        let db = ProjectsStore::open_in_memory().unwrap();
        for mission in [&root, &child, &grandchild, &other] {
            save(
                &db,
                &Entry {
                    user_id: "u".into(),
                    node_id: "nippur".into(),
                    session_id: None,
                    job_id: None,
                    assignment: assignment(mission),
                    message: QueuedMessage {
                        id: Uuid::new_v4(),
                        content: "follow-up".into(),
                        mission_id: Some(mission.id),
                        agent: None,
                        source: None,
                        inflight: false,
                        queue_error: None,
                    },
                },
            )
            .unwrap();
        }
        cancel_tree(&db, &missions, "u", root.id).await.unwrap();
        let remaining = waiting(&db, Some("u")).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].message.mission_id, Some(other.id));
    }

    #[test]
    fn remote_queue_reopen_fifo_cancel_and_receipts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("projects.db");
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let mid = Uuid::new_v4();
        let entry = |id, content: &str| Entry {
            user_id: "u".into(),
            message: QueuedMessage {
                id,
                content: content.into(),
                mission_id: Some(mid),
                agent: None,
                source: Some("remote-queue".into()),
                inflight: false,
                queue_error: None,
            },
            node_id: "nippur".into(),
            session_id: None,
            job_id: None,
            assignment: serde_json::json!({}),
        };
        {
            let db = ProjectsStore::open(path.clone()).unwrap();
            save(&db, &entry(first, "one")).unwrap();
            save(&db, &entry(second, "two")).unwrap();
            save(&db, &entry(first, "overwrite")).unwrap();
            bind_job(&db, "u", first, Some(mid)).unwrap();
        }
        let db = ProjectsStore::open(path.clone()).unwrap();
        let rows = waiting(&db, Some("u")).unwrap();
        assert_eq!(
            rows.iter().map(|e| e.message.id).collect::<Vec<_>>(),
            vec![first, second]
        );
        assert_eq!(rows[0].message.content, "one");
        assert_eq!(rows[0].job_id, Some(mid));
        assert!(waiting(&db, Some("other-user")).unwrap().is_empty());
        assert!(finish(&db, "u", first, "accepted").unwrap());
        assert!(finish(&db, "u", second, "cancelled").unwrap());
        drop(db);
        let db = ProjectsStore::open(path).unwrap();
        save(&db, &entry(first, "retry accepted")).unwrap();
        save(&db, &entry(second, "retry cancelled")).unwrap();
        assert!(waiting(&db, None).unwrap().is_empty());
        assert!(!finish(&db, "u", first, "cancelled").unwrap());
    }
}

// Bind before submit, under dispatch admission. Unlike scheduled wake receipts,
// this journal also covers ordinary composer messages and ambiguous responses.
pub(super) fn bind_job(
    store: &ProjectsStore,
    user: &str,
    id: Uuid,
    job: Option<Uuid>,
) -> Result<(), String> {
    let count=store.lock()?.execute("UPDATE remote_message_queue SET payload=json_set(payload,'$.job_id',?3) WHERE user_id=?1 AND message_id=?2 AND state='waiting'",params![user,id.to_string(),job.map(|id|id.to_string())]).map_err(|e|e.to_string())?;
    if count != 1 {
        return Err("Remote queue delivery was cancelled".into());
    }
    Ok(())
}

fn report_error(
    store: &ProjectsStore,
    user: &str,
    id: Uuid,
    error: Option<&str>,
) -> Result<(), String> {
    store.lock()?.execute("UPDATE remote_message_queue SET payload=json_set(payload,'$.message.queue_error',?3) WHERE user_id=?1 AND message_id=?2 AND state='waiting'",params![user,id.to_string(),error]).map_err(|e|e.to_string())?;
    Ok(())
}
