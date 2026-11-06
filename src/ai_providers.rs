//! AI Provider configuration and storage.
//!
//! Manages inference providers that OpenCode can use (Anthropic, OpenAI, etc.).

use arc_swap::ArcSwap;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────────────────
// Authentication Methods
// ─────────────────────────────────────────────────────────────────────────────

/// Authentication method types.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMethodType {
    /// OAuth-based authentication (Claude Pro/Max, GitHub Copilot)
    Oauth,
    /// Manual API key entry
    Api,
}

/// An authentication method for a provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthMethod {
    pub label: String,
    #[serde(rename = "type")]
    pub method_type: AuthMethodType,
    /// Optional description for the method
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Pending OAuth authorization state.
#[derive(Debug, Clone)]
pub struct PendingOAuth {
    pub verifier: String,
    pub mode: String, // "max" or "console"
    pub state: Option<String>,
    pub created_at: std::time::Instant,
}

/// Stored OAuth credentials.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OAuthCredentials {
    pub refresh_token: String,
    pub access_token: String,
    pub expires_at: i64,
}

/// Provider credential type.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ProviderCredential {
    /// API key authentication
    ApiKey { key: String },
    /// OAuth token authentication
    OAuth {
        refresh_token: String,
        access_token: String,
        expires_at: i64,
    },
}

/// Custom model definition for custom providers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomModel {
    /// Model ID (used in API requests)
    pub id: String,
    /// Human-readable name
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Context window size (input tokens)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_limit: Option<u32>,
    /// Maximum output tokens
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_limit: Option<u32>,
}

/// Known AI provider types.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderType {
    Anthropic,
    #[serde(rename = "openai")]
    OpenAI,
    Google,
    Antigravity,
    AmazonBedrock,
    Azure,
    OpenRouter,
    Mistral,
    Groq,
    Xai,
    DeepInfra,
    Cerebras,
    Cohere,
    #[serde(rename = "together-ai")]
    TogetherAI,
    Perplexity,
    GithubCopilot,
    Zai,
    Minimax,
    Kimi,
    /// Meta's Muse model family (api.meta.ai, OpenAI-compatible).
    Muse,
    /// Muse Code subscription, isolated from the paid Meta API provider.
    MuseCode,
    Custom,
}

impl ProviderType {
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Anthropic => "Anthropic",
            Self::OpenAI => "OpenAI",
            Self::Google => "Google AI",
            Self::Antigravity => "Antigravity subscription",
            Self::AmazonBedrock => "Amazon Bedrock",
            Self::Azure => "Azure OpenAI",
            Self::OpenRouter => "OpenRouter",
            Self::Mistral => "Mistral AI",
            Self::Groq => "Groq",
            Self::Xai => "xAI",
            Self::DeepInfra => "DeepInfra",
            Self::Cerebras => "Cerebras",
            Self::Cohere => "Cohere",
            Self::TogetherAI => "Together AI",
            Self::Perplexity => "Perplexity",
            Self::GithubCopilot => "GitHub Copilot",
            Self::Zai => "Z.AI",
            Self::Minimax => "Minimax",
            Self::Muse => "Meta Muse API",
            Self::MuseCode => "Muse Code",
            Self::Kimi => "Kimi",
            Self::Custom => "Custom",
        }
    }

    pub fn id(&self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAI => "openai",
            Self::Google => "google",
            Self::Antigravity => "antigravity",
            Self::AmazonBedrock => "amazon-bedrock",
            Self::Azure => "azure",
            Self::OpenRouter => "open-router",
            Self::Mistral => "mistral",
            Self::Groq => "groq",
            Self::Xai => "xai",
            Self::DeepInfra => "deep-infra",
            Self::Cerebras => "cerebras",
            Self::Cohere => "cohere",
            Self::TogetherAI => "together-ai",
            Self::Perplexity => "perplexity",
            Self::GithubCopilot => "github-copilot",
            Self::Zai => "zai",
            Self::Minimax => "minimax",
            Self::Muse => "muse",
            Self::MuseCode => "muse-code",
            Self::Kimi => "kimi",
            Self::Custom => "custom",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "anthropic" => Some(Self::Anthropic),
            "openai" => Some(Self::OpenAI),
            "codex" => Some(Self::OpenAI),
            "google" | "gemini" => Some(Self::Google),
            "antigravity" => Some(Self::Antigravity),
            "amazon-bedrock" => Some(Self::AmazonBedrock),
            "azure" => Some(Self::Azure),
            "open-router" => Some(Self::OpenRouter),
            "mistral" => Some(Self::Mistral),
            "groq" => Some(Self::Groq),
            "xai" => Some(Self::Xai),
            "deep-infra" => Some(Self::DeepInfra),
            "cerebras" => Some(Self::Cerebras),
            "cohere" => Some(Self::Cohere),
            "together-ai" => Some(Self::TogetherAI),
            "perplexity" => Some(Self::Perplexity),
            "github-copilot" => Some(Self::GithubCopilot),
            "zai" => Some(Self::Zai),
            "minimax" => Some(Self::Minimax),
            "muse" | "meta" => Some(Self::Muse),
            "muse-code" => Some(Self::MuseCode),
            "kimi" => Some(Self::Kimi),
            "custom" => Some(Self::Custom),
            _ => None,
        }
    }

    pub fn env_var_name(&self) -> Option<&'static str> {
        match self {
            Self::Anthropic => Some("ANTHROPIC_API_KEY"),
            Self::OpenAI => Some("OPENAI_API_KEY"),
            Self::Google => Some("GOOGLE_API_KEY"),
            Self::Antigravity => None,
            Self::AmazonBedrock => None, // Uses AWS credentials
            Self::Azure => Some("AZURE_OPENAI_API_KEY"),
            Self::OpenRouter => Some("OPENROUTER_API_KEY"),
            Self::Mistral => Some("MISTRAL_API_KEY"),
            Self::Groq => Some("GROQ_API_KEY"),
            Self::Xai => Some("XAI_API_KEY"),
            Self::DeepInfra => Some("DEEPINFRA_API_KEY"),
            Self::Cerebras => Some("CEREBRAS_API_KEY"),
            Self::Cohere => Some("COHERE_API_KEY"),
            Self::TogetherAI => Some("TOGETHER_API_KEY"),
            Self::Perplexity => Some("PERPLEXITY_API_KEY"),
            Self::GithubCopilot => None, // Uses OAuth
            Self::Zai => Some("ZHIPU_API_KEY"),
            Self::Minimax => Some("MINIMAX_API_KEY"),
            Self::Muse => Some("META_MODEL_API_KEY"),
            Self::MuseCode => None,
            Self::Kimi => None, // OAuth-only (Kimi Code subscription)
            Self::Custom => None,
        }
    }

    /// Returns whether this provider uses OAuth authentication.
    pub fn uses_oauth(&self) -> bool {
        matches!(
            self,
            Self::Anthropic
                | Self::GithubCopilot
                | Self::OpenAI
                | Self::Google
                | Self::Xai
                | Self::Kimi
                | Self::Antigravity
                | Self::MuseCode
        )
    }

    /// Returns available authentication methods for this provider.
    pub fn auth_methods(&self) -> Vec<AuthMethod> {
        match self {
            Self::OpenAI => vec![
                AuthMethod {
                    label: "ChatGPT Plus/Pro (OAuth)".to_string(),
                    method_type: AuthMethodType::Oauth,
                    description: Some(
                        "Use your ChatGPT subscription via official OAuth".to_string(),
                    ),
                },
                AuthMethod {
                    label: "Manually enter API Key".to_string(),
                    method_type: AuthMethodType::Api,
                    description: Some("Enter an existing OpenAI API key".to_string()),
                },
            ],
            Self::Anthropic => vec![
                AuthMethod {
                    label: "Claude Pro/Max".to_string(),
                    method_type: AuthMethodType::Oauth,
                    description: Some(
                        "Use your Claude Pro or Max subscription for unlimited usage".to_string(),
                    ),
                },
                AuthMethod {
                    label: "Create an API Key".to_string(),
                    method_type: AuthMethodType::Oauth,
                    description: Some(
                        "Create a new API key from your Anthropic account".to_string(),
                    ),
                },
                AuthMethod {
                    label: "Manually enter API Key".to_string(),
                    method_type: AuthMethodType::Api,
                    description: Some("Enter an existing Anthropic API key".to_string()),
                },
            ],
            Self::MuseCode => vec![AuthMethod {
                label: "Muse Code subscription".into(),
                method_type: AuthMethodType::Oauth,
                description: Some("Connect your Meta subscription through CLIProxyAPI. No paid API fallback.".into()),
            }],
            Self::Antigravity => vec![AuthMethod {
                label: "Google Antigravity".into(),
                method_type: AuthMethodType::Oauth,
                description: Some("Connect a Google account for shared model access through CLIProxyAPI.".into()),
            }],
            Self::GithubCopilot => vec![AuthMethod {
                label: "GitHub Copilot".to_string(),
                method_type: AuthMethodType::Oauth,
                description: Some("Connect your GitHub Copilot subscription".to_string()),
            }],
            Self::Google => vec![
                AuthMethod {
                    label: "OAuth with Google (OpenCode)".to_string(),
                    method_type: AuthMethodType::Oauth,
                    description: Some(
                        "Use your Gemini plan/quotas (including free tier) via Google OAuth"
                            .to_string(),
                    ),
                },
                AuthMethod {
                    label: "Manually enter API Key".to_string(),
                    method_type: AuthMethodType::Api,
                    description: Some("Enter an existing Google AI API key".to_string()),
                },
            ],
            Self::Xai => vec![
                AuthMethod {
                    label: "xAI SuperGrok OAuth".to_string(),
                    method_type: AuthMethodType::Oauth,
                    description: Some(
                        "Use your grok.com SuperGrok login. OpenCode xai/* and the grok CLI share this account; Grok Build is the CLI harness, not a second login."
                            .to_string(),
                    ),
                },
                AuthMethod {
                    label: "Manually enter API Key".to_string(),
                    method_type: AuthMethodType::Api,
                    description: Some("Enter an existing xAI API key".to_string()),
                },
            ],
            Self::Kimi => vec![AuthMethod {
                label: "Kimi Code (Device OAuth)".to_string(),
                method_type: AuthMethodType::Oauth,
                description: Some(
                    "Authorize your Kimi Code subscription via device-code login".to_string(),
                ),
            }],
            _ => vec![AuthMethod {
                label: "API Key".to_string(),
                method_type: AuthMethodType::Api,
                description: None,
            }],
        }
    }
}

impl std::fmt::Display for ProviderType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.display_name())
    }
}

/// AI provider configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AIProvider {
    pub id: Uuid,
    /// Provider type (anthropic, openai, etc.)
    pub provider_type: ProviderType,
    /// Human-readable name (e.g., "My Claude Account", "Work OpenAI")
    pub name: String,
    /// Optional label to distinguish multiple accounts of the same provider type
    /// (e.g., "Thomas (OAuth)", "Ben (OAuth)", "Team (API key)")
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// Priority order for fallback chains (lower = higher priority, used first)
    #[serde(default)]
    pub priority: u32,
    /// Optional Google Cloud project ID (required for Gemini via OpenCode)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub google_project_id: Option<String>,
    /// API key (if using API key auth)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    /// Credential provisioned by Mistral Vibe browser sign-in, billed to its plan.
    #[serde(default)]
    pub mistral_subscription: bool,
    /// Mistral console session (`ory_session_*` + `csrftoken` cookies only),
    /// used solely to read the Vibe plan's monthly usage. Never sent to clients.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mistral_usage_session: Option<String>,
    /// OAuth credentials (if using OAuth auth)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthCredentials>,
    #[serde(default)]
    pub(crate) oauth_generation: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) oauth_rotation_id: Option<Uuid>,
    /// Authoritative CLIProxyAPI auth file. `oauth` is a read-only snapshot for
    /// quota probes; only CLIProxyAPI may rotate the corresponding login.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_proxy_auth_file: Option<String>,
    /// Custom base URL (for self-hosted or proxy endpoints)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Custom models for custom providers
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_models: Option<Vec<CustomModel>>,
    /// Custom environment variable name for API key (for custom providers)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_env_var: Option<String>,
    /// NPM package for custom provider (defaults to @ai-sdk/openai-compatible)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub npm_package: Option<String>,
    /// Which backends this provider is used for (e.g., ["opencode", "claudecode", "codex"])
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub use_for_backends: Option<Vec<String>>,
    /// Whether this provider is enabled
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    /// Automatically redeem a banked subscription reset when all accounts hit
    /// a usage limit on a mission.
    #[serde(default)]
    pub auto_reset_on_limit: bool,
    /// Whether this is the default provider
    #[serde(default)]
    pub is_default: bool,
    /// Account identifier (email or username) from OAuth or user-provided
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_email: Option<String>,
    /// Provider-assigned organization identifier — e.g. Anthropic's
    /// `anthropic-organization-id` response header. Persisted so the chain
    /// resolver can group credential records under the same subscription
    /// and apply shared cooldowns across them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization_id: Option<String>,
    /// SHA-256 fingerprint of an OAuth refresh token that the provider has
    /// permanently rejected. Persisted so a service restart cannot briefly
    /// present a revoked account as connected again. This is deliberately a
    /// one-way fingerprint rather than another copy of the credential.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejected_oauth_refresh_fingerprint: Option<String>,
    /// Connection status (populated at runtime)
    #[serde(skip)]
    pub status: ProviderStatus,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

fn default_enabled() -> bool {
    true
}

/// Provider connection status.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderStatus {
    #[default]
    Unknown,
    Connected,
    NeedsAuth,
    /// OAuth refresh token expired - user needs to re-authenticate
    NeedsReauth(String),
    Error(String),
}

impl AIProvider {
    pub fn new(provider_type: ProviderType, name: String) -> Self {
        let now = chrono::Utc::now();
        Self {
            id: Uuid::new_v4(),
            provider_type,
            name,
            label: None,
            priority: 0,
            google_project_id: None,
            api_key: None,
            mistral_subscription: false,
            mistral_usage_session: None,
            oauth: None,
            oauth_generation: Uuid::new_v4(),
            oauth_rotation_id: None,
            cli_proxy_auth_file: None,
            base_url: None,
            custom_models: None,
            custom_env_var: None,
            npm_package: None,
            use_for_backends: None,
            enabled: true,
            auto_reset_on_limit: false,
            is_default: false,
            account_email: None,
            organization_id: None,
            rejected_oauth_refresh_fingerprint: None,
            status: ProviderStatus::Unknown,
            created_at: now,
            updated_at: now,
        }
    }

    /// Check if this provider has valid credentials configured.
    /// Custom providers may not require credentials.
    pub fn has_credentials(&self) -> bool {
        self.api_key.is_some()
            || self.oauth.is_some()
            || (self.provider_type == ProviderType::Custom && self.base_url.is_some())
    }

    /// Check if this provider has OAuth credentials.
    pub fn has_oauth(&self) -> bool {
        self.oauth.is_some()
    }
}

/// In-memory store for AI providers.
#[derive(Debug, Clone)]
pub struct AIProviderStore {
    providers: Arc<ArcSwap<HashMap<Uuid, AIProvider>>>,
    writer: Arc<Mutex<()>>,
    /// Pending OAuth authorizations (keyed by provider ID)
    pending_oauth: Arc<DashMap<Uuid, PendingOAuth>>,
    storage_path: PathBuf,
}

impl AIProviderStore {
    pub async fn new(storage_path: PathBuf) -> Self {
        let store = Self {
            providers: Arc::new(ArcSwap::from_pointee(HashMap::new())),
            writer: Arc::new(Mutex::new(())),
            pending_oauth: Arc::new(DashMap::new()),
            storage_path,
        };

        // Load existing providers
        if let Ok((loaded, needs_save)) = store.load_from_disk() {
            store.providers.store(Arc::new(loaded.clone()));
            if needs_save {
                let _ = store.save_snapshot(&loaded).await;
            }
        }

        store
    }

    pub(crate) fn oauth_generation_at_path(
        storage_path: &std::path::Path,
        provider_type: ProviderType,
        refresh_token: &str,
    ) -> Option<Uuid> {
        if refresh_token.trim().is_empty() {
            return None;
        }
        let contents = std::fs::read_to_string(storage_path).ok()?;
        let providers: Vec<AIProvider> = serde_json::from_str(&contents).ok()?;
        providers
            .into_iter()
            .find(|provider| {
                provider.enabled
                    && provider.provider_type == provider_type
                    && provider
                        .oauth
                        .as_ref()
                        .is_some_and(|oauth| oauth.refresh_token == refresh_token)
            })
            .map(|provider| provider.oauth_generation)
            .filter(|generation| !generation.is_nil())
    }

    /// Load providers from disk.
    fn load_from_disk(&self) -> Result<(HashMap<Uuid, AIProvider>, bool), std::io::Error> {
        if !self.storage_path.exists() {
            return Ok((HashMap::new(), false));
        }

        let contents = std::fs::read_to_string(&self.storage_path)?;
        let mut providers: Vec<AIProvider> = serde_json::from_str(&contents)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        let mut needs_save = false;
        for provider in &mut providers {
            if provider.oauth_generation.is_nil() {
                provider.oauth_generation = Uuid::new_v4();
                needs_save = true;
            }
        }

        Ok((
            providers.into_iter().map(|p| (p.id, p)).collect(),
            needs_save,
        ))
    }

    /// Save a provider map snapshot atomically to disk (`0o600` on Unix) via `tokio::fs`
    /// without blocking readers.
    async fn save_snapshot(
        &self,
        providers: &HashMap<Uuid, AIProvider>,
    ) -> Result<(), std::io::Error> {
        let providers_vec: Vec<&AIProvider> = providers.values().collect();
        let contents = serde_json::to_vec_pretty(&providers_vec)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        crate::concurrency::write_atomic_async(&self.storage_path, &contents, Some(0o600)).await?;
        let parent = self
            .storage_path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or_else(|| std::path::Path::new("."));
        tokio::fs::File::open(parent).await?.sync_all().await
    }

    async fn publish_snapshot(&self, providers: HashMap<Uuid, AIProvider>) -> bool {
        if let Err(error) = self.save_snapshot(&providers).await {
            tracing::error!(%error, "Failed to save AI providers to disk");
            return false;
        }
        self.providers.store(Arc::new(providers));
        true
    }

    pub async fn list(&self) -> Vec<AIProvider> {
        let providers = self.providers.load();
        let mut list: Vec<_> = providers.values().cloned().collect();
        // Sort by name
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    pub async fn get(&self, id: Uuid) -> Option<AIProvider> {
        self.providers.load().get(&id).cloned()
    }

    /// Get the default provider (first enabled default, or highest-priority enabled).
    pub async fn get_default(&self) -> Option<AIProvider> {
        let providers = self.providers.load();
        // Find the one marked as default
        if let Some(provider) = providers.values().find(|p| p.is_default && p.enabled) {
            return Some(provider.clone());
        }
        // Fallback to highest-priority enabled (UUID tiebreaker for determinism)
        providers
            .values()
            .filter(|p| p.enabled)
            .min_by_key(|p| (p.priority, p.id))
            .cloned()
    }

    /// Get highest-priority enabled provider by type.
    ///
    /// When multiple accounts exist for the same provider type, returns the one
    /// with the lowest `priority` value (i.e. highest priority).  Ties are
    /// broken by UUID for deterministic ordering.
    pub async fn get_by_type(&self, provider_type: ProviderType) -> Option<AIProvider> {
        let providers = self.providers.load();
        providers
            .values()
            .filter(|p| p.provider_type == provider_type && p.enabled)
            .min_by_key(|p| (p.priority, p.id))
            .cloned()
    }

    /// Get all providers of a given type, sorted by priority (lower = higher priority).
    /// Ties are broken by UUID for deterministic ordering.
    pub async fn get_all_by_type(&self, provider_type: ProviderType) -> Vec<AIProvider> {
        let providers = self.providers.load();
        let mut matched: Vec<AIProvider> = providers
            .values()
            .filter(|p| p.provider_type == provider_type && p.enabled)
            .cloned()
            .collect();
        matched.sort_by_key(|p| (p.priority, p.id));
        matched
    }

    /// Persist a browser-provisioned account before making it visible to readers.
    pub(crate) async fn persist_account(
        &self,
        mut provider: AIProvider,
        reconnect: bool,
    ) -> std::io::Result<()> {
        let _guard = self.writer.lock().await;
        let mut updated = (**self.providers.load()).clone();
        provider.oauth_generation = Uuid::new_v4();
        provider.oauth_rotation_id = None;
        if reconnect {
            let latest = updated.get_mut(&provider.id).ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotFound, "Account was removed")
            })?;
            if latest.provider_type != ProviderType::Mistral || !latest.mistral_subscription {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Account changed while signing in",
                ));
            }
            // A browser exchange can take minutes. Preserve settings changed
            // during that interval and never resurrect a deleted account.
            latest.api_key = provider.api_key.take();
            latest.oauth_generation = Uuid::new_v4();
            latest.oauth_rotation_id = None;
            latest.updated_at = provider.updated_at;
        } else {
            if updated.is_empty() {
                provider.is_default = true;
            }
            provider.oauth_generation = Uuid::new_v4();
            provider.oauth_rotation_id = None;
            updated.insert(provider.id, provider);
        }
        self.save_snapshot(&updated).await?;
        self.providers.store(Arc::new(updated));
        Ok(())
    }

    pub async fn add(&self, provider: AIProvider) -> Uuid {
        let id = provider.id;
        let _guard = self.writer.lock().await;
        let mut updated = (**self.providers.load()).clone();

        // If this is the first provider, make it default
        let is_first = updated.is_empty();
        let mut prov = provider;
        prov.oauth_generation = Uuid::new_v4();
        prov.oauth_rotation_id = None;
        if is_first {
            prov.is_default = true;
        }

        updated.insert(id, prov);
        self.publish_snapshot(updated).await;

        id
    }

    pub async fn update(&self, id: Uuid, mut provider: AIProvider) -> Option<AIProvider> {
        provider.updated_at = chrono::Utc::now();

        let _guard = self.writer.lock().await;
        let mut updated = (**self.providers.load()).clone();
        let existing = updated.get(&id)?;
        let oauth_changed = existing.oauth != provider.oauth
            || existing.provider_type != provider.provider_type
            || existing.cli_proxy_auth_file != provider.cli_proxy_auth_file
            || existing.rejected_oauth_refresh_fingerprint
                != provider.rejected_oauth_refresh_fingerprint
            || !provider.enabled;
        let existing_refresh = existing
            .oauth
            .as_ref()
            .map(|oauth| oauth.refresh_token.as_str());
        let replacement_refresh = provider
            .oauth
            .as_ref()
            .map(|oauth| oauth.refresh_token.as_str());
        if existing_refresh != replacement_refresh {
            provider.rejected_oauth_refresh_fingerprint = None;
        }
        if oauth_changed {
            provider.oauth_generation = Uuid::new_v4();
            provider.oauth_rotation_id = None;
        } else {
            provider.oauth_generation = existing.oauth_generation;
            provider.oauth_rotation_id = existing.oauth_rotation_id;
        }
        // If setting as default, unset others
        if provider.is_default {
            for p in updated.values_mut() {
                if p.id != id {
                    p.is_default = false;
                }
            }
        }
        updated.insert(id, provider.clone());
        self.publish_snapshot(updated).await.then_some(provider)
    }

    /// Set the routing order of one provider's accounts: `ids[0]` is tried
    /// first. Every id must exist and share one provider type. Accounts of
    /// that type left out keep their relative order after the listed ones.
    pub async fn reorder(&self, ids: &[Uuid]) -> Result<Vec<AIProvider>, String> {
        let _guard = self.writer.lock().await;
        let mut updated = (**self.providers.load()).clone();
        let mut kind = None;
        if ids.iter().collect::<std::collections::HashSet<_>>().len() != ids.len() {
            return Err("An account is listed twice".into());
        }
        for id in ids {
            let p = updated
                .get(id)
                .ok_or_else(|| format!("Unknown account {id}"))?;
            if *kind.get_or_insert(p.provider_type) != p.provider_type {
                return Err("Accounts belong to different providers".into());
            }
        }
        let Some(kind) = kind else {
            return Ok(vec![]);
        };
        let mut rest: Vec<Uuid> = {
            let mut r: Vec<&AIProvider> = updated
                .values()
                .filter(|p| p.provider_type == kind && !ids.contains(&p.id))
                .collect();
            r.sort_by_key(|p| (p.priority, p.id));
            r.into_iter().map(|p| p.id).collect()
        };
        let mut order: Vec<Uuid> = Vec::with_capacity(ids.len() + rest.len());
        order.extend_from_slice(ids);
        order.append(&mut rest);
        let now = chrono::Utc::now();
        let ordered: Vec<AIProvider> = order
            .iter()
            .enumerate()
            .filter_map(|(rank, id)| {
                let p = updated.get_mut(id)?;
                p.priority = rank as u32;
                p.updated_at = now;
                Some(p.clone())
            })
            .collect();
        if !self.publish_snapshot(updated).await {
            return Err("Failed to save AI providers to disk".into());
        }
        Ok(ordered)
    }

    pub async fn delete(&self, id: Uuid) -> bool {
        let _guard = self.writer.lock().await;
        let mut updated = (**self.providers.load()).clone();
        let existed = updated.remove(&id).is_some();

        if existed {
            return self.publish_snapshot(updated).await;
        }

        false
    }

    /// Set a provider as the default.
    pub async fn set_default(&self, id: Uuid) -> bool {
        let _guard = self.writer.lock().await;
        let mut updated = (**self.providers.load()).clone();

        if !updated.contains_key(&id) {
            return false;
        }

        for p in updated.values_mut() {
            p.is_default = p.id == id;
        }

        self.publish_snapshot(updated).await
    }

    /// Store a pending OAuth authorization.
    pub async fn set_pending_oauth(&self, id: Uuid, pending: PendingOAuth) {
        self.pending_oauth.insert(id, pending);
    }

    /// Get and remove a pending OAuth authorization.
    pub async fn take_pending_oauth(&self, id: Uuid) -> Option<PendingOAuth> {
        self.pending_oauth.remove(&id).map(|(_, v)| v)
    }

    pub(crate) async fn persist_oauth_credentials(
        &self,
        id: Uuid,
        expected_refresh_token: &str,
        expected_oauth_generation: Option<Uuid>,
        rotation_id: Uuid,
        credentials: OAuthCredentials,
    ) -> std::io::Result<Option<bool>> {
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();
        let Some(provider) = updated_map.get_mut(&id) else {
            return Ok(None);
        };
        if !provider.enabled {
            return Ok(None);
        }
        let Some(current) = provider.oauth.as_ref() else {
            return Ok(None);
        };
        if !rotation_id.is_nil()
            && provider.oauth_rotation_id == Some(rotation_id)
            && *current == credentials
        {
            match tokio::fs::read(&self.storage_path).await {
                Ok(bytes) => {
                    let persisted: Vec<AIProvider> = serde_json::from_slice(&bytes)
                        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                    if persisted.iter().any(|saved| {
                        saved.id == id
                            && saved.oauth_rotation_id == Some(rotation_id)
                            && saved.oauth.as_ref() == Some(&credentials)
                    }) {
                        return Ok(Some(false));
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                Err(err) => return Err(err),
            }
            self.save_snapshot(&updated_map).await?;
            self.providers.store(Arc::new(updated_map));
            return Ok(Some(true));
        }
        if current.refresh_token != expected_refresh_token {
            return Ok(None);
        }
        if expected_oauth_generation != Some(provider.oauth_generation)
            || expected_refresh_token.trim().is_empty()
        {
            return Ok(None);
        }
        provider.oauth = Some(credentials);
        provider.oauth_generation = rotation_id;
        provider.oauth_rotation_id = Some(rotation_id);
        provider.rejected_oauth_refresh_fingerprint = None;
        provider.status = ProviderStatus::Connected;
        provider.updated_at = chrono::Utc::now();
        self.save_snapshot(&updated_map).await?;
        self.providers.store(Arc::new(updated_map));
        Ok(Some(true))
    }

    /// Update a provider with OAuth credentials.
    pub async fn set_oauth_credentials(
        &self,
        id: Uuid,
        credentials: OAuthCredentials,
    ) -> Option<AIProvider> {
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();

        if let Some(provider) = updated_map.get_mut(&id) {
            provider.oauth = Some(credentials);
            provider.oauth_generation = Uuid::new_v4();
            provider.oauth_rotation_id = None;
            provider.rejected_oauth_refresh_fingerprint = None;
            provider.status = ProviderStatus::Connected;
            provider.updated_at = chrono::Utc::now();
            let updated = provider.clone();
            self.publish_snapshot(updated_map).await.then_some(updated)
        } else {
            None
        }
    }

    /// Persist or clear the fingerprint of a permanently rejected OAuth
    /// refresh token without retaining an additional plaintext credential.
    pub async fn set_rejected_oauth_refresh_fingerprint(
        &self,
        id: Uuid,
        fingerprint: Option<String>,
    ) -> Option<AIProvider> {
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();
        let provider = updated_map.get_mut(&id)?;
        provider.rejected_oauth_refresh_fingerprint = fingerprint;
        provider.oauth_generation = Uuid::new_v4();
        provider.oauth_rotation_id = None;
        provider.updated_at = chrono::Utc::now();
        let updated = provider.clone();
        self.publish_snapshot(updated_map).await.then_some(updated)
    }

    /// Update the provider's recorded organization ID (no-op when unchanged).
    ///
    /// Used by the usage probe to persist Anthropic's
    /// `anthropic-organization-id` once we've successfully talked to the
    /// upstream. Chain resolution uses this ID to group credential records
    /// under the same subscription so cooldowns are shared.
    pub async fn set_organization_id(
        &self,
        id: Uuid,
        organization_id: String,
    ) -> Option<AIProvider> {
        if let Some(existing) = self.providers.load().get(&id) {
            if existing.organization_id.as_deref() == Some(organization_id.as_str()) {
                return Some(existing.clone());
            }
        }
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();

        if let Some(provider) = updated_map.get_mut(&id) {
            if provider.organization_id.as_deref() == Some(organization_id.as_str()) {
                return Some(provider.clone());
            }
            provider.organization_id = Some(organization_id);
            provider.updated_at = chrono::Utc::now();
            let updated = provider.clone();
            self.publish_snapshot(updated_map).await.then_some(updated)
        } else {
            None
        }
    }

    /// Store (Some) or clear (None) the Mistral console usage session.
    pub async fn set_mistral_usage_session(
        &self,
        id: Uuid,
        session: Option<String>,
    ) -> Option<AIProvider> {
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();
        let provider = updated_map.get_mut(&id)?;
        provider.mistral_usage_session = session;
        provider.updated_at = chrono::Utc::now();
        let updated = provider.clone();
        self.publish_snapshot(updated_map).await.then_some(updated)
    }

    /// Update a provider with an API key.
    pub async fn set_api_key(&self, id: Uuid, api_key: String) -> Option<AIProvider> {
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();

        if let Some(provider) = updated_map.get_mut(&id) {
            provider.api_key = Some(api_key);
            provider.oauth_generation = Uuid::new_v4();
            provider.oauth_rotation_id = None;
            provider.status = ProviderStatus::Connected;
            provider.updated_at = chrono::Utc::now();
            let updated = provider.clone();
            self.publish_snapshot(updated_map).await.then_some(updated)
        } else {
            None
        }
    }

    /// Set provider status (e.g., to NeedsReauth when OAuth token is invalid)
    pub async fn set_status(&self, id: Uuid, status: ProviderStatus) -> Option<AIProvider> {
        let _guard = self.writer.lock().await;
        let mut updated_map = (**self.providers.load()).clone();

        if let Some(provider) = updated_map.get_mut(&id) {
            if !matches!(status, ProviderStatus::Connected | ProviderStatus::Unknown) {
                provider.oauth_generation = Uuid::new_v4();
                provider.oauth_rotation_id = None;
            }
            provider.status = status;
            provider.updated_at = chrono::Utc::now();
            let updated = provider.clone();
            self.publish_snapshot(updated_map).await.then_some(updated)
        } else {
            None
        }
    }
}

/// Shared store type.
pub type SharedAIProviderStore = Arc<AIProviderStore>;

#[cfg(test)]
mod tests {
    use super::*;

    fn oauth(access: &str, refresh: &str, expires_at: i64) -> OAuthCredentials {
        OAuthCredentials {
            access_token: access.into(),
            refresh_token: refresh.into(),
            expires_at,
        }
    }

    #[tokio::test]
    async fn oauth_mutations_rotate_generation_and_fence_stale_rotations() {
        let dir = tempfile::tempdir().unwrap();
        let storage_path = dir.path().join("ai_providers.json");
        let store = AIProviderStore::new(storage_path.clone()).await;
        let mut provider = AIProvider::new(ProviderType::Anthropic, "Primary".into());
        provider.oauth = Some(oauth("access-0", "refresh-0", 100));
        let id = store.add(provider).await;

        let gen_0 = store.get(id).await.unwrap().oauth_generation;
        assert!(!gen_0.is_nil());

        let updated = store
            .set_oauth_credentials(id, oauth("access-1", "refresh-0", 200))
            .await
            .unwrap();
        assert_ne!(updated.oauth_generation, gen_0);
        assert_eq!(updated.oauth_rotation_id, None);

        assert_eq!(
            store
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(gen_0),
                    Uuid::new_v4(),
                    oauth("stale-access", "refresh-1", 150),
                )
                .await
                .unwrap(),
            None
        );

        let mut same_name = store.get(id).await.unwrap();
        same_name.name = "Renamed".into();
        let after_rename = store.update(id, same_name).await.unwrap();
        assert_eq!(after_rename.oauth_generation, updated.oauth_generation);

        let mut same_refresh_update = after_rename.clone();
        same_refresh_update.oauth = Some(oauth("access-2", "refresh-0", 300));
        let after_oauth_update = store.update(id, same_refresh_update).await.unwrap();
        assert_ne!(
            after_oauth_update.oauth_generation,
            after_rename.oauth_generation
        );

        let rotation_id = Uuid::new_v4();
        let rotated_creds = oauth("access-3", "refresh-1", 400);
        assert_eq!(
            store
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(after_oauth_update.oauth_generation),
                    rotation_id,
                    rotated_creds.clone(),
                )
                .await
                .unwrap(),
            Some(true)
        );
        assert_eq!(
            store
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(after_oauth_update.oauth_generation),
                    rotation_id,
                    rotated_creds.clone(),
                )
                .await
                .unwrap(),
            Some(false)
        );

        let reloaded = AIProviderStore::new(storage_path).await;
        let reloaded_provider = reloaded.get(id).await.unwrap();
        assert_eq!(reloaded_provider.oauth, Some(rotated_creds.clone()));
        assert_eq!(reloaded_provider.oauth_rotation_id, Some(rotation_id));
        assert_eq!(
            reloaded
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(after_oauth_update.oauth_generation),
                    rotation_id,
                    rotated_creds,
                )
                .await
                .unwrap(),
            Some(false)
        );
    }

    #[tokio::test]
    async fn delete_disable_and_reauth_status_invalidate_pending_rotations() {
        let dir = tempfile::tempdir().unwrap();
        let store = AIProviderStore::new(dir.path().join("ai_providers.json")).await;
        let mut provider = AIProvider::new(ProviderType::Anthropic, "Account".into());
        provider.oauth = Some(oauth("access-0", "refresh-0", 100));
        let id = store.add(provider).await;

        let gen_0 = store.get(id).await.unwrap().oauth_generation;
        store
            .set_status(id, ProviderStatus::NeedsReauth("invalid_grant".into()))
            .await
            .unwrap();
        assert_eq!(
            store
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(gen_0),
                    Uuid::new_v4(),
                    oauth("access-1", "refresh-1", 200),
                )
                .await
                .unwrap(),
            None
        );

        let mut disabled = store.get(id).await.unwrap();
        let gen_1 = disabled.oauth_generation;
        disabled.enabled = false;
        store.update(id, disabled).await.unwrap();
        assert_eq!(
            store
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(gen_1),
                    Uuid::new_v4(),
                    oauth("access-2", "refresh-2", 300),
                )
                .await
                .unwrap(),
            None
        );

        assert!(store.delete(id).await);
        assert_eq!(
            store
                .persist_oauth_credentials(
                    id,
                    "refresh-0",
                    Some(gen_1),
                    Uuid::new_v4(),
                    oauth("access-3", "refresh-3", 400),
                )
                .await
                .unwrap(),
            None
        );
    }
}
