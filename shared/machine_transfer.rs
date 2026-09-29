//! Bounded workspace checkpoints shared by Core, nodes and Orb. Roots are supplied
//! by the trusted host adapter, never by the network caller.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    process::Command,
};

pub const BLOCK: usize = 1024 * 1024;
pub const MAX_BYTES: u64 = 10 * 1024 * 1024 * 1024;
pub const MAX_FILES: usize = 50_000;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub executable: bool,
}
/// A symbolic link recreated at the destination. `target` is always relative and
/// stays inside the workspace; it is never followed by this adapter.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Link {
    pub path: String,
    pub target: String,
}
/// A path left at the source because it cannot be reproduced elsewhere.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Skipped {
    pub path: String,
    pub reason: String,
}
pub const OUTSIDE_LINK: &str = "link points outside the workspace";
pub const UNUSUAL_LINK: &str = "link target is not portable";
pub const SPECIAL_FILE: &str = "socket, pipe or device";
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Manifest {
    pub files: Vec<Entry>,
    pub excluded: Vec<String>,
    pub bytes: u64,
    // Absent from manifests written before links were transferable.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<Link>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<Skipped>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Operation {
    Snapshot,
    CheckSource,
    Read {
        path: String,
        offset: u64,
    },
    Stage {
        manifest: Manifest,
    },
    Write {
        path: String,
        offset: u64,
        data: String,
    },
    Verify,
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn relative(value: &str) -> Result<PathBuf, String> {
    let path = Path::new(value);
    if value.is_empty()
        || value.contains('\\')
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err("Invalid checkpoint path".into());
    }
    Ok(path.to_owned())
}
fn confined(root: &Path, value: &str) -> Result<PathBuf, String> {
    let path = relative(value)?;
    let mut current = root.to_owned();
    if fs::symlink_metadata(root)
        .map_err(err)?
        .file_type()
        .is_symlink()
    {
        return Err("Checkpoint root is a symlink".into());
    }
    for part in path.components() {
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(m) if m.file_type().is_symlink() => {
                return Err(format!("Symlink is not transferable: {value}"))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(err(e)),
            _ => {}
        }
    }
    Ok(current)
}
/// Directory depth of a checkpoint path's parent.
fn depth(path: &str) -> usize {
    path.split('/').count().saturating_sub(1)
}
/// A target that cannot leave the workspace: `..` only leads, never beyond the
/// root, and is followed by plain names. Links are never children of links, so
/// every hop of a chain lands inside the root as well.
fn contained_target(path: &str, target: &str) -> bool {
    if target.is_empty() || target.len() > 4096 || target.contains(['\\', '\0']) {
        return false;
    }
    let mut up = 0;
    let mut names = 0;
    for part in Path::new(target).components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir if names == 0 => up += 1,
            Component::Normal(_) => names += 1,
            _ => return false,
        }
    }
    up <= depth(path)
}
/// The target to record for a source link, or why it stays behind. Absolute
/// targets inside one of the workspace's own `roots` become relative.
fn portable_target(roots: &[&Path], path: &str, target: &Path) -> Result<String, &'static str> {
    let Some(text) = target.to_str() else {
        return Err(UNUSUAL_LINK);
    };
    if !target.is_absolute() {
        if contained_target(path, text) {
            return Ok(text.into());
        }
        let escapes = Path::new(path)
            .parent()
            .map(|p| p.join(target))
            .is_some_and(|joined| {
                let mut level = 0usize;
                joined.components().any(|c| match c {
                    Component::ParentDir => {
                        let out = level == 0;
                        level = level.saturating_sub(1);
                        out
                    }
                    Component::Normal(_) => {
                        level += 1;
                        false
                    }
                    Component::CurDir => false,
                    _ => true,
                })
            });
        return Err(if escapes { OUTSIDE_LINK } else { UNUSUAL_LINK });
    }
    let inside = roots
        .iter()
        .find_map(|root| target.strip_prefix(root).ok())
        .ok_or(OUTSIDE_LINK)?;
    if inside
        .components()
        .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(UNUSUAL_LINK);
    }
    let inside = inside.to_str().ok_or(UNUSUAL_LINK)?.replace('\\', "/");
    let up = "../".repeat(depth(path));
    let rewritten = if inside.is_empty() {
        if up.is_empty() {
            ".".into()
        } else {
            up.trim_end_matches('/').to_owned()
        }
    } else {
        format!("{up}{inside}")
    };
    if contained_target(path, &rewritten) {
        Ok(rewritten)
    } else {
        Err(UNUSUAL_LINK)
    }
}
fn excluded(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    matches!(
        n.as_str(),
        ".git"
            | ".transfers"
            | "node_modules"
            | "target"
            | ".next"
            | ".cache"
            | "__pycache__"
            | ".venv"
            | ".ssh"
            | ".aws"
            | ".codex"
            | ".claude"
            | ".opencode"
            | ".grok"
            | ".gemini"
            | ".gnupg"
            | ".npmrc"
            | ".netrc"
            | ".pypirc"
            | ".envrc"
            | ".git-credentials"
            | "secrets"
            | "secrets.json"
            | "secrets.yaml"
            | "secrets.yml"
            | "credentials.json"
            | "auth.json"
            | "opencode.json"
    ) || n == ".env"
        || (n.starts_with(".env.") && !n.ends_with(".example"))
        || n.ends_with(".pem")
        || n.ends_with(".key")
        || n.ends_with(".p12")
        || n.ends_with(".pfx")
        || n.starts_with("id_rsa")
        || n.starts_with("id_ed25519")
        || n.contains("credentials")
}
fn digest(path: &Path) -> Result<String, String> {
    digest_beneath(path.parent().ok_or("Invalid file")?, path)
}
fn digest_beneath(root: &Path, path: &Path) -> Result<String, String> {
    let mut input = crate::file_browser::open_beneath(root, path)?;
    if !input.metadata().map_err(err)?.is_file() {
        return Err("Not a regular file".into());
    }
    let mut hash = Sha256::new();
    let mut buf = vec![0; BLOCK];
    loop {
        let n = input.read(&mut buf).map_err(err)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn size(bytes: u64) -> String {
    const GIB: u64 = 1024 * 1024 * 1024;
    if bytes >= GIB {
        format!("{:.1} GiB", bytes as f64 / GIB as f64)
    } else {
        format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
    }
}
/// Counts what a snapshot would carry without reading file contents, so an
/// oversized workspace is refused with its totals before anything is hashed.
fn measure(root: &Path, max_bytes: u64, max_files: usize) -> Result<(), String> {
    type Tally = std::collections::BTreeMap<String, (u64, usize)>;
    fn walk(top: Option<&str>, dir: &Path, tally: &mut Tally) -> Result<(), String> {
        for item in fs::read_dir(dir).map_err(err)? {
            let item = item.map_err(err)?;
            let name = item.file_name();
            let name = name.to_str().ok_or("Non-UTF-8 filename")?;
            if excluded(name) || name == ".transfer-git.bundle" {
                continue;
            }
            let m = fs::symlink_metadata(item.path()).map_err(err)?;
            let top = top.unwrap_or(name);
            if m.is_dir() {
                walk(Some(top), &item.path(), tally)?;
            } else if m.is_file() || m.file_type().is_symlink() {
                let row = tally.entry(top.to_owned()).or_default();
                row.0 = row
                    .0
                    .checked_add(if m.is_file() { m.len() } else { 0 })
                    .ok_or("Workspace size overflow")?;
                row.1 += 1;
            }
        }
        Ok(())
    }
    let mut tally = Tally::new();
    walk(None, root, &mut tally)?;
    let bytes = tally
        .values()
        .try_fold(0u64, |sum, row| sum.checked_add(row.0))
        .ok_or("Workspace size overflow")?;
    let files: usize = tally.values().map(|row| row.1).sum();
    if bytes <= max_bytes && files <= max_files {
        return Ok(());
    }
    let mut rows: Vec<_> = tally.into_iter().collect();
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    let largest: Vec<_> = rows
        .iter()
        .take(5)
        .map(|(top, (bytes, files))| format!("{top} ({}, {files} files)", size(*bytes)))
        .collect();
    Err(format!(
        "Workspace exceeds transfer limit (10 GiB / 50,000 files): {} in {files} files. Largest: {}",
        size(bytes),
        largest.join(", ")
    ))
}
/// `roots` are the spellings of the workspace root an absolute link may use.
fn inventory(
    roots: &[&Path],
    root: &Path,
    dir: &Path,
    manifest: &mut Manifest,
) -> Result<(), String> {
    let mut entries = fs::read_dir(dir)
        .map_err(err)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(err)?;
    entries.sort_by_key(|e| e.file_name());
    for item in entries {
        let path = item.path();
        let rel = path
            .strip_prefix(root)
            .map_err(err)?
            .to_str()
            .ok_or("Non-UTF-8 filename")?
            .replace('\\', "/");
        let name = item.file_name();
        let name = name.to_str().ok_or("Non-UTF-8 filename")?;
        if excluded(name) || name == ".transfer-git.bundle" {
            manifest.excluded.push(rel);
            if manifest.excluded.len() > MAX_FILES {
                return Err("Too many excluded paths".into());
            }
            continue;
        }
        let m = fs::symlink_metadata(&path).map_err(err)?;
        if m.is_dir() {
            inventory(roots, root, &path, manifest)?;
            continue;
        }
        if !m.is_file() {
            // Never followed: the link itself travels, or stays behind.
            let kept = if m.file_type().is_symlink() {
                portable_target(roots, &rel, &fs::read_link(&path).map_err(err)?)
            } else {
                Err(SPECIAL_FILE)
            };
            match kept {
                Ok(target) => manifest.links.push(Link { path: rel, target }),
                Err(reason) => manifest.skipped.push(Skipped {
                    path: rel,
                    reason: reason.into(),
                }),
            }
            if manifest.files.len() + manifest.links.len() > MAX_FILES
                || manifest.skipped.len() > MAX_FILES
            {
                return Err("Workspace exceeds transfer limit (10 GiB / 50,000 files)".into());
            }
            continue;
        }
        manifest.bytes = manifest
            .bytes
            .checked_add(m.len())
            .ok_or("Workspace size overflow")?;
        if manifest.bytes > MAX_BYTES || manifest.files.len() + manifest.links.len() >= MAX_FILES {
            return Err("Workspace exceeds transfer limit (10 GiB / 50,000 files)".into());
        }
        #[cfg(unix)]
        let executable = {
            use std::os::unix::fs::PermissionsExt;
            m.permissions().mode() & 0o111 != 0
        };
        #[cfg(not(unix))]
        let executable = false;
        let sha256 = digest_beneath(root, &path)?;
        let after = fs::symlink_metadata(&path).map_err(err)?;
        if m.len() != after.len() || m.modified().ok() != after.modified().ok() {
            return Err(format!("File changed during snapshot: {rel}"));
        }
        manifest.files.push(Entry {
            path: rel,
            bytes: m.len(),
            sha256,
            executable,
        });
    }
    Ok(())
}
/// Recreates the manifest's links once every file is in place. A retry after
/// an interrupted verification finds the links it already made.
fn restore_links(root: &Path, links: &[Link]) -> Result<(), String> {
    for link in links {
        let at = relative(&link.path)?;
        let parent = match at.parent().and_then(Path::to_str) {
            Some("") | None => root.to_owned(),
            Some(parent) => confined(root, parent)?,
        };
        fs::create_dir_all(&parent).map_err(err)?;
        let path = parent.join(at.file_name().ok_or("Invalid link path")?);
        match fs::symlink_metadata(&path) {
            Ok(m) if m.file_type().is_symlink() => {
                if fs::read_link(&path).map_err(err)? != Path::new(&link.target) {
                    return Err(format!("Checkpoint mismatch: {}", link.path));
                }
            }
            Ok(_) => return Err(format!("Checkpoint mismatch: {}", link.path)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                #[cfg(unix)]
                std::os::unix::fs::symlink(&link.target, &path).map_err(err)?;
                #[cfg(not(unix))]
                return Err("This computer cannot receive a workspace containing links".into());
            }
            Err(e) => return Err(err(e)),
        }
    }
    Ok(())
}
fn manifest_path(area: &Path) -> PathBuf {
    area.join("manifest.json")
}
fn load(area: &Path) -> Result<Manifest, String> {
    serde_json::from_slice(&fs::read(manifest_path(area)).map_err(err)?).map_err(err)
}
fn validate(m: &Manifest) -> Result<(), String> {
    if serde_json::to_vec(m).map_err(err)?.len() > 8 * 1024 * 1024 {
        return Err("Workspace inventory exceeds 8 MiB".into());
    }
    let mut seen = std::collections::HashSet::new();
    let mut total = 0u64;
    if m.files.len() > MAX_FILES {
        return Err("Too many files".into());
    }
    for f in &m.files {
        relative(&f.path)?;
        if f.path.split('/').any(excluded) {
            return Err("Excluded path in manifest".into());
        }
        if !seen.insert(f.path.clone())
            || f.sha256.len() != 64
            || !f.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err("Invalid manifest".into());
        }
        total = total.checked_add(f.bytes).ok_or("Size overflow")?;
        if total > MAX_BYTES {
            return Err("Checkpoint exceeds 10 GiB".into());
        }
    }
    if total != m.bytes {
        return Err("Manifest size mismatch".into());
    }
    if m.files.len() + m.links.len() > MAX_FILES || m.skipped.len() > MAX_FILES {
        return Err("Too many files".into());
    }
    for l in &m.links {
        relative(&l.path)?;
        if l.path.split('/').any(excluded) {
            return Err("Excluded path in manifest".into());
        }
        if !seen.insert(l.path.clone()) || !contained_target(&l.path, &l.target) {
            return Err("Invalid manifest".into());
        }
    }
    for path in m
        .files
        .iter()
        .map(|f| &f.path)
        .chain(m.links.iter().map(|l| &l.path))
    {
        let mut p = Path::new(path);
        while let Some(parent) = p.parent() {
            if seen.contains(parent.to_str().unwrap_or("")) {
                return Err("Overlapping checkpoint paths".into());
            }
            p = parent;
        }
    }
    Ok(())
}
fn save(area: &Path, m: &Manifest) -> Result<(), String> {
    let bytes = serde_json::to_vec(m).map_err(err)?;
    let temporary = area.join("manifest.pending");
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&temporary)
        .map_err(err)?;
    f.write_all(&bytes).map_err(err)?;
    f.sync_all().map_err(err)?;
    fs::rename(temporary, manifest_path(area)).map_err(err)?;
    File::open(area).map_err(err)?.sync_all().map_err(err)
}
fn git(root: &Path, args: &[&str]) -> Result<(), String> {
    let out = Command::new("git")
        .arg("-c")
        .arg("core.hooksPath=/dev/null")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(err)?;
    if !out.status.success() {
        return Err("Git checkpoint failed; inspect the repository before moving".into());
    }
    Ok(())
}
fn bundle_repository(repo: &Path, destination: &Path, limit: u64) -> Result<u64, String> {
    let mut output = File::create(destination).map_err(err)?;
    let limit = limit.min(
        fs2::available_space(destination.parent().ok_or("Invalid bundle path")?)
            .map_err(err)?
            .saturating_sub(BLOCK as u64),
    );
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["bundle", "create", "-", "--all"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(err)?;
    let copied = std::io::copy(
        &mut child
            .stdout
            .take()
            .ok_or("Git output unavailable")?
            .take(limit.saturating_add(1)),
        &mut output,
    );
    if copied.as_ref().is_err() || copied.as_ref().is_ok_and(|n| *n > limit) {
        let _ = child.kill();
        let _ = child.wait();
        return Err("Git history exceeds transfer size or available disk space".into());
    }
    if !child.wait().map_err(err)?.success() {
        return Err("Could not checkpoint Git history".into());
    }
    output.sync_all().map_err(err)?;
    copied.map_err(err)
}

/// `area` is a host-owned, unique per-action directory; `source` exists only on
/// the source adapter. The restored root is always area/workspace.
pub fn operate(
    area: &Path,
    source: Option<&Path>,
    op: Operation,
) -> Result<serde_json::Value, String> {
    fs::create_dir_all(area).map_err(err)?;
    let root = area.join("workspace");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(area.join("lock"))
        .map_err(err)?;
    fs2::FileExt::lock_exclusive(&lock).map_err(err)?;
    match op {
        Operation::Snapshot => {
            if manifest_path(area).exists() {
                return Ok(serde_json::json!(load(area)?));
            }
            let given = source.ok_or("Source workspace unavailable")?;
            let source = given.canonicalize().map_err(err)?;
            let roots = [source.as_path(), given];
            if area.starts_with(&source) {
                return Err("Checkpoint directory must be outside the workspace".into());
            }
            if root.exists() {
                fs::remove_dir_all(&root).map_err(err)?;
            }
            fs::create_dir_all(&root).map_err(err)?;
            measure(&source, MAX_BYTES, MAX_FILES)?;
            let mut m = Manifest::default();
            inventory(&roots, &source, &source, &mut m)?;
            if fs2::available_space(area).map_err(err)? < m.bytes.saturating_add(BLOCK as u64) {
                return Err("Insufficient snapshot disk space".into());
            }
            for f in &m.files {
                let from = confined(&source, &f.path)?;
                let to = confined(&root, &f.path)?;
                fs::create_dir_all(to.parent().unwrap()).map_err(err)?;
                let input = crate::file_browser::open_beneath(&source, &from)?;
                if !input.metadata().map_err(err)?.is_file() {
                    return Err("Source is not a regular file".into());
                }
                let mut output = File::create(&to).map_err(err)?;
                let copied = std::io::copy(&mut input.take(f.bytes.saturating_add(1)), &mut output)
                    .map_err(err)?;
                if copied != f.bytes {
                    return Err("File changed during snapshot".into());
                }
                output.sync_all().map_err(err)?;
                if digest(&to)? != f.sha256 {
                    return Err(format!("File changed during snapshot: {}", f.path));
                }
            }
            let mut after = Manifest::default();
            inventory(&roots, &source, &source, &mut after)?;
            if after != m {
                return Err("Workspace changed during snapshot; stop all writers and retry".into());
            }
            let repositories: Vec<_> = m
                .excluded
                .iter()
                .filter(|p| Path::new(p).file_name().is_some_and(|n| n == ".git"))
                .cloned()
                .collect();
            for git_path in repositories {
                let rel = Path::new(&git_path).parent().unwrap_or(Path::new(""));
                let repo = source.join(rel);
                let bundle = root.join(rel).join(".transfer-git.bundle");
                fs::create_dir_all(bundle.parent().unwrap()).map_err(err)?;
                let refs = Command::new("git")
                    .arg("-C")
                    .arg(&repo)
                    .args(["show-ref"])
                    .output()
                    .map_err(err)?;
                if !refs.status.success() && refs.status.code() != Some(1) {
                    return Err("Cannot read Git history".into());
                }
                if refs.status.success() {
                    let bytes =
                        bundle_repository(&repo, &bundle, MAX_BYTES.saturating_sub(m.bytes))?;
                    m.bytes = m
                        .bytes
                        .checked_add(bytes)
                        .ok_or("Workspace size overflow")?;
                    m.files.push(Entry {
                        path: bundle
                            .strip_prefix(&root)
                            .map_err(err)?
                            .to_str()
                            .ok_or("Invalid path")?
                            .into(),
                        bytes,
                        sha256: digest(&bundle)?,
                        executable: false,
                    });
                }
            }
            validate(&m)?;
            save(area, &m)?;
            Ok(serde_json::json!(m))
        }
        Operation::CheckSource => {
            let given = source.ok_or("Source workspace unavailable")?;
            let source = given.canonicalize().map_err(err)?;
            let expected = load(area)?;
            let mut current = Manifest::default();
            inventory(&[source.as_path(), given], &source, &source, &mut current)?;
            let files: Vec<_> = expected
                .files
                .iter()
                .filter(|f| !f.path.ends_with(".transfer-git.bundle"))
                .cloned()
                .collect();
            if current.files != files || current.links != expected.links {
                return Err(
                    "Source files changed after preparation; cancel and prepare again".into(),
                );
            }
            for bundle in expected
                .files
                .iter()
                .filter(|f| f.path.ends_with(".transfer-git.bundle"))
            {
                let relative = Path::new(&bundle.path).parent().unwrap_or(Path::new(""));
                let refs = Command::new("git")
                    .arg("-C")
                    .arg(source.join(relative))
                    .args(["show-ref"])
                    .output()
                    .map_err(err)?;
                let bundled = Command::new("git")
                    .args(["bundle", "list-heads"])
                    .arg(root.join(&bundle.path))
                    .output()
                    .map_err(err)?;
                if !refs.status.success() || !bundled.status.success() {
                    return Err("Git source is no longer available".into());
                }
                let normalize = |bytes: &[u8]| {
                    let text = String::from_utf8_lossy(bytes);
                    let mut lines: Vec<_> = text
                        .lines()
                        .filter(|s| !s.ends_with(" HEAD"))
                        .map(str::to_owned)
                        .collect();
                    lines.sort();
                    lines
                };
                if normalize(&refs.stdout) != normalize(&bundled.stdout) {
                    return Err("Git history changed after preparation; prepare again".into());
                }
            }
            Ok(serde_json::json!({"unchanged":true}))
        }
        Operation::Stage { manifest } => {
            validate(&manifest)?;
            if manifest_path(area).exists() {
                if load(area)? != manifest {
                    return Err("Transfer manifest differs from staged checkpoint".into());
                }
            } else {
                if fs2::available_space(area).map_err(err)?
                    < manifest.bytes.saturating_add(BLOCK as u64)
                {
                    return Err("Insufficient destination disk space".into());
                }
                fs::create_dir_all(&root).map_err(err)?;
                save(area, &manifest)?;
            }
            let received: std::collections::BTreeMap<_, _> = manifest
                .files
                .iter()
                .map(|f| {
                    let size = confined(&root, &f.path)
                        .ok()
                        .and_then(|p| fs::metadata(p).ok())
                        .map(|m| m.len().min(f.bytes))
                        .unwrap_or(0);
                    (
                        f.path.clone(),
                        if size == f.bytes {
                            size
                        } else {
                            size / BLOCK as u64 * BLOCK as u64
                        },
                    )
                })
                .collect();
            Ok(
                serde_json::json!({"ok":true,"sealed":area.join("verified").exists(),"received":received}),
            )
        }
        Operation::Read { path, offset } => {
            let m = load(area)?;
            let f = m
                .files
                .iter()
                .find(|f| f.path == path)
                .ok_or("File absent from manifest")?;
            if offset > f.bytes || offset % BLOCK as u64 != 0 {
                return Err("Invalid block offset".into());
            }
            let mut file = File::open(confined(&root, &path)?).map_err(err)?;
            file.seek(SeekFrom::Start(offset)).map_err(err)?;
            let mut data = vec![0; (f.bytes - offset).min(BLOCK as u64) as usize];
            file.read_exact(&mut data).map_err(err)?;
            Ok(serde_json::json!({"data":STANDARD.encode(data)}))
        }
        Operation::Write { path, offset, data } => {
            if area.join("verified").exists() {
                return Err("Checkpoint already sealed".into());
            }
            let m = load(area)?;
            let f = m
                .files
                .iter()
                .find(|f| f.path == path)
                .ok_or("File absent from manifest")?;
            if data.len() > BLOCK * 2 {
                return Err("Oversized block".into());
            }
            let bytes = STANDARD.decode(data).map_err(err)?;
            if offset > f.bytes
                || offset % BLOCK as u64 != 0
                || bytes.len() as u64 != (f.bytes - offset).min(BLOCK as u64)
            {
                return Err("Invalid block extent".into());
            }
            let to = confined(&root, &path)?;
            fs::create_dir_all(to.parent().unwrap()).map_err(err)?;
            let mut file = OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(to)
                .map_err(err)?;
            file.seek(SeekFrom::Start(offset)).map_err(err)?;
            file.write_all(&bytes).map_err(err)?;
            file.sync_data().map_err(err)?;
            Ok(serde_json::json!({"ok":true}))
        }
        Operation::Verify => {
            let m = load(area)?;
            validate(&m)?;
            if !area.join("verified").exists() {
                for f in &m.files {
                    let path = confined(&root, &f.path)?;
                    if fs::metadata(&path).map_err(err)?.len() != f.bytes
                        || digest(&path)? != f.sha256
                    {
                        return Err(format!("Checkpoint mismatch: {}", f.path));
                    }
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        fs::set_permissions(
                            path,
                            fs::Permissions::from_mode(if f.executable { 0o700 } else { 0o600 }),
                        )
                        .map_err(err)?;
                    }
                }
                restore_links(&root, &m.links)?;
                for (i, f) in m.files.iter().enumerate().filter(|(_, f)| {
                    Path::new(&f.path)
                        .file_name()
                        .is_some_and(|n| n == ".transfer-git.bundle")
                }) {
                    let bundle = confined(&root, &f.path)?;
                    let working = bundle.parent().ok_or("Invalid repository path")?;
                    let repo = area.join(format!("git-restore-{i}"));
                    if repo.exists() {
                        fs::remove_dir_all(&repo).map_err(err)?;
                    }
                    git(
                        area,
                        &[
                            "clone",
                            "--mirror",
                            bundle.to_str().ok_or("Invalid path")?,
                            repo.to_str().ok_or("Invalid path")?,
                        ],
                    )?;
                    git(&repo, &["config", "--remove-section", "remote.origin"])?;
                    if !working.join(".git").exists() {
                        fs::rename(&repo, working.join(".git")).map_err(err)?;
                    }
                    git(working, &["config", "core.bare", "false"])?;
                    git(working, &["reset", "--mixed", "HEAD"])?;
                }
                let mut marker = File::create(area.join("verified")).map_err(err)?;
                marker
                    .write_all(digest(&manifest_path(area))?.as_bytes())
                    .map_err(err)?;
                marker.sync_all().map_err(err)?;
            }
            Ok(
                serde_json::json!({"root":root,"digest":digest(&manifest_path(area))?,"bytes":m.bytes,"files":m.files.len(),"links":m.links.len()}),
            )
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn copies_binary_and_excludes_credentials_and_retries_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("é.bin"), vec![17; BLOCK + 7]).unwrap();
        fs::write(src.join(".env"), "secret").unwrap();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        let m: Manifest =
            serde_json::from_value(operate(&a, Some(&src), Operation::Snapshot).unwrap()).unwrap();
        assert_eq!(m.excluded, vec![".env"]);
        operate(
            &b,
            None,
            Operation::Stage {
                manifest: m.clone(),
            },
        )
        .unwrap();
        for f in &m.files {
            for off in (0..f.bytes).step_by(BLOCK) {
                let read = operate(
                    &a,
                    None,
                    Operation::Read {
                        path: f.path.clone(),
                        offset: off,
                    },
                )
                .unwrap();
                let op = Operation::Write {
                    path: f.path.clone(),
                    offset: off,
                    data: read["data"].as_str().unwrap().into(),
                };
                operate(&b, None, op.clone()).unwrap();
                operate(&b, None, op).unwrap();
            }
        }
        operate(&b, None, Operation::Verify).unwrap();
        assert_eq!(
            fs::read(src.join("é.bin")).unwrap(),
            fs::read(b.join("workspace/é.bin")).unwrap()
        );
        assert!(!b.join("workspace/.env").exists());
    }
    #[test]
    fn rejects_traversal_and_corrupt_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let m = Manifest {
            files: vec![Entry {
                path: "../escape".into(),
                bytes: 0,
                sha256: "0".repeat(64),
                executable: false,
            }],
            ..Default::default()
        };
        assert!(operate(dir.path(), None, Operation::Stage { manifest: m }).is_err());
        assert!(relative("/absolute").is_err());
        assert!(relative("a/../b").is_err());
    }
}

#[cfg(test)]
mod integrity_tests {
    use super::*;
    fn copy(a: &Path, b: &Path, m: &Manifest) {
        operate(
            b,
            None,
            Operation::Stage {
                manifest: m.clone(),
            },
        )
        .unwrap();
        for f in &m.files {
            for offset in (0..f.bytes.max(1)).step_by(BLOCK) {
                let data = operate(
                    a,
                    None,
                    Operation::Read {
                        path: f.path.clone(),
                        offset,
                    },
                )
                .unwrap()["data"]
                    .as_str()
                    .unwrap()
                    .into();
                operate(
                    b,
                    None,
                    Operation::Write {
                        path: f.path.clone(),
                        offset,
                        data,
                    },
                )
                .unwrap();
            }
        }
    }
    #[test]
    fn machine_transfer_detects_corruption_and_supports_sealed_retry() {
        let temp = tempfile::tempdir().unwrap();
        let src = temp.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("empty"), "").unwrap();
        fs::write(src.join("file"), "original").unwrap();
        let a = temp.path().join("a");
        let b = temp.path().join("b");
        let m: Manifest =
            serde_json::from_value(operate(&a, Some(&src), Operation::Snapshot).unwrap()).unwrap();
        copy(&a, &b, &m);
        fs::write(b.join("workspace/file"), "corrupt!").unwrap();
        assert!(operate(&b, None, Operation::Verify).is_err());
        fs::write(b.join("workspace/file"), "original").unwrap();
        let receipt = operate(&b, None, Operation::Verify).unwrap();
        assert_eq!(receipt, operate(&b, None, Operation::Verify).unwrap());
        assert_eq!(
            operate(&b, None, Operation::Stage { manifest: m }).unwrap()["sealed"],
            true
        );
        assert!(operate(
            &b,
            None,
            Operation::Write {
                path: "file".into(),
                offset: 0,
                data: STANDARD.encode(b"changed!")
            }
        )
        .is_err());
    }
    #[cfg(unix)]
    #[test]
    fn machine_transfer_preserves_executable_bits() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let src = temp.path().join("src");
        fs::create_dir(&src).unwrap();
        fs::write(src.join("run.sh"), "#!/bin/sh\ntrue\n").unwrap();
        fs::set_permissions(src.join("run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        let a = temp.path().join("a");
        let m: Manifest =
            serde_json::from_value(operate(&a, Some(&src), Operation::Snapshot).unwrap()).unwrap();
        let b = temp.path().join("b");
        copy(&a, &b, &m);
        operate(&b, None, Operation::Verify).unwrap();
        assert_ne!(
            fs::metadata(b.join("workspace/run.sh"))
                .unwrap()
                .permissions()
                .mode()
                & 0o111,
            0
        );
    }
    #[cfg(unix)]
    fn linked_source(temp: &Path) -> PathBuf {
        use std::os::unix::fs::symlink;
        let src = temp.join("src");
        fs::create_dir_all(src.join("bin")).unwrap();
        fs::create_dir_all(src.join("pkg/deep")).unwrap();
        fs::write(src.join("bin/rustup"), "tool").unwrap();
        fs::write(src.join("pkg/deep/file"), "shared").unwrap();
        symlink("rustup", src.join("bin/cargo")).unwrap();
        symlink("../pkg/deep", src.join("bin/packages")).unwrap();
        symlink("missing/doc.html", src.join("pkg/doc.html")).unwrap();
        symlink(
            src.canonicalize().unwrap().join("pkg/deep"),
            src.join("pkg/deep/absolute"),
        )
        .unwrap();
        symlink(src.canonicalize().unwrap(), src.join("root")).unwrap();
        symlink("/etc/passwd", src.join("escape")).unwrap();
        symlink("../../outside", src.join("bin/above")).unwrap();
        symlink("pkg/../bin", src.join("detour")).unwrap();
        let pipe = std::ffi::CString::new(src.join("pipe").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(pipe.as_ptr(), 0o600) }, 0);
        src
    }
    #[cfg(unix)]
    #[test]
    fn machine_transfer_recreates_links_and_leaves_external_ones_behind() {
        let temp = tempfile::tempdir().unwrap();
        let src = linked_source(temp.path());
        let a = temp.path().join("a");
        let b = temp.path().join("b");
        let m: Manifest =
            serde_json::from_value(operate(&a, Some(&src), Operation::Snapshot).unwrap()).unwrap();
        let link = |path: &str, target: &str| Link {
            path: path.into(),
            target: target.into(),
        };
        assert_eq!(
            m.links,
            vec![
                link("bin/cargo", "rustup"),
                link("bin/packages", "../pkg/deep"),
                link("pkg/deep/absolute", "../../pkg/deep"),
                link("pkg/doc.html", "missing/doc.html"),
                link("root", "."),
            ]
        );
        let skipped: Vec<_> = m
            .skipped
            .iter()
            .map(|s| (s.path.as_str(), s.reason.as_str()))
            .collect();
        assert_eq!(
            skipped,
            vec![
                ("bin/above", OUTSIDE_LINK),
                ("detour", UNUSUAL_LINK),
                ("escape", OUTSIDE_LINK),
                ("pipe", SPECIAL_FILE),
            ]
        );
        assert_eq!(m.files.len(), 2);
        operate(&a, Some(&src), Operation::CheckSource).unwrap();
        copy(&a, &b, &m);
        // No link exists while blocks are written, so none can redirect a write.
        assert!(fs::symlink_metadata(b.join("workspace/bin/cargo")).is_err());
        // An interrupted verification may already have made some of them.
        std::os::unix::fs::symlink("rustup", b.join("workspace/bin/cargo")).unwrap();
        let receipt = operate(&b, None, Operation::Verify).unwrap();
        assert_eq!(receipt["links"], 5);
        assert_eq!(receipt, operate(&b, None, Operation::Verify).unwrap());
        let root = b.join("workspace");
        for l in &m.links {
            assert_eq!(
                fs::read_link(root.join(&l.path)).unwrap(),
                Path::new(&l.target)
            );
        }
        assert_eq!(fs::read_to_string(root.join("bin/cargo")).unwrap(), "tool");
        assert_eq!(
            fs::read_to_string(root.join("bin/packages/file")).unwrap(),
            "shared"
        );
        assert_eq!(
            fs::read_to_string(root.join("pkg/deep/absolute/file")).unwrap(),
            "shared"
        );
        for absent in ["escape", "bin/above", "detour", "pipe"] {
            assert!(fs::symlink_metadata(root.join(absent)).is_err());
        }
        // The moved workspace can move again, and a retargeted link is a change.
        let c = temp.path().join("c");
        let again: Manifest =
            serde_json::from_value(operate(&c, Some(&root), Operation::Snapshot).unwrap()).unwrap();
        assert_eq!(again.links, m.links);
        fs::remove_file(root.join("bin/cargo")).unwrap();
        std::os::unix::fs::symlink("packages", root.join("bin/cargo")).unwrap();
        assert!(operate(&c, Some(&root), Operation::CheckSource).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn machine_transfer_refuses_a_conflicting_path_at_a_link() {
        let temp = tempfile::tempdir().unwrap();
        let src = linked_source(temp.path());
        let a = temp.path().join("a");
        let b = temp.path().join("b");
        let m: Manifest =
            serde_json::from_value(operate(&a, Some(&src), Operation::Snapshot).unwrap()).unwrap();
        copy(&a, &b, &m);
        std::os::unix::fs::symlink("/etc", b.join("workspace/bin/cargo")).unwrap();
        assert!(operate(&b, None, Operation::Verify).is_err());
    }
    #[test]
    fn machine_transfer_refuses_links_that_leave_the_workspace() {
        let manifest = |path: &str, target: &str| Manifest {
            links: vec![Link {
                path: path.into(),
                target: target.into(),
            }],
            ..Default::default()
        };
        for (path, target) in [
            ("a/b", "c"),
            ("a/b", "../c/d"),
            ("a/b", ".."),
            ("a", "."),
            ("a/b/c", "../../d"),
        ] {
            validate(&manifest(path, target)).unwrap();
        }
        for (path, target) in [
            ("a", "../b"),
            ("a/b", "../../c"),
            ("a", "/etc/passwd"),
            ("a", "b/../../c"),
            ("a/b", "c/../d"),
            ("a", ""),
            ("a", "b\\c"),
            ("../a", "b"),
            (".ssh/config", "b"),
            ("a/.env", "b"),
        ] {
            assert!(
                validate(&manifest(path, target)).is_err(),
                "{path} -> {target}"
            );
        }
        // Nothing may be written beneath a link, and a path is either one or a file.
        let file = |path: &str| Entry {
            path: path.into(),
            bytes: 0,
            sha256: "0".repeat(64),
            executable: false,
        };
        let mut beneath = manifest("a", "b");
        beneath.files = vec![file("a/c")];
        assert!(validate(&beneath).is_err());
        let mut nested = manifest("a", "b");
        nested.links.push(Link {
            path: "a/c".into(),
            target: "d".into(),
        });
        assert!(validate(&nested).is_err());
        let mut both = manifest("a", "b");
        both.files = vec![file("a")];
        assert!(validate(&both).is_err());
    }
    #[test]
    fn manifests_without_links_keep_their_previous_encoding() {
        let old = r#"{"files":[],"excluded":[".env"],"bytes":0}"#;
        let m: Manifest = serde_json::from_str(old).unwrap();
        assert!(m.links.is_empty() && m.skipped.is_empty());
        assert_eq!(serde_json::to_string(&m).unwrap(), old);
    }
    #[test]
    fn an_oversized_workspace_is_refused_with_its_totals() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("big/nested")).unwrap();
        fs::create_dir_all(temp.path().join("target")).unwrap();
        fs::write(temp.path().join("big/nested/a"), vec![0; 2 * BLOCK]).unwrap();
        fs::write(temp.path().join("big/b"), "b").unwrap();
        fs::write(temp.path().join("small"), "s").unwrap();
        fs::write(temp.path().join("target/ignored"), vec![0; 4 * BLOCK]).unwrap();
        measure(temp.path(), 3 * BLOCK as u64, 3).unwrap();
        let bytes = measure(temp.path(), BLOCK as u64, 3).unwrap_err();
        assert!(bytes.contains("2.0 MiB in 3 files"), "{bytes}");
        assert!(
            bytes.contains("Largest: big (2.0 MiB, 2 files), small"),
            "{bytes}"
        );
        assert!(measure(temp.path(), 3 * BLOCK as u64, 2).is_err());
    }
    #[test]
    fn machine_transfer_preserves_git_history_and_uncommitted_work() {
        let temp = tempfile::tempdir().unwrap();
        let src = temp.path().join("src");
        fs::create_dir(&src).unwrap();
        git(&src, &["init"]).unwrap();
        fs::write(src.join("file"), "committed").unwrap();
        git(&src, &["add", "file"]).unwrap();
        git(
            &src,
            &[
                "-c",
                "user.name=Transfer Test",
                "-c",
                "user.email=transfer@example.invalid",
                "commit",
                "-m",
                "checkpoint",
            ],
        )
        .unwrap();
        fs::write(src.join("file"), "uncommitted").unwrap();
        let a = temp.path().join("a");
        let b = temp.path().join("b");
        let m: Manifest =
            serde_json::from_value(operate(&a, Some(&src), Operation::Snapshot).unwrap()).unwrap();
        copy(&a, &b, &m);
        operate(&b, None, Operation::Verify).unwrap();
        assert_eq!(
            fs::read_to_string(b.join("workspace/file")).unwrap(),
            "uncommitted"
        );
        git(&b.join("workspace"), &["rev-parse", "HEAD"]).unwrap();
        // A second move snapshots the updated repository, not the old bundle.
        let c = temp.path().join("c");
        operate(&c, Some(&b.join("workspace")), Operation::Snapshot).unwrap();
        operate(&c, Some(&b.join("workspace")), Operation::CheckSource).unwrap();
        fs::write(b.join("workspace/file"), "edited after preparation").unwrap();
        assert!(operate(&c, Some(&b.join("workspace")), Operation::CheckSource).is_err());
        fs::write(b.join("workspace/file"), "uncommitted").unwrap();
        git(&b.join("workspace"), &["branch", "created-after-snapshot"]).unwrap();
        assert!(operate(&c, Some(&b.join("workspace")), Operation::CheckSource).is_err());
    }
}
