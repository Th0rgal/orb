//! Git mutations follow the mission's durable placement, never Core's cwd.
use super::{gateway::Principal, Handler, Role, Tool, ToolDefinition};
use crate::api::{auth::AuthUser, routes::AppState};
use serde_json::{json, Value};
use std::{collections::HashMap, process::Stdio, sync::Arc};
use uuid::Uuid;

pub fn tools() -> Vec<Tool> {
    [
        ("create_worktree", vec!["path", "branch"], json!({"path":{"type":"string"},"branch":{"type":"string"},"base":{"type":"string"}}), "Create a Git worktree inside the mission workspace on its current machine. Paths are relative to the mission root. Specify repo_path when the checkout is in a subdirectory."),
        ("remove_worktree", vec!["path"], json!({"path":{"type":"string"}}), "Remove a clean worktree inside the mission workspace on its current machine. Dirty worktrees are preserved; forced removal is not supported."),
        ("merge_branch", vec!["source_branch", "target_branch"], json!({"source_branch":{"type":"string"},"target_branch":{"type":"string"},"push":{"type":"boolean"},"delete_source":{"type":"boolean"}}), "Merge in the mission workspace on its current machine. The checkout must be clean and already on target_branch. Conflicts are reported and the merge is aborted; assign a resolver after inspecting the receipt. Optional source deletion only removes fully merged branches."),
    ].into_iter().map(|(name, required, mut properties, description)| {
        properties["mission_id"] = json!({"type":"string","format":"uuid"});
        properties["repo_path"] = json!({"type":"string"});
        properties["idempotency_key"] = json!({"type":"string","minLength":1,"maxLength":200});
        let mut required = required;
        required.extend(["mission_id", "idempotency_key"]);
        Tool { definition: ToolDefinition { name:name.into(), description:description.into(), input_schema:json!({"type":"object","required":required,"properties":properties,"additionalProperties":false}) }, handler:Handler::Workspace, minimum_role:Role::Coordinator, mutation:true }
    }).collect()
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub async fn preflight(state: &Arc<AppState>, p: &Principal, args: &Value) -> Result<(), String> {
    let id = args["mission_id"]
        .as_str()
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or("Mission UUID required")?;
    let control = state
        .control
        .get_or_spawn(&AuthUser {
            id: p.sub.clone(),
            username: p.username.clone(),
        })
        .await;
    let mission = control
        .mission_store
        .get_mission(id)
        .await?
        .ok_or("Mission unavailable")?;
    if p.project
        .as_deref()
        .is_some_and(|project| mission.project.project.as_deref() != Some(project))
    {
        return Err("Mission is outside the project scope".into());
    }
    crate::api::control::machine_transfer::guard(&control.mission_store, id).await?;
    if crate::api::control::client_placement::is_tagged(&mission.project.tags) {
        return Err(
            "Workspace is owned by the desktop client; no Core command was executed".into(),
        );
    }
    let placement = crate::api::control::remote_grok::placement(
        &state.config.working_dir,
        &control.mission_store,
        id,
    )
    .await?;
    match placement {
        Some(placement) if state.config.remote_nodes.node(&placement.node_id).is_none() => {
            Err("Mission node unavailable".into())
        }
        None if state.workspaces.get(mission.workspace_id).await.is_none() => {
            Err("Mission workspace unavailable".into())
        }
        _ => Ok(()),
    }
}

pub async fn execute(
    state: &Arc<AppState>,
    p: &Principal,
    name: &str,
    mut args: Value,
) -> Result<Value, String> {
    let id = args["mission_id"]
        .as_str()
        .and_then(|s| Uuid::parse_str(s).ok())
        .ok_or("Mission UUID required")?;
    let control = state
        .control
        .get_or_spawn(&AuthUser {
            id: p.sub.clone(),
            username: p.username.clone(),
        })
        .await;
    let _workspace_mutation =
        crate::api::control::machine_transfer::workspace_mutation_lock(id).await;
    preflight(state, p, &args).await?;
    let mission = control
        .mission_store
        .get_mission(id)
        .await?
        .ok_or("Mission unavailable")?;
    crate::api::control::machine_transfer::guard(&control.mission_store, id).await?;
    if crate::api::control::client_placement::is_tagged(&mission.project.tags) {
        return Err(
            "Workspace is owned by the desktop client; no Core command was executed".into(),
        );
    }
    args["operation"] = json!(name);
    let script = include_str!("../../scripts/mcp_workspace_git.py");
    let placement = crate::api::control::remote_grok::placement(
        &state.config.working_dir,
        &control.mission_store,
        id,
    )
    .await?;
    let (stdout, machine) = if let Some(placement) = placement {
        let node = state
            .config
            .remote_nodes
            .node(&placement.node_id)
            .ok_or("Mission node unavailable")?;
        let secret =
            std::env::var(&node.token_env).map_err(|_| "Node authentication unavailable")?;
        let workspace_id = mission
            .project
            .tags
            .iter()
            .find_map(|tag| {
                tag.strip_prefix("fork-workspace:")
                    .and_then(|s| Uuid::parse_str(s).ok())
            })
            .unwrap_or(id);
        let claims = crate::remote_node::LeaseClaims {
            mission_id: workspace_id,
            node_id: node.id.clone(),
            scope: crate::remote_node::SCOPE_MISSION_EXECUTE.into(),
            expires_at: (chrono::Utc::now() + chrono::Duration::minutes(15)).timestamp(),
            job_id: None,
        };
        let prefix =
            match crate::api::control::machine_transfer::committed(&control.mission_store, id)
                .await?
            {
                Some(t) => format!(
                    "cd -- {} || exit 78; ",
                    quote(&t.destination_root.ok_or("Transferred workspace missing")?)
                ),
                None => String::new(),
            };
        let request = crate::remote_node::LeaseRequest {
            mission_id: workspace_id,
            node_id: node.id.clone(),
            lease_token: crate::remote_node::create_lease_token(&claims, &secret)
                .map_err(|_| "Cannot issue node lease")?,
            command: format!(
                "{prefix}exec python3 -c {} {}",
                quote(script),
                quote(&args.to_string())
            ),
        };
        let result = crate::remote_node::RemoteNodeClient::default()
            .execute(node, &secret, &request)
            .await
            .map_err(|_| "Node operation outcome unknown")?;
        if !result.accepted {
            return Err("Node refused workspace operation".into());
        }
        (result.stdout, node.id.clone())
    } else {
        let workspace = state
            .workspaces
            .get(mission.workspace_id)
            .await
            .ok_or("Mission workspace unavailable")?;
        let cwd = crate::api::durable_jobs::resolve_mission_job_cwd(
            &workspace,
            id,
            mission.working_directory.as_deref(),
            None,
        )?;
        let exec = crate::workspace_exec::WorkspaceExec::new(workspace);
        let child = exec
            .spawn_with_stdio(
                &cwd,
                "python3",
                &["-c".into(), script.into(), args.to_string()],
                HashMap::new(),
                Stdio::null(),
                Stdio::piped(),
                Stdio::piped(),
                Uuid::new_v4(),
            )
            .await
            .map_err(|_| "Workspace operation could not start")?;
        let output = child
            .wait_with_output()
            .await
            .map_err(|_| "Workspace operation outcome unknown")?;
        (
            String::from_utf8(output.stdout).map_err(|_| "Invalid workspace receipt")?,
            "core".into(),
        )
    };
    let mut result: Value = serde_json::from_str(&stdout).map_err(|_| {
        "Workspace operation produced no valid receipt; inspect target before retrying"
    })?;
    result["machine"] = json!(machine);
    result["mission_id"] = json!(id);
    Ok(result)
}
