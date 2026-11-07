/-
  OrbCore.SelfTest: End-to-End Verification Suite for Wave 4 `OrbCore` (`orb-core-test`):
  1. All 5 `OrbCore.Spec` `MetaGateSpec` gates (fail-closed `DEV_MODE=false` secrets, `DEV_MODE=true` non-loopback rejection, `:80/api/console/ws` JWT auth + conflicting-credential rejection, transfer fence, proxy failover, deploy unit allowlist).
  2. Live SQLite `CoreStore` (`missions.db`, `projects.db`, `ask.db`, `idempotency_keys.db`), parameterized queries, `BEGIN IMMEDIATE` machine-transfer fencing, privilege leases & audit log, automations & routing chains.
  3. `OrbCore.Search` conversation indexing & in-memory trigram SST lookup.
  4. All 9 `OrbCore.Harness` contract tests.
  5. `/v1/*` `OrbCore.Proxy` pre-first-byte `429`/`503` failover + hop-by-hop header sanitization.
  6. Live HTTP/1.1 + WebSocket dispatch (`/api/health`, `/api/auth/login` with `SANDBOXED_USERS`, `/v1/*` auth, `/api/privilege-access/verify-and-log` fail-closed vs valid lease, `/api/console/ws` `401` without JWT and `101` echoing `Sec-WebSocket-Protocol: jwt.<token>`).
  7. All 83 `OrbCore.HostTests` & optional `--emit-evidence-log <path>` receipt generation.
-/
import OrbCore

namespace OrbCore.SelfTest

open LeanSys.Posix
open LeanSys.Http
open LeanSys.Auth
open OrbCore.Spec
open OrbCore.Store
open OrbCore.Search
open OrbCore.Harness
open OrbCore.Proxy
open OrbCore.Managed
open OrbCore.Control
open OrbCore.HostTests

private def findFlag? (args : List String) (flag : String) : Option String :=
  match args with
  | [] => none
  | a :: b :: rest => if a == flag then some b else findFlag? (b :: rest) flag
  | [_] => none

private def exceptStrEq (a b : Except String String) : Bool :=
  match a, b with
  | .ok x, .ok y => x == y
  | .error x, .error y => x == y
  | _, _ => false

private def runR2bRound2Extras (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  -- Same-boot orphan mission cleanup: if a mission row is deleted while an intent/lease exists at the current boot,
  -- `recoverDispatchLeases` rolls back the orphaned reservation so the track is never wedged.
  let .ok () ← releaseDispatchTrackLease store "rsv-post-crash" "t5b"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: release rsv-post-crash failed"; return 1
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO dispatch_lease_intents(reservation_id,mission_id,project_slug,track,repo,authority_mode,reserved_disk_gib,phase,boot_epoch,created_at,updated_at) VALUES('rsv-ghost','m-deleted-ghost','orb','r2-track','Th0rgal/orb','writer',4,'active',2,'t5c','t5c');" #[]
  let _ ← execParamQuery store.projectsDb
    "INSERT INTO project_track_leases(project_slug,track,reservation_id,mission_id,repo,authority_mode,phase,boot_epoch,updated_at) VALUES('orb','r2-track','rsv-ghost','m-deleted-ghost','Th0rgal/orb','writer','active',2,'t5c');" #[]
  let .ok () ← recoverDispatchLeases store.missionsDb store.projectsDb 2
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: ghost-mission recoverDispatchLeases failed"; return 1
  let .ok () ← acquireDispatchTrackLease store {
    reservationId := "rsv-after-ghost", missionId := "m-w1", projectSlug := "orb",
    track := "r2-track", repo := "Th0rgal/orb", authorityMode := "writer",
    reservedDiskGib := 3, bootEpoch := 2, nowAt := "t5d"
  } | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: ghost mission wedged track lease"; return 1
  -- Duplicate caller-supplied mission `id` on `POST /api/control/missions` returns 409 without deleting or overwriting `m-w1`
  let dupCreateBody := "{\"id\":\"m-w1\",\"title\":\"Attempt overwrite\",\"project\":\"orb\",\"track\":\"r2-track\",\"repo\":\"Th0rgal/orb\",\"writer\":true}"
  let dupCreateRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {dupCreateBody.utf8ByteSize}\r\n\r\n{dupCreateBody}".toUTF8
  let .ok dupCreateReq := parseRequest dupCreateRaw none | do closeCoreStore store; return 1
  let .ok dupCreateResp ← dispatchCoreRequest appSt dupCreateReq nowSec | do closeCoreStore store; return 1
  let mW1Rows ← execParamQuery store.missionsDb "SELECT title,tags FROM missions WHERE id='m-w1';" #[]
  let .ok mW1Rs := mW1Rows
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: duplicate POST /api/control/missions deleted existing m-w1"; return 1
  let mW1Title := (mW1Rs[1]?.bind (·[0]?)).getD ""
  let mW1Tags := (mW1Rs[1]?.bind (·[1]?)).getD ""
  if dupCreateResp.status != 409 || mW1Title == "Attempt overwrite" || (mW1Tags.splitOn "disk-gib:3").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: duplicate mission id guard or lease tags projection failed: status={dupCreateResp.status} title={mW1Title} tags={mW1Tags}"
    return 1
  -- Cross-project repository/PR writer split-brain (`SM-08`): `m-w1` holds active writer lease on `Th0rgal/orb` under `orb`;
  -- a writer under a different project (`other-proj`) targeting the same `Th0rgal/orb` MUST fail with `repo_writer_conflict:m-w1` (HTTP 409),
  -- while a `readonly` consultant on the same repo under `other-proj` succeeds!
  let crossProjConflictBody := "{\"id\":\"m-cross-proj-w\",\"title\":\"Cross-project PR writer\",\"project\":\"other-proj\",\"track\":\"t-other\",\"github_pr\":\"Th0rgal/orb\",\"writer\":true}"
  let crossProjConflictRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {crossProjConflictBody.utf8ByteSize}\r\n\r\n{crossProjConflictBody}".toUTF8
  let .ok crossProjConflictReq := parseRequest crossProjConflictRaw none | do closeCoreStore store; return 1
  let .ok crossProjConflictResp ← dispatchCoreRequest appSt crossProjConflictReq nowSec | do closeCoreStore store; return 1
  let crossProjConflictStr := String.fromUTF8! crossProjConflictResp.body
  if crossProjConflictResp.status != 409 || (crossProjConflictStr.splitOn "repo_writer_conflict:m-w1").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cross-project repo writer split-brain not blocked: status={crossProjConflictResp.status} body={crossProjConflictStr}"
    return 1
  let crossProjRoBody := "{\"id\":\"m-cross-proj-ro\",\"title\":\"Cross-project readonly\",\"project\":\"other-proj\",\"track\":\"t-other-ro\",\"github_pr\":\"Th0rgal/orb\",\"writer\":false,\"estimated_disk_gib\":2,\"tags\":[\"custom:keep-me\"]}"
  let crossProjRoRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {crossProjRoBody.utf8ByteSize}\r\n\r\n{crossProjRoBody}".toUTF8
  let .ok crossProjRoReq := parseRequest crossProjRoRaw none | do closeCoreStore store; return 1
  let .ok crossProjRoResp ← dispatchCoreRequest appSt crossProjRoReq nowSec | do closeCoreStore store; return 1
  if crossProjRoResp.status != 201 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cross-project readonly mission rejected: status={crossProjRoResp.status}"
    return 1
  -- Verify custom non-system tag (`custom:keep-me`) survives lease acquisition and release
  let roTagRows ← execParamQuery store.missionsDb "SELECT tags FROM missions WHERE id='m-cross-proj-ro';" #[]
  let roTags := match roTagRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if (roTags.splitOn "custom:keep-me").length != 2 || (roTags.splitOn "disk-gib:2").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: custom mission tag lost on lease acquisition: {roTags}"
    return 1
  -- 64-bit wraparound disk-budget bypass (`2^34 + 1 = 17179869185`) MUST fail closed on both HTTP (`400`) and store (`invalid_reserved_disk_gib`)!
  let wrapDiskBody := "{\"id\":\"m-disk-wrap\",\"title\":\"Disk wrap\",\"project\":\"other-proj\",\"track\":\"t-wrap\",\"estimated_disk_gib\":17179869185,\"writer\":false}"
  let wrapDiskRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {wrapDiskBody.utf8ByteSize}\r\n\r\n{wrapDiskBody}".toUTF8
  let .ok wrapDiskReq := parseRequest wrapDiskRaw none | do closeCoreStore store; return 1
  let .ok wrapDiskResp ← dispatchCoreRequest appSt wrapDiskReq nowSec | do closeCoreStore store; return 1
  let wrapStoreLease ← acquireDispatchTrackLease store {
    reservationId := "rsv-wrap-direct", missionId := "m-cross-proj-ro", projectSlug := "other-proj",
    track := "t-wrap-2", repo := "", authorityMode := "readonly",
    reservedDiskGib := 17179869185, bootEpoch := 2, nowAt := "t5e"
  }
  if wrapDiskResp.status != 400 || wrapStoreLease.isOk then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: 64-bit disk wraparound was not rejected: http={wrapDiskResp.status}"
    return 1
  return 0

def runSuite (emitLogPath? : Option String) : IO UInt32 := do
  -- 1. Startup security fail-closed gates (`validateRuntimeSecurity`) + conflicting WS credential rejection
  let prodNoSecrets : CoreConfig := { devMode := false, host := "127.0.0.1" }
  let prodPlaceholder : CoreConfig := {
    devMode := false, host := "127.0.0.1",
    dashboardPassword := "strong-pass-1234", jwtSecret := "change-me"
  }
  let prodShortJwt : CoreConfig := {
    devMode := false, host := "127.0.0.1",
    dashboardPassword := "strong-pass-1234", jwtSecret := "too-short-secret"
  }
  let prodValid : CoreConfig := {
    devMode := false, host := "127.0.0.1",
    dashboardPassword := "ci-test-strong-passphrase",
    jwtSecret := "ci-test-random-jwt-secret-0123456789abcdef",
    usersJson := "[{\"username\":\"alice\",\"password\":\"alice-strong-pass-99\"}]",
    proxySecret := "proxy-secret-0123456789abcdef0123456789"
  }
  let prodUsersOnly : CoreConfig := {
    devMode := false, host := "127.0.0.1",
    jwtSecret := "ci-test-random-jwt-secret-0123456789abcdef",
    usersJson := "[{\"username\":\"bob\",\"password\":\"bob-strong-pass-9999\"}]"
  }
  let devNonLoopback : CoreConfig := { devMode := true, host := "0.0.0.0" }
  let devLoopback : CoreConfig := { devMode := true, host := "127.0.0.1" }
  if (validateRuntimeSecurity prodNoSecrets).isOk ||
     (validateRuntimeSecurity prodPlaceholder).isOk ||
     (validateRuntimeSecurity prodShortJwt).isOk ||
     !(validateRuntimeSecurity prodValid).isOk ||
     !(validateRuntimeSecurity prodUsersOnly).isOk ||
     (validateRuntimeSecurity devNonLoopback).isOk ||
     !(validateRuntimeSecurity devLoopback).isOk ||
     verifyConsoleWsAuth 1 1 1 0 1700000000 1700003600 != 0 ||
     verifyConsoleWsAuth 1 1 0 0 1700000000 1700003600 != 1 then
    IO.eprintln "[orb-core-test] FAIL: validateRuntimeSecurity or verifyConsoleWsAuth checks failed"
    return 1

  -- 2. Service-scoped VM prefix & deploy unit confinement (including path traversal rejection)
  if sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh-prod" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh-dev" != "orb-managed-dev-" ||
     !exceptStrEq (validateDeployServiceUnit "sandboxed-sh") (.ok "sandboxed-sh.service") ||
     !exceptStrEq (validateDeployServiceUnit "orb-node") (.ok "sandboxed-node.service") ||
     !exceptStrEq (validateDeployServiceUnit "orb-privd.service") (.ok "orb-privd.service") ||
     (validateDeployServiceUnit "../sandboxed-sh").isOk ||
     (validateDeployServiceUnit "../evil").isOk ||
     (validateDeployServiceUnit "sshd").isOk then
    IO.eprintln "[orb-core-test] FAIL: managed prefix or deploy unit confinement failed"
    return 1

  -- 3. Live SQLite `CoreStore` + Transfer Fence + Search Index
  let ts ← IO.monoNanosNow
  let tmpRoot := s!"/tmp/orb-core-selftest-{ts}"
  let .ok store ← openCoreStore tmpRoot
    | do IO.eprintln "[orb-core-test] FAIL: openCoreStore failed"; return 1
  let m1 : MissionRecord := {
    id := "m-alpha", title := "Verify Lean 4 Core", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "high", workingDirectory := tmpRoot,
    updatedAt := "2026-11-06T00:00:00Z", totalCostCents := 42
  }
  let .ok () ← upsertMission store m1 | do closeCoreStore store; return 1
  let .ok missionsJson ← listMissionsJson store | do closeCoreStore store; return 1
  if (missionsJson.splitOn "\"total_cost_cents\":42").length != 2 ||
     (missionsJson.splitOn "\"model_effort\":\"high\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: listMissionsJson mismatch: {missionsJson}"
    return 1
  let txReq : TransferRecord := {
    id := "tx-1", missionId := "m-alpha", requestKey := "rk-1", revision := 0,
    phase := "preparing", destination := "ashur",
    sourceRevision := "2026-11-06T00:00:00Z", sourceGeneration := 0,
    generation := 0, createdAt := "2026-11-06T00:01:00Z"
  }
  let .ok tx1 ← startMachineTransfer store txReq
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: first startMachineTransfer rejected"; return 1
  -- Second concurrent transfer on same mission MUST be fenced!
  let tx2Res ← startMachineTransfer store { txReq with id := "tx-2", requestKey := "rk-2" }
  if tx1.generation != 1 || tx2Res.isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: concurrent machine transfer was not fenced"
    return 1
  -- Idempotency roundtrip
  let .ok idem1 ← checkOrStoreIdempotency store "missions" "key-1" "{\"created\":1}" "t0" | do closeCoreStore store; return 1
  let .ok idem2 ← checkOrStoreIdempotency store "missions" "key-1" "{\"created\":2}" "t1" | do closeCoreStore store; return 1
  if idem1 != "{\"created\":1}" || idem2 != "{\"created\":1}" then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: idempotency_keys replay mismatch"
    return 1

  let .ok sIdx0 ← openSearchIndex s!"{tmpRoot}/search" | do closeCoreStore store; return 1
  let .ok sIdx1 ← indexConversation sIdx0 "m-alpha" "Pure Lean4 Turbo-Lean verified QUIC gateway" | do closeCoreStore store; return 1
  let sHits ← queryConversations sIdx1 "Turbo-Lean" 8
  if !sHits.contains "m-alpha" then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: OrbCore.Search trigram query missed indexed conversation"
    return 1

  -- 4. Harness contract tests (all 9 invariants)
  if !runAllHarnessContractTests then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: runAllHarnessContractTests failed"
    return 1

  -- 5. `/v1/*` Proxy pre-first-byte failover (`429` on primary -> `200` on backup) + header sanitization
  let chain : RoutingChain := {
    id := "c1", name := "primary-backup",
    targets := #[
      { accountId := "acct-1", provider := "openai", baseUrl := "https://api.openai.com", apiKey := "k1", modelId := "gpt" },
      { accountId := "acct-2", provider := "anthropic", baseUrl := "https://api.anthropic.com", apiKey := "k2", modelId := "claude" }
    ]
  }
  let proxyOut ← forwardProxyChain chain "POST" "/v1/responses" #[] "{}".toUTF8 (some fun tgt => do
    if tgt.accountId == "acct-1" then
      return .ok { status := 429, headers := #[], body := "rate_limited".toUTF8 }
    else
      return .ok {
        status := 200,
        headers := #[("Transfer-Encoding", "chunked"), ("Content-Type", "application/json"), ("X-Provider", "anthropic")],
        body := "{\"id\":\"resp_ok\"}".toUTF8
      })
  if proxyOut.status != 200 || proxyOut.selectedAccount != "acct-2" || proxyOut.attemptsUsed != 2 ||
     proxyOut.headers.any (fun (k, _) => k.toLower == "transfer-encoding") then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: forwardProxyChain failover or header sanitization mismatch"
    return 1

  -- 6. HTTP/WS Dispatch checks (`/api/health`, `SANDBOXED_USERS` login, `/v1/*` auth, privilege lease verification, WS subprotocol echo)
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let seqRef ← IO.mkRef (1 : UInt64)
  let appSt : CoreAppState := {
    cfg := prodValid, store := store, searchIdx? := some sIdx1,
    managedRef := managedRef, chainsRef := chainsRef, seqRef := seqRef
  }
  let nowSec : UInt64 := 1700001000
  let .ok healthReq := parseRequest "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toUTF8 none | do closeCoreStore store; return 1
  let .ok healthResp ← dispatchCoreRequest appSt healthReq nowSec | do closeCoreStore store; return 1
  let healthStr := String.fromUTF8! healthResp.body
  if healthResp.status != 200 ||
     (healthStr.splitOn "\"dev_mode\":false").length != 2 ||
     (healthStr.splitOn "\"auth_required\":true").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /api/health contract mismatch: {healthStr}"
    return 1

  -- Login with `SANDBOXED_USERS` account (`alice`)
  let loginBody := "{\"username\":\"alice\",\"password\":\"alice-strong-pass-99\"}"
  let loginRaw := s!"POST /api/auth/login HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {loginBody.utf8ByteSize}\r\n\r\n{loginBody}".toUTF8
  let .ok loginReq := parseRequest loginRaw none | do closeCoreStore store; return 1
  let .ok loginResp ← dispatchCoreRequest appSt loginReq nowSec | do closeCoreStore store; return 1
  if loginResp.status != 200 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: SANDBOXED_USERS login failed"
    return 1

  -- Unauthenticated `/v1/responses` MUST return 401; authenticated with `SANDBOXED_PROXY_SECRET` proceeds to chain (503 on empty chain)
  let v1UnauthRaw := "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}".toUTF8
  let .ok v1UnauthReq := parseRequest v1UnauthRaw none | do closeCoreStore store; return 1
  let .ok v1UnauthResp ← dispatchCoreRequest appSt v1UnauthReq nowSec | do closeCoreStore store; return 1
  let v1AuthRaw := (s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {prodValid.proxySecret}\r\nContent-Length: 2\r\n\r\n" ++ "{}").toUTF8
  let .ok v1AuthReq := parseRequest v1AuthRaw none | do closeCoreStore store; return 1
  let .ok v1AuthResp ← dispatchCoreRequest appSt v1AuthReq nowSec | do closeCoreStore store; return 1
  if v1UnauthResp.status != 401 || v1AuthResp.status != 503 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /v1/* auth gate mismatch ({v1UnauthResp.status}, {v1AuthResp.status})"
    return 1

  -- Privilege lease verification: unknown lease -> 403; valid stored lease -> 200
  let validJwt := mintSessionToken prodValid.jwtSecret (nowSec + 3600)
  let forgedPrivBody := "{\"mission_id\":\"m-alpha\",\"lease_token\":\"forged-lease-000\",\"target_host\":\"ashur\",\"executing_host\":\"ashur\",\"command\":\"systemctl status sandboxed-sh.service\"}"
  let forgedPrivRaw := s!"POST /api/privilege-access/verify-and-log HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {forgedPrivBody.utf8ByteSize}\r\n\r\n{forgedPrivBody}".toUTF8
  let .ok forgedPrivReq := parseRequest forgedPrivRaw none | do closeCoreStore store; return 1
  let .ok forgedPrivResp ← dispatchCoreRequest appSt forgedPrivReq nowSec | do closeCoreStore store; return 1
  if forgedPrivResp.status != 403 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: forged privilege lease was not rejected (got {forgedPrivResp.status})"
    return 1

  let .ok () ← upsertPrivilegeLease store {
    grantId := "grant-1", leaseToken := "lease-live-1234567890", missionId := "m-alpha",
    targetHost := "ashur", scope := "service_deploy", allowedUnitsJson := "[\"sandboxed-sh.service\"]",
    requireForceCmd := false, biometricSigned := true, revoked := false, expiresAtEpoch := nowSec + 300
  } | do closeCoreStore store; return 1
  -- Local orb-privd sends target_host="self" + executing_host="ashur" + argv
  let validPrivBody := "{\"mission_id\":\"m-alpha\",\"lease_token\":\"lease-live-1234567890\",\"target_host\":\"self\",\"executing_host\":\"ashur\",\"command\":\"systemctl restart sandboxed-sh.service\",\"argv\":[\"systemctl\",\"restart\",\"sandboxed-sh.service\"]}"
  let validPrivRaw := s!"POST /api/privilege-access/verify-and-log HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {validPrivBody.utf8ByteSize}\r\n\r\n{validPrivBody}".toUTF8
  let .ok validPrivReq := parseRequest validPrivRaw none | do closeCoreStore store; return 1
  let .ok validPrivResp ← dispatchCoreRequest appSt validPrivReq nowSec | do closeCoreStore store; return 1
  if validPrivResp.status != 200 || ((String.fromUTF8! validPrivResp.body).splitOn "\"allow_exec\":true").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: valid privilege lease rejected: {String.fromUTF8! validPrivResp.body}"
    return 1

  -- Disallowed unit (`sshd.service`) on `service_deploy` lease MUST fail closed with 403!
  let badUnitBody := "{\"mission_id\":\"m-alpha\",\"lease_token\":\"lease-live-1234567890\",\"target_host\":\"self\",\"executing_host\":\"ashur\",\"command\":\"systemctl restart sshd.service\",\"argv\":[\"systemctl\",\"restart\",\"sshd.service\"]}"
  let badUnitRaw := s!"POST /api/privilege-access/verify-and-log HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {badUnitBody.utf8ByteSize}\r\n\r\n{badUnitBody}".toUTF8
  let .ok badUnitReq := parseRequest badUnitRaw none | do closeCoreStore store; return 1
  let .ok badUnitResp ← dispatchCoreRequest appSt badUnitReq nowSec | do closeCoreStore store; return 1
  if badUnitResp.status != 403 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: unauthorized unit was not rejected (got {badUnitResp.status})"
    return 1

  -- Unknown privilege scope (`ops_admin`) MUST fail closed with 403!
  let .ok () ← upsertPrivilegeLease store {
    grantId := "grant-bad-scope", leaseToken := "lease-bad-scope-123", missionId := "m-alpha",
    targetHost := "ashur", scope := "ops_admin", allowedUnitsJson := "[]",
    requireForceCmd := false, biometricSigned := true, revoked := false, expiresAtEpoch := nowSec + 300
  } | do closeCoreStore store; return 1
  let badScopeBody := "{\"mission_id\":\"m-alpha\",\"lease_token\":\"lease-bad-scope-123\",\"target_host\":\"ashur\",\"executing_host\":\"ashur\",\"command\":\"uname -a\",\"argv\":[\"uname\",\"-a\"]}"
  let badScopeRaw := s!"POST /api/privilege-access/verify-and-log HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {badScopeBody.utf8ByteSize}\r\n\r\n{badScopeBody}".toUTF8
  let .ok badScopeReq := parseRequest badScopeRaw none | do closeCoreStore store; return 1
  let .ok badScopeResp ← dispatchCoreRequest appSt badScopeReq nowSec | do closeCoreStore store; return 1
  if badScopeResp.status != 403 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: unknown scope was not rejected (got {badScopeResp.status})"
    return 1

  -- Expired privilege lease on a fresh mission MUST NOT permanently fence `startMachineTransfer`!
  let .ok () ← upsertMission store {
    id := "m-exp-lease", title := "Expired Lease Transfer Test", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := tmpRoot,
    project := "proj-cap", updatedAt := "2026-11-06T00:00:00Z", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let .ok () ← upsertPrivilegeLease store {
    grantId := "grant-exp", leaseToken := "lease-expired-999", missionId := "m-exp-lease",
    targetHost := "ashur", scope := "ops_read", allowedUnitsJson := "[]",
    requireForceCmd := false, biometricSigned := true, revoked := false, expiresAtEpoch := 100
  } | do closeCoreStore store; return 1
  let expTxRes ← startMachineTransfer store {
    id := "tx-exp-1", missionId := "m-exp-lease", requestKey := "rk-exp-1", revision := 0,
    phase := "preparing", destination := "ashur", sourceRevision := "2026-11-06T00:00:00Z",
    sourceGeneration := 0, generation := 0, createdAt := "2026-11-06T00:02:00Z"
  }
  if !expTxRes.isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: expired privilege lease falsely fenced startMachineTransfer"
    return 1

  -- Per-project `parallel_missions_cap` returns HTTP 429 `{"error":"parallel_missions_cap","cap":1,"active":1}`
  -- for `"proj-cap"`, while unrelated `"other-proj"` succeeds!
  let _ ← execParamQuery store.projectsDb upsertProjectGrantSql
    #["proj-cap", "owner", "1h", "1", "", "", "high", "propose", "2026-11-06T00:00:00Z"]
  let capHitBody := "{\"id\":\"m-cap-2\",\"title\":\"Blocked\",\"backend\":\"codex\",\"project_slug\":\"proj-cap\"}"
  let capHitRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {capHitBody.utf8ByteSize}\r\n\r\n{capHitBody}".toUTF8
  let .ok capHitReq := parseRequest capHitRaw none | do closeCoreStore store; return 1
  let .ok capHitResp ← dispatchCoreRequest appSt { capHitReq with } nowSec | do closeCoreStore store; return 1
  let capHitStr := String.fromUTF8! capHitResp.body
  if capHitResp.status != 429 ||
     (capHitStr.splitOn "\"error\":\"parallel_missions_cap\"").length != 2 ||
     (capHitStr.splitOn "\"cap\":1").length != 2 ||
     (capHitStr.splitOn "\"active\":1").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: parallel_missions_cap contract mismatch ({capHitResp.status}): {capHitStr}"
    return 1

  -- Symlinked-ancestor confinement: `<tmpRoot>/escape_link -> /etc` with non-existent leaf must fail closed!
  let symOut ← IO.Process.output { cmd := "/bin/ln", args := #["-s", "/etc", s!"{tmpRoot}/escape_link"] }
  if symOut.exitCode == 0 then
    match ← confineWorkingDirectory tmpRoot "escape_link/nonexistent_subdir" with
    | .ok leaked =>
      closeCoreStore store
      IO.eprintln s!"[orb-core-test] FAIL: symlinked-ancestor escape leaked `{leaked}`"
      return 1
    | .error _ => pure ()

  -- WebSocket upgrade: 401 without JWT; 101 with `Sec-WebSocket-Protocol: jwt.<tok>` echoed in response!
  let wsUnauthRaw := "GET /api/console/ws HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".toUTF8
  let .ok wsUnauthReq := parseRequest wsUnauthRaw none | do closeCoreStore store; return 1
  let .ok wsUnauthResp ← dispatchCoreRequest appSt wsUnauthReq nowSec | do closeCoreStore store; return 1
  if wsUnauthResp.status != 401 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: unauthenticated /api/console/ws returned {wsUnauthResp.status} instead of 401"
    return 1

  let wsAuthRaw := s!"GET /api/console/ws HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: jwt.{validJwt}\r\n\r\n".toUTF8
  let .ok wsAuthReq := parseRequest wsAuthRaw none | do closeCoreStore store; return 1
  match ← dispatchCoreRequest appSt wsAuthReq nowSec with
  | .error raw101 =>
    let resp101 := String.fromUTF8! raw101
    if (resp101.splitOn "101 Switching Protocols").length != 2 ||
       (resp101.splitOn s!"Sec-WebSocket-Protocol: jwt.{validJwt}").length != 2 then
      closeCoreStore store
      IO.eprintln s!"[orb-core-test] FAIL: authenticated /api/console/ws missing 101 or echoed subprotocol: {resp101}"
      return 1
  | .ok r =>
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: authenticated /api/console/ws returned HTTP {r.status}"
    return 1

  -- Durable queue edit (`GET /api/control/queue`, `PATCH /api/control/queue/:id`):
  -- edits in place without changing FIFO order, emits a queued `user_message` event,
  -- rejects empty edits with 400, missing rows with 404, and delivered/bound rows with 409.
  for (qid, text) in [("q-1", "first"), ("q-2", "second"), ("q-3", "third")] do
    let .ok _ ← enqueueRemoteMessage store "core" qid "m-alpha" text (some "remote-queue")
      | do closeCoreStore store; return 1
  let patchBody := "{\"content\":\"second-edited\"}"
  let patchRaw := s!"PATCH /api/control/queue/q-2 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {patchBody.utf8ByteSize}\r\n\r\n{patchBody}".toUTF8
  let .ok patchReq := parseRequest patchRaw none | do closeCoreStore store; return 1
  let .ok patchResp ← dispatchCoreRequest appSt patchReq nowSec | do closeCoreStore store; return 1
  if patchResp.status != 200 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: PATCH /api/control/queue/q-2 returned {patchResp.status}: {String.fromUTF8! patchResp.body}"
    return 1

  let listQueueRaw := s!"GET /api/control/queue?mission_id=m-alpha HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok listQueueReq := parseRequest listQueueRaw none | do closeCoreStore store; return 1
  let .ok listQueueResp ← dispatchCoreRequest appSt listQueueReq nowSec | do closeCoreStore store; return 1
  let listQueueStr := String.fromUTF8! listQueueResp.body
  let expectedQueue := "[{\"id\":\"q-1\",\"mission_id\":\"m-alpha\",\"content\":\"first\",\"source\":\"remote-queue\",\"inflight\":false},{\"id\":\"q-2\",\"mission_id\":\"m-alpha\",\"content\":\"second-edited\",\"source\":\"remote-queue\",\"inflight\":false},{\"id\":\"q-3\",\"mission_id\":\"m-alpha\",\"content\":\"third\",\"source\":\"remote-queue\",\"inflight\":false}]"
  if listQueueResp.status != 200 || listQueueStr != expectedQueue then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: queue FIFO snapshot mismatch ({listQueueResp.status}): {listQueueStr}"
    return 1

  let .ok evRows ← execParamQuery store.missionsDb
    "SELECT payload FROM mission_events WHERE mission_id='m-alpha' AND event_type='user_message' ORDER BY seq DESC LIMIT 1;" #[]
    | do closeCoreStore store; return 1
  let evPayload := ((evRows[1]?.bind (·[0]?)).getD "")
  if (evPayload.splitOn "\"id\":\"q-2\"").length != 2 ||
     (evPayload.splitOn "\"content\":\"second-edited\"").length != 2 ||
     (evPayload.splitOn "\"queued\":true").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: queued user_message event missing after PATCH: {evPayload}"
    return 1

  -- RFC 8259: escaped content is decoded, not stored as literal backslash sequences.
  let escBody := "{\"content\":\"line1\\nline2\\\"q\\\"\\\\end\"}"
  let escRaw := s!"PATCH /api/control/queue/q-2 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {escBody.utf8ByteSize}\r\n\r\n{escBody}".toUTF8
  let .ok escReq := parseRequest escRaw none | do closeCoreStore store; return 1
  let .ok escResp ← dispatchCoreRequest appSt escReq nowSec | do closeCoreStore store; return 1
  if escResp.status != 200 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: escaped PATCH returned {escResp.status}: {String.fromUTF8! escResp.body}"
    return 1
  let .ok escListReq := parseRequest listQueueRaw none | do closeCoreStore store; return 1
  let .ok escListResp ← dispatchCoreRequest appSt escListReq nowSec | do closeCoreStore store; return 1
  let escListStr := String.fromUTF8! escListResp.body
  if escListResp.status != 200 ||
     (escListStr.splitOn "\"content\":\"line1\\nline2\\\"q\\\"\\\\end\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: escaped content not decoded: {escListStr}"
    return 1

  -- Whitespace-only escapes are empty after unescaping and must be rejected.
  let wsEscBody := "{\"content\":\"\\n\\t\\r\"}"
  let wsEscRaw := s!"PATCH /api/control/queue/q-2 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {wsEscBody.utf8ByteSize}\r\n\r\n{wsEscBody}".toUTF8
  let .ok wsEscReq := parseRequest wsEscRaw none | do closeCoreStore store; return 1
  let .ok wsEscResp ← dispatchCoreRequest appSt wsEscReq nowSec | do closeCoreStore store; return 1
  if wsEscResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: whitespace-escape PATCH returned {wsEscResp.status}"
    return 1

  -- Non-string and malformed bodies are rejected before the queue is touched.
  for badBody in ["{\"content\":null}", "{\"content\":123}", "{\"content\":false}", "{not json"] do
    let badRaw := s!"PATCH /api/control/queue/q-2 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {badBody.utf8ByteSize}\r\n\r\n{badBody}".toUTF8
    let .ok badReq := parseRequest badRaw none | do closeCoreStore store; return 1
    let .ok badResp ← dispatchCoreRequest appSt badReq nowSec | do closeCoreStore store; return 1
    if badResp.status != 400 then
      closeCoreStore store
      IO.eprintln s!"[orb-core-test] FAIL: bad PATCH body {badBody} returned {badResp.status}"
      return 1

  let emptyPatchBody := "{\"content\":\"   \"}"
  let emptyPatchRaw := s!"PATCH /api/control/queue/q-2 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {emptyPatchBody.utf8ByteSize}\r\n\r\n{emptyPatchBody}".toUTF8
  let .ok emptyPatchReq := parseRequest emptyPatchRaw none | do closeCoreStore store; return 1
  let .ok emptyPatchResp ← dispatchCoreRequest appSt emptyPatchReq nowSec | do closeCoreStore store; return 1
  if emptyPatchResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: empty PATCH returned {emptyPatchResp.status}"
    return 1

  let missingPatchRaw := s!"PATCH /api/control/queue/q-missing HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {patchBody.utf8ByteSize}\r\n\r\n{patchBody}".toUTF8
  let .ok missingPatchReq := parseRequest missingPatchRaw none | do closeCoreStore store; return 1
  let .ok missingPatchResp ← dispatchCoreRequest appSt missingPatchReq nowSec | do closeCoreStore store; return 1
  if missingPatchResp.status != 404 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: missing PATCH returned {missingPatchResp.status}"
    return 1

  let _ ← execParamQuery store.missionsDb
    "UPDATE remote_message_queue SET payload=json_set(payload,'$.job_id','job-1') WHERE user_id='core' AND message_id='q-2';" #[]
  let boundPatchRaw := s!"PATCH /api/control/queue/q-2 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {patchBody.utf8ByteSize}\r\n\r\n{patchBody}".toUTF8
  let .ok boundPatchReq := parseRequest boundPatchRaw none | do closeCoreStore store; return 1
  let .ok boundPatchResp ← dispatchCoreRequest appSt boundPatchReq nowSec | do closeCoreStore store; return 1
  if boundPatchResp.status != 409 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: job-bound PATCH returned {boundPatchResp.status}"
    return 1

  -- 6b. Phase R2-B & R2-C regressions (`SM-01`, `SM-02`, `SM-08`, `SM-12`)
  -- SM-01: fail-closed persistent DB open (rejects `:memory:`, `mode=memory`, and non-directory file collisions)
  if (← openSqliteDb ":memory:" missionsSchemaSql).isOk ||
     (← openSqliteDb "file:memdb1?mode=memory" missionsSchemaSql).isOk ||
     (← openCoreStore ":memory:").isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: openSqliteDb/openCoreStore permitted memory fallback"
    return 1
  let blockedRoot := s!"{tmpRoot}/not-a-directory"
  IO.FS.writeFile blockedRoot "file-blocking-dir"
  if (← openCoreStore blockedRoot).isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: openCoreStore succeeded on file-blocked root"
    return 1

  -- SM-01: `mission_terminal_evidence` join in `listMissionsJson` + unified `GET /api/control/missions/:id/health`
  let .ok () ← upsertTerminalEvidence store {
    missionId := "m-alpha"
    terminalReason := "completed_verified"
    summary := "all checks green"
    artifactRef := "sha256:deadbeef"
    verified := true
    recordedAt := "2026-11-06T00:02:00Z"
  } | do closeCoreStore store; return 1
  let .ok rev2 ← commitTransitionWithIntents store "m-alpha" 1 1 1 1 1
      "completed" "readonly" "client" "" "" 16 "2026-11-06T00:03:00Z"
      #[{ effectId := "eff-r2c-1", intentKind := "notify_completion", payloadJson := "{\"ok\":true}", attemptEpoch := 1 }]
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: commitTransitionWithIntents failed"; return 1
  if rev2 != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: expected state_revision=2, got {rev2}"
    return 1
  -- SM-02: stale `expectedRev` CAS update and contradictory authority tags MUST be rejected!
  let staleCas ← commitTransitionWithIntents store "m-alpha" 1 1 1 1 1
      "completed" "writer" "managed" "m-beta" "" 0 "2026-11-06T00:04:00Z" #[]
  if staleCas.isOk || (classifyAuthorityMode none #["pr-writer", "pr-readonly"] false).isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: stale CAS or contradictory tags were not rejected"
    return 1
  -- R2-C outbox StickyFence: Claim -> MarkUncertain blocks fresh Claim/Accept until Reconcile!
  let .ok (phClaim, _) ← transitionOutboxEffect store "eff-r2c-1" 1 1 1 "t1"
    | do closeCoreStore store; return 1
  let .ok (phUnc, _) ← transitionOutboxEffect store "eff-r2c-1" 4 1 1 "t2"
    | do closeCoreStore store; return 1
  let retryOnUncertain ← transitionOutboxEffect store "eff-r2c-1" 1 1 1 "t3"
  let acceptOnUncertain ← transitionOutboxEffect store "eff-r2c-1" 2 1 1 "t3"
  let .ok (phRec, _) ← transitionOutboxEffect store "eff-r2c-1" 5 1 1 "t4"
    | do closeCoreStore store; return 1
  if phClaim != 1 || phUnc != 4 || retryOnUncertain.isOk || acceptOnUncertain.isOk || phRec != 5 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: outbox StickyFence transition invariant violated"
    return 1

  let .ok listJoined ← listMissionsJson store | do closeCoreStore store; return 1
  if (listJoined.splitOn "\"artifact_ref\":\"sha256:deadbeef\"").length != 2 ||
     (listJoined.splitOn "\"health_verdict\":\"completed\"").length != 2 ||
     (listJoined.splitOn "\"authority_mode\":\"readonly\"").length != 2 ||
     (listJoined.splitOn "\"reserved_disk_gib\":16").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: listMissionsJson terminal_evidence/typed columns missing: {listJoined}"
    return 1
  let healthRaw := s!"GET /api/control/missions/m-alpha/health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok healthReq := parseRequest healthRaw none | do closeCoreStore store; return 1
  let .ok healthResp ← dispatchCoreRequest appSt healthReq nowSec | do closeCoreStore store; return 1
  let healthStr := String.fromUTF8! healthResp.body
  if healthResp.status != 200 || (healthStr.splitOn "\"health_verdict\":\"completed\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: GET /api/control/missions/m-alpha/health mismatch: {healthStr}"
    return 1

  -- SM-08: two-phase cross-DB track/repo lease reservation + conflict rejection + crash recovery
  let .ok () ← upsertMission store {
    id := "m-w1", title := "Writer 1", status := "active", backend := "opencode",
    modelOverride := "", workingDirectory := tmpRoot, project := "orb", updatedAt := "t1"
  } | do closeCoreStore store; return 1
  let .ok () ← upsertMission store {
    id := "m-w2", title := "Writer 2", status := "active", backend := "opencode",
    modelOverride := "", workingDirectory := tmpRoot, project := "orb", updatedAt := "t1"
  } | do closeCoreStore store; return 1
  let .ok () ← acquireDispatchTrackLease store {
    reservationId := "rsv-w1", missionId := "m-w1", projectSlug := "orb",
    track := "r2-track", repo := "Th0rgal/orb", authorityMode := "writer",
    reservedDiskGib := 8, nowAt := "t1"
  } | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: first writer lease rejected"; return 1
  let dupWriter ← acquireDispatchTrackLease store {
    reservationId := "rsv-w2", missionId := "m-w2", projectSlug := "orb",
    track := "r2-track", repo := "Th0rgal/orb", authorityMode := "writer",
    reservedDiskGib := 4, nowAt := "t2"
  }
  if dupWriter.isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: conflicting track writer lease was not rejected"
    return 1
  -- Cross-track writer on the SAME repo MUST also be rejected (`verifyRepoDisjoint`)!
  let sameRepoOtherTrack ← acquireDispatchTrackLease store {
    reservationId := "rsv-w2-repo", missionId := "m-w2", projectSlug := "orb",
    track := "different-track", repo := "Th0rgal/orb", authorityMode := "writer",
    reservedDiskGib := 2, nowAt := "t2b"
  }
  if sameRepoOtherTrack.isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: cross-track same-repo writer lease was not rejected"
    return 1
  let .ok () ← releaseDispatchTrackLease store "rsv-w1" "t3" | do closeCoreStore store; return 1
  -- Simulate same-boot Phase-3 failure (intent `preparing`, projects row `active` at boot 1)
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO dispatch_lease_intents(reservation_id,mission_id,project_slug,track,repo,authority_mode,reserved_disk_gib,phase,boot_epoch,created_at,updated_at) VALUES('rsv-sameboot','m-w2','orb','r2-track','Th0rgal/orb','writer',6,'preparing',1,'t3b','t3b');" #[]
  let _ ← execParamQuery store.projectsDb
    "INSERT INTO project_track_leases(project_slug,track,reservation_id,mission_id,repo,authority_mode,phase,boot_epoch,updated_at) VALUES('orb','r2-track','rsv-sameboot','m-w2','Th0rgal/orb','writer','active',1,'t3b');" #[]
  let .ok () ← recoverDispatchLeases store.missionsDb store.projectsDb 1
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: same-boot recoverDispatchLeases failed"; return 1
  -- Simulate mid-flight crash leaving `preparing` rows in both `missions.db` and `projects.db`
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO dispatch_lease_intents(reservation_id,mission_id,project_slug,track,repo,authority_mode,reserved_disk_gib,phase,boot_epoch,created_at,updated_at) VALUES('rsv-crash','m-w2','orb','r2-track','Th0rgal/orb','writer',12,'preparing',1,'t4','t4');" #[]
  let _ ← execParamQuery store.projectsDb
    "INSERT INTO project_track_leases(project_slug,track,reservation_id,mission_id,repo,authority_mode,phase,boot_epoch,updated_at) VALUES('orb','r2-track','rsv-crash','m-w2','Th0rgal/orb','writer','preparing',1,'t4');" #[]
  let .ok () ← recoverDispatchLeases store.missionsDb store.projectsDb 2
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: recoverDispatchLeases failed"; return 1
  -- After startup recovery on boot 2, `m-w1` can acquire `r2-track` immediately without waiting 6h TTL!
  let .ok () ← acquireDispatchTrackLease store {
    reservationId := "rsv-post-crash", missionId := "m-w1", projectSlug := "orb",
    track := "r2-track", repo := "Th0rgal/orb", authorityMode := "writer",
    reservedDiskGib := 4, bootEpoch := 2, nowAt := "t5"
  } | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: post-crash lease acquisition blocked"; return 1
  if (← runR2bRound2Extras store appSt validJwt nowSec) != 0 then return 1

  -- SM-12: pre-effect in-flight idempotency reservation + committed `2xx` > 512 KiB `committed_oversize` sentinel
  let .ok .Claimed ← claimIdempotencySlot store "missions_create" "idem-inflight-1" "t5"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: claimIdempotencySlot initial claim failed"; return 1
  let .ok .InFlight ← claimIdempotencySlot store "missions_create" "idem-inflight-1" "t5"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: concurrent claimIdempotencySlot did not return InFlight"; return 1
  let .ok _ ← recordOrReplayIdempotency store "missions_create" "idem-inflight-1" 201 "{\"id\":\"m-idem-1\"}" "t5"
    | do closeCoreStore store; return 1
  let .ok (.Replayed repRec) ← claimIdempotencySlot store "missions_create" "idem-inflight-1" "t6"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: finalized slot did not replay"; return 1
  if repRec.statusCode != 201 || repRec.bodyJson != "{\"id\":\"m-idem-1\"}" then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: finalized slot replay mismatch"
    return 1
  let bigPayload := "{\"blob\":\"" ++ String.ofList (List.replicate 530000 'x') ++ "\"}"
  let .ok over1 ← recordOrReplayIdempotency store "missions_create" "idem-oversize-1" 201 bigPayload "t5"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: oversize idempotency write failed"; return 1
  let .ok over2 ← recordOrReplayIdempotency store "missions_create" "idem-oversize-1" 201 "{\"second\":\"mutation\"}" "t6"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: oversize idempotency replay failed"; return 1
  if !over1.committedOversize || over1.replayed || !over2.committedOversize || !over2.replayed ||
     over1.statusCode != 201 || over2.statusCode != 201 || over1.bodyJson != over2.bodyJson ||
     (over2.bodyJson.splitOn "\"committed_oversize\":true").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-12 committed_oversize sentinel invariant violated: {over2.bodyJson}"
    return 1

  closeCoreStore store
  -- Re-opening `openCoreStore tmpRoot` MUST auto-increment persistent `bootEpoch` (`1 -> 2`) and recover stale boot-1 leases!
  let .ok storeBoot2 ← openCoreStore tmpRoot
    | do IO.eprintln "[orb-core-test] FAIL: second openCoreStore failed"; return 1
  if storeBoot2.bootEpoch != 2 then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: expected persistent bootEpoch=2 on reopen, got {storeBoot2.bootEpoch}"
    return 1
  closeCoreStore storeBoot2
  IO.FS.removeDirAll tmpRoot

  -- 7. Host evidence suite (`83/83` host tests)
  let hostOk ← runAllHostTests emitLogPath?
  if !hostOk then
    IO.eprintln "[orb-core-test] FAIL: OrbCore.HostTests failed"
    return 1

  IO.println "{\"ok\":true,\"binary\":\"orb-core-test\",\"spec_gates\":5,\"harness_contracts\":9,\"host_tests\":83}"
  return 0

end OrbCore.SelfTest

def main (args : List String) : IO UInt32 :=
  OrbCore.SelfTest.runSuite (OrbCore.SelfTest.findFlag? args "--emit-evidence-log")
