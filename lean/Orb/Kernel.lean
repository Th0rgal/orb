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
  `preflightMerged == 0` (already-merged PRs park for boss review), and `chatgptUiBlocked == 0`.
-/
@[inline, export orb_verify_board_retry]
def verifyBoardRetry
    (attempts maxAttempts : UInt32)
    (requiresExternalRecovery preflightMerged chatgptUiBlocked : UInt8) : UInt8 :=
  if maxAttempts ≥ 1 && attempts < maxAttempts &&
     requiresExternalRecovery == 0 && preflightMerged == 0 && chatgptUiBlocked == 0 then 1 else 0

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
  Unboxed C-ABI Bounded Process Log Window Gate (`leansys_verify_log_window` from `lean-sys`):
  Verifies that `offset ≤ fileSize`, `reqLen ≤ maxChunk`, `maxChunk ≤ hardCap`,
  `actualLen ≤ reqLen`, and `actualLen ≤ fileSize - offset`.
-/
@[inline, export leansys_verify_log_window]
def verifyLogWindow (offset reqLen maxChunk hardCap fileSize actualLen : UInt64) : UInt8 :=
  if offset ≤ fileSize && reqLen ≤ maxChunk && maxChunk ≤ hardCap &&
     actualLen ≤ reqLen && actualLen ≤ fileSize - offset then 1 else 0

/--
  Unboxed C-ABI Bijective 64-bit Avalanche Word Mixer (`leansys_mix64_word` from `lean-sys`).
-/
@[inline, export leansys_mix64_word]
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

end Orb.Kernel
