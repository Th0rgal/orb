//! Project-scoped view of Hermes cron jobs.
//!
//! Hermes remains the scheduler and source of job state. This module owns only
//! the durable project <-> Hermes job-id binding and never writes a cron file.

// Handlers return the mapped axum `Response` as the error branch on purpose:
// the Hermes adapter decides the client-visible status once, at the boundary.
#![allow(clippy::result_large_err)]

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};

type AppState = super::routes::AppState;
use super::projects_store::ProjectsStore;

fn valid_slug(slug: &str) -> Result<(), Response> {
    if super::projects_overview::is_plain_key(slug) {
        Ok(())
    } else {
        Err((StatusCode::BAD_REQUEST, "invalid project slug").into_response())
    }
}

pub(super) async fn hermes(
    state: &AppState,
    method: reqwest::Method,
    suffix: &str,
    body: Option<Value>,
) -> Result<Value, Response> {
    let key = super::system::hermes_api_server_key(state)
        .await
        .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e).into_response())?;
    hermes_request(
        &state.http_client,
        &super::system::hermes_api_server_url(&state.config),
        &key,
        method,
        suffix,
        body,
    )
    .await
}

async fn hermes_request(
    client: &reqwest::Client,
    base: &str,
    key: &str,
    method: reqwest::Method,
    suffix: &str,
    body: Option<Value>,
) -> Result<Value, Response> {
    let mut request = client
        .request(method, format!("{base}{suffix}"))
        .bearer_auth(key);
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request
        .send()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "Hermes scheduler unavailable").into_response())?;
    let status = response.status();
    let text = response.text().await.map_err(|_| {
        (
            StatusCode::BAD_GATEWAY,
            "Could not read Hermes scheduler response",
        )
            .into_response()
    })?;
    if !status.is_success() {
        // Only the job API's explicit tombstone may be skipped by list. A generic
        // HTTP 404 can mean the adapter/route itself is unavailable.
        let deleted = status == reqwest::StatusCode::NOT_FOUND
            && serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_owned))
                .as_deref()
                == Some("Job not found");
        let mapped = if deleted {
            StatusCode::NOT_FOUND
        } else if status.is_server_error() {
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY)
        } else if status == reqwest::StatusCode::UNAUTHORIZED
            || status == reqwest::StatusCode::FORBIDDEN
            || status == reqwest::StatusCode::NOT_FOUND
        {
            StatusCode::BAD_GATEWAY
        } else {
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY)
        };
        return Err((
            mapped,
            format!(
                "Hermes scheduler returned {}: {}",
                status.as_u16(),
                text.chars().take(400).collect::<String>()
            ),
        )
            .into_response());
    }
    serde_json::from_str(&text).map_err(|_| {
        (
            StatusCode::BAD_GATEWAY,
            "Hermes scheduler returned invalid JSON",
        )
            .into_response()
    })
}

fn project_exists(store: &ProjectsStore, slug: &str) -> Result<(), Response> {
    valid_slug(slug)?;
    if slug == "default" {
        store
            .ensure_default_project()
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?;
    }
    match store.get_project(slug) {
        Ok(Some(_)) => Ok(()),
        Ok(None) => Err((StatusCode::NOT_FOUND, "project not found").into_response()),
        Err(e) => Err((StatusCode::INTERNAL_SERVER_ERROR, e).into_response()),
    }
}

pub(crate) fn sync_hermes_jobs_with_list(
    store: &ProjectsStore,
    jobs: &[Value],
    mission_projects: &std::collections::HashMap<String, String>,
) -> Result<usize, String> {
    let mut bound = 0;
    for job in jobs {
        let Some(id) = job
            .get("id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        if store.cron_owner(id)?.is_some() {
            continue;
        }
        let explicit_project = job
            .pointer("/controller/project")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .or_else(|| {
                job.get("deliver").and_then(Value::as_str).and_then(|d| {
                    d.split(',')
                        .map(str::trim)
                        .find_map(|part| part.strip_prefix("project:"))
                })
            });
        if let Some(proj_slug) = explicit_project {
            let canonical = super::projects_overview::canonicalize_project_slug(proj_slug);
            let target = if canonical.is_empty() {
                proj_slug.to_string()
            } else {
                canonical
            };
            if target == "default" {
                store.ensure_default_project()?;
                store.bind_project_cron("default", id)?;
                bound += 1;
                continue;
            }
            if let Some(project) = store.get_project(&target)? {
                let primary_id = super::project_controller::find_job(
                    jobs,
                    &super::projects_overview::project_tag_keys(&target),
                    project.controller_cron_id.as_deref(),
                )
                .and_then(|j| j.get("id").and_then(Value::as_str));
                if primary_id == Some(id) {
                    continue;
                }
                store.bind_project_cron(&target, id)?;
                bound += 1;
                continue;
            }
        }

        let mut origin_project: Option<String> = None;
        for ptr in ["/origin/session_id", "/origin/chat_id", "/session_id"] {
            let Some(sid) = job
                .pointer(ptr)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            else {
                continue;
            };
            if let Some(mission_id) = sid.strip_prefix("orb_") {
                if let Some(proj_slug) = mission_projects.get(mission_id) {
                    if proj_slug == "default" || store.get_project(proj_slug)?.is_some() {
                        origin_project = Some(proj_slug.clone());
                        break;
                    }
                }
            }
            if let Some(proj_slug) = store.project_for_session(sid)? {
                if proj_slug == "default" || store.get_project(&proj_slug)?.is_some() {
                    origin_project = Some(proj_slug);
                    break;
                }
            }
        }

        let target = origin_project.unwrap_or_else(|| "default".to_string());
        if target == "default" {
            store.ensure_default_project()?;
        }
        store.bind_project_cron(&target, id)?;
        bound += 1;
    }
    Ok(bound)
}

async fn collect_job_mission_projects(
    state: &AppState,
    jobs: &[Value],
) -> std::collections::HashMap<String, String> {
    let mut mission_projects = std::collections::HashMap::new();
    for job in jobs {
        for ptr in ["/origin/session_id", "/origin/chat_id", "/session_id"] {
            if let Some(mission_id) = job
                .pointer(ptr)
                .and_then(Value::as_str)
                .and_then(|s| s.trim().strip_prefix("orb_"))
            {
                if let Ok(uuid) = uuid::Uuid::parse_str(mission_id) {
                    if let Ok(Some((_, m))) = state.control.find_mission_store_owner(uuid).await {
                        if let Some(proj) = m.project.project.filter(|p| !p.trim().is_empty()) {
                            mission_projects.insert(mission_id.to_string(), proj);
                            break;
                        }
                    }
                }
            }
        }
    }
    mission_projects
}

pub(crate) async fn sync_hermes_jobs(state: &AppState) -> Result<usize, String> {
    let mut jobs = match hermes(
        state,
        reqwest::Method::GET,
        "/api/jobs?include_disabled=true",
        None,
    )
    .await
    {
        Ok(value) => value
            .get("jobs")
            .and_then(Value::as_array)
            .cloned()
            .or_else(|| value.as_array().cloned())
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    if jobs.is_empty() {
        jobs = super::project_controller::hermes_home()
            .map(|h| super::project_controller::load_jobs(&h))
            .unwrap_or_default();
    }
    if jobs.is_empty() {
        return Ok(0);
    }
    let mission_projects = collect_job_mission_projects(state, &jobs).await;
    sync_hermes_jobs_with_list(&state.projects, &jobs, &mission_projects)
}

pub(crate) async fn sync_local_hermes_jobs_if_present(state: &AppState) {
    let jobs = super::project_controller::hermes_home()
        .map(|h| super::project_controller::load_jobs(&h))
        .unwrap_or_default();
    if jobs.is_empty() {
        return;
    }
    let mission_projects = collect_job_mission_projects(state, &jobs).await;
    let _ = sync_hermes_jobs_with_list(&state.projects, &jobs, &mission_projects);
}

fn delivery_ready(store: &ProjectsStore, slug: &str) -> Result<bool, Response> {
    project_exists(store, slug)?;
    store
        .binding_for_canonical(slug, &super::projects_overview::project_tag_keys(slug))
        .map(|route| route.is_some_and(|r| !r.session_id.trim().is_empty()))
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())
}

fn prepare_delivery(
    store: &ProjectsStore,
    slug: &str,
    body: &mut Value,
    creating: bool,
) -> Result<(), Response> {
    project_exists(store, slug)?;
    let object = body
        .as_object_mut()
        .ok_or_else(|| (StatusCode::BAD_REQUEST, "cron must be a JSON object").into_response())?;
    if !creating && !object.contains_key("deliver") {
        return Ok(());
    }
    let default_deliver = if slug == "default" && !delivery_ready(store, slug)? {
        "local".to_string()
    } else {
        format!("project:{slug}")
    };
    let deliver = match object.get("deliver") {
        None | Some(Value::Null) => default_deliver,
        Some(Value::String(text)) if text.trim().is_empty() => default_deliver,
        Some(Value::String(text)) => text.trim().to_owned(),
        _ => return Err((StatusCode::BAD_REQUEST, "delivery must be a string").into_response()),
    };
    for target in deliver.split(',').map(str::trim) {
        if let Some(project) = target.strip_prefix("project:") {
            if project != slug {
                return Err((
                    StatusCode::BAD_REQUEST,
                    "project cron delivery must target its own project",
                )
                    .into_response());
            }
            if !delivery_ready(store, slug)? {
                return Err((StatusCode::CONFLICT, format!("Project '{slug}' has no canonical conversation route. Bind one first, or explicitly choose local delivery to save output only.")).into_response());
            }
        }
    }
    object.insert("deliver".into(), Value::String(deliver));
    Ok(())
}

async fn defaults(State(state): State<Arc<AppState>>, Path(slug): Path<String>) -> Response {
    match delivery_ready(&state.projects, &slug) {
        Ok(ready) => Json(json!({ "deliver": format!("project:{slug}"), "route_ready": ready, "folders_supported": true }))
            .into_response(),
        Err(error) => error,
    }
}

async fn collect_jobs<F, Fut>(ids: Vec<String>, mut fetch: F) -> Result<Vec<Value>, Response>
where
    F: FnMut(String) -> Fut,
    Fut: std::future::Future<Output = Result<Value, Response>>,
{
    let mut jobs = Vec::new();
    for id in ids {
        match fetch(id.clone()).await {
            Ok(value) => {
                let job = value.get("job").unwrap_or(&value);
                if job.get("id").and_then(Value::as_str) != Some(id.as_str()) {
                    return Err((
                        StatusCode::BAD_GATEWAY,
                        "Hermes returned an invalid job record",
                    )
                        .into_response());
                }
                jobs.push(job.clone());
            }
            Err(error) if error.status() == StatusCode::NOT_FOUND => {}
            Err(error) => return Err(error),
        }
    }
    Ok(jobs)
}

fn resolve_owned_slug(store: &ProjectsStore, slug: &str, id: &str) -> Result<String, Response> {
    project_exists(store, slug)?;
    if store
        .owns_project_cron(slug, id)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?
    {
        return Ok(slug.to_string());
    }
    let keys = super::projects_overview::project_tag_keys(slug);
    for candidate in &keys {
        if candidate != slug
            && store
                .owns_project_cron(candidate, id)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?
        {
            return Ok(candidate.clone());
        }
    }
    if let Some(owner) = store
        .cron_owner(id)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?
    {
        let owner_keys = super::projects_overview::project_tag_keys(&owner);
        if keys.iter().any(|k| {
            owner.eq_ignore_ascii_case(k) || owner_keys.iter().any(|ok| ok.eq_ignore_ascii_case(k))
        }) && store
            .owns_project_cron(&owner, id)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?
        {
            return Ok(owner);
        }
    }
    Err((StatusCode::NOT_FOUND, "cron is not bound to this project").into_response())
}

#[cfg(test)]
fn owned(store: &ProjectsStore, slug: &str, id: &str) -> Result<(), Response> {
    resolve_owned_slug(store, slug, id).map(|_| ())
}

async fn list(State(state): State<Arc<AppState>>, Path(slug): Path<String>) -> Response {
    let _ = sync_hermes_jobs(&state).await;
    if let Err(e) = project_exists(&state.projects, &slug) {
        return e;
    }
    let ids = match state.projects.project_cron_ids(&slug) {
        Ok(ids) => ids,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    };
    match collect_jobs(ids, |id| {
        let state = &state;
        let slug = &slug;
        async move {
            let res = hermes(
                state,
                reqwest::Method::GET,
                &format!("/api/jobs/{id}"),
                None,
            )
            .await;
            if let Err(ref error) = res {
                if error.status() == StatusCode::NOT_FOUND {
                    let _ = state.projects.unbind_project_cron(slug, &id);
                }
            }
            res
        }
    })
    .await
    {
        Ok(mut jobs) => {
            for job in &mut jobs {
                let id = job.get("id").and_then(Value::as_str).unwrap_or("");
                match state.projects.project_cron_folder(&slug, id) {
                    Ok(folder) => job["folder"] = json!(folder),
                    Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
                }
            }
            Json(json!({"jobs": jobs})).into_response()
        }
        Err(error) => error,
    }
}

async fn create(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
    Json(mut body): Json<Value>,
) -> Response {
    if let Err(e) = valid_slug(&slug) {
        return e;
    }
    if let Err(error) = prepare_delivery(&state.projects, &slug, &mut body, true) {
        return error;
    }
    let folder = match body.as_object_mut().and_then(|o| o.remove("folder")) {
        None => String::new(),
        Some(Value::String(folder)) if valid_folder(&folder) => folder,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "folder must be a relative project folder path",
            )
                .into_response()
        }
    };
    let mut result = match hermes(&state, reqwest::Method::POST, "/api/jobs", Some(body)).await {
        Ok(value) => value,
        Err(e) => return e,
    };
    let id = result
        .pointer("/job/id")
        .and_then(Value::as_str)
        .unwrap_or("");
    if id.is_empty() {
        return (
            StatusCode::BAD_GATEWAY,
            "Hermes created a job without an id",
        )
            .into_response();
    }
    if let Err(e) = state
        .projects
        .bind_project_cron_in_folder(&slug, id, &folder)
    {
        // Avoid a scheduler orphan if our durable binding cannot be committed.
        let _ = hermes(
            &state,
            reqwest::Method::DELETE,
            &format!("/api/jobs/{id}"),
            None,
        )
        .await;
        return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response();
    }
    result["job"]["folder"] = json!(folder);
    Json(result).into_response()
}

async fn get_one(
    State(state): State<Arc<AppState>>,
    Path((slug, id)): Path<(String, String)>,
) -> Response {
    if let Err(e) = valid_slug(&slug) {
        return e;
    }
    let owned_slug = match resolve_owned_slug(&state.projects, &slug, &id) {
        Ok(s) => s,
        Err(e) => return e,
    };
    hermes(
        &state,
        reqwest::Method::GET,
        &format!("/api/jobs/{id}"),
        None,
    )
    .await
    .and_then(|mut result| {
        let folder = state
            .projects
            .project_cron_folder(&owned_slug, &id)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?;
        result["job"]["folder"] = json!(folder);
        let runs = super::project_controller::hermes_home()
            .map(|h| super::project_controller::build_runs(&h, &id, 30))
            .unwrap_or_default();
        result["runs"] = json!(runs);
        Ok(result)
    })
    .map(Json)
    .map(IntoResponse::into_response)
    .unwrap_or_else(|e| {
        if e.status() == StatusCode::NOT_FOUND {
            let _ = state.projects.unbind_project_cron(&owned_slug, &id);
        }
        e
    })
}

async fn update(
    State(state): State<Arc<AppState>>,
    Path((slug, id)): Path<(String, String)>,
    Json(mut body): Json<Value>,
) -> Response {
    if let Err(e) = valid_slug(&slug) {
        return e;
    }
    let owned_slug = match resolve_owned_slug(&state.projects, &slug, &id) {
        Ok(s) => s,
        Err(e) => return e,
    };
    let target_project = match body.as_object_mut().and_then(|o| o.remove("project")) {
        None => None,
        Some(Value::String(target)) => {
            let trimmed = target.trim().to_string();
            if let Err(e) = project_exists(&state.projects, &trimmed) {
                return e;
            }
            Some(trimmed)
        }
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "project must be a valid project slug",
            )
                .into_response()
        }
    };
    let effective_slug = target_project.as_deref().unwrap_or(&owned_slug).to_string();
    if let Err(error) = prepare_delivery(&state.projects, &effective_slug, &mut body, false) {
        return error;
    }
    let folder = match body.as_object_mut().and_then(|o| o.remove("folder")) {
        None => None,
        Some(Value::String(folder)) if valid_folder(&folder) => Some(folder),
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "folder must be a relative project folder path",
            )
                .into_response()
        }
    };
    if target_project.is_some() || folder.is_some() {
        if let Err(e) =
            state
                .projects
                .move_project_cron(&owned_slug, &effective_slug, &id, folder.as_deref())
        {
            return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response();
        }
    }
    let response = if body.as_object().is_some_and(|o| o.is_empty()) {
        hermes(
            &state,
            reqwest::Method::GET,
            &format!("/api/jobs/{id}"),
            None,
        )
        .await
    } else {
        hermes(
            &state,
            reqwest::Method::PATCH,
            &format!("/api/jobs/{id}"),
            Some(body),
        )
        .await
    };
    response
        .and_then(|mut result| {
            let saved_folder = state
                .projects
                .project_cron_folder(&effective_slug, &id)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e).into_response())?;
            result["job"]["folder"] = json!(saved_folder);
            result["job"]["project"] = json!(effective_slug);
            let runs = super::project_controller::hermes_home()
                .map(|h| super::project_controller::build_runs(&h, &id, 30))
                .unwrap_or_default();
            result["runs"] = json!(runs);
            Ok(result)
        })
        .map(Json)
        .map(IntoResponse::into_response)
        .unwrap_or_else(|e| e)
}

async fn remove(
    State(state): State<Arc<AppState>>,
    Path((slug, id)): Path<(String, String)>,
) -> Response {
    if let Err(e) = valid_slug(&slug) {
        return e;
    }
    if let Err(e) = project_exists(&state.projects, &slug) {
        return e;
    }
    let owned_slug = match resolve_owned_slug(&state.projects, &slug, &id) {
        Ok(s) => Some(s),
        Err(not_bound) => match state.projects.cron_owner(&id) {
            Ok(None) => None,
            Ok(Some(_)) => return not_bound,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
        },
    };
    match hermes(
        &state,
        reqwest::Method::DELETE,
        &format!("/api/jobs/{id}"),
        None,
    )
    .await
    {
        Ok(_) => {}
        Err(error) if error.status() == StatusCode::NOT_FOUND => {}
        Err(error) => return error,
    }
    if let Some(ref owner) = owned_slug {
        if let Err(e) = state.projects.unbind_project_cron(owner, &id) {
            return (StatusCode::INTERNAL_SERVER_ERROR, e).into_response();
        }
    } else {
        let _ = state.projects.unbind_project_cron_any(&id);
    }
    Json(json!({ "deleted": id })).into_response()
}

async fn action(
    State(state): State<Arc<AppState>>,
    Path((slug, id)): Path<(String, String)>,
    Json(body): Json<Value>,
) -> Response {
    if let Err(e) = valid_slug(&slug) {
        return e;
    }
    if let Err(e) = resolve_owned_slug(&state.projects, &slug, &id) {
        return e;
    }
    let action = body.get("action").and_then(Value::as_str).unwrap_or("");
    let suffix = match action {
        "pause" | "resume" | "run" => format!("/api/jobs/{id}/{action}"),
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                "action must be pause, resume, or run",
            )
                .into_response()
        }
    };
    hermes(&state, reqwest::Method::POST, &suffix, None)
        .await
        .map(Json)
        .map(IntoResponse::into_response)
        .unwrap_or_else(|e| e)
}

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/:slug/crons/defaults", get(defaults))
        .route("/:slug/crons", get(list).post(create))
        .route(
            "/:slug/crons/:id",
            get(get_one).patch(update).delete(remove),
        )
        .route("/:slug/crons/:id/action", post(action))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> ProjectsStore {
        let store = ProjectsStore::open_in_memory().unwrap();
        store
            .upsert_project(
                "orbit",
                Some("Orbit"),
                None,
                None,
                Some("canonical-controller"),
            )
            .unwrap();
        store
            .upsert_project("other", None, None, None, None)
            .unwrap();
        store
    }

    #[test]
    fn project_cron_ownership_is_exclusive_and_preserves_controller() {
        let store = store();
        store.bind_project_cron("orbit", "additional-job").unwrap();
        assert!(owned(&store, "orbit", "additional-job").is_ok());
        assert_eq!(
            owned(&store, "other", "additional-job")
                .unwrap_err()
                .status(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            owned(&store, "missing", "additional-job")
                .unwrap_err()
                .status(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            owned(&store, "orbit", "canonical-controller")
                .unwrap_err()
                .status(),
            StatusCode::NOT_FOUND
        );
        assert!(store.bind_project_cron("other", "additional-job").is_err());
        assert!(store.bind_project_cron("missing", "orphan").is_err());
        assert_eq!(
            store
                .get_project("orbit")
                .unwrap()
                .unwrap()
                .controller_cron_id
                .as_deref(),
            Some("canonical-controller")
        );
        assert_eq!(
            store.project_cron_ids("orbit").unwrap(),
            vec!["additional-job"]
        );
    }

    #[test]
    fn project_cron_delivery_defaults_require_explicit_canonical_route() {
        let store = store();
        let mut draft = json!({"name": "notes"});
        assert_eq!(
            prepare_delivery(&store, "orbit", &mut draft, true)
                .unwrap_err()
                .status(),
            StatusCode::CONFLICT
        );
        // A caller may intentionally request local output, but it is never a fallback.
        let mut local = json!({"deliver": "local"});
        prepare_delivery(&store, "orbit", &mut local, true).unwrap();
        assert_eq!(local["deliver"], "local");
        store
            .set_binding("orbit", "test-canonical-conversation", Some("test"))
            .unwrap();
        prepare_delivery(&store, "orbit", &mut draft, true).unwrap();
        assert_eq!(draft["deliver"], "project:orbit");
        assert!(delivery_ready(&store, "orbit").unwrap());
        assert!(!delivery_ready(&store, "other").unwrap());
        assert_eq!(
            prepare_delivery(&store, "other", &mut draft, true)
                .unwrap_err()
                .status(),
            StatusCode::BAD_REQUEST
        );
        let mut edit = json!({"name": "renamed"});
        prepare_delivery(&store, "other", &mut edit, false).unwrap();
        assert!(edit.get("deliver").is_none());
        let mut invalid = json!({"deliver": []});
        assert_eq!(
            prepare_delivery(&store, "orbit", &mut invalid, true)
                .unwrap_err()
                .status(),
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            store
                .get_project("orbit")
                .unwrap()
                .unwrap()
                .controller_cron_id
                .as_deref(),
            Some("canonical-controller")
        );
    }

    async fn upstream(status: StatusCode, body: String) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = Router::new().fallback(move || {
            let body = body.clone();
            async move { (status, body) }
        });
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (url, task)
    }

    #[tokio::test]
    async fn project_cron_adapter_propagates_outage_and_auth_without_local_logout() {
        for (status, expected) in [
            (
                StatusCode::SERVICE_UNAVAILABLE,
                StatusCode::SERVICE_UNAVAILABLE,
            ),
            (StatusCode::UNAUTHORIZED, StatusCode::BAD_GATEWAY),
            (StatusCode::FORBIDDEN, StatusCode::BAD_GATEWAY),
            (StatusCode::NOT_FOUND, StatusCode::BAD_GATEWAY),
        ] {
            let (url, task) = upstream(status, "adapter unavailable".into()).await;
            let error = hermes_request(
                &reqwest::Client::new(),
                &url,
                "test-key",
                reqwest::Method::GET,
                "/api/jobs/test",
                None,
            )
            .await
            .unwrap_err();
            assert_eq!(error.status(), expected);
            let text = axum::body::to_bytes(error.into_body(), 4096).await.unwrap();
            assert!(String::from_utf8_lossy(&text)
                .contains(&format!("Hermes scheduler returned {}", status.as_u16())));
            task.abort();
        }
    }

    #[tokio::test]
    async fn project_cron_adapter_skips_only_explicit_deleted_jobs_and_rejects_invalid_records() {
        let (url, task) = upstream(
            StatusCode::NOT_FOUND,
            json!({"error": "Job not found"}).to_string(),
        )
        .await;
        let client = reqwest::Client::new();
        let result = collect_jobs(vec!["deleted".into()], |_| {
            hermes_request(
                &client,
                &url,
                "test-key",
                reqwest::Method::GET,
                "/api/jobs/deleted",
                None,
            )
        })
        .await
        .unwrap();
        assert!(result.is_empty());
        task.abort();
        let (url, task) = upstream(StatusCode::OK, "not json".into()).await;
        assert_eq!(
            hermes_request(
                &client,
                &url,
                "test-key",
                reqwest::Method::GET,
                "/api/jobs/test",
                None
            )
            .await
            .unwrap_err()
            .status(),
            StatusCode::BAD_GATEWAY
        );
        task.abort();
        assert_eq!(
            collect_jobs(vec!["expected".into()], |_| async {
                Ok(json!({"job": null}))
            })
            .await
            .unwrap_err()
            .status(),
            StatusCode::BAD_GATEWAY
        );
    }

    #[tokio::test]
    async fn project_cron_adapter_preserves_real_hermes_schema_and_partial_failure() {
        let fixtures: Value =
            serde_json::from_str(include_str!("../../orb/tests/fixtures/hermes-jobs.json"))
                .unwrap();
        let job = fixtures["hourly"].clone();
        let (url, task) = upstream(StatusCode::OK, json!({"job": job}).to_string()).await;
        let client = reqwest::Client::new();
        let result = collect_jobs(vec![job["id"].as_str().unwrap().into()], |_| {
            hermes_request(
                &client,
                &url,
                "test-key",
                reqwest::Method::GET,
                "/api/jobs/test",
                None,
            )
        })
        .await
        .unwrap();
        assert_eq!(result, vec![job.clone()]);
        task.abort();
        let result = collect_jobs(
            vec![job["id"].as_str().unwrap().into(), "unavailable".into()],
            |id| {
                let job = job.clone();
                async move {
                    if id == "unavailable" {
                        Err((StatusCode::SERVICE_UNAVAILABLE, "Hermes unavailable").into_response())
                    } else {
                        Ok(json!({"job": job}))
                    }
                }
            },
        )
        .await;
        assert_eq!(
            result.unwrap_err().status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
    }

    #[test]
    fn sync_hermes_jobs_binds_unassigned_crons_to_default_and_respects_origin_and_controllers() {
        let store = store();
        let mut mission_projects = std::collections::HashMap::new();
        mission_projects.insert("m-other".to_string(), "other".to_string());
        let jobs = vec![
            json!({"id": "canonical-controller", "name": "Controller", "controller": {"project": "orbit"}}),
            json!({"id": "orbit-secondary", "name": "Orbit extra", "deliver": "project:orbit"}),
            json!({"id": "from-orb-mission", "name": "Mission cron", "origin": {"chat_id": "orb_m-other"}}),
            json!({"id": "unassigned-hermes", "name": "Morning brief", "deliver": "local"}),
        ];
        let bound = sync_hermes_jobs_with_list(&store, &jobs, &mission_projects).unwrap();
        assert_eq!(bound, 3);
        assert_eq!(
            store.project_cron_ids("orbit").unwrap(),
            vec!["orbit-secondary"]
        );
        assert_eq!(
            store.project_cron_ids("other").unwrap(),
            vec!["from-orb-mission"]
        );
        assert_eq!(
            store.project_cron_ids("default").unwrap(),
            vec!["unassigned-hermes"]
        );
        // Second sync is idempotent.
        assert_eq!(
            sync_hermes_jobs_with_list(&store, &jobs, &mission_projects).unwrap(),
            0
        );
    }

    #[test]
    fn move_project_cron_transfers_between_projects_and_folders_and_resolves_canonical_slugs() {
        let store = store();
        store
            .bind_project_cron_in_folder("orbit", "job-move", "crons")
            .unwrap();
        assert_eq!(
            store.project_cron_folder("orbit", "job-move").unwrap(),
            "crons"
        );
        store
            .move_project_cron("orbit", "other", "job-move", Some("monitors/daily"))
            .unwrap();
        assert!(store.project_cron_ids("orbit").unwrap().is_empty());
        assert_eq!(store.project_cron_ids("other").unwrap(), vec!["job-move"]);
        assert_eq!(
            store.project_cron_folder("other", "job-move").unwrap(),
            "monitors/daily"
        );
        store
            .upsert_project("Verity", Some("Verity"), None, None, None)
            .unwrap();
        store
            .upsert_project("verity", Some("verity"), None, None, None)
            .unwrap();
        store.bind_project_cron("verity", "verity-cron").unwrap();
        assert_eq!(
            resolve_owned_slug(&store, "Verity", "verity-cron").unwrap(),
            "verity"
        );
    }
}

fn valid_folder(folder: &str) -> bool {
    folder.is_empty()
        || (!folder.contains('\\')
            && !folder.contains('\0')
            && folder
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != ".."))
}
