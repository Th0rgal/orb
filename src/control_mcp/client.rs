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
    http: reqwest::Client,
    session: Mutex<Option<(String, i64)>>,
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
        Ok(Self {
            api_url: api_url.trim_end_matches('/').into(),
            token,
            token_file,
            role,
            mission_id,
            project: None,
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|_| "Cannot initialize HTTP client")?,
            session: Mutex::new(None),
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
                let expiry = caps["limits"]["session_expires_at"]
                    .as_i64()
                    .ok_or("Missing session expiry")?;
                *session = Some((credential.clone(), expiry));
                if expiry > chrono::Utc::now().timestamp() + 120 {
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
        let path = if scoped {
            "/api/mcp/renew"
        } else {
            "/api/mcp/session"
        };
        let response = self
            .http
            .post(format!("{}{path}", self.api_url))
            .bearer_auth(auth)
            .json(&json!({"role":self.role,"mission_id":self.mission_id,"project":self.project}))
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
        if v["contract_version"] != CONTRACT_VERSION {
            return Err("MCP contract version mismatch".into());
        }
        Ok(v)
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
                        deliver_secret(reply["result"].clone())
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

/// Directory for secrets handed to this mission, under a per-user base
/// (never the shared temp dir, where another user could own a parent).
fn secrets_dir() -> std::path::PathBuf {
    if let Some(dir) = std::env::var_os("SANDBOXED_SECRETS_DIR") {
        return dir.into();
    }
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(|d| std::path::PathBuf::from(d).join("paloma-secrets"))
        .or_else(|| {
            std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".paloma-secrets"))
        })
        .unwrap_or_else(|| std::path::PathBuf::from(".paloma-secrets"));
    let mission = std::env::var("SANDBOXED_SH_MISSION_ID")
        .or_else(|_| std::env::var("MISSION_ID"))
        .unwrap_or_else(|_| "session".into());
    base.join(mission.replace(['/', '.'], "_"))
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
fn deliver_secret(result: Value) -> Value {
    deliver_secret_in(&secrets_dir(), result)
}

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

pub async fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).is_some_and(|arg| arg == "launch") {
        return super::launch::run(&args[2..]).await;
    }
    if args.iter().any(|a| a == "--version") {
        println!(
            "sandboxed-mcp {} contract {}",
            env!("CARGO_PKG_VERSION"),
            CONTRACT_VERSION
        );
        return Ok(());
    }
    let option = |flag: &str| args.windows(2).find(|w| w[0] == flag).map(|w| w[1].clone());
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
    if args.iter().any(|a| a == "--print-catalog") {
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
    let client = Arc::new(client);
    if args.iter().any(|a| a == "--check") {
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
}
