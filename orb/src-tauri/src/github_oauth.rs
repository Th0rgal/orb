//! Native GitHub OAuth sign-in for Orb desktop.
//!
//! Prefers an RFC 8252 §7.3 loopback callback (`http://127.0.0.1:<port>/auth/callback`)
//! in the user's default browser so existing GitHub sessions and passkeys work.
//! When talking to an older Core server whose `github_oauth_redirect_allowlist`
//! permits only `sandboxed://auth/callback`, falls back to an isolated Tauri
//! sign-in window that intercepts the `sandboxed://auth/callback` redirect.

use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const WINDOW_LABEL: &str = "github-oauth-sign-in";
const TIMEOUT: Duration = Duration::from_secs(10 * 60);

fn encode_query_component(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn build_start_url(base_url: &str, redirect_uri: &str, state: Option<&str>) -> String {
    let clean = base_url.trim().trim_end_matches('/');
    let mut url = format!(
        "{clean}/api/auth/github/start?redirect={}",
        encode_query_component(redirect_uri)
    );
    if let Some(s) = state.filter(|s| !s.trim().is_empty()) {
        url.push_str("&state=");
        url.push_str(&encode_query_component(s.trim()));
    }
    url
}

fn open_system_browser(url: &str) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("only http(s) URLs".into());
    }
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg(url);
        c
    };
    #[cfg(target_os = "linux")]
    let mut cmd = {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(url);
        c
    };
    #[cfg(target_os = "windows")]
    let mut cmd = {
        let mut c = std::process::Command::new("rundll32");
        c.args(["url.dll,FileProtocolHandler", url]);
        c
    };
    cmd.spawn().map_err(|e| e.to_string())?;
    Ok(())
}

async fn try_loopback_authorize_url(
    base_url: &str,
    redirect_uri: &str,
    state: Option<&str>,
) -> Result<Option<String>, String> {
    let client = crate::transport_proxy::resilient_client_builder()
        .connect_timeout(Duration::from_secs(6))
        .timeout(Duration::from_secs(12))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;

    for candidate in crate::transport_proxy::candidate_endpoints(base_url) {
        let start_url = build_start_url(&candidate, redirect_uri, state);
        let Ok(resp) = client.get(&start_url).send().await else {
            continue;
        };
        let status = resp.status().as_u16();
        if matches!(status, 301..=303 | 307 | 308) {
            if let Some(loc) = resp.headers().get("location").and_then(|v| v.to_str().ok()) {
                if loc.starts_with("https://github.com/") {
                    return Ok(Some(loc.to_string()));
                }
            }
        }
        if status == 400 {
            return Ok(None);
        }
        if status == 404 {
            return Err("GitHub sign-in is not configured on this server".into());
        }
    }
    Ok(None)
}

async fn wait_for_loopback_callback(
    listener: TcpListener,
    port: u16,
) -> Result<Option<String>, String> {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    loop {
        let accept = tokio::time::timeout_at(deadline, listener.accept()).await;
        let Ok(Ok((mut stream, _))) = accept else {
            return Err("GitHub sign-in timed out".into());
        };
        let mut buf = [0u8; 8192];
        let Ok(Ok(n)) = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buf)).await
        else {
            continue;
        };
        if n == 0 {
            continue;
        }
        let req = String::from_utf8_lossy(&buf[..n]);
        let Some(first_line) = req.lines().next() else {
            continue;
        };
        let mut parts = first_line.split_whitespace();
        let _method = parts.next();
        let Some(target) = parts.next() else {
            continue;
        };
        if !target.starts_with("/auth/callback") {
            let not_found =
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            let _ = stream.write_all(not_found).await;
            let _ = stream.shutdown().await;
            continue;
        }
        let has_error = target.contains("error=");
        let body = if has_error {
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>Orb Sign-In</title></head>\
             <body style=\"font-family:-apple-system,system-ui,sans-serif;padding:40px;color:#222\">\
             <h2 style=\"margin:0 0 8px\">GitHub sign-in did not complete</h2>\
             <p style=\"margin:0;color:#666\">Return to Orb for details. You can close this tab.</p></body></html>"
        } else {
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>Signed in to Orb</title></head>\
             <body style=\"font-family:-apple-system,system-ui,sans-serif;padding:40px;color:#222\">\
             <h2 style=\"margin:0 0 8px\">Signed in to Orb</h2>\
             <p style=\"margin:0;color:#666\">You can close this tab and return to Orb.</p></body></html>"
        };
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.shutdown().await;
        return Ok(Some(format!("http://127.0.0.1:{port}{target}")));
    }
}

async fn sign_in_via_webview(
    app: tauri::AppHandle,
    base_url: &str,
    state: Option<&str>,
) -> Result<Option<String>, String> {
    if let Some(existing) = app.get_webview_window(WINDOW_LABEL) {
        let _ = existing.close();
    }
    let start_url = build_start_url(base_url, "sandboxed://auth/callback", state);
    let parsed: tauri::Url = start_url.parse().map_err(|e| format!("{e}"))?;
    let captured: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let captured_nav = captured.clone();

    let window = WebviewWindowBuilder::new(&app, WINDOW_LABEL, WebviewUrl::External(parsed))
        .title("Sign in with GitHub")
        .inner_size(860.0, 720.0)
        .on_navigation(move |url| {
            let s = url.as_str();
            if s.starts_with("sandboxed://auth/callback") {
                if let Ok(mut guard) = captured_nav.lock() {
                    *guard = Some(s.to_string());
                }
                return false;
            }
            true
        })
        .build()
        .map_err(|e| format!("Could not open GitHub sign-in window: {e}"))?;

    let started = std::time::Instant::now();
    loop {
        tokio::time::sleep(Duration::from_millis(200)).await;
        if let Some(callback_url) = captured.lock().ok().and_then(|mut g| g.take()) {
            let _ = window.close();
            return Ok(Some(callback_url));
        }
        if app.get_webview_window(WINDOW_LABEL).is_none() {
            return Ok(None);
        }
        if started.elapsed() > TIMEOUT {
            let _ = window.close();
            return Err("GitHub sign-in timed out".into());
        }
    }
}

#[tauri::command]
pub async fn github_oauth_sign_in(
    app: tauri::AppHandle,
    api_url: String,
    state: Option<String>,
) -> Result<Option<String>, String> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let loopback_redirect = format!("http://127.0.0.1:{port}/auth/callback");

    if let Some(authorize_url) =
        try_loopback_authorize_url(&api_url, &loopback_redirect, state.as_deref()).await?
    {
        open_system_browser(&authorize_url)?;
        return wait_for_loopback_callback(listener, port).await;
    }

    drop(listener);
    sign_in_via_webview(app, &api_url, state.as_deref()).await
}
