/-
Reserved vault-to-Core sealing. Never returns a value to a mission, response or
log. The resolver is injected so tests exercise authorization before vault I/O.
-/
import Orb.ManagedProviderPolicy
import OrbCore.Managed

namespace OrbCore.ManagedProviderSealing

/-- No arbitrary vault lookup and no legacy provider aliases on the operator path. -/
def reservedKey? (provider : String) : Option String :=
  (OrbCore.ManagedProvider.declaration? provider).map (·.secretName)

abbrev Resolver := String → IO (Except String String)

def sealReserved (root provider : String) (admin mission managed : Bool)
    (resolve : Resolver) : IO (Except String Unit) := do
  if !Orb.ManagedProviderPolicy.maySeal admin mission managed then
    return .error "operator_required"
  let some keyName := reservedKey? provider
    | return .error "managed_provider_secret_unsupported"
  let .ok value ← resolve keyName
    | return .error "managed_provider_secret_lookup_failed"
  let clean := value.trimAscii.toString
  if clean.isEmpty then return .error "managed_provider_secret_empty"
  OrbCore.Managed.sealProviderSecret root provider clean

/-- Discover configured provider names through vault metadata only, then feed
    each value directly into the same reserved sealing boundary. Authority is
    checked before metadata lookup, value lookup or any filesystem mutation. -/
def sealConfigured (root : String) (admin mission managed : Bool)
    (discover : IO (Except String (Array String))) (resolve : Resolver) :
    IO (Except String (Array String)) := do
  if !Orb.ManagedProviderPolicy.maySeal admin mission managed then return .error "operator_required"
  let .ok providers ← discover | return .error "managed_provider_inventory_failed"
  if providers.toList.eraseDups.length != providers.size || providers.any (fun p => (reservedKey? p).isNone) then
    return .error "managed_provider_inventory_invalid"
  let mut sealed : Array String := #[]
  for provider in providers do
    if let .error _ ← sealReserved root provider admin mission managed resolve then
      return .error ("managed_provider_seal_failed:" ++ provider)
    sealed := sealed.push provider
  return .ok sealed

end OrbCore.ManagedProviderSealing
