//! Unified skill discovery, inspection, and synchronization across local agent harnesses.
//!
//! Scans canonical local skill sources (`~/work/skills/skills`, `~/work/paloma/skills`,
//! `~/.sandboxed-sh/library/skill`, `sandboxed_sh/context/sandboxed-library/skill`,
//! and `~/.config/sandboxed-sh/development-identity/current/skill`) as well as the
//! 6 local user-level harness directories:
//! - Claude Code: `~/.claude/skills`
//! - Codex: `~/.codex/skills`
//! - Antigravity & Codex: `~/.agents/skills`
//! - OpenCode: `~/.config/opencode/skills`
//! - Grok: `~/.grok/skills`
//! - Mistral Vibe: `~/.vibe/skills`
//!
//! Synchronization copies canonical skills (plus optional Library skills supplied by the
//! frontend) into all 6 harness directories using an explicit ownership marker
//! (`.managed-by-orb-skills` / `.managed-by-agent-skills-repo`) so user-authored
//! unmanaged skills are never overwritten or deleted.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

const ORB_MANAGED_MARKER: &str = ".managed-by-orb-skills";
const LEGACY_MANAGED_MARKER: &str = ".managed-by-agent-skills-repo";

const HARNESS_TARGETS: &[(&str, &str, &str, &str)] = &[
    (
        "claudecode",
        "Claude Code",
        ".claude/skills",
        ".claude/skills",
    ),
    ("codex", "Codex", ".codex/skills", ".agents/skills"),
    (
        "antigravity",
        "Antigravity",
        ".agents/skills",
        ".agents/skills",
    ),
    (
        "opencode",
        "OpenCode",
        ".config/opencode/skills",
        ".opencode/skills",
    ),
    ("grok", "Grok", ".grok/skills", ".grok/skills"),
    ("vibe", "Mistral Vibe", ".vibe/skills", ".vibe/skills"),
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreflightStatus {
    pub python3_ready: bool,
    pub python3_version: Option<String>,
    pub pyyaml_ready: bool,
    pub preflight_error: Option<String>,
    pub identity_ready: bool,
    pub identity_fingerprint: Option<String>,
    pub identity_updated_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessSkillTarget {
    pub id: String,
    pub name: String,
    pub global_rel: String,
    pub global_path: String,
    pub project_rel: String,
    pub exists: bool,
    pub skill_count: usize,
    pub synced_count: usize,
    pub canonical_total: usize,
    pub missing_skills: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillSourceInfo {
    pub id: String,
    pub label: String,
    pub path: String,
    pub exists: bool,
    pub skill_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredSkill {
    pub name: String,
    pub description: Option<String>,
    pub origin: String,
    pub source_path: Option<String>,
    pub harnesses: Vec<String>,
    pub managed: bool,
    pub content_preview: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalSkillsReport {
    pub checked_at: u64,
    pub home_dir: String,
    pub preflight: PreflightStatus,
    pub sources: Vec<SkillSourceInfo>,
    pub harnesses: Vec<HarnessSkillTarget>,
    pub skills: Vec<DiscoveredSkill>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SyncSkillPayload {
    pub name: String,
    pub content: String,
    #[serde(default)]
    pub files: Vec<SyncSkillFilePayload>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SyncSkillFilePayload {
    pub rel: String,
    pub content: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SyncSkillsRequest {
    #[serde(default)]
    pub library_skills: Vec<SyncSkillPayload>,
    #[serde(default)]
    pub prune_removed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSkillsResult {
    pub synced_skills: usize,
    pub harnesses_updated: usize,
    pub skipped_unmanaged: Vec<String>,
    pub report: LocalSkillsReport,
}

fn home_dir() -> Result<PathBuf, String> {
    if let Some(override_home) = std::env::var_os("ORB_SKILLS_TEST_HOME") {
        return Ok(PathBuf::from(override_home));
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".to_string())
}

fn valid_skill_name(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('.') && !name.contains(['/', '\\', '\0']) && name != ".."
}

/// Extract `name` and `description` from YAML frontmatter without external crates.
pub fn parse_skill_frontmatter(markdown: &str) -> (Option<String>, Option<String>) {
    let text = markdown.trim_start_matches('\u{feff}');
    let Some(rest) = text
        .strip_prefix("---\n")
        .or_else(|| text.strip_prefix("---\r\n"))
    else {
        return (None, first_paragraph_summary(text));
    };
    let end = rest
        .find("\n---\n")
        .or_else(|| rest.find("\r\n---\r\n"))
        .or_else(|| rest.find("\n---"))
        .unwrap_or(0);
    if end == 0 {
        return (None, first_paragraph_summary(text));
    }
    let yaml = &rest[..end];
    let body = &rest[end..];
    let mut name: Option<String> = None;
    let mut description: Option<String> = None;
    let lines: Vec<&str> = yaml.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            i += 1;
            continue;
        }
        if let Some(val) = trimmed.strip_prefix("name:") {
            let v = unquote_yaml(val.trim());
            if !v.is_empty() {
                name = Some(v);
            }
        } else if let Some(val) = trimmed.strip_prefix("description:") {
            let v = val.trim();
            if v == "|" || v == ">" || v == "|-" || v == ">-" || v.is_empty() {
                let mut multiline = Vec::new();
                i += 1;
                while i < lines.len() {
                    let next = lines[i];
                    if next.starts_with(' ') || next.starts_with('\t') {
                        multiline.push(next.trim());
                        i += 1;
                    } else if next.trim().is_empty() {
                        i += 1;
                    } else {
                        break;
                    }
                }
                if !multiline.is_empty() {
                    description = Some(multiline.join(" "));
                }
                continue;
            } else {
                let unq = unquote_yaml(v);
                if !unq.is_empty() {
                    description = Some(unq);
                }
            }
        }
        i += 1;
    }
    if description.is_none() {
        description = first_paragraph_summary(body);
    }
    (name, description)
}

fn unquote_yaml(val: &str) -> String {
    let v = val.trim();
    if (v.starts_with('"') && v.ends_with('"') && v.len() >= 2)
        || (v.starts_with('\'') && v.ends_with('\'') && v.len() >= 2)
    {
        v[1..v.len() - 1].trim().to_string()
    } else {
        v.to_string()
    }
}

fn first_paragraph_summary(body: &str) -> Option<String> {
    for line in body.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with("---") || t.starts_with('#') {
            continue;
        }
        return Some(t.chars().take(220).collect());
    }
    None
}

fn check_preflight(home: &Path) -> PreflightStatus {
    let mut python3_ready = false;
    let mut python3_version = None;
    let mut pyyaml_ready = false;
    let mut preflight_error = None;

    match Command::new("python3")
        .args([
            "-c",
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}'); import yaml; print('YAML_OK')",
        ])
        .output()
    {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let mut lines = stdout.lines();
            if let Some(ver) = lines.next() {
                if !ver.trim().is_empty() {
                    python3_ready = true;
                    python3_version = Some(ver.trim().to_string());
                }
            }
            if lines.any(|l| l.trim() == "YAML_OK") {
                pyyaml_ready = true;
            } else if python3_ready {
                let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
                preflight_error = Some(if stderr.is_empty() {
                    "PyYAML is not installed for python3".to_string()
                } else {
                    stderr
                });
            } else {
                preflight_error = Some(String::from_utf8_lossy(&out.stderr).trim().to_string());
            }
        }
        Err(e) => {
            preflight_error = Some(format!("python3 unavailable: {e}"));
        }
    }

    let receipt_path = home.join(".config/sandboxed-sh/development-identity/current/receipt.json");
    let skill_path = home.join(".config/sandboxed-sh/development-identity/current/skill/SKILL.md");
    let mut identity_ready = false;
    let mut identity_fingerprint = None;
    let mut identity_updated_at = None;

    if receipt_path.is_file() && skill_path.is_file() {
        if let Ok(bytes) = fs::read(&receipt_path) {
            if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                identity_ready = true;
                identity_fingerprint = json
                    .get("signing_fingerprint")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned);
                identity_updated_at = json.get("created_at").and_then(|v| v.as_u64());
            }
        }
    }

    PreflightStatus {
        python3_ready,
        python3_version,
        pyyaml_ready,
        preflight_error,
        identity_ready,
        identity_fingerprint,
        identity_updated_at,
    }
}

#[derive(Clone)]
struct CanonicalSkillEntry {
    description: Option<String>,
    origin: String,
    dir_path: PathBuf,
    content: String,
}

fn scan_skill_dir(root: &Path) -> Vec<(String, PathBuf, String, Option<String>)> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(root) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !valid_skill_name(name) {
            continue;
        }
        let skill_md = path.join("SKILL.md");
        if !skill_md.is_file() {
            continue;
        }
        let Ok(content) = fs::read_to_string(&skill_md) else {
            continue;
        };
        let (_, description) = parse_skill_frontmatter(&content);
        out.push((name.to_string(), path, content, description));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn candidate_sources(home: &Path) -> Vec<(String, String, PathBuf)> {
    let mut list = vec![
        (
            "agent-skills-repo".to_string(),
            "Agent Skills Repo".to_string(),
            home.join("work/skills/skills"),
        ),
        (
            "paloma-skills".to_string(),
            "Paloma Skills".to_string(),
            home.join("work/paloma/skills"),
        ),
        (
            "host-library".to_string(),
            "Host Library".to_string(),
            home.join(".sandboxed-sh/library/skill"),
        ),
        (
            "workspace-library".to_string(),
            "Workspace Library Checkout".to_string(),
            home.join("work/paloma/sandboxed_sh/context/sandboxed-library/skill"),
        ),
    ];
    let identity_skill = home.join(".config/sandboxed-sh/development-identity/current/skill");
    if identity_skill.join("SKILL.md").is_file() {
        list.push((
            "development-identity".to_string(),
            "Development Identity".to_string(),
            identity_skill,
        ));
    }
    list
}

fn collect_canonical_sources(
    home: &Path,
) -> (Vec<SkillSourceInfo>, BTreeMap<String, CanonicalSkillEntry>) {
    let mut sources_info = Vec::new();
    let mut canonical: BTreeMap<String, CanonicalSkillEntry> = BTreeMap::new();

    for (id, label, path) in candidate_sources(home) {
        if id == "development-identity" {
            let skill_md = path.join("SKILL.md");
            let exists = skill_md.is_file();
            let mut count = 0;
            if exists {
                if let Ok(content) = fs::read_to_string(&skill_md) {
                    let (_, description) = parse_skill_frontmatter(&content);
                    count = 1;
                    canonical.insert(
                        "development-identity".to_string(),
                        CanonicalSkillEntry {
                            description,
                            origin: label.clone(),
                            dir_path: path.clone(),
                            content,
                        },
                    );
                }
            }
            sources_info.push(SkillSourceInfo {
                id,
                label,
                path: path.display().to_string(),
                exists,
                skill_count: count,
            });
            continue;
        }

        let exists = path.is_dir();
        let entries = if exists {
            scan_skill_dir(&path)
        } else {
            Vec::new()
        };
        let skill_count = entries.len();
        for (name, dir_path, content, description) in entries {
            canonical.insert(
                name,
                CanonicalSkillEntry {
                    description,
                    origin: label.clone(),
                    dir_path,
                    content,
                },
            );
        }
        sources_info.push(SkillSourceInfo {
            id,
            label,
            path: path.display().to_string(),
            exists,
            skill_count,
        });
    }

    (sources_info, canonical)
}

fn is_managed_skill_dir(dir: &Path) -> bool {
    dir.join(ORB_MANAGED_MARKER).is_file() || dir.join(LEGACY_MANAGED_MARKER).is_file()
}

pub fn inspect_local_skills_in(home: &Path) -> Result<LocalSkillsReport, String> {
    let preflight = check_preflight(home);
    let (sources, canonical) = collect_canonical_sources(home);
    let canonical_names: BTreeSet<String> = canonical.keys().cloned().collect();

    let mut harness_targets = Vec::new();
    let mut discovered_map: BTreeMap<String, DiscoveredSkill> = BTreeMap::new();

    for (name, entry) in &canonical {
        discovered_map.insert(
            name.clone(),
            DiscoveredSkill {
                name: name.clone(),
                description: entry.description.clone(),
                origin: entry.origin.clone(),
                source_path: Some(entry.dir_path.display().to_string()),
                harnesses: Vec::new(),
                managed: true,
                content_preview: Some(entry.content.chars().take(4000).collect()),
            },
        );
    }

    for (id, name, global_rel, project_rel) in HARNESS_TARGETS {
        let global_dir = home.join(global_rel);
        let exists = global_dir.is_dir();
        let entries = if exists {
            scan_skill_dir(&global_dir)
        } else {
            Vec::new()
        };
        let installed_names: BTreeSet<String> = entries.iter().map(|e| e.0.clone()).collect();

        for (skill_name, skill_path, content, description) in entries {
            let managed = is_managed_skill_dir(&skill_path) || canonical.contains_key(&skill_name);
            let item =
                discovered_map
                    .entry(skill_name.clone())
                    .or_insert_with(|| DiscoveredSkill {
                        name: skill_name.clone(),
                        description: description.clone(),
                        origin: "User global".to_string(),
                        source_path: Some(skill_path.display().to_string()),
                        harnesses: Vec::new(),
                        managed,
                        content_preview: Some(content.chars().take(4000).collect()),
                    });
            if item.description.is_none() && description.is_some() {
                item.description = description;
            }
            if item.content_preview.is_none() {
                item.content_preview = Some(content.chars().take(4000).collect());
            }
            if !item.harnesses.iter().any(|h| h == id) {
                item.harnesses.push((*id).to_string());
            }
        }

        let canonical_total = if canonical_names.is_empty() {
            installed_names.len()
        } else {
            canonical_names.len()
        };
        let synced_count = if canonical_names.is_empty() {
            installed_names.len()
        } else {
            canonical_names.intersection(&installed_names).count()
        };
        let missing_skills: Vec<String> = canonical_names
            .difference(&installed_names)
            .cloned()
            .collect();

        harness_targets.push(HarnessSkillTarget {
            id: (*id).to_string(),
            name: (*name).to_string(),
            global_rel: format!("~/{global_rel}"),
            global_path: global_dir.display().to_string(),
            project_rel: (*project_rel).to_string(),
            exists,
            skill_count: installed_names.len(),
            synced_count,
            canonical_total,
            missing_skills,
        });
    }

    let skills: Vec<DiscoveredSkill> = discovered_map.into_values().collect();

    Ok(LocalSkillsReport {
        checked_at: crate::agent_software::now(),
        home_dir: home.display().to_string(),
        preflight,
        sources,
        harnesses: harness_targets,
        skills,
    })
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    fs::create_dir_all(dst).map_err(|e| format!("Failed to create {}: {e}", dst.display()))?;
    let entries =
        fs::read_dir(src).map_err(|e| format!("Failed to read {}: {e}", src.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let file_type = entry.file_type().map_err(|e| e.to_string())?;
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        if name_str == ".git" || name_str == ".DS_Store" {
            continue;
        }
        let src_path = entry.path();
        let dst_path = dst.join(&name);
        if file_type.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else if file_type.is_file() {
            fs::copy(&src_path, &dst_path)
                .map_err(|e| format!("Failed to copy {}: {e}", src_path.display()))?;
        }
    }
    Ok(())
}

fn safe_relative_path(rel: &str) -> Option<PathBuf> {
    let path = Path::new(rel);
    if path.is_absolute() {
        return None;
    }
    let mut clean = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::Normal(part) => {
                let s = part.to_str()?;
                if s.is_empty() || s == ".git" {
                    return None;
                }
                clean.push(part);
            }
            _ => return None,
        }
    }
    if clean.as_os_str().is_empty() {
        None
    } else {
        Some(clean)
    }
}

pub fn sync_local_skills_in(
    home: &Path,
    request: SyncSkillsRequest,
) -> Result<SyncSkillsResult, String> {
    let (_, canonical) = collect_canonical_sources(home);
    let mut library_map: BTreeMap<String, SyncSkillPayload> = BTreeMap::new();
    for item in request.library_skills {
        let name = item.name.trim().to_string();
        if valid_skill_name(&name) && !item.content.trim().is_empty() {
            library_map.insert(name.clone(), SyncSkillPayload { name, ..item });
        }
    }

    let mut all_skill_names: BTreeSet<String> = canonical.keys().cloned().collect();
    for name in library_map.keys() {
        all_skill_names.insert(name.clone());
    }

    // If neither canonical folders nor library skills exist, also union existing managed skills
    // across local harness directories so e.g. Claude's skills can still populate Antigravity/OpenCode.
    let mut fallback_dirs: BTreeMap<String, PathBuf> = BTreeMap::new();
    if all_skill_names.is_empty() {
        for (_, _, global_rel, _) in HARNESS_TARGETS {
            let root = home.join(global_rel);
            for (name, path, _, _) in scan_skill_dir(&root) {
                fallback_dirs.entry(name.clone()).or_insert(path);
                all_skill_names.insert(name);
            }
        }
    }

    let mut skipped_unmanaged = BTreeSet::new();
    let mut harnesses_updated = 0usize;

    for (_, _, global_rel, _) in HARNESS_TARGETS {
        let target_root = home.join(global_rel);
        fs::create_dir_all(&target_root)
            .map_err(|e| format!("Failed to create {}: {e}", target_root.display()))?;
        let mut updated_this_harness = false;

        for skill_name in &all_skill_names {
            let dest = target_root.join(skill_name);
            if dest.exists() {
                // Check if it is a symlink or unmanaged user folder.
                let meta = fs::symlink_metadata(&dest).map_err(|e| e.to_string())?;
                if meta.file_type().is_symlink() {
                    // Preserve explicit symlinks unless broken.
                    if fs::metadata(&dest).is_ok() {
                        continue;
                    }
                    let _ = fs::remove_file(&dest);
                } else if dest.is_dir() && !is_managed_skill_dir(&dest) {
                    // If the skill has the exact same SKILL.md as canonical, adopt it; otherwise preserve user-owned skill.
                    let existing_md = fs::read_to_string(dest.join("SKILL.md")).unwrap_or_default();
                    let canonical_md = canonical
                        .get(skill_name)
                        .map(|c| c.content.as_str())
                        .or_else(|| library_map.get(skill_name).map(|l| l.content.as_str()))
                        .unwrap_or("");
                    if !canonical_md.is_empty() && existing_md.trim() != canonical_md.trim() {
                        skipped_unmanaged.insert(format!("~/{global_rel}/{skill_name}"));
                        continue;
                    }
                }
            }

            if let Some(canon) = canonical.get(skill_name) {
                if dest != canon.dir_path {
                    if dest.exists() {
                        let _ = fs::remove_dir_all(&dest);
                    }
                    copy_dir_recursive(&canon.dir_path, &dest)?;
                    let _ = fs::write(dest.join(ORB_MANAGED_MARKER), "managed-by-orb-skills\n");
                    updated_this_harness = true;
                }
            } else if let Some(lib) = library_map.get(skill_name) {
                if dest.exists() {
                    let _ = fs::remove_dir_all(&dest);
                }
                fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
                fs::write(dest.join("SKILL.md"), &lib.content).map_err(|e| e.to_string())?;
                for extra in &lib.files {
                    if extra.rel == "SKILL.md" {
                        continue;
                    }
                    if let Some(rel_path) = safe_relative_path(&extra.rel) {
                        let out_path = dest.join(rel_path);
                        if let Some(parent) = out_path.parent() {
                            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                        }
                        fs::write(out_path, &extra.content).map_err(|e| e.to_string())?;
                    }
                }
                let _ = fs::write(dest.join(ORB_MANAGED_MARKER), "managed-by-orb-skills\n");
                updated_this_harness = true;
            } else if let Some(fallback_src) = fallback_dirs.get(skill_name) {
                if &dest != fallback_src {
                    if dest.exists() {
                        let _ = fs::remove_dir_all(&dest);
                    }
                    copy_dir_recursive(fallback_src, &dest)?;
                    let _ = fs::write(dest.join(ORB_MANAGED_MARKER), "managed-by-orb-skills\n");
                    updated_this_harness = true;
                }
            }
        }

        if request.prune_removed && !all_skill_names.is_empty() {
            if let Ok(entries) = fs::read_dir(&target_root) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                        continue;
                    };
                    if !all_skill_names.contains(name) && is_managed_skill_dir(&path) {
                        let _ = fs::remove_dir_all(&path);
                        updated_this_harness = true;
                    }
                }
            }
        }

        if updated_this_harness {
            harnesses_updated += 1;
        }
    }

    let report = inspect_local_skills_in(home)?;
    Ok(SyncSkillsResult {
        synced_skills: all_skill_names.len(),
        harnesses_updated,
        skipped_unmanaged: skipped_unmanaged.into_iter().collect(),
        report,
    })
}

#[tauri::command]
pub async fn local_skills_status() -> Result<LocalSkillsReport, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let home = home_dir()?;
        inspect_local_skills_in(&home)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn local_skills_sync(request: SyncSkillsRequest) -> Result<SyncSkillsResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let home = home_dir()?;
        sync_local_skills_in(&home, request)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_frontmatter_and_syncs_across_all_six_harnesses() {
        let temp = tempfile::tempdir().expect("tempdir");
        let home = temp.path();

        let repo_skill = home.join("work/skills/skills/proof-helper");
        fs::create_dir_all(&repo_skill).unwrap();
        fs::write(
            repo_skill.join("SKILL.md"),
            "---\nname: proof-helper\ndescription: |\n  Assists with Lean 4 tactic proofs.\n---\n# Proof Helper\n",
        )
        .unwrap();

        let paloma_skill = home.join("work/paloma/skills/paloma-fleet");
        fs::create_dir_all(&paloma_skill).unwrap();
        fs::write(
            paloma_skill.join("SKILL.md"),
            "---\nname: paloma-fleet\ndescription: \"Inspect and lease fleet compute nodes.\"\n---\n# Fleet\n",
        )
        .unwrap();

        // Create an unmanaged user skill in ~/.agents/skills/custom-user-skill
        let user_skill = home.join(".agents/skills/custom-user-skill");
        fs::create_dir_all(&user_skill).unwrap();
        fs::write(
            user_skill.join("SKILL.md"),
            "---\nname: custom-user-skill\ndescription: My personal skill\n---\nBody\n",
        )
        .unwrap();

        // Initial inspection shows drift (0/2 synced in each harness).
        let initial = inspect_local_skills_in(home).expect("inspect");
        assert_eq!(initial.harnesses.len(), 6);
        for h in &initial.harnesses {
            assert_eq!(h.synced_count, 0);
            assert_eq!(h.canonical_total, 2);
        }

        // Run sync with an additional Library skill from Core.
        let sync_res = sync_local_skills_in(
            home,
            SyncSkillsRequest {
                library_skills: vec![SyncSkillPayload {
                    name: "core-audit".to_string(),
                    content: "---\nname: core-audit\ndescription: Core library skill\n---\nAudit\n"
                        .to_string(),
                    files: vec![],
                }],
                prune_removed: false,
            },
        )
        .expect("sync");

        assert_eq!(sync_res.synced_skills, 3);
        assert_eq!(sync_res.harnesses_updated, 6);
        assert!(sync_res.skipped_unmanaged.is_empty());

        // Verify all 6 harness directories now have proof-helper, paloma-fleet, and core-audit,
        // and custom-user-skill is still preserved in ~/.agents/skills.
        for (_, _, global_rel, _) in HARNESS_TARGETS {
            let root = home.join(global_rel);
            assert!(root.join("proof-helper/SKILL.md").is_file());
            assert!(root.join("paloma-fleet/SKILL.md").is_file());
            assert!(root.join("core-audit/SKILL.md").is_file());
        }
        assert!(user_skill.join("SKILL.md").is_file());
    }
}
