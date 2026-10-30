//! Thin client: authorization and execution are always performed by Core.
use super::{Role, CONTRACT_VERSION};
use serde_json::{json, Value};
use std::{path::PathBuf, sync::Arc};
use tokio::sync::Mutex;

fn persist_scoped_credential(path: &std::path::Path, token: &str) -> Result<(), String> {
    use std::io::Write;
    if !token.starts_with("mcp1.") {
        return Err("Core returned an invalid scoped credential".into());
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(std::path::Path::new("."));
    let mut staged = tempfile::NamedTempFile::new_in(parent)
        .map_err(|_| "Cannot refresh scoped credential file")?;
    staged
        .write_all(token.as_bytes())
        .map_err(|_| "Cannot refresh scoped credential file")?;
    staged
        .as_file()
        .sync_all()
        .map_err(|_| "Cannot persist scoped credential renewal")?;
    staged
        .persist(path)
        .map_err(|_| "Cannot replace scoped credential file")?;
    Ok(())
}

pub struct Client {
    api_url: String,
    token: String,
    token_file: Option<PathBuf>,
    role: Role,
    mission_id: Option<uuid::Uuid>,
    project: Option<String>,
    client_label: Option<String>,
    host_hint: Option<String>,
    secrets_dir_override: Option<PathBuf>,
    http: reqwest::Client,
    session: Mutex<Option<(String, i64)>>,
    resolved_session_id: Mutex<Option<uuid::Uuid>>,
}

fn decode_mcp_token_session_id(token: &str) -> Option<uuid::Uuid> {
    use base64::Engine as _;
    let jwt = token.strip_prefix("mcp1.")?;
    let payload_b64 = jwt.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload_b64))
        .ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v["session_id"]
        .as_str()
        .and_then(|s| uuid::Uuid::parse_str(s).ok())
}

impl Client {
    pub fn new(
        api_url: String,
        token: String,
        token_file: Option<PathBuf>,
        role: Role,
        mission_id: Option<uuid::Uuid>,
    ) -> Result<Self, String> {
        let parsed = reqwest::Url::parse(&api_url).map_err(|_| "Invalid Core URL")?;
        if parsed.scheme() != "https"
            && !(parsed.scheme() == "http"
                && matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")))
        {
            return Err("Core requires HTTPS except on loopback".into());
        }
        let initial_session_id = decode_mcp_token_session_id(&token);
        Ok(Self {
            api_url: api_url.trim_end_matches('/').into(),
            token,
            token_file,
            role,
            mission_id,
            project: None,
            client_label: None,
            host_hint: None,
            secrets_dir_override: None,
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|_| "Cannot initialize HTTP client")?,
            session: Mutex::new(None),
            resolved_session_id: Mutex::new(initial_session_id),
        })
    }
    async fn credential(&self) -> Result<String, String> {
        let raw = if let Some(path) = &self.token_file {
            tokio::fs::read_to_string(path)
                .await
                .map_err(|_| "Cannot read MCP credential file")?
        } else {
            self.token.clone()
        };
        let token = raw.trim();
        if token.is_empty() {
            return Err("Missing MCP credential".into());
        }
        Ok(token.into())
    }
    pub(super) async fn token(&self) -> Result<String, String> {
        let credential = self.credential().await?;
        let mut session = self.session.lock().await;
        if let Some((token, expiry)) = session.as_ref() {
            if *expiry > chrono::Utc::now().timestamp() + 120 {
                return Ok(token.clone());
            }
        }
        if credential.starts_with("mcp1.") && session.is_none() {
            if let Some(sid) = decode_mcp_token_session_id(&credential) {
                *self.resolved_session_id.lock().await = Some(sid);
            }
            let response = self
                .http
                .get(format!("{}/api/mcp/capabilities", self.api_url))
                .bearer_auth(&credential)
                .send()
                .await
                .map_err(|_| "Core is unavailable")?;
            // A queued remote job may start after its credential expired;
            // renewal below still accepts it while the mission is live.
            if response.status() != reqwest::StatusCode::UNAUTHORIZED {
                if !response.status().is_success() {
                    return Err(format!(
                        "Core refused scoped session ({})",
                        response.status()
                    ));
                }
                let caps: Value = response
                    .json()
                    .await
                    .map_err(|_| "Invalid capabilities response")?;
                if let Some(sid) = caps["identity"]["session_id"]
                    .as_str()
                    .and_then(|s| uuid::Uuid::parse_str(s).ok())
                {
                    *self.resolved_session_id.lock().await = Some(sid);
                }
                let expiry = caps["limits"]["session_expires_at"]
                    .as_i64()
                    .ok_or("Missing session expiry")?;
                *session = Some((credential.clone(), expiry));
                // When explicit --client-label / --host-hint are passed on an
                // existing mcp1 token, fall through to one renewal so Core updates
                // the session's label/host hint.
                if expiry > chrono::Utc::now().timestamp() + 120
                    && self.client_label.is_none()
                    && self.host_hint.is_none()
                {
                    return Ok(credential);
                }
            }
        }
        let scoped = credential.starts_with("mcp1.");
        let auth = if self.token_file.is_some() {
            credential
        } else {
            session
                .as_ref()
                .map(|(token, _)| token.clone())
                .filter(|_| scoped)
                .unwrap_or(credential)
        };
        let (path, payload) = if scoped {
            let mut body = serde_json::Map::new();
            if let Some(ref label) = self.client_label {
                body.insert("client_label".into(), json!(label));
            }
            if let Some(ref host) = self.host_hint {
                body.insert("host_hint".into(), json!(host));
            }
            ("/api/mcp/renew", Value::Object(body))
        } else if let Some(mission_id) = self.mission_id {
            (
                "/api/mcp/session",
                json!({
                    "role": self.role,
                    "mission_id": mission_id,
                    "project": self.project,
                }),
            )
        } else {
            return Err(
                "Missionless MCP clients require a pre-issued `mcp1.*` external session credential \
                 (mint one in Orb Settings -> Security -> External MCP Sessions and pass \
                 SANDBOXED_MCP_TOKEN or --token-file)"
                    .into(),
            );
        };
        let response = self
            .http
            .post(format!("{}{path}", self.api_url))
            .bearer_auth(auth)
            .json(&payload)
            .send()
            .await
            .map_err(|_| "Cannot reach Core to establish MCP session")?;
        if !response.status().is_success() {
            return Err(format!("Core refused MCP session ({})", response.status()));
        }
        let data: Value = response
            .json()
            .await
            .map_err(|_| "Invalid MCP session response")?;
        let token = data["token"]
            .as_str()
            .ok_or("Missing session token")?
            .to_string();
        if let Some(sid) = data["session_id"]
            .as_str()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .or_else(|| decode_mcp_token_session_id(&token))
        {
            *self.resolved_session_id.lock().await = Some(sid);
        }
        if scoped {
            if let Some(path) = &self.token_file {
                persist_scoped_credential(path, &token)?;
            }
        }
        *session = Some((
            token.clone(),
            data["expires_at"].as_i64().ok_or("Missing expiry")?,
        ));
        Ok(token)
    }
    async fn request(&self, path: &str, body: Option<&Value>) -> Result<Value, String> {
        for attempt in 0..2 {
            let token = self.token().await?;
            let request = if let Some(body) = body {
                self.http.post(format!("{}{path}", self.api_url)).json(body)
            } else {
                self.http.get(format!("{}{path}", self.api_url))
            };
            let response = request.bearer_auth(token).send().await.map_err(|_| {
                "Core connection failed; acceptance is unknown for a submitted mutation"
            })?;
            if response.status() == reqwest::StatusCode::UNAUTHORIZED && attempt == 0 {
                // Auth middleware rejected this request before tool execution.
                // Renew once using the same scoped credential/mission; never
                // retry ambiguous transport failures or escalate to owner auth.
                if let Some((_, expiry)) = self.session.lock().await.as_mut() {
                    *expiry = 0;
                }
                continue;
            }
            if !response.status().is_success() {
                return Err(format!("Core rejected request ({})", response.status()));
            }
            return response
                .json()
                .await
                .map_err(|_| "Invalid Core response".into());
        }
        Err("Core rejected the renewed scoped session; check mission authorization".into())
    }
    pub async fn preflight(&self) -> Result<Value, String> {
        let v = self.request("/api/mcp/capabilities", None).await?;
        if let Some(sid) = v["identity"]["session_id"]
            .as_str()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
        {
            *self.resolved_session_id.lock().await = Some(sid);
        }
        if v["contract_version"] != CONTRACT_VERSION {
            return Err("MCP contract version mismatch".into());
        }
        Ok(v)
    }
    async fn secrets_dir_for_session(&self) -> PathBuf {
        if let Some(ref dir) = self.secrets_dir_override {
            return dir.clone();
        }
        let session_id = *self.resolved_session_id.lock().await;
        secrets_dir_for(self.mission_id, session_id)
    }
    pub async fn fetch_secret_file(
        &self,
        name: &str,
        reason: Option<&str>,
        wait_secs: u64,
    ) -> Result<(PathBuf, String), String> {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return Err("Secret name cannot be empty".into());
        }
        let mut tool_args = json!({ "name": trimmed });
        if let Some(r) = reason.map(str::trim).filter(|s| !s.is_empty()) {
            tool_args["reason"] = json!(r);
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(wait_secs);
        loop {
            let call_body = json!({
                "name": "secret_get",
                "arguments": tool_args,
            });
            let reply = self.request("/api/mcp/call", Some(&call_body)).await?;
            if reply["ok"] != true {
                let msg = reply["error"]["message"]
                    .as_str()
                    .unwrap_or("Secret request refused by Core");
                return Err(msg.to_string());
            }
            let result = reply["result"].clone();
            if result.get("secret_delivery").is_some() {
                let dir = self.secrets_dir_for_session().await;
                let delivered = deliver_secret_in(&dir, result);
                if let Some(err) = delivered.get("error").and_then(Value::as_str) {
                    return Err(err.to_string());
                }
                let path_str = delivered["path"]
                    .as_str()
                    .ok_or("Missing delivered secret file path")?;
                let export_line = delivered["export"]
                    .as_str()
                    .ok_or("Missing delivered secret export line")?
                    .to_string();
                return Ok((PathBuf::from(path_str), export_line));
            }
            if result["status"] == "pending" {
                let req_id = result["request_id"]
                    .as_str()
                    .and_then(|s| uuid::Uuid::parse_str(s).ok())
                    .ok_or("Core returned pending secret request without a valid request_id")?;
                let now = std::time::Instant::now();
                if now >= deadline {
                    return Err(format!(
                        "Timed out waiting for approval of secret `{trimmed}` (request {req_id})"
                    ));
                }
                while std::time::Instant::now() < deadline {
                    let remaining = deadline
                        .saturating_duration_since(std::time::Instant::now())
                        .as_secs()
                        .clamp(1, 25);
                    let wait_path =
                        format!("/api/mcp/requests/secret/{req_id}/wait?timeout_secs={remaining}");
                    let waited = self.request(&wait_path, None).await?;
                    match waited["status"].as_str().unwrap_or("pending") {
                        "approved" => break,
                        "denied" => {
                            let err = waited["error"]
                                .as_str()
                                .filter(|s| !s.is_empty())
                                .unwrap_or("Operator denied access");
                            return Err(format!("Access to secret `{trimmed}` denied: {err}"));
                        }
                        "expired" => {
                            return Err(format!("Approval request for secret `{trimmed}` expired"));
                        }
                        _ => {
                            if std::time::Instant::now() >= deadline {
                                return Err(format!(
                                    "Timed out waiting for approval of secret `{trimmed}` (request {req_id})"
                                ));
                            }
                        }
                    }
                }
                // Re-call secret_get on the next loop iteration to receive secret_delivery.
                continue;
            }
            return Err(format!(
                "Unexpected response from secret_get for `{trimmed}`: {}",
                result["status"].as_str().unwrap_or("unknown")
            ));
        }
    }
    pub async fn handle(&self, request: Value) -> Value {
        let id = request["id"].clone();
        let result = match request["method"].as_str().unwrap_or("") {
            "initialize" => match self.preflight().await {
                Ok(_) => Ok(
                    json!({"protocolVersion":"2024-11-05","serverInfo":{"name":"sandboxed-mcp","version":env!("CARGO_PKG_VERSION")},"capabilities":{"tools":{}}}),
                ),
                Err(e) => Err((-32000, e)),
            },
            "ping" => Ok(json!({})),
            "tools/list" => self
                .preflight()
                .await
                .map(|v| json!({"tools":v["tools"]}))
                .map_err(|e| (-32000, e)),
            "tools/call" => {
                let params = &request["params"];
                if !params["name"].is_string() {
                    Err((-32602, "Missing tool name".into()))
                } else {
                    let body = json!({"name":params["name"],"arguments":params.get("arguments").cloned().unwrap_or(json!({}))});
                    let reply = match self.request("/api/mcp/call", Some(&body)).await {
                        Ok(v) => v,
                        Err(message) => {
                            json!({"ok":false,"error":{"code":"transport_unavailable","message":message,"accepted":"unknown","retryable":false}})
                        }
                    };
                    let failed = reply["ok"] != true;
                    let payload = if failed {
                        json!({"error":reply["error"]})
                    } else {
                        let dir = self.secrets_dir_for_session().await;
                        deliver_secret_in(&dir, reply["result"].clone())
                    };
                    let structured = if payload.is_object() {
                        payload
                    } else {
                        json!({"data":payload})
                    };
                    Ok(
                        json!({"isError":failed,"structuredContent":structured,"content":[{"type":"text","text":structured.to_string()}]}),
                    )
                }
            }
            _ => Err((-32601, "Method not found".into())),
        };
        match result {
            Ok(v) => json!({"jsonrpc":"2.0","id":id,"result":v}),
            Err((code, message)) => {
                json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
            }
        }
    }
}

/// Directory for secrets handed to this mission or external session, under a
/// per-user base (never the shared temp dir, where another user could own a parent).
fn secrets_dir_for(
    mission_id: Option<uuid::Uuid>,
    session_id: Option<uuid::Uuid>,
) -> std::path::PathBuf {
    secrets_dir_with_env(
        mission_id,
        session_id,
        std::env::var_os("SANDBOXED_SECRETS_DIR").map(PathBuf::from),
        std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from),
        std::env::var_os("HOME").map(PathBuf::from),
        std::env::var("SANDBOXED_SH_MISSION_ID")
            .or_else(|_| std::env::var("MISSION_ID"))
            .ok(),
    )
}

fn secrets_dir_with_env(
    mission_id: Option<uuid::Uuid>,
    session_id: Option<uuid::Uuid>,
    override_dir: Option<PathBuf>,
    xdg_runtime_dir: Option<PathBuf>,
    home_dir: Option<PathBuf>,
    env_mission_id: Option<String>,
) -> std::path::PathBuf {
    if let Some(dir) = override_dir {
        return dir;
    }
    let base = xdg_runtime_dir
        .map(|d| d.join("paloma-secrets"))
        .or_else(|| home_dir.map(|h| h.join(".paloma-secrets")))
        .unwrap_or_else(|| PathBuf::from(".paloma-secrets"));
    let subdir = if let Some(mid) = mission_id {
        mid.to_string()
    } else if let Some(env_mid) = env_mission_id.filter(|s| !s.trim().is_empty()) {
        env_mid
    } else if let Some(sid) = session_id {
        format!("session-{sid}")
    } else {
        "session".into()
    };
    base.join(subdir.replace(['/', '.'], "_"))
}

/// Create `dir` (and its parent) as 0700 and refuse anything that is a
/// symlink or owned by another user.
#[cfg(unix)]
fn ensure_private_dir(dir: &std::path::Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let check = |d: &std::path::Path| -> std::io::Result<()> {
        let meta = std::fs::symlink_metadata(d)?;
        if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "{} is not a private directory owned by this user",
                    d.display()
                ),
            ));
        }
        Ok(())
    };
    for d in [dir.parent(), Some(dir)].into_iter().flatten() {
        match std::fs::DirBuilder::new().mode(0o700).create(d) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        check(d)?;
    }
    Ok(())
}

/// Core returns a secret as `secret_delivery`; write it to a 0600 file and
/// replace it with the path, so the value never enters the agent transcript,
/// the harness logs or Core's event store.
fn deliver_secret_in(dir: &std::path::Path, mut result: Value) -> Value {
    let Some(delivery) = result
        .as_object_mut()
        .and_then(|o| o.remove("secret_delivery"))
    else {
        return result;
    };
    let name = delivery["name"].as_str().unwrap_or("");
    let value = delivery["value"].as_str().unwrap_or("");
    let safe = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if !safe {
        result["error"] = json!("Secret name is not a safe file name; value withheld");
        return result;
    }
    let dir = dir.to_path_buf();
    let path = dir.join(name);
    let written = (|| -> std::io::Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            if let Some(parent) = dir.parent().and_then(|p| p.parent()) {
                std::fs::create_dir_all(parent)?;
            }
            ensure_private_dir(&dir)?;
            let tmp = dir.join(format!(".{name}.{}.tmp", uuid::Uuid::new_v4()));
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&tmp)?;
            std::io::Write::write_all(&mut f, value.as_bytes())?;
            std::fs::rename(&tmp, &path)?;
        }
        #[cfg(not(unix))]
        std::fs::write(&path, value)?;
        Ok(())
    })();
    match written {
        Ok(()) => {
            let shown = path.display().to_string();
            result["path"] = json!(shown);
            result["export"] = json!(format!("export {name}=\"$(cat '{shown}')\""));
            result["message"] = json!("Value written to the private file at `path`. Load it with the `export` line; never print it.");
        }
        Err(e) => {
            result["error"] = json!(format!("Could not write the secret file: {e}"));
        }
    }
    result
}

#[derive(Debug, PartialEq, Eq)]
enum SecretCliCommand {
    Get {
        name: String,
        reason: Option<String>,
        wait_secs: u64,
        output: SecretGetOutput,
    },
    Env {
        names: Vec<String>,
        reason: Option<String>,
        wait_secs: u64,
    },
    Exec {
        names: Vec<String>,
        reason: Option<String>,
        wait_secs: u64,
        command: Vec<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SecretGetOutput {
    Path,
    Export,
}

const DEFAULT_SECRET_WAIT_SECS: u64 = 120;

fn is_global_value_flag(flag: &str) -> bool {
    matches!(
        flag,
        "--api-url"
            | "--token-file"
            | "--mission-id"
            | "--profile"
            | "--project"
            | "--client-label"
            | "--host-hint"
    )
}

/// Extract any `secret <get|env|exec>` subcommand from CLI args while tolerating
/// global `--api-url` / `--token-file` / `--client-label` / `--host-hint` flags
/// before or after `secret`.
fn parse_secret_subcommand(args: &[String]) -> Result<Option<SecretCliCommand>, String> {
    let mut i = 1usize;
    let mut secret_pos = None;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--" {
            break;
        }
        if is_global_value_flag(a) {
            i += 2;
            continue;
        }
        if a.starts_with('-') {
            i += 1;
            continue;
        }
        if a == "secret" {
            secret_pos = Some(i);
        }
        break;
    }
    let Some(pos) = secret_pos else {
        return Ok(None);
    };
    let rest = &args[pos + 1..];
    let sub = rest
        .first()
        .map(String::as_str)
        .ok_or("Usage: sandboxed-mcp secret <get|env|exec> ...")?;
    let tail = &rest[1..];
    match sub {
        "get" => {
            let mut name: Option<String> = None;
            let mut reason: Option<String> = None;
            let mut wait_secs = DEFAULT_SECRET_WAIT_SECS;
            let mut print_path = false;
            let mut print_export = false;
            let mut idx = 0usize;
            while idx < tail.len() {
                let arg = tail[idx].as_str();
                if is_global_value_flag(arg) {
                    if idx + 1 >= tail.len() {
                        return Err(format!("Missing value for {arg}"));
                    }
                    idx += 2;
                } else if arg == "--reason" {
                    let val = tail.get(idx + 1).ok_or("Missing value for --reason")?;
                    reason = Some(val.clone());
                    idx += 2;
                } else if arg == "--wait-secs" {
                    let val = tail.get(idx + 1).ok_or("Missing value for --wait-secs")?;
                    wait_secs = val
                        .parse::<u64>()
                        .map_err(|_| "Invalid integer for --wait-secs")?;
                    idx += 2;
                } else if arg == "--print-path" {
                    print_path = true;
                    idx += 1;
                } else if arg == "--print-export" {
                    print_export = true;
                    idx += 1;
                } else if arg.starts_with('-') {
                    return Err(format!("Unknown flag for `secret get`: {arg}"));
                } else if name.is_none() {
                    name = Some(arg.to_string());
                    idx += 1;
                } else {
                    return Err(format!(
                        "Unexpected extra argument `{arg}` for `secret get`"
                    ));
                }
            }
            if print_path && print_export {
                return Err("Specify at most one of --print-path or --print-export".into());
            }
            let name = name.ok_or("Usage: sandboxed-mcp secret get <NAME> [--reason ...] [--wait-secs 120] [--print-path | --print-export]")?;
            let output = if print_export {
                SecretGetOutput::Export
            } else {
                SecretGetOutput::Path
            };
            Ok(Some(SecretCliCommand::Get {
                name,
                reason,
                wait_secs,
                output,
            }))
        }
        "env" => {
            let mut names = Vec::new();
            let mut reason: Option<String> = None;
            let mut wait_secs = DEFAULT_SECRET_WAIT_SECS;
            let mut idx = 0usize;
            while idx < tail.len() {
                let arg = tail[idx].as_str();
                if is_global_value_flag(arg) {
                    if idx + 1 >= tail.len() {
                        return Err(format!("Missing value for {arg}"));
                    }
                    idx += 2;
                } else if arg == "--reason" {
                    let val = tail.get(idx + 1).ok_or("Missing value for --reason")?;
                    reason = Some(val.clone());
                    idx += 2;
                } else if arg == "--wait-secs" {
                    let val = tail.get(idx + 1).ok_or("Missing value for --wait-secs")?;
                    wait_secs = val
                        .parse::<u64>()
                        .map_err(|_| "Invalid integer for --wait-secs")?;
                    idx += 2;
                } else if arg.starts_with('-') {
                    return Err(format!("Unknown flag for `secret env`: {arg}"));
                } else {
                    names.push(arg.to_string());
                    idx += 1;
                }
            }
            if names.is_empty() {
                return Err(
                    "Usage: sandboxed-mcp secret env [--reason ...] [--wait-secs 120] <NAME>..."
                        .into(),
                );
            }
            Ok(Some(SecretCliCommand::Env {
                names,
                reason,
                wait_secs,
            }))
        }
        "exec" => {
            let sep = tail.iter().position(|a| a == "--").ok_or(
                "Usage: sandboxed-mcp secret exec [--reason ...] [--wait-secs 120] <NAME>... -- <COMMAND> [ARGS...]",
            )?;
            let before = &tail[..sep];
            let command = tail[sep + 1..].to_vec();
            if command.is_empty() {
                return Err("Missing <COMMAND> after `--` in `secret exec`".into());
            }
            let mut names = Vec::new();
            let mut reason: Option<String> = None;
            let mut wait_secs = DEFAULT_SECRET_WAIT_SECS;
            let mut idx = 0usize;
            while idx < before.len() {
                let arg = before[idx].as_str();
                if is_global_value_flag(arg) {
                    if idx + 1 >= before.len() {
                        return Err(format!("Missing value for {arg}"));
                    }
                    idx += 2;
                } else if arg == "--reason" {
                    let val = before.get(idx + 1).ok_or("Missing value for --reason")?;
                    reason = Some(val.clone());
                    idx += 2;
                } else if arg == "--wait-secs" {
                    let val = before.get(idx + 1).ok_or("Missing value for --wait-secs")?;
                    wait_secs = val
                        .parse::<u64>()
                        .map_err(|_| "Invalid integer for --wait-secs")?;
                    idx += 2;
                } else if arg.starts_with('-') {
                    return Err(format!("Unknown flag for `secret exec`: {arg}"));
                } else {
                    names.push(arg.to_string());
                    idx += 1;
                }
            }
            if names.is_empty() {
                return Err("Specify at least one <NAME> before `--` in `secret exec`".into());
            }
            Ok(Some(SecretCliCommand::Exec {
                names,
                reason,
                wait_secs,
                command,
            }))
        }
        other => Err(format!(
            "Unknown `secret` subcommand `{other}` (expected get, env, or exec)"
        )),
    }
}

async fn run_secret_cli(client: &Client, cmd: SecretCliCommand) -> Result<(), String> {
    match cmd {
        SecretCliCommand::Get {
            name,
            reason,
            wait_secs,
            output,
        } => {
            let (path, export_line) = client
                .fetch_secret_file(&name, reason.as_deref(), wait_secs)
                .await?;
            match output {
                SecretGetOutput::Path => println!("{}", path.display()),
                SecretGetOutput::Export => println!("{export_line}"),
            }
            Ok(())
        }
        SecretCliCommand::Env {
            names,
            reason,
            wait_secs,
        } => {
            let mut exports = Vec::with_capacity(names.len());
            for name in &names {
                let (_, export_line) = client
                    .fetch_secret_file(name, reason.as_deref(), wait_secs)
                    .await?;
                exports.push(export_line);
            }
            for line in exports {
                println!("{line}");
            }
            Ok(())
        }
        SecretCliCommand::Exec {
            names,
            reason,
            wait_secs,
            command,
        } => {
            let mut env_pairs = Vec::with_capacity(names.len());
            for name in &names {
                if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') || name.is_empty() {
                    return Err(format!("Invalid environment variable name `{name}`"));
                }
                let (path, _) = client
                    .fetch_secret_file(name, reason.as_deref(), wait_secs)
                    .await?;
                let value = std::fs::read_to_string(&path)
                    .map_err(|e| format!("Failed reading private secret file: {e}"))?;
                env_pairs.push((name.clone(), value));
            }
            let mut cmd = build_secret_exec_command(&command, env_pairs);
            let status = cmd
                .status()
                .map_err(|e| format!("Failed to execute `{}`: {e}", command[0]))?;
            if let Some(code) = status.code() {
                if code == 0 {
                    return Ok(());
                }
                std::process::exit(code);
            }
            #[cfg(unix)]
            {
                use std::os::unix::process::ExitStatusExt;
                if let Some(sig) = status.signal() {
                    std::process::exit(128 + sig);
                }
            }
            std::process::exit(1);
        }
    }
}

fn build_secret_exec_command(
    command: &[String],
    env_pairs: Vec<(String, String)>,
) -> std::process::Command {
    let mut cmd = std::process::Command::new(&command[0]);
    cmd.args(&command[1..]);
    for name in super::launch::CONTROL_PLANE_ENV_VARS {
        cmd.env_remove(name);
    }
    cmd.envs(env_pairs);
    cmd
}

pub async fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).is_some_and(|arg| arg == "launch") {
        return super::launch::run(&args[2..]).await;
    }
    let head_args = match args.iter().position(|a| a == "--") {
        Some(sep) => &args[..sep],
        None => &args[..],
    };
    if head_args.iter().any(|a| a == "--version") {
        println!(
            "sandboxed-mcp {} contract {}",
            env!("CARGO_PKG_VERSION"),
            CONTRACT_VERSION
        );
        return Ok(());
    }
    let secret_cmd = parse_secret_subcommand(&args)?;
    let option = |flag: &str| {
        head_args
            .windows(2)
            .find(|w| w[0] == flag)
            .map(|w| w[1].clone())
    };
    let env = |names: &[&str]| {
        names
            .iter()
            .find_map(|name| std::env::var(name).ok().filter(|s| !s.is_empty()))
    };
    let mission_id = option("--mission-id")
        .or_else(|| env(&["SANDBOXED_SH_MISSION_ID", "MISSION_ID"]))
        .map(|s| uuid::Uuid::parse_str(&s).map_err(|_| "Invalid mission UUID"))
        .transpose()?;
    let role: Role = serde_json::from_value(json!(option("--profile")
        .or_else(|| env(&["SANDBOXED_MCP_PROFILE"]))
        .unwrap_or_else(|| if mission_id.is_some() {
            "executor"
        } else {
            "coordinator"
        }
        .into())))
    .map_err(|_| "Invalid MCP profile")?;
    if head_args.iter().any(|a| a == "--print-catalog") {
        println!(
            "{}",
            serde_json::to_string_pretty(&super::catalog(role)).unwrap()
        );
        return Ok(());
    }
    let api_url = option("--api-url")
        .or_else(|| {
            env(&[
                "SANDBOXED_MCP_API_URL",
                "HERMES_SANDBOXED_API_URL",
                "SANDBOXED_API_URL",
                "API_URL",
            ])
        })
        .ok_or("Missing Core API URL")?;
    let token_file = option("--token-file")
        .or_else(|| env(&["SANDBOXED_MCP_TOKEN_FILE"]))
        .map(PathBuf::from);
    let token = env(&[
        "SANDBOXED_MCP_TOKEN",
        "HERMES_SANDBOXED_API_TOKEN",
        "SANDBOXED_API_TOKEN",
        "API_TOKEN",
    ])
    .unwrap_or_default();
    let mut client = Client::new(api_url, token, token_file, role, mission_id)?;
    client.project = option("--project");
    client.client_label = option("--client-label").or_else(|| env(&["SANDBOXED_MCP_CLIENT_LABEL"]));
    client.host_hint = option("--host-hint").or_else(|| env(&["SANDBOXED_MCP_HOST_HINT"]));
    let client = Arc::new(client);
    if let Some(cmd) = secret_cmd {
        return run_secret_cli(&client, cmd).await;
    }
    if head_args.iter().any(|a| a == "--check") {
        let value = client.preflight().await?;
        println!(
            "{}",
            json!({"contract_version":value["contract_version"],"identity":value["identity"],"tools":value["tools"].as_array().map(Vec::len)})
        );
        return Ok(());
    }
    let renewal_client = client.clone();
    let renewal = tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            // Keep an active mission's credential alive even during a long
            // model/tool operation with no MCP traffic. Errors remain on stderr.
            if renewal_client.token().await.is_err() {
                eprintln!("sandboxed-mcp: session renewal unavailable; retrying");
            }
        }
    });
    let result = super::protocol::serve(
        tokio::io::BufReader::new(tokio::io::stdin()),
        tokio::io::stdout(),
        move |request| {
            let client = client.clone();
            async move { client.handle(request).await }
        },
    )
    .await
    .map_err(|e| e.to_string());
    renewal.abort();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn rejected_cached_session_renews_once_without_replaying_an_accepted_mutation() {
        use axum::{routing::post, Json, Router};
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let renewals = Arc::new(AtomicUsize::new(0));
        let app = Router::new()
            .route("/api/mcp/renew", post({ let renewals = renewals.clone(); move |headers: axum::http::HeaderMap| { let renewals = renewals.clone(); async move {
                assert_eq!(headers["authorization"], "Bearer mcp1.stale");
                renewals.fetch_add(1, Ordering::SeqCst);
                Json(json!({"token":"mcp1.fresh","expires_at":chrono::Utc::now().timestamp()+3600}))
            }}}))
            .route("/api/mcp/call", post({ let calls = calls.clone(); move |headers: axum::http::HeaderMap| { let calls = calls.clone(); async move {
                if headers["authorization"] != "Bearer mcp1.fresh" {
                    return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({})));
                }
                calls.fetch_add(1, Ordering::SeqCst);
                (axum::http::StatusCode::OK, Json(json!({"ok":true})))
            }}}));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = Client::new(url, "mcp1.stale".into(), None, Role::Executor, None).unwrap();
        *client.session.lock().await =
            Some(("mcp1.stale".into(), chrono::Utc::now().timestamp() + 3600));
        assert_eq!(
            client
                .request("/api/mcp/call", Some(&json!({"name":"test"})))
                .await
                .unwrap()["ok"],
            true
        );
        assert_eq!(renewals.load(Ordering::SeqCst), 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        server.abort();
    }

    #[tokio::test]
    async fn token_file_renewal_prefers_externally_repaired_file_over_stale_memory() {
        use axum::{routing::post, Json, Router};
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mcp-credential");
        persist_scoped_credential(&path, "mcp1.repaired").unwrap();

        let app = Router::new()
            .route(
                "/api/mcp/renew",
                post(|headers: axum::http::HeaderMap| async move {
                    if headers["authorization"] != "Bearer mcp1.repaired" {
                        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({})));
                    }
                    (
                        axum::http::StatusCode::OK,
                        Json(json!({
                            "token": "mcp1.rotated",
                            "expires_at": chrono::Utc::now().timestamp() + 3600
                        })),
                    )
                }),
            )
            .route(
                "/api/mcp/call",
                post(|headers: axum::http::HeaderMap| async move {
                    if headers["authorization"] != "Bearer mcp1.rotated" {
                        return (axum::http::StatusCode::UNAUTHORIZED, Json(json!({})));
                    }
                    (axum::http::StatusCode::OK, Json(json!({"ok": true})))
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = Client::new(
            url,
            String::new(),
            Some(path.clone()),
            Role::Coordinator,
            None,
        )
        .unwrap();
        *client.session.lock().await =
            Some(("mcp1.dead".into(), chrono::Utc::now().timestamp() + 3600));
        assert_eq!(
            client
                .request("/api/mcp/call", Some(&json!({"name": "test"})))
                .await
                .unwrap()["ok"],
            true
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "mcp1.rotated");
        server.abort();
    }

    #[test]
    fn renewal_is_private_atomic_and_available_after_client_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credential");
        std::fs::write(&path, "mcp1.old").unwrap();
        persist_scoped_credential(&path, "mcp1.renewed").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "mcp1.renewed");
        assert!(persist_scoped_credential(&path, "owner-login").is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "mcp1.renewed");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn secret_delivery_is_written_to_a_private_file_and_stripped() {
        let dir = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let target = dir.path().join("mission");
        let out = super::deliver_secret_in(
            &target,
            json!({
                "status": "granted",
                "secret_delivery": {"name": "UXON_TOKEN", "value": "s3cret"}
            }),
        );
        assert!(!out.to_string().contains("s3cret"));
        let path = out["path"]
            .as_str()
            .unwrap_or_else(|| panic!("no path in {out}"));
        assert_eq!(std::fs::read_to_string(path).unwrap(), "s3cret");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        let bad = super::deliver_secret_in(
            &target,
            json!({"secret_delivery": {"name": "../x", "value": "v"}}),
        );
        assert!(!bad.to_string().contains("\"v\""));
    }

    #[test]
    fn parse_secret_subcommands_and_session_scoped_secrets_dir() {
        let s = |items: &[&str]| items.iter().map(|x| (*x).to_string()).collect::<Vec<_>>();
        assert_eq!(
            parse_secret_subcommand(&s(&["sandboxed-mcp", "--check"])).unwrap(),
            None
        );
        assert_eq!(
            parse_secret_subcommand(&s(&[
                "sandboxed-mcp",
                "--api-url",
                "http://127.0.0.1:3000",
                "--client-label",
                "Codex Desktop",
                "--host-hint",
                "thomas-mac",
                "secret",
                "get",
                "OPENAI_API_KEY",
                "--reason",
                "run evals",
                "--wait-secs",
                "90",
                "--print-export"
            ]))
            .unwrap(),
            Some(SecretCliCommand::Get {
                name: "OPENAI_API_KEY".into(),
                reason: Some("run evals".into()),
                wait_secs: 90,
                output: SecretGetOutput::Export,
            })
        );
        assert_eq!(
            parse_secret_subcommand(&s(&[
                "sandboxed-mcp",
                "secret",
                "env",
                "FOO_KEY",
                "BAR_KEY",
                "--reason",
                "local test"
            ]))
            .unwrap(),
            Some(SecretCliCommand::Env {
                names: vec!["FOO_KEY".into(), "BAR_KEY".into()],
                reason: Some("local test".into()),
                wait_secs: DEFAULT_SECRET_WAIT_SECS,
            })
        );
        assert_eq!(
            parse_secret_subcommand(&s(&[
                "sandboxed-mcp",
                "secret",
                "exec",
                "--reason",
                "deploy check",
                "--wait-secs",
                "45",
                "FOO_KEY",
                "BAR_KEY",
                "--",
                "sh",
                "-c",
                "echo ok --version"
            ]))
            .unwrap(),
            Some(SecretCliCommand::Exec {
                names: vec!["FOO_KEY".into(), "BAR_KEY".into()],
                reason: Some("deploy check".into()),
                wait_secs: 45,
                command: vec!["sh".into(), "-c".into(), "echo ok --version".into()],
            })
        );
        assert!(parse_secret_subcommand(&s(&[
            "sandboxed-mcp",
            "secret",
            "get",
            "FOO",
            "--print-path",
            "--print-export"
        ]))
        .is_err());

        let sid = uuid::Uuid::parse_str("11111111-2222-3333-4444-555555555555").unwrap();
        let mid = uuid::Uuid::parse_str("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").unwrap();
        assert_eq!(
            secrets_dir_with_env(
                None,
                Some(sid),
                None,
                Some(PathBuf::from("/run/user/501")),
                Some(PathBuf::from("/Users/thomas")),
                None,
            ),
            PathBuf::from(
                "/run/user/501/paloma-secrets/session-11111111-2222-3333-4444-555555555555"
            )
        );
        assert_eq!(
            secrets_dir_with_env(
                None,
                Some(sid),
                None,
                None,
                Some(PathBuf::from("/Users/thomas")),
                None,
            ),
            PathBuf::from(
                "/Users/thomas/.paloma-secrets/session-11111111-2222-3333-4444-555555555555"
            )
        );
        assert_eq!(
            secrets_dir_with_env(
                Some(mid),
                Some(sid),
                None,
                Some(PathBuf::from("/run/user/501")),
                None,
                None,
            ),
            PathBuf::from("/run/user/501/paloma-secrets/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        );
    }

    #[tokio::test]
    async fn fetch_secret_file_waits_for_pending_approval_and_forwards_client_hints() {
        use axum::{
            extract::{Path, Query},
            routing::{get, post},
            Json, Router,
        };
        use base64::Engine as _;
        use std::collections::HashMap;
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };

        let sid = uuid::Uuid::new_v4();
        let req_id = uuid::Uuid::new_v4();
        let jwt_payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(json!({"session_id": sid}).to_string());
        let fake_mcp_token = format!("mcp1.hdr.{jwt_payload}.sig");

        let secret_calls = Arc::new(AtomicUsize::new(0));
        let wait_calls = Arc::new(AtomicUsize::new(0));
        let renew_payloads: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(Vec::new()));

        let app = Router::new()
            .route(
                "/api/mcp/capabilities",
                get({
                    move || async move {
                        Json(json!({
                            "contract_version": "1",
                            "identity": {
                                "session_id": sid,
                                "mission_id": null,
                                "role": "coordinator"
                            },
                            "tools": [],
                            "limits": {
                                "session_expires_at": chrono::Utc::now().timestamp() + 3600
                            }
                        }))
                    }
                }),
            )
            .route(
                "/api/mcp/renew",
                post({
                    let renew_payloads = renew_payloads.clone();
                    let tok = fake_mcp_token.clone();
                    move |Json(body): Json<Value>| {
                        let renew_payloads = renew_payloads.clone();
                        let tok = tok.clone();
                        async move {
                            renew_payloads.lock().await.push(body);
                            Json(json!({
                                "token": tok,
                                "session_id": sid,
                                "expires_at": chrono::Utc::now().timestamp() + 3600
                            }))
                        }
                    }
                }),
            )
            .route(
                "/api/mcp/call",
                post({
                    let secret_calls = secret_calls.clone();
                    move |Json(body): Json<Value>| {
                        let secret_calls = secret_calls.clone();
                        async move {
                            assert_eq!(body["name"], "secret_get");
                            assert_eq!(body["arguments"]["name"], "OPENAI_API_KEY");
                            assert_eq!(body["arguments"]["reason"], "local mac cli");
                            let n = secret_calls.fetch_add(1, Ordering::SeqCst);
                            if n == 0 {
                                Json(json!({
                                    "ok": true,
                                    "result": {
                                        "status": "pending",
                                        "request_id": req_id,
                                    }
                                }))
                            } else {
                                Json(json!({
                                    "ok": true,
                                    "result": {
                                        "status": "granted",
                                        "secret_delivery": {
                                            "name": "OPENAI_API_KEY",
                                            "value": "sk-live-secret-999"
                                        }
                                    }
                                }))
                            }
                        }
                    }
                }),
            )
            .route(
                "/api/mcp/requests/secret/:id/wait",
                get({
                    let wait_calls = wait_calls.clone();
                    move |Path(id): Path<uuid::Uuid>, Query(q): Query<HashMap<String, String>>| {
                        let wait_calls = wait_calls.clone();
                        async move {
                            assert_eq!(id, req_id);
                            assert!(q.contains_key("timeout_secs"));
                            let w = wait_calls.fetch_add(1, Ordering::SeqCst);
                            if w == 0 {
                                Json(json!({"status": "pending", "request_id": id}))
                            } else {
                                Json(json!({"status": "approved", "request_id": id}))
                            }
                        }
                    }
                }),
            );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let tmp = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let secrets_root = tmp.path().join("session-secrets");

        // Missionless owner tokens fail closed immediately with actionable guidance
        // instead of attempting an unsigned POST to `/api/mcp/external-sessions`.
        let owner_client = Client::new(
            url.clone(),
            "owner-jwt-token".into(),
            None,
            Role::Coordinator,
            None,
        )
        .unwrap();
        let owner_err = owner_client
            .fetch_secret_file("OPENAI_API_KEY", Some("local mac cli"), 5)
            .await
            .unwrap_err();
        assert!(owner_err.contains("mcp1.*"), "{owner_err}");

        let mut client = Client::new(url, fake_mcp_token, None, Role::Coordinator, None).unwrap();
        client.client_label = Some("Mac Terminal".into());
        client.host_hint = Some("thomas-mbp".into());
        client.secrets_dir_override = Some(secrets_root.clone());

        let (path, export_line) = client
            .fetch_secret_file("OPENAI_API_KEY", Some("local mac cli"), 30)
            .await
            .unwrap();

        assert_eq!(secret_calls.load(Ordering::SeqCst), 2);
        assert_eq!(wait_calls.load(Ordering::SeqCst), 2);
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "sk-live-secret-999"
        );
        assert!(export_line.contains("export OPENAI_API_KEY="));
        assert!(!export_line.contains("sk-live-secret-999"));

        let payloads = renew_payloads.lock().await;
        assert_eq!(payloads.len(), 1);
        assert_eq!(payloads[0]["client_label"], "Mac Terminal");
        assert_eq!(payloads[0]["host_hint"], "thomas-mbp");

        server.abort();
    }

    #[test]
    fn secret_exec_strips_control_plane_credentials_while_injecting_requested_secrets() {
        let mut cmd = build_secret_exec_command(
            &[
                "python3".into(),
                "-c".into(),
                concat!(
                    "import json, os; ",
                    "keys = ['JWT_SECRET','API_SERVER_KEY','HERMES_SANDBOXED_API_TOKEN',",
                    "'SANDBOXED_API_TOKEN','OPEN_AGENT_API_TOKEN','API_TOKEN',",
                    "'SANDBOXED_MCP_TOKEN','SANDBOXED_MCP_TOKEN_FILE','SANDBOXED_MCP_WRAPPER',",
                    "'OPENAI_API_KEY']; ",
                    "print(json.dumps({k: os.environ.get(k) for k in keys}))"
                )
                .into(),
            ],
            vec![("OPENAI_API_KEY".into(), "sk-injected-secret".into())],
        );
        let envs: Vec<_> = cmd.get_envs().collect();
        for &var in super::super::launch::CONTROL_PLANE_ENV_VARS {
            assert!(
                envs.iter()
                    .any(|(k, v)| *k == std::ffi::OsStr::new(var) && v.is_none()),
                "expected `{var}` to be explicitly removed from child env"
            );
        }
        assert!(envs.iter().any(|(k, v)| {
            *k == std::ffi::OsStr::new("OPENAI_API_KEY")
                && *v == Some(std::ffi::OsStr::new("sk-injected-secret"))
        }));
        let out = cmd.output().unwrap();
        assert!(out.status.success());
        let observed: Value = serde_json::from_slice(&out.stdout).unwrap();
        for &var in super::super::launch::CONTROL_PLANE_ENV_VARS {
            assert!(observed[var].is_null(), "expected `{var}` to be absent");
        }
        assert_eq!(observed["OPENAI_API_KEY"], "sk-injected-secret");
    }
}
