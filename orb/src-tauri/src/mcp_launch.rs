//! The desktop exchanges its owner login for a mission credential. Only the
//! scoped credential reaches the harness; no project file chooses the launcher.
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};

fn executable() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("SANDBOXED_MCP_BIN") {
        let path = PathBuf::from(path);
        if !path.is_absolute() || !path.is_file() {
            return Err("SANDBOXED_MCP_BIN must point to an installed executable".into());
        }
        return Ok(path);
    }
    if let Ok(current) = std::env::current_exe() {
        candidates.push(current.with_file_name("sandboxed-mcp"));
        #[cfg(test)]
        if let Some(debug) = current.parent().and_then(|path| path.parent()) {
            candidates.push(debug.join("sandboxed-mcp"));
        }
    }
    candidates.push(PathBuf::from("/usr/local/bin/sandboxed-mcp"));
    candidates.into_iter().find(|path| path.is_file()).ok_or_else(||
        "The sandboxed-mcp companion is missing. Install it or set SANDBOXED_MCP_BIN before launching Orb.".into())
}

pub async fn environment(
    mission: &str,
    base: &str,
    owner: &str,
) -> Result<Vec<(String, String)>, String> {
    uuid::Uuid::parse_str(mission).map_err(|_| "Invalid MCP mission identity")?;
    let url = reqwest::Url::parse(base).map_err(|_| "Invalid Core URL")?;
    if url.scheme() != "https"
        && !(url.scheme() == "http"
            && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")))
    {
        return Err("MCP credentials require HTTPS or a loopback Core".into());
    }
    let binary = executable()?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| "Cannot initialize MCP connection")?;
    let response = client
        .post(format!("{}/api/mcp/session", base.trim_end_matches('/')))
        .bearer_auth(owner)
        .json(&json!({"role":"executor","mission_id":mission}))
        .send()
        .await
        .map_err(|_| "Cannot authorize this mission's MCP connection")?;
    if !response.status().is_success() {
        return Err(format!(
            "Core refused the mission MCP session ({})",
            response.status()
        ));
    }
    let value: Value = response
        .json()
        .await
        .map_err(|_| "Invalid MCP session response")?;
    if value["contract_version"] != "1" {
        return Err("Core and Orb use incompatible MCP contracts".into());
    }
    let credential = value["token"]
        .as_str()
        .filter(|token| token.starts_with("mcp1."))
        .ok_or("Core did not return a scoped MCP credential")?;
    Ok(vec![
        (
            "SANDBOXED_MCP_WRAPPER".into(),
            binary.to_string_lossy().into_owned(),
        ),
        ("SANDBOXED_MCP_API_URL".into(), base.into()),
        ("SANDBOXED_MCP_TOKEN".into(), credential.into()),
        ("SANDBOXED_SH_MISSION_ID".into(), mission.into()),
    ])
}
