import OrbCore.Control

namespace OrbCore.ApprovalSignatureTests

open OrbCore.Store OrbCore.Control OrbCore.SecretAndApproval OrbBin.Json OrbBin.PosixExt LeanSys.Http

private def check (ok : Bool) (label : String) : IO Unit :=
  unless ok do throw (IO.userError s!"approval signature: {label}")

private def openssl (args : Array String) : IO Unit := do
  let out ← IO.Process.output { cmd := "openssl", args := args }
  check (out.exitCode == 0) s!"fixture openssl failed: {out.stderr}"

/-- Ephemeral test-only private key, never a production credential. -/
def makeSigner (dir : String) : IO (String × (String → IO String)) := do
  IO.FS.createDirAll dir
  let key := dir ++ "/key.pem"
  let pub := dir ++ "/public.der"
  openssl #["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key]
  openssl #["pkey", "-in", key, "-pubout", "-outform", "DER", "-out", pub]
  let publicKey := base64Encode (← IO.FS.readBinFile pub)
  let sign := fun (payload : String) => do
    IO.FS.writeFile (dir ++ "/payload") payload
    openssl #["dgst", "-sha256", "-sign", key, "-out", dir ++ "/signature", dir ++ "/payload"]
    return base64Encode (← IO.FS.readBinFile (dir ++ "/signature"))
  return (publicKey, sign)

def header (store : CoreStore) (sign : String → IO String) (path body : String)
    (now : UInt64) : IO String := do
  let request := renderCompact (.obj #[("method", .str "POST"), ("path", .str path), ("body", .str body)])
  let some (200, _, reply) ← dispatchSecretAndApprovalRoutes? store "" store.rootDir none true
    "POST" "/api/approvals/challenge" "/api/approvals/challenge" request.toUTF8 now
    | throw (IO.userError "approval challenge fixture")
  let .ok j := OrbBin.Json.parse reply | throw (IO.userError "challenge JSON")
  let signature ← sign ((j.fieldStr? "payload").getD "")
  return (j.fieldStr? "challenge_id").getD "" ++ ".test-device." ++ signature

def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore (root ++ "/approval-signatures")
    | throw (IO.userError "approval store fixture")
  try
    let (publicKey, sign) ← makeSigner (store.rootDir ++ "/signer")
    let now : UInt64 := 1000
    let .ok _ ← execParamQuery store.missionsDb
      "INSERT INTO users(id,username,password_hash,role) VALUES('approval-admin','approval-admin','synthetic','admin');" #[]
      | throw (IO.userError "approval admin fixture")
    let st : CoreAppState := {
      bootstrapAdminId := "approval-admin",
      cfg := { jwtSecret := "synthetic-approval-test-secret" }, store := store,
      searchIdx? := none, managedRef := ← IO.mkRef {}, chainsRef := ← IO.mkRef #[],
      proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1 }
    let jwt := OrbCore.LegacyHydrate.issueHs256Jwt st.cfg.jwtSecret
      "approval-admin" "approval-admin" now 10000
    let send := fun (method path body approval : String) (time : UInt64) => do
      let wire := s!"{method} {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {jwt}\r\nX-Paloma-Approval: {approval}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok req := parseRequest wire.toUTF8 none | throw (IO.userError "approval HTTP parse")
      let .ok res ← dispatchCoreRequest st req time | throw (IO.userError "approval HTTP dispatch")
      return (res.status, (OrbBin.Json.parseBytes res.body).toOption.getD .null)
    IO.FS.writeFile (store.rootDir ++ "/approval_enrollment_code") "fixture-enrollment-code\n"
    let enrolled ← send "POST" "/api/approvals/devices"
      (renderCompact (.obj #[("id", .str "test-device"), ("public_key", .str publicKey)])) "" now
    check (enrolled.1 == 403) "enrollment requires out-of-band code"
    IO.FS.writeFile (store.rootDir ++ "/approval_enrollment_code") "fixture-enrollment-code\n"
    let enrolled ← send "POST" "/api/approvals/devices"
      (renderCompact (.obj #[("id", .str "test-device"), ("public_key", .str publicKey),
        ("enrollment_code", .str "fixture-enrollment-code")])) "" now
    check (enrolled.1 == 201) "enroll fixture"
    let newRequest := fun (scope : String) => do
      let result ← mcpRequestPrivilegedAccess (some store) store.rootDir "" "test-session" scope "self"
        "signature regression" #[] 30 now
      return (result.fieldStr? "request_id").getD ""
    let id ← newRequest "ops_read"
    check (!id.isEmpty) "request fixture"
    let path := s!"/api/privilege-access/{id}/approve"
    let body := "{}"
    let leaseCount := do
      let .ok rows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM privilege_leases;" #[]
        | throw (IO.userError "lease count")
      return ((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    let good ← header store sign path body now
    let parts := good.splitOn "."
    let badSignature ← sign "different payload"
    let badCrypto := s!"{(parts[0]?).getD ""}.test-device.{badSignature}"
    for bad in #["", good ++ "x", good.replace ".test-device." ".unknown.", badCrypto] do
      check ((← send "POST" path body bad now).1 == 403) "unsigned, corrupt and unknown device refused"
    check ((← send "POST" path "{ }" good now).1 == 403) "exact wire body binding"
    check ((← send "POST" (path ++ "?other=1") body good now).1 == 403) "raw target binding"
    check ((← leaseCount) == 0) "rejected requests mint no lease"
    let expired ← header store sign path body now
    check ((← send "POST" path body expired (now + 120)).1 == 403) "expiry boundary refused"
    check ((← send "POST" path body good now).1 == 200) "valid signature mints lease"
    check ((← send "POST" path body good now).1 == 403) "same challenge replay refused"
    let fresh ← header store sign path body now
    check ((← send "POST" path body fresh now).1 == 409) "fresh challenge cannot reapprove request"
    check ((← leaseCount) == 1) "exactly one lease"
    let second ← newRequest "service_deploy"
    let legacy := s!"/api/privilege-access/requests/{second}/approve"
    check ((← send "POST" legacy body "" now).1 == 403) "legacy URL requires signature"
    let legacyHeader ← header store sign legacy body now
    check ((← send "POST" legacy body legacyHeader now).1 == 200) "legacy URL accepts valid signature"
    let third ← newRequest "root_exec"
    let batch := renderCompact (.obj #[("items", .arr #[.obj #[("kind", .str "privilege"), ("id", .str third)]]),
      ("confirm_critical", .bool true)])
    let batchPath := "/api/approvals/approve-all"
    check ((← send "POST" batchPath batch "" now).1 == 403) "batch requires signature"
    let batchHeader ← header store sign batchPath batch now
    check ((← send "POST" batchPath batch batchHeader now).1 == 200) "signed batch accepted"
    check ((← send "POST" batchPath batch batchHeader now).1 == 403) "batch replay refused"
    check ((← leaseCount) == 3) "three distinct authorized leases"
  finally
    closeCoreStore store

end OrbCore.ApprovalSignatureTests
