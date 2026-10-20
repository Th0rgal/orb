//! Request/response types shared by the control HTTP API, shared files and rich tags.

use super::*;

/// Message posted by a user to the control session.
#[derive(Debug, Clone, Deserialize)]
pub struct ControlMessageRequest {
    /// Accept an ordinary follow-up durably before execution resource admission.
    #[serde(default)]
    pub queue_followup: bool,
    /// Explicit same-work assertion, checked against stored identity before dispatch.
    #[serde(default)]
    pub continue_identity: Option<crate::api::writer_recycle::WriterContinuation>,

    pub content: String,
    /// Client-generated idempotency key for the send action. When present,
    /// the backend uses it as the message id and ignores duplicate commands
    /// with the same id, so a slow/lost POST response can be retried without
    /// creating two user messages.
    #[serde(default)]
    pub client_message_id: Option<Uuid>,
    /// Optional agent override for this specific message (e.g., from @agent mention)
    #[serde(default)]
    pub agent: Option<String>,
    /// Target mission ID. If provided and differs from the currently running mission,
    /// the backend will automatically start this mission in parallel (if capacity allows).
    /// `target_mission_id` is accepted as an alias — unknown fields are otherwise
    /// silently ignored, and a mistyped targeting field would silently reroute the
    /// message to the session's current mission.
    #[serde(default, alias = "target_mission_id")]
    pub mission_id: Option<Uuid>,
    /// Explicit identity update when retasking a writer. Omit to leave
    /// stored `github_pr` / `track` / `title` unchanged; empty string
    /// clears. A different objective without these fields is refused.
    #[serde(default)]
    pub github_pr: Option<String>,
    #[serde(default)]
    pub track: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// Follow-up `@` chips: written into the live workspace before this message.
    #[serde(default)]
    pub attachments: Option<Vec<crate::api::mission_payload::MissionAttachment>>,
    /// Catch-all for unrecognized request fields — surfaced as `warnings` in
    /// the response instead of being silently dropped (a mistyped targeting
    /// field once silently rerouted a message to the wrong mission).
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ControlMessageResponse {
    pub id: Uuid,
    pub queued: bool,
    pub message_accepted: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mission_id: Option<Uuid>,
    /// Only populated for an accepted idle wake, not an active queued steer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_execution: Option<MessagePreviousExecution>,
    /// Non-fatal request problems (e.g. unrecognized fields that were
    /// ignored). Empty on clean requests; omitted from the JSON then.
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub warnings: Vec<String>,
}

/// A message waiting in the queue
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueuedMessage {
    pub id: Uuid,
    pub content: String,
    pub agent: Option<String>,
    /// Which mission this queued message belongs to
    pub mission_id: Option<Uuid>,
    /// Attribution for the message (e.g. `api:<user_id>`, `telegram`). Persisted
    /// so a queued message keeps its source after a restart. Defaults to `None`
    /// for snapshots written before this field existed.
    #[serde(default)]
    pub source: Option<String>,
    /// The actor had already consumed this message into an executing parallel
    /// turn when the snapshot was written. After restart it is a durable
    /// idempotency marker, not work to replay: the inherited run is
    /// interrupted and an explicit resume is required.
    #[serde(default)]
    pub inflight: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue_error: Option<String>,
}

/// Tool result posted by the frontend for an interactive tool call.
#[derive(Debug, Clone, Deserialize)]
pub struct ControlToolResultRequest {
    pub tool_call_id: String,
    pub name: String,
    pub result: serde_json::Value,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ControlRunState {
    #[default]
    Idle,
    Running,
    WaitingForTool,
}

/// A file shared by the agent (images render inline, other files show as download links).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SharedFile {
    /// Display name for the file
    pub name: String,
    /// Public URL to view/download
    pub url: String,
    /// MIME type (e.g., "image/png", "application/pdf")
    pub content_type: String,
    /// File size in bytes (optional)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
    /// File kind for rendering hints: "image", "document", "archive", "code", "other"
    pub kind: SharedFileKind,
}

/// Kind of shared file (determines how it renders in the UI).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SharedFileKind {
    /// Images (PNG, JPEG, GIF, WebP, SVG) - rendered inline
    Image,
    /// Documents (PDF, Word, etc.) - shown as download card
    Document,
    /// Archives (ZIP, TAR, etc.) - shown as download card
    Archive,
    /// Code/text files - shown as download card with syntax hint
    Code,
    /// Other files - generic download card
    Other,
}

impl SharedFile {
    /// Create a new SharedFile, inferring kind from content_type.
    pub fn new(
        name: impl Into<String>,
        url: impl Into<String>,
        content_type: impl Into<String>,
        size_bytes: Option<u64>,
    ) -> Self {
        let content_type = content_type.into();
        let kind = Self::infer_kind(&content_type);
        Self {
            name: name.into(),
            url: url.into(),
            content_type,
            size_bytes,
            kind,
        }
    }

    /// Infer the file kind from MIME type.
    pub(super) fn infer_kind(content_type: &str) -> SharedFileKind {
        if content_type.starts_with("image/") {
            SharedFileKind::Image
        } else if content_type.starts_with("text/")
            || content_type.contains("json")
            || content_type.contains("xml")
        {
            SharedFileKind::Code
        } else if content_type.contains("pdf")
            || content_type.contains("document")
            || content_type.contains("word")
        {
            SharedFileKind::Document
        } else if content_type.contains("zip")
            || content_type.contains("tar")
            || content_type.contains("gzip")
            || content_type.contains("compress")
        {
            SharedFileKind::Archive
        } else {
            SharedFileKind::Other
        }
    }
}

// ---------------------------------------------------------------------------
// Rich tag parsing: extract <image path="..." /> and <file path="..." /> from
// agent output so we can validate referenced files and populate shared_files.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub(super) enum RichTagType {
    Image,
    File,
}

#[derive(Debug, Clone)]
pub(super) struct RichTagRef {
    pub(super) tag_type: RichTagType,
    pub(super) path: String,
    pub(super) alt: Option<String>,
    pub(super) name: Option<String>,
}

/// Parse `<image path="..." />` and `<file path="..." />` tags from content.
pub(super) fn parse_rich_tags(content: &str) -> Vec<RichTagRef> {
    use regex::Regex;
    use std::sync::LazyLock;

    static TAG_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"<(image|file)\s+([^>]*?)\s*/>"#).unwrap());
    static ATTR_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"(\w+)\s*=\s*"([^"]*)""#).unwrap());

    let mut tags = Vec::new();
    for cap in TAG_RE.captures_iter(content) {
        let tag_type = match cap[1].to_ascii_lowercase().as_str() {
            "image" => RichTagType::Image,
            "file" => RichTagType::File,
            _ => continue,
        };
        let attr_str = &cap[2];
        let mut path = None;
        let mut alt = None;
        let mut name = None;
        for attr_cap in ATTR_RE.captures_iter(attr_str) {
            match &attr_cap[1] {
                "path" => path = Some(attr_cap[2].to_string()),
                "alt" => alt = Some(attr_cap[2].to_string()),
                "name" => name = Some(attr_cap[2].to_string()),
                _ => {}
            }
        }
        if let Some(p) = path {
            tags.push(RichTagRef {
                tag_type,
                path: p,
                alt,
                name,
            });
        }
    }
    tags
}

/// Validate rich tag paths against the filesystem and return SharedFile entries.
/// `working_dir` is used to resolve relative paths.
/// `workspace_id` and `mission_id` are included in download URLs for the frontend.
pub(super) async fn validate_rich_tags(
    tags: &[RichTagRef],
    working_dir: &std::path::Path,
    workspace_id: Option<Uuid>,
    mission_id: Option<Uuid>,
) -> Vec<SharedFile> {
    // Only allow files that resolve within the mission working directory. This keeps the
    // "shared files" surface area consistent with what the agent produced in its workspace,
    // and avoids emitting links that would be rejected by the download endpoint anyway.
    let canonical_working_dir = working_dir.canonicalize().ok();

    let mut files = Vec::new();
    for tag in tags {
        // Resolve the path relative to working_dir
        let p = std::path::Path::new(&tag.path);
        let resolved = if p.is_absolute() {
            p.to_path_buf()
        } else {
            working_dir.join(&tag.path)
        };

        // Check existence and metadata
        let meta = match tokio::fs::metadata(&resolved).await {
            Ok(m) => m,
            Err(_) => continue, // skip non-existent files
        };

        let canon_resolved = match resolved.canonicalize() {
            Ok(p) => p,
            Err(_) => continue,
        };

        if let Some(work_root) = canonical_working_dir.as_ref() {
            if !canon_resolved.starts_with(work_root) {
                continue;
            }
        }

        let size = Some(meta.len());
        let content_type = super::super::fs::content_type_for_path(&canon_resolved).to_string();

        let display_name = match &tag.tag_type {
            RichTagType::Image => tag
                .alt
                .clone()
                .or_else(|| tag.path.rsplit('/').next().map(|s| s.to_string()))
                .unwrap_or_else(|| tag.path.clone()),
            RichTagType::File => tag
                .name
                .clone()
                .or_else(|| tag.path.rsplit('/').next().map(|s| s.to_string()))
                .unwrap_or_else(|| tag.path.clone()),
        };

        // Build a download URL for the file
        let canon_str = canon_resolved.to_string_lossy();
        let mut url = format!(
            "/api/fs/download?path={}",
            urlencoding::encode(canon_str.as_ref())
        );
        if let Some(ws_id) = workspace_id {
            url.push_str(&format!("&workspace_id={}", ws_id));
        }
        if let Some(mid) = mission_id {
            url.push_str(&format!("&mission_id={}", mid));
        }

        files.push(SharedFile::new(display_name, url, content_type, size));
    }
    files
}

/// Request to set mission status.
#[derive(Debug, Clone, Deserialize)]
pub struct SetMissionStatusRequest {
    pub status: MissionStatus,
}

/// Request to rename a mission.
#[derive(Debug, Clone, Deserialize)]
pub struct SetMissionTitleRequest {
    pub title: String,
}
