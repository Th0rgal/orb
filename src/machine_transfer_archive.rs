//! Server-side bulk copy for machine transfers: one tar+zstd stream of a
//! source checkpoint's files, unpacked into a staged destination checkpoint.
//!
//! This replaces relaying base64 1 MiB blocks through the Orb client for
//! Core/node -> node moves. It only carries bytes: the destination's
//! `Operation::Verify` (per-file sha256 against the transfer manifest) stays
//! the authority, and the per-file `Read`/`Write` path stays as the fallback.
use crate::machine_transfer::{confined, load, lock_area, Entry};
use bytes::Bytes;
use futures::{Stream, StreamExt};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

/// Advertised in transfer `features` by Core and nodes that serve the
/// archive routes.
pub const FEATURE: &str = "bulk_copy";
const ZSTD_LEVEL: i32 = 3;
const CHUNK: usize = 256 * 1024;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Writes every file of the checkpoint at `area` (its own saved manifest)
/// into `out` as a zstd-compressed tar. Returns the uncompressed file bytes.
pub fn pack(area: &Path, out: impl Write) -> Result<u64, String> {
    let _lock = lock_area(area)?;
    let manifest = load(area)?;
    let root = area.join("workspace");
    let mut tar =
        tar::Builder::new(zstd::stream::write::Encoder::new(out, ZSTD_LEVEL).map_err(err)?);
    let mut total = 0u64;
    for f in &manifest.files {
        let path = confined(&root, &f.path)?;
        let file = File::open(&path).map_err(err)?;
        if file.metadata().map_err(err)?.len() != f.bytes {
            return Err(format!("Checkpoint file changed: {}", f.path));
        }
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(tar::EntryType::Regular);
        header.set_size(f.bytes);
        header.set_mode(if f.executable { 0o700 } else { 0o600 });
        header.set_mtime(0);
        tar.append_data(&mut header, &f.path, file.take(f.bytes))
            .map_err(err)?;
        total += f.bytes;
    }
    tar.into_inner()
        .map_err(err)?
        .finish()
        .map_err(err)?
        .flush()
        .map_err(err)?;
    Ok(total)
}

/// Unpacks an archive from [`pack`] into the staged (not yet verified)
/// checkpoint at `area`. Every entry must be a regular file named by the
/// staged manifest with exactly its size; anything else aborts. `progress`
/// receives the running total of file bytes written.
pub fn unpack(area: &Path, input: impl Read, mut progress: impl FnMut(u64)) -> Result<u64, String> {
    let _lock = lock_area(area)?;
    if area.join("verified").exists() {
        return Err("Checkpoint already sealed".into());
    }
    let manifest = load(area)?;
    let wanted: HashMap<&str, &Entry> = manifest
        .files
        .iter()
        .map(|f| (f.path.as_str(), f))
        .collect();
    let root = area.join("workspace");
    let mut archive = tar::Archive::new(zstd::stream::read::Decoder::new(input).map_err(err)?);
    let mut written = 0u64;
    for entry in archive.entries().map_err(err)? {
        let mut entry = entry.map_err(err)?;
        if entry.header().entry_type() != tar::EntryType::Regular {
            return Err("Archive contains a non-regular entry".into());
        }
        let name = entry
            .path()
            .map_err(err)?
            .to_str()
            .ok_or("Invalid archive path")?
            .to_owned();
        let f = wanted
            .get(name.as_str())
            .ok_or_else(|| format!("Archive entry absent from manifest: {name}"))?;
        if entry.size() != f.bytes {
            return Err(format!("Archive entry has the wrong size: {name}"));
        }
        let to = confined(&root, &name)?;
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent).map_err(err)?;
        }
        let mut out = File::create(&to).map_err(err)?;
        let copied = io::copy(&mut (&mut entry).take(f.bytes), &mut out).map_err(err)?;
        if copied != f.bytes {
            return Err(format!("Archive entry truncated: {name}"));
        }
        out.sync_data().map_err(err)?;
        written += copied;
        progress(written);
    }
    Ok(written)
}

/// `Write` half of a bounded channel, for a blocking producer feeding an
/// async consumer.
struct ChannelWriter {
    tx: tokio::sync::mpsc::Sender<Result<Bytes, io::Error>>,
    buf: Vec<u8>,
}
impl Write for ChannelWriter {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.buf.extend_from_slice(data);
        if self.buf.len() >= CHUNK {
            self.flush()?;
        }
        Ok(data.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        if self.buf.is_empty() {
            return Ok(());
        }
        let chunk = Bytes::from(std::mem::take(&mut self.buf));
        self.tx
            .blocking_send(Ok(chunk))
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "archive consumer closed"))
    }
}

/// `Read` half of a bounded channel, for an async producer feeding a
/// blocking consumer.
struct ChannelReader {
    rx: tokio::sync::mpsc::Receiver<Result<Bytes, io::Error>>,
    current: Bytes,
}
impl Read for ChannelReader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        while self.current.is_empty() {
            match self.rx.blocking_recv() {
                Some(Ok(chunk)) => self.current = chunk,
                Some(Err(e)) => return Err(e),
                None => return Ok(0),
            }
        }
        let n = out.len().min(self.current.len());
        out[..n].copy_from_slice(&self.current.split_to(n));
        Ok(n)
    }
}

/// Streams [`pack`] of `area`. A packing failure ends the stream with an
/// error, so a receiver never mistakes a truncated archive for a whole one.
pub fn pack_stream(area: PathBuf) -> impl Stream<Item = Result<Bytes, io::Error>> + Send {
    let (tx, rx) = tokio::sync::mpsc::channel(8);
    tokio::task::spawn_blocking(move || {
        let mut writer = ChannelWriter {
            tx: tx.clone(),
            buf: Vec::new(),
        };
        let result = pack(&area, &mut writer).and_then(|_| writer.flush().map_err(err));
        if let Err(e) = result {
            let _ = tx.blocking_send(Err(io::Error::other(e)));
        }
    });
    futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|item| (item, rx))
    })
}

/// Unpacks a streamed archive into the staged checkpoint at `area`,
/// counting written file bytes into `progress`.
pub async fn unpack_stream<S, E>(
    area: PathBuf,
    input: S,
    progress: Arc<AtomicU64>,
) -> Result<u64, String>
where
    S: Stream<Item = Result<Bytes, E>> + Send + 'static,
    E: std::fmt::Display + Send + 'static,
{
    let (tx, rx) = tokio::sync::mpsc::channel(8);
    let forward = tokio::spawn(async move {
        let mut input = std::pin::pin!(input);
        while let Some(item) = input.next().await {
            let item = item.map_err(|e| io::Error::other(e.to_string()));
            let failed = item.is_err();
            if tx.send(item).await.is_err() || failed {
                break;
            }
        }
    });
    let result = tokio::task::spawn_blocking(move || {
        let reader = ChannelReader {
            rx,
            current: Bytes::new(),
        };
        unpack(&area, reader, |n| progress.store(n, Ordering::Relaxed))
    })
    .await
    .map_err(err)?;
    forward.abort();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machine_transfer::{operate, Operation};

    fn snapshot(source_dir: &Path, area: &Path) -> crate::machine_transfer::Manifest {
        let value = operate(area, Some(source_dir), Operation::Snapshot).unwrap();
        serde_json::from_value(value).unwrap()
    }

    fn workspace(dir: &Path) {
        fs::create_dir_all(dir.join("src/deep")).unwrap();
        fs::write(dir.join("README.md"), "hello").unwrap();
        fs::write(dir.join("empty.txt"), "").unwrap();
        let big: Vec<u8> = (0..(3 * 1024 * 1024 + 17))
            .map(|i| (i % 251) as u8)
            .collect();
        fs::write(dir.join("src/deep/blob.bin"), big).unwrap();
    }

    #[tokio::test]
    async fn archive_round_trip_then_verify() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src-ws");
        workspace(&src);
        let source_area = tmp.path().join("source");
        let dest_area = tmp.path().join("destination");
        let manifest = snapshot(&src, &source_area);
        operate(
            &dest_area,
            None,
            Operation::Stage {
                manifest: manifest.clone(),
            },
        )
        .unwrap();

        let progress = Arc::new(AtomicU64::new(0));
        let written = unpack_stream(
            dest_area.clone(),
            pack_stream(source_area.clone()),
            progress.clone(),
        )
        .await
        .unwrap();
        assert_eq!(written, manifest.bytes);
        assert_eq!(progress.load(Ordering::Relaxed), manifest.bytes);

        // Verify still runs and is authoritative.
        let receipt = operate(&dest_area, None, Operation::Verify).unwrap();
        assert_eq!(receipt["files"].as_u64(), Some(manifest.files.len() as u64));
        assert_eq!(
            fs::read(dest_area.join("workspace/src/deep/blob.bin")).unwrap(),
            fs::read(src.join("src/deep/blob.bin")).unwrap()
        );
        // A sealed checkpoint refuses another archive.
        assert!(unpack(&dest_area, io::empty(), |_| {}).is_err());
    }

    #[tokio::test]
    async fn verify_rejects_tampered_archive_bytes() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src-ws");
        workspace(&src);
        let source_area = tmp.path().join("source");
        let dest_area = tmp.path().join("destination");
        let manifest = snapshot(&src, &source_area);
        operate(&dest_area, None, Operation::Stage { manifest }).unwrap();
        // Same size, different content: the archive accepts it, verify must not.
        fs::write(source_area.join("workspace/README.md"), "HELLO").unwrap();
        let mut archive = Vec::new();
        pack(&source_area, &mut archive).unwrap();
        unpack(&dest_area, archive.as_slice(), |_| {}).unwrap();
        assert!(operate(&dest_area, None, Operation::Verify).is_err());
    }

    #[test]
    fn unpack_refuses_entries_outside_the_manifest() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src-ws");
        workspace(&src);
        let source_area = tmp.path().join("source");
        let dest_area = tmp.path().join("destination");
        let mut manifest = snapshot(&src, &source_area);
        manifest.bytes -= 5;
        manifest.files.retain(|f| f.path != "README.md");
        operate(&dest_area, None, Operation::Stage { manifest }).unwrap();
        let mut archive = Vec::new();
        pack(&source_area, &mut archive).unwrap();
        let e = unpack(&dest_area, archive.as_slice(), |_| {}).unwrap_err();
        assert!(e.contains("absent from manifest"), "{e}");
    }

    #[tokio::test]
    async fn failed_pack_ends_stream_with_error() {
        let tmp = tempfile::tempdir().unwrap();
        // No manifest at this area: packing fails and the stream must say so.
        let items: Vec<_> = pack_stream(tmp.path().join("missing")).collect().await;
        assert!(items.last().unwrap().is_err());
    }
}
