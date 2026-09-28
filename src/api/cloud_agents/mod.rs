//! Hosted execution receipts belong to missions, never to a parallel project tracker.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub mod chatgpt;
pub mod cursor;
pub mod grok;
pub mod http;
pub mod worker;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Chatgpt,
    GrokBot,
    CursorCloud,
}
impl Provider {
    pub fn backend(self) -> &'static str {
        match self {
            Self::Chatgpt => "cloud_chatgpt",
            Self::GrokBot => "cloud_grok_bot",
            Self::CursorCloud => "cloud_cursor",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Queued,
    Submitting,
    SubmissionUncertain,
    Running,
    WaitingUser,
    ReconnectRequired,
    ResponseComplete,
    Failed,
    CancelRequested,
    Cancelled,
    Incompatible,
}
impl Phase {
    pub fn terminal(self) -> bool {
        matches!(
            self,
            Self::ResponseComplete | Self::Failed | Self::Cancelled
        )
    }
    pub fn mission_status(self) -> &'static str {
        match self {
            Self::ResponseComplete | Self::WaitingUser => "awaiting_user",
            Self::Failed | Self::Incompatible => "failed",
            Self::Cancelled => "interrupted",
            Self::ReconnectRequired | Self::SubmissionUncertain => "blocked",
            _ => "active",
        }
    }
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    pub models: bool,
    pub attachments: bool,
    pub repository: bool,
    pub follow_up: bool,
    pub cancel: bool,
    pub detailed_events: bool,
    pub artifacts: bool,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub model_params: Vec<ModelParam>,
    pub provider: Provider,
    pub account: String,
    pub repository: Option<String>,
    pub git_ref: Option<String>,
    pub model: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelParam {
    pub id: String,
    pub value: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Turn {
    #[serde(default)]
    pub model_params: Vec<ModelParam>,
    #[serde(default)]
    pub model: Option<String>,
    pub key: String,
    pub prompt: String,
    pub phase: Phase,
    pub external_id: Option<String>,
    pub cursor: Option<String>,
    pub result: Option<String>,
    pub detail: Option<String>,
    pub artifacts: Vec<Value>,
    pub branches: Vec<Value>,
    pub usage: Option<Value>,
}
impl Turn {
    pub fn new(key: String, prompt: String) -> Self {
        Self {
            model: None,
            model_params: vec![],
            key,
            prompt,
            phase: Phase::Queued,
            external_id: None,
            cursor: None,
            result: None,
            detail: None,
            artifacts: vec![],
            branches: vec![],
            usage: None,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Execution {
    #[serde(default)]
    pub parent_mission_id: Option<Uuid>,
    pub mission_id: Uuid,
    pub request_key: String,
    pub request_signature: String,
    pub revision: u64,
    pub selection: Selection,
    pub external_id: Option<String>,
    pub external_url: Option<String>,
    pub turns: Vec<Turn>,
}
impl Execution {
    pub fn enqueue(&mut self, key: String, prompt: String) -> Result<(), String> {
        if let Some(old) = self.turns.iter().find(|t| t.key == key) {
            return if old.prompt == prompt {
                Ok(())
            } else {
                Err("Message key already used for different content".into())
            };
        }
        if self
            .turns
            .iter()
            .any(|t| matches!(t.phase, Phase::SubmissionUncertain | Phase::Incompatible))
        {
            return Err("Reconcile the previous submission before sending another prompt".into());
        }
        self.turns.push(Turn::new(key, prompt));
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub run_id: String,
    pub id: String,
    pub kind: String,
    pub data: Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct Account {
    pub id: String,
    pub provider: Provider,
    pub label: String,
    pub available: bool,
    pub experimental: bool,
    pub reason: Option<String>,
    pub capabilities: Capabilities,
}

/// Secrets are resolved inside an adapter; this contract only accepts an account reference.
#[async_trait::async_trait]
pub trait Adapter: Send + Sync {
    async fn availability(&self) -> Result<(), String>;
    async fn create(&self, execution: &Execution, turn: &Turn) -> Result<(String, String), String>;
    async fn follow_up(&self, external_id: &str, turn: &Turn) -> Result<String, String>;
    async fn observe(&self, external_id: &str, run_id: &str) -> Result<Value, String>;
    async fn results(&self, external_id: &str) -> Result<Value, String>;
    async fn cancel(&self, external_id: &str, run_id: &str) -> Result<(), String>;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn loss_of_transport_is_not_completion() {
        for phase in [
            Phase::SubmissionUncertain,
            Phase::ReconnectRequired,
            Phase::CancelRequested,
            Phase::Running,
        ] {
            assert!(!phase.terminal());
        }
    }
    #[test]
    fn duplicate_message_is_not_a_second_turn() {
        let mut e = Execution {
            parent_mission_id: None,
            mission_id: Uuid::new_v4(),
            request_key: "create".into(),
            request_signature: "test".into(),
            revision: 0,
            selection: Selection {
                provider: Provider::CursorCloud,
                account: "test".into(),
                repository: None,
                git_ref: None,
                model: None,
                model_params: vec![],
            },
            external_id: None,
            external_url: None,
            turns: vec![],
        };
        e.enqueue("1".into(), "hello".into()).unwrap();
        e.enqueue("1".into(), "hello".into()).unwrap();
        assert_eq!(e.turns.len(), 1);
        assert!(e.enqueue("1".into(), "different".into()).is_err());
        e.turns[0].phase = Phase::SubmissionUncertain;
        assert!(e.enqueue("2".into(), "again".into()).is_err());
    }
}

#[cfg(test)]
mod cursor_canary;
