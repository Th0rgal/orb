//! Stage operator-provided conversation archives inside the side-agent workspace.
use super::*;
const STAGE: &str = include_str!("../../../scripts/orb_stage_conversation.py");

pub(super) fn snapshot_id(prompt: &str) -> Option<Uuid> {
    prompt.lines().find_map(|line| {
        line.strip_prefix("@conversation: .paloma/conversation/")?
            .strip_suffix("/conversation.json")?
            .parse()
            .ok()
    })
}

pub(super) fn remote_prefix(mission: &Mission, prompt: &str) -> String {
    if !mission
        .project
        .tags
        .iter()
        .any(|t| t.starts_with("btw-parent:"))
    {
        return String::new();
    }
    let Some(id) = snapshot_id(prompt) else {
        return String::new();
    };
    // Capture the node's upload root before the fork prefix changes directory.
    format!(
        "python3 -c {} \"$btw_upload_root\" {} || exit 78; ",
        shell_single_quote(STAGE),
        shell_single_quote(&id.to_string())
    )
}

#[derive(Deserialize)]
pub struct StageRequest {
    pub manifest_id: Uuid,
}

pub async fn stage(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(req): Json<StageRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mission = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "Mission not found".into()))?;
    if mission.project.tags.iter().any(|t| t == "placement:client")
        || remote_grok::placement(&state.config.working_dir, &control.mission_store, id)
            .await
            .map_err(internal_error)?
            .is_some()
    {
        return Err((
            StatusCode::CONFLICT,
            "Stage this snapshot on the mission's machine".into(),
        ));
    }
    let workspace = crate::workspace::resolve_workspace(
        &state.workspaces,
        &state.config,
        Some(mission.workspace_id),
    )
    .await;
    let root = mission
        .working_directory
        .as_ref()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| crate::workspace::mission_workspace_dir_for_workspace(&workspace, id));
    let uploads =
        super::super::mission_payload::storage_root(&state.config.working_dir).join("uploads");
    let output = tokio::process::Command::new("python3")
        .arg("-c")
        .arg(STAGE)
        .arg(uploads)
        .arg(req.manifest_id.to_string())
        .current_dir(root)
        .output()
        .await
        .map_err(internal_error)?;
    if !output.status.success() {
        return Err((
            StatusCode::CONFLICT,
            "Could not stage the conversation archive in this workspace".into(),
        ));
    }
    Ok(Json(
        serde_json::json!({"path":format!(".paloma/conversation/{}/conversation.json", req.manifest_id)}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshot_marker_accepts_only_a_canonical_workspace_reference() {
        let id = Uuid::new_v4();
        assert_eq!(
            snapshot_id(&format!(
                "@conversation: .paloma/conversation/{id}/conversation.json"
            )),
            Some(id)
        );
        assert_eq!(snapshot_id("@conversation: /etc/passwd"), None);
        assert_eq!(
            snapshot_id("@conversation: .paloma/conversation/../../etc/conversation.json"),
            None
        );
    }
}
