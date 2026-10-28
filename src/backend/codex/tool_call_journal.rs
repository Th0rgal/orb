//! Durable app-server tool-call lifecycle journal.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PendingToolCall {
    pub id: String,
    pub name: String,
    pub start_payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "snake_case")]
enum Entry {
    Started {
        descriptor: PendingToolCall,
    },
    Completed {
        descriptor: PendingToolCall,
        /// A terminal native receipt means settled, including a failed command.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        receipt: Option<serde_json::Value>,
    },
}

pub struct ToolCallJournal {
    path: PathBuf,
}

fn lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

impl ToolCallJournal {
    pub fn at(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn new(session_id: &str, thread_id: &str) -> Self {
        let safe = |value: &str| {
            value
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                        c
                    } else {
                        '_'
                    }
                })
                .collect::<String>()
        };
        Self {
            path: std::env::temp_dir()
                .join("sandboxed-sh")
                .join("codex-tool-calls")
                .join(format!("{}-{}.json", safe(session_id), safe(thread_id))),
        }
    }

    async fn load_entries(&self) -> anyhow::Result<Vec<Entry>> {
        match tokio::fs::read(&self.path).await {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|err| anyhow::anyhow!("parse {}: {err}", self.path.display())),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(err) => Err(anyhow::anyhow!("read {}: {err}", self.path.display())),
        }
    }

    async fn store(&self, entries: &[Entry]) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                tokio::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700)).await?;
            }
        }
        let bytes = serde_json::to_vec_pretty(entries)?;
        let tmp = self.path.with_extension("json.tmp");
        let mut options = tokio::fs::OpenOptions::new();
        options.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            options.mode(0o600);
        }
        let mut file = options.open(&tmp).await?;
        file.write_all(&bytes).await?;
        file.sync_all().await?;
        drop(file);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600)).await?;
        }
        tokio::fs::rename(tmp, &self.path).await?;
        if let Some(parent) = self.path.parent() {
            tokio::fs::File::open(parent).await?.sync_all().await?;
        }
        Ok(())
    }

    pub async fn started(&self, descriptor: PendingToolCall) -> anyhow::Result<()> {
        let _guard = lock().lock().await;
        let mut entries = self.load_entries().await?;
        entries.retain(|entry| match entry {
            Entry::Started { descriptor: old }
            | Entry::Completed {
                descriptor: old, ..
            } => old.id != descriptor.id,
        });
        entries.push(Entry::Started { descriptor });
        self.store(&entries).await
    }

    pub async fn completed(&self, id: &str) -> anyhow::Result<()> {
        let _guard = lock().lock().await;
        let mut entries = self.load_entries().await?;
        for entry in &mut entries {
            if let Entry::Started { descriptor } = entry {
                if descriptor.id == id {
                    *entry = Entry::Completed {
                        descriptor: descriptor.clone(),
                        receipt: None,
                    };
                    self.store(&entries).await?;
                    break;
                }
            }
        }
        Ok(())
    }

    /// Reconcile only terminal tool receipts from an identity-checked native
    /// thread snapshot. A completed turn alone says nothing about a background
    /// command; an absent or still-running item remains fenced.
    pub async fn reconcile_native_receipts(
        &self,
        turns: &[serde_json::Value],
    ) -> anyhow::Result<()> {
        let _guard = lock().lock().await;
        let mut entries = self.load_entries().await?;
        let mut changed = false;
        for entry in &mut entries {
            let Entry::Started { descriptor } = entry else {
                continue;
            };
            let receipt = turns
                .iter()
                .filter_map(|turn| turn.get("items").and_then(|items| items.as_array()))
                .flatten()
                .find(|item| {
                    item["id"].as_str() == Some(descriptor.id.as_str())
                        && item["type"].as_str().is_some()
                        && item["type"] == descriptor.start_payload["type"]
                        && matches!(item["status"].as_str(), Some("completed" | "failed"))
                });
            if let Some(receipt) = receipt {
                *entry = Entry::Completed {
                    descriptor: descriptor.clone(),
                    receipt: Some(receipt.clone()),
                };
                changed = true;
            }
        }
        if changed {
            self.store(&entries).await?;
        }
        Ok(())
    }

    pub async fn pending(&self) -> anyhow::Result<Vec<PendingToolCall>> {
        Ok(self
            .load_entries()
            .await?
            .into_iter()
            .filter_map(|entry| match entry {
                Entry::Started { descriptor } => Some(descriptor),
                Entry::Completed { .. } => None,
            })
            .collect())
    }

    pub async fn clear(&self) -> anyhow::Result<()> {
        let _guard = lock().lock().await;
        match tokio::fs::remove_file(&self.path).await {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn native_receipt_reconciliation_requires_exact_terminal_tool() {
        let dir = tempfile::tempdir().unwrap();
        let journal = ToolCallJournal::at(dir.path().join("tools.json"));
        journal.started(PendingToolCall {
            id: "background-tool".into(), name: "bash".into(),
            start_payload: serde_json::json!({"id":"background-tool", "type":"commandExecution", "status":"inProgress"}),
        }).await.unwrap();
        for item in [
            serde_json::json!({"id":"background-tool", "type":"commandExecution", "status":"inProgress"}),
            serde_json::json!({"id":"other-tool", "type":"commandExecution", "status":"completed"}),
            serde_json::json!({"id":"background-tool", "type":"mcpToolCall", "status":"completed"}),
            serde_json::json!({"id":"background-tool", "type":"commandExecution"}),
        ] {
            journal
                .reconcile_native_receipts(&[
                    serde_json::json!({"status":"completed","items":[item]}),
                ])
                .await
                .unwrap();
            assert_eq!(journal.pending().await.unwrap().len(), 1);
        }
        let receipt = serde_json::json!({"id":"background-tool", "type":"commandExecution", "status":"failed", "exitCode":-1});
        let turns = [serde_json::json!({"status":"completed","items":[receipt.clone()]})];
        journal.reconcile_native_receipts(&turns).await.unwrap();
        journal.reconcile_native_receipts(&turns).await.unwrap();
        assert!(journal.pending().await.unwrap().is_empty());
        let entries = journal.load_entries().await.unwrap();
        assert!(
            matches!(&entries[0], Entry::Completed { receipt: Some(saved), .. } if saved == &receipt)
        );
    }

    #[tokio::test]
    async fn lifecycle_is_atomic_idempotent_and_clearable() {
        let dir = tempfile::tempdir().unwrap();
        let journal = ToolCallJournal::new(&uuid::Uuid::new_v4().to_string(), "thread");
        assert!(!journal.path.starts_with(dir.path()));
        let descriptor = PendingToolCall {
            id: "call-1".into(),
            name: "bash".into(),
            start_payload: serde_json::json!({"command": "do-once"}),
        };
        journal.started(descriptor.clone()).await.unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(journal.path.parent().unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
            assert_eq!(
                std::fs::metadata(&journal.path)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        journal.started(descriptor.clone()).await.unwrap();
        assert_eq!(journal.pending().await.unwrap(), vec![descriptor]);
        journal.completed("call-1").await.unwrap();
        journal.completed("call-1").await.unwrap();
        assert!(journal.pending().await.unwrap().is_empty());
        journal.clear().await.unwrap();
        assert!(!journal.path.exists());
    }
}
