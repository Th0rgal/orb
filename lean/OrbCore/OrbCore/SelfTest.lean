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
open OrbCore.Control
open OrbCore.HostTests
open OrbCore.HarnessSessionRegistry

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
     (rep1Str.splitOn "\"status\":\"interrupted\"").length != 2 ||
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
    id := "m-manual-sup", title := "Manual Supersession Test", status := "interrupted",
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

  closeCoreStore store
  -- Re-opening `openCoreStore tmpRoot` MUST auto-increment persistent `bootEpoch` (`1 -> 2`), recover stale boot-1 leases,
  -- heal `m-crash-pend` (`pending -> interrupted` with `usage_limit_wait`), and preserve `m-deferred-pend` (`pending`)!
  let .ok storeBoot2 ← openCoreStore tmpRoot
    | do IO.eprintln "[orb-core-test] FAIL: second openCoreStore failed"; return 1
  if storeBoot2.bootEpoch != 2 then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: expected persistent bootEpoch=2 on reopen, got {storeBoot2.bootEpoch}"
    return 1
  let cpRows ← execParamQuery storeBoot2.missionsDb "SELECT status,COALESCE(terminal_reason,'') FROM missions WHERE id='m-crash-pend';" #[]
  let dpRows ← execParamQuery storeBoot2.missionsDb "SELECT status FROM missions WHERE id='m-deferred-pend';" #[]
  let cpStatus := match cpRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  let cpReason := match cpRows with | .ok rs => (rs[1]?.bind (·[1]?)).getD "" | .error _ => ""
  let dpStatus := match dpRows with | .ok rs => (rs[1]?.bind (·[0]?)).getD "" | .error _ => ""
  if cpStatus != "interrupted" || cpReason != "usage_limit_wait" || dpStatus != "pending" then
    closeCoreStore storeBoot2
    IO.eprintln s!"[orb-core-test] FAIL: startup reconcileStrandedPendingMissions mismatch: cp=({cpStatus},{cpReason}) dp={dpStatus}"
    return 1
  closeCoreStore storeBoot2
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
     (handoffStr.splitOn "fork-workspace:").length != 1 then
    closeCoreStore store
    IO.eprintln s!"[orb-core-test] FAIL: cloud-to-workspace handoff response mismatch: status={validHandoffResp.status} body={handoffStr}"
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
          observeProviderPayload "boost" "m2" 200 (.obj #[("status", .str "halted")]),
          observeProviderPayload "hetzner" "m3" 200 (.obj #[("status", .str "off")]),
          observeProviderPayload "vastai" "m4" 200 (.obj #[("state", .str "exited")]),
          observeProviderPayload "scaleway" "m5" 200 (.obj #[("state", .str "stopped_in_place")]),
          observeProviderPayload "colab" "m6" 404 (.obj #[]) with
    | .ok o1, .ok o2, .ok o3, .ok o4, .ok o5, .ok o6 =>
      o1.observedStatus == "ready" && !o1.orphaned && o1.spentCents == 12 &&
      o2.observedStatus == "stopped" && o3.observedStatus == "stopped" &&
      o4.observedStatus == "stopped" && o5.observedStatus == "stopped" &&
      o6.orphaned && (observeProviderPayload "aws" "m7" 200 (.obj #[])).isOk == false
    | _, _, _, _, _, _ => false
  if !adapterOk then
    closeManagedComputeStore mst
    IO.eprintln "[orb-core-test] FAIL: pure ProviderObservation adapter check failed"
    return 1
  let fleet0 : ManagedFleetState := { enabled := true, boatEnabled := true }
  let vm0 : ManagedMachine := {
    id := "mm-r5b-1", sandboxName := "orb-managed-mm-r5b-1", provider := "boat",
    size := "small", spentCents := 25, nodeBootEpoch := 1, deletableAtSec := 100
  }
  let .ok _ ← provisionManagedMachine mst fleet0 vm0 50
    | do closeManagedComputeStore mst; IO.eprintln "[orb-core-test] FAIL: provisionManagedMachine failed"; return 1
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

  -- 3. SM-17: Non-contended `ProcessKillHandle` (`procLivenessStep` + `/proc/<pid>/stat` parser + contended mutex test)
  let trickyStat :=
    "54321 (codex (worker) 1) S 1 54321 54321 0 -1 4194304 100 0 0 0 12 3 0 0 20 0 4 0 88776655 12345678 1024"
  let parsedObs := parseProcStatContent trickyStat
  if parsedObs.procMissing != 0 || parsedObs.procReadError != 0 || parsedObs.isZombieOrDeadState != 0 ||
     parsedObs.actualStartTicks != 88776655 || parsedObs.fieldsAfterComm < 20 then
    IO.eprintln s!"[orb-core-test] FAIL: SM-17 parseProcStatContent failed on parens/spaces comm: {repr parsedObs}"
    return 1
  -- Live `/proc/self/stat` check on Linux
  let selfPid ← OrbBin.PosixExt.getpid
  let selfTicks? ← readLiveProcStartTicks? selfPid
  if selfPid == 0 || selfTicks?.isNone then
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
      let _ := releaseLock.result!.get
      pure ()
  let _ := enteredLock.result!.get
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

set_option maxRecDepth 4000 in
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
  let pacingTracker ← newProxyPacingTracker
  let memTokenCache ← newMemoryTokenCache
  let cloudWakeup ← newCloudWorkerWakeup
  let bunkerRef ← IO.mkRef (0 : UInt8)
  let appSt : CoreAppState := {
    cfg := prodValid, store := store, searchIdx? := some sIdx1,
    managedRef := managedRef, chainsRef := chainsRef,
    proxyCooldownsRef := proxyCooldownsRef, seqRef := seqRef,
    pacingTracker? := some pacingTracker,
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
  let hostOk ← runAllHostTests emitLogPath?
  if !hostOk then
    IO.eprintln "[orb-core-test] FAIL: OrbCore.HostTests failed"
    return 1
  if (← runR5bManagedStoreTests prodValid) != 0 then return 1

  IO.println "{\"ok\":true,\"binary\":\"orb-core-test\",\"spec_gates\":7,\"harness_contracts\":9,\"host_tests\":85}"
  return 0

end OrbCore.SelfTest

def main (args : List String) : IO UInt32 :=
  OrbCore.SelfTest.runSuite (OrbCore.SelfTest.findFlag? args "--emit-evidence-log")
