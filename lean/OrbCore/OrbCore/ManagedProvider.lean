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
  quoteCents : String → UInt64 → Result UInt64
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

/-- Integer milli-cents avoid floating point and conservatively reserve full leases. -/
structure Size where
  name : String
  cpu : Nat
  ramGb : Nat
  diskGb : Nat
  milliCentsPerHour : UInt64
  deriving Repr, BEq

inductive BootstrapMode where
  | execSystemd
  | execSupervised
  deriving Repr, BEq

/-- Provider-owned catalog data. Usability is resolved separately, never persisted here. -/
structure Declaration where
  name : String
  displayName : String
  secretName : String
  apiBaseEnv : String
  defaultApiBase : String
  sizes : Array Size
  readinessDeadlineSecs : UInt64
  bootstrapMode : BootstrapMode
  supportsStopResume : Bool
  supportsSnapshots : Bool
  supportsExtend : Bool
  quoteCents : String → UInt64 → Result UInt64
  create : Transport → Provider

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

def call (transport : Transport) (req : Request) : IO (Result JVal) := do
  match ← transport req with
  | .error e => return .error e
  | .ok (status, body) =>
    if 200 ≤ status && status < 300 then return .ok body
    -- Only use an allowlisted code: arbitrary upstream text can contain secrets.
    let raw := (body.fieldStr? "code").orElse (fun _ => body.fieldStr? "error") |>.getD ""
    let code := if raw == "stop_failed" then raw else "provider_http_error"
    return .error { status, code }

def callUnit (transport : Transport) (req : Request) : IO (Result Unit) := do
  return (← call transport req).map (fun _ => ())


end OrbCore.ManagedProvider
