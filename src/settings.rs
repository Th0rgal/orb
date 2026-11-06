//! Global settings storage.
//!
//! Persists user-configurable settings to disk at `{working_dir}/.sandboxed-sh/settings.json`.
//! Environment variables are used as initial defaults when no settings file exists.

use arc_swap::ArcSwap;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

/// Global cached max parallel missions value.
/// A value of 0 means "unset" and callers should fall back to their default.
static MAX_PARALLEL_MISSIONS_CACHED: AtomicUsize = AtomicUsize::new(0);
/// Global cached max concurrent command tasks value.
/// A value of 0 means "unset" and callers should fall back to their default.
static MAX_CONCURRENT_TASKS_CACHED: AtomicUsize = AtomicUsize::new(0);
/// Global cached per-account Google / Antigravity proxy concurrency limit.
/// A value of 0 means "unset" and callers fall back to `PROXY_GOOGLE_MAX_CONCURRENCY` (default 10).
static GOOGLE_MAX_CONCURRENCY_CACHED: AtomicUsize = AtomicUsize::new(0);

/// Default per-account in-flight concurrency cap for Google and Antigravity proxy requests.
pub const DEFAULT_GOOGLE_MAX_CONCURRENCY: usize = 10;
/// Upper bound on configurable per-account Google and Antigravity proxy concurrency.
pub const MAX_GOOGLE_ACCOUNT_CONCURRENCY: usize = 128;

/// Default repo path for sandboxed.sh source (used for self-updates).
pub const DEFAULT_SANDBOXED_REPO_PATH: &str = "/opt/sandboxed-sh/vaduz-v1";

/// Fallback Claude Code version installed into container workspaces when no
/// pin is configured (settings `harness_versions.claude_code` or the
/// `SANDBOXED_SH_CLAUDECODE_VERSION` env var).
pub const DEFAULT_CLAUDE_CODE_VERSION: &str = "2.1.139";

/// Per-harness version pins for container workspace bootstrap.
///
/// `None` for a harness means "no pin": Claude Code falls back to
/// [`DEFAULT_CLAUDE_CODE_VERSION`], the others install latest-if-missing.
/// A pinned harness is reinstalled whenever `--version` stops matching the
/// pin, so editing these (Settings UI / `PUT /api/settings`) takes effect on
/// the next workspace build or rebuild without a redeploy.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HarnessVersionPolicy {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opencode: Option<String>,
}

impl HarnessVersionPolicy {
    /// Effective Claude Code version: env override, then settings pin, then
    /// the built-in default.
    pub fn effective_claude_code(&self) -> String {
        std::env::var("SANDBOXED_SH_CLAUDECODE_VERSION")
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .or_else(|| self.claude_code.clone())
            .unwrap_or_else(|| DEFAULT_CLAUDE_CODE_VERSION.to_string())
    }
}

/// Globally cached harness version policy, refreshed whenever settings are
/// loaded, updated, or reloaded. Lets code without a `SettingsStore` handle
/// (e.g. the system component update checks) read the current pins.
static HARNESS_VERSIONS_CACHED: std::sync::OnceLock<ArcSwap<HarnessVersionPolicy>> =
    std::sync::OnceLock::new();

fn harness_versions_cell() -> &'static ArcSwap<HarnessVersionPolicy> {
    HARNESS_VERSIONS_CACHED.get_or_init(|| ArcSwap::from_pointee(HarnessVersionPolicy::default()))
}

/// Current harness version policy from the global cache.
pub fn harness_versions_cached() -> HarnessVersionPolicy {
    (**harness_versions_cell().load()).clone()
}

/// Refresh the global harness version cache.
pub fn set_harness_versions_cached(policy: Option<&HarnessVersionPolicy>) {
    harness_versions_cell().store(Arc::new(policy.cloned().unwrap_or_default()));
}

/// Authentication settings managed via the dashboard.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AuthSettings {
    /// PBKDF2 password hash (format: `pbkdf2:iterations:hex_salt:hex_hash`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password_hash: Option<String>,
    /// ISO 8601 timestamp of last password change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password_changed_at: Option<String>,
}

/// Bitwarden Secrets Manager (`bws`) integration settings.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BitwardenSettings {
    /// AES-256-GCM encrypted Machine Account access token (`<encrypted v="1">...</encrypted>`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encrypted_access_token: Option<String>,
    /// Optional custom Bitwarden server URL (`BWS_SERVER_URL`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_url: Option<String>,
    /// Default Bitwarden project UUID selected in the Secrets UI (defaults to `paloma`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_project_id: Option<String>,
    /// Mapping from Paloma project slug (e.g. `paloma`) to Bitwarden project UUID.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub project_bindings: std::collections::BTreeMap<String, String>,
    /// Paloma project slug -> Bitwarden project UUIDs its missions may read
    /// without asking. Anything else goes through an approved grant.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub default_access: std::collections::BTreeMap<String, Vec<String>>,
}

/// Opt-in Orb usage telemetry forwarded to a telemetry hub
/// (`Th0rgal/telemetry-hub`). Off unless `enabled` is set.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrbTelemetrySettings {
    /// Forward `orb.*` UI, approval and turn events. Default: off.
    #[serde(default)]
    pub enabled: bool,
    /// Also forward scrubbed prompt text (`orb.prompt.v1`). Separate opt-in.
    #[serde(default)]
    pub prompts_enabled: bool,
    /// Hub base URL (default `https://telemetry.thomas.md`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hub_url: Option<String>,
    /// Owner namespace on the hub. Never `community`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    /// AES-256-GCM encrypted `tl_live_` hub token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encrypted_token: Option<String>,
}

/// Global application settings.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Settings {
    /// Git remote URL for the configuration library.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub library_remote: Option<String>,
    /// Path to the sandboxed.sh source repo (used for self-updates).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandboxed_repo_path: Option<String>,
    /// Dashboard-managed auth settings (password hash, etc.).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<AuthSettings>,
    /// Maximum number of missions that can run in parallel.
    /// When None, falls back to the MAX_PARALLEL_MISSIONS env var (default: 1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_parallel_missions: Option<usize>,
    /// Maximum number of command-mode tasks that can run concurrently.
    /// When None, falls back to the MAX_CONCURRENT_TASKS env var (default: 5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_concurrent_tasks: Option<usize>,
    /// Maximum concurrent in-flight OrbRouter requests per Google or Antigravity account.
    /// When None, falls back to `PROXY_GOOGLE_MAX_CONCURRENCY` (default: 10).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub google_max_concurrency: Option<usize>,
    /// Whether retention inventory reports old terminal mission directories.
    /// Retention never authorizes discard. None means disabled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_cleanup_enabled: Option<bool>,
    /// Minimum age in days for advisory retention candidates. Defaults to 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_cleanup_days: Option<u32>,
    /// Legacy setting retained for API/config compatibility. Parked and
    /// resumable directories are never discarded by age.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_cleanup_stopped_days: Option<u32>,
    /// Legacy setting retained for compatibility. Unknown directories require
    /// reconciliation; absence from the mission index never authorizes purge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_cleanup_orphans_enabled: Option<bool>,
    /// Model for the Ask assistant (sidecar co-pilot). When None, falls back to
    /// the `ASK_ASSISTANT_MODEL` env var, then the built-in default
    /// (`gpt-oss-120b`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ask_assistant_model: Option<String>,
    /// Model for mission titles & status lines. Only routable values (a
    /// Routing chain id or a provider/model passthrough) are honored; when
    /// None or non-routable the auto provider ladder picks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata_model: Option<String>,
    /// Version pins for harness CLIs installed into container workspaces.
    /// When None, every harness uses its built-in default behavior.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness_versions: Option<HarnessVersionPolicy>,
    /// Bitwarden Secrets Manager (`bws`) integration settings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitwarden: Option<BitwardenSettings>,
    /// Opt-in usage telemetry (off by default).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orb_telemetry: Option<OrbTelemetrySettings>,
}

/// In-memory store for global settings with disk persistence.
#[derive(Debug)]
pub struct SettingsStore {
    settings: ArcSwap<Settings>,
    writer: Mutex<()>,
    storage_path: PathBuf,
}

impl SettingsStore {
    /// Create a new settings store, loading from disk if available.
    ///
    /// If no settings file exists, uses environment variables as defaults:
    /// - `LIBRARY_REMOTE` - Git remote URL for the configuration library
    pub async fn new(working_dir: &Path) -> Self {
        let storage_path = working_dir.join(".sandboxed-sh/settings.json");

        let settings = if storage_path.exists() {
            match Self::load_from_path(&storage_path) {
                Ok(s) => {
                    tracing::info!("Loaded settings from {}", storage_path.display());
                    s
                }
                Err(e) => {
                    tracing::warn!(
                        "Failed to load settings from {}: {}, using defaults",
                        storage_path.display(),
                        e
                    );
                    Self::defaults_from_env()
                }
            }
        } else {
            tracing::info!(
                "No settings file found at {}, using environment defaults",
                storage_path.display()
            );
            Self::defaults_from_env()
        };

        set_harness_versions_cached(settings.harness_versions.as_ref());
        set_google_max_concurrency_cached(settings.google_max_concurrency);

        Self {
            settings: ArcSwap::from_pointee(settings),
            writer: Mutex::new(()),
            storage_path,
        }
    }

    /// Load settings from environment variables as initial defaults.
    fn defaults_from_env() -> Settings {
        let max_parallel_missions = std::env::var("MAX_PARALLEL_MISSIONS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|v| *v >= 1);
        let max_concurrent_tasks = std::env::var("MAX_CONCURRENT_TASKS")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|v| *v >= 1);
        let google_max_concurrency = std::env::var("PROXY_GOOGLE_MAX_CONCURRENCY")
            .ok()
            .and_then(|v| v.trim().parse::<usize>().ok())
            .filter(|v| *v >= 1)
            .map(|v| v.min(MAX_GOOGLE_ACCOUNT_CONCURRENCY));

        Settings {
            library_remote: std::env::var("LIBRARY_REMOTE").ok().or_else(|| {
                Some("https://github.com/Th0rgal/sandboxed-library-template.git".to_string())
            }),
            sandboxed_repo_path: std::env::var("SANDBOXED_SH_REPO_PATH")
                .or_else(|_| std::env::var("SANDBOXED_REPO_PATH"))
                .ok()
                .or_else(|| Some(DEFAULT_SANDBOXED_REPO_PATH.to_string())),
            auth: None,
            max_parallel_missions,
            max_concurrent_tasks,
            google_max_concurrency,
            auto_cleanup_enabled: None,
            auto_cleanup_days: None,
            auto_cleanup_stopped_days: None,
            auto_cleanup_orphans_enabled: None,
            ask_assistant_model: std::env::var("ASK_ASSISTANT_MODEL").ok(),
            metadata_model: None,
            harness_versions: None,
            bitwarden: None,
            orb_telemetry: None,
        }
    }

    /// Get the current Bitwarden settings.
    pub async fn get_bitwarden(&self) -> BitwardenSettings {
        self.settings.load().bitwarden.clone().unwrap_or_default()
    }

    /// Update the Bitwarden settings and persist to disk.
    pub async fn set_bitwarden(&self, bitwarden: BitwardenSettings) -> Result<(), std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        next.bitwarden = Some(bitwarden);
        self.settings.store(Arc::new(next.clone()));
        self.save_snapshot(&next).await
    }

    /// Current usage telemetry settings (disabled when unset).
    pub async fn get_orb_telemetry(&self) -> OrbTelemetrySettings {
        self.settings
            .load()
            .orb_telemetry
            .clone()
            .unwrap_or_default()
    }

    /// Update the usage telemetry settings and persist to disk.
    pub async fn set_orb_telemetry(
        &self,
        telemetry: OrbTelemetrySettings,
    ) -> Result<(), std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        next.orb_telemetry = Some(telemetry);
        self.settings.store(Arc::new(next.clone()));
        self.save_snapshot(&next).await
    }

    /// Effective harness version policy (empty policy when unset).
    pub async fn get_harness_versions(&self) -> HarnessVersionPolicy {
        self.settings
            .load()
            .harness_versions
            .clone()
            .unwrap_or_default()
    }

    /// Get the auto-cleanup enabled state.
    pub async fn get_auto_cleanup_enabled(&self) -> Option<bool> {
        self.settings.load().auto_cleanup_enabled
    }

    /// Get the auto-cleanup retention window in days.
    pub async fn get_auto_cleanup_days(&self) -> Option<u32> {
        self.settings.load().auto_cleanup_days
    }

    /// Load settings from a file path.
    fn load_from_path(path: &PathBuf) -> Result<Settings, std::io::Error> {
        let contents = std::fs::read_to_string(path)?;
        serde_json::from_str(&contents)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
    }

    /// Save a settings snapshot atomically to disk via `tokio::fs` without blocking readers.
    async fn save_snapshot(&self, settings: &Settings) -> Result<(), std::io::Error> {
        let contents = serde_json::to_string_pretty(settings)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        crate::concurrency::write_atomic_async(&self.storage_path, contents.as_bytes(), None)
            .await?;
        tracing::debug!("Saved settings to {}", self.storage_path.display());
        Ok(())
    }

    /// Get a clone of the current settings.
    pub async fn get(&self) -> Settings {
        (**self.settings.load()).clone()
    }

    /// Get the library remote URL.
    pub async fn get_library_remote(&self) -> Option<String> {
        self.settings.load().library_remote.clone()
    }

    /// Get the configured sandboxed.sh repo path.
    pub async fn get_sandboxed_repo_path(&self) -> Option<String> {
        self.settings.load().sandboxed_repo_path.clone()
    }

    /// Update the library remote URL.
    ///
    /// Returns `(changed, previous_value)`.
    pub async fn set_library_remote(
        &self,
        remote: Option<String>,
    ) -> Result<(bool, Option<String>), std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        let previous = next.library_remote.clone();

        if previous != remote {
            next.library_remote = remote;
            self.settings.store(Arc::new(next.clone()));
            self.save_snapshot(&next).await?;
            Ok((true, previous))
        } else {
            Ok((false, previous))
        }
    }

    /// Get the auth settings.
    pub async fn get_auth_settings(&self) -> Option<AuthSettings> {
        self.settings.load().auth.clone()
    }

    /// Update auth settings and persist to disk.
    pub async fn set_auth_settings(&self, auth: AuthSettings) -> Result<(), std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        next.auth = Some(auth);
        self.settings.store(Arc::new(next.clone()));
        self.save_snapshot(&next).await
    }

    pub async fn upgrade_password_hash_if_current(
        &self,
        expected_current_hash: &str,
        upgraded_hash: String,
    ) -> Result<bool, std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        let Some(ref mut auth) = next.auth else {
            return Ok(false);
        };
        if auth.password_hash.as_deref() != Some(expected_current_hash) {
            return Ok(false);
        }
        auth.password_hash = Some(upgraded_hash);
        self.settings.store(Arc::new(next.clone()));
        self.save_snapshot(&next).await?;
        Ok(true)
    }

    /// Get the max parallel missions setting.
    /// Returns None if not explicitly set (caller should check env var as fallback).
    pub async fn get_max_parallel_missions(&self) -> Option<usize> {
        self.settings.load().max_parallel_missions
    }

    /// Update the max parallel missions setting.
    ///
    /// Returns `(changed, previous_value)`.
    pub async fn set_max_parallel_missions(
        &self,
        max_parallel_missions: Option<usize>,
    ) -> Result<(bool, Option<usize>), std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        let previous = next.max_parallel_missions;

        if previous != max_parallel_missions {
            next.max_parallel_missions = max_parallel_missions;
            if let Some(limit) = max_parallel_missions {
                set_max_parallel_missions_cached(limit);
            }
            self.settings.store(Arc::new(next.clone()));
            self.save_snapshot(&next).await?;
            Ok((true, previous))
        } else {
            Ok((false, previous))
        }
    }

    /// Update multiple settings at once.
    pub async fn update(&self, new_settings: Settings) -> Result<(), std::io::Error> {
        let _guard = self.writer.lock().await;
        set_harness_versions_cached(new_settings.harness_versions.as_ref());
        set_google_max_concurrency_cached(new_settings.google_max_concurrency);
        self.settings.store(Arc::new(new_settings.clone()));
        self.save_snapshot(&new_settings).await
    }

    /// Reload settings from disk.
    ///
    /// Used after restoring a backup to pick up the restored settings.
    /// Also refreshes all atomic caches so the new values take effect immediately.
    pub async fn reload(&self) -> Result<(), std::io::Error> {
        let _guard = self.writer.lock().await;
        let exists = tokio::fs::try_exists(&self.storage_path)
            .await
            .unwrap_or_else(|_| self.storage_path.exists());
        if exists {
            let contents = tokio::fs::read_to_string(&self.storage_path).await?;
            let loaded: Settings = serde_json::from_str(&contents)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            // Refresh atomic caches from the reloaded settings.
            if let Some(limit) = loaded.max_parallel_missions {
                set_max_parallel_missions_cached(limit);
            }
            if let Some(limit) = loaded.max_concurrent_tasks {
                set_max_concurrent_tasks_cached(limit);
            }
            set_google_max_concurrency_cached(loaded.google_max_concurrency);
            set_harness_versions_cached(loaded.harness_versions.as_ref());
            self.settings.store(Arc::new(loaded));
            tracing::info!("Reloaded settings from {}", self.storage_path.display());
        }
        Ok(())
    }

    /// Update the max concurrent tasks setting.
    ///
    /// Returns `(changed, previous_value)`.
    pub async fn set_max_concurrent_tasks(
        &self,
        max_concurrent_tasks: Option<usize>,
    ) -> Result<(bool, Option<usize>), std::io::Error> {
        let _guard = self.writer.lock().await;
        let mut next = (**self.settings.load()).clone();
        let previous = next.max_concurrent_tasks;

        if previous != max_concurrent_tasks {
            next.max_concurrent_tasks = max_concurrent_tasks;
            if let Some(limit) = max_concurrent_tasks {
                set_max_concurrent_tasks_cached(limit);
            }
            self.settings.store(Arc::new(next.clone()));
            self.save_snapshot(&next).await?;
            Ok((true, previous))
        } else {
            Ok((false, previous))
        }
    }

    /// Initialize cached values from loaded settings.
    /// Must be called after creating the settings store, before any workspace operations.
    pub fn init_cached_values(&self) {
        let settings = self.settings.load();
        if let Some(limit) = settings.max_parallel_missions {
            set_max_parallel_missions_cached(limit);
        }
        if let Some(limit) = settings.max_concurrent_tasks {
            set_max_concurrent_tasks_cached(limit);
        }
        set_google_max_concurrency_cached(settings.google_max_concurrency);
    }
}

/// Shared settings store wrapped in Arc for concurrent access.
pub type SharedSettingsStore = Arc<SettingsStore>;

/// Get the effective max parallel missions limit from cache, with a fallback default.
pub fn max_parallel_missions_cached_or(default: usize) -> usize {
    let cached = MAX_PARALLEL_MISSIONS_CACHED.load(Ordering::Relaxed);
    if cached >= 1 {
        cached
    } else if default >= 1 {
        default
    } else {
        1
    }
}

/// Update the cached max parallel missions value.
/// Values less than 1 are normalized to 1.
pub fn set_max_parallel_missions_cached(max_parallel_missions: usize) {
    MAX_PARALLEL_MISSIONS_CACHED.store(max_parallel_missions.max(1), Ordering::Relaxed);
}

/// Get the effective max concurrent command tasks limit from cache, with a fallback default.
pub fn max_concurrent_tasks_cached_or(default: usize) -> usize {
    let cached = MAX_CONCURRENT_TASKS_CACHED.load(Ordering::Relaxed);
    if cached >= 1 {
        cached
    } else if default >= 1 {
        default
    } else {
        5
    }
}

/// Update the cached max concurrent tasks value.
/// Values less than 1 are normalized to 1.
pub fn set_max_concurrent_tasks_cached(max_concurrent_tasks: usize) {
    MAX_CONCURRENT_TASKS_CACHED.store(max_concurrent_tasks.max(1), Ordering::Relaxed);
}

/// Effective per-account concurrency cap for Google and Antigravity proxy requests:
/// runtime setting (`PUT /api/settings`) -> `PROXY_GOOGLE_MAX_CONCURRENCY` env var -> 10.
pub fn effective_google_max_concurrency() -> usize {
    let cached = GOOGLE_MAX_CONCURRENCY_CACHED.load(Ordering::Acquire);
    if cached >= 1 {
        return cached.min(MAX_GOOGLE_ACCOUNT_CONCURRENCY);
    }
    std::env::var("PROXY_GOOGLE_MAX_CONCURRENCY")
        .ok()
        .and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|n| *n > 0)
        .map(|n| n.min(MAX_GOOGLE_ACCOUNT_CONCURRENCY))
        .unwrap_or(DEFAULT_GOOGLE_MAX_CONCURRENCY)
}

/// Update (or clear with `None`) the cached Google / Antigravity per-account concurrency cap.
pub fn set_google_max_concurrency_cached(limit: Option<usize>) {
    let raw = limit
        .filter(|n| *n >= 1)
        .map(|n| n.min(MAX_GOOGLE_ACCOUNT_CONCURRENCY))
        .unwrap_or(0);
    GOOGLE_MAX_CONCURRENCY_CACHED.store(raw, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn harness_version_policy_roundtrips_and_defaults() {
        // Old settings files without the field still deserialize.
        let old: Settings = serde_json::from_str("{}").unwrap();
        assert!(old.harness_versions.is_none());

        let policy = HarnessVersionPolicy {
            claude_code: Some("2.2.0".to_string()),
            codex: Some("0.48.0".to_string()),
            ..Default::default()
        };
        let json = serde_json::to_string(&policy).unwrap();
        let back: HarnessVersionPolicy = serde_json::from_str(&json).unwrap();
        assert_eq!(back, policy);
        // Unpinned harnesses are omitted from the serialized form.
        assert!(!json.contains("gemini"));
        // Grok's upstream installer only installs latest, so an old pin is
        // ignored instead of being exposed as an enforceable setting.
        let legacy: HarnessVersionPolicy = serde_json::from_str(r#"{"grok":"1.2.3"}"#).unwrap();
        assert_eq!(legacy, HarnessVersionPolicy::default());
    }

    #[test]
    fn effective_claude_code_prefers_pin_over_default() {
        let unpinned = HarnessVersionPolicy::default();
        // Env var may leak from the host environment; only assert the
        // settings-pin path when it is unset.
        if std::env::var("SANDBOXED_SH_CLAUDECODE_VERSION").is_err() {
            assert_eq!(
                unpinned.effective_claude_code(),
                DEFAULT_CLAUDE_CODE_VERSION
            );
            let pinned = HarnessVersionPolicy {
                claude_code: Some("9.9.9".to_string()),
                ..Default::default()
            };
            assert_eq!(pinned.effective_claude_code(), "9.9.9");
        }
    }

    #[tokio::test]
    async fn google_max_concurrency_persists_and_defaults_to_ten() {
        let old: Settings = serde_json::from_str("{}").unwrap();
        assert!(old.google_max_concurrency.is_none());

        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(dir.path()).await;
        if std::env::var("PROXY_GOOGLE_MAX_CONCURRENCY").is_err() {
            assert_eq!(
                effective_google_max_concurrency(),
                DEFAULT_GOOGLE_MAX_CONCURRENCY
            );
            assert_eq!(DEFAULT_GOOGLE_MAX_CONCURRENCY, 10);
        }

        let mut updated = store.get().await;
        updated.google_max_concurrency = Some(14);
        store.update(updated).await.unwrap();
        assert_eq!(effective_google_max_concurrency(), 14);

        let reloaded = SettingsStore::new(dir.path()).await;
        assert_eq!(reloaded.get().await.google_max_concurrency, Some(14));

        // Reset global cache so parallel tests keep the default (10).
        set_google_max_concurrency_cached(None);
    }
}
