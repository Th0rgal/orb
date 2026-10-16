//! Agent harnesses never stamp commits or pull requests with their own
//! co-author trailer or "generated with" footer, on any machine: Core,
//! remote nodes and Orb's local runs all apply these overrides at launch,
//! where they outrank profile and user configuration.
//!
//! Only Claude Code and Codex add attribution today; the other harnesses
//! (OpenCode, Gemini, Grok, Vibe, Antigravity) ship none.

/// Claude Code settings: empty commit/PR attribution (and the legacy
/// `includeCoAuthoredBy` switch for older CLIs).
pub fn claude_settings() -> serde_json::Value {
    serde_json::json!({
        "attribution": { "commit": "", "pr": "" },
        "includeCoAuthoredBy": false
    })
}

/// Force the attribution keys into a Claude settings object, overriding any
/// profile or user value.
pub fn apply_claude(settings: &mut serde_json::Value) {
    if let (Some(target), serde_json::Value::Object(forced)) =
        (settings.as_object_mut(), claude_settings())
    {
        target.extend(forced);
    }
}

/// Inline JSON for `claude --settings`.
pub fn claude_settings_arg() -> String {
    claude_settings().to_string()
}

/// Codex `-c` override: an empty `commit_attribution` disables the
/// `Co-authored-by: Codex` trailer.
pub const CODEX_CONFIG_OVERRIDE: &str = "commit_attribution=\"\"";

/// Pin `commit_attribution = ""` at the top level of a Codex config.toml,
/// replacing any value a profile or operator set. TOML top-level keys must
/// precede the first `[section]`, so the key is prepended.
pub fn apply_codex_config(config: &str) -> String {
    let mut in_prelude = true;
    let kept: Vec<&str> = config
        .lines()
        .filter(|line| {
            if line.trim_start().starts_with('[') {
                in_prelude = false;
            }
            !(in_prelude
                && line
                    .split('=')
                    .next()
                    .is_some_and(|key| key.trim() == "commit_attribution"))
        })
        .collect();
    let rest = kept.join("\n");
    format!(
        "commit_attribution = \"\"\n{}{}",
        if rest.is_empty() { "" } else { "\n" },
        rest
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_overrides_profile_attribution() {
        let mut settings = serde_json::json!({
            "attribution": { "commit": "Co-Authored-By: Claude", "pr": "x" },
            "includeCoAuthoredBy": true,
            "permissions": { "allow": ["Bash"] }
        });
        apply_claude(&mut settings);
        assert_eq!(settings["attribution"]["commit"], "");
        assert_eq!(settings["attribution"]["pr"], "");
        assert_eq!(settings["includeCoAuthoredBy"], false);
        assert_eq!(settings["permissions"]["allow"][0], "Bash");
    }

    #[test]
    fn codex_config_pins_empty_attribution_once() {
        let config = "model = \"gpt\"\ncommit_attribution = \"Me <me@x>\"\n\n[mcp_servers.a]\ncommit_attribution = \"kept in section\"\n";
        let out = apply_codex_config(config);
        let prelude: Vec<_> = out.lines().take_while(|l| !l.starts_with('[')).collect();
        assert_eq!(
            prelude
                .iter()
                .filter(|l| l.starts_with("commit_attribution"))
                .count(),
            1
        );
        assert!(out.starts_with("commit_attribution = \"\"\n"));
        assert!(out.contains("model = \"gpt\""));
        assert!(
            out.contains("kept in section"),
            "section keys are untouched"
        );
        assert_eq!(apply_codex_config(""), "commit_attribution = \"\"\n");
    }
}
