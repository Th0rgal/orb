/-
  OrbNode.AutoUpdate: Core-Driven Idle Auto-Updater, Automatic Rollback, & Declarative Harness CLI Bundle Sync.
  - Pure eligibility gates (`shouldApplyBinaryUpdate`, `shouldRollbackStartup`, `findDriftedCliHarnesses`).
  - Atomic binary swap keeping `.prev` backup (direct swap when writable, or `<stateDir>/bin/sandboxed-node`
    trampoline under `ProtectSystem=strict`).
  - Automatic rollback on startup crash or first-heartbeat timeout, quarantining the failed `sha256`
    and reporting the rollback reason to Core.
  - Declarative harness CLI bundle resync (`agy`, `claude`, `codex`, `opencode`) when idle and drifted.
  (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbNode.Posix

namespace OrbNode.AutoUpdate

open LeanSys.Auth
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient

/-- Check whether `s` is a valid 64-character lowercase hex SHA-256 digest. -/
def isValidSha256Hex (s : String) : Bool :=
  s.length == 64 && s.toList.all fun c =>
    ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f')

/-- Normalize architecture names (`amd64` -> `x86_64`, `arm64` -> `aarch64`). -/
def normalizeArch (raw : String) : String :=
  match raw.trimAscii.toString.toLower with
  | "x86_64" | "amd64" => "x86_64"
  | "aarch64" | "arm64" => "aarch64"
  | other => other

/-- Detect current host architecture via `uname -m`. -/
def detectHostArch : IO String := do
  if let some override ← getEnvNonEmpty "SANDBOXED_NODE_ARCH_OVERRIDE" then
    return normalizeArch override
  match ← (IO.Process.output { cmd := "uname", args := #["-m"] }).toBaseIO with
  | .ok out =>
    if out.exitCode == 0 then return normalizeArch out.stdout
    else return "x86_64"
  | .error _ => return "x86_64"

/-- Verify Linux 64-bit little-endian ELF header and `e_machine` (`0x003e` for `x86_64`, `0x00b7` for `aarch64`). -/
def verifyLinuxElfArch (bytes : ByteArray) (arch : String) : Bool :=
  if bytes.size < 20 then false
  else
    let magicOk :=
      bytes.get! 0 == 0x7f && bytes.get! 1 == 0x45 &&
      bytes.get! 2 == 0x4c && bytes.get! 3 == 0x46 &&
      bytes.get! 4 == 0x02 && bytes.get! 5 == 0x01
    let machLo := bytes.get! 18
    let machHi := bytes.get! 19
    let machOk :=
      match normalizeArch arch with
      | "x86_64" => machLo == 0x3e && machHi == 0x00
      | "aarch64" => machLo == 0xb7 && machHi == 0x00
      | _ => false
    magicOk && machOk

structure BinaryReleaseSpec where
  name      : String
  sha256    : String
  url       : String
  sizeBytes : UInt64 := 0
  arch      : String := "x86_64"
  deriving Repr, BEq, Inhabited

structure CliHarnessSpec where
  name    : String
  bin     : String
  version : String
  url     : String := ""
  sha256  : String := ""
  format  : String := "raw"
  entry   : String := ""
  deriving Repr, BEq, Inhabited

structure CliBundleManifest where
  profile      : String := "default"
  version      : String := ""
  bundleUrl    : String := ""
  bundleSha256 : String := ""
  harnesses    : Array CliHarnessSpec := #[]
  deriving Repr, BEq, Inhabited

structure ReleaseManifest where
  version           : Nat := 1
  buildSha          : String := ""
  nodeBinary?       : Option BinaryReleaseSpec := none
  privdBinary?      : Option BinaryReleaseSpec := none
  cliBundle?        : Option CliBundleManifest := none
  cordoned          : Bool := false
  startupWindowSecs : UInt64 := 90
  deriving Repr, BEq, Inhabited

private def parseBinarySpec? (name : String) (v : JVal) : Option BinaryReleaseSpec := do
  let sha ← v.fieldStr? "sha256"
  let url ← v.fieldStr? "url"
  let shaClean := sha.trimAscii.toString.toLower
  guard (isValidSha256Hex shaClean && !url.trimAscii.toString.isEmpty)
  return {
    name := name
    sha256 := shaClean
    url := url.trimAscii.toString
    sizeBytes := (v.fieldUInt64? "size_bytes").getD 0
    arch := normalizeArch ((v.fieldStr? "arch").getD "x86_64")
  }

def ReleaseManifest.fromJson? (root : JVal) : Option ReleaseManifest := do
  let m := (root.field? "release_manifest").getD root
  let ver := (m.fieldNat? "version").getD 1
  let buildSha := (m.fieldStr? "build_sha").getD ""
  let bins? := m.field? "binaries"
  let nodeBin? := bins?.bind (·.field? "sandboxed-node") >>= parseBinarySpec? "sandboxed-node"
  let privdBin? := bins?.bind (·.field? "orb-privd") >>= parseBinarySpec? "orb-privd"
  let cliBundle? : Option CliBundleManifest :=
    match m.field? "cli_bundle" with
    | some cb =>
      let prof := (cb.fieldStr? "profile").getD "default"
      let cbVer := (cb.fieldStr? "version").getD ""
      let bUrl := (cb.fieldStr? "bundle_url").getD ""
      let bSha := ((cb.fieldStr? "bundle_sha256").getD "").trimAscii.toString.toLower
      let harnesses : Array CliHarnessSpec :=
        match cb.field? "harnesses" >>= JVal.asObj? with
        | some pairs =>
          pairs.filterMap fun (hName, hv) =>
            match hv.fieldStr? "version" with
            | some hVer =>
              let vClean := hVer.trimAscii.toString
              if vClean.isEmpty then none
              else some {
                name := hName
                bin := ((hv.fieldStr? "bin").filter (!·.isEmpty)).getD hName
                version := vClean
                url := ((hv.fieldStr? "url").getD "").trimAscii.toString
                sha256 := ((hv.fieldStr? "sha256").getD "").trimAscii.toString.toLower
                format := ((hv.fieldStr? "format").filter (!·.isEmpty)).getD "raw"
                entry := ((hv.fieldStr? "entry").getD "").trimAscii.toString
              }
            | none => none
        | none => #[]
      if harnesses.isEmpty && bUrl.isEmpty then none
      else some { profile := prof, version := cbVer, bundleUrl := bUrl, bundleSha256 := bSha, harnesses }
    | none => none
  let cordoned := (root.fieldBool? "cordoned").orElse (fun _ => m.fieldBool? "cordoned") |>.getD false
  let winSecs := max 10 ((m.fieldUInt64? "startup_window_secs").getD 90)
  return {
    version := ver
    buildSha := buildSha
    nodeBinary? := nodeBin?
    privdBinary? := privdBin?
    cliBundle? := cliBundle?
    cordoned := cordoned
    startupWindowSecs := winSecs
  }

structure PendingUpdate where
  targetSha256      : String
  prevSha256        : String
  binaryPath        : String
  prevBinaryPath    : String
  stagedMode        : Bool := false
  startedAt         : UInt64 := 0
  startupWindowSecs : UInt64 := 90
  bootAttempts      : Nat := 0
  deriving Repr, BEq, Inhabited

structure AutoUpdateState where
  pending?           : Option PendingUpdate := none
  quarantinedSha256? : Option String := none
  lastRollbackReason? : Option String := none
  lastRollbackAt?    : Option UInt64 := none
  lastUpdateAt?      : Option UInt64 := none
  lastSyncedCliVer?  : Option String := none
  lastError?         : Option String := none
  deriving Repr, BEq, Inhabited

private def optStrJson (v? : Option String) : JVal :=
  match v? with | some s => .str s | none => .null

private def optU64Json (v? : Option UInt64) : JVal :=
  match v? with | some n => .uint64 n | none => .null

def PendingUpdate.toJson (p : PendingUpdate) : JVal :=
  .obj #[
    ("target_sha256", .str p.targetSha256),
    ("prev_sha256", .str p.prevSha256),
    ("binary_path", .str p.binaryPath),
    ("prev_binary_path", .str p.prevBinaryPath),
    ("staged_mode", .bool p.stagedMode),
    ("started_at", .uint64 p.startedAt),
    ("startup_window_secs", .uint64 p.startupWindowSecs),
    ("boot_attempts", .nat p.bootAttempts)
  ]

def PendingUpdate.fromJson? (v : JVal) : Option PendingUpdate := do
  let targetSha ← v.fieldStr? "target_sha256"
  let binPath ← v.fieldStr? "binary_path"
  guard (isValidSha256Hex targetSha && !binPath.isEmpty)
  return {
    targetSha256 := targetSha
    prevSha256 := (v.fieldStr? "prev_sha256").getD ""
    binaryPath := binPath
    prevBinaryPath := (v.fieldStr? "prev_binary_path").getD (binPath ++ ".prev")
    stagedMode := (v.fieldBool? "staged_mode").getD false
    startedAt := (v.fieldUInt64? "started_at").getD 0
    startupWindowSecs := max 10 ((v.fieldUInt64? "startup_window_secs").getD 90)
    bootAttempts := (v.fieldNat? "boot_attempts").getD 0
  }

def AutoUpdateState.toJson (st : AutoUpdateState) : JVal :=
  let statusStr :=
    if st.pending?.isSome then "pending_confirm"
    else if st.lastRollbackReason?.isSome then "rolled_back"
    else if st.lastError?.isSome then "error"
    else "idle"
  .obj #[
    ("status", .str statusStr),
    ("pending", match st.pending? with | some p => p.toJson | none => .null),
    ("quarantined_sha256", optStrJson st.quarantinedSha256?),
    ("rollback_reason", optStrJson st.lastRollbackReason?),
    ("last_rollback_at", optU64Json st.lastRollbackAt?),
    ("last_update_at", optU64Json st.lastUpdateAt?),
    ("cli_bundle_version", optStrJson st.lastSyncedCliVer?),
    ("last_error", optStrJson st.lastError?)
  ]

def AutoUpdateState.fromJson (v : JVal) : AutoUpdateState :=
  {
    pending? := v.field? "pending" >>= PendingUpdate.fromJson?
    quarantinedSha256? := (v.fieldStr? "quarantined_sha256").filter (!·.isEmpty)
    lastRollbackReason? := (v.fieldStr? "rollback_reason").filter (!·.isEmpty)
    lastRollbackAt? := v.fieldUInt64? "last_rollback_at"
    lastUpdateAt? := v.fieldUInt64? "last_update_at"
    lastSyncedCliVer? := (v.fieldStr? "cli_bundle_version").filter (!·.isEmpty)
    lastError? := (v.fieldStr? "last_error").filter (!·.isEmpty)
  }

def defaultStateDir (workDir : String) : IO String := do
  if let some override ← getEnvNonEmpty "SANDBOXED_NODE_UPDATE_STATE_DIR" then
    return override
  return (System.FilePath.mk workDir / ".auto-update").toString

def stateFilePath (stateDir : String) : System.FilePath :=
  System.FilePath.mk stateDir / "auto_update_state.json"

def stagedBinaryPath (stateDir : String) : System.FilePath :=
  System.FilePath.mk stateDir / "bin" / "sandboxed-node"

def managedToolsBinDir (stateDir : String) : String :=
  (System.FilePath.mk stateDir / "tools" / "bin").toString

def loadAutoUpdateState (stateDir : String) : IO AutoUpdateState := do
  let fp := stateFilePath stateDir
  if !(← fp.pathExists) then return {}
  match ← (IO.FS.readFile fp).toBaseIO with
  | .error _ => return {}
  | .ok raw =>
    match OrbBin.Json.parse raw with
    | .ok jv => return AutoUpdateState.fromJson jv
    | .error _ => return {}

def saveAutoUpdateState (stateDir : String) (st : AutoUpdateState) : IO Unit := do
  let dir := System.FilePath.mk stateDir
  discard <| (IO.FS.createDirAll dir).toBaseIO
  let fp := stateFilePath stateDir
  let nonce ← newUuidV4
  let tmp := System.FilePath.mk s!"{fp.toString}.{nonce}.tmp"
  let payload := (renderCompact st.toJson) ++ "\n"
  match ← (IO.FS.writeFile tmp payload).toBaseIO with
  | .error _ => pure ()
  | .ok () =>
    if let .error _ ← (IO.FS.rename tmp fp).toBaseIO then
      discard <| (IO.FS.removeFile tmp).toBaseIO

/-! ### Pure Update & Rollback Decision Gates -/

/-- True iff the node is idle, uncordoned, not quarantined for `targetSha`, has no pending
    unconfirmed update, and `currentSha != targetSha`. -/
def shouldApplyBinaryUpdate
    (enabled : Bool)
    (runningJobs queuedJobs : Nat)
    (cordoned : Bool)
    (currentSha targetSha : String)
    (state : AutoUpdateState) : Bool :=
  enabled &&
  runningJobs == 0 &&
  queuedJobs == 0 &&
  !cordoned &&
  state.pending?.isNone &&
  isValidSha256Hex targetSha &&
  currentSha.toLower != targetSha.toLower &&
  state.quarantinedSha256?.map String.toLower != some targetSha.toLower

/-- Determine whether a pending update must roll back immediately.
    - If `bootAttempts >= 1` during startup trampoline, the new binary crashed before its first heartbeat.
    - If `nowSec >= startedAt + startupWindowSecs` and `!firstHbConfirmed`, the startup window timed out. -/
def shouldRollbackStartup
    (pending : PendingUpdate)
    (nowSec : UInt64)
    (firstHbConfirmed : Bool)
    (isStartupPhase : Bool := false) : Option String :=
  if firstHbConfirmed then none
  else if isStartupPhase && pending.bootAttempts >= 1 then
    some "startup_crash_before_heartbeat"
  else if pending.startedAt > 0 && nowSec ≥ pending.startedAt + pending.startupWindowSecs then
    some "startup_heartbeat_timeout"
  else none

/-- Extract the leading semver/version token from CLI `--version` output (e.g. `"claude 2.1.322 (Claude Code)"` -> `"2.1.322"`). -/
def normalizeCliVersionToken (raw : String) : String := Id.run do
  let clean := raw.trimAscii.toString
  if clean.isEmpty then return ""
  let tokens := (clean.splitOn " ").filter (!·.isEmpty)
  for tok in tokens do
    let t := (if tok.startsWith "v" || tok.startsWith "V" then (tok.drop 1).toString else tok).trimAscii.toString
    if t.any (· == '.') && t.toList.head?.any Char.isDigit then
      return t
  return clean

/-- Check whether `reported` satisfies `targetVersion`. -/
def cliVersionMatches (reported targetVersion : String) : Bool :=
  let r := reported.trimAscii.toString
  let t := targetVersion.trimAscii.toString
  if r.isEmpty || t.isEmpty then false
  else
    let normR := normalizeCliVersionToken r
    let normT := normalizeCliVersionToken t
    normR == normT || r == t || (r.splitOn t).length > 1

/-- Return all CLI harnesses whose reported version is missing or drifts from `manifest`. -/
def findDriftedCliHarnesses
    (manifest : CliBundleManifest)
    (reportedVersions : Array (String × String)) : Array CliHarnessSpec :=
  manifest.harnesses.filter fun spec =>
    match reportedVersions.find? (fun (k, _) => k == spec.name || k == spec.bin) with
    | none => true
    | some (_, repVer) => !cliVersionMatches repVer spec.version

/-! ### Local CLI Version Probe (TTL-Cached) -/

private initialize cliVersionCache : Std.Mutex (UInt64 × Array (String × String)) ←
  Std.Mutex.new (0, #[])

def invalidateCliVersionCache : IO Unit :=
  cliVersionCache.atomically (set ((0 : UInt64), (#[] : Array (String × String))))

private def resolveCliBinPath? (stateDir bin : String) : IO (Option String) := do
  let mut dirs : Array String := #[managedToolsBinDir stateDir]
  if let some envPath ← IO.getEnv "PATH" then
    for d in envPath.splitOn ":" do
      let clean := d.trimAscii.toString
      if !clean.isEmpty && !dirs.contains clean then
        dirs := dirs.push clean
  for d in #["/opt/orb/bin", "/opt/sandboxed-tools/bin", "/opt/orb-tools/bin", "/usr/local/bin", "/usr/bin", "/bin"] do
    if !dirs.contains d then dirs := dirs.push d
  for d in dirs do
    let cand := System.FilePath.mk d / bin
    if (← cand.pathExists) && !(← cand.isDir) then
      return some cand.toString
  return none

/-- Probe installed harness CLI versions (`agy`, `claude`, `codex`, `opencode`), cached for 60s. -/
def collectLocalCliVersions (stateDir : String) (force : Bool := false) : IO (Array (String × String)) := do
  let nowSec ← OrbNode.Posix.nowEpoch
  if !force then
    let (cachedAt, cached) ← cliVersionCache.atomically get
    if cachedAt > 0 && nowSec < cachedAt + 60 && !cached.isEmpty then
      return cached
  let tools := #[("agy", "agy"), ("claude", "claude"), ("codex", "codex"), ("opencode", "opencode")]
  let mut out : Array (String × String) := #[]
  for (name, bin) in tools do
    let mut ver := ""
    if let some binPath ← resolveCliBinPath? stateDir bin then
      match ← (IO.Process.output { cmd := "timeout", args := #["3s", binPath, "--version"] }).toBaseIO with
      | .ok res =>
        if res.exitCode == 0 then
          let firstLine := ((res.stdout.splitOn "\n").find? (fun ln => !ln.trimAscii.isEmpty)).getD ""
          ver := normalizeCliVersionToken (firstLine.trimAscii.toString.take 120).toString
      | .error _ => pure ()
    out := out.push (name, ver)
  cliVersionCache.atomically (set (nowSec, out))
  return out

def cliVersionsToJson (vers : Array (String × String)) : JVal :=
  .obj (vers.map fun (k, v) => (k, if v.isEmpty then .null else .str v))

/-! ### Atomic Binary Swap & Rollback -/

/-- Fast SHA-256 hex digest of a file on disk using native `sha256sum` / `shasum -a 256`,
    falling back to pure-Lean `sha256Bytes` when external hash utilities are absent. -/
def sha256FileFast (path : String) : IO (Option String) := do
  let tryCmd (cmd : String) (args : Array String) : IO (Option String) := do
    match ← (IO.Process.output { cmd := cmd, args := args }).toBaseIO with
    | .ok out =>
      if out.exitCode == 0 then
        let tok := ((out.stdout.trimAscii.toString.splitOn " ").head?.getD "").trimAscii.toString.toLower
        if isValidSha256Hex tok then return some tok
      return none
    | .error _ => return none
  if let some h ← tryCmd "sha256sum" #[path] then return some h
  if let some h ← tryCmd "shasum" #["-a", "256", path] then return some h
  match ← (IO.FS.readBinFile path).toBaseIO with
  | .ok bytes => return some (bytesToHexLower (sha256Bytes bytes))
  | .error _ => return none

/-- Read only the first 20 bytes of `path` to check Linux ELF architecture without loading large binaries into RAM. -/
def verifyLinuxElfArchFile (path expectedArch : String) : IO Bool := do
  try
    let h ← IO.FS.Handle.mk path .read
    let hdr ← h.read 20
    return verifyLinuxElfArch hdr expectedArch
  catch _ =>
    return false

private def canWriteDir (dir : System.FilePath) : IO Bool := do
  let nonce ← newUuidV4
  let probe := dir / s!".orb-write-probe-{nonce}"
  match ← (IO.FS.writeFile probe "ok").toBaseIO with
  | .ok () =>
    discard <| (IO.FS.removeFile probe).toBaseIO
    return true
  | .error _ => return false

/-- Choose the binary installation path: explicit override if set, else current executable if its
    parent directory is writable, else `<stateDir>/bin/sandboxed-node` (staged trampoline mode). -/
def resolveInstallTarget (stateDir : String) : IO (String × Bool) := do
  if let some override ← getEnvNonEmpty "SANDBOXED_NODE_UPDATE_BIN_PATH" then
    return (override, false)
  if let .ok appP ← (IO.appPath).toBaseIO then
    if let some par := appP.parent then
      if ← canWriteDir par then
        return (appP.toString, false)
  let staged := stagedBinaryPath stateDir
  if let some par := staged.parent then
    discard <| (IO.FS.createDirAll par).toBaseIO
  return (staged.toString, true)

/-- Atomically write `bytes` with mode `0755` to `dstPath`, backing up any existing `dstPath` to `prevPath`. -/
def atomicSwapExecutable (dstPath prevPath : String) (bytes : ByteArray) : IO (Except String Unit) := do
  let dst := System.FilePath.mk dstPath
  let prev := System.FilePath.mk prevPath
  if let some par := dst.parent then
    if let .error e ← (IO.FS.createDirAll par).toBaseIO then
      return .error s!"createDirAll failed: {e}"
  let nonce ← newUuidV4
  let tmpNew := System.FilePath.mk s!"{dstPath}.new.{nonce}"
  if let .error e ← (IO.FS.writeBinFile tmpNew bytes).toBaseIO then
    return .error s!"write staged binary failed: {e}"
  let _ ← chmod tmpNew.toString 0o755
  -- Preserve previous binary as `.prev` backup before replacing `dst`.
  if ← dst.pathExists then
    if let .ok oldBytes ← (IO.FS.readBinFile dst).toBaseIO then
      let tmpPrev := System.FilePath.mk s!"{prevPath}.tmp.{nonce}"
      if let .ok () ← (IO.FS.writeBinFile tmpPrev oldBytes).toBaseIO then
        let _ ← chmod tmpPrev.toString 0o755
        if let .error e ← (IO.FS.rename tmpPrev prev).toBaseIO then
          discard <| (IO.FS.removeFile tmpPrev).toBaseIO
          discard <| (IO.FS.removeFile tmpNew).toBaseIO
          return .error s!"backup .prev rename failed: {e}"
  match ← (IO.FS.rename tmpNew dst).toBaseIO with
  | .ok () => return .ok ()
  | .error e =>
    discard <| (IO.FS.removeFile tmpNew).toBaseIO
    return .error s!"atomic binary swap failed: {e}"

/-- Restore `.prev` over `pending.binaryPath` (or remove staged binary if no `.prev`),
    quarantine `pending.targetSha256`, and persist the rollback reason in `auto_update_state.json`. -/
def rollbackPendingUpdate (stateDir : String) (state : AutoUpdateState) (pending : PendingUpdate) (reason : String) : IO AutoUpdateState := do
  let nowSec ← OrbNode.Posix.nowEpoch
  let dst := System.FilePath.mk pending.binaryPath
  let prev := System.FilePath.mk pending.prevBinaryPath
  if ← prev.pathExists then
    if let .ok prevBytes ← (IO.FS.readBinFile prev).toBaseIO then
      let nonce ← newUuidV4
      let tmp := System.FilePath.mk s!"{pending.binaryPath}.rollback.{nonce}"
      if let .ok () ← (IO.FS.writeBinFile tmp prevBytes).toBaseIO then
        let _ ← chmod tmp.toString 0o755
        if let .error _ ← (IO.FS.rename tmp dst).toBaseIO then
          discard <| (IO.FS.removeFile tmp).toBaseIO
  else if pending.stagedMode then
    discard <| (IO.FS.removeFile dst).toBaseIO
  let next : AutoUpdateState := {
    state with
    pending? := none
    quarantinedSha256? := some pending.targetSha256
    lastRollbackReason? := some reason
    lastRollbackAt? := some nowSec
    lastError? := some s!"rollback:{reason}"
  }
  saveAutoUpdateState stateDir next
  IO.eprintln s!"[sandboxed-node] auto-update rolled back target={pending.targetSha256} reason={reason}"
  return next

/-- Mark the first heartbeat confirmed, committing any pending binary update. -/
def confirmFirstHeartbeat (stateDir : String) : IO Unit := do
  let st ← loadAutoUpdateState stateDir
  if let some _ := st.pending? then
    let nowSec ← OrbNode.Posix.nowEpoch
    let next : AutoUpdateState := {
      st with
      pending? := none
      lastUpdateAt? := some nowSec
      lastError? := none
    }
    saveAutoUpdateState stateDir next
    IO.eprintln "[sandboxed-node] auto-update confirmed after first heartbeat"

inductive StartupAction where
  | normal
  | rolledBack (reason : String)
  | trampoline (binaryPath : String)
  deriving Repr, BEq

/-- Startup hook invoked in `Main.lean` before binding `:3088`:
    1. Detects crash-before-heartbeat (`bootAttempts >= 1`) and immediately rolls back to `.prev`.
    2. Trampolines into `<stateDir>/bin/sandboxed-node` when staged binary exists and differs from self.
    3. Records `bootAttempts := 1` when launching a pending update binary so a subsequent crash triggers rollback. -/
def handleStartupUpdateCheck (stateDir : String) : IO StartupAction := do
  let st ← loadAutoUpdateState stateDir
  let nowSec ← OrbNode.Posix.nowEpoch
  if let some p := st.pending? then
    if let some reason := shouldRollbackStartup p nowSec false true then
      let _ ← rollbackPendingUpdate stateDir st p reason
      return .rolledBack reason
  let staged := stagedBinaryPath stateDir
  if ← staged.pathExists then
    let selfStr := match ← (IO.appPath).toBaseIO with
      | .ok p => p.toString
      | .error _ => ""
    let stagedStr := staged.toString
    if !selfStr.isEmpty && selfStr != stagedStr then
      let sf ← statPath stagedStr
      if sf.exists_ && sf.isReg && (sf.mode &&& 0o111) != 0 then
        -- Do not trampoline into a quarantined binary
        let stagedSha := match ← (IO.FS.readBinFile staged).toBaseIO with
          | .ok b => bytesToHexLower (sha256Bytes b)
          | .error _ => ""
        if !stagedSha.isEmpty && st.quarantinedSha256? != some stagedSha then
          return .trampoline stagedStr
  if let some p := st.pending? then
    let bumped : AutoUpdateState := { st with pending? := some { p with bootAttempts := p.bootAttempts + 1 } }
    saveAutoUpdateState stateDir bumped
  return .normal

private def resolveUrlAgainstCore (coreUrl url : String) : String :=
  if url.startsWith "http://" || url.startsWith "https://" then url
  else
    let base := stripTrailingSlash coreUrl
    let path := if url.startsWith "/" then url else "/" ++ url
    base ++ path

/-- Download `spec` from Core, verify `sha256` and ELF arch, atomically swap keeping `.prev`,
    and persist `PendingUpdate`. Returns `.ok true` when swap succeeded and restart is needed. -/
def downloadAndStageBinaryUpdate
    (stateDir coreUrl nodeToken : String)
    (machineId? : Option String)
    (currentSha : String)
    (spec : BinaryReleaseSpec)
    (startupWindowSecs : UInt64 := 90) : IO (Except String Bool) := do
  let arch ← detectHostArch
  let baseDownloadUrl := resolveUrlAgainstCore coreUrl spec.url
  let dlUrl :=
    if (baseDownloadUrl.splitOn "?").length > 1 then s!"{baseDownloadUrl}&arch={arch}"
    else s!"{baseDownloadUrl}?arch={arch}"
  let mut hdrs : Array (String × String) := #[("Authorization", s!"Bearer {nodeToken}")]
  if let some mid := machineId? then
    if !mid.isEmpty then hdrs := hdrs.push ("x-orb-machine-id", mid)
  let maxBytes := if dlUrl.startsWith "https://" then 64 * 1024 * 1024 else 128 * 1024 * 1024
  match ← sendRequest "GET" dlUrl hdrs ByteArray.empty 60000 maxBytes with
  | .error e => return .error s!"binary download failed: {e}"
  | .ok resp =>
    if resp.status < 200 || resp.status ≥ 300 then
      return .error s!"binary download HTTP {resp.status}"
    if resp.body.isEmpty then
      return .error "downloaded binary is empty"
    let actualSha := bytesToHexLower (sha256Bytes resp.body)
    if actualSha != spec.sha256.toLower then
      return .error s!"sha256 mismatch: expected {spec.sha256}, got {actualSha}"
    let skipElf := ((← IO.getEnv "SANDBOXED_NODE_UPDATE_SKIP_ELF_CHECK").getD "") == "1"
    if !skipElf && !System.Platform.isOSX then
      if !verifyLinuxElfArch resp.body arch then
        return .error s!"downloaded binary is not a valid Linux {arch} ELF"
    let (targetBin, stagedMode) ← resolveInstallTarget stateDir
    let prevBin := targetBin ++ ".prev"
    match ← atomicSwapExecutable targetBin prevBin resp.body with
    | .error e => return .error e
    | .ok () =>
      let nowSec ← OrbNode.Posix.nowEpoch
      let curSt ← loadAutoUpdateState stateDir
      let pending : PendingUpdate := {
        targetSha256 := actualSha
        prevSha256 := currentSha
        binaryPath := targetBin
        prevBinaryPath := prevBin
        stagedMode := stagedMode
        startedAt := nowSec
        startupWindowSecs := max 10 startupWindowSecs
        bootAttempts := 0
      }
      let nextSt : AutoUpdateState := {
        curSt with
        pending? := some pending
        lastError? := none
      }
      saveAutoUpdateState stateDir nextSt
      IO.eprintln s!"[sandboxed-node] auto-update staged target={actualSha} path={targetBin} staged_mode={stagedMode}"
      return .ok true

/-! ### Declarative Harness CLI Bundle Resync -/

private def installDownloadedHarness
    (toolsRoot toolsBin : String) (spec : CliHarnessSpec) (archiveBytes : ByteArray) : IO (Except String Unit) := do
  let destDir := System.FilePath.mk toolsRoot / spec.name / spec.version
  let binDir := System.FilePath.mk toolsBin
  if let .error e ← (IO.FS.createDirAll destDir).toBaseIO then
    return .error s!"mkdir {destDir} failed: {e}"
  if let .error e ← (IO.FS.createDirAll binDir).toBaseIO then
    return .error s!"mkdir {binDir} failed: {e}"
  let nonce ← newUuidV4
  let targetLink := (binDir / spec.bin).toString
  if spec.format == "raw" then
    let binDest := (destDir / spec.bin).toString
    match ← atomicSwapExecutable binDest (binDest ++ ".prev") archiveBytes with
    | .error e => return .error e
    | .ok () =>
      let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", binDest, targetLink] }
      return .ok ()
  else
    let tmpTar := (destDir / s!".dl-{nonce}.tgz").toString
    if let .error e ← (IO.FS.writeBinFile tmpTar archiveBytes).toBaseIO then
      return .error s!"write archive failed: {e}"
    let mut tarArgs : Array String := #["-xzf", tmpTar, "-C", destDir.toString, "--no-same-owner"]
    if spec.format == "npm-tgz" || spec.format == "codex-npm-tgz" then
      tarArgs := tarArgs.push "--strip-components=1"
    if !spec.entry.isEmpty then
      tarArgs := tarArgs.push spec.entry
    let res ← (IO.Process.output { cmd := "tar", args := tarArgs }).toBaseIO
    discard <| (IO.FS.removeFile tmpTar).toBaseIO
    match res with
    | .error e => return .error s!"tar extract failed: {e}"
    | .ok out =>
      if out.exitCode != 0 then
        return .error s!"tar extract exit {out.exitCode}: {(out.stderr.take 160).toString}"
    if spec.format == "codex-npm-tgz" then
      let wrapper :=
        s!"#!/bin/sh\nV={destDir.toString}/vendor/x86_64-unknown-linux-musl\n" ++
        "PATH=\"$V/codex-path:$PATH\" CODEX_MANAGED_BY_NPM=1 exec \"$V/bin/codex\" \"$@\"\n"
      match ← atomicSwapExecutable targetLink (targetLink ++ ".prev") wrapper.toUTF8 with
      | .error e => return .error e
      | .ok () => return .ok ()
    else
      let binFile :=
        let cand1 := destDir / spec.bin
        cand1.toString
      let _ ← chmod binFile 0o755
      let _ ← IO.Process.output { cmd := "ln", args := #["-sfn", binFile, targetLink] }
      return .ok ()

/-- Resync drifted harness CLIs from Core's declarative `CliBundleManifest` when idle. -/
def syncCliBundleIfDrifted
    (stateDir coreUrl nodeToken : String)
    (machineId? : Option String)
    (manifest : CliBundleManifest)
    (reportedVersions : Array (String × String)) : IO (Except String Nat) := do
  let drifted := findDriftedCliHarnesses manifest reportedVersions
  if drifted.isEmpty then return .ok 0
  let optRoot := System.FilePath.mk "/opt/sandboxed-tools"
  let optWritable ← if ← optRoot.pathExists then canWriteDir optRoot else pure false
  let toolsRoot :=
    if optWritable then optRoot.toString
    else (System.FilePath.mk stateDir / "tools").toString
  let toolsBin := managedToolsBinDir stateDir
  let mut updated : Nat := 0
  for spec in drifted do
    if !spec.url.isEmpty && isValidSha256Hex spec.sha256 then
      let dlUrl := resolveUrlAgainstCore coreUrl spec.url
      let mut hdrs : Array (String × String) := #[]
      if dlUrl.startsWith (stripTrailingSlash coreUrl) then
        hdrs := hdrs.push ("Authorization", s!"Bearer {nodeToken}")
        if let some mid := machineId? then
          if !mid.isEmpty then hdrs := hdrs.push ("x-orb-machine-id", mid)
      let cliMaxBytes := if dlUrl.startsWith "https://" then 64 * 1024 * 1024 else 512 * 1024 * 1024
      match ← sendRequestFollowingRedirects "GET" dlUrl hdrs ByteArray.empty 180000 cliMaxBytes 5 with
      | .error e => return .error s!"cli {spec.name} download failed: {e}"
      | .ok resp =>
        if resp.status < 200 || resp.status ≥ 300 then
          return .error s!"cli {spec.name} download HTTP {resp.status}"
        let gotSha ←
          if resp.body.size ≤ 16 * 1024 * 1024 then
            pure (bytesToHexLower (sha256Bytes resp.body))
          else
            let tmpHash := (System.FilePath.mk stateDir / s!".cli-hash-{← newUuidV4}.tmp").toString
            discard <| (IO.FS.createDirAll (System.FilePath.mk stateDir)).toBaseIO
            discard <| (IO.FS.writeBinFile tmpHash resp.body).toBaseIO
            let h? ← sha256FileFast tmpHash
            discard <| (IO.FS.removeFile tmpHash).toBaseIO
            pure (h?.getD "")
        if gotSha != spec.sha256.toLower then
          return .error s!"cli {spec.name} sha256 mismatch: expected {spec.sha256}, got {gotSha}"
        match ← installDownloadedHarness toolsRoot toolsBin spec resp.body with
        | .error e => return .error s!"cli {spec.name} install failed: {e}"
        | .ok () => updated := updated + 1
  if updated > 0 then
    invalidateCliVersionCache
    let st ← loadAutoUpdateState stateDir
    let nextVer := if manifest.version.isEmpty then manifest.profile else manifest.version
    saveAutoUpdateState stateDir { st with lastSyncedCliVer? := some nextVer, lastError? := none }
  return .ok updated

/-- Validate that a Core URL learned from an authenticated `GET /heartbeat` header is safe
    (`https://` or mesh/loopback `http://10.88.0.1:` / `http://127.0.0.1:`). -/
def isAllowedCoreUrl (rawUrl : String) : Bool :=
  let u := stripTrailingSlash rawUrl.trimAscii.toString
  u.startsWith "https://" ||
  u.startsWith "http://10.88.0.1:" || u == "http://10.88.0.1" ||
  u.startsWith "http://127.0.0.1:" || u == "http://127.0.0.1"

/-- Perform one outbound heartbeat + auto-update check against Core.
    Returns `true` if a new binary was staged and the daemon must restart cleanly. -/
def runAutoUpdateTick
    (stateDir coreUrl nodeId nodeToken currentSha : String)
    (machineId? : Option String)
    (enabled : Bool)
    (runningJobs queuedJobs : Nat)
    (localCordoned : Bool) : IO Bool := do
  let arch ← detectHostArch
  let st ← loadAutoUpdateState stateDir
  let cliVers ← collectLocalCliVersions stateDir
  let hbPayload := JVal.obj #[
    ("node_id", .str nodeId),
    ("arch", .str arch),
    ("running_jobs", .nat runningJobs),
    ("queued_jobs", .nat queuedJobs),
    ("current_sha256", if currentSha.isEmpty then .null else .str currentSha),
    ("cli_versions", cliVersionsToJson cliVers),
    ("auto_update", st.toJson)
  ]
  let url := s!"{stripTrailingSlash coreUrl}/api/node-releases/heartbeat"
  let mut extraHdrs : Array (String × String) := #[]
  if let some mid := machineId? then
    if !mid.isEmpty then extraHdrs := extraHdrs.push ("x-orb-machine-id", mid)
  match ← sendJsonRequest "POST" url (some nodeToken) (some hbPayload) extraHdrs 15000 with
  | .error _ => return false
  | .ok (stCode, _, some respJv) =>
    if stCode < 200 || stCode ≥ 300 then return false
    confirmFirstHeartbeat stateDir
    let freshSt ← loadAutoUpdateState stateDir
    let some manifest := ReleaseManifest.fromJson? respJv | return false
    let effCordoned := localCordoned || manifest.cordoned
    if let some binSpec := manifest.nodeBinary? then
      if binSpec.arch == arch &&
          shouldApplyBinaryUpdate enabled runningJobs queuedJobs effCordoned currentSha binSpec.sha256 freshSt then
        match ← downloadAndStageBinaryUpdate stateDir coreUrl nodeToken machineId? currentSha binSpec manifest.startupWindowSecs with
        | .ok true => return true
        | .ok false => pure ()
        | .error err =>
          saveAutoUpdateState stateDir { freshSt with lastError? := some err }
          IO.eprintln s!"[sandboxed-node] auto-update error: {err}"
          return false
    if enabled && runningJobs == 0 && queuedJobs == 0 && !effCordoned then
      if let some cliBundle := manifest.cliBundle? then
        match ← syncCliBundleIfDrifted stateDir coreUrl nodeToken machineId? cliBundle cliVers with
        | .ok _ => pure ()
        | .error err =>
          let cur ← loadAutoUpdateState stateDir
          saveAutoUpdateState stateDir { cur with lastError? := some err }
          IO.eprintln s!"[sandboxed-node] cli bundle sync error: {err}"
    return false
  | .ok _ => return false

end OrbNode.AutoUpdate
