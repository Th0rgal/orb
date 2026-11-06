/-
  OrbNode.Transfer: Machine-Transfer Checkpoints (`shared/machine_transfer.rs`) & `tar+zstd`
  Bulk-Copy Pack/Unpack (`src/machine_transfer_archive.rs`) for `sandboxed-node`.
  Supports portable workspace symlinks (`links` + `skipped`), Git repository `.transfer-git.bundle`
  preservation & restoration, overlap/escape confinement, and block/bulk resume.
-/
import Std.Data.HashMap
import LeanSys.Posix
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

/-- Compute `(byteSize, lowercaseHexSha256)` of `fp` via streaming `sha256sum` when large (`> 4 MiB`)
    or direct `sha256Bytes` for small files so multi-GiB checkpoint files never require whole-file RAM buffers! -/
private def streamFileSizeAndSha256 (fp : System.FilePath) : IO (Except String (UInt64 × String)) := do
  let .ok md ← fp.metadata |>.toBaseIO
    | return .error s!"Failed stating {fp}"
  if md.byteSize <= 4 * 1024 * 1024 then
    let .ok bytes ← IO.FS.readBinFile fp |>.toBaseIO
      | return .error s!"Failed reading {fp}"
    return .ok (bytes.size.toUInt64, bytesToHexLower (sha256Bytes bytes))
  match ← (IO.Process.output { cmd := "sha256sum", args := #[fp.toString] }).toBaseIO with
  | .ok out =>
    if out.exitCode == 0 then
      let hex := ((out.stdout.splitOn " ").headD "").trimAscii.toString.toLower
      if hex.length == 64 then
        let .ok mdAfter ← fp.metadata |>.toBaseIO
          | return .error s!"Failed stating {fp}"
        if mdAfter.byteSize == md.byteSize && mdAfter.modified == md.modified then
          return .ok (md.byteSize, hex)
        else
          return .error s!"File changed during hash: {fp}"
    let .ok bytes ← IO.FS.readBinFile fp |>.toBaseIO
      | return .error s!"Failed reading {fp}"
    return .ok (bytes.size.toUInt64, bytesToHexLower (sha256Bytes bytes))
  | .error _ =>
    let .ok bytes ← IO.FS.readBinFile fp |>.toBaseIO
      | return .error s!"Failed reading {fp}"
    return .ok (bytes.size.toUInt64, bytesToHexLower (sha256Bytes bytes))

/-- Copy `src` to `dst` in `64 KiB` streaming chunks while tracking total bytes copied. -/
private def streamCopyFile (src dst : System.FilePath) : IO (Except String UInt64) := do
  let .ok hIn ← (IO.FS.Handle.mk src .read).toBaseIO
    | return .error s!"Failed opening {src}"
  let .ok hOut ← (IO.FS.Handle.mk dst .write).toBaseIO
    | return .error s!"Failed creating {dst}"
  let mut copied : UInt64 := 0
  while true do
    let .ok chunk ← (hIn.read 65536).toBaseIO
      | return .error s!"Failed reading {src}"
    if chunk.isEmpty then break
    let .ok () ← (hOut.write chunk).toBaseIO
      | return .error s!"Failed writing {dst}"
    copied := copied + chunk.size.toUInt64
  discard <| (hOut.flush).toBaseIO
  return .ok copied

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
        let (szBytes, sha) ← match ← streamFileSizeAndSha256 item.path with
          | .ok v => pure v
          | .error _ => return .error s!"Failed reading {rel}"
        let afterSt ← statPath item.path.toString
        let afterMd? ← (item.path.metadata |>.toBaseIO).map (fun r => r.toOption)
        let changed :=
          !afterSt.exists_ || afterSt.isSymlink || !afterSt.isReg ||
          match beforeMd?, afterMd? with
          | some bmd, some amd =>
            amd.byteSize != szBytes || amd.modified != bmd.modified
          | _, _ => true
        if changed then
          return .error s!"File changed during snapshot: {rel}"
        let exec := (st.mode &&& 0o111) != 0
        totalBytes := totalBytes + szBytes
        if totalBytes > maxTransferBytes || files.size + links.size + 1 > maxTransferFiles then
          return .error "Workspace exceeds transfer limit (10 GiB / 50,000 files)"
        files := files.push { path := rel, bytes := szBytes, sha256 := sha, executable := exec }
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
      let copied ← match ← streamCopyFile srcFile dstFile with
        | .ok c => pure c
        | .error _ => return .error s!"Failed copying {f.path}"
      let (dstSz, dstSha) ← match ← streamFileSizeAndSha256 dstFile with
        | .ok v => pure v
        | .error _ => return .error s!"Failed hashing {f.path}"
      if copied != f.bytes || dstSz != f.bytes || dstSha != f.sha256.toLower then
        return .error s!"File changed during snapshot: {f.path}"
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
        let (bSz, bSha) ← match ← streamFileSizeAndSha256 bundleDst with
          | .ok v => pure v
          | .error _ => return .error "Could not read Git bundle"
        if m.bytes + bSz > maxTransferBytes then
          return .error "Git history exceeds transfer size or available disk space"
        m := {
          m with
          bytes := m.bytes + bSz
          files := m.files.push {
            path := bundleRel
            bytes := bSz
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
    let wantLen := min transferBlockBytes (f.bytes.toNat - off.toNat)
    let slice ← if wantLen == 0 then
      pure ByteArray.empty
    else
      match ← LeanSys.Posix.withFd fp.toString 0 (fun fd => do
        let b ← LeanSys.Posix.preadByteArray fd off wantLen
        return .ok b
      ) with
      | .ok b => pure b
      | .error _ => return .error "Failed reading file"
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
    if chunk.isEmpty then
      if !(← fp.pathExists) then
        IO.FS.writeBinFile fp ByteArray.empty
    else
      -- Page-aligned `MAP_SHARED` positional write (`LeanSys.Posix.mmapMapShared` + `mmapRegionWrite`)
      -- so writing a 1 MiB block at `off` is strictly `O(1)` (`1 MiB` page window) with zero whole-file reads/rewrites!
      let writeRes ← LeanSys.Posix.withFd fp.toString 1 (fun fd => do
        let curSz ← match ← LeanSys.Posix.fstatSize fd with
          | .ok sz => pure sz.toNat
          | .error e => return .error e
        let endOff := off.toNat + chunk.size
        if curSz < endOff then
          if let .error e ← LeanSys.Posix.ftruncateFd fd endOff then
            return .error e
        let pageBase : Nat := (off.toNat / 4096) * 4096
        let relOff : Nat := off.toNat - pageBase
        let mapLen : Nat := relOff + chunk.size
        let reg ← match ← LeanSys.Posix.mmapMapShared fd mapLen pageBase false with
          | .ok r => pure r
          | .error e => return .error e
        try
          let _ ← match ← LeanSys.Posix.mmapRegionWrite reg relOff chunk with
            | .ok n => pure n
            | .error e => return .error e
          return .ok ()
        finally
          discard <| LeanSys.Posix.mmapUnmap reg
      )
      match writeRes with
      | .error _ => return .error "Failed writing block"
      | .ok () => pure ()
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
        let (fbSz, fbSha) ← match ← streamFileSizeAndSha256 fp with
          | .ok v => pure v
          | .error _ => return .error s!"Checkpoint mismatch: {f.path}"
        if fbSz != f.bytes || fbSha != f.sha256.toLower then
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

/-- Encode a 12-byte tar `size` field (`off = 124..136`), using standard 11-digit ASCII octal for
    `val < 8 GiB` (`8589934592`) and GNU base-256 (`0x80` high-bit prefix + big-endian 64-bit `UInt64`)
    for `val >= 8 GiB` so checkpoints up to `maxTransferBytes` (`10 GiB`) roundtrip losslessly! -/
def writeTarSizeField (buf : ByteArray) (off : Nat) (val : UInt64) : ByteArray := Id.run do
  if val < (8589934592 : UInt64) then
    return writeOctalField buf off 12 val
  let mut out := buf
  out := out.set! off 0x80
  out := out.set! (off + 1) 0
  out := out.set! (off + 2) 0
  out := out.set! (off + 3) 0
  for i in [0:8] do
    let shift : UInt64 := ((7 - i) * 8).toUInt64
    out := out.set! (off + 4 + i) ((val >>> shift) &&& 0xFF).toUInt8
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

def makeTarHeaderBlock (name : String) (typeFlag : UInt8) (mode : UInt64) (size : UInt64) : ByteArray := Id.run do
  let mut hdr := padZeroBytes 512
  hdr := writeAsciiField hdr 0 100 name
  hdr := writeOctalField hdr 100 8 mode
  hdr := writeOctalField hdr 108 8 0
  hdr := writeOctalField hdr 116 8 0
  hdr := writeTarSizeField hdr 124 size
  hdr := writeOctalField hdr 136 12 0
  hdr := hdr.set! 156 typeFlag
  hdr := writeAsciiField hdr 257 6 "ustar"
  hdr := hdr.set! 262 0
  hdr := writeAsciiField hdr 263 2 "00"
  return finalizeTarChecksum hdr

def parseTarSizeField? (hdr : ByteArray) (off width : Nat) : Option UInt64 := Id.run do
  if off + width > hdr.size || width < 12 then return none
  if (hdr.get! off &&& 0x80) != 0 then
    -- Base-256 GNU binary size encoding: require high bytes `off+1 .. off+(width-8)` to be 0 so UInt64 cannot overflow!
    if hdr.get! off != 0x80 then return none
    for j in [1 : width - 8] do
      if hdr.get! (off + j) != 0 then return none
    let mut acc : UInt64 := 0
    for j in [width - 8 : width] do
      acc := (acc <<< 8) ||| (hdr.get! (off + j)).toUInt64
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

private def readExactHandle (h : IO.FS.Handle) (n : Nat) : IO (Option ByteArray) := do
  if n == 0 then return some ByteArray.empty
  let mut acc := ByteArray.emptyWithCapacity n
  while acc.size < n do
    let want := min 65536 (n - acc.size)
    let .ok chunk ← (h.read (USize.ofNat want)).toBaseIO
      | return none
    if chunk.isEmpty then
      return if acc.isEmpty then some ByteArray.empty else none
    acc := acc ++ chunk
  return some acc

private def discardExactHandle (h : IO.FS.Handle) (n : Nat) : IO Bool := do
  let mut rem := n
  while rem > 0 do
    let want := min 65536 rem
    let .ok chunk ← (h.read (USize.ofNat want)).toBaseIO
      | return false
    if chunk.isEmpty then return false
    rem := rem - chunk.size
  return true

/-- Stream a single manifest file into open tar handle `hTar` in `64 KiB` chunks (zero whole-file RAM allocation). -/
private def writeTarEntryStreaming
    (hTar : IO.FS.Handle) (path : String) (executable : Bool)
    (srcPath : System.FilePath) (expectedBytes : UInt64) : IO (Except String Unit) := do
  let .ok md ← srcPath.metadata |>.toBaseIO
    | return .error s!"Checkpoint file missing: {path}"
  if md.byteSize != expectedBytes then
    return .error s!"Checkpoint file changed: {path}"
  let pathBytes := path.toUTF8
  if pathBytes.size > 99 then
    let longPayload := pathBytes.push 0
    let longHdr := makeTarHeaderBlock "././@LongLink" 76 0o644 longPayload.size.toUInt64
    let .ok () ← (hTar.write longHdr).toBaseIO | return .error "Failed writing tar LongLink header"
    let .ok () ← (hTar.write longPayload).toBaseIO | return .error "Failed writing tar LongLink payload"
    let remL := (512 - (longPayload.size % 512)) % 512
    if remL > 0 then
      let .ok () ← (hTar.write (padZeroBytes remL)).toBaseIO | return .error "Failed writing tar padding"
  let shortName := if pathBytes.size > 99 then (String.fromUTF8? (pathBytes.extract 0 99) |>.getD "entry") else path
  let mode : UInt64 := if executable then 0o700 else 0o600
  let hdr := makeTarHeaderBlock shortName 48 mode expectedBytes
  let .ok () ← (hTar.write hdr).toBaseIO | return .error "Failed writing tar entry header"
  let .ok hIn ← (IO.FS.Handle.mk srcPath .read).toBaseIO
    | return .error s!"Checkpoint file missing: {path}"
  let mut copied : UInt64 := 0
  while copied < expectedBytes do
    let want := min 65536 (expectedBytes - copied).toNat
    let .ok chunk ← (hIn.read (USize.ofNat want)).toBaseIO
      | return .error s!"Failed reading checkpoint file: {path}"
    if chunk.isEmpty then
      return .error s!"Checkpoint file changed: {path}"
    let .ok () ← (hTar.write chunk).toBaseIO
      | return .error "Failed writing tar entry payload"
    copied := copied + chunk.size.toUInt64
  if copied != expectedBytes then
    return .error s!"Checkpoint file changed: {path}"
  let remC := ((512 : UInt64) - (expectedBytes % 512)) % 512
  if remC > 0 then
    let .ok () ← (hTar.write (padZeroBytes remC.toNat)).toBaseIO
      | return .error "Failed writing tar block padding"
  return .ok ()

/-- Stream-unpack an uncompressed `tar` file on disk (`outTar`) into `root` in `64 KiB` chunks
    (handling GNU `@LongLink`, PAX `x` headers, GNU base-256 `>= 8 GiB` sizes, and ustar `prefix`),
    rejecting non-regular entries, unlisted files, wrong sizes, or cumulative bytes `> maxTransferBytes`! -/
private def streamUnpackTarFile
    (outTar : System.FilePath) (root : System.FilePath)
    (wanted : Std.HashMap String TransferEntry) : IO (Except String UInt64) := do
  let .ok hTar ← (IO.FS.Handle.mk outTar .read).toBaseIO
    | return .error "Failed opening decompressed tar archive"
  let mut pendingLongName? : Option String := none
  let mut written : UInt64 := 0
  while true do
    let some hdr ← readExactHandle hTar 512
      | return .error "Archive header truncated"
    if hdr.isEmpty || isAllZeroBlock hdr then
      break
    let some szU64 := parseTarSizeField? hdr 124 12
      | return .error "Corrupt tar entry size"
    let tf := hdr.get! 156
    let padLen : Nat := (((512 : UInt64) - (szU64 % 512)) % 512).toNat
    if tf == 76 then -- 'L' GNU LongLink
      if szU64 > 65536 then return .error "Oversized tar LongLink path"
      let some payload ← readExactHandle hTar szU64.toNat
        | return .error "Archive LongLink truncated"
      if payload.size != szU64.toNat then return .error "Archive LongLink truncated"
      if !(← discardExactHandle hTar padLen) then return .error "Archive block padding truncated"
      let mut endIdx := payload.size
      while endIdx > 0 && payload.get! (endIdx - 1) == 0 do
        endIdx := endIdx - 1
      let some lname := String.fromUTF8? (payload.extract 0 endIdx)
        | return .error "Invalid archive path"
      pendingLongName? := some lname
    else if tf == 120 then -- 'x' PAX extended header
      if szU64 > 1048576 then return .error "Oversized PAX extended header"
      let some payload ← readExactHandle hTar szU64.toNat
        | return .error "Archive PAX header truncated"
      if payload.size != szU64.toNat then return .error "Archive PAX header truncated"
      if !(← discardExactHandle hTar padLen) then return .error "Archive block padding truncated"
      if let some pname := parsePaxPath? payload then
        pendingLongName? := some pname
    else if tf == 103 then -- 'g' global PAX header
      if szU64 > 1048576 then return .error "Oversized global PAX header"
      if !(← discardExactHandle hTar (szU64.toNat + padLen)) then
        return .error "Archive global PAX header truncated"
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
      let some f := wanted.get? clean
        | return .error s!"Archive entry absent from manifest: {clean}"
      if szU64 != f.bytes then
        return .error s!"Archive entry has the wrong size: {clean}"
      if written + szU64 > maxTransferBytes then
        return .error "Archive exceeds 10 GiB transfer limit"
      let dst ← match ← confinedCheckpointPath root clean with
        | .ok v => pure v
        | .error e => return .error e
      if let some par := dst.parent then IO.FS.createDirAll par
      let .ok hDst ← (IO.FS.Handle.mk dst .write).toBaseIO
        | return .error s!"Failed creating destination file: {clean}"
      let mut rem : UInt64 := szU64
      while rem > 0 do
        let want := min 65536 rem.toNat
        let .ok chunk ← (hTar.read (USize.ofNat want)).toBaseIO
          | return .error s!"Archive entry truncated: {clean}"
        if chunk.isEmpty then
          return .error s!"Archive entry truncated: {clean}"
        let .ok () ← (hDst.write chunk).toBaseIO
          | return .error s!"Failed writing destination file: {clean}"
        rem := rem - chunk.size.toUInt64
      discard <| (hDst.flush).toBaseIO
      if !(← discardExactHandle hTar padLen) then
        return .error "Archive block padding truncated"
      written := written + szU64
    else
      return .error "Archive contains a non-regular entry"
  return .ok written

/-- Pack verified source checkpoint `area` into a compressed `tar + zstd` file on disk (`outArchive`)
    using `64 KiB` streaming chunks (zero whole-archive `ByteArray` in memory!). -/
def packTransferArchiveToFile (area : System.FilePath) : IO (Except String System.FilePath) := do
  let manifestFile := area / "manifest.json"
  if !(← manifestFile.pathExists) then
    return .error "Transfer checkpoint not found"
  let .ok raw ← IO.FS.readFile manifestFile |>.toBaseIO | return .error "Failed reading manifest"
  let .ok jv := OrbBin.Json.parse raw | return .error "Corrupt manifest"
  let some m := TransferManifest.fromJson? jv | return .error "Corrupt manifest"
  let root := area / "workspace"
  let nonce ← newUuidV4
  let rawTarFile := area / s!".pack-raw-{nonce}.tar"
  let outArchive := area / s!".pack-out-{nonce}.tar.zst"
  let packStep : IO (Except String Unit) := do
    let .ok hTar ← (IO.FS.Handle.mk rawTarFile .write).toBaseIO
      | return .error "Failed creating temporary tar file"
    for f in m.files do
      let fp ← match ← confinedCheckpointPath root f.path with
        | .ok v => pure v
        | .error e => return .error e
      if let .error err ← writeTarEntryStreaming hTar f.path f.executable fp f.bytes then
        return .error err
    let .ok () ← (hTar.write (padZeroBytes 1024)).toBaseIO
      | return .error "Failed finalizing tar trailer"
    discard <| (hTar.flush).toBaseIO
    return .ok ()
  if let .error err ← packStep then
    try IO.FS.removeFile rawTarFile catch _ => pure ()
    return .error err
  let res ← IO.Process.output { cmd := "zstd", args := #["-3", "-q", "-f", "-o", outArchive.toString, rawTarFile.toString] }
  try IO.FS.removeFile rawTarFile catch _ => pure ()
  if res.exitCode != 0 then
    try IO.FS.removeFile outArchive catch _ => pure ()
    return .error s!"Archive pack failed: {res.stderr.trimAscii}"
  return .ok outArchive

/-- Pack verified source checkpoint `area` into a `tar + zstd` archive (`ByteArray`) without invoking `tar` CLI. -/
def packTransferArchive (area : System.FilePath) : IO (Except String ByteArray) := do
  let outArchive ← match ← packTransferArchiveToFile area with
    | .ok p => pure p
    | .error e => return .error e
  let .ok archiveBytes ← IO.FS.readBinFile outArchive |>.toBaseIO
    | try IO.FS.removeFile outArchive catch _ => pure ()
      return .error "Failed reading packed archive"
  try IO.FS.removeFile outArchive catch _ => pure ()
  return .ok archiveBytes

/-- Unpack a `tar + zstd` archive file on disk (`inArchive`) into staged destination checkpoint `area`,
    streaming tar blocks in `64 KiB` chunks and enforcing manifest & size bounds so a highly compressible
    multi-GiB `.tar.zst` payload never expands into daemon RAM! -/
def unpackTransferArchiveFromFile (area : System.FilePath) (inArchive : System.FilePath) : IO (Except String UInt64) := do
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
  let outTar := area / s!".unpack-out-{nonce}.tar"
  let decRes ← IO.Process.output { cmd := "zstd", args := #["-d", "-q", "-f", "-o", outTar.toString, inArchive.toString] }
  if decRes.exitCode != 0 then
    try IO.FS.removeFile outTar catch _ => pure ()
    return .error s!"Invalid tar+zstd archive: {decRes.stderr.trimAscii}"
  let maxTarAllowance : UInt64 := m.bytes + (m.files.size.toUInt64 + 8) * 4096 + 67108864
  if let .ok md ← outTar.metadata |>.toBaseIO then
    if md.byteSize > maxTarAllowance || md.byteSize > maxTransferBytes + 67108864 then
      try IO.FS.removeFile outTar catch _ => pure ()
      return .error "Decompressed tar archive exceeds staged manifest allowance"
  let res ← streamUnpackTarFile outTar root wanted
  try IO.FS.removeFile outTar catch _ => pure ()
  return res

/-- Unpack an in-memory `tar + zstd` `ByteArray` into staged destination checkpoint `area`. -/
def unpackTransferArchive (area : System.FilePath) (archiveBytes : ByteArray) : IO (Except String UInt64) := do
  IO.FS.createDirAll area
  let nonce ← newUuidV4
  let inArchive := area / s!".unpack-in-{nonce}.tar.zst"
  IO.FS.writeBinFile inArchive archiveBytes
  let res ← unpackTransferArchiveFromFile area inArchive
  try IO.FS.removeFile inArchive catch _ => pure ()
  return res

end OrbNode.Transfer
