import OrbCore.NodeLiveness
import OrbCore.RemoteFleetAndRelay

namespace OrbCore.NodeLivenessTests

open OrbBin.Json OrbCore.NodeLiveness OrbCore.Managed OrbCore.RemoteFleetAndRelay OrbCore.LegacyHydrate OrbCore.Store

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"node liveness: {label}")

private def pureTests : IO Unit := do
  check (lastSeen none 0 == none && lastSeen (some 50) 0 == some 50 && lastSeen none 70 == some 70 &&
    lastSeen (some 50) 70 == some 70 && lastSeen (some 90) 70 == some 90) "the latest contact from either source wins"
  check (managedStatus "ready" (some 1000) 1090 == "online" && managedStatus "ready" (some 1000) 1091 == "offline")
    "a poll proves liveness for 90 seconds"
  check (managedStatus "ready" none 1000 == "offline") "ready without any poll is not online"
  check (managedStatus "provisioning" (some 1000) 1000 == "provisioning" && managedStatus "stopped" (some 1000) 1000 == "offline")
    "only a ready machine can be online"
  let online : JVal := .obj #[("id", .str "ashur"), ("status", .str "online"), ("last_seen", .str "T1"),
    ("cpu_total", JVal.nat 32), ("mem_total_bytes", JVal.nat 64), ("mem_available_bytes", JVal.nat 10),
    ("disk_total_bytes", .null), ("version", .str "1.2")]
  let silent (id : String) : JVal := .obj #[("id", .str id), ("status", .str "offline"), ("last_seen", .null),
    ("cpu_total", .null), ("mem_total_bytes", .null), ("mem_available_bytes", .null), ("error", .str "timeout")]
  let cache := updateCache (.obj #[]) #[online, silent "nippur"]
  check (cache == .obj #[("ashur", .obj #[("last_seen", .str "T1"), ("cpu_total", JVal.nat 32),
    ("mem_total_bytes", JVal.nat 64), ("version", .str "1.2")])]) "only what a heartbeat reported is cached"
  let kept := updateCache cache #[silent "ashur", silent "nippur"]
  check (kept == cache) "a silent node keeps its entry"
  check (updateCache cache #[silent "nippur"] == .obj #[]) "a node no longer configured is dropped"
  let shown := applyCache cache (silent "ashur")
  check (shown.fieldStr? "status" == some "offline" && shown.fieldStr? "last_seen" == some "T1" &&
    shown.fieldNat? "cpu_total" == some 32 && shown.fieldNat? "mem_total_bytes" == some 64 &&
    shown.field? "mem_available_bytes" == some .null && shown.fieldStr? "version" == some "1.2" &&
    shown.fieldBool? "capacity_cached" == some true && shown.fieldStr? "error" == some "timeout")
    "an offline node shows its last contact and size, and no live figures"
  check (applyCache cache (silent "nippur") == silent "nippur") "a node never seen stays unknown"
  check (applyCache cache online == online) "an online node is reported as probed"

/-- The fleet view over a real store: liveness comes from the persisted poll. -/
private def fleetTests (root : String) : IO Unit := do
  let .ok mc ← openManagedComputeStore s!"{root}/liveness-managed.db" | throw (IO.userError "liveness store open failed")
  try
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 100000, maxConcurrent := 100 }
    let now ← coreEpochSec
    for (id, size, pollAge) in #[("fresh", "small", 10), ("stale", "large", 600), ("odd", "no-such-size", 10)] do
      let .ok _ ← provisionManagedMachine mc fleet {
          id, sandboxName := s!"orb-managed-{id}", provider := "boat", size, ownerKind := "user", ttlMinutes := 30, spentCents := 5
        } now | throw (IO.userError "liveness machine fixture failed")
      let .ok _ ← bindManagedProviderId mc id s!"remote-{id}" 1 | throw (IO.userError "liveness bind failed")
      let .ok _ ← recordAuthenticatedManagedPoll mc id 1 (now - pollAge) | throw (IO.userError "liveness poll failed")
    let .ok _ ← provisionManagedMachine mc fleet {
        id := "booting", sandboxName := "orb-managed-booting", provider := "boat", size := "small", ownerKind := "user",
        ttlMinutes := 30, spentCents := 5
      } now | throw (IO.userError "liveness booting fixture failed")
    let .ok live ← loadManagedFleet mc true true 100000 0 100 | throw (IO.userError "liveness fleet load failed")
    let view ← buildComputeFleetJVal none (some mc) live none 0 none root
    let node (id : String) : IO JVal := do
      match ((view.fieldArr? "managed_nodes").getD #[]).find? (·.fieldStr? "machine_id" == some id) with
      | some item => pure item
      | none => throw (IO.userError s!"node liveness: {id} missing from the fleet view")
    let fresh ← node "fresh"
    check (fresh.fieldStr? "status" == some "online" && fresh.fieldBool? "relay_connected" == some true &&
      fresh.fieldStr? "last_seen" == some (formatEpochIso8601Utc (now - 10))) "a recent persisted poll is online, with its own time"
    -- The declared size is the provider catalog's entry, not a number repeated here.
    let some declared := OrbCore.ManagedProvider.boatSizes.find? (·.name == "small")
      | throw (IO.userError "node liveness: Boat small missing from the catalog")
    check (fresh.fieldNat? "cpu_total" == some declared.cpu &&
      fresh.fieldNat? "mem_total_bytes" == some (declared.ramGb * 1024 * 1024 * 1024) &&
      fresh.fieldNat? "disk_total_bytes" == some (declared.diskGb * 1024 * 1024 * 1024)) "capacity is the declared size"
    let stale ← node "stale"
    check (stale.fieldStr? "status" == some "offline" && stale.fieldBool? "relay_connected" == some false &&
      stale.fieldNat? "capacity_available" == some 0 && stale.fieldStr? "state" == some "ready" &&
      stale.fieldStr? "last_seen" == some (formatEpochIso8601Utc (now - 600)) && stale.fieldNat? "cpu_total" == some 8)
      "a ready machine that stopped polling is offline, and says when it was last seen"
    let odd ← node "odd"
    check (odd.field? "cpu_total" == some .null && odd.field? "mem_total_bytes" == some .null) "an unknown size reports no capacity"
    let booting ← node "booting"
    check (booting.fieldStr? "status" == some "provisioning" && booting.field? "last_seen" == some .null)
      "a machine that never polled has no last contact"
    -- The machine record carries the same declared shape and price.
    let some (small, _) ← getManagedMachine? mc "fresh" | throw (IO.userError "liveness machine missing")
    let .ok item := OrbBin.Json.parse (renderManagedMachineItemJson small) | throw (IO.userError "machine JSON invalid")
    check (item.fieldNat? "cpu" == some 2 && item.fieldNat? "ram_gb" == some 4) "the machine record reports its real size"
    check (item.fieldStr? "created_at" == some (formatEpochIso8601Utc small.createdAtSec) &&
      item.fieldStr? "expires_at" == some (formatEpochIso8601Utc small.expiresAtSec) &&
      item.field? "deletable_at" == some .null &&
      item.fieldNat? "deletable_at_sec" == some 0 &&
      item.fieldNat? "expires_at_sec" == some small.expiresAtSec.toNat)
      s!"client ISO timestamps and epoch compatibility fields describe the same lease (got deletable_at={item.field? "deletable_at" |>.map OrbBin.Json.renderCompact})"
    let .ok boundItem := OrbBin.Json.parse (renderManagedMachineItemJson { small with deletableAtSec := now + 3600 })
      | throw (IO.userError "bound machine JSON invalid")
    check (boundItem.fieldStr? "deletable_at" == some (formatEpochIso8601Utc (now + 3600)) &&
      boundItem.fieldNat? "deletable_at_sec" == some (now + 3600).toNat)
      "minimum-lease deletable_at renders as UTC ISO-8601 alongside deletable_at_sec"
    check (managedUsdPerHourJson "boat" "small" == "0.01800" && managedUsdPerHourJson "boat" "xlarge" == "0.20000" &&
      managedUsdPerHourJson "boat" "no-such-size" == "null") "the hourly price is the declared rate"
    let some (unknown, _) ← getManagedMachine? mc "odd" | throw (IO.userError "liveness machine missing")
    let .ok oddItem := OrbBin.Json.parse (renderManagedMachineItemJson unknown) | throw (IO.userError "machine JSON invalid")
    check (oddItem.field? "cpu" == some .null && oddItem.field? "usd_per_hour" == some .null) "an unknown size is not given a made-up shape"
    -- The heartbeat cache round-trips through its file.
    let cache : JVal := .obj #[("ashur", .obj #[("last_seen", .str "T1"), ("cpu_total", JVal.nat 32)])]
    saveNodeHeartbeatCache root (.obj #[]) cache
    check ((← loadNodeHeartbeatCache root) == cache) "the heartbeat cache persists"
    check ((← loadNodeHeartbeatCache s!"{root}/absent") == .obj #[] && (← loadNodeHeartbeatCache "") == .obj #[])
      "no cache file reads as empty"
  finally
    closeManagedComputeStore mc

def run (root : String) : IO Unit := do
  pureTests
  fleetTests root

end OrbCore.NodeLivenessTests
