//! Unified skill discovery, inspection, and synchronization across local agent harnesses.
//!
//! The Core Library is the only canonical skill source. The frontend fetches it from
//! `/api/library/skill` and passes the payloads in; the locally provisioned
//! `development-identity` skill (`~/.config/sandboxed-sh/development-identity/current/skill`)
//! is the only other canonical source.
//!
//! Older local folders (`~/work/skills/skills`, `~/work/paloma/skills`,
//! `~/.sandboxed-sh/library/skill` and the `sandboxed_sh/context/sandboxed-library/skill`
//! checkout) are *legacy* sources: they are still scanned and reported (so the UI can offer
//! "import to Library" and show divergent copies) but they are never synced to harnesses.
//!
//! Synchronization installs canonical skills whose audience includes `local` into the 6
//! user-level harness directories:
//! - Claude Code: `~/.claude/skills`
//! - Codex: `~/.codex/skills`
//! - Antigravity & Codex: `~/.agents/skills`
//! - OpenCode: `~/.config/opencode/skills`
//! - Grok: `~/.grok/skills`
//! - Mistral Vibe: `~/.vibe/skills`
//!
//! Installed copies carry an ownership marker (`.managed-by-orb-skills`, or the older
//! `.managed-by-agent-skills-repo`). Only marked entries are replaced or pruned; unmanaged
//! user skills are never overwritten or deleted (an identical unmanaged copy is adopted).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

const ORB_MANAGED_MARKER: &str = ".managed-by-orb-skills";
const LEGACY_MANAGED_MARKER: &str = ".managed-by-agent-skills-repo";
const IDENTITY_SKILL: &str = "development-identity";
const MAX_SOURCE_FILE_BYTES: u64 = 512 * 1024;

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
    /// Desired skills installed with the desired SKILL.md content.
    pub synced_count: usize,
    /// Number of desired (canonical, audience `local`) skills.
    pub canonical_total: usize,
    /// Desired skills not installed at all.
    pub missing_skills: Vec<String>,
    /// Desired skills installed with different content.
    #[serde(default)]
    pub outdated_skills: Vec<String>,
    /// Orb-managed entries that are no longer desired (removed by a pruning sync).
    #[serde(default)]
    pub stale_managed: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillSourceInfo {
    pub id: String,
    pub label: String,
    pub path: String,
    pub exists: bool,
    pub skill_count: usize,
    #[serde(default)]
    pub legacy: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillFileContent {
    pub rel: String,
    pub content: String,
}

/// One copy of a skill in a canonical or legacy source.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillSourceRef {
    pub id: String,
    pub label: String,
    pub path: Option<String>,
    pub legacy: bool,
    /// Short SHA-256 of the normalized SKILL.md.
    pub hash: String,
    pub lines: usize,
    /// Full SKILL.md for local sources (the frontend already holds Library content).
    pub content: Option<String>,
    /// Text reference files of local sources, for "import to Library".
    #[serde(default)]
    pub files: Vec<SkillFileContent>,
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
    #[serde(default)]
    pub sources: Vec<SkillSourceRef>,
    /// More than one distinct SKILL.md among canonical and legacy sources.
    #[serde(default)]
    pub divergent: bool,
    /// Installed by sync (canonical and audience includes `local`).
    #[serde(default)]
    pub desired: bool,
    #[serde(default)]
    pub in_library: bool,
    /// Only present in legacy folders: not synced until imported to the Library.
    #[serde(default)]
    pub legacy_only: bool,
    #[serde(default)]
    pub audience: Vec<String>,
    #[serde(default)]
    pub scope: Option<String>,
    /// Harnesses whose installed SKILL.md differs from the desired content.
    #[serde(default)]
    pub stale_harnesses: Vec<String>,
    #[serde(default)]
    pub lines: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalSkillsReport {
    pub checked_at: u64,
    pub home_dir: String,
    pub preflight: PreflightStatus,
    pub sources: Vec<SkillSourceInfo>,
    pub harnesses: Vec<HarnessSkillTarget>,
    pub skills: Vec<DiscoveredSkill>,
    /// Whether Library payloads were supplied (pruning is only meaningful then).
    #[serde(default)]
    pub library_known: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SyncSkillPayload {
    pub name: String,
    pub content: String,
    #[serde(default)]
    pub files: Vec<SyncSkillFilePayload>,
    /// Audience from the Library API; parsed from frontmatter when absent.
    #[serde(default)]
    pub audience: Option<Vec<String>>,
    #[serde(default)]
    pub scope: Option<String>,
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
    #[serde(default)]
    pub pruned: Vec<String>,
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

/// Default audience when `metadata.sandboxed.audience` is absent.
pub const DEFAULT_AUDIENCE: &[&str] = &["mission", "local"];

fn frontmatter_block(markdown: &str) -> Option<&str> {
    let text = markdown.trim_start_matches('\u{feff}');
    let rest = text
        .strip_prefix("---\n")
        .or_else(|| text.strip_prefix("---\r\n"))?;
    let end = rest
        .find("\n---")
        .or_else(|| rest.starts_with("---").then_some(0))?;
    Some(&rest[..end])
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

fn parse_inline_list(value: &str) -> Vec<String> {
    let v = value.trim();
    let inner = v
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(v);
    inner
        .split(',')
        .map(|s| unquote_yaml(s.trim()))
        .filter(|s| !s.is_empty())
        .collect()
}

/// Parse `metadata.sandboxed.audience` and `metadata.sandboxed.scope` from frontmatter.
/// Returns `(audience, scope)`; `None` audience means the key is absent.
pub fn parse_sandboxed_meta(markdown: &str) -> (Option<Vec<String>>, Option<String>) {
    let Some(yaml) = frontmatter_block(markdown) else {
        return (None, None);
    };
    let lines: Vec<&str> = yaml.lines().collect();
    let mut audience = None;
    let mut scope = None;
    let mut metadata_indent: Option<usize> = None;
    let mut sandboxed_indent: Option<usize> = None;
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            i += 1;
            continue;
        }
        let indent = indent_of(line);
        if let Some(si) = sandboxed_indent {
            if indent <= si {
                sandboxed_indent = None;
            }
        }
        if let Some(mi) = metadata_indent {
            if indent <= mi {
                metadata_indent = None;
                sandboxed_indent = None;
            }
        }
        if metadata_indent.is_none() {
            if trimmed == "metadata:" {
                metadata_indent = Some(indent);
            }
            i += 1;
            continue;
        }
        if sandboxed_indent.is_none() {
            if trimmed == "sandboxed:" {
                sandboxed_indent = Some(indent);
            }
            i += 1;
            continue;
        }
        if let Some(val) = trimmed.strip_prefix("audience:") {
            let val = val.trim();
            if val.is_empty() {
                let mut items = Vec::new();
                let mut j = i + 1;
                while j < lines.len() {
                    let t = lines[j].trim();
                    if let Some(item) = t.strip_prefix("- ").or_else(|| t.strip_prefix('-')) {
                        let item = unquote_yaml(item.trim());
                        if !item.is_empty() {
                            items.push(item);
                        }
                        j += 1;
                    } else if t.is_empty() {
                        j += 1;
                    } else {
                        break;
                    }
                }
                audience = Some(items);
                i = j;
                continue;
            }
            audience = Some(parse_inline_list(val));
        } else if let Some(val) = trimmed.strip_prefix("scope:") {
            let v = unquote_yaml(val.trim());
            if !v.is_empty() {
                scope = Some(v);
            }
        }
        i += 1;
    }
    (audience, scope)
}

fn effective_audience(explicit: Option<Vec<String>>, content: &str) -> Vec<String> {
    let mut list = explicit
        .or_else(|| parse_sandboxed_meta(content).0)
        .unwrap_or_else(|| DEFAULT_AUDIENCE.iter().map(|s| s.to_string()).collect());
    for item in list.iter_mut() {
        *item = item.trim().to_ascii_lowercase();
    }
    list.retain(|s| !s.is_empty());
    list.dedup();
    list
}

/// Short, stable content hash of a SKILL.md (line endings and trailing space normalized).
pub fn content_hash(content: &str) -> String {
    let normalized = content.replace("\r\n", "\n");
    let digest = Sha256::digest(normalized.trim_end().as_bytes());
    digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

fn line_count(content: &str) -> usize {
    content.lines().count()
}

/// Read text reference files of a local skill directory (excluding SKILL.md and markers).
fn read_skill_files(dir: &Path) -> Vec<SkillFileContent> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<SkillFileContent>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if name == ".git"
                || name == ".DS_Store"
                || name == ORB_MANAGED_MARKER
                || name == LEGACY_MANAGED_MARKER
            {
                continue;
            }
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_dir() {
                walk(root, &path, out);
            } else if ft.is_file() {
                let Ok(rel) = path.strip_prefix(root) else {
                    continue;
                };
                let rel = rel.to_string_lossy().replace('\\', "/");
                if rel == "SKILL.md" {
                    continue;
                }
                if entry
                    .metadata()
                    .map(|m| m.len() > MAX_SOURCE_FILE_BYTES)
                    .unwrap_or(true)
                {
                    continue;
                }
                if let Ok(content) = fs::read_to_string(&path) {
                    out.push(SkillFileContent { rel, content });
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort_by(|a, b| a.rel.cmp(&b.rel));
    out
}

/// Legacy local folders: scanned and reported, never synced.
fn legacy_sources(home: &Path) -> Vec<(String, String, PathBuf)> {
    vec![
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
            "Host Library copy".to_string(),
            home.join(".sandboxed-sh/library/skill"),
        ),
        (
            "workspace-library".to_string(),
            "Workspace Library Checkout".to_string(),
            home.join("work/paloma/sandboxed_sh/context/sandboxed-library/skill"),
        ),
    ]
}

fn identity_skill_dir(home: &Path) -> PathBuf {
    home.join(".config/sandboxed-sh/development-identity/current/skill")
}

/// What sync installs for one skill.
#[derive(Clone)]
enum DesiredBody {
    Dir(PathBuf),
    Inline(Vec<SkillFileContent>),
}

#[derive(Clone)]
struct DesiredSkill {
    content: String,
    body: DesiredBody,
}

struct Catalog {
    sources: Vec<SkillSourceInfo>,
    /// name -> source copies (library, identity, legacy)
    copies: BTreeMap<String, Vec<SkillSourceRef>>,
    /// name -> (audience, scope) for canonical skills
    canonical_meta: BTreeMap<String, (Vec<String>, Option<String>)>,
    desired: BTreeMap<String, DesiredSkill>,
    library_names: BTreeSet<String>,
    library_known: bool,
}

fn build_catalog(home: &Path, library: &[SyncSkillPayload]) -> Catalog {
    let mut sources = Vec::new();
    let mut copies: BTreeMap<String, Vec<SkillSourceRef>> = BTreeMap::new();
    let mut canonical_meta = BTreeMap::new();
    let mut desired = BTreeMap::new();
    let mut library_names = BTreeSet::new();

    for item in library {
        let name = item.name.trim().to_string();
        if !valid_skill_name(&name) || item.content.trim().is_empty() {
            continue;
        }
        let audience = effective_audience(item.audience.clone(), &item.content);
        let scope = item
            .scope
            .clone()
            .or_else(|| parse_sandboxed_meta(&item.content).1);
        library_names.insert(name.clone());
        copies
            .entry(name.clone())
            .or_default()
            .push(SkillSourceRef {
                id: "library".to_string(),
                label: "Library".to_string(),
                path: None,
                legacy: false,
                hash: content_hash(&item.content),
                lines: line_count(&item.content),
                content: None,
                files: Vec::new(),
            });
        if audience.iter().any(|a| a == "local") {
            desired.insert(
                name.clone(),
                DesiredSkill {
                    content: item.content.clone(),
                    body: DesiredBody::Inline(
                        item.files
                            .iter()
                            .map(|f| SkillFileContent {
                                rel: f.rel.clone(),
                                content: f.content.clone(),
                            })
                            .collect(),
                    ),
                },
            );
        }
        canonical_meta.insert(name, (audience, scope));
    }

    let identity_dir = identity_skill_dir(home);
    let identity_md = identity_dir.join("SKILL.md");
    let mut identity_count = 0;
    if let Ok(content) = fs::read_to_string(&identity_md) {
        identity_count = 1;
        copies
            .entry(IDENTITY_SKILL.to_string())
            .or_default()
            .push(SkillSourceRef {
                id: "development-identity".to_string(),
                label: "Development Identity".to_string(),
                path: Some(identity_dir.display().to_string()),
                legacy: false,
                hash: content_hash(&content),
                lines: line_count(&content),
                content: Some(content.clone()),
                files: Vec::new(),
            });
        let (audience, scope) = parse_sandboxed_meta(&content);
        canonical_meta.insert(
            IDENTITY_SKILL.to_string(),
            (
                audience
                    .unwrap_or_else(|| DEFAULT_AUDIENCE.iter().map(|s| s.to_string()).collect()),
                scope,
            ),
        );
        // The provisioned identity is machine-local and always installed.
        desired.insert(
            IDENTITY_SKILL.to_string(),
            DesiredSkill {
                content,
                body: DesiredBody::Dir(identity_dir.clone()),
            },
        );
    }
    sources.push(SkillSourceInfo {
        id: "development-identity".to_string(),
        label: "Development Identity".to_string(),
        path: identity_dir.display().to_string(),
        exists: identity_count == 1,
        skill_count: identity_count,
        legacy: false,
    });

    for (id, label, path) in legacy_sources(home) {
        let exists = path.is_dir();
        let entries = if exists {
            scan_skill_dir(&path)
        } else {
            Vec::new()
        };
        let skill_count = entries.len();
        for (name, dir_path, content, _) in entries {
            copies.entry(name).or_default().push(SkillSourceRef {
                id: id.clone(),
                label: label.clone(),
                path: Some(dir_path.display().to_string()),
                legacy: true,
                hash: content_hash(&content),
                lines: line_count(&content),
                files: read_skill_files(&dir_path),
                content: Some(content),
            });
        }
        sources.push(SkillSourceInfo {
            id,
            label,
            path: path.display().to_string(),
            exists,
            skill_count,
            legacy: true,
        });
    }

    Catalog {
        sources,
        copies,
        canonical_meta,
        desired,
        library_names,
        library_known: !library.is_empty(),
    }
}

fn is_managed_skill_dir(dir: &Path) -> bool {
    dir.join(ORB_MANAGED_MARKER).is_file() || dir.join(LEGACY_MANAGED_MARKER).is_file()
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

pub fn inspect_local_skills_in(
    home: &Path,
    library: &[SyncSkillPayload],
) -> Result<LocalSkillsReport, String> {
    let preflight = check_preflight(home);
    let catalog = build_catalog(home, library);
    let desired_names: BTreeSet<String> = catalog.desired.keys().cloned().collect();
    let desired_hash: BTreeMap<&str, String> = catalog
        .desired
        .iter()
        .map(|(k, v)| (k.as_str(), content_hash(&v.content)))
        .collect();

    let mut harness_targets = Vec::new();
    let mut skills: BTreeMap<String, DiscoveredSkill> = BTreeMap::new();

    for (name, copies) in &catalog.copies {
        let in_library = catalog.library_names.contains(name);
        let is_identity = copies.iter().any(|c| c.id == "development-identity");
        let primary = copies
            .iter()
            .find(|c| c.id == "library")
            .or_else(|| copies.iter().find(|c| !c.legacy))
            .or_else(|| copies.first());
        let lib_content = library
            .iter()
            .find(|l| l.name.trim() == name)
            .map(|l| l.content.as_str());
        let primary_content = lib_content
            .or_else(|| primary.and_then(|p| p.content.as_deref()))
            .unwrap_or("");
        let (audience, scope) = catalog
            .canonical_meta
            .get(name)
            .cloned()
            .unwrap_or_else(|| {
                let (a, s) = parse_sandboxed_meta(primary_content);
                (effective_audience(a, primary_content), s)
            });
        let hashes: BTreeSet<&str> = copies.iter().map(|c| c.hash.as_str()).collect();
        let (_, description) = parse_skill_frontmatter(primary_content);
        skills.insert(
            name.clone(),
            DiscoveredSkill {
                name: name.clone(),
                description,
                origin: primary.map(|p| p.label.clone()).unwrap_or_default(),
                source_path: primary.and_then(|p| p.path.clone()),
                harnesses: Vec::new(),
                managed: catalog.desired.contains_key(name),
                content_preview: Some(primary_content.chars().take(4000).collect()),
                divergent: hashes.len() > 1,
                desired: catalog.desired.contains_key(name),
                in_library,
                legacy_only: !in_library && !is_identity,
                audience,
                scope,
                stale_harnesses: Vec::new(),
                lines: line_count(primary_content),
                sources: copies.clone(),
            },
        );
    }

    for (id, hname, global_rel, project_rel) in HARNESS_TARGETS {
        let global_dir = home.join(global_rel);
        let exists = global_dir.is_dir();
        let entries = if exists {
            scan_skill_dir(&global_dir)
        } else {
            Vec::new()
        };
        let mut installed_names = BTreeSet::new();
        let mut matching = BTreeSet::new();
        let mut outdated = Vec::new();
        let mut stale_managed = Vec::new();

        for (skill_name, skill_path, content, description) in entries {
            installed_names.insert(skill_name.clone());
            let managed = !is_symlink(&skill_path) && is_managed_skill_dir(&skill_path);
            let hash = content_hash(&content);
            let item = skills
                .entry(skill_name.clone())
                .or_insert_with(|| DiscoveredSkill {
                    name: skill_name.clone(),
                    description: description.clone(),
                    origin: "User global".to_string(),
                    source_path: Some(skill_path.display().to_string()),
                    harnesses: Vec::new(),
                    managed,
                    content_preview: Some(content.chars().take(4000).collect()),
                    sources: Vec::new(),
                    divergent: false,
                    desired: false,
                    in_library: false,
                    legacy_only: false,
                    audience: Vec::new(),
                    scope: None,
                    stale_harnesses: Vec::new(),
                    lines: line_count(&content),
                });
            if item.description.is_none() && description.is_some() {
                item.description = description;
            }
            if !item.harnesses.iter().any(|h| h == id) {
                item.harnesses.push((*id).to_string());
            }
            match desired_hash.get(skill_name.as_str()) {
                Some(want) if *want == hash => {
                    matching.insert(skill_name.clone());
                }
                Some(_) => {
                    outdated.push(skill_name.clone());
                    item.stale_harnesses.push((*id).to_string());
                }
                None if managed => stale_managed.push(skill_name.clone()),
                None => {}
            }
        }

        let missing_skills: Vec<String> = desired_names
            .difference(&installed_names)
            .cloned()
            .collect();

        harness_targets.push(HarnessSkillTarget {
            id: (*id).to_string(),
            name: (*hname).to_string(),
            global_rel: format!("~/{global_rel}"),
            global_path: global_dir.display().to_string(),
            project_rel: (*project_rel).to_string(),
            exists,
            skill_count: installed_names.len(),
            synced_count: matching.len(),
            canonical_total: desired_names.len(),
            missing_skills,
            outdated_skills: outdated,
            stale_managed,
        });
    }

    Ok(LocalSkillsReport {
        checked_at: crate::agent_software::now(),
        home_dir: home.display().to_string(),
        preflight,
        sources: catalog.sources,
        harnesses: harness_targets,
        skills: skills.into_values().collect(),
        library_known: catalog.library_known,
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

fn write_marker(dest: &Path) {
    let _ = fs::write(dest.join(ORB_MANAGED_MARKER), "managed-by-orb-skills\n");
}

fn install_desired(dest: &Path, skill: &DesiredSkill) -> Result<(), String> {
    if dest.exists() || is_symlink(dest) {
        if is_symlink(dest) {
            fs::remove_file(dest).map_err(|e| e.to_string())?;
        } else {
            fs::remove_dir_all(dest).map_err(|e| e.to_string())?;
        }
    }
    match &skill.body {
        DesiredBody::Dir(src) => copy_dir_recursive(src, dest)?,
        DesiredBody::Inline(files) => {
            fs::create_dir_all(dest).map_err(|e| e.to_string())?;
            fs::write(dest.join("SKILL.md"), &skill.content).map_err(|e| e.to_string())?;
            for extra in files {
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
        }
    }
    write_marker(dest);
    Ok(())
}

pub fn sync_local_skills_in(
    home: &Path,
    request: SyncSkillsRequest,
) -> Result<SyncSkillsResult, String> {
    let catalog = build_catalog(home, &request.library_skills);
    // Pruning without a Library snapshot would remove every Library skill, so it
    // requires the caller to have supplied one.
    let prune = request.prune_removed && catalog.library_known;

    let mut skipped_unmanaged = BTreeSet::new();
    let mut pruned = Vec::new();
    let mut harnesses_updated = 0usize;

    for (_, _, global_rel, _) in HARNESS_TARGETS {
        let target_root = home.join(global_rel);
        fs::create_dir_all(&target_root)
            .map_err(|e| format!("Failed to create {}: {e}", target_root.display()))?;
        let mut updated_this_harness = false;

        for (skill_name, skill) in &catalog.desired {
            let dest = target_root.join(skill_name);
            if is_symlink(&dest) {
                // Preserve explicit symlinks unless broken.
                if fs::metadata(&dest).is_ok() {
                    continue;
                }
            } else if dest.is_dir() {
                let existing_md = fs::read_to_string(dest.join("SKILL.md")).unwrap_or_default();
                let same = content_hash(&existing_md) == content_hash(&skill.content);
                if !is_managed_skill_dir(&dest) {
                    // Adopt an identical unmanaged copy; otherwise it belongs to the user.
                    if same {
                        write_marker(&dest);
                    } else {
                        skipped_unmanaged.insert(format!("~/{global_rel}/{skill_name}"));
                    }
                    continue;
                }
                if same && matches!(skill.body, DesiredBody::Dir(_)) {
                    continue;
                }
                if !same {
                    updated_this_harness = true;
                }
                install_desired(&dest, skill)?;
                continue;
            }
            install_desired(&dest, skill)?;
            updated_this_harness = true;
        }

        if prune {
            if let Ok(entries) = fs::read_dir(&target_root) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                        continue;
                    };
                    if catalog.desired.contains_key(name)
                        || is_symlink(&path)
                        || !path.is_dir()
                        || !is_managed_skill_dir(&path)
                    {
                        continue;
                    }
                    if fs::remove_dir_all(&path).is_ok() {
                        pruned.push(format!("~/{global_rel}/{name}"));
                        updated_this_harness = true;
                    }
                }
            }
        }

        if updated_this_harness {
            harnesses_updated += 1;
        }
    }

    let report = inspect_local_skills_in(home, &request.library_skills)?;
    Ok(SyncSkillsResult {
        synced_skills: catalog.desired.len(),
        harnesses_updated,
        skipped_unmanaged: skipped_unmanaged.into_iter().collect(),
        pruned,
        report,
    })
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SkillsStatusRequest {
    #[serde(default)]
    pub library_skills: Vec<SyncSkillPayload>,
}

#[tauri::command]
pub async fn local_skills_status(
    request: Option<SkillsStatusRequest>,
) -> Result<LocalSkillsReport, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let home = home_dir()?;
        inspect_local_skills_in(&home, &request.unwrap_or_default().library_skills)
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

    fn write_skill(dir: &Path, body: &str) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join("SKILL.md"), body).unwrap();
    }

    fn lib(name: &str, content: &str) -> SyncSkillPayload {
        SyncSkillPayload {
            name: name.to_string(),
            content: content.to_string(),
            files: vec![SyncSkillFilePayload {
                rel: "references/notes.md".to_string(),
                content: "notes".to_string(),
            }],
            audience: None,
            scope: None,
        }
    }

    fn request(skills: Vec<SyncSkillPayload>, prune: bool) -> SyncSkillsRequest {
        SyncSkillsRequest {
            library_skills: skills,
            prune_removed: prune,
        }
    }

    #[test]
    fn parses_sandboxed_metadata_inline_and_block() {
        let inline = "---\nname: a\nmetadata:\n  sandboxed:\n    audience: [coordinator, \"local\"]\n    scope: global\n---\nBody\n";
        assert_eq!(
            parse_sandboxed_meta(inline),
            (
                Some(vec!["coordinator".to_string(), "local".to_string()]),
                Some("global".to_string())
            )
        );
        let block = "---\nname: a\nmetadata:\n  other: x\n  sandboxed:\n    audience:\n      - mission\n  owner: me\n---\n";
        assert_eq!(
            parse_sandboxed_meta(block),
            (Some(vec!["mission".to_string()]), None)
        );
        assert_eq!(parse_sandboxed_meta("---\nname: a\n---\n"), (None, None));
        // `audience` outside metadata.sandboxed is ignored.
        assert_eq!(
            parse_sandboxed_meta("---\naudience: [local]\n---\n"),
            (None, None)
        );
    }

    #[test]
    fn legacy_sources_are_reported_but_not_synced() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        write_skill(
            &home.join("work/skills/skills/proof-helper"),
            "---\nname: proof-helper\ndescription: Lean helper\n---\n# Proof\n",
        );
        write_skill(
            &home.join("work/paloma/skills/paloma-fleet"),
            "---\nname: paloma-fleet\ndescription: Fleet\n---\n# Fleet\n",
        );

        let res = sync_local_skills_in(
            home,
            request(
                vec![lib(
                    "core-audit",
                    "---\nname: core-audit\ndescription: Audit\n---\nAudit\n",
                )],
                true,
            ),
        )
        .unwrap();
        assert_eq!(res.synced_skills, 1);
        for (_, _, rel, _) in HARNESS_TARGETS {
            let root = home.join(rel);
            assert!(root.join("core-audit/SKILL.md").is_file());
            assert!(root.join("core-audit/references/notes.md").is_file());
            assert!(root.join("core-audit").join(ORB_MANAGED_MARKER).is_file());
            assert!(!root.join("proof-helper").exists());
            assert!(!root.join("paloma-fleet").exists());
        }
        let legacy = res
            .report
            .skills
            .iter()
            .find(|s| s.name == "proof-helper")
            .unwrap();
        assert!(legacy.legacy_only);
        assert!(!legacy.desired);
        assert!(legacy.sources.iter().all(|s| s.legacy));
        assert!(res
            .report
            .sources
            .iter()
            .any(|s| s.id == "agent-skills-repo" && s.legacy));
        for h in &res.report.harnesses {
            assert_eq!(h.canonical_total, 1);
            assert_eq!(h.synced_count, 1);
        }
    }

    #[test]
    fn audience_filter_only_installs_local_skills() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let coordinator = "---\nname: controllers-policy\ndescription: x\nmetadata:\n  sandboxed:\n    audience: [coordinator]\n---\n";
        let mission_only = "---\nname: m\nmetadata:\n  sandboxed:\n    audience: [mission]\n---\n";
        let default = "---\nname: d\n---\n";
        let mut explicit = lib("explicit", "---\nname: explicit\n---\n");
        explicit.audience = Some(vec!["Local".to_string()]);
        let res = sync_local_skills_in(
            home,
            request(
                vec![
                    lib("controllers-policy", coordinator),
                    lib("m", mission_only),
                    lib("d", default),
                    explicit,
                ],
                false,
            ),
        )
        .unwrap();
        let root = home.join(".claude/skills");
        assert!(!root.join("controllers-policy").exists());
        assert!(!root.join("m").exists());
        assert!(root.join("d/SKILL.md").is_file());
        assert!(root.join("explicit/SKILL.md").is_file());
        let cp = res
            .report
            .skills
            .iter()
            .find(|s| s.name == "controllers-policy")
            .unwrap();
        assert_eq!(cp.audience, vec!["coordinator".to_string()]);
        assert!(cp.in_library && !cp.desired);
        let d = res.report.skills.iter().find(|s| s.name == "d").unwrap();
        assert_eq!(d.audience, vec!["mission".to_string(), "local".to_string()]);
    }

    #[test]
    fn prune_removes_only_managed_and_preserves_unmanaged() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let keep = lib("keep", "---\nname: keep\n---\nK\n");
        let gone = lib("gone", "---\nname: gone\n---\nG\n");
        sync_local_skills_in(home, request(vec![keep.clone(), gone], false)).unwrap();

        // Unmanaged user skill and a legacy-marker skill, both not in the Library.
        let user = home.join(".claude/skills/my-own");
        write_skill(&user, "---\nname: my-own\n---\nmine\n");
        let old = home.join(".claude/skills/old-managed");
        write_skill(&old, "---\nname: old-managed\n---\n");
        fs::write(old.join(LEGACY_MANAGED_MARKER), "x").unwrap();

        let status = inspect_local_skills_in(home, std::slice::from_ref(&keep)).unwrap();
        let claude = status
            .harnesses
            .iter()
            .find(|h| h.id == "claudecode")
            .unwrap();
        assert_eq!(
            claude.stale_managed,
            vec!["gone".to_string(), "old-managed".to_string()]
        );

        // Without a Library snapshot pruning is refused.
        let res = sync_local_skills_in(home, request(vec![], true)).unwrap();
        assert!(res.pruned.is_empty());
        assert!(home.join(".claude/skills/gone").exists());

        let res = sync_local_skills_in(home, request(vec![keep], true)).unwrap();
        assert!(res.pruned.contains(&"~/.claude/skills/gone".to_string()));
        assert!(res
            .pruned
            .contains(&"~/.claude/skills/old-managed".to_string()));
        for (_, _, rel, _) in HARNESS_TARGETS {
            assert!(!home.join(rel).join("gone").exists());
            assert!(home.join(rel).join("keep/SKILL.md").is_file());
        }
        assert!(user.join("SKILL.md").is_file());
        assert!(!old.exists());
    }

    #[test]
    fn unmanaged_conflict_is_preserved_and_identical_copy_adopted() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let content = "---\nname: shared\n---\nS\n";
        let conflict = home.join(".claude/skills/shared");
        write_skill(&conflict, "---\nname: shared\n---\nuser edit\n");
        let identical = home.join(".grok/skills/shared");
        write_skill(&identical, content);

        let res = sync_local_skills_in(home, request(vec![lib("shared", content)], true)).unwrap();
        assert_eq!(
            res.skipped_unmanaged,
            vec!["~/.claude/skills/shared".to_string()]
        );
        assert_eq!(
            fs::read_to_string(conflict.join("SKILL.md")).unwrap(),
            "---\nname: shared\n---\nuser edit\n"
        );
        assert!(!conflict.join(ORB_MANAGED_MARKER).exists());
        assert!(identical.join(ORB_MANAGED_MARKER).is_file());
        let shared = res
            .report
            .skills
            .iter()
            .find(|s| s.name == "shared")
            .unwrap();
        assert_eq!(shared.stale_harnesses, vec!["claudecode".to_string()]);
        assert_eq!(shared.harnesses.len(), 6);
    }

    #[test]
    fn detects_divergent_copies_across_library_and_legacy() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let same = "---\nname: same\n---\nBody\n";
        write_skill(
            &home.join("work/paloma/skills/same"),
            &same.replace('\n', "\r\n"),
        );
        write_skill(
            &home.join("work/skills/skills/split"),
            "---\nname: split\n---\nOld body\n",
        );
        write_skill(
            &home.join("work/paloma/skills/split"),
            "---\nname: split\n---\nOld body\n",
        );
        let report = inspect_local_skills_in(
            home,
            &[
                lib("same", same),
                lib("split", "---\nname: split\n---\nNew body\n"),
            ],
        )
        .unwrap();
        let s = report.skills.iter().find(|s| s.name == "same").unwrap();
        assert!(!s.divergent, "line endings alone must not diverge");
        let split = report.skills.iter().find(|s| s.name == "split").unwrap();
        assert!(split.divergent);
        assert_eq!(split.sources.len(), 3);
        assert!(!split.legacy_only);
        let legacy = split.sources.iter().find(|s| s.legacy).unwrap();
        assert_eq!(
            legacy.content.as_deref(),
            Some("---\nname: split\n---\nOld body\n")
        );
    }

    #[test]
    fn identity_skill_is_always_installed() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        write_skill(
            &identity_skill_dir(home),
            "---\nname: development-identity\ndescription: id\n---\n",
        );
        let res = sync_local_skills_in(home, request(vec![], false)).unwrap();
        assert_eq!(res.synced_skills, 1);
        for (_, _, rel, _) in HARNESS_TARGETS {
            assert!(home
                .join(rel)
                .join("development-identity/SKILL.md")
                .is_file());
        }
    }
}
