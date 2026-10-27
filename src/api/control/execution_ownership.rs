//! Ownership evidence is independent of presentation status and heartbeat age.
//! Read-only snapshots combine every store with accepted remote handles and
//! actor-owned work. Duplicate store observations retain the more conservative
//! claim; a failed read cannot establish quiescence.
use super::*;
use rusqlite::Connection;

#[derive(Clone)]
struct Owner {
    status: MissionStatus,
    reason: Option<String>,
    pr: Option<String>,
    pr_known: bool,
    read_only: bool,
}

#[derive(Clone)]
struct DirectoryOwner {
    id: Uuid,
    workspace_id: Uuid,
    working_directory: Option<String>,
    directory_owner: Uuid,
}

#[derive(Default)]
pub(crate) struct Snapshot {
    directories: Vec<DirectoryOwner>,
    owners: HashMap<Uuid, Vec<Owner>>,
    unresolved: HashSet<Uuid>,
    queued_assignments: HashSet<Uuid>,
    /// Accepted remote handles per mission with the repository each one
    /// validates. `None` is a raw command or legacy handle whose target is
    /// unknown; it cannot prove that the mission is unrelated to any PR.
    remote: HashMap<Uuid, Vec<Option<String>>>,
}

/// `owner/repo` of a GitHub repository reference in any of the forms the
/// remote build ledger and PR fields carry (https/http/ssh URLs, `git@`
/// scp-style, `github.com/...`, bare `owner/repo`, optional `.git`). `None`
/// for anything else: an unrecognised identity must not prove disjointness.
pub(crate) fn canonical_github_repository(raw: &str) -> Option<String> {
    let mut value = raw
        .trim()
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .trim_end_matches('/')
        .to_ascii_lowercase();
    for prefix in [
        "https://github.com/",
        "http://github.com/",
        "ssh://git@github.com/",
        "git@github.com:",
        "github.com/",
    ] {
        if let Some(stripped) = value.strip_prefix(prefix) {
            value = stripped.to_string();
            break;
        }
    }
    if value.contains("://") || value.contains(['@', ':']) {
        return None;
    }
    let value = value.strip_suffix(".git").unwrap_or(&value);
    let mut segments = value.split('/');
    let (owner, repo, rest) = (segments.next()?, segments.next()?, segments.next());
    let valid = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    (rest.is_none() && valid(owner) && valid(repo)).then(|| format!("{owner}/{repo}"))
}

/// Repository of a canonical `owner/repo#number` PR reference.
fn pr_repository(canonical_pr: &str) -> Option<String> {
    canonical_pr
        .split_once('#')
        .and_then(|(repository, _)| canonical_github_repository(repository))
}

impl Snapshot {
    fn mission(&mut self, mission: Mission) {
        self.directories.push(DirectoryOwner {
            id: mission.id,
            workspace_id: mission.workspace_id,
            working_directory: mission.working_directory.clone(),
            directory_owner: fork_directory_owner(mission.id, &mission.project.tags),
        });
        let read_only = crate::api::track_leases::lease_mode(
            None,
            &mission.project.tags,
            mission.project.intent.as_deref(),
        ) == "reader";
        self.owners.entry(mission.id).or_default().push(Owner {
            read_only,
            status: mission.status,
            reason: mission.terminal_reason,
            pr: mission.project.github_pr,
            pr_known: true,
        });
    }

    fn queue(&mut self, payload: &str) -> Result<(), String> {
        if payload.trim().is_empty() {
            return Ok(());
        }
        let items: Vec<QueuedMessage> = serde_json::from_str(payload).map_err(|e| e.to_string())?;
        // Consumed messages are idempotency markers; their actual execution is
        // represented by a run/actor/remote handle, not by historical content.
        for message in items.into_iter().filter(|m| !m.inflight) {
            if let Some(id) = message.mission_id {
                if host_followup_source(message.source.as_deref()) {
                    self.queued_assignments.insert(id);
                } else {
                    self.unresolved.insert(id);
                }
            }
        }
        Ok(())
    }

    /// None proves that no enumerated store knows this owner. Some(false)
    /// proves all known presentations terminal and no unresolved execution.
    pub(crate) fn holds_track(&self, id: Uuid) -> Option<bool> {
        let in_unresolved = self.unresolved.contains(&id);
        let in_queued = self.queued_assignments.contains(&id);
        let owners = self.owners.get(&id);
        if !in_unresolved && !in_queued && owners.is_none() {
            return None;
        }
        let has_live = owners.is_some_and(|list| {
            list.iter()
                .any(|o| !(o.status.is_terminal() || o.status == MissionStatus::Acknowledged))
        });
        let native_holds = owners.is_some_and(|list| {
            list.iter()
                .any(|o| native_goal_holds_ownership(o.status, o.reason.as_deref()))
        });
        Some(crate::orb_spec::track_hold_active(
            crate::orb_spec::TrackHold {
                in_unresolved,
                in_queued,
                has_live_owner: has_live,
                native_goal_holds: native_holds,
            },
        ))
    }

    /// Every persisted owner counts, even archived missions. A different mission
    /// can resume from the same physical checkout after a fork or alias.
    pub(crate) async fn require_unshared_directory(
        &self,
        state: &AppState,
        id: Uuid,
        source: &std::path::Path,
    ) -> Result<(), String> {
        for owner in self.directories.iter().filter(|owner| owner.id != id) {
            let ws = state
                .workspaces
                .get(owner.workspace_id)
                .await
                .ok_or("Cannot verify another mission's workspace placement")?;
            let path = match &owner.working_directory {
                Some(path) => std::path::PathBuf::from(path),
                None => workspace::mission_workspace_dir_for_workspace(&ws, owner.directory_owner),
            };
            // Resolve the parent even while the source is quarantined. A
            // fork's path may be temporarily absent but still owns this inode.
            let physical = if path.try_exists().map_err(|e| e.to_string())? {
                path.canonicalize()
                    .map_err(|e| format!("Cannot verify shared workspace: {e}"))?
            } else {
                let parent = path.parent().ok_or("Missing workspace parent")?;
                let parent = parent
                    .canonicalize()
                    .map_err(|e| format!("Cannot verify workspace root: {e}"))?;
                parent.join(path.file_name().ok_or("Missing workspace directory name")?)
            };
            if physical.starts_with(source) || source.starts_with(&physical) {
                return Err(format!(
                    "Workspace is shared with mission {}; retain it",
                    owner.id
                ));
            }
        }
        Ok(())
    }

    /// Whether this mission's accepted remote work can touch `target`'s
    /// repository. A mission with no remote handle has no remote claim. Any
    /// handle whose repository is unknown, or any repository equal to the
    /// target's, conflicts; a ledger identity naming a different GitHub
    /// repository on every handle proves the remote work disjoint. When the
    /// target repository itself cannot be parsed nothing is provable.
    fn remote_conflicts_with(&self, id: Uuid, target_repository: Option<&str>) -> bool {
        let Some(repositories) = self.remote.get(&id) else {
            return false;
        };
        repositories.iter().any(|repository| {
            let parsed = repository.as_deref().and_then(canonical_github_repository);
            let same = parsed
                .as_deref()
                .zip(target_repository)
                .is_some_and(|(r, t)| r == t);
            !crate::orb_spec::repo_disjoint(crate::orb_spec::RepoDisjoint {
                handle_repo_known: parsed.is_some(),
                target_repo_known: target_repository.is_some(),
                same_repo: same,
            })
        })
    }

    pub(super) fn unresolved_pr_writer(
        &self,
        pr: &str,
        exclude: Option<Uuid>,
    ) -> Option<PrWriterLease> {
        let target = canonical_github_pr(pr);
        let target_repository = pr_repository(&target);
        self.unresolved
            .iter()
            .filter(|id| Some(**id) != exclude)
            .find_map(|id| {
                let owners = self.owners.get(id);
                // Missing assignment evidence cannot prove that a still-unresolved
                // execution is unrelated to the requested PR — unless every
                // remote handle of that execution names a different repository.
                let remote = self.remote_conflicts_with(*id, target_repository.as_deref());
                let conflicting = owners.map_or(remote, |owners| {
                    owners.iter().any(|owner| {
                        !owner.read_only
                            && ((!owner.pr_known && remote)
                                || owner
                                    .pr
                                    .as_deref()
                                    .is_some_and(|pr| canonical_github_pr(pr) == target))
                    })
                });
                conflicting.then(|| PrWriterLease {
                    id: *id,
                    status: owners
                        .and_then(|owners| owners.first())
                        .map_or(MissionStatus::Active, |owner| owner.status),
                })
            })
    }
}

fn fork_directory_owner(id: Uuid, tags: &[String]) -> Uuid {
    tags.iter()
        .find_map(|tag| {
            tag.strip_prefix("fork-workspace:")
                .and_then(|id| Uuid::parse_str(id).ok())
        })
        .unwrap_or(id)
}

fn columns(conn: &Connection, table: &str) -> Result<HashSet<String>, String> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| row.get(1))
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<HashSet<_>, _>>()
        .map_err(|e| e.to_string())
}

fn read_sqlite(path: &std::path::Path, snapshot: &mut Snapshot) -> Result<(), String> {
    let conn = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("open {} read-only: {e}", path.display()))?;
    conn.busy_timeout(std::time::Duration::from_secs(2))
        .map_err(|e| e.to_string())?;
    let cols = columns(&conn, "missions")?;
    let optional = |name: &str| {
        if cols.contains(name) {
            name.to_string()
        } else {
            "NULL".into()
        }
    };
    let query = format!(
        "SELECT id,status,{},{},{},{},{},{} FROM missions",
        optional("terminal_reason"),
        optional("github_pr"),
        optional("tags"),
        optional("intent"),
        optional("workspace_id"),
        optional("working_directory")
    );
    let mut stmt = conn.prepare(&query).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Option<String>>(4)?,
                r.get::<_, Option<String>>(5)?,
                r.get::<_, Option<String>>(6)?,
                r.get::<_, Option<String>>(7)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    for row in rows {
        let (id, status, reason, pr, tags, intent, workspace_id, working_directory) =
            row.map_err(|e| e.to_string())?;
        let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
        let status =
            serde_json::from_value(serde_json::Value::String(status)).map_err(|e| e.to_string())?;
        let tags: Vec<String> = tags
            .map(|t| serde_json::from_str(&t))
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or_default();
        snapshot.directories.push(DirectoryOwner {
            id,
            workspace_id: workspace_id
                .as_deref()
                .map(Uuid::parse_str)
                .transpose()
                .map_err(|e| e.to_string())?
                .unwrap_or(Uuid::nil()),
            working_directory,
            directory_owner: fork_directory_owner(id, &tags),
        });
        let read_only =
            crate::api::track_leases::lease_mode(None, &tags, intent.as_deref()) == "reader";
        snapshot.owners.entry(id).or_default().push(Owner {
            status,
            reason,
            pr,
            pr_known: cols.contains("github_pr"),
            read_only,
        });
    }
    if !columns(&conn, "mission_runs")?.is_empty() {
        let mut stmt = conn
            .prepare("SELECT mission_id FROM mission_runs WHERE execution_state <> 'terminal'")
            .map_err(|e| e.to_string())?;
        for row in stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
        {
            snapshot.unresolved.insert(
                Uuid::parse_str(&row.map_err(|e| e.to_string())?).map_err(|e| e.to_string())?,
            );
        }
    }
    if !columns(&conn, "control_queue")?.is_empty() {
        let mut stmt = conn
            .prepare("SELECT payload FROM control_queue")
            .map_err(|e| e.to_string())?;
        for row in stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
        {
            snapshot.queue(&row.map_err(|e| e.to_string())?)?;
        }
    }
    Ok(())
}

fn read_file(path: &std::path::Path, snapshot: &mut Snapshot) -> Result<(), String> {
    #[derive(Deserialize)]
    struct FileSnapshot {
        missions: HashMap<Uuid, Mission>,
        #[serde(default)]
        runs: HashMap<Uuid, MissionRun>,
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let file: FileSnapshot = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    for mission in file.missions.into_values() {
        snapshot.mission(mission);
    }
    snapshot.unresolved.extend(
        file.runs
            .into_values()
            .filter(|run| !run.execution_state.is_terminal())
            .map(|run| run.mission_id),
    );
    Ok(())
}

pub(crate) async fn snapshot(hub: &ControlHub) -> Result<Snapshot, String> {
    let mut snapshot = Snapshot::default();
    for handle in crate::remote_node::job_ledger::load(&hub.config.working_dir)
        .await
        .map_err(|e| e.to_string())?
    {
        snapshot
            .remote
            .entry(handle.mission_id)
            .or_default()
            .push(handle.identity.map(|identity| identity.repository));
    }
    snapshot.unresolved.extend(snapshot.remote.keys().copied());
    for session in hub.all_sessions().await {
        snapshot
            .unresolved
            .extend(session.assignment_owners.read().await.iter().copied());
    }
    let inventory = hub.mission_store_inventory().await?;
    for store in inventory.live {
        snapshot.unresolved.extend(
            store
                .list_active_mission_runs()
                .await?
                .into_iter()
                .map(|run| run.mission_id),
        );
        // SQLite ignores this argument; file/memory have no persisted queue.
        snapshot.queue(&store.load_control_queue("").await?)?;
        // One store read: updated_at can change between offset pages and
        // omission here would release a parked mission's writer claims.
        let missions = store.list_missions(usize::MAX, 0).await?;
        #[cfg(test)]
        super::dispatch_admission_tests::after_ownership_page(&missions);
        for mission in missions {
            snapshot.mission(mission);
        }
    }
    tokio::task::spawn_blocking(move || {
        for path in inventory.offline_sqlite {
            read_sqlite(&path, &mut snapshot)?;
        }
        for user in inventory.offline_file_users {
            read_file(
                &inventory.base_dir.join(format!("missions-{user}.json")),
                &mut snapshot,
            )?;
        }
        Ok(snapshot)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod repository_identity_tests {
    use super::canonical_github_repository;

    #[test]
    fn github_repository_forms_canonicalise_to_owner_repo() {
        for raw in [
            "https://github.com/LFGLabs-dev/Verity",
            "https://github.com/lfglabs-dev/verity.git",
            "https://github.com/lfglabs-dev/verity/",
            "http://github.com/lfglabs-dev/verity",
            "github.com/lfglabs-dev/verity",
            "git@github.com:lfglabs-dev/verity.git",
            "ssh://git@github.com/lfglabs-dev/verity.git",
            "lfglabs-dev/verity",
            "https://github.com/lfglabs-dev/verity?ref=main#readme",
        ] {
            assert_eq!(
                canonical_github_repository(raw).as_deref(),
                Some("lfglabs-dev/verity"),
                "{raw}"
            );
        }
    }

    #[test]
    fn unrecognised_repositories_prove_nothing() {
        for raw in [
            "",
            "verity",
            "https://example.invalid/lfglabs-dev/verity.git",
            "https://gitlab.com/lfglabs-dev/verity",
            "https://github.com/lfglabs-dev/verity/pull/2406",
            "https://github.com/lfglabs-dev",
            "https://user:token@github.com/lfglabs-dev/verity",
            "lfglabs-dev/verity/extra",
            "lfglabs dev/verity",
        ] {
            assert_eq!(canonical_github_repository(raw), None, "{raw}");
        }
    }
}

#[cfg(test)]
mod followup_tests {
    use super::*;
    #[test]
    fn queued_followup_protects_assignment_without_claiming_execution() {
        let id = Uuid::new_v4();
        let mut snapshot = Snapshot::default();
        snapshot.queue(&serde_json::json!([{"id":Uuid::new_v4(),"content":"continue","mission_id":id,"agent":null,"source":"host-queue:api:test"}]).to_string()).unwrap();
        assert_eq!(snapshot.holds_track(id), Some(true));
        assert!(!snapshot.unresolved.contains(&id));
    }
    #[test]
    fn missing_owner_is_distinct_from_explicitly_unassigned_pr() {
        let id = Uuid::new_v4();
        let mut snapshot = Snapshot::default();
        snapshot.unresolved.insert(id);
        snapshot.remote.insert(id, vec![None]);
        assert!(snapshot.unresolved_pr_writer("org/repo#1", None).is_some());
        snapshot.owners.insert(
            id,
            vec![Owner {
                status: MissionStatus::Active,
                reason: None,
                pr: None,
                pr_known: true,
                read_only: false,
            }],
        );
        assert!(snapshot.unresolved_pr_writer("org/repo#1", None).is_none());
        snapshot.owners.get_mut(&id).unwrap()[0].pr_known = false;
        assert!(snapshot.unresolved_pr_writer("org/repo#1", None).is_some());
        let owner = &mut snapshot.owners.get_mut(&id).unwrap()[0];
        owner.pr_known = true;
        owner.pr = Some("org/repo#2".into());
        assert!(snapshot.unresolved_pr_writer("org/repo#1", None).is_none());
        assert!(snapshot.unresolved_pr_writer("org/repo#2", None).is_some());
    }
}
