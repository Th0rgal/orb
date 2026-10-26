//! Claude subscription models, as listed by the installed Claude Code CLI.
//!
//! Anthropic OAuth has no catalog endpoint this backend may call (see
//! docs/MODEL_CATALOG.md), so the subscription picker used to depend on the
//! reviewed snapshot alone and lagged every release. The CLI already knows
//! which models its account can use: the stream-json `initialize` control
//! request returns them. That handshake starts no turn and sends no inference
//! request, so a refresh costs no quota.
//!
//! The result supplements the Anthropic subscription list; it never removes a
//! snapshot model. A failed probe keeps the last successful list.

use crate::api::providers::ProviderModel;
use serde_json::Value;
use std::sync::RwLock;
use std::time::Duration;

const REQUEST_ID: &str = "orb-model-discovery";
const TIMEOUT: Duration = Duration::from_secs(30);
const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;

fn cache() -> &'static RwLock<Vec<ProviderModel>> {
    static CACHE: std::sync::OnceLock<RwLock<Vec<ProviderModel>>> = std::sync::OnceLock::new();
    CACHE.get_or_init(Default::default)
}

/// Last successful CLI listing; empty until a probe succeeds.
pub fn cached() -> Vec<ProviderModel> {
    cache().read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Probe the CLI and keep its list when it returned any models.
pub async fn refresh(cli: &str) -> Result<usize, String> {
    let models = discover(cli).await?;
    let count = models.len();
    *cache().write().unwrap_or_else(|e| e.into_inner()) = models;
    Ok(count)
}

/// The CLI the Claude Code runner launches.
pub fn configured_cli() -> String {
    crate::api::mission_runner::get_backend_string_setting("claudecode", "cli_path")
        .or_else(|| std::env::var("CLAUDE_CLI_PATH").ok())
        .unwrap_or_else(|| "claude".to_string())
}

async fn discover(cli: &str) -> Result<Vec<ProviderModel>, String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let mut child = tokio::process::Command::new(cli)
        .args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
        ])
        .current_dir(std::env::temp_dir())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| "Claude Code CLI is unavailable".to_string())?;
    let request = serde_json::json!({
        "type": "control_request",
        "request_id": REQUEST_ID,
        "request": {"subtype": "initialize"},
    });
    let mut stdin = child.stdin.take().ok_or("Claude Code stdin unavailable")?;
    stdin
        .write_all(format!("{request}\n").as_bytes())
        .await
        .map_err(|_| "Cannot write to Claude Code")?;
    // Closing stdin ends the session once the handshake is answered.
    drop(stdin);
    let stdout = child
        .stdout
        .take()
        .ok_or("Claude Code stdout unavailable")?;
    let result = tokio::time::timeout(TIMEOUT, async {
        let mut lines = tokio::io::BufReader::new(stdout).lines();
        let mut read = 0usize;
        while let Some(line) = lines
            .next_line()
            .await
            .map_err(|_| "Cannot read Claude Code output")?
        {
            read += line.len();
            if read > MAX_OUTPUT_BYTES {
                return Err("Claude Code output exceeded the discovery limit");
            }
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if let Some(models) = initialize_models(&value) {
                return if models.is_empty() {
                    Err("Claude Code listed no models")
                } else {
                    Ok(models)
                };
            }
        }
        Err("Claude Code exited without listing models")
    })
    .await;
    let _ = child.kill().await;
    result
        .map_err(|_| "Claude Code model discovery timed out".to_string())?
        .map_err(str::to_string)
}

/// Models from the `initialize` control response, or `None` for other lines.
///
/// Aliases (`opus`, `sonnet`, `default`) resolve to exact IDs; only exact
/// `claude-*` IDs are kept, once each, in the CLI's order.
pub(crate) fn initialize_models(value: &Value) -> Option<Vec<ProviderModel>> {
    if value.get("type")?.as_str()? != "control_response" {
        return None;
    }
    let response = value.get("response")?;
    if response.get("request_id").and_then(Value::as_str) != Some(REQUEST_ID) {
        return None;
    }
    let body = response.get("response").unwrap_or(response);
    let mut models: Vec<ProviderModel> = Vec::new();
    for entry in body.get("models")?.as_array()? {
        let alias = entry.get("value").and_then(Value::as_str).unwrap_or("");
        let Some(id) = entry
            .get("resolvedModel")
            .and_then(Value::as_str)
            .or(Some(alias).filter(|v| v.starts_with("claude-")))
            .map(str::trim)
            .filter(|id| is_model_id(id))
        else {
            continue;
        };
        if models.iter().any(|m| m.id == id) {
            continue;
        }
        models.push(ProviderModel {
            id: id.to_string(),
            name: display_name(id),
            description: entry
                .get("description")
                .and_then(Value::as_str)
                .filter(|_| alias != "default")
                .map(|d| d.chars().take(200).collect()),
        });
    }
    Some(models)
}

fn is_model_id(id: &str) -> bool {
    id.starts_with("claude-")
        && id.len() <= 100
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// `claude-sonnet-5-5` → `Claude Sonnet 5.5`; a release date is not shown.
fn display_name(id: &str) -> String {
    let mut words = Vec::new();
    let mut version = Vec::new();
    for part in id.trim_start_matches("claude-").split('-') {
        if part.len() >= 8 && part.bytes().all(|b| b.is_ascii_digit()) {
            break;
        }
        if part.bytes().all(|b| b.is_ascii_digit()) {
            version.push(part);
        } else {
            let mut chars = part.chars();
            if let Some(first) = chars.next() {
                words.push(first.to_uppercase().chain(chars).collect::<String>());
            }
        }
    }
    let mut name = format!("Claude {}", words.join(" "));
    if !version.is_empty() {
        name.push(' ');
        name.push_str(&version.join("."));
    }
    name
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn response(models: Value) -> Value {
        json!({"type":"control_response","response":{"subtype":"success","request_id":REQUEST_ID,"response":{"models":models}}})
    }

    #[test]
    fn resolves_aliases_to_exact_ids_once() {
        let models = initialize_models(&response(json!([
            {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · recommended"},
            {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus","description":"For complex work"},
            {"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet"},
            {"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku"},
            {"value":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"}
        ])))
        .unwrap();
        let ids: Vec<_> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "claude-opus-5-5",
                "claude-sonnet-5-5",
                "claude-haiku-5-5",
                "claude-haiku-4-5-20251001"
            ]
        );
        assert_eq!(models[0].name, "Claude Opus 5.5");
        // The `default` row describes the alias, not the model.
        assert_eq!(models[0].description, None);
        assert_eq!(models[3].name, "Claude Haiku 4.5");
    }

    #[test]
    fn ignores_other_lines_and_other_requests() {
        assert!(initialize_models(&json!({"type":"system","subtype":"init"})).is_none());
        let mut other = response(json!([{"value":"opus","resolvedModel":"claude-opus-5-5"}]));
        other["response"]["request_id"] = json!("someone-else");
        assert!(initialize_models(&other).is_none());
    }

    #[test]
    fn rejects_ids_that_are_not_claude_model_ids() {
        let models = initialize_models(&response(json!([
            {"value":"custom","resolvedModel":"https://example.com/x"},
            {"value":"default"},
            {"value":"claude-Opus-5"},
            {"value":"sonnet","resolvedModel":"claude-sonnet-5-5"}
        ])))
        .unwrap();
        let ids: Vec<_> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["claude-sonnet-5-5"]);
    }
}
