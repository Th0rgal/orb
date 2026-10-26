//! Control hub: per-user control state, frontend tool hub and session lookup.

use super::*;

// Mission and MissionHistoryEntry are now defined in mission_store module

/// Metadata for a desktop session started during a mission.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DesktopSessionInfo {
    pub display: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_server: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compositor: Option<String>,
    pub started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stopped_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshots_dir: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub browser: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The mission that owns this desktop session.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mission_id: Option<uuid::Uuid>,
    /// Timestamp until which the session should be kept alive (ISO 8601).
    /// User can extend this to prevent auto-close.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keep_alive_until: Option<String>,
}

// MissionStore trait and implementations are in mission_store module

/// Shared tool hub used to await frontend tool results.
///
/// Supports both orderings:
/// - register-then-resolve (normal flow)
/// - resolve-then-register (frontend submits answer before backend registers)
#[derive(Debug)]
pub struct FrontendToolHub {
    pub(super) pending: Mutex<HashMap<String, oneshot::Sender<serde_json::Value>>>,
    pub(super) early_results: Mutex<HashMap<String, serde_json::Value>>,
    /// Missions currently blocked awaiting a human-provided frontend tool
    /// result (e.g. `AskUserQuestion`). Ref-counted so a mission with more
    /// than one concurrent frontend tool call is only cleared once its last
    /// wait ends. The stuck-mission watchdog consults this so a mission that
    /// is legitimately waiting for the user is never auto-interrupted for
    /// "inactivity" — humans routinely take longer than the stall threshold
    /// to answer. A `std::sync::Mutex` (not tokio) so `WaitingGuard::drop`
    /// can release the slot synchronously on the cancellation path.
    pub(super) waiting_missions: std::sync::Mutex<HashMap<Uuid, usize>>,
}

impl FrontendToolHub {
    pub fn new() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            early_results: Mutex::new(HashMap::new()),
            waiting_missions: std::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Register a tool call that expects a frontend-provided result.
    /// If the result was already submitted (resolve-before-register), it is
    /// delivered immediately.
    pub async fn register(&self, tool_call_id: String) -> oneshot::Receiver<serde_json::Value> {
        let (tx, rx) = oneshot::channel();

        {
            let mut early = self.early_results.lock().await;
            if let Some(result) = early.remove(&tool_call_id) {
                let _ = tx.send(result);
                return rx;
            }
        }

        let mut pending = self.pending.lock().await;
        pending.insert(tool_call_id, tx);
        rx
    }

    pub async fn unregister(&self, tool_call_id: &str) {
        self.pending.lock().await.remove(tool_call_id);
    }

    /// Resolve a pending tool call by id.
    ///
    /// Returns `true` if a live waiter received the result (the running mission
    /// is consuming it). Returns `false` only when no waiter ever appears and
    /// the result had to be cached in `early_results` — which, for a
    /// human-answered question, means the mission is no longer running and the
    /// answer was dropped on the floor.
    ///
    /// The harnesses broadcast the `ToolCall` to the frontend *before*
    /// [`register`](Self::register) runs (there are a couple of `.await`
    /// points in between), so a fast `tool_result` can race ahead of the
    /// matching `register`. To avoid misreporting such a delivery as dropped,
    /// we briefly wait for the imminent registration before falling back to the
    /// cache. The wait is only ever paid when no waiter is present yet — the
    /// common case (waiter already parked) returns immediately, and a mission
    /// that has truly ended simply waits out the short grace window before we
    /// correctly report the answer as undelivered.
    pub async fn resolve(&self, tool_call_id: &str, result: serde_json::Value) -> bool {
        // Total grace window ~250ms (10 × 25ms), only incurred when the waiter
        // has not registered yet. Bounded so a genuinely dead mission still
        // reports `delivered: false` promptly.
        const REGISTER_GRACE_ATTEMPTS: u32 = 10;
        const REGISTER_GRACE_STEP: std::time::Duration = std::time::Duration::from_millis(25);

        for attempt in 0..=REGISTER_GRACE_ATTEMPTS {
            {
                let mut pending = self.pending.lock().await;
                if let Some(tx) = pending.remove(tool_call_id) {
                    return tx.send(result).is_ok();
                }
            }
            if attempt < REGISTER_GRACE_ATTEMPTS {
                tokio::time::sleep(REGISTER_GRACE_STEP).await;
            }
        }

        // Native requests are registered before publication. Never replay an
        // expired answer into a future waiter.
        if tool_call_id.starts_with("native-") {
            return false;
        }
        let mut early = self.early_results.lock().await;
        const MAX_EARLY_RESULTS: usize = 256;
        if early.len() >= MAX_EARLY_RESULTS {
            tracing::warn!(
                "FrontendToolHub: early_results cache full ({} entries), dropping an entry",
                early.len()
            );
            if let Some(key) = early.keys().next().cloned() {
                early.remove(&key);
            }
        }
        early.insert(tool_call_id.to_string(), result);
        false
    }

    /// Mark `mission_id` as blocked on user input. The returned guard clears
    /// the mark when dropped, which covers both the answered path (the parked
    /// task proceeds and drops the guard) and the cancelled path (the task
    /// returns early and the guard drops during unwind).
    pub fn begin_waiting(hub: &Arc<Self>, mission_id: Uuid) -> WaitingGuard {
        {
            let mut waiting = hub.waiting_missions.lock().unwrap();
            *waiting.entry(mission_id).or_insert(0) += 1;
        }
        WaitingGuard {
            hub: Arc::clone(hub),
            mission_id,
        }
    }

    /// True while a mission is parked awaiting a human-provided tool result.
    pub fn is_waiting_for_input(&self, mission_id: Uuid) -> bool {
        self.waiting_missions
            .lock()
            .unwrap()
            .get(&mission_id)
            .is_some_and(|count| *count > 0)
    }
}

impl Default for FrontendToolHub {
    fn default() -> Self {
        Self::new()
    }
}

/// RAII guard that keeps a mission marked as "waiting for user input" in the
/// [`FrontendToolHub`] for as long as it is held. Created via
/// [`FrontendToolHub::begin_waiting`].
pub struct WaitingGuard {
    pub(super) hub: Arc<FrontendToolHub>,
    pub(super) mission_id: Uuid,
}

impl Drop for WaitingGuard {
    fn drop(&mut self) {
        let mut waiting = self.hub.waiting_missions.lock().unwrap();
        if let Some(count) = waiting.get_mut(&self.mission_id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                waiting.remove(&self.mission_id);
            }
        }
    }
}

/// Control session runtime stored in `AppState`.
#[derive(Clone)]
pub struct ControlState {
    pub cmd_tx: mpsc::Sender<ControlCommand>,
    pub events_tx: broadcast::Sender<AgentEvent>,
    /// P3-#20: per-mission broadcast channels. A fan-out task subscribed
    /// to `events_tx` mirrors each `AgentEvent` with a non-empty
    /// `mission_id()` into the matching per-mission channel here.
    /// SSE/WS clients with a mission filter subscribe directly to the
    /// per-mission channel and avoid receiving — and filtering out —
    /// events for missions they don't care about. The HashMap entry is
    /// created lazily on first subscribe and never garbage-collected
    /// because a long-running mission may have intermittent subscribers
    /// over its lifetime; the cost per entry is one Sender<Arc<…>>.
    pub mission_channels:
        Arc<RwLock<std::collections::HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    pub tool_hub: Arc<FrontendToolHub>,
    pub status: Arc<RwLock<ControlStatus>>,
    /// Current mission ID (if any) - primary mission in the old sequential model
    pub current_mission: Arc<RwLock<Option<Uuid>>>,
    /// Current agent tree snapshot (for refresh resilience)
    pub current_tree: Arc<RwLock<Option<AgentTreeNode>>>,
    /// Current execution progress (for progress indicator)
    pub progress: Arc<RwLock<ExecutionProgress>>,
    /// Running missions (for parallel execution)
    pub running_missions: Arc<RwLock<Vec<super::super::mission_runner::RunningMissionInfo>>>,
    /// Published by the owning actor before it processes its next command.
    /// Admission/sweep read this without recursively querying that actor.
    pub(crate) assignment_owners: Arc<RwLock<HashSet<Uuid>>>,
    /// Max parallel missions allowed
    pub max_parallel: usize,
    /// Slot usage from the last scheduler pass. Read paths use it to say a
    /// pending mission is waiting for a slot rather than stuck.
    pub(crate) dispatch_capacity: Arc<RwLock<Option<super::dispatch_capacity::DispatchCapacity>>>,
    /// Mission persistence (SQLite-backed)
    pub mission_store: Arc<dyn MissionStore>,
    /// Cache for semantic mission search results keyed by normalized query hash
    pub mission_search_cache: Arc<RwLock<HashMap<u64, MissionSearchCacheEntry>>>,
}

/// Control session manager for per-user sessions.
#[derive(Clone)]
pub struct ControlHub {
    pub(super) admission_state: Arc<std::sync::OnceLock<std::sync::Weak<AppState>>>,
    pub(super) admission_ready: Arc<tokio::sync::Notify>,
    pub(super) sessions: Arc<RwLock<HashMap<String, ControlState>>>,
    pub(super) identities: Arc<RwLock<HashMap<String, AuthUser>>>,
    pub(super) config: Config,
    pub(super) root_agent: AgentRef,
    pub(super) mcp: Arc<McpRegistry>,
    pub(super) workspaces: workspace::SharedWorkspaceStore,
    pub(super) library: SharedLibrary,
    pub(super) secrets: Option<Arc<SecretsStore>>,
    pub(super) telegram_bridge: Option<super::super::telegram::SharedTelegramBridge>,
}

pub(super) struct MissionStoreInventory {
    pub(super) live: Vec<Arc<dyn MissionStore>>,
    pub(super) offline_sqlite: Vec<PathBuf>,
    pub(super) offline_file_users: Vec<String>,
    pub(super) base_dir: PathBuf,
}

impl ControlHub {
    pub fn new(
        config: Config,
        root_agent: AgentRef,
        mcp: Arc<McpRegistry>,
        workspaces: workspace::SharedWorkspaceStore,
        library: SharedLibrary,
        secrets: Option<Arc<SecretsStore>>,
    ) -> Self {
        Self {
            admission_state: Arc::new(std::sync::OnceLock::new()),
            admission_ready: Arc::new(tokio::sync::Notify::new()),
            sessions: Arc::new(RwLock::new(HashMap::new())),
            identities: Arc::new(RwLock::new(HashMap::new())),
            config,
            root_agent,
            mcp,
            workspaces,
            library,
            secrets,
            telegram_bridge: None,
        }
    }

    pub(crate) fn bind_admission_state(&self, state: &Arc<AppState>) {
        if self.admission_state.set(Arc::downgrade(state)).is_ok() {
            remote_queue::start(Arc::downgrade(state));
        }
        self.admission_ready.notify_waiters();
    }

    pub(crate) async fn wait_for_admission_state(&self) -> Option<Arc<AppState>> {
        loop {
            let ready = self.admission_ready.notified();
            if let Some(state) = self.admission_state.get() {
                return state.upgrade();
            }
            ready.await;
        }
    }

    /// Set the Telegram bridge reference (called after AppState is created).
    pub fn set_telegram_bridge(&mut self, bridge: super::super::telegram::SharedTelegramBridge) {
        self.telegram_bridge = Some(bridge);
    }

    /// Get the events broadcast sender from any active session.
    /// Used by the FIDO signing hub to broadcast signing requests to all
    /// connected SSE clients regardless of which user session they belong to.
    pub fn get_any_session_events_tx(&self) -> Option<broadcast::Sender<AgentEvent>> {
        // Try to read without blocking — best-effort for the FIDO relay.
        let sessions = self.sessions.try_read().ok()?;
        sessions.values().next().map(|s| s.events_tx.clone())
    }

    pub(crate) async fn identity_for_store(
        &self,
        store: &Arc<dyn MissionStore>,
    ) -> Option<AuthUser> {
        let owner = self
            .sessions
            .read()
            .await
            .iter()
            .find(|(_, state)| Arc::ptr_eq(&state.mission_store, store))
            .map(|(owner, _)| owner.clone())?;
        self.identities.read().await.get(&owner).cloned()
    }

    /// The mission store of an already-loaded session for `user_id`, without
    /// spawning one. `None` when that tenant's session is not loaded.
    pub async fn loaded_mission_store(&self, user_id: &str) -> Option<Arc<dyn MissionStore>> {
        self.sessions
            .read()
            .await
            .get(user_id)
            .map(|s| Arc::clone(&s.mission_store))
    }

    pub async fn get_or_spawn(&self, user: &AuthUser) -> ControlState {
        self.identities
            .write()
            .await
            .insert(user.id.clone(), user.clone());
        if let Some(existing) = self.sessions.read().await.get(&user.id).cloned() {
            return existing;
        }
        let mut sessions = self.sessions.write().await;
        if let Some(existing) = sessions.get(&user.id).cloned() {
            return existing;
        }

        // Get mission store type from environment (default: SQLite)
        let store_type = std::env::var("MISSION_STORE_TYPE")
            .map(|s| MissionStoreType::from_str(&s))
            .unwrap_or(MissionStoreType::Sqlite);

        let base_dir = self
            .config
            .working_dir
            .join(".sandboxed-sh")
            .join("missions");
        let mission_store: Arc<dyn MissionStore> =
            match create_mission_store(store_type, base_dir, &user.id).await {
                Ok(store) => Arc::from(store),
                Err(err) => {
                    tracing::warn!(
                        "Failed to initialize {:?} mission store, falling back to memory: {}",
                        store_type,
                        err
                    );
                    Arc::new(mission_store::InMemoryMissionStore::new())
                }
            };

        let state = spawn_control_session(
            self.clone(),
            self.config.clone(),
            Arc::clone(&self.root_agent),
            Arc::clone(&self.mcp),
            Arc::clone(&self.workspaces),
            Arc::clone(&self.library),
            mission_store,
            self.secrets.clone(),
            self.telegram_bridge.clone(),
            user.id.clone(),
        );
        super::super::cloud_agents::worker::start(
            state.mission_store.clone(),
            self.config.clone(),
            user.id.clone(),
        );
        sessions.insert(user.id.clone(), state.clone());

        // Drop the write lock before performing async I/O so concurrent
        // callers of get_or_spawn / all_sessions are not blocked.
        drop(sessions);

        // Boot Telegram channels for this user's missions — ensures channels
        // are registered before we start serving requests.
        if let Some(ref bridge) = self.telegram_bridge {
            let public_url = std::env::var("SANDBOXED_PUBLIC_URL")
                .unwrap_or_else(|_| format!("http://{}:{}", self.config.host, self.config.port));
            bridge
                .boot_from_store(
                    &state.mission_store,
                    state.cmd_tx.clone(),
                    state.events_tx.clone(),
                    &public_url,
                )
                .await;
        }

        state
    }

    pub async fn all_sessions(&self) -> Vec<ControlState> {
        self.sessions.read().await.values().cloned().collect()
    }

    /// Sessions with the user that owns each one.
    pub(crate) async fn all_sessions_with_users(&self) -> Vec<(String, ControlState)> {
        self.sessions
            .read()
            .await
            .iter()
            .map(|(user, session)| (user.clone(), session.clone()))
            .collect()
    }

    /// Resolve a mission capability against the store that owns it.  Never use
    /// `get_mission_store` for this: that convenience method intentionally
    /// chooses an arbitrary desktop/default session and is not an authority
    /// lookup in a multi-user deployment.
    pub(crate) async fn find_mission_store_owner(
        &self,
        mission_id: Uuid,
    ) -> Result<Option<(Arc<dyn MissionStore>, Mission)>, String> {
        // A Spark token can only have been minted by a running session, so a
        // live owner is required.  Do not open offline SQLite files here: a
        // capability check must not create a competing writer just to find a
        // row that cannot currently execute.
        let stores: Vec<_> = self
            .sessions
            .read()
            .await
            .values()
            .map(|state| Arc::clone(&state.mission_store))
            .collect();
        for store in stores {
            if let Some(mission) = store.get_mission(mission_id).await? {
                return Ok(Some((store, mission)));
            }
        }
        Ok(None)
    }

    /// Collect every mission that carries a `project` tag across all mission
    /// stores (live, offline file, offline sqlite). Read-only; used by the
    /// projects-overview board. Terminal missions older than `terminal_horizon`
    /// are skipped so the scan stays bounded on long-lived stores.
    pub(crate) async fn collect_project_missions(
        &self,
        terminal_horizon: chrono::Duration,
    ) -> Result<Vec<Mission>, String> {
        const PAGE_SIZE: usize = 200;
        let cutoff = chrono::Utc::now() - terminal_horizon;
        let keep = |mission: &Mission| -> bool {
            if mission.project.project.is_none() {
                return false;
            }
            if mission.status.is_terminal() || mission.status == MissionStatus::Acknowledged {
                return chrono::DateTime::parse_from_rfc3339(&mission.updated_at)
                    .map(|t| t.with_timezone(&chrono::Utc) >= cutoff)
                    .unwrap_or(false);
            }
            true
        };
        let mut collected: Vec<Mission> = Vec::new();
        let mut seen: std::collections::HashSet<Uuid> = std::collections::HashSet::new();
        let inventory = self.mission_store_inventory().await?;
        let mut stores: Vec<Arc<dyn MissionStore>> = inventory.live;
        for user in inventory.offline_file_users {
            stores.push(Arc::new(
                mission_store::FileMissionStore::new(inventory.base_dir.clone(), &user).await?,
            ));
        }
        for store in stores {
            let mut offset = 0;
            loop {
                let page = store.list_missions(PAGE_SIZE, offset).await?;
                let page_len = page.len();
                for mission in page {
                    if keep(&mission) && seen.insert(mission.id) {
                        collected.push(mission);
                    }
                }
                if page_len < PAGE_SIZE {
                    break;
                }
                offset += page_len;
            }
        }
        for path in inventory.offline_sqlite {
            let cutoff_str = cutoff.to_rfc3339();
            let rows = tokio::task::spawn_blocking(move || {
                collect_project_missions_from_sqlite(&path, &cutoff_str)
            })
            .await
            .map_err(|error| error.to_string())??;
            for mission in rows {
                if seen.insert(mission.id) {
                    collected.push(mission);
                }
            }
        }
        Ok(collected)
    }

    /// Live AskUserQuestion waits: mission id → user-wait tool `started_at`.
    /// Presence means `WaitingUser`; the value is the grace clock (None if the
    /// tool row is not registered yet — treated as just started).
    ///
    /// Returns `(waits, complete)`. When `complete` is false at least one store
    /// or page failed — the map is a best-effort subset, not negative evidence.
    pub(crate) async fn collect_waiting_user_waits(&self) -> (HashMap<Uuid, Option<String>>, bool) {
        let mut waits = HashMap::new();
        let Ok(inventory) = self.mission_store_inventory().await else {
            return (waits, false);
        };
        let mut complete = true;
        for store in inventory.live {
            let Ok(runs) = store.list_active_mission_runs().await else {
                complete = false;
                continue;
            };
            let (store_waits, store_complete) =
                user_wait_starts_for_runs_checked(store.as_ref(), &runs).await;
            complete &= store_complete;
            waits.extend(store_waits);
        }
        (waits, complete)
    }

    /// Attention-horizon missions for one project: live / waiting / blocked
    /// and unabsorbed failed/interrupted attempts. Used by the item-first
    /// project read so controllers do not walk historical missions.
    ///
    /// `project` may be a roster nickname; every `routes.json` alias that
    /// folds onto the same canonical is queried. Offline sqlite is read
    /// read-only — opening a second writer on `missions-prod.db` is how a
    /// `get_project` would lock or fail closed to an empty item list.
    pub(crate) async fn collect_attention_missions_for_project(
        &self,
        project: &str,
    ) -> Result<Vec<Mission>, String> {
        let keys = super::super::projects_overview::project_tag_keys(project);
        if keys.is_empty() {
            return Ok(Vec::new());
        }
        Self::collect_attention_inventory(self.mission_store_inventory().await?, &keys).await
    }

    /// A roster is usable as negative evidence only when every store and page
    /// was read successfully. Never turn a skipped store into an empty result.
    pub(super) async fn collect_attention_inventory(
        inventory: MissionStoreInventory,
        keys: &[String],
    ) -> Result<Vec<Mission>, String> {
        const PAGE_SIZE: usize = 200;
        let mut collected = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut stores = inventory.live;
        for user in inventory.offline_file_users {
            stores.push(Arc::new(
                mission_store::FileMissionStore::new(inventory.base_dir.clone(), &user).await?,
            ));
        }
        let filters: Vec<_> = keys
            .iter()
            .map(|key| mission_store::MissionFilter {
                project: Some(key.clone()),
                attention_only: true,
                ..Default::default()
            })
            .collect();
        for store in stores {
            let mut offset = 0;
            loop {
                // The trait's filtered-list fallback stops after 5000 raw
                // rows. Scan raw pages once so old waits cannot disappear.
                let page = store.list_missions(PAGE_SIZE, offset).await?;
                let page_len = page.len();
                for mission in page {
                    if filters.iter().any(|filter| filter.matches(&mission))
                        && seen.insert(mission.id)
                    {
                        collected.push(mission);
                    }
                }
                if page_len < PAGE_SIZE {
                    break;
                }
                offset += page_len;
            }
        }
        for path in inventory.offline_sqlite {
            for key in keys {
                let path = path.clone();
                let key = key.clone();
                let rows = tokio::task::spawn_blocking(move || {
                    collect_attention_missions_from_sqlite(&path, &key)
                })
                .await
                .map_err(|error| error.to_string())??;
                for mission in rows {
                    if seen.insert(mission.id) {
                        collected.push(mission);
                    }
                }
            }
        }
        Ok(collected)
    }

    /// Delete every mission tagged with any of these project keys across live
    /// and offline stores. Callers must pass every alias the board folds onto
    /// the project (`project_tag_keys`), not only the canonical slug. This is
    /// intentionally fail-closed: a project-wide data delete cannot race a
    /// running, queued, paused, or otherwise resumable mission. The operator
    /// must finish or cancel those missions first. All tags are scanned before
    /// any delete so a live mission on an alias cannot be discovered after a
    /// partial wipe.
    pub(crate) async fn delete_project_missions(
        &self,
        projects: &[String],
    ) -> Result<Vec<Uuid>, String> {
        const PAGE_SIZE: usize = 200;
        let inventory = self.mission_store_inventory().await?;
        let mut stores: Vec<Arc<dyn MissionStore>> = inventory.live;
        for user in inventory.offline_file_users {
            stores.push(Arc::new(
                mission_store::FileMissionStore::new(inventory.base_dir.clone(), &user).await?,
            ));
        }
        for path in inventory.offline_sqlite {
            let Some(user) = path
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_prefix("missions-"))
                .and_then(|name| name.strip_suffix(".db"))
            else {
                return Err(format!("invalid mission store path {}", path.display()));
            };
            stores.push(Arc::new(
                mission_store::SqliteMissionStore::new(inventory.base_dir.clone(), user).await?,
            ));
        }

        let tags: Vec<String> = {
            let mut seen = std::collections::HashSet::new();
            projects
                .iter()
                .map(|tag| tag.trim())
                .filter(|tag| !tag.is_empty() && seen.insert((*tag).to_string()))
                .map(str::to_string)
                .collect()
        };
        let mut plans: Vec<(Arc<dyn MissionStore>, Vec<Mission>)> = Vec::new();
        for store in stores {
            let mut matched = Vec::new();
            let mut seen_ids = std::collections::HashSet::new();
            for tag in &tags {
                let filter = mission_store::MissionFilter {
                    project: Some(tag.clone()),
                    ..Default::default()
                };
                let mut offset = 0;
                loop {
                    let page = store
                        .list_missions_filtered(&filter, PAGE_SIZE, offset)
                        .await?;
                    let page_len = page.len();
                    for mission in page {
                        if seen_ids.insert(mission.id) {
                            matched.push(mission);
                        }
                    }
                    if page_len < PAGE_SIZE {
                        break;
                    }
                    offset += page_len;
                }
            }
            for mission in &matched {
                if !mission.status.is_terminal() && mission.status != MissionStatus::Acknowledged {
                    return Err(format!(
                        "Cannot delete project data while mission {} is {}. Finish or cancel it first.",
                        mission.id, mission.status
                    ));
                }
                if store.get_active_mission_run(mission.id).await?.is_some() {
                    return Err(format!(
                        "Cannot delete project data while mission {} still has an active run.",
                        mission.id
                    ));
                }
                let children = collect_child_mission_ids(&store, mission.id)
                    .await
                    .map_err(|(_, error)| error)?;
                for child_id in children {
                    if !seen_ids.contains(&child_id) {
                        return Err(format!(
                            "Cannot delete project data while mission {} has descendant {} tagged outside this project. Re-tag or delete that child first.",
                            mission.id, child_id
                        ));
                    }
                }
            }
            plans.push((store, matched));
        }

        let mut deleted_ids = std::collections::HashSet::new();
        for (store, missions) in plans {
            let selected: std::collections::HashSet<Uuid> =
                missions.iter().map(|mission| mission.id).collect();
            let roots: Vec<Uuid> = missions
                .iter()
                .filter(|mission| {
                    mission
                        .parent_mission_id
                        .is_none_or(|parent| !selected.contains(&parent))
                })
                .map(|mission| mission.id)
                .collect();
            for mission_id in roots {
                if store.get_mission(mission_id).await?.is_none() {
                    continue;
                }
                cleanup_mission_workspace_dirs_for_delete(
                    &store,
                    &self.workspaces,
                    mission_id,
                    &[],
                )
                .await
                .map_err(|(_, error)| error)?;
                let removed = delete_mission_with_children(&store, mission_id, &[])
                    .await
                    .map_err(|(_, error)| error)?;
                for id in removed {
                    clear_mission_metadata_refresh_state(id);
                    deleted_ids.insert(id);
                }
            }
        }

        let mut deleted: Vec<Uuid> = deleted_ids.into_iter().collect();
        deleted.sort_unstable();
        Ok(deleted)
    }

    pub(super) async fn mission_store_inventory(&self) -> Result<MissionStoreInventory, String> {
        let sessions = self.sessions.read().await;
        let live: Vec<Arc<dyn MissionStore>> = sessions
            .values()
            .map(|session| Arc::clone(&session.mission_store))
            .collect();
        drop(sessions);

        let base_dir = self
            .config
            .working_dir
            .join(".sandboxed-sh")
            .join("missions");
        let mut entries = match tokio::fs::read_dir(&base_dir).await {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(MissionStoreInventory {
                    live,
                    offline_sqlite: Vec::new(),
                    offline_file_users: Vec::new(),
                    base_dir,
                })
            }
            Err(error) => return Err(format!("read {}: {error}", base_dir.display())),
        };
        let mut offline_sqlite = Vec::new();
        let mut offline_file_users = Vec::new();
        while let Some(entry) = entries
            .next_entry()
            .await
            .map_err(|error| error.to_string())?
        {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(stem) = name.strip_prefix("missions-") else {
                continue;
            };
            if let Some(_user) = stem.strip_suffix(".db") {
                // The live session may be file-backed or an in-memory
                // fallback, so it cannot prove that this persisted SQLite
                // store is represented by `live`. A duplicate read-only scan
                // is safer than admitting a second writer during migration.
                offline_sqlite.push(entry.path());
            } else if let Some(user) = stem.strip_suffix(".json") {
                // A live user can be backed by SQLite while a second process
                // or an interrupted migration still owns missions in the
                // legacy file store. Scanning it twice when the live store is
                // itself file-backed is harmless; skipping it can miss a
                // writer lease.
                offline_file_users.push(user.to_string());
            }
        }
        Ok(MissionStoreInventory {
            live,
            offline_sqlite,
            offline_file_users,
            base_dir,
        })
    }

    /// User ids of all live control sessions. Used by GC/reaper to decide
    /// whether the cross-store mission index is complete (a persisted store
    /// with no live session means missions exist that the index can't see).
    pub async fn session_user_ids(&self) -> Vec<String> {
        self.sessions.read().await.keys().cloned().collect()
    }

    /// Get a mission store for desktop management.
    /// Uses the default user's store if available, or creates a temporary one.
    pub async fn get_mission_store(&self) -> Arc<dyn MissionStore> {
        // Try to get from the first existing session
        if let Some(session) = self.sessions.read().await.values().next() {
            return Arc::clone(&session.mission_store);
        }

        // No existing sessions, create a temporary store
        let store_type = std::env::var("MISSION_STORE_TYPE")
            .map(|s| MissionStoreType::from_str(&s))
            .unwrap_or(MissionStoreType::Sqlite);

        let base_dir = self
            .config
            .working_dir
            .join(".sandboxed-sh")
            .join("missions");

        let user = crate::api::auth::implicit_single_tenant_user(&self.config);
        match create_mission_store(store_type, base_dir, &user.id).await {
            Ok(store) => Arc::from(store),
            Err(err) => {
                tracing::warn!(
                    "Failed to create mission store for desktop management: {}",
                    err
                );
                Arc::new(mission_store::InMemoryMissionStore::new())
            }
        }
    }
}

/// Execution progress for showing overall mission progress
#[derive(Debug, Clone, Serialize, Default)]
pub struct ExecutionProgress {
    /// Total number of subtasks
    pub total_subtasks: usize,
    /// Number of completed subtasks
    pub completed_subtasks: usize,
    /// Currently executing subtask description (if any)
    pub current_subtask: Option<String>,
    /// Current depth level (0=root, 1=subtask, 2=sub-subtask)
    pub current_depth: u8,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct ControlStatus {
    pub state: ControlRunState,
    pub queue_len: usize,
    pub mission_id: Option<Uuid>,
}

pub(super) async fn set_and_emit_status(
    status: &Arc<RwLock<ControlStatus>>,
    events: &broadcast::Sender<AgentEvent>,
    state: ControlRunState,
    queue_len: usize,
    mission_id: Option<Uuid>,
) {
    {
        let mut s = status.write().await;
        s.state = state;
        s.queue_len = queue_len;
        s.mission_id = mission_id;
    }
    let _ = events.send(AgentEvent::Status {
        state,
        queue_len,
        mission_id,
    });
}

pub(crate) async fn control_for_user(state: &Arc<AppState>, user: &AuthUser) -> ControlState {
    state.control.get_or_spawn(user).await
}
