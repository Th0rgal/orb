/-
  OrbNode.ProjectContext: Node-Owned Project Context Replica (`shared/project_context.rs` +
  `shared/context_replica.rs` + `src/node/project_context.rs`).
  Synchronizes `<work_dir>/project-context/<sha256(endpoint)>/<project>/{files,state}` against
  `<endpoint>/api/projects/<project>/context/{manifest,blobs,operations,conflicts}` over HTTP(S)
  without leaking the context Bearer token into the mission harness environment.
-/
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient

namespace OrbNode.ProjectContext

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient

def contextFileLimit : Nat := 10 * 1024 * 1024
def contextConfirmedFileLimit : UInt64 := 2 * 1024 * 1024 * 1024
def contextProjectLimit : UInt64 := 100 * 1024 * 1024
def contextEntryLimit : Nat := 5000

def validContextPath (path : String) : Except String Unit := do
  if path.isEmpty || path.length > 1024 || path.contains '\\' then
    throw "invalid context path"
  if path.any (fun c => c.toNat < 32 || c.toNat == 127) then
    throw "invalid context path"
  let segs := path.splitOn "/"
  if segs.any (fun seg => seg.isEmpty || seg == "." || seg == "..") then
    throw "context path must be canonical and relative"
  for name in segs do
    if name.startsWith "." ||
       name == "node_modules" || name == "target" || name == "vendor" ||
       name.endsWith "~" ||
       name == "id_rsa" || name == "id_ed25519" ||
       name == "credentials.json" || name == "auth.json" ||
       name.endsWith ".pem" || name.endsWith ".key" then
      throw s!"excluded context path: {path}"

def checkedContextPath (root : System.FilePath) (rel : String) : IO (Except String System.FilePath) := do
  if let .error e := validContextPath rel then
    return .error e
  let rst ← statPath root.toString
  if rst.exists_ && rst.isSymlink then
    return .error "context root cannot be a symlink"
  let mut cur := root
  for seg in rel.splitOn "/" do
    cur := cur / seg
    let st ← statPath cur.toString
    if st.exists_ then
      if st.isSymlink || (!st.isReg && !st.isDir) then
        return .error s!"unsupported context entry: {rel}"
  return .ok cur

structure ContextEntry where
  hash?     : Option String
  directory : Bool
  revision  : UInt64
  size      : UInt64
  deriving Repr, BEq, Inhabited

def ContextEntry.sameContent (a? b? : Option ContextEntry) : Bool :=
  match a?, b? with
  | none, none => true
  | some a, some b => a.hash? == b.hash? && a.directory == b.directory
  | _, _ => false

def ContextEntry.toJson (e : ContextEntry) : JVal :=
  .obj #[
    ("hash", match e.hash? with | some h => .str h | none => .null),
    ("directory", .bool e.directory),
    ("revision", JVal.uint64 e.revision),
    ("size", JVal.uint64 e.size)
  ]

def ContextEntry.fromJson? (v : JVal) : Option ContextEntry := do
  let directory := (v.fieldBool? "directory").getD false
  let revision := (v.fieldUInt64? "revision").getD 0
  let size := (v.fieldUInt64? "size").getD 0
  let hash? :=
    match v.field? "hash" with
    | some (.str s) => some s
    | _ => none
  return { hash?, directory, revision, size }

structure ContextManifest where
  revision : UInt64 := 0
  entries  : Array (String × ContextEntry) := #[]
  deriving Repr, BEq, Inhabited

def ContextManifest.get? (m : ContextManifest) (p : String) : Option ContextEntry :=
  (m.entries.find? (fun (k, _) => k == p)).map Prod.snd

def ContextManifest.upsert (m : ContextManifest) (p : String) (e : ContextEntry) : ContextManifest :=
  let next := (m.entries.filter (fun (k, _) => k != p)).push (p, e)
  { m with entries := next.qsort (fun a b => a.1 < b.1) }

def ContextManifest.erase (m : ContextManifest) (p : String) : ContextManifest :=
  { m with entries := m.entries.filter (fun (k, _) => k != p) }

def ContextManifest.toJson (m : ContextManifest) : JVal :=
  let sorted := m.entries.qsort (fun a b => a.1 < b.1)
  .obj #[
    ("revision", JVal.uint64 m.revision),
    ("entries", .obj (sorted.map fun (p, e) => (p, e.toJson)))
  ]

def ContextManifest.fromJson? (v : JVal) : Option ContextManifest := do
  let rev := (v.fieldUInt64? "revision").getD 0
  let rawEntries ← (v.field? "entries") >>= JVal.asObj?
  let mut parsed : Array (String × ContextEntry) := #[]
  for (k, ev) in rawEntries do
    let ce ← ContextEntry.fromJson? ev
    parsed := parsed.push (k, ce)
  return { revision := rev, entries := parsed.qsort (fun a b => a.1 < b.1) }

structure ContextOperation where
  id             : String
  path           : String
  base?          : Option UInt64 := none
  hash?          : Option String := none
  directory      : Bool := false
  delete         : Bool := false
  source         : String := "compute node"
  confirmedLarge : Bool := false
  deriving Repr, BEq, Inhabited

def ContextOperation.toJson (op : ContextOperation) : JVal :=
  .obj #[
    ("id", .str op.id),
    ("path", .str op.path),
    ("base", match op.base? with | some b => JVal.uint64 b | none => .null),
    ("hash", match op.hash? with | some h => .str h | none => .null),
    ("directory", .bool op.directory),
    ("delete", .bool op.delete),
    ("source", .str op.source),
    ("confirmed_large", .bool op.confirmedLarge)
  ]

def ContextOperation.fromJson? (v : JVal) : Option ContextOperation := do
  let id ← v.fieldStr? "id"
  let path ← v.fieldStr? "path"
  let base? := v.fieldUInt64? "base"
  let hash? := v.fieldStr? "hash"
  let directory := (v.fieldBool? "directory").getD false
  let delete := (v.fieldBool? "delete").getD false
  let source := (v.fieldStr? "source").getD "compute node"
  let confirmedLarge := (v.fieldBool? "confirmed_large").getD false
  return { id, path, base?, hash?, directory, delete, source, confirmedLarge }

structure ReplicaState where
  initialized      : Bool := false
  ready            : Bool := false
  baseline         : ContextManifest := {}
  pending          : Array ContextOperation := #[]
  conflicts        : Array (String × String) := #[]
  conflictVersions : Array (String × Option String) := #[]
  error?           : Option String := none
  deriving Repr, Inhabited

def ReplicaState.toJson (s : ReplicaState) : JVal :=
  .obj #[
    ("initialized", .bool s.initialized),
    ("ready", .bool s.ready),
    ("baseline", s.baseline.toJson),
    ("pending", .arr (s.pending.map ContextOperation.toJson)),
    ("conflicts", .obj (s.conflicts.map fun (k, v) => (k, .str v))),
    ("conflict_versions", .obj (s.conflictVersions.map fun (k, v) =>
      (k, match v with | some h => .str h | none => .null))),
    ("error", match s.error? with | some e => .str e | none => .null)
  ]

def ReplicaState.fromJson? (v : JVal) : Option ReplicaState := do
  let initialized := (v.fieldBool? "initialized").getD false
  let ready := (v.fieldBool? "ready").getD false
  let baseline := ((v.field? "baseline") >>= ContextManifest.fromJson?).getD {}
  let pending := ((v.fieldArr? "pending").getD #[]).filterMap ContextOperation.fromJson?
  let conflicts :=
    match (v.field? "conflicts") >>= JVal.asObj? with
    | some kvs => kvs.filterMap (fun (k, cv) => cv.asStr?.map (fun s => (k, s)))
    | none => #[]
  let conflictVersions :=
    match (v.field? "conflict_versions") >>= JVal.asObj? with
    | some kvs => kvs.map (fun (k, cv) => (k, cv.asStr?))
    | none => #[]
  let error? := v.fieldStr? "error"
  return { initialized, ready, baseline, pending, conflicts, conflictVersions, error? }

private def writeAtomicFile (dest : System.FilePath) (bytes : ByteArray) : IO (Except String Unit) := do
  if let some par := dest.parent then
    IO.FS.createDirAll par
  let nonce ← newUuidV4
  let tmp := System.FilePath.mk s!"{dest}.tmp-{nonce}"
  match ← (do
    IO.FS.writeBinFile tmp bytes
    IO.FS.rename tmp dest
  ).toBaseIO with
  | .ok () => return .ok ()
  | .error e =>
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error (toString e)

private def storePutBlob (stateDir : System.FilePath) (bytes : ByteArray) (confirmedLarge : Bool := false) :
    IO (Except String String) := do
  let maxB : UInt64 := if confirmedLarge then contextConfirmedFileLimit else contextFileLimit.toUInt64
  if bytes.size.toUInt64 > maxB then
    return .error "Context file exceeds limit"
  let hash := bytesToHexLower (sha256Bytes bytes)
  let blobPath := stateDir / "blobs" / hash
  if !(← blobPath.pathExists) then
    if let .error e ← writeAtomicFile blobPath bytes then
      return .error e
  return .ok hash

private def storeReadBlob (stateDir : System.FilePath) (hash : String) : IO (Except String ByteArray) := do
  if hash.length != 64 || !hash.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')) then
    return .error "invalid content hash"
  let blobPath := stateDir / "blobs" / hash.toLower
  if !(← blobPath.pathExists) then
    return .error "blob not found"
  let .ok bytes ← IO.FS.readBinFile blobPath |>.toBaseIO
    | return .error "failed reading context blob"
  if bytesToHexLower (sha256Bytes bytes) != hash.toLower then
    return .error "context content checksum mismatch"
  return .ok bytes

/-- Reconcile visible `<filesDir>` working tree with `<stateDir>/state.json` and return current `ContextManifest`. -/
def reconcileLocalStore (filesDir stateDir : System.FilePath) : IO (Except String ContextManifest) := do
  IO.FS.createDirAll stateDir
  let stateFile := stateDir / "state.json"
  let (prevId?, prevManifest) ←
    if ← stateFile.pathExists then
      match ← IO.FS.readFile stateFile |>.toBaseIO with
      | .ok raw =>
        match OrbBin.Json.parse raw with
        | .ok jv =>
          let rid? := jv.fieldStr? "root_identity"
          let m := ((jv.field? "manifest") >>= ContextManifest.fromJson?).getD {}
          pure (rid?, m)
        | .error _ => pure (none, ({} : ContextManifest))
      | .error _ => pure (none, ({} : ContextManifest))
    else
      pure (none, ({} : ContextManifest))
  if !(← filesDir.pathExists) then
    if prevManifest.revision > 0 then
      return .error "context root is missing; refusing mass deletion"
    IO.FS.createDirAll filesDir
  let marker := filesDir / ".sandboxed-context-root"
  let rootIdentity ←
    match prevId? with
    | some expected =>
      let actual? ← (IO.FS.readFile marker).toBaseIO
      match actual? with
      | .ok s =>
        if s != expected then
          return .error "context root identity changed; refusing deletion or overwrite"
        pure expected
      | .error _ =>
        return .error "context root identity changed; refusing deletion or overwrite"
    | none =>
      let fresh ← newUuidV4
      if let .error e ← writeAtomicFile marker fresh.toUTF8 then
        return .error e
      pure fresh
  let mut pendingDirs : Array (System.FilePath × String) := #[(filesDir, "")]
  let mut scanned : Array (String × ContextEntry) := #[]
  let mut totalSize : UInt64 := 0
  while !pendingDirs.isEmpty do
    let (curDir, relPfx) := pendingDirs.back!
    pendingDirs := pendingDirs.pop
    let .ok rawItems ← curDir.readDir |>.toBaseIO
      | return .error s!"failed reading context directory {curDir}"
    let items := rawItems.qsort (fun a b => a.fileName < b.fileName)
    for item in items do
      let rel := if relPfx.isEmpty then item.fileName else s!"{relPfx}/{item.fileName}"
      if (validContextPath rel).isOk then
        let full ← match ← checkedContextPath filesDir rel with
          | .ok p => pure p
          | .error e => return .error e
        if scanned.size >= contextEntryLimit then
          return .error "context exceeds 5000 entries"
        if scanned.any (fun (k, _) => k.toLower == rel.toLower && k != rel) then
          return .error "Context filenames differ only by case; rename one before syncing"
        let st ← statPath full.toString
        if st.isDir then
          scanned := scanned.push (rel, { hash? := none, directory := true, revision := 0, size := 0 })
          pendingDirs := pendingDirs.push (full, rel)
        else if st.isReg then
          let .ok bytes ← IO.FS.readBinFile full |>.toBaseIO
            | return .error s!"failed reading context file {rel}"
          let isLarge := bytes.size > contextFileLimit
          let hash ← match ← storePutBlob stateDir bytes isLarge with
            | .ok h => pure h
            | .error e => return .error e
          totalSize := totalSize + bytes.size.toUInt64
          scanned := scanned.push (rel, { hash? := some hash, directory := false, revision := 0, size := bytes.size.toUInt64 })
  let mut nextRev := prevManifest.revision
  let mut changed := false
  let mut finalEntries : Array (String × ContextEntry) := #[]
  for (path, entry) in scanned.qsort (fun a b => a.1 < b.1) do
    match prevManifest.get? path with
    | some old =>
      if old.hash? == entry.hash? && old.directory == entry.directory then
        finalEntries := finalEntries.push (path, { entry with revision := old.revision })
      else
        nextRev := nextRev + 1
        changed := true
        finalEntries := finalEntries.push (path, { entry with revision := nextRev })
    | none =>
      nextRev := nextRev + 1
      changed := true
      finalEntries := finalEntries.push (path, { entry with revision := nextRev })
  for (oldPath, _) in prevManifest.entries do
    if !(finalEntries.any (fun (k, _) => k == oldPath)) then
      nextRev := nextRev + 1
      changed := true
  let nextManifest : ContextManifest := { revision := nextRev, entries := finalEntries }
  if changed || prevId?.isNone then
    let stJson := JVal.obj #[
      ("root_identity", .str rootIdentity),
      ("manifest", nextManifest.toJson),
      ("history", .arr #[]),
      ("conflicts", .obj #[]),
      ("receipts", .obj #[]),
      ("pending", .arr #[])
    ]
    if let .error e ← writeAtomicFile stateFile (renderCompact stJson).toUTF8 then
      return .error e
  return .ok nextManifest

private def applyLocalOperation
    (filesDir stateDir : System.FilePath) (op : ContextOperation) : IO (Except String Bool) := do
  let curManifest ← match ← reconcileLocalStore filesDir stateDir with
    | .ok m => pure m
    | .error e => return .error e
  let curEntry? := curManifest.get? op.path
  let identical :=
    if op.delete then curEntry?.isNone
    else match curEntry? with
      | some ce => ce.hash? == op.hash? && ce.directory == op.directory
      | none => false
  if !identical && curEntry?.map (·.revision) != op.base? then
    return .ok true
  let target ← match ← checkedContextPath filesDir op.path with
    | .ok p => pure p
    | .error e => return .error e
  if op.delete then
    let st ← statPath target.toString
    if st.exists_ then
      if st.isDir then
        let children ← match ← target.readDir |>.toBaseIO with
          | .ok cs => pure cs
          | .error e => return .error (toString e)
        if !children.isEmpty then
          return .error "delete directory contents first"
        match ← (IO.FS.removeDir target).toBaseIO with
        | .ok () => pure ()
        | .error e => return .error (toString e)
      else
        match ← (IO.FS.removeFile target).toBaseIO with
        | .ok () => pure ()
        | .error e => return .error (toString e)
  else if op.directory then
    IO.FS.createDirAll target
  else
    let some h := op.hash?
      | return .error "missing content hash"
    let blobBytes ← match ← storeReadBlob stateDir h with
      | .ok b => pure b
      | .error e => return .error e
    if let some par := target.parent then
      IO.FS.createDirAll par
    if let .error e ← writeAtomicFile target blobBytes then
      return .error e
  let _ ← reconcileLocalStore filesDir stateDir
  return .ok false

private def buildContextUrl (endpoint project suffix : String) : Except String String := do
  let ep := (endpoint.trimAscii.dropEndWhile (· == '/')).toString
  if !(ep.startsWith "http://" || ep.startsWith "https://") then
    throw "context endpoint must use HTTP(S)"
  let parsed ← parseUrl ep
  let basePath := (parsed.pathQuery.splitOn "?").headD "/"
  let cleanBase := (basePath.dropEndWhile (· == '/')).toString
  let scheme := if parsed.isHttps then "https" else "http"
  return s!"{scheme}://{parsed.hostHeader}{cleanBase}/api/projects/{urlEncodeComponent project}/context/{suffix}"

private def contextHttpRequest
    (endpoint token project method suffix : String)
    (body : ByteArray := ByteArray.empty)
    (isJson : Bool := false)
    (maxBytes : Nat := 32 * 1024 * 1024) : IO (Except String ByteArray) := do
  let url ← match buildContextUrl endpoint project suffix with
    | .ok u => pure u
    | .error e => return .error e
  let mut hdrs : Array (String × String) := #[("Authorization", s!"Bearer {token}")]
  if isJson then
    hdrs := hdrs.push ("Content-Type", "application/json")
  match ← sendRequest method url hdrs body 15000 maxBytes with
  | .error _ => return .error "Context server unavailable"
  | .ok resp =>
    if 200 ≤ resp.status && resp.status < 300 then
      return .ok resp.body
    else
      return .error s!"Context sync returned HTTP {resp.status}"

private def loadReplicaState (stateDir : System.FilePath) : IO ReplicaState := do
  let p := stateDir / "replica.json"
  if !(← p.pathExists) then return {}
  let .ok raw ← IO.FS.readFile p |>.toBaseIO | return {}
  let .ok jv := OrbBin.Json.parse raw | return {}
  return (ReplicaState.fromJson? jv).getD {}

private def saveReplicaState (stateDir : System.FilePath) (st : ReplicaState) : IO (Except String Unit) := do
  let p := stateDir / "replica.json"
  let nextBytes := (renderCompact st.toJson).toUTF8
  if ← p.pathExists then
    if let .ok ex ← IO.FS.readBinFile p |>.toBaseIO then
      if ex == nextBytes then return .ok ()
  writeAtomicFile p nextBytes

private def synchronizeReplicaInner
    (filesDir stateDir : System.FilePath) (endpoint token project : String)
    (st0 : ReplicaState) : IO (Except String ReplicaState) := do
  let mut st := st0
  let localM ← match ← reconcileLocalStore filesDir stateDir with
    | .ok m => pure m
    | .error e => return .error e
  if st.initialized then
    let mut allPaths : Array String := #[]
    for (p, _) in localM.entries do
      if !allPaths.contains p then allPaths := allPaths.push p
    for (p, _) in st.baseline.entries do
      if !allPaths.contains p then allPaths := allPaths.push p
    for path in allPaths.qsort (· < ·) do
      let hasConflict := st.conflicts.any (fun (cp, _) => cp == path)
      let hasPending := st.pending.any (fun op => op.path == path)
      if !hasConflict && !hasPending then
        let entry? := localM.get? path
        let base? := st.baseline.get? path
        if !ContextEntry.sameContent entry? base? then
          let replacing := match entry?, base? with
            | some e, some b => e.directory != b.directory
            | _, _ => false
          let opId ← newUuidV4
          let op : ContextOperation := {
            id := opId
            path := path
            base? := base?.map (·.revision)
            hash? := if replacing then none else entry?.bind (·.hash?)
            directory := !replacing && (entry?.map (·.directory) |>.getD false)
            delete := replacing || entry?.isNone
            source := "compute node"
            confirmedLarge := (entry?.map (fun e => decide (e.size > contextFileLimit.toUInt64)) |>.getD false)
          }
          st := { st with pending := st.pending.push op }
    let sortedPending := st.pending.qsort fun a b =>
      if a.delete != b.delete then a.delete
      else if a.delete then a.path.length > b.path.length
      else a.path.length < b.path.length
    st := { st with pending := sortedPending }
    let _ ← saveReplicaState stateDir st
  let initRemoteBytes ← match ← contextHttpRequest endpoint token project "GET" "manifest" with
    | .ok b => pure b
    | .error e => return .error e
  let .ok initRemoteJv := OrbBin.Json.parseBytes initRemoteBytes
    | return .error "invalid context manifest JSON"
  let some initRemote := ContextManifest.fromJson? initRemoteJv
    | return .error "malformed context manifest JSON"
  if !st.initialized && !localM.entries.isEmpty then
    return .error "Uninitialized context cache contains files; refusing to overwrite"
  if !st.initialized then
    st := { st with initialized := true }
    let _ ← saveReplicaState stateDir st
  let hadPending := !st.pending.isEmpty
  while h : 0 < st.pending.size do
    let op := st.pending[0]
    if let some blobHash := op.hash? then
      let blobBytes ← match ← storeReadBlob stateDir blobHash with
        | .ok b => pure b
        | .error e => return .error e
      if let .error e ← contextHttpRequest endpoint token project "POST" "blobs" blobBytes false then
        return .error e
    let opBytes := (renderCompact op.toJson).toUTF8
    let rcptBytes ← match ← contextHttpRequest endpoint token project "POST" "operations" opBytes true with
      | .ok b => pure b
      | .error e => return .error e
    let .ok rcptJv := OrbBin.Json.parseBytes rcptBytes
      | return .error "invalid operation receipt JSON"
    let isConflict := (rcptJv.fieldBool? "conflict").getD false
    let rcptRev := (rcptJv.fieldUInt64? "revision").getD 0
    if isConflict then
      st := {
        st with
        conflicts := (st.conflicts.filter (fun (k, _) => k != op.path)).push (op.path, op.id)
        conflictVersions := (st.conflictVersions.filter (fun (k, _) => k != op.path)).push (op.path, op.hash?)
      }
    else if op.delete then
      st := { st with baseline := st.baseline.erase op.path }
    else
      st := {
        st with
        baseline := st.baseline.upsert op.path {
          hash? := op.hash?
          directory := op.directory
          revision := rcptRev
          size := 0
        }
      }
    st := { st with pending := st.pending.extract 1 st.pending.size }
    let _ ← saveReplicaState stateDir st
  let remoteM : ContextManifest ←
    if hadPending then
      let rb ← match ← contextHttpRequest endpoint token project "GET" "manifest" with
        | .ok b => pure b
        | .error e => return .error e
      let .ok rjv := OrbBin.Json.parseBytes rb
        | return .error "invalid context manifest JSON"
      let some rm := ContextManifest.fromJson? rjv
        | return .error "malformed context manifest JSON"
      pure rm
    else pure initRemote
  let curM ← match ← reconcileLocalStore filesDir stateDir with
    | .ok m => pure m
    | .error e => return .error e
  if !st.conflicts.isEmpty then
    let openBytes ← match ← contextHttpRequest endpoint token project "GET" "conflicts" with
      | .ok b => pure b
      | .error e => return .error e
    let .ok openJv := OrbBin.Json.parseBytes openBytes
      | return .error "invalid open conflicts JSON"
    let openIds : Array String :=
      match openJv.asObj? with
      | some kvs => kvs.map (·.1)
      | none => #[]
    let resolvedPaths := (st.conflicts.filter (fun (_, cid) => !openIds.contains cid)).map (·.1)
    for path in resolvedPaths do
      let existing? := curM.get? path
      let recordedVer? := (st.conflictVersions.find? (fun (k, _) => k == path)).bind (·.2)
      if existing?.bind (·.hash?) == recordedVer? then
        match existing? with
        | some exE => st := { st with baseline := st.baseline.upsert path exE }
        | none => st := { st with baseline := st.baseline.erase path }
      st := {
        st with
        conflicts := st.conflicts.filter (fun (k, _) => k != path)
        conflictVersions := st.conflictVersions.filter (fun (k, _) => k != path)
      }
    let _ ← saveReplicaState stateDir st
  let mut syncPaths : Array String := #[]
  for (p, _) in remoteM.entries do
    if !syncPaths.contains p then syncPaths := syncPaths.push p
  for (p, _) in st.baseline.entries do
    if !syncPaths.contains p then syncPaths := syncPaths.push p
  let orderedPaths := syncPaths.qsort fun a b =>
    let da := (remoteM.get? a).isNone
    let db := (remoteM.get? b).isNone
    if da != db then da
    else if da then a.length > b.length
    else a.length < b.length
  for path in orderedPaths do
    if !(st.conflicts.any (fun (cp, _) => cp == path)) then
      let desired? := remoteM.get? path
      let base? := st.baseline.get? path
      let existing? := curM.get? path
      if !(st.initialized && !ContextEntry.sameContent existing? base?) then
        let mut expectedBase? := existing?.map (·.revision)
        if let (some exE, some desE) := (existing?, desired?) then
          if exE.directory != desE.directory then
            let delId ← newUuidV4
            let _ ← applyLocalOperation filesDir stateDir {
              id := delId, path := path, base? := expectedBase?, delete := true, source := "sync"
            }
            expectedBase? := none
        if !ContextEntry.sameContent existing? desired? then
          let isLarge := desired?.map (fun e => decide (e.size > contextFileLimit.toUInt64)) |>.getD false
          if let some dHash := desired?.bind (·.hash?) then
            let blobBytes ← match ← contextHttpRequest endpoint token project "GET" s!"blobs/{dHash}" ByteArray.empty false (64 * 1024 * 1024) with
              | .ok b => pure b
              | .error e => return .error e
            let storedHash ← match ← storePutBlob stateDir blobBytes isLarge with
              | .ok h => pure h
              | .error e => return .error e
            if storedHash.toLower != dHash.toLower then
              return .error "Context checksum mismatch"
          let apId ← newUuidV4
          let conflict ← match ← applyLocalOperation filesDir stateDir {
            id := apId
            path := path
            base? := expectedBase?
            hash? := desired?.bind (·.hash?)
            directory := desired?.map (·.directory) |>.getD false
            delete := desired?.isNone
            source := "sync"
            confirmedLarge := isLarge
          } with
            | .ok c => pure c
            | .error e => return .error e
          if !conflict then
            match desired? with
            | some de => st := { st with baseline := st.baseline.upsert path de }
            | none => st := { st with baseline := st.baseline.erase path }
            let _ ← saveReplicaState stateDir st
        else
          match desired? with
          | some de => st := { st with baseline := st.baseline.upsert path de }
          | none => st := { st with baseline := st.baseline.erase path }
          let _ ← saveReplicaState stateDir st
  let readyState : ReplicaState := {
    st with
    baseline := { st.baseline with revision := remoteM.revision }
    initialized := true
    ready := true
    error? := none
  }
  if let .error e ← saveReplicaState stateDir readyState then
    return .error e
  return .ok readyState

/-- Run one exclusive-flock replica sync pass (`Replica::tick`). -/
def tickProjectReplica
    (filesDir stateDir : System.FilePath) (endpoint token project : String) :
    IO (Except String ReplicaState) := do
  if let .error e ← ensurePrivateDir0700 stateDir then
    return .error e
  let lockFd ← flockExclusiveNb (stateDir / "sync.lock").toString
  if lockFd == 0xFFFFFFFF then
    let st ← loadReplicaState stateDir
    return .ok st
  let lockFdI32 : Int32 := Int32.ofBitVec (BitVec.ofNat 32 lockFd.toNat)
  try
    let st0 ← loadReplicaState stateDir
    match ← synchronizeReplicaInner filesDir stateDir endpoint token project st0 with
    | .ok st' => return .ok st'
    | .error errMsg =>
      let latest ← loadReplicaState stateDir
      let errSt := { latest with error? := some errMsg }
      let _ ← saveReplicaState stateDir errSt
      return .ok errSt
  finally
    closeFdRaw lockFdI32

/-- `POST /project-context/prepare` (`src/node/project_context.rs::prepare`). -/
def prepareNodeProjectContext (workDir : String) (jv : JVal) : IO (Except String JVal) := do
  let endpoint := ((jv.fieldStr? "endpoint").getD "").trimAscii.toString
  let token := (jv.fieldStr? "token").getD ""
  let project := ((jv.fieldStr? "project").getD "").trimAscii.toString
  if endpoint.isEmpty then
    return .error "missing endpoint"
  if let .error e := validContextPath project then
    return .error e
  if project.contains '/' then
    return .error "invalid project"
  let key := bytesToHexLower (sha256Bytes endpoint.toUTF8)
  let base := System.FilePath.mk workDir / "project-context" / key / project
  let filesDir := base / "files"
  let stateDir := base / "state"
  let st ← match ← tickProjectReplica filesDir stateDir endpoint token project with
    | .ok s => pure s
    | .error e => return .error e
  if !st.ready || st.error?.isSome then
    return .error (st.error?.getD "context replica is not ready")
  let connDoc := renderCompact (.obj #[
    ("endpoint", .str endpoint),
    ("token", .str token),
    ("project", .str project)
  ])
  if let .error e ← writeAtomicPrivate0600 (stateDir / "connection.json") connDoc.toUTF8 then
    return .error e
  let manifest ← match ← reconcileLocalStore filesDir stateDir with
    | .ok m => pure m
    | .error e => return .error e
  return .ok (.obj #[
    ("root", .str filesDir.toString),
    ("manifest", manifest.toJson)
  ])

/-- Background 2-second replica refresh loop (`src/node/project_context.rs::start`).
    Runs on `Task.Priority.dedicated` so its `IO.sleep` / socket I/O never starves
    Lean's default worker pool on 1-2 vCPU hosts (`LEAN_NUM_THREADS=1`). -/
def startProjectContextDaemon (workDir : String) (stopRef : IO.Ref Bool) : IO (Task (Except IO.Error Unit)) :=
  IO.asTask (prio := Task.Priority.dedicated) do
    let root := System.FilePath.mk workDir / "project-context"
    while !(← stopRef.get) do
      if ← root.isDir then
        if let .ok servers ← root.readDir |>.toBaseIO then
          for srv in servers do
            if let .ok projects ← srv.path.readDir |>.toBaseIO then
              for proj in projects do
                let cfgPath := proj.path / "state" / "connection.json"
                if ← cfgPath.pathExists then
                  if let .ok raw ← IO.FS.readFile cfgPath |>.toBaseIO then
                    if let .ok jv := OrbBin.Json.parse raw then
                      let ep := ((jv.fieldStr? "endpoint").getD "").trimAscii.toString
                      let tok := (jv.fieldStr? "token").getD ""
                      let pr := ((jv.fieldStr? "project").getD "").trimAscii.toString
                      if !ep.isEmpty && !pr.isEmpty && !pr.contains '/' && (validContextPath pr).isOk then
                        let key := bytesToHexLower (sha256Bytes ep.toUTF8)
                        let base := root / key / pr
                        discard <| tickProjectReplica (base / "files") (base / "state") ep tok pr
      IO.sleep 2000

end OrbNode.ProjectContext
