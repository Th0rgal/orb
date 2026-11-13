import OrbCore.ManagedProvider

namespace OrbCore.ManagedProvider

open OrbBin.Json OrbBin.HttpClient

private def machineFrom (body : JVal) : Result Machine := do
  let sb := (body.field? "sandbox").getD body
  let id := (sb.fieldStr? "id").getD ""
  if id.trimAscii.toString.isEmpty then throw { code := "provider_missing_machine_id" }
  return {
    providerId := id
    name := (sb.fieldStr? "name").getD ""
    state := (sb.fieldStr? "state").getD "unknown"
  }

private def snapshotFrom (fallbackName : String) (body : JVal) : Result Snapshot := do
  let snap := (body.field? "snapshot").getD body
  let name := (snap.fieldStr? "name").getD fallbackName
  if name.isEmpty then throw { code := "provider_missing_snapshot_name" }
  return {
    name
    status := (snap.fieldStr? "status").getD "unknown"
    sizeBytes := snap.fieldUInt64? "sizeBytes"
  }

def boatSpawnBody (spec : SpawnSpec) : JVal :=
  let fields := #[("type", .str spec.size), ("name", .str spec.name),
    ("ttlSeconds", JVal.uint64 spec.ttlSeconds), ("noEnv", .bool true)]
  .obj (if spec.fromSnapshot.isEmpty || spec.fromSnapshot == "provider-default" then fields
    else fields.push ("from", .str spec.fromSnapshot))

private def boatCreate (transport : Transport) (path : String) (spec : SpawnSpec) : IO (Result Machine) := do
  if spec.idempotencyKey.isEmpty then return .error { code := "provider_idempotency_key_required" }
  match ← call transport {
      method := "POST"
      path
      body := some (boatSpawnBody spec)
      idempotencyKey := spec.idempotencyKey
      timeoutMs := 120000
    } with
  | .error e => return .error e
  | .ok body => return machineFrom body

private def boatList (transport : Transport) : IO (Result (Array Machine)) := do
  let mut out := #[]
  let mut cursor := ""
  let mut seen : Array String := #[]
  for _ in [0:100] do
    let path := "/sandboxes?limit=200" ++
      (if cursor.isEmpty then "" else "&cursor=" ++ urlEncodeComponent cursor)
    let body ← match ← call transport { method := "GET", path } with
      | .error e => return .error e
      | .ok v => pure v
    let some items := body.fieldArr? "sandboxes"
      | return .error { code := "provider_invalid_machine_list" }
    for item in items do
      match machineFrom item with
      | .error e => return .error e
      | .ok m => out := out.push m
    cursor := (body.fieldStr? "nextCursor").orElse (fun _ => body.fieldStr? "cursor") |>.getD ""
    if cursor.isEmpty then return .ok out
    if seen.contains cursor then return .error { code := "provider_repeated_cursor" }
    seen := seen.push cursor
  -- Never return a partial fleet: reconciliation could destroy unseen machines.
  return .error { code := "provider_pagination_limit" }

private def sandboxPath (id : String) : String := "/sandboxes/" ++ urlEncodeComponent id

private def boatStop (transport : Transport) (sleep : UInt32 → IO Unit) (id : String) : IO (Result Unit) := do
  for attempt in [0:5] do
    if attempt > 0 then sleep ((attempt * 3000).toUInt32)
    match ← callUnit transport { method := "POST", path := sandboxPath id ++ "/stop", body := some (.obj #[]) } with
    | .ok _ => return .ok ()
    | .error e =>
      if e.status == 404 || e.status == 409 then return .ok ()
      if e.code != "stop_failed" || attempt == 4 then return .error e
  return .error { code := "provider_stop_retry_exhausted" }

private def boatDestroy (transport : Transport) (id : String) : IO (Result Unit) := do
  match ← callUnit transport { method := "DELETE", path := sandboxPath id } with
  | .ok _ => return .ok ()
  | .error e =>
    if e.status == 404 then return .ok ()
    return .error e

private def boatSnapshotList (transport : Transport) : IO (Result (Array Snapshot)) := do
  match ← call transport { method := "GET", path := "/saved-snapshots" } with
  | .error e => return .error e
  | .ok body =>
    let some items := (body.fieldArr? "snapshots").orElse (fun _ => body.fieldArr? "savedSnapshots")
        |>.orElse (fun _ => body.fieldArr? "items") |>.orElse (fun _ => body.asArr?)
      | return .error { code := "provider_invalid_snapshot_list" }
    let mut out := #[]
    for item in items do
      match snapshotFrom "" item with
      | .error e => return .error e
      | .ok snap => out := out.push snap
    return .ok out

def boatSizes : Array Size := #[
  -- Disk measured on a fresh guest (2026-11-13, dev): 79 GB root, 53 GB free.
  -- The other sizes are not measured.
  { name := "small", cpu := 2, ramGb := 4, diskGb := 79, milliCentsPerHour := 1800 },
  { name := "default", cpu := 4, ramGb := 8, diskGb := 50, milliCentsPerHour := 3600 },
  { name := "large", cpu := 8, ramGb := 16, diskGb := 125, milliCentsPerHour := 7200 },
  { name := "xlarge", cpu := 16, ramGb := 32, diskGb := 251, milliCentsPerHour := 20000 }
]

/-- Conservative whole-cent reservation for the entire requested lease. Rates
    are milli-cents/hour ($0.018, $0.036, $0.072, $0.20); never trust a caller's
    estimated_cents. TTL is bounded before multiplication. -/
def boatQuoteCents (size : String) (ttlMinutes : UInt64) : Result UInt64 := do
  if ttlMinutes < 5 || ttlMinutes > 720 then throw { code := "provider_invalid_ttl" }
  let some profile := boatSizes.find? (·.name == size)
    | throw { code := "provider_invalid_size" }
  return (profile.milliCentsPerHour * ttlMinutes + 59999) / 60000

/-- Boat resumes archived guests by forking, so the provider ID may change.
    Core's durable managed ID and boot epoch must not be replaced with this ID. -/
def boat (transport : Transport) (sleep : UInt32 → IO Unit := fun ms => do IO.sleep ms) : Provider := {
  name := "boat"
  -- Boat has no pool-capacity introspection in its supported API. Preserve its
  -- explicit create-admission behavior; provider rejection still cannot imply ready.
  availability := fun _ => pure (.ok { status := .available, reason := "capacity_not_exposed" })
  readinessDeadlineSecs := 360
  isReady := fun s => #["ready", "idle", "running", "busy"].contains s
  isStopped := fun s => #["archived", "stopped", "deleted", "error", "archiving"].contains s
  quoteCents := boatQuoteCents
  spawn := boatCreate transport "/sandboxes"
  get := fun id => do
    match ← call transport { method := "GET", path := sandboxPath id } with
    | .error e => return .error e
    | .ok body => return machineFrom body
  list := boatList transport
  destroy := boatDestroy transport
  stop := boatStop transport sleep
  resume := fun id spec => boatCreate transport (sandboxPath id ++ "/fork") { spec with fromSnapshot := "" }
  fork := fun id spec => boatCreate transport (sandboxPath id ++ "/fork") { spec with fromSnapshot := "" }
  extend := fun id ttl => callUnit transport {
    method := "PATCH"
    path := sandboxPath id
    body := some (.obj #[("ttlSeconds", JVal.uint64 ttl)])
  }
  saveSnapshot := fun id name => callUnit transport {
    method := "POST"
    path := "/saved-snapshots"
    body := some (.obj #[("sandboxId", .str id), ("name", .str name)])
    timeoutMs := 60000
  }
  getSnapshot := fun name => do
    match ← call transport { method := "GET", path := "/saved-snapshots/" ++ urlEncodeComponent name } with
    | .error e => return .error e
    | .ok body => return snapshotFrom name body
  listSnapshots := boatSnapshotList transport
  deleteSnapshot := fun name => do
    match ← callUnit transport { method := "DELETE", path := "/saved-snapshots/" ++ urlEncodeComponent name } with
    | .error e => if e.status == 404 then return .ok () else return .error e
    | .ok _ => return .ok ()
  -- Boat's file API is `PUT /sandboxes/:id/files`; a POST is rejected.
  writeFile := fun id path content => callUnit transport {
    method := "PUT"
    path := sandboxPath id ++ "/files"
    body := some (.obj #[("path", .str path), ("content", .str content)])
  }
  exec := fun id command timeoutSecs =>
    let timeout := max 1 (min timeoutSecs 600)
    call transport {
      method := "POST"
      path := sandboxPath id ++ "/commands"
      body := some (.obj #[("command", .str command), ("timeoutSeconds", .nat timeout.toNat)])
      timeoutMs := timeout * 1000 + 5000
    }
  usageCents := fun id => do
    match ← call transport { method := "GET", path := sandboxPath id ++ "/usage" } with
    | .error e => return .error e
    | .ok body =>
      let amount := match body.field? "dollars" with
        | some (.num raw) | some (.str raw) => usdCents? raw
        | _ => none
      return .ok amount
}


def boatDeclaration : Declaration := {
  name := "boat"
  displayName := "boat.dev"
  secretName := "BOAT_API_KEY"
  apiBaseEnv := "BOAT_API_URL"
  defaultApiBase := "https://boat.dev/api/v1"
  sizes := boatSizes
  readinessDeadlineSecs := 360
  bootstrapMode := .execSystemd
  supportsStopResume := true
  supportsSnapshots := true
  supportsExtend := true
  quoteCents := boatQuoteCents
  create := fun transport => boat transport
}

end OrbCore.ManagedProvider
