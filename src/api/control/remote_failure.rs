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
    /// The startup watchdog stopped a job that stayed silent on every
    /// liveness signal. Nobody asked for the stop, so it is retried once.
    StartupStall,
    Unknown,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct Failure {
    pub kind: FailureKind,
    pub summary: String,
    pub retry_after_seconds: Option<i64>,
}

fn retry_after_seconds(value: &str, now: chrono::DateTime<chrono::Utc>) -> Option<i64> {
    let value = value.trim();
    if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) {
        // Preserve an oversized delay as a veto, never as a missing header
        // that would allow the scheduler to fall back to a short retry.
        return Some(value.parse::<i64>().unwrap_or(i64::MAX));
    }
    let date = chrono::DateTime::parse_from_rfc2822(value).ok()?;
    // Round up: truncating a fractional second would retry before the date.
    Some(
        date.signed_duration_since(now)
            .num_milliseconds()
            .saturating_add(999)
            .max(0)
            / 1000,
    )
}

/// SSE error code the `/v1` proxy ends a stalled stream with.
pub(crate) const PROXY_STREAM_STALL_CODE: &str = "upstream_stalled";

/// The turn ended on a proxy stream stall or stream error: transient, and
/// worth resuming quickly rather than after the generic transport backoff.
pub(crate) fn is_proxy_stream_interruption(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains(PROXY_STREAM_STALL_CODE) || lower.contains("upstream_stream_error")
}

/// True when the upstream provider rejected the node's egress IP or region
/// (for example Google's `FAILED_PRECONDITION (code 400): User location is not
/// supported for the API use` over a mis-geolocated OVH IPv6 range).
pub(crate) fn is_node_location_unsupported(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    [
        "user location is not supported",
        "unsupported country, region, or territory",
        "not available in your country",
        "not available in your region",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

pub(crate) fn classify(raw: &str) -> Failure {
    let lower = raw.to_ascii_lowercase();
    let location_unsupported = is_node_location_unsupported(raw);
    let kind = if lower.contains("startup watchdog") || lower.contains("startup_watchdog") {
        FailureKind::StartupStall
    } else if ["cancelled by", "canceled by", "operator stop"]
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
    } else if location_unsupported
        || [
            "no such file or directory",
            "cli is not installed",
            "cli not installed",
            "command not found",
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
        let mut retry_forbidden = false;
        // Only parse the native error object, never a code sample quoted in a
        // transcript. OpenCode wraps APIError data in name/data on some versions.
        if let Ok(value) = serde_json::from_str::<Value>(raw) {
            let data = value
                .get("data")
                .or_else(|| value.get("error").and_then(|e| e.get("data")))
                .unwrap_or(&value);
            let code = data["statusCode"].as_u64();
            retry_forbidden = data["isRetryable"] == false;
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
                    .and_then(|value| retry_after_seconds(value, chrono::Utc::now()));
            }
        }
        if !retry_forbidden
            && failure.kind == FailureKind::Unknown
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
                // The /v1 proxy's mid-stream stall / stream error events.
                PROXY_STREAM_STALL_CODE,
                "upstream_stream_error",
                crate::antigravity::IDLE_WAIT_INTERRUPTED_MARKER,
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
        FailureKind::Configuration if location_unsupported => "The provider rejected this node's egress IP or region. Choose Core or another machine, or route provider traffic over a supported egress IP on that node.",
        FailureKind::Configuration => "The node's CLI, model, or workspace configuration needs attention before resuming.",
        FailureKind::Quota => "The provider usage limit was reached.",
        FailureKind::Cancelled => "The run was stopped. Automatic recovery will not override that stop.",
        FailureKind::StartupStall => "The run stayed silent past the startup watchdog and was interrupted; it is resumed automatically once.",
        FailureKind::Unknown => "The run ended without a confirmed recoverable cause.",
    }.into();
    failure
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retry_after_accepts_http_dates_and_does_not_round_down() {
        let now = chrono::DateTime::parse_from_rfc3339("2015-10-21T07:27:00.500Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        assert_eq!(
            retry_after_seconds("Wed, 21 Oct 2015 07:28:00 GMT", now),
            Some(60)
        );
        assert_eq!(
            retry_after_seconds("Wed, 21 Oct 2015 07:26:00 GMT", now),
            Some(0)
        );
        assert_eq!(retry_after_seconds("60", now), Some(60));
        assert_eq!(retry_after_seconds("-1", now), None);
        assert_eq!(retry_after_seconds("invalid", now), None);
    }
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
    fn exhausted_429_chain_is_a_usage_limit_not_an_interrupted_connection() {
        // What OpenCode prints when every account of `google/gemini-4-argon`
        // (and its Antigravity equivalent) answered 429 and is parked.
        let failure = classify(
            r#"{"name":"APIError","data":{"isRetryable":true,"statusCode":429,"message":"You've hit your usage limit on every account configured for 'google/gemini-4-argon' (google usage limit). Try again at Oct 28, 2026 05:00 UTC.","responseHeaders":{"Retry-After":"30"}}}"#,
        );
        assert_eq!(failure.kind, FailureKind::Quota);
        // A plain cooldown 429 stays a transient.
        let failure = classify(
            r#"{"name":"APIError","data":{"isRetryable":true,"statusCode":429,"message":"All providers in chain 'x' are currently in cooldown or unconfigured"}}"#,
        );
        assert_eq!(failure.kind, FailureKind::Transport);
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
                FailureKind::StartupStall,
            ),
            (
                "Cancelled by startup_watchdog: No native activity",
                FailureKind::StartupStall,
            ),
            (
                "Cancelled by operator: stop requested",
                FailureKind::Cancelled,
            ),
            ("interrupted", FailureKind::Unknown),
            (
                &crate::antigravity::idle_wait_interrupted_message(1),
                FailureKind::Transport,
            ),
        ] {
            assert_eq!(classify(text).kind, expected, "{text}");
        }
        assert_eq!(
            classify(r#"{"statusCode":502,"isRetryable":false,"message":"HTTP 502"}"#).kind,
            FailureKind::Unknown
        );
    }

    #[test]
    fn proxy_stream_stall_is_transport() {
        // The exact shape a remote opencode job reported (mission c22d3f33).
        let raw = r#"command exited with Some(1). CLI error: {"data":{"message":"{\"message\":\"upstream stream stalled\",\"type\":\"server_error\",\"code\":\"upstream_stalled\"}"}}"#;
        assert_eq!(classify(raw).kind, FailureKind::Transport);
        assert!(is_proxy_stream_interruption(raw));
        assert!(!is_proxy_stream_interruption("http 503"));
    }

    #[test]
    fn provider_location_rejection_is_configuration_with_egress_guidance() {
        // Exact error reported by mission 4a2512c8-c945-4090-a08a-43883221cd36 on nimrud.
        let raw = "FAILED_PRECONDITION (code 400): User location is not supported for the API use.";
        let failure = classify(raw);
        assert_eq!(failure.kind, FailureKind::Configuration);
        assert!(is_node_location_unsupported(raw));
        assert!(failure.summary.contains("egress IP or region"));
    }
}
