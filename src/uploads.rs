//! Bounded binary uploads with server-owned, immutable paths.
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

pub const MAX_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_BODY_BYTES: usize = 28 * 1024 * 1024;
pub const MAX_RESUMABLE_BYTES: u64 = 2 * 1024 * 1024 * 1024; // 2 GiB
pub const DEFAULT_CHUNK_BYTES: usize = 4 * 1024 * 1024; // 4 MiB
pub const MAX_CHUNK_BYTES: usize = 16 * 1024 * 1024; // 16 MiB
pub static SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
pub static CHUNK_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(8);

/// Where a file lands inside a folder upload: `<root>/<batch_id>/<relative_path>`.
/// Both are absent for a single file, which lands at `<root>/<uuid>/<name>`.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct Placement {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relative_path: Option<String>,
    /// Secret chosen by the batch's creator. The first file claims the batch
    /// with it; later files must present the same token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_token: Option<String>,
}

/// A batch accepts files for this long after its first file; then it is sealed.
pub const BATCH_OPEN_SECS: u64 = 6 * 60 * 60;

/// SHA-256 of a well-formed batch token. Only this digest is ever written to disk.
fn token_digest(token: &str) -> Result<String, String> {
    if token.len() < 32
        || token.len() > 128
        || !token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("Invalid folder upload token".into());
    }
    Ok(hex::encode(Sha256::digest(token.as_bytes())))
}

/// The placement as persisted in session metadata: the raw token replaced by its digest.
fn stored_placement(placement: &Placement) -> Result<(Placement, Option<String>), String> {
    let digest = placement
        .batch_token
        .as_deref()
        .map(token_digest)
        .transpose()?;
    Ok((
        Placement {
            batch_token: None,
            ..placement.clone()
        },
        digest,
    ))
}

/// Claims `batch` for a token digest, or checks that the digest owns it. The
/// claim is an atomic `create_new` of `<root>/.batches/<batch>`.
fn claim_batch(root: &Path, batch: &str, digest: &str) -> Result<(), String> {
    let owners = root.join(".batches");
    fs::create_dir_all(&owners).map_err(|e| format!("Create batch registry: {e}"))?;
    let owner = owners.join(batch);
    let digest = digest.to_string();
    // Write the digest beside the registry entry, then link it into place:
    // link() is atomic and never replaces, so a reader sees all or nothing.
    let staged = owners.join(format!(".{batch}.{}", uuid::Uuid::new_v4()));
    fs::write(&staged, digest.as_bytes()).map_err(|e| format!("Record batch owner: {e}"))?;
    let linked = fs::hard_link(&staged, &owner);
    let _ = fs::remove_file(&staged);
    match linked {
        Ok(()) => return Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(format!("Record batch owner: {e}")),
    }
    let stored = fs::read(&owner).map_err(|_| "This folder upload belongs to someone else")?;
    let same = stored.len() == digest.len()
        && stored
            .iter()
            .zip(digest.as_bytes())
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0;
    if !same {
        return Err("This folder upload belongs to someone else".into());
    }
    let age = fs::metadata(&owner)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .map(|d| d.as_secs())
        .unwrap_or(u64::MAX);
    if age > BATCH_OPEN_SECS {
        return Err("This folder upload is closed; upload the folder again".into());
    }
    Ok(())
}

#[derive(Deserialize, Serialize)]
pub struct Upload {
    pub name: String,
    pub data_base64: String,
    #[serde(flatten)]
    pub placement: Placement,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Receipt {
    pub name: String,
    pub path: String,
    pub size: usize,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionInit {
    pub upload_id: String,
    pub name: String,
    pub size: u64,
    #[serde(default)]
    pub chunk_size: Option<usize>,
    #[serde(flatten)]
    pub placement: Placement,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct SessionStatus {
    pub upload_id: String,
    pub name: String,
    pub size: u64,
    pub chunk_size: usize,
    pub total_chunks: usize,
    pub received_chunks: Vec<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Receipt>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct SessionMeta {
    upload_id: String,
    name: String,
    size: u64,
    chunk_size: usize,
    total_chunks: usize,
    #[serde(default)]
    receipt: Option<Receipt>,
    /// Never holds `batch_token`; see `batch_token_digest`.
    #[serde(flatten)]
    placement: Placement,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    batch_token_digest: Option<String>,
}

pub fn validate_upload_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || name.len() > 240
        || name == "."
        || name == ".."
        || name.contains(['/', '\\'])
        || name.chars().any(char::is_control)
    {
        return Err("Choose a file with a plain filename (up to 240 bytes)".into());
    }
    Ok(())
}

/// NFC, as typed text is: macOS hands out NFD names, and a mention must match the path.
fn nfc(value: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    value.nfc().collect()
}

pub const MAX_FOLDER_DEPTH: usize = 32;
pub const MAX_RELATIVE_PATH_BYTES: usize = 1024;

/// A path inside a folder upload, normalized: relative, `/`-separated, every
/// segment a plain filename, never `.`/`..`, absolute, or a Windows drive.
pub fn validate_relative_upload_path(relative: &str) -> Result<String, String> {
    let relative = nfc(relative);
    let parts: Vec<&str> = relative.split('/').collect();
    if relative.is_empty()
        || relative.len() > MAX_RELATIVE_PATH_BYTES
        || parts.len() > MAX_FOLDER_DEPTH
        || relative.contains(':')
    {
        return Err("Choose a folder with shorter, plain paths".into());
    }
    for part in &parts {
        validate_upload_name(part)?;
    }
    Ok(relative)
}

/// Creates the parent directory and returns where the file must be created.
/// The result is always inside `root` (already canonical).
fn destination(
    root: &Path,
    name: &str,
    placement: &Placement,
    digest: Option<&str>,
) -> Result<PathBuf, String> {
    match (&placement.batch_id, &placement.relative_path) {
        (None, None) => {
            let directory = root.join(uuid::Uuid::new_v4().to_string());
            fs::create_dir(&directory).map_err(|e| e.to_string())?;
            Ok(directory.join(nfc(name)))
        }
        (Some(batch), Some(relative)) => {
            let batch = uuid::Uuid::parse_str(batch)
                .map_err(|_| "Invalid folder upload ID".to_string())?
                .hyphenated()
                .to_string();
            let relative = validate_relative_upload_path(relative)?;
            let digest = digest.ok_or("Folder uploads need a batch token")?;
            claim_batch(root, &batch, digest)?;
            let path = root.join(batch).join(&relative);
            let parent = path.parent().ok_or("Invalid folder path")?;
            fs::create_dir_all(parent).map_err(|e| format!("Create upload folder: {e}"))?;
            // Directories are created here, never followed through a link.
            let canonical = parent.canonicalize().map_err(|e| e.to_string())?;
            if !canonical.starts_with(root) || canonical != parent {
                return Err("Invalid folder path".into());
            }
            Ok(path)
        }
        _ => Err("Folder uploads need both batch_id and relative_path".into()),
    }
}

pub fn validate_upload_id(upload_id: &str) -> Result<(), String> {
    if upload_id.is_empty()
        || upload_id.len() > 128
        || !upload_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        return Err("Invalid upload session ID".into());
    }
    Ok(())
}

fn session_dir(root: &Path, upload_id: &str) -> Result<PathBuf, String> {
    validate_upload_id(upload_id)?;
    fs::create_dir_all(root).map_err(|e| format!("Create upload directory: {e}"))?;
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let sessions = root.join(".sessions");
    fs::create_dir_all(&sessions).map_err(|e| format!("Create sessions directory: {e}"))?;
    Ok(sessions.join(upload_id))
}

fn read_bitmap(dir: &Path, total_chunks: usize) -> Vec<usize> {
    let Ok(bytes) = fs::read(dir.join("bitmap.bin")) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (idx, b) in bytes.into_iter().take(total_chunks).enumerate() {
        if b == 1 {
            out.push(idx);
        }
    }
    out
}

fn mark_bitmap_chunk(dir: &Path, total_chunks: usize, index: usize) -> Result<(), String> {
    let bitmap_path = dir.join("bitmap.bin");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&bitmap_path)
        .map_err(|e| format!("Open session bitmap: {e}"))?;
    if file.metadata().map_err(|e| e.to_string())?.len() < total_chunks as u64 {
        file.set_len(total_chunks as u64)
            .map_err(|e| e.to_string())?;
    }
    file.seek(SeekFrom::Start(index as u64))
        .map_err(|e| e.to_string())?;
    file.write_all(&[1]).map_err(|e| e.to_string())?;
    file.flush().map_err(|e| e.to_string())?;
    Ok(())
}

pub fn init_or_status_session(root: &Path, req: SessionInit) -> Result<SessionStatus, String> {
    validate_upload_id(&req.upload_id)?;
    validate_upload_name(&req.name)?;
    if let Some(relative) = &req.placement.relative_path {
        validate_relative_upload_path(relative)?;
        let (_, digest) = stored_placement(&req.placement)?;
        let digest = digest.ok_or("Folder uploads need a batch token")?;
        let batch = uuid::Uuid::parse_str(req.placement.batch_id.as_deref().unwrap_or(""))
            .map_err(|_| "Invalid folder upload ID".to_string())?
            .hyphenated()
            .to_string();
        fs::create_dir_all(root).map_err(|e| format!("Create upload directory: {e}"))?;
        claim_batch(
            &root.canonicalize().map_err(|e| e.to_string())?,
            &batch,
            &digest,
        )?;
    }
    if req.size > MAX_RESUMABLE_BYTES {
        return Err("Files must be 2 GiB or smaller".into());
    }
    let chunk_size = req.chunk_size.unwrap_or(DEFAULT_CHUNK_BYTES);
    if chunk_size == 0 || chunk_size > MAX_CHUNK_BYTES {
        return Err("Invalid upload chunk size".into());
    }
    let total_chunks = if req.size == 0 {
        1
    } else {
        (req.size as usize).div_ceil(chunk_size)
    };
    let dir = session_dir(root, &req.upload_id)?;
    fs::create_dir_all(&dir).map_err(|e| format!("Create upload session: {e}"))?;
    let meta_path = dir.join("meta.json");
    if meta_path.is_file() {
        let existing: SessionMeta = serde_json::from_slice(
            &fs::read(&meta_path).map_err(|e| format!("Read session metadata: {e}"))?,
        )
        .map_err(|e| format!("Parse session metadata: {e}"))?;
        if existing.name != req.name
            || (
                existing.placement.clone(),
                existing.batch_token_digest.clone(),
            ) != stored_placement(&req.placement)?
            || existing.size != req.size
            || existing.chunk_size != chunk_size
        {
            return Err("Upload session parameters do not match existing session".into());
        }
        let received_chunks = if existing.receipt.is_some() {
            (0..existing.total_chunks).collect()
        } else {
            read_bitmap(&dir, existing.total_chunks)
        };
        return Ok(SessionStatus {
            upload_id: existing.upload_id,
            name: existing.name,
            size: existing.size,
            chunk_size: existing.chunk_size,
            total_chunks: existing.total_chunks,
            received_chunks,
            receipt: existing.receipt,
        });
    }
    let part_path = dir.join("payload.part");
    let part = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&part_path)
        .map_err(|e| format!("Create upload staging file: {e}"))?;
    part.set_len(req.size)
        .map_err(|e| format!("Allocate upload staging file: {e}"))?;
    let bitmap = vec![0u8; total_chunks];
    fs::write(dir.join("bitmap.bin"), &bitmap)
        .map_err(|e| format!("Initialize upload bitmap: {e}"))?;
    let meta = SessionMeta {
        upload_id: req.upload_id.clone(),
        name: req.name.clone(),
        size: req.size,
        chunk_size,
        total_chunks,
        receipt: None,
        placement: stored_placement(&req.placement)?.0,
        batch_token_digest: stored_placement(&req.placement)?.1,
    };
    fs::write(
        &meta_path,
        serde_json::to_vec(&meta).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("Write session metadata: {e}"))?;
    Ok(SessionStatus {
        upload_id: meta.upload_id,
        name: meta.name,
        size: meta.size,
        chunk_size: meta.chunk_size,
        total_chunks: meta.total_chunks,
        received_chunks: Vec::new(),
        receipt: None,
    })
}

pub fn write_session_chunk(
    root: &Path,
    upload_id: &str,
    index: usize,
    bytes: &[u8],
) -> Result<SessionStatus, String> {
    let dir = session_dir(root, upload_id)?;
    let meta_path = dir.join("meta.json");
    let meta: SessionMeta = serde_json::from_slice(
        &fs::read(&meta_path).map_err(|_| "Upload session not found; reinitialize the upload")?,
    )
    .map_err(|e| format!("Invalid session metadata: {e}"))?;
    if let Some(receipt) = meta.receipt {
        return Ok(SessionStatus {
            upload_id: meta.upload_id,
            name: meta.name,
            size: meta.size,
            chunk_size: meta.chunk_size,
            total_chunks: meta.total_chunks,
            received_chunks: (0..meta.total_chunks).collect(),
            receipt: Some(receipt),
        });
    }
    if index >= meta.total_chunks {
        return Err("Chunk index out of bounds".into());
    }
    let offset = (index as u64)
        .checked_mul(meta.chunk_size as u64)
        .ok_or("Chunk offset overflow")?;
    let expected_len = if meta.size == 0 {
        0
    } else if index + 1 == meta.total_chunks {
        (meta.size - offset) as usize
    } else {
        meta.chunk_size
    };
    if bytes.len() != expected_len {
        return Err(format!(
            "Chunk {index} size mismatch: expected {expected_len} bytes, got {}",
            bytes.len()
        ));
    }
    let part_path = dir.join("payload.part");
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&part_path)
        .map_err(|e| format!("Open staging payload: {e}"))?;
    file.seek(SeekFrom::Start(offset))
        .map_err(|e| format!("Seek staging payload: {e}"))?;
    file.write_all(bytes)
        .map_err(|e| format!("Write chunk {index}: {e}"))?;
    file.flush()
        .map_err(|e| format!("Flush chunk {index}: {e}"))?;
    mark_bitmap_chunk(&dir, meta.total_chunks, index)?;
    Ok(SessionStatus {
        upload_id: meta.upload_id,
        name: meta.name,
        size: meta.size,
        chunk_size: meta.chunk_size,
        total_chunks: meta.total_chunks,
        received_chunks: read_bitmap(&dir, meta.total_chunks),
        receipt: None,
    })
}

pub fn complete_session(root: &Path, upload_id: &str) -> Result<Receipt, String> {
    let dir = session_dir(root, upload_id)?;
    let meta_path = dir.join("meta.json");
    let mut meta: SessionMeta = serde_json::from_slice(
        &fs::read(&meta_path).map_err(|_| "Upload session not found; reinitialize the upload")?,
    )
    .map_err(|e| format!("Invalid session metadata: {e}"))?;
    if let Some(receipt) = meta.receipt {
        return Ok(receipt);
    }
    let received = read_bitmap(&dir, meta.total_chunks);
    if received.len() != meta.total_chunks {
        return Err(format!(
            "Upload incomplete: received {}/{} chunks",
            received.len(),
            meta.total_chunks
        ));
    }
    let part_path = dir.join("payload.part");
    let mut part = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&part_path)
        .map_err(|e| format!("Open staged upload: {e}"))?;
    part.sync_all()
        .map_err(|e| format!("Sync staged upload: {e}"))?;
    let actual_size = part.metadata().map_err(|e| e.to_string())?.len();
    if actual_size != meta.size {
        return Err("Staged upload size mismatch".into());
    }
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = part
            .read(&mut buf)
            .map_err(|e| format!("Hash staged upload: {e}"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let sha256 = hex::encode(hasher.finalize());
    drop(part);

    let canonical_root = root.canonicalize().map_err(|e| e.to_string())?;
    let final_path = destination(
        &canonical_root,
        &meta.name,
        &meta.placement,
        meta.batch_token_digest.as_deref(),
    )?;
    // link() fails if the target exists: an atomic no-replace placement, so a
    // concurrent upload of the same path can never overwrite the other.
    if let Err(e) = fs::hard_link(&part_path, &final_path) {
        if meta.placement.batch_id.is_none() {
            let _ = fs::remove_dir(final_path.parent().unwrap_or(&canonical_root));
        }
        return Err(if e.kind() == std::io::ErrorKind::AlreadyExists {
            "A file with this path was already uploaded".into()
        } else {
            format!("Finalize uploaded file: {e}")
        });
    }
    let _ = fs::remove_file(&part_path);
    let _ = fs::remove_file(dir.join("bitmap.bin"));
    let receipt = Receipt {
        name: nfc(&meta.name),
        path: final_path.to_string_lossy().into_owned(),
        size: meta.size as usize,
        sha256,
    };
    meta.receipt = Some(receipt.clone());
    let _ = fs::write(&meta_path, serde_json::to_vec(&meta).unwrap_or_default());
    Ok(receipt)
}

pub fn cancel_session(root: &Path, upload_id: &str) -> Result<(), String> {
    let dir = session_dir(root, upload_id)?;
    if dir.exists() {
        fs::remove_dir_all(&dir).map_err(|e| format!("Remove upload session: {e}"))?;
    }
    Ok(())
}

pub fn store(root: &Path, upload: Upload) -> Result<Receipt, String> {
    validate_upload_name(&upload.name)?;
    if upload.data_base64.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err("Files must be 20 MiB or smaller".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(upload.data_base64)
        .map_err(|_| "Invalid file encoding")?;
    if bytes.len() > MAX_BYTES {
        return Err("Files must be 20 MiB or smaller".into());
    }
    std::fs::create_dir_all(root).map_err(|e| format!("Create upload directory: {e}"))?;
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let (_, digest) = stored_placement(&upload.placement)?;
    let path = destination(&root, &upload.name, &upload.placement, digest.as_deref())?;
    let single = upload.placement.batch_id.is_none();
    let result: Result<Receipt, String> = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|e| format!("Create uploaded file: {e}"))?;
        file.write_all(&bytes)
            .map_err(|e| format!("Write uploaded file: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("Persist uploaded file: {e}"))?;
        Ok(Receipt {
            name: nfc(&upload.name),
            path: path.to_string_lossy().into_owned(),
            size: bytes.len(),
            sha256: hex::encode(Sha256::digest(&bytes)),
        })
    })();
    if let Err(error) = &result {
        // Never remove a file this request did not create.
        if !error.starts_with("Create uploaded file") {
            let _ = std::fs::remove_file(&path);
        }
        if single {
            let _ = std::fs::remove_dir(path.parent().unwrap_or(&root));
        }
    }
    result
}

/// Removes any upload directories (`<root>/<uuid>`) referenced in `prompt`
/// once the session completes, so temporary attachments do not accumulate.
pub fn cleanup_prompt_uploads(root: &Path, prompt: &str) {
    if prompt.is_empty() {
        return;
    }
    let mut roots = Vec::new();
    if let Ok(canon) = root.canonicalize() {
        roots.push(canon);
    }
    if !roots.iter().any(|r| r == root) {
        roots.push(root.to_path_buf());
    }
    for base in &roots {
        let prefix = format!("{}/", base.to_string_lossy().trim_end_matches('/'));
        let mut cursor = 0usize;
        while let Some(idx) = prompt[cursor..].find(&prefix) {
            let after = cursor + idx + prefix.len();
            let rest = &prompt[after..];
            let seg_len = rest
                .find(['/', '"', '\'', ']', ')', ' ', '\n', '\r', '\t'])
                .unwrap_or(rest.len());
            let segment = &rest[..seg_len];
            if let Ok(id) = uuid::Uuid::parse_str(segment) {
                let id_str = id.hyphenated().to_string();
                let target = base.join(&id_str);
                let _ = fs::remove_dir_all(&target);
                let _ = fs::remove_file(base.join(".batches").join(&id_str));
            }
            cursor = after + seg_len.max(1);
        }
    }
}

/// Sweeps `<root>`, `<root>/.sessions`, and `<root>/.batches` and removes
/// temporary upload directories older than `max_age`.
pub fn prune_expired_uploads(root: &Path, max_age: std::time::Duration) {
    let is_expired = |path: &Path| -> bool {
        fs::metadata(path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age > max_age)
    };
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name == ".sessions" || name == ".batches" {
            if let Ok(sub) = fs::read_dir(&path) {
                for item in sub.flatten() {
                    let sub_path = item.path();
                    if is_expired(&sub_path) {
                        if sub_path.is_dir() {
                            let _ = fs::remove_dir_all(&sub_path);
                        } else {
                            let _ = fs::remove_file(&sub_path);
                        }
                    }
                }
            }
            continue;
        }
        if uuid::Uuid::parse_str(name).is_ok() && is_expired(&path) {
            let _ = fs::remove_dir_all(&path);
            let _ = fs::remove_file(root.join(".batches").join(name));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const TOKEN: &str = "a3f1c2d4e5f60718293a4b5c6d7e8f90a1b2c3d4";
    fn folder(batch: &str, relative: &str) -> Placement {
        Placement {
            batch_id: Some(batch.into()),
            relative_path: Some(relative.into()),
            batch_token: Some(TOKEN.into()),
        }
    }
    #[test]
    fn a_batch_only_takes_files_from_its_creator() {
        let root = tempfile::tempdir().unwrap();
        let up = |placement: Placement| {
            store(
                root.path(),
                Upload {
                    name: "a.txt".into(),
                    data_base64: "YQ==".into(),
                    placement,
                },
            )
        };
        up(folder(BATCH, "F/a.txt")).unwrap();
        let mut foreign = folder(BATCH, "F/b.txt");
        foreign.batch_token = Some("ffffffffffffffffffffffffffffffffffffffff".into());
        assert!(up(foreign).unwrap_err().contains("someone else"));
        let mut missing = folder(BATCH, "F/c.txt");
        missing.batch_token = None;
        assert!(up(missing).is_err());
        let mut short = folder(BATCH, "F/d.txt");
        short.batch_token = Some("short".into());
        assert!(up(short).is_err());
        up(folder(BATCH, "F/e.txt")).unwrap();
        let batch_dir = root.path().canonicalize().unwrap().join(BATCH).join("F");
        let mut names: Vec<_> = fs::read_dir(batch_dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, vec!["a.txt", "e.txt"]);
    }
    #[test]
    fn session_metadata_never_stores_the_batch_token() {
        let root = tempfile::tempdir().unwrap();
        let init = SessionInit {
            upload_id: "sess_secret".into(),
            name: "a.bin".into(),
            size: 1,
            chunk_size: Some(4),
            placement: folder(BATCH, "F/a.bin"),
        };
        init_or_status_session(root.path(), init.clone()).unwrap();
        let meta = root.path().join(".sessions/sess_secret/meta.json");
        assert!(!fs::read_to_string(&meta).unwrap().contains(TOKEN));
        // Resuming with the same token works; another token does not.
        init_or_status_session(root.path(), init.clone()).unwrap();
        let mut foreign = init.clone();
        foreign.placement.batch_token = Some("ffffffffffffffffffffffffffffffffffffffff".into());
        assert!(init_or_status_session(root.path(), foreign).is_err());
        write_session_chunk(root.path(), "sess_secret", 0, b"z").unwrap();
        complete_session(root.path(), "sess_secret").unwrap();
        let meta = fs::read_to_string(&meta).unwrap();
        assert!(!meta.contains(TOKEN));
        assert!(meta.contains(&hex::encode(Sha256::digest(TOKEN.as_bytes()))));
    }
    #[test]
    fn concurrent_uploads_of_one_path_never_overwrite() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().to_path_buf();
        let results: Vec<_> = (0..8)
            .map(|i| {
                let path = path.clone();
                std::thread::spawn(move || {
                    let id = format!("race_{i}");
                    init_or_status_session(
                        &path,
                        SessionInit {
                            upload_id: id.clone(),
                            name: "same.txt".into(),
                            size: 1,
                            chunk_size: Some(4),
                            placement: folder(BATCH, "F/same.txt"),
                        },
                    )
                    .unwrap();
                    write_session_chunk(&path, &id, 0, &[b'0' + i as u8]).unwrap();
                    complete_session(&path, &id)
                })
            })
            .map(|t| t.join().unwrap())
            .collect();
        let winners: Vec<_> = results.iter().filter_map(|r| r.as_ref().ok()).collect();
        assert_eq!(winners.len(), 1, "{results:?}");
        let content = fs::read(&winners[0].path).unwrap();
        assert_eq!(winners[0].sha256, hex::encode(Sha256::digest(&content)));
    }
    const BATCH: &str = "497dfe42-8ff1-44a8-b0f8-6b74a4866833";
    #[test]
    fn folder_uploads_keep_their_tree_under_one_batch() {
        let root = tempfile::tempdir().unwrap();
        let canonical = root.path().canonicalize().unwrap();
        // NFD "ã" from macOS lands as NFC, so the mention typed by a user matches.
        let nfd = "Questo\u{0303}es (1)/sub dir/key (1).pdf";
        let upload = |relative: &str| Upload {
            name: relative.rsplit('/').next().unwrap().into(),
            data_base64: "YQ==".into(),
            placement: folder(BATCH, relative),
        };
        let a = store(root.path(), upload(nfd)).unwrap();
        let b = store(root.path(), upload("Questões (1)/b.txt")).unwrap();
        assert_eq!(
            a.path,
            canonical
                .join(BATCH)
                .join("Questões (1)/sub dir/key (1).pdf")
                .to_string_lossy()
        );
        assert!(b.path.ends_with("/Questões (1)/b.txt"));
        // The same path in the same batch is never overwritten.
        assert!(store(root.path(), upload("Questões (1)/b.txt")).is_err());
        assert_eq!(std::fs::read(&b.path).unwrap(), b"a");
    }
    #[test]
    fn folder_uploads_reject_traversal_and_malformed_placements() {
        let root = tempfile::tempdir().unwrap();
        for relative in [
            "../escape.txt",
            "a/../../escape.txt",
            "/etc/passwd",
            "a//b.txt",
            "a/./b.txt",
            "a\\b.txt",
            "C:/x.txt",
            "a/b\nc.txt",
            "",
        ] {
            assert!(
                validate_relative_upload_path(relative).is_err(),
                "{relative:?} must be refused"
            );
            assert!(store(
                root.path(),
                Upload {
                    name: "x.txt".into(),
                    data_base64: "YQ==".into(),
                    placement: folder(BATCH, relative),
                }
            )
            .is_err());
        }
        let deep = vec!["d"; MAX_FOLDER_DEPTH + 1].join("/");
        assert!(validate_relative_upload_path(&deep).is_err());
        for placement in [
            folder("../x", "a/b.txt"),
            Placement {
                batch_id: Some(BATCH.into()),
                relative_path: None,
                batch_token: Some(TOKEN.into()),
            },
            Placement {
                batch_id: None,
                relative_path: Some("a/b.txt".into()),
                batch_token: Some(TOKEN.into()),
            },
        ] {
            assert!(store(
                root.path(),
                Upload {
                    name: "b.txt".into(),
                    data_base64: "YQ==".into(),
                    placement,
                }
            )
            .is_err());
        }
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
        #[cfg(unix)]
        {
            // A link planted inside a batch is never followed.
            let outside = tempfile::tempdir().unwrap();
            std::fs::create_dir_all(root.path().join(BATCH)).unwrap();
            std::os::unix::fs::symlink(outside.path(), root.path().join(BATCH).join("a")).unwrap();
            assert!(store(
                root.path(),
                Upload {
                    name: "b.txt".into(),
                    data_base64: "YQ==".into(),
                    placement: folder(BATCH, "a/b.txt"),
                }
            )
            .is_err());
            assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
        }
    }
    #[test]
    fn resumable_folder_session_places_the_file_in_its_batch() {
        let root = tempfile::tempdir().unwrap();
        let init = SessionInit {
            upload_id: "sess_folder".into(),
            name: "big.bin".into(),
            size: 3,
            chunk_size: Some(4),
            placement: folder(BATCH, "Data/raw/big.bin"),
        };
        init_or_status_session(root.path(), init.clone()).unwrap();
        // Same id, different placement: refused instead of silently resumed.
        let mut other = init.clone();
        other.placement = folder(BATCH, "Data/other.bin");
        assert!(init_or_status_session(root.path(), other).is_err());
        write_session_chunk(root.path(), "sess_folder", 0, b"abc").unwrap();
        let receipt = complete_session(root.path(), "sess_folder").unwrap();
        assert!(receipt.path.ends_with(&format!("{BATCH}/Data/raw/big.bin")));
    }
    #[test]
    fn binary_uploads_are_exact_and_never_overwrite() {
        let root = tempfile::tempdir().unwrap();
        let make = || Upload {
            name: "image é.png".into(),
            data_base64: "AP8BAg==".into(),
            placement: Placement::default(),
        };
        let a = store(root.path(), make()).unwrap();
        let b = store(root.path(), make()).unwrap();
        assert_ne!(a.path, b.path);
        assert_eq!(a.size, 4);
        assert_eq!(std::fs::read(a.path).unwrap(), [0, 255, 1, 2]);
        assert_eq!(a.sha256, b.sha256);
    }
    #[test]
    fn rejects_paths_and_invalid_data_without_writes() {
        let root = tempfile::tempdir().unwrap();
        for name in ["../secret", "/tmp/x", "..", "a\\b", "a\nb"] {
            assert!(store(
                root.path(),
                Upload {
                    name: name.into(),
                    data_base64: "YQ==".into(),
                    placement: Placement::default(),
                }
            )
            .is_err());
        }
        assert!(store(
            root.path(),
            Upload {
                name: "a".into(),
                data_base64: "!".into(),
                placement: Placement::default(),
            }
        )
        .is_err());
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    }
    #[test]
    fn resumable_session_tracks_out_of_order_chunks_and_assembles_exact_file() {
        let root = tempfile::tempdir().unwrap();
        let init = SessionInit {
            upload_id: "sess_12345".into(),
            name: "video.mp4".into(),
            size: 10,
            chunk_size: Some(4),
            placement: Placement::default(),
        };
        let status = init_or_status_session(root.path(), init.clone()).unwrap();
        assert_eq!(status.total_chunks, 3);
        assert!(status.received_chunks.is_empty());

        // Write chunk 2 (last 2 bytes) then chunk 0 (first 4 bytes)
        let s2 = write_session_chunk(root.path(), "sess_12345", 2, b"89").unwrap();
        assert_eq!(s2.received_chunks, vec![2]);
        let s0 = write_session_chunk(root.path(), "sess_12345", 0, b"0123").unwrap();
        assert_eq!(s0.received_chunks, vec![0, 2]);

        // Re-querying status returns existing bitmap so interrupted client knows only chunk 1 is missing
        let resumed = init_or_status_session(root.path(), init.clone()).unwrap();
        assert_eq!(resumed.received_chunks, vec![0, 2]);
        assert!(complete_session(root.path(), "sess_12345").is_err());

        // Write missing chunk 1 and complete
        let s1 = write_session_chunk(root.path(), "sess_12345", 1, b"4567").unwrap();
        assert_eq!(s1.received_chunks, vec![0, 1, 2]);
        let receipt = complete_session(root.path(), "sess_12345").unwrap();
        assert_eq!(receipt.size, 10);
        assert_eq!(std::fs::read(&receipt.path).unwrap(), b"0123456789");

        // Idempotent complete returns same receipt
        let again = complete_session(root.path(), "sess_12345").unwrap();
        assert_eq!(again, receipt);
    }

    #[test]
    fn cleanup_prompt_uploads_removes_session_attachments_and_preserves_unreferenced() {
        let root = tempfile::tempdir().unwrap();
        let a = store(
            root.path(),
            Upload {
                name: "report (1).pdf".into(),
                data_base64: "YQ==".into(),
                placement: Placement::default(),
            },
        )
        .unwrap();
        let b = store(
            root.path(),
            Upload {
                name: "keep.txt".into(),
                data_base64: "Yg==".into(),
                placement: Placement::default(),
            },
        )
        .unwrap();
        let c = store(
            root.path(),
            Upload {
                name: "photo.png".into(),
                data_base64: "Yw==".into(),
                placement: Placement::default(),
            },
        )
        .unwrap();
        assert!(Path::new(&a.path).exists());
        assert!(Path::new(&b.path).exists());
        assert!(Path::new(&c.path).exists());

        let prompt = format!("Inspect @\"{}\" and [Uploaded: {}] please", a.path, c.path);
        cleanup_prompt_uploads(root.path(), &prompt);
        assert!(!Path::new(&a.path).exists());
        assert!(Path::new(&b.path).exists());
        assert!(!Path::new(&c.path).exists());
    }
}
