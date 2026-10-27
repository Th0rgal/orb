//! Persisted permission to discard a mission filesystem. Presentation status,
//! retention age and directory names never constitute permission.
use super::*;
use chrono::{DateTime, Utc};
use std::path::{Path as FsPath, PathBuf};

const RECOVERY_DAYS: i64 = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Phase {
    Authorized,
    Quarantining,
    Quarantined,
    Removing,
    Purged,
    Revoked,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Receipt {
    pub mission_id: Uuid,
    pub owner: String,
    pub workspace_id: Uuid,
    pub source: PathBuf,
    pub quarantine: PathBuf,
    pub identity: String,
    pub parent_identity: String,
    pub original_mode: u32,
    pub phase: Phase,
    pub not_before: DateTime<Utc>,
    /// This receipt is only minted after the caller explicitly accepts losing
    /// untracked/ignored files and commits which have not been backed up.
    pub discard_work: bool,
}

type Error = (StatusCode, String);
fn conflict(e: impl std::fmt::Display) -> Error {
    (StatusCode::CONFLICT, e.to_string())
}

fn schema(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS mission_workspace_purges (
        mission_id TEXT PRIMARY KEY, receipt TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS mission_workspace_purge_audit (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, mission_id TEXT NOT NULL,
        phase TEXT NOT NULL, owner TEXT NOT NULL, recorded_at TEXT NOT NULL, receipt TEXT NOT NULL);",
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn load(conn: &rusqlite::Connection, id: Uuid) -> Result<Option<Receipt>, String> {
    use rusqlite::OptionalExtension;
    schema(conn)?;
    let raw: Option<String> = conn
        .query_row(
            "SELECT receipt FROM mission_workspace_purges WHERE mission_id=?1",
            [id.to_string()],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    raw.map(|raw| serde_json::from_str(&raw).map_err(|e| e.to_string()))
        .transpose()
}

fn save(conn: &rusqlite::Connection, receipt: &Receipt) -> Result<(), String> {
    schema(conn)?;
    let raw = serde_json::to_string(receipt).map_err(|e| e.to_string())?;
    if load(conn, receipt.mission_id)?
        .as_ref()
        .is_some_and(|old| serde_json::to_string(old).ok().as_ref() == Some(&raw))
    {
        return Ok(());
    }
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO mission_workspace_purges(mission_id,receipt) VALUES (?1,?2)
        ON CONFLICT(mission_id) DO UPDATE SET receipt=excluded.receipt",
        rusqlite::params![receipt.mission_id.to_string(), raw.clone()],
    )
    .map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO mission_workspace_purge_audit(mission_id,phase,owner,recorded_at,receipt)
        VALUES (?1,?2,?3,?4,?5)",
        rusqlite::params![
            receipt.mission_id.to_string(),
            serde_json::to_string(&receipt.phase).map_err(|e| e.to_string())?,
            receipt.owner,
            Utc::now().to_rfc3339(),
            raw
        ],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}

fn read(state: &AppState, id: Uuid) -> Result<Option<Receipt>, String> {
    let conn = state
        .projects
        .connection
        .lock()
        .map_err(|e| e.to_string())?;
    load(&conn, id)
}
fn persist(state: &AppState, receipt: &Receipt) -> Result<(), String> {
    let conn = state
        .projects
        .connection
        .lock()
        .map_err(|e| e.to_string())?;
    save(&conn, receipt)
}

/// Bind permission to an actual directory inode, never a reusable pathname.
#[cfg(unix)]
fn directory_identity(path: &FsPath) -> Result<String, String> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err("Workspace is not a physical directory".into());
    }
    Ok(format!("{}:{}", meta.dev(), meta.ino()))
}
#[cfg(not(unix))]
fn directory_identity(_path: &FsPath) -> Result<String, String> {
    Err("Safe workspace purge requires filesystem identity support".into())
}

pub(crate) async fn revoke_store_locked(
    state: &AppState,
    store: &Arc<dyn MissionStore>,
    id: Uuid,
) -> Result<(), String> {
    if let Some(receipt) = read(state, id)? {
        let owner_store = state
            .control
            .loaded_mission_store(&receipt.owner)
            .await
            .ok_or("Authorizing user store unavailable")?;
        if !Arc::ptr_eq(&owner_store, store) {
            return Err("Workspace authorization belongs to another mission store".into());
        }
    }
    revoke_locked(state, id)
}

pub(crate) fn revoke_owned_locked(state: &AppState, id: Uuid, owner: &str) -> Result<(), String> {
    if read(state, id)?.is_some_and(|receipt| receipt.owner != owner) {
        return Err("Workspace authorization belongs to another user".into());
    }
    revoke_locked(state, id)
}

fn rename_bound(
    source: &FsPath,
    destination: &FsPath,
    parent_identity: &str,
    identity: &str,
) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        super::workspace_purge_fs::rename(source, destination, parent_identity, identity)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (source, destination, parent_identity, identity);
        Err("Anchored workspace purge is unsupported on this platform".into())
    }
}

fn original_mode(path: &FsPath) -> Result<u32, String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(std::fs::metadata(path).map_err(|e| e.to_string())?.mode() & 0o7777)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Err("Unsupported filesystem".into())
    }
}

fn secure_quarantine(receipt: &Receipt, path: &FsPath) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        super::workspace_purge_fs::secure_directory(
            path,
            &receipt.parent_identity,
            &receipt.identity,
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (receipt, path);
        Err("Unsupported filesystem".into())
    }
}

// Recovery must repeat the durability barrier even when a previous rename
// succeeded and its fsync/receipt acknowledgement did not.
fn sync_parent_bound(receipt: &Receipt) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        super::workspace_purge_fs::sync_parent(&receipt.source, &receipt.parent_identity)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = receipt;
        Err("Anchored workspace purge unsupported".into())
    }
}

/// The caller holds process + durable dispatch admission locks. Restoring source
/// and revoking permission precedes all native resume/follow-up admission.
fn revoke_locked(state: &AppState, id: Uuid) -> Result<(), String> {
    let Some(mut receipt) = read(state, id)? else {
        return Ok(());
    };
    restore_receipt(&mut receipt, |receipt| persist(state, receipt))
}

fn restore_receipt(
    receipt: &mut Receipt,
    mut persist: impl FnMut(&Receipt) -> Result<(), String>,
) -> Result<(), String> {
    if directory_identity(receipt.source.parent().ok_or("Workspace parent missing")?)?
        != receipt.parent_identity
    {
        return Err("Workspace parent filesystem identity changed".into());
    }
    match receipt.phase {
        Phase::Revoked => return sync_parent_bound(receipt),
        Phase::Removing | Phase::Purged => {
            return Err(
                "Workspace was explicitly discarded; recover from backup before resuming".into(),
            )
        }
        Phase::Authorized | Phase::Quarantining | Phase::Quarantined => {
            if receipt.quarantine.try_exists().map_err(|e| e.to_string())? {
                if receipt.source.try_exists().map_err(|e| e.to_string())? {
                    return Err(
                        "Both source and quarantine exist; recovery requires reconciliation".into(),
                    );
                }
                if directory_identity(&receipt.quarantine)? != receipt.identity {
                    return Err("Quarantine filesystem identity changed".into());
                }
                rename_bound(
                    &receipt.quarantine,
                    &receipt.source,
                    &receipt.parent_identity,
                    &receipt.identity,
                )?;
            } else if directory_identity(&receipt.source)? != receipt.identity {
                return Err("Authorized workspace is unavailable".into());
            }
        }
    }
    #[cfg(target_os = "linux")]
    super::workspace_purge_fs::restore_mode(
        &receipt.source,
        &receipt.parent_identity,
        &receipt.identity,
        receipt.original_mode,
    )?;
    sync_parent_bound(receipt)?;
    receipt.phase = Phase::Revoked;
    persist(receipt)
}

pub(crate) fn require_history_deletable_locked(state: &AppState, id: Uuid) -> Result<(), String> {
    if read(state, id)?
        .is_some_and(|receipt| !matches!(receipt.phase, Phase::Revoked | Phase::Purged))
    {
        return Err(
            "Restore or finish the authorized workspace purge before deleting its recovery history"
                .into(),
        );
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Request {
    Authorize {
        discard_untracked_ignored_and_unpushed_work: bool,
    },
    Restore,
}

pub async fn operate(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(request): Json<Request>,
) -> Result<Json<serde_json::Value>, Error> {
    let _workspace = machine_transfer::workspace_mutation_lock(id).await;
    let _admission = DISPATCH_ADMISSION.lock().await;
    let _durable = dispatch_admission::durable_lock(&state.config)
        .await
        .map_err(conflict)?;
    let control = control_for_user(&state, &user).await;
    let mission = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(conflict)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Mission not found".into()))?;
    match request {
        Request::Restore => {
            if read(&state, id)
                .map_err(conflict)?
                .is_some_and(|r| r.owner != user.id)
            {
                return Err(conflict("Workspace authorization owner differs"));
            }
            revoke_owned_locked(&state, id, &user.id).map_err(conflict)?;
        }
        Request::Authorize {
            discard_untracked_ignored_and_unpushed_work,
        } => {
            if !discard_untracked_ignored_and_unpushed_work {
                return Err(conflict("Explicit abandonment of untracked/ignored files and unpushed commits is required"));
            }
            if let Some(receipt) = read(&state, id).map_err(conflict)? {
                if receipt.owner != user.id {
                    return Err(conflict("Workspace authorization owner differs"));
                }
                if receipt.phase != Phase::Revoked {
                    return Ok(Json(serde_json::to_value(receipt).map_err(conflict)?));
                }
            }
            let ws = state
                .workspaces
                .get(mission.workspace_id)
                .await
                .ok_or_else(|| conflict("Workspace unavailable"))?;
            workspace::ensure_persisted_mission_root_is_available(&ws, id).map_err(conflict)?;
            let expected = workspace::mission_workspace_dir_for_workspace(&ws, id);
            directory_identity(&expected).map_err(conflict)?;
            let source = expected.canonicalize().map_err(conflict)?;
            check_quiescent(&state, &user, &mission, &source)
                .await
                .map_err(conflict)?;
            if let Some(working) = &mission.working_directory {
                if std::path::Path::new(working)
                    .canonicalize()
                    .map_err(conflict)?
                    != source
                {
                    return Err(conflict(
                        "Mission uses a different/shared working directory; preserve it",
                    ));
                }
            }
            let receipt = Receipt {
                mission_id: id,
                owner: user.id.clone(),
                workspace_id: mission.workspace_id,
                quarantine: source
                    .with_file_name(format!(".purge-mission-{id}-{}", Uuid::new_v4())),
                parent_identity: directory_identity(
                    source
                        .parent()
                        .ok_or_else(|| conflict("Workspace parent missing"))?,
                )
                .map_err(conflict)?,
                identity: directory_identity(&source).map_err(conflict)?,
                original_mode: original_mode(&source).map_err(conflict)?,
                source,
                phase: Phase::Authorized,
                not_before: Utc::now() + chrono::Duration::days(RECOVERY_DAYS),
                discard_work: true,
            };
            persist(&state, &receipt).map_err(conflict)?;
        }
    }
    Ok(Json(
        serde_json::to_value(read(&state, id).map_err(conflict)?).map_err(conflict)?,
    ))
}

// Deliberately conservative: action arguments may refer to aliases, a project,
// a new child, or an implicit issuer mission. Tool allowlists miss accepted work.
pub(crate) fn require_no_accepted_actions(conn: &rusqlite::Connection) -> Result<(), String> {
    let has_actions: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='mcp_actions_v1')", [], |row| row.get(0)).map_err(|e| e.to_string())?;
    if has_actions {
        let unsettled: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM mcp_actions_v1 WHERE state IN ('queued','dispatching','reconciliation_required'))", [], |row| row.get(0)).map_err(|e| e.to_string())?;
        if unsettled {
            return Err("Accepted MCP work is queued, dispatching or uncertain".into());
        }
    }
    Ok(())
}

async fn check_quiescent(
    state: &Arc<AppState>,
    user: &AuthUser,
    mission: &Mission,
    source: &FsPath,
) -> Result<(), String> {
    if !mission.requires_local_disk
        || mission.backend.starts_with("cloud_")
        || client_placement::is_tagged(&mission.project.tags)
    {
        return Err(
            "Remote/client workspace purge requires verified node-local lifecycle support".into(),
        );
    }
    let control = control_for_user(state, user).await;
    if remote_grok::placement(
        &state.config.working_dir,
        &control.mission_store,
        mission.id,
    )
    .await?
    .is_some()
    {
        return Err("Remote workspace state cannot authorize a Core filesystem purge".into());
    }
    machine_transfer::guard(&control.mission_store, mission.id).await?;
    #[cfg(target_os = "linux")]
    super::workspace_purge_fs::require_unambiguous_mount(
        source.parent().ok_or("Missing source parent")?,
    )?;
    #[cfg(not(target_os = "linux"))]
    return Err("Anchored workspace purge is unsupported on this platform".into());
    {
        let conn = state
            .projects
            .connection
            .lock()
            .map_err(|e| e.to_string())?;
        require_no_accepted_actions(&conn)?;
    }
    let snapshot = execution_ownership::snapshot(&state.control).await?;
    if snapshot.holds_track(mission.id) != Some(false) {
        return Err("Mission has live or unresolved execution/queue ownership".into());
    }
    snapshot
        .require_unshared_directory(state, mission.id, source)
        .await?;
    if crate::api::durable_jobs::has_unsettled_workspace_jobs(state, mission.workspace_id, source)
        .await?
    {
        return Err("Workspace jobs are running or uncertain".into());
    }
    let units = crate::api::scope_reaper::try_list_workspace_gc_scope_units().await?;
    if !units.is_empty() {
        // A malformed/legacy scope cannot establish disjointness either.
        return Err("Exec scopes are still present; defer filesystem purge".into());
    }
    Ok(())
}

fn quarantine_receipt(
    receipt: &mut Receipt,
    now: DateTime<Utc>,
    mut persist: impl FnMut(&Receipt) -> Result<(), String>,
) -> Result<(), String> {
    if !receipt.discard_work {
        return Err("Explicit abandonment missing".into());
    }
    if !matches!(receipt.phase, Phase::Authorized | Phase::Quarantining) {
        return Err("Receipt is not authorized for quarantine".into());
    }
    if !receipt.quarantine.try_exists().map_err(|e| e.to_string())? {
        if directory_identity(&receipt.source)? != receipt.identity {
            return Err("Source identity changed".into());
        }
        receipt.not_before = now + chrono::Duration::days(RECOVERY_DAYS);
        receipt.phase = Phase::Quarantining;
        persist(receipt)?;
        secure_quarantine(receipt, &receipt.source)?;
        rename_bound(
            &receipt.source,
            &receipt.quarantine,
            &receipt.parent_identity,
            &receipt.identity,
        )?;
    } else if receipt.source.try_exists().map_err(|e| e.to_string())? {
        return Err("Both source and quarantine exist; reconciliation required".into());
    }
    if directory_identity(&receipt.quarantine)? != receipt.identity {
        return Err("Quarantine identity changed".into());
    }
    secure_quarantine(receipt, &receipt.quarantine)?;
    sync_parent_bound(receipt)?;
    receipt.phase = Phase::Quarantined;
    persist(receipt)
}

fn removal_ready(
    receipt: &mut Receipt,
    now: DateTime<Utc>,
    mut persist: impl FnMut(&Receipt) -> Result<(), String>,
) -> Result<bool, String> {
    if !receipt.discard_work {
        return Err("Explicit abandonment missing".into());
    }
    if !matches!(receipt.phase, Phase::Quarantined | Phase::Removing) {
        return Ok(false);
    }
    if now < receipt.not_before {
        return Ok(false);
    }
    if receipt.source.try_exists().map_err(|e| e.to_string())? {
        return Err("Source reappeared; retaining quarantine".into());
    }
    if receipt.phase == Phase::Quarantined {
        if directory_identity(&receipt.quarantine)? != receipt.identity {
            return Err("Quarantine identity changed".into());
        }
        receipt.phase = Phase::Removing;
        persist(receipt)?;
    }
    Ok(true)
}

/// Scheduled reclamation only consumes persisted explicit permissions. Legacy
/// quarantine names and unindexed directories never enter this queue.
pub(crate) async fn sweep(state: &Arc<AppState>) -> Result<(), String> {
    let ids = {
        let conn = state
            .projects
            .connection
            .lock()
            .map_err(|e| e.to_string())?;
        schema(&conn)?;
        let mut stmt = conn
            .prepare("SELECT mission_id FROM mission_workspace_purges")
            .map_err(|e| e.to_string())?;
        let ids = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        ids
    };
    for raw in ids {
        let id = Uuid::parse_str(&raw).map_err(|e| e.to_string())?;
        let _workspace = machine_transfer::workspace_mutation_lock(id).await;
        let _admission = DISPATCH_ADMISSION.lock().await;
        let _durable = dispatch_admission::durable_lock(&state.config).await?;
        if let Err(error) = sweep_one_locked(state, id).await {
            tracing::warn!(mission_id = %id, %error, "workspace purge retained for recovery/retry");
        }
    }
    Ok(())
}

async fn sweep_one_locked(state: &Arc<AppState>, id: Uuid) -> Result<(), String> {
    let Some(mut receipt) = read(state, id)? else {
        return Ok(());
    };
    if matches!(receipt.phase, Phase::Revoked | Phase::Purged) {
        return Ok(());
    }
    if !receipt.discard_work {
        return Err("Missing explicit abandonment".into());
    }
    let store = state
        .control
        .loaded_mission_store(&receipt.owner)
        .await
        .ok_or("Authorizing user session unavailable")?;
    let mission = store
        .get_mission(id)
        .await?
        .ok_or("Mission unavailable; retaining quarantine")?;
    if mission.workspace_id != receipt.workspace_id {
        return Err("Workspace placement changed".into());
    }
    let user = AuthUser {
        id: receipt.owner.clone(),
        username: receipt.owner.clone(),
    };
    check_quiescent(state, &user, &mission, &receipt.source).await?;
    let ws = state
        .workspaces
        .get(receipt.workspace_id)
        .await
        .ok_or("Workspace unavailable")?;
    workspace::ensure_persisted_mission_root_is_available(&ws, id).map_err(|e| e.to_string())?;
    let expected = workspace::mission_workspace_dir_for_workspace(&ws, id);
    if directory_identity(receipt.source.parent().ok_or("Workspace parent missing")?)?
        != receipt.parent_identity
    {
        return Err("Workspace parent filesystem identity changed".into());
    }
    if expected.file_name() != receipt.source.file_name() {
        return Err("Workspace path changed".into());
    }
    if expected.parent().and_then(|p| p.canonicalize().ok())
        != receipt.source.parent().map(FsPath::to_path_buf)
    {
        return Err("Workspace root changed/unavailable".into());
    }
    if matches!(receipt.phase, Phase::Authorized | Phase::Quarantining) {
        quarantine_receipt(&mut receipt, Utc::now(), |receipt| persist(state, receipt))?;
        tracing::info!(mission_id = %id, not_before = %receipt.not_before, "workspace purge quarantined");
        return Ok(());
    }
    if !removal_ready(&mut receipt, Utc::now(), |receipt| persist(state, receipt))? {
        return Ok(());
    }
    #[cfg(target_os = "linux")]
    {
        let removal = receipt.clone();
        tokio::task::spawn_blocking(move || {
            super::workspace_purge_fs::remove(
                &removal.quarantine,
                &removal.parent_identity,
                &removal.identity,
            )
        })
        .await
        .map_err(|e| e.to_string())??;
    }
    #[cfg(not(target_os = "linux"))]
    return Err("Anchored workspace purge is unsupported on this platform".into());
    receipt.phase = Phase::Purged;
    persist(state, &receipt)?;
    tracing::info!(mission_id = %id, "workspace purge completed");
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, rusqlite::Connection, Receipt) {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("mission-source");
        std::fs::create_dir(&source).unwrap();
        std::fs::write(source.join("untracked"), b"unsaved work").unwrap();
        std::fs::create_dir(source.join("ignored-build")).unwrap();
        std::fs::write(source.join("ignored-build/artifact"), b"only copy").unwrap();
        let receipt = Receipt {
            mission_id: Uuid::new_v4(),
            owner: "test-user".into(),
            workspace_id: Uuid::nil(),
            identity: directory_identity(&source).unwrap(),
            parent_identity: directory_identity(temp.path()).unwrap(),
            original_mode: original_mode(&source).unwrap(),
            source,
            quarantine: temp.path().join("quarantine"),
            phase: Phase::Authorized,
            not_before: Utc::now(),
            discard_work: true,
        };
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        save(&conn, &receipt).unwrap();
        (temp, conn, receipt)
    }

    #[test]
    fn workspace_purge_all_accepted_queue_states_block_reclamation() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE mcp_actions_v1(tool TEXT, arguments TEXT, state TEXT);")
            .unwrap();
        for state in ["queued", "dispatching", "reconciliation_required"] {
            conn.execute(
                "INSERT INTO mcp_actions_v1 VALUES('resume_mission','{}',?1)",
                [state],
            )
            .unwrap();
            assert!(require_no_accepted_actions(&conn).is_err());
            conn.execute("DELETE FROM mcp_actions_v1", []).unwrap();
        }
        conn.execute(
            "INSERT INTO mcp_actions_v1 VALUES('resume_mission','{}','completed')",
            [],
        )
        .unwrap();
        require_no_accepted_actions(&conn).unwrap();
    }

    #[test]
    fn workspace_purge_authorization_and_audit_survive_reopen_and_retry() {
        let (temp, _, receipt) = fixture();
        let db = temp.path().join("receipts.db");
        {
            let conn = rusqlite::Connection::open(&db).unwrap();
            save(&conn, &receipt).unwrap();
            save(&conn, &receipt).unwrap();
        }
        let conn = rusqlite::Connection::open(db).unwrap();
        let loaded = load(&conn, receipt.mission_id).unwrap().unwrap();
        assert_eq!(loaded.identity, receipt.identity);
        assert!(loaded.discard_work);
        let count: i64 = conn
            .query_row(
                "SELECT count(*) FROM mission_workspace_purge_audit",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "a retry must not duplicate an audit transition");
        assert!(receipt.source.join("untracked").exists());
    }

    #[test]
    fn workspace_purge_quarantine_is_recoverable_and_revoke_fences_removal() {
        let (_temp, conn, mut receipt) = fixture();
        let now = Utc::now();
        quarantine_receipt(&mut receipt, now, |r| save(&conn, r)).unwrap();
        assert!(!receipt.source.exists());
        assert!(receipt.quarantine.join("untracked").exists());
        assert!(
            !removal_ready(&mut receipt, now + chrono::Duration::days(6), |r| save(
                &conn, r
            ))
            .unwrap()
        );
        restore_receipt(&mut receipt, |r| save(&conn, r)).unwrap();
        assert_eq!(
            load(&conn, receipt.mission_id).unwrap().unwrap().phase,
            Phase::Revoked
        );
        assert_eq!(
            std::fs::read(receipt.source.join("ignored-build/artifact")).unwrap(),
            b"only copy"
        );
        assert!(
            !removal_ready(&mut receipt, now + chrono::Duration::days(30), |r| save(
                &conn, r
            ))
            .unwrap()
        );
    }

    #[test]
    fn workspace_purge_recovers_crash_between_rename_and_receipt_commit() {
        let (_temp, conn, mut receipt) = fixture();
        let now = Utc::now();
        // This is the exact crash window: intent committed, rename completed,
        // but the quarantine acknowledgement was not committed.
        receipt.phase = Phase::Quarantining;
        receipt.not_before = now + chrono::Duration::days(7);
        save(&conn, &receipt).unwrap();
        std::fs::rename(&receipt.source, &receipt.quarantine).unwrap();
        let mut recovered = load(&conn, receipt.mission_id).unwrap().unwrap();
        quarantine_receipt(&mut recovered, now + chrono::Duration::hours(1), |r| {
            save(&conn, r)
        })
        .unwrap();
        assert_eq!(recovered.phase, Phase::Quarantined);
        assert_eq!(recovered.not_before, receipt.not_before);
        restore_receipt(&mut recovered, |r| save(&conn, r)).unwrap();
        assert!(recovered.source.join("untracked").exists());
    }

    #[test]
    fn workspace_purge_recovery_repeats_failed_parent_fsync() {
        use super::super::workspace_purge_fs::fail_next_parent_sync;
        let (_temp, conn, mut receipt) = fixture();
        fail_next_parent_sync();
        assert!(quarantine_receipt(&mut receipt, Utc::now(), |r| save(&conn, r)).is_err());
        assert!(receipt.quarantine.exists());
        assert_eq!(
            load(&conn, receipt.mission_id).unwrap().unwrap().phase,
            Phase::Quarantining
        );
        fail_next_parent_sync();
        assert!(quarantine_receipt(&mut receipt, Utc::now(), |r| save(&conn, r)).is_err());
        quarantine_receipt(&mut receipt, Utc::now(), |r| save(&conn, r)).unwrap();
        fail_next_parent_sync();
        assert!(restore_receipt(&mut receipt, |r| save(&conn, r)).is_err());
        assert!(receipt.source.exists());
        fail_next_parent_sync();
        assert!(restore_receipt(&mut receipt, |r| save(&conn, r)).is_err());
        assert_eq!(
            load(&conn, receipt.mission_id).unwrap().unwrap().phase,
            Phase::Quarantined
        );
        restore_receipt(&mut receipt, |r| save(&conn, r)).unwrap();
        assert!(receipt.source.join("untracked").exists());
    }

    #[test]
    fn workspace_purge_failed_intent_commit_never_moves_source() {
        let (_temp, _conn, mut receipt) = fixture();
        assert!(quarantine_receipt(&mut receipt, Utc::now(), |_| Err("disk full".into())).is_err());
        assert!(receipt.source.join("untracked").exists());
        assert!(!receipt.quarantine.exists());
    }

    #[test]
    fn workspace_purge_refuses_replaced_inode_and_reappeared_source() {
        let (temp, conn, mut receipt) = fixture();
        let now = Utc::now();
        quarantine_receipt(&mut receipt, now, |r| save(&conn, r)).unwrap();
        std::fs::create_dir(&receipt.source).unwrap();
        assert!(
            removal_ready(&mut receipt, now + chrono::Duration::days(8), |r| save(
                &conn, r
            ))
            .is_err()
        );
        assert!(restore_receipt(&mut receipt, |r| save(&conn, r)).is_err());
        std::fs::remove_dir(&receipt.source).unwrap();
        std::fs::rename(&receipt.quarantine, temp.path().join("saved-original")).unwrap();
        std::fs::create_dir(&receipt.quarantine).unwrap();
        assert!(
            removal_ready(&mut receipt, now + chrono::Duration::days(8), |r| save(
                &conn, r
            ))
            .is_err()
        );
        assert!(temp.path().join("saved-original/untracked").exists());
    }

    #[test]
    fn workspace_purge_requires_abandonment_and_delay_before_irreversible_phase() {
        let (_temp, conn, mut receipt) = fixture();
        receipt.discard_work = false;
        assert!(quarantine_receipt(&mut receipt, Utc::now(), |r| save(&conn, r)).is_err());
        receipt.discard_work = true;
        let now = Utc::now();
        quarantine_receipt(&mut receipt, now, |r| save(&conn, r)).unwrap();
        assert!(
            removal_ready(&mut receipt, now + chrono::Duration::days(7), |r| save(
                &conn, r
            ))
            .unwrap()
        );
        assert_eq!(
            load(&conn, receipt.mission_id).unwrap().unwrap().phase,
            Phase::Removing
        );
        assert!(restore_receipt(&mut receipt, |r| save(&conn, r)).is_err());
        assert!(receipt.quarantine.join("untracked").exists());
    }
}
