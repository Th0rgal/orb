/-
Implemented-provider registry. Add an adapter's declaration here once; resolution,
quotes and catalog capabilities all consume the same entry. A known provider name
without an entry remains unimplemented, never a synthetic successful machine.
-/
import OrbCore.ManagedProviderBoat
import OrbCore.ManagedProviderLeanci
import OrbCore.ManagedProviderColab

namespace OrbCore.ManagedProvider

open OrbBin.Json

def registry : Array Declaration := #[boatDeclaration, leanciDeclaration, colabDeclaration]

def declaration? (name : String) : Option Declaration :=
  registry.find? (·.name == name)

def quote (provider size : String) (ttlMinutes : UInt64) : Result UInt64 := do
  let some entry := declaration? provider
    | throw { code := "managed_provider_not_implemented" }
  entry.quoteCents size ttlMinutes

def publicProviderId (provider id : String) : String :=
  match declaration? provider with
  | some entry => entry.publicId id
  | none => id

def sizeJson (size : Size) : JVal := .obj #[
  ("size", .str size.name),
  ("cpu", .nat size.cpu),
  ("ram_gb", .nat size.ramGb),
  ("disk_gb", .nat size.diskGb),
  ("usd_per_hour", .num (toString (size.milliCentsPerHour.toNat / 100000) ++ "." ++
    String.ofList (List.replicate (5 - (toString (size.milliCentsPerHour.toNat % 100000)).length) '0') ++
    toString (size.milliCentsPerHour.toNat % 100000)))
]

def catalogFields (provider : String) (capabilities : Option JVal := none) : Array (String × JVal) :=
  match declaration? provider with
  | none => #[
      ("implemented", .bool false), ("supports_snapshots", .bool false),
      ("supports_free_stop", .bool false), ("supports_extend", .bool false),
      ("readiness_deadline_secs", .null), ("bootstrap_mode", .null), ("sizes", .arr #[])]
  | some entry => #[
      ("implemented", .bool true), ("supports_snapshots", .bool entry.supportsSnapshots),
      ("supports_free_stop", .bool entry.supportsStopResume),
      ("supports_extend", .bool (entry.supportsExtend ||
        (provider == "leanci" && (capabilities.map leanciSupportsExtend).getD false))),
      ("readiness_deadline_secs", JVal.uint64 entry.readinessDeadlineSecs),
      ("bootstrap_mode", .str (match entry.bootstrapMode with
        | .execSystemd => "exec_systemd" | .execSupervised => "exec_supervised")),
      ("sizes", .arr ((if provider == "leanci" then
        (capabilities.map (fun body => (leanciCatalogProfiles body).map (·.size))).getD entry.sizes
        else entry.sizes).map sizeJson))]

def catalogFieldsObserved (provider : String) (transport : Transport)
    (cache : LeanciCapabilityCache := leanciCapabilityCache) (nowMs : IO Nat := IO.monoMsNow)
    : IO (Array (String × JVal)) := do
  if provider != "leanci" then return catalogFields provider
  match ← leanciCapabilities transport cache nowMs
      { name := "", size := "small", ttlSeconds := 300, idempotencyKey := "" } with
  | .ok body => return catalogFields provider (some body)
  | .error _ => return catalogFields provider

end OrbCore.ManagedProvider
