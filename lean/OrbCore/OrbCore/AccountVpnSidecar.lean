import OrbBin.HttpClient

namespace OrbCore.AccountVpnSidecar

open OrbBin.HttpClient OrbBin.Json

/-- Management carries both an operator credential and an account-specific
proxy password, so a cleartext endpoint must be local to the service. -/
def validManagement (base : String) : Bool :=
  match parseUrl base with
  | .error _ => false
  | .ok url => url.isHttps || ["127.0.0.1", "::1", "[::1]"].contains url.host

private def readProxy (base key file : String) : IO (Except String String) := do
  let url := base ++ "/v8/management/credentials/download?name=" ++ urlEncodeComponent file
  let .ok (200, _, some credential) ← sendJsonRequest "GET" url (some key) none #[] 4000 262144
    | return .error "vpn_sidecar_credential_unavailable"
  let .obj _ := credential | return .error "vpn_sidecar_credential_unavailable"
  match credential.field? "proxy_url" with
  | none | some .null => return .ok ""
  | some (.str proxy) => return .ok proxy
  | _ => return .error "vpn_sidecar_proxy_invalid"

/-- Touch only the selected auth file. An existing third-party proxy belongs
to the operator. The management response, credential document, and URL never
escape this boundary or enter the error string. -/
def configure (base key file relay : String) (enable : Bool) : IO (Except String Unit) := do
  if !validManagement base || key.isEmpty || file.isEmpty || !file.endsWith ".json" ||
    file.contains '/' || file.contains '\\' || relay.isEmpty then return .error "vpn_sidecar_unavailable"
  let before ← match ← readProxy base key file with
    | .error e => return .error e
    | .ok value => pure value
  if !before.isEmpty && before != relay then return .error "vpn_sidecar_proxy_conflict"
  let desired := if enable then relay else ""
  if desired == before then return .ok ()
  let patch := JVal.obj #[("name", .str file), ("proxy_url", .str desired)]
  let .ok (200, _, some ack) ← sendJsonRequest "PATCH" (base ++ "/v8/management/credentials/fields")
      (some key) (some patch) #[] 4000 8192 | return .error "vpn_sidecar_update_failed"
  if ack.fieldStr? "status" != some "ok" then return .error "vpn_sidecar_update_failed"
  if (← readProxy base key file).toOption != some desired then return .error "vpn_sidecar_readback_failed"
  return .ok ()

end OrbCore.AccountVpnSidecar
