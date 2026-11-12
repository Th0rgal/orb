import OrbCore.McpGateway
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedSnapshotLifecycleTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.ManagedProvider OrbCore.LegacyHydrate
open OrbCore.ManagedSnapshotCatalog

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed snapshot lifecycle: {label}")

private def sameName (result : Except String String) (expected : Except String String) : Bool :=
  match result, expected with
  | .ok a, .ok b => a == b
  | .error a, .error b => a == b
  | _, _ => false

private def namingTests : IO Unit := do
  check (sameName (newName "Health Manager" "Warm Build v1" "a1b2") (.ok "orb-snap-health-manager-warm-build-v1-a1b2"))
    "the provider name carries project, label and suffix"
  check (sameName (newName "" "x" "a1b2") (.error "managed_snapshot_requires_project") &&
    sameName (newName "p" "  " "a1b2") (.error "managed_snapshot_name_required") &&
    sameName (newName "p" "x" "") (.error "managed_snapshot_suffix_invalid") &&
    sameName (newName "p" "x" "a-b") (.error "managed_snapshot_suffix_invalid")) "incomplete names are refused"
  let entry (name label status : String) : Entry := { name, label, project := "p", status, sizeBytes := none }
  let entries := #[entry "orb-snap-p-warm-aaaa" "warm" "ready", entry "orb-snap-p-old-bbbb" "old" "failed",
    entry "orb-snap-p-twin-cccc" "twin" "ready", entry "orb-snap-p-twin-dddd" "twin" "saving"]
  check (labelTaken entries "Warm" && labelTaken entries "twin" && !labelTaken entries "old" && !labelTaken entries "new")
    "a label is taken until its snapshot failed or is gone"
  check (sameName (resolveForDelete entries "old") (.ok "orb-snap-p-old-bbbb")) "a failed snapshot can be deleted by label"
  check (sameName (resolveForDelete entries "orb-snap-p-twin-dddd") (.ok "orb-snap-p-twin-dddd")) "an exact name disambiguates"
  check (sameName (resolveForDelete entries "twin") (.error "managed_snapshot_ambiguous:orb-snap-p-twin-cccc,orb-snap-p-twin-dddd"))
    "an ambiguous label deletes nothing"
  check (sameName (resolveForDelete entries "orb-snap-q-warm-aaaa") (.error "managed_snapshot_not_found_in_project") &&
    sameName (resolveForDelete entries "") (.error "managed_snapshot_name_required")) "names outside the project are not found"

/-- Save, list, delete and fork through the real dispatcher with a provider that
    records exactly what reaches it. -/
private def gatewayTests (root : String) : IO Unit := do
  let .ok core ← openCoreStore s!"{root}/snaplife-core" | throw (IO.userError "snapshot lifecycle core open failed")
  let .ok mc ← openManagedComputeStore s!"{root}/snaplife-managed.db"
    | throw (IO.userError "snapshot lifecycle managed open failed")
  try
    let .ok _ ← execParamQuery core.missionsDb
        "INSERT INTO missions(id,owner_user_id,project) VALUES('alpha-lead','','alpha'),('beta-lead','','beta'),('nowhere','','');" #[]
      | throw (IO.userError "snapshot lifecycle mission fixture failed")
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let .ok () ← saveManagedFleetConfig mc true true 20000 0 50 | throw (IO.userError "snapshot lifecycle fleet fixture failed")
    let now ← coreEpochSec
    let seed (id owner : String) (ready : Bool) : IO Unit := do
      let .ok _ ← provisionManagedMachine mc fleet {
          id, sandboxName := s!"orb-managed-{id}", provider := "boat", size := "small", ownerMission := owner,
          ownerKind := "mission", requestedByMissionId := owner, ttlMinutes := 30, spentCents := 5
        } now | throw (IO.userError "snapshot lifecycle machine fixture failed")
      let .ok _ ← bindManagedProviderId mc id s!"remote-{id}" 1 | throw (IO.userError "snapshot lifecycle bind failed")
      if ready then
        let .ok _ ← recordAuthenticatedManagedPoll mc id 1 now | throw (IO.userError "snapshot lifecycle poll failed")
    seed "alpha-vm" "alpha-lead" true
    seed "alpha-booting" "alpha-lead" false
    seed "nowhere-vm" "nowhere" true
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let inventory ← IO.mkRef (#[{ name := "orb-snap-beta-warm-zzzz", status := "ready" }] : Array Snapshot)
    let saved ← IO.mkRef (#[] : Array (String × String))
    let forks ← IO.mkRef (#[] : Array String)
    let spawns ← IO.mkRef (0 : Nat)
    let provider : Provider := { template with
      listSnapshots := do return .ok (← inventory.get)
      saveSnapshot := fun providerId name => do
        saved.modify (·.push (providerId, name))
        inventory.modify (·.push { name, status := "saving" })
        return .ok ()
      getSnapshot := fun name => do
        match (← inventory.get).find? (·.name == name) with
        | some snap => return .ok snap
        | none => return .error { code := "not_found", status := 404 }
      deleteSnapshot := fun name => do
        inventory.modify (·.filter (·.name != name))
        return .ok ()
      spawn := fun spec => do
        spawns.modify (· + 1)
        template.spawn spec
      fork := fun providerId spec => do
        forks.modify (·.push providerId)
        template.spawn spec
    }
    let cfg : OrbCore.ManagedProvisioning.BootstrapConfig := { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" }
    let call (mission tool : String) (args : Array (String × JVal)) : IO JVal := do
      let claims : OrbCore.MemoryAndCloud.McpSessionClaims := {
        sessionId := "snaplife-session", missionId := mission, role := "executor", expiresAt := 99999999999
      }
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall core (some mc) none none fleet root claims tool (.obj args)
        now none (some (provider, cfg))
      return (OrbBin.Json.parse raw).toOption.getD .null
    let errorOf (reply : JVal) : Option String × Option String :=
      let err := (reply.field? "error").getD .null
      (err.fieldStr? "code", err.fieldStr? "message")
    let resultOf (reply : JVal) : JVal := (reply.field? "result").getD .null
    let names : IO (Array String) := do return (← inventory.get).map (·.name)
    -- Save: the name is scoped to the caller's project and reaches the provider's machine id.
    let first ← call "alpha-lead" "snapshot_managed_machine" #[("machine_id", .str "managed-alpha-vm"), ("name", .str "Warm Build")]
    let name := ((resultOf first).fieldStr? "name").getD ""
    check (first.fieldBool? "ok" == some true && name.startsWith "orb-snap-alpha-warm-build-" &&
      (resultOf first).fieldStr? "label" == some "warm-build" && (resultOf first).fieldStr? "project" == some "alpha" &&
      (resultOf first).fieldStr? "status" == some "saving") s!"a snapshot is saved under the project: {renderCompact first}"
    check ((← saved.get) == #[("remote-alpha-vm", name)]) "the provider saves the machine's provider id under that name"
    -- Refusals save nothing.
    let again ← call "alpha-lead" "snapshot_managed_machine" #[("machine_id", .str "alpha-vm"), ("name", .str "warm build")]
    check (errorOf again == (some "snapshot_failed", some "managed_snapshot_label_exists")) "a label in use is refused"
    let unnamed ← call "alpha-lead" "snapshot_managed_machine" #[("machine_id", .str "alpha-vm")]
    check (errorOf unnamed == (some "snapshot_failed", some "managed_snapshot_name_required")) "a snapshot needs a name"
    let booting ← call "alpha-lead" "snapshot_managed_machine" #[("machine_id", .str "alpha-booting"), ("name", .str "early")]
    check (errorOf booting == (some "snapshot_failed", some "managed_machine_not_running")) "only a running machine is saved"
    let foreign ← call "beta-lead" "snapshot_managed_machine" #[("machine_id", .str "alpha-vm"), ("name", .str "steal")]
    check ((errorOf foreign).1 == some "not_found") "another lineage cannot snapshot the machine"
    let projectless ← call "nowhere" "snapshot_managed_machine" #[("machine_id", .str "nowhere-vm"), ("name", .str "x")]
    check (errorOf projectless == (some "snapshot_failed", some "managed_snapshot_requires_project")) "a snapshot needs a project"
    check ((← saved.get).size == 1) "refused requests never reach the provider"
    -- Listing shows each project its own.
    let listed (mission : String) : IO (Array String) := do
      let reply ← call mission "list_managed_snapshots" #[]
      return (((resultOf reply).fieldArr? "snapshots").getD #[]).filterMap (·.fieldStr? "name")
    check ((← listed "alpha-lead") == #[name] && (← listed "beta-lead") == #["orb-snap-beta-warm-zzzz"]) "listing is per project"
    -- Delete: only inside the caller's project, by label or by name.
    let wrongProject ← call "beta-lead" "delete_managed_snapshot" #[("name", .str name)]
    check ((errorOf wrongProject).1 == some "not_found" && (← names).contains name) "another project cannot delete it, even by exact name"
    let missing ← call "alpha-lead" "delete_managed_snapshot" #[("name", .str "warm")]
    check (errorOf missing == (some "not_found", some "managed_snapshot_not_found_in_project") &&
      (← names).contains "orb-snap-beta-warm-zzzz") "a label of another project is not found"
    let deleted ← call "alpha-lead" "delete_managed_snapshot" #[("name", .str "Warm Build")]
    check ((resultOf deleted).fieldStr? "deleted" == some name && (← names) == #["orb-snap-beta-warm-zzzz"])
      "the owning project deletes by label"
    let reuse ← call "alpha-lead" "snapshot_managed_machine" #[("machine_id", .str "alpha-vm"), ("name", .str "warm build")]
    check (reuse.fieldBool? "ok" == some true) "a deleted label can be used again"
    -- Fork: a real machine from the source's disk, owned by the caller.
    let forked ← call "alpha-lead" "fork_managed_machine" #[("machine_id", .str "managed-alpha-vm"), ("ttl_minutes", .nat 20)]
    let forkId := ((resultOf forked).fieldStr? "id").getD ""
    check (forked.fieldBool? "ok" == some true && !forkId.isEmpty && forkId != "alpha-vm" &&
      (resultOf forked).fieldStr? "forked_from" == some "alpha-vm") s!"a fork is a new machine: {renderCompact forked}"
    check ((← forks.get) == #["remote-alpha-vm"] && (← spawns.get) == 0) "the provider forks the source and rents nothing else"
    let some (forkMachine, forkSlice) ← getManagedMachine? mc forkId | throw (IO.userError "snapshot lifecycle: fork missing")
    check (forkMachine.ownerMission == "alpha-lead" && forkMachine.size == "small" && forkMachine.ttlMinutes == 20 &&
      forkMachine.status == "ready" && forkSlice.phaseCode == 1 && forkMachine.providerId != "remote-alpha-vm")
      "the fork is enrolled, owned by the caller and has its own provider identity"
    let foreignFork ← call "beta-lead" "fork_managed_machine" #[("machine_id", .str "alpha-vm")]
    let bootingFork ← call "alpha-lead" "fork_managed_machine" #[("machine_id", .str "alpha-booting")]
    check ((errorOf foreignFork).1 == some "not_found" &&
      errorOf bootingFork == (some "fork_rejected", some "managed_machine_not_running") && (← forks.get).size == 1)
      "an outsider or a machine that is not running forks nothing"
    let countRows : IO Nat := do
      let .ok rows ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_machines;" #[] | throw (IO.userError "count failed")
      return ((cell rows[1]! 0).toNat?).getD 0
    check ((← countRows) == 4) "a refused fork leaves no machine record"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

def run (root : String) : IO Unit := do
  namingTests
  gatewayTests root

end OrbCore.ManagedSnapshotLifecycleTests
