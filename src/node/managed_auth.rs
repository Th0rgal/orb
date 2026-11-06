//! Node-configured managed authentication for native harness launches.
//!
//! Raw node jobs run with a cleared environment and `HOME` set to the
//! per-mission job directory (`crate::remote_node::raw_command`), so a CLI
//! that authenticates through a cached login under `~/.<cli>` sees no
//! credential at all. Two things must never happen to fix that:
//!
//! - the core must not ship the credential inside the job payload (it would
//!   be persisted in the node's job database and echoed into logs), and
//! - the core must not be able to point the node at an arbitrary file on the
//!   node's filesystem.
//!
//! Instead the operator configures one trusted directory per profile on the
//! node, and a payload only *names* the profile it needs. The node resolves
//! the name to its own configured path and exports the CLI's documented home
//! override; the payload's own env can never redirect it.
//!
//! Profiles:
//! - [`PROFILE_GROK`]: `SANDBOXED_NODE_GROK_HOME` names a directory owned by
//!   the node service account that holds the Grok CLI state. The operator
//!   creates it with `GROK_HOME=<dir> grok login --device-auth` (as the
//!   service account) which writes `<dir>/auth.json`; an optional
//!   `config.toml` there may configure an external auth provider instead.
//!   Jobs receive `GROK_HOME=<dir>` (the CLI's documented override for
//!   `~/.grok`). Session state also lives there, keyed by the job cwd, which
//!   is what makes `--resume <session id>` work across jobs of one mission.

use std::path::{Path, PathBuf};

/// Profile name for the Grok Build CLI cached login.
pub const PROFILE_GROK: &str = "grok";
/// Node env var naming the trusted Grok home directory.
pub const GROK_HOME_ENV: &str = "SANDBOXED_NODE_GROK_HOME";
/// Env var the Grok CLI reads to relocate `~/.grok`.
pub const GROK_HOME_CHILD_ENV: &str = "GROK_HOME";
/// Credential file the Grok CLI keeps inside its home.
pub const GROK_AUTH_FILE: &str = "auth.json";

/// Operator-configured managed-auth profiles of this node.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ManagedAuth {
    grok_home: Option<PathBuf>,
    antigravity_home: Option<PathBuf>,
    /// The Core may replace the Antigravity login with its routing login.
    antigravity_core_sync: bool,
}

impl ManagedAuth {
    /// Read the node configuration from the environment. A relative or empty
    /// `SANDBOXED_NODE_GROK_HOME` is ignored with a warning: a relative path
    /// would resolve against each job's cwd, i.e. against mission-controlled
    /// content.
    pub fn from_env() -> Self {
        let mut auth = Self::from_values(std::env::var(GROK_HOME_ENV).ok());
        auth.antigravity_home = std::env::var("SANDBOXED_NODE_ANTIGRAVITY_HOME")
            .ok()
            .map(PathBuf::from)
            .filter(|p| p.is_absolute());
        auth
    }

    pub fn from_values(grok_home: Option<String>) -> Self {
        let grok_home = grok_home
            .map(|raw| raw.trim().to_string())
            .filter(|raw| !raw.is_empty())
            .and_then(|raw| {
                let path = PathBuf::from(raw);
                if path.is_absolute() {
                    Some(path)
                } else {
                    tracing::warn!(
                        path = %path.display(),
                        "{GROK_HOME_ENV} must be an absolute path; managed grok auth is disabled"
                    );
                    None
                }
            });
        Self {
            grok_home,
            antigravity_home: None,
            antigravity_core_sync: false,
        }
    }

    /// Test/explicit constructor.
    pub fn with_grok_home(path: impl Into<PathBuf>) -> Self {
        Self {
            grok_home: Some(path.into()),
            antigravity_home: None,
            antigravity_core_sync: false,
        }
    }

    /// Accept the Core's Antigravity login (one Google sign-in for routing
    /// and native runs). Without `SANDBOXED_NODE_ANTIGRAVITY_HOME` the login
    /// lives in `default_home`, a private directory under the node work root.
    /// `SANDBOXED_NODE_ANTIGRAVITY_LOCAL_ONLY=1` keeps the node's own sign-in.
    pub fn with_core_antigravity(mut self, default_home: PathBuf) -> Self {
        let local_only = std::env::var("SANDBOXED_NODE_ANTIGRAVITY_LOCAL_ONLY")
            .is_ok_and(|v| matches!(v.trim(), "1" | "true" | "yes"));
        self.antigravity_core_sync = !local_only;
        if self.antigravity_home.is_none() && !local_only {
            self.antigravity_home = Some(default_home);
        }
        self
    }

    pub fn accepts_core_antigravity(&self) -> bool {
        self.antigravity_core_sync && self.antigravity_home.is_some()
    }

    /// Store the Core's Antigravity login in this node's profile.
    pub fn install_antigravity(
        &self,
        credential: &crate::antigravity_auth::Credential,
    ) -> Result<bool, String> {
        self.install_antigravity_slot(credential, None, true)
    }

    /// Store an Antigravity login in an isolated per-account slot
    /// (`<antigravity_home>/accounts/<slot>`) and optionally also update the
    /// node's default `"antigravity"` sign-in. Each slot shares the node's
    /// `conversations/` and `brain/` directories so resuming a conversation
    /// across account switches preserves full native history while keeping
    /// OAuth tokens isolated across concurrent jobs.
    pub fn install_antigravity_slot(
        &self,
        credential: &crate::antigravity_auth::Credential,
        slot: Option<&str>,
        update_default: bool,
    ) -> Result<bool, String> {
        let Some(home) = &self.antigravity_home else {
            return Err("This node keeps its own Antigravity sign-in".into());
        };
        if !self.accepts_core_antigravity() {
            return Err("This node keeps its own Antigravity sign-in".into());
        }
        let slot = slot.map(str::trim).filter(|s| !s.is_empty());
        if let Some(slot_id) = slot {
            if !crate::antigravity_auth::valid_slot_id(slot_id) {
                return Err("Invalid Antigravity slot identifier".into());
            }
        }
        let mut changed = false;
        let default_missing =
            !private_file_readable(&home.join(crate::antigravity_auth::TOKEN_FILE));
        if slot.is_none() || update_default || default_missing {
            changed |= crate::antigravity_auth::install(home, credential)?;
        }
        if let Some(slot_id) = slot {
            changed |= install_slot_profile(home, slot_id, credential)?;
        }
        Ok(changed)
    }

    /// Profiles that are configured *and* usable right now (the credential
    /// file exists and is readable by this process). This is what the
    /// heartbeat advertises, so a node whose operator configured the path
    /// but never logged in is not selected for a launch that would hang on
    /// an interactive sign-in.
    pub fn advertised(&self) -> Vec<String> {
        let mut ready = Vec::new();
        if let Some(home) = &self.grok_home {
            if grok_auth_readable(home) {
                ready.push(PROFILE_GROK.to_string());
            }
        }
        if let Some(home) = &self.antigravity_home {
            if private_file_readable(&home.join(crate::antigravity_auth::TOKEN_FILE)) {
                ready.push("antigravity".into());
            }
            let accounts_dir = home.join("accounts");
            if !accounts_dir.is_symlink() {
                if let Ok(entries) = std::fs::read_dir(&accounts_dir) {
                    let mut slots: Vec<String> = entries
                        .flatten()
                        .filter_map(|entry| {
                            if entry.file_type().ok()?.is_symlink() {
                                return None;
                            }
                            let slot = entry.file_name().into_string().ok()?;
                            if !crate::antigravity_auth::valid_slot_id(&slot) {
                                return None;
                            }
                            private_file_readable(
                                &entry.path().join(crate::antigravity_auth::TOKEN_FILE),
                            )
                            .then(|| format!("antigravity:{slot}"))
                        })
                        .collect();
                    slots.sort();
                    ready.extend(slots);
                }
            }
        }
        ready
    }

    /// Reject a payload that names a profile this node cannot honour. Called
    /// at submission so the core gets a clear HTTP rejection instead of a job
    /// that fails (or hangs on an interactive login) minutes later.
    pub fn validate_request(&self, profiles: &[String]) -> Result<(), String> {
        let mut antigravity_count = 0usize;
        for profile in profiles {
            match profile.as_str() {
                PROFILE_GROK => {
                    let Some(home) = &self.grok_home else {
                        return Err(format!(
                            "managed auth profile '{PROFILE_GROK}' is not configured on this node (set {GROK_HOME_ENV} to the service account's Grok home and run `grok login --device-auth` there)"
                        ));
                    };
                    if !grok_auth_readable(home) {
                        return Err(format!(
                            "managed auth profile '{PROFILE_GROK}' is configured but {}/{GROK_AUTH_FILE} is missing, unreadable, or not private to the service account; run `GROK_HOME={} grok login --device-auth` as the node service account",
                            home.display(),
                            home.display()
                        ));
                    }
                }
                "antigravity" => {
                    antigravity_count += 1;
                    if !self.antigravity_home.as_ref().is_some_and(|p| {
                        private_file_readable(&p.join(crate::antigravity_auth::TOKEN_FILE))
                    }) {
                        return Err("Antigravity requires SANDBOXED_NODE_ANTIGRAVITY_HOME pointing to the execution user's native CLI profile with a private OAuth login; connect Google Antigravity in Core or sign in with agy".into());
                    }
                }
                other if other.starts_with("antigravity:") => {
                    antigravity_count += 1;
                    let slot = &other["antigravity:".len()..];
                    if !crate::antigravity_auth::valid_slot_id(slot) {
                        return Err(format!(
                            "managed auth profile '{other}' has an invalid Antigravity slot identifier"
                        ));
                    }
                    let ready = self.antigravity_home.as_ref().is_some_and(|home| {
                        let accounts = home.join("accounts");
                        let slot_dir = accounts.join(slot);
                        !accounts.is_symlink()
                            && !slot_dir.is_symlink()
                            && private_file_readable(
                                &slot_dir.join(crate::antigravity_auth::TOKEN_FILE),
                            )
                    });
                    if !ready {
                        return Err(format!(
                            "managed auth profile '{other}' is not provisioned on this node; sync the compatible Google Antigravity account from Core before launching"
                        ));
                    }
                }
                other => {
                    return Err(format!(
                        "managed auth profile '{other}' is unknown to this node (supported: {PROFILE_GROK}, antigravity, antigravity:<slot>)"
                    ));
                }
            }
        }
        if antigravity_count > 1 {
            return Err(
                "Only one Antigravity managed auth profile may be requested per job".into(),
            );
        }
        Ok(())
    }

    /// Bind only the native agy profile; retain the job's isolated HOME.
    pub fn prepare_workspace(&self, profiles: &[String], directory: &Path) -> Result<(), String> {
        self.validate_request(profiles)?;
        let Some(requested_profile) = profiles
            .iter()
            .find(|p| p.as_str() == "antigravity" || p.starts_with("antigravity:"))
        else {
            return Ok(());
        };
        let home = self
            .antigravity_home
            .as_ref()
            .ok_or("Missing Antigravity profile")?;
        let target_profile = match requested_profile.strip_prefix("antigravity:") {
            Some(slot) => home.join("accounts").join(slot),
            None => home.clone(),
        };
        let gemini = directory.join(".gemini");
        if gemini.is_symlink() {
            return Err("Job .gemini must not be a symlink".into());
        }
        std::fs::create_dir_all(&gemini).map_err(|_| "Cannot prepare native Antigravity home")?;
        let link = gemini.join("antigravity-cli");
        if let Ok(metadata) = std::fs::symlink_metadata(&link) {
            if !metadata.file_type().is_symlink() {
                return Err("Job Antigravity home conflicts with the node-managed profile".into());
            }
            let current_target = std::fs::read_link(&link)
                .map_err(|_| "Job Antigravity home conflicts with the node-managed profile")?;
            if !is_node_managed_antigravity_target(home, &current_target) {
                return Err("Job Antigravity home conflicts with the node-managed profile".into());
            }
            if current_target == target_profile {
                return Ok(());
            }
            #[cfg(unix)]
            {
                let tmp = gemini.join(format!(".antigravity-cli.{}", uuid::Uuid::new_v4()));
                let _ = std::fs::remove_file(&tmp);
                std::os::unix::fs::symlink(&target_profile, &tmp)
                    .map_err(|_| "Cannot update native Antigravity profile binding")?;
                if std::fs::rename(&tmp, &link).is_err() {
                    let _ = std::fs::remove_file(&tmp);
                    return Err("Cannot update native Antigravity profile binding".into());
                }
                return Ok(());
            }
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&target_profile, &link)
                .map_err(|_| "Cannot bind native Antigravity profile")?;
            Ok(())
        }
        #[cfg(not(unix))]
        {
            Err("Antigravity node-managed profiles require Unix".into())
        }
    }

    /// Environment to export for the requested profiles. Applied *after* the
    /// payload env so a payload cannot redirect a managed profile elsewhere.
    pub fn env_for(&self, profiles: &[String]) -> Result<Vec<(String, String)>, String> {
        self.validate_request(profiles)?;
        let mut env = Vec::new();
        for profile in profiles {
            if profile == PROFILE_GROK {
                if let Some(home) = &self.grok_home {
                    env.push((
                        GROK_HOME_CHILD_ENV.to_string(),
                        home.to_string_lossy().into_owned(),
                    ));
                }
            }
        }
        Ok(env)
    }
}

fn is_node_managed_antigravity_target(home: &Path, target: &Path) -> bool {
    if target == home {
        return true;
    }
    target.parent() == Some(home.join("accounts").as_path())
        && target
            .file_name()
            .and_then(|s| s.to_str())
            .is_some_and(crate::antigravity_auth::valid_slot_id)
}

fn install_slot_profile(
    home: &Path,
    slot_id: &str,
    credential: &crate::antigravity_auth::Credential,
) -> Result<bool, String> {
    if home.is_symlink() {
        return Err("Antigravity profile must not be a symlink".into());
    }
    let accounts_dir = home.join("accounts");
    if accounts_dir.is_symlink() {
        return Err("Antigravity accounts directory must not be a symlink".into());
    }
    std::fs::create_dir_all(&accounts_dir)
        .map_err(|_| "Cannot prepare Antigravity account slots")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&accounts_dir, std::fs::Permissions::from_mode(0o700));
    }
    let slot_dir = accounts_dir.join(slot_id);
    let changed = crate::antigravity_auth::install(&slot_dir, credential)?;
    #[cfg(unix)]
    for shared_subdir in ["conversations", "brain"] {
        let shared_target = home.join(shared_subdir);
        if shared_target.is_symlink() {
            return Err("Antigravity shared conversation state must not be a symlink".into());
        }
        std::fs::create_dir_all(&shared_target)
            .map_err(|_| "Cannot prepare Antigravity conversation state")?;
        let link = slot_dir.join(shared_subdir);
        match std::fs::symlink_metadata(&link) {
            Ok(meta) => {
                if !meta.file_type().is_symlink()
                    || std::fs::read_link(&link).ok().as_deref() != Some(shared_target.as_path())
                {
                    return Err(
                        "Antigravity slot conversation state conflicts with node profile".into(),
                    );
                }
            }
            Err(_) => {
                std::os::unix::fs::symlink(&shared_target, &link)
                    .map_err(|_| "Cannot link Antigravity slot conversation state")?;
            }
        }
    }
    Ok(changed)
}

fn grok_auth_readable(home: &Path) -> bool {
    private_file_readable(&home.join(GROK_AUTH_FILE))
}

fn private_file_readable(path: &Path) -> bool {
    let Ok(file) = std::fs::File::open(path) else {
        return false;
    };
    let Ok(metadata) = file.metadata() else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.mode() & 0o077 != 0 || metadata.uid() != unsafe { libc::geteuid() } {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retired_gemini_auth_profile_is_rejected() {
        let auth = ManagedAuth::default();
        assert!(auth
            .env_for(&["gemini".into()])
            .unwrap_err()
            .contains("unknown"));
        assert!(!auth.advertised().iter().any(|profile| profile == "gemini"));
    }

    #[test]
    #[cfg(unix)]
    fn core_antigravity_login_makes_the_profile_ready_unless_local_only() {
        let root = tempfile::tempdir().unwrap();
        let credential = crate::antigravity_auth::Credential {
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            expires_at: 1_800_000_000_000,
        };
        let synced = ManagedAuth {
            antigravity_home: Some(root.path().join("managed-auth/antigravity")),
            antigravity_core_sync: true,
            ..Default::default()
        };
        assert!(synced.advertised().is_empty());
        assert!(synced.install_antigravity(&credential).unwrap());
        assert_eq!(synced.advertised(), vec!["antigravity".to_string()]);
        let local = ManagedAuth {
            antigravity_home: Some(root.path().join("local")),
            ..Default::default()
        };
        assert!(!local.accepts_core_antigravity());
        assert!(local.install_antigravity(&credential).is_err());
        assert!(!root.path().join("local").exists());
    }

    #[test]
    #[cfg(unix)]
    fn antigravity_mount_is_narrow_and_rejects_workspace_redirection() {
        use std::os::unix::fs::PermissionsExt;
        let profile = tempfile::tempdir().unwrap();
        let token = profile.path().join("antigravity-oauth-token");
        std::fs::write(&token, "fixture-only").unwrap();
        std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
        let auth = ManagedAuth {
            antigravity_home: Some(profile.path().into()),
            ..Default::default()
        };
        let job = tempfile::tempdir().unwrap();
        let requested = vec!["antigravity".into()];
        assert_eq!(auth.advertised(), requested);
        assert!(auth.env_for(&requested).unwrap().is_empty());
        auth.prepare_workspace(&requested, job.path()).unwrap();
        auth.prepare_workspace(&requested, job.path()).unwrap();
        let link = job.path().join(".gemini/antigravity-cli");
        assert_eq!(std::fs::read_link(&link).unwrap(), profile.path());
        std::fs::remove_file(&link).unwrap();
        std::fs::create_dir(&link).unwrap();
        assert!(auth.prepare_workspace(&requested, job.path()).is_err());
        std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(auth.advertised().is_empty());
    }

    fn grok_home_with_auth() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(GROK_AUTH_FILE), "{}").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                dir.path().join(GROK_AUTH_FILE),
                std::fs::Permissions::from_mode(0o600),
            )
            .unwrap();
        }
        dir
    }

    #[test]
    fn unconfigured_node_advertises_nothing_and_rejects_grok() {
        let auth = ManagedAuth::from_values(None);
        assert!(auth.advertised().is_empty());
        let err = auth.validate_request(&["grok".to_string()]).unwrap_err();
        assert!(err.contains("not configured"), "{err}");
        assert!(err.contains(GROK_HOME_ENV), "{err}");
        assert!(auth.validate_request(&[]).is_ok());
    }

    #[test]
    fn relative_grok_home_is_ignored() {
        let auth = ManagedAuth::from_values(Some("relative/grok".into()));
        assert_eq!(auth, ManagedAuth::default());
        assert_eq!(
            ManagedAuth::from_values(Some("   ".into())),
            ManagedAuth::default()
        );
    }

    #[test]
    fn configured_home_without_login_is_not_advertised() {
        let dir = tempfile::tempdir().unwrap();
        let auth = ManagedAuth::with_grok_home(dir.path());
        assert!(auth.advertised().is_empty());
        let err = auth.validate_request(&["grok".to_string()]).unwrap_err();
        assert!(err.contains("missing, unreadable"), "{err}");
    }

    #[test]
    fn logged_in_home_is_advertised_and_injected_as_grok_home_only() {
        let dir = grok_home_with_auth();
        let auth = ManagedAuth::with_grok_home(dir.path());
        assert_eq!(auth.advertised(), vec!["grok".to_string()]);
        let env = auth.env_for(&["grok".to_string()]).unwrap();
        assert_eq!(
            env,
            vec![(
                "GROK_HOME".to_string(),
                dir.path().to_string_lossy().into_owned()
            )]
        );
        // Only the home override is exported: the credential bytes never
        // travel through the job environment either.
        assert!(env.iter().all(|(_, value)| !value.contains('{')));
        assert!(auth.env_for(&[]).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn permissive_auth_file_is_rejected() {
        use std::os::unix::fs::PermissionsExt;
        let dir = grok_home_with_auth();
        std::fs::set_permissions(
            dir.path().join(GROK_AUTH_FILE),
            std::fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        let auth = ManagedAuth::with_grok_home(dir.path());
        assert!(auth.advertised().is_empty());
        assert!(auth.env_for(&["grok".into()]).is_err());
    }

    #[test]
    fn unknown_profile_is_rejected_by_name() {
        let dir = grok_home_with_auth();
        let auth = ManagedAuth::with_grok_home(dir.path());
        let err = auth
            .env_for(&["grok".to_string(), "openai".to_string()])
            .unwrap_err();
        assert!(err.contains("'openai' is unknown"), "{err}");
    }

    #[cfg(unix)]
    #[test]
    fn per_account_antigravity_slots_isolate_concurrent_missions_and_keep_conversations() {
        let root = tempfile::tempdir().unwrap();
        let auth = ManagedAuth {
            antigravity_home: Some(root.path().join("managed-auth/antigravity")),
            antigravity_core_sync: true,
            ..Default::default()
        };
        let general = crate::antigravity_auth::Credential {
            access_token: "access-general".into(),
            refresh_token: "refresh-her3sy".into(),
            expires_at: 1_800_000_000_000,
        };
        let carbon = crate::antigravity_auth::Credential {
            access_token: "access-carbon".into(),
            refresh_token: "refresh-marchand".into(),
            expires_at: 1_800_000_000_000,
        };
        let general_slot = general.slot_id();
        let carbon_slot = carbon.slot_id();
        assert_ne!(general_slot, carbon_slot);

        // Install default/general account first, then Carbon account without clobbering default.
        assert!(auth
            .install_antigravity_slot(&general, Some(&general_slot), true)
            .unwrap());
        assert!(auth
            .install_antigravity_slot(&carbon, Some(&carbon_slot), false)
            .unwrap());

        let advertised = auth.advertised();
        assert!(advertised.contains(&"antigravity".to_string()));
        assert!(advertised.contains(&format!("antigravity:{general_slot}")));
        assert!(advertised.contains(&format!("antigravity:{carbon_slot}")));

        // Re-syncing general account as default (e.g. model picker or refresh loop)
        // NEVER overwrites the Carbon slot!
        let general_refreshed = crate::antigravity_auth::Credential {
            access_token: "access-general-2".into(),
            refresh_token: "refresh-her3sy".into(),
            expires_at: 1_800_000_050_000,
        };
        auth.install_antigravity_slot(&general_refreshed, Some(&general_slot), true)
            .unwrap();

        let carbon_mission = tempfile::tempdir().unwrap();
        let opus_mission = tempfile::tempdir().unwrap();

        // Simulate resuming a pre-upgrade mission that originally linked `"antigravity"`
        // and created a conversation DB, then switched to Gemini 4 Carbon (`antigravity:<carbon_slot>`).
        auth.prepare_workspace(&["antigravity".into()], carbon_mission.path())
            .unwrap();
        let conv_db = carbon_mission
            .path()
            .join(".gemini/antigravity-cli/conversations/conv-1.db");
        std::fs::create_dir_all(conv_db.parent().unwrap()).unwrap();
        std::fs::write(&conv_db, b"sqlite-fixture").unwrap();

        auth.prepare_workspace(
            &[format!("antigravity:{carbon_slot}")],
            carbon_mission.path(),
        )
        .unwrap();
        auth.prepare_workspace(
            &[format!("antigravity:{general_slot}")],
            opus_mission.path(),
        )
        .unwrap();

        let carbon_token: serde_json::Value = serde_json::from_slice(
            &std::fs::read(
                carbon_mission
                    .path()
                    .join(".gemini/antigravity-cli/antigravity-oauth-token"),
            )
            .unwrap(),
        )
        .unwrap();
        let opus_token: serde_json::Value = serde_json::from_slice(
            &std::fs::read(
                opus_mission
                    .path()
                    .join(".gemini/antigravity-cli/antigravity-oauth-token"),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(carbon_token["token"]["refresh_token"], "refresh-marchand");
        assert_eq!(opus_token["token"]["refresh_token"], "refresh-her3sy");
        assert_eq!(std::fs::read(&conv_db).unwrap(), b"sqlite-fixture");
    }
}
