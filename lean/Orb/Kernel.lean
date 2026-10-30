/-
  Orb.Kernel: Pure Unboxed Scalar C-ABI Kernel (`0 import Lean`, `0 sorryAx`)
  Contains only primitive `UInt8` / `UInt32` / `UInt64` functions with `@[inline, export]`.
  Compiled via `lean Orb/Kernel.lean -c Orb_Kernel.c` + `cc -O3 -ffunction-sections -fdata-sections`
  + `ld -r --gc-sections` into a self-contained static archive (`liborb_spec_cabi.a`) with zero
  Lean runtime symbol dependencies (`nm -u` count == 0) and zero hand-written C fallbacks.
-/

namespace Orb.Kernel

/--
  Unboxed C-ABI Writer Identity Reuse & Continuation Gate (`orb_verify_writer_reuse`):
  - If `hasContinue == 1`: requires `contTrackNonempty == 1`, `contMatchesStored == 1`, and `hasAnyEdit == 0`.
  - If `hasContinue == 0`: requires `workChanged == 0 || identityUpdated == 1`.
-/
@[inline, export orb_verify_writer_reuse]
def verifyWriterReuse
    (hasContinue contTrackNonempty contMatchesStored hasAnyEdit workChanged identityUpdated : UInt8) : UInt8 :=
  if hasContinue == 1 then
    if contTrackNonempty == 1 && contMatchesStored == 1 && hasAnyEdit == 0 then 1 else 0
  else
    if workChanged == 0 || identityUpdated == 1 then 1 else 0

/--
  Unboxed C-ABI Track Lease Mode Classifier (`orb_verify_lease_mode`):
  Returns `0` for `"reader"` and `1` for `"writer"`.
  - `writerFlag`: `0` = `Some(false)`, `1` = `Some(true)`, `2` = `None`
  - `hasReadonlyTag == 1` or `writerFlag == 0` forces `"reader"` (`0`)
  - `hasWriterTag == 1` or `writerFlag == 1` forces `"writer"` (`1`)
  - Otherwise `isReadonlyIntent == 1` selects `"reader"` (`0`), else `"writer"` (`1`).
-/
@[inline, export orb_verify_lease_mode]
def verifyLeaseMode (writerFlag hasReadonlyTag hasWriterTag isReadonlyIntent : UInt8) : UInt8 :=
  if writerFlag == 0 || hasReadonlyTag == 1 then 0
  else if writerFlag == 1 || hasWriterTag == 1 then 1
  else if isReadonlyIntent == 1 then 0
  else 1

/--
  Unboxed C-ABI Conservative Execution Ownership Gate (`orb_verify_track_hold`):
  Returns `1` when a mission still holds track ownership:
  either it has unresolved execution (`inUnresolved == 1`), queued assignments (`inQueued == 1`),
  a non-terminal/non-acknowledged presentation (`hasLiveOwner == 1`), or a stopped native goal (`nativeGoalHolds == 1`).
-/
@[inline, export orb_verify_track_hold]
def verifyTrackHold (inUnresolved inQueued hasLiveOwner nativeGoalHolds : UInt8) : UInt8 :=
  if inUnresolved == 1 || inQueued == 1 || hasLiveOwner == 1 || nativeGoalHolds == 1 then 1 else 0

/--
  Unboxed C-ABI Remote Handle Repository Conflict Gate (`orb_verify_repo_disjoint`):
  Returns `1` if a remote handle is provably disjoint from a target PR's repository:
  requires both repositories to be canonically parsed (`handleRepoKnown == 1 && targetRepoKnown == 1`)
  and their canonical identities to differ (`sameRepo == 0`).
-/
@[inline, export orb_verify_repo_disjoint]
def verifyRepoDisjoint (handleRepoKnown targetRepoKnown sameRepo : UInt8) : UInt8 :=
  if handleRepoKnown == 1 && targetRepoKnown == 1 && sameRepo == 0 then 1 else 0

/--
  Unboxed C-ABI Durable Remote Queue Admission & Cancellation Gate (`orb_verify_remote_outbox`):
  - For `opKind == 0` (enqueue retry check): if `alreadyExists == 1`, admits (`1`) iff
    `sameMission == 1 && isCancelled == 0`; if `alreadyExists == 0`, admits (`1`) iff
    `isSuperseded == 0 && sessionReady == 1 && prUnsupported == 0`.
  - For `opKind != 0` (cancel waiting row): admits (`1`) iff `hasJobId == 0 || deliveryAbandonable == 1`.
-/
@[inline, export orb_verify_remote_outbox]
def verifyRemoteOutbox
    (opKind alreadyExists sameMission isCancelled isSuperseded sessionReady
     prUnsupported hasJobId deliveryAbandonable : UInt8) : UInt8 :=
  if (opKind == 0 && ((alreadyExists == 1 && sameMission == 1 && isCancelled == 0) ||
                      (alreadyExists == 0 && isSuperseded == 0 && sessionReady == 1 && prUnsupported == 0))) ||
     (opKind != 0 && (hasJobId == 0 || deliveryAbandonable == 1)) then 1 else 0

/--
  Unboxed C-ABI Task Board Slot Reservation Gate (`orb_verify_board_slots`):
  Verifies that `reservedBossSlots ≥ 1`, `reservedBossSlots < maxParallel`,
  and `totalRunning < maxParallel - reservedBossSlots` so the boss always retains a reserved slot.
-/
@[inline, export orb_verify_board_slots]
def verifyBoardSlots (maxParallel reservedBossSlots totalRunning : UInt32) : UInt8 :=
  if reservedBossSlots ≥ 1 && reservedBossSlots < maxParallel &&
     totalRunning < maxParallel - reservedBossSlots then 1 else 0

/--
  Unboxed C-ABI Task Board Automatic Retry Gate (`orb_verify_board_retry`):
  Verifies that `maxAttempts ≥ 1`, `attempts < maxAttempts`, `requiresExternalRecovery == 0`,
  `preflightMerged == 0` (already-merged PRs park for boss review), and `retrySuppressed == 0`.
-/
@[inline, export orb_verify_board_retry]
def verifyBoardRetry
    (attempts maxAttempts : UInt32)
    (requiresExternalRecovery preflightMerged retrySuppressed : UInt8) : UInt8 :=
  if maxAttempts ≥ 1 && attempts < maxAttempts &&
     requiresExternalRecovery == 0 && preflightMerged == 0 && retrySuppressed == 0 then 1 else 0

/--
  Unboxed C-ABI Node Job Lifecycle State Machine Gate (`orb_verify_job_transition`):
  State encoding: `0 = queued`, `1 = running`, `2 = succeeded`, `3 = failed`, `4 = cancelled`, `5 = lost`.
  - Terminal states (`2, 3, 4`) are absorbing.
  - Allowed transitions:
    * `0 (queued) → 1 (running) | 2 | 3 | 4 | 5`
    * `1 (running) → 2 | 3 | 4 | 5`
    * `5 (lost) → 4 (cancelled)` (once containment scope is confirmed stopped).
-/
@[inline, export orb_verify_job_transition]
def verifyJobTransition (fromState toState : UInt8) : UInt8 :=
  if (fromState == 0 && toState ≥ 1 && toState ≤ 5) ||
     (fromState == 1 && toState ≥ 2 && toState ≤ 5) ||
     (fromState == 5 && toState == 4) then 1 else 0

/--
  Unboxed C-ABI Source Bundle & HTTP Body Capacity Gate (`orb_verify_bundle_budget`):
  Verifies that decoded source bundle bytes `decodedBytes` fit within the effective receiver ceiling
  (`completeCap` when `isComplete == 1`, else `overlayCap`) and within the caller-supplied `maxBytes` wire ceiling.
-/
@[inline, export orb_verify_bundle_budget]
def verifyBundleBudget (isComplete : UInt8) (decodedBytes overlayCap completeCap maxBytes : UInt64) : UInt8 :=
  let limit := if isComplete == 1 then completeCap else overlayCap
  if decodedBytes ≤ limit && decodedBytes ≤ maxBytes then 1 else 0

/--
  Unboxed C-ABI Node Bearer Token Rotation & Scoped Lease Gate (`orb_verify_token_rotation`):
  Verifies that `presentedNonEmpty == 1`, `(matchCurrent == 1 || (prevNonEmpty == 1 && matchPrev == 1))`,
  and `scopeAndExpiryOk == 1`.
-/
@[inline, export orb_verify_token_rotation]
def verifyTokenRotation
    (presentedNonEmpty matchCurrent prevNonEmpty matchPrev scopeAndExpiryOk : UInt8) : UInt8 :=
  if presentedNonEmpty == 1 &&
     (matchCurrent == 1 || (prevNonEmpty == 1 && matchPrev == 1)) &&
     scopeAndExpiryOk == 1 then 1 else 0

/--
  Unboxed C-ABI Bounded Process Log Window Gate (`orb_verify_log_window`):
  Verifies that `offset ≤ fileSize`, `reqLen ≤ maxChunk`, `maxChunk ≤ hardCap`,
  `actualLen ≤ reqLen`, and `actualLen ≤ fileSize - offset`.
-/
@[inline, export orb_verify_log_window]
def verifyLogWindow (offset reqLen maxChunk hardCap fileSize actualLen : UInt64) : UInt8 :=
  if offset ≤ fileSize && reqLen ≤ maxChunk && maxChunk ≤ hardCap &&
     actualLen ≤ reqLen && actualLen ≤ fileSize - offset then 1 else 0

/--
  Unboxed C-ABI Bijective 64-bit Avalanche Word Mixer (`orb_mix64_word`).
-/
@[inline, export orb_mix64_word]
def mix64Word (acc word : UInt64) : UInt64 :=
  let v1 := acc + word * 0xBF58476D1CE4E5B9
  let v2 := (v1 <<< 31) ||| (v1 >>> 33)
  let v3 := v2 * 0x9E3779B97F4A7C15
  v3 ^^^ (v3 >>> 27)

/--
  Unboxed C-ABI Proxy SSE Commitment & Transparent Reroute Stepper (`orb_proxy_step`):
  Packs `(committedNext : UInt8, action : UInt8, excludeCurrent : UInt8)` into a 32-bit word:
  `bit 0 = committedNext`, `bits 8..15 = action (0 = pass, 1 = reroute_same, 2 = reroute_exclude, 3 = fail_stall)`,
  `bit 16 = excludeCurrent`.
  - Commitment is sticky (`committedNext = 1` iff `committed == 1 || chunkCommits == 1`).
  - Once committed (`committed == 1`), transparent reroute (`action == 1 || action == 2`) is forbidden.
-/
@[inline, export orb_proxy_step]
def proxyStep (committed chunkCommits stalled : UInt8) (retries maxRetries : UInt32) : UInt32 :=
  let cNext : UInt32 := if committed == 1 || chunkCommits == 1 then 1 else 0
  if stalled == 1 then
    if committed == 0 && retries < maxRetries then
      if retries + 1 ≥ 2 then cNext ||| 0x00010200
      else cNext ||| 0x00000100
    else
      cNext ||| 0x00000300
  else
    cNext

/--
  Unboxed C-ABI Proxy 3-Clock Discipline Gate (`orb_stream_deadlines`):
  Packs `(emitKeepalive : UInt8, upstreamStalled : UInt8, touchLiveness : UInt8)` into a 32-bit word:
  - Clock 1 (`bit 0 = emitKeepalive`): `clientElapsedMs ≥ keepaliveMs && atEventBoundary == 1`
  - Clock 2 (`bit 8 = upstreamStalled`): `upstreamElapsedMs ≥ max baseIdleMs providerFloorMs`
  - Clock 3 (`bit 16 = touchLiveness`): `hasMissionHeader == 1 && authVerified == 1`
-/
@[inline, export orb_stream_deadlines]
def streamDeadlines
    (clientElapsedMs keepaliveMs upstreamElapsedMs baseIdleMs providerFloorMs : UInt64)
    (atEventBoundary hasMissionHeader authVerified : UInt8) : UInt32 :=
  let effIdle := if providerFloorMs > baseIdleMs then providerFloorMs else baseIdleMs
  let ka : UInt32 := if clientElapsedMs ≥ keepaliveMs && atEventBoundary == 1 then 1 else 0
  let stall : UInt32 := if upstreamElapsedMs ≥ effIdle then 256 else 0
  let live : UInt32 := if hasMissionHeader == 1 && authVerified == 1 then 65536 else 0
  ka ||| stall ||| live

/--
  Unboxed C-ABI Provider Circuit-Breaker Stepper (`orb_breaker_step`):
  `reason`: `0 = ok`, `1 = rate_limit_429`, `2 = quota_exhausted`, `3 = payment_required_402`,
            `4 = transient_502_timeout`, `5 = auth_401_403`.
  Packs `(parkAccount : UInt8, poisonSubscription : UInt8, applyCooldown : UInt8)` into a 32-bit word:
  `bit 0 = parkAccount`, `bit 8 = poisonSubscription`, `bit 16 = applyCooldown`.
  - Transient 502/timeout (`reason == 4`) with `transientStreak < transientThreshold` applies zero cooldown (`0`)
    and never poisons the subscription.
  - Only `rate_limit_429` (`1`) or `quota_exhausted` (`2`) may poison a shared subscription (`bit 8`).
  - `quota_exhausted` (`2`) and `payment_required_402` (`3`) park the account across restarts (`bit 0`).
-/
@[inline, export orb_breaker_step]
def breakerStep (reason : UInt8) (transientStreak transientThreshold : UInt32) : UInt32 :=
  if reason == 0 then 0
  else if reason == 4 then
    if transientStreak ≥ transientThreshold && transientThreshold ≥ 1 then 65536 else 0
  else if reason == 2 || reason == 3 then
    let sub : UInt32 := if reason == 2 then 256 else 0
    (1 : UInt32) ||| sub ||| 65536
  else if reason == 1 then
    65792
  else
    65536

/--
  Unboxed C-ABI Host `/goal` & Mission Turn-End Stepper (`orb_mission_step`):
  `signal`: `0 = none`, `1 = complete`, `2 = aborted`.
  Returns outcome code:
  `0 = stopped`, `1 = complete`, `2 = aborted`, `3 = already_queued`,
  `4 = paused_wakeup`, `5 = stalled`, `6 = budget_limited`, `7 = continue_goal`.
  When `armed == 1`, `signal == 0`, `continuationPending == 0`, and `wakeupArmed == 1`,
  returns `4 (paused_wakeup)` instead of completing or queuing a duplicate continuation.
-/
@[inline, export orb_mission_step]
def missionStep
    (armed signal continuationPending wakeupArmed madeProgress : UInt8)
    (priorNoProgress maxNoProgress priorContinuations maxContinuations hasMaxCont : UInt32) : UInt8 :=
  if armed == 0 then 0
  else if signal == 1 then 1
  else if signal == 2 then 2
  else if continuationPending == 1 then 3
  else if wakeupArmed == 1 then 4
  else
    let effMaxNoProg := if maxNoProgress ≥ 1 then maxNoProgress else 1
    let noProg := if madeProgress == 1 then 0 else priorNoProgress + 1
    if noProg ≥ effMaxNoProg then 5
    else if hasMaxCont == 1 && priorContinuations + 1 > maxContinuations then 6
    else 7

/--
  Unboxed C-ABI Boot-Scoped Orphan & Ghost-Active Reconciler Stepper (`orb_reconcile_step`):
  `status`: `0 = active`, `1 = awaiting_user`, `2 = interrupted`, `3 = other`.
  Returns verdict: `0 = keep`, `1 = interrupt_and_resume`, `2 = tag_orphaned`, `3 = reresume_interrupted`.
  - A mission from the current boot (`sameBootId == 1`) or with a live runner/scope/durable run is never
    reaped as a ghost-active or orphan (`0 = keep`).
-/
@[inline, export orb_reconcile_step]
def reconcileStep
    (status isClientPlaced sameBootId isAssistantMode runningInActor
     hasLiveScope hasDurableRun recentlyUpdated hasEvents alreadyOrphaned
     isServiceRestart withinHorizon liveRetryExists : UInt8) : UInt8 :=
  if isClientPlaced == 1 || sameBootId == 1 || runningInActor == 1 ||
     hasLiveScope == 1 || hasDurableRun == 1 then 0
  else if status == 0 then
    if isAssistantMode == 0 && recentlyUpdated == 0 then 1 else 0
  else if status == 1 then
    if hasEvents == 0 && alreadyOrphaned == 0 then 2 else 0
  else if status == 2 then
    if isServiceRestart == 1 && withinHorizon == 1 && liveRetryExists == 0 then 3 else 0
  else 0

/--
  Unboxed C-ABI Follow-Up Queue Retention & Uncertain-Delivery Stepper (`orb_queue_step`):
  `deliveryOutcome`: `0 = acked`, `1 = rejected`, `2 = uncertain_timeout`, `3 = persist_failed`.
  Packs `(retainInQueue : UInt8, markConsumed : UInt8, blockCancel : UInt8)` into a 32-bit word:
  `bit 0 = retainInQueue`, `bit 8 = markConsumed`, `bit 16 = blockCancel`.
  - Only confirmed delivery (`deliveryOutcome == 0 && durablyStarted == 1`) marks the message consumed (`bit 8`)
    and drops it from the pending queue (`retainInQueue == 0`).
  - Uncertain delivery (`deliveryOutcome == 2`) retains the entry and blocks cancellation (`bit 16`).
-/
@[inline, export orb_queue_step]
def queueStep (deliveryOutcome durablyStarted : UInt8) : UInt32 :=
  if deliveryOutcome == 0 && durablyStarted == 1 then
    256
  else if deliveryOutcome == 2 then
    65537
  else
    1

/--
  Unboxed C-ABI Managed VM Admission, Budget, RAM & Reaper Stepper (`orb_vm_step`):
  `op`: `0 = spawn_admit`, `1 = reap_check`.
  - For `op == 0 (spawn_admit)`: admits (`1`) iff `sizeRank ≤ maxSizeRank`, `activeCount < maxConcurrent`,
    `spentPlusNewCents ≤ dailyCapCents`, `ttlMinutes ≥ 5 && ttlMinutes ≤ maxTtlMinutes`,
    `jobMemPct ≤ 90`, and `secretProjected == 0` (managed VMs are untrusted: never project secrets).
  - For `op == 1 (reap_check)`: returns `1` (reap) iff `ttlExpired == 1 || (busy == 0 && (ownerEnded == 1 || idleExpired == 1))`.
-/
@[inline, export orb_vm_step]
def vmStep
    (op sizeRank maxSizeRank secretProjected ttlExpired busy ownerEnded idleExpired : UInt8)
    (activeCount maxConcurrent ttlMinutes maxTtlMinutes jobMemPct : UInt32)
    (spentPlusNewCents dailyCapCents : UInt64) : UInt8 :=
  if op == 0 then
    if sizeRank ≤ maxSizeRank && activeCount < maxConcurrent &&
       spentPlusNewCents ≤ dailyCapCents && ttlMinutes ≥ 5 &&
       ttlMinutes ≤ maxTtlMinutes && jobMemPct ≤ 90 && secretProjected == 0 then 1 else 0
  else
    if ttlExpired == 1 || (busy == 0 && (ownerEnded == 1 || idleExpired == 1)) then 1 else 0

/--
  Unboxed C-ABI Pre-Grant Mission-Access Non-Disclosure & Read-Only Gate (`orb_access_step`):
  Packs `(allowTool : UInt8, discloseTitle : UInt8, alreadyInScope : UInt8)` into a 32-bit word:
  `bit 0 = allowTool`, `bit 8 = discloseTitle`, `bit 16 = alreadyInScope`.
  - In-scope targets (`sameOwner == 1 && (isSelfOrChild == 1)`) allow read tools (`isReadTool == 1`) or self access.
  - Cross-mission access (`isSelfOrChild == 0`) is strictly read-only (`isReadTool == 1`), requires a live
    approved grant (`sameOwner == 1 && grantApproved == 1 && grantUnexpired == 1`), and never discloses
    `target_title` (`discloseTitle == 0`) before a live grant exists (regardless of whether `targetExists` is 0 or 1).
-/
@[inline, export orb_access_step]
def accessStep
    (sameOwner isSelfOrChild isReadTool grantApproved grantUnexpired _targetExists : UInt8) : UInt32 :=
  if sameOwner == 1 && isSelfOrChild == 1 then
    65793
  else if sameOwner == 1 && grantApproved == 1 && grantUnexpired == 1 then
    let allow : UInt32 := if isReadTool == 1 then 1 else 0
    allow ||| 256
  else
    0

/--
  Unboxed C-ABI Cross-Client Work-Fold & Narration Classification Stepper (`orb_workfold_step`):
  `itemKind`: `0 = user`, `1 = think`, `2 = text`, `3 = work_tool`, `4 = standalone_tool`, `5 = other`.
  Packs `(foldItem : UInt8, foldHasToolNext : UInt8)` into a 32-bit word:
  `bit 0 = foldItem`, `bit 8 = foldHasToolNext`.
  - A `text` item (`itemKind == 2`) folds into the work group (`foldItem == 1`) iff
    `isCumulative == 0 && isNonEmpty == 1 && toolAhead == 1 && (foldHasTool == 1 || nextIsTool == 1)`.
  - Text after the turn's last work tool (`toolAhead == 0`) or cumulative text (`isCumulative == 1`)
    never folds (`foldItem == 0`).
-/
@[inline, export orb_workfold_step]
def workfoldStep
    (itemKind isCumulative isNonEmpty toolAhead nextIsTool foldHasTool : UInt8) : UInt32 :=
  if itemKind == 3 then
    257
  else if itemKind == 1 then
    if foldHasTool == 1 then 257 else 1
  else if itemKind == 2 then
    if isCumulative == 0 && isNonEmpty == 1 && toolAhead == 1 &&
       (foldHasTool == 1 || nextIsTool == 1) then
      if foldHasTool == 1 then 257 else 1
    else
      0
  else
    0

/--
  Unboxed C-ABI Cross-Client Tasks-Card State Stepper (`orb_taskcard_step`):
  Returns card state: `0 = live`, `1 = done`, `2 = stale`, `3 = stopped`.
  - While the turn is running (`turnEnded == 0`), returns `0 (live)`.
  - Once ended (`turnEnded == 1`), if `allClosed == 1` returns `1 (done)`;
    else if `turnOutcomeFinished == 1` returns `2 (stale)`; else returns `3 (stopped)`.
-/
@[inline, export orb_taskcard_step]
def taskcardStep (turnEnded allClosed turnOutcomeFinished : UInt8) : UInt8 :=
  if turnEnded == 0 then 0
  else if allClosed == 1 then 1
  else if turnOutcomeFinished == 1 then 2
  else 3

/--
  Unboxed C-ABI Cross-Client Sidebar Hierarchy Visibility Stepper (`orb_sidebar_visibility`):
  Packs `(retainInMainTree : UInt8, showInArchiveOnly : UInt8, isCycleSafeChild : UInt8)` into a 32-bit word:
  `bit 0 = retainInMainTree`, `bit 8 = showInArchiveOnly`, `bit 16 = isCycleSafeChild`.
  - A mission is retained in the main tree (`bit 0`) iff `matchesFilter == 1 || hasVisibleDescendant == 1`.
  - An archived mission (`isAcknowledged == 1`) appears in archive-only rows (`bit 8`) iff it is NOT retained in the main tree.
  - A child link is cycle-safe (`bit 16`) iff `hasParent == 1 && isFork == 0 && parentReachesSelf == 0`.
-/
@[inline, export orb_sidebar_visibility]
def sidebarVisibility
    (matchesFilter hasVisibleDescendant isAcknowledged hasParent isFork parentReachesSelf : UInt8) : UInt32 :=
  let retain : UInt32 := if matchesFilter == 1 || hasVisibleDescendant == 1 then 1 else 0
  let archiveOnly : UInt32 := if isAcknowledged == 1 && retain == 0 then 256 else 0
  let cycleSafe : UInt32 := if hasParent == 1 && isFork == 0 && parentReachesSelf == 0 then 65536 else 0
  retain ||| archiveOnly ||| cycleSafe

/--
  Unboxed C-ABI Dispatch Admission, Quiescence & Disk Budget Gate (`orb_admission_step`):
  Packs `(admit : UInt8, rollbackRequired : UInt8, fenceBoth : UInt8)` into a 32-bit word:
  `bit 0 = admit`, `bit 8 = rollbackRequired`, `bit 16 = fenceBoth`.
  - If `recoveryPhase == 1` (`"rejected"` or `"preparing"`): returns `256` (`rollbackRequired == 1`).
  - If `recoveryPhase == 2` (ambiguous/unknown crash state or legacy non-quiescent retag): returns `65536` (`fenceBoth == 1`).
  - If `recoveryPhase == 0` (live dispatch admission): admits (`1`) iff `isQuiescent == 1 && reservedTagForged == 0 && emergencyPlusCandBytes ≤ freeDiskBytes`.
-/
@[inline, export orb_admission_step]
def admissionStep
    (recoveryPhase isQuiescent reservedTagForged : UInt8)
    (emergencyPlusCandBytes freeDiskBytes : UInt64) : UInt32 :=
  if recoveryPhase == 1 then
    256
  else if recoveryPhase == 2 then
    65536
  else if isQuiescent == 1 && reservedTagForged == 0 && emergencyPlusCandBytes ≤ freeDiskBytes then
    1
  else
    0

/--
  Unboxed C-ABI Account Circuit-Breaker Exponential Cooldown Calculator (`orb_account_cooldown_secs`):
  Computes `min(max(baseSecs, maxSecs), baseSecs * 2^(min(max(consecutive, 1) - 1, 20)))`
  with saturating 64-bit arithmetic and floor `≥ 1`.
-/
@[inline, export orb_account_cooldown_secs]
def accountCooldownSecs (baseSecs maxSecs : UInt64) (consecutive : UInt32) : UInt64 :=
  let effBase := if baseSecs ≥ 1 then baseSecs else 600
  let effMax := if maxSecs > effBase then maxSecs else effBase
  let rawExp := if consecutive > 1 then consecutive - 1 else 0
  let exp : UInt64 := (if rawExp > 20 then 20 else rawExp).toUInt64
  let factor : UInt64 := (1 : UInt64) <<< exp
  if effBase > effMax / factor then effMax else effBase * factor

/--
  Unboxed C-ABI Integer Token Pricing & Cents Rounding Kernel (`orb_cost_cents_step`):
  Computes rounded cents from token counts and nanodollar-per-token rates without floating-point drift:
  - Regular input tokens saturate at `inputTokens - min(inputTokens, cacheCreateTokens)`
  - Rounds nearest cent via `(totalNano + 5_000_000) / 10_000_000`.
-/
@[inline, export orb_cost_cents_step]
def costCentsStep
    (inputTokens outputTokens cacheCreateTokens cacheReadTokens : UInt64)
    (inputNano outputNano cacheCreateNano cacheReadNano : UInt64) : UInt64 :=
  let regInput := if inputTokens ≥ cacheCreateTokens then inputTokens - cacheCreateTokens else 0
  let totalNano :=
    regInput * inputNano +
    outputTokens * outputNano +
    cacheCreateTokens * cacheCreateNano +
    cacheReadTokens * cacheReadNano
  (totalNano + 5000000) / 10000000

/--
  Unboxed C-ABI Stream Repetition & Loop Detector Gate (`orb_stream_loop_step`):
  Returns verdict: `0 = clear`, `1 = repeated`, `2 = inconclusive`.
  - If `cancelledOrTimedOut == 1 || minLen > 256 || comparisons > comparisonBudget`: returns `2 (inconclusive)`.
  - Else if `minLen == 0 || repeats < 2 || windowLen < minLen * repeats`: returns `0 (clear)`.
  - Else if `hashCollision == 1`: returns `2 (inconclusive)`.
  - Else if `nonOverlappingCount ≥ repeats && distinctWords4Plus ≥ 2`: returns `1 (repeated)`.
  - Otherwise returns `0 (clear)`.
-/
@[inline, export orb_stream_loop_step]
def streamLoopStep
    (cancelledOrTimedOut hashCollision : UInt8)
    (windowLen minLen repeats nonOverlappingCount distinctWords4Plus : UInt32)
    (comparisons comparisonBudget : UInt64) : UInt8 :=
  if cancelledOrTimedOut == 1 || minLen > 256 || comparisons > comparisonBudget then 2
  else if minLen == 0 || repeats < 2 || windowLen < minLen * repeats then 0
  else if hashCollision == 1 then 2
  else if nonOverlappingCount ≥ repeats && distinctWords4Plus ≥ 2 then 1
  else 0

/--
  Unboxed C-ABI Remote Build Wait-Lease & Terminal Wake Supersession Stepper (`orb_job_ledger_step`):
  Packs `(retainWaitHandle : UInt8, wakeDisposition : UInt8)` into a 32-bit word:
  `bit 0 = retainWaitHandle`, `bits 8..15 = wakeDisposition (0 = ready, 1 = deferred, 2 = superseded)`.
  - Wait handle is retained (`bit 0 == 1`) iff `isAcceptedRemoteBuild == 1 && expectsContinuation == 1 && newerTerminalExists == 0 && newerAmbiguousTentative == 0`.
  - Wake disposition is `2 (superseded)` when `newerTerminalExists == 1`, else `1 (deferred)` when `newerAmbiguousTentative == 1`, else `0 (ready)`.
-/
@[inline, export orb_job_ledger_step]
def jobLedgerStep
    (isAcceptedRemoteBuild expectsContinuation newerTerminalExists newerAmbiguousTentative : UInt8) : UInt32 :=
  let disp : UInt32 :=
    if newerTerminalExists == 1 then 512
    else if newerAmbiguousTentative == 1 then 256
    else 0
  let retain : UInt32 :=
    if isAcceptedRemoteBuild == 1 && expectsContinuation == 1 && disp == 0 then 1 else 0
  retain ||| disp

/--
  Unboxed C-ABI Linux `/proc/<pid>/stat` Liveness & Start-Ticks Gate (`orb_proc_liveness_step`):
  Returns liveness verdict: `0 = dead`, `1 = alive`, `2 = inconclusive_alive`.
  - If `procMissing == 1`: returns `0 (dead)`.
  - If `procReadError == 1`: returns `2 (inconclusive_alive)` (never reap on transient procfs read error).
  - If `isZombieOrDeadState == 1 || fieldsAfterComm < 20`: returns `0 (dead)`.
  - If `hasExpectedTicks == 1 && actualStartTicks != expectedStartTicks`: returns `0 (dead)` (PID reused).
  - Otherwise returns `1 (alive)`.
-/
@[inline, export orb_proc_liveness_step]
def procLivenessStep
    (procMissing procReadError isZombieOrDeadState hasExpectedTicks : UInt8)
    (fieldsAfterComm : UInt32)
    (expectedStartTicks actualStartTicks : UInt64) : UInt8 :=
  if procMissing == 1 then 0
  else if procReadError == 1 then 2
  else if isZombieOrDeadState == 1 || fieldsAfterComm < 20 then 0
  else if hasExpectedTicks == 1 && actualStartTicks != expectedStartTicks then 0
  else 1

/--
  Unboxed C-ABI GitHub PR Gate Recommendation Stepper (`orb_pr_gate_step`):
  Returns recommendation code:
  `0 = already_merged`, `1 = wait_for_ready_for_review`, `2 = closed_without_merge`,
  `3 = head_changed_since_worker`, `4 = action_required_external`, `5 = blocked_by_policy`,
  `6 = needs_update_with_base`, `7 = needs_conflict_resolution`,
  `8 = ready_for_review_or_merge`, `9 = needs_checks_or_review`.
-/
@[inline, export orb_pr_gate_step]
def prGateStep
    (merged draft closed exactHead actionRequired blocked behind conflicting checksGreen workflowsGreen : UInt8) : UInt8 :=
  if merged == 1 then 0
  else if draft == 1 then 1
  else if closed == 1 then 2
  else if exactHead == 0 then 3
  else if actionRequired == 1 then 4
  else if blocked == 1 then 5
  else if behind == 1 then 6
  else if conflicting == 1 then 7
  else if checksGreen == 1 && workflowsGreen == 1 then 8
  else 9

/--
  Unboxed C-ABI Cross-Client Turn Summary & Task Status Stepper (`orb_turn_summary_step`):
  `rawStatus`: `0 = pending`, `1 = in_progress`, `2 = completed`, `3 = cancelled`.
  Packs `(normalizedStatus : UInt8, isDone : UInt8, isActive : UInt8, cardState : UInt8)` into a 32-bit word:
  `bits 0..7 = normalizedStatus`, `bit 8 = isDone`, `bit 16 = isActive`,
  `bits 24..31 = cardState (0 = live, 1 = done, 2 = stale, 3 = stopped)`.
  - While the turn is running (`turnEnded == 0`), `normalizedStatus = rawStatus`.
  - Once ended (`turnEnded == 1`), `in_progress (1)` settles to `pending (0)` (`clear_in_progress`),
    and `cardState` follows `taskcardStep turnEnded allClosed turnOutcomeFinished`.
-/
@[inline, export orb_turn_summary_step]
def turnSummaryStep (rawStatus turnEnded allClosed turnOutcomeFinished : UInt8) : UInt32 :=
  let norm : UInt8 :=
    if rawStatus == 2 then 2
    else if rawStatus == 3 then 3
    else if rawStatus == 1 && turnEnded == 0 then 1
    else 0
  let done : UInt32 := if norm == 2 then 256 else 0
  let active : UInt32 := if norm == 1 then 65536 else 0
  let card : UInt32 := (taskcardStep turnEnded allClosed turnOutcomeFinished).toUInt32 <<< 24
  norm.toUInt32 ||| done ||| active ||| card

/--
  Unboxed C-ABI Anthropic Unified Rate-Limit Status Stepper (`orb_usage_limit_status`):
  `statusKind`: `0 = allowed/ok/missing`, `1 = allowed_warning`, `2 = rejected`, `3 = other`.
  `claimKind`: `0 = none/other`, `1 = five_hour`, `2 = seven_day`, `3 = seven_day_opus`, `4 = seven_day_sonnet`.
  Packs `(tone : UInt8, windowKind : UInt8, showPct : UInt8, pct : UInt8, resetUnit : UInt8, resetValue : UInt32)` into a 64-bit word:
  - `bits 0..7`: `tone` (`0 = hidden/null`, `1 = warning`, `2 = error`, `3 = unknown_warning`)
  - `bits 8..15`: `windowKind` (`0..4` for `allowed_warning`, `0` otherwise)
  - `bits 16..23`: `showPct` (`1` iff `allowed_warning`, `claimKind ∈ {1, 2}`, `hasUtilization == 1`, and `utilizationPct ≤ 100`)
  - `bits 24..31`: `pct` (`0..100`)
  - `bits 32..39`: `resetUnit` (`0 = none`, `1 = minutes ("m")`, `2 = hours ("h")`, `3 = days ("d")`)
  - `bits 40..63`: `resetValue` (`max(1, rem/60)` for `< 3600s`, `rem/3600` for `< 172800s (48h)`, `rem/86400` for `≥ 172800s`).
-/
@[inline, export orb_usage_limit_status]
def usageLimitStatus
    (statusKind claimKind hasUtilization utilizationPct hasReset : UInt8)
    (resetRemSecs : UInt64) : UInt64 :=
  if statusKind == 0 then 0
  else if statusKind == 1 then
    let win : UInt64 := if claimKind ≥ 1 && claimKind ≤ 4 then claimKind.toUInt64 <<< 8 else 0
    let showPct : UInt64 :=
      if (claimKind == 1 || claimKind == 2) && hasUtilization == 1 && utilizationPct ≤ 100 then 65536 else 0
    let pct : UInt64 := if showPct != 0 then utilizationPct.toUInt64 <<< 24 else 0
    (1 : UInt64) ||| win ||| showPct ||| pct
  else if statusKind == 2 then
    if hasReset == 1 && resetRemSecs > 0 then
      let mins := resetRemSecs / 60
      let hrs := resetRemSecs / 3600
      let days := resetRemSecs / 86400
      let unit : UInt64 := if mins < 60 then 1 else if hrs < 48 then 2 else 3
      let val : UInt64 :=
        if mins < 60 then (if mins ≥ 1 then mins else 1)
        else if hrs < 48 then hrs
        else days
      let clampedVal : UInt64 := if val > 0xFFFFFF then 0xFFFFFF else val
      (2 : UInt64) ||| (unit <<< 32) ||| (clampedVal <<< 40)
    else 2
  else 3

/--
  Unboxed C-ABI Cross-Client Compact Relative-Time Classifier (`orb_relative_time_bucket`):
  Matches `shared/orb-spec/fixtures/relative-time.json`:
  Packs `(unit : UInt8, value : UInt32)` into a 64-bit word (`bits 0..7 = unit`, `bits 8..39 = value`):
  - `elapsedSecs < 45` -> `unit = 0 ("now"), value = 0`
  - `elapsedSecs < 3600` -> `unit = 1 ("m"), value = max(1, elapsedSecs / 60)` (never `"0m"` at 45..59s)
  - `elapsedSecs < 86400` -> `unit = 2 ("h"), value = elapsedSecs / 3600`
  - `elapsedSecs < 604800` -> `unit = 3 ("d"), value = elapsedSecs / 86400`
  - `elapsedSecs ≥ 604800` -> `unit = 4 ("w"), value = elapsedSecs / 604800`.
-/
@[inline, export orb_relative_time_bucket]
def relativeTimeBucket (elapsedSecs : UInt64) : UInt64 :=
  if elapsedSecs < 45 then 0
  else if elapsedSecs < 3600 then
    let mins := elapsedSecs / 60
    let v := if mins ≥ 1 then mins else 1
    (1 : UInt64) ||| (v <<< 8)
  else if elapsedSecs < 86400 then
    (2 : UInt64) ||| ((elapsedSecs / 3600) <<< 8)
  else if elapsedSecs < 604800 then
    (3 : UInt64) ||| ((elapsedSecs / 86400) <<< 8)
  else
    let wks := elapsedSecs / 604800
    let clamped := if wks > 0xFFFFFFFF then 0xFFFFFFFF else wks
    (4 : UInt64) ||| (clamped <<< 8)

/-- Saturating `UInt32` addition: `a + b` when it fits, `0xFFFFFFFF` otherwise (never wraps). -/
@[inline] def satAdd32 (a b : UInt32) : UInt32 := if a ≤ 0xFFFFFFFF - b then a + b else 0xFFFFFFFF

/--
  Unboxed C-ABI Incremental SSE Transcript Patch Stepper (`orb_transcript_patch_step`):
  `eventKind`:
  `0 = message_delta` (append `deltaLen` to live buffer, saturating at `0xFFFFFFFF`),
  `1 = assistant_snapshot` (replace live buffer with `deltaLen` when `deltaLen > 0`, else keep `stateLen`),
  `2 = turn_boundary` (reset live buffer to `0` on user message or turn boundary).
  Any other `eventKind` returns the packed input state unchanged.
  Packs `(nextLen : UInt32, nextSeq : UInt32)` into a 64-bit word (`bits 0..31 = nextLen`, `bits 32..63 = nextSeq`);
  `nextSeq` saturates at `0xFFFFFFFF` (theorem `transcript_patch_step_monotone_absorbing`).
-/
@[inline, export orb_transcript_patch_step]
def transcriptPatchStep (stateLen stateSeq : UInt32) (eventKind : UInt8) (deltaLen : UInt32) : UInt64 :=
  if eventKind ≤ 2 then
    let nextLen : UInt32 :=
      if eventKind == 2 then 0
      else if eventKind == 1 then (if deltaLen > 0 then deltaLen else stateLen)
      else satAdd32 stateLen deltaLen
    nextLen.toUInt64 ||| ((satAdd32 stateSeq 1).toUInt64 <<< 32)
  else stateLen.toUInt64 ||| (stateSeq.toUInt64 <<< 32)

/--
  Usage attribution scope (`orb_attribution_step`). Caller kinds:
  `0 = unknown`, `1 = mission`, `2 = subagent`, `3 = hermes`, `4 = orb_ui`, `5 = core`, `6 = script`.
  `principalKind` is derived server-side from the authenticated credential (out-of-range = `unknown`);
  `claimedKind` is the client hint (`0 = no claim`). A claim is in scope iff it is empty, or
  - the principal is `core` (internal proxy secret) and claims `mission`, `subagent` or `core`;
  - the principal is a mission key (`1`/`2`) and claims its own mission (`sameMission == 1`)
    or a subagent descending from it (`isDescendant == 1`);
  - the principal is `hermes`, `orb_ui` or `script` and claims exactly its own kind.
-/
@[inline] def attributionInScope (principalKind claimedKind sameMission isDescendant : UInt8) : Bool :=
  if claimedKind == 0 then true
  else if principalKind == 5 then
    if claimedKind == 1 then true
    else if claimedKind == 2 then true
    else claimedKind == 5
  else if principalKind == 1 then
    if claimedKind == 1 then sameMission == 1
    else if claimedKind == 2 then isDescendant == 1
    else false
  else if principalKind == 2 then
    if claimedKind == 1 then sameMission == 1
    else if claimedKind == 2 then isDescendant == 1
    else false
  else if principalKind == 3 then claimedKind == 3
  else if principalKind == 4 then claimedKind == 4
  else if principalKind == 6 then claimedKind == 6
  else false

/-- Principal kind clamped to the closed enum (`> 6` is `unknown`). -/
@[inline] def attributionPrincipal (principalKind : UInt8) : UInt8 :=
  if principalKind ≤ 6 then principalKind else 0

/-- Final caller kind: the claim when in scope (and non-empty), the principal's own kind otherwise. -/
@[inline] def attributionKind (principalKind claimedKind sameMission isDescendant : UInt8) : UInt8 :=
  let p := attributionPrincipal principalKind
  if attributionInScope p claimedKind sameMission isDescendant then
    (if claimedKind == 0 then p else claimedKind)
  else p

/--
  Unboxed C-ABI Usage Attribution Stepper (`orb_attribution_step`):
  packs `bits 0..7 = caller kind` (`attributionKind`) and `bit 8 = claim accepted`.
  A rejected (forged or out-of-scope) claim keeps the principal's own kind, so the caller is
  never empty and `unknown` is returned only when no credential binding exists.
-/
@[inline, export orb_attribution_step]
def attributionStep (principalKind claimedKind sameMission isDescendant : UInt8) : UInt32 :=
  let p := attributionPrincipal principalKind
  if attributionInScope p claimedKind sameMission isDescendant then
    (if claimedKind == 0 then p else claimedKind).toUInt32 ||| 256
  else p.toUInt32

/--
  Native recurring schedule step (`orb_schedule_step`, `docs/specs/agent-schedules.md`).
  A schedule is keyed by `hash(mission, cron, prompt)`. `op`: `0 = register`, `1 = tick`.
  Flags are `0/1`: `known` (a row with the same key exists, active or cancelled),
  `cancelled` (the row was cancelled or its mission stopped), `ownerTerminal` (the owning
  mission is gone), `authorized` (the caller owns the mission), `busy` (the mission is mid-turn).
  `lastFired` is the reference of the last fire (or registration); `nextDue` is the first cron
  slot strictly after it; `now` is the scheduler clock.
  Actions: `0 = drop`, `1 = register`, `2 = dedupe`, `3 = fire`, `4 = wait`.
-/
@[inline] def scheduleAction (op known cancelled ownerTerminal authorized busy : UInt8)
    (lastFired nextDue now : UInt64) : UInt8 :=
  if authorized != 1 then 0
  else if op == 0 then (if known == 1 then 2 else if ownerTerminal == 1 then 0 else 1)
  else if cancelled == 1 || ownerTerminal == 1 then 0
  else if lastFired < nextDue && nextDue ≤ now && busy != 1 then 3
  else 4

/-- Reference after a step: a fire moves it to `now`, never to the (possibly long past) slot,
    so downtime collapses every missed slot into a single fire. -/
@[inline] def scheduleNextRef (action : UInt8) (lastFired now : UInt64) : UInt64 :=
  if action == 3 then now else lastFired

/-- Unboxed C-ABI Schedule Stepper (`orb_schedule_step`): returns `scheduleAction`. -/
@[inline, export orb_schedule_step]
def scheduleStep (op known cancelled ownerTerminal authorized busy : UInt8)
    (lastFired nextDue now : UInt64) : UInt8 :=
  scheduleAction op known cancelled ownerTerminal authorized busy lastFired nextDue now

/--
  Spend statistics settle step (`orb_stats_settle_step`): add one priced request's cost to a running
  total exactly once. `seen == 1` means the request id is already in the ledger (a replay), which adds
  nothing. Saturating at `UInt64.max`, so a total never wraps. Statistics only: the planned
  `budget_reserve` / `chain_pick` enforcement steps will reuse it (see `docs/specs/mission-stats.md`).
-/
@[inline] def statsSettle (acc cost : UInt64) (seen : UInt8) : UInt64 :=
  if seen == 1 then acc
  else if acc ≤ 18446744073709551615 - cost then acc + cost
  else 18446744073709551615

/-- Unboxed C-ABI Stats Settle Stepper (`orb_stats_settle_step`). -/
@[inline, export orb_stats_settle_step]
def statsSettleStep (acc cost : UInt64) (seen : UInt8) : UInt64 :=
  statsSettle acc cost seen

/--
  Unboxed C-ABI Biometric JIT Privilege Broker & Session-Scoped Root Stepper (`orb_privilege_step`):
  Packs `(allowExec : UInt8, requireForceCmd : UInt8, reapGrant : UInt8)` into a 32-bit word:
  `bit 0 = allowExec`, `bit 8 = requireForceCmd`, `bit 16 = reapGrant`.
  - `scopeRank`: `0 = ops_read`, `1 = service_deploy`, `2 = root_exec`.
  - `bunkerState`: `0 = normal`, `1 = soft_quarantine`, `2 = hard_lockdown`.
  - Admits execution (`bit 0 == 1`) iff `sameOwner == 1`, `missionActive == 1`,
    `biometricSigned == 1`, `revoked == 0`, `bunkerState == 0`, `scopeRank ≤ maxGrantedScope`,
    `nowEpoch < grantExpiresAt`, and `nowEpoch < sessionExpiresAt`.
  - Sets `requireForceCmd` (`bit 8 == 1`) whenever execution is admitted with `scopeRank < 2`.
  - Sets `reapGrant` (`bit 16 == 1`) whenever `missionActive == 0 || revoked == 1 ||
    bunkerState != 0 || grantExpiresAt ≤ nowEpoch || sessionExpiresAt ≤ nowEpoch`.
-/
@[inline, export orb_privilege_step]
def privilegeStep
    (sameOwner missionActive biometricSigned scopeRank maxGrantedScope bunkerState revoked : UInt8)
    (nowEpoch grantExpiresAt sessionExpiresAt : UInt64) : UInt32 :=
  if missionActive == 0 || revoked == 1 || bunkerState != 0 ||
     grantExpiresAt ≤ nowEpoch || sessionExpiresAt ≤ nowEpoch then
    65536
  else if sameOwner == 1 && biometricSigned == 1 && scopeRank ≤ maxGrantedScope then
    if scopeRank < 2 then 257 else 1
  else
    0

/--
  Unboxed C-ABI Bunker Mode & Canary Tripwire Fence Stepper (`orb_bunker_step`):
  `currentState`: `0 = normal`, `1 = soft_quarantine`, `2 = hard_lockdown`.
  Packs `bits 0..7 = nextState`, `bit 8 = revokeAllJitGrants`, `bit 16 = isolateNodeMesh`.
  - Any `canaryTripped == 1` or `manualTrigger == 2` transitions immediately to `2 (hard_lockdown)`.
  - `authFailureBurst == 1` or `manualTrigger == 1` transitions at least to `1 (soft_quarantine)`.
  - Once `currentState ≥ 1`, the system never returns to `0` unless `biometricUnbunker == 1`
    and `canaryTripped == 0` (`StickyFence`).
-/
@[inline, export orb_bunker_step]
def bunkerStep
    (currentState canaryTripped authFailureBurst manualTrigger biometricUnbunker : UInt8) : UInt32 :=
  let clamped : UInt8 := if currentState ≤ 2 then currentState else 2
  let next : UInt8 :=
    if canaryTripped == 1 || manualTrigger == 2 then 2
    else if clamped == 2 then (if biometricUnbunker == 1 then 0 else 2)
    else if authFailureBurst == 1 || manualTrigger == 1 then 1
    else if clamped == 1 then (if biometricUnbunker == 1 then 0 else 1)
    else 0
  next.toUInt32 |||
    (if next ≥ 1 then 256 else 0) |||
    (if next == 2 then 65536 else 0)

/--
  Unboxed C-ABI Guarded Production Deploy Gate (`orb_deploy_gate_step`):
  - Dev/staging deploys (`isProdService == 0`) require `serviceMatches == 1 && callingOnSelf == 0 &&
    debounceOk == 1 && (liveWriters == 0 || forceFlag == 1) && bunkerState == 0`.
  - Production deploys (`isProdService == 1`) additionally require `biometricApproved == 1`
    (satisfied by an active session-scoped `service_deploy` grant or direct `X-Paloma-Approval`).
-/
@[inline, export orb_deploy_gate_step]
def deployGateStep
    (isProdService serviceMatches callingOnSelf debounceOk forceFlag biometricApproved bunkerState : UInt8)
    (liveWriters : UInt32) : UInt8 :=
  let baseOk := serviceMatches == 1 && callingOnSelf == 0 && debounceOk == 1 &&
                (liveWriters == 0 || forceFlag == 1) && bunkerState == 0
  if isProdService == 1 then
    if baseOk && biometricApproved == 1 then 1 else 0
  else
    if baseOk then 1 else 0

/-! ## Wave 7: Cross-Platform Mobile Kernel (`Orb.Scroll`, `Orb.Stream` & Domain State Machines) -/

/--
  Unboxed C-ABI Scroll Maximum Top (`orb_scroll_max_top`):
  Largest valid scroll offset (`content - viewport` saturating at `0`).
-/
@[inline, export orb_scroll_max_top]
def scrollMaxTop (content viewport : UInt64) : UInt64 :=
  if viewport ≤ content then content - viewport else 0

/--
  Unboxed C-ABI Scroll Clamp Top (`orb_scroll_clamp_top`):
  `top` clamped to `[0, scrollMaxTop content viewport]`.
-/
@[inline, export orb_scroll_clamp_top]
def scrollClampTop (content viewport top : UInt64) : UInt64 :=
  let mx := scrollMaxTop content viewport
  if top ≤ mx then top else mx

/--
  Unboxed C-ABI Scroll Gap From Bottom (`orb_scroll_gap`):
  Pixels between the viewport bottom and content bottom (`scrollMaxTop - scrollClampTop`).
-/
@[inline, export orb_scroll_gap]
def scrollGap (content viewport top : UInt64) : UInt64 :=
  let mx := scrollMaxTop content viewport
  let cl := scrollClampTop content viewport top
  if cl ≤ mx then mx - cl else 0

/--
  Unboxed C-ABI Scroll Layout Step (`orb_scroll_layout_step`):
  Content or viewport resize (streaming delta, tool card, keyboard):
  never modifies `pinned`; returns `scrollMaxTop` when `pinned == 1`, else `scrollClampTop`.
-/
@[inline, export orb_scroll_layout_step]
def scrollLayoutStep (pinned : UInt8) (content viewport top : UInt64) : UInt64 :=
  if pinned == 1 then scrollMaxTop content viewport else scrollClampTop content viewport top

/--
  Unboxed C-ABI Scroll User Step (`orb_scroll_user_step`):
  User scroll gesture: returns the new `pinned : UInt8` (`1` iff `scrollGap content viewport top ≤ threshold`).
-/
@[inline, export orb_scroll_user_step]
def scrollUserStep (content viewport top threshold : UInt64) : UInt8 :=
  if scrollGap content viewport top ≤ threshold then 1 else 0

/--
  Unboxed C-ABI Scroll Jump To Bottom Step (`orb_scroll_jump_step`):
  Explicit jump-to-bottom or send: returns `scrollMaxTop content viewport` (and pins to `1`).
-/
@[inline, export orb_scroll_jump_step]
def scrollJumpStep (content viewport : UInt64) : UInt64 :=
  scrollMaxTop content viewport

/--
  Unboxed C-ABI Scroll Post-Render Correction (`orb_scroll_correct`):
  One correction after DOM/layout render: pulls to `scrollMaxTop` if `pinned == 1`, else clamps `top`.
-/
@[inline, export orb_scroll_correct]
def scrollCorrect (pinned : UInt8) (content viewport top : UInt64) : UInt64 :=
  if pinned == 1 then scrollMaxTop content viewport else scrollClampTop content viewport top

/--
  Unboxed C-ABI Scroll Jump Pill Visibility (`orb_scroll_shows_jump`):
  Returns `1` iff `pinned == 0`, content is scrollable (`viewport + 24 < content`),
  and `pillThreshold < scrollGap content viewport top`.
-/
@[inline, export orb_scroll_shows_jump]
def scrollShowsJump (pinned : UInt8) (content viewport top pillThreshold : UInt64) : UInt8 :=
  if pinned == 0 && viewport ≤ 18446744073709551591 && viewport + 24 < content &&
     pillThreshold < scrollGap content viewport top then 1 else 0

/--
  Unboxed C-ABI Stream Coalescer Step (`orb_stream_coalescer_step`):
  `op`: `0 = append`, `1 = frame/flush`, `2 = clear`.
  Packs `bits 0..31 = nextShownLen : UInt32`, `bits 32..62 = nextPendingLen : UInt32` (31-bit),
  `bit 63 = didRender : UInt8` (`1` iff `op == 1 && pendingLen > 0`).
-/
@[inline, export orb_stream_coalescer_step]
def streamCoalescerStep (op : UInt8) (shownLen pendingLen deltaLen : UInt32) : UInt64 :=
  if op == 0 then
    let nextP := satAdd32 pendingLen deltaLen
    shownLen.toUInt64 ||| ((nextP.toUInt64 &&& 2147483647) <<< 32)
  else if op == 1 then
    if pendingLen == 0 then
      shownLen.toUInt64
    else
      let nextS := satAdd32 shownLen pendingLen
      nextS.toUInt64 ||| ((1 : UInt64) <<< 63)
  else
    0

@[inline] def streamNextFenceKind
    (openKind : UInt8) (openCount : UInt32) (markerKind : UInt8) (markerCount : UInt32) : UInt8 :=
  if openKind == 0 then
    if (markerKind == 1 || markerKind == 2) && 3 ≤ markerCount then markerKind else 0
  else
    if markerKind == openKind && openCount ≤ markerCount && 3 ≤ markerCount then 0 else openKind

@[inline] def streamNextFenceCount
    (openKind : UInt8) (openCount : UInt32) (markerKind : UInt8) (markerCount : UInt32) : UInt32 :=
  if openKind == 0 then
    if (markerKind == 1 || markerKind == 2) && 3 ≤ markerCount then markerCount else 0
  else
    if markerKind == openKind && openCount ≤ markerCount && 3 ≤ markerCount then 0 else openCount

/--
  Unboxed C-ABI Stream Fence Step (`orb_stream_fence_step`):
  `openKind / markerKind`: `0 = none`, `1 = backtick`, `2 = tilde`.
  Packs `bits 0..7 = nextFenceKind : UInt8`, `bits 32..63 = nextFenceCount : UInt32`.
-/
@[inline, export orb_stream_fence_step]
def streamFenceStep
    (openKind : UInt8) (openCount : UInt32) (markerKind : UInt8) (markerCount : UInt32) : UInt64 :=
  let nk := streamNextFenceKind openKind openCount markerKind markerCount
  let nc := streamNextFenceCount openKind openCount markerKind markerCount
  nk.toUInt64 ||| (nc.toUInt64 <<< 32)

/--
  Unboxed C-ABI Stream Commit Prefix Scanner Step (`orb_stream_commit_step`):
  Advances one newline-terminated line of `OrbStreamCommit`:
  - `nextTick = if lineTick == 1 then (1 - tick) else tick`
  - `(nextFenceKind, nextFenceCount)` via `streamNextFenceKind` / `streamNextFenceCount`
  - `commits = lineBlank == 1 && nextTick == 0 && nextFenceKind == 0`
  - `nextPos = satAdd32 pos 1`, `nextCommit = if commits then nextPos else commit`
  Packs `bit 0 = nextTick`, `bits 8..15 = nextFenceKind`, `bit 16 = commits`, `bits 32..63 = nextCommit`.
-/
@[inline, export orb_stream_commit_step]
def streamCommitStep
    (tick openKind : UInt8) (openCount : UInt32)
    (lineBlank lineTick markerKind : UInt8) (markerCount pos commit : UInt32) : UInt64 :=
  let nextTick : UInt8 := if lineTick == 1 then (if tick == 1 then 0 else 1) else (if tick == 1 then 1 else 0)
  let nextFenceKind := streamNextFenceKind openKind openCount markerKind markerCount
  let nextPos := satAdd32 pos 1
  let commits : UInt8 := if lineBlank == 1 && nextTick == 0 && nextFenceKind == 0 then 1 else 0
  let nextCommit : UInt32 := if commits == 1 then nextPos else commit
  let nextFenceBits : UInt32 :=
    if nextFenceKind == 1 then 256 else if nextFenceKind == 2 then 512 else 0
  let commitBits : UInt32 := if commits == 1 then 65536 else 0
  let lo32 : UInt32 := nextTick.toUInt32 ||| nextFenceBits ||| commitBits
  lo32.toUInt64 ||| (nextCommit.toUInt64 <<< 32)

/--
  Unboxed C-ABI Stream Incremental Token Cost Step (`orb_stream_token_cost_step`):
  Accumulates `prevCost + newAdvance + tailBytes` with `UInt64` saturation (never wraps).
-/
@[inline, export orb_stream_token_cost_step]
def streamTokenCostStep (prevCost newAdvance tailBytes : UInt64) : UInt64 :=
  let stepCost := statsSettle newAdvance tailBytes 0
  statsSettle prevCost stepCost 0

/--
  Unboxed C-ABI Mission State Category Classifier (`orb_mission_state_classify`):
  Maps `stateId` (`0..28`, `≥ 29 = unknown`) to `MissionCategory` (`0..9`):
  - `0..8 (active..waiting_background)` -> `3 (live)`
  - `9..10 (pending, queued)` -> `4 (queued)`
  - `11..15 (awaiting_user..awaiting_approval)` -> `0 (waiting)`
  - `16 (blocked)` -> `1 (blocked)`
  - `17..21 (failed..timed_out)` -> `2 (failed)`
  - `22..23 (interrupted, cancelled)` -> `6 (stopped)`
  - `24 (paused)` -> `5 (paused)`
  - `25..26 (completed, succeeded)` -> `7 (done)`
  - `27..28 (acknowledged, archived)` -> `8 (archived)`
  - `≥ 29` -> `9 (unknown)`
-/
@[inline, export orb_mission_state_classify]
def missionStateClassify (stateId : UInt8) : UInt8 :=
  if stateId ≤ 8 then 3
  else if stateId ≤ 10 then 4
  else if stateId ≤ 15 then 0
  else if stateId == 16 then 1
  else if stateId ≤ 21 then 2
  else if stateId ≤ 23 then 6
  else if stateId == 24 then 5
  else if stateId ≤ 26 then 7
  else if stateId ≤ 28 then 8
  else 9

/--
  Unboxed C-ABI Mission Sort Rank (`orb_mission_sort_rank`):
  Inbox urgency rank (`0 = waiting` .. `8 = archived`, `9 = unknown`).
-/
@[inline, export orb_mission_sort_rank]
def missionSortRank (stateId : UInt8) : UInt8 :=
  missionStateClassify stateId

@[inline] def missionAwaitsReview (stateId : UInt8) : Bool :=
  stateId == 11 || stateId == 12 || stateId == 16 || stateId == 17 ||
  stateId == 20 || stateId == 22 || stateId == 24 || stateId == 25 || stateId == 26

@[inline] def missionCategoryFlags (cat : UInt8) : UInt32 :=
  if cat == 0 then 4
  else if cat == 1 then 36
  else if cat == 2 then 166
  else if cat == 3 || cat == 4 then 1
  else if cat == 7 then 194
  else if cat == 6 || cat == 8 then 128
  else 0

@[inline] def missionExtraBits (stateId : UInt8) : UInt32 :=
  if stateId == 11 || stateId == 12 || stateId == 24 || stateId == 25 || stateId == 26 then 8
  else if stateId == 16 || stateId == 17 || stateId == 20 || stateId == 22 then 24
  else 0

/--
  Unboxed C-ABI Mission Derived Flags (`orb_mission_flags`):
  Packs 8 flags into `UInt32`:
  - `bit 0 (1)`: `isActive / live` (`cat == 3 || cat == 4`)
  - `bit 1 (2)`: `isTerminal / terminal` (`cat == 7 || cat == 2`)
  - `bit 2 (4)`: `needsAttention` (`cat ≤ 2`)
  - `bit 3 (8)`: `awaitsReview / unreadResponse`
  - `bit 4 (16)`: `canRetry` (`stateId ∈ {16, 17, 20, 22}`)
  - `bit 5 (32)`: `isProblem` (`cat == 1 || cat == 2`)
  - `bit 6 (64)`: `isSuccess` (`cat == 7`)
  - `bit 7 (128)`: `canReopen` (`cat == 7 || cat == 2 || cat == 6 || cat == 8`)
-/
@[inline, export orb_mission_flags]
def missionFlags (stateId : UInt8) : UInt32 :=
  missionCategoryFlags (missionStateClassify stateId) ||| missionExtraBits stateId

/--
  Unboxed C-ABI Mission Inbox Section (`orb_mission_inbox_section`):
  `0 = working`, `1 = needsYou`, `2 = ready`, `3 = hidden`.
-/
@[inline, export orb_mission_inbox_section]
def missionInboxSection (stateId : UInt8) : UInt8 :=
  let cat := missionStateClassify stateId
  if cat == 3 || cat == 4 then 0
  else if cat ≤ 2 then 1
  else if cat == 7 || cat == 5 then 2
  else if cat == 6 then (if missionAwaitsReview stateId then 2 else 3)
  else 3

/--
  Unboxed C-ABI Connection Issue Classifier (`orb_connection_issue_classify`):
  Packs:
  - `bit 0`: `showIssue` (`1` iff `isUnreachable == 1`)
  - `bit 8`: `offerUseDefault` (`1` iff `isUnreachable == 1 && isUsingDefault == 0`)
  - `bit 16`: `recommendDefault` (`1` iff `isUnreachable == 1 && hasExternalProxy == 0 && isUsingDefault == 0 && isPrivateAddr == 1 && defaultReachable == 1`)
  - `bit 24`: `shouldProbeDefault` (`1` iff `isUnreachable == 1 && isUsingDefault == 0 && isPrivateAddr == 1`)
  - `bits 28..31`: `messageKind` (`0 = none`, `1 = proxy`, `2 = recommend_default`, `3 = private_lan`, `4 = default_offline`, `5 = custom_unreachable`)
-/
@[inline, export orb_connection_issue_classify]
def connectionIssueClassify
    (isUnreachable isUsingDefault isPrivateAddr defaultReachable hasExternalProxy : UInt8) : UInt32 :=
  if isUnreachable != 1 then 0
  else
    let offerDef : UInt32 := if isUsingDefault == 0 then 256 else 0
    let probeDef : UInt32 := if isUsingDefault == 0 && isPrivateAddr == 1 then 16777216 else 0
    if hasExternalProxy == 1 then
      (1 : UInt32) ||| offerDef ||| probeDef ||| ((1 : UInt32) <<< 28)
    else
      let recDef : Bool := isUsingDefault == 0 && isPrivateAddr == 1 && defaultReachable == 1
      let recBit : UInt32 := if recDef then 65536 else 0
      let msgKind : UInt32 :=
        if recDef then 2
        else if isPrivateAddr == 1 then 3
        else if isUsingDefault == 1 then 4
        else 5
      (1 : UInt32) ||| offerDef ||| recBit ||| probeDef ||| (msgKind <<< 28)

/--
  Unboxed C-ABI Worked Duration Bucket (`orb_worked_duration_bucket`):
  Mirrors `OrbTurnTiming.workedFor(seconds)`:
  - `seconds < 60`: `unit = 0 (s)`, `primary = seconds`, `secondary = 0`
  - `seconds < 3600`: `unit = 1 (m)`, `primary = seconds / 60`, `secondary = seconds % 60`
  - `seconds < 86400`: `unit = 2 (h)`, `primary = (seconds / 60) / 60`, `secondary = (seconds / 60) % 60`
  - `seconds ≥ 86400`: `unit = 3 (d)`, `primary = (seconds / 3600) / 24`, `secondary = (seconds / 3600) % 24`
  Packs `bits 0..7 = unit`, `bits 8..15 = secondary`, `bits 32..63 = primary (clamped to UInt32)`.
-/
@[inline, export orb_worked_duration_bucket]
def workedDurationBucket (seconds : UInt64) : UInt64 :=
  if seconds < 60 then
    seconds <<< 32
  else if seconds < 3600 then
    let m := seconds / 60
    let rem := seconds % 60
    (1 : UInt64) ||| (rem <<< 8) ||| (m <<< 32)
  else if seconds < 86400 then
    let totalM := seconds / 60
    let h := totalM / 60
    let remM := totalM % 60
    (2 : UInt64) ||| (remM <<< 8) ||| (h <<< 32)
  else
    let totalH := seconds / 3600
    let d := if totalH / 24 ≤ 4294967295 then totalH / 24 else 4294967295
    let remH := totalH % 24
    (3 : UInt64) ||| (remH <<< 8) ||| (d <<< 32)

/--
  Unboxed C-ABI Turn Outcome Stepper (`orb_turn_outcome_step`):
  `eventKind`: `0 = user_message`, `1 = todo_update`, `2 = assistant_message`.
  Packs `bit 0 = nextOutcome (0 = stopped, 1 = finished)`, `bit 8 = nextTodosFailed (0/1)`.
-/
@[inline, export orb_turn_outcome_step]
def turnOutcomeStep
    (prevOutcome prevFailed eventKind isNarration isSuccessFalse isTextNonEmpty : UInt8) : UInt32 :=
  if eventKind == 0 || eventKind == 1 then
    0
  else if eventKind == 2 then
    if isNarration == 1 then
      (if prevOutcome == 1 then 1 else 0) ||| (if prevFailed == 1 then 256 else 0)
    else if isSuccessFalse == 1 then
      256
    else if prevFailed == 0 && isTextNonEmpty == 1 then
      1
    else
      (if prevOutcome == 1 then 1 else 0) ||| (if prevFailed == 1 then 256 else 0)
  else
    (if prevOutcome == 1 then 1 else 0) ||| (if prevFailed == 1 then 256 else 0)

/--
  Unboxed C-ABI Pipe-Table Numeric Cell Gate (`orb_numeric_cell_scan`):
  Returns `1` iff the trimmed cell is non-empty (`nonEmpty == 1`), starts with an optional
  sign/currency and digit (`hasLeadingDigitOrSign == 1`), contains at least one ASCII digit
  (`hasDigit == 1`), and every character belongs to the numeric cell alphabet (`allAllowedChars == 1`).
-/
@[inline, export orb_numeric_cell_scan]
def numericCellScan
    (nonEmpty hasLeadingDigitOrSign hasDigit allAllowedChars : UInt8) : UInt8 :=
  if nonEmpty == 1 && hasLeadingDigitOrSign == 1 && hasDigit == 1 && allAllowedChars == 1 then 1 else 0

/--
  Unboxed C-ABI File Reference Line Span Gate (`orb_file_ref_line_span`):
  Validates a 1-based `[startLine, endLine]` span against `totalLines` (`0` = unbounded):
  Packs `bit 0 = admitted`, `bits 32..63 = spanLineCount (endLine - startLine + 1)`.
-/
@[inline, export orb_file_ref_line_span]
def fileRefLineSpan (startLine endLine totalLines : UInt32) : UInt64 :=
  if 1 ≤ startLine && startLine ≤ endLine && (totalLines == 0 || endLine ≤ totalLines) then
    let count : UInt32 := endLine - startLine + 1
    (1 : UInt64) ||| (count.toUInt64 <<< 32)
  else
    0

/--
  Unboxed C-ABI Managed Machine Action Gate (`orb_machine_action_admitted`):
  `stateKind`: `0 = provisioning`, `1 = enrolling`, `2 = online`, `3 = destroying`,
  `4 = destroyed`, `5 = failed`, `6 = stopped`.
  Packs `bit 0 = isLive`, `bit 8 = canAct`, `bit 16 = meterLiveCost`,
  `bit 24 = isStopped`, `bit 25 = canResume`.
-/
@[inline, export orb_machine_action_admitted]
def machineActionAdmitted (stateKind isBusy isMuted : UInt8) : UInt32 :=
  let idleUnmuted : Bool := isBusy == 0 && isMuted == 0
  let isLive : UInt32 := if stateKind ≤ 3 then 1 else 0
  let canAct : UInt32 := if stateKind ≤ 2 && idleUnmuted then 256 else 0
  let meterCost : UInt32 := if stateKind ≤ 2 then 65536 else 0
  let isStopped : UInt32 := if stateKind == 6 then 16777216 else 0
  let canResume : UInt32 := if stateKind == 6 && idleUnmuted then 33554432 else 0
  isLive ||| canAct ||| meterCost ||| isStopped ||| canResume

/--
  Unboxed C-ABI Send Flow & Queue Edit Stepper (`orb_send_flow_step`):
  Packs:
  - `bits 0..7 = tapAction`: `0 = ignore`, `1 = send`, `2 = deferToQueue`
  - `bit 8 = canDrain`: `1` iff `pendingCount > 0 && awaitingAck == 0 && isDraining == 0`
  - `bits 16..23 = editOutcome`: `0 = failed`, `1 = edited (200..299)`, `2 = unsupported (404/405)`, `3 = alreadySent (409)`
-/
@[inline, export orb_send_flow_step]
def sendFlowStep
    (isBusy hasNonEmptyText canQueue awaitingAck isDraining pendingCount : UInt8)
    (httpStatus : UInt32) : UInt32 :=
  let tap : UInt32 :=
    if hasNonEmptyText == 0 then 0
    else if isBusy == 0 then 1
    else if canQueue == 1 then 2
    else 0
  let drain : UInt32 := if 0 < pendingCount && awaitingAck == 0 && isDraining == 0 then 256 else 0
  let editOut : UInt32 :=
    if 200 ≤ httpStatus && httpStatus < 300 then 1
    else if httpStatus == 404 || httpStatus == 405 then 2
    else if httpStatus == 409 then 3
    else 0
  tap ||| drain ||| (editOut <<< 16)

/-! ## Wave 9 — Phase 0: `OrbWire` Canonical Word+Arena Wire Codec & Schema Migration Gates -/

/--
  Unboxed C-ABI `OrbWire` Frame & Arena Bounds Validator (`orb_wire_validate_frame`):
  Validates a versioned `AbiHeader` (`magic == 0x4F524257 ("ORBW")`, `abiVersion == 1`,
  `schemaId == expectedSchemaId`), total buffer bounds (`24 ≤ totalLen ≤ maxBudgetBytes`),
  payload slice bounds (`payloadLen ≤ totalLen - 24`), contiguous string/blob arena slice
  bounds (`arenaOff ≤ payloadLen && arenaLen ≤ payloadLen - arenaOff`), and caller output
  buffer capacity (`requiredOutBytes ≤ outCap`).
  Returns status code `UInt8`:
  - `0`: `OK`
  - `1`: `BAD_MAGIC_OR_VERSION`
  - `2`: `UNSUPPORTED_SCHEMA`
  - `3`: `TRUNCATED_OR_OUT_OF_BOUNDS`
  - `4`: `BUDGET_EXCEEDED`
  - `5`: `OUTPUT_TOO_SMALL`
-/
@[inline, export orb_wire_validate_frame]
def wireValidateFrame
    (magic abiVersion schemaId expectedSchemaId
     totalLen payloadLen arenaOff arenaLen
     maxBudgetBytes outCap requiredOutBytes : UInt32) : UInt8 :=
  if !(magic == 0x4F524257 && abiVersion == 1) then 1
  else if !(schemaId == expectedSchemaId) then 2
  else if !(24 ≤ totalLen) then 3
  else if !(totalLen ≤ maxBudgetBytes) then 4
  else if !(payloadLen ≤ totalLen - 24) then 3
  else if !(arenaOff ≤ payloadLen && arenaLen ≤ payloadLen - arenaOff) then 3
  else if !(requiredOutBytes ≤ outCap) then 5
  else 0

/--
  Unboxed C-ABI `OrbWire` Canonical 64-Bit Record Word Encoder (`orb_wire_pack_record`):
  Packs `(tag : UInt8, flags : UInt8, len16 : UInt32, payload32 : UInt32)` into a canonical
  little-endian `UInt64` word (`bits 0..7 = tag`, `bits 8..15 = flags`,
  `bits 16..31 = len16 & 0xFFFF`, `bits 32..63 = payload32`).
-/
@[inline, export orb_wire_pack_record]
def wirePackRecord (tag flags : UInt8) (len16 payload32 : UInt32) : UInt64 :=
  let lo32 : UInt32 :=
    tag.toUInt32 ||| (flags.toUInt32 <<< 8) ||| ((len16 &&& 0xFFFF) <<< 16)
  lo32.toUInt64 ||| (payload32.toUInt64 <<< 32)

@[inline] def wireRecordTag (w : UInt64) : UInt8 :=
  (w &&& 0xFF).toUInt8

@[inline] def wireRecordFlags (w : UInt64) : UInt8 :=
  ((w >>> 8) &&& 0xFF).toUInt8

@[inline] def wireRecordLen16 (w : UInt64) : UInt32 :=
  ((w >>> 16) &&& 0xFFFF).toUInt32

@[inline] def wireRecordPayload32 (w : UInt64) : UInt32 :=
  (w >>> 32).toUInt32

/--
  Unboxed C-ABI `OrbWire` Consecutive Schema Migration Gate (`orb_wire_schema_migrate_step`):
  Admits a state migration iff `fromSchema == currentSchema`, `fromSchema < toSchema`,
  `toSchema - fromSchema == 1` (single-step consecutive version hop), and
  `0 < payloadBytes ∧ payloadBytes ≤ maxBytes`.
-/
@[inline, export orb_wire_schema_migrate_step]
def wireSchemaMigrateStep
    (fromSchema toSchema currentSchema : UInt32)
    (payloadBytes maxBytes : UInt64) : UInt8 :=
  if fromSchema == currentSchema && fromSchema < toSchema &&
     toSchema - fromSchema == 1 && 0 < payloadBytes && payloadBytes ≤ maxBytes then 1
  else 0

/--
  Unboxed C-ABI Universal Effect Safety Precondition Gate (`orb_effect_admissible`):
  `effectKind`:
  - `0 = Observe / NoOp` (`budgetOk == 1`)
  - `1 = LaunchJob` (`hasValidLease == 1 && isArchived == 0 && idempotencyFresh == 1 && budgetOk == 1`)
  - `2 = ResumeSession` (`hasValidLease == 1 && sessionCreated == 1 && lineageVerified == 1 && isArchived == 0 && budgetOk == 1`)
  - `3 = DispatchProvider` (`accountBound == 1 && accountRejected == 0 && firstByteLocked == 0 && budgetOk == 1`)
  - `4 = ExecPrivCommand` (`grammarAllowed == 1 && envScrubbed == 1 && hasValidLease == 1 && isArchived == 0 && budgetOk == 1`)
  - `5 = MutateStore` (`hasValidLease == 1 && idempotencyFresh == 1 && budgetOk == 1`)
  Any unknown `effectKind > 5` is rejected (`0`).
-/
@[inline, export orb_effect_admissible]
def effectAdmissible
    (effectKind hasValidLease sessionCreated lineageVerified isArchived
     idempotencyFresh accountBound accountRejected firstByteLocked
     grammarAllowed envScrubbed budgetOk : UInt8) : UInt8 :=
  if budgetOk != 1 then 0
  else if effectKind == 0 then 1
  else if effectKind == 1 then
    if hasValidLease == 1 && isArchived == 0 && idempotencyFresh == 1 then 1 else 0
  else if effectKind == 2 then
    if hasValidLease == 1 && sessionCreated == 1 && lineageVerified == 1 && isArchived == 0 then 1 else 0
  else if effectKind == 3 then
    if accountBound == 1 && accountRejected == 0 && firstByteLocked == 0 then 1 else 0
  else if effectKind == 4 then
    if grammarAllowed == 1 && envScrubbed == 1 && hasValidLease == 1 && isArchived == 0 then 1 else 0
  else if effectKind == 5 then
    if hasValidLease == 1 && idempotencyFresh == 1 then 1 else 0
  else 0

/-! ## Wave 9 — Phase 2: Proxy Provider Account Pool, Failover & `ArgminRouteFold` -/

/--
  Unboxed C-ABI Provider Account Pool & Failover Stepper (`orb_provider_pool_step`):
  Pure decision machine for provider/account selection, Antigravity account pinning,
  cooldown/quota rejection enforcement, bounded failover, and first-byte commitment lock:
  - If `firstByteSent == 1 && isFailoverAttempt == 1`, returns `action = 3 (AbortLockedStream)`,
    emitting zero dispatch (`bit 8 == 0`, `StickyFence`).
  - Else if `isFailoverAttempt == 1 && !(1 ≤ maxAttempts && attempts < maxAttempts)`,
    returns `action = 4 (ExhaustedFailover)`, emitting zero dispatch.
  - Else if `hasBoundAccount == 1 && candidateAccountId != boundAccountId`,
    returns `action = 0 (RejectCandidate)` (prevents the wrong-account Antigravity bug).
  - Else if `isRejected == 1 && nowEpoch < resetEpoch`,
    returns `action = 0 (RejectCandidate)` (never routes to a rejected account before `resetEpoch`).
  - Else if `candidateAccountId == 0`, returns `action = 0 (RejectCandidate)`.
  - Otherwise admits dispatch (`bit 8 = 256`, `bit 16 = lockBit` preserving `firstByteSent`,
    `bits 32..63 = candidateAccountId`), with `action = 1 (DispatchBoundAccount)` when
    `hasBoundAccount == 1` and `action = 2 (DispatchPoolCandidate)` when `hasBoundAccount == 0`.
-/
@[inline, export orb_provider_pool_step]
def providerPoolStep
    (hasBoundAccount : UInt8) (boundAccountId candidateAccountId : UInt32)
    (isRejected firstByteSent isFailoverAttempt : UInt8)
    (attempts maxAttempts : UInt32)
    (nowEpoch resetEpoch : UInt64) : UInt64 :=
  let lockBit : UInt32 := if firstByteSent == 1 then 65536 else 0
  let lo32 : UInt32 :=
    if firstByteSent == 1 && isFailoverAttempt == 1 then 3 + lockBit
    else if isFailoverAttempt == 1 && !(1 ≤ maxAttempts && attempts < maxAttempts) then 4 + lockBit
    else if hasBoundAccount == 1 && !(candidateAccountId == boundAccountId) then lockBit
    else if isRejected == 1 && nowEpoch < resetEpoch then lockBit
    else if candidateAccountId == 0 then lockBit
    else (if hasBoundAccount == 1 then 1 else 2) + 256 + lockBit
  let hi32 : UInt32 :=
    if firstByteSent == 1 && isFailoverAttempt == 1 then 0
    else if isFailoverAttempt == 1 && !(1 ≤ maxAttempts && attempts < maxAttempts) then 0
    else if hasBoundAccount == 1 && !(candidateAccountId == boundAccountId) then 0
    else if isRejected == 1 && nowEpoch < resetEpoch then 0
    else if candidateAccountId == 0 then 0
    else candidateAccountId
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI `ArgminRouteFold` Candidate Selection Stepper (`orb_route_argmin_step`):
  Folds one candidate `(candId, candScore, candAdmissible)` into the running best route
  `(hasBest, bestId, bestScore)`:
  - Selects `candId` (`tookCandidate = 1`, `bit 8 = 256`) iff `candAdmissible == 1` and
    (`hasBest == 0 || candScore < bestScore`).
  - Packs `bit 0 = nextHasBest`, `bit 8 = tookCandidate`, `bits 32..63 = nextBestId : UInt32`.
-/
@[inline, export orb_route_argmin_step]
def routeArgminStep
    (hasBest : UInt8) (bestId : UInt32) (bestScore : UInt64)
    (candId : UInt32) (candScore : UInt64) (candAdmissible : UInt8) : UInt64 :=
  let takeCand : Bool := candAdmissible == 1 && (hasBest == 0 || candScore < bestScore)
  let lo32 : UInt32 :=
    if takeCand then 257
    else if hasBest == 1 then 1
    else 0
  let hi32 : UInt32 :=
    if takeCand then candId
    else if hasBest == 1 then bestId
    else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/-! ## Wave 9 — Phase 1: Control Core — Mission Lifecycle, Codex Resume, Fork `HOME` & Track Leases -/

/--
  Unboxed C-ABI Mission Control & Codex Resume Stepper (`orb_mission_control_step`):
  Pure decision machine for mission lifecycle, archived mission fencing, single-writer track
  admission, message replay deduplication, and verified Codex session resume vs. seeded fallback:
  - If `isArchived == 1`, returns `action = 0 (RejectArchived)` with `archivedNext = 1` (`bit 16 = 65536`)
    and zero dispatch (`bit 8 = 0`, `StickyFence` — archived missions never revive).
  - Else if `msgAlreadyDelivered == 1`, returns `action = 4 (DedupeDeliveredMessage)` with zero dispatch
    (`ReplayIdempotence` — no user message is delivered twice).
  - Else if `!(hasLease == 1 && activeTrackWriters == 0)`, returns `action = 5 (RejectTrackWriterConflict)`
    with zero dispatch (`at_most_one_writer_per_track`).
  - Else if `isResume == 1`:
    - If `sessionCreated == 1 && lineageVerified == 1 && rolloutExists == 1`, returns
      `action = 2 (ResumeVerifiedSession)` with `emitDispatch = 256` (`bit 8 = 1`) and `hi32 = 1`.
    - Else if `hasFallbackPrompt == 1`, returns `action = 3 (SeedFallbackFreshSession)` with
      `emitDispatch = 256` (`bit 8 = 1`), `seedFallback = 512` (`bit 9 = 1`), and `hi32 = 1`
      (prevents the phantom Codex session bug `16b74dd4` / `c96df4f9`).
    - Else returns `action = 6 (RejectUnverifiedResume)` with zero dispatch.
  - Otherwise (`isResume == 0`), returns `action = 1 (DispatchFreshTurn)` with `emitDispatch = 256`
    and `hi32 = 1` (`no_user_message_lost_or_duplicated`).
-/
@[inline, export orb_mission_control_step]
def missionControlStep
    (isArchived : UInt8) (activeTrackWriters : UInt32)
    (hasLease msgAlreadyDelivered isResume : UInt8)
    (sessionCreated lineageVerified rolloutExists hasFallbackPrompt : UInt8) : UInt64 :=
  let lo32 : UInt32 :=
    if isArchived == 1 then 65536
    else if msgAlreadyDelivered == 1 then 4
    else if !(hasLease == 1 && activeTrackWriters == 0) then 5
    else if isResume == 1 then
      if sessionCreated == 1 && lineageVerified == 1 && rolloutExists == 1 then 258
      else if hasFallbackPrompt == 1 then 771
      else 6
    else 257
  let hi32 : UInt32 :=
    if isArchived == 1 then 0
    else if msgAlreadyDelivered == 1 then 0
    else if !(hasLease == 1 && activeTrackWriters == 0) then 0
    else if isResume == 1 then
      if sessionCreated == 1 && lineageVerified == 1 && rolloutExists == 1 then 1
      else if hasFallbackPrompt == 1 then 1
      else 0
    else 1
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI Fork & `/btw` Workspace / `HOME` Isolation Stepper (`orb_fork_home_step`):
  Pure decision machine for conversation fork and `/btw` side-agent workspace resolution:
  - Under ALL inputs (`isForkOrSide == 0` or `1`, regardless of `requestedOverrideHome`),
    `overrideHomeBit` (`bit 16 = 65536`) is ALWAYS `0`: a fork or `/btw` job NEVER overrides
    its own job `HOME` directory with the source workspace (preventing the `#1302` / `9178bd08`
    harness sign-out bug).
  - If `isForkOrSide == 0`:
    returns `action = 1 (StandardJobWorkspace)` with `admitBit = 256` (`bit 8 = 1`),
    `jobHomePreservedBit = 131072` (`bit 17 = 1`), `useSourceCwdBit = 0`, `hi32 = 0` (`lo32 = 131329`).
  - Else (`isForkOrSide == 1`):
    - If `!(sourceExists == 1 && sourceIsSymlink == 0 && sameWorkspace == 1 && sameNode == 1)`,
      returns `action = 0 (RejectForkWorkspace)` with `admitBit = 0` and `hi32 = 78` (`EX_CONFIG`).
    - Else if `hasCommittedTransfer == 1`, returns `action = 3 (UseTransferredRootCwdKeepJobHome)`
      with `admitBit = 256`, `useSourceCwdBit = 512`, `jobHomePreservedBit = 131072`, `hi32 = 0`
      (`lo32 = 131843`).
    - Else returns `action = 2 (UseSiblingSourceCwdKeepJobHome)` with `admitBit = 256`,
      `useSourceCwdBit = 512`, `jobHomePreservedBit = 131072`, `hi32 = 0` (`lo32 = 131842`).
-/
@[inline, export orb_fork_home_step]
def forkHomeStep
    (isForkOrSide sourceExists sourceIsSymlink sameWorkspace sameNode : UInt8)
    (hasCommittedTransfer requestedOverrideHome : UInt8) : UInt64 :=
  let _ := requestedOverrideHome
  let validForkSource : Bool :=
    sourceExists == 1 && sourceIsSymlink == 0 && sameWorkspace == 1 && sameNode == 1
  let lo32 : UInt32 :=
    if isForkOrSide == 0 then 131329
    else if !validForkSource then 131072
    else if hasCommittedTransfer == 1 then 131843
    else 131842
  let hi32 : UInt32 :=
    if isForkOrSide == 0 then 0
    else if !validForkSource then 78
    else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 9 Phase 5: Security-Critical System Primitives (`orb-privd`, `development_identity`, Codex Driver)
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI Privileged Command Grammar & Environment Confinement Stepper (`orb_privd_command_step`):
  Constructive grammar and environment/path confinement replacing bypassable blacklists in `orb-privd`:
  - `grantScope`: `0 = OpsRead`, `1 = ServiceDeploy`, `2 = RootExec`.
  - `commandClass`: `0 = UnknownOrForbidden`, `1 = OpsReadSafe`, `2 = ServiceDeployUnit`,
    `3 = ServiceDeployReload`, `4 = RootExecCommand`.
  - Under ALL inputs (admitted or rejected), `scrubEnvBit` (`bit 9 = 512`) and
    `auditRequiredBit` (`bit 10 = 1024`) are ALWAYS `1` (`1536`).
  - Admits (`allowExecBit = 256`, `hi32 = 0`) iff `leaseValid == 1`, no shell metacharacter / flag
    bypass (`hasShellMetacharOrFlagBypass == 0`), no `..` traversal or symlink escape
    (`hasPathTraversalOrSymlink == 0`), no unsafe environment variable (`hasUnsafeEnvVar == 0`),
    and `(commandClass, grantScope)` satisfies `GrammarConfinement` and `NoPrivilegeEscalation`.
  - Otherwise rejects (`action = 0`, `allowExecBit = 0`, `lo32 = 1536`, `hi32 = 126`).
-/
@[inline, export orb_privd_command_step]
def privdCommandStep
    (leaseValid grantScope commandClass unitMatchesAllowed : UInt8)
    (hasShellMetacharOrFlagBypass hasPathTraversalOrSymlink hasUnsafeEnvVar requireForceCmd : UInt8) : UInt64 :=
  let safeInput : Bool :=
    leaseValid == 1 && hasShellMetacharOrFlagBypass == 0 &&
    hasPathTraversalOrSymlink == 0 && hasUnsafeEnvVar == 0
  let lo32 : UInt32 :=
    if !safeInput then 1536
    else if !(grantScope <= 2) then 1536
    else if commandClass == 1 then 1793
    else if commandClass == 2 && 1 <= grantScope && unitMatchesAllowed == 1 then 1794
    else if commandClass == 3 && 1 <= grantScope then 1794
    else if commandClass == 4 && grantScope == 2 && requireForceCmd == 0 then 1795
    else 1536
  let hi32 : UInt32 :=
    if lo32 == 1536 then 126 else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI SSH Development Identity & Codex Node Driver Confinement Stepper (`orb_ssh_identity_step`):
  Proves non-leakage of control-plane secrets (`PALOMA_SSH_PRIVATE_KEY`, `host_keys`, `ssh_hosts`) to
  worker nodes/containers (`coding_only_bundle`), rejects symlinked parent directories, private keys
  in public key fields, forward `proxy_jump` references, invalid `SANDBOXED_CYBER_PROGRAM` values,
  and exhausted Codex native goal budgets:
  - Under ALL inputs, `noSecretLeakBit` (`bit 10 = 1024`) is `1`, and whenever
    `isWorkerOrContainerTarget == 1`, `stripControlPlaneSecretsBit` (`bit 9 = 512`) is `1`.
  - When `valid` holds:
    - `isWorkerOrContainerTarget == 1` -> `action = 1 (AdmitCodingOnlyIdentity)`, `admitBit = 256`, `lo32 = 1793`, `hi32 = 0`.
    - `isWorkerOrContainerTarget == 0` -> `action = 2 (AdmitFleetIdentity)`, `admitBit = 256`, `lo32 = 1282`, `hi32 = 0`.
  - Otherwise rejects (`action = 0`, `admitBit = 0`, `hi32 = 78`).
-/
@[inline, export orb_ssh_identity_step]
def sshIdentityStep
    (isWorkerOrContainerTarget bundleHasControlPlaneKey parentDirIsSymlink : UInt8)
    (pubKeyIsEd25519WithoutPrivate proxyJumpValid codexCyberProgramValid codexGoalBudgetExhausted : UInt8) : UInt64 :=
  let valid : Bool :=
    parentDirIsSymlink == 0 && pubKeyIsEd25519WithoutPrivate == 1 &&
    proxyJumpValid == 1 && codexCyberProgramValid == 1 &&
    codexGoalBudgetExhausted == 0 &&
    !(isWorkerOrContainerTarget == 1 && bundleHasControlPlaneKey == 1)
  let lo32 : UInt32 :=
    if !valid then
      if isWorkerOrContainerTarget == 1 then 1536 else 1024
    else if isWorkerOrContainerTarget == 1 then 1793
    else 1282
  let hi32 : UInt32 :=
    if valid then 0 else 78
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 9 Phase 3: Multi-Harness Agent Event Normalizer & Unified Transcript Reducer
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI Multi-Harness Agent Event Normalizer Stepper (`orb_agent_event_normalize_step`):
  Total, bounded transducer step normalizing raw events across all 6 supported harnesses
  (`0 = Codex`, `1 = ClaudeCode`, `2 = Antigravity`, `3 = OpenCode`, `4 = Grok`, `5 = Vibe`):
  - `rawEventKind`: `0 = DiagnosticLine`, `1 = SessionIdUpdate`, `2 = ThinkingUpdate`,
    `3 = AssistantText`, `4 = ToolCall`, `5 = GoalProgress`, `6 = TurnCompleted`, `7 = ErrorOrAuth`.
  - Universally sets `totalTransducerBit` (`bit 11 = 2048`) and bounds `hi32` by `maxPayloadBytes` (`CostBound`).
-/
@[inline, export orb_agent_event_normalize_step]
def agentEventNormalizeStep
    (harnessKind rawEventKind isCompleted hasNonEmptyText : UInt8)
    (sessionMatchesExpected isDuplicateTurnOrTool payloadBytes maxPayloadBytes : UInt32) : UInt64 :=
  let bounded : Bool := payloadBytes <= maxPayloadBytes
  let harnessValid : Bool := harnessKind <= 5
  let sessionOk : Bool :=
    sessionMatchesExpected == 1 || rawEventKind == 0 || rawEventKind == 1 || rawEventKind == 7
  let notDup : Bool := isDuplicateTurnOrTool == 0
  let lo32 : UInt32 :=
    if !bounded then 2048
    else if !(harnessValid && sessionOk && notDup) then 2049
    else if rawEventKind == 0 then 2306
    else if rawEventKind == 1 then 2307
    else if rawEventKind == 2 then (if hasNonEmptyText == 1 then 2820 else 2049)
    else if rawEventKind == 3 then (if hasNonEmptyText == 1 then 3333 else 2049)
    else if rawEventKind == 4 then (if isCompleted == 1 then 3334 else 3335)
    else if rawEventKind == 5 then 2312
    else if rawEventKind == 6 then 3337
    else if rawEventKind == 7 then 3338
    else 2049
  let hi32 : UInt32 :=
    if bounded then payloadBytes else maxPayloadBytes
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI Unified Transcript Reducer Stepper (`orb_transcript_reduce_step`):
  Pure transcript reduction step shared by Core, iOS, Android, and Desktop (`wasm32`).
  Satisfies `replay_log_eq_live_transcript` (`isReplayFromLog` invariance) and strict sequence
  monotonicity (`incomingSeq > lastAppliedSeq` required to append/mutate transcript entries).
-/
@[inline, export orb_transcript_reduce_step]
def transcriptReduceStep
    (lastAppliedSeq incomingSeq : UInt64)
    (thinkingOpen normalizedAction isReplayFromLog : UInt8) : UInt64 :=
  let _ := isReplayFromLog
  let seqAdvances : Bool := incomingSeq > lastAppliedSeq
  let nextSeq32 : UInt32 := (if seqAdvances then incomingSeq else lastAppliedSeq).toUInt32
  let lo32 : UInt32 :=
    if !seqAdvances then
      if thinkingOpen == 1 then 512 else 0
    else if normalizedAction == 4 then 769
    else if normalizedAction == 5 || normalizedAction == 6 || normalizedAction == 7 ||
            normalizedAction == 9 || normalizedAction == 10 then
      if thinkingOpen == 1 then 1282 else 258
    else if normalizedAction == 2 || normalizedAction == 3 || normalizedAction == 8 then
      if thinkingOpen == 1 then 771 else 259
    else
      if thinkingOpen == 1 then 512 else 0
  lo32.toUInt64 ||| (nextSeq32.toUInt64 <<< 32)

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 9 Phase 4: Storage Invariants — Pagination Cursors & Sidebar Merge
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI Storage Pagination Cursor & Partial-Response Preservation Stepper (`orb_cursor_page_step`):
  Enforces strict exclusive cursor bounds (`since_seq < itemSeq < before_seq`), rejects inverted
  windows (`sinceSeq >= beforeSeq` when both bounds are active), and universally sets
  `preserveExistingBit` (`bit 9 = 512`) so partial or paginated responses never wipe stored data.
-/
@[inline, export orb_cursor_page_step]
def cursorPageStep
    (sinceSeq beforeSeq itemSeq : UInt64)
    (hasSinceCursor hasBeforeCursor isPartialResponse existingCount : UInt32) : UInt64 :=
  let validWindow : Bool := !(hasSinceCursor == 1 && hasBeforeCursor == 1 && sinceSeq >= beforeSeq)
  let afterSince : Bool := hasSinceCursor == 0 || itemSeq > sinceSeq
  let beforeBound : Bool := hasBeforeCursor == 0 || itemSeq < beforeSeq
  let admitItem : Bool := validWindow && afterSince && beforeBound
  let partialBit : UInt32 := if isPartialResponse == 1 then 1024 else 0
  let lo32 : UInt32 :=
    if !validWindow then 512 ||| partialBit
    else if admitItem then 769 ||| partialBit
    else 514 ||| partialBit
  let hi32 : UInt32 :=
    if admitItem then existingCount + 1 else existingCount
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI Sidebar Mission List Merge & Deduplication Stepper (`orb_sidebar_merge_step`):
  Eliminates duplicate missions in the sidebar (`sidebar_missions_unique_and_idempotent`):
  - When `existingIdOrd != 0 && existingIdOrd == incomingIdOrd` (`sameMission`), updates in place
    (`insertNewBit = 0`, `hi32 = 0` net new rows) if `incomingUpdatedAtMs >= existingUpdatedAtMs`
    or retains the newer existing row.
  - When `incomingSupersededOrArchived == 1`, removes or skips the superseded/archived mission.
  - Universally sets `uniqueSidebarBit` (`bit 10 = 1024`).
-/
@[inline, export orb_sidebar_merge_step]
def sidebarMergeStep
    (existingIdOrd incomingIdOrd : UInt32)
    (existingUpdatedAtMs incomingUpdatedAtMs : UInt64)
    (incomingSupersededOrArchived isPartialPage : UInt8) : UInt64 :=
  let sameMission : Bool := existingIdOrd != 0 && existingIdOrd == incomingIdOrd
  let incomingNewer : Bool := incomingUpdatedAtMs >= existingUpdatedAtMs
  let partialKeepBit : UInt32 := if isPartialPage == 1 then 2048 else 0
  let lo32 : UInt32 :=
    if incomingSupersededOrArchived == 1 then
      (if sameMission then 1028 else 1024) ||| partialKeepBit
    else if sameMission then
      (if incomingNewer then 1281 else 1282) ||| partialKeepBit
    else 1795 ||| partialKeepBit
  let hi32 : UInt32 :=
    if !(incomingSupersededOrArchived == 1) && !sameMission then 1 else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 9 Phase 6: Clients (iOS, Android & Desktop `wasm32`) Scroll Epoch & Parity
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI Client Scroll Correction Epoch Gate (`orb_scroll_epoch_step`):
  Enforces `scroll_correction_at_most_once_per_epoch` across iOS, Android, and Desktop (`wasm32`):
  once a scroll correction has been applied in `layoutEpoch` (`layoutEpoch <= lastCorrectedEpoch && correctionsInEpoch > 0`),
  any second correction in the same epoch is suppressed (`applyScrollBit = 0`, `hi32 = currentScrollTopPx`).
-/
@[inline, export orb_scroll_epoch_step]
def scrollEpochStep
    (layoutEpoch lastCorrectedEpoch : UInt32)
    (correctionsInEpoch isPinnedToBottom userIsDragging : UInt8)
    (targetScrollTopPx currentScrollTopPx : UInt32) : UInt64 :=
  let newEpoch : Bool := layoutEpoch > lastCorrectedEpoch
  let alreadyCorrected : Bool := !newEpoch && correctionsInEpoch > 0
  let needsDelta : Bool := targetScrollTopPx != currentScrollTopPx
  let admitCorrection : Bool :=
    isPinnedToBottom == 1 && userIsDragging == 0 && !alreadyCorrected && needsDelta
  let lo32 : UInt32 :=
    if admitCorrection then 1281
    else if alreadyCorrected then 1026
    else 0
  let hi32 : UInt32 :=
    if admitCorrection then targetScrollTopPx else currentScrollTopPx
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI Cross-Client `OrbWire` Projection Parity Stepper (`orb_client_parity_step`):
  Computes the canonical client projection state word across Core (`0`), iOS (`1`), Android (`2`),
  and Desktop `wasm32` (`3`), proving bit-for-bit parity across all 4 targets on the same `OrbWire` stream.
-/
@[inline, export orb_client_parity_step]
def clientParityStep
    (clientTarget : UInt8) (wireSchemaId : UInt32)
    (transcriptSeq markdownBlocksCount sendQueueDepth : UInt32)
    (scrollCorrectedInEpoch : UInt8) : UInt64 :=
  let validTarget : Bool := clientTarget <= 3
  let schemaOk : Bool := wireSchemaId >= 1 && wireSchemaId <= 2
  let lo32 : UInt32 :=
    if !(validTarget && schemaOk) then 0
    else if scrollCorrectedInEpoch == 1 then 769 else 257
  let hi32 : UInt32 :=
    if !(validTarget && schemaOk) then 0
    else transcriptSeq ^^^ (markdownBlocksCount <<< 16) ^^^ (sendQueueDepth <<< 24)
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 10: Fleet Security — Canary Blast-Radius Isolation, Process Whitelist,
--          High-Signal Attacker Bait, Enforcer Convergence & Biometric/Mesh Gates
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Canary Tripwire Blast-Radius & Process Whitelist Stepper (`canaryTripwireStep`):
  - `canaryClass`:
    - `0 = AmbientDecoy` (`.env.production.canary`, `.vault-recovery.age`, `mongo_27017`)
    - `≥ 1 = HighSignalBait` (attacker-only bait such as fake Bitcoin WIF / BIP-39 wallet seed
      `btc-treasury-wallet.dat` or fake SSH exfil key `ssh_exfil_canary` that legitimate agents
      never access; a hit even from an agent process implies process/inference compromise).
  - `actorTrust`:
    - `0 = WhitelistedAgentWalk` (routine search/walk by a known agent process: `rg`, `fd`, `find`, `ls`, `git`)
    - `1 = MissionProcess` (mission job process directly reading/probing an ambient decoy)
    - `≥ 2 = UntrustedOrSystem` (non-agent / unknown / root / external process)
  - `isDryRun`: `1` if synthetic `--dry-run`, else `0`.
  - `currentFleetBunker`: `0 = Normal`, `1 = SoftQuarantine`, `≥ 2 = HardLockdown`.
  - Returns a packed `UInt32`:
    - `bits 0..7`: `action` (`0 = IgnoreWhitelisted`, `1 = QuarantineNodeOnly`, `2 = EscalateFleetLockdown`)
    - `bit 8 (256)`: `quarantineReportingNodeBit` (`1` iff `action ≥ 1`)
    - `bit 9 (512)`: `fleetLockdownBit` (`1` iff `action == 2`)
    - `bit 10 (1024)`: `alertOperatorBit` (`1` iff `action ≥ 1` or `isDryRun == 1`)
    - `bits 16..23`: `nextFleetBunker` (`2` if `action == 2`, else `clampedFleetBunker`)
-/
@[inline]
def canaryTripwireStep
    (canaryClass actorTrust isDryRun currentFleetBunker : UInt8) : UInt64 :=
  let isHighSignal : Bool := canaryClass >= 1
  let lo32 : UInt32 :=
    if isDryRun == 1 then 1024
    else if isHighSignal then 1794
    else if actorTrust == 0 then 0
    else if actorTrust == 1 then 1281
    else 1794
  let hi32 : UInt32 :=
    if isDryRun == 1 then
      (if currentFleetBunker >= 2 then 2 else currentFleetBunker.toUInt32)
    else if isHighSignal then 2
    else if actorTrust == 0 || actorTrust == 1 then
      (if currentFleetBunker >= 2 then 2 else currentFleetBunker.toUInt32)
    else 2
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Worker Node Bunker Enforcer Convergence Stepper (`bunkerEnforcerStep`):
  Determines whether a worker node's `orb-bunker-enforcer` should apply/keep `paloma_canary_quarantine`
  or release it and clear `/run/paloma-canary-tripped`:
  - When `statusReachable == 0`: preserves local quarantine if `hasLocalTripMarker == 1`, else stays normal.
  - When `statusReachable == 1`:
    - Keeps/applies quarantine (`action = 1`, `bit 8 = 256`) iff `fleetBunker >= 2` (`HardLockdown` /
      `SovereignDeadManTripped`), or `nodeQuarantinedByCore == 1`, or (`hasLocalTripMarker == 1` and
      `lastUnbunkerEpoch < localTripEpoch`).
    - Releases quarantine (`action = 0`, `bit 8 = 0`, `clearMarkerBit = 512` if marker present)
      whenever `fleetBunker < 2 && nodeQuarantinedByCore == 0 && (hasLocalTripMarker == 0 || lastUnbunkerEpoch >= localTripEpoch)`.
-/
@[inline]
def bunkerEnforcerStep
    (statusReachable fleetBunker nodeQuarantinedByCore hasLocalTripMarker : UInt8)
    (localTripEpoch lastUnbunkerEpoch : UInt64) : UInt32 :=
  let fleetLockdown : Bool := fleetBunker >= 2
  let markerCleared : Bool := hasLocalTripMarker == 0 || lastUnbunkerEpoch >= localTripEpoch
  if statusReachable == 0 then
    if hasLocalTripMarker == 1 then 257 else 0
  else if fleetLockdown || nodeQuarantinedByCore == 1 || !markerCleared then
    257
  else if hasLocalTripMarker == 1 then
    512
  else
    0

/--
  Biometric Approval Gate Stepper (`biometricGateStep`):
  Enforces non-bypassable Face ID / Touch ID evaluation on mobile & desktop approval surfaces:
  - When `surfaceRequiresBio == 0`: admitted (`257`).
  - When `surfaceRequiresBio == 1`:
    - Admitted (`257`, `admittedBit = 256`) iff `(hardwareEnrolled == 1 && evalSucceeded == 1)` or
      `(hardwareEnrolled == 0 && passcodeFallbackSucceeded == 1)`.
    - Otherwise rejected (`512`, `admittedBit = 0`, `surfaceErrorBit = 512`) so failed or unavailable
      biometric contexts never silently drop or auto-approve the request.
-/
@[inline]
def biometricGateStep
    (surfaceRequiresBio hardwareEnrolled evalSucceeded passcodeFallbackSucceeded : UInt8) : UInt32 :=
  if surfaceRequiresBio == 0 then 257
  else if (hardwareEnrolled == 1 && evalSucceeded == 1) ||
          (hardwareEnrolled == 0 && passcodeFallbackSucceeded == 1) then 257
  else 512

/--
  Mesh Internal Service Route Admission Stepper (`meshServiceRouteStep`):
  Enforces that internal service endpoints (such as Spark Whisper `/v1/audio/transcriptions`)
  never route to a retired Tailscale CGNAT address (`endpointInRetiredTailnet == 1`) and only
  admit requests over the verified `lean-mesh` `10.88.0.0/16` overlay, loopback, or explicit bearer auth.
-/
@[inline]
def meshServiceRouteStep
    (endpointInMeshOverlay endpointInRetiredTailnet hasMeshAuthOrBearer isLoopback : UInt8) : UInt32 :=
  if endpointInRetiredTailnet == 1 then 512
  else if isLoopback == 1 || endpointInMeshOverlay == 1 || hasMeshAuthOrBearer == 1 then 257
  else 512

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 11: SOC 2 Type I Compliance Gates — 3-Key SSH & macOS Remote Login,
--          Off-Host B2 Audit Log Shipper, and OS Lifecycle / Boundary Scope
-- ═══════════════════════════════════════════════════════════════════════════

/--
  SOC 2 CC6.1 / CC6.6 3-Key SSH & macOS Remote Login Hardening Stepper (`soc2SshHostKeyPolicyStep`):
  Verifies that an enrolled fleet node (or `macbook-air` with macOS Remote Login enabled) enforces:
  - Exactly the 3 authorized public keys (`hasYubikeyAdminKey == 1 && hasBreakglassKey == 1 && hasUniqueHostKey == 1`)
  - Zero legacy/shared keys or worker private keys (`hasSharedLegacyKey == 0 && hasProvisioningRsaKey == 0 && workerHasFleetPrivateKey == 0`)
  - Key-only `sshd` configuration (`passwordAuthDisabled == 1 && kbdInteractiveDisabled == 1 && rootPasswordDisabled == 1`).
  Returns `257` (`admittedBit = 256 | 1`) when compliant, else `512` (`rejectBit = 512`).
-/
@[inline]
def soc2SshHostKeyPolicyStep
    (hasYubikeyAdminKey hasBreakglassKey hasUniqueHostKey : UInt8)
    (hasSharedLegacyKey hasProvisioningRsaKey workerHasFleetPrivateKey : UInt8)
    (passwordAuthDisabled kbdInteractiveDisabled rootPasswordDisabled : UInt8) : UInt32 :=
  if hasYubikeyAdminKey == 1 && hasBreakglassKey == 1 && hasUniqueHostKey == 1 &&
     hasSharedLegacyKey == 0 && hasProvisioningRsaKey == 0 && workerHasFleetPrivateKey == 0 &&
     passwordAuthDisabled == 1 && kbdInteractiveDisabled == 1 && rootPasswordDisabled == 1 then
    257
  else
    512

/--
  SOC 2 CC7.2 / C1.1 Off-Host Immutable Audit Log Shipper & Redaction Stepper (`soc2AuditShipperStep`):
  Admits an audit log batch for off-host Backblaze B2 shipping (`257`) iff:
  - Backblaze B2 credentials and append-only/Object-Lock mode are active (`hasB2Credentials == 1 && objectLockOrAppendOnly == 1`)
  - Command-line / environment secrets have been scrubbed (`secretsRedacted == 1`)
  - Per-record SHA-256 digest chain is verified (`sha256DigestVerified == 1`)
  - Batch payload is non-empty and within budget (`0 < batchBytes && batchBytes ≤ maxBatchBytes`).
  Otherwise returns `512` (`rejectBit = 512`).
-/
@[inline]
def soc2AuditShipperStep
    (hasB2Credentials objectLockOrAppendOnly secretsRedacted sha256DigestVerified : UInt8)
    (batchBytes maxBatchBytes : UInt64) : UInt32 :=
  if hasB2Credentials == 1 && objectLockOrAppendOnly == 1 &&
     secretsRedacted == 1 && sha256DigestVerified == 1 &&
     0 < batchBytes && batchBytes ≤ maxBatchBytes then
    257
  else
    512

/--
  SOC 2 CC7.1 / CC6.8 OS Lifecycle, Egress Filter & System Boundary Scope Stepper (`soc2HostScopeStep`):
  - For Out-of-Scope Scheduled Decommission hosts (`isOutOfScopeDecommission == 1`, e.g. expiring legacy Starknet.id VPSs):
    admits (`258`, `admittedBit = 256 | 2`) iff strictly isolated from `lean-mesh` and fleet credentials
    (`enrolledInLeanMesh == 0 && holdsFleetCredentials == 0`).
  - For In-Scope Fleet hosts (`isOutOfScopeDecommission == 0`):
    admits (`257`, `admittedBit = 256 | 1`) iff running a supported LTS OS (`osSupportedLts == 1`),
    `unattended-upgrades` or equivalent is active (`unattendedUpgradesActive == 1`), enrolled in `lean-mesh`
    (`enrolledInLeanMesh == 1`), and `chain mesh_output` egress filtering is active (`meshOutputEgressFilterActive == 1`).
  - Otherwise returns `512` (`rejectBit = 512`), automatically flagging EOL OS hosts inside `lean-mesh`
    or nodes missing `chain mesh_output`.
-/
@[inline]
def soc2HostScopeStep
    (isOutOfScopeDecommission osSupportedLts unattendedUpgradesActive : UInt8)
    (enrolledInLeanMesh meshOutputEgressFilterActive holdsFleetCredentials : UInt8) : UInt32 :=
  if isOutOfScopeDecommission == 1 then
    if enrolledInLeanMesh == 0 && holdsFleetCredentials == 0 then 258 else 512
  else
    if osSupportedLts == 1 && unattendedUpgradesActive == 1 &&
       enrolledInLeanMesh == 1 && meshOutputEgressFilterActive == 1 then
      257
    else
      512

/--
  Unboxed C-ABI Approval Admission Gate (`orb_verify_approval`), shared by every approval kind
  (secret access, privileged access, mission access) and by single and batch approvals:
  admits one request iff it carries a device signature (`signed == 1`), belongs to the approver
  (`owned == 1`), is still pending (`pending == 1`), has not expired (`unexpired == 1`), matches
  what the approver was shown (`unchanged == 1`), and is either below critical risk
  (`risk < 2`; `0 = routine`, `1 = elevated`, `2 = critical`) or explicitly confirmed
  (`confirmed == 1`). A batch is admitted only when every item is.
-/
@[inline, export orb_verify_approval]
def verifyApproval (signed owned pending unexpired unchanged risk confirmed : UInt8) : UInt8 :=
  if signed == 1 && owned == 1 && pending == 1 && unexpired == 1 && unchanged == 1 &&
     (risk < 2 || confirmed == 1) then 1 else 0

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 12: Worker Disk-Pressure Tiered Reclamation, Anti-Thrashing & Placement
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI Node Tiered Disk-Pressure Reclamation & Anti-Thrashing Controller (`orb_node_gc_step`):
  Evaluates node-owned storage tiers against `floorBytes` (`SANDBOXED_NODE_MIN_FREE_GB * GiB`) and
  `emergencyFloorBytes` (`min(floorBytes / 2, 10 GiB)`), using subtraction-only deficit cascading so
  64-bit byte counts never overflow:
  - When `freeBytes ≥ floorBytes`: returns `action = 0 (Healthy)` (`lo32 = 0`, `graceHours = 72` in `hi32`).
  - When `freeBytes < floorBytes`: cascades `deficit = floorBytes - freeBytes` across:
    1. `agedScratchBytes` (confirmed-retired scratch `age ≥ 6h`) → `rem1`
    2. `coldCacheBytes` (unlocked caches idle `≥ 2h` & stale transfer mutation builds) → `rem2`
    3. `freshScratchBytes` (confirmed-retired scratch `age < 6h`) → `rem3`
    4. `hotCacheBytes` (unlocked shared caches `idle < 2h`):
       - `unrecoverable := hotCacheBytes < rem3` (`pinnedPressureBit = 4096`)
       - `evictHot := rem3 > 0 && (!unrecoverable || (inEmergency && hotCacheBytes > 0))` (`evictHotBit = 2048`),
         preserving warm `< 2h` shared Lake caches whenever non-cache storage pins the disk below `floorBytes`
         above `emergencyFloorBytes`, while evicting them below `emergencyFloorBytes` to prevent `ENOSPC`.
  - Packed `UInt64` return:
    - `lo32 bits 0..7`: `action` (`0 = Healthy`, `1 = SweepAgedScratch`, `2 = EvictColdCaches`,
      `3 = SweepAllRetiredScratch`, `4 = EvictHotCaches`, `5 = PinnedPreserveHot`)
    - `bit 8 (256)`: `sweepAgedScratchBit` (`freeBytes < floorBytes`)
    - `bit 9 (512)`: `evictColdCacheBit` (`rem1 > 0`)
    - `bit 10 (1024)`: `sweepFreshScratchBit` (`rem2 > 0 || inEmergency`)
    - `bit 11 (2048)`: `evictHotCacheBit`
    - `bit 12 (4096)`: `pinnedPressureBit` (`unrecoverable`)
    - `hi32`: `retiredGraceHours` (`72` when healthy, `6` when `sweepAged && !sweepFresh`, `0` when `sweepFresh`).
-/
@[inline, export orb_node_gc_step]
def nodeGcStep
    (freeBytes floorBytes emergencyFloorBytes : UInt64)
    (agedScratchBytes freshScratchBytes coldCacheBytes hotCacheBytes : UInt64) : UInt64 :=
  let underFloor : Bool := freeBytes < floorBytes
  if !underFloor then
    (72 : UInt64) <<< 32
  else
    let emerg : Bool := freeBytes < emergencyFloorBytes
    let deficit : UInt64 := floorBytes - freeBytes
    let rem1 : UInt64 := if agedScratchBytes >= deficit then 0 else deficit - agedScratchBytes
    let rem2 : UInt64 := if coldCacheBytes >= rem1 then 0 else rem1 - coldCacheBytes
    let rem3 : UInt64 := if freshScratchBytes >= rem2 then 0 else rem2 - freshScratchBytes
    let unrecoverable : Bool := hotCacheBytes < rem3
    let evictCold : Bool := rem1 > 0
    let hasRem2 : Bool := rem2 > 0
    let hasRem3 : Bool := rem3 > 0
    let sweepFresh : Bool := if hasRem2 then true else emerg
    let evictHot : Bool :=
      if !hasRem3 then false
      else if !unrecoverable then true
      else if emerg then hotCacheBytes > 0
      else false
    let action : UInt32 :=
      if unrecoverable && !evictHot then 5
      else if evictHot then 4
      else if sweepFresh then 3
      else if evictCold then 2
      else 1
    let lo32 : UInt32 :=
      action ||| 256 |||
        (if evictCold then 512 else 0) |||
        (if sweepFresh then 1024 else 0) |||
        (if evictHot then 2048 else 0) |||
        (if unrecoverable then 4096 else 0)
    let graceHours : UInt32 := if sweepFresh then 0 else 6
    lo32.toUInt64 ||| (graceHours.toUInt64 <<< 32)

/--
  Unboxed C-ABI Node Disk-Floor & Pinned-Pressure Placement Gate (`orb_node_disk_admission_step`):
  - Enforces `effectiveFloor = max(nodeFloorBytes, coreFloorBytes)` against
    `effectiveFree = satSub64(freeBytes, reservedBytes)` and rejects any node advertising
    `nodePinnedPressure != 0`.
  - Flags `softPressureBit` (`bit 9 = 512`) when admitted inside the GC hysteresis band
    (`effectiveFree - effectiveFloor < hysteresisBytes`) so auto-placement prefers roomy peers
    at equal normalized utilization.
  - Packs clamped `headroomGiB` (`(effectiveFree - effectiveFloor) >>> 30`) in `hi32`.
  - `lo32`:
    - `2`: `RejectPinnedPressure` (`nodePinnedPressure != 0`)
    - `0`: `RejectBelowFloor` (`nodePinnedPressure == 0 && effectiveFree < effectiveFloor`)
    - `769` (`1 | 256 | 512`): `AdmitSoftPressure` (`admitted && headroomBytes < hysteresisBytes`)
    - `257` (`1 | 256`): `AdmitComfortable` (`admitted && headroomBytes ≥ hysteresisBytes`).
-/
@[inline, export orb_node_disk_admission_step]
def nodeDiskAdmissionStep
    (freeBytes reservedBytes nodeFloorBytes coreFloorBytes hysteresisBytes : UInt64)
    (nodePinnedPressure : UInt8) : UInt64 :=
  let effectiveFloor : UInt64 :=
    if nodeFloorBytes >= coreFloorBytes then nodeFloorBytes else coreFloorBytes
  let effectiveFree : UInt64 :=
    if freeBytes >= reservedBytes then freeBytes - reservedBytes else 0
  let pinned : Bool := nodePinnedPressure != 0
  let aboveFloor : Bool := effectiveFree >= effectiveFloor
  let admitted : Bool := !pinned && aboveFloor
  let headroomBytes : UInt64 :=
    if admitted then effectiveFree - effectiveFloor else 0
  let softPressure : Bool := admitted && headroomBytes < hysteresisBytes
  let rawHeadroomGiB : UInt64 := headroomBytes >>> 30
  let headroomGiB32 : UInt32 :=
    if rawHeadroomGiB > 0xFFFFFFFF then 0xFFFFFFFF else rawHeadroomGiB.toUInt32
  let lo32 : UInt32 :=
    if pinned then 2
    else if !aboveFloor then 0
    else if softPressure then 769
    else 257
  lo32.toUInt64 ||| (headroomGiB32.toUInt64 <<< 32)

-- ═══════════════════════════════════════════════════════════════════════════
-- Wave 13: Multi-Provider Managed Compute Governance & Secret Confinement
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI Managed VM Lifecycle, Working-Idle & Minimum-Commitment Stepper (`orb_vm_lifecycle_step`):
  `ownerClass`: `0 = unknown`, `1 = working`, `2 = waiting`, `3 = terminal_or_missing`, `4 = user_or_unowned`.
  Packs:
  - `bits 0..7 = action`: `0 = keep`, `1 = schedule`, `2 = stop`, `3 = destroy`
  - `bit 8 (256) = admitted`: `1` iff `action == 2 || action == 3`
  - `bit 16 (65536) = deferForMinLease`: `1` iff destroy is deferred because `minDeletePending == 1`
    (e.g. Scaleway Apple Silicon 24-hour `deletable_at` minimum commitment).
-/
@[inline, export orb_vm_lifecycle_step]
def vmLifecycleStep
    (ownerClass busy ttlExpired graceOrIdleElapsed workingIdleEnabled supportsFreeStop minDeletePending : UInt8) : UInt32 :=
  if ttlExpired == 1 then
    if minDeletePending == 1 then 65537 else 259
  else if busy == 1 then
    0
  else if ownerClass == 0 then
    0
  else if ownerClass == 1 then
    if workingIdleEnabled == 0 then
      0
    else if graceOrIdleElapsed == 0 then
      1
    else if minDeletePending == 1 then
      65537
    else
      259
  else if ownerClass == 2 then
    if graceOrIdleElapsed == 0 then
      1
    else if supportsFreeStop == 1 then
      258
    else if minDeletePending == 1 then
      65537
    else
      259
  else
    if graceOrIdleElapsed == 0 then
      1
    else if minDeletePending == 1 then
      65537
    else
      259

/--
  Unboxed C-ABI Managed VM Lineage Claim & Tenant Isolation Gate (`orb_vm_claim_step`):
  Admits (`257 = 1 ||| 256`) iff the machine is live (`isLive == 1`), belongs to the same tenant
  (`sameTenant == 1`), and is either unowned (`ownerNone == 1`) or currently owned by the authorized
  requester/lineage (`ownerInLineage == 1`); otherwise rejects (`512`).
-/
@[inline, export orb_vm_claim_step]
def vmClaimStep (isLive sameTenant ownerNone ownerInLineage : UInt8) : UInt32 :=
  if isLive == 1 && sameTenant == 1 && (ownerNone == 1 || ownerInLineage == 1) then
    257
  else
    512

/--
  Unboxed C-ABI Cloud Compute Secret Confinement & Untrusted Managed-Node Gate (`orb_compute_secret_gate`):
  - Core-reserved cloud provider API keys (`isCoreReservedComputeKey == 1`, e.g. `BOAT_API_KEY`,
    `HETZNER_CLOUD_APIKEY`, `SCALEWAY_SECRET_KEY`, `VASTAI_API_KEY`) are rejected (`512`) unless an
    explicit operator break-glass override is active (`operatorBreakGlass == 1`).
  - Missions executing on untrusted external managed nodes (`callerOnManagedNode == 1`) are rejected (`512`)
    for any secret outside the explicit managed-node allowlist (`isAllowlistedManagedSecret == 0`).
  - Otherwise admits (`257`).
-/
@[inline, export orb_compute_secret_gate]
def computeSecretGate
    (isCoreReservedComputeKey callerOnManagedNode isAllowlistedManagedSecret operatorBreakGlass : UInt8) : UInt32 :=
  if isCoreReservedComputeKey == 1 && operatorBreakGlass == 0 then
    512
  else if callerOnManagedNode == 1 && isAllowlistedManagedSecret == 0 then
    512
  else
    257
-- Wave 12 (P4–P6): Compositional `OrbWire` Patch/Machine ABI & 7 Stateful
--                  Domain Steppers (Closing `G-ORB-1..7`)
-- ═══════════════════════════════════════════════════════════════════════════

/--
  Unboxed C-ABI `OrbWire` Field-Presence Patch Stepper (`orb_wire_apply_patch_step`):
  Applies a revision-fenced tri-state field patch (`presence : 0 = Omitted, 1 = Present, 2 = Cleared`)
  to `(currentRev, currentHasVal, currentVal)`:
  - Rejects unknown presence tags (`presence > 2`, `lo32 = 0`, state preserved).
  - Rejects stale or duplicate revisions (`!(incomingRev > currentRev)`, `lo32` action `2`, state preserved).
  - `presence == 0 (Omitted)`: advances revision, preserves `(currentHasVal, currentVal)` (`lo32` action `3 | 256`).
  - `presence == 1 (Present)`: advances revision, sets `hasVal = 1`, `val = incomingVal` (`lo32 = 769`, `hi32 = incomingVal`).
  - `presence == 2 (Cleared)`: advances revision, clears `hasVal = 0`, `val = 0` (`lo32 = 260`, `hi32 = 0`).
-/
@[inline, export orb_wire_apply_patch_step]
def wireApplyPatchStep
    (currentRev incomingRev : UInt64)
    (currentHasVal : UInt8) (currentVal : UInt32)
    (presence : UInt8) (incomingVal : UInt32) : UInt64 :=
  let keepBit : UInt32 := if currentHasVal == 1 then 512 else 0
  let keepVal : UInt32 := if currentHasVal == 1 then currentVal else 0
  let validPresence : Bool := presence <= 2
  let freshRev : Bool := incomingRev > currentRev
  let lo32 : UInt32 :=
    if !validPresence then 0
    else if !freshRev then 2 ||| keepBit
    else if presence == 0 then 259 ||| keepBit
    else if presence == 1 then 769
    else 260
  let hi32 : UInt32 :=
    if !(validPresence && freshRev) then keepVal
    else if presence == 0 then keepVal
    else if presence == 1 then incomingVal
    else 0
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Unboxed C-ABI Compositional `OrbWire` Machine Stepper (`orb_wire_machine_step`):
  Executes a validated, versioned, output-capacity-fenced `OrbWire` state-machine step:
  - If `outCap < requiredOutBytes`: returns `lo32 = 5`, `hi32 = stateRev32` (zero partial mutation).
  - If `!(schemaId >= 1 && schemaId <= 2)`: returns `lo32 = 2`, `hi32 = stateRev32`.
  - If `!(eventSeq > stateRev)`: returns `lo32 = 3`, `hi32 = stateRev32` (`ReplayIdempotence`).
  - If `effectAdmitted != 1`: returns `lo32 = 4`, `hi32 = stateRev32` (`EffectSafety` rejection).
  - Otherwise admits transition (`lo32 = 257 | emitBit`, `hi32 = eventSeq.toUInt32`).
-/
@[inline, export orb_wire_machine_step]
def wireMachineStep
    (schemaId : UInt32)
    (stateRev eventSeq : UInt64)
    (effectKind effectAdmitted : UInt8)
    (outCap requiredOutBytes : UInt32) : UInt64 :=
  let curRev32 : UInt32 := stateRev.toUInt32
  let capOk : Bool := requiredOutBytes <= outCap
  let schemaOk : Bool := schemaId >= 1 && schemaId <= 2
  let seqFresh : Bool := eventSeq > stateRev
  let authOk : Bool := effectAdmitted == 1 && effectKind <= 5
  let emitBit : UInt32 := if effectKind != 0 then 512 else 0
  let lo32 : UInt32 :=
    if !capOk then 5
    else if !schemaOk then 2
    else if !seqFresh then 3
    else if !authOk then 4
    else 257 ||| emitBit
  let hi32 : UInt32 :=
    if capOk && schemaOk && seqFresh && authOk then eventSeq.toUInt32 else curRev32
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Family 1 (`G-ORB-5`): Epoch-Aware Mission Hierarchy & Snapshot/Patch Merge Stepper (`orb_hierarchy_merge_step`):
  Distinguishes full-snapshot replacement (`isPartialPatch == 0`) from partial-patch preservation
  (`isPartialPatch == 1`, where `parentPresence == 0` preserves `curParentOrd` while `parentPresence == 2`
  clears it), and enforces the sticky supersession fence (`curSuperseded == 1 || incSupersede == 1`)
  versus explicit epoch-fenced unarchive (`incUnarchive == 1 && incomingEpoch > archiveEpoch && !superseded`).
-/
@[inline, export orb_hierarchy_merge_step]
def hierarchyMergeStep
    (currentEpoch incomingEpoch archiveEpoch : UInt64)
    (curArchived curSuperseded isPartialPatch parentPresence : UInt8)
    (curParentOrd incParentOrd : UInt32)
    (incArchive incUnarchive incSupersede : UInt8) : UInt64 :=
  let nextSup : Bool := curSuperseded == 1 || incSupersede == 1
  let curArchBool : Bool := curArchived == 1
  let incArchBool : Bool := incArchive == 1
  let incUnarchBool : Bool := incUnarchive == 1
  let incSupBool : Bool := incSupersede == 1
  let validPresence : Bool := parentPresence <= 2
  let epochFresh : Bool :=
    if isPartialPatch == 1 then incomingEpoch > currentEpoch else incomingEpoch >= currentEpoch
  let unarchEpochOk : Bool := incomingEpoch > archiveEpoch
  let unarchiveAllowed : Bool :=
    if nextSup then false
    else if incUnarchBool then (if incArchBool then false else unarchEpochOk)
    else false
  let nextArch : Bool :=
    if nextSup then true
    else if validPresence then
      if epochFresh then
        if incArchBool then true
        else if unarchiveAllowed then false
        else curArchBool
      else curArchBool
    else curArchBool
  let supBlocks : Bool := if curSuperseded == 1 then !incSupBool else false
  let archBlocks : Bool :=
    if curArchBool then
      if nextSup then false
      else if incArchBool then false
      else !unarchiveAllowed
    else false
  let admit : Bool :=
    if validPresence then
      if epochFresh then
        if supBlocks then false else !archBlocks
      else false
    else false
  let nextParent : UInt32 :=
    if !admit then curParentOrd
    else if isPartialPatch == 1 then
      if parentPresence == 0 then curParentOrd
      else if parentPresence == 1 then incParentOrd
      else 0
    else
      if parentPresence == 1 then incParentOrd else 0
  let archBit : UInt32 := if nextArch then 512 else 0
  let supBit : UInt32 := if nextSup then 1024 else 0
  let unarchBit : UInt32 := if admit && unarchiveAllowed && curArchived == 1 then 2048 else 0
  let lo32 : UInt32 :=
    (if admit then 257 else 2) ||| archBit ||| supBit ||| unarchBit
  lo32.toUInt64 ||| (nextParent.toUInt64 <<< 32)

/--
  Family 2 (`G-ORB-3`): Contiguous Sequence & Replay-Equivalent Transcript Fold Stepper (`orb_transcript_fold_step`):
  Enforces strict contiguous sequence progression (`incomingSeq == lastAppliedSeq + 1` with no `UInt64` wrap)
  so out-of-order gaps (`incomingSeq > lastAppliedSeq + 1`) are buffered (`action = 3`, `gapBit = 2048`)
  and duplicates (`incomingSeq <= lastAppliedSeq`) are ignored (`action = 2`), while `isReplayFromLog`
  is bit-for-bit invariant across live and replay folds.
-/
@[inline, export orb_transcript_fold_step]
def transcriptFoldStep
    (lastAppliedSeq incomingSeq : UInt64)
    (entryCount : UInt32)
    (thinkingOpen normalizedAction isReplayFromLog : UInt8) : UInt64 :=
  let _ := isReplayFromLog
  let keepThink : UInt32 := if thinkingOpen == 1 then 512 else 0
  let isDuplicate : Bool := incomingSeq <= lastAppliedSeq
  let isContiguous : Bool := !isDuplicate && (incomingSeq - lastAppliedSeq == 1)
  let isOpenThink : Bool := normalizedAction == 4
  let isAppendEntry : Bool :=
    normalizedAction == 5 || normalizedAction == 6 || normalizedAction == 7 ||
    normalizedAction == 9 || normalizedAction == 10
  let isMetaUpdate : Bool :=
    normalizedAction == 2 || normalizedAction == 3 || normalizedAction == 8
  let lo32 : UInt32 :=
    if isDuplicate then 2 ||| keepThink
    else if !isContiguous then 2051 ||| keepThink
    else if isOpenThink then 769
    else if isAppendEntry then (if thinkingOpen == 1 then 1281 else 257)
    else if isMetaUpdate then 260 ||| keepThink
    else 5 ||| keepThink
  let hi32 : UInt32 :=
    if isContiguous && isAppendEntry then satAdd32 entryCount 1 else entryCount
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Family 3 (`G-ORB-2`): Crash-Consistent Durable Outbox & Volatile Lease Reconciler (`orb_outbox_crash_reconcile_step`):
  Separates persistent WAL state (`durableQueued`, `durableAcked`) from volatile in-flight lease state
  (`volatileInFlight`, `volatileLeaseOwner`, `leaseBootEpoch` vs `nodeBootEpoch`):
  - If `durableAcked > durableQueued`, rejects corrupt WAL (`lo32 = 0`, `hi32 = 0`).
  - If `leaseBootEpoch != nodeBootEpoch`, crash-resets volatile lease/in-flight state and re-queues
    `durableQueued - durableAcked` unacknowledged messages (`reconciledBit = 512`, `0` lost messages).
  - Admits single-writer dispatch (`admitBit = 256`, `writerCount <= 1`) iff `unacked > 0`, `reqOwner != 0`,
    and either volatile lease was crash-reset or `volatileLeaseOwner == 0 || volatileLeaseOwner == reqOwner`.
-/
@[inline, export orb_outbox_crash_reconcile_step]
def outboxCrashReconcileStep
    (durableQueued durableAcked volatileInFlight : UInt32)
    (leaseBootEpoch nodeBootEpoch : UInt64)
    (volatileLeaseOwner reqOwner : UInt32) : UInt64 :=
  let validWal : Bool := durableAcked <= durableQueued
  let unacked : UInt32 := if validWal then durableQueued - durableAcked else 0
  let crashReset : Bool := leaseBootEpoch != nodeBootEpoch
  let effOwner : UInt32 := if crashReset then 0 else volatileLeaseOwner
  let effInFlight : UInt32 := if crashReset then 0 else volatileInFlight
  let canAcquire : Bool :=
    validWal && unacked > 0 && reqOwner != 0 &&
    (effOwner == 0 || effOwner == reqOwner) && effInFlight < unacked
  let nextOwner : UInt32 := if canAcquire then reqOwner else effOwner
  let writerBit : UInt32 := if nextOwner != 0 then 1024 else 0
  let crashBit : UInt32 := if crashReset then 512 else 0
  let lo32 : UInt32 :=
    if !validWal then 0
    else if canAcquire then 257 ||| crashBit ||| writerBit
    else (if unacked == 0 then 2 else 3) ||| crashBit ||| writerBit
  lo32.toUInt64 ||| (unacked.toUInt64 <<< 32)

/--
  Family 4: Multi-Attempt Provider Lifecycle, Cooldown & 3-Clock Stepper (`orb_provider_attempt_step`):
  Unifies retry budget (`attemptsUsed < retryBudget`), Antigravity account pinning (`pinnedAccountId == 0 || candidateAccountId == pinnedAccountId`),
  402/quota cooldown (`failureKind != 2` and `upstreamNowEpoch >= cooldownUntilEpoch`), 3-clock deadline
  isolation (`upstreamNowEpoch < upstreamDeadline && authValid == 1`), and sticky `firstByteCommitted` lock.
-/
@[inline, export orb_provider_attempt_step]
def providerAttemptStep
    (pinnedAccountId candidateAccountId : UInt32)
    (attemptsUsed retryBudget : UInt32)
    (firstByteCommitted failureKind : UInt8)
    (upstreamNowEpoch cooldownUntilEpoch upstreamDeadline : UInt64)
    (authValid : UInt8) : UInt64 :=
  let nextFirstByte : Bool := firstByteCommitted == 1 || failureKind == 3
  let lockBit : UInt32 := if nextFirstByte then 512 else 0
  let pinOk : Bool :=
    candidateAccountId != 0 && (pinnedAccountId == 0 || candidateAccountId == pinnedAccountId)
  let cooldownOk : Bool := failureKind != 2 && upstreamNowEpoch >= cooldownUntilEpoch
  let clockOk : Bool := upstreamNowEpoch < upstreamDeadline && authValid == 1
  let isRetry : Bool := failureKind == 1 || failureKind == 2
  let budgetOk : Bool := if isRetry then attemptsUsed < retryBudget else attemptsUsed <= retryBudget
  let canDispatch : Bool :=
    !(firstByteCommitted == 1 && isRetry) && pinOk && cooldownOk && clockOk && budgetOk
  let nextAttempts : UInt32 :=
    if canDispatch && isRetry then satAdd32 attemptsUsed 1 else attemptsUsed
  let lo32 : UInt32 :=
    if firstByteCommitted == 1 && isRetry then 3 ||| lockBit
    else if !pinOk then 4 ||| lockBit
    else if !cooldownOk then 5 ||| lockBit
    else if !clockOk then 6 ||| lockBit
    else if !budgetOk then 7 ||| lockBit
    else 257 ||| lockBit
  lo32.toUInt64 ||| (nextAttempts.toUInt64 <<< 32)

/--
  Family 5 (`G-ORB-7`): `observe -> gate -> execute` TOCTOU Authorization Stepper (`orb_auth_toctou_execute_step`):
  Binds an execution attempt to the exact authorization evidence observed at gate time:
  admits (`257`) iff `principalKind >= 1 && principalKind <= 3`, `observedTargetId != 0 && observedTargetId == execTargetId`,
  `observedLeaseEpoch != 0 && observedLeaseEpoch == liveLeaseEpoch`, `observedDigest != 0 && observedDigest == execDigest`,
  `nowTick < expiryTick`, and `bunkerState == 0` (normal). Any target swap, lease revocation/rotation,
  payload mutation, expiry, or bunker trip between `gate` and `execute` fails closed (`>= 512`, `admittedBit = 0`).
-/
@[inline, export orb_auth_toctou_execute_step]
def authToctouExecuteStep
    (principalKind bunkerState : UInt8)
    (observedTargetId execTargetId : UInt32)
    (observedLeaseEpoch liveLeaseEpoch : UInt64)
    (nowTick expiryTick : UInt64)
    (observedDigest execDigest : UInt64) : UInt32 :=
  if bunkerState != 0 then 513
  else if !(principalKind >= 1 && principalKind <= 3) then 514
  else if !(nowTick < expiryTick) then 515
  else if !(observedLeaseEpoch != 0 && observedLeaseEpoch == liveLeaseEpoch) then 516
  else if !(observedTargetId != 0 && observedTargetId == execTargetId) then 517
  else if !(observedDigest != 0 && observedDigest == execDigest) then 518
  else 257

/--
  Family 6: Conserved Resource Reservation, Spend & TTL Reaper Stepper (`orb_resource_ledger_step`):
  Maintains `reservedSlots + activeSlots <= maxSlots` and `spentCents <= budgetCents` with TTL/boot-epoch
  reaping (`opKind : 0 = Reserve, 1 = ActivateReserved, 2 = ReleaseActive, 3 = ReapExpired`):
  - Never double-spends (`spentCents + costDeltaCents` checked without wrap via `costDeltaCents <= budgetCents - spentCents`).
  - Never overflows `maxSlots` (`activeSlots <= maxSlots && reservedSlots <= maxSlots - activeSlots`).
-/
@[inline, export orb_resource_ledger_step]
def resourceLedgerStep
    (opKind : UInt8)
    (reservedSlots activeSlots maxSlots : UInt32)
    (spentCents costDeltaCents budgetCents : UInt64)
    (nowTick ttlExpiryTick : UInt64) : UInt64 :=
  let activeFits : Bool := activeSlots <= maxSlots
  let remSlots : UInt32 := if activeFits then maxSlots - activeSlots else 0
  let reservedFits : Bool := reservedSlots <= remSlots
  let budgetValid : Bool := spentCents <= budgetCents
  let stateValid : Bool :=
    if activeFits then (if reservedFits then budgetValid else false) else false
  let remBudget : UInt64 := if budgetValid then budgetCents - spentCents else 0
  let spendFits : Bool := if stateValid then costDeltaCents <= remBudget else false
  let hasFreeSlot : Bool := reservedSlots < remSlots
  let hasReserved : Bool := reservedSlots > 0
  let hasActive : Bool := activeSlots > 0
  let ttlLive : Bool := nowTick < ttlExpiryTick
  let ttlExpired : Bool := nowTick >= ttlExpiryTick
  let canReserve : Bool :=
    if opKind == 0 then (if spendFits then (if hasFreeSlot then ttlLive else false) else false) else false
  let canActivate : Bool :=
    if opKind == 1 then (if stateValid then (if hasReserved then ttlLive else false) else false) else false
  let canRelease : Bool :=
    if opKind == 2 then (if stateValid then hasActive else false) else false
  let canReap : Bool :=
    if opKind == 3 then (if stateValid then (if hasReserved then ttlExpired else false) else false) else false
  let nextReserved : UInt32 :=
    if canReserve then reservedSlots + 1
    else if canActivate || canReap then reservedSlots - 1
    else reservedSlots
  let nextActive : UInt32 :=
    if canActivate then activeSlots + 1
    else if canRelease then activeSlots - 1
    else activeSlots
  let admit : Bool := canReserve || canActivate || canRelease || canReap
  let lo32 : UInt32 :=
    if !stateValid then 0
    else if admit then (257 : UInt32) ||| ((opKind.toUInt32 &&& (0xFF : UInt32)) <<< 1)
    else 2
  let hi32 : UInt32 := (nextReserved &&& (0xFFFF : UInt32)) ||| ((nextActive &&& (0xFFFF : UInt32)) <<< 16)
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)

/--
  Family 7 (`G-ORB-6`): Bounded-Tail Checkpointed Stream Commit Stepper (`orb_stream_bounded_commit_step`):
  Bounds the open Markdown fence tail by `maxOpenTailBytes` (`maxOpenTailBytes > 0`):
  computes monotone `nextCommit = max prevCommit (min rawCommit totalBytes)` and advances
  `nextCheckpoint = max (max prevCheckpoint nextCommit) (totalBytes - maxOpenTailBytes)` so the
  re-parsed open tail `totalBytes - nextCheckpoint` NEVER exceeds `maxOpenTailBytes` even on giant
  unclosed code fences.
-/
@[inline, export orb_stream_bounded_commit_step]
def streamBoundedCommitStep
    (prevLen prevCommit prevCheckpoint : UInt32)
    (newLen rawCommit maxOpenTailBytes : UInt32) : UInt64 :=
  let validCap : Bool := maxOpenTailBytes > 0
  let validMono : Bool :=
    prevCommit <= prevCheckpoint && prevCheckpoint <= prevLen && prevLen <= newLen
  let clampedRaw : UInt32 := if rawCommit <= newLen then rawCommit else newLen
  let nextCommit : UInt32 := if prevCommit <= clampedRaw then clampedRaw else prevCommit
  let baseCheckpoint : UInt32 := if prevCheckpoint <= nextCommit then nextCommit else prevCheckpoint
  let capFloor : UInt32 := if maxOpenTailBytes <= newLen then newLen - maxOpenTailBytes else 0
  let nextCheckpoint : UInt32 := if baseCheckpoint <= capFloor then capFloor else baseCheckpoint
  let checkpointForcedBit : UInt32 := if nextCheckpoint > nextCommit then 512 else 0
  let lo32 : UInt32 :=
    if !(validCap && validMono) then 0
    else 257 ||| checkpointForcedBit
  let hi32 : UInt32 :=
    if !(validCap && validMono) then prevCheckpoint else nextCheckpoint
  lo32.toUInt64 ||| (hi32.toUInt64 <<< 32)
end Orb.Kernel
