import OrbCore.Control

namespace OrbCore.DevOperatorTests

open OrbCore.Store OrbCore.DevOperator OrbCore.Control OrbBin.Json LeanSys.Http

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"dev operator: {label}")

def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore (root ++ "/dev-operator")
    | throw (IO.userError "dev operator fixture store")
  try
    let .ok childEnv ← runCommand "/usr/bin/env" #[] | throw (IO.userError "sanitized command environment")
    check ((childEnv.splitOn "\n").filter (!·.isEmpty) |>.all (fun line =>
      line.startsWith "PATH=" || line.startsWith "LANG=")) "host tooling inherits no Core credentials"
    let now : UInt64 := 1000
    let .ok () ← upsertMission store {
      id := "owner", title := "Orb development", status := "awaiting_user", backend := "codex",
      modelOverride := "", workingDirectory := root, updatedAt := "2026-11-13T00:00:00Z", ownerUserId := "admin" }
      | throw (IO.userError "dev mission fixture")
    let lease : PrivilegeLeaseRecord := {
      grantId := "dev-grant", leaseToken := "synthetic-dev-pass", missionId := "owner",
      targetHost := "dev", scope := "dev_operator", expiresAtEpoch := 2000 }
    let save (l : PrivilegeLeaseRecord) : IO Unit := do
      let .ok () ← upsertPrivilegeLease store l | throw (IO.userError "dev lease fixture")
    save lease
    let request ← OrbCore.SecretAndApproval.mcpRequestPrivilegedAccess (some store) store.rootDir
      "owner" "mission-session" "dev_operator" "prod" "test dev deployment" #["sandboxed-sh-prod.service"] 999 now
    check (request.fieldStr? "state" == some "pending" && request.fieldStr? "target_host" == some "dev" &&
      request.fieldNat? "ttl_minutes" == some 240 && (request.field? "allowed_unit").getD .null == .null)
      "dev grant requires approval, fixes the dev target and clamps its TTL without arbitrary units"
    for denied in #[{ lease with revoked := true }, { lease with biometricSigned := false },
        { lease with scope := "service_deploy" }, { lease with targetHost := "self" },
        { lease with expiresAtEpoch := now }, { lease with expiresAtEpoch := now + 14401 },
        { lease with missionId := "" }] do
      check (!leaseAllowed denied now) "lease scope, host, biometric, expiry and revocation are mandatory"
    for denied in #[{ lease with revoked := true }, { lease with biometricSigned := false },
        { lease with scope := "root_exec" }, { lease with expiresAtEpoch := now },
        { lease with missionId := "deleted-mission" }] do
      save denied
      check ((← activeLease? store lease.leaseToken now).isNone) "persisted invalid leases fail closed"
    save lease
    let effects ← IO.mkRef (#[] : Array (String × Array String))
    let runner := fun cmd argv => do
      effects.modify (·.push (cmd, argv))
      return .ok "synthetic-journal"
    let args : JVal := .obj #[("grant_id", .str lease.grantId)]
    for mission in #["other-mission", ""] do
      for tool in #["get_dev_access", "deploy_dev", "read_dev_logs"] do
        check (!(← call store mission tool args now runner).isOk) "no grant reuse by another mission or direct session"
    check (← effects.get).isEmpty "unauthorized calls have no host effects"
    let externalListing ← OrbCore.SecretAndApproval.mcpListPrivilegedAccess store store.rootDir "" now "unrelated-session" true
    check (((externalListing.fieldArr? "grants").getD #[]).isEmpty)
      "external sessions cannot enumerate or steal another mission's dev or host lease"
    let .ok pass ← call store "owner" "get_dev_access" args now runner
      | throw (IO.userError "dev pass redemption")
    let bearer := (pass.fieldStr? "token").getD ""
    check (bearer == tokenPrefix ++ lease.leaseToken && pass.fieldStr? "instance" == some "dev" &&
      pass.fieldUInt64? "expires_at" == some lease.expiresAtEpoch) "opaque dev-only bearer and bounded expiry"
    let issuerCalls ← IO.mkRef (0 : Nat)
    let issuer := fun _ => do issuerCalls.modify (· + 1); return some (now + 600)
    check ((← tokenExpiry? store false bearer now issuer).isNone && (← issuerCalls.get) == 0)
      "prod rejects dev bearer before any issuer/network lookup"
    check ((← tokenExpiry? store true bearer now issuer) == some 2000 && (← issuerCalls.get) == 0)
      "local lease is checked live without a remote lookup"
    check ((← tokenExpiry? store true (tokenPrefix ++ "remote") now issuer) == some 1600 && (← issuerCalls.get) == 1)
      "cross-instance redemption asks the issuer"
    for badExpiry in #[now, now - 1, now + 14401] do
      check ((← tokenExpiry? store true (tokenPrefix ++ "remote") now (fun _ => pure (some badExpiry))).isNone)
        "issuer expiry cannot authorize expired or overlong access"
    check ((← tokenExpiry? store true (tokenPrefix ++ "remote") now (fun _ => pure none)).isNone)
      "issuer failure denies access"
    let sha := String.ofList (List.replicate 40 'a')
    check ((← call store "owner" "deploy_dev" (args.setField "sha" (.str sha)) now runner).isOk)
      "approved exact commit deployment"
    check ((← effects.get) == #[("/usr/local/sbin/orb-deploy", #["--detach", sha, "--dev-only"])])
      "Core always supplies dev-only and detached flags, with no shell"
    for bad in #["master", "--prod", "a; id", sha ++ " --prod", String.ofList (List.replicate 40 'G')] do
      check (!(← call store "owner" "deploy_dev" (args.setField "sha" (.str bad)) now runner).isOk)
        "reject refs, flags, shell text and malformed SHAs"
    check ((← effects.get).size == 1) "invalid commits never execute"
    check ((← call store "owner" "read_dev_logs" (args.setField "lines" (.nat 99999)) now runner).isOk)
      "approved bounded dev logs"
    check (((← effects.get)[1]?) == some ("/usr/bin/journalctl", #["--unit=sandboxed-sh-dev.service",
      "--lines=500", "--no-pager", "--output=cat"])) "journal arguments fix the dev unit and enforce a bound"
    let .error err ← call store "owner" "read_dev_logs" args now (fun _ _ => pure (.error "sensitive failure"))
      | throw (IO.userError "failed command unexpectedly succeeded")
    check (err == "dev_operator_command_failed") "subprocess failures never disclose upstream output"
    save { lease with revoked := true }
    check ((← activeLease? store lease.leaseToken now).isNone &&
      !(← call store "owner" "deploy_dev" (args.setField "sha" (.str sha)) now runner).isOk)
      "revocation stops redemption and host operations immediately"
    save lease
    let .ok () ← writePersistedBunkerState store 1 | throw (IO.userError "bunker fixture")
    check ((← tokenExpiry? store true bearer now issuer).isNone &&
      (← tokenExpiry? store true (tokenPrefix ++ "remote") now issuer).isNone && (← issuerCalls.get) == 1)
      "local bunker blocks local and remote grants before contacting issuer"
    let .ok () ← writePersistedBunkerState store 0 | throw (IO.userError "unbunker fixture")
    let .ok _ ← execParamQuery store.missionsDb
      "INSERT INTO users(id,username,password_hash,role) VALUES('admin','admin','synthetic-hash','admin');" #[]
      | throw (IO.userError "admin fixture")
    let st : CoreAppState := {
      cfg := { instanceName := "dev", jwtSecret := "synthetic-dev-jwt-secret-not-shared" }, store := store,
      searchIdx? := none, managedRef := ← IO.mkRef {}, chainsRef := ← IO.mkRef #[],
      proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1 }
    let headers := #[("Authorization", "Bearer " ++ bearer)]
    let some principal ← resolveCallerPrincipal? st headers now
      | throw (IO.userError "dev bearer did not resolve")
    check (principal.role == "admin" && principal.isDevOperator && !principal.isLegacyUnscoped)
      "dev bearer resolves to current enabled bootstrap admin with explicit dev provenance"
    check ((← resolveCallerPrincipal? { st with cfg := { st.cfg with instanceName := "prod" } } headers now).isNone)
      "same bearer cannot authenticate prod even with identical stores"
    let send (method path token body : String) : IO CoreHttpResponse := do
      let wire := s!"{method} {path} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok request := parseRequest wire.toUTF8 none | throw (IO.userError "dev HTTP fixture")
      let .ok response ← dispatchCoreRequest st request now | throw (IO.userError "dev HTTP dispatch")
      return response
    for path in #["/api/mcp/session", "/api/mcp/external-sessions", "/api/privilege-access/request",
        "/api/approvals/queue", "/api/system/deploy", "/api/system/hermes-assistant/control",
        "/api//system/hermes-assistant/control", "/api/software/updates", "/api/secrets", "/api/bitwarden/status", "/api/workspaces/host/shell",
        "/api/settings", "/api/settings/restore", "/api/proxy-keys", "/api/control/auth/codex"] do
      check ((← send "POST" path bearer "{}").status == 403) s!"dev bearer excludes host and independent credentials: {path}"
    let fixtureBody := "{\"username\":\"isolation_fixture\",\"password\":\"synthetic-member-password-123\",\"role\":\"member\",\"daily_spend_cap_cents\":0}"
    let .ok fixtureDoc := OrbBin.Json.parse fixtureBody | throw (IO.userError "dev account fixture")
    for bad in #[fixtureDoc.setField "role" (.str "admin"), fixtureDoc.removeField "daily_spend_cap_cents",
        fixtureDoc.setField "daily_spend_cap_cents" (.nat 100), fixtureDoc.setField "unix_username" (.str "orb-admin")] do
      check ((← send "POST" "/api/admin/users" bearer (renderCompact bad)).status == 403)
        "dev pass cannot create an admin, uncapped member or assigned Linux identity"
    for (method, path, body) in #[("POST", "/api/admin/users/admin/reset-password", "{\"password\":\"synthetic-replacement-password\"}"),
        ("POST", "/api/admin/users/admin/password", "{\"password\":\"synthetic-replacement-password\"}"),
        ("PATCH", "/api/admin/users/admin", "{\"disabled\":true}"), ("DELETE", "/api/admin/users/admin", "")] do
      check ((← send method path bearer body).status == 403) "dev pass cannot change existing admin credentials or identity"
    let fixtureResponse ← send "POST" "/api/admin/users" bearer fixtureBody
    let fixture := ((OrbBin.Json.parseBytes fixtureResponse.body).toOption.bind (·.fieldStr? "id")).getD ""
    check (fixtureResponse.status == 201 && !fixture.isEmpty) "dev pass can create zero-budget test member"
    for body in #["{\"role\":\"admin\"}", "{\"unix_username\":\"orb-admin\"}"] do
      check ((← send "PATCH" ("/api/admin/users/" ++ fixture) bearer body).status == 403)
        "dev pass cannot promote or remap its test member"
    check ((← send "PATCH" ("/api/admin/users/" ++ fixture) bearer "{\"disabled\":true}").status == 200)
      "dev pass can revoke its test member after acceptance"
    let some unchangedAdmin ← getUserById? store "admin" | throw (IO.userError "dev admin vanished")
    check (unchangedAdmin.passwordHash == "synthetic-hash" && !unchangedAdmin.disabled)
      "rejected credential escalation leaves the administrator unchanged"
    check ((← send "POST" "/api/mcp/call" bearer "{\"name\":\"memory_get_knowledge_tree\",\"arguments\":{}}").status == 403)
      "dev-only bearer cannot use the owner's shared personal memory broker"
    for suffix in #["controller", "controller/action", "crons", "crons/existing-job", "crons/existing-job/action"] do
      check ((← send "POST" ("/api/projects/example/" ++ suffix) bearer "{}").status == 403)
        "dev pass cannot enqueue work on the shared host scheduler"
    let response ← send "POST" "/api/dev-operator/verify" bearer ""
    check (response.status == 200 && (OrbBin.Json.parseBytes response.body).toOption.bind (·.fieldBool? "active") == some true)
      "issuer endpoint verifies capability without echoing token"
    let .ok verifyDoc := OrbBin.Json.parseBytes response.body | throw (IO.userError "issuer response JSON")
    check (verifyDoc.fieldStr? "token" == none && verifyDoc.fieldStr? "lease_token" == none &&
      verifyDoc.fieldStr? "jwt_secret" == none && verifyDoc.fieldUInt64? "expires_at" == some 2000)
      "issuer discloses expiry alone, with no usable credentials"
    let adminJwt := mintSessionToken st.cfg.jwtSecret (now + 600)
    let body := renderCompact (.obj #[("mission_id", .str "owner"), ("lease_token", .str lease.leaseToken),
      ("target_host", .str "dev"), ("executing_host", .str "dev"), ("command", .str "[exec]"),
      ("argv", .arr #[.str "id"])])
    check ((← send "POST" "/api/privilege-access/verify-and-log" adminJwt body).status == 403)
      "dev_operator never obtains generic host execution via scope ranking"
    save { lease with revoked := true }
    check ((← send "POST" "/api/dev-operator/verify" bearer "").status == 401)
      "issuer observes revocation immediately"
  finally closeCoreStore store

end OrbCore.DevOperatorTests
