//! Durable job store for the `sandboxed-node` runner.
//!
//! Jobs live in a small SQLite database at `<workdir>/jobs.db` so job state
//! survives node restarts. All rusqlite calls run under
//! `tokio::task::spawn_blocking`.

use std::path::Path;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension, Row};
use uuid::Uuid;

/// Lifecycle state of a node job.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    /// The node restarted while the job was queued or running; its process
    /// (if any) is gone and its true outcome is unknown.
    Lost,
}

impl JobState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Lost => "lost",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "queued" => Self::Queued,
            "running" => Self::Running,
            "succeeded" => Self::Succeeded,
            "failed" => Self::Failed,
            "cancelled" => Self::Cancelled,
            "lost" => Self::Lost,
            _ => return None,
        })
    }

    pub fn is_terminal(&self) -> bool {
        !crate::orb_spec::job_transition_allowed(*self as u8, Self::Running as u8)
            && *self != Self::Running
    }

    pub fn can_transition_to(&self, next: Self) -> bool {
        crate::orb_spec::job_transition_allowed(*self as u8, next as u8)
    }
}

/// One persisted job row.
#[derive(Debug, Clone)]
pub struct JobRecord {
    pub id: Uuid,
    pub mission_id: Uuid,
    pub payload_json: String,
    pub state: JobState,
    pub exit_code: Option<i32>,
    pub created_at: String,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub log_path: Option<String>,
    pub error: Option<String>,
    /// JSON-encoded `Vec<ArtifactEntry>` recorded after a successful build
    /// job; `None` for raw commands and unfinished/failed jobs.
    pub artifacts_json: Option<String>,
    pub cancellation: Option<crate::remote_node::JobCancellation>,
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// SQLite-backed job store; cheap to clone.
#[derive(Clone)]
pub struct JobStore {
    conn: Arc<Mutex<Connection>>,
}

impl JobStore {
    /// Open (creating if needed) `<workdir>/jobs.db` and ensure the schema.
    pub async fn open(work_dir: &Path) -> anyhow::Result<Self> {
        let work_dir = work_dir.to_path_buf();
        tokio::task::spawn_blocking(move || {
            std::fs::create_dir_all(&work_dir)?;
            let conn = Connection::open(work_dir.join("jobs.db"))?;
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, payload_json TEXT NOT NULL, state TEXT NOT NULL, exit_code INTEGER, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT, log_path TEXT, error TEXT, artifacts_json TEXT);",
            )?;
            let _ = conn.execute("ALTER TABLE jobs ADD COLUMN artifacts_json TEXT", []);
            let _ = conn.execute("ALTER TABLE jobs ADD COLUMN cancellation_json TEXT", []);
            Ok(Self { conn: Arc::new(Mutex::new(conn)) })
        })
        .await?
    }

    async fn with_conn<T, F>(&self, f: F) -> anyhow::Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> rusqlite::Result<T> + Send + 'static,
    {
        let conn = Arc::clone(&self.conn);
        Ok(
            tokio::task::spawn_blocking(move || f(&conn.lock().unwrap_or_else(|e| e.into_inner())))
                .await??,
        )
    }

    pub async fn recover_on_start(&self) -> anyhow::Result<usize> {
        self.with_conn(|conn| {
            conn.execute(
                "UPDATE jobs SET state = 'lost', finished_at = ?1, error = 'node restarted while the job was in flight' WHERE state IN ('queued', 'running')",
                params![now_rfc3339()],
            )
        })
        .await
    }

    pub async fn create(
        &self,
        id: Uuid,
        mission_id: Uuid,
        payload_json: String,
        log_path: String,
    ) -> anyhow::Result<()> {
        self.with_conn(move |conn| {
            conn.execute(
                "INSERT INTO jobs (id, mission_id, payload_json, state, created_at, log_path) VALUES (?1, ?2, ?3, 'queued', ?4, ?5)",
                params![id.to_string(), mission_id.to_string(), payload_json, now_rfc3339(), log_path],
            )
            .map(|_| ())
        })
        .await
    }

    pub async fn mark_running(&self, id: Uuid) -> anyhow::Result<()> {
        self.with_conn(move |conn| {
            conn.execute(
                "UPDATE jobs SET state = 'running', started_at = ?2 WHERE id = ?1",
                params![id.to_string(), now_rfc3339()],
            )
            .map(|_| ())
        })
        .await
    }

    pub async fn mark_running_if_queued(&self, id: Uuid) -> anyhow::Result<bool> {
        self.with_conn(move |conn| {
            conn.execute("UPDATE jobs SET state = 'running', started_at = ?2 WHERE id = ?1 AND state = 'queued'", params![id.to_string(), now_rfc3339()]).map(|u| u == 1)
        })
        .await
    }

    pub async fn record_cancellation(
        &self,
        id: Uuid,
        actor: &str,
        reason: &str,
    ) -> anyhow::Result<()> {
        let value = serde_json::to_string(&crate::remote_node::JobCancellation {
            actor: actor.into(),
            reason: reason.chars().take(256).collect(),
            requested_at: now_rfc3339(),
        })?;
        self.with_conn(move |conn| conn.execute(
            "UPDATE jobs SET cancellation_json = ?2 WHERE id = ?1 AND cancellation_json IS NULL AND state IN ('queued','running','lost')",
            params![id.to_string(), value],
        ).map(|_| ())).await
    }

    pub async fn cancel_if_queued(&self, id: Uuid) -> anyhow::Result<bool> {
        self.with_conn(move |conn| {
            conn.execute("UPDATE jobs SET state = 'cancelled', finished_at = ?2, error = 'cancelled before start' WHERE id = ?1 AND state = 'queued'", params![id.to_string(), now_rfc3339()]).map(|u| u == 1)
        })
        .await
    }

    pub async fn cancel_if_lost(&self, id: Uuid) -> anyhow::Result<bool> {
        self.with_conn(move |conn| {
            conn.execute("UPDATE jobs SET state = 'cancelled', finished_at = ?2 WHERE id = ?1 AND state = 'lost'", params![id.to_string(), now_rfc3339()]).map(|u| u == 1)
        })
        .await
    }

    pub async fn finish(
        &self,
        id: Uuid,
        state: JobState,
        exit_code: Option<i32>,
        error: Option<String>,
    ) -> anyhow::Result<()> {
        self.finish_with_artifacts(id, state, exit_code, error, None)
            .await
    }

    pub async fn finish_with_artifacts(
        &self,
        id: Uuid,
        state: JobState,
        exit_code: Option<i32>,
        error: Option<String>,
        artifacts_json: Option<String>,
    ) -> anyhow::Result<()> {
        self.with_conn(move |conn| {
            conn.execute(
                "UPDATE jobs SET state = ?2, exit_code = ?3, error = ?4, finished_at = ?5, artifacts_json = ?6 WHERE id = ?1 AND state IN ('queued', 'running')",
                params![id.to_string(), state.as_str(), exit_code, error, now_rfc3339(), artifacts_json],
            )
            .map(|_| ())
        })
        .await
    }

    pub async fn finalize_running(
        &self,
        id: Uuid,
        state: JobState,
        exit_code: Option<i32>,
        error: Option<String>,
    ) -> anyhow::Result<bool> {
        self.with_conn(move |conn| {
            conn.execute(
                "UPDATE jobs SET state = ?2, exit_code = ?3, error = ?4, finished_at = ?5 WHERE id = ?1 AND state = 'running'",
                params![id.to_string(), state.as_str(), exit_code, error, now_rfc3339()],
            )
            .map(|u| u == 1)
        })
        .await
    }

    pub async fn running_ids(&self) -> anyhow::Result<Vec<Uuid>> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare("SELECT id FROM jobs WHERE state = 'running'")?;
            let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
            Ok(rows.filter_map(|r| r.ok()?.parse().ok()).collect())
        })
        .await
    }

    pub async fn get(&self, id: Uuid) -> anyhow::Result<Option<JobRecord>> {
        self.with_conn(move |conn| {
            conn.query_row(
                "SELECT id, mission_id, payload_json, state, exit_code, created_at, started_at, finished_at, log_path, error, artifacts_json, cancellation_json FROM jobs WHERE id = ?1",
                params![id.to_string()],
                row_to_record,
            )
            .optional()
        })
        .await
    }

    pub async fn mission_has_live_jobs(&self, mission_id: Uuid) -> anyhow::Result<bool> {
        self.with_conn(move |conn| {
            conn.query_row("SELECT EXISTS(SELECT 1 FROM jobs WHERE mission_id=?1 AND state IN ('queued','running'))", [mission_id.to_string()], |row| row.get(0))
        }).await
    }

    /// Most recently created jobs, newest first.
    pub async fn recent(&self, limit: usize) -> anyhow::Result<Vec<JobRecord>> {
        self.with_conn(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT id, mission_id, payload_json, state, exit_code, created_at,
                        started_at, finished_at, log_path, error, artifacts_json, cancellation_json
                 FROM jobs ORDER BY created_at DESC, id DESC LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit as i64], row_to_record)?;
            rows.collect()
        })
        .await
    }
}

fn row_to_record(row: &Row<'_>) -> rusqlite::Result<JobRecord> {
    let parse_uuid = |idx: usize| -> rusqlite::Result<Uuid> {
        let raw: String = row.get(idx)?;
        Uuid::parse_str(&raw).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(idx, rusqlite::types::Type::Text, Box::new(e))
        })
    };
    let state_raw: String = row.get(3)?;
    Ok(JobRecord {
        id: parse_uuid(0)?,
        mission_id: parse_uuid(1)?,
        payload_json: row.get(2)?,
        state: JobState::parse(&state_raw).unwrap_or(JobState::Lost),
        exit_code: row.get(4)?,
        created_at: row.get(5)?,
        started_at: row.get(6)?,
        finished_at: row.get(7)?,
        log_path: row.get(8)?,
        error: row.get(9)?,
        artifacts_json: row.get(10)?,
        cancellation: row
            .get::<_, Option<String>>(11)?
            .and_then(|raw| serde_json::from_str(&raw).ok()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_states_are_exactly_the_finished_ones() {
        use JobState::*;
        for (state, terminal) in [
            (Queued, false),
            (Running, false),
            (Succeeded, true),
            (Failed, true),
            (Cancelled, true),
            (Lost, true),
        ] {
            assert_eq!(state.is_terminal(), terminal, "{state:?}");
        }
    }

    #[tokio::test]
    async fn cancellation_cause_survives_finish_and_restart() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let store = JobStore::open(dir.path()).await.unwrap();
        store
            .create(id, Uuid::new_v4(), "{}".into(), "log".into())
            .await
            .unwrap();
        store
            .record_cancellation(id, "startup_watchdog", "No native activity")
            .await
            .unwrap();
        store
            .record_cancellation(id, "core", "interrupted")
            .await
            .unwrap();
        store
            .finish(id, JobState::Cancelled, None, Some("interrupted".into()))
            .await
            .unwrap();
        drop(store);
        let reopened = JobStore::open(dir.path()).await.unwrap();
        let cause = reopened
            .get(id)
            .await
            .unwrap()
            .unwrap()
            .cancellation
            .unwrap();
        assert_eq!(cause.actor, "startup_watchdog");
        assert_eq!(cause.reason, "No native activity");
    }

    #[tokio::test]
    async fn job_state_machine_create_run_succeed() {
        let dir = tempfile::tempdir().unwrap();
        let store = JobStore::open(dir.path()).await.unwrap();
        let job_id = Uuid::new_v4();
        let mission_id = Uuid::new_v4();
        store
            .create(
                job_id,
                mission_id,
                "{\"kind\":\"raw_command\",\"command\":\"true\"}".to_string(),
                "logs/test.log".to_string(),
            )
            .await
            .unwrap();

        let record = store.get(job_id).await.unwrap().unwrap();
        assert_eq!(record.state, JobState::Queued);
        assert_eq!(record.mission_id, mission_id);
        assert!(record.started_at.is_none());
        assert!(!record.state.is_terminal());

        store.mark_running(job_id).await.unwrap();
        let record = store.get(job_id).await.unwrap().unwrap();
        assert_eq!(record.state, JobState::Running);
        assert!(record.started_at.is_some());
        assert!(record.finished_at.is_none());

        store
            .finish(job_id, JobState::Succeeded, Some(0), None)
            .await
            .unwrap();
        let record = store.get(job_id).await.unwrap().unwrap();
        assert_eq!(record.state, JobState::Succeeded);
        assert_eq!(record.exit_code, Some(0));
        assert!(record.finished_at.is_some());
        assert!(record.state.is_terminal());

        // Unknown job ids read as None.
        assert!(store.get(Uuid::new_v4()).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn terminal_outcome_is_first_wins() {
        let dir = tempfile::tempdir().unwrap();
        let store = JobStore::open(dir.path()).await.unwrap();
        let id = Uuid::new_v4();
        store
            .create(id, Uuid::new_v4(), "{}".into(), "log".into())
            .await
            .unwrap();
        assert!(!store
            .finalize_running(id, JobState::Lost, None, None)
            .await
            .unwrap());
        store.mark_running(id).await.unwrap();
        assert_eq!(store.running_ids().await.unwrap(), vec![id]);
        assert!(store
            .finalize_running(id, JobState::Lost, None, Some("process vanished".into()))
            .await
            .unwrap());
        store
            .finish(id, JobState::Succeeded, Some(0), None)
            .await
            .unwrap();
        let record = store.get(id).await.unwrap().unwrap();
        assert_eq!(record.state, JobState::Lost);
        assert_eq!(record.error.as_deref(), Some("process vanished"));
        assert!(store.running_ids().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn recover_on_start_flips_inflight_jobs_to_lost() {
        let dir = tempfile::tempdir().unwrap();
        let store = JobStore::open(dir.path()).await.unwrap();
        let queued = Uuid::new_v4();
        let running = Uuid::new_v4();
        let done = Uuid::new_v4();
        for id in [queued, running, done] {
            store
                .create(
                    id,
                    Uuid::new_v4(),
                    "{}".to_string(),
                    "logs/x.log".to_string(),
                )
                .await
                .unwrap();
        }
        store.mark_running(running).await.unwrap();
        store
            .finish(done, JobState::Succeeded, Some(0), None)
            .await
            .unwrap();

        // Simulate a restart: reopen the same database and recover.
        drop(store);
        let store = JobStore::open(dir.path()).await.unwrap();
        let recovered = store.recover_on_start().await.unwrap();
        assert_eq!(recovered, 2);

        for id in [queued, running] {
            let record = store.get(id).await.unwrap().unwrap();
            assert_eq!(record.state, JobState::Lost);
            assert!(record.finished_at.is_some());
            assert!(record.error.as_deref().unwrap_or("").contains("restarted"));
        }
        // Terminal jobs are untouched.
        let record = store.get(done).await.unwrap().unwrap();
        assert_eq!(record.state, JobState::Succeeded);

        let recent = store.recent(10).await.unwrap();
        assert_eq!(recent.len(), 3);
    }
}
