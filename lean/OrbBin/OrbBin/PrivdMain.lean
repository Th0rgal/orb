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

/-! ### Multi-User Confined Execution Broker (`ensure_mission_user`, `spawn_user_job`, `control_user_job`, `user_fs_op`) -/

private def isDeniedUserFsSegment (raw : String) : Bool :=
  let n := raw.toLower
  n == ".env" || n.startsWith ".env." ||
  n == ".ssh" || n == ".aws" || n == ".gnupg" || n == ".git" ||
  n == "credentials.json" || n == ".credentials.json" || n == "auth.json" ||
  n == "id_rsa" || n == "id_ed25519" || n == ".git-credentials" ||
  n.endsWith ".pem" || n.endsWith ".key"

private def resolveAllowedNodePeer (peer : PeerCred) : IO Bool := do
  let allowNonRoot := (← getEnvNonEmpty "ORB_PRIVD_ALLOW_NONROOT_TEST") == some "1"
  let myEuid ← geteuid
  let some pUid := peer.uid
    | return allowNonRoot
  if pUid == 0 then return true
  if allowNonRoot && pUid == myEuid then return true
  for uName in #["sandboxed-node", "orb-node"] do
    if let .ok out ← (IO.Process.output { cmd := "id", args := #["-u", uName] }).toBaseIO then
      if out.exitCode == 0 then
        if let some uNat := out.stdout.trimAscii.toString.toNat? then
          if pUid == uNat.toUInt32 then return true
  return false

private def lookupUnixUserInfo (uName : String) : IO (Option (UInt32 × UInt32 × String × Array String)) := do
  let py :=
    "import grp, json, pwd, sys\n" ++
    "u = sys.argv[1]\n" ++
    "try:\n" ++
    "  pw = pwd.getpwnam(u)\n" ++
    "  gnames = []\n" ++
    "  for g in grp.getgrall():\n" ++
    "    if g.gr_gid == pw.pw_gid or u in g.gr_mem:\n" ++
    "      gnames.append(g.gr_name)\n" ++
    "  print(json.dumps({'ok': True, 'uid': pw.pw_uid, 'gid': pw.pw_gid, 'dir': pw.pw_dir, 'groups': gnames}))\n" ++
    "except KeyError:\n" ++
    "  print(json.dumps({'ok': False}))\n"
  let .ok out ← (IO.Process.output { cmd := "python3", args := #["-c", py, uName] }).toBaseIO
    | return none
  if out.exitCode != 0 then return none
  let .ok jv := Json.parse out.stdout | return none
  if (jv.fieldBool? "ok") != some true then return none
  let some uid := jv.fieldNat? "uid" | return none
  let some gid := jv.fieldNat? "gid" | return none
  let dir := (jv.fieldStr? "dir").getD ""
  let groups := ((jv.fieldArr? "groups").getD #[]).filterMap JVal.asStr?
  return some (uid.toUInt32, gid.toUInt32, dir, groups)

private def populateUserHomeDropped
    (isNonRootTest : Bool)
    (uid gid : UInt32)
    (homeRoot uName missionId : String)
    (wsFiles : Array (String × String)) : IO (Except String (String × String)) := do
  let py :=
    "import base64, json, os, shutil, stat, sys\n" ++
    "req = json.loads(sys.stdin.read())\n" ++
    "nonroot = req['nonroot']\n" ++
    "uid = int(req['uid']); gid = int(req['gid'])\n" ++
    "home_root = req['home_root']; u_name = req['unix_username']; mid = req['mission_id']\n" ++
    "home_dir = os.path.join(home_root, u_name)\n" ++
    "st_root = os.lstat(home_root)\n" ++
    "if stat.S_ISLNK(st_root.st_mode) or not stat.S_ISDIR(st_root.st_mode):\n" ++
    "  raise RuntimeError('home_root is not a real directory')\n" ++
    "if not os.path.lexists(home_dir):\n" ++
    "  os.mkdir(home_dir, 0o700)\n" ++
    "st_home = os.lstat(home_dir)\n" ++
    "if stat.S_ISLNK(st_home.st_mode) or not stat.S_ISDIR(st_home.st_mode):\n" ++
    "  raise RuntimeError('home_dir is a symlink or non-directory')\n" ++
    "if not nonroot:\n" ++
    "  os.chown(home_dir, uid, gid)\n" ++
    "os.chmod(home_dir, 0o700)\n" ++
    "shared_elan = req.get('shared_elan', '/opt/orb/elan')\n" ++
    "has_elan = False\n" ++
    "if os.path.lexists(shared_elan):\n" ++
    "  st_el = os.lstat(shared_elan)\n" ++
    "  if stat.S_ISLNK(st_el.st_mode) or (not nonroot and (st_el.st_uid != 0 or st_el.st_gid != 0)):\n" ++
    "    raise RuntimeError('shared_elan is not root-owned non-symlink directory')\n" ++
    "  has_elan = stat.S_ISDIR(st_el.st_mode)\n" ++
    "if not nonroot:\n" ++
    "  os.setgroups([gid])\n" ++
    "  os.setgid(gid)\n" ++
    "  os.setuid(uid)\n" ++
    "os.umask(0o077)\n" ++
    "if has_elan:\n" ++
    "  dest_elan = os.path.join(home_dir, '.elan')\n" ++
    "  for sub in ['', 'bin', 'toolchains']:\n" ++
    "    p = os.path.join(dest_elan, sub) if sub else dest_elan\n" ++
    "    if not os.path.lexists(p): os.mkdir(p, 0o700)\n" ++
    "  bin_src = os.path.join(shared_elan, 'bin')\n" ++
    "  if os.path.isdir(bin_src):\n" ++
    "    for fn in os.listdir(bin_src):\n" ++
    "      sp = os.path.join(bin_src, fn); dp = os.path.join(dest_elan, 'bin', fn)\n" ++
    "      if os.path.isfile(sp) and not os.path.islink(dp):\n" ++
    "        shutil.copy2(sp, dp); os.chmod(dp, 0o755)\n" ++
    "  tc_src = os.path.join(shared_elan, 'toolchains')\n" ++
    "  if os.path.isdir(tc_src):\n" ++
    "    for fn in os.listdir(tc_src):\n" ++
    "      sp = os.path.join(tc_src, fn); dp = os.path.join(dest_elan, 'toolchains', fn)\n" ++
    "      if os.path.isdir(sp):\n" ++
    "        if os.path.lexists(dp) and os.path.islink(dp): os.unlink(dp)\n" ++
    "        if not os.path.lexists(dp): os.symlink(sp, dp)\n" ++
    "  st_toml = os.path.join(shared_elan, 'settings.toml')\n" ++
    "  dt_toml = os.path.join(dest_elan, 'settings.toml')\n" ++
    "  if os.path.isfile(st_toml) and not os.path.lexists(dt_toml):\n" ++
    "    shutil.copy2(st_toml, dt_toml); os.chmod(dt_toml, 0o600)\n" ++
    "for rc in ['.profile', '.bashrc']:\n" ++
    "  rcp = os.path.join(home_dir, rc)\n" ++
    "  line = 'export PATH=\"$HOME/.elan/bin:/opt/orb-tools/bin:/opt/sandboxed-tools/bin:$PATH\"\\n'\n" ++
    "  if not os.path.lexists(rcp):\n" ++
    "    fd = os.open(rcp, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)\n" ++
    "    os.write(fd, line.encode('utf-8')); os.close(fd)\n" ++
    "missions_root = os.path.join(home_dir, '.orb-missions')\n" ++
    "if not os.path.lexists(missions_root): os.mkdir(missions_root, 0o700)\n" ++
    "if stat.S_ISLNK(os.lstat(missions_root).st_mode): raise RuntimeError('symlinked .orb-missions')\n" ++
    "mcwd = os.path.join(missions_root, mid)\n" ++
    "if not os.path.lexists(mcwd): os.mkdir(mcwd, 0o700)\n" ++
    "if stat.S_ISLNK(os.lstat(mcwd).st_mode): raise RuntimeError('symlinked mission cwd')\n" ++
    "os.chmod(mcwd, 0o700)\n" ++
    "for item in req.get('files', []):\n" ++
    "  rel = item['path'].strip('/')\n" ++
    "  segs = [s for s in rel.split('/') if s and s != '.']\n" ++
    "  if not segs or any(s == '..' for s in segs): raise RuntimeError('unsafe workspace_file path')\n" ++
    "  cur = mcwd\n" ++
    "  for s in segs[:-1]:\n" ++
    "    cur = os.path.join(cur, s)\n" ++
    "    if not os.path.lexists(cur): os.mkdir(cur, 0o700)\n" ++
    "    if stat.S_ISLNK(os.lstat(cur).st_mode): raise RuntimeError('symlink in workspace_file parent')\n" ++
    "  leaf = os.path.join(cur, segs[-1])\n" ++
    "  raw = base64.b64decode(item['b64']) if item.get('is_b64') else item['content'].encode('utf-8')\n" ++
    "  fd = os.open(leaf, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)\n" ++
    "  os.write(fd, raw); os.close(fd)\n" ++
    "print(json.dumps({'ok': True, 'home_dir': home_dir, 'mission_cwd': mcwd}))\n"
  let sharedElan := (← getEnvNonEmpty "ORB_PRIVD_SHARED_ELAN").getD "/opt/orb/elan"
  let filesJson := wsFiles.map fun (p, c) => JVal.obj #[("path", .str p), ("content", .str c)]
  let stdinJson := renderCompact <| JVal.obj #[
    ("nonroot", .bool isNonRootTest),
    ("uid", .nat uid.toNat),
    ("gid", .nat gid.toNat),
    ("home_root", .str homeRoot),
    ("unix_username", .str uName),
    ("mission_id", .str missionId),
    ("shared_elan", .str sharedElan),
    ("files", .arr filesJson)
  ]
  match ← (IO.Process.output { cmd := "python3", args := #["-c", py] } (input? := some stdinJson)).toBaseIO with
  | .error e => return .error (toString e)
  | .ok out =>
    if out.exitCode != 0 then
      return .error s!"user home provisioning failed: {out.stderr.trimAscii}"
    let .ok jv := Json.parse out.stdout | return .error "corrupt user home provisioning JSON"
    let hd := (jv.fieldStr? "home_dir").getD s!"{homeRoot}/{uName}"
    let mc := (jv.fieldStr? "mission_cwd").getD s!"{homeRoot}/{uName}/.orb-missions/{missionId}"
    return .ok (hd, mc)

def handleEnsureMissionUser (cfd : LeanSys.Posix.Fd) (cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  let peerOk ← resolveAllowedNodePeer peer
  let uName := ((req.fieldStr? "unix_username").getD "").trimAscii.toString
  let missionId := ((req.fieldStr? "mission_id").getD "").trimAscii.toString
  let callerRole := ((req.fieldStr? "caller_role").getD "member").trimAscii.toString
  let nodeAdminOnly := (req.fieldBool? "node_admin_only").getD false
  let leaseVerified := (req.fieldBool? "lease_verified").getD true
  if !isSafeMissionDirIdent missionId then
    return (← replyError cfd "Invalid mission_id for ensure_mission_user" 2)
  if !Orb.Kernel.validUnixUsername uName then
    let _ := checkUserExecAdmission peerOk leaseVerified nodeAdminOnly callerRole uName 0 0 false false false
    return (← replyError cfd s!"Invalid or reserved unix_username '{uName}'" 2)
  let allowNonRoot := (← getEnvNonEmpty "ORB_PRIVD_ALLOW_NONROOT_TEST") == some "1"
  let myEuid ← geteuid
  let isNonRootTest := allowNonRoot && myEuid != 0
  let homeRoot := stripTrailingSlash ((← getEnvNonEmpty "ORB_PRIVD_HOME_ROOT").getD "/home")
  if isNonRootTest then
    IO.FS.createDirAll (System.FilePath.mk homeRoot)
  let (uid, gid, groupsDisjoint) ←
    if isNonRootTest then
      pure ((2500 : UInt32), (2500 : UInt32), true)
    else do
      let mut info? ← lookupUnixUserInfo uName
      if info?.isNone then
        let _ ← IO.Process.output {
          cmd := "/usr/sbin/groupadd"
          args := #["-K", "GID_MIN=2000", "-K", "GID_MAX=60000", uName]
        }
        let addOut ← IO.Process.output {
          cmd := "/usr/sbin/useradd"
          args := #[
            "--create-home",
            "--home-dir", s!"{homeRoot}/{uName}",
            "--shell", "/bin/bash",
            "-g", uName,
            "-G", "",
            "-K", "UID_MIN=2000",
            "-K", "UID_MAX=60000",
            uName
          ]
        }
        if addOut.exitCode != 0 then
          return (← replyError cfd s!"useradd failed for {uName}: {addOut.stderr.trimAscii}" 126)
        info? ← lookupUnixUserInfo uName
      let some (u, g, pwDir, grps) := info?
        | return (← replyError cfd s!"Failed resolving provisioned unix user {uName}" 126)
      if pwDir != s!"{homeRoot}/{uName}" then
        return (← replyError cfd s!"Existing unix user {uName} home '{pwDir}' != '{homeRoot}/{uName}'" 126)
      let disj := !(grps.any (fun gn => privilegedUnixGroups.contains gn.toLower))
      pure (u, g, disj)
  let stRoot ← statPath homeRoot
  let homeDirCand := s!"{homeRoot}/{uName}"
  let stHome0 ← statPath homeDirCand
  let homeNoSymlink :=
    stRoot.exists_ && stRoot.isDir && !stRoot.isSymlink &&
    (!stHome0.exists_ || (stHome0.isDir && !stHome0.isSymlink))
  let sharedElan := (← getEnvNonEmpty "ORB_PRIVD_SHARED_ELAN").getD "/opt/orb/elan"
  let stElan ← statPath sharedElan
  let elanOk :=
    if !stElan.exists_ then true
    else !stElan.isSymlink && stElan.isDir && (isNonRootTest || stElan.ownedByRoot)
  let gate := checkUserExecAdmission
    peerOk leaseVerified nodeAdminOnly callerRole uName uid gid groupsDisjoint homeNoSymlink elanOk
  if (gate &&& 1) != 1 then
    return (← replyError cfd s!"Rejected by orb_privd_user_exec_step (gate={gate})" 126)
  let mut wsFiles : Array (String × String) := #[]
  if let some fArr := req.fieldArr? "workspace_files" then
    for item in fArr do
      if let (some p, some c) := (item.fieldStr? "path", item.fieldStr? "content") then
        wsFiles := wsFiles.push (p, c)
  match ← populateUserHomeDropped isNonRootTest uid gid homeRoot uName missionId wsFiles with
  | .error err =>
    return (← replyError cfd err 126)
  | .ok (homeDir, missionCwd) =>
    let ts ← nowEpoch
    appendAuditLine cfg.auditLog <| JVal.obj #[
      ("ts", .uint64 ts),
      ("action", .str "ensure_mission_user"),
      ("unix_username", .str uName),
      ("mission_id", .str missionId),
      ("uid", .nat uid.toNat),
      ("gid", .nat gid.toNat)
    ]
    replyJson cfd <| JVal.obj #[
      ("ok", .bool true),
      ("uid", .nat uid.toNat),
      ("gid", .nat gid.toNat),
      ("home_dir", .str homeDir),
      ("mission_cwd", .str missionCwd)
    ]

private def privdStateDir : IO String := do
  return stripTrailingSlash ((← getEnvNonEmpty "ORB_PRIVD_STATE_DIR").getD "/run/orb-privd-jobs")

initialize privdSystemdExpandEnvCache : IO.Ref (Option Bool) ← IO.mkRef none

def escapeSystemdExecArgDollar (arg : String) : String :=
  String.intercalate "$$" (arg.splitOn "$")

def detectPrivdSystemdExpandEnvironment : IO Bool := do
  if let some cached ← privdSystemdExpandEnvCache.get then
    return cached
  let res ← (IO.Process.output { cmd := "/usr/bin/systemd-run", args := #["--help"] }).toBaseIO
  let supported := match res with
    | .ok out => ((out.stdout ++ out.stderr).splitOn "--expand-environment").length > 1
    | .error _ => false
  privdSystemdExpandEnvCache.set (some supported)
  return supported

/-- Build the confined `/usr/bin/systemd-run` command vector for `spawn_user_job`.
    When `supportsExpandEnvNo` is `true` (`systemd >= 254`), passes `--expand-environment=no`
    so systemd never expands `${...}`, `$VAR`, or `$$` inside `argv`. On older hosts such as
    Debian 12 (`systemd 252`), omits `--expand-environment=no` and doubles `$` -> `$$` in `argv`
    so transient service `ExecStart` unescaping preserves every literal `$` losslessly. -/
def buildPrivdSystemdRunCmd
    (unit : String) (uid gid : UInt32) (cwd homeDir logPath : String)
    (timeoutSecs : Nat)
    (memMax? memHigh? : Option UInt64)
    (cpuWeight? : Option Nat) (cpuQuota? : Option String)
    (cleanEnv : Array (String × String))
    (argv : Array String)
    (supportsExpandEnvNo : Bool := true) : Array String := Id.run do
  let mut cmd : Array String := #["/usr/bin/systemd-run", "--system"]
  if supportsExpandEnvNo then
    cmd := cmd.push "--expand-environment=no"
  cmd := cmd ++ #[
    "--quiet", "--collect",
    s!"--unit={unit}",
    s!"--uid={uid}", s!"--gid={gid}",
    s!"--working-directory={cwd}",
    "--property=RemainAfterExit=yes",
    "--property=Slice=missions.slice",
    "--property=KillMode=control-group",
    "--property=NoNewPrivileges=yes",
    "--property=SupplementaryGroups=",
    "--property=PrivateTmp=yes",
    "--property=ProtectSystem=strict",
    s!"--property=ReadWritePaths={homeDir}",
    s!"--property=StandardOutput=file:{logPath}",
    s!"--property=StandardError=file:{logPath}",
    s!"--property=RuntimeMaxSec={max 1 timeoutSecs}"
  ]
  if let some m := memMax? then cmd := cmd.push s!"--property=MemoryMax={m}"
  if let some m := memHigh? then cmd := cmd.push s!"--property=MemoryHigh={m}"
  if let some w := cpuWeight? then cmd := cmd.push s!"--property=CPUWeight={w}"
  if let some q := cpuQuota? then cmd := cmd.push s!"--property=CPUQuota={q}"
  for (k, v) in cleanEnv do cmd := cmd.push s!"--setenv={k}={v}"
  cmd := cmd.push "--"
  let safeArgv := if supportsExpandEnvNo then argv else argv.map escapeSystemdExecArgDollar
  cmd := cmd ++ safeArgv
  return cmd

def handleSpawnUserJob (cfd : LeanSys.Posix.Fd) (cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  let peerOk ← resolveAllowedNodePeer peer
  if !peerOk then
    return (← replyError cfd "Unauthorized peer UID for spawn_user_job" 126)
  let uName := ((req.fieldStr? "unix_username").getD "").trimAscii.toString
  let jobId := ((req.fieldStr? "job_id").getD "").trimAscii.toString
  let missionId := ((req.fieldStr? "mission_id").getD "").trimAscii.toString
  let logPath := ((req.fieldStr? "log_path").getD "").trimAscii.toString
  let callerRole := ((req.fieldStr? "caller_role").getD "member").trimAscii.toString
  let nodeAdminOnly := (req.fieldBool? "node_admin_only").getD false
  if !Orb.Kernel.validUnixUsername uName || !isSafeJobUnitIdent jobId || !isSafeMissionDirIdent missionId || logPath.isEmpty then
    return (← replyError cfd "Invalid unix_username, job_id, mission_id, or log_path" 2)
  let some rawArgv := req.fieldArr? "argv"
    | return (← replyError cfd "argv is required" 2)
  let argv := rawArgv.filterMap JVal.asStr?
  if argv.isEmpty then
    return (← replyError cfd "argv must be non-empty" 2)
  let allowNonRoot := (← getEnvNonEmpty "ORB_PRIVD_ALLOW_NONROOT_TEST") == some "1"
  let myEuid ← geteuid
  let isNonRootTest := allowNonRoot && myEuid != 0
  let homeRoot := stripTrailingSlash ((← getEnvNonEmpty "ORB_PRIVD_HOME_ROOT").getD "/home")
  let (uid, gid, groupsDisjoint) ←
    if isNonRootTest then
      pure ((2500 : UInt32), (2500 : UInt32), true)
    else do
      let some (u, g, pwDir, grps) ← lookupUnixUserInfo uName
        | return (← replyError cfd s!"Unix user '{uName}' is not provisioned" 126)
      if pwDir != s!"{homeRoot}/{uName}" then
        return (← replyError cfd s!"Unix user '{uName}' home mismatch" 126)
      let disj := !(grps.any (fun gn => privilegedUnixGroups.contains gn.toLower))
      pure (u, g, disj)
  let homeDir := s!"{homeRoot}/{uName}"
  let missionCwd := s!"{homeDir}/.orb-missions/{missionId}"
  let stRoot ← statPath homeRoot
  let stHome ← statPath homeDir
  let stCwd ← statPath missionCwd
  let homeOk :=
    stRoot.exists_ && stRoot.isDir && !stRoot.isSymlink &&
    stHome.exists_ && stHome.isDir && !stHome.isSymlink &&
    stCwd.exists_ && stCwd.isDir && !stCwd.isSymlink
  let gate := checkUserExecAdmission peerOk true nodeAdminOnly callerRole uName uid gid groupsDisjoint homeOk true
  if (gate &&& 1) != 1 then
    return (← replyError cfd s!"spawn_user_job rejected by orb_privd_user_exec_step (gate={gate})" 126)
  let mut rawEnv : Array (String × String) := #[]
  if let some envObj := (req.field? "env") >>= JVal.asObj? then
    for (ek, ev) in envObj do
      if let some sv := ev.asStr? then
        rawEnv := rawEnv.push (ek, sv)
  let cleanEnv := scrubUserJobEnv rawEnv homeDir
  let cleanJobUnit := "orb-job-" ++ String.ofList (jobId.toList.filter (fun c => c.isAlphanum))
  let stDir ← privdStateDir
  IO.FS.createDirAll (System.FilePath.mk stDir)
  let metaPath := s!"{stDir}/{cleanJobUnit}.json"
  let timeoutSecs := (req.fieldNat? "timeout_secs").getD 14400
  let memMax? := req.fieldUInt64? "mem_max"
  let memHigh? := req.fieldUInt64? "mem_high"
  let cpuWeight? := req.fieldNat? "cpu_weight"
  let cpuQuota? := req.fieldStr? "cpu_quota"
  let supportsExpandEnv ← if isNonRootTest then pure true else detectPrivdSystemdExpandEnvironment
  let systemdCmd := buildPrivdSystemdRunCmd cleanJobUnit uid gid missionCwd homeDir logPath
    timeoutSecs memMax? memHigh? cpuWeight? cpuQuota? cleanEnv argv supportsExpandEnv
  let pySpawn :=
    "import json, os, stat, subprocess, sys\n" ++
    "req = json.loads(sys.stdin.read())\n" ++
    "lp = req['log_path']\n" ++
    "os.makedirs(os.path.dirname(lp), exist_ok=True)\n" ++
    "lfd = os.open(lp, os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o640)\n" ++
    "if req.get('group_gid') is not None and not req['nonroot']:\n" ++
    "  try: os.fchown(lfd, 0, int(req['group_gid']))\n" ++
    "  except OSError: pass\n" ++
    "env_map = dict(req['env'])\n" ++
    "if req['nonroot']:\n" ++
    "  if os.environ.get('PATH'): env_map['PATH'] = env_map.get('PATH', '') + ':' + os.environ['PATH']\n" ++
    "  rc_path = req['meta_path'] + '.rc'\n" ++
    "  runner = 'import os, subprocess, sys\\np = subprocess.run(sys.argv[2:], env=os.environ)\\nopen(sys.argv[1], \"w\").write(str(p.returncode))\\nsys.exit(p.returncode)\\n'\n" ++
    "  proc = subprocess.Popen([sys.executable, '-c', runner, rc_path, *req['argv']], cwd=req['cwd'], env=env_map, stdin=subprocess.DEVNULL, stdout=lfd, stderr=lfd, start_new_session=True)\n" ++
    "  os.close(lfd)\n" ++
    "  meta = {'unix_username': req['unix_username'], 'unit': req['unit'], 'pid': proc.pid, 'rc_path': rc_path, 'mode': 'nonroot'}\n" ++
    "  open(req['meta_path'], 'w').write(json.dumps(meta))\n" ++
    "  print(json.dumps({'ok': True, 'unit': req['unit'], 'pid': proc.pid}))\n" ++
    "else:\n" ++
    "  os.close(lfd)\n" ++
    "  r = subprocess.run(req['systemd_cmd'], capture_output=True, text=True, timeout=20)\n" ++
    "  if r.returncode != 0:\n" ++
    "    print(json.dumps({'ok': False, 'stderr': r.stderr.strip() or r.stdout.strip()}))\n" ++
    "    sys.exit(0)\n" ++
    "  sh = subprocess.run(['/usr/bin/systemctl', 'show', '--property=MainPID', '--value', req['unit']], capture_output=True, text=True)\n" ++
    "  mpid = int((sh.stdout.strip() or '0')) if sh.returncode == 0 and sh.stdout.strip().isdigit() else 0\n" ++
    "  meta = {'unix_username': req['unix_username'], 'unit': req['unit'], 'pid': mpid, 'mode': 'systemd'}\n" ++
    "  open(req['meta_path'], 'w').write(json.dumps(meta))\n" ++
    "  print(json.dumps({'ok': True, 'unit': req['unit'], 'pid': mpid}))\n"
  let envJsonArr := cleanEnv.map fun (k, v) => JVal.arr #[.str k, .str v]
  let spawnInput := renderCompact <| JVal.obj #[
    ("nonroot", .bool isNonRootTest),
    ("unix_username", .str uName),
    ("group_gid", match peer.gid with | some g => .nat g.toNat | none => .null),
    ("cwd", .str missionCwd),
    ("log_path", .str logPath),
    ("unit", .str cleanJobUnit),
    ("meta_path", .str metaPath),
    ("env", .arr envJsonArr),
    ("argv", .arr (argv.map .str)),
    ("systemd_cmd", .arr (systemdCmd.map .str))
  ]
  match ← (IO.Process.output { cmd := "python3", args := #["-c", pySpawn] } (input? := some spawnInput)).toBaseIO with
  | .error e => return (← replyError cfd s!"spawn_user_job failed: {e}" 126)
  | .ok out =>
    if out.exitCode != 0 then
      return (← replyError cfd s!"spawn_user_job helper error: {out.stderr.trimAscii}" 126)
    let .ok jv := Json.parse out.stdout | return (← replyError cfd "Invalid JSON from spawn helper" 126)
    if (jv.fieldBool? "ok") != some true then
      return (← replyError cfd ((jv.fieldStr? "stderr").getD "systemd-run failed") 126)
    let ts ← nowEpoch
    appendAuditLine cfg.auditLog <| JVal.obj #[
      ("ts", .uint64 ts),
      ("action", .str "spawn_user_job"),
      ("unix_username", .str uName),
      ("job_id", .str jobId),
      ("mission_id", .str missionId),
      ("unit", .str cleanJobUnit)
    ]
    replyJson cfd jv

def handleControlUserJob (cfd : LeanSys.Posix.Fd) (_cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  let peerOk ← resolveAllowedNodePeer peer
  if !peerOk then
    return (← replyError cfd "Unauthorized peer UID for control_user_job" 126)
  let op := ((req.fieldStr? "op").getD "status").trimAscii.toString
  let jobId := ((req.fieldStr? "job_id").getD "").trimAscii.toString
  let uName := ((req.fieldStr? "unix_username").getD "").trimAscii.toString
  if !Orb.Kernel.validUnixUsername uName || !isSafeJobUnitIdent jobId then
    return (← replyError cfd "Invalid unix_username or job_id" 2)
  let cleanJobUnit := "orb-job-" ++ String.ofList (jobId.toList.filter (fun c => c.isAlphanum))
  let stDir ← privdStateDir
  let metaPath := s!"{stDir}/{cleanJobUnit}.json"
  let pyCtrl :=
    "import json, os, signal, subprocess, sys\n" ++
    "op, u_name, unit, meta_path = sys.argv[1:5]\n" ++
    "if not os.path.isfile(meta_path):\n" ++
    "  print(json.dumps({'ok': True, 'done': True, 'exit_code': -1, 'state': 'not-found'}))\n" ++
    "  sys.exit(0)\n" ++
    "meta = json.loads(open(meta_path).read())\n" ++
    "if meta.get('unix_username') != u_name:\n" ++
    "  print(json.dumps({'ok': False, 'stderr': 'job belongs to a different unix_username'}))\n" ++
    "  sys.exit(0)\n" ++
    "if meta.get('mode') == 'nonroot':\n" ++
    "  pid = int(meta.get('pid') or 0)\n" ++
    "  rc_path = meta.get('rc_path', '')\n" ++
    "  if op in ('stop', 'kill'):\n" ++
    "    if pid > 1:\n" ++
    "      try: os.killpg(pid, signal.SIGKILL if op == 'kill' else signal.SIGTERM)\n" ++
    "      except OSError: pass\n" ++
    "    try: os.unlink(meta_path)\n" ++
    "    except OSError: pass\n" ++
    "    print(json.dumps({'ok': True, 'done': True, 'exit_code': 137, 'state': 'stopped'}))\n" ++
    "  else:\n" ++
    "    if rc_path and os.path.isfile(rc_path):\n" ++
    "      rc = int((open(rc_path).read().strip() or '0'))\n" ++
    "      try: os.unlink(meta_path); os.unlink(rc_path)\n" ++
    "      except OSError: pass\n" ++
    "      print(json.dumps({'ok': True, 'done': True, 'exit_code': rc, 'state': 'exited'}))\n" ++
    "    else:\n" ++
    "      alive = False\n" ++
    "      if pid > 1:\n" ++
    "        try: os.kill(pid, 0); alive = True\n" ++
    "        except OSError: alive = False\n" ++
    "      print(json.dumps({'ok': True, 'done': not alive, 'exit_code': 0 if alive else -1, 'state': 'running' if alive else 'exited'}))\n" ++
    "else:\n" ++
    "  if op in ('stop', 'kill'):\n" ++
    "    subprocess.run(['/usr/bin/systemctl', 'kill', '--kill-who=all', '--signal=SIGKILL', unit], capture_output=True)\n" ++
    "    subprocess.run(['/usr/bin/systemctl', 'stop', unit], capture_output=True)\n" ++
    "    subprocess.run(['/usr/bin/systemctl', 'reset-failed', unit], capture_output=True)\n" ++
    "    try: os.unlink(meta_path)\n" ++
    "    except OSError: pass\n" ++
    "    print(json.dumps({'ok': True, 'done': True, 'exit_code': 137, 'state': 'stopped'}))\n" ++
    "  else:\n" ++
    "    sh = subprocess.run(['/usr/bin/systemctl', 'show', '--property=ActiveState,SubState,ExecMainStatus,LoadState', unit], capture_output=True, text=True)\n" ++
    "    kv = {}\n" ++
    "    for ln in sh.stdout.splitlines():\n" ++
    "      if '=' in ln:\n" ++
    "        k, v = ln.split('=', 1); kv[k] = v\n" ++
    "    ast = kv.get('ActiveState', 'inactive')\n" ++
    "    sst = kv.get('SubState', '')\n" ++
    "    rc = int(kv.get('ExecMainStatus', '0') or '0')\n" ++
    "    running = ast in ('active', 'activating') and sst == 'running'\n" ++
    "    if not running:\n" ++
    "      subprocess.run(['/usr/bin/systemctl', 'stop', unit], capture_output=True)\n" ++
    "      subprocess.run(['/usr/bin/systemctl', 'reset-failed', unit], capture_output=True)\n" ++
    "      try: os.unlink(meta_path)\n" ++
    "      except OSError: pass\n" ++
    "    print(json.dumps({'ok': True, 'done': not running, 'exit_code': rc, 'state': sst or ast}))\n"
  match ← (IO.Process.output { cmd := "python3", args := #["-c", pyCtrl, op, uName, cleanJobUnit, metaPath] }).toBaseIO with
  | .error e => return (← replyError cfd s!"control_user_job failed: {e}" 126)
  | .ok out =>
    if out.exitCode != 0 then
      return (← replyError cfd s!"control_user_job error: {out.stderr.trimAscii}" 126)
    let .ok jv := Json.parse out.stdout | return (← replyError cfd "Invalid JSON from control_user_job" 126)
    if (jv.fieldBool? "ok") != some true then
      return (← replyError cfd ((jv.fieldStr? "stderr").getD "control_user_job denied") 126)
    replyJson cfd jv

def handleUserFsOp (cfd : LeanSys.Posix.Fd) (_cfg : PrivdConfig) (peer : PeerCred) (req : JVal) : IO Unit := do
  let peerOk ← resolveAllowedNodePeer peer
  if !peerOk then
    return (← replyError cfd "Unauthorized peer UID for user_fs_op" 126)
  let uName := ((req.fieldStr? "unix_username").getD "").trimAscii.toString
  let missionId := ((req.fieldStr? "mission_id").getD "").trimAscii.toString
  let subop := ((req.fieldStr? "subop").getD "file_browser").trimAscii.toString
  if !Orb.Kernel.validUnixUsername uName || !isSafeMissionDirIdent missionId then
    return (← replyError cfd "Invalid unix_username or mission_id" 2)
  let allowNonRoot := (← getEnvNonEmpty "ORB_PRIVD_ALLOW_NONROOT_TEST") == some "1"
  let myEuid ← geteuid
  let isNonRootTest := allowNonRoot && myEuid != 0
  let homeRoot := stripTrailingSlash ((← getEnvNonEmpty "ORB_PRIVD_HOME_ROOT").getD "/home")
  let (uid, gid, groupsDisjoint) ←
    if isNonRootTest then
      pure ((2500 : UInt32), (2500 : UInt32), true)
    else do
      let some (u, g, pwDir, grps) ← lookupUnixUserInfo uName
        | return (← replyError cfd s!"Unix user '{uName}' is not provisioned" 126)
      if pwDir != s!"{homeRoot}/{uName}" then
        return (← replyError cfd s!"Unix user '{uName}' home mismatch" 126)
      let disj := !(grps.any (fun gn => privilegedUnixGroups.contains gn.toLower))
      pure (u, g, disj)
  let homeDir := s!"{homeRoot}/{uName}"
  let missionCwd := s!"{homeDir}/.orb-missions/{missionId}"
  let stRoot ← statPath homeRoot
  let stHome ← statPath homeDir
  let stCwd ← statPath missionCwd
  let homeOk :=
    stRoot.exists_ && stRoot.isDir && !stRoot.isSymlink &&
    stHome.exists_ && stHome.isDir && !stHome.isSymlink &&
    stCwd.exists_ && stCwd.isDir && !stCwd.isSymlink
  let gate := checkUserExecAdmission peerOk true false "member" uName uid gid groupsDisjoint homeOk true
  if (gate &&& 1) != 1 then
    return (← replyError cfd s!"user_fs_op rejected by orb_privd_user_exec_step (gate={gate})" 126)
  let pyFs :=
    "import base64, json, os, stat, sys\n" ++
    "req = json.loads(sys.stdin.read())\n" ++
    "if not req['nonroot']:\n" ++
    "  os.setgroups([int(req['gid'])])\n" ++
    "  os.setgid(int(req['gid']))\n" ++
    "  os.setuid(int(req['uid']))\n" ++
    "os.umask(0o077)\n" ++
    "root = req['mission_cwd']\n" ++
    "DENIED = {'.env', '.ssh', '.aws', '.gnupg', '.git', 'credentials.json', '.credentials.json', 'auth.json', 'id_rsa', 'id_ed25519', '.git-credentials'}\n" ++
    "def bad_seg(s):\n" ++
    "  low = s.lower()\n" ++
    "  return low in DENIED or low.startswith('.env.') or low.endswith('.pem') or low.endswith('.key')\n" ++
    "def resolve_rel(raw, allow_missing_leaf=False):\n" ++
    "  r = raw.strip()\n" ++
    "  if r.startswith('/'):\n" ++
    "    rc = r.rstrip('/')\n" ++
    "    rt = root.rstrip('/')\n" ++
    "    if rc == rt: r = ''\n" ++
    "    elif rc.startswith(rt + '/'): r = rc[len(rt)+1:]\n" ++
    "    else: raise ValueError('File is outside this source')\n" ++
    "  if '\\\\' in r: raise ValueError('File is not available in this source')\n" ++
    "  segs = [s for s in r.split('/') if s and s != '.']\n" ++
    "  if any(s == '..' or bad_seg(s) for s in segs): raise ValueError('File is not available in this source')\n" ++
    "  cur = root\n" ++
    "  for idx, s in enumerate(segs):\n" ++
    "    cur = os.path.join(cur, s)\n" ++
    "    if not os.path.lexists(cur):\n" ++
    "      if allow_missing_leaf and idx == len(segs) - 1: return cur, segs\n" ++
    "      raise ValueError('File is unavailable')\n" ++
    "    st = os.lstat(cur)\n" ++
    "    if stat.S_ISLNK(st.st_mode): raise ValueError('Symbolic links are not exposed')\n" ++
    "  return cur, segs\n" ++
    "def entry_obj(full, segs):\n" ++
    "  if not segs or any(bad_seg(s) for s in segs): return None\n" ++
    "  st = os.lstat(full)\n" ++
    "  if stat.S_ISLNK(st.st_mode) or (not stat.S_ISDIR(st.st_mode) and not stat.S_ISREG(st.st_mode)): return None\n" ++
    "  return {'name': segs[-1], 'path': '/'.join(segs), 'kind': 'dir' if stat.S_ISDIR(st.st_mode) else 'file', 'size': 0 if stat.S_ISDIR(st.st_mode) else st.st_size, 'modified': int(st.st_mtime)}\n" ++
    "try:\n" ++
    "  subop = req['subop']\n" ++
    "  if subop == 'file_browser':\n" ++
    "    fb = req.get('req_json') or {}\n" ++
    "    act = fb.get('action', '')\n" ++
    "    if act == 'roots': res = {'path': root}\n" ++
    "    elif act == 'list':\n" ++
    "      d, segs = resolve_rel(fb.get('path', ''))\n" ++
    "      items = []\n" ++
    "      for fn in sorted(os.listdir(d)):\n" ++
    "        eo = entry_obj(os.path.join(d, fn), segs + [fn])\n" ++
    "        if eo: items.append(eo)\n" ++
    "      items.sort(key=lambda x: (0 if x['kind'] == 'dir' else 1, x['name'].lower()))\n" ++
    "      res = {'entries': items[:1000], 'truncated': len(items) > 1000}\n" ++
    "    elif act in ('read', 'download'):\n" ++
    "      fp, _ = resolve_rel(fb.get('path', ''))\n" ++
    "      off = max(0, int(fb.get('offset') or 0))\n" ++
    "      fd = os.open(fp, os.O_RDONLY | os.O_NOFOLLOW)\n" ++
    "      st = os.fstat(fd)\n" ++
    "      if not stat.S_ISREG(st.st_mode): os.close(fd); raise ValueError('Not a regular file')\n" ++
    "      os.lseek(fd, min(off, st.st_size), os.SEEK_SET)\n" ++
    "      chunk = os.read(fd, 1048576); os.close(fd)\n" ++
    "      nxt = min(off, st.st_size) + len(chunk)\n" ++
    "      if act == 'download': res = {'bytes': list(chunk), 'next': nxt, 'size': st.st_size}\n" ++
    "      else:\n" ++
    "        has_nul = b'\\x00' in chunk\n" ++
    "        res = {'content': None if has_nul else chunk.decode('utf-8', errors='replace'), 'binary': has_nul, 'size': st.st_size, 'truncated': nxt < st.st_size, 'modified': int(st.st_mtime)}\n" ++
    "    elif act in ('search', 'resolve'):\n" ++
    "      q = (fb.get('query') or '').lower()\n" ++
    "      all_files = []\n" ++
    "      stack = [(root, [])]\n" ++
    "      while stack and len(all_files) < 2000:\n" ++
    "        cd, cp = stack.pop()\n" ++
    "        for fn in os.listdir(cd):\n" ++
    "          eo = entry_obj(os.path.join(cd, fn), cp + [fn])\n" ++
    "          if eo:\n" ++
    "            if eo['kind'] == 'dir' and fn not in {'node_modules', 'target', '.lake', '.cache'}: stack.append((os.path.join(cd, fn), cp + [fn]))\n" ++
    "            elif eo['kind'] == 'file': all_files.append(eo)\n" ++
    "      if act == 'search':\n" ++
    "        m = [e for e in all_files if not q or q in e['path'].lower()]\n" ++
    "        res = {'entries': m[:200], 'truncated': len(m) > 200}\n" ++
    "      else:\n" ++
    "        out_r = []\n" ++
    "        for rp in (fb.get('paths') or [])[:64]:\n" ++
    "          ms = [e for e in all_files if e['path'] == rp or e['path'].endswith('/' + rp)]\n" ++
    "          out_r.append({'reference': rp, 'matches': ms})\n" ++
    "        res = {'results': out_r}\n" ++
    "    else: raise ValueError('Unknown file operation')\n" ++
    "  elif subop == 'mkdir':\n" ++
    "    rel = (req.get('rel_path') or '').strip('/')\n" ++
    "    segs = [s for s in rel.split('/') if s and s != '.']\n" ++
    "    if any(s == '..' or bad_seg(s) for s in segs): raise ValueError('Invalid path')\n" ++
    "    cur = root\n" ++
    "    for s in segs:\n" ++
    "      cur = os.path.join(cur, s)\n" ++
    "      if not os.path.lexists(cur): os.mkdir(cur, 0o700)\n" ++
    "      if stat.S_ISLNK(os.lstat(cur).st_mode): raise ValueError('Symlink rejected')\n" ++
    "    res = {'ok': True, 'path': cur}\n" ++
    "  elif subop == 'write':\n" ++
    "    fp, _ = resolve_rel(req.get('rel_path', ''), allow_missing_leaf=True)\n" ++
    "    raw = base64.b64decode(req.get('content_b64', ''))\n" ++
    "    fd = os.open(fp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW, 0o600)\n" ++
    "    os.write(fd, raw); os.close(fd)\n" ++
    "    res = {'ok': True, 'size': len(raw)}\n" ++
    "  elif subop == 'collect_artifacts':\n" ++
    "    import hashlib\n" ++
    "    arts = []\n" ++
    "    for rel in (req.get('paths') or []):\n" ++
    "      try:\n" ++
    "        fp, segs = resolve_rel(rel)\n" ++
    "        fd = os.open(fp, os.O_RDONLY | os.O_NOFOLLOW)\n" ++
    "        st = os.fstat(fd)\n" ++
    "        if stat.S_ISREG(st.st_mode):\n" ++
    "          h = hashlib.sha256()\n" ++
    "          while True:\n" ++
    "            b = os.read(fd, 65536)\n" ++
    "            if not b: break\n" ++
    "            h.update(b)\n" ++
    "          arts.append({'path': '/'.join(segs), 'sha256': h.hexdigest(), 'size_bytes': st.st_size})\n" ++
    "        os.close(fd)\n" ++
    "      except Exception:\n" ++
    "        pass\n" ++
    "    res = {'artifacts': arts}\n" ++
    "  else: raise ValueError(f'Unknown user_fs_op subop: {subop}')\n" ++
    "  print(json.dumps({'ok': True, 'result': res}))\n" ++
    "except Exception as exc:\n" ++
    "  print(json.dumps({'ok': False, 'stderr': str(exc)}))\n"
  let fsInput := renderCompact <| JVal.obj #[
    ("nonroot", .bool isNonRootTest),
    ("uid", .nat uid.toNat),
    ("gid", .nat gid.toNat),
    ("mission_cwd", .str missionCwd),
    ("subop", .str subop),
    ("rel_path", match req.fieldStr? "rel_path" with | some s => .str s | none => .null),
    ("content_b64", match req.fieldStr? "content_b64" with | some s => .str s | none => .null),
    ("paths", req.fieldOrNull "paths"),
    ("req_json", req.fieldOrNull "req_json")
  ]
  match ← (IO.Process.output { cmd := "python3", args := #["-c", pyFs] } (input? := some fsInput)).toBaseIO with
  | .error e => return (← replyError cfd s!"user_fs_op failed: {e}" 126)
  | .ok out =>
    if out.exitCode != 0 then
      return (← replyError cfd s!"user_fs_op helper error: {out.stderr.trimAscii}" 126)
    let .ok jv := Json.parse out.stdout | return (← replyError cfd "Invalid JSON from user_fs_op" 126)
    if (jv.fieldBool? "ok") != some true then
      return (← replyError cfd ((jv.fieldStr? "stderr").getD "user_fs_op failed") 2)
    replyJson cfd jv

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
      else if action == "ensure_mission_user" then
        handleEnsureMissionUser cfd cfg peer req
      else if action == "spawn_user_job" then
        handleSpawnUserJob cfd cfg peer req
      else if action == "control_user_job" then
        handleControlUserJob cfd cfg peer req
      else if action == "user_fs_op" then
        handleUserFsOp cfd cfg peer req
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
