//! Execution-private temporary files. Only a persisted retirement receipt, written
//! after confirmed process cleanup, authorizes reclamation. Job status is not proof.
use std::future::Future;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use rusqlite::params;
use uuid::Uuid;

use super::JobStore;

const RETENTION_HOURS: i64 = 72;

tokio::task_local! {
    static DIRECTORY: PathBuf;
}

/// Apply after payload environment: temporary storage is owned by the runner.
pub(crate) fn configure(command: &mut tokio::process::Command) {
    let _ = DIRECTORY.try_with(|path| {
        command
            .env("TMPDIR", path)
            .env("TMP", path)
            .env("TEMP", path);
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
    let result = DIRECTORY.scope(path, execution).await;
    if result.is_ok() {
        if let Err(error) = retire(store, receipt.id, Utc::now()).await {
            tracing::warn!(scratch_id = %receipt.id, %error, "scratch retirement failed; retaining files");
        }
    }
    result
}

/// Called on the existing cache GC cadence, regardless of disk pressure.
pub async fn sweep(store: &JobStore, work_root: &Path) -> anyhow::Result<()> {
    sweep_at(store, work_root, Utc::now()).await
}

async fn sweep_at(store: &JobStore, work_root: &Path, now: DateTime<Utc>) -> anyhow::Result<()> {
    let receipts = store.with_conn(|conn| {
        let mut query = conn.prepare("SELECT id,parent_identity,directory_identity,retired_at FROM node_scratch WHERE retired_at IS NOT NULL")?;
        let rows = query.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?, row.get::<_, String>(3)?)))?;
        rows.collect::<Result<Vec<_>, _>>()
    }).await?;
    for (id, parent_identity, directory_identity, retired_at) in receipts {
        let receipt = Receipt {
            id: Uuid::parse_str(&id)?,
            parent_identity,
            directory_identity,
            retired_at: Some(retired_at),
        };
        let retired = DateTime::parse_from_rfc3339(receipt.retired_at.as_deref().unwrap())?;
        if now.signed_duration_since(retired).num_hours() < RETENTION_HOURS {
            continue;
        }
        let path = root(work_root)?.join(receipt.id.to_string());
        let id = receipt.id;
        let result = tokio::task::spawn_blocking(move || remove(&path, &receipt)).await?;
        match result {
            Ok(()) => {
                store
                    .with_conn(move |conn| {
                        conn.execute("DELETE FROM node_scratch WHERE id=?1", [id.to_string()])?;
                        Ok(())
                    })
                    .await?;
                tracing::info!(scratch_id = %id, "retired node scratch removed");
            }
            Err(error) => tracing::warn!(scratch_id = %id, %error, "retired node scratch retained"),
        }
    }
    Ok(())
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
        std::fs::remove_dir(&gone_path).unwrap();
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
}
