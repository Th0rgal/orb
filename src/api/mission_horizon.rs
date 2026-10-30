//! Item-first mission horizon.
//!
//! Controllers should see durable work items (`track` / `task_key`) and only
//! the live or unabsorbed attempts on those items. Historical, acknowledged,
//! completed, and replaced attempts stay in the store for lineage but drop
//! out of the default listing and the project snapshot.
//!
//! Wake routing prefers the bound project conversation over an isolated
//! `webhook:mission-complete:*` session.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Serialize;
use uuid::Uuid;

use super::control::events::MissionStatus;
use super::mission_store::{
    default_attention_keeps, Mission, MissionFilter, MissionProjectPatch, MissionStore,
    SUPERSEDED_TAG,
};
use super::projects_store::{ProjectTrack, RoadmapProposal};

/// How this mission participates in a PR, if at all. Writer and reviewer
/// attempts on the same track are different items.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriterRole {
    Writer,
    Readonly,
    None,
}

pub fn writer_role(mission: &Mission) -> WriterRole {
    if mission.project.tags.iter().any(|tag| tag == "pr-writer") {
        WriterRole::Writer
    } else if mission.project.tags.iter().any(|tag| tag == "pr-readonly") {
        WriterRole::Readonly
    } else {
        WriterRole::None
    }
}

/// Tag prefix recording *which* attempt replaced this one, so the board can
/// show "relayed by …" and never count the superseded attempt as a problem.
pub const SUPERSEDED_BY_PREFIX: &str = "superseded_by:";

/// The attempt that superseded this mission, if any (from its tags).
pub fn superseded_by(mission: &Mission) -> Option<Uuid> {
    mission
        .project
        .tags
        .iter()
        .filter_map(|tag| tag.strip_prefix(SUPERSEDED_BY_PREFIX))
        .filter_map(|id| Uuid::parse_str(id.trim()).ok())
        .next_back()
}

/// The replacement chain around `id`: earlier attempts (nearest first, found
/// through their `superseded_by:` tag) and later ones (following this
/// mission's own tag). Bounded and cycle-safe.
pub async fn replacement_chain(
    store: &dyn MissionStore,
    id: Uuid,
) -> Result<(Vec<Uuid>, Vec<Uuid>), String> {
    const DEPTH: usize = 16;
    let mut seen = std::collections::HashSet::from([id]);
    let mut earlier = Vec::new();
    let mut cursor = id;
    while earlier.len() < DEPTH {
        let filter = MissionFilter {
            tag: Some(format!("{SUPERSEDED_BY_PREFIX}{cursor}")),
            ..Default::default()
        };
        let Some(prior) = store
            .list_missions_filtered(&filter, 4, 0)
            .await?
            .into_iter()
            .filter(|m| superseded_by(m) == Some(cursor))
            .max_by_key(|m| m.created_at.clone())
        else {
            break;
        };
        if !seen.insert(prior.id) {
            break;
        }
        earlier.push(prior.id);
        cursor = prior.id;
    }
    let mut later = Vec::new();
    let mut next = store
        .get_mission(id)
        .await?
        .as_ref()
        .and_then(superseded_by);
    while let Some(successor) = next.filter(|_| later.len() < DEPTH) {
        if !seen.insert(successor) {
            break;
        }
        later.push(successor);
        next = store
            .get_mission(successor)
            .await?
            .as_ref()
            .and_then(superseded_by);
    }
    Ok((earlier, later))
}

/// Optional remote-node context allowing `absorb` to immediately cancel any
/// in-flight or queued remote job belonging to a superseded mission so orphan
/// workers (`consult_model` / remote child attempts) release their node slot.
pub struct RemoteSupersedeContext<'a> {
    pub working_dir: &'a Path,
    pub remote_nodes: &'a crate::remote_node::RemoteNodeSettings,
    pub fleet: &'a std::sync::Arc<crate::remote_node::FleetMonitor>,
}

pub async fn cancel_superseded_remote_jobs_by_id(
    store: &dyn MissionStore,
    prior_id: Uuid,
    remote: &RemoteSupersedeContext<'_>,
) {
    crate::api::control::usage_limit_wait::update_remote_wait(remote.working_dir, prior_id, |_| {
        None
    })
    .await;

    let handles = match crate::remote_node::job_ledger::load(remote.working_dir).await {
        Ok(handles) => handles,
        Err(error) => {
            tracing::warn!(
                mission_id = %prior_id,
                ?error,
                "could not read remote job ledger while superseding mission"
            );
            return;
        }
    };
    let client = crate::remote_node::RemoteNodeClient::default();
    for handle in handles.into_iter().filter(|h| h.mission_id == prior_id) {
        if crate::managed::node_provably_gone(&handle.node_id).await {
            let _ = super::control::finish_remote_job_lease(
                store,
                prior_id,
                handle.job_id,
                "superseded",
            )
            .await;
            let _ = store
                .complete_scheduled_remote_job(
                    prior_id,
                    handle.job_id,
                    Some(false),
                    Some("superseded".to_string()),
                )
                .await;
            let _ = crate::remote_node::job_ledger::finalize(
                remote.working_dir,
                handle.job_id,
                "cancelled",
                None,
            )
            .await;
            continue;
        }

        let Some(node) = remote.remote_nodes.node(&handle.node_id).cloned() else {
            tracing::warn!(
                mission_id = %prior_id,
                job_id = %handle.job_id,
                node_id = %handle.node_id,
                "superseded remote job node config unavailable; poll loop will cancel if attached"
            );
            continue;
        };
        let Some(shared_token) = crate::remote_node::node_token(&node.token_env)
            .ok()
            .filter(|token| !token.trim().is_empty())
        else {
            tracing::warn!(
                mission_id = %prior_id,
                job_id = %handle.job_id,
                node_id = %handle.node_id,
                "superseded remote job node token unavailable; poll loop will cancel if attached"
            );
            continue;
        };

        let cancel_res = client
            .cancel_job_with_reason(&node, &shared_token, handle.job_id, "core", "superseded")
            .await;
        if let Err(ref error) = cancel_res {
            tracing::warn!(
                mission_id = %prior_id,
                job_id = %handle.job_id,
                node_id = %node.id,
                ?error,
                "superseded remote job cancel request failed; poll/untracked observer will retry"
            );
        }

        let confirmed_terminal = match client.get_job(&node, &shared_token, handle.job_id).await {
            Ok(status) if crate::remote_node::job_state_confirms_termination(&status.state) => {
                Some(status)
            }
            Err(error) if error.is_not_found() && cancel_res.is_ok() => Some(
                crate::remote_node::missing_job_cancelled(prior_id, handle.job_id),
            ),
            _ => None,
        };

        let lease_owner = super::control::remote_job_lease_owner(handle.job_id);
        let active_run = store.get_active_mission_run(prior_id).await.ok().flatten();
        let owns_active_lease = active_run
            .as_ref()
            .is_some_and(|run| run.owner_actor_id == lease_owner);

        if let Some(status) = confirmed_terminal {
            let _ = store
                .complete_scheduled_remote_job(
                    prior_id,
                    handle.job_id,
                    Some(status.state == "succeeded"),
                    (status.state != "succeeded").then(|| "superseded".to_string()),
                )
                .await;
            let _ = super::control::finish_remote_job_lease(
                store,
                prior_id,
                handle.job_id,
                "superseded",
            )
            .await;
            if crate::remote_node::job_ledger::finalize_with_artifacts(
                remote.working_dir,
                handle.job_id,
                &status.state,
                status.exit_code,
                status.artifacts.clone(),
            )
            .await
            .is_ok()
            {
                remote
                    .fleet
                    .record_outcome(crate::remote_node::DispatchOutcome {
                        mission_id: prior_id,
                        node_id: node.id,
                        job_id: Some(handle.job_id),
                        state: status.state,
                        exit_code: status.exit_code,
                        error: status.error,
                        started_at: handle.started_at,
                        finished_at: Some(chrono::Utc::now()),
                    });
            }
        } else if !owns_active_lease {
            // No live `poll_remote_job` owns a run lease for this handle (e.g.
            // tentative handle or detached handle); spawn background retry
            // cancellation so the node slot is guaranteed to be released.
            super::control::spawn_untracked_remote_job_cancellation_with_reason(
                std::sync::Arc::clone(remote.fleet),
                node,
                shared_token,
                prior_id,
                handle.job_id,
                handle.started_at,
                remote.working_dir.to_path_buf(),
                "superseded",
            );
        }
    }
    if matches!(store.get_active_mission_run(prior_id).await, Ok(None)) {
        if let Err(error) = store
            .update_mission_status(prior_id, MissionStatus::Acknowledged)
            .await
        {
            tracing::warn!(
                mission_id = %prior_id,
                %error,
                "could not acknowledge a superseded attempt after remote cancellation"
            );
        }
    }
}

/// Mark `prior` as replaced by `successor`: tag it (`superseded` +
/// `superseded_by:<id>`), move its child missions under the successor, cancel
/// any active/queued remote job, and when no run is live, acknowledge it so it
/// leaves the attention horizon. Idempotent.
async fn absorb(
    store: &dyn MissionStore,
    prior: &Mission,
    successor: Uuid,
    remote: Option<&RemoteSupersedeContext<'_>>,
) -> Result<(), String> {
    let mut tags = prior.project.tags.clone();
    if !tags.iter().any(|tag| tag == SUPERSEDED_TAG) {
        tags.push(SUPERSEDED_TAG.to_string());
    }
    let by = format!("{SUPERSEDED_BY_PREFIX}{successor}");
    if !tags.iter().any(|tag| tag == &by) {
        tags.retain(|tag| !tag.starts_with(SUPERSEDED_BY_PREFIX));
        tags.push(by);
    }
    store
        .update_mission_project(
            prior.id,
            MissionProjectPatch {
                tag_patch: Some(super::mission_store::MissionTagPatch::between(
                    &prior.project.tags,
                    &tags,
                )),
                ..Default::default()
            },
        )
        .await?;
    // Workers follow the coordinator that replaced theirs: their completions
    // reach the live attempt, and the superseded one stays deletable.
    // A successor inside the prior's own tree would close a cycle; leave it.
    let mut ancestor = Some(successor);
    let mut depth = 0;
    let mut inside = false;
    while let Some(id) = ancestor.filter(|_| depth < 64) {
        if id == prior.id {
            inside = true;
            break;
        }
        ancestor = store
            .get_mission(id)
            .await?
            .and_then(|m| m.parent_mission_id);
        depth += 1;
    }
    let moved = if inside {
        Vec::new()
    } else {
        store.reparent_child_missions(prior.id, successor).await?
    };
    if !moved.is_empty() {
        tracing::info!(prior = %prior.id, %successor, count = moved.len(), "moved workers to the superseding mission");
    }
    if let Some(remote) = remote {
        cancel_superseded_remote_jobs_by_id(store, prior.id, remote).await;
    }
    if store.get_active_mission_run(prior.id).await?.is_none() {
        if let Err(error) = store
            .update_mission_status(prior.id, MissionStatus::Acknowledged)
            .await
        {
            tracing::warn!(
                mission_id = %prior.id,
                %error,
                "could not acknowledge a superseded attempt"
            );
        }
    }
    Ok(())
}

/// An explicit relay: the caller names the attempt it replaces
/// (`supersedes_mission_id`). Used when a controller hands work to a new
/// mission on another backend after a failure, whatever the track tagging.
/// Refused across projects; a mission may not absorb itself.
pub async fn supersede_explicit(
    store: &dyn MissionStore,
    new_mission: &Mission,
    prior_id: Uuid,
) -> Result<(), String> {
    supersede_explicit_with_remote(store, new_mission, prior_id, None).await
}

pub async fn supersede_explicit_with_remote(
    store: &dyn MissionStore,
    new_mission: &Mission,
    prior_id: Uuid,
    remote: Option<&RemoteSupersedeContext<'_>>,
) -> Result<(), String> {
    if prior_id == new_mission.id {
        return Err("a mission cannot supersede itself".to_string());
    }
    let Some(prior) = store.get_mission(prior_id).await? else {
        return Err(format!("mission {prior_id} not found"));
    };
    let same_project = match (
        prior.project.project.as_deref().map(str::trim),
        new_mission.project.project.as_deref().map(str::trim),
    ) {
        (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
        (None, _) => true,
        (Some(_), None) => false,
    };
    if !same_project {
        return Err(format!(
            "mission {prior_id} belongs to project {:?}, not {:?}",
            prior.project.project, new_mission.project.project
        ));
    }
    absorb(store, &prior, new_mission.id, remote).await
}

fn role_label(role: WriterRole) -> Option<&'static str> {
    match role {
        WriterRole::Writer => Some("pr-writer"),
        WriterRole::Readonly => Some("pr-readonly"),
        WriterRole::None => None,
    }
}

/// Absorb every prior attention-horizon attempt on the same
/// `(project, track, writer role)` so a new start replaces the old one
/// without a separate model acknowledge.
pub async fn supersede_prior_attempts(
    store: &dyn MissionStore,
    new_mission: &Mission,
) -> Result<Vec<Uuid>, String> {
    supersede_prior_attempts_with_remote(store, new_mission, None).await
}

pub async fn supersede_prior_attempts_with_remote(
    store: &dyn MissionStore,
    new_mission: &Mission,
    remote: Option<&RemoteSupersedeContext<'_>>,
) -> Result<Vec<Uuid>, String> {
    let Some(project) = new_mission
        .project
        .project
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(Vec::new());
    };
    let Some(track) = new_mission
        .project
        .track
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(Vec::new());
    };
    let role = writer_role(new_mission);
    let candidates = store
        .list_missions_filtered(
            &MissionFilter {
                project: Some(project.to_string()),
                track: Some(track.to_string()),
                attention_only: true,
                ..Default::default()
            },
            50,
            0,
        )
        .await?;
    let mut absorbed = Vec::new();
    for prior in candidates {
        if prior.id == new_mission.id || writer_role(&prior) != role {
            continue;
        }
        absorb(store, &prior, new_mission.id, remote).await?;
        absorbed.push(prior.id);
    }
    Ok(absorbed)
}

/// One durable work item as presented to a controller.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProjectItem {
    pub key: String,
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub desired_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub acceptance_criteria: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub depends_on: Vec<String>,
    pub open: bool,
    /// True when a `project_tracks` or leftover proposal row declared this
    /// item. Mission-only attention rows stay off the public roadmap.
    pub declared: bool,
    pub attempts: Vec<ProjectItemAttempt>,
    /// Stable track id (None for mission-only rows and leftover proposals).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// `declared` | `imported` | `absorbed`, from the track row.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub revision: u64,
    /// Operator-declared structured blocker, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocker: Option<String>,
}

/// A declared track is open unless it is done, closed, or cancelled.
/// Missing, empty, `running`, and `in-progress` all count as open — that is
/// how `set_project_track` and existing store rows already behave.
pub fn track_status_is_open(status: Option<&str>) -> bool {
    !matches!(
        status.map(str::trim).filter(|value| !value.is_empty()),
        Some("done") | Some("closed") | Some("cancelled") | Some("satisfied")
    )
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProjectItemAttempt {
    pub id: Uuid,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

/// Group declared tracks, open proposals, and attention-horizon missions
/// into items. Historical / absorbed missions never become the inventory.
pub fn project_items(
    tracks: &[ProjectTrack],
    proposals: &[RoadmapProposal],
    missions: &[Mission],
) -> Vec<ProjectItem> {
    let mut items: BTreeMap<String, ProjectItem> = BTreeMap::new();
    for track in tracks {
        items.insert(
            track.track.clone(),
            ProjectItem {
                key: track.track.clone(),
                kind: "track",
                position: Some(track.position),
                desired_state: track.desired_state.clone(),
                status: track.status.clone(),
                title: track.title.clone(),
                acceptance_criteria: track.acceptance_criteria.clone(),
                depends_on: track.depends_on.clone(),
                open: track_status_is_open(track.status.as_deref()),
                declared: true,
                attempts: Vec::new(),
                id: Some(track.id.clone()),
                origin: Some(track.origin.clone()),
                revision: track.revision,
                blocker: track.explicit_blocker.clone(),
            },
        );
    }
    for proposal in proposals {
        items
            .entry(proposal.task_key.clone())
            .or_insert_with(|| ProjectItem {
                key: proposal.task_key.clone(),
                kind: "task",
                position: None,
                desired_state: proposal.prompt.clone(),
                status: Some("proposed".to_string()),
                title: Some(proposal.title.clone()),
                acceptance_criteria: proposal.acceptance_criteria.clone(),
                depends_on: proposal.depends_on.clone(),
                open: true,
                declared: true,
                attempts: Vec::new(),
                id: None,
                origin: Some("declared".to_string()),
                revision: 0,
                blocker: None,
            });
    }
    for mission in missions {
        if !default_attention_keeps(mission) {
            continue;
        }
        let key = mission
            .project
            .track
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("untagged")
            .to_string();
        let item = items.entry(key.clone()).or_insert_with(|| ProjectItem {
            key: key.clone(),
            kind: "track",
            position: None,
            desired_state: mission.project.desired_state.clone(),
            status: None,
            title: None,
            acceptance_criteria: Vec::new(),
            depends_on: Vec::new(),
            open: true,
            declared: false,
            attempts: Vec::new(),
            id: None,
            origin: Some("absorbed".to_string()),
            revision: 0,
            blocker: None,
        });
        item.attempts.push(ProjectItemAttempt {
            id: mission.id,
            status: mission.status.to_string(),
            title: mission.title.clone(),
            updated_at: mission.updated_at.clone(),
            role: role_label(writer_role(mission)).map(str::to_string),
        });
        item.open = true;
    }
    for item in items.values_mut() {
        item.attempts
            .sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    }
    let mut items: Vec<_> = items.into_values().collect();
    items.sort_by(|left, right| match (left.position, right.position) {
        (Some(left_position), Some(right_position)) => left_position
            .cmp(&right_position)
            .then_with(|| left.key.cmp(&right.key)),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => left.key.cmp(&right.key),
    });
    items
}

/// Where a terminal / `awaiting_user` callback should land.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WakeTarget {
    pub session: Option<String>,
    pub source: &'static str,
}

impl WakeTarget {
    pub fn isolated() -> Self {
        Self {
            session: None,
            source: "isolated",
        }
    }
}

/// Prefer the bound project conversation, then the creating origin.
/// Isolated is last: that is the `webhook:mission-complete:*` fallback.
pub fn resolve_mission_wake_target(
    origin_session: Option<&str>,
    project_session: Option<&str>,
) -> WakeTarget {
    if let Some(session) = project_session
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return WakeTarget {
            session: Some(session.to_string()),
            source: "project",
        };
    }
    if let Some(session) = origin_session
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return WakeTarget {
            session: Some(session.to_string()),
            source: "origin",
        };
    }
    WakeTarget::isolated()
}

/// Read-only lookup of the bound control session. Does not open the
/// projects store (which would migrate); a missing file is "no binding".
pub fn bound_session_from_projects_db(working_dir: &Path, slug: &str) -> Option<String> {
    let path = working_dir.join(".sandboxed-sh/projects.db");
    if !path.exists() {
        return None;
    }
    let connection =
        rusqlite::Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    let canonical = crate::api::projects_overview::canonicalize_project_slug(slug);
    for key in crate::api::projects_overview::project_tag_keys(&canonical) {
        if let Some(session) = connection
            .query_row(
                "SELECT control_session_id FROM project_bindings WHERE slug = ?1",
                [&key],
                |row| row.get::<_, String>(0),
            )
            .ok()
            .map(|session: String| session.trim().to_string())
            .filter(|session| !session.is_empty())
        {
            return Some(session);
        }
    }
    None
}

/// Tag stamped onto subagents/workers launched inside a `/btw` side-question
/// subtree so every client and store query can exclude them without walking
/// unbounded lineage, while keeping `btw-parent:<uuid>` reserved for the `/btw`
/// thread itself.
pub const BTW_SUBAGENT_TAG: &str = "btw-subagent";

/// True when `tag` is a reserved `/btw` lineage marker (`btw-parent:*` or `btw-subagent`).
pub fn is_reserved_btw_tag(tag: &str) -> bool {
    tag.starts_with("btw-parent:") || tag == BTW_SUBAGENT_TAG
}

/// True when a mission is an interactive `/btw` side-question fork (`btw-parent:<uuid>`).
/// Side-question turns answer the operator inline in Orb and must never wake Paloma
/// or project conversations on completion.
pub fn is_btw_side_mission(mission: &Mission) -> bool {
    mission
        .project
        .tags
        .iter()
        .any(|tag| tag.starts_with("btw-parent:"))
}

/// True when a mission is either a `/btw` side-question thread or a worker
/// launched inside a `/btw` subtree (`btw-subagent`).
pub fn is_btw_subtree_mission(mission: &Mission) -> bool {
    mission
        .project
        .tags
        .iter()
        .any(|tag| is_reserved_btw_tag(tag))
}

/// Shipped wake decision for a mission-status webhook: project binding,
/// then origin, else isolated.
/// A worker started by another mission reports to that mission unless it has its own
/// direct `origin_session_id` (not merely a project-level binding). Interactive `/btw`
/// side missions and their descendants also never wake Paloma.
pub fn reports_to_parent_mission(mission: &Mission, _wake: Option<&WakeTarget>) -> bool {
    is_btw_subtree_mission(mission)
        || (mission.parent_mission_id.is_some()
            && mission
                .origin_session_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .is_none())
}

pub fn wake_fields_for_mission(mission: &Mission, working_dir: &Path) -> WakeTarget {
    let bound = mission
        .project
        .project
        .as_deref()
        .and_then(|slug| bound_session_from_projects_db(working_dir, slug));
    resolve_mission_wake_target(mission.origin_session_id.as_deref(), bound.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mission_store::{InMemoryMissionStore, MissionStore};

    #[tokio::test]
    async fn a_worker_without_a_conversation_reports_only_to_its_parent() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let parent = store
            .create_mission(Some("boss"), None, None, None, None, None, None)
            .await
            .unwrap();
        let mut worker = store
            .create_mission_with_parent(
                Some("worker"),
                None,
                None,
                None,
                None,
                false,
                None,
                None,
                Some(parent.id),
                None,
            )
            .await
            .unwrap();
        assert!(reports_to_parent_mission(
            &worker,
            Some(&WakeTarget::isolated())
        ));
        assert!(reports_to_parent_mission(&worker, None));
        // A project-level binding does not turn a child worker into a chat-waking mission;
        // only an explicit origin_session_id on the worker itself wakes that conversation.
        let bound = WakeTarget {
            session: Some("s1".into()),
            source: "project",
        };
        assert!(reports_to_parent_mission(&worker, Some(&bound)));
        worker.origin_session_id = Some("hermes-session".into());
        assert!(!reports_to_parent_mission(
            &worker,
            Some(&WakeTarget::isolated())
        ));
        // An interactive /btw side-question mission never wakes Hermes even without parent_mission_id.
        let mut btw = parent.clone();
        btw.project.tags.push(format!("btw-parent:{}", parent.id));
        assert!(is_btw_side_mission(&btw));
        assert!(is_btw_subtree_mission(&btw));
        assert!(reports_to_parent_mission(&btw, Some(&bound)));
        let mut btw_worker = parent.clone();
        btw_worker.project.tags.push(BTW_SUBAGENT_TAG.to_string());
        assert!(!is_btw_side_mission(&btw_worker));
        assert!(is_btw_subtree_mission(&btw_worker));
        assert!(reports_to_parent_mission(&btw_worker, Some(&bound)));
        // A mission without a parent is not a worker.
        assert!(!reports_to_parent_mission(
            &parent,
            Some(&WakeTarget::isolated())
        ));
    }
    use crate::api::projects_store::ProjectsStore;
    use std::sync::Arc;

    async fn seed(
        store: &Arc<dyn MissionStore>,
        title: &str,
        project: &str,
        track: &str,
        status: MissionStatus,
        tags: &[&str],
    ) -> Mission {
        let mission = store
            .create_mission(Some(title), None, None, None, None, None, None)
            .await
            .expect("create");
        store
            .update_mission_project(
                mission.id,
                MissionProjectPatch {
                    project: Some(Some(project.to_string())),
                    track: Some(Some(track.to_string())),
                    tags: Some(tags.iter().map(|tag| (*tag).to_string()).collect()),
                    ..Default::default()
                },
            )
            .await
            .expect("tag");
        if status != MissionStatus::Pending {
            store
                .update_mission_status(mission.id, status)
                .await
                .expect("status");
        }
        store
            .get_mission(mission.id)
            .await
            .expect("get")
            .expect("exists")
    }

    async fn default_list(store: &Arc<dyn MissionStore>) -> Vec<Uuid> {
        store
            .list_missions_filtered(
                &MissionFilter {
                    attention_only: true,
                    ..Default::default()
                },
                50,
                0,
            )
            .await
            .expect("list")
            .into_iter()
            .map(|mission| mission.id)
            .collect()
    }

    #[tokio::test]
    async fn default_list_keeps_live_and_unabsorbed_failed() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let live = seed(&store, "live", "verity", "core", MissionStatus::Active, &[]).await;
        let waiting = seed(
            &store,
            "waiting",
            "verity",
            "core",
            MissionStatus::AwaitingUser,
            &[],
        )
        .await;
        let failed = seed(
            &store,
            "failed",
            "verity",
            "review",
            MissionStatus::Failed,
            &[],
        )
        .await;
        let interrupted = seed(
            &store,
            "interrupted",
            "verity",
            "review",
            MissionStatus::Interrupted,
            &[],
        )
        .await;
        let acked = seed(
            &store,
            "acked",
            "verity",
            "old",
            MissionStatus::Acknowledged,
            &[],
        )
        .await;
        let completed = seed(
            &store,
            "done",
            "verity",
            "old",
            MissionStatus::Completed,
            &[],
        )
        .await;
        let absorbed = seed(
            &store,
            "replaced",
            "verity",
            "core",
            MissionStatus::Failed,
            &[SUPERSEDED_TAG],
        )
        .await;

        let ids = default_list(&store).await;
        assert!(ids.contains(&live.id));
        assert!(ids.contains(&waiting.id));
        assert!(ids.contains(&failed.id));
        assert!(ids.contains(&interrupted.id));
        assert!(!ids.contains(&acked.id));
        assert!(!ids.contains(&completed.id));
        assert!(!ids.contains(&absorbed.id));
    }

    #[tokio::test]
    async fn start_attempt_absorbs_the_prior_same_item() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let first = seed(
            &store,
            "attempt-1",
            "coldcard",
            "skip-kernel",
            MissionStatus::Failed,
            &[],
        )
        .await;
        let second = seed(
            &store,
            "attempt-2",
            "coldcard",
            "skip-kernel",
            MissionStatus::Pending,
            &[],
        )
        .await;

        let absorbed = supersede_prior_attempts(store.as_ref(), &second)
            .await
            .expect("supersede");
        assert_eq!(absorbed, vec![first.id]);

        let ids = default_list(&store).await;
        assert!(ids.contains(&second.id));
        assert!(!ids.contains(&first.id));

        let prior = store
            .get_mission(first.id)
            .await
            .expect("get")
            .expect("exists");
        assert_eq!(prior.status, MissionStatus::Acknowledged);
        assert!(prior.project.tags.iter().any(|tag| tag == SUPERSEDED_TAG));
        assert_eq!(superseded_by(&prior), Some(second.id));
    }

    #[tokio::test]
    async fn an_explicit_relay_absorbs_a_failed_attempt_without_a_track() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let failed = seed(
            &store,
            "fable-attempt",
            "eip-8282",
            "entry-reach",
            MissionStatus::Failed,
            &[],
        )
        .await;
        // The relay carries the project but a different (or no) track.
        let relay = seed(
            &store,
            "codex-relay",
            "eip-8282",
            "entry-reach-relay",
            MissionStatus::Pending,
            &[],
        )
        .await;
        assert!(
            supersede_prior_attempts(store.as_ref(), &relay)
                .await
                .expect("supersede")
                .is_empty(),
            "a different track never absorbs implicitly"
        );
        supersede_explicit(store.as_ref(), &relay, failed.id)
            .await
            .expect("explicit relay");
        let prior = store
            .get_mission(failed.id)
            .await
            .expect("get")
            .expect("exists");
        assert_eq!(prior.status, MissionStatus::Acknowledged);
        assert_eq!(superseded_by(&prior), Some(relay.id));
        // Idempotent and refuses nonsense.
        supersede_explicit(store.as_ref(), &relay, failed.id)
            .await
            .expect("replay");
        assert!(supersede_explicit(store.as_ref(), &relay, relay.id)
            .await
            .is_err());
        let other = seed(
            &store,
            "elsewhere",
            "verity-core",
            "x",
            MissionStatus::Failed,
            &[],
        )
        .await;
        assert!(supersede_explicit(store.as_ref(), &relay, other.id)
            .await
            .is_err());
    }

    #[tokio::test]
    async fn a_relay_takes_over_the_superseded_coordinators_workers() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let old = seed(
            &store,
            "coordinator",
            "verity-core",
            "solidity-import",
            MissionStatus::Completed,
            &["pr-writer"],
        )
        .await;
        let worker = store
            .create_mission_with_parent(
                Some("worker"),
                None,
                None,
                None,
                None,
                false,
                None,
                None,
                Some(old.id),
                None,
            )
            .await
            .unwrap();
        let relay = seed(
            &store,
            "relay",
            "verity-core",
            "solidity-import",
            MissionStatus::Pending,
            &["pr-writer"],
        )
        .await;
        supersede_explicit(store.as_ref(), &relay, old.id)
            .await
            .unwrap();
        assert!(store.get_child_missions(old.id).await.unwrap().is_empty());
        let moved = store.get_mission(worker.id).await.unwrap().unwrap();
        assert_eq!(moved.parent_mission_id, Some(relay.id));
    }

    #[tokio::test]
    async fn a_relay_from_inside_the_tree_keeps_the_hierarchy_acyclic() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let old = store
            .create_mission(Some("coordinator"), None, None, None, None, None, None)
            .await
            .unwrap();
        let child = store
            .create_mission_with_parent(
                Some("child"),
                None,
                None,
                None,
                None,
                false,
                None,
                None,
                Some(old.id),
                None,
            )
            .await
            .unwrap();
        let grandchild = store
            .create_mission_with_parent(
                Some("grandchild"),
                None,
                None,
                None,
                None,
                false,
                None,
                None,
                Some(child.id),
                None,
            )
            .await
            .unwrap();
        supersede_explicit(store.as_ref(), &grandchild, old.id)
            .await
            .unwrap();
        let child = store.get_mission(child.id).await.unwrap().unwrap();
        assert_eq!(child.parent_mission_id, Some(old.id));
    }

    #[tokio::test]
    async fn writer_and_reviewer_do_not_absorb_each_other() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let writer = seed(
            &store,
            "write",
            "lido",
            "merge-66",
            MissionStatus::AwaitingUser,
            &["pr-writer"],
        )
        .await;
        let reviewer = seed(
            &store,
            "review",
            "lido",
            "merge-66",
            MissionStatus::Pending,
            &["pr-readonly"],
        )
        .await;

        let absorbed = supersede_prior_attempts(store.as_ref(), &reviewer)
            .await
            .expect("supersede");
        assert!(absorbed.is_empty());
        let ids = default_list(&store).await;
        assert!(ids.contains(&writer.id));
        assert!(ids.contains(&reviewer.id));
    }

    #[tokio::test]
    async fn project_items_are_keyed_by_track_not_history() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let live = seed(&store, "now", "verity", "core", MissionStatus::Active, &[]).await;
        seed(
            &store,
            "old",
            "verity",
            "core",
            MissionStatus::Completed,
            &[],
        )
        .await;
        seed(
            &store,
            "replaced",
            "verity",
            "core",
            MissionStatus::Failed,
            &[SUPERSEDED_TAG],
        )
        .await;
        let failed = seed(
            &store,
            "review-fail",
            "verity",
            "review",
            MissionStatus::Failed,
            &[],
        )
        .await;

        let tracks = vec![ProjectTrack {
            track: "core".to_string(),
            desired_state: Some("landed".to_string()),
            status: Some("active".to_string()),
            title: Some("Core".to_string()),
            acceptance_criteria: vec!["merged".to_string()],
            depends_on: Vec::new(),
            updated_at: "2026-08-14T00:00:00Z".to_string(),
            id: "id".to_string(),
            lifecycle: "active".to_string(),
            origin: "declared".to_string(),
            explicit_blocker: None,
            revision: 0,
            claim: None,
            position: 0,
            governed_artifact_version: None,
            accepted_at: None,
        }];
        let proposals = vec![RoadmapProposal {
            task_key: "docs".to_string(),
            title: "Write the guide".to_string(),
            prompt: None,
            acceptance_criteria: Vec::new(),
            depends_on: Vec::new(),
            created_at: "2026-08-14T00:00:00Z".to_string(),
            updated_at: "2026-08-14T00:00:00Z".to_string(),
        }];
        let missions = store.list_missions(50, 0).await.expect("all");
        let items = project_items(&tracks, &proposals, &missions);

        let core = items.iter().find(|item| item.key == "core").expect("core");
        assert_eq!(core.kind, "track");
        assert!(core.open);
        assert_eq!(core.attempts.len(), 1);
        assert_eq!(core.attempts[0].id, live.id);

        let review = items
            .iter()
            .find(|item| item.key == "review")
            .expect("review");
        assert_eq!(review.attempts.len(), 1);
        assert_eq!(review.attempts[0].id, failed.id);

        let docs = items.iter().find(|item| item.key == "docs").expect("docs");
        assert_eq!(docs.kind, "task");
        assert!(docs.open);
        assert!(docs.attempts.is_empty());

        assert!(items.iter().all(|item| item
            .attempts
            .iter()
            .all(|attempt| attempt.id != live.id || item.key == "core")));

        let cancelled = vec![ProjectTrack {
            track: "old-pr46".to_string(),
            desired_state: Some("certify PR 46".to_string()),
            status: Some("cancelled".to_string()),
            title: None,
            acceptance_criteria: Vec::new(),
            depends_on: Vec::new(),
            updated_at: "2026-08-01T00:00:00Z".to_string(),
            id: "id".to_string(),
            lifecycle: "active".to_string(),
            origin: "declared".to_string(),
            explicit_blocker: None,
            revision: 0,
            claim: None,
            position: 0,
            governed_artifact_version: None,
            accepted_at: None,
        }];
        let closed = project_items(&cancelled, &[], &[]);
        assert_eq!(closed.len(), 1);
        assert!(!closed[0].open, "cancelled tracks are not open items");
        assert!(core.declared);
        assert_eq!(core.title.as_deref(), Some("Core"));
        assert_eq!(core.acceptance_criteria, vec!["merged"]);
        assert!(docs.declared);
        assert!(!review.declared, "mission-only items are not declared");
        let missing = project_items(
            &[ProjectTrack {
                track: "running-pr".to_string(),
                desired_state: None,
                status: Some("running".to_string()),
                title: None,
                acceptance_criteria: Vec::new(),
                depends_on: Vec::new(),
                updated_at: "2026-08-14T00:00:00Z".to_string(),
                id: "id".to_string(),
                lifecycle: "active".to_string(),
                origin: "declared".to_string(),
                explicit_blocker: None,
                revision: 0,
                claim: None,
                position: 0,
                governed_artifact_version: None,
                accepted_at: None,
            }],
            &[],
            &[],
        );
        assert!(missing[0].open, "running is an open track status");
        assert!(track_status_is_open(None));
        assert!(track_status_is_open(Some("")));
        assert!(track_status_is_open(Some("in-progress")));
        assert!(!track_status_is_open(Some("closed")));
        let historical = missions
            .iter()
            .filter(|mission| {
                matches!(
                    mission.status,
                    MissionStatus::Completed | MissionStatus::Acknowledged
                ) || mission.project.tags.iter().any(|tag| tag == SUPERSEDED_TAG)
            })
            .count();
        assert!(historical >= 2);
        assert!(items
            .iter()
            .flat_map(|item| item.attempts.iter())
            .all(|attempt| attempt.status != "completed" && attempt.status != "acknowledged"));
    }

    #[test]
    fn wake_prefers_project_binding_over_origin_and_isolated() {
        let isolated = resolve_mission_wake_target(None, None);
        assert_eq!(isolated.source, "isolated");
        assert!(isolated.session.is_none());

        let origin = resolve_mission_wake_target(Some("origin-sess"), None);
        assert_eq!(origin.source, "origin");
        assert_eq!(origin.session.as_deref(), Some("origin-sess"));

        let project = resolve_mission_wake_target(Some("origin-sess"), Some("project-tip"));
        assert_eq!(project.source, "project");
        assert_eq!(project.session.as_deref(), Some("project-tip"));
        assert_ne!(
            project.session.as_deref(),
            Some("webhook:mission-complete:x")
        );
    }

    #[tokio::test]
    async fn shipped_wake_path_uses_project_tip_from_binding() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_dir = dir.path().join(".sandboxed-sh");
        std::fs::create_dir_all(&db_dir).expect("mkdir");
        let store = ProjectsStore::open(db_dir.join("projects.db")).expect("projects db");
        store
            .upsert_project("benchmark", Some("Benchmark"), None, None, None)
            .expect("project");
        store
            .set_binding("benchmark", "20260814_094937_8c5097", None)
            .expect("bind");

        let missions: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let mut mission = seed(
            &missions,
            "strat-50",
            "benchmark",
            "run",
            MissionStatus::AwaitingUser,
            &[],
        )
        .await;
        mission.origin_session_id = Some("20260814_review_child".to_string());

        let wake = wake_fields_for_mission(&mission, dir.path());
        assert_eq!(wake.source, "project");
        assert_eq!(wake.session.as_deref(), Some("20260814_094937_8c5097"));
    }

    #[tokio::test]
    async fn the_replacement_chain_never_includes_an_unrelated_mission() {
        let store: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let first = seed(&store, "security", "ops", "t", MissionStatus::Failed, &[]).await;
        let second = seed(
            &store,
            "security (fresh session)",
            "ops",
            "t",
            MissionStatus::Failed,
            &[],
        )
        .await;
        let third = seed(
            &store,
            "security (fresh session) (fresh session)",
            "ops",
            "t",
            MissionStatus::Active,
            &[],
        )
        .await;
        let unrelated = seed(&store, "elsewhere", "ops", "u", MissionStatus::Failed, &[]).await;
        supersede_explicit(store.as_ref(), &second, first.id)
            .await
            .unwrap();
        supersede_explicit(store.as_ref(), &third, second.id)
            .await
            .unwrap();
        let (earlier, later) = replacement_chain(store.as_ref(), third.id).await.unwrap();
        assert_eq!(earlier, vec![second.id, first.id]);
        assert!(later.is_empty());
        let (earlier, later) = replacement_chain(store.as_ref(), second.id).await.unwrap();
        assert_eq!((earlier, later), (vec![first.id], vec![third.id]));
        let (earlier, later) = replacement_chain(store.as_ref(), unrelated.id)
            .await
            .unwrap();
        assert!(earlier.is_empty() && later.is_empty());
    }

    #[tokio::test]
    async fn superseding_attempt_cancels_active_remote_job_and_acknowledges_mission() {
        use axum::{
            extract::{Path as AxumPath, State as AxumState},
            http::HeaderMap,
            routing::{get, post},
            Json, Router,
        };
        use std::sync::Mutex;

        #[derive(Default)]
        struct FakeNodeState {
            cancels: Mutex<Vec<(Uuid, String, String)>>,
            state: Mutex<String>,
        }

        let node_state = Arc::new(FakeNodeState {
            cancels: Mutex::new(Vec::new()),
            state: Mutex::new("queued".to_string()),
        });
        let app_state = Arc::clone(&node_state);
        let app =
            Router::new()
                .route(
                    "/jobs/:id/cancel",
                    post(
                        |AxumState(st): AxumState<Arc<FakeNodeState>>,
                         AxumPath(id): AxumPath<Uuid>,
                         headers: HeaderMap| async move {
                            let actor = headers
                                .get("x-sandboxed-cancel-actor")
                                .and_then(|v| v.to_str().ok())
                                .unwrap_or("")
                                .to_string();
                            let reason = headers
                                .get("x-sandboxed-cancel-reason")
                                .and_then(|v| v.to_str().ok())
                                .unwrap_or("")
                                .to_string();
                            st.cancels.lock().unwrap().push((id, actor, reason));
                            *st.state.lock().unwrap() = "cancelled".to_string();
                            Json(crate::remote_node::CancelJobResponse {
                                job_id: id,
                                state: "cancelled".to_string(),
                                cancel_requested: true,
                            })
                        },
                    ),
                )
                .route(
                    "/jobs/:id",
                    get(
                        |AxumState(st): AxumState<Arc<FakeNodeState>>,
                         AxumPath(id): AxumPath<Uuid>| async move {
                            let cur = st.state.lock().unwrap().clone();
                            Json(crate::remote_node::NodeJobStatus {
                                cancellation: None,
                                job_id: id,
                                mission_id: Uuid::nil(),
                                state: cur.clone(),
                                exit_code: (cur == "cancelled").then_some(130),
                                created_at: chrono::Utc::now().to_rfc3339(),
                                started_at: None,
                                finished_at: (cur == "cancelled")
                                    .then(|| chrono::Utc::now().to_rfc3339()),
                                error: None,
                                log_tail: None,
                                artifacts: Vec::new(),
                            })
                        },
                    ),
                )
                .with_state(app_state);

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            crate::api::mission_store::SqliteMissionStore::new(
                dir.path().to_path_buf(),
                "test-user",
            )
            .await
            .unwrap(),
        );
        let prior = seed(
            &store,
            "consult-attempt-1",
            "orb",
            "review-track",
            MissionStatus::Active,
            &[],
        )
        .await;
        let successor = seed(
            &store,
            "consult-attempt-2",
            "orb",
            "review-track",
            MissionStatus::Pending,
            &[],
        )
        .await;

        let job_id = Uuid::new_v4();
        let token_env = format!("SANDBOXED_TEST_SUPERSEDE_TOKEN_{}", Uuid::new_v4().simple());
        std::env::set_var(&token_env, "test-node-secret");

        crate::remote_node::job_ledger::record(
            dir.path(),
            crate::remote_node::job_ledger::JobHandle {
                mission_id: prior.id,
                node_id: "babylon".to_string(),
                job_id,
                started_at: chrono::Utc::now(),
                submission_sequence: 0,
                accepted_at: Some(chrono::Utc::now()),
                heartbeat_at: Some(chrono::Utc::now()),
                disk_reservation_bytes: 0,
                kind: crate::remote_node::job_ledger::JobHandleKind::Mission,
                identity: None,
                wait_for_completion: None,
                wake_on_terminal: false,
            },
        )
        .await
        .unwrap();
        let run = store
            .begin_mission_run(
                prior.id,
                &super::super::control::remote_job_lease_owner(job_id),
                Some("remote-node:babylon"),
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .get_active_mission_run(prior.id)
                .await
                .unwrap()
                .unwrap()
                .run_id,
            run.run_id
        );

        let remote_nodes = crate::remote_node::RemoteNodeSettings {
            enabled: true,
            nodes: vec![crate::remote_node::RemoteNodeConfig {
                id: "babylon".to_string(),
                base_url: format!("http://{addr}"),
                token_env: token_env.clone(),
                labels: None,
            }],
        };
        let fleet = Arc::new(crate::remote_node::FleetMonitor::new());
        let remote_ctx = RemoteSupersedeContext {
            working_dir: dir.path(),
            remote_nodes: &remote_nodes,
            fleet: &fleet,
        };

        let absorbed =
            supersede_prior_attempts_with_remote(store.as_ref(), &successor, Some(&remote_ctx))
                .await
                .unwrap();
        std::env::remove_var(&token_env);
        server.abort();

        assert_eq!(absorbed, vec![prior.id]);
        let cancels = node_state.cancels.lock().unwrap().clone();
        assert_eq!(
            cancels,
            vec![(job_id, "core".to_string(), "superseded".to_string())]
        );
        assert!(
            crate::remote_node::job_ledger::load(dir.path())
                .await
                .unwrap()
                .is_empty(),
            "superseded job ledger handle must be finalized"
        );
        assert!(
            store
                .get_active_mission_run(prior.id)
                .await
                .unwrap()
                .is_none(),
            "superseded remote job run lease must be finished"
        );
        let updated_prior = store.get_mission(prior.id).await.unwrap().unwrap();
        assert_eq!(updated_prior.status, MissionStatus::Acknowledged);
        assert_eq!(superseded_by(&updated_prior), Some(successor.id));
    }
}
