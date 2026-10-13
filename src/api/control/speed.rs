//! Subscription-only Codex speed eligibility. A requested accelerated tier never
//! authorizes falling back to API billing or an opaque proxy account pool.
use super::*;
use crate::api::ai_providers::CodexOAuthAccount;
use crate::codex_speed::Tier;
use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

#[derive(Clone, Default)]
struct Support {
    fast: bool,
    ultrafast: bool,
}
type CapabilityCache = HashMap<(Uuid, String), (Instant, Support)>;
static CACHE: LazyLock<tokio::sync::Mutex<CapabilityCache>> = LazyLock::new(Default::default);

fn advertised(report: &serde_json::Value, model: &str, tier: &str) -> bool {
    let tier = match tier {
        "fast" => Tier::Fast,
        "ultrafast" => Tier::Ultrafast,
        _ => return false,
    };
    crate::codex_speed::catalog_advertises(report, model, tier)
}

async fn support(root: &std::path::Path, account: &CodexOAuthAccount, model: &str) -> Support {
    let model = model.rsplit('/').next().unwrap_or(model);
    let key = (account.provider_id, model.to_string());
    if let Some((at, value)) = CACHE.lock().await.get(&key) {
        if at.elapsed() < Duration::from_secs(60) {
            return value.clone();
        }
    }
    let result = async {
        let account =
            super::super::ai_providers::prepare_codex_oauth_account_for_launch(root, account)
                .await
                .ok()?;
        let client = reqwest::Client::new();
        let usage = super::super::codex_usage::read_usage(
            &client,
            &account.access_token,
            &account.chatgpt_account_id,
        )
        .await
        .ok()?;
        let catalog: serde_json::Value = client
            .get("https://chatgpt.com/backend-api/codex/models")
            .query(&[("client_version", "0.162.0")])
            .bearer_auth(&account.access_token)
            .header("chatgpt-account-id", &account.chatgpt_account_id)
            .header("originator", "codex_cli_rs")
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .ok()?
            .error_for_status()
            .ok()?
            .json()
            .await
            .ok()?;
        // A generic `pro` claim does not distinguish Pro $200 from Pro $500.
        // Enterprise/Edu access must also be advertised by this account's catalog.
        let eligible_ultrafast_plan =
            crate::codex_speed::eligible_ultrafast_plan(usage.plan_type.as_deref());
        Some(Support {
            fast: Tier::Fast.supports_model(model) && advertised(&catalog, model, "fast"),
            ultrafast: Tier::Ultrafast.supports_model(model)
                && eligible_ultrafast_plan
                && advertised(&catalog, model, "ultrafast"),
        })
    }
    .await
    .unwrap_or_default();
    CACHE
        .lock()
        .await
        .insert(key, (Instant::now(), result.clone()));
    result
}

pub(crate) async fn eligible_accounts(
    root: &std::path::Path,
    model: &str,
    tier: Tier,
) -> Vec<CodexOAuthAccount> {
    let mut eligible = Vec::new();
    for account in super::super::ai_providers::get_all_openai_oauth_accounts(root) {
        let supported = support(root, &account, model).await;
        if tier == Tier::Standard
            || (tier == Tier::Fast && supported.fast)
            || (tier == Tier::Ultrafast && supported.ultrafast)
        {
            eligible.push(account);
        }
    }
    eligible
}

async fn validate_selection(
    root: &std::path::Path,
    backend: &str,
    model: Option<&str>,
    tier: Tier,
    mission_id: Option<Uuid>,
    prepare_routes: bool,
) -> Result<(), String> {
    if tier == Tier::Standard {
        return Ok(());
    }
    if backend != "codex" {
        return Err("Speed tiers are available for Codex only.".into());
    }
    let model =
        model.ok_or("Choose an explicit Codex model before enabling an accelerated tier.")?;
    if !tier.supports_model(model) {
        return Err("The selected model does not support this speed tier.".into());
    }
    if let Some(endpoint) = super::super::oauth_owner::codex_via_cli_proxy() {
        let client = super::super::cli_proxy_login::ManagementClient::configured()
            .map_err(|error| error.1)?;
        let version = client.version().await.map_err(|error| error.1)?;
        if !proxy_supports_speed(&version) {
            return Err("Update CLIProxyAPI to 8.0.26 or later before enabling accelerated speed; older transports may silently discard Ultrafast.".into());
        }
        let eligible = eligible_proxy_accounts(root, model, tier).await;
        if eligible.is_empty() {
            return Err("No connected proxy-owned subscription advertises this speed for the selected model. Refresh or connect a compatible account in Providers.".into());
        }
        if let Some(id) = mission_id {
            if let Some(binding) = crate::backend::codex::continuity::read(
                &crate::backend::codex::continuity::binding_path(root, id),
            )
            .map_err(|e| e.to_string())?
            {
                if binding.identity.account
                    != crate::backend::codex::continuity::account_fingerprint(
                        "cliproxy",
                        &endpoint.base_url,
                    )
                {
                    return Err("This native conversation is bound to another credential owner. Fork it before changing its account route.".into());
                }
            }
        }
        if prepare_routes {
            for account in &eligible {
                proxy_prefix(root, account, model).await?;
            }
        }
        return Ok(());
    }
    let eligible = eligible_accounts(root, model, tier).await;
    let binding = mission_id
        .map(|id| {
            crate::backend::codex::continuity::read(
                &crate::backend::codex::continuity::binding_path(root, id),
            )
        })
        .transpose()
        .map_err(|error| error.to_string())?
        .flatten();
    if let Some(binding) = binding {
        if !eligible.iter().any(|account| {
            crate::backend::codex::continuity::account_fingerprint(
                "oauth",
                &account.chatgpt_account_id,
            ) == binding.identity.account
        }) {
            return Err("This conversation's account cannot use that speed. Fork it to select a compatible subscription without replacing its native conversation.".into());
        }
    }
    if eligible.is_empty() {
        return Err("No connected subscription currently advertises this speed for the selected model. Refresh or connect a compatible account in Providers.".into());
    }
    Ok(())
}

pub(crate) async fn validate(
    root: &std::path::Path,
    backend: &str,
    model: Option<&str>,
    tier: Tier,
    mission_id: Option<Uuid>,
) -> Result<(), String> {
    validate_selection(root, backend, model, tier, mission_id, true).await
}
#[derive(serde::Deserialize)]
pub struct OptionsQuery {
    model: String,
    mission_id: Option<Uuid>,
}
pub async fn options(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<OptionsQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    if let Some(id) = query.mission_id {
        let control = control_for_user(&state, &user).await;
        control
            .mission_store
            .get_mission(id)
            .await
            .map_err(internal_error)?
            .ok_or((StatusCode::NOT_FOUND, "Mission not found".into()))?;
    }
    super::super::cli_proxy_accounts::reconcile(&state.ai_providers).await;
    let mut items = Vec::new();
    for tier in [Tier::Standard, Tier::Fast, Tier::Ultrafast] {
        let result = validate_selection(
            &state.config.working_dir,
            "codex",
            Some(&query.model),
            tier,
            query.mission_id,
            false,
        )
        .await;
        items.push(serde_json::json!({"id":tier,"available":result.is_ok(),"reason":result.err()}));
    }
    Ok(Json(serde_json::json!({"version":1,"tiers":items})))
}

#[cfg(test)]
mod tests {
    #[test]
    fn speed_transport_requires_a_version_that_preserves_ultrafast_and_discovers_metadata_without_tokens(
    ) {
        assert!(!super::proxy_supports_speed("8.0.23"));
        assert!(super::proxy_supports_speed("v8.0.26"));
        assert!(!super::proxy_supports_speed("unknown"));
        assert_eq!(super::catalog_prefix(&serde_json::json!({"models":[{"id":"gpt-6.1-sol"},{"id":"orb-codex-account/gpt-6.1-sol"}]})).unwrap().as_deref(),Some("orb-codex-account"));
        assert!(super::catalog_prefix(
            &serde_json::json!({"models":[{"id":"a/gpt-6.1-sol"},{"id":"b/gpt-6.1-sol"}]})
        )
        .is_err());
    }
    use super::*;
    #[test]
    fn catalog_capability_is_per_model_and_missing_evidence_is_not_access() {
        let catalog = serde_json::json!({"models":[{"slug":"gpt-6.1-sol","service_tiers":[{"id":"fast"},{"id":"ultrafast"}]},{"slug":"gpt-6-luna","service_tiers":["fast"]}]});
        assert!(advertised(&catalog, "gpt-6.1-sol", "ultrafast"));
        assert!(!advertised(&catalog, "gpt-6-luna", "ultrafast"));
        assert!(!advertised(
            &serde_json::json!({}),
            "gpt-6.1-sol",
            "ultrafast"
        ));
    }
}

#[derive(Clone)]
pub(crate) struct ProxySpeedAccount {
    pub provider_id: Uuid,
    pub file: String,
    pub auth_index: String,
    pub prefix: Option<String>,
}

async fn proxy_accounts(root: &std::path::Path) -> Result<Vec<ProxySpeedAccount>, String> {
    let client = super::super::cli_proxy_login::ManagementClient::configured().map_err(|e| e.1)?;
    let files = client
        .request(reqwest::Method::GET, "/auth-files", None)
        .await
        .map_err(|e| e.1)?;
    let providers =
        crate::ai_providers::AIProviderStore::new(root.join(crate::util::AI_PROVIDERS_PATH))
            .await
            .list()
            .await;
    let mut accounts: Vec<ProxySpeedAccount> = files["files"]
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
            Some(ProxySpeedAccount {
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

async fn proxy_support(account: &ProxySpeedAccount, model: &str) -> Support {
    let model = model.rsplit('/').next().unwrap_or(model);
    let key = (account.provider_id, model.to_string());
    if let Some((at, value)) = CACHE.lock().await.get(&key) {
        if at.elapsed() < Duration::from_secs(60) {
            return value.clone();
        }
    }
    let result=async {
        let client=super::super::cli_proxy_login::ManagementClient::configured().ok()?;
        let call=|url:&str|serde_json::json!({"auth_index":account.auth_index,"method":"GET","url":url,"header":{"Authorization":"Bearer $TOKEN$","originator":"codex_cli_rs"}});
        let usage=client.request(reqwest::Method::POST,"/api-call",Some(call("https://chatgpt.com/backend-api/wham/usage"))).await.ok()?;
        if usage["status_code"]!=200{return None;}
        let usage:serde_json::Value=serde_json::from_str(usage["body"].as_str()?).ok()?;
        let catalog=client.request(reqwest::Method::POST,"/api-call",Some(call("https://chatgpt.com/backend-api/codex/models?client_version=0.162.0"))).await.ok()?;
        if catalog["status_code"]!=200{return None;}
        let catalog:serde_json::Value=serde_json::from_str(catalog["body"].as_str()?).ok()?;
        Some(Support {fast:Tier::Fast.supports_model(model)&&advertised(&catalog,model,"fast"),ultrafast:Tier::Ultrafast.supports_model(model)&&crate::codex_speed::eligible_ultrafast_plan(usage["plan_type"].as_str())&&advertised(&catalog,model,"ultrafast")})
    }.await.unwrap_or_default();
    CACHE
        .lock()
        .await
        .insert(key, (Instant::now(), result.clone()));
    result
}

pub(crate) async fn eligible_proxy_accounts(
    root: &std::path::Path,
    model: &str,
    tier: Tier,
) -> Vec<ProxySpeedAccount> {
    if !tier.supports_model(model) {
        return Vec::new();
    }
    let mut allowed = Vec::new();
    for account in proxy_accounts(root).await.unwrap_or_default() {
        let support = proxy_support(&account, model).await;
        if (tier == Tier::Fast && support.fast) || (tier == Tier::Ultrafast && support.ultrafast) {
            allowed.push(account);
        }
    }
    allowed
}

/// Prefix namespaces pin the proxy's account selection while retaining the
/// original bare model routes. OAuth refresh remains entirely in CLIProxyAPI.
pub(crate) async fn proxy_prefix(
    root: &std::path::Path,
    account: &ProxySpeedAccount,
    model: &str,
) -> Result<String, String> {
    static GATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _guard = GATE.lock().await;
    let all = proxy_accounts(root).await?;
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
        return Err("Subscription routing prefix is shared with another account; configure a unique prefix before enabling this speed.".into());
    }
    let client = super::super::cli_proxy_login::ManagementClient::configured().map_err(|e| e.1)?;
    if current.prefix.is_none()
        && client
            .request(reqwest::Method::GET, "/config", None)
            .await
            .map_err(|e| e.1)?["force-model-prefix"]
            == true
    {
        return Err("Dedicated speed routing would remove existing bare model routes. Configure backward-compatible CLIProxyAPI routing first.".into());
    }
    if current.prefix.is_none() {
        client
            .request(
                reqwest::Method::PATCH,
                "/auth-files/fields",
                Some(serde_json::json!({"name":account.file,"prefix":prefix})),
            )
            .await
            .map_err(|e| e.1)?;
    }
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("name", &account.file)
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
    Ok(prefix)
}

pub(crate) async fn eligible_account_ids(
    root: &std::path::Path,
    model: &str,
    tier: Tier,
) -> std::collections::HashSet<Uuid> {
    if super::super::oauth_owner::codex_via_cli_proxy().is_some() {
        eligible_proxy_accounts(root, model, tier)
            .await
            .into_iter()
            .map(|a| a.provider_id)
            .collect()
    } else {
        eligible_accounts(root, model, tier)
            .await
            .into_iter()
            .map(|a| a.provider_id)
            .collect()
    }
}

fn proxy_supports_speed(version: &str) -> bool {
    let parts: Option<Vec<u32>> = version
        .trim_start_matches('v')
        .split('.')
        .take(3)
        .map(|part| part.parse().ok())
        .collect();
    parts.is_some_and(|parts| parts.len() == 3 && parts.as_slice() >= [8, 0, 26].as_slice())
}
fn catalog_prefix(catalog: &serde_json::Value) -> Result<Option<String>, String> {
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
        return Err("This account exposes multiple routing prefixes; configure a unique account prefix before enabling accelerated speed.".into());
    }
    Ok(prefixes.into_iter().next().map(str::to_owned))
}
