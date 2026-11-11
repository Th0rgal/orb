/-
  OrbCore.SecretAndApproval: Bitwarden (`bws`) Secret Broker, Hardware Approval Devices & Queue,
  Cross-Mission Read Access Grants, Privilege Broker Routes, and Cross-Project Move Secret Preflight
  (`0 import Lean`, `0 sorryAx`). Never logs or echoes plaintext secret values.
-/
import LeanSys
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Store
import OrbCore.R7Core
import OrbCore.LegacyHydrate

namespace OrbCore.SecretAndApproval

open LeanSys.Auth
open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.R7Core
open OrbCore.LegacyHydrate

/-! ## Private JSON File Helpers under `.sandboxed-sh/` -/

private def readDataJsonObj (dataRoot fileName : String) : IO JVal := do
  let p := System.FilePath.mk s!"{dataRoot}/{fileName}"
  if !(← p.pathExists) then return .obj #[]
  match ← (try some <$> IO.FS.readFile p catch _ => pure none) with
  | none => return .obj #[]
  | some raw =>
    match OrbBin.Json.parse raw with
    | .ok v@(.obj _) => return v
    | .ok (.arr xs) => return .obj #[("items", .arr xs)]
    | _ => return .obj #[]

private def writeDataJsonObj (dataRoot fileName : String) (v : JVal) : IO (Except String Unit) :=
  writeAtomicPrivate0600 (System.FilePath.mk s!"{dataRoot}/{fileName}") ((renderPretty v) ++ "\n").toUTF8

private def grantIsActive (g : JVal) (nowEpochSec : UInt64) (nowIso : String) : Bool :=
  let rev := (g.fieldStr? "revoked_at").getD ""
  if !rev.isEmpty then false
  else
    match g.fieldUInt64? "expires_at_epoch" with
    | some exp => nowEpochSec < exp
    | none =>
      let expIso := (g.fieldStr? "expires_at").getD ""
      expIso.isEmpty || decide (nowIso < expIso)

private def grantMatchesMissions (v : JVal) (missionIds : Array String) : Bool :=
  let mid := (v.fieldStr? "mission_id").getD ""
  let rmid := (v.fieldStr? "root_mission_id").getD ""
  (!mid.isEmpty && missionIds.contains mid) || (!rmid.isEmpty && missionIds.contains rmid)

/-! ## `#1545` Cross-Project Mission Move Secret-Approval Preflight & Transfer -/

/-- Inspect `.sandboxed-sh/secret_broker.json` before moving `movingMissionIds` across projects.
    Returns `some bodyJson` (`HTTP 409`, `code = "approval_transfer_confirmation_required"`) when
    active grants or pending secret requests would cross project boundaries under `policy == "check"`. -/
def inspectCrossProjectSecretTransfer
    (dataRoot : String)
    (movingMissionIds : Array String)
    (targetProject : String)
    (nowEpochSec : UInt64) : IO (Option String) := do
  if movingMissionIds.isEmpty then return none
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let broker ← readDataJsonObj dataRoot "secret_broker.json"
  let grants := (broker.fieldArr? "grants").getD #[]
  let requests := (broker.fieldArr? "requests").getD #[]
  let activeGrants := grants.filter (fun g => grantMatchesMissions g movingMissionIds && grantIsActive g nowEpochSec nowIso)
  let pendingReqs := requests.filter (fun r =>
    grantMatchesMissions r movingMissionIds && ((r.fieldStr? "status").getD "") == "pending")
  if activeGrants.isEmpty && pendingReqs.isEmpty then
    return none
  let targetLabel := let t := targetProject.trimAscii.toString; if t.isEmpty then "default" else t
  let redactReq (r : JVal) : JVal :=
    (r.removeField "encrypted_value").removeField "value"
  let safePending := pendingReqs.map redactReq
  return some (renderCompact (.obj #[
    ("code", .str "approval_transfer_confirmation_required"),
    ("error", .str "Moving across projects affects active secret approvals."),
    ("target_project", .str targetLabel),
    ("grants", .arr activeGrants),
    ("active_grants", .arr activeGrants),
    ("pending_requests", .arr safePending)
  ]))

/-- Apply `approval_policy` (`"revoke"` or `"keep"`) to `.sandboxed-sh/secret_broker.json` on cross-project move. -/
def applyCrossProjectSecretPolicy
    (dataRoot : String)
    (movingMissionIds : Array String)
    (targetProject policy nowIso : String)
    (nowEpochSec : UInt64) : IO Unit := do
  if movingMissionIds.isEmpty then return ()
  let broker ← readDataJsonObj dataRoot "secret_broker.json"
  let grants := (broker.fieldArr? "grants").getD #[]
  let requests := (broker.fieldArr? "requests").getD #[]
  if grants.isEmpty && requests.isEmpty then return ()
  let nextProjVal : JVal := if targetProject.trimAscii.isEmpty then .null else .str targetProject.trimAscii.toString
  let (nextGrants, nextReqs) :=
    if policy == "revoke" then
      let gs := grants.map fun g =>
        if grantMatchesMissions g movingMissionIds && grantIsActive g nowEpochSec nowIso then
          g.setField "revoked_at" (.str nowIso)
        else g
      let rs := requests.map fun r =>
        if grantMatchesMissions r movingMissionIds && ((r.fieldStr? "status").getD "") == "pending" then
          (r.setField "status" (.str "cancelled")).setField "decided_at" (.str nowIso)
        else r
      (gs, rs)
    else if policy == "keep" then
      let gs := grants.map fun g =>
        if grantMatchesMissions g movingMissionIds && grantIsActive g nowEpochSec nowIso then
          g.setField "project" nextProjVal
        else g
      let rs := requests.map fun r =>
        if grantMatchesMissions r movingMissionIds && ((r.fieldStr? "status").getD "") == "pending" then
          r.setField "project" nextProjVal
        else r
      (gs, rs)
    else
      (grants, requests)
  let updated := (broker.setField "grants" (.arr nextGrants)).setField "requests" (.arr nextReqs)
  discard <| writeDataJsonObj dataRoot "secret_broker.json" updated

/-! ## Bitwarden Secrets Manager (`bws`) Wrapper -/

private def resolveBwsToken? (workingDir dataRoot : String) : IO (Option String) := do
  if let some envTok ← firstEnvNonEmpty ["BWS_ACCESS_TOKEN", "BITWARDEN_ACCESS_TOKEN"] then
    return some envTok.trimAscii.toString
  let key32? ← loadPrivateKeyBytes? workingDir dataRoot
  let settings ← readSettingsJson dataRoot
  let bwObj := (settings.field? "bitwarden").getD (.obj #[])
  if let some rawTok := (bwObj.fieldStr? "access_token").orElse (fun _ => settings.fieldStr? "bws_access_token") then
    if let .ok dec ← decryptEnvValue key32? rawTok then
      let clean := dec.trimAscii.toString
      if !clean.isEmpty then return some clean
  let bwFile ← readDataJsonObj dataRoot "bitwarden.json"
  if let some rawTok := bwFile.fieldStr? "access_token" then
    if let .ok dec ← decryptEnvValue key32? rawTok then
      let clean := dec.trimAscii.toString
      if !clean.isEmpty then return some clean
  return none

private def runBwsJson (bwsToken : String) (args : Array String) : IO (Except String JVal) := do
  let envVars : Array (String × Option String) := #[("BWS_ACCESS_TOKEN", some bwsToken)]
  let out ← (try
    some <$> IO.Process.output { cmd := "bws", args := args ++ #["--output", "json"], env := envVars }
  catch _ => pure none)
  let some procOut := out
    | return .error "bws CLI is not installed or unavailable"
  if procOut.exitCode != 0 then
    return .error "bws command failed"
  match OrbBin.Json.parse procOut.stdout with
  | .ok jv => return .ok jv
  | .error _ => return .error "bws returned invalid JSON"

def listBitwardenProjectsAndSecrets (workingDir dataRoot : String) : IO (Except String (Array JVal × Array JVal)) := do
  let some tok ← resolveBwsToken? workingDir dataRoot
    | return .error "Bitwarden Secrets Manager is not configured"
  let projsJv ← match ← runBwsJson tok #["project", "list"] with
    | .ok (.arr ps) => pure ps
    | .ok _ => pure #[]
    | .error e => return .error e
  let secsJv ← match ← runBwsJson tok #["secret", "list"] with
    | .ok (.arr ss) => pure ss
    | .ok _ => pure #[]
    | .error e => return .error e
  -- Redact `value` from metadata listing!
  let redactedSecs := secsJv.map (fun s => s.removeField "value")
  return .ok (projsJv, redactedSecs)

/-! ## Cross-Mission Read Access Grants (`.sandboxed-sh/mission_access.json`) -/

def hasApprovedMissionReadAccess (dataRoot callerMissionId targetMissionId : String) (nowEpochSec : UInt64) : IO Bool := do
  if callerMissionId.isEmpty || targetMissionId.isEmpty then return false
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "mission_access.json"
  let grants := (doc.fieldArr? "grants").getD #[]
  return grants.any fun g =>
    ((g.fieldStr? "requester_mission_id").getD "" == callerMissionId ||
     (g.fieldStr? "mission_id").getD "" == callerMissionId) &&
    (g.fieldStr? "target_mission_id").getD "" == targetMissionId &&
    grantIsActive g nowEpochSec nowIso

def mcpRequestMissionAccess
    (dataRoot callerMissionId targetMissionId reason : String)
    (ttlHours : Nat) (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "mission_access.json"
  let grants := (doc.fieldArr? "grants").getD #[]
  if grants.any (fun g =>
      (g.fieldStr? "requester_mission_id").getD "" == callerMissionId &&
      (g.fieldStr? "target_mission_id").getD "" == targetMissionId &&
      grantIsActive g nowEpochSec nowIso) then
    return .obj #[
      ("status", .str "approved"),
      ("target_mission_id", .str targetMissionId)
    ]
  let reqs := (doc.fieldArr? "requests").getD #[]
  if let some existing := reqs.find? (fun r =>
      (r.fieldStr? "requester_mission_id").getD "" == callerMissionId &&
      (r.fieldStr? "target_mission_id").getD "" == targetMissionId &&
      (r.fieldStr? "status").getD "" == "pending") then
    return .obj #[
      ("status", .str "pending"),
      ("request_id", .str ((existing.fieldStr? "id").getD "")),
      ("target_mission_id", .str targetMissionId)
    ]
  let reqId ← newUuidV4
  let clampedHours := Nat.min 168 (Nat.max 1 ttlHours)
  let newReq := JVal.obj #[
    ("id", .str reqId),
    ("requester_mission_id", .str callerMissionId),
    ("target_mission_id", .str targetMissionId),
    ("scope", .str "read"),
    ("reason", .str reason),
    ("ttl_hours", JVal.nat clampedHours),
    ("status", .str "pending"),
    ("created_at", .str nowIso)
  ]
  discard <| writeDataJsonObj dataRoot "mission_access.json" (doc.setField "requests" (.arr (reqs.push newReq)))
  return .obj #[
    ("status", .str "pending"),
    ("request_id", .str reqId),
    ("target_mission_id", .str targetMissionId)
  ]

def mcpListMissionAccess (dataRoot callerMissionId : String) (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "mission_access.json"
  let reqs := ((doc.fieldArr? "requests").getD #[]).filter (fun r =>
    callerMissionId.isEmpty || (r.fieldStr? "requester_mission_id").getD "" == callerMissionId)
  let grants := ((doc.fieldArr? "grants").getD #[]).filter (fun g =>
    (callerMissionId.isEmpty || (g.fieldStr? "requester_mission_id").getD "" == callerMissionId) &&
    grantIsActive g nowEpochSec nowIso)
  return .obj #[("requests", .arr reqs), ("grants", .arr grants)]

/-! ## MCP Secret Broker Tools (`secret_list`, `secret_get`, `secret_request`, `secret_put`, `secret_delete`, `secret_move`) -/

private def defaultBwProjectsForSlug (broker : JVal) (projectSlug : String) : Array String :=
  if projectSlug.isEmpty then #[]
  else
    match (broker.field? "default_access").bind (·.field? projectSlug) with
    | some (.arr xs) => xs.filterMap JVal.asStr?
    | some (.obj kvs) =>
      match (JVal.obj kvs).fieldArr? "bitwarden_projects" with
      | some xs => xs.filterMap JVal.asStr?
      | none => #[]
    | _ => #[]

private def missionHasBwProjectAccess
    (broker : JVal) (missionId projectSlug bwProjName bwProjId : String)
    (nowEpochSec : UInt64) (nowIso : String) : Bool :=
  let defaults := defaultBwProjectsForSlug broker projectSlug
  if defaults.any (fun d => d == "all" || d == bwProjName || (!bwProjId.isEmpty && d == bwProjId)) then
    true
  else
    let grants := (broker.fieldArr? "grants").getD #[]
    grants.any fun g =>
      (g.fieldStr? "mission_id").getD "" == missionId &&
      grantIsActive g nowEpochSec nowIso &&
      let gp := (g.fieldStr? "bitwarden_project").getD ""
      (gp == "all" || gp == bwProjName || (!bwProjId.isEmpty && gp == bwProjId))

def mcpSecretList
    (workingDir dataRoot missionId projectSlug : String) (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let broker ← readDataJsonObj dataRoot "secret_broker.json"
  match ← listBitwardenProjectsAndSecrets workingDir dataRoot with
  | .error e =>
    return .obj #[("configured", .bool false), ("error", .str e), ("projects", .arr #[]), ("secrets", .arr #[])]
  | .ok (projs, secs) =>
    let projMap : Array (String × String) := projs.map fun p =>
      ((p.fieldStr? "id").getD "", (p.fieldStr? "name").getD "")
    let items := secs.map fun s =>
      let key := (s.fieldStr? "key").getD ""
      let pid := (s.fieldStr? "projectId").getD ""
      let pname := ((projMap.find? (fun (k, _) => k == pid)).map Prod.snd).getD "unassigned"
      let readable := missionHasBwProjectAccess broker missionId projectSlug pname pid nowEpochSec nowIso
      JVal.obj #[
        ("name", .str key),
        ("bitwarden_project", .str pname),
        ("accessible_now", .bool readable)
      ]
    return .obj #[("configured", .bool true), ("secrets", .arr items)]

def mcpSecretGet
    (workingDir dataRoot missionId missionWorkDir projectSlug secretName reason : String)
    (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let broker ← readDataJsonObj dataRoot "secret_broker.json"
  let some bwsTok ← resolveBwsToken? workingDir dataRoot
    | return .obj #[("status", .str "error"), ("error", .str "Bitwarden Secrets Manager is not configured")]
  let (projs, secs) ← match ← listBitwardenProjectsAndSecrets workingDir dataRoot with
    | .ok pair => pure pair
    | .error e => return .obj #[("status", .str "error"), ("error", .str e)]
  let some matchedSec := secs.find? (fun s => (s.fieldStr? "key").getD "" == secretName)
    | return .obj #[("status", .str "not_found"), ("name", .str secretName)]
  let secId := (matchedSec.fieldStr? "id").getD ""
  let pid := (matchedSec.fieldStr? "projectId").getD ""
  let pname := ((projs.find? (fun p => (p.fieldStr? "id").getD "" == pid)).bind (·.fieldStr? "name")).getD "unassigned"
  let allowed := missionHasBwProjectAccess broker missionId projectSlug pname pid nowEpochSec nowIso ||
    ((broker.fieldArr? "grants").getD #[]).any (fun g =>
      (g.fieldStr? "mission_id").getD "" == missionId &&
      grantIsActive g nowEpochSec nowIso &&
      (g.fieldStr? "secret_name").getD "" == secretName)
  if !allowed then
    let reqs := (broker.fieldArr? "requests").getD #[]
    let reqId ← newUuidV4
    let newReq := JVal.obj #[
      ("id", .str reqId),
      ("kind", .str "secret_get"),
      ("mission_id", .str missionId),
      ("project", if projectSlug.isEmpty then .null else .str projectSlug),
      ("secret_name", .str secretName),
      ("bitwarden_project", .str pname),
      ("reason", .str reason),
      ("status", .str "pending"),
      ("created_at", .str nowIso)
    ]
    discard <| writeDataJsonObj dataRoot "secret_broker.json" (broker.setField "requests" (.arr (reqs.push newReq)))
    return .obj #[("status", .str "pending"), ("request_id", .str reqId), ("name", .str secretName), ("bitwarden_project", .str pname)]
  match ← runBwsJson bwsTok #["secret", "get", secId] with
  | .error e => return .obj #[("status", .str "error"), ("error", .str e)]
  | .ok fullJv =>
    let val := (fullJv.fieldStr? "value").getD ""
    let baseDir := if missionWorkDir.trimAscii.isEmpty then s!"{dataRoot}/mission-secrets/{missionId}" else s!"{missionWorkDir}/.paloma/secrets"
    discard <| ensurePrivateDir0700 (System.FilePath.mk baseDir)
    let safeFile := String.ofList (secretName.toList.filter (fun c => c.isAlphanum || c == '_' || c == '-'))
    let fileLeaf := if safeFile.isEmpty then "secret" else safeFile
    let secretFile := System.FilePath.mk s!"{baseDir}/{fileLeaf}"
    if let .error e ← writeAtomicPrivate0600 secretFile val.toUTF8 then
      return .obj #[("status", .str "error"), ("error", .str e)]
    let exportLine :=
      if isSafeEnvIdent secretName then
        s!"export {secretName}=\"$(cat {shellSingleQuote secretFile.toString})\""
      else
        s!"cat {shellSingleQuote secretFile.toString}"
    return .obj #[
      ("status", .str "ready"),
      ("name", .str secretName),
      ("path", .str secretFile.toString),
      ("export", .str exportLine)
    ]

def mcpSecretQueueAction
    (workingDir dataRoot kind missionId projectSlug bwProject secretName? plainValue? note? reason : String)
    (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let broker ← readDataJsonObj dataRoot "secret_broker.json"
  let reqs := (broker.fieldArr? "requests").getD #[]
  let reqId ← newUuidV4
  let encValField ←
    if plainValue?.isEmpty then pure JVal.null
    else
      match ← loadOrCreatePrivateKeyBytes workingDir dataRoot with
      | .error _ => pure JVal.null
      | .ok k32 =>
        match ← encryptEnvValue k32 plainValue? with
        | .ok enc => pure (.str enc)
        | .error _ => pure JVal.null
  let newReq := JVal.obj #[
    ("id", .str reqId),
    ("kind", .str kind),
    ("mission_id", .str missionId),
    ("project", if projectSlug.isEmpty then .null else .str projectSlug),
    ("bitwarden_project", .str bwProject),
    ("secret_name", if secretName?.isEmpty then .null else .str secretName?),
    ("encrypted_value", encValField),
    ("note", if note?.isEmpty then .null else .str note?),
    ("reason", .str reason),
    ("status", .str "pending"),
    ("created_at", .str nowIso)
  ]
  discard <| writeDataJsonObj dataRoot "secret_broker.json" (broker.setField "requests" (.arr (reqs.push newReq)))
  return .obj #[("status", .str "pending"), ("request_id", .str reqId), ("kind", .str kind)]

/-! ## MCP Privilege Broker Helpers (`request_privileged_access`, `list_privileged_access`, `revoke_privileged_access`) -/

def mcpRequestPrivilegedAccess
    (dataRoot missionId scope targetHost reason : String)
    (allowedUnits : Array String) (ttlMinutes : Nat) (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "privilege_access.json"
  let reqs := (doc.fieldArr? "requests").getD #[]
  let reqId ← newUuidV4
  let clampedTtl := Nat.min 240 (Nat.max 1 ttlMinutes)
  let newReq := JVal.obj #[
    ("id", .str reqId),
    ("mission_id", .str missionId),
    ("scope", .str scope),
    ("target_host", .str (if targetHost.isEmpty then "self" else targetHost)),
    ("allowed_units", .arr (allowedUnits.map JVal.str)),
    ("ttl_minutes", JVal.nat clampedTtl),
    ("reason", .str reason),
    ("status", .str "pending"),
    ("created_at", .str nowIso)
  ]
  discard <| writeDataJsonObj dataRoot "privilege_access.json" (doc.setField "requests" (.arr (reqs.push newReq)))
  return .obj #[("status", .str "pending"), ("request_id", .str reqId), ("scope", .str scope)]

def mcpListPrivilegedAccess (st : CoreStore) (dataRoot missionId : String) (nowEpochSec : UInt64) : IO JVal := do
  let doc ← readDataJsonObj dataRoot "privilege_access.json"
  let reqs := ((doc.fieldArr? "requests").getD #[]).filter (fun r =>
    missionId.isEmpty || (r.fieldStr? "mission_id").getD "" == missionId)
  let sql :=
    if missionId.isEmpty then
      "SELECT grant_id, mission_id, target_host, scope, allowed_units_json, revoked, expires_at_epoch FROM privilege_leases ORDER BY expires_at_epoch DESC LIMIT 100;"
    else
      "SELECT grant_id, mission_id, target_host, scope, allowed_units_json, revoked, expires_at_epoch FROM privilege_leases WHERE mission_id=?1 ORDER BY expires_at_epoch DESC LIMIT 100;"
  let args := if missionId.isEmpty then #[] else #[missionId]
  let mut grants : Array JVal := #[]
  if let .ok rs ← execParamQuery st.missionsDb sql args then
    for i in [1:rs.size] do
      let r := rs[i]!
      let gid := (r[0]?).getD ""
      let mid := (r[1]?).getD ""
      let th := (r[2]?).getD "self"
      let sc := (r[3]?).getD ""
      let units := (OrbBin.Json.parse ((r[4]?).getD "[]")).toOption.getD (.arr #[])
      let rev := ((r[5]?).getD "0") != "0"
      let exp := (((r[6]?).bind String.toNat?).getD 0).toUInt64
      grants := grants.push (.obj #[
        ("id", .str gid),
        ("grant_id", .str gid),
        ("mission_id", .str mid),
        ("target_host", .str th),
        ("scope", .str sc),
        ("allowed_units", units),
        ("revoked", .bool rev),
        ("active", .bool (!rev && nowEpochSec < exp)),
        ("expires_at_epoch", JVal.uint64 exp)
      ])
  return .obj #[("requests", .arr reqs), ("grants", .arr grants)]

def mcpRevokePrivilegedAccess (st : CoreStore) (grantId missionId : String) : IO Bool := do
  let res ←
    if missionId.isEmpty then
      execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1 WHERE grant_id=?1;" #[grantId]
    else
      execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1 WHERE grant_id=?1 AND mission_id=?2;" #[grantId, missionId]
  return res.isOk

/-! ## HTTP Route Dispatcher (`/api/approvals*`, `/api/secrets*`, `/api/bitwarden*`, `/api/mission-access*`, `/api/privilege-access*`) -/

set_option maxHeartbeats 800000 in
def dispatchSecretAndApprovalRoutes?
    (st : CoreStore)
    (workingDir dataRoot : String)
    (bunkerRef? : Option (IO.Ref UInt8))
    (isAdmin : Bool)
    (method _rawTarget cleanPath : String)
    (bodyBytes : ByteArray)
    (nowEpochSec : UInt64) : IO (Option (Nat × String × String)) := do
  -- Returns `Option (statusCode × contentType × bodyString)`
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let okJson (code : Nat) (s : String) : Option (Nat × String × String) :=
    some (code, "application/json", s)

  -- 1. `/api/approvals/*`
  if cleanPath == "/api/approvals" || cleanPath.startsWith "/api/approvals/" then
    if !isAdmin then
      return okJson 403 "{\"error\":\"admin_required\"}"
    let devDoc ← readDataJsonObj dataRoot "approval_devices.json"
    let devices := (devDoc.fieldArr? "devices").getD #[]
    let mode := (devDoc.fieldStr? "mode").getD "biometric"
    if method == "GET" && cleanPath == "/api/approvals/devices" then
      return okJson 200 (renderCompact (.obj #[("devices", .arr devices), ("mode", .str mode)]))
    if method == "POST" && cleanPath == "/api/approvals/devices" then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return okJson 400 "{\"error\":\"invalid_json\"}"
      let did ← match jv.fieldStr? "id" with | some s => pure s | none => newUuidV4
      let name := (jv.fieldStr? "name").getD "Approval Device"
      let pubKey := (jv.fieldStr? "public_key").getD ""
      let entry := JVal.obj #[
        ("id", .str did), ("name", .str name), ("public_key", .str pubKey), ("created_at", .str nowIso)
      ]
      let nextDevs := (devices.filter (fun d => (d.fieldStr? "id").getD "" != did)).push entry
      discard <| writeDataJsonObj dataRoot "approval_devices.json" (devDoc.setField "devices" (.arr nextDevs))
      return okJson 201 (renderCompact entry)
    if method == "DELETE" && cleanPath.startsWith "/api/approvals/devices/" then
      let did := (cleanPath.drop 23).toString
      let nextDevs := devices.filter (fun d => (d.fieldStr? "id").getD "" != did)
      discard <| writeDataJsonObj dataRoot "approval_devices.json" (devDoc.setField "devices" (.arr nextDevs))
      return okJson 200 "{\"ok\":true}"
    if method == "POST" && cleanPath == "/api/approvals/challenge" then
      let nonce ← newUuidV4
      return okJson 200 (renderCompact (.obj #[
        ("challenge", .str nonce),
        ("expires_at", JVal.uint64 (nowEpochSec + 120))
      ]))
    if method == "GET" && cleanPath == "/api/approvals/mode" then
      return okJson 200 (renderCompact (.obj #[("mode", .str mode)]))
    if method == "PUT" && cleanPath == "/api/approvals/mode" then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let nextMode := (jv.fieldStr? "mode").getD mode
      discard <| writeDataJsonObj dataRoot "approval_devices.json" (devDoc.setField "mode" (.str nextMode))
      return okJson 200 (renderCompact (.obj #[("mode", .str nextMode)]))
    if method == "GET" && cleanPath == "/api/approvals/queue" then
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let mAcc ← readDataJsonObj dataRoot "mission_access.json"
      let pAcc ← readDataJsonObj dataRoot "privilege_access.json"
      let secPending := (((broker.fieldArr? "requests").getD #[]).filter (fun r => (r.fieldStr? "status").getD "" == "pending")).map
        (fun r => ((r.removeField "encrypted_value").removeField "value").setField "category" (.str "secret"))
      let maPending := (((mAcc.fieldArr? "requests").getD #[]).filter (fun r => (r.fieldStr? "status").getD "" == "pending")).map
        (fun r => r.setField "category" (.str "mission_access"))
      let paPending := (((pAcc.fieldArr? "requests").getD #[]).filter (fun r => (r.fieldStr? "status").getD "" == "pending")).map
        (fun r => r.setField "category" (.str "privilege"))
      let items := secPending ++ maPending ++ paPending
      return okJson 200 (renderCompact (.obj #[
        ("items", .arr items),
        ("secret_requests", .arr secPending),
        ("mission_access_requests", .arr maPending),
        ("privilege_requests", .arr paPending),
        ("mode", .str mode)
      ]))
    if method == "POST" && cleanPath == "/api/approvals/approve-all" then
      return okJson 200 "{\"ok\":true,\"approved\":0}"
    if method == "GET" && cleanPath == "/api/approvals/stream" then
      return some (200, "text/event-stream", formatSseFrame "snapshot" "{\"items\":[]}" (some 1))

  -- 2. `/api/bitwarden/*`
  if cleanPath == "/api/bitwarden" || cleanPath.startsWith "/api/bitwarden/" then
    if !isAdmin then
      return okJson 403 "{\"error\":\"admin_required\"}"
    if method == "GET" && cleanPath == "/api/bitwarden/status" then
      let tok? ← resolveBwsToken? workingDir dataRoot
      return okJson 200 (renderCompact (.obj #[
        ("configured", .bool tok?.isSome),
        ("connected", .bool tok?.isSome)
      ]))
    if method == "PUT" && cleanPath == "/api/bitwarden/config" then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return okJson 400 "{\"error\":\"invalid_json\"}"
      let rawTok := ((jv.fieldStr? "access_token").getD "").trimAscii.toString
      if rawTok.isEmpty then
        return okJson 400 "{\"error\":\"missing_access_token\"}"
      let .ok k32 ← loadOrCreatePrivateKeyBytes workingDir dataRoot
        | return okJson 500 "{\"error\":\"private_key_unavailable\"}"
      let .ok enc ← encryptEnvValue k32 rawTok
        | return okJson 500 "{\"error\":\"encrypt_failed\"}"
      let settings ← readSettingsJson dataRoot
      let bwObj := ((settings.field? "bitwarden").getD (.obj #[])).setField "access_token" (.str enc)
      if let .error e ← writeSettingsJson dataRoot (settings.setField "bitwarden" bwObj) then
        return okJson 500 s!"\{\"error\":{jsonEscape e}}"
      return okJson 200 "{\"ok\":true,\"configured\":true}"
    if method == "DELETE" && cleanPath == "/api/bitwarden/config" then
      let settings ← readSettingsJson dataRoot
      discard <| writeSettingsJson dataRoot (settings.removeField "bitwarden")
      return okJson 200 "{\"ok\":true,\"configured\":false}"
    if method == "GET" && cleanPath == "/api/bitwarden/projects" then
      match ← listBitwardenProjectsAndSecrets workingDir dataRoot with
      | .ok (projs, _) => return okJson 200 (renderCompact (.obj #[("projects", .arr projs)]))
      | .error e => return okJson 200 (renderCompact (.obj #[("projects", .arr #[]), ("error", .str e)]))
    if method == "GET" && cleanPath == "/api/bitwarden/secrets" then
      match ← listBitwardenProjectsAndSecrets workingDir dataRoot with
      | .ok (_, secs) => return okJson 200 (renderCompact (.obj #[("secrets", .arr secs)]))
      | .error e => return okJson 200 (renderCompact (.obj #[("secrets", .arr #[]), ("error", .str e)]))
    if method == "GET" && cleanPath == "/api/bitwarden/broker" then
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let safeReqs := (((broker.fieldArr? "requests").getD #[])).map (fun r => (r.removeField "encrypted_value").removeField "value")
      let safeBroker := broker.setField "requests" (.arr safeReqs)
      return okJson 200 (renderCompact safeBroker)
    if method == "POST" && cleanPath.startsWith "/api/bitwarden/requests/" && cleanPath.endsWith "/approve" then
      let reqId := ((cleanPath.drop 24).dropEnd 8).toString
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let reqs := (broker.fieldArr? "requests").getD #[]
      let some targetReq := reqs.find? (fun r => (r.fieldStr? "id").getD "" == reqId)
        | return okJson 404 "{\"error\":\"request_not_found\"}"
      let grants := (broker.fieldArr? "grants").getD #[]
      let gid ← newUuidV4
      let newGrant := JVal.obj #[
        ("id", .str gid),
        ("mission_id", targetReq.fieldOrNull "mission_id"),
        ("project", targetReq.fieldOrNull "project"),
        ("bitwarden_project", targetReq.fieldOrNull "bitwarden_project"),
        ("secret_name", targetReq.fieldOrNull "secret_name"),
        ("created_at", .str nowIso),
        ("expires_at_epoch", JVal.uint64 (nowEpochSec + 86400))
      ]
      let nextReqs := reqs.map fun r =>
        if (r.fieldStr? "id").getD "" == reqId then
          ((r.removeField "encrypted_value").setField "status" (.str "approved")).setField "decided_at" (.str nowIso)
        else r
      let nextBroker := (broker.setField "requests" (.arr nextReqs)).setField "grants" (.arr (grants.push newGrant))
      discard <| writeDataJsonObj dataRoot "secret_broker.json" nextBroker
      return okJson 200 (renderCompact (.obj #[("ok", .bool true), ("grant", newGrant)]))
    if method == "POST" && cleanPath.startsWith "/api/bitwarden/requests/" && cleanPath.endsWith "/reject" then
      let reqId := ((cleanPath.drop 24).dropEnd 7).toString
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let reqs := (broker.fieldArr? "requests").getD #[]
      let nextReqs := reqs.map fun r =>
        if (r.fieldStr? "id").getD "" == reqId then
          ((r.removeField "encrypted_value").setField "status" (.str "rejected")).setField "decided_at" (.str nowIso)
        else r
      discard <| writeDataJsonObj dataRoot "secret_broker.json" (broker.setField "requests" (.arr nextReqs))
      return okJson 200 "{\"ok\":true}"
    if method == "DELETE" && cleanPath.startsWith "/api/bitwarden/grants/" then
      let gid := (cleanPath.drop 22).toString
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let grants := (broker.fieldArr? "grants").getD #[]
      let nextGrants := grants.map fun g =>
        if (g.fieldStr? "id").getD "" == gid then g.setField "revoked_at" (.str nowIso) else g
      discard <| writeDataJsonObj dataRoot "secret_broker.json" (broker.setField "grants" (.arr nextGrants))
      return okJson 200 "{\"ok\":true}"
    if method == "PUT" && cleanPath.startsWith "/api/bitwarden/default-access/" then
      let rawSlug := (cleanPath.drop 30).toString
      let some slug := percentDecodeStrict rawSlug
        | return okJson 400 "{\"error\":\"invalid_project\"}"
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return okJson 400 "{\"error\":\"invalid_json\"}"
      let bwProjs := ((jv.fieldArr? "bitwarden_projects").orElse (fun _ => jv.fieldArr? "projects")).getD #[]
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let da := ((broker.field? "default_access").getD (.obj #[])).setField slug (.arr bwProjs)
      discard <| writeDataJsonObj dataRoot "secret_broker.json" (broker.setField "default_access" da)
      return okJson 200 (renderCompact (.obj #[("ok", .bool true), ("project", .str slug), ("bitwarden_projects", .arr bwProjs)]))

  -- 3. Legacy `/api/secrets*`
  if cleanPath == "/api/secrets" || cleanPath.startsWith "/api/secrets/" then
    if !isAdmin then
      return okJson 403 "{\"error\":\"admin_required\"}"
    let secDoc ← readDataJsonObj dataRoot "secrets.json"
    let items := (secDoc.fieldArr? "secrets").getD ((secDoc.fieldArr? "items").getD #[])
    let redact (s : JVal) : JVal := ((s.removeField "value").removeField "encrypted_value").setField "has_value" (.bool true)
    if method == "GET" && cleanPath == "/api/secrets/status" then
      let hasKey := (← loadPrivateKeyBytes? workingDir dataRoot).isSome
      return okJson 200 (renderCompact (.obj #[("initialized", .bool hasKey), ("unlocked", .bool hasKey)]))
    if method == "GET" && cleanPath == "/api/secrets/categories" then
      return okJson 200 "{\"categories\":[\"api_key\",\"oauth\",\"ssh\",\"other\"]}"
    if method == "GET" && cleanPath == "/api/secrets/registry" then
      return okJson 200 (renderCompact (.obj #[("secrets", .arr (items.map redact))]))
    if method == "GET" && cleanPath == "/api/secrets" then
      return okJson 200 (renderCompact (.arr (items.map redact)))
    if method == "POST" && (cleanPath == "/api/secrets/initialize" || cleanPath == "/api/secrets/unlock" || cleanPath == "/api/secrets/lock") then
      discard <| loadOrCreatePrivateKeyBytes workingDir dataRoot
      return okJson 200 "{\"ok\":true,\"unlocked\":true}"

  -- 4. `/api/mission-access*`
  if cleanPath == "/api/mission-access" || cleanPath.startsWith "/api/mission-access/" then
    if !isAdmin then
      return okJson 403 "{\"error\":\"admin_required\"}"
    let doc ← readDataJsonObj dataRoot "mission_access.json"
    let reqs := (doc.fieldArr? "requests").getD #[]
    let grants := (doc.fieldArr? "grants").getD #[]
    if method == "GET" && cleanPath == "/api/mission-access" then
      return okJson 200 (renderCompact (.obj #[("requests", .arr reqs), ("grants", .arr grants)]))
    if method == "POST" && cleanPath.startsWith "/api/mission-access/requests/" && cleanPath.endsWith "/approve" then
      let reqId := ((cleanPath.drop 29).dropEnd 8).toString
      let some r := reqs.find? (fun x => (x.fieldStr? "id").getD "" == reqId)
        | return okJson 404 "{\"error\":\"request_not_found\"}"
      let ttlH := (r.fieldNat? "ttl_hours").getD 24
      let gid ← newUuidV4
      let grant := JVal.obj #[
        ("id", .str gid),
        ("requester_mission_id", r.fieldOrNull "requester_mission_id"),
        ("target_mission_id", r.fieldOrNull "target_mission_id"),
        ("scope", .str "read"),
        ("created_at", .str nowIso),
        ("expires_at_epoch", JVal.uint64 (nowEpochSec + (ttlH * 3600).toUInt64))
      ]
      let nextReqs := reqs.map fun x =>
        if (x.fieldStr? "id").getD "" == reqId then (x.setField "status" (.str "approved")).setField "decided_at" (.str nowIso) else x
      discard <| writeDataJsonObj dataRoot "mission_access.json"
        ((doc.setField "requests" (.arr nextReqs)).setField "grants" (.arr (grants.push grant)))
      return okJson 200 (renderCompact (.obj #[("ok", .bool true), ("grant", grant)]))
    if method == "POST" && cleanPath.startsWith "/api/mission-access/requests/" && cleanPath.endsWith "/reject" then
      let reqId := ((cleanPath.drop 29).dropEnd 7).toString
      let nextReqs := reqs.map fun x =>
        if (x.fieldStr? "id").getD "" == reqId then (x.setField "status" (.str "denied")).setField "decided_at" (.str nowIso) else x
      discard <| writeDataJsonObj dataRoot "mission_access.json" (doc.setField "requests" (.arr nextReqs))
      return okJson 200 "{\"ok\":true}"
    if method == "DELETE" && cleanPath.startsWith "/api/mission-access/grants/" then
      let gid := (cleanPath.drop 27).toString
      let nextGrants := grants.map fun g =>
        if (g.fieldStr? "id").getD "" == gid then g.setField "revoked_at" (.str nowIso) else g
      discard <| writeDataJsonObj dataRoot "mission_access.json" (doc.setField "grants" (.arr nextGrants))
      return okJson 200 "{\"ok\":true}"

  -- 5. `/api/privilege-access*` (excluding `/api/privilege-access/verify-and-log` which is handled earlier in `Control.lean`)
  if cleanPath == "/api/privilege-access" || cleanPath.startsWith "/api/privilege-access/" then
    if !isAdmin then
      return okJson 403 "{\"error\":\"admin_required\"}"
    if method == "GET" && cleanPath == "/api/privilege-access" then
      let summary ← mcpListPrivilegedAccess st dataRoot "" nowEpochSec
      let bState ← match bunkerRef? with | some r => r.get | none => pure (0 : UInt8)
      return okJson 200 (renderCompact (summary.setField "bunker_state" (JVal.nat bState.toNat)))
    if method == "POST" && cleanPath == "/api/privilege-access/request" then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return okJson 400 "{\"error\":\"invalid_json\"}"
      let mid := (jv.fieldStr? "mission_id").getD ""
      let sc := (jv.fieldStr? "scope").getD "ops_read"
      let th := (jv.fieldStr? "target_host").getD "self"
      let rsn := (jv.fieldStr? "reason").getD ""
      let units := ((jv.fieldArr? "allowed_units").getD #[]).filterMap JVal.asStr?
      let ttl := (jv.fieldNat? "ttl_minutes").getD 30
      let res ← mcpRequestPrivilegedAccess dataRoot mid sc th rsn units ttl nowEpochSec
      return okJson 200 (renderCompact res)
    if method == "POST" && cleanPath.startsWith "/api/privilege-access/requests/" && cleanPath.endsWith "/approve" then
      let reqId := ((cleanPath.drop 31).dropEnd 8).toString
      let doc ← readDataJsonObj dataRoot "privilege_access.json"
      let reqs := (doc.fieldArr? "requests").getD #[]
      let some r := reqs.find? (fun x => (x.fieldStr? "id").getD "" == reqId)
        | return okJson 404 "{\"error\":\"request_not_found\"}"
      let gid ← newUuidV4
      let .ok rnd ← OrbNetLeaf.Crypto.randBytes 24
        | return okJson 500 "{\"error\":\"csprng_failed\"}"
      let leaseTok := "orb-pl-" ++ bytesToHexLower rnd
      let ttlMins := (r.fieldNat? "ttl_minutes").getD 30
      let expEpoch := nowEpochSec + (ttlMins * 60).toUInt64
      let unitsJson := renderCompact ((r.field? "allowed_units").getD (.arr #[]))
      let lease : PrivilegeLeaseRecord := {
        grantId := gid
        leaseToken := leaseTok
        missionId := (r.fieldStr? "mission_id").getD ""
        targetHost := (r.fieldStr? "target_host").getD "self"
        scope := (r.fieldStr? "scope").getD "ops_read"
        allowedUnitsJson := unitsJson
        requireForceCmd := false
        biometricSigned := true
        revoked := false
        expiresAtEpoch := expEpoch
        leaseEpoch := expEpoch
      }
      if let .error e ← upsertPrivilegeLease st lease then
        return okJson 500 s!"\{\"error\":{jsonEscape e}}"
      let nextReqs := reqs.map fun x =>
        if (x.fieldStr? "id").getD "" == reqId then (x.setField "status" (.str "approved")).setField "decided_at" (.str nowIso) else x
      discard <| writeDataJsonObj dataRoot "privilege_access.json" (doc.setField "requests" (.arr nextReqs))
      return okJson 200 (renderCompact (.obj #[
        ("ok", .bool true),
        ("grant_id", .str gid),
        ("lease_token", .str leaseTok),
        ("expires_at_epoch", JVal.uint64 expEpoch)
      ]))
    if method == "POST" && cleanPath.startsWith "/api/privilege-access/requests/" && cleanPath.endsWith "/reject" then
      let reqId := ((cleanPath.drop 31).dropEnd 7).toString
      let doc ← readDataJsonObj dataRoot "privilege_access.json"
      let reqs := (doc.fieldArr? "requests").getD #[]
      let nextReqs := reqs.map fun x =>
        if (x.fieldStr? "id").getD "" == reqId then (x.setField "status" (.str "denied")).setField "decided_at" (.str nowIso) else x
      discard <| writeDataJsonObj dataRoot "privilege_access.json" (doc.setField "requests" (.arr nextReqs))
      return okJson 200 "{\"ok\":true}"
    if method == "DELETE" && cleanPath.startsWith "/api/privilege-access/grants/" then
      let gid := (cleanPath.drop 29).toString
      discard <| mcpRevokePrivilegedAccess st gid ""
      return okJson 200 "{\"ok\":true}"
    if method == "POST" && cleanPath == "/api/privilege-access/revoke-all" then
      discard <| execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1;" #[]
      return okJson 200 "{\"ok\":true}"
    if method == "POST" && cleanPath == "/api/privilege-access/bunker" then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let nextSt : UInt8 := ((jv.fieldNat? "state").getD 0).toUInt8
      if let some r := bunkerRef? then
        r.set nextSt
      discard <| writePersistedBunkerState st nextSt
      return okJson 200 (renderCompact (.obj #[("ok", .bool true), ("bunker_state", JVal.nat nextSt.toNat)]))

  return none

end OrbCore.SecretAndApproval
