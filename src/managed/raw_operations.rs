//! Durable at-most-once dispatch for explicitly requested raw guest operations.
//! A pending record is a permanent uncertainty fence, never permission to retry.
use super::{sha256_hex, MachineState, ManagedError, ManagedManager};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    time::Duration,
};

const MAX_CONTENT: usize = 64 * 1024;
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OperationRequest {
    pub idempotency_key: String,
    pub operation: Operation,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    Exec { command: String, timeout_secs: u64 },
    WriteFile { path: String, content: String },
    ReadFile { path: String },
}
impl Operation {
    fn kind(&self) -> &'static str {
        match self {
            Self::Exec { .. } => "exec",
            Self::WriteFile { .. } => "write_file",
            Self::ReadFile { .. } => "read_file",
        }
    }
    fn validate(&self) -> Result<(), ManagedError> {
        let valid = match self {
            Self::Exec {
                command,
                timeout_secs,
            } => {
                !command.is_empty()
                    && command.len() <= MAX_CONTENT
                    && !command.contains('\0')
                    && (1..=120).contains(timeout_secs)
            }
            Self::WriteFile { path, content } => valid_path(path) && content.len() <= MAX_CONTENT,
            Self::ReadFile { path } => valid_path(path),
        };
        if valid {
            Ok(())
        } else {
            Err(ManagedError::new(
                "invalid_operation",
                400,
                "Operation exceeds command, path, content or timeout limits",
            ))
        }
    }
}
fn valid_path(path: &str) -> bool {
    path.starts_with('/') && path.len() <= 4096 && !path.contains('\0')
}
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OperationReceipt {
    pub request_hash: String,
    /// pending, completed, or uncertain; only completed proves an HTTP result.
    pub status: String,
    pub created_at: chrono::DateTime<Utc>,
    pub finished_at: Option<chrono::DateTime<Utc>>,
    pub output: Option<String>,
    pub truncated: bool,
}
fn journal_error(_: impl std::fmt::Display) -> ManagedError {
    ManagedError::new(
        "journal_unavailable",
        503,
        "Cannot durably record operation; inspect the private operation journal",
    )
}
fn open_private(path: &Path, create_new: bool) -> std::io::Result<std::fs::File> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(create_new);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts.open(path)
}
fn write_synced(file: &mut std::fs::File, value: &OperationReceipt) -> Result<(), ManagedError> {
    let bytes = serde_json::to_vec(value).map_err(journal_error)?;
    file.write_all(&bytes).map_err(journal_error)?;
    file.sync_all().map_err(journal_error)
}
fn sync_dir(dir: &Path) -> Result<(), ManagedError> {
    std::fs::File::open(dir)
        .and_then(|f| f.sync_all())
        .map_err(journal_error)
}
fn prepare_dir(dir: &Path) -> Result<(), ManagedError> {
    fs::create_dir_all(dir).map_err(journal_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).map_err(journal_error)?;
    }
    if let Some(parent) = dir.parent() {
        sync_dir(parent)?;
    }
    Ok(())
}
/// None means this caller owns the newly persisted dispatch fence.
fn begin(
    path: &Path,
    pending: &OperationReceipt,
) -> Result<Option<OperationReceipt>, ManagedError> {
    let dir = path.parent().ok_or_else(|| journal_error("parent"))?;
    match open_private(path, true) {
        Ok(mut file) => {
            write_synced(&mut file, pending)?;
            sync_dir(dir)?;
            Ok(None)
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let bytes = fs::read(path).map_err(journal_error)?;
            // Partial records from a concurrent writer or crash fail closed.
            let prior: OperationReceipt = serde_json::from_slice(&bytes).map_err(journal_error)?;
            if prior.request_hash != pending.request_hash {
                return Err(ManagedError::new(
                    "idempotency_conflict",
                    409,
                    "Idempotency key was used for another operation",
                ));
            }
            if prior.status == "pending" {
                return Err(ManagedError::new("operation_uncertain", 409, "Operation is pending or its outcome is unknown; it will not be automatically repeated"));
            }
            Ok(Some(prior))
        }
        Err(e) => Err(journal_error(e)),
    }
}
fn finish(path: &Path, receipt: &OperationReceipt) -> Result<(), ManagedError> {
    let temp = path.with_extension(format!("{}.tmp", super::random_id()));
    let mut file = open_private(&temp, true).map_err(journal_error)?;
    write_synced(&mut file, receipt)?;
    fs::rename(&temp, path).map_err(journal_error)?;
    sync_dir(path.parent().ok_or_else(|| journal_error("parent"))?)
}
fn bounded(value: Value) -> (String, bool) {
    let mut text = value.to_string();
    let truncated = text.len() > MAX_CONTENT;
    if truncated {
        let mut end = MAX_CONTENT;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    (text, truncated)
}
impl ManagedManager {
    pub async fn raw_operation(
        &self,
        id: &str,
        tenant: &str,
        request: OperationRequest,
    ) -> Result<OperationReceipt, ManagedError> {
        let machine = self
            .get(id)
            .await
            .filter(|m| {
                !m.provisioning_mode.is_worker() && m.owner_user_id.as_deref() == Some(tenant)
            })
            .ok_or_else(|| ManagedError::new("not_found", 404, "Unknown raw managed machine"))?;
        if request.idempotency_key.is_empty()
            || request.idempotency_key.len() > 128
            || !request
                .idempotency_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-.:".contains(&b))
        {
            return Err(ManagedError::new(
                "invalid_idempotency_key",
                400,
                "Use 1-128 ASCII letters, digits, underscores, dashes, dots or colons",
            ));
        }
        request.operation.validate()?;
        let dir = self.dir.join("raw_operations");
        prepare_dir(&dir)?;
        let identity = serde_json::to_string(&(tenant, &machine.id, &request.idempotency_key))
            .map_err(journal_error)?;
        let path = dir.join(format!("{}.json", sha256_hex(&identity)));
        let hash = sha256_hex(&serde_json::to_string(&request.operation).map_err(journal_error)?);
        let mut receipt = OperationReceipt {
            request_hash: hash.clone(),
            status: "pending".into(),
            created_at: Utc::now(),
            finished_at: None,
            output: None,
            truncated: false,
        };
        // Replay is allowed after stop/destroy; new work still requires Online.
        if path.exists() {
            return begin(&path, &receipt)?.ok_or_else(|| journal_error("missing replay"));
        }
        if machine.state != MachineState::Online {
            return Err(ManagedError::new(
                "not_running",
                409,
                "Raw machine must be online",
            ));
        }
        let provider = self
            .provider
            .clone()
            .ok_or_else(|| ManagedError::new("disabled", 503, "No managed provider"))?;
        let pid = machine.provider_id.as_deref().ok_or_else(|| {
            ManagedError::new("not_running", 409, "Machine has no provider sandbox")
        })?;
        if let Some(prior) = begin(&path, &receipt)? {
            return Ok(prior);
        }
        self.update(&machine.id, |m| m.last_busy_at = Some(Utc::now()))
            .await;
        self.ledger_with(
            "raw_operation_started",
            &machine,
            json!({"operation_kind": request.operation.kind(), "request_hash": hash}),
        );
        let run = async {
            match &request.operation {
                Operation::Exec {
                    command,
                    timeout_secs,
                } => provider.raw_exec(pid, command, *timeout_secs).await,
                Operation::WriteFile { path, content } => provider
                    .raw_write_file(pid, path, content)
                    .await
                    .map(|_| json!({"written": true})),
                Operation::ReadFile { path } => {
                    provider
                        .raw_exec(
                            pid,
                            &format!("head -c {} -- {}", MAX_CONTENT + 1, shell_quote(path)),
                            30,
                        )
                        .await
                }
            }
        };
        let timeout = match &request.operation {
            Operation::Exec { timeout_secs, .. } => timeout_secs + 5,
            _ => 35,
        };
        match tokio::time::timeout(Duration::from_secs(timeout), run).await {
            Ok(Ok(value)) => {
                let (output, truncated) = bounded(value);
                receipt.status = "completed".into();
                receipt.output = Some(output);
                receipt.truncated = truncated;
            }
            _ => {
                receipt.status = "uncertain".into();
            }
        }
        receipt.finished_at = Some(Utc::now());
        finish(&path, &receipt)?;
        self.ledger_with("raw_operation_finished", &machine, json!({"operation_kind": request.operation.kind(), "request_hash": hash, "outcome": receipt.status}));
        Ok(receipt)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pending(hash: &str) -> OperationReceipt {
        OperationReceipt {
            request_hash: hash.into(),
            status: "pending".into(),
            created_at: Utc::now(),
            finished_at: None,
            output: None,
            truncated: false,
        }
    }
    #[test]
    fn durable_fence_rejects_crash_retry_and_changed_request() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("receipt.json");
        let mut receipt = pending("one");
        assert!(begin(&path, &receipt).unwrap().is_none());
        // New reader after a crash sees pending, never dispatch permission.
        assert_eq!(
            begin(&path, &pending("one")).unwrap_err().error,
            "operation_uncertain"
        );
        assert_eq!(
            begin(&path, &pending("two")).unwrap_err().error,
            "idempotency_conflict"
        );
        receipt.status = "completed".into();
        receipt.output = Some("result".into());
        finish(&path, &receipt).unwrap();
        assert_eq!(
            begin(&path, &pending("one"))
                .unwrap()
                .unwrap()
                .output
                .as_deref(),
            Some("result")
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
    #[test]
    fn concurrent_admission_has_one_dispatch_owner() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("receipt.json");
        let results = std::thread::scope(|scope| {
            let a = scope.spawn(|| begin(&path, &pending("same")));
            let b = scope.spawn(|| begin(&path, &pending("same")));
            [a.join().unwrap(), b.join().unwrap()]
        });
        assert_eq!(results.iter().filter(|r| matches!(r, Ok(None))).count(), 1);
    }
    #[test]
    fn output_is_utf8_bounded_and_paths_are_shell_quoted() {
        let (output, truncated) = bounded(json!("💫".repeat(MAX_CONTENT)));
        assert!(truncated);
        assert!(output.len() <= MAX_CONTENT);
        assert_eq!(
            shell_quote("/tmp/a'$(touch /bad)"),
            "'/tmp/a'\\''$(touch /bad)'"
        );
        assert!(Operation::Exec {
            command: "true".into(),
            timeout_secs: 121
        }
        .validate()
        .is_err());
        assert!(Operation::ReadFile {
            path: "relative".into()
        }
        .validate()
        .is_err());
    }
}
