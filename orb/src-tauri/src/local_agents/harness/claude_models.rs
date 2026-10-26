//! Models this computer's Claude Code can run, from the stream-json
//! `initialize` handshake. No turn starts and no inference request is sent.

use super::*;
use std::io::{BufRead, BufReader, Write};

const REQUEST_ID: &str = "orb-model-discovery";
const TIMEOUT: Duration = Duration::from_secs(30);
const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;

/// `(exact id, label)` for the newest model of each class the CLI offers.
///
/// The CLI's class aliases (`opus`, `sonnet`, …) resolve to its current
/// releases; older pinned rows are omitted, like Core's picker policy.
pub(crate) fn models(bin: &str) -> Result<Vec<(String, String)>, String> {
    let mut child = harness_command(bin)
        .args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
        ])
        .current_dir(std::env::temp_dir())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "Claude Code is unavailable".to_string())?;
    let request = json!({
        "type": "control_request",
        "request_id": REQUEST_ID,
        "request": {"subtype": "initialize"},
    });
    if let Some(mut stdin) = child.stdin.take() {
        // Closing stdin ends the session once the handshake is answered.
        let _ = writeln!(stdin, "{request}");
    }
    let stdout = child
        .stdout
        .take()
        .ok_or("Claude Code output unavailable")?;
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let mut read = 0usize;
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            read += line.len();
            if read > MAX_OUTPUT_BYTES {
                break;
            }
            if let Some(models) = serde_json::from_str::<Value>(&line)
                .ok()
                .and_then(|value| initialize_models(&value))
            {
                let _ = tx.send(models);
                return;
            }
        }
    });
    let result = rx.recv_timeout(TIMEOUT);
    let _ = child.kill();
    let _ = child.wait();
    match result {
        Ok(models) if !models.is_empty() => Ok(models),
        Ok(_) => Err("Claude Code listed no models".into()),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            Err("Claude Code model discovery timed out".into())
        }
        Err(_) => Err("Sign in with claude on this computer".into()),
    }
}

fn initialize_models(value: &Value) -> Option<Vec<(String, String)>> {
    if value.get("type")?.as_str()? != "control_response" {
        return None;
    }
    let response = value.get("response")?;
    if response.get("request_id").and_then(Value::as_str) != Some(REQUEST_ID) {
        return None;
    }
    let body = response.get("response").unwrap_or(response);
    let mut models: Vec<(String, String)> = Vec::new();
    for entry in body.get("models")?.as_array()? {
        let alias = entry.get("value").and_then(Value::as_str).unwrap_or("");
        // Exact rows are pinned older releases; `default` repeats a class.
        if alias.is_empty() || alias == "default" || alias.starts_with("claude-") {
            continue;
        }
        let Some(id) = entry
            .get("resolvedModel")
            .and_then(Value::as_str)
            .filter(|id| is_model_id(id))
        else {
            continue;
        };
        if !models.iter().any(|(known, _)| known == id) {
            models.push((id.to_string(), display_name(id)));
        }
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
    use std::os::unix::fs::PermissionsExt;

    const RESPONSE: &str = r#"{"type":"control_response","response":{"subtype":"success","request_id":"orb-model-discovery","response":{"models":[{"value":"default","resolvedModel":"claude-sonnet-5-5"},{"value":"opus","resolvedModel":"claude-opus-5-5"},{"value":"fable","resolvedModel":"claude-fable-5-1"},{"value":"sonnet","resolvedModel":"claude-sonnet-5-5"},{"value":"haiku","resolvedModel":"claude-haiku-5-5"},{"value":"claude-opus-4-8","resolvedModel":"claude-opus-4-8"}]}}}"#;

    #[test]
    fn lists_the_current_release_of_each_class() {
        let value: Value = serde_json::from_str(RESPONSE).unwrap();
        assert_eq!(
            initialize_models(&value).unwrap(),
            [
                ("claude-opus-5-5".to_string(), "Claude Opus 5.5".to_string()),
                (
                    "claude-fable-5-1".to_string(),
                    "Claude Fable 5.1".to_string()
                ),
                (
                    "claude-sonnet-5-5".to_string(),
                    "Claude Sonnet 5.5".to_string()
                ),
                (
                    "claude-haiku-5-5".to_string(),
                    "Claude Haiku 5.5".to_string()
                ),
            ]
        );
    }

    #[test]
    fn reads_the_handshake_from_the_cli() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("claude");
        // Like the real CLI: answer the handshake, then wait for input to close.
        std::fs::write(
            &bin,
            format!(
                "#!/bin/sh\necho '{{\"type\":\"system\"}}'\necho '{RESPONSE}'\ncat >/dev/null\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        let models = models(&bin.to_string_lossy()).unwrap();
        assert_eq!(models.len(), 4);
        assert_eq!(models[2].0, "claude-sonnet-5-5");
    }

    #[test]
    fn reports_a_cli_that_exits_without_a_handshake() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("claude");
        std::fs::write(&bin, "#!/bin/sh\nexit 1\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(models(&bin.to_string_lossy()).is_err());
    }
}
