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

end Orb.Kernel
