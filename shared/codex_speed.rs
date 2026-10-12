//! Requested Codex service tier, independent of reasoning effort.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tier {
    #[default]
    Standard,
    Fast,
    Ultrafast,
}

impl Tier {
    pub fn id(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Fast => "fast",
            Self::Ultrafast => "ultrafast",
        }
    }

    pub fn wire(self) -> &'static str {
        match self {
            Self::Standard => "default",
            Self::Fast => "priority",
            Self::Ultrafast => "ultrafast",
        }
    }

    pub fn from_legacy(explicit: Option<Self>, fast_mode: bool) -> Self {
        explicit.unwrap_or(if fast_mode {
            Self::Fast
        } else {
            Self::Standard
        })
    }

    pub fn supports_model(self, model: &str) -> bool {
        let model = model.rsplit('/').next().unwrap_or(model);
        match self {
            Self::Standard => true,
            Self::Fast => ["gpt-6.1", "gpt-6", "gpt-5.6", "gpt-5.5", "gpt-5.4"]
                .iter()
                .any(|prefix| model == *prefix || model.starts_with(&format!("{prefix}-"))),
            Self::Ultrafast => matches!(model, "gpt-6-astra" | "gpt-6.1-sol"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_standard_overrides_legacy_fast_and_ultrafast_is_distinct() {
        assert_eq!(Tier::from_legacy(None, true), Tier::Fast);
        assert_eq!(
            Tier::from_legacy(Some(Tier::Standard), true),
            Tier::Standard
        );
        assert_eq!(
            Tier::from_legacy(Some(Tier::Ultrafast), true).wire(),
            "ultrafast"
        );
        assert!(Tier::Ultrafast.supports_model("openai/gpt-6.1-sol"));
        assert!(!Tier::Ultrafast.supports_model("gpt-6-luna"));
    }
}

/// An account-specific catalog is capability evidence; a model name or an
/// ambiguous `pro` plan alone cannot grant Ultrafast.
pub fn catalog_advertises(catalog: &serde_json::Value, model: &str, tier: Tier) -> bool {
    let model = model.rsplit('/').next().unwrap_or(model);
    let rows = catalog
        .get("models")
        .or_else(|| catalog.get("data"))
        .and_then(|v| v.as_array());
    rows.into_iter().flatten().any(|entry| {
        let id = entry
            .get("slug")
            .or_else(|| entry.get("model"))
            .or_else(|| entry.get("id"))
            .and_then(|v| v.as_str());
        id == Some(model)
            && entry
                .get("service_tiers")
                .or_else(|| entry.get("serviceTiers"))
                .and_then(|v| v.as_array())
                .is_some_and(|tiers| {
                    tiers.iter().any(|v| {
                        v.as_str().or_else(|| v.get("id").and_then(|v| v.as_str()))
                            == Some(tier.wire())
                            || (tier == Tier::Fast
                                && v.as_str().or_else(|| v.get("id").and_then(|v| v.as_str()))
                                    == Some("fast"))
                    })
                })
    })
}

pub fn eligible_ultrafast_plan(plan: Option<&str>) -> bool {
    matches!(
        plan,
        Some(
            "promax"
                | "enterprise_cbp_usage_based"
                | "enterprise_cbp_automation"
                | "ent26"
                | "edu_plus"
                | "edu_pro"
        )
    )
}
