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
  -- `encrypted_access_token` is the stored field; the other two names are read for older settings files.
  if let some rawTok := ((bwObj.fieldStr? "encrypted_access_token").orElse (fun _ => bwObj.fieldStr? "access_token")).orElse
      (fun _ => settings.fieldStr? "bws_access_token") then
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
    | .ok _ => return .error "invalid_bws_projects_response"
    | .error e => return .error e
  let secsJv ← match ← runBwsJson tok #["secret", "list"] with
    | .ok (.arr ss) => pure ss
    | .ok _ => return .error "invalid_bws_secrets_response"
    | .error e => return .error e
  -- Redact `value` from metadata listing!
  let redactedSecs := secsJv.map (fun s => s.removeField "value")
  return .ok (projsJv, redactedSecs)

/-- The broker document with `default_access` taken from `settings.bitwarden.default_access`, where the
    Bitwarden settings page stores it. Entries only present in `secret_broker.json` are kept. -/
def readSecretBrokerWithDefaults (dataRoot : String) : IO JVal := do
  let broker ← readDataJsonObj dataRoot "secret_broker.json"
  let settings ← readSettingsJson dataRoot
  match (settings.field? "bitwarden").bind (·.field? "default_access") with
  | some (.obj pairs) =>
    let merged := pairs.foldl (fun acc (slug, projs) => acc.setField slug projs)
      ((broker.field? "default_access").getD (.obj #[]))
    return broker.setField "default_access" merged
  | _ => return broker

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

/-- Cloud-compute provider credentials reserved for Core's managed-machine control plane. A mission
    holding one could rent machines outside Core's ownership tracking, spend caps and reaper. -/
def isCoreReservedComputeSecret (key : String) : Bool :=
  #["BOAT_API_KEY", "LEANCI_API_KEY", "LEANCI_TOKEN", "BOOST_API_KEY", "BOOST_TOKEN",
    "HETZNER_CLOUD_APIKEY", "HCLOUD_TOKEN", "SCALEWAY_SECRET_KEY", "SCALEWAY_KEY_ID",
    "SCW_SECRET_KEY", "SCW_ACCESS_KEY", "VASTAI_API_KEY", "VAST_API_KEY", "RUNPOD_API_KEY",
    "COLAB_API_TOKEN", "COLAB_API_DOTENV_PRIVATE_KEY"].contains key.trimAscii.toString.toUpper

/-- The only secrets an untrusted managed machine may receive. -/
def isAllowlistedManagedSecret (key : String) : Bool :=
  #["GITHUB_TOKEN", "GH_TOKEN"].contains key.trimAscii.toString.toUpper

/-- `Orb.Kernel.computeSecretGate` applied to `secret_get`: reserved compute keys are never delivered,
    and a caller on a managed machine receives allowlisted secrets only. -/
def admitsSecretDelivery (key : String) (callerOnManagedNode : Bool) : Bool :=
  Orb.Kernel.computeSecretGate
    (if isCoreReservedComputeSecret key then 1 else 0)
    (if callerOnManagedNode then 1 else 0)
    (if isAllowlistedManagedSecret key then 1 else 0)
    0 == 257

/-- Core-only resolution for the operator's reserved sealing path. This value
    must never be placed in an MCP response, file delivery, action receipt or log. -/
def resolveReservedComputeVaultSecret (workingDir dataRoot key : String) : IO (Except String String) := do
  if !isCoreReservedComputeSecret key then return .error "not_core_reserved"
  let some token ← resolveBwsToken? workingDir dataRoot
    | return .error "reserved_secret_vault_unconfigured"
  let .ok (_, secrets) ← listBitwardenProjectsAndSecrets workingDir dataRoot
    | return .error "reserved_secret_vault_unavailable"
  let matchingSecrets := secrets.filter (fun secret => secret.fieldStr? "key" == some key)
  if matchingSecrets.size != 1 then return .error "reserved_secret_missing_or_ambiguous"
  let some id := matchingSecrets[0]!.fieldStr? "id"
    | return .error "reserved_secret_missing_id"
  let .ok secret ← runBwsJson token #["secret", "get", id]
    | return .error "reserved_secret_vault_unavailable"
  let value := (secret.fieldStr? "value").getD "" |>.trimAscii.toString
  if value.isEmpty then return .error "reserved_secret_empty"
  return .ok value

/-- Compatibility for single-provider sealing; batch sealing deliberately uses
    the vault-only resolver so both instances use the same Bitwarden entries. -/
def resolveReservedComputeSecret (workingDir dataRoot key : String) : IO (Except String String) := do
  if !isCoreReservedComputeSecret key then return .error "not_core_reserved"
  if let some value ← IO.getEnv key then
    let clean := value.trimAscii.toString
    if !clean.isEmpty then return .ok clean
  resolveReservedComputeVaultSecret workingDir dataRoot key

/-- Names only. Disabled providers are included when their vault key exists;
    duplicates are refused before any provider is resealed. -/
def configuredReservedComputeProviders (workingDir dataRoot : String) : IO (Except String (Array String)) := do
  let .ok (_, secrets) ← listBitwardenProjectsAndSecrets workingDir dataRoot
    | return .error "reserved_secret_vault_unavailable"
  let mut providers : Array String := #[]
  for provider in OrbCore.ManagedProvider.registry do
    let matching := secrets.filter (fun secret => secret.fieldStr? "key" == some provider.secretName)
    if matching.size > 1 then return .error "reserved_secret_ambiguous"
    if matching.size == 1 then providers := providers.push provider.name
  return .ok providers

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
  let broker ← readSecretBrokerWithDefaults dataRoot
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
      let readable := !isCoreReservedComputeSecret key &&
        missionHasBwProjectAccess broker missionId projectSlug pname pid nowEpochSec nowIso
      JVal.obj #[
        ("name", .str key),
        ("bitwarden_project", .str pname),
        ("accessible_now", .bool readable)
      ]
    return .obj #[("configured", .bool true), ("secrets", .arr items)]

def mcpSecretGet
    (workingDir dataRoot missionId projectSlug secretName reason : String)
    (callerOnManagedNode : Bool)
    (nowEpochSec : UInt64) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  if !admitsSecretDelivery secretName callerOnManagedNode then
    return .obj #[("status", .str "refused"), ("name", .str secretName),
      ("error", .str (if isCoreReservedComputeSecret secretName
        then "This credential is reserved to Core's managed-machine control plane; rent machines through spawn_managed_machine or start_mission instead."
        else "This secret is not delivered to managed machines."))]
  let broker ← readSecretBrokerWithDefaults dataRoot
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
    let safeName := String.ofList (secretName.toList.filter (fun c => c.isAlphanum || c == '_' || c == '-'))
    -- The value travels to the caller's MCP companion, which writes it to a private `0600` file beside
    -- the harness and replaces `secret_delivery` with `path` / `export` before the model sees the
    -- result. Core must not write the file itself: a remote mission cannot read Core's disk.
    return .obj #[
      ("status", .str "granted"),
      ("name", .str secretName),
      ("project", if projectSlug.isEmpty then .null else .str projectSlug),
      ("secret_delivery", .obj #[("name", .str (if safeName.isEmpty then "secret" else safeName)), ("value", .str val)])
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

private def lookupMissionTitleOpt (st : CoreStore) (missionId : String) : IO (Option String) := do
  let mid := missionId.trimAscii.toString
  if mid.isEmpty then return none
  if let .ok rs ← execParamQuery st.missionsDb "SELECT COALESCE(title,'') FROM missions WHERE id=?1 LIMIT 1;" #[mid] then
    if rs.size > 1 then
      let t := ((rs[1]?).bind (·[0]?)).getD "" |>.trimAscii.toString
      if !t.isEmpty then return some t
  return none

private def buildExternalRequesterJVal (sessionId : String) (clientKind : String := "cli")
    (clientLabel : String := "sandboxed-mcp") (hostHint : String := "") : JVal :=
  let sid := if sessionId.trimAscii.toString.isEmpty then "external" else sessionId.trimAscii.toString
  let base : Array (String × JVal) := #[
    ("kind", .str "external_session"),
    ("session_id", .str sid),
    ("client_kind", .str (if clientKind.isEmpty then "cli" else clientKind)),
    ("client_label", .str (if clientLabel.isEmpty then "sandboxed-mcp" else clientLabel))
  ]
  if hostHint.trimAscii.toString.isEmpty then .obj base
  else .obj (base.push ("host_hint", .str hostHint.trimAscii.toString))

private def canonicalSubjectIdForApproval (subject : JVal) : String :=
  let kind := (subject.fieldStr? "kind").getD "mission"
  if kind == "external_session" then
    let sid := (subject.fieldStr? "session_id").getD "external"
    let ckind := (subject.fieldStr? "client_kind").getD "local_mcp"
    let clabel := ((subject.fieldStr? "client_label").getD "").trimAscii.toString
    let hhint := ((subject.fieldStr? "host_hint").getD "").trimAscii.toString
    let fullHex := bytesToHexLower (sha256Bytes s!"{clabel}\n{hhint}".toUTF8)
    let shortHex := (fullHex.take 16).toString
    s!"session:{sid}:{ckind}:{shortHex}"
  else
    let mid := (subject.fieldStr? "mission_id").getD ""
    s!"mission:{mid}"

def computeApprovalDigest (kind id : String) (subject : JVal) (fields : Array String) : String :=
  let subjKind := (subject.fieldStr? "kind").getD "mission"
  let head :=
    if subjKind == "external_session" then
      s!"orb-approval-v2\n{kind}\n{id}\n{canonicalSubjectIdForApproval subject}"
    else
      let mid := (subject.fieldStr? "mission_id").getD ""
      s!"orb-approval-v1\n{kind}\n{id}\n{mid}"
  let payload := String.intercalate "\n" (head :: fields.toList)
  bytesToHexLower (sha256Bytes payload.toUTF8)

private def extractAllowedUnitsFromRequest (r : JVal) : Array String := Id.run do
  let mut out : Array String := #[]
  if let some u := (r.fieldStr? "allowed_unit").map (·.trimAscii.toString) then
    if !u.isEmpty then out := out.push u
  if let some xs := r.fieldArr? "allowed_units" then
    for x in xs do
      if let some s := x.asStr? then
        let ts := s.trimAscii.toString
        if !ts.isEmpty && !out.contains ts then out := out.push ts
  return out

private def normalizePrivilegeRequestJVal
    (r : JVal)
    (leaseLookup : Array (String × Bool × UInt64))
    (nowEpochSec : UInt64)
    (nowIso : String) : JVal := Id.run do
  let rawState := ((r.fieldStr? "state").orElse (fun _ => r.fieldStr? "status") |>.getD "pending").trimAscii.toString
  let mappedState :=
    if rawState == "rejected" then "denied"
    else if rawState.isEmpty then "pending"
    else rawState
  let gid := (r.fieldStr? "grant_id").getD ""
  let revAt0 := (r.fieldStr? "revoked_at").getD ""
  let expAt0 := (r.fieldStr? "expires_at").getD ""
  let mut effState := mappedState
  let mut effRevAt := revAt0
  let mut effExpAt := expAt0
  if let some (_, dbRev, dbExp) :=
      if gid.isEmpty then none else leaseLookup.find? (fun (lgid, _, _) => lgid == gid) then
    if effExpAt.isEmpty && dbExp > 0 then
      effExpAt := formatEpochIso8601Utc dbExp
    if dbRev && effRevAt.isEmpty then
      effRevAt := nowIso
    if dbRev then
      effState := "revoked"
    else if effState == "approved" && dbExp > 0 && nowEpochSec ≥ dbExp then
      effState := "expired"
  if !effRevAt.isEmpty then
    effState := "revoked"
  else if effState == "approved" && !effExpAt.isEmpty && decide (effExpAt ≤ nowIso) then
    effState := "expired"
  let mid := ((r.fieldStr? "requester_mission_id").orElse (fun _ => r.fieldStr? "mission_id") |>.getD "").trimAscii.toString
  let units := extractAllowedUnitsFromRequest r
  let allowedUnitField : JVal :=
    match units[0]? with
    | some u => .str u
    | none => .null
  let sessScoped := (r.fieldBool? "session_scoped").getD true
  let ttlMins := (r.fieldNat? "ttl_minutes").getD 30
  let targetHost :=
    let th := ((r.fieldStr? "target_host").getD "self").trimAscii.toString
    if th.isEmpty then "self" else th
  let scope :=
    let sc := ((r.fieldStr? "scope").getD "ops_read").trimAscii.toString
    if sc == "systemctl" || sc.isEmpty then "service_deploy" else sc
  let reqSubj : JVal :=
    match r.field? "requester" with
    | some v@(.obj _) => v
    | _ =>
      if mid.isEmpty then buildExternalRequesterJVal ((r.fieldStr? "session_id").getD "external")
      else .obj #[("kind", .str "mission"), ("mission_id", .str mid)]
  let base := r
    |>.removeField "lease_token"
    |>.setField "state" (.str effState)
    |>.setField "status" (.str effState)
    |>.setField "scope" (.str scope)
    |>.setField "target_host" (.str targetHost)
    |>.setField "allowed_unit" allowedUnitField
    |>.setField "allowed_units" (.arr (units.map JVal.str))
    |>.setField "session_scoped" (.bool sessScoped)
    |>.setField "ttl_minutes" (JVal.nat ttlMins)
    |>.setField "requester_mission_id" (if mid.isEmpty then .null else .str mid)
    |>.setField "mission_id" (if mid.isEmpty then .null else .str mid)
    |>.setField "requester" reqSubj
    |>.setField "expires_at" (if effExpAt.isEmpty then .null else .str effExpAt)
    |>.setField "revoked_at" (if effRevAt.isEmpty then .null else .str effRevAt)
  return base

private def normalizeMissionAccessRequestJVal (r : JVal) (nowIso : String) : JVal :=
  let rawState := ((r.fieldStr? "state").orElse (fun _ => r.fieldStr? "status") |>.getD "pending").trimAscii.toString
  let mapped := if rawState == "rejected" then "denied" else if rawState.isEmpty then "pending" else rawState
  let revAt := (r.fieldStr? "revoked_at").getD ""
  let expAt := (r.fieldStr? "expires_at").getD ""
  let effState :=
    if !revAt.isEmpty then "revoked"
    else if mapped == "approved" && !expAt.isEmpty && decide (expAt ≤ nowIso) then "expired"
    else mapped
  r.setField "state" (.str effState) |>.setField "status" (.str effState)

private def riskOfApprovalKindTier (kind tier : String) (allProjects : Bool := false) : String :=
  if kind == "privilege" then
    if tier == "root_exec" || tier == "host_admin" then "critical"
    else if tier == "service_deploy" then "elevated"
    else "routine"
  else if kind == "mission_access" then
    "elevated"
  else if tier == "delete" || tier == "move" then
    "critical"
  else if tier == "write" || allProjects then
    "elevated"
  else
    "routine"

private def normalizeSecretTier (rawKind : String) : String :=
  if rawKind == "secret_put" || rawKind == "write" then "write"
  else if rawKind == "secret_delete" || rawKind == "delete" then "delete"
  else if rawKind == "secret_move" || rawKind == "move" then "move"
  else "read"

private def buildPrivilegeApprovalItem (rNorm : JVal) : JVal :=
  let rid := (rNorm.fieldStr? "id").getD ""
  let scope := (rNorm.fieldStr? "scope").getD "ops_read"
  let targetHost := (rNorm.fieldStr? "target_host").getD "self"
  let allowedUnit := (rNorm.fieldStr? "allowed_unit").getD ""
  let ttlMins := (rNorm.fieldNat? "ttl_minutes").getD 30
  let sessScoped := (rNorm.fieldBool? "session_scoped").getD true
  let mid := (rNorm.fieldStr? "requester_mission_id").getD ""
  let subj : JVal :=
    match rNorm.field? "requester" with
    | some v@(.obj _) => v
    | _ =>
      if mid.isEmpty then buildExternalRequesterJVal "external"
      else .obj #[("kind", .str "mission"), ("mission_id", .str mid)]
  let digest := computeApprovalDigest "privilege" rid subj
    #[scope, targetHost, allowedUnit, s!"{ttlMins}", if sessScoped then "session" else "ttl"]
  let risk := riskOfApprovalKindTier "privilege" scope false
  JVal.obj #[
    ("kind", .str "privilege"),
    ("id", .str rid),
    ("requester_mission_id", if mid.isEmpty then .null else .str mid),
    ("requester_title", rNorm.fieldOrNull "requester_title"),
    ("requester_subject", subj),
    ("requester_label", rNorm.fieldOrNull "requester_label"),
    ("tier", .str scope),
    ("target", .str targetHost),
    ("risk", .str risk),
    ("reason", .str ((rNorm.fieldStr? "reason").getD "")),
    ("created_at", .str ((rNorm.fieldStr? "created_at").getD "")),
    ("digest", .str digest),
    ("request", rNorm)
  ]

private def buildSecretApprovalItem (rRaw : JVal) : JVal :=
  let rSafe := (rRaw.removeField "encrypted_value").removeField "value"
  let rid := (rSafe.fieldStr? "id").getD ""
  let tier := normalizeSecretTier ((rSafe.fieldStr? "kind").getD "read")
  let secKey := ((rSafe.fieldStr? "key").orElse (fun _ => rSafe.fieldStr? "secret_name") |>.getD "")
  let projId := ((rSafe.fieldStr? "project_id").orElse (fun _ => rSafe.fieldStr? "bitwarden_project") |>.getD "")
  let targetProjId := (rSafe.fieldStr? "target_project_id").getD ""
  let allProjs := (rSafe.fieldBool? "all_projects").getD (projId == "all")
  let reqEnriched := rSafe
    |>.setField "kind" (.str tier)
    |>.setField "key" (if secKey.isEmpty then .null else .str secKey)
    |>.setField "project_id" (if projId.isEmpty || projId == "all" then .null else .str projId)
    |>.setField "all_projects" (.bool allProjs)
  let target :=
    if !secKey.isEmpty then secKey
    else if allProjs || projId.isEmpty then "*"
    else projId
  let mid := ((rSafe.fieldStr? "requester_mission_id").orElse (fun _ => rSafe.fieldStr? "mission_id") |>.getD "")
  let subj : JVal :=
    match rSafe.field? "requester" with
    | some v@(.obj _) => v
    | _ =>
      if mid.isEmpty then buildExternalRequesterJVal "external"
      else .obj #[("kind", .str "mission"), ("mission_id", .str mid)]
  let digest := computeApprovalDigest "secret" rid subj
    #[tier, secKey, if allProjs then "" else projId, targetProjId, if allProjs then "all" else "", ""]
  let risk := riskOfApprovalKindTier "secret" tier allProjs
  JVal.obj #[
    ("kind", .str "secret"),
    ("id", .str rid),
    ("requester_mission_id", if mid.isEmpty then .null else .str mid),
    ("requester_title", rSafe.fieldOrNull "requester_title"),
    ("requester_subject", subj),
    ("requester_label", rSafe.fieldOrNull "requester_label"),
    ("tier", .str tier),
    ("target", .str target),
    ("risk", .str risk),
    ("reason", .str ((rSafe.fieldStr? "reason").getD "")),
    ("created_at", .str ((rSafe.fieldStr? "created_at").getD "")),
    ("digest", .str digest),
    ("request", reqEnriched)
  ]

private def buildMissionAccessApprovalItem (rRaw : JVal) (nowIso : String) : JVal :=
  let rNorm := normalizeMissionAccessRequestJVal rRaw nowIso
  let rid := (rNorm.fieldStr? "id").getD ""
  let scope := (rNorm.fieldStr? "scope").getD "read"
  let tier := if scope == "control" then "control_mission" else "read_mission"
  let targetMid := (rNorm.fieldStr? "target_mission_id").getD ""
  let ttlH := (rNorm.fieldNat? "ttl_hours").getD 24
  let mid := ((rNorm.fieldStr? "requester_mission_id").orElse (fun _ => rNorm.fieldStr? "mission_id") |>.getD "")
  let subj : JVal :=
    match rNorm.field? "requester" with
    | some v@(.obj _) => v
    | _ =>
      if mid.isEmpty then buildExternalRequesterJVal "external"
      else .obj #[("kind", .str "mission"), ("mission_id", .str mid)]
  let digest := computeApprovalDigest "mission_access" rid subj #[scope, targetMid, s!"{ttlH}"]
  let risk := riskOfApprovalKindTier "mission_access" tier false
  JVal.obj #[
    ("kind", .str "mission_access"),
    ("id", .str rid),
    ("requester_mission_id", if mid.isEmpty then .null else .str mid),
    ("requester_title", rNorm.fieldOrNull "requester_title"),
    ("requester_subject", subj),
    ("requester_label", rNorm.fieldOrNull "requester_label"),
    ("tier", .str tier),
    ("target", .str targetMid),
    ("risk", .str risk),
    ("reason", .str ((rNorm.fieldStr? "reason").getD "")),
    ("created_at", .str ((rNorm.fieldStr? "created_at").getD "")),
    ("digest", .str digest),
    ("request", rNorm)
  ]

private def approveSinglePrivilegeRequest
    (st : CoreStore)
    (dataRoot reqId : String)
    (ttlOverride? : Option Nat)
    (sessScopedOverride? : Option Bool)
    (nowEpochSec : UInt64)
    (nowIso : String) : IO (Except (Nat × String) (JVal × String × String × UInt64)) := do
  let doc ← readDataJsonObj dataRoot "privilege_access.json"
  let reqs := (doc.fieldArr? "requests").getD #[]
  let some r := reqs.find? (fun x => (x.fieldStr? "id").getD "" == reqId)
    | return .error (404, "{\"error\":\"request_not_found\"}")
  let gid ← newUuidV4
  let .ok rnd ← OrbNetLeaf.Crypto.randBytes 24
    | return .error (500, "{\"error\":\"csprng_failed\"}")
  let leaseTok := "orb-pl-" ++ bytesToHexLower rnd
  let baseTtl := (r.fieldNat? "ttl_minutes").getD 30
  let ttlMins := Nat.min 240 (Nat.max 1 (ttlOverride?.getD baseTtl))
  let sessScoped := sessScopedOverride?.getD ((r.fieldBool? "session_scoped").getD true)
  let expEpoch := nowEpochSec + (ttlMins * 60).toUInt64
  let expIso := formatEpochIso8601Utc expEpoch
  let units := extractAllowedUnitsFromRequest r
  let unitsJson := renderCompact (.arr (units.map JVal.str))
  let mid := ((r.fieldStr? "requester_mission_id").orElse (fun _ => r.fieldStr? "mission_id") |>.getD "").trimAscii.toString
  let targetHost :=
    let th := ((r.fieldStr? "target_host").getD "self").trimAscii.toString
    if th.isEmpty then "self" else th
  let scope :=
    let sc := ((r.fieldStr? "scope").getD "ops_read").trimAscii.toString
    if sc == "systemctl" || sc.isEmpty then "service_deploy" else sc
  let lease : PrivilegeLeaseRecord := {
    grantId := gid
    leaseToken := leaseTok
    missionId := mid
    targetHost := targetHost
    scope := scope
    allowedUnitsJson := unitsJson
    requireForceCmd := false
    biometricSigned := true
    revoked := false
    expiresAtEpoch := expEpoch
    leaseEpoch := expEpoch
  }
  if let .error e ← upsertPrivilegeLease st lease then
    return .error (500, s!"\{\"error\":{jsonEscape e}}")
  let mut approvedNorm : JVal := .obj #[]
  let mut nextReqs : Array JVal := #[]
  for x in reqs do
    if (x.fieldStr? "id").getD "" == reqId then
      let upd := x
        |>.setField "state" (.str "approved")
        |>.setField "status" (.str "approved")
        |>.setField "grant_id" (.str gid)
        |>.setField "ttl_minutes" (JVal.nat ttlMins)
        |>.setField "session_scoped" (.bool sessScoped)
        |>.setField "decided_at" (.str nowIso)
        |>.setField "expires_at" (.str expIso)
        |>.removeField "revoked_at"
      let norm := normalizePrivilegeRequestJVal upd #[(gid, false, expEpoch)] nowEpochSec nowIso
      approvedNorm := norm
      nextReqs := nextReqs.push norm
    else nextReqs := nextReqs.push x
  let audits := (doc.fieldArr? "audit").getD #[]
  let auditEntry := JVal.obj #[
    ("at", .str nowIso),
    ("request_id", .str reqId),
    ("requester_mission_id", if mid.isEmpty then .null else .str mid),
    ("requester", approvedNorm.fieldOrNull "requester"),
    ("target_host", .str targetHost),
    ("scope", .str scope),
    ("action", .str "approved"),
    ("detail", match units[0]? with | some u => .str u | none => .null)
  ]
  let nextDoc := (doc.setField "requests" (.arr nextReqs)).setField "audit" (.arr (#[auditEntry] ++ audits))
  discard <| writeDataJsonObj dataRoot "privilege_access.json" nextDoc
  return .ok (approvedNorm, gid, leaseTok, expEpoch)

def mcpRequestPrivilegedAccess
    (st? : Option CoreStore)
    (dataRoot missionId sessionId scope targetHost reason : String)
    (allowedUnits : Array String) (ttlMinutes : Nat) (nowEpochSec : UInt64)
    (sessionScoped : Bool := true) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "privilege_access.json"
  let reqs := (doc.fieldArr? "requests").getD #[]
  let reqId ← newUuidV4
  let clampedTtl := Nat.min 240 (Nat.max 1 ttlMinutes)
  let cleanMid := missionId.trimAscii.toString
  let cleanHost := if targetHost.trimAscii.toString.isEmpty then "self" else targetHost.trimAscii.toString
  let cleanScope :=
    let sc := scope.trimAscii.toString
    if sc == "systemctl" || sc.isEmpty then "service_deploy" else sc
  let cleanUnits := allowedUnits.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let allowedUnitField : JVal := match cleanUnits[0]? with | some u => .str u | none => .null
  let titleOpt ← match st? with
    | some st => lookupMissionTitleOpt st cleanMid
    | none => pure none
  let reqSubj : JVal :=
    if cleanMid.isEmpty then
      buildExternalRequesterJVal sessionId "cli" "sandboxed-mcp"
    else
      .obj #[("kind", .str "mission"), ("mission_id", .str cleanMid)]
  let newReq := JVal.obj #[
    ("id", .str reqId),
    ("requester_mission_id", if cleanMid.isEmpty then .null else .str cleanMid),
    ("mission_id", if cleanMid.isEmpty then .null else .str cleanMid),
    ("requester_title", match titleOpt with | some t => .str t | none => .null),
    ("requester", reqSubj),
    ("session_id", if sessionId.trimAscii.toString.isEmpty then .null else .str sessionId.trimAscii.toString),
    ("scope", .str cleanScope),
    ("target_host", .str cleanHost),
    ("allowed_unit", allowedUnitField),
    ("allowed_units", .arr (cleanUnits.map JVal.str)),
    ("session_scoped", .bool sessionScoped),
    ("ttl_minutes", JVal.nat clampedTtl),
    ("reason", .str reason),
    ("state", .str "pending"),
    ("status", .str "pending"),
    ("created_at", .str nowIso),
    ("decided_at", .null),
    ("expires_at", .null),
    ("revoked_at", .null)
  ]
  let audits := (doc.fieldArr? "audit").getD #[]
  let auditEntry := JVal.obj #[
    ("at", .str nowIso),
    ("request_id", .str reqId),
    ("requester_mission_id", if cleanMid.isEmpty then .null else .str cleanMid),
    ("requester", reqSubj),
    ("target_host", .str cleanHost),
    ("scope", .str cleanScope),
    ("action", .str "requested"),
    ("detail", if reason.isEmpty then .null else .str reason)
  ]
  let nextDoc := (doc.setField "requests" (.arr (reqs.push newReq))).setField "audit" (.arr (#[auditEntry] ++ audits))
  discard <| writeDataJsonObj dataRoot "privilege_access.json" nextDoc
  return .obj #[
    ("status", .str "pending"),
    ("state", .str "pending"),
    ("request_id", .str reqId),
    ("id", .str reqId),
    ("scope", .str cleanScope),
    ("target_host", .str cleanHost),
    ("allowed_unit", allowedUnitField),
    ("session_scoped", .bool sessionScoped),
    ("ttl_minutes", JVal.nat clampedTtl)
  ]

def mcpListPrivilegedAccess (st : CoreStore) (dataRoot missionId : String) (nowEpochSec : UInt64)
    (sessionId : String := "") (includeLeaseTokensForOwner : Bool := false) : IO JVal := do
  let nowIso := formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "privilege_access.json"
  let sql :=
    if missionId.isEmpty then
      "SELECT grant_id, mission_id, target_host, scope, allowed_units_json, revoked, expires_at_epoch, lease_token FROM privilege_leases ORDER BY expires_at_epoch DESC LIMIT 100;"
    else
      "SELECT grant_id, mission_id, target_host, scope, allowed_units_json, revoked, expires_at_epoch, lease_token FROM privilege_leases WHERE mission_id=?1 ORDER BY expires_at_epoch DESC LIMIT 100;"
  let args := if missionId.isEmpty then #[] else #[missionId]
  let mut grants : Array JVal := #[]
  let mut leaseLookup : Array (String × Bool × UInt64) := #[]
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
      let ltok := (r[7]?).getD ""
      leaseLookup := leaseLookup.push (gid, rev, exp)
      let baseFields : Array (String × JVal) := #[
        ("id", .str gid),
        ("grant_id", .str gid),
        ("mission_id", .str mid),
        ("target_host", .str th),
        ("scope", .str sc),
        ("allowed_units", units),
        ("revoked", .bool rev),
        ("active", .bool (!rev && nowEpochSec < exp)),
        ("expires_at", .str (formatEpochIso8601Utc exp)),
        ("expires_at_epoch", JVal.uint64 exp)
      ]
      let grantFields :=
        if includeLeaseTokensForOwner && !rev && nowEpochSec < exp && !ltok.isEmpty then
          baseFields.push ("lease_token", .str ltok)
        else
          baseFields
      grants := grants.push (.obj grantFields)
  let rawReqs := ((doc.fieldArr? "requests").getD #[]).filter (fun r =>
    if !missionId.isEmpty then
      ((r.fieldStr? "requester_mission_id").orElse (fun _ => r.fieldStr? "mission_id") |>.getD "") == missionId
    else if includeLeaseTokensForOwner && !sessionId.isEmpty then
      let rMid := (r.fieldStr? "requester_mission_id").orElse (fun _ => r.fieldStr? "mission_id") |>.getD ""
      let rSid := (r.fieldStr? "session_id").getD ""
      rMid.isEmpty && (rSid.isEmpty || rSid == sessionId)
    else
      true)
  let normReqs := (rawReqs.map (fun r => normalizePrivilegeRequestJVal r leaseLookup nowEpochSec nowIso)).reverse
  let auditArr := (doc.fieldArr? "audit").getD #[]
  let cmdAuditArr := (doc.fieldArr? "command_audit").getD #[]
  let incidentsArr := (doc.fieldArr? "bunker_incidents").getD #[]
  return .obj #[
    ("requests", .arr normReqs),
    ("grants", .arr grants),
    ("audit", .arr auditArr),
    ("command_audit", .arr cmdAuditArr),
    ("bunker_incidents", .arr incidentsArr)
  ]

def mcpRevokePrivilegedAccess (st : CoreStore) (dataRoot : String) (idOrGrantId missionId : String)
    (nowEpochSec : UInt64 := 0) : IO (Option JVal) := do
  let nowIso := if nowEpochSec == 0 then "revoked" else formatEpochIso8601Utc nowEpochSec
  let doc ← readDataJsonObj dataRoot "privilege_access.json"
  let reqs := (doc.fieldArr? "requests").getD #[]
  let matchedReq? := reqs.find? (fun r =>
    (r.fieldStr? "id").getD "" == idOrGrantId || (r.fieldStr? "grant_id").getD "" == idOrGrantId)
  let gid :=
    match matchedReq?.bind (·.fieldStr? "grant_id") with
    | some g => if g.isEmpty then idOrGrantId else g
    | none => idOrGrantId
  let _ ←
    if missionId.isEmpty then
      execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1 WHERE grant_id=?1;" #[gid]
    else
      execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1 WHERE grant_id=?1 AND mission_id=?2;" #[gid, missionId]
  let mut revokedOut? : Option JVal := none
  let mut nextReqs : Array JVal := #[]
  for r in reqs do
    if (r.fieldStr? "id").getD "" == idOrGrantId || (!gid.isEmpty && (r.fieldStr? "grant_id").getD "" == gid) then
      let upd := r
        |>.setField "state" (.str "revoked")
        |>.setField "status" (.str "revoked")
        |>.setField "revoked_at" (.str nowIso)
      let norm := normalizePrivilegeRequestJVal upd #[(gid, true, 0)] nowEpochSec nowIso
      revokedOut? := some norm
      nextReqs := nextReqs.push norm
    else nextReqs := nextReqs.push r
  if revokedOut?.isSome then
    discard <| writeDataJsonObj dataRoot "privilege_access.json" (doc.setField "requests" (.arr nextReqs))
  return revokedOut?

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
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let cMethod := (jv.fieldStr? "method").getD "POST"
      let cPath := (jv.fieldStr? "path").getD ""
      let rawSummary := ((jv.fieldStr? "summary").getD "Approve").replace "\n" " " |>.trimAscii.toString
      let cSummary := if rawSummary.isEmpty then "Approve" else rawSummary
      let cBodyHash :=
        match jv.fieldStr? "body_sha256" with
        | some h => h
        | none => bytesToHexLower (sha256Bytes ((jv.fieldStr? "body").getD "").toUTF8)
      let expAt := nowEpochSec + 120
      let payloadStr := s!"paloma-approval-v1\n{nonce}\n{cMethod} {cPath}\n{cBodyHash}\n{expAt}\n{cSummary}"
      return okJson 200 (renderCompact (.obj #[
        ("challenge", .str nonce),
        ("challenge_id", .str nonce),
        ("payload", .str payloadStr),
        ("expires_at", JVal.uint64 expAt)
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
      let pSummary ← mcpListPrivilegedAccess st dataRoot "" nowEpochSec
      let secPendingRaw := ((broker.fieldArr? "requests").getD #[]).filter (fun r =>
        ((r.fieldStr? "status").orElse (fun _ => r.fieldStr? "state") |>.getD "") == "pending")
      let maPendingRaw := ((mAcc.fieldArr? "requests").getD #[]).filter (fun r =>
        ((r.fieldStr? "state").orElse (fun _ => r.fieldStr? "status") |>.getD "") == "pending")
      let paPendingNorm := ((pSummary.fieldArr? "requests").getD #[]).filter (fun r =>
        (r.fieldStr? "state").getD "" == "pending")
      let secItems := secPendingRaw.map buildSecretApprovalItem
      let maItems := maPendingRaw.map (fun r => buildMissionAccessApprovalItem r nowIso)
      let paItems := paPendingNorm.map buildPrivilegeApprovalItem
      let items := paItems ++ secItems ++ maItems
      return okJson 200 (renderCompact (.obj #[
        ("items", .arr items),
        ("mode", .str mode)
      ]))
    if method == "POST" && cleanPath == "/api/approvals/approve-all" then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return okJson 400 "{\"error\":\"invalid_json\"}"
      let batchItems := (jv.fieldArr? "items").getD #[]
      let confirmCrit := (jv.fieldBool? "confirm_critical").getD false
      if batchItems.size > 20 then
        return okJson 400 "{\"error\":\"batch_too_large\"}"
      -- Validate every item in the batch before mutating (`orb_verify_approval` atomic batch rule)
      let broker ← readDataJsonObj dataRoot "secret_broker.json"
      let mAcc ← readDataJsonObj dataRoot "mission_access.json"
      let pSummary ← mcpListPrivilegedAccess st dataRoot "" nowEpochSec
      let secPending := ((broker.fieldArr? "requests").getD #[]).filter (fun r =>
        ((r.fieldStr? "status").orElse (fun _ => r.fieldStr? "state") |>.getD "") == "pending") |>.map buildSecretApprovalItem
      let maPending := ((mAcc.fieldArr? "requests").getD #[]).filter (fun r =>
        ((r.fieldStr? "state").orElse (fun _ => r.fieldStr? "status") |>.getD "") == "pending") |>.map (fun r => buildMissionAccessApprovalItem r nowIso)
      let paPending := ((pSummary.fieldArr? "requests").getD #[]).filter (fun r =>
        (r.fieldStr? "state").getD "" == "pending") |>.map buildPrivilegeApprovalItem
      let allLive := paPending ++ secPending ++ maPending
      for bi in batchItems do
        let bKind := (bi.fieldStr? "kind").getD ""
        let bId := (bi.fieldStr? "id").getD ""
        let bDigest := (bi.fieldStr? "digest").getD ""
        let some liveItem := allLive.find? (fun x => (x.fieldStr? "kind").getD "" == bKind && (x.fieldStr? "id").getD "" == bId)
          | return okJson 409 s!"\{\"error\":\"approval_not_pending\",\"id\":{jsonEscape bId}}"
        let liveDigest := (liveItem.fieldStr? "digest").getD ""
        if !bDigest.isEmpty && bDigest != liveDigest then
          return okJson 409 s!"\{\"error\":\"approval_digest_mismatch\",\"id\":{jsonEscape bId}}"
        let liveRisk := (liveItem.fieldStr? "risk").getD "routine"
        if liveRisk == "critical" && !confirmCrit then
          return okJson 400 s!"\{\"error\":\"critical_confirmation_required\",\"id\":{jsonEscape bId}}"
      let mut approvedCnt : Nat := 0
      for bi in batchItems do
        let bKind := (bi.fieldStr? "kind").getD ""
        let bId := (bi.fieldStr? "id").getD ""
        if bKind == "privilege" then
          if let .ok _ ← approveSinglePrivilegeRequest st dataRoot bId none none nowEpochSec nowIso then
            approvedCnt := approvedCnt + 1
        else if bKind == "secret" then
          let curBroker ← readDataJsonObj dataRoot "secret_broker.json"
          let curReqs := (curBroker.fieldArr? "requests").getD #[]
          if let some targetReq := curReqs.find? (fun r => (r.fieldStr? "id").getD "" == bId) then
            let curGrants := (curBroker.fieldArr? "grants").getD #[]
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
            let nextReqs := curReqs.map fun r =>
              if (r.fieldStr? "id").getD "" == bId then
                ((r.removeField "encrypted_value").setField "status" (.str "approved")).setField "decided_at" (.str nowIso)
              else r
            discard <| writeDataJsonObj dataRoot "secret_broker.json"
              ((curBroker.setField "requests" (.arr nextReqs)).setField "grants" (.arr (curGrants.push newGrant)))
            approvedCnt := approvedCnt + 1
        else if bKind == "mission_access" then
          let curDoc ← readDataJsonObj dataRoot "mission_access.json"
          let curReqs := (curDoc.fieldArr? "requests").getD #[]
          let curGrants := (curDoc.fieldArr? "grants").getD #[]
          if let some r := curReqs.find? (fun x => (x.fieldStr? "id").getD "" == bId) then
            let ttlH := (r.fieldNat? "ttl_hours").getD 24
            let expEp := nowEpochSec + (ttlH * 3600).toUInt64
            let expIso := formatEpochIso8601Utc expEp
            let gid ← newUuidV4
            let grant := JVal.obj #[
              ("id", .str gid),
              ("requester_mission_id", r.fieldOrNull "requester_mission_id"),
              ("target_mission_id", r.fieldOrNull "target_mission_id"),
              ("scope", .str ((r.fieldStr? "scope").getD "read")),
              ("created_at", .str nowIso),
              ("expires_at", .str expIso),
              ("expires_at_epoch", JVal.uint64 expEp)
            ]
            let nextReqs := curReqs.map fun x =>
              if (x.fieldStr? "id").getD "" == bId then
                x
                  |>.setField "state" (.str "approved")
                  |>.setField "status" (.str "approved")
                  |>.setField "decided_at" (.str nowIso)
                  |>.setField "expires_at" (.str expIso)
              else x
            discard <| writeDataJsonObj dataRoot "mission_access.json"
              ((curDoc.setField "requests" (.arr nextReqs)).setField "grants" (.arr (curGrants.push grant)))
            approvedCnt := approvedCnt + 1
      return okJson 200 (renderCompact (.obj #[("ok", .bool true), ("approved", JVal.nat approvedCnt)]))
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
      let bwObj := (((settings.field? "bitwarden").getD (.obj #[])).removeField "access_token").setField
        "encrypted_access_token" (.str enc)
      if let .error e ← writeSettingsJson dataRoot (settings.setField "bitwarden" bwObj) (some settings) then
        return okJson (OrbCore.SettingsFile.errorStatus e) s!"\{\"error\":{jsonEscape e}}"
      return okJson 200 "{\"ok\":true,\"configured\":true}"
    if method == "DELETE" && cleanPath == "/api/bitwarden/config" then
      -- Disconnecting removes the token only; default project access stays for the next token.
      let settings ← readSettingsJson dataRoot
      let bwObj := (((settings.field? "bitwarden").getD (.obj #[])).removeField "access_token").removeField
        "encrypted_access_token"
      if let .error e ← writeSettingsJson dataRoot ((settings.setField "bitwarden" bwObj).removeField "bws_access_token") (some settings) then
        return okJson (OrbCore.SettingsFile.errorStatus e) s!"\{\"error\":{jsonEscape e}}"
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
      let settings ← readSettingsJson dataRoot
      let bwObj := (settings.field? "bitwarden").getD (.obj #[])
      let da := ((bwObj.field? "default_access").getD (.obj #[])).setField slug (.arr bwProjs)
      if let .error e ← writeSettingsJson dataRoot (settings.setField "bitwarden" (bwObj.setField "default_access" da)) (some settings) then
        return okJson (OrbCore.SettingsFile.errorStatus e) s!"\{\"error\":{jsonEscape e}}"
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
    let audit := (doc.fieldArr? "audit").getD #[]
    if method == "GET" && cleanPath == "/api/mission-access" then
      let normReqs := (reqs.map (fun r => normalizeMissionAccessRequestJVal r nowIso)).reverse
      return okJson 200 (renderCompact (.obj #[
        ("requests", .arr normReqs),
        ("grants", .arr grants),
        ("audit", .arr audit)
      ]))
    if method == "POST" && cleanPath.startsWith "/api/mission-access/" && cleanPath.endsWith "/approve" then
      let rawMid := ((cleanPath.drop 20).dropEnd 8).toString
      let reqId := if rawMid.startsWith "requests/" then (rawMid.drop 9).toString else rawMid
      let bodyJv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let some r := reqs.find? (fun x => (x.fieldStr? "id").getD "" == reqId)
        | return okJson 404 "{\"error\":\"request_not_found\"}"
      let ttlH := (bodyJv.fieldNat? "ttl_hours").getD ((r.fieldNat? "ttl_hours").getD 24)
      let expEp := nowEpochSec + (ttlH * 3600).toUInt64
      let expIso := formatEpochIso8601Utc expEp
      let gid ← newUuidV4
      let grant := JVal.obj #[
        ("id", .str gid),
        ("requester_mission_id", r.fieldOrNull "requester_mission_id"),
        ("target_mission_id", r.fieldOrNull "target_mission_id"),
        ("scope", .str ((r.fieldStr? "scope").getD "read")),
        ("created_at", .str nowIso),
        ("expires_at", .str expIso),
        ("expires_at_epoch", JVal.uint64 expEp)
      ]
      let mut approvedReq : JVal := .obj #[]
      let mut nextReqs : Array JVal := #[]
      for x in reqs do
        if (x.fieldStr? "id").getD "" == reqId then
          let upd := x
            |>.setField "state" (.str "approved")
            |>.setField "status" (.str "approved")
            |>.setField "ttl_hours" (JVal.nat ttlH)
            |>.setField "decided_at" (.str nowIso)
            |>.setField "expires_at" (.str expIso)
          approvedReq := upd
          nextReqs := nextReqs.push upd
        else nextReqs := nextReqs.push x
      discard <| writeDataJsonObj dataRoot "mission_access.json"
        ((doc.setField "requests" (.arr nextReqs)).setField "grants" (.arr (grants.push grant)))
      return okJson 200 (renderCompact ((approvedReq.setField "ok" (.bool true)).setField "grant" grant))
    if method == "POST" && cleanPath.startsWith "/api/mission-access/" &&
       (cleanPath.endsWith "/deny" || cleanPath.endsWith "/reject") then
      let stripped :=
        if cleanPath.endsWith "/deny" then ((cleanPath.drop 20).dropEnd 5).toString
        else ((cleanPath.drop 20).dropEnd 7).toString
      let reqId := if stripped.startsWith "requests/" then (stripped.drop 9).toString else stripped
      let mut deniedReq? : Option JVal := none
      let mut nextReqs : Array JVal := #[]
      for x in reqs do
        if (x.fieldStr? "id").getD "" == reqId then
          let upd := x
            |>.setField "state" (.str "denied")
            |>.setField "status" (.str "denied")
            |>.setField "decided_at" (.str nowIso)
          deniedReq? := some upd
          nextReqs := nextReqs.push upd
        else nextReqs := nextReqs.push x
      discard <| writeDataJsonObj dataRoot "mission_access.json" (doc.setField "requests" (.arr nextReqs))
      return okJson 200 (renderCompact ((deniedReq?.getD (.obj #[])).setField "ok" (.bool true)))
    if method == "DELETE" && cleanPath.startsWith "/api/mission-access/" then
      let rawId := (cleanPath.drop 20).toString
      let gid := if rawId.startsWith "grants/" then (rawId.drop 7).toString else rawId
      let nextGrants := grants.map fun g =>
        if (g.fieldStr? "id").getD "" == gid then g.setField "revoked_at" (.str nowIso) else g
      let nextReqs := reqs.map fun x =>
        if (x.fieldStr? "id").getD "" == gid then
          x
            |>.setField "state" (.str "revoked")
            |>.setField "status" (.str "revoked")
            |>.setField "revoked_at" (.str nowIso)
        else x
      discard <| writeDataJsonObj dataRoot "mission_access.json"
        ((doc.setField "grants" (.arr nextGrants)).setField "requests" (.arr nextReqs))
      return okJson 200 "{\"ok\":true}"

  -- 5. `/api/privilege-access*` (excluding `/api/privilege-access/verify-and-log` which is handled earlier in `Control.lean`)
  if cleanPath == "/api/privilege-access" || cleanPath.startsWith "/api/privilege-access/" then
    if !isAdmin then
      return okJson 403 "{\"error\":\"admin_required\"}"
    if method == "GET" && cleanPath == "/api/privilege-access" then
      let summary ← mcpListPrivilegedAccess st dataRoot "" nowEpochSec
      let memBunker ← match bunkerRef? with | some r => r.get | none => pure (0 : UInt8)
      let diskBunker ← readPersistedBunkerState st
      let bState := if memBunker > diskBunker then memBunker else diskBunker
      return okJson 200 (renderCompact (summary.setField "bunker_state" (JVal.nat bState.toNat)))
    if method == "POST" && cleanPath == "/api/privilege-access/request" then
      let .ok jv := OrbBin.Json.parseBytes bodyBytes
        | return okJson 400 "{\"error\":\"invalid_json\"}"
      let mid := ((jv.fieldStr? "requester_mission_id").orElse (fun _ => jv.fieldStr? "mission_id") |>.getD "")
      let sc := (jv.fieldStr? "scope").getD "ops_read"
      let th := (jv.fieldStr? "target_host").getD "self"
      let rsn := (jv.fieldStr? "reason").getD ""
      let units := extractAllowedUnitsFromRequest jv
      let ttl := (jv.fieldNat? "ttl_minutes").getD 30
      let sessScoped := (jv.fieldBool? "session_scoped").getD true
      let res ← mcpRequestPrivilegedAccess (some st) dataRoot mid "" sc th rsn units ttl nowEpochSec sessScoped
      return okJson 200 (renderCompact res)
    if method == "POST" && cleanPath == "/api/privilege-access/revoke-all" then
      discard <| execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1;" #[]
      let doc ← readDataJsonObj dataRoot "privilege_access.json"
      let reqs := ((doc.fieldArr? "requests").getD #[]).map fun x =>
        let curSt := ((x.fieldStr? "state").orElse (fun _ => x.fieldStr? "status") |>.getD "")
        if curSt == "approved" then
          x.setField "state" (.str "revoked") |>.setField "status" (.str "revoked") |>.setField "revoked_at" (.str nowIso)
        else x
      discard <| writeDataJsonObj dataRoot "privilege_access.json" (doc.setField "requests" (.arr reqs))
      return okJson 200 "{\"ok\":true}"
    if method == "POST" && cleanPath == "/api/privilege-access/bunker" then
      let jv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let nextSt : UInt8 := ((jv.fieldNat? "level").orElse (fun _ => jv.fieldNat? "state") |>.getD 2).toUInt8
      if nextSt > 0 then
        discard <| execParamQuery st.missionsDb "UPDATE privilege_leases SET revoked=1;" #[]
      if let some r := bunkerRef? then
        r.set nextSt
      discard <| writePersistedBunkerState st nextSt
      return okJson 200 (renderCompact (.obj #[
        ("ok", .bool true),
        ("status", .str (if nextSt > 0 then "bunkered" else "ok")),
        ("bunker_state", JVal.nat nextSt.toNat)
      ]))
    if method == "POST" && cleanPath == "/api/privilege-access/unbunker" then
      if let some r := bunkerRef? then
        r.set 0
      discard <| writePersistedBunkerState st 0
      return okJson 200 (renderCompact (.obj #[
        ("ok", .bool true),
        ("status", .str "ok"),
        ("bunker_state", JVal.nat 0)
      ]))
    if method == "POST" && cleanPath.startsWith "/api/privilege-access/" && cleanPath.endsWith "/approve" then
      let rawMid := ((cleanPath.drop 22).dropEnd 8).toString
      let reqId := if rawMid.startsWith "requests/" then (rawMid.drop 9).toString else rawMid
      let isLegacyRoute := rawMid.startsWith "requests/"
      let bodyJv := (OrbBin.Json.parseBytes bodyBytes).toOption.getD (.obj #[])
      let ttlOver := bodyJv.fieldNat? "ttl_minutes"
      let sessOver := bodyJv.fieldBool? "session_scoped"
      match ← approveSinglePrivilegeRequest st dataRoot reqId ttlOver sessOver nowEpochSec nowIso with
      | .error (errCode, errJson) => return okJson errCode errJson
      | .ok (approvedNorm, gid, leaseTok, expEpoch) =>
        let respObj := approvedNorm
          |>.setField "ok" (.bool true)
          |>.setField "grant_id" (.str gid)
          |>.setField "expires_at_epoch" (JVal.uint64 expEpoch)
        let finalObj :=
          if isLegacyRoute then respObj.setField "lease_token" (.str leaseTok) else respObj
        return okJson 200 (renderCompact finalObj)
    if method == "POST" && cleanPath.startsWith "/api/privilege-access/" &&
       (cleanPath.endsWith "/deny" || cleanPath.endsWith "/reject") then
      let stripped :=
        if cleanPath.endsWith "/deny" then ((cleanPath.drop 22).dropEnd 5).toString
        else ((cleanPath.drop 22).dropEnd 7).toString
      let reqId := if stripped.startsWith "requests/" then (stripped.drop 9).toString else stripped
      let doc ← readDataJsonObj dataRoot "privilege_access.json"
      let reqs := (doc.fieldArr? "requests").getD #[]
      if !(reqs.any (fun x => (x.fieldStr? "id").getD "" == reqId)) then
        return okJson 404 "{\"error\":\"request_not_found\"}"
      let mut deniedOut : JVal := .obj #[]
      let mut nextReqs : Array JVal := #[]
      for x in reqs do
        if (x.fieldStr? "id").getD "" == reqId then
          let upd := x
            |>.setField "state" (.str "denied")
            |>.setField "status" (.str "denied")
            |>.setField "decided_at" (.str nowIso)
          let norm := normalizePrivilegeRequestJVal upd #[] nowEpochSec nowIso
          deniedOut := norm
          nextReqs := nextReqs.push norm
        else nextReqs := nextReqs.push x
      let audits := (doc.fieldArr? "audit").getD #[]
      let mid := (deniedOut.fieldStr? "requester_mission_id").getD ""
      let auditEntry := JVal.obj #[
        ("at", .str nowIso),
        ("request_id", .str reqId),
        ("requester_mission_id", if mid.isEmpty then .null else .str mid),
        ("requester", deniedOut.fieldOrNull "requester"),
        ("target_host", .str ((deniedOut.fieldStr? "target_host").getD "self")),
        ("scope", .str ((deniedOut.fieldStr? "scope").getD "ops_read")),
        ("action", .str "denied"),
        ("detail", .null)
      ]
      discard <| writeDataJsonObj dataRoot "privilege_access.json"
        ((doc.setField "requests" (.arr nextReqs)).setField "audit" (.arr (#[auditEntry] ++ audits)))
      return okJson 200 (renderCompact (deniedOut.setField "ok" (.bool true)))
    if method == "DELETE" && cleanPath.startsWith "/api/privilege-access/" then
      let rawId := (cleanPath.drop 22).toString
      let targetId := if rawId.startsWith "grants/" then (rawId.drop 7).toString else rawId
      match ← mcpRevokePrivilegedAccess st dataRoot targetId "" nowEpochSec with
      | some revObj => return okJson 200 (renderCompact (revObj.setField "ok" (.bool true)))
      | none => return okJson 200 "{\"ok\":true}"

  return none

end OrbCore.SecretAndApproval
