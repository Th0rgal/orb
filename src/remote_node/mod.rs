//! Remote runner nodes: core-side configuration, wire protocol, HTTP client
//! and fleet monitoring for the `sandboxed-node` runner binary.
//!
//! Module layout:
//! - [`protocol`]: shared wire types (heartbeat, leases, job payloads) used by
//!   both core and the node binary.
//! - [`client`]: core-side HTTP client for talking to nodes.
//! - [`monitor`]: background fleet monitor caching per-node statuses and
//!   recent dispatch outcomes.
//!
//! Everything public is re-exported here so call sites keep using
//! `crate::remote_node::*` unchanged.

pub mod client;
pub mod job_ledger;
pub mod monitor;
pub mod protocol;

pub use client::*;
pub use monitor::*;
pub use protocol::*;

use axum::http::HeaderMap;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use thiserror::Error;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RemoteNodeStatus {
    Disabled,
    Unknown,
    Online,
    Degraded,
    Offline,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteNodeOverview {
    pub enabled: bool,
    pub configured_nodes: usize,
    pub status: RemoteNodeStatus,
    pub notes: Vec<String>,
}

impl RemoteNodeOverview {
    pub fn from_env() -> Self {
        match RemoteNodeSettings::from_env() {
            Ok(settings) => Self::from_settings(&settings),
            Err(err) => Self {
                enabled: false,
                configured_nodes: 0,
                status: RemoteNodeStatus::Degraded,
                notes: vec![format!("Remote node configuration is invalid: {err}")],
            },
        }
    }

    pub fn from_settings(settings: &RemoteNodeSettings) -> Self {
        let mut notes = Vec::new();
        if !settings.enabled {
            notes.push(
                "Remote mission nodes are disabled; local/container execution is unchanged."
                    .to_string(),
            );
        } else if settings.nodes.is_empty() {
            notes.push(
                "Remote nodes are enabled, but no node endpoints are configured.".to_string(),
            );
        } else {
            notes.push(
                "Remote node MVP is enabled for explicit selected-node missions.".to_string(),
            );
        }
        let status = if settings.enabled {
            // Derive the live status from the fleet monitor cache when
            // available instead of the old hardcoded `Unknown`.
            monitor::global_fleet()
                .and_then(|fleet| fleet.aggregate_status())
                .unwrap_or(RemoteNodeStatus::Unknown)
        } else {
            RemoteNodeStatus::Disabled
        };
        Self {
            enabled: settings.enabled,
            configured_nodes: settings.nodes.len(),
            status,
            notes,
        }
    }
}

#[derive(Debug, Error)]
pub enum RemoteNodeError {
    #[error("remote nodes are disabled; set SANDBOXED_REMOTE_NODES_ENABLED=true")]
    Disabled,
    #[error("remote node '{0}' is not configured")]
    UnknownNode(String),
    #[error("remote node '{0}' has no token in {1}")]
    MissingToken(String, String),
    #[error("invalid remote node config: {0}")]
    InvalidConfig(String),
    #[error("remote node connection failed before the request was sent: {0}")]
    Connect(String),
    #[error("remote node request failed: {0}")]
    Request(String),
    #[error("remote node rejected request with HTTP {status}: {body}")]
    Rejected { status: u16, body: String },
    #[error("invalid lease token: {0}")]
    InvalidLease(String),
}

impl RemoteNodeError {
    pub fn is_not_found(&self) -> bool {
        matches!(self, Self::Rejected { status: 404, .. })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteNodeConfig {
    pub id: String,
    pub base_url: String,
    pub token_env: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub labels: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteNodeSettings {
    pub enabled: bool,
    pub nodes: Vec<RemoteNodeConfig>,
}

impl RemoteNodeSettings {
    pub fn from_env() -> Result<Self, RemoteNodeError> {
        Self::from_raw(
            parse_bool_env("SANDBOXED_REMOTE_NODES_ENABLED").unwrap_or(false),
            std::env::var("SANDBOXED_REMOTE_NODES").ok(),
        )
    }

    fn from_raw(enabled: bool, raw: Option<String>) -> Result<Self, RemoteNodeError> {
        let raw = match raw {
            Some(raw) if !raw.trim().is_empty() => raw,
            _ => {
                return Ok(Self {
                    enabled,
                    nodes: vec![],
                })
            }
        };
        match parse_node_list(&raw) {
            Ok(nodes) => Ok(Self { enabled, nodes }),
            // A stale or legacy SANDBOXED_REMOTE_NODES value (e.g. the old
            // URL-only format) must not prevent core startup while the
            // feature is disabled.
            Err(_) if !enabled => Ok(Self {
                enabled,
                nodes: vec![],
            }),
            Err(err) => Err(err),
        }
    }

    /// Static (operator-enrolled) nodes only. Use this for every path that
    /// hands a node credentials or private material beyond the per-job
    /// projected harness auth: managed nodes are an untrusted class.
    pub fn static_node(&self, id: &str) -> Option<&RemoteNodeConfig> {
        self.nodes.iter().find(|node| node.id == id)
    }

    /// Static nodes first, then live managed (dial-out) nodes. Managed nodes
    /// are deliberately absent from `nodes`, so automatic placement, which
    /// iterates `nodes`, never selects them.
    pub fn node(&self, id: &str) -> Option<&RemoteNodeConfig> {
        self.nodes
            .iter()
            .find(|node| node.id == id)
            .or_else(|| crate::managed::node_config(id))
    }
}

fn parse_bool_env(key: &str) -> Option<bool> {
    let raw = std::env::var(key).ok()?;
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

/// Resolve a node bearer token by its `token_env` name: managed nodes keep
/// theirs in memory (never in the process environment, so harness children
/// cannot inherit it); static nodes read the environment.
pub fn node_token(token_env: &str) -> Result<String, std::env::VarError> {
    if let Some(token) = crate::managed::node_token(token_env) {
        return Ok(token);
    }
    std::env::var(token_env)
}

pub fn default_token_env(node_id: &str) -> String {
    let suffix = node_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("SANDBOXED_REMOTE_NODE_{}_TOKEN", suffix)
}

pub fn parse_node_list(raw: &str) -> Result<Vec<RemoteNodeConfig>, RemoteNodeError> {
    raw.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(|entry| {
            let (id, rest) = entry.split_once('=').ok_or_else(|| {
                RemoteNodeError::InvalidConfig(format!(
                    "entry '{entry}' must be id=url or id=url|TOKEN_ENV"
                ))
            })?;
            let id = id.trim();
            if id.is_empty() {
                return Err(RemoteNodeError::InvalidConfig(
                    "node id cannot be empty".to_string(),
                ));
            }
            let mut parts = rest.split('|').map(str::trim);
            let base_url = parts
                .next()
                .filter(|url| !url.is_empty())
                .ok_or_else(|| RemoteNodeError::InvalidConfig(format!("{id} has empty url")))?;
            let token_env = parts
                .next()
                .filter(|token_env| !token_env.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| default_token_env(id));
            if parts.next().is_some() {
                return Err(RemoteNodeError::InvalidConfig(format!(
                    "{id} has too many pipe-separated fields"
                )));
            }
            Ok(RemoteNodeConfig {
                id: id.to_string(),
                base_url: base_url.trim_end_matches('/').to_string(),
                token_env,
                labels: None,
            })
        })
        .collect()
}

pub fn placement_for_selected_node<'a>(
    settings: &'a RemoteNodeSettings,
    selected_node_id: Option<&str>,
) -> Result<Option<&'a RemoteNodeConfig>, RemoteNodeError> {
    let Some(node_id) = selected_node_id.filter(|id| !id.trim().is_empty()) else {
        return Ok(None);
    };
    if !settings.enabled {
        return Err(RemoteNodeError::Disabled);
    }
    settings
        .node(node_id)
        .map(Some)
        .ok_or_else(|| RemoteNodeError::UnknownNode(node_id.to_string()))
}

pub fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

pub async fn run_lease_command(
    node_id: &str,
    token_secret: &str,
    work_root: PathBuf,
    store: &crate::node::JobStore,
    request: LeaseRequest,
) -> Result<ExecuteResponse, RemoteNodeError> {
    let claims = validate_lease_token(
        &request.lease_token,
        token_secret,
        node_id,
        SCOPE_MISSION_EXECUTE,
        chrono::Utc::now(),
    )?;
    if claims.mission_id != request.mission_id {
        return Err(RemoteNodeError::InvalidLease(
            "lease is scoped to a different mission".to_string(),
        ));
    }
    let mission_dir = work_root.join(request.mission_id.to_string());
    tokio::fs::create_dir_all(&mission_dir)
        .await
        .map_err(|e| RemoteNodeError::Request(e.to_string()))?;
    let max_secs = std::env::var("SANDBOXED_NODE_MAX_JOB_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(crate::node::runner::DEFAULT_MAX_JOB_SECS)
        .max(1);
    let (exit_code, stdout, stderr) = crate::node::scratch::run(
        store,
        &work_root,
        request.mission_id,
        None,
        crate::node::runner::run_captured_command(
            raw_command_with_work_root(&request.command, &mission_dir, Some(&work_root), None),
            max_secs,
        ),
    )
    .await
    .map_err(|e| RemoteNodeError::Request(e.to_string()))?;
    Ok(ExecuteResponse {
        accepted: true,
        exit_code,
        stdout,
        stderr,
    })
}

const LAKE_ADVISORY_WRAPPER: &str = r#"#!/bin/sh
# Installed by sandboxed-node in <work-root>/caches/bin/lake so mission shells
# steer agents toward turbo-lean on heavy `lake build|check|test` commands
# while transparently delegating `lake setup-file`, `lake env`, `lake exe`, etc.
self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
real_lake=""
if [ -n "${ELAN_HOME:-}" ] && [ -x "${ELAN_HOME}/bin/lake" ]; then
  cand_dir=$(CDPATH='' cd -- "$(dirname -- "${ELAN_HOME}/bin/lake")" 2>/dev/null && pwd -P || true)
  if [ "$cand_dir" != "$self_dir" ]; then
    real_lake="${ELAN_HOME}/bin/lake"
  fi
fi
if [ -z "$real_lake" ]; then
  old_ifs=$IFS
  IFS=':'
  for dir in ${PATH:-/usr/local/bin:/usr/bin:/bin}; do
    [ -n "$dir" ] || continue
    if [ -x "$dir/lake" ]; then
      cand_dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P || true)
      if [ "$cand_dir" != "$self_dir" ]; then
        real_lake="$dir/lake"
        break
      fi
    fi
  done
  IFS=$old_ifs
fi
if [ -z "$real_lake" ]; then
  printf 'sandboxed-node: lake binary not found in ELAN_HOME or PATH\n' >&2
  exit 127
fi
heavy_lake=0
case "${1:-}" in
  build|check|test) heavy_lake=1 ;;
  env)
    case "${2:-}" in
      lake)
        case "${3:-}" in
          build|check|test) heavy_lake=1 ;;
        esac
        ;;
    esac
    ;;
esac
if [ "$heavy_lake" -eq 1 ] && [ "${SANDBOXED_ALLOW_RAW_LAKE:-0}" != "1" ] && [ "${SANDBOXED_REMOTE_EXECUTION:-0}" != "1" ]; then
  printf '[sandboxed-node] warning: raw `lake %s` duplicates multi-GiB .lake/.olean artifacts per worktree and risks filling node storage.\n[sandboxed-node] use `turbo-lean` instead (reuses the host shared CAS in TURBO_LEAN_HOME):\n  - full/target build: `turbo-lean build` (or `turbo-lean build --project-dir <dir>`)\n  - single-file proof check: `turbo-lean check <path/to/File.lean>`\n  (set SANDBOXED_ALLOW_RAW_LAKE=1 only if raw Lake is strictly required.)\n' "${1:-build}" >&2
fi
exec "$real_lake" "$@"
"#;

/// Prepare `<work-root>/caches/{elan,turbo-lean,bin}` and install the advisory
/// `lake` wrapper so remote mission turns share one toolchain/CAS store per
/// host instead of duplicating `.elan` and `.lake` across mission worktrees.
pub(crate) fn prepare_shared_mission_caches(
    work_root: &std::path::Path,
) -> std::io::Result<Vec<(String, String)>> {
    let caches = work_root.join("caches");
    let elan = caches.join("elan");
    let turbo_lean = caches.join("turbo-lean");
    let bin = caches.join("bin");
    std::fs::create_dir_all(&elan)?;
    std::fs::create_dir_all(&turbo_lean)?;
    std::fs::create_dir_all(&bin)?;

    let lake_shim = bin.join("lake");
    let needs_write = match std::fs::read(&lake_shim) {
        Ok(existing) => existing != LAKE_ADVISORY_WRAPPER.as_bytes(),
        Err(_) => true,
    };
    if needs_write {
        let tmp = bin.join(format!(".lake.tmp.{}", uuid::Uuid::new_v4().simple()));
        std::fs::write(&tmp, LAKE_ADVISORY_WRAPPER.as_bytes())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
        }
        std::fs::rename(&tmp, &lake_shim)?;
    }

    let base_path =
        std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".to_string());
    let mut path_entries = vec![bin.display().to_string()];
    let rustup = caches.join("rustup");
    let cargo = caches.join("cargo");
    let has_shared_rustup =
        rustup.join("toolchains").is_dir() || cargo.join("bin/rustup").is_file();
    if has_shared_rustup && cargo.join("bin").is_dir() {
        path_entries.push(cargo.join("bin").display().to_string());
    }
    path_entries.push(elan.join("bin").display().to_string());
    path_entries.push(base_path);

    let mut envs = vec![
        ("ELAN_HOME".to_string(), elan.display().to_string()),
        (
            "TURBO_LEAN_HOME".to_string(),
            turbo_lean.display().to_string(),
        ),
        ("PATH".to_string(), path_entries.join(":")),
    ];
    if has_shared_rustup {
        envs.push(("RUSTUP_HOME".to_string(), rustup.display().to_string()));
        envs.push(("CARGO_HOME".to_string(), cargo.display().to_string()));
    }
    Ok(envs)
}

/// Construct a raw command without inheriting the node service environment.
/// The service bearer/signing tokens must never be visible to repository or
/// mission code. Explicit payload env is added back after a minimal runtime
/// baseline.
#[cfg(test)]
pub(crate) fn raw_command(
    command: &str,
    cwd: &std::path::Path,
    env: Option<&std::collections::HashMap<String, String>>,
) -> Command {
    raw_command_with_work_root(command, cwd, None, env)
}

pub(crate) fn raw_command_with_work_root(
    command: &str,
    cwd: &std::path::Path,
    work_root: Option<&std::path::Path>,
    env: Option<&std::collections::HashMap<String, String>>,
) -> Command {
    let mut cmd = Command::new("bash");
    cmd.arg("-lc")
        .arg(command)
        .current_dir(cwd)
        .env_clear()
        .env(
            "PATH",
            std::env::var("PATH").unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".to_string()),
        )
        .env("HOME", cwd)
        .env("LANG", "C.UTF-8");
    if let Some(root) = work_root {
        match prepare_shared_mission_caches(root) {
            Ok(cache_envs) => {
                cmd.envs(cache_envs);
            }
            Err(error) => {
                tracing::warn!(
                    work_root = %root.display(),
                    %error,
                    "failed to prepare shared mission caches; continuing with baseline env"
                );
            }
        }
    }
    if let Some(env) = env {
        cmd.envs(env);
    }
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[tokio::test]
    async fn raw_command_does_not_inherit_node_secrets() {
        let dir = tempfile::tempdir().unwrap();
        let secret_name = "SANDBOXED_NODE_TEST_ONLY_SECRET_44EDEB08";
        std::env::set_var(secret_name, "must-not-leak");

        let output = raw_command(
            &format!("test -z \"${secret_name:-}\" && printf safe"),
            dir.path(),
            None,
        )
        .output()
        .await
        .unwrap();
        std::env::remove_var(secret_name);

        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "safe");
    }

    #[test]
    fn parses_env_node_list_with_default_token_env() {
        let nodes = parse_node_list(
            "babylon=http://203.0.113.10:3088,nippur=http://203.0.113.11:3088|NIPPUR_TOKEN",
        )
        .unwrap();
        assert_eq!(nodes[0].id, "babylon");
        assert_eq!(nodes[0].token_env, "SANDBOXED_REMOTE_NODE_BABYLON_TOKEN");
        assert_eq!(nodes[1].token_env, "NIPPUR_TOKEN");
    }

    #[test]
    fn disabled_settings_tolerate_legacy_node_list_format() {
        let settings =
            RemoteNodeSettings::from_raw(false, Some("http://n1:9100,http://n2:9100".to_string()))
                .unwrap();
        assert!(!settings.enabled);
        assert!(settings.nodes.is_empty());

        assert!(RemoteNodeSettings::from_raw(
            true,
            Some("http://n1:9100,http://n2:9100".to_string())
        )
        .is_err());
    }

    #[tokio::test]
    async fn run_lease_command_rejects_mismatched_mission_id() {
        let claims = LeaseClaims {
            mission_id: Uuid::new_v4(),
            node_id: "babylon".to_string(),
            scope: SCOPE_MISSION_EXECUTE.to_string(),
            expires_at: chrono::Utc::now().timestamp() + 60,
            job_id: None,
        };
        let token = create_lease_token(&claims, "node-secret").unwrap();
        let work_root = tempfile::tempdir().unwrap();
        let request = LeaseRequest {
            mission_id: Uuid::new_v4(),
            node_id: "babylon".to_string(),
            lease_token: token,
            command: "true".to_string(),
        };
        let err = run_lease_command(
            "babylon",
            "node-secret",
            work_root.path().to_path_buf(),
            &crate::node::JobStore::open(work_root.path()).await.unwrap(),
            request,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, RemoteNodeError::InvalidLease(_)));
    }

    #[tokio::test]
    async fn run_lease_command_preserves_separate_output_and_exit_code() {
        let mission_id = Uuid::new_v4();
        let claims = LeaseClaims {
            mission_id,
            node_id: "babylon".into(),
            scope: SCOPE_MISSION_EXECUTE.into(),
            expires_at: chrono::Utc::now().timestamp() + 60,
            job_id: None,
        };
        let token = create_lease_token(&claims, "node-secret").unwrap();
        let work_root = tempfile::tempdir().unwrap();
        let result = run_lease_command(
            "babylon",
            "node-secret",
            work_root.path().to_path_buf(),
            &crate::node::JobStore::open(work_root.path()).await.unwrap(),
            LeaseRequest {
                mission_id,
                node_id: "babylon".into(),
                lease_token: token,
                command: "printf scratch > \"$TMPDIR/probe\"; printf out; printf err >&2; exit 7"
                    .into(),
            },
        )
        .await
        .unwrap();
        assert!(result.accepted);
        let scratch = std::fs::read_dir(work_root.path().join(".scratch"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(std::fs::read(scratch.join("probe")).unwrap(), b"scratch");
        assert!(scratch.join("opencode").is_dir());
        assert_eq!(result.exit_code, Some(7));
        assert_eq!(result.stdout, "out");
        assert_eq!(result.stderr, "err");
    }

    #[tokio::test]
    async fn raw_command_with_work_root_wires_shared_lean_caches_and_advisory_lake_shim() {
        use std::os::unix::fs::PermissionsExt;

        let work_root = tempfile::tempdir().unwrap();
        let mission_dir = work_root.path().join("mission-a");
        std::fs::create_dir_all(&mission_dir).unwrap();

        let fake_elan_bin = work_root.path().join("caches/elan/bin");
        std::fs::create_dir_all(&fake_elan_bin).unwrap();
        let fake_lake = fake_elan_bin.join("lake");
        std::fs::write(&fake_lake, "#!/bin/sh\nprintf 'real-lake:%s' \"$*\"\n").unwrap();
        std::fs::set_permissions(&fake_lake, std::fs::Permissions::from_mode(0o755)).unwrap();

        let (code, stdout, stderr) = crate::node::runner::run_captured_command(
            raw_command_with_work_root(
                "printf '%s|%s|%s|' \"$ELAN_HOME\" \"$TURBO_LEAN_HOME\" \"${RUSTUP_HOME:-unset}\"; lake setup-file Foo.lean; printf '|'; lake build; printf '|'; lake check",
                &mission_dir,
                Some(work_root.path()),
                None,
            ),
            10,
        )
        .await
        .unwrap();
        assert_eq!(code, Some(0));
        let expected_elan = work_root.path().join("caches/elan");
        let expected_tl = work_root.path().join("caches/turbo-lean");
        assert_eq!(
            stdout,
            format!(
                "{}|{}|unset|real-lake:setup-file Foo.lean|real-lake:build|real-lake:check",
                expected_elan.display(),
                expected_tl.display()
            )
        );
        assert!(
            stderr.contains("use `turbo-lean` instead")
                && stderr.contains("turbo-lean build")
                && stderr.contains("turbo-lean check"),
            "expected actionable turbo-lean warning on lake build/check, got: {stderr:?}"
        );
        assert_eq!(
            stderr.matches("use `turbo-lean` instead").count(),
            2,
            "lake setup-file must stay silent while build and check warn: {stderr:?}"
        );

        // Opt-out via SANDBOXED_ALLOW_RAW_LAKE=1 suppresses the stderr warning,
        // and shared RUSTUP_HOME/CARGO_HOME activate once toolchains exist.
        std::fs::create_dir_all(work_root.path().join("caches/rustup/toolchains")).unwrap();
        let mut override_env = std::collections::HashMap::new();
        override_env.insert("SANDBOXED_ALLOW_RAW_LAKE".to_string(), "1".to_string());
        let (code2, stdout2, stderr2) = crate::node::runner::run_captured_command(
            raw_command_with_work_root(
                "printf '%s|' \"${RUSTUP_HOME:-unset}\"; lake build",
                &mission_dir,
                Some(work_root.path()),
                Some(&override_env),
            ),
            10,
        )
        .await
        .unwrap();
        assert_eq!(code2, Some(0));
        assert_eq!(
            stdout2,
            format!(
                "{}|real-lake:build",
                work_root.path().join("caches/rustup").display()
            )
        );
        assert!(
            stderr2.is_empty(),
            "expected empty stderr with opt-out, got: {stderr2:?}"
        );
    }

    #[tokio::test]
    async fn captured_command_discards_excess_output_while_running() {
        let work_root = tempfile::tempdir().unwrap();
        let command = raw_command(
            "head -c 17825792 /dev/zero; printf done >&2",
            work_root.path(),
            None,
        );
        let (code, stdout, stderr) = crate::node::runner::run_captured_command(command, 10)
            .await
            .unwrap();
        assert_eq!(code, Some(0));
        assert!(stdout.starts_with('\0'));
        assert!(stdout.ends_with("[node output truncated to fit 16 MiB JSON limit]\n"));
        assert!(serde_json::to_vec(&stdout).unwrap().len() <= 16 * 1024 * 1024);
        assert_eq!(stderr, "done");
    }

    #[test]
    fn placement_requires_enabled_selected_configured_node() {
        let node = RemoteNodeConfig {
            id: "babylon".to_string(),
            base_url: "http://127.0.0.1:3088".to_string(),
            token_env: "TOKEN".to_string(),
            labels: None,
        };
        let disabled = RemoteNodeSettings {
            enabled: false,
            nodes: vec![node.clone()],
        };
        assert!(matches!(
            placement_for_selected_node(&disabled, Some("babylon")),
            Err(RemoteNodeError::Disabled)
        ));
        let enabled = RemoteNodeSettings {
            enabled: true,
            nodes: vec![node],
        };
        assert_eq!(
            placement_for_selected_node(&enabled, Some("babylon"))
                .unwrap()
                .unwrap()
                .id,
            "babylon"
        );
        assert!(matches!(
            placement_for_selected_node(&enabled, Some("ashur")),
            Err(RemoteNodeError::UnknownNode(_))
        ));
    }
}
