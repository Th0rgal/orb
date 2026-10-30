//! Skills library management.
//!
//! Manages the git-backed skills repository containing `skill/<name>/SKILL.md`
//! alongside optional markdown and reference files.

mod git;
pub mod types;

use anyhow::{Context, Result};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use tokio::fs;

pub use crate::env_crypto;
pub use crate::model_policy::{normalize_claude_code_default_model, CLAUDE_CODE_DEFAULT_MODEL};
pub use git::{set_trusted_remote, GitAuthor};
pub use types::*;

const SKILL_DIR: &str = "skill";

/// Store for managing the git-backed skills library.
pub struct LibraryStore {
    /// Path to the library directory
    path: PathBuf,
    /// Git remote URL
    remote: String,
}

impl LibraryStore {
    /// Create a new LibraryStore, cloning the repo if needed.
    pub async fn new(path: PathBuf, remote: &str) -> Result<Self> {
        git::clone_if_needed(&path, remote).await?;
        git::ensure_remote(&path, remote).await?;

        Ok(Self {
            path,
            remote: remote.to_string(),
        })
    }

    /// Get the library path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Get the remote URL.
    pub fn remote(&self) -> &str {
        &self.remote
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Git Operations
    // ─────────────────────────────────────────────────────────────────────────

    /// Get the current git status of the library.
    pub async fn status(&self) -> Result<LibraryStatus> {
        git::status(&self.path).await
    }

    /// Pull latest changes from remote.
    ///
    /// Returns `Err` with a specific error if the pull fails due to diverged history
    /// (e.g., after a force push on the remote). In this case, use `force_sync` to
    /// reset the local branch to match remote.
    pub async fn sync(&self) -> Result<()> {
        match git::pull(&self.path).await {
            Ok(()) => Ok(()),
            Err(git::PullError::DivergedHistory { message }) => {
                anyhow::bail!("DIVERGED_HISTORY: {}", message);
            }
            Err(git::PullError::Other(e)) => Err(e),
        }
    }

    /// Force sync: reset local branch to match remote, discarding local changes.
    pub async fn force_sync(&self) -> Result<()> {
        git::force_pull(&self.path).await
    }

    /// Force push: overwrite remote with local changes.
    pub async fn force_push(&self) -> Result<()> {
        git::force_push(&self.path).await
    }

    /// Commit all changes with a message and optional author.
    pub async fn commit(&self, message: &str, author: Option<&git::GitAuthor>) -> Result<()> {
        git::commit(&self.path, message, author).await
    }

    /// Push changes to remote.
    pub async fn push(&self) -> Result<()> {
        git::push(&self.path).await
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Skills (skill/*/SKILL.md with additional .md files and references)
    // ─────────────────────────────────────────────────────────────────────────

    /// Get the skills directory path.
    fn skills_dir(&self) -> PathBuf {
        self.path.join(SKILL_DIR)
    }

    /// List all skills with their summaries.
    pub async fn list_skills(&self) -> Result<Vec<SkillSummary>> {
        let skills_dir = self.skills_dir();

        if !skills_dir.exists() {
            return Ok(Vec::new());
        }

        let mut skills = Vec::new();
        let mut entries = fs::read_dir(&skills_dir).await?;

        while let Some(entry) = entries.next_entry().await? {
            let entry_path = entry.path();

            if !entry_path.is_dir() {
                continue;
            }

            let skill_md = entry_path.join("SKILL.md");
            if !skill_md.exists() {
                continue;
            }

            let name = entry.file_name().to_string_lossy().to_string();

            let content = fs::read_to_string(&skill_md).await.ok();
            let (frontmatter, _) = content
                .as_ref()
                .map(|c| parse_frontmatter(c))
                .unwrap_or((None, ""));

            let description = extract_description(&frontmatter);
            let delivery = extract_skill_delivery(&frontmatter);
            let line_count = content.as_deref().map(|c| c.lines().count()).unwrap_or(0);

            skills.push(SkillSummary {
                name,
                description,
                path: format!("{}/{}", SKILL_DIR, entry.file_name().to_string_lossy()),
                audience: delivery.audience,
                scope: delivery.scope,
                line_count,
            });
        }

        skills.sort_by(|a, b| a.name.cmp(&b.name));

        Ok(skills)
    }

    /// Commits that changed a skill's SKILL.md, newest first.
    pub async fn skill_history(&self, name: &str) -> Result<Vec<types::LibraryHistoryEntry>> {
        Self::validate_name(name)?;
        git::log_path(&self.path, &format!("{SKILL_DIR}/{name}/SKILL.md"), 30).await
    }

    /// A skill's SKILL.md at an earlier commit (restore saves it as a new version).
    pub async fn skill_at(&self, name: &str, rev: &str) -> Result<String> {
        Self::validate_name(name)?;
        git::show_at(&self.path, rev, &format!("{SKILL_DIR}/{name}/SKILL.md")).await
    }

    /// Get a skill by name with full content.
    pub async fn get_skill(&self, name: &str) -> Result<Skill> {
        Self::validate_name(name)?;
        let skill_dir = self.skills_dir().join(name);
        let skill_md = skill_dir.join("SKILL.md");

        if !skill_md.exists() {
            anyhow::bail!("Skill not found: {}", name);
        }

        let content = fs::read_to_string(&skill_md)
            .await
            .context("Failed to read SKILL.md")?;

        let (frontmatter, _body) = parse_frontmatter(&content);
        let description = extract_description(&frontmatter);

        let (files, references) = self.collect_skill_files(&skill_dir).await?;
        let delivery = extract_skill_delivery(&frontmatter);
        let line_count = content.lines().count();

        Ok(Skill {
            name: name.to_string(),
            description,
            path: format!("{}/{}", SKILL_DIR, name),
            content,
            files,
            references,
            audience: delivery.audience,
            scope: delivery.scope,
            line_count,
        })
    }

    /// Collect all .md files and reference files from a skill directory.
    async fn collect_skill_files(&self, skill_dir: &Path) -> Result<(Vec<SkillFile>, Vec<String>)> {
        let mut md_files = Vec::new();
        let mut references = Vec::new();
        let mut visited = HashSet::new();

        self.collect_skill_files_recursive(
            skill_dir,
            skill_dir,
            &mut md_files,
            &mut references,
            &mut visited,
        )
        .await?;

        md_files.sort_by(|a, b| a.name.cmp(&b.name));
        references.sort();

        Ok((md_files, references))
    }

    /// Recursively collect .md files and references.
    // async-recursion 1.1.1 generates #[must_use] on an already must-use Future.
    #[allow(clippy::double_must_use)]
    #[async_recursion::async_recursion]
    async fn collect_skill_files_recursive(
        &self,
        base_dir: &Path,
        current_dir: &Path,
        md_files: &mut Vec<SkillFile>,
        references: &mut Vec<String>,
        visited: &mut HashSet<PathBuf>,
    ) -> Result<()> {
        if !current_dir.exists() {
            return Ok(());
        }

        let canonical_path = match current_dir.canonicalize() {
            Ok(p) => p,
            Err(_) => return Ok(()),
        };

        if !visited.insert(canonical_path) {
            return Ok(());
        }

        let mut entries = fs::read_dir(current_dir).await?;

        while let Some(entry) = entries.next_entry().await? {
            let entry_path = entry.path();
            let file_name = entry.file_name().to_string_lossy().to_string();

            if file_name.starts_with('.') {
                continue;
            }

            let metadata = match fs::symlink_metadata(&entry_path).await {
                Ok(m) => m,
                Err(_) => continue,
            };

            if metadata.is_dir() {
                self.collect_skill_files_recursive(
                    base_dir,
                    &entry_path,
                    md_files,
                    references,
                    visited,
                )
                .await?;
            } else if metadata.is_file() {
                let relative_path = entry_path
                    .strip_prefix(base_dir)
                    .unwrap_or(&entry_path)
                    .to_string_lossy()
                    .to_string();

                if file_name.ends_with(".md") {
                    if file_name != "SKILL.md" {
                        let file_content =
                            fs::read_to_string(&entry_path).await.unwrap_or_default();
                        md_files.push(SkillFile {
                            name: file_name,
                            path: relative_path,
                            content: file_content,
                        });
                    }
                } else {
                    references.push(relative_path);
                }
            }
        }

        Ok(())
    }

    /// Save a skill's SKILL.md content.
    pub async fn save_skill(&self, name: &str, content: &str) -> Result<()> {
        Self::validate_name(name)?;

        let skill_dir = self.skills_dir().join(name);
        let skill_md = skill_dir.join("SKILL.md");

        fs::create_dir_all(&skill_dir).await?;
        fs::write(&skill_md, content)
            .await
            .context("Failed to write SKILL.md")?;

        Ok(())
    }

    /// Delete a skill and its directory.
    pub async fn delete_skill(&self, name: &str) -> Result<()> {
        Self::validate_name(name)?;

        let skill_dir = self.skills_dir().join(name);

        if skill_dir.exists() {
            fs::remove_dir_all(&skill_dir)
                .await
                .context("Failed to delete skill directory")?;
        }

        Ok(())
    }

    /// Validate that a name doesn't contain path traversal sequences.
    /// Names should be simple identifiers without directory separators.
    fn validate_name(name: &str) -> Result<()> {
        if name.is_empty() {
            anyhow::bail!("Name cannot be empty");
        }

        if name.contains("..") || name.contains('/') || name.contains('\\') {
            anyhow::bail!("Name contains invalid characters");
        }

        if name.starts_with('.') {
            anyhow::bail!("Name cannot start with a dot");
        }

        Ok(())
    }

    /// Validate that a path doesn't escape the base directory via traversal.
    fn validate_path_within(&self, base: &std::path::Path, target: &std::path::Path) -> Result<()> {
        for component in target.components() {
            if let std::path::Component::ParentDir = component {
                anyhow::bail!("Path traversal not allowed");
            }
        }

        let base_canonical = if base.exists() {
            base.canonicalize()?
        } else {
            let mut candidate = base.to_path_buf();
            while !candidate.exists() {
                match candidate.parent() {
                    Some(parent) if parent != candidate => candidate = parent.to_path_buf(),
                    _ => break,
                }
            }
            candidate.canonicalize().unwrap_or(candidate)
        };

        if target.exists() {
            let target_canonical = target.canonicalize()?;
            if !target_canonical.starts_with(&base_canonical) {
                anyhow::bail!("Path escapes allowed directory");
            }
        } else {
            let mut current = target.to_path_buf();
            while let Some(parent) = current.parent() {
                if parent.exists() {
                    let parent_canonical = parent.canonicalize()?;
                    if !parent_canonical.starts_with(&base_canonical) {
                        anyhow::bail!("Path escapes allowed directory");
                    }
                    break;
                }
                current = parent.to_path_buf();
            }
            if !target.starts_with(base) {
                anyhow::bail!("Path escapes allowed directory");
            }
            if target == base {
                anyhow::bail!("Target equals base directory");
            }
        }

        Ok(())
    }

    /// Get a reference file from a skill.
    pub async fn get_skill_reference(&self, skill_name: &str, ref_path: &str) -> Result<String> {
        Self::validate_name(skill_name)?;
        let skill_dir = self.skills_dir().join(skill_name);
        let file_path = skill_dir.join(ref_path);

        self.validate_path_within(&skill_dir, &file_path)?;

        if !file_path.exists() {
            anyhow::bail!("Reference file not found: {}/{}", skill_name, ref_path);
        }

        fs::read_to_string(&file_path)
            .await
            .context("Failed to read reference file")
    }

    /// Save a reference file for a skill.
    pub async fn save_skill_reference(
        &self,
        skill_name: &str,
        ref_path: &str,
        content: &str,
    ) -> Result<()> {
        Self::validate_name(skill_name)?;
        let skill_dir = self.skills_dir().join(skill_name);
        let file_path = skill_dir.join(ref_path);

        self.validate_path_within(&skill_dir, &file_path)?;

        if let Some(parent) = file_path.parent() {
            fs::create_dir_all(parent).await?;
        }

        fs::write(&file_path, content)
            .await
            .context("Failed to write reference file")?;

        Ok(())
    }

    /// Delete a reference file from a skill.
    pub async fn delete_skill_reference(&self, skill_name: &str, ref_path: &str) -> Result<()> {
        Self::validate_name(skill_name)?;
        let skill_dir = self.skills_dir().join(skill_name);
        let file_path = skill_dir.join(ref_path);

        self.validate_path_within(&skill_dir, &file_path)?;

        if ref_path == "SKILL.md" || ref_path.ends_with("/SKILL.md") {
            anyhow::bail!("Cannot delete SKILL.md via reference API - use delete_skill instead");
        }

        if !file_path.exists() {
            anyhow::bail!("Reference file not found: {}/{}", skill_name, ref_path);
        }

        let metadata = fs::metadata(&file_path).await?;
        if metadata.is_dir() {
            fs::remove_dir_all(&file_path)
                .await
                .context("Failed to delete directory")?;
        } else {
            fs::remove_file(&file_path)
                .await
                .context("Failed to delete reference file")?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claudecode_default_model_upgrades_retired_opus() {
        assert_eq!(normalize_claude_code_default_model(None), "claude-opus-5");
        assert_eq!(
            normalize_claude_code_default_model(Some("anthropic/claude-opus-4-8".to_string())),
            "claude-opus-5"
        );
        assert_eq!(
            normalize_claude_code_default_model(Some("claude-sonnet-5".to_string())),
            "claude-sonnet-5"
        );
    }

    #[test]
    fn test_parse_frontmatter() {
        let content = r#"---
name: test-skill
description: A test skill
---

# Test Skill

This is the body."#;

        let (frontmatter, body) = parse_frontmatter(content);

        assert!(frontmatter.is_some());
        let fm = frontmatter.unwrap();
        assert_eq!(fm.get("name").unwrap().as_str().unwrap(), "test-skill");
        assert_eq!(
            fm.get("description").unwrap().as_str().unwrap(),
            "A test skill"
        );
        assert!(body.contains("# Test Skill"));
    }

    #[test]
    fn test_parse_frontmatter_no_frontmatter() {
        let content = "# Just a heading\n\nSome content.";

        let (frontmatter, body) = parse_frontmatter(content);

        assert!(frontmatter.is_none());
        assert_eq!(body, content);
    }

    #[test]
    fn test_validate_name_valid() {
        assert!(LibraryStore::validate_name("my-skill").is_ok());
        assert!(LibraryStore::validate_name("skill_name").is_ok());
        assert!(LibraryStore::validate_name("skill123").is_ok());
    }

    #[test]
    fn test_validate_name_rejects_path_traversal() {
        assert!(LibraryStore::validate_name("..").is_err());
        assert!(LibraryStore::validate_name("../etc").is_err());
        assert!(LibraryStore::validate_name("skill/../etc").is_err());
        assert!(LibraryStore::validate_name("skill/subdir").is_err());
        assert!(LibraryStore::validate_name("skill\\subdir").is_err());
    }

    #[test]
    fn test_validate_name_rejects_hidden() {
        assert!(LibraryStore::validate_name(".hidden").is_err());
        assert!(LibraryStore::validate_name(".").is_err());
    }

    #[test]
    fn test_validate_name_rejects_empty() {
        assert!(LibraryStore::validate_name("").is_err());
    }

    fn test_store() -> LibraryStore {
        LibraryStore {
            path: std::path::PathBuf::from("/unused"),
            remote: String::new(),
        }
    }

    #[test]
    fn test_validate_path_within_allows_descendant() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().join("lib");
        std::fs::create_dir_all(&base).unwrap();
        let target = base.join("sub/file.json");
        assert!(test_store().validate_path_within(&base, &target).is_ok());
    }

    #[test]
    fn test_validate_path_within_allows_fresh_install_missing_base() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().join("skill/new-skill");
        let target = base.join("references/guide.md");
        assert!(test_store().validate_path_within(&base, &target).is_ok());
    }

    #[test]
    fn test_validate_path_within_rejects_parent_traversal() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().join("lib");
        std::fs::create_dir_all(&base).unwrap();
        let target = base.join("../escape.json");
        assert!(test_store().validate_path_within(&base, &target).is_err());
    }

    #[test]
    fn test_validate_path_within_rejects_sibling_name_prefix() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().join("lib");
        let sibling = tmp.path().join("library/evil.json");
        assert!(test_store().validate_path_within(&base, &sibling).is_err());
    }

    #[test]
    fn test_validate_path_within_rejects_target_equal_base() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().join("lib");
        assert!(test_store().validate_path_within(&base, &base).is_err());
    }

    #[tokio::test]
    async fn save_get_and_delete_skill_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let store = LibraryStore {
            path: tmp.path().to_path_buf(),
            remote: "test-remote".to_string(),
        };

        let content = "---\ndescription: Demo skill\n---\n\n# Demo\n";
        store.save_skill("demo", content).await.unwrap();
        store
            .save_skill_reference("demo", "references/notes.md", "extra")
            .await
            .unwrap();
        store
            .save_skill_reference("demo", "scripts/check.sh", "#!/bin/sh\n")
            .await
            .unwrap();

        let summaries = store.list_skills().await.unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].name, "demo");
        assert_eq!(summaries[0].description.as_deref(), Some("Demo skill"));

        let skill = store.get_skill("demo").await.unwrap();
        assert_eq!(skill.content, content);
        assert_eq!(skill.files.len(), 1);
        assert_eq!(skill.files[0].path, "references/notes.md");
        assert_eq!(skill.references, vec!["scripts/check.sh"]);

        assert_eq!(
            store
                .get_skill_reference("demo", "scripts/check.sh")
                .await
                .unwrap(),
            "#!/bin/sh\n"
        );
        store
            .delete_skill_reference("demo", "scripts/check.sh")
            .await
            .unwrap();
        store.delete_skill("demo").await.unwrap();
        assert!(store.list_skills().await.unwrap().is_empty());
    }
}
