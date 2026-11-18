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

structure Harness where
  now : UInt64
  send : String → String → String → String → UInt64 → IO (Nat × JVal)
  header : String → String → IO String
  sign : String → IO String
  newRequest : String → IO String
  leaseCount : IO Nat

private def approvePath (id : String) : String := s!"/api/privilege-access/{id}/approve"

def testUnsignedRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let (status, _) ← h.send "POST" (approvePath id) "{}" "" h.now
  check (status == 403) "unsigned approval is refused"

def testBadSignatureRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let signed ← h.header path "{}"
  let nonce := ((signed.splitOn ".")[0]?).getD ""
  let badSignature ← h.sign "a different payload"
  let (status, _) ← h.send "POST" path "{}" s!"{nonce}.test-device.{badSignature}" h.now
  check (status == 403) "signature that does not cover the challenge payload is refused"

def testUnknownDeviceRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let signed ← h.header path "{}"
  let (status, _) ← h.send "POST" path "{}" (signed.replace ".test-device." ".unknown.") h.now
  check (status == 403) "signature from an unenrolled device is refused"

def testWrongBodyRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let signed ← h.header path "{}"
  let (status, _) ← h.send "POST" path "{ }" signed h.now
  check (status == 403) "signature bound to different body bytes is refused"

def testWrongTargetRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let signed ← h.header path "{}"
  let (status, _) ← h.send "POST" (path ++ "?other=1") "{}" signed h.now
  check (status == 403) "signature bound to a different request target is refused"

def testExpiredRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let signed ← h.header path "{}"
  let (status, _) ← h.send "POST" path "{}" signed (h.now + 120)
  check (status == 403) "expired challenge is refused"

def testReplayRefused (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let signed ← h.header path "{}"
  let (first, _) ← h.send "POST" path "{}" signed h.now
  check (first == 200) "replay fixture first approval succeeds"
  let afterFirst ← h.leaseCount
  let (second, _) ← h.send "POST" path "{}" signed h.now
  check (second == 403) "already consumed challenge replay is refused"
  check ((← h.leaseCount) == afterFirst) "replay mints no second lease"

def testValidSignatureMintsLease (h : Harness) : IO Unit := do
  let id ← h.newRequest "ops_read"
  let path := approvePath id
  let before ← h.leaseCount
  let signed ← h.header path "{}"
  let (status, _) ← h.send "POST" path "{}" signed h.now
  check (status == 200) "valid request-bound signature mints a lease"
  check ((← h.leaseCount) == before + 1) "valid approval mints exactly one lease"

def testLegacyRouteRequiresSignature (h : Harness) : IO Unit := do
  let id ← h.newRequest "service_deploy"
  let path := s!"/api/privilege-access/requests/{id}/approve"
  let before ← h.leaseCount
  let (unsigned, _) ← h.send "POST" path "{}" "" h.now
  check (unsigned == 403) "legacy approval route requires a signature"
  check ((← h.leaseCount) == before) "unsigned legacy approval mints no lease"
  let signed ← h.header path "{}"
  let (status, _) ← h.send "POST" path "{}" signed h.now
  check (status == 200) "legacy approval route accepts a valid signature"

def testBatchRequiresSignature (h : Harness) : IO Unit := do
  let id ← h.newRequest "root_exec"
  let batch := renderCompact (.obj #[("items", .arr #[.obj #[("kind", .str "privilege"), ("id", .str id)]]),
    ("confirm_critical", .bool true)])
  let path := "/api/approvals/approve-all"
  let before ← h.leaseCount
  let (unsigned, _) ← h.send "POST" path batch "" h.now
  check (unsigned == 403) "batch approval requires a signature"
  check ((← h.leaseCount) == before) "unsigned batch approval mints no lease"
  let signed ← h.header path batch
  let (status, _) ← h.send "POST" path batch signed h.now
  check (status == 200) "batch approval accepts a valid signature"
  let (replay, _) ← h.send "POST" path batch signed h.now
  check (replay == 403) "batch challenge replay is refused"

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
    check (enrolled.1 == 403) "enrolment requires an out-of-band code"
    IO.FS.writeFile (store.rootDir ++ "/approval_enrollment_code") "fixture-enrollment-code\n"
    let enrolled ← send "POST" "/api/approvals/devices"
      (renderCompact (.obj #[("id", .str "test-device"), ("public_key", .str publicKey),
        ("enrollment_code", .str "fixture-enrollment-code")])) "" now
    check (enrolled.1 == 201) "enrol fixture"
    let newRequest := fun (scope : String) => do
      let result ← mcpRequestPrivilegedAccess (some store) store.rootDir "" "test-session" scope "self"
        "signature regression" #[] 30 now
      return (result.fieldStr? "request_id").getD ""
    let leaseCount : IO Nat := do
      let .ok rows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM privilege_leases;" #[]
        | throw (IO.userError "lease count")
      return ((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0
    let h : Harness := {
      now := now, send := send, sign := sign,
      header := fun path body => header store sign path body now,
      newRequest := newRequest, leaseCount := leaseCount }
    testUnsignedRefused h
    testBadSignatureRefused h
    testUnknownDeviceRefused h
    testWrongBodyRefused h
    testWrongTargetRefused h
    testExpiredRefused h
    testValidSignatureMintsLease h
    testReplayRefused h
    testLegacyRouteRequiresSignature h
    testBatchRequiresSignature h
  finally
    closeCoreStore store

end OrbCore.ApprovalSignatureTests
