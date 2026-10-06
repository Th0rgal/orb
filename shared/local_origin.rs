//! Wire record for a new, native-owned local mission. Never used to adopt an
//! existing Core mission. Sequence numbers make reconnect/replay idempotent.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Origin {
    pub id: uuid::Uuid,
    pub run_id: uuid::Uuid,
    pub client_id: uuid::Uuid,
    pub title: String,
    pub project: String,
    pub backend: String,
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cyber_access: Option<crate::cyber_access::Mode>,
    pub cwd: String,
    pub prompt: String,
    pub created_at: String,
    #[serde(default)]
    pub tags: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub origin: Origin,
    pub sequence: u64,
    pub text: String,
    pub status: String,
    #[serde(default)]
    pub error: Option<String>,
}
impl Snapshot {
    pub fn validate(&self) -> Result<(), String> {
        if let Some(effort) = self.origin.effort.as_deref() {
            let accepted = match self.origin.backend.as_str() {
                "antigravity" => matches!(effort, "low" | "medium" | "high"),
                "codex" | "claudecode" => {
                    matches!(effort, "low" | "medium" | "high" | "xhigh" | "max")
                }
                _ => false,
            };
            if !accepted {
                return Err("Invalid local reasoning effort for harness".into());
            }
        }
        if self.sequence == 0 || self.sequence > i64::MAX as u64 {
            return Err("Invalid sequence".into());
        }
        if !matches!(
            self.status.as_str(),
            "active" | "awaiting_user" | "failed" | "interrupted"
        ) {
            return Err("Invalid local status".into());
        }
        if self.origin.id.is_nil() || self.origin.run_id.is_nil() || self.origin.client_id.is_nil()
        {
            return Err("Missing local identity".into());
        }
        if self.origin.project.is_empty()
            || self.origin.project.len() > 256
            || self.origin.project.contains(['/', '\\'])
            || self.origin.project.starts_with('.')
        {
            return Err("Invalid project".into());
        }
        if self.origin.title.len() > 4096
            || self.origin.prompt.len() > 1024 * 1024
            || self.text.len() > 8 * 1024 * 1024
        {
            return Err("Local transcript exceeds sync limits".into());
        }
        if self.origin.tags.len() > 64
            || self
                .origin
                .tags
                .iter()
                .any(|t| !t.starts_with("orb-folder:") || t.len() > 1024)
        {
            return Err("Invalid local folder tags".into());
        }
        Ok(())
    }
}
