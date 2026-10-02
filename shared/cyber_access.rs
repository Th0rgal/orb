//! Explicit selections never grant provider access.
use serde::{Deserialize, Serialize};
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
        let model = model.rsplit('/').next().unwrap_or(model);
        match self {
            Self::Automatic => Ok(None),
            Self::Standard if model.starts_with("gpt-daybreak-") || model == "gpt-5.6-cyber" => Err("This model requires Daybreak. Choose Automatic or Daybreak, or select a general-purpose model.".into()),
            Self::Standard => Ok(Some("standard")),
            Self::Daybreak => match model {
                "gpt-daybreak-blue-latest" | "gpt-6-sol" | "gpt-6.1-sol" | "gpt-6-astra" | "gpt-5.6-sol" => Ok(Some("daybreak_blue")),
                "gpt-daybreak-red-latest" | "gpt-5.6-cyber" => Ok(Some("daybreak_red")),
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
