//! Usage attribution: who every routed LLM request is billed to.
//!
//! The caller kind is derived server-side from the authenticated credential
//! (the *principal*); client headers are hints that may only refine it
//! inside the principal's scope. The decision itself is the verified kernel
//! `orb_attribution_step` (`lean/Orb/Kernel.lean`); this module gathers its
//! inputs. See `docs/specs/usage-attribution.md`.
use axum::http::HeaderMap;
use std::collections::HashMap;
use std::sync::Mutex;
use uuid::Uuid;

pub use crate::orb_spec::CallerKind;

/// Client hint header: `core:<purpose>`, or a caller kind (`hermes`,
/// `orb_ui`, `script`). Never trusted outside the principal's scope.
pub const CALLER_HEADER: &str = "x-sandboxed-caller";

/// Key-name prefixes Core mints for bound principals. User-created keys may
/// not use them (see `proxy_keys::create_key`).
pub const REMOTE_LAUNCH_KEY_PREFIX: &str = "remote-launch:";
pub const HERMES_KEY_PREFIX: &str = "Hermes Assistant";

/// Why Core itself called a model. Every Core-internal LLM call names one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorePurpose {
    /// Mission title and short description (`metadata_llm`).
    MissionTitle,
    /// Inbox digest (`ask::inbox`).
    InboxSummary,
    /// The Orb assistant ("Ask").
    Ask,
    /// Side question about a mission (`ask::btw`).
    Btw,
}

impl CorePurpose {
    pub const ALL: [Self; 4] = [Self::MissionTitle, Self::InboxSummary, Self::Ask, Self::Btw];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::MissionTitle => "mission_title",
            Self::InboxSummary => "inbox_summary",
            Self::Ask => "ask",
            Self::Btw => "btw",
        }
    }

    /// Value of [`CALLER_HEADER`] for this purpose.
    pub fn header_value(self) -> String {
        format!("core:{}", self.as_str())
    }

    fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.as_str() == raw)
    }
}

/// Purpose recorded for a Core call that did not name one.
pub const UNSPECIFIED_PURPOSE: &str = "unspecified";

/// What the authenticated credential is bound to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Principal {
    pub kind: CallerKind,
    pub mission: Option<Uuid>,
}

/// Principal of a request: the internal proxy secret is Core, a
/// `remote-launch:<mission>` key is that mission, a Hermes key is Hermes,
/// any other key is a script. No credential is `unknown`.
pub fn principal_for(key_name: Option<&str>, internal_secret: bool) -> Principal {
    if internal_secret {
        return Principal {
            kind: CallerKind::Core,
            mission: None,
        };
    }
    let Some(name) = key_name else {
        return Principal {
            kind: CallerKind::Unknown,
            mission: None,
        };
    };
    if let Some(mission) = name
        .strip_prefix(REMOTE_LAUNCH_KEY_PREFIX)
        .and_then(|id| Uuid::parse_str(id).ok())
    {
        return Principal {
            kind: CallerKind::Mission,
            mission: Some(mission),
        };
    }
    let kind = if name.starts_with(HERMES_KEY_PREFIX) {
        CallerKind::Hermes
    } else {
        CallerKind::Script
    };
    Principal {
        kind,
        mission: None,
    }
}

/// Client-supplied attribution hints.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Hint {
    pub mission: Option<Uuid>,
    pub kind: Option<CallerKind>,
    pub purpose: Option<CorePurpose>,
}

pub fn hint_from(headers: &HeaderMap) -> Hint {
    let mission = headers
        .get(crate::api::proxy_liveness::MISSION_ID_HEADER)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| Uuid::parse_str(v.trim()).ok());
    let caller = headers
        .get(CALLER_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let (kind, purpose) = match caller.split_once(':') {
        Some(("core", purpose)) => (Some(CallerKind::Core), CorePurpose::parse(purpose)),
        _ => (
            match caller.as_str() {
                "core" => Some(CallerKind::Core),
                "hermes" => Some(CallerKind::Hermes),
                "orb_ui" => Some(CallerKind::OrbUi),
                "script" => Some(CallerKind::Script),
                _ => None,
            },
            None,
        ),
    };
    Hint {
        mission,
        kind,
        purpose,
    }
}

/// Final attribution of one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub kind: CallerKind,
    pub mission_id: Option<Uuid>,
    /// `core` calls only: the named purpose, or [`UNSPECIFIED_PURPOSE`].
    pub purpose: Option<String>,
    /// False when a hint was outside the principal's scope (it was ignored).
    pub accepted: bool,
}

/// Decide attribution. `principal_chain` / `hint_chain` are the ancestry of
/// the principal's and the hinted mission (the mission first, then its
/// parent, ...); empty when unknown.
pub fn resolve(
    principal: Principal,
    principal_chain: &[Uuid],
    hint: &Hint,
    hint_chain: &[Uuid],
) -> Resolved {
    // A mission-bound credential whose mission has a parent is a subagent.
    let principal_kind = match principal.kind {
        CallerKind::Mission if principal_chain.len() > 1 => CallerKind::Subagent,
        kind => kind,
    };
    let (claimed, same_mission, descends) = match hint.mission {
        Some(mission) => (
            Some(if hint_chain.len() > 1 {
                CallerKind::Subagent
            } else {
                CallerKind::Mission
            }),
            principal.mission == Some(mission),
            principal.mission.is_some_and(|m| hint_chain.contains(&m)),
        ),
        None => (hint.kind, false, false),
    };
    let verdict =
        crate::orb_spec::attribution_step(principal_kind, claimed, same_mission, descends);
    let mission_id = match (verdict.accepted, hint.mission) {
        (true, Some(mission)) => Some(mission),
        _ => principal.mission,
    };
    let purpose = (verdict.kind == CallerKind::Core).then(|| {
        hint.purpose
            .filter(|_| verdict.accepted)
            .map_or(UNSPECIFIED_PURPOSE, CorePurpose::as_str)
            .to_string()
    });
    Resolved {
        kind: verdict.kind,
        mission_id,
        purpose,
        accepted: verdict.accepted,
    }
}

/// Mission parents never change, so they are cached for the proxy hot path.
static PARENTS: Mutex<Option<HashMap<Uuid, Option<Uuid>>>> = Mutex::new(None);
const PARENT_CACHE_MAX: usize = 4096;
const MAX_DEPTH: usize = 16;

/// `mission`, its parent, grandparent, ... (bounded, cycle-safe). Empty when
/// the mission is unknown to the store.
pub async fn ancestry(
    store: &dyn crate::api::mission_store::MissionStore,
    mission: Uuid,
) -> Vec<Uuid> {
    let mut chain = Vec::new();
    let mut current = Some(mission);
    while let Some(id) = current {
        if chain.len() >= MAX_DEPTH || chain.contains(&id) {
            break;
        }
        let cached = PARENTS
            .lock()
            .ok()
            .and_then(|g| g.as_ref().and_then(|m| m.get(&id).copied()));
        let parent = match cached {
            Some(parent) => parent,
            None => match store.get_mission(id).await {
                Ok(Some(m)) => {
                    if let Ok(mut guard) = PARENTS.lock() {
                        let map = guard.get_or_insert_with(HashMap::new);
                        if map.len() >= PARENT_CACHE_MAX {
                            map.clear();
                        }
                        map.insert(id, m.parent_mission_id);
                    }
                    m.parent_mission_id
                }
                _ => {
                    // Unknown mission: keep what we have (nothing for the root).
                    if chain.is_empty() {
                        return chain;
                    }
                    break;
                }
            },
        };
        chain.push(id);
        current = parent;
    }
    chain
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(
                axum::http::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                v.parse().unwrap(),
            );
        }
        h
    }

    #[test]
    fn principal_comes_from_the_credential() {
        let m = Uuid::new_v4();
        assert_eq!(principal_for(None, true).kind, CallerKind::Core);
        assert_eq!(principal_for(None, false).kind, CallerKind::Unknown);
        let p = principal_for(Some(&format!("remote-launch:{m}")), false);
        assert_eq!((p.kind, p.mission), (CallerKind::Mission, Some(m)));
        assert_eq!(
            principal_for(Some("Hermes Assistant (prod)"), false).kind,
            CallerKind::Hermes
        );
        assert_eq!(
            principal_for(Some("my-ide"), false).kind,
            CallerKind::Script
        );
        // A malformed launch key is just a script key, never a mission.
        assert_eq!(
            principal_for(Some("remote-launch:nope"), false).kind,
            CallerKind::Script
        );
    }

    #[test]
    fn core_mission_header_attributes_to_the_mission() {
        // The Snark.fast case: internal secret + mission header used to log
        // an empty caller.
        let m = Uuid::new_v4();
        let h = hint_from(&headers(&[("x-sandboxed-mission-id", &m.to_string())]));
        let r = resolve(principal_for(None, true), &[], &h, &[m]);
        assert_eq!(
            (r.kind, r.mission_id, r.accepted),
            (CallerKind::Mission, Some(m), true)
        );
        let parent = Uuid::new_v4();
        let r = resolve(principal_for(None, true), &[], &h, &[m, parent]);
        assert_eq!(r.kind, CallerKind::Subagent);
    }

    #[test]
    fn core_calls_carry_a_purpose() {
        let h = hint_from(&headers(&[(CALLER_HEADER, "core:mission_title")]));
        let r = resolve(principal_for(None, true), &[], &h, &[]);
        assert_eq!(r.kind, CallerKind::Core);
        assert_eq!(r.purpose.as_deref(), Some("mission_title"));
        let r = resolve(principal_for(None, true), &[], &Hint::default(), &[]);
        assert_eq!(r.purpose.as_deref(), Some(UNSPECIFIED_PURPOSE));
    }

    #[test]
    fn forged_hints_are_rejected_and_keep_the_principal() {
        let launch = Uuid::new_v4();
        let other = Uuid::new_v4();
        let key = format!("remote-launch:{launch}");
        // A launch key cannot bill another mission.
        let h = hint_from(&headers(&[("x-sandboxed-mission-id", &other.to_string())]));
        let r = resolve(principal_for(Some(&key), false), &[launch], &h, &[other]);
        assert_eq!(
            (r.kind, r.mission_id, r.accepted),
            (CallerKind::Mission, Some(launch), false)
        );
        // ...but may claim its own subagent.
        let r = resolve(
            principal_for(Some(&key), false),
            &[launch],
            &h,
            &[other, launch],
        );
        assert_eq!(
            (r.kind, r.mission_id, r.accepted),
            (CallerKind::Subagent, Some(other), true)
        );
        // A script key cannot claim a mission, Core, or Hermes.
        let r = resolve(principal_for(Some("ide"), false), &[], &h, &[other]);
        assert_eq!(
            (r.kind, r.mission_id, r.accepted),
            (CallerKind::Script, None, false)
        );
        let h = hint_from(&headers(&[(CALLER_HEADER, "core:ask")]));
        let r = resolve(principal_for(Some("ide"), false), &[], &h, &[]);
        assert_eq!(
            (r.kind, r.purpose, r.accepted),
            (CallerKind::Script, None, false)
        );
        let h = hint_from(&headers(&[(CALLER_HEADER, "hermes")]));
        let r = resolve(principal_for(Some("ide"), false), &[], &h, &[]);
        assert_eq!(r.kind, CallerKind::Script);
    }
}
