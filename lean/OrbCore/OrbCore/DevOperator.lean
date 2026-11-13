/- Dev-only authority backed by the existing hardware-approved privilege lease.
    The issuer remains the single owner of expiry/revocation; no JWT secret is shared. -/
import OrbCore.Store
import OrbBin.Json
import OrbNetLeaf.TlsHttp

namespace OrbCore.DevOperator

open OrbCore.Store OrbBin.Json OrbBin.PosixExt

def tokenPrefix : String := "orb-dev-v1."

def leaseAllowed (lease : PrivilegeLeaseRecord) (now : UInt64) : Bool :=
  lease.scope == "dev_operator" && lease.targetHost == "dev" &&
  !lease.missionId.isEmpty && lease.biometricSigned && !lease.revoked &&
  now < lease.expiresAtEpoch && lease.expiresAtEpoch - now ≤ 14400

def bunkerClear (store : CoreStore) : IO Bool := do
  let .ok rows ← execParamQuery store.missionsDb
    "SELECT bunker_state FROM core_boot_state WHERE singleton_id=1;" #[] | return false
  return (rows[1]?.bind (·[0]?)) == some "0"

/-- Every use consults the live lease and bunker state. A deleted issuing mission
    invalidates its pass; a missing DB/bunker record fails closed. -/
def activeLease? (store : CoreStore) (token : String) (now : UInt64) : IO (Option PrivilegeLeaseRecord) := do
  let some lease ← lookupPrivilegeLease? store token | return none
  unless leaseAllowed lease now do return none
  unless ← bunkerClear store do return none
  unless (← getMission? store lease.missionId).isSome do return none
  return some lease

/-- A token for another mission is never redeemable, even by a coordinator. -/
def missionLease? (store : CoreStore) (mission grantId : String) (now : UInt64) : IO (Option PrivilegeLeaseRecord) := do
  if mission.isEmpty || grantId.isEmpty then return none
  let .ok rows ← execParamQuery store.missionsDb
    "SELECT lease_token FROM privilege_leases WHERE grant_id=?1 AND mission_id=?2;" #[grantId, mission] | return none
  let some token := rows[1]?.bind (·[0]?) | return none
  activeLease? store token now

/-- Dev may use a local dev grant or ask the issuing prod Core over authenticated
    TLS. Transport/status/parse failures deny access. The opaque lease is sent
    only as a header, never in an URL, command argument, or log. -/
def tokenExpiry? (store : CoreStore) (isDev : Bool) (token : String) (now : UInt64)
    (verifyIssuer : String → IO (Option UInt64)) : IO (Option UInt64) := do
  unless isDev && token.startsWith tokenPrefix do return none
  unless ← bunkerClear store do return none
  let raw := (token.drop tokenPrefix.length).toString
  if let some lease ← activeLease? store raw now then return some lease.expiresAtEpoch
  let some expiry ← verifyIssuer raw | return none
  if now < expiry && expiry - now ≤ 14400 then return some expiry
  return none

def verifyIssuer (host token : String) : IO (Option UInt64) := do
  let .ok response ← OrbNetLeaf.TlsHttp.httpsRequest "POST" host 443
      "/api/dev-operator/verify" #[("Authorization", "Bearer " ++ tokenPrefix ++ token)]
      ByteArray.empty 4096 true 3000 | return none
  unless response.status == 200 do return none
  let .ok doc := OrbBin.Json.parseBytes response.body | return none
  unless doc.fieldBool? "active" == some true do return none
  return doc.fieldUInt64? "expires_at"

def validCommit (sha : String) : Bool :=
  sha.length == 40 && sha.toList.all (fun c => c.isDigit || (c ≥ 'a' && c ≤ 'f'))

/-- Caller-supplied flags, refs, paths, units and shell text never reach the host. -/
def deployArgs? (sha : String) : Option (Array String) :=
  if validCommit sha then some #["--detach", sha, "--dev-only"] else none

def logArgs (lines : Nat) : Array String :=
  #["--unit=sandboxed-sh-dev.service", "--lines=" ++ toString (min 500 (max 1 lines)),
    "--no-pager", "--output=cat"]

/-- A dev pass cannot mint independent sessions, approve privilege escalation,
    modify host services, read host files, or request a production deploy. -/
def restrictedPath (path : String) : Bool :=
  let path := "/" ++ String.intercalate "/" ((path.splitOn "/").filter (!·.isEmpty))
  path.startsWith "/api/auth/" || path.startsWith "/api/mcp/session" ||
  path.startsWith "/api/mcp/external-sessions" || path.startsWith "/api/privilege" ||
  path.startsWith "/api/approvals" || path.startsWith "/api/system/" ||
  path.startsWith "/api/software/" || path.startsWith "/api/fido/" ||
  path.startsWith "/api/bitwarden" || path.startsWith "/api/secrets" ||
  path.startsWith "/api/workspaces/" || path.startsWith "/api/desktop/" ||
  path.startsWith "/api/console/"

/-- Injectable command runner makes the exact host effect testable without
    executing a deploy or reading any real journal in self-tests. -/
def call (store : CoreStore) (mission tool : String) (args : JVal) (now : UInt64)
    (run : String → Array String → IO (Except String String)) : IO (Except String JVal) := do
  let grant := (args.fieldStr? "grant_id").getD ""
  let some lease ← missionLease? store mission grant now | return .error "active_dev_operator_grant_required"
  if tool == "get_dev_access" then
    return .ok (.obj #[("token", .str (tokenPrefix ++ lease.leaseToken)),
      ("url", .str "https://agent-backend-dev.thomas.md"),
      ("expires_at", .uint64 lease.expiresAtEpoch), ("role", .str "admin"), ("instance", .str "dev")])
  let (program, argv) ← if tool == "deploy_dev" then do
      let some argv := deployArgs? ((args.fieldStr? "sha").getD "") | return .error "full_commit_sha_required"
      pure ("/usr/local/sbin/orb-deploy", argv)
    else if tool == "read_dev_logs" then
      pure ("/usr/bin/journalctl", logArgs ((args.fieldNat? "lines").getD 100))
    else return .error "unknown_dev_operator_tool"
  -- Record the fixed operation, never credentials, journal contents or subprocess output.
  let .ok () ← appendPrivilegeAuditLog store lease.grantId mission "dev" "self"
      (tool ++ (if tool == "deploy_dev" then ":" ++ (args.fieldStr? "sha").getD "" else "")) true (toString now)
    | return .error "dev_operator_audit_failed"
  let .ok output ← run program argv | return .error "dev_operator_command_failed"
  if tool == "deploy_dev" then
    return .ok (.obj #[("accepted", .bool true), ("instance", .str "dev"),
      ("sha", .str ((args.fieldStr? "sha").getD ""))])
  return .ok (.obj #[("unit", .str "sandboxed-sh-dev.service"), ("log", .str output)])

def runCommand (program : String) (args : Array String) : IO (Except String String) := do
  try
    -- The Core environment may hold vault/session credentials. Host tooling
    -- receives a fixed utility PATH and locale, never that environment.
    let result ← IO.Process.output {
      cmd := program, args := args, inheritEnv := false,
      env := #[("PATH", some "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        ("LANG", some "C.UTF-8")] }
    if result.exitCode != 0 then return .error "command_failed"
    return .ok (result.stdout.take 262144).toString
  catch _ => return .error "command_failed"

end OrbCore.DevOperator
