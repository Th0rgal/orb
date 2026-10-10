//! Normalize native failure evidence without treating arbitrary exit codes as
//! permission to replay. In particular, a cancellation without an actor is not
//! a transport error, and authentication/policy failures win over retry hints.
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FailureKind {
    Transport,
    Authentication,
    ProviderPolicy,
    Configuration,
    Quota,
    Cancelled,
    Unknown,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct Failure {
    pub kind: FailureKind,
    pub summary: String,
    pub retry_after_seconds: Option<i64>,
}

pub(crate) fn classify(raw: &str) -> Failure {
    let lower = raw.to_ascii_lowercase();
    let kind = if [
        "cancelled by",
        "canceled by",
        "operator stop",
        "startup watchdog",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        FailureKind::Cancelled
    } else if [
        "content safety filter",
        "blocked by safety",
        "content_policy_violation",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        FailureKind::ProviderPolicy
    } else if [
        "unauthorized",
        "unauthenticated",
        "permission_denied",
        "invalid_grant",
        "oauth revoked",
        "login required",
        "sign in",
        "log in",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        FailureKind::Authentication
    } else if [
        "no such file or directory",
        "argument list too long",
        "unknown model",
        "model is not available",
        "unsupported model",
        "identity was not durably persisted",
        "invalid agent",
        "requires --effort",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        FailureKind::Configuration
    } else if crate::account_limits::is_usage_limit_message(raw) {
        FailureKind::Quota
    } else {
        FailureKind::Unknown
    };
    let mut failure = Failure {
        kind,
        summary: String::new(),
        retry_after_seconds: None,
    };
    if failure.kind == FailureKind::Unknown {
        // Only parse the native error object, never a code sample quoted in a
        // transcript. OpenCode wraps APIError data in name/data on some versions.
        if let Ok(value) = serde_json::from_str::<Value>(raw) {
            let data = value
                .get("data")
                .or_else(|| value.get("error").and_then(|e| e.get("data")))
                .unwrap_or(&value);
            let code = data["statusCode"].as_u64();
            if matches!(code, Some(401 | 403)) {
                failure.kind = FailureKind::Authentication;
            } else if data["isRetryable"] != false
                && matches!(code, Some(408 | 429 | 500 | 502 | 503 | 504 | 524 | 529))
            {
                failure.kind = FailureKind::Transport;
                failure.retry_after_seconds = data["responseHeaders"]
                    .as_object()
                    .and_then(|headers| {
                        headers
                            .iter()
                            .find(|(key, _)| key.eq_ignore_ascii_case("retry-after"))
                    })
                    .and_then(|(_, value)| value.as_str())
                    .and_then(|value| value.parse::<i64>().ok())
                    .filter(|seconds| *seconds >= 0);
            }
        }
        if failure.kind == FailureKind::Unknown
            && [
                "connection reset",
                "connection refused",
                "no route to host",
                "temporary failure in name resolution",
                "unexpected eof",
                "http 502",
                "http 503",
                "http 504",
                "http 524",
                "code 503",
                "code 529",
            ]
            .iter()
            .any(|s| lower.contains(s))
        {
            failure.kind = FailureKind::Transport;
        }
    }
    failure.summary = match failure.kind {
        FailureKind::Transport => "The inference connection failed temporarily.",
        FailureKind::Authentication => "Authentication failed. Reconnect the account or repair the node's scoped Core credentials before resuming.",
        FailureKind::ProviderPolicy => "The provider blocked the response. Review the request before resuming.",
        FailureKind::Configuration => "The node's CLI, model, or workspace configuration needs attention before resuming.",
        FailureKind::Quota => "The provider usage limit was reached.",
        FailureKind::Cancelled => "The run was stopped. Automatic recovery will not override that stop.",
        FailureKind::Unknown => "The run ended without a confirmed recoverable cause.",
    }.into();
    failure
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn opencode_gateway_error_preserves_retry_hint_without_html() {
        let failure = classify(
            r#"{"name":"APIError","data":{"isRetryable":true,"statusCode":502,"message":"Bad Gateway","responseHeaders":{"Retry-After":"60"},"responseBody":"<html>Host Error</html>"}}"#,
        );
        assert_eq!(failure.kind, FailureKind::Transport);
        assert_eq!(failure.retry_after_seconds, Some(60));
        assert!(!failure.summary.contains("html"));
    }
    #[test]
    fn hard_failures_and_unattributed_cancellation_are_not_transport_retries() {
        for (text, expected) in [
            (
                "Core refused scoped session (401 Unauthorized)",
                FailureKind::Authentication,
            ),
            (
                "blocked by content safety filters",
                FailureKind::ProviderPolicy,
            ),
            (
                "/usr/local/bin/codex-code-mode-host: No such file or directory",
                FailureKind::Configuration,
            ),
            (
                "cancelled by startup watchdog after HTTP 503",
                FailureKind::Cancelled,
            ),
            ("interrupted", FailureKind::Unknown),
        ] {
            assert_eq!(classify(text).kind, expected, "{text}");
        }
        assert_eq!(
            classify(r#"{"statusCode":502,"isRetryable":false}"#).kind,
            FailureKind::Unknown
        );
    }
}
