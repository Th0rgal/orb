//! Types for the skills library.

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Skill Types (supports multiple .md files per skill)
// ─────────────────────────────────────────────────────────────────────────────

/// A single markdown file within a skill folder.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillFile {
    /// File name (e.g., "SKILL.md", "examples.md")
    pub name: String,
    /// Path relative to skill folder
    pub path: String,
    /// Full file content
    pub content: String,
}

/// Delivery scope of a Library skill.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "kebab-case")]
pub enum SkillScope {
    /// Delivered to every mission whose audience matches.
    Global,
    /// Delivered only when selected (workspace or project skill list).
    #[default]
    OnDemand,
}

pub const SKILL_AUDIENCE_MISSION: &str = "mission";

pub fn default_skill_audience() -> Vec<String> {
    vec!["mission".to_string(), "local".to_string()]
}

/// Delivery metadata parsed from `metadata.sandboxed` in SKILL.md frontmatter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillDeliveryMeta {
    pub audience: Vec<String>,
    pub scope: SkillScope,
}

impl SkillDeliveryMeta {
    pub fn targets_missions(&self) -> bool {
        self.audience.iter().any(|a| a == SKILL_AUDIENCE_MISSION)
    }
}

/// Parse `metadata.sandboxed.{audience,scope}`; absent values fall back to
/// `audience: [mission, local]` and `scope: on-demand`.
pub fn extract_skill_delivery(frontmatter: &Option<serde_yaml::Value>) -> SkillDeliveryMeta {
    let sandboxed = frontmatter
        .as_ref()
        .and_then(|fm| fm.get("metadata"))
        .and_then(|m| m.get("sandboxed"));
    let audience = sandboxed
        .and_then(|s| s.get("audience"))
        .and_then(|v| match v {
            serde_yaml::Value::Sequence(seq) => Some(
                seq.iter()
                    .filter_map(|v| v.as_str().map(|s| s.trim().to_ascii_lowercase()))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>(),
            ),
            serde_yaml::Value::String(s) => Some(
                s.split(',')
                    .map(|s| s.trim().to_ascii_lowercase())
                    .filter(|s| !s.is_empty())
                    .collect(),
            ),
            _ => None,
        })
        .unwrap_or_else(default_skill_audience);
    let scope = match sandboxed
        .and_then(|s| s.get("scope"))
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_ascii_lowercase())
        .as_deref()
    {
        Some("global") => SkillScope::Global,
        _ => SkillScope::OnDemand,
    };
    SkillDeliveryMeta { audience, scope }
}

/// Skill summary for listing (without full content).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillSummary {
    /// Skill name (folder name, e.g., "frontend-development")
    pub name: String,
    /// Description from SKILL.md frontmatter
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Path relative to library root (e.g., "skill/frontend-development")
    pub path: String,
    /// Who should receive this skill (`metadata.sandboxed.audience`).
    /// Absent in frontmatter => `[mission, local]`.
    #[serde(default = "default_skill_audience")]
    pub audience: Vec<String>,
    /// Delivery scope (`metadata.sandboxed.scope`): `global` or `on-demand`.
    #[serde(default)]
    pub scope: SkillScope,
    /// Number of lines in SKILL.md.
    #[serde(default)]
    pub line_count: usize,
}

/// Full skill with content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Skill {
    /// Skill name (folder name)
    pub name: String,
    /// Description from SKILL.md frontmatter
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Path relative to library root
    pub path: String,
    /// Primary SKILL.md content
    pub content: String,
    /// All markdown files in the skill folder (excluding SKILL.md)
    #[serde(default)]
    pub files: Vec<SkillFile>,
    /// List of non-.md reference files
    #[serde(default)]
    pub references: Vec<String>,
    /// Who should receive this skill (`metadata.sandboxed.audience`).
    /// Absent in frontmatter => `[mission, local]`.
    #[serde(default = "default_skill_audience")]
    pub audience: Vec<String>,
    /// Delivery scope (`metadata.sandboxed.scope`): `global` or `on-demand`.
    #[serde(default)]
    pub scope: SkillScope,
    /// Number of lines in SKILL.md.
    #[serde(default)]
    pub line_count: usize,
}

// ─────────────────────────────────────────────────────────────────────────────
// Library Status & History
// ─────────────────────────────────────────────────────────────────────────────

/// Git status for the library repository.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryStatus {
    /// Absolute path to the library
    pub path: String,
    /// Git remote URL if configured
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    /// Current branch name
    pub branch: String,
    /// True if working directory is clean
    pub clean: bool,
    /// Number of commits ahead of remote
    pub ahead: u32,
    /// Number of commits behind remote
    pub behind: u32,
    /// List of modified/untracked files
    pub modified_files: Vec<String>,
    /// Unix time of the last fetch from the remote (`.git/FETCH_HEAD`), if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_synced_at: Option<i64>,
}

/// One commit that changed a Library file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryHistoryEntry {
    pub rev: String,
    pub author: String,
    /// Unix time of the commit.
    pub timestamp: i64,
    pub subject: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Frontmatter Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Parse YAML frontmatter from markdown content.
/// Returns (frontmatter, body) where frontmatter is the parsed YAML.
pub fn parse_frontmatter(content: &str) -> (Option<serde_yaml::Value>, &str) {
    if !content.starts_with("---") {
        return (None, content);
    }

    // Normalize line endings to handle Windows-style \r\n
    let normalized = content.replace("\r\n", "\n");
    let normalized_ref = normalized.as_str();

    let rest = &normalized_ref[3..];

    // Find closing --- (could be \n--- or end of yaml section)
    if let Some(end_pos) = rest.find("\n---") {
        let yaml_str = rest[..end_pos].trim();

        // Try serde_yaml first
        match serde_yaml::from_str(yaml_str) {
            Ok(value) => {
                // Return body slice from original content if possible, otherwise use normalized
                let original_body = find_body_in_original(content);
                return (Some(value), original_body);
            }
            Err(e) => {
                // Log the error for debugging but try fallback parser
                tracing::debug!("serde_yaml parse failed, trying fallback: {}", e);
            }
        }

        // Fallback: simple line-by-line parser for basic key: value pairs
        if let Some(fallback) = parse_simple_frontmatter(yaml_str) {
            let original_body = find_body_in_original(content);
            return (Some(fallback), original_body);
        }

        // Both parsers failed
        (None, content)
    } else {
        (None, content)
    }
}

/// Find the body content in the original (non-normalized) content.
fn find_body_in_original(content: &str) -> &str {
    // Look for closing --- after the opening ---
    if let Some(start) = content.find("---") {
        let after_open = &content[start + 3..];
        // Find closing delimiter (handles both \n--- and \r\n---)
        if let Some(close_pos) = after_open.find("\n---") {
            let body_start = start + 3 + close_pos + 4;
            if body_start < content.len() {
                return content[body_start..].trim_start();
            }
        } else if let Some(close_pos) = after_open.find("\r\n---") {
            let body_start = start + 3 + close_pos + 5;
            if body_start < content.len() {
                return content[body_start..].trim_start();
            }
        }
    }
    content
}

/// Simple fallback parser for basic YAML frontmatter.
/// Handles simple key: value pairs when serde_yaml fails.
fn parse_simple_frontmatter(yaml_str: &str) -> Option<serde_yaml::Value> {
    use serde_yaml::{Mapping, Value};

    let mut map = Mapping::new();
    let mut current_key: Option<String> = None;
    let mut current_value = String::new();
    let mut in_multiline = false;

    for line in yaml_str.lines() {
        let trimmed = line.trim();

        // Skip empty lines at the start
        if trimmed.is_empty() && current_key.is_none() {
            continue;
        }

        // Check for new key: value pair
        if let Some(colon_pos) = line.find(':') {
            let potential_key = line[..colon_pos].trim();
            // Only treat as new key if it starts at beginning (not indented) and is alphanumeric
            if !line.starts_with(' ') && !line.starts_with('\t') && !potential_key.is_empty() {
                // Save previous key-value if exists
                if let Some(key) = current_key.take() {
                    let val = current_value.trim().to_string();
                    map.insert(Value::String(key), Value::String(val));
                    current_value.clear();
                }

                current_key = Some(potential_key.to_string());
                let value_part = line[colon_pos + 1..].trim();

                // Check for multiline indicators
                if value_part == ">"
                    || value_part == "|"
                    || value_part == ">-"
                    || value_part == "|-"
                {
                    in_multiline = true;
                    current_value.clear();
                } else {
                    in_multiline = false;
                    // Remove surrounding quotes if present
                    let cleaned = value_part
                        .trim_start_matches('"')
                        .trim_end_matches('"')
                        .trim_start_matches('\'')
                        .trim_end_matches('\'');
                    current_value = cleaned.to_string();
                }
                continue;
            }
        }

        // Continuation of multiline value
        if in_multiline && current_key.is_some() {
            if !current_value.is_empty() {
                current_value.push(' ');
            }
            current_value.push_str(trimmed);
        }
    }

    // Save last key-value
    if let Some(key) = current_key {
        let val = current_value.trim().to_string();
        map.insert(Value::String(key), Value::String(val));
    }

    if map.is_empty() {
        None
    } else {
        Some(Value::Mapping(map))
    }
}

/// Extract description from YAML frontmatter.
pub fn extract_description(frontmatter: &Option<serde_yaml::Value>) -> Option<String> {
    frontmatter.as_ref().and_then(|fm| {
        fm.get("description")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    })
}

#[cfg(test)]
mod skill_delivery_tests {
    use super::*;

    fn meta(md: &str) -> SkillDeliveryMeta {
        let (fm, _) = parse_frontmatter(md);
        extract_skill_delivery(&fm)
    }

    #[test]
    fn skill_delivery_defaults_when_absent() {
        let m = meta("---\nname: a\ndescription: x\n---\nbody");
        assert_eq!(m.audience, vec!["mission", "local"]);
        assert_eq!(m.scope, SkillScope::OnDemand);
        assert!(m.targets_missions());
        let m = meta("no frontmatter");
        assert_eq!(m.audience, vec!["mission", "local"]);
    }

    #[test]
    fn skill_delivery_parses_metadata() {
        let m = meta(
            "---\nname: a\nmetadata:\n  sandboxed:\n    audience: [coordinator]\n    scope: global\n---\n",
        );
        assert_eq!(m.audience, vec!["coordinator"]);
        assert_eq!(m.scope, SkillScope::Global);
        assert!(!m.targets_missions());
        let m = meta("---\nmetadata:\n  sandboxed:\n    audience: [Mission, local]\n---\n");
        assert!(m.targets_missions());
        assert_eq!(m.scope, SkillScope::OnDemand);
        let m = meta("---\nmetadata:\n  other: 1\n---\n");
        assert_eq!(m.audience, default_skill_audience());
    }
}
