//! Authenticated mission/project file sources. Never accepts a host root from clients.
use super::{auth::AuthUser, routes::AppState};
use axum::{extract::State, http::StatusCode, Extension, Json};
use serde_json::{json, Value};
use std::{path::PathBuf, sync::Arc};
#[derive(serde::Deserialize)]
pub struct Request {
    pub mission_id: Option<uuid::Uuid>,
    pub project: Option<String>,
    #[serde(default)]
    pub source: String,
    #[serde(flatten)]
    pub operation: crate::file_browser::Request,
}
type Error = (StatusCode, String);
pub async fn operate(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(mut req): Json<Request>,
) -> Result<Json<Value>, Error> {
    let mission = if let Some(id) = req.mission_id {
        Some(
            super::control::get_mission(
                State(state.clone()),
                Extension(user.clone()),
                axum::extract::Path(id),
            )
            .await?
            .0,
        )
    } else {
        None
    };
    let project = mission
        .as_ref()
        .and_then(|m| m["project"].as_str())
        .or(req.project.as_deref());
    let mut roots: Vec<(String, String, PathBuf)> = Vec::new();
    if let Some(slug) = project {
        if !super::projects_overview::is_plain_key(slug) {
            return Err((StatusCode::BAD_REQUEST, "Invalid project".into()));
        }
        roots.push((
            "context".into(),
            "Project context · current".into(),
            state
                .config
                .working_dir
                .join(".sandboxed-sh/project-files")
                .join(slug),
        ));
    }
    let transfer = mission
        .as_ref()
        .and_then(|m| m.get("machine_transfer"))
        .filter(|t| t["destination"]["kind"] == "node");
    let remote = mission
        .as_ref()
        .and_then(|m| m.get("remote_job"))
        .filter(|j| j.is_object());
    if let (Some(m), Some(id)) = (&mission, req.mission_id) {
        if remote.is_none()
            && transfer.is_none()
            && !m["tags"]
                .as_array()
                .is_some_and(|t| t.iter().any(|t| t == "placement:client"))
        {
            if let Some(ws_id) = m["workspace_id"].as_str().and_then(|v| v.parse().ok()) {
                if let Some(ws) = state.workspaces.get(ws_id).await {
                    let path = m["working_directory"]
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| {
                            crate::workspace::mission_workspace_dir_for_workspace(&ws, id)
                                .to_string_lossy()
                                .into_owned()
                        });
                    if let Ok(path) =
                        super::fs::resolve_path_for_workspace(&state, ws_id, &path, Some(id)).await
                    {
                        if path.join(".paloma").is_dir() {
                            roots.push((
                                "snapshot".into(),
                                "Attached context · mission copy".into(),
                                path.join(".paloma"),
                            ));
                        }
                        roots.insert(0, ("workspace".into(), "Workspace".into(), path));
                    }
                }
            }
        }
    }
    if let (Some(_), Some(id)) = (&mission, req.mission_id) {
        // Files Core copied out of an agent's reach (Hermes `MEDIA:` attachments).
        roots.push((
            "media".into(),
            "Shared files".into(),
            super::cloud_agents::media::mission_media_dir(&state.config.working_dir, id),
        ));
    }
    // Earlier and later attempts of a replacement chain on the same node: the
    // node keeps each one's workspace, and agents cite those files. Read-only.
    let mut sessions: Vec<(uuid::Uuid, Value)> = Vec::new();
    if let (Some(remote), Some(id)) = (remote, req.mission_id) {
        let control = super::control::control_for_user(&state, &user).await;
        let (earlier, later) =
            super::mission_horizon::replacement_chain(control.mission_store.as_ref(), id)
                .await
                .map_err(|_| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Mission chain unavailable".into(),
                    )
                })?;
        for (group, other) in earlier
            .into_iter()
            .map(|m| ("earlier", m))
            .chain(later.into_iter().map(|m| ("later", m)))
        {
            // The same per-user lookup as the current mission: authorization stays here.
            let Ok(Json(m)) = super::control::get_mission(
                State(state.clone()),
                Extension(user.clone()),
                axum::extract::Path(other),
            )
            .await
            else {
                continue;
            };
            let job = &m["remote_job"];
            if job["node_id"] != remote["node_id"] || !job["job_id"].is_string() {
                continue;
            }
            let short = &other.to_string()[..8];
            let title = m["title"].as_str().unwrap_or("Untitled");
            sessions.push((
                other,
                json!({"id":format!("{group}:{other}"),"label":format!("{title} · {short}"),
                    "group":group,"mission":other,"machine":remote["node_id"],
                    "job":job["job_id"],"available":true,"readonly":true}),
            ));
        }
    }
    if req.operation.action == "roots" {
        let mut sources:Vec<Value>=roots.iter().map(|(id,label,path)|json!({"id":id,"label":label,"path":path,"available":path.is_dir()})).collect();
        if let Some(t) = transfer {
            sources.insert(0,json!({"id":"workspace","label":"Workspace","machine":t["destination"]["id"],"available":true}));
        } else if let Some(remote) = remote {
            sources.insert(0,json!({"id":"workspace","label":"Workspace","machine":remote["node_id"],"mission":req.mission_id,"available":true}));
        }
        let at = usize::from(!sources.is_empty() && (transfer.is_some() || remote.is_some()));
        for (index, (_, session)) in sessions.iter().enumerate() {
            let mut session = session.clone();
            session.as_object_mut().map(|o| o.remove("job"));
            sources.insert(at + index, session);
        }
        return Ok(Json(json!({"sources":sources})));
    }
    if req.source == "workspace" {
        if let Some(t) = transfer {
            let node = t["destination"]["id"]
                .as_str()
                .and_then(|id| state.config.remote_nodes.node(id))
                .ok_or((StatusCode::CONFLICT, "Destination unavailable".into()))?;
            let token = crate::remote_node::node_token(&node.token_env).map_err(|_| {
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "Destination authentication unavailable".into(),
                )
            })?;
            let response = state
                .http_client
                .post(format!("{}/machine-transfer/browse", node.base_url))
                .bearer_auth(token)
                .timeout(std::time::Duration::from_secs(15))
                .json(&json!({"transfer_id":t["id"],"operation":req.operation}))
                .send()
                .await
                .map_err(|_| (StatusCode::BAD_GATEWAY, "Destination unreachable".into()))?;
            if !response.status().is_success() {
                return Err((
                    StatusCode::BAD_GATEWAY,
                    "Transferred workspace unavailable".into(),
                ));
            }
            return Ok(Json(response.json().await.map_err(|_| {
                (StatusCode::BAD_GATEWAY, "Invalid workspace response".into())
            })?));
        }
        if let Some(remote) = remote {
            let node = remote["node_id"].as_str().unwrap_or_default();
            let job = remote["job_id"]
                .as_str()
                .ok_or((StatusCode::CONFLICT, "Remote job is unavailable".into()))?;
            return node_files(&state, node, job, &req.operation)
                .await
                .map(Json);
        }
    }
    if let Some((_, session)) = sessions
        .iter()
        .find(|(_, s)| s["id"].as_str() == Some(req.source.as_str()))
    {
        let job = session["job"].as_str().unwrap_or_default();
        let node = session["machine"].as_str().unwrap_or_default();
        return node_files(&state, node, job, &req.operation)
            .await
            .map(Json);
    }
    if session_source(&req.source).is_some() {
        return Err((
            StatusCode::FORBIDDEN,
            "That file is outside this mission's workspaces".into(),
        ));
    }
    let root = roots
        .into_iter()
        .find(|(id, _, _)| id == &req.source)
        .ok_or((StatusCode::NOT_FOUND, "File source unavailable".into()))?
        .2;
    let original = req.operation.paths.clone();
    if req.source == "workspace" && req.operation.action == "resolve" {
        if let (Some(m), Some(id)) = (&mission, req.mission_id) {
            if let Some(ws) = m["workspace_id"].as_str().and_then(|s| s.parse().ok()) {
                for path in &mut req.operation.paths {
                    if std::path::Path::new(path).is_absolute() {
                        if let Ok(resolved) =
                            super::fs::resolve_path_for_workspace(&state, ws, path, Some(id)).await
                        {
                            if let Ok(rel) = resolved.strip_prefix(&root) {
                                *path = rel.to_string_lossy().into_owned();
                            }
                        }
                    }
                }
            }
        }
    }
    let mut value =
        tokio::task::spawn_blocking(move || crate::file_browser::execute(&root, &req.operation))
            .await
            .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "File read failed".into()))?
            .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    if let Some(results) = value["results"].as_array_mut() {
        for (row, reference) in results.iter_mut().zip(original) {
            row["reference"] = json!(reference);
        }
    }
    Ok(Json(value))
}

/// `earlier:<id>` / `later:<id>`: the mission a session source names.
fn session_source(source: &str) -> Option<uuid::Uuid> {
    let (group, id) = source.split_once(':')?;
    matches!(group, "earlier" | "later")
        .then(|| id.parse().ok())
        .flatten()
}

/// One node job's workspace, through the node's own path-checked browser.
async fn node_files(
    state: &AppState,
    node_id: &str,
    job: &str,
    operation: &crate::file_browser::Request,
) -> Result<Value, Error> {
    let node = state.config.remote_nodes.node(node_id).ok_or((
        StatusCode::CONFLICT,
        format!("Machine {node_id} is no longer configured"),
    ))?;
    let token = crate::remote_node::node_token(&node.token_env).map_err(|_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            format!("Core has no credentials for {node_id}"),
        )
    })?;
    let response = state
        .http_client
        .post(format!("{}/jobs/{}/files", node.base_url, job))
        .bearer_auth(token)
        .timeout(std::time::Duration::from_secs(15))
        .json(operation)
        .send()
        .await
        .map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                format!("{node_id} is offline or unreachable"),
            )
        })?;
    match response.status() {
        s if s.is_success() => response.json().await.map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Invalid remote file response".into(),
            )
        }),
        StatusCode::NOT_FOUND => Err((
            StatusCode::GONE,
            format!("{node_id} no longer keeps this session's workspace"),
        )),
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err((
            StatusCode::BAD_GATEWAY,
            format!("{node_id} refused Core's credentials"),
        )),
        StatusCode::BAD_REQUEST => Err((
            StatusCode::BAD_REQUEST,
            response
                .text()
                .await
                .ok()
                .filter(|t| !t.is_empty() && t.len() < 200)
                .unwrap_or_else(|| "File is unavailable".into()),
        )),
        _ => Err((
            StatusCode::BAD_GATEWAY,
            "Remote file browser unavailable; update the node or retry".into(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::session_source;

    #[test]
    fn only_chain_groups_name_a_session() {
        let id = uuid::Uuid::new_v4();
        assert_eq!(session_source(&format!("earlier:{id}")), Some(id));
        assert_eq!(session_source(&format!("later:{id}")), Some(id));
        assert_eq!(session_source(&format!("workspace:{id}")), None);
        assert_eq!(session_source("earlier:../../etc"), None);
    }
}
