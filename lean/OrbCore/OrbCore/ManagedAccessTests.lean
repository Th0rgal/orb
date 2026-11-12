import OrbCore.McpGateway
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedAccessTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.MemoryAndCloud

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed access: {label}")

/-- Deterministic authorization tests through the real dispatcher. No provider,
    bootstrap, network, clock, or extension implementation is needed. -/
def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore s!"{root}/access-core"
    | throw (IO.userError "access core open failed")
  try
    let .ok mc ← openManagedComputeStore s!"{root}/access-managed.db"
      | throw (IO.userError "access managed open failed")
    try
      let now : UInt64 := 1000
      let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
      let seedMission (id parent user project : String) : IO Unit := do
        let .ok _ ← execParamQuery store.missionsDb
            "INSERT INTO missions(id,parent_mission_id,owner_user_id,project) VALUES(?1,?2,?3,?4);"
            #[id, parent, user, project]
          | throw (IO.userError "mission fixture failed")
      for (id, parent, user, project) in #[
          ("root", "", "alice", "p"), ("parent", "root", "alice", "p"),
          ("owner", "parent", "alice", "p"), ("child", "owner", "alice", "p"),
          ("grandchild", "child", "alice", "p"), ("sibling", "parent", "alice", "p"),
          ("unrelated", "", "alice", "p"), ("foreign", "owner", "bob", "p"),
          ("other-project", "owner", "alice", "q"),
          ("cross-tenant-leaf", "foreign", "alice", "p"),
          ("cross-project-leaf", "other-project", "alice", "p"),
          ("empty-owner", "", "", "p")] do
        seedMission id parent user project
      let machine : ManagedMachine := {
        id := "access-core-id", sandboxName := "access-worker", ownerMission := "owner",
        ownerUserId := "alice", ownerKind := "mission", spentCents := 0
      }
      let .ok _ ← provisionManagedMachine mc fleet machine now
        | throw (IO.userError "machine fixture failed")
      let .ok _ ← provisionManagedMachine mc fleet {
          machine with id := "user-core-id", ownerMission := "", ownerKind := "user"
        } now | throw (IO.userError "user machine fixture failed")
      let .ok _ ← provisionManagedMachine mc fleet {
          machine with id := "legacy-core-id", ownerUserId := ""
        } now | throw (IO.userError "legacy machine fixture failed")
      let .ok _ ← provisionManagedMachine mc fleet {
          machine with id := "unowned-core-id", ownerMission := "", ownerUserId := ""
        } now | throw (IO.userError "unowned machine fixture failed")
      let seedSession (id owner kind mission project expires hard revoked : String) : IO Unit := do
        let .ok _ ← execParamQuery store.projectsDb
            ("INSERT INTO mcp_sessions_v1(id,owner,subject_kind,mission_id,project_scope,expires_at,hard_expires_at,revoked) " ++
             "VALUES(?1,?2,?3,?4,?5,?6,?7,?8);")
            #[id, owner, kind, mission, project, expires, hard, revoked]
          | throw (IO.userError "session fixture failed")
      -- Mirrors external-session minting: authenticated principal in `owner`,
      -- no mission and no stored role; project_scoped is left at its default.
      for (id, user, kind, mission, project, expires, hard, revoked) in #[
          ("external", "alice", "external_session", "", "p", "2000", "3000", "0"),
          ("unconfined", "alice", "external_session", "", "", "2000", "3000", "0"),
          ("bob", "bob", "external_session", "", "p", "2000", "3000", "0"),
          ("q", "alice", "external_session", "", "q", "2000", "3000", "0"),
          ("revoked", "alice", "external_session", "", "p", "2000", "3000", "1"),
          ("expired", "alice", "external_session", "", "p", "1000", "3000", "0"),
          ("hard-expired", "alice", "external_session", "", "p", "2000", "1000", "0"),
          ("empty", "", "external_session", "", "p", "2000", "3000", "0"),
          ("mission-kind", "alice", "mission", "owner", "p", "2000", "3000", "0")] do
        seedSession id user kind mission project expires hard revoked
      let base : McpSessionClaims := {
        sessionId := "mission-session", missionId := "owner", role := "executor", expiresAt := 2000
      }
      let external : McpSessionClaims := {
        sessionId := "external", missionId := "", role := "executor",
        isExternal := true, expiresAt := 2000, hardExpiresAt := 3000
      }
      let operator : McpSessionClaims := {
        base with
        sessionId := "00000000-0000-4000-8000-000000000000"
        missionId := ""
        role := "operator"
      }
      -- Deliberately mismatch the mock provider's name. An authorized request
      -- reaches the lifecycle boundary and returns this stable sentinel BEFORE
      -- any extension implementation can run. Denials must return not_found.
      let mock := { OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat" with
        name := "authorization-probe"
      }
      let probe (claims : McpSessionClaims) (tool idKey id : String) (allowed : Bool)
          (authenticatedUserId : String := "") : IO Unit := do
        -- Every probe attempts a body identity spoof, including foreign-user
        -- and missing-principal cases. Only the trusted parameter may count.
        let args : JVal := .obj #[(idKey, .str id), ("ttl_minutes", .nat 5),
          ("role", .str "operator"), ("user_id", .str "alice"), ("owner_user_id", .str "alice"),
          ("authenticatedUserId", .str "alice"), ("authenticated_user_id", .str "alice")]
        let raw ← OrbCore.McpGateway.dispatchMcpToolCall store (some mc) none none fleet root claims
          tool args now none (some (mock, { coreUrl := "https://unused.invalid", script := "" })) authenticatedUserId
        let .ok result := OrbBin.Json.parse raw | throw (IO.userError "invalid gateway JSON")
        let err := (result.field? "error").getD .null
        check (result.fieldBool? "ok" == some false && err.fieldStr? "code" ==
          some (if allowed then "lifecycle_rejected" else "not_found")) s!"{tool}/{id}/{claims.sessionId}/{claims.missionId}"
        if allowed then
          check (err.fieldStr? "message" == some "managed_provider_mismatch") "reached lifecycle boundary"
      for tool in #["extend_managed_machine", "stop_managed_machine", "resume_managed_machine", "destroy_managed_machine"] do
        for (idKey, id) in #[("machine_id", machine.id), ("id", "managed-" ++ machine.id)] do
          for mid in #["root", "parent", "owner", "child", "grandchild"] do
            probe { base with missionId := mid } tool idKey id true
          probe external tool idKey id true
          probe { external with role := "coordinator" } tool idKey id true
          -- External minting currently forbids operator; even an operator claim
          -- must get exactly the same owner-scoped access, not a tenant bypass.
          probe { external with role := "operator" } tool idKey id true
          for mid in #["sibling", "unrelated", "foreign", "other-project", "cross-tenant-leaf", "cross-project-leaf", "empty-owner"] do
            for role in #["executor", "coordinator", "operator"] do
              probe { base with missionId := mid, role } tool idKey id false
          probe { base with project := "q" } tool idKey id false
          for sid in #["bob", "q", "revoked", "expired", "hard-expired", "empty", "missing", "mission-kind"] do
            probe { external with sessionId := sid, role := "operator" } tool idKey id false
          probe { external with missionId := "owner" } tool idKey id false
          probe { external with project := "q" } tool idKey id false
          probe operator tool idKey id true "alice"
          probe operator tool idKey id false "bob"
          probe operator tool idKey id false
          -- A trusted Core principal must not overwrite scoped/external identity
          -- or turn a non-synthetic claim into the Core operator fallback.
          probe { operator with sessionId := "arbitrary-scoped-session" } tool idKey id false "alice"
          probe { operator with project := "p" } tool idKey id false "alice"
          for role in #["executor", "coordinator"] do
            probe { operator with role } tool idKey id false "alice"
          probe { operator with missionId := "unrelated" } tool idKey id false "alice"
          probe { base with missionId := "foreign" } tool idKey id false "alice"
          probe { external with sessionId := "bob" } tool idKey id false "alice"
          probe { external with sessionId := "missing" } tool idKey id false "alice"
          probe external tool idKey id true "bob"
      for id in #["user-core-id", "managed-user-core-id", "legacy-core-id", "managed-legacy-core-id"] do
        probe operator "extend_managed_machine" "machine_id" id true "alice"
        probe operator "extend_managed_machine" "machine_id" id false "bob"
        probe operator "extend_managed_machine" "machine_id" id false
      probe operator "extend_managed_machine" "machine_id" "unowned-core-id" false "alice"
      probe { external with sessionId := "unconfined" } "extend_managed_machine" "machine_id" "managed-user-core-id" true
      probe external "extend_managed_machine" "machine_id" "user-core-id" false
      probe base "extend_managed_machine" "machine_id" "user-core-id" false
      probe base "extend_managed_machine" "machine_id" "managed-missing" false
      let some (unchanged, _) ← getManagedMachine? mc machine.id
        | throw (IO.userError "machine vanished")
      check (unchanged.ownerUserId == "alice" && unchanged.ownerMission == "owner" &&
        unchanged.ttlMinutes == machine.ttlMinutes && unchanged.status == "provisioning") "probes never mutate machine"
    finally
      closeManagedComputeStore mc
  finally
    closeCoreStore store

end OrbCore.ManagedAccessTests
