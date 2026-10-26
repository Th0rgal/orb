use base64::Engine;
use serde::Serialize;
use std::{
    collections::HashSet,
    io::Read,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

fn selected() -> &'static Mutex<HashSet<PathBuf>> {
    static PATHS: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
    PATHS.get_or_init(|| Mutex::new(HashSet::new()))
}
/// Files found in a picked or dropped folder, offered but not yet readable.
/// The client grants the subset it will upload (`grant_upload_folder`) once the
/// user confirmed; grants are per batch and revoked on cancel or finish.
#[derive(Default)]
struct FolderBatches {
    offered: std::collections::HashMap<String, std::collections::HashMap<String, PathBuf>>,
    order: Vec<String>,
    granted: std::collections::HashMap<String, HashSet<PathBuf>>,
}
const MAX_OFFERED_BATCHES: usize = 8;
fn folders() -> &'static Mutex<FolderBatches> {
    static BATCHES: OnceLock<Mutex<FolderBatches>> = OnceLock::new();
    BATCHES.get_or_init(|| Mutex::new(FolderBatches::default()))
}
fn offer(files: &[FolderFile]) -> Option<String> {
    if files.is_empty() {
        return None;
    }
    let id = uuid::Uuid::new_v4().to_string();
    let mut batches = folders().lock().ok()?;
    batches.offered.insert(
        id.clone(),
        files
            .iter()
            .map(|f| (f.relative_path.clone(), PathBuf::from(&f.path)))
            .collect(),
    );
    batches.order.push(id.clone());
    while batches.order.len() > MAX_OFFERED_BATCHES {
        let old = batches.order.remove(0);
        batches.offered.remove(&old);
    }
    Some(id)
}
fn granted(path: &Path) -> bool {
    folders()
        .lock()
        .map(|b| b.granted.values().any(|set| set.contains(path)))
        .unwrap_or(false)
}

/// Makes the confirmed subset of an offered folder readable. Unknown paths are ignored.
#[tauri::command]
pub fn grant_upload_folder(batch: String, relative_paths: Vec<String>) -> Result<usize, String> {
    let mut batches = folders().lock().map_err(|e| e.to_string())?;
    let offered = batches
        .offered
        .remove(&batch)
        .ok_or("This folder selection expired. Choose the folder again.")?;
    batches.order.retain(|id| id != &batch);
    let set: HashSet<PathBuf> = relative_paths
        .iter()
        .filter_map(|r| offered.get(r).cloned())
        .collect();
    let count = set.len();
    batches.granted.insert(batch, set);
    Ok(count)
}

#[tauri::command]
pub fn revoke_upload_folder(batch: String) {
    if let Ok(mut batches) = folders().lock() {
        batches.granted.remove(&batch);
        batches.offered.remove(&batch);
        batches.order.retain(|id| id != &batch);
    }
}

#[derive(Serialize)]
pub struct Selection {
    name: String,
    path: String,
}

#[tauri::command]
pub async fn pick_upload_files() -> Result<Vec<Selection>, String> {
    let files = rfd::AsyncFileDialog::new()
        .set_title("Attach files or images")
        .pick_files()
        .await
        .unwrap_or_default();
    let mut selections = Vec::new();
    let mut allowed = selected().lock().map_err(|e| e.to_string())?;
    for file in files {
        let path = file.path().canonicalize().map_err(|e| e.to_string())?;
        if !path.is_file() {
            return Err("Only regular files can be attached".into());
        }
        selections.push(Selection {
            name: file.file_name(),
            path: path.to_string_lossy().into_owned(),
        });
        allowed.insert(path);
    }
    Ok(selections)
}

#[tauri::command]
pub async fn read_upload_file(path: String, max_bytes: Option<u64>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let path = PathBuf::from(path);
        let canonical = path.canonicalize().map_err(|e| e.to_string())?;
        if canonical != path
            || !selected()
                .lock()
                .map_err(|e| e.to_string())?
                .contains(&canonical)
        {
            return Err("Choose this file again using the file picker".into());
        }
        let file = std::fs::File::open(&canonical).map_err(|e| e.to_string())?;
        if !file.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err("Only regular files can be attached".into());
        }
        let limit = max_bytes.unwrap_or(20 * 1024 * 1024).min(20 * 1024 * 1024);
        if file.metadata().map_err(|e| e.to_string())?.len() > limit {
            return Err(format!(
                "File exceeds the {} MiB limit",
                limit / 1024 / 1024
            ));
        }
        let mut bytes = Vec::new();
        file.take(limit + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > limit {
            return Err(format!(
                "File exceeds the {} MiB limit",
                limit / 1024 / 1024
            ));
        }
        Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Never worth sending to an agent; skipped when walking a folder.
const SKIP: &[&str] = &[
    ".DS_Store",
    "Thumbs.db",
    "desktop.ini",
    ".git",
    ".svn",
    ".hg",
    "node_modules",
    "__MACOSX",
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
];
/// Never offered from a folder walk: hidden files, secrets and build output,
/// mirroring Core's shared-context `valid_path` exclusions.
fn excluded(name: &str) -> bool {
    name.starts_with('.')
        || SKIP.contains(&name)
        || matches!(
            name,
            "target"
                | "vendor"
                | "id_rsa"
                | "id_ed25519"
                | "id_ecdsa"
                | "credentials.json"
                | "auth.json"
        )
        || name.ends_with('~')
        || name.ends_with(".pem")
        || name.ends_with(".key")
        || name.ends_with(".p12")
        || name.ends_with(".pfx")
}

/// One past the client's folder limit, so it can say the folder is too large.
pub const MAX_FOLDER_FILES: usize = 2001;

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct FolderFile {
    name: String,
    path: String,
    /// `<folder name>/<path inside the folder>`, always with `/`.
    relative_path: String,
    size: u64,
}

#[derive(Serialize, Debug)]
pub struct FolderOffer {
    batch: Option<String>,
    files: Vec<FolderFile>,
}
impl FolderOffer {
    pub fn len(&self) -> usize {
        self.files.len()
    }
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }
}

/// Regular files under `root`, sorted. Links are not followed, so a folder can
/// never reach outside itself. Nothing becomes readable here; see `offer`.
fn walk_folder(root: &Path) -> Result<Vec<FolderFile>, String> {
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    if !root.is_dir() {
        return Err("Only folders can be attached as folders".into());
    }
    let root_name = root
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("Folder names must be valid text")?
        .to_string();
    let mut out = Vec::new();
    let mut stack = vec![(root.clone(), root_name)];
    while let Some((dir, prefix)) = stack.pop() {
        let entries: Vec<_> = std::fs::read_dir(&dir)
            .map_err(|e| e.to_string())?
            .filter_map(Result::ok)
            .collect();
        for entry in entries {
            let Some(name) = entry.file_name().to_str().map(str::to_string) else {
                continue;
            };
            if excluded(&name) {
                continue;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let relative = format!("{prefix}/{name}");
            if kind.is_dir() {
                stack.push((entry.path(), relative));
            } else if kind.is_file() {
                let path = entry.path();
                out.push(FolderFile {
                    name,
                    path: path.to_string_lossy().into_owned(),
                    relative_path: relative,
                    size: entry.metadata().map(|m| m.len()).unwrap_or(0),
                });
                if out.len() >= MAX_FOLDER_FILES {
                    break;
                }
            }
        }
        if out.len() >= MAX_FOLDER_FILES {
            break;
        }
    }
    out.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    Ok(out)
}

#[tauri::command]
pub async fn pick_upload_folder() -> Result<FolderOffer, String> {
    let Some(folder) = rfd::AsyncFileDialog::new()
        .set_title("Attach a folder")
        .pick_folder()
        .await
    else {
        return Ok(FolderOffer {
            batch: None,
            files: vec![],
        });
    };
    let path = folder.path().to_path_buf();
    tauri::async_runtime::spawn_blocking(move || {
        let files = walk_folder(&path)?;
        Ok(FolderOffer {
            batch: offer(&files),
            files,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

// Only OS-delivered drop paths enter the same allowlist as file-picker selections.
// Dropped folders are walked; their files come back with folder-relative paths.
pub fn allow_drop(paths: &[PathBuf]) -> (Vec<String>, FolderOffer) {
    let mut files = Vec::new();
    let mut entries = Vec::new();
    for path in paths {
        let Ok(path) = path.canonicalize() else {
            continue;
        };
        if path.is_dir() {
            entries.extend(walk_folder(&path).unwrap_or_default());
        } else if path.is_file() {
            if let Ok(mut allowed) = selected().lock() {
                allowed.insert(path.clone());
            }
            files.push(path.to_string_lossy().into_owned());
        }
    }
    let batch = offer(&entries);
    (
        files,
        FolderOffer {
            batch,
            files: entries,
        },
    )
}

fn session_staging_dir() -> Result<PathBuf, String> {
    static SESSION_DIR: OnceLock<PathBuf> = OnceLock::new();
    let dir = SESSION_DIR.get_or_init(|| {
        let base = std::env::temp_dir().join("orb-session-uploads");
        if let Ok(entries) = std::fs::read_dir(&base) {
            for entry in entries.flatten() {
                let path = entry.path();
                if std::fs::metadata(&path)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .is_some_and(|age| age > std::time::Duration::from_secs(6 * 3600))
                {
                    let _ = std::fs::remove_dir_all(&path);
                }
            }
        }
        base.join(uuid::Uuid::new_v4().to_string())
    });
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    Ok(dir.clone())
}

pub fn cleanup_session_staging(app: Option<&tauri::AppHandle>) {
    if let Some(app) = app {
        use tauri::Manager;
        if let Ok(local_data) = app.path().app_local_data_dir() {
            let _ = std::fs::remove_dir_all(local_data.join("attachments"));
        }
    }
    if let Ok(dir) = session_staging_dir() {
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[tauri::command]
pub async fn stage_upload_file(
    app: tauri::AppHandle,
    name: String,
    data_base64: String,
) -> Result<String, String> {
    use tauri::Manager;
    if let Ok(local_data) = app.path().app_local_data_dir() {
        let _ = std::fs::remove_dir_all(local_data.join("attachments"));
    }
    if name.is_empty()
        || name.contains(['/', '\\'])
        || name == "."
        || name == ".."
        || name.len() > 240
    {
        return Err("Invalid filename".into());
    }
    if data_base64.len() > 28 * 1024 * 1024 {
        return Err("Files must be 20 MiB or smaller".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data_base64)
        .map_err(|e| e.to_string())?;
    if bytes.len() > 20 * 1024 * 1024 {
        return Err("Files must be 20 MiB or smaller".into());
    }
    let directory = session_staging_dir()?.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let path = directory.join(name);
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    let path = path.canonicalize().map_err(|e| e.to_string())?;
    selected()
        .lock()
        .map_err(|e| e.to_string())?
        .insert(path.clone());
    Ok(path.to_string_lossy().into_owned())
}

#[derive(Serialize)]
pub struct FileStat {
    pub size: u64,
    pub modified: u64,
}

fn verify_allowed_file(path: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(path);
    let canonical = path.canonicalize().map_err(|e| e.to_string())?;
    if canonical != path
        || !(selected()
            .lock()
            .map_err(|e| e.to_string())?
            .contains(&canonical)
            || granted(&canonical))
    {
        return Err("Choose this file again using the file picker".into());
    }
    if !canonical.is_file() {
        return Err("Only regular files can be attached".into());
    }
    Ok(canonical)
}

#[tauri::command]
pub async fn stat_upload_file(path: String) -> Result<FileStat, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let canonical = verify_allowed_file(&path)?;
        let meta = std::fs::metadata(&canonical).map_err(|e| e.to_string())?;
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        Ok(FileStat {
            size: meta.len(),
            modified,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn read_upload_file_chunk(
    path: String,
    offset: u64,
    length: usize,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        use std::io::{Seek, SeekFrom};
        if length == 0 || length > 16 * 1024 * 1024 {
            return Err("Invalid chunk length".into());
        }
        let canonical = verify_allowed_file(&path)?;
        let mut file = std::fs::File::open(&canonical).map_err(|e| e.to_string())?;
        file.seek(SeekFrom::Start(offset))
            .map_err(|e| e.to_string())?;
        let mut bytes = Vec::with_capacity(length);
        file.take(length as u64)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn stage_upload_file_from_path(
    app: tauri::AppHandle,
    path: String,
    name: String,
) -> Result<String, String> {
    use tauri::Manager;
    if let Ok(local_data) = app.path().app_local_data_dir() {
        let _ = std::fs::remove_dir_all(local_data.join("attachments"));
    }
    if name.is_empty()
        || name.contains(['/', '\\'])
        || name == "."
        || name == ".."
        || name.len() > 240
    {
        return Err("Invalid filename".into());
    }
    let directory = session_staging_dir()?.join(uuid::Uuid::new_v4().to_string());
    tauri::async_runtime::spawn_blocking(move || {
        let canonical = verify_allowed_file(&path)?;
        let meta = std::fs::metadata(&canonical).map_err(|e| e.to_string())?;
        if meta.len() > 2 * 1024 * 1024 * 1024 {
            return Err("Files must be 2 GiB or smaller".into());
        }
        std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let dest = directory.join(name);
        std::fs::copy(&canonical, &dest).map_err(|e| e.to_string())?;
        let dest = dest.canonicalize().map_err(|e| e.to_string())?;
        selected()
            .lock()
            .map_err(|e| e.to_string())?
            .insert(dest.clone());
        Ok(dest.to_string_lossy().into_owned())
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn pick_working_directory() -> Result<Option<String>, String> {
    let Some(folder) = rfd::AsyncFileDialog::new()
        .set_title("Choose working folder")
        .pick_folder()
        .await
    else {
        return Ok(None);
    };
    let path = folder.path().canonicalize().map_err(|e| e.to_string())?;
    Ok(Some(path.to_string_lossy().into_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_dropped_or_picked_files_are_readable() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let allowed = root.join("allowed.txt");
        let other = root.join("other.txt");
        std::fs::write(&allowed, "ok").unwrap();
        std::fs::write(&other, "secret").unwrap();
        std::fs::create_dir(root.join("folder")).unwrap();
        let (dropped, entries) =
            allow_drop(&[allowed.clone(), root.join("folder"), root.join("missing")]);
        assert_eq!(dropped, vec![allowed.to_string_lossy().into_owned()]);
        assert!(entries.files.is_empty() && entries.batch.is_none());
        assert_eq!(
            verify_allowed_file(&allowed.to_string_lossy()).unwrap(),
            allowed
        );
        // A file nobody chose, a directory, a missing path.
        assert!(verify_allowed_file(&other.to_string_lossy()).is_err());
        assert!(verify_allowed_file(&root.join("folder").to_string_lossy()).is_err());
        assert!(verify_allowed_file(&root.join("missing").to_string_lossy()).is_err());
        // The chosen file reached through another spelling or a link.
        let dotted = root.join("folder").join("..").join("allowed.txt");
        assert!(verify_allowed_file(&dotted.to_string_lossy()).is_err());
        #[cfg(unix)]
        {
            let link = root.join("link.txt");
            std::os::unix::fs::symlink(&allowed, &link).unwrap();
            assert!(verify_allowed_file(&link.to_string_lossy()).is_err());
        }
    }

    #[test]
    fn dropped_folders_are_offered_without_secrets_and_granted_per_batch() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("Questões (1)");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join(".ssh")).unwrap();
        std::fs::write(root.join("a.txt"), "a").unwrap();
        std::fs::write(root.join("sub/b é.pdf"), "bb").unwrap();
        for junk in [
            ".DS_Store",
            ".env",
            "server.pem",
            "api.key",
            "node_modules/x/index.js",
            ".git/HEAD",
            ".ssh/id_ed25519",
            "credentials.json",
        ] {
            std::fs::write(root.join(junk), "secret").unwrap();
        }
        let outside = dir.path().join("outside.txt");
        std::fs::write(&outside, "secret").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, root.join("link.txt")).unwrap();
        let (files, offer) = allow_drop(&[root.clone()]);
        assert!(files.is_empty());
        let relative: Vec<_> = offer
            .files
            .iter()
            .map(|e| e.relative_path.as_str())
            .collect();
        assert_eq!(
            relative,
            vec!["Questões (1)/a.txt", "Questões (1)/sub/b é.pdf"]
        );
        assert_eq!(offer.files[1].size, 2);
        let a = root.join("a.txt");
        let b = root.join("sub/b é.pdf");
        // Offered is not readable until the client confirms a subset.
        assert!(verify_allowed_file(&a.to_string_lossy()).is_err());
        let batch = offer.batch.unwrap();
        assert_eq!(
            grant_upload_folder(
                batch.clone(),
                vec!["Questões (1)/a.txt".into(), "Questões (1)/../x".into()]
            )
            .unwrap(),
            1
        );
        assert!(verify_allowed_file(&a.to_string_lossy()).is_ok());
        assert!(verify_allowed_file(&b.to_string_lossy()).is_err());
        assert!(verify_allowed_file(&outside.to_string_lossy()).is_err());
        // A batch is granted once; revoking removes the grant.
        assert!(
            grant_upload_folder(batch.clone(), vec!["Questões (1)/sub/b é.pdf".into()]).is_err()
        );
        revoke_upload_folder(batch);
        assert!(verify_allowed_file(&a.to_string_lossy()).is_err());
    }
}
