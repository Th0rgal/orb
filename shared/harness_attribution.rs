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
/// `Co-authored-by: Codex` trailer on Codex before 0.164. Codex 0.164 ignores
/// the key with a startup warning, so Core no longer sends it.
pub const CODEX_CONFIG_OVERRIDE: &str = "commit_attribution=\"\"";

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
}
