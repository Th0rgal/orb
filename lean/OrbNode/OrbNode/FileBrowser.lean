/-
  OrbNode.FileBrowser: Confined Workspace File Browser (`shared/file_browser.rs`),
  Node FS List/Mkdir, Single & Resumable Chunk Uploads (`src/uploads.rs`), and
  Managed Auth Profile Provisioning (`src/node/managed_auth.rs`).
-/
import LeanSys.Auth
import LeanSys.Posix
import Orb.Kernel
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Posix
import OrbNode.Spec

namespace OrbNode.FileBrowser

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json

/-! ### 1. Confined Read-Only `file_browser` (`roots`, `resolve`, `search`, `list`, `read`, `download`) -/

def isDeniedBrowserSegment (raw : String) : Bool :=
  let n := raw.toLower
  n == ".env" || n.startsWith ".env." ||
  n == ".ssh" || n == ".aws" || n == ".gnupg" || n == ".git" ||
  n == "credentials.json" || n == ".credentials.json" || n == "auth.json" ||
  n == "id_rsa" || n == "id_ed25519" || n == ".git-credentials" ||
  n.endsWith ".pem" || n.endsWith ".key"

def resolveBrowserPath (root : System.FilePath) (raw : String) : IO (Except String (System.FilePath × List String)) := do
  let rst ← statPath root.toString
  if !rst.exists_ || rst.isSymlink || !rst.isDir then
    return .error "File source is unavailable"
  let rootStr := stripTrailingSlash root.toString
  let relRaw ←
    if raw.startsWith "/" then
      let rClean := stripTrailingSlash raw
      if rClean == rootStr then pure ""
      else if rClean.startsWith (rootStr ++ "/") then
        pure (rClean.drop (rootStr.length + 1)).toString
      else
        return .error "File is outside this source"
    else
      pure raw
  let segs := (relRaw.splitOn "/").filter (fun s => !s.isEmpty && s != ".")
  if relRaw.contains '\\' || segs.any (fun s => s == ".." || isDeniedBrowserSegment s) then
    return .error "File is not available in this source"
  let mut cur := root
  for seg in segs do
    cur := cur / seg
    let st ← statPath cur.toString
    if !st.exists_ then return .error "File is unavailable"
    if st.isSymlink then return .error "Symbolic links are not exposed"
  return .ok (cur, segs)

private def browserEntry? (full : System.FilePath) (relSegs : List String) : IO (Option JVal) := do
  if relSegs.isEmpty || relSegs.any isDeniedBrowserSegment then return none
  let st ← statPath full.toString
  if !st.exists_ || st.isSymlink || (!st.isDir && !st.isReg) then return none
  let sz ← if st.isDir then pure 0 else
    match ← full.metadata |>.toBaseIO with
    | .ok md => pure md.byteSize
    | .error _ => pure 0
  let mtime ← match ← full.metadata |>.toBaseIO with
    | .ok md => pure md.modified.sec
    | .error _ => pure 0
  let name := relSegs.getLast!
  let relStr := String.intercalate "/" relSegs
  return some (.obj #[
    ("name", .str name),
    ("path", .str relStr),
    ("kind", .str (if st.isDir then "dir" else "file")),
    ("size", JVal.uint64 sz),
    ("modified", JVal.int mtime)
  ])

private def scanBrowser (root : System.FilePath) (query : String) (limit : Nat) : IO (Array JVal × Bool) := do
  let qLower := query.toLower
  let mut pending : Array (System.FilePath × List String) := #[(root, [])]
  let mut out : Array JVal := #[]
  let mut visited : Nat := 0
  while !pending.isEmpty do
    let (dir, relPfx) := pending.back!
    pending := pending.pop
    if let .ok entries ← dir.readDir |>.toBaseIO then
      for e in entries do
        visited := visited + 1
        if visited > 20000 || out.size >= limit then
          return (out, true)
        let childSegs := relPfx ++ [e.fileName]
        if let some item ← browserEntry? e.path childSegs then
          if item.fieldStr? "kind" == some "dir" then
            if !(["node_modules", "target", ".lake", ".cache"].contains e.fileName) then
              pending := pending.push (e.path, childSegs)
          else
            let pLower := (item.fieldStr? "path" |>.getD "").toLower
            if qLower.isEmpty || (pLower.splitOn qLower).length > 1 then
              out := out.push item
  let sorted := out.qsort fun a b =>
    (a.fieldStr? "path" |>.getD "") < (b.fieldStr? "path" |>.getD "")
  return (sorted, false)

def executeFileBrowser (rootDir : String) (reqJson : JVal) : IO (Except String JVal) := do
  let root := System.FilePath.mk rootDir
  let rst ← statPath root.toString
  if !rst.exists_ || rst.isSymlink || !rst.isDir then
    return .error "File source is unavailable"
  let action := (reqJson.fieldStr? "action").getD ""
  let path := (reqJson.fieldStr? "path").getD ""
  let query := (reqJson.fieldStr? "query").getD ""
  let offset := (reqJson.fieldUInt64? "offset").getD 0
  let paths := ((reqJson.fieldArr? "paths").getD #[]).filterMap JVal.asStr?
  match action with
  | "roots" =>
    return .ok (.obj #[("path", .str root.toString)])
  | "resolve" =>
    if paths.size > 64 then return .error "Too many references"
    let mut index? : Option (Array JVal) := none
    let mut results : Array JVal := #[]
    for p in paths do
      let mut matchesArr : Array JVal := #[]
      match ← resolveBrowserPath root p with
      | .ok (full, segs) =>
        if let some ent ← browserEntry? full segs then
          if ent.fieldStr? "kind" == some "file" then
            matchesArr := #[ent]
      | .error _ => pure ()
      if matchesArr.isEmpty && !p.startsWith "/" && !(p.splitOn "..").tail.isEmpty == false &&
         !(p.splitOn "/").any isDeniedBrowserSegment then
        let idx ← match index? with
          | some xs => pure xs
          | none =>
            let (xs, _) ← scanBrowser root "" 20000
            index? := some xs
            pure xs
        matchesArr := idx.filter fun e =>
          let sp := e.fieldStr? "path" |>.getD ""
          sp == p || sp.endsWith ("/" ++ p)
      results := results.push (.obj #[("reference", .str p), ("matches", .arr matchesArr)])
    return .ok (.obj #[("results", .arr results)])
  | "search" =>
    let (entries, trunc) ← scanBrowser root query 200
    return .ok (.obj #[("entries", .arr entries), ("truncated", .bool trunc)])
  | "list" =>
    match ← resolveBrowserPath root path with
    | .error e => return .error e
    | .ok (dir, relSegs) =>
      let .ok rawEntries ← dir.readDir |>.toBaseIO
        | return .error "Directory is unavailable"
      let mut items : Array JVal := #[]
      let mut trunc := false
      for e in rawEntries do
        if let some item ← browserEntry? e.path (relSegs ++ [e.fileName]) then
          items := items.push item
          if items.size > 1000 then
            trunc := true
            break
      let sorted := items.qsort fun a b =>
        let ka := a.fieldStr? "kind" == some "dir"
        let kb := b.fieldStr? "kind" == some "dir"
        if ka != kb then ka
        else (a.fieldStr? "name" |>.getD "").toLower < (b.fieldStr? "name" |>.getD "").toLower
      let finalItems := if sorted.size > 1000 then sorted.extract 0 1000 else sorted
      return .ok (.obj #[("entries", .arr finalItems), ("truncated", .bool trunc)])
  | "read" | "download" =>
    match ← resolveBrowserPath root path with
    | .error e => return .error e
    | .ok (full, _) =>
      let st ← statPath full.toString
      if !st.isReg || st.isSymlink then return .error "Not a regular file"
      let (total, clampedOff, slice) ← match ← LeanSys.Posix.withFd full.toString 0 (fun fd => do
        let fileSz ← match ← LeanSys.Posix.fstatSize fd with
          | .ok sz => pure sz
          | .error e => return .error e
        let cOff : UInt64 := min fileSz offset
        let remBytes : UInt64 := fileSz - cOff
        let wantLen : Nat := (min 1048576 remBytes).toNat
        let b ← if wantLen == 0 then pure ByteArray.empty
                 else LeanSys.Posix.preadByteArray fd cOff wantLen
        return .ok (fileSz, cOff, b)
      ) with
      | .ok tup => pure tup
      | .error _ => return .error "Cannot read file"
      let nextOff : UInt64 := clampedOff + slice.size.toUInt64
      if action == "download" then
        let mut byteVals : Array JVal := Array.mkEmpty slice.size
        for i in [0 : slice.size] do
          byteVals := byteVals.push (JVal.nat (slice.get! i).toNat)
        return .ok (.obj #[
          ("bytes", .arr byteVals),
          ("next", JVal.uint64 nextOff),
          ("size", JVal.uint64 total)
        ])
      let mut hasNul := false
      for i in [0 : slice.size] do
        if slice.get! i == 0 then hasNul := true; break
      let mtime ← match ← full.metadata |>.toBaseIO with
        | .ok md => pure md.modified.sec
        | .error _ => pure 0
      let contentVal : JVal :=
        if hasNul then .null
        else .str (String.fromUTF8? slice |>.getD (String.fromUTF8! (slice.foldl (fun acc b =>
          if b < 128 then acc.push b else acc.push 63) ByteArray.empty)))
      return .ok (.obj #[
        ("content", contentVal),
        ("binary", .bool hasNul),
        ("size", JVal.uint64 total),
        ("truncated", .bool (nextOff < total)),
        ("modified", JVal.int mtime)
      ])
  | _ => return .error "Unknown file operation"

/-! ### 2. Node FS List & Mkdir (`GET /fs/list`, `POST /fs/mkdir`) -/

def resolveNodeFsPath (workDir raw : String) : System.FilePath :=
  let t := raw.trimAscii.toString
  if t.isEmpty || t == "." then System.FilePath.mk workDir
  else if t.startsWith "/" then System.FilePath.mk t
  else System.FilePath.mk workDir / t

def listNodeFsDir (workDir raw : String) : IO (Except String JVal) := do
  let target := resolveNodeFsPath workDir raw
  let .ok entries ← target.readDir |>.toBaseIO
    | return .error s!"Cannot read directory '{target}'"
  let mut out : Array JVal := #[]
  for e in entries do
    let st ← statPath e.path.toString
    if st.exists_ then
      let kind :=
        if st.isSymlink then "link"
        else if st.isDir then "dir"
        else if st.isReg then "file"
        else "other"
      let (sz, mtime) ←
        if st.isSymlink || st.isDir then pure (0, 0)
        else match ← e.path.metadata |>.toBaseIO with
          | .ok md => pure (md.byteSize, md.modified.sec)
          | .error _ => pure (0, 0)
      out := out.push (.obj #[
        ("name", .str e.fileName),
        ("path", .str e.path.toString),
        ("kind", .str kind),
        ("size", JVal.uint64 sz),
        ("mtime", JVal.int mtime)
      ])
  return .ok (.arr out)

/-! ### 3. Bounded Single & Resumable Chunk Uploads (`src/uploads.rs`) -/

def maxSingleUploadBytes : Nat := 20 * 1024 * 1024
def maxResumableBytes : UInt64 := 2 * 1024 * 1024 * 1024
def defaultChunkBytes : Nat := 4 * 1024 * 1024
def maxChunkBytes : Nat := 16 * 1024 * 1024

def validateUploadName (name : String) : Except String Unit := do
  if name.isEmpty || name.utf8ByteSize > 240 || name == "." || name == ".." ||
     name.contains '/' || name.contains '\\' || name.any (fun c => c.toNat < 32 || c.toNat == 127) then
    throw "Choose a file with a plain filename (up to 240 bytes)"

def validateRelativeUploadPath (rel : String) : Except String String := do
  let parts := rel.splitOn "/"
  if rel.isEmpty || rel.utf8ByteSize > 1024 || parts.length > 32 || rel.contains ':' then
    throw "Choose a folder with shorter, plain paths"
  for p in parts do
    validateUploadName p
  return rel

def validateUploadId (uid : String) : Except String Unit := do
  if uid.isEmpty || uid.length > 128 || !uid.all (fun c => c.isAlphanum || c == '-' || c == '_') then
    throw "Invalid upload session ID"

private def batchTokenDigest (tok : String) : Except String String := do
  if tok.length < 32 || tok.length > 128 || !tok.all (fun c => c.isAlphanum || c == '-') then
    throw "Invalid folder upload token"
  return bytesToHexLower (sha256Bytes tok.toUTF8)

private def claimUploadBatch (uploadsRoot : System.FilePath) (batchUuid digest : String) : IO (Except String Unit) := do
  let owners := uploadsRoot / ".batches"
  IO.FS.createDirAll owners
  let ost ← statPath owners.toString
  if !ost.exists_ || ost.isSymlink || !ost.isDir then
    return .error "Invalid folder upload batch directory"
  let lockPath := (owners / ".claim.lock").toString
  match ← LeanSys.Posix.withDirLock lockPath false fun _ => do
    let ownerFile := owners / batchUuid
    if ← ownerFile.pathExists then
      let .ok stored ← IO.FS.readFile ownerFile |>.toBaseIO
        | return .ok (.error "This folder upload belongs to someone else")
      if !ctEqString stored.trimAscii.toString digest then
        return .ok (.error "This folder upload belongs to someone else")
      return .ok (.ok ())
    else
      let pid ← OrbBin.PosixExt.getpid
      let nonce ← newUuidV4
      let tmp := owners / s!".{batchUuid}.tmp.{pid}.{nonce}"
      match ← LeanSys.Posix.withFd tmp.toString 1 (fun fd => LeanSys.Posix.writeAll fd digest.toUTF8 true) (exclusive := 2) with
      | .error _ =>
        try IO.FS.removeFile tmp catch _ => pure ()
        return .ok (.error "Record batch owner failed")
      | .ok (_ : Nat) => pure ()
      match ← LeanSys.Posix.atomicRename tmp.toString ownerFile.toString with
      | .error _ =>
        try IO.FS.removeFile tmp catch _ => pure ()
        return .ok (.error "Record batch owner failed")
      | .ok () => return .ok (.ok ())
  with
  | .ok inner => return inner
  | .error _ => return .error "Batch claim lock failed"

private def resolveUploadDest
    (uploadsRoot : System.FilePath) (name : String)
    (batchId? relPath? digest? : Option String) : IO (Except String System.FilePath) := do
  IO.FS.createDirAll uploadsRoot
  match batchId?, relPath? with
  | none, none =>
    let uid ← newUuidV4
    let dir := uploadsRoot / uid
    IO.FS.createDirAll dir
    return .ok (dir / name)
  | some rawBatch, some rawRel =>
    let some batch := parseUuidCanonical? rawBatch
      | return .error "Invalid folder upload ID"
    let rel ← match validateRelativeUploadPath rawRel with
      | .ok r => pure r
      | .error e => return .error e
    let some dig := digest?
      | return .error "Folder uploads need a batch token"
    if let .error e ← claimUploadBatch uploadsRoot batch dig then
      return .error e
    let dest := uploadsRoot / batch / rel
    if let some par := dest.parent then
      IO.FS.createDirAll par
      let pst ← statPath par.toString
      if pst.isSymlink then return .error "Invalid folder path"
    return .ok dest
  | _, _ => return .error "Folder uploads need both batch_id and relative_path"

def storeSingleUpload (workDir : String) (jv : JVal) : IO (Except String JVal) := do
  let some name := jv.fieldStr? "name" | return .error "missing name"
  let some b64 := jv.fieldStr? "data_base64" | return .error "missing data_base64"
  if let .error e := validateUploadName name then return .error e
  if b64.utf8ByteSize > ((maxSingleUploadBytes + 2) / 3) * 4 + 64 then
    return .error "Files must be 20 MiB or smaller"
  let some bytes := base64Decode? b64
    | return .error "Invalid file encoding"
  if bytes.size > maxSingleUploadBytes then
    return .error "Files must be 20 MiB or smaller"
  let batchId? := jv.fieldStr? "batch_id"
  let relPath? := jv.fieldStr? "relative_path"
  let digest? ← match jv.fieldStr? "batch_token" with
    | some bt =>
      match batchTokenDigest bt with
      | .ok d => pure (some d)
      | .error e => return .error e
    | none => pure none
  let uploadsRoot := System.FilePath.mk workDir / "uploads"
  IO.FS.createDirAll uploadsRoot
  let urst ← statPath uploadsRoot.toString
  if !urst.exists_ || urst.isSymlink || !urst.isDir then
    return .error "Invalid uploads root"
  match ← LeanSys.Posix.withDirLock (uploadsRoot / ".dest-claim.lock").toString false fun _ => do
    let dest ← match ← resolveUploadDest uploadsRoot name batchId? relPath? digest? with
      | .ok d => pure d
      | .error e => return .ok (.error e)
    let mut conflict := ← dest.pathExists
    if !conflict then
      let destStr := dest.toString
      if let .ok entries ← (uploadsRoot / ".sessions").readDir |>.toBaseIO then
        for e in entries do
          if let .ok raw ← IO.FS.readFile (e.path / "meta.json") |>.toBaseIO then
            if let .ok other := OrbBin.Json.parse raw then
              if let some rec := other.field? "receipt" then
                if rec != JVal.null && rec.fieldStr? "path" == some destStr then
                  conflict := true
              if (other.fieldStr? "dest_path").getD "" == destStr then
                conflict := true
    if conflict then
      return .ok (.error "A file with this path was already uploaded")
    let pid ← OrbBin.PosixExt.getpid
    let nonce ← newUuidV4
    let tmp := System.FilePath.mk (s!"{dest.toString}.tmp.{pid}.{nonce}")
    match ← LeanSys.Posix.withFd tmp.toString 1 (fun fd => LeanSys.Posix.writeAll fd bytes true) (exclusive := 2) with
    | .error _ =>
      try IO.FS.removeFile tmp catch _ => pure ()
      return .ok (.error "Write uploaded file failed")
    | .ok (_ : Nat) => pure ()
    match ← LeanSys.Posix.atomicRename tmp.toString dest.toString with
    | .error _ =>
      try IO.FS.removeFile tmp catch _ => pure ()
      return .ok (.error "Commit uploaded file failed")
    | .ok () => pure ()
    if let some parent := dest.parent then
      let _ ← LeanSys.Posix.withFd parent.toString 0 (fun fd => LeanSys.Posix.writeAll fd ByteArray.empty true)
    let sha := bytesToHexLower (sha256Bytes bytes)
    return .ok (.ok (.obj #[
      ("name", .str name),
      ("path", .str dest.toString),
      ("size", JVal.nat bytes.size),
      ("sha256", .str sha)
    ]))
  with
  | .ok inner => return inner
  | .error _ => return .error "upload destination claim lock failed"

private def liftSys {α : Type} (r : LeanSys.Posix.SysResult α) (msg : String) : Except String α :=
  match r with
  | .ok v => .ok v
  | .error _ => .error msg

private def writeFileDurableAtomic (dst : System.FilePath) (bytes : ByteArray) : IO (Except String Unit) := do
  let some parent := dst.parent | return .error "missing parent directory"
  IO.FS.createDirAll parent
  let pst ← statPath parent.toString
  if !pst.exists_ || pst.isSymlink || !pst.isDir then
    return .error "parent is not a directory"
  let pid ← OrbBin.PosixExt.getpid
  let nonce ← newUuidV4
  let tmp := System.FilePath.mk (s!"{dst.toString}.tmp.{pid}.{nonce}")
  match liftSys (← LeanSys.Posix.withFd tmp.toString 1 (fun fd => LeanSys.Posix.writeAll fd bytes true) (exclusive := 2)) "durable write failed" with
  | .error e =>
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error e
  | .ok (_ : Nat) => pure ()
  match liftSys (← LeanSys.Posix.atomicRename tmp.toString dst.toString) "atomic rename failed" with
  | .error e =>
    try IO.FS.removeFile tmp catch _ => pure ()
    return .error e
  | .ok () => pure ()
  match liftSys (← LeanSys.Posix.withFd parent.toString 0 (fun fd => LeanSys.Posix.writeAll fd ByteArray.empty true)) "parent fsync failed" with
  | .error e => return .error e
  | .ok (_ : Nat) => return .ok ()

private def destBytesMatch (dest : System.FilePath) (size : UInt64) (sha : String) : IO Bool := do
  let st ← statPath dest.toString
  if !st.exists_ || st.isSymlink || !st.isReg then
    return false
  let .ok bytes ← IO.FS.readBinFile dest |>.toBaseIO | return false
  return bytes.size.toUInt64 == size && bytesToHexLower (sha256Bytes bytes) == sha

private def verifyCompletedReceipt (rec : JVal) (expectedSize : UInt64) : IO Bool := do
  let some pathStr := rec.fieldStr? "path" | return false
  let some recSize := rec.fieldUInt64? "size" | return false
  let some recSha := rec.fieldStr? "sha256" | return false
  if pathStr.isEmpty || recSize != expectedSize then
    return false
  destBytesMatch (System.FilePath.mk pathStr) expectedSize recSha

def initOrStatusUploadSession (workDir : String) (jv : JVal) : IO (Except String JVal) := do
  let some uid := jv.fieldStr? "upload_id" | return .error "missing upload_id"
  let some name := jv.fieldStr? "name" | return .error "missing name"
  let some size := jv.fieldUInt64? "size" | return .error "missing size"
  if let .error e := validateUploadId uid then return .error e
  if let .error e := validateUploadName name then return .error e
  if size > maxResumableBytes then return .error "Files must be 2 GiB or smaller"
  let chunkSize := (jv.fieldNat? "chunk_size").getD defaultChunkBytes
  if chunkSize == 0 || chunkSize > maxChunkBytes then return .error "Invalid upload chunk size"
  let totalChunks := if size == 0 then 1 else (size.toNat + chunkSize - 1) / chunkSize
  let batchId? := jv.fieldStr? "batch_id"
  let relPath? := jv.fieldStr? "relative_path"
  let digest? ← match jv.fieldStr? "batch_token" with
    | some bt =>
      match batchTokenDigest bt with
      | .ok d => pure (some d)
      | .error e => return .error e
    | none => pure none
  let uploadsRoot := System.FilePath.mk workDir / "uploads"
  if let (some rb, some rr) := (batchId?, relPath?) then
    let some batch := parseUuidCanonical? rb | return .error "Invalid folder upload ID"
    if let .error e := validateRelativeUploadPath rr then return .error e
    let some dig := digest? | return .error "Folder uploads need a batch token"
    if let .error e ← claimUploadBatch uploadsRoot batch dig then return .error e
  let sessDir := uploadsRoot / ".sessions" / uid
  IO.FS.createDirAll sessDir
  let sdst ← statPath sessDir.toString
  if !sdst.exists_ || sdst.isSymlink || !sdst.isDir then
    return .error "Invalid upload session directory"
  let metaPath := sessDir / "meta.json"
  match ← LeanSys.Posix.withDirLock (sessDir / "finalize.lock").toString false fun _ => do
    if ← metaPath.pathExists then
      let .ok raw ← IO.FS.readFile metaPath |>.toBaseIO
        | return .ok (.error "Read session metadata failed")
      let .ok ex := OrbBin.Json.parse raw
        | return .ok (.error "Parse session metadata failed")
      if ex.fieldStr? "name" != some name || ex.fieldUInt64? "size" != some size ||
         ex.fieldNat? "chunk_size" != some chunkSize ||
         ex.fieldStr? "batch_id" != batchId? || ex.fieldStr? "relative_path" != relPath? ||
         ex.fieldStr? "batch_token_digest" != digest? then
        return .ok (.error "Upload session parameters do not match existing session")
      if let some rec := ex.field? "receipt" then
        if rec != .null then
          if !(← verifyCompletedReceipt rec size) then
            return .ok (.error "Finalized upload artifact missing or corrupted")
          let mut allIdx : Array JVal := #[]
          for i in [0 : totalChunks] do allIdx := allIdx.push (JVal.nat i)
          return .ok (.ok (.obj #[
            ("upload_id", .str uid), ("name", .str name), ("size", JVal.uint64 size),
            ("chunk_size", JVal.nat chunkSize), ("total_chunks", JVal.nat totalChunks),
            ("received_chunks", .arr allIdx), ("receipt", rec)
          ]))
      if ex.fieldStr? "status" == some "completed" then
        return .ok (.error "Finalized upload artifact missing or corrupted")
      IO.FS.createDirAll (sessDir / "chunks")
      let mut recvd : Array Nat := #[]
      if let .ok cEntries ← (sessDir / "chunks").readDir |>.toBaseIO then
        for ce in cEntries do
          if let some idx := ce.fileName.toNat? then
            if idx < totalChunks then recvd := recvd.push idx
      let sorted := (recvd.qsort (· < ·)).map JVal.nat
      return .ok (.ok (.obj #[
        ("upload_id", .str uid), ("name", .str name), ("size", JVal.uint64 size),
        ("chunk_size", JVal.nat chunkSize), ("total_chunks", JVal.nat totalChunks),
        ("received_chunks", .arr sorted)
      ]))
    IO.FS.createDirAll (sessDir / "chunks")
    let mut metaFields : Array (String × JVal) := #[
      ("upload_id", .str uid), ("name", .str name), ("size", JVal.uint64 size),
      ("chunk_size", JVal.nat chunkSize), ("total_chunks", JVal.nat totalChunks),
      ("status", .str "staging")
    ]
    if let some b := batchId? then metaFields := metaFields.push ("batch_id", .str b)
    if let some r := relPath? then metaFields := metaFields.push ("relative_path", .str r)
    if let some d := digest? then metaFields := metaFields.push ("batch_token_digest", .str d)
    if batchId?.isNone then
      let destUid ← newUuidV4
      metaFields := metaFields.push ("dest_uid", .str destUid)
    match ← writeFileDurableAtomic metaPath (renderCompact (.obj metaFields)).toUTF8 with
    | .ok () => pure ()
    | .error e => return .ok (.error e)
    return .ok (.ok (.obj #[
      ("upload_id", .str uid), ("name", .str name), ("size", JVal.uint64 size),
      ("chunk_size", JVal.nat chunkSize), ("total_chunks", JVal.nat totalChunks),
      ("received_chunks", .arr #[])
    ]))
  with
  | .ok inner => return inner
  | .error _ => return .error "upload session lock failed"

def writeUploadSessionChunk (workDir uid : String) (index : Nat) (bytes : ByteArray) : IO (Except String JVal) := do
  if let .error e := validateUploadId uid then return .error e
  let sessDir := System.FilePath.mk workDir / "uploads" / ".sessions" / uid
  let metaPath := sessDir / "meta.json"
  if !(← metaPath.pathExists) then
    return .error "Upload session not found; reinitialize the upload"
  let sdst ← statPath sessDir.toString
  if !sdst.exists_ || sdst.isSymlink || !sdst.isDir then
    return .error "Invalid upload session directory"
  match ← LeanSys.Posix.withDirLock (sessDir / "finalize.lock").toString false fun _ => do
    if !(← metaPath.pathExists) then
      return .ok (.error "Upload session not found; reinitialize the upload")
    let .ok raw ← IO.FS.readFile metaPath |>.toBaseIO
      | return .ok (.error "Read session metadata failed")
    let .ok metaJv := OrbBin.Json.parse raw
      | return .ok (.error "Invalid session metadata")
    let name := (metaJv.fieldStr? "name").getD ""
    let size := (metaJv.fieldUInt64? "size").getD 0
    let chunkSize := (metaJv.fieldNat? "chunk_size").getD defaultChunkBytes
    let totalChunks := (metaJv.fieldNat? "total_chunks").getD 1
    if let some rec := metaJv.field? "receipt" then
      if rec != .null then
        return .ok (.error "Upload session is already finalized")
    if metaJv.fieldStr? "status" == some "completed" then
      return .ok (.error "Upload session is already finalized")
    if index >= totalChunks then return .ok (.error "Chunk index out of bounds")
    let offset := index * chunkSize
    let expectedLen :=
      if size == 0 then 0
      else if index + 1 == totalChunks then size.toNat - offset
      else chunkSize
    if bytes.size != expectedLen then
      return .ok (.error s!"Chunk {index} size mismatch: expected {expectedLen} bytes, got {bytes.size}")
    let chunksDir := sessDir / "chunks"
    IO.FS.createDirAll chunksDir
    let cdst ← statPath chunksDir.toString
    if !cdst.exists_ || cdst.isSymlink || !cdst.isDir then
      return .ok (.error "Invalid upload chunks directory")
    let chunkPath := chunksDir / toString index
    let pid ← OrbBin.PosixExt.getpid
    let nonce ← newUuidV4
    let tmp := System.FilePath.mk (s!"{chunkPath.toString}.tmp.{pid}.{nonce}")
    match ← LeanSys.Posix.withFd tmp.toString 1 (fun fd => LeanSys.Posix.writeAll fd bytes true) (exclusive := 2) with
    | .error _ =>
      try IO.FS.removeFile tmp catch _ => pure ()
      return .ok (.error "Write chunk failed")
    | .ok (_ : Nat) => pure ()
    match ← LeanSys.Posix.atomicRename tmp.toString chunkPath.toString with
    | .error _ =>
      try IO.FS.removeFile tmp catch _ => pure ()
      return .ok (.error "Commit chunk failed")
    | .ok () => pure ()
    let mut recvd : Array Nat := #[]
    if let .ok cEntries ← (sessDir / "chunks").readDir |>.toBaseIO then
      for ce in cEntries do
        if let some idx := ce.fileName.toNat? then
          if idx < totalChunks then recvd := recvd.push idx
    let sorted := (recvd.qsort (· < ·)).map JVal.nat
    return .ok (.ok (.obj #[
      ("upload_id", .str uid), ("name", .str name), ("size", JVal.uint64 size),
      ("chunk_size", JVal.nat chunkSize), ("total_chunks", JVal.nat totalChunks),
      ("received_chunks", .arr sorted)
    ]))
  with
  | .ok inner => return inner
  | .error _ => return .error "upload session lock failed"

private def readUploadMeta (metaPath : System.FilePath) : IO (Except String JVal) := do
  if !(← metaPath.pathExists) then
    return .error "Upload session not found; reinitialize the upload"
  let .ok raw ← IO.FS.readFile metaPath |>.toBaseIO | return .error "Read session metadata failed"
  match OrbBin.Json.parse raw with
  | .ok jv => return .ok jv
  | .error _ => return .error "Invalid session metadata"

private def completedReceipt? (metaJv : JVal) : Option JVal :=
  match metaJv.field? "receipt" with
  | some rec => if rec == .null then none else some rec
  | none => none

private def receiptMatchesDest (rec : JVal) (dest : System.FilePath) (size : UInt64) (sha : String) : Bool :=
  rec.fieldStr? "path" == some dest.toString &&
  rec.fieldUInt64? "size" == some size &&
  rec.fieldStr? "sha256" == some sha

private def unlinkUploadChunks (sessDir : System.FilePath) : IO Unit := do
  let chunks := sessDir / "chunks"
  if let .ok entries ← chunks.readDir |>.toBaseIO then
    for e in entries do
      try IO.FS.removeFile e.path catch _ => pure ()
  try IO.FS.removeDir chunks catch _ => pure ()

private def removeSessionContents (sessDir : System.FilePath) : IO Unit := do
  if let .ok entries ← sessDir.readDir |>.toBaseIO then
    for e in entries do
      if e.fileName != "finalize.lock" then
        try IO.FS.removeFile e.path catch _ => pure ()
        try IO.FS.removeDirAll e.path catch _ => pure ()

private def sessionOwnsDest (uploadsRoot : System.FilePath) (uid : String) (metaJv : JVal) (dest : System.FilePath) : IO Bool := do
  let destStr := dest.toString
  let sessRoot := uploadsRoot / ".sessions"
  if let .ok entries ← sessRoot.readDir |>.toBaseIO then
    for e in entries do
      if e.fileName != uid then
        if let .ok raw ← IO.FS.readFile (e.path / "meta.json") |>.toBaseIO then
          if let .ok other := OrbBin.Json.parse raw then
            if let some rec := completedReceipt? other then
              if rec.fieldStr? "path" == some destStr then
                return false
            if (other.fieldStr? "dest_path").getD "" == destStr then
              return false
  if (metaJv.fieldStr? "dest_path").getD "" == destStr then
    return true
  if ← dest.pathExists then
    return (metaJv.fieldStr? "batch_id").isNone && (metaJv.fieldStr? "dest_uid").isSome
  return true

private def resolveSessionDest
    (uploadsRoot sessDir : System.FilePath) (uid : String) (metaJv : JVal) :
    IO (Except String (System.FilePath × JVal)) := do
  let name := (metaJv.fieldStr? "name").getD ""
  match metaJv.fieldStr? "batch_id", metaJv.fieldStr? "relative_path" with
  | some rawBatch, some rawRel =>
    let dst ← match ← resolveUploadDest uploadsRoot name (some rawBatch) (some rawRel) (metaJv.fieldStr? "batch_token_digest") with
      | .ok d => pure d
      | .error e => return .error e
    let owned ← sessionOwnsDest uploadsRoot uid metaJv dst
    if !owned then
      return .error "A file with this path was already uploaded"
    if ← dst.pathExists then
      return .ok (dst, metaJv)
    let fields := (metaJv.asObj?.getD #[]).filter (fun kv => kv.1 != "dest_path")
    let next := JVal.obj (fields.push ("dest_path", .str dst.toString))
    match ← writeFileDurableAtomic (sessDir / "meta.json") (renderCompact next).toUTF8 with
    | .ok () => return .ok (dst, next)
    | .error e => return .error e
  | none, none =>
    let destUid ← match metaJv.fieldStr? "dest_uid" with
      | some u =>
        match parseUuidCanonical? u with
        | some c => pure c
        | none => return .error "Invalid dest_uid"
      | none => newUuidV4
    let dir := uploadsRoot / destUid
    IO.FS.createDirAll dir
    let dst := dir / name
    let owned ← sessionOwnsDest uploadsRoot uid metaJv dst
    if !owned then
      return .error "A file with this path was already uploaded"
    let fields := (metaJv.asObj?.getD #[]).filter (fun kv => kv.1 != "dest_uid" && kv.1 != "dest_path")
    let next := JVal.obj (fields.push ("dest_uid", .str destUid) |>.push ("dest_path", .str dst.toString))
    match ← writeFileDurableAtomic (sessDir / "meta.json") (renderCompact next).toUTF8 with
    | .ok () => return .ok (dst, next)
    | .error e => return .error e
  | _, _ => return .error "Folder uploads need both batch_id and relative_path"

def completeUploadSession (workDir uid : String) (crashAfterDestDurable : Bool := false) : IO (Except String JVal) := do
  if let .error e := validateUploadId uid then return .error e
  let uploadsRoot := System.FilePath.mk workDir / "uploads"
  let sessDir := uploadsRoot / ".sessions" / uid
  let metaPath := sessDir / "meta.json"
  if !(← sessDir.pathExists) || !(← metaPath.pathExists) then
    return .error "Upload session not found; reinitialize the upload"
  let sdst ← statPath sessDir.toString
  if !sdst.exists_ || sdst.isSymlink || !sdst.isDir then
    return .error "Invalid upload session directory"
  let lockPath := (sessDir / "finalize.lock").toString
  match ← LeanSys.Posix.withDirLock lockPath false fun _ => do
    if !(← metaPath.pathExists) then
      return .ok (.error "Upload session not found; reinitialize the upload")
    let .ok meta0 ← readUploadMeta metaPath | return .ok (.error "Invalid session metadata")
    let size := (meta0.fieldUInt64? "size").getD 0
    if let some rec := completedReceipt? meta0 then
      if ← verifyCompletedReceipt rec size then
        if OrbNode.Spec.verifyUploadFinalizeOrder 1 1 1 3 == 1 then
          unlinkUploadChunks sessDir
        return .ok (.ok rec)
      else
        return .ok (.error "Finalized upload artifact missing or corrupted")
    if meta0.fieldStr? "status" == some "completed" then
      return .ok (.error "Finalized upload artifact missing or corrupted")
    let name := (meta0.fieldStr? "name").getD ""
    let totalChunks := (meta0.fieldNat? "total_chunks").getD 1
    let mut assembled := ByteArray.emptyWithCapacity size.toNat
    for i in [0 : totalChunks] do
      let cf := sessDir / "chunks" / toString i
      if !(← cf.pathExists) then
        return .ok (.error s!"Upload incomplete: missing chunk {i}/{totalChunks}")
      let .ok cb ← IO.FS.readBinFile cf |>.toBaseIO
        | return .ok (.error s!"Failed reading chunk {i}")
      assembled := assembled ++ cb
    if assembled.size.toUInt64 != size then
      return .ok (.error "Staged upload size mismatch")
    let sha := bytesToHexLower (sha256Bytes assembled)
    IO.FS.createDirAll uploadsRoot
    let urst ← statPath uploadsRoot.toString
    if !urst.exists_ || urst.isSymlink || !urst.isDir then
      return .ok (.error "Invalid uploads root")
    let claimRes : LeanSys.Posix.SysResult (Except String (System.FilePath × JVal)) ←
      LeanSys.Posix.withDirLock (uploadsRoot / ".dest-claim.lock").toString false fun _ => do
        let (dest, metaJv) ← match ← resolveSessionDest uploadsRoot sessDir uid meta0 with
          | .ok pair => pure pair
          | .error e => return .ok (.error e)
        let owned ← sessionOwnsDest uploadsRoot uid metaJv dest
        if !owned then
          return .ok (.error "A file with this path was already uploaded")
        if ← dest.pathExists then
          let bytesOk ← destBytesMatch dest size sha
          if !bytesOk then
            return .ok (.error "A file with this path was already uploaded")
        else
          match ← writeFileDurableAtomic dest assembled with
          | .ok () => pure ()
          | .error e => return .ok (.error e)
        return .ok (.ok (dest, metaJv))
    let (dest, metaJv) ← match claimRes with
      | .ok (.ok pair) => pure pair
      | .ok (.error e) => return .ok (.error e)
      | .error _ => return .ok (.error "upload destination claim lock failed")
    if OrbNode.Spec.verifyUploadFinalizeOrder 1 1 0 1 != 1 then
      return .ok (.error "upload finalize gate rejected dest durability")
    if crashAfterDestDurable then
      return .ok (.error "injected_crash_after_dest_durable")
    let receipt := JVal.obj #[
      ("name", .str name),
      ("path", .str dest.toString),
      ("size", JVal.uint64 size),
      ("sha256", .str sha)
    ]
    let fields := (metaJv.asObj?.getD #[]).filter (fun kv => kv.1 != "status" && kv.1 != "receipt" && kv.1 != "dest_path")
    let completed := JVal.obj (fields.push ("dest_path", .str dest.toString) |>.push ("status", .str "completed") |>.push ("receipt", receipt))
    match ← writeFileDurableAtomic metaPath (renderCompact completed).toUTF8 with
    | .ok () => pure ()
    | .error e => return .ok (.error e)
    if OrbNode.Spec.verifyUploadFinalizeOrder 1 1 1 3 != 1 then
      return .ok (.error "upload finalize gate rejected chunk unlink")
    unlinkUploadChunks sessDir
    if receiptMatchesDest receipt dest size sha then
      return .ok (.ok receipt)
    return .ok (.error "receipt mismatch")
  with
  | .ok inner => return inner
  | .error _ => return .error "upload finalize lock failed"

def cancelUploadSession (workDir uid : String) : IO (Except String Unit) := do
  if let .error e := validateUploadId uid then return .error e
  let sessDir := System.FilePath.mk workDir / "uploads" / ".sessions" / uid
  if !(← sessDir.pathExists) then
    return .ok ()
  let sdst ← statPath sessDir.toString
  if !sdst.exists_ || sdst.isSymlink || !sdst.isDir then
    return .error "Invalid upload session directory"
  let lockPath := (sessDir / "finalize.lock").toString
  match ← LeanSys.Posix.withDirLock lockPath false fun _ => do
    if !(← (sessDir / "meta.json").pathExists) then
      removeSessionContents sessDir
      return .ok (.ok ())
    let .ok metaJv ← readUploadMeta (sessDir / "meta.json") | return .ok (.error "Invalid session metadata")
    if (completedReceipt? metaJv).isSome || metaJv.fieldStr? "status" == some "completed" then
      return .ok (.error "Upload session is already finalized")
    removeSessionContents sessDir
    return .ok (.ok ())
  with
  | .ok inner => return inner
  | .error _ => return .error "upload cancel lock failed"

/-- Content-addressed shared Library skills archive (`library-skills-<hex>.tar.gz`) uploaded once per
    content digest and reused across remote worker missions. Strictly rejects any path separators,
    `..` segments, or NUL/control bytes. -/
def isSharedLibrarySkillsArchive (fileName : String) : Bool :=
  fileName.startsWith "library-skills-" &&
  fileName.endsWith ".tar.gz" &&
  fileName.length > ("library-skills-".length + ".tar.gz".length) &&
  !fileName.contains '/' &&
  !fileName.contains '\\' &&
  (fileName.splitOn "..").tail.isEmpty &&
  fileName.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')

/-- Decide whether `<uploads>/<uid>/<fileName>` may be deleted under single-job post-run cleanup
    (`expiredForGc = false`) vs TTL sweep (`expiredForGc = true`), delegated to `Orb.Kernel.uploadCleanupGate`. -/
def shouldCleanupUploadEntry (uid fileName : String) (expiredForGc : Bool) : Bool :=
  let validUuidBit : UInt8 := if (parseUuidCanonical? uid).isSome then 1 else 0
  let sharedLibBit : UInt8 := if isSharedLibrarySkillsArchive fileName then 1 else 0
  let expiredBit   : UInt8 := if expiredForGc then 1 else 0
  Orb.Kernel.uploadCleanupGate validUuidBit sharedLibBit expiredBit == 1

/-- Sweep `<workDir>/uploads/<uid>` entries referenced by a completed job (`expiredForGc = false`) or
    periodic TTL sweep (`expiredForGc = true`), retaining shared `library-skills-*.tar.gz` bundles
    until TTL expiry so concurrent/subsequent remote missions never hit `ENOENT` on cached skill tarballs. -/
def cleanupUploadDirectories (workDir : String) (uids : Array String) (expiredForGc : Bool) : IO Nat := do
  let uploadsRoot := System.FilePath.mk workDir / "uploads"
  let mut removed : Nat := 0
  for rawUid in uids do
    if let some uid := parseUuidCanonical? rawUid then
      let dir := uploadsRoot / uid
      let st ← statPath dir.toString
      if st.exists_ && !st.isSymlink && st.isDir then
        if let .ok entries ← dir.readDir |>.toBaseIO then
          let mut keepAny := false
          for ent in entries do
            if shouldCleanupUploadEntry uid ent.fileName expiredForGc then
              try IO.FS.removeFile ent.path catch _ => pure ()
              removed := removed + 1
            else
              keepAny := true
          if !keepAny then
            try IO.FS.removeDirAll dir catch _ => pure ()
  return removed

/-- Adaptive remote-job observation poll cadence (`80 ms -> 200 ms -> 500 ms -> bounded backoff`),
    delegated to `Orb.Kernel.fastPollDelayMs`. -/
def computeFastPollDelayMs (isStopping : Bool) (elapsedMs : UInt64) (consecutiveFailures : UInt32) : UInt64 :=
  Orb.Kernel.fastPollDelayMs (if isStopping then 1 else 0) elapsedMs consecutiveFailures

/-! ### 4. Managed Auth (`grok` + `antigravity` / `antigravity:<slot>`) -/

structure ManagedAuthConfig where
  grokHome?        : Option String := none
  antigravityHome? : Option String := none
  coreSync         : Bool := true
  deriving Repr, Inhabited

def validAntigravitySlot (slot : String) : Bool :=
  1 ≤ slot.length && slot.length ≤ 32 &&
  slot.all (fun c => ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9'))

private def privateFileReadable (path : System.FilePath) : IO Bool := do
  let st ← statPath path.toString
  return st.exists_ && !st.isSymlink && st.isReg && st.ownedByEuid && (st.mode &&& 0o077) == 0

def loadManagedAuthFromEnv (workDir : String) : IO ManagedAuthConfig := do
  let grok? := (← getEnvNonEmpty "SANDBOXED_NODE_GROK_HOME").map (·.trimAscii.toString)
    |>.filter (·.startsWith "/")
  let agEnv? := (← getEnvNonEmpty "SANDBOXED_NODE_ANTIGRAVITY_HOME").map (·.trimAscii.toString)
    |>.filter (·.startsWith "/")
  let localOnly := match ← getEnvNonEmpty "SANDBOXED_NODE_ANTIGRAVITY_LOCAL_ONLY" with
    | some v => let lv := v.trimAscii.toString.toLower; lv == "1" || lv == "true" || lv == "yes"
    | none => false
  let defaultAg := (System.FilePath.mk workDir / "managed-auth" / "antigravity").toString
  let agHome? := match agEnv? with
    | some p => some p
    | none => if localOnly then none else some defaultAg
  return { grokHome? := grok?, antigravityHome? := agHome?, coreSync := !localOnly }

def advertisedManagedAuth (ma : ManagedAuthConfig) : IO (Array String) := do
  let mut ready : Array String := #[]
  if let some gh := ma.grokHome? then
    let gp := System.FilePath.mk gh
    let gst ← statPath gp.toString
    if gst.exists_ && !gst.isSymlink && gst.isDir && gst.ownedByEuid then
      if ← privateFileReadable (gp / "auth.json") then
        ready := ready.push "grok"
  if let some ah := ma.antigravityHome? then
    let ap := System.FilePath.mk ah
    if ← privateFileReadable (ap / "antigravity-oauth-token") then
      ready := ready.push "antigravity"
    let accts := ap / "accounts"
    let ast ← statPath accts.toString
    if ast.exists_ && !ast.isSymlink && ast.isDir then
      if let .ok entries ← accts.readDir |>.toBaseIO then
        let mut slots : Array String := #[]
        for e in entries do
          let est ← statPath e.path.toString
          if !est.isSymlink && est.isDir && validAntigravitySlot e.fileName then
            if ← privateFileReadable (e.path / "antigravity-oauth-token") then
              slots := slots.push s!"antigravity:{e.fileName}"
        ready := ready ++ slots.qsort (· < ·)
  return ready

def validateManagedAuthRequest (ma : ManagedAuthConfig) (profiles : Array String) : IO (Except String Unit) := do
  let mut agCount := 0
  for p in profiles do
    if p == "grok" then
      let some gh := ma.grokHome?
        | return .error "managed auth profile 'grok' is not configured on this node"
      if !(← privateFileReadable (System.FilePath.mk gh / "auth.json")) then
        return .error "managed auth profile 'grok' auth.json is missing or not private (0600)"
    else if p == "antigravity" then
      agCount := agCount + 1
      let some ah := ma.antigravityHome?
        | return .error "Antigravity profile is not configured on this node"
      if !(← privateFileReadable (System.FilePath.mk ah / "antigravity-oauth-token")) then
        return .error "Antigravity OAuth login is not provisioned on this node"
    else if p.startsWith "antigravity:" then
      agCount := agCount + 1
      let slot := (p.drop 12).toString
      if !validAntigravitySlot slot then
        return .error s!"managed auth profile '{p}' has an invalid Antigravity slot identifier"
      let some ah := ma.antigravityHome?
        | return .error s!"managed auth profile '{p}' is not provisioned on this node"
      let slotDir := System.FilePath.mk ah / "accounts" / slot
      let sst ← statPath slotDir.toString
      if sst.isSymlink || !(← privateFileReadable (slotDir / "antigravity-oauth-token")) then
        return .error s!"managed auth profile '{p}' is not provisioned on this node"
    else
      return .error s!"managed auth profile '{p}' is unknown to this node"
  if agCount > 1 then
    return .error "Only one Antigravity managed auth profile may be requested per job"
  return .ok ()

def prepareManagedAuthWorkspace
    (ma : ManagedAuthConfig) (profiles : Array String) (cwd : String) :
    IO (Except String (Array (String × String))) := do
  if let .error e ← validateManagedAuthRequest ma profiles then
    return .error e
  let mut extraEnv : Array (String × String) := #[]
  if profiles.contains "grok" then
    if let some gh := ma.grokHome? then
      extraEnv := extraEnv.push ("GROK_HOME", gh)
  if let some agProf := profiles.find? (fun p => p == "antigravity" || p.startsWith "antigravity:") then
    if let some ah := ma.antigravityHome? then
      let target :=
        if agProf.startsWith "antigravity:" then
          (System.FilePath.mk ah / "accounts" / (agProf.drop 12).toString).toString
        else ah
      let gemini := System.FilePath.mk cwd / ".gemini"
      let gst ← statPath gemini.toString
      if gst.isSymlink then return .error "Job .gemini must not be a symlink"
      IO.FS.createDirAll gemini
      let link := gemini / "antigravity-cli"
      let lst ← statPath link.toString
      if lst.exists_ && !lst.isSymlink then
        return .error "Job Antigravity home conflicts with node-managed profile"
      let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", target, link.toString] }
  return .ok extraEnv

def installAntigravityAuth
    (ma : ManagedAuthConfig) (slot? : Option String) (updateDefault : Bool) (credJson : JVal) :
    IO (Except String JVal) := do
  if !ma.coreSync || ma.antigravityHome?.isNone then
    return .error "conflict:This node keeps its own Antigravity sign-in"
  let ah := ma.antigravityHome?.getD ""
  let access := ((credJson.fieldStr? "access_token").getD "").trimAscii.toString
  let refresh := ((credJson.fieldStr? "refresh_token").getD "").trimAscii.toString
  let expiresMs := (credJson.fieldInt? "expires_at").getD 0
  if access.isEmpty || refresh.isEmpty then
    return .error "bad_request:Antigravity credential is incomplete"
  let cleanSlot? := slot?.map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  if let some sl := cleanSlot? then
    if !validAntigravitySlot sl then
      return .error "bad_request:Invalid Antigravity slot identifier"
  let expSecs := max 0 (expiresMs / 1000)
  let dateOut ← IO.Process.output { cmd := "date", args := #["-u", "-d", s!"@{expSecs}", "+%Y-%m-%dT%H:%M:%SZ"] }
  let expiryIso :=
    if dateOut.exitCode == 0 && !dateOut.stdout.trimAscii.isEmpty then dateOut.stdout.trimAscii.toString
    else "2030-01-01T00:00:00Z"
  let nativeDoc := renderCompact (.obj #[
    ("auth_method", .str "consumer"),
    ("token", .obj #[
      ("access_token", .str access),
      ("token_type", .str "Bearer"),
      ("refresh_token", .str refresh),
      ("expiry", .str expiryIso)
    ])
  ])
  let homePath := System.FilePath.mk ah
  if let .error e ← ensurePrivateDir0700 homePath then
    return .error e
  IO.FS.createDirAll (homePath / "conversations")
  IO.FS.createDirAll (homePath / "brain")
  let defaultMissing := !(← privateFileReadable (homePath / "antigravity-oauth-token"))
  let mut changed := false
  if cleanSlot?.isNone || updateDefault || defaultMissing then
    if let .error e ← writeAtomicPrivate0600 (homePath / "antigravity-oauth-token") nativeDoc.toUTF8 then
      return .error e
    changed := true
  if let some sl := cleanSlot? then
    let slotDir := homePath / "accounts" / sl
    if let .error e ← ensurePrivateDir0700 slotDir then
      return .error e
    let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", (homePath / "conversations").toString, (slotDir / "conversations").toString] }
    let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", (homePath / "brain").toString, (slotDir / "brain").toString] }
    if let .error e ← writeAtomicPrivate0600 (slotDir / "antigravity-oauth-token") nativeDoc.toUTF8 then
      return .error e
    changed := true
  let adv ← advertisedManagedAuth ma
  return .ok (.obj #[("changed", .bool changed), ("managed_auth", .arr (adv.map .str))])

end OrbNode.FileBrowser
