import OrbBin.HttpClient
import OrbCore.ProviderCredentialIdentity

namespace OrbCore.AccountVpnSidecar

open OrbBin.HttpClient OrbBin.Json

/-- Management carries both an operator credential and an account-specific
proxy password, so a cleartext endpoint must be local to the service. -/
def validManagement (base : String) : Bool :=
  match parseUrl base with
  | .error _ => false
  | .ok url => url.isHttps || ["127.0.0.1", "::1", "[::1]"].contains url.host

private def readCredential (base key file : String) : IO (Except String JVal) := do
  let url := base ++ "/v8/management/credentials/download?name=" ++ urlEncodeComponent file
  let .ok (200, _, some credential) ← sendJsonRequest "GET" url (some key) none #[] 4000 262144
    | return .error "vpn_sidecar_credential_unavailable"
  let .obj _ := credential | return .error "vpn_sidecar_credential_unavailable"
  return .ok credential

private def readBinding (base key file : String) : IO (Except String (String × String)) := do
  let .ok credential ← readCredential base key file | return .error "vpn_sidecar_credential_unavailable"
  let modelPrefix := (credential.fieldStr? "prefix").getD ""
  match credential.field? "proxy_url" with
  | none | some .null => return .ok ("", modelPrefix)
  | some (.str proxy) => return .ok (proxy, modelPrefix)
  | _ => return .error "vpn_sidecar_proxy_invalid"

/-- Confirm the sidecar still owns the configured account proxy and model prefix
before sending an account-pinned inference request to its local API. -/
def confirm (base key file relay modelPrefix : String) : IO (Except String Unit) := do
  if !validManagement base || key.isEmpty || file.isEmpty || relay.isEmpty || modelPrefix.isEmpty then
    return .error "vpn_sidecar_binding_unavailable"
  match ← readBinding base key file with
  | .ok (proxy, name) =>
    if proxy == relay && name == modelPrefix then return .ok ()
    return .error "vpn_sidecar_binding_changed"
  | .error e => return .error e

/-- Touch only the selected auth file. An existing third-party proxy belongs
to the operator. The management response, credential document, and URL never
escape this boundary or enter the error string. -/
def configure (base key file relay : String) (enable : Bool) : IO (Except String Unit) := do
  if !validManagement base || key.isEmpty || file.isEmpty || !file.endsWith ".json" ||
    file.contains '/' || file.contains '\\' || relay.isEmpty then return .error "vpn_sidecar_unavailable"
  let (before, modelPrefix) ← match ← readBinding base key file with
    | .error e => return .error e
    | .ok value => pure value
  if !before.isEmpty && before != relay then return .error "vpn_sidecar_proxy_conflict"
  let desired := if enable then relay else ""
  let generated := ProviderUsageAndLogin.vpnModelPrefix file
  let desiredPrefix := if enable && modelPrefix.isEmpty then generated
    else if !enable && before == relay && modelPrefix == generated then "" else modelPrefix
  if desired == before && desiredPrefix == modelPrefix then return .ok ()
  let patch := JVal.obj #[("name", .str file), ("proxy_url", .str desired)]
  let patch := if desiredPrefix == modelPrefix then patch else patch.setField "prefix" (.str desiredPrefix)
  let .ok (200, _, some ack) ← sendJsonRequest "PATCH" (base ++ "/v8/management/credentials/fields")
      (some key) (some patch) #[] 4000 8192 | return .error "vpn_sidecar_update_failed"
  if ack.fieldStr? "status" != some "ok" then return .error "vpn_sidecar_update_failed"
  if (← readBinding base key file).toOption != some (desired, desiredPrefix) then return .error "vpn_sidecar_readback_failed"
  return .ok ()

/-- An Antigravity login can stay available to agy while the sidecar excludes
all models for this particular credential. Retain any individual exclusions
when changing the wildcard. Never return credential metadata to the caller. -/
private def exclusions? (credential : JVal) : Option (Array String) := do
  match (credential.field? "excluded_models").orElse (fun _ => credential.field? "excluded-models") with
  | none | some .null => return #[]
  | some (.arr values) => values.mapM JVal.asStr?
  | _ => none

def alternativeRouterAccess (base key file : String) (allowed? : Option Bool) : IO (Except String Bool) := do
  let unavailable := "router_access_unavailable"
  if !validManagement base || key.isEmpty || !file.endsWith ".json" || file.contains '/' || file.contains '\\' then
    return .error unavailable
  let .ok credential ← readCredential base key file | return .error unavailable
  unless credential.fieldStr? "type" == some "antigravity" do return .error unavailable
  let some before := exclusions? credential | return .error unavailable
  let allowed := !before.contains "*"
  let some next := allowed? | return .ok allowed
  if next == allowed then return .ok allowed
  let after := if next then before.filter (· != "*") else before.push "*"
  let patch := JVal.obj #[("name", .str file), ("excluded_models", .arr (after.map JVal.str))]
  let .ok (200, _, some ack) ← sendJsonRequest "PATCH" (base ++ "/v8/management/credentials/fields")
      (some key) (some patch) #[] 4000 8192 | return .error unavailable
  unless ack.fieldStr? "status" == some "ok" do return .error unavailable
  let .ok updated ← readCredential base key file | return .error unavailable
  if exclusions? updated != some after then return .error "router_access_readback_failed"
  return .ok next

end OrbCore.AccountVpnSidecar
