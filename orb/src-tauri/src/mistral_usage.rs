//! One-time Mistral console sign-in for monthly Vibe usage.
//!
//! Mistral exposes the Vibe plan's monthly counter only to a signed-in
//! console session. Orb opens the console in its own window, waits until the
//! session cookies exist, and returns only those cookies (`ory_session_*`,
//! `csrftoken`) to the webview, which hands them to Core. Nothing else from the
//! browsing session is read.
use std::time::Duration;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "mistral-usage-sign-in";
const ADMIN: &str = "https://admin.mistral.ai/subscription";
const CONSOLE: &str = "https://console.mistral.ai/";
const TIMEOUT: Duration = Duration::from_secs(15 * 60);

fn session_cookies(window: &tauri::WebviewWindow) -> (Option<String>, Option<String>) {
    let mut session = None;
    let mut csrf = None;
    for url in [ADMIN, CONSOLE] {
        let Ok(url) = url.parse() else { continue };
        for cookie in window.cookies_for_url(url).unwrap_or_default() {
            let (name, value) = (cookie.name(), cookie.value());
            if value.is_empty() {
                continue;
            }
            if name.starts_with("ory_session_") && session.is_none() {
                session = Some(format!("{name}={value}"));
            } else if name == "csrftoken" && csrf.is_none() {
                csrf = Some(value.to_string());
            }
        }
    }
    (session, csrf)
}

/// Returns `ory_session_…=…; csrftoken=…`, or `None` if the window was closed.
#[tauri::command]
pub async fn mistral_usage_sign_in(app: tauri::AppHandle) -> Result<Option<String>, String> {
    if let Some(existing) = app.get_webview_window(LABEL) {
        let _ = existing.close();
    }
    let window = WebviewWindowBuilder::new(
        &app,
        LABEL,
        WebviewUrl::External(ADMIN.parse().map_err(|e| format!("{e}"))?),
    )
    .title("Sign in to Mistral to show monthly usage")
    .inner_size(980.0, 760.0)
    .build()
    .map_err(|e| format!("Could not open the Mistral sign-in window: {e}"))?;

    let started = std::time::Instant::now();
    let mut visited_console = false;
    loop {
        tokio::time::sleep(Duration::from_millis(800)).await;
        // Closed by the user: no session.
        if app.get_webview_window(LABEL).is_none() {
            return Ok(None);
        }
        if started.elapsed() > TIMEOUT {
            let _ = window.close();
            return Err("Mistral sign-in timed out".into());
        }
        match session_cookies(&window) {
            (Some(session), Some(csrf)) => {
                let _ = window.close();
                return Ok(Some(format!("{session}; csrftoken={csrf}")));
            }
            // Signed in, but the console issues its CSRF token on first visit.
            (Some(_), None) if !visited_console => {
                visited_console = true;
                if let Ok(url) = CONSOLE.parse() {
                    let _ = window.navigate(url);
                }
            }
            _ => {}
        }
    }
}
