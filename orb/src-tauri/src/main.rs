#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#[path = "../../../shared/agent_software.rs"]
#[allow(dead_code)] // Shared with other binaries; not every item is used here.
mod agent_software;
#[path = "../../../shared/antigravity.rs"]
#[allow(dead_code)] // Shared with other binaries; not every item is used here.
mod antigravity;
#[path = "../../../shared/codex_speed.rs"]
pub mod codex_speed;
#[path = "../../../shared/cyber_access.rs"]
pub mod cyber_access;
#[path = "../../../shared/file_notifications.rs"]
pub mod file_notifications;
#[path = "../../../shared/harness_attribution.rs"]
#[allow(dead_code)] // Shared with other binaries; not every item is used here.
mod harness_attribution;
#[path = "../../../shared/vibe.rs"]
#[allow(dead_code)] // Shared with other binaries; not every item is used here.
mod vibe;

mod connection_store;
#[cfg(test)]
mod live_mcp_tests;
mod local_origin;
mod local_origin_confirmed;
#[path = "../../../shared/local_origin.rs"]
mod local_origin_wire;
mod mcp_launch;
#[path = "../../../shared/project_context.rs"]
#[allow(dead_code)] // Shared with other binaries; not every item is used here.
mod project_context_store;
mod run_recovery;
mod software;
// Shared replica code uses the same module name in both binaries.
use project_context_store as project_context;
#[path = "../../../shared/context_replica.rs"]
mod context_replica;
#[path = "project_context.rs"]
mod context_service;

#[path = "../../../shared/file_browser.rs"]
mod file_browser;
mod interactions;
mod local_agents;
mod local_stream;
mod local_wakeups;
mod machine_metrics;
mod routed_opencode;
mod session_preview;
mod skills;
mod sync_util;
mod transfers;
mod uploads;
mod voice;

use tauri::{Manager, Theme, WebviewWindow};

/// Follow the frontend's persisted preference. `None` delegates to the OS,
/// which makes titlebar material and the frontend change together for Auto.
#[tauri::command]
fn set_window_theme(window: WebviewWindow, theme: String) -> Result<(), String> {
    let theme = match theme.as_str() {
        "auto" => None,
        "light" => Some(Theme::Light),
        "dark" => Some(Theme::Dark),
        _ => return Err("theme must be auto, light, or dark".to_string()),
    };
    window.set_theme(theme).map_err(|e| e.to_string())
}

#[tauri::command]
fn paloma_ssh_pubkey() -> Result<String, String> {
    let home = std::env::var("HOME").map_err(|_| "HOME is unset".to_string())?;
    std::fs::read_to_string(format!("{home}/.ssh/paloma.pub")).map_err(|e| e.to_string())
}

/// Show a file the webview saved to ~/Downloads, or the folder when the browser
/// renamed it (e.g. "name (1).jar"). Only bare file names are accepted.
#[tauri::command]
fn reveal_download(name: String) -> Result<(), String> {
    if name.is_empty() || name.contains('/') || name.contains('\\') || name == "." || name == ".." {
        return Err("invalid file name".into());
    }
    let downloads = std::env::var_os("HOME")
        .map(|home| std::path::PathBuf::from(home).join("Downloads"))
        .ok_or("no home directory")?;
    let file = downloads.join(&name);
    #[cfg(target_os = "macos")]
    let status = if file.exists() {
        std::process::Command::new("open")
            .arg("-R")
            .arg(&file)
            .status()
    } else {
        std::process::Command::new("open").arg(&downloads).status()
    };
    #[cfg(target_os = "windows")]
    let status = if file.exists() {
        std::process::Command::new("explorer")
            .arg(format!("/select,{}", file.display()))
            .status()
    } else {
        std::process::Command::new("explorer")
            .arg(&downloads)
            .status()
    };
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let status = std::process::Command::new("xdg-open")
        .arg(&downloads)
        .status();
    match status {
        Ok(status) if status.success() => Ok(()),
        _ => Err("Could not open the Downloads folder".into()),
    }
}

#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("only http(s) URLs".into());
    }
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg(&url);
        c
    };
    #[cfg(target_os = "linux")]
    let mut cmd = {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(&url);
        c
    };
    #[cfg(target_os = "windows")]
    let mut cmd = {
        let mut c = std::process::Command::new("rundll32");
        c.args(["url.dll,FileProtocolHandler", &url]);
        c
    };
    cmd.spawn().map_err(|e| e.to_string())?;
    Ok(())
}

mod approval_key;
mod bindings;
mod biometrics;
mod client_link;
mod diagnostics;
mod mistral_usage;
use bindings::local_bindings;

fn main() {
    agent_software::start_worker();
    if context_service::worker_entry() {
        return;
    }
    tauri::Builder::default()
        .manage(voice::VoiceState::new())
        .on_page_load(|_, payload| {
            if matches!(payload.event(), tauri::webview::PageLoadEvent::Started) {
                bindings::clear_subscriptions();
                context_service::clear_subscriptions();
                interactions::clear_subscriptions();
                local_agents::clear_subscriptions();
            }
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, position }) =
                event
            {
                use tauri::Emitter;
                let paths = uploads::allow_drop(paths);
                let count = paths.len();
                if let Err(error) = window.emit(
                    "orb-upload-drop",
                    serde_json::json!({"paths":paths,"x":position.x,"y":position.y}),
                ) {
                    orb_log!(
                        warn,
                        "upload_drop_emit_failed",
                        extra = serde_json::json!({"paths": count, "error": error.to_string()})
                    );
                }
            }
        })
        .setup(|app| {
            // Local voice input: the Python worker starts on first use and
            // is released again after a stretch of inactivity.
            app.state::<voice::VoiceState>().start_idle_reaper();
            machine_metrics::start(app.state::<voice::VoiceState>().inner().clone());
            diagnostics::start(app.handle().clone());
            client_link::set_app(app.handle().clone());
            // macOS vibrancy: the window is transparent and the sidebar
            // shows the desktop through a sidebar-material blur, like
            // Cursor/Xcode. The main pane paints an opaque background in
            // CSS so only the sidebar is translucent.
            #[cfg(target_os = "macos")]
            {
                use tauri::Manager;
                use window_vibrancy::{
                    apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState,
                };
                if let Some(window) = app.get_webview_window("main") {
                    let _ = apply_vibrancy(
                        &window,
                        NSVisualEffectMaterial::Sidebar,
                        Some(NSVisualEffectState::Active),
                        Some(10.0),
                    );
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            diagnostics::diagnostics_append,
            diagnostics::reveal_logs,
            approval_key::approval_key_status,
            approval_key::approval_key_create,
            approval_key::approval_sign,
            approval_key::approval_grace_until,
            approval_key::set_approval_grace,
            biometrics::biometric_status,
            biometrics::biometric_authenticate,
            bindings::local_binding_set,
            bindings::local_bindings_refresh,
            bindings::local_bindings_subscribe,
            bindings::local_bindings_unsubscribe,
            local_origin::local_origin_launch,
            local_origin::local_origin_list,
            local_origin::local_origin_confirm,
            local_origin::local_origin_disconnect,
            run_recovery::local_run_launch,
            run_recovery::local_run_reconcile,
            interactions::local_interaction,
            interactions::local_interaction_subscribe,
            interactions::local_interaction_unsubscribe,
            interactions::local_interaction_answer,
            paloma_ssh_pubkey,
            session_preview::local_session_git,
            connection_store::desktop_connection_load,
            connection_store::desktop_connection_save,
            uploads::pick_upload_files,
            uploads::pick_working_directory,
            uploads::read_upload_file,
            uploads::read_upload_file_chunk,
            uploads::stat_upload_file,
            uploads::stage_upload_file,
            uploads::stage_upload_file_from_path,
            browse_local_files,
            machine_metrics::local_machine_metrics,
            open_url,
            reveal_download,
            set_window_theme,
            voice::voice_capability,
            voice::voice_prewarm,
            voice::voice_transcribe,
            voice::voice_cancel,
            context_service::project_context_file,
            context_service::project_context_prepare,
            context_service::project_skills_prepare,
            context_service::project_context_status,
            context_service::project_context_subscribe,
            context_service::project_context_unsubscribe,
            context_service::project_context_sync,
            context_service::project_context_disconnect,
            context_service::project_context_workers,
            context_service::project_context_stop,
            software::software_inventory,
            software::software_update,
            software::software_cancel,
            skills::local_skills_status,
            skills::local_skills_sync,
            skills::local_skill_source_files,
            local_agents::local_agents_cyber_capabilities,
            local_agents::local_codex_speed_options,
            local_agents::local_agents_scan,
            local_agents::local_antigravity_models,
            local_agents::local_claude_models,
            local_agents::local_agents_workspace,
            local_agents::local_agents_directory,
            local_agents::local_agents_write,
            transfers::local_machine_transfer,
            transfers::local_machine_identity,
            mistral_usage::mistral_usage_sign_in,
            client_link::client_link_active,
            client_link::client_link_flush,
            client_link::client_link_connect,
            client_link::client_link_set_capabilities,
            client_link::client_link_start_result,
            local_agents::local_agents_poll,
            local_wakeups::local_wakeups_sync,
            local_wakeups::local_wakeups_cancel,
            local_wakeups::local_wakeups_discard,
            local_agents::local_agents_subscribe,
            local_agents::local_agents_unsubscribe,
            local_agents::local_agents_stop
        ])
        .run(tauri::generate_context!())
        .expect("error while running orb");
}

#[tauri::command]
async fn browse_local_files(
    root: String,
    request: file_browser::Request,
) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if request.action == "reveal" {
            let root = std::path::Path::new(&root)
                .canonicalize()
                .map_err(|e| e.to_string())?;
            let path = file_browser::resolve(&root, &request.path)?;
            #[cfg(target_os = "macos")]
            let status = std::process::Command::new("open")
                .arg("-R")
                .arg(&path)
                .status();
            #[cfg(target_os = "windows")]
            let status = std::process::Command::new("explorer")
                .arg(format!("/select,{}", path.display()))
                .status();
            #[cfg(not(any(target_os = "macos", target_os = "windows")))]
            let status = std::process::Command::new("xdg-open")
                .arg(path.parent().unwrap_or(&root))
                .status();
            if !status.map_err(|e| e.to_string())?.success() {
                return Err("Could not reveal this file".into());
            }
            return Ok(serde_json::json!({}));
        }
        file_browser::execute(std::path::Path::new(&root), &request)
    })
    .await
    .map_err(|e| e.to_string())?
}
