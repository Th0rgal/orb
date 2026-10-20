//! Mission export/import (bundles and chunked uploads).

use super::*;

/// Export a mission as a portable bundle for transfer to another instance.
///
/// Response: JSON by default, or gzipped JSON when the caller sends
/// `Accept-Encoding: gzip` (or explicitly forces it with `?gzip=true`).
/// Gzipping typically shrinks bundles 5–10× — a 220 MB text-heavy bundle
/// lands around 30 MB, comfortably under Cloudflare's 100 MB free-tier
/// request cap. Clients that can't decompress pass `?gzip=false` to
/// disable.
#[derive(Debug, Deserialize, Default)]
pub struct ExportMissionQuery {
    /// Force gzip encoding regardless of Accept-Encoding. `None` defers to
    /// the header; `Some(false)` disables even if Accept-Encoding asked.
    #[serde(default)]
    pub gzip: Option<bool>,
}

pub async fn export_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(mission_id): Path<Uuid>,
    axum::extract::Query(query): axum::extract::Query<ExportMissionQuery>,
    headers_in: axum::http::HeaderMap,
) -> Result<axum::response::Response, (StatusCode, String)> {
    use axum::http::header;
    use axum::response::IntoResponse;
    use flate2::write::GzEncoder;
    use flate2::Compression;

    let control = control_for_user(&state, &user).await;
    let source_public_url = std::env::var("SANDBOXED_PUBLIC_URL").ok();
    let mut bundle = control
        .mission_store
        .export_mission_bundle(mission_id, source_public_url)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, e))?;
    // Ensure `workspace_name` is populated so the import side can resolve
    // it against its own workspace store without requiring the caller to
    // pass `?workspace_id=`. The stored `missions.workspace_name` column
    // can be NULL (it's only populated opportunistically at display time).
    if bundle.workspace_name.is_none() {
        if let Some(ws) = state.workspaces.get(bundle.mission.workspace_id).await {
            bundle.workspace_name = Some(ws.name.clone());
            bundle.mission.workspace_name = Some(ws.name);
        }
    }
    let mission_id_simple = bundle.mission.id.simple().to_string();

    // Gzip opt-in:
    //   1. `?gzip=true` always compresses
    //   2. `?gzip=false` always skips
    //   3. Otherwise honor Accept-Encoding: gzip, including q-values
    //      (`gzip;q=0` explicitly disallows gzip even when present).
    let accepts_gzip = headers_in
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .map(accept_encoding_allows_gzip)
        .unwrap_or(false);
    let use_gzip = query.gzip.unwrap_or(accepts_gzip);

    // Stream the bundle out instead of materializing a full JSON string
    // (and a full gzip buffer on top of that). For large missions the
    // old approach held bundle + JSON + optional gzip — three in-memory
    // copies at once — which could OOM the daemon on export. Here the
    // serializer writes into a bounded mpsc channel in ~64 KB chunks;
    // flate2 compresses on the fly when use_gzip is set.
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<bytes::Bytes, std::io::Error>>(8);
    tokio::task::spawn_blocking(move || {
        let mut writer = ChannelWriter::new(tx);
        let serialize_result: std::io::Result<()> = if use_gzip {
            let mut encoder = GzEncoder::new(&mut writer, Compression::default());
            serde_json::to_writer(&mut encoder, &bundle)
                .map_err(std::io::Error::other)
                .and_then(|_| encoder.finish().map(|_| ()))
        } else {
            serde_json::to_writer(&mut writer, &bundle).map_err(std::io::Error::other)
        };
        if let Err(e) = serialize_result.and_then(|_| writer.flush_all()) {
            writer.send_error(e);
        }
    });
    // Adapt the mpsc receiver into a `Stream` via futures::stream::unfold —
    // tokio-stream isn't in the dep set, and this is a ~5-line adapter.
    let stream = futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|item| (item, rx))
    });
    let body = axum::body::Body::from_stream(stream);

    let filename = if use_gzip {
        format!("mission-{mission_id_simple}.json.gz")
    } else {
        format!("mission-{mission_id_simple}.json")
    };

    let mut resp = (StatusCode::OK, body).into_response();
    let out_headers = resp.headers_mut();
    out_headers.insert(
        header::CONTENT_TYPE,
        "application/json; charset=utf-8".parse().unwrap(),
    );
    if use_gzip {
        out_headers.insert(header::CONTENT_ENCODING, "gzip".parse().unwrap());
        // Mark the response as varying on Accept-Encoding so caches
        // don't serve a gzipped body to a client that didn't ask.
        out_headers.insert(header::VARY, "Accept-Encoding".parse().unwrap());
    }
    out_headers.insert(
        header::CONTENT_DISPOSITION,
        format!("attachment; filename=\"{filename}\"")
            .parse()
            .map_err(internal_error)?,
    );
    Ok(resp)
}

/// Import a mission bundle previously produced by [`export_mission`].
///
/// Body is the raw JSON bundle (no multipart wrapper — keep the happy path
/// simple for curl / scripts). Optional query params:
/// - `workspace_id=<uuid>` — override target workspace; otherwise we resolve
///   the bundle's `workspace_name` against the local workspace store.
/// - `keep_automations_active=true` — import automations enabled. Default is
///   disabled so bundles don't immediately start firing on the target.
#[derive(Debug, Deserialize, Default)]
pub struct ImportMissionQuery {
    pub workspace_id: Option<Uuid>,
    #[serde(default)]
    pub keep_automations_active: bool,
}

pub async fn import_mission(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    axum::extract::Query(query): axum::extract::Query<ImportMissionQuery>,
    headers_in: axum::http::HeaderMap,
    body: axum::body::Bytes,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let bundle = parse_mission_bundle(&headers_in, &body)?;
    if bundle.version != 1 {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("Unsupported bundle version {} (expected 1)", bundle.version),
        ));
    }

    let target = resolve_import_target_workspace(
        &state,
        query.workspace_id,
        bundle.workspace_name.as_deref(),
    )
    .await?;

    let options = mission_store::MissionImportOptions {
        target_workspace_id: Some(target.workspace_id),
        target_workspace_name: target.workspace_name.clone(),
        keep_automations_active: query.keep_automations_active,
    };
    let original_mission_id = bundle.mission.id;
    let events_imported = bundle.events.len();
    let automations_imported = bundle.automations.len();
    let executions_imported = bundle.executions.len();
    let new_id = control
        .mission_store
        .import_mission_bundle(bundle, options)
        .await
        .map_err(internal_error)?;

    Ok(Json(serde_json::json!({
        "mission_id": new_id,
        "workspace_id": target.workspace_id,
        "original_mission_id": original_mission_id,
        "imported": {
            "events": events_imported,
            "automations": automations_imported,
            "executions": executions_imported,
        },
        "automations_active": query.keep_automations_active,
    })))
}

/// Resolve the workspace a mission import should land in.
///
/// Explicit `?workspace_id=` wins. Otherwise the bundle's
/// `workspace_name` is matched against the local workspace list. A
/// single match is used; zero matches or multiple matches return
/// `BAD_REQUEST`/`CONFLICT` asking the caller to disambiguate — we
/// never silently pick "the first" when workspace names aren't unique.
/// Resolved import target: the workspace UUID the new mission will be
/// attached to, plus its current display name (used so
/// `mission.workspace_name` agrees with `mission.workspace_id`).
pub(super) struct ResolvedImportTarget {
    pub(super) workspace_id: Uuid,
    pub(super) workspace_name: Option<String>,
}

pub(super) async fn resolve_import_target_workspace(
    state: &Arc<AppState>,
    explicit_id: Option<Uuid>,
    bundle_workspace_name: Option<&str>,
) -> Result<ResolvedImportTarget, (StatusCode, String)> {
    if let Some(id) = explicit_id {
        // Reject unknown IDs up front — the alternative is persisting a
        // mission pointing at a nonexistent workspace, which later falls
        // through to the default host workspace in resolve_workspace and
        // silently executes in the wrong directory.
        let workspaces = state.workspaces.list().await;
        let Some(ws) = workspaces.iter().find(|w| w.id == id) else {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "Workspace '{id}' not found on this instance. Pass a \
                     valid ?workspace_id=<uuid> or omit it to resolve \
                     by workspace_name."
                ),
            ));
        };
        return Ok(ResolvedImportTarget {
            workspace_id: id,
            workspace_name: Some(ws.name.clone()),
        });
    }
    let Some(name) = bundle_workspace_name else {
        return Err((
            StatusCode::BAD_REQUEST,
            "Bundle has no workspace_name and no ?workspace_id= override was provided.".to_string(),
        ));
    };
    let workspaces = state.workspaces.list().await;
    let matches: Vec<_> = workspaces.iter().filter(|w| w.name == name).collect();
    match matches.as_slice() {
        [] => Err((
            StatusCode::BAD_REQUEST,
            format!(
                "Workspace '{name}' not found on this instance. Pass \
                 ?workspace_id=<uuid> to pick one explicitly."
            ),
        )),
        [only] => Ok(ResolvedImportTarget {
            workspace_id: only.id,
            workspace_name: Some(only.name.clone()),
        }),
        _ => Err((
            StatusCode::CONFLICT,
            format!(
                "Workspace name '{name}' is ambiguous ({} matches). \
                 Pass ?workspace_id=<uuid> to pick one explicitly.",
                matches.len()
            ),
        )),
    }
}

/// Parse a mission bundle from raw bytes, transparently decompressing
/// `Content-Encoding: gzip` before JSON-decoding. Both the single-shot
/// `/import` route and the chunked `/import-chunks/:id/commit` route
/// share this helper — they both arrive as a `Bytes` blob that may or
/// may not be gzipped.
/// Hard cap on decompressed mission bundle size for the *chunked*
/// import path, where the decoder streams from disk-staged chunks into
/// `serde_json::from_reader` without ever buffering the full payload.
/// 2 GiB bounds a zip-bomb there.
pub(super) const MISSION_BUNDLE_MAX_DECOMPRESSED_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Tighter cap for the *single-shot* `/import` route. That path streams
/// the decompressed body into `from_reader`, but the parser still
/// allocates per-frame state up to this ceiling — and an attacker can
/// drive it from a 128 MiB compressed body. Keep the ceiling small
/// enough that even the worst-case allocation stays bounded; larger
/// bundles must use the chunked route, which stages chunks on disk
/// first.
pub(super) const MISSION_BUNDLE_SINGLE_SHOT_MAX_DECOMPRESSED_BYTES: u64 = 512 * 1024 * 1024;

/// Stream a mission bundle out of a staged chunk directory without ever
/// holding the concatenated body in memory. Handles gzip transparently —
/// either because the caller set `?gzip=true` or because the first chunk
/// starts with the gzip magic header.
pub(super) fn parse_mission_bundle_from_chunk_dir(
    dir: &std::path::Path,
    total_chunks: u32,
    gzip_hint: bool,
) -> Result<mission_store::MissionBundle, (StatusCode, String)> {
    use std::fs::File;
    use std::io::{BufReader, Read};

    if total_chunks == 0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "total_chunks must be > 0".to_string(),
        ));
    }

    // Peek at the first chunk to auto-detect gzip when the caller
    // forgot to pass the hint. A plain `[0x1f, 0x8b]` prefix is
    // unambiguous for gzip and lets us decompress without buffering
    // the whole upload first.
    let first_path = dir.join(format!("chunk_{:06}", 0));
    let mut first = File::open(&first_path).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            format!("Chunk 0 missing or unreadable: {e}"),
        )
    })?;
    let mut magic = [0u8; 2];
    let peeked = first.read(&mut magic).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            format!("Failed to read chunk 0: {e}"),
        )
    })?;
    let is_gzipped = gzip_hint || (peeked == 2 && magic == [0x1f, 0x8b]);
    // Seek back to start so the reader chain sees the full first chunk.
    use std::io::Seek;
    first
        .seek(std::io::SeekFrom::Start(0))
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("seek: {e}")))?;

    // Build a chained reader across every chunk file in index order.
    // `Read::chain` is associative, so we fold left across the remaining
    // chunk indices without allocating intermediate buffers.
    let mut reader: Box<dyn Read> = Box::new(BufReader::new(first));
    for i in 1..total_chunks {
        let path = dir.join(format!("chunk_{i:06}"));
        let f = File::open(&path).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                format!("Chunk {i} missing or unreadable: {e}"),
            )
        })?;
        reader = Box::new(reader.chain(BufReader::new(f)));
    }

    let bundle: mission_store::MissionBundle = if is_gzipped {
        let decoder = flate2::read::GzDecoder::new(reader);
        let bounded = decoder.take(MISSION_BUNDLE_MAX_DECOMPRESSED_BYTES);
        serde_json::from_reader(BufReader::new(bounded)).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                format!("Invalid mission bundle (after gunzip): {e}"),
            )
        })?
    } else {
        // Cap the plain-JSON path at the same ceiling as the gzip
        // branch. `/import-chunks` accepts many 128 MB chunks, so
        // without a cap an attacker could chain them into an
        // arbitrarily large payload and drive unbounded allocation
        // inside serde_json::from_reader.
        let bounded = reader.take(MISSION_BUNDLE_MAX_DECOMPRESSED_BYTES);
        serde_json::from_reader(BufReader::new(bounded)).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                format!("Invalid mission bundle: {e}"),
            )
        })?
    };

    Ok(bundle)
}

/// `std::io::Write` adapter that pushes ~64 KB chunks into an mpsc
/// channel consumed by the HTTP response body. Lets `export_mission`
/// serialize (and optionally gzip) the bundle straight to the wire
/// without ever holding the full payload in RAM.
pub(super) struct ChannelWriter {
    pub(super) tx: tokio::sync::mpsc::Sender<Result<bytes::Bytes, std::io::Error>>,
    pub(super) buf: Vec<u8>,
}

impl ChannelWriter {
    /// Flush threshold — large enough to amortize channel overhead,
    /// small enough that stream backpressure is responsive.
    pub(super) const CHUNK_BYTES: usize = 64 * 1024;

    pub(super) fn new(tx: tokio::sync::mpsc::Sender<Result<bytes::Bytes, std::io::Error>>) -> Self {
        Self {
            tx,
            buf: Vec::with_capacity(Self::CHUNK_BYTES * 2),
        }
    }

    /// Drain whatever is in `buf`.
    pub(super) fn flush_all(&mut self) -> std::io::Result<()> {
        if !self.buf.is_empty() {
            let chunk = std::mem::take(&mut self.buf);
            self.tx
                .blocking_send(Ok(bytes::Bytes::from(chunk)))
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::BrokenPipe, e.to_string()))?;
        }
        Ok(())
    }

    /// Surface a late error (serialization or flush) to the consumer
    /// by pushing it as a stream item. Best-effort: if the receiver is
    /// already gone we swallow it.
    pub(super) fn send_error(&self, err: std::io::Error) {
        let _ = self.tx.blocking_send(Err(err));
    }
}

impl std::io::Write for ChannelWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        if self.buf.len() >= Self::CHUNK_BYTES {
            self.flush_all()?;
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.flush_all()
    }
}

/// Parse an `Accept-Encoding` header and decide whether the client
/// allows gzip. Treats `identity;q=0` / `*;q=0` semantics correctly —
/// a token of the form `gzip;q=0` explicitly disallows gzip, so simply
/// matching on `starts_with("gzip")` (the previous behavior) returns
/// the wrong answer for proxies that send weighted encodings.
pub(super) fn accept_encoding_allows_gzip(header_value: &str) -> bool {
    let mut gzip_seen = false;
    let mut gzip_qzero = false;
    let mut star_qzero = false;
    for raw in header_value.split(',') {
        let token = raw.trim();
        if token.is_empty() {
            continue;
        }
        // Split into `name` and optional `q=<float>` parameter.
        let mut parts = token.split(';');
        let name = parts.next().unwrap_or("").trim().to_ascii_lowercase();
        let mut q: f32 = 1.0;
        for param in parts {
            let p = param.trim();
            if let Some(rest) = p.strip_prefix("q=").or_else(|| p.strip_prefix("Q=")) {
                if let Ok(v) = rest.parse::<f32>() {
                    q = v;
                }
            }
        }
        let disallowed = q <= 0.0;
        match name.as_str() {
            "gzip" | "x-gzip" => {
                if disallowed {
                    gzip_qzero = true;
                } else {
                    gzip_seen = true;
                }
            }
            "*" => {
                if disallowed {
                    star_qzero = true;
                } else if !gzip_qzero {
                    gzip_seen = true;
                }
            }
            _ => {}
        }
    }
    // Explicit `gzip;q=0` always wins over `*`. Otherwise gzip is on
    // only when the client named it with a positive q-value — a bare
    // `*` (without q=0) could mean "any", but we stay conservative and
    // only compress when explicitly asked.
    if gzip_qzero {
        return false;
    }
    let _ = star_qzero; // star handling is advisory only here
    gzip_seen
}

pub(super) fn parse_mission_bundle(
    headers: &axum::http::HeaderMap,
    body: &[u8],
) -> Result<mission_store::MissionBundle, (StatusCode, String)> {
    use axum::http::header;
    use flate2::read::GzDecoder;
    use std::io::Read;

    let is_gzipped = headers
        .get(header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(',').any(|t| t.trim().eq_ignore_ascii_case("gzip")))
        .unwrap_or(false)
        // Also sniff the gzip magic header — CLIs uploading gzipped
        // bodies via `curl --data-binary @file.gz` sometimes forget to
        // set Content-Encoding, and hitting them with "invalid JSON"
        // instead of decoding would be a confusing footgun.
        || body.starts_with(&[0x1f, 0x8b]);

    // Stream straight from the body into `from_reader` and cap both
    // the compressed wire size (enforced at the route layer via
    // DefaultBodyLimit) and the decompressed size (via `Read::take`)
    // so a zip-bomb can't allocate more than the single-shot ceiling
    // inside the JSON parser.
    let bundle: mission_store::MissionBundle = if is_gzipped {
        let decoder = GzDecoder::new(body).take(MISSION_BUNDLE_SINGLE_SHOT_MAX_DECOMPRESSED_BYTES);
        serde_json::from_reader(std::io::BufReader::new(decoder)).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                format!("Invalid mission bundle (after gunzip): {e}"),
            )
        })?
    } else {
        let reader = body.take(MISSION_BUNDLE_SINGLE_SHOT_MAX_DECOMPRESSED_BYTES);
        serde_json::from_reader(std::io::BufReader::new(reader)).map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                format!("Invalid mission bundle: {e}"),
            )
        })?
    };

    Ok(bundle)
}

pub(super) fn sanitize_upload_id(id: &str) -> Option<String> {
    // Keep upload IDs to a conservative alphabet — these become path
    // components under /tmp, so allowing only [A-Za-z0-9_-] avoids path
    // traversal without sacrificing UUIDs or custom labels.
    let trimmed = id.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return None;
    }
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return None;
    }
    Some(trimmed.to_string())
}

pub(super) fn import_chunks_dir(upload_id: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("sandboxed_sh_mission_import_{upload_id}"))
}

/// Staging TTL. Any chunked import dir untouched for longer than this is
/// considered abandoned (client disconnect, crash, never committed) and
/// gets swept on the next `init_mission_import` call. Picked large
/// enough that a slow human-driven upload won't get culled mid-flight.
pub(super) const MISSION_IMPORT_STAGING_TTL: std::time::Duration =
    std::time::Duration::from_secs(6 * 3600);

/// Best-effort cleanup of abandoned chunked-import staging dirs. Runs
/// opportunistically on `init_mission_import`; errors are logged but not
/// propagated because temp directory sweeping must never block an
/// otherwise-valid new upload.
pub(super) fn sweep_stale_import_staging_dirs() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let Ok(name_os) = entry.file_name().into_string() else {
            continue;
        };
        if !name_os.starts_with("sandboxed_sh_mission_import_") {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        // Prefer mtime over ctime — a chunk upload touches mtime, so a
        // currently-active upload looks "fresh" even if init_ was hours
        // ago. Fall back to created() if mtime isn't available.
        let last_touched = metadata
            .modified()
            .or_else(|_| metadata.created())
            .unwrap_or(now);
        match now.duration_since(last_touched) {
            Ok(age) if age > MISSION_IMPORT_STAGING_TTL => {
                let path = entry.path();
                if let Err(e) = std::fs::remove_dir_all(&path) {
                    tracing::warn!(?path, error = %e, "Failed to sweep stale mission-import staging dir");
                } else {
                    tracing::info!(
                        ?path,
                        age_secs = age.as_secs(),
                        "Swept abandoned mission-import staging dir"
                    );
                }
            }
            _ => {}
        }
    }
}

/// Initialize a chunked mission import.
///
/// Returns `{"upload_id": "..."}` — the caller then PUTs chunks in order
/// to `/api/control/missions/import-chunks/:upload_id/:index`, and POSTs
/// `/commit` to finalize. This exists for bundles that exceed
/// Cloudflare's 100 MB per-request cap even after gzip (very long
/// missions with binary-heavy payloads that don't compress well).
///
/// For bundles under ~90 MB gzipped, prefer the single-shot `/import`
/// route — it's simpler and doesn't leave temp files on disk.
pub async fn init_mission_import(
    State(_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    // Opportunistic cleanup of prior abandoned uploads so /tmp can't
    // grow without bound. Runs on a blocking thread since it hits the
    // filesystem synchronously.
    tokio::task::spawn_blocking(sweep_stale_import_staging_dirs);

    let upload_id = Uuid::new_v4().simple().to_string();
    let dir = import_chunks_dir(&upload_id);
    tokio::fs::create_dir_all(&dir).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to create chunk staging dir: {e}"),
        )
    })?;
    Ok(Json(serde_json::json!({
        "upload_id": upload_id,
        "recommended_chunk_bytes": 80 * 1024 * 1024,
    })))
}

/// Upload one chunk of a mission import.
///
/// Path: `/api/control/missions/import-chunks/:upload_id/:index`.
/// Chunks are written to `chunk_<index:06>` under the upload's staging
/// directory. Index order determines assembly order — the commit step
/// reads `chunk_000000`, `chunk_000001`, ... in sequence.
pub async fn upload_mission_import_chunk(
    State(_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Path((upload_id, index)): Path<(String, u32)>,
    body: axum::body::Bytes,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let safe_id = sanitize_upload_id(&upload_id)
        .ok_or((StatusCode::BAD_REQUEST, "Invalid upload_id".to_string()))?;
    let dir = import_chunks_dir(&safe_id);
    if !dir.exists() {
        return Err((
            StatusCode::NOT_FOUND,
            "Unknown upload_id. Call /import-chunks first to initialize.".to_string(),
        ));
    }
    let chunk_path = dir.join(format!("chunk_{index:06}"));
    tokio::fs::write(&chunk_path, &body).await.map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Failed to write chunk {index}: {e}"),
        )
    })?;
    Ok(Json(serde_json::json!({
        "upload_id": safe_id,
        "chunk_index": index,
        "chunk_bytes": body.len(),
    })))
}

#[derive(Debug, Deserialize, Default)]
pub struct CommitMissionImportQuery {
    pub workspace_id: Option<Uuid>,
    #[serde(default)]
    pub keep_automations_active: bool,
    /// Total number of chunks the client uploaded. Must match the files
    /// present in the staging dir — any gap aborts the commit.
    pub total_chunks: u32,
    /// Hint: the bundle is gzipped (set `?gzip=true` when sending
    /// compressed chunks; otherwise server sniffs the magic header).
    #[serde(default)]
    pub gzip: bool,
}

/// Assemble uploaded chunks, optionally decompress, and run the regular
/// import.
///
/// Cleans up the staging directory on success or failure — a caller that
/// wants to retry a failed commit must re-upload all chunks under a
/// fresh `upload_id`.
pub async fn commit_mission_import(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(upload_id): Path<String>,
    axum::extract::Query(query): axum::extract::Query<CommitMissionImportQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let safe_id = sanitize_upload_id(&upload_id)
        .ok_or((StatusCode::BAD_REQUEST, "Invalid upload_id".to_string()))?;
    let dir = import_chunks_dir(&safe_id);
    if !dir.exists() {
        return Err((StatusCode::NOT_FOUND, "Unknown upload_id.".to_string()));
    }

    // Parse directly from the staged chunk files instead of concatenating
    // them into one giant `Vec<u8>` in memory. For multi-hundred-MB or GB
    // uploads that's the difference between "handled" and "OOM'd the
    // daemon". The parser streams via `serde_json::from_reader` on a
    // chained `File` iterator (optionally gzip-decoded in flight).
    let total_chunks = query.total_chunks;
    let gzip_hint = query.gzip;
    let dir_for_parse = dir.clone();
    let bundle_result = tokio::task::spawn_blocking(move || {
        parse_mission_bundle_from_chunk_dir(&dir_for_parse, total_chunks, gzip_hint)
    })
    .await
    .map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Join error while parsing import: {e}"),
        )
    })?;

    // Chunks on disk are no longer needed — wipe staging regardless of
    // parse outcome so /tmp doesn't hold the raw upload open.
    let _ = tokio::fs::remove_dir_all(&dir).await;

    let bundle = bundle_result?;
    if bundle.version != 1 {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("Unsupported bundle version {} (expected 1)", bundle.version),
        ));
    }

    let target = resolve_import_target_workspace(
        &state,
        query.workspace_id,
        bundle.workspace_name.as_deref(),
    )
    .await?;

    let control = control_for_user(&state, &user).await;
    let options = mission_store::MissionImportOptions {
        target_workspace_id: Some(target.workspace_id),
        target_workspace_name: target.workspace_name.clone(),
        keep_automations_active: query.keep_automations_active,
    };
    let original_mission_id = bundle.mission.id;
    let events_imported = bundle.events.len();
    let automations_imported = bundle.automations.len();
    let executions_imported = bundle.executions.len();
    let new_id = control
        .mission_store
        .import_mission_bundle(bundle, options)
        .await
        .map_err(internal_error)?;

    Ok(Json(serde_json::json!({
        "mission_id": new_id,
        "workspace_id": target.workspace_id,
        "original_mission_id": original_mission_id,
        "imported": {
            "events": events_imported,
            "automations": automations_imported,
            "executions": executions_imported,
        },
        "automations_active": query.keep_automations_active,
    })))
}

/// Cancel an in-progress chunked import and remove its staging dir.
pub async fn cancel_mission_import(
    State(_state): State<Arc<AppState>>,
    Extension(_user): Extension<AuthUser>,
    Path(upload_id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    let safe_id = sanitize_upload_id(&upload_id)
        .ok_or((StatusCode::BAD_REQUEST, "Invalid upload_id".to_string()))?;
    let dir = import_chunks_dir(&safe_id);
    if dir.exists() {
        tokio::fs::remove_dir_all(&dir)
            .await
            .map_err(internal_error)?;
    }
    Ok(StatusCode::NO_CONTENT)
}
