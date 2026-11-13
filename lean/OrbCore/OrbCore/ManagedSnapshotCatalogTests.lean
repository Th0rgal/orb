import OrbCore.RemoteFleetAndRelay
import OrbCore.McpGateway
import OrbCore.ManagedProvisioningTests

namespace OrbCore.ManagedSnapshotCatalogTests

open OrbCore.Managed OrbCore.ManagedProvider OrbCore.ManagedSnapshotCatalog OrbCore.Store
open OrbCore.RemoteFleetAndRelay OrbBin.Json

/-- Test-local comparison of resolution outcomes. -/
private instance : BEq (Except String String) where
  beq
    | .ok x, .ok y => x == y
    | .error x, .error y => x == y
    | _, _ => false

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed snapshots: {label}")

/-- Names below are the shapes observed in prod on 2026-11-12. No provider is contacted. -/
def run (root : String) : IO Unit := do
  check (slug "Health Manager!" == "health-manager" && slug "--x--" == "x" &&
    (slug "abcdefghijklmnopqrstuvwxyz0123").length == 24) "slug rule"
  let inventory : Array Snapshot := #[
    { name := "orb-snap-health-manager-ledger-hub-warm-v1-eevr", status := "ready", sizeBytes := some 10 },
    { name := "orb-snap-verity-core-wave8-r32-chainc-warm-tgrm", status := "ready" },
    { name := "orb-snap-default-tl-7e1aa81-warm-uxvr", status := "unknown" },
    { name := "orb-snap-assistant-turbo-lean-c-warm-aaaa", status := "ready" },
    { name := "orb-snap-assistant-turbo-lean-d-warm-bbbb", status := "saving" },
    { name := "orb-snap-verity-old-warm-cccc", status := "ready" },
    { name := "someone-elses-disk", status := "ready" }]
  let known := #["health-manager", "verity", "verity-core", "default", "assistant"]
  let registry : Array LegacyRecord := parseLegacyRegistry
    "[{\"name\":\"orb-snap-verity-old-warm-cccc\",\"label\":\"old-warm\",\"project\":\"verity\"},{\"bad\":1}]"
  let names (project : String) := (visible inventory registry known project).map (·.name)
  check (names "health-manager" == #["orb-snap-health-manager-ledger-hub-warm-v1-eevr"]) "project sees its own snapshot"
  check (names "verity-core" == #["orb-snap-verity-core-wave8-r32-chainc-warm-tgrm"] &&
    names "verity" == #["orb-snap-verity-old-warm-cccc"]) "longest project slug wins; registry decides when present"
  check ((names "assistant").size == 2 && (names "").isEmpty && (names "unrelated").isEmpty &&
    !(names "health-manager").contains "someone-elses-disk") "no project, no foreign names"
  let health := visible inventory registry known "health-manager"
  check (health[0]!.label == "ledger-hub-warm-v1" &&
    (visible inventory registry known "verity")[0]!.label == "old-warm") "label from name or registry"
  check (resolve health "ledger-hub-warm-v1" == .ok "orb-snap-health-manager-ledger-hub-warm-v1-eevr" &&
    resolve health "orb-snap-health-manager-ledger-hub-warm-v1-eevr" == .ok "orb-snap-health-manager-ledger-hub-warm-v1-eevr")
    "resolve by label or provider name"
  check (resolve health "orb-snap-verity-core-wave8-r32-chainc-warm-tgrm" == .error "managed_snapshot_not_found_in_project" &&
    resolve health "" == .error "managed_snapshot_name_required") "another project's snapshot is not resolvable"
  let assistant := visible inventory registry known "assistant"
  check (resolve assistant "turbo-lean-d-warm" == .error "managed_snapshot_not_ready" &&
    resolve assistant "turbo-lean-c-warm" == .ok "orb-snap-assistant-turbo-lean-c-warm-aaaa" &&
    resolve (visible inventory registry known "default") "tl-7e1aa81-warm" == .ok "orb-snap-default-tl-7e1aa81-warm-uxvr")
    "saving is refused; an unlabelled provider status is offered"
  let twins : Array Entry := #[
    { name := "orb-snap-p-warm-aaaa", label := "warm", project := "p", status := "ready", sizeBytes := none },
    { name := "orb-snap-p-warm-bbbb", label := "warm", project := "p", status := "ready", sizeBytes := none }]
  check (resolve twins "warm" == .error "managed_snapshot_ambiguous:orb-snap-p-warm-aaaa,orb-snap-p-warm-bbbb")
    "ambiguous label is an error, not a guess"

  -- End to end through the store-backed helpers and the shared spawn path.
  let .ok core ← openCoreStore s!"{root}/snapshot-core" | throw (IO.userError "core open failed")
  let .ok mc ← openManagedComputeStore s!"{root}/snapshot-managed.db" | throw (IO.userError "managed open failed")
  try
    let .ok _ ← execParamQuery core.missionsDb
        "INSERT INTO missions(id,owner_user_id,project) VALUES('snap-owner','','health-manager'),('other','','verity-core');" #[]
      | throw (IO.userError "mission fixture failed")
    let template := OrbCore.ManagedProvisioningTests.mockPolicyProvider mc "boat"
    let spawnedFrom ← IO.mkRef ""
    let provider : Provider := { template with
      listSnapshots := pure (.ok inventory)
      spawn := fun spec => do
        spawnedFrom.set spec.fromSnapshot
        template.spawn spec
    }
    let .ok entries ← projectSnapshotEntries core provider "health-manager" | throw (IO.userError "entries failed")
    check (entries.size == 1) "store-backed listing is project scoped"
    check ((← resolveProjectSnapshot core provider "" "ledger-hub-warm-v1") == .error "managed_snapshot_requires_project" &&
      (← resolveProjectSnapshot core provider "verity-core" "ledger-hub-warm-v1") == .error "managed_snapshot_not_found_in_project")
      "no project and wrong project both fail before any spawn"
    let failing : Provider := { provider with listSnapshots := pure (.error { code := "down", status := 503 }) }
    check (!(← projectSnapshotEntries core failing "health-manager").isOk) "a failed provider list is an error, not an empty list"
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true }
    let .ok () ← saveManagedFleetConfig mc true true 2000 0 20 | throw (IO.userError "fleet fixture failed")
    let machine : ManagedMachine := {
      id := "snap-core-id", sandboxName := "orb-managed-snap-core-id", provider := "boat", size := "small",
      ttlMinutes := 5, ownerMission := "snap-owner", ownerKind := "mission"
    }
    let cfg : OrbCore.ManagedProvisioning.BootstrapConfig := { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" }
    let args : JVal := .obj #[("from_snapshot", .str "ledger-hub-warm-v1")]
    let unresolved ← spawnConfiguredManagedWorker mc core.rootDir fleet machine args "k1" (some (provider, cfg))
    check (!unresolved.isOk && (← spawnedFrom.get).isEmpty) "an unresolved label never reaches the provider"
    let .ok name ← resolveProjectSnapshot core provider "health-manager" "ledger-hub-warm-v1"
      | throw (IO.userError "resolve failed")
    let .ok spawned ← spawnConfiguredManagedWorker mc core.rootDir fleet machine args "k2" (some (provider, cfg)) none name
      | throw (IO.userError "snapshot spawn failed")
    check ((← spawnedFrom.get) == "orb-snap-health-manager-ledger-hub-warm-v1-eevr" &&
      spawned.machine.image == "orb-snap-health-manager-ledger-hub-warm-v1-eevr" && spawned.machine.status == "ready")
      "spawn restores the resolved project snapshot"
    -- start_mission(auto-managed) rents through the same path and hands the machine to the child.
    let claims : OrbCore.MemoryAndCloud.McpSessionClaims := {
      sessionId := "snapshot-session", missionId := "snap-owner", role := "executor", expiresAt := 99999999999
    }
    let now ← coreEpochSec
    let call (args : JVal) : IO JVal := do
      let raw ← OrbCore.McpGateway.dispatchMcpToolCall core (some mc) none none fleet root claims
        "start_mission" args now none (some (provider, cfg))
      return (OrbBin.Json.parse raw).toOption.getD .null
    let countMachines : IO String := do
      let .ok rows ← execParamQuery mc.db "SELECT COUNT(*) FROM managed_machines;" #[] | throw (IO.userError "count failed")
      return cell rows[1]! 0
    let before ← countMachines
    let foreign ← call (.obj #[("title", .str "t"), ("remote_node_id", .str "auto-managed:small"),
      ("managed_from_snapshot", .str "wave8-r32-chainc-warm"), ("managed_ttl_minutes", .nat 5), ("idempotency_key", .str "sm-foreign")])
    let misplaced ← call (.obj #[("title", .str "t"), ("remote_node_id", .str "auto"),
      ("managed_from_snapshot", .str "ledger-hub-warm-v1"), ("idempotency_key", .str "sm-misplaced")])
    check (foreign.fieldBool? "ok" == some false && misplaced.fieldBool? "ok" == some false && (← countMachines) == before)
      "another project's snapshot, or a snapshot without auto-managed, rents nothing"
    spawnedFrom.set ""
    let started ← call (.obj #[("title", .str "warm child"), ("remote_node_id", .str "auto-managed:small"),
      ("managed_from_snapshot", .str "ledger-hub-warm-v1"), ("managed_ttl_minutes", .nat 5), ("idempotency_key", .str "sm-warm")])
    let result := (started.field? "result").getD .null
    let child := (result.fieldStr? "mission_id").getD ""
    let node := (result.fieldStr? "remote_node_id").getD ""
    check (started.fieldBool? "ok" == some true && !child.isEmpty && node.startsWith "managed-" &&
      (← spawnedFrom.get) == "orb-snap-health-manager-ledger-hub-warm-v1-eevr") "start_mission restores the project snapshot"
    let some (rented, _) ← getManagedMachine? mc (node.drop 8).toString | throw (IO.userError "rented machine missing")
    check (rented.ownerMission == child && rented.requestedByMissionId == "snap-owner" && rented.status == "ready" &&
      rented.ttlMinutes == 5 && rented.size == "small") "the child owns the machine rented for it"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

end OrbCore.ManagedSnapshotCatalogTests
