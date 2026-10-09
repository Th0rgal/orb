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
