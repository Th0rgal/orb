//! Native `agy` runs use the Google login connected for model routing.
//!
//! The CLIProxyAPI file stays the only login store (see
//! [`super::cli_proxy_accounts`]); this module copies it into the native CLI
//! profile of the Core workspace that runs `agy`, and pushes it to a remote
//! node over the node's authenticated `/managed-auth/antigravity` endpoint. It
//! never travels inside a job payload.
use crate::antigravity_auth::{Credential, PROFILE_DIR};

/// The Antigravity login best suited to run `model` natively (switching to the
/// only account whose discovered catalog offers `model`, e.g. Gemini 4 Carbon).
pub(crate) fn routing_credential_for_model(
    work_dir: Option<&std::path::Path>,
    model: Option<&str>,
) -> Option<Credential> {
    let dir = super::cli_proxy_accounts::auth_dir()?;
    let file = super::antigravity_accounts::chosen_file_for_model(&dir, work_dir, model)?;
    super::cli_proxy_accounts::accounts_in(&dir)
        .into_iter()
        .find(|a| a.file == file)
        .map(|a| Credential {
            access_token: a.oauth.access_token,
            refresh_token: a.oauth.refresh_token,
            expires_at: a.oauth.expires_at,
        })
}

/// Project the routing login into `home` before `agy` starts there. Without a
/// connected login the machine's own `agy` sign-in, if any, is left alone.
pub(crate) fn install_in_home(home: &std::path::Path) {
    install_in_home_for_model(home, None, None);
}

pub(crate) fn install_in_home_for_model(
    home: &std::path::Path,
    work_dir: Option<&std::path::Path>,
    model: Option<&str>,
) {
    let Some(credential) = routing_credential_for_model(work_dir, model) else {
        return;
    };
    if let Err(error) = crate::antigravity_auth::install(&home.join(PROFILE_DIR), &credential) {
        tracing::warn!(home = %home.display(), "Antigravity sign-in not projected: {error}");
    }
}

/// Outcome of pushing the routing login to a node.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum NodeSync {
    /// The node holds the routing login and advertises the profile.
    Ready,
    /// No Google login is connected for model routing.
    NoLogin,
    /// The node predates the endpoint or keeps its own sign-in.
    Unsupported,
}

pub(crate) async fn sync_node(
    state: &super::routes::AppState,
    node_id: &str,
) -> Result<NodeSync, String> {
    sync_node_for_model(state, node_id, None).await
}

pub(crate) async fn sync_node_for_model(
    state: &super::routes::AppState,
    node_id: &str,
    model: Option<&str>,
) -> Result<NodeSync, String> {
    let Some(credential) = routing_credential_for_model(Some(&state.config.working_dir), model)
    else {
        return Ok(NodeSync::NoLogin);
    };
    let managed = crate::managed::is_managed_node(node_id);
    if managed {
        // Only the owner's own managed VMs, and only while the operator
        // setting allows it; never baked into the image, wiped on destroy.
        let allowed = match crate::managed::global() {
            Some(m) => m.antigravity_allowed(node_id).await,
            None => false,
        };
        if !allowed {
            return Err(format!(
                "Node '{node_id}' is a managed machine without Antigravity projection (setting off or not the owner's machine)"
            ));
        }
    }
    let node = if managed {
        state.config.remote_nodes.node(node_id)
    } else {
        state.config.remote_nodes.static_node(node_id)
    }
    .ok_or_else(|| format!("Unknown node '{node_id}'"))?;
    let token = crate::remote_node::node_token(&node.token_env)
        .map_err(|_| format!("Node '{node_id}' credential unavailable"))?;
    let pushed = crate::remote_node::RemoteNodeClient::default()
        .push_antigravity_credential(node, &token, &credential)
        .await;
    if managed && matches!(pushed, Ok(true)) {
        if let Some(m) = crate::managed::global() {
            m.mark_antigravity_projected(node_id).await;
        }
    }
    pushed
        .map(|accepted| {
            if accepted {
                NodeSync::Ready
            } else {
                NodeSync::Unsupported
            }
        })
        .map_err(|error| error.to_string())
}
