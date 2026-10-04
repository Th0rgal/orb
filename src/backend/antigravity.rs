use anyhow::Error;
use async_trait::async_trait;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::backend::events::ExecutionEvent;
use crate::backend::{AgentInfo, Backend, Session, SessionConfig};

/// Google Antigravity backend that launches the `agy` CLI for mission execution.
pub struct AntigravityBackend {
    id: String,
    name: String,
}

impl AntigravityBackend {
    pub fn new() -> Self {
        Self {
            id: "antigravity".to_string(),
            name: "Google Antigravity".to_string(),
        }
    }
}

impl Default for AntigravityBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Backend for AntigravityBackend {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn cli_names(&self) -> &'static [&'static str] {
        &["agy"]
    }

    async fn list_agents(&self) -> Result<Vec<AgentInfo>, Error> {
        Ok(vec![AgentInfo {
            id: "build".to_string(),
            name: "Build".to_string(),
        }])
    }

    async fn create_session(&self, config: SessionConfig) -> Result<Session, Error> {
        Ok(Session {
            id: uuid::Uuid::new_v4().to_string(),
            directory: config.directory,
            model: config.model,
            agent: config.agent,
        })
    }

    async fn send_message_streaming(
        &self,
        _session: &Session,
        _message: &str,
    ) -> Result<(mpsc::Receiver<ExecutionEvent>, JoinHandle<()>), Error> {
        anyhow::bail!("Google Antigravity streaming is handled by the mission runner")
    }
}

pub fn registry_entry() -> Arc<dyn Backend> {
    Arc::new(AntigravityBackend::new())
}
