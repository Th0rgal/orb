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
  claimedKind == 0 ||
  (principalKind == 5 && (claimedKind == 1 || claimedKind == 2 || claimedKind == 5)) ||
  ((principalKind == 1 || principalKind == 2) &&
    ((claimedKind == 1 && sameMission == 1) || (claimedKind == 2 && isDescendant == 1))) ||
  ((principalKind == 3 || principalKind == 4 || principalKind == 6) && claimedKind == principalKind)

/-- Principal kind clamped to the closed enum (`> 6` is `unknown`). -/
@[inline] def attributionPrincipal (principalKind : UInt8) : UInt8 :=
  if principalKind ≤ 6 then principalKind else 0

/-- Final caller kind: the claim when in scope (and non-empty), the principal's own kind otherwise. -/
@[inline] def attributionKind (principalKind claimedKind sameMission isDescendant : UInt8) : UInt8 :=
  if attributionInScope (attributionPrincipal principalKind) claimedKind sameMission isDescendant then
    (if claimedKind == 0 then attributionPrincipal principalKind else claimedKind)
  else attributionPrincipal principalKind

/--
  Unboxed C-ABI Usage Attribution Stepper (`orb_attribution_step`):
  packs `bits 0..7 = caller kind` (`attributionKind`) and `bit 8 = claim accepted`.
  A rejected (forged or out-of-scope) claim keeps the principal's own kind, so the caller is
  never empty and `unknown` is returned only when no credential binding exists.
-/
@[inline, export orb_attribution_step]
def attributionStep (principalKind claimedKind sameMission isDescendant : UInt8) : UInt32 :=
  (attributionKind principalKind claimedKind sameMission isDescendant).toUInt32 |||
    (if attributionInScope (attributionPrincipal principalKind) claimedKind sameMission isDescendant
     then 256 else 0)

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
  Packs `bit 0 = isLive`, `bit 8 = canAct`, `bit 16 = meterLiveCost`.
-/
@[inline, export orb_machine_action_admitted]
def machineActionAdmitted (stateKind isBusy isMuted : UInt8) : UInt32 :=
  let isLive : UInt32 := if stateKind ≤ 3 then 1 else 0
  let canAct : UInt32 := if stateKind ≤ 2 && isBusy == 0 && isMuted == 0 then 256 else 0
  let meterCost : UInt32 := if stateKind ≤ 2 then 65536 else 0
  isLive ||| canAct ||| meterCost

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

end Orb.Kernel
