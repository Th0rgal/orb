//! Local disk admission locks and the disk reservation ledger.

use super::*;

pub(super) static PR_WRITER_CREATE_LOCK: std::sync::LazyLock<Mutex<()>> =
    std::sync::LazyLock::new(|| Mutex::new(()));

// Admission is deliberately a durable, filesystem-scoped lease rather than an
// in-memory counter.  More than one control process can use the same mission
// store and a restart must not forget work that is already consuming scratch.
pub(super) static DISK_ADMISSION_LOCK: std::sync::LazyLock<Mutex<()>> =
    std::sync::LazyLock::new(|| Mutex::new(()));

pub(super) struct DurableDiskAdmissionLockGuard {
    pub(super) _process_guard: tokio::sync::MutexGuard<'static, ()>,
    pub(super) file: std::fs::File,
}

impl Drop for DurableDiskAdmissionLockGuard {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

pub(super) async fn acquire_durable_disk_admission_lock(
    config: &Config,
) -> Result<DurableDiskAdmissionLockGuard, String> {
    let process_guard = DISK_ADMISSION_LOCK.lock().await;
    let lock_dir = config.working_dir.join(".sandboxed-sh").join("missions");
    tokio::fs::create_dir_all(&lock_dir)
        .await
        .map_err(|error| format!("create disk admission lock directory: {error}"))?;
    let lock_path = lock_dir.join(".disk-admission.lock");
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
    .map_err(|error| format!("join disk admission lock task: {error}"))??;
    Ok(DurableDiskAdmissionLockGuard {
        _process_guard: process_guard,
        file,
    })
}

pub(super) const DISK_RESERVATION_TAG_PREFIX: &str = "disk-reservation-v1:";

/// Server-owned admission state.  This is intentionally separate from
/// `MissionProject`: project metadata is user editable and consequently can
/// never be an authority for resource accounting.  The file is written while
/// holding the global admission lock and atomically replaced, so independent
/// control processes observe a complete old or complete new ledger.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct DiskReservation {
    pub(super) mission_id: Uuid,
    pub(super) filesystem: String,
    pub(super) estimated_bytes: u64,
    /// Free bytes observed when the lease was granted.  This is a diagnostic
    /// baseline, not an additional reservation; counting both consumed disk
    /// and the full estimate would double-count the same work.
    pub(super) free_bytes_at_grant: u64,
    /// Canonical mission directory whose actual usage consumes this lease.
    /// Older records omit it and conservatively retain their full estimate.
    #[serde(default)]
    pub(super) workspace_dir: Option<PathBuf>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub(super) struct DiskReservationLedger {
    #[serde(default = "disk_reservation_ledger_version")]
    pub(super) version: u8,
    #[serde(default)]
    pub(super) reservations: HashMap<Uuid, DiskReservation>,
    /// Compatibility input for the immediately preceding ledger format.  The
    /// placement decision has moved to the mission row, but an upgrade must
    /// first transfer any remote (`false`) decisions rather than treating
    /// those missions as conservative local work.  Do not serialize this
    /// field again: once transferred, the row is the sole authority.
    ///
    /// The on-disk key was `requires_local_disk`.  The Rust field was renamed
    /// during the migration, so deserialize both names.
    #[serde(
        default,
        rename = "requires_local_disk",
        alias = "legacy_requires_local_disk",
        skip_serializing
    )]
    pub(super) legacy_requires_local_disk: HashMap<Uuid, bool>,
}

pub(super) const fn disk_reservation_ledger_version() -> u8 {
    2
}

pub(super) fn disk_reservation_ledger_path(config: &Config) -> PathBuf {
    config
        .working_dir
        .join(".sandboxed-sh")
        .join("missions")
        .join("disk-reservations-v2.json")
}

pub(super) fn read_disk_reservation_ledger(
    config: &Config,
) -> Result<DiskReservationLedger, String> {
    let path = disk_reservation_ledger_path(config);
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|error| format!("parse {}: {error}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(DiskReservationLedger {
            version: disk_reservation_ledger_version(),
            reservations: HashMap::new(),
            legacy_requires_local_disk: HashMap::new(),
        }),
        Err(error) => Err(format!("read {}: {error}", path.display())),
    }
}

pub(super) fn write_disk_reservation_ledger(
    config: &Config,
    ledger: &DiskReservationLedger,
) -> Result<(), String> {
    let path = disk_reservation_ledger_path(config);
    let parent = path.parent().expect("ledger path has parent");
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("create {}: {error}", parent.display()))?;
    let temp = parent.join(format!(".disk-reservations-v2.{}.tmp", Uuid::new_v4()));
    let outcome = (|| -> Result<(), String> {
        let bytes = serde_json::to_vec(ledger).map_err(|error| error.to_string())?;
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp)
            .map_err(|error| format!("open {}: {error}", temp.display()))?;
        file.write_all(&bytes)
            .map_err(|error| format!("write {}: {error}", temp.display()))?;
        file.sync_all()
            .map_err(|error| format!("sync {}: {error}", temp.display()))?;
        std::fs::rename(&temp, &path)
            .map_err(|error| format!("rename {}: {error}", path.display()))?;
        std::fs::File::open(parent)
            .and_then(|dir| dir.sync_all())
            .map_err(|error| format!("sync {}: {error}", parent.display()))?;
        Ok(())
    })();
    if outcome.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    outcome
}

/// Admission leases are server-owned durable state.  They used to share the
/// free-form project-tag namespace, which let a project edit forge, erase, or
/// transplant a lease.  Keep the compatibility reader below for records made
/// by older servers, but never accept this reserved namespace from an API
/// request.
pub(super) fn contains_internal_disk_reservation_tag(tags: &[String]) -> bool {
    let forged = tags
        .iter()
        .any(|tag| tag.trim().starts_with(DISK_RESERVATION_TAG_PREFIX));
    !crate::orb_spec::admission_step(crate::orb_spec::AdmissionStepInput {
        recovery_phase: 0,
        is_quiescent: true,
        reserved_tag_forged: forged,
        emergency_plus_cand_bytes: 0,
        free_disk_bytes: 0,
    })
    .admit
}

/// Only missions that are actually running hold a scratch lease.
/// Parked (`awaiting_user`, `paused`) and every terminal status release —
/// those were the 2026-08-17 zombie majority (~18 TiB paper vs ~2 TiB free).
pub(super) fn mission_holds_disk_reservation(status: MissionStatus) -> bool {
    matches!(
        status,
        MissionStatus::Active | MissionStatus::Pending | MissionStatus::WaitingBackground
    )
}

/// Hard admission budget: emergency floor + this candidate. Paper leases are
/// not part of the hard gate — the 2026-08-17 ledger still charged ~5–18 TiB
/// of `failed` / parked rows after deploy, so every create died while 2 TiB
/// was actually free.
pub(super) fn disk_admission_hard_required_bytes(emergency: u64, candidate: u64) -> u64 {
    emergency.saturating_add(candidate)
}

/// Soft budget including paper reservations; only tests still assert it.
#[cfg(test)]
pub(super) fn disk_admission_required_bytes(emergency: u64, reserved: u64, candidate: u64) -> u64 {
    disk_admission_hard_required_bytes(emergency, candidate).saturating_add(reserved)
}

pub(super) async fn reserved_disk_bytes_for_filesystem(
    config: &Config,
    filesystem: &str,
    live_ids: &HashSet<Uuid>,
) -> Result<u64, String> {
    let ledger = read_disk_reservation_ledger(config)?;
    Ok(ledger
        .reservations
        .values()
        .filter(|reservation| {
            reservation.filesystem == filesystem && live_ids.contains(&reservation.mission_id)
        })
        .map(disk_reservation_outstanding_bytes)
        .fold(0u64, |sum, bytes| sum.saturating_add(bytes)))
}

/// The filesystem's free counter already includes bytes written by a running
/// mission. Subtracting both those bytes and its full estimate would charge
/// the same consumption twice.  A lease therefore retains only its estimated
/// *remaining* peak after measuring its own workspace.  Measurement failure
/// is conservative: keep the complete estimate.
pub(super) fn allocated_file_bytes(metadata: &std::fs::Metadata) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // POSIX `st_blocks` is in 512-byte units and counts allocated
        // storage, so sparse/reflinked files do not appear fully consumed.
        metadata.blocks().saturating_mul(512)
    }
    #[cfg(not(unix))]
    {
        metadata.len()
    }
}

pub(super) fn disk_reservation_outstanding_bytes(reservation: &DiskReservation) -> u64 {
    let Some(path) = reservation.workspace_dir.as_deref() else {
        return reservation.estimated_bytes;
    };
    let usage = walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .fold(0u64, |total, metadata| {
            total.saturating_add(allocated_file_bytes(&metadata))
        });
    reservation.estimated_bytes.saturating_sub(usage)
}

pub(super) fn nonterminal_missions_in_sqlite(
    path: &std::path::Path,
) -> Result<HashMap<Uuid, (Option<Uuid>, bool)>, String> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|error| format!("open {} read-only: {error}", path.display()))?;
    let _ = connection.busy_timeout(std::time::Duration::from_secs(10));
    let mut statement = connection
        .prepare("SELECT id, status, workspace_id, COALESCE(requires_local_disk, 1) FROM missions")
        .or_else(|_| connection.prepare("SELECT id, status, workspace_id, 1 FROM missions"))
        .or_else(|_| connection.prepare("SELECT id, status, NULL AS workspace_id, 1 FROM missions"))
        .map_err(|error| format!("query {}: {error}", path.display()))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })
        .map_err(|error| error.to_string())?;
    let mut missions = HashMap::new();
    for row in rows {
        let (id, status, workspace_id, requires_local_disk) =
            row.map_err(|error| error.to_string())?;
        let status = serde_json::from_value::<MissionStatus>(serde_json::Value::String(status))
            .unwrap_or(MissionStatus::Failed);
        if mission_holds_disk_reservation(status) {
            let id = Uuid::parse_str(&id)
                .map_err(|error| format!("parse mission id {id} in {}: {error}", path.display()))?;
            let workspace_id = workspace_id
                .as_deref()
                .map(Uuid::parse_str)
                .transpose()
                .map_err(|error| format!("parse workspace id in {}: {error}", path.display()))?;
            missions.insert(id, (workspace_id, requires_local_disk != 0));
        }
    }
    Ok(missions)
}

/// Transfer placement from the short-lived v2 lease-ledger authority into an
/// offline SQLite mission store.  This runs under the global admission lock;
/// the transaction means a crash leaves either the old ledger classification
/// or the fully-updated mission rows, never a partially applied set.
pub(super) fn migrate_legacy_ledger_placement_in_sqlite(
    path: &std::path::Path,
    placement: &HashMap<Uuid, bool>,
) -> Result<(), String> {
    if placement.is_empty() {
        return Ok(());
    }
    let mut connection = rusqlite::Connection::open(path)
        .map_err(|error| format!("open {} for placement migration: {error}", path.display()))?;
    let _ = connection.busy_timeout(std::time::Duration::from_secs(10));
    let has_column = connection
        .prepare("SELECT 1 FROM pragma_table_info('missions') WHERE name = 'requires_local_disk'")
        .and_then(|mut statement| statement.exists([]))
        .map_err(|error| format!("inspect {} placement schema: {error}", path.display()))?;
    let transaction = connection
        .transaction()
        .map_err(|error| format!("start {} placement migration: {error}", path.display()))?;
    if !has_column {
        transaction
            .execute(
                "ALTER TABLE missions ADD COLUMN requires_local_disk INTEGER NOT NULL DEFAULT 1",
                [],
            )
            .map_err(|error| format!("add {} placement column: {error}", path.display()))?;
    }
    for (&mission_id, &requires_local_disk) in placement {
        transaction
            .execute(
                "UPDATE missions SET requires_local_disk = ?1 WHERE id = ?2",
                rusqlite::params![
                    if requires_local_disk { 1i64 } else { 0i64 },
                    mission_id.to_string()
                ],
            )
            .map_err(|error| {
                format!(
                    "migrate placement for {mission_id} in {}: {error}",
                    path.display()
                )
            })?;
    }
    transaction
        .commit()
        .map_err(|error| format!("commit {} placement migration: {error}", path.display()))
}

/// Reconstruct the live lease set from authoritative mission state while the
/// global admission lock is held.  The ledger supplies bytes; mission stores
/// supply lifecycle truth.  Project tags are deliberately excluded: they are
/// user-editable presentation metadata and can neither grant nor retain a
/// lease after a project edit.
pub(super) async fn reconcile_disk_reservation_ledger_under_lock(
    control_hub: &ControlHub,
    config: &Config,
) -> Result<HashSet<Uuid>, String> {
    let inventory = control_hub.mission_store_inventory().await?;
    let mut ledger = read_disk_reservation_ledger(config)?;
    let legacy_placement = std::mem::take(&mut ledger.legacy_requires_local_disk);
    // Mission rows are the lifecycle authority.  A process can crash after a
    // row commits but before the separate, atomically-published ledger file is
    // renamed.  Reconstructing a conservative lease for every such live row
    // closes that crash window; the lock is retained from admission through
    // row creation and ledger publication, so no concurrent admission can
    // observe the intermediate state either.
    let mut live_missions: HashMap<Uuid, (Option<Uuid>, bool)> = HashMap::new();
    for store in inventory.live {
        for mission in store.list_missions(usize::MAX, 0).await? {
            if let Some(&requires_local_disk) = legacy_placement.get(&mission.id) {
                if mission.requires_local_disk != requires_local_disk {
                    store
                        .set_mission_requires_local_disk(mission.id, requires_local_disk)
                        .await?;
                }
            }
            if mission_holds_disk_reservation(mission.status) {
                live_missions.insert(
                    mission.id,
                    (
                        Some(mission.workspace_id),
                        legacy_placement
                            .get(&mission.id)
                            .copied()
                            .unwrap_or(mission.requires_local_disk),
                    ),
                );
            }
        }
    }
    for user in inventory.offline_file_users {
        let store: Arc<dyn MissionStore> = Arc::new(
            mission_store::FileMissionStore::new(inventory.base_dir.clone(), &user).await?,
        );
        for mission in store.list_missions(usize::MAX, 0).await? {
            if let Some(&requires_local_disk) = legacy_placement.get(&mission.id) {
                if mission.requires_local_disk != requires_local_disk {
                    store
                        .set_mission_requires_local_disk(mission.id, requires_local_disk)
                        .await?;
                }
            }
            if mission_holds_disk_reservation(mission.status) {
                live_missions.insert(
                    mission.id,
                    (
                        Some(mission.workspace_id),
                        legacy_placement
                            .get(&mission.id)
                            .copied()
                            .unwrap_or(mission.requires_local_disk),
                    ),
                );
            }
        }
    }
    for path in inventory.offline_sqlite {
        let placement = legacy_placement.clone();
        let missions = tokio::task::spawn_blocking(move || {
            migrate_legacy_ledger_placement_in_sqlite(&path, &placement)?;
            nonterminal_missions_in_sqlite(&path)
        })
        .await
        .map_err(|error| error.to_string())??;
        for (id, placement) in missions {
            live_missions.entry(id).or_insert(placement);
        }
    }
    let mut changed = !legacy_placement.is_empty();
    let before = ledger.reservations.len();
    ledger
        .reservations
        .retain(|id, _| live_missions.contains_key(id));
    changed |= ledger.reservations.len() != before;
    for (&mission_id, &(workspace_id, requires_local_disk)) in &live_missions {
        // Remote-node missions have an authoritative persisted placement
        // record but no host-disk lease.  Never manufacture one on restart.
        // An absent record predates placement persistence and is charged
        // locally as the safe compatibility policy.
        if !requires_local_disk {
            continue;
        }
        if ledger.reservations.contains_key(&mission_id) {
            continue;
        }
        // A very old SQLite schema may not carry workspace_id. Charge the
        // default host conservatively rather than allowing a crash-created
        // Pending mission to escape admission accounting.
        let workspace_id = workspace_id.unwrap_or(workspace::DEFAULT_WORKSPACE_ID);
        let workspace = control_hub
            .workspaces
            .get(workspace_id)
            .await
            .unwrap_or_else(|| workspace::Workspace::default_host(config.working_dir.clone()));
        workspace::ensure_persisted_mission_root_is_available(&workspace, mission_id)
            .map_err(|error| format!("verify persisted placement for {mission_id}: {error}"))?;
        let root = workspace::mission_workspace_root_for_workspace(&workspace, mission_id);
        let usage = crate::api::monitoring::disk_usage_for_path(&root).map_err(|error| {
            format!(
                "measure reconstructed mission filesystem {}: {error}",
                root.display()
            )
        })?;
        ledger.reservations.insert(
            mission_id,
            DiskReservation {
                mission_id,
                filesystem: usage.filesystem,
                estimated_bytes: mission_disk_default_estimate_gib().saturating_mul(1 << 30),
                free_bytes_at_grant: usage.available,
                workspace_dir: Some(workspace::mission_workspace_dir_for_workspace(
                    &workspace, mission_id,
                )),
            },
        );
        changed = true;
    }
    if changed {
        write_disk_reservation_ledger(config, &ledger)?;
    }
    Ok(live_missions.keys().copied().collect())
}

/// Periodic / on-demand purge of dead leases. The workspace GC loop calls
/// this even when directory GC is dry-run so an operator never has to edit
/// `disk-reservations-v2.json` by hand.
pub(crate) async fn sweep_stale_disk_reservations(
    control_hub: &ControlHub,
    config: &Config,
) -> Result<(), String> {
    let _guard = acquire_durable_disk_admission_lock(config).await?;
    reconcile_disk_reservation_ledger_under_lock(control_hub, config).await?;
    Ok(())
}

/// The caller must retain the returned lock through mission persistence and
/// its reservation-tag write.  That makes admission, creation and durable
/// reconstruction one atomic protocol across local control processes.
pub(super) async fn reserve_local_mission_disk(
    control_hub: &ControlHub,
    config: &Config,
    workspace: &workspace::Workspace,
    estimate_gib: u64,
) -> Result<(DurableDiskAdmissionLockGuard, DiskReservation), String> {
    let guard = acquire_durable_disk_admission_lock(config).await?;
    let live_ids = match reconcile_disk_reservation_ledger_under_lock(control_hub, config).await {
        Ok(ids) => ids,
        Err(error) => {
            // Paper accounting must never block a host that still has real
            // free space. A reconcile failure used to leave the stale
            // ledger as a hard refusal (~18 TiB reserved vs ~2 TiB free).
            tracing::warn!(
                %error,
                "disk reservation reconcile failed; admitting on measured free space only"
            );
            HashSet::new()
        }
    };
    let root = workspace::mission_workspace_root_for_workspace(workspace, Uuid::nil());
    if let Some(reason) = disk_admission_refusal(&root) {
        return Err(reason);
    }
    let usage = crate::api::monitoring::disk_usage_for_path(&root).map_err(|error| {
        format!(
            "mission creation refused: cannot measure workspace filesystem at {}: {error}",
            root.display()
        )
    })?;
    let reserved = reserved_disk_bytes_for_filesystem(config, &usage.filesystem, &live_ids)
        .await
        .unwrap_or(0);
    let estimate = estimate_gib.saturating_mul(1 << 30);
    let emergency = mission_disk_reserve_gib().saturating_mul(1 << 30);
    let hard_required = disk_admission_hard_required_bytes(emergency, estimate);
    if !crate::orb_spec::admission_step(crate::orb_spec::AdmissionStepInput {
        recovery_phase: 0,
        is_quiescent: true,
        reserved_tag_forged: false,
        emergency_plus_cand_bytes: hard_required,
        free_disk_bytes: usage.available,
    })
    .admit
    {
        return Err(format!(
            "mission admission refused on filesystem {}: {} GiB free, {} GiB candidate estimate, {} GiB emergency reserve ({} GiB required)",
            usage.filesystem,
            usage.available / (1 << 30),
            estimate_gib,
            mission_disk_reserve_gib(),
            hard_required / (1 << 30),
        ));
    }
    if reserved > 0 && usage.available < hard_required.saturating_add(reserved) {
        tracing::warn!(
            filesystem = %usage.filesystem,
            free_bytes = usage.available,
            reserved_bytes = reserved,
            candidate_bytes = estimate,
            "paper scratch reservations exceed free space; admitting because measured disk is sufficient"
        );
    }
    tracing::info!(
        filesystem = %usage.filesystem,
        free_bytes = usage.available,
        reserved_bytes = reserved,
        candidate_bytes = estimate,
        required_bytes = hard_required,
        "local mission disk admission reserved"
    );
    Ok((
        guard,
        DiskReservation {
            mission_id: Uuid::nil(),
            filesystem: usage.filesystem,
            estimated_bytes: estimate,
            free_bytes_at_grant: usage.available,
            workspace_dir: None,
        },
    ))
}

/// Release a server-owned lease when a mission reaches a terminal state.  The
/// lock is the same one used for admission, making a terminal transition and
/// a concurrent create serialize across control processes.  A failed ledger
/// write is deliberately surfaced to the caller rather than silently making
/// capacity appear free.
pub(super) async fn release_local_mission_disk(
    config: &Config,
    mission_id: Uuid,
) -> Result<(), String> {
    let _guard = acquire_durable_disk_admission_lock(config).await?;
    let mut ledger = read_disk_reservation_ledger(config)?;
    if ledger.reservations.remove(&mission_id).is_some() {
        write_disk_reservation_ledger(config, &ledger)?;
    }
    Ok(())
}

pub(super) async fn release_local_mission_disk_if_not_holding(
    mission_store: &Arc<dyn crate::api::mission_store::MissionStore>,
    config: &Config,
    mission_id: Uuid,
) {
    match mission_store.get_mission(mission_id).await {
        Ok(Some(mission)) if mission_holds_disk_reservation(mission.status) => {}
        Ok(_) => {
            if let Err(error) = release_local_mission_disk(config, mission_id).await {
                tracing::error!(
                    mission = %mission_id,
                    %error,
                    "terminal mission lease cleanup failed after runner stop"
                );
            }
        }
        Err(error) => {
            tracing::warn!(
                mission = %mission_id,
                %error,
                "could not load mission to decide disk lease release"
            );
        }
    }
}
