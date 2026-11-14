import OrbCore.Control

namespace OrbCore.PrivdNodeAuthTests

open OrbCore.Store OrbCore.Control OrbCore.Managed OrbCore.RemoteFleetAndRelay
open OrbBin.Json OrbBin.PosixExt LeanSys.Http

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"privd node auth: {label}")

private def nimrudTok := "synthetic-nimrud-node-token-0123456789"
private def ashurTok := "synthetic-ashur-node-token-9876543210"
private def twinTok := "synthetic-shared-by-two-nodes-token"
private def wildcardTok := "synthetic-node-named-all-token"
private def managedTok := "synthetic-managed-machine-node-token"

private def tokenEnvs : Array (String × String) := #[
  ("ORB_TEST_PRIVD_NIMRUD_TOKEN", nimrudTok), ("ORB_TEST_PRIVD_ASHUR_TOKEN", ashurTok),
  ("ORB_TEST_PRIVD_TWIN_TOKEN", twinTok), ("ORB_TEST_PRIVD_ALL_TOKEN", wildcardTok)]

/-- `POST /api/privilege-access/verify-and-log` as `orb-privd` calls it from a fleet node: the node's
    own token plus the mission's lease. Runs through the real dispatcher. -/
def run (root : String) : IO Unit := do
  let .ok store ← openCoreStore (root ++ "/privd-node-auth")
    | throw (IO.userError "privd node auth fixture store")
  let .ok mc ← openManagedComputeStore (root ++ "/privd-node-auth-managed.db")
    | do closeCoreStore store; throw (IO.userError "privd node auth managed store")
  try
    setenvVar "SANDBOXED_REMOTE_NODES"
      ("nimrud=http://10.99.0.2:1|ORB_TEST_PRIVD_NIMRUD_TOKEN,ashur=http://10.99.0.3:1|ORB_TEST_PRIVD_ASHUR_TOKEN," ++
       "twin-a=http://10.99.0.4:1|ORB_TEST_PRIVD_TWIN_TOKEN,twin-b=http://10.99.0.5:1|ORB_TEST_PRIVD_TWIN_TOKEN," ++
       "all=http://10.99.0.6:1|ORB_TEST_PRIVD_ALL_TOKEN,tokenless=http://10.99.0.7:1|ORB_TEST_PRIVD_UNSET_TOKEN")
    for (name, value) in tokenEnvs do setenvVar name value
    let now : UInt64 := 1000
    let sql (db : OrbBin.Sqlite.SqliteDb) (query : String) (args : Array String := #[]) : IO (Array (Array String)) := do
      match ← execParamQuery db query args with
      | .ok rows => pure rows
      | .error e => throw (IO.userError s!"privd node auth: fixture query failed: {e}")

    -- The one mechanism: the token Core already holds for a static node, exact and unambiguous.
    check ((← authenticateStaticNodeToken? nimrudTok) == some "nimrud" &&
      (← authenticateStaticNodeToken? ("  " ++ ashurTok ++ " ")) == some "ashur") "a node token names its node"
    for bad in #["", " ", "garbage", (nimrudTok.dropEnd 1).toString, nimrudTok ++ "x", nimrudTok.toUpper,
        twinTok, managedTok, "ORB_TEST_PRIVD_NIMRUD_TOKEN"] do
      check ((← authenticateStaticNodeToken? bad).isNone) "an unknown, partial or shared token names nobody"

    discard <| sql store.missionsDb
      "INSERT INTO users(id,username,password_hash,role) VALUES('admin','admin','synthetic-hash','admin'),('bob','bob','synthetic-hash','member');"
    for (id, tags) in #[("m-nimrud", "[\"remote-node:nimrud\"]"), ("m-ashur", "[\"remote-node:ashur\"]"), ("m-core", "[]")] do
      discard <| sql store.missionsDb "INSERT INTO missions(id,owner_user_id,project,tags) VALUES(?1,'admin','p',?2);" #[id, tags]
    -- A managed machine's node credential, as Core stores it.
    discard <| sql mc.db
      "INSERT OR REPLACE INTO managed_node_tokens(machine_id,node_id,node_token,enroll_token,node_boot_epoch) VALUES('vm1','managed-vm1',?1,'synthetic-enroll',1);"
      #[managedTok]
    let units := "[\"sandboxed-sh.service\"]"
    let lease (token mission host : String) : PrivilegeLeaseRecord := {
      grantId := "grant-" ++ token, leaseToken := token, missionId := mission, targetHost := host,
      scope := "service_deploy", allowedUnitsJson := units, expiresAtEpoch := now + 300 }
    let save (l : PrivilegeLeaseRecord) : IO Unit := do
      let .ok () ← upsertPrivilegeLease store l | throw (IO.userError "privd node auth lease fixture")
    for l in #[lease "lease-nimrud" "m-nimrud" "nimrud", lease "lease-ashur" "m-ashur" "ashur",
        lease "lease-self-nimrud" "m-nimrud" "self", lease "lease-self-core" "m-core" "self",
        lease "lease-all" "m-core" "all", lease "lease-managed" "m-core" "managed-vm1",
        { (lease "lease-expired" "m-nimrud" "nimrud") with expiresAtEpoch := now },
        { (lease "lease-revoked" "m-nimrud" "nimrud") with revoked := true },
        { (lease "lease-unsigned" "m-nimrud" "nimrud") with biometricSigned := false }] do
      save l

    let bunkerRef ← IO.mkRef (0 : UInt8)
    let st : CoreAppState := {
      cfg := { instanceName := "prod", jwtSecret := "synthetic-privd-jwt-secret-not-shared" }, store := store,
      searchIdx? := none, managedRef := ← IO.mkRef {}, chainsRef := ← IO.mkRef #[],
      proxyCooldownsRef := ← IO.mkRef #[], seqRef := ← IO.mkRef 1,
      bunkerStateRef? := some bunkerRef, managedStore? := some mc }
    let send (authHeaders body : String) : IO (Nat × JVal) := do
      let wire := s!"POST /api/privilege-access/verify-and-log HTTP/1.1\r\nHost: localhost\r\n{authHeaders}Content-Length: {body.utf8ByteSize}\r\n\r\n{body}"
      let .ok request := parseRequest wire.toUTF8 none | throw (IO.userError "privd node auth HTTP fixture")
      let .ok response ← dispatchCoreRequest st request now | throw (IO.userError "privd node auth HTTP dispatch")
      let text := (String.fromUTF8? response.body).getD ""
      for secret in #[nimrudTok, ashurTok, twinTok, wildcardTok, managedTok] do
        check ((text.splitOn secret).length == 1) "a response never echoes a node token"
      return (response.status, (OrbBin.Json.parse text).toOption.getD .null)
    let bearer (token : String) : String := s!"Authorization: Bearer {token}\r\n"
    let restart := #["systemctl", "restart", "sandboxed-sh.service"]
    let body (mission leaseToken target claimedExec : String) (argv : Array String := restart)
        (extra : Array (String × JVal) := #[]) : String :=
      renderCompact (.obj (#[("mission_id", .str mission), ("lease_token", .str leaseToken),
        ("target_host", .str target), ("executing_host", .str claimedExec),
        ("command", .str ("[pre-exec] " ++ String.intercalate " " argv.toList)),
        ("argv", .arr (argv.map .str))] ++ extra))
    let allowed (r : Nat × JVal) : Bool :=
      r.1 == 200 && r.2.fieldBool? "allow_exec" == some true && r.2.fieldBool? "allowed" == some true
    let denied (r : Nat × JVal) (error : String) : Bool :=
      r.1 == 403 && r.2.fieldBool? "allow_exec" == some false && r.2.fieldStr? "error" == some error
    let auditCount : IO Nat := do
      let rows ← sql store.missionsDb "SELECT COUNT(*) FROM privilege_audit_log;"
      pure (((rows[1]?.bind (·[0]?)).bind String.toNat?).getD 0)
    -- Last audit row as (grant, mission, executing host, allowed).
    let lastAudit : IO (Array String) := do
      let rows ← sql store.missionsDb
        "SELECT grant_id,mission_id,executing_host,allowed FROM privilege_audit_log ORDER BY id DESC LIMIT 1;"
      pure (rows[1]?.getD #[])

    -- 1. A node's token plus a lease for that node: allowed, recorded under the authenticated node.
    let ok ← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud")
    check (allowed ok && ok.2.fieldStr? "grant_id" == some "grant-lease-nimrud" &&
      ok.2.fieldStr? "scope" == some "service_deploy") "node token with a valid lease for that node is allowed"
    check ((← lastAudit) == #["grant-lease-nimrud", "m-nimrud", "node:nimrud", "1"])
      "an allow is audited with the authenticated node identity"
    check (allowed (← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "nimrud" "nimrud")))
      "the node may name itself as the target"
    -- The body's executing_host is a claim; the token decides.
    check (allowed (← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "some-other-hostname")))
      "a node caller's executing_host claim is ignored"
    check ((← lastAudit)[2]? == some "node:nimrud") "the audit records the authenticated node, not the claim"

    -- 2. The same lease presented with another node's token is refused, whatever the body claims.
    for (target, claimed) in #[("self", "ashur"), ("self", "nimrud"), ("nimrud", "nimrud"), ("self", ""), ("all", "nimrud")] do
      check (denied (← send (bearer ashurTok) (body "m-nimrud" "lease-nimrud" target claimed)) "lease_denied")
        s!"another node cannot verify a lease for nimrud (target={target}, claimed={claimed})"
      check ((← lastAudit) == #["grant-lease-nimrud", "m-nimrud", "node:ashur", "0"])
        "a cross-node denial is audited under the node that asked"
    check (denied (← send (bearer nimrudTok) (body "m-ashur" "lease-ashur" "ashur" "ashur")) "lease_denied" &&
      denied (← send (bearer nimrudTok) (body "m-ashur" "lease-ashur" "self" "ashur")) "lease_denied")
      "a node cannot verify another node's lease by claiming to be it"
    check (denied (← send (bearer ashurTok) (body "m-nimrud" "lease-nimrud" "self" "ashur" restart #[("exit_code", .nat 0)]))
      "lease_denied") "a post-exec log for another node's lease is refused too"

    -- 3. No valid second factor: 401 before the lease is looked at, and nothing is audited.
    let before ← auditCount
    for headers in #["", bearer "garbage", bearer (nimrudTok ++ "x"), bearer (nimrudTok.dropEnd 1).toString,
        bearer "lease-nimrud", bearer twinTok, bearer wildcardTok, "Authorization: Basic " ++ nimrudTok ++ "\r\n",
        "X-Orb-Node-Token: " ++ nimrudTok ++ "\r\n"] do
      let r ← send headers (body "m-nimrud" "lease-nimrud" "self" "nimrud")
      check (r.1 == 401 && r.2.fieldBool? "allow_exec" == some false) "unknown, ambiguous or missing token is 401"
    -- 4. Managed machines are not fleet nodes here: their node token authenticates nothing.
    for leaseToken in #["lease-managed", "lease-all", "lease-nimrud"] do
      let r ← send (bearer managedTok ++ "X-Orb-Machine-Id: vm1\r\nX-Orb-Boot-Epoch: 1\r\n")
        (body "m-core" leaseToken "self" "managed-vm1")
      check (r.1 == 401) "a managed machine's node token is refused"
    check ((← auditCount) == before) "unauthenticated callers write no audit rows"

    -- 5. A "self" lease names no node, so the mission's placement must be the caller.
    check (allowed (← send (bearer nimrudTok) (body "m-nimrud" "lease-self-nimrud" "self" "nimrud")))
      "a self lease is honoured on the node its mission is placed on"
    check (denied (← send (bearer ashurTok) (body "m-nimrud" "lease-self-nimrud" "self" "ashur")) "lease_denied")
      "a self lease is refused on a node its mission is not placed on"
    check (denied (← send (bearer nimrudTok) (body "m-core" "lease-self-core" "self" "nimrud")) "lease_denied")
      "a self lease of a mission Core does not place on a node is refused there"
    check (allowed (← send (bearer ashurTok) (body "m-core" "lease-all" "self" "ashur")))
      "an explicit all-hosts lease stays valid on any authenticated node"
    check ((← lastAudit) == #["grant-lease-all", "m-core", "node:ashur", "1"]) "all-hosts allow names the node"

    -- 6. Every existing lease check still binds a node caller.
    check (denied (← send (bearer nimrudTok) (body "m-ashur" "lease-nimrud" "self" "nimrud")) "lease_denied")
      "the lease stays bound to its mission"
    check (denied (← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud"
      #["systemctl", "restart", "sshd.service"])) "lease_denied") "allowed units still confine a node caller"
    check (denied (← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud" #[])) "lease_denied")
      "an empty command is still refused"
    for leaseToken in #["lease-expired", "lease-revoked", "lease-unsigned"] do
      check (denied (← send (bearer nimrudTok) (body "m-nimrud" leaseToken "self" "nimrud")) "lease_denied")
        s!"{leaseToken} is refused for a node caller"
    check (denied (← send (bearer nimrudTok) (body "m-nimrud" "no-such-lease" "self" "nimrud")) "unknown_lease")
      "an unknown lease is refused"
    check ((← lastAudit) == #["", "m-nimrud", "node:nimrud", "0"]) "an unknown lease is audited under the node"
    save { (lease "lease-bad-scope" "m-nimrud" "nimrud") with scope := "ops_admin" }
    check (denied (← send (bearer nimrudTok) (body "m-nimrud" "lease-bad-scope" "self" "nimrud")) "unknown_privilege_scope")
      "an unknown scope is refused"
    check ((← send (bearer nimrudTok) (body "" "lease-nimrud" "self" "nimrud")).1 == 403 &&
      (← send (bearer nimrudTok) "not json").1 == 400) "missing fields and bad JSON fail closed"

    -- 7. Bunker fails closed for a node caller and the denial is audited.
    for level in #[(1 : UInt8), 2] do
      bunkerRef.set level
      check (denied (← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud")) "bunker_active")
        "bunker denies a node caller"
      check ((← lastAudit) == #["grant-lease-nimrud", "m-nimrud", "node:nimrud", "0"]) "a bunker denial is audited"
    bunkerRef.set 0
    check (allowed (← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud")))
      "the node path recovers when the bunker is lifted"

    -- 8. The admin path is unchanged: same answers, executing_host recorded as the caller states it.
    let adminJwt := mintSessionToken st.cfg.jwtSecret (now + 600)
    check (allowed (← send (bearer adminJwt) (body "m-nimrud" "lease-nimrud" "self" "nimrud")))
      "admin bearer verifies a lease as before"
    check ((← lastAudit) == #["grant-lease-nimrud", "m-nimrud", "nimrud", "1"]) "admin audit rows keep the stated host"
    check (allowed (← send (bearer adminJwt) (body "m-ashur" "lease-ashur" "ashur" "ashur")) &&
      allowed (← send (bearer adminJwt) (body "m-core" "lease-self-core" "self" "anywhere")))
      "admin bearer is not bound to a node"
    check (denied (← send (bearer adminJwt) (body "m-nimrud" "lease-nimrud" "self" "ashur")) "lease_denied" &&
      denied (← send (bearer adminJwt) (body "m-nimrud" "lease-nimrud" "self" "nimrud"
        #["systemctl", "restart", "sshd.service"])) "lease_denied")
      "admin bearer keeps the existing host and unit checks"
    bunkerRef.set 1
    check (denied (← send (bearer adminJwt) (body "m-nimrud" "lease-nimrud" "self" "nimrud")) "bunker_active")
      "bunker still denies the admin path"
    bunkerRef.set 0
    let some member ← getUserById? store "bob" | throw (IO.userError "privd node auth member fixture")
    let memberJwt := mintSessionTokenV2 st.cfg.jwtSecret member.id member.role member.sessionEpoch (now + 600)
    check (denied (← send (bearer memberJwt) (body "m-nimrud" "lease-nimrud" "self" "nimrud")) "admin_required")
      "a non-admin user is still refused"

    -- 9. Removing the node from the fleet, or its token from Core, removes the authority.
    unsetenvVar "ORB_TEST_PRIVD_NIMRUD_TOKEN"
    check ((← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud")).1 == 401)
      "a node whose token Core no longer holds is 401"
    setenvVar "ORB_TEST_PRIVD_NIMRUD_TOKEN" nimrudTok
    setenvVar "SANDBOXED_REMOTE_NODES" "ashur=http://10.99.0.3:1|ORB_TEST_PRIVD_ASHUR_TOKEN"
    check ((← send (bearer nimrudTok) (body "m-nimrud" "lease-nimrud" "self" "nimrud")).1 == 401)
      "a node no longer registered is 401"
  finally
    unsetenvVar "SANDBOXED_REMOTE_NODES"
    for (name, _) in tokenEnvs do unsetenvVar name
    closeManagedComputeStore mc
    closeCoreStore store

end OrbCore.PrivdNodeAuthTests
