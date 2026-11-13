/-
Reserved vault-to-Core sealing. Never returns a value to a mission, response or
log. The resolver is injected so tests exercise authorization before vault I/O.
-/
import Orb.ManagedProviderPolicy
import OrbCore.Managed

namespace OrbCore.ManagedProviderSealing

/-- No arbitrary vault lookup and no legacy provider aliases on the operator path. -/
def reservedKey? (provider : String) : Option String :=
  match provider with
  | "boat" => some "BOAT_API_KEY"
  | "leanci" => some "LEANCI_API_KEY"
  | "colab" => some "COLAB_API_TOKEN"
  | _ => none

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

end OrbCore.ManagedProviderSealing
