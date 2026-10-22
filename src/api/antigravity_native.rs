//! Native `agy` runs use the Google login connected for model routing.
//!
//! The CLIProxyAPI file stays the only login store (see
//! [`super::cli_proxy_accounts`]); this module copies it into the native CLI
//! profile of the Core workspace that runs `agy`, and pushes it to a remote
//! node over the node's authenticated `/managed-auth/antigravity` endpoint. It
//! never travels inside a job payload.
use crate::ai_providers::ProviderType;
use crate::antigravity_auth::{Credential, PROFILE_DIR};

/// The Antigravity login CLIProxyAPI routes with, if one is connected.
pub(crate) fn routing_credential() -> Option<Credential> {
    let dir = super::cli_proxy_accounts::auth_dir()?;
    super::cli_proxy_accounts::accounts_in(&dir)
        .into_iter()
        .filter(|a| {
            a.provider == ProviderType::Antigravity
                && !a.disabled
                && a.prefix.as_deref() == Some("antigravity")
        })
        .max_by(|a, b| {
            a.oauth
                .expires_at
                .cmp(&b.oauth.expires_at)
                .then_with(|| b.file.cmp(&a.file))
        })
        .map(|a| Credential {
            access_token: a.oauth.access_token,
            refresh_token: a.oauth.refresh_token,
            expires_at: a.oauth.expires_at,
        })
}

/// Project the routing login into `home` before `agy` starts there. Without a
/// connected login the machine's own `agy` sign-in, if any, is left alone.
pub(crate) fn install_in_home(home: &std::path::Path) {
    let Some(credential) = routing_credential() else {
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
    let Some(credential) = routing_credential() else {
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
