//! Per-process routing. Never rewrites the user's OpenCode configuration.
use crate::local_agents::{self, StartRequest};
use serde_json::{json, Value};
use std::time::Duration;

fn configuration(base: &str, route: &str, mission: &str) -> Value {
    json!({
        "model": format!("orb-routing/{route}"),
        "small_model": format!("orb-routing/{route}"),
        "enabled_providers": ["orb-routing"],
        "provider": {"orb-routing": {
            "npm": "@ai-sdk/openai-compatible", "name": "Sandboxed routing",
            "options": {"baseURL": format!("{}/v1",base.trim_end_matches('/')),
                "apiKey": "{env:ORB_ROUTING_KEY}",
                "headers": {"x-sandboxed-mission-id": mission}},
            "models": {(route): {"name": route, "id": route}}
        }}
    })
}

pub async fn start(request: StartRequest, base: &str, token: &str) -> Result<(), String> {
    let generation = *local_agents::launch_fence(&request.id)
        .lock()
        .map_err(|e| e.to_string())?;
    // This entry point is only used for a newly registered local origin.
    // Core creates that immutable origin at run generation 1.
    start_fenced(request, base, token, Some(generation), 1).await
}

pub async fn start_fenced(
    mut request: StartRequest,
    base: &str,
    token: &str,
    stop_generation: Option<u64>,
    run_generation: u64,
) -> Result<(), String> {
    // Also covers scheduled wake-ups and resumes outside the composer.
    let response = reqwest::Client::new()
        .get(format!(
            "{}/api/control/missions/{}/digest",
            base.trim_end_matches('/'),
            request.id
        ))
        .bearer_auth(token)
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|_| "Cannot read the mission project before skill preparation")?;
    if !response.status().is_success() {
        return Err(format!(
            "Cannot read the mission project ({}); reconnect and retry",
            response.status()
        ));
    }
    let mission: Value = response
        .json()
        .await
        .map_err(|_| "Invalid mission project identity")?;
    if let Some(project) = mission["project"]
        .as_str()
        .or_else(|| mission["project"]["project"].as_str())
    {
        crate::context_service::project_skills_prepare(
            crate::context_service::Request {
                endpoint: base.into(),
                token: token.into(),
                project: project.into(),
                paths: vec![],
            },
            request.cwd.clone(),
            request.harness.clone(),
            Some(request.bin.clone()),
        )
        .await?;
    } else {
        let output = std::process::Command::new("sh")
            .args([
                "-c",
                include_str!("../../../shared/prepare_project_skills.sh"),
                "orb-project-skills",
                "",
                &request.harness,
                include_str!("../../../shared/prepare_project_skills.py"),
                &request.cwd,
            ])
            .output()
            .map_err(|e| format!("Prepare project skills: {e}"))?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).into_owned());
        }
    }
    let mut launch_env = crate::mcp_launch::environment(&request.id, base, token).await?;
    crate::local_wakeups::prepare(
        &mut request,
        &crate::run_recovery::Connection {
            api_url: base.into(),
            token: token.into(),
        },
        run_generation,
    )?;
    if request.harness != "opencode" {
        return local_agents::start_with_env_fenced(request, &launch_env, stop_generation);
    }
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| "Could not initialize routing connection")?;
    let base = base.trim_end_matches('/');
    let response = http
        .get(format!("{base}/api/model-routing/chains"))
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| "Could not load OpenCode routes")?;
    if !response.status().is_success() {
        return Err(format!(
            "Could not load OpenCode routes ({})",
            response.status()
        ));
    }
    let routes: Vec<Value> = response
        .json()
        .await
        .map_err(|_| "Invalid routing catalog")?;
    let selected = request.model.as_deref().filter(|s| !s.is_empty());
    let route = routes
        .iter()
        .find(|r| match selected {
            Some(id) => r["id"].as_str() == Some(id),
            None => r["is_default"].as_bool() == Some(true),
        })
        .and_then(|r| r["id"].as_str())
        .ok_or("The selected OpenCode route is unavailable. Refresh the model list.")?
        .to_string();
    // Dedicated key, never the dashboard JWT. It exists only for this run and is
    // revoked on launch failure or termination (including stopped generations).
    let response = http
        .post(format!("{base}/api/proxy-keys"))
        .bearer_auth(token)
        .json(&json!({"name":format!("Orb OpenCode run {}",request.id)}))
        .send()
        .await
        .map_err(|_| "Could not authorize OpenCode routing")?;
    if !response.status().is_success() {
        return Err(format!(
            "Could not authorize OpenCode routing ({})",
            response.status()
        ));
    }
    let key: Value = response
        .json()
        .await
        .map_err(|_| "Invalid proxy authorization response")?;
    let secret = key["key"].as_str().ok_or("Missing proxy credential")?;
    let key_id = key["id"]
        .as_str()
        .ok_or("Missing proxy credential identity")?
        .to_string();
    let config = configuration(base, &route, &request.id);
    request.model = Some(format!("orb-routing/{route}"));
    let mission = request.id.clone();
    launch_env.extend([
        ("OPENCODE_CONFIG_CONTENT".into(), config.to_string()),
        ("ORB_ROUTING_KEY".into(), secret.into()),
    ]);
    let started = local_agents::start_with_env_fenced(request, &launch_env, stop_generation);
    let generation = local_agents::native_generation(&mission);
    let (base, token) = (base.to_string(), token.to_string());
    let failed = started.is_err();
    tauri::async_runtime::spawn(async move {
        if !failed {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                if local_agents::native_generation(&mission) != generation
                    || local_agents::local_agents_poll(mission.clone())
                        .map(|s| s.done)
                        .unwrap_or(true)
                {
                    break;
                }
            }
        }
        for _ in 0..3 {
            if http
                .delete(format!("{base}/api/proxy-keys/{key_id}"))
                .bearer_auth(&token)
                .send()
                .await
                .is_ok_and(|r| r.status().is_success() || r.status().as_u16() == 404)
            {
                break;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
    started
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_route_identity_and_keeps_secrets_out_of_config() {
        for route in ["builtin/smart", "reviewer", "team/custom"] {
            let c = configuration("https://core.test/", route, "mission");
            assert_eq!(c["model"], format!("orb-routing/{route}"));
            assert_eq!(c["provider"]["orb-routing"]["models"][route]["id"], route);
            assert_eq!(
                c["provider"]["orb-routing"]["options"]["baseURL"],
                "https://core.test/v1"
            );
            assert_eq!(c["enabled_providers"], json!(["orb-routing"]));
        }
    }
}
