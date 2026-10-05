//! Read-only account projection from CLIProxyAPI. Never exchange or refresh
//! tokens here: the proxy's files remain the authoritative login store.
use crate::ai_providers::{AIProvider, AIProviderStore, OAuthCredentials, ProviderType};
use serde_json::Value;
use std::path::{Path, PathBuf};

pub(crate) struct ProxyAccount {
    pub file: String,
    pub original_id: Option<uuid::Uuid>,
    pub provider: ProviderType,
    pub identity: String,
    pub oauth: OAuthCredentials,
    pub disabled: bool,
}

pub(crate) fn auth_dir() -> Option<PathBuf> {
    std::env::var("CLI_PROXY_AUTH_DIR")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
}

pub(crate) fn parse_account(file: &str, value: &Value) -> Option<ProxyAccount> {
    // Only plain filenames can become a stored binding.
    if Path::new(file).file_name()?.to_str()? != file || !file.ends_with(".json") {
        return None;
    }
    let provider = match value.get("type")?.as_str()? {
        "claude" => ProviderType::Anthropic,
        "codex" => ProviderType::OpenAI,
        "xai" => ProviderType::Xai,
        "kimi" => ProviderType::Kimi,
        _ => return None,
    };
    let access_token = value.get("access_token")?.as_str()?.to_string();
    let refresh_token = value.get("refresh_token")?.as_str()?.to_string();
    if access_token.is_empty() || refresh_token.is_empty() {
        return None;
    }
    let expiry = value.get("expired").or_else(|| value.get("expires_at"))?;
    let expires_at = expiry
        .as_i64()
        .map(|n| if n < 100_000_000_000 { n * 1000 } else { n })
        .or_else(|| {
            chrono::DateTime::parse_from_rfc3339(expiry.as_str()?)
                .ok()
                .map(|v| v.timestamp_millis())
        })?;
    let identity = value
        .get("email")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .or_else(|| value.get("sub").and_then(Value::as_str))
        .unwrap_or(file)
        .to_string();
    Some(ProxyAccount {
        file: file.to_string(),
        original_id: value
            .get("sandboxed_provider_id")
            .and_then(Value::as_str)
            .and_then(|id| uuid::Uuid::parse_str(id).ok()),
        provider,
        identity,
        oauth: OAuthCredentials {
            access_token,
            refresh_token,
            expires_at,
        },
        disabled: value
            .get("disabled")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

pub(crate) fn accounts_in(dir: &Path) -> Vec<ProxyAccount> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_str()?.to_string();
            if entry.file_type().ok()?.is_symlink() {
                return None;
            }
            let value = serde_json::from_slice::<Value>(&std::fs::read(entry.path()).ok()?).ok()?;
            parse_account(&name, &value)
        })
        .collect()
}

pub(crate) fn account_for(provider: &AIProvider) -> Option<ProxyAccount> {
    let accounts = accounts_in(&auth_dir()?);
    accounts.into_iter().find(|a| {
        a.provider == provider.provider_type
            && ((provider.cli_proxy_auth_file.is_none() && a.original_id == Some(provider.id))
                || provider.cli_proxy_auth_file.as_deref() == Some(a.file.as_str())
                || (provider.cli_proxy_auth_file.is_none()
                    && provider
                        .account_email
                        .as_deref()
                        .is_some_and(|email| email.eq_ignore_ascii_case(&a.identity))))
    })
}

pub(crate) fn needs_reconnect(provider: &AIProvider) -> bool {
    account_for(provider).is_none_or(|a| {
        a.disabled
            || a.oauth.expires_at + chrono::Duration::hours(24).num_milliseconds()
                < chrono::Utc::now().timestamp_millis()
    })
}

pub(crate) fn spawn_projection_loop(store: std::sync::Arc<AIProviderStore>) {
    tokio::spawn(async move {
        loop {
            reconcile(&store).await;
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        }
    });
}

pub(crate) async fn reconcile(store: &AIProviderStore) {
    if !super::oauth_owner::management_enabled() {
        return;
    }
    let Some(dir) = auth_dir() else {
        return;
    };
    reconcile_from(store, &dir).await;
}

async fn reconcile_from(store: &AIProviderStore, dir: &Path) {
    static GATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _guard = GATE.lock().await;
    for a in accounts_in(dir) {
        let rows = store.list().await;
        let old = rows.into_iter().find(|p| {
            p.provider_type == a.provider
                && ((p.id == a.original_id.unwrap_or(uuid::Uuid::nil())
                    && p.cli_proxy_auth_file.is_none())
                    || p.cli_proxy_auth_file.as_deref() == Some(a.file.as_str())
                    || p.account_email
                        .as_deref()
                        .is_some_and(|email| email.eq_ignore_ascii_case(&a.identity)))
        });
        if a.disabled && old.is_none() {
            continue;
        }
        let mut p = old.clone().unwrap_or_else(|| {
            AIProvider::new(
                a.provider,
                format!("{} ({})", a.provider.display_name(), a.identity),
            )
        });
        let changed = p.cli_proxy_auth_file.as_deref() != Some(a.file.as_str())
            || p.oauth.as_ref().is_none_or(|o| {
                o.access_token != a.oauth.access_token
                    || o.refresh_token != a.oauth.refresh_token
                    || o.expires_at != a.oauth.expires_at
            });
        if !changed {
            continue;
        }
        p.cli_proxy_auth_file = Some(a.file);
        p.account_email = Some(a.identity);
        p.oauth = Some(a.oauth);
        p.rejected_oauth_refresh_fingerprint = None;
        if p.use_for_backends.is_none() {
            p.use_for_backends = Some(super::ai_providers::default_backends_for_provider(
                a.provider,
            ));
        }
        if old.is_some() {
            store.update(p.id, p).await;
        } else {
            store.add(p).await;
        }
    }
}

/// Keep UI enable/delete actions consistent with the authoritative proxy store.
pub(crate) async fn set_enabled(
    provider: &AIProvider,
    enabled: bool,
) -> Result<(), (axum::http::StatusCode, String)> {
    if !super::oauth_owner::management_enabled() {
        return Ok(());
    }
    let Some(account) = account_for(provider) else {
        return Ok(());
    };
    super::cli_proxy_login::ManagementClient::configured()?
        .request(
            reqwest::Method::PATCH,
            "/auth-files/status",
            Some(serde_json::json!({"name":account.file,"disabled":!enabled})),
        )
        .await?;
    Ok(())
}
pub(crate) async fn delete(provider: &AIProvider) -> Result<(), (axum::http::StatusCode, String)> {
    if !super::oauth_owner::management_enabled() {
        return Ok(());
    }
    let Some(account) = account_for(provider) else {
        return Ok(());
    };
    let query: String = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("name", &account.file)
        .finish();
    super::cli_proxy_login::ManagementClient::configured()?
        .request(
            reqwest::Method::DELETE,
            &format!("/auth-files?{query}"),
            None,
        )
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn reconnect_preserves_identity_settings_and_independent_api_key() {
        let dir = tempfile::tempdir().unwrap();
        let store = AIProviderStore::new(dir.path().join("providers.json")).await;
        let mut row = AIProvider::new(ProviderType::Anthropic, "Ben".into());
        row.account_email = Some("ben@example.com".into());
        row.api_key = Some("independent-platform-key".into());
        row.label = Some("Work".into());
        row.priority = 7;
        row.enabled = false;
        row.rejected_oauth_refresh_fingerprint = Some("old-rejection".into());
        let id = store.add(row).await;
        std::fs::write(
            dir.path().join("claude-ben.json"),
            serde_json::json!({
                "type":"claude","email":"ben@example.com","access_token":"new-access",
                "refresh_token":"new-refresh","expired":"2099-01-01T00:00:00Z"
            })
            .to_string(),
        )
        .unwrap();
        reconcile_from(&store, dir.path()).await;
        reconcile_from(&store, dir.path()).await;
        assert_eq!(store.list().await.len(), 1);
        let p = store.get(id).await.unwrap();
        assert_eq!(p.name, "Ben");
        assert_eq!(p.priority, 7);
        assert!(!p.enabled);
        assert_eq!(p.api_key.as_deref(), Some("independent-platform-key"));
        assert_eq!(p.cli_proxy_auth_file.as_deref(), Some("claude-ben.json"));
        assert!(p.rejected_oauth_refresh_fingerprint.is_none());
    }
    #[tokio::test]
    async fn identityless_import_keeps_original_uuid_and_concurrent_scans_do_not_duplicate() {
        let dir = tempfile::tempdir().unwrap();
        let store = AIProviderStore::new(dir.path().join("providers.json")).await;
        let row = AIProvider::new(ProviderType::Kimi, "Personal Kimi".into());
        let id = store.add(row).await;
        std::fs::write(dir.path().join("kimi-import.json"), serde_json::json!({
            "type":"kimi","sandboxed_provider_id":id,"access_token":"a","refresh_token":"r","expired":"2099-01-01T00:00:00Z"
        }).to_string()).unwrap();
        tokio::join!(
            reconcile_from(&store, dir.path()),
            reconcile_from(&store, dir.path())
        );
        assert_eq!(store.list().await.len(), 1);
        assert_eq!(
            store.get(id).await.unwrap().cli_proxy_auth_file.as_deref(),
            Some("kimi-import.json")
        );
    }

    #[test]
    fn rejects_path_traversal_and_supports_kimi_epoch_expiry() {
        let v = serde_json::json!({"type":"kimi","access_token":"a","refresh_token":"r","expires_at":2000000000});
        assert!(parse_account("../other.json", &v).is_none());
        assert_eq!(
            parse_account("kimi-user.json", &v)
                .unwrap()
                .oauth
                .expires_at,
            2000000000000
        );
    }
}
