/-
  OrbCore.SelfTest: End-to-End Verification Suite for Wave 4 `OrbCore` (`orb-core-test`):
  1. All 7 `OrbCore.Spec` `MetaGateSpec` gates (fail-closed `DEV_MODE=false` secrets, `DEV_MODE=true` non-loopback rejection, `:80/api/console/ws` JWT auth + conflicting-credential rejection, transfer fence, proxy failover, deploy unit allowlist, proactive provider pacing, remote replay supersession lineage fence).
  2. Live SQLite `CoreStore` (`missions.db`, `projects.db`, `ask.db`, `idempotency_keys.db`), parameterized queries, `BEGIN IMMEDIATE` machine-transfer fencing, remote replay rollback & stranded-`pending` reconciliation, privilege leases & audit log, automations & routing chains.
  3. `OrbCore.Search` conversation indexing & in-memory trigram SST lookup.
  4. All 9 `OrbCore.Harness` contract tests.
  5. `/v1/*` `OrbCore.Proxy` pre-first-byte `429`/`503` failover + hop-by-hop header sanitization.
  6. Live HTTP/1.1 + WebSocket dispatch (`/api/health`, `/api/auth/login` with `SANDBOXED_USERS`, `/v1/*` auth, `/api/privilege-access/verify-and-log` fail-closed vs valid lease, `/api/console/ws` `401` without JWT and `101` echoing `Sec-WebSocket-Protocol: jwt.<token>`).
  7. All 85 `OrbCore.HostTests` & optional `--emit-evidence-log <path>` receipt generation.
-/
import OrbCore
import OrbCore.ManagedProviderTests
import OrbCore.ManagedProviderLeanciTests
import OrbCore.ManagedProviderColabTests
import OrbCore.ManagedProviderSealingTests
import OrbCore.ManagedProviderAvailabilityTests
import OrbCore.ManagedSpawnActionsTests
import OrbCore.ManagedProvisioningTests
import OrbCore.ManagedResumeTests
import OrbCore.WakeupRestartTests
import OrbCore.TurnOutcomeTests
import OrbCore.ManagedAccessTests
import OrbCore.ManagedTtlTests
import OrbCore.ManagedHarvestTests
import OrbCore.AutoPlacementTests
import OrbCore.ManagedReuseTests
import OrbCore.ManagedSnapshotLifecycleTests
import OrbCore.NodeLivenessTests
import OrbCore.ComputeRollupTests
import OrbCore.ManagedSnapshotCatalogTests
import OrbCore.ProviderContractTests
import OrbCore.ProxyRoutingTests
import OrbCore.SettingsDocumentTests
import OrbCore.DevOperatorTests
import OrbCore.SettingsTransferTests

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
open OrbCore.CloudAgents
open OrbCore.MemoryAndCloud
open OrbCore.Cyber
open OrbCore.Skills
open OrbCore.QueueCont
open OrbCore.R7Core
open OrbCore.TelemetryAndVoice
open OrbCore.LegacyHydrate
open OrbCore.SecretAndApproval
open OrbCore.RemoteFleetAndRelay
open OrbCore.ProjectFilesAndController
open OrbCore.RemoteDispatch
open OrbCore.McpGateway
open OrbCore.CloudHttpAndWorker
open OrbCore.ProviderUsageAndLogin
open OrbCore.ResourcesAndSystem
open OrbCore.Control
open OrbCore.HostTests
open OrbCore.HarnessSessionRegistry
open OrbNetLeaf.TlsHttp
open OrbNetLeaf.Gzip
open LeanSys.WebSocket

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

/-- Fixtures which need a live VM must explicitly replay its first relay poll. -/
private def provisionReadyFixture (st : ManagedComputeStore) (fleet : ManagedFleetState)
    (machine : ManagedMachine) (nowEpoch : UInt64) : IO (Except String ManagedMachine) := do
  let .ok m ← provisionManagedMachine st fleet machine nowEpoch
    | return .error "fixture_reservation_failed"
  let .ok _ ← recordAuthenticatedManagedPoll st m.id m.nodeBootEpoch nowEpoch
    | return .error "fixture_poll_failed"
  return .ok { m with status := "ready", lastPollSec := nowEpoch }

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

  -- Remote replay rollback & `ashur` `9409f9a9` consecutive `ENOSPC` regression suite:
  -- 1. Create mission `m-ashur-9409f9a9` and arm a scheduled-origin `RemoteWait` (`failed_job_id = "job-origin-0"`, `scheduled_origin_job_id = "job-origin-0"`).
  let .ok () ← upsertMission store {
    id := "m-ashur-9409f9a9", title := "evm.fast (claude takeover)", status := "interrupted",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    project := "evm-fast", updatedAt := "t-w0", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let armBody := "{\"node_id\":\"ashur\",\"failed_job_id\":\"job-origin-0\",\"scheduled_origin_job_id\":\"job-origin-0\",\"max_retries\":10,\"terminal_reason\":\"usage_limit_wait\"}"
  let armRaw := s!"POST /api/control/missions/m-ashur-9409f9a9/remote-wait HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {armBody.utf8ByteSize}\r\n\r\n{armBody}".toUTF8
  let .ok armReq := parseRequest armRaw none | do closeCoreStore store; return 1
  let .ok armResp ← dispatchCoreRequest appSt armReq nowSec | do closeCoreStore store; return 1
  if armResp.status != 200 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: arm remote-wait failed: {armResp.status}"
    return 1

  -- 2. Retry #1 hits HTTP 500 `ENOSPC` pre-dispatch (`dispatch_outcome = 1`, `has_recovery_handle = 0`, `scheduled_origin = true`, `candidate_job_id = "job-enospc-1"`):
  --    MUST roll `pending -> interrupted` (`usage_limit_wait`), restore `scheduled_remote_job_id = "job-origin-0"`, and advance `failed_job_id = "job-enospc-1"` (`retries = 1`).
  let rep1Body := "{\"node_id\":\"ashur\",\"candidate_job_id\":\"job-enospc-1\",\"scheduled_origin\":true,\"dispatch_outcome\":1,\"has_recovery_handle\":0,\"retry_fits_deadline\":1}"
  let rep1Raw := s!"POST /api/control/missions/m-ashur-9409f9a9/remote-replay HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {rep1Body.utf8ByteSize}\r\n\r\n{rep1Body}".toUTF8
  let .ok rep1Req := parseRequest rep1Raw none | do closeCoreStore store; return 1
  let .ok rep1Resp ← dispatchCoreRequest appSt rep1Req nowSec | do closeCoreStore store; return 1
  let rep1Str := String.fromUTF8! rep1Resp.body
  if rep1Resp.status != 200 ||
     (rep1Str.splitOn "\"action\":4").length != 2 ||
     (rep1Str.splitOn "\"status\":\"waiting_rate_limit\"").length != 2 ||
     (rep1Str.splitOn "\"scheduled_remote_job_id\":\"job-origin-0\"").length != 2 ||
     (rep1Str.splitOn "\"failed_job_id\":\"job-enospc-1\"").length != 2 ||
     (rep1Str.splitOn "\"retries\":1").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: ENOSPC retry #1 rollback mismatch ({rep1Resp.status}): {rep1Str}"
    return 1

  -- 3. Retry #2 also hits HTTP 500 `ENOSPC` (`candidate_job_id = "job-enospc-2"`):
  --    MUST NOT fail with `400 scheduled_recovery_missing_remote_job` or `409 scheduled_recovery_superseded`!
  let rep2Body := "{\"node_id\":\"ashur\",\"candidate_job_id\":\"job-enospc-2\",\"scheduled_origin\":true,\"dispatch_outcome\":1,\"has_recovery_handle\":0,\"retry_fits_deadline\":1}"
  let rep2Raw := s!"POST /api/control/missions/m-ashur-9409f9a9/remote-replay HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {rep2Body.utf8ByteSize}\r\n\r\n{rep2Body}".toUTF8
  let .ok rep2Req := parseRequest rep2Raw none | do closeCoreStore store; return 1
  let .ok rep2Resp ← dispatchCoreRequest appSt rep2Req nowSec | do closeCoreStore store; return 1
  let rep2Str := String.fromUTF8! rep2Resp.body
  if rep2Resp.status != 200 ||
     (rep2Str.splitOn "\"action\":4").length != 2 ||
     (rep2Str.splitOn "\"scheduled_remote_job_id\":\"job-origin-0\"").length != 2 ||
     (rep2Str.splitOn "\"failed_job_id\":\"job-enospc-2\"").length != 2 ||
     (rep2Str.splitOn "\"retries\":2").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: ENOSPC retry #2 rollback mismatch ({rep2Resp.status}): {rep2Str}"
    return 1

  -- 4. Retry #3 succeeds after disk recovery on `ashur` (`dispatch_outcome = 0`, `candidate_job_id = "job-ok-3"`):
  --    MUST transition to `active` (`action = 3`), clear `mission_remote_waits`, and record a live `running` run!
  let rep3Body := "{\"node_id\":\"ashur\",\"candidate_job_id\":\"job-ok-3\",\"scheduled_origin\":true,\"dispatch_outcome\":0,\"has_recovery_handle\":1,\"retry_fits_deadline\":1}"
  let rep3Raw := s!"POST /api/control/missions/m-ashur-9409f9a9/remote-replay HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {rep3Body.utf8ByteSize}\r\n\r\n{rep3Body}".toUTF8
  let .ok rep3Req := parseRequest rep3Raw none | do closeCoreStore store; return 1
  let .ok rep3Resp ← dispatchCoreRequest appSt rep3Req nowSec | do closeCoreStore store; return 1
  let rep3Str := String.fromUTF8! rep3Resp.body
  if rep3Resp.status != 200 ||
     (rep3Str.splitOn "\"action\":3").length != 2 ||
     (rep3Str.splitOn "\"status\":\"active\"").length != 2 ||
     (rep3Str.splitOn "\"wait_active\":false").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: ENOSPC retry #3 resume mismatch ({rep3Resp.status}): {rep3Str}"
    return 1

  -- 5. Manual user resume supersession fence (`verifyRemoteReplaySupersession`):
  --    When a manual resume advances `placement_job_id` with a non-`remote_dispatch_failed` run,
  --    `POST /api/control/missions/:id/remote-replay` MUST return `409 scheduled_recovery_superseded` and clear the stale wait!
  let .ok () ← upsertMission store {
    id := "m-manual-sup", title := "Manual Supersession Test", status := "waiting_rate_limit",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    updatedAt := "t-sup0", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let .ok () ← armRemoteMissionWait store "m-manual-sup" "ashur" "job-wait-1" "job-wait-1" 10 0 "usage_limit_wait" "t-sup1"
    | do closeCoreStore store; return 1
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET placement_job_id='job-manual-2' WHERE id='m-manual-sup';" #[]
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES('run-manual-2','m-manual-sup',2,'terminal','completed','job-manual-2','t-sup2');" #[]
  let supBody := "{\"node_id\":\"ashur\",\"candidate_job_id\":\"job-stale-replay\",\"scheduled_origin\":true,\"dispatch_outcome\":0}"
  let supRaw := s!"POST /api/control/missions/m-manual-sup/remote-replay HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {supBody.utf8ByteSize}\r\n\r\n{supBody}".toUTF8
  let .ok supReq := parseRequest supRaw none | do closeCoreStore store; return 1
  let .ok supResp ← dispatchCoreRequest appSt supReq nowSec | do closeCoreStore store; return 1
  if supResp.status != 409 || ((String.fromUTF8! supResp.body).splitOn "scheduled_recovery_superseded").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: manual resume did not supersede remote-replay ({supResp.status})"
    return 1

  -- 6. `restoreMissionStatus` `StickyFence` on `acknowledged` & live-run protection:
  let .ok () ← upsertMission store {
    id := "m-rb-ack", title := "Archived Mission", status := "acknowledged",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    updatedAt := "t-rb0", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let .ok ackRb ← restoreMissionStatus store "m-rb-ack" "interrupted" "usage_limit_wait" "t-rb1"
    | do closeCoreStore store; return 1
  if ackRb then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: restoreMissionStatus un-archived acknowledged mission"
    return 1
  let .ok () ← upsertMission store {
    id := "m-rb-pend", title := "Pending Pre-Dispatch", status := "pending",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    updatedAt := "t-rb0", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let .ok pendRb ← restoreMissionStatus store "m-rb-pend" "interrupted" "usage_limit_wait" "t-rb2"
    | do closeCoreStore store; return 1
  if !pendRb then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: restoreMissionStatus failed to roll back pending -> interrupted"
    return 1
  return 0

private def runPostCrashAndReconcileExtras (store : CoreStore) (tmpRoot : String) : IO UInt32 := do
  -- Seed one crash-stranded `pending` mission (`m-crash-pend`, latest run `remote_dispatch_failed`) and one legitimate `deferred_goal` `pending` mission (`m-deferred-pend`) before closing `store`:
  let .ok () ← upsertMission store {
    id := "m-crash-pend", title := "Crash Stranded Pending", status := "pending",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := tmpRoot,
    updatedAt := "t-cp0", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET terminal_reason='usage_limit_wait' WHERE id='m-crash-pend';" #[]
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES('run-cp-1','m-crash-pend',1,'terminal','remote_dispatch_failed','job-cp-1','t-cp1');" #[]
  let .ok () ← upsertMission store {
    id := "m-deferred-pend", title := "Deferred Goal Pending", status := "pending",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := tmpRoot,
    updatedAt := "t-dp0", totalCostCents := 0
  } | do closeCoreStore store; return 1
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET deferred_goal='run after dependency',terminal_reason='remote_dispatch_failed' WHERE id='m-deferred-pend';" #[]
  let _ ← enqueueStructuredFollowup store "core" "q-boot1-inflight" "m-r3c-local" "claimed before crash" "desktop" "t-qb1"
  let _ ← stepQueueItem store "core" "q-boot1-inflight" 0 "1" s!"{store.bootEpoch}" "0" "t-qb2"
  let _ ← enqueueStructuredFollowup store "core" "q-boot1-delivered" "m-r3c-local" "delivered before crash" "desktop" "t-qd1"
  let _ ← stepQueueItem store "core" "q-boot1-delivered" 0 "1" s!"{store.bootEpoch}" "0" "t-qd2"
  let _ ← stepQueueItem store "core" "q-boot1-delivered" 1 "1" s!"{store.bootEpoch}" "77" "t-qd3"

  closeCoreStore store
  -- Re-opening `openCoreStore tmpRoot` MUST auto-increment persistent `bootEpoch` (`1 -> 2`), recover stale boot-1 leases,
  -- heal `m-crash-pend` (`pending -> waiting_rate_limit` with `usage_limit_wait`), preserve `m-deferred-pend` (`pending`),
  -- and convert boot-1 claimed `q-boot1-inflight` into `crash_tombstone` (`phase=3`) via `outboxCrashReconcileStep`!
  let .ok storeBoot2 ← openCoreStore tmpRoot
    | do IO.eprintln "[orb-core-test] FAIL: second openCoreStore failed"; return 1
  if storeBoot2.bootEpoch != 2 then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: expected persistent bootEpoch=2 on reopen, got {storeBoot2.bootEpoch}"
    return 1
  let cpRows ← execParamQuery storeBoot2.missionsDb "SELECT status,COALESCE(terminal_reason,'') FROM missions WHERE id='m-crash-pend';" #[]
  let dpRows ← execParamQuery storeBoot2.missionsDb "SELECT status FROM missions WHERE id='m-deferred-pend';" #[]
  let qtRows ← execParamQuery storeBoot2.missionsDb "SELECT phase,state FROM remote_message_queue WHERE message_id='q-boot1-inflight';" #[]
  let cpStatus := match cpRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let cpReason := match cpRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let dpStatus := match dpRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let qtPhase := match qtRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let qtState := match qtRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if cpStatus != "waiting_rate_limit" || cpReason != "usage_limit_wait" || dpStatus != "pending" ||
     qtPhase != "3" || qtState != "crash_tombstone" then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: startup reconcile mismatch: cp=({cpStatus},{cpReason}) dp={dpStatus} qt=({qtPhase},{qtState})"
    return 1
  -- Verify restart durability: accepted id (`q-boot1-delivered`) is preserved (never overwritten/re-inserted) across restart,
  -- delivered & crash tombstone rows cannot be re-claimed or edited without operator requeue,
  -- and `mission_supervision` `bg_wait_arms` survived restart without zeroing!
  let dupAfterBoot ← enqueueStructuredFollowup storeBoot2 "core" "q-boot1-delivered" "m-r3c-local" "replay after restart" "desktop" "t-qd4"
  let reclaimDeliveredAfterBoot ← stepQueueItem storeBoot2 "core" "q-boot1-delivered" 0 "2" s!"{storeBoot2.bootEpoch}" "0" "t-qd5"
  let reclaimTombstoneAfterBoot ← stepQueueItem storeBoot2 "core" "q-boot1-inflight" 0 "2" s!"{storeBoot2.bootEpoch}" "0" "t-qb3"
  let editTombstoneAfterBoot ← stepQueueItem storeBoot2 "core" "q-boot1-inflight" 6 "2" s!"{storeBoot2.bootEpoch}" "0" "t-qb4" 0 0 "tampered"
  let .ok (bgBoot2, _) ← readSupervision storeBoot2 "m-r3d-place"
    | do closeCoreStore storeBoot2; IO.eprintln "[orb-core-test] FAIL: readSupervision boot2 failed"; return 1
  let sameDupContent := match dupAfterBoot with | .ok c => c == "delivered before crash" | .error _ => false
  let rejDelivered := match reclaimDeliveredAfterBoot with | .ok (.rejected _) => true | _ => false
  let rejTombstone := match reclaimTombstoneAfterBoot with | .ok (.rejected _) => true | _ => false
  let rejEditTombstone := match editTombstoneAfterBoot with | .ok (.rejected _) => true | _ => false
  if !sameDupContent || !rejDelivered || !rejTombstone || !rejEditTombstone || bgBoot2 == 0 then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: restart durability failed: sameDupContent={sameDupContent} rejD={rejDelivered} rejT={rejTombstone} rejEditT={rejEditTombstone} bgBoot2={bgBoot2}"
    return 1
  let bgStatusRows ← execParamQuery storeBoot2.missionsDb "SELECT status FROM missions WHERE id='m-r3d-place';" #[]
  let bgStatus := match bgStatusRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if bgStatus != "interrupted" then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: undurable waiting_background survived restart as {bgStatus}"
    return 1
  closeCoreStore storeBoot2
  return 0

private def sendTestHttp
    (appSt : CoreAppState) (validJwt method target body : String) (nowSec : UInt64) :
    IO (Except String (Nat × String)) := do
  let raw :=
    if body.isEmpty then
      s!"{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
    else
      s!"{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}".toUTF8
  let .ok req := parseRequest raw none | return .error s!"parseRequest failed for {method} {target}"
  let .ok resp ← dispatchCoreRequest appSt req nowSec | return .error s!"dispatch failed for {method} {target}"
  return .ok (resp.status, String.fromUTF8! resp.body)

private def runR3cdQueueAndContinuationTests
    (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  let failWith (msg : String) : IO UInt32 := do
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: {msg}"
    return 1

  -- Seed dedicated R3-C / R3-D test missions across local (`managed`), `client`, and `remote` placements
  for (mid, place, stStr) in #[("m-r3c-local", "managed", "active"), ("m-r3c-remote", "remote", "active"), ("m-r3d-cont", "managed", "awaiting_user"), ("m-r3d-place", "client", "awaiting_user")] do
    let .ok () ← upsertMission store {
      id := mid, title := s!"R3 {mid}", status := stStr,
      backend := "codex", modelOverride := "", modelEffort := "medium", workingDirectory := store.rootDir,
      placementKind := place, nodeBootEpoch := store.bootEpoch, updatedAt := s!"{nowSec}", totalCostCents := 0
    } | return (← failWith s!"upsertMission {mid} failed")

  -- 1. SM-04: Row-level queue CAS (`queued -> claimed -> delivered`), edit fence, crash tombstone & operator requeue
  let .ok (sEnq1, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue"
    "{\"id\":\"q-r3c-1\",\"mission_id\":\"m-r3c-local\",\"content\":\"first step\",\"source\":\"desktop\"}" nowSec
    | return (← failWith "POST /api/control/queue q-r3c-1 transport")
  if sEnq1 != 201 then return (← failWith s!"enqueue q-r3c-1 expected 201, got {sEnq1}")

  let .ok (sClaim1, bClaim1) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-1/step"
    s!"\{\"op\":0,\"run_generation\":1,\"node_boot_epoch\":{store.bootEpoch}}" nowSec
    | return (← failWith "claim q-r3c-1 transport")
  if sClaim1 != 200 || (bClaim1.splitOn "\"phase_name\":\"claimed\"").length != 2 then
    return (← failWith s!"claim q-r3c-1 mismatch: {sClaim1} {bClaim1}")

  -- Editing a claimed item MUST return 409
  let .ok (sEditClaimed, _) ← sendTestHttp appSt validJwt "PATCH" "/api/control/queue/q-r3c-1" "{\"content\":\"late edit\"}" nowSec
    | return (← failWith "PATCH claimed transport")
  if sEditClaimed != 409 then return (← failWith s!"PATCH claimed expected 409, got {sEditClaimed}")

  -- Confirm delivered (`op=1`, `delivery_seq=77`)
  let .ok (sDeliv1, bDeliv1) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-1/step"
    s!"\{\"op\":1,\"run_generation\":1,\"node_boot_epoch\":{store.bootEpoch},\"delivery_seq\":77}" nowSec
    | return (← failWith "deliver q-r3c-1 transport")
  if sDeliv1 != 200 || (bDeliv1.splitOn "\"delivered_seq\":77").length != 2 then
    return (← failWith s!"deliver q-r3c-1 mismatch: {sDeliv1} {bDeliv1}")

  -- Delivered item NEVER replays (`op=0`), edits (`PATCH`), or cancels (`op=5`)
  let .ok (sReplayDeliv, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-1/step"
    s!"\{\"op\":0,\"run_generation\":2,\"node_boot_epoch\":{store.bootEpoch}}" nowSec
    | return (← failWith "replay delivered transport")
  let .ok (sEditDeliv, _) ← sendTestHttp appSt validJwt "PATCH" "/api/control/queue/q-r3c-1" "{\"content\":\"after deliv\"}" nowSec
    | return (← failWith "edit delivered transport")
  let .ok (sCancelDeliv, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-1/step"
    s!"\{\"op\":5,\"run_generation\":2,\"node_boot_epoch\":{store.bootEpoch}}" nowSec
    | return (← failWith "cancel delivered transport")
  if sReplayDeliv != 409 || sEditDeliv != 409 || sCancelDeliv != 409 then
    return (← failWith s!"delivered queue fence violated: replay={sReplayDeliv} edit={sEditDeliv} cancel={sCancelDeliv}")

  -- Crash-tombstone flow (`q-r3c-tomb`): claim -> uncertain timeout (`op=3`) -> silent claim/requeue without operator confirmation rejected -> operator requeue (`operator_confirmed=true`) succeeds!
  let .ok (sEnq2, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue"
    "{\"id\":\"q-r3c-tomb\",\"mission_id\":\"m-r3c-local\",\"content\":\"uncertain msg\",\"source\":\"telegram\"}" nowSec
    | return (← failWith "enqueue q-r3c-tomb")
  let .ok (sClaim2, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-tomb/step"
    s!"\{\"op\":0,\"run_generation\":1,\"node_boot_epoch\":{store.bootEpoch}}" nowSec
    | return (← failWith "claim q-r3c-tomb")
  let .ok (sTomb, bTomb) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-tomb/step"
    s!"\{\"op\":3,\"run_generation\":1,\"node_boot_epoch\":{store.bootEpoch},\"uncertain_timeout\":true}" nowSec
    | return (← failWith "tombstone q-r3c-tomb")
  if sEnq2 != 201 || sClaim2 != 200 || sTomb != 200 || (bTomb.splitOn "\"phase_name\":\"crash_tombstone\"").length != 2 then
    return (← failWith s!"tombstone transition failed: {sTomb} {bTomb}")
  let .ok (sSilentClaim, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-tomb/step"
    s!"\{\"op\":0,\"run_generation\":2,\"node_boot_epoch\":{store.bootEpoch}}" nowSec
    | return (← failWith "silent claim tombstone")
  let .ok (sUnconfReq, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-tomb/requeue" "{\"operator_confirmed\":false}" nowSec
    | return (← failWith "unconfirmed requeue")
  let .ok (sEditTomb, _) ← sendTestHttp appSt validJwt "PATCH" "/api/control/queue/q-r3c-tomb" "{\"content\":\"edit tomb\"}" nowSec
    | return (← failWith "edit tombstone")
  if sSilentClaim != 409 || sUnconfReq != 409 || sEditTomb != 409 then
    return (← failWith s!"crash_tombstone block violated: claim={sSilentClaim} unconf={sUnconfReq} edit={sEditTomb}")
  let .ok (sConfReq, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r3c-tomb/requeue" "{\"operator_confirmed\":true}" nowSec
    | return (← failWith "confirmed requeue")
  if sConfReq != 200 then return (← failWith s!"confirmed requeue expected 200, got {sConfReq}")

  -- 2. SM-05: Structured deferred batches unpacked uniformly across sources & HTML trailer stripped; malformed rejected
  let validBatchJson := "{\"messages\":[[\"550e8400-e29b-41d4-a716-446655440000\",\"msg one\"],[\"550e8400-e29b-41d4-a716-446655440001\",\"msg two\"]]}"
  let validB64 := OrbBin.PosixExt.base64Encode validBatchJson.toUTF8
  let trailerContent := s!"Primary goal\n<!-- sandboxed:messages:v1:{validB64} -->"
  let enqTrailerBody := s!"\{\"id\":\"q-r3c-batch\",\"mission_id\":\"m-r3c-local\",\"content\":{jsonEscape trailerContent},\"source\":\"hermes\"}"
  let .ok (sBatchOk, bBatchOk) ← sendTestHttp appSt validJwt "POST" "/api/control/queue" enqTrailerBody nowSec
    | return (← failWith "enqueue trailer batch")
  if sBatchOk != 201 || (bBatchOk.splitOn "sandboxed:messages:v1:").length != 1 || (bBatchOk.splitOn "\"content\":\"Primary goal\"").length != 2 then
    return (← failWith s!"SM-05 trailer not stripped on write: {sBatchOk} {bBatchOk}")
  let bCntRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id='m-r3c-local' AND source='hermes';" #[]
  let bCnt := match bCntRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  if bCnt != 2 then return (← failWith s!"expected 2 unpacked rows in deferred_message_batches, got {bCnt}")

  -- Also test `deferred-unpack` on `missions.deferred_goal` with non-control source (`webhook`)
  let _ ← execParamQuery store.missionsDb "UPDATE missions SET deferred_goal=?1 WHERE id='m-r3c-remote';" #[trailerContent]
  let .ok (sUnpack, bUnpack) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3c-remote/deferred-unpack" "{\"source\":\"webhook\"}" nowSec
    | return (← failWith "deferred-unpack")
  let remGoalRows ← execParamQuery store.missionsDb "SELECT deferred_goal FROM missions WHERE id='m-r3c-remote';" #[]
  let remGoal := match remGoalRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if sUnpack != 200 || (bUnpack.splitOn "\"unpacked\":2").length != 2 || remGoal != "Primary goal" then
    return (← failWith s!"deferred-unpack mismatch: {sUnpack} {bUnpack} goal={remGoal}")

  -- Malformed UUID / duplicate IDs / empty content MUST return 400
  let badUuidB64 := OrbBin.PosixExt.base64Encode "{\"messages\":[[\"not-a-uuid\",\"hi\"]]}".toUTF8
  let dupUuidB64 := OrbBin.PosixExt.base64Encode "{\"messages\":[[\"550e8400-e29b-41d4-a716-446655440000\",\"a\"],[\"550e8400-e29b-41d4-a716-446655440000\",\"b\"]]}".toUTF8
  for badB64 in #[badUuidB64, dupUuidB64, "%%%not_base64%%%"] do
    let badMsg := s!"Goal\n<!-- sandboxed:messages:v1:{badB64} -->"
    let .ok (sBad, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue"
      s!"\{\"id\":\"q-bad\",\"mission_id\":\"m-r3c-local\",\"content\":{jsonEscape badMsg}}" nowSec
      | return (← failWith "bad batch transport")
    if sBad != 400 then return (← failWith s!"expected 400 on malformed deferred trailer, got {sBad}")

  -- 3. SM-06: Unified local (`m-r3c-local`) + remote (`m-r3c-remote`) `waiting_rate_limit` park & resume
  let dueRl := nowSec + 120
  for mid in #["m-r3c-local", "m-r3c-remote"] do
    -- Past `not_before` rejected (409)
    let .ok (sPast, _) ← sendTestHttp appSt validJwt "POST" s!"/api/control/missions/{mid}/rate-limit/park"
      s!"\{\"not_before\":{nowSec - 5},\"resume_intent\":true}" nowSec | return (← failWith "past park")
    if sPast != 409 then return (← failWith s!"{mid} past not_before should 409, got {sPast}")
    -- Valid park -> `waiting_rate_limit`
    let .ok (sPark, bPark) ← sendTestHttp appSt validJwt "POST" s!"/api/control/missions/{mid}/rate-limit/park"
      s!"\{\"not_before\":{dueRl},\"resume_intent\":true}" nowSec | return (← failWith "valid park")
    if sPark != 200 || (bPark.splitOn "\"status\":\"waiting_rate_limit\"").length != 2 then
      return (← failWith s!"{mid} park failed: {sPark} {bPark}")
    -- Early resume before `dueRl` rejected (409)
    let .ok (sEarly, _) ← sendTestHttp appSt validJwt "POST" s!"/api/control/missions/{mid}/rate-limit/resume" "{}" (nowSec + 30)
      | return (← failWith "early resume")
    if sEarly != 409 then return (← failWith s!"{mid} early resume should 409, got {sEarly}")
    -- Resume at `dueRl` -> `active`
    let .ok (sRes, bRes) ← sendTestHttp appSt validJwt "POST" s!"/api/control/missions/{mid}/rate-limit/resume" "{}" dueRl
      | return (← failWith "due resume")
    if sRes != 200 || (bRes.splitOn "\"status\":\"active\"").length != 2 then
      return (← failWith s!"{mid} resume failed: {sRes} {bRes}")

  -- 4. SM-07: Dedicated `mission_continuations` via MCP `/automations` payload, cron separation, replace, race, Hosted Stop vs local interrupt
  let mcpWakeBody1 :=
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"check child status\"}," ++
    "\"trigger\":{\"type\":\"interval\",\"seconds\":180},\"stop_policy\":{\"type\":\"after_first_fire\"}," ++
    "\"variables\":{\"__wakeup_request_id\":\"req-w-1\",\"__wakeup_reason\":\"poll child\",\"__wakeup_source\":\"automation-manager\"}}"
  let .ok (sW1, bW1) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/automations" mcpWakeBody1 nowSec
    | return (← failWith "arm wakeup 1")
  let .ok (sW1Dup, bW1Dup) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/automations" mcpWakeBody1 nowSec
    | return (← failWith "idempotent wakeup 1")
  if sW1 != 201 || sW1Dup != 201 || bW1 != bW1Dup then
    return (← failWith s!"idempotent wakeup mismatch: {sW1}/{sW1Dup} {bW1} vs {bW1Dup}")

  -- User cron table `mission_automations` MUST remain empty for one-shot wakeups; posting a real cron strips `__wakeup_*`
  let .ok (sCronList0, bCronList0) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-cont/automations" "" nowSec
    | return (← failWith "list cron 0")
  if sCronList0 != 200 || bCronList0 != "[]" then
    return (← failWith s!"one-shot wakeup leaked into mission_automations: {bCronList0}")
  let cronWithLeak := "{\"id\":\"cron-clean-1\",\"cron_expr\":\"*/15 * * * *\",\"prompt\":\"periodic\",\"variables\":{\"env\":\"prod\",\"__wakeup_reason\":\"strip_me\"}}"
  let .ok (sCronAdd, bCronAdd) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/automations" cronWithLeak nowSec
    | return (← failWith "add cron")
  if sCronAdd != 201 || (bCronAdd.splitOn "__wakeup_").length != 1 || (bCronAdd.splitOn "\"env\":\"prod\"").length != 2 then
    return (← failWith s!"cron __wakeup_* variable sanitization failed: {sCronAdd} {bCronAdd}")

  -- Second time wakeup with new `request_id` replaces the existing armed time wakeup in place (`count` stays 1)
  let mcpWakeBody2 :=
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"updated prompt\"}," ++
    "\"trigger\":{\"type\":\"interval\",\"seconds\":300},\"stop_policy\":{\"type\":\"after_first_fire\"}," ++
    "\"variables\":{\"__wakeup_request_id\":\"req-w-2\",\"__wakeup_reason\":\"updated reason\",\"__wakeup_source\":\"automation-manager\"}}"
  let .ok (sW2, bW2) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/automations" mcpWakeBody2 nowSec
    | return (← failWith "replace wakeup 2")
  if sW2 != 201 then return (← failWith s!"replace wakeup expected 201, got {sW2}")
  let contId := match (OrbBin.Json.parse bW2).toOption.bind (·.fieldStr? "id") with | some cid => cid | none => ""
  if contId.isEmpty then return (← failWith s!"missing continuation id in {bW2}")

  -- Check `orb/src/continuations.ts` contract + SM-01 parity across `GET /missions`, `GET /missions/:id`, and `GET /missions/:id/health`
  let expectedIso300 := formatEpochIso8601Utc (nowSec + 300)
  let _ ← execParamQuery store.missionsDb "UPDATE missions SET status='paused' WHERE id='m-r3d-cont';" #[]
  let .ok (sDet, bDet) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-cont" "" nowSec | return (← failWith "detail")
  let .ok (sHlth, bHlth) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-cont/health" "" nowSec | return (← failWith "health")
  let .ok (sList, bList) ← sendTestHttp appSt validJwt "GET" "/api/control/missions" "" nowSec | return (← failWith "list")
  if sDet != 200 || sHlth != 200 || sList != 200 ||
     (bDet.splitOn "\"health_verdict\":\"paused_wakeup\"").length != 2 ||
     (bHlth.splitOn "\"health_verdict\":\"paused_wakeup\"").length != 2 ||
     (bList.splitOn "\"health_verdict\":\"paused_wakeup\"").length != 2 ||
     (bDet.splitOn "\"state\":\"scheduled\"").length != 2 ||
     (bDet.splitOn s!"\"next_at\":\"{expectedIso300}\"").length != 2 ||
     (bList.splitOn s!"\"next_at\":\"{expectedIso300}\"").length != 2 ||
     (bDet.splitOn s!"\"next_at\":\"{nowSec + 300}\"").length != 1 ||
     (bDet.splitOn "\"reason\":\"updated reason\"").length != 2 then
    return (← failWith s!"SM-01/SM-07 projection mismatch:\ndetail={bDet}\nhealth={bHlth}")

  -- Local runner interrupt (`POST /interrupt`) MUST preserve armed continuation (`phase=1`)
  let .ok (sInt, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/interrupt" "{}" nowSec
    | return (← failWith "local interrupt")
  let .ok (_, bAfterInt) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-cont" "" nowSec
    | return (← failWith "detail after interrupt")
  if sInt != 200 || (bAfterInt.splitOn "\"state\":\"scheduled\"").length != 2 then
    return (← failWith s!"local interrupt wrongly revoked armed continuation: {bAfterInt}")

  -- Fire continuation (`action=resume` at due time) -> `queued`; then late `cancel` loses race -> 409!
  let .ok (sFire, _) ← sendTestHttp appSt validJwt "POST" s!"/api/control/automations/{contId}/action" "{\"action\":\"resume\"}" (nowSec + 301)
    | return (← failWith "fire continuation")
  let .ok (sCancelRace, _) ← sendTestHttp appSt validJwt "POST" s!"/api/control/automations/{contId}/action" "{\"action\":\"cancel\"}" (nowSec + 302)
    | return (← failWith "cancel race continuation")
  if sFire != 200 || sCancelRace != 409 then
    return (← failWith s!"continuation resume/cancel-race mismatch: fire={sFire} cancel={sCancelRace}")

  -- Arm a durable-job wakeup (`schedule_job_wakeup` shape), then Hosted Stop (`POST /stop`) bumps `run_generation` and revokes continuations + waiting queue!
  let jobWakeBody :=
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"on job done\"}," ++
    "\"trigger\":{\"type\":\"durable_job_terminal\",\"job_id\":\"550e8400-e29b-41d4-a716-446655440099\"}," ++
    "\"stop_policy\":{\"type\":\"after_first_fire\"}," ++
    "\"variables\":{\"__wakeup_request_id\":\"req-job-1\",\"__wakeup_reason\":\"await build\",\"__wakeup_source\":\"durable-job-terminal\"}}"
  let .ok (sJW, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/automations" jobWakeBody nowSec
    | return (← failWith "arm job wakeup")
  let .ok (sStop, bStop) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/stop" "{}" nowSec
    | return (← failWith "hosted stop")
  let .ok (sStaleArm, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-cont/automations"
    "{\"run_generation\":1,\"command_source\":{\"type\":\"inline\",\"content\":\"stale\"},\"trigger\":{\"type\":\"interval\",\"seconds\":60},\"stop_policy\":{\"type\":\"after_first_fire\"},\"variables\":{\"__wakeup_request_id\":\"req-stale-1\"}}" nowSec
    | return (← failWith "stale arm")
  if sJW != 201 || sStop != 200 || (bStop.splitOn "\"run_generation\":2").length != 2 || sStaleArm != 409 then
    return (← failWith s!"Hosted Stop / stale generation fence failed: jw={sJW} stop={sStop} ({bStop}) staleArm={sStaleArm}")

  -- 5. SM-10: `beginMissionRun` reads typed `missions.placement_kind` (ignoring adversarial `tags`) and retires stale armed continuations on generation advance
  let _ ← execParamQuery store.missionsDb "UPDATE missions SET run_generation=0,tags='[\"remote\",\"invalid-tag\"]' WHERE id='m-r3d-place';" #[]
  let .ok (sRun1, bRun1) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-place/runs/begin" "{\"run_id\":\"run-p-1\",\"owner_epoch\":1}" nowSec
    | return (← failWith "begin run 1")
  if sRun1 != 201 || (bRun1.splitOn "\"placement_kind\":\"client\"").length != 2 || (bRun1.splitOn "\"generation\":1").length != 2 then
    return (← failWith s!"SM-10 typed placement_kind mismatch: {sRun1} {bRun1}")
  -- Second `begin` while `run-p-1` is non-terminal MUST reject with 409
  let .ok (sRunDup, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3d-place/runs/begin" "{\"run_id\":\"run-p-2\",\"owner_epoch\":1}" nowSec
    | return (← failWith "begin dup run")
  if sRunDup != 409 then return (← failWith s!"concurrent non-terminal beginMissionRun expected 409, got {sRunDup}")

  -- 6. SM-09: Durable supervision counters + shared reconcile (`POST /api/control/missions/reconcile`)
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET status='waiting_background',node_boot_epoch=0 WHERE id='m-r3d-place';" #[]
  let _ ← execParamQuery store.missionsDb
    "UPDATE mission_runs SET execution_state='terminal' WHERE mission_id='m-r3d-place';" #[]
  let .ok (sRec, bRec) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/reconcile" "{}" nowSec
    | return (← failWith "shared reconcile")
  let .ok (sSup, bSup) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-place/supervision" "" nowSec
    | return (← failWith "get supervision")
  if sRec != 200 || sSup != 200 || (bSup.splitOn "\"bg_wait_arms\":1").length != 2 then
    return (← failWith s!"SM-09 shared reconcile / bg_wait_arms mismatch: rec={bRec} sup={bSup}")

  -- Round-2 BLOCK regressions (lifecycle CAS, trailer strip, durable background wait, rate-limit status).
  let .ok () ← upsertMission store {
    id := "m-r2-term", title := "Terminal Stop Fence", status := "completed",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    updatedAt := "t-r2", totalCostCents := 0
  } | return (← failWith "seed m-r2-term")
  let .ok (sStopTerm, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r2-term/stop" "{}" nowSec
    | return (← failWith "stop terminal")
  let .ok (sIntTerm, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r2-term/interrupt" "{}" nowSec
    | return (← failWith "interrupt terminal")
  let .ok (sStopMiss, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r2-missing/stop" "{}" nowSec
    | return (← failWith "stop missing")
  let .ok (sIntMiss, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r2-missing/interrupt" "{}" nowSec
    | return (← failWith "interrupt missing")
  if sStopTerm != 409 || sIntTerm != 409 || sStopMiss != 404 || sIntMiss != 404 then
    return (← failWith s!"BLOCK1 stop/interrupt codes: stopT={sStopTerm} intT={sIntTerm} stopM={sStopMiss} intM={sIntMiss}")
  let .ok () ← upsertMission store {
    id := "m-r2-run", title := "Terminal Begin Fence", status := "failed",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    updatedAt := "t-r2b", totalCostCents := 0, placementKind := "managed"
  } | return (← failWith "seed m-r2-run")
  let .ok (sBeginTerm, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r2-run/runs/begin" "{\"run_id\":\"run-term\",\"owner_epoch\":1}" nowSec
    | return (← failWith "begin terminal")
  if sBeginTerm != 409 then
    return (← failWith s!"BLOCK1 beginMissionRun on failed expected 409, got {sBeginTerm}")

  let trailB64 := OrbBin.PosixExt.base64Encode "{\"messages\":[[\"550e8400-e29b-41d4-a716-4466554400aa\",\"follow one\"]]}".toUTF8
  let trailBody := s!"Visible goal\n<!-- sandboxed:messages:v1:{trailB64} -->"
  let .ok (sTrail, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue"
    s!"\{\"id\":\"q-r2-trail\",\"mission_id\":\"m-r2-run\",\"content\":{jsonEscape trailBody}}" nowSec
    | return (← failWith "enqueue trailer")
  let trailRows ← execParamQuery store.missionsDb
    "SELECT payload FROM remote_message_queue WHERE message_id='q-r2-trail';" #[]
  let trailPayload := match trailRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let batchRows ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM deferred_message_batches WHERE mission_id='m-r2-run' AND message_id='550e8400-e29b-41d4-a716-4466554400aa';" #[]
  let batchN := match batchRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  if sTrail != 201 || (trailPayload.splitOn "sandboxed:messages").length != 1 || batchN != 1 then
    return (← failWith s!"BLOCK3 trailer persisted: status={sTrail} payload={trailPayload} batchN={batchN}")
  let .ok (sEditTrail, _) ← sendTestHttp appSt validJwt "PATCH" "/api/control/queue/q-r2-trail"
    s!"\{\"content\":{jsonEscape trailBody}}" nowSec | return (← failWith "edit trailer")
  if sEditTrail != 400 then
    return (← failWith s!"BLOCK2 edit trailer expected 400, got {sEditTrail}")
  let .ok (sEditClaim, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue/q-r2-trail/step"
    "{\"op\":0,\"run_generation\":1}" nowSec | return (← failWith "claim trail row")
  let .ok (sEditAfterClaim, _) ← sendTestHttp appSt validJwt "PATCH" "/api/control/queue/q-r2-trail"
    "{\"content\":\"too late\"}" nowSec | return (← failWith "edit claimed")
  if sEditClaim != 200 || sEditAfterClaim != 409 then
    return (← failWith s!"BLOCK2 claimed edit codes: claim={sEditClaim} edit={sEditAfterClaim}")

  let .ok () ← upsertMission store {
    id := "m-r2-bg", title := "Durable Background", status := "waiting_background",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    updatedAt := "t-r2c", totalCostCents := 0
  } | return (← failWith "seed m-r2-bg")
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET node_boot_epoch=0 WHERE id='m-r2-bg';" #[]
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,created_at,updated_at) " ++
     "VALUES('cont-r2-bg','m-r2-bg',1,1,1,'time','durable','stay','req-r2-bg','t','t');") #[]
  let .ok (sKeepBg, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/reconcile" "{}" nowSec
    | return (← failWith "reconcile durable bg")
  let bgKeepRows ← execParamQuery store.missionsDb "SELECT status FROM missions WHERE id='m-r2-bg';" #[]
  let bgKept := match bgKeepRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if sKeepBg != 200 || bgKept != "waiting_background" then
    return (← failWith s!"BLOCK4 durable waiting_background flipped to {bgKept}")

  let .ok (sRlArm, bRlArm) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r2-bg/remote-wait"
    "{\"node_id\":\"ashur\",\"failed_job_id\":\"job-rl-1\",\"scheduled_origin_job_id\":\"job-rl-1\",\"terminal_reason\":\"usage_limit_wait\",\"deadline_epoch\":1}" nowSec
    | return (← failWith "remote wait rate limit")
  let rlRows ← execParamQuery store.missionsDb "SELECT status,COALESCE(resume_intent,0) FROM missions WHERE id='m-r2-bg';" #[]
  let rlStatus := match rlRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let rlIntent := match rlRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if sRlArm != 200 || (bRlArm.splitOn "\"ok\":true").length != 2 || rlStatus != "waiting_rate_limit" || rlIntent != "1" then
    return (← failWith s!"BLOCK5 remote wait parked {rlStatus}/{rlIntent}: {sRlArm} {bRlArm}")
  let .ok rbReject ← restoreMissionStatus store "m-r2-bg" "interrupted" "usage_limit_wait" "t-rb3"
    | return (← failWith "rollback collision")
  if rbReject then
    return (← failWith "BLOCK5 waiting_rate_limit collided with interrupted rollback")

  -- SM-01: `GET /api/control/missions`, `GET /api/control/missions/:id`, and `GET /api/control/missions/:id/health`
  -- all include `mission_terminal_evidence` / `terminal_evidence` when present
  let .ok () ← upsertTerminalEvidence store {
    missionId := "m-r3d-cont"
    terminalReason := "completed_verified"
    summary := "r3d verified"
    artifactRef := "sha256:r3de0001"
    verified := true
    recordedAt := "2026-11-07T00:10:00Z"
  } | return (← failWith "upsertTerminalEvidence m-r3d-cont")
  let .ok (sEvList, bEvList) ← sendTestHttp appSt validJwt "GET" "/api/control/missions" "" nowSec
    | return (← failWith "list terminal evidence")
  let .ok (sEvGet, bEvGet) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-cont" "" nowSec
    | return (← failWith "get terminal evidence")
  let .ok (sEvHealth, bEvHealth) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3d-cont/health" "" nowSec
    | return (← failWith "health terminal evidence")
  if sEvList != 200 || sEvGet != 200 || sEvHealth != 200 ||
     (bEvList.splitOn "\"artifact_ref\":\"sha256:r3de0001\"").length != 2 ||
     (bEvGet.splitOn "\"artifact_ref\":\"sha256:r3de0001\"").length != 2 ||
     (bEvHealth.splitOn "\"artifact_ref\":\"sha256:r3de0001\"").length != 2 ||
     (bEvGet.splitOn "\"verified\":true").length != 2 then
    return (← failWith s!"SM-01 list/get/health terminal_evidence mismatch: get={bEvGet} health={bEvHealth}")

  -- 7. SM-13: `project_decisions.status` canonical (`pending | answered | dismissed`), `answered` derived, contradictory rejected with 400
  let .ok (sDecOk, bDecOk) ← sendTestHttp appSt validJwt "POST" "/api/control/projects/orb/decisions"
    "{\"id\":\"dec-1\",\"status\":\"answered\",\"question\":\"Ship R3?\",\"evidence\":\"green\"}" nowSec
    | return (← failWith "put decision ok")
  let .ok (sDecBad1, _) ← sendTestHttp appSt validJwt "POST" "/api/control/projects/orb/decisions"
    "{\"id\":\"dec-2\",\"status\":\"pending\",\"answered\":true,\"question\":\"Contradiction\"}" nowSec
    | return (← failWith "put decision bad 1")
  let .ok (sDecBad2, _) ← sendTestHttp appSt validJwt "POST" "/api/control/projects/orb/decisions"
    "{\"id\":\"dec-3\",\"status\":\"answered\",\"answered\":false,\"question\":\"Contradiction 2\"}" nowSec
    | return (← failWith "put decision bad 2")
  let .ok (sDecList, bDecList) ← sendTestHttp appSt validJwt "GET" "/api/control/projects/orb/decisions" "" nowSec
    | return (← failWith "list decisions")
  if sDecOk != 200 || (bDecOk.splitOn "\"answered\":true").length != 2 ||
     sDecBad1 != 400 || sDecBad2 != 400 ||
     sDecList != 200 || (bDecList.splitOn "\"status\":\"answered\"").length != 2 then
    return (← failWith s!"SM-13 decision invariant failed: ok={sDecOk} ({bDecOk}) bad1={sDecBad1} bad2={sDecBad2} list={bDecList}")

  return 0

private def runR3cdRound3BlockerTests
    (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  let failWith (msg : String) : IO UInt32 := do
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: {msg}"
    return 1

  -- Round-3 Blocker Regressions (`d0af28d5`, `SM-04..SM-11`):
  -- R3-BLOCK-1 (`SM-07` ISO-8601 `next_at` + `__wakeup_due_at` + job `next_at: null`):
  let iso2030 := "2030-10-30T13:30:00Z"
  let ep2030 := parseIso8601EpochU64? iso2030
  let ep2030Offset := parseIso8601EpochU64? "2030-10-30T15:30:00.250+02:00"
  if ep2030 != some 1919597400 || ep2030Offset != some 1919597400 || formatEpochIso8601Utc 1919597400 != iso2030 ||
     formatEpochIso8601Utc 0 != "1970-01-01T00:00:00Z" || (parseIso8601EpochU64? "1919597400").isSome then
    return (← failWith s!"R3-BLOCK-1 ISO-8601 codec roundtrip failed: ep={repr ep2030} off={repr ep2030Offset}")
  let .ok () ← upsertMission store {
    id := "m-r3b-iso", title := "ISO Wakeup Contract", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "managed", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r3b-iso")
  let wakeIsoBody :=
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"check build\"}," ++
    "\"trigger\":{\"type\":\"interval\",\"seconds\":60},\"stop_policy\":{\"type\":\"after_first_fire\"}," ++
    "\"variables\":{\"__wakeup_request_id\":\"req-iso-2030\",\"__wakeup_reason\":\"Check the build\"," ++
    "\"__wakeup_source\":\"orb-local\",\"__wakeup_due_at\":\"2030-10-30T13:30:00+00:00\",\"__wakeup_run_generation\":\"1\"}}"
  let .ok (sWiso, bWiso) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-iso/automations" wakeIsoBody nowSec
    | return (← failWith "arm iso wakeup")
  let wakeJobNullBody :=
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"after job\"}," ++
    "\"trigger\":{\"type\":\"durable_job_terminal\",\"job_id\":\"550e8400-e29b-41d4-a716-446655440077\"}," ++
    "\"stop_policy\":{\"type\":\"after_first_fire\"}," ++
    "\"variables\":{\"__wakeup_request_id\":\"req-job-null\",\"__wakeup_reason\":\"Wait job\",\"__wakeup_source\":\"durable-job-terminal\"}}"
  let .ok (sWjobN, bWjobN) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-iso/automations" wakeJobNullBody nowSec
    | return (← failWith "arm job null wakeup")
  let .ok (sDetIso, bDetIso) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r3b-iso" "" nowSec
    | return (← failWith "detail m-r3b-iso")
  let .ok (sListIso, bListIso) ← sendTestHttp appSt validJwt "GET" "/api/control/missions" "" nowSec
    | return (← failWith "list m-r3b-iso")
  let isoTsRows ← execParamQuery store.missionsDb
    "SELECT created_at,updated_at FROM mission_continuations WHERE mission_id='m-r3b-iso' AND request_id='req-iso-2030';" #[]
  let cAtIso := match isoTsRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let uAtIso := match isoTsRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if sWiso != 201 || sWjobN != 201 || sDetIso != 200 || sListIso != 200 ||
     (bWiso.splitOn "\"next_at\":\"2030-10-30T13:30:00Z\"").length != 2 ||
     (bWjobN.splitOn "\"next_at\":null").length != 2 ||
     (bDetIso.splitOn "\"next_at\":\"2030-10-30T13:30:00Z\"").length != 2 ||
     (bListIso.splitOn "\"next_at\":\"2030-10-30T13:30:00Z\"").length != 2 ||
     (bDetIso.splitOn "\"next_at\":null").length != 2 ||
     (bDetIso.splitOn "\"next_at\":\"1919597400\"").length != 1 ||
     (parseIso8601EpochU64? cAtIso).isNone || (parseIso8601EpochU64? uAtIso).isNone then
    return (← failWith s!"R3-BLOCK-1 ISO next_at / job null / wakeup_due_at failed:\nwiso={bWiso}\nwjob={bWjobN}\ndet={bDetIso}\ncAt={cAtIso}")

  -- Verify `__wakeup_run_generation` variable fence rejects stale generation (`99 != 1`) with 409
  let wakeStaleVarBody :=
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"stale var gen\"}," ++
    "\"trigger\":{\"type\":\"interval\",\"seconds\":60},\"stop_policy\":{\"type\":\"after_first_fire\"}," ++
    "\"variables\":{\"__wakeup_request_id\":\"req-stale-var\",\"__wakeup_run_generation\":\"99\"}}"
  let .ok (sWstaleVar, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-iso/automations" wakeStaleVarBody nowSec
    | return (← failWith "stale __wakeup_run_generation")
  if sWstaleVar != 409 then
    return (← failWith s!"R3-BLOCK-1 stale __wakeup_run_generation expected 409, got {sWstaleVar}")

  -- R3-BLOCK-2 (`POST /api/control/missions/:id/continuations/cancel` MUST revoke undelivered `effect_outbox`, `remote_message_queue`, and `queue_item_receipts`):
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO effect_outbox(effect_id,mission_id,state_revision,intent_kind,payload_json,phase,delivered,attempt_epoch,created_at,updated_at) " ++
     "VALUES('eff-cancel-plan','m-r3b-iso',1,'wakeup_dispatch','{}',0,0,1,'t0','t0')," ++
     "('eff-cancel-claim','m-r3b-iso',1,'wakeup_dispatch','{}',1,0,1,'t0','t0')," ++
     "('eff-cancel-deliv','m-r3b-iso',1,'wakeup_dispatch','{}',2,1,1,'t0','t0');") #[]
  let .ok (sEnqCancel, _) ← sendTestHttp appSt validJwt "POST" "/api/control/queue"
    "{\"id\":\"q-cancel-outbox\",\"mission_id\":\"m-r3b-iso\",\"content\":\"scheduled follow-up\",\"source\":\"durable_schedule\"}" nowSec
    | return (← failWith "enqueue q-cancel-outbox")
  let .ok (sCancelCont, bCancelCont) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-iso/continuations/cancel" "{}" nowSec
    | return (← failWith "POST continuations/cancel")
  let outboxCancelRows ← execParamQuery store.missionsDb
    "SELECT effect_id,phase,delivered FROM effect_outbox WHERE mission_id='m-r3b-iso' ORDER BY effect_id ASC;" #[]
  let qCancelRows ← execParamQuery store.missionsDb
    "SELECT state,phase FROM remote_message_queue WHERE message_id='q-cancel-outbox';" #[]
  let qrCancelRows ← execParamQuery store.missionsDb
    "SELECT phase FROM queue_item_receipts WHERE message_id='q-cancel-outbox';" #[]
  let effClaimPh := match outboxCancelRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let effDelivPh := match outboxCancelRows with | .ok rs => (rs[2]?.bind (·[1]?)).getD "" | .error _ => ""
  let effDelivFl := match outboxCancelRows with | .ok rs => (rs[2]?.bind (·[2]?)).getD "" | .error _ => ""
  let effPlanPh  := match outboxCancelRows with | .ok rs => (rs[3]?.bind (·[1]?)).getD "" | .error _ => ""
  let qCancState := match qCancelRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let qCancPhase := match qCancelRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let qrCancPhase := match qrCancelRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if sEnqCancel != 201 || sCancelCont != 200 || (bCancelCont.splitOn "\"cancelled\":2").length != 2 ||
     effClaimPh != "5" || effPlanPh != "5" || effDelivPh != "2" || effDelivFl != "1" ||
     qCancState != "cancelled" || qCancPhase != "4" || qrCancPhase != "4" then
    return (← failWith s!"R3-BLOCK-2 continuations/cancel outbox revocation failed: body={bCancelCont} claimPh={effClaimPh} planPh={effPlanPh} deliv={effDelivPh}/{effDelivFl} q={qCancState}/{qCancPhase} qr={qrCancPhase}")

  -- R3-BLOCK-3 (`hostedStop` single atomic `BEGIN IMMEDIATE` transaction):
  -- Install a test SQLite `BEFORE UPDATE ON mission_continuations` trigger for `m-r3b-stop-tx` that raises `ABORT` on revocation;
  -- if `hostedStop` ran across multiple transactions, `missions.status='interrupted'` or `run_generation+1` would commit before revocation failed!
  let .ok () ← upsertMission store {
    id := "m-r3b-stop-tx", title := "Atomic Hosted Stop", status := "active",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "managed", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r3b-stop-tx")
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,created_at,updated_at) " ++
     "VALUES('cont-stop-tx','m-r3b-stop-tx',1,1,?1,'time','atomic check','run','req-stop-tx','2026-11-07T00:00:00Z','2026-11-07T00:00:00Z');")
    #[s!"{nowSec + 600}"]
  let _ ← execParamQuery store.missionsDb
    "CREATE TEMP TRIGGER tr_abort_stop_tx BEFORE UPDATE ON mission_continuations WHEN OLD.mission_id='m-r3b-stop-tx' BEGIN SELECT RAISE(ABORT,'simulated_revoke_fault'); END;" #[]
  let stopTxAbort ← hostedStop store "m-r3b-stop-tx" (formatEpochIso8601Utc nowSec)
  let _ ← execParamQuery store.missionsDb "DROP TRIGGER IF EXISTS tr_abort_stop_tx;" #[]
  let postAbortRows ← execParamQuery store.missionsDb
    "SELECT status,COALESCE(run_generation,1),COALESCE(state_revision,1) FROM missions WHERE id='m-r3b-stop-tx';" #[]
  let postAbortContRows ← execParamQuery store.missionsDb
    "SELECT phase FROM mission_continuations WHERE id='cont-stop-tx';" #[]
  let paStatus := match postAbortRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let paGen    := match postAbortRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let paRev    := match postAbortRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let paContPh := match postAbortContRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if stopTxAbort.isOk || paStatus != "active" || paGen != "1" || paRev != "1" || paContPh != "1" then
    return (← failWith s!"R3-BLOCK-3 hostedStop was NOT atomic in a single transaction: res={repr stopTxAbort} status={paStatus} gen={paGen} rev={paRev} contPh={paContPh}")
  -- Now without the fault trigger, `hostedStop` commits interrupt + fence + continuation/outbox/run revocation atomically:
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO effect_outbox(effect_id,mission_id,state_revision,intent_kind,payload_json,phase,delivered,attempt_epoch,created_at,updated_at) VALUES('eff-stop-tx','m-r3b-stop-tx',1,'dispatch','{}',0,0,1,'t0','t0');" #[]
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO mission_runs(id,mission_id,generation,execution_state,terminal_reason,remote_job_id,updated_at) VALUES('run-stop-live','m-r3b-stop-tx',1,'running','','','t0');" #[]
  let .ok stopNextGen ← hostedStop store "m-r3b-stop-tx" (formatEpochIso8601Utc nowSec)
    | return (← failWith "hostedStop clean after trigger drop")
  let cleanStopRows ← execParamQuery store.missionsDb
    "SELECT status,run_generation,(SELECT phase FROM mission_continuations WHERE id='cont-stop-tx'),(SELECT phase FROM effect_outbox WHERE effect_id='eff-stop-tx'),(SELECT execution_state FROM mission_runs WHERE id='run-stop-live'),(SELECT terminal_reason FROM mission_runs WHERE id='run-stop-live'),(SELECT COUNT(*) FROM mission_runs WHERE mission_id='m-r3b-stop-tx' AND execution_state<>'terminal') FROM missions WHERE id='m-r3b-stop-tx';" #[]
  let csStatus := match cleanStopRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let csGen    := match cleanStopRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let csContPh := match cleanStopRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let csEffPh  := match cleanStopRows with | .ok rs => (rs[1]?.bind (·[3]?)).getD "" | .error _ => ""
  let csRunSt  := match cleanStopRows with | .ok rs => (rs[1]?.bind (·[4]?)).getD "" | .error _ => ""
  let csRunTr  := match cleanStopRows with | .ok rs => (rs[1]?.bind (·[5]?)).getD "" | .error _ => ""
  let csLiveCnt := match cleanStopRows with | .ok rs => ((rs[1]?.bind (·[6]?)).bind String.toNat?).getD 99 | .error _ => 99
  if stopNextGen != 2 || csStatus != "interrupted" || csGen != "2" || csContPh != "4" || csEffPh != "5" ||
     csRunSt != "terminal" || csRunTr != "hosted_stop" || csLiveCnt != 0 then
    return (← failWith s!"R3-BLOCK-3 hostedStop clean state mismatch: nextGen={stopNextGen} st={csStatus} gen={csGen} cont={csContPh} eff={csEffPh} run={csRunSt} tr={csRunTr} liveCnt={csLiveCnt}")
  -- Verify `isMissionIdleForCyberChange` (`PATCH /api/control/missions/:id/cyber`) sees zero live runs after `hostedStop`:
  let appStTmp := { appSt with cfg := { appSt.cfg with workingDir := store.rootDir } }
  let .ok (sCyberAfterStop, _) ← sendTestHttp appStTmp validJwt "PATCH" "/api/control/missions/m-r3b-stop-tx/cyber"
    "{\"mode\":\"daybreak\"}" nowSec
    | return (← failWith "PATCH cyber after hostedStop")
  if sCyberAfterStop != 200 then
    return (← failWith s!"BLOCK-1 PATCH /cyber rejected as non-idle after hostedStop: status={sCyberAfterStop}")

  -- R3-BLOCK-4 (`stepRemoteMissionReplay` fenced CAS status writes + `Orb.Lifecycle` superseded gate + no premature `run_generation` bump):
  let .ok () ← upsertMission store {
    id := "m-r3b-replay", title := "Fenced Remote Replay", status := "waiting_rate_limit",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "remote", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r3b-replay")
  let .ok () ← armRemoteMissionWait store "m-r3b-replay" "ashur" "job-fenced-0" "job-fenced-0" 3 (nowSec + 600) "usage_limit_wait" (formatEpochIso8601Utc nowSec)
    | return (← failWith "arm m-r3b-replay")
  -- Transient dispatch failure (`dispatchOutcome = 1 -> action = 4`) MUST NOT advance `missions.run_generation` (`1 -> 1`), while bumping `state_revision`:
  let preRepRows ← execParamQuery store.missionsDb "SELECT run_generation,state_revision FROM missions WHERE id='m-r3b-replay';" #[]
  let preRepGen := match preRepRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  let preRepRev := match preRepRows with | .ok rs => ((rs[1]?.bind (·[1]?)).bind String.toNat?).getD 0 | .error _ => 0
  let .ok repRetryRec ← stepRemoteMissionReplay store "m-r3b-replay" "ashur" "job-fenced-1" true 1 0 1 nowSec (formatEpochIso8601Utc nowSec)
    | return (← failWith "stepRemoteMissionReplay retry")
  let midRepRows ← execParamQuery store.missionsDb "SELECT run_generation,state_revision,status FROM missions WHERE id='m-r3b-replay';" #[]
  let midRepGen := match midRepRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  let midRepRev := match midRepRows with | .ok rs => ((rs[1]?.bind (·[1]?)).bind String.toNat?).getD 0 | .error _ => 0
  let midRepSt  := match midRepRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  if repRetryRec.action != 4 || midRepGen != preRepGen || midRepRev ≤ preRepRev || midRepSt != "waiting_rate_limit" then
    return (← failWith s!"R3-BLOCK-4 retry bumped run_generation prematurely or skipped state_revision: preGen={preRepGen} midGen={midRepGen} preRev={preRepRev} midRev={midRepRev} st={midRepSt}")
  -- Successful dispatch (`dispatchOutcome = 0 -> action = 3`) before deadline (`nowSec + 120 <= nowSec + 600`) advances `run_generation` by 1 (`1 -> 2`):
  let .ok repOkRec ← stepRemoteMissionReplay store "m-r3b-replay" "ashur" "job-fenced-2" true 0 1 1 (nowSec + 120) (formatEpochIso8601Utc (nowSec + 120))
    | return (← failWith "stepRemoteMissionReplay ok")
  let okRepRows ← execParamQuery store.missionsDb "SELECT run_generation,status FROM missions WHERE id='m-r3b-replay';" #[]
  let okRepGen := match okRepRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  let okRepSt  := match okRepRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if repOkRec.action != 3 || okRepGen != preRepGen + 1 || okRepSt != "active" then
    return (← failWith s!"R3-BLOCK-4 mark_replayed generation/status mismatch: gen={okRepGen} expected={preRepGen + 1} st={okRepSt}")
  -- Past-deadline terminal failure (`nowSec + 601 > nowSec + 600 -> action = 2`, `status = 'failed'`) ALSO keeps `run_generation` unadvanced (`1 -> 1`):
  let .ok () ← upsertMission store {
    id := "m-r3b-replay-exp", title := "Deadline Expired Replay", status := "waiting_rate_limit",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "remote", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r3b-replay-exp")
  let .ok () ← armRemoteMissionWait store "m-r3b-replay-exp" "ashur" "job-exp-0" "job-exp-0" 3 (nowSec + 600) "usage_limit_wait" (formatEpochIso8601Utc nowSec)
    | return (← failWith "arm m-r3b-replay-exp")
  let .ok repExpRec ← stepRemoteMissionReplay store "m-r3b-replay-exp" "ashur" "job-exp-1" true 0 1 1 (nowSec + 601) (formatEpochIso8601Utc (nowSec + 601))
    | return (← failWith "stepRemoteMissionReplay expired")
  let expRepRows ← execParamQuery store.missionsDb "SELECT run_generation,status FROM missions WHERE id='m-r3b-replay-exp';" #[]
  let expRepGen := match expRepRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  let expRepSt  := match expRepRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if repExpRec.action != 2 || expRepGen != 1 || expRepSt != "failed" then
    return (← failWith s!"R3-BLOCK-4 fail_deadline bumped run_generation or wrong status: action={repExpRec.action} gen={expRepGen} st={expRepSt}")
  -- Superseded mission (`superseded_by_mission_id != ''`) MUST be rejected by `Orb.Lifecycle` (`remote_replay_lifecycle_rejected`, HTTP 409) without mutating status!
  let .ok () ← upsertMission store {
    id := "m-r3b-replay-sup", title := "Superseded Replay Fence", status := "waiting_rate_limit",
    backend := "claude", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "remote", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r3b-replay-sup")
  let .ok () ← armRemoteMissionWait store "m-r3b-replay-sup" "ashur" "job-sup-0" "job-sup-0" 3 0 "usage_limit_wait" (formatEpochIso8601Utc nowSec)
    | return (← failWith "arm m-r3b-replay-sup")
  let _ ← execParamQuery store.missionsDb "UPDATE missions SET superseded_by_mission_id='m-successor-99' WHERE id='m-r3b-replay-sup';" #[]
  let .ok (sRepSup, bRepSup) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-replay-sup/remote-replay"
    "{\"node_id\":\"ashur\",\"candidate_job_id\":\"job-sup-1\",\"scheduled_origin\":true,\"dispatch_outcome\":0}" nowSec
    | return (← failWith "POST remote-replay superseded")
  let supRepStRows ← execParamQuery store.missionsDb "SELECT status,run_generation FROM missions WHERE id='m-r3b-replay-sup';" #[]
  let supRepSt := match supRepStRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let supRepGen := match supRepStRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if sRepSup != 409 || (bRepSup.splitOn "remote_replay_lifecycle_rejected").length != 2 || supRepSt != "waiting_rate_limit" || supRepGen != "1" then
    return (← failWith s!"R3-BLOCK-4 superseded remote-replay not fenced by Orb.Lifecycle: code={sRepSup} body={bRepSup} st={supRepSt} gen={supRepGen}")

  -- R3-BLOCK-5 (`beginMissionRun` passes honest lifecycle phase — rejects `active` and `pending` even with zero rows in `mission_runs`,
  -- and rejects a second live `active` run via `verifyRunLifecycleAdmit` when `mission_runs` has a live row):
  for (midAct, badStatus) in #[("m-r3b-honest-act", "active"), ("m-r3b-honest-pend", "pending")] do
    let .ok () ← upsertMission store {
      id := midAct, title := s!"Honest Phase {badStatus}", status := badStatus,
      backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
      placementKind := "managed", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
    } | return (← failWith s!"seed {midAct}")
    let .ok (sHonestRej, bHonestRej) ← sendTestHttp appSt validJwt "POST" s!"/api/control/missions/{midAct}/runs/begin"
      "{\"run_id\":\"run-should-reject\",\"owner_epoch\":1}" nowSec
      | return (← failWith s!"POST runs/begin {midAct}")
    let runCntRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM mission_runs WHERE mission_id=?1;" #[midAct]
    let runCnt := match runCntRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 99 | .error _ => 99
    if sHonestRej != 409 || (bHonestRej.splitOn s!"begin_run_mission_rejected:{badStatus}").length != 2 || runCnt != 0 then
      return (← failWith s!"R3-BLOCK-5 beginMissionRun allowed second live {badStatus} run: status={sHonestRej} body={bHonestRej} runCnt={runCnt}")

  -- Also verify `verifyRunLifecycleAdmit` (`begin_run_rejected`) blocks a second live run even if `missions.status` is `awaiting_user`:
  let .ok () ← upsertMission store {
    id := "m-r3b-honest-live", title := "Honest Live Run Row", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "managed", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r3b-honest-live")
  let .ok (sLive1, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-honest-live/runs/begin"
    "{\"run_id\":\"run-live-1\",\"owner_epoch\":1}" nowSec
    | return (← failWith "begin run-live-1")
  let _ ← execParamQuery store.missionsDb "UPDATE missions SET status='awaiting_user' WHERE id='m-r3b-honest-live';" #[]
  let .ok (sLive2, bLive2) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r3b-honest-live/runs/begin"
    "{\"run_id\":\"run-live-2\",\"owner_epoch\":1}" nowSec
    | return (← failWith "begin run-live-2")
  if sLive1 != 201 || sLive2 != 409 || (bLive2.splitOn "begin_run_rejected").length != 2 then
    return (← failWith s!"R3-BLOCK-5 live mission_runs row was not rejected by verifyRunLifecycleAdmit: s1={sLive1} s2={sLive2} b2={bLive2}")

  -- R4-BLOCK-2 (`GET /api/control/missions/:id` returns full `Mission` fields + compatibility tags with no shadowed duplicate route):
  let .ok () ← upsertMission store {
    id := "m-r4b-detail", title := "Detail Contract Mission", status := "awaiting_user",
    backend := "codex", modelOverride := "gpt-6.1-sol", modelEffort := "xhigh",
    workingDirectory := store.rootDir, project := "orb", track := "r3cd-track", repo := "Th0rgal/orb#1617",
    authorityMode := "writer", placementKind := "managed", supersededById := "m-r4b-succ",
    orphanedAt := "2026-11-07T01:02:03Z", reservedDiskGib := 24, tagsJson := "",
    nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 137
  } | return (← failWith "seed m-r4b-detail")
  let .ok (sDet4, bDet4) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r4b-detail" "" nowSec
    | return (← failWith "GET /api/control/missions/m-r4b-detail")
  let .ok detJv := OrbBin.Json.parse bDet4
    | return (← failWith s!"parse GET m-r4b-detail failed: {bDet4}")
  if sDet4 != 200 ||
     detJv.fieldStr? "model_override" != some "gpt-6.1-sol" ||
     detJv.fieldStr? "model_effort" != some "xhigh" ||
     detJv.fieldStr? "project" != some "orb" ||
     detJv.fieldStr? "track" != some "r3cd-track" ||
     detJv.fieldStr? "github_pr" != some "Th0rgal/orb#1617" ||
     detJv.fieldStr? "working_directory" != some store.rootDir ||
     detJv.fieldNat? "total_cost_cents" != some 137 ||
     detJv.fieldStr? "superseded_by_mission_id" != some "m-r4b-succ" ||
     detJv.fieldStr? "orphaned_at" != some "2026-11-07T01:02:03Z" ||
     detJv.fieldNat? "reserved_disk_gib" != some 24 ||
     (bDet4.splitOn "\"pr-writer\"").length != 2 ||
     (bDet4.splitOn "\"placement:managed\"").length != 2 ||
     (bDet4.splitOn "\"superseded_by:m-r4b-succ\"").length != 2 ||
     (bDet4.splitOn "\"orphaned\"").length != 2 ||
     (bDet4.splitOn "\"disk-gib:24\"").length != 2 then
    return (← failWith s!"R4-BLOCK-2 missionDetailJson field/tag parity failed: status={sDet4} body={bDet4}")

  -- R4-BLOCK-3 (`registerContinuation` multi-row time-wakeup replacement revokes extra armed rows so at most 1 armed time row remains):
  let .ok () ← upsertMission store {
    id := "m-r4b-multi-time", title := "Multi Time Wakeup Replace", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "local", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r4b-multi-time")
  let isoSeed := formatEpochIso8601Utc nowSec
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,job_id,source,error,recurrence,stop_after_first,created_at,updated_at) " ++
     "VALUES('cont-mt-1','m-r4b-multi-time',1,1,?1,'time','legacy-1','old-1','req-mt-1','','mcp','','once',1,?2,?2)," ++
     "('cont-mt-2','m-r4b-multi-time',1,1,?3,'time','legacy-2','old-2','req-mt-2','','mcp','','once',1,?2,?2)," ++
     "('cont-mt-3','m-r4b-multi-time',1,1,?4,'time','legacy-3','old-3','req-mt-3','','mcp','','once',1,?2,?2);")
    #[s!"{nowSec + 120}", isoSeed, s!"{nowSec + 240}", s!"{nowSec + 360}"]
  let .ok repContId ← registerContinuation store {
    id := "cont-mt-new", missionId := "m-r4b-multi-time", requestId := "req-mt-replace",
    prompt := "replaced-prompt", reason := "replaced-reason", source := "mcp",
    triggerKind := "time", dueEpoch := nowSec + 500
  } nowSec isoSeed
    | return (← failWith "registerContinuation multi-row time replace")
  let mtRows ← execParamQuery store.missionsDb
    "SELECT id,phase,prompt,due_epoch FROM mission_continuations WHERE mission_id='m-r4b-multi-time' ORDER BY id ASC;" #[]
  let mtArmedRows ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-r4b-multi-time' AND trigger_kind='time' AND phase=1;" #[]
  let mtArmedCnt := match mtArmedRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 99 | .error _ => 99
  let mtPh1 := match mtRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let mtPr1 := match mtRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let mtDu1 := match mtRows with | .ok rs => (rs[1]?.bind (·[3]?)).getD "" | .error _ => ""
  let mtPh2 := match mtRows with | .ok rs => (rs[2]?.bind (·[1]?)).getD "" | .error _ => ""
  let mtPh3 := match mtRows with | .ok rs => (rs[3]?.bind (·[1]?)).getD "" | .error _ => ""
   if repContId != "cont-mt-1" || mtArmedCnt != 1 || mtPh1 != "1" || mtPr1 != "replaced-prompt" ||
      mtDu1 != s!"{nowSec + 500}" || mtPh2 != "4" || mtPh3 != "4" then
     return (← failWith s!"R4-BLOCK-3 multi-row time wakeup replacement left extra armed rows: id={repContId} cnt={mtArmedCnt} ph1={mtPh1} pr1={mtPr1} du1={mtDu1} ph2={mtPh2} ph3={mtPh3}")

   return 0

private def runR3cdReviewFixTests
    (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  let failWith (msg : String) : IO UInt32 := do
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: {msg}"
    return 1

  let .ok () ← upsertMission store {
    id := "m-r5-fix", title := "Review Fixes", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "", workingDirectory := store.rootDir,
    placementKind := "managed", nodeBootEpoch := store.bootEpoch, updatedAt := formatEpochIso8601Utc nowSec, totalCostCents := 0
  } | return (← failWith "seed m-r5-fix")
  let .ok _ ← enqueueStructuredFollowup store "core" "q-r5-edit" "m-r5-fix" "before edit" "desktop" (formatEpochIso8601Utc nowSec)
    | return (← failWith "enqueue q-r5-edit")
  let _ ← execParamQuery store.missionsDb
    "UPDATE remote_message_queue SET claimed_generation=9,claim_boot_epoch=4,delivered_seq=3 WHERE message_id='q-r5-edit';" #[]
  let hostEdit ← stepQueueItem store "core" "q-r5-edit" 6 "1" s!"{store.bootEpoch}" "0" (formatEpochIso8601Utc nowSec) 0 0 "after edit"
  let specEdit := Orb.Lifecycle.stepQueueSlice
    { phaseCode := 0, claimedGeneration := 9, claimBootEpoch := 4, deliveredSeq := 3, editRevision := 0 }
    { opCode := 6, deferredUnpacked := 1, durablyStarted := 1, uncertainTimeout := 0,
      operatorConfirmedNotDelivered := 0, contentNonEmpty := 1, runGeneration := 1,
      nodeBootEpoch := store.bootEpoch, deliverySeq := 0 }
  let editRows ← execParamQuery store.missionsDb
    "SELECT phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision FROM remote_message_queue WHERE message_id='q-r5-edit';" #[]
  let recRows ← execParamQuery store.missionsDb
    "SELECT phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,content FROM queue_item_receipts WHERE message_id='q-r5-edit';" #[]
  let ePh := match editRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let eCg := match editRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let eBt := match editRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let eDs := match editRows with | .ok rs => (rs[1]?.bind (·[3]?)).getD "" | .error _ => ""
  let eRv := match editRows with | .ok rs => (rs[1]?.bind (·[4]?)).getD "" | .error _ => ""
  let rPh := match recRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let rCg := match recRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let rBt := match recRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let rDs := match recRows with | .ok rs => (rs[1]?.bind (·[3]?)).getD "" | .error _ => ""
  let rCt := match recRows with | .ok rs => (rs[1]?.bind (·[5]?)).getD "" | .error _ => ""
  let specCleared := specEdit.1.phaseCode == 0 && specEdit.1.claimedGeneration == 0 && specEdit.1.claimBootEpoch == 0 && specEdit.1.editRevision == 1
  let hostOk := match hostEdit with | .ok (.ok rec) => rec.phase == 0 && rec.content == "after edit" | _ => false
  if !hostOk || !specCleared || ePh != "0" || eCg != "0" || eBt != "0" || eDs != "3" || eRv != "1" ||
     rPh != "0" || rCg != "0" || rBt != "0" || rDs != "3" || rCt != "after edit" then
    return (← failWith s!"review edit claim fields: host={hostOk} spec={specCleared} q={ePh}/{eCg}/{eBt}/{eDs}/{eRv} rec={rPh}/{rCg}/{rBt}/{rDs}/{rCt}")
  let _ ← execParamQuery store.missionsDb
    "UPDATE remote_message_queue SET claimed_generation=5,claim_boot_epoch=2 WHERE message_id='q-r5-edit';" #[]
  let _ ← execParamQuery store.missionsDb
    "UPDATE queue_item_receipts SET claimed_generation=5,claim_boot_epoch=2 WHERE message_id='q-r5-edit';" #[]
  let .ok (sPatchEdit, _) ← sendTestHttp appSt validJwt "PATCH" "/api/control/queue/q-r5-edit"
    "{\"content\":\"patched edit\"}" nowSec | return (← failWith "PATCH q-r5-edit")
  let patchRows ← execParamQuery store.missionsDb
    "SELECT phase,claimed_generation,claim_boot_epoch,delivered_seq,edit_revision,(SELECT claimed_generation FROM queue_item_receipts WHERE message_id='q-r5-edit'),(SELECT claim_boot_epoch FROM queue_item_receipts WHERE message_id='q-r5-edit'),(SELECT edit_revision FROM queue_item_receipts WHERE message_id='q-r5-edit') FROM remote_message_queue WHERE message_id='q-r5-edit';" #[]
  let pCg := match patchRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let pBt := match patchRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let pRv := match patchRows with | .ok rs => (rs[1]?.bind (·[4]?)).getD "" | .error _ => ""
  let prCg := match patchRows with | .ok rs => (rs[1]?.bind (·[5]?)).getD "" | .error _ => ""
  let prBt := match patchRows with | .ok rs => (rs[1]?.bind (·[6]?)).getD "" | .error _ => ""
  let prRv := match patchRows with | .ok rs => (rs[1]?.bind (·[7]?)).getD "" | .error _ => ""
  if sPatchEdit != 200 || pCg != "0" || pBt != "0" || pRv != "2" || prCg != "0" || prBt != "0" || prRv != "2" then
    return (← failWith s!"review editRemoteMessage claim fields: st={sPatchEdit} q={pCg}/{pBt}/{pRv} rec={prCg}/{prBt}/{prRv}")

  let .ok _ ← enqueueStructuredFollowup store "core" "q-r5-deliv" "m-r5-fix" "keep me" "desktop" (formatEpochIso8601Utc nowSec)
    | return (← failWith "enqueue q-r5-deliv")
  let _ ← stepQueueItem store "core" "q-r5-deliv" 0 "1" s!"{store.bootEpoch}" "0" (formatEpochIso8601Utc nowSec)
  let _ ← stepQueueItem store "core" "q-r5-deliv" 1 "1" s!"{store.bootEpoch}" "11" (formatEpochIso8601Utc nowSec)
  let .ok _ ← enqueueStructuredFollowup store "core" "q-r5-wait" "m-r5-fix" "drop me" "desktop" (formatEpochIso8601Utc nowSec)
    | return (← failWith "enqueue q-r5-wait")
  let .ok _ ← revokeContinuations store "m-r5-fix" (formatEpochIso8601Utc nowSec) true
    | return (← failWith "revoke m-r5-fix")
  let keptRows ← execParamQuery store.missionsDb
    "SELECT state,phase FROM remote_message_queue WHERE message_id='q-r5-deliv';" #[]
  let dropRows ← execParamQuery store.missionsDb
    "SELECT state,phase,claimed_generation,claim_boot_epoch FROM remote_message_queue WHERE message_id='q-r5-wait';" #[]
  let dropRec ← execParamQuery store.missionsDb
    "SELECT phase,claimed_generation,claim_boot_epoch FROM queue_item_receipts WHERE message_id='q-r5-wait';" #[]
  let kSt := match keptRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let kPh := match keptRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let dSt := match dropRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let dPh := match dropRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let dCg := match dropRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let dBt := match dropRows with | .ok rs => (rs[1]?.bind (·[3]?)).getD "" | .error _ => ""
  let drPh := match dropRec with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let drCg := match dropRec with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if kSt != "delivered" || kPh != "2" || dSt != "cancelled" || dPh != "4" || dCg != "0" || dBt != "0" ||
     drPh != "4" || drCg != "0" then
    return (← failWith s!"review revoke delivered fence: kept={kSt}/{kPh} drop={dSt}/{dPh}/{dCg}/{dBt} rec={drPh}/{drCg}")

  let _ ← execParamQuery store.missionsDb "UPDATE missions SET run_generation=2,status='awaiting_user' WHERE id='m-r5-fix';" #[]
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,created_at,updated_at) " ++
     "VALUES('cont-r5-stale','m-r5-fix',1,1,1,'time','stale','stay','req-r5-stale','t','t');") #[]
  let _ ← execParamQuery store.missionsDb
    "CREATE TEMP TRIGGER tr_r5_resume BEFORE UPDATE ON mission_continuations WHEN OLD.id='cont-r5-stale' AND NEW.phase=3 BEGIN SELECT RAISE(ABORT,'resume_cas_fault'); END;" #[]
  let resumeFault ← actOnContinuation store "cont-r5-stale" "resume" (formatEpochIso8601Utc nowSec) nowSec
  let _ ← execParamQuery store.missionsDb "DROP TRIGGER IF EXISTS tr_r5_resume;" #[]
  let stalePh ← execParamQuery store.missionsDb "SELECT phase FROM mission_continuations WHERE id='cont-r5-stale';" #[]
  let staleKept := match stalePh with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if resumeFault.isOk || staleKept != "1" then
    return (← failWith s!"review resume CAS: res={repr resumeFault} phase={staleKept}")
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,created_at,updated_at) " ++
     "VALUES('cont-r5-cas0','m-r5-fix',1,1,1,'time','cas0','stay','req-r5-cas0','t','t');") #[]
  let _ ← execParamQuery store.missionsDb
    "CREATE TEMP TRIGGER tr_r5_cas0 BEFORE UPDATE ON mission_continuations WHEN OLD.id='cont-r5-cas0' AND NEW.phase=3 BEGIN SELECT RAISE(IGNORE); END;" #[]
  let cas0Res ← actOnContinuation store "cont-r5-cas0" "resume" (formatEpochIso8601Utc nowSec) nowSec
  let _ ← execParamQuery store.missionsDb "DROP TRIGGER IF EXISTS tr_r5_cas0;" #[]
  if cas0Res.toOption.isSome then
    return (← failWith s!"review resume 0-changes CAS accepted: {repr cas0Res}")
  let resumeOk ← sendTestHttp appSt validJwt "POST" "/api/control/automations/cont-r5-stale/action"
    "{\"action\":\"resume\"}" nowSec
  let sResumeStale := match resumeOk with | .ok (stCode, _) => stCode | .error _ => 0
  let staleAfter ← execParamQuery store.missionsDb "SELECT phase,error FROM mission_continuations WHERE id='cont-r5-stale';" #[]
  let saPh := match staleAfter with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let saEr := match staleAfter with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if sResumeStale != 409 || saPh != "3" || saEr != "stale_run_generation" then
    return (← failWith s!"review resume supersede: st={sResumeStale} phase={saPh} err={saEr}")

  let _ ← execParamQuery store.missionsDb "UPDATE missions SET status='awaiting_user',run_generation=1 WHERE id='m-r5-fix';" #[]
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,created_at,updated_at) " ++
     "VALUES('cont-r5-begin','m-r5-fix',1,1,1,'time','begin','stay','req-r5-begin','t','t');") #[]
  let _ ← execParamQuery store.missionsDb
    "CREATE TEMP TRIGGER tr_r5_begin0 BEFORE UPDATE ON mission_continuations WHEN OLD.id='cont-r5-begin' AND NEW.phase=3 BEGIN SELECT RAISE(IGNORE); END;" #[]
  let beginCas0 ← beginMissionRun store "m-r5-fix" "run-r5-cas0" (formatEpochIso8601Utc nowSec) 1
  let _ ← execParamQuery store.missionsDb "DROP TRIGGER IF EXISTS tr_r5_begin0;" #[]
  let beginCas0Lost := match beginCas0 with | .error "begin_run_cas_lost" => true | _ => false
  if !beginCas0Lost then
    return (← failWith s!"review beginMissionRun 0-changes CAS expected begin_run_cas_lost, got {repr beginCas0}")
  let _ ← execParamQuery store.missionsDb
    "CREATE TEMP TRIGGER tr_r5_begin BEFORE UPDATE ON mission_continuations WHEN OLD.id='cont-r5-begin' AND NEW.phase=3 BEGIN SELECT RAISE(ABORT,'begin_cas_fault'); END;" #[]
  let beginFault ← beginMissionRun store "m-r5-fix" "run-r5-fault" (formatEpochIso8601Utc nowSec) 1
  let _ ← execParamQuery store.missionsDb "DROP TRIGGER IF EXISTS tr_r5_begin;" #[]
  let beginPh ← execParamQuery store.missionsDb
    "SELECT phase,(SELECT COUNT(*) FROM mission_runs WHERE id='run-r5-fault'),(SELECT status FROM missions WHERE id='m-r5-fix') FROM mission_continuations WHERE id='cont-r5-begin';" #[]
  let bPh := match beginPh with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let bRuns := match beginPh with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let bSt := match beginPh with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  if beginFault.isOk || bPh != "1" || bRuns != "0" || bSt != "awaiting_user" then
    return (← failWith s!"review beginMissionRun CAS: res={repr beginFault} phase={bPh} runs={bRuns} status={bSt}")
  let .ok beginOk ← beginMissionRun store "m-r5-fix" "run-r5-ok" (formatEpochIso8601Utc nowSec) 1
    | return (← failWith "beginMissionRun after trigger drop")
  let beginAfter ← execParamQuery store.missionsDb "SELECT phase FROM mission_continuations WHERE id='cont-r5-begin';" #[]
  let baPh := match beginAfter with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if beginOk.generation != 2 || baPh != "3" then
    return (← failWith s!"review beginMissionRun supersede: gen={beginOk.generation} phase={baPh}")
  -- Superseded (`phase=3`) and prior-generation fired (`phase=2, run_generation < missions.run_generation`) rows
  -- MUST NOT leak into `GET /missions/:id` or `GET /missions` `continuation.items` as `"error"` / `"queued"`!
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,due_epoch,trigger_kind,reason,prompt,request_id,created_at,updated_at) " ++
     "VALUES('cont-r5-old-fired','m-r5-fix',1,2,1,'time','old-fired','stay','req-r5-old-fired','t','t');") #[]
  let .ok (sSupDet, bSupDet) ← sendTestHttp appSt validJwt "GET" "/api/control/missions/m-r5-fix" "" nowSec
    | return (← failWith "superseded continuation detail")
  let .ok (sSupList, bSupList) ← sendTestHttp appSt validJwt "GET" "/api/control/missions?limit=50" "" nowSec
    | return (← failWith "superseded continuation list")
  if sSupDet != 200 || sSupList != 200 ||
     (bSupDet.splitOn "\"state\":\"error\"").length != 1 ||
     (bSupDet.splitOn "\"id\":\"cont-r5-old-fired\"").length != 1 ||
     (bSupList.splitOn "stale_run_generation").length != 1 ||
     (bSupList.splitOn "\"id\":\"cont-r5-old-fired\"").length != 1 then
    return (← failWith s!"superseded/stale-fired continuation leaked into mission projection:\ndet={bSupDet}\nlist={bSupList}")

  let preAuto ← execParamQuery store.missionsDb
    "SELECT (SELECT COUNT(*) FROM mission_automations),(SELECT COUNT(*) FROM mission_continuations);" #[]
  let preA := match preAuto with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let preC := match preAuto with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let .ok (sMissCron, bMissCron) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r5-missing/automations"
    "{\"cron_expr\":\"0 * * * *\",\"prompt\":\"nope\"}" nowSec | return (← failWith "missing cron")
  let .ok (sMissWake, bMissWake) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r5-missing/automations"
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"nope\"},\"trigger\":{\"type\":\"interval\",\"seconds\":60},\"stop_policy\":{\"type\":\"after_first_fire\"},\"variables\":{\"__wakeup_request_id\":\"req-missing\"}}" nowSec
    | return (← failWith "missing wakeup")
  let postAuto ← execParamQuery store.missionsDb
    "SELECT (SELECT COUNT(*) FROM mission_automations),(SELECT COUNT(*) FROM mission_continuations);" #[]
  let postA := match postAuto with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let postC := match postAuto with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  if sMissCron != 404 || (bMissCron.splitOn "mission_not_found").length != 2 ||
     sMissWake != 404 || (bMissWake.splitOn "mission_not_found").length != 2 ||
     postA != preA || postC != preC then
    return (← failWith s!"review missing mission automations: cron={sMissCron} {bMissCron} wake={sMissWake} {bMissWake} counts={preA}/{preC}->{postA}/{postC}")

  let preJob ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-r5-fix';" #[]
  let preJN := match preJob with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let .ok (sEmptyJob, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r5-fix/automations"
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"bad job\"},\"trigger\":{\"type\":\"durable_job_terminal\",\"job_id\":\"\"},\"stop_policy\":{\"type\":\"after_first_fire\"}}" nowSec
    | return (← failWith "empty job_id")
  let afterEmpty ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-r5-fix';" #[]
  let afterEmptyN := match afterEmpty with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let .ok (sGoodJob, _) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r5-fix/automations"
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"good job\"},\"trigger\":{\"type\":\"durable_job_terminal\",\"job_id\":\"job-r5-1\"},\"stop_policy\":{\"type\":\"after_first_fire\"},\"variables\":{\"__wakeup_request_id\":\"req-r5-job\"}}" nowSec
    | return (← failWith "nonempty job_id")
  let .ok (sReplJob, bReplJob) ← sendTestHttp appSt validJwt "POST" "/api/control/missions/m-r5-fix/automations"
    "{\"command_source\":{\"type\":\"inline\",\"content\":\"replaced job\"},\"trigger\":{\"type\":\"durable_job_terminal\",\"job_id\":\"job-r5-1\"},\"stop_policy\":{\"type\":\"after_first_fire\"},\"variables\":{\"__wakeup_request_id\":\"req-r5-job-2\"}}" nowSec
    | return (← failWith "replace job_id")
  let jobCnt ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-r5-fix' AND job_id='job-r5-1' AND phase=1;" #[]
  let jN := match jobCnt with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if sEmptyJob != 400 || afterEmptyN != preJN || sGoodJob != 201 || sReplJob != 201 || jN != "1" || preJN == "" then
    return (← failWith s!"review empty job_id: empty={sEmptyJob} pre={preJN} afterEmpty={afterEmptyN} good={sGoodJob} repl={sReplJob} {bReplJob} armed={jN}")

  return 0

private def runLifecycleCompositionTests : IO UInt32 := do
  let mOk := Orb.Lifecycle.verifyMissionLifecycleAdmit 0 0 0 0 0 1 5 5 10 20 == 1
  let mSupRej := Orb.Lifecycle.verifyMissionLifecycleAdmit 0 0 1 0 0 1 5 5 10 20 == 0
  let rReenterRej := Orb.Lifecycle.verifyRunLifecycleAdmit 4 0 0 0 0 0 0 8 8 7 7 == 0
  let rNextGenOk := Orb.Lifecycle.verifyRunLifecycleAdmit 4 0 0 0 0 0 0 8 9 7 7 == 1
  let qAckRej := Orb.Lifecycle.verifyQueueItemAdmit 2 0 1 0 0 0 0 0 9 3 3 1 == 0
  let cNoRecRej := Orb.Lifecycle.verifyCancelProtocolAdmit 1 2 0 0 6 6 == 0
  let cWithRecOk := Orb.Lifecycle.verifyCancelProtocolAdmit 1 2 1 0 6 6 == 1
  let wEarlyRej := Orb.Lifecycle.verifyWakeupContinuationAdmit 1 2 0 0 4 4 20 10 == 0
  let wDueOk := Orb.Lifecycle.verifyWakeupContinuationAdmit 1 2 0 0 4 4 10 20 == 1
  let rWrapRej := Orb.Lifecycle.verifyRunLifecycleAdmit 4 0 0 0 0 0 0
    0xFFFFFFFFFFFFFFFF 0 7 7 == 0
  let rSupSticky := (Orb.Lifecycle.stepRunSlice
    { phaseCode := 2, ownerSuperseded := 1, activeToolCalls := 0, runGeneration := 4, durableOwnerEpoch := 7 }
    { opCode := 4, hasStructuredReceipt := 1, hasAbortReceipt := 0, drainTimedOut := 0,
      markOwnerSuperseded := 0, nextToolCalls := 0, proposedGeneration := 4, callerOwnerEpoch := 7 }).1.ownerSuperseded == 1
  if !(mOk && mSupRej && rReenterRej && rNextGenOk && rWrapRej && rSupSticky && qAckRej &&
       cNoRecRej && cWithRecOk && wEarlyRej && wDueOk) then
    IO.eprintln "[orb-core-test] FAIL: Orb.Lifecycle R3-A gate invariants failed"
    return 1
  return 0

private def runHarnessCloudCompositionTests : IO UInt32 := do
  let ctSubmitOk := Orb.HarnessCloud.verifyCloudTurnAdmit 0 0 0 0 0 0 1 2 0 0 100 100 == 1
  let ctUncRej := Orb.HarnessCloud.verifyCloudTurnAdmit 4 0 0 0 0 0 1 2 0 0 100 100 == 0
  let ctCancelNoRecRej := Orb.HarnessCloud.verifyCloudTurnAdmit 5 9 0 0 0 0 2 2 10 0 100 200 == 0
  let hsUnderflowRej := Orb.HarnessCloud.verifyHarnessSessionAdmit 2 3 0 0 0 0 4 4 == 0
  let hsDeadNoRecRej := Orb.HarnessCloud.verifyHarnessSessionAdmit 4 10 0 0 0 0 4 4 == 0
  let paPreOk := Orb.HarnessCloud.verifyProviderAttemptAdmit 0 0 0 7 0 2 0 3 5 5 20 10 == 1
  let paCommittedPass := Orb.HarnessCloud.classifyProviderAttempt 1 0 7 7 1 2 2 3 5 5 20 10 == 8
  let paCommittedUnpinnedRej := Orb.HarnessCloud.classifyProviderAttempt 1 0 0 7 1 2 0 3 5 5 20 10 == 0
  let paCommittedFaultAbort := Orb.HarnessCloud.classifyProviderAttempt 1 4 7 7 1 2 0 3 5 5 20 10 == 4
  let paCommittedNoDispatch :=
    let s : Orb.HarnessCloud.ProviderAttemptSliceState :=
      { firstByteCommitted := 1, pinnedAccountId := 7, attemptsUsed := 1,
        transientStreak := 2, routeGeneration := 5, cooldownUntilEpoch := 10 }
    let ev : Orb.HarnessCloud.ProviderAttemptSliceEvent :=
      { chunkCommits := 0, failureReason := 0, candidateAccountId := 7, maxRetries := 2,
        transientThreshold := 3, attemptGeneration := 5, nowEpoch := 20, nextCooldownEpoch := 30 }
    Orb.HarnessCloud.stepProviderAttemptSlice s ev == (s, [])
  let arRevokedRej := Orb.HarnessCloud.verifyAuthRefreshAdmit 3 0 0 0 4 5 99 99 10 20 == 0
  let arCommitOk := Orb.HarnessCloud.verifyAuthRefreshAdmit 2 2 1 1 4 4 99 99 10 20 == 1
  if !(ctSubmitOk && ctUncRej && ctCancelNoRecRej && hsUnderflowRej && hsDeadNoRecRej &&
       paPreOk && paCommittedPass && paCommittedUnpinnedRej && paCommittedFaultAbort &&
       paCommittedNoDispatch && arRevokedRej && arCommitOk) then
    IO.eprintln "[orb-core-test] FAIL: Orb.HarnessCloud R4-A gate invariants failed"
    return 1
  return 0

private def runManagedNodeCompositionTests : IO UInt32 := do
  let vmResSameBootRej := Orb.ManagedNode.verifyVmLifecycleAdmit 2 2 0 0 4 4 10 10 == 0
  let vmResNextBootOk := Orb.ManagedNode.verifyVmLifecycleAdmit 2 2 0 0 4 5 10 10 == 1
  let vmRepRunningOk := Orb.ManagedNode.verifyVmLifecycleAdmit 1 3 0 0 4 5 10 10 == 1
  let vmRepStoppedOk := Orb.ManagedNode.verifyVmLifecycleAdmit 2 3 0 0 4 5 10 10 == 1
  let vmDelMinLeaseRej := Orb.ManagedNode.verifyVmLifecycleAdmit 1 4 0 1 4 4 5 10 == 0
  let vmDelExpiredOk := Orb.ManagedNode.verifyVmLifecycleAdmit 1 4 0 1 4 4 10 10 == 1
  let vmStopIneligible := (Orb.ManagedNode.stepVmSlice
    { phaseCode := 1, activeComputeEligible := 1, nodeBootEpoch := 4, deletableAt := 10 }
    { opCode := 1, ownerLive := 0, idleElapsed := 0, presentedBootEpoch := 4, nowEpoch := 6 }).1.activeComputeEligible == 0
  let claimStoppedRej := Orb.ManagedNode.verifyVmClaimAdmit 0 0 1 0 0 0 0 7 4 4 == 0
  let claimRunningOk := Orb.ManagedNode.verifyVmClaimAdmit 0 0 1 0 1 1 0 7 4 4 == 1
  let relStoppedOk := Orb.ManagedNode.verifyVmClaimAdmit 1 1 1 0 0 0 7 7 4 4 == 1
  let jobCrossBootRej := Orb.ManagedNode.verifyRemoteJobAdmit 1 2 9 9 3 4 == 0
  let jobUncertainSticky := Orb.ManagedNode.verifyRemoteJobAdmit 2 5 9 9 4 4 == 0
  let procTicksRej := Orb.ManagedNode.verifyProcLivenessAdmit 1 2 0 0 42 42 1000 1001 == 0
  let relayLeaseNoPop := (Orb.ManagedNode.stepRelaySlice
    { phaseCode := 0, retired := 0, heldLeaseId := 0, leaseEpoch := 0, nodeBootEpoch := 4 }
    { opCode := 0, presentedLeaseId := 9, presentedBootEpoch := 4, nowEpoch := 12 }).1.retired == 0
  let relayAckRetires := (Orb.ManagedNode.stepRelaySlice
    { phaseCode := 1, retired := 0, heldLeaseId := 9, leaseEpoch := 12, nodeBootEpoch := 4 }
    { opCode := 1, presentedLeaseId := 9, presentedBootEpoch := 4, nowEpoch := 13 }).1.retired == 1
  let relayUncertainRetryRej := Orb.ManagedNode.verifyRelayCommandAdmit 3 4 9 9 4 4 == 0
  let relayUncertainReconcileOk := Orb.ManagedNode.verifyRelayCommandAdmit 3 3 9 9 4 4 == 1
  if !(vmResSameBootRej && vmResNextBootOk && vmRepRunningOk && vmRepStoppedOk &&
       vmDelMinLeaseRej && vmDelExpiredOk && vmStopIneligible &&
       claimStoppedRej && claimRunningOk && relStoppedOk &&
       jobCrossBootRej && jobUncertainSticky && procTicksRej &&
       relayLeaseNoPop && relayAckRetires && relayUncertainRetryRej && relayUncertainReconcileOk) then
    IO.eprintln "[orb-core-test] FAIL: Orb.ManagedNode R5-A gate invariants failed"
    return 1
  return 0

private def runCustomProviderRateLimitTests
    (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  -- Custom provider rate-limit CRUD, out-of-range rejection, `/resolve` projection & proactive proxy pacing spillover
  if verifyProviderPacingAdmission 300 0 60 2 42 1 10 1 != 1 ||
     verifyProviderPacingAdmission 300 0 0 2 2 2 2 2 != 0 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: verifyProviderPacingAdmission spec gate mismatch"
    return 1

  let createProvBody := "{\"id\":\"eth-1\",\"provider_type\":\"custom\",\"name\":\"Ethereum Foundation\",\"base_url\":\"https://inference.ethereum.foundation/v1\",\"api_key\":\"sk-secret-do-not-leak\",\"rpm_limit\":300,\"custom_models\":[{\"id\":\"glm-5.3\",\"max_concurrency\":2},{\"id\":\"qwen3.8-27b\",\"rpm_limit\":60,\"tpm_limit\":200000}]}"
  let createProvRaw := s!"POST /api/ai/providers HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {createProvBody.utf8ByteSize}\r\n\r\n{createProvBody}".toUTF8
  let .ok createProvReq := parseRequest createProvRaw none | do closeCoreStore store; return 1
  let .ok createProvResp ← dispatchCoreRequest appSt createProvReq nowSec | do closeCoreStore store; return 1
  let createProvStr := String.fromUTF8! createProvResp.body
  if createProvResp.status != 201 ||
     (createProvStr.splitOn "sk-secret-do-not-leak").length != 1 ||
     (createProvStr.splitOn "\"rpm_limit\":300").length != 2 ||
     (createProvStr.splitOn "\"max_concurrency\":2").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: POST /api/ai/providers mismatch ({createProvResp.status}): {createProvStr}"
    return 1

  let badProvBody := "{\"rpm_limit\":0}"
  let badProvRaw := s!"PUT /api/ai/providers/eth-1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {badProvBody.utf8ByteSize}\r\n\r\n{badProvBody}".toUTF8
  let .ok badProvReq := parseRequest badProvRaw none | do closeCoreStore store; return 1
  let .ok badProvResp ← dispatchCoreRequest appSt badProvReq nowSec | do closeCoreStore store; return 1
  if badProvResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: out-of-range PUT /api/ai/providers/eth-1 returned {badProvResp.status}"
    return 1

  let chainCreateBody := "{\"id\":\"obliterated\",\"name\":\"obliterated\",\"entries\":[{\"provider_id\":\"custom:eth-1\",\"model_id\":\"glm-5.3\"},{\"provider_id\":\"custom:eth-1\",\"model_id\":\"qwen3.8-27b\"}]}"
  let chainCreateRaw := s!"POST /api/model-routing/chains HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {chainCreateBody.utf8ByteSize}\r\n\r\n{chainCreateBody}".toUTF8
  let .ok chainCreateReq := parseRequest chainCreateRaw none | do closeCoreStore store; return 1
  let .ok chainCreateResp ← dispatchCoreRequest appSt chainCreateReq nowSec | do closeCoreStore store; return 1
  if chainCreateResp.status != 201 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: POST /api/model-routing/chains returned {chainCreateResp.status}"
    return 1

  let resolveRaw := s!"GET /api/model-routing/chains/obliterated/resolve HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok resolveReq := parseRequest resolveRaw none | do closeCoreStore store; return 1
  let .ok resolveResp ← dispatchCoreRequest appSt resolveReq nowSec | do closeCoreStore store; return 1
  let resolveStr := String.fromUTF8! resolveResp.body
  if resolveResp.status != 200 ||
     (resolveStr.splitOn "\"rpm_limit\":300").length != 3 ||
     (resolveStr.splitOn "\"model_max_concurrency\":2").length != 2 ||
     (resolveStr.splitOn "\"model_rpm_limit\":60").length != 2 ||
     (resolveStr.splitOn "\"model_tpm_limit\":200000").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: GET /api/model-routing/chains/obliterated/resolve mismatch: {resolveStr}"
    return 1

  -- Proactive proxy spillover on saturated `modelRpmLimit := some 1` + upstream `x-litellm-key-rpm-limit` header learning
  let pacedTracker ← newProxyPacingTracker
  let pacedChain : RoutingChain := {
    id := "paced", name := "paced",
    targets := #[
      {
        accountId := "eth-learn", provider := "custom:eth-learn",
        baseUrl := "https://inference.ethereum.foundation/v1", apiKey := "k1",
        modelId := "qwen3.8-27b", modelRpmLimit? := some 1
      },
      {
        accountId := "eth-backup", provider := "custom:eth-backup",
        baseUrl := "https://inference.ethereum.foundation/v1", apiKey := "k2",
        modelId := "deepseek-v4.1-flash"
      }
    ]
  }
  let pacedMock := some fun (tgt : ProviderTarget) => do
    return .ok {
      status := 200,
      headers := #[("Content-Type", "application/json"), ("x-litellm-key-rpm-limit", "300")],
      body := s!"\{\"model\":\"{tgt.modelId}\"}".toUTF8
    }
  let pOut1 ← forwardProxyChain pacedChain "POST" "/v1/chat/completions" #[] "{\"model\":\"paced\"}".toUTF8 pacedMock false (some pacedTracker)
  let pOut2 ← forwardProxyChain pacedChain "POST" "/v1/chat/completions" #[] "{\"model\":\"paced\"}".toUTF8 pacedMock false (some pacedTracker)
  let learnedRpm? ← lookupObservedKeyRpm? pacedTracker "eth-learn"
  if pOut1.selectedAccount != "eth-learn" || pOut2.selectedAccount != "eth-backup" || learnedRpm? != some 300 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: proactive pacing spillover or header learning mismatch ({pOut1.selectedAccount}, {pOut2.selectedAccount}, {repr learnedRpm?})"
    return 1
  return 0

private def runFastMemoryBrokerTests
    (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  -- (a) Proxy 402 (`particle-ai/particle-1`) pre-header failover -> 200 on fallback, and all-402 -> `out_of_credit`
  let chain402Fallback : RoutingChain := {
    id := "c-402", name := "particle-then-claude",
    targets := #[
      { accountId := "particle-1", provider := "particle", baseUrl := "https://api.particle.ai", apiKey := "pk", modelId := "particle-ai/particle-1" },
      { accountId := "claude-2", provider := "anthropic", baseUrl := "https://api.anthropic.com", apiKey := "ak", modelId := "claude" }
    ]
  }
  let out402Ok ← forwardProxyChain chain402Fallback "POST" "/v1/chat/completions" #[] "{}".toUTF8 (some fun tgt => do
    if tgt.accountId == "particle-1" then
      return .ok { status := 402, headers := #[], body := "{\"error\":\"insufficient_balance\"}".toUTF8 }
    else
      return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"id\":\"ok_after_402\"}".toUTF8 })
  if out402Ok.status != 200 || out402Ok.selectedAccount != "claude-2" || out402Ok.attemptsUsed != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: HTTP 402 pre-header failover failed: status={out402Ok.status} acct={out402Ok.selectedAccount}"
    return 1
  let chain402Only : RoutingChain := {
    id := "c-402-only", name := "particle-only",
    targets := #[
      { accountId := "particle-1", provider := "particle", baseUrl := "https://api.particle.ai", apiKey := "pk", modelId := "particle-ai/particle-1" }
    ]
  }
  let out402Exhaust ← forwardProxyChain chain402Only "POST" "/v1/chat/completions" #[] "{}".toUTF8 (some fun _ => do
    return .ok { status := 402, headers := #[], body := "{\"error\":\"out_of_credit\"}".toUTF8 })
  if out402Exhaust.status != 502 ||
     out402Exhaust.exhaustionClass != "out_of_credit" ||
     !out402Exhaust.headers.any (fun (k, v) => k == "X-Orb-Exhaustion-Class" && v == "out_of_credit") then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: all-402 exhaustion class mismatch: status={out402Exhaust.status} class={out402Exhaust.exhaustionClass}"
    return 1

  -- (b) Loopback Hindsight MCP server + `executeMemoryMcpTool` + `/api/mcp/*` routes + managed/bunker denials
  let .ok (memListenFd, memPort) ← tcpListen "127.0.0.1" 0 16
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: loopback Hindsight fixture listen failed"; return 1
  let _ ← IO.asTask (prio := .dedicated) do
    for idx in [0:4] do
      if let .ok cfd ← tcpAcceptPoll memListenFd 5000 then
        let _ ← readHttpRequestFromFd cfd none 2000
        let (ct, body) :=
          if idx == 0 then
            ("text/event-stream", "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"structuredContent\":{\"hits\":[{\"path\":\"projects/orb.md\",\"title\":\"Orb Architecture\"}]}}}\n\n")
          else if idx == 1 then
            ("application/json", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"# Orb Architecture\\nPure Lean 4.\"}]}}")
          else if idx == 2 then
            ("application/json", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"structuredContent\":{\"entries\":[\"projects/orb.md\"]}}}")
          else
            ("application/json", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"structuredContent\":{\"memories\":[\"Thomas prefers Lean 4 over Rust\"]}}}")
        let wire := s!"HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
        discard <| writeAll cfd wire false
        discard <| closeFd cfd
    discard <| closeFd memListenFd

  let memBaseUrl := s!"http://127.0.0.1:{memPort}/mcp"
  let memCache ← newMemoryTokenCache
  let coordCtx : MemoryCallerContext := { callerRole := 1 }
  let .ok searchVal ← executeMemoryMcpTool memCache coordCtx "memory_search_knowledge"
      (OrbBin.Json.JVal.obj #[("query", .str "Orb"), ("bank", .str "thomas"), ("limit", .nat 5)])
      nowSec (some memBaseUrl) (some "hindsight-test-tok")
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: memory_search_knowledge SSE call failed"; return 1
  let .ok pageVal ← executeMemoryMcpTool memCache coordCtx "memory_get_knowledge_page"
      (OrbBin.Json.JVal.obj #[("path", .str "projects/orb.md"), ("bank", .str "thomas")])
      nowSec (some memBaseUrl) (some "hindsight-test-tok")
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: memory_get_knowledge_page call failed"; return 1
  let .ok treeVal ← executeMemoryMcpTool memCache coordCtx "memory_get_knowledge_tree"
      (OrbBin.Json.JVal.obj #[("bank", .str "ppl")])
      nowSec (some memBaseUrl) (some "hindsight-test-tok")
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: memory_get_knowledge_tree call failed"; return 1
  let .ok recallVal ← executeMemoryMcpTool memCache coordCtx "memory_recall"
      (OrbBin.Json.JVal.obj #[("query", .str "Lean 4"), ("max_tokens", .nat 1024)])
      nowSec (some memBaseUrl) (some "hindsight-test-tok")
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: memory_recall call failed"; return 1
  if (OrbBin.Json.renderCompact searchVal |>.splitOn "projects/orb.md").length != 2 ||
     (OrbBin.Json.renderCompact pageVal |>.splitOn "Pure Lean 4.").length != 2 ||
     (OrbBin.Json.renderCompact treeVal |>.splitOn "\"bank\":\"ppl\"").length != 2 ||
     (OrbBin.Json.renderCompact recallVal |>.splitOn "Thomas prefers Lean 4").length != 2 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: Hindsight memory_* unwrapped payload mismatch"
    return 1

  let managedRes ← executeMemoryMcpTool memCache { callerRole := 2, onManagedNode := true } "memory_search_knowledge"
      (OrbBin.Json.JVal.obj #[("query", .str "Orb")]) nowSec (some memBaseUrl) (some "tok")
  let bunkerExtRes ← executeMemoryMcpTool memCache { callerRole := 2, isExternalSession := true, bunkerState := 1 } "memory_search_knowledge"
      (OrbBin.Json.JVal.obj #[("query", .str "Orb")]) nowSec (some memBaseUrl) (some "tok")
  if managedRes.isOk || bunkerExtRes.isOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: memoryToolGate failed to deny managed VM or quarantined external session"
    return 1

  let mcpSessBody := "{\"mission_id\":\"m-alpha\",\"role\":\"coordinator\",\"project\":\"orb\"}"
  let mcpSessRaw := s!"POST /api/mcp/session HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {mcpSessBody.utf8ByteSize}\r\n\r\n{mcpSessBody}".toUTF8
  let .ok mcpSessReq := parseRequest mcpSessRaw none | do closeCoreStore store; return 1
  let .ok mcpSessResp ← dispatchCoreRequest appSt mcpSessReq nowSec | do closeCoreStore store; return 1
  let .ok mcpSessJson := OrbBin.Json.parseBytes mcpSessResp.body | do closeCoreStore store; return 1
  let scopedMcpTok := (mcpSessJson.fieldStr? "token").getD ""
  if mcpSessResp.status != 200 || !scopedMcpTok.startsWith "mcp1." then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /api/mcp/session failed: status={mcpSessResp.status}"
    return 1
  let mcpCapsRaw := s!"GET /api/mcp/capabilities HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {scopedMcpTok}\r\n\r\n".toUTF8
  let .ok mcpCapsReq := parseRequest mcpCapsRaw none | do closeCoreStore store; return 1
  let .ok mcpCapsResp ← dispatchCoreRequest appSt mcpCapsReq nowSec | do closeCoreStore store; return 1
  let mcpCapsStr := String.fromUTF8! mcpCapsResp.body
  if mcpCapsResp.status != 200 ||
     (mcpCapsStr.splitOn "\"memory_search_knowledge\"").length != 2 ||
     (mcpCapsStr.splitOn "\"memory_recall\"").length != 2 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: /api/mcp/capabilities missing memory_* tools"
    return 1

  -- External MCP sessions (`/api/mcp/external-sessions` mint, idle renew, list, revoke)
  let extOpBody := "{\"role\":\"operator\",\"ttl_days\":7}"
  let extOpRaw := s!"POST /api/mcp/external-sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {extOpBody.utf8ByteSize}\r\n\r\n{extOpBody}".toUTF8
  let .ok extOpReq := parseRequest extOpRaw none | do closeCoreStore store; return 1
  let .ok extOpResp ← dispatchCoreRequest appSt extOpReq nowSec | do closeCoreStore store; return 1
  let extCoordBody := "{\"role\":\"coordinator\",\"client_kind\":\"local_mcp\",\"client_label\":\"Local Harnesses\",\"ttl_days\":30}"
  let extCoordRaw := s!"POST /api/mcp/external-sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {extCoordBody.utf8ByteSize}\r\n\r\n{extCoordBody}".toUTF8
  let .ok extCoordReq := parseRequest extCoordRaw none | do closeCoreStore store; return 1
  let .ok extCoordResp ← dispatchCoreRequest appSt extCoordReq nowSec | do closeCoreStore store; return 1
  let .ok extCoordJson := OrbBin.Json.parseBytes extCoordResp.body | do closeCoreStore store; return 1
  let extTok := (extCoordJson.fieldStr? "token").getD ""
  let extSid := (extCoordJson.fieldStr? "session_id").getD ""
  let extListRaw := s!"GET /api/mcp/external-sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok extListReq := parseRequest extListRaw none | do closeCoreStore store; return 1
  let .ok extListResp ← dispatchCoreRequest appSt extListReq nowSec | do closeCoreStore store; return 1
  let extIdleRenewRaw := s!"POST /api/mcp/renew HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {extTok}\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok extIdleRenewReq := parseRequest extIdleRenewRaw none | do closeCoreStore store; return 1
  let .ok extIdleRenewResp ← dispatchCoreRequest appSt extIdleRenewReq (nowSec + 7200) | do closeCoreStore store; return 1
  let extDelRaw := s!"DELETE /api/mcp/external-sessions/{extSid} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok extDelReq := parseRequest extDelRaw none | do closeCoreStore store; return 1
  let .ok extDelResp ← dispatchCoreRequest appSt extDelReq (nowSec + 1800) | do closeCoreStore store; return 1
  let .ok extRevokedRenewResp ← dispatchCoreRequest appSt extIdleRenewReq (nowSec + 7201) | do closeCoreStore store; return 1
  if extOpResp.status != 403 || extCoordResp.status != 200 || !extTok.startsWith "mcp1." ||
     extListResp.status != 200 || extIdleRenewResp.status != 200 ||
     extDelResp.status != 200 || extRevokedRenewResp.status != 401 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /api/mcp/external-sessions lifecycle failed: op={extOpResp.status} coord={extCoordResp.status} renew={extIdleRenewResp.status} del={extDelResp.status} afterDel={extRevokedRenewResp.status}"
    return 1
  -- SM-02: POST /api/control/missions with client placement persists placement_kind='client',
  -- and POST /api/mcp/call classifies onManagedNode strictly from typed placement_kind (ignoring legacy tags).
  let clientCreateBody := "{\"id\":\"m-sm02-client\",\"title\":\"Client Placed\",\"placement\":\"client\",\"project\":\"orb\"}"
  let clientCreateRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {clientCreateBody.utf8ByteSize}\r\n\r\n{clientCreateBody}".toUTF8
  let .ok clientCreateReq := parseRequest clientCreateRaw none | do closeCoreStore store; return 1
  let .ok clientCreateResp ← dispatchCoreRequest appSt clientCreateReq nowSec | do closeCoreStore store; return 1
  let clientCreateStr := String.fromUTF8! clientCreateResp.body
  if clientCreateResp.status != 201 || (clientCreateStr.splitOn "\"placement_kind\":\"client\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 client mission create expected placement_kind=client: {clientCreateResp.status} {clientCreateStr}"
    return 1
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET tags='[\"managed-fake\",\"placement:managed_vm\",\"remote-node:auto-managed\"]' WHERE id='m-sm02-client';" #[]
  let clientSessBody := "{\"mission_id\":\"m-sm02-client\",\"role\":\"worker\",\"project\":\"orb\"}"
  let clientSessRaw := s!"POST /api/mcp/session HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {clientSessBody.utf8ByteSize}\r\n\r\n{clientSessBody}".toUTF8
  let .ok clientSessReq := parseRequest clientSessRaw none | do closeCoreStore store; return 1
  let .ok clientSessResp ← dispatchCoreRequest appSt clientSessReq nowSec | do closeCoreStore store; return 1
  let .ok clientSessJson := OrbBin.Json.parseBytes clientSessResp.body | do closeCoreStore store; return 1
  let clientMcpTok := (clientSessJson.fieldStr? "token").getD ""
  let badLimitCallBody := "{\"name\":\"memory_search_knowledge\",\"arguments\":{\"query\":\"Orb\",\"limit\":0}}"
  let clientCallRaw := s!"POST /api/mcp/call HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {clientMcpTok}\r\nContent-Length: {badLimitCallBody.utf8ByteSize}\r\n\r\n{badLimitCallBody}".toUTF8
  let .ok clientCallReq := parseRequest clientCallRaw none | do closeCoreStore store; return 1
  let .ok clientCallResp ← dispatchCoreRequest appSt clientCallReq nowSec | do closeCoreStore store; return 1
  let clientCallStr := String.fromUTF8! clientCallResp.body
  if clientCallResp.status != 200 || (clientCallStr.splitOn "untrusted managed compute nodes").length != 1 || (clientCallStr.splitOn "`limit` must be between").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 /api/mcp/call should ignore managed-* tags when placement_kind=client: {clientCallStr}"
    return 1
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET placement_kind='managed_vm', tags='[]' WHERE id='m-sm02-client';" #[]
  let .ok mgdCallReq := parseRequest clientCallRaw none | do closeCoreStore store; return 1
  let .ok mgdCallResp ← dispatchCoreRequest appSt mgdCallReq nowSec | do closeCoreStore store; return 1
  let mgdCallStr := String.fromUTF8! mgdCallResp.body
  if mgdCallResp.status != 200 || (mgdCallStr.splitOn "untrusted managed compute nodes").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 /api/mcp/call should deny typed placement_kind=managed_vm: {mgdCallStr}"
    return 1
  let vmCreateBody := "{\"id\":\"m-sm02-vm\",\"title\":\"Managed VM\",\"project\":\"orb\",\"remote_node_id\":\"auto-managed:boat:xlarge\"}"
  let vmCreateRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {vmCreateBody.utf8ByteSize}\r\n\r\n{vmCreateBody}".toUTF8
  let .ok vmCreateReq := parseRequest vmCreateRaw none | do closeCoreStore store; return 1
  let .ok vmCreateResp ← dispatchCoreRequest appSt vmCreateReq nowSec | do closeCoreStore store; return 1
  let vmCreateStr := String.fromUTF8! vmCreateResp.body
  if vmCreateResp.status != 201 || (vmCreateStr.splitOn "\"placement_kind\":\"managed_vm\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 auto-managed create expected placement_kind=managed_vm: {vmCreateResp.status} {vmCreateStr}"
    return 1
  let beginVmBody := "{\"run_id\":\"run-sm02-vm\",\"owner_epoch\":1}"
  let beginVmRaw := s!"POST /api/control/missions/m-sm02-vm/runs/begin HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {beginVmBody.utf8ByteSize}\r\n\r\n{beginVmBody}".toUTF8
  let .ok beginVmReq := parseRequest beginVmRaw none | do closeCoreStore store; return 1
  let .ok beginVmResp ← dispatchCoreRequest appSt beginVmReq nowSec | do closeCoreStore store; return 1
  let beginVmStr := String.fromUTF8! beginVmResp.body
  if beginVmResp.status != 201 || (beginVmStr.splitOn "\"placement_kind\":\"managed_vm\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-10 managed_vm beginMissionRun expected 201: {beginVmResp.status} {beginVmStr}"
    return 1
  let vmSessBody := "{\"mission_id\":\"m-sm02-vm\",\"role\":\"worker\",\"project\":\"orb\"}"
  let vmSessRaw := s!"POST /api/mcp/session HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {vmSessBody.utf8ByteSize}\r\n\r\n{vmSessBody}".toUTF8
  let .ok vmSessReq := parseRequest vmSessRaw none | do closeCoreStore store; return 1
  let .ok vmSessResp ← dispatchCoreRequest appSt vmSessReq nowSec | do closeCoreStore store; return 1
  let .ok vmSessJson := OrbBin.Json.parseBytes vmSessResp.body | do closeCoreStore store; return 1
  let vmMcpTok := (vmSessJson.fieldStr? "token").getD ""
  let vmCallBody := "{\"name\":\"memory_search_knowledge\",\"arguments\":{\"query\":\"Orb\"}}"
  let vmCallRaw := s!"POST /api/mcp/call HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {vmMcpTok}\r\nContent-Length: {vmCallBody.utf8ByteSize}\r\n\r\n{vmCallBody}".toUTF8
  let .ok vmCallReq := parseRequest vmCallRaw none | do closeCoreStore store; return 1
  let .ok vmCallResp ← dispatchCoreRequest appSt vmCallReq nowSec | do closeCoreStore store; return 1
  let vmCallStr := String.fromUTF8! vmCallResp.body
  if vmCallResp.status != 200 || (vmCallStr.splitOn "untrusted managed compute nodes").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 auto-managed /api/mcp/call should deny memory_search_knowledge: {vmCallStr}"
    return 1
  let bogusBeginBody := "{\"run_id\":\"run-sm02-bogus\",\"owner_epoch\":1}"
  let _ ← execParamQuery store.missionsDb "UPDATE missions SET placement_kind='' WHERE id='m-sm02-client';" #[]
  let bogusBeginRaw := s!"POST /api/control/missions/m-sm02-client/runs/begin HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {bogusBeginBody.utf8ByteSize}\r\n\r\n{bogusBeginBody}".toUTF8
  let .ok bogusBeginReq := parseRequest bogusBeginRaw none | do closeCoreStore store; return 1
  let .ok bogusBeginResp ← dispatchCoreRequest appSt bogusBeginReq nowSec | do closeCoreStore store; return 1
  let bogusBeginStr := String.fromUTF8! bogusBeginResp.body
  if bogusBeginResp.status != 400 || (bogusBeginStr.splitOn "invalid_placement_kind:").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-10 empty placement_kind expected 400: {bogusBeginResp.status} {bogusBeginStr}"
    return 1
  return 0

private def runCloudHandoffTests
    (tmpRoot : String) (store : CoreStore) (appSt : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  -- (c) Instant Paloma wakeup + SSE delta reducer (monotone cursor dedup across reconnects)
  let wake ← newCloudWorkerWakeup
  let g1 ← notifyCloudWorker wake
  let gObserved ← waitForCloudWake wake 0 1000
  let sseChunk :=
    "id: 1\nevent: text_delta\ndata: {\"delta\":\"Hello \"}\n\n" ++
    "id: 1\nevent: text_delta\ndata: {\"delta\":\"DUPLICATE\"}\n\n" ++
    "id: 2\nevent: text_delta\ndata: {\"delta\":\"world!\"}\n\n" ++
    "id: 3\nevent: completed\ndata: {\"status\":\"completed\"}\n\n"
  let (sseSt, sseEvs) := stepHermesSseChunk {} sseChunk
  if g1 != 1 || gObserved != 1 || sseSt.accumulatedText != "Hello world!" ||
     sseSt.lastCursor != 3 || sseSt.terminalStatus? != some "completed" || sseEvs.size != 3 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: Paloma wakeup or SSE monotone reducer mismatch: text={sseSt.accumulatedText} evs={sseEvs.size}"
    return 1

  -- (d) Cloud-to-workspace handoff & native mission fork (`POST /api/control/missions/:id/fork`)
  let cloudSrc : MissionRecord := {
    id := "m-paloma-1", title := "Quick Paloma Ask", status := "completed",
    backend := "cloud_hermes", modelOverride := "", workingDirectory := tmpRoot,
    updatedAt := "2026-11-07T00:00:00Z"
  }
  let .ok () ← insertNewMission store cloudSrc | do closeCoreStore store; return 1
  let emptyForkBody := "{\"id\":\"m-handoff-empty\",\"backend\":\"codex\"}"
  let emptyForkRaw := s!"POST /api/control/missions/m-paloma-1/fork HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {emptyForkBody.utf8ByteSize}\r\n\r\n{emptyForkBody}".toUTF8
  let .ok emptyForkReq := parseRequest emptyForkRaw none | do closeCoreStore store; return 1
  let .ok emptyForkResp ← dispatchCoreRequest appSt emptyForkReq nowSec | do closeCoreStore store; return 1
  if emptyForkResp.status != 422 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: empty cloud mission handoff should return 422, got {emptyForkResp.status}"
    return 1
  let _ ← execParamQuery store.missionsDb
    "INSERT INTO cloud_executions(id,mission_id,provider,prompt,response_text,status,created_at,updated_at) VALUES('ce-1','m-paloma-1','hermes','Where is the memory spec?','In docs/specs/fast-memory-and-remote-skill-delivery.md.','completed','1','2');" #[]
  let btwCloudBody := "{\"id\":\"m-handoff-btw\",\"backend\":\"codex\",\"side_question\":true}"
  let btwCloudRaw := s!"POST /api/control/missions/m-paloma-1/fork HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {btwCloudBody.utf8ByteSize}\r\n\r\n{btwCloudBody}".toUTF8
  let .ok btwCloudReq := parseRequest btwCloudRaw none | do closeCoreStore store; return 1
  let .ok btwCloudResp ← dispatchCoreRequest appSt btwCloudReq nowSec | do closeCoreStore store; return 1
  if btwCloudResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cloud /btw side_question should return 400, got {btwCloudResp.status}"
    return 1
  let validHandoffBody := "{\"id\":\"m-handoff-ok\",\"backend\":\"codex\",\"remote_node_id\":\"babylon\",\"working_directory\":\"/var/lib/sandboxed-node/work/orb\"}"
  let validHandoffRaw := s!"POST /api/control/missions/m-paloma-1/fork HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {validHandoffBody.utf8ByteSize}\r\n\r\n{validHandoffBody}".toUTF8
  let .ok validHandoffReq := parseRequest validHandoffRaw none | do closeCoreStore store; return 1
  let .ok validHandoffResp ← dispatchCoreRequest appSt validHandoffReq nowSec | do closeCoreStore store; return 1
  let handoffStr := String.fromUTF8! validHandoffResp.body
  if validHandoffResp.status != 201 ||
     (handoffStr.splitOn "\"turns_copied\":2").length != 2 ||
     (handoffStr.splitOn "\"used_cloud_turns\":true").length != 2 ||
     (handoffStr.splitOn "\"fresh_workspace\":true").length != 2 ||
     (handoffStr.splitOn "\"placement_kind\":\"remote\"").length != 2 ||
     (handoffStr.splitOn "fork-workspace:").length != 1 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cloud-to-workspace handoff response mismatch: status={validHandoffResp.status} body={handoffStr}"
    return 1
  let beginBabBody := "{\"run_id\":\"run-handoff-babylon\",\"owner_epoch\":1}"
  let beginBabRaw := s!"POST /api/control/missions/m-handoff-ok/runs/begin HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {beginBabBody.utf8ByteSize}\r\n\r\n{beginBabBody}".toUTF8
  let .ok beginBabReq := parseRequest beginBabRaw none | do closeCoreStore store; return 1
  let .ok beginBabResp ← dispatchCoreRequest appSt beginBabReq nowSec | do closeCoreStore store; return 1
  let beginBabStr := String.fromUTF8! beginBabResp.body
  if beginBabResp.status != 201 || (beginBabStr.splitOn "\"placement_kind\":\"remote\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-10 fleet fork beginMissionRun expected 201 remote: {beginBabResp.status} {beginBabStr}"
    return 1
  let vmForkBody := "{\"id\":\"m-fork-vm\",\"backend\":\"codex\",\"remote_node_id\":\"auto-managed\",\"working_directory\":\"/var/lib/sandboxed-node/work/orb\"}"
  let vmForkRaw := s!"POST /api/control/missions/m-paloma-1/fork HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {vmForkBody.utf8ByteSize}\r\n\r\n{vmForkBody}".toUTF8
  let .ok vmForkReq := parseRequest vmForkRaw none | do closeCoreStore store; return 1
  let .ok vmForkResp ← dispatchCoreRequest appSt vmForkReq nowSec | do closeCoreStore store; return 1
  let vmForkStr := String.fromUTF8! vmForkResp.body
  if vmForkResp.status != 201 || (vmForkStr.splitOn "\"placement_kind\":\"managed_vm\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: auto-managed fork expected placement_kind=managed_vm: {vmForkResp.status} {vmForkStr}"
    return 1
  let beginForkBody := "{\"run_id\":\"run-fork-vm\",\"owner_epoch\":1}"
  let beginForkRaw := s!"POST /api/control/missions/m-fork-vm/runs/begin HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {beginForkBody.utf8ByteSize}\r\n\r\n{beginForkBody}".toUTF8
  let .ok beginForkReq := parseRequest beginForkRaw none | do closeCoreStore store; return 1
  let .ok beginForkResp ← dispatchCoreRequest appSt beginForkReq nowSec | do closeCoreStore store; return 1
  if beginForkResp.status != 201 || ((String.fromUTF8! beginForkResp.body).splitOn "\"placement_kind\":\"managed_vm\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-10 forked managed_vm beginMissionRun expected 201: {beginForkResp.status}"
    return 1
  let forkSessBody := "{\"mission_id\":\"m-fork-vm\",\"role\":\"worker\",\"project\":\"orb\"}"
  let forkSessRaw := s!"POST /api/mcp/session HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {forkSessBody.utf8ByteSize}\r\n\r\n{forkSessBody}".toUTF8
  let .ok forkSessReq := parseRequest forkSessRaw none | do closeCoreStore store; return 1
  let .ok forkSessResp ← dispatchCoreRequest appSt forkSessReq nowSec | do closeCoreStore store; return 1
  let .ok forkSessJson := OrbBin.Json.parseBytes forkSessResp.body | do closeCoreStore store; return 1
  let forkMcpTok := (forkSessJson.fieldStr? "token").getD ""
  let forkCallBody := "{\"name\":\"memory_search_knowledge\",\"arguments\":{\"query\":\"Orb\"}}"
  let forkCallRaw := s!"POST /api/mcp/call HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {forkMcpTok}\r\nContent-Length: {forkCallBody.utf8ByteSize}\r\n\r\n{forkCallBody}".toUTF8
  let .ok forkCallReq := parseRequest forkCallRaw none | do closeCoreStore store; return 1
  let .ok forkCallResp ← dispatchCoreRequest appSt forkCallReq nowSec | do closeCoreStore store; return 1
  if forkCallResp.status != 200 || ((String.fromUTF8! forkCallResp.body).splitOn "untrusted managed compute nodes").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 forked managed_vm /api/mcp/call should deny memory: {String.fromUTF8! forkCallResp.body}"
    return 1
  return 0

private def runCyberAndSkillDeliveryTests
    (tmpRoot : String) (store : CoreStore) (appSt0 : CoreAppState) (validJwt : String) (nowSec : UInt64) : IO UInt32 := do
  let appSt := { appSt0 with cfg := { appSt0.cfg with workingDir := tmpRoot } }
  -- 1. `#1497` Codex Cyber Access + `/goal` fail-closed HTTP gates
  let capsRaw := s!"GET /api/control/cyber-capabilities?model=gpt-6.1-sol&mode=daybreak HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok capsReq := parseRequest capsRaw none | do closeCoreStore store; return 1
  let .ok capsResp ← dispatchCoreRequest appSt capsReq nowSec | do closeCoreStore store; return 1
  let capsStr := String.fromUTF8! capsResp.body
  if capsResp.status != 200 ||
     (capsStr.splitOn "\"version\":2").length != 2 ||
     (capsStr.splitOn "\"route_supported\":true").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /api/control/cyber-capabilities mismatch: {capsStr}"
    return 1

  -- `/goal` + explicit `daybreak` MUST fail closed (400) before creating a mission row
  let badGoalBody := "{\"id\":\"m-cyber-goal-bad\",\"backend\":\"codex\",\"model_override\":\"gpt-6.1-sol\",\"cyber_access\":\"daybreak\",\"prompt\":\"/goal audit kernel\"}"
  let badGoalRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {badGoalBody.utf8ByteSize}\r\n\r\n{badGoalBody}".toUTF8
  let .ok badGoalReq := parseRequest badGoalRaw none | do closeCoreStore store; return 1
  let .ok badGoalResp ← dispatchCoreRequest appSt badGoalReq nowSec | do closeCoreStore store; return 1
  if badGoalResp.status != 400 || (← getMission? store "m-cyber-goal-bad").isSome then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /goal with explicit cyber should fail closed without persisting mission, got {badGoalResp.status}"
    return 1

  -- Retired Daybreak alias MUST fail closed (400)
  let retiredBody := "{\"id\":\"m-cyber-retired\",\"backend\":\"codex\",\"model_override\":\"gpt-daybreak-blue-latest\",\"prompt\":\"hello\"}"
  let retiredRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {retiredBody.utf8ByteSize}\r\n\r\n{retiredBody}".toUTF8
  let .ok retiredReq := parseRequest retiredRaw none | do closeCoreStore store; return 1
  let .ok retiredResp ← dispatchCoreRequest appSt retiredReq nowSec | do closeCoreStore store; return 1
  if retiredResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: retired Daybreak alias should return 400, got {retiredResp.status}"
    return 1

  -- Path traversal mission id MUST fail closed (400) before creating a mission row or sidecar
  let badMidBody := "{\"id\":\"../escape\",\"backend\":\"codex\",\"model_override\":\"gpt-6.1-sol\",\"cyber_access\":\"daybreak\",\"prompt\":\"hello\"}"
  let badMidRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {badMidBody.utf8ByteSize}\r\n\r\n{badMidBody}".toUTF8
  let .ok badMidReq := parseRequest badMidRaw none | do closeCoreStore store; return 1
  let .ok badMidResp ← dispatchCoreRequest appSt badMidReq nowSec | do closeCoreStore store; return 1
  if badMidResp.status != 400 || !(isSafeMissionId "m-cyber-ok") || isSafeMissionId "../escape" ||
     (← writePending tmpRoot "../escape" { mode := .daybreak, revision := nilRevision }).isOk then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: unsafe missionId did not fail closed, got {badMidResp.status}"
    return 1

  -- Create Codex mission, PATCH cyber to `daybreak`, verify GET + conflicting `/api/control/message` (409) + `/goal` resume refusal (400)
  let okCodexBody := "{\"id\":\"m-cyber-ok\",\"backend\":\"codex\",\"model_override\":\"gpt-6.1-sol\",\"working_directory\":\"" ++ tmpRoot ++ "\"}"
  let okCodexRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {okCodexBody.utf8ByteSize}\r\n\r\n{okCodexBody}".toUTF8
  let .ok okCodexReq := parseRequest okCodexRaw none | do closeCoreStore store; return 1
  let .ok okCodexResp ← dispatchCoreRequest appSt okCodexReq nowSec | do closeCoreStore store; return 1
  if okCodexResp.status != 201 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: codex mission create failed: {okCodexResp.status}"
    return 1

  let patchCyberBody := "{\"mode\":\"daybreak\"}"
  let patchCyberRaw := s!"PATCH /api/control/missions/m-cyber-ok/cyber HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {patchCyberBody.utf8ByteSize}\r\n\r\n{patchCyberBody}".toUTF8
  let .ok patchCyberReq := parseRequest patchCyberRaw none | do closeCoreStore store; return 1
  let .ok patchCyberResp ← dispatchCoreRequest appSt patchCyberReq nowSec | do closeCoreStore store; return 1
  let getCyberRaw := s!"GET /api/control/missions/m-cyber-ok/cyber HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok getCyberReq := parseRequest getCyberRaw none | do closeCoreStore store; return 1
  let .ok getCyberResp ← dispatchCoreRequest appSt getCyberReq nowSec | do closeCoreStore store; return 1
  let getCyberStr := String.fromUTF8! getCyberResp.body
  let cyberRev := ((OrbBin.Json.parse getCyberStr).toOption.bind (·.fieldStr? "revision")).getD ""
  if patchCyberResp.status != 200 || getCyberResp.status != 200 || cyberRev.isEmpty ||
     (getCyberStr.splitOn "\"mode\":\"daybreak\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: PATCH/GET /cyber mismatch: patch={patchCyberResp.status} get={getCyberStr}"
    return 1

  -- Idle Codex follow-up omitting `cyber_access`/`cyber_revision` when explicit Daybreak is saved MUST return 409; stale `PATCH /cyber` `expected_revision` MUST return 409
  let omitCyberMsgBody := "{\"mission_id\":\"m-cyber-ok\",\"content\":\"ping\"}"
  let omitCyberMsgRaw := s!"POST /api/control/message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {omitCyberMsgBody.utf8ByteSize}\r\n\r\n{omitCyberMsgBody}".toUTF8
  let .ok omitCyberMsgReq := parseRequest omitCyberMsgRaw none | do closeCoreStore store; return 1
  let .ok omitCyberMsgResp ← dispatchCoreRequest appSt omitCyberMsgReq nowSec | do closeCoreStore store; return 1
  let stalePatchBody := "{\"mode\":\"standard\",\"expected_revision\":\"00000000-0000-0000-0000-000000000001\"}"
  let stalePatchRaw := s!"PATCH /api/control/missions/m-cyber-ok/cyber HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {stalePatchBody.utf8ByteSize}\r\n\r\n{stalePatchBody}".toUTF8
  let .ok stalePatchReq := parseRequest stalePatchRaw none | do closeCoreStore store; return 1
  let .ok stalePatchResp ← dispatchCoreRequest appSt stalePatchReq nowSec | do closeCoreStore store; return 1
  if omitCyberMsgResp.status != 409 || stalePatchResp.status != 409 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cyber omission/stale-patch CAS mismatch: omit={omitCyberMsgResp.status} stalePatch={stalePatchResp.status}"
    return 1

  let conflictMsgBody := "{\"mission_id\":\"m-cyber-ok\",\"content\":\"ping\",\"cyber_access\":\"standard\"}"
  let conflictMsgRaw := s!"POST /api/control/message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {conflictMsgBody.utf8ByteSize}\r\n\r\n{conflictMsgBody}".toUTF8
  let .ok conflictMsgReq := parseRequest conflictMsgRaw none | do closeCoreStore store; return 1
  let .ok conflictMsgResp ← dispatchCoreRequest appSt conflictMsgReq nowSec | do closeCoreStore store; return 1
  let resumeGoalBody := "{\"goal_mode\":true}"
  let resumeGoalRaw := s!"POST /api/control/missions/m-cyber-ok/resume HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {resumeGoalBody.utf8ByteSize}\r\n\r\n{resumeGoalBody}".toUTF8
  let .ok resumeGoalReq := parseRequest resumeGoalRaw none | do closeCoreStore store; return 1
  let .ok resumeGoalResp ← dispatchCoreRequest appSt resumeGoalReq nowSec | do closeCoreStore store; return 1
  if conflictMsgResp.status != 409 || resumeGoalResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cyber follow-up conflict/goal-resume mismatch: msg={conflictMsgResp.status} resume={resumeGoalResp.status}"
    return 1

  -- 2. `#1553` `/api/library/skill-delivery` + `/skill:<name>` validation
  let globalSkillDir := System.FilePath.mk tmpRoot / "library" / "skills" / "lean-audit"
  let ctxSkillDir := System.FilePath.mk tmpRoot / "project-files" / "orb" / "skills" / "orb-release"
  IO.FS.createDirAll globalSkillDir
  IO.FS.createDirAll ctxSkillDir
  IO.FS.writeFile (globalSkillDir / "SKILL.md") "---\ndescription: \"Audit formal Lean specs\"\n---\nCheck specs.\n"
  IO.FS.writeFile (ctxSkillDir / "SKILL.md") "Context-scoped release checklist.\n"

  let delivRaw := s!"GET /api/library/skill-delivery?project=orb HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok delivReq := parseRequest delivRaw none | do closeCoreStore store; return 1
  let .ok delivResp ← dispatchCoreRequest appSt delivReq nowSec | do closeCoreStore store; return 1
  let delivStr := String.fromUTF8! delivResp.body
  if delivResp.status != 200 ||
     (delivStr.splitOn "\"lean-audit\"").length != 2 ||
     (delivStr.splitOn "\"orb-release\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /api/library/skill-delivery mismatch: {delivStr}"
    return 1

  -- Path traversal project slug rejected with 400
  let badProjRaw := s!"GET /api/library/skill-delivery?project=../etc HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\n\r\n".toUTF8
  let .ok badProjReq := parseRequest badProjRaw none | do closeCoreStore store; return 1
  let .ok badProjResp ← dispatchCoreRequest appSt badProjReq nowSec | do closeCoreStore store; return 1
  -- Undelivered skill rejected with 400; delivered skill accepted with 200
  let undelivMsgBody := s!"\{\"mission_id\":\"m-cyber-ok\",\"content\":\"run /skill:not-installed now\",\"cyber_access\":\"daybreak\",\"cyber_revision\":\"{cyberRev}\"}"
  let undelivMsgRaw := s!"POST /api/control/message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {undelivMsgBody.utf8ByteSize}\r\n\r\n{undelivMsgBody}".toUTF8
  let .ok undelivMsgReq := parseRequest undelivMsgRaw none | do closeCoreStore store; return 1
  let .ok undelivMsgResp ← dispatchCoreRequest appSt undelivMsgReq nowSec | do closeCoreStore store; return 1
  let delivMsgBody := s!"\{\"mission_id\":\"m-cyber-ok\",\"content\":\"run /skill:lean-audit now\",\"cyber_access\":\"daybreak\",\"cyber_revision\":\"{cyberRev}\"}"
  let delivMsgRaw := s!"POST /api/control/message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {delivMsgBody.utf8ByteSize}\r\n\r\n{delivMsgBody}".toUTF8
  let .ok delivMsgReq := parseRequest delivMsgRaw none | do closeCoreStore store; return 1
  let .ok delivMsgResp ← dispatchCoreRequest appSt delivMsgReq nowSec | do closeCoreStore store; return 1
  let delivMsgStr := String.fromUTF8! delivMsgResp.body
  if badProjResp.status != 400 || undelivMsgResp.status != 400 || delivMsgResp.status != 200 ||
     (delivMsgStr.splitOn "Selected skills (load before performing the current request):").length != 2 ||
     (delivMsgStr.splitOn ".agents/skills/lean-audit/SKILL.md").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: skill-delivery gate/directive mismatch: badProj={badProjResp.status} undeliv={undelivMsgResp.status} deliv={delivMsgResp.status} body={delivMsgStr}"
    return 1

  -- Idle follow-up MUST have promoted `.next.json` to `{mid}.json` and written execution binding (`remote-launch:m-cyber-ok`)
  let .ok committedSel ← readCommittedSelection tmpRoot "m-cyber-ok" | do closeCoreStore store; return 1
  let boundKey? ← readBinding? tmpRoot "m-cyber-ok"
  if committedSel.mode != .daybreak || boundKey?.map (·.key) != some "remote-launch:m-cyber-ok" then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cyber pending selection was not promoted/bound on idle launch"
    return 1

  -- Active mission MUST reject `PATCH /api/control/missions/:id/cyber` with 409
  discard <| execParamQuery store.missionsDb "UPDATE missions SET status='active' WHERE id='m-cyber-ok';" #[]
  let patchActiveBody := "{\"mode\":\"standard\"}"
  let patchActiveRaw := s!"PATCH /api/control/missions/m-cyber-ok/cyber HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {patchActiveBody.utf8ByteSize}\r\n\r\n{patchActiveBody}".toUTF8
  let .ok patchActiveReq := parseRequest patchActiveRaw none | do closeCoreStore store; return 1
  let .ok patchActiveResp ← dispatchCoreRequest appSt patchActiveReq nowSec | do closeCoreStore store; return 1
  if patchActiveResp.status != 409 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: active mission PATCH /cyber should return 409, got {patchActiveResp.status}"
    return 1

  -- `/v1/responses` proxy enforcement: non-existent mission key -> 403; unsupported intermediary target -> 400
  let proxyTok := if appSt.cfg.proxySecret.isEmpty then validJwt else appSt.cfg.proxySecret
  let ghostProxyBody := "{\"model\":\"gpt-6.1-sol\",\"input\":\"hi\"}"
  let ghostProxyRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {proxyTok}\r\nX-Sandboxed-Execution-Key: remote-launch:m-ghost-nonexistent\r\nContent-Length: {ghostProxyBody.utf8ByteSize}\r\n\r\n{ghostProxyBody}".toUTF8
  let .ok ghostProxyReq := parseRequest ghostProxyRaw none | do closeCoreStore store; return 1
  let .ok ghostProxyResp ← dispatchCoreRequest appSt ghostProxyReq nowSec | do closeCoreStore store; return 1
  let prevChains ← appSt.chainsRef.get
  appSt.chainsRef.set #[{
    id := "codex-bad-intermediary", name := "Bad Intermediary",
    targets := #[{
      accountId := "intermediary-1", provider := "openai",
      baseUrl := "https://proxy.example.invalid/v1", apiKey := "sk-test", modelId := "gpt-6.1-sol"
    }]
  }]
  let boundProxyRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {proxyTok}\r\nX-Sandboxed-Execution-Key: remote-launch:m-cyber-ok\r\nContent-Length: {ghostProxyBody.utf8ByteSize}\r\n\r\n{ghostProxyBody}".toUTF8
  let .ok boundProxyReq := parseRequest boundProxyRaw none | do closeCoreStore store; return 1
  let .ok boundProxyResp ← dispatchCoreRequest appSt boundProxyReq nowSec | do closeCoreStore store; return 1
  appSt.chainsRef.set prevChains
  if ghostProxyResp.status != 403 || boundProxyResp.status != 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: proxy execution-key / intermediary cyber gating mismatch: ghost={ghostProxyResp.status} intermediary={boundProxyResp.status}"
    return 1
  return 0

private def runR5bManagedStoreTests (prodValid : CoreConfig) : IO UInt32 := do
  let r5Ts ← IO.monoNanosNow
  let r5Root := s!"/tmp/orb-core-r5b-{r5Ts}"
  IO.FS.createDirAll r5Root
  let memRej ← openManagedComputeStore ":memory:"
  if memRej.isOk then
    IO.eprintln "[orb-core-test] FAIL: openManagedComputeStore accepted :memory:"
    return 1
  let .ok mst ← openManagedComputeStore s!"{r5Root}/managed_compute.db"
    | do IO.eprintln "[orb-core-test] FAIL: openManagedComputeStore failed"; return 1
  let .ok () ← sealProviderSecret r5Root "boat" "boat-secret-token-r5b"
    | do closeManagedComputeStore mst; IO.eprintln "[orb-core-test] FAIL: sealProviderSecret failed"; return 1
  let secStat ← OrbBin.PosixExt.statPath (managedSecretPath r5Root "boat").toString
  let keyStat ← OrbBin.PosixExt.statPath (managedMasterKeyPath r5Root).toString
  let dirStat ← OrbBin.PosixExt.statPath (managedSecretDir r5Root).toString
  let rawCipher ← IO.FS.readBinFile (managedSecretPath r5Root "boat")
  let rawMasterKey ← IO.FS.readBinFile (managedMasterKeyPath r5Root)
  let managedSecretRej ← openProviderSecret r5Root "boat" true true
  let missionSecretRej ← openProviderSecret r5Root "boat" false false
  let .ok openedSecret ← openProviderSecret r5Root "boat" false true
    | do closeManagedComputeStore mst; IO.eprintln "[orb-core-test] FAIL: openProviderSecret failed"; return 1
  if managedSecretRej.isOk || missionSecretRej.isOk || openedSecret != "boat-secret-token-r5b" ||
     (secStat.mode &&& 0o777) != 0o600 || (keyStat.mode &&& 0o777) != 0o600 ||
     (dirStat.mode &&& 0o777) != 0o700 || rawMasterKey.size != 32 ||
     rawCipher.extract 0 32 == rawMasterKey ||
     (((String.fromUTF8? rawCipher).getD "").splitOn "boat-secret-token-r5b").length > 1 ||
     admitCoreReservedSecret true true != 512 || admitCoreReservedSecret false false != 512 ||
     admitCoreReservedSecret false true != 257 then
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: CoreReserved secret gate, 0600 mode, or AEAD round-trip failed"
    return 1
  let adapterOk :=
    match observeProviderPayload "boat" "m1" 200 (.obj #[("state", .str "running"), ("spent_cents", .nat 12)]),
          observeProviderPayload "leanci" "m2" 200 (.obj #[("status", .str "halted")]),
          observeProviderPayload "leanci" "m2b" 200 (.obj #[("status", .str "reaped")]),
          observeProviderPayload "hetzner" "m3" 200 (.obj #[("status", .str "off")]),
          observeProviderPayload "vastai" "m4" 200 (.obj #[("state", .str "exited")]),
          observeProviderPayload "scaleway" "m5" 200 (.obj #[("state", .str "stopped_in_place")]),
          observeProviderPayload "colab" "m6" 404 (.obj #[]) with
    | .ok o1, .ok o2, .ok o2b, .ok o3, .ok o4, .ok o5, .ok o6 =>
      o1.observedStatus == "ready" && !o1.orphaned && o1.spentCents == 12 &&
      o2.provider == "leanci" && o2.observedStatus == "stopped" &&
      o2b.provider == "leanci" && o2b.observedStatus == "destroyed" && o2b.orphaned &&
      o3.observedStatus == "stopped" &&
      o4.observedStatus == "stopped" && o5.observedStatus == "stopped" &&
      o6.orphaned && (observeProviderPayload "aws" "m7" 200 (.obj #[])).isOk == false &&
      -- The former provider name is not an alias: only the one-time migration knows it.
      (observeProviderPayload "boost" "m8" 200 (.obj #[])).isOk == false &&
      canonicalizeProvider "boost" == "boost" && !isKnownProvider "boost" && canonicalizeProvider "lean.ci" == "leanci"
    | _, _, _, _, _, _, _ => false
  if !adapterOk then
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: pure ProviderObservation adapter check failed"
    return 1
  let fleet0 : ManagedFleetState := { enabled := true, boatEnabled := true }
  let vm0 : ManagedMachine := {
    id := "mm-r5b-1", sandboxName := "orb-managed-mm-r5b-1", provider := "boat",
    size := "small", spentCents := 25, nodeBootEpoch := 1, deletableAtSec := 100
  }
  let .ok reservedVm ← provisionManagedMachine mst fleet0 vm0 50
    | do closeManagedComputeStore mst; IO.eprintln "[orb-core-test] FAIL: provisionManagedMachine failed"; return 1
  if reservedVm.status != "provisioning" || reservedVm.lastPollSec != 0 ||
      reservedVm.createdAtSec != 50 || reservedVm.expiresAtSec != 3650 then
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: a reservation must not manufacture readiness"
    return 1
  let .ok () ← bindManagedProviderId mst vm0.id "boat-boot-1" 1
    | do closeManagedComputeStore mst; return 1
  let some (boundVm, _) ← getManagedMachine? mst vm0.id
    | do closeManagedComputeStore mst; return 1
  if boundVm.id != vm0.id || boundVm.providerId != "boat-boot-1" || boundVm.status != "provisioning" then
    closeManagedComputeStore mst
    return 1
  let .ok () ← putEnrollmentToken mst "mm-r5b-1" "enroll-boot-1"
    | do closeManagedComputeStore mst; return 1
  let .ok r5Store ← openCoreStore s!"{r5Root}/core"
    | do closeManagedComputeStore mst; return 1
  let r5ManagedRef ← IO.mkRef fleet0
  let r5ChainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let r5CooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let r5SeqRef ← IO.mkRef (1 : UInt64)
  let r5App : CoreAppState := {
    cfg := prodValid, store := r5Store, searchIdx? := none,
    managedRef := r5ManagedRef, chainsRef := r5ChainsRef,
    proxyCooldownsRef := r5CooldownsRef, seqRef := r5SeqRef,
    managedStore? := some mst
  }
  let .ok badPollReq := parseRequest "GET /api/managed-machines/relay/poll HTTP/1.1\r\nHost: 127.0.0.1\r\nx-orb-machine-id: mm-r5b-1\r\n\r\n".toUTF8 none
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok badPollResp ← dispatchCoreRequest r5App badPollReq 64
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if badPollResp.status != 401 then
    closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let enrollBody := "{\"machine_id\":\"mm-r5b-1\",\"enroll_token\":\"enroll-boot-1\"}"
  let enrollRaw := s!"POST /api/managed-machines/enroll HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {enrollBody.utf8ByteSize}\r\n\r\n{enrollBody}".toUTF8
  let .ok enrollReq := parseRequest enrollRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok enrollResp ← dispatchCoreRequest r5App enrollReq 65 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok enrollJson := OrbBin.Json.parseBytes enrollResp.body | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let nodeTok1 := (enrollJson.fieldStr? "node_token").getD ""
  let replayEnroll ← enrollManagedNode mst "mm-r5b-1" "enroll-boot-1" (some 1)
  if enrollResp.status != 200 || nodeTok1.isEmpty || replayEnroll.isOk then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: HTTP enroll or replay rejection failed"
    return 1
  let some (enrolledVm, _) ← getManagedMachine? mst vm0.id
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if enrolledVm.status != "provisioning" || enrolledVm.lastPollSec != 0 then
    closeCoreStore r5Store; closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: enrollment alone must not mark ready"
    return 1
  let readyPollRaw := s!"GET /api/managed-machines/relay/poll HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {nodeTok1}\r\nx-orb-machine-id: mm-r5b-1\r\nx-orb-boot-epoch: 1\r\n\r\n".toUTF8
  let .ok readyPollReq := parseRequest readyPollRaw none
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok readyPollResp ← dispatchCoreRequest r5App readyPollReq 66
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let some (polledVm, polledSlice) ← getManagedMachine? mst vm0.id
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if readyPollResp.status != 200 || polledVm.status != "ready" || polledVm.lastPollSec != 66 ||
      polledSlice.activeComputeEligible != 1 || polledVm.providerId != "boat-boot-1" then
    closeCoreStore r5Store; closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: authenticated poll must commit readiness and provider identity"
    return 1
  let .ok claim1 ← applyVmClaim mst "mm-r5b-1" "m-owner-1" {
    opCode := Orb.ManagedNode.ClaimOp.encode .claim, ownerInLineage := 1, ownerSuperseded := 0,
    vmLive := 1, activeComputeEligible := 1, presentedReservation := 10, presentedBootEpoch := 1
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let dupClaim ← applyVmClaim mst "mm-r5b-1" "m-owner-1" {
    opCode := Orb.ManagedNode.ClaimOp.encode .claim, ownerInLineage := 1, ownerSuperseded := 0,
    vmLive := 1, activeComputeEligible := 1, presentedReservation := 10, presentedBootEpoch := 1
  }
  if dupClaim.isOk || claim1.reservationId != 10 then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: duplicate claim was not rejected"
    return 1
  let earlyDestroy ← applyVmLifecycle mst "mm-r5b-1" {
    opCode := Orb.ManagedNode.VmOp.encode .destroy, ownerLive := 0, idleElapsed := 1,
    presentedBootEpoch := 1, nowEpoch := 60
  }
  if earlyDestroy.isOk then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: destroy inside deletable_at lease was accepted"
    return 1
  let .ok () ← enqueueRelayCommand mst "mm-r5b-1" "cmd-http" "{\"op\":\"echo\"}"
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let pollRaw := s!"GET /api/managed-machines/relay/poll HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {nodeTok1}\r\nx-orb-machine-id: mm-r5b-1\r\n\r\n".toUTF8
  let .ok pollReq := parseRequest pollRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok pollResp ← dispatchCoreRequest r5App pollReq 68 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let staleLeaseBody := "{\"id\":\"cmd-http\",\"lease_id\":999}"
  let staleLeaseRaw := s!"POST /api/managed-machines/relay/respond HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {nodeTok1}\r\nx-orb-machine-id: mm-r5b-1\r\nContent-Length: {staleLeaseBody.utf8ByteSize}\r\n\r\n{staleLeaseBody}".toUTF8
  let .ok staleLeaseReq := parseRequest staleLeaseRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok staleLeaseResp ← dispatchCoreRequest r5App staleLeaseReq 69 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let ackBody := "{\"id\":\"cmd-http\",\"lease_id\":1}"
  let ackRaw := s!"POST /api/managed-machines/relay/respond HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {nodeTok1}\r\nx-orb-machine-id: mm-r5b-1\r\nx-orb-boot-epoch: 1\r\nContent-Length: {ackBody.utf8ByteSize}\r\n\r\n{ackBody}".toUTF8
  let .ok ackReq := parseRequest ackRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok ackResp ← dispatchCoreRequest r5App ackReq 69 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let opJwt := mintSessionToken prodValid.jwtSecret 3660
  let .ok () ← upsertMission r5Store {
    id := "m-owner-1", title := "Managed VM Owner", status := "active",
    backend := "codex", modelOverride := "", workingDirectory := r5Root,
    project := "orb", placementKind := "managed", updatedAt := "70"
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let ownerSessBody := "{\"mission_id\":\"m-owner-1\",\"role\":\"worker\",\"project\":\"orb\"}"
  let ownerSessRaw := s!"POST /api/mcp/session HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {opJwt}\r\nContent-Length: {ownerSessBody.utf8ByteSize}\r\n\r\n{ownerSessBody}".toUTF8
  let .ok ownerSessReq := parseRequest ownerSessRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok ownerSessResp ← dispatchCoreRequest r5App ownerSessReq 70 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok ownerSessJson := OrbBin.Json.parseBytes ownerSessResp.body | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let ownerMcpTok := (ownerSessJson.fieldStr? "token").getD ""
  let ownerMemBody := "{\"name\":\"memory_search_knowledge\",\"arguments\":{\"query\":\"Orb\"}}"
  let ownerMemRaw := s!"POST /api/mcp/call HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {ownerMcpTok}\r\nContent-Length: {ownerMemBody.utf8ByteSize}\r\n\r\n{ownerMemBody}".toUTF8
  let .ok ownerMemReq := parseRequest ownerMemRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok ownerMemResp ← dispatchCoreRequest r5App ownerMemReq 70 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if ownerMemResp.status != 200 || (((String.fromUTF8? ownerMemResp.body).getD "").splitOn "untrusted managed compute nodes").length != 2 then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln s!"[orb-core-test] FAIL: SM-02 managedStore active VM claim did not deny memory_search_knowledge: {(String.fromUTF8? ownerMemResp.body).getD ""}"
    return 1
  let mmListRaw := s!"GET /api/managed-machines HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {opJwt}\r\n\r\n".toUTF8
  let .ok mmListReq := parseRequest mmListRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok mmListResp ← dispatchCoreRequest r5App mmListReq 70 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let rnListRaw := s!"GET /api/remote-nodes HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {opJwt}\r\n\r\n".toUTF8
  let .ok rnListReq := parseRequest rnListRaw none | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok rnListResp ← dispatchCoreRequest r5App rnListReq 70 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if pollResp.status != 200 || staleLeaseResp.status != 409 || ackResp.status != 200 ||
     mmListResp.status != 200 || rnListResp.status != 200 ||
     (((String.fromUTF8? mmListResp.body).getD "").splitOn "\"mm-r5b-1\"").length <= 1 ||
     (((String.fromUTF8? rnListResp.body).getD "").splitOn "\"managed-mm-r5b-1\"").length <= 1 then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: HTTP relay poll/respond or operator fleet routes failed"
    return 1
  let .ok () ← enqueueRelayCommand mst "mm-r5b-1" "cmd-1" "{\"op\":\"ping\"}"
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok (some leased1) ← pollRelayLease mst "mm-r5b-1" 1 70 80
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok none ← pollRelayLease mst "mm-r5b-1" 1 70 80
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok releasedCmd ← expireRelayLease mst "cmd-1" 85 1
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok (some leased2) ← pollRelayLease mst "mm-r5b-1" 1 85 96
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let staleLeaseAck ← stepRelayCommand mst "cmd-1" {
    opCode := Orb.ManagedNode.RelayOp.encode .ack, presentedLeaseId := leased1.heldLeaseId,
    presentedBootEpoch := 1, nowEpoch := 86
  }
  let .ok uncCmd ← stepRelayCommand mst "cmd-1" {
    opCode := Orb.ManagedNode.RelayOp.encode .markUncertain, presentedLeaseId := leased2.heldLeaseId,
    presentedBootEpoch := 1, nowEpoch := 87
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let uncRetry ← expireRelayLease mst "cmd-1" 120 1
  let .ok recCmd ← stepRelayCommand mst "cmd-1" {
    opCode := Orb.ManagedNode.RelayOp.encode .reconcile, presentedLeaseId := leased2.heldLeaseId,
    presentedBootEpoch := 1, nowEpoch := 88
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if leased1.phaseCode != 1 || leased2.heldLeaseId <= leased1.heldLeaseId || staleLeaseAck.isOk ||
     releasedCmd.phaseCode != 0 || uncCmd.phaseCode != 3 ||
     uncRetry.isOk || recCmd.phaseCode != 2 then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: leased relay transitions violated SM-19"
    return 1
  let .ok _ ← applyProviderObservation mst { provider := "boat", machineId := "mm-r5b-1", observedStatus := "stopped" } 90 0 0
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let sameBootResume ← applyVmLifecycle mst "mm-r5b-1" {
    opCode := Orb.ManagedNode.VmOp.encode .resume, ownerLive := 0, idleElapsed := 0,
    presentedBootEpoch := 1, nowEpoch := 95
  }
  let .ok (resumedSlice, _) ← applyVmLifecycle mst "mm-r5b-1" {
    opCode := Orb.ManagedNode.VmOp.encode .resume, ownerLive := 0, idleElapsed := 0,
    presentedBootEpoch := 2, nowEpoch := 95
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let staleNodeAuth ← authenticateNodeToken mst "mm-r5b-1" nodeTok1 (some 1)
  let .ok stalePollResp ← dispatchCoreRequest r5App pollReq 96 | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  if stalePollResp.status != 410 then
    closeCoreStore r5Store
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: superseded boot token did not return HTTP 410 on /relay/poll"
    return 1
  let staleClaim ← applyVmClaim mst "mm-r5b-1" "m-owner-2" {
    opCode := Orb.ManagedNode.ClaimOp.encode .claim, ownerInLineage := 1, ownerSuperseded := 0,
    vmLive := 1, activeComputeEligible := 1, presentedReservation := 11, presentedBootEpoch := 1
  }
  let .ok claimBoot2 ← applyVmClaim mst "mm-r5b-1" "m-owner-2" {
    opCode := Orb.ManagedNode.ClaimOp.encode .claim, ownerInLineage := 1, ownerSuperseded := 0,
    vmLive := 1, activeComputeEligible := 1, presentedReservation := 11, presentedBootEpoch := 2
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let .ok _ ← applyVmClaim mst "mm-r5b-1" "m-owner-2" {
    opCode := Orb.ManagedNode.ClaimOp.encode .release, ownerInLineage := 1, ownerSuperseded := 0,
    vmLive := 1, activeComputeEligible := 1, presentedReservation := 11, presentedBootEpoch := 2
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let sameBootReplace ← applyVmLifecycle mst "mm-r5b-1" {
    opCode := Orb.ManagedNode.VmOp.encode .replace, ownerLive := 0, idleElapsed := 0,
    presentedBootEpoch := 2, nowEpoch := 120
  }
  let .ok (replacedSlice, _) ← applyVmLifecycle mst "mm-r5b-1" {
    opCode := Orb.ManagedNode.VmOp.encode .replace, ownerLive := 0, idleElapsed := 0,
    presentedBootEpoch := 3, nowEpoch := 120
  } | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  let wrongProviderRej := (← applyProviderObservation mst
    { provider := "hetzner", machineId := "mm-r5b-1", observedStatus := "destroyed", orphaned := true } 150 0 1).isOk
  let .ok closeEffs ← applyProviderObservation mst
    { provider := "boat", machineId := "mm-r5b-1", observedStatus := "destroyed", orphaned := true } 150 0 1
    | do closeCoreStore r5Store; closeManagedComputeStore mst; return 1
  closeCoreStore r5Store
  closeManagedComputeStore mst
  IO.FS.removeDirAll r5Root
  if sameBootResume.isOk || resumedSlice.nodeBootEpoch != 2 || sameBootReplace.isOk ||
     replacedSlice.nodeBootEpoch != 3 || staleNodeAuth.isOk ||
     staleClaim.isOk || claimBoot2.claimBoot != 2 || wrongProviderRej ||
     !closeEffs.contains (.closeCostLedger 3) then
    IO.eprintln "[orb-core-test] FAIL: boot-epoch fence or closeCostLedger invariant failed"
    return 1
  return 0

private def runR7CoreTests (prodValid : CoreConfig) : IO UInt32 := do
  if verifyInboxCas 1 1 1 1 1 4 4 0 != 1 ||
     verifyInboxCas 1 1 1 1 1 4 5 0 != 0 ||
     verifyContextOpCas 1 1 1 1 1 7 7 1 1 != 1 ||
     verifyContextOpCas 1 1 1 1 1 7 3 1 1 != 0 ||
     verifyContextOpCas 1 1 1 1 1 0 0 0 1 != 0 ||
     verifyContextOpCas 1 1 1 1 1 0 0 0 0 != 1 ||
     verifyBoardTrack 1 1 1 1 0 != 1 ||
     verifyBoardTrack 1 1 1 1 1 != 0 ||
     verifyDeployRecheck 1 2 0 9 9 4 4 10 20 8 8 != 257 ||
     verifyDeployRecheck 1 2 0 9 9 4 5 10 20 8 8 == 257 ||
     Orb.Kernel.deployGateStep 1 1 0 1 0 1 0 0 != 1 ||
     Orb.Kernel.authToctouExecuteStep 2 0 9 9 4 4 10 20 8 8 != 257 ||
     Orb.Kernel.verifyBoardSlots 4 1 0 != 1 ||
     Orb.Kernel.verifyBoardRetry 0 3 0 0 0 != 1 then
    IO.eprintln "[orb-core-test] FAIL: R7 kernel gates rejected their own witnesses"
    return 1
  let r7Ts ← IO.monoNanosNow
  let r7Root := s!"/tmp/orb-core-r7-{r7Ts}"
  let .ok store ← openCoreStore r7Root
    | do IO.eprintln "[orb-core-test] FAIL: R7 openCoreStore failed"; return 1
  let managedRef ← IO.mkRef { enabled := true }
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (1 : UInt64)
  let bunkerRef ← IO.mkRef (0 : UInt8)
  let app : CoreAppState := {
    cfg := { prodValid with workingDir := r7Root }, store := store, searchIdx? := none,
    managedRef := managedRef, chainsRef := chainsRef,
    proxyCooldownsRef := cooldownsRef, seqRef := seqRef,
    bunkerStateRef? := some bunkerRef
  }
  let nowSec ← coreEpochSec
  let jwt := mintSessionToken prodValid.jwtSecret (nowSec + 3600)
  let dispatch (raw : String) : IO (Option CoreHttpResponse) := do
    match parseRequest raw.toUTF8 none with
    | .ok req =>
      match ← dispatchCoreRequest app req nowSec with
      | .ok resp => return some resp
      | .error _ => return none
    | .error _ => return none
  let unauth ← dispatch "GET /api/control/inbox-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
  let get0 ← dispatch s!"GET /api/control/inbox-state HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let prefBody := "{\"clientId\":\"c1\",\"mutationSeq\":1,\"expectedVersion\":0,\"aiSummary\":true,\"includeAutonomous\":false,\"model\":\"m\",\"inboxEnabled\":true}"
  let prefRaw := s!"PUT /api/control/inbox-state/preferences HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {prefBody.utf8ByteSize}\r\n\r\n{prefBody}"
  let put1 ← dispatch prefRaw
  let replay ← dispatch prefRaw
  let staleBody := "{\"clientId\":\"c2\",\"mutationSeq\":2,\"expectedVersion\":0,\"aiSummary\":false,\"includeAutonomous\":true,\"model\":\"n\"}"
  let stale ← dispatch s!"PUT /api/control/inbox-state/preferences HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {staleBody.utf8ByteSize}\r\n\r\n{staleBody}"
  let seenBody := "{\"clientId\":\"c1\",\"mutationSeq\":3,\"expectedVersion\":0,\"stamp\":9}"
  let seen ← dispatch s!"PUT /api/control/inbox-state/seen/q%2F1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {seenBody.utf8ByteSize}\r\n\r\n{seenBody}"
  let negSeenBody := "{\"clientId\":\"c1\",\"mutationSeq\":4,\"expectedVersion\":1,\"stamp\":-1}"
  let negSeen ← dispatch s!"PUT /api/control/inbox-state/seen/q%2F1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {negSeenBody.utf8ByteSize}\r\n\r\n{negSeenBody}"
  let get1 ← dispatch s!"GET /api/control/inbox-state HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let zeroSeenBody := "{\"clientId\":\"c1\",\"mutationSeq\":5,\"expectedVersion\":2,\"stamp\":0}"
  let badStamp ← dispatch s!"PUT /api/control/inbox-state/seen/q%2F1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {zeroSeenBody.utf8ByteSize}\r\n\r\n{zeroSeenBody}"
  let g0 := (get0.map (·.body)).bind String.fromUTF8? |>.getD ""
  let p1 := (put1.map (·.body)).bind String.fromUTF8? |>.getD ""
  let rp := (replay.map (·.body)).bind String.fromUTF8? |>.getD ""
  let stl := (stale.map (·.body)).bind String.fromUTF8? |>.getD ""
  let g1 := (get1.map (·.body)).bind String.fromUTF8? |>.getD ""
  if unauth.map (·.status) != some 401 || get0.map (·.status) != some 200 ||
     (g0.splitOn "_versions").length < 2 || put1.map (·.status) != some 200 ||
     (p1.splitOn "\"preferences\":1").length < 2 || replay.map (·.status) != some 200 ||
     (rp.splitOn "\"replayed\":true").length < 2 || stale.map (·.status) != some 409 ||
     (stl.splitOn "_versions").length < 2 || seen.map (·.status) != some 200 ||
     negSeen.map (·.status) != some 200 ||
     (g1.splitOn "\"seen:q/1\":-1").length < 2 || badStamp.map (·.status) != some 400 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: inbox CAS wire contract mismatch: {g1}"
    return 1
  let blob := "project-context-bytes".toUTF8
  let blobRaw := s!"POST /api/projects/orb/context/blobs HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {blob.size}\r\n\r\nproject-context-bytes"
  let blobResp ← dispatch blobRaw
  let blobJson := (blobResp.map (·.body)).bind String.fromUTF8? |>.getD ""
  let hash := (OrbBin.Json.parse blobJson).toOption.bind (·.fieldStr? "hash") |>.getD ""
  let readBlob ← dispatch s!"GET /api/projects/orb/context/blobs/{hash} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let opBody := s!"\{\"id\":\"op-1\",\"path\":\"docs/a.txt\",\"base\":null,\"hash\":\"{hash}\",\"directory\":false,\"delete\":false,\"source\":\"Orb\"}"
  let opResp ← dispatch s!"POST /api/projects/orb/context/operations HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {opBody.utf8ByteSize}\r\n\r\n{opBody}"
  let staleOp := s!"\{\"id\":\"op-2\",\"path\":\"docs/a.txt\",\"base\":0,\"hash\":\"{hash}\",\"directory\":false,\"delete\":false,\"source\":\"Orb\"}"
  let staleOpResp ← dispatch s!"POST /api/projects/orb/context/operations HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {staleOp.utf8ByteSize}\r\n\r\n{staleOp}"
  let conflicts ← dispatch s!"GET /api/projects/orb/context/conflicts HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let manifest ← dispatch s!"GET /api/projects/orb/context/manifest HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let historyResp ← dispatch s!"GET /api/projects/orb/context/history HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let streamResp ← dispatch s!"GET /api/projects/orb/context/stream HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let travBody := "{\"id\":\"op-3\",\"path\":\"../x\",\"delete\":true}"
  let traversal ← dispatch s!"POST /api/projects/orb/context/operations HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {travBody.utf8ByteSize}\r\n\r\n{travBody}"
  let blobDirStat ← OrbBin.PosixExt.statPath (contextBlobDir r7Root "orb").toString
  let fiveMib := ByteArray.mk (Array.replicate (5 * 1024 * 1024) (65 : UInt8))
  let fiveMibStatus ← do
    let hdrs := s!"POST /api/projects/orb/context/blobs HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {fiveMib.size}\r\n\r\n".toUTF8
    match parseCoreHttpRequest (hdrs ++ fiveMib) with
    | .ok req =>
      match ← dispatchCoreRequest app req nowSec with
      | .ok resp => pure (some resp.status)
      | .error _ => pure none
    | .error _ => pure none
  let big := ByteArray.mk (Array.replicate (contextFileLimit + 1) (1 : UInt8))
  let bigHttp ← do
    let hdrs := s!"POST /api/projects/orb/context/blobs HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {big.size}\r\n\r\n".toUTF8
    match parseCoreHttpRequest (hdrs ++ big) with
    | .ok req =>
      match ← dispatchCoreRequest app req nowSec with
      | .ok resp => pure (some resp.status)
      | .error _ => pure none
    | .error e => pure (some (statusForParseError e))
  let opText := (opResp.map (·.body)).bind String.fromUTF8? |>.getD ""
  let staleText := (staleOpResp.map (·.body)).bind String.fromUTF8? |>.getD ""
  let conflictText := (conflicts.map (·.body)).bind String.fromUTF8? |>.getD ""
   let manifestText := (manifest.map (·.body)).bind String.fromUTF8? |>.getD ""
   let sameOp := s!"\{\"id\":\"op-same\",\"path\":\"docs/a.txt\",\"base\":null,\"hash\":\"{hash}\",\"directory\":false,\"delete\":false}"
   let sameResp ← dispatch s!"POST /api/projects/orb/context/operations HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {sameOp.utf8ByteSize}\r\n\r\n{sameOp}"
   let blob2 := "other-context-bytes".toUTF8
   let blob2Resp ← dispatch s!"POST /api/projects/orb/context/blobs HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {blob2.size}\r\n\r\nother-context-bytes"
   let hash2 := ((blob2Resp.map (·.body)).bind String.fromUTF8?).bind (fun s => (OrbBin.Json.parse s).toOption.bind (·.fieldStr? "hash")) |>.getD ""
   let clashOp := s!"\{\"id\":\"op-clash\",\"path\":\"docs/a.txt\",\"base\":null,\"hash\":\"{hash2}\",\"directory\":false,\"delete\":false,\"source\":\"Agent\"}"
   let clashResp ← dispatch s!"POST /api/projects/orb/context/operations HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {clashOp.utf8ByteSize}\r\n\r\n{clashOp}"
   let conflicts2 ← dispatch s!"GET /api/projects/orb/context/conflicts HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
   let conflict2Text := (conflicts2.map (·.body)).bind String.fromUTF8? |>.getD ""
   let conflict2Jv := (OrbBin.Json.parse conflict2Text).toOption.getD (.obj #[])
   let op2Obj? := conflict2Jv.field? "op-2"
   let clashObj? := conflict2Jv.field? "op-clash"
   let resolveOp := s!"\{\"id\":\"op-resolve\",\"path\":\"docs/a.txt\",\"base\":1,\"hash\":\"{hash2}\",\"directory\":false,\"delete\":false,\"source\":\"Orb\"}"
   let resolveResp ← dispatch s!"POST /api/projects/orb/context/conflicts/op-clash HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {resolveOp.utf8ByteSize}\r\n\r\n{resolveOp}"
   let missingConflictOp := s!"\{\"id\":\"op-missing-conf\",\"path\":\"docs/a.txt\",\"base\":2,\"hash\":\"{hash2}\",\"directory\":false,\"delete\":false,\"source\":\"Orb\"}"
   let missingConflictResp ← dispatch s!"POST /api/projects/orb/context/conflicts/no-such-id HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {missingConflictOp.utf8ByteSize}\r\n\r\n{missingConflictOp}"
   let conflicts3 ← dispatch s!"GET /api/projects/orb/context/conflicts HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
   let conflict3Jv := ((conflicts3.map (·.body)).bind String.fromUTF8?).bind (fun s => (OrbBin.Json.parse s).toOption) |>.getD (.obj #[])
   let history2Resp ← dispatch s!"GET /api/projects/orb/context/history HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
   let historyText := (historyResp.map (·.body)).bind String.fromUTF8? |>.getD ""
   let history2Text := (history2Resp.map (·.body)).bind String.fromUTF8? |>.getD ""
   let historyArr := match OrbBin.Json.parse historyText with | .ok (.arr xs) => xs | _ => #[]
   let history2Arr := match OrbBin.Json.parse history2Text with | .ok (.arr xs) => xs | _ => #[]
   let streamText := (streamResp.map (·.body)).bind String.fromUTF8? |>.getD ""
   let sameText := (sameResp.map (·.body)).bind String.fromUTF8? |>.getD ""
   let clashText := (clashResp.map (·.body)).bind String.fromUTF8? |>.getD ""
   if blobResp.map (·.status) != some 200 || !isSha256Hex hash ||
      (blobDirStat.mode &&& 0o777) != 0o700 ||
      readBlob.map (·.status) != some 200 || readBlob.map (·.body) != some blob ||
      opResp.map (·.status) != some 200 || (opText.splitOn "\"conflict\":false").length < 2 ||
      staleOpResp.map (·.status) != some 200 || (staleText.splitOn "\"conflict\":true").length < 2 ||
      sameResp.map (·.status) != some 200 || (sameText.splitOn "\"conflict\":false").length < 2 ||
      clashResp.map (·.status) != some 200 || (clashText.splitOn "\"conflict\":true").length < 2 ||
      (conflictText.splitOn "\"op-2\"").length < 2 ||
      op2Obj?.bind (·.fieldStr? "path") != some "docs/a.txt" ||
      op2Obj?.bind (·.fieldNat? "base") != some 0 ||
      op2Obj?.bind (·.fieldStr? "hash") != some hash ||
      op2Obj?.bind (·.fieldBool? "directory") != some false ||
      op2Obj?.bind (·.fieldBool? "delete") != some false ||
      op2Obj?.bind (·.fieldStr? "source") != some "Orb" ||
      clashObj?.bind (·.fieldStr? "path") != some "docs/a.txt" ||
      clashObj?.bind (·.field? "base") != some .null ||
      clashObj?.bind (·.fieldStr? "source") != some "Agent" ||
      resolveResp.map (·.status) != some 200 ||
      missingConflictResp.map (·.status) != some 404 ||
      (conflict3Jv.field? "op-clash").isSome ||
      historyResp.map (·.status) != some 200 || historyArr.size != 1 ||
      (historyArr[0]?).bind (·.fieldNat? "revision") != some 1 ||
      (historyArr[0]?).bind (·.fieldStr? "path") != some "docs/a.txt" ||
      (historyArr[0]?).bind (·.fieldStr? "source") != some "Orb" ||
      history2Arr.size != 2 ||
      (history2Arr[0]?).bind (·.fieldNat? "revision") != some 1 ||
      (history2Arr[1]?).bind (·.fieldNat? "revision") != some 2 ||
      streamResp.map (·.status) != some 200 ||
      streamResp.map (·.contentType) != some "text/event-stream" ||
      !streamText.startsWith "data: {" || !streamText.endsWith "\n\n" ||
      (manifestText.splitOn "\"docs/a.txt\"").length < 2 ||
      (stl.splitOn "\"preferences\":1").length < 2 ||
      traversal.map (·.status) != some 400 || fiveMibStatus != some 200 || bigHttp != some 413 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: project context wire contract mismatch: {manifestText}"
    return 1
   let trackBody := "{\"track\":\"core\",\"desired_condition\":\"ship\",\"status\":\"open\"}"
   let trackResp ← dispatch s!"POST /api/projects/orb/tracks HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {trackBody.utf8ByteSize}\r\n\r\n{trackBody}"
   for mid in ["m1", "m2", "m3", "m4"] do
     let .ok () ← insertNewMission store {
       id := mid, title := mid, status := "running", backend := "opencode",
       modelOverride := "", workingDirectory := r7Root, project := "orb", updatedAt := s!"{nowSec}"
     } | do closeCoreStore store; return 1
   let staleTrackBody := "{\"track\":\"core\",\"desired_condition\":\"stale\",\"status\":\"open\",\"expected_revision\":99}"
  let staleTrack ← dispatch s!"POST /api/projects/orb/tracks HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {staleTrackBody.utf8ByteSize}\r\n\r\n{staleTrackBody}"
  let taskBody := "{\"project_slug\":\"orb\",\"track\":\"core\",\"task_key\":\"t1\",\"attempt_seq\":0,\"max_attempts\":3}"
  let taskResp ← dispatch s!"POST /api/control/missions/m1/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {taskBody.utf8ByteSize}\r\n\r\n{taskBody}"
  let dupTask ← dispatch s!"POST /api/control/missions/m1/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {taskBody.utf8ByteSize}\r\n\r\n{taskBody}"
  let retryBody := "{\"project_slug\":\"orb\",\"track\":\"core\",\"task_key\":\"t-retry\",\"attempt_seq\":3,\"max_attempts\":3}"
  let retryRej ← dispatch s!"POST /api/control/missions/m1/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {retryBody.utf8ByteSize}\r\n\r\n{retryBody}"
  let task2Body := "{\"project_slug\":\"orb\",\"track\":\"core\",\"task_key\":\"t2\",\"attempt_seq\":0,\"max_attempts\":3}"
  let task3Body := "{\"project_slug\":\"orb\",\"track\":\"core\",\"task_key\":\"t3\",\"attempt_seq\":0,\"max_attempts\":3}"
  let task4Body := "{\"project_slug\":\"orb\",\"track\":\"core\",\"task_key\":\"t4\",\"attempt_seq\":0,\"max_attempts\":3}"
  let t2Resp ← dispatch s!"POST /api/control/missions/m2/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {task2Body.utf8ByteSize}\r\n\r\n{task2Body}"
  let t3Resp ← dispatch s!"POST /api/control/missions/m3/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {task3Body.utf8ByteSize}\r\n\r\n{task3Body}"
  let fullResp ← dispatch s!"POST /api/control/missions/m4/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {task4Body.utf8ByteSize}\r\n\r\n{task4Body}"
  let missBody := "{\"project_slug\":\"orb\",\"track\":\"missing\",\"task_key\":\"t-miss\",\"attempt_seq\":0}"
  let missing ← dispatch s!"POST /api/control/missions/m1/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {missBody.utf8ByteSize}\r\n\r\n{missBody}"
   let board ← dispatch s!"GET /api/projects/orb/board HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
   let badProj ← dispatch s!"GET /api/projects/%ZZ/board HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
   let _ ← execParamQuery store.missionsDb "UPDATE mission_board_tasks SET status='failed' WHERE task_key='t1';" #[]
   let reopen ← dispatch s!"POST /api/control/missions/m1/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {taskBody.utf8ByteSize}\r\n\r\n{taskBody}"
   let ghost ← dispatch s!"POST /api/control/missions/missing-mission/board-task HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {taskBody.utf8ByteSize}\r\n\r\n{taskBody}"
  let boardText := (board.map (·.body)).bind String.fromUTF8? |>.getD ""
  let dupText := (dupTask.map (·.body)).bind String.fromUTF8? |>.getD ""
  let missText := (missing.map (·.body)).bind String.fromUTF8? |>.getD ""
  let retryText := (retryRej.map (·.body)).bind String.fromUTF8? |>.getD ""
  let fullText := (fullResp.map (·.body)).bind String.fromUTF8? |>.getD ""
  if trackResp.map (·.status) != some 200 || staleTrack.map (·.status) != some 409 ||
     taskResp.map (·.status) != some 200 || t2Resp.map (·.status) != some 200 ||
     t3Resp.map (·.status) != some 200 ||
     dupTask.map (·.status) != some 409 || (dupText.splitOn "duplicate_task").length < 2 ||
     retryRej.map (·.status) != some 409 || (retryText.splitOn "board_retry_suppressed").length < 2 ||
     fullResp.map (·.status) != some 409 || (fullText.splitOn "board_slots_full").length < 2 ||
      missing.map (·.status) != some 409 || (missText.splitOn "unknown_track").length < 2 ||
      badProj.map (·.status) != some 400 ||
      reopen.map (·.status) != some 200 || ghost.map (·.status) != some 404 ||
      (boardText.splitOn "\"task_key\":\"t1\"").length < 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: project board wire contract mismatch: {boardText}"
    return 1
   let cap1TrackBody := "{\"track\":\"cap1\",\"desired_condition\":\"one-slot\",\"status\":\"open\"}"
   let cap1Track ← dispatch s!"POST /api/projects/orbcap/tracks HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {cap1TrackBody.utf8ByteSize}\r\n\r\n{cap1TrackBody}"
   let _ ← execParamQuery store.projectsDb
     "INSERT OR REPLACE INTO project_grant(slug,parallel_missions,updated_at) VALUES('orbcap',2,?1);" #[s!"{nowSec}"]
   let .ok cap1TaskA := OrbBin.Json.parse "{\"project_slug\":\"orbcap\",\"track\":\"cap1\",\"task_key\":\"cap-a\",\"attempt_seq\":0,\"max_attempts\":3}"
     | do closeCoreStore store; return 1
   let .ok cap1TaskB := OrbBin.Json.parse "{\"project_slug\":\"orbcap\",\"track\":\"cap1\",\"task_key\":\"cap-b\",\"attempt_seq\":0,\"max_attempts\":3}"
     | do closeCoreStore store; return 1
   let taskFiberA ← IO.asTask (prio := .dedicated) (postBoardTask store "m1" cap1TaskA)
   let taskFiberB ← IO.asTask (prio := .dedicated) (postBoardTask store "m2" cap1TaskB)
   let .ok (capCodeA, _) ← IO.wait taskFiberA | do closeCoreStore store; return 1
   let .ok (capCodeB, _) ← IO.wait taskFiberB | do closeCoreStore store; return 1
   let capOpenRes ← countOpenBoardSlots store "orbcap"
   let capOpenCount := match capOpenRes with | .ok n => n | .error _ => 99
   let cancelTrackBody := "{\"track\":\"cap1\",\"desired_condition\":\"cancelled\",\"status\":\"cancelled\"}"
   let cancelTrack ← dispatch s!"POST /api/projects/orbcap/tracks HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {cancelTrackBody.utf8ByteSize}\r\n\r\n{cancelTrackBody}"
   let _ ← execParamQuery store.missionsDb "UPDATE mission_board_tasks SET status='failed' WHERE project_slug='orbcap';" #[]
   let .ok cap1TaskC := OrbBin.Json.parse "{\"project_slug\":\"orbcap\",\"track\":\"cap1\",\"task_key\":\"cap-c\",\"attempt_seq\":0,\"max_attempts\":3}"
     | do closeCoreStore store; return 1
   let (capCancelCode, capCancelBody) ← postBoardTask store "m3" cap1TaskC
   if cap1Track.map (·.status) != some 200 ||
      !((capCodeA == 200 && capCodeB == 409) || (capCodeA == 409 && capCodeB == 200)) ||
      capOpenCount != 1 ||
      cancelTrack.map (·.status) != some 200 ||
      capCancelCode != 409 || (capCancelBody.splitOn "board_rejected").length < 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: concurrent 1-slot board cap / track cancel mismatch: a={capCodeA} b={capCodeB} open={capOpenCount} cancel={capCancelCode}"
    return 1
   let dryBody := "{\"service\":\"sandboxed-sh-dev\",\"dry_run\":true}"
   let noLease ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nX-Paloma-Approval: approved\r\nContent-Length: {dryBody.utf8ByteSize}\r\n\r\n{dryBody}"
   let privExp := nowSec + 240
   let .ok () ← upsertPrivilegeLease store {
     grantId := "grant-r7", leaseToken := "lease-r7-live-01", missionId := "m-r7",
     targetHost := "self", scope := "service_deploy", allowedUnitsJson := "[\"sandboxed-sh-dev.service\"]",
     requireForceCmd := false, biometricSigned := true, revoked := false, expiresAtEpoch := privExp
   } | do closeCoreStore store; return 1
   let dryBody2 := "{\"service\":\"sandboxed-sh-dev\",\"dry_run\":true,\"lease_token\":\"lease-r7-live-01\"}"
   let dry ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {dryBody2.utf8ByteSize}\r\n\r\n{dryBody2}"
   let dryText := (dry.map (·.body)).bind String.fromUTF8? |>.getD ""
   let prodLie := "{\"service\":\"sandboxed-sh\",\"dry_run\":true,\"is_prod\":false,\"lease_token\":\"lease-r7-unsigned\"}"
   let .ok () ← upsertPrivilegeLease store {
     grantId := "grant-unsigned", leaseToken := "lease-r7-unsigned", missionId := "m-r7",
     targetHost := "self", scope := "service_deploy", allowedUnitsJson := "[\"*\"]",
     requireForceCmd := false, biometricSigned := false, revoked := false, expiresAtEpoch := privExp
   } | do closeCoreStore store; return 1
   let prodDeny ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {prodLie.utf8ByteSize}\r\n\r\n{prodLie}"
   let some liveLease ← lookupPrivilegeLease? store "lease-r7-live-01" | do closeCoreStore store; return 1
   let deb0 ← observeDeployLive store "sandboxed-sh-dev.service" false true false (some liveLease) nowSec
   let _ ← persistDeployReceipt store {
     unitName := "sandboxed-sh-dev.service", observedDigest := 1, execDigest := 1,
     verdictCode := 257, verdict := "admitted", dryRun := false, restart := false
   } s!"{nowSec - 10}"
   let deb1 ← observeDeployLive store "sandboxed-sh-dev.service" false true false (some liveLease) nowSec
   let _ ← execParamQuery store.missionsDb
     "UPDATE deploy_receipts SET created_at=?1 WHERE unit_name='sandboxed-sh-dev.service';" #[s!"{nowSec - 60}"]
   let badUnitBody := "{\"service\":\"../evil\",\"dry_run\":true}"
   let badUnit ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {badUnitBody.utf8ByteSize}\r\n\r\n{badUnitBody}"
   let defaultDryBody := "{\"service\":\"../evil\"}"
   let defaultDryUnit ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {defaultDryBody.utf8ByteSize}\r\n\r\n{defaultDryBody}"
   let noDryNoLeaseBody := "{\"expected_service\":\"sandboxed-sh-dev.service\"}"
   let noDryNoLease ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {noDryNoLeaseBody.utf8ByteSize}\r\n\r\n{noDryNoLeaseBody}"
   let privVerifyBody := "{\"mission_id\":\"m-r7\",\"lease_token\":\"lease-r7-live-01\",\"target_host\":\"self\",\"executing_host\":\"self\",\"command\":\"systemctl restart sandboxed-sh-dev.service\",\"argv\":[\"systemctl\",\"restart\",\"sandboxed-sh-dev.service\"]}"
   let privVerifyRaw := s!"POST /api/privilege-access/verify-and-log HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {privVerifyBody.utf8ByteSize}\r\n\r\n{privVerifyBody}"
   let privOk ← dispatch privVerifyRaw
   let privOkText := (privOk.map (·.body)).bind String.fromUTF8? |>.getD ""
   let .ok () ← writePersistedBunkerState store 1 | do closeCoreStore store; return 1
   bunkerRef.set 1
   let privBunker ← dispatch privVerifyRaw
   let privBunkerText := (privBunker.map (·.body)).bind String.fromUTF8? |>.getD ""
   let bunker ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {dryBody2.utf8ByteSize}\r\n\r\n{dryBody2}"
   let bunkerText := (bunker.map (·.body)).bind String.fromUTF8? |>.getD ""
   let .ok () ← writePersistedBunkerState store 0 | do closeCoreStore store; return 1
   bunkerRef.set 0
   let shPayload := "{\"expected_service\":\"sandboxed-sh-dev.service\",\"force\":false,\"skip_build\":true,\"repo_path\":\"/tmp/orb\",\"calling_mission_id\":\"m-r7\",\"git_ref\":\"HEAD\",\"dry_run\":true}"
   let hdrLeaseDeploy ← dispatch s!"POST /api/system/deploy HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nX-Orb-Lease: lease-r7-live-01\r\nContent-Length: {shPayload.utf8ByteSize}\r\n\r\n{shPayload}"
   let hdrLeaseText := (hdrLeaseDeploy.map (·.body)).bind String.fromUTF8? |>.getD ""
   let .ok () ← upsertPrivilegeLease store {
     grantId := "grant-revoke", leaseToken := "lease-r7-revoke-01", missionId := "m-r7",
     targetHost := "self", scope := "service_deploy", allowedUnitsJson := "[\"sandboxed-sh-dev.service\"]",
     requireForceCmd := false, biometricSigned := true, revoked := false,
     expiresAtEpoch := privExp, leaseEpoch := 42
   } | do closeCoreStore store; return 1
   let some preRevokeLease ← lookupPrivilegeLease? store "lease-r7-revoke-01" | do closeCoreStore store; return 1
   let revokeObs ← observeDeployLive store "sandboxed-sh-dev.service" false false false (some preRevokeLease) nowSec
   let .ok () ← upsertPrivilegeLease store { preRevokeLease with revoked := true } | do closeCoreStore store; return 1
   let revokeRestarted ← IO.mkRef false
   let reobserveRevoked : IO DeployObservation := do
     let cur? ← lookupPrivilegeLease? store "lease-r7-revoke-01"
     observeDeployLive store "sandboxed-sh-dev.service" false false false cur? nowSec
   let .ok revokeRcpt ← runGuardedDeploy store revokeObs reobserveRevoked false s!"{nowSec}"
       (some (fun _ => do revokeRestarted.set true; return .ok ()))
     | do closeCoreStore store; return 1
   let wasRevokeRestarted ← revokeRestarted.get
   let postRevokeObs ← reobserveRevoked
   let restartCalled ← IO.mkRef false
   let driftObs : DeployObservation := {
     unitName := "sandboxed-sh.service", isProd := true, serviceMatches := true,
     callingOnSelf := false, debounceOk := true, forceFlag := false, biometric := true,
     bunkerState := 0, liveWriters := 0, principalKind := 2, targetId := 1,
     leaseEpoch := nowSec + 300, expiryTick := nowSec + 300, digest := 777, nowTick := nowSec
   }
   let driftLive := { driftObs with leaseEpoch := 0, expiryTick := 0 }
   let .ok driftRcpt ← runGuardedDeploy store driftObs (pure driftLive) false s!"{nowSec}"
       (some (fun _ => do restartCalled.set true; return .ok ()))
     | do closeCoreStore store; return 1
   let wasRestarted ← restartCalled.get
   let execFailRes ← runGuardedDeploy store driftObs (pure driftObs) false s!"{nowSec}"
       (some (fun _ => pure (.error "boom")))
   let failRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM deploy_receipts WHERE verdict='exec_failed';" #[]
   let nExecFailed := match failRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
   let admRows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM deploy_receipts WHERE unit_name='sandboxed-sh.service' AND verdict='admitted';" #[]
   let nFalseAdmitted := match admRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 99
   let rows ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM deploy_receipts;" #[]
   let nReceipts := match rows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
   closeCoreStore store
   let cliNoLease ← IO.Process.output {
     cmd := "./lean/OrbCore/.lake/build/bin/orb-core"
     args := #["deploy", "--service", "sandboxed-sh-dev.service", "--dry-run"]
     env := #[("WORKING_DIR", some r7Root), ("DEV_MODE", some "true")]
   }
   let cliSubRoot := s!"{r7Root}-cli"
   let .ok cliStore ← openCoreStore s!"{cliSubRoot}/.sandboxed-sh" | do IO.FS.removeDirAll r7Root; return 1
   let .ok () ← upsertPrivilegeLease cliStore {
     grantId := "grant-cli", leaseToken := "lease-r7-cli-01", missionId := "m-cli",
     targetHost := "self", scope := "service_deploy", allowedUnitsJson := "[\"sandboxed-sh-dev.service\"]",
     requireForceCmd := false, biometricSigned := true, revoked := false, expiresAtEpoch := privExp
   } | do closeCoreStore cliStore; IO.FS.removeDirAll r7Root; return 1
   closeCoreStore cliStore
   let cliWithLease ← IO.Process.output {
     cmd := "./lean/OrbCore/.lake/build/bin/orb-core"
     args := #["deploy", "--service", "sandboxed-sh-dev.service", "--dry-run", "--lease", "lease-r7-cli-01", "--force"]
     env := #[("WORKING_DIR", some cliSubRoot), ("DEV_MODE", some "true")]
   }
   IO.FS.removeDirAll cliSubRoot
   IO.FS.removeDirAll r7Root
   if       noLease.map (·.status) != some 403 ||
      noDryNoLease.map (·.status) != some 403 ||
      defaultDryUnit.map (·.status) != some 400 ||
      dry.map (·.status) != some 200 || (dryText.splitOn "dry_run_admitted").length < 2 ||
      prodDeny.map (·.status) != some 409 ||
      deb0.debounceOk != true || deb1.debounceOk != false ||
      badUnit.map (·.status) != some 400 ||
      privOk.map (·.status) != some 200 ||
      (privOkText.splitOn "\"bunker_state\":0").length < 2 ||
      (privOkText.splitOn s!"\"expires_at\":{privExp}").length < 2 ||
      (privOkText.splitOn s!"\"lease_epoch\":{privExp}").length < 2 ||
      privBunker.map (·.status) != some 403 ||
      (privBunkerText.splitOn "\"bunker_state\":1").length < 2 ||
      (privBunkerText.splitOn "\"allow_exec\":false").length < 2 ||
      bunker.map (·.status) != some 409 ||
      (bunkerText.splitOn "gate_denied").length < 2 ||
      driftRcpt.verdict != "reconciliation_required" || driftRcpt.restart || wasRestarted ||
      hdrLeaseDeploy.map (·.status) != some 200 || (hdrLeaseText.splitOn "dry_run_admitted").length < 2 ||
      revokeObs.leaseEpoch != 42 || postRevokeObs.leaseEpoch != 0 ||
      revokeRcpt.verdict != "reconciliation_required" || revokeRcpt.verdictCode != 516 ||
      revokeRcpt.restart || wasRevokeRestarted ||
      execFailRes.isOk || nExecFailed != 1 || nFalseAdmitted != 0 ||
      cliNoLease.exitCode == 0 || cliWithLease.exitCode != 0 ||
      nReceipts < 2 then
    IO.eprintln s!"[orb-core-test] FAIL: guarded deploy / privilege bunker wire contract mismatch: hdr={hdrLeaseDeploy.map (·.status)}:{hdrLeaseText} revObs={revokeObs.leaseEpoch}->{postRevokeObs.leaseEpoch} revRcpt={revokeRcpt.verdict}:{revokeRcpt.verdictCode} cliNo={cliNoLease.exitCode} cliWith={cliWithLease.exitCode}:{cliWithLease.stderr} ok={privOkText} bunker={privBunkerText}"
    return 1
  return 0

private def runR4dUnitTests (r4dRoot : String) (r4dChain : RoutingChain) : IO UInt32 := do
  -- (A) `OrbCore.Proxy`: sticky `firstByteCommitted` lock (`abortCommittedLock = 4` on mid-stream failure,
  -- `passCommittedStream = 8` on committed 2xx), pre-commit failover, stale `attemptGeneration` fencing (`0`),
  -- and unified `ProviderHealthTracker` exponential cooldowns + circuit breaker (`Orb.Kernel.accountCooldownSecs` / `breakerStep`).
  let hTracker ← newProviderHealthTracker 1 2
  -- 1. Pre-commit 503 fails over cleanly to `acct-backup` (`firstByteCommitted = false` -> `true` on 200 commit),
  -- recording `transientStreak = 1` (< `transientThreshold = 2`, so not yet cooled down).
  let preCommitOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-primary" then
        return .ok { status := 503, headers := #[], body := "{\"error\":\"overloaded\"}".toUTF8 }
      else
        return .ok { status := 200, headers := #[("Content-Type", "text/event-stream")], body := "data: ok\n\n".toUTF8 })
    false none #[] (some hTracker) (some 1) (some 1000)
  let primRec1 ← lookupAccountHealthRecord hTracker "acct-primary"
  if preCommitOut.status != 200 || preCommitOut.selectedAccount != "acct-backup" ||
     preCommitOut.attemptsUsed != 2 || !preCommitOut.firstByteCommitted ||
     preCommitOut.pinnedAccountId != accountSlotId "acct-backup" ||
     preCommitOut.verdictCode != 1 || primRec1.transientStreak != 1 || primRec1.cooldown?.isSome then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D pre-commit failover/health mismatch: acct={preCommitOut.selectedAccount} streak={primRec1.transientStreak}"
    return 1

  -- 2. Second transient 503 on `acct-primary` reaches `transientThreshold == 2` and trips the account breaker,
  -- installing an exponential cooldown via `Orb.Kernel.accountCooldownSecs` so `planChainFromHealth` skips `acct-primary`!
  let tripOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-primary" then
        return .ok { status := 503, headers := #[], body := "{\"error\":\"overloaded_again\"}".toUTF8 }
      else
        return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"ok\":true}".toUTF8 })
    false none #[] (some hTracker) (some 1) (some 1005)
  let primRec2 ← lookupAccountHealthRecord hTracker "acct-primary"
  let planDuringCool ← planChainFromHealth hTracker r4dChain 1010
  let planAfterExpiry ← planChainFromHealth hTracker r4dChain 2000
  if tripOut.status != 200 || tripOut.selectedAccount != "acct-backup" ||
     primRec2.consecutiveTrips != 1 || primRec2.cooldown?.isNone ||
     planDuringCool.eligible.size != 1 || planDuringCool.eligible[0]!.accountId != "acct-backup" ||
     planAfterExpiry.eligible.size != 2 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D breaker cooldown/expiry mismatch: trips={primRec2.consecutiveTrips} elig={planDuringCool.eligible.size}"
    return 1

  -- 3. Exponential cooldown progression (`15s -> 30s -> 60s` for rate-limit, capped at `maxCooldownRetryAfterSecs`).
  let e1 := exponentialCooldownSecs .rateLimit 1
  let e2 := exponentialCooldownSecs .rateLimit 2
  let e3 := exponentialCooldownSecs .rateLimit 3
  let u1 := exponentialCooldownSecs .usageLimit 1
  let u2 := exponentialCooldownSecs .usageLimit 2
  let uCap := exponentialCooldownSecs .usageLimit 20
  if e1 != 15 || e2 != 30 || e3 != 60 || u1 != 300 || u2 != 600 || uCap != maxCooldownRetryAfterSecs then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D exponentialCooldownSecs mismatch ({e1}, {e2}, {e3}, {u1}, {u2}, {uCap})"
    return 1

  -- 4. Sticky `firstByteCommitted = true` (`headersAlreadyCommitted := true`):
  --    - 200 response yields `verdictCode == 8` (`passCommittedStream`) on the pinned primary without touching backup.
  --    - 503 mid-stream failure yields `verdictCode == 4` (`abortCommittedLock`), `attemptsUsed == 1`, and NEVER reroutes to `acct-backup`!
  let backupTouchedRef ← IO.mkRef false
  let committedPassOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-backup" then backupTouchedRef.set true
      return .ok { status := 200, headers := #[("Content-Type", "text/event-stream")], body := "data: chunk2\n\n".toUTF8 })
    true none #[] (some hTracker) (some 1) (some 2005)
  let committedAbortOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-backup" then backupTouchedRef.set true
      return .ok { status := 503, headers := #[], body := "{\"error\":\"mid_stream_reset\"}".toUTF8 })
    true none #[] (some hTracker) (some 1) (some 2006)
  let committedNetAbortOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-backup" then backupTouchedRef.set true
      return .error "mid_stream_eof")
    true none #[] (some hTracker) (some 1) (some 2007)
  let committedRemovedPinOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun _ => do
      backupTouchedRef.set true
      return .ok { status := 200, headers := #[], body := "{\"hijack\":true}".toUTF8 })
    true none #[] (some hTracker) (some 1) (some 2008) (some "acct-removed")
  let committedMissingPinOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun _ => do
      backupTouchedRef.set true
      return .ok { status := 200, headers := #[], body := "{\"hijack\":true}".toUTF8 })
    true none #[] (some hTracker) (some 1) (some 2009) (some "")
  let backupTouched ← backupTouchedRef.get
  if backupTouched ||
     committedPassOut.status != 200 || committedPassOut.verdictCode != 8 || !committedPassOut.firstByteCommitted ||
     committedAbortOut.verdictCode != 4 || committedAbortOut.attemptsUsed != 1 ||
     committedAbortOut.exhaustionClass != "committed_stream_aborted" ||
     committedNetAbortOut.verdictCode != 4 || committedNetAbortOut.attemptsUsed != 1 ||
     committedNetAbortOut.exhaustionClass != "committed_stream_aborted" ||
     committedRemovedPinOut.status != 502 || committedRemovedPinOut.verdictCode != 0 ||
     committedRemovedPinOut.attemptsUsed != 0 ||
     committedRemovedPinOut.exhaustionClass != "committed_stream_aborted" ||
     ((String.fromUTF8! committedRemovedPinOut.body).splitOn "committed_stream_pin_mismatch").length < 2 ||
     committedMissingPinOut.status != 502 || committedMissingPinOut.verdictCode != 0 ||
     committedMissingPinOut.attemptsUsed != 0 || committedMissingPinOut.pinnedAccountId != 0 ||
     committedMissingPinOut.exhaustionClass != "committed_stream_aborted" then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D sticky firstByteCommitted violated: backupTouched={backupTouched} passV={committedPassOut.verdictCode} abortV={committedAbortOut.verdictCode} remSt={committedRemovedPinOut.status} missSt={committedMissingPinOut.status}"
    return 1

  -- 5. Route-generation fencing: bumping `routeGeneration` (`1 -> 2`) causes stale `attemptGeneration = 1`
  -- to fail closed (`verdictCode == 0`, `attemptsUsed == 0`, HTTP 409) with zero upstream calls!
  let nextGen ← bumpRouteGeneration hTracker
  let staleCalledRef ← IO.mkRef false
  let staleGenOut ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun _ => do
      staleCalledRef.set true
      return .ok { status := 200, headers := #[], body := "{}".toUTF8 })
    false none #[] (some hTracker) (some 1) (some 2010)
  let staleCalled ← staleCalledRef.get
  if nextGen != 2 || staleCalled || staleGenOut.status != 409 ||
     staleGenOut.verdictCode != 0 || staleGenOut.attemptsUsed != 0 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D stale routeGeneration was not fenced: status={staleGenOut.status} v={staleGenOut.verdictCode}"
    return 1

  -- (B) `OrbCore.AuthSidecar.CliProxyLoginSession`: concurrent CLIProxy OAuth logins (`attemptA` vs `attemptB`)
  -- bound to `<authRoot>/attempts/<attemptNonce>/` with zero cross-attribution, plus negative tests on
  -- zero/mismatched/expired nonces and path traversal.
  let cliRoot := s!"{r4dRoot}/cliproxy"
  if (← OrbCore.AuthSidecar.beginCliProxyLogin cliRoot "openai" 0 100 200).isOk ||
     (← OrbCore.AuthSidecar.beginCliProxyLogin cliRoot "../escape" 11 100 200).isOk ||
     (← OrbCore.AuthSidecar.beginCliProxyLogin cliRoot "openai" 11 200 200).isOk then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln "[orb-core-test] FAIL: R4-D beginCliProxyLogin accepted invalid nonce/provider/expiry"
    return 1
  let .ok sessA ← OrbCore.AuthSidecar.beginCliProxyLogin cliRoot "openai" 1001 100 500
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: beginCliProxyLogin sessA failed"; return 1
  let .ok sessB ← OrbCore.AuthSidecar.beginCliProxyLogin cliRoot "openai" 2002 105 500
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: beginCliProxyLogin sessB failed"; return 1
  -- Stage distinct credentials concurrently into `sessA` and `sessB`
  let .ok stagedPathA ← OrbCore.AuthSidecar.stageCliProxyCredential sessA 1001 "openai" "{\"account\":\"alice-oauth\"}" 120
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: stageCliProxyCredential sessA failed"; return 1
  let .ok stagedPathB ← OrbCore.AuthSidecar.stageCliProxyCredential sessB 2002 "openai" "{\"account\":\"bob-oauth\"}" 121
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: stageCliProxyCredential sessB failed"; return 1
  let cliRootStat ← OrbBin.PosixExt.statPath cliRoot
  let attemptsDirStat ← OrbBin.PosixExt.statPath s!"{cliRoot}/attempts"
  let attemptADirStat ← OrbBin.PosixExt.statPath sessA.attemptDir
  let credsADirStat ← OrbBin.PosixExt.statPath s!"{sessA.attemptDir}/credentials"
  let stagedAStat ← OrbBin.PosixExt.statPath stagedPathA
  let stagedBStat ← OrbBin.PosixExt.statPath stagedPathB
  if (cliRootStat.mode &&& 0o777) != 0o700 || (attemptsDirStat.mode &&& 0o777) != 0o700 ||
     (attemptADirStat.mode &&& 0o777) != 0o700 || (credsADirStat.mode &&& 0o777) != 0o700 ||
     (stagedAStat.mode &&& 0o777) != 0o600 || (stagedBStat.mode &&& 0o777) != 0o600 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D CLIProxy staged 0700/0600 permissions violated: root={cliRootStat.mode} credA={stagedAStat.mode}"
    return 1
  -- Cross-nonce stage, read, and promote (`attemptA` presenting `2002`, `attemptB` presenting `1001`, or expired `nowEpoch = 500`) MUST fail closed!
  let crossStage ← OrbCore.AuthSidecar.stageCliProxyCredential sessA 2002 "openai" "{\"account\":\"hijack\"}" 122
  let crossRead ← OrbCore.AuthSidecar.readStagedCliProxyCredential sessA 2002 "openai"
  let crossPromote ← OrbCore.AuthSidecar.promoteCliProxyCredential sessA 2002 "openai" 130
  let expiredPromote ← OrbCore.AuthSidecar.promoteCliProxyCredential sessA 1001 "openai" 500
  let .ok readA ← OrbCore.AuthSidecar.readStagedCliProxyCredential sessA 1001 "openai"
    | do IO.FS.removeDirAll r4dRoot; return 1
  let .ok readB ← OrbCore.AuthSidecar.readStagedCliProxyCredential sessB 2002 "openai"
    | do IO.FS.removeDirAll r4dRoot; return 1
  let .ok promotedPathA ← OrbCore.AuthSidecar.promoteCliProxyCredential sessA 1001 "openai" 140
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: promoteCliProxyCredential sessA failed"; return 1
  let promotedRawA ← IO.FS.readFile promotedPathA
  let promotedDirStat ← OrbBin.PosixExt.statPath s!"{cliRoot}/promoted"
  let promotedFileStat ← OrbBin.PosixExt.statPath promotedPathA
  if (promotedDirStat.mode &&& 0o777) != 0o700 || (promotedFileStat.mode &&& 0o777) != 0o600 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D CLIProxy promoted 0700/0600 permissions violated: dir={promotedDirStat.mode} file={promotedFileStat.mode}"
    return 1
  -- After promoting `sessA`, `sessB`'s staged credential remains intact and isolated, and `sessA` cannot be replayed!
  let replayPromoteA ← OrbCore.AuthSidecar.promoteCliProxyCredential sessA 1001 "openai" 141
  let .ok readBAfter ← OrbCore.AuthSidecar.readStagedCliProxyCredential sessB 2002 "openai"
    | do IO.FS.removeDirAll r4dRoot; return 1
  if stagedPathA == stagedPathB ||
     crossStage.isOk || crossRead.isOk || crossPromote.isOk || expiredPromote.isOk || replayPromoteA.isOk ||
     readA != "{\"account\":\"alice-oauth\"}" || readB != "{\"account\":\"bob-oauth\"}" ||
     promotedRawA != "{\"account\":\"alice-oauth\"}" || readBAfter != "{\"account\":\"bob-oauth\"}" then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln "[orb-core-test] FAIL: R4-D CLIProxy concurrent nonce isolation or replay fence violated"
    return 1

  -- (C) `OrbCore.AuthSidecar`: generation-fenced OAuth rotation (`stepAuthRefreshSlice`), `R1-02`
  -- `drainPendingRotations` preserving concurrent `gen = 3` while draining `gen = 2`, `R1-03`
  -- `CoalescedAtomicWriter` keeping `dirty = true` & `dirtySeq` on `fsync`/`rename` failure, and sticky `Revoked (3)`.
  let rotDir := s!"{r4dRoot}/rotations"
  IO.FS.createDirAll rotDir
  let rot2File := s!"{rotDir}/pending-gen-2.json"
  let rot3File := s!"{rotDir}/pending-gen-3.json"
  IO.FS.writeFile rot2File "{\"gen\":2}"
  IO.FS.writeFile rot3File "{\"gen\":3}"
  let targetCredFile := s!"{rotDir}/oauth_creds.json"

  let rot0 : OrbCore.AuthSidecar.AuthRotationState := { durableAuthGeneration := 1 }
  -- Stale/non-consecutive claim or zero nonce must fail closed
  let badZeroNonceClaim := OrbCore.AuthSidecar.claimAuthRefresh rot0 0 100 300
  let .ok (rotClaimed, _) := OrbCore.AuthSidecar.claimAuthRefresh rot0 7777 100 300
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: claimAuthRefresh failed"; return 1
  -- Mismatched nonce or wrong candidate generation on stage must fail closed
  let badNonceStage := OrbCore.AuthSidecar.stageAuthRotation rotClaimed 2 9999 110 rot2File
  let badGenStage := OrbCore.AuthSidecar.stageAuthRotation rotClaimed 1 7777 110 rot2File
  let .ok (rotStaged, _) := OrbCore.AuthSidecar.stageAuthRotation rotClaimed 2 7777 110 rot2File
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: stageAuthRotation failed"; return 1
  -- Simulate concurrent next-generation rotation (`gen = 3`) staged into `pendingRotations` BEFORE `gen = 2` drains (`R1-02`)!
  let .ok rotWithConcurrentGen3 := OrbCore.AuthSidecar.recordPendingRotation rotStaged 3 rot3File
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: recordPendingRotation(gen=3) failed"; return 1
  let stalePendingReject := OrbCore.AuthSidecar.recordPendingRotation rotStaged 1 rot2File

  -- Stage coalesced payloads (`seq = 1`, coalesced to `seq = 2`) on `CoalescedAtomicWriter`
  let w0 := (OrbCore.AuthSidecar.CoalescedAtomicWriter.new targetCredFile).stage 1 "{\"tok\":\"v1\"}".toUTF8
  let wDirty := w0.stage 2 "{\"tok\":\"v2-gen2\"}".toUTF8
  -- `R1-03` negative tests:
  --   1. `fsyncConfirmed = false` or `simulateFsyncFail = true` MUST fail and keep `dirty = true`, `dirtySeq = 2`, `flushedSeq = 0`!
  --   2. `simulateRenameFail = true` MUST fail and keep `dirty = true`, `dirtySeq = 2`, `flushedSeq = 0`!
  --   3. Expired refresh lease (`nowEpoch >= leaseDeadlineEpoch`) MUST reject `commitAndDrainRotation`!
  let unconfirmedFlush ← wDirty.commit false
  let fsyncFailCommit ← OrbCore.AuthSidecar.commitAndDrainRotation rotWithConcurrentGen3 wDirty 2 120 900 (simulateFsyncFail := true)
  let renameFailCommit ← OrbCore.AuthSidecar.commitAndDrainRotation rotWithConcurrentGen3 wDirty 2 120 900 (simulateRenameFail := true)
  let expiredLeaseCommit ← OrbCore.AuthSidecar.commitAndDrainRotation rotWithConcurrentGen3 wDirty 2 300 900
  if badZeroNonceClaim.isOk || badNonceStage.isOk || badGenStage.isOk || stalePendingReject.isOk ||
     unconfirmedFlush.isOk || fsyncFailCommit.isOk || renameFailCommit.isOk || expiredLeaseCommit.isOk ||
     !wDirty.dirty || wDirty.dirtySeq != 2 || wDirty.flushedSeq != 0 ||
     (← (System.FilePath.mk targetCredFile).pathExists) then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln "[orb-core-test] FAIL: R4-D R1-03 negative commit/fsync/rename/lease fence violated"
    return 1

  -- Happy-path `commitAndDrainRotation` for `committedGen = 2`:
  --   - `wCommitted.dirty == false` and `wCommitted.flushedSeq == 2`
  --   - `rot2File` (`appliedGen = 2 <= 2`) is unlinked and drained
  --   - `rot3File` (`appliedGen = 3 > 2`) SURVIVES on disk and in `rotCommitted.pendingRotations` (`R1-02`)!
  let .ok (rotCommitted, wCommitted, drainedPaths, _) ←
      OrbCore.AuthSidecar.commitAndDrainRotation rotWithConcurrentGen3 wDirty 2 150 900
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: commitAndDrainRotation happy path failed"; return 1
  let diskCreds ← IO.FS.readFile targetCredFile
  let targetCredStat ← OrbBin.PosixExt.statPath targetCredFile
  let rotDirStat ← OrbBin.PosixExt.statPath rotDir
  let rot2Exists ← (System.FilePath.mk rot2File).pathExists
  let rot3Exists ← (System.FilePath.mk rot3File).pathExists
  if rotCommitted.phaseCode != 0 || rotCommitted.durableAuthGeneration != 2 || rotCommitted.dirtyPending != 0 ||
     wCommitted.dirty || wCommitted.flushedSeq != 2 || diskCreds != "{\"tok\":\"v2-gen2\"}" ||
     (targetCredStat.mode &&& 0o777) != 0o600 || (rotDirStat.mode &&& 0o777) != 0o700 ||
     drainedPaths != #[rot2File] || rot2Exists || !rot3Exists ||
     rotCommitted.pendingRotations.size != 1 || rotCommitted.pendingRotations[0]!.appliedGen != 3 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: R4-D R1-02/R1-03 commitAndDrainRotation invariant violated: pending={rotCommitted.pendingRotations.size} rot2={rot2Exists} rot3={rot3Exists}"
    return 1

  -- Transient abort (`RefreshClaimed -> Valid`) retains `dirtyPending` without rewinding generation,
  -- and `revokeAuthCredential` transitions to sticky `Revoked (3)` where subsequent `claimAuthRefresh` fails closed!
  let .ok (rotGen3Claim, _) := OrbCore.AuthSidecar.claimAuthRefresh rotCommitted 8888 200 500
    | do IO.FS.removeDirAll r4dRoot; return 1
  let .ok (rotAborted, _) := OrbCore.AuthSidecar.abortAuthRefreshTransient rotGen3Claim 3 210
    | do IO.FS.removeDirAll r4dRoot; return 1
  let .ok (rotRevoked, _) := OrbCore.AuthSidecar.revokeAuthCredential rotAborted 3 220
    | do IO.FS.removeDirAll r4dRoot; return 1
  let claimAfterRevoke := OrbCore.AuthSidecar.claimAuthRefresh rotRevoked 9999 230 600
  let revokeAgain := OrbCore.AuthSidecar.revokeAuthCredential rotRevoked 3 231
  if rotAborted.phaseCode != 0 || rotAborted.durableAuthGeneration != 3 ||
     rotRevoked.phaseCode != 3 || claimAfterRevoke.isOk || revokeAgain.isOk then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln "[orb-core-test] FAIL: R4-D transient abort or sticky Revoked (3) invariant violated"
    return 1
  return 0

private def runR4dProxyAuthTests (prodValid : CoreConfig) : IO UInt32 := do
  let r4dPid ← IO.monoNanosNow
  let r4dRoot := s!"/tmp/orb-core-r4d-{r4dPid}"
  IO.FS.createDirAll r4dRoot
  let r4dChain : RoutingChain := {
    id := "r4d-chain", name := "r4d-chain",
    targets := #[
      { accountId := "acct-primary", provider := "openai", baseUrl := "https://api.openai.com/v1", apiKey := "k-prim", modelId := "gpt-6" },
      { accountId := "acct-backup", provider := "openai", baseUrl := "https://api.openai.com/v1", apiKey := "k-bak", modelId := "gpt-6" }
    ]
  }
  if (← runR4dUnitTests r4dRoot r4dChain) != 0 then
    return 1
  let .ok store ← openCoreStore s!"{r4dRoot}/store"
    | do IO.FS.removeDirAll r4dRoot; IO.eprintln "[orb-core-test] FAIL: openCoreStore for R4-D failed"; return 1
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : ManagedFleetState)
  let nowSec : UInt64 := 1700001000

  -- (D) End-to-end `dispatchCoreRequest` (`SM-21`):
  --   1. first-target `503` pre-commit failover
  --   2. post-first-byte sticky pin (no silent account switch)
  --   3. breaker threshold 2 holds across one transient failure
  --   4. authenticated CLIProxy login nonce isolation via `/api/control/auth/cliproxy/*`
  --   5. lost/older generation drain does not unlink a newer staged file
  let chainsRef2 ← IO.mkRef #[r4dChain]
  let coolRef2 ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef2 ← IO.mkRef (1 : UInt64)
  let hLive ← newProviderHealthTracker 1 2
  let mockTransport : ProviderTarget → IO (Except String HttpsResponse) := fun tgt => do
    if tgt.accountId == "acct-primary" then
      return .ok { status := 503, headers := #[], body := "{\"error\":\"overloaded\"}".toUTF8 }
    else
      return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"ok\":true}".toUTF8 }
  let authRoot2 := s!"{r4dRoot}/live-auth"
  IO.FS.createDirAll authRoot2
  let rotH ← OrbCore.AuthSidecar.newAuthRotationHandle s!"{authRoot2}/oauth_credentials.json"
  let sessRef ← IO.mkRef (#[] : Array OrbCore.AuthSidecar.CliProxyLoginSession)
  let appLive : CoreAppState := {
    cfg := { prodValid with workingDir := r4dRoot }
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef2
    proxyCooldownsRef := coolRef2
    seqRef := seqRef2
    pacingTracker? := some hLive.pacing
    healthTracker? := some hLive
    proxyMockTransport? := some mockTransport
    authRoot := authRoot2
    authRotation? := some rotH
    cliProxySessionsRef? := some sessRef
  }
  let bearer := s!"Authorization: Bearer {prodValid.proxySecret}"
  let jwt := mintSessionToken prodValid.jwtSecret (nowSec + 3600)
  let jwtH := s!"Authorization: Bearer {jwt}"
  let postV1 (extraHdrs body : String) (atEp : UInt64) : IO (Except String (Nat × String × Array (String × String))) := do
    let raw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{bearer}\r\nContent-Type: application/json\r\n{extraHdrs}Content-Length: {body.utf8ByteSize}\r\n\r\n{body}".toUTF8
    let .ok req := parseRequest raw none | return .error "parse_v1"
    let .ok resp ← dispatchCoreRequest appLive req atEp | return .error "dispatch_v1"
    return .ok (resp.status, String.fromUTF8! resp.body, resp.extraHdrs)
  let hdr (hs : Array (String × String)) (k : String) : String :=
    (hs.find? (fun p => p.1.toLower == k.toLower)).map Prod.snd |>.getD ""
  let .ok (s1, b1, h1) ← postV1 "" "{}" 1000 | return 1
  let primAfterOne ← lookupAccountHealthRecord hLive "acct-primary"
  let hPin ← newProviderHealthTracker 1 2
  let pinMock : ProviderTarget → IO (Except String HttpsResponse) := fun tgt => do
    if tgt.accountId == "acct-primary" then
      return .ok { status := 503, headers := #[], body := "{\"error\":\"mid_stream\"}".toUTF8 }
    else
      return .ok { status := 200, headers := #[], body := "{\"hijack\":true}".toUTF8 }
  let appPin : CoreAppState := { appLive with healthTracker? := some hPin, proxyMockTransport? := some pinMock }
  let pinRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{bearer}\r\nContent-Type: application/json\r\nX-Orb-First-Byte-Committed: 1\r\nX-Orb-Pinned-Account: acct-primary\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok pinReq := parseRequest pinRaw none | return 1
  let .ok pinResp ← dispatchCoreRequest appPin pinReq 1005 | return 1
  let h2 := pinResp.extraHdrs
  let s2 := pinResp.status
  let primPin ← lookupAccountHealthRecord hPin "acct-primary"
  let .ok (s3, _, h3) ← postV1 "" "{}" 1010 | return 1
  let primTripped ← lookupAccountHealthRecord hLive "acct-primary"
  let planHeld ← planChainFromHealth hLive r4dChain 1010
  if s1 != 200 || hdr h1 "X-Orb-Selected-Account" != "acct-backup" ||
     hdr h1 "X-Orb-Attempts-Used" != "2" ||
     !b1.contains 'o' ||
     s2 != 503 || hdr h2 "X-Orb-Selected-Account" != "acct-primary" ||
     hdr h2 "X-Orb-Attempts-Used" != "1" ||
     hdr h2 "X-Orb-Verdict-Code" != "4" ||
     primPin.cooldown?.isSome ||
     primAfterOne.transientStreak != 1 || primAfterOne.cooldown?.isSome ||
     s3 != 200 || hdr h3 "X-Orb-Selected-Account" != "acct-backup" ||
     hdr h3 "X-Orb-Attempts-Used" != "2" ||
     primTripped.cooldown?.isNone || planHeld.eligible.size != 1 ||
     planHeld.eligible[0]!.accountId != "acct-backup" then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: dispatchCoreRequest proxy failover/pin/threshold: {s1}/{s2}/{s3} streak1={primAfterOne.transientStreak}"
    return 1
  let missPinRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{bearer}\r\nContent-Type: application/json\r\nX-Orb-First-Byte-Committed: 1\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok missPinReq := parseRequest missPinRaw none | return 1
  let .ok missPinResp ← dispatchCoreRequest appPin missPinReq 1006 | return 1
  let gonePinRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{bearer}\r\nContent-Type: application/json\r\nX-Orb-First-Byte-Committed: 1\r\nX-Orb-Pinned-Account: acct-removed\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok gonePinReq := parseRequest gonePinRaw none | return 1
  let .ok gonePinResp ← dispatchCoreRequest appPin gonePinReq 1007 | return 1
  if missPinResp.status != 502 || hdr missPinResp.extraHdrs "X-Orb-Verdict-Code" != "0" ||
     hdr missPinResp.extraHdrs "X-Orb-Attempts-Used" != "0" ||
     hdr missPinResp.extraHdrs "X-Orb-Selected-Account" != "" ||
     !(String.fromUTF8! missPinResp.body).contains 'm' ||
     gonePinResp.status != 502 || hdr gonePinResp.extraHdrs "X-Orb-Verdict-Code" != "0" ||
     hdr gonePinResp.extraHdrs "X-Orb-Attempts-Used" != "0" ||
     hdr gonePinResp.extraHdrs "X-Orb-Selected-Account" != "" ||
     !((String.fromUTF8! gonePinResp.body).splitOn "committed_stream_pin_mismatch").length > 1 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: HTTP committed pin fail-closed: miss={missPinResp.status} gone={gonePinResp.status}"
    return 1
  let postCtl (path body : String) (atEp : UInt64) : IO (Nat × String) := do
    let raw := s!"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{jwtH}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}".toUTF8
    let .ok req := parseRequest raw none | return (0, "parse")
    match ← dispatchCoreRequest appLive req atEp with
    | .error _ => return (0, "ws")
    | .ok resp => return (resp.status, String.fromUTF8! resp.body)
  let unauthSt ← do
    let raw := "POST /api/control/auth/cliproxy/login HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}".toUTF8
    match parseRequest raw none with
    | .error _ => pure 0
    | .ok req =>
      match ← dispatchCoreRequest appLive req 120 with
      | .ok resp => pure resp.status
      | .error _ => pure 0
  let (la, ba) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"openai\",\"attempt_nonce\":1001,\"expires_at\":500}" 120
  let (lb, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"openai\",\"attempt_nonce\":2002,\"expires_at\":500}" 121
  let (lCross, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"anthropic\",\"attempt_nonce\":1001,\"expires_at\":500}" 122
  let heldAfterCross ← sessRef.get
  let (sa, _) ← postCtl "/api/control/auth/cliproxy/stage" "{\"session_nonce\":1001,\"presented_nonce\":1001,\"provider\":\"openai\",\"credential_json\":\"{\\\"account\\\":\\\"alice-oauth\\\"}\"}" 130
  let (sb, _) ← postCtl "/api/control/auth/cliproxy/stage" "{\"session_nonce\":2002,\"presented_nonce\":2002,\"provider\":\"openai\",\"credential_json\":\"{\\\"account\\\":\\\"bob-oauth\\\"}\"}" 131
  let (sx, bx) ← postCtl "/api/control/auth/cliproxy/stage" "{\"session_nonce\":1001,\"presented_nonce\":2002,\"provider\":\"openai\",\"credential_json\":\"{\\\"account\\\":\\\"hijack\\\"}\"}" 132
  let readRaw := s!"GET /api/control/auth/cliproxy/staged?session_nonce=1001&presented_nonce=1001&provider=openai HTTP/1.1\r\nHost: 127.0.0.1\r\n{jwtH}\r\n\r\n".toUTF8
  let .ok readReq := parseRequest readRaw none | return 1
  let .ok readResp ← dispatchCoreRequest appLive readReq 130 | return 1
  let readBody := String.fromUTF8! readResp.body
  if unauthSt != 401 || la != 201 || lb != 201 || lCross != 409 ||
     heldAfterCross.any (fun s => s.attemptNonce == 1001 && s.provider == "anthropic") ||
     sa != 200 || sb != 200 || sx == 200 ||
     !(ba.splitOn "attempts/1001").length > 1 ||
     readResp.status != 200 || (readBody.splitOn "alice-oauth").length < 2 ||
     (readBody.splitOn "bob-oauth").length > 1 then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: control CLIProxy nonce isolation: unauth={unauthSt} cross={lCross} stageX={sx} bodyX={bx}"
    return 1
  let (gPreClaim, _) ← postCtl "/api/control/auth/rotation/stage" "{\"candidate_gen\":2,\"presented_nonce\":7777,\"record_name\":\"preclaim-stage.json\",\"payload_json\":\"{\\\"tok\\\":\\\"preclaim\\\"}\",\"seq\":7}" 139
  let rotDirPre ← (System.FilePath.mk s!"{authRoot2}/rotations").pathExists
  let (gTrav, _) ← postCtl "/api/control/auth/rotation/stage" "{\"candidate_gen\":2,\"presented_nonce\":7777,\"record_name\":\"../escape.json\",\"payload_json\":\"{\\\"tok\\\":\\\"x\\\"}\"}" 161
  let (gSlash, _) ← postCtl "/api/control/auth/rotation/stage" "{\"candidate_gen\":2,\"presented_nonce\":7777,\"record_name\":\"a/b.json\",\"payload_json\":\"{\\\"tok\\\":\\\"x\\\"}\"}" 162
  let travExists ← (System.FilePath.mk s!"{authRoot2}/escape.json").pathExists
  let ledAfterTrav ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  if gPreClaim != 409 || rotDirPre || gTrav != 400 || gSlash != 400 || travExists || ledAfterTrav.writer.dirty then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: rotation preclaim/traversal wrote disk or dirtied writer: pre={gPreClaim} rotDir={rotDirPre} trav={gTrav} slash={gSlash} exists={travExists} dirty={ledAfterTrav.writer.dirty}"
    return 1
  let (pStale, _) ← postCtl "/api/control/auth/rotation/record-pending" "{\"applied_gen\":0,\"record_name\":\"stale.json\",\"payload_json\":\"{\\\"tok\\\":\\\"stale\\\"}\",\"coalesce_writer\":true,\"seq\":9}" 163
  let staleFile ← (System.FilePath.mk s!"{authRoot2}/rotations/stale.json").pathExists
  let ledAfterStale ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  if pStale != 409 || staleFile || ledAfterStale.writer.dirty || ledAfterStale.writer.dirtySeq != 0 then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: rejected record-pending mutated disk or writer: status={pStale} file={staleFile} dirtySeq={ledAfterStale.writer.dirtySeq}"
    return 1
  let (cSt, _) ← postCtl "/api/control/auth/rotation/claim" "{\"attempt_nonce\":7777,\"lease_deadline\":900}" 150
  let (gSt, _) ← postCtl "/api/control/auth/rotation/stage" "{\"candidate_gen\":2,\"presented_nonce\":7777,\"record_name\":\"pending-gen-2.json\",\"payload_json\":\"{\\\"tok\\\":\\\"v2\\\"}\",\"seq\":2}" 160
  let (gBadNonce, _) ← postCtl "/api/control/auth/rotation/stage" "{\"candidate_gen\":2,\"presented_nonce\":9999,\"record_name\":\"bad-nonce-stage.json\",\"payload_json\":\"{\\\"tok\\\":\\\"bad\\\"}\",\"seq\":99}" 164
  let badNonceFile ← (System.FilePath.mk s!"{authRoot2}/rotations/bad-nonce-stage.json").pathExists
  let ledAfterBadStage ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  if gBadNonce != 409 || badNonceFile || ledAfterBadStage.writer.dirtySeq != 2 then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: rejected stage mutated disk or writer: status={gBadNonce} file={badNonceFile} dirtySeq={ledAfterBadStage.writer.dirtySeq}"
    return 1
  let (pSt, _) ← postCtl "/api/control/auth/rotation/record-pending" "{\"applied_gen\":3,\"record_name\":\"pending-gen-3.json\",\"payload_json\":\"{\\\"tok\\\":\\\"v3\\\"}\",\"coalesce_writer\":true,\"seq\":3}" 170
  let snapBeforeRace ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  let _ ← OrbCore.AuthSidecar.stageRotationNext rotH "{\"tok\":\"v3-next\"}".toUTF8
  let postSnapMismatch ← OrbCore.AuthSidecar.commitAndDrainRotation
    snapBeforeRace.rotation snapBeforeRace.writer 2 174 900 false false (some rotH)
  let ledAfterPostSnap ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  let postSnapErr := match postSnapMismatch with | .error e => e | .ok _ => "ok"
  if postSnapErr != "concurrent_stage_generation_mismatch" ||
     ledAfterPostSnap.rotation.phaseCode != 2 || !ledAfterPostSnap.writer.dirty ||
     ledAfterPostSnap.writer.dirtySeq != 4 then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: commitAndDrainRotation post-snapshot stageNext mismatch: err={postSnapErr} phase={ledAfterPostSnap.rotation.phaseCode} seq={ledAfterPostSnap.writer.dirtySeq}"
    return 1
  let (staleCommitSt, _) ← postCtl "/api/control/auth/rotation/commit" "{\"candidate_gen\":2,\"new_expiry\":900,\"expected_seq\":2}" 175
  let gen2BeforeDrain ← (System.FilePath.mk s!"{authRoot2}/rotations/pending-gen-2.json").pathExists
  let ledStale ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  -- BLOCK-3a: HTTP `/api/control/auth/rotation/commit` must ignore caller-supplied `simulate_fsync_fail` /
  -- `simulate_rename_fail` fault-injection fields and commit normally (`200`), never leaving `PendingFsync` wedged.
  let (kSt, kb) ← postCtl "/api/control/auth/rotation/commit" "{\"candidate_gen\":2,\"new_expiry\":900,\"simulate_fsync_fail\":true,\"simulate_rename_fail\":true}" 180
  let liveOauthStat ← OrbBin.PosixExt.statPath s!"{authRoot2}/oauth_credentials.json"
  let liveRotDirStat ← OrbBin.PosixExt.statPath s!"{authRoot2}/rotations"
  let liveGen3Stat ← OrbBin.PosixExt.statPath s!"{authRoot2}/rotations/pending-gen-3.json"
  if (liveOauthStat.mode &&& 0o777) != 0o600 || (liveRotDirStat.mode &&& 0o777) != 0o700 ||
     (liveGen3Stat.mode &&& 0o777) != 0o600 then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: live rotation 0700/0600 permissions violated: oauth={liveOauthStat.mode} rotDir={liveRotDirStat.mode} gen3={liveGen3Stat.mode}"
    return 1
  let (pStaleAfterGen2, _) ← postCtl "/api/control/auth/rotation/record-pending" "{\"applied_gen\":1,\"record_name\":\"stale-gen1.json\",\"payload_json\":\"{\\\"tok\\\":\\\"stale1\\\"}\",\"coalesce_writer\":true,\"seq\":99}" 181
  let staleGen1File ← (System.FilePath.mk s!"{authRoot2}/rotations/stale-gen1.json").pathExists
  let gen2AfterDrain ← (System.FilePath.mk s!"{authRoot2}/rotations/pending-gen-2.json").pathExists
  let gen3Exists ← (System.FilePath.mk s!"{authRoot2}/rotations/pending-gen-3.json").pathExists
  let ledAfter ← OrbCore.AuthSidecar.snapshotRotationLedger rotH
  let .ok kbVal := OrbBin.Json.parse kb | do IO.FS.removeDirAll r4dRoot; return 1
  let drainedArr := (kbVal.fieldArr? "drained_paths").getD #[]
  if cSt != 200 || gSt != 200 || pSt != 200 || staleCommitSt != 409 || !gen2BeforeDrain ||
     !ledStale.writer.dirty || ledStale.writer.dirtySeq != 4 ||
     kSt != 200 || pStaleAfterGen2 != 409 || staleGen1File || gen2AfterDrain || !gen3Exists ||
     ledAfter.writer.dirty || ledAfter.writer.flushedSeq != 4 ||
     ledAfter.rotation.pendingRotations.size != 1 ||
     ledAfter.rotation.pendingRotations[0]!.appliedGen != 3 ||
     drainedArr.size != 1 ||
     drainedArr.any (fun v => ((v.asStr?).getD "").endsWith "pending-gen-3.json") then
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: control rotation generation fence: claim={cSt} stage={gSt} pend={pSt} stale={staleCommitSt} commit={kSt} gen2={gen2AfterDrain} gen3={gen3Exists}"
    return 1
  let wideTargets := (List.range 20).toArray.map fun i =>
    ({ accountId := s!"acct-{i}", provider := "openai", baseUrl := "https://api.openai.com/v1",
       apiKey := "k", modelId := "gpt-6" } : ProviderTarget)
  let wideChain : RoutingChain := { id := "wide", name := "wide", targets := wideTargets }
  let widePlan := planChain wideChain #[] 1000
  let zeroFailover := canFailoverUpstream 0 20 503 false
  let lastLegal := canFailoverUpstream 14 16 503 false
  let pastCap := canFailoverUpstream 15 16 503 false
  let callsRef ← IO.mkRef (0 : Nat)
  let wideOut ← forwardProxyChain wideChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun _ => do
      callsRef.modify (· + 1)
      return .ok { status := 503, headers := #[], body := "{\"error\":\"down\"}".toUTF8 })
    false none #[] none none (some 1000)
  let calls ← callsRef.get
  if widePlan.eligible.size != 16 || !zeroFailover || !lastLegal || pastCap || calls != 16 || wideOut.attemptsUsed != 16 then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: proxy chain cap: eligible={widePlan.eligible.size} calls={calls} z={zeroFailover} last={lastLegal} past={pastCap}"
    return 1
  let genBeforeWrite ← currentRouteGeneration hLive
  let provBody := "{\"id\":\"prov-r4d\",\"provider_type\":\"custom\",\"name\":\"r4d\",\"base_url\":\"https://example.invalid/v1\",\"api_key\":\"sk-r4d-secret-value\",\"rpm_limit\":10}"
  let (provSt, _) ← postCtl "/api/ai/providers" provBody 190
  let genAfterWrite ← currentRouteGeneration hLive
  chainsRef2.set #[r4dChain]
  let snapGen ← currentRouteGeneration hLive
  let bumpTask ← IO.asTask (prio := .dedicated) do
    IO.sleep 30
    discard <| bumpRouteGeneration hLive
  let racedMock : ProviderTarget → IO (Except String HttpsResponse) := fun _ => do
    let _ ← IO.wait bumpTask
    return .ok { status := 200, headers := #[], body := "{\"ok\":true}".toUTF8 }
  let appRace : CoreAppState := { appLive with proxyMockTransport? := some racedMock }
  let raceRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{bearer}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok raceReq := parseRequest raceRaw none | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let .ok raceResp ← dispatchCoreRequest appRace raceReq 191 | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let genAfterRace ← currentRouteGeneration hLive
  if provSt != 201 || genAfterWrite <= genBeforeWrite || raceResp.status != 409 ||
     genAfterRace <= snapGen ||
     ((String.fromUTF8! raceResp.body).splitOn "stale_route_generation").length < 2 then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: route generation fence: prov={provSt} before={genBeforeWrite} after={genAfterWrite} race={raceResp.status} snap={snapGen} now={genAfterRace}"
    return 1
  sessRef.set #[]
  let mut loginN : Nat := 0
  let mut lastLogin := 0
  while loginN < maxCliProxyLoginSessions do
    let nonce := 3000 + loginN
    let (stL, _) ← postCtl "/api/control/auth/cliproxy/login" s!"\{\"provider\":\"openai\",\"attempt_nonce\":{nonce},\"expires_at\":900}" 200
    lastLogin := stL
    if stL != 201 then break
    loginN := loginN + 1
  let (overSt, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"openai\",\"attempt_nonce\":9999,\"expires_at\":900}" 210
  let held ← sessRef.get
  let (preStageSt, _) ← postCtl "/api/control/auth/cliproxy/stage" "{\"session_nonce\":3000,\"presented_nonce\":3000,\"provider\":\"openai\",\"credential_json\":\"{\\\"account\\\":\\\"cap-user\\\"}\"}" 215
  let (reuseCrossAtCap, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"anthropic\",\"attempt_nonce\":3000,\"expires_at\":950}" 218
  let (reuseSt, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"openai\",\"attempt_nonce\":3000,\"expires_at\":950}" 220
  let readAfterRefreshRaw := s!"GET /api/control/auth/cliproxy/staged?session_nonce=3000&presented_nonce=3000&provider=openai HTTP/1.1\r\nHost: 127.0.0.1\r\n{jwtH}\r\n\r\n".toUTF8
  let .ok readAfterRefreshReq := parseRequest readAfterRefreshRaw none | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let .ok readAfterRefreshResp ← dispatchCoreRequest appLive readAfterRefreshReq 221 | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let (promotedOkSt, _) ← postCtl "/api/control/auth/cliproxy/promote" "{\"session_nonce\":3000,\"presented_nonce\":3000,\"provider\":\"openai\"}" 222
  let (freedSlotSt, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"openai\",\"attempt_nonce\":8888,\"expires_at\":950}" 225
  let (afterExpirySt, _) ← postCtl "/api/control/auth/cliproxy/login" "{\"provider\":\"openai\",\"attempt_nonce\":7770,\"expires_at\":1200}" 920
  let heldAfterExpiry ← sessRef.get
  if loginN != maxCliProxyLoginSessions || lastLogin != 201 || overSt != 429 ||
     held.size != maxCliProxyLoginSessions || preStageSt != 200 ||
     reuseCrossAtCap != 409 || reuseSt != 201 ||
     readAfterRefreshResp.status != 200 ||
     ((String.fromUTF8! readAfterRefreshResp.body).splitOn "cap-user").length < 2 ||
     promotedOkSt != 200 || freedSlotSt != 201 ||
     afterExpirySt != 201 || heldAfterExpiry.size != 2 ||
     held.any (fun s => s.attemptNonce == 9999) ||
     !heldAfterExpiry.any (fun s => s.attemptNonce == 8888) ||
     !heldAfterExpiry.any (fun s => s.attemptNonce == 7770) then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: CLIProxy session cap/prune: n={loginN} over={overSt} held={held.size} cross={reuseCrossAtCap} reuse={reuseSt} read={readAfterRefreshResp.status} prom={promotedOkSt} freed={freedSlotSt} exp={afterExpirySt} after={heldAfterExpiry.size}"
    return 1
  -- BLOCK-1: Concurrent sibling cooldown race on `[acct-primary, acct-backup]`:
  -- R1 and R2 are both admitted before `acct-primary` cools down. R1 gets `429` and installs a live
  -- cooldown on `acct-primary` while R2 is already in flight on `acct-primary`:
  --   (a) R2 receiving `200` on `acct-primary` MUST return `200` (never `409 stale_route_generation`).
  --   (b) R2 receiving pre-commit `503` on `acct-primary` MUST fail over cleanly to `acct-backup` (`200`, never `409`).
  let hSibA ← newProviderHealthTracker 1 2
  let r1TaskA ← IO.asTask (prio := .dedicated) do
    IO.sleep 25
    forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
      (some fun tgt => do
        if tgt.accountId == "acct-primary" then
          return .ok { status := 429, headers := #[("Retry-After", "60")], body := "{\"error\":\"rate_limit\"}".toUTF8 }
        else
          return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"r1\":true}".toUTF8 })
      false none #[] (some hSibA) (some 1) (some 3000)
  let r2Out200 ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-primary" then
        let _ ← IO.wait r1TaskA
        return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"r2\":200}".toUTF8 }
      else
        return .ok { status := 200, headers := #[], body := "{\"unexpected\":true}".toUTF8 })
    false none #[] (some hSibA) (some 1) (some 3000)
  let r1OutA ← IO.ofExcept r1TaskA.get
  let hSibB ← newProviderHealthTracker 1 2
  let r1TaskB ← IO.asTask (prio := .dedicated) do
    IO.sleep 25
    forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
      (some fun tgt => do
        if tgt.accountId == "acct-primary" then
          return .ok { status := 429, headers := #[("Retry-After", "60")], body := "{\"error\":\"rate_limit\"}".toUTF8 }
        else
          return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"r1\":true}".toUTF8 })
      false none #[] (some hSibB) (some 1) (some 3010)
  let r2Out503 ← forwardProxyChain r4dChain "POST" "/v1/responses" #[] "{}".toUTF8
    (some fun tgt => do
      if tgt.accountId == "acct-primary" then
        let _ ← IO.wait r1TaskB
        return .ok { status := 503, headers := #[], body := "{\"error\":\"overloaded\"}".toUTF8 }
      else
        return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"r2\":\"failover\"}".toUTF8 })
    false none #[] (some hSibB) (some 1) (some 3010)
  let r1OutB ← IO.ofExcept r1TaskB.get
  let primSibB ← lookupAccountHealthRecord hSibB "acct-primary"
  if r1OutA.status != 200 || r1OutA.selectedAccount != "acct-backup" ||
     r2Out200.status != 200 || r2Out200.selectedAccount != "acct-primary" || r2Out200.verdictCode != 1 ||
     r1OutB.status != 200 || r1OutB.selectedAccount != "acct-backup" ||
     r2Out503.status != 200 || r2Out503.selectedAccount != "acct-backup" || r2Out503.attemptsUsed != 2 ||
     primSibB.cooldown?.isNone then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: BLOCK-1 sibling cooldown race: r2_200={r2Out200.status}/{r2Out200.selectedAccount} r2_503={r2Out503.status}/{r2Out503.selectedAccount}/{r2Out503.attemptsUsed}"
    return 1

  -- BLOCK-3b: Dashboard-JWT caller (when `proxySecret` is unset) sending `X-Orb-First-Byte-Committed: 1`
  -- and `X-Orb-Pinned-Account` MUST be treated as a fresh unpinned request (cooldown gate applies, no pin).
  let freshSlice0 : Orb.HarnessCloud.ProviderAttemptSliceState := {
    firstByteCommitted := 0, pinnedAccountId := 0, attemptsUsed := 0,
    transientStreak := 0, routeGeneration := 1, cooldownUntilEpoch := 0
  }
  let hJwtProxy ← newProviderHealthTracker 1 2
  let _ ← recordHealthAttempt hJwtProxy freshSlice0 "acct-primary" 429 #[("Retry-After", "120")] "{\"error\":\"rate_limit\"}" false 1 1 (nowSec - 1)
  let _ ← recordHealthAttempt hJwtProxy freshSlice0 "acct-backup" 429 #[("Retry-After", "120")] "{\"error\":\"rate_limit\"}" false 1 1 (nowSec - 1)
  let jwtUpstreamCalled ← IO.mkRef false
  let appJwtNoSecret : CoreAppState := {
    appLive with
    cfg := { appLive.cfg with proxySecret := "" }
    proxyCooldownsRef := (← IO.mkRef #[])
    healthTracker? := some hJwtProxy
    proxyMockTransport? := some (fun _ => do
      jwtUpstreamCalled.set true
      return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := "{\"bypassed\":true}".toUTF8 })
  }
  let jwtSpoofRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{jwtH}\r\nContent-Type: application/json\r\nX-Orb-First-Byte-Committed: 1\r\nX-Orb-Pinned-Account: acct-primary\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok jwtSpoofReq := parseRequest jwtSpoofRaw none | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let .ok jwtSpoofResp ← dispatchCoreRequest appJwtNoSecret jwtSpoofReq nowSec | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let jwtCalled1 ← jwtUpstreamCalled.get
  let hJwtPin ← newProviderHealthTracker 1 2
  let _ ← recordHealthAttempt hJwtPin freshSlice0 "acct-primary" 429 #[("Retry-After", "120")] "{\"error\":\"rate_limit\"}" false 1 1 (nowSec - 1)
  let appJwtPin : CoreAppState := {
    appLive with
    cfg := { appLive.cfg with proxySecret := "" }
    proxyCooldownsRef := (← IO.mkRef #[])
    healthTracker? := some hJwtPin
    proxyMockTransport? := some (fun tgt => do
      return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := s!"\{\"acct\":\"{tgt.accountId}\"}".toUTF8 })
  }
  let .ok jwtUnpinnedResp ← dispatchCoreRequest appJwtPin jwtSpoofReq nowSec | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let hJwtPinOrder ← newProviderHealthTracker 1 2
  let appJwtPinOrder : CoreAppState := {
    appLive with
    cfg := { appLive.cfg with proxySecret := "" }
    proxyCooldownsRef := (← IO.mkRef #[])
    healthTracker? := some hJwtPinOrder
    proxyMockTransport? := some (fun tgt => do
      return .ok { status := 200, headers := #[("Content-Type", "application/json")], body := s!"\{\"acct\":\"{tgt.accountId}\"}".toUTF8 })
  }
  let jwtSpoofBackupRaw := s!"POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n{jwtH}\r\nContent-Type: application/json\r\nX-Orb-First-Byte-Committed: 1\r\nX-Orb-Pinned-Account: acct-backup\r\nContent-Length: 2\r\n\r\n\{}".toUTF8
  let .ok jwtSpoofBackupReq := parseRequest jwtSpoofBackupRaw none | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  let .ok jwtSpoofBackupResp ← dispatchCoreRequest appJwtPinOrder jwtSpoofBackupReq nowSec | do closeCoreStore store; IO.FS.removeDirAll r4dRoot; return 1
  if jwtCalled1 || jwtSpoofResp.status != 429 ||
     jwtUnpinnedResp.status != 200 ||
     hdr jwtUnpinnedResp.extraHdrs "X-Orb-Selected-Account" != "acct-backup" ||
     hdr jwtUnpinnedResp.extraHdrs "X-Orb-Verdict-Code" != "1" ||
     jwtSpoofBackupResp.status != 200 ||
     hdr jwtSpoofBackupResp.extraHdrs "X-Orb-Selected-Account" != "acct-primary" ||
     hdr jwtSpoofBackupResp.extraHdrs "X-Orb-Verdict-Code" != "1" then
    closeCoreStore store
    IO.FS.removeDirAll r4dRoot
    IO.eprintln s!"[orb-core-test] FAIL: BLOCK-3b dashboard JWT spoofed committed/pin headers: coolSt={jwtSpoofResp.status} called={jwtCalled1} unpinSt={jwtUnpinnedResp.status} acct={hdr jwtUnpinnedResp.extraHdrs "X-Orb-Selected-Account"} ordAcct={hdr jwtSpoofBackupResp.extraHdrs "X-Orb-Selected-Account"}"
    return 1

  closeCoreStore store
  IO.FS.removeDirAll r4dRoot
  return 0

private def runOrbUriCorsTests : IO UInt32 := do
  if !OrbCore.Control.isAllowedCorsOrigin true "orb://localhost" ||
     !OrbCore.Control.isAllowedCorsOrigin false "orb://localhost" ||
     !OrbCore.Control.isAllowedCorsOrigin true "tauri://localhost" ||
     OrbCore.Control.isAllowedCorsOrigin true "orb://evil.example" ||
     OrbCore.Control.isAllowedCorsOrigin false "orb://evil.example" then
    IO.eprintln "[orb-core-test] FAIL: orb://localhost CORS origin confinement mismatch"
    return 1
  return 0

private def runWarmClaudeControlAndCheckpointsCoreTests (prodValid : CoreConfig) : IO UInt32 := do
  let ts ← IO.monoNanosNow
  let rawRoot := s!"/tmp/orb-core-warm-claude-{ts}"
  IO.FS.createDirAll rawRoot
  let realRootFp ← IO.FS.realPath (System.FilePath.mk rawRoot)
  let root := realRootFp.toString
  let repoFp := realRootFp / "repo"
  IO.FS.createDirAll repoFp
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoFp.toString, "init", "-b", "main"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoFp.toString, "config", "user.email", "core@orb.local"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoFp.toString, "config", "user.name", "Orb Core"] }
  IO.FS.writeFile (repoFp / "tracked.txt") "initial\n"
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoFp.toString, "add", "tracked.txt"] }
  let _ ← IO.Process.output { cmd := "git", args := #["-C", repoFp.toString, "commit", "-m", "init"] }

  let mockClaudeFp := realRootFp / "mock-claude-core.py"
  IO.FS.writeFile mockClaudeFp (
    "#!/usr/bin/env python3\n" ++
    "import sys, json\n" ++
    "for raw in sys.stdin:\n" ++
    "    line = raw.strip()\n" ++
    "    if not line: continue\n" ++
    "    msg = json.loads(line)\n" ++
    "    if msg.get('type') == 'control_request' and msg.get('request', {}).get('subtype') == 'initialize':\n" ++
    "        print(json.dumps({'type':'system','subtype':'init','session_id':'core-sid-1'}), flush=True)\n" ++
    "    elif msg.get('type') == 'user':\n" ++
    "        print(json.dumps({'type':'control_request','request_id':'core-perm-1','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'ls'}}}), flush=True)\n" ++
    "    elif msg.get('type') == 'control_response':\n" ++
    "        with open('tracked.txt', 'w') as f: f.write('updated-by-core\\n')\n" ++
    "        print(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':'Core warm reply'}]}}), flush=True)\n" ++
    "        print(json.dumps({'type':'result','num_turns':1,'is_error':False,'result':'Core warm reply','session_id':'core-sid-1'}), flush=True)\n"
  )
  let _ ← OrbBin.PosixExt.chmod mockClaudeFp.toString 0o755

  let .ok store ← openCoreStore s!"{root}/store"
    | do IO.FS.removeDirAll root; IO.eprintln "[orb-core-test] FAIL: openCoreStore for warm claude test failed"; return 1
  let managedRef ← IO.mkRef ({ enabled := true } : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (1 : UInt64)
  let warmMgr ← OrbBin.ClaudeControl.newWarmHarnessManager
  let pendingRef ← IO.mkRef (#[] : Array (String × String))
  let app : CoreAppState := {
    cfg := { prodValid with workingDir := root }
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef
    proxyCooldownsRef := cooldownsRef
    seqRef := seqRef
    warmMgr? := some warmMgr
    warmHarnessBinOverride? := some mockClaudeFp.toString
    pendingControlCallsRef? := some pendingRef
  }
  let nowSec ← coreEpochSec
  let jwt := mintSessionToken prodValid.jwtSecret (nowSec + 3600)
  let dispatch (raw : String) : IO (Option CoreHttpResponse) := do
    match parseRequest raw.toUTF8 none with
    | .ok req =>
      match ← dispatchCoreRequest app req nowSec with
      | .ok resp => return some resp
      | .error _ => return none
    | .error _ => return none

  let createBody := OrbBin.Json.renderCompact (.obj #[
    ("id", .str "m-warm-core-1"),
    ("title", .str "Warm Claude Core Test"),
    ("backend", .str "claudecode"),
    ("working_directory", .str repoFp.toString),
    ("prompt", .str "Update tracked.txt"),
    ("spawn_harness", .bool true),
    ("permission_mode", .str "supervised")
  ])
  let createResp? ← dispatch s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {createBody.utf8ByteSize}\r\n\r\n{createBody}"
  if createResp?.map (·.status) != some 201 then
    OrbBin.ClaudeControl.stopHarnessRun warmMgr "m-warm-core-1"
    closeCoreStore store
    IO.FS.removeDirAll root
    IO.eprintln s!"[orb-core-test] FAIL: warm claude mission create failed: {createResp?.map (·.status)}"
    return 1

  let mut waitedPerm := 0
  let mut sawNativeReq := false
  let mut hasEventsHdr := false
  while waitedPerm < 4000 && !sawNativeReq do
    if let some evResp ← dispatch s!"GET /api/control/missions/m-warm-core-1/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n" then
      hasEventsHdr := evResp.extraHdrs.any (fun p => p.1 == "X-Orb-Events-Protocol" && p.2 == "1")
      let bodyStr := String.fromUTF8? evResp.body |>.getD ""
      if (bodyStr.splitOn "core-perm-1").length >= 2 && (bodyStr.splitOn "ui_native_request").length >= 2 then
        sawNativeReq := true
    if !sawNativeReq then
      IO.sleep 25
      waitedPerm := waitedPerm + 25

  let toolResBody := "{\"tool_call_id\":\"core-perm-1\",\"name\":\"ui_native_request\",\"result\":{\"action\":\"accept_session\"}}"
  let toolResResp? ← dispatch s!"POST /api/control/tool_result HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {toolResBody.utf8ByteSize}\r\n\r\n{toolResBody}"
  let toolResStr := (toolResResp?.map (·.body)).bind String.fromUTF8? |>.getD ""

  let mut waitedDone := 0
  let mut sawCompleted := false
  while waitedDone < 4000 && !sawCompleted do
    if let some evResp ← dispatch s!"GET /api/control/missions/m-warm-core-1/events?since_seq=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n" then
      let bodyStr := String.fromUTF8? evResp.body |>.getD ""
      if (bodyStr.splitOn "Core warm reply").length >= 2 && (bodyStr.splitOn "mission_status_changed").length >= 2 then
        sawCompleted := true
    if !sawCompleted then
      IO.sleep 25
      waitedDone := waitedDone + 25

  let permModeBody := "{\"mode\":\"acceptEdits\"}"
  let permModeResp? ← dispatch s!"POST /api/control/missions/m-warm-core-1/permission-mode HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {permModeBody.utf8ByteSize}\r\n\r\n{permModeBody}"
  let tcResp? ← dispatch s!"GET /api/control/missions/m-warm-core-1/tool-calls/core-perm-1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let cpListResp? ← dispatch s!"GET /api/control/missions/m-warm-core-1/checkpoints HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let cpDiffResp? ← dispatch s!"GET /api/control/missions/m-warm-core-1/checkpoints/diff HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"
  let wtGetResp? ← dispatch s!"GET /api/control/missions/m-warm-core-1/worktree?prefer_worktree=true HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\n\r\n"

  let cpListStr := (cpListResp?.map (·.body)).bind String.fromUTF8? |>.getD "{}"
  let firstRef :=
    match OrbBin.Json.parse cpListStr with
    | .ok jv =>
      let cps := (jv.fieldArr? "checkpoints").getD #[]
      (cps[0]?.bind (·.fieldStr? "ref")).getD ""
    | _ => ""
  let restoreBody := OrbBin.Json.renderCompact (.obj #[("ref", .str firstRef)])
  let cpRestoreResp? ← dispatch s!"POST /api/control/missions/m-warm-core-1/checkpoints/restore HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {jwt}\r\nContent-Length: {restoreBody.utf8ByteSize}\r\n\r\n{restoreBody}"
  let restoredContent ← IO.FS.readFile (repoFp / "tracked.txt")

  OrbBin.ClaudeControl.stopHarnessRun warmMgr "m-warm-core-1"
  closeCoreStore store
  IO.FS.removeDirAll root

  let cpDiffStr := (cpDiffResp?.map (·.body)).bind String.fromUTF8? |>.getD "{}"
  let wtGetStr := (wtGetResp?.map (·.body)).bind String.fromUTF8? |>.getD "{}"
  let tcStr := (tcResp?.map (·.body)).bind String.fromUTF8? |>.getD "{}"
  if !hasEventsHdr || !sawNativeReq ||
     toolResResp?.map (·.status) != some 200 || (toolResStr.splitOn "\"delivered\":true").length != 2 ||
     !sawCompleted ||
     permModeResp?.map (·.status) != some 200 ||
     tcResp?.map (·.status) != some 200 || (tcStr.splitOn "core-perm-1").length < 2 ||
     cpListResp?.map (·.status) != some 200 || firstRef.isEmpty ||
     cpDiffResp?.map (·.status) != some 200 || (cpDiffStr.splitOn "tracked.txt").length < 2 ||
     wtGetResp?.map (·.status) != some 200 || (wtGetStr.splitOn "\"decision_word\":513").length < 2 ||
     cpRestoreResp?.map (·.status) != some 200 || restoredContent != "initial\n" then
    IO.eprintln s!"[orb-core-test] FAIL: warm claude Core control/checkpoints/worktree mismatch: hdr={hasEventsHdr} req={sawNativeReq} toolRes={toolResStr} done={sawCompleted} ref={firstRef} restored={repr restoredContent}"
    return 1
  return 0

set_option maxRecDepth 4000 in
private def runR4cHarnessSessionTests (store : CoreStore) (tmpRoot : String) : IO UInt32 := do
  -- 1. SM-15: Generation-owned `HarnessSessionHandle` & Registry + warm-turn latch reset + stale-generation fail-closed
  let reg ← newHarnessSessionRegistry
  let badZeroGen ← registerSessionHandle reg "m-r4c-1" .openCode 0 "high"
  let badEmptyId ← registerSessionHandle reg "   " .openCode 1 "high"
  if badZeroGen.isOk || badEmptyId.isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-15 registerSessionHandle accepted empty missionId or zero generation"
    return 1

  let supKilledRef ← IO.mkRef (#[] : Array (Int64 × Int32))
  let khGen1 : ProcessKillHandle := {
    pid := 42420
    startTicks := 900100
    killProcessGrp := true
    observeFn? := some (fun _ => pure {
      procMissing := 0, procReadError := 0, isZombieOrDeadState := 0,
      fieldsAfterComm := 50, actualStartTicks := 900100
    })
    signalFn? := some (fun tgt sig => do
      supKilledRef.modify (fun xs => xs.push (tgt, sig))
      return 0)
  }
  let .ok hGen1 ← registerSessionHandle reg "m-r4c-1" .openCode 1 "high" (some khGen1)
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 initial registerSessionHandle failed"; return 1
  if hGen1.sessionGeneration != 1 || hGen1.backend != .openCode then
    IO.eprintln "[orb-core-test] FAIL: SM-15 initial handle identity mismatch"
    return 1
  -- Stale or duplicate generation registration MUST fail closed
  if (← registerSessionHandle reg "m-r4c-1" .openCode 1 "high").isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-15 registerSessionHandle accepted duplicate generation"
    return 1
  -- Superseding with generation 2 must reap generation 1's process group (`-42420`)
  let .ok hWarm ← registerSessionHandle reg "m-r4c-1" .openCode 2 "high"
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 generation-2 supersession failed"; return 1
  let supSignals ← supKilledRef.get
  if supSignals != #[(-42420, 15)] || (← registerSessionHandle reg "m-r4c-1" .openCode 1 "high").isOk then
    IO.eprintln s!"[orb-core-test] FAIL: SM-15 supersession kill or stale-generation rejection failed: {repr supSignals}"
    return 1

  -- Stale eventGeneration (`1 != 2`) MUST be rejected fail-closed on `applySessionOp`
  if (← applySessionOp hWarm .confirmReady 1).isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-15 applySessionOp accepted stale eventGeneration"
    return 1
  let .ok (stReady, _) ← applySessionOp hWarm .confirmReady 2
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 confirmReady failed"; return 1
  let .ok (stTurn1, _) ← applySessionOp hWarm .beginTurn 2
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 beginTurn 1 failed"; return 1
  if stReady.slice.phaseCode != 1 || stTurn1.slice.phaseCode != 2 || stTurn1.turnOrdinal != 1 then
    IO.eprintln "[orb-core-test] FAIL: SM-15 phase/ordinal mismatch on turn 1"
    return 1

  -- Turn 1 activity: tool call + tool result + assistant text + SSE idle + CLI exit 0 -> Ready (`phaseCode == 1`)
  let .ok _ ← stepOpenCodeHandleInput hWarm 2
    (.sseChunk "ses_warm_1" "data: {\"type\":\"tool_call\",\"sessionID\":\"ses_warm_1\",\"id\":\"tc-1\",\"name\":\"bash\"}\n")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-15/16 OpenCode tool_call step failed"; return 1
  -- While `toolDepth == 1`, `finishTurnToReady` MUST be rejected!
  if (← applySessionOp hWarm .finishTurnToReady 2 (hasTurnIdleReceipt := true)).isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-15 finishTurnToReady admitted while toolDepth > 0"
    return 1
  let .ok _ ← stepOpenCodeHandleInput hWarm 2
    (.sseChunk "ses_warm_1" "data: {\"type\":\"tool_result\",\"sessionID\":\"ses_warm_1\",\"tool_use_id\":\"tc-1\",\"output\":\"ok\"}\n")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-15/16 OpenCode tool_result step failed"; return 1
  -- Duplicate `tool_result` for `tc-1` must NOT underflow `toolDepth`
  let .ok (afterDupTool, _, dupEvs) ← stepOpenCodeHandleInput hWarm 2
    (.sseChunk "ses_warm_1" "data: {\"type\":\"tool_result\",\"sessionID\":\"ses_warm_1\",\"tool_use_id\":\"tc-1\",\"output\":\"dup\"}\n")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 duplicate tool_result step errored"; return 1
  if afterDupTool.slice.toolDepth != 0 || !dupEvs.isEmpty then
    IO.eprintln "[orb-core-test] FAIL: SM-16 duplicate tool_result underflowed or re-emitted"
    return 1
  let .ok _ ← stepOpenCodeHandleInput hWarm 2
    (.cliJsonLine "{\"type\":\"text\",\"sessionID\":\"ses_warm_1\",\"part\":{\"type\":\"text\",\"text\":\"Turn 1 visible reply\"}}")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 Turn 1 text step failed"; return 1
  let .ok _ ← stepOpenCodeHandleInput hWarm 2
    (.cliJsonLine "{\"type\":\"step_finish\",\"sessionID\":\"ses_warm_1\",\"part\":{\"type\":\"step-finish\",\"reason\":\"stop\"}}")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 Turn 1 step_finish failed"; return 1
  let .ok (afterTurn1Idle, _, turn1IdleEvs) ← stepOpenCodeHandleInput hWarm 2
    (.sseSessionIdle "ses_warm_1")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 Turn 1 sseSessionIdle failed"; return 1
  if afterTurn1Idle.slice.phaseCode != 1 ||
     turn1IdleEvs != #[.TurnResult "m-r4c-1" false "end_turn"] then
    IO.eprintln s!"[orb-core-test] FAIL: SM-16 Turn 1 did not settle to Ready cleanly: {repr afterTurn1Idle.slice} evs={repr turn1IdleEvs}"
    return 1

  -- Park -> Wake -> BeginTurn (Turn 2) on warm session MUST reset `sawUserText`, `sawActivity`, `emittedEvents`, `openCode` latches
  -- while preserving `expectedSessionId == "ses_warm_1"`, so a silent stop on Turn 2 is NOT masked by Turn 1's `sawUserText = true`!
  let .ok (stParked, _) ← applySessionOp hWarm .parkSession 2
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 parkSession failed"; return 1
  let .ok (stWoken, _) ← applySessionOp hWarm .wakeParkedSession 2
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 wakeParkedSession failed"; return 1
  let .ok (stTurn2, _) ← applySessionOp hWarm .beginTurn 2
    | do IO.eprintln "[orb-core-test] FAIL: SM-15 beginTurn 2 failed"; return 1
  if stParked.slice.phaseCode != 3 || stWoken.slice.phaseCode != 1 || stTurn2.slice.phaseCode != 2 ||
     stTurn2.turnOrdinal != 2 || stTurn2.parser.sawUserText || stTurn2.parser.sawActivity ||
     !stTurn2.parser.emittedEvents.isEmpty || stTurn2.openCode.sawSseIdle ||
     stTurn2.openCode.expectedSessionId != "ses_warm_1" then
    IO.eprintln s!"[orb-core-test] FAIL: SM-15 warm turn latch reset failed: {repr stTurn2}"
    return 1
  -- Foreign sessionID frame on SSE sidecar must be rejected by `agentEventNormalizeStep` (`sessionMatchesExpected == 0`)
  let .ok (afterForeign, _, foreignEvs) ← stepOpenCodeHandleInput hWarm 2
    (.sseChunk "ses_foreign_999" "data: {\"type\":\"text_delta\",\"sessionID\":\"ses_foreign_999\",\"delta\":\"SPOOFED\"}\n")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 foreign session step errored"; return 1
  if afterForeign.parser.sawUserText || !foreignEvs.isEmpty then
    IO.eprintln "[orb-core-test] FAIL: SM-16 foreign OpenCode SSE session leaked into active turn"
    return 1
  -- Direct `foldEmittedAgentEventIntoSession` normalizer admission gate on `.TurnResult _ true msg`:
  -- oversize payload (`payloadBytes > 65536`), invalid `harnessKind > 5`, or foreign `sessionMatches == 0`
  -- when `expectedSessionId` is bound MUST all be rejected fail-closed (`sawExplicitError == false`, `ev? == none`),
  -- and an oversize OpenCode SSE/CLI error line (`> 65536` bytes) MUST NOT poison `sawExplicitError` or `expectedSessionId`!
  let baseNormSlice := afterForeign.slice
  let baseNormDc : OpenCodeDualChannelState := { expectedSessionId := "ses_warm_1" }
  let errEv := AgentEvent.TurnResult "m-r4c-1" true "synthetic-err"
  let (_, dcOversize, _, evOversize?) :=
    foldEmittedAgentEventIntoSession 3 baseNormSlice baseNormDc 1 70000 errEv
  let (_, dcBadKind, _, evBadKind?) :=
    foldEmittedAgentEventIntoSession 9 baseNormSlice baseNormDc 1 128 errEv
  let (_, dcForeignErr, _, evForeignErr?) :=
    foldEmittedAgentEventIntoSession 3 baseNormSlice baseNormDc 0 128 errEv
  let (_, dcValidErr, _, evValidErr?) :=
    foldEmittedAgentEventIntoSession 3 baseNormSlice baseNormDc 1 128 errEv
  if dcOversize.sawExplicitError || evOversize?.isSome ||
     dcBadKind.sawExplicitError || evBadKind?.isSome ||
     dcForeignErr.sawExplicitError || evForeignErr?.isSome ||
     !dcValidErr.sawExplicitError || evValidErr? != some errEv then
    IO.eprintln "[orb-core-test] FAIL: SM-16 foldEmittedAgentEventIntoSession did not enforce normalizer/session admission on error TurnResult"
    return 1
  let hugePad := String.ofList (List.replicate 66000 'x')
  let hugeErrJson := s!"\{\"type\":\"result\",\"sessionID\":\"ses_warm_1\",\"is_error\":true,\"error\":\"{hugePad}\"}"
  let .ok (afterHugeErr, _, hugeErrEvs) ← stepOpenCodeHandleInput hWarm 2
    (.cliJsonLine hugeErrJson)
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 oversize CLI error line step errored"; return 1
  if afterHugeErr.openCode.sawExplicitError || !hugeErrEvs.isEmpty then
    IO.eprintln "[orb-core-test] FAIL: SM-16 oversize (>65536B) error event bypassed normalizer byte cap"
    return 1
  -- Turn 2 reasoning without assistant text + `step_finish=stop` MUST flag silent stop (proving Turn 1 `sawUserText` did not bleed)
  let .ok _ ← stepOpenCodeHandleInput hWarm 2
    (.cliJsonLine "{\"type\":\"reasoning\",\"sessionID\":\"ses_warm_1\",\"part\":{\"type\":\"reasoning\",\"text\":\"Thinking only\"}}")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 Turn 2 reasoning failed"; return 1
  let .ok (afterSilent, _, silentEvs) ← stepOpenCodeHandleInput hWarm 2
    (.cliJsonLine "{\"type\":\"step_finish\",\"sessionID\":\"ses_warm_1\",\"part\":{\"type\":\"step-finish\",\"reason\":\"stop\"}}")
    (requireCliExitForTurnDone := false)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 Turn 2 step_finish failed"; return 1
  if afterSilent.openCode.verdict != .failedSilentStop "OpenCode finished without assistant text (stop reason: end_turn)." ||
     !silentEvs.any (fun e => e == .TurnResult "m-r4c-1" true "OpenCode finished without assistant text (stop reason: end_turn).") then
    IO.eprintln s!"[orb-core-test] FAIL: SM-15/16 Turn 2 silent stop was masked by stale Turn 1 latches: {repr afterSilent.openCode}"
    return 1

  -- 2. SM-16: Out-of-order, duplicate, and raced OpenCode SSE `session.idle` vs CLI exit (`0` vs non-zero)
  -- Case A: Raced `SSE session.idle` arriving BEFORE non-zero CLI exit (`exitCode = 137`) MUST NOT mark turn clean,
  -- and `Terminating -> Dead` (`opCode = 10`) MUST fail closed without `hasProcExitReceipt == 1`.
  let .ok hRace ← mkHarnessSessionHandle "m-oc-race" .openCode 3
    | do IO.eprintln "[orb-core-test] FAIL: mkHarnessSessionHandle m-oc-race failed"; return 1
  let .ok _ ← applySessionOp hRace .confirmReady 3 | return 1
  let .ok _ ← applySessionOp hRace .beginTurn 3 | return 1
  let .ok _ ← stepOpenCodeHandleInput hRace 3
    (.cliJsonLine "{\"type\":\"text\",\"sessionID\":\"ses_r\",\"part\":{\"type\":\"text\",\"text\":\"partial output\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok (sAfterRacedIdle, _, evsRacedIdle) ← stepOpenCodeHandleInput hRace 3
    (.sseSessionIdle "ses_r") (requireCliExitForTurnDone := true) | return 1
  -- Duplicate `session.idle` while CLI still running must also stay `inProgress`
  let .ok (sAfterDupIdle, _, evsDupIdle) ← stepOpenCodeHandleInput hRace 3
    (.sseSessionIdle "ses_r") (requireCliExitForTurnDone := true) | return 1
  if sAfterRacedIdle.slice.phaseCode != 2 || !evsRacedIdle.isEmpty ||
     sAfterDupIdle.openCode.verdict != .inProgress || !evsDupIdle.isEmpty then
    IO.eprintln "[orb-core-test] FAIL: SM-16 raced/duplicate SSE session.idle prematurely completed turn before CLI exit"
    return 1
  let .ok (sAfterCrashExit, _, evsCrashExit) ← stepOpenCodeHandleInput hRace 3
    (.cliProcessExited 137) (requireCliExitForTurnDone := true) | return 1
  if sAfterCrashExit.openCode.verdict != .failedCliExit 137 "opencode_cli_exit_137" ||
     evsCrashExit != #[.TurnResult "m-oc-race" true "opencode_cli_exit_137"] then
    IO.eprintln s!"[orb-core-test] FAIL: SM-16 non-zero CLI exit after SSE idle did not surface failedCliExit: {repr sAfterCrashExit.openCode}"
    return 1
  -- Verify `Terminating -> Dead` (`confirmProcessDead`) rejects `hasProcExitReceipt = false` on a live handle
  let .ok hTermGate ← mkHarnessSessionHandle "m-oc-term" .openCode 4 | return 1
  let .ok _ ← applySessionOp hTermGate .beginTerminate 4 | return 1
  if (← applySessionOp hTermGate .confirmProcessDead 4 (hasProcExitReceipt := false)).isOk ||
     (← retireDeadSessionHandle reg "m-r4c-1" 2) then
    IO.eprintln "[orb-core-test] FAIL: SM-16 confirmProcessDead admitted without exit receipt or retired live handle"
    return 1
  let .ok (deadTerm, _) ← applySessionOp hTermGate .confirmProcessDead 4 (hasProcExitReceipt := true)
    | do IO.eprintln "[orb-core-test] FAIL: SM-16 confirmProcessDead with exit receipt failed"; return 1
  if deadTerm.slice.phaseCode != 5 || (← applySessionOp hTermGate .confirmReady 4).isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-16 Dead phase was not sticky"
    return 1

  -- Case B: Out-of-order `CLI exit 0` BEFORE trailing SSE `session.idle` settles once and suppresses trailing duplicate SSE idle
  let .ok hOutOrder ← mkHarnessSessionHandle "m-oc-ooo" .openCode 5 | return 1
  let .ok _ ← applySessionOp hOutOrder .confirmReady 5 | return 1
  let .ok _ ← applySessionOp hOutOrder .beginTurn 5 | return 1
  let .ok _ ← stepOpenCodeHandleInput hOutOrder 5
    (.cliJsonLine "{\"type\":\"text\",\"sessionID\":\"ses_ooo\",\"part\":{\"type\":\"text\",\"text\":\"complete answer\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok (sExitFirst, _, evsExitFirst) ← stepOpenCodeHandleInput hOutOrder 5
    (.cliProcessExited 0) (requireCliExitForTurnDone := true) | return 1
  let .ok (sTrailingIdle, _, evsTrailingIdle) ← stepOpenCodeHandleInput hOutOrder 5
    (.sseChunk "ses_ooo" "data: {\"type\":\"session.idle\",\"sessionID\":\"ses_ooo\"}\n")
    (requireCliExitForTurnDone := true) | return 1
  if sExitFirst.slice.phaseCode != 1 || evsExitFirst != #[.TurnResult "m-oc-ooo" false "end_turn"] ||
     sTrailingIdle.slice.phaseCode != 1 || !evsTrailingIdle.isEmpty then
    IO.eprintln s!"[orb-core-test] FAIL: SM-16 CLI-exit-before-SSE-idle out-of-order settlement failed: ev1={repr evsExitFirst} ev2={repr evsTrailingIdle}"
    return 1

  -- Case C: OpenCode `step_finish` `reason == "length"` after tool steps + oversize (>65536B) reasoning line + `CLI exit 0`
  -- (`ashur` `c2dc6bee` incident replay):
  --   1) nested `part` `tool_use` with `status == "completed"` emits paired `ToolCall` + `ToolResult` keeping `toolDepth == 0`;
  --   2) `step_start` records `sawActivity = true` even when the subsequent `31,999`-token `reasoning` line exceeds `65536` bytes;
  --   3) `step_finish(reason="length")` + `cliProcessExited 0` surfaces `failedSilentStop "OpenCode finished without assistant text (stop reason: length)."`
  --      exactly once (never misclassifying as `completedClean` or masking `length` as `end_turn`);
  --   4) warm turn reset clears `lastStopReason` so a resumed turn completes cleanly.
  let .ok hLenStop ← mkHarnessSessionHandle "m-oc-len-stop" .openCode 6 | return 1
  let .ok _ ← applySessionOp hLenStop .confirmReady 6 | return 1
  let .ok _ ← applySessionOp hLenStop .beginTurn 6 | return 1
  let .ok _ ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"step_start\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"step-start\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok (sAfterOcTool, _, evsOcTool) ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"tool_use\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"tool\",\"callID\":\"call_ashur_1\",\"tool\":\"sandboxed_get_mission_health\",\"state\":{\"status\":\"completed\",\"input\":{\"id\":\"m-oc-len-stop\"},\"output\":\"running\"}}}")
    (requireCliExitForTurnDone := true) | return 1
  if sAfterOcTool.slice.toolDepth != 0 ||
     evsOcTool != #[
       .ToolCall "m-oc-len-stop" "call_ashur_1" "sandboxed_get_mission_health" "{\"id\":\"m-oc-len-stop\"}",
       .ToolResult "m-oc-len-stop" "call_ashur_1" "sandboxed_get_mission_health" "running"
     ] then
    IO.eprintln s!"[orb-core-test] FAIL: OpenCode nested completed tool_use did not keep toolDepth balanced: depth={sAfterOcTool.slice.toolDepth} evs={repr evsOcTool}"
    return 1
  let .ok _ ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"step_finish\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"step-finish\",\"reason\":\"tool-calls\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok _ ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"step_start\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"step-start\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let hugeReasoningLine :=
    s!"\{\"type\":\"reasoning\",\"sessionID\":\"ses_ashur\",\"part\":\{\"type\":\"reasoning\",\"text\":\"{hugePad}\"}}"
  let .ok _ ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine hugeReasoningLine)
    (requireCliExitForTurnDone := true) | return 1
  let .ok (sAfterLenFinish, _, evsLenFinish) ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"step_finish\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"step-finish\",\"reason\":\"length\",\"tokens\":{\"total\":139374,\"input\":107374,\"output\":1,\"reasoning\":31999}}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok (sAfterLenExit, _, evsLenExit) ← stepOpenCodeHandleInput hLenStop 6
    (.cliProcessExited 0)
    (requireCliExitForTurnDone := true) | return 1
  let expectedLenMsg := "OpenCode finished without assistant text (stop reason: length)."
  if sAfterLenFinish.openCode.verdict != .failedSilentStop expectedLenMsg ||
     evsLenFinish != #[.TurnResult "m-oc-len-stop" true expectedLenMsg] ||
     sAfterLenExit.openCode.verdict != .failedSilentStop expectedLenMsg ||
     !evsLenExit.isEmpty then
    IO.eprintln s!"[orb-core-test] FAIL: OpenCode step_finish(length) + exit 0 replay mismatch: finishEvs={repr evsLenFinish} exitEvs={repr evsLenExit} verdict={repr sAfterLenExit.openCode.verdict}"
    return 1
  -- Resume on warm handle (`finishTurnToReady` -> `beginTurn`) and verify `lastStopReason` is cleared
  let .ok _ ← applySessionOp hLenStop .finishTurnToReady 6 (hasTurnIdleReceipt := true) (hasProcExitReceipt := true) | return 1
  let .ok (sResumedTurn, _) ← applySessionOp hLenStop .beginTurn 6 | return 1
  if !sResumedTurn.parser.lastStopReason.isEmpty || sResumedTurn.parser.sawActivity then
    IO.eprintln s!"[orb-core-test] FAIL: warm turn reset did not clear lastStopReason: {repr sResumedTurn.parser}"
    return 1
  let .ok _ ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"text\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"text\",\"text\":\"Resumed cleanly\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok _ ← stepOpenCodeHandleInput hLenStop 6
    (.cliJsonLine "{\"type\":\"step_finish\",\"sessionID\":\"ses_ashur\",\"part\":{\"type\":\"step-finish\",\"reason\":\"stop\"}}")
    (requireCliExitForTurnDone := true) | return 1
  let .ok (sResumedDone, _, evsResumedDone) ← stepOpenCodeHandleInput hLenStop 6
    (.cliProcessExited 0)
    (requireCliExitForTurnDone := true) | return 1
  if sResumedDone.openCode.verdict != .completedClean ||
     sResumedDone.slice.phaseCode != 1 ||
     evsResumedDone != #[.TurnResult "m-oc-len-stop" false "end_turn"] then
    IO.eprintln s!"[orb-core-test] FAIL: warm turn after length stop did not complete cleanly: {repr sResumedDone.openCode} evs={repr evsResumedDone}"
    return 1

  -- 3. SM-17: Non-contended `ProcessKillHandle` (`procLivenessStep` + `/proc/<pid>/stat` parser + contended mutex test)
  let trickyStat :=
    "54321 (codex (worker) 1) S 1 54321 54321 0 -1 4194304 100 0 0 0 12 3 0 0 20 0 4 0 88776655 12345678 1024"
  let parsedObs := parseProcStatContent trickyStat
  if parsedObs.procMissing != 0 || parsedObs.procReadError != 0 || parsedObs.isZombieOrDeadState != 0 ||
     parsedObs.actualStartTicks != 88776655 || parsedObs.fieldsAfterComm < 20 then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 parseProcStatContent failed on parens/spaces comm: {repr parsedObs}"
    return 1
  -- Live `/proc/self/stat` check on Linux (or synthetic procRoot fixture on macOS without procfs)
  let selfPid ← OrbBin.PosixExt.getpid
  let hasLinuxProc := (← OrbBin.PosixExt.statPath "/proc/self/stat").exists_
  let procRootForSelf ←
    if hasLinuxProc then
      pure (System.FilePath.mk "/proc")
    else do
      let fakeProc := System.FilePath.mk s!"{tmpRoot}/fake-proc"
      IO.FS.createDirAll (fakeProc / s!"{selfPid}")
      IO.FS.writeFile (fakeProc / s!"{selfPid}" / "stat") trickyStat
      pure fakeProc
  let selfTicks? ← readLiveProcStartTicks? selfPid procRootForSelf
  if selfPid == 0 || selfTicks?.isNone || (!hasLinuxProc && selfTicks? != some 88776655) then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 readLiveProcStartTicks? failed on current PID {selfPid}"
    return 1

  -- PID reuse (`actualStartTicks != startTicks`) and zombie (`'Z'`) MUST return `.skippedDeadOrPidReused` and NEVER invoke `signalFn`!
  let killSignalsRef ← IO.mkRef (#[] : Array (Int64 × Int32))
  let reusedKh : ProcessKillHandle := {
    pid := 54321
    startTicks := 88776655
    observeFn? := some (fun _ => pure { parsedObs with actualStartTicks := 99999999 })
    signalFn? := some (fun tgt sig => do killSignalsRef.modify (·.push (tgt, sig)); return 0)
  }
  let zombieKh : ProcessKillHandle := {
    pid := 54321
    startTicks := 88776655
    observeFn? := some (fun _ => pure { parsedObs with isZombieOrDeadState := 1 })
    signalFn? := some (fun tgt sig => do killSignalsRef.modify (·.push (tgt, sig)); return 0)
  }
  let vReused ← reapWithKillHandle reusedKh 9
  let vZombie ← reapWithKillHandle zombieKh 9
  let sigsAfterReject ← killSignalsRef.get
  if vReused != .skippedDeadOrPidReused || vZombie != .skippedDeadOrPidReused || !sigsAfterReject.isEmpty then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 PID reuse or zombie process was signaled: {repr vReused} {repr vZombie}"
    return 1

  -- Contended `handle.mu` test: hold `handle.mu` inside a background task and prove `forceKillHandleNonBlocking`
  -- immediately reaps the matching `(pid, startTicks)` without blocking on `handle.mu`!
  let liveKh : ProcessKillHandle := {
    pid := 54321
    startTicks := 88776655
    killProcessGrp := true
    observeFn? := some (fun _ => pure parsedObs)
    signalFn? := some (fun tgt sig => do killSignalsRef.modify (·.push (tgt, sig)); return 0)
  }
  let .ok hContended ← mkHarnessSessionHandle "m-contended" .codex 1 "high" (some liveKh) | return 1
  let enteredLock ← IO.Promise.new
  let releaseLock ← IO.Promise.new
  let holderTask ← IO.asTask (prio := .dedicated) do
    hContended.mu.atomically do
      enteredLock.resolve ()
      let _ := releaseLock.result?.get
      pure ()
  let _ := enteredLock.result?.get
  let vWhileLocked ← forceKillHandleNonBlocking hContended 15
  releaseLock.resolve ()
  let _ ← IO.wait holderTask
  let sigsAfterContended ← killSignalsRef.get
  if vWhileLocked != .signaledAlive 0 || sigsAfterContended != #[(-54321, 15)] then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 non-contended forceKillHandleNonBlocking failed while mu locked: {repr vWhileLocked} {repr sigsAfterContended}"
    return 1

  -- 4. SM-17: Durable `(session_id, prompt_claim, tool_journal)` continuity table & crash reconciliation
  let .ok () ← ensureHarnessContinuitySchema store.missionsDb
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 ensureHarnessContinuitySchema failed"; return 1
  let .ok contIdxRows ← execParamQuery store.missionsDb
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_harness_continuity_reconcile';" #[]
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 sqlite_master continuity index query failed"; return 1
  if contIdxRows.size != 2 || contIdxRows[1]! != #["idx_harness_continuity_reconcile"] then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 idx_harness_continuity_reconcile missing in sqlite_master: {repr contIdxRows}"
    return 1
  let .ok boundRec ← bindHarnessContinuitySession store.missionsDb "m-codex-cont" .codex 1 "thread-codex-1" "t-c0"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 bindHarnessContinuitySession failed"; return 1
  if boundRec.sessionId != "thread-codex-1" || boundRec.promptClaimPhase != .none || boundRec.stateRevision != 1 then
    IO.eprintln "[orb-core-test] FAIL: SM-17 bound continuity record mismatch"
    return 1
  -- Winning CAS advances `state_revision` by exactly 1; stale expected revision (`0`-row update) returns `cas_conflict`
  -- and leaves the durable row unchanged (no unwritten revision returned as `.ok`).
  let .ok casWinner ← commitHarnessContinuityCas store.missionsDb "m-codex-cont" boundRec.stateRevision .codex 1 "thread-codex-1" "" .none #[] false "t-c0b"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 winning continuity CAS failed"; return 1
  if casWinner.stateRevision != boundRec.stateRevision + 1 then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 winning CAS did not advance state_revision by 1: {casWinner.stateRevision}"
    return 1
  let lostCas ← commitHarnessContinuityCas store.missionsDb "m-codex-cont" boundRec.stateRevision .codex 1 "thread-codex-LOST" "" .none #[] false "t-c0c"
  match lostCas with
  | .error msg =>
    if !(msg.startsWith "cas_conflict:") then
      IO.eprintln s!"[orb-core-test] FAIL: SM-17 lost CAS returned unexpected error: {msg}"
      return 1
  | .ok stale =>
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 lost CAS returned .ok stale record: {repr stale}"
    return 1
  let .ok (some afterLost?) ← loadHarnessContinuity? store.missionsDb "m-codex-cont"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 loadHarnessContinuity? after lost CAS failed"; return 1
  if afterLost?.sessionId != "thread-codex-1" || afterLost?.stateRevision != casWinner.stateRevision then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 lost CAS mutated durable continuity row: {repr afterLost?}"
    return 1
  -- Claim prompt `claim-1` and start tool `call-a`, then simulate crash before delivery ack / tool result
  let .ok claimedRec ← claimHarnessPrompt store.missionsDb "m-codex-cont" 1 "claim-1" "t-c1"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 claimHarnessPrompt failed"; return 1
  if claimedRec.stateRevision != afterLost?.stateRevision + 1 then
    IO.eprintln "[orb-core-test] FAIL: SM-17 claimHarnessPrompt did not advance state_revision by 1"
    return 1
  -- Second concurrent prompt claim before delivery/reconcile MUST fail closed (double prompt claim rejected)
  if (← claimHarnessPrompt store.missionsDb "m-codex-cont" 1 "claim-1" "t-c1b").isOk ||
     (← claimHarnessPrompt store.missionsDb "m-codex-cont" 1 "claim-2" "t-c1c").isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-17 concurrent/duplicate inflight claim was not fenced"
    return 1
  let .ok _ ← recordHarnessToolJournal store.missionsDb "m-codex-cont" 1
    { callId := "call-a", toolName := "bash", phase := .started } "t-c2"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 recordHarnessToolJournal started failed"; return 1
  let .ok (some recOut) ← reconcileHarnessContinuityOnRestart store.missionsDb "m-codex-cont" "t-c3"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 reconcileHarnessContinuityOnRestart failed"; return 1
  let reconciledRec ← match recOut with
    | .requiresReconciliation r reason =>
      if reason != "prompt_claim_uncertain" || r.promptClaimPhase != .uncertain || !r.reconcileRequired ||
         r.sessionId != "thread-codex-1" ||
         r.toolJournal != #[{ callId := "call-a", toolName := "bash", phase := .crashTombstone, outputHash := "" }] then
        IO.eprintln s!"[orb-core-test] FAIL: SM-17 crash reconciliation state mismatch: reason={reason} rec={repr r}"
        return 1
      pure r
    | .cleanReady r =>
      IO.eprintln s!"[orb-core-test] FAIL: SM-17 expected requiresReconciliation across crash, got cleanReady: {repr r}"
      return 1
  let _ := reconciledRec
  -- While `reconcile_required == true`, fresh prompt claim or session rebind MUST fail closed with `native_continuity_required`
  if (← claimHarnessPrompt store.missionsDb "m-codex-cont" 1 "claim-after-crash" "t-c4").isOk ||
     (← bindHarnessContinuitySession store.missionsDb "m-codex-cont" .codex 2 "thread-different" "t-c4").isOk ||
     (← resolveContinuityReconciliation store.missionsDb "m-codex-cont" 1 true "thread-DRIFTED" "t-c4").isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-17 unreconciled continuity allowed fresh claim, rebind, or sessionId drift"
    return 1
  let .ok resolvedRec ← resolveContinuityReconciliation store.missionsDb "m-codex-cont" 1 true "thread-codex-1" "t-c5"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 resolveContinuityReconciliation failed"; return 1
  -- Duplicate replay of already-delivered `claim-1` is rejected, while new `claim-2` now succeeds
  if resolvedRec.reconcileRequired || resolvedRec.promptClaimPhase != .delivered ||
     (← claimHarnessPrompt store.missionsDb "m-codex-cont" 1 "claim-1" "t-c6").isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-17 delivered prompt claim was not idempotent after reconciliation"
    return 1
  let .ok _ ← claimHarnessPrompt store.missionsDb "m-codex-cont" 1 "claim-2" "t-c7"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 next prompt claim after reconciliation failed"; return 1
  let .ok _ ← confirmHarnessPromptDelivered store.missionsDb "m-codex-cont" 1 "claim-2" "" "t-c8"
    | do IO.eprintln "[orb-core-test] FAIL: SM-17 confirmHarnessPromptDelivered failed"; return 1

  -- 5. SM-18: Ask sidecar post-ack `operator_notes` midturn flush + startup `ask-sandbox-*` GC
  let sbxRoot : System.FilePath := System.FilePath.mk s!"{tmpRoot}/ask-tmp-root"
  IO.FS.createDirAll sbxRoot
  let orphanDir1 := sbxRoot / "ask-sandbox-orphan-01"
  let orphanDir2 := sbxRoot / "ask-sandbox-orphan-02"
  let activeDir := sbxRoot / "ask-sandbox-active-99"
  let unrelatedDir := sbxRoot / "keep-other-scratch"
  let protectedOutside := System.FilePath.mk s!"{tmpRoot}/protected-outside-dir"
  IO.FS.createDirAll (orphanDir1 / "nested")
  IO.FS.writeFile (orphanDir1 / "nested" / "scratch.txt") "orphan1"
  IO.FS.createDirAll orphanDir2
  IO.FS.createDirAll activeDir
  IO.FS.writeFile (activeDir / "live.txt") "keep-active"
  IO.FS.createDirAll unrelatedDir
  IO.FS.createDirAll protectedOutside
  IO.FS.writeFile (protectedOutside / "must-survive.txt") "precious"
  -- Create a symlink `ask-sandbox-symlink-03 -> protectedOutside` to prove GC uses `lstat` and unlinks only the symlink
  let symPath := sbxRoot / "ask-sandbox-symlink-03"
  let symOut ← IO.Process.output { cmd := "ln", args := #["-s", protectedOutside.toString, symPath.toString] }
  if symOut.exitCode != 0 then
    IO.eprintln "[orb-core-test] FAIL: SM-18 ln -s setup failed"
    return 1

  let .ok () ← ensureAskMidturnSchema store.askDb
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 ensureAskMidturnSchema failed"; return 1
  let .ok askIdxRows ← execParamQuery store.askDb
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_operator_notes_pending';" #[]
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 sqlite_master idx_operator_notes_pending query failed"; return 1
  if askIdxRows.size != 2 || askIdxRows[1]! != #["idx_operator_notes_pending"] then
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 idx_operator_notes_pending missing in sqlite_master: {repr askIdxRows}"
    return 1
  let .ok n1 ← enqueueOperatorNote store.askDb "uuid-note-001" "m-midturn" "First operator steer" 10 "2026-11-07T01:00:00Z"
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 enqueueOperatorNote 1 failed"; return 1
  let .ok n2 ← enqueueOperatorNote store.askDb "uuid-note-002" "m-midturn" "Second operator steer" 20 "2026-11-07T01:00:01Z"
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 enqueueOperatorNote 2 failed"; return 1
  -- Duplicate enqueue of `uuid-note-001` preserves original UUID & seq without duplicating
  let .ok n1Dup ← enqueueOperatorNote store.askDb "uuid-note-001" "m-midturn" "Mutated text" 999 "2026-11-07T01:05:00Z"
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 duplicate enqueueOperatorNote failed"; return 1
  if n1Dup != n1 || n2.createdAtSeq != 20 then
    IO.eprintln "[orb-core-test] FAIL: SM-18 idempotent enqueueOperatorNote mutated original note"
    return 1

  let .ok (bootPendingCount, reapedNames) ← bootstrapAskSidecarOnStartup store.askDb sbxRoot #["active-99"]
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 bootstrapAskSidecarOnStartup failed"; return 1
  let orphan1St ← OrbBin.PosixExt.statPath orphanDir1.toString
  let orphan2St ← OrbBin.PosixExt.statPath orphanDir2.toString
  let symSt ← OrbBin.PosixExt.statPath symPath.toString
  let activeSt ← OrbBin.PosixExt.statPath (activeDir / "live.txt").toString
  let unrelatedSt ← OrbBin.PosixExt.statPath unrelatedDir.toString
  let preciousSt ← OrbBin.PosixExt.statPath (protectedOutside / "must-survive.txt").toString
  if bootPendingCount != 2 ||
     reapedNames != #["ask-sandbox-orphan-01", "ask-sandbox-orphan-02", "ask-sandbox-symlink-03"] ||
     orphan1St.exists_ || orphan2St.exists_ || symSt.exists_ ||
     !activeSt.exists_ || !unrelatedSt.exists_ || !preciousSt.exists_ then
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 startup bootstrap / sandbox GC invariant violated: pending={bootPendingCount} reaped={repr reapedNames}"
    return 1

  -- Midturn flush fencing: MUST reject while `toolDepth > 0`, and on transient RPC injection failure on note 2:
  -- note 1 commits `flushed_at`, while note 2 keeps `flushed_at == none`, original `noteId == "uuid-note-002"`,
  -- original `createdAtSeq == 20`, `deliveryTries == 1`, and `steerPending == 1` on `hMid`!
  let .ok hMid ← mkHarnessSessionHandle "m-midturn" .claudeCode 1 | return 1
  let .ok _ ← applySessionOp hMid .confirmReady 1 | return 1
  let .ok _ ← applySessionOp hMid .beginTurn 1 | return 1
  let .ok _ ← stepStandardHarnessLine hMid 1 "{\"type\":\"tool_call\",\"id\":\"c-mid-1\",\"name\":\"bash\"}" | return 1
  -- Flush while `toolDepth == 1` MUST fail closed before calling `injectFn`
  let calledWhileToolBusy ← IO.mkRef false
  let busyFlush ← flushPendingOperatorNotesBetweenTools store.askDb hMid 1 "2026-11-07T01:01:00Z" (fun _ => do
    calledWhileToolBusy.set true
    return .ok { receiptId := "should-not-run" })
  if busyFlush.isOk || (← calledWhileToolBusy.get) then
    IO.eprintln "[orb-core-test] FAIL: SM-18 midturn flush admitted while toolDepth > 0"
    return 1
  -- Complete tool call (`toolDepth -> 0`), then inject note 1 ok and fail note 2 transiently
  let .ok _ ← stepStandardHarnessLine hMid 1 "{\"type\":\"tool_result\",\"tool_use_id\":\"c-mid-1\",\"output\":\"done\"}" | return 1
  let injectedLogRef ← IO.mkRef (#[] : Array String)
  let failFlush ← flushPendingOperatorNotesBetweenTools store.askDb hMid 1 "2026-11-07T01:02:00Z" (fun note => do
    injectedLogRef.modify (·.push note.noteId)
    if note.noteId == "uuid-note-002" then
      return .error "rpc_stdin_would_block"
    return .ok { receiptId := s!"ack-{note.noteId}" })
  match failFlush with
  | .ok partialSum =>
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 failed inject returned .ok success: {repr partialSum}"
    return 1
  | .error errMsg =>
    if errMsg != "rpc_stdin_would_block" then
      IO.eprintln s!"[orb-core-test] FAIL: SM-18 failed inject surfaced unexpected error: {errMsg}"
      return 1
  let midInnerAfterFail ← inspectSessionInner hMid
  let .ok remAfterFail ← listPendingOperatorNotes store.askDb "m-midturn" | return 1
  let .ok allAfterFail ← listAllOperatorNotes store.askDb "m-midturn" | return 1
  let note1AfterFail := allAfterFail.find? (fun n => n.noteId == "uuid-note-001")
  if note1AfterFail != some { n1 with deliveryTries := 1, flushedAt? := some "2026-11-07T01:02:00Z" } ||
     midInnerAfterFail.slice.steerPending != 1 ||
     remAfterFail.size != 1 ||
     remAfterFail[0]!.noteId != "uuid-note-002" ||
     remAfterFail[0]!.createdAtSeq != 20 ||
     remAfterFail[0]!.createdAtIso != n2.createdAtIso ||
     remAfterFail[0]!.deliveryTries != 1 ||
     remAfterFail[0]!.flushedAt?.isSome then
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 transient midturn failure dropped or mutated note identity/order: rem={repr remAfterFail}"
    return 1

  -- Empty delivery receipt MUST NOT mark `flushed_at` before a real receipt exists
  let emptyReceiptFlush ← flushPendingOperatorNotesBetweenTools store.askDb hMid 1 "2026-11-07T01:02:15Z" (fun note => do
    if note.noteId == "uuid-note-002" then
      return .ok { receiptId := "   " }
    return .ok { receiptId := s!"ack-{note.noteId}" })
  match emptyReceiptFlush with
  | .ok bogus =>
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 empty delivery receipt was treated as success: {repr bogus}"
    return 1
  | .error errMsg =>
    if errMsg != "missing_delivery_receipt:uuid-note-002" then
      IO.eprintln s!"[orb-core-test] FAIL: SM-18 empty receipt error mismatch: {errMsg}"
      return 1
  let .ok remAfterEmpty ← listPendingOperatorNotes store.askDb "m-midturn" | return 1
  if remAfterEmpty.size != 1 || remAfterEmpty[0]!.noteId != "uuid-note-002" ||
     remAfterEmpty[0]!.createdAtSeq != 20 || remAfterEmpty[0]!.flushedAt?.isSome then
    IO.eprintln "[orb-core-test] FAIL: SM-18 empty delivery receipt marked flushed_at before receipt"
    return 1

  -- Enqueue a third note (`seq = 30`) and retry flush when RPC succeeds: `uuid-note-002` MUST flush BEFORE `uuid-note-003`,
  -- and `steerPending` MUST clear (`0`) via `flushSteerBetweenTools` (`opCode = 5`)!
  let .ok _ ← enqueueOperatorNote store.askDb "uuid-note-003" "m-midturn" "Third operator steer" 30 "2026-11-07T01:02:30Z"
    | return 1
  let retryOrderRef ← IO.mkRef (#[] : Array String)
  let .ok fullFlush ← flushPendingOperatorNotesBetweenTools store.askDb hMid 1 "2026-11-07T01:03:00Z" (fun note => do
    retryOrderRef.modify (·.push note.noteId)
    return .ok { receiptId := s!"ack-{note.noteId}" })
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 retry midturn flush failed"; return 1
  let retryOrder ← retryOrderRef.get
  let midInnerAfterOk ← inspectSessionInner hMid
  let .ok remAfterOk ← listPendingOperatorNotes store.askDb "m-midturn" | return 1
  let .ok allNotes ← listAllOperatorNotes store.askDb "m-midturn" | return 1
  if retryOrder != #["uuid-note-002", "uuid-note-003"] ||
     fullFlush.flushedNoteIds != #["uuid-note-002", "uuid-note-003"] ||
     fullFlush.remainingCount != 0 ||
     fullFlush.failedReason?.isSome ||
     midInnerAfterOk.slice.steerPending != 0 ||
     !remAfterOk.isEmpty ||
     allNotes.map (·.noteId) != #["uuid-note-001", "uuid-note-002", "uuid-note-003"] ||
     allNotes.any (fun n => n.flushedAt?.isNone) then
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 retry FIFO order or post-ack flush settlement failed: order={repr retryOrder} all={repr allNotes}"
    return 1

  -- Lost CAS after a successful inject (`flushed_at` committed concurrently inside `injectFn` before post-inject CAS)
  -- MUST NOT report the note as flushed by this caller, and MUST leave the winner's `flushed_at` timestamp untouched.
  let .ok lostNote ← enqueueOperatorNote store.askDb "uuid-note-lost-cas" "m-midturn-lost" "Lost CAS steer" 40 "2026-11-07T01:04:00Z"
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 lost-CAS note enqueue failed"; return 1
  let .ok hLost ← mkHarnessSessionHandle "m-midturn-lost" .claudeCode 1 | return 1
  let .ok _ ← applySessionOp hLost .confirmReady 1 | return 1
  let .ok _ ← applySessionOp hLost .beginTurn 1 | return 1
  let .ok _ ← stepStandardHarnessLine hLost 1 "{\"type\":\"tool_call\",\"id\":\"c-lost-1\",\"name\":\"bash\"}" | return 1
  let .ok _ ← stepStandardHarnessLine hLost 1 "{\"type\":\"tool_result\",\"tool_use_id\":\"c-lost-1\",\"output\":\"done\"}" | return 1
  let preInjectPendingRef ← IO.mkRef false
  let lostFlush ← flushPendingOperatorNotesBetweenTools store.askDb hLost 1 "2026-11-07T01:05:00Z" (fun note => do
    -- Also verify `flushed_at` is STILL NULL inside `injectFn` BEFORE receipt is returned!
    let .ok duringInject ← listPendingOperatorNotes store.askDb "m-midturn-lost"
      | return .error "pending_query_during_inject_failed"
    if duringInject.any (fun n => n.noteId == note.noteId && n.flushedAt?.isNone) then
      preInjectPendingRef.set true
    -- Simulate concurrent caller winning the CAS right before our `injectFn` returns its receipt
    let raceWin ← withImmediateTx store.askDb do
      execParamQueryUnlocked store.askDb
        "UPDATE operator_notes SET flushed_at=?2, delivery_tries=delivery_tries+1 WHERE note_id=?1 AND (flushed_at IS NULL OR flushed_at = '');"
        #[note.noteId, "2026-11-07T01:04:30Z"]
    if let .error e := raceWin then
      return .error s!"race_winner_failed:{e}"
    return .ok { receiptId := s!"ack-{note.noteId}" })
  let wasPendingBeforeReceipt ← preInjectPendingRef.get
  if !wasPendingBeforeReceipt then
    IO.eprintln "[orb-core-test] FAIL: SM-18 flushed_at was set before injectFn returned receipt"
    return 1
  match lostFlush with
  | .error e =>
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 lost note CAS returned error: {e}"
    return 1
  | .ok summary =>
    if summary.flushedNoteIds.contains "uuid-note-lost-cas" || summary.remainingCount != 0 then
      IO.eprintln s!"[orb-core-test] FAIL: SM-18 lost note CAS reported note flushed by this caller: {repr summary}"
      return 1
  let .ok allLost ← listAllOperatorNotes store.askDb "m-midturn-lost" | return 1
  if allLost.size != 1 || allLost[0]!.noteId != lostNote.noteId ||
     allLost[0]!.createdAtSeq != 40 || allLost[0]!.deliveryTries != 1 ||
     allLost[0]!.flushedAt? != some "2026-11-07T01:04:30Z" then
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 lost note CAS rewrote flushed_at or tries: {repr allLost}"
    return 1

  -- Fail-closed error propagation in `bootstrapAskSidecarOnStartup`:
  -- Case 1: unopen/null SQLite handle (`handle = 0`) MUST propagate `.error` rather than masking as `.ok (0, _)`.
  let bogusMu ← Std.Mutex.new ()
  let bogusDb : SqliteDb := { handle := 0, path := s!"{tmpRoot}/null-ask.db", mu := bogusMu }
  if (← bootstrapAskSidecarOnStartup bogusDb sbxRoot).isOk then
    IO.eprintln "[orb-core-test] FAIL: SM-18 bootstrapAskSidecarOnStartup masked null-handle SQLite error"
    return 1
  -- Case 2: `ensureAskMidturnSchema` succeeds (`CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` on `main`),
  -- while a `TEMP VIEW operator_notes` without `flushed_at` causes `SELECT COUNT(*) FROM operator_notes WHERE flushed_at IS NULL ...`
  -- inside `bootstrapAskSidecarOnStartup` to fail in SQLite, proving the query error propagates fail-closed.
  let badAskPath := s!"{tmpRoot}/bad-query-ask.db"
  let .ok badAskDb ← openSqliteDb badAskPath
    "CREATE TABLE operator_notes (note_id TEXT PRIMARY KEY, mission_id TEXT NOT NULL, flushed_at TEXT, created_at_seq INTEGER); CREATE TEMP VIEW operator_notes AS SELECT 1 AS broken_col;"
    | do IO.eprintln "[orb-core-test] FAIL: SM-18 openSqliteDb bad-query-ask.db failed"; return 1
  let badBootRes ← bootstrapAskSidecarOnStartup badAskDb sbxRoot
  sqliteCloseRaw badAskDb.handle
  if badBootRes.isOk then
    IO.eprintln s!"[orb-core-test] FAIL: SM-18 bootstrapAskSidecarOnStartup masked COUNT(*) SQLite query error: {repr badBootRes}"
    return 1

  -- 6. Round-4 regressions (`SM-15`..`SM-18`):
  -- 6a. Eager `openCoreStore` DDL initialization (`operator_notes`, `idx_operator_notes_pending`, `harness_continuity`,
  --     `idx_harness_continuity_reconcile`) WITHOUT calling `ensureAskMidturnSchema` or `ensureHarnessContinuitySchema`
  --     first, plus live `runCoreServer` startup wiring (`bootstrapAskSidecarOnStartup` + `ask-sandbox-*` GC).
  let eagerRoot := s!"{tmpRoot}/eager-r4c-store"
  let .ok eagerStore ← openCoreStore eagerRoot
    | do IO.eprintln "[orb-core-test] FAIL: R4-C openCoreStore eager-r4c-store failed"; return 1
  let .ok eagerContTables ← execParamQuery eagerStore.missionsDb
    "SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name IN ('harness_continuity','idx_harness_continuity_reconcile') ORDER BY name ASC;" #[]
    | do closeCoreStore eagerStore; IO.eprintln "[orb-core-test] FAIL: R4-C sqlite_master eager missions.db query failed"; return 1
  let .ok eagerAskTables ← execParamQuery eagerStore.askDb
    "SELECT name FROM sqlite_master WHERE type IN ('table','index') AND name IN ('operator_notes','idx_operator_notes_pending') ORDER BY name ASC;" #[]
    | do closeCoreStore eagerStore; IO.eprintln "[orb-core-test] FAIL: R4-C sqlite_master eager ask.db query failed"; return 1
  closeCoreStore eagerStore
  if eagerContTables.size != 3 ||
     eagerContTables[1]! != #["harness_continuity"] ||
     eagerContTables[2]! != #["idx_harness_continuity_reconcile"] ||
     eagerAskTables.size != 3 ||
     eagerAskTables[1]! != #["idx_operator_notes_pending"] ||
     eagerAskTables[2]! != #["operator_notes"] then
    IO.eprintln s!"[orb-core-test] FAIL: R4-C openCoreStore did not eagerly materialize R4-C DDL: cont={repr eagerContTables} ask={repr eagerAskTables}"
    return 1

  let srvWorkDir := s!"{tmpRoot}/live-srv-work"
  let srvAskTmp := System.FilePath.mk s!"{tmpRoot}/live-srv-ask-tmp"
  let srvOrphan := srvAskTmp / "ask-sandbox-srv-orphan-77"
  let srvKeep := srvAskTmp / "unrelated-srv-scratch"
  IO.FS.createDirAll (srvOrphan / "sub")
  IO.FS.writeFile (srvOrphan / "sub" / "leak.txt") "orphan-bytes"
  IO.FS.createDirAll srvKeep
  let srvExitCode ← runCoreServer {
    host := "127.0.0.1"
    port := 0
    workingDir := srvWorkDir
    devMode := true
    askSandboxTmpRoot := srvAskTmp.toString
  } (some 0)
  let srvOrphanAfter ← OrbBin.PosixExt.statPath srvOrphan.toString
  let srvKeepAfter ← OrbBin.PosixExt.statPath srvKeep.toString
  if srvExitCode != 0 || srvOrphanAfter.exists_ || !srvKeepAfter.exists_ then
    IO.eprintln s!"[orb-core-test] FAIL: R4-C runCoreServer did not run bootstrapAskSidecarOnStartup / ask-sandbox-* GC: code={srvExitCode} orphan={srvOrphanAfter.exists_}"
    return 1

  -- 6b. Standalone raw `SqliteDb` idempotent schema guards on continuity & operator-note entry points
  --     (`openSqliteDb path ""` with zero pre-existing tables -> no `no such table` error).
  let .ok rawContDb1 ← openSqliteDb s!"{tmpRoot}/standalone-cont-1.db" ""
    | do IO.eprintln "[orb-core-test] FAIL: openSqliteDb standalone-cont-1.db failed"; return 1
  let rawLoadRes ← loadHarnessContinuity? rawContDb1 "m-raw-1"
  let rawRecRes ← reconcileHarnessContinuityOnRestart rawContDb1 "m-raw-1" "t-raw-0"
  sqliteCloseRaw rawContDb1.handle
  let rawContOk :=
    match rawLoadRes, rawRecRes with
    | .ok none, .ok none => true
    | _, _ => false
  if !rawContOk then
    IO.eprintln s!"[orb-core-test] FAIL: standalone load/reconcile failed on bare SqliteDb: load={repr rawLoadRes} rec={repr rawRecRes}"
    return 1

  let .ok rawContDb2 ← openSqliteDb s!"{tmpRoot}/standalone-cont-2.db" ""
    | do IO.eprintln "[orb-core-test] FAIL: openSqliteDb standalone-cont-2.db failed"; return 1
  let rawBindRes ← bindHarnessContinuitySession rawContDb2 "m-raw-2" .grok 1 "grok-sess-1" "t-raw-1"
  sqliteCloseRaw rawContDb2.handle
  if !rawBindRes.isOk then
    IO.eprintln s!"[orb-core-test] FAIL: standalone bindHarnessContinuitySession failed on bare SqliteDb: {repr rawBindRes}"
    return 1

  let .ok rawAskDb1 ← openSqliteDb s!"{tmpRoot}/standalone-ask-1.db" ""
    | do IO.eprintln "[orb-core-test] FAIL: openSqliteDb standalone-ask-1.db failed"; return 1
  let rawPendEmpty ← listPendingOperatorNotes rawAskDb1 "m-raw-ask"
  let rawAllEmpty ← listAllOperatorNotes rawAskDb1 "m-raw-ask"
  let .ok hRawAsk ← mkHarnessSessionHandle "m-raw-ask" .claudeCode 1 | do sqliteCloseRaw rawAskDb1.handle; return 1
  let .ok _ ← applySessionOp hRawAsk .confirmReady 1 | do sqliteCloseRaw rawAskDb1.handle; return 1
  let .ok _ ← applySessionOp hRawAsk .beginTurn 1 | do sqliteCloseRaw rawAskDb1.handle; return 1
  let rawFlushEmpty ← flushPendingOperatorNotesBetweenTools rawAskDb1 hRawAsk 1 "2026-11-07T02:00:00Z"
    (fun _ => pure (.ok { receiptId := "unused" }))
  sqliteCloseRaw rawAskDb1.handle
  let rawAskOk :=
    match rawPendEmpty, rawAllEmpty, rawFlushEmpty with
    | .ok ps, .ok as, .ok fs => ps.isEmpty && as.isEmpty && fs.flushedNoteIds.isEmpty && fs.remainingCount == 0
    | _, _, _ => false
  if !rawAskOk then
    IO.eprintln s!"[orb-core-test] FAIL: standalone list/flush failed on bare SqliteDb: pend={repr rawPendEmpty} flush={repr rawFlushEmpty}"
    return 1

  let .ok rawAskDb2 ← openSqliteDb s!"{tmpRoot}/standalone-ask-2.db" ""
    | do IO.eprintln "[orb-core-test] FAIL: openSqliteDb standalone-ask-2.db failed"; return 1
  let rawEnqRes ← enqueueOperatorNote rawAskDb2 "raw-note-1" "m-raw-ask-2" "Standalone note" 1 "2026-11-07T02:01:00Z"
  sqliteCloseRaw rawAskDb2.handle
  if !rawEnqRes.isOk then
    IO.eprintln s!"[orb-core-test] FAIL: standalone enqueueOperatorNote failed on bare SqliteDb: {repr rawEnqRes}"
    return 1

  -- 6c. `stepStandardHarnessLine`: session-ID extraction, binding, foreign-session fencing (`sessionMatches == 0`),
  --     and Vibe ACP JSON-RPC (`session/new` + `session/update`) dispatch.
  let .ok hCodexFence ← mkHarnessSessionHandle "m-codex-fence" .codex 1
    | do IO.eprintln "[orb-core-test] FAIL: mkHarnessSessionHandle m-codex-fence failed"; return 1
  let .ok _ ← applySessionOp hCodexFence .confirmReady 1 | return 1
  let .ok _ ← applySessionOp hCodexFence .beginTurn 1 | return 1
  -- First line with `thread_id` binds `sessionId` / `expectedSessionId` and enters tool call (`toolDepth == 1`)
  let .ok (stCodexBound, _, codexEvs1) ← stepStandardHarnessLine hCodexFence 1
    "{\"type\":\"tool_call\",\"thread_id\":\"thr-bound-1\",\"id\":\"tc-cx-1\",\"name\":\"bash\"}"
    | do IO.eprintln "[orb-core-test] FAIL: stepStandardHarnessLine codex bind failed"; return 1
  if stCodexBound.sessionId != "thr-bound-1" || stCodexBound.openCode.expectedSessionId != "thr-bound-1" ||
     stCodexBound.slice.toolDepth != 1 || codexEvs1 != #[.ToolCall "m-codex-fence" "tc-cx-1" "bash"] then
    IO.eprintln s!"[orb-core-test] FAIL: stepStandardHarnessLine did not bind thread_id or increment toolDepth: {repr stCodexBound}"
    return 1
  -- Foreign `thread_id` (`thr-foreign-999`) MUST be fenced out (`sessionMatches == 0`):
  -- MUST NOT mutate `toolDepth`, `sawExplicitError`, `sessionId`, or emit events!
  let .ok (stCodexForeignTool, _, foreignToolEvs) ← stepStandardHarnessLine hCodexFence 1
    "{\"type\":\"tool_call\",\"thread_id\":\"thr-foreign-999\",\"id\":\"tc-spoof\",\"name\":\"rm\"}"
    | return 1
  let .ok (stCodexForeignErr, _, foreignErrEvs) ← stepStandardHarnessLine hCodexFence 1
    "{\"type\":\"result\",\"session_id\":\"thr-foreign-999\",\"is_error\":true,\"error\":\"spoofed-err\"}"
    | return 1
  if stCodexForeignTool.slice.toolDepth != 1 || !foreignToolEvs.isEmpty ||
     stCodexForeignErr.openCode.sawExplicitError || !foreignErrEvs.isEmpty ||
     stCodexForeignErr.sessionId != "thr-bound-1" then
    IO.eprintln s!"[orb-core-test] FAIL: stepStandardHarnessLine allowed foreign session line to mutate session state: {repr stCodexForeignErr}"
    return 1
  -- Matching `thread_id` completes `tc-cx-1` (`toolDepth -> 0`)
  let .ok (stCodexDoneTool, _, doneToolEvs) ← stepStandardHarnessLine hCodexFence 1
    "{\"type\":\"tool_result\",\"thread_id\":\"thr-bound-1\",\"tool_use_id\":\"tc-cx-1\",\"output\":\"clean\"}"
    | return 1
  if stCodexDoneTool.slice.toolDepth != 0 || doneToolEvs != #[.ToolResult "m-codex-fence" "tc-cx-1" "bash" "clean"] then
    IO.eprintln s!"[orb-core-test] FAIL: stepStandardHarnessLine rejected matching thread_id tool_result: {repr stCodexDoneTool}"
    return 1

  -- Vibe ACP JSON-RPC notifications (`method = "session/update"`, both flat and nested `params.update.content`)
  let .ok hVibe ← mkHarnessSessionHandle "m-vibe-acp" .vibe 1 | return 1
  let .ok _ ← applySessionOp hVibe .confirmReady 1 | return 1
  let .ok _ ← applySessionOp hVibe .beginTurn 1 | return 1
  let .ok (stVibe1, _, vibeEvs1) ← stepStandardHarnessLine hVibe 1
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"vibe-native-1\",\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"vibe-plan\"}}}}"
    | do IO.eprintln "[orb-core-test] FAIL: stepStandardHarnessLine Vibe thought failed"; return 1
  let .ok (stVibe2, _, vibeEvs2) ← stepStandardHarnessLine hVibe 1
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"sessionId\":\"vibe-native-1\",\"sessionUpdate\":\"agent_message_chunk\",\"text\":\"vibe-answer\"}"
    | do IO.eprintln "[orb-core-test] FAIL: stepStandardHarnessLine Vibe message failed"; return 1
  let .ok (stVibeForeign, _, vibeForeignEvs) ← stepStandardHarnessLine hVibe 1
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"sessionId\":\"vibe-foreign-2\",\"sessionUpdate\":\"agent_message_chunk\",\"text\":\"SPOOF\"}"
    | do IO.eprintln "[orb-core-test] FAIL: stepStandardHarnessLine Vibe foreign failed"; return 1
  if stVibe1.sessionId != "vibe-native-1" ||
     vibeEvs1 != #[.Thinking "m-vibe-acp" "vibe-plan" false] ||
     !stVibe2.parser.sawUserText ||
     vibeEvs2 != #[.TextDelta "m-vibe-acp" "vibe-answer"] ||
     !vibeForeignEvs.isEmpty ||
     stVibeForeign.sessionId != "vibe-native-1" then
    IO.eprintln s!"[orb-core-test] FAIL: Vibe ACP dispatch or session fencing failed in stepStandardHarnessLine: ev1={repr vibeEvs1} ev2={repr vibeEvs2} foreign={repr vibeForeignEvs}"
    return 1

  -- 6d. `stepOpenCodeDualChannel` `.sseSessionIdle`: `expectedSessionId` binding MUST be gated on
  --     `checkNormalizerAdmitted` so a duplicate `.sseSessionIdle "foreign_sid"` (`isDup == 1`) after an
  --     unattributed `.sseSessionIdle ""` NEVER poisons `expectedSessionId` or blocks legitimate CLI lines!
  let .ok hDupIdle ← mkHarnessSessionHandle "m-oc-dupidle-bind" .openCode 1 | return 1
  let .ok _ ← applySessionOp hDupIdle .confirmReady 1 | return 1
  let .ok _ ← applySessionOp hDupIdle .beginTurn 1 | return 1
  -- First, unattributed `.sseSessionIdle ""` sets `sawSseIdle := true` while `expectedSessionId` stays `""`.
  let .ok (afterUnattrIdle, _, _) ← stepOpenCodeHandleInput hDupIdle 1
    (.sseSessionIdle "") (requireCliExitForTurnDone := true) | return 1
  -- Next, duplicate `.sseSessionIdle "ses_poison_foreign"` AND duplicate raw SSE `session.idle` chunk arrive
  -- (`isDup == 1` -> rejected by normalizer!). Neither may poison `expectedSessionId`!
  let .ok (afterDupForeignIdle, _, _) ← stepOpenCodeHandleInput hDupIdle 1
    (.sseSessionIdle "ses_poison_foreign") (requireCliExitForTurnDone := true) | return 1
  let .ok (afterDupForeignSseChunk, _, _) ← stepOpenCodeHandleInput hDupIdle 1
    (.sseChunk "" "data: {\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_poison_chunk\"}}\n")
    (requireCliExitForTurnDone := true) | return 1
  if !afterUnattrIdle.openCode.sawSseIdle || !afterUnattrIdle.openCode.expectedSessionId.isEmpty ||
     !afterDupForeignIdle.openCode.expectedSessionId.isEmpty || !afterDupForeignIdle.sessionId.isEmpty ||
     !afterDupForeignSseChunk.openCode.expectedSessionId.isEmpty || !afterDupForeignSseChunk.sessionId.isEmpty then
    IO.eprintln s!"[orb-core-test] FAIL: rejected duplicate .sseSessionIdle / SSE idle chunk poisoned expectedSessionId: {repr afterDupForeignSseChunk.openCode}"
    return 1
  -- Now legitimate CLI output with `"sessionID":"ses_legit_1"` arrives and MUST bind `"ses_legit_1"` and emit its event!
  let .ok (afterLegitCli, _, legitCliEvs) ← stepOpenCodeHandleInput hDupIdle 1
    (.cliJsonLine "{\"type\":\"text\",\"sessionID\":\"ses_legit_1\",\"part\":{\"type\":\"text\",\"text\":\"Legit CLI output\"}}")
    (requireCliExitForTurnDone := true) | return 1
  if afterLegitCli.openCode.expectedSessionId != "ses_legit_1" ||
     afterLegitCli.sessionId != "ses_legit_1" ||
     legitCliEvs != #[.TextDelta "m-oc-dupidle-bind" "Legit CLI output"] then
    IO.eprintln s!"[orb-core-test] FAIL: legitimate CLI line was blocked after duplicate sseSessionIdle: {repr afterLegitCli.openCode} evs={repr legitCliEvs}"
    return 1
  return 0

set_option maxHeartbeats 1000000 in
set_option maxRecDepth 8000 in
private def runMultiUserCoreTests (prodValid : CoreConfig) : IO UInt32 := do
  let muTs ← IO.monoNanosNow
  let muRoot := s!"/tmp/orb-core-multiuser-{muTs}"
  let .ok store ← openCoreStore muRoot
    | do IO.eprintln "[orb-core-test] FAIL: multiuser openCoreStore failed"; return 1
  let .ok mStore ← openManagedComputeStore s!"{muRoot}/managed_compute.db"
    | do closeCoreStore store; IO.eprintln "[orb-core-test] FAIL: multiuser openManagedComputeStore failed"; return 1
  let fail (msg : String) : IO UInt32 := do
    closeManagedComputeStore mStore
    closeCoreStore store
    discard <| (IO.FS.removeDirAll muRoot).toBaseIO
    IO.eprintln s!"[orb-core-test] FAIL (multiuser): {msg}"
    return 1

  -- 1. PBKDF2-HMAC-SHA256 hash/verify & legacy row seeding BEFORE bootstrap
  let hSample ← hashPasswordPbkdf2 "correct-horse-battery-staple"
  let vOk ← verifyPasswordPbkdf2 "correct-horse-battery-staple" hSample
  let vBad ← verifyPasswordPbkdf2 "wrong-horse-battery-staple" hSample
  if !vOk || vBad then
    return (← fail "PBKDF2 password verification mismatch")

  let nowSec ← coreEpochSec
  let .ok () ← upsertMission store {
    id := "m-legacy-boot", title := "Legacy Pre-Bootstrap Mission", status := "completed",
    backend := "opencode", modelOverride := "", workingDirectory := muRoot,
    project := "legacy-proj", updatedAt := "2026-11-08T00:00:00Z", ownerUserId := ""
  } | return (← fail "seed legacy mission failed")
  if let .ok putLeg := parseInboxPut "preferences"
      (.obj #[("clientId", .str "c-leg"), ("mutationSeq", .num "1"), ("expectedVersion", .num "0"),
              ("aiSummary", .bool true), ("includeAutonomous", .bool false), ("model", .str "gpt-5")]) then
    discard <| putInboxState store putLeg none

  discard <| saveManagedFleetConfig mStore true true 50000 0 10
  let initFleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 50000, spentTodayCents := 0, maxConcurrent := 10 }
  let .ok _ ← provisionReadyFixture mStore initFleet {
    id := "vm-legacy-1", sandboxName := "orb-managed-leg", provider := "boat", size := "small",
    status := "ready", nodeBootEpoch := store.bootEpoch, deletableAtSec := nowSec, ownerUserId := ""
  } nowSec | return (← fail "seed legacy managed VM failed")

  let seedAdmins := #[("admin", prodValid.dashboardPassword), ("opsadmin", "opsadmin-strong-pass-123")]
  let .ok bootAdminId ← bootstrapUsersAndBackfill store seedAdmins s!"{nowSec}"
    | return (← fail "bootstrapUsersAndBackfill failed")
  let .ok () ← backfillManagedMachineOwner mStore bootAdminId
    | return (← fail "backfillManagedMachineOwner failed")
  -- Idempotence check: second bootstrap returns exact same admin id and does not duplicate users
  let .ok bootAdminId2 ← bootstrapUsersAndBackfill store seedAdmins s!"{nowSec}"
    | return (← fail "idempotent bootstrapUsersAndBackfill failed")
  if bootAdminId.isEmpty || bootAdminId != bootAdminId2 then
    return (← fail s!"bootstrap admin id mismatch: {bootAdminId} vs {bootAdminId2}")
  let some legAfter ← getMission? store "m-legacy-boot"
    | return (← fail "legacy mission disappeared after bootstrap")
  let .ok mfBoot ← loadManagedFleet mStore true true 50000 0 10
    | return (← fail "loadManagedFleet after backfill failed")
  if legAfter.ownerUserId != bootAdminId ||
     (mfBoot.machines[0]?).map (·.ownerUserId) != some bootAdminId then
    return (← fail "bootstrap backfill did not assign legacy mission/VM to bootstrapAdminId")
  let managedRef ← IO.mkRef mfBoot

  let chainsRef ← IO.mkRef (#[
    {
      id := "default"
      name := "Default Chain"
      targets := #[
        { accountId := "prov-a", provider := "openai", baseUrl := "http://127.0.0.1:9999", apiKey := "sk-a", modelId := "gpt-5" },
        { accountId := "prov-b", provider := "anthropic", baseUrl := "http://127.0.0.1:9998", apiKey := "sk-b", modelId := "claude-4" }
      ]
    }
  ] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (1 : UInt64)
  let bunkerRef ← IO.mkRef (0 : UInt8)
  let telSink ← newTelemetrySink
  let voiceSlots ← newVoiceRelaySlots
  let app : CoreAppState := {
    cfg := { prodValid with workingDir := muRoot, usersJson := "" }
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef
    proxyCooldownsRef := cooldownsRef
    seqRef := seqRef
    bunkerStateRef? := some bunkerRef
    managedStore? := some mStore
    managedProvisioningOverride? := some (ManagedProvisioningTests.mockPolicyProvider mStore "leanci",
      { coreUrl := "https://core.example", script := "#!/bin/sh\nexit 0\n" })
    bootstrapAdminId := bootAdminId
    telemetrySink? := some telSink
    voiceSlots? := some voiceSlots
    proxyMockTransport? := some (fun tgt => do
      let body := s!"\{\"id\":\"resp-1\",\"acct\":{jsonEscape tgt.accountId},\"usage\":\{\"input_tokens\":10000,\"output_tokens\":10000}}"
      return .ok {
        status := 200
        headers := #[("Content-Type", "application/json"), ("X-Orb-Cost-Cents", "30")]
        body := body.toUTF8
      })
  }

  let sendReq (method target tok body : String) (retryKey : String := "") : IO (Nat × String × Array (String × String)) := do
    let authHdr := (if tok.isEmpty then "" else s!"Authorization: Bearer {tok}\r\n") ++
      (if retryKey.isEmpty then "" else s!"Idempotency-Key: {retryKey}\r\n")
    let raw :=
      if body.isEmpty then
        s!"{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authHdr}\r\n"
      else
        s!"{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authHdr}Content-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
    match parseRequest raw.toUTF8 none with
    | .error e => return (0, s!"parse_err:{e}", #[])
    | .ok req =>
      match ← dispatchCoreRequest app req nowSec with
      | .error _ => return (0, "dispatch_err", #[])
      | .ok resp => return (resp.status, (String.fromUTF8? resp.body).getD "", resp.extraHdrs)

  -- 2. Admin login (`orb-jwt-v2`), `/api/auth/me`, and `/api/admin/users` CRUD
  let (admLoginSt, admLoginBody, _) ← sendReq "POST" "/api/auth/login" "" s!"\{\"username\":\"admin\",\"password\":{jsonEscape prodValid.dashboardPassword}}"
  let admLoginJv := (OrbBin.Json.parse admLoginBody).toOption.getD (.obj #[])
  let adminTok := (admLoginJv.fieldStr? "token").getD ""
  if admLoginSt != 200 || !adminTok.startsWith "orb-jwt-v2:" then
    return (← fail s!"admin login failed: st={admLoginSt} body={admLoginBody}")

  let (meAdmSt, meAdmBody, _) ← sendReq "GET" "/api/auth/me" adminTok ""
  if meAdmSt != 200 || (meAdmBody.splitOn "\"role\":\"admin\"").length != 2 ||
     (meAdmBody.splitOn "\"can_manage_users\":true").length != 2 then
    return (← fail s!"admin /api/auth/me mismatch: {meAdmBody}")

  -- Create `alice` (member, cap = 50 cents) and `bob` (member)
  let (cAliceSt, cAliceBody, _) ← sendReq "POST" "/api/admin/users" adminTok
    "{\"username\":\"alice\",\"password\":\"alice-passphrase-1234\",\"role\":\"member\",\"daily_spend_cap_cents\":50}"
  let aliceJv := (OrbBin.Json.parse cAliceBody).toOption.getD (.obj #[])
  let aliceId := (aliceJv.fieldStr? "id").getD ""
  let aliceUnix := (aliceJv.fieldStr? "unix_username").getD ""
  let (cBobSt, cBobBody, _) ← sendReq "POST" "/api/admin/users" adminTok
    "{\"username\":\"bob\",\"password\":\"bob-passphrase-123456\",\"role\":\"member\"}"
  let bobJv := (OrbBin.Json.parse cBobBody).toOption.getD (.obj #[])
  let bobId := (bobJv.fieldStr? "id").getD ""
  if cAliceSt != 201 || aliceId.isEmpty || aliceUnix != "orb-alice" || cBobSt != 201 || bobId.isEmpty then
    return (← fail s!"create alice/bob failed: alice={cAliceSt}:{cAliceBody} bob={cBobSt}:{cBobBody}")

  -- Reserved unix_username (`root`) rejected with 400
  let (badRootSt, _, _) ← sendReq "POST" "/api/admin/users" adminTok
    "{\"username\":\"mallory\",\"password\":\"mallory-passphrase-1234\",\"role\":\"member\",\"unix_username\":\"root\"}"
  if badRootSt != 400 then
    return (← fail s!"reserved unix_username root was not rejected: {badRootSt}")

  -- Login as `alice` & `bob`
  let (alLogSt, alLogBody, _) ← sendReq "POST" "/api/auth/login" "" "{\"username\":\"alice\",\"password\":\"alice-passphrase-1234\"}"
  let aliceTok0 := ((OrbBin.Json.parse alLogBody).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  let (boLogSt, boLogBody, _) ← sendReq "POST" "/api/auth/login" "" "{\"username\":\"bob\",\"password\":\"bob-passphrase-123456\"}"
  let bobTok := ((OrbBin.Json.parse boLogBody).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  if alLogSt != 200 || boLogSt != 200 || !aliceTok0.startsWith "orb-jwt-v2:" || !bobTok.startsWith "orb-jwt-v2:" then
    return (← fail "alice/bob login failed")

  -- Reserved sealing authenticates an operator before any vault call. Unknown
  -- provider + real admin tests dispatch without ever resolving a real key.
  let (sealUnknown, _, _) ← sendReq "POST" "/api/managed-machines/providers/unknown/seal" adminTok ""
  let (sealMember, _, _) ← sendReq "POST" "/api/managed-machines/providers/leanci/seal" aliceTok0 ""
  let (sealAnon, _, _) ← sendReq "POST" "/api/managed-machines/providers/leanci/seal" "" ""
  let (sealMission, _, _) ← sendReq "POST" "/api/managed-machines/providers/leanci/seal" "mcp1.invalid" ""
  if sealUnknown != 400 || sealMember != 403 || sealAnon != 401 || sealMission != 401 then
    return (← fail s!"reserved sealing route authority failed: {sealUnknown}/{sealMember}/{sealAnon}/{sealMission}")
  let .ok openDevReq := parseRequest
      "POST /api/managed-machines/providers/leanci/seal HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toUTF8 none
    | return (← fail "open dev seal request parse failed")
  let .ok openDevSeal ← dispatchCoreRequest { app with cfg := { app.cfg with devMode := true } } openDevReq nowSec
    | return (← fail "open dev seal dispatch failed")
  if openDevSeal.status != 401 then return (← fail "dev-mode bypass granted vault sealing authority")
  let sealWith (state : CoreAppState) (token : String) : IO Nat := do
    let raw := s!"POST /api/managed-machines/providers/leanci/seal HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\n\r\n"
    let .ok request := parseRequest raw.toUTF8 none | return 0
    let .ok response ← dispatchCoreRequest state request nowSec | return 0
    return response.status
  let configuredMember := { app with cfg := { app.cfg with
    usersJson := "[{\"username\":\"alice\",\"password\":\"alice-passphrase-1234\"}]" } }
  if (← sealWith configuredMember "alice-passphrase-1234") != 401 then
    return (← fail "configured member raw password granted sealing authority")
  let openDev := { app with cfg := { app.cfg with devMode := true } }
  let devLoginBody := "{\"username\":\"admin\",\"password\":\"wrong-password\"}"
  let devLoginRaw := s!"POST /api/auth/login HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {devLoginBody.utf8ByteSize}\r\n\r\n{devLoginBody}"
  let .ok devLoginReq := parseRequest devLoginRaw.toUTF8 none | return (← fail "dev login parse failed")
  let .ok devLoginResp ← dispatchCoreRequest openDev devLoginReq nowSec | return (← fail "dev login dispatch failed")
  let devToken := ((OrbBin.Json.parse ((String.fromUTF8? devLoginResp.body).getD "")).toOption.getD .null).fieldStr? "token" |>.getD ""
  if devToken.isEmpty || (← sealWith openDev devToken) != 403 then
    return (← fail "open dev login token granted sealing authority")
  let fallbackState := { app with cfg := { app.cfg with jwtSecret := "" } }
  let fallbackToken := mintSessionTokenV2 "dev-mode-ephemeral-jwt-secret-012345"
    app.bootstrapAdminId "admin" 1 (nowSec + 3600)
  if (← sealWith fallbackState fallbackToken) != 403 then
    return (← fail "fallback signing key granted sealing authority")
  let .ok () ← OrbBin.PosixExt.ensurePrivateDir0700 (managedSecretDir store.rootDir)
    | return (← fail "seal contention directory fixture failed")
  let sealLock ← OrbBin.PosixExt.flockExclusiveNb (managedSecretDir store.rootDir / "seal.lock").toString
  if sealLock == 0xFFFFFFFF || sealLock == 0xFFFFFFFE then return (← fail "seal contention lock fixture failed")
  let sealConflict ← try
      let (status, _, _) ← sendReq "PUT" "/api/managed-machines/providers/leanci" adminTok
        "{\"api_key\":\"synthetic-contention-key\"}"
      pure status
    finally OrbBin.PosixExt.closeFdRaw sealLock.toInt32
  if sealConflict != 409 then return (← fail "provider update silently ignored seal lock contention")
  -- A credential edit must not turn the global fleet back on merely because
  -- Boat's independent switch was left on when the global switch was disabled.
  let priorFleet ← app.managedRef.get
  let (disableFleetStatus, _, _) ← sendReq "PUT" "/api/managed-machines/settings" adminTok
    "{\"enabled\":false,\"boat_enabled\":true}"
  let (credentialStatus, _, _) ← sendReq "PATCH" "/api/managed-machines/providers/leanci" adminTok
    "{\"api_key\":\"synthetic-credential-only-fixture\"}"
  let (readFleetStatus, readFleetBody, _) ← sendReq "GET" "/api/managed-machines/settings" adminTok ""
  let observedFleet := (OrbBin.Json.parse readFleetBody).toOption.getD .null
  let restoreBody := OrbBin.Json.renderCompact (.obj #[("enabled", .bool priorFleet.enabled), ("boat_enabled", .bool priorFleet.boatEnabled)])
  let (restoreStatus, _, _) ← sendReq "PUT" "/api/managed-machines/budget" adminTok restoreBody
  if disableFleetStatus != 200 || credentialStatus != 200 || readFleetStatus != 200 || restoreStatus != 200 ||
      observedFleet.fieldBool? "enabled" != some false || observedFleet.fieldBool? "boat_enabled" != some true then
    return (← fail s!"credential-only edit changed independent fleet enablement: {disableFleetStatus}/{credentialStatus}/{readFleetStatus}/{restoreStatus}: {readFleetBody}")
  let (providersStatus, providersBody, _) ← sendReq "GET" "/api/managed-machines/providers" adminTok ""
  let (machinesStatus, machinesBody, _) ← sendReq "GET" "/api/managed-machines" adminTok ""
  let dedicatedProviders := (OrbBin.Json.parse providersBody).toOption.bind (·.asArr?) |>.getD #[]
  let embeddedProviders := ((OrbBin.Json.parse machinesBody).toOption.getD .null).fieldArr? "providers" |>.getD #[]
  let dedicatedLean := dedicatedProviders.find? (fun p => p.fieldStr? "provider" == some "leanci")
  let embeddedLean := embeddedProviders.find? (fun p => p.fieldStr? "provider" == some "leanci")
  if providersStatus != 200 || machinesStatus != 200 || dedicatedProviders.size != knownProviders.size ||
      (dedicatedLean.bind (·.fieldBool? "configured")) != some true || dedicatedLean != embeddedLean then
    return (← fail "reserved provider route or embedded catalog projection diverged")

  -- Session epoch revocation: password reset bumps `session_epoch`, immediately invalidating `aliceTok0`!
  let (rstSt, _, _) ← sendReq "POST" s!"/api/admin/users/{aliceId}/reset-password" adminTok "{\"password\":\"alice-newpass-123456\"}"
  let (staleMeSt, _, _) ← sendReq "GET" "/api/auth/me" aliceTok0 ""
  let (alLog2St, alLog2Body, _) ← sendReq "POST" "/api/auth/login" "" "{\"username\":\"alice\",\"password\":\"alice-newpass-123456\"}"
  let aliceTok := ((OrbBin.Json.parse alLog2Body).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  if rstSt != 200 || staleMeSt != 401 || alLog2St != 200 || aliceTok.isEmpty then
    return (← fail s!"session_epoch revocation failed: rst={rstSt} staleMe={staleMeSt} reLogin={alLog2St}")

  -- Legacy mobile route alias `/api/admin/users/:id/password` with `new_password` also rotates epoch
  let (bobPwdAliasSt, _, _) ← sendReq "POST" s!"/api/admin/users/{bobId}/password" adminTok "{\"new_password\":\"bob-passphrase-654321\"}"
  let (bobStaleMeSt, _, _) ← sendReq "GET" "/api/auth/me" bobTok ""
  let (boLog2St, boLog2Body, _) ← sendReq "POST" "/api/auth/login" "" "{\"username\":\"bob\",\"password\":\"bob-passphrase-654321\"}"
  let bobTok := ((OrbBin.Json.parse boLog2Body).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  if bobPwdAliasSt != 200 || bobStaleMeSt != 401 || boLog2St != 200 || bobTok.isEmpty then
    return (← fail s!"/password alias revocation failed: st={bobPwdAliasSt} stale={bobStaleMeSt} reLogin={boLog2St}")

  -- Self password change (`/api/auth/change-password`) works and bumps epoch; re-login `alice`
  let (chgSt, _, _) ← sendReq "POST" "/api/auth/change-password" aliceTok
    "{\"current_password\":\"alice-newpass-123456\",\"new_password\":\"alice-finalpass-1234\"}"
  let (staleAfterChgSt, _, _) ← sendReq "GET" "/api/auth/me" aliceTok ""
  let (_, alLog3Body, _) ← sendReq "POST" "/api/auth/login" "" "{\"username\":\"alice\",\"password\":\"alice-finalpass-1234\"}"
  let aliceTok := ((OrbBin.Json.parse alLog3Body).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  if chgSt != 200 || staleAfterChgSt != 401 || aliceTok.isEmpty then
    return (← fail s!"change-password failed: chg={chgSt} stale={staleAfterChgSt}")

  -- Member gets `403` on `/api/admin/users`, `/api/system/deploy`, global provider mutations
  let (memUsersSt, _, _) ← sendReq "GET" "/api/admin/users" aliceTok ""
  let (memDeploySt, _, _) ← sendReq "POST" "/api/system/deploy" aliceTok "{\"unit\":\"sandboxed-sh\"}"
  let (memAddProvSt, _, _) ← sendReq "POST" "/api/ai/providers" aliceTok "{\"name\":\"Evil\",\"provider_type\":\"openai\",\"api_key\":\"sk-1\"}"
  if memUsersSt != 403 || memDeploySt != 403 || memAddProvSt != 403 then
    return (← fail s!"member admin-route confinement failed: users={memUsersSt} deploy={memDeploySt} prov={memAddProvSt}")

  -- Backend model catalog & routing catalog: Opus 5.5 is default (index 0), Fable 5.2 + Mythos 5.2 + Meta Muse Wonder/Ember present, Fable 5.1 absent from picker,
  -- and non-admin `member` callers never receive internal custom-provider `base_url` hostnames or inline chain secrets on `/api/providers*` or `/api/model-routing/chains`.
  let savedChainsBeforeCatalogCheck ← chainsRef.get
  let (custAddSt, _, _) ← sendReq "POST" "/api/ai/providers" adminTok
    "{\"id\":\"cust-vllm\",\"name\":\"Internal VLLM\",\"provider_type\":\"custom\",\"base_url\":\"http://vllm-internal.corp.local:8000\",\"api_key\":\"sk-vllm-1\",\"enabled\":true,\"custom_models\":[{\"id\":\"qwen3-coder\",\"name\":\"Qwen 3 Coder\"}]}"
  let (chainAddSt, _, _) ← sendReq "POST" "/api/model-routing/chains" adminTok
    "{\"id\":\"cust-chain\",\"name\":\"Custom Chain\",\"models\":[{\"provider_id\":\"custom:cust-vllm\",\"model_id\":\"qwen3-coder\",\"base_url\":\"http://vllm-internal.corp.local:8000\",\"api_key\":\"sk-inline-chain-secret\",\"rpm_limit\":120}]}"
  let (bmSt, bmBody, _) ← sendReq "GET" "/api/providers/backend-models" adminTok ""
  let (alBmSt, alBmBody, _) ← sendReq "GET" "/api/providers/backend-models" aliceTok ""
  let bmJv := (OrbBin.Json.parse bmBody).toOption.getD (.obj #[])
  let ccModels := ((bmJv.fieldOrNull "backends").fieldArr? "claudecode").getD #[]
  let firstCcVal := (ccModels[0]?.bind (·.fieldStr? "value")).getD ""
  let (catSt, catBody, _) ← sendReq "GET" "/api/providers" adminTok ""
  let (alCatSt, alCatBody, _) ← sendReq "GET" "/api/providers" aliceTok ""
  let (admChainsSt, admChainsBody, _) ← sendReq "GET" "/api/model-routing/chains" adminTok ""
  let (alChainsSt, alChainsBody, _) ← sendReq "GET" "/api/model-routing/chains" aliceTok ""
  let (alResolveSt, _, _) ← sendReq "GET" "/api/model-routing/chains/cust-chain/resolve" aliceTok ""
  -- When `alice` disables `cust-vllm` in her preferences, both `/api/providers` and `/api/providers/backend-models` omit `qwen3-coder` for `alice`
  let (alDisableCustSt, _, _) ← sendReq "PUT" "/api/ai/providers/cust-vllm/preference" aliceTok "{\"enabled\":false}"
  let (_, alCatDisabledBody, _) ← sendReq "GET" "/api/providers" aliceTok ""
  let (_, alBmDisabledBody, _) ← sendReq "GET" "/api/providers/backend-models" aliceTok ""
  -- Clean up temporary custom provider & chain and restore `chainsRef` before section 6's proxy routing test
  let (custDelSt, _, _) ← sendReq "DELETE" "/api/ai/providers/cust-vllm" adminTok ""
  discard <| execParamQuery store.missionsDb "DELETE FROM model_routing_chains WHERE id=?1;" #["cust-chain"]
  discard <| publishRoutingChainsUpdate app savedChainsBeforeCatalogCheck
  let museTargets := parseChainTargetsJson "[{\"provider_id\":\"muse\",\"model_id\":\"muse-wonder-1.0\"}]" #[]
  let agyTargets := parseChainTargetsJson "[{\"provider_id\":\"antigravity\",\"model_id\":\"agy-model-high\"},{\"provider_id\":\"antigravity\",\"model_id\":\"agy-demo-low\"}]" #[]
  let agyGrouped := OrbBin.ClaudeControl.groupAntigravityModels #[
    ("gemini-4-carbon-high", "Carbon (High)"),
    ("agy-model-low", "Carbon (Low)"),
    ("gemini-4-argon-medium", "Argon (Medium)")
  ]
  let (agyCliMdl, agyCliEff) := OrbBin.ClaudeControl.normalizeAntigravityCliModel "agy-model" (some "medium")
  if custAddSt != 201 || chainAddSt != 201 || custDelSt != 200 || alDisableCustSt != 200 ||
     bmSt != 200 || alBmSt != 200 || firstCcVal != "claude-opus-5-5" ||
     (bmBody.splitOn "claude-fable-5-2").length < 2 ||
     (bmBody.splitOn "claude-mythos-5-2").length < 2 ||
     (bmBody.splitOn "claude-fable-5-1").length != 1 ||
     (bmBody.splitOn "muse/muse-wonder-1.0").length < 2 ||
     (bmBody.splitOn "muse/muse-ember-1.0").length < 2 ||
     (alBmBody.splitOn "cust-vllm/qwen3-coder").length < 2 ||
     (alBmBody.splitOn "vllm-internal.corp.local").length != 1 ||
     (alBmDisabledBody.splitOn "qwen3-coder").length != 1 ||
     catSt != 200 || (catBody.splitOn "muse-wonder-1.0").length < 2 ||
     (catBody.splitOn "muse-ember-1.0").length < 2 ||
     (catBody.splitOn "vllm-internal.corp.local").length < 2 ||
     alCatSt != 200 || (alCatBody.splitOn "qwen3-coder").length < 2 ||
     (alCatBody.splitOn "vllm-internal.corp.local").length != 1 ||
     (alCatDisabledBody.splitOn "qwen3-coder").length != 1 ||
     admChainsSt != 200 || (admChainsBody.splitOn "sk-inline-chain-secret").length != 1 ||
     (admChainsBody.splitOn "vllm-internal.corp.local").length != 1 ||
     (admChainsBody.splitOn "\"entries\":[{\"provider_id\":\"custom:cust-vllm\",\"model_id\":\"qwen3-coder\"}]").length < 2 ||
     alChainsSt != 200 || (alChainsBody.splitOn "cust-chain").length < 2 ||
     (alChainsBody.splitOn "sk-inline-chain-secret").length != 1 ||
     (alChainsBody.splitOn "vllm-internal.corp.local").length != 1 ||
     (alChainsBody.splitOn "rpm_limit").length != 1 ||
     alResolveSt != 403 ||
     (museTargets[0]?).map (·.baseUrl) != some "https://api.meta.ai" ||
     (agyTargets[0]?).map (·.modelId) != some "gemini-4-carbon-high" ||
     (agyTargets[1]?).map (·.modelId) != some "gemini-4-argon-low" ||
     agyGrouped != #[("gemini-4-carbon", "Carbon"), ("gemini-4-argon", "Argon")] ||
     agyCliMdl != "gemini-4-carbon-medium" || agyCliEff != none then
    return (← fail s!"backend-models / catalog / chain redaction check failed: firstCc={firstCcVal} bmSt={bmSt} catSt={catSt} alCat={alCatBody} alChains={alChainsBody} alRes={alResolveSt}")

  -- Last-active-admin protection: disable/demote `opsadmin` first (so `admin` is sole active admin), then verify `admin` cannot be disabled/demoted/deleted!
  let opsOpt ← getUserByUsername? store "opsadmin"
  if let some opsU := opsOpt then
    let (disOpsSt, _, _) ← sendReq "PATCH" s!"/api/admin/users/{opsU.id}" adminTok "{\"disabled\":true}"
    if disOpsSt != 200 then return (← fail "disable opsadmin failed")
  let (selfDemoteSt, _, _) ← sendReq "PATCH" s!"/api/admin/users/{bootAdminId}" adminTok "{\"role\":\"member\"}"
  let (selfDisableSt, _, _) ← sendReq "PATCH" s!"/api/admin/users/{bootAdminId}" adminTok "{\"disabled\":true}"
  let (selfDelSt, _, _) ← sendReq "DELETE" s!"/api/admin/users/{bootAdminId}" adminTok ""
  if selfDemoteSt != 400 || selfDisableSt != 400 || selfDelSt != 400 then
    return (← fail s!"last-active-admin invariant violated: demote={selfDemoteSt} disable={selfDisableSt} del={selfDelSt}")

  -- 3. Placement confinement (`member` blocked from Core & colocated/admin-only nodes; allowed on `ashur`, `auto-managed`, and staged `/api/uploads`)
  let (alCoreMisSt, _, _) ← sendReq "POST" "/api/control/missions" aliceTok
    s!"\{\"title\":\"Escape to Core\",\"backend\":\"opencode\",\"working_directory\":{jsonEscape muRoot}}"
  let (alColocMisSt, _, _) ← sendReq "POST" "/api/control/missions" aliceTok
    "{\"title\":\"Escape to Colocated\",\"backend\":\"opencode\",\"remote_node_id\":\"agent-core\",\"working_directory\":\"/tmp\"}"
  let (alWsSt, _, _) ← sendReq "POST" "/api/workspaces" aliceTok "{\"name\":\"core-ws\"}"
  let (alNodesSt, alNodesBody, _) ← sendReq "GET" "/api/nodes" aliceTok ""
  let (admNodesSt, admNodesBody, _) ← sendReq "GET" "/api/nodes" adminTok ""
  if alCoreMisSt != 403 || alColocMisSt != 403 || alWsSt != 403 || alNodesSt != 200 || admNodesSt != 200 ||
     (alNodesBody.splitOn "\"id\":\"core\"").length != 1 ||
     (admNodesBody.splitOn "\"id\":\"core\"").length < 2 then
    return (← fail s!"member placement confinement failed: core={alCoreMisSt} coloc={alColocMisSt} ws={alWsSt} alNodes={alNodesBody} admNodes={admNodesBody}")

  let (alUploadSt, alUploadBody, _) ← sendReq "POST" "/api/uploads?name=spec.md" aliceTok "hello-staged-attachment"
  if alUploadSt != 201 || (alUploadBody.splitOn s!"\"owner_user_id\":{jsonEscape aliceId}").length < 2 then
    return (← fail s!"member staged upload failed or unconfined: st={alUploadSt} body={alUploadBody}")

  -- `alice` creates mission on dedicated fleet node `ashur` with project `lean-campaign`
  let (alMisSt, alMisBody, _) ← sendReq "POST" "/api/control/missions" aliceTok
    "{\"title\":\"Alice Private Theorem\",\"backend\":\"opencode\",\"remote_node_id\":\"ashur\",\"working_directory\":\"/home/orb-alice/work\",\"project\":\"lean-campaign\"}"
  let alMisId := ((OrbBin.Json.parse alMisBody).toOption.getD (.obj #[]) |>.fieldStr? "id").getD ""
  if alMisSt != 201 || alMisId.isEmpty || (alMisBody.splitOn "\"project\":\"lean-campaign\"").length < 2 then
    return (← fail s!"alice remote mission create failed: st={alMisSt} body={alMisBody}")

  -- Active mission_runs lock prevents changing `alice`'s `unix_username` (`409`)
  let insRun ← execParamQuery store.missionsDb
    "INSERT INTO mission_runs(id,mission_id,generation,execution_state,updated_at) VALUES('run-al-1',?1,1,'running','t1');" #[alMisId]
  if !insRun.isOk then
    return (← fail s!"insert active mission_run failed: {reprStr insRun}")
  let (renBusySt, _, _) ← sendReq "PATCH" s!"/api/admin/users/{aliceId}" adminTok "{\"unix_username\":\"orb-alice2\"}"
  let _ ← execParamQuery store.missionsDb "UPDATE mission_runs SET execution_state='terminal' WHERE id='run-al-1';" #[]
  if renBusySt != 409 then
    return (← fail s!"expected 409 when mutating unix_username with active mission_run, got {renBusySt}")

  -- 4. Strict owner privacy EVEN FROM `admin` (`404` non-disclosure, isolated projects, isolated inbox, isolated VMs, zero counts in `/api/admin/users`)
  let (admGetAlSt, _, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}" adminTok ""
  let (admDelAlSt, _, _) ← sendReq "DELETE" s!"/api/control/missions/{alMisId}" adminTok ""
  let (admEvAlSt, _, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}/events" adminTok ""
  let (admShAlSt, _, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}/shares" adminTok ""
  let (_, admListBody, _) ← sendReq "GET" "/api/control/missions" adminTok ""
  let (_, admUsersBody, _) ← sendReq "GET" "/api/admin/users" adminTok ""
  if admGetAlSt != 404 || admDelAlSt != 404 || admEvAlSt != 404 || admShAlSt != 404 ||
     (admListBody.splitOn "Alice Private Theorem").length != 1 ||
     (admListBody.splitOn "Legacy Pre-Bootstrap Mission").length < 2 ||
     (admUsersBody.splitOn "Alice Private Theorem").length != 1 ||
     (admUsersBody.splitOn "mission_count").length != 1 then
    return (← fail s!"strict owner privacy from admin violated: get={admGetAlSt} del={admDelAlSt} ev={admEvAlSt} sh={admShAlSt} list={admListBody}")

  -- Isolated per-user project namespace (`lean-campaign` for `alice` vs `admin`) & isolated inbox state
  let (alBoardPutSt, _, _) ← sendReq "POST" "/api/projects/lean-campaign/tracks" aliceTok
    "{\"track\":\"proof-track\",\"desired_condition\":\"Alice Secret Track\"}"
  let (_, admBoardBody, _) ← sendReq "GET" "/api/projects/lean-campaign/board" adminTok ""
  let (_, alBoardBody, _) ← sendReq "GET" "/api/projects/lean-campaign/board" aliceTok ""
  let (alInbPutSt, _, _) ← sendReq "PUT" "/api/control/inbox-state/seen/m-secret" aliceTok
    "{\"clientId\":\"c-al\",\"mutationSeq\":1,\"expectedVersion\":0,\"stamp\":42}"
  let (_, admInbBody, _) ← sendReq "GET" "/api/control/inbox-state" adminTok ""
  if alBoardPutSt != 200 || (alBoardBody.splitOn "proof-track").length < 2 ||
     (admBoardBody.splitOn "proof-track").length != 1 ||
     alInbPutSt != 200 || (admInbBody.splitOn "m-secret").length != 1 then
    return (← fail s!"project/inbox namespace isolation failed: alBoard={alBoardBody} admBoard={admBoardBody} admInb={admInbBody}")

  -- 5. Mission sharing (`owner` -> `bob` `participant`: read/message/queue/cancel allowed, destructive ops `403`, self-leave `200` -> `404`)
  let (bobPreSt, _, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}" bobTok ""
  let (shCreateSt, shCreateBody, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/shares" aliceTok "{\"username\":\"bob\"}"
  let (bobGetSt, bobGetBody, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}" bobTok ""
  let (bobMsgSt, _, _) ← sendReq "POST" "/api/control/message" bobTok
    s!"\{\"mission_id\":{jsonEscape alMisId},\"content\":\"Hi Alice from Bob\"}"
  let (_, alEvsBody, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}/events" aliceTok ""
  let (bobCancelSt, _, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/cancel" bobTok "{}"
  -- Mission budget & reset cadence (`#1565`): owner `PUT` sets daily budget + `inference_usd_per_hour`, shared `participant` can `GET` (`200`) and is denied `PUT` (`403`)
  let (alBudInitSt, alBudInitBody, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}/budget" aliceTok ""
  let (alBudBadPeriodSt, _, _) ← sendReq "PUT" s!"/api/control/missions/{alMisId}/budget" aliceTok "{\"budget_reset_period\":\"daily\"}"
  let (alBudPutSt, alBudPutBody, _) ← sendReq "PUT" s!"/api/control/missions/{alMisId}/budget" aliceTok
    "{\"budget_usd\":300,\"budget_reset_period\":\"daily\",\"vm_limits\":{\"max_concurrent\":4,\"provider_max_concurrent\":{\"boat\":2}},\"bandwidth_limits\":{\"tokens_per_min\":50000,\"inference_usd_per_hour\":18.5,\"compute_usd_per_hour\":6.0,\"protect_root\":true}}"
  let (bobBudGetSt, bobBudGetBody, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}/budget" bobTok ""
  let (bobBudPutSt, _, _) ← sendReq "PUT" s!"/api/control/missions/{alMisId}/budget" bobTok "{\"budget_usd\":500}"
  let (admBudGetSt, _, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}/budget" adminTok ""
  let (alBudClrSt, alBudClrBody, _) ← sendReq "PUT" s!"/api/control/missions/{alMisId}/budget" aliceTok "{\"budget_usd\":null,\"vm_limits\":null,\"bandwidth_limits\":null}"
  if alBudInitSt != 200 || (alBudInitBody.splitOn "\"mode\":\"none\"").length < 2 ||
     alBudBadPeriodSt != 400 || alBudPutSt != 200 ||
     (alBudPutBody.splitOn "\"own_budget_reset_period\":\"daily\"").length < 2 ||
     (alBudPutBody.splitOn "\"reset_period\":\"daily\"").length < 2 ||
     (alBudPutBody.splitOn "\"period_resets_at\":\"20").length < 2 ||
     (alBudPutBody.splitOn "\"persistent_carved_usd\":0.0").length < 2 ||
     (alBudPutBody.splitOn "\"inference_usd_per_hour\":18.5").length < 2 ||
     (alBudPutBody.splitOn "\"max_concurrent\":4").length < 2 ||
     bobBudGetSt != 200 || (bobBudGetBody.splitOn "\"own_budget_usd\":300.0").length < 2 ||
     bobBudPutSt != 403 || admBudGetSt != 404 ||
     alBudClrSt != 200 || (alBudClrBody.splitOn "\"mode\":\"none\"").length < 2 then
    return (← fail s!"mission budget (#1565) mismatch: init={alBudInitSt}:{alBudInitBody} badPeriod={alBudBadPeriodSt} put={alBudPutSt}:{alBudPutBody} bobGet={bobBudGetSt} bobPut={bobBudPutSt} admGet={admBudGetSt} clr={alBudClrSt}:{alBudClrBody}")
  let (bobDelSt, _, _) ← sendReq "DELETE" s!"/api/control/missions/{alMisId}" bobTok ""
  let (bobArcSt, _, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/archive" bobTok "{}"
  let (bobForkSt, _, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/fork" bobTok "{}"
  let (bobTxSt, _, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/machine-transfer" bobTok "{\"destination\":\"ashur\"}"
  let (bobReShareSt, _, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/shares" bobTok "{\"username\":\"admin\"}"
  let (bobLeaveSt, _, _) ← sendReq "DELETE" s!"/api/control/missions/{alMisId}/shares/{bobId}" bobTok ""
  let (bobAfterLeaveSt, _, _) ← sendReq "GET" s!"/api/control/missions/{alMisId}" bobTok ""
  if bobPreSt != 404 || (shCreateSt != 200 && shCreateSt != 201) || bobGetSt != 200 ||
     (bobGetBody.splitOn "\"viewer_role\":\"participant\"").length < 2 ||
     (bobGetBody.splitOn "\"owner_username\":\"alice\"").length < 2 ||
     bobMsgSt != 200 || (alEvsBody.splitOn "\"sender_username\":\"bob\"").length < 2 ||
     bobCancelSt != 200 ||
     bobDelSt != 403 || bobArcSt != 403 || bobForkSt != 403 || bobTxSt != 403 || bobReShareSt != 403 ||
     bobLeaveSt != 200 || bobAfterLeaveSt != 404 then
    return (← fail s!"mission sharing RBAC mismatch: pre={bobPreSt} sh={shCreateSt}:{shCreateBody} get={bobGetSt}:{bobGetBody} msg={bobMsgSt} evs={alEvsBody} del={bobDelSt} arc={bobArcSt} fork={bobForkSt} tx={bobTxSt} reshare={bobReShareSt} leave={bobLeaveSt} after={bobAfterLeaveSt}")

  -- 6. Inference provider redaction, per-user provider preferences, `mission_proxy_token`, and per-user daily spend cap (`50` cents)
  let _ ← upsertAIProvider store { id := "prov-a", name := "OpenAI Primary", providerType := "openai", baseUrl := "https://internal-a.example/v1", apiKey := "sk-secret-openai-9999", enabled := true, updatedAt := "t1" }
  let _ ← upsertAIProvider store { id := "prov-b", name := "Anthropic Backup", providerType := "anthropic", baseUrl := "https://internal-b.example/v1", apiKey := "sk-secret-anth-8888", enabled := true, updatedAt := "t1" }
  let (alProvsSt, alProvsBody, _) ← sendReq "GET" "/api/ai/providers" aliceTok ""
  let (admProvsSt, admProvsBody, _) ← sendReq "GET" "/api/ai/providers" adminTok ""
  if alProvsSt != 200 || admProvsSt != 200 ||
     (alProvsBody.splitOn "sk-secret").length != 1 ||
     (alProvsBody.splitOn "internal-a.example").length != 1 ||
     (admProvsBody.splitOn "internal-a.example").length < 2 then
    return (← fail s!"provider secret/baseUrl redaction mismatch: al={alProvsBody} adm={admProvsBody}")

  -- `alice` disables `prov-a` (OpenAI). A model is never served by another model family: her `gpt-5`
  -- request is refused (403), it is NOT rerouted to the Anthropic account as the old expectation
  -- encoded. Her Claude requests use `prov-b`; `admin` still reaches `prov-a` for `gpt-5`.
  let (alPrefSt, _, _) ← sendReq "PUT" "/api/ai/providers/prov-a/preference" aliceTok "{\"enabled\":false}"
  let (mptSt, mptBody, _) ← sendReq "POST" s!"/api/control/missions/{alMisId}/proxy-token" aliceTok "{}"
  let mptTok := ((OrbBin.Json.parse mptBody).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  let (alGptSt, alGptBody, _) ← sendReq "POST" "/v1/responses" mptTok "{\"model\":\"gpt-5\",\"input\":\"hi\"}"
  let (alProxy1St, alProxy1Body, _) ← sendReq "POST" "/v1/responses" mptTok "{\"model\":\"claude-fable-5-2\",\"input\":\"hi\"}"
  let (admProxy1St, admProxy1Body, _) ← sendReq "POST" "/v1/responses" adminTok "{\"model\":\"gpt-5\",\"input\":\"hi\"}"
  -- Second call (`30` cents each -> `30 < 50` admitted, becomes `60 >= 50`), third call hits `alice`'s 50-cent daily cap -> `429`!
  let (alProxy2St, _, _) ← sendReq "POST" "/v1/responses" mptTok "{\"model\":\"claude-fable-5-2\",\"input\":\"hi2\"}"
  let (alProxy3St, alProxy3Body, _) ← sendReq "POST" "/v1/responses" mptTok "{\"model\":\"claude-fable-5-2\",\"input\":\"hi3\"}"
  if alPrefSt != 200 || (mptSt != 200 && mptSt != 201) || !mptTok.startsWith "orb-mpt-v1_" ||
     alGptSt != 403 || (alGptBody.splitOn "no_user_enabled_providers").length < 2 ||
     alProxy1St != 200 || (alProxy1Body.splitOn "\"acct\":\"prov-b\"").length < 2 ||
     admProxy1St != 200 || (admProxy1Body.splitOn "\"acct\":\"prov-a\"").length < 2 ||
     alProxy2St != 200 || alProxy3St != 429 ||
     (alProxy3Body.splitOn "daily_spend_cap_exceeded").length < 2 then
    return (← fail s!"per-user proxy routing or spend cap failed: pref={alPrefSt} mpt={mptSt} p1={alProxy1St}:{alProxy1Body} adm={admProxy1St}:{admProxy1Body} p2={alProxy2St} p3={alProxy3St}:{alProxy3Body}")

  -- Managed VMs: `alice` hitting daily spend cap gets `429` on `POST /api/managed-machines`, while `bob` (`no cap`, disables `boat`) spawns an auto VM (`leanci`) owned by `bob`, invisible to `admin` (`404` on `DELETE`)!
  let (alVmCapSt, _, _) ← sendReq "POST" "/api/managed-machines" aliceTok "{\"provider\":\"boat\",\"name\":\"alice-vm\"}"
  let (bobPrefBoatSt, _, _) ← sendReq "PUT" "/api/managed-machines/providers/boat/preference" bobTok "{\"enabled\":false}"
  let (bobVmAutoSt, bobVmAutoBody, _) ← sendReq "POST" "/api/managed-machines" bobTok "{\"provider\":\"auto\",\"name\":\"bob-vm\",\"wait\":true}" "bob-managed-create"
  let beforeRetrySpend ← getUserSpentTodayCents store bobId (formatEpochIso8601Utc nowSec |>.take 10 |>.toString)
  let (bobRetrySt, bobRetryBody, _) ← sendReq "POST" "/api/managed-machines" bobTok "{\"provider\":\"auto\",\"name\":\"bob-vm\",\"wait\":true}" "bob-managed-create"
  let afterRetrySpend ← getUserSpentTodayCents store bobId (formatEpochIso8601Utc nowSec |>.take 10 |>.toString)
  if bobRetrySt != 201 || bobRetryBody != bobVmAutoBody || beforeRetrySpend != afterRetrySpend then
    return (← fail "managed REST retry must not create another VM or charge spend twice")
  let .ok beforeImageGuard ← execParamQuery mStore.db "SELECT COUNT(*) FROM managed_machines;" #[]
    | return (← fail "managed image guard count failed")
  let (privateImageSt, _, _) ← sendReq "POST" "/api/managed-machines" bobTok
    "{\"provider\":\"leanci\",\"image\":\"unrelated-private-disk\"}"
  let (privateSnapshotSt, _, _) ← sendReq "POST" "/api/managed-machines" bobTok
    "{\"provider\":\"leanci\",\"from_snapshot\":\"unrelated-private-snapshot\"}"
  let .ok afterImageGuard ← execParamQuery mStore.db "SELECT COUNT(*) FROM managed_machines;" #[]
    | return (← fail "managed image guard count failed")
  if privateImageSt != 409 || privateSnapshotSt != 409 || beforeImageGuard != afterImageGuard then
    return (← fail "unscoped image/snapshot labels must rent nothing")
  let bobVmId := ((OrbBin.Json.parse bobVmAutoBody).toOption.getD (.obj #[]) |>.fieldStr? "id").getD ""
  let (bobStopVmSt, _, _) ← sendReq "POST" s!"/api/managed-machines/{bobVmId}/stop" bobTok "{}"
  let (bobResumeVmSt, bobResumeBody, _) ← sendReq "POST" s!"/api/managed-machines/{bobVmId}/resume" bobTok
    "{\"ttl_minutes\":5}" "bob-rest-resume"
  let (bobResumeRetrySt, bobResumeRetryBody, _) ← sendReq "POST" s!"/api/managed-machines/{bobVmId}/resume" bobTok
    "{\"ttl_minutes\":5}" "bob-rest-resume"
  let resumedRest := (OrbBin.Json.parse bobResumeBody).toOption.getD .null
  if bobStopVmSt != 200 || bobResumeVmSt != 200 || bobResumeRetrySt != 200 || bobResumeRetryBody != bobResumeBody ||
      ((resumedRest.field? "machine").getD .null).fieldUInt64? "node_boot_epoch" != some 2 then
    return (← fail s!"REST resume must preserve identity and advance only on poll: {bobResumeVmSt}:{bobResumeBody}")
  let (_, admVmsBody, _) ← sendReq "GET" "/api/managed-machines" adminTok ""
  let (admDelBobVmSt, _, _) ← sendReq "DELETE" s!"/api/managed-machines/{bobVmId}" adminTok ""
  let (bobDelBobVmSt, _, _) ← sendReq "DELETE" s!"/api/managed-machines/{bobVmId}" bobTok ""
  if alVmCapSt != 429 || bobPrefBoatSt != 200 || bobVmAutoSt != 201 || bobVmId.isEmpty ||
     (bobVmAutoBody.splitOn "\"provider\":\"leanci\"").length < 2 ||
     (admVmsBody.splitOn bobVmId).length != 1 ||
     admDelBobVmSt != 404 || bobDelBobVmSt != 200 then
    return (← fail s!"managed VM multi-user isolation/prefs/cap failed: alCap={alVmCapSt} bobVm={bobVmAutoSt}:{bobVmAutoBody} admVms={admVmsBody} admDel={admDelBobVmSt} bobDel={bobDelBobVmSt}")

  -- A disabled fleet is reported as such, not as a spend cap.
  let (fleetOffSt, _, _) ← sendReq "PUT" "/api/managed-machines/settings" adminTok "{\"enabled\":false}"
  let (offCreateSt, offCreateBody, _) ← sendReq "POST" "/api/managed-machines" bobTok "{\"provider\":\"leanci\",\"name\":\"bob-off\"}"
  let (fleetOnSt, _, _) ← sendReq "PUT" "/api/managed-machines/settings" adminTok "{\"enabled\":true}"
  let (provOffSt, _, _) ← sendReq "PATCH" "/api/managed-machines/providers/leanci" adminTok "{\"enabled\":false}"
  let (provOffCreateSt, provOffCreateBody, _) ← sendReq "POST" "/api/managed-machines" bobTok "{\"provider\":\"leanci\",\"name\":\"bob-off\"}"
  let (provOnSt, _, _) ← sendReq "PATCH" "/api/managed-machines/providers/leanci" adminTok "{\"enabled\":true}"
  if fleetOffSt != 200 || fleetOnSt != 200 || provOffSt != 200 || provOnSt != 200 || offCreateSt != 409 ||
      (offCreateBody.splitOn "managed_fleet_disabled").length != 2 || provOffCreateSt != 409 ||
      (provOffCreateBody.splitOn "provider_disabled").length != 2 then
    return (← fail s!"disabled fleet or provider must be named: {offCreateSt}:{offCreateBody} / {provOffCreateSt}:{provOffCreateBody}")

  -- REST create without `wait` answers 202 at once with the provisioning machine
  -- and an action to poll; a retry with the same key returns the same machine.
  let (asyncSt, asyncBody, _) ← sendReq "POST" "/api/managed-machines" bobTok
    "{\"provider\":\"leanci\",\"name\":\"bob-async\",\"ttl_minutes\":5}" "bob-async-create"
  let (asyncRetrySt, asyncRetryBody, _) ← sendReq "POST" "/api/managed-machines" bobTok
    "{\"provider\":\"leanci\",\"name\":\"bob-async\",\"ttl_minutes\":5}" "bob-async-create"
  let asyncJson := (OrbBin.Json.parse asyncBody).toOption.getD .null
  let asyncRetry := (OrbBin.Json.parse asyncRetryBody).toOption.getD .null
  let asyncAction := (asyncJson.fieldStr? "action_id").getD ""
  let asyncId := (asyncJson.fieldStr? "id").getD ""
  if asyncSt != 202 || asyncRetrySt != 202 || asyncAction.isEmpty || asyncId.isEmpty ||
      asyncRetry.fieldStr? "action_id" != some asyncAction || asyncRetry.fieldStr? "id" != some asyncId then
    return (← fail s!"managed REST create must return one prompt receipt: {asyncSt}:{asyncBody} / {asyncRetrySt}:{asyncRetryBody}")
  let mut asyncState := ""
  let mut asyncFinal := OrbBin.Json.JVal.null
  for _ in [0:2000] do
    let (_, pollBody, _) ← sendReq "GET" s!"/api/managed-machines/actions/{asyncAction}" bobTok ""
    asyncFinal := (OrbBin.Json.parse pollBody).toOption.getD .null
    asyncState := (asyncFinal.fieldStr? "state").getD ""
    if asyncState != "accepted" && asyncState != "running" then break
    IO.sleep 5
  let (alicePollSt, _, _) ← sendReq "GET" s!"/api/managed-machines/actions/{asyncAction}" aliceTok ""
  let (asyncDelSt, _, _) ← sendReq "DELETE" s!"/api/managed-machines/{asyncId}" bobTok ""
  if asyncState != "succeeded" || ((asyncFinal.field? "result").getD .null).fieldStr? "state" != some "ready" ||
      ((asyncFinal.field? "result").getD .null).fieldStr? "id" != some asyncId || alicePollSt != 404 || asyncDelSt != 200 then
    return (← fail s!"managed REST action must settle on the real machine and stay owner-scoped: {OrbBin.Json.renderCompact asyncFinal} alice={alicePollSt} del={asyncDelSt}")

  -- MCP uses exactly the same mock provider/bootstrap pipeline as REST, with
  -- ownership derived from its authenticated mission rather than tool arguments.
  let .ok () ← upsertMission store {
    id := "m-managed-parity", title := "Managed entry-point parity", status := "awaiting_user",
    backend := "opencode", modelOverride := "", updatedAt := formatEpochIso8601Utc nowSec,
    workingDirectory := muRoot, ownerUserId := bobId
  } | return (← fail "managed parity mission fixture failed")
  let parityClaims : McpSessionClaims := {
    sessionId := "managed-parity-session", missionId := "m-managed-parity",
    role := "executor", expiresAt := nowSec + 600
  }
  let parityArgs := OrbBin.Json.JVal.obj #[("provider", .str "leanci"), ("size", .str "small"),
    ("ttl_minutes", .nat 5), ("idempotency_key", .str "mcp-managed-parity")]
  let mcpCreated ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
    "spawn_managed_machine" parityArgs nowSec none app.managedProvisioningOverride?
  let mcpReplay ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
    "spawn_managed_machine" parityArgs nowSec none app.managedProvisioningOverride?
  -- The spawn tool answers at once with an action; the machine arrives through get_action.
  let acceptedJson := (OrbBin.Json.parse mcpCreated).toOption.getD .null
  let acceptedAction := ((acceptedJson.field? "result").getD .null).fieldStr? "action_id" |>.getD ""
  let replayAction := (((OrbBin.Json.parse mcpReplay).toOption.getD .null).field? "result").getD .null
  if acceptedAction.isEmpty || replayAction.fieldStr? "action_id" != some acceptedAction then
    return (← fail s!"managed MCP spawn must return one action receipt for a retried key: {mcpCreated} / {mcpReplay}")
  let mut createdJson := OrbBin.Json.JVal.null
  let mut actionState := ""
  for _ in [0:2000] do
    let polled ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
      "get_action" (.obj #[("action_id", .str acceptedAction)]) nowSec none app.managedProvisioningOverride?
    createdJson := (OrbBin.Json.parse polled).toOption.getD .null
    actionState := (((createdJson.field? "result").getD .null).fieldStr? "state").getD ""
    if actionState != "accepted" && actionState != "running" then break
    IO.sleep 5
  if actionState != "succeeded" then
    return (← fail s!"managed MCP spawn action did not succeed: {OrbBin.Json.renderCompact createdJson}")
  let foreignPoll ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot
    { parityClaims with sessionId := "foreign-action-session", missionId := "m-not-the-owner" }
    "get_action" (.obj #[("action_id", .str acceptedAction)]) nowSec none app.managedProvisioningOverride?
  if (((OrbBin.Json.parse foreignPoll).toOption.getD .null).fieldBool? "ok") == some true then
    return (← fail "another mission read a managed spawn receipt")
  let createdItem := (((createdJson.field? "result").getD .null).field? "result").getD .null
  let parityId := (createdItem.fieldStr? "id").getD ""
  let some (parityVm, _) ← getManagedMachine? mStore parityId
    | return (← fail "managed MCP parity VM missing")
  if createdJson.fieldBool? "ok" != some true ||
      parityVm.ownerUserId != bobId || parityVm.ownerMission != "m-managed-parity" ||
      parityVm.status != "ready" || parityVm.lastPollSec == 0 || parityVm.providerId == parityVm.id then
    return (← fail "REST/MCP provisioning parity or retry identity failed")
  let .ok () ← upsertMission store {
    id := "m-managed-foreign", title := "Foreign managed caller", status := "awaiting_user",
    backend := "opencode", modelOverride := "", updatedAt := formatEpochIso8601Utc nowSec,
    workingDirectory := muRoot, ownerUserId := aliceId
  } | return (← fail "foreign managed caller fixture failed")
  let foreignClaims := { parityClaims with sessionId := "foreign-managed-session", missionId := "m-managed-foreign" }
  let foreignDestroy ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot foreignClaims
    "destroy_managed_machine" (.obj #[("machine_id", .str parityId)]) nowSec none app.managedProvisioningOverride?
  let foreignExec ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot foreignClaims
    "exec_raw_managed_machine" (.obj #[("machine_id", .str parityId), ("command", .str "true")]) nowSec none app.managedProvisioningOverride?
  let wrongProject ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot
    { parityClaims with project := "another-project" }
    "destroy_managed_machine" (.obj #[("machine_id", .str parityId)]) nowSec none app.managedProvisioningOverride?
  for response in #[foreignDestroy, foreignExec, wrongProject] do
    let parsed := (OrbBin.Json.parse response).toOption.getD .null
    if ((parsed.field? "error").getD .null).fieldStr? "code" != some "not_found" then
      return (← fail "managed mutations must not cross tenant/project boundaries")
  let some (stillReady, _) ← getManagedMachine? mStore parityId
    | return (← fail "foreign caller erased managed machine")
  if stillReady.status != "ready" then return (← fail "foreign caller changed managed machine")
  let mcpStopped ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
    "stop_managed_machine" (.obj #[("machine_id", .str parityId)]) nowSec none app.managedProvisioningOverride?
  let resumeArgs := OrbBin.Json.JVal.obj #[("machine_id", .str parityId), ("ttl_minutes", .nat 5),
    ("idempotency_key", .str "mcp-managed-resume")]
  let mcpResumed ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
    "resume_managed_machine" resumeArgs nowSec none app.managedProvisioningOverride?
  let mcpResumeReplay ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
    "resume_managed_machine" resumeArgs nowSec none app.managedProvisioningOverride?
  let resumedMcp := ((OrbBin.Json.parse mcpResumed).toOption.getD .null |>.field? "result").getD .null
  if ((OrbBin.Json.parse mcpStopped).toOption.getD .null).fieldBool? "ok" != some true ||
      mcpResumed != mcpResumeReplay || ((resumedMcp.field? "machine").getD .null).fieldUInt64? "node_boot_epoch" != some 2 then
    return (← fail s!"MCP resume/poll/retry parity failed: {mcpResumed}")
  let mcpDestroyed ← dispatchMcpToolCall store (some mStore) none none mfBoot muRoot parityClaims
    "destroy_managed_machine" (.obj #[("machine_id", .str parityId)]) nowSec none app.managedProvisioningOverride?
  if ((OrbBin.Json.parse mcpDestroyed).toOption.getD .null).fieldBool? "ok" != some true then
    return (← fail "MCP provider-backed destroy failed")

  -- 7. Multi-user Opt-In Usage Telemetry & Speaker-Attributed Voice Relay (`/api/usage-telemetry/*`, `/api/voice/transcribe`)
  -- 7a. `scrubSecrets` covers API keys, hub tokens, GitHub tokens, Bearer headers, and password pairs without mangling prose
  if scrubSecrets "use sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv to call" != "use [REDACTED] to call" ||
     scrubSecrets "token tl_live_0123456789abcdef please" != "token [REDACTED] please" ||
     scrubSecrets "curl -H 'Authorization: Bearer abc.def-ghi_jklmnopqrstu'" != "curl -H 'Authorization: Bearer [REDACTED]'" ||
     scrubSecrets "password: hunter2hunter2" != "password: [REDACTED]" ||
     scrubSecrets "fix the token refresh bug in auth.rs" != "fix the token refresh bug in auth.rs" then
    return (← fail "scrubSecrets fixture regression")

  -- 7b. Non-admin `member` (`alice`) cannot mutate `PUT /api/usage-telemetry/config` (`403`), and `community` namespace is rejected (`400`)
  let (alTelCfgSt, _, _) ← sendReq "PUT" "/api/usage-telemetry/config" aliceTok
    "{\"enabled\":true,\"namespace\":\"th0rgal\",\"token\":\"tl_live_evil\"}"
  let (badNsSt, _, _) ← sendReq "PUT" "/api/usage-telemetry/config" adminTok
    "{\"enabled\":true,\"namespace\":\"community\",\"token\":\"tl_live_0123456789abcdef\"}"
  if alTelCfgSt != 403 || badNsSt != 400 then
    return (← fail s!"telemetry config RBAC/namespace guard failed: alCfg={alTelCfgSt} badNs={badNsSt}")

  -- 7c. Admin configures loopback hub (`prompts_enabled=true`), token is encrypted at rest and never returned in `GET /api/usage-telemetry`
  let .ok (mockHubFd, mockHubPort) ← tcpListen "127.0.0.1" 0 8
    | return (← fail "tcpListen mock telemetry hub failed")
  let hubCfgBody :=
    s!"\{\"enabled\":true,\"prompts_enabled\":true,\"hub_url\":\"http://127.0.0.1:{mockHubPort}\",\"namespace\":\"th0rgal\",\"token\":\"tl_live_secret_hub_token_1234\"}"
  let (admTelCfgSt, admTelCfgBody, _) ← sendReq "PUT" "/api/usage-telemetry/config" adminTok hubCfgBody
  let (getTelSt, getTelBody, _) ← sendReq "GET" "/api/usage-telemetry" aliceTok ""
  let rawSavedTelCfg ← try IO.FS.readFile (System.FilePath.mk store.rootDir / "telemetry_config.json") catch _ => pure ""
  if admTelCfgSt != 200 || getTelSt != 200 ||
     (admTelCfgBody.splitOn "\"active\":true").length < 2 ||
     (getTelBody.splitOn "tl_live_secret_hub_token_1234").length != 1 ||
     (rawSavedTelCfg.splitOn "tl_live_secret_hub_token_1234").length != 1 ||
     (rawSavedTelCfg.splitOn "\"v1:").length < 2 then
    discard <| closeFd mockHubFd
    return (← fail s!"telemetry config encryption/redaction failed: put={admTelCfgSt}:{admTelCfgBody} saved={rawSavedTelCfg}")

  -- 7d. `alice` sends a client event attempting to spoof `"username":"admin"` and `"user_id":"spoof"`:
  --     Core strips the spoofed fields and stamps authoritative `"username":"alice"` + `"user_id":aliceId`!
  --     Also `alice` (`member`) sending `POST /api/control/message` MUST NOT emit `orb.prompt.v1`, whereas `admin` DOES!
  let (alEvPostSt, alEvPostBody, _) ← sendReq "POST" "/api/usage-telemetry/events" aliceTok
    "{\"events\":[{\"schema\":\"orb.page.v1\",\"event_id\":\"evt-al-1\",\"client\":\"desktop\",\"screen\":\"mission\",\"surface\":\"screen\",\"dwell_ms\":1200,\"username\":\"admin\",\"user_id\":\"spoof-admin\",\"secret\":\"drop-me\"}]}"
  let (admEvPostSt, _, _) ← sendReq "POST" "/api/usage-telemetry/events" adminTok
    "{\"events\":[{\"schema\":\"orb.action.v1\",\"event_id\":\"evt-adm-1\",\"client\":\"ios\",\"action\":\"fork\",\"count\":1}]}"
  let _ ← sendReq "POST" "/api/control/message" aliceTok
    s!"\{\"mission_id\":{jsonEscape alMisId},\"content\":\"Alice private prompt sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv\"}"
  let _ ← sendReq "POST" "/api/control/message" adminTok
    "{\"mission_id\":\"m-legacy-boot\",\"content\":\"Admin prompt with token tl_live_9999888877776666\"}"
  if alEvPostSt != 202 || admEvPostSt != 202 || (alEvPostBody.splitOn "\"accepted\":1").length < 2 then
    discard <| closeFd mockHubFd
    return (← fail s!"POST /api/usage-telemetry/events failed: al={alEvPostSt}:{alEvPostBody} adm={admEvPostSt}")

  let findHdr (hdrs : Array (String × String)) (name : String) : String :=
    ((hdrs.find? fun (k, _) => k.toLower == name.toLower).map (·.2)).getD ""
  let hubServerTask ← IO.asTask (prio := .dedicated) do
    match ← tcpAcceptPoll mockHubFd 5000 with
    | .error _ => return ""
    | .ok cfd =>
      let reqRes ← readCoreHttpRequestFromFd cfd 5000
      let respBytes := encodeCoreHttpResponse (jsonResponse 200 "{\"accepted\":3}")
      discard <| writeAll cfd respBytes false
      discard <| closeFd cfd
      match reqRes with
      | .error _ => return ""
      | .ok r =>
        let authH := findHdr r.headers "authorization"
        let bStr := (String.fromUTF8? r.bodySlice.toByteArray).getD ""
        return s!"{r.path}\n{authH}\n{bStr}"
  let flushRes ← flushTelemetryOnce telSink nowSec
  let hubWire := match hubServerTask.get with
    | .ok s => s
    | .error _ => ""
  discard <| closeFd mockHubFd
  let flushedCount := match flushRes with
    | .ok n => n
    | .error _ => 0
  if flushedCount != 3 ||
     (hubWire.splitOn "/v2/ns/th0rgal/ingest").length < 2 ||
     (hubWire.splitOn "Bearer tl_live_secret_hub_token_1234").length < 2 ||
     (hubWire.splitOn "\"username\":\"alice\"").length < 2 ||
     (hubWire.splitOn s!"\"user_id\":{jsonEscape aliceId}").length < 2 ||
     (hubWire.splitOn "spoof-admin").length != 1 ||
     (hubWire.splitOn "drop-me").length != 1 ||
     (hubWire.splitOn "\"quick_close\":true").length < 2 ||
     (hubWire.splitOn "Alice private prompt").length != 1 ||
     (hubWire.splitOn "Admin prompt with token [REDACTED]").length < 2 then
    return (← fail s!"telemetry hub flush attribution/privacy mismatch: res={reprStr flushRes} wire={hubWire}")

  -- 7e. `POST /api/voice/transcribe?language=fr` validates WAV and stamps `X-Spark-Speaker-Id: bob` + `X-Orb-Username: bob` + `X-Orb-User-Id`
  let .ok (mockAsrFd, mockAsrPort) ← tcpListen "127.0.0.1" 0 8
    | return (← fail "tcpListen mock ASR failed")
  let appVoice : CoreAppState := { app with voiceEndpointOverride? := some s!"http://127.0.0.1:{mockAsrPort}/v1/audio/transcriptions" }
  let mkValidWav (pcmLen : Nat) : ByteArray := Id.run do
    let total := 44 + pcmLen
    let pushU16 (acc : ByteArray) (v : Nat) : ByteArray :=
      acc.push (v &&& 0xFF).toUInt8 |>.push ((v >>> 8) &&& 0xFF).toUInt8
    let pushU32 (acc : ByteArray) (v : Nat) : ByteArray :=
      acc.push (v &&& 0xFF).toUInt8 |>.push ((v >>> 8) &&& 0xFF).toUInt8
         |>.push ((v >>> 16) &&& 0xFF).toUInt8 |>.push ((v >>> 24) &&& 0xFF).toUInt8
    let mut b := "RIFF".toUTF8
    b := pushU32 b (total - 8)
    b := b ++ "WAVEfmt ".toUTF8
    b := pushU32 b 16
    b := pushU16 b 1
    b := pushU16 b 1
    b := pushU32 b 16000
    b := pushU32 b 32000
    b := pushU16 b 2
    b := pushU16 b 16
    b := b ++ "data".toUTF8
    b := pushU32 b pcmLen
    for _ in [0:pcmLen] do
      b := b.push 0
    return b
  let validWav := mkValidWav 3200
  -- Reject bad WAV (`400`) and unsupported language (`400`) before hitting upstream
  let (badLangSt, _, _) ← sendReq "POST" "/api/voice/transcribe?language=zz" bobTok "RIFF"
  let (badWavSt, _, _) ← sendReq "POST" "/api/voice/transcribe?language=fr" bobTok "not-a-wav"
  if badLangSt != 400 || badWavSt != 400 then
    discard <| closeFd mockAsrFd
    return (← fail s!"voice validation failed: lang={badLangSt} wav={badWavSt}")

  let asrServerTask ← IO.asTask (prio := .dedicated) do
    match ← tcpAcceptPoll mockAsrFd 5000 with
    | .error _ => return ""
    | .ok cfd =>
      let reqRes ← readCoreHttpRequestFromFd cfd 5000
      let respBytes := encodeCoreHttpResponse (jsonResponse 200 "{\"text\":\"  bonjour de bob  \"}")
      discard <| writeAll cfd respBytes false
      discard <| closeFd cfd
      match reqRes with
      | .error _ => return ""
      | .ok r =>
        let spk := findHdr r.headers "x-spark-speaker-id"
        let src := findHdr r.headers "x-spark-audio-source"
        let uHdr := findHdr r.headers "x-orb-username"
        let uidHdr := findHdr r.headers "x-orb-user-id"
        let prefixStr := (String.fromUTF8? (r.bodySlice.toByteArray.extract 0 (Nat.min 512 r.bodySlice.len))).getD ""
        return s!"spk={spk}|src={src}|u={uHdr}|uid={uidHdr}|body={prefixStr}"
  let voiceHead :=
    s!"POST /api/voice/transcribe?language=fr HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {bobTok}\r\nContent-Type: audio/wav\r\nContent-Length: {validWav.size}\r\n\r\n".toUTF8
  let .ok voiceReq := parseRequest (voiceHead ++ validWav) none
    | do discard <| closeFd mockAsrFd; return (← fail "parse voice request failed")
  let .ok voiceResp ← dispatchCoreRequest appVoice voiceReq nowSec
    | do discard <| closeFd mockAsrFd; return (← fail "dispatch voice request failed")
  let voiceRespBody := (String.fromUTF8? voiceResp.body).getD ""
  let asrWire := match asrServerTask.get with
    | .ok s => s
    | .error _ => ""
  discard <| closeFd mockAsrFd
  if voiceResp.status != 200 ||
     voiceRespBody != "{\"text\":\"bonjour de bob\"}" ||
     (asrWire.splitOn "spk=bob|src=orb-voice|u=bob|").length < 2 ||
     (asrWire.splitOn s!"uid={bobId}|").length < 2 ||
     (asrWire.splitOn "name=\"speaker_id\"\r\n\r\nbob").length < 2 then
    return (← fail s!"voice speaker attribution relay mismatch: st={voiceResp.status} resp={voiceRespBody} wire={asrWire}")

  closeManagedComputeStore mStore
  closeCoreStore store
  discard <| (IO.FS.removeDirAll muRoot).toBaseIO

  -- 8. Legacy single-tenant DB layout (`missions/missions-prod.db`, `mission_runs.run_id` PK, `not_before` TEXT) + `sdNotifyRaw` safety
  let legRoot := s!"/tmp/orb_legacy_compat_{muTs}"
  discard <| (IO.FS.removeDirAll legRoot).toBaseIO
  IO.FS.createDirAll (System.FilePath.mk s!"{legRoot}/missions")
  IO.FS.writeFile (System.FilePath.mk s!"{legRoot}/missions.db") ""
  let legMissionsPath := s!"{legRoot}/missions/missions-prod.db"
  let legAskPath := s!"{legRoot}/missions/ask.db"
  let legacySeedSchema :=
    "CREATE TABLE IF NOT EXISTS missions (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'awaiting_user', backend TEXT NOT NULL DEFAULT 'codex', working_directory TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '', not_before TEXT);" ++
    "CREATE TABLE IF NOT EXISTS mission_runs (run_id TEXT PRIMARY KEY NOT NULL, mission_id TEXT NOT NULL, generation INTEGER NOT NULL, execution_state TEXT NOT NULL, started_at TEXT NOT NULL);" ++
    "INSERT INTO missions(id,title,status,backend,working_directory,updated_at,not_before) VALUES('m-leg-prod','Legacy Prod Mission','awaiting_user','opencode','/tmp','2026-11-06T00:00:00Z','2026-11-06T01:00:00Z');" ++
    "INSERT INTO mission_runs(run_id,mission_id,generation,execution_state,started_at) VALUES('run-leg-0','m-leg-prod',1,'terminal','2026-11-06T00:05:00Z');"
  let .ok preM ← openSqliteDb legMissionsPath legacySeedSchema #[]
    | do discard <| (IO.FS.removeDirAll legRoot).toBaseIO; IO.eprintln "[orb-core-test] FAIL: open legacy missions-prod.db failed"; return 1
  sqliteCloseRaw preM.handle
  let .ok preA ← openSqliteDb legAskPath askSchemaSql #[]
    | do discard <| (IO.FS.removeDirAll legRoot).toBaseIO; IO.eprintln "[orb-core-test] FAIL: open legacy missions/ask.db failed"; return 1
  sqliteCloseRaw preA.handle
  let legOpenRes ← openCoreStore legRoot 0 "prod"
  let .ok legStore := legOpenRes
    | do
      let errStr := match legOpenRes with | .error e => e | .ok _ => ""
      discard <| (IO.FS.removeDirAll legRoot).toBaseIO
      IO.eprintln s!"[orb-core-test] FAIL: openCoreStore on legacy layout failed: {errStr}"
      return 1
  let .ok () ← ensureQueueContSchema legStore
    | do closeCoreStore legStore; discard <| (IO.FS.removeDirAll legRoot).toBaseIO; IO.eprintln "[orb-core-test] FAIL: ensureQueueContSchema on legacy layout failed"; return 1
  let backfilledRows ← execParamQuery legStore.missionsDb
    "SELECT id, updated_at FROM mission_runs WHERE run_id='run-leg-0';" #[]
  let bfId := match backfilledRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let bfUpd := match backfilledRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let beginLeg ← beginMissionRun legStore "m-leg-prod" "run-leg-2" "2026-11-09T19:00:00Z" 1
  let detLeg ← missionDetailJson legStore "m-leg-prod" none ""
  let sdEmpty ← sdNotifyRaw "" "READY=1\n"
  let sdMissing ← sdNotifyRaw s!"{legRoot}/nonexistent_notify.sock" "WATCHDOG=1\n"
  closeCoreStore legStore
  discard <| (IO.FS.removeDirAll legRoot).toBaseIO
  let detStr := match detLeg with | .ok (some s) => s | _ => ""
  if legStore.missionsDb.path != legMissionsPath ||
     legStore.askDb.path != legAskPath ||
     bfId != "run-leg-0" || bfUpd != "2026-11-06T00:05:00Z" ||
     !beginLeg.isOk ||
     (detStr.splitOn "\"id\":\"m-leg-prod\"").length < 2 ||
     sdEmpty != 0 || sdMissing != 0 then
    IO.eprintln s!"[orb-core-test] FAIL: legacy layout/sd_notify regression: mPath={legStore.missionsDb.path} aPath={legStore.askDb.path} bf={bfId}/{bfUpd} begin={reprStr beginLeg} sd={sdEmpty}/{sdMissing}"
    return 1

  return 0

private def runZeroWaitPerfAndSyncTests (prodValid : CoreConfig) : IO UInt32 := do
  let ts ← IO.monoNanosNow
  let zwRoot := s!"/tmp/orb-core-zerowait-{ts}"
  let cleanup : IO Unit := do discard <| (IO.FS.removeDirAll zwRoot).toBaseIO
  let .ok store ← openCoreStore zwRoot
    | do cleanup; IO.eprintln "[orb-core-test] FAIL: openCoreStore in runZeroWaitPerfAndSyncTests"; return 1
  let .ok () ← ensureQueueContSchema store
    | do closeCoreStore store; cleanup; IO.eprintln "[orb-core-test] FAIL: ensureQueueContSchema in runZeroWaitPerfAndSyncTests"; return 1
  let nowSec ← coreEpochSec
  let seedAdmins := #[("admin", prodValid.dashboardPassword), ("alice", "alice-zw-pass-1234")]
  let bootAdminId ← match ← bootstrapUsersAndBackfill store seedAdmins s!"{nowSec}" with
    | .ok aid => pure aid
    | .error _ => pure ""
  let managedRef ← IO.mkRef ({} : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (1 : UInt64)
  let app : CoreAppState := {
    cfg := { prodValid with workingDir := zwRoot, usersJson := "" }
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef
    proxyCooldownsRef := cooldownsRef
    seqRef := seqRef
    bootstrapAdminId := bootAdminId
  }
  let fail (msg : String) : IO UInt32 := do
    closeCoreStore store
    cleanup
    IO.eprintln s!"[orb-core-test] FAIL (zero-wait): {msg}"
    return 1

  let sendReqHdr (method target tok body : String) (extraHdrLines : String := "") : IO (Nat × ByteArray × Array (String × String)) := do
    let authHdr := if tok.isEmpty then "" else s!"Authorization: Bearer {tok}\r\n"
    let raw :=
      if body.isEmpty then
        s!"{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authHdr}{extraHdrLines}\r\n"
      else
        s!"{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authHdr}{extraHdrLines}Content-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
    match parseRequest raw.toUTF8 none with
    | .error e => return (0, s!"parse_err:{e}".toUTF8, #[])
    | .ok req =>
      match ← dispatchCoreRequest app req nowSec with
      | .error _ => return (0, "dispatch_err".toUTF8, #[])
      | .ok resp => return (resp.status, resp.body, resp.extraHdrs)

  let (_, admBody, _) ← sendReqHdr "POST" "/api/auth/login" "" s!"\{\"username\":\"admin\",\"password\":{jsonEscape prodValid.dashboardPassword}}"
  let adminTok := (((OrbBin.Json.parse (String.fromUTF8? admBody |>.getD "")).toOption.getD (.obj #[])) |>.fieldStr? "token").getD ""
  let (_, cBobBody, _) ← sendReqHdr "POST" "/api/admin/users" adminTok "{\"username\":\"bob\",\"password\":\"bob-zw-pass-987654\",\"role\":\"member\"}"
  let bobId := (((OrbBin.Json.parse (String.fromUTF8? cBobBody |>.getD "")).toOption.getD (.obj #[])) |>.fieldStr? "id").getD ""
  let (_, bobLogBody, _) ← sendReqHdr "POST" "/api/auth/login" "" "{\"username\":\"bob\",\"password\":\"bob-zw-pass-987654\"}"
  let bobTok := (((OrbBin.Json.parse (String.fromUTF8? bobLogBody |>.getD "")).toOption.getD (.obj #[])) |>.fieldStr? "token").getD ""
  if adminTok.isEmpty || bobId.isEmpty || bobTok.isEmpty then
    return (← fail "login setup failed")

  -- 1. Seed missions across projects & timestamps + archived mission, and verify SQL filtering on `/api/control/missions`
  let .ok () ← upsertMission store {
    id := "m-zw-fast-old", title := "Fast Old", status := "completed", backend := "codex",
    modelOverride := "", modelEffort := "", workingDirectory := zwRoot, project := "proj-fast",
    updatedAt := "1700000100", totalCostCents := 5, ownerUserId := bootAdminId
  } | return (← fail "upsert m-zw-fast-old")
  let .ok () ← upsertMission store {
    id := "m-zw-fast-new", title := "Fast New", status := "active", backend := "codex",
    modelOverride := "", modelEffort := "", workingDirectory := zwRoot, project := "proj-fast",
    updatedAt := "1700000500", totalCostCents := 10, ownerUserId := bootAdminId
  } | return (← fail "upsert m-zw-fast-new")
  let .ok () ← upsertMission store {
    id := "m-zw-fast-ack", title := "Fast Archived", status := "acknowledged", backend := "codex",
    modelOverride := "", modelEffort := "", workingDirectory := zwRoot, project := "proj-fast",
    updatedAt := "1700000600", totalCostCents := 1, ownerUserId := bootAdminId
  } | return (← fail "upsert m-zw-fast-ack")
  let .ok () ← upsertMission store {
    id := "m-zw-other", title := "Other Project", status := "awaiting_user", backend := "codex",
    modelOverride := "", modelEffort := "", workingDirectory := zwRoot, project := "proj-other",
    updatedAt := "2026-11-11T08:00:00Z", totalCostCents := 2, ownerUserId := bootAdminId
  } | return (← fail "upsert m-zw-other")
  let .ok () ← upsertMission store {
    id := "m-zw-bob", title := "Bob Private", status := "awaiting_user", backend := "opencode",
    modelOverride := "", modelEffort := "", workingDirectory := zwRoot, project := s!"{bobId}:proj-fast",
    updatedAt := "1700000700", totalCostCents := 0, ownerUserId := bobId
  } | return (← fail "upsert m-zw-bob")

  let (pSt, pBytes, _) ← sendReqHdr "GET" "/api/control/missions?project=proj-fast" adminTok ""
  let pStr := String.fromUTF8? pBytes |>.getD ""
  let (paSt, paBytes, _) ← sendReqHdr "GET" "/api/control/missions?project=proj-fast&all=true" adminTok ""
  let paStr := String.fromUTF8? paBytes |>.getD ""
  let (akSt, akBytes, _) ← sendReqHdr "GET" "/api/control/missions?status=acknowledged" adminTok ""
  let akStr := String.fromUTF8? akBytes |>.getD ""
  let (dSt, dBytes, _) ← sendReqHdr "GET" "/api/control/missions?updated_since=1700000400" adminTok ""
  let dStr := String.fromUTF8? dBytes |>.getD ""
  let (limSt, limBytes, _) ← sendReqHdr "GET" "/api/control/missions?limit=1&all=true" adminTok ""
  let limStr := String.fromUTF8? limBytes |>.getD ""
  let (dLimSt, dLimBytes, _) ← sendReqHdr "GET" "/api/control/missions?limit=1&all=true&updated_since=1700000400" adminTok ""
  let dLimStr := String.fromUTF8? dLimBytes |>.getD ""
  let (badSinceSt, badSinceBytes, _) ← sendReqHdr "GET" "/api/control/missions?all=true&updated_since=not-a-timestamp" adminTok ""
  let badSinceStr := String.fromUTF8? badSinceBytes |>.getD ""
  let (bSt, bBytes, _) ← sendReqHdr "GET" "/api/control/missions?project=proj-fast" bobTok ""
  let bStr := String.fromUTF8? bBytes |>.getD ""
  if pSt != 200 || (pStr.splitOn "\"m-zw-fast-new\"").length != 2 || (pStr.splitOn "\"m-zw-fast-old\"").length != 2 ||
     (pStr.splitOn "\"m-zw-fast-ack\"").length != 1 || (pStr.splitOn "\"m-zw-other\"").length != 1 ||
     (pStr.splitOn "\"project\":\"proj-fast\"").length < 3 ||
     paSt != 200 || (paStr.splitOn "\"m-zw-fast-ack\"").length != 2 || (paStr.splitOn "\"m-zw-fast-new\"").length != 2 ||
     akSt != 200 || (akStr.splitOn "\"m-zw-fast-ack\"").length != 2 || (akStr.splitOn "\"m-zw-fast-new\"").length != 1 ||
     dSt != 200 || (dStr.splitOn "\"m-zw-fast-old\"").length != 1 || (dStr.splitOn "\"m-zw-fast-new\"").length != 2 ||
     (dStr.splitOn "\"m-zw-fast-ack\"").length != 1 || (dStr.splitOn "\"m-zw-other\"").length != 2 ||
     limSt != 200 || (limStr.splitOn "\"m-zw-other\"").length != 2 || (limStr.splitOn "\"m-zw-fast-new\"").length != 1 ||
     dLimSt != 200 || (dLimStr.splitOn "\"m-zw-other\"").length != 2 || (dLimStr.splitOn "\"m-zw-fast-ack\"").length != 2 ||
     (dLimStr.splitOn "\"m-zw-fast-new\"").length != 2 || (dLimStr.splitOn "\"m-zw-fast-old\"").length != 1 ||
     (dLimStr.splitOn "\"m-zw-bob\"").length != 1 ||
     badSinceSt != 200 || badSinceStr.trimAscii.toString != "[]" ||
     bSt != 200 || (bStr.splitOn "\"m-zw-bob\"").length != 2 || (bStr.splitOn "\"m-zw-fast-new\"").length != 1 ||
     (bStr.splitOn "\"project\":\"proj-fast\"").length != 2 then
    return (← fail s!"missions SQL filter regression: p={pStr} pa={paStr} ak={akStr} d={dStr} lim={limStr} dLim={dLimStr} bad={badSinceStr} b={bStr}")

  -- 2. Seed spine messages + 25 tool events (with 10 KB tool_result) & verify SQL pre-LIMIT `types`, `view=transcript`, `max_payload`, `/snapshot`, `/open`, and `gzip`!
  let _ ← appendMissionEvent store "m-zw-fast-new" "user_message" "{\"id\":\"u-1\",\"content\":\"Explain zero-wait caching\"}" "2026-11-11T07:00:01Z"
  let _ ← appendMissionEvent store "m-zw-fast-new" "assistant_message" "{\"id\":\"a-1\",\"content\":\"Settled answer from spine\",\"success\":true}" "2026-11-11T07:00:02Z"
  let bigOut := String.ofList (List.replicate 10000 'Z')
  for k in [0:25] do
    let _ ← appendMissionEvent store "m-zw-fast-new" "tool_result"
      s!"\{\"id\":\"tr-{k}\",\"tool_call_id\":\"call-{k}\",\"tool_name\":\"bash\",\"result\":{jsonEscape (if k == 24 then bigOut else s!"out-{k}")},\"success\":true}"
      "2026-11-11T07:00:03Z"
  let _ ← enqueueStructuredFollowup store "core" "q-zw-1" "m-zw-fast-new" "next follow-up" "desktop" s!"{nowSec}"

  let (tySt, tyBytes, _) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/events?types=user_message&limit=5" adminTok ""
  let tyStr := String.fromUTF8? tyBytes |>.getD ""
  let (vwSt, vwBytes, _) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/events?view=transcript&limit=5" adminTok ""
  let vwStr := String.fromUTF8? vwBytes |>.getD ""
  let (trSt, trBytes, _) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/events?limit=2&max_payload=256" adminTok ""
  let trStr := String.fromUTF8? trBytes |>.getD ""
  let (snSt, snBytes, _) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/snapshot?profile=presentation" adminTok ""
  let snStr := String.fromUTF8? snBytes |>.getD ""
  let (opSt, opGzBytes, opHdrs) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/open?limit=5&max_payload=512&spine_limit=10" adminTok "" "Accept-Encoding: gzip\r\n"
  let hasGzHdr := opHdrs.any (fun (k, v) => k.toLower == "content-encoding" && v == "gzip")
  let opPlainBytes := match gunzipBounded opGzBytes 1048576 with | .ok b => b | .error _ => ByteArray.empty
  let opStr := String.fromUTF8? opPlainBytes |>.getD ""
  let (opTruncSt, opTruncBytes, _) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/open?limit=5&max_payload=512&spine_limit=1" adminTok ""
  let opTruncStr := String.fromUTF8? opTruncBytes |>.getD ""
  let (bobOpSt, _, _) ← sendReqHdr "GET" "/api/control/missions/m-zw-fast-new/open" bobTok ""
  if tySt != 200 || (tyStr.splitOn "Explain zero-wait caching").length != 2 ||
     vwSt != 200 || (vwStr.splitOn "Explain zero-wait caching").length != 2 || (vwStr.splitOn "Settled answer from spine").length != 2 ||
     trSt != 200 || trBytes.size > 2500 || (trStr.splitOn "\"truncated\":true").length != 2 || (trStr.splitOn "\"tool_call_id\":\"call-24\"").length != 2 ||
     snSt != 200 || (snStr.splitOn "\"profile\":\"presentation\"").length != 2 || (snStr.splitOn "Settled answer from spine").length != 2 ||
     opSt != 200 || !hasGzHdr || opGzBytes.size >= opPlainBytes.size ||
     (opStr.splitOn "\"protocol\":1").length != 2 || (opStr.splitOn "Settled answer from spine").length < 2 ||
     (opStr.splitOn "next follow-up").length != 2 || (opStr.splitOn "\"has_more\":true").length != 2 ||
     (opStr.splitOn "\"spine_has_more\":false").length != 2 ||
     opTruncSt != 200 || (opTruncStr.splitOn "\"spine_has_more\":true").length != 2 ||
     (opTruncStr.splitOn "\"spine_next_cursor\":2").length != 2 ||
     bobOpSt != 404 then
    return (← fail s!"events/snapshot/open/gzip check failed: ty={tyStr} vw={vwStr} trSize={trBytes.size} sn={snStr} hasGz={hasGzHdr} gz={opGzBytes.size}/{opPlainBytes.size} opTrunc={opTruncStr} bobOp={bobOpSt}")

  -- 3. Live loopback TCP test: HTTP/1.1 keep-alive (2 requests on 1 socket) + `/api/control/sync` WebSocket (`orb-sync.v1`, `since_seq` replay, live push, cross-user confinement, and `inbox_answer_push`)
  let .ok (lfd, lport) ← tcpListen "127.0.0.1" 0 8
    | return (← fail "tcpListen for keep-alive & sync WS failed")
  let srvTask ← IO.asTask (prio := .dedicated) do
    for _ in [0:2] do
      if let .ok sfd ← tcpAcceptPoll lfd 5000 then
        handleClientConn app sfd true
    discard <| closeFd lfd

  -- (a) HTTP/1.1 Keep-Alive: 2 requests over 1 connected socket!
  let mut keepAliveOk := false
  if let .ok kfd ← tcpConnect "127.0.0.1" lport then
    let req1 := "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toUTF8
    let req2 := s!"GET /api/control/missions/m-zw-fast-new/snapshot?profile=presentation HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {adminTok}\r\nConnection: close\r\n\r\n".toUTF8
    discard <| writeAll kfd (req1 ++ req2) false
    let mut rxAll := ByteArray.empty
    for _ in [0:8] do
      if let .ok () ← pollReadable kfd 1000 then
        let ch ← readStreamChunk kfd 16384
        if ch.isEmpty then break else rxAll := rxAll ++ ch
      else break
    discard <| closeFd kfd
    let rxStr := String.fromUTF8? rxAll |>.getD ""
    keepAliveOk :=
      (rxStr.splitOn "Connection: keep-alive").length == 2 &&
      (rxStr.splitOn "HTTP/1.1 200 OK").length == 3 &&
      (rxStr.splitOn "\"profile\":\"presentation\"").length == 2

  -- (b) `/api/control/sync` WebSocket: `Sec-WebSocket-Protocol: orb-sync.v1, jwt.<adminTok>`
  let mut wsSyncOk := false
  if let .ok wfd ← tcpConnect "127.0.0.1" lport then
    let upgReq :=
      s!"GET /api/control/sync HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: orb-sync.v1, jwt.{adminTok}\r\n\r\n".toUTF8
    discard <| writeAll wfd upgReq false
    let mut hsBuf := ByteArray.empty
    while (LeanSys.Http.findHeaderEnd? hsBuf).isNone do
      if let .ok () ← pollReadable wfd 2000 then
        let ch ← readStreamChunk wfd 4096
        if ch.isEmpty then break
        hsBuf := hsBuf ++ ch
      else break
    let some hsEnd := LeanSys.Http.findHeaderEnd? hsBuf | do discard <| closeFd wfd; let _ := srvTask.get; return (← fail "WS handshake missing header end")
    let hsHead := String.fromUTF8? (hsBuf.extract 0 hsEnd) |>.getD ""
    let mut wsRx := hsBuf.extract hsEnd hsBuf.size
    let mask4 := ByteArray.mk #[0x37, 0xFA, 0x21, 0x3D]
    -- Subscribe to `m-zw-fast-new` with `since_seq: 26` (replaying seq 27 + `sync_caught_up`), enable `set_presentation`, AND attempt cross-user subscribe to `m-zw-bob` (must be `forbidden`)!
    let presMsg := "{\"op\":\"set_presentation\",\"enabled\":true}"
    let subMsg1 := "{\"op\":\"subscribe\",\"mission_id\":\"m-zw-fast-new\",\"since_seq\":26,\"max_payload\":512}"
    let subMsgBob := "{\"op\":\"subscribe\",\"mission_id\":\"m-zw-bob\"}"
    let pingMsg := "{\"op\":\"ping\",\"ts\":1234567}"
    for m in [presMsg, subMsg1, subMsgBob, pingMsg] do
      if let some frm := encodeFrame? { fin := true, opcode := .text, payload := m.toUTF8 } (some mask4) then
        discard <| writeAll wfd frm false
    -- Read initial `sync_ready`, `subscribed` (`presentation:true`), replay, `sync_caught_up`, `forbidden`, and `pong` before triggering live events!
    for _ in [0:5] do
      if let .ok () ← pollReadable wfd 300 then
        let ch ← readStreamChunk wfd 32768
        if !ch.isEmpty then wsRx := wsRx ++ ch
    -- Append live events on subscribed `m-zw-fast-new`, unsubscribed `m-zw-other` (`tool_call` -> `mission_activity` + `assistant_message` -> `inbox_answer_push` + `mission_presentation`), HTTP mutations (`archive` + `DELETE`), and Bob's mission (`tool_call`, `assistant_message`, `DELETE`), then revoke access on `m-zw-fast-new` and verify immediate `forbidden` unsubscribe with zero cross-user leak!
    let _ ← appendMissionEvent store "m-zw-fast-new" "text_delta" "{\"delta\":\"chunk-1\"}" "2026-11-11T07:00:59Z"
    let _ ← appendMissionEvent store "m-zw-fast-new" "assistant_message" "{\"id\":\"a-live\",\"content\":\"Live WS delta\"}" "2026-11-11T07:01:00Z"
    let _ ← appendMissionEvent store "m-zw-other" "tool_call" "{\"tool_call_id\":\"tc-pres-1\",\"tool_name\":\"bash\",\"args\":{\"cmd\":\"ls\"}}" "2026-11-11T07:01:00Z"
    let _ ← appendMissionEvent store "m-zw-other" "assistant_message" "{\"id\":\"a-inbox\",\"content\":\"Background inbox answer\"}" "2026-11-11T07:01:01Z"
    let (archCode, _, _) ← sendReqHdr "POST" "/api/control/missions/m-zw-other/archive" adminTok "{\"archived\":true}"
    let (delOwnCode, _, _) ← sendReqHdr "DELETE" "/api/control/missions/m-zw-fast-ack" adminTok ""
    let _ ← appendMissionEvent store "m-zw-bob" "tool_call" "{\"tool_call_id\":\"tc-bob\",\"tool_name\":\"secret_tool\",\"args\":{}}" "2026-11-11T07:01:02Z"
    let _ ← appendMissionEvent store "m-zw-bob" "assistant_message" "{\"id\":\"a-bob-secret\",\"content\":\"Bob secret answer\"}" "2026-11-11T07:01:02Z"
    let (delBobCode, _, _) ← sendReqHdr "DELETE" "/api/control/missions/m-zw-bob" bobTok ""
    if archCode != 200 || delOwnCode != 200 || delBobCode != 200 then
      discard <| closeFd wfd
      let _ := srvTask.get
      return (← fail s!"HTTP mutation codes failed: arch={archCode} delOwn={delOwnCode} delBob={delBobCode}")
    IO.sleep 35
    for _ in [0:6] do
      if let .ok () ← pollReadable wfd 250 then
        let ch ← readStreamChunk wfd 32768
        if !ch.isEmpty then wsRx := wsRx ++ ch
    -- Revoke `bootAdminId`'s access to `m-zw-fast-new` while the WebSocket subscription is still open!
    discard <| execParamQuery store.missionsDb
      "UPDATE missions SET owner_user_id=?2 WHERE id=?1;" #["m-zw-fast-new", bobId]
    let _ ← appendMissionEvent store "m-zw-fast-new" "assistant_message" "{\"id\":\"a-revoked\",\"content\":\"Revoked post-share secret\"}" "2026-11-11T07:01:03Z"
    IO.sleep 25
    for _ in [0:3] do
      if let .ok () ← pollReadable wfd 250 then
        let ch ← readStreamChunk wfd 32768
        if !ch.isEmpty then wsRx := wsRx ++ ch
    -- Bump `bootAdminId`'s `session_epoch` while the socket is open -> must drop live delivery and close with 1008!
    discard <| execParamQuery store.missionsDb
      "UPDATE users SET session_epoch = session_epoch + 1 WHERE id=?1;" #[bootAdminId]
    let _ ← appendMissionEvent store "m-zw-other" "assistant_message" "{\"id\":\"a-post-epoch\",\"content\":\"Post-epoch-bump secret\"}" "2026-11-11T07:01:04Z"
    IO.sleep 35
    for _ in [0:3] do
      if let .ok () ← pollReadable wfd 250 then
        let ch ← readStreamChunk wfd 32768
        if !ch.isEmpty then wsRx := wsRx ++ ch
    discard <| closeFd wfd
    let mut decodedTexts : Array String := #[]
    let mut sawAuthClose := false
    let mut parseMore := true
    while parseMore do
      match decodeFramePrefix wsRx false with
      | .ok (some (frm, cons)) =>
        wsRx := wsRx.extract cons wsRx.size
        if frm.opcode == .text then
          decodedTexts := decodedTexts.push (String.fromUTF8? frm.payload |>.getD "")
        else if frm.opcode == .close then
          sawAuthClose := true
      | _ => parseMore := false
    let allWs := String.intercalate "\n" decodedTexts.toList
    wsSyncOk :=
      sawAuthClose &&
      (hsHead.splitOn "101 Switching Protocols").length == 2 &&
      (hsHead.splitOn "Sec-WebSocket-Protocol: orb-sync.v1").length == 2 &&
      (allWs.splitOn "\"type\":\"sync_ready\"").length == 2 &&
      (allWs.splitOn "\"type\":\"subscribed\",\"presentation\":true").length == 2 &&
      (allWs.splitOn "\"type\":\"sync_caught_up\"").length == 2 &&
      (allWs.splitOn "\"replayed\":1").length == 2 &&
      (allWs.splitOn "\"error\":\"forbidden\"").length == 3 &&
      (allWs.splitOn "\"type\":\"pong\",\"ts\":1234567").length == 2 &&
      (allWs.splitOn "\"mode\":\"delta\"").length == 2 &&
      (allWs.splitOn "Live WS delta").length == 2 &&
      (allWs.splitOn "\"type\":\"inbox_answer_push\"").length == 2 &&
      (allWs.splitOn "Background inbox answer").length == 2 &&
      (allWs.splitOn "\"type\":\"mission_presentation\",\"mission_id\":\"m-zw-other\",\"kind\":\"mission_activity\",\"label\":\"Running bash\"").length == 2 &&
      (allWs.splitOn "\"type\":\"mission_presentation\",\"mission_id\":\"m-zw-other\",\"kind\":\"mission_updated\"").length == 2 &&
      (allWs.splitOn "\"type\":\"mission_presentation\",\"mission_id\":\"m-zw-fast-ack\",\"kind\":\"mission_deleted\"").length == 2 &&
      (allWs.splitOn "\"m-zw-bob\"").length == 2 &&
      (allWs.splitOn "secret_tool").length == 1 &&
      (allWs.splitOn "Bob secret answer").length == 1 &&
      (allWs.splitOn "Revoked post-share secret").length == 1 &&
      (allWs.splitOn "Post-epoch-bump secret").length == 1

  let _ := srvTask.get
  if !keepAliveOk || !wsSyncOk then
    return (← fail s!"keepAliveOk={keepAliveOk} wsSyncOk={wsSyncOk}")

  -- 5. Concurrent `appendMissionEvent` writers deliver notifications in strictly monotonic committed `seq` order,
  --    AND a slow/blocked listener never blocks `appendMissionEvent` callers or healthy listeners.
  let seenSeqsMu ← Std.Mutex.new (#[] : Array UInt64)
  let slowBlockedProm ← IO.Promise.new (α := Unit)
  let unregSlow ← registerMissionEventListener store fun mid _ _ _ _ => do
    if mid == "m-zw-slow" then
      let _ := slowBlockedProm.result?.get
  let unregOrder ← registerMissionEventListener store fun mid seq _ _ _ => do
    if mid == "m-zw-order" then
      -- Introduce jitter for odd sequences so an unordered post-commit broadcast would invert N+1 ahead of N
      if seq % 2 == 1 then IO.sleep 5
      seenSeqsMu.atomically do modify (·.push seq)
  let mut writerTasks : Array (Task (Except IO.Error (Except String UInt64))) := #[]
  for idx in [0:16] do
    let t ← IO.asTask <|
      appendMissionEvent store "m-zw-order" "tool_result"
        s!"\{\"id\":\"ord-{idx}\",\"tool_call_id\":\"c-{idx}\",\"tool_name\":\"bash\",\"result\":\"ok\",\"success\":true}"
        "2026-11-11T07:05:00Z"
    writerTasks := writerTasks.push t
  for t in writerTasks do
    let _ ← IO.ofExcept t.get
  for _ in [0:100] do
    if (← seenSeqsMu.atomically get).size < 16 then
      IO.sleep 5
  -- Now trigger `m-zw-slow` (whose listener blocks on `slowBlockedProm`), and verify a subsequent `appendMissionEvent`
  -- on another mission returns immediately without blocking on the stalled listener!
  let _ ← appendMissionEvent store "m-zw-slow" "tool_result" "{\"id\":\"s-1\"}" "2026-11-11T07:05:01Z"
  IO.sleep 10
  let t0Ms ← IO.monoMsNow
  let nonBlockingRes ← appendMissionEvent store "m-zw-other" "tool_result" "{\"id\":\"fast-after-slow\"}" "2026-11-11T07:05:02Z"
  let elapsedMs := (← IO.monoMsNow) - t0Ms
  slowBlockedProm.resolve ()
  for _ in [0:50] do
    if let some dMu := store.eventDispatchState? then
      if ← dMu.atomically (do return (← get).draining) then IO.sleep 2
  unregSlow
  unregOrder
  let seenSeqs ← seenSeqsMu.atomically get
  let expectedSeqs : Array UInt64 := (List.range 16).toArray.map (fun k => (k + 1).toUInt64)
  if seenSeqs != expectedSeqs || !nonBlockingRes.isOk || elapsedMs > 500 then
    return (← fail s!"concurrent/nonblocking appendMissionEvent failed: seqs={repr seenSeqs} elapsedMs={elapsedMs}")

  closeCoreStore store
  cleanup
  return 0

set_option maxHeartbeats 800000 in
set_option maxRecDepth 8000 in
private def runProdParityAndMissionMoveTests (_baseCfg : CoreConfig) : IO UInt32 := do
  let ts ← IO.monoNanosNow
  let workRoot := s!"/tmp/orb_prod_parity_{ts}"
  let dataRoot := s!"{workRoot}/.sandboxed-sh"
  let cleanup : IO Unit := do
    discard <| (IO.FS.removeDirAll workRoot).toBaseIO
  cleanup
  IO.FS.createDirAll (System.FilePath.mk s!"{dataRoot}/missions")
  IO.FS.createDirAll (System.FilePath.mk s!"{dataRoot}/project-files/verity-core/Audits")
  IO.FS.writeFile (System.FilePath.mk s!"{dataRoot}/project-files/verity-core/Audits/report.md") "# Audit\n"

  -- 1. Seed legacy `missions-prod.db` with `Pareto`, legacy `orb-folder:Audits` mission,
  -- AND exact legacy `mission_events` DDL (`sequence`/`timestamp` NOT NULL, NO `seq` column yet!)
  let legMissionsPath := s!"{dataRoot}/missions/missions-prod.db"
  let seedSql :=
    "CREATE TABLE IF NOT EXISTS missions (id TEXT PRIMARY KEY NOT NULL, title TEXT, status TEXT NOT NULL DEFAULT 'awaiting_user', backend TEXT NOT NULL DEFAULT 'codex', workspace_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000', working_directory TEXT, project TEXT, tags TEXT, created_at TEXT NOT NULL DEFAULT '2026-11-01T00:00:00Z', updated_at TEXT NOT NULL DEFAULT '', parent_mission_id TEXT);" ++
    "CREATE TABLE IF NOT EXISTS mission_events (id INTEGER PRIMARY KEY AUTOINCREMENT, mission_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_type TEXT NOT NULL, timestamp TEXT NOT NULL, event_id TEXT, tool_call_id TEXT, tool_name TEXT, content TEXT, content_file TEXT, metadata TEXT, FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE);" ++
    "INSERT INTO missions(id,title,status,backend,workspace_id,working_directory,project,tags,created_at,updated_at) VALUES('8a349331-41cf-4223-a25f-459c00cd0d98','Pareto','awaiting_user','codex','00000000-0000-0000-0000-000000000000','/tmp','verity-core','[]','2026-11-10T09:00:00Z','2026-11-10T10:00:00Z');" ++
    "INSERT INTO missions(id,title,status,backend,workspace_id,working_directory,project,tags,created_at,updated_at) VALUES('c1665d11-0000-4000-8000-000000000001','Legacy Audit','completed','codex','00000000-0000-0000-0000-000000000000','/tmp','verity-core','[\"orb-folder:Audits\",\"audit\"]','2026-11-01T11:00:00Z','2026-11-01T12:00:00Z');" ++
    "INSERT INTO mission_events(mission_id,sequence,event_type,timestamp,content) VALUES('8a349331-41cf-4223-a25f-459c00cd0d98',1,'user_message','2026-11-10T09:00:01Z','Audit Pareto invariants');"
  let .ok preDb ← openSqliteDb legMissionsPath seedSql #[]
    | do cleanup; IO.eprintln "[orb-core-test] FAIL: seed legacy Pareto db failed"; return 1
  sqliteCloseRaw preDb.handle

  let store ← match ← openCoreStore dataRoot 0 "prod" with
    | .ok s => pure s
    | .error openErr => cleanup; IO.eprintln s!"[orb-core-test] FAIL: openCoreStore on Pareto db failed: {openErr}"; return 1
  let .ok () ← ensureQueueContSchema store
    | do closeCoreStore store; cleanup; IO.eprintln "[orb-core-test] FAIL: ensureQueueContSchema on Pareto db failed"; return 1
  let .ok mStore ← openManagedComputeStore s!"{dataRoot}/managed_compute.db"
    | do closeCoreStore store; cleanup; IO.eprintln "[orb-core-test] FAIL: openManagedComputeStore failed"; return 1

  let fail (msg : String) : IO UInt32 := do
    closeManagedComputeStore mStore
    closeCoreStore store
    cleanup
    IO.eprintln s!"[orb-core-test] FAIL (prod-parity): {msg}"
    return 1

  -- Verify online `orb-folder:Audits` migration preserved `updated_at` and stripped `orb-folder:` tag
  let migRows ← execParamQuery store.missionsDb
    "SELECT folder, tags, updated_at FROM missions WHERE id='c1665d11-0000-4000-8000-000000000001';" #[]
  let migFolder := match migRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let migTags := match migRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let migUpd := match migRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  if migFolder != "Audits" || (migTags.splitOn "orb-folder:").length > 1 || migUpd != "2026-11-01T12:00:00Z" then
    return (← fail s!"orb-folder online migration mismatch: folder={migFolder} tags={migTags} upd={migUpd}")

  -- 2. Verify `<encrypted v=\"1\">` AES-256-GCM + `eyJ...` HS256 JWT + `pbkdf2:` legacy hash
  let .ok key32 ← loadOrCreatePrivateKeyBytes workRoot dataRoot
    | return (← fail "loadOrCreatePrivateKeyBytes failed")
  let .ok encSecret ← encryptEnvValue key32 "super-secret-value-42"
    | return (← fail "encryptEnvValue failed")
  let .ok decSecret ← decryptEnvValue (some key32) encSecret
    | return (← fail "decryptEnvValue failed")
  if !isEncryptedValue encSecret || decSecret != "super-secret-value-42" then
    return (← fail s!"encrypted v=1 roundtrip mismatch: enc={encSecret} dec={decSecret}")

  let jwtSec := "prod-parity-jwt-secret-0123456789abcdef"
  let nowSec : UInt64 := 1794400000
  let hsJwt := issueHs256Jwt jwtSec "prod" "admin" nowSec (nowSec + 86400) "admin"
  if !hsJwt.startsWith "eyJ" || (verifyHs256Jwt? jwtSec hsJwt nowSec).isNone then
    return (← fail "HS256 JWT roundtrip failed")

  let cfg : CoreConfig := {
    host := "127.0.0.1"
    port := 3000
    workingDir := workRoot
    devMode := false
    dashboardPassword := "strong-prod-pass-1234"
    jwtSecret := jwtSec
  }
  let _ ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] s!"{nowSec}"
  hydrateLegacyDataDir workRoot dataRoot store mStore "" false
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 20 } : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (0 : UInt64)
  let bHub ← newBroadcastHub
  let rHub ← newRelayHub 0
  let cHub ← newCloudRuntimeHub
  let pHub ← newProviderRuntimeHub
  let sHub ← newSystemRuntimeHub
  let appSt : CoreAppState := {
    cfg := { cfg with githubClientId := "Ov23liTestClientId" }
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef
    proxyCooldownsRef := cooldownsRef
    seqRef := seqRef
    managedStore? := some mStore
    broadcastHub? := some bHub
    relayHub? := some rHub
    cloudHub? := some cHub
    providerHub? := some pHub
    systemHub? := some sHub
  }

  let sendJson (method path tok body : String) : IO (Nat × String) := do
    let bBytes := body.toUTF8
    let authLine := if tok.isEmpty then "" else s!"Authorization: Bearer {tok}\r\n"
    let rawWire :=
      (s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authLine}" ++
       s!"Content-Type: application/json\r\nContent-Length: {bBytes.size}\r\n\r\n").toUTF8 ++ bBytes
    match parseRequest rawWire none with
    | .error _ => return (599, "parse_err")
    | .ok req =>
      match ← dispatchCoreRequest appSt req nowSec with
      | .error _ => return (101, "")
      | .ok r => return (r.status, (String.fromUTF8? r.body).getD "")

  -- Authenticate with `eyJ...` HS256 JWT and list `verity-core` missions
  let (listSt, listBody) ← sendJson "GET" "/api/control/missions?project=verity-core" hsJwt ""
  if listSt != 200 ||
     (listBody.splitOn "8a349331-41cf-4223-a25f-459c00cd0d98").length < 2 ||
     (listBody.splitOn "\"folder\":\"Audits\"").length < 2 then
    return (← fail s!"GET /api/control/missions with eyJ JWT failed: {listSt} {listBody}")

  -- Verify legacy `mission_events` (`sequence=1`, `seq=0`, `content`) works on `/messages` + sync replay + follow-up `/api/control/message`
  let (msgGetSt, msgGetBody) ← sendJson "GET" "/api/control/missions/8a349331-41cf-4223-a25f-459c00cd0d98/messages" hsJwt ""
  let replayRes ← queryMissionSyncReplayFrames store "8a349331-41cf-4223-a25f-459c00cd0d98" (some 0)
  let (postMsgSt, _) ← sendJson "POST" "/api/control/message" hsJwt
    "{\"mission_id\":\"8a349331-41cf-4223-a25f-459c00cd0d98\",\"content\":\"Follow-up on Pareto\"}"
  let replayOk := match replayRes with
    | .ok (frames, maxSeq, false) => frames.size == 1 && maxSeq == 1
    | _ => false
  if msgGetSt != 200 || (msgGetBody.splitOn "Audit Pareto invariants").length < 2 || !replayOk || postMsgSt != 200 then
    return (← fail s!"legacy mission_events messages/replay/post failed: get={msgGetSt}:{msgGetBody} replayOk={replayOk} post={postMsgSt}")

  -- 3. Move `Pareto` into `Audits` inside `verity-core` (`POST /api/control/missions/move`)
  let (_, subQ) ← registerSseSubscriber bHub none
  let (mvSt, mvBody) ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"8a349331-41cf-4223-a25f-459c00cd0d98\"],\"project\":\"verity-core\",\"folder\":\"Audits\",\"client_op_id\":101,\"client_id\":\"cli-1\"}"
  let sseEvs ← subQ.get
  let pRows ← execParamQuery store.missionsDb
    "SELECT folder, placement_revision, updated_at FROM missions WHERE id='8a349331-41cf-4223-a25f-459c00cd0d98';" #[]
  let pFolder := match pRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let pRev := match pRows with | .ok rs => ((rs[1]?.bind (·[1]?)).bind String.toNat?).getD 0 | .error _ => 0
  let pUpd := match pRows with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  if mvSt != 200 || pFolder != "Audits" || pRev < 2 || pUpd != "2026-11-10T10:00:00Z" ||
     sseEvs.isEmpty || (mvBody.splitOn "\"client_op_id\":101").length < 2 then
    return (← fail s!"Pareto move failed: st={mvSt} body={mvBody} folder={pFolder} rev={pRev} upd={pUpd} sse={sseEvs.size}")

  -- Fork group leader vs non-leader + `/btw` side child (`folder = ""`)
  -- `f-lead` has the newer `updated_at` (`11:05`), so `f-lead` is the fork group leader and `f-child` (`11:01`) is a non-leader version.
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO missions(id,title,status,backend,working_directory,project,folder,tags,created_at,updated_at) VALUES" ++
     "('f-lead','Leader','awaiting_user','codex','/tmp','verity-core','Specs','[]','2026-11-10T11:00:00Z','2026-11-10T11:05:00Z')," ++
     "('f-child','Fork Child','awaiting_user','codex','/tmp','verity-core','Specs','[\"fork-of:f-lead\"]','2026-11-10T11:01:00Z','2026-11-10T11:01:00Z')," ++
     "('f-btw','Side Question','awaiting_user','codex','/tmp','verity-core','','[\"btw-parent:f-lead\"]','2026-11-10T11:02:00Z','2026-11-10T11:02:00Z');") #[]
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET parent_mission_id='f-lead' WHERE id='f-child';" #[]
  let (mvChildSt, _) ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"f-child\"],\"project\":\"verity-core\",\"folder\":\"Drafts\"}"
  let leadAfterChild ← execParamQuery store.missionsDb "SELECT folder FROM missions WHERE id='f-lead';" #[]
  let leadF1 := match leadAfterChild with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let _ ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"f-child\"],\"project\":\"verity-core\",\"folder\":\"Specs\"}"
  let (mvLeadSt, _) ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"f-lead\"],\"project\":\"verity-core\",\"folder\":\"Reviews\"}"
  let famRows ← execParamQuery store.missionsDb
    "SELECT id, folder FROM missions WHERE id IN ('f-lead','f-child','f-btw') ORDER BY id ASC;" #[]
  let famStr := match famRows with | .ok rs => rowsToJsonArray rs | .error _ => ""
  if mvChildSt != 200 || leadF1 != "Specs" || mvLeadSt != 200 ||
     (famStr.splitOn "\"id\":\"f-child\",\"folder\":\"Reviews\"").length < 2 ||
     (famStr.splitOn "\"id\":\"f-btw\",\"folder\":\"\"").length < 2 then
    return (← fail s!"fork/btw move family rules failed: leadF1={leadF1} fam={famStr}")

  -- Cross-project `409 approval_transfer_confirmation_required` + `revoke` + `mcp_sessions_v1` live rebind
  IO.FS.writeFile (System.FilePath.mk s!"{dataRoot}/secret_broker.json")
    "{\"grants\":[{\"id\":\"g-1\",\"mission_id\":\"8a349331-41cf-4223-a25f-459c00cd0d98\",\"secret_name\":\"ETH_RPC\",\"project\":\"verity-core\"}],\"requests\":[]}"
  let (mcpSessSt, mcpSessBody) ← sendJson "POST" "/api/mcp/session" hsJwt
    "{\"mission_id\":\"8a349331-41cf-4223-a25f-459c00cd0d98\",\"role\":\"executor\",\"project\":\"verity-core\"}"
  let (xpCheckSt, xpCheckBody) ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"8a349331-41cf-4223-a25f-459c00cd0d98\"],\"project\":\"paloma\",\"folder\":\"\",\"approval_policy\":\"check\"}"
  let (xpRevSt, _) ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"8a349331-41cf-4223-a25f-459c00cd0d98\"],\"project\":\"paloma\",\"folder\":\"\",\"approval_policy\":\"revoke\"}"
  let rebRows ← execParamQuery store.projectsDb
    "SELECT project_scope FROM mcp_sessions_v1 WHERE mission_id='8a349331-41cf-4223-a25f-459c00cd0d98';" #[]
  let rebScope := match rebRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if mcpSessSt != 200 || xpCheckSt != 409 ||
     (xpCheckBody.splitOn "approval_transfer_confirmation_required").length < 2 ||
     xpRevSt != 200 || rebScope != "paloma" then
    return (← fail s!"cross-project approval/MCP rebind failed: sess={mcpSessSt}:{mcpSessBody} chk={xpCheckSt}:{xpCheckBody} rev={xpRevSt} reb={rebScope}")

  -- Move Pareto back into `verity-core` / `Audits`, then rename folder `Audits` -> `SecurityAudits` via `/file/transfer`
  let _ ← sendJson "POST" "/api/control/missions/move" hsJwt
    "{\"mission_ids\":[\"8a349331-41cf-4223-a25f-459c00cd0d98\"],\"project\":\"verity-core\",\"folder\":\"Audits\",\"approval_policy\":\"keep\"}"
  let (tfSt, tfBody) ← sendJson "POST" "/api/projects/verity-core/file/transfer" hsJwt
    "{\"path\":\"Audits\",\"destination\":\"SecurityAudits\",\"copy\":false}"
  let cascRows ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM missions WHERE project='verity-core' AND folder='SecurityAudits';" #[]
  let cascCnt := match cascRows with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  if tfSt != 200 || cascCnt != 2 || (tfBody.splitOn "\"folder\":\"SecurityAudits\"").length < 3 then
    return (← fail s!"project folder transfer cascade failed: st={tfSt} body={tfBody} cnt={cascCnt}")

  -- 4. MCP tool call (`list_projects`, `get_compute_fleet`) + Legacy Hermes `mcp1.*` coordinator token compatibility
  let legMcpDerivedKey := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes s!"sandboxed-mcp-v1:{jwtSec}".toUTF8)
  let legMcpHdr := OrbBin.PosixExt.base64Encode "{\"typ\":\"JWT\",\"alg\":\"HS256\"}".toUTF8 true false
  let legMcpPay := OrbBin.PosixExt.base64Encode s!"\{\"sub\":\"prod\",\"username\":\"prod\",\"role\":\"coordinator\",\"mission_id\":null,\"project\":null,\"session_id\":\"f3f30e30-a193-464c-bd71-28cda258ef64\",\"exp\":{nowSec + 3600}}".toUTF8 true false
  let legMcpSig := OrbBin.PosixExt.base64Encode (LeanSys.Auth.hmacSha256Bytes legMcpDerivedKey.toUTF8 s!"{legMcpHdr}.{legMcpPay}".toUTF8) true false
  let legHermesTok := s!"mcp1.{legMcpHdr}.{legMcpPay}.{legMcpSig}"
  let _ ← execParamQuery store.projectsDb
    "INSERT INTO mcp_sessions_v1(id,owner,mission_id,expires_at,revoked,subject_kind) VALUES('f3f30e30-a193-464c-bd71-28cda258ef64','prod','',?1,0,'mission');"
    #[s!"{nowSec + 3600}"]
  let (legCapSt, legCapBody) ← sendJson "GET" "/api/mcp/capabilities" legHermesTok ""
  let (legRenewSt, legRenewBody) ← sendJson "POST" "/api/mcp/renew" legHermesTok "{}"
  if legCapSt != 200 || (legCapBody.splitOn "\"role\":\"coordinator\"").length < 2 || legRenewSt != 200 then
    return (← fail s!"legacy Hermes mcp1 token failed: cap={legCapSt}:{legCapBody} renew={legRenewSt}:{legRenewBody}")

  let (mcpCallSt, mcpCallBody) ← sendJson "POST" "/api/mcp/call" hsJwt
    "{\"name\":\"list_projects\",\"arguments\":{}}"
  let (mcpFleetSt, mcpFleetBody) ← sendJson "POST" "/api/mcp/call" hsJwt
    "{\"name\":\"get_compute_fleet\",\"arguments\":{}}"
  if mcpCallSt != 200 || (mcpCallBody.splitOn "\"ok\":true").length < 2 ||
     mcpFleetSt != 200 || (mcpFleetBody.splitOn "\"ok\":true").length < 2 then
    return (← fail s!"MCP gateway call failed: proj={mcpCallSt}:{mcpCallBody} fleet={mcpFleetSt}:{mcpFleetBody}")

  -- 4b. Project roster parity (`listProjectsJVal`): no phantom inferred mission-tag projects,
  --     `routes.json` alias folding (`verity` -> `verity-core`), and `board-overrides.json` archiving.
  let _ ← execParamQuery store.missionsDb
    "INSERT OR IGNORE INTO missions(id,status,title,project,folder,owner_user_id,created_at,updated_at) VALUES('m-phantom-proj','completed','Old','verity-phase1k-fix','','prod','2026-08-05T00:00:00Z','2026-08-05T00:00:00Z');" #[]
  let _ ← OrbCore.ProjectFilesAndController.upsertProjectRecord store "verity" "verity" "Legacy Verity" "" "active" "" "2026-08-16T00:00:00Z" (some "prod")
  let _ ← OrbCore.ProjectFilesAndController.upsertProjectRecord store "verity-core" "verity-core" "Ethereum" "" "active" "" "2026-11-12T00:00:00Z" (some "prod")
  let _ ← OrbCore.ProjectFilesAndController.upsertProjectRecord store "sandboxed-sh-dev" "sandboxed-sh-dev" "sandboxed-sh-dev" "" "active" "" "2026-11-12T00:00:00Z" (some "prod")
  let hermesProjDir := s!"{workRoot}/.hermes-projects-test"
  IO.FS.createDirAll (System.FilePath.mk hermesProjDir)
  IO.FS.writeFile (System.FilePath.mk s!"{hermesProjDir}/routes.json") "{\"verity\":\"verity-core\"}"
  IO.FS.writeFile (System.FilePath.mk s!"{hermesProjDir}/board-overrides.json") "{\"sandboxed-sh-dev\":\"archived\",\"verity\":\"archived\"}"
  let dedupedProjs ← OrbCore.ProjectFilesAndController.listProjectsJVal store "prod" "prod" false false (some hermesProjDir)
  let dedupedJson := OrbBin.Json.renderCompact (.arr dedupedProjs)
  if (dedupedJson.splitOn "\"slug\":\"verity-phase1k-fix\"").length > 1 ||
     (dedupedJson.splitOn "\"slug\":\"verity\"").length > 1 ||
     (dedupedJson.splitOn "\"slug\":\"sandboxed-sh-dev\"").length > 1 ||
     (dedupedJson.splitOn "\"slug\":\"verity-core\"").length != 2 ||
     (dedupedJson.splitOn "\"title\":\"Ethereum\"").length < 2 then
    return (← fail s!"listProjectsJVal alias/override/phantom parity failed: {dedupedJson}")

  let fleetBoat : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 20 }
  let .ok () ← saveManagedFleetConfig mStore true true 5000 0 20
    | return (← fail "enable managed provider fixture failed")
  let vmBoat : ManagedMachine := {
    id := "vm-boat-1", sandboxName := "orb-managed-vm-boat-1", provider := "boat",
    size := "medium", status := "ready", spentCents := 0, nodeBootEpoch := 1, deletableAtSec := nowSec + 3600
  }
  let .ok _ ← provisionReadyFixture mStore fleetBoat vmBoat nowSec
    | return (← fail "provisionManagedMachine vm-boat-1 failed")
  let .ok () ← putEnrollmentToken mStore "vm-boat-1" "enroll-secret-1"
    | return (← fail "putEnrollmentToken vm-boat-1 failed")
  let (enrSt, enrBody) ← sendJson "POST" "/api/managed-machines/enroll" ""
    "{\"machine_id\":\"vm-boat-1\",\"enroll_token\":\"enroll-secret-1\",\"node_boot_epoch\":1}"
  let nodeTok := ((OrbBin.Json.parse enrBody).toOption.getD (.obj #[]) |>.fieldStr? "node_token").getD ""
  if enrSt != 200 || nodeTok.isEmpty then
    return (← fail s!"managed node enroll failed: {enrSt} {enrBody}")

  let pollWorker ← IO.asTask (prio := .dedicated) do
    for _ in [0:40] do
      let pollWire :=
        (s!"GET /api/managed-machines/relay/poll HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++
         s!"Authorization: Bearer {nodeTok}\r\nX-Orb-Machine-Id: vm-boat-1\r\nX-Orb-Boot-Epoch: 1\r\n\r\n").toUTF8
      if let .ok pReq := parseRequest pollWire none then
        if let .ok pResp ← dispatchCoreRequest appSt pReq nowSec then
          let pStr := (String.fromUTF8? pResp.body).getD "[]"
          if let .ok (.arr reqs) := OrbBin.Json.parse pStr then
            if let some r0 := reqs[0]? then
              let rid := (r0.fieldStr? "id").getD ""
              if !rid.isEmpty then
                let b64 := OrbBin.PosixExt.base64Encode "{\"healthy\":true}".toUTF8
                let respBody := s!"\{\"id\":{jsonEscape rid},\"status\":200,\"headers\":[[\"Content-Type\",\"application/json\"]],\"body_b64\":{jsonEscape b64}}"
                let rbBytes := respBody.toUTF8
                let respWire :=
                  (s!"POST /api/managed-machines/relay/respond HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++
                   s!"Authorization: Bearer {nodeTok}\r\nX-Orb-Machine-Id: vm-boat-1\r\nX-Orb-Boot-Epoch: 1\r\n" ++
                   s!"Content-Type: application/json\r\nContent-Length: {rbBytes.size}\r\n\r\n").toUTF8 ++ rbBytes
                if let .ok rReq := parseRequest respWire none then
                  discard <| dispatchCoreRequest appSt rReq nowSec
                return true
      IO.sleep 20
    return false

  let tunRes ← tunnelHttpToManagedMachine rHub mStore "vm-boat-1" "GET" "/heartbeat" #[] ByteArray.empty 2000
  let _ := pollWorker.get
  match tunRes with
  | .error e => return (← fail s!"tunnelHttpToManagedMachine failed: {e}")
  | .ok tResp =>
    let tStr := (String.fromUTF8? tResp.body).getD ""
    if tResp.status != 200 || (tStr.splitOn "\"healthy\":true").length < 2 then
      return (← fail s!"tunnelHttpToManagedMachine response mismatch: st={tResp.status} body={tStr}")

  -- 5. Client/Cloud/Resources/System/Providers Parity Surface (`orb-core` cutover)
  let (caSt, caBody) ← sendJson "GET" "/api/cloud/accounts" hsJwt ""
  if caSt != 200 || (caBody.splitOn "\"grok-default\"").length < 2 ||
     (caBody.splitOn "\"cursor-default\"").length < 2 || (caBody.splitOn "\"paloma\"").length < 2 then
    return (← fail s!"GET /api/cloud/accounts failed: {caSt} {caBody}")

  let (cuSt, cuBody) ← sendJson "GET" "/api/cloud/usage" hsJwt ""
  if cuSt != 200 || (cuBody.splitOn "\"accounts\"").length < 2 then
    return (← fail s!"GET /api/cloud/usage failed: {cuSt} {cuBody}")

  let (roSt, roBody) ← sendJson "GET" "/api/resources/overview?range=6h&scope=all" hsJwt ""
  if roSt != 200 || (roBody.splitOn "\"core:host\"").length < 2 ||
     (roBody.splitOn "\"timestamps_ms\"").length < 2 || (roBody.splitOn "\"bucket_seconds\":300").length < 2 ||
     (roBody.splitOn "\"pools\"").length < 2 || (roBody.splitOn "\"links\"").length < 2 then
    return (← fail s!"GET /api/resources/overview failed: {roSt} {roBody}")

  -- The Bitwarden token lives in `settings.bitwarden.encrypted_access_token`, is never returned by
  -- `/api/settings`, and is not erased when a client writes its redacted settings copy back.
  let (bwPutSt, _) ← sendJson "PUT" "/api/bitwarden/config" hsJwt "{\"access_token\":\"0.test-token\"}"
  let (bwDaSt, _) ← sendJson "PUT" "/api/bitwarden/default-access/misc" hsJwt "{\"bitwarden_projects\":[\"proj-1\"]}"
  let (setSt, setBody) ← sendJson "GET" "/api/settings" hsJwt ""
  let (setPutSt, _) ← sendJson "PUT" "/api/settings" hsJwt "{\"bitwarden\":{},\"auto_cleanup_days\":7}"
  let (bwStSt, bwStBody) ← sendJson "GET" "/api/bitwarden/status" hsJwt ""
  if bwPutSt != 200 || bwDaSt != 200 || setSt != 200 || setPutSt != 200 || bwStSt != 200 ||
     (setBody.splitOn "access_token").length != 1 || (setBody.splitOn "\"default_access\"").length < 2 ||
     (bwStBody.splitOn "\"configured\":true").length < 2 then
    return (← fail s!"Bitwarden settings contract failed: put={bwPutSt} da={bwDaSt} settings={setSt}:{setBody} status={bwStSt}:{bwStBody}")
  let (bwDelSt, _) ← sendJson "DELETE" "/api/bitwarden/config" hsJwt ""
  let (bwSt2St, bwSt2Body) ← sendJson "GET" "/api/bitwarden/status" hsJwt ""
  let (_, setBody2) ← sendJson "GET" "/api/settings" hsJwt ""
  if bwDelSt != 200 || bwSt2St != 200 || (bwSt2Body.splitOn "\"configured\":false").length < 2 ||
     (setBody2.splitOn "\"proj-1\"").length < 2 then
    return (← fail s!"Bitwarden disconnect should drop only the token: status={bwSt2Body} settings={setBody2}")

  -- `POST /api/control/missions/:id/status`: archive and reopen a stopped mission; refuse unknown
  -- statuses, unknown missions and missions with a live run.
  discard <| execParamQuery store.missionsDb
    "INSERT INTO missions(id,title,status,backend,working_directory,updated_at) VALUES('m-status-route','Status route','completed','opencode','/tmp','2026-11-12T00:00:00Z');" #[]
  let (ackSt, ackBody) ← sendJson "POST" "/api/control/missions/m-status-route/status" hsJwt "{\"status\":\"acknowledged\"}"
  let ackRows ← execParamQuery store.missionsDb "SELECT status FROM missions WHERE id='m-status-route';" #[]
  let (reopenSt, _) ← sendJson "POST" "/api/control/missions/m-status-route/status" hsJwt "{\"status\":\"paused\"}"
  let (badSt, _) ← sendJson "POST" "/api/control/missions/m-status-route/status" hsJwt "{\"status\":\"banana\"}"
  let (missingSt, _) ← sendJson "POST" "/api/control/missions/m-no-such-mission/status" hsJwt "{\"status\":\"acknowledged\"}"
  let ackStored := match ackRows with
    | .ok rows => rows.size > 1 && rows[1]! == #["acknowledged"]
    | .error _ => false
  if ackSt != 200 || !ackStored || reopenSt != 200 || badSt != 400 || (missingSt != 404 && missingSt != 403) then
    return (← fail s!"mission status route failed: ack={ackSt}:{ackBody} stored={ackStored} reopen={reopenSt} bad={badSt} missing={missingSt}")
  -- This store may carry the current `mission_runs` shape or the legacy one; exactly one insert applies.
  discard <| execParamQuery store.missionsDb
    "INSERT INTO mission_runs(id,mission_id,generation,execution_state) VALUES('run-status-route','m-status-route',1,'running');" #[]
  discard <| execParamQuery store.missionsDb
    "INSERT INTO mission_runs(run_id,mission_id,generation,execution_state,started_at) VALUES('run-status-route','m-status-route',1,'running','2026-11-12T00:00:00Z');" #[]
  let (liveSt, _) ← sendJson "POST" "/api/control/missions/m-status-route/status" hsJwt "{\"status\":\"acknowledged\"}"
  if liveSt != 409 then
    return (← fail s!"status change over a live run must be refused, got {liveSt}")

  let (puSt, puBody) ← sendJson "GET" "/api/ai/providers/usage" hsJwt ""
  if puSt != 200 || (puBody.splitOn "\"entries\"").length < 2 || (puBody.splitOn "\"refresh_after_seconds\"").length < 2 then
    return (← fail s!"GET /api/ai/providers/usage failed: {puSt} {puBody}")

  let (usSt, usBody) ← sendJson "GET" "/api/ai/usage/summary?window=24h" hsJwt ""
  let (mrhSt, mrhBody) ← sendJson "GET" "/api/model-routing/health" hsJwt ""
  if usSt != 200 || (usBody.splitOn "\"totals\"").length < 2 || mrhSt != 200 then
    return (← fail s!"AI usage summary / model-routing health failed: us={usSt}:{usBody} mrh={mrhSt}:{mrhBody}")

  let (frSt, frBody) ← sendJson "POST" "/api/file-resources" hsJwt "{\"action\":\"roots\"}"
  let (fsSt, fsBody) ← sendJson "GET" "/api/fs/list" hsJwt ""
  if frSt != 200 || (frBody.splitOn "\"sources\"").length < 2 || fsSt != 200 || !fsBody.trimAscii.toString.startsWith "[" then
    return (← fail s!"file-resources / fs/list failed: fr={frSt}:{frBody} fs={fsSt}:{fsBody}")

  let (swSt, swBody) ← sendJson "GET" "/api/software" hsJwt ""
  let (msSt, msBody) ← sendJson "GET" "/api/mesh/status" hsJwt ""
  let (ghSt, ghBody) ← sendJson "GET" "/api/integrations/github/status" hsJwt ""
  if swSt != 200 || (swBody.splitOn "\"node_name\":\"orb-core\"").length < 2 ||
     msSt != 200 || (msBody.splitOn "\"formal_verified\":true").length < 2 ||
     ghSt != 200 || (ghBody.splitOn "\"configured\":true").length < 2 then
    return (← fail s!"software/mesh/github status failed: sw={swSt}:{swBody} ms={msSt}:{msBody} gh={ghSt}:{ghBody}")

  let (idSt, idBody) ← sendJson "POST" "/api/control/missions/8a349331-41cf-4223-a25f-459c00cd0d98/inbox-digest" hsJwt "{}"
  let (ndSt, ndBody) ← sendJson "GET" "/api/nodes" hsJwt ""
  if idSt != 200 || (idBody.splitOn "\"schemaVersion\":7").length < 2 ||
     ndSt != 200 || (ndBody.splitOn "\"name\":\"orb-core\"").length < 2 then
    return (← fail s!"inbox-digest / nodes failed: id={idSt}:{idBody} nd={ndSt}:{ndBody}")

  -- Verify `GET /api/remote-nodes` includes static fleet nodes, flattened heartbeat fields,
  -- `enabled: true`, `remote_launch.typed: true`, and persisted `node_state.json` cordons.
  let .ok (mockHbFd, mockHbPort) ← tcpListen "127.0.0.1" 0 8
    | return (← fail "tcpListen mockHbFd failed")
  let hbTask ← IO.asTask (prio := .dedicated) do
    for _ in [0:2] do
      if let .ok cfd ← tcpAcceptPoll mockHbFd 3000 then
        discard <| readCoreHttpRequestFromFd cfd 1000
        let hbJson :=
          "{\"version\":\"1.3.0-lean4\",\"protocol_version\":2,\"capacity_total\":10,\"capacity_available\":9," ++
          "\"active_leases\":1,\"active_jobs\":1,\"queued_jobs\":0,\"cpu_total\":8," ++
          "\"mem_total_bytes\":68719476736,\"mem_available_bytes\":51539607552," ++
          "\"disk_total_bytes\":500000000000,\"disk_available_bytes\":400000000000," ++
          "\"lean_runtime_ready\":true,\"labels\":[\"lean\",\"docker\",\"high-memory\"],\"cordoned\":false}"
        let respBytes := encodeCoreHttpResponse (jsonResponse 200 hbJson)
        discard <| writeAll cfd respBytes false
        discard <| closeFd cfd
    discard <| closeFd mockHbFd
  IO.FS.writeFile (System.FilePath.mk s!"{dataRoot}/node_state.json") "{\"cordoned\":[\"sepolia\"]}\n"
  OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES_ENABLED" "true"
  OrbBin.PosixExt.setenvVar "SANDBOXED_PROXY_PUBLIC_URL" "https://orbrouter.thomas.md"
  OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES"
    s!"ashur=http://127.0.0.1:{mockHbPort}|ORB_TEST_ASHUR_TOK,sepolia=http://127.0.0.1:{mockHbPort}|ORB_TEST_SEPOLIA_TOK"
  OrbBin.PosixExt.setenvVar "ORB_TEST_ASHUR_TOK" "tok-ashur-1"
  OrbBin.PosixExt.setenvVar "ORB_TEST_SEPOLIA_TOK" "tok-sepolia-1"
  let (rnSt, rnBody) ← sendJson "GET" "/api/remote-nodes" hsJwt ""
  let (cordonSt, cordonBody) ← sendJson "POST" "/api/nodes/ashur/cordon" hsJwt "{}"
  let (uncordonSt, uncordonBody) ← sendJson "POST" "/api/nodes/sepolia/uncordon" hsJwt "{}"
  OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES_ENABLED"
  OrbBin.PosixExt.unsetenvVar "SANDBOXED_PROXY_PUBLIC_URL"
  OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES"
  OrbBin.PosixExt.unsetenvVar "ORB_TEST_ASHUR_TOK"
  OrbBin.PosixExt.unsetenvVar "ORB_TEST_SEPOLIA_TOK"
  let _ := hbTask.get
  let afterCordons ← OrbCore.RemoteFleetAndRelay.loadPersistedNodeCordons dataRoot
  if rnSt != 200 ||
     (rnBody.splitOn "\"enabled\":true").length < 2 ||
     (rnBody.splitOn "\"typed\":true").length < 2 ||
     (rnBody.splitOn "\"proxy_url_configured\":true").length < 2 ||
     (rnBody.splitOn "\"id\":\"ashur\"").length < 2 ||
     (rnBody.splitOn "\"high-memory\"").length < 2 ||
     (rnBody.splitOn "\"cpu_total\":8").length < 2 ||
     (rnBody.splitOn "\"core_colocated\":true").length < 2 ||
     cordonSt != 200 || (cordonBody.splitOn "\"changed\":true").length < 2 ||
     uncordonSt != 200 || (uncordonBody.splitOn "\"changed\":true").length < 2 ||
     !afterCordons.contains "ashur" || afterCordons.contains "sepolia" then
    return (← fail s!"GET /api/remote-nodes or static cordon persistence failed: rn={rnSt}:{rnBody} cordon={cordonSt}:{cordonBody} after={afterCordons}")

  -- 6. Privilege Access & Unified Approval Queue Cross-Client Parity (`shared/orb-spec/fixtures/{privilege-access,approvals}.json`)
  let d1 := computeApprovalDigest "privilege" "a1b2c3d4-0000-4000-8000-000000000010"
    (.obj #[("kind", .str "mission"), ("mission_id", .str "7c1d2e3f-0000-4000-8000-000000000001")])
    #["service_deploy", "agent-core", "", "240", "session"]
  let d2 := computeApprovalDigest "secret" "b2c3d4e5-0000-4000-8000-000000000011"
    (.obj #[
      ("kind", .str "external_session"),
      ("session_id", .str "c4d5e6f7-0000-4000-8000-000000000099"),
      ("client_kind", .str "local_mcp"),
      ("client_label", .str "claude-code"),
      ("host_hint", .str "macbook-air")
    ])
    #["read", "OPENAI_API_KEY", "", "", "", ""]
  let d3 := computeApprovalDigest "privilege" "e6f7a8b9-0000-4000-8000-000000000012"
    (.obj #[
      ("kind", .str "external_session"),
      ("session_id", .str "d5e6f7a8-0000-4000-8000-000000000088"),
      ("client_kind", .str "cli"),
      ("client_label", .str "sandboxed-mcp")
    ])
    #["ops_read", "dgx-spark", "", "60", "session"]
  if d1 != "db33f6a77e11349420b2bdea048047d3526d28a332d222062722ad1f49946db7" ||
     d2 != "2ec3bf5abecf82806835e4f60b07d65a4b1531b9e1b75ec7ce31abd4255477e6" ||
     d3 != "617ec6d41152351f09f86f601ad879216bc5b0bf94e33356e816b009e7a9579e" then
    return (← fail s!"computeApprovalDigest fixture mismatch: d1={d1} d2={d2} d3={d3}")

  let (chalSt, chalBody) ← sendJson "POST" "/api/approvals/challenge" hsJwt
    "{\"method\":\"POST\",\"path\":\"/api/privilege-access/p1/approve\",\"body\":\"{}\",\"summary\":\"grant deploy\"}"
  if chalSt != 200 || (chalBody.splitOn "\"challenge_id\":").length < 2 || (chalBody.splitOn "\"payload\":\"paloma-approval-v1\\n").length < 2 then
    return (← fail s!"POST /api/approvals/challenge failed: {chalSt} {chalBody}")

  let (paReqSt, paReqBody) ← sendJson "POST" "/api/mcp/call" hsJwt
    "{\"name\":\"request_privileged_access\",\"arguments\":{\"scope\":\"service_deploy\",\"target_host\":\"self\",\"allowed_unit\":\"sandboxed-sh-dev.service\",\"ttl_minutes\":60,\"session_scoped\":true,\"reason\":\"Deploy parity fix\"}}"
  let paReqRes := ((OrbBin.Json.parse paReqBody).toOption.getD (.obj #[])).field? "result" |>.getD (.obj #[])
  let paReqId := (paReqRes.fieldStr? "request_id").getD ""
  if paReqSt != 200 || paReqId.isEmpty || (paReqRes.fieldStr? "state") != some "pending" ||
     (paReqRes.fieldStr? "allowed_unit") != some "sandboxed-sh-dev.service" then
    return (← fail s!"MCP request_privileged_access failed: {paReqSt} {paReqBody}")

  let (paGetSt, paGetBody) ← sendJson "GET" "/api/privilege-access" hsJwt ""
  let (aqGetSt, aqGetBody) ← sendJson "GET" "/api/approvals/queue" hsJwt ""
  if paGetSt != 200 || (paGetBody.splitOn "\"state\":\"pending\"").length < 2 ||
     (paGetBody.splitOn "\"allowed_unit\":\"sandboxed-sh-dev.service\"").length < 2 ||
     (paGetBody.splitOn "\"audit\":[").length < 2 || (paGetBody.splitOn "\"command_audit\":[").length < 2 ||
     aqGetSt != 200 || (aqGetBody.splitOn "\"kind\":\"privilege\"").length < 2 ||
     (aqGetBody.splitOn "\"risk\":\"elevated\"").length < 2 then
    return (← fail s!"GET /api/privilege-access or /api/approvals/queue mismatch: pa={paGetSt}:{paGetBody} aq={aqGetSt}:{aqGetBody}")

  let (paAppSt, paAppBody) ← sendJson "POST" s!"/api/privilege-access/{paReqId}/approve" hsJwt
    "{\"ttl_minutes\":60,\"session_scoped\":true}"
  if paAppSt != 200 || (paAppBody.splitOn "\"state\":\"approved\"").length < 2 ||
     (paAppBody.splitOn "\"expires_at\":\"20").length < 2 ||
     (paAppBody.splitOn "\"lease_token\":").length > 1 then
    return (← fail s!"POST /api/privilege-access/:id/approve failed or leaked lease_token: {paAppSt} {paAppBody}")

  let (mcpListPaSt, mcpListPaBody) ← sendJson "POST" "/api/mcp/call" hsJwt
    "{\"name\":\"list_privileged_access\",\"arguments\":{}}"
  if mcpListPaSt != 200 || (mcpListPaBody.splitOn "\"lease_token\":\"orb-pl-").length < 2 then
    return (← fail s!"MCP list_privileged_access did not return owner lease_token: {mcpListPaSt} {mcpListPaBody}")

  let (paRevSt, paRevBody) ← sendJson "DELETE" s!"/api/privilege-access/{paReqId}" hsJwt ""
  if paRevSt != 200 || (paRevBody.splitOn "\"state\":\"revoked\"").length < 2 then
    return (← fail s!"DELETE /api/privilege-access/:id failed: {paRevSt} {paRevBody}")

  -- Batch `/api/approvals/approve-all` with critical confirmation check
  let (_, rootReqBody) ← sendJson "POST" "/api/privilege-access/request" hsJwt
    "{\"scope\":\"root_exec\",\"target_host\":\"self\",\"ttl_minutes\":30,\"reason\":\"Root check\"}"
  let rootReqId := (((OrbBin.Json.parse rootReqBody).toOption.getD (.obj #[])).fieldStr? "request_id").getD ""
  let (critNoConfirmSt, _) ← sendJson "POST" "/api/approvals/approve-all" hsJwt
    s!"\{\"items\":[\{\"kind\":\"privilege\",\"id\":\"{rootReqId}\",\"digest\":\"\"}],\"confirm_critical\":false}"
  let (critConfirmSt, critConfirmBody) ← sendJson "POST" "/api/approvals/approve-all" hsJwt
    s!"\{\"items\":[\{\"kind\":\"privilege\",\"id\":\"{rootReqId}\",\"digest\":\"\"}],\"confirm_critical\":true}"
  let (bunkSt, _) ← sendJson "POST" "/api/privilege-access/bunker" hsJwt "{\"level\":2,\"reason\":\"test\"}"
  let (unbunkSt, unbunkBody) ← sendJson "POST" "/api/privilege-access/unbunker" hsJwt ""
  if critNoConfirmSt != 400 || critConfirmSt != 200 || (critConfirmBody.splitOn "\"approved\":1").length < 2 ||
     bunkSt != 200 || unbunkSt != 200 || (unbunkBody.splitOn "\"bunker_state\":0").length < 2 then
    return (← fail s!"approve-all / bunker / unbunker failed: noConf={critNoConfirmSt} conf={critConfirmSt}:{critConfirmBody} bunk={bunkSt} unbunk={unbunkSt}:{unbunkBody}")

  closeManagedComputeStore mStore
  closeCoreStore store
  cleanup
  return 0

set_option maxHeartbeats 1200000 in
private def runRemoteDispatchWakeupAndBtwTests (_baseCfg : CoreConfig) : IO UInt32 := do
  let ts ← IO.monoNanosNow
  let workRoot := s!"/tmp/orb_remote_btw_wakeup_{ts}"
  let dataRoot := s!"{workRoot}/.sandboxed-sh"
  discard <| (IO.FS.removeDirAll workRoot).toBaseIO
  IO.FS.createDirAll (System.FilePath.mk s!"{dataRoot}/missions")

  let .ok (nodeListenFd, nodePort) ← tcpListen "127.0.0.1" 0 32
    | do IO.eprintln "[orb-core-test] FAIL: mock OrbNode listen failed"; return 1

  let stopMockRef ← IO.mkRef false
  let submittedJobsRef ← IO.mkRef (#[] : Array OrbBin.Json.JVal)
  let cancelledJobsRef ← IO.mkRef (#[] : Array String)
  let jobSeqRef ← IO.mkRef (0 : Nat)
  let ndjsonLines :=
    "{\"type\":\"tool_use\",\"sessionID\":\"ses_mock1\",\"part\":{\"id\":\"call_1\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"ls\"}}}}\n" ++
    "{\"type\":\"text\",\"sessionID\":\"ses_mock1\",\"part\":{\"text\":\"Babylon progress is 94%.\"}}\n"
  let ndjsonLen := ndjsonLines.utf8ByteSize

  let mockTask ← IO.asTask (prio := .dedicated) do
    while !(← stopMockRef.get) do
      match ← tcpAcceptPoll nodeListenFd 80 with
      | .error _ => pure ()
      | .ok cfd =>
        match ← readHttpRequestFromFd cfd none 2000 with
        | .error _ => discard <| closeFd cfd
        | .ok req =>
          let authOk := req.headers.any (fun (k, v) =>
            k.toLower == "authorization" && v.trimAscii.toString == "Bearer mock-node-secret-token")
          let (statusLine, respBody) ←
            if !authOk then
              pure ("401 Unauthorized", "{\"error\":\"unauthorized\"}")
            else if req.method == "POST" && req.path == "/jobs" then do
              let jv := (OrbBin.Json.parseBytes req.bodySlice.toByteArray).toOption.getD (.obj #[])
              submittedJobsRef.modify (·.push jv)
              let ltok := (jv.fieldStr? "lease_token").getD ""
              let pl := (jv.field? "payload").getD (.obj #[])
              let mid := (jv.fieldStr? "mission_id").getD ((pl.fieldStr? "mission_id").getD "")
              if ltok.isEmpty then
                pure ("400 Bad Request", "{\"error\":\"missing_lease_token\"}")
              else if mid == "m-btw-fail" then
                pure ("503 Service Unavailable", "{\"error\":\"node_overloaded\"}")
              else do
                let n ← jobSeqRef.modifyGet (fun c => (c + 1, c + 1))
                let jid := s!"job-mock-{n}"
                pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":\"running\"}")
            else if req.method == "GET" && req.path.startsWith "/jobs/" && (req.path.splitOn "/log").length > 1 then do
              let qParts := req.path.splitOn "offset="
              let off := match qParts[1]? with
                | some tail => ((tail.splitOn "&")[0]?.bind String.toNat?).getD 0
                | none => 0
              let chunk := if off ≥ ndjsonLen then "" else ndjsonLines
              let bodyJson := OrbBin.Json.renderCompact (.obj #[
                ("job_id", .str "job-mock"),
                ("offset", .nat off),
                ("next_offset", .nat ndjsonLen),
                ("log_len", .nat ndjsonLen),
                ("data", .str chunk),
                ("state", .str "succeeded")
              ])
              pure ("200 OK", bodyJson)
            else if req.method == "POST" && req.path.startsWith "/jobs/" && req.path.endsWith "/cancel" then do
              let p0 := (req.path.drop 6).toString
              let jid := (p0.splitOn "/cancel")[0]?.getD ""
              cancelledJobsRef.modify (·.push jid)
              pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":\"cancelled\",\"cancel_requested\":true}")
            else if req.method == "GET" && req.path.startsWith "/jobs/" then do
              let jid := ((req.path.drop 6).toString.splitOn "?")[0]?.getD ""
              pure ("200 OK", s!"\{\"job_id\":{jsonEscape jid},\"state\":\"succeeded\",\"exit_code\":0}")
            else
              pure ("404 Not Found", "{\"error\":\"not_found\"}")
          let bBytes := respBody.toUTF8
          let wire :=
            (s!"HTTP/1.1 {statusLine}\r\nContent-Type: application/json\r\n" ++
             s!"Content-Length: {bBytes.size}\r\nConnection: close\r\n\r\n").toUTF8 ++ bBytes
          discard <| writeAll cfd wire false
          discard <| closeFd cfd
    discard <| closeFd nodeListenFd

  OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODES" s!"mocknode=http://127.0.0.1:{nodePort}|SANDBOXED_REMOTE_NODE_MOCKNODE_TOKEN"
  OrbBin.PosixExt.setenvVar "SANDBOXED_REMOTE_NODE_MOCKNODE_TOKEN" "mock-node-secret-token"
  OrbBin.PosixExt.setenvVar "SANDBOXED_PUBLIC_URL" "http://127.0.0.1:13000"

  let stopEnvAndMock : IO Unit := do
    stopMockRef.set true
    let _ := mockTask.get
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODES"
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_REMOTE_NODE_MOCKNODE_TOKEN"
    OrbBin.PosixExt.unsetenvVar "SANDBOXED_PUBLIC_URL"
    discard <| (IO.FS.removeDirAll workRoot).toBaseIO

  let store ← match ← openCoreStore dataRoot 0 "prod" with
    | .ok s => pure s
    | .error e => stopEnvAndMock; IO.eprintln s!"[orb-core-test] FAIL: openCoreStore remote test failed: {e}"; return 1
  let .ok () ← ensureQueueContSchema store
    | do closeCoreStore store; stopEnvAndMock; IO.eprintln "[orb-core-test] FAIL: ensureQueueContSchema remote test failed"; return 1
  let .ok mStore ← openManagedComputeStore s!"{dataRoot}/managed_compute.db"
    | do closeCoreStore store; stopEnvAndMock; IO.eprintln "[orb-core-test] FAIL: openManagedComputeStore remote test failed"; return 1

  let fail (msg : String) : IO UInt32 := do
    closeManagedComputeStore mStore
    closeCoreStore store
    stopEnvAndMock
    IO.eprintln s!"[orb-core-test] FAIL (remote-dispatch-wakeup-btw): {msg}"
    return 1

  let jwtSec := "remote-btw-wakeup-jwt-secret-0123456789abcdef"
  let nowSec : UInt64 := 1794400000
  let hsJwt := issueHs256Jwt jwtSec "prod" "admin" nowSec (nowSec + 86400) "admin"
  let cfg : CoreConfig := {
    host := "127.0.0.1"
    port := 13000
    workingDir := workRoot
    devMode := false
    dashboardPassword := "strong-prod-pass-1234"
    jwtSecret := jwtSec
  }
  let _ ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] (formatEpochIso8601Utc nowSec)
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true, dailyCapCents := 5000, maxConcurrent := 20 } : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (0 : UInt64)
  let bHub ← newBroadcastHub
  let rHub ← newRelayHub 0
  let remSup ← newRemoteJobSupervisor jwtSec false
  remSup.boundPortRef.set 13000
  let appSt : CoreAppState := {
    cfg := cfg
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef
    proxyCooldownsRef := cooldownsRef
    seqRef := seqRef
    managedStore? := some mStore
    broadcastHub? := some bHub
    relayHub? := some rHub
    remoteSup? := some remSup
  }

  let sendJson (method path tok body : String) : IO (Nat × String) := do
    let bBytes := body.toUTF8
    let authLine := if tok.isEmpty then "" else s!"Authorization: Bearer {tok}\r\n"
    let rawWire :=
      (s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authLine}" ++
       s!"Content-Type: application/json\r\nContent-Length: {bBytes.size}\r\n\r\n").toUTF8 ++ bBytes
    match parseRequest rawWire none with
    | .error _ => return (599, "parse_err")
    | .ok req =>
      match ← dispatchCoreRequest appSt req nowSec with
      | .error _ => return (101, "")
      | .ok r => return (r.status, (String.fromUTF8? r.body).getD "")

  -- Seed remote parent mission `m-parent-rem` placed on `mocknode` via `mission_runs.scope_unit = 'remote-node:mocknode'`
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,run_generation,created_at,updated_at) " ++
     "VALUES('m-parent-rem','leanvm faster','active','opencode','','leanvm','managed','[]',1,'2026-11-12T06:00:00Z','2026-11-12T06:05:00Z');") #[]
  let _ ← store.missionsDb.mu.atomically do
    insertMissionRunUnlocked store.missionsDb
      "r-parent-1" "m-parent-rem" "1" "running" "" "" "2026-11-12T06:05:00Z" false "orb-core" "remote-node:mocknode"
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO mission_events(mission_id,seq,sequence,event_type,timestamp,content) VALUES" ++
     "('m-parent-rem',1,1,'user_message','2026-11-12T06:00:01Z','Benchmark leanvm on babylon')," ++
     "('m-parent-rem',2,2,'assistant_message','2026-11-12T06:04:00Z','Wave 3 running on babylon.');") #[]

  -- 1. Live `/btw/agent` inherits `mocknode`, keeps `working_directory=''` + `fork-workspace:m-parent-rem`, launches turn, streams NDJSON
  let (btwSt, btwBody) ← sendJson "POST" "/api/control/missions/m-parent-rem/btw/agent" hsJwt
    "{\"id\":\"m-btw-ok\",\"idempotency_key\":\"btw-idem-ok\",\"side_question\":\"où en est le run ?\",\"side_context_mode\":\"incremental\"}"
  if btwSt != 201 ||
     (btwBody.splitOn "\"status\":\"active\"").length < 2 ||
     (btwBody.splitOn "\"remote_node_id\":\"mocknode\"").length < 2 then
    return (← fail s!"/btw/agent expected 201 active on mocknode, got {btwSt}: {btwBody}")

  let mut btwCompleted := false
  for _ in [0:80] do
    if !btwCompleted then
      if let .ok rs ← execParamQuery store.missionsDb "SELECT status FROM missions WHERE id='m-btw-ok';" #[] then
        if ((rs[1]?.bind (·[0]?)).getD "") == "completed" then
          btwCompleted := true
      if !btwCompleted then
        IO.sleep 30
  if !btwCompleted then
    return (← fail "m-btw-ok did not complete within 2.4s")

  let jobs1 ← submittedJobsRef.get
  let j0 := jobs1[0]?.getD (.obj #[])
  let j0Pl := (j0.field? "payload").getD (.obj #[])
  let j0Cmd := (j0Pl.fieldStr? "command").getD ""
  let j0Env := (j0Pl.field? "env").getD (.obj #[])
  let j0ProxyKey := (j0Env.fieldStr? "SANDBOXED_PROXY_API_KEY").getD ""
  let j0McpTok := (j0Env.fieldStr? "SANDBOXED_MCP_TOKEN").getD ""
  if (j0Pl.fieldBool? "side_question") != some true ||
     (j0Cmd.splitOn "fork_dir=\"$fork_root/m-parent-rem\"").length < 2 ||
     (j0Cmd.splitOn "opencode run --format json").length < 2 ||
     !j0ProxyKey.startsWith "orb-mpt-v1_" ||
     !j0McpTok.startsWith "mcp1." then
    return (← fail s!"m-btw-ok job payload mismatch: cmd={j0Cmd} proxyKey={j0ProxyKey.take 12} mcpTok={j0McpTok.take 8}")

  let btwRowRes ← execParamQuery store.missionsDb
    "SELECT working_directory, session_id, updated_at FROM missions WHERE id='m-btw-ok';" #[]
  let btwWd := match btwRowRes with | .ok rs => (rs[1]?.bind (·[0]?)).getD "x" | .error _ => "x"
  let btwSid := match btwRowRes with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let btwUpd := match btwRowRes with | .ok rs => (rs[1]?.bind (·[2]?)).getD "" | .error _ => ""
  let btwEvRes ← execParamQuery store.missionsDb
    "SELECT event_type, COALESCE(content, payload, '') FROM mission_events WHERE mission_id='m-btw-ok' ORDER BY id ASC;" #[]
  let btwEvStr := match btwEvRes with | .ok rs => rowsToJsonArray rs | .error _ => ""
  if btwWd != "" || btwSid != "ses_mock1" || !btwUpd.endsWith "Z" || (btwUpd.splitOn "T").length < 2 ||
     (btwEvStr.splitOn "tool_result").length < 2 ||
     (btwEvStr.splitOn "Babylon progress is 94%.").length < 2 then
    return (← fail s!"m-btw-ok post-run DB mismatch: wd={btwWd} sid={btwSid} upd={btwUpd} evs={btwEvStr}")

  -- 2. Fail-closed `/btw/agent`: when remote node returns 503, returns HTTP 502 and leaves zero orphan `awaiting_user` rows
  let (failBtwSt, failBtwBody) ← sendJson "POST" "/api/control/missions/m-parent-rem/btw/agent" hsJwt
    "{\"id\":\"m-btw-fail\",\"idempotency_key\":\"btw-idem-fail\",\"side_question\":\"test fail\",\"side_context_mode\":\"clean\"}"
  let orphanRes ← execParamQuery store.missionsDb "SELECT COUNT(*) FROM missions WHERE id='m-btw-fail';" #[]
  let orphanCnt := match orphanRes with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 99 | .error _ => 99
  if failBtwSt != 502 || orphanCnt != 0 then
    return (← fail s!"fail-closed /btw/agent expected 502 and 0 orphans, got st={failBtwSt} cnt={orphanCnt} body={failBtwBody}")

  -- 3. MCP `schedule_wakeup` + `get_action` + `wait_actions` + idempotent replay + executor self-confinement + firing due wakeup
  let _ ← execParamQuery store.missionsDb
    "UPDATE missions SET status='awaiting_user', session_id='ses_parent_prev', updated_at='2026-11-12T06:10:00Z' WHERE id='m-parent-rem';" #[]
  let _ ← execParamQuery store.missionsDb
    "UPDATE mission_runs SET execution_state='terminal', updated_at='2026-11-12T06:10:00Z' WHERE mission_id='m-parent-rem';" #[]
  let (wSessSt, wSessBody) ← sendJson "POST" "/api/mcp/session" hsJwt
    "{\"mission_id\":\"m-parent-rem\",\"role\":\"worker\",\"project\":\"leanvm\"}"
  let wMcpTok := ((OrbBin.Json.parse wSessBody).toOption.getD (.obj #[]) |>.fieldStr? "token").getD ""
  if wSessSt != 200 || !wMcpTok.startsWith "mcp1." then
    return (← fail s!"mint worker MCP session failed: {wSessSt} {wSessBody}")

  let (_, crossWakeBody) ← sendJson "POST" "/api/mcp/call" wMcpTok
    "{\"name\":\"schedule_wakeup\",\"arguments\":{\"mission_id\":\"other-mission\",\"delay_seconds\":60,\"prompt\":\"nope\",\"reason\":\"test\",\"idempotency_key\":\"wk-cross\"}}"
  if (crossWakeBody.splitOn "\"forbidden\"").length < 2 then
    return (← fail s!"worker session should forbid cross-mission schedule_wakeup: {crossWakeBody}")

  let wakeCallPayload :=
    "{\"name\":\"schedule_wakeup\",\"arguments\":{\"delay_seconds\":60,\"prompt\":\"Check wave 4\",\"reason\":\"poll\",\"idempotency_key\":\"wk-idem-1\"}}"
  let (wkSt1, wkBody1) ← sendJson "POST" "/api/mcp/call" wMcpTok wakeCallPayload
  let (wkSt2, wkBody2) ← sendJson "POST" "/api/mcp/call" wMcpTok wakeCallPayload
  let wkRes1 := ((OrbBin.Json.parse wkBody1).toOption.getD (.obj #[]) |>.field? "result").getD (.obj #[])
  let wkRes2 := ((OrbBin.Json.parse wkBody2).toOption.getD (.obj #[]) |>.field? "result").getD (.obj #[])
  let wkActId1 := (wkRes1.fieldStr? "action_id").getD ""
  let wkActId2 := (wkRes2.fieldStr? "action_id").getD ""
  let wkContId1 := (wkRes1.fieldStr? "continuation_id").getD ""
  if wkSt1 != 200 || wkSt2 != 200 || wkActId1.isEmpty || wkContId1.isEmpty || wkActId1 != wkActId2 then
    return (← fail s!"schedule_wakeup / idempotent replay failed: b1={wkBody1} b2={wkBody2}")

  let (gaSt, gaBody) ← sendJson "POST" "/api/mcp/call" wMcpTok
    s!"\{\"name\":\"get_action\",\"arguments\":\{\"action_id\":{jsonEscape wkActId1}}}"
  let (waSt, waBody) ← sendJson "POST" "/api/mcp/call" wMcpTok
    s!"\{\"name\":\"wait_actions\",\"arguments\":\{\"action_ids\":[{jsonEscape wkActId1}]}}"
  if gaSt != 200 || (gaBody.splitOn "\"state\":\"succeeded\"").length < 2 ||
     waSt != 200 || (waBody.splitOn "\"all_succeeded\":true").length < 2 then
    return (← fail s!"get_action / wait_actions failed: ga={gaBody} wa={waBody}")

  let preJobsCnt := (← submittedJobsRef.get).size
  discard <| tickContinuationScheduler store (some mStore) (some rHub) (some bHub) remSup none workRoot none (some (nowSec + 61))
  let postJobs ← submittedJobsRef.get
  if postJobs.size != preJobsCnt + 1 then
    return (← fail s!"tickContinuationScheduler did not dispatch due wakeup job: pre={preJobsCnt} post={postJobs.size}")
  let wkJobCmd := (((postJobs.back?.getD (.obj #[])).field? "payload").getD (.obj #[]) |>.fieldStr? "command").getD ""
  if (wkJobCmd.splitOn "--session 'ses_parent_prev'").length < 2 then
    return (← fail s!"woken remote turn did not resume ses_parent_prev: cmd={wkJobCmd}")
  let mut parentDone := false
  for _ in [0:80] do
    if !parentDone then
      if let .ok rs ← execParamQuery store.missionsDb "SELECT status FROM missions WHERE id='m-parent-rem';" #[] then
        if ((rs[1]?.bind (·[0]?)).getD "") == "completed" then
          parentDone := true
      if !parentDone then
        IO.sleep 30
  if !parentDone then
    return (← fail "woken m-parent-rem did not reach completed")

  -- 4. Legacy `automations` migration + recurring `interval:<secs>` re-arm + parking in `awaiting_user` while armed
  let legPastIso := formatEpochIso8601Utc (nowSec - 600)
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO missions(id,title,status,backend,working_directory,project,placement_kind,tags,session_id,run_generation,created_at,updated_at) " ++
     "VALUES('m-legacy-auto','ldgr','completed','opencode','','ldgr','managed','[\"remote-node:mocknode\"]','ses_ldgr1',2,?1,?1);") #[legPastIso]
  let _ ← execParamQuery store.missionsDb
    ("CREATE TABLE IF NOT EXISTS automations (" ++
     "id TEXT PRIMARY KEY NOT NULL, mission_id TEXT NOT NULL, command_source_type TEXT NOT NULL DEFAULT 'inline', " ++
     "command_source_data TEXT NOT NULL, trigger_type TEXT NOT NULL, trigger_data TEXT NOT NULL, " ++
     "active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, last_triggered_at TEXT, " ++
     "stop_policy TEXT NOT NULL DEFAULT 'never', fresh_session TEXT NOT NULL DEFAULT 'keep', retry_config TEXT NOT NULL DEFAULT '{}');") #[]
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO automations(id,mission_id,command_source_data,trigger_type,trigger_data,active,created_at,last_triggered_at) " ++
     "VALUES('auto-ldgr-1','m-legacy-auto','{\"content\":\"Check Ashur wave\"}','interval','{\"seconds\":120}',1,?1,?1);") #[legPastIso]

  let preLegJobs := (← submittedJobsRef.get).size
  discard <| tickContinuationScheduler store (some mStore) (some rHub) (some bHub) remSup none workRoot none (some (nowSec + 300))
  let postLegJobs := (← submittedJobsRef.get).size
  let autoActiveRes ← execParamQuery store.missionsDb "SELECT active FROM automations WHERE id='auto-ldgr-1';" #[]
  let autoActive := match autoActiveRes with | .ok rs => (rs[1]?.bind (·[0]?)).getD "1" | .error _ => "1"
  let rearmedRes ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-legacy-auto' AND phase=1 AND recurrence='interval:120';" #[]
  let rearmedCnt := match rearmedRes with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 0 | .error _ => 0
  if postLegJobs != preLegJobs + 1 || autoActive != "0" || rearmedCnt != 1 then
    return (← fail s!"legacy automations migration / interval re-arm failed: jobs={preLegJobs}->{postLegJobs} active={autoActive} rearmed={rearmedCnt}")

  let mut legParked := false
  for _ in [0:80] do
    if !legParked then
      if let .ok rs ← execParamQuery store.missionsDb "SELECT status FROM missions WHERE id='m-legacy-auto';" #[] then
        if ((rs[1]?.bind (·[0]?)).getD "") == "awaiting_user" then
          legParked := true
      if !legParked then
        IO.sleep 30
  if !legParked then
    return (← fail "m-legacy-auto with armed recurring interval did not park in awaiting_user after turn completion")
  let legFiredStuckRes ← execParamQuery store.missionsDb
    "SELECT COUNT(*) FROM mission_continuations WHERE mission_id='m-legacy-auto' AND phase IN (2,3);" #[]
  let legFiredStuck := match legFiredStuckRes with | .ok rs => ((rs[1]?.bind (·[0]?)).bind String.toNat?).getD 99 | .error _ => 99
  let (legDetSt, legDetBody) ← sendJson "GET" "/api/control/missions/m-legacy-auto" hsJwt ""
  if legFiredStuck != 0 || legDetSt != 200 ||
     (legDetBody.splitOn "\"state\":\"error\"").length != 1 ||
     (legDetBody.splitOn "\"state\":\"queued\"").length != 1 ||
     (legDetBody.splitOn "\"state\":\"scheduled\"").length != 2 then
    return (← fail s!"recurring wakeup left ghost queued/error continuation on m-legacy-auto: stuck={legFiredStuck} st={legDetSt} body={legDetBody}")

  -- 5. Admin-owned mission (`owner_user_id` set, `role='admin'`, empty `unix_username`) signs `job:submit` lease with `caller_role='admin'`,
  --    and `"model":"smart"` resolves chain `"builtin/smart"` instead of forwarding `"smart"` raw!
  let bootAdm? ← getUserByUsername? store "admin"
  let admUid := (bootAdm?.map (·.id)).getD ""
  if admUid.isEmpty then
    return (← fail "missing bootstrap admin user in runRemoteDispatchWakeupAndBtwTests")
  let _ ← execParamQuery store.missionsDb
    ("INSERT INTO missions(id,title,status,backend,model_override,working_directory,project,placement_kind,owner_user_id,tags,run_generation,created_at,updated_at) " ++
     "VALUES('m-admin-owned','admin remote','failed','opencode','builtin/smart','','leanvm','managed',?1,'[\"remote-node:mocknode\"]',1,?2,?2);")
    #[admUid, legPastIso]
  let (resAdmSt, resAdmBody) ← sendJson "POST" "/api/control/missions/m-admin-owned/resume" hsJwt "{}"
  if resAdmSt != 200 then
    return (← fail s!"resume m-admin-owned failed: {resAdmSt} {resAdmBody}")
  let admJob := (← submittedJobsRef.get).back?.getD (.obj #[])
  let admLeaseTok := (admJob.fieldStr? "lease_token").getD ""
  let admLeaseB64 := (admLeaseTok.splitOn ".").headD ""
  let admLeaseJson :=
    match OrbBin.PosixExt.base64Decode? admLeaseB64 with
    | some bs => (String.fromUTF8? bs).getD ""
    | none => ""
  if (admLeaseJson.splitOn "\"caller_role\":\"admin\"").length < 2 ||
     (admLeaseJson.splitOn s!"\"owner_user_id\":{jsonEscape admUid}").length < 2 then
    return (← fail s!"admin-owned remote lease did not carry caller_role=admin: {admLeaseJson}")

  let _ ← execParamQuery store.missionsDb
    "INSERT OR REPLACE INTO model_routing_chains(id,name,models_json,updated_at) VALUES('builtin/smart','Smart (Default)','[{\"provider_id\":\"antigravity\",\"model_id\":\"gemini-4-argon-low\"}]','t1');" #[]
  OrbBin.PosixExt.setenvVar "CLI_PROXY_API_KEY" "test-cli-proxy-key"
  OrbBin.PosixExt.setenvVar "CLI_PROXY_API_BASE_URL" "http://127.0.0.1:18317"
  let loadedChains ← loadRoutingChainsFromStore store workRoot
  OrbBin.PosixExt.setenvVar "CLI_PROXY_API_KEY" ""
  OrbBin.PosixExt.setenvVar "CLI_PROXY_API_BASE_URL" ""
  appSt.chainsRef.set loadedChains
  let forwardedModelRef ← IO.mkRef ""
  let appWithMockProxy : CoreAppState := {
    appSt with
    proxyMockTransport? := some (fun tgt => do
      forwardedModelRef.set tgt.modelId
      return .ok { status := 200, headers := #[], body :=
        "{\"id\":\"chatcmpl-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":1200,\"completion_tokens\":300,\"prompt_tokens_details\":{\"cached_tokens\":200}}}".toUTF8 })
  }
  let smartBody := "{\"model\":\"smart\",\"messages\":[]}".toUTF8
  let smartReqRaw :=
    (s!"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {hsJwt}\r\n" ++
     s!"Content-Type: application/json\r\nContent-Length: {smartBody.size}\r\n\r\n").toUTF8 ++ smartBody
  match parseRequest smartReqRaw none with
  | .error _ => return (← fail "parse smartReqRaw failed")
  | .ok sReq =>
    match ← dispatchCoreRequest appWithMockProxy sReq nowSec with
    | .error _ => return (← fail "dispatch smartReqRaw returned 101")
    | .ok sResp =>
      let fwdMdl ← forwardedModelRef.get
      if sResp.status != 200 || fwdMdl != "gemini-4-argon-low" then
        return (← fail s!"model='smart' did not resolve builtin/smart target: status={sResp.status} fwd={fwdMdl}")
      let usageRows ← execParamQuery store.missionsDb
        "SELECT input_tokens,output_tokens,cache_read_tokens,cost_cents FROM proxy_usage WHERE model='gemini-4-argon-low' ORDER BY id DESC LIMIT 1;" #[]
      match usageRows with
      | .ok rows =>
        if rows.size < 2 || rows[1]! != #["1000", "300", "200", "1"] then
          return (← fail s!"proxied call did not record its usage: {rows}")
      | .error e => return (← fail s!"proxy_usage query failed: {e}")
  let sseUsage := extractProxyUsage
    ("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":40,\"cache_read_input_tokens\":900,\"cache_creation_input_tokens\":60}}}\n\n" ++
     "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":25}}\n\ndata: [DONE]\n").toUTF8
  if sseUsage != { input := 40, output := 25, cacheCreate := 60, cacheRead := 900 } then
    return (← fail s!"SSE usage was not merged across events: {repr sseUsage}")

  closeManagedComputeStore mStore
  closeCoreStore store
  stopEnvAndMock
  return 0

set_option maxHeartbeats 400000 in
private def runLibraryGitAndSkillParityTests : IO UInt32 := do
  let ts ← IO.monoNanosNow
  let workRoot := s!"/tmp/orb_library_parity_{ts}"
  let dataRoot := s!"{workRoot}/.sandboxed-sh"
  let bareRepo := s!"{workRoot}/remote-library.git"
  let seedRepo := s!"{workRoot}/seed-library"
  let peerRepo := s!"{workRoot}/peer-library"
  discard <| (IO.FS.removeDirAll workRoot).toBaseIO
  IO.FS.createDirAll (System.FilePath.mk s!"{dataRoot}/missions")
  IO.FS.createDirAll (System.FilePath.mk bareRepo)
  IO.FS.createDirAll (System.FilePath.mk s!"{seedRepo}/skill/orb-basics/references")
  IO.FS.createDirAll (System.FilePath.mk s!"{seedRepo}/skill/orb-basics/tools")
  IO.FS.createDirAll (System.FilePath.mk s!"{seedRepo}/skill/proton-mail")

  let shRun (cmd : String) : IO Nat := do
    let env ← OrbBin.PosixExt.environList
    let sp ← OrbBin.PosixExt.spawnPgrp "/bin/sh" #["-c", cmd] env false false true
    if sp.pid < 0 then return 127
    if sp.stdoutFd >= 0 then
      let mut eof := false
      while !eof do
        let chunk ← OrbBin.PosixExt.readFdChunk sp.stdoutFd 4096
        if chunk.isEmpty then eof := true
      OrbBin.PosixExt.closeFdRaw sp.stdoutFd
    let st ← OrbBin.PosixExt.waitpidBlock sp.pid
    return st.toNat

  IO.FS.writeFile (System.FilePath.mk s!"{seedRepo}/skill/orb-basics/SKILL.md")
    "---\nname: orb-basics\ndescription: \"Orient an Orb agent to its environment.\"\nmetadata:\n  sandboxed:\n    audience: [mission, local]\n    scope: global\n---\n\n# Orb Basics\n\nFollow Core contracts.\n"
  IO.FS.writeFile (System.FilePath.mk s!"{seedRepo}/skill/orb-basics/references/guide.md") "# Guide\nRead carefully.\n"
  let hugeMd := "# Huge\n" ++ String.ofList (List.replicate 270000 'a') ++ "\n"
  IO.FS.writeFile (System.FilePath.mk s!"{seedRepo}/skill/orb-basics/references/huge.md") hugeMd
  IO.FS.writeFile (System.FilePath.mk s!"{seedRepo}/skill/orb-basics/tools/helper.py") "#!/usr/bin/env python3\nprint('ok')\n"
  IO.FS.writeFile (System.FilePath.mk s!"{seedRepo}/skill/proton-mail/SKILL.md")
    "---\nname: proton-mail\ndescription: \"Coordinator mail helper.\"\nmetadata:\n  sandboxed:\n    audience: [coordinator]\n    scope: on-demand\n---\n\n# Proton Mail\n"

  let initRc ← shRun
    (s!"git init --bare '{bareRepo}' && " ++
     s!"cd '{seedRepo}' && git init -b main && " ++
     "git config user.name 'Seed' && git config user.email 'seed@example.com' && " ++
     s!"git add -A && git commit -m 'initial library' && git remote add origin '{bareRepo}' && git push -u origin main")
  if initRc != 0 then
    discard <| (IO.FS.removeDirAll workRoot).toBaseIO
    IO.eprintln s!"[orb-core-test] FAIL (library-parity): failed to seed bare git repo (rc={initRc})"
    return 1

  let store ← match ← openCoreStore dataRoot 0 "prod" with
    | .ok s => pure s
    | .error e =>
      discard <| (IO.FS.removeDirAll workRoot).toBaseIO
      IO.eprintln s!"[orb-core-test] FAIL (library-parity): openCoreStore failed: {e}"
      return 1

  let fail (msg : String) : IO UInt32 := do
    closeCoreStore store
    discard <| (IO.FS.removeDirAll workRoot).toBaseIO
    IO.eprintln s!"[orb-core-test] FAIL (library-parity): {msg}"
    return 1

  let jwtSec := "library-parity-jwt-secret-0123456789abcdef"
  let nowSec : UInt64 := 1794500000
  let hsJwt := issueHs256Jwt jwtSec "prod" "admin" nowSec (nowSec + 86400) "admin"
  let cfg : CoreConfig := {
    host := "127.0.0.1"
    port := 13001
    workingDir := workRoot
    devMode := false
    dashboardPassword := "strong-prod-pass-1234"
    jwtSecret := jwtSec
  }
  let _ ← bootstrapUsersAndBackfill store #[("admin", cfg.dashboardPassword)] (formatEpochIso8601Utc nowSec)
  let managedRef ← IO.mkRef ({} : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let cooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (0 : UInt64)
  let appSt : CoreAppState := {
    cfg := cfg
    store := store
    searchIdx? := none
    managedRef := managedRef
    chainsRef := chainsRef
    proxyCooldownsRef := cooldownsRef
    seqRef := seqRef
  }

  let sendReq (method path tok body : String) : IO (Nat × String × String) := do
    let bBytes := body.toUTF8
    let authLine := if tok.isEmpty then "" else s!"Authorization: Bearer {tok}\r\n"
    let rawWire :=
      (s!"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{authLine}" ++
       s!"Content-Type: application/json\r\nContent-Length: {bBytes.size}\r\n\r\n").toUTF8 ++ bBytes
    match parseRequest rawWire none with
    | .error _ => return (599, "", "parse_err")
    | .ok req =>
      match ← dispatchCoreRequest appSt req nowSec with
      | .error _ => return (101, "", "")
      | .ok resp => return (resp.status, resp.contentType, (String.fromUTF8? resp.body).getD "")

  -- 1. Unreachable initial clone fails closed (`502`, never `200 []`), loopback host boundary rejects evil URLs,
  --    existing non-git `library/` directory attaches remote cleanly BEFORE first `commit`, local no-op `push`,
  --    and switching to `bareRepo` via `force_reinitialize: true`
  let missingCloneRepo := s!"{workRoot}/nonexistent-remote.git"
  let (setMissingSt, _, setMissingBody) ← sendReq "PUT" "/api/settings/library-remote" hsJwt
    s!"\{\"library_remote\":{jsonEscape missingCloneRepo}}"
  let (failListSt, _, _) ← sendReq "GET" "/api/library/skill" hsJwt ""
  let (failStatSt, _, _) ← sendReq "GET" "/api/library/status" hsJwt ""
  let (clrRemSt, _, _) ← sendReq "PUT" "/api/settings/library-remote" hsJwt "{\"library_remote\":null}"
  let (evilAtSt, _, _) ← sendReq "PUT" "/api/settings/library-remote" hsJwt "{\"library_remote\":\"http://localhost@evil.com/repo.git\"}"
  let (evilSubSt, _, _) ← sendReq "PUT" "/api/settings/library-remote" hsJwt "{\"library_remote\":\"http://localhost.evil.com/repo.git\"}"
  let (evilIpSt, _, _) ← sendReq "PUT" "/api/settings/library-remote" hsJwt "{\"library_remote\":\"http://127.0.0.1.evil.com/repo.git\"}"
  if setMissingSt != 200 || (setMissingBody.splitOn "\"library_error\"").length < 2 ||
     failListSt != 502 || failStatSt != 502 || clrRemSt != 200 ||
     evilAtSt != 400 || evilSubSt != 400 || evilIpSt != 400 then
    return (← fail s!"fail-closed clone or loopback host-boundary check failed: setMissing=({setMissingSt},{setMissingBody}) failList={failListSt} failStat={failStatSt} evil=({evilAtSt},{evilSubSt},{evilIpSt})")

  let freshBareRepo := s!"{workRoot}/fresh-bare.git"
  IO.FS.createDirAll (System.FilePath.mk freshBareRepo)
  let freshRc ← shRun s!"git init --bare '{freshBareRepo}'"
  if freshRc != 0 then
    return (← fail s!"failed to init freshBareRepo (rc={freshRc})")
  let (putLocalSt, _, _) ← sendReq "PUT" "/api/library/skill/local-first" hsJwt
    "{\"content\":\"---\\nname: local-first\\ndescription: \\\"Local first\\\"\\n---\\n# Local\\n\"}"
  -- Attach `freshBareRepo` while `library/` already exists on disk WITHOUT `.git` (before first `commit`),
  -- then disconnect via `library_remote: null` and verify `origin` is actually removed without manual `git remote remove`!
  let (attachPreGitSt, _, attachPreGitBody) ← sendReq "PUT" "/api/settings/library-remote" hsJwt
    s!"\{\"library_remote\":{jsonEscape freshBareRepo}}"
  let (clrForNoopSt, _, _) ← sendReq "PUT" "/api/settings/library-remote" hsJwt "{\"library_remote\":null}"
  let (discStatSt, _, discStatBody) ← sendReq "GET" "/api/library/status" hsJwt ""
  let (cmtLocalSt, _, _) ← sendReq "POST" "/api/library/commit" hsJwt "{\"message\":\"skill: local-first\"}"
  let (pushNoRemSt, _, pushNoRemBody) ← sendReq "POST" "/api/library/push" hsJwt ""
  let (attachRemSt, _, attachRemBody) ← sendReq "PUT" "/api/settings/library-remote" hsJwt
    s!"\{\"library_remote\":{jsonEscape freshBareRepo}}"
  let (pushFreshSt, _, pushFreshBody) ← sendReq "POST" "/api/library/push" hsJwt ""
  if putLocalSt != 200 ||
     attachPreGitSt != 200 || (attachPreGitBody.splitOn "\"library_reinitialized\":true").length != 2 ||
     (attachPreGitBody.splitOn "\"library_error\"").length != 1 || clrForNoopSt != 200 ||
     discStatSt != 200 || (discStatBody.splitOn "\"remote\":null").length != 2 ||
     cmtLocalSt != 200 ||
     pushNoRemSt != 200 || (pushNoRemBody.splitOn "No remote configured").length != 2 ||
     attachRemSt != 200 || (attachRemBody.splitOn "\"library_reinitialized\":true").length != 2 ||
     (attachRemBody.splitOn "\"library_error\"").length != 1 ||
     pushFreshSt != 200 || (pushFreshBody.splitOn "Pushed successfully").length != 2 then
    return (← fail s!"local-first library -> attach remote -> push failed: put={putLocalSt} preGit=({attachPreGitSt},{attachPreGitBody}) disc=({discStatSt},{discStatBody}) cmt={cmtLocalSt} noRem=({pushNoRemSt},{pushNoRemBody}) attach=({attachRemSt},{attachRemBody}) pushFresh=({pushFreshSt},{pushFreshBody})")

  let (badRemSt, _, _) ← sendReq "PUT" "/api/settings/library-remote" hsJwt "{\"library_remote\":\"--upload-pack=/bin/false\"}"
  let (setRemSt, _, setRemBody) ← sendReq "PUT" "/api/settings/library-remote" hsJwt
    s!"\{\"library_remote\":{jsonEscape bareRepo},\"force_reinitialize\":true}"
  let (hlthSt, _, hlthBody) ← sendReq "GET" "/api/health" "" ""
  let (stCode, _, stBody) ← sendReq "GET" "/api/library/status" hsJwt ""
  if badRemSt != 400 || setRemSt != 200 ||
     (setRemBody.splitOn "\"library_reinitialized\":true").length != 2 ||
     hlthSt != 200 || (hlthBody.splitOn bareRepo).length < 2 ||
     stCode != 200 || (stBody.splitOn "\"clean\":true").length != 2 then
    return (← fail s!"library-remote init/health/status mismatch: bad={badRemSt} set={setRemSt}:{setRemBody} hlth={hlthBody} st={stBody}")

  -- 2. Canonical `skill/` catalog listing (`?include=bundle`), single-skill bundle, oversized `.md` in `references`, raw text reference read, and `SKILL.md` delete guard
  let (listSt, _, listBody) ← sendReq "GET" "/api/library/skill" hsJwt ""
  let (bundleSt, _, bundleBody) ← sendReq "GET" "/api/library/skill?include=bundle" hsJwt ""
  let (oneSt, _, oneBody) ← sendReq "GET" "/api/library/skill/orb-basics" hsJwt ""
  let (refSt, refCtype, refBody) ← sendReq "GET" "/api/library/skill/orb-basics/files/references/guide.md" hsJwt ""
  let (hugeRefSt, _, hugeRefBody) ← sendReq "GET" "/api/library/skill/orb-basics/files/references/huge.md" hsJwt ""
  let (delMdSt, _, _) ← sendReq "DELETE" "/api/library/skill/orb-basics/files/SKILL.md" hsJwt ""
  let (delivSt, _, delivBody) ← sendReq "GET" "/api/library/skill-delivery" hsJwt ""
  -- Unreadable companion directory (`chmod 000`) MUST fail closed (`500`) on bundle reads instead of returning a truncated bundle
  let euid ← OrbBin.PosixExt.geteuid
  if euid != 0 then
    discard <| OrbBin.PosixExt.chmod s!"{dataRoot}/library/skill/orb-basics/references" 0o000
    let (unreadBundleSt, _, _) ← sendReq "GET" "/api/library/skill?include=bundle" hsJwt ""
    let (unreadOneSt, _, _) ← sendReq "GET" "/api/library/skill/orb-basics" hsJwt ""
    discard <| OrbBin.PosixExt.chmod s!"{dataRoot}/library/skill/orb-basics/references" 0o755
    if unreadBundleSt != 500 || unreadOneSt != 500 then
      return (← fail s!"unreadable companion directory did not fail closed: bundle={unreadBundleSt} one={unreadOneSt}")
  -- Companion directory nested deeper than 16 levels MUST also fail closed (`500`) instead of omitting deep companions
  let deepRoot := s!"{dataRoot}/library/skill/orb-basics/deep_test"
  let deepLeaf := s!"{deepRoot}/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/d12/d13/d14/d15/d16/d17"
  IO.FS.createDirAll deepLeaf
  IO.FS.writeFile s!"{deepLeaf}/leaf.txt" "deep"
  let (deepBundleSt, _, _) ← sendReq "GET" "/api/library/skill?include=bundle" hsJwt ""
  let (deepOneSt, _, _) ← sendReq "GET" "/api/library/skill/orb-basics" hsJwt ""
  discard <| IO.Process.output { cmd := "rm", args := #["-rf", deepRoot] }
  if deepBundleSt != 500 || deepOneSt != 500 then
    return (← fail s!"over-nested companion directory did not fail closed: bundle={deepBundleSt} one={deepOneSt}")
  if listSt != 200 ||
     (listBody.splitOn "\"path\":\"skill/orb-basics\"").length != 2 ||
     (listBody.splitOn "\"scope\":\"global\"").length != 2 ||
     bundleSt != 200 ||
     (bundleBody.splitOn "\"references/guide.md\"").length < 2 ||
     (bundleBody.splitOn "\"references/huge.md\"").length < 2 ||
     (bundleBody.splitOn "\"tools/helper.py\"").length < 2 ||
     oneSt != 200 ||
     (oneBody.splitOn "\"references\":[\"references/huge.md\",\"tools/helper.py\"]").length != 2 ||
     refSt != 200 || !(refCtype.startsWith "text/plain") || refBody != "# Guide\nRead carefully.\n" ||
     hugeRefSt != 200 || hugeRefBody.length != hugeMd.length ||
     delMdSt != 400 ||
     delivSt != 200 ||
     (delivBody.splitOn "\"orb-basics\"").length != 2 ||
     (delivBody.splitOn "\"proton-mail\"").length != 1 then
    return (← fail s!"skill catalog/files/delivery mismatch: list={listBody} one={oneBody} ref=({refSt},{refCtype},{refBody}) huge={hugeRefSt} delMd={delMdSt} deliv={delivBody}")

  -- 3. Update skill, commit, push, and inspect git history + revision content
  let updatedContent := "---\nname: orb-basics\ndescription: \"Updated description.\"\nmetadata:\n  sandboxed:\n    audience: [mission, local]\n    scope: global\n---\n\n# Orb Basics v2\n"
  let (putSkSt, _, _) ← sendReq "PUT" "/api/library/skill/orb-basics" hsJwt s!"\{\"content\":{jsonEscape updatedContent}}"
  let (cmtSt, _, cmtBody) ← sendReq "POST" "/api/library/commit" hsJwt "{\"message\":\"skill: update orb-basics\"}"
  let (pushSt, _, pushBody) ← sendReq "POST" "/api/library/push" hsJwt ""
  let (histSt, _, histBody) ← sendReq "GET" "/api/library/skill/orb-basics/history" hsJwt ""
  let histArr := ((OrbBin.Json.parse histBody).toOption >>= OrbBin.Json.JVal.asArr?).getD #[]
  let oldestRev := (histArr.back?.bind (·.fieldStr? "rev")).getD ""
  let (revSt, revCtype, revBody) ← sendReq "GET" s!"/api/library/skill/orb-basics/history/{oldestRev}" hsJwt ""
  if putSkSt != 200 || cmtSt != 200 || pushSt != 200 || histSt != 200 || histArr.size < 2 ||
     revSt != 200 || !(revCtype.startsWith "text/plain") || (revBody.splitOn "Follow Core contracts.").length != 2 then
    return (← fail s!"commit/push/history roundtrip failed: put={putSkSt} cmt={cmtSt}:{cmtBody} push={pushSt}:{pushBody} hist={histBody} rev=({revSt},{revBody})")

  -- 4. Diverged history (`409 DIVERGED_HISTORY`) on `sync`/`push` and recovery via `force-sync`
  let divergeRc ← shRun
    (s!"git clone -b main '{bareRepo}' '{peerRepo}' && cd '{peerRepo}' && " ++
     "git config user.name 'Peer' && git config user.email 'peer@example.com' && " ++
     "printf '\\nPeer remote line.\\n' >> skill/orb-basics/SKILL.md && " ++
     "git commit -am 'peer update' && git push origin main")
  if divergeRc != 0 then
    return (← fail s!"peer clone/push failed (rc={divergeRc})")
  let localDivContent := updatedContent ++ "\nLocal diverged line.\n"
  let _ ← sendReq "PUT" "/api/library/skill/orb-basics" hsJwt s!"\{\"content\":{jsonEscape localDivContent}}"
  let (divCmtSt, _, _) ← sendReq "POST" "/api/library/commit" hsJwt "{\"message\":\"local diverge\"}"
  let (divPushSt, _, divPushBody) ← sendReq "POST" "/api/library/push" hsJwt ""
  let (divSyncSt, _, divSyncBody) ← sendReq "POST" "/api/library/sync" hsJwt ""
  let (fSyncSt, _, _) ← sendReq "POST" "/api/library/force-sync" hsJwt ""
  let (afterSt, _, afterBody) ← sendReq "GET" "/api/library/skill/orb-basics" hsJwt ""
  if divCmtSt != 200 ||
     divPushSt != 409 || (divPushBody.splitOn "DIVERGED_HISTORY").length < 2 ||
     divSyncSt != 409 || (divSyncBody.splitOn "DIVERGED_HISTORY").length < 2 ||
     fSyncSt != 200 || afterSt != 200 || (afterBody.splitOn "Peer remote line.").length < 2 then
    return (← fail s!"diverged history detection/force-sync failed: push=({divPushSt},{divPushBody}) sync=({divSyncSt},{divSyncBody}) fSync={fSyncSt} after={afterBody}")

  -- A transferred Library pin selects that commit, never the moving branch.
  let pinSettings ← readSettingsJson dataRoot
  let .ok () ← writeSettingsJson dataRoot (pinSettings.setField "library_revision" (.str oldestRev))
    | return (← fail "could not set Library revision fixture")
  let (pinSyncSt, _, _) ← sendReq "POST" "/api/library/sync" hsJwt ""
  let (pinReadSt, _, pinReadBody) ← sendReq "GET" "/api/library/skill/orb-basics" hsJwt ""
  if pinSyncSt != 200 || pinReadSt != 200 || (pinReadBody.splitOn "Follow Core contracts.").length != 2 ||
      (pinReadBody.splitOn "Peer remote line.").length != 1 then
    return (← fail "Library synchronization did not honor the transferred revision")
  let libraryDir ← resolveLibraryDir workRoot dataRoot
  IO.FS.writeFile (System.FilePath.mk libraryDir / "keep-local.txt") "local draft"
  let (dirtyPinSt, _, _) ← sendReq "POST" "/api/library/force-sync" hsJwt ""
  if dirtyPinSt != 409 || (← IO.FS.readFile (System.FilePath.mk libraryDir / "keep-local.txt")) != "local draft" then
    return (← fail "Library revision sync must preserve local drafts even on force-sync")

  closeCoreStore store
  discard <| (IO.FS.removeDirAll workRoot).toBaseIO
  return 0

set_option maxHeartbeats 800000 in
set_option maxRecDepth 4000 in
def runSuite (emitLogPath? : Option String) : IO UInt32 := do
  try
    OrbCore.WakeupRestartTests.run
    OrbCore.TurnOutcomeTests.run
  catch e =>
    IO.eprintln s!"[orb-core-test] FAIL: {e}"
    return 1
  -- Wire compatibility regressions run before the broader integration suite.
  try
    OrbCore.ProviderContractTests.run
    OrbCore.ProxyRoutingTests.run
  catch e =>
    IO.eprintln s!"[orb-core-test] FAIL: {e}"
    return 1
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

  -- Provider contracts use a mock transport: no live machines or provider credentials.
  try
    OrbCore.ManagedProviderTests.run
    OrbCore.ManagedProviderLeanciTests.run
    OrbCore.ManagedProviderColabTests.run
  catch e =>
    IO.eprintln s!"[orb-core-test] FAIL: {e}"
    return 1

  -- 2. Service-scoped VM prefix & deploy unit confinement (including path traversal rejection)
  if sandboxNamePrefixFor "/usr/local/bin/orb-core" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/orb-core-prod" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/orb-core-dev" != "orb-managed-dev-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh-prod" != "orb-managed-" ||
     sandboxNamePrefixFor "/usr/local/bin/sandboxed-sh-dev" != "orb-managed-dev-" ||
     !exceptStrEq (validateDeployServiceUnit "orb-core") (.ok "sandboxed-sh.service") ||
     !exceptStrEq (validateDeployServiceUnit "orb-core-prod") (.ok "sandboxed-sh-prod.service") ||
     !exceptStrEq (validateDeployServiceUnit "orb-core-dev") (.ok "sandboxed-sh-dev.service") ||
     !exceptStrEq (validateDeployServiceUnit "sandboxed-sh-prod") (.ok "sandboxed-sh-prod.service") ||
     !exceptStrEq (validateDeployServiceUnit "sandboxed-sh-dev") (.ok "sandboxed-sh-dev.service") ||
     deployUnitIsProd "sandboxed-sh-prod.service" != true ||
     deployUnitIsProd "sandboxed-sh-dev.service" != false ||
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
  try
    OrbCore.ManagedProvisioningTests.run tmpRoot
    OrbCore.ManagedResumeTests.run tmpRoot
    OrbCore.DevOperatorTests.run tmpRoot
    OrbCore.ManagedAccessTests.run tmpRoot
    OrbCore.ManagedTtlTests.run tmpRoot
    OrbCore.ManagedHarvestTests.run tmpRoot
    OrbCore.AutoPlacementTests.run tmpRoot
    OrbCore.ManagedReuseTests.run tmpRoot
    OrbCore.ManagedSnapshotLifecycleTests.run tmpRoot
    OrbCore.NodeLivenessTests.run tmpRoot
    OrbCore.ComputeRollupTests.run tmpRoot
    OrbCore.ManagedSnapshotCatalogTests.run tmpRoot
    OrbCore.ManagedProviderSealingTests.run tmpRoot
    OrbCore.ManagedProviderAvailabilityTests.run tmpRoot
    OrbCore.ManagedSpawnActionsTests.run store
  catch e =>
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: {e}"
    return 1
  let m1 : MissionRecord := {
    id := "m-alpha", title := "Verify Lean 4 Core", status := "awaiting_user",
    backend := "codex", modelOverride := "", modelEffort := "high", workingDirectory := tmpRoot,
    updatedAt := "2026-11-06T00:00:00Z", totalCostCents := 42
  }
  let .ok () ← upsertMission store m1 | do closeCoreStore store; return 1
  let .ok missionsJson ← listMissionsJson store | do closeCoreStore store; return 1
  if (missionsJson.splitOn "\"total_cost_cents\":42").length != 2 ||
     (missionsJson.splitOn "\"model_effort\":\"high\"").length != 2 ||
     (missionsJson.splitOn "\"live_children_count\":0").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: listMissionsJson mismatch: {missionsJson}"
    return 1
  -- Child evidence must survive list filtering/pagination and agree with detail.
  let childStatuses := #["active", "running", "starting", "resuming", "working", "in_progress",
    "processing", "streaming", "pending", "queued", "waiting_background", "awaiting_user",
    "interrupted", "completed", "failed", "cancelled", "archived"]
  for idx in [0:childStatuses.size] do
    let .ok () ← upsertMission store { m1 with
        id := s!"count-child-{idx}", status := childStatuses[idx]!, parentMissionId := "m-alpha",
        updatedAt := "2020-01-01T00:00:00Z" }
      | do closeCoreStore store; return 1
  let .ok () ← upsertMission store { m1 with
      id := "count-grandchild", status := "active", parentMissionId := "count-child-0",
      updatedAt := "2020-01-01T00:00:00Z" }
    | do closeCoreStore store; return 1
  let .ok _ ← execParamQuery store.missionsDb
      ("INSERT INTO mission_continuations(id,mission_id,run_generation,phase,request_id) VALUES " ++
       "('count-armed','count-child-11',1,1,'first'),('count-armed-again','count-child-11',1,1,'second')," ++
       "('count-cancelled','count-child-12',1,4,'cancelled');") #[]
    | do closeCoreStore store; return 1
  let .ok childCountList ← listMissionsJson store none none { status? := some "awaiting_user", limit? := some 1 }
    | do closeCoreStore store; return 1
  let .ok (some childCountDetail) ← missionDetailJson store "m-alpha"
    | do closeCoreStore store; return 1
  let .ok childCountListJ := OrbBin.Json.parse childCountList
    | do closeCoreStore store; return 1
  let .ok childCountDetailJ := OrbBin.Json.parse childCountDetail
    | do closeCoreStore store; return 1
  let countListOk := match childCountListJ with
    | .arr rows => rows.size == 1 && rows[0]!.fieldStr? "id" == some "m-alpha" &&
        rows[0]!.fieldNat? "live_children_count" == some 12
    | _ => false
  if !countListOk || childCountDetailJ.fieldNat? "live_children_count" != some 12 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: authoritative live_children_count list/detail mismatch"
    return 1
  let .ok _ ← execParamQuery store.missionsDb
      "DELETE FROM mission_continuations WHERE id LIKE 'count-%';" #[]
    | do closeCoreStore store; return 1
  let .ok _ ← execParamQuery store.missionsDb
      "DELETE FROM missions WHERE id LIKE 'count-%';" #[]
    | do closeCoreStore store; return 1
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

  -- 5b. Cooldown planning, retry-after cap, usage-limit parity
  let nowSec0 : UInt64 := 1700001000
  let cooling : Array AccountCooldown := #[
    { accountId := "acct-1", untilEpoch := nowSec0 + 7200, reason := .rateLimit, label := "" }
  ]
  let plan := planChain chain cooling nowSec0
  if plan.eligible.size != 1 || plan.eligible[0]!.accountId != "acct-2" ||
     (plan.retryAfterSecs? nowSec0).getD 0 != 3600 then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: cooldown chain plan or retry-after cap mismatch"
    return 1
  let coolReply := cooldownReply "c1" 7200
  if coolReply.status != 429 ||
     !coolReply.headers.any (fun (k, v) => k.toLower == "retry-after" && v == "3600") then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: cooldown reply retry-after cap mismatch"
    return 1
  let usageLimit : AccountCooldown := {
    accountId := "acct-1", untilEpoch := nowSec0 + 2700, reason := .usageLimit, label := "GLM usage limit"
  }
  let usageReply := usageLimitReply "c1" usageLimit nowSec0
  if usageReply.status != 429 ||
     !usageReply.headers.any (fun (k, v) => k.toLower == "retry-after" && v == "2700") ||
     !containsSubstring usageReply.body "\"code\":\"usage_limit_reached\"" ||
     !containsSubstring usageReply.body "\"resets_in_seconds\":2700" then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: usage-limit reply parity mismatch"
    return 1
  let limitOut : ProxyOutcome := {
    status := 429, headers := #[("retry-after", "1800")], body := "usage limit reached".toUTF8,
    selectedAccount := "acct-1", attemptsUsed := 1
  }
  let limitOk :=
    match cooldownForOutcome limitOut nowSec0 with
    | some c => c.reason == .usageLimit && c.untilEpoch == nowSec0 + 1800
    | none => false
  if !limitOk then
    closeCoreStore store
    IO.eprintln "[orb-core-test] FAIL: cooldown classification from upstream mismatch"
    return 1

  -- 6. HTTP/WS Dispatch checks (`/api/health`, `SANDBOXED_USERS` login, `/v1/*` auth, privilege lease verification, WS subprotocol echo)
  let managedRef ← IO.mkRef ({ enabled := true, boatEnabled := true } : ManagedFleetState)
  let chainsRef ← IO.mkRef (#[] : Array RoutingChain)
  let proxyCooldownsRef ← IO.mkRef (#[] : Array AccountCooldown)
  let seqRef ← IO.mkRef (1 : UInt64)
  let liveHealthTracker ← newProviderHealthTracker 1 2
  let authRootMain := s!"{tmpRoot}/auth"
  IO.FS.createDirAll authRootMain
  let authRotMain ← OrbCore.AuthSidecar.newAuthRotationHandle s!"{authRootMain}/oauth_credentials.json"
  let cliSessRefMain ← IO.mkRef (#[] : Array OrbCore.AuthSidecar.CliProxyLoginSession)
  let memTokenCache ← newMemoryTokenCache
  let cloudWakeup ← newCloudWorkerWakeup
  let bunkerRef ← IO.mkRef (0 : UInt8)
  let appSt : CoreAppState := {
    cfg := prodValid, store := store, searchIdx? := some sIdx1,
    managedRef := managedRef, chainsRef := chainsRef,
    proxyCooldownsRef := proxyCooldownsRef, seqRef := seqRef,
    pacingTracker? := some liveHealthTracker.pacing,
    healthTracker? := some liveHealthTracker,
    authRoot := authRootMain,
    authRotation? := some authRotMain,
    cliProxySessionsRef? := some cliSessRefMain,
    memTokenCache? := some memTokenCache,
    cloudWakeup? := some cloudWakeup,
    bunkerStateRef? := some bunkerRef
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

  -- `/btw` side questions bypass `parallel_missions_cap` AND never consume project cap slots!
  let btwAgentBody := "{\"id\":\"m-btw-cap-1\",\"backend\":\"opencode\",\"model_override\":\"builtin/smart\",\"idempotency_key\":\"idem-btw-cap-1\",\"side_question\":\"How far are we?\",\"side_context_mode\":\"incremental\"}"
  let btwAgentRaw := s!"POST /api/control/missions/m-exp-lease/btw/agent HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {btwAgentBody.utf8ByteSize}\r\n\r\n{btwAgentBody}".toUTF8
  let .ok btwAgentReq := parseRequest btwAgentRaw none | do closeCoreStore store; return 1
  let .ok btwAgentResp ← dispatchCoreRequest appSt btwAgentReq nowSec | do closeCoreStore store; return 1
  let btwAgentStr := String.fromUTF8! btwAgentResp.body
  if btwAgentResp.status != 201 ||
     (btwAgentStr.splitOn "\"btw-parent:m-exp-lease\"").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: /btw/agent blocked by parallel_missions_cap ({btwAgentResp.status}): {btwAgentStr}"
    return 1

  let btwDirectBody := "{\"id\":\"m-btw-cap-2\",\"title\":\"Side 2\",\"backend\":\"opencode\",\"project_slug\":\"proj-cap\",\"tags\":[\"btw-parent:m-exp-lease\"]}"
  let btwDirectRaw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {btwDirectBody.utf8ByteSize}\r\n\r\n{btwDirectBody}".toUTF8
  let .ok btwDirectReq := parseRequest btwDirectRaw none | do closeCoreStore store; return 1
  let .ok btwDirectResp ← dispatchCoreRequest appSt btwDirectReq nowSec | do closeCoreStore store; return 1
  if btwDirectResp.status != 201 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: tagged /btw mission blocked by parallel_missions_cap ({btwDirectResp.status}): {String.fromUTF8! btwDirectResp.body}"
    return 1

  -- Raise `proj-cap` to 2: `m-exp-lease` holds 1 slot while `m-btw-cap-1` + `m-btw-cap-2` hold 0 slots,
  -- so a 2nd regular mission `m-cap-reg-2` succeeds (201) and a 3rd `m-cap-reg-3` hits 429 (`active:2`)!
  let _ ← execParamQuery store.projectsDb upsertProjectGrantSql
    #["proj-cap", "owner", "1h", "2", "", "", "high", "propose", "2026-11-06T00:01:00Z"]
  let reg2Body := "{\"id\":\"m-cap-reg-2\",\"title\":\"Second Regular\",\"backend\":\"codex\",\"project_slug\":\"proj-cap\"}"
  let reg2Raw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {reg2Body.utf8ByteSize}\r\n\r\n{reg2Body}".toUTF8
  let .ok reg2Req := parseRequest reg2Raw none | do closeCoreStore store; return 1
  let .ok reg2Resp ← dispatchCoreRequest appSt reg2Req nowSec | do closeCoreStore store; return 1
  if reg2Resp.status != 201 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: idle /btw missions consumed project cap slots ({reg2Resp.status}): {String.fromUTF8! reg2Resp.body}"
    return 1
  let reg3Body := "{\"id\":\"m-cap-reg-3\",\"title\":\"Third Regular\",\"backend\":\"codex\",\"project_slug\":\"proj-cap\"}"
  let reg3Raw := s!"POST /api/control/missions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {validJwt}\r\nContent-Length: {reg3Body.utf8ByteSize}\r\n\r\n{reg3Body}".toUTF8
  let .ok reg3Req := parseRequest reg3Raw none | do closeCoreStore store; return 1
  let .ok reg3Resp ← dispatchCoreRequest appSt reg3Req nowSec | do closeCoreStore store; return 1
  let reg3Str := String.fromUTF8! reg3Resp.body
  if reg3Resp.status != 429 || (reg3Str.splitOn "\"active\":2").length != 2 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: expected 429 active:2 on 3rd regular mission ({reg3Resp.status}): {reg3Str}"
    return 1
  -- Clean up `/btw` cap test rows so subsequent `listMissionsJson` fixture counts stay unchanged.
  let _ ← execParamQuery store.missionsDb "DELETE FROM missions WHERE id IN ('m-btw-cap-1','m-btw-cap-2','m-cap-reg-2');" #[]
  let _ ← execParamQuery store.projectsDb upsertProjectGrantSql
    #["proj-cap", "owner", "1h", "1", "", "", "high", "propose", "2026-11-06T00:01:00Z"]

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

  if (← runCustomProviderRateLimitTests store appSt validJwt nowSec) != 0 then return 1
  if (← runFastMemoryBrokerTests store appSt validJwt nowSec) != 0 then return 1
  if (← runCloudHandoffTests tmpRoot store appSt validJwt nowSec) != 0 then return 1
  if (← runCyberAndSkillDeliveryTests tmpRoot store appSt validJwt nowSec) != 0 then return 1
  if (← runR4cHarnessSessionTests store tmpRoot) != 0 then
    closeCoreStore store
    return 1
  if (← runR3cdQueueAndContinuationTests store appSt validJwt nowSec) != 0 then return 1
  if (← runR3cdRound3BlockerTests store appSt validJwt nowSec) != 0 then return 1
  if (← runR3cdReviewFixTests store appSt validJwt nowSec) != 0 then return 1
  if (← runPostCrashAndReconcileExtras store tmpRoot) != 0 then return 1
  IO.FS.removeDirAll tmpRoot

  -- 7. Host evidence suite (`85/85` host tests) + R3-A / R4-A / R5-A composition gates
  if (← runLifecycleCompositionTests) != 0 then return 1
  if (← runHarnessCloudCompositionTests) != 0 then return 1
  if (← runManagedNodeCompositionTests) != 0 then return 1
  if (← do
    let base := OrbCore.RunCoordinator.fresh "m-r3b" 7
    let .ok supMarked := OrbCore.RunCoordinator.markSuperseded base 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator markSuperseded failed"; return 1
    if (OrbCore.RunCoordinator.startRun supMarked 7 1).isOk ||
       (OrbCore.RunCoordinator.startRun base 6 1).isOk then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator admitted superseded or stale owner"
      return 1
    let .ok claimed := OrbCore.RunCoordinator.startRun base 7 1
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator failed initial claim"; return 1
    if claimed.missionPhase != 1 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator claim did not step mission to active"
      return 1
    let .ok running := OrbCore.RunCoordinator.confirmSpawned claimed 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator failed spawn confirm"; return 1
    let busy := OrbCore.RunCoordinator.pushReceipt
      (OrbCore.RunCoordinator.noteToolCall running "call-live" "bash")
      { toolName := "finish", ok := false, messageId := "msg-sup", missionId := "m-r3b" }
    let .ok supBusy := OrbCore.RunCoordinator.markSuperseded busy 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator supersede during tools failed"; return 1
    if supBusy.ownerSuperseded == 0 ||
       OrbCore.RunCoordinator.liveToolCount supBusy.activeToolCalls != 1 ||
       supBusy.pendingReceipts.size != 1 ||
       supBusy.crashTombstones != 0 || supBusy.runPhase != 2 ||
       (OrbCore.RunCoordinator.enterToolDrain supBusy 7).isOk ||
       (OrbCore.RunCoordinator.reconcileMissingToolResult supBusy 7).isOk ||
       (OrbCore.RunCoordinator.failTurn supBusy 7).isOk then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator supersede wiped or kept admitting in-flight calls"
      return 1
    if (OrbCore.RunCoordinator.completeTurn running 7).isOk then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator completed without structured receipt"
      return 1
    let badId := OrbCore.RunCoordinator.pushReceipt running
      { toolName := "finish", ok := true, messageId := "m-r3b", missionId := "m-r3b" }
    if badId.pendingReceipts.size != 0 || (OrbCore.RunCoordinator.completeTurn badId 7).isOk then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator accepted messageId == missionId"
      return 1
    let notOk := OrbCore.RunCoordinator.pushReceipt running
      { toolName := "finish", ok := false, messageId := "msg-fail", missionId := "m-r3b" }
    if (OrbCore.RunCoordinator.completeTurn notOk 7).isOk then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator completeTurn accepted ok = false"
      return 1
    let .ok (failedRec, failRecPoll) := OrbCore.RunCoordinator.failTurn notOk 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator failTurn on ok = false receipt failed"; return 1
    if failedRec.runPhase != 5 || failedRec.missionPhase != 6 ||
       failRecPoll.ok || failRecPoll.messageId != "msg-fail" || failRecPoll.messageId == failedRec.missionId then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator ok = false receipt did not surface on failTurn"
      return 1
    let busyNoRec := OrbCore.RunCoordinator.noteToolCall running "call-live-2" "bash"
    let .ok (failedSt, failPoll) := OrbCore.RunCoordinator.failTurn busyNoRec 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator failTurn with live tools failed"; return 1
    if failedSt.runPhase != 5 || failedSt.missionPhase != 6 ||
       OrbCore.RunCoordinator.liveToolCount failedSt.activeToolCalls != 0 ||
       failedSt.activeToolCalls.size != 1 || failedSt.crashTombstones != 1 ||
       failPoll.messageId != "" || failPoll.messageId == "m-r3b" then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator failTurn without receipt dropped live tools or leaked missionId"
      return 1
    let .ok (abortedSt, abortPoll) := OrbCore.RunCoordinator.abortTurn busyNoRec 7 true
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator abortTurn with live tools failed"; return 1
    if abortedSt.runPhase != 6 || abortedSt.missionPhase != 7 ||
       OrbCore.RunCoordinator.liveToolCount abortedSt.activeToolCalls != 0 ||
       abortedSt.activeToolCalls.size != 1 || abortedSt.crashTombstones != 1 ||
       abortPoll.messageId != "" || abortPoll.messageId == abortedSt.missionId then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator abortTurn dropped live tools without a tombstone"
      return 1
    let twoCalls := OrbCore.RunCoordinator.noteToolCall
      (OrbCore.RunCoordinator.noteToolCall running "call-1" "bash") "call-2" "read"
    let .ok draining := OrbCore.RunCoordinator.enterToolDrain twoCalls 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator failed enterToolDrain"; return 1
    let cleared := (OrbCore.RunCoordinator.finishToolCall draining "call-1") |>
      (OrbCore.RunCoordinator.finishToolCall · "call-2")
    let .ok drained := OrbCore.RunCoordinator.finishDrainedTools cleared 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator normal drain did not exit"; return 1
    if drained.runPhase != 2 || drained.crashTombstones != 0 ||
       OrbCore.RunCoordinator.liveToolCount drained.activeToolCalls != 0 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator normal drain recorded a crash tombstone"
      return 1
    let .ok recRun := OrbCore.RunCoordinator.reconcileMissingToolResult twoCalls 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator reconcile from running failed"; return 1
    let .ok recDrain := OrbCore.RunCoordinator.reconcileMissingToolResult draining 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator reconcile from drainingTools failed"; return 1
    let .ok recAgain := OrbCore.RunCoordinator.reconcileMissingToolResult recDrain 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator second reconcile failed"; return 1
    let proj := OrbCore.RunCoordinator.projectControl recAgain
    if recRun.runPhase != 2 || recDrain.runPhase != 2 || recRun != recDrain || recDrain != recAgain ||
       proj.activeToolCalls != 0 || proj.crashTombstones != 2 || recDrain.activeToolCalls.size != 2 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator missing ToolResult reconcile not zero/idempotent"
      return 1
    let withRec := OrbCore.RunCoordinator.pushReceipt recDrain
      { toolName := "finish", ok := true, messageId := "msg-42", missionId := "m-r3b" }
    let .ok (done, poll) := OrbCore.RunCoordinator.completeTurn withRec 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator completeTurn with receipt failed"; return 1
    if !poll.completed || !poll.ok || poll.messageId != "msg-42" || poll.messageId == done.missionId ||
       done.runPhase != 4 || done.missionPhase != 5 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator completion poll mismatch"
      return 1
    if (OrbCore.RunCoordinator.claimNextGeneration done 7 1).isOk ||
       (OrbCore.RunCoordinator.claimNextGeneration done 7 2).isOk ||
       (OrbCore.RunCoordinator.confirmSpawned done 7).isOk ||
       done.missionPhase != 5 || done.runPhase != 4 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator reopened completed terminal mission"
      return 1
    let .ok (parkedDone, parkedPoll) := OrbCore.RunCoordinator.completeTurn withRec 7 (parkMission := true)
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator completeTurn (parkMission := true) failed"; return 1
    if !parkedPoll.completed || parkedDone.runPhase != 4 || parkedDone.missionPhase != 0 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator parked turn state mismatch"
      return 1
    if (OrbCore.RunCoordinator.claimNextGeneration parkedDone 7 1).isOk ||
       (OrbCore.RunCoordinator.confirmSpawned parkedDone 7).isOk then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator re-entered running without incremented generation"
      return 1
    let .ok nextClaim := OrbCore.RunCoordinator.claimNextGeneration parkedDone 7 2
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator rejected generation + 1 on parked mission"; return 1
    let .ok nextRun := OrbCore.RunCoordinator.confirmSpawned nextClaim 7
      | do IO.eprintln "[orb-core-test] FAIL: RunCoordinator rejected confirm on generation + 1"; return 1
    if nextRun.runPhase != 2 || nextRun.runGeneration != 2 || nextRun.missionPhase != 1 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator generation + 1 state mismatch"
      return 1
    let abortClaimRes := OrbCore.RunCoordinator.claimNextGeneration abortedSt 7 2
    let failClaimRes := OrbCore.RunCoordinator.claimNextGeneration failedSt 7 2
    if abortClaimRes.isOk || failClaimRes.isOk || abortedSt.missionPhase != 7 || abortedSt.runPhase != 6 ||
       failedSt.missionPhase != 6 || failedSt.runPhase != 5 then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator reopened cancelled or failed terminal mission"
      return 1
    let isOutOfDomain {α : Type} : Except String α → Bool
      | .error "phase_out_of_domain" => true
      | _ => false
    let corruptMission := { base with missionPhase := 99 }
    let corruptRun := { running with runPhase := 99 }
    if !isOutOfDomain (OrbCore.RunCoordinator.startRun corruptMission 7 1) ||
       !isOutOfDomain (OrbCore.RunCoordinator.markSuperseded corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.confirmSpawned corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.enterToolDrain corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.finishDrainedTools corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.reconcileMissingToolResult corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.completeTurn corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.failTurn corruptMission 7) ||
       !isOutOfDomain (OrbCore.RunCoordinator.abortTurn corruptMission 7 true) ||
       !isOutOfDomain (OrbCore.RunCoordinator.claimNextGeneration corruptMission 7 1) ||
       !isOutOfDomain (OrbCore.RunCoordinator.startRun corruptRun 7 2) ||
       !isOutOfDomain (OrbCore.RunCoordinator.markSuperseded corruptRun 7) ||
       OrbCore.RunCoordinator.noteToolCall corruptMission "c-bad" "bash" != corruptMission ||
       OrbCore.RunCoordinator.finishToolCall corruptMission "c-bad" != corruptMission ||
       OrbCore.RunCoordinator.pushReceipt corruptMission
         { toolName := "finish", ok := true, messageId := "msg-bad", missionId := "m-r3b" } != corruptMission ||
       OrbCore.RunCoordinator.noteToolCall corruptRun "c-bad" "bash" != corruptRun ||
       OrbCore.RunCoordinator.finishToolCall corruptRun "c-bad" != corruptRun ||
       OrbCore.RunCoordinator.pushReceipt corruptRun
         { toolName := "finish", ok := true, messageId := "msg-bad", missionId := "m-r3b" } != corruptRun then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator accepted out-of-domain phase code"
      return 1
    let supAfterNote := OrbCore.RunCoordinator.noteToolCall supBusy "call-after-sup" "bash"
    let supAfterFinish := OrbCore.RunCoordinator.finishToolCall supBusy "call-live"
    let supAfterReceipt := OrbCore.RunCoordinator.pushReceipt supBusy
      { toolName := "finish", ok := true, messageId := "msg-after-sup", missionId := "m-r3b" }
    let termAfterNote := OrbCore.RunCoordinator.noteToolCall done "call-after-done" "bash"
    let termAfterReceipt := OrbCore.RunCoordinator.pushReceipt done
      { toolName := "finish", ok := true, messageId := "msg-after-done", missionId := "m-r3b" }
    if supAfterNote.activeToolCalls != supBusy.activeToolCalls ||
       supAfterFinish.activeToolCalls != supBusy.activeToolCalls ||
       supAfterReceipt.pendingReceipts != supBusy.pendingReceipts ||
       termAfterNote.activeToolCalls != done.activeToolCalls ||
       termAfterReceipt.pendingReceipts != done.pendingReceipts then
      IO.eprintln "[orb-core-test] FAIL: RunCoordinator mutated activeToolCalls or pendingReceipts while superseded or terminal"
      return 1
    pure (0 : UInt32)) != 0 then return 1
  if (← do
    -- R4-B (`SM-14`): Grok prose-invariance, Hermes split cursor + approval + SSE replay,
    -- Cursor Cloud follow-up `SubmissionUncertain` reconciliation, cancel-receipt fence, and SQLite CAS.
    let grok0 := freshCloudTurn "m-grok" 0 .grok
    let (grokSub, grokSubEffs) := beginSubmit grok0 1 1000 1000
    let (grokRej, _) := rejectPreCommit grokSub .reconnectRequired 1010
    let (grokSub2, _) := beginSubmit grokRej 2 1020 1020
    let (grokRun, _) := confirmAccepted grokSub2 9001 0 1030
    let (grokCancReq, _) := requestCancel grokRun 1040
    let proseSamples : Array String := #[
      "", "reconnect_required", "Cancellation sent...", " localized: connexion requise / annulation envoyée "
    ]
    let evSamples : Array Orb.HarnessCloud.CloudTurnSliceEvent := #[
      { opCode := 0, hasTerminationReceipt := 0, hasCompletionReceipt := 0, operatorConfirmedNotDelivered := 0,
        approvalResolved := 0, proposedAttemptId := 3, reqProviderTurnId := 0, reqEventCursor := 0,
        reqApprovalReqId := 0, reqSubmittedAtMs := 2000, nowMs := 2000 },
      { opCode := 1, hasTerminationReceipt := 0, hasCompletionReceipt := 0, operatorConfirmedNotDelivered := 0,
        approvalResolved := 0, proposedAttemptId := 2, reqProviderTurnId := 9002, reqEventCursor := 4,
        reqApprovalReqId := 0, reqSubmittedAtMs := 0, nowMs := 2010 },
      { opCode := 8, hasTerminationReceipt := 0, hasCompletionReceipt := 0, operatorConfirmedNotDelivered := 0,
        approvalResolved := 0, proposedAttemptId := 2, reqProviderTurnId := 0, reqEventCursor := 0,
        reqApprovalReqId := 0, reqSubmittedAtMs := 0, nowMs := 2020 },
      { opCode := 9, hasTerminationReceipt := 0, hasCompletionReceipt := 0, operatorConfirmedNotDelivered := 0,
        approvalResolved := 0, proposedAttemptId := 2, reqProviderTurnId := 0, reqEventCursor := 0,
        reqApprovalReqId := 0, reqSubmittedAtMs := 0, nowMs := 2030 },
      { opCode := 9, hasTerminationReceipt := 1, hasCompletionReceipt := 0, operatorConfirmedNotDelivered := 0,
        approvalResolved := 0, proposedAttemptId := 2, reqProviderTurnId := 0, reqEventCursor := 0,
        reqApprovalReqId := 0, reqSubmittedAtMs := 0, nowMs := 2040 }
    ]
    for stSample in #[grok0, grokSub, grokRej, grokRun, grokCancReq] do
      for evSample in evSamples do
        for prose in proseSamples do
          if !detailIsInert stSample evSample prose then
            IO.eprintln "[orb-core-test] FAIL: Grok CloudTurnState transition branched on detail prose"
            return 1
    if grokSubEffs.isEmpty || grokRej.errorKind != .reconnectRequired || grokRej.phase != .queued ||
       grokRun.errorKind != .none || grokCancReq.cancel != .requested || grokCancReq.phase != .cancelRequested then
      IO.eprintln "[orb-core-test] FAIL: Grok typed SubmissionErrorKind / CancelState transition mismatch"
      return 1
    -- CancelRequested refuses Terminal without termination receipt (`hasTerminationReceipt == 0`), admits with `1`, and Terminal is sticky
    let (noReceiptSt, noReceiptEffs) := stepCloudTurn grokCancReq {
      opCode := 9, hasTerminationReceipt := 0, hasCompletionReceipt := 0, operatorConfirmedNotDelivered := 0,
      approvalResolved := 0, proposedAttemptId := 2, reqProviderTurnId := 0, reqEventCursor := 0,
      reqApprovalReqId := 0, reqSubmittedAtMs := 0, nowMs := 1050
    }
    if noReceiptEffs != [] || noReceiptSt != grokCancReq || noReceiptSt.phase != .cancelRequested then
      IO.eprintln "[orb-core-test] FAIL: CancelRequested entered Terminal without termination receipt"
      return 1
    let (grokTerm, grokTermEffs) := finalizeCancelReceipt grokCancReq 1060
    let (afterTerm, afterTermEffs) := beginSubmit grokTerm 3 1070 1070
    if grokTerm.phase != .terminal || grokTerm.cancel != .confirmedReceipt || grokTermEffs.isEmpty ||
       afterTerm != grokTerm || !afterTermEffs.isEmpty then
      IO.eprintln "[orb-core-test] FAIL: CloudTurnState cancel receipt finalization or terminal sticky fence broken"
      return 1

    -- Hermes: split `(submittedAtMs?, eventCursor?)`, typed `WaitingApproval`, and duplicate/reordered/dropped SSE replay
    let h0 := freshCloudTurn "m-hermes" 1 .hermes
    let (hSub, _) := beginSubmit h0 1 1700000123456 1700000123456
    let (hRun, _) := confirmAccepted hSub 501 0 1700000123500
    if hRun.submittedAtMs? != some 1700000123456 || hRun.eventCursor? != none then
      IO.eprintln "[orb-core-test] FAIL: Hermes initial (submittedAtMs?, eventCursor?) split state mismatch"
      return 1
    let hermesTrace :=
      "id: 2\nevent: text_delta\ndata: {\"delta\":\"Alpha \"}\n\n" ++
      "id: 2\nevent: text_delta\ndata: {\"delta\":\"DUP\"}\n\n" ++
      "id: 1\nevent: text_delta\ndata: {\"delta\":\"REORDERED-STALE\"}\n\n" ++
      "id: 5\nevent: waiting_approval\ndata: {\"request\":{\"request_id\":77,\"command\":\"git push\",\"choices\":[\"allow\",\"deny\"]}}\n\n" ++
      "id: 4\nevent: text_delta\ndata: {\"delta\":\"LATE-4\"}\n\n" ++
      "id: 8\nevent: approval_resolved\ndata: {\"status\":\"resumed\"}\n\n" ++
      "id: 11\nevent: text_delta\ndata: {\"delta\":\"Omega\"}\n\n" ++
      "id: 12\nevent: completed\ndata: {\"status\":\"completed\"}\n\n" ++
      "id: 13\nevent: text_delta\ndata: {\"delta\":\"POST-TERMINAL\"}\n\n"
    let approvalChunk :=
      "id: 2\nevent: text_delta\ndata: {\"delta\":\"Alpha \"}\n\n" ++
      "id: 5\nevent: waiting_approval\ndata: {\"request\":{\"request_id\":77,\"command\":\"git push\",\"choices\":[\"allow\",\"deny\"]}}\n\n"
    let (hSseMid, hTurnMid, _, _) := stepHermesTurnChunk {} hRun approvalChunk 1700000124000
    let expectedApproval : CloudApprovalRequest := { reqId := 77, command := "git push", choices := #["allow", "deny"] }
     if hTurnMid.phase != .waitingApproval || hTurnMid.approval? != some expectedApproval ||
       hTurnMid.approvalReqId != 77 || hTurnMid.submittedAtMs? != some 1700000123456 ||
       hTurnMid.eventCursor? != some 5 || hTurnMid.stateRevision != hRun.stateRevision + 1 ||
       hSseMid.eventCursor? != some 5 || hSseMid.submittedAtMs? != some 1700000123456 then
      IO.eprintln "[orb-core-test] FAIL: Hermes typed WaitingApproval or split cursor/timestamp corrupted"
      return 1
    let (hSseDone, hTurnDone, hEvs, _) := stepHermesTurnChunk {} hRun hermesTrace 1700000125000
     if hSseDone.accumulatedText != "Alpha Omega" || hSseDone.eventCursor? != some 12 ||
       hSseDone.submittedAtMs? != some 1700000123456 || hTurnDone.phase != .terminal ||
       hTurnDone.approval? != none || hTurnDone.approvalReqId != 0 ||
       hTurnDone.eventCursor? != some 12 || hTurnDone.submittedAtMs? != some 1700000123456 ||
       hTurnDone.stateRevision != hRun.stateRevision + 1 ||
       hEvs.size != 5 then
      IO.eprintln s!"[orb-core-test] FAIL: Hermes duplicate/reordered/dropped SSE trace mismatch: text={hSseDone.accumulatedText} evs={hEvs.size}"
      return 1

    -- Cursor Cloud follow-up timeout -> `uncertain` -> blocked fresh retry -> `inspectProviderTurns` + `bindExistingTurn`
    -- AND `confirmNotDeliveredRetry` -> fresh `attemptId + 1`
    let c0 := freshCloudTurn "m-cursor" 2 .cursorCloud
    let (cSub, _) := beginSubmit c0 10 5000 5000
    let (cUnc, cUncEffs) := markUncertain cSub 5500
    let (cBlockedSame, cBlockedSameEffs) := beginSubmit cUnc 10 5600 5600
    let (cBlockedNext, cBlockedNextEffs) := beginSubmit cUnc 11 5600 5600
    if cUnc.phase != .uncertain || cUnc.errorKind != .transportTimeout || cUncEffs.isEmpty ||
       cBlockedSame != cUnc || !cBlockedSameEffs.isEmpty ||
       cBlockedNext != cUnc || !cBlockedNextEffs.isEmpty then
      IO.eprintln "[orb-core-test] FAIL: Cursor Cloud uncertain turn failed to fence fresh submission"
      return 1
    let obsMiss := inspectProviderTurns cUnc #[{ providerTurnId := 888, attemptId := 9, submittedAtMs := 5000 }]
    let obsHit := inspectProviderTurns cUnc #[
      { providerTurnId := 888, attemptId := 9, submittedAtMs := 5000 },
      { providerTurnId := 999, attemptId := 10, submittedAtMs := 5000 }
    ]
    if obsMiss != .none || obsHit != .matched 999 || cUnc.phase != .uncertain then
      IO.eprintln "[orb-core-test] FAIL: inspectProviderTurns did not match durable attempt handle cleanly"
      return 1
    let (cBound, cBoundEffs) := bindExistingTurn cUnc 999 3 5700
    if cBound.phase != .running || cBound.providerTurnId != 999 || cBound.eventCursor? != some 3 ||
       cBound.errorKind != .none || cBound.lastAttemptId != 10 || cBoundEffs.isEmpty then
      IO.eprintln "[orb-core-test] FAIL: bindExistingTurn did not reconcile uncertain turn to running"
      return 1
    let (cRequeued, cRequeuedEffs) := confirmNotDeliveredRetry cUnc 5700
    let (cDupAttempt, cDupEffs) := beginSubmit cRequeued 10 5800 5800
    let (cRetryOk, cRetryEffs) := beginSubmit cRequeued 11 5800 5800
    if cRequeued.phase != .queued || cRequeued.errorKind != .none || cRequeuedEffs.isEmpty ||
       cDupAttempt != cRequeued || !cDupEffs.isEmpty ||
       cRetryOk.phase != .submitting || cRetryOk.lastAttemptId != 11 ||
       cRetryOk.submittedAtMs? != some 5800 || cRetryEffs.isEmpty then
      IO.eprintln "[orb-core-test] FAIL: confirmNotDeliveredRetry / attemptId+1 recovery failed"
      return 1

     -- Cancel receipt preserves the cursor and counts as one revision, including from waitingApproval.
     let (hCancReq, _) := requestCancel hTurnMid 1700000124100
     let (hCancKept, hCancKeptEffs) := applyHermesEventToTurn hCancReq (.cancelled 0) 1700000124200
     let (hCancDone, hCancEffs) := applyHermesEventToTurn hCancReq (.cancelled 9) 1700000124300
     let (hCancFromWait, hCancFromWaitEffs) := applyHermesEventToTurn hTurnMid (.cancelled 9) 1700000124400
     let (hSubCanc, hSubCancEffs) := applyHermesEventToTurn hSub (.cancelled 4) 1700000124500
     let (hUncCanc, hUncCancEffs) := applyHermesEventToTurn cUnc (.cancelled 4) 1700000124600
     if hCancKeptEffs.isEmpty || hCancKept.phase != .terminal || hCancKept.eventCursor? != some 5 ||
        hCancKept.stateRevision != hCancReq.stateRevision + 1 ||
        hCancEffs.isEmpty || hCancDone.phase != .terminal || hCancDone.cancel != .confirmedReceipt ||
        hCancDone.eventCursor? != some 9 || hCancDone.stateRevision != hCancReq.stateRevision + 1 ||
        hCancFromWaitEffs.isEmpty || hCancFromWait.phase != .terminal ||
        hCancFromWait.eventCursor? != some 9 || hCancFromWait.approval? != none ||
        hCancFromWait.stateRevision != hTurnMid.stateRevision + 1 ||
        !hSubCancEffs.isEmpty || hSubCanc != hSub ||
        !hUncCancEffs.isEmpty || hUncCanc != cUnc then
       IO.eprintln "[orb-core-test] FAIL: Hermes cancel receipt cursor or single-revision fence broken"
       return 1
     let (zeroReq, zeroReqEffs) := awaitApproval hRun { reqId := 0, command := "nope" } 1700000124700
     if !zeroReqEffs.isEmpty || zeroReq != hRun then
       IO.eprintln "[orb-core-test] FAIL: awaitApproval accepted reqId 0"
       return 1

     -- SQLite crash-durable `cloud_turn_states` persistence + CAS revision conflict check.
     -- Schema is created inside persist/load; do not call ensureCloudTurnSchema first.
     let ctTs ← IO.monoNanosNow
     let ctRoot := s!"/tmp/orb-core-r4b-{ctTs}"
     let .ok ctStore ← openCoreStore ctRoot
       | do IO.eprintln "[orb-core-test] FAIL: openCoreStore for R4-B failed"; return 1
     let .ok none ← loadCloudTurn? ctStore.missionsDb hTurnMid.missionId hTurnMid.turnIndex
       | do closeCoreStore ctStore; IO.eprintln "[orb-core-test] FAIL: fresh loadCloudTurn? should be none"; return 1
     let .ok persisted1 ← persistCloudTurn ctStore.missionsDb hTurnMid 0
       | do closeCoreStore ctStore; IO.eprintln "[orb-core-test] FAIL: initial persistCloudTurn failed"; return 1
     let .ok peerDb ← openSqliteDb s!"{ctRoot}/missions.db" ""
       | do closeCoreStore ctStore; IO.eprintln "[orb-core-test] FAIL: second cloud_turn connection failed"; return 1
     let staleRes ← persistCloudTurn ctStore.missionsDb cUnc 0
     let cUncSameKey := { cUnc with missionId := hTurnMid.missionId, turnIndex := hTurnMid.turnIndex }
     let conflictRes ← persistCloudTurn peerDb cUncSameKey 0
     let staleUpdate ← persistCloudTurn peerDb { persisted1 with detail := "lost" } 0
     let missingUpdate ← persistCloudTurn peerDb { cUnc with detail := "missing" } 7
     let .ok persisted2 ← persistCloudTurn ctStore.missionsDb hTurnDone persisted1.stateRevision
       | do discard <| sqliteCloseRaw peerDb.handle; closeCoreStore ctStore
            IO.eprintln "[orb-core-test] FAIL: CAS update persistCloudTurn failed"; return 1
     let racedUpdate ← persistCloudTurn peerDb { persisted1 with detail := "stale" } persisted1.stateRevision
     let .ok loadedDone? ← loadCloudTurn? ctStore.missionsDb hTurnDone.missionId hTurnDone.turnIndex
       | do discard <| sqliteCloseRaw peerDb.handle; closeCoreStore ctStore
            IO.eprintln "[orb-core-test] FAIL: loadCloudTurn? failed"; return 1
     let .ok loadedUnc? ← loadCloudTurn? ctStore.missionsDb cUnc.missionId cUnc.turnIndex
       | do discard <| sqliteCloseRaw peerDb.handle; closeCoreStore ctStore
            IO.eprintln "[orb-core-test] FAIL: loadCloudTurn? uncertain failed"; return 1
     let resetWaitingSql :=
       "UPDATE cloud_turn_states SET phase_code=?1,approval_req_id=?2,approval_json=?3,event_cursor=?4,state_revision=?5 WHERE mission_id=?6 AND turn_index=?7;"
     let resetWaitingArgs : Array String := #[
       s!"{phaseCodeOf hTurnMid}", "77",
       "{\"req_id\":77,\"command\":\"git push\",\"choices\":[\"allow\",\"deny\"]}",
       "5", s!"{persisted1.stateRevision}", hTurnMid.missionId, s!"{hTurnMid.turnIndex}"
     ]
     let corruptCases : Array String := #[
       "UPDATE cloud_turn_states SET approval_json='' WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET approval_json='not-json' WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET approval_req_id=0 WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET approval_json='{\"req_id\":78,\"command\":\"git push\",\"choices\":[]}' WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET phase_code=2 WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET phase_code=2,approval_req_id=0 WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET phase_code=2,approval_json='' WHERE mission_id=?1 AND turn_index=?2;",
       "UPDATE cloud_turn_states SET state_revision=0 WHERE mission_id=?1 AND turn_index=?2;"
     ]
     let badWrite ← persistCloudTurn peerDb { hTurnMid with approval? := none } 0
     let mut corruptFailed := false
     for sql in corruptCases do
       let _ ← execParamQuery peerDb resetWaitingSql resetWaitingArgs
       let upd ← execParamQuery peerDb sql #[hTurnMid.missionId, s!"{hTurnMid.turnIndex}"]
       if upd.isOk then
         match ← loadCloudTurn? peerDb hTurnMid.missionId hTurnMid.turnIndex with
         | .error "cloud_turn_row_corrupt" => pure ()
         | _ => corruptFailed := true
       else
         corruptFailed := true
     let _ ← execParamQuery peerDb resetWaitingSql resetWaitingArgs
     let .ok (some restored) ← loadCloudTurn? peerDb hTurnMid.missionId hTurnMid.turnIndex
       | do discard <| sqliteCloseRaw peerDb.handle; closeCoreStore ctStore
            IO.eprintln "[orb-core-test] FAIL: restored waitingApproval row did not load"; return 1
     discard <| sqliteCloseRaw peerDb.handle
     closeCoreStore ctStore
     IO.FS.removeDirAll ctRoot
     let isCasErr := fun (r : Except String CloudTurnState) =>
       match r with | .error "cloud_turn_cas_conflict" => true | _ => false
     let isBadApprovalErr := fun (r : Except String CloudTurnState) =>
       match r with | .error "cloud_turn_invalid_approval_state" => true | _ => false
     if !staleRes.isOk || !isCasErr conflictRes ||
        !isCasErr staleUpdate || !isCasErr missingUpdate || !isCasErr racedUpdate ||
        !isBadApprovalErr badWrite ||
        persisted1.stateRevision != 1 || persisted2.stateRevision != persisted1.stateRevision + 1 ||
        loadedDone? != some persisted2 || loadedUnc?.map (fun s => s.phase) != some .uncertain ||
        corruptFailed || restored.phase != .waitingApproval then
       IO.eprintln "[orb-core-test] FAIL: cloud_turn_states SQLite CAS or corrupt-row fence mismatch"
       return 1

     -- Hermes JSON fallback steps CloudTurnState: sticky terminal, approval resolve, cancel receipt, store round-trip.
     let termView := seedHermesView hTurnDone { accumulatedText := "Alpha Omega", terminalStatus? := some "completed" }
     let (termTurn, termView2, termEvs, termEffs) :=
       applyHermesJsonFallback hTurnDone termView (.obj #[("status", .str "running"), ("output", .str "LATE")]) 1700000126000
     if termTurn != hTurnDone || termView2.eventCursor? != termView.eventCursor? ||
        !termEvs.isEmpty || !termEffs.isEmpty then
       IO.eprintln "[orb-core-test] FAIL: Hermes JSON fallback mutated a sticky terminal turn"
       return 1
     let (resolved, resolvedView, resolvedEvs, resolvedEffs) :=
       applyHermesJsonFallback hTurnMid (seedHermesView hTurnMid {})
         (.obj #[("status", .str "running")]) 1700000126100
     if resolved.phase != .running || resolved.approval? != none || resolved.approvalReqId != 0 ||
        resolved.eventCursor? != some 6 || resolved.submittedAtMs? != hTurnMid.submittedAtMs? ||
        resolved.stateRevision != hTurnMid.stateRevision + 1 ||
        resolvedView.pendingApproval? != none || resolvedView.terminalStatus? != none ||
        resolvedEvs != #[.approvalResolved 6] || resolvedEffs.isEmpty then
       IO.eprintln "[orb-core-test] FAIL: Hermes JSON fallback did not resolve waitingApproval to running"
       return 1
     let (stillCanc, _, stillEvs, stillEffs) :=
       applyHermesJsonFallback hCancReq (seedHermesView hCancReq {})
         (.obj #[("status", .str "running"), ("output", .str "draining")]) 1700000126200
     let (failCanc, failView, failEvs, _) :=
       applyHermesJsonFallback hCancReq (seedHermesView hCancReq {})
         (.obj #[("status", .str "failed"), ("error", .str "provider cancelled")]) 1700000126300
     let (doneCanc, _, doneEvs, _) :=
       applyHermesJsonFallback hCancReq (seedHermesView hCancReq {})
         (.obj #[("status", .str "completed"), ("output", .str "finished")]) 1700000126400
     if stillCanc != hCancReq || !stillEvs.isEmpty || !stillEffs.isEmpty ||
        failCanc.phase != .terminal || failCanc.cancel != .confirmedReceipt ||
        failCanc.eventCursor? != some 6 || failCanc.errorKind != .providerRejected ||
        failCanc.stateRevision != hCancReq.stateRevision + 1 ||
        failView.terminalStatus? != some "failed" || failEvs.size != 1 ||
        doneCanc.phase != .terminal || doneCanc.eventCursor? != some 6 || doneEvs.size != 1 then
       IO.eprintln "[orb-core-test] FAIL: Hermes JSON fallback cancel receipt fence broken"
       return 1
     let fbTs ← IO.monoNanosNow
     let fbRoot := s!"/tmp/orb-core-r4b-fb-{fbTs}"
     let .ok fbStore ← openCoreStore fbRoot
       | do IO.eprintln "[orb-core-test] FAIL: openCoreStore for Hermes fallback failed"; return 1
     let .ok (fbListen, fbPort) ← tcpListen "127.0.0.1" 0 16
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: Hermes fallback listen failed"; return 1
     let _ ← IO.asTask (prio := .dedicated) do
       for idx in [0:4] do
         if let .ok cfd ← tcpAcceptPoll fbListen 5000 then
           let _ ← readHttpRequestFromFd cfd none 2000
           let (statusLine, body) :=
             if idx == 0 || idx == 2 then ("404 Not Found", "{}")
             else if idx == 1 then ("200 OK", "{\"status\":\"running\"}")
             else ("200 OK", "{\"status\":\"cancelled\"}")
           let wire := s!"HTTP/1.1 {statusLine}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8
           discard <| writeAll cfd wire false
           discard <| closeFd cfd
       discard <| closeFd fbListen
     let fbBase := s!"http://127.0.0.1:{fbPort}"
     let .ok (stickyView, stickyTurn, stickyEvs) ←
       streamOrFallbackHermesRun fbBase "run-sticky" none hTurnDone
         { accumulatedText := "Alpha Omega", terminalStatus? := some "completed" } (some fbStore) 1700000127000
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: sticky streamOrFallbackHermesRun errored"; return 1
     let .ok none ← loadCloudTurn? fbStore.missionsDb hTurnDone.missionId hTurnDone.turnIndex
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: sticky poll persisted a terminal turn"; return 1
     let .ok (runView, runTurn, runEvs) ←
       syncHermesTurnWithStore fbStore fbBase "run-wait" none hTurnMid {} 1700000127100
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: syncHermesTurnWithStore resolve errored"; return 1
     let .ok (some loadedRun) ← loadCloudTurn? fbStore.missionsDb hTurnMid.missionId hTurnMid.turnIndex
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: resolved Hermes turn missing from store"; return 1
     let (fbCancReq, _) := requestCancel loadedRun 1700000127150
     let .ok persistedCancReq ← persistCloudTurn fbStore.missionsDb fbCancReq loadedRun.stateRevision
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: persistCloudTurn cancelRequested errored"; return 1
     let .ok (cancView, cancTurn, cancEvs) ←
       streamOrFallbackHermesRun fbBase "run-cancel" none persistedCancReq (seedHermesView persistedCancReq {}) (some fbStore) 1700000127200
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: cancel streamOrFallbackHermesRun errored"; return 1
     let .ok (some loadedCanc) ← loadCloudTurn? fbStore.missionsDb persistedCancReq.missionId persistedCancReq.turnIndex
       | do closeCoreStore fbStore; IO.eprintln "[orb-core-test] FAIL: finalized cancel turn missing from store"; return 1
     closeCoreStore fbStore
     IO.FS.removeDirAll fbRoot
     if stickyTurn != hTurnDone || stickyView.eventCursor? != some 12 || !stickyEvs.isEmpty ||
        runTurn.phase != .running || runTurn.approval? != none || runTurn.eventCursor? != some 6 ||
        runTurn.stateRevision != 1 || runView.pendingApproval? != none ||
        runEvs != #[.approvalResolved 6] || loadedRun != runTurn ||
        cancTurn.phase != .terminal || cancTurn.cancel != .confirmedReceipt ||
        cancTurn.eventCursor? != some 7 || cancTurn.stateRevision != 3 ||
        loadedCanc != cancTurn ||
        cancView.terminalStatus? != some "cancelled" || cancEvs != #[.cancelled 7] then
       IO.eprintln "[orb-core-test] FAIL: streamOrFallbackHermesRun JSON fallback round-trip mismatch"
       return 1
     pure (0 : UInt32)) != 0 then return 1


  -- 7b. Phase R4-D (`SM-21`): extracted so `runSuite` stays under the heartbeat elaboration bound.
  if (← runR4dProxyAuthTests prodValid) != 0 then return 1

  let hostOk ← runAllHostTests emitLogPath?
  if !hostOk then
    IO.eprintln "[orb-core-test] FAIL: OrbCore.HostTests failed"
    return 1
  if (← runR5bManagedStoreTests prodValid) != 0 then return 1
  if (← runR7CoreTests prodValid) != 0 then return 1
  if (← runMultiUserCoreTests prodValid) != 0 then return 1
  if (← runWarmClaudeControlAndCheckpointsCoreTests prodValid) != 0 then return 1
  if (← runZeroWaitPerfAndSyncTests prodValid) != 0 then return 1
  if (← runOrbUriCorsTests) != 0 then return 1
  if (← runProdParityAndMissionMoveTests prodValid) != 0 then return 1
  if (← runRemoteDispatchWakeupAndBtwTests prodValid) != 0 then return 1
  if (← runLibraryGitAndSkillParityTests) != 0 then return 1

  IO.println "{\"ok\":true,\"binary\":\"orb-core-test\",\"spec_gates\":11,\"harness_contracts\":10,\"host_tests\":101}"
  return 0

end OrbCore.SelfTest

def main (args : List String) : IO UInt32 := do
  OrbBin.PosixExt.setenvVar "ORB_HERMETIC_TEST" "1"
  OrbCore.SettingsDocumentTests.run
  OrbCore.SettingsTransferTests.run
  OrbCore.SelfTest.runSuite (OrbCore.SelfTest.findFlag? args "--emit-evidence-log")
