//! Workspace management API endpoints.
//!
//! Provides endpoints for managing execution workspaces:
//! - List workspaces
//! - Create workspace
//! - Get workspace details
//! - Delete workspace

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    routing::{delete, get, post, put},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

use crate::nspawn::NspawnDistro;
use crate::util::sanitize_skill_list;
use crate::workspace::{self, TailscaleMode, Workspace, WorkspaceStatus, WorkspaceType};

/// Create workspace routes.
pub fn routes() -> Router<Arc<super::routes::AppState>> {
    Router::new()
        .route("/", get(list_workspaces))
        .route("/", post(create_workspace))
        .route("/:id", get(get_workspace))
        .route("/:id", put(update_workspace))
        .route("/:id", delete(delete_workspace))
        .route("/:id/build", post(build_workspace))
        .route("/:id/sync", post(sync_workspace))
        .route("/:id/exec", post(exec_workspace_command))
        .route("/:id/exec-rooted", post(exec_rooted_workspace_command))
        // Debug endpoints for container development
        .route("/:id/debug", get(get_workspace_debug))
        .route("/:id/rerun-init", post(rerun_init_script))
        .route("/:id/init-log", get(get_init_log))
        // Memory monitoring
        .route("/:id/memory", get(get_workspace_memory))
        .route("/memory/all", get(get_all_workspaces_memory))
        // Live + persisted memory caps (per-workspace override of the
        // MISSION_MEMORY_* defaults; applies to running scopes via
        // `systemctl set-property --runtime`)
        .route(
            "/:id/resources",
            get(get_workspace_resources).post(update_workspace_resources),
        )
        // Backend preflight checks
        .route(
            "/:id/backends/:backend_id/preflight",
            get(check_backend_preflight),
        )
}

// ─────────────────────────────────────────────────────────────────────────────
// Request/Response Types
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct CreateWorkspaceRequest {
    /// Human-readable name
    pub name: String,
    /// Type of workspace (defaults to "host")
    #[serde(default)]
    pub workspace_type: WorkspaceType,
    /// Working directory path (optional, defaults based on type)
    pub path: Option<PathBuf>,
    /// Skill names from library to sync to this workspace
    #[serde(default)]
    pub skills: Vec<String>,
    /// Plugin identifiers for hooks
    #[serde(default)]
    pub plugins: Vec<String>,
    /// Optional workspace template name
    pub template: Option<String>,
    /// Preferred Linux distribution for container workspaces
    pub distro: Option<String>,
    /// Environment variables always loaded in this workspace
    pub env_vars: Option<HashMap<String, String>>,
    /// Init script to run when the workspace is built/rebuilt
    pub init_script: Option<String>,
    /// Whether to share the host network (default: true).
    /// Set to false for isolated networking (e.g., Tailscale).
    pub shared_network: Option<bool>,
    /// Tailscale networking mode when shared_network is false.
    pub tailscale_mode: Option<TailscaleMode>,
    /// MCP server names to enable for this workspace.
    /// See `Workspace::mcps` for the full interaction with `mcps_replace_defaults`.
    #[serde(default)]
    pub mcps: Vec<String>,
    /// `true` (default) = `mcps` list replaces defaults, `false` = additive.
    /// See `Workspace::mcps_replace_defaults`.
    #[serde(default = "crate::workspace::default_true")]
    pub mcps_replace_defaults: bool,
    /// Optional config profile to apply to this workspace.
    pub config_profile: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateWorkspaceRequest {
    pub workspace_type: Option<WorkspaceType>,
    pub path: Option<PathBuf>,
    /// Human-readable name (optional update)
    pub name: Option<String>,
    /// Skill names from library to sync to this workspace
    pub skills: Option<Vec<String>>,
    /// Plugin identifiers for hooks
    pub plugins: Option<Vec<String>>,
    /// Optional workspace template name
    pub template: Option<String>,
    /// Preferred Linux distribution for container workspaces
    pub distro: Option<String>,
    /// Environment variables always loaded in this workspace
    pub env_vars: Option<HashMap<String, String>>,
    /// Init script to run when the workspace is built/rebuilt
    pub init_script: Option<String>,
    /// Init script fragment names to include (executed in order)
    pub init_scripts: Option<Vec<String>>,
    /// Whether to share the host network (default: true).
    /// Set to false for isolated networking (e.g., Tailscale).
    pub shared_network: Option<bool>,
    /// Tailscale networking mode when shared_network is false.
    pub tailscale_mode: Option<TailscaleMode>,
    /// MCP server names to enable for this workspace.
    pub mcps: Option<Vec<String>>,
    /// `true` (default) = `mcps` list replaces defaults, `false` = additive.
    pub mcps_replace_defaults: Option<bool>,
    /// Optional config profile to apply to this workspace.
    pub config_profile: Option<String>,
    /// Freeform workspace configuration (merged with existing config).
    pub config: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceResponse {
    pub id: Uuid,
    pub name: String,
    pub workspace_type: WorkspaceType,
    pub path: PathBuf,
    pub status: WorkspaceStatus,
    pub error_message: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub skills: Vec<String>,
    pub plugins: Vec<String>,
    pub template: Option<String>,
    pub distro: Option<String>,
    pub env_vars: HashMap<String, String>,
    pub init_scripts: Vec<String>,
    pub init_script: Option<String>,
    pub shared_network: Option<bool>,
    pub tailscale_mode: Option<TailscaleMode>,
    pub mcps: Vec<String>,
    pub mcps_replace_defaults: bool,
    pub config_profile: Option<String>,
    pub config: serde_json::Value,
    pub compute_policy: workspace::ComputePolicy,
    /// Harness CLI versions last probed inside this container workspace.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness_versions: Option<workspace::HarnessVersions>,
}

impl From<Workspace> for WorkspaceResponse {
    fn from(w: Workspace) -> Self {
        let compute_policy = w.compute_policy();
        Self {
            id: w.id,
            name: w.name,
            workspace_type: w.workspace_type,
            path: w.path,
            status: w.status,
            error_message: w.error_message,
            created_at: w.created_at,
            skills: w.skills,
            plugins: w.plugins,
            template: w.template,
            distro: w.distro,
            env_vars: w.env_vars,
            init_scripts: w.init_scripts,
            init_script: w.init_script,
            shared_network: w.shared_network,
            tailscale_mode: w.tailscale_mode,
            mcps: w.mcps,
            mcps_replace_defaults: w.mcps_replace_defaults,
            config_profile: w.config_profile,
            config: w.config,
            compute_policy,
            harness_versions: w.harness_versions,
        }
    }
}

/// Look up a workspace by ID, returning 404 if it does not exist.
async fn require_workspace(
    store: &workspace::WorkspaceStore,
    id: Uuid,
) -> Result<Workspace, (StatusCode, String)> {
    store
        .get(id)
        .await
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("Workspace {} not found", id)))
}

// ─────────────────────────────────────────────────────────────────────────────
// Handlers
// ─────────────────────────────────────────────────────────────────────────────

/// GET /api/workspaces - List all workspaces.
async fn list_workspaces(
    State(state): State<Arc<super::routes::AppState>>,
) -> Result<Json<Vec<WorkspaceResponse>>, (StatusCode, String)> {
    let workspaces = state.workspaces.list().await;
    let responses: Vec<WorkspaceResponse> =
        dedupe_workspace_list(workspaces, &state.config.working_dir)
            .into_iter()
            .map(Into::into)
            .collect();
    Ok(Json(responses))
}

fn dedupe_workspace_list(workspaces: Vec<Workspace>, working_dir: &Path) -> Vec<Workspace> {
    let canonical_container_root = working_dir.join(".sandboxed-sh").join("containers");
    let mut by_identity: HashMap<(String, String), Workspace> = HashMap::new();

    for workspace in workspaces {
        let key = (
            workspace.workspace_type.as_str().to_string(),
            workspace.name.clone(),
        );
        match by_identity.get_mut(&key) {
            Some(existing) => {
                let existing_current = existing.path.starts_with(&canonical_container_root);
                let candidate_current = workspace.path.starts_with(&canonical_container_root);
                if candidate_current && !existing_current {
                    *existing = workspace;
                }
            }
            None => {
                by_identity.insert(key, workspace);
            }
        }
    }

    let mut list: Vec<_> = by_identity.into_values().collect();
    list.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.workspace_type.as_str().cmp(b.workspace_type.as_str()))
            .then_with(|| a.path.cmp(&b.path))
    });
    list
}

/// Validate workspace name to prevent path traversal.
fn validate_workspace_name(name: &str) -> Result<(), (StatusCode, String)> {
    if name.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Name cannot be empty".to_string()));
    }
    if name.contains("..") || name.contains('/') || name.contains('\\') {
        return Err((
            StatusCode::BAD_REQUEST,
            "Name contains invalid characters".to_string(),
        ));
    }
    if name.starts_with('.') {
        return Err((
            StatusCode::BAD_REQUEST,
            "Name cannot start with a dot".to_string(),
        ));
    }
    Ok(())
}

/// Resolve and validate a custom workspace path.
fn resolve_custom_path(
    working_dir: &Path,
    custom_path: &Path,
) -> Result<PathBuf, (StatusCode, String)> {
    let resolved = if custom_path.is_absolute() {
        custom_path.to_path_buf()
    } else {
        working_dir.join(custom_path)
    };

    if !path_within(working_dir, &resolved) {
        return Err((
            StatusCode::BAD_REQUEST,
            "Custom path must be within the working directory".to_string(),
        ));
    }

    Ok(resolved)
}

/// Check whether a target path is within a base directory, even if it doesn't exist yet.
/// Returns false if the path contains traversal sequences or escapes the base directory.
fn path_within(base: &Path, target: &Path) -> bool {
    use std::path::Component;

    // Reject any path containing parent directory components (..)
    // This prevents traversal attacks like "/base/../../etc/passwd"
    for component in target.components() {
        if matches!(component, Component::ParentDir) {
            return false;
        }
    }

    let base_canonical = match base.canonicalize() {
        Ok(p) => p,
        Err(_) => return false, // Base must exist and be resolvable
    };

    if target.exists() {
        // For existing paths, canonicalize resolves symlinks
        match target.canonicalize() {
            Ok(target_canonical) => target_canonical.starts_with(&base_canonical),
            Err(_) => false,
        }
    } else {
        // For non-existent paths, find the nearest existing parent and verify it's within base
        let mut current = target.to_path_buf();
        while let Some(parent) = current.parent() {
            if parent.exists() {
                return match parent.canonicalize() {
                    Ok(parent_canonical) => parent_canonical.starts_with(&base_canonical),
                    Err(_) => false,
                };
            }
            current = parent.to_path_buf();
        }
        false
    }
}

/// POST /api/workspaces - Create a new workspace.
async fn create_workspace(
    State(state): State<Arc<super::routes::AppState>>,
    Json(req): Json<CreateWorkspaceRequest>,
) -> Result<Json<WorkspaceResponse>, (StatusCode, String)> {
    // Validate workspace name for path traversal
    validate_workspace_name(&req.name)?;

    if req
        .template
        .as_deref()
        .is_some_and(|t| !t.trim().is_empty())
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "Workspace templates have been retired; configure distro, skills, env_vars, and init_script directly.".to_string(),
        ));
    }

    let workspace_type = req.workspace_type;

    // Host workspaces require a custom path - the root working directory is reserved
    // for the default host workspace (which is created automatically).
    if workspace_type == WorkspaceType::Host && req.path.is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Host workspaces require a custom path. The root working directory is reserved for the default host workspace.".to_string(),
        ));
    }

    // Determine path
    let path = match &req.path {
        Some(custom_path) => resolve_custom_path(&state.config.working_dir, custom_path)?,
        None => match workspace_type {
            WorkspaceType::Host => {
                // This should be unreachable due to the check above, but keeping for safety
                return Err((
                    StatusCode::BAD_REQUEST,
                    "Host workspaces require a custom path".to_string(),
                ));
            }
            WorkspaceType::Container => {
                // Container workspaces go in a dedicated directory
                state
                    .config
                    .working_dir
                    .join(".sandboxed-sh/containers")
                    .join(&req.name)
            }
        },
    };

    let env_vars = sanitize_env_vars(req.env_vars.unwrap_or_default());
    let skills = sanitize_skill_list(req.skills);
    let init_scripts = Vec::new();
    let init_script = normalize_init_script(req.init_script);
    let distro = match req.distro.as_ref() {
        Some(value) => Some(normalize_distro_value(value)?),
        None => None,
    };
    let shared_network = req.shared_network;
    let tailscale_mode = req.tailscale_mode;
    let mcps = req.mcps;
    let mcps_replace_defaults = req.mcps_replace_defaults;
    let config_profile = req
        .config_profile
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let workspace = match workspace_type {
        WorkspaceType::Host => Workspace {
            id: Uuid::new_v4(),
            name: req.name,
            workspace_type: WorkspaceType::Host,
            path,
            status: WorkspaceStatus::Ready,
            error_message: None,
            config: serde_json::json!({}),
            template: None,
            distro,
            env_vars,
            init_scripts,
            init_script,
            created_at: chrono::Utc::now(),
            skills,
            plugins: req.plugins,
            shared_network,
            tailscale_mode,
            mcps,
            mcps_replace_defaults,
            config_profile,
            resolved_git_credentials: None,
            read_only_command_guard_dir: None,
            mission_project_skills: Vec::new(),
            harness_versions: None,
        },
        WorkspaceType::Container => {
            let mut ws = Workspace::new_container(req.name, path);
            ws.skills = skills;
            ws.plugins = req.plugins;
            ws.distro = distro;
            ws.env_vars = env_vars;
            ws.init_scripts = init_scripts;
            ws.init_script = init_script;
            ws.shared_network = shared_network;
            ws.tailscale_mode = tailscale_mode;
            ws.mcps = mcps;
            ws.mcps_replace_defaults = mcps_replace_defaults;
            ws.config_profile = config_profile;
            ws
        }
    };

    // Ready is a filesystem promise: admission immediately stats this root.
    // Only explicit creation may provision it; resuming a missing workspace
    // must not recreate a config-only replacement for lost source.
    if workspace.workspace_type == WorkspaceType::Host {
        tokio::fs::create_dir_all(&workspace.path)
            .await
            .map_err(|error| {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!("Cannot create host workspace directory: {error}"),
                )
            })?;
    }

    let id = state
        .workspaces
        .add(workspace.clone())
        .await
        .map_err(|error| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to persist workspace: {error}"),
            )
        })?;

    // Sync skills to workspace if any are specified
    let library_guard = state.library.read().await;
    if let Some(library) = library_guard.as_ref() {
        if !workspace.skills.is_empty() {
            if let Err(e) = workspace::sync_workspace_skills(&workspace, library).await {
                tracing::warn!(
                    workspace = %workspace.name,
                    error = %e,
                    "Failed to sync skills to workspace during creation"
                );
            }
        }
    } else if !workspace.skills.is_empty() {
        tracing::warn!(
            workspace = %workspace.name,
            "Library not initialized, cannot sync skills"
        );
    }
    drop(library_guard);

    tracing::info!("Created workspace: {} ({})", workspace.name, id);

    let response: WorkspaceResponse = workspace.into();

    Ok(Json(response))
}

/// GET /api/workspaces/:id - Get workspace details.
async fn get_workspace(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<WorkspaceResponse>, (StatusCode, String)> {
    require_workspace(&state.workspaces, id)
        .await
        .map(|w| Json(w.into()))
}

/// PUT /api/workspaces/:id - Update a workspace.
async fn update_workspace(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
    Json(req): Json<UpdateWorkspaceRequest>,
) -> Result<Json<WorkspaceResponse>, (StatusCode, String)> {
    let skills_changed = req.skills.is_some();
    let working_dir = state.config.working_dir.clone();
    let workspace = state
        .workspaces
        .update_with(id, move |workspace| {
            let apply = |existing: Workspace| -> Result<Workspace, (StatusCode, String)> {
                let mut workspace = existing.clone();
                if let Some(workspace_type) = req.workspace_type {
                    if existing.status != WorkspaceStatus::Building
                        && workspace_type != existing.workspace_type
                    {
                        return Err((
                            StatusCode::BAD_REQUEST,
                            "Workspace type cannot be changed after creation".to_string(),
                        ));
                    }
                    workspace.workspace_type = workspace_type;
                }
                if let Some(path) = req.path {
                    let resolved = resolve_custom_path(&working_dir, &path)?;
                    if existing.status != WorkspaceStatus::Building && resolved != existing.path {
                        return Err((
                            StatusCode::BAD_REQUEST,
                            "Workspace path cannot be changed after creation".to_string(),
                        ));
                    }
                    workspace.path = resolved;
                }
                // Validate name if provided
                if let Some(ref name) = req.name {
                    validate_workspace_name(name)?;
                    workspace.name = name.clone();
                }

                // Update skills if provided
                if let Some(skills) = req.skills {
                    workspace.skills = sanitize_skill_list(skills);
                }

                // Update plugins if provided
                if let Some(plugins) = req.plugins {
                    workspace.plugins = plugins;
                }

                if let Some(template) = req.template {
                    let trimmed = template.trim();
                    if trimmed.is_empty() {
                        workspace.template = None;
                    } else {
                        workspace.template = Some(trimmed.to_string());
                    }
                }

                if let Some(distro) = req.distro {
                    let trimmed = distro.trim();
                    if trimmed.is_empty() {
                        workspace.distro = None;
                    } else {
                        workspace.distro = Some(normalize_distro_value(trimmed)?);
                    }
                }

                if let Some(env_vars) = req.env_vars {
                    workspace.env_vars = sanitize_env_vars(env_vars);
                }

                if let Some(init_script) = req.init_script {
                    workspace.init_script = normalize_init_script(Some(init_script));
                }

                // Update init_scripts (fragment names) if provided
                if let Some(init_scripts) = req.init_scripts {
                    workspace.init_scripts = init_scripts;
                }

                // Update shared_network if explicitly set in the request.
                // The request uses Option<Option<bool>> pattern - outer Option for "field present",
                // inner Option for the actual value including null for "reset to default".
                // However, serde flattens this, so we check if the field was explicitly provided.
                // For now, we only update if Some() is passed; to reset, pass null explicitly via the UI.
                if req.shared_network.is_some() {
                    workspace.shared_network = req.shared_network;
                }

                // Update tailscale_mode if explicitly set in the request
                if req.tailscale_mode.is_some() {
                    workspace.tailscale_mode = req.tailscale_mode;
                }

                // Update MCPs if provided
                if let Some(mcps) = req.mcps {
                    workspace.mcps = mcps;
                }
                if let Some(exclude) = req.mcps_replace_defaults {
                    workspace.mcps_replace_defaults = exclude;
                }

                if let Some(config_profile) = req.config_profile {
                    let trimmed = config_profile.trim();
                    if trimmed.is_empty() {
                        workspace.config_profile = None;
                    } else {
                        workspace.config_profile = Some(trimmed.to_string());
                    }
                }

                // Merge freeform config (shallow merge of top-level keys). The control
                // registry path is server-owned and must not move with a client edit.
                if let Some(config) = req.config {
                    if let Some(new_obj) = config.as_object() {
                        let mut existing =
                            workspace.config.as_object().cloned().unwrap_or_default();
                        for (k, v) in new_obj {
                            if k == "mission_workspace_registry_control_root" {
                                continue;
                            }
                            existing.insert(k.clone(), v.clone());
                        }
                        workspace.config = serde_json::Value::Object(existing);
                    }
                }

                Ok(workspace)
            };
            let next = apply(workspace.clone())
                .map_err(|(status, message)| workspace::BuildConflict { status, message })?;
            *workspace = next;
            Ok(())
        })
        .await
        .map_err(|conflict| (conflict.status, conflict.message))?;

    // Sync skills and tools if they changed
    let library_guard = state.library.read().await;
    if let Some(library) = library_guard.as_ref() {
        if skills_changed && !workspace.skills.is_empty() {
            if let Err(e) = workspace::sync_workspace_skills(&workspace, library).await {
                tracing::warn!(
                    workspace = %workspace.name,
                    error = %e,
                    "Failed to sync skills to workspace during update"
                );
            }
        }
    } else if skills_changed && !workspace.skills.is_empty() {
        tracing::warn!(
            workspace = %workspace.name,
            "Library not initialized, cannot sync skills"
        );
    }

    tracing::info!("Updated workspace: {} ({})", workspace.name, id);

    Ok(Json(workspace.into()))
}

/// POST /api/workspaces/:id/sync - Manually sync skills to workspace.
async fn sync_workspace(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<WorkspaceResponse>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, id).await?;

    // Get library
    let library_guard = state.library.read().await;
    let library = library_guard.as_ref().ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "Library not initialized".to_string(),
        )
    })?;

    // Sync skills to workspace
    workspace::sync_workspace_skills(&workspace, library)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to sync skills: {}", e),
            )
        })?;

    tracing::info!("Synced skills to workspace: {} ({})", workspace.name, id);

    Ok(Json(workspace.into()))
}

/// DELETE /api/workspaces/:id - Delete a workspace.
async fn delete_workspace(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    if id == crate::workspace::DEFAULT_WORKSPACE_ID {
        return Err((
            StatusCode::BAD_REQUEST,
            "Cannot delete default host workspace".to_string(),
        ));
    }

    // If it's a container workspace, destroy the container first
    if let Some(ws) = state.workspaces.get(id).await {
        if ws.workspace_type == WorkspaceType::Container {
            // Stop any live mission/exec scopes for this workspace first.
            // Surviving scope processes (Tailscale daemons, leftover exec
            // shells) keep the rootfs busy and make removal fail with EBUSY
            // — this is how `dna` resisted deletion.
            match list_workspace_scope_units(&ws).await {
                Ok(units) => {
                    for unit in units {
                        let stopped = tokio::process::Command::new("systemctl")
                            .args(["stop", &unit])
                            .output()
                            .await
                            .map(|out| out.status.success())
                            .unwrap_or(false);
                        if !stopped {
                            tracing::warn!(unit = %unit, "Failed to stop workspace scope before deletion");
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!(
                        "Could not list scopes for workspace {} before deletion: {}",
                        ws.name,
                        e
                    );
                }
            }
            if let Err(e) = crate::workspace::destroy_container_workspace(&ws).await {
                tracing::error!("Failed to destroy container for workspace {}: {}", id, e);
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!(
                        "Failed to destroy container: {}. Workspace not deleted to prevent orphaned state.",
                        e
                    ),
                ));
            }
        }
    }

    if state.workspaces.delete(id).await {
        Ok((
            StatusCode::OK,
            format!("Workspace {} deleted successfully", id),
        ))
    } else {
        Err((StatusCode::NOT_FOUND, format!("Workspace {} not found", id)))
    }
}

#[derive(Debug, Deserialize)]
pub struct BuildWorkspaceRequest {
    /// Linux distribution to use (defaults to "ubuntu-noble")
    /// Options: "ubuntu-noble", "ubuntu-jammy", "debian-bookworm", "arch-linux"
    pub distro: Option<String>,
    /// Force rebuild even if the container already exists
    pub rebuild: Option<bool>,
}

/// Parse a distro string into a NspawnDistro enum.
fn parse_distro(s: &str) -> Result<NspawnDistro, String> {
    NspawnDistro::parse(s).ok_or_else(|| {
        format!(
            "Unknown distro '{}'. Supported: {}",
            s,
            NspawnDistro::supported_values().join(", ")
        )
    })
}

fn normalize_distro_value(value: &str) -> Result<String, (StatusCode, String)> {
    NspawnDistro::parse(value)
        .map(|d| d.api_value().to_string())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                format!(
                    "Unknown distro '{}'. Supported: {}",
                    value,
                    NspawnDistro::supported_values().join(", ")
                ),
            )
        })
}

fn normalize_init_script(value: Option<String>) -> Option<String> {
    value.filter(|script| !script.trim().is_empty())
}

fn sanitize_env_vars(env_vars: HashMap<String, String>) -> HashMap<String, String> {
    // Drop entries whose key is not a valid POSIX env var name. nspawn passes
    // `--setenv=KEY=VALUE` as one argv token, so a key containing `=`, whitespace,
    // a leading `-`, or a control character would either confuse the parser or be
    // silently mishandled. Values are passed through unchanged.
    env_vars
        .into_iter()
        .filter(|(key, value)| is_valid_env_name(key) && !value.contains('\0'))
        .collect()
}

pub(crate) fn is_valid_env_name(key: &str) -> bool {
    let mut chars = key.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Escape a string for safe use in shell commands.
fn shell_escape(s: &str) -> String {
    // Use single quotes and escape any single quotes in the string
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Build a systemd-nspawn (or host bash) invocation for running a shell command
/// in a workspace. Used by both exec (synchronous) and tasks (background).
///
/// Returns `(program, args)` ready for `tokio::process::Command::new(program).args(args)`.
/// For host workspaces, env vars should be set via `cmd.env()` on the returned Command —
/// the caller is responsible for that since we can't inject them into `args` for bash -c.
///
/// `cwd` sets the working directory inside the container (defaults to `/root`).
pub fn build_nspawn_command(
    workspace: &crate::workspace::Workspace,
    command: &str,
    extra_env: Option<&HashMap<String, String>>,
    cwd: Option<&str>,
) -> (String, Vec<String>) {
    use crate::workspace::WorkspaceType;

    match workspace.workspace_type {
        WorkspaceType::Host => {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string());
            (shell, vec!["-c".to_string(), command.to_string()])
        }
        WorkspaceType::Container => {
            let container_root = workspace.path.clone();
            let chdir = cwd.unwrap_or("/root");

            let mut nspawn_args = vec![
                "-D".to_string(),
                container_root.to_string_lossy().to_string(),
                "--quiet".to_string(),
                "--timezone=off".to_string(),
                "--chdir".to_string(),
                chdir.to_string(),
            ];

            let use_shared_network = workspace.shared_network.unwrap_or(true);
            let tailscale_mode = workspace
                .tailscale_mode
                .unwrap_or(crate::workspace::TailscaleMode::ExitNode);
            let tailscale_requested = crate::nspawn::tailscale_enabled(&workspace.env_vars);

            let tailscale_enabled = if use_shared_network {
                nspawn_args.extend(crate::workspace_exec::resolv_conf_nspawn_args());
                false
            } else if tailscale_requested {
                nspawn_args.push("--network-veth".to_string());
                nspawn_args.push("--capability=CAP_NET_ADMIN,CAP_NET_RAW".to_string());
                if Path::new("/dev/net/tun").exists() {
                    nspawn_args.push("--bind=/dev/net/tun".to_string());
                }
                true
            } else {
                nspawn_args.extend(crate::workspace_exec::resolv_conf_nspawn_args());
                false
            };

            // Inject workspace env vars
            for (key, value) in &workspace.env_vars {
                nspawn_args.push(format!("--setenv={}={}", key, value));
            }
            // Inject any caller-supplied extra env vars
            if let Some(env) = extra_env {
                for (key, value) in env {
                    nspawn_args.push(format!("--setenv={}={}", key, value));
                }
            }

            let final_command = if tailscale_enabled {
                let tailnet_only = tailscale_mode == crate::workspace::TailscaleMode::TailnetOnly;
                let mut bootstrap_cmd = String::new();
                for (k, v) in &workspace.env_vars {
                    if k.starts_with("TS_") && !v.trim().is_empty() {
                        bootstrap_cmd.push_str(&format!("export {}={}; ", k, shell_escape(v)));
                    }
                }
                bootstrap_cmd.push_str(
                    "if [ -x /usr/local/bin/sandboxed-tailscale-up ]; then \
                     /usr/local/bin/sandboxed-tailscale-up >/dev/null 2>&1 || true; \
                     fi; ",
                );
                if tailnet_only {
                    bootstrap_cmd.push_str(crate::workspace_exec::HOST0_GATEWAY_DISCOVERY);
                    bootstrap_cmd.push_str(
                        "if [ -n \"$_oa_gw\" ]; then \
                           ip route del default 2>/dev/null || true; \
                           ip route add default via \"$_oa_gw\" 2>/dev/null || true; \
                         fi; \
                         if [ ! -s /etc/resolv.conf ]; then \
                           printf 'nameserver 8.8.8.8\\nnameserver 1.1.1.1\\n' > /etc/resolv.conf 2>/dev/null || true; \
                         fi; "
                    );
                }
                bootstrap_cmd.push_str(command);
                bootstrap_cmd
            } else {
                command.to_string()
            };

            nspawn_args.extend(["/bin/bash".to_string(), "-c".to_string(), final_command]);
            ("systemd-nspawn".to_string(), nspawn_args)
        }
    }
}

/// POST /api/workspaces/:id/build - Build a container workspace.
async fn build_workspace(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
    body: Option<Json<BuildWorkspaceRequest>>,
) -> Result<Json<WorkspaceResponse>, (StatusCode, String)> {
    let force_rebuild = body.as_ref().and_then(|b| b.rebuild).unwrap_or(false);
    if let Some(distro) = body.as_ref().and_then(|b| b.distro.as_deref()) {
        parse_distro(distro).map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    }

    let claim = state
        .workspaces
        .try_claim_workspace_build(
            id,
            body.as_ref()
                .and_then(|b| b.distro.as_deref())
                .and_then(|d| parse_distro(d).ok())
                .map(|d| d.api_value().to_string()),
        )
        .await
        .map_err(|conflict| (conflict.status, conflict.message))?;
    let distro = match claim.workspace.distro.as_deref() {
        Some(value) => match parse_distro(value) {
            Ok(distro) => Some(distro),
            Err(error) => {
                let mut failed = claim.workspace.clone();
                failed.status = WorkspaceStatus::Error;
                failed.error_message = Some(error.clone());
                let _ = claim.settle(failed).await;
                return Err((StatusCode::BAD_REQUEST, error));
            }
        },
        None => None,
    };
    let mut response_workspace = claim.workspace.clone();
    response_workspace.error_message = None;

    // Run the container build in the background so long builds aren't tied to the HTTP request
    let working_dir = state.config.working_dir.clone();
    let mut workspace_for_build = claim.workspace.clone();
    let harness_policy = state.settings.get_harness_versions().await;

    tokio::spawn(async move {
        let result = crate::workspace::build_container_workspace(
            &mut workspace_for_build,
            distro,
            force_rebuild,
            &working_dir,
            &harness_policy,
        )
        .await;

        if let Err(e) = result {
            if workspace_for_build.status == WorkspaceStatus::Building {
                workspace_for_build.status = WorkspaceStatus::Error;
                workspace_for_build.error_message = Some(e.to_string());
            }
            tracing::error!(
                workspace = %workspace_for_build.name,
                error = %e,
                "Failed to build container workspace"
            );
        }

        if let Err(error) = claim.settle(workspace_for_build).await {
            tracing::error!(%error, "Failed to persist workspace build result");
        }
    });

    Ok(Json(response_workspace.into()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Command Execution
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ExecCommandRequest {
    /// The shell command to execute
    pub command: String,
    /// Optional working directory (relative to workspace or absolute within workspace)
    pub cwd: Option<String>,
    /// Timeout in seconds (default: 300, max: 600)
    pub timeout_secs: Option<u64>,
    /// Environment variables to set for the command
    pub env: Option<HashMap<String, String>>,
}

#[derive(Debug, Serialize)]
pub struct ExecCommandResponse {
    /// Exit code of the command
    pub exit_code: i32,
    /// Standard output
    pub stdout: String,
    /// Standard error
    pub stderr: String,
    /// Whether the command timed out
    pub timed_out: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Debug Types (for template development)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct WorkspaceDebugInfo {
    /// Workspace ID
    pub id: Uuid,
    /// Workspace name
    pub name: String,
    /// Current status
    pub status: WorkspaceStatus,
    /// Container/workspace path
    pub path: String,
    /// Whether the container directory exists
    pub path_exists: bool,
    /// Size of the container in bytes (if applicable)
    pub size_bytes: Option<u64>,
    /// Key directories that exist in the container
    pub directories: Vec<DirectoryInfo>,
    /// Whether bash is available
    pub has_bash: bool,
    /// Whether the init script file exists in the container
    pub init_script_exists: bool,
    /// Last modification time of init script
    pub init_script_modified: Option<String>,
    /// Distro information
    pub distro: Option<String>,
    /// Any error message from last build
    pub last_error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct DirectoryInfo {
    /// Directory path
    pub path: String,
    /// Whether it exists
    pub exists: bool,
    /// Approximate file count (if exists)
    pub file_count: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct InitLogResponse {
    /// Whether the log file exists
    pub exists: bool,
    /// Log content (last N lines)
    pub content: String,
    /// Total lines in log
    pub total_lines: Option<u32>,
    /// Log file path inside container
    pub log_path: String,
}

#[derive(Debug, Serialize)]
pub struct RerunInitResponse {
    /// Whether the rerun was successful
    pub success: bool,
    /// Exit code from the script
    pub exit_code: i32,
    /// Standard output from the script
    pub stdout: String,
    /// Standard error from the script
    pub stderr: String,
    /// Execution time in seconds
    pub duration_secs: f64,
}

/// POST /api/workspaces/:id/exec - Execute a command in a workspace.
///
/// Runs through [`crate::workspace_exec::WorkspaceExec`], the same execution
/// layer missions use: the workspace `env_vars` are merged into the command
/// environment, and container workspaces reuse a running container leader via
/// nsenter instead of failing with "Directory tree … is currently busy" when
/// a mission already holds the container. This is also how assistant gateways
/// (Hermes `workspace_bash`) get mission-equivalent workspace access without
/// copying secrets into their own service environment.
async fn exec_workspace_command(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
    Json(req): Json<ExecCommandRequest>,
) -> Result<Json<ExecCommandResponse>, (StatusCode, String)> {
    exec_workspace_command_inner(state, id, req, false).await
}

// A distinct route fails closed on older Core versions (404), rather than
// silently ignoring a new JSON flag and executing setup against the host root.
async fn exec_rooted_workspace_command(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
    Json(req): Json<ExecCommandRequest>,
) -> Result<Json<ExecCommandResponse>, (StatusCode, String)> {
    exec_workspace_command_inner(state, id, req, true).await
}

async fn exec_workspace_command_inner(
    state: Arc<super::routes::AppState>,
    id: Uuid,
    req: ExecCommandRequest,
    require_target_root: bool,
) -> Result<Json<ExecCommandResponse>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, id).await?;

    // For container workspaces, ensure container is ready
    if workspace.workspace_type == WorkspaceType::Container
        && workspace.status != WorkspaceStatus::Ready
    {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "Container workspace is not ready (status: {:?}). Build it first.",
                workspace.status
            ),
        ));
    }

    if req.command.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "Command is empty".to_string()));
    }

    let timeout_secs = req.timeout_secs.unwrap_or(300).clamp(1, 600);

    // Determine working directory
    let cwd = resolve_workspace_exec_cwd(&workspace, req.cwd.as_deref())?;

    // `timeout(1)` enforces the limit inside the workspace: TERM at expiry,
    // escalating to KILL 5s later (`-k`) so TERM-ignoring commands still die
    // in the right place — on outer-timeout the dropped future only kills the
    // direct child (the timeout/nsenter wrapper), which would orphan the
    // command itself. The outer tokio timeout is a belt-and-braces guard for
    // exec-layer hangs (e.g. a wedged container boot).
    let exec = crate::workspace_exec::WorkspaceExec::new(workspace);
    let exec = if require_target_root {
        exec.with_required_target_root()
            .map_err(|error| (StatusCode::CONFLICT, error.to_string()))?
    } else {
        exec
    };
    let args = vec![
        "-k".to_string(),
        "5".to_string(),
        timeout_secs.to_string(),
        "/bin/bash".to_string(),
        "-lc".to_string(),
        req.command.clone(),
    ];
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(timeout_secs + 15),
        exec.output(&cwd, "timeout", &args, req.env.clone().unwrap_or_default()),
    )
    .await;

    match result {
        Ok(Ok(output)) => {
            let exit_code = output.status.code().unwrap_or(-1);
            Ok(Json(ExecCommandResponse {
                exit_code,
                stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                // timeout(1) exits 124 when the command was killed.
                timed_out: exit_code == 124,
            }))
        }
        Ok(Err(e)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Command execution failed: {}", e),
        )),
        Err(_) => Ok(Json(ExecCommandResponse {
            exit_code: -1,
            stdout: String::new(),
            stderr: format!(
                "Command timed out after {} seconds (exec layer)",
                timeout_secs
            ),
            timed_out: true,
        })),
    }
}

fn resolve_workspace_exec_cwd(
    workspace: &Workspace,
    requested: Option<&str>,
) -> Result<PathBuf, (StatusCode, String)> {
    let Some(requested) = requested else {
        return Ok(workspace.path.clone());
    };
    let requested = Path::new(requested);

    if workspace.workspace_type != WorkspaceType::Container {
        return Ok(if requested.is_absolute() {
            requested.to_path_buf()
        } else {
            workspace.path.join(requested)
        });
    }

    // WorkspaceExec accepts host paths and translates them back into guest
    // paths. Hermes/users naturally supply guest-absolute paths such as
    // `/workspace/verity/base`; map those under the container root first.
    let resolved = if requested.is_absolute() {
        if requested.starts_with(&workspace.path) {
            requested.to_path_buf()
        } else {
            workspace
                .path
                .join(requested.strip_prefix("/").unwrap_or(requested))
        }
    } else {
        workspace.path.join(requested)
    };

    if !path_within(&workspace.path, &resolved) {
        return Err((
            StatusCode::BAD_REQUEST,
            "Working directory must remain inside the workspace".to_string(),
        ));
    }
    Ok(resolved)
}

// ─────────────────────────────────────────────────────────────────────────────
// Debug Endpoints (for template development)
// ─────────────────────────────────────────────────────────────────────────────

/// GET /api/workspaces/:id/debug - Get debug information about a workspace container.
///
/// Returns detailed information about the container state useful for debugging
/// init script issues: directory structure, file existence, sizes, etc.
async fn get_workspace_debug(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<WorkspaceDebugInfo>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, id).await?;

    let path = &workspace.path;
    let path_exists = path.exists();

    // Calculate container size (only for container workspaces)
    // Use du -sk (kilobytes) for portability, then convert to bytes
    let size_bytes = if workspace.workspace_type == WorkspaceType::Container && path_exists {
        let output = tokio::process::Command::new("du")
            .args(["-sk", &path.to_string_lossy()])
            .output()
            .await
            .ok();

        output.and_then(|o| {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let kb = stdout.split_whitespace().next()?.parse::<u64>().ok()?;
            Some(kb * 1024) // Convert KB to bytes
        })
    } else {
        None
    };

    // Check key directories
    let key_dirs = ["bin", "usr", "etc", "var", "var/log", "root", "tmp"];
    let directories: Vec<DirectoryInfo> = key_dirs
        .iter()
        .map(|dir| {
            let full_path = path.join(dir);
            let exists = full_path.exists() && full_path.is_dir();
            let file_count = if exists {
                std::fs::read_dir(&full_path)
                    .map(|entries| entries.count() as u32)
                    .ok()
            } else {
                None
            };
            DirectoryInfo {
                path: dir.to_string(),
                exists,
                file_count,
            }
        })
        .collect();

    // Check for bash
    let has_bash = path.join("bin/bash").exists() || path.join("usr/bin/bash").exists();

    // Check for init script
    let init_script_path = path.join("sandboxed-init.sh");
    let init_script_exists = init_script_path.exists();
    let init_script_modified = if init_script_exists {
        std::fs::metadata(&init_script_path)
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|t| {
                chrono::DateTime::<chrono::Utc>::from(t)
                    .format("%Y-%m-%d %H:%M:%S UTC")
                    .to_string()
            })
    } else {
        None
    };

    Ok(Json(WorkspaceDebugInfo {
        id: workspace.id,
        name: workspace.name.clone(),
        status: workspace.status,
        path: path.to_string_lossy().to_string(),
        path_exists,
        size_bytes,
        directories,
        has_bash,
        init_script_exists,
        init_script_modified,
        distro: workspace.distro.clone(),
        last_error: workspace.error_message.clone(),
    }))
}

/// GET /api/workspaces/:id/init-log - Get the init script log from inside the container.
///
/// Reads /var/log/sandboxed-init.log from inside the container to show what
/// the init script has logged. Useful for debugging template issues.
async fn get_init_log(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<InitLogResponse>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, id).await?;

    let log_path = "/var/log/sandboxed-init.log";
    let host_log_path = workspace.path.join("var/log/sandboxed-init.log");

    // During debootstrap, the container filesystem doesn't exist yet so
    // var/log/sandboxed-init.log won't be there. Check the build log sibling
    // file that debootstrap streams output to.
    let effective_log_path = if host_log_path.exists() {
        host_log_path
    } else {
        let build_log = crate::nspawn::build_log_path_for(&workspace.path);
        if build_log.exists() {
            build_log
        } else {
            return Ok(Json(InitLogResponse {
                exists: false,
                content: String::new(),
                total_lines: None,
                log_path: log_path.to_string(),
            }));
        }
    };

    // Read the log file
    let content = tokio::fs::read_to_string(&effective_log_path)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to read log file: {}", e),
            )
        })?;

    let lines: Vec<&str> = content.lines().collect();
    let total_lines = lines.len() as u32;

    // Return last 500 lines max
    let start = if lines.len() > 500 {
        lines.len() - 500
    } else {
        0
    };
    let truncated_content = lines[start..].join("\n");

    Ok(Json(InitLogResponse {
        exists: true,
        content: truncated_content,
        total_lines: Some(total_lines),
        log_path: log_path.to_string(),
    }))
}

/// POST /api/workspaces/:id/rerun-init - Re-run the init script without rebuilding the container.
///
/// This allows template developers to iterate on their init script without
/// waiting for a full container rebuild. The container must already exist.
async fn rerun_init_script(
    State(state): State<Arc<super::routes::AppState>>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<RerunInitResponse>, (StatusCode, String)> {
    let mut workspace = require_workspace(&state.workspaces, id).await?;

    // Only works for container workspaces
    if workspace.workspace_type != WorkspaceType::Container {
        return Err((
            StatusCode::BAD_REQUEST,
            "Rerun init only works for container workspaces".to_string(),
        ));
    }

    // Container must exist (at least have basic structure)
    if !workspace.path.join("bin").exists() {
        return Err((
            StatusCode::BAD_REQUEST,
            "Container doesn't exist yet. Build it first.".to_string(),
        ));
    }

    // Must have an init script configured
    let init_script = workspace.init_script.clone().unwrap_or_default();
    if init_script.trim().is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "No init script configured for this workspace".to_string(),
        ));
    }

    let claim = state
        .workspaces
        .try_claim_workspace_build(id, None)
        .await
        .map_err(|conflict| (conflict.status, conflict.message))?;
    workspace = claim.workspace.clone();

    let settle_claim_error =
        |claim: workspace::BuildClaimGuard, workspace: Workspace, error: String| async move {
            let mut failed = workspace;
            failed.status = WorkspaceStatus::Error;
            failed.error_message = Some(error.clone());
            if let Err(settle_error) = claim.settle(failed).await {
                tracing::error!(%settle_error, "Failed to settle workspace init error");
            }
            Err((StatusCode::INTERNAL_SERVER_ERROR, error))
        };

    let script_path = workspace.path.join("sandboxed-init.sh");
    if let Err(error) = tokio::fs::write(&script_path, &init_script).await {
        return settle_claim_error(
            claim,
            workspace,
            format!("Failed to write init script: {}", error),
        )
        .await;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o755);
        if let Err(error) = tokio::fs::set_permissions(&script_path, perms).await {
            let _ = tokio::fs::remove_file(&script_path).await;
            return settle_claim_error(
                claim,
                workspace,
                format!("Failed to set script permissions: {}", error),
            )
            .await;
        }
    }

    // Run the init script
    let start_time = std::time::Instant::now();

    let shell = if workspace.path.join("bin/bash").exists() {
        "/bin/bash"
    } else {
        "/bin/sh"
    };

    let config = crate::nspawn::NspawnConfig {
        env: workspace.env_vars.clone(),
        ..Default::default()
    };

    let command = vec![shell.to_string(), "/sandboxed-init.sh".to_string()];
    let output_result =
        crate::nspawn::execute_in_container(&workspace.path, &command, &config).await;

    let duration_secs = start_time.elapsed().as_secs_f64();

    // Clean up the script file regardless of success/failure
    let _ = tokio::fs::remove_file(&script_path).await;

    // Handle container execution failure - revert status and return error
    let output = match output_result {
        Ok(out) => out,
        Err(e) => {
            // Revert workspace status to Error so it's not stuck in Building
            workspace.status = WorkspaceStatus::Error;
            workspace.error_message = Some(format!("Failed to execute init script: {}", e));
            let _ = claim.settle(workspace).await;
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to execute init script: {}", e),
            ));
        }
    };

    let exit_code = output.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let success = output.status.success();

    // Update workspace status
    if success {
        workspace.status = WorkspaceStatus::Ready;
        workspace.error_message = None;
    } else {
        workspace.status = WorkspaceStatus::Error;
        let mut error_msg = String::new();
        if !stderr.trim().is_empty() {
            error_msg.push_str(stderr.trim());
        }
        if !stdout.trim().is_empty() {
            if !error_msg.is_empty() {
                error_msg.push_str(" | ");
            }
            error_msg.push_str(stdout.trim());
        }
        if error_msg.is_empty() {
            error_msg = format!("Init script failed with exit code {}", exit_code);
        }
        workspace.error_message = Some(format!("Init script failed: {}", error_msg));
    }

    if let Err(error) = claim.settle(workspace).await {
        tracing::error!(%error, "Failed to persist workspace init result");
    }

    Ok(Json(RerunInitResponse {
        success,
        exit_code,
        stdout,
        stderr,
        duration_secs,
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// Memory Monitoring
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct WorkspaceMemoryStats {
    pub workspace_id: Uuid,
    pub workspace_name: String,
    pub workspace_type: String,
    pub memory_current_bytes: Option<u64>,
    pub memory_peak_bytes: Option<u64>,
    pub memory_limit_bytes: Option<u64>,
    pub memory_available_bytes: Option<u64>,
    pub memory_current_mb: Option<f64>,
    pub memory_peak_mb: Option<f64>,
    pub memory_limit_mb: Option<String>,
    pub container_name: Option<String>,
    pub error: Option<String>,
}

/// Get memory statistics for a specific workspace container.
async fn get_workspace_memory(
    AxumPath(id): AxumPath<Uuid>,
    State(state): State<Arc<super::routes::AppState>>,
) -> Result<Json<WorkspaceMemoryStats>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, id).await?;

    let stats = get_container_memory_stats(&workspace).await;
    Ok(Json(stats))
}

/// Get memory statistics for all workspace containers.
async fn get_all_workspaces_memory(
    State(state): State<Arc<super::routes::AppState>>,
) -> Json<Vec<WorkspaceMemoryStats>> {
    use futures::stream::{self, StreamExt};

    let workspaces = state.workspaces.list().await;
    let stat_futs: Vec<_> = workspaces
        .into_iter()
        .map(|workspace| async move { get_container_memory_stats(&workspace).await })
        .collect();
    let all_stats = stream::iter(stat_futs)
        .buffered(8)
        .collect::<Vec<_>>()
        .await;

    Json(all_stats)
}

/// Get memory stats for a workspace container using systemd cgroup data.
async fn get_container_memory_stats(workspace: &Workspace) -> WorkspaceMemoryStats {
    let workspace_type_str = match workspace.workspace_type {
        WorkspaceType::Host => "host",
        WorkspaceType::Container => "container",
    };

    // For host workspaces, return N/A
    if workspace.workspace_type != WorkspaceType::Container {
        return WorkspaceMemoryStats {
            workspace_id: workspace.id,
            workspace_name: workspace.name.clone(),
            workspace_type: workspace_type_str.to_string(),
            memory_current_bytes: None,
            memory_peak_bytes: None,
            memory_limit_bytes: None,
            memory_available_bytes: None,
            memory_current_mb: None,
            memory_peak_mb: None,
            memory_limit_mb: Some("N/A (host)".to_string()),
            container_name: None,
            error: None,
        };
    }

    // Aggregate over every transient scope this workspace owns: the boot
    // scope (`sandboxed-mission-<machine>.scope`) plus per-exec attach
    // scopes (`sandboxed-exec-<machine>-*.scope`). The previous
    // `machine-*.scope` lookup never matched: containers boot with
    // `--register=no`, so machined scopes don't exist.
    let exec = crate::workspace_exec::WorkspaceExec::new(workspace.clone());
    let container_name = exec.mission_scope_match_token();
    let units = match list_workspace_scope_units(workspace).await {
        Ok(units) => units,
        Err(e) => {
            return WorkspaceMemoryStats {
                workspace_id: workspace.id,
                workspace_name: workspace.name.clone(),
                workspace_type: workspace_type_str.to_string(),
                memory_current_bytes: None,
                memory_peak_bytes: None,
                memory_limit_bytes: None,
                memory_available_bytes: None,
                memory_current_mb: None,
                memory_peak_mb: None,
                memory_limit_mb: None,
                container_name,
                error: Some(format!("Could not query mission scopes: {e}")),
            };
        }
    };

    if units.is_empty() {
        return WorkspaceMemoryStats {
            workspace_id: workspace.id,
            workspace_name: workspace.name.clone(),
            workspace_type: workspace_type_str.to_string(),
            memory_current_bytes: None,
            memory_peak_bytes: None,
            memory_limit_bytes: None,
            memory_available_bytes: None,
            memory_current_mb: None,
            memory_peak_mb: None,
            memory_limit_mb: None,
            container_name,
            error: Some(
                "No active mission scopes (container not running, or memory caps disabled)"
                    .to_string(),
            ),
        };
    }

    let mut memory_current: Option<u64> = None;
    let mut memory_peak: Option<u64> = None;
    let mut memory_limit: Option<u64> = None;
    let mut memory_available: Option<u64> = None;
    let mut read_ok = false;
    let mut last_error: Option<String> = None;

    use futures::StreamExt;
    let output_futs: Vec<_> = units
        .iter()
        .map(|unit| async move {
            let output = tokio::process::Command::new("systemctl")
                .args([
                    "show",
                    unit,
                    "-p",
                    "MemoryCurrent,MemoryPeak,MemoryMax,MemoryAvailable",
                ])
                .output()
                .await;
            (unit, output)
        })
        .collect();
    let outputs = futures::stream::iter(output_futs)
        .buffered(8)
        .collect::<Vec<_>>()
        .await;

    for (unit, output) in outputs {
        match &output {
            Ok(o) if !o.status.success() => {
                last_error = Some(format!(
                    "systemctl show {unit} failed: {}",
                    String::from_utf8_lossy(&o.stderr).trim()
                ));
            }
            Err(e) => {
                last_error = Some(format!("systemctl show {unit} errored: {e}"));
            }
            _ => {}
        }
        if let Ok(output) = output {
            if output.status.success() {
                read_ok = true;
                let stdout = String::from_utf8_lossy(&output.stdout);
                let (cur, peak, max, avail, _) = parse_systemd_memory_stats(&stdout);
                if let Some(c) = cur {
                    memory_current = Some(memory_current.unwrap_or(0) + c);
                }
                if let Some(p) = peak {
                    memory_peak = Some(memory_peak.unwrap_or(0).max(p));
                }
                if let Some(m) = max.filter(|m| *m != u64::MAX) {
                    // Each scope is independently capped, so the workspace's
                    // ceiling is the sum across scopes — matching the summed
                    // `MemoryCurrent` numerator. Taking the min here would let
                    // summed usage exceed the displayed limit and peg the
                    // gauge at 100% while still climbing.
                    memory_limit = Some(memory_limit.unwrap_or(0) + m);
                }
                if let Some(a) = avail {
                    memory_available = Some(memory_available.unwrap_or(0) + a);
                }
            }
        }
    }

    WorkspaceMemoryStats {
        workspace_id: workspace.id,
        workspace_name: workspace.name.clone(),
        workspace_type: workspace_type_str.to_string(),
        memory_current_bytes: memory_current,
        memory_peak_bytes: memory_peak,
        memory_limit_bytes: memory_limit,
        memory_available_bytes: memory_available,
        memory_current_mb: memory_current.map(|b| b as f64 / 1024.0 / 1024.0),
        memory_peak_mb: memory_peak.map(|b| b as f64 / 1024.0 / 1024.0),
        memory_limit_mb: memory_limit
            .map(|b| format!("{:.2}", b as f64 / 1024.0 / 1024.0))
            .or(Some("unlimited".to_string())),
        container_name,
        // Scopes exist but not one `systemctl show` succeeded — surface it
        // instead of returning blank stats with no explanation.
        error: if read_ok {
            None
        } else {
            Some(last_error.unwrap_or_else(|| {
                "Found mission scopes but could not read their memory stats".to_string()
            }))
        },
    }
}

/// Every transient scope unit currently alive that belongs to this
/// workspace's container: the boot scope plus per-exec attach scopes.
///
/// `Ok(vec![])` means the query ran and the workspace genuinely has no live
/// scopes; `Err` means the `systemctl list-units` query itself failed, so
/// callers must not interpret the result as "no scopes" (the container may
/// still be running and capped).
pub(crate) async fn list_workspace_scope_units(
    workspace: &Workspace,
) -> Result<Vec<String>, String> {
    let exec = crate::workspace_exec::WorkspaceExec::new(workspace.clone());
    let Some(token) = exec.mission_scope_match_token() else {
        return Ok(Vec::new());
    };
    let output = tokio::process::Command::new("systemctl")
        .args([
            "list-units",
            "--plain",
            "--no-legend",
            "--all",
            "sandboxed-mission-*.scope",
            "sandboxed-exec-*.scope",
        ])
        .output()
        .await
        .map_err(|e| format!("failed to run systemctl list-units: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "systemctl list-units failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.split_whitespace().next())
        .filter(|unit| unit.contains(&token))
        .map(|s| s.to_string())
        .collect())
}

// ─────────────────────────────────────────────────────────────────────────────
// Live memory-cap adjustment
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct UpdateWorkspaceResourcesRequest {
    /// e.g. "24G", "infinity", "50%". `Some("")` clears the workspace
    /// override (falls back to the global MISSION_MEMORY_MAX default).
    pub memory_max: Option<String>,
    pub memory_high: Option<String>,
    pub memory_swap_max: Option<String>,
    /// `CPUWeight` (1..=10000, or "idle"). Relative CPU share of this mission's
    /// scopes under contention. `Some("")` clears the override.
    pub cpu_weight: Option<String>,
    /// `CPUQuota` (e.g. "400%" = 4 cores, or "infinity"). Hard per-mission CPU
    /// ceiling so one mission can't saturate the host. `Some("")` clears it.
    pub cpu_quota: Option<String>,
    /// Persist into the workspace env-var overrides (default true). When
    /// false the change is runtime-only: it survives until the scopes die.
    #[serde(default = "default_true")]
    pub persist: bool,
    /// Apply to currently-running scopes via `systemctl set-property
    /// --runtime` (default true).
    #[serde(default = "default_true")]
    pub apply_live: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Serialize)]
pub struct UpdateWorkspaceResourcesResponse {
    /// Units the new caps were applied to live (empty when none running).
    pub applied_units: Vec<String>,
    /// Running scopes whose live retune failed (e.g. `systemctl set-property`
    /// errored). Non-empty here means scopes exist but caps did not take live.
    pub failed_units: Vec<String>,
    pub persisted: bool,
    /// Effective caps after this call (override merged with global defaults).
    pub memory_max: Option<String>,
    pub memory_high: Option<String>,
    pub memory_swap_max: Option<String>,
    pub cpu_weight: Option<String>,
    pub cpu_quota: Option<String>,
}

/// Read-only resource-limit visibility.  This intentionally reports both the
/// effective values and whether each came from a workspace override or the
/// process environment, so operators can distinguish an unset limit from an
/// inherited one before changing a live mission.
#[derive(Debug, Serialize)]
pub struct WorkspaceResourcesResponse {
    pub workspace_id: Uuid,
    pub workspace_name: String,
    pub memory_max: Option<String>,
    pub memory_high: Option<String>,
    pub memory_swap_max: Option<String>,
    pub cpu_weight: Option<String>,
    pub cpu_quota: Option<String>,
    pub workspace_overrides: HashMap<String, String>,
    pub running_scope_units: Vec<String>,
    pub scope_list_error: Option<String>,
}

async fn get_workspace_resources(
    AxumPath(id): AxumPath<Uuid>,
    State(state): State<Arc<super::routes::AppState>>,
) -> Result<Json<WorkspaceResourcesResponse>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, id).await?;
    let caps = crate::workspace_exec::WorkspaceExec::new(workspace.clone()).mission_resource_caps();
    let workspace_overrides = workspace
        .env_vars
        .iter()
        .filter(|(key, _)| {
            matches!(
                key.as_str(),
                "MISSION_MEMORY_MAX"
                    | "MISSION_MEMORY_HIGH"
                    | "MISSION_MEMORY_SWAP_MAX"
                    | "MISSION_CPU_WEIGHT"
                    | "MISSION_CPU_QUOTA"
            )
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    let (running_scope_units, scope_list_error) = match list_workspace_scope_units(&workspace).await
    {
        Ok(units) => (units, None),
        Err(err) => {
            tracing::warn!(workspace = %workspace.name, %err, "resource visibility: scope listing failed");
            (Vec::new(), Some(err))
        }
    };
    Ok(Json(WorkspaceResourcesResponse {
        workspace_id: workspace.id,
        workspace_name: workspace.name,
        memory_max: caps.max,
        memory_high: caps.high,
        memory_swap_max: caps.swap_max,
        cpu_weight: caps.cpu_weight,
        cpu_quota: caps.cpu_quota,
        workspace_overrides,
        running_scope_units,
        scope_list_error,
    }))
}

/// Validate a systemd memory size: bytes, suffixed (K/M/G/T), percentage,
/// or "infinity".
fn valid_memory_size(value: &str) -> bool {
    let v = value.trim();
    if v.eq_ignore_ascii_case("infinity") {
        return true;
    }
    let v = v.strip_suffix('%').unwrap_or(v);
    let v = v
        .strip_suffix(['K', 'M', 'G', 'T', 'k', 'm', 'g', 't'])
        .unwrap_or(v);
    let mut seen_dot = false;
    let mut seen_digit = false;
    for c in v.chars() {
        match c {
            '0'..='9' => seen_digit = true,
            '.' if !seen_dot => seen_dot = true,
            _ => return false,
        }
    }
    seen_digit
}

/// Validate a systemd `CPUWeight`: integer 1..=10000, or "idle".
fn valid_cpu_weight(value: &str) -> bool {
    let v = value.trim();
    if v.eq_ignore_ascii_case("idle") {
        return true;
    }
    matches!(v.parse::<u32>(), Ok(n) if (1..=10000).contains(&n))
}

/// Validate a systemd `CPUQuota`: "infinity", or a percentage like "400%"
/// (>= 1%, optional decimals). "100%" == one core.
fn valid_cpu_quota(value: &str) -> bool {
    let v = value.trim();
    if v.eq_ignore_ascii_case("infinity") {
        return true;
    }
    let Some(num) = v.strip_suffix('%') else {
        return false;
    };
    // Rust's f64 parser accepts "inf"/"nan"; require a finite percentage so
    // "infinity%" and friends don't slip through.
    matches!(num.trim().parse::<f64>(), Ok(pct) if pct.is_finite() && pct >= 1.0)
}

/// POST /api/workspaces/:id/resources — adjust a workspace's memory caps.
///
/// This is the "boost" path: raise (or clear) one workspace's memory limits
/// without touching the global env file and without restarting anything.
/// Running scopes are retuned in place; the persisted override applies to
/// every scope the workspace boots afterwards.
async fn update_workspace_resources(
    AxumPath(id): AxumPath<Uuid>,
    State(state): State<Arc<super::routes::AppState>>,
    Json(req): Json<UpdateWorkspaceResourcesRequest>,
) -> Result<Json<UpdateWorkspaceResourcesResponse>, (StatusCode, String)> {
    let mut workspace = require_workspace(&state.workspaces, id).await?;

    let updates: [(&str, &Option<String>); 5] = [
        ("MISSION_MEMORY_MAX", &req.memory_max),
        ("MISSION_MEMORY_HIGH", &req.memory_high),
        ("MISSION_MEMORY_SWAP_MAX", &req.memory_swap_max),
        ("MISSION_CPU_WEIGHT", &req.cpu_weight),
        ("MISSION_CPU_QUOTA", &req.cpu_quota),
    ];

    for (key, value) in &updates {
        if let Some(v) = value {
            let v = v.trim();
            if v.is_empty() {
                continue;
            }
            let ok = match *key {
                "MISSION_CPU_WEIGHT" => valid_cpu_weight(v),
                "MISSION_CPU_QUOTA" => valid_cpu_quota(v),
                _ => valid_memory_size(v),
            };
            if !ok {
                let hint = match *key {
                    "MISSION_CPU_WEIGHT" => "expected an integer 1..=10000 or 'idle'",
                    "MISSION_CPU_QUOTA" => "expected a percentage like '400%' or 'infinity'",
                    _ => "expected bytes, K/M/G/T suffix, %, or 'infinity'",
                };
                return Err((
                    StatusCode::BAD_REQUEST,
                    format!("Invalid {key} value '{v}': {hint}"),
                ));
            }
        }
    }

    // Merge the requested values into the workspace env overrides (empty
    // string = clear the override).
    for (key, value) in &updates {
        if let Some(v) = value {
            let v = v.trim();
            if v.is_empty() {
                workspace.env_vars.remove(*key);
            } else {
                workspace.env_vars.insert(key.to_string(), v.to_string());
            }
        }
    }

    let exec = crate::workspace_exec::WorkspaceExec::new(workspace.clone());
    let caps = exec.mission_resource_caps();

    let mut applied_units = Vec::new();
    let mut failed_units = Vec::new();
    if req.apply_live {
        let units = match list_workspace_scope_units(&workspace).await {
            Ok(units) => units,
            Err(e) => {
                // Persist still applies (caps take at next boot); record why
                // the live retune found nothing instead of silently skipping.
                tracing::warn!(
                    "apply_live: could not list scopes for {}: {}",
                    workspace.name,
                    e
                );
                Vec::new()
            }
        };
        use futures::StreamExt;
        let caps_ref = &caps;
        let set_prop_futs: Vec<_> = units
            .into_iter()
            .map(|unit| async move {
                let mut cmd = tokio::process::Command::new("systemctl");
                cmd.args(["set-property", "--runtime", &unit]);
                cmd.arg(format!(
                    "MemoryMax={}",
                    caps_ref.max.as_deref().unwrap_or("infinity")
                ));
                cmd.arg(format!(
                    "MemoryHigh={}",
                    caps_ref.high.as_deref().unwrap_or("infinity")
                ));
                cmd.arg(format!(
                    "MemorySwapMax={}",
                    caps_ref.swap_max.as_deref().unwrap_or("infinity")
                ));
                // CPUWeight defaults back to systemd's 100 when cleared; CPUQuota
                // is reset with an empty value ("infinity" is not a valid
                // set-property argument for it).
                cmd.arg(format!(
                    "CPUWeight={}",
                    caps_ref.cpu_weight.as_deref().unwrap_or("100")
                ));
                cmd.arg(format!(
                    "CPUQuota={}",
                    caps_ref.cpu_quota.as_deref().unwrap_or("")
                ));
                (unit, cmd.output().await)
            })
            .collect();
        let results = futures::stream::iter(set_prop_futs)
            .buffered(8)
            .collect::<Vec<_>>()
            .await;

        for (unit, output) in results {
            match output {
                Ok(out) if out.status.success() => applied_units.push(unit),
                Ok(out) => {
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    tracing::warn!("set-property failed for {}: {}", unit, stderr.trim());
                    failed_units.push(unit);
                }
                Err(e) => {
                    tracing::warn!("set-property spawn failed for {}: {}", unit, e);
                    failed_units.push(unit);
                }
            }
        }
    }

    if req.persist {
        let updates_owned: Vec<(String, String)> = updates
            .iter()
            .filter_map(|(k, v)| {
                v.as_ref()
                    .map(|val| ((*k).to_string(), val.trim().to_string()))
            })
            .collect();
        state
            .workspaces
            .update_with(id, move |ws| {
                for (key, val) in updates_owned {
                    if val.is_empty() {
                        ws.env_vars.remove(&key);
                    } else {
                        ws.env_vars.insert(key, val);
                    }
                }
                Ok(())
            })
            .await
            .map_err(|conflict| (conflict.status, conflict.message))?;
    }

    tracing::info!(
        "Workspace {} resource caps updated: max={:?} high={:?} swap_max={:?} cpu_weight={:?} cpu_quota={:?} (live: {} unit(s), persisted: {})",
        workspace.name,
        caps.max,
        caps.high,
        caps.swap_max,
        caps.cpu_weight,
        caps.cpu_quota,
        applied_units.len(),
        req.persist
    );

    Ok(Json(UpdateWorkspaceResourcesResponse {
        applied_units,
        failed_units,
        persisted: req.persist,
        memory_max: caps.max,
        memory_high: caps.high,
        memory_swap_max: caps.swap_max,
        cpu_weight: caps.cpu_weight,
        cpu_quota: caps.cpu_quota,
    }))
}

/// Parse systemd cgroup memory statistics from `systemctl show` output.
type MemoryStats = (
    Option<u64>,
    Option<u64>,
    Option<u64>,
    Option<u64>,
    Option<String>,
);

fn parse_systemd_memory_stats(stdout: &str) -> MemoryStats {
    let mut memory_current = None;
    let mut memory_peak = None;
    let mut memory_max = None;
    let mut memory_available = None;

    for line in stdout.lines() {
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "MemoryCurrent" => {
                    memory_current = value.parse::<u64>().ok();
                }
                "MemoryPeak" => {
                    memory_peak = value.parse::<u64>().ok();
                }
                "MemoryMax" => {
                    if value == "infinity" {
                        memory_max = Some(u64::MAX);
                    } else {
                        memory_max = value.parse::<u64>().ok();
                    }
                }
                "MemoryAvailable" => {
                    memory_available = value.parse::<u64>().ok();
                }
                _ => {}
            }
        }
    }

    (
        memory_current,
        memory_peak,
        memory_max,
        memory_available,
        None,
    )
}

/// Check if a backend can run in a workspace.
/// GET /api/workspaces/:id/backends/:backend_id/preflight
async fn check_backend_preflight(
    AxumPath((workspace_id, backend_id)): AxumPath<(Uuid, String)>,
    State(state): State<Arc<super::routes::AppState>>,
) -> Result<Json<super::mission_runner::BackendPreflightResult>, (StatusCode, String)> {
    let workspace = require_workspace(&state.workspaces, workspace_id).await?;

    let cli_path = if matches!(
        backend_id.as_str(),
        "claudecode" | "codex" | "antigravity" | "vibe"
    ) {
        state
            .backend_configs
            .get(&backend_id)
            .await
            .and_then(|config| {
                config
                    .settings
                    .get("cli_path")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
    } else {
        None
    };

    let result = super::mission_runner::check_backend_prerequisites(
        &workspace,
        &backend_id,
        cli_path.as_deref(),
    )
    .await;

    Ok(Json(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use tempfile::TempDir;

    #[test]
    fn valid_memory_size_accepts_systemd_forms() {
        for v in [
            "512", "0", "100M", "1.5G", "2T", "50%", "infinity", "INFINITY",
        ] {
            assert!(valid_memory_size(v), "should accept {v}");
        }
    }

    #[test]
    fn valid_memory_size_rejects_f64_quirks_systemd_does_not_accept() {
        // These all parse as f64 but systemd rejects them; accepting one and
        // persisting it would break every future container boot.
        for v in [
            "1e10", "inf", "nan", "+5", "-5", "1.2.3", "", ".", "0x10", " ",
        ] {
            assert!(!valid_memory_size(v), "should reject {v:?}");
        }
    }

    #[test]
    fn valid_cpu_weight_matches_systemd_range() {
        for v in ["1", "100", "10000", "idle", "IDLE"] {
            assert!(valid_cpu_weight(v), "should accept {v}");
        }
        for v in ["0", "10001", "", "100%", "-1", "1.5", "abc"] {
            assert!(!valid_cpu_weight(v), "should reject {v:?}");
        }
    }

    #[test]
    fn valid_cpu_quota_matches_systemd_forms() {
        for v in ["400%", "100%", "1%", "12.5%", "infinity"] {
            assert!(valid_cpu_quota(v), "should accept {v}");
        }
        for v in ["400", "0%", "0.5%", "", "%", "-100%", "infinity%"] {
            assert!(!valid_cpu_quota(v), "should reject {v:?}");
        }
    }

    #[test]
    fn test_path_within_rejects_parent_traversal() {
        let base = Path::new("/tmp/working_dir");
        // Even if the literal path doesn't exist, the .. components should be rejected
        assert!(!path_within(base, Path::new("/tmp/working_dir/../etc")));
        assert!(!path_within(
            base,
            Path::new("/tmp/working_dir/../../etc/passwd")
        ));
        assert!(!path_within(
            base,
            Path::new("/tmp/working_dir/subdir/../../../etc")
        ));
    }

    #[test]
    fn test_path_within_rejects_relative_traversal() {
        let base = Path::new("/tmp/working_dir");
        // Relative paths with .. should be rejected
        assert!(!path_within(base, Path::new("../etc")));
        assert!(!path_within(base, Path::new("subdir/../../etc")));
    }

    #[test]
    fn test_path_within_allows_valid_subpaths() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create a subdirectory
        let sub = base.join("subdir");
        std::fs::create_dir(&sub).unwrap();

        // Valid paths within base
        assert!(path_within(base, &sub));
        assert!(path_within(base, &base.join("subdir/file.txt")));
        assert!(path_within(base, &base.join("newdir/newfile.txt")));
    }

    #[test]
    fn test_path_within_rejects_symlink_escape() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create a subdirectory and symlink pointing outside
        let sub = base.join("subdir");
        std::fs::create_dir(&sub).unwrap();

        let outside = TempDir::new().unwrap();
        let symlink_path = base.join("escape");

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(outside.path(), &symlink_path).unwrap();
            // A path through the symlink should be rejected
            assert!(!path_within(base, &symlink_path.join("file.txt")));
        }
    }

    #[test]
    fn test_validate_workspace_name_valid() {
        assert!(validate_workspace_name("my-workspace").is_ok());
        assert!(validate_workspace_name("workspace_1").is_ok());
        assert!(validate_workspace_name("test123").is_ok());
    }

    #[test]
    fn test_validate_workspace_name_rejects_traversal() {
        assert!(validate_workspace_name("..").is_err());
        assert!(validate_workspace_name("../etc").is_err());
        assert!(validate_workspace_name("name/../etc").is_err());
        assert!(validate_workspace_name("name/subdir").is_err());
        assert!(validate_workspace_name("name\\subdir").is_err());
    }

    #[test]
    fn test_validate_workspace_name_rejects_hidden() {
        assert!(validate_workspace_name(".hidden").is_err());
        assert!(validate_workspace_name(".").is_err());
    }

    #[test]
    fn test_validate_workspace_name_rejects_empty() {
        assert!(validate_workspace_name("").is_err());
    }

    #[test]
    fn container_exec_cwd_maps_guest_absolute_path_under_workspace_root() {
        let root = TempDir::new().unwrap();
        let workspace = Workspace::new_container("verity".to_string(), root.path().to_path_buf());

        let cwd = resolve_workspace_exec_cwd(&workspace, Some("/workspace/verity/base"))
            .expect("guest path should map into the container root");

        assert_eq!(cwd, root.path().join("workspace/verity/base"));
    }

    #[test]
    fn container_exec_cwd_accepts_host_path_inside_workspace() {
        let root = TempDir::new().unwrap();
        let workspace = Workspace::new_container("verity".to_string(), root.path().to_path_buf());
        let host_path = root.path().join("workspace/verity/base");

        let cwd = resolve_workspace_exec_cwd(&workspace, host_path.to_str())
            .expect("host path inside the workspace should remain unchanged");

        assert_eq!(cwd, host_path);
    }

    #[test]
    fn container_exec_cwd_rejects_relative_escape() {
        let root = TempDir::new().unwrap();
        let workspace = Workspace::new_container("verity".to_string(), root.path().to_path_buf());

        let error = resolve_workspace_exec_cwd(&workspace, Some("../../etc"))
            .expect_err("relative traversal must not leave the workspace");

        assert_eq!(error.0, StatusCode::BAD_REQUEST);
    }

    async fn test_state(path: &Path) -> Arc<super::super::routes::AppState> {
        let config = crate::config::Config::new(path.to_path_buf());
        let root_agent: crate::agents::AgentRef =
            Arc::new(crate::agents::OpenCodeAgent::new(config.clone()));
        let mcp = Arc::new(crate::mcp::McpRegistry::new(path).await);
        let workspaces = Arc::new(workspace::WorkspaceStore::new(path.to_path_buf()).await);
        let library = Arc::new(tokio::sync::RwLock::new(None));
        let control = crate::api::control::ControlHub::new(
            config.clone(),
            root_agent.clone(),
            mcp.clone(),
            workspaces.clone(),
            library.clone(),
            None,
        );
        Arc::new(super::super::routes::AppState {
            config,
            root_agent,
            mcp,
            workspaces,
            library,
            control,
            tasks: Default::default(),
            opencode_connections: Arc::new(
                crate::opencode_config::OpenCodeStore::new(path.join("connections.json")).await,
            ),
            opencode_agents_cache: Default::default(),
            ai_providers: Arc::new(
                crate::ai_providers::AIProviderStore::new(path.join("providers.json")).await,
            ),
            pending_oauth: Default::default(),
            pending_github_oauth: Default::default(),
            pending_github_integration: Default::default(),
            github_connection: Arc::new(
                crate::github_connection::GithubConnectionStore::new(path.join("github.json"))
                    .await,
            ),
            secrets: None,
            console_pool: Arc::new(crate::api::console::SessionPool::new()),
            settings: Arc::new(crate::settings::SettingsStore::new(path).await),
            backend_registry: Arc::new(tokio::sync::RwLock::new(
                crate::backend::registry::BackendRegistry::new("opencode"),
            )),
            backend_configs: Arc::new(
                crate::backend_config::BackendConfigStore::new(path.join("backends.json"), vec![])
                    .await,
            ),
            model_catalog: Default::default(),
            health_tracker: Arc::new(crate::provider_health::ProviderHealthTracker::new()),
            chain_store: Arc::new(
                crate::provider_health::ModelChainStore::new(path.join("chains.json")).await,
            ),
            http_client: reqwest::Client::new(),
            proxy_secret: "test".into(),
            proxy_api_keys: Arc::new(
                crate::api::proxy_keys::ProxyApiKeyStore::new(path.join("keys.json")).await,
            ),
            deferred_requests: Arc::new(
                crate::api::deferred_proxy::DeferredRequestStore::new(path.join("requests.json"))
                    .await,
            ),
            telegram_bridge: Arc::new(crate::api::telegram::TelegramBridge::new()),
            fido_hub: Arc::new(crate::api::fido::FidoSigningHub::new()),
            control_metrics: Arc::new(crate::api::control_metrics::ControlMetrics::new()),
            provider_usage_cache: crate::api::provider_usage_cache::ProviderUsageCache::new(),
            codex_usage: crate::api::codex_usage::CodexUsageStore::new(),
            fleet: Arc::new(crate::remote_node::FleetMonitor::new()),
            validation: Arc::new(
                crate::api::validation::ValidationStore::open(path.join("validation.db")).unwrap(),
            ),
            projects: Arc::new(
                crate::api::projects_store::ProjectsStore::open(path.join("projects.db")).unwrap(),
            ),
            attention_snapshot: Default::default(),
            managed: Default::default(),
        })
    }

    #[tokio::test]
    async fn concurrent_build_workspace_admits_exactly_one_and_rejects_second() {
        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let path = root.path().join(".sandboxed-sh/containers/race");
        for dir in ["bin", "usr", "etc"] {
            std::fs::create_dir_all(path.join(dir)).unwrap();
        }
        std::fs::write(
            path.join("etc/os-release"),
            "ID=ubuntu\nVERSION_CODENAME=noble\n",
        )
        .unwrap();
        let container = Workspace::new_container("race".into(), path);
        let id = state.workspaces.add(container).await.unwrap();
        let (first, second) = tokio::join!(
            build_workspace(State(Arc::clone(&state)), AxumPath(id), None),
            build_workspace(State(Arc::clone(&state)), AxumPath(id), None),
        );
        let admitted = usize::from(first.is_ok()) + usize::from(second.is_ok());
        assert_eq!(admitted, 1);
        let rejected = first.err().or_else(|| second.err()).unwrap();
        assert_eq!(rejected.0, StatusCode::CONFLICT);
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while state.workspaces.get(id).await.unwrap().status == WorkspaceStatus::Building {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        let retry = build_workspace(State(Arc::clone(&state)), AxumPath(id), None)
            .await
            .unwrap();
        assert_eq!(retry.0.config["build_generation"].as_u64(), Some(2));
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while state.workspaces.get(id).await.unwrap().status == WorkspaceStatus::Building {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn build_claim_guard_recovers_after_panic_and_fences_stale_generation() {
        let root = TempDir::new().unwrap();
        let store = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let container = Workspace::new_container(
            "panic-recovery".into(),
            root.path().join(".sandboxed-sh/containers/panic-recovery"),
        );
        let id = store.add(container).await.unwrap();
        let panicked = tokio::spawn({
            let store = Arc::clone(&store);
            async move {
                let claim = store.try_claim_workspace_build(id, None).await.unwrap();
                assert_eq!(claim.generation(), 1);
                panic!("simulated build task panic");
            }
        })
        .await;
        assert!(panicked.is_err());
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while store.get(id).await.unwrap().status == WorkspaceStatus::Building {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(store.get(id).await.unwrap().status, WorkspaceStatus::Error);

        let second = store.try_claim_workspace_build(id, None).await.unwrap();
        assert_eq!(second.generation(), 2);
        let mut stale = second.workspace.clone();
        stale.status = WorkspaceStatus::Ready;
        store.settle_for_generation(&stale, 1).await.unwrap();
        assert_eq!(
            store.get(id).await.unwrap().status,
            WorkspaceStatus::Building
        );
        let mut ready = second.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        second.settle(ready).await.unwrap();
        assert_eq!(store.get(id).await.unwrap().status, WorkspaceStatus::Ready);
    }

    #[tokio::test]
    async fn cross_handle_flock_contention_returns_conflict() {
        use fs2::FileExt;

        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let path = root.path().join(".sandboxed-sh/containers/locked");
        let id = state
            .workspaces
            .add(Workspace::new_container("locked".into(), path.clone()))
            .await
            .unwrap();
        let lock_path = workspace::workspace_build_lock_path(&path);
        std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
        let external = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .unwrap();
        external.try_lock_exclusive().unwrap();

        let err = build_workspace(State(Arc::clone(&state)), AxumPath(id), None)
            .await
            .unwrap_err();
        assert_eq!(err.0, StatusCode::CONFLICT);
        assert_ne!(
            state.workspaces.get(id).await.unwrap().status,
            WorkspaceStatus::Building
        );
        drop(external);
        let claim = state
            .workspaces
            .try_claim_workspace_build(id, None)
            .await
            .unwrap();
        let mut ready = claim.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        claim.settle(ready).await.unwrap();
    }

    #[tokio::test]
    async fn restart_scan_ignores_build_artifacts_and_cleans_unlocked_build_lock_on_delete() {
        let root = TempDir::new().unwrap();
        let containers_dir = root.path().join(".sandboxed-sh/containers");
        std::fs::create_dir_all(containers_dir.join(".hidden")).unwrap();
        std::fs::create_dir_all(containers_dir.join("legacy.build")).unwrap();
        std::fs::create_dir_all(containers_dir.join("stale.lock")).unwrap();

        let store = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let ws_path = containers_dir.join("clean-container");
        let id = store
            .add(Workspace::new_container(
                "clean-container".into(),
                ws_path.clone(),
            ))
            .await
            .unwrap();

        let claim = store
            .try_claim_workspace_build(id, Some("ubuntu-noble".into()))
            .await
            .unwrap();
        let lock_path = workspace::workspace_build_lock_path(&ws_path);
        assert!(lock_path.is_file());
        assert!(!containers_dir.join("clean-container.build").exists());

        let mut ready = claim.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        claim.settle(ready).await.unwrap();

        let restarted = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let names: Vec<String> = restarted.list().await.into_iter().map(|w| w.name).collect();
        assert_eq!(
            names,
            vec!["clean-container".to_string(), "host".to_string()]
        );

        assert!(restarted.delete(id).await);
        assert!(!lock_path.exists());
    }

    #[tokio::test]
    async fn restart_recovery_preserves_live_build_lock_and_fails_interrupted_build() {
        let root = TempDir::new().unwrap();
        let store = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let live_id = store
            .add(Workspace::new_container(
                "live-build".into(),
                root.path().join(".sandboxed-sh/containers/live-build"),
            ))
            .await
            .unwrap();
        let dead_id = store
            .add(Workspace::new_container(
                "dead-build".into(),
                root.path().join(".sandboxed-sh/containers/dead-build"),
            ))
            .await
            .unwrap();

        let live_claim = store
            .try_claim_workspace_build(live_id, None)
            .await
            .unwrap();

        let dead_claim = store
            .try_claim_workspace_build(dead_id, None)
            .await
            .unwrap();
        let dead_lock = workspace::workspace_build_lock_path(&dead_claim.workspace.path);
        assert!(dead_lock.exists());

        let storage_path = root.path().join(".sandboxed-sh/workspaces.json");
        let mut persisted: Vec<Workspace> =
            serde_json::from_slice(&std::fs::read(&storage_path).unwrap()).unwrap();
        let mut ready = dead_claim.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        dead_claim.settle(ready).await.unwrap();

        for ws in &mut persisted {
            if ws.id == dead_id {
                ws.status = WorkspaceStatus::Building;
                ws.error_message = None;
            }
        }
        std::fs::write(
            &storage_path,
            serde_json::to_vec_pretty(&persisted).unwrap(),
        )
        .unwrap();

        let recovered = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        assert_eq!(
            recovered.get(live_id).await.unwrap().status,
            WorkspaceStatus::Building
        );
        let dead = recovered.get(dead_id).await.unwrap();
        assert_eq!(dead.status, WorkspaceStatus::Error);
        assert_eq!(
            dead.error_message.as_deref(),
            Some("Workspace build interrupted by restart")
        );

        let mut live_ready = live_claim.workspace.clone();
        live_ready.status = WorkspaceStatus::Ready;
        live_claim.settle(live_ready).await.unwrap();
    }

    #[tokio::test]
    async fn put_during_build_rejects_build_defining_edits_and_settle_preserves_concurrent_fields()
    {
        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let ws_path = root.path().join(".sandboxed-sh/containers/concurrent-put");
        let mut container = Workspace::new_container("concurrent-put".into(), ws_path);
        container.distro = Some("ubuntu-noble".into());
        let id = state.workspaces.add(container).await.unwrap();

        let claim = state
            .workspaces
            .try_claim_workspace_build(id, None)
            .await
            .unwrap();

        let distro_conflict = update_workspace(
            State(Arc::clone(&state)),
            AxumPath(id),
            Json(UpdateWorkspaceRequest {
                workspace_type: None,
                path: None,
                name: None,
                skills: None,
                plugins: None,
                template: None,
                distro: Some("debian-bookworm".into()),
                env_vars: None,
                init_script: None,
                init_scripts: None,
                shared_network: None,
                tailscale_mode: None,
                mcps: None,
                mcps_replace_defaults: None,
                config_profile: None,
                config: None,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(distro_conflict.0, StatusCode::CONFLICT);

        let type_conflict = update_workspace(
            State(Arc::clone(&state)),
            AxumPath(id),
            Json(UpdateWorkspaceRequest {
                workspace_type: Some(WorkspaceType::Host),
                path: None,
                name: None,
                skills: None,
                plugins: None,
                template: None,
                distro: None,
                env_vars: None,
                init_script: None,
                init_scripts: None,
                shared_network: None,
                tailscale_mode: None,
                mcps: None,
                mcps_replace_defaults: None,
                config_profile: None,
                config: None,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(type_conflict.0, StatusCode::CONFLICT);

        let path_conflict = update_workspace(
            State(Arc::clone(&state)),
            AxumPath(id),
            Json(UpdateWorkspaceRequest {
                workspace_type: None,
                path: Some(root.path().join(".sandboxed-sh/containers/other-path")),
                name: None,
                skills: None,
                plugins: None,
                template: None,
                distro: None,
                env_vars: None,
                init_script: None,
                init_scripts: None,
                shared_network: None,
                tailscale_mode: None,
                mcps: None,
                mcps_replace_defaults: None,
                config_profile: None,
                config: None,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(path_conflict.0, StatusCode::CONFLICT);

        let mut env_vars = HashMap::new();
        env_vars.insert("FOO".into(), "bar".into());
        let updated = update_workspace(
            State(Arc::clone(&state)),
            AxumPath(id),
            Json(UpdateWorkspaceRequest {
                workspace_type: None,
                path: None,
                name: Some("renamed-during-build".into()),
                skills: Some(vec!["ops".into()]),
                plugins: Some(vec!["plugin-a".into()]),
                template: None,
                distro: None,
                env_vars: Some(env_vars.clone()),
                init_script: Some("echo updated".into()),
                init_scripts: Some(vec!["frag-a".into()]),
                shared_network: Some(false),
                tailscale_mode: Some(TailscaleMode::ExitNode),
                mcps: Some(vec!["mcp-a".into()]),
                mcps_replace_defaults: Some(false),
                config_profile: Some("custom-profile".into()),
                config: Some(serde_json::json!({ "custom_key": 42, "build_generation": 999 })),
            }),
        )
        .await
        .unwrap()
        .0;

        assert_eq!(updated.status, WorkspaceStatus::Building);
        assert_eq!(updated.distro.as_deref(), Some("ubuntu-noble"));
        assert_eq!(updated.name, "renamed-during-build");
        assert_eq!(updated.config["build_generation"].as_u64(), Some(1));
        assert_eq!(updated.config["custom_key"].as_i64(), Some(42));

        let mut built = claim.workspace.clone();
        built.status = WorkspaceStatus::Ready;
        built.distro = Some("ubuntu-noble".into());
        claim.settle(built).await.unwrap();

        let settled = state.workspaces.get(id).await.unwrap();
        assert_eq!(settled.status, WorkspaceStatus::Ready);
        assert_eq!(settled.name, "renamed-during-build");
        assert_eq!(settled.skills, vec!["ops".to_string()]);
        assert_eq!(settled.plugins, vec!["plugin-a".to_string()]);
        assert_eq!(settled.env_vars, env_vars);
        assert_eq!(settled.init_script.as_deref(), Some("echo updated"));
        assert_eq!(settled.init_scripts, vec!["frag-a".to_string()]);
        assert_eq!(settled.shared_network, Some(false));
        assert_eq!(settled.tailscale_mode, Some(TailscaleMode::ExitNode));
        assert_eq!(settled.mcps, vec!["mcp-a".to_string()]);
        assert!(!settled.mcps_replace_defaults);
        assert_eq!(settled.config_profile.as_deref(), Some("custom-profile"));
        assert_eq!(settled.config["custom_key"].as_i64(), Some(42));
        assert_eq!(settled.distro.as_deref(), Some("ubuntu-noble"));
    }

    #[tokio::test]
    async fn cross_store_json_locking_and_settle_failure_do_not_corrupt_or_double_drop() {
        let root = TempDir::new().unwrap();
        let store_a = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let store_b = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);

        let ws_a = Workspace::new_container(
            "store-a".into(),
            root.path().join(".sandboxed-sh/containers/store-a"),
        );
        let ws_b = Workspace::new_container(
            "store-b".into(),
            root.path().join(".sandboxed-sh/containers/store-b"),
        );
        let (id_a, id_b) = tokio::join!(store_a.add(ws_a), store_b.add(ws_b));
        let (id_a, id_b) = (id_a.unwrap(), id_b.unwrap());

        let reloaded = workspace::WorkspaceStore::new(root.path().to_path_buf()).await;
        assert!(reloaded.get(id_a).await.is_some());
        assert!(reloaded.get(id_b).await.is_some());

        let claim = store_a
            .try_claim_workspace_build(id_a, Some("ubuntu-noble".into()))
            .await
            .unwrap();
        let storage_path = root.path().join(".sandboxed-sh/workspaces.json");
        let saved_bytes = std::fs::read(&storage_path).unwrap();
        std::fs::remove_file(&storage_path).unwrap();
        std::fs::create_dir_all(&storage_path).unwrap();

        let mut ready = claim.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        let settle_err = claim.settle(ready).await;
        assert!(settle_err.is_err());

        std::fs::remove_dir_all(&storage_path).unwrap();
        std::fs::write(&storage_path, &saved_bytes).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let after_failed_settle = store_a.get(id_a).await.unwrap();
        assert_eq!(after_failed_settle.status, WorkspaceStatus::Building);
        assert_ne!(
            after_failed_settle.error_message.as_deref(),
            Some("Workspace build aborted before completion")
        );
    }

    #[tokio::test]
    async fn flock_contention_returns_immediate_conflict_without_waiting_on_storage_lock() {
        use fs2::FileExt;

        let root = TempDir::new().unwrap();
        let store = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let ws_path = root.path().join(".sandboxed-sh/containers/contended");
        let id = store
            .add(Workspace::new_container(
                "contended".into(),
                ws_path.clone(),
            ))
            .await
            .unwrap();

        let build_lock_path = workspace::workspace_build_lock_path(&ws_path);
        std::fs::create_dir_all(build_lock_path.parent().unwrap()).unwrap();
        let held_build_lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&build_lock_path)
            .unwrap();
        held_build_lock.try_lock_exclusive().unwrap();

        let storage_lock_path = root.path().join(".sandboxed-sh/workspaces.json.lock");
        let held_storage_lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&storage_lock_path)
            .unwrap();
        held_storage_lock.try_lock_exclusive().unwrap();

        let Err(err) = tokio::time::timeout(
            std::time::Duration::from_millis(250),
            store.try_claim_workspace_build(id, None),
        )
        .await
        .expect("try-flock contention must fail fast without waiting on storage lock") else {
            panic!("expected conflict when build lock is held");
        };
        assert_eq!(err.status, StatusCode::CONFLICT);

        drop(held_storage_lock);
        drop(held_build_lock);
    }

    #[tokio::test]
    async fn cancelling_try_claim_workspace_build_mid_claim_settles_abort_and_allows_retry() {
        use fs2::FileExt;

        let root = TempDir::new().unwrap();
        let store = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let ws_path = root.path().join(".sandboxed-sh/containers/cancel-claim");
        let id = store
            .add(Workspace::new_container(
                "cancel-claim".into(),
                ws_path.clone(),
            ))
            .await
            .unwrap();

        let storage_lock_path = root.path().join(".sandboxed-sh/workspaces.json.lock");
        let held_storage_lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&storage_lock_path)
            .unwrap();
        held_storage_lock.try_lock_exclusive().unwrap();

        let build_lock_path = workspace::workspace_build_lock_path(&ws_path);
        let claim_store = Arc::clone(&store);
        let mut claim_fut = Box::pin(async move {
            claim_store
                .try_claim_workspace_build(id, Some("ubuntu-noble".into()))
                .await
        });

        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                assert!(
                    tokio::time::timeout(std::time::Duration::from_millis(5), &mut claim_fut)
                        .await
                        .is_err()
                );
                if let Ok(probe) = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&build_lock_path)
                {
                    if probe.try_lock_exclusive().is_err() {
                        break;
                    }
                }
            }
        })
        .await
        .expect("claim must acquire build lock while blocked on storage lock");

        drop(claim_fut);
        drop(held_storage_lock);

        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let in_mem = store.get(id).await.unwrap();
                let probe = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&build_lock_path)
                    .unwrap();
                let lock_free = probe.try_lock_exclusive().is_ok();
                if in_mem.status == WorkspaceStatus::Error
                    && in_mem.config["build_generation"].as_u64() == Some(1)
                    && lock_free
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("cancelled claim must settle abort and release build lock");

        let storage_path = root.path().join(".sandboxed-sh/workspaces.json");
        let persisted: Vec<Workspace> =
            serde_json::from_slice(&std::fs::read(&storage_path).unwrap()).unwrap();
        let disk_ws = persisted.into_iter().find(|w| w.id == id).unwrap();
        assert_eq!(disk_ws.status, WorkspaceStatus::Error);
        assert_eq!(
            disk_ws.error_message.as_deref(),
            Some("Workspace build aborted before completion")
        );
        assert_eq!(disk_ws.config["build_generation"].as_u64(), Some(1));

        let next_claim = store
            .try_claim_workspace_build(id, Some("debian-bookworm".into()))
            .await
            .unwrap();
        assert_eq!(next_claim.generation(), 2);
        let mut ready = next_claim.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        next_claim.settle(ready).await.unwrap();
        assert_eq!(store.get(id).await.unwrap().status, WorkspaceStatus::Ready);
    }

    #[tokio::test]
    async fn update_workspace_resources_propagates_persistence_error_instead_of_reporting_persisted(
    ) {
        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let id = state
            .workspaces
            .add(Workspace::new_container(
                "resource-persist-fail".into(),
                root.path()
                    .join(".sandboxed-sh/containers/resource-persist-fail"),
            ))
            .await
            .unwrap();

        let storage_path = root.path().join(".sandboxed-sh/workspaces.json");
        let saved = std::fs::read(&storage_path).unwrap();
        std::fs::remove_file(&storage_path).unwrap();
        std::fs::create_dir_all(&storage_path).unwrap();

        let err = update_workspace_resources(
            AxumPath(id),
            State(Arc::clone(&state)),
            Json(UpdateWorkspaceResourcesRequest {
                memory_max: Some("8G".into()),
                memory_high: None,
                memory_swap_max: None,
                cpu_weight: None,
                cpu_quota: None,
                persist: true,
                apply_live: false,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.0, StatusCode::INTERNAL_SERVER_ERROR);
        assert!(!state
            .workspaces
            .get(id)
            .await
            .unwrap()
            .env_vars
            .contains_key("MISSION_MEMORY_MAX"));

        std::fs::remove_dir_all(&storage_path).unwrap();
        std::fs::write(&storage_path, saved).unwrap();

        let ok = update_workspace_resources(
            AxumPath(id),
            State(Arc::clone(&state)),
            Json(UpdateWorkspaceResourcesRequest {
                memory_max: Some("8G".into()),
                memory_high: None,
                memory_swap_max: None,
                cpu_weight: None,
                cpu_quota: None,
                persist: true,
                apply_live: false,
            }),
        )
        .await
        .unwrap()
        .0;
        assert!(ok.persisted);
        assert_eq!(
            state
                .workspaces
                .get(id)
                .await
                .unwrap()
                .env_vars
                .get("MISSION_MEMORY_MAX")
                .map(String::as_str),
            Some("8G")
        );
    }

    #[tokio::test]
    async fn create_workspace_propagates_storage_failure_and_does_not_register_workspace() {
        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let storage_path = root.path().join(".sandboxed-sh/workspaces.json");
        let saved = std::fs::read(&storage_path).unwrap();
        std::fs::remove_file(&storage_path).unwrap();
        std::fs::create_dir_all(&storage_path).unwrap();

        let store_err = state
            .workspaces
            .add(Workspace::new_container(
                "direct-add-fail".into(),
                root.path().join(".sandboxed-sh/containers/direct-add-fail"),
            ))
            .await
            .unwrap_err();
        assert_ne!(store_err.kind(), std::io::ErrorKind::NotFound);

        let err = create_workspace(
            State(Arc::clone(&state)),
            Json(CreateWorkspaceRequest {
                name: "unpersisted-ws".into(),
                workspace_type: WorkspaceType::Container,
                path: None,
                skills: Vec::new(),
                plugins: Vec::new(),
                template: None,
                distro: Some("ubuntu-noble".into()),
                env_vars: None,
                init_script: None,
                shared_network: None,
                tailscale_mode: None,
                mcps: Vec::new(),
                mcps_replace_defaults: true,
                config_profile: None,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.0, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(state.workspaces.list().await.len(), 1);
        assert!(
            std::fs::read_dir(root.path().join(".sandboxed-sh/mission-workspace-roots"))
                .map(|mut entries| entries.next().is_none())
                .unwrap_or(true)
        );

        std::fs::remove_dir_all(&storage_path).unwrap();
        std::fs::write(&storage_path, saved).unwrap();

        let created = create_workspace(
            State(Arc::clone(&state)),
            Json(CreateWorkspaceRequest {
                name: "persisted-ws".into(),
                workspace_type: WorkspaceType::Container,
                path: None,
                skills: Vec::new(),
                plugins: Vec::new(),
                template: None,
                distro: Some("ubuntu-noble".into()),
                env_vars: None,
                init_script: None,
                shared_network: None,
                tailscale_mode: None,
                mcps: Vec::new(),
                mcps_replace_defaults: true,
                config_profile: None,
            }),
        )
        .await
        .unwrap()
        .0;
        assert!(state.workspaces.get(created.id).await.is_some());
    }

    #[tokio::test]
    async fn cross_handle_stale_cached_building_consults_lock_and_disk_after_other_handle_settles()
    {
        let root = TempDir::new().unwrap();
        let store_a = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        let ws_path = root.path().join(".sandboxed-sh/containers/stale-building");
        let id = store_a
            .add(Workspace::new_container(
                "stale-building".into(),
                ws_path.clone(),
            ))
            .await
            .unwrap();

        let claim_a = store_a
            .try_claim_workspace_build(id, Some("ubuntu-noble".into()))
            .await
            .unwrap();
        assert_eq!(claim_a.generation(), 1);

        let store_b = Arc::new(workspace::WorkspaceStore::new(root.path().to_path_buf()).await);
        assert_eq!(
            store_b.get(id).await.unwrap().status,
            WorkspaceStatus::Building
        );
        let Err(while_active) = store_b.try_claim_workspace_build(id, None).await else {
            panic!("expected conflict while build lock is held");
        };
        assert_eq!(while_active.status, StatusCode::CONFLICT);

        let mut ready_a = claim_a.workspace.clone();
        ready_a.status = WorkspaceStatus::Ready;
        claim_a.settle(ready_a).await.unwrap();

        assert_eq!(
            store_b.get(id).await.unwrap().status,
            WorkspaceStatus::Building
        );

        let claim_b = store_b
            .try_claim_workspace_build(id, Some("debian-bookworm".into()))
            .await
            .unwrap();
        assert_eq!(claim_b.generation(), 2);
        assert_eq!(claim_b.workspace.distro.as_deref(), Some("debian-bookworm"));

        let mut ready_b = claim_b.workspace.clone();
        ready_b.status = WorkspaceStatus::Ready;
        claim_b.settle(ready_b).await.unwrap();
        assert_eq!(
            store_b.get(id).await.unwrap().status,
            WorkspaceStatus::Ready
        );
    }

    #[tokio::test]
    async fn claim_workspace_build_preserves_prior_error_for_build_input_and_clears_response_and_store(
    ) {
        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let ws_path = root.path().join(".sandboxed-sh/containers/claim-error");
        let mut container = Workspace::new_container("claim-error".into(), ws_path);
        container.distro = Some("ubuntu-noble".into());
        container.status = WorkspaceStatus::Error;
        container.error_message = Some("Init script failed: exit code 1".into());
        let id = state.workspaces.add(container).await.unwrap();

        let claim = state
            .workspaces
            .try_claim_workspace_build(id, None)
            .await
            .unwrap();
        assert_eq!(
            claim.workspace.error_message.as_deref(),
            Some("Init script failed: exit code 1")
        );
        let in_mem = state.workspaces.get(id).await.unwrap();
        assert_eq!(in_mem.status, WorkspaceStatus::Building);
        assert!(in_mem.error_message.is_none());
        let storage_path = root.path().join(".sandboxed-sh/workspaces.json");
        let persisted: Vec<Workspace> =
            serde_json::from_slice(&std::fs::read(&storage_path).unwrap()).unwrap();
        let disk_ws = persisted.into_iter().find(|w| w.id == id).unwrap();
        assert_eq!(disk_ws.status, WorkspaceStatus::Building);
        assert!(disk_ws.error_message.is_none());

        let mut ready = claim.workspace.clone();
        ready.status = WorkspaceStatus::Ready;
        ready.error_message = None;
        claim.settle(ready).await.unwrap();

        let mut errored = state.workspaces.get(id).await.unwrap();
        errored.status = WorkspaceStatus::Error;
        errored.error_message = Some("Init script failed: second".into());
        assert!(state.workspaces.update(errored).await);

        let response = build_workspace(State(Arc::clone(&state)), AxumPath(id), None)
            .await
            .unwrap()
            .0;
        assert_eq!(response.status, WorkspaceStatus::Building);
        assert!(response.error_message.is_none());
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while state.workspaces.get(id).await.unwrap().status == WorkspaceStatus::Building {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn build_workspace_preserves_prior_error_for_force_rebuild_while_clearing_persisted_error(
    ) {
        use std::os::unix::fs::PermissionsExt;

        if std::env::var_os("ORB_FAILED_INIT_REGRESSION_CHILD").is_none() {
            let root = TempDir::new().unwrap();
            let fake_bin = root.path().join("fake-bin");
            std::fs::create_dir_all(&fake_bin).unwrap();
            for (name, body) in [
                ("systemd-nspawn", "#!/bin/sh\nexit 0\n"),
                ("debootstrap", "#!/bin/sh\nexit 1\n"),
            ] {
                let bin_path = fake_bin.join(name);
                std::fs::write(&bin_path, body).unwrap();
                std::fs::set_permissions(&bin_path, std::fs::Permissions::from_mode(0o755))
                    .unwrap();
            }
            let joined_path = match std::env::var_os("PATH") {
                Some(existing) => {
                    let mut paths = vec![fake_bin];
                    paths.extend(std::env::split_paths(&existing));
                    std::env::join_paths(paths).unwrap()
                }
                None => fake_bin.into_os_string(),
            };
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "api::workspaces::tests::build_workspace_preserves_prior_error_for_force_rebuild_while_clearing_persisted_error",
                    "--nocapture",
                ])
                .env("ORB_FAILED_INIT_REGRESSION_CHILD", "1")
                .env("PATH", joined_path)
                .env("WORKING_DIR", root.path())
                .env("SANDBOXED_SH_ALLOW_CONTAINER_FALLBACK", "0")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "stdout: {}\nstderr: {}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let root_path = PathBuf::from(std::env::var_os("WORKING_DIR").unwrap());
        let state = test_state(&root_path).await;
        let ws_path = root_path.join(".sandboxed-sh/containers/failed-init");
        for dir in ["bin", "usr", "etc", "var"] {
            std::fs::create_dir_all(ws_path.join(dir)).unwrap();
        }
        std::fs::write(
            ws_path.join("etc/os-release"),
            "ID=ubuntu\nVERSION_CODENAME=noble\n",
        )
        .unwrap();
        let stale_marker = ws_path.join("var/stale-failed-init-marker");
        std::fs::write(&stale_marker, "stale").unwrap();

        let mut container = Workspace::new_container("failed-init".into(), ws_path.clone());
        container.distro = Some("ubuntu-noble".into());
        container.status = WorkspaceStatus::Error;
        container.error_message = Some("Init script failed: exit code 1".into());
        let id = state.workspaces.add(container).await.unwrap();

        let response = build_workspace(State(Arc::clone(&state)), AxumPath(id), None)
            .await
            .unwrap()
            .0;
        assert_eq!(response.status, WorkspaceStatus::Building);
        assert!(response.error_message.is_none());

        let in_mem = state.workspaces.get(id).await.unwrap();
        if in_mem.status == WorkspaceStatus::Building {
            assert!(in_mem.error_message.is_none());
        }

        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while state.workspaces.get(id).await.unwrap().status == WorkspaceStatus::Building {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        let settled = state.workspaces.get(id).await.unwrap();
        assert_eq!(settled.status, WorkspaceStatus::Error);
        assert!(!stale_marker.exists());
    }

    #[tokio::test]
    async fn rerun_init_script_write_failure_deterministically_settles_error_before_response() {
        let root = TempDir::new().unwrap();
        let state = test_state(root.path()).await;
        let ws_path = root
            .path()
            .join(".sandboxed-sh/containers/rerun-write-fail");
        std::fs::create_dir_all(ws_path.join("bin")).unwrap();
        std::fs::create_dir_all(ws_path.join("sandboxed-init.sh")).unwrap();

        let mut container = Workspace::new_container("rerun-write-fail".into(), ws_path.clone());
        container.status = WorkspaceStatus::Ready;
        container.init_script = Some("echo hello".into());
        let id = state.workspaces.add(container).await.unwrap();

        let err = rerun_init_script(State(Arc::clone(&state)), AxumPath(id))
            .await
            .unwrap_err();
        assert_eq!(err.0, StatusCode::INTERNAL_SERVER_ERROR);
        assert!(err.1.starts_with("Failed to write init script:"));

        let in_mem = state.workspaces.get(id).await.unwrap();
        assert_eq!(in_mem.status, WorkspaceStatus::Error);
        assert_eq!(in_mem.error_message.as_deref(), Some(err.1.as_str()));
        assert_eq!(in_mem.config["build_generation"].as_u64(), Some(1));

        let reloaded = workspace::WorkspaceStore::new(root.path().to_path_buf()).await;
        let on_disk = reloaded.get(id).await.unwrap();
        assert_eq!(on_disk.status, WorkspaceStatus::Error);
        assert_eq!(on_disk.error_message.as_deref(), Some(err.1.as_str()));

        let next_claim = state
            .workspaces
            .try_claim_workspace_build(id, None)
            .await
            .unwrap();
        assert_eq!(next_claim.generation(), 2);
        let mut recovered = next_claim.workspace.clone();
        recovered.status = WorkspaceStatus::Ready;
        recovered.error_message = None;
        next_claim.settle(recovered).await.unwrap();
    }
}
