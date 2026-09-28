#[path = "context_fs.rs"]
mod secure_fs;
// Versioned project context. Metadata and immutable blobs live outside the agent-visible tree.
/// Existing project-relative paths win over the synthetic `context/` namespace.
/// A project may itself contain a directory named `context`.
pub fn resolve_reference(
    value: &str,
    exists: impl Fn(&str) -> bool,
) -> std::result::Result<String, String> {
    let value = value.trim_end_matches('/');
    valid_path(value)?;
    if exists(value) {
        return Ok(value.into());
    }
    let relative = if value == "context" {
        ""
    } else {
        value
            .strip_prefix("context/")
            .ok_or("Invalid context reference")?
    };
    if relative.is_empty() {
        return Ok(String::new());
    }
    valid_path(relative)?;
    if !exists(relative) {
        return Err(format!("Context path does not exist: {value}"));
    }
    Ok(relative.into())
}
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    path::{Component, Path, PathBuf},
};

pub const FILE_LIMIT: usize = 10 * 1024 * 1024;
pub const PROJECT_LIMIT: u64 = 100 * 1024 * 1024;
pub const ENTRY_LIMIT: usize = 5000;
pub type Result<T> = std::result::Result<T, String>;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Entry {
    pub hash: Option<String>,
    pub directory: bool,
    pub revision: u64,
    pub size: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Change {
    #[serde(default)]
    pub before: Option<Entry>,
    #[serde(default)]
    pub timestamp: u64,
    pub revision: u64,
    pub path: String,
    pub entry: Option<Entry>,
    pub source: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Operation {
    pub id: String,
    pub path: String,
    pub base: Option<u64>,
    pub hash: Option<String>,
    #[serde(default)]
    pub directory: bool,
    #[serde(default)]
    pub delete: bool,
    pub source: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Receipt {
    pub revision: u64,
    pub conflict: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Manifest {
    pub revision: u64,
    pub entries: BTreeMap<String, Entry>,
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
struct State {
    #[serde(default)]
    root_identity: Option<String>,
    manifest: Manifest,
    history: Vec<Change>,
    conflicts: BTreeMap<String, Operation>,
    receipts: BTreeMap<String, (Operation, Receipt)>,
    // A committed update must be projected before inspecting external edits after a crash.
    pending: Vec<Change>,
}
#[derive(Clone)]
pub struct Store {
    pub root: PathBuf,
    pub metadata: PathBuf,
}
fn timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn valid_path(path: &str) -> Result<()> {
    if path.is_empty()
        || path.len() > 1024
        || path.contains('\\')
        || path.chars().any(char::is_control)
    {
        return Err("invalid context path".into());
    }
    if path
        .split('/')
        .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err("context path must be canonical and relative".into());
    }
    for part in Path::new(path).components() {
        let Component::Normal(name) = part else {
            return Err("context path must be relative".into());
        };
        let name = name.to_str().ok_or("context path must be UTF-8")?;
        if name.starts_with('.')
            || matches!(name, "node_modules" | "target" | "vendor")
            || name.ends_with('~')
            || matches!(
                name,
                "id_rsa" | "id_ed25519" | "credentials.json" | "auth.json"
            )
            || name.ends_with(".pem")
            || name.ends_with(".key")
        {
            return Err(format!("excluded context path: {path}"));
        }
    }
    Ok(())
}
fn checked(root: &Path, path: &str) -> Result<PathBuf> {
    valid_path(path)?;
    let mut result = root.to_path_buf();
    if fs::symlink_metadata(root)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_symlink()
    {
        return Err("context root cannot be a symlink".into());
    }
    for component in Path::new(path).components() {
        result.push(component);
        match fs::symlink_metadata(&result) {
            Ok(meta) if meta.file_type().is_symlink() || (!meta.is_file() && !meta.is_dir()) => {
                return Err(format!("unsupported context entry: {path}"))
            }
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(result)
}
pub(crate) fn atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let parent = path.parent().ok_or("missing parent")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let temp = parent.join(format!(".context-{}.tmp", uuid::Uuid::new_v4()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|e| e.to_string())?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    fs::rename(&temp, path).map_err(|e| e.to_string())?;
    fs::File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(())
}
impl Store {
    pub fn new(root: PathBuf, metadata: PathBuf) -> Self {
        Self { root, metadata }
    }
    fn lock(&self) -> Result<fs::File> {
        fs::create_dir_all(&self.metadata).map_err(|e| e.to_string())?;
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.metadata.join("lock"))
            .map_err(|e| e.to_string())?;
        lock.lock_exclusive().map_err(|e| e.to_string())?;
        Ok(lock)
    }
    fn load(&self) -> Result<State> {
        match fs::read(self.metadata.join("state.json")) {
            Ok(data) => serde_json::from_slice(&data).map_err(|e| e.to_string()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(e.to_string()),
        }
    }
    fn save(&self, state: &State) -> Result<()> {
        let mut state = state.clone();
        let cutoff = timestamp().saturating_sub(90 * 86400);
        let mut counts = BTreeMap::<String, usize>::new();
        state.history = state
            .history
            .into_iter()
            .rev()
            .filter(|change| {
                let count = counts.entry(change.path.clone()).or_default();
                *count += 1;
                *count <= 20 || change.timestamp >= cutoff || change.timestamp == 0
            })
            .collect();
        state.history.reverse();
        atomic(
            &self.metadata.join("state.json"),
            &serde_json::to_vec(&state).map_err(|e| e.to_string())?,
        )
    }
    pub fn put_blob(&self, bytes: &[u8]) -> Result<String> {
        if bytes.len() > FILE_LIMIT {
            return Err("context file exceeds 10 MiB".into());
        }
        let hash = digest(bytes);
        let path = self.metadata.join("blobs").join(&hash);
        if !path.exists() {
            atomic(&path, bytes)?;
        }
        Ok(hash)
    }
    pub fn blob(&self, hash: &str) -> Result<Vec<u8>> {
        if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("invalid content hash".into());
        }
        let data = fs::read(self.metadata.join("blobs").join(hash)).map_err(|e| e.to_string())?;
        if digest(&data) != hash {
            return Err("context content checksum mismatch".into());
        }
        Ok(data)
    }
    fn recover(&self, state: &mut State) -> Result<()> {
        for change in state.pending.clone() {
            // Preserve a write made after a commit but before crash recovery.
            let target = checked(&self.root, &change.path)?;
            if target.is_file() {
                let bytes = secure_fs::read(&self.root, &change.path)?;
                let hash = digest(&bytes);
                if change.entry.as_ref().and_then(|e| e.hash.as_ref()) != Some(&hash)
                    && change.before.as_ref().and_then(|e| e.hash.as_ref()) != Some(&hash)
                {
                    self.put_blob(&bytes)?;
                    let id = uuid::Uuid::new_v4().to_string();
                    state.conflicts.insert(
                        id.clone(),
                        Operation {
                            id,
                            path: change.path.clone(),
                            base: change.before.as_ref().map(|e| e.revision),
                            hash: Some(hash),
                            directory: false,
                            delete: false,
                            source: "recovered filesystem edit".into(),
                        },
                    );
                    self.save(state)?;
                }
            }
            let path = checked(&self.root, &change.path)?;
            match &change.entry {
                Some(entry) if entry.directory => secure_fs::mkdir(&self.root, &change.path)?,
                Some(entry) => secure_fs::write(
                    &self.root,
                    &change.path,
                    &self.blob(entry.hash.as_deref().ok_or("missing hash")?)?,
                )?,
                None if path.is_dir() => secure_fs::remove(&self.root, &change.path, true)?,
                None if path.exists() => secure_fs::remove(&self.root, &change.path, false)?,
                None => (),
            }
        }
        if !state.pending.is_empty() {
            state.pending.clear();
            self.save(state)?;
        }
        Ok(())
    }
    fn scan_dir(
        &self,
        rel: &str,
        entries: &mut BTreeMap<String, Entry>,
        size: &mut u64,
    ) -> Result<()> {
        let dir = if rel.is_empty() {
            self.root.clone()
        } else {
            checked(&self.root, rel)?
        };
        for item in fs::read_dir(dir).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?;
            let name = item
                .file_name()
                .into_string()
                .map_err(|_| "non UTF-8 context filename")?;
            let path = if rel.is_empty() {
                name
            } else {
                format!("{rel}/{name}")
            };
            if valid_path(&path).is_err() {
                continue;
            }
            let full = checked(&self.root, &path)?;
            let meta = fs::metadata(&full).map_err(|e| e.to_string())?;
            if entries.len() >= ENTRY_LIMIT {
                return Err("context exceeds 5000 entries".into());
            }
            let entry = if meta.is_dir() {
                Entry {
                    hash: None,
                    directory: true,
                    revision: 0,
                    size: 0,
                }
            } else {
                if meta.len() > FILE_LIMIT as u64 {
                    return Err(format!("{path} exceeds 10 MiB"));
                }
                let bytes = secure_fs::read(&self.root, &path)?;
                let after = fs::metadata(&full).map_err(|e| e.to_string())?;
                if meta.len() != after.len() || meta.modified().ok() != after.modified().ok() {
                    return Err("context file changed during read; retry".into());
                }
                *size += bytes.len() as u64;
                if *size > PROJECT_LIMIT {
                    return Err("context exceeds 100 MiB".into());
                }
                Entry {
                    hash: Some(self.put_blob(&bytes)?),
                    directory: false,
                    revision: 0,
                    size: bytes.len() as u64,
                }
            };
            let directory = entry.directory;
            if entries
                .keys()
                .any(|existing| existing.to_lowercase() == path.to_lowercase() && existing != &path)
            {
                return Err(
                    "Context filenames differ only by case; rename one before syncing".into(),
                );
            }
            entries.insert(path.clone(), entry);
            if directory {
                self.scan_dir(&path, entries, size)?;
            }
        }
        Ok(())
    }
    fn reconcile(&self, state: &mut State) -> Result<()> {
        if !self.root.exists() {
            if state.manifest.revision > 0 {
                return Err("context root is missing; refusing mass deletion".into());
            }
            fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        }
        let marker = self.root.join(".sandboxed-context-root");
        if let Some(identity) = &state.root_identity {
            if fs::read_to_string(&marker).ok().as_ref() != Some(identity) {
                return Err("context root identity changed; refusing deletion or overwrite".into());
            }
        } else {
            let identity = uuid::Uuid::new_v4().to_string();
            atomic(&marker, identity.as_bytes())?;
            state.root_identity = Some(identity);
            self.save(state)?;
        }
        self.recover(state)?;
        let mut entries = BTreeMap::new();
        self.scan_dir("", &mut entries, &mut 0)?;
        let mut changes = Vec::new();
        for (path, entry) in &mut entries {
            if let Some(old) = state
                .manifest
                .entries
                .get(path)
                .filter(|old| old.hash == entry.hash && old.directory == entry.directory)
            {
                entry.revision = old.revision;
            } else {
                state.manifest.revision += 1;
                entry.revision = state.manifest.revision;
                changes.push(Change {
                    before: state.manifest.entries.get(path).cloned(),
                    timestamp: timestamp(),
                    revision: entry.revision,
                    path: path.clone(),
                    entry: Some(entry.clone()),
                    source: "filesystem".into(),
                });
            }
        }
        for path in state.manifest.entries.keys() {
            if !entries.contains_key(path) {
                state.manifest.revision += 1;
                changes.push(Change {
                    before: state.manifest.entries.get(path).cloned(),
                    timestamp: timestamp(),
                    revision: state.manifest.revision,
                    path: path.clone(),
                    entry: None,
                    source: "filesystem".into(),
                });
            }
        }
        if !changes.is_empty() {
            state.manifest.entries = entries;
            state.history.extend(changes);
            self.save(state)?;
        }
        Ok(())
    }
    pub fn manifest(&self) -> Result<Manifest> {
        let _lock = self.lock()?;
        let mut state = self.load()?;
        self.reconcile(&mut state)?;
        Ok(state.manifest)
    }
    pub fn history(&self) -> Result<Vec<Change>> {
        let _lock = self.lock()?;
        Ok(self.load()?.history)
    }
    pub fn resolve(&self, id: &str, operation: Operation) -> Result<Receipt> {
        let _lock = self.lock()?;
        let state = self.load()?;
        if !state.conflicts.contains_key(id) {
            if let Some((saved, receipt)) = state.receipts.get(&operation.id) {
                if serde_json::to_value(saved).unwrap() == serde_json::to_value(&operation).unwrap()
                {
                    return Ok(receipt.clone());
                }
            }
            return Err("conflict no longer exists".into());
        }
        self.apply_locked(operation, state, Some(id))
    }
    pub fn conflicts(&self) -> Result<BTreeMap<String, Operation>> {
        let _lock = self.lock()?;
        Ok(self.load()?.conflicts)
    }
    pub fn apply(&self, operation: Operation) -> Result<Receipt> {
        let _lock = self.lock()?;
        self.apply_locked(operation, self.load()?, None)
    }
    /// Copy by immutable blob identity, then remove only the exact source revision.
    /// A concurrent filesystem edit is retained, never deleted as part of a move.
    pub fn transfer_file(&self, path: &str, destination: &str, copy: bool) -> Result<()> {
        valid_path(path)?;
        valid_path(destination)?;
        if path == destination {
            return Err("Choose a different destination".into());
        }
        let _lock = self.lock()?;
        let mut state = self.load()?;
        self.reconcile(&mut state)?;
        let entry = state
            .manifest
            .entries
            .get(path)
            .cloned()
            .ok_or("File not found")?;
        if state
            .manifest
            .entries
            .keys()
            .any(|p| p.to_lowercase() == destination.to_lowercase())
        {
            return Err("A file or folder already exists at the destination".into());
        }
        if let Some((parent, _)) = destination.rsplit_once('/') {
            if !state
                .manifest
                .entries
                .get(parent)
                .is_some_and(|e| e.directory)
            {
                return Err("The destination folder does not exist".into());
            }
        }
        if entry.directory {
            return self.transfer_folder(state, path, destination, copy);
        }
        if !copy {
            // Persist both sides together before touching the visible tree. Recovery
            // materializes the destination before deleting the source, including
            // after a crash. A rename consumes no additional quota.
            self.blob(entry.hash.as_deref().ok_or("missing content hash")?)?;
            state.manifest.revision += 1;
            let mut moved = entry.clone();
            moved.revision = state.manifest.revision;
            let created = Change {
                before: None,
                timestamp: timestamp(),
                revision: state.manifest.revision,
                path: destination.into(),
                entry: Some(moved.clone()),
                source: "Orb".into(),
            };
            state.manifest.revision += 1;
            let deleted = Change {
                before: Some(entry),
                timestamp: timestamp(),
                revision: state.manifest.revision,
                path: path.into(),
                entry: None,
                source: "Orb".into(),
            };
            state.manifest.entries.remove(path);
            state.manifest.entries.insert(destination.into(), moved);
            state.history.extend([created.clone(), deleted.clone()]);
            state.pending.extend([created, deleted]);
            self.save(&state)?;
            self.recover(&mut state)?;
            return Ok(());
        }
        let receipt = self.apply_locked(
            Operation {
                id: uuid::Uuid::new_v4().to_string(),
                path: destination.into(),
                base: None,
                hash: entry.hash,
                directory: false,
                delete: false,
                source: "Orb".into(),
            },
            state,
            None,
        )?;
        if receipt.conflict {
            return Err("The destination changed. No file was moved".into());
        }
        Ok(())
    }
    /// Entries below `path` on disk, including ones the manifest excludes.
    fn disk_entries(dir: &Path) -> Result<usize> {
        let mut count = 0;
        for item in fs::read_dir(dir).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?;
            count += 1;
            if item.file_type().map_err(|e| e.to_string())?.is_dir() {
                count += Self::disk_entries(&item.path())?;
            }
        }
        Ok(count)
    }
    /// Move or copy a folder together with everything the manifest tracks inside
    /// it. Both sides are committed at once; recovery creates the destination
    /// tree before it removes the source, children first.
    fn transfer_folder(
        &self,
        mut state: State,
        path: &str,
        destination: &str,
        copy: bool,
    ) -> Result<()> {
        let prefix = format!("{path}/");
        if destination.starts_with(&prefix) {
            return Err("A folder cannot be moved into itself".into());
        }
        // A parent is a strict prefix of its children, so it always sorts first.
        let sources: Vec<(String, Entry)> = state
            .manifest
            .entries
            .iter()
            .filter(|(p, _)| p.as_str() == path || p.starts_with(&prefix))
            .map(|(p, e)| (p.clone(), e.clone()))
            .collect();
        if !copy && Self::disk_entries(&checked(&self.root, path)?)? != sources.len() - 1 {
            return Err(
                "This folder contains files that are not part of the project context; move or delete them first"
                    .into(),
            );
        }
        if copy {
            if state.manifest.entries.len() + sources.len() > ENTRY_LIMIT {
                return Err("context exceeds 5000 entries".into());
            }
            let total: u64 = state.manifest.entries.values().map(|e| e.size).sum();
            let added: u64 = sources.iter().map(|(_, e)| e.size).sum();
            if total + added > PROJECT_LIMIT {
                return Err("context exceeds 100 MiB".into());
            }
        }
        let mut changes = Vec::new();
        for (source, entry) in &sources {
            let target = format!("{destination}{}", &source[path.len()..]);
            valid_path(&target)?;
            if !entry.directory {
                self.blob(entry.hash.as_deref().ok_or("missing content hash")?)?;
            }
            state.manifest.revision += 1;
            let mut created = entry.clone();
            created.revision = state.manifest.revision;
            changes.push(Change {
                before: None,
                timestamp: timestamp(),
                revision: state.manifest.revision,
                path: target.clone(),
                entry: Some(created.clone()),
                source: "Orb".into(),
            });
            state.manifest.entries.insert(target, created);
        }
        if !copy {
            for (source, entry) in sources.into_iter().rev() {
                state.manifest.revision += 1;
                changes.push(Change {
                    before: Some(entry),
                    timestamp: timestamp(),
                    revision: state.manifest.revision,
                    path: source.clone(),
                    entry: None,
                    source: "Orb".into(),
                });
                state.manifest.entries.remove(&source);
            }
        }
        state.history.extend(changes.clone());
        state.pending.extend(changes);
        self.save(&state)?;
        self.recover(&mut state)
    }
    /// Delete a file, or a folder with everything the manifest tracks inside it.
    /// A folder that also holds entries outside the context is left untouched:
    /// its directory could not be removed, and the tracked files would be lost
    /// for nothing.
    pub fn delete_tree(&self, path: &str) -> Result<()> {
        valid_path(path)?;
        let manifest = self.manifest()?;
        let prefix = format!("{path}/");
        let entries: Vec<(String, Entry)> = manifest
            .entries
            .iter()
            .filter(|(p, _)| p.as_str() == path || p.starts_with(&prefix))
            .map(|(p, e)| (p.clone(), e.clone()))
            .collect();
        if manifest.entries.get(path).is_some_and(|e| e.directory)
            && Self::disk_entries(&checked(&self.root, path)?)? != entries.len() - 1
        {
            return Err(
                "This folder contains files that are not part of the project context; move or delete them first"
                    .into(),
            );
        }
        // Children sort after their parent: delete them first.
        for (path, entry) in entries.into_iter().rev() {
            let receipt = self.apply(Operation {
                id: uuid::Uuid::new_v4().to_string(),
                path,
                base: Some(entry.revision),
                hash: None,
                directory: false,
                delete: true,
                source: "Orb".into(),
            })?;
            if receipt.conflict {
                return Err("A file changed during deletion; the remaining files were kept".into());
            }
        }
        Ok(())
    }
    /// Copy a file or folder into another project's context, then remove the
    /// exact source revisions for a move. The copy always lands first, so an
    /// interruption can duplicate content but never lose it. The two stores are
    /// never locked together.
    pub fn transfer_to(
        &self,
        target: &Store,
        path: &str,
        destination: &str,
        copy: bool,
    ) -> Result<()> {
        valid_path(path)?;
        valid_path(destination)?;
        let manifest = self.manifest()?;
        let prefix = format!("{path}/");
        let sources: Vec<(String, Entry)> = manifest
            .entries
            .iter()
            .filter(|(p, _)| p.as_str() == path || p.starts_with(&prefix))
            .map(|(p, e)| (p.clone(), e.clone()))
            .collect();
        let root = sources.first().ok_or("File not found")?;
        if !copy
            && root.1.directory
            && Self::disk_entries(&checked(&self.root, path)?)? != sources.len() - 1
        {
            return Err(
                "This folder contains files that are not part of the project context; move or delete them first"
                    .into(),
            );
        }
        let existing = target.manifest()?;
        if existing
            .entries
            .keys()
            .any(|p| p.to_lowercase() == destination.to_lowercase())
        {
            return Err("A file or folder already exists at the destination".into());
        }
        if let Some((parent, _)) = destination.rsplit_once('/') {
            if !existing.entries.get(parent).is_some_and(|e| e.directory) {
                return Err("The destination folder does not exist".into());
            }
        }
        if existing.entries.len() + sources.len() > ENTRY_LIMIT {
            return Err("context exceeds 5000 entries".into());
        }
        let total: u64 = existing.entries.values().map(|e| e.size).sum();
        if total + sources.iter().map(|(_, e)| e.size).sum::<u64>() > PROJECT_LIMIT {
            return Err("context exceeds 100 MiB".into());
        }
        for (source, entry) in &sources {
            let hash = match entry.hash.as_deref() {
                Some(hash) if !entry.directory => Some(target.put_blob(&self.blob(hash)?)?),
                _ => None,
            };
            let receipt = target.apply(Operation {
                id: uuid::Uuid::new_v4().to_string(),
                path: format!("{destination}{}", &source[path.len()..]),
                base: None,
                hash,
                directory: entry.directory,
                delete: false,
                source: "Orb".into(),
            })?;
            if receipt.conflict {
                return Err("The destination changed. The source was kept".into());
            }
        }
        if copy {
            return Ok(());
        }
        for (source, entry) in sources.into_iter().rev() {
            let receipt = self.apply(Operation {
                id: uuid::Uuid::new_v4().to_string(),
                path: source,
                base: Some(entry.revision),
                hash: None,
                directory: false,
                delete: true,
                source: "Orb".into(),
            })?;
            if receipt.conflict {
                return Err(
                    "The source changed during the move; it was copied and the original was kept"
                        .into(),
                );
            }
        }
        Ok(())
    }
    fn apply_locked(
        &self,
        operation: Operation,
        mut state: State,
        resolve: Option<&str>,
    ) -> Result<Receipt> {
        valid_path(&operation.path)?;
        if operation.id.is_empty() || operation.id.len() > 128 || operation.source.len() > 128 {
            return Err("invalid operation identity".into());
        }
        self.reconcile(&mut state)?;
        if let Some((saved, receipt)) = state.receipts.get(&operation.id) {
            if serde_json::to_value(saved).unwrap() != serde_json::to_value(&operation).unwrap() {
                return Err("operation id reused with different content".into());
            }
            return Ok(receipt.clone());
        }
        let current = state.manifest.entries.get(&operation.path);
        let identical = if operation.delete {
            current.is_none()
        } else {
            current.is_some_and(|e| e.hash == operation.hash && e.directory == operation.directory)
        };
        let conflict = !identical && current.map(|e| e.revision) != operation.base;
        if !operation.delete && current.is_none() {
            let parts: Vec<_> = operation.path.split('/').collect();
            for end in 1..=parts.len() {
                let prefix = parts[..end].join("/");
                if state
                    .manifest
                    .entries
                    .keys()
                    .any(|path| path.to_lowercase() == prefix.to_lowercase() && path != &prefix)
                {
                    return Err("context filename or folder collides by case".into());
                }
            }
        }
        if !operation.delete && !operation.directory {
            self.blob(operation.hash.as_deref().ok_or("missing content hash")?)?;
        }
        if conflict {
            state
                .conflicts
                .insert(operation.id.clone(), operation.clone());
        } else if !identical {
            let target = checked(&self.root, &operation.path)?;
            if operation.delete
                && target.is_dir()
                && fs::read_dir(&target)
                    .map_err(|e| e.to_string())?
                    .next()
                    .is_some()
            {
                return Err("delete directory contents first".into());
            }
            if let Some(entry) = current {
                if !operation.delete && entry.directory != operation.directory {
                    return Err("delete existing entry before changing its type".into());
                }
            }
            let size = if operation.directory || operation.delete {
                0
            } else {
                self.blob(operation.hash.as_deref().unwrap())?.len() as u64
            };
            let total: u64 = state.manifest.entries.values().map(|e| e.size).sum();
            if total - current.map_or(0, |e| e.size) + size > PROJECT_LIMIT {
                return Err("context exceeds 100 MiB".into());
            }
            if !operation.delete && current.is_none() && state.manifest.entries.len() >= ENTRY_LIMIT
            {
                return Err("context exceeds 5000 entries".into());
            }
            state.manifest.revision += 1;
            let entry = if operation.delete {
                None
            } else {
                Some(Entry {
                    hash: operation.hash.clone(),
                    directory: operation.directory,
                    revision: state.manifest.revision,
                    size,
                })
            };
            let change = Change {
                before: current.cloned(),
                timestamp: timestamp(),
                revision: state.manifest.revision,
                path: operation.path.clone(),
                entry: entry.clone(),
                source: operation.source.clone(),
            };
            if let Some(entry) = entry {
                state.manifest.entries.insert(operation.path.clone(), entry);
            } else {
                state.manifest.entries.remove(&operation.path);
            }
            state.history.push(change.clone());
            state.pending.push(change);
        }
        let receipt = Receipt {
            revision: if identical {
                state
                    .manifest
                    .entries
                    .get(&operation.path)
                    .map_or(state.manifest.revision, |entry| entry.revision)
            } else {
                state.manifest.revision
            },
            conflict,
        };
        if !conflict {
            if let Some(id) = resolve {
                state.conflicts.remove(id);
            }
        }
        state
            .receipts
            .insert(operation.id.clone(), (operation, receipt.clone()));
        self.save(&state)?;
        self.recover(&mut state)?;
        Ok(receipt)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn context_reference_prefers_existing_project_path() {
        let exists =
            |p: &str| ["context", "context/AGENTS.md", "AGENTS.md", "PPL/guide.pdf"].contains(&p);
        assert_eq!(
            resolve_reference("context/AGENTS.md", exists).unwrap(),
            "context/AGENTS.md"
        );
        assert_eq!(
            resolve_reference("context/PPL/guide.pdf", exists).unwrap(),
            "PPL/guide.pdf"
        );
        assert_eq!(resolve_reference("context/", exists).unwrap(), "context");
        assert_eq!(resolve_reference("context", |_| false).unwrap(), "");
        assert!(resolve_reference("context/missing", exists).is_err());
        assert!(resolve_reference("context/../outside", |_| true).is_err());
    }

    fn setup() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("files"), dir.path().join("meta"));
        store.manifest().unwrap();
        (dir, store)
    }
    fn write(store: &Store, id: &str, base: Option<u64>, text: &str) -> Receipt {
        let hash = store.put_blob(text.as_bytes()).unwrap();
        store
            .apply(Operation {
                id: id.into(),
                path: "note.md".into(),
                base,
                hash: Some(hash),
                directory: false,
                delete: false,
                source: "test".into(),
            })
            .unwrap()
    }
    #[test]
    fn rename_at_entry_limit_does_not_charge_for_the_source_twice() {
        let (_dir, s) = setup();
        for i in 0..ENTRY_LIMIT {
            fs::write(s.root.join(format!("file-{i}")), b"").unwrap();
        }
        s.transfer_file("file-0", "renamed", false).unwrap();
        assert!(!s.root.join("file-0").exists());
        assert!(s.root.join("renamed").exists());
        assert_eq!(s.manifest().unwrap().entries.len(), ENTRY_LIMIT);
        assert!(s
            .transfer_file("renamed", "copy", true)
            .unwrap_err()
            .contains("5000"));
    }
    #[test]
    fn transfer_preserves_bytes_and_refuses_overwrite() {
        let (_dir, s) = setup();
        let bytes = vec![0, 255, 128, 42];
        fs::create_dir_all(s.root.join("notes")).unwrap();
        fs::write(s.root.join("notes/source.bin"), &bytes).unwrap();
        s.transfer_file("notes/source.bin", "renamed.bin", false)
            .unwrap();
        assert!(!s.root.join("notes/source.bin").exists());
        assert_eq!(fs::read(s.root.join("renamed.bin")).unwrap(), bytes);
        s.transfer_file("renamed.bin", "notes/copy.bin", true)
            .unwrap();
        assert!(s.root.join("renamed.bin").exists());
        assert_eq!(fs::read(s.root.join("notes/copy.bin")).unwrap(), bytes);
        assert!(s
            .transfer_file("renamed.bin", "notes/copy.bin", false)
            .is_err());
        assert!(s
            .transfer_file("renamed.bin", "missing/copy.bin", false)
            .is_err());
        assert!(s.transfer_file("renamed.bin", "../escape", false).is_err());
        assert_eq!(fs::read(s.root.join("renamed.bin")).unwrap(), bytes);
        let manifest = s.manifest().unwrap();
        assert!(!manifest.entries.contains_key("notes/source.bin"));
        assert_eq!(
            manifest.entries["renamed.bin"].hash,
            manifest.entries["notes/copy.bin"].hash
        );
    }
    fn tree(s: &Store) {
        fs::create_dir_all(s.root.join("notes/deep")).unwrap();
        fs::write(s.root.join("notes/a.md"), "a").unwrap();
        fs::write(s.root.join("notes/deep/b.bin"), [0u8, 255]).unwrap();
        fs::create_dir_all(s.root.join("archive")).unwrap();
        s.manifest().unwrap();
    }
    #[test]
    fn folder_move_carries_its_tree_and_refuses_unsafe_destinations() {
        let (_dir, s) = setup();
        tree(&s);
        assert!(s.transfer_file("notes", "notes/inside", false).is_err());
        assert!(s.transfer_file("notes", "Archive", false).is_err());
        assert!(s.transfer_file("notes", "missing/notes", false).is_err());
        s.transfer_file("notes", "archive/renamed", false).unwrap();
        assert!(!s.root.join("notes").exists());
        assert_eq!(
            fs::read(s.root.join("archive/renamed/deep/b.bin")).unwrap(),
            [0u8, 255]
        );
        let paths: Vec<_> = s.manifest().unwrap().entries.into_keys().collect();
        assert_eq!(
            paths,
            [
                "archive",
                "archive/renamed",
                "archive/renamed/a.md",
                "archive/renamed/deep",
                "archive/renamed/deep/b.bin"
            ]
        );
    }
    #[test]
    fn folder_copy_keeps_the_source_and_untracked_files_block_a_move() {
        let (_dir, s) = setup();
        tree(&s);
        s.transfer_file("notes", "copy", true).unwrap();
        assert_eq!(fs::read_to_string(s.root.join("notes/a.md")).unwrap(), "a");
        assert_eq!(fs::read_to_string(s.root.join("copy/a.md")).unwrap(), "a");
        fs::write(s.root.join("notes/.secret"), "kept").unwrap();
        assert!(s
            .transfer_file("notes", "moved", false)
            .unwrap_err()
            .contains("not part of the project context"));
        assert_eq!(
            fs::read_to_string(s.root.join("notes/.secret")).unwrap(),
            "kept"
        );
        assert!(!s.root.join("moved").exists());
    }
    #[test]
    fn folder_delete_removes_nothing_when_untracked_files_remain() {
        let (_dir, s) = setup();
        tree(&s);
        fs::write(s.root.join("notes/deep/.gitkeep"), "").unwrap();
        assert!(s
            .delete_tree("notes")
            .unwrap_err()
            .contains("not part of the project context"));
        assert_eq!(fs::read_to_string(s.root.join("notes/a.md")).unwrap(), "a");
        assert!(s.root.join("notes/deep/b.bin").exists());
        fs::remove_file(s.root.join("notes/deep/.gitkeep")).unwrap();
        s.delete_tree("notes").unwrap();
        assert!(!s.root.join("notes").exists());
        s.delete_tree("archive").unwrap();
        assert!(s.manifest().unwrap().entries.is_empty());
        s.delete_tree("already-gone").unwrap();
    }
    #[test]
    fn transfer_between_projects_copies_before_it_deletes() {
        let (_dir, s) = setup();
        tree(&s);
        let other = tempfile::tempdir().unwrap();
        let t = Store::new(other.path().join("files"), other.path().join("meta"));
        t.manifest().unwrap();
        fs::write(t.root.join("taken.md"), "theirs").unwrap();
        assert!(s.transfer_to(&t, "notes/a.md", "taken.md", false).is_err());
        assert!(s.root.join("notes/a.md").exists());
        s.transfer_to(&t, "notes/a.md", "a.md", false).unwrap();
        assert!(!s.root.join("notes/a.md").exists());
        assert_eq!(fs::read_to_string(t.root.join("a.md")).unwrap(), "a");
        s.transfer_to(&t, "notes", "notes", true).unwrap();
        assert_eq!(
            fs::read(t.root.join("notes/deep/b.bin")).unwrap(),
            [0u8, 255]
        );
        assert!(s.root.join("notes/deep/b.bin").exists());
        s.transfer_to(&t, "notes", "moved", false).unwrap();
        assert!(!s.root.join("notes").exists());
        assert!(t.root.join("moved/deep/b.bin").exists());
    }
    #[test]
    fn identical_write_keeps_file_revision_and_rejects_ambiguous_paths() {
        let (_dir, s) = setup();
        let first = write(&s, "first", None, "same");
        fs::write(s.root.join("other.md"), "other").unwrap();
        s.manifest().unwrap();
        assert_eq!(write(&s, "retry", None, "same").revision, first.revision);
        for path in [
            "notes//file.md",
            "notes/./file.md",
            "notes/../file.md",
            "/absolute",
            "trailing/",
        ] {
            assert!(valid_path(path).is_err());
        }
        fs::create_dir(s.root.join("Notes")).unwrap();
        s.manifest().unwrap();
        let hash = s.put_blob(b"content").unwrap();
        assert!(s
            .apply(Operation {
                id: "case".into(),
                path: "notes/file.md".into(),
                base: None,
                hash: Some(hash),
                directory: false,
                delete: false,
                source: "test".into()
            })
            .is_err());
    }
    #[test]
    fn concurrent_changes_preserve_both() {
        let (_dir, s) = setup();
        let first = write(&s, "1", None, "first");
        assert!(!first.conflict);
        let other = write(&s, "2", None, "other");
        assert!(other.conflict);
        assert_eq!(fs::read_to_string(s.root.join("note.md")).unwrap(), "first");
        assert_eq!(s.conflicts().unwrap().len(), 1);
        assert_eq!(write(&s, "2", None, "other").revision, other.revision);
    }
    #[test]
    fn external_edit_is_versioned() {
        let (_dir, s) = setup();
        let first = write(&s, "1", None, "first");
        fs::write(s.root.join("note.md"), "agent").unwrap();
        assert!(s.manifest().unwrap().revision > first.revision);
        assert!(write(&s, "2", Some(first.revision), "stale").conflict);
    }
    #[test]
    fn missing_root_does_not_delete_context() {
        let (_dir, s) = setup();
        write(&s, "1", None, "first");
        fs::remove_dir_all(&s.root).unwrap();
        assert!(s.manifest().unwrap_err().contains("mass deletion"));
    }
    #[test]
    fn rejects_escape() {
        let (_dir, s) = setup();
        for path in [
            "../secret",
            "/secret",
            "a/../../secret",
            ".env",
            "a/.git/config",
        ] {
            assert!(valid_path(path).is_err());
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/tmp", s.root.join("escape")).unwrap();
            assert!(s.manifest().is_err());
        }
    }
}
