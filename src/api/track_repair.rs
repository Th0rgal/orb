//! One-off, idempotent data repair: missions whose track is ANOTHER mission's
//! generated key (`mission-<8hex>` not derived from their own id).
//!
//! Older continuation/replacement paths copied the source mission's generated
//! track onto the new mission, so two missions shared one auto track and the
//! second inherited (or fought over) the first one's writer lease. Each
//! affected non-active mission is moved to its own generated key and its live
//! leases follow it. Running the repair twice changes nothing the second time.

use std::sync::Arc;

use serde::Serialize;
use uuid::Uuid;

use super::control::MissionStatus;
use super::mission_store::{MissionProjectPatch, MissionStore};
use super::projects_store::ProjectsStore;
use super::track_leases::{generated_track_key, lease_request};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TrackRepair {
    pub mission_id: Uuid,
    pub project: Option<String>,
    pub from_track: String,
    pub to_track: String,
    /// Lease modes moved from the borrowed track to the mission's own track.
    pub leases_moved: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct TrackRepairReport {
    pub dry_run: bool,
    pub scanned: usize,
    pub skipped_active: usize,
    pub repairs: Vec<TrackRepair>,
}

/// `mission-<8 lowercase hex>`: the shape of [`generated_track_key`].
pub fn is_generated_track_key(track: &str) -> bool {
    track
        .strip_prefix("mission-")
        .is_some_and(|hex| hex.len() == 8 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// The key a mission should own when its track is a borrowed generated key.
pub fn borrowed_generated_track(mission_id: Uuid, track: Option<&str>) -> Option<String> {
    let track = track?.trim();
    let own = generated_track_key(&mission_id.to_string());
    (is_generated_track_key(track) && !track.eq_ignore_ascii_case(&own)).then_some(own)
}

pub async fn repair_borrowed_generated_tracks(
    projects: &ProjectsStore,
    missions: &Arc<dyn MissionStore>,
    dry_run: bool,
) -> Result<TrackRepairReport, String> {
    const PAGE: usize = 200;
    let mut all = Vec::new();
    let mut offset = 0;
    loop {
        let page = missions.list_missions(PAGE, offset).await?;
        let len = page.len();
        all.extend(page);
        if len < PAGE {
            break;
        }
        offset += len;
    }
    let mut report = TrackRepairReport {
        dry_run,
        scanned: all.len(),
        ..Default::default()
    };
    for mission in all {
        let Some(own) = borrowed_generated_track(mission.id, mission.project.track.as_deref())
        else {
            continue;
        };
        let from = mission.project.track.clone().unwrap_or_default();
        // Never move a mission that may be executing: its runner, remote job
        // and lease renewals all name the current track.
        if mission.status == MissionStatus::Active
            || missions.get_active_mission_run(mission.id).await?.is_some()
        {
            report.skipped_active += 1;
            tracing::info!(mission_id = %mission.id, track = %from, "track repair skipped an active mission");
            continue;
        }
        let attempt = mission.id.to_string();
        let slug = mission.project.project.clone();
        let held: Vec<String> = match slug.as_deref() {
            Some(slug) => projects
                .live_leases(Some(slug))?
                .into_iter()
                .filter(|lease| lease.attempt_id == attempt && lease.track == from)
                .map(|lease| lease.mode)
                .collect(),
            None => Vec::new(),
        };
        let mut repair = TrackRepair {
            mission_id: mission.id,
            project: slug.clone(),
            from_track: from.clone(),
            to_track: own.clone(),
            leases_moved: held.clone(),
            error: None,
        };
        if !dry_run {
            if let Err(error) =
                apply(projects, missions, mission.id, slug.as_deref(), &own, &held).await
            {
                repair.error = Some(error);
            }
            tracing::info!(
                mission_id = %mission.id,
                from = %from,
                to = %own,
                leases = ?held,
                error = ?repair.error,
                "track repair reassigned borrowed generated track"
            );
        }
        report.repairs.push(repair);
    }
    Ok(report)
}

async fn apply(
    projects: &ProjectsStore,
    missions: &Arc<dyn MissionStore>,
    id: Uuid,
    slug: Option<&str>,
    own: &str,
    held: &[String],
) -> Result<(), String> {
    let attempt = id.to_string();
    if let Some(slug) = slug {
        projects.absorb_track(slug, own, None, None)?;
        // Acquire on the own track before releasing the borrowed one, so the
        // mission is never left without the claim it held.
        for mode in held {
            projects
                .acquire_track_lease(&lease_request(slug, own, &attempt, mode, None))
                .map_err(|error| format!("lease move failed: {error:?}"))?;
        }
        projects.release_leases_except(&attempt, slug, own)?;
    }
    missions
        .update_mission_project(
            id,
            MissionProjectPatch {
                preserve_updated_at: true,
                track: Some(Some(own.to_string())),
                ..Default::default()
            },
        )
        .await
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mission_store::InMemoryMissionStore;

    #[test]
    fn recognises_only_foreign_generated_keys() {
        let id = Uuid::parse_str("9304baf4-0000-4000-8000-000000000000").unwrap();
        assert_eq!(borrowed_generated_track(id, Some("mission-9304baf4")), None);
        assert_eq!(borrowed_generated_track(id, Some("trio-reserve1")), None);
        assert_eq!(borrowed_generated_track(id, Some("mission-xyz")), None);
        assert_eq!(borrowed_generated_track(id, None), None);
        assert_eq!(
            borrowed_generated_track(id, Some("mission-deadbeef")).as_deref(),
            Some("mission-9304baf4")
        );
    }

    #[tokio::test]
    async fn repair_moves_track_and_leases_and_is_idempotent() {
        let missions: Arc<dyn MissionStore> = Arc::new(InMemoryMissionStore::new());
        let projects = ProjectsStore::open_in_memory().unwrap();
        let source = missions
            .create_mission(None, None, None, None, None, Some("codex"), None)
            .await
            .unwrap();
        let borrowed = generated_track_key(&source.id.to_string());
        let make = |status| {
            let missions = missions.clone();
            let borrowed = borrowed.clone();
            async move {
                let m = missions
                    .create_mission(None, None, None, None, None, Some("codex"), None)
                    .await
                    .unwrap();
                missions
                    .update_mission_project(
                        m.id,
                        MissionProjectPatch {
                            project: Some(Some("lido".into())),
                            track: Some(Some(borrowed)),
                            ..Default::default()
                        },
                    )
                    .await
                    .unwrap();
                missions.update_mission_status(m.id, status).await.unwrap();
                m
            }
        };
        let finished = make(MissionStatus::Interrupted).await;
        let running = make(MissionStatus::Active).await;
        projects
            .absorb_track("lido", &borrowed, None, None)
            .unwrap();
        projects
            .acquire_track_lease(&lease_request(
                "lido",
                &borrowed,
                &finished.id.to_string(),
                "writer",
                None,
            ))
            .unwrap();

        let preview = repair_borrowed_generated_tracks(&projects, &missions, true)
            .await
            .unwrap();
        assert_eq!(preview.repairs.len(), 1);
        assert_eq!(preview.skipped_active, 1);
        assert_eq!(
            missions
                .get_mission(finished.id)
                .await
                .unwrap()
                .unwrap()
                .project
                .track,
            Some(borrowed.clone()),
            "dry run changes nothing"
        );

        let report = repair_borrowed_generated_tracks(&projects, &missions, false)
            .await
            .unwrap();
        let own = generated_track_key(&finished.id.to_string());
        assert_eq!(report.repairs.len(), 1);
        assert_eq!(report.repairs[0].mission_id, finished.id);
        assert_eq!(report.repairs[0].to_track, own);
        assert_eq!(report.repairs[0].leases_moved, vec!["writer".to_string()]);
        assert!(report.repairs[0].error.is_none());
        let repaired = missions.get_mission(finished.id).await.unwrap().unwrap();
        assert_eq!(repaired.project.track.as_deref(), Some(own.as_str()));
        let leases = projects.live_leases(Some("lido")).unwrap();
        let mine: Vec<_> = leases
            .iter()
            .filter(|l| l.attempt_id == finished.id.to_string())
            .collect();
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].track, own);
        assert_eq!(mine[0].mode, "writer");
        // The active mission is untouched.
        assert_eq!(
            missions
                .get_mission(running.id)
                .await
                .unwrap()
                .unwrap()
                .project
                .track,
            Some(borrowed)
        );
        // Idempotent.
        let again = repair_borrowed_generated_tracks(&projects, &missions, false)
            .await
            .unwrap();
        assert!(again.repairs.is_empty());
        assert_eq!(projects.live_leases(Some("lido")).unwrap().len(), 1);
    }
}
