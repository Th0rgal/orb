use super::*;
use crate::api::{
    auth::AuthUser,
    control::{ControlMessageRequest, ControlMessageResponse, CreateMissionRequest},
    mission_store::MissionStore,
    routes::AppState,
};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Extension, Json,
};
use serde_json::json;
use std::sync::Arc;
type Error = (StatusCode, String);
fn bad(s: impl Into<String>) -> Error {
    (StatusCode::BAD_REQUEST, s.into())
}
fn account_allowed(user: &str) -> bool {
    std::env::var("CURSOR_CLOUD_OWNER").is_ok_and(|owner| owner == user)
}
fn enabled(user: &str) -> bool {
    account_allowed(user) && std::env::var("CURSOR_CLOUD_VALIDATED").as_deref() == Ok("1")
}
pub async fn accounts(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Json<Vec<Account>> {
    let connected =
        account_allowed(&user.id) && cursor::Cursor::from_account("cursor-default").is_ok();
    let mut accounts = vec![
        Account {
            id: "chatgpt-pool".into(),
            provider: Provider::Chatgpt,
            label: "ChatGPT".into(),
            available: false,
            experimental: true,
            reason: Some(
                "Dedicated browser account binding and cloud canary have not been validated".into(),
            ),
            capabilities: Capabilities::default(),
        },
        Account {
            id: "grok-default".into(),
            provider: Provider::GrokBot,
            label: "Grok Bot".into(),
            available: std::env::var("GROK_BOT_OWNER").as_deref() == Ok(user.id.as_str())
                && std::env::var("GROK_BOT_VALIDATED").as_deref() == Ok("1")
                && grok::Grok::from_account("grok-default").is_ok(),
            experimental: true,
            reason: Some("Experimental connector. Bots on this account share one computer".into()),
            capabilities: Capabilities {
                follow_up: true,
                cancel: true,
                ..Default::default()
            },
        },
        Account {
            id: "cursor-default".into(),
            provider: Provider::CursorCloud,
            label: "Cursor Cloud".into(),
            available: connected && enabled(&user.id),
            experimental: false,
            reason: if !connected {
                Some("Connect a user API key on Core".into())
            } else if !enabled(&user.id) {
                Some("A bounded cloud canary must pass before activation".into())
            } else {
                None
            },
            capabilities: Capabilities {
                models: true,
                repository: true,
                follow_up: true,
                cancel: true,
                artifacts: true,
                detailed_events: true,
                ..Default::default()
            },
        },
    ];
    if std::env::var("CHATGPT_CLOUD_OWNER").as_deref() == Ok(user.id.as_str()) {
        if let Ok(profiles) =
            crate::api::runners::chatgpt_ui::configured_profile_dirs(&state.config.working_dir)
        {
            for slot in crate::api::runners::chatgpt_ui::profile_pool::pool_snapshot(&profiles) {
                accounts.retain(|a| a.id != "chatgpt-pool");
                let validated = std::env::var("CHATGPT_CLOUD_VALIDATED").as_deref() == Ok("1");
                accounts.push(Account {
                    id: slot.profile_name.clone(),
                    provider: Provider::Chatgpt,
                    label: chatgpt_account_label(&slot.profile_name),
                    available: validated && matches!(slot.state, crate::api::runners::chatgpt_ui::profile_pool::ProfileSlotState::Available | crate::api::runners::chatgpt_ui::profile_pool::ProfileSlotState::InUse),
                    experimental: true,
                    reason: if validated {
                        Some(format!("Browser pool: {:?}", slot.state))
                    } else {
                        Some("Browser cloud canary has not passed".into())
                    },
                    capabilities: Capabilities {
                        models: true,
                        follow_up: true,
                        artifacts: true,
                        ..Default::default()
                    },
                });
            }
        }
    }
    Json(accounts)
}
pub async fn options(Extension(user): Extension<AuthUser>) -> Result<Json<Value>, Error> {
    if !account_allowed(&user.id) {
        return Err((StatusCode::FORBIDDEN, "No connected Cursor account".into()));
    }
    let adapter = cursor::Cursor::from_account("cursor-default").map_err(bad)?;
    let (models, repositories) = tokio::join!(adapter.models(), adapter.repositories());
    let models = models.map_err(bad)?;
    let repositories = repositories.unwrap_or_else(|_| json!({"items":[]}));
    Ok(Json(
        json!({"models": models, "repositories": repositories}),
    ))
}
pub async fn get(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<Execution>, Error> {
    let store = state.control.get_or_spawn(&user).await.mission_store;
    Ok(Json(find(&store, id).await?))
}
async fn find(store: &Arc<dyn MissionStore>, id: Uuid) -> Result<Execution, Error> {
    store
        .cloud_executions()
        .await
        .map_err(bad)?
        .into_iter()
        .find(|e| e.mission_id == id)
        .ok_or((StatusCode::NOT_FOUND, "Cloud mission not found".into()))
}
pub async fn create(
    state: Arc<AppState>,
    user: AuthUser,
    req: CreateMissionRequest,
    mut selection: Selection,
) -> Result<(axum::http::HeaderMap, Json<Value>), Error> {
    if selection.provider != Provider::CursorCloud && !selection.model_params.is_empty() {
        return Err(bad("Model parameters are only supported by Cursor"));
    }
    if selection.provider != Provider::CursorCloud
        && (selection.repository.is_some() || selection.git_ref.is_some())
    {
        return Err(bad("This service does not accept repositories"));
    }
    if selection.provider == Provider::Chatgpt {
        if let Some(model) = selection.model.as_deref() {
            validate_chatgpt_model(model).map_err(bad)?;
        } else {
            selection.model = Some("gpt-6-pro".into());
        }
    }
    if req.track.is_some()
        || req.supersedes_mission_id.is_some()
        || req.writer == Some(true)
        || req.github_pr.is_some()
        || req.not_before.is_some()
        || req.deadline.is_some()
    {
        return Err(bad(
            "Cloud track ownership, writer grants and scheduled admission are not available yet",
        ));
    }
    if !req.extra.is_empty()
        || req.backend.is_some()
        || req.agent.is_some()
        || req.config_profile.is_some()
        || req.model_override.is_some()
        || req.model_effort.is_some()
        || req.fast_mode
    {
        return Err(bad(
            "Cloud execution accepts only service capabilities, not harness settings",
        ));
    }
    if req.remote_node_id.is_some()
        || req.placement.is_some()
        || req.working_directory.is_some()
        || req.workspace_id.is_some()
        || req.attachments.as_ref().is_some_and(|a| !a.is_empty())
    {
        return Err(bad(
            "Cloud missions do not expose Orb folders, machines or attachments",
        ));
    }
    let prompt = req
        .prompt
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| bad("prompt is required"))?
        .to_string();
    crate::api::mission_payload::validate_user_content(&prompt).map_err(bad)?;
    let key = req
        .idempotency_key
        .as_deref()
        .filter(|s| !s.is_empty() && s.len() <= 200)
        .ok_or_else(|| bad("Cloud launch requires an idempotency_key"))?
        .to_string();
    if selection
        .repository
        .as_deref()
        .is_some_and(|s| !s.starts_with("https://github.com/") || s.contains(['?', '#', '@']))
    {
        return Err(bad("Choose an authorized GitHub repository URL"));
    }
    use sha2::{Digest, Sha256};
    let request_signature = format!("{:x}", Sha256::digest(serde_json::to_vec(&json!({"selection": selection, "prompt": prompt, "title": req.title, "project": req.project, "tags": req.tags, "parent_mission_id": req.parent_mission_id})).map_err(|e| bad(e.to_string()))?));
    let store = state.control.get_or_spawn(&user).await.mission_store;
    if let Some(parent) = req.parent_mission_id {
        if store.get_mission(parent).await.map_err(bad)?.is_none() {
            return Err(bad("Parent mission is not owned by this user"));
        }
    }
    // An exact replay is read-only even if the provider is temporarily unavailable.
    if let Some(old) = store
        .cloud_executions()
        .await
        .map_err(bad)?
        .into_iter()
        .find(|e| e.request_key == key)
    {
        if old.request_signature != request_signature
            || old.selection != selection
            || old.turns.first().map(|t| t.prompt.as_str()) != Some(prompt.as_str())
        {
            return Err((StatusCode::CONFLICT, "Launch key already used".into()));
        }
        let mission = store
            .get_mission(old.mission_id)
            .await
            .map_err(bad)?
            .ok_or_else(|| bad("Mission missing"))?;
        return Ok((Default::default(), Json(json!(mission))));
    }
    let discovered = accounts(State(state.clone()), Extension(user.clone()))
        .await
        .0;
    if !discovered
        .iter()
        .any(|a| a.id == selection.account && a.provider == selection.provider && a.available)
    {
        return Err(bad("This cloud account has not passed activation checks"));
    }
    if selection.provider == Provider::CursorCloud {
        cursor::Cursor::from_account(&selection.account)
            .map_err(bad)?
            .availability()
            .await
            .map_err(bad)?;
    }
    let execution = Execution {
        parent_mission_id: req.parent_mission_id,
        mission_id: Uuid::new_v4(),
        request_key: key.clone(),
        request_signature,
        revision: 0,
        selection,
        external_id: None,
        external_url: None,
        turns: vec![Turn::new(key, prompt)],
    };
    let execution = store
        .save_cloud_execution(
            execution,
            None,
            req.title,
            req.project,
            req.tags.unwrap_or_default(),
        )
        .await
        .map_err(bad)?;
    if let Some(origin) = req.origin.as_deref() {
        store
            .set_mission_origin(
                execution.mission_id,
                origin,
                req.origin_session_id.as_deref(),
            )
            .await
            .map_err(bad)?;
    }
    let mission = store
        .get_mission(execution.mission_id)
        .await
        .map_err(bad)?
        .ok_or_else(|| bad("Mission missing"))?;
    Ok((Default::default(), Json(json!(mission))))
}
pub async fn follow_up(
    store: Arc<dyn MissionStore>,
    req: &ControlMessageRequest,
) -> Result<Option<Json<ControlMessageResponse>>, Error> {
    let Some(mid) = req.mission_id else {
        return Ok(None);
    };
    let Some(mut execution) = store
        .cloud_executions()
        .await
        .map_err(bad)?
        .into_iter()
        .find(|e| e.mission_id == mid)
    else {
        return Ok(None);
    };
    if req.attachments.as_ref().is_some_and(|a| !a.is_empty()) {
        return Err(bad("Attachments are not supported by this connector"));
    }
    // Hosted services only take a prompt and a model: refuse controls they
    // would silently ignore instead of reporting acceptance.
    let unsupported: Vec<&str> = [
        ("agent", req.agent.is_some()),
        ("github_pr", req.github_pr.is_some()),
        ("track", req.track.is_some()),
        ("title", req.title.is_some()),
    ]
    .into_iter()
    .filter_map(|(name, set)| set.then_some(name))
    .chain(
        req.extra
            .keys()
            .map(String::as_str)
            .filter(|key| !matches!(*key, "cloud_model" | "cloud_model_params")),
    )
    .collect();
    if !unsupported.is_empty() {
        return Err(bad(format!(
            "Unsupported fields for a cloud follow-up: {}",
            unsupported.join(", ")
        )));
    }
    let key = req
        .client_message_id
        .ok_or_else(|| bad("Cloud follow-ups require client_message_id"))?;
    let model = req
        .extra
        .get("cloud_model")
        .map(|v| {
            v.as_str()
                .ok_or_else(|| bad("cloud_model must be a model identifier"))
        })
        .transpose()?
        .map(str::to_owned);
    let model_params: Vec<ModelParam> = req
        .extra
        .get("cloud_model_params")
        .map(|value| {
            serde_json::from_value(value.clone()).map_err(|_| bad("Invalid model parameters"))
        })
        .transpose()?
        .unwrap_or_default();
    if !model_params.is_empty()
        && (execution.selection.provider != Provider::CursorCloud || model.is_none())
    {
        return Err(bad("Model parameters require an explicit Cursor model"));
    }
    if let Some(value) = &model {
        match execution.selection.provider {
            Provider::Chatgpt => validate_chatgpt_model(value).map_err(bad)?,
            Provider::CursorCloud => {
                if value.is_empty() || value.len() > 200 {
                    return Err(bad("Invalid model identifier"));
                }
            }
            Provider::GrokBot => return Err(bad("Grok Bot does not expose model selection")),
        }
    }
    if let Some(old) = execution.turns.iter().find(|t| t.key == key.to_string()) {
        if old.model != model || old.model_params != model_params {
            return Err(bad("Message key already used with a different model"));
        }
    }
    let revision = execution.revision;
    execution
        .enqueue(key.to_string(), req.content.clone())
        .map_err(bad)?;
    if let Some(turn) = execution
        .turns
        .iter_mut()
        .find(|t| t.key == key.to_string())
    {
        turn.model = model.clone();
        turn.model_params = model_params.clone();
    }
    commit_follow_up(
        &store,
        execution,
        revision,
        key,
        &req.content,
        &model,
        &model_params,
    )
    .await
    .map_err(bad)?;
    Ok(Some(Json(ControlMessageResponse {
        id: key,
        queued: true,
        message_accepted: true,
        mission_id: Some(mid),
        previous_execution: None,
        warnings: vec![],
    })))
}
async fn commit_follow_up(
    store: &Arc<dyn MissionStore>,
    execution: Execution,
    revision: u64,
    key: Uuid,
    prompt: &str,
    model: &Option<String>,
    model_params: &[ModelParam],
) -> Result<(), String> {
    let mid = execution.mission_id;
    if let Err(error) = store
        .save_cloud_execution(execution, Some(revision), None, None, vec![])
        .await
    {
        // A concurrent retry may already have committed this exact message.
        // Never overwrite the winner or acknowledge a key with different content.
        let accepted = if error == "Cloud execution revision changed" {
            store
                .cloud_executions()
                .await?
                .iter()
                .find(|e| e.mission_id == mid)
                .is_some_and(|e| {
                    e.turns.iter().any(|t| {
                        t.key == key.to_string()
                            && t.prompt == prompt
                            && &t.model == model
                            && t.model_params == model_params
                    })
                })
        } else {
            false
        };
        if !accepted {
            return Err(error);
        }
    }
    Ok(())
}

pub async fn cancel(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, Error> {
    let store = state.control.get_or_spawn(&user).await.mission_store;
    let mut e = find(&store, id).await?;
    if !matches!(
        e.selection.provider,
        Provider::CursorCloud | Provider::GrokBot
    ) {
        return Err(bad("Cancellation is not supported by this connector"));
    }
    let revision = e.revision;
    let t = e
        .turns
        .iter_mut()
        .find(|t| !t.phase.terminal())
        .ok_or_else(|| bad("No active run"))?;
    if t.phase == Phase::Queued {
        t.phase = Phase::Cancelled;
    } else if t.external_id.is_some() {
        t.phase = Phase::CancelRequested;
    } else {
        return Err(bad("Reconcile the submission before cancelling"));
    }
    store
        .save_cloud_execution(e, Some(revision), None, None, vec![])
        .await
        .map_err(bad)?;
    Ok(Json(json!({"cancel_requested":true})))
}

pub async fn events(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<Vec<Event>>, Error> {
    let store = state.control.get_or_spawn(&user).await.mission_store;
    find(&store, id).await?;
    Ok(Json(store.cloud_events(id).await.map_err(bad)?))
}
#[derive(Deserialize)]
pub struct ArtifactQuery {
    path: String,
}
pub async fn artifact(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    axum::extract::Query(query): axum::extract::Query<ArtifactQuery>,
) -> Result<Json<Value>, Error> {
    let store = state.control.get_or_spawn(&user).await.mission_store;
    let e = find(&store, id).await?;
    if !e.turns.iter().any(|t| {
        t.artifacts
            .iter()
            .any(|a| a["path"].as_str() == Some(query.path.as_str()))
    }) {
        return Err(bad("Artifact is not in this mission's results"));
    }
    if e.selection.provider == Provider::Chatgpt {
        use base64::Engine;
        let root = state
            .config
            .working_dir
            .join(".sandboxed-sh/cloud-artifacts")
            .join(id.to_string())
            .canonicalize()
            .map_err(|_| bad("Artifact directory unavailable"))?;
        let path = root
            .join(&query.path)
            .canonicalize()
            .map_err(|_| bad("Artifact unavailable"))?;
        if !path.starts_with(&root) || !path.is_file() {
            return Err(bad("Artifact path is outside this mission"));
        }
        if tokio::fs::metadata(&path)
            .await
            .map_err(|_| bad("Artifact unavailable"))?
            .len()
            > 50 * 1024 * 1024
        {
            return Err(bad("Artifact exceeds the 50 MiB limit"));
        }
        let bytes = tokio::fs::read(&path)
            .await
            .map_err(|_| bad("Artifact unavailable"))?;
        return Ok(Json(
            json!({"name":path.file_name().and_then(|n|n.to_str()).unwrap_or("artifact"),"content_base64":base64::engine::general_purpose::STANDARD.encode(bytes)}),
        ));
    }
    let agent = e
        .external_id
        .ok_or_else(|| bad("Missing external identity"))?;
    Ok(Json(
        cursor::Cursor::from_account(&e.selection.account)
            .map_err(bad)?
            .artifact_url(&agent, &query.path)
            .await
            .map_err(bad)?,
    ))
}

fn validate_chatgpt_model(model: &str) -> Result<(), String> {
    if [
        "gpt-6-instant",
        "gpt-6-medium",
        "gpt-6-high",
        "gpt-6-extra-high",
        "gpt-6-pro",
        "gpt-5.6-pro",
    ]
    .contains(&model)
    {
        Ok(())
    } else {
        Err("This ChatGPT model has not been verified in the browser".into())
    }
}
pub async fn chatgpt_options(Extension(user): Extension<AuthUser>) -> Result<Json<Value>, Error> {
    if std::env::var("CHATGPT_CLOUD_OWNER").as_deref() != Ok(user.id.as_str()) {
        return Err((StatusCode::FORBIDDEN, "No connected ChatGPT account".into()));
    }
    Ok(Json(
        json!({"models":{"items":[{"id":"gpt-6-instant","displayName":"GPT-6 Instant"},{"id":"gpt-6-medium","displayName":"GPT-6 Medium"},{"id":"gpt-6-high","displayName":"GPT-6 High"},{"id":"gpt-6-extra-high","displayName":"GPT-6 Extra High"},{"id":"gpt-6-pro","displayName":"GPT-6 Pro"}]}}),
    ))
}

fn chatgpt_account_label(profile: &str) -> String {
    let identity = std::env::var("CHATGPT_CLOUD_IDENTITIES_FILE")
        .ok()
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|data| data.get(profile).and_then(Value::as_str).map(str::to_owned));
    match identity {
        Some(email) => format!("ChatGPT · {email} · {profile}"),
        None => format!("ChatGPT · {profile}"),
    }
}

#[cfg(test)]
mod follow_up_tests {
    use super::*;
    use crate::api::mission_store::SqliteMissionStore;
    #[tokio::test]
    async fn follow_ups_reject_controls_a_hosted_service_would_ignore() {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().into(), "fields")
                .await
                .unwrap(),
        );
        let mut first = Turn::new("first".into(), "hello".into());
        first.phase = Phase::ResponseComplete;
        let e = Execution {
            parent_mission_id: None,
            mission_id: Uuid::new_v4(),
            request_key: "launch".into(),
            request_signature: "launch".into(),
            revision: 0,
            selection: Selection {
                provider: Provider::Chatgpt,
                account: "chatgpt-profile".into(),
                repository: None,
                git_ref: None,
                model: None,
                model_params: vec![],
            },
            external_id: None,
            external_url: None,
            turns: vec![first],
        };
        let e = store
            .save_cloud_execution(e, None, None, None, vec![])
            .await
            .unwrap();
        for extra in [json!({"track": "t"}), json!({"cloud_modle": "gpt"})] {
            let mut body = json!({"mission_id": e.mission_id, "content": "again", "client_message_id": Uuid::new_v4()});
            body.as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            let req: ControlMessageRequest = serde_json::from_value(body).unwrap();
            assert!(follow_up(store.clone(), &req).await.is_err(), "{extra}");
        }
        assert_eq!(store.cloud_executions().await.unwrap()[0].turns.len(), 1);
    }

    #[tokio::test]
    async fn overlapping_retries_accept_the_same_turn_and_reject_changed_content() {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().into(), "retry")
                .await
                .unwrap(),
        );
        let e = Execution {
            parent_mission_id: None,
            mission_id: Uuid::new_v4(),
            request_key: "launch".into(),
            request_signature: "launch".into(),
            revision: 0,
            selection: Selection {
                provider: Provider::CursorCloud,
                account: "cursor-default".into(),
                repository: None,
                git_ref: None,
                model: None,
                model_params: vec![],
            },
            external_id: None,
            external_url: None,
            turns: vec![Turn::new("first".into(), "hello".into())],
        };
        let mut e = store
            .save_cloud_execution(e, None, None, None, vec![])
            .await
            .unwrap();
        let revision = e.revision;
        let key = Uuid::new_v4();
        e.enqueue(key.to_string(), "continue".into()).unwrap();
        let (a, b) = tokio::join!(
            commit_follow_up(&store, e.clone(), revision, key, "continue", &None, &[]),
            commit_follow_up(&store, e.clone(), revision, key, "continue", &None, &[]),
        );
        a.unwrap();
        b.unwrap();
        assert_eq!(store.cloud_executions().await.unwrap()[0].turns.len(), 2);
        assert!(
            commit_follow_up(&store, e.clone(), revision, key, "changed", &None, &[])
                .await
                .is_err()
        );
        assert!(commit_follow_up(
            &store,
            e,
            revision,
            key,
            "continue",
            &Some("different".into()),
            &[]
        )
        .await
        .is_err());
    }
}
