/-
  Managed provider boundary. Provider readiness only means guest commands are available;
  Core must still bootstrap and observe a relay poll before admitting mission work.
  Transport and sleeping are injectable so lifecycle tests never rent a machine.
-/
import OrbBin.HttpClient

namespace OrbCore.ManagedProvider

open OrbBin.Json OrbBin.HttpClient

structure SpawnSpec where
  name : String
  size : String
  ttlSeconds : UInt64
  idempotencyKey : String
  fromSnapshot : String := ""

structure Machine where
  providerId : String
  name : String := ""
  state : String := "unknown"
  deriving Repr, BEq

structure Snapshot where
  name : String
  status : String := "unknown"
  sizeBytes : Option UInt64 := none
  deriving Repr, BEq

/-- No credential or provider response body is included in errors. -/
structure ProviderError where
  status : Nat := 0
  code : String
  deriving Repr, BEq

abbrev Result (α : Type) := Except ProviderError α

structure Request where
  method : String
  path : String
  body : Option JVal := none
  idempotencyKey : String := ""
  timeoutMs : UInt32 := 25000
  deriving Inhabited

abbrev Transport := Request → IO (Result (Nat × JVal))

/-- The sole provider I/O interface, shared by REST, MCP and automatic placement. -/
structure Provider where
  name : String
  readinessDeadlineSecs : UInt64
  isReady : String → Bool
  isStopped : String → Bool
  spawn : SpawnSpec → IO (Result Machine)
  get : String → IO (Result Machine)
  list : IO (Result (Array Machine))
  destroy : String → IO (Result Unit)
  stop : String → IO (Result Unit)
  resume : String → SpawnSpec → IO (Result Machine)
  fork : String → SpawnSpec → IO (Result Machine)
  extend : String → UInt64 → IO (Result Unit)
  saveSnapshot : String → String → IO (Result Unit)
  getSnapshot : String → IO (Result Snapshot)
  listSnapshots : IO (Result (Array Snapshot))
  deleteSnapshot : String → IO (Result Unit)
  writeFile : String → String → String → IO (Result Unit)
  exec : String → String → UInt32 → IO (Result JVal)

def httpTransport (baseUrl apiKey : String) : Transport := fun req => do
  if apiKey.trimAscii.toString.isEmpty then return .error { code := "provider_credential_missing" }
  let headers := if req.idempotencyKey.isEmpty then #[]
    else #[("Idempotency-Key", req.idempotencyKey)]
  match ← sendJsonRequest req.method (baseUrl ++ req.path) (some apiKey) req.body headers req.timeoutMs with
  | .error _ => return .error { code := "provider_transport_failed_outcome_uncertain" }
  | .ok (status, text, parsed) =>
    if let some body := parsed then return .ok (status, body)
    if text.trimAscii.toString.isEmpty then return .ok (status, .null)
    return .error { status, code := "provider_invalid_json_outcome_uncertain" }

private def call (transport : Transport) (req : Request) : IO (Result JVal) := do
  match ← transport req with
  | .error e => return .error e
  | .ok (status, body) =>
    if 200 ≤ status && status < 300 then return .ok body
    -- Only use an allowlisted code: arbitrary upstream text can contain secrets.
    let raw := (body.fieldStr? "code").orElse (fun _ => body.fieldStr? "error") |>.getD ""
    let code := if raw == "stop_failed" then raw else "provider_http_error"
    return .error { status, code }

private def callUnit (transport : Transport) (req : Request) : IO (Result Unit) := do
  return (← call transport req).map (fun _ => ())

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

private def boatDestroy (transport : Transport) (sleep : UInt32 → IO Unit) (id : String) : IO (Result Unit) := do
  match ← callUnit transport { method := "DELETE", path := sandboxPath id } with
  | .ok _ => return .ok ()
  | .error e =>
    if e.status == 404 then return .ok ()
    return ← boatStop transport sleep id

private def boatSnapshotList (transport : Transport) : IO (Result (Array Snapshot)) := do
  match ← call transport { method := "GET", path := "/saved-snapshots" } with
  | .error e => return .error e
  | .ok body =>
    let some items := (body.fieldArr? "snapshots").orElse (fun _ => body.asArr?)
      | return .error { code := "provider_invalid_snapshot_list" }
    let mut out := #[]
    for item in items do
      match snapshotFrom "" item with
      | .error e => return .error e
      | .ok snap => out := out.push snap
    return .ok out

/-- Boat resumes archived guests by forking, so the provider ID may change.
    Core's durable managed ID and boot epoch must not be replaced with this ID. -/
def boat (transport : Transport) (sleep : UInt32 → IO Unit := fun ms => do IO.sleep ms) : Provider := {
  name := "boat"
  readinessDeadlineSecs := 360
  isReady := fun s => #["ready", "idle", "running", "busy"].contains s
  isStopped := fun s => #["archived", "stopped", "deleted", "error", "archiving"].contains s
  spawn := boatCreate transport "/sandboxes"
  get := fun id => do
    match ← call transport { method := "GET", path := sandboxPath id } with
    | .error e => return .error e
    | .ok body => return machineFrom body
  list := boatList transport
  destroy := boatDestroy transport sleep
  stop := boatStop transport sleep
  resume := fun id spec => boatCreate transport (sandboxPath id ++ "/fork") spec
  fork := fun id spec => boatCreate transport (sandboxPath id ++ "/fork") spec
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
  writeFile := fun id path content => callUnit transport {
    method := "POST"
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
}

end OrbCore.ManagedProvider
