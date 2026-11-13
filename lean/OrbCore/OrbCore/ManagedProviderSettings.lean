/-
Operator provider toggles have one persistent owner, separate from ephemeral
provider availability. No observation/cache code imports or calls this writer.
-/
import OrbCore.Managed

namespace OrbCore.ManagedProviderSettings

open OrbCore.Managed OrbCore.Store

def isEnabled (store : ManagedComputeStore) (provider : String) : IO (Except String Bool) := do
  if provider == "boat" then
    let .ok rows ← execParamQuery store.db
        "SELECT boat_enabled FROM managed_fleet_state WHERE singleton_id=1;" #[]
      | return .error "managed_provider_settings_unavailable"
    return .ok (rows.size ≤ 1 || (rows[1]!.getD 0 "") == "1")
  let .ok rows ← execParamQuery store.db
      "SELECT enabled FROM managed_provider_settings WHERE provider=?1;" #[provider]
    | return .error "managed_provider_settings_unavailable"
  -- Absence means no individual opt-out. Global managed enablement and Boat's
  -- legacy switch are independent guards; credentials alone do not enable either.
  if rows.size ≤ 1 then return .ok true
  return .ok ((rows[1]!.getD 0 "") == "1")

def setEnabled (store : ManagedComputeStore) (provider : String) (enabled : Bool)
    (nowIso : String) : IO (Except String Unit) := do
  if provider == "boat" then return .error "boat_toggle_owned_by_fleet"
  if !isKnownProvider provider || canonicalizeProvider provider != provider then
    return .error "unknown_provider"
  match ← execParamQuery store.db
      ("INSERT INTO managed_provider_settings(provider,enabled,updated_at) VALUES(?1,?2,?3) " ++
       "ON CONFLICT(provider) DO UPDATE SET enabled=excluded.enabled,updated_at=excluded.updated_at;")
      #[provider, if enabled then "1" else "0", nowIso] with
  | .error _ => return .error "managed_provider_settings_unavailable"
  | .ok _ => return .ok ()

def disabled (store : ManagedComputeStore) : IO (Except String (Array String)) := do
  let .ok rows ← execParamQuery store.db
      "SELECT provider FROM managed_provider_settings WHERE enabled=0 AND provider<>'boat' ORDER BY provider;" #[]
    | return .error "managed_provider_settings_unavailable"
  return .ok ((rows.extract 1 rows.size).map (fun row => row.getD 0 ""))

end OrbCore.ManagedProviderSettings
