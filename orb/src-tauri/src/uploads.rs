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
/// One past the client's folder limit, so it can say the folder is too large.
pub const MAX_FOLDER_FILES: usize = 2001;

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct FolderFile {
    name: String,
    path: String,
    /// `<folder name>/<path inside the folder>`, always with `/`.
    relative_path: String,
}

/// Regular files under `root`, depth first and sorted. Links are not followed,
/// so a folder can never reach outside itself. Every returned file joins the
/// allowlist the same way a picked file does.
fn walk_folder(root: &Path, allowed: &mut HashSet<PathBuf>) -> Result<Vec<FolderFile>, String> {
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
            if SKIP.contains(&name.as_str()) {
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
                });
                allowed.insert(path);
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
pub async fn pick_upload_folder() -> Result<Vec<FolderFile>, String> {
    let Some(folder) = rfd::AsyncFileDialog::new()
        .set_title("Attach a folder")
        .pick_folder()
        .await
    else {
        return Ok(vec![]);
    };
    let path = folder.path().to_path_buf();
    tauri::async_runtime::spawn_blocking(move || {
        let mut allowed = selected().lock().map_err(|e| e.to_string())?;
        walk_folder(&path, &mut allowed)
    })
    .await
    .map_err(|e| e.to_string())?
}

// Only OS-delivered drop paths enter the same allowlist as file-picker selections.
// Dropped folders are walked; their files come back with folder-relative paths.
pub fn allow_drop(paths: &[PathBuf]) -> (Vec<String>, Vec<FolderFile>) {
    let Ok(mut allowed) = selected().lock() else {
        return (vec![], vec![]);
    };
    let mut files = Vec::new();
    let mut entries = Vec::new();
    for path in paths {
        let Ok(path) = path.canonicalize() else {
            continue;
        };
        if path.is_dir() {
            entries.extend(walk_folder(&path, &mut allowed).unwrap_or_default());
        } else if path.is_file() {
            allowed.insert(path.clone());
            files.push(path.to_string_lossy().into_owned());
        }
    }
    (files, entries)
}

#[tauri::command]
pub async fn stage_upload_file(
    app: tauri::AppHandle,
    name: String,
    data_base64: String,
) -> Result<String, String> {
    use tauri::Manager;
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
    let directory = app
        .path()
        .app_local_data_dir()
        .map_err(|e| e.to_string())?
        .join("attachments")
        .join(uuid::Uuid::new_v4().to_string());
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
        || !selected()
            .lock()
            .map_err(|e| e.to_string())?
            .contains(&canonical)
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
    if name.is_empty()
        || name.contains(['/', '\\'])
        || name == "."
        || name == ".."
        || name.len() > 240
    {
        return Err("Invalid filename".into());
    }
    let directory = app
        .path()
        .app_local_data_dir()
        .map_err(|e| e.to_string())?
        .join("attachments")
        .join(uuid::Uuid::new_v4().to_string());
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
        assert!(entries.is_empty());
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
    fn dropped_folders_are_walked_without_junk_or_links() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("Questões (1)");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::write(root.join("a.txt"), "a").unwrap();
        std::fs::write(root.join("sub/b é.pdf"), "b").unwrap();
        std::fs::write(root.join(".DS_Store"), "junk").unwrap();
        std::fs::write(root.join("node_modules/x/index.js"), "junk").unwrap();
        std::fs::write(root.join(".git/HEAD"), "junk").unwrap();
        let outside = dir.path().join("outside.txt");
        std::fs::write(&outside, "secret").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, root.join("link.txt")).unwrap();
        let (files, entries) = allow_drop(&[root.clone()]);
        assert!(files.is_empty());
        let relative: Vec<_> = entries.iter().map(|e| e.relative_path.as_str()).collect();
        assert_eq!(
            relative,
            vec!["Questões (1)/a.txt", "Questões (1)/sub/b é.pdf"]
        );
        assert!(verify_allowed_file(&root.join("sub/b é.pdf").to_string_lossy()).is_ok());
        assert!(verify_allowed_file(&outside.to_string_lossy()).is_err());
    }
}
