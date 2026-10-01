//! One control-plane tool catalogue, shared by Core and every MCP client.
mod actions;
mod assistant;
pub mod client;
mod cloud_read;
pub mod gateway;
pub mod launch;
mod orchestrator;
pub mod protocol;
mod scheduling;
mod schema;
mod workspace_ops;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub const CONTRACT_VERSION: &str = "1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    #[default]
    Executor,
    Coordinator,
    Operator,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handler {
    Assistant,
    Orchestrator,
    Capabilities,
    Workspace,
}

#[derive(Clone, Debug)]
pub struct Tool {
    pub definition: ToolDefinition,
    pub handler: Handler,
    pub minimum_role: Role,
    pub mutation: bool,
}

impl Tool {
    pub fn visible_to(&self, role: Role) -> bool {
        role == Role::Operator
            || self.minimum_role == Role::Executor
            || (role == Role::Coordinator && self.minimum_role == Role::Coordinator)
    }
}

/// Deliberately explicit and fail-closed: a new handler is not published until
/// its permission and side-effect policy have been chosen here.
fn policy(name: &str) -> Option<(Role, bool)> {
    use Role::*;
    Some(match name {
        "get_action"
        | "get_capabilities"
        | "get_mission"
        | "get_mission_events"
        | "get_mission_health"
        | "get_mission_diagnostics"
        | "list_mission_shared_files"
        | "list_cloud_models"
        | "list_cloud_accounts"
        | "get_cloud_execution"
        | "get_workspace_job" => (Executor, false),
        "schedule_wakeup"
        | "schedule_job_wakeup"
        | "ask_mission"
        | "start_mission"
        | "send_message_to_mission"
        | "answer_mission_question"
        | "cancel_mission"
        | "resume_mission"
        | "start_workspace_job"
        | "cancel_workspace_job" => (Executor, true),
        "list_active_missions"
        | "list_missions"
        | "get_chatgpt_ui_pool_status"
        | "get_compute_fleet"
        | "list_projects"
        | "get_project"
        | "get_situation"
        | "get_project_grant"
        | "get_project_tasks"
        | "list_workspaces"
        | "get_workspace"
        | "list_workspace_templates"
        | "get_workspace_template"
        | "board_status" => (Coordinator, false),
        "acknowledge_mission"
        | "adopt_mission"
        | "update_project_status"
        | "set_project_track"
        | "accept_project_track_evidence"
        | "reopen_project_track"
        | "accept_project_track"
        | "invalidate_project_track_evidence"
        | "add_project_steer"
        | "record_project_decision"
        | "answer_project_decision"
        | "plan_project_tasks"
        | "update_project_task"
        | "cancel_project_task"
        | "link_mission_to_project"
        | "update_mission_settings"
        | "plan_tasks"
        | "review_task"
        | "accept_task"
        | "reject_task" => (Coordinator, true),
        "get_backend_auth_status" => (Operator, false),
        "set_project_grant"
        | "create_workspace"
        | "update_workspace"
        | "delete_workspace"
        | "save_workspace_template"
        | "delete_workspace_template"
        | "rebuild_workspace_from_template"
        | "deploy_sandboxed_sh" => (Operator, true),
        // Superseded worker aliases and blocking asks/waits are not published.
        // Host-side worktree operations must not run on Core for a remote node.
        _ => return None,
    })
}

pub fn registry() -> Vec<Tool> {
    let mut entries = vec![Tool { definition: ToolDefinition {
        name: "get_capabilities".into(),
        description: "Read the authenticated identity, effective role, contract version, tools and limits. No work is started.".into(),
        input_schema: json!({"type":"object","properties":{},"additionalProperties":false}),
    }, handler: Handler::Capabilities, minimum_role: Role::Executor, mutation: false }];
    entries.push(Tool { definition: ToolDefinition {
        name: "get_action".into(), description: "Read an accepted action receipt and its result. A pending or uncertain action must never be submitted with a new key.".into(),
        input_schema: json!({"type":"object","required":["action_id"],"properties":{"action_id":{"type":"string","format":"uuid"}},"additionalProperties":false}),
    }, handler: Handler::Capabilities, minimum_role: Role::Executor, mutation: false });
    entries.push(Tool { definition: ToolDefinition {
        name: "cancel_action".into(), description: "Cancel an action that is still queued. Returns a durable cancellation receipt. Once dispatch started, cancellation is not claimed: inspect the target and use cancel_mission or cancel_workspace_job.".into(),
        input_schema: json!({"type":"object","required":["action_id","idempotency_key"],"properties":{
            "action_id":{"type":"string","format":"uuid"},
            "idempotency_key":{"type":"string","minLength":1,"maxLength":200}
        },"additionalProperties":false}),
    }, handler: Handler::Capabilities, minimum_role: Role::Executor, mutation: true });
    entries.push(Tool { definition:ToolDefinition {
        name:"reconcile_action".into(), description:"Operator-only: after inspecting the target, record evidence that an uncertain action completed or never took effect. This settles the original receipt without replaying work. Use the original mission/project session scope.".into(),
        input_schema:json!({"type":"object","required":["action_id","resolution","evidence","idempotency_key"],"properties":{
            "action_id":{"type":"string","format":"uuid"},"resolution":{"type":"string","enum":["completed","rejected"]},
            "evidence":{"type":"string","minLength":1,"maxLength":4096},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}
        },"additionalProperties":false}),
    }, handler:Handler::Capabilities, minimum_role:Role::Operator, mutation:true });
    entries.extend(workspace_ops::tools());
    for (handler, definitions) in [
        (Handler::Assistant, assistant::AssistantMcp::tools()),
        (
            Handler::Orchestrator,
            orchestrator::OrchestratorMcp::get_tools()
                .into_iter()
                .chain(scheduling::tools())
                .collect(),
        ),
    ] {
        for mut definition in definitions {
            let Some((minimum_role, mutation)) = policy(&definition.name) else {
                continue;
            };
            assert!(
                !entries.iter().any(|e| e.definition.name == definition.name),
                "duplicate MCP tool"
            );
            if definition.name == "start_mission" {
                definition.input_schema["properties"]["remote_node_id"] = json!({"type":"string","description":"Native node placement. Executors inherit their parent node; coordinators may select a registered node."});
                definition.description="Launch one native or cloud mission. Native launches select a backend/workspace/model; cloud launches select cloud.provider/account and optional repository/model. Discover cloud availability with list_cloud_accounts and list_cloud_models. Every role can use owner cloud accounts within quotas. Core supplies the parent identity for executors. Pass project/track and acceptance criteria for governed work; reviewers use writer=false. Mission completion and accepted project evidence remain separate.".into();
            }
            if definition.name == "send_message_to_mission" {
                definition.input_schema["properties"]
                    .as_object_mut()
                    .unwrap()
                    .remove("client_message_id");
                definition.description="Send a follow-up to an existing native or cloud mission. Core derives a stable message identity from the action key. Use answer_mission_question for a pending agent question; ordinary follow-ups may queue behind it.".into();
            }
            if matches!(
                definition.name.as_str(),
                "list_missions" | "list_active_missions"
            ) {
                definition.input_schema["properties"]["offset"] = json!({"type":"integer","minimum":0,"description":"Use the preceding page's next_offset; omit for the first page."});
                definition.description.push_str(" Results are bounded pages. Follow next_offset while non-null, including after an empty filtered page. Concurrent inserts may shift offsets; deduplicate by mission ID.");
            }
            for field in ["mission_id", "supersedes_mission_id"] {
                if let Some(schema) = definition.input_schema["properties"].get_mut(field) {
                    schema["format"] = json!("uuid");
                    schema["description"] = json!("Full mission UUID.");
                }
            }
            definition.input_schema["additionalProperties"] = json!(false);
            if mutation {
                definition.description.push_str(" Returns an action receipt immediately. Read its result with get_action; retry the same logical request with the same key.");
                definition.input_schema["properties"]["idempotency_key"] = json!({"type":"string","minLength":1,"maxLength":200,"description":"Stable key for this logical operation. Reuse after a lost response; never change its arguments."});
                let required = definition
                    .input_schema
                    .as_object_mut()
                    .unwrap()
                    .entry("required")
                    .or_insert(json!([]))
                    .as_array_mut()
                    .unwrap();
                if !required.iter().any(|v| v == "idempotency_key") {
                    required.push(json!("idempotency_key"));
                }
            }
            entries.push(Tool {
                definition,
                handler,
                minimum_role,
                mutation,
            });
        }
    }
    entries
}

pub fn catalog(role: Role) -> Vec<ToolDefinition> {
    registry()
        .into_iter()
        .filter(|t| t.visible_to(role))
        .map(|t| t.definition)
        .collect()
}

fn wire_catalog(role: Role) -> Vec<Value> {
    registry()
        .into_iter()
        .filter(|tool| tool.visible_to(role))
        .map(|tool| {
            let mut definition = json!(tool.definition);
            // These are client UX hints, never authorization. Core rechecks
            // scope and mutation permissions on every call and dispatch.
            definition["annotations"] = json!({
                "readOnlyHint": !tool.mutation,
                "destructiveHint": tool.mutation,
                "idempotentHint": true,
                "openWorldHint": true
            });
            definition
        })
        .collect()
}

pub(super) async fn execute(
    state: &std::sync::Arc<crate::api::routes::AppState>,
    principal: &gateway::Principal,
    api_url: String,
    token: String,
    mission: Option<Uuid>,
    tool: &Tool,
    arguments: Value,
) -> Result<Value, String> {
    match tool.handler {
        Handler::Assistant => {
            assistant::AssistantMcp::connected(api_url, token)
                .handle_call(&tool.definition.name, arguments)
                .await
        }
        Handler::Orchestrator => {
            let mission = match tool.definition.name.as_str() {
                "get_backend_auth_status" | "deploy_sandboxed_sh" => {
                    mission.unwrap_or_else(Uuid::nil)
                }
                _ => mission.ok_or("This operation requires a mission")?,
            };
            orchestrator::OrchestratorMcp::new(
                mission,
                api_url,
                Some(token),
                state.clone(),
                principal.clone(),
            )
            .handle_call(&tool.definition.name, arguments)
            .await
        }
        Handler::Capabilities | Handler::Workspace => {
            Err("Capabilities are handled by the authenticated gateway".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_annotations_match_the_authoritative_mutation_policy() {
        for role in [Role::Executor, Role::Coordinator, Role::Operator] {
            let tools = registry();
            let wire = wire_catalog(role);
            assert_eq!(wire.len(), catalog(role).len());
            for value in wire {
                let tool = tools
                    .iter()
                    .find(|t| t.definition.name == value["name"])
                    .unwrap();
                assert_eq!(value["annotations"]["readOnlyHint"], !tool.mutation);
                assert_eq!(value["annotations"]["destructiveHint"], tool.mutation);
                assert!(tool.visible_to(role));
            }
        }
    }
    #[test]
    fn roles_are_nested_and_cloud_is_available_to_every_agent() {
        for role in [Role::Executor, Role::Coordinator, Role::Operator] {
            let tools = catalog(role);
            for name in [
                "start_mission",
                "list_cloud_accounts",
                "list_cloud_models",
                "get_cloud_execution",
            ] {
                assert!(tools.iter().any(|t| t.name == name));
            }
            assert_eq!(
                tools.iter().any(|t| t.name == "deploy_sandboxed_sh"),
                role == Role::Operator
            );
        }
        assert!(policy("new_unreviewed_tool").is_none());
    }
    #[test]
    fn every_mutation_requires_a_retry_key_and_aliases_are_absent() {
        for tool in registry() {
            if tool.mutation {
                assert!(tool.definition.input_schema["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("idempotency_key")));
            }
            assert!(!tool.definition.name.starts_with("wait_for_"));
            assert!(![
                "create_worker_mission",
                "get_worker_status",
                "get_mission_digest"
            ]
            .contains(&tool.definition.name.as_str()));
        }
    }
}
