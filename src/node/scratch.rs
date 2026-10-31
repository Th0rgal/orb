//! Execution-private temporary files. Only a persisted retirement receipt, written
//! after confirmed process cleanup, authorizes reclamation. Job status is not proof.
use std::cell::Cell;
use std::future::Future;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use rusqlite::params;
use uuid::Uuid;

use super::JobStore;

const RETENTION_HOURS: u32 = 72;
/// Retired-scratch age boundary separating aged (`>= 6h`) from fresh (`< 6h`) scratch under pressure.
pub const PRESSURE_AGED_HOURS: i64 = 6;
const MAX_MEASURE_DEPTH: usize = 16;

struct Execution {
    directory: PathBuf,
    descendants_contained: Cell<bool>,
}

tokio::task_local! {
    static EXECUTION: Execution;
}

/// Process groups cannot contain setsid() descendants. Once any supervised
/// command uses that fallback, this execution's scratch must remain retained.
pub(crate) fn retain_uncontained() {
    let _ = EXECUTION.try_with(|execution| execution.descendants_contained.set(false));
}

/// Apply after payload environment: temporary storage is owned by the runner.
pub(crate) fn configure(command: &mut tokio::process::Command) {
    let _ = EXECUTION.try_with(|execution| {
        command
            .env("TMPDIR", &execution.directory)
            .env("TMP", &execution.directory)
            .env("TEMP", &execution.directory)
            .env("OPENCODE_TMPDIR", execution.directory.join("opencode"));
    });
}

#[derive(Debug)]
struct Receipt {
    id: Uuid,
    parent_identity: String,
    directory_identity: String,
    retired_at: Option<String>,
}

fn identity(path: &Path) -> anyhow::Result<String> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::symlink_metadata(path)?;
    anyhow::ensure!(meta.is_dir(), "scratch must be a physical directory");
    anyhow::ensure!(
        meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o022 == 0,
        "scratch must be owned by the service and not writable by other users"
    );
    Ok(format!("{}:{}", meta.dev(), meta.ino()))
}

fn root(work_root: &Path) -> anyhow::Result<PathBuf> {
    Ok(work_root.canonicalize()?.join(".scratch"))
}

async fn prepare(
    store: &JobStore,
    work_root: &Path,
    mission_id: Uuid,
    job_id: Option<Uuid>,
) -> anyhow::Result<(Receipt, PathBuf)> {
    let parent = root(work_root)?;
    use std::os::unix::fs::DirBuilderExt;
    match std::fs::DirBuilder::new().mode(0o700).create(&parent) {
        Ok(()) => (),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error.into()),
    }
    let parent_identity = identity(&parent)?;
    let id = Uuid::new_v4();
    let path = parent.join(id.to_string());
    std::fs::DirBuilder::new().mode(0o700).create(&path)?;
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(path.join("opencode"))?;
    let directory_identity = identity(&path)?;
    let receipt = Receipt {
        id,
        parent_identity: parent_identity.clone(),
        directory_identity: directory_identity.clone(),
        retired_at: None,
    };
    store.with_conn(move |conn| {
        conn.execute(
            "INSERT INTO node_scratch (id,mission_id,job_id,parent_identity,directory_identity) VALUES (?1,?2,?3,?4,?5)",
            params![id.to_string(), mission_id.to_string(), job_id.map(|id| id.to_string()), parent_identity, directory_identity],
        )?;
        Ok(())
    }).await?;
    Ok((receipt, path))
}

async fn retire(store: &JobStore, id: Uuid, now: DateTime<Utc>) -> anyhow::Result<()> {
    store
        .with_conn(move |conn| {
            conn.execute(
                "UPDATE node_scratch SET retired_at=?2 WHERE id=?1 AND retired_at IS NULL",
                params![id.to_string(), now.to_rfc3339()],
            )?;
            Ok(())
        })
        .await
}

/// `execution` must return only after the supervisor confirms all its children
/// are gone. Dropping this future deliberately leaves an unretired receipt.
pub(crate) async fn run<T>(
    store: &JobStore,
    work_root: &Path,
    mission_id: Uuid,
    job_id: Option<Uuid>,
    execution: impl Future<Output = anyhow::Result<T>>,
) -> anyhow::Result<T> {
    let (receipt, path) = prepare(store, work_root, mission_id, job_id).await?;
    let context = Execution {
        directory: path,
        descendants_contained: Cell::new(true),
    };
    let (result, descendants_contained) = EXECUTION
        .scope(context, async {
            let result = execution.await;
            (
                result,
                EXECUTION.with(|execution| execution.descendants_contained.get()),
            )
        })
        .await;
    if result.is_ok() && descendants_contained {
        if let Err(error) = retire(store, receipt.id, Utc::now()).await {
            tracing::warn!(scratch_id = %receipt.id, %error, "scratch retirement failed; retaining files");
        }
    }
    result
}

/// Approximate regular-file byte usage under `path` without following symlinks.
pub(crate) fn dir_tree_bytes_nofollow(path: &Path) -> u64 {
    fn walk(dir: &Path, depth: usize) -> u64 {
        if depth > MAX_MEASURE_DEPTH {
            return 0;
        }
        let Ok(meta) = std::fs::symlink_metadata(dir) else {
            return 0;
        };
        if meta.file_type().is_symlink() {
            return 0;
        }
        if meta.is_file() {
            return meta.len();
        }
        if !meta.is_dir() {
            return 0;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return 0;
        };
        let mut total = 0_u64;
        for entry in entries.filter_map(Result::ok) {
            let Ok(ft) = entry.file_type() else {
                continue;
            };
            if ft.is_symlink() {
                continue;
            }
            let child = entry.path();
            if ft.is_file() {
                if let Ok(m) = entry.metadata() {
                    total = total.saturating_add(m.len());
                }
            } else if ft.is_dir() {
                total = total.saturating_add(walk(&child, depth + 1));
            }
        }
        total
    }
    walk(path, 0)
}

/// Measure reclaimable confirmed-retired scratch bytes partitioned into `(aged_bytes, fresh_bytes)`
/// (`aged >= 6h`, `fresh < 6h`). Unretired receipts (`retired_at IS NULL`) and non-Linux hosts
/// where descriptor-relative reclamation is unavailable report `(0, 0)`.
pub async fn reclaimable_retired_bytes(
    store: &JobStore,
    work_root: &Path,
    now: DateTime<Utc>,
) -> anyhow::Result<(u64, u64)> {
    measure_retired_bytes(store, work_root, now, cfg!(target_os = "linux")).await
}

async fn measure_retired_bytes(
    store: &JobStore,
    work_root: &Path,
    now: DateTime<Utc>,
    reclamation_supported: bool,
) -> anyhow::Result<(u64, u64)> {
    if !reclamation_supported {
        return Ok((0, 0));
    }
    let receipts = store
        .with_conn(|conn| {
            let mut query = conn.prepare(
                "SELECT id,directory_identity,retired_at FROM node_scratch WHERE retired_at IS NOT NULL",
            )?;
            let rows = query.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?;
            rows.collect::<Result<Vec<_>, _>>()
        })
        .await?;
    let Ok(scratch_root) = root(work_root) else {
        return Ok((0, 0));
    };
    tokio::task::spawn_blocking(move || {
        let mut aged = 0_u64;
        let mut fresh = 0_u64;
        for (id_raw, directory_identity, retired_raw) in receipts {
            let Ok(id) = Uuid::parse_str(&id_raw) else {
                continue;
            };
            let Ok(retired) = DateTime::parse_from_rfc3339(&retired_raw) else {
                continue;
            };
            let path = scratch_root.join(id.to_string());
            if identity(&path).ok().as_deref() != Some(directory_identity.as_str()) {
                continue;
            }
            let bytes = dir_tree_bytes_nofollow(&path);
            if now.signed_duration_since(retired) >= chrono::Duration::hours(PRESSURE_AGED_HOURS) {
                aged = aged.saturating_add(bytes);
            } else {
                fresh = fresh.saturating_add(bytes);
            }
        }
        Ok((aged, fresh))
    })
    .await?
}

/// Called on the existing cache GC cadence, regardless of disk pressure.
pub async fn sweep(store: &JobStore, work_root: &Path) -> anyhow::Result<()> {
    sweep_at(store, work_root, Utc::now()).await
}

async fn sweep_at(store: &JobStore, work_root: &Path, now: DateTime<Utc>) -> anyhow::Result<()> {
    let _ = sweep_with_grace_hours(store, work_root, now, RETENTION_HOURS, None).await?;
    Ok(())
}

/// Sweep confirmed-retired scratch receipts (`retired_at IS NOT NULL`) whose retirement age is at
/// least `grace_hours` (`0` reclaims all confirmed-retired receipts regardless of subsecond clock
/// skew). Unretired receipts (`retired_at IS NULL`) are never touched. When `stop_at_free_bytes`
/// is `Some(target)`, stops early as soon as `fs2::available_space(work_root) >= target` so newer
/// retired scratch retains its forensic grace.
pub async fn sweep_with_grace_hours(
    store: &JobStore,
    work_root: &Path,
    now: DateTime<Utc>,
    grace_hours: u32,
    stop_at_free_bytes: Option<u64>,
) -> anyhow::Result<u64> {
    if let Some(target) = stop_at_free_bytes {
        if fs2::available_space(work_root).is_ok_and(|free| free >= target) {
            return Ok(0);
        }
    }
    let receipts = store
        .with_conn(|conn| {
            let mut query = conn.prepare(
                "SELECT id,parent_identity,directory_identity,retired_at \
                 FROM node_scratch WHERE retired_at IS NOT NULL ORDER BY retired_at ASC",
            )?;
            let rows = query.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?;
            rows.collect::<Result<Vec<_>, _>>()
        })
        .await?;
    let mut removed = 0_u64;
    let scratch_root = root(work_root)?;
    for (id_raw, parent_identity, directory_identity, retired_at) in receipts {
        let id = match Uuid::parse_str(&id_raw) {
            Ok(id) => id,
            Err(error) => {
                tracing::warn!(scratch_id = %id_raw, %error, "invalid scratch receipt id; skipping");
                continue;
            }
        };
        let retired = match DateTime::parse_from_rfc3339(&retired_at) {
            Ok(retired) => retired,
            Err(error) => {
                tracing::warn!(scratch_id = %id, %error, "invalid scratch retired_at; skipping");
                continue;
            }
        };
        if grace_hours > 0
            && now.signed_duration_since(retired) < chrono::Duration::hours(i64::from(grace_hours))
        {
            continue;
        }
        let receipt = Receipt {
            id,
            parent_identity,
            directory_identity,
            retired_at: Some(retired_at),
        };
        let path = scratch_root.join(receipt.id.to_string());
        let result = tokio::task::spawn_blocking(move || remove(&path, &receipt)).await?;
        match result {
            Ok(()) => {
                store
                    .with_conn(move |conn| {
                        conn.execute("DELETE FROM node_scratch WHERE id=?1", [id.to_string()])?;
                        Ok(())
                    })
                    .await?;
                removed += 1;
                tracing::info!(scratch_id = %id, grace_hours, "retired node scratch removed");
                if let Some(target) = stop_at_free_bytes {
                    if fs2::available_space(work_root).is_ok_and(|free| free >= target) {
                        break;
                    }
                }
            }
            Err(error) => tracing::warn!(scratch_id = %id, %error, "retired node scratch retained"),
        }
    }
    Ok(removed)
}

fn remove(path: &Path, receipt: &Receipt) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        let parent = path.parent().ok_or("scratch parent missing")?;
        crate::workspace_purge_fs::require_no_nested_mounts(parent)?;
        // Recheck and restore privacy before descriptor-relative removal. A
        // missing child is the crash-after-unlink case; remove repeats fsync.
        match std::fs::symlink_metadata(path) {
            Ok(_) => crate::workspace_purge_fs::secure_directory(
                path,
                &receipt.parent_identity,
                &receipt.directory_identity,
            )?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.to_string()),
        }
        crate::workspace_purge_fs::remove(
            path,
            &receipt.parent_identity,
            &receipt.directory_identity,
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (path, &receipt.parent_identity, &receipt.directory_identity);
        Err("scratch removal requires Linux descriptor-relative reclamation".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn scratch_retirement_requires_successful_supervision() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::open(temp.path()).await.unwrap();
        let mission = Uuid::new_v4();
        let (retained, retained_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(retained_path.join("unfinished"), b"keep").unwrap();
        let failed: anyhow::Result<()> = run(&store, temp.path(), mission, None, async {
            anyhow::bail!("supervision failed")
        })
        .await;
        assert!(failed.is_err());
        run(&store, temp.path(), mission, None, async {
            let mut command = tokio::process::Command::new("env");
            command.env("TMPDIR", "/unmanaged");
            configure(&mut command);
            for key in ["TMPDIR", "TMP", "TEMP"] {
                assert!(command
                    .as_std()
                    .get_envs()
                    .any(|(k, v)| k == key && v.unwrap().to_string_lossy().contains(".scratch/")));
            }
            Ok(())
        })
        .await
        .unwrap();
        let counts = store
            .with_conn(|conn| {
                conn.query_row(
                    "SELECT COUNT(*),COUNT(retired_at) FROM node_scratch",
                    [],
                    |row| Ok((row.get::<_, u32>(0)?, row.get::<_, u32>(1)?)),
                )
            })
            .await
            .unwrap();
        assert_eq!(counts, (3, 1));
        sweep_at(&store, temp.path(), Utc::now()).await.unwrap();
        assert_eq!(
            std::fs::read_dir(temp.path().join(".scratch"))
                .unwrap()
                .count(),
            3
        );
        assert!(retained.retired_at.is_none());
        assert!(retained_path.join("unfinished").exists());
    }

    #[tokio::test]
    async fn scratch_cancelled_future_never_becomes_reclaimable() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::open(temp.path()).await.unwrap();
        let (started, ready) = tokio::sync::oneshot::channel();
        let task = tokio::spawn({
            let store = store.clone();
            let root = temp.path().to_path_buf();
            async move {
                run(&store, &root, Uuid::new_v4(), None, async {
                    started.send(()).unwrap();
                    std::future::pending::<anyhow::Result<()>>().await
                })
                .await
            }
        });
        // Wait until the receipt exists and the execution really started.
        tokio::time::timeout(std::time::Duration::from_secs(10), ready)
            .await
            .unwrap()
            .unwrap();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        let retired = store
            .with_conn(|conn| {
                conn.query_row("SELECT COUNT(retired_at) FROM node_scratch", [], |row| {
                    row.get::<_, u32>(0)
                })
            })
            .await
            .unwrap();
        assert_eq!(retired, 0);
    }

    #[tokio::test]
    async fn scratch_uncontained_execution_is_never_retired() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::open(temp.path()).await.unwrap();
        run(&store, temp.path(), Uuid::new_v4(), None, async {
            retain_uncontained();
            // Later successful commands cannot reverse this retention fence.
            let mut command = tokio::process::Command::new("true");
            configure(&mut command);
            Ok(())
        })
        .await
        .unwrap();
        let retired = store
            .with_conn(|conn| {
                conn.query_row("SELECT COUNT(retired_at) FROM node_scratch", [], |row| {
                    row.get::<_, u32>(0)
                })
            })
            .await
            .unwrap();
        assert_eq!(retired, 0);
        sweep_at(
            &store,
            temp.path(),
            Utc::now() + chrono::Duration::hours(100),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read_dir(temp.path().join(".scratch"))
                .unwrap()
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn scratch_parent_symlink_is_refused() {
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let store = JobStore::open(temp.path()).await.unwrap();
        std::os::unix::fs::symlink(outside.path(), temp.path().join(".scratch")).unwrap();
        assert!(prepare(&store, temp.path(), Uuid::new_v4(), None)
            .await
            .is_err());
        assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn scratch_restart_expiry_and_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::open(temp.path()).await.unwrap();
        let mission = Uuid::new_v4();
        let (old, old_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        let (replaced, replaced_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        let (_, running_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        let old_time = Utc::now() - chrono::Duration::hours(73);
        retire(&store, old.id, old_time).await.unwrap();
        retire(&store, replaced.id, old_time).await.unwrap();
        std::fs::write(running_path.join("source"), b"preserve").unwrap();
        std::os::unix::fs::symlink(&running_path, old_path.join("link")).unwrap();
        std::fs::rename(&replaced_path, temp.path().join("original")).unwrap();
        std::fs::create_dir(&replaced_path).unwrap();
        std::fs::write(replaced_path.join("new-source"), b"preserve").unwrap();
        drop(store);
        let store = JobStore::open(temp.path()).await.unwrap();
        sweep_at(&store, temp.path(), Utc::now()).await.unwrap();
        assert!(!old_path.exists());
        assert!(running_path.join("source").exists());
        assert!(replaced_path.join("new-source").exists());
        // A crash after removal but before receipt acknowledgement is idempotent.
        let (gone, gone_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        retire(&store, gone.id, old_time).await.unwrap();
        std::fs::remove_dir_all(&gone_path).unwrap();
        sweep_at(&store, temp.path(), Utc::now()).await.unwrap();
        let remaining = store
            .with_conn(|conn| {
                conn.query_row("SELECT COUNT(*) FROM node_scratch", [], |row| {
                    row.get::<_, u32>(0)
                })
            })
            .await
            .unwrap();
        assert_eq!(remaining, 2);
    }

    #[tokio::test]
    async fn scratch_sizing_partitions_aged_and_fresh_without_following_symlinks_or_unretired() {
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("external.bin"), vec![0_u8; 4096]).unwrap();

        let store = JobStore::open(temp.path()).await.unwrap();
        let mission = Uuid::new_v4();
        let now = Utc::now();

        let (aged, aged_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(aged_path.join("aged.bin"), vec![1_u8; 1024]).unwrap();
        std::os::unix::fs::symlink(outside.path(), aged_path.join("escape")).unwrap();
        retire(&store, aged.id, now - chrono::Duration::hours(8))
            .await
            .unwrap();

        let (fresh, fresh_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(fresh_path.join("fresh.bin"), vec![2_u8; 512]).unwrap();
        retire(&store, fresh.id, now - chrono::Duration::hours(1))
            .await
            .unwrap();

        let (_unretired, unretired_path) =
            prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(unretired_path.join("live.bin"), vec![3_u8; 8192]).unwrap();

        let (replaced, replaced_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        retire(&store, replaced.id, now - chrono::Duration::hours(12))
            .await
            .unwrap();
        std::fs::rename(&replaced_path, temp.path().join("moved-aside")).unwrap();
        std::fs::create_dir(&replaced_path).unwrap();
        std::fs::write(replaced_path.join("foreign.bin"), vec![4_u8; 2048]).unwrap();

        assert_eq!(
            measure_retired_bytes(&store, temp.path(), now, false)
                .await
                .unwrap(),
            (0, 0)
        );
        assert_eq!(
            measure_retired_bytes(&store, temp.path(), now, true)
                .await
                .unwrap(),
            (1024, 512)
        );

        // Even at grace_hours = 0, unretired scratch is strictly untouched.
        let _ = sweep_with_grace_hours(&store, temp.path(), now, 0, None)
            .await
            .unwrap();
        assert!(unretired_path.join("live.bin").exists());
        assert!(outside.path().join("external.bin").exists());
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn scratch_pressure_grace_sweeps_6h_before_0h_and_never_touches_unretired() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::open(temp.path()).await.unwrap();
        let mission = Uuid::new_v4();
        let now = Utc::now();

        let (aged, aged_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(aged_path.join("a"), b"aged").unwrap();
        retire(&store, aged.id, now - chrono::Duration::hours(7))
            .await
            .unwrap();

        let (fresh, fresh_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(fresh_path.join("f"), b"fresh").unwrap();
        retire(&store, fresh.id, now - chrono::Duration::hours(2))
            .await
            .unwrap();

        let (_live, live_path) = prepare(&store, temp.path(), mission, None).await.unwrap();
        std::fs::write(live_path.join("l"), b"live").unwrap();

        let removed_6h = sweep_with_grace_hours(&store, temp.path(), now, 6, None)
            .await
            .unwrap();
        assert_eq!(removed_6h, 1);
        assert!(!aged_path.exists());
        assert!(fresh_path.exists());
        assert!(live_path.exists());

        let removed_0h = sweep_with_grace_hours(&store, temp.path(), now, 0, None)
            .await
            .unwrap();
        assert_eq!(removed_0h, 1);
        assert!(!fresh_path.exists());
        assert!(live_path.exists());
    }
}
