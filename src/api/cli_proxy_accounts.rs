//! Read-only account projection from CLIProxyAPI. Never exchange or refresh
//! tokens here: the proxy's files remain the authoritative login store.
use crate::ai_providers::{AIProvider, AIProviderStore, OAuthCredentials, ProviderType};
use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub(crate) struct ProxyAccount {
    pub file: String,
    pub original_id: Option<uuid::Uuid>,
    pub provider: ProviderType,
    pub identity: String,
    pub oauth: OAuthCredentials,
    pub disabled: bool,
    pub prefix: Option<String>,
    pub subscription_active: bool,
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
        "antigravity" => ProviderType::Antigravity,
        "meta" if value.get("auth_kind").and_then(Value::as_str) == Some("oauth") => {
            ProviderType::MuseCode
        }
        _ => return None,
    };
    let access_token = value.get("access_token")?.as_str()?.to_string();
    let refresh_token = value
        .get(if provider == ProviderType::MuseCode {
            "dca_token"
        } else {
            "refresh_token"
        })?
        .as_str()?
        .to_string();
    if access_token.is_empty() || refresh_token.is_empty() {
        return None;
    }
    let unknown_muse_expiry = Value::from(i64::MAX);
    // Minted Muse keys have no advertised expiration. Do not invent a refresh
    // deadline: subscription state and the authoritative DCA receipt gate use.
    let expiry = if provider == ProviderType::MuseCode {
        value
            .get("dca_expires_at")
            .filter(|v| v.as_i64().is_some_and(|n| n > 0))
            .or_else(|| {
                value
                    .get("dca_expired")
                    .filter(|v| v.as_str().is_some_and(|s| !s.is_empty()))
            })
            .unwrap_or(&unknown_muse_expiry)
    } else {
        value.get("expired").or_else(|| value.get("expires_at"))?
    };
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
        prefix: value
            .get("prefix")
            .and_then(Value::as_str)
            .map(str::to_string),
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
        subscription_active: provider != ProviderType::MuseCode
            || value.get("is_subs_active").and_then(Value::as_bool) == Some(true),
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

fn account_needs_reconnect(a: &ProxyAccount) -> bool {
    a.disabled
        || !a.subscription_active
        || (a.provider == ProviderType::MuseCode && a.prefix.as_deref() != Some("muse-code"))
        || (a.provider == ProviderType::Antigravity && a.prefix.as_deref() != Some("antigravity"))
        || a.oauth
            .expires_at
            .saturating_add(chrono::Duration::hours(24).num_milliseconds())
            < chrono::Utc::now().timestamp_millis()
}

pub(crate) fn needs_reconnect(provider: &AIProvider) -> bool {
    account_for(provider).is_none_or(|a| account_needs_reconnect(&a))
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
        let old = rows
            .iter()
            .find(|p| {
                p.provider_type == a.provider
                    && ((p.id == a.original_id.unwrap_or(uuid::Uuid::nil())
                        && p.cli_proxy_auth_file.is_none())
                        || p.cli_proxy_auth_file.as_deref() == Some(a.file.as_str())
                        || (p.cli_proxy_auth_file.is_none()
                            && p.account_email
                                .as_deref()
                                .is_some_and(|email| email.eq_ignore_ascii_case(&a.identity))))
            })
            .cloned();
        // A completed UI reconnect can replace the proxy filename. Do not
        // resurrect retired imports or rebind a row from an older duplicate.
        if old.is_none()
            && rows.iter().any(|p| {
                p.provider_type == a.provider
                    && (a.original_id == Some(p.id)
                        || p.account_email
                            .as_deref()
                            .is_some_and(|email| email.eq_ignore_ascii_case(&a.identity)))
            })
        {
            continue;
        }
        // Identityless device files need a UI session or migration row ID to
        // establish their binding, rather than creating a duplicate mid-login.
        if old.is_none()
            && a.provider == ProviderType::Kimi
            && a.identity == a.file
            && a.original_id.is_none()
        {
            continue;
        }
        let unusable = a.disabled
            || !a.subscription_active
            || a.oauth
                .expires_at
                .saturating_add(chrono::Duration::hours(24).num_milliseconds())
                < chrono::Utc::now().timestamp_millis();
        // Preserve healthy legacy sources until the one-time migration replaces
        // a stale/disabled proxy login. Never erase the import source at startup.
        if unusable && old.as_ref().is_none_or(|p| p.cli_proxy_auth_file.is_none()) {
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
        p.account_email = (a.identity != a.file).then_some(a.identity);
        p.cli_proxy_auth_file = Some(a.file);
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

/// Attach the credential selected by a completed login before general scans.
pub(crate) async fn bind_login(
    store: &AIProviderStore,
    target: Option<uuid::Uuid>,
    account: ProxyAccount,
) -> Option<uuid::Uuid> {
    let mut p = if let Some(id) = target {
        let p = store.get(id).await?;
        if p.provider_type != account.provider {
            return None;
        }
        p
    } else {
        AIProvider::new(
            account.provider,
            format!("{} ({})", account.provider.display_name(), account.identity),
        )
    };
    p.account_email = (account.identity != account.file).then_some(account.identity);
    p.cli_proxy_auth_file = Some(account.file);
    p.oauth = Some(account.oauth);
    p.rejected_oauth_refresh_fingerprint = None;
    if p.use_for_backends.is_none() {
        p.use_for_backends = Some(super::ai_providers::default_backends_for_provider(
            p.provider_type,
        ));
    }
    if let Some(id) = target {
        store.update(id, p).await.map(|p| p.id)
    } else {
        Some(store.add(p).await)
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
    #[test]
    fn muse_requires_subscription_receipt_and_isolated_route() {
        let mut value = serde_json::json!({"type":"meta", "auth_kind":"oauth", "access_token":"minted", "dca_token":"device", "is_subs_active":true, "prefix":"muse-code"});
        let account = parse_account("meta.json", &value).unwrap();
        assert_eq!(account.provider, ProviderType::MuseCode);
        assert_eq!(account.oauth.expires_at, i64::MAX);
        assert!(!account_needs_reconnect(&account));
        for bad in [serde_json::json!(false), serde_json::Value::Null] {
            value["is_subs_active"] = bad;
            assert!(account_needs_reconnect(
                &parse_account("meta.json", &value).unwrap()
            ));
        }
        value["is_subs_active"] = serde_json::json!(true);
        value["prefix"] = serde_json::json!("muse");
        assert!(account_needs_reconnect(
            &parse_account("meta.json", &value).unwrap()
        ));
        value["auth_kind"] = serde_json::json!("api_key");
        assert!(parse_account("meta.json", &value).is_none());
    }

    #[test]
    fn antigravity_requires_its_own_routing_prefix() {
        let mut value = serde_json::json!({"type":"antigravity","access_token":"a","refresh_token":"r","expired":"2099-01-01T00:00:00Z"});
        for prefix in [None, Some("other"), Some("antigravity")] {
            value["prefix"] = serde_json::json!(prefix);
            let account = parse_account("google.json", &value).unwrap();
            assert_eq!(
                account_needs_reconnect(&account),
                prefix != Some("antigravity")
            );
        }
    }

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

    #[tokio::test]
    async fn stale_disabled_proxy_does_not_erase_healthy_migration_source() {
        let dir = tempfile::tempdir().unwrap();
        let store = AIProviderStore::new(dir.path().join("providers.json")).await;
        let mut row = AIProvider::new(ProviderType::Anthropic, "Current login".into());
        row.account_email = Some("user@example.com".into());
        row.oauth = Some(OAuthCredentials {
            access_token: "usable-access".into(),
            refresh_token: "usable-refresh".into(),
            expires_at: 4070908800000,
        });
        let id = store.add(row).await;
        std::fs::write(dir.path().join("claude-old.json"), serde_json::json!({
            "type":"claude","email":"user@example.com","disabled":true,"access_token":"old-access","refresh_token":"old-refresh","expired":"2000-01-01T00:00:00Z"
        }).to_string()).unwrap();
        reconcile_from(&store, dir.path()).await;
        let row = store.get(id).await.unwrap();
        assert_eq!(row.oauth.unwrap().refresh_token, "usable-refresh");
        assert!(row.cli_proxy_auth_file.is_none());
    }

    #[tokio::test]
    async fn replacement_login_keeps_settings_and_retired_files_cannot_rebind() {
        for provider in [ProviderType::Kimi, ProviderType::Anthropic] {
            let dir = tempfile::tempdir().unwrap();
            let store = AIProviderStore::new(dir.path().join("providers.json")).await;
            let mut row = AIProvider::new(provider, "Personal".into());
            row.cli_proxy_auth_file = Some("old.json".into());
            row.account_email = Some(
                if provider == ProviderType::Kimi {
                    "old.json"
                } else {
                    "user@example.com"
                }
                .into(),
            );
            row.priority = 9;
            row.enabled = false;
            let id = store.add(row).await;
            let kind = if provider == ProviderType::Kimi {
                "kimi"
            } else {
                "claude"
            };
            let mut old = serde_json::json!({"type":kind,"sandboxed_provider_id":id,"access_token":"old","refresh_token":"r","expired":"2099-01-01T00:00:00Z"});
            if provider == ProviderType::Anthropic {
                old["email"] = serde_json::json!("user@example.com");
            }
            std::fs::write(dir.path().join("old.json"), old.to_string()).unwrap();
            let mut new = old.clone();
            new.as_object_mut().unwrap().remove("sandboxed_provider_id");
            new["access_token"] = serde_json::json!("fresh");
            std::fs::write(dir.path().join("new.json"), new.to_string()).unwrap();
            bind_login(&store, Some(id), parse_account("new.json", &new).unwrap())
                .await
                .unwrap();
            reconcile_from(&store, dir.path()).await;
            reconcile_from(&store, dir.path()).await;
            assert_eq!(store.list().await.len(), 1);
            let row = store.get(id).await.unwrap();
            assert_eq!(row.cli_proxy_auth_file.as_deref(), Some("new.json"));
            assert_eq!(row.priority, 9);
            assert!(!row.enabled);
            assert_eq!(row.oauth.unwrap().access_token, "fresh");
            if provider == ProviderType::Kimi {
                assert!(row.account_email.is_none());
            }
        }
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
