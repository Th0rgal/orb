/-
  OrbNode.Transfer: Machine-Transfer Checkpoints (`shared/machine_transfer.rs`) & `tar+zstd`
  Bulk-Copy Pack/Unpack (`src/machine_transfer_archive.rs`) for `sandboxed-node`.
-/
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.FileBrowser

namespace OrbNode.Transfer

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbNode.FileBrowser

def transferBlockBytes : Nat := 1024 * 1024
def maxTransferBytes : UInt64 := 10 * 1024 * 1024 * 1024
def maxTransferFiles : Nat := 50000

def isProtectedSegment (name : String) : Bool :=
  let n := name.toLower
  n == ".env" || n.startsWith ".env." ||
  n == ".ssh" || n == ".aws" || n == ".gnupg" || n == ".git" ||
  n == "credentials.json" || n == ".credentials.json" || n == "auth.json" ||
  n == "id_rsa" || n == "id_ed25519" || n == ".git-credentials" ||
  n == ".gemini" || n == ".claude" || n == ".codex" || n == ".grok" ||
  n.endsWith ".pem" || n.endsWith ".key"

def isRebuildableSegment (name : String) : Bool :=
  name == "node_modules" || name == "target" || name == ".lake" ||
  name == ".turbo-lean" || name == "__pycache__" || name == ".venv" || name == ".cache"

def validRelativeCheckpointPath (raw : String) : Bool :=
  !raw.isEmpty && !raw.startsWith "/" && !raw.endsWith "/" && !raw.contains '\\' &&
  (raw.splitOn "/").all fun seg => !seg.isEmpty && seg != "." && seg != ".."

def confinedCheckpointPath (root : System.FilePath) (rel : String) : IO (Except String System.FilePath) := do
  if !validRelativeCheckpointPath rel then
    return .error "Invalid checkpoint path"
  let rst ← statPath root.toString
  if rst.exists_ && rst.isSymlink then
    return .error "Checkpoint root is a symlink"
  let mut cur := root
  for seg in rel.splitOn "/" do
    cur := cur / seg
    let st ← statPath cur.toString
    if st.exists_ && st.isSymlink then
      return .error s!"Symlink is not transferable: {rel}"
  return .ok cur

def detectTransferHarnesses (ma : ManagedAuthConfig) : IO (Array String) := do
  let adv ← advertisedManagedAuth ma
  let grokOk := adv.contains "grok"
  let agOk := adv.contains "antigravity"
  let pyRes ← IO.Process.output { cmd := "python3", args := #["-c", "import sys; raise SystemExit(0 if sys.version_info >= (3,12) else 1)"] }
  let pyOk := pyRes.exitCode == 0
  let pathStr := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
  let dirs := (pathStr.splitOn ":").filter (fun s => !s.isEmpty)
  let hasBin (bin : String) : IO Bool := do
    for d in dirs do
      let st ← statPath ((System.FilePath.mk d / bin).toString)
      if st.exists_ && st.isReg then return true
    return false
  let candidates := #[
    ("grok", "grok", grokOk),
    ("codex", "codex", true),
    ("opencode", "opencode", true),
    ("claude", "claudecode", true),
    ("agy", "antigravity", agOk),
    ("vibe-acp", "vibe", pyOk)
  ]
  let mut out : Array String := #[]
  for (bin, backend, gate) in candidates do
    if gate && (← hasBin bin) then
      out := out.push backend
  return out

structure TransferEntry where
  path       : String
  bytes      : UInt64
  sha256     : String
  executable : Bool
  deriving Repr, BEq

def TransferEntry.toJson (e : TransferEntry) : JVal :=
  .obj #[
    ("path", .str e.path),
    ("bytes", JVal.uint64 e.bytes),
    ("sha256", .str e.sha256),
    ("executable", .bool e.executable)
  ]

def TransferEntry.fromJson? (v : JVal) : Option TransferEntry := do
  let path ← v.fieldStr? "path"
  let bytes ← v.fieldUInt64? "bytes"
  let sha256 ← v.fieldStr? "sha256"
  let exec := (v.fieldBool? "executable").getD false
  return { path, bytes, sha256, executable := exec }

structure TransferManifest where
  files    : Array TransferEntry := #[]
  excluded : Array String := #[]
  bytes    : UInt64 := 0
  links    : Array (String × String) := #[]
  deriving Repr, BEq

def TransferManifest.toJson (m : TransferManifest) : JVal := Id.run do
  let mut fields : Array (String × JVal) := #[
    ("files", .arr (m.files.map TransferEntry.toJson)),
    ("excluded", .arr (m.excluded.map .str)),
    ("bytes", JVal.uint64 m.bytes)
  ]
  if !m.links.isEmpty then
    fields := fields.push ("links", .arr (m.links.map fun (p, t) =>
      .obj #[("path", .str p), ("target", .str t)]))
  return .obj fields

def TransferManifest.fromJson? (v : JVal) : Option TransferManifest := do
  let rawFiles ← v.fieldArr? "files"
  let mut files : Array TransferEntry := #[]
  for rf in rawFiles do
    let ef ← TransferEntry.fromJson? rf
    files := files.push ef
  let excluded := ((v.fieldArr? "excluded").getD #[]).filterMap JVal.asStr?
  let bytes ← v.fieldUInt64? "bytes"
  let mut links : Array (String × String) := #[]
  if let some rl := v.fieldArr? "links" then
    for l in rl do
      if let (some p, some t) := (l.fieldStr? "path", l.fieldStr? "target") then
        links := links.push (p, t)
  return { files, excluded, bytes, links }

def validateManifest (m : TransferManifest) : Except String Unit := do
  if m.files.size + m.links.size > maxTransferFiles then
    throw "Too many files"
  let mut total : UInt64 := 0
  let mut seen : Array String := #[]
  for f in m.files do
    if !validRelativeCheckpointPath f.path then throw "Invalid checkpoint path"
    let checkPath :=
      if f.path.endsWith ".transfer-git.bundle" then
        (f.path.dropEnd 20).toString
      else f.path
    if !checkPath.isEmpty && (checkPath.splitOn "/").any isProtectedSegment then
      throw "Excluded path in manifest"
    if seen.contains f.path then throw "Duplicate path in manifest"
    if f.sha256.length != 64 || !f.sha256.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')) then
      throw "Invalid manifest sha256"
    seen := seen.push f.path
    total := total + f.bytes
    if total > maxTransferBytes then throw "Checkpoint exceeds 10 GiB"
  if total != m.bytes then
    throw "Manifest size mismatch"

private def loadSelection (area : System.FilePath) : IO (Array String × Array String) := do
  let selFile := area / "selection.json"
  if !(← selFile.pathExists) then return (#[], #[])
  let .ok raw ← IO.FS.readFile selFile |>.toBaseIO | return (#[], #[])
  let .ok jv := OrbBin.Json.parse raw | return (#[], #[])
  let omitList := ((jv.fieldArr? "omit").getD #[]).filterMap JVal.asStr?
  let inclList := ((jv.fieldArr? "include").getD #[]).filterMap JVal.asStr?
  return (omitList, inclList)

private def walkWorkspace
    (sourceRoot : System.FilePath) (omitList inclList : Array String) :
    IO (Except String TransferManifest) := do
  let rst ← statPath sourceRoot.toString
  if !rst.exists_ then
    return .error "Source workspace directory does not exist"
  if rst.isSymlink || !rst.isDir then
    return .error "Source workspace unavailable"
  let mut pending : Array (System.FilePath × String × Bool) := #[(sourceRoot, "", false)]
  let mut files : Array TransferEntry := #[]
  let mut excluded : Array String := #[]
  let mut totalBytes : UInt64 := 0
  while !pending.isEmpty do
    let (dir, relPfx, chosen) := pending.back!
    pending := pending.pop
    let .ok rawEntries ← dir.readDir |>.toBaseIO
      | return .error s!"Failed reading {dir}"
    let sorted := rawEntries.qsort (fun a b => a.fileName < b.fileName)
    for item in sorted do
      let rel := if relPfx.isEmpty then item.fileName else s!"{relPfx}/{item.fileName}"
      let st ← statPath item.path.toString
      let incHere := chosen || inclList.contains rel
      let isExcl :=
        isProtectedSegment item.fileName ||
        omitList.contains rel ||
        (!incHere && isRebuildableSegment item.fileName)
      if isExcl then
        if excluded.size < 5000 || item.fileName == ".git" then
          excluded := excluded.push rel
      else if st.isSymlink then
        pure ()
      else if st.isDir then
        pending := pending.push (item.path, rel, incHere)
      else if st.isReg then
        let .ok bytes ← IO.FS.readBinFile item.path |>.toBaseIO
          | return .error s!"Failed reading {rel}"
        let sha := bytesToHexLower (sha256Bytes bytes)
        let exec := (st.mode &&& 0o111) != 0
        totalBytes := totalBytes + bytes.size.toUInt64
        if totalBytes > maxTransferBytes || files.size + 1 > maxTransferFiles then
          return .error "Workspace exceeds transfer limit (10 GiB / 50,000 files)"
        files := files.push { path := rel, bytes := bytes.size.toUInt64, sha256 := sha, executable := exec }
  let sortedFiles := files.qsort (fun a b => a.path < b.path)
  return .ok { files := sortedFiles, excluded := excluded, bytes := totalBytes }

def operateTransfer
    (area : System.FilePath) (source? : Option System.FilePath) (opJson : JVal) :
    IO (Except String JVal) := do
  IO.FS.createDirAll area
  let root := area / "workspace"
  let manifestFile := area / "manifest.json"
  let opName := (opJson.fieldStr? "op").getD ""
  match opName with
  | "inventory" =>
    let some src := source? | return .error "Source workspace unavailable"
    match ← walkWorkspace src #[] #[] with
    | .error e => return .error e
    | .ok m =>
      let rows := m.files.map fun f => JVal.obj #[
        ("path", .str f.path),
        ("folder", .bool false),
        ("state", .str "moved"),
        ("bytes", JVal.uint64 f.bytes),
        ("files", JVal.nat 1)
      ]
      return .ok (.obj #[
        ("bytes", JVal.uint64 m.bytes),
        ("files", JVal.nat m.files.size),
        ("rows", .arr rows),
        ("truncated", .bool false),
        ("hidden", JVal.nat 0)
      ])
  | "select" =>
    let omitList := ((opJson.fieldArr? "omit").getD #[]).filterMap JVal.asStr?
    let inclList := ((opJson.fieldArr? "include").getD #[]).filterMap JVal.asStr?
    for p in omitList ++ inclList do
      if !validRelativeCheckpointPath p then return .error "Invalid checkpoint path"
    if inclList.any (fun p => (p.splitOn "/").any isProtectedSegment) then
      return .error "Credentials and generated configuration cannot be moved"
    let selDoc := renderCompact (.obj #[
      ("omit", .arr (omitList.map .str)),
      ("include", .arr (inclList.map .str))
    ])
    IO.FS.writeFile (area / "selection.json") selDoc
    return .ok (.obj #[("ok", .bool true)])
  | "snapshot" =>
    if ← manifestFile.pathExists then
      let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
      let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
      return .ok jv
    let some src := source? | return .error "Source workspace unavailable"
    let (omitList, inclList) ← loadSelection area
    let m ← match ← walkWorkspace src omitList inclList with
      | .ok v => pure v
      | .error e => return .error e
    if ← root.pathExists then
      let _ ← IO.Process.output { cmd := "rm", args := #["-rf", root.toString] }
    IO.FS.createDirAll root
    for f in m.files do
      let srcFile := src / f.path
      let dstFile := root / f.path
      if let some par := dstFile.parent then IO.FS.createDirAll par
      let .ok bytes ← IO.FS.readBinFile srcFile |>.toBaseIO
        | return .error s!"Failed copying {f.path}"
      if bytesToHexLower (sha256Bytes bytes) != f.sha256 then
        return .error s!"File changed during snapshot: {f.path}"
      IO.FS.writeBinFile dstFile bytes
      let _ ← chmod dstFile.toString (if f.executable then 0o700 else 0o600)
    let mJson := m.toJson
    IO.FS.writeFile manifestFile (renderCompact mJson)
    return .ok mJson
  | "check_source" =>
    let some src := source? | return .error "Source workspace unavailable"
    if !(← manifestFile.pathExists) then return .error "Manifest not found"
    let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
    let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
    let some expected := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
    let (omitList, inclList) ← loadSelection area
    match ← walkWorkspace src omitList inclList with
    | .error e => return .error e
    | .ok cur =>
      let expPlain := expected.files.filter (fun f => !f.path.endsWith ".transfer-git.bundle")
      if cur.files != expPlain then
        return .error "Source files changed after preparation; cancel and prepare again"
      return .ok (.obj #[("unchanged", .bool true)])
  | "stage" =>
    let some mVal := opJson.field? "manifest" | return .error "missing manifest"
    let some m := TransferManifest.fromJson? mVal | return .error "invalid manifest"
    if let .error e := validateManifest m then return .error e
    if ← manifestFile.pathExists then
      let .ok exRaw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
      let .ok exJv := OrbBin.Json.parse exRaw | return .error "Corrupt manifest"
      let some exM := TransferManifest.fromJson? exJv | return .error "Corrupt manifest"
      if exM != m then return .error "Transfer manifest differs from staged checkpoint"
    else
      IO.FS.createDirAll root
      IO.FS.writeFile manifestFile (renderCompact m.toJson)
    let mut recvd : Array (String × JVal) := #[]
    for f in m.files do
      let fp := root / f.path
      let sz ← if ← fp.pathExists then
        match ← fp.metadata |>.toBaseIO with
        | .ok md => pure (min md.byteSize f.bytes)
        | .error _ => pure 0
      else pure 0
      let aligned := if sz == f.bytes then sz else (sz / transferBlockBytes.toUInt64) * transferBlockBytes.toUInt64
      recvd := recvd.push (f.path, JVal.uint64 aligned)
    let sealed ← (area / "verified").pathExists
    return .ok (.obj #[("ok", .bool true), ("sealed", .bool sealed), ("received", .obj recvd)])
  | "read" =>
    let some p := opJson.fieldStr? "path" | return .error "missing path"
    let off := (opJson.fieldUInt64? "offset").getD 0
    if !(← manifestFile.pathExists) then return .error "Manifest not found"
    let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
    let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
    let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
    let some f := m.files.find? (·.path == p) | return .error "File absent from manifest"
    if off > f.bytes || off.toNat % transferBlockBytes != 0 then
      return .error "Invalid block offset"
    let fp ← match ← confinedCheckpointPath root p with
      | .ok v => pure v
      | .error e => return .error e
    let .ok allBytes ← IO.FS.readBinFile fp |>.toBaseIO | return .error "Failed reading file"
    let endIdx := min allBytes.size (off.toNat + transferBlockBytes)
    let slice := allBytes.extract off.toNat endIdx
    return .ok (.obj #[("data", .str (base64Encode slice false true))])
  | "write" =>
    if ← (area / "verified").pathExists then return .error "Checkpoint already sealed"
    let some p := opJson.fieldStr? "path" | return .error "missing path"
    let off := (opJson.fieldUInt64? "offset").getD 0
    let some dataB64 := opJson.fieldStr? "data" | return .error "missing data"
    if !(← manifestFile.pathExists) then return .error "Manifest not found"
    let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
    let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
    let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
    let some f := m.files.find? (·.path == p) | return .error "File absent from manifest"
    let some chunk := base64Decode? dataB64 | return .error "Invalid base64 data"
    let expectedLen := min transferBlockBytes (f.bytes.toNat - off.toNat)
    if off > f.bytes || off.toNat % transferBlockBytes != 0 || chunk.size != expectedLen then
      return .error "Invalid block extent"
    let fp ← match ← confinedCheckpointPath root p with
      | .ok v => pure v
      | .error e => return .error e
    if let some par := fp.parent then IO.FS.createDirAll par
    let existing ← if ← fp.pathExists then
      match ← IO.FS.readBinFile fp |>.toBaseIO with
      | .ok b => pure b
      | .error _ => pure ByteArray.empty
    else pure ByteArray.empty
    let prefixBytes :=
      if existing.size >= off.toNat then existing.extract 0 off.toNat
      else existing ++ ByteArray.mk (Array.replicate (off.toNat - existing.size) 0)
    let suffixStart := off.toNat + chunk.size
    let suffixBytes := if existing.size > suffixStart then existing.extract suffixStart existing.size else ByteArray.empty
    IO.FS.writeBinFile fp (prefixBytes ++ chunk ++ suffixBytes)
    return .ok (.obj #[("ok", .bool true)])
  | "verify" =>
    if !(← manifestFile.pathExists) then return .error "Manifest not found"
    let .ok mBytes ← IO.FS.readBinFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
    let .ok jv := OrbBin.Json.parseBytes mBytes | return .error "Corrupt manifest"
    let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
    if let .error e := validateManifest m then return .error e
    let mDigest := bytesToHexLower (sha256Bytes mBytes)
    if !(← (area / "verified").pathExists) then
      for f in m.files do
        let fp ← match ← confinedCheckpointPath root f.path with
          | .ok v => pure v
          | .error e => return .error e
        if f.bytes == 0 && !(← fp.pathExists) then
          if let some par := fp.parent then IO.FS.createDirAll par
          IO.FS.writeBinFile fp ByteArray.empty
        let .ok fb ← IO.FS.readBinFile fp |>.toBaseIO
          | return .error s!"Checkpoint mismatch: {f.path}"
        if fb.size.toUInt64 != f.bytes || bytesToHexLower (sha256Bytes fb) != f.sha256.toLower then
          return .error s!"Checkpoint mismatch: {f.path}"
        let _ ← chmod fp.toString (if f.executable then 0o700 else 0o600)
      for (lp, lt) in m.links do
        let linkDest := root / lp
        if let some par := linkDest.parent then IO.FS.createDirAll par
        let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", lt, linkDest.toString] }
      IO.FS.writeFile (area / "verified") mDigest
    return .ok (.obj #[
      ("root", .str root.toString),
      ("digest", .str mDigest),
      ("bytes", JVal.uint64 m.bytes),
      ("files", JVal.nat m.files.size),
      ("links", JVal.nat m.links.size)
    ])
  | _ => return .error s!"Unknown transfer operation '{opName}'"

/-- Pack source checkpoint `area` into a `tar + zstd` ByteArray (`POST /machine-transfer/archive/pack`). -/
def packTransferArchive (area : System.FilePath) : IO (Except String ByteArray) := do
  let manifestFile := area / "manifest.json"
  if !(← manifestFile.pathExists) then
    return .error "Take the source snapshot first"
  let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
  let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
  let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
  let root := area / "workspace"
  let nonce ← newUuidV4
  let listFile := area / s!".pack-list-{nonce}"
  let outArchive := area / s!".pack-out-{nonce}.tar.zst"
  let mut listContent := ""
  for f in m.files do
    let fp ← match ← confinedCheckpointPath root f.path with
      | .ok v => pure v
      | .error e => return .error e
    let .ok md ← fp.metadata |>.toBaseIO
      | return .error s!"Checkpoint file missing: {f.path}"
    if md.byteSize != f.bytes then
      return .error s!"Checkpoint file changed: {f.path}"
    listContent := listContent ++ f.path ++ "\n"
  IO.FS.writeFile listFile listContent
  let cmd ←
    if m.files.isEmpty then
      pure s!"tar -cf - -T /dev/null | zstd -3 -q -o {shellSingleQuote outArchive.toString}"
    else
      pure s!"tar -C {shellSingleQuote root.toString} -cf - -T {shellSingleQuote listFile.toString} | zstd -3 -q -o {shellSingleQuote outArchive.toString}"
  let res ← IO.Process.output { cmd := "sh", args := #["-c", cmd] }
  try IO.FS.removeFile listFile catch _ => pure ()
  if res.exitCode != 0 then
    try IO.FS.removeFile outArchive catch _ => pure ()
    return .error s!"Archive pack failed: {res.stderr.trimAscii}"
  let .ok archiveBytes ← IO.FS.readBinFile outArchive |>.toBaseIO
    | try IO.FS.removeFile outArchive catch _ => pure ()
      return .error "Failed reading packed archive"
  try IO.FS.removeFile outArchive catch _ => pure ()
  return .ok archiveBytes

/-- Unpack a `tar + zstd` archive into staged destination checkpoint `area`, enforcing manifest confinement. -/
def unpackTransferArchive (area : System.FilePath) (archiveBytes : ByteArray) : IO (Except String UInt64) := do
  if ← (area / "verified").pathExists then
    return .error "Checkpoint already sealed"
  let manifestFile := area / "manifest.json"
  if !(← manifestFile.pathExists) then
    return .error "Stage destination manifest first"
  let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
  let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
  let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
  let root := area / "workspace"
  IO.FS.createDirAll root
  let nonce ← newUuidV4
  let inArchive := area / s!".unpack-in-{nonce}.tar.zst"
  let tmpExtract := area / s!".unpack-dir-{nonce}"
  IO.FS.createDirAll tmpExtract
  IO.FS.writeBinFile inArchive archiveBytes
  let listCmd := s!"zstd -dc {shellSingleQuote inArchive.toString} | tar -tf -"
  let listRes ← IO.Process.output { cmd := "sh", args := #["-c", listCmd] }
  if listRes.exitCode != 0 then
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", inArchive.toString, tmpExtract.toString] }
    return .error s!"Invalid tar+zstd archive: {listRes.stderr.trimAscii}"
  let names := (listRes.stdout.splitOn "\n").map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty)
  for name in names do
    let clean := if name.startsWith "./" then (name.drop 2).toString else name
    if !clean.isEmpty then
      if (m.files.find? (·.path == clean)).isNone then
        let _ ← IO.Process.output { cmd := "rm", args := #["-rf", inArchive.toString, tmpExtract.toString] }
        return .error s!"Archive entry absent from manifest: {clean}"
  let extCmd := s!"zstd -dc {shellSingleQuote inArchive.toString} | tar --no-same-owner --no-same-permissions -C {shellSingleQuote tmpExtract.toString} -xf -"
  let extRes ← IO.Process.output { cmd := "sh", args := #["-c", extCmd] }
  try IO.FS.removeFile inArchive catch _ => pure ()
  if extRes.exitCode != 0 then
    let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpExtract.toString] }
    return .error s!"Archive extraction failed: {extRes.stderr.trimAscii}"
  let mut written : UInt64 := 0
  for name in names do
    let clean := if name.startsWith "./" then (name.drop 2).toString else name
    if let some f := m.files.find? (·.path == clean) then
      let extracted := tmpExtract / clean
      let est ← statPath extracted.toString
      if !est.exists_ || est.isSymlink || !est.isReg then
        let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpExtract.toString] }
        return .error "Archive contains a non-regular entry"
      let .ok bytes ← IO.FS.readBinFile extracted |>.toBaseIO
        | let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpExtract.toString] }
          return .error s!"Failed reading extracted entry {clean}"
      if bytes.size.toUInt64 != f.bytes then
        let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpExtract.toString] }
        return .error s!"Archive entry has the wrong size: {clean}"
      let dst ← match ← confinedCheckpointPath root clean with
        | .ok v => pure v
        | .error e =>
          let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpExtract.toString] }
          return .error e
      if let some par := dst.parent then IO.FS.createDirAll par
      IO.FS.writeBinFile dst bytes
      written := written + bytes.size.toUInt64
  let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpExtract.toString] }
  return .ok written

end OrbNode.Transfer
