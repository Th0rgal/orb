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
    if bytes.len() > MAX_RECEIPT_BYTES {
        return Err(journal_error("oversized receipt"));
    }
    file.write_all(&bytes).map_err(journal_error)?;
    file.sync_all().map_err(journal_error)
}
fn sync_dir(dir: &Path) -> Result<(), ManagedError> {
    std::fs::File::open(dir)
        .and_then(|f| f.sync_all())
        .map_err(journal_error)
}
fn prepare_dir(dir: &Path) -> Result<(), ManagedError> {
    match fs::create_dir(dir) {
        Ok(()) => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
                    .map_err(journal_error)?;
            }
            if let Some(parent) = dir.parent() {
                sync_dir(parent)?;
            }
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && dir.is_dir() => Ok(()),
        Err(e) => Err(journal_error(e)),
    }
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
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(Some(replay(path, pending)?)),
        Err(e) => Err(journal_error(e)),
    }
}
// Reserve up to 132 KiB per receipt: JSON may escape the bounded output again.
const MAX_RECEIPT_BYTES: usize = 2 * MAX_CONTENT + 4096;
#[derive(Clone, Copy)]
struct JournalCaps {
    global: usize,
    tenant: usize,
    machine: usize,
    per_minute: usize,
}
const JOURNAL_CAPS: JournalCaps = JournalCaps {
    global: 4096,
    tenant: 512,
    machine: 256,
    per_minute: 60,
};
#[derive(Serialize, Deserialize)]
struct Scope {
    tenant: String,
    machine: String,
}
fn capacity() -> ManagedError {
    ManagedError::new(
        "operation_capacity",
        429,
        "Raw operation capacity reached; existing receipt replay remains available",
    )
}
fn lock_file(path: &Path) -> Result<std::fs::File, ManagedError> {
    let mut opts = OpenOptions::new();
    opts.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts.open(path).map_err(journal_error)
}
fn replay(path: &Path, pending: &OperationReceipt) -> Result<OperationReceipt, ManagedError> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(journal_error)?
        .take((MAX_RECEIPT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(journal_error)?;
    if bytes.len() > MAX_RECEIPT_BYTES {
        return Err(journal_error("oversized receipt"));
    }
    let prior: OperationReceipt = serde_json::from_slice(&bytes).map_err(journal_error)?;
    if prior.request_hash != pending.request_hash {
        return Err(ManagedError::new(
            "idempotency_conflict",
            409,
            "Idempotency key was used for another operation",
        ));
    }
    if prior.status == "pending" {
        return Err(ManagedError::new(
            "operation_uncertain",
            409,
            "Operation is pending or its outcome is unknown; it will not be automatically repeated",
        ));
    }
    if !matches!(prior.status.as_str(), "completed" | "uncertain") {
        return Err(journal_error("invalid receipt"));
    }
    Ok(prior)
}
/// Count/create is serialized across processes; the returned OS lease spans I/O.
fn admit(
    path: &Path,
    pending: &OperationReceipt,
    scope: &Scope,
    caps: JournalCaps,
) -> Result<(Option<OperationReceipt>, Option<std::fs::File>), ManagedError> {
    use fs2::FileExt;
    use std::io::{Read, Seek, SeekFrom};
    let dir = path.parent().ok_or_else(|| journal_error("parent"))?;
    prepare_dir(dir)?;
    if path.exists() {
        return Ok((Some(replay(path, pending)?), None));
    }
    let admission = lock_file(&dir.join(".admission.lock"))?;
    admission.try_lock_exclusive().map_err(|_| capacity())?;
    if path.exists() {
        return Ok((Some(replay(path, pending)?), None));
    }
    let mut global = 0;
    let mut tenant = 0;
    let mut machine = 0;
    let mut recent = 0;
    let mut machine_recent = 0;
    let mut global_recent = 0;
    for entry in fs::read_dir(dir).map_err(journal_error)? {
        let entry = entry.map_err(journal_error)?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        // Temp artifacts and legacy unscoped receipts consume conservative capacity.
        let parts: Vec<_> = name.split('_').collect();
        global += 1;
        let mine = parts.len() != 3 || parts[0] == scope.tenant;
        let same_machine = parts.len() != 3 || (mine && parts[1] == scope.machine);
        tenant += usize::from(mine);
        machine += usize::from(same_machine);
        let meta = entry.metadata().map_err(journal_error)?;
        if !meta.is_file() || meta.len() > MAX_RECEIPT_BYTES as u64 {
            return Err(journal_error("unexpected journal entry"));
        }
        if meta
            .modified()
            .map_err(journal_error)?
            .elapsed()
            .map_or(true, |age| age < Duration::from_secs(60))
        {
            global_recent += 1;
            recent += usize::from(mine);
            machine_recent += usize::from(same_machine);
        }
    }
    if global >= caps.global
        || tenant >= caps.tenant
        || machine >= caps.machine
        || recent >= caps.per_minute
        || machine_recent >= 10
        || global_recent >= 240
    {
        return Err(capacity());
    }
    // Fixed 16 slot files bound active provider requests without creating a file
    // per tenant/machine. Admission lock makes lease metadata reads race-free.
    let mut slot = None;
    let mut tenant_active = 0;
    let mut machine_active = 0;
    for index in 0..16 {
        let file = lock_file(&dir.join(format!(".slot-{index}")))?;
        if file.try_lock_exclusive().is_ok() {
            if slot.is_none() {
                slot = Some(file);
            }
        } else {
            let mut bytes = Vec::new();
            file.take(1024)
                .read_to_end(&mut bytes)
                .map_err(journal_error)?;
            let active: Scope = serde_json::from_slice(&bytes).map_err(journal_error)?;
            if active.tenant == scope.tenant {
                tenant_active += 1;
            }
            if active.tenant == scope.tenant && active.machine == scope.machine {
                machine_active += 1;
            }
        }
    }
    if tenant_active >= 4 || machine_active >= 1 {
        return Err(capacity());
    }
    let mut slot = slot.ok_or_else(capacity)?;
    slot.set_len(0).map_err(journal_error)?;
    slot.seek(SeekFrom::Start(0)).map_err(journal_error)?;
    slot.write_all(&serde_json::to_vec(scope).map_err(journal_error)?)
        .map_err(journal_error)?;
    let prior = begin(path, pending)?;
    Ok((prior, Some(slot)))
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
        let identity = serde_json::to_string(&(tenant, &machine.id, &request.idempotency_key))
            .map_err(journal_error)?;
        let scope = Scope {
            tenant: sha256_hex(tenant),
            machine: sha256_hex(&machine.id),
        };
        let legacy = dir.join(format!("{}.json", sha256_hex(&identity)));
        let path = if legacy.exists() {
            legacy
        } else {
            dir.join(format!(
                "{}_{}_{}.json",
                scope.tenant,
                scope.machine,
                sha256_hex(&identity)
            ))
        };
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
            return tokio::task::spawn_blocking(move || replay(&path, &receipt))
                .await
                .map_err(journal_error)?;
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
        let pending = receipt.clone();
        let journal_path = path.clone();
        let (prior, lease) = tokio::task::spawn_blocking(move || {
            admit(&journal_path, &pending, &scope, JOURNAL_CAPS)
        })
        .await
        .map_err(journal_error)??;
        if let Some(prior) = prior {
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
        let final_receipt = receipt.clone();
        tokio::task::spawn_blocking(move || {
            let _lease = lease; // Release only after the final receipt is durable.
            finish(&path, &final_receipt)
        })
        .await
        .map_err(journal_error)??;
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
    fn scoped_path(dir: &Path, scope: &Scope, key: &str) -> std::path::PathBuf {
        dir.join(format!("{}_{}_{}.json", scope.tenant, scope.machine, key))
    }
    fn small_caps() -> JournalCaps {
        JournalCaps {
            global: 2,
            tenant: 2,
            machine: 1,
            per_minute: 60,
        }
    }
    #[test]
    fn journal_caps_survive_restart_and_allow_replay_at_capacity() {
        let dir = tempfile::tempdir().unwrap();
        let scope = Scope {
            tenant: "t".into(),
            machine: "m".into(),
        };
        let path = scoped_path(dir.path(), &scope, "first");
        let mut receipt = pending("request");
        let (prior, lease) = admit(&path, &receipt, &scope, small_caps()).unwrap();
        assert!(prior.is_none());
        receipt.status = "completed".into();
        finish(&path, &receipt).unwrap();
        drop(lease);
        // No in-memory counter is involved; reopening the same directory is enough.
        assert_eq!(
            admit(
                &scoped_path(dir.path(), &scope, "second"),
                &pending("new"),
                &scope,
                small_caps()
            )
            .unwrap_err()
            .error,
            "operation_capacity"
        );
        assert_eq!(
            admit(&path, &pending("request"), &scope, small_caps())
                .unwrap()
                .0
                .unwrap()
                .status,
            "completed"
        );
        let other = Scope {
            tenant: "other".into(),
            machine: "other".into(),
        };
        let other_path = scoped_path(dir.path(), &other, "second");
        let (_, lease) = admit(&other_path, &pending("other"), &other, small_caps()).unwrap();
        drop(lease);
        let third = Scope {
            tenant: "third".into(),
            machine: "third".into(),
        };
        assert_eq!(
            admit(
                &scoped_path(dir.path(), &third, "third"),
                &pending("third"),
                &third,
                small_caps()
            )
            .unwrap_err()
            .error,
            "operation_capacity"
        );
    }
    #[test]
    fn active_machine_lease_refuses_new_keys_but_replays_completed_receipts() {
        let dir = tempfile::tempdir().unwrap();
        let scope = Scope {
            tenant: "t".into(),
            machine: "m".into(),
        };
        let caps = JournalCaps {
            global: 100,
            tenant: 100,
            machine: 100,
            per_minute: 60,
        };
        let path = scoped_path(dir.path(), &scope, "first");
        let mut receipt = pending("one");
        let (_, lease) = admit(&path, &receipt, &scope, caps).unwrap();
        assert_eq!(
            admit(
                &scoped_path(dir.path(), &scope, "second"),
                &pending("two"),
                &scope,
                caps
            )
            .unwrap_err()
            .error,
            "operation_capacity"
        );
        receipt.status = "completed".into();
        finish(&path, &receipt).unwrap();
        assert!(admit(&path, &pending("one"), &scope, caps)
            .unwrap()
            .0
            .is_some());
        drop(lease);
        assert!(admit(
            &scoped_path(dir.path(), &scope, "second"),
            &pending("two"),
            &scope,
            caps
        )
        .is_ok());
    }
    #[test]
    fn concurrent_admission_cannot_exceed_global_receipt_budget() {
        let dir = tempfile::tempdir().unwrap();
        let caps = JournalCaps {
            global: 1,
            tenant: 10,
            machine: 10,
            per_minute: 60,
        };
        let admitted = std::thread::scope(|threads| {
            let joins: Vec<_> = (0..8)
                .map(|i| {
                    let root = dir.path();
                    threads.spawn(move || {
                        let scope = Scope {
                            tenant: format!("t{i}"),
                            machine: format!("m{i}"),
                        };
                        admit(
                            &scoped_path(root, &scope, "key"),
                            &pending("request"),
                            &scope,
                            caps,
                        )
                        .is_ok()
                    })
                })
                .collect();
            joins
                .into_iter()
                .map(|j| j.join().unwrap())
                .filter(|accepted| *accepted)
                .count()
        });
        assert_eq!(admitted, 1);
    }
}
