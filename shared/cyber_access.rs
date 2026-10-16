//! Explicit selections never grant provider access.
use serde::{Deserialize, Serialize};
/// OpenAI retired these Daybreak aliases on 2026-10-28; the underlying models remain.
pub fn retired_alias_error(model: &str) -> Option<String> {
    let model = model.rsplit('/').next().unwrap_or(model);
    let replacement = match model {
        "gpt-daybreak-blue-latest" => {
            "a specific Daybreak Blue model such as gpt-6.1-sol with Cyber Access set to Daybreak"
        }
        "gpt-daybreak-red-latest" => "a specific Daybreak Red model such as gpt-5.6-cyber",
        _ => return None,
    };
    Some(format!(
        "OpenAI retired the '{model}' alias on 2026-10-28. Select {replacement}."
    ))
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Standard,
    Daybreak,
    #[default]
    Automatic,
}
impl Mode {
    pub fn program(self, model: &str) -> Result<Option<&'static str>, String> {
        if let Some(error) = retired_alias_error(model) {
            return Err(error);
        }
        let model = model.rsplit('/').next().unwrap_or(model);
        match self {
            Self::Automatic => Ok(None),
            Self::Standard if model.starts_with("gpt-daybreak-") || model == "gpt-5.6-cyber" => Err("This model requires Daybreak. Choose Automatic or Daybreak, or select a general-purpose model.".into()),
            Self::Standard => Ok(Some("standard")),
            Self::Daybreak => match model {
                "gpt-6-sol" | "gpt-6.1-sol" | "gpt-6-astra" | "gpt-5.6-sol" => Ok(Some("daybreak_blue")),
                "gpt-5.6-cyber" => Ok(Some("daybreak_red")),
                _ => Err("Daybreak compatibility is not known for this model. Keep the model and choose Standard or Automatic.".into()),
            },
        }
    }
    pub fn native(self, model: &str) -> Result<Option<&'static str>, String> {
        Ok(self.program(model)?.map(|p| match p {
            "daybreak_blue" => "daybreakBlue",
            "daybreak_red" => "daybreakRed",
            _ => "standard",
        }))
    }
}
