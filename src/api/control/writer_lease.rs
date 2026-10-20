//! PR writer leases, mission activation for incoming messages and host follow-ups.

use super::*;

pub(super) struct DurablePrWriterLockGuard {
    pub(super) _process_guard: tokio::sync::MutexGuard<'static, ()>,
    pub(super) file: std::fs::File,
}

impl Drop for DurablePrWriterLockGuard {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

pub(super) async fn acquire_durable_pr_writer_lock(
    control_hub: &ControlHub,
) -> Result<DurablePrWriterLockGuard, String> {
    // The async mutex prevents this process from blocking one of its runtime
    // threads on flock while another local request owns the lease lock. The
    // advisory file lock extends the same critical section across backend and
    // Hermes/controller processes that share this mission store directory.
    let process_guard = PR_WRITER_CREATE_LOCK.lock().await;
    let lock_dir = control_hub
        .config
        .working_dir
        .join(".sandboxed-sh")
        .join("missions");
    tokio::fs::create_dir_all(&lock_dir)
        .await
        .map_err(|error| format!("create PR writer lock directory: {error}"))?;
    let lock_path = lock_dir.join(".pr-writer.lock");
    let file = tokio::task::spawn_blocking(move || {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .map_err(|error| format!("open {}: {error}", lock_path.display()))?;
        fs2::FileExt::lock_exclusive(&file)
            .map_err(|error| format!("lock {}: {error}", lock_path.display()))?;
        Ok::<_, String>(file)
    })
    .await
    .map_err(|error| format!("join PR writer lock task: {error}"))??;
    Ok(DurablePrWriterLockGuard {
        _process_guard: process_guard,
        file,
    })
}

pub(crate) fn canonical_github_pr(raw: &str) -> String {
    let mut value = raw
        .trim()
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .trim_end_matches('/')
        .to_ascii_lowercase();
    for prefix in ["https://github.com/", "http://github.com/", "github.com/"] {
        if let Some(stripped) = value.strip_prefix(prefix) {
            value = stripped.to_string();
            break;
        }
    }
    if let Some((repository, tail)) = value.split_once("/pull/") {
        let number = tail.split('/').next().unwrap_or_default();
        return format!("{repository}#{number}");
    }
    // Preserve the compact `owner/repo#number` form while discarding a copied
    // tab suffix such as `#123/files`.
    if let Some((repository, tail)) = raw.trim().to_ascii_lowercase().split_once('#') {
        let number = tail.split(['/', '?']).next().unwrap_or_default();
        return format!("{}#{}", repository.trim_end_matches('/'), number);
    }
    value
}

pub(super) fn inferred_pr_writer(
    explicit: Option<bool>,
    intent: Option<&str>,
    prompt: Option<&str>,
) -> bool {
    if let Some(explicit) = explicit {
        return explicit;
    }
    let text = format!(
        "{} {}",
        intent.unwrap_or_default(),
        prompt.unwrap_or_default()
    )
    .to_ascii_lowercase();
    let clauses: Vec<Vec<&str>> = text
        .split([';', '.', '!', '?', '\n', '\r'])
        .map(|clause| {
            clause
                .split(|ch: char| !ch.is_ascii_alphanumeric())
                .filter(|token| !token.is_empty())
                .collect()
        })
        .filter(|clause: &Vec<&str>| !clause.is_empty())
        .collect();
    let tokens: HashSet<&str> = clauses.iter().flatten().copied().collect();
    let has_writer_noun = ["integration", "implementation"]
        .iter()
        .any(|token| tokens.contains(token));
    if has_writer_noun {
        return true;
    }

    const WRITER_VERBS: [&str; 24] = [
        "write",
        "writing",
        "edit",
        "editing",
        "fix",
        "fixing",
        "repair",
        "repairing",
        "resolve",
        "resolving",
        "integrate",
        "integrating",
        "rebase",
        "rebasing",
        "merge",
        "merging",
        "commit",
        "committing",
        "push",
        "pushing",
        "implement",
        "implementing",
        "update",
        "updating",
    ];
    const NEGATORS_BEFORE: [&str; 8] = [
        "not", "never", "no", "without", "dont", "cannot", "cant", "forbid",
    ];
    const NEGATORS_AFTER: [&str; 4] = ["prohibited", "forbidden", "banned", "disallowed"];
    const POLICY_ADVERBS: [&str; 6] = [
        "currently",
        "temporarily",
        "explicitly",
        "strictly",
        "now",
        "still",
    ];

    clauses.iter().any(|words| {
        words.iter().enumerate().any(|(index, word)| {
            if !WRITER_VERBS.contains(word) {
                return false;
            }
            let negated_immediately = index > 0 && NEGATORS_BEFORE.contains(&words[index - 1]);
            let coordinated_negation = (index.saturating_sub(4)..index).any(|negator_index| {
                NEGATORS_BEFORE.contains(&words[negator_index])
                    && words[(negator_index + 1)..index].iter().all(|between| {
                        WRITER_VERBS.contains(between) || matches!(*between, "and" | "or")
                    })
            });
            let stopped_before =
                index >= 2 && words[index - 2] == "stop" && words[index - 1] == "before";
            let mut prohibition_index = index + 1;
            let has_copula = words
                .get(prohibition_index)
                .is_some_and(|word| matches!(*word, "is" | "are" | "was" | "were"));
            if has_copula {
                prohibition_index += 1;
            }
            let mut policy_adverbs = 0;
            while policy_adverbs < 2
                && words
                    .get(prohibition_index)
                    .is_some_and(|word| POLICY_ADVERBS.contains(word))
            {
                prohibition_index += 1;
                policy_adverbs += 1;
            }
            let policy_prohibition = words
                .get(prohibition_index)
                .is_some_and(|word| NEGATORS_AFTER.contains(word))
                && (has_copula
                    || policy_adverbs > 0
                    || words.get(prohibition_index + 1).is_none_or(|next| {
                        matches!(
                            *next,
                            "by" | "under" | "here" | "globally" | "currently" | "temporarily"
                        )
                    }));
            !(negated_immediately || coordinated_negation || stopped_before || policy_prohibition)
        })
    })
}

pub(super) fn requested_pr_writer(
    explicit: Option<bool>,
    tags: Option<&[String]>,
    intent: Option<&str>,
    prompt: Option<&str>,
) -> bool {
    if let Some(explicit) = explicit {
        return explicit;
    }
    if tags.is_some_and(|tags| tags.iter().any(|tag| tag == "pr-readonly")) {
        return false;
    }
    tags.is_some_and(|tags| tags.iter().any(|tag| tag == "pr-writer"))
        || inferred_pr_writer(None, intent, prompt)
}

pub(super) fn normalize_mission_tags(tags: Option<&[String]>) -> Option<Vec<String>> {
    tags.map(|tags| {
        tags.iter()
            .map(|tag| tag.trim().to_string())
            .filter(|tag| !tag.is_empty())
            .collect()
    })
}

pub(crate) fn native_goal_holds_ownership(status: MissionStatus, reason: Option<&str>) -> bool {
    status == MissionStatus::Blocked
        && matches!(
            reason,
            Some(
                "native_goal_stopped" | "codex_continuity_required" | "native_continuity_required"
            )
        )
}

pub(super) fn status_holds_pr_writer_lease(status: MissionStatus, reason: Option<&str>) -> bool {
    if native_goal_holds_ownership(status, reason) {
        return true;
    }
    matches!(
        status,
        MissionStatus::Pending
            | MissionStatus::Active
            | MissionStatus::WaitingBackground
            | MissionStatus::AwaitingUser
            | MissionStatus::Paused
    )
}

/// Grace window during which an `AwaitingUser` PR writer keeps its lease.
///
/// `AwaitingUser` is non-terminal on purpose — a writer waiting for a human
/// reply must not lose its branch. But agent-created writers are often never
/// opened in the dashboard, so the view-gated ack-promotion tick never
/// archives them, and a finished writer can hold its PR lease indefinitely
/// (phantom lease: observed 2026-08-01, a writer 13h idle in a tenant store
/// blocked every replacement while reading 404 from another tenant). After
/// this many seconds without any update, the lease check itself releases the
/// holder by acknowledging it.
pub(crate) fn pr_writer_awaiting_grace_secs() -> i64 {
    std::env::var("PR_WRITER_AWAITING_GRACE_SECS")
        .ok()
        .and_then(|raw| raw.trim().parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(3600)
}

/// Whether an `AwaitingUser` writer's lease has lapsed. Unparseable
/// timestamps keep the lease (fail closed on exclusivity, never on release).
pub(super) fn awaiting_pr_writer_lease_expired(updated_at: &str) -> bool {
    let Ok(updated) = chrono::DateTime::parse_from_rfc3339(updated_at) else {
        return false;
    };
    let idle = chrono::Utc::now().signed_duration_since(updated.with_timezone(&chrono::Utc));
    idle.num_seconds() > pr_writer_awaiting_grace_secs()
}

/// Gate a matched writer through the awaiting-grace policy. Fresh holders are
/// returned as the lease; lapsed `AwaitingUser` holders are acknowledged in
/// place (best effort) so the durable state converges with the release.
pub(super) async fn resolve_writer_lease_or_release(
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Result<Option<PrWriterLease>, String> {
    if mission.status == MissionStatus::AwaitingUser
        && awaiting_pr_writer_lease_expired(&mission.updated_at)
    {
        tracing::info!(
            mission_id = %mission.id,
            updated_at = %mission.updated_at,
            "releasing lapsed AwaitingUser PR-writer lease (auto-acknowledge)"
        );
        if let Err(error) = store
            .update_mission_status(mission.id, MissionStatus::Acknowledged)
            .await
        {
            // The holder could not be archived (read-only store, race). Keep
            // treating the lease as released for this decision: the mission is
            // provably idle past grace, and exclusivity failing open here only
            // after a long idle window is the lesser risk than a permanent
            // phantom lease.
            tracing::warn!(
                mission_id = %mission.id,
                "failed to acknowledge lapsed PR-writer holder: {error}"
            );
        }
        return Ok(None);
    }
    Ok(Some(pr_writer_lease(mission)))
}

pub(super) fn mission_is_pr_writer(mission: &Mission) -> bool {
    mission_is_pr_writer_with_prompt(
        mission,
        mission.history.first().map(|entry| entry.content.as_str()),
    )
}

pub(super) fn mission_is_pr_writer_with_prompt(mission: &Mission, prompt: Option<&str>) -> bool {
    if mission.project.tags.iter().any(|tag| tag == "pr-readonly") {
        return false;
    }
    mission.project.tags.iter().any(|tag| tag == "pr-writer")
        || inferred_pr_writer(None, mission.project.intent.as_deref(), prompt)
}

pub(super) async fn mission_is_pr_writer_in_store(
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Result<bool, String> {
    let initial_prompt = store.get_initial_user_message(mission.id).await?;
    Ok(mission_is_pr_writer_with_prompt(
        mission,
        initial_prompt.as_deref(),
    ))
}

pub(super) fn message_requests_pr_writer(mission: &Mission, content: &str) -> bool {
    mission.project.github_pr.is_some()
        // An explicit read-only capability is an authority boundary, not a
        // prompt hint. In particular, the scheduler re-injects a pending
        // mission's deferred initial goal as a message; inferring an upgrade
        // from that text made read-only PR validators contend for the writer
        // lease before their harness ever started. Callers that want to expand
        // authority must first use the structured project update with
        // `writer=true`, which replaces this tag with `pr-writer` under the
        // durable lease lock.
        && !mission
            .project
            .tags
            .iter()
            .any(|tag| tag == "pr-readonly")
        && inferred_pr_writer(None, None, Some(content))
}

#[derive(Debug, Clone, Copy)]
pub(super) struct PrWriterLease {
    pub(super) id: Uuid,
    pub(super) status: MissionStatus,
}

pub(super) fn dispatch_identity_patch(
    github_pr: Option<String>,
    track: Option<String>,
    title: Option<String>,
    work_hint: Option<String>,
    continue_identity: Option<crate::api::writer_recycle::WriterContinuation>,
) -> crate::api::writer_recycle::WriterIdentityPatch {
    let to_patch = |value: Option<String>| -> Option<Option<String>> {
        value.map(|raw| {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        })
    };
    crate::api::writer_recycle::WriterIdentityPatch {
        title: to_patch(title),
        github_pr: to_patch(github_pr),
        track: to_patch(track),
        work_hint,
        continue_identity,
    }
}

pub(super) fn writer_reuse_or_conflict(
    mission: &Mission,
    patch: &crate::api::writer_recycle::WriterIdentityPatch,
) -> Result<crate::api::writer_recycle::WriterIdentity, (StatusCode, String)> {
    use crate::api::writer_recycle::{apply_writer_reuse, WriterIdentity};
    apply_writer_reuse(
        &WriterIdentity {
            project: mission.project.project.clone(),
            title: mission.title.clone(),
            github_pr: mission.project.github_pr.clone(),
            track: mission.project.track.clone(),
        },
        patch,
    )
    .map_err(|err| {
        (
            StatusCode::CONFLICT,
            serde_json::json!({"error": err.error, "message": err.message}).to_string(),
        )
    })
}

pub(super) fn pr_writer_lease(mission: &Mission) -> PrWriterLease {
    PrWriterLease {
        id: mission.id,
        status: mission.status,
    }
}

pub(super) async fn find_existing_pr_writer(
    store: &Arc<dyn MissionStore>,
    github_pr: &str,
    exclude_id: Option<Uuid>,
) -> Result<Option<PrWriterLease>, String> {
    let target = canonical_github_pr(github_pr);
    // Parked PR writers need the same stable inventory as execution owners.
    // Concurrent metadata updates must not move a writer behind an OFFSET.
    let page = store.list_missions(usize::MAX, 0).await?;
    #[cfg(test)]
    dispatch_admission_tests::after_ownership_page(&page);
    for mission in page {
        if Some(mission.id) == exclude_id
            || !status_holds_pr_writer_lease(mission.status, mission.terminal_reason.as_deref())
            || mission
                .project
                .github_pr
                .as_deref()
                .is_none_or(|value| canonical_github_pr(value) != target)
        {
            continue;
        }
        if mission_is_pr_writer(&mission) {
            if let Some(lease) = resolve_writer_lease_or_release(store, &mission).await? {
                return Ok(Some(lease));
            }
            continue;
        }
        // SQLite list queries intentionally omit history. Load the full
        // mission before treating a legacy prompt-only writer as read-only.
        if let Some(full) = store.get_mission(mission.id).await? {
            let initial_prompt = store.get_initial_user_message(mission.id).await?;
            if mission_is_pr_writer_with_prompt(&full, initial_prompt.as_deref()) {
                if let Some(lease) = resolve_writer_lease_or_release(store, &full).await? {
                    return Ok(Some(lease));
                }
                continue;
            }
            // Scheduled missions can carry their only prompt in the
            // durable deferred goal until dispatch. Treat that prompt as
            // capability evidence before declaring this lease read-only.
            if let Some(goal) = store.get_deferred_goal(mission.id).await? {
                // This is the mission's initial mandate, not a later
                // steering message. Explicit `pr-readonly` must therefore
                // continue to win over inferred write verbs in the goal.
                if mission_is_pr_writer_with_prompt(&full, Some(&goal)) {
                    if let Some(lease) = resolve_writer_lease_or_release(store, &full).await? {
                        return Ok(Some(lease));
                    }
                    continue;
                }
            }
        }
    }
    Ok(None)
}

pub(super) fn find_existing_pr_writer_in_sqlite(
    path: &std::path::Path,
    github_pr: &str,
    exclude_id: Option<Uuid>,
) -> Result<Option<PrWriterLease>, String> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|error| format!("open {} read-only: {error}", path.display()))?;
    connection
        .busy_timeout(std::time::Duration::from_secs(2))
        .map_err(|error| error.to_string())?;
    let table_columns = |table: &str| -> Result<std::collections::HashSet<String>, String> {
        let mut statement = connection
            .prepare(&format!("PRAGMA table_info({table})"))
            .map_err(|error| format!("inspect {table} in {}: {error}", path.display()))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|error| error.to_string())?;
        rows.collect::<Result<std::collections::HashSet<_>, _>>()
            .map_err(|error| error.to_string())
    };
    let mission_columns = table_columns("missions")?;
    if !mission_columns.contains("github_pr") {
        // Stores that predate PR metadata cannot hold a PR-scoped lease.
        return Ok(None);
    }
    if !mission_columns.contains("id") || !mission_columns.contains("status") {
        return Err(format!(
            "missions table in {} is missing identity/status columns",
            path.display()
        ));
    }
    let event_columns = table_columns("mission_events")?;
    let events_have_prompt = ["mission_id", "sequence", "event_type", "content"]
        .iter()
        .all(|column| event_columns.contains(*column));
    let optional_mission_column = |column: &str| {
        if mission_columns.contains(column) {
            format!("m.{column}")
        } else {
            "NULL".to_string()
        }
    };
    let first_prompt = if events_have_prompt {
        "(SELECT e.content FROM mission_events e \
         WHERE e.mission_id = m.id AND e.event_type = 'user_message' \
         ORDER BY e.sequence ASC LIMIT 1)"
            .to_string()
    } else {
        "NULL".to_string()
    };
    let first_prompt_file = if events_have_prompt && event_columns.contains("content_file") {
        "(SELECT e.content_file FROM mission_events e \
         WHERE e.mission_id = m.id AND e.event_type = 'user_message' \
         ORDER BY e.sequence ASC LIMIT 1)"
            .to_string()
    } else {
        "NULL".to_string()
    };
    let query = format!(
        "SELECT m.id, m.status, m.github_pr, {}, {}, {}, {}, {}, {}, {} \
         FROM missions m WHERE m.github_pr IS NOT NULL",
        optional_mission_column("intent"),
        optional_mission_column("tags"),
        optional_mission_column("deferred_goal"),
        first_prompt,
        first_prompt_file,
        optional_mission_column("updated_at"),
        optional_mission_column("terminal_reason"),
    );
    let mut statement = connection
        .prepare(&query)
        .map_err(|error| format!("query {}: {error}", path.display()))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
                row.get::<_, Option<String>>(9)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    let target = canonical_github_pr(github_pr);
    for row in rows {
        let (
            id,
            status,
            candidate_pr,
            intent,
            tags,
            deferred_goal,
            first_prompt,
            prompt_file,
            updated_at,
            terminal_reason,
        ) = row.map_err(|error| error.to_string())?;
        let Ok(id) = Uuid::parse_str(&id) else {
            continue;
        };
        if Some(id) == exclude_id || canonical_github_pr(&candidate_pr) != target {
            continue;
        }
        let status = serde_json::from_value::<MissionStatus>(serde_json::Value::String(status))
            .unwrap_or(MissionStatus::Active);
        if !status_holds_pr_writer_lease(status, terminal_reason.as_deref()) {
            continue;
        }
        // Offline stores are opened read-only, so a lapsed AwaitingUser writer
        // cannot be acknowledged here — but it must not hold the lease either
        // (same phantom-lease policy as the live path).
        if status == MissionStatus::AwaitingUser
            && updated_at
                .as_deref()
                .is_some_and(awaiting_pr_writer_lease_expired)
        {
            tracing::info!(
                mission_id = %id,
                store = %path.display(),
                "ignoring lapsed AwaitingUser PR-writer lease in offline store"
            );
            continue;
        }
        let tags: Vec<String> = tags
            .as_deref()
            .and_then(|value| serde_json::from_str(value).ok())
            .unwrap_or_default();
        let external_prompt = match (first_prompt.as_deref(), prompt_file.as_deref()) {
            (None, Some(path)) => Some(
                std::fs::read_to_string(path)
                    .map_err(|error| format!("read externalized mission prompt {path}: {error}"))?,
            ),
            _ => None,
        };
        let initial_prompt_requests_writer = requested_pr_writer(
            None,
            Some(&tags),
            intent.as_deref(),
            first_prompt
                .as_deref()
                .or(external_prompt.as_deref())
                .or(deferred_goal.as_deref()),
        );
        let deferred_goal_requests_writer = deferred_goal.as_deref().is_some_and(|goal| {
            requested_pr_writer(None, Some(&tags), intent.as_deref(), Some(goal))
        });
        if initial_prompt_requests_writer || deferred_goal_requests_writer {
            return Ok(Some(PrWriterLease { id, status }));
        }
    }
    Ok(None)
}

pub(super) async fn find_existing_pr_writer_global(
    control_hub: &ControlHub,
    github_pr: &str,
    exclude_id: Option<Uuid>,
) -> Result<Option<PrWriterLease>, String> {
    if let Some(owner) = execution_ownership::snapshot(control_hub)
        .await?
        .unresolved_pr_writer(github_pr, exclude_id)
    {
        return Ok(Some(owner));
    }
    // Cross-store admission can temporarily change or clear the stored PR.
    // Until cleanup completes, neither the old nor proposed PR is available
    // to another writer, including after a crash with a terminal status.
    if let Some(state) = control_hub
        .admission_state
        .get()
        .and_then(std::sync::Weak::upgrade)
    {
        let target = canonical_github_pr(github_pr);
        for (id, receipt) in state.projects.dispatch_admissions()? {
            let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
            if Some(id) != exclude_id
                && ["before", "after"].iter().any(|phase| {
                    receipt[*phase]["project"]["github_pr"]
                        .as_str()
                        .is_some_and(|pr| canonical_github_pr(pr) == target)
                })
            {
                return Ok(Some(PrWriterLease {
                    id,
                    status: MissionStatus::Active,
                }));
            }
        }
    }
    // Fail closed if any persisted store cannot be enumerated or read. A
    // partial cross-user scan cannot prove that a branch is writer-free.
    let inventory = control_hub.mission_store_inventory().await?;
    for store in inventory.live {
        if let Some(mission) = find_existing_pr_writer(&store, github_pr, exclude_id).await? {
            return Ok(Some(mission));
        }
    }
    for path in inventory.offline_sqlite {
        let github_pr = github_pr.to_string();
        let found = tokio::task::spawn_blocking(move || {
            find_existing_pr_writer_in_sqlite(&path, &github_pr, exclude_id)
        })
        .await
        .map_err(|error| error.to_string())??;
        if found.is_some() {
            return Ok(found);
        }
    }
    for user in inventory.offline_file_users {
        let store: Arc<dyn MissionStore> = Arc::new(
            mission_store::FileMissionStore::new(inventory.base_dir.clone(), &user).await?,
        );
        if let Some(mission) = find_existing_pr_writer(&store, github_pr, exclude_id).await? {
            return Ok(Some(mission));
        }
    }
    Ok(None)
}

pub(super) async fn ensure_pr_writer_resume_is_exclusive(
    control_hub: &ControlHub,
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
) -> Result<(), String> {
    if !mission_is_pr_writer_in_store(store, mission).await? {
        return Ok(());
    }
    let Some(github_pr) = mission.project.github_pr.as_deref() else {
        return Ok(());
    };
    if let Some(existing) =
        find_existing_pr_writer_global(control_hub, github_pr, Some(mission.id)).await?
    {
        return Err(format!(
            "PR writer lease is already held by mission {} (status={}); cannot resume mission {} as another writer for {}",
            existing.id,
            existing.status,
            mission.id,
            canonical_github_pr(github_pr)
        ));
    }
    Ok(())
}

pub(super) async fn activate_mission_for_message(
    control_hub: &ControlHub,
    store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    mission: &Mission,
    content: &str,
) -> Result<(), String> {
    // Both sequential dequeue and parallel follow-up activation pass here.
    // Retags are refused for the lifetime of the queue, so its mission identity
    // remains the binding; validate that this binding still owns its track.
    if let (Some(state), Some(slug), Some(track)) = (
        control_hub
            .admission_state
            .get()
            .and_then(std::sync::Weak::upgrade),
        mission.project.project.as_deref(),
        mission.project.track.as_deref(),
    ) {
        let writer = mission_is_pr_writer_in_store(store, mission).await?
            || message_requests_pr_writer(mission, content);
        let request = super::super::track_leases::lease_request(
            slug,
            track,
            &mission.id.to_string(),
            super::super::track_leases::lease_mode(
                writer.then_some(true),
                &mission.project.tags,
                mission.project.intent.as_deref(),
            ),
            None,
        );
        state.projects.revalidate_track_lease(&request)?;
    }
    // Keep the writer mutex until Active is persisted so a replacement writer
    // cannot race a terminal mission's message-based reactivation.
    let _pr_writer_guard =
        match acquire_pr_writer_lease_for_message(control_hub, store, mission, content).await {
            Ok(guard) => guard,
            Err(error)
                if mission.status == MissionStatus::Pending
                    && error.contains("PR writer lease is already held") =>
            {
                // A pending writer that conflicts with an existing durable writer
                // cannot become runnable by retrying the same deferred goal. Make
                // the deterministic rejection terminal and clear the goal so the
                // scheduler does not emit the same error every cooldown interval.
                let reason = "pr_writer_lease_conflict";
                store
                    .update_mission_status_with_reason(
                        mission.id,
                        MissionStatus::Interrupted,
                        Some(reason),
                    )
                    .await?;
                store.set_deferred_goal(mission.id, None).await?;
                let _ = events_tx.send(AgentEvent::MissionStatusChanged {
                    completion: None,
                    execution: None,
                    mission_id: mission.id,
                    status: MissionStatus::Interrupted,
                    summary: Some(format!("{reason}: {error}")),
                });
                return Err(error);
            }
            Err(error) => return Err(error),
        };

    if message_activates_mission(mission.status) {
        store
            .update_mission_status(mission.id, MissionStatus::Active)
            .await?;
        // The original create prompt stays in deferred_goal after first
        // dispatch so a capacity-race retry can re-inject it while still
        // Pending. Once a later operator message activates the mission,
        // that stale prompt must not be re-dispatched (or concatenated onto)
        // after the next failure.
        let _ = store.set_deferred_goal(mission.id, None).await;
        let _ = events_tx.send(AgentEvent::MissionStatusChanged {
            completion: None,
            execution: None,
            mission_id: mission.id,
            status: MissionStatus::Active,
            summary: None,
        });
    }
    Ok(())
}

pub(super) async fn activate_mission_id_for_message(
    control_hub: &ControlHub,
    store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    mission_id: Uuid,
    content: &str,
) -> Result<(), String> {
    let mission = store
        .get_mission(mission_id)
        .await?
        .ok_or_else(|| format!("mission {mission_id} no longer exists"))?;
    activate_mission_for_message(control_hub, store, events_tx, &mission, content).await
}

pub(super) async fn restore_mission_after_failed_run_acquisition(
    store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    mission: &Mission,
) -> Result<(), String> {
    store
        .restore_mission_status(
            mission.id,
            &crate::api::mission_store::MissionStatusSnapshot::capture(mission),
        )
        .await?;
    let _ = events_tx.send(AgentEvent::MissionStatusChanged {
        completion: None,
        execution: None,
        mission_id: mission.id,
        status: mission.status,
        summary: Some("Run acquisition failed; prior mission status restored".to_string()),
    });
    Ok(())
}

pub(super) fn host_followup_parked(mission: &Mission) -> bool {
    mission.status == MissionStatus::Paused
        || (mission.status == MissionStatus::Pending
            && !mission.is_dispatchable_at(chrono::Utc::now()))
}

pub(super) async fn rollback_host_parallel_followup(
    store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    runner: &mut super::super::mission_runner::MissionRunner,
    previous: &Mission,
    deferred_goal: Option<String>,
) -> Result<(), String> {
    if let Some(message) = runner.inflight_message().cloned() {
        runner.remove_inflight_message(message.id);
        runner.queue.push_front(message);
    }
    restore_mission_after_failed_run_acquisition(store, events_tx, previous).await?;
    store.set_deferred_goal(previous.id, deferred_goal).await
}

pub(super) async fn prepare_host_parallel_followup(
    hub: &ControlHub,
    store: &Arc<dyn MissionStore>,
    events_tx: &tokio::sync::broadcast::Sender<AgentEvent>,
    runner: &mut super::super::mission_runner::MissionRunner,
    owner: &str,
) -> Result<Option<(Mission, Option<String>)>, String> {
    if runner.is_running() || runner.cancellation_requested() {
        return Ok(None);
    }
    let Some(message) = runner.inflight_message().or_else(|| runner.queue.front()) else {
        return Ok(None);
    };
    if !host_followup_source(message.source.as_deref()) {
        return Ok(None);
    }
    let content = message.content.clone();
    let mission = store
        .get_mission(runner.mission_id)
        .await?
        .ok_or_else(|| "Queued mission no longer exists".to_string())?;
    if host_followup_parked(&mission) {
        return Ok(None);
    }
    dispatch_admission::admit_followup(hub, store, mission.id, &content).await?;
    let deferred_goal = store.get_deferred_goal(mission.id).await?;
    activate_mission_for_message(hub, store, events_tx, &mission, &content).await?;
    runner.backend_id = mission.backend.clone();
    runner.agent_override = mission.agent.clone();
    runner.model_override = mission.model_override.clone();
    runner.model_effort = mission.model_effort.clone();
    runner.fast_mode = mission.fast_mode;
    runner.service_tier = mission.service_tier;
    runner.config_profile = mission.config_profile.clone();
    runner.session_id = mission.session_id.clone();
    if runner.inflight_message().is_none() {
        runner.take_next_message_for_start();
    }
    if let Err(error) = runner.acquire_durable_run(store, owner).await {
        rollback_host_parallel_followup(store, events_tx, runner, &mission, deferred_goal).await?;
        return Err(error);
    }
    Ok(Some((mission, deferred_goal)))
}

pub(super) struct MessageWriterLeaseGuard {
    pub(super) _guard: DurablePrWriterLockGuard,
    pub(super) retagged: bool,
}

pub(super) async fn acquire_pr_writer_lease_for_message(
    control_hub: &ControlHub,
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
    content: &str,
) -> Result<Option<MessageWriterLeaseGuard>, String> {
    let was_writer = mission_is_pr_writer_in_store(store, mission).await?;
    let becomes_writer = was_writer || message_requests_pr_writer(mission, content);
    if !becomes_writer {
        return Ok(None);
    }

    let guard = acquire_durable_pr_writer_lock(control_hub).await?;
    if let Some(github_pr) = mission.project.github_pr.as_deref() {
        if let Some(existing) =
            find_existing_pr_writer_global(control_hub, github_pr, Some(mission.id)).await?
        {
            return Err(format!(
                "PR writer lease is already held by mission {} (status={}); cannot activate mission {} as another writer for {}",
                existing.id,
                existing.status,
                mission.id,
                canonical_github_pr(github_pr)
            ));
        }
    }

    let retagged = !was_writer;
    if retagged {
        let mut tags = mission.project.tags.clone();
        tags.retain(|tag| tag != "pr-readonly" && tag != "pr-writer");
        tags.push("pr-writer".to_string());
        store
            .update_mission_project(
                mission.id,
                crate::api::mission_store::MissionProjectPatch {
                    tag_patch: Some(crate::api::mission_store::MissionTagPatch::capabilities(
                        &tags,
                    )),
                    ..Default::default()
                },
            )
            .await?;
    }

    Ok(Some(MessageWriterLeaseGuard {
        _guard: guard,
        retagged,
    }))
}

pub(super) async fn rollback_message_writer_tag(
    store: &Arc<dyn MissionStore>,
    mission: &Mission,
    lease: &Option<MessageWriterLeaseGuard>,
) {
    if lease.as_ref().is_some_and(|lease| lease.retagged) {
        let _ = store
            .update_mission_project(
                mission.id,
                crate::api::mission_store::MissionProjectPatch {
                    tag_patch: Some(crate::api::mission_store::MissionTagPatch::capabilities(
                        &mission.project.tags,
                    )),
                    ..Default::default()
                },
            )
            .await;
    }
}
