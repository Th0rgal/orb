//! Skills library management API endpoints.
//!
//! Provides endpoints for managing the git-backed skills library:
//! - Git operations (`status`, `sync`, `force-sync`, `force-push`, `commit`, `push`)
//! - Skills CRUD, delivery preview, reference files, and git history

use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{delete, get, post, put},
    Json, Router,
};
use serde::Deserialize;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::library::{
    GitAuthor, LibraryHistoryEntry, LibraryStatus, LibraryStore, Skill, SkillSummary,
};
use crate::util::{internal_error, not_found_or_internal};
use crate::workspace::{self, WorkspaceType, DEFAULT_WORKSPACE_ID};

/// Shared library state.
pub type SharedLibrary = Arc<RwLock<Option<Arc<LibraryStore>>>>;

const LIBRARY_REMOTE_HEADER: &str = "x-sandboxed-library-remote";
const GIT_AUTHOR_NAME_HEADER: &str = "x-sandboxed-git-author-name";
const GIT_AUTHOR_EMAIL_HEADER: &str = "x-sandboxed-git-author-email";

fn extract_library_remote(headers: &HeaderMap) -> Option<String> {
    headers
        .get(LIBRARY_REMOTE_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string())
}

fn extract_git_author(headers: &HeaderMap) -> Option<GitAuthor> {
    let name = headers
        .get(GIT_AUTHOR_NAME_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let email = headers
        .get(GIT_AUTHOR_EMAIL_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    if name.is_some() || email.is_some() {
        Some(GitAuthor::new(name, email))
    } else {
        None
    }
}

fn is_default_host_workspace(workspace: &workspace::Workspace) -> bool {
    workspace.id == DEFAULT_WORKSPACE_ID && workspace.workspace_type == WorkspaceType::Host
}

async fn sync_all_workspaces(state: &super::routes::AppState, library: &LibraryStore) {
    let workspaces = state.workspaces.list().await;
    for workspace in workspaces {
        if is_default_host_workspace(&workspace) || !workspace.skills.is_empty() {
            if let Err(e) = workspace::sync_workspace_skills(&workspace, library).await {
                tracing::warn!(
                    workspace = %workspace.name,
                    error = %e,
                    "Failed to sync skills after library update"
                );
            }
        }
    }
}

async fn sync_skill_to_workspaces(
    state: &super::routes::AppState,
    library: &LibraryStore,
    skill_name: &str,
) {
    let workspaces = state.workspaces.list().await;
    for workspace in workspaces {
        if is_default_host_workspace(&workspace) || workspace.skills.iter().any(|s| s == skill_name)
        {
            if let Err(e) = workspace::sync_workspace_skills(&workspace, library).await {
                tracing::warn!(
                    workspace = %workspace.name,
                    skill = %skill_name,
                    error = %e,
                    "Failed to sync skill to workspace"
                );
            }
        }
    }
}

fn same_remote(a: &str, b: &str) -> bool {
    let norm = |r: &str| {
        r.trim()
            .trim_end_matches('/')
            .trim_end_matches(".git")
            .to_ascii_lowercase()
    };
    norm(a) == norm(b)
}

async fn ensure_library(
    state: &super::routes::AppState,
    headers: &HeaderMap,
) -> Result<Arc<LibraryStore>, (StatusCode, String)> {
    // The configured remote is the only Library: Core's git identity pushes
    // to it, so a different remote named per request is refused.
    let configured = state.settings.get_library_remote().await;
    let remote = match (extract_library_remote(headers), configured) {
        (Some(r), Some(c)) if !same_remote(&r, &c) => {
            return Err((
                StatusCode::FORBIDDEN,
                "This Core serves only its configured Library remote".to_string(),
            ))
        }
        (Some(r), None) => Some(r),
        (_, configured) => configured,
    };
    let remote = remote.ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "Library not configured. Set a Git repo in Settings.".to_string(),
        )
    })?;

    {
        let library_guard = state.library.read().await;
        if let Some(library) = library_guard.as_ref() {
            if library.remote() == remote {
                return Ok(Arc::clone(library));
            }
        }
    }

    let mut library_guard = state.library.write().await;
    if let Some(library) = library_guard.as_ref() {
        if library.remote() == remote {
            return Ok(Arc::clone(library));
        }
    }

    match LibraryStore::new(state.config.library_path.clone(), &remote).await {
        Ok(store) => {
            let store = Arc::new(store);
            *library_guard = Some(Arc::clone(&store));
            drop(library_guard);
            sync_all_workspaces(state, store.as_ref()).await;
            Ok(store)
        }
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to initialize library: {}", e),
        )),
    }
}

/// Create library routes.
pub fn routes() -> Router<Arc<super::routes::AppState>> {
    Router::new()
        // Git operations
        .route("/status", get(get_status))
        .route("/sync", post(sync_library))
        .route("/force-sync", post(force_sync_library))
        .route("/force-push", post(force_push_library))
        .route("/commit", post(commit_library))
        .route("/push", post(push_library))
        // Skills
        .route("/skill", get(list_skills))
        .route("/skill-delivery", get(skill_delivery_preview))
        .route("/skill/:name", get(get_skill))
        .route("/skill/:name", put(save_skill))
        .route("/skill/:name", delete(delete_skill))
        .route("/skill/:name/history", get(get_skill_history))
        .route("/skill/:name/history/:rev", get(get_skill_at))
        .route("/skill/:name/files/*path", get(get_skill_reference))
        .route("/skill/:name/files/*path", put(save_skill_reference))
        .route("/skill/:name/files/*path", delete(delete_skill_reference))
}

#[derive(Debug, Deserialize)]
pub struct CommitRequest {
    message: String,
}

#[derive(Debug, Deserialize)]
pub struct SaveContentRequest {
    content: String,
}

#[derive(Debug, Deserialize)]
struct SkillDeliveryQuery {
    workspace_id: Option<uuid::Uuid>,
    project: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Git Operations
// ─────────────────────────────────────────────────────────────────────────────

/// GET /api/library/status - Get git status of the library.
async fn get_status(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
) -> Result<Json<LibraryStatus>, (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library.status().await.map(Json).map_err(internal_error)
}

/// POST /api/library/sync - Pull latest changes from remote.
///
/// Returns 409 Conflict if history has diverged (e.g., after force push).
/// In that case, use /force-sync to reset to remote or /force-push to overwrite remote.
async fn sync_library(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;

    if let Err(e) = library.sync().await {
        let error_msg = e.to_string();
        if error_msg.starts_with("DIVERGED_HISTORY:") {
            let msg = error_msg
                .strip_prefix("DIVERGED_HISTORY: ")
                .unwrap_or(&error_msg);
            return Err((StatusCode::CONFLICT, format!("DIVERGED_HISTORY: {}", msg)));
        }
        return Err((StatusCode::INTERNAL_SERVER_ERROR, error_msg));
    }

    sync_all_workspaces(&state, library.as_ref()).await;

    Ok((StatusCode::OK, "Synced successfully".to_string()))
}

/// POST /api/library/force-sync - Force reset local branch to match remote.
async fn force_sync_library(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library.force_sync().await.map_err(internal_error)?;

    sync_all_workspaces(&state, library.as_ref()).await;

    Ok((
        StatusCode::OK,
        "Force synced successfully - local branch reset to remote".to_string(),
    ))
}

/// POST /api/library/force-push - Force push local changes to remote.
async fn force_push_library(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .force_push()
        .await
        .map(|_| {
            (
                StatusCode::OK,
                "Force pushed successfully - remote updated with local changes".to_string(),
            )
        })
        .map_err(internal_error)
}

/// POST /api/library/commit - Commit all changes.
async fn commit_library(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
    Json(req): Json<CommitRequest>,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    let author = extract_git_author(&headers);
    library
        .commit(&req.message, author.as_ref())
        .await
        .map(|_| (StatusCode::OK, "Committed successfully".to_string()))
        .map_err(internal_error)
}

/// POST /api/library/push - Push changes to remote.
async fn push_library(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .push()
        .await
        .map(|_| (StatusCode::OK, "Pushed successfully".to_string()))
        .map_err(internal_error)
}

// ─────────────────────────────────────────────────────────────────────────────
// Skills
// ─────────────────────────────────────────────────────────────────────────────

/// GET /api/library/skill-delivery?workspace_id=&project= - Read-only
/// preview of the Library skills a mission would receive, with reasons.
async fn skill_delivery_preview(
    State(state): State<Arc<super::routes::AppState>>,
    Query(query): Query<SkillDeliveryQuery>,
    headers: HeaderMap,
) -> Result<Json<workspace::skill_delivery::SkillDeliveryPlan>, (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    let workspace_id = query.workspace_id.unwrap_or(DEFAULT_WORKSPACE_ID);
    let ws = state
        .workspaces
        .get(workspace_id)
        .await
        .ok_or((StatusCode::NOT_FOUND, "Unknown workspace".to_string()))?;
    let project_skills = match query.project.as_deref().filter(|p| !p.is_empty()) {
        Some(slug) => state
            .projects
            .get_project(slug)
            .map_err(internal_error)?
            .map(|record| record.skills)
            .unwrap_or_default(),
        None => Vec::new(),
    };
    workspace::skill_delivery::resolve_for_workspace(
        &ws.skills,
        workspace::skill_delivery::is_default_host(&ws),
        &library,
        &project_skills,
    )
    .await
    .map(Json)
    .map_err(internal_error)
}

/// GET /api/library/skill - List all skills.
async fn list_skills(
    State(state): State<Arc<super::routes::AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<SkillSummary>>, (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .list_skills()
        .await
        .map(Json)
        .map_err(internal_error)
}

/// GET /api/library/skill/:name - Get a skill by name.
async fn get_skill(
    State(state): State<Arc<super::routes::AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Skill>, (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .get_skill(&name)
        .await
        .map(Json)
        .map_err(not_found_or_internal)
}

/// GET /api/library/skill/:name/history - Commits that changed the skill.
async fn get_skill_history(
    State(state): State<Arc<super::routes::AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<LibraryHistoryEntry>>, (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .skill_history(&name)
        .await
        .map(Json)
        .map_err(not_found_or_internal)
}

/// GET /api/library/skill/:name/history/:rev - SKILL.md at that commit.
async fn get_skill_at(
    State(state): State<Arc<super::routes::AppState>>,
    Path((name, rev)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<String, (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .skill_at(&name, &rev)
        .await
        .map_err(not_found_or_internal)
}

/// PUT /api/library/skill/:name - Save a skill.
async fn save_skill(
    State(state): State<Arc<super::routes::AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    Json(req): Json<SaveContentRequest>,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .save_skill(&name, &req.content)
        .await
        .map_err(internal_error)?;
    sync_skill_to_workspaces(&state, library.as_ref(), &name).await;
    Ok((StatusCode::OK, "Skill saved successfully".to_string()))
}

/// DELETE /api/library/skill/:name - Delete a skill.
async fn delete_skill(
    State(state): State<Arc<super::routes::AppState>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library.delete_skill(&name).await.map_err(internal_error)?;
    sync_skill_to_workspaces(&state, library.as_ref(), &name).await;
    Ok((StatusCode::OK, "Skill deleted successfully".to_string()))
}

/// GET /api/library/skill/:name/files/*path - Get a reference file.
async fn get_skill_reference(
    State(state): State<Arc<super::routes::AppState>>,
    Path((name, path)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .get_skill_reference(&name, &path)
        .await
        .map(|content| (StatusCode::OK, content))
        .map_err(not_found_or_internal)
}

/// PUT /api/library/skill/:name/files/*path - Save a reference file.
async fn save_skill_reference(
    State(state): State<Arc<super::routes::AppState>>,
    Path((name, path)): Path<(String, String)>,
    headers: HeaderMap,
    Json(req): Json<SaveContentRequest>,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .save_skill_reference(&name, &path, &req.content)
        .await
        .map_err(internal_error)?;
    sync_skill_to_workspaces(&state, library.as_ref(), &name).await;
    Ok((StatusCode::OK, "Reference saved successfully".to_string()))
}

/// DELETE /api/library/skill/:name/files/*path - Delete a reference file.
async fn delete_skill_reference(
    State(state): State<Arc<super::routes::AppState>>,
    Path((name, path)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<(StatusCode, String), (StatusCode, String)> {
    let library = ensure_library(&state, &headers).await?;
    library
        .delete_skill_reference(&name, &path)
        .await
        .map_err(|e| {
            if e.to_string().contains("not found") {
                (StatusCode::NOT_FOUND, e.to_string())
            } else if e.to_string().contains("Cannot delete SKILL.md") {
                (StatusCode::BAD_REQUEST, e.to_string())
            } else {
                (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
            }
        })?;
    sync_skill_to_workspaces(&state, library.as_ref(), &name).await;
    Ok((StatusCode::OK, "Reference deleted successfully".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn normalizes_remote_matching() {
        assert!(same_remote(
            "git@github.com:Th0rgal/sandboxed-library.git",
            "git@github.com:th0rgal/sandboxed-library/"
        ));
        assert!(!same_remote(
            "git@github.com:Th0rgal/sandboxed-library.git",
            "git@github.com:someone/other.git"
        ));
    }

    #[test]
    fn extracts_git_author_headers() {
        let mut headers = HeaderMap::new();
        assert!(extract_git_author(&headers).is_none());

        headers.insert(GIT_AUTHOR_NAME_HEADER, HeaderValue::from_static("Thomas"));
        headers.insert(
            GIT_AUTHOR_EMAIL_HEADER,
            HeaderValue::from_static("thomas@example.com"),
        );
        let author = extract_git_author(&headers).unwrap();
        assert_eq!(author.name.as_deref(), Some("Thomas"));
        assert_eq!(author.email.as_deref(), Some("thomas@example.com"));
    }
}
