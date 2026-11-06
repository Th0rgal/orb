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

/// Provider HTTP/header timeout (15 minutes) injected into Orb-managed OpenCode
/// `provider.<id>.options.timeout` blocks.
///
/// Stock `@ai-sdk/openai-compatible` defaults to `300_000` ms (5 min), which
/// blind-aborted queued private GPU fleet requests (`ProviderHeaderTimeoutError`)
/// while Core was legitimately waiting for a serialized `dgx-spark` queue turn
/// (`PROXY_FLEET_SEMANTIC_FIRST_TOKEN_SECS`, default 600 s). Keeping OpenCode's
/// client timeout strictly above Core's pre-commit semantic + failover budget
/// ensures Core owns timeout, retry, and waterfall failover decisions.
pub const OPENCODE_PROXY_PROVIDER_TIMEOUT_MS: u64 = 900_000;

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
