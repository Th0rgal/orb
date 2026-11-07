/-
  OrbBin.PrivdMain: Native Lean `orb-privd` Local Privileged Execution & Harness Broker (`0 import Lean`).
  Listens on `/run/orb-privd.sock` (`0660 root:sandboxed-node`), verifies peer credentials via `SO_PEERCRED`,
  enforces `Orb.Kernel.privdCommandStep`, verifies biometric JIT leases against Core
  `POST /api/privilege-access/verify-and-log`, and logs pre/post execution SHA-256 digests.
-/
import LeanSys.Posix
import LeanSys.Auth
import OrbBin.Spec
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
  socketPath  : String
  groupName   : String
  apiUrl      : String
  apiToken    : Option String
  auditLog    : String
  hostLabel   : String
  trustedDirs : Array String := trustedExecDirs

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

def normalizeTargetLabel (raw hostLabel : String) : String :=
  let low := raw.trimAscii.toString.toLower
  let hLow := hostLabel.trimAscii.toString.toLower
  if low.isEmpty || low == "self" || low == "local" || low == "localhost" || low == hLow then
    hLow
  else
    low

def targetIdWord (label : String) : UInt32 := Id.run do
  let digest := LeanSys.Auth.sha256Bytes label.toUTF8
  let mut w : UInt32 := 0
  for i in [0:4] do
    w := w ||| ((digest.get! i).toUInt32 <<< (i * 8).toUInt32)
  return if w == 0 then 1 else w

def commandSha256Hex (argv : Array String) (cwd : String := "") : String :=
  let joined := cwd ++ "\x00" ++ String.intercalate "\x00" argv.toList
  LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes joined.toUTF8)

def commandDigestU64 (argv : Array String) (cwd : String := "") : UInt64 := Id.run do
  let joined := cwd ++ "\x00" ++ String.intercalate "\x00" argv.toList
  let digest := LeanSys.Auth.sha256Bytes joined.toUTF8
  let mut w : UInt64 := 0
  for i in [0:8] do
    w := w ||| ((digest.get! i).toUInt64 <<< (i * 8).toUInt64)
  return if w == 0 then 1 else w

def maxVerifyToExecWindowSecs : UInt64 := 30

def leaseEpochWord (leaseToken grantId : String) : UInt64 := Id.run do
  let digest := LeanSys.Auth.sha256Bytes (leaseToken ++ "\x00" ++ grantId).toUTF8
  let mut w : UInt64 := 0
  for i in [0:8] do
    w := w ||| ((digest.get! i).toUInt64 <<< (i * 8).toUInt64)
  return if w == 0 then 1 else w

def principalKindForScope (scopeStr : String) : UInt8 :=
  match parseGrantScope? scopeStr with
  | some s => s + 1
  | none => 0

private def statIdentityTag (id : StatIdentity) : String :=
  if !id.exists_ then "missing"
  else s!"{id.dev}:{id.ino}:{id.size}:{id.mtime}:{id.uid}:{id.gid}:{id.mode}"

def validateExecCwd (cwdRaw : String) : IO (Except String (String × StatIdentity)) := do
  let s := cwdRaw.trimAscii.toString
  if s.isEmpty || !s.startsWith "/" then
    return .error s!"Invalid non-absolute working directory `{cwdRaw}`"
  if (s.splitOn "/").any (· == "..") then
    return .error s!"Working directory traversal rejected: `{cwdRaw}`"
  let st ← statPath s
  if !st.exists_ || st.isSymlink || !st.isDir then
    return .error s!"Working directory `{s}` does not exist or is a symlink/non-directory"
  let id ← statIdentity s false
  if !id.exists_ then
    return .error s!"Working directory `{s}` stat identity unavailable"
  return .ok (s, id)

def validateTrustedHelperFile (path : String) : IO (Option StatIdentity) := do
  let st ← statPath path
  if !st.exists_ || st.isSymlink || !st.isReg || !st.ownedByRoot then
    return none
  if (st.mode &&& 0o022) != 0 || (st.mode &&& 0o111) == 0 then
    return none
  let id ← statIdentity path false
  if !id.exists_ || id.uid != 0 then
    return none
  return some id

def validateExecBinaryIdentity
    (binPath : String)
    (requireTrustedDir : Bool := true)
    (execDirs : Array String := trustedExecDirs) : IO (Except String (String × StatIdentity × StatIdentity)) := do
  let stLink ← statPath binPath
  if !stLink.exists_ then
    return .error s!"Executable `{binPath}` not found"
  let resolved ←
    if stLink.isSymlink then
      try
        let rp ← IO.FS.realPath (System.FilePath.mk binPath)
        pure rp.toString
      catch _ =>
        return .error s!"Executable symlink `{binPath}` could not be resolved"
    else
      pure binPath
  if requireTrustedDir then
    let dir := ((System.FilePath.mk resolved).parent.map toString).getD ""
    if !execDirs.contains dir then
      return .error s!"Executable `{resolved}` is outside trusted system directories"
  let stTarget ← statPath resolved
  if !stTarget.exists_ || stTarget.isSymlink || !stTarget.isReg then
    return .error s!"Executable `{resolved}` is not a regular file"
  if (stTarget.mode &&& 0o022) != 0 || (stTarget.mode &&& 0o111) == 0 then
    return .error s!"Executable `{resolved}` has unsafe permissions or is not executable"
  let linkId ← statIdentity binPath false
  let targetId ← statIdentity resolved true
  if !linkId.exists_ || !targetId.exists_ then
    return .error s!"Executable `{binPath}` stat identity unavailable"
  return .ok (resolved, linkId, targetId)

def executionEvidenceDigestU64
    (resolvedBin : String)
    (argv : Array String)
    (execCwd normTarget : String)
    (binLinkId binTargetId cwdId : StatIdentity)
    (auxId? : Option StatIdentity := none) : UInt64 := Id.run do
  let auxTag := match auxId? with | some a => statIdentityTag a | none => "no-aux"
  let material :=
    String.intercalate "\x00" ([
      resolvedBin,
      execCwd,
      normTarget,
      statIdentityTag binLinkId,
      statIdentityTag binTargetId,
      statIdentityTag cwdId,
      auxTag
    ] ++ argv.toList)
  let digest := LeanSys.Auth.sha256Bytes material.toUTF8
  let mut w : UInt64 := 0
  for i in [0:8] do
    w := w ||| ((digest.get! i).toUInt64 <<< (i * 8).toUInt64)
  return if w == 0 then 1 else w

private def parseCoreBunkerState (j : JVal) (coreAllowed : Bool) : UInt8 :=
  match j.field? "bunker_state" with
  | none | some .null => if coreAllowed then 0 else 1
  | some (.bool false) => 0
  | some (.bool true) => 1
  | some v =>
    match v.asNat? with
    | some 0 => 0
    | some n => if n < 256 then n.toUInt8 else 1
    | none => 1

def verifyExecWindowAndToctou
    (principalKind bunkerState : UInt8)
    (obsTarget execTarget : UInt32)
    (obsLease liveLease obsTick execNowTick : UInt64)
    (coreExpiryTick? : Option UInt64)
    (obsDigest execDigest : UInt64)
    (grantPresent allowExec : UInt8)
    (maxWindowSecs : UInt64 := maxVerifyToExecWindowSecs) : UInt32 :=
  let windowCap := obsTick + maxWindowSecs
  let deadlineTick := match coreExpiryTick? with
    | some ce => if ce < windowCap then ce else windowCap
    | none => windowCap
  let effNowTick := if execNowTick < obsTick then deadlineTick else execNowTick
  OrbBin.Spec.verifyPrivdToctouStep
    principalKind bunkerState obsTarget execTarget obsLease liveLease effNowTick deadlineTick obsDigest execDigest grantPresent allowExec

def handleUpdateHarness (cfd : LeanSys.Posix.Fd) (cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  let rawHarness := ((req.fieldStr? "name").orElse (fun _ => req.fieldStr? "harness")).getD ""
  let version := (req.fieldStr? "version").getD ""
  let some harness := normalizeHarnessName? rawHarness
    | return (← replyError cfd "Invalid harness name or semantic version" 2)
  if !isStrictSemver version then
    return (← replyError cfd "Invalid harness name or semantic version" 2)
  let execCwdRaw := ((req.fieldStr? "cwd").filter (!·.isEmpty)).getD "/root"
  let (execCwd, obsCwdId) ← match (← validateExecCwd execCwdRaw) with
    | .ok pair => pure pair
    | .error err => return (← replyError cfd err 126)
  let helperPath := "/usr/local/sbin/orb-update-harness"
  let obsHelperId? ← validateTrustedHelperFile helperPath
  let (rawCmd, args) : String × Array String :=
    if obsHelperId?.isSome then
      ("/usr/bin/python3", #[helperPath, harness, version])
    else
      match harness with
      | "claude"   => ("/usr/local/bin/bun", #["install", "-g", s!"@anthropic-ai/claude-code@{version}"])
      | "codex"    => ("/usr/local/bin/bun", #["install", "-g", s!"@openai/codex@{version}"])
      | "opencode" => ("/usr/local/bin/bun", #["install", "-g", s!"opencode-ai@{version}"])
      | "grok"     => ("/usr/local/bin/bun", #["install", "-g", s!"@xai/grok@{version}"])
      | _          => ("/opt/mistral-vibe/bin/pip", #["install", "--no-cache-dir", s!"mistral-vibe=={version}"])
  let leaseToken := ((req.fieldStr? "lease_token").getD "").trimAscii.toString
  let missionId := ((req.fieldStr? "mission_id").getD "system-harness-update").trimAscii.toString
  if peer.uid != some 0 && leaseToken.isEmpty then
    return (← replyError cfd "update_harness requires root peer UID or an active Core lease_token" 126)
  let (resolvedCmd, obsLinkId, obsTargetId) ← match (← validateExecBinaryIdentity rawCmd false) with
    | .ok triple => pure triple
    | .error err => return (← replyError cfd err 127)
  let fullArgv := #[resolvedCmd] ++ args
  let normTarget := normalizeTargetLabel "self" cfg.hostLabel
  let obsTarget := targetIdWord normTarget
  let obsDigest := executionEvidenceDigestU64 resolvedCmd fullArgv execCwd normTarget obsLinkId obsTargetId obsCwdId obsHelperId?
  let obsTick ← nowEpoch
  let obsLeaseReq := leaseEpochWord leaseToken missionId
  let verifyUrl := stripTrailingSlash cfg.apiUrl ++ "/api/privilege-access/verify-and-log"
  let mut verifiedGrantId := "root-peer"
  if peer.uid != some 0 then
    let verifyBody := JVal.obj #[
      ("mission_id", .str missionId),
      ("lease_token", .str leaseToken),
      ("target_host", .str "self"),
      ("executing_host", .str cfg.hostLabel),
      ("command", .str "[update_harness]"),
      ("argv", .arr #[.str "orb-update-harness", .str harness, .str version]),
      ("cwd", .str execCwd)
    ]
    match (← sendJsonRequest "POST" verifyUrl cfg.apiToken (some verifyBody) #[("User-Agent", "orb-privd/1.0")] 15000) with
    | .ok (status, text, j?) =>
      if !(200 ≤ status && status < 300) then
        return (← replyError cfd s!"Core rejected update_harness lease ({status}): {text}" 126)
      let some j := j?
        | return (← replyError cfd "Core returned non-JSON update_harness verification response" 126)
      let allowExec := (j.fieldBool? "allow_exec") == some true
      let coreAllowed := ((j.fieldBool? "allowed").getD allowExec) && allowExec
      let scopeStr := (j.fieldStr? "scope").getD ""
      let gid := ((j.fieldStr? "grant_id").getD "").trimAscii.toString
      let scopeAllowed := scopeStr == "service_deploy" || scopeStr == "root_exec" || scopeStr == "host_admin"
      let bunkerState := parseCoreBunkerState j coreAllowed
      let coreExp? := j.fieldUInt64? "expires_at"
      let pk := principalKindForScope scopeStr
      let liveLease : UInt64 :=
        if coreAllowed && scopeAllowed && !gid.isEmpty then
          match j.fieldUInt64? "lease_epoch" with
          | some 0 => 0
          | some _ => obsLeaseReq
          | none => obsLeaseReq
        else 0
      let (_, execCwdId) ← match (← validateExecCwd execCwd) with
        | .ok pair => pure pair
        | .error err => return (← replyError cfd s!"TOCTOU working directory check failed: {err}" 126)
      let (execResolvedCmd, execLinkId, execTargetId) ← match (← validateExecBinaryIdentity rawCmd false) with
        | .ok triple => pure triple
        | .error err => return (← replyError cfd s!"TOCTOU executable check failed: {err}" 126)
      let execHelperId? ←
        if obsHelperId?.isSome then validateTrustedHelperFile helperPath
        else pure none
      if obsHelperId?.isSome && execHelperId?.isNone then
        return (← replyError cfd "TOCTOU helper script check failed" 126)
      let execNormTarget := normalizeTargetLabel cfg.hostLabel cfg.hostLabel
      let execTarget := targetIdWord execNormTarget
      let execDigest := executionEvidenceDigestU64 execResolvedCmd (#[execResolvedCmd] ++ args) execCwd execNormTarget execLinkId execTargetId execCwdId execHelperId?
      let execNowTick ← nowEpoch
      let grantPresent : UInt8 := if !gid.isEmpty then 1 else 0
      let allowFlag : UInt8 := if coreAllowed && scopeAllowed then 1 else 0
      let gate := verifyExecWindowAndToctou
        pk bunkerState obsTarget execTarget obsLeaseReq liveLease obsTick execNowTick coreExp? obsDigest execDigest grantPresent allowFlag
      if gate != 257 then
        return (← replyError cfd s!"Core rejected update_harness lease ({status}, scope={scopeStr}, gate={gate}): {text}" 126)
      verifiedGrantId := gid
    | .error err =>
      return (← replyError cfd s!"Failed contacting Core privilege verifier: {err}" 126)
  else
    let (_, execCwdId) ← match (← validateExecCwd execCwd) with
      | .ok pair => pure pair
      | .error err => return (← replyError cfd s!"Root update_harness TOCTOU cwd check failed: {err}" 126)
    let (execResolvedCmd, execLinkId, execTargetId) ← match (← validateExecBinaryIdentity rawCmd false) with
      | .ok triple => pure triple
      | .error err => return (← replyError cfd s!"Root update_harness TOCTOU binary check failed: {err}" 126)
    let execHelperId? ←
      if obsHelperId?.isSome then validateTrustedHelperFile helperPath
      else pure none
    if obsHelperId?.isSome && execHelperId?.isNone then
      return (← replyError cfd "Root update_harness TOCTOU helper check failed" 126)
    let execNormTarget := normalizeTargetLabel cfg.hostLabel cfg.hostLabel
    let execTarget := targetIdWord execNormTarget
    let execDigest := executionEvidenceDigestU64 execResolvedCmd (#[execResolvedCmd] ++ args) execCwd execNormTarget execLinkId execTargetId execCwdId execHelperId?
    let execNowTick ← nowEpoch
    let rootGate := verifyExecWindowAndToctou
      3 0 obsTarget execTarget 1 1 obsTick execNowTick none obsDigest execDigest 1 1
    if rootGate != 257 then
      return (← replyError cfd s!"Root update_harness failed TOCTOU verification (gate={rootGate})" 126)
  let cmdSha := commandSha256Hex fullArgv execCwd
  let ts ← nowEpoch
  appendAuditLine cfg.auditLog <| JVal.obj #[
    ("ts", .uint64 ts),
    ("action", .str "update_harness"),
    ("name", .str harness),
    ("version", .str version),
    ("grant_id", .str verifiedGrantId),
    ("command_sha256", .str cmdSha),
    ("peer_uid", match peer.uid with | some u => .nat u.toNat | none => .null),
    ("peer_pid", match peer.pid with | some p => .nat p.toNat | none => .null)
  ]
  try
    let out ← IO.Process.output {
      cmd := resolvedCmd
      args := args
      cwd := some (System.FilePath.mk execCwd)
      env := #[
        ("PATH", some "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        ("HOME", some "/root"),
        ("LANG", some "C.UTF-8")
      ]
    }
    let postTs ← nowEpoch
    appendAuditLine cfg.auditLog <| JVal.obj #[
      ("ts", .uint64 postTs),
      ("action", .str "update_harness_complete"),
      ("name", .str harness),
      ("version", .str version),
      ("grant_id", .str verifiedGrantId),
      ("exit_code", .nat out.exitCode.toNat),
      ("command_sha256", .str cmdSha)
    ]
    if peer.uid != some 0 && !leaseToken.isEmpty then
      let postBody := JVal.obj #[
        ("mission_id", .str missionId),
        ("lease_token", .str leaseToken),
        ("target_host", .str "self"),
        ("executing_host", .str cfg.hostLabel),
        ("command", .str "[update_harness]"),
        ("argv", .arr #[.str "orb-update-harness", .str harness, .str version]),
        ("cwd", .str execCwd),
        ("exit_code", .nat out.exitCode.toNat),
        ("command_sha256", .str cmdSha)
      ]
      let _ ← sendJsonRequest "POST" verifyUrl cfg.apiToken (some postBody) #[("User-Agent", "orb-privd/1.0")] 10000
    replyJson cfd <| JVal.obj #[
      ("ok", .bool (out.exitCode == 0)),
      ("exit_code", .nat out.exitCode.toNat),
      ("command_sha256", .str cmdSha),
      ("stdout", .str out.stdout),
      ("stderr", .str out.stderr)
    ]
  catch e =>
    replyError cfd s!"Harness update failed: {e}" 1

def handleExec
    (cfd : LeanSys.Posix.Fd)
    (cfg : PrivdConfig)
    (peer : PeerCred)
    (req : JVal)
    (betweenVerifyAndExecHook? : Option (IO Unit) := none) : IO Unit := do
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
  let (execCwd, obsCwdId) ← match (← validateExecCwd cwdStr) with
    | .ok pair => pure pair
    | .error err => return (← replyError cfd err 126)
  let mut envPairs : Array (String × String) := #[]
  if let some envObj := (req.field? "env") >>= JVal.asObj? then
    for (ek, ev) in envObj do
      envPairs := envPairs.push (ek, (ev.asStr?).getD "")
  let some resolvedBin0 ← resolveTrustedBinary? argv[0]! cfg.trustedDirs
    | return (← replyError cfd s!"Executable `{argv[0]!}` not found in trusted system directories" 127)
  let (resolvedBin, obsBinLinkId, obsBinTargetId) ← match (← validateExecBinaryIdentity resolvedBin0 true cfg.trustedDirs) with
    | .ok triple => pure triple
    | .error err => return (← replyError cfd err 127)
  let timeoutBin? ← resolveTrustedBinary? "timeout" cfg.trustedDirs
  let obsTimeoutId? ← match timeoutBin? with
    | some tb =>
      match (← validateExecBinaryIdentity tb true cfg.trustedDirs) with
      | .ok (_, _, tid) => pure (some tid)
      | .error _ => pure none
    | none => pure none
  let normTarget := normalizeTargetLabel targetHost cfg.hostLabel
  let obsTarget := targetIdWord normTarget
  let obsDigest := executionEvidenceDigestU64 resolvedBin argv execCwd normTarget obsBinLinkId obsBinTargetId obsCwdId obsTimeoutId?
  let obsLeaseReq := leaseEpochWord leaseToken missionId
  let obsTick ← nowEpoch
  let commandStr := String.intercalate " " argv.toList
  let verifyUrl := stripTrailingSlash cfg.apiUrl ++ "/api/privilege-access/verify-and-log"
  let preBody := JVal.obj #[
    ("mission_id", .str missionId),
    ("lease_token", .str leaseToken),
    ("target_host", .str targetHost),
    ("executing_host", .str cfg.hostLabel),
    ("command", .str s!"[pre-exec] {commandStr}"),
    ("argv", .arr (argv.map .str)),
    ("cwd", .str execCwd)
  ]
  let (scopeStr, allowedUnits, reqForceCmd, grantId, allowExecFlag, bunkerState, expTickOpt, liveLease) ←
    match (← sendJsonRequest "POST" verifyUrl cfg.apiToken (some preBody) #[("User-Agent", "orb-privd/1.0")] 15000) with
    | .ok (status, text, j?) =>
      if !(200 ≤ status && status < 300) then
        return (← replyError cfd s!"Core rejected privilege lease ({status}): {text}" 126)
      match j? with
      | none => return (← replyError cfd "Core returned non-JSON privilege verification response" 126)
      | some j =>
        let allowExec := (j.fieldBool? "allow_exec") == some true
        let coreAllowed := ((j.fieldBool? "allowed").getD allowExec) && allowExec
        if !coreAllowed then
          return (← replyError cfd "Lease denied by Core" 126)
        let sc := ((j.fieldStr? "scope").getD "").trimAscii.toString
        let unitsArr := match j.fieldArr? "allowed_units" with
          | some arr => arr.filterMap JVal.asStr?
          | none => #[]
        let units := match j.fieldStr? "allowed_unit" with
          | some u => if u.isEmpty then unitsArr else unitsArr.push u
          | none => unitsArr
        let rf := (j.fieldBool? "require_force_cmd").getD false
        let gid := ((j.fieldStr? "grant_id").getD "").trimAscii.toString
        if gid.isEmpty then
          return (← replyError cfd "Core privilege response missing grant_id" 126)
        let bk := parseCoreBunkerState j coreAllowed
        let expOpt := j.fieldUInt64? "expires_at"
        let liveL : UInt64 :=
          if coreAllowed && !gid.isEmpty && (parseGrantScope? sc).isSome then
            match j.fieldUInt64? "lease_epoch" with
            | some 0 => 0
            | some _ => obsLeaseReq
            | none => obsLeaseReq
          else 0
        pure (sc, units, rf, gid, (if coreAllowed then (1 : UInt8) else 0), bk, expOpt, liveL)
    | .error err =>
      return (← replyError cfd s!"Failed contacting Core privilege verifier: {err}" 126)

  match (← checkScopeRestrictions scopeStr allowedUnits argv (some execCwd) envPairs reqForceCmd cfg.trustedDirs) with
  | .error err =>
    return (← replyError cfd err 126)
  | .ok _ => pure ()

  if let some hook := betweenVerifyAndExecHook? then
    hook

  let (_, execCwdId) ← match (← validateExecCwd execCwd) with
    | .ok pair => pure pair
    | .error err => return (← replyError cfd s!"Rejected by orb-privd TOCTOU cwd check: {err}" 126)
  let some resolvedBinPost0 ← resolveTrustedBinary? argv[0]! cfg.trustedDirs
    | return (← replyError cfd s!"Rejected by orb-privd TOCTOU binary resolution (`{argv[0]!}`)" 126)
  let (resolvedBinPost, execBinLinkId, execBinTargetId) ← match (← validateExecBinaryIdentity resolvedBinPost0 true cfg.trustedDirs) with
    | .ok triple => pure triple
    | .error err => return (← replyError cfd s!"Rejected by orb-privd TOCTOU binary check: {err}" 126)
  let (useTimeoutBin?, execTimeoutId?) ← match timeoutBin?, obsTimeoutId? with
    | some tb, some _ =>
      match (← validateExecBinaryIdentity tb true cfg.trustedDirs) with
      | .ok (rtb, _, tid) => pure (some rtb, some tid)
      | .error _ => pure (none, none)
    | _, _ => pure (none, none)
  let pk := principalKindForScope scopeStr
  let execNormTarget := normalizeTargetLabel cfg.hostLabel cfg.hostLabel
  let execTarget := targetIdWord execNormTarget
  let execDigest := executionEvidenceDigestU64 resolvedBinPost argv execCwd execNormTarget execBinLinkId execBinTargetId execCwdId execTimeoutId?
  let execNowTick ← nowEpoch
  let grantPresent : UInt8 := if !grantId.isEmpty then 1 else 0
  let toctouGate := verifyExecWindowAndToctou
    pk bunkerState obsTarget execTarget obsLeaseReq liveLease obsTick execNowTick expTickOpt obsDigest execDigest grantPresent allowExecFlag
  if toctouGate != 257 then
    return (← replyError cfd s!"Rejected by orb-privd TOCTOU gate ({toctouGate})" 126)
  let cmdSha := commandSha256Hex argv execCwd
  let rawTimeout := (req.fieldNat? "timeout_secs").getD 600
  let boundedTimeoutSecs := Nat.max 1 (Nat.min rawTimeout 600)
  let (execCmd, execArgs) := match useTimeoutBin? with
    | some tb => (tb, #[s!"{boundedTimeoutSecs}s", resolvedBinPost] ++ argv.extract 1 argv.size)
    | none => (resolvedBinPost, argv.extract 1 argv.size)
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
    ("grant_id", .str grantId),
    ("scope", .str scopeStr),
    ("argv", .arr (argv.map .str)),
    ("exit_code", .nat out.exitCode.toNat),
    ("duration_ms", .nat durationMs),
    ("command_sha256", .str cmdSha),
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
    ("cwd", .str execCwd),
    ("exit_code", .nat out.exitCode.toNat),
    ("duration_ms", .nat durationMs),
    ("command_sha256", .str cmdSha),
    ("stdout_sha256", .str stdoutSha)
  ]
  let _ ← sendJsonRequest "POST" verifyUrl cfg.apiToken (some postBody) #[("User-Agent", "orb-privd/1.0")] 10000
  replyJson cfd <| JVal.obj #[
    ("ok", .bool (out.exitCode == 0)),
    ("exit_code", .nat out.exitCode.toNat),
    ("duration_ms", .nat durationMs),
    ("command_sha256", .str cmdSha),
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
