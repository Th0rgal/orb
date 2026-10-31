use crate::agent_software::{self as software, Inventory, UpdateJob};
use std::{collections::HashMap, path::PathBuf};

fn apply_local_readiness(inventory: &mut Inventory) {
    let agy_token = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".gemini/antigravity-cli/antigravity-oauth-token"));
    for comp in &mut inventory.components {
        if !comp.installed {
            comp.ready = Some(false);
            comp.ready_detail = Some("CLI is not installed on This Mac.".into());
            continue;
        }
        match comp.id.as_str() {
            "vibe" => {
                if let Some(ref path) = comp.path {
                    match crate::local_agents::harness::vibe::vibe_python(path) {
                        Ok(_) => {
                            comp.ready = Some(true);
                            comp.ready_detail = Some("Python 3.9+ interpreter verified.".into());
                        }
                        Err(err) => {
                            comp.ready = Some(false);
                            comp.ready_detail = Some(err);
                        }
                    }
                }
            }
            "antigravity" => {
                let signed_in = agy_token.as_ref().is_some_and(|p| p.is_file());
                comp.ready = Some(signed_in);
                comp.ready_detail = Some(if signed_in {
                    "Local Antigravity sign-in detected.".into()
                } else {
                    "Sign in with agy login on This Mac.".into()
                });
            }
            _ => {}
        }
    }
}

#[tauri::command]
pub async fn software_inventory(
    overrides: HashMap<String, String>,
    force: bool,
) -> Result<Inventory, String> {
    let mut inventory = tauri::async_runtime::spawn_blocking(move || {
        if force {
            software::clear_versions();
        }
        let mut scanned = software::scan("Orb runner", &overrides);
        apply_local_readiness(&mut scanned);
        scanned
    })
    .await
    .map_err(|e| e.to_string())?;
    software::releases(&mut inventory, force).await;
    Ok(inventory)
}
#[tauri::command]
pub async fn software_update(
    component: String,
    version: String,
    path: String,
) -> Result<UpdateJob, String> {
    tauri::async_runtime::spawn_blocking(move || software::queue(&component, &version, &path))
        .await
        .map_err(|e| e.to_string())?
}
#[tauri::command]
pub fn software_cancel(id: String) -> Result<(), String> {
    software::cancel(&id)
}
