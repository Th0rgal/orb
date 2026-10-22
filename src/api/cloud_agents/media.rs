//! Hermes `MEDIA:<path>` attachments become mission-scoped shared files.
//!
//! Hermes marks a file to deliver with a `MEDIA:<path>` directive (its chat
//! platforms upload it as a native attachment). The path names a file inside
//! Hermes's own mount namespace (the service runs with `PrivateTmp`), which no
//! client can reach. When a cloud_hermes turn completes, Core copies each
//! referenced file into a per-mission, content-addressed store and rewrites the
//! directive into the shared-file markup every client already renders
//! (`<image path=…/>` / `<file path=…/>` plus `metadata.shared_files`). A file
//! that cannot be copied becomes `<file … unavailable="true"/>`, which clients
//! show as a "file no longer available" chip.
//!
//! Security model (prompt-injected paths are expected):
//! - only a fixed set of Hermes output roots is accepted (`/tmp` and Hermes's
//!   media cache sub-directories, never `cache/` itself, which holds secrets);
//! - every component below the root is opened with `O_NOFOLLOW`, so symlinks,
//!   `..` and `.` cannot escape; FIFOs/devices and hard-linked files are refused;
//! - names that look like secrets are refused, sizes are capped per file, per
//!   message and per mission, and the stored type comes from the file's bytes
//!   (an extension that disagrees with its content is refused or corrected);
//! - active content (HTML, SVG) is stored as plain text.
use crate::api::control::SharedFile;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    io::Read,
    os::fd::{FromRawFd, OwnedFd},
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub const MAX_FILE_BYTES: u64 = 25 * 1024 * 1024;
pub const MAX_FILES_PER_MESSAGE: usize = 12;
pub const MAX_MISSION_BYTES: u64 = 512 * 1024 * 1024;
const MAX_PATH_LEN: usize = 1024;
pub const MAX_IMAGE_SIDE: u32 = 16_384;
pub const MAX_IMAGE_PIXELS: u64 = 48_000_000;

/// Sub-directories of `$HERMES_HOME` Hermes writes deliverable media into.
/// Mirrors `MEDIA_DELIVERY_SAFE_ROOTS` in hermes-agent `gateway/platforms/base.py`.
const HOME_MEDIA_DIRS: &[&str] = &[
    "cache/images",
    "cache/audio",
    "cache/videos",
    "cache/documents",
    "cache/screenshots",
    "cache/generated",
    "image_cache",
    "audio_cache",
    "video_cache",
    "document_cache",
    "browser_screenshots",
];

/// Where Hermes's files are read from.
#[derive(Debug, Clone)]
pub struct MediaSource {
    /// Root of Hermes's mount namespace as seen by Core (`/proc/<pid>/root`, or `/`).
    pub namespace_root: PathBuf,
    /// `$HERMES_HOME` inside that namespace.
    pub hermes_home: PathBuf,
    /// UID the Hermes service writes as. Every directory below the trusted
    /// base (except `/tmp` itself) and the file must be owned by it, so Core
    /// (root) never copies a file Hermes could not have produced.
    pub owner: u32,
}

impl MediaSource {
    /// `(trusted base, sub-directory)`: the base is operator-owned and may be a
    /// symlink (`HERMES_HOME` is on prod); the sub-directory is something the
    /// agent itself could replace, so it is walked without following links.
    fn allowed_roots(&self) -> Vec<(PathBuf, &'static str)> {
        let mut roots = vec![(PathBuf::from("/"), "tmp")];
        roots.extend(
            HOME_MEDIA_DIRS
                .iter()
                .map(|d| (self.hermes_home.clone(), *d)),
        );
        roots
    }
}

/// `<working_dir>/.sandboxed-sh/mission-media`: the root of every mission store.
pub fn media_root(working_dir: &Path) -> PathBuf {
    working_dir.join(".sandboxed-sh").join("mission-media")
}

pub fn mission_media_dir(working_dir: &Path, mission: Uuid) -> PathBuf {
    media_root(working_dir).join(mission.to_string())
}

/// A `MEDIA:` directive found in message text (byte offsets of the whole tag).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaTag {
    pub start: usize,
    pub end: usize,
    pub path: String,
}

const WRAP: &[u8] = b"*_\"'";

/// Byte ranges of inline code spans in one line (backtick runs of equal length).
fn code_spans(line: &str) -> Vec<(usize, usize)> {
    let b = line.as_bytes();
    let mut spans = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'`' {
            i += 1;
            continue;
        }
        let open = i;
        while i < b.len() && b[i] == b'`' {
            i += 1;
        }
        let run = i - open;
        let mut j = i;
        let mut closed = None;
        while j < b.len() {
            if b[j] == b'`' {
                let s = j;
                while j < b.len() && b[j] == b'`' {
                    j += 1;
                }
                if j - s == run {
                    closed = Some(j);
                    break;
                }
            } else {
                j += 1;
            }
        }
        match closed {
            Some(end) => {
                spans.push((open, end));
                i = end;
            }
            None => break,
        }
    }
    spans
}

/// Find `MEDIA:` directives outside fenced and inline code, the way Hermes
/// extracts them: optional emphasis/quote wrappers, then either a quoted path
/// or a bare absolute path ending at whitespace or the next `MEDIA:`.
pub fn find_media_tags(text: &str) -> Vec<MediaTag> {
    let mut tags = Vec::new();
    let mut offset = 0;
    let mut fence: Option<&str> = None;
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_start();
        let base = offset;
        offset += line.len();
        if let Some(marker) = fence {
            if trimmed.starts_with(marker) {
                fence = None;
            }
            continue;
        }
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            fence = Some(&trimmed[..3]);
            continue;
        }
        let spans = code_spans(line);
        let b = line.as_bytes();
        let mut search = 0;
        // End of the previous directive: a glued `MEDIA:/a.pngMEDIA:/b.png` is two.
        let mut previous_end = usize::MAX;
        while let Some(found) = line[search..].find("MEDIA:") {
            let at = search + found;
            search = at + 6;
            if spans.iter().any(|&(s, e)| at >= s && at < e) {
                continue;
            }
            // A directive is a word of its own (not `XMEDIA:`).
            if at > 0 && at != previous_end && b[at - 1].is_ascii_alphanumeric() {
                continue;
            }
            let mut start = at;
            while start > 0 && at - start < 3 && WRAP.contains(&b[start - 1]) {
                start -= 1;
            }
            let mut p = at + 6;
            while p < b.len() && (b[p] == b' ' || b[p] == b'\t') {
                p += 1;
            }
            let (path, mut end) = if p < b.len() && matches!(b[p], b'"' | b'\'' | b'`') {
                let q = b[p];
                match line[p + 1..].find(q as char) {
                    Some(close) => (line[p + 1..p + 1 + close].trim().to_string(), p + 2 + close),
                    None => continue,
                }
            } else if line[p..].starts_with('/') || line[p..].starts_with("~/") {
                let mut e = p;
                while e < b.len() && !b[e].is_ascii_whitespace() && !line[e..].starts_with("MEDIA:")
                {
                    e += line[e..].chars().next().map_or(1, char::len_utf8);
                }
                let mut raw = &line[p..e];
                while let Some(last) = raw.chars().last() {
                    if ",;:)]}.*_\"'`".contains(last) {
                        raw = &raw[..raw.len() - last.len_utf8()];
                    } else {
                        break;
                    }
                }
                (raw.to_string(), p + raw.len())
            } else {
                continue;
            };
            if path.is_empty() {
                continue;
            }
            let mut wrap = 0;
            while end < b.len() && wrap < 3 && WRAP.contains(&b[end]) {
                end += 1;
                wrap += 1;
            }
            search = search.max(end);
            previous_end = end;
            tags.push(MediaTag {
                start: base + start,
                end: base + end,
                path,
            });
        }
    }
    tags
}

/// The type Core stores a file as, decided from its bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Kind {
    ext: &'static str,
    mime: &'static str,
    image: bool,
}

const fn k(ext: &'static str, mime: &'static str, image: bool) -> Kind {
    Kind { ext, mime, image }
}

/// Text formats: accepted when the bytes are UTF-8 without NUL.
fn text_kind(ext: &str) -> Option<Kind> {
    Some(match ext {
        "txt" | "log" => k("txt", "text/plain; charset=utf-8", false),
        "md" | "markdown" => k("md", "text/markdown; charset=utf-8", false),
        "csv" => k("csv", "text/csv; charset=utf-8", false),
        "tsv" => k("tsv", "text/tab-separated-values; charset=utf-8", false),
        "json" => k("json", "application/json", false),
        "geojson" => k("geojson", "application/geo+json", false),
        "yaml" | "yml" => k("yaml", "application/yaml", false),
        "xml" | "kml" | "gpx" => k("xml", "application/xml", false),
        // Active content is never served as itself.
        "html" | "htm" | "svg" => k("txt", "text/plain; charset=utf-8", false),
        _ => return None,
    })
}

/// Sniff a binary format from its magic bytes.
fn sniff(bytes: &[u8]) -> Option<Kind> {
    let at = |o: usize, m: &[u8]| bytes.len() >= o + m.len() && &bytes[o..o + m.len()] == m;
    Some(if at(0, b"\x89PNG\r\n\x1a\n") {
        k("png", "image/png", true)
    } else if at(0, b"\xFF\xD8\xFF") {
        k("jpg", "image/jpeg", true)
    } else if at(0, b"GIF87a") || at(0, b"GIF89a") {
        k("gif", "image/gif", true)
    } else if at(0, b"RIFF") && at(8, b"WEBP") {
        k("webp", "image/webp", true)
    } else if at(0, b"RIFF") && at(8, b"WAVE") {
        k("wav", "audio/wav", false)
    } else if at(0, b"%PDF-") {
        k("pdf", "application/pdf", false)
    } else if at(0, b"PK\x03\x04") {
        k("zip", "application/zip", false)
    } else if at(0, b"\x1F\x8B") {
        k("gz", "application/gzip", false)
    } else if at(4, b"ftyp") {
        k("mp4", "video/mp4", false)
    } else if at(0, b"\x1A\x45\xDF\xA3") {
        k("webm", "video/webm", false)
    } else if at(0, b"OggS") {
        k("ogg", "audio/ogg", false)
    } else if at(0, b"fLaC") {
        k("flac", "audio/flac", false)
    } else if at(0, b"ID3") || (bytes.len() > 1 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) {
        k("mp3", "audio/mpeg", false)
    } else {
        return None;
    })
}

/// Pixel size from the image header (PNG, GIF, WebP, JPEG).
fn image_dimensions(b: &[u8]) -> Option<(u32, u32)> {
    let be32 = |o: usize| Some(u32::from_be_bytes(b.get(o..o + 4)?.try_into().ok()?));
    let le16 = |o: usize| Some(u16::from_le_bytes(b.get(o..o + 2)?.try_into().ok()?) as u32);
    let be16 = |o: usize| Some(u16::from_be_bytes(b.get(o..o + 2)?.try_into().ok()?) as u32);
    let le24 = |o: usize| {
        let s = b.get(o..o + 3)?;
        Some(s[0] as u32 | (s[1] as u32) << 8 | (s[2] as u32) << 16)
    };
    if b.starts_with(b"\x89PNG") {
        if b.get(12..16)? != b"IHDR" {
            return None;
        }
        return Some((be32(16)?, be32(20)?));
    }
    if b.starts_with(b"GIF8") {
        return Some((le16(6)?, le16(8)?));
    }
    if b.starts_with(b"RIFF") && b.get(8..12)? == b"WEBP" {
        return match b.get(12..16)? {
            b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
            b"VP8 " => Some((le16(26)? & 0x3FFF, le16(28)? & 0x3FFF)),
            b"VP8L" => {
                let v = u32::from_le_bytes(b.get(21..25)?.try_into().ok()?);
                Some(((v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1))
            }
            _ => None,
        };
    }
    if b.starts_with(b"\xFF\xD8") {
        // Walk JPEG segments to the first start-of-frame marker.
        let mut i = 2;
        while i + 9 < b.len() {
            if b[i] != 0xFF {
                return None;
            }
            let marker = b[i + 1];
            if marker == 0xFF {
                i += 1;
                continue;
            }
            let len = be16(i + 2)? as usize;
            if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
                return Some((be16(i + 7)?, be16(i + 5)?));
            }
            i += 2 + len;
        }
    }
    None
}

/// Binary extensions and the sniffed container they must match.
fn binary_family(ext: &str) -> Option<&'static [&'static str]> {
    Some(match ext {
        "png" | "jpg" | "jpeg" | "gif" | "webp" => &["png", "jpg", "gif", "webp"],
        "pdf" => &["pdf"],
        "zip" | "docx" | "xlsx" | "pptx" | "odt" | "ods" | "odp" | "epub" | "kmz" => &["zip"],
        "gz" | "tgz" => &["gz"],
        "mp4" | "mov" | "m4a" | "3gp" => &["mp4"],
        "webm" | "mkv" => &["webm"],
        "ogg" | "opus" => &["ogg"],
        "mp3" => &["mp3"],
        "wav" => &["wav"],
        "flac" => &["flac"],
        _ => return None,
    })
}

/// Decide the stored type. Office/zip formats keep their own extension so the
/// download names them correctly; the bytes still had to be a zip.
fn classify(name_ext: &str, bytes: &[u8]) -> Result<Kind, &'static str> {
    if let Some(family) = binary_family(name_ext) {
        let sniffed = sniff(bytes).ok_or("content does not match its type")?;
        if !family.contains(&sniffed.ext) {
            return Err("content does not match its type");
        }
        return Ok(match (sniffed.ext, name_ext) {
            ("zip", "docx") => k(
                "docx",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                false,
            ),
            ("zip", "xlsx") => k(
                "xlsx",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                false,
            ),
            ("zip", "pptx") => k(
                "pptx",
                "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                false,
            ),
            ("zip", "epub") => k("epub", "application/epub+zip", false),
            ("mp4", "mov") => k("mov", "video/quicktime", false),
            ("mp4", "m4a") => k("m4a", "audio/mp4", false),
            _ => sniffed,
        });
    }
    if let Some(kind) = text_kind(name_ext) {
        if bytes.contains(&0) || std::str::from_utf8(bytes).is_err() {
            return Err("content does not match its type");
        }
        return Ok(kind);
    }
    Err("unsupported file type")
}

/// Content type of a stored file, from the extension Core gave it.
pub fn stored_content_type(ext: &str) -> Option<&'static str> {
    Some(match ext {
        "png" => "image/png",
        "jpg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "zip" => "application/zip",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "epub" => "application/epub+zip",
        "gz" => "application/gzip",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "m4a" => "audio/mp4",
        "webm" => "video/webm",
        "ogg" => "audio/ogg",
        "flac" => "audio/flac",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "txt" => "text/plain; charset=utf-8",
        "md" => "text/markdown; charset=utf-8",
        "csv" => "text/csv; charset=utf-8",
        "tsv" => "text/tab-separated-values; charset=utf-8",
        "json" => "application/json",
        "geojson" => "application/geo+json",
        "yaml" => "application/yaml",
        "xml" => "application/xml",
        _ => return None,
    })
}

/// Names that hint at credentials are never copied, whatever their extension.
fn looks_secret(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n.starts_with('.')
        || [
            "secret",
            "token",
            "credential",
            "password",
            "passwd",
            "id_rsa",
            "id_ed25519",
            "private",
            "apikey",
            "api_key",
            "bws",
            "oauth",
            "cookie",
            "shadow",
        ]
        .iter()
        .any(|w| n.contains(w))
}

fn open_at(dir: Option<&OwnedFd>, path: &Path, flags: libc::c_int) -> std::io::Result<OwnedFd> {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let base = dir.map_or(libc::AT_FDCWD, |d| d.as_raw_fd());
    // SAFETY: valid C string; the returned descriptor is owned below.
    let fd = unsafe { libc::openat(base, c.as_ptr(), flags | libc::O_CLOEXEC | libc::O_NOCTTY) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `fd` is a fresh descriptor we own.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Why a directive could not be shared (kept for logs; never shown verbatim).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reject {
    Missing,
    NotAllowed(&'static str),
    TooLarge,
}

/// Read one Hermes file safely. Returns its bytes and the stored type.
fn read_media(source: &MediaSource, logical: &str) -> Result<(Vec<u8>, Kind), Reject> {
    if logical.len() > MAX_PATH_LEN || logical.contains('\0') || !logical.starts_with('/') {
        return Err(Reject::NotAllowed("path"));
    }
    let parts: Vec<&str> = logical[1..].split('/').collect();
    if parts
        .iter()
        .any(|p| p.is_empty() || *p == "." || *p == "..")
    {
        return Err(Reject::NotAllowed("path"));
    }
    let path = Path::new(logical);
    let (base, sub, rest) = source
        .allowed_roots()
        .into_iter()
        .find_map(|(base, sub)| {
            let rest = path.strip_prefix(base.join(sub)).ok()?;
            (rest.components().count() > 0).then(|| (base, sub, rest.to_path_buf()))
        })
        .ok_or(Reject::NotAllowed("outside Hermes output directories"))?;
    let name = rest
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or(Reject::NotAllowed("name"))?;
    if looks_secret(name)
        || rest
            .iter()
            .any(|c| c.to_str().is_none_or(|c| c.starts_with('.')))
    {
        return Err(Reject::NotAllowed("name"));
    }
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    if binary_family(&ext).is_none() && text_kind(&ext).is_none() {
        return Err(Reject::NotAllowed("unsupported file type"));
    }
    let in_ns = source
        .namespace_root
        .join(base.strip_prefix("/").unwrap_or(&base));
    let mut dir =
        open_at(None, &in_ns, libc::O_RDONLY | libc::O_DIRECTORY).map_err(|_| Reject::Missing)?;
    let mut comps: Vec<&std::ffi::OsStr> = Path::new(sub).iter().collect();
    comps.extend(rest.iter());
    use std::os::unix::fs::MetadataExt;
    let owned = |fd: &OwnedFd| -> Result<(), Reject> {
        let m = std::fs::File::from(fd.try_clone().map_err(|_| Reject::Missing)?)
            .metadata()
            .map_err(|_| Reject::Missing)?;
        if m.uid() != source.owner {
            return Err(Reject::NotAllowed("not written by Hermes"));
        }
        Ok(())
    };
    for (i, c) in comps[..comps.len() - 1].iter().enumerate() {
        dir = open_at(
            Some(&dir),
            Path::new(c),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
        .map_err(|_| Reject::NotAllowed("path"))?;
        // `/tmp` itself is root-owned and shared; everything below must be Hermes's.
        if !(i == 0 && sub == "tmp") {
            owned(&dir)?;
        }
    }
    let fd = open_at(
        Some(&dir),
        Path::new(comps[comps.len() - 1]),
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
    )
    .map_err(|e| {
        // ELOOP: the final component is a symlink.
        if e.raw_os_error() == Some(libc::ELOOP) {
            Reject::NotAllowed("symlink")
        } else {
            Reject::Missing
        }
    })?;
    let file = std::fs::File::from(fd);
    let meta = file.metadata().map_err(|_| Reject::Missing)?;
    if !meta.file_type().is_file() {
        return Err(Reject::NotAllowed("not a regular file"));
    }
    if meta.uid() != source.owner {
        return Err(Reject::NotAllowed("not written by Hermes"));
    }
    {
        // A hard link can alias any file on the same filesystem.
        if meta.nlink() != 1 {
            return Err(Reject::NotAllowed("hard link"));
        }
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(Reject::TooLarge);
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    file.take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Reject::Missing)?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(Reject::TooLarge);
    }
    if bytes.is_empty() {
        return Err(Reject::Missing);
    }
    let kind = classify(&ext, &bytes).map_err(Reject::NotAllowed)?;
    if kind.image {
        // A small file can still decode to gigabytes (decompression bomb).
        let (w, h) = image_dimensions(&bytes).ok_or(Reject::NotAllowed("unreadable image"))?;
        if w == 0
            || h == 0
            || w > MAX_IMAGE_SIDE
            || h > MAX_IMAGE_SIDE
            || w as u64 * h as u64 > MAX_IMAGE_PIXELS
        {
            return Err(Reject::TooLarge);
        }
    }
    Ok((bytes, kind))
}

fn dir_size(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.metadata().ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

/// Store bytes content-addressed; returns the stored path.
fn store(dir: &Path, bytes: &[u8], kind: Kind) -> Result<PathBuf, Reject> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let hash = hex::encode(Sha256::digest(bytes));
    let path = dir.join(format!("{hash}.{}", kind.ext));
    if path.is_file() {
        return Ok(path);
    }
    if dir_size(dir) + bytes.len() as u64 > MAX_MISSION_BYTES {
        return Err(Reject::TooLarge);
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|_| Reject::Missing)?;
    let tmp = dir.join(format!(".{hash}.{}.part", Uuid::new_v4().simple()));
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        std::io::Write::write_all(&mut f, bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, &path)
    };
    write().map_err(|_| {
        let _ = std::fs::remove_file(&tmp);
        Reject::Missing
    })?;
    Ok(path)
}

/// Attribute-safe text for generated tags.
fn attr(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_control())
        .map(|c| match c {
            '"' | '<' | '>' => '\'',
            c => c,
        })
        .collect()
}

#[derive(Debug, Default)]
pub struct Normalized {
    pub text: String,
    pub shared_files: Vec<SharedFile>,
}

/// Rewrite every `MEDIA:` directive in `text`. Blocking (filesystem work).
pub fn normalize_text(
    text: &str,
    source: Option<&MediaSource>,
    working_dir: &Path,
    mission: Uuid,
) -> Normalized {
    let tags = find_media_tags(text);
    if tags.is_empty() {
        return Normalized {
            text: text.to_string(),
            shared_files: vec![],
        };
    }
    let dir = mission_media_dir(working_dir, mission);
    let mut out = String::with_capacity(text.len());
    let mut files: Vec<SharedFile> = Vec::new();
    let mut last = 0;
    for (index, tag) in tags.iter().enumerate() {
        out.push_str(&text[last..tag.start]);
        last = tag.end;
        let name = tag
            .path
            .rsplit('/')
            .next()
            .filter(|n| !n.is_empty())
            .unwrap_or("file");
        let result = if index >= MAX_FILES_PER_MESSAGE {
            Err(Reject::TooLarge)
        } else {
            source
                .ok_or(Reject::Missing)
                .and_then(|s| read_media(s, &tag.path))
                .and_then(|(bytes, kind)| Ok((store(&dir, &bytes, kind)?, kind, bytes.len())))
        };
        match result {
            Ok((stored, kind, size)) => {
                let shown = stored.to_string_lossy();
                if kind.image {
                    out.push_str(&format!(
                        "<image path=\"{}\" alt=\"{}\" />",
                        attr(&shown),
                        attr(name)
                    ));
                } else {
                    out.push_str(&format!(
                        "<file path=\"{}\" name=\"{}\" />",
                        attr(&shown),
                        attr(name)
                    ));
                }
                let url = format!(
                    "/api/fs/download?path={}&mission_id={mission}",
                    urlencoding::encode(&shown)
                );
                if !files.iter().any(|f| f.url == url) {
                    files.push(SharedFile::new(name, url, kind.mime, Some(size as u64)));
                }
            }
            Err(reason) => {
                tracing::info!(%mission, ?reason, "Hermes media attachment not shared");
                out.push_str(&format!(
                    "<file path=\"{}\" name=\"{}\" unavailable=\"true\" />",
                    attr(&tag.path),
                    attr(name)
                ));
            }
        }
    }
    out.push_str(&text[last..]);
    Normalized {
        text: out,
        shared_files: files,
    }
}

/// Locate Hermes's mount namespace. Hermes runs with `PrivateTmp`, so its `/tmp`
/// is only reachable through its main process. The PID is checked to still
/// belong to the unit so a recycled PID never redirects the read.
pub fn hermes_source(runtime: &str) -> Option<MediaSource> {
    let hermes_home = PathBuf::from(format!("/var/lib/{runtime}"));
    let unit = format!("{runtime}.service");
    let out = std::process::Command::new("systemctl")
        .args(["show", "-p", "MainPID", "-p", "PrivateTmp", &unit])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let field = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('=')))
            .unwrap_or("")
            .trim()
            .to_string()
    };
    // Fail closed: without Hermes's own namespace, Core's (root) /tmp would be read.
    if field("PrivateTmp") != "yes" {
        return None;
    }
    let pid: u32 = field("MainPID").parse().ok().filter(|p| *p > 0)?;
    let cgroup = std::fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
    if !cgroup.lines().any(|l| l.ends_with(&format!("/{unit}"))) {
        return None;
    }
    let owner = {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(&hermes_home).ok()?.uid()
    };
    Some(MediaSource {
        namespace_root: PathBuf::from(format!("/proc/{pid}/root")),
        hermes_home,
        owner,
    })
}

/// Normalize a completed Hermes turn in place. Idempotent: rewritten text has
/// no directives left.
pub async fn normalize_turn(config: &crate::config::Config, mission: Uuid, turn: &mut super::Turn) {
    let Some(result) = turn.result.clone().filter(|r| r.contains("MEDIA:")) else {
        return;
    };
    let runtime = crate::api::system::assistant_runtime_name(config);
    let working_dir = config.working_dir.clone();
    let done = tokio::task::spawn_blocking(move || {
        let source = hermes_source(runtime);
        normalize_text(&result, source.as_ref(), &working_dir, mission)
    })
    .await;
    if let Ok(n) = done {
        turn.result = Some(n.text);
        turn.shared_files.extend(
            n.shared_files
                .into_iter()
                .filter_map(|f| serde_json::to_value(f).ok()),
        );
    }
}

/// A stored media file named by a download path: `<root>/<mission>/<sha256>.<ext>`.
/// Returns `None` when the path is not in the media store at all.
pub fn parse_store_path(
    working_dir: &Path,
    raw: &str,
) -> Option<Result<(Uuid, PathBuf, &'static str), ()>> {
    let root = media_root(working_dir);
    let canonical_root = root.canonicalize().ok();
    let p = Path::new(raw);
    let rest = p
        .strip_prefix(&root)
        .ok()
        .or_else(|| canonical_root.as_ref().and_then(|r| p.strip_prefix(r).ok()))?;
    let parts: Vec<_> = rest.iter().filter_map(|c| c.to_str()).collect();
    let parsed = (|| {
        let [mission, file] = parts.as_slice() else {
            return Err(());
        };
        let mission: Uuid = mission.parse().map_err(|_| ())?;
        let (hash, ext) = file.split_once('.').ok_or(())?;
        if hash.len() != 64
            || !hash
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(());
        }
        let mime = stored_content_type(ext).ok_or(())?;
        Ok((mission, root.join(mission.to_string()).join(file), mime))
    })();
    Some(parsed)
}

/// Shared-file JSON published with an assistant message.
pub fn metadata(files: &[Value]) -> Option<String> {
    (!files.is_empty()).then(|| serde_json::json!({ "shared_files": files }).to_string())
}

#[cfg(test)]
#[path = "media_tests.rs"]
mod tests;
