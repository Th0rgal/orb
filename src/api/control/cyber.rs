//! Per-mission cyber selection. Provider authorization remains authoritative.
//! Legacy missions retain automatic selection until an operator chooses a mode.
use super::*;
use serde::{Deserialize, Serialize};
use std::path::{Path as FsPath, PathBuf};

pub const HEADER: &str = "x-sandboxed-cyber-program";
pub use crate::cyber_access::Mode;
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Selection {
    pub mode: Mode,
    /// This is the requested mode, never a claim of provider confirmation.
    pub revision: Uuid,
}
impl Default for Selection {
    fn default() -> Self {
        Self {
            mode: Mode::Automatic,
            revision: Uuid::nil(),
        }
    }
}
fn path(root: &FsPath, id: Uuid) -> PathBuf {
    root.join("mission-cyber").join(format!("{id}.json"))
}
pub fn read(root: &FsPath, id: Uuid) -> Result<Selection, String> {
    match std::fs::read(path(root, id)) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| {
            "The mission cyber setting is unreadable; refusing to guess a program.".into()
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Selection::default()),
        Err(_) => Err("The mission cyber setting could not be read.".into()),
    }
}
pub fn write(root: &FsPath, id: Uuid, mode: Mode) -> Result<Selection, String> {
    let selection = Selection {
        mode,
        revision: Uuid::new_v4(),
    };
    let dest = path(root, id);
    std::fs::create_dir_all(dest.parent().unwrap()).map_err(|e| e.to_string())?;
    let temp = dest.with_extension(format!("{}.tmp", selection.revision));
    let result = (|| {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        file.write_all(&serde_json::to_vec(&selection).unwrap())
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        std::fs::rename(&temp, &dest).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result.map(|_| selection)
}
fn response(selection: Selection) -> serde_json::Value {
    serde_json::json!({"mode":selection.mode,"revision":selection.revision,"status":"requested","confirmed_program":null,
      "note":"Selection saved for the next launch. Account authorization is checked by the provider; activation is not confirmed by a successful save."})
}
pub async fn get(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let control = control_for_user(&state, &user).await;
    let mission = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "Mission not found".into()))?;
    let selection = read(&state.config.working_dir, id).map_err(internal_error)?;
    let mut result = response(selection.clone());
    if let Some(receipt) = std::fs::read(receipt_path(&state.config.working_dir, id))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Receipt>(&bytes).ok())
    {
        if !mission
            .project
            .tags
            .iter()
            .any(|tag| tag == client_placement::TAG)
            && receipt.revision == selection.revision
            && mission.model_override.as_deref() == Some(receipt.requested_model.as_str())
        {
            result["status"] = serde_json::json!("confirmed");
            result["confirmed_program"] = serde_json::json!(receipt.program);
            result["confirmed_model"] = serde_json::json!(receipt.model);
        }
    }
    Ok(Json(result))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub mode: Mode,
}
pub async fn update(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
    Json(change): Json<Change>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let _guard = DISPATCH_ADMISSION.lock().await;
    let control = control_for_user(&state, &user).await;
    let mission = control
        .mission_store
        .get_mission(id)
        .await
        .map_err(internal_error)?
        .ok_or((StatusCode::NOT_FOUND, "Mission not found".into()))?;
    if !matches!(
        mission.status,
        MissionStatus::AwaitingUser
            | MissionStatus::Acknowledged
            | MissionStatus::Interrupted
            | MissionStatus::Failed
            | MissionStatus::Paused
            | MissionStatus::Blocked
    ) {
        return Err((StatusCode::CONFLICT,"Stop the current turn before changing its cyber program. Your selection has not changed.".into()));
    }
    if mission.backend != "codex" {
        return Err((
            StatusCode::BAD_REQUEST,
            "Cyber selection is available for Codex only.".into(),
        ));
    }
    change
        .mode
        .program(mission.model_override.as_deref().unwrap_or(""))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    Ok(Json(response(
        write(&state.config.working_dir, id, change.mode).map_err(internal_error)?,
    )))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn access_is_separate_from_the_model() {
        assert_eq!(
            Mode::Daybreak.native("gpt-6.1-sol").unwrap(),
            Some("daybreakBlue")
        );
        assert_eq!(
            Mode::Daybreak.program("gpt-6-astra").unwrap(),
            Some("daybreak_blue")
        );
        assert!(Mode::Standard.program("gpt-daybreak-blue-latest").is_err());
        assert!(Mode::Daybreak.program("unrecognized-model").is_err());
        assert_eq!(Mode::Automatic.program("any-model").unwrap(), None);
    }
    #[test]
    fn provider_evidence_requires_current_execution_key() {
        let root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let key = Uuid::new_v4();
        let selection = write(root.path(), id, Mode::Standard).unwrap();
        assert!(proxy_selection(root.path(), id, key).is_none());
        bind_proxy(root.path(), id, selection.revision, key).unwrap();
        assert!(proxy_selection(root.path(), id, key).is_some());
        assert!(proxy_selection(root.path(), id, Uuid::new_v4()).is_none());
        write(root.path(), id, Mode::Daybreak).unwrap();
        assert!(proxy_selection(root.path(), id, key).is_none());
    }
    #[test]
    fn legacy_and_persistence() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        assert_eq!(read(dir.path(), id).unwrap().mode, Mode::Automatic);
        let saved = write(dir.path(), id, Mode::Standard).unwrap();
        assert_eq!(read(dir.path(), id).unwrap().revision, saved.revision);
        std::fs::write(path(dir.path(), id), b"broken").unwrap();
        assert!(read(dir.path(), id).is_err());
    }
}

#[derive(Serialize, Deserialize)]
struct Receipt {
    revision: Uuid,
    requested_model: String,
    program: String,
    model: String,
}
fn receipt_path(root: &FsPath, id: Uuid) -> PathBuf {
    path(root, id).with_extension("receipt.json")
}
/// Only structured provider metadata can confirm activation. Assistant text is
/// never evidence, and an old model/selection receipt cannot confirm a new one.
fn confirmation(value: &serde_json::Value) -> Option<(&str, &str)> {
    if !matches!(
        value["type"].as_str(),
        Some("response.created" | "response.completed")
    ) {
        return None;
    }
    let program = value.pointer("/response/access_programs/cyber")?.as_str()?;
    if !matches!(program, "standard" | "daybreak_blue" | "daybreak_red") {
        return None;
    }
    Some((program, value.pointer("/response/model")?.as_str()?))
}
pub fn observe(
    inner: impl futures::Stream<Item = Result<bytes::Bytes, std::io::Error>> + Send + 'static,
    receipt: Option<(PathBuf, Uuid, Selection, String)>,
) -> impl futures::Stream<Item = Result<bytes::Bytes, std::io::Error>> + Send + 'static {
    use futures::StreamExt;
    async_stream::stream! {
        let mut inner=std::pin::pin!(inner);
        let mut line=Vec::new(); let mut oversized=false; let mut recorded=false;
        while let Some(chunk)=inner.next().await {
            if let (Some((root,id,selection,requested_model)),Ok(bytes))=(&receipt,&chunk) {
                if !recorded {
                    for b in bytes {
                        if *b==b'\n' {
                            if !oversized {
                                if let Some(data)=line.strip_prefix(b"data: ") {
                                    if let Ok(value)=serde_json::from_slice::<serde_json::Value>(data) {
                                        if let Some((program,model))=confirmation(&value) {
                                            if selection.mode.program(requested_model).ok().flatten().is_none_or(|requested|requested==program) {
                                                let record=Receipt{revision:selection.revision,requested_model:requested_model.clone(),program:program.into(),model:model.into()};
                                                let dest=receipt_path(root,*id);let tmp=dest.with_extension(format!("{}.tmp",Uuid::new_v4()));
                                                if std::fs::write(&tmp,serde_json::to_vec(&record).unwrap()).is_ok(){let _=std::fs::rename(&tmp,dest);}let _=std::fs::remove_file(&tmp);
                                                recorded=true;
                                            }
                                        }
                                    }
                                }
                            }
                            line.clear();oversized=false;
                        } else if !oversized { if line.len()<65536 {line.push(*b);} else {line.clear();oversized=true;} }
                    }
                }
            }
            yield chunk;
        }
    }
}

#[cfg(test)]
mod receipt_tests {
    use super::*;
    use futures::StreamExt;
    #[tokio::test]
    async fn only_provider_metadata_confirms_and_chunks_are_unchanged() {
        let root = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let selection = write(root.path(), id, Mode::Standard).unwrap();
        let payload=b"data: {\"type\":\"response.created\",\"response\":{\"model\":\"gpt-6.1-sol\",\"access_programs\":{\"cyber\":\"standard\"}}}\n\n";
        let chunks: Vec<_> = payload
            .chunks(7)
            .map(|c| Ok(bytes::Bytes::copy_from_slice(c)))
            .collect();
        let stream = observe(
            futures::stream::iter(chunks),
            Some((
                root.path().into(),
                id,
                selection.clone(),
                "gpt-6.1-sol".into(),
            )),
        );
        let output: Vec<_> = stream.collect().await;
        assert_eq!(
            output
                .into_iter()
                .flat_map(|c| c.unwrap().to_vec())
                .collect::<Vec<_>>(),
            payload
        );
        let receipt: Receipt =
            serde_json::from_slice(&std::fs::read(receipt_path(root.path(), id)).unwrap()).unwrap();
        assert_eq!(receipt.revision, selection.revision);
        assert_eq!(receipt.program, "standard");
        let assistant =
            serde_json::json!({"type":"response.output_text.delta","delta":"Daybreak is active"});
        assert!(confirmation(&assistant).is_none());
        let changed = write(root.path(), id, Mode::Daybreak).unwrap();
        assert_ne!(receipt.revision, changed.revision);
    }
}

/// Key names are user-controlled labels. Only an execution-issued binding can
/// attribute provider evidence to a mission.
pub fn bind_proxy(root: &FsPath, id: Uuid, revision: Uuid, key: Uuid) -> Result<(), String> {
    let dest = path(root, id).with_extension("binding.json");
    let temp = dest.with_extension(format!("{}.tmp", Uuid::new_v4()));
    std::fs::write(&temp, serde_json::to_vec(&(revision, key)).unwrap())
        .map_err(|e| e.to_string())?;
    let result = std::fs::rename(&temp, dest).map_err(|e| e.to_string());
    let _ = std::fs::remove_file(temp);
    result
}
pub fn proxy_selection(root: &FsPath, id: Uuid, key: Uuid) -> Option<Selection> {
    let selection = read(root, id).ok()?;
    let binding: (Uuid, Uuid) =
        serde_json::from_slice(&std::fs::read(path(root, id).with_extension("binding.json")).ok()?)
            .ok()?;
    (binding == (selection.revision, key)).then_some(selection)
}

pub async fn capabilities() -> Json<serde_json::Value> {
    Json(
        serde_json::json!({"version":1,"request_field":"cyber_access","native_goals_explicit":false}),
    )
}
