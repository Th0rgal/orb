//! Authenticated operator API; node credentials stay on the control plane.
use super::routes::AppState;
use crate::agent_software::{self as software, Inventory, UpdateJob};
use crate::ai_providers::ProviderType;
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use std::{collections::HashMap, path::Path, sync::Arc, time::Duration};
type Error = (StatusCode, String);
fn bad(e: String) -> Error {
    (StatusCode::BAD_REQUEST, e)
}
#[derive(Default, Deserialize)]
pub struct Params {
    pub node: Option<String>,
    #[serde(default)]
    pub force: bool,
}
#[derive(Deserialize, serde::Serialize)]
pub struct Update {
    pub component: String,
    pub version: String,
    pub path: String,
}
#[derive(Deserialize, serde::Serialize)]
pub struct Cancel {
    pub id: String,
}
async fn remote(
    state: &AppState,
    node: &str,
    method: reqwest::Method,
    suffix: &str,
    body: Option<serde_json::Value>,
) -> Result<reqwest::Response, Error> {
    let config = state
        .config
        .remote_nodes
        .node(node)
        .ok_or((StatusCode::NOT_FOUND, "Machine not found".into()))?;
    let token = crate::remote_node::node_token(&config.token_env).map_err(|_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "Machine credentials unavailable".into(),
        )
    })?;
    let mut request = state
        .http_client
        .request(
            method,
            format!(
                "{}/software{}",
                config.base_url.trim_end_matches('/'),
                suffix
            ),
        )
        .bearer_auth(token)
        .timeout(Duration::from_secs(90));
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request
        .send()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "Machine unavailable".into()))?;
    if !response.status().is_success() {
        return Err((
            StatusCode::from_u16(response.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            if response.status().as_u16() == 404 {
                "Runtime update required".into()
            } else {
                "Machine software request failed".into()
            },
        ));
    }
    Ok(response)
}
struct CoreHarnessAuth {
    claude: bool,
    codex: bool,
    opencode: bool,
    grok_key: bool,
    grok_core_local: bool,
    agy_routing: bool,
    agy_core_local: bool,
    vibe: bool,
}

async fn core_harness_auth(state: &AppState) -> CoreHarnessAuth {
    let providers = state.ai_providers.list().await;
    let has_provider = |pt: ProviderType| {
        providers
            .iter()
            .any(|p| p.enabled && p.provider_type == pt && p.has_credentials())
    };
    let any_provider = providers.iter().any(|p| p.enabled && p.has_credentials());
    let claude_secret = match &state.secrets {
        Some(store) => store
            .list_secrets("claudecode")
            .await
            .is_ok_and(|items| items.iter().any(|s| s.key == "api_key" && !s.is_expired)),
        None => false,
    };
    let claude = has_provider(ProviderType::Anthropic)
        || super::ai_providers::anthropic_cli_proxy_account_available()
        || claude_secret
        || Path::new("/var/lib/opencode/.claude/.credentials.json").exists()
        || Path::new("/root/.claude/.credentials.json").exists();
    let codex = has_provider(ProviderType::OpenAI)
        || super::ai_providers::openai_cli_proxy_account_available()
        || super::oauth_owner::codex_via_cli_proxy().is_some();
    let opencode = any_provider
        || claude
        || codex
        || super::ai_providers::google_cli_proxy_account_available();
    let grok_key = has_provider(ProviderType::Xai)
        || super::ai_providers::xai_cli_proxy_account_available()
        || super::ai_providers::get_xai_api_key_for_grok(&state.config.working_dir).is_some();
    let grok_core_local = Path::new("/root/.grok/auth.json").exists();
    let agy_routing = super::antigravity_native::routing_credential_for_model(
        Some(&state.config.working_dir),
        None,
    )
    .is_some();
    let agy_core_local =
        Path::new("/root/.gemini/antigravity-cli/antigravity-oauth-token").exists();
    let vibe = crate::backend::vibe::core_auth_configured(&state.config.working_dir).await;
    CoreHarnessAuth {
        claude,
        codex,
        opencode,
        grok_key,
        grok_core_local,
        agy_routing,
        agy_core_local,
        vibe,
    }
}

fn apply_readiness(
    auth: &CoreHarnessAuth,
    node: Option<&str>,
    is_managed_vm: bool,
    managed_agy_allowed: bool,
    heartbeat_managed_auth: Option<&[String]>,
    inventory: &mut Inventory,
) {
    for comp in &mut inventory.components {
        if !comp.installed {
            comp.ready = Some(false);
            comp.ready_detail = Some("CLI is not installed on this machine.".into());
            continue;
        }
        let (ready, detail): (Option<bool>, &str) = match (node, comp.id.as_str()) {
            (_, "claudecode") => (
                Some(auth.claude),
                if auth.claude {
                    "Authenticated via Core Anthropic provider."
                } else {
                    "Connect an Anthropic account or API key in Providers."
                },
            ),
            (_, "codex") => (
                Some(auth.codex),
                if auth.codex {
                    "Authenticated via Core OpenAI / Codex provider."
                } else {
                    "Connect an OpenAI / ChatGPT account in Providers."
                },
            ),
            (_, "opencode") => (
                Some(auth.opencode),
                if auth.opencode {
                    "Authenticated via Core model proxy."
                } else {
                    "Configure at least one AI provider in Providers."
                },
            ),
            (None, "grok") => {
                let ok = auth.grok_key || auth.grok_core_local;
                (
                    Some(ok),
                    if ok {
                        "Authenticated via xAI provider or Core Grok login."
                    } else {
                        "Configure xAI in Providers or sign in with grok login."
                    },
                )
            }
            (Some(_), "grok") => {
                if is_managed_vm {
                    (
                        Some(false),
                        "Managed VMs do not carry a Grok login; use OpenCode, Codex, or Claude Code.",
                    )
                } else if let Some(profiles) = heartbeat_managed_auth {
                    let node_grok = profiles.iter().any(|p| p == "grok");
                    let ok = node_grok || auth.grok_key;
                    (
                        Some(ok),
                        if node_grok {
                            "Node Grok managed-auth profile verified."
                        } else if auth.grok_key {
                            "Authenticated via Core xAI API key."
                        } else {
                            "Node has no verified Grok login (SANDBOXED_NODE_GROK_HOME) or xAI API key."
                        },
                    )
                } else {
                    (None, "")
                }
            }
            (None, "antigravity") => {
                let ok = auth.agy_routing || auth.agy_core_local;
                (
                    Some(ok),
                    if ok {
                        "Google Antigravity login configured."
                    } else {
                        "Connect Google Antigravity in Providers."
                    },
                )
            }
            (Some(_), "antigravity") => {
                if is_managed_vm {
                    let ok = managed_agy_allowed && auth.agy_routing;
                    (
                        Some(ok),
                        if ok {
                            "Core Antigravity login projects on launch."
                        } else if !auth.agy_routing {
                            "Connect Google Antigravity in Providers."
                        } else {
                            "Antigravity sign-in projection onto managed VMs is disabled."
                        },
                    )
                } else {
                    let node_agy = heartbeat_managed_auth
                        .is_some_and(|p| p.iter().any(|x| x == "antigravity"));
                    let ok = node_agy || auth.agy_routing;
                    (
                        Some(ok),
                        if node_agy {
                            "Node Antigravity managed-auth profile verified."
                        } else if auth.agy_routing {
                            "Core Antigravity login syncs to node on launch."
                        } else {
                            "Connect Google Antigravity in Providers or sign in on node."
                        },
                    )
                }
            }
            (Some(_), "vibe") if is_managed_vm => (
                Some(false),
                "Managed VMs do not run native Vibe; use OpenCode, Codex, or Claude Code.",
            ),
            (_, "vibe") => (
                Some(auth.vibe),
                if auth.vibe {
                    "Authenticated via Core Mistral proxy."
                } else {
                    "Connect a Mistral API key or subscription in Providers."
                },
            ),
            _ => (None, ""),
        };
        comp.ready = ready;
        comp.ready_detail = (!detail.is_empty()).then(|| detail.to_string());
    }
}

pub async fn inventory(
    State(state): State<Arc<AppState>>,
    Query(q): Query<Params>,
) -> Result<Json<Inventory>, Error> {
    let auth = core_harness_auth(&state).await;
    if let Some(node) = q.node {
        let mut result: Inventory = remote(
            &state,
            &node,
            reqwest::Method::GET,
            if q.force { "?force=true" } else { "" },
            None,
        )
        .await?
        .json()
        .await
        .map_err(|_| bad("Invalid machine inventory".into()))?;
        software::releases(&mut result, false).await;
        let is_managed_vm = crate::managed::is_managed_node(&node);
        let managed_agy_allowed = state
            .managed()
            .is_some_and(|m| m.runtime_settings().antigravity_on_managed);
        let heartbeat_auth = state
            .fleet
            .get(&node)
            .and_then(|s| s.last_heartbeat.map(|hb| hb.managed_auth));
        apply_readiness(
            &auth,
            Some(&node),
            is_managed_vm,
            managed_agy_allowed,
            heartbeat_auth.as_deref(),
            &mut result,
        );
        return Ok(Json(result));
    }
    let overrides: HashMap<String, String> = state
        .backend_configs
        .list()
        .await
        .into_iter()
        .filter_map(|c| {
            c.settings
                .get("cli_path")
                .and_then(|p| p.as_str())
                .filter(|p| !p.trim().is_empty())
                .map(|p| (c.id.clone(), p.to_string()))
        })
        .collect();
    let mut result = tokio::task::spawn_blocking(move || {
        if q.force {
            software::clear_versions();
        }
        software::scan("Execution service", &overrides)
    })
    .await
    .map_err(|e| bad(e.to_string()))?;
    software::releases(&mut result, q.force).await;
    apply_readiness(&auth, None, false, false, None, &mut result);
    Ok(Json(result))
}
pub async fn update(
    State(state): State<Arc<AppState>>,
    Query(q): Query<Params>,
    Json(body): Json<Update>,
) -> Result<Json<UpdateJob>, Error> {
    if let Some(node) = q.node {
        return remote(
            &state,
            &node,
            reqwest::Method::POST,
            "/updates",
            serde_json::to_value(body).ok(),
        )
        .await?
        .json()
        .await
        .map(Json)
        .map_err(|_| bad("Invalid update receipt".into()));
    }
    tokio::task::spawn_blocking(move || software::queue(&body.component, &body.version, &body.path))
        .await
        .map_err(|e| bad(e.to_string()))?
        .map(Json)
        .map_err(bad)
}
pub async fn cancel(
    State(state): State<Arc<AppState>>,
    Query(q): Query<Params>,
    Json(body): Json<Cancel>,
) -> Result<Json<serde_json::Value>, Error> {
    if let Some(node) = q.node {
        remote(
            &state,
            &node,
            reqwest::Method::POST,
            "/updates/cancel",
            serde_json::to_value(body).ok(),
        )
        .await?;
    } else {
        software::cancel(&body.id).map_err(bad)?;
    }
    Ok(Json(serde_json::json!({"ok":true})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_software::{Component, Runtime};

    fn component(id: &str, installed: bool) -> Component {
        Component {
            id: id.into(),
            name: id.into(),
            version: installed.then(|| "1.0.0".into()),
            path: installed.then(|| format!("/usr/local/bin/{id}")),
            installed,
            owner: "Fleet installer".into(),
            update_supported: true,
            latest: Some("1.0.0".into()),
            release_error: None,
            running: vec![],
            instructions: String::new(),
            ready: None,
            ready_detail: None,
        }
    }

    #[test]
    fn remote_readiness_distinguishes_static_node_profiles_and_managed_vms() {
        let auth = CoreHarnessAuth {
            claude: true,
            codex: true,
            opencode: true,
            grok_key: false,
            grok_core_local: false,
            agy_routing: true,
            agy_core_local: false,
            vibe: true,
        };
        let mut inv = Inventory {
            checked_at: 1,
            components: vec![
                component("claudecode", true),
                component("grok", true),
                component("antigravity", true),
                component("vibe", false),
            ],
            runtime: Runtime {
                name: "Node runner".into(),
                version: "0.1.0".into(),
                build: "test".into(),
                path: None,
                restart_required: false,
                running: vec![],
            },
            jobs: vec![],
        };
        apply_readiness(&auth, Some("nimrud"), false, false, Some(&[]), &mut inv);
        assert_eq!(inv.components[0].ready, Some(true));
        assert_eq!(
            inv.components[1].ready,
            Some(false),
            "grok without node managed-auth or xAI key is marked not ready"
        );
        assert_eq!(
            inv.components[2].ready,
            Some(true),
            "antigravity with Core routing login is ready via sync-on-launch"
        );
        assert_eq!(
            inv.components[3].ready,
            Some(false),
            "missing vibe is marked not ready"
        );

        apply_readiness(
            &auth,
            Some("nimrud"),
            false,
            false,
            Some(&["grok".to_string()]),
            &mut inv,
        );
        assert_eq!(inv.components[1].ready, Some(true));

        apply_readiness(
            &auth,
            Some("managed-boat-1"),
            true,
            false,
            Some(&[]),
            &mut inv,
        );
        assert_eq!(inv.components[1].ready, Some(false));
        assert_eq!(inv.components[2].ready, Some(false));
    }
}
