use super::{auth::AuthUser, routes::AppState};
use axum::{
    body::Bytes,
    extract::{Path as AxumPath, Query, State},
    http::StatusCode,
    Extension, Json,
};
use std::sync::Arc;

#[derive(serde::Deserialize)]
pub struct Request {
    pub node_id: Option<String>,
    #[serde(flatten)]
    pub file: crate::uploads::Upload,
}
#[derive(serde::Deserialize)]
pub struct SessionInitRequest {
    pub node_id: Option<String>,
    #[serde(flatten)]
    pub session: crate::uploads::SessionInit,
}
#[derive(serde::Deserialize, Default)]
pub struct NodeQuery {
    pub node_id: Option<String>,
}
type Error = (StatusCode, String);

fn remote_node_auth(
    state: &AppState,
    node_id: &str,
) -> Result<(String, String), (StatusCode, String)> {
    let node = state.config.remote_nodes.node(node_id).ok_or((
        StatusCode::BAD_REQUEST,
        "Unknown destination machine".into(),
    ))?;
    let token = crate::remote_node::node_token(&node.token_env).map_err(|_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "Machine connection is unavailable".into(),
        )
    })?;
    Ok((node.base_url.trim_end_matches('/').to_string(), token))
}

pub async fn upload(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(request): Json<Request>,
) -> Result<Json<crate::uploads::Receipt>, Error> {
    let slot = crate::uploads::SLOTS.try_acquire().map_err(|_| {
        (
            StatusCode::TOO_MANY_REQUESTS,
            "Other uploads are in progress; try again shortly".into(),
        )
    })?;
    if let Some(id) = request.node_id.as_deref().filter(|id| *id != "core") {
        let (base_url, token) = remote_node_auth(&state, id)?;
        let response = state
            .http_client
            .post(format!("{base_url}/uploads"))
            .bearer_auth(token)
            .timeout(std::time::Duration::from_secs(120))
            .json(&request.file)
            .send()
            .await
            .map_err(|_| {
                (
                    StatusCode::BAD_GATEWAY,
                    "Could not transfer the file to the selected machine".into(),
                )
            })?;
        if !response.status().is_success() {
            let status = response.status();
            return Err((
                StatusCode::BAD_GATEWAY,
                if status == StatusCode::NOT_FOUND {
                    "This machine needs an update before accepting file uploads".into()
                } else {
                    format!("File transfer refused by the selected machine ({status})")
                },
            ));
        }
        return response.json().await.map(Json).map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Invalid upload receipt from selected machine".into(),
            )
        });
    }
    let root = super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    tokio::task::spawn_blocking(move || {
        let _slot = slot;
        crate::uploads::prune_expired_uploads(
            &root,
            std::time::Duration::from_secs(crate::uploads::BATCH_OPEN_SECS),
        );
        crate::uploads::store(&root, request.file)
    })
    .await
    .map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Upload worker failed".into(),
        )
    })?
    .map(Json)
    .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn forward_one_core_upload(
    state: &AppState,
    node_id: &str,
    canon_root: &std::path::Path,
    raw_path: &str,
) -> Result<Option<String>, Error> {
    let candidate = std::path::Path::new(raw_path.trim());
    let Ok(canon_file) = std::fs::canonicalize(candidate) else {
        return Ok(None);
    };
    if !canon_file.starts_with(canon_root) || !canon_file.is_file() {
        return Ok(None);
    }
    let Some(name) = canon_file
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
    else {
        return Ok(None);
    };
    let Ok(bytes) = tokio::fs::read(&canon_file).await else {
        return Ok(None);
    };
    let (base_url, token) = remote_node_auth(state, node_id)?;
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &bytes);
    let payload = serde_json::json!({
        "name": name,
        "data_base64": b64,
    });
    let response = state
        .http_client
        .post(format!("{base_url}/uploads"))
        .bearer_auth(token)
        .timeout(std::time::Duration::from_secs(120))
        .json(&payload)
        .send()
        .await
        .map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Could not transfer the file to the selected machine".into(),
            )
        })?;
    if !response.status().is_success() {
        let status = response.status();
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("File transfer refused by the selected machine ({status})"),
        ));
    }
    let receipt: crate::uploads::Receipt = response.json().await.map_err(|_| {
        (
            StatusCode::BAD_GATEWAY,
            "Invalid upload receipt from selected machine".into(),
        )
    })?;
    crate::uploads::cleanup_prompt_uploads(canon_root, raw_path);
    Ok(Some(receipt.path))
}

/// If a client uploaded a file to Core (`node_id: "core"`) before discovering
/// that the target mission runs on a remote worker node (`node_id != "core"`),
/// forwards any `[Uploaded: <core_uploads_path>]` or `@"<core_uploads_path>"` /
/// `@<core_uploads_path>` reference to the worker node and rewrites the prompt
/// reference to the remote receipt path.
pub(crate) async fn forward_core_uploads_in_prompt(
    state: &AppState,
    node_id: &str,
    content: &str,
) -> Result<String, Error> {
    if node_id.is_empty()
        || node_id == "core"
        || (!content.contains("[Uploaded: ") && !content.contains('@'))
    {
        return Ok(content.to_string());
    }
    let root = super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    let Ok(canon_root) = std::fs::canonicalize(&root) else {
        return Ok(content.to_string());
    };
    let mut updated = content.to_string();
    let mut cursor = 0usize;
    while let Some(rel_idx) = updated[cursor..].find("[Uploaded: ") {
        let start = cursor + rel_idx;
        let path_start = start + "[Uploaded: ".len();
        let Some(rel_end) = updated[path_start..].find(']') else {
            break;
        };
        let path_end = path_start + rel_end;
        let raw_path = updated[path_start..path_end].trim().to_string();
        cursor = path_end + 1;
        let Some(remote_path) =
            forward_one_core_upload(state, node_id, &canon_root, &raw_path).await?
        else {
            continue;
        };
        let old_tag = format!("[Uploaded: {raw_path}]");
        let new_tag = format!("[Uploaded: {remote_path}]");
        updated = updated.replacen(&old_tag, &new_tag, 1);
        cursor = start + new_tag.len();
    }
    // Also forward `@"<core_upload_path>"` and `@<core_upload_path>` mentions
    // from Desktop/Web Composer when Core routes the prompt to a remote node.
    let mention_re =
        regex::Regex::new(r#"(^|[\s(\[{])@(?:"((?:[^"\\]|\\.)*)"|([^\s)\]},;]+))"#).unwrap();
    let mut matches: Vec<(usize, usize, bool, String)> = Vec::new();
    for cap in mention_re.captures_iter(&updated) {
        let whole = cap.get(0).unwrap();
        let prefix_len = cap.get(1).map_or(0, |m| m.len());
        let at_start = whole.start() + prefix_len;
        let at_end = whole.end();
        let quoted = cap.get(2).is_some();
        let raw_path = if let Some(q) = cap.get(2) {
            q.as_str().replace("\\\"", "\"").replace("\\\\", "\\")
        } else {
            cap.get(3)
                .unwrap()
                .as_str()
                .trim_end_matches(['.', ',', ';', ':', '!', '?'])
                .to_string()
        };
        matches.push((at_start, at_end, quoted, raw_path));
    }
    for (at_start, at_end, quoted, raw_path) in matches.into_iter().rev() {
        let Some(remote_path) =
            forward_one_core_upload(state, node_id, &canon_root, &raw_path).await?
        else {
            continue;
        };
        let replacement = if quoted || remote_path.contains([' ', '"']) {
            format!(
                "@\"{}\"",
                remote_path.replace('\\', "\\\\").replace('"', "\\\"")
            )
        } else {
            let token_len = 1 + raw_path.len();
            let trailing = &updated[at_start + token_len..at_end];
            format!("@{remote_path}{trailing}")
        };
        updated.replace_range(at_start..at_end, &replacement);
    }
    Ok(updated)
}

pub async fn session_init(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Json(request): Json<SessionInitRequest>,
) -> Result<Json<crate::uploads::SessionStatus>, Error> {
    if let Some(id) = request.node_id.as_deref().filter(|id| *id != "core") {
        let (base_url, token) = remote_node_auth(&state, id)?;
        let response = state
            .http_client
            .post(format!("{base_url}/uploads/sessions"))
            .bearer_auth(token)
            .timeout(std::time::Duration::from_secs(60))
            .json(&request.session)
            .send()
            .await
            .map_err(|_| {
                (
                    StatusCode::BAD_GATEWAY,
                    "Could not initialize upload on the selected machine".into(),
                )
            })?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err((
                StatusCode::BAD_GATEWAY,
                if status == StatusCode::NOT_FOUND {
                    "This machine needs an update before accepting resumable uploads".into()
                } else if !text.is_empty() {
                    text
                } else {
                    format!("Upload session refused by the selected machine ({status})")
                },
            ));
        }
        return response.json().await.map(Json).map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Invalid upload session response from selected machine".into(),
            )
        });
    }
    let root = super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    tokio::task::spawn_blocking(move || {
        crate::uploads::init_or_status_session(&root, request.session)
    })
    .await
    .map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Upload session worker failed".into(),
        )
    })?
    .map(Json)
    .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn session_chunk(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    AxumPath((upload_id, index)): AxumPath<(String, usize)>,
    Query(query): Query<NodeQuery>,
    bytes: Bytes,
) -> Result<Json<crate::uploads::SessionStatus>, Error> {
    let slot = crate::uploads::CHUNK_SLOTS.acquire().await.map_err(|_| {
        (
            StatusCode::TOO_MANY_REQUESTS,
            "Upload queue unavailable".into(),
        )
    })?;
    if let Some(id) = query.node_id.as_deref().filter(|id| *id != "core") {
        let _slot = slot;
        crate::uploads::validate_upload_id(&upload_id).map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        let (base_url, token) = remote_node_auth(&state, id)?;
        let response = state
            .http_client
            .put(format!(
                "{base_url}/uploads/sessions/{upload_id}/chunks/{index}"
            ))
            .bearer_auth(token)
            .header(axum::http::header::CONTENT_TYPE, "application/octet-stream")
            .timeout(std::time::Duration::from_secs(120))
            .body(bytes)
            .send()
            .await
            .map_err(|_| {
                (
                    StatusCode::BAD_GATEWAY,
                    "Could not transfer upload chunk to the selected machine".into(),
                )
            })?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err((
                StatusCode::BAD_GATEWAY,
                if !text.is_empty() {
                    text
                } else {
                    format!("Chunk refused by the selected machine ({status})")
                },
            ));
        }
        return response.json().await.map(Json).map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Invalid chunk response from selected machine".into(),
            )
        });
    }
    let root = super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    tokio::task::spawn_blocking(move || {
        let _slot = slot;
        crate::uploads::write_session_chunk(&root, &upload_id, index, &bytes)
    })
    .await
    .map_err(|_| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "Upload chunk worker failed".into(),
        )
    })?
    .map(Json)
    .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn session_complete(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    AxumPath(upload_id): AxumPath<String>,
    Query(query): Query<NodeQuery>,
) -> Result<Json<crate::uploads::Receipt>, Error> {
    if let Some(id) = query.node_id.as_deref().filter(|id| *id != "core") {
        crate::uploads::validate_upload_id(&upload_id).map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        let (base_url, token) = remote_node_auth(&state, id)?;
        let response = state
            .http_client
            .post(format!("{base_url}/uploads/sessions/{upload_id}/complete"))
            .bearer_auth(token)
            .timeout(std::time::Duration::from_secs(180))
            .send()
            .await
            .map_err(|_| {
                (
                    StatusCode::BAD_GATEWAY,
                    "Could not finalize upload on the selected machine".into(),
                )
            })?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err((
                StatusCode::BAD_GATEWAY,
                if !text.is_empty() {
                    text
                } else {
                    format!("Upload finalization refused by the selected machine ({status})")
                },
            ));
        }
        return response.json().await.map(Json).map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Invalid upload receipt from selected machine".into(),
            )
        });
    }
    let root = super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    tokio::task::spawn_blocking(move || crate::uploads::complete_session(&root, &upload_id))
        .await
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Upload finalize worker failed".into(),
            )
        })?
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn session_cancel(
    State(state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    AxumPath(upload_id): AxumPath<String>,
    Query(query): Query<NodeQuery>,
) -> Result<StatusCode, Error> {
    if let Some(id) = query.node_id.as_deref().filter(|id| *id != "core") {
        crate::uploads::validate_upload_id(&upload_id).map_err(|e| (StatusCode::BAD_REQUEST, e))?;
        let (base_url, token) = remote_node_auth(&state, id)?;
        let _ = state
            .http_client
            .delete(format!("{base_url}/uploads/sessions/{upload_id}"))
            .bearer_auth(token)
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await;
        return Ok(StatusCode::NO_CONTENT);
    }
    let root = super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    tokio::task::spawn_blocking(move || crate::uploads::cancel_session(&root, &upload_id))
        .await
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Upload cancel worker failed".into(),
            )
        })?
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}
