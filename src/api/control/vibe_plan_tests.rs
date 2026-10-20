use super::*;
#[tokio::test]
async fn remote_vibe_requires_current_core_credentials() {
    let directory = tempfile::tempdir().unwrap();
    let plan = plan_remote_harness(None, "vibe", None, Some("inspect")).unwrap();
    assert!(validate_remote_vibe_auth(directory.path(), &plan)
        .await
        .is_err());
    let path = directory.path().join(crate::util::AI_PROVIDERS_PATH);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut provider = crate::ai_providers::AIProvider::new(
        crate::ai_providers::ProviderType::Mistral,
        "Mistral".into(),
    );
    provider.api_key = Some("fixture-key".into());
    std::fs::write(&path, serde_json::to_vec(&[&provider]).unwrap()).unwrap();
    assert!(validate_remote_vibe_auth(directory.path(), &plan)
        .await
        .is_ok());
    provider.enabled = false;
    std::fs::write(&path, serde_json::to_vec(&[&provider]).unwrap()).unwrap();
    assert!(validate_remote_vibe_auth(directory.path(), &plan)
        .await
        .is_err());
    let raw = RemoteHarnessPlan::Raw {
        command: "true".into(),
    };
    assert!(validate_remote_vibe_auth(directory.path(), &raw)
        .await
        .is_ok());
}

#[test]
fn vibe_model_keeps_its_proxy_provider_prefix() {
    assert_eq!(
        normalize_model_override_for_backend(Some("vibe"), " mistral/mistral-medium-latest "),
        Some("mistral/mistral-medium-latest".into())
    );
}

#[test]
fn vibe_remote_plan_preserves_read_only_mode() {
    let plan = plan_remote_harness(None, "vibe", None, Some("/plan inspect this")).unwrap();
    let execution = remote_execution_for_plan(&plan, "https://core.test", "test-key");
    assert!(execution.command.contains("'--mode' 'plan'"));
}

#[test]
fn vibe_large_remote_prompt_is_staged_outside_argv() {
    let prompt = "large context ".repeat(30_000);
    let plan = plan_remote_harness(None, "vibe", None, Some(&prompt)).unwrap();
    let execution = remote_execution_for_plan(&plan, "https://core.test", "test-key");
    assert!(execution.command.len() < INLINE_PROMPT_LIMIT);
    assert!(execution.command.contains("'--prompt-file' '/dev/fd/3'"));
    let env = execution.env.unwrap();
    let mut restored = String::new();
    for part in 0..10 {
        if let Some(value) = env.get(&format!("{STDIN_PROMPT_ENV}{part}")) {
            restored.push_str(value);
        }
    }
    assert_eq!(restored, prompt.trim());
}

#[test]
fn vibe_remote_plan_uses_proxy_without_exposing_the_key_in_argv() {
    let plan = plan_remote_harness(
        None,
        "vibe",
        Some("mistral/mistral-vibe-cli-latest"),
        Some("hello"),
    )
    .unwrap();
    assert!(plan.uses_core_proxy());
    let execution = remote_execution_for_plan(&plan, "https://core.test", "private-test-key");
    assert!(execution.command.starts_with("exec python3 "));
    assert!(!execution.command.contains("private-test-key"));
    let env = execution.env.unwrap();
    assert_eq!(env["SANDBOXED_VIBE_PROXY_URL"], "https://core.test/v1");
    assert_eq!(env["SANDBOXED_VIBE_PROXY_KEY"], "private-test-key");
    assert!(execution.managed_auth.is_empty());
}
