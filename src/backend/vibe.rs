use anyhow::Error;
use async_trait::async_trait;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::backend::events::ExecutionEvent;
use crate::backend::{AgentInfo, Backend, Session, SessionConfig};

/// Mistral Vibe backend that launches the `vibe-acp` CLI for mission execution.
pub struct VibeBackend {
    id: String,
    name: String,
}

impl VibeBackend {
    pub fn new() -> Self {
        Self {
            id: "vibe".to_string(),
            name: "Mistral Vibe".to_string(),
        }
    }
}

impl Default for VibeBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Backend for VibeBackend {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn cli_names(&self) -> &'static [&'static str] {
        &["vibe-acp"]
    }

    async fn check_auth_configured(&self, ctx: &crate::backend::AuthContext<'_>) -> Option<bool> {
        Some(core_auth_configured(ctx.working_dir).await)
    }

    async fn list_agents(&self) -> Result<Vec<AgentInfo>, Error> {
        Ok(vec![
            AgentInfo {
                id: "build".to_string(),
                name: "Build".to_string(),
            },
            AgentInfo {
                id: "plan".into(),
                name: "Plan".into(),
            },
        ])
    }

    async fn create_session(&self, _config: SessionConfig) -> Result<Session, Error> {
        anyhow::bail!("Native Vibe sessions are allocated by the mission runner")
    }

    async fn send_message_streaming(
        &self,
        _session: &Session,
        _message: &str,
    ) -> Result<(mpsc::Receiver<ExecutionEvent>, JoinHandle<()>), Error> {
        anyhow::bail!("Mistral Vibe streaming is handled by the mission runner")
    }
}

pub fn registry_entry() -> Arc<dyn Backend> {
    Arc::new(VibeBackend::new())
}

/// Core and node execution use Core's proxy, not the execution user's Vibe login.
/// Mistral browser subscriptions persist their credential in `api_key` too.
pub(crate) async fn core_auth_configured(working_dir: &std::path::Path) -> bool {
    let Ok(contents) = tokio::fs::read(working_dir.join(crate::util::AI_PROVIDERS_PATH)).await
    else {
        return false;
    };
    let Ok(providers) = serde_json::from_slice::<Vec<crate::ai_providers::AIProvider>>(&contents)
    else {
        return false;
    };
    providers.iter().any(|provider| {
        provider.enabled
            && provider.provider_type == crate::ai_providers::ProviderType::Mistral
            && provider
                .api_key
                .as_deref()
                .is_some_and(|key| !key.trim().is_empty())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai_providers::{AIProvider, ProviderType};

    #[tokio::test]
    async fn core_readiness_requires_an_enabled_mistral_credential() {
        let directory = tempfile::tempdir().unwrap();
        let settings = serde_json::json!({});
        let context = crate::backend::AuthContext {
            working_dir: directory.path(),
            settings: &settings,
            secrets: None,
        };
        let backend = VibeBackend::new();
        assert_eq!(backend.check_auth_configured(&context).await, Some(false));

        let path = directory.path().join(crate::util::AI_PROVIDERS_PATH);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "invalid provider configuration").unwrap();
        assert_eq!(backend.check_auth_configured(&context).await, Some(false));

        let mut account = AIProvider::new(ProviderType::Mistral, "Mistral".into());
        for credential in [None, Some(""), Some("  ")] {
            account.api_key = credential.map(str::to_owned);
            std::fs::write(&path, serde_json::to_vec(&vec![&account]).unwrap()).unwrap();
            assert_eq!(backend.check_auth_configured(&context).await, Some(false));
        }

        account.api_key = Some("fixture-key".into());
        account.enabled = false;
        std::fs::write(&path, serde_json::to_vec(&vec![&account]).unwrap()).unwrap();
        assert_eq!(backend.check_auth_configured(&context).await, Some(false));

        account.enabled = true;
        account.provider_type = ProviderType::OpenAI;
        std::fs::write(&path, serde_json::to_vec(&vec![&account]).unwrap()).unwrap();
        assert_eq!(backend.check_auth_configured(&context).await, Some(false));

        account.provider_type = ProviderType::Mistral;
        for subscription in [false, true] {
            account.mistral_subscription = subscription;
            std::fs::write(&path, serde_json::to_vec(&vec![&account]).unwrap()).unwrap();
            assert_eq!(backend.check_auth_configured(&context).await, Some(true));
        }
    }
}
