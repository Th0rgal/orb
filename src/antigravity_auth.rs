//! One Google sign-in for Antigravity model routing and native `agy` runs.
//!
//! CLIProxyAPI owns the login used for model routing and keeps its access
//! token fresh. The native CLI reads `~/.gemini/antigravity-cli/antigravity-oauth-token`.
//! Both use the same Google OAuth client, so the routing login is projected
//! into the CLI's file on every machine instead of asking for a second sign-in
//! per machine. `agy` refreshes the projected token itself with the refresh
//! token and writes the result back, so a run longer than the access-token
//! lifetime keeps working.

use std::path::Path;

use serde::{Deserialize, Serialize};

/// Profile directory of the native CLI, relative to its `HOME`.
pub const PROFILE_DIR: &str = ".gemini/antigravity-cli";
/// Credential file the native CLI keeps inside its profile.
pub const TOKEN_FILE: &str = "antigravity-oauth-token";

/// The routing login, as handed to a machine. Never logged or persisted in a
/// job record.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Credential {
    pub access_token: String,
    pub refresh_token: String,
    /// Access-token expiry, Unix milliseconds.
    pub expires_at: i64,
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credential")
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}

impl Credential {
    pub fn validate(&self) -> Result<(), String> {
        if self.access_token.trim().is_empty() || self.refresh_token.trim().is_empty() {
            return Err("Antigravity credential is incomplete".into());
        }
        Ok(())
    }

    /// The file format `agy` reads and writes. `id_token` is optional: the CLI
    /// adds it on its first refresh.
    pub fn native_file(&self) -> serde_json::Value {
        let expiry = chrono::DateTime::from_timestamp_millis(self.expires_at)
            .unwrap_or_default()
            .to_rfc3339();
        serde_json::json!({
            "auth_method": "consumer",
            "token": {
                "access_token": self.access_token,
                "token_type": "Bearer",
                "refresh_token": self.refresh_token,
                "expiry": expiry,
            }
        })
    }
}

/// Refresh token and expiry (ms) of an existing native file.
fn existing(path: &Path) -> Option<(String, i64)> {
    let value: serde_json::Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let token = value.get("token")?;
    let refresh = token.get("refresh_token")?.as_str()?.to_string();
    let expiry = chrono::DateTime::parse_from_rfc3339(token.get("expiry")?.as_str()?)
        .ok()?
        .timestamp_millis();
    Some((refresh, expiry))
}

/// Write `credential` into the native profile `profile`
/// (`<home>/.gemini/antigravity-cli`). A token the CLI already refreshed for
/// the same login is kept. Returns whether the file changed.
///
/// Files get the owner of `<home>` so a workspace user other than the
/// service account can read them; the credential stays mode 0600.
pub fn install(profile: &Path, credential: &Credential) -> Result<bool, String> {
    credential.validate()?;
    for path in [profile.parent(), Some(profile)].into_iter().flatten() {
        if path.is_symlink() {
            return Err("Antigravity profile must not be a symlink".into());
        }
    }
    let file = profile.join(TOKEN_FILE);
    if file.is_symlink() {
        return Err("Antigravity credential must not be a symlink".into());
    }
    if let Some((refresh, expiry)) = existing(&file) {
        if refresh == credential.refresh_token && expiry >= credential.expires_at {
            return Ok(false);
        }
    }
    std::fs::create_dir_all(profile).map_err(|_| "Cannot prepare the Antigravity profile")?;
    let temporary = profile.join(format!(".{TOKEN_FILE}.{}", uuid::Uuid::new_v4()));
    let body = serde_json::to_vec(&credential.native_file())
        .map_err(|_| "Cannot encode the Antigravity credential")?;
    let written = write_private(&temporary, &body).and_then(|()| {
        set_home_owner(profile, &temporary);
        std::fs::rename(&temporary, &file)
    });
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
        return Err("Cannot write the Antigravity credential".into());
    }
    Ok(true)
}

fn write_private(path: &Path, body: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(body)?;
    file.sync_all()
}

/// Give the profile directories and `file` the owner of the home that holds
/// them. Best effort: only a privileged service can change ownership, and an
/// unprivileged one already owns what it created.
fn set_home_owner(profile: &Path, file: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let gemini = profile.parent();
        let Some(home) = gemini.and_then(Path::parent) else {
            return;
        };
        let Ok(owner) = std::fs::symlink_metadata(home) else {
            return;
        };
        let _ = std::fs::set_permissions(profile, std::fs::Permissions::from_mode(0o700));
        if owner.uid() == unsafe { libc::geteuid() } {
            return;
        }
        for path in [gemini, Some(profile), Some(file)].into_iter().flatten() {
            let _ = std::os::unix::fs::lchown(path, Some(owner.uid()), Some(owner.gid()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn credential(refresh: &str, expires_at: i64) -> Credential {
        Credential {
            access_token: "access".into(),
            refresh_token: refresh.into(),
            expires_at,
        }
    }

    #[test]
    fn writes_the_native_cli_format_privately() {
        let home = tempfile::tempdir().unwrap();
        let profile = home.path().join(PROFILE_DIR);
        assert!(install(&profile, &credential("refresh", 1_800_000_000_000)).unwrap());
        let file = profile.join(TOKEN_FILE);
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(value["auth_method"], "consumer");
        assert_eq!(value["token"]["refresh_token"], "refresh");
        assert_eq!(value["token"]["token_type"], "Bearer");
        assert_eq!(existing(&file), Some(("refresh".into(), 1_800_000_000_000)));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&file).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn keeps_a_token_the_cli_refreshed_and_replaces_another_login() {
        let home = tempfile::tempdir().unwrap();
        let profile = home.path().join(PROFILE_DIR);
        install(&profile, &credential("refresh", 2_000)).unwrap();
        assert!(!install(&profile, &credential("refresh", 1_000)).unwrap());
        assert!(install(&profile, &credential("refresh", 3_000)).unwrap());
        assert!(install(&profile, &credential("other", 1_000)).unwrap());
        assert_eq!(
            existing(&profile.join(TOKEN_FILE)),
            Some(("other".into(), 1_000))
        );
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinked_profiles() {
        let home = tempfile::tempdir().unwrap();
        let elsewhere = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join(".gemini")).unwrap();
        let profile = home.path().join(PROFILE_DIR);
        std::os::unix::fs::symlink(elsewhere.path(), &profile).unwrap();
        assert!(install(&profile, &credential("refresh", 1)).is_err());
        assert!(!elsewhere.path().join(TOKEN_FILE).exists());
    }

    /// Live check against Google with a real login:
    /// `ANTIGRAVITY_E2E_TOKEN=~/.gemini/antigravity-cli/antigravity-oauth-token cargo test --lib -- --ignored projected_login`.
    /// The access token is dropped on purpose: `agy` must refresh it itself.
    #[test]
    #[ignore]
    fn projected_login_runs_agy_in_a_fresh_home() {
        let Ok(source) = std::env::var("ANTIGRAVITY_E2E_TOKEN") else {
            return;
        };
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(source).unwrap()).unwrap();
        let credential = Credential {
            access_token: "expired".into(),
            refresh_token: value["token"]["refresh_token"].as_str().unwrap().into(),
            expires_at: 1_000,
        };
        let home = tempfile::tempdir().unwrap();
        install(&home.path().join(PROFILE_DIR), &credential).unwrap();
        let models =
            crate::antigravity::models_in_home(Path::new("agy"), Some(home.path())).unwrap();
        assert!(!models.is_empty());
        let (refresh, expiry) = existing(&home.path().join(PROFILE_DIR).join(TOKEN_FILE)).unwrap();
        assert_eq!(refresh, credential.refresh_token);
        assert!(
            expiry > chrono::Utc::now().timestamp_millis(),
            "agy refreshed and wrote back"
        );
    }

    #[test]
    fn rejects_incomplete_credentials_and_hides_secrets_in_debug() {
        let home = tempfile::tempdir().unwrap();
        assert!(install(&home.path().join(PROFILE_DIR), &credential("", 1)).is_err());
        assert!(!format!("{:?}", credential("refresh", 1)).contains("refresh"));
    }
}
