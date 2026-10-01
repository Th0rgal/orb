use crate::project_context::Manifest;
use std::path::Path;
pub fn has_mentions(text: &str) -> bool {
    regex::Regex::new(r#"(^|[\s(\[{])@(?:\")?(?:context|__orb_path__)(?:[/\s\"),.;!?]|$)"#)
        .unwrap()
        .is_match(text)
}
pub fn resolve(text: &str, root: &Path, manifest: &Manifest) -> Result<String, String> {
    let pattern =
        regex::Regex::new(r#"(^|[\s(\[{])@(?:\"((?:context|__orb_path__)(?:/[^\"]*)?)\"|((?:context|__orb_path__)(?:/[^\s)\]},;]*)?))"#)
            .unwrap();
    let mut result = String::new();
    let mut last = 0;
    for captures in pattern.captures_iter(text) {
        let whole = captures.get(0).unwrap();
        if whole.end() < text.len()
            && text[whole.end()..]
                .chars()
                .next()
                .is_some_and(|c| c.is_alphanumeric() || c == '_')
        {
            continue;
        }
        let raw = captures
            .get(2)
            .or_else(|| captures.get(3))
            .unwrap()
            .as_str();
        let value = if captures.get(2).is_some() {
            raw
        } else {
            raw.trim_end_matches(['.', ',', ';', ':', '!', '?'])
        };
        let relative = if let Some(path) = value.strip_prefix("__orb_path__/") {
            let path = path.trim_end_matches('/');
            crate::project_context::valid_path(path)?;
            if !manifest.entries.contains_key(path) {
                return Err(format!("Context path does not exist: {path}"));
            }
            path.to_owned()
        } else {
            crate::project_context::resolve_reference(value, |path| {
                manifest.entries.contains_key(path)
            })?
        };
        result.push_str(&text[last..whole.start()]);
        result.push_str(&captures[1]);
        result.push_str(
            &serde_json::to_string(&root.join(relative).to_string_lossy())
                .map_err(|e| e.to_string())?,
        );
        result.push_str(&raw[value.len()..]);
        last = whole.end();
    }
    result.push_str(&text[last..]);
    Ok(result)
}
pub async fn remote(
    state: &super::routes::AppState,
    project: &str,
    node: &crate::remote_node::RemoteNodeConfig,
    text: &str,
) -> Result<(String, String), String> {
    if !super::projects_overview::is_plain_key(project) {
        return Err("Invalid context project".into());
    }
    let root = super::mission_payload::project_files_root(&state.config.working_dir, project);
    let metadata = state
        .config
        .working_dir
        .join(".sandboxed-sh/project-context-state")
        .join(project);
    let store = crate::project_context::Store::new(root, metadata);
    let manifest = store.manifest()?;
    let skill_path = |path: &str| {
        let parts: Vec<_> = path.split('/').collect();
        parts.len() == 3 && parts[0] == "skills" && parts[2] == "SKILL.md"
    };
    // Skill-free projects retain the old launch path. Historical skill files
    // still require a replica refresh so deleting the last skill cleans links.
    if !has_mentions(text)
        && !manifest.entries.keys().any(|path| skill_path(path))
        && !store
            .history()?
            .iter()
            .any(|change| skill_path(&change.path))
    {
        return Ok((text.into(), String::new()));
    }
    let endpoint = super::mission_runner::public_api_base_url_from_env()
        .ok_or("Remote context requires SANDBOXED_PUBLIC_URL")?;
    let token = super::context_auth::issue(&state.config, project, &node.id)?;
    let node_token = std::env::var(&node.token_env).map_err(|_| "Node credentials unavailable")?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .post(format!(
            "{}/project-context/prepare",
            node.base_url.trim_end_matches('/')
        ))
        .bearer_auth(node_token)
        .json(&crate::node::project_context::Request {
            endpoint,
            token,
            project: project.into(),
        })
        .send()
        .await
        .map_err(|_| "Context preparation could not reach the node")?;
    if !response.status().is_success() {
        return Err(format!("Node context preparation failed (HTTP {}); update the node if this capability is missing",response.status().as_u16()));
    }
    #[derive(serde::Deserialize)]
    struct Prepared {
        root: std::path::PathBuf,
        manifest: Manifest,
    }
    let prepared: Prepared = response.json().await.map_err(|e| e.to_string())?;
    Ok((
        resolve(text, &prepared.root, &prepared.manifest)?,
        prepared.root.to_string_lossy().into_owned(),
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn context_reference_preserves_real_context_directory() {
        let mut manifest = Manifest::default();
        manifest.entries.insert(
            "context/AGENTS.md".into(),
            crate::project_context::Entry {
                hash: None,
                directory: false,
                revision: 1,
                size: 12,
            },
        );
        assert_eq!(
            resolve("Read @context/AGENTS.md", Path::new("/project"), &manifest).unwrap(),
            "Read \"/project/context/AGENTS.md\""
        );
    }
    #[test]
    fn project_skills_and_context_references_resolve_to_original_tree() {
        let mut manifest = Manifest::default();
        for path in [
            "skills",
            "skills/review",
            "skills/review/SKILL.md",
            "skills/review/references/checklist.md",
            "Context",
            "Context/architecture.md",
        ] {
            manifest.entries.insert(
                path.into(),
                crate::project_context::Entry {
                    hash: None,
                    directory: !path.ends_with(".md"),
                    revision: 1,
                    size: 1,
                },
            );
        }
        assert_eq!(
            resolve(
                "Edit @context/skills/review/SKILL.md and read @context/Context",
                Path::new("/synced/source"),
                &manifest
            )
            .unwrap(),
            "Edit \"/synced/source/skills/review/SKILL.md\" and read \"/synced/source/Context\""
        );
    }

    #[test]
    fn literal_attachment_does_not_fall_back_to_namespace_alias() {
        let mut manifest = Manifest::default();
        for path in ["notes.md", "context/notes.md", "context/context/notes.md"] {
            manifest.entries.insert(
                path.into(),
                crate::project_context::Entry {
                    hash: None,
                    directory: false,
                    revision: 1,
                    size: 1,
                },
            );
        }
        let text = "Read @\"__orb_path__/context/notes.md\".";
        assert!(has_mentions(text));
        assert_eq!(
            resolve(text, Path::new("/project"), &manifest).unwrap(),
            "Read \"/project/context/notes.md\"."
        );
        assert_eq!(
            resolve(
                "[@\"__orb_path__/context/notes.md\"]",
                Path::new("/project"),
                &manifest
            )
            .unwrap(),
            "[\"/project/context/notes.md\"]"
        );
        manifest.entries.remove("context/notes.md");
        assert!(resolve(text, Path::new("/project"), &manifest).is_err());
    }

    #[test]
    fn resolution_is_bound_to_context_tokens() {
        let m = Manifest::default();
        assert_eq!(
            resolve("Read @context.", Path::new("/srv/context"), &m).unwrap(),
            "Read \"/srv/context/\"."
        );
        assert_eq!(
            resolve("a@context.test", Path::new("/x"), &m).unwrap(),
            "a@context.test"
        );
        assert!(resolve("@context/missing", Path::new("/x"), &m).is_err());
        assert!(resolve("@context/../escape", Path::new("/x"), &m).is_err());
    }
}
