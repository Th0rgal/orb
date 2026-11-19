import OrbCore.Control
import OrbBin.SandboxedMcpMain

namespace OrbCore.R16aSecretTests

open OrbBin.Json OrbBin.SandboxedMcp OrbBin.PosixExt LeanSys.Posix
open OrbCore.Control OrbCore.Managed OrbCore.Store OrbCore.MemoryAndCloud

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"R16a secret delivery: {label}")

private def sql (db : SqliteDb) (query : String) (args : Array String := #[]) : IO Unit := do
  let .ok _ ← execParamQuery db query args | throw (IO.userError "R16a secret fixture SQL")

/-- The real broker calls a fixture-only BWS CLI. Count metadata reads as well as
    value fetches, since even `secret list` can return values upstream. -/
private def withFakeVault (root : System.FilePath) (run : IO Unit) : IO Unit := do
  let bin := root / "bin"
  IO.FS.createDirAll bin
  let bws := bin / "bws"
  IO.FS.writeFile bws ("#!/bin/sh\n" ++
    "[ \"$BWS_ACCESS_TOKEN\" = 'r16a-inert-vault-input' ] || exit 71\n" ++
    "printf '%s\\n' \"$1 $2 $3\" >> \"${0%/*}/vault.calls\"\n" ++
    "case \"$1 $2\" in\n" ++
    " 'project list') printf '%s' '[{\"id\":\"synthetic\",\"name\":\"synthetic-vault\"}]';;\n" ++
    " 'secret list') printf '%s' '[{\"id\":\"allow\",\"key\":\"GH_TOKEN\",\"projectId\":\"synthetic\"},{\"id\":\"reserved\",\"key\":\"BOAT_API_KEY\",\"projectId\":\"synthetic\"},{\"id\":\"host\",\"key\":\"R16A_HOST_ONLY\",\"projectId\":\"synthetic\"}]';;\n" ++
    " 'secret get') printf '%s' '{\"value\":\"r16a-inert-marker\"}';;\n" ++
    " *) exit 72;;\nesac\n")
  check ((← OrbBin.PosixExt.chmod bws.toString 0o700) == 0) "fake BWS executable"
  let vars := #["PATH", "BWS_ACCESS_TOKEN"]
  let prior ← vars.mapM fun key => do return (← IO.getEnv key)
  try
    OrbBin.PosixExt.setenvVar "PATH" bin.toString
    OrbBin.PosixExt.setenvVar "BWS_ACCESS_TOKEN" "r16a-inert-vault-input"
    run
  finally
    for (key, value) in vars.zip prior do
      match value with
      | some v => OrbBin.PosixExt.setenvVar key v
      | none => OrbBin.PosixExt.unsetenvVar key

private def exercise (root : System.FilePath) (store : CoreStore) (mc : ManagedComputeStore) : IO Unit := do
  let now ← coreEpochSec
  let project := "synthetic-r16a"
  sql store.missionsDb "INSERT INTO users(id,username,password_hash,role) VALUES('fixture','fixture','inert','member');"
  let placements := #["bound", "inherited", "ledger", "alias", "automatic", "pending", "claim", "host"]
  for mid in placements do
    sql store.missionsDb "INSERT INTO missions(id,owner_user_id,project,working_directory) VALUES(?1,'fixture',?2,?3);"
      #[mid, project, root.toString]
  discard <| updateMissionBoundManagedNode store "bound" "managed-synthetic" (formatEpochIso8601Utc now)
  sql store.missionsDb "UPDATE missions SET tags='[\"btw-parent:bound\"]' WHERE id='inherited';"
  sql store.missionsDb "INSERT INTO remote_node_jobs(job_id,mission_id,node_id) VALUES('fixture-job','ledger','managed-synthetic');"
  sql store.missionsDb "UPDATE missions SET tags='[\"remote-node:synthetic\"]' WHERE id='alias';"
  sql store.missionsDb "UPDATE missions SET tags='[\"remote-node:auto-managed:boat:small\"]' WHERE id='automatic';"
  sql store.missionsDb "UPDATE missions SET placement_kind='managed_vm' WHERE id='pending';"
  sql mc.db "INSERT INTO managed_vm_claims(machine_id,reservation_id,phase_code,claim_boot,owner_mission) VALUES('claim-fixture',1,1,1,'claim');"
  let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 10 }
  let .ok _ ← provisionManagedMachine mc fleet {
    id := "synthetic", sandboxName := "synthetic-sandbox", ownerUserId := "fixture", ownerKind := "user", spentCents := 0
  } now | throw (IO.userError "R16a managed fixture")
  let st : CoreAppState := {
    cfg := { instanceName := "dev", jwtSecret := "r16a-inline-synthetic-signing-input", workingDir := root.toString },
    store, managedStore? := some mc, searchIdx? := none, managedRef := ← IO.mkRef fleet,
    chainsRef := ← IO.mkRef #[], proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1 }
  let requestId := "8e646d70-7777-4b2c-bdeb-2daa22440501"
  let brokerFile := System.FilePath.mk store.rootDir / "secret_broker.json"
  let seedApproval (name : String) : IO Unit :=
    IO.FS.writeFile brokerFile (renderCompact (.obj #[
      ("default_access", .obj #[(project, .arr #[.str "synthetic-vault"])]),
      ("requests", .arr #[.obj #[("id", .str requestId), ("status", .str "approved"),
        ("mission_id", .str "inherited"), ("requester_subject", .str "mission:inherited"), ("secret_name", .str name)]])]))
  seedApproval "R16A_HOST_ONLY"
  let .ok (listener, port) ← tcpListen "127.0.0.1" 0 8 | throw (IO.userError "R16a loopback listen")
  let stop ← IO.mkRef false
  let server ← IO.asTask (prio := .dedicated) do
    try
      while !(← stop.get) do
        if let .ok fd ← tcpAcceptPoll listener 100 then handleClientConn st fd
    finally discard <| closeFd listener
  try
    let url := s!"http://127.0.0.1:{port}"
    let mut clients : Array (String × McpClient) := #[]
    for mid in placements do
      let sessionId ← newUuidV4
      sql store.projectsDb "INSERT INTO mcp_sessions_v1(id,owner,mission_id,project_scope,project_scoped,expires_at,hard_expires_at,subject_kind) VALUES(?1,'fixture',?2,?3,1,?4,?4,'mission');"
        #[sessionId, mid, project, toString (now + 3600)]
      let token := mintScopedMcpToken st.cfg.jwtSecret {
        sessionId, missionId := mid, role := "executor", project, expiresAt := now + 3600, hardExpiresAt := now + 3600 }
      let .ok client ← McpClient.create url token none "executor" (some mid)
          (secretsDirOverride := some (root / "companions" / mid).toString)
        | throw (IO.userError "R16a companion create")
      clients := clients.push (mid, client)
    let findClient (mid : String) : IO McpClient := do
      let some (_, client) := clients.find? (·.1 == mid) | throw (IO.userError "R16a missing companion fixture")
      return client
    let call (c : McpClient) (name : String) : IO (JVal × JVal) := do
      let req := JVal.obj #[("jsonrpc", .str "2.0"), ("id", .nat 1), ("method", .str "tools/call"),
        ("params", .obj #[("name", .str "secret_get"), ("arguments", .obj #[("name", .str name)])])]
      let response ← c.handleRpc req (← IO.mkRef false)
      return (response, (response.fieldOrNull "result").fieldOrNull "structuredContent")
    let calls := root / "bin" / "vault.calls"
    for (mid, client) in clients do
      if mid == "host" then continue
      let (_, reserved) ← call client "BOAT_API_KEY"
      let (_, hostOnly) ← call client "R16A_HOST_ONLY"
      check (reserved.fieldStr? "status" == some "refused" && hostOnly.fieldStr? "status" == some "refused" &&
        !(← calls.pathExists)) s!"{mid}: reserved and non-allowlisted names refused before any vault access"
    let requester ← findClient "inherited"
    let sibling ← findClient "bound"
    let waitPath := s!"/api/mcp/requests/secret/{requestId}/wait?timeout_secs=0"
    let .ok waited ← requester.request waitPath none | throw (IO.userError "R16a own approval wait")
    check (waited.fieldStr? "status" == some "refused" && !(← calls.pathExists))
      "inherited placement is also enforced during approval wait before vault access"
    seedApproval "GH_TOKEN"
    let .ok other ← sibling.request waitPath none | throw (IO.userError "R16a sibling approval wait")
    check (other.fieldStr? "status" == some "not_found" && !(← calls.pathExists))
      "a sibling companion does not receive another mission's approved delivery"
    let (raw, delivered) ← call requester "GH_TOKEN"
    let dir ← requester.secretsDir
    let target := dir / "GH_TOKEN"
    let marker := "r16a-inert-marker"
    check (delivered.fieldStr? "status" == some "granted" && delivered.fieldStr? "path" == some target.toString &&
      !(renderCompact raw).contains marker && !(renderCompact raw).contains "secret_delivery")
      "permitted delivery is materialized and absent from both companion result views"
    let fileStat ← OrbBin.PosixExt.statPath target.toString
    let dirStat ← OrbBin.PosixExt.statPath dir.toString
    check ((fileStat.mode &&& 0o777) == 0o600 && (dirStat.mode &&& 0o777) == 0o700 &&
      (← IO.FS.readFile target) == marker) "requester's private file contains the inert value"
    check ((← IO.FS.readFile calls) == "project list --output\nsecret list --output\nsecret get allow\n")
      "one permitted fetch and no earlier vault calls"
    for (mid, client) in clients do
      if mid != "inherited" then
        let otherDir ← client.secretsDir
        check (!(← otherDir.pathExists)) "non-requesting companion received no file"
    let (_, host) ← call (← findClient "host") "R16A_HOST_ONLY"
    check (host.fieldStr? "status" == some "granted") "trusted host control permits the same non-allowlisted name"
  finally
    stop.set true
    IO.ofExcept server.get

def run : IO Unit := IO.FS.withTempDir fun root => do
  let .ok store ← openCoreStore (root / "core").toString | throw (IO.userError "R16a Core fixture store")
  try
    let .ok mc ← openManagedComputeStore (root / "managed.db").toString
      | throw (IO.userError "R16a managed fixture store")
    try withFakeVault root (exercise root store mc)
    finally closeManagedComputeStore mc
  finally closeCoreStore store

end OrbCore.R16aSecretTests
