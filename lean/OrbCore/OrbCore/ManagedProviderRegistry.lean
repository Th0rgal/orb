/-
Implemented-provider registry. Add an adapter's declaration here once; resolution,
quotes and catalog capabilities all consume the same entry. A known provider name
without an entry remains unimplemented, never a synthetic successful machine.
-/
import OrbCore.ManagedProviderBoat
import OrbCore.ManagedProviderLeanci

namespace OrbCore.ManagedProvider

open OrbBin.Json

def registry : Array Declaration := #[boatDeclaration, leanciDeclaration]

def declaration? (name : String) : Option Declaration :=
  registry.find? (·.name == name)

def quote (provider size : String) (ttlMinutes : UInt64) : Result UInt64 := do
  let some entry := declaration? provider
    | throw { code := "managed_provider_not_implemented" }
  entry.quoteCents size ttlMinutes

def sizeJson (size : Size) : JVal := .obj #[
  ("size", .str size.name),
  ("cpu", .nat size.cpu),
  ("ram_gb", .nat size.ramGb),
  ("disk_gb", .nat size.diskGb),
  ("usd_per_hour", .num (toString (size.milliCentsPerHour.toNat / 100000) ++ "." ++
    String.ofList (List.replicate (5 - (toString (size.milliCentsPerHour.toNat % 100000)).length) '0') ++
    toString (size.milliCentsPerHour.toNat % 100000)))
]

def catalogFields (provider : String) : Array (String × JVal) :=
  match declaration? provider with
  | none => #[
      ("implemented", .bool false), ("supports_snapshots", .bool false),
      ("supports_free_stop", .bool false), ("supports_extend", .bool false),
      ("readiness_deadline_secs", .null), ("bootstrap_mode", .null), ("sizes", .arr #[])]
  | some entry => #[
      ("implemented", .bool true), ("supports_snapshots", .bool entry.supportsSnapshots),
      ("supports_free_stop", .bool entry.supportsStopResume),
      ("supports_extend", .bool entry.supportsExtend),
      ("readiness_deadline_secs", JVal.uint64 entry.readinessDeadlineSecs),
      ("bootstrap_mode", .str (match entry.bootstrapMode with
        | .execSystemd => "exec_systemd" | .execSupervised => "exec_supervised")),
      ("sizes", .arr (entry.sizes.map sizeJson))]

end OrbCore.ManagedProvider
