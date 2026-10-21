//! Dial-out mode for `sandboxed-node` on machines with no inbound path
//! (managed boat.dev sandboxes).
//!
//! Enabled by `SANDBOXED_NODE_DIAL_CORE_URL`. On start the node exchanges the
//! one-time `SANDBOXED_NODE_ENROLL_TOKEN` for a node credential at
//! `<core>/api/managed-machines/enroll` (cached in
//! `SANDBOXED_NODE_CREDENTIAL_FILE`, default `<work>/../node.cred`, mode 0600,
//! so a restart does not need a fresh token). It then serves its normal API on
//! loopback and long-polls `<core>/api/managed-machines/relay/poll`,
//! replaying each request against that loopback listener.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::managed::relay::{RelayRequest, RelayResponse};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DialCredential {
    pub core_url: String,
    pub machine_id: String,
    pub node_id: String,
    pub node_token: String,
}

fn credential_path() -> PathBuf {
    if let Ok(p) = std::env::var("SANDBOXED_NODE_CREDENTIAL_FILE") {
        return PathBuf::from(p);
    }
    let work = std::env::var("SANDBOXED_NODE_WORK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/var/lib/sandboxed-node/work"));
    work.parent()
        .map(|p| p.join("node.cred"))
        .unwrap_or_else(|| PathBuf::from("node.cred"))
}

/// Enroll (or reuse a cached credential) when dial-out mode is configured.
/// Returns `None` for ordinary listening nodes.
pub async fn enroll_from_env() -> anyhow::Result<Option<DialCredential>> {
    let Some(core_url) = std::env::var("SANDBOXED_NODE_DIAL_CORE_URL")
        .ok()
        .map(|u| u.trim().trim_end_matches('/').to_string())
        .filter(|u| !u.is_empty())
    else {
        return Ok(None);
    };
    let machine_id = std::env::var("SANDBOXED_NODE_MANAGED_ID")
        .map_err(|_| anyhow::anyhow!("dial-out mode needs SANDBOXED_NODE_MANAGED_ID"))?;
    let path = credential_path();
    if let Ok(bytes) = std::fs::read(&path) {
        if let Ok(cred) = serde_json::from_slice::<DialCredential>(&bytes) {
            if cred.machine_id == machine_id && cred.core_url == core_url {
                tracing::info!("dial-out: reusing cached node credential");
                return Ok(Some(cred));
            }
        }
    }
    let token = std::env::var("SANDBOXED_NODE_ENROLL_TOKEN")
        .map_err(|_| anyhow::anyhow!("dial-out mode needs SANDBOXED_NODE_ENROLL_TOKEN"))?;
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()?;
    let mut last_error = String::new();
    for attempt in 0..30u64 {
        match http
            .post(format!("{core_url}/api/managed-machines/enroll"))
            .json(&json!({"machine_id": machine_id, "enroll_token": token}))
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                let v: serde_json::Value = resp.json().await?;
                let cred = DialCredential {
                    core_url: core_url.clone(),
                    machine_id: machine_id.clone(),
                    node_id: v["node_id"].as_str().unwrap_or_default().to_string(),
                    node_token: v["node_token"]
                        .as_str()
                        .ok_or_else(|| anyhow::anyhow!("enroll: no node_token"))?
                        .to_string(),
                };
                if let Some(dir) = path.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                std::fs::write(&path, serde_json::to_vec(&cred)?)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
                }
                tracing::info!(node_id = %cred.node_id, "dial-out: enrolled");
                return Ok(Some(cred));
            }
            Ok(resp) if resp.status().as_u16() == 401 => {
                anyhow::bail!("enrollment denied (token used, expired or wrong)");
            }
            Ok(resp) => last_error = format!("HTTP {}", resp.status()),
            Err(e) => last_error = e.without_url().to_string(),
        }
        tokio::time::sleep(Duration::from_secs((attempt + 1).min(10))).await;
    }
    anyhow::bail!("enrollment failed: {last_error}")
}

/// Run the relay loop forever (until Core answers 410 Gone).
pub fn spawn_relay(cred: DialCredential, local: SocketAddr) {
    tokio::spawn(async move {
        let poll_http = reqwest::Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_default();
        let local_http = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap_or_default();
        let mut backoff = 1u64;
        loop {
            let resp = poll_http
                .get(format!("{}/api/managed-machines/relay/poll", cred.core_url))
                .bearer_auth(&cred.node_token)
                .header("x-orb-machine-id", &cred.machine_id)
                .send()
                .await;
            match resp {
                Ok(r) if r.status().as_u16() == 410 => {
                    tracing::warn!("dial-out: Core says this machine is gone; exiting");
                    let _ = std::fs::remove_file(credential_path());
                    std::process::exit(0);
                }
                Ok(r) if r.status().is_success() => {
                    backoff = 1;
                    let requests: Vec<RelayRequest> = r.json().await.unwrap_or_default();
                    for req in requests {
                        let cred = cred.clone();
                        let local_http = local_http.clone();
                        let poll_http = poll_http.clone();
                        tokio::spawn(async move {
                            let resp = forward(&local_http, local, req).await;
                            // Results can be large; give the upload time.
                            let _ = poll_http
                                .post(format!(
                                    "{}/api/managed-machines/relay/respond",
                                    cred.core_url
                                ))
                                .timeout(Duration::from_secs(600))
                                .bearer_auth(&cred.node_token)
                                .header("x-orb-machine-id", &cred.machine_id)
                                .json(&resp)
                                .send()
                                .await;
                        });
                    }
                }
                Ok(r) => {
                    tracing::warn!(status = %r.status(), "dial-out: poll failed");
                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                    backoff = (backoff * 2).min(15);
                }
                Err(e) => {
                    tracing::warn!(error = %e.without_url(), "dial-out: poll error");
                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                    backoff = (backoff * 2).min(15);
                }
            }
        }
    });
}

async fn forward(http: &reqwest::Client, local: SocketAddr, req: RelayRequest) -> RelayResponse {
    let fail = |status: u16, msg: &str| RelayResponse {
        id: req.id.clone(),
        status,
        headers: vec![("content-type".into(), "text/plain".into())],
        body_b64: base64::engine::general_purpose::STANDARD.encode(msg),
    };
    let Ok(method) = reqwest::Method::from_bytes(req.method.as_bytes()) else {
        return fail(400, "bad method");
    };
    let body = base64::engine::general_purpose::STANDARD
        .decode(req.body_b64.as_bytes())
        .unwrap_or_default();
    let mut builder = http
        .request(method, format!("http://{local}{}", req.path))
        .timeout(Duration::from_secs(req.timeout_secs.max(30)))
        .body(body);
    for (k, v) in &req.headers {
        builder = builder.header(k, v);
    }
    match builder.send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let headers = resp
                .headers()
                .iter()
                .filter_map(|(k, v)| Some((k.to_string(), v.to_str().ok()?.to_string())))
                .collect();
            let bytes = resp.bytes().await.unwrap_or_default();
            RelayResponse {
                id: req.id.clone(),
                status,
                headers,
                body_b64: base64::engine::general_purpose::STANDARD.encode(&bytes),
            }
        }
        Err(e) => fail(
            502,
            &format!("local node request failed: {}", e.without_url()),
        ),
    }
}
