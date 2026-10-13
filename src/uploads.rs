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

#[derive(Deserialize, Serialize)]
pub struct Upload {
    pub name: String,
    pub data_base64: String,
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
    let directory = canonical_root.join(uuid::Uuid::new_v4().to_string());
    fs::create_dir(&directory).map_err(|e| e.to_string())?;
    let final_path = directory.join(&meta.name);
    if let Err(e) = fs::rename(&part_path, &final_path) {
        let _ = fs::remove_dir(&directory);
        return Err(format!("Finalize uploaded file: {e}"));
    }
    let _ = fs::remove_file(dir.join("bitmap.bin"));
    let receipt = Receipt {
        name: meta.name.clone(),
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
    let directory = root.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir(&directory).map_err(|e| e.to_string())?;
    let path = directory.join(&upload.name);
    let result = (|| {
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
            name: upload.name,
            path: path.to_string_lossy().into_owned(),
            size: bytes.len(),
            sha256: hex::encode(Sha256::digest(&bytes)),
        })
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&directory);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn binary_uploads_are_exact_and_never_overwrite() {
        let root = tempfile::tempdir().unwrap();
        let make = || Upload {
            name: "image é.png".into(),
            data_base64: "AP8BAg==".into(),
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
                    data_base64: "YQ==".into()
                }
            )
            .is_err());
        }
        assert!(store(
            root.path(),
            Upload {
                name: "a".into(),
                data_base64: "!".into()
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
}
