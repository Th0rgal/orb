/-
  OrbNode.Transfer: Machine-Transfer Checkpoints (`shared/machine_transfer.rs`) & `tar+zstd`
  Bulk-Copy Pack/Unpack (`src/machine_transfer_archive.rs`) for `sandboxed-node`.
  Supports portable workspace symlinks (`links` + `skipped`), Git repository `.transfer-git.bundle`
  preservation & restoration, overlap/escape confinement, and block/bulk resume.
-/
import Std.Data.HashMap
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
def maxTransferRows : Nat := 2000
def excludedListedCap : Nat := 5000

def outsideLinkReason : String := "link points outside the workspace"
def unusualLinkReason : String := "link target is not portable"
def specialFileReason : String := "socket, pipe or device"

def isProtectedSegment (name : String) : Bool :=
  let n := name.toLower
  n == ".git" || n == ".transfers" || n == ".transfer-git.bundle" ||
  n == ".ssh" || n == ".aws" || n == ".codex" || n == ".claude" ||
  n == ".opencode" || n == ".grok" || n == ".gemini" || n == ".gnupg" ||
  n == ".npmrc" || n == ".netrc" || n == ".pypirc" || n == ".envrc" ||
  n == ".git-credentials" || n == "secrets" || n == "secrets.json" ||
  n == "secrets.yaml" || n == "secrets.yml" || n == "credentials.json" ||
  n == ".credentials.json" || n == "auth.json" || n == "opencode.json" ||
  n == ".env" || (n.startsWith ".env." && !n.endsWith ".example") ||
  n.endsWith ".pem" || n.endsWith ".key" || n.endsWith ".p12" || n.endsWith ".pfx" ||
  n.startsWith "id_rsa" || n.startsWith "id_ed25519" ||
  (n.splitOn "credentials").length > 1

def isRebuildableSegment (name : String) (topLevel : Bool := false) : Bool :=
  let n := name.toLower
  n == "node_modules" || n == "target" || n == ".next" || n == ".cache" ||
  n == "__pycache__" || n == ".venv" || n == ".lake" || n == ".turbo-lean" ||
  (topLevel && (
    n == ".rustup" || n == ".cargo" || n == ".elan" || n == ".npm" ||
    n == ".nvm" || n == ".bun" || n == ".deno" || n == ".pnpm-store" ||
    n == ".gradle" || n == ".m2" || n == ".pyenv" || n == ".rbenv"))

def isRebuildableRel (rel : String) : Bool :=
  rel == ".local/share/opencode/tool-output" ||
  rel == ".local/share/opencode/log" ||
  rel == ".local/share/opencode/snapshot"

def isRepositoryRel (rel : String) : Bool :=
  rel == ".git" || rel.endsWith "/.git"

def validRelativeCheckpointPath (raw : String) : Bool :=
  !raw.isEmpty && !raw.startsWith "/" && !raw.endsWith "/" && !raw.contains '\\' &&
  !raw.contains '\x00' &&
  (raw.splitOn "/").all fun seg => !seg.isEmpty && seg != "." && seg != ".."

def checkpointParentDepth (path : String) : Nat :=
  let segs := path.splitOn "/"
  if segs.length == 0 then 0 else segs.length - 1

/-- `contained_target` (`shared/machine_transfer.rs`): relative target whose `..` components only lead
    and never climb above the workspace root (`up <= depth(path)`). -/
def containedLinkTarget (path target : String) : Bool := Id.run do
  if target.isEmpty || target.length > 4096 || target.contains '\\' || target.contains '\x00' || target.startsWith "/" then
    return false
  let mut up : Nat := 0
  let mut names : Nat := 0
  for seg in target.splitOn "/" do
    if seg.isEmpty || seg == "." then
      if seg.isEmpty then return false
    else if seg == ".." then
      if names > 0 then return false
      up := up + 1
    else
      names := names + 1
  return up ≤ checkpointParentDepth path

private def readSymlinkTarget (linkPath : System.FilePath) : IO (Option String) := do
  let res ← (IO.Process.output { cmd := "readlink", args := #[linkPath.toString] }).toBaseIO
  match res with
  | .ok out =>
    if out.exitCode != 0 then return none
    let clean := (out.stdout.dropEndWhile (fun c => c == '\n' || c == '\r')).toString
    if clean.isEmpty then return none else return some clean
  | .error _ => return none

/-- Rewrite portable source symlink target (`portable_target` in `shared/machine_transfer.rs`). -/
def portableLinkTarget (roots : Array String) (relPath rawTarget : String) : Except String String := do
  if rawTarget.isEmpty || rawTarget.contains '\\' || rawTarget.contains '\x00' then
    throw unusualLinkReason
  if !rawTarget.startsWith "/" then
    if containedLinkTarget relPath rawTarget then
      return rawTarget
    let parentSegs := (relPath.splitOn "/").dropLast
    let mut level : Nat := parentSegs.length
    let mut escapes := false
    for seg in rawTarget.splitOn "/" do
      if seg == ".." then
        if level == 0 then escapes := true
        level := level - 1
      else if seg != "." && !seg.isEmpty then
        level := level + 1
    throw (if escapes then outsideLinkReason else unusualLinkReason)
  let mut inside? : Option String := none
  for r in roots do
    let cleanR := (r.dropEndWhile (· == '/')).toString
    if rawTarget == cleanR then
      inside? := some ""
      break
    else if rawTarget.startsWith (cleanR ++ "/") then
      inside? := some ((rawTarget.drop (cleanR.length + 1)).toString)
      break
  let some inside := inside?
    | throw outsideLinkReason
  if !inside.isEmpty && !validRelativeCheckpointPath inside then
    throw unusualLinkReason
  let d := checkpointParentDepth relPath
  let up := String.intercalate "/" (List.replicate d "..")
  let rewritten :=
    if inside.isEmpty then
      if up.isEmpty then "." else up
    else if up.isEmpty then
      inside
    else
      s!"{up}/{inside}"
  if containedLinkTarget relPath rewritten then
    return rewritten
  else
    throw unusualLinkReason

/-- Confine `rel` beneath `root`, verifying `root` and every existing component is not a symlink. -/
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

/-- Confine parent directories for creating or verifying a symlink at `rel` beneath `root`
    (every ancestor must be a non-symlink directory; the final component itself may be a symlink). -/
private def confinedSymlinkParent (root : System.FilePath) (rel : String) :
    IO (Except String (System.FilePath × System.FilePath)) := do
  if !validRelativeCheckpointPath rel then
    return .error "Invalid checkpoint path"
  let rst ← statPath root.toString
  if rst.exists_ && rst.isSymlink then
    return .error "Checkpoint root is a symlink"
  let segs := rel.splitOn "/"
  let parentSegs := segs.dropLast
  let some leaf := segs.getLast?
    | return .error "Invalid link path"
  let mut par := root
  for seg in parentSegs do
    par := par / seg
    let st ← statPath par.toString
    if st.exists_ then
      if st.isSymlink then
        return .error s!"Symlink ancestor is not transferable: {rel}"
      if !st.isDir then
        return .error s!"Checkpoint mismatch: {rel}"
  return .ok (par, par / leaf)

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
  skipped  : Array (String × String) := #[]
  unlisted : Nat := 0
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
  if !m.skipped.isEmpty then
    fields := fields.push ("skipped", .arr (m.skipped.map fun (p, r) =>
      .obj #[("path", .str p), ("reason", .str r)]))
  if m.unlisted > 0 then
    fields := fields.push ("unlisted", JVal.nat m.unlisted)
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
      let p ← l.fieldStr? "path"
      let t ← l.fieldStr? "target"
      links := links.push (p, t)
  let mut skipped : Array (String × String) := #[]
  if let some rs := v.fieldArr? "skipped" then
    for s in rs do
      let p ← s.fieldStr? "path"
      let r ← s.fieldStr? "reason"
      skipped := skipped.push (p, r)
  let unlisted := (v.fieldNat? "unlisted").getD 0
  return { files, excluded, bytes, links, skipped, unlisted }

/-- Full `shared/machine_transfer.rs::validate` check: validates files, links, target containment,
    duplicate paths, and file/link ancestor overlaps. -/
def validateManifest (m : TransferManifest) : Except String Unit := do
  if (renderCompact m.toJson).utf8ByteSize > 8 * 1024 * 1024 then
    throw "Workspace inventory exceeds 8 MiB"
  if m.files.size > maxTransferFiles || m.files.size + m.links.size > maxTransferFiles || m.skipped.size > maxTransferFiles then
    throw "Too many files"
  let mut total : UInt64 := 0
  let mut seen : Std.HashMap String Unit := {}
  for f in m.files do
    if !validRelativeCheckpointPath f.path then throw "Invalid checkpoint path"
    let checkPath :=
      if f.path.endsWith ".transfer-git.bundle" then
        (f.path.dropEnd 20).toString
      else f.path
    if !checkPath.isEmpty && (checkPath.splitOn "/").any isProtectedSegment then
      throw "Excluded path in manifest"
    if seen.contains f.path then throw "Invalid manifest"
    if f.sha256.length != 64 || !f.sha256.all (fun c => ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')) then
      throw "Invalid manifest"
    seen := seen.insert f.path ()
    total := total + f.bytes
    if total > maxTransferBytes then throw "Checkpoint exceeds 10 GiB"
  if total != m.bytes then
    throw "Manifest size mismatch"
  for (lp, lt) in m.links do
    if !validRelativeCheckpointPath lp then throw "Invalid checkpoint path"
    if (lp.splitOn "/").any isProtectedSegment then
      throw "Excluded path in manifest"
    if seen.contains lp || !containedLinkTarget lp lt then
      throw "Invalid manifest"
    seen := seen.insert lp ()
  let allPaths := (m.files.map (·.path)) ++ (m.links.map Prod.fst)
  for p in allPaths do
    let segs := p.splitOn "/"
    if segs.length > 1 then
      let mut prefixStr := ""
      for seg in segs.dropLast do
        prefixStr := if prefixStr.isEmpty then seg else s!"{prefixStr}/{seg}"
        if seen.contains prefixStr then
          throw "Overlapping checkpoint paths"

private def loadSelection (area : System.FilePath) : IO (Array String × Array String) := do
  let selFile := area / "selection.json"
  if !(← selFile.pathExists) then return (#[], #[])
  let .ok raw ← IO.FS.readFile selFile |>.toBaseIO | return (#[], #[])
  let .ok jv := OrbBin.Json.parse raw | return (#[], #[])
  let omitList := ((jv.fieldArr? "omit").getD #[]).filterMap JVal.asStr?
  let inclList := ((jv.fieldArr? "include").getD #[]).filterMap JVal.asStr?
  return (omitList, inclList)

private def gitIgnoredPaths (dir : System.FilePath) (rel : String) : IO (Option (Std.HashMap String Unit)) := do
  let gitMeta ← statPath (dir / ".git").toString
  if !gitMeta.exists_ then return none
  let r ← (IO.Process.output {
    cmd := "git"
    args := #[
      "-c", "core.hooksPath=/dev/null",
      "-c", "core.fsmonitor=false",
      "-C", dir.toString,
      "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"
    ]
    env := #[("GIT_TERMINAL_PROMPT", some "0"), ("GIT_OPTIONAL_LOCKS", some "0")]
  }).toBaseIO
  let mut set : Std.HashMap String Unit := {}
  if let .ok out := r then
    if out.exitCode == 0 then
      for line in out.stdout.splitOn "\n" do
        let p := (line.trimAscii.dropEndWhile (· == '/')).toString
        if !p.isEmpty then
          let full := if rel.isEmpty then p else s!"{rel}/{p}"
          set := set.insert full ()
  return some set

private def walkWorkspace
    (sourceRoot : System.FilePath) (roots : Array String) (omitList inclList : Array String) :
    IO (Except String TransferManifest) := do
  let rst ← statPath sourceRoot.toString
  if !rst.exists_ then
    return .error "Source workspace directory does not exist"
  if rst.isSymlink || !rst.isDir then
    return .error "Source workspace unavailable"
  let rootIgnored := (← gitIgnoredPaths sourceRoot "").getD {}
  let mut pending : Array (System.FilePath × String × Bool × Std.HashMap String Unit) :=
    #[(sourceRoot, "", false, rootIgnored)]
  let mut files : Array TransferEntry := #[]
  let mut links : Array (String × String) := #[]
  let mut skipped : Array (String × String) := #[]
  let mut excluded : Array String := #[]
  let mut unlisted : Nat := 0
  let mut totalBytes : UInt64 := 0
  while !pending.isEmpty do
    let (dir, relPfx, chosen, ignoredSet) := pending.back!
    pending := pending.pop
    let .ok rawEntries ← dir.readDir |>.toBaseIO
      | return .error s!"Failed reading {dir}"
    let sorted := rawEntries.qsort (fun a b => a.fileName < b.fileName)
    for item in sorted do
      if item.fileName.contains '\\' then
        return .error "Invalid checkpoint path"
      let rel := if relPfx.isEmpty then item.fileName else s!"{relPfx}/{item.fileName}"
      let st ← statPath item.path.toString
      let incHere := chosen || inclList.contains rel
      let topLevel := !(rel.contains '/')
      let isLeftBehind :=
        if isProtectedSegment item.fileName then true
        else if omitList.contains rel then true
        else if incHere then false
        else if isRebuildableSegment item.fileName topLevel || isRebuildableRel rel then true
        else if ignoredSet.contains rel then true
        else false
      if isLeftBehind then
        if isRepositoryRel rel || excluded.size < excludedListedCap then
          excluded := excluded.push rel
        else
          unlisted := unlisted + 1
        if excluded.size > maxTransferFiles then
          return .error "Too many repositories"
      else if st.isSymlink then
        match ← readSymlinkTarget item.path with
        | some rawTarget =>
          match portableLinkTarget roots rel rawTarget with
          | .ok portable => links := links.push (rel, portable)
          | .error reason => skipped := skipped.push (rel, reason)
        | none =>
          skipped := skipped.push (rel, unusualLinkReason)
        if files.size + links.size > maxTransferFiles || skipped.size > maxTransferFiles then
          return .error "Workspace exceeds transfer limit (10 GiB / 50,000 files)"
      else if st.isDir then
        let ownIgnored? ← gitIgnoredPaths item.path rel
        pending := pending.push (item.path, rel, incHere, ownIgnored?.getD ignoredSet)
      else if st.isReg then
        let beforeMd? ← (item.path.metadata |>.toBaseIO).map (fun r => r.toOption)
        let .ok bytes ← IO.FS.readBinFile item.path |>.toBaseIO
          | return .error s!"Failed reading {rel}"
        let afterSt ← statPath item.path.toString
        let afterMd? ← (item.path.metadata |>.toBaseIO).map (fun r => r.toOption)
        let changed :=
          !afterSt.exists_ || afterSt.isSymlink || !afterSt.isReg ||
          match beforeMd?, afterMd? with
          | some bmd, some amd =>
            amd.byteSize != bytes.size.toUInt64 || amd.modified != bmd.modified
          | _, _ => true
        if changed then
          return .error s!"File changed during snapshot: {rel}"
        let sha := bytesToHexLower (sha256Bytes bytes)
        let exec := (st.mode &&& 0o111) != 0
        totalBytes := totalBytes + bytes.size.toUInt64
        if totalBytes > maxTransferBytes || files.size + links.size + 1 > maxTransferFiles then
          return .error "Workspace exceeds transfer limit (10 GiB / 50,000 files)"
        files := files.push { path := rel, bytes := bytes.size.toUInt64, sha256 := sha, executable := exec }
      else
        skipped := skipped.push (rel, specialFileReason)
  let sortedFiles := files.qsort (fun a b => a.path < b.path)
  let sortedLinks := links.qsort (fun a b => a.1 < b.1)
  let sortedSkipped := skipped.qsort (fun a b => a.1 < b.1)
  let sortedExcl := excluded.qsort (· < ·)
  return .ok {
    files := sortedFiles
    excluded := sortedExcl
    bytes := totalBytes
    links := sortedLinks
    skipped := sortedSkipped
    unlisted := unlisted
  }

private def resolveCanonicalSource (src : System.FilePath) : IO (Except String (System.FilePath × Array String)) := do
  let st ← statPath src.toString
  if !st.exists_ then
    return .error "Source workspace directory does not exist"
  let r ← (IO.FS.realPath src).toBaseIO
  match r with
  | .error e => return .error (toString e)
  | .ok canon =>
    let mut roots : Array String := #[canon.toString]
    if src.toString != canon.toString then
      roots := roots.push src.toString
    return .ok (canon, roots)

private def normalizeShowRefLines (s : String) : Array String :=
  let lines := (s.splitOn "\n").map (·.trimAscii.toString) |>.filter (fun ln => !ln.isEmpty && !ln.endsWith " HEAD")
  lines.toArray.qsort (· < ·)

private def restoreManifestLinks (root : System.FilePath) (links : Array (String × String)) :
    IO (Except String Unit) := do
  for (lp, lt) in links do
    let (par, linkDest) ← match ← confinedSymlinkParent root lp with
      | .ok v => pure v
      | .error e => return .error e
    IO.FS.createDirAll par
    let lst ← statPath linkDest.toString
    if lst.exists_ then
      if lst.isSymlink then
        match ← readSymlinkTarget linkDest with
        | some curTarget =>
          if curTarget != lt then
            return .error s!"Checkpoint mismatch: {lp}"
        | none => return .error s!"Checkpoint mismatch: {lp}"
      else
        return .error s!"Checkpoint mismatch: {lp}"
    else
      let r ← IO.Process.output { cmd := "ln", args := #["-s", lt, linkDest.toString] }
      if r.exitCode != 0 then
        return .error s!"Failed creating symlink {lp}: {r.stderr.trimAscii}"
  return .ok ()

private def runGitCmd (cwd : System.FilePath) (args : Array String) : IO (Except String Unit) := do
  let r ← IO.Process.output {
    cmd := "git"
    args := #["-c", "core.hooksPath=/dev/null", "-C", cwd.toString] ++ args
    env := #[("GIT_TERMINAL_PROMPT", some "0")]
  }
  if r.exitCode != 0 then
    return .error "Git checkpoint failed; inspect the repository before moving"
  return .ok ()

def operateTransfer
    (area : System.FilePath) (source? : Option System.FilePath) (opJson : JVal) :
    IO (Except String JVal) := do
  IO.FS.createDirAll area
  let root := area / "workspace"
  let manifestFile := area / "manifest.json"
  let opName := (opJson.fieldStr? "op").getD ""
  match opName with
  | "inventory" =>
    let some rawSrc := source? | return .error "Source workspace unavailable"
    let (src, roots) ← match ← resolveCanonicalSource rawSrc with
      | .ok v => pure v
      | .error e => return .error e
    match ← walkWorkspace src roots #[] #[] with
    | .error e => return .error e
    | .ok m =>
      let fileRows := m.files.map fun f => JVal.obj #[
        ("path", .str f.path),
        ("folder", .bool false),
        ("state", .str "moved"),
        ("bytes", JVal.uint64 f.bytes),
        ("files", JVal.nat 1)
      ]
      let linkRows := m.links.map fun (lp, _) => JVal.obj #[
        ("path", .str lp),
        ("folder", .bool false),
        ("state", .str "moved"),
        ("bytes", JVal.uint64 0),
        ("files", JVal.nat 1)
      ]
      let rows := (fileRows ++ linkRows).extract 0 (min maxTransferRows (fileRows.size + linkRows.size))
      return .ok (.obj #[
        ("rows", .arr rows),
        ("bytes", JVal.uint64 m.bytes),
        ("files", JVal.nat (m.files.size + m.links.size)),
        ("reserved", .obj #[("bytes", JVal.uint64 0), ("files", JVal.nat 0)]),
        ("truncated", .bool (fileRows.size + linkRows.size > maxTransferRows)),
        ("protected", JVal.nat m.excluded.size),
        ("limits", .obj #[("bytes", JVal.uint64 maxTransferBytes), ("files", JVal.nat maxTransferFiles)])
      ])
  | "select" =>
    let omitList := ((opJson.fieldArr? "omit").getD #[]).filterMap JVal.asStr?
    let inclList := ((opJson.fieldArr? "include").getD #[]).filterMap JVal.asStr?
    if ← manifestFile.pathExists then
      let (curOmit, curIncl) ← loadSelection area
      if curOmit == omitList && curIncl == inclList then
        return .ok (.obj #[("ok", .bool true)])
      else
        return .error "Workspace snapshot already taken; cancel to choose again"
    if omitList.size + inclList.size > maxTransferRows then
      return .error "Too many selected paths"
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
    let some rawSrc := source? | return .error "Source workspace unavailable"
    let (src, roots) ← match ← resolveCanonicalSource rawSrc with
      | .ok v => pure v
      | .error e => return .error e
    if area.toString == src.toString || area.toString.startsWith (src.toString ++ "/") then
      return .error "Checkpoint directory must be outside the workspace"
    let (omitList, inclList) ← loadSelection area
    let mut m ← match ← walkWorkspace src roots omitList inclList with
      | .ok v => pure v
      | .error e => return .error e
    if ← root.pathExists then
      let _ ← IO.Process.output { cmd := "rm", args := #["-rf", root.toString] }
    IO.FS.createDirAll root
    for f in m.files do
      let srcFile ← match ← confinedCheckpointPath src f.path with
        | .ok v => pure v
        | .error e => return .error e
      let dstFile ← match ← confinedCheckpointPath root f.path with
        | .ok v => pure v
        | .error e => return .error e
      if let some par := dstFile.parent then IO.FS.createDirAll par
      let .ok bytes ← IO.FS.readBinFile srcFile |>.toBaseIO
        | return .error s!"Failed copying {f.path}"
      if bytes.size.toUInt64 != f.bytes || bytesToHexLower (sha256Bytes bytes) != f.sha256 then
        return .error s!"File changed during snapshot: {f.path}"
      IO.FS.writeBinFile dstFile bytes
      let _ ← chmod dstFile.toString (if f.executable then 0o700 else 0o600)
    let afterWalk ← match ← walkWorkspace src roots omitList inclList with
      | .ok v => pure v
      | .error e => return .error e
    if afterWalk != m then
      return .error "Workspace changed during snapshot; stop all writers and retry"
    let repos := m.excluded.filter isRepositoryRel
    for gitRel in repos do
      let repoRel :=
        if gitRel == ".git" then ""
        else (gitRel.dropEnd 5).toString
      let repoDir := if repoRel.isEmpty then src else src / repoRel
      let bundleRel := if repoRel.isEmpty then ".transfer-git.bundle" else s!"{repoRel}/.transfer-git.bundle"
      let bundleDst := root / bundleRel
      if let some par := bundleDst.parent then IO.FS.createDirAll par
      let refsOut ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "show-ref"] }
      if refsOut.exitCode != 0 && refsOut.exitCode != 1 then
        return .error "Cannot read Git history"
      if refsOut.exitCode == 0 then
        let bOut ← IO.Process.output {
          cmd := "git"
          args := #["-C", repoDir.toString, "bundle", "create", bundleDst.toString, "--all"]
        }
        if bOut.exitCode != 0 then
          return .error "Could not checkpoint Git history"
        let .ok bBytes ← IO.FS.readBinFile bundleDst |>.toBaseIO
          | return .error "Could not read Git bundle"
        if m.bytes + bBytes.size.toUInt64 > maxTransferBytes then
          return .error "Git history exceeds transfer size or available disk space"
        let bSha := bytesToHexLower (sha256Bytes bBytes)
        m := {
          m with
          bytes := m.bytes + bBytes.size.toUInt64
          files := m.files.push {
            path := bundleRel
            bytes := bBytes.size.toUInt64
            sha256 := bSha
            executable := false
          }
        }
    if let .error e := validateManifest m then
      return .error e
    let mJson := m.toJson
    IO.FS.writeFile manifestFile (renderCompact mJson)
    return .ok mJson
  | "check_source" =>
    let some rawSrc := source? | return .error "Source workspace unavailable"
    let (src, roots) ← match ← resolveCanonicalSource rawSrc with
      | .ok v => pure v
      | .error e => return .error e
    if !(← manifestFile.pathExists) then return .error "Manifest not found"
    let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
    let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
    let some expected := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
    let (omitList, inclList) ← loadSelection area
    match ← walkWorkspace src roots omitList inclList with
    | .error e => return .error e
    | .ok cur =>
      let expPlain := expected.files.filter (fun f => !f.path.endsWith ".transfer-git.bundle")
      if cur.files != expPlain || cur.links != expected.links then
        return .error "Source files changed after preparation; cancel and prepare again"
      for bEntry in expected.files.filter (fun f => f.path.endsWith ".transfer-git.bundle") do
        let repoRel :=
          if bEntry.path == ".transfer-git.bundle" then ""
          else (bEntry.path.dropEnd 21).toString
        let repoDir := if repoRel.isEmpty then src else src / repoRel
        let refsOut ← IO.Process.output { cmd := "git", args := #["-C", repoDir.toString, "show-ref"] }
        let bundleOut ← IO.Process.output { cmd := "git", args := #["bundle", "list-heads", (root / bEntry.path).toString] }
        if refsOut.exitCode != 0 || bundleOut.exitCode != 0 then
          return .error "Git source is no longer available"
        if normalizeShowRefLines refsOut.stdout != normalizeShowRefLines bundleOut.stdout then
          return .error "Git history changed after preparation; prepare again"
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
      let sz ← match ← confinedCheckpointPath root f.path with
        | .ok fp =>
          if ← fp.pathExists then
            match ← fp.metadata |>.toBaseIO with
            | .ok md => pure (min md.byteSize f.bytes)
            | .error _ => pure 0
          else pure 0
        | .error _ => pure 0
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
    if dataB64.length > transferBlockBytes * 2 then
      return .error "Oversized block"
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
      if let .error e ← restoreManifestLinks root m.links then
        return .error e
      let mut idx : Nat := 0
      for f in m.files do
        let fname := (f.path.splitOn "/").getLastD ""
        if fname == ".transfer-git.bundle" then
          let bundlePath ← match ← confinedCheckpointPath root f.path with
            | .ok v => pure v
            | .error e => return .error e
          let some working := bundlePath.parent
            | return .error "Invalid repository path"
          let tmpRepo := area / s!"git-restore-{idx}"
          if ← tmpRepo.pathExists then
            let _ ← IO.Process.output { cmd := "rm", args := #["-rf", tmpRepo.toString] }
          if let .error e ← runGitCmd area #["clone", "--mirror", bundlePath.toString, tmpRepo.toString] then
            return .error e
          if let .error e ← runGitCmd tmpRepo #["config", "--remove-section", "remote.origin"] then
            return .error e
          let dotGit := working / ".git"
          if !(← dotGit.pathExists) then
            IO.FS.rename tmpRepo dotGit
          if let .error e ← runGitCmd working #["config", "core.bare", "false"] then
            return .error e
          if let .error e ← runGitCmd working #["reset", "--mixed", "HEAD"] then
            return .error e
        idx := idx + 1
      IO.FS.writeFile (area / "verified") mDigest
    return .ok (.obj #[
      ("root", .str root.toString),
      ("digest", .str mDigest),
      ("bytes", JVal.uint64 m.bytes),
      ("files", JVal.nat m.files.size),
      ("links", JVal.nat m.links.size)
    ])
  | _ => return .error s!"Unknown transfer operation '{opName}'"

private def padZeroBytes (n : Nat) : ByteArray := Id.run do
  let mut b := ByteArray.emptyWithCapacity n
  for _ in [0:n] do
    b := b.push 0
  return b

private def writeAsciiField (buf : ByteArray) (off width : Nat) (s : String) : ByteArray := Id.run do
  let sb := s.toUTF8
  let mut out := buf
  let lim := min width sb.size
  for i in [0:lim] do
    out := out.set! (off + i) (sb.get! i)
  return out

private def formatOctal (val : UInt64) (digits : Nat) : String := Id.run do
  let mut v := val
  let mut chars : Array Char := #[]
  for _ in [0:digits] do
    let d := (v % 8).toNat
    chars := chars.push (Char.ofNat ('0'.toNat + d))
    v := v / 8
  return String.ofList chars.reverse.toList

private def writeOctalField (buf : ByteArray) (off width : Nat) (val : UInt64) : ByteArray := Id.run do
  let oct := formatOctal val (width - 1)
  let mut out := writeAsciiField buf off (width - 1) oct
  out := out.set! (off + width - 1) 0
  return out

private def finalizeTarChecksum (hdr0 : ByteArray) : ByteArray := Id.run do
  let mut hdr := hdr0
  for i in [148:156] do
    hdr := hdr.set! i 32
  let mut sum : UInt64 := 0
  for i in [0:512] do
    sum := sum + (hdr.get! i).toUInt64
  let chk := formatOctal sum 6
  hdr := writeAsciiField hdr 148 6 chk
  hdr := hdr.set! 154 0
  hdr := hdr.set! 155 32
  return hdr

private def makeTarHeaderBlock (name : String) (typeFlag : UInt8) (mode : UInt64) (size : UInt64) : ByteArray := Id.run do
  let mut hdr := padZeroBytes 512
  hdr := writeAsciiField hdr 0 100 name
  hdr := writeOctalField hdr 100 8 mode
  hdr := writeOctalField hdr 108 8 0
  hdr := writeOctalField hdr 116 8 0
  hdr := writeOctalField hdr 124 12 size
  hdr := writeOctalField hdr 136 12 0
  hdr := hdr.set! 156 typeFlag
  hdr := writeAsciiField hdr 257 6 "ustar"
  hdr := hdr.set! 262 0
  hdr := writeAsciiField hdr 263 2 "00"
  return finalizeTarChecksum hdr

private def appendTarEntry (tarBuf : ByteArray) (path : String) (executable : Bool) (content : ByteArray) : ByteArray := Id.run do
  let mut out := tarBuf
  let pathBytes := path.toUTF8
  if pathBytes.size > 99 then
    let longPayload := pathBytes.push 0
    let longHdr := makeTarHeaderBlock "././@LongLink" 76 0o644 longPayload.size.toUInt64
    out := out ++ longHdr ++ longPayload
    let remL := (512 - (longPayload.size % 512)) % 512
    if remL > 0 then
      out := out ++ padZeroBytes remL
  let shortName := if pathBytes.size > 99 then (String.fromUTF8? (pathBytes.extract 0 99) |>.getD "entry") else path
  let mode : UInt64 := if executable then 0o700 else 0o600
  let hdr := makeTarHeaderBlock shortName 48 mode content.size.toUInt64
  out := out ++ hdr ++ content
  let remC := (512 - (content.size % 512)) % 512
  if remC > 0 then
    out := out ++ padZeroBytes remC
  return out

private def parseOctalField? (hdr : ByteArray) (off width : Nat) : Option UInt64 := Id.run do
  if off + width > hdr.size then return none
  if (hdr.get! off &&& 0x80) != 0 then
    -- Base-256 GNU binary size encoding
    let mut acc : UInt64 := (hdr.get! off &&& 0x7F).toUInt64
    for i in [1:width] do
      acc := (acc <<< 8) ||| (hdr.get! (off + i)).toUInt64
    return some acc
  let mut i := off
  let endOff := off + width
  while i < endOff && (hdr.get! i == 32 || hdr.get! i == 0) do
    i := i + 1
  if i == endOff then return some 0
  let mut acc : UInt64 := 0
  let mut sawDigit := false
  while i < endOff do
    let b := hdr.get! i
    if b == 0 || b == 32 then break
    if b < 48 || b > 55 then return none
    sawDigit := true
    acc := acc * 8 + (b - 48).toUInt64
    i := i + 1
  return if sawDigit then some acc else some 0

private def parseCStringField (hdr : ByteArray) (off width : Nat) : Option String := Id.run do
  let mut endIdx := off
  let lim := min hdr.size (off + width)
  while endIdx < lim && hdr.get! endIdx != 0 do
    endIdx := endIdx + 1
  String.fromUTF8? (hdr.extract off endIdx)

private def isAllZeroBlock (hdr : ByteArray) : Bool := Id.run do
  for i in [0:hdr.size] do
    if hdr.get! i != 0 then return false
  return true

private def parsePaxPath? (paxBytes : ByteArray) : Option String := Id.run do
  let some text := String.fromUTF8? paxBytes | return none
  let mut found : Option String := none
  for line in text.splitOn "\n" do
    if let _lenPart :: rest := line.splitOn " " then
      let kv := String.intercalate " " rest
      if kv.startsWith "path=" then
        found := some (kv.drop 5).toString
  return found

/-- Parse an uncompressed `tar` byte stream directly in Lean (handling GNU `@LongLink`, PAX `x` headers,
    and ustar `prefix`), returning `(path, contentBytes)` for every regular file and failing closed on
    any non-regular entry or truncated archive. -/
private def parseTarRegularEntries (tarBytes : ByteArray) : Except String (Array (String × ByteArray)) := Id.run do
  let mut off : Nat := 0
  let mut pendingLongName? : Option String := none
  let mut entries : Array (String × ByteArray) := #[]
  while off + 512 <= tarBytes.size do
    let hdr := tarBytes.extract off (off + 512)
    off := off + 512
    if isAllZeroBlock hdr then
      break
    let some szU64 := parseOctalField? hdr 124 12
      | return .error "Corrupt tar entry size"
    let sz := szU64.toNat
    if off + sz > tarBytes.size then
      return .error "Archive entry truncated"
    let payload := tarBytes.extract off (off + sz)
    let padded := sz + ((512 - (sz % 512)) % 512)
    if off + padded > tarBytes.size then
      return .error "Archive block padding truncated"
    off := off + padded
    let tf := hdr.get! 156
    if tf == 76 then -- 'L' GNU LongLink
      let mut endIdx := payload.size
      while endIdx > 0 && payload.get! (endIdx - 1) == 0 do
        endIdx := endIdx - 1
      let some lname := String.fromUTF8? (payload.extract 0 endIdx)
        | return .error "Invalid archive path"
      pendingLongName? := some lname
    else if tf == 120 then -- 'x' PAX extended header
      if let some pname := parsePaxPath? payload then
        pendingLongName? := some pname
    else if tf == 103 then -- 'g' global PAX header
      pure ()
    else if tf == 0 || tf == 48 then -- '\0' or '0' regular file
      let rawName ← match pendingLongName? with
        | some ln => pure ln
        | none =>
          let some baseName := parseCStringField hdr 0 100
            | return .error "Invalid archive path"
          let pfx := (parseCStringField hdr 345 155).getD ""
          pure (if pfx.isEmpty then baseName else s!"{pfx}/{baseName}")
      pendingLongName? := none
      let clean := if rawName.startsWith "./" then (rawName.drop 2).toString else rawName
      entries := entries.push (clean, payload)
    else
      return .error "Archive contains a non-regular entry"
  return .ok entries

/-- Pack verified source checkpoint `area` into a `tar + zstd` archive (`ByteArray`) without invoking `tar` CLI. -/
def packTransferArchive (area : System.FilePath) : IO (Except String ByteArray) := do
  let manifestFile := area / "manifest.json"
  if !(← manifestFile.pathExists) then
    return .error "Transfer checkpoint not found"
  let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
  let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
  let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
  let root := area / "workspace"
  let mut tarBuf := ByteArray.empty
  for f in m.files do
    let fp ← match ← confinedCheckpointPath root f.path with
      | .ok v => pure v
      | .error e => return .error e
    let .ok bytes ← IO.FS.readBinFile fp |>.toBaseIO
      | return .error s!"Checkpoint file missing: {f.path}"
    if bytes.size.toUInt64 != f.bytes then
      return .error s!"Checkpoint file changed: {f.path}"
    tarBuf := appendTarEntry tarBuf f.path f.executable bytes
  tarBuf := tarBuf ++ padZeroBytes 1024
  let nonce ← newUuidV4
  let rawTarFile := area / s!".pack-raw-{nonce}.tar"
  let outArchive := area / s!".pack-out-{nonce}.tar.zst"
  IO.FS.writeBinFile rawTarFile tarBuf
  let res ← IO.Process.output { cmd := "zstd", args := #["-3", "-q", "-f", "-o", outArchive.toString, rawTarFile.toString] }
  try IO.FS.removeFile rawTarFile catch _ => pure ()
  if res.exitCode != 0 then
    try IO.FS.removeFile outArchive catch _ => pure ()
    return .error s!"Archive pack failed: {res.stderr.trimAscii}"
  let .ok archiveBytes ← IO.FS.readBinFile outArchive |>.toBaseIO
    | try IO.FS.removeFile outArchive catch _ => pure ()
      return .error "Failed reading packed archive"
  try IO.FS.removeFile outArchive catch _ => pure ()
  return .ok archiveBytes

/-- Unpack a `tar + zstd` archive into staged destination checkpoint `area`, enforcing manifest confinement
    and parsing tar blocks directly in Lean (rejecting non-regular entries and path directives). -/
def unpackTransferArchive (area : System.FilePath) (archiveBytes : ByteArray) : IO (Except String UInt64) := do
  if ← (area / "verified").pathExists then
    return .error "Checkpoint already sealed"
  let manifestFile := area / "manifest.json"
  if !(← manifestFile.pathExists) then
    return .error "Stage destination manifest first"
  let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
  let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
  let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
  let mut wanted : Std.HashMap String TransferEntry := {}
  for f in m.files do
    wanted := wanted.insert f.path f
  let root := area / "workspace"
  IO.FS.createDirAll root
  let nonce ← newUuidV4
  let inArchive := area / s!".unpack-in-{nonce}.tar.zst"
  let outTar := area / s!".unpack-out-{nonce}.tar"
  IO.FS.writeBinFile inArchive archiveBytes
  let decRes ← IO.Process.output { cmd := "zstd", args := #["-d", "-q", "-f", "-o", outTar.toString, inArchive.toString] }
  try IO.FS.removeFile inArchive catch _ => pure ()
  if decRes.exitCode != 0 then
    try IO.FS.removeFile outTar catch _ => pure ()
    return .error s!"Invalid tar+zstd archive: {decRes.stderr.trimAscii}"
  let .ok tarBytes ← IO.FS.readBinFile outTar |>.toBaseIO
    | try IO.FS.removeFile outTar catch _ => pure ()
      return .error "Failed reading decompressed tar archive"
  try IO.FS.removeFile outTar catch _ => pure ()
  let entries ← match parseTarRegularEntries tarBytes with
    | .ok es => pure es
    | .error e => return .error e
  let mut written : UInt64 := 0
  for (clean, bytes) in entries do
    let some f := wanted.get? clean
      | return .error s!"Archive entry absent from manifest: {clean}"
    if bytes.size.toUInt64 != f.bytes then
      return .error s!"Archive entry has the wrong size: {clean}"
    let dst ← match ← confinedCheckpointPath root clean with
      | .ok v => pure v
      | .error e => return .error e
    if let some par := dst.parent then IO.FS.createDirAll par
    IO.FS.writeBinFile dst bytes
    written := written + bytes.size.toUInt64
  return .ok written

end OrbNode.Transfer
