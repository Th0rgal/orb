//! Named snapshots, forks and stop/resume for managed machines.
//!
//! - **Snapshots** freeze a machine's disk under a name owned by the
//!   mission's project (boat: `POST /saved-snapshots`). New machines start
//!   from one with `from_snapshot`. Boat bills them only beyond 10 included
//!   snapshots ($1.70/month each). The cleanup keeps the newest
//!   `snapshot_keep` ready snapshots per project, deletes ones unused for
//!   `snapshot_unused_days`, and never deletes one a provisioning machine is
//!   being created from.
//! - **Fork** creates a machine from another machine's latest background
//!   snapshot (boat's is up to about a minute stale: write and `sync` what
//!   the child needs, or take a named snapshot, before forking).
//! - **Stop** keeps the disk and bills nothing. The reaper stops (instead of
//!   destroying) idle machines whose owner is interrupted or awaiting the
//!   user, and resumes them when the owner works again. A stopped machine is
//!   closed after `stopped_retention_hours` or when its owner ends. Boat's
//!   key has no `sandbox.resume`, so a resume forks the stopped sandbox; the
//!   machine keeps its id, node id and owner, so missions placed on it
//!   continue.
//!
//! Spec: `docs/specs/managed-vm-lifecycle.md` ("Snapshots, forks, stop").

use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::{
    allocate_name, budget, register_alias, unregister_node, write_atomic, MachineState,
    ManagedError, ManagedMachine, ManagedManager, Owner, OwnerState, ProvisioningMode,
    SpawnRequest,
};

/// Boat bills named snapshots beyond this many, at `SNAPSHOT_USD_PER_MONTH`.
pub const INCLUDED_SNAPSHOTS: usize = 10;
pub const SNAPSHOT_USD_PER_MONTH: f64 = 1.70;
const SNAPSHOT_PREFIX: &str = "orb-snap-";
/// Deletes every delivered secret file on a VM; non-zero exit on failure.
pub const SECRETS_WIPE: &str =
    "sudo find /var/lib/orb-node /home -maxdepth 6 -name .paloma-secrets -prune -exec rm -rf {} + && sync";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManagedSnapshot {
    #[serde(default)]
    pub provisioning_mode: ProvisioningMode,
    /// Provider name (unique): `orb-snap-<project>-<label>-<suffix>`.
    pub name: String,
    /// The name the agent chose.
    pub label: String,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub owner_mission_id: Option<String>,
    #[serde(default)]
    pub owner_user_id: Option<String>,
    pub source_machine_id: String,
    /// Size of the source machine (a machine from it may pick another).
    pub source_size: String,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub last_used_at: Option<DateTime<Utc>>,
    /// `saving`, `ready` or `failed`.
    pub status: String,
    #[serde(default)]
    pub size_bytes: Option<u64>,
    #[serde(default)]
    pub error: Option<String>,
    /// Estimated monthly storage cost (0 within the included allowance).
    #[serde(default)]
    pub monthly_usd: f64,
}

/// Lowercase `[a-z0-9-]`, at most `max` chars, no leading/trailing dash.
pub fn slug(raw: &str, max: usize) -> String {
    let mut out = String::new();
    for c in raw.trim().chars() {
        let c = c.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
        if out.len() >= max {
            break;
        }
    }
    out.trim_matches('-').to_string()
}

/// Provider name for a new snapshot.
pub fn snapshot_name(project: Option<&str>, label: &str, suffix: &str) -> String {
    let project = slug(project.unwrap_or("none"), 24);
    let label = slug(label, 24);
    format!(
        "{SNAPSHOT_PREFIX}{}-{}-{suffix}",
        if project.is_empty() { "none" } else { &project },
        if label.is_empty() { "warm" } else { &label }
    )
}

/// The reaper stops (rather than destroys) for these reasons: the owner is
/// only waiting and may resume.
pub fn stops_instead_of_destroy(reason: &str) -> bool {
    reason.starts_with("owner_") && reason.ends_with("_idle")
}

/// Monthly cost per snapshot: the oldest `INCLUDED_SNAPSHOTS` are free.
pub fn price_snapshots(snaps: &mut [ManagedSnapshot]) {
    let mut order: Vec<usize> = (0..snaps.len()).collect();
    order.sort_by_key(|i| snaps[*i].created_at);
    for (rank, i) in order.into_iter().enumerate() {
        snaps[i].monthly_usd = if rank < INCLUDED_SNAPSHOTS {
            0.0
        } else {
            SNAPSHOT_USD_PER_MONTH
        };
    }
}

/// Which snapshots the cleanup deletes: beyond the newest `keep` ready ones
/// per project, or unused for `unused_days`; never a snapshot in `in_use`.
pub fn cleanup_plan(
    snaps: &[ManagedSnapshot],
    keep: usize,
    unused_days: i64,
    in_use: &[String],
    now: DateTime<Utc>,
) -> Vec<String> {
    let mut by_project: std::collections::HashMap<Option<String>, Vec<&ManagedSnapshot>> =
        std::collections::HashMap::new();
    for s in snaps.iter().filter(|s| s.status == "ready") {
        by_project.entry(s.project.clone()).or_default().push(s);
    }
    let mut out = Vec::new();
    for list in by_project.values_mut() {
        list.sort_by_key(|s| std::cmp::Reverse(s.created_at));
        for (i, s) in list.iter().enumerate() {
            let last = s.last_used_at.unwrap_or(s.created_at).max(s.created_at);
            let stale = now - last > chrono::Duration::days(unused_days);
            if (i >= keep || stale) && !in_use.contains(&s.name) {
                out.push(s.name.clone());
            }
        }
    }
    // A failed save never becomes usable.
    out.extend(
        snaps
            .iter()
            .filter(|s| s.status == "failed" && !in_use.contains(&s.name))
            .map(|s| s.name.clone()),
    );
    out.sort();
    out
}

/// What a caller may see or use: its own tenant and the same project.
pub fn snapshot_visible(s: &ManagedSnapshot, tenant: Option<&str>, project: Option<&str>) -> bool {
    s.owner_user_id.as_deref() == tenant && s.project.as_deref() == project
}

impl ManagedManager {
    fn snapshots_path(&self) -> std::path::PathBuf {
        self.dir.join("managed_snapshots.json")
    }

    pub(super) async fn load_snapshots(&self) {
        if let Some(list) = std::fs::read(self.snapshots_path())
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<ManagedSnapshot>>(&b).ok())
        {
            *self.snapshots.lock().await = list;
        }
    }

    async fn persist_snapshots(&self) {
        let list = self.snapshots.lock().await.clone();
        let _ = std::fs::create_dir_all(&self.dir);
        write_atomic(
            &self.snapshots_path(),
            &serde_json::to_vec_pretty(&list).unwrap_or_default(),
            false,
        );
    }

    /// Snapshots visible to a tenant/project, with storage prices.
    pub async fn list_snapshots(
        &self,
        tenant: Option<&str>,
        project: Option<&str>,
    ) -> Vec<ManagedSnapshot> {
        let mut all = self.snapshots.lock().await.clone();
        price_snapshots(&mut all);
        all.into_iter()
            .filter(|s| snapshot_visible(s, tenant, project))
            .collect()
    }

    /// Every snapshot (operator view, Orb settings).
    pub async fn all_snapshots(&self) -> Vec<ManagedSnapshot> {
        let mut all = self.snapshots.lock().await.clone();
        price_snapshots(&mut all);
        all
    }

    /// Newest `ready` worker snapshot visible to `(tenant, project)`, if any.
    pub async fn newest_ready_worker_snapshot(
        &self,
        tenant: Option<&str>,
        project: Option<&str>,
    ) -> Option<String> {
        let project = project.map(str::trim).filter(|p| !p.is_empty())?;
        self.snapshots
            .lock()
            .await
            .iter()
            .filter(|s| {
                s.status == "ready"
                    && s.provisioning_mode.is_worker()
                    && snapshot_visible(s, tenant, Some(project))
            })
            .max_by_key(|s| s.created_at)
            .map(|s| s.name.clone())
    }

    /// Image, source snapshot and fork source for a spawn request.
    pub(super) async fn resolve_source(
        &self,
        req: &SpawnRequest,
    ) -> Result<
        (
            String,
            Option<String>,
            Option<(String, String)>,
            ProvisioningMode,
        ),
        ManagedError,
    > {
        if let Some(of) = req.fork_of.as_deref() {
            let src = self
                .get(of)
                .await
                .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
            if !matches!(src.state, MachineState::Online | MachineState::Stopped) {
                return Err(ManagedError::new(
                    "not_forkable",
                    409,
                    "Only an online or stopped machine can be forked",
                ));
            }
            if src.antigravity_projected {
                return Err(ManagedError::new(
                    "not_forkable",
                    409,
                    "This machine holds a projected sign-in and cannot be copied",
                ));
            }
            if (src.owner_user_id.is_some() || !src.provisioning_mode.is_worker())
                && src.owner_user_id != req.owner_user_id
            {
                return Err(ManagedError::new(
                    "forbidden",
                    403,
                    "Managed machine belongs to another user",
                ));
            }
            let pid = src.provider_id.clone().ok_or_else(|| {
                ManagedError::new("not_forkable", 409, "Machine has no provider sandbox yet")
            })?;
            let mode = ProvisioningMode::inherit(req.provisioning_mode, src.provisioning_mode)?;
            return Ok((src.image.clone(), None, Some((src.id.clone(), pid)), mode));
        }
        if let Some(name) = req.from_snapshot.as_deref().map(str::trim).filter(|n| {
            !n.is_empty()
                && !n.eq_ignore_ascii_case("none")
                && !n.eq_ignore_ascii_case("base")
                && !n.eq_ignore_ascii_case("light")
        }) {
            let latest_name = if name.eq_ignore_ascii_case("latest") {
                Some(
                    self.newest_ready_worker_snapshot(
                        req.owner_user_id.as_deref(),
                        req.snapshot_project.as_deref(),
                    )
                    .await
                    .ok_or_else(|| {
                        ManagedError::new(
                            "snapshot_not_found",
                            404,
                            "No ready project snapshot found; omit from_snapshot for light mode or see list_managed_snapshots",
                        )
                    })?,
                )
            } else {
                None
            };
            let target_name = latest_name.as_deref().unwrap_or(name);
            let mut snaps = self.snapshots.lock().await;
            let snap = snaps
                .iter_mut()
                .find(|s| {
                    (s.name == target_name || s.label == target_name)
                        && snapshot_visible(
                            s,
                            req.owner_user_id.as_deref(),
                            req.snapshot_project.as_deref(),
                        )
                })
                .ok_or_else(|| {
                    ManagedError::new(
                        "snapshot_not_found",
                        404,
                        format!("Unknown snapshot '{name}'; see list_managed_snapshots"),
                    )
                })?;
            if snap.status != "ready" {
                return Err(ManagedError::new(
                    "snapshot_not_ready",
                    409,
                    format!("Snapshot '{}' is {}", snap.label, snap.status),
                ));
            }
            let mode = ProvisioningMode::inherit(req.provisioning_mode, snap.provisioning_mode)?;
            snap.last_used_at = Some(Utc::now());
            let provider_name = snap.name.clone();
            drop(snaps);
            self.persist_snapshots().await;
            return Ok((provider_name.clone(), Some(provider_name), None, mode));
        }
        let mode = req.provisioning_mode.unwrap_or_default();
        let image = if mode.is_worker() {
            Self::resolve_image(&self.settings, req.image.as_deref())?
        } else {
            let image = req
                .image
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    ManagedError::new(
                        "image_required",
                        400,
                        "Raw mode requires an explicit clean image",
                    )
                })?;
            if !self
                .settings
                .raw_allowed_images
                .iter()
                .any(|allowed| allowed == image)
            {
                return Err(ManagedError::new(
                    "image_not_allowed",
                    403,
                    "Raw image is not in SANDBOXED_MANAGED_RAW_IMAGES",
                ));
            }
            image.to_owned()
        };
        Ok((image, None, None, mode))
    }

    /// Save a named snapshot of a machine for `project`. Returns at once
    /// with status `saving`; a background task records `ready`/`failed`.
    pub async fn snapshot_machine(
        self: &std::sync::Arc<Self>,
        id: &str,
        label: &str,
        project: Option<&str>,
        owner_mission_id: Option<&str>,
        tenant: Option<&str>,
    ) -> Result<ManagedSnapshot, ManagedError> {
        let m = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        let provider = self
            .provider_for(&m.provider)
            .ok_or_else(|| ManagedError::new("disabled", 503, "No managed-machine provider"))?;
        if !provider.supports_snapshots() {
            return Err(ManagedError::new(
                "unsupported_by_provider",
                409,
                format!(
                    "Provider '{}' does not support managed snapshots",
                    provider.name()
                ),
            ));
        }
        if !matches!(m.state, MachineState::Online | MachineState::Stopped) {
            return Err(ManagedError::new(
                "not_snapshottable",
                409,
                "Only an online or stopped machine can be snapshotted",
            ));
        }
        if m.antigravity_projected {
            return Err(ManagedError::new(
                "not_snapshottable",
                409,
                "This machine holds a projected sign-in and cannot be saved",
            ));
        }
        if (m.owner_user_id.is_some() || !m.provisioning_mode.is_worker())
            && m.owner_user_id.as_deref() != tenant
        {
            return Err(ManagedError::new(
                "forbidden",
                403,
                "Managed machine belongs to another user",
            ));
        }
        let pid = m.provider_id.clone().ok_or_else(|| {
            ManagedError::new(
                "not_snapshottable",
                409,
                "Machine has no provider sandbox yet",
            )
        })?;
        let label = slug(label, 24);
        if label.is_empty() {
            return Err(ManagedError::new(
                "invalid_name",
                400,
                "Name the snapshot (letters, digits, dashes)",
            ));
        }
        // Secrets delivered to missions must never be frozen into the
        // image: a running VM is wiped now (failure aborts), a stopped one
        // only qualifies if its wipe succeeded when it stopped.
        if m.provisioning_mode.is_worker() {
            match m.state {
            MachineState::Online => self.wipe_secrets(provider.as_ref(), &pid).await?,
            _ if !m.secrets_wiped => {
                return Err(ManagedError::new(
                    "not_snapshottable",
                    409,
                    "This stopped machine was not verified free of delivered secrets; resume it and snapshot while running",
                ))
            }
            _ => {}
        }
        }
        let name = snapshot_name(project, &label, &super::random_id()[..4]);
        provider
            .save_snapshot(&pid, &name)
            .await
            .map_err(|e| ManagedError::new("provider_error", 502, e))?;
        let snap = ManagedSnapshot {
            provisioning_mode: m.provisioning_mode,
            name: name.clone(),
            label,
            project: project.map(str::to_string),
            owner_mission_id: owner_mission_id.map(str::to_string),
            owner_user_id: tenant.map(str::to_string),
            source_machine_id: m.id.clone(),
            source_size: m.size.clone(),
            created_at: Utc::now(),
            last_used_at: None,
            status: "saving".into(),
            size_bytes: None,
            error: None,
            monthly_usd: 0.0,
        };
        self.snapshots.lock().await.push(snap.clone());
        self.persist_snapshots().await;
        self.ledger("snapshot_saving", &m);
        let this = std::sync::Arc::clone(self);
        tokio::spawn(async move {
            let deadline = tokio::time::Instant::now() + Duration::from_secs(20 * 60);
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let state = provider.snapshot(&name).await;
                let done = match &state {
                    Ok(s) if s.status == "ready" || s.status == "failed" => true,
                    _ => tokio::time::Instant::now() > deadline,
                };
                if done {
                    let mut snaps = this.snapshots.lock().await;
                    if let Some(s) = snaps.iter_mut().find(|s| s.name == name) {
                        match state {
                            Ok(p) if p.status == "ready" => {
                                s.status = "ready".into();
                                s.size_bytes = p.size_bytes;
                            }
                            Ok(p) => {
                                s.status = "failed".into();
                                s.error = Some(format!("provider status {}", p.status));
                            }
                            Err(e) => {
                                s.status = "failed".into();
                                s.error = Some(e);
                            }
                        }
                    }
                    drop(snaps);
                    this.persist_snapshots().await;
                    break;
                }
            }
        });
        Ok(snap)
    }

    /// Delete a snapshot the caller can see. Refused while a machine is
    /// being created from it.
    pub async fn delete_snapshot(
        &self,
        name: &str,
        tenant: Option<&str>,
        project: Option<&str>,
    ) -> Result<(), ManagedError> {
        let snap = self
            .snapshots
            .lock()
            .await
            .iter()
            .find(|s| (s.name == name || s.label == name) && snapshot_visible(s, tenant, project))
            .cloned()
            .ok_or_else(|| ManagedError::new("snapshot_not_found", 404, "Unknown snapshot"))?;
        if self.snapshots_in_use().await.contains(&snap.name) {
            return Err(ManagedError::new(
                "snapshot_in_use",
                409,
                "A machine is being created from this snapshot; retry when it is online",
            ));
        }
        if let Some(p) = self
            .provider_for("boat")
            .or_else(|| self.default_provider())
        {
            p.delete_snapshot(&snap.name)
                .await
                .map_err(|e| ManagedError::new("provider_error", 502, e))?;
        }
        self.snapshots.lock().await.retain(|s| s.name != snap.name);
        self.persist_snapshots().await;
        Ok(())
    }

    /// Snapshots a machine is being provisioned from right now.
    async fn snapshots_in_use(&self) -> Vec<String> {
        self.machines
            .lock()
            .await
            .iter()
            .filter(|m| {
                matches!(
                    m.state,
                    MachineState::Provisioning | MachineState::Enrolling
                )
            })
            .filter_map(|m| m.source_snapshot.clone())
            .collect()
    }

    /// Snapshot cleanup pass (dry-run aware): see [`cleanup_plan`].
    pub async fn cleanup_snapshots(&self) -> Vec<String> {
        let snaps = self.snapshots.lock().await.clone();
        let in_use = self.snapshots_in_use().await;
        let plan = cleanup_plan(
            &snaps,
            self.settings.snapshot_keep,
            self.settings.snapshot_unused_days,
            &in_use,
            Utc::now(),
        );
        if plan.is_empty() {
            return plan;
        }
        if self.dry_run() {
            tracing::info!(snapshots = ?plan, "managed snapshot cleanup (dry-run) would delete");
            return plan;
        }
        let mut deleted = Vec::new();
        let snap_provider = self
            .provider_for("boat")
            .or_else(|| self.default_provider());
        for name in plan {
            let ok = match &snap_provider {
                Some(p) => p.delete_snapshot(&name).await.is_ok(),
                None => true,
            };
            if ok {
                deleted.push(name);
            }
        }
        self.snapshots
            .lock()
            .await
            .retain(|s| !deleted.contains(&s.name));
        self.persist_snapshots().await;
        tracing::info!(snapshots = ?deleted, "managed snapshot cleanup deleted");
        deleted
    }

    /// Stop a machine: disk kept, billing ends. `by_reaper` marks it for
    /// automatic resume when its owner works again.
    pub async fn stop_inner(
        &self,
        id: &str,
        reason: &str,
        by_reaper: bool,
    ) -> Result<ManagedMachine, ManagedError> {
        let m = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        if m.state == MachineState::Stopped {
            return Ok(m);
        }
        if m.state != MachineState::Online {
            return Err(ManagedError::new(
                "not_running",
                409,
                "Only an online machine can be stopped",
            ));
        }
        let provider_opt = self.provider_for(&m.provider);
        if let Some(provider) = &provider_opt {
            if !provider.supports_free_stop() {
                return Err(ManagedError::new(
                    "unsupported_by_provider",
                    409,
                    format!(
                        "Provider '{}' continues billing stopped servers; destroy the machine instead",
                        provider.name()
                    ),
                ));
            }
        }
        unregister_node(&m);
        self.relay.close(&m.id).await;
        let mut secrets_wiped = false;
        if let (Some(provider), Some(pid)) = (&provider_opt, &m.provider_id) {
            if m.provisioning_mode.is_worker() {
                self.wipe_projection(provider.as_ref(), pid, &m).await;
                // The kept disk must not hold delivered secrets.
                secrets_wiped = self.wipe_secrets(provider.as_ref(), pid).await.is_ok();
            }
            provider
                .stop(pid)
                .await
                .map_err(|e| ManagedError::new("provider_error", 502, e))?;
        }
        let now = Utc::now();
        let reason = reason.to_string();
        let m = self
            .update(&m.id, |m| {
                if !m.cost_is_metered {
                    m.cost_usd = m.estimated_cost(now);
                }
                m.state = MachineState::Stopped;
                m.stopped_at = Some(now);
                m.stopped_by_reaper = by_reaper;
                m.secrets_wiped = secrets_wiped;
                m.destroy_reason = Some(format!("stopped: {reason}"));
                m.reap_at = None;
                m.reap_reason = None;
                m.antigravity_projected = false;
            })
            .await
            .unwrap_or(m);
        self.ledger("stopped", &m);
        Ok(m)
    }

    /// Resume a stopped machine as a fork of its stopped sandbox, keeping
    /// its id, node id and owner. Budget and caps apply like a new rent.
    pub async fn resume(
        self: &std::sync::Arc<Self>,
        id: &str,
        ttl_minutes: Option<u64>,
    ) -> Result<ManagedMachine, ManagedError> {
        self.resume_with_lineage(id, ttl_minutes, &[]).await
    }

    pub async fn resume_with_lineage(
        self: &std::sync::Arc<Self>,
        id: &str,
        ttl_minutes: Option<u64>,
        cap_lineage: &[String],
    ) -> Result<ManagedMachine, ManagedError> {
        let m = self
            .get(id)
            .await
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
        let provider = self
            .provider_for(&m.provider)
            .ok_or_else(|| ManagedError::new("disabled", 503, "No managed-machine provider"))?;
        if !self.is_provider_enabled(provider.name()) {
            return Err(ManagedError::new(
                "provider_disabled",
                409,
                format!(
                    "Provider '{}' is disabled in Settings",
                    super::provider_display_name(provider.name())
                ),
            ));
        }
        if !provider.supports_free_stop() {
            return Err(ManagedError::new(
                "unsupported_by_provider",
                409,
                format!(
                    "Provider '{}' does not support stop/resume",
                    provider.name()
                ),
            ));
        }
        let core_url = self.core_url_for(m.provisioning_mode)?;
        if m.state != MachineState::Stopped {
            return Err(ManagedError::new(
                "not_stopped",
                409,
                "Only a stopped machine can be resumed",
            ));
        }
        let pid = m
            .provider_id
            .clone()
            .ok_or_else(|| ManagedError::new("not_stopped", 409, "No stopped sandbox to resume"))?;
        let ttl = ttl_minutes
            .unwrap_or(self.settings.default_ttl_minutes)
            .clamp(5, self.settings.max_ttl_minutes.max(5));
        let machine = {
            let _guard = self.admission.lock().await;
            let live_snapshot = self.machines.lock().await.clone();
            let cap_pool_id = self
                .check_concurrency_quota(
                    &live_snapshot,
                    &m.provider,
                    cap_lineage,
                    m.cap_pool_id.as_deref(),
                    m.owner_mission_id
                        .as_deref()
                        .or(m.requested_by_mission_id.as_deref()),
                    m.owner_user_id.as_deref(),
                )
                .await?;
            let b = self.budget_view(&live_snapshot);
            let new_cost = ttl as f64 / 60.0 * m.usd_per_hour;
            if let Some(cap) = self
                .settings
                .daily_cap_usd
                .filter(|cap| b.spent_today_usd + b.committed_usd + new_cost > *cap)
            {
                return Err(ManagedError::new(
                    "budget_exceeded",
                    402,
                    format!("Daily managed-machine budget ${cap:.2} would be exceeded"),
                ));
            }
            if let Some(pool) = m.budget_pool_id.as_deref() {
                self.check_pool(
                    pool,
                    budget::reservation_for(ttl, m.usd_per_hour),
                    "this resume",
                )
                .await?;
            }
            let live: Vec<String> = live_snapshot
                .iter()
                .filter(|x| x.id != m.id && (x.state.is_live() || x.state == MachineState::Stopped))
                .map(|x| x.name.clone())
                .collect();
            let now = Utc::now();
            let cost_so_far = m.cost_usd.max(m.estimated_cost(now));
            let name = if live.contains(&m.name) {
                allocate_name(&m.size, &live)
            } else {
                m.name.clone()
            };
            let machine = self
                .update(&m.id, |x| {
                    x.name = name;
                    x.state = MachineState::Provisioning;
                    x.cap_pool_id = cap_pool_id;
                    x.fork_source_provider_id = Some(pid.clone());
                    x.provider_id = None;
                    x.resumes += 1;
                    x.cost_before_resume = cost_so_far;
                    x.cost_usd = cost_so_far;
                    x.cost_is_metered = false;
                    x.ledger_closed = false;
                    x.run_started_at = Some(now);
                    x.expires_at = now + chrono::Duration::minutes(ttl as i64);
                    x.stopped_at = None;
                    x.stopped_by_reaper = false;
                    x.destroy_reason = None;
                    x.online_at = None;
                    x.error = None;
                })
                .await
                .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown managed machine"))?;
            register_alias(&machine);
            machine
        };
        self.ledger("resume_requested", &machine);
        let this = std::sync::Arc::clone(self);
        let mid = machine.id.clone();
        tokio::spawn(async move {
            if let Err(error) = this.provision(&mid, provider, &core_url, ttl).await {
                tracing::warn!(machine = %mid, %error, "managed machine failed to resume");
                let _ = this
                    .destroy_inner(&mid, Some(format!("resume failed: {error}")), true)
                    .await;
            }
        });
        Ok(machine)
    }

    /// Reaper rules for a stopped machine: close it after the retention or
    /// when its owner ended; resume it when the reaper stopped it and its
    /// owner works again.
    pub(super) async fn reap_stopped(
        self: &std::sync::Arc<Self>,
        m: &ManagedMachine,
        now: DateTime<Utc>,
    ) {
        let owner = self.owner_of(m).await;
        let retention = chrono::Duration::hours(self.settings.stopped_retention_hours as i64);
        let expired = m.stopped_at.is_some_and(|t| now - t > retention);
        let ended = match owner {
            Owner::Mission(Some(OwnerState::Terminal { status })) => {
                Some(format!("owner_{status}"))
            }
            Owner::Mission(Some(OwnerState::Missing)) => Some("owner_missing".to_string()),
            _ => None,
        };
        if expired || ended.is_some() {
            let reason = ended.unwrap_or_else(|| "stopped_retention".into());
            let m = self
                .update(&m.id, |m| {
                    m.state = MachineState::Destroyed;
                    m.destroyed_at = Some(now);
                    m.destroy_reason = Some(reason);
                })
                .await;
            if let Some(m) = m {
                self.ledger("destroyed", &m);
                // Delete the disk if the key allows it; boat drops it after
                // 14 days otherwise.
                if let (Some(p), Some(pid)) = (self.provider_for(&m.provider), &m.provider_id) {
                    let _ = p.destroy(pid).await;
                }
            }
            return;
        }
        if !m.ledger_closed {
            self.refresh_usage(&m.id).await;
        }
        if m.stopped_by_reaper && matches!(owner, Owner::Mission(Some(OwnerState::Working))) {
            match self.resume(&m.id, None).await {
                Ok(_) => {
                    tracing::info!(machine = %m.id, "resumed managed machine for its working owner")
                }
                Err(e) => {
                    tracing::info!(machine = %m.id, error = %e, "managed auto-resume refused")
                }
            }
        }
    }

    /// Delete delivered secret files on a VM; an error if that is not proven.
    pub(super) async fn wipe_secrets(
        &self,
        provider: &dyn super::ManagedProvider,
        pid: &str,
    ) -> Result<(), ManagedError> {
        let out = provider.exec(pid, SECRETS_WIPE, 120).await.map_err(|e| {
            ManagedError::new(
                "secret_wipe_failed",
                502,
                format!("could not remove delivered secrets: {e}"),
            )
        })?;
        match super::exec_exit_code(&out) {
            Some(code) if code != 0 => Err(ManagedError::new(
                "secret_wipe_failed",
                502,
                format!("could not remove delivered secrets (exit {code})"),
            )),
            _ => Ok(()),
        }
    }

    /// Remove a projected sign-in before the disk is retained.
    pub(super) async fn wipe_projection(
        &self,
        provider: &dyn super::ManagedProvider,
        pid: &str,
        m: &ManagedMachine,
    ) {
        if !m.antigravity_projected {
            return;
        }
        let wiped = provider
            .exec(
                pid,
                "sudo rm -rf /var/lib/orb-node/work/managed-auth /var/lib/orb-node/node.cred && sync",
                60,
            )
            .await;
        if let Err(e) = &wiped {
            tracing::warn!(machine = %m.id, error = %e, "could not wipe projected sign-in");
        }
        self.ledger(
            if wiped.is_ok() {
                "antigravity_wiped"
            } else {
                "antigravity_wipe_failed"
            },
            m,
        );
    }
}
