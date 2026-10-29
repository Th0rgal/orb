//! Account-bound Codex routes shared by ordinary and accelerated inference.
//! Core owns priority/failover; CLIProxyAPI owns credentials, never account choice.
use super::cli_proxy_login::ManagementClient;
use uuid::Uuid;
#[derive(Clone)]
pub(crate) struct ProxyAccountRoute {
    pub provider_id: Uuid,
    pub file: String,
    pub auth_index: String,
    pub prefix: Option<String>,
}

pub(crate) async fn proxy_accounts(
    root: &std::path::Path,
) -> Result<Vec<ProxyAccountRoute>, String> {
    let client = ManagementClient::configured().map_err(|e| e.1)?;
    proxy_accounts_with_client(root, &client).await
}

async fn proxy_accounts_with_client(
    root: &std::path::Path,
    client: &ManagementClient,
) -> Result<Vec<ProxyAccountRoute>, String> {
    let files = client
        .request(reqwest::Method::GET, "/auth-files", None)
        .await
        .map_err(|e| e.1)?;
    let providers =
        crate::ai_providers::AIProviderStore::new(root.join(crate::util::AI_PROVIDERS_PATH))
            .await
            .list()
            .await;
    let mut accounts: Vec<ProxyAccountRoute> = files["files"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|file| {
            if file
                .get("provider")
                .or_else(|| file.get("type"))
                .and_then(|v| v.as_str())
                != Some("codex")
                || file["disabled"] == true
            {
                return None;
            }
            let name = file["name"].as_str()?;
            let provider = providers.iter().find(|p| {
                p.enabled
                    && p.provider_type == crate::ProviderType::OpenAI
                    && p.cli_proxy_auth_file.as_deref() == Some(name)
            })?;
            Some(ProxyAccountRoute {
                provider_id: provider.id,
                file: name.into(),
                auth_index: file["auth_index"].as_str()?.into(),
                prefix: file["prefix"]
                    .as_str()
                    .filter(|p| !p.is_empty())
                    .map(str::to_string),
            })
        })
        .collect();
    for account in &mut accounts {
        if account.prefix.is_some() {
            continue;
        }
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("name", &account.file)
            .finish();
        let models = client
            .request(
                reqwest::Method::GET,
                &format!("/auth-files/models?{query}"),
                None,
            )
            .await
            .map_err(|error| error.1)?;
        account.prefix = catalog_prefix(&models)?;
    }
    Ok(accounts)
}

/// Prefix namespaces pin the proxy's account selection while retaining the
/// original bare model routes. OAuth refresh remains entirely in CLIProxyAPI.
pub(crate) async fn proxy_prefix(
    root: &std::path::Path,
    account: &ProxyAccountRoute,
    model: &str,
) -> Result<String, String> {
    let client = ManagementClient::configured().map_err(|e| e.1)?;
    proxy_prefix_with_client(root, account, model, &client).await
}

async fn proxy_prefix_with_client(
    root: &std::path::Path,
    account: &ProxyAccountRoute,
    model: &str,
    client: &ManagementClient,
) -> Result<String, String> {
    static GATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _guard = GATE.lock().await;
    let all = proxy_accounts_with_client(root, client).await?;
    let current = all
        .iter()
        .find(|a| a.provider_id == account.provider_id)
        .ok_or("Subscription account was disconnected")?;
    let prefix = current
        .prefix
        .clone()
        .unwrap_or_else(|| format!("orb-codex-{}", account.provider_id.simple()));
    if all.iter().any(|other| {
        other.provider_id != account.provider_id && other.prefix.as_deref() == Some(&prefix)
    }) {
        return Err("Subscription routing prefix is shared with another account; configure a unique prefix before routing.".into());
    }
    if current.prefix.is_none()
        && client
            .request(reqwest::Method::GET, "/config", None)
            .await
            .map_err(|e| e.1)?["force-model-prefix"]
            == true
    {
        return Err("Dedicated account routing would remove existing bare model routes. Configure backward-compatible CLIProxyAPI routing first.".into());
    }
    if current.prefix.is_none() {
        client
            .request(
                reqwest::Method::PATCH,
                "/auth-files/fields",
                Some(serde_json::json!({"name":current.file,"prefix":prefix})),
            )
            .await
            .map_err(|e| e.1)?;
    }
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("name", &current.file)
        .finish();
    let catalog = client
        .request(
            reqwest::Method::GET,
            &format!("/auth-files/models?{query}"),
            None,
        )
        .await
        .map_err(|e| e.1)?;
    let qualified = format!("{prefix}/{}", model.rsplit('/').next().unwrap_or(model));
    if !catalog["models"]
        .as_array()
        .is_some_and(|models| models.iter().any(|m| m["id"].as_str() == Some(&qualified)))
    {
        return Err("The proxy has not registered this account's dedicated model route. Update or refresh CLIProxyAPI before starting.".into());
    }
    // Include credentials not projected into Core: they must not be able to
    // capture an account-qualified request either.
    let files = client
        .request(reqwest::Method::GET, "/auth-files", None)
        .await
        .map_err(|e| e.1)?;
    for file in files["files"]
        .as_array()
        .ok_or("Proxy credential inventory unavailable")?
    {
        if file["disabled"] == true || file["name"].as_str() == Some(&current.file) {
            continue;
        }
        let name = file["name"]
            .as_str()
            .ok_or("Proxy credential name unavailable")?;
        let query = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("name", name)
            .finish();
        let models = client
            .request(
                reqwest::Method::GET,
                &format!("/auth-files/models?{query}"),
                None,
            )
            .await
            .map_err(|e| e.1)?;
        if models["models"]
            .as_array()
            .ok_or("Proxy model inventory unavailable")?
            .iter()
            .any(|m| m["id"].as_str() == Some(&qualified))
        {
            return Err("Dedicated account route is shared by another proxy credential".into());
        }
    }
    Ok(prefix)
}

pub(crate) fn catalog_prefix(catalog: &serde_json::Value) -> Result<Option<String>, String> {
    let prefixes: std::collections::HashSet<&str> = catalog["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| {
            model["id"]
                .as_str()?
                .rsplit_once('/')
                .map(|(prefix, _)| prefix)
        })
        .collect();
    if prefixes.len() > 1 {
        return Err("This account exposes multiple routing prefixes; configure a unique account prefix before routing.".into());
    }
    Ok(prefixes.into_iter().next().map(str::to_owned))
}

/// Never fall back to a bare model: that would silently enter the proxy's pool.
pub(crate) async fn qualified_model(
    root: &std::path::Path,
    account_id: Uuid,
    model: &str,
) -> Result<String, String> {
    let client = ManagementClient::configured().map_err(|e| e.1)?;
    qualified_model_with_client(root, account_id, model, &client).await
}

async fn qualified_model_with_client(
    root: &std::path::Path,
    account_id: Uuid,
    model: &str,
    client: &ManagementClient,
) -> Result<String, String> {
    let accounts = proxy_accounts_with_client(root, client).await?;
    let account = accounts
        .iter()
        .find(|a| a.provider_id == account_id)
        .ok_or("Selected Codex account has no active proxy credential")?;
    let prefix = proxy_prefix_with_client(root, account, model, client).await?;
    Ok(format!(
        "{prefix}/{}",
        model.rsplit('/').next().unwrap_or(model)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        extract::{Query, State},
        routing::get,
        Json, Router,
    };
    use serde_json::{json, Value};
    use std::{collections::HashMap, sync::Arc};
    use tokio::sync::Mutex;

    #[derive(Clone)]
    struct Fixture {
        files: Arc<Mutex<Value>>,
        catalogs: Arc<Mutex<HashMap<String, Value>>>,
    }

    async fn fixture() -> (
        tempfile::TempDir,
        ManagementClient,
        Fixture,
        Vec<Uuid>,
        tokio::task::JoinHandle<()>,
    ) {
        let root = tempfile::tempdir().unwrap();
        let store = crate::ai_providers::AIProviderStore::new(
            root.path().join(crate::util::AI_PROVIDERS_PATH),
        )
        .await;
        let mut ids = Vec::new();
        for (priority, name) in ["first", "second"].into_iter().enumerate() {
            let mut p =
                crate::ai_providers::AIProvider::new(crate::ProviderType::OpenAI, name.into());
            p.cli_proxy_auth_file = Some(format!("{name}.json"));
            p.priority = priority as u32;
            ids.push(store.add(p).await);
        }
        let fixture = Fixture {
            files: Arc::new(Mutex::new(json!({"files":[
                {"provider":"codex","name":"first.json","auth_index":"first","prefix":"first"},
                {"provider":"codex","name":"second.json","auth_index":"second","prefix":"second"}
            ]}))),
            catalogs: Arc::new(Mutex::new(HashMap::from([
                (
                    "first.json".into(),
                    json!({"models":[{"id":"first/gpt-6-astra"},{"id":"gpt-6-astra"}]}),
                ),
                (
                    "second.json".into(),
                    json!({"models":[{"id":"second/gpt-6-astra"},{"id":"gpt-6-astra"}]}),
                ),
            ]))),
        };
        let app = Router::new()
            .route("/auth-files", get(|State(s): State<Fixture>| async move { Json(s.files.lock().await.clone()) }))
            .route("/auth-files/models", get(|State(s): State<Fixture>, Query(q): Query<HashMap<String,String>>| async move {
                Json(s.catalogs.lock().await.get(&q["name"]).cloned().unwrap_or(json!({"models":[]})))
            }))
            .with_state(fixture.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client =
            ManagementClient::for_test(format!("http://{}", listener.local_addr().unwrap()));
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (root, client, fixture, ids, task)
    }

    #[tokio::test]
    async fn selected_account_not_pool_order_controls_both_speeds() {
        let (root, client, _, ids, task) = fixture().await;
        assert_eq!(
            qualified_model_with_client(root.path(), ids[1], "openai/gpt-6-astra", &client)
                .await
                .unwrap(),
            "second/gpt-6-astra"
        );
        let accounts = proxy_accounts_with_client(root.path(), &client)
            .await
            .unwrap();
        let accelerated =
            proxy_prefix_with_client(root.path(), &accounts[1], "gpt-6-astra", &client)
                .await
                .unwrap();
        assert_eq!(accelerated, "second");
        assert_eq!(
            qualified_model_with_client(root.path(), ids[0], "gpt-6-astra", &client)
                .await
                .unwrap(),
            "first/gpt-6-astra"
        );
        task.abort();
    }

    #[tokio::test]
    async fn disconnected_or_unregistered_account_route_is_never_bare() {
        let (root, client, state, ids, task) = fixture().await;
        state.files.lock().await["files"][0]["disabled"] = json!(true);
        assert!(
            qualified_model_with_client(root.path(), ids[0], "gpt-6-astra", &client)
                .await
                .is_err()
        );
        state.catalogs.lock().await.insert(
            "second.json".into(),
            json!({"models":[{"id":"gpt-6-astra"}]}),
        );
        assert!(
            qualified_model_with_client(root.path(), ids[1], "gpt-6-astra", &client)
                .await
                .is_err()
        );
        task.abort();
    }

    #[tokio::test]
    async fn unmanaged_credential_cannot_capture_a_bound_route() {
        let (root, client, state, ids, task) = fixture().await;
        state.files.lock().await["files"].as_array_mut().unwrap().push(json!({"provider":"codex","name":"foreign.json","auth_index":"foreign","prefix":"first"}));
        state.catalogs.lock().await.insert(
            "foreign.json".into(),
            json!({"models":[{"id":"first/gpt-6-astra"}]}),
        );
        let error = qualified_model_with_client(root.path(), ids[0], "gpt-6-astra", &client)
            .await
            .unwrap_err();
        assert!(error.contains("shared"), "{error}");
        task.abort();
    }
}
