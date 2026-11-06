/-
  OrbBin.PrivdMain: Native Lean `orb-privd` Local Privileged Execution & Harness Broker (`0 import Lean`).
  Listens on `/run/orb-privd.sock` (`0660 root:sandboxed-node`), verifies peer credentials via `SO_PEERCRED`,
  enforces `Orb.Kernel.privdCommandStep`, verifies biometric JIT leases against Core
  `POST /api/privilege-access/verify-and-log`, and logs pre/post execution SHA-256 digests.
-/
import LeanSys.Posix
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.PrivdShared

namespace OrbBin.Privd

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbBin.PrivdShared

structure PrivdConfig where
  socketPath : String
  groupName  : String
  apiUrl     : String
  apiToken   : Option String
  auditLog   : String
  hostLabel  : String

def appendAuditLine (auditLog : String) (entry : JVal) : IO Unit := do
  try
    let p := System.FilePath.mk auditLog
    if let some parent := p.parent then
      IO.FS.createDirAll parent
    let h ← IO.FS.Handle.mk p .append
    h.putStrLn (renderCompact entry)
    h.flush
  catch _ =>
    pure ()

def replyJson (cfd : LeanSys.Posix.Fd) (v : JVal) : IO Unit := do
  let _ ← LeanSys.Posix.writeAll cfd ((renderCompact v) ++ "\n").toUTF8

def replyError (cfd : LeanSys.Posix.Fd) (msg : String) (code : Int := 1) : IO Unit :=
  replyJson cfd <| JVal.obj #[
    ("ok", .bool false),
    ("exit_code", .int code),
    ("stdout", .str ""),
    ("stderr", .str msg)
  ]

def handleUpdateHarness (cfd : LeanSys.Posix.Fd) (cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  let leaseToken := ((req.fieldStr? "lease_token").getD "").trimAscii.toString
  if peer.uid != some 0 then
    if leaseToken.isEmpty then
      return (← replyError cfd "update_harness requires root peer UID or an active Core lease_token" 126)
    let missionId := ((req.fieldStr? "mission_id").getD "system-harness-update").trimAscii.toString
    let verifyUrl := stripTrailingSlash cfg.apiUrl ++ "/api/privilege-access/verify-and-log"
    let verifyBody := JVal.obj #[
      ("mission_id", .str missionId),
      ("lease_token", .str leaseToken),
      ("target_host", .str "self"),
      ("executing_host", .str cfg.hostLabel),
      ("command", .str "[update_harness]"),
      ("argv", .arr #[.str "orb-update-harness"]),
      ("cwd", .str "/root")
    ]
    match (← sendJsonRequest "POST" verifyUrl cfg.apiToken (some verifyBody) #[("User-Agent", "orb-privd/1.0")] 15000) with
    | .ok (status, text, j?) =>
      let (valid, scopeStr) := match j? with
        | some j =>
          let v := (j.fieldBool? "allow_exec").orElse (fun _ =>
            (j.fieldBool? "valid").orElse (fun _ => j.fieldBool? "allowed")) |>.getD false
          (v, (j.fieldStr? "scope").getD "")
        | none => (false, "")
      let scopeAllowed := scopeStr == "service_deploy" || scopeStr == "root_exec" || scopeStr == "host_admin"
      if !(200 ≤ status && status < 300) || !valid || !scopeAllowed then
        return (← replyError cfd s!"Core rejected update_harness lease ({status}, scope={scopeStr}): {text}" 126)
    | .error err =>
      return (← replyError cfd s!"Failed contacting Core privilege verifier: {err}" 126)
  let rawHarness := ((req.fieldStr? "name").orElse (fun _ => req.fieldStr? "harness")).getD ""
  let version := (req.fieldStr? "version").getD ""
  let some harness := normalizeHarnessName? rawHarness
    | return (← replyError cfd "Invalid harness name or semantic version" 2)
  if !isStrictSemver version then
    return (← replyError cfd "Invalid harness name or semantic version" 2)
  let ts ← nowEpoch
  appendAuditLine cfg.auditLog <| JVal.obj #[
    ("ts", .uint64 ts),
    ("action", .str "update_harness"),
    ("name", .str harness),
    ("version", .str version),
    ("peer_uid", match peer.uid with | some u => .nat u.toNat | none => .null),
    ("peer_pid", match peer.pid with | some p => .nat p.toNat | none => .null)
  ]
  let helperPath := "/usr/local/sbin/orb-update-harness"
  let helperStat ← statPath helperPath
  let (cmd, args) : String × Array String :=
    if helperStat.exists_ && helperStat.isReg then
      ("/usr/bin/python3", #[helperPath, harness, version])
    else
      match harness with
      | "claude"   => ("/usr/local/bin/bun", #["install", "-g", s!"@anthropic-ai/claude-code@{version}"])
      | "codex"    => ("/usr/local/bin/bun", #["install", "-g", s!"@openai/codex@{version}"])
      | "opencode" => ("/usr/local/bin/bun", #["install", "-g", s!"opencode-ai@{version}"])
      | "grok"     => ("/usr/local/bin/bun", #["install", "-g", s!"@xai/grok@{version}"])
      | _          => ("/opt/mistral-vibe/bin/pip", #["install", "--no-cache-dir", s!"mistral-vibe=={version}"])
  try
    let out ← IO.Process.output {
      cmd := cmd
      args := args
      env := #[
        ("PATH", some "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        ("HOME", some "/root"),
        ("LANG", some "C.UTF-8")
      ]
    }
    replyJson cfd <| JVal.obj #[
      ("ok", .bool (out.exitCode == 0)),
      ("exit_code", .nat out.exitCode.toNat),
      ("stdout", .str out.stdout),
      ("stderr", .str out.stderr)
    ]
  catch e =>
    replyError cfd s!"Harness update failed: {e}" 1

def handleExec (cfd : LeanSys.Posix.Fd) (cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  if (req.field? "api_url").isSome || (req.field? "api_token").isSome then
    return (← replyError cfd "Client-supplied api_url/api_token are forbidden; orb-privd uses its pinned Core endpoint" 2)
  let targetHost := ((req.fieldStr? "target_host").getD "self").trimAscii.toString
  let tl := targetHost.toLower
  if !(tl.isEmpty || tl == "self" || tl == "local" || tl == "localhost" || tl == cfg.hostLabel.trimAscii.toString.toLower) then
    return (← replyError cfd s!"orb-sudo runs only on this machine ({cfg.hostLabel}); for {targetHost} use the execute_privileged_command tool" 2)
  let leaseToken := ((req.fieldStr? "lease_token").getD "").trimAscii.toString
  let missionId := ((req.fieldStr? "mission_id").getD "").trimAscii.toString
  let some rawArgv := req.fieldArr? "argv"
    | return (← replyError cfd "mission_id, lease_token, and argv are required" 2)
  let mut argv : Array String := #[]
  for item in rawArgv do
    match item.asStr? with
    | some s => argv := argv.push s
    | none => return (← replyError cfd "Non-string element in argv" 2)
  if leaseToken.isEmpty || missionId.isEmpty || argv.isEmpty then
    return (← replyError cfd "mission_id, lease_token, and argv are required" 2)
  let cwdStr := ((req.fieldStr? "cwd").filter (!·.isEmpty)).getD "/root"
  let mut envPairs : Array (String × String) := #[]
  if let some envObj := (req.field? "env") >>= JVal.asObj? then
    for (ek, ev) in envObj do
      envPairs := envPairs.push (ek, (ev.asStr?).getD "")
  let commandStr := String.intercalate " " argv.toList
  let verifyUrl := stripTrailingSlash cfg.apiUrl ++ "/api/privilege-access/verify-and-log"
  let preBody := JVal.obj #[
    ("mission_id", .str missionId),
    ("lease_token", .str leaseToken),
    ("target_host", .str targetHost),
    ("executing_host", .str cfg.hostLabel),
    ("command", .str s!"[pre-exec] {commandStr}"),
    ("argv", .arr (argv.map .str)),
    ("cwd", .str cwdStr)
  ]
  let (scopeStr, allowedUnits, reqForceCmd, grantId) ←
    match (← sendJsonRequest "POST" verifyUrl cfg.apiToken (some preBody) #[("User-Agent", "orb-privd/1.0")] 15000) with
    | .ok (status, text, j?) =>
      if !(200 ≤ status && status < 300) then
        return (← replyError cfd s!"Core rejected privilege lease ({status}): {text}" 126)
      match j? with
      | none => return (← replyError cfd "Core returned non-JSON privilege verification response" 126)
      | some j =>
        let valid := (j.fieldBool? "allow_exec").orElse (fun _ =>
          (j.fieldBool? "valid").orElse (fun _ => j.fieldBool? "allowed")) |>.getD false
        if !valid then
          return (← replyError cfd "Lease denied by Core" 126)
        let sc := (j.fieldStr? "scope").getD "root_exec"
        let unitsArr := match j.fieldArr? "allowed_units" with
          | some arr => arr.filterMap JVal.asStr?
          | none => #[]
        let units := match j.fieldStr? "allowed_unit" with
          | some u => if u.isEmpty then unitsArr else unitsArr.push u
          | none => unitsArr
        let rf := (j.fieldBool? "require_force_cmd").getD false
        let gid := (j.fieldStr? "grant_id").getD ""
        pure (sc, units, rf, gid)
    | .error err =>
      return (← replyError cfd s!"Failed contacting Core privilege verifier: {err}" 126)

  match (← checkScopeRestrictions scopeStr allowedUnits argv (some cwdStr) envPairs reqForceCmd) with
  | .error err =>
    return (← replyError cfd err 126)
  | .ok _ => pure ()

  let some resolvedBin ← resolveTrustedBinary? argv[0]!
    | return (← replyError cfd s!"Executable `{argv[0]!}` not found in trusted system directories" 127)
  let cwdStat ← statPath cwdStr
  let execCwd := if cwdStat.exists_ && cwdStat.isDir then cwdStr else "/root"
  let rawTimeout := (req.fieldNat? "timeout_secs").getD 600
  let boundedTimeoutSecs := Nat.max 1 (Nat.min rawTimeout 600)
  let timeoutBin ← resolveTrustedBinary? "timeout"
  let (execCmd, execArgs) := match timeoutBin with
    | some tb => (tb, #[s!"{boundedTimeoutSecs}s", resolvedBin] ++ argv.extract 1 argv.size)
    | none => (resolvedBin, argv.extract 1 argv.size)
  let t0Ms ← IO.monoMsNow
  let out ← try
    IO.Process.output {
      cmd := execCmd
      args := execArgs
      cwd := some (System.FilePath.mk execCwd)
      env := #[
        ("PATH", some trustedExecPath),
        ("HOME", some "/root"),
        ("LANG", some "C.UTF-8"),
        ("ORB_MISSION_ID", some missionId),
        ("ORB_JIT_GRANT_ID", some grantId)
      ]
    }
  catch e =>
    return (← replyError cfd s!"Execution failed: {e}" 126)
  let t1Ms ← IO.monoMsNow
  let durationMs := t1Ms - t0Ms
  let stdoutSha := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes out.stdout.toUTF8)
  let ts ← nowEpoch
  appendAuditLine cfg.auditLog <| JVal.obj #[
    ("ts", .uint64 ts),
    ("action", .str "exec"),
    ("mission_id", .str missionId),
    ("scope", .str scopeStr),
    ("argv", .arr (argv.map .str)),
    ("exit_code", .nat out.exitCode.toNat),
    ("duration_ms", .nat durationMs),
    ("stdout_sha256", .str stdoutSha),
    ("peer_uid", match peer.uid with | some u => .nat u.toNat | none => .null)
  ]
  let postBody := JVal.obj #[
    ("mission_id", .str missionId),
    ("lease_token", .str leaseToken),
    ("target_host", .str targetHost),
    ("executing_host", .str cfg.hostLabel),
    ("command", .str commandStr),
    ("argv", .arr (argv.map .str)),
    ("cwd", .str cwdStr),
    ("exit_code", .nat out.exitCode.toNat),
    ("duration_ms", .nat durationMs),
    ("stdout_sha256", .str stdoutSha)
  ]
  let _ ← sendJsonRequest "POST" verifyUrl cfg.apiToken (some postBody) #[("User-Agent", "orb-privd/1.0")] 10000
  replyJson cfd <| JVal.obj #[
    ("ok", .bool (out.exitCode == 0)),
    ("exit_code", .nat out.exitCode.toNat),
    ("duration_ms", .nat durationMs),
    ("stdout_sha256", .str stdoutSha),
    ("stdout", .str out.stdout),
    ("stderr", .str out.stderr)
  ]

def handleConnection (cfd : LeanSys.Posix.Fd) (cfg : PrivdConfig) : IO Unit := do
  try
    let peer ← getPeerCred (Int32.ofBitVec (BitVec.ofNat 32 cfd.raw.toNat))
    let mut rawBytes := ByteArray.emptyWithCapacity 4096
    while rawBytes.size < 262144 do
      match (← readSocketTimed cfd 16384 10000) with
      | .eof => break
      | .timeout => break
      | .fatal _ => break
      | .bytes chunk =>
        rawBytes := rawBytes ++ chunk
        if chunk.data.any (· == 10) then break
    if rawBytes.isEmpty then
      let _ ← LeanSys.Posix.closeFd cfd
      return
    match Json.parseBytes rawBytes with
    | .error err =>
      replyError cfd s!"Invalid JSON request: {err}" 2
    | .ok req =>
      let action := (req.fieldStr? "action").getD "exec"
      if action == "ping" then
        replyJson cfd <| JVal.obj #[
          ("ok", .bool true),
          ("service", .str "orb-privd"),
          ("host", .str cfg.hostLabel),
          ("uid", match peer.uid with | some u => .nat u.toNat | none => .null),
          ("gid", match peer.gid with | some g => .nat g.toNat | none => .null),
          ("pid", match peer.pid with | some p => .nat p.toNat | none => .null)
        ]
      else if action == "update_harness" then
        handleUpdateHarness cfd cfg peer req
      else if action == "exec" then
        handleExec cfd cfg peer req
      else
        replyError cfd s!"Unknown action: {action}" 2
    let _ ← LeanSys.Posix.closeFd cfd
  catch _ =>
    let _ ← LeanSys.Posix.closeFd cfd

/-- CLI mode `orb-privd --check-scope-json <json>` for unit/confinement verification without root socket. -/
private def runCheckScopeCli (rawJson : String) : IO UInt32 := do
  match Json.parse rawJson with
  | .error err =>
    IO.eprintln s!"invalid json: {err}"
    return 2
  | .ok req =>
    let scope := (req.fieldStr? "scope").getD ""
    let units := match req.fieldStr? "allowed_unit" with
      | some u => if u.isEmpty then #[] else #[u]
      | none => #[]
    let argv := match req.fieldArr? "argv" with
      | some arr => arr.filterMap JVal.asStr?
      | none => #[]
    let cwd? := req.fieldStr? "cwd"
    let mut envPairs : Array (String × String) := #[]
    if let some envObj := (req.field? "env") >>= JVal.asObj? then
      for (ek, ev) in envObj do
        envPairs := envPairs.push (ek, (ev.asStr?).getD "")
    let reqForce := (req.fieldBool? "require_force_cmd").getD false
    match (← checkScopeRestrictions scope units argv cwd? envPairs reqForce) with
    | .ok packed =>
      IO.println s!"{packed}"
      return 0
    | .error err =>
      IO.eprintln err
      return 1

def runMain (args : List String) : IO UInt32 := do
  if args.contains "--help" || args.contains "-h" then
    IO.println "Usage: orb-privd [--socket <path>] | [--check-scope-json <json>]"
    return 0
  if args.contains "--version" then
    IO.println "orb-privd 1.3.0 (Lean 4)"
    return 0
  match args with
  | ["--check-scope-json", rawJson] =>
    return (← runCheckScopeCli rawJson)
  | _ => pure ()
  let euid ← geteuid
  let allowNonRoot := (← getEnvNonEmpty "ORB_PRIVD_ALLOW_NONROOT_TEST") == some "1"
  if euid != 0 && !allowNonRoot then
    IO.eprintln "orb-privd must run as root"
    return 1
  let sockArg := match args with
    | "--socket" :: p :: _ => some p
    | _ => none
  let sockEnv ← getEnvNonEmpty "ORB_PRIVD_SOCKET"
  let socketPath := sockArg.orElse (fun _ => sockEnv) |>.getD defaultPrivdSocket
  let groupName := (← firstEnvNonEmpty ["ORB_PRIVD_SOCKET_GROUP", "ORB_PRIVD_GROUP"]).getD "sandboxed-node"
  let apiUrl := (← firstEnvNonEmpty [
    "ORB_CORE_API_URL", "ORB_PRIVD_CORE_URL", "ORB_MCP_API_URL",
    "SANDBOXED_MCP_API_URL", "SANDBOXED_SH_API_URL", "API_URL"
  ]).getD "https://agent-backend.thomas.md"
  let apiToken ← firstEnvNonEmpty [
    "ORB_CORE_API_TOKEN", "ORB_PRIVD_CORE_TOKEN", "ORB_API_TOKEN",
    "SANDBOXED_SH_TOKEN", "ORB_NODE_TOKEN", "SANDBOXED_NODE_TOKEN",
    "SANDBOXED_SH_API_TOKEN", "API_TOKEN"
  ]
  let auditLog := (← getEnvNonEmpty "ORB_PRIVD_AUDIT_LOG").getD "/var/log/orb-privd/audit.jsonl"
  let hostEnv ← firstEnvNonEmpty ["ORB_NODE_NAME", "ORB_PRIVD_HOST_LABEL"]
  let sysHost ← getHostname
  let hostLabel := hostEnv.getD sysHost
  let sp := System.FilePath.mk socketPath
  if let some parent := sp.parent then
    IO.FS.createDirAll parent
  try IO.FS.removeFile sp catch _ => pure ()
  let lfd ← match (← LeanSys.Posix.unixListen socketPath 64) with
    | .ok f => pure f
    | .error e =>
      IO.eprintln s!"orb-privd: failed to bind Unix socket `{socketPath}`: {e}"
      return 1
  let _ ← chmod socketPath 0o660
  if euid == 0 then
    let rc ← chownGroup socketPath groupName
    if rc != 0 then
      let rc2 ← chownGroup socketPath "sandboxed-node"
      if rc2 != 0 then
        let _ ← chownGroup socketPath "orb-node"
  let cfg : PrivdConfig := { socketPath, groupName, apiUrl, apiToken, auditLog, hostLabel }
  IO.eprintln s!"orb-privd listening on {socketPath} (host={hostLabel})"
  while true do
    match (← LeanSys.Posix.tcpAcceptPoll lfd 1000) with
    | .ok cfd =>
      let _ ← IO.asTask (prio := .dedicated) (handleConnection cfd cfg)
    | .error _ => pure ()
  return 0

end OrbBin.Privd
