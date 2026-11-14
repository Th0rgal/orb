import OrbCore.ManagedProviderRegistry

namespace OrbCore.ManagedProviderLeanciTests

open OrbCore.ManagedProvider OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"lean.ci provider contract: {label}")

private def capabilities (engines vcpus bootVcpus bootMemory launchable : Nat) (reason : JVal := .null) : JVal := .obj #[
  ("largest_bootable_memory_mib", .nat bootMemory),
  ("pool", .obj #[("online_engines", .nat engines)]),
  ("effective", .obj #[("schedulable_vcpus", .nat vcpus),
    ("schedulable_memory_mib", .nat 323796),
    ("largest_bootable_vm", .obj #[("vcpus", .nat bootVcpus), ("memory_mib", .nat bootMemory)])]),
  ("profiles", .arr (leanciProfiles.map fun profile => .obj #[("runner_label", .str profile.runnerLabel),
    ("default_memory_mib", .nat (profile.size.ramGb * 1024)),
    ("max_launchable_now", .nat launchable), ("blocking_reason", reason)]))]

/-- Mock transport that rejects what the real API rejects: POST file uploads,
    string exec commands, unknown labels and non-`lean-*` names. No sockets. -/
def run : IO Unit := do
  let requests ← IO.mkRef (#[] : Array Request)
  let caps ← IO.mkRef (capabilities 3 96 32 107520 4)
  let clock ← IO.mkRef (0 : Nat)
  let cache ← IO.mkRef #[]
  let transport : Transport := fun req => do
    requests.modify (·.push req)
    let body := req.body.getD .null
    if req.method == "GET" && req.path.startsWith "/vms/capabilities" then return .ok (200, ← caps.get)
    if req.method == "POST" && req.path == "/vms" then
      -- Like the server: an unknown label or a missing one is refused; TTL is bounded.
      let label := (body.fieldStr? "runner_label").getD ""
      if !(label.startsWith "lean-" && label.endsWith "vcpu-ubuntu-2604") then return .ok (422, .null)
      if ((body.fieldUInt64? "ttl_secs").getD 0) < 60 then return .ok (400, .null)
      return .ok (202, .obj #[("vm", .obj #[("id", .str "11111111-2222-3333-4444-555555555555"),
        ("name", (body.field? "name").getD .null), ("status", .str "queued")])])
    if req.method == "GET" && req.path == "/vms" then
      return .ok (200, .obj #[("vms", .arr #[.obj #[("id", .str "aaaaaaaa-0000-4000-8000-000000000001"), ("name", .str "orb-managed-a"), ("status", .str "running")]])])
    if req.method == "GET" && req.path == "/vms/snapshots" then
      return .ok (200, .obj #[("snapshots", .arr #[
        .obj #[("id", .str "bbbbbbbb-0000-4000-8000-000000000002"), ("label", .str "warm"), ("status", .str "failed")],
        .obj #[("id", .str "bbbbbbbb-0000-4000-8000-000000000001"), ("label", .str "warm"), ("status", .str "ready"), ("size_bytes", .nat 4096)]])])
    if req.method == "DELETE" && (req.path == "/vms/snapshots/bbbbbbbb-0000-4000-8000-000000000001" || req.path == "/vms/snapshots/bbbbbbbb-0000-4000-8000-000000000002") then return .ok (204, .null)
    if req.method == "GET" && req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001" then
      return .ok (200, .obj #[("vm", .obj #[("id", .str "aaaaaaaa-0000-4000-8000-000000000001"), ("status", .str "running")])])
    if req.method == "DELETE" && req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001" then return .ok (204, .null)
    if req.method == "DELETE" && req.path == "/vms/bbbbbbbb-0000-4000-8000-000000000001" then return .ok (404, .null)
    if req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001/files" then
      -- The real route is PUT with base64 content; a POST or plain `content` is rejected.
      if req.method != "PUT" then return .ok (405, .null)
      if (body.fieldStr? "content_b64").isNone || (body.fieldStr? "path").isNone then return .ok (422, .null)
      return .ok (200, .obj #[("ok", .bool true)])
    if req.method == "POST" && req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001/exec" then
      if (body.fieldArr? "command").isNone then return .ok (422, .null)
      return .ok (200, .obj #[("ok", .bool true), ("exit_code", .nat 0)])
    if req.method == "POST" && req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000002/exec" then
      return .ok (200, .obj #[("ok", .bool false), ("error", .str "guest unreachable")])
    -- A VM that is not running answers 409 to exec, files and snapshots.
    if req.method == "POST" && req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000003/exec" then return .ok (409, .null)
    if req.method == "POST" && req.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001/snapshots" then
      return .ok (201, .obj #[("snapshot", .obj #[("id", .str "bbbbbbbb-0000-4000-8000-000000000001")])])
    return .ok (404, .null)
  let provider := leanci transport cache clock.get

  let some entry := declaration? "leanci" | throw (IO.userError "leanci missing from registry")
  check (entry.secretName == "LEANCI_API_KEY" && entry.defaultApiBase == "https://api.lean.ci/v1" &&
    entry.readinessDeadlineSecs == 480 && !entry.supportsStopResume && entry.supportsSnapshots &&
    !entry.supportsExtend && entry.sizes.size == 6) "declaration"
  check ((declaration? "retired-provider").isNone && (leanciProfile? "retired-profile").isNone) "unknown names rejected"
  -- lean.ci is the owner's own infrastructure: every size is free, for any lease.
  check (entry.sizes.all (·.milliCentsPerHour == 0) &&
    leanciProfiles.all (fun p => (quote "leanci" p.size.name 720).toOption == some 0) &&
    (quote "leanci" "small" 60).toOption == some 0 && (quote "leanci" "medium" 5).toOption == some 0 &&
    !(quote "leanci" "3xlarge" 720).isOk && !(quote "leanci" "small" 721).isOk &&
    !(quote "leanci" "huge" 60).isOk) "zero price for every size and the 720-minute cap"
  let leanciCatalog := JVal.obj (catalogFields "leanci")
  let catalogSizes := (leanciCatalog.fieldArr? "sizes").getD #[]
  check (catalogSizes.size == 6 &&
    catalogSizes.all (fun size => (size.field? "usd_per_hour").map renderCompact == some "0.00000"))
    "the catalog prices every lean.ci size at 0.00000 USD per hour"
  -- The extend call is ready for the day `supportsExtend` is switched on.
  let extendRequest := leanciExtendRequest "aaaaaaaa-0000-4000-8000-000000000001" 600
  check (extendRequest.method == "POST" && extendRequest.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001/extend" &&
    (extendRequest.body.map renderCompact) == some "{\"ttl_secs\":600}" &&
    leanciCatalog.fieldBool? "supports_extend" == some false)
    "extend request shape; without discovery the catalog keeps extend off"
  -- Discovery, both shapes: today's capabilities (no `lifecycle` block) and lean.ci#35's.
  let today := capabilities 3 96 32 107520 4
  let lifecycle (extend : Bool) : JVal := today.setField "lifecycle" (.obj #[
    ("extend", .bool extend), ("snapshots", .bool true), ("restore_from_snapshot", .bool true),
    ("stop_keeps_disk", .bool false), ("resume", .bool false), ("fork", .bool false), ("usage", .bool false)])
  let catalogExtend (body : Option JVal) := (JVal.obj (catalogFields "leanci" body)).fieldBool? "supports_extend"
  check (!leanciSupportsExtend today && !leanciSupportsExtend (.obj #[]) && !leanciSupportsExtend (lifecycle false) &&
    leanciSupportsExtend (lifecycle true)) "extend is supported only when lifecycle.extend is true"
  check (catalogExtend none == some false && catalogExtend (some today) == some false &&
    catalogExtend (some (lifecycle false)) == some false && catalogExtend (some (lifecycle true)) == some true &&
    (JVal.obj (catalogFields "leanci" (some (lifecycle true)))).fieldBool? "supports_free_stop" == some false &&
    ((JVal.obj (catalogFields "leanci" (some (lifecycle true)))).fieldArr? "sizes").map (·.size) == some 6)
    "the observed catalog follows lifecycle.extend and never advertises stop/resume"
  let extendCalls ← IO.mkRef (#[] : Array Request)
  let discovered (body : JVal) (fails : Bool := false) : IO Provider := do
    return leanci (fun req => do
      if req.method == "GET" then return (if fails then .ok (503, .null) else .ok (200, body))
      extendCalls.modify (·.push req)
      return .ok (200, .obj #[("extended", .bool false)])) (← IO.mkRef #[]) (pure 0)
  check (!(← (← discovered today).supportsExtend) && !(← (← discovered (lifecycle false)).supportsExtend) &&
    !(← (← discovered (lifecycle true) true).supportsExtend) && (← (← discovered (lifecycle true)).supportsExtend))
    "the provider answers extend support from discovery, and no when it cannot read it"
  check ((← (← discovered (lifecycle true)).extend "aaaaaaaa-0000-4000-8000-000000000001" 900).isOk &&
    (← extendCalls.get).size == 1 && (← extendCalls.get).back!.idempotencyKey.isEmpty &&
    (← extendCalls.get).back!.path == "/vms/aaaaaaaa-0000-4000-8000-000000000001/extend" &&
    ((← extendCalls.get).back!.body.map renderCompact) == some "{\"ttl_secs\":900}")
    "extend posts the remaining seconds without an idempotency key; an already-covered 200 is success"

  let spec : SpawnSpec := { name := "orb-managed-dev-t", size := "small", ttlSeconds := 300, idempotencyKey := "k1" }
  let .ok created ← provider.spawn spec | throw (IO.userError "spawn failed")
  let sent := (← requests.get).back!
  let body := sent.body.getD .null
  check (created.providerId.length == 36 && !provider.isReady created.state && sent.idempotencyKey == "k1" &&
    body.fieldStr? "runner_label" == some "lean-2vcpu-ubuntu-2604" && body.fieldUInt64? "ttl_secs" == some 300 &&
    (body.field? "memory_mib").isNone && (body.field? "snapshot_id").isNone) "create wire contract; queued is not ready"
  let .ok wide := leanciSpawnBody { spec with size := "2xlarge" } | throw (IO.userError "2xlarge body")
  check (wide.fieldStr? "runner_label" == some "lean-32vcpu-ubuntu-2604" && wide.fieldUInt64? "memory_mib" == some 98304 &&
    (leanciProfile? "lean-32vcpu-ubuntu-2604").map (·.size.name) == some "2xlarge" &&
    !(leanciSpawnBody { spec with size := "3xlarge" }).isOk) "32-vCPU profile is 96 GiB; impossible size rejected"
  let live := capabilities 3 96 32 107520 4
  check ((leanciCatalogProfiles live).size == 6 && entry.sizes.all (fun size => size.ramGb * 1024 ≤ 107520) &&
    ((.obj (catalogFields "leanci" (some live)) : JVal).fieldArr? "sizes").map (·.size) == some 6 &&
    (leanciCatalogProfiles (capabilities 3 96 32 65536 4)).size == 4 &&
    (leanciCatalogProfiles (capabilities 3 8 32 107520 4)).size == 3 &&
    (leanciCatalogProfiles (capabilities 3 96 32 107520 0)).isEmpty &&
    (leanciCatalogProfiles (capabilities 0 96 32 107520 4)).isEmpty &&
    (leanciCatalogProfiles (.obj #[])).isEmpty) "catalog uses live bootable capacity, not aggregate pool memory"
  let heterogeneous (ceiling : Option Nat) (slot : JVal) : JVal := .obj (
    (ceiling.map (fun value => #[("largest_bootable_memory_mib", JVal.nat value)])).getD #[] ++ #[
    ("pool", .obj #[("online_engines", .nat 2)]),
    ("effective", .obj #[("schedulable_vcpus", .nat 48), ("schedulable_memory_mib", .nat 98304),
      ("largest_bootable_vm", slot)]),
    ("profiles", .arr #[.obj #[("runner_label", .str "lean-16vcpu-ubuntu-2604"),
      ("default_memory_mib", .nat 65536), ("max_launchable_now", .nat 1)]])])
  let mixed := heterogeneous (some 65536) (.obj #[("vcpus", .nat 32), ("memory_mib", .nat 32768)])
  check ((leanciCatalogProfiles mixed).map (·.size.name) == #["xlarge"] &&
    (leanciAvailabilityOf { spec with size := "xlarge" } mixed).status == .available)
    "heterogeneous pool uses profile launchability, not the CPU-first selected engine"
  let withoutSlotMemory := heterogeneous (some 107520) (.obj #[("vcpus", .nat 32)])
  check ((leanciAvailabilityOf { spec with size := "xlarge" } withoutSlotMemory).status == .available &&
    (leanciAvailabilityOf { spec with size := "xlarge" }
      (heterogeneous (some 32768) .null)).status == .saturated &&
    (leanciAvailabilityOf { spec with size := "xlarge" }
      (heterogeneous none .null)).status == .available &&
    (leanciAvailabilityOf { spec with size := "xlarge", memoryMiB := some 108544 }
      (heterogeneous none .null)).status == .saturated)
    "top-level memory ceiling works without slot memory; absent ceiling uses global bound"
  check ((leanciAvailabilityOf { spec with size := "xlarge", memoryMiB := some 98304 } mixed).status == .saturated &&
    (leanciAvailabilityOf { spec with size := "xlarge", memoryMiB := some 98304 }
      withoutSlotMemory).status == .unknown)
    "custom memory cannot infer a fitting engine from default-profile launchability"
  let incomplete := .obj #[("pool", .obj #[("online_engines", .nat 3)]),
    ("effective", .obj #[("schedulable_vcpus", .nat 96), ("schedulable_memory_mib", .nat 323796),
      ("largest_bootable_vm", .obj #[("vcpus", .nat 32), ("memory_mib", .nat 107520)])]),
    ("profiles", .arr #[.obj #[("runner_label", .str "lean-2vcpu-ubuntu-2604")]])]
  check ((leanciAvailabilityOf spec incomplete).status == .unknown &&
    (leanciCatalogProfiles incomplete).isEmpty) "missing launchability is not available"
  check ((leanciAvailabilityOf { spec with size := "2xlarge" } live).status == .available &&
    (leanciAvailabilityOf { spec with memoryMiB := some 108544 } live).status == .saturated &&
    (leanciAvailabilityOf { spec with size := "3xlarge" } live).status == .unknown)
    "live service retains 32 vCPU/96 GiB and rejects oversized or unknown requests"
  check (!(leanciSpawnBody { spec with memoryMiB := some 5000 }).isOk &&
    !(leanciSpawnBody { spec with memoryMiB := some 108544 }).isOk &&
    !(leanciSpawnBody { spec with memoryMiB := some 131072 }).isOk &&
    (leanciSpawnBody { spec with memoryMiB := some 107520 }).isOk &&
    (leanciSpawnBody { spec with memoryMiB := some 4096 }).isOk &&
    !(leanciSpawnBody { spec with ttlSeconds := 30 }).isOk &&
    ((leanciSpawnBody { spec with fromSnapshot := "orb-node-base" }).toOption.bind (·.field? "snapshot_id")).isNone &&
    !(leanciSpawnBody { spec with fromSnapshot := "warm-label" }).isOk)
    "memory bounds, TTL floor, base image is a fresh VM, a snapshot label never boots fresh"
  let .ok _ ← provider.spawn { spec with fromSnapshot := "warm", idempotencyKey := "k2" }
    | throw (IO.userError "spawn from a snapshot label failed")
  check (((← requests.get).back!.body.getD .null).fieldStr? "snapshot_id" == some "bbbbbbbb-0000-4000-8000-000000000001")
    "a snapshot label resolves to the ready snapshot's ID, not the failed one"
  let beforeMissing := (← requests.get).size
  check (!(← provider.spawn { spec with fromSnapshot := "no-such", idempotencyKey := "k3" }).isOk &&
    (← requests.get).size == beforeMissing + 1) "an unknown snapshot label rents nothing"
  let before := (← requests.get).size
  check (!(← provider.spawn { spec with idempotencyKey := "" }).isOk && (← requests.get).size == before)
    "idempotency key required before I/O"

  let .ok machines ← provider.list | throw (IO.userError "list failed")
  check (machines.size == 1 && machines.all (fun m => provider.isReady m.state) && provider.isStopped "reaped" &&
    !provider.isStopped "snapshotting") "list and state mapping"
  check ((← provider.destroy "aaaaaaaa-0000-4000-8000-000000000001").isOk && (← provider.destroy "bbbbbbbb-0000-4000-8000-000000000001").isOk) "destroy; 404 is idempotent"
  check (!(← provider.stop "aaaaaaaa-0000-4000-8000-000000000001").isOk && !(← provider.extend "aaaaaaaa-0000-4000-8000-000000000001" 600).isOk &&
    !(← provider.resume "aaaaaaaa-0000-4000-8000-000000000001" spec).isOk) "stop and resume are unsupported, and an extend the provider does not serve fails, not faked"

  check (← provider.writeFile "aaaaaaaa-0000-4000-8000-000000000001" "/home/user/.orb/enroll.env" "A=1\n").isOk "file upload"
  let file := (← requests.get).back!
  check (file.method == "PUT" && (file.body.getD .null).fieldStr? "content_b64" == some "QT0xCg==" &&
    (file.body.getD .null).fieldNat? "mode" == some 384) "PUT, base64, mode 0600"
  let .ok ran ← provider.exec "aaaaaaaa-0000-4000-8000-000000000001" "true" 90 | throw (IO.userError "exec failed")
  let exec := ((← requests.get).back!.body.getD .null)
  check (ran.fieldInt? "exit_code" == some 0 && exec.fieldBool? "as_root" == some true &&
    ((exec.fieldArr? "command").map (·.size)) == some 3 && exec.fieldNat? "timeout_secs" == some 90) "exec argv as root"
  check (!(← provider.exec "aaaaaaaa-0000-4000-8000-000000000002" "true" 10).isOk && !(← provider.exec "aaaaaaaa-0000-4000-8000-000000000003" "true" 10).isOk)
    "exec without an exit code, or on a stopped VM, is a failure"
  let beforeLong := (← requests.get).size
  check (!(← provider.exec "aaaaaaaa-0000-4000-8000-000000000001" (String.ofList (List.replicate 5000 'x')) 10).isOk &&
    (← requests.get).size == beforeLong) "oversized exec argument refused before I/O"
  check ((← requests.get).back!.timeoutMs == 130000) "client waits longer than the server's guest wait"

  check ((← provider.saveSnapshot "aaaaaaaa-0000-4000-8000-000000000001" "warm").isOk) "snapshot save"
  let .ok snap ← provider.getSnapshot "warm" | throw (IO.userError "snapshot lookup failed")
  let beforeDelete := (← requests.get).size
  check (snap.status == "ready" && snap.sizeBytes == some 4096 && !(← provider.getSnapshot "absent").isOk &&
    (← provider.deleteSnapshot "warm").isOk && (← requests.get).size == beforeDelete + 4 &&
    (← provider.deleteSnapshot "absent").isOk && !(← provider.saveSnapshot "x" "bad label").isOk)
    "ready snapshot preferred over a failed one; delete removes every entry with the label"

  -- Capacity preflight: saturation cases, repo/snapshot queries and the 20 s cache.
  requests.set #[]
  let observe (s : SpawnSpec) : IO Availability := do
    let .ok value ← provider.availability s | throw (IO.userError "availability failed")
    return value
  check ((← observe spec).status == .available) "capacity available"
  check ((← observe spec).status == .available && (← requests.get).size == 1) "cached within 20 s"
  let observedFields ← catalogFieldsObserved "leanci" transport cache clock.get
  check (((.obj observedFields : JVal).fieldArr? "sizes").map (·.size) == some 6 &&
    (← requests.get).size == 1) "catalog shares the capability cache"
  let failedCatalog ← catalogFieldsObserved "leanci" (fun _ => pure (.error { code := "provider_http_error" }))
    (← IO.mkRef #[]) clock.get
  check (((.obj failedCatalog : JVal).fieldArr? "sizes").map (·.size) == some 6)
    "catalog lookup failure retains only conservative declarations"
  clock.set 20001
  caps.set (capabilities 0 64 32 131072 4)
  check ((← observe spec).status == .saturated && (← requests.get).size == 2) "no engines; cache expired"
  clock.set 50000
  caps.set (capabilities 3 0 32 131072 4)
  check ((← observe spec).status == .saturated) "no schedulable vCPUs"
  clock.set 80000
  caps.set (capabilities 3 64 1 131072 4)
  check ((← observe spec).status == .available) "CPU-first slot does not override launchable default profile"
  clock.set 110000
  caps.set (capabilities 3 64 32 131072 0 (.str "quota_vcpus"))
  let quota ← observe spec
  check (quota.status == .saturated && quota.reason == "quota_vcpus") "profile not launchable"
  clock.set 140000
  caps.set (.obj #[])
  check ((← observe spec).status == .unknown) "uninterpretable capabilities are unknown, not available"
  discard <| observe { spec with repo := "Layr-Labs/evm.fast" }
  check ((← requests.get).back!.path == "/vms/capabilities?repo=Layr-Labs%2Fevm.fast") "repo query"
  discard <| observe { spec with fromSnapshot := "11111111-2222-3333-4444-555555555555" }
  check ((← requests.get).back!.path == "/vms/capabilities?snapshot_id=11111111-2222-3333-4444-555555555555") "snapshot query"

end OrbCore.ManagedProviderLeanciTests
