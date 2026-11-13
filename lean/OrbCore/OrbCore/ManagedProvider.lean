/-
  Managed provider boundary. Provider readiness only means guest commands are available;
  Core must still bootstrap and observe a relay poll before admitting mission work.
  Transport and sleeping are injectable so lifecycle tests never rent a machine.
-/
import OrbBin.HttpClient
import Orb.ManagedProviderAvailability

namespace OrbCore.ManagedProvider

open OrbBin.Json OrbBin.HttpClient

structure SpawnSpec where
  name : String
  size : String
  ttlSeconds : UInt64
  idempotencyKey : String
  fromSnapshot : String := ""
  repo : String := ""
  memoryMiB : Option UInt64 := none

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

structure Availability where
  status : Orb.ManagedProviderAvailability.Status := .available
  reason : String := ""

def availabilityJson (value : Availability) : JVal := .obj #[
  ("status", .str (match value.status with
    | .available => "available" | .degraded => "degraded"
    | .saturated => "saturated" | .unknown => "unknown")),
  ("reason", if value.reason.isEmpty then .null else .str value.reason)
]

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
  /-- Read-only observation; never changes a persisted operator enable toggle. -/
  availability : SpawnSpec → IO (Result Availability) := fun _ => pure (.ok { status := .unknown })
  usageCents : String → IO (Result (Option UInt64)) := fun _ => pure (.ok none)

/-- Parse nonnegative provider USD decimals (including bounded exponent form)
    and round half-up to cents without binary floating-point arithmetic. -/
def usdCents? (raw : String) : Option UInt64 := do
  if raw.length > 64 then none else do
    let parts := raw.toLower.splitOn "e"
    let (mantissa, exponent) ← match parts with
      | [m] => some (m, (0 : Int))
      | [m,e] => do let x ← e.toInt?; pure (m,x)
      | _ => none
    if exponent < -12 || exponent > 12 then none else do
      let (whole, fraction) ← match mantissa.splitOn "." with
        | [w] => some (w, "")
        | [w,f] => some (w,f)
        | _ => none
      let digits := whole ++ fraction
      if whole.isEmpty || !digits.toList.all (fun c => '0' ≤ c && c ≤ '9') then none else do
        let n ← digits.toNat?
        let power := exponent - (Int.ofNat fraction.length) + 2
        let cents := if power ≥ 0 then n * 10 ^ power.toNat else
          let denominator := 10 ^ (-power).toNat
          (n + denominator / 2) / denominator
        if cents > 9000000000000000 then none else some cents.toUInt64

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
  /-- The part of a provider's machine ID that may be shown to the machine's
      owner. Core always calls the provider with the full ID. -/
  publicId : String → String := id

/-- Retain transport diagnostics privately, without a credential or log injection. -/
def transportDiagnostic (apiKey cause : String) : String :=
  let redacted := if apiKey.isEmpty then cause else cause.replace apiKey "[redacted]"
  (redacted.replace "\r" "\\r" |>.replace "\n" "\\n" |>.take 1024).toString

def httpTransport (baseUrl apiKey : String) : Transport := fun req => do
  if apiKey.trimAscii.toString.isEmpty then return .error { code := "provider_credential_missing" }
  let headers := if req.idempotencyKey.isEmpty then #[]
    else #[("Idempotency-Key", req.idempotencyKey)]
  match ← sendJsonRequest req.method (baseUrl ++ req.path) (some apiKey) req.body headers req.timeoutMs with
  | .error cause =>
    IO.eprintln ("[managed-provider] transport failed: " ++ transportDiagnostic apiKey cause)
    return .error { code := "provider_transport_failed_outcome_uncertain" }
  | .ok (status, text, parsed) =>
    if let some body := parsed then return .ok (status, body)
    if text.trimAscii.toString.isEmpty then return .ok (status, .null)
    return .error { status, code := "provider_invalid_json_outcome_uncertain" }

/-- Prefix for a guest command that already runs as root on an image that may
    not ship `sudo`: a function of that name which drops leading option flags
    (`-n`, `-E`) and runs the rest. Unused where `sudo` exists. -/
def sudoShim : String :=
  "command -v sudo >/dev/null 2>&1 || sudo() { while [ \"${1#-}\" != \"$1\" ]; do shift; done; \"$@\"; }; "

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
