//! What Core last confirmed about a synchronized local-origin mission.
//! The journal snapshot stays the wire payload; this overlay only corrects
//! what Orb shows before Core can be reached again.
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq, Eq)]
pub struct Confirmed {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub deleted: bool,
    /// Client clock, in milliseconds, when the confirming request started.
    pub observed_at: u64,
}
#[derive(Deserialize, Clone, Debug)]
pub struct Confirmation {
    pub id: String,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub deleted: bool,
    pub observed_at: u64,
}
impl Confirmation {
    pub fn validate(&self) -> Result<(), String> {
        if self.status.as_deref().is_some_and(|s| {
            s.is_empty() || s.len() > 32 || !s.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
        }) {
            return Err("Invalid confirmed status".into());
        }
        if self
            .title
            .as_deref()
            .is_some_and(|t| t.chars().count() > 512 || t.chars().any(char::is_control))
        {
            return Err("Invalid confirmed title".into());
        }
        Ok(())
    }
}
/// Returns whether the overlay changed. Unsynchronized local work is never
/// overruled, and an answer observed earlier never replaces a later one. A
/// saved observation from the future (the clock was set back) cannot block
/// every later answer.
pub fn merge(
    current: &mut Option<Confirmed>,
    local_pending: bool,
    incoming: &Confirmation,
    now: u64,
) -> bool {
    if local_pending || (incoming.status.is_none() && incoming.title.is_none() && !incoming.deleted)
    {
        return false;
    }
    let mut next = current.clone().unwrap_or_default();
    if current.is_some() && next.observed_at <= now && incoming.observed_at <= next.observed_at {
        return false;
    }
    if incoming.status.is_some() {
        next.status = incoming.status.clone();
    }
    if incoming.title.is_some() {
        next.title = incoming.title.clone();
    }
    if incoming.deleted {
        next.deleted = true;
    }
    next.observed_at = incoming.observed_at;
    *current = Some(next);
    true
}
/// Status and title to show for a journal record.
pub fn shown(
    confirmed: Option<&Confirmed>,
    local_pending: bool,
    status: &str,
    title: &str,
) -> (String, String) {
    match confirmed.filter(|_| !local_pending) {
        Some(c) => (
            c.status.clone().unwrap_or_else(|| status.into()),
            c.title.clone().unwrap_or_else(|| title.into()),
        ),
        None => (status.into(), title.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn confirm(status: Option<&str>, title: Option<&str>, at: u64) -> Confirmation {
        Confirmation {
            id: "id".into(),
            status: status.map(Into::into),
            title: title.map(Into::into),
            deleted: false,
            observed_at: at,
        }
    }
    #[test]
    fn confirmed_deletion_persists_once_synchronized() {
        let mut saved = None;
        let del = Confirmation {
            id: "id".into(),
            status: None,
            title: None,
            deleted: true,
            observed_at: 15,
        };
        assert!(!merge(&mut saved, true, &del, 100));
        assert!(merge(&mut saved, false, &del, 100));
        assert!(saved.unwrap().deleted);
    }
    #[test]
    fn archive_restore_and_title_survive_a_restart() {
        let mut saved = None;
        assert!(merge(
            &mut saved,
            false,
            &confirm(Some("acknowledged"), None, 10),
            100
        ));
        assert!(merge(
            &mut saved,
            false,
            &confirm(None, Some("Renamed"), 11),
            100
        ));
        let restored: Option<Confirmed> =
            serde_json::from_str(&serde_json::to_string(&saved).unwrap()).unwrap();
        assert_eq!(
            shown(restored.as_ref(), false, "awaiting_user", "Draft"),
            ("acknowledged".into(), "Renamed".into())
        );
        assert!(merge(
            &mut saved,
            false,
            &confirm(Some("paused"), None, 12),
            100
        ));
        assert_eq!(
            shown(saved.as_ref(), false, "awaiting_user", "Draft"),
            ("paused".into(), "Renamed".into())
        );
    }
    #[test]
    fn an_older_answer_never_replaces_a_newer_state() {
        let mut saved = None;
        assert!(merge(
            &mut saved,
            false,
            &confirm(Some("acknowledged"), None, 20),
            100
        ));
        assert!(!merge(
            &mut saved,
            false,
            &confirm(Some("awaiting_user"), None, 19),
            100
        ));
        assert!(!merge(
            &mut saved,
            false,
            &confirm(Some("awaiting_user"), None, 20),
            100
        ));
        assert_eq!(saved.unwrap().status.as_deref(), Some("acknowledged"));
    }
    #[test]
    fn a_clock_set_back_does_not_freeze_the_saved_state() {
        let mut saved = None;
        assert!(merge(
            &mut saved,
            false,
            &confirm(Some("acknowledged"), None, 5_000),
            5_000
        ));
        assert!(merge(
            &mut saved,
            false,
            &confirm(Some("paused"), None, 90),
            100
        ));
        assert_eq!(saved.unwrap().status.as_deref(), Some("paused"));
    }
    #[test]
    fn unsynchronized_local_work_keeps_its_own_state() {
        let mut saved = Some(Confirmed {
            status: Some("acknowledged".into()),
            title: None,
            deleted: false,
            observed_at: 5,
        });
        assert!(!merge(
            &mut saved,
            true,
            &confirm(Some("completed"), None, 9),
            100
        ));
        assert_eq!(
            shown(saved.as_ref(), true, "active", "Local"),
            ("active".into(), "Local".into())
        );
    }
    #[test]
    fn rejects_values_core_would_not_send() {
        assert!(confirm(Some("Archived!"), None, 1).validate().is_err());
        assert!(confirm(None, Some("a\nb"), 1).validate().is_err());
        assert!(confirm(Some("acknowledged"), Some("Title"), 1)
            .validate()
            .is_ok());
        let mut saved = None;
        assert!(!merge(&mut saved, false, &confirm(None, None, 1), 100));
    }
}
