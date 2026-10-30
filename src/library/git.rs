//! Git operations for the configuration library.

use anyhow::{Context, Result};
use std::path::Path;
use tokio::process::Command;

use super::types::{LibraryHistoryEntry, LibraryStatus};

/// Get the GIT_SSH_COMMAND value for git operations.
///
/// - If `LIBRARY_GIT_SSH_KEY` is set to a path, uses that key with `-o IdentitiesOnly=yes`
/// - If `LIBRARY_GIT_SSH_KEY` is set to empty string, uses `ssh` with no config to ignore host-specific settings
/// - If `LIBRARY_GIT_SSH_KEY` is unset, returns None (use default git/ssh behavior)
fn get_ssh_command() -> Option<String> {
    match std::env::var("LIBRARY_GIT_SSH_KEY") {
        Ok(key) if key.is_empty() => {
            // Empty string means "use default ssh, ignore any host-specific config"
            // -F /dev/null ignores the user's ssh config
            Some("ssh -F /dev/null".to_string())
        }
        Ok(key) => {
            // Use the specified key
            Some(format!("ssh -i {} -o IdentitiesOnly=yes", key))
        }
        Err(_) => {
            // Not set - use default git behavior (respects ~/.ssh/config)
            None
        }
    }
}

/// Apply SSH configuration to a git command if needed.
/// Core's configured Library remote, set once at startup. Only this remote
/// gets the development identity; a remote named per request never does.
static TRUSTED_REMOTE: std::sync::OnceLock<String> = std::sync::OnceLock::new();

pub fn set_trusted_remote(remote: &str) {
    let _ = TRUSTED_REMOTE.set(normalize_remote(remote));
}

fn normalize_remote(remote: &str) -> String {
    remote
        .trim()
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .to_ascii_lowercase()
}

/// The development identity's git config (GitHub credential and signing).
/// The service user's own config named the signing key without its gpg
/// wrapper and held an expired GitHub token, which froze the prod Library
/// on 2026-10-18.
fn identity_gitconfig() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("SANDBOXED_DEVELOPMENT_IDENTITY")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| "/root/.config/sandboxed-sh/development-identity".into());
    [base.join("current/gitconfig"), base.join("gitconfig")]
        .into_iter()
        .find(|path| path.is_file())
}

/// A local git command: never signs, never uses the shared identity.
fn git() -> Command {
    let mut cmd = Command::new("git");
    cmd.args(["-c", "commit.gpgsign=false"]);
    cmd
}

fn origin_of(path: &Path) -> Option<String> {
    let out = std::process::Command::new("git")
        .current_dir(path)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// A network or commit command: the development identity only when `remote`
/// is the configured Library remote, otherwise the plain [`git`].
fn trusted_git(remote: Option<&str>) -> Command {
    let trusted = remote
        .map(normalize_remote)
        .zip(TRUSTED_REMOTE.get())
        .is_some_and(|(remote, trusted)| remote == *trusted);
    match identity_gitconfig().filter(|_| trusted) {
        Some(config) => {
            let mut cmd = Command::new("git");
            cmd.env("GIT_CONFIG_GLOBAL", config);
            cmd
        }
        None => git(),
    }
}

/// [`trusted_git`] for the repository at `path`, judged by its origin.
fn trusted_git_at(path: &Path) -> Command {
    trusted_git(origin_of(path).as_deref())
}

fn apply_ssh_config(cmd: &mut Command) {
    if let Some(ssh_cmd) = get_ssh_command() {
        cmd.env("GIT_SSH_COMMAND", ssh_cmd);
    }
}

/// Clone a git repository if it doesn't exist.
pub async fn clone_if_needed(path: &Path, remote: &str) -> Result<bool> {
    if path.exists() && path.join(".git").exists() {
        tracing::debug!(path = %path.display(), "Library repo already exists");
        return Ok(false);
    }

    tracing::info!(remote = %remote, path = %path.display(), "Cloning library repository");

    // Create parent directory if needed
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let mut cmd = trusted_git(Some(remote));
    cmd.args(["clone", remote, &path.to_string_lossy()]);
    apply_ssh_config(&mut cmd);
    let output = cmd.output().await.context("Failed to execute git clone")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git clone failed: {}", stderr);
    }

    Ok(true)
}

/// Ensure the repository has the expected remote configured.
///
/// Precondition: `path` is either a git repository or does not exist.
/// Postcondition: if a git repository exists at `path`, its `origin` remote URL equals `remote`
/// and the repository is tracking content from that remote.
pub async fn ensure_remote(path: &Path, remote: &str) -> Result<()> {
    if !path.exists() || !path.join(".git").exists() {
        return Ok(());
    }

    let current = get_remote(path).await.ok();
    if current.as_deref() == Some(remote) {
        return Ok(());
    }

    tracing::info!(
        old_remote = ?current,
        new_remote = %remote,
        "Switching library remote"
    );

    // Update the remote URL
    let output = git()
        .current_dir(path)
        .args(["remote", "set-url", "origin", remote])
        .output()
        .await
        .context("Failed to execute git remote set-url")?;

    if !output.status.success() {
        // Try adding remote if it doesn't exist
        let output = git()
            .current_dir(path)
            .args(["remote", "add", "origin", remote])
            .output()
            .await
            .context("Failed to execute git remote add")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("git remote add failed: {}", stderr);
        }
    }

    // Fetch from the new remote
    tracing::info!("Fetching from new remote");
    let mut cmd = trusted_git_at(path);
    cmd.current_dir(path).args(["fetch", "origin"]);
    apply_ssh_config(&mut cmd);
    let output = cmd.output().await.context("Failed to execute git fetch")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git fetch failed: {}", stderr);
    }

    // Try to find the default branch (main or master)
    let default_branch = detect_default_branch(path).await?;

    // Reset to the new remote's default branch
    tracing::info!(branch = %default_branch, "Resetting to remote's default branch");
    let output = git()
        .current_dir(path)
        .args([
            "checkout",
            "-B",
            &default_branch,
            &format!("origin/{}", default_branch),
        ])
        .output()
        .await
        .context("Failed to execute git checkout")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git checkout failed: {}", stderr);
    }

    Ok(())
}

/// Detect the default branch of the remote (main or master).
async fn detect_default_branch(path: &Path) -> Result<String> {
    // Try 'main' first
    let output = git()
        .current_dir(path)
        .args(["rev-parse", "--verify", "origin/main"])
        .output()
        .await?;

    if output.status.success() {
        return Ok("main".to_string());
    }

    // Fall back to 'master'
    let output = git()
        .current_dir(path)
        .args(["rev-parse", "--verify", "origin/master"])
        .output()
        .await?;

    if output.status.success() {
        return Ok("master".to_string());
    }

    // Default to 'main' if neither exists (new repo)
    Ok("main".to_string())
}

/// Get the current git status of a repository.
pub async fn status(path: &Path) -> Result<LibraryStatus> {
    // Get current branch
    let branch = get_branch(path).await?;

    // Get remote URL
    let remote = get_remote(path).await.ok();

    // Check if clean
    let (clean, modified_files) = get_status(path).await?;

    // Get ahead/behind counts
    let (ahead, behind) = get_ahead_behind(path).await.unwrap_or((0, 0));

    Ok(LibraryStatus {
        path: path.to_string_lossy().to_string(),
        remote,
        branch,
        clean,
        ahead,
        behind,
        modified_files,
        last_synced_at: last_fetch_at(path),
    })
}

/// When the repository last fetched from its remote (pull and sync both fetch).
fn last_fetch_at(path: &Path) -> Option<i64> {
    let modified = std::fs::metadata(path.join(".git/FETCH_HEAD"))
        .ok()?
        .modified()
        .ok()?;
    let secs = modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    i64::try_from(secs).ok()
}

/// Commits that changed `rel`, newest first.
pub async fn log_path(path: &Path, rel: &str, limit: usize) -> Result<Vec<LibraryHistoryEntry>> {
    let output = git()
        .current_dir(path)
        .args([
            "log",
            &format!("-n{limit}"),
            "--format=%H%x1f%an%x1f%at%x1f%s",
            "--",
            rel,
        ])
        .output()
        .await?;
    if !output.status.success() {
        anyhow::bail!(
            "git log failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(parse_log(&String::from_utf8_lossy(&output.stdout)))
}

fn parse_log(out: &str) -> Vec<LibraryHistoryEntry> {
    out.lines()
        .filter_map(|line| {
            let mut p = line.split('\x1f');
            Some(LibraryHistoryEntry {
                rev: p.next()?.to_string(),
                author: p.next()?.to_string(),
                timestamp: p.next()?.parse().ok()?,
                subject: p.next().unwrap_or_default().to_string(),
            })
        })
        .collect()
}

/// A commit id as `git log` prints it; anything else (refs, ranges, options) is refused.
pub fn is_commit_id(rev: &str) -> bool {
    (7..=40).contains(&rev.len()) && rev.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Contents of `rel` at commit `rev`.
pub async fn show_at(path: &Path, rev: &str, rel: &str) -> Result<String> {
    if !is_commit_id(rev) {
        anyhow::bail!("Revision not found: {}", rev);
    }
    let output = git()
        .current_dir(path)
        .args(["show", &format!("{rev}:{rel}")])
        .output()
        .await?;
    if !output.status.success() {
        anyhow::bail!("Revision not found: {}", rev);
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod history_tests {
    use super::*;

    #[test]
    fn parses_log_lines_and_refuses_non_commit_revisions() {
        let rows = parse_log("abc1234\x1fThomas\x1f1761480000\x1fskill: update deploy\nbad line\n");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].subject, "skill: update deploy");
        assert_eq!(rows[0].timestamp, 1_761_480_000);
        assert!(is_commit_id("abc1234"));
        assert!(!is_commit_id("HEAD"));
        assert!(!is_commit_id("abc1234..def5678"));
        assert!(!is_commit_id("--output=x"));
    }
}

/// Error type for git pull operations.
#[derive(Debug)]
pub enum PullError {
    /// Pull failed because local and remote histories have diverged.
    /// This happens after a force push on the remote.
    DivergedHistory { message: String },
    /// Pull failed for another reason.
    Other(anyhow::Error),
}

impl std::fmt::Display for PullError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PullError::DivergedHistory { message } => {
                write!(f, "Diverged history: {}", message)
            }
            PullError::Other(e) => write!(f, "{}", e),
        }
    }
}

impl std::error::Error for PullError {}

/// Pull latest changes from remote.
pub async fn pull(path: &Path) -> Result<(), PullError> {
    tracing::info!(path = %path.display(), "Pulling library changes");

    let mut cmd = trusted_git_at(path);
    cmd.current_dir(path).args(["pull", "--ff-only"]);
    apply_ssh_config(&mut cmd);
    let output = cmd
        .output()
        .await
        .map_err(|e| PullError::Other(anyhow::anyhow!("Failed to execute git pull: {}", e)))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stderr_lower = stderr.to_lowercase();

        // Detect diverged history errors
        if stderr_lower.contains("not possible to fast-forward")
            || stderr_lower.contains("have diverged")
            || stderr_lower.contains("cannot fast-forward")
            || stderr_lower.contains("refusing to merge unrelated histories")
        {
            return Err(PullError::DivergedHistory {
                message: format!(
                    "Local and remote histories have diverged (likely due to a force push). \
                     Use 'Force Pull' to reset to remote or 'Force Push' to overwrite remote. \
                     Git error: {}",
                    stderr.trim()
                ),
            });
        }

        return Err(PullError::Other(anyhow::anyhow!(
            "git pull failed: {}",
            stderr
        )));
    }

    Ok(())
}

/// Force pull: reset local branch to match remote (discards local changes).
/// Use this after a force push on the remote has caused history to diverge.
pub async fn force_pull(path: &Path) -> Result<()> {
    tracing::info!(path = %path.display(), "Force pulling library (resetting to remote)");

    // First, fetch the latest from remote
    let mut cmd = trusted_git_at(path);
    cmd.current_dir(path).args(["fetch", "origin"]);
    apply_ssh_config(&mut cmd);
    let output = cmd.output().await.context("Failed to execute git fetch")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git fetch failed: {}", stderr);
    }

    // Get the current branch name
    let branch = get_branch(path)
        .await
        .unwrap_or_else(|_| "main".to_string());

    // Reset to the remote branch
    let output = git()
        .current_dir(path)
        .args(["reset", "--hard", &format!("origin/{}", branch)])
        .output()
        .await
        .context("Failed to execute git reset")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git reset failed: {}", stderr);
    }

    tracing::info!(path = %path.display(), branch = %branch, "Force pull complete - local branch reset to remote");
    Ok(())
}

/// Force push: overwrite remote with local changes.
/// Use this when you want to keep local changes and discard remote history.
pub async fn force_push(path: &Path) -> Result<()> {
    tracing::info!(path = %path.display(), "Force pushing library changes");

    let mut cmd = trusted_git_at(path);
    cmd.current_dir(path).args(["push", "--force-with-lease"]);
    apply_ssh_config(&mut cmd);
    let output = cmd
        .output()
        .await
        .context("Failed to execute git push --force-with-lease")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git push --force-with-lease failed: {}", stderr);
    }

    tracing::info!(path = %path.display(), "Force push complete");
    Ok(())
}

/// Git author configuration for commits.
#[derive(Debug, Clone, Default)]
pub struct GitAuthor {
    pub name: Option<String>,
    pub email: Option<String>,
}

impl GitAuthor {
    pub fn new(name: Option<String>, email: Option<String>) -> Self {
        Self { name, email }
    }
}

/// Commit all changes with a message.
pub async fn commit(path: &Path, message: &str, author: Option<&GitAuthor>) -> Result<()> {
    tracing::info!(path = %path.display(), message = %message, "Committing library changes");

    // Stage all changes
    let output = git()
        .current_dir(path)
        .args(["add", "-A"])
        .output()
        .await
        .context("Failed to execute git add")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git add failed: {}", stderr);
    }

    // Build commit command with optional author
    // Commits are never signed: the identity only authenticates fetch and
    // push to the configured remote.
    let mut cmd = git();
    cmd.current_dir(path);
    cmd.args(["commit", "-m", message]);

    // Add author if both name and email are provided
    if let Some(author) = author {
        if let (Some(name), Some(email)) = (&author.name, &author.email) {
            let author_string = format!("{} <{}>", name, email);
            cmd.args(["--author", &author_string]);
        }
    }

    let output = cmd.output().await.context("Failed to execute git commit")?;

    // Exit code 1 means nothing to commit, which is fine
    if !output.status.success() && output.status.code() != Some(1) {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git commit failed: {}", stderr);
    }

    Ok(())
}

/// Push changes to remote.
pub async fn push(path: &Path) -> Result<()> {
    tracing::info!(path = %path.display(), "Pushing library changes");

    let mut cmd = trusted_git_at(path);
    cmd.current_dir(path).args(["push"]);
    apply_ssh_config(&mut cmd);
    let output = cmd.output().await.context("Failed to execute git push")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git push failed: {}", stderr);
    }

    Ok(())
}

// Helper functions

async fn get_branch(path: &Path) -> Result<String> {
    let output = git()
        .current_dir(path)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .await
        .context("Failed to get current branch")?;

    if !output.status.success() {
        anyhow::bail!("Failed to get branch name");
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

async fn get_remote(path: &Path) -> Result<String> {
    let output = git()
        .current_dir(path)
        .args(["remote", "get-url", "origin"])
        .output()
        .await
        .context("Failed to get remote URL")?;

    if !output.status.success() {
        anyhow::bail!("No remote origin configured");
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

async fn get_status(path: &Path) -> Result<(bool, Vec<String>)> {
    let output = git()
        .current_dir(path)
        .args(["status", "--porcelain"])
        .output()
        .await
        .context("Failed to get git status")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<String> = stdout
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect();

    Ok((lines.is_empty(), lines))
}

async fn get_ahead_behind(path: &Path) -> Result<(u32, u32)> {
    // First, fetch to update remote tracking branches
    let mut cmd = git();
    cmd.current_dir(path).args(["fetch", "--quiet"]);
    apply_ssh_config(&mut cmd);
    let _ = cmd.output().await;

    // Get ahead/behind counts
    let output = git()
        .current_dir(path)
        .args(["rev-list", "--left-right", "--count", "@{u}...HEAD"])
        .output()
        .await
        .context("Failed to get ahead/behind count")?;

    if !output.status.success() {
        // No upstream configured
        return Ok((0, 0));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<&str> = stdout.trim().split('\t').collect();

    if parts.len() == 2 {
        let behind = parts[0].parse().unwrap_or(0);
        let ahead = parts[1].parse().unwrap_or(0);
        Ok((ahead, behind))
    } else {
        Ok((0, 0))
    }
}
