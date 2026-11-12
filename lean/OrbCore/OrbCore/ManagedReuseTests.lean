import OrbCore.McpGateway
import OrbCore.ManagedReuse
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedReuseTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.ManagedProvider OrbCore.LegacyHydrate

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed reuse: {label}")

/-- `start_mission(auto-managed)` through the real dispatcher and spawn path,
    with a provider that counts what is actually rented. -/
def run (root : String) : IO Unit := do
  let .ok core ← openCoreStore s!"{root}/reuse-core" | throw (IO.userError "reuse core open failed")
  let .ok mc ← openManagedComputeStore s!"{root}/reuse-managed.db" | throw (IO.userError "reuse managed open failed")
  try
    let sqlCore (query : String) (args : Array String := #[]) : IO (Array (Array String)) := do
      match ← execParamQuery core.missionsDb query args with
      | .ok rows => pure rows
      | .error e => throw (IO.userError s!"managed reuse: core fixture: {e}")
    let sqlManaged (query : String) (args : Array String := #[]) : IO (Array (Array String)) := do
      match ← execParamQuery mc.db query args with
      | .ok rows => pure rows
      | .error e => throw (IO.userError s!"managed reuse: managed fixture: {e}")
    discard <| sqlCore "INSERT INTO missions(id,owner_user_id,project) VALUES('lead','','p'),('rival','','p');"
    discard <| sqlCore ("CREATE TABLE IF NOT EXISTS remote_node_jobs (job_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL DEFAULT '', " ++
      "node_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', payload_json TEXT NOT NULL DEFAULT '{}', " ++
      "created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '');")
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let rented ← IO.mkRef (0 : Nat)
    let provider : Provider := { template with
      spawn := fun spec => do
        rented.modify (· + 1)
        template.spawn spec
    }
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let .ok () ← saveManagedFleetConfig mc true true 20000 0 50 | throw (IO.userError "reuse fleet fixture failed")
    let cfg : OrbCore.ManagedProvisioning.BootstrapConfig := { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" }
    let now ← coreEpochSec
    let counter ← IO.mkRef (0 : Nat)
    -- Start one child; returns (child mission, machine id, reused).
    let start (caller : String) (size : String := "small") (extra : Array (String × JVal) := #[]) :
        IO (String × String × Bool) := do
      counter.modify (· + 1)
      let claims : OrbCore.MemoryAndCloud.McpSessionClaims := {
        sessionId := "reuse-session", missionId := caller, role := "executor", expiresAt := 99999999999
      }
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall core (some mc) none none fleet root claims "start_mission"
        (.obj (#[("title", JVal.str "child"), ("remote_node_id", .str s!"auto-managed:{size}"),
          ("managed_ttl_minutes", .nat 60), ("idempotency_key", .str s!"reuse-{← counter.get}")] ++ extra))
        now none (some (provider, cfg))
      let reply := (OrbBin.Json.parse raw).toOption.getD .null
      let result := (reply.field? "result").getD .null
      let some child := result.fieldStr? "mission_id" | throw (IO.userError s!"managed reuse: start failed: {raw}")
      let machineId := (((result.fieldStr? "remote_node_id").getD "").drop 8).toString
      -- Give the fixture machine a known lifetime and a fresh poll.
      if result.fieldBool? "managed_machine_reused" != some true then
        discard <| sqlManaged "UPDATE managed_machines SET expires_at_sec=?2,last_poll_sec=?3 WHERE id=?1;"
          #[machineId, s!"{now + 3600}", s!"{now}"]
      return (child, machineId, result.fieldBool? "managed_machine_reused" == some true)
    let finish (mission : String) (status : String := "completed") : IO Unit := do
      discard <| sqlCore "UPDATE missions SET status=?2 WHERE id=?1;" #[mission, status]
    let ownerOf (machineId : String) : IO String := do
      let some (m, _) ← getManagedMachine? mc machineId | throw (IO.userError "managed reuse: machine missing")
      return m.ownerMission
    -- Two live children each get their own machine.
    let (first, vmA, reusedA) ← start "lead"
    discard <| sqlCore "UPDATE missions SET status='active' WHERE id=?1;" #[first]
    let (second, vmB, reusedB) ← start "lead"
    discard <| sqlCore "UPDATE missions SET status='active' WHERE id=?1;" #[second]
    check (!reusedA && !reusedB && vmA != vmB && (← rented.get) == 2) "a live sibling's machine is never taken"
    -- Once the first child has ended, the next child takes its machine over.
    finish first
    let (third, vmThird, reusedThird) ← start "lead"
    check (reusedThird && vmThird == vmA && (← rented.get) == 2) "an ended sibling's idle machine is reused, nothing is rented"
    check ((← ownerOf vmA) == third) "the new child owns the reused machine"
    let some (reusedMachine, _) ← getManagedMachine? mc vmA | throw (IO.userError "managed reuse: machine missing")
    check (reusedMachine.requestedByMissionId == "lead" && reusedMachine.status == "ready") "requester and state are unchanged"
    -- The same machine is not handed out twice: its new owner is not ended.
    let (_, vmFourth, reusedFourth) ← start "lead"
    check (!reusedFourth && vmFourth != vmA && (← rented.get) == 3) "a machine just taken over is not offered again"
    -- Each remaining condition, one at a time, on the second child's machine.
    finish second "failed"
    let expectFresh (label : String) (caller : String := "lead") (size : String := "small")
        (extra : Array (String × JVal) := #[]) : IO Unit := do
      let before ← rented.get
      let (_, vm, reused) ← start caller size extra
      check (!reused && vm != vmB && (← rented.get) == before + 1 && (← ownerOf vmB) == second) label
    discard <| sqlCore "INSERT INTO remote_node_jobs(job_id,node_id,state) VALUES('job-b',?1,'running');" #[s!"managed-{vmB}"]
    expectFresh "a machine with an active job is not reused"
    discard <| sqlCore "UPDATE remote_node_jobs SET state='completed' WHERE job_id='job-b';"
    discard <| sqlManaged "UPDATE managed_machines SET expires_at_sec=?2 WHERE id=?1;" #[vmB, s!"{now + 600}"]
    expectFresh "a machine about to expire is not reused"
    discard <| sqlManaged "UPDATE managed_machines SET expires_at_sec=?2,last_poll_sec=?3 WHERE id=?1;"
      #[vmB, s!"{now + 3600}", s!"{now - 900}"]
    expectFresh "a machine that stopped polling is not reused"
    discard <| sqlManaged "UPDATE managed_machines SET last_poll_sec=?2,cordoned=1 WHERE id=?1;" #[vmB, s!"{now}"]
    expectFresh "a cordoned machine is not reused"
    discard <| sqlManaged "UPDATE managed_machines SET cordoned=0 WHERE id=?1;" #[vmB]
    expectFresh "another mission's children cannot take it" "rival"
    expectFresh "a different size is not a match" "lead" "large"
    discard <| sqlManaged "UPDATE managed_machines SET requested_by_mission_id=owner_mission WHERE id=?1;" #[vmB]
    expectFresh "a machine its owner spawned for itself is never taken"
    discard <| sqlManaged "UPDATE managed_machines SET requested_by_mission_id='lead' WHERE id=?1;" #[vmB]
    finish second "awaiting_user"
    expectFresh "a sibling that may still continue keeps its machine"
    finish second "cancelled"
    -- A claim that cannot be used is handed back.
    let request : OrbCore.ManagedReuse.Request := {
      provider := "boat", size := "small", parentMission := "lead", userId := "", project := "p", now
    }
    let some claimed ← OrbCore.ManagedReuse.claim core mc request "lead"
      | throw (IO.userError "managed reuse: eligible machine was not claimed")
    check (claimed.machine.id == vmB && claimed.previousOwner == second && (← ownerOf vmB) == "lead") "claim is recorded at once"
    check ((← OrbCore.ManagedReuse.claim core mc request "lead").isNone) "a second claim finds nothing"
    OrbCore.ManagedReuse.restore mc claimed
    check ((← ownerOf vmB) == second) "a failed start restores the previous owner"
    -- With every condition met again, it is reused.
    let before ← rented.get
    let (fifth, vmFifth, reusedFifth) ← start "lead"
    check (reusedFifth && vmFifth == vmB && (← rented.get) == before && (← ownerOf vmB) == fifth) "an eligible machine is reused"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

end OrbCore.ManagedReuseTests
