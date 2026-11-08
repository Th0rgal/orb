/-
  OrbNode.PrivdClient: Pure-Lean Unix Socket Broker Client for `orb-privd` (`0 import Lean`, `0 C LOC`).
  Talks to `/run/orb-privd.sock` for confined per-user provisioning, transient systemd unit execution,
  job status/kill control, and UID-dropped `O_NOFOLLOW` filesystem / artifact operations.
-/
import LeanSys.Posix
import OrbBin.PosixExt
import OrbBin.Json
import OrbNode.Store

namespace OrbNode.PrivdClient

open OrbBin.PosixExt
open OrbBin.Json
open OrbNode.Store

structure ProvisionedMissionUser where
  uid        : UInt32
  gid        : UInt32
  homeDir    : String
  missionCwd : String
  deriving Repr, BEq

structure SpawnedUserJob where
  unit : String
  pid  : UInt64
  deriving Repr, BEq

structure UserJobStatus where
  done     : Bool
  exitCode : Int
  state    : String
  deriving Repr, BEq

/-- Send one newline-framed + write-half-closed JSON request to `orb-privd` and parse the JSON reply. -/
def callPrivd (socketPath : String) (payload : JVal) (timeoutMs : UInt32 := 30000) : IO (Except String JVal) := do
  let fd ← match ← LeanSys.Posix.unixConnect socketPath with
    | .ok f => pure f
    | .error err => return .error s!"orb-privd connect failed ({socketPath}): {repr err}"
  let wire := ((renderCompact payload) ++ "\n").toUTF8
  match ← LeanSys.Posix.writeAll fd wire with
  | .error err =>
    let _ ← LeanSys.Posix.closeFd fd
    return .error s!"orb-privd write failed: {repr err}"
  | .ok _ => pure ()
  let _ ← shutdownWr (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
  let mut respBytes := ByteArray.emptyWithCapacity 4096
  while true do
    match ← readSocketTimed fd 65536 timeoutMs with
    | .eof => break
    | .timeout =>
      let _ ← LeanSys.Posix.closeFd fd
      return .error "orb-privd read timed out"
    | .fatal code =>
      let _ ← LeanSys.Posix.closeFd fd
      return .error s!"orb-privd read error ({code})"
    | .bytes chunk => respBytes := respBytes ++ chunk
  let _ ← LeanSys.Posix.closeFd fd
  match OrbBin.Json.parseBytes respBytes with
  | .error err => return .error s!"orb-privd invalid JSON reply: {err}"
  | .ok resp =>
    if (resp.fieldBool? "ok") == some true then
      return .ok resp
    else
      let errMsg := (resp.fieldStr? "stderr").getD ((resp.fieldStr? "error").getD "orb-privd rejected request")
      return .error errMsg

/-- Provision or verify `/home/<unixUsername>` (`0700`) and `/home/<unixUsername>/.orb-missions/<missionId>`,
    writing workspace harness config files inside the UID-dropped helper. -/
def ensureMissionUser
    (socketPath unixUsername missionId callerRole : String)
    (nodeAdminOnly : Bool)
    (workspaceFiles : Array (String × String) := #[]) : IO (Except String ProvisionedMissionUser) := do
  let filesArr := workspaceFiles.map fun (p, c) => JVal.obj #[("path", .str p), ("content", .str c)]
  let req := JVal.obj #[
    ("action", .str "ensure_mission_user"),
    ("unix_username", .str unixUsername),
    ("mission_id", .str missionId),
    ("caller_role", .str callerRole),
    ("node_admin_only", .bool nodeAdminOnly),
    ("lease_verified", .bool true),
    ("workspace_files", .arr filesArr)
  ]
  match ← callPrivd socketPath req 30000 with
  | .error e => return .error e
  | .ok resp =>
    let uid := ((resp.fieldNat? "uid").getD 0).toUInt32
    let gid := ((resp.fieldNat? "gid").getD 0).toUInt32
    let homeDir := (resp.fieldStr? "home_dir").getD ""
    let missionCwd := (resp.fieldStr? "mission_cwd").getD ""
    if uid == 0 || homeDir.isEmpty || missionCwd.isEmpty then
      return .error "orb-privd returned incomplete ensure_mission_user payload"
    return .ok { uid, gid, homeDir, missionCwd }

/-- Spawn a confined user job under `orb-privd` (`systemd-run --uid --gid --property=ProtectSystem=strict ...`). -/
def spawnUserJob
    (socketPath unixUsername callerRole : String)
    (nodeAdminOnly : Bool)
    (jobId missionId : String)
    (argv : Array String)
    (envPairs : Array (String × String))
    (logPath : String)
    (timeoutSecs? : Option UInt64 := none)
    (memMax? : Option UInt64 := none)
    (memHigh? : Option UInt64 := none)
    (cpuWeight? : Option Nat := none)
    (cpuQuota? : Option String := none) : IO (Except String SpawnedUserJob) := do
  let envObj := JVal.obj (envPairs.map fun (k, v) => (k, JVal.str v))
  let mut fields : Array (String × JVal) := #[
    ("action", .str "spawn_user_job"),
    ("unix_username", .str unixUsername),
    ("caller_role", .str callerRole),
    ("node_admin_only", .bool nodeAdminOnly),
    ("job_id", .str jobId),
    ("mission_id", .str missionId),
    ("argv", .arr (argv.map .str)),
    ("env", envObj),
    ("log_path", .str logPath)
  ]
  if let some t := timeoutSecs? then
    fields := fields.push ("timeout_secs", .uint64 t)
  if let some m := memMax? then
    fields := fields.push ("mem_max", .uint64 m)
  if let some mh := memHigh? then
    fields := fields.push ("mem_high", .uint64 mh)
  if let some cw := cpuWeight? then
    fields := fields.push ("cpu_weight", .nat cw)
  if let some cq := cpuQuota? then
    fields := fields.push ("cpu_quota", .str cq)
  match ← callPrivd socketPath (.obj fields) 30000 with
  | .error e => return .error e
  | .ok resp =>
    let unit := (resp.fieldStr? "unit").getD ""
    let pid := (resp.fieldUInt64? "pid").getD 0
    return .ok { unit, pid }

/-- Query status (`"status"`) or terminate (`"stop"` / `"kill"`) a confined user job. -/
def controlUserJob
    (socketPath op jobId unixUsername : String) : IO (Except String UserJobStatus) := do
  let req := JVal.obj #[
    ("action", .str "control_user_job"),
    ("op", .str op),
    ("job_id", .str jobId),
    ("unix_username", .str unixUsername)
  ]
  match ← callPrivd socketPath req 15000 with
  | .error e => return .error e
  | .ok resp =>
    let done := (resp.fieldBool? "done").getD false
    let exitCode := (resp.fieldInt? "exit_code").getD 0
    let state := (resp.fieldStr? "state").getD ""
    return .ok { done, exitCode, state }

/-- Execute a confined UID-dropped `file_browser` operation inside `/home/<unixUsername>/.orb-missions/<missionId>`. -/
def userFileBrowser
    (socketPath unixUsername missionId : String)
    (reqJson : JVal) : IO (Except String JVal) := do
  let req := JVal.obj #[
    ("action", .str "user_fs_op"),
    ("unix_username", .str unixUsername),
    ("mission_id", .str missionId),
    ("subop", .str "file_browser"),
    ("req_json", reqJson)
  ]
  match ← callPrivd socketPath req 30000 with
  | .error e => return .error e
  | .ok resp =>
    return .ok (resp.fieldOrNull "result")

/-- Write a binary/text file inside `/home/<unixUsername>/.orb-missions/<missionId>` via UID-dropped `O_NOFOLLOW`. -/
def userWriteFile
    (socketPath unixUsername missionId relPath : String)
    (bytes : ByteArray) : IO (Except String UInt64) := do
  let b64 := OrbBin.PosixExt.base64Encode bytes
  let req := JVal.obj #[
    ("action", .str "user_fs_op"),
    ("unix_username", .str unixUsername),
    ("mission_id", .str missionId),
    ("subop", .str "write"),
    ("rel_path", .str relPath),
    ("content_b64", .str b64)
  ]
  match ← callPrivd socketPath req 30000 with
  | .error e => return .error e
  | .ok resp =>
    let res := resp.fieldOrNull "result"
    return .ok ((res.fieldUInt64? "size").getD bytes.size.toUInt64)

/-- Create directory path inside `/home/<unixUsername>/.orb-missions/<missionId>` via UID-dropped `O_NOFOLLOW`. -/
def userMkdir
    (socketPath unixUsername missionId relPath : String) : IO (Except String String) := do
  let req := JVal.obj #[
    ("action", .str "user_fs_op"),
    ("unix_username", .str unixUsername),
    ("mission_id", .str missionId),
    ("subop", .str "mkdir"),
    ("rel_path", .str relPath)
  ]
  match ← callPrivd socketPath req 15000 with
  | .error e => return .error e
  | .ok resp =>
    let res := resp.fieldOrNull "result"
    return .ok ((res.fieldStr? "path").getD "")

/-- Hash and size declared artifact paths inside `/home/<unixUsername>/.orb-missions/<missionId>`. -/
def collectUserArtifacts
    (socketPath unixUsername missionId : String)
    (declaredPaths : Array String) : IO (Array ArtifactEntry) := do
  if declaredPaths.isEmpty then return #[]
  let req := JVal.obj #[
    ("action", .str "user_fs_op"),
    ("unix_username", .str unixUsername),
    ("mission_id", .str missionId),
    ("subop", .str "collect_artifacts"),
    ("paths", .arr (declaredPaths.map .str))
  ]
  match ← callPrivd socketPath req 30000 with
  | .error _ => return #[]
  | .ok resp =>
    let res := resp.fieldOrNull "result"
    let some arr := res.fieldArr? "artifacts" | return #[]
    return arr.filterMap ArtifactEntry.fromJson?

end OrbNode.PrivdClient
