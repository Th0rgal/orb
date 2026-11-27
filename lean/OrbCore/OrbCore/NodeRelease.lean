/-
  OrbCore.NodeRelease: Core-Driven Release Manifest, Binary Distribution & Node Auto-Update Reports.
  - Serves `GET /api/node-releases/manifest`, `POST /api/node-releases/heartbeat`,
    and `GET /api/node-releases/binaries/:name` (`sandboxed-node`, `orb-privd`).
  - Exposes target binary `sha256` + download URLs + declarative harness CLI bundle manifest
    (`agy`, `claude`, `codex`, `opencode`) in the node heartbeat response.
  - Persists per-node reported auto-update / rollback status and CLI versions in
    `<dataRoot>/node_update_status.json` so fleet endpoints surface convergence & rollbacks.
  (`0 import Lean`, `0 sorryAx`).
-/
import Std.Sync.Mutex
import Std.Data.HashMap
import LeanSys.Auth
import OrbBin.Json
import OrbBin.PosixExt
import OrbNode.AutoUpdate

namespace OrbCore.NodeRelease

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt

private initialize releaseBinaryShaCache : Std.Mutex (Std.HashMap String (UInt64 × IO.FS.SystemTime × String)) ←
  Std.Mutex.new {}

private initialize agyVersionCache : Std.Mutex (Std.HashMap String (UInt64 × IO.FS.SystemTime × String)) ←
  Std.Mutex.new {}

private def allowedReleaseBinaryName (name : String) : Bool :=
  name == "sandboxed-node" || name == "orb-privd" || name == "agy"

private def candidateBinaryPaths (name arch : String) : IO (Array String) := do
  let normArch := OrbNode.AutoUpdate.normalizeArch arch
  let buildSha := ((← IO.getEnv "ORB_BUILD_SHA").getD "").trimAscii.toString
  let mut cands : Array String := #[]
  if let some relDir ← getEnvNonEmpty "ORB_NODE_RELEASE_DIR" then
    let r := stripTrailingSlash relDir
    cands := cands.push s!"{r}/{normArch}/{name}"
    cands := cands.push s!"{r}/{name}"
  if !buildSha.isEmpty then
    cands := cands.push s!"/usr/local/share/orb/releases/{buildSha}/bin/{normArch}/{name}"
    cands := cands.push s!"/usr/local/share/orb/releases/{buildSha}/bin/{name}"
  if name == "sandboxed-node" then
    cands := cands ++ #[
      s!"/usr/local/lib/orb/guest/{normArch}/sandboxed-node",
      "/usr/local/lib/orb/guest/sandboxed-node",
      "/usr/local/bin/sandboxed-node",
      "/usr/bin/sandboxed-node"
    ]
  else if name == "orb-privd" then
    cands := cands ++ #[
      s!"/usr/local/lib/orb/guest/{normArch}/orb-privd",
      "/usr/local/sbin/orb-privd",
      "/usr/local/bin/orb-privd"
    ]
  else if name == "agy" then
    cands := cands ++ #[
      s!"/usr/local/lib/orb/guest/{normArch}/agy",
      "/usr/local/lib/orb/guest/agy",
      "/usr/local/bin/agy",
      "/opt/sandboxed-tools/bin/agy",
      "/opt/orb/bin/agy"
    ]
  return cands

/-- Cached `(path, sha256, sizeBytes)` metadata for a release binary without loading large binaries
    into RAM (reads only 20-byte ELF header + native `sha256sum` cached by `(size, mtime)`). -/
def resolveReleaseBinaryPathMeta? (name arch : String) : IO (Option (String × String × UInt64)) := do
  if !allowedReleaseBinaryName name then return none
  let skipElf := ((← IO.getEnv "ORB_NODE_RELEASE_SKIP_ELF_CHECK").getD "") == "1"
  let normArch := OrbNode.AutoUpdate.normalizeArch arch
  let cands ← candidateBinaryPaths name normArch
  for p in cands do
    let fp := System.FilePath.mk p
    if ← fp.pathExists then
      if let .ok md ← (fp.metadata).toBaseIO then
        if md.byteSize > 0 then
          let key := s!"{p}|{normArch}|{skipElf}"
          let cached? ← releaseBinaryShaCache.atomically do
            return (← get).get? key
          if let some (sz, mt, hex) := cached? then
            if sz == md.byteSize && mt == md.modified then
              return some (p, hex, md.byteSize)
          let archOk ←
            if skipElf || System.Platform.isOSX then pure true
            else OrbNode.AutoUpdate.verifyLinuxElfArchFile p normArch
          if archOk then
            if let some sha ← OrbNode.AutoUpdate.sha256FileFast p then
              releaseBinaryShaCache.atomically do
                modify (·.insert key (md.byteSize, md.modified, sha))
              return some (p, sha, md.byteSize)
  return none

/-- Resolve the first existing, non-empty release binary matching `arch` (ELF `e_machine` check
    on Linux unless `ORB_NODE_RELEASE_SKIP_ELF_CHECK=1`). -/
def resolveReleaseBinaryBytes? (name arch : String) : IO (Option (String × ByteArray × String)) := do
  let some (p, sha, _) ← resolveReleaseBinaryPathMeta? name arch | return none
  match ← (IO.FS.readBinFile p).toBaseIO with
  | .ok bytes =>
    if bytes.isEmpty then return none
    return some (p, bytes, sha)
  | .error _ => return none

/-- Cached `(sha256, sizeBytes)` metadata for a release binary without re-hashing unchanged files. -/
def resolveReleaseBinaryMeta? (name arch : String) : IO (Option (String × UInt64)) := do
  return (← resolveReleaseBinaryPathMeta? name arch).map fun (_, sha, sz) => (sha, sz)

/-- Default declarative harness CLI bundle manifest matching `scripts/orb-node-provision.sh`.
    Can be overridden via `ORB_CLI_BUNDLE_MANIFEST_PATH` or `<dataRoot>/cli_bundle_manifest.json`. -/
def defaultCliBundleManifestJVal : JVal :=
  let harnesses := JVal.obj #[
    ("agy", .obj #[
      ("bin", .str "agy"),
      ("version", .str "1.5.18"),
      ("url", .str ""),
      ("sha256", .str ""),
      ("format", .str "raw")
    ]),
    ("claude", .obj #[
      ("bin", .str "claude"),
      ("version", .str "2.1.322"),
      ("url", .str "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.322.tgz"),
      ("sha256", .str "3cc175d82980c20ab66057d345bd2d913244f8cf1791d10722a1225214b57219"),
      ("format", .str "npm-tgz"),
      ("entry", .str "package/claude")
    ]),
    ("codex", .obj #[
      ("bin", .str "codex"),
      ("version", .str "0.166.0"),
      ("url", .str "https://registry.npmjs.org/@openai/codex/-/codex-0.166.0-linux-x64.tgz"),
      ("sha256", .str "cbc00a26d3d0e2ceefc4be8891f8a81ef1e349b3b175bc0ae308762bc001fd93"),
      ("format", .str "codex-npm-tgz")
    ]),
    ("opencode", .obj #[
      ("bin", .str "opencode"),
      ("version", .str "1.19.3"),
      ("url", .str "https://github.com/anomalyco/opencode/releases/download/v1.19.3/opencode-linux-x64-baseline.tar.gz"),
      ("sha256", .str "531cff2441129c30f0edd5878af494108ad07f5feb46d7ee29a2a5b830a5765d"),
      ("format", .str "tar.gz"),
      ("entry", .str "opencode")
    ])
  ]
  let verHash := (bytesToHexLower (sha256Bytes (renderCompact harnesses).toUTF8)).take 16 |>.toString
  .obj #[
    ("profile", .str "default"),
    ("version", .str verHash),
    ("bundle_url", .null),
    ("bundle_sha256", .null),
    ("harnesses", harnesses)
  ]

def loadCliBundleManifestJVal (dataRoot : String) : IO JVal := do
  let mut candPaths : Array String := #[]
  if let some envP ← getEnvNonEmpty "ORB_CLI_BUNDLE_MANIFEST_PATH" then
    candPaths := candPaths.push envP
  let trimmed := dataRoot.trimAscii.toString
  if !trimmed.isEmpty then
    candPaths := candPaths.push s!"{trimmed}/cli_bundle_manifest.json"
  for p in candPaths do
    let fp := System.FilePath.mk p
    if ← fp.pathExists then
      if let .ok raw ← (IO.FS.readFile fp).toBaseIO then
        if let .ok jv := OrbBin.Json.parse raw then
          return jv
  return defaultCliBundleManifestJVal

private def probeAgyBinaryVersion (path : String) (fallback : String) : IO String := do
  if let some envVer ← getEnvNonEmpty "ORB_CLI_BUNDLE_AGY_VERSION" then
    return envVer.trimAscii.toString
  let fp := System.FilePath.mk path
  if let .ok md ← (fp.metadata).toBaseIO then
    let cached? ← agyVersionCache.atomically do return (← get).get? path
    if let some (sz, mt, ver) := cached? then
      if sz == md.byteSize && mt == md.modified then
        return if ver.isEmpty then fallback else ver
    let mut probed := ""
    match ← (IO.Process.output { cmd := "timeout", args := #["3s", path, "--version"] }).toBaseIO with
    | .ok out =>
      if out.exitCode == 0 then
        let firstLine := ((out.stdout.splitOn "\n").find? (fun ln => !ln.trimAscii.isEmpty)).getD ""
        probed := OrbNode.AutoUpdate.normalizeCliVersionToken (firstLine.trimAscii.toString.take 120).toString
    | .error _ => pure ()
    agyVersionCache.atomically do
      modify (·.insert path (md.byteSize, md.modified, probed))
    return if probed.isEmpty then fallback else probed
  return fallback

/-- When `cli_bundle.harnesses.agy` has no explicit download URL and Core has an `agy` binary
    for `normArch`, serve it directly from `/api/node-releases/binaries/agy?arch=<arch>` so
    fleet nodes (e.g. `babylon`) converge automatically to Core's `agy` version. -/
private def hydrateAgyCliBundleSpec (normArch : String) (cliBundle : JVal) : IO JVal := do
  let some (.obj bFields) := some cliBundle | return cliBundle
  let some (.obj hFields) := cliBundle.field? "harnesses" | return cliBundle
  let agyEntry? := (hFields.find? (fun p => p.1 == "agy")).map Prod.snd
  let curUrl := (agyEntry?.bind (·.fieldStr? "url")).getD ""
  if !curUrl.isEmpty then return cliBundle
  let some (agyPath, agySha, _) ← resolveReleaseBinaryPathMeta? "agy" normArch | return cliBundle
  let curVer := (agyEntry?.bind (·.fieldStr? "version")).getD "1.5.18"
  let agyVer ← probeAgyBinaryVersion agyPath curVer
  let newAgy := JVal.obj #[
    ("bin", .str "agy"),
    ("version", .str agyVer),
    ("url", .str s!"/api/node-releases/binaries/agy?arch={normArch}"),
    ("sha256", .str agySha),
    ("format", .str "raw")
  ]
  let updatedHFields := (hFields.filter (fun p => p.1 != "agy")).push ("agy", newAgy)
  let newHarnesses := JVal.obj updatedHFields
  let verHash := (bytesToHexLower (sha256Bytes (renderCompact newHarnesses).toUTF8)).take 16 |>.toString
  let updatedBFields :=
    (bFields.filter (fun p => p.1 != "harnesses" && p.1 != "version"))
      |>.push ("version", .str verHash)
      |>.push ("harnesses", newHarnesses)
  return .obj updatedBFields

/-- Build the Core release manifest returned in `GET /api/node-releases/manifest` and
    `POST /api/node-releases/heartbeat`. -/
def buildNodeReleaseManifestJVal (dataRoot arch : String) (cordoned : Bool := false) : IO JVal := do
  let normArch := OrbNode.AutoUpdate.normalizeArch arch
  let buildSha := ((← IO.getEnv "ORB_BUILD_SHA").getD "").trimAscii.toString
  let nodeMeta? ← resolveReleaseBinaryMeta? "sandboxed-node" normArch
  let privdMeta? ← resolveReleaseBinaryMeta? "orb-privd" normArch
  let mkBinEntry (name : String) (meta? : Option (String × UInt64)) : JVal :=
    match meta? with
    | none => .null
    | some (sha, sz) =>
      .obj #[
        ("sha256", .str sha),
        ("url", .str s!"/api/node-releases/binaries/{name}"),
        ("size_bytes", .uint64 sz),
        ("arch", .str normArch)
      ]
  let cliBundleRaw ← loadCliBundleManifestJVal dataRoot
  let cliBundle ← hydrateAgyCliBundleSpec normArch cliBundleRaw
  let winSecs := (((← IO.getEnv "ORB_NODE_UPDATE_STARTUP_WINDOW_SECS") >>= String.toNat?).getD 90).toUInt64
  return .obj #[
    ("version", .nat 1),
    ("build_sha", if buildSha.isEmpty then .null else .str buildSha),
    ("arch", .str normArch),
    ("cordoned", .bool cordoned),
    ("startup_window_secs", .uint64 (max 10 winSecs)),
    ("binaries", .obj #[
      ("sandboxed-node", mkBinEntry "sandboxed-node" nodeMeta?),
      ("orb-privd", mkBinEntry "orb-privd" privdMeta?)
    ]),
    ("cli_bundle", cliBundle)
  ]

/-! ### Persisted Node Auto-Update / Rollback Telemetry (`<dataRoot>/node_update_status.json`) -/

def loadNodeUpdateReports (dataRoot : String) : IO JVal := do
  let trimmed := dataRoot.trimAscii.toString
  if trimmed.isEmpty then return .obj #[]
  match ← (IO.FS.readFile s!"{trimmed}/node_update_status.json").toBaseIO with
  | .error _ => return .obj #[]
  | .ok raw =>
    match OrbBin.Json.parse raw with
    | .ok (.obj fields) => return .obj fields
    | _ => return .obj #[]

def recordNodeUpdateReport (dataRoot nodeId : String) (report : JVal) (nowIso : String) : IO Unit := do
  let trimmed := dataRoot.trimAscii.toString
  let cleanNode := nodeId.trimAscii.toString
  if trimmed.isEmpty || cleanNode.isEmpty then return
  let existing ← loadNodeUpdateReports trimmed
  let existingFields : Array (String × JVal) := match existing with
    | .obj fs => fs.filter (fun p => p.1 != cleanNode)
    | _ => #[]
  let entry := JVal.obj #[
    ("node_id", .str cleanNode),
    ("arch", (report.field? "arch").getD .null),
    ("current_sha256", (report.field? "current_sha256").getD .null),
    ("running_jobs", (report.field? "running_jobs").getD (.nat 0)),
    ("queued_jobs", (report.field? "queued_jobs").getD (.nat 0)),
    ("cli_versions", (report.field? "cli_versions").getD (.obj #[])),
    ("auto_update", (report.field? "auto_update").getD (.obj #[])),
    ("updated_at", .str nowIso)
  ]
  let next := JVal.obj (existingFields.push (cleanNode, entry))
  let path := s!"{trimmed}/node_update_status.json"
  let tmp := s!"{path}.{← newUuidV4}.tmp"
  discard <| (IO.FS.createDirAll (System.FilePath.mk trimmed)).toBaseIO
  match ← (IO.FS.writeFile tmp ((renderCompact next) ++ "\n")).toBaseIO with
  | .error _ => pure ()
  | .ok () =>
    if let .error _ ← (IO.FS.rename tmp path).toBaseIO then
      discard <| (IO.FS.removeFile tmp).toBaseIO

end OrbCore.NodeRelease
