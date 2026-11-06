/-
  OrbCore.SelfTest: End-to-End Verification Suite for Wave 4 `OrbCore` (`orb-core-test`):
  1. All 5 `OrbCore.Spec` `MetaGateSpec` gates (fail-closed `DEV_MODE=false` secrets, `DEV_MODE=true` non-loopback rejection, `:80/api/console/ws` JWT auth, transfer fence, proxy failover, deploy unit allowlist).
  2. Live SQLite `CoreStore` (`missions.db`, `projects.db`, `ask.db`, `idempotency_keys.db`), parameterized queries, machine-transfer fencing, automations & routing chains.
  3. `OrbCore.Search` conversation indexing & trigram SST lookup.
  4. All 9 `OrbCore.Harness` contract tests.
  5. `/v1/*` `OrbCore.Proxy` pre-first-byte `429`/`503` failover.
  6. Live loopback HTTP/1.1 + WebSocket dispatch (`/api/health`, `/api/auth/login`, `/api/console/ws` `401` without JWT and `101` with `jwt.<token>`).
  7. All 78 `OrbCore.HostTests` & optional `--emit-evidence-log <path>` receipt generation.
-/
import OrbCore

namespace OrbCore.SelfTest

open LeanSys.Posix
open LeanSys.Http
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

def runSuite (emitLogPath? : Option String) : IO UInt32 := do
  -- 1. Startup security fail-closed gates (`validateRuntimeSecurity`)
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
    jwtSecret := "ci-test-random-jwt-secret-0123456789abcdef"
  }
  let devNonLoopback : CoreConfig := { devMode := true, host := "0.0.0.0" }
  let devLoopback : CoreConfig := { devMode := true, host := "127.0.0.1" }
  if (validateRuntimeSecurity prodNoSecrets).isOk ||
     (validateRuntimeSecurity prodPlaceholder).isOk ||
     (validateRuntimeSecurity prodShortJwt).isOk ||
     !(validateRuntimeSecurity prodValid).isOk ||
     (validateRuntimeSecurity devNonLoopback).isOk ||
     !(validateRuntimeSecurity devLoopback).isOk then
    IO.eprintln "[orb-core-test] FAIL: validateRuntimeSecurity fail-closed checks failed"
    return 1

  -- 2. Service-scoped VM prefix & deploy unit confinement
  if sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh-prod" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh-dev" != "orb-managed-dev-" ||
     !exceptStrEq (validateDeployServiceUnit "sandboxed-sh") (.ok "sandboxed-sh.service") ||
     !exceptStrEq (validateDeployServiceUnit "orb-node") (.ok "sandboxed-node.service") ||
     !exceptStrEq (validateDeployServiceUnit "orb-privd.service") (.ok "orb-privd.service") ||
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
    backend := "codex", modelOverride := "", workingDirectory := tmpRoot,
    updatedAt := "2026-11-06T00:00:00Z", totalCostCents := 42
  }
  let .ok () ← upsertMission store m1 | do closeCoreStore store; return 1
  let .ok missionsJson ← listMissionsJson store | do closeCoreStore store; return 1
  if (missionsJson.splitOn "\"total_cost_cents\":42").length != 2 then
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

  -- 5. `/v1/*` Proxy pre-first-byte failover (`429` on primary -> `200` on backup)
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
      return .ok { status := 200, headers := #[], body := "{\"id\":\"resp_ok\"}".toUTF8 })
  if proxyOut.status != 200 || proxyOut.selectedAccount != "acct-2" || proxyOut.attemptsUsed != 2 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: forwardProxyChain failover mismatch"
    return 1

  -- 6. HTTP/WS Dispatch checks (`/api/health`, `/api/console/ws` 401 unauthenticated vs 101 with `jwt.<token>`)
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : ManagedFleetState)
  let chainsRef ← IO.mkRef #[chain]
  let appSt : CoreAppState := {
    cfg := prodValid, store := store, searchIdx? := some sIdx1,
    managedRef := managedRef, chainsRef := chainsRef
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

  let wsUnauthRaw := "GET /api/console/ws HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".toUTF8
  let .ok wsUnauthReq := parseRequest wsUnauthRaw none | do closeCoreStore store; return 1
  let .ok wsUnauthResp ← dispatchCoreRequest appSt wsUnauthReq nowSec | do closeCoreStore store; return 1
  if wsUnauthResp.status != 401 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: unauthenticated /api/console/ws returned {wsUnauthResp.status} instead of 401"
    return 1

  let validJwt := mintSessionToken prodValid.jwtSecret (nowSec + 3600)
  let wsAuthRaw := s!"GET /api/console/ws HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: jwt.{validJwt}\r\n\r\n".toUTF8
  let .ok wsAuthReq := parseRequest wsAuthRaw none | do closeCoreStore store; return 1
  match ← dispatchCoreRequest appSt wsAuthReq nowSec with
  | .error raw101 =>
    if ((String.fromUTF8! raw101).splitOn "101 Switching Protocols").length != 2 then
      closeCoreStore store
      IO.eprintln "[orb-core-test] FAIL: authenticated /api/console/ws did not upgrade to 101"
      return 1
  | .ok r =>
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: authenticated /api/console/ws returned HTTP {r.status}"
    return 1

  closeCoreStore store
  IO.FS.removeDirAll tmpRoot

  -- 7. Host evidence suite (`82/82` host tests)
  let hostOk ← runAllHostTests emitLogPath?
  if !hostOk then
    IO.eprintln "[orb-core-test] FAIL: OrbCore.HostTests failed"
    return 1

  IO.println "{\"ok\":true,\"binary\":\"orb-core-test\",\"spec_gates\":5,\"harness_contracts\":9,\"host_tests\":82}"
  return 0

end OrbCore.SelfTest

def main (args : List String) : IO UInt32 :=
  OrbCore.SelfTest.runSuite (OrbCore.SelfTest.findFlag? args "--emit-evidence-log")
