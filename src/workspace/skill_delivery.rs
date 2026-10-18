//! Library skill delivery: which Library skills a mission receives, and the
//! deterministic archive that carries them to remote nodes.
//!
//! One resolution rule for every execution path (local host/container
//! missions and remote node jobs):
//!
//! ```text
//! mission skills = base ∪ globals ∪ project
//!   base    = workspace.skills if non-empty,
//!             else (default host workspace) every Library skill whose
//!             audience includes `mission`, else nothing
//!   globals = Library skills with scope=global and audience ∋ mission
//!   project = the project's Library skill list (projects.db)
//! ```
//!
//! Names absent from the Library are reported as `missing` and skipped.

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;
use sha2::{Digest, Sha256};

use super::{
    collect_skill_contents, ensure_claudecode_skill_frontmatter, SkillContent, Workspace,
    WorkspaceType, DEFAULT_WORKSPACE_ID,
};
use crate::library::env_crypto::strip_encrypted_tags;
use crate::library::{LibraryStore, SkillScope, SkillSummary, SKILL_AUDIENCE_MISSION};

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SkillDeliveryReason {
    Base,
    Global,
    Project,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct DeliveredSkill {
    pub name: String,
    pub reasons: Vec<SkillDeliveryReason>,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct SkillDeliveryPlan {
    pub skills: Vec<DeliveredSkill>,
    pub missing: Vec<String>,
}

impl SkillDeliveryPlan {
    pub fn names(&self) -> Vec<String> {
        self.skills.iter().map(|s| s.name.clone()).collect()
    }
}

fn targets_missions(skill: &SkillSummary) -> bool {
    skill.audience.iter().any(|a| a == SKILL_AUDIENCE_MISSION)
}

/// Pure resolution over a Library listing. Order: base (as configured or
/// Library order), then globals (Library order), then project (as listed).
pub fn resolve_skill_delivery(
    workspace_skills: &[String],
    default_host: bool,
    library: &[SkillSummary],
    project_skills: &[String],
) -> SkillDeliveryPlan {
    let known: HashMap<&str, &SkillSummary> =
        library.iter().map(|s| (s.name.as_str(), s)).collect();
    let mut plan = SkillDeliveryPlan::default();
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut add = |plan: &mut SkillDeliveryPlan, name: &str, reason: SkillDeliveryReason| {
        if !known.contains_key(name) {
            if !plan.missing.iter().any(|m| m == name) {
                plan.missing.push(name.to_string());
            }
            return;
        }
        match index.get(name) {
            Some(&i) => {
                if !plan.skills[i].reasons.contains(&reason) {
                    plan.skills[i].reasons.push(reason);
                }
            }
            None => {
                index.insert(name.to_string(), plan.skills.len());
                plan.skills.push(DeliveredSkill {
                    name: name.to_string(),
                    reasons: vec![reason],
                });
            }
        }
    };
    if !workspace_skills.is_empty() {
        for name in workspace_skills {
            add(&mut plan, name, SkillDeliveryReason::Base);
        }
    } else if default_host {
        for skill in library.iter().filter(|s| targets_missions(s)) {
            add(&mut plan, &skill.name, SkillDeliveryReason::Base);
        }
    }
    for skill in library
        .iter()
        .filter(|s| s.scope == SkillScope::Global && targets_missions(s))
    {
        add(&mut plan, &skill.name, SkillDeliveryReason::Global);
    }
    for name in project_skills {
        add(&mut plan, name, SkillDeliveryReason::Project);
    }
    plan
}

pub fn is_default_host(workspace: &Workspace) -> bool {
    workspace.id == DEFAULT_WORKSPACE_ID && workspace.workspace_type == WorkspaceType::Host
}

/// Resolve the delivery plan for a workspace (+ optional project skill list).
pub async fn resolve_for_workspace(
    workspace_skills: &[String],
    default_host: bool,
    library: &LibraryStore,
    project_skills: &[String],
) -> anyhow::Result<SkillDeliveryPlan> {
    let listing = library.list_skills().await?;
    let plan = resolve_skill_delivery(workspace_skills, default_host, &listing, project_skills);
    if !plan.missing.is_empty() {
        tracing::warn!(missing = ?plan.missing, "Selected skills are not in the Library; skipping");
    }
    Ok(plan)
}

/// Load the plan's skills from the Library (missing ones are skipped).
pub async fn load_skill_contents(
    plan: &SkillDeliveryPlan,
    context: &str,
    library: &LibraryStore,
) -> Vec<SkillContent> {
    collect_skill_contents(&plan.names(), context, library).await
}

/// Files each skill would get in a native skill directory, exactly as the
/// local native writer normalizes them (frontmatter + stripped secrets).
pub fn native_skill_files(skills: &[SkillContent]) -> BTreeMap<String, Vec<u8>> {
    let mut out = BTreeMap::new();
    for skill in skills {
        if crate::project_context::valid_path(&skill.name).is_err() || skill.name.contains('/') {
            tracing::warn!(skill = %skill.name, "Invalid Library skill name; skipping");
            continue;
        }
        let content = ensure_claudecode_skill_frontmatter(
            &skill.content,
            &skill.name,
            skill.description.as_deref(),
        );
        let mut files = BTreeMap::new();
        files.insert(
            format!("skills/{}/SKILL.md", skill.name),
            strip_encrypted_tags(&content).into_bytes(),
        );
        let mut ok = true;
        for (path, content) in &skill.files {
            if crate::project_context::valid_path(path).is_err() {
                ok = false;
                break;
            }
            files.insert(
                format!("skills/{}/{}", skill.name, path),
                strip_encrypted_tags(content).into_bytes(),
            );
        }
        if ok {
            out.extend(files);
        } else {
            tracing::warn!(skill = %skill.name, "Library skill has an invalid file path; skipping");
        }
    }
    out
}

fn octal(field: &mut [u8], value: u64) {
    let width = field.len() - 1;
    let text = format!("{value:0width$o}");
    field[..width].copy_from_slice(&text.as_bytes()[text.len() - width..]);
    field[width] = 0;
}

fn tar_header(path: &str, size: u64) -> anyhow::Result<[u8; 512]> {
    let mut header = [0u8; 512];
    let bytes = path.as_bytes();
    if bytes.len() <= 100 {
        header[..bytes.len()].copy_from_slice(bytes);
    } else {
        // ustar: split at a '/' so that prefix ≤ 155 and name ≤ 100.
        let split = bytes
            .iter()
            .enumerate()
            .filter(|(i, b)| **b == b'/' && *i <= 155 && bytes.len() - i - 1 <= 100)
            .map(|(i, _)| i)
            .next()
            .ok_or_else(|| anyhow::anyhow!("Skill file path too long for archive: {path}"))?;
        header[..bytes.len() - split - 1].copy_from_slice(&bytes[split + 1..]);
        header[345..345 + split].copy_from_slice(&bytes[..split]);
    }
    octal(&mut header[100..108], 0o644);
    octal(&mut header[108..116], 0);
    octal(&mut header[116..124], 0);
    anyhow::ensure!(size < 0o77777777777, "Skill file too large");
    octal(&mut header[124..136], size);
    octal(&mut header[136..148], 0);
    header[156] = b'0';
    header[257..263].copy_from_slice(b"ustar\0");
    header[263..265].copy_from_slice(b"00");
    header[148..156].copy_from_slice(b"        ");
    let sum: u32 = header.iter().map(|b| *b as u32).sum();
    let text = format!("{sum:06o}\0 ");
    header[148..156].copy_from_slice(text.as_bytes());
    Ok(header)
}

/// Deterministic tar.gz (sorted entries, zero mtime/uid/gid, fixed gzip
/// header) of `skills/<name>/...`. Returns the archive and its sha256.
pub fn build_skill_tarball(skills: &[SkillContent]) -> anyhow::Result<(Vec<u8>, String)> {
    use std::io::Write;
    let files = native_skill_files(skills);
    let mut tar = Vec::new();
    for (path, data) in &files {
        tar.extend_from_slice(&tar_header(path, data.len() as u64)?);
        tar.extend_from_slice(data);
        let pad = (512 - data.len() % 512) % 512;
        tar.extend_from_slice(&vec![0u8; pad]);
    }
    tar.extend_from_slice(&[0u8; 1024]);
    let mut encoder = flate2::GzBuilder::new()
        .mtime(0)
        .operating_system(255)
        .write(Vec::new(), flate2::Compression::default());
    encoder.write_all(&tar)?;
    let archive = encoder.finish()?;
    let sha = hex::encode(Sha256::digest(&archive));
    Ok((archive, sha))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::SkillSource;

    fn lib(name: &str, audience: &[&str], scope: SkillScope) -> SkillSummary {
        SkillSummary {
            name: name.into(),
            description: None,
            path: format!("skill/{name}"),
            source: SkillSource::Local,
            setup_commands: Vec::new(),
            audience: audience.iter().map(|s| s.to_string()).collect(),
            scope,
            line_count: 1,
        }
    }

    fn library() -> Vec<SkillSummary> {
        vec![
            lib("alpha", &["mission", "local"], SkillScope::OnDemand),
            lib("coord", &["coordinator"], SkillScope::OnDemand),
            lib("coord-global", &["coordinator"], SkillScope::Global),
            lib("glob", &["mission"], SkillScope::Global),
            lib("zeta", &["mission"], SkillScope::OnDemand),
        ]
    }

    fn names(plan: &SkillDeliveryPlan) -> Vec<&str> {
        plan.skills.iter().map(|s| s.name.as_str()).collect()
    }

    #[test]
    fn skill_delivery_explicit_workspace_list_plus_globals_and_project() {
        let plan = resolve_skill_delivery(
            &["zeta".into(), "ghost".into(), "glob".into()],
            true,
            &library(),
            &["alpha".into(), "zeta".into(), "nope".into()],
        );
        assert_eq!(names(&plan), vec!["zeta", "glob", "alpha"]);
        assert_eq!(
            plan.skills[0].reasons,
            vec![SkillDeliveryReason::Base, SkillDeliveryReason::Project]
        );
        assert_eq!(
            plan.skills[1].reasons,
            vec![SkillDeliveryReason::Base, SkillDeliveryReason::Global]
        );
        assert_eq!(plan.missing, vec!["ghost", "nope"]);
    }

    #[test]
    fn skill_delivery_default_host_filters_coordinator_skills() {
        let plan = resolve_skill_delivery(&[], true, &library(), &[]);
        assert_eq!(names(&plan), vec!["alpha", "glob", "zeta"]);
        assert!(plan.missing.is_empty());
    }

    #[test]
    fn skill_delivery_other_workspace_gets_globals_and_project_only() {
        let plan = resolve_skill_delivery(&[], false, &library(), &[]);
        assert_eq!(names(&plan), vec!["glob"]);
        assert_eq!(plan.skills[0].reasons, vec![SkillDeliveryReason::Global]);
        let plan = resolve_skill_delivery(&[], false, &library(), &["coord".into()]);
        // An explicit project selection wins over audience.
        assert_eq!(names(&plan), vec!["glob", "coord"]);
        let plan = resolve_skill_delivery(&[], false, &[], &["x".into()]);
        assert!(plan.skills.is_empty());
        assert_eq!(plan.missing, vec!["x"]);
    }

    fn content(name: &str, body: &str) -> SkillContent {
        SkillContent {
            name: name.into(),
            description: Some("d".into()),
            content: body.into(),
            files: vec![(
                "references/a.md".into(),
                "x <encrypted>sek</encrypted>".into(),
            )],
        }
    }

    fn untar(archive: &[u8]) -> BTreeMap<String, String> {
        use std::io::Read;
        let mut tar = Vec::new();
        flate2::read::GzDecoder::new(archive)
            .read_to_end(&mut tar)
            .unwrap();
        let mut out = BTreeMap::new();
        let mut offset = 0;
        while offset + 512 <= tar.len() && tar[offset] != 0 {
            let h = &tar[offset..offset + 512];
            let name =
                String::from_utf8(h[..100].split(|b| *b == 0).next().unwrap().to_vec()).unwrap();
            let size_text = std::str::from_utf8(&h[124..135]).unwrap();
            let size = usize::from_str_radix(size_text, 8).unwrap();
            assert_eq!(&h[257..263], b"ustar\0");
            let data = &tar[offset + 512..offset + 512 + size];
            out.insert(name, String::from_utf8(data.to_vec()).unwrap());
            offset += 512 + size.div_ceil(512) * 512;
        }
        out
    }

    #[test]
    fn skill_tarball_is_deterministic_and_strips_secrets() {
        let a = build_skill_tarball(&[
            content(
                "beta",
                "---\ndescription: d\n---\nuse <encrypted v=\"1\">tok</encrypted>",
            ),
            content("alpha", "plain"),
        ])
        .unwrap();
        let b = build_skill_tarball(&[
            content("alpha", "plain"),
            content(
                "beta",
                "---\ndescription: d\n---\nuse <encrypted v=\"1\">tok</encrypted>",
            ),
        ])
        .unwrap();
        assert_eq!(a, b);
        assert_eq!(a.1.len(), 64);
        let files = untar(&a.0);
        assert_eq!(
            files.keys().collect::<Vec<_>>(),
            vec![
                "skills/alpha/SKILL.md",
                "skills/alpha/references/a.md",
                "skills/beta/SKILL.md",
                "skills/beta/references/a.md"
            ]
        );
        let beta = &files["skills/beta/SKILL.md"];
        assert!(beta.contains("name: beta"), "{beta}");
        assert!(beta.contains("use tok"), "{beta}");
        assert!(!beta.contains("encrypted"), "{beta}");
        assert_eq!(files["skills/beta/references/a.md"], "x sek");
        assert!(files["skills/alpha/SKILL.md"].starts_with("---\n"));
    }

    #[test]
    fn skill_tarball_long_paths_use_ustar_prefix() {
        let mut skill = content("alpha", "x");
        let long = format!("{}/{}.md", "d".repeat(60), "f".repeat(60));
        skill.files = vec![(long.clone(), "y".into())];
        let (archive, _) = build_skill_tarball(&[skill]).unwrap();
        assert!(!archive.is_empty());
    }
}
