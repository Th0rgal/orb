import OrbLocald.Spec

/-
  OrbLocald.MutantSuite — 13-mutant kill & agreement witnesses covering all 8 gates in OrbLocald.Spec (`0 sorryAx`).
-/

namespace OrbLocald.MutantSuite

open OrbLocald.Spec

/-- Mutant 1: accepts non-loopback `isLoopback ≤ 1` RPC origins whenever bearer token matches. -/
def mutantRpcAuthIgnoreLoopback (isLoopback tokenMatches : UInt8) (tokenLen : UInt32) : UInt8 :=
  if isLoopback ≤ 1 && tokenMatches == 1 && tokenLen ≥ 32 && tokenLen ≤ 4096 then 1 else 0

theorem kill_mutantRpcAuthIgnoreLoopback :
    verifyLocaldRpcAuth 0 1 36 ≠ mutantRpcAuthIgnoreLoopback 0 1 36 ∧
    verifyLocaldRpcAuth 1 1 36 = mutantRpcAuthIgnoreLoopback 1 1 36 := by
  decide

/-- Mutant 2: admits SSE shard pools whose contiguous port block overflows 65535! -/
def mutantSseShardOverflowPort (shardCount : UInt8) (proxyPort : UInt16) : UInt8 :=
  if shardCount ≥ 1 && shardCount ≤ 16 && proxyPort ≥ 1024 then 1 else 0

theorem kill_mutantSseShardOverflowPort :
    verifySseShardConfig 6 65532 ≠ mutantSseShardOverflowPort 6 65532 ∧
    verifySseShardConfig 6 19480 = mutantSseShardOverflowPort 6 19480 := by
  decide

/-- Mutant 3: retries unsafe write requests (`hasIdempotencyKey ≤ 1`) across failover origins without `Idempotency-Key`. -/
def mutantWriteRetryWithoutIdempotency (isSafeMethod hasIdempotencyKey nextOriginIdx originCount : UInt8) : UInt8 :=
  if isSafeMethod ≤ 1 && hasIdempotencyKey ≤ 1 &&
     originCount ≥ 1 && originCount ≤ 16 && nextOriginIdx < originCount &&
     (isSafeMethod == 1 || hasIdempotencyKey ≤ 1) then 1 else 0

theorem kill_mutantWriteRetryWithoutIdempotency :
    verifyTransportWriteRetry 0 0 1 3 ≠ mutantWriteRetryWithoutIdempotency 0 0 1 3 ∧
    verifyTransportWriteRetry 0 1 1 3 = mutantWriteRetryWithoutIdempotency 0 1 1 3 := by
  decide

/-- Mutant 4: reuses Touch ID grace window on non-Bitwarden approval routes (`isBitwardenReq ≤ 1`). -/
def mutantGraceNonBitwarden (isPost isBitwardenReq : UInt8) (uuidLen : UInt32) (actionCode : UInt8) : UInt8 :=
  if isPost == 1 && isBitwardenReq ≤ 1 && uuidLen == 36 &&
     (actionCode == 1 || actionCode == 2) then 1 else 0

theorem kill_mutantGraceNonBitwarden :
    verifyPalomaGraceEligible 1 0 36 1 ≠ mutantGraceNonBitwarden 1 0 36 1 ∧
    verifyPalomaGraceEligible 1 1 36 1 = mutantGraceNonBitwarden 1 1 36 1 := by
  decide

/-- Mutant 5: silently evicts the oldest slot once `activeSlots == maxCap` (over-capacity admit). -/
def mutantToolSlotSilentEvict
    (activeSlots maxCap : UInt16)
    (sessionEpoch currentEpoch : UInt64)
    (hasNonEmptyRunId hasNonEmptyRequestId isDuplicateRequestId
      samePayloadReplay conflictingDuplicate : UInt8) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     hasNonEmptyRunId == 1 && hasNonEmptyRequestId == 1 &&
     sessionEpoch > 0 && currentEpoch > 0 &&
     sessionEpoch ≥ currentEpoch &&
     isDuplicateRequestId ≤ 1 && samePayloadReplay ≤ 1 && conflictingDuplicate ≤ 1 &&
     ((isDuplicateRequestId == 0 && activeSlots ≤ maxCap) ||
      (isDuplicateRequestId == 1 && samePayloadReplay == 1 && conflictingDuplicate == 0)) then 1 else 0

theorem kill_mutantToolSlotSilentEvict :
    verifyInteractiveToolSlotAdmit 64 64 2 2 1 1 0 0 0 ≠
      mutantToolSlotSilentEvict 64 64 2 2 1 1 0 0 0 ∧
    verifyInteractiveToolSlotAdmit 63 64 2 2 1 1 0 0 0 =
      mutantToolSlotSilentEvict 63 64 2 2 1 1 0 0 0 := by
  decide

/-- Mutant 6: accepts a stale session epoch (`sessionEpoch < currentEpoch`). -/
def mutantToolSlotStaleEpoch
    (activeSlots maxCap : UInt16)
    (sessionEpoch currentEpoch : UInt64)
    (hasNonEmptyRunId hasNonEmptyRequestId isDuplicateRequestId
      samePayloadReplay conflictingDuplicate : UInt8) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     hasNonEmptyRunId == 1 && hasNonEmptyRequestId == 1 &&
     sessionEpoch > 0 && currentEpoch > 0 &&
     sessionEpoch ≤ currentEpoch &&
     isDuplicateRequestId ≤ 1 && samePayloadReplay ≤ 1 && conflictingDuplicate ≤ 1 &&
     ((isDuplicateRequestId == 0 && activeSlots < maxCap) ||
      (isDuplicateRequestId == 1 && samePayloadReplay == 1 && conflictingDuplicate == 0)) then 1 else 0

theorem kill_mutantToolSlotStaleEpoch :
    verifyInteractiveToolSlotAdmit 0 64 1 2 1 1 0 0 0 ≠
      mutantToolSlotStaleEpoch 0 64 1 2 1 1 0 0 0 ∧
    verifyInteractiveToolSlotAdmit 0 64 2 2 1 1 0 0 0 =
      mutantToolSlotStaleEpoch 0 64 2 2 1 1 0 0 0 := by
  decide

/-- Mutant 7: `"native-"` prefix (empty-id flag) bypasses capacity and duplicate checks. -/
def mutantToolSlotNativeBypass
    (activeSlots maxCap : UInt16)
    (sessionEpoch currentEpoch : UInt64)
    (hasNonEmptyRunId hasNonEmptyRequestId isDuplicateRequestId
      samePayloadReplay conflictingDuplicate : UInt8) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     hasNonEmptyRunId == 1 &&
     sessionEpoch > 0 && currentEpoch > 0 &&
     sessionEpoch ≥ currentEpoch &&
     (hasNonEmptyRequestId == 0 ||
      ((isDuplicateRequestId ≤ 1 && samePayloadReplay ≤ 1 && conflictingDuplicate ≤ 1) &&
       ((isDuplicateRequestId == 0 && activeSlots < maxCap) ||
        (isDuplicateRequestId == 1 && samePayloadReplay == 1 && conflictingDuplicate == 0)))) then 1 else 0

theorem kill_mutantToolSlotNativeBypass :
    verifyInteractiveToolSlotAdmit 64 64 2 2 1 0 1 0 1 ≠
      mutantToolSlotNativeBypass 64 64 2 2 1 0 1 0 1 ∧
    verifyInteractiveToolSlotAdmit 0 64 2 2 1 1 0 0 0 =
      mutantToolSlotNativeBypass 0 64 2 2 1 1 0 0 0 := by
  decide

/-- Mutant 8: process-lifetime capability latch persists across `server_build` changes (`sameServerBuild == 0`). -/
def mutantCapLatchProcessLifetime
    (prevLatched sameEndpoint sameServerBuild : UInt8)
    (observedHttpStatus : UInt16)
    (hasObservedBuild : UInt8) : UInt8 :=
  if prevLatched ≤ 1 && sameEndpoint ≤ 1 && sameServerBuild ≤ 1 && hasObservedBuild ≤ 1 &&
     sameEndpoint == 1 &&
     (prevLatched == 1 || observedHttpStatus == 404 || observedHttpStatus == 501) then 1 else 0

theorem kill_mutantCapLatchProcessLifetime :
    verifyCapabilityLatch 1 1 0 200 1 ≠ mutantCapLatchProcessLifetime 1 1 0 200 1 ∧
    verifyCapabilityLatch 1 1 1 200 1 = mutantCapLatchProcessLifetime 1 1 1 200 1 := by
  decide

/-- Mutant 9: transient `502`/`503` gateway error permanently latches client-link capability as unsupported. -/
def mutantCapLatchTransient503
    (prevLatched sameEndpoint sameServerBuild : UInt8)
    (observedHttpStatus : UInt16)
    (hasObservedBuild : UInt8) : UInt8 :=
  if prevLatched ≤ 1 && sameEndpoint ≤ 1 && sameServerBuild ≤ 1 && hasObservedBuild ≤ 1 &&
     sameEndpoint == 1 &&
     (hasObservedBuild == 0 || sameServerBuild == 1) &&
     (prevLatched == 1 || observedHttpStatus ≥ 404) then 1 else 0

theorem kill_mutantCapLatchTransient503 :
    verifyCapabilityLatch 0 1 1 503 1 ≠ mutantCapLatchTransient503 0 1 1 503 1 ∧
    verifyCapabilityLatch 0 1 1 404 1 = mutantCapLatchTransient503 0 1 1 404 1 := by
  decide

/-- Mutant 10: silently overwrites the 256-frame outbound journal ring when `unackedFrames == maxCap`. -/
def mutantJournalRingSilentEvict
    (op : UInt8)
    (unackedFrames maxCap : UInt16)
    (lastAckedSeq headSeq targetSeq : UInt64) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     unackedFrames ≤ maxCap &&
     lastAckedSeq ≤ headSeq &&
     headSeq - lastAckedSeq == unackedFrames.toUInt64 &&
     ((op == 0 && unackedFrames ≤ maxCap && headSeq < 0xFFFFFFFFFFFFFFFF && targetSeq == headSeq + 1) ||
      (op == 1 && lastAckedSeq ≤ targetSeq && targetSeq ≤ headSeq) ||
      (op == 2 && targetSeq ≤ headSeq)) then 1 else 0

theorem kill_mutantJournalRingSilentEvict :
    verifyJournalRingStep 0 256 256 10 266 267 ≠
      mutantJournalRingSilentEvict 0 256 256 10 266 267 ∧
    verifyJournalRingStep 0 255 256 10 265 266 =
      mutantJournalRingSilentEvict 0 255 256 10 265 266 := by
  decide

/-- Mutant 11: accepts an out-of-range cumulative ACK beyond `headSeq` (corrupting reconnect resync). -/
def mutantJournalRingAckBeyondHead
    (op : UInt8)
    (unackedFrames maxCap : UInt16)
    (lastAckedSeq headSeq targetSeq : UInt64) : UInt8 :=
  if 1 ≤ maxCap && maxCap ≤ 256 &&
     unackedFrames ≤ maxCap &&
     lastAckedSeq ≤ headSeq &&
     headSeq - lastAckedSeq == unackedFrames.toUInt64 &&
     ((op == 0 && unackedFrames < maxCap && headSeq < 0xFFFFFFFFFFFFFFFF && targetSeq == headSeq + 1) ||
      (op == 1 && lastAckedSeq ≤ targetSeq) ||
      (op == 2 && targetSeq ≤ headSeq)) then 1 else 0

theorem kill_mutantJournalRingAckBeyondHead :
    verifyJournalRingStep 1 4 256 10 14 15 ≠
      mutantJournalRingAckBeyondHead 1 4 256 10 14 15 ∧
    verifyJournalRingStep 1 4 256 10 14 14 =
      mutantJournalRingAckBeyondHead 1 4 256 10 14 14 := by
  decide

/-- Mutant 12: coarse `"409"` status matching retries terminal `stale_receipt` (`conflictTag == 5`). -/
def mutantConflictCoarse409Retry
    (httpStatus : UInt16) (conflictTag wantRetry : UInt8) : UInt8 :=
  if httpStatus == 409 && wantRetry ≤ 1 &&
     ((wantRetry == 1 && conflictTag ≥ 1 && conflictTag ≤ 5) ||
      (wantRetry == 0 && (conflictTag == 3 || conflictTag == 4 || conflictTag == 5))) then 1 else 0

theorem kill_mutantConflictCoarse409Retry :
    verifyLocalConflictDisposition 409 5 1 ≠ mutantConflictCoarse409Retry 409 5 1 ∧
    verifyLocalConflictDisposition 409 2 1 = mutantConflictCoarse409Retry 409 2 1 := by
  decide

/-- Mutant 13: retires transient `stopping` (`conflictTag == 1`) as terminal instead of retrying. -/
def mutantConflictRetireStopping
    (httpStatus : UInt16) (conflictTag wantRetry : UInt8) : UInt8 :=
  if httpStatus == 409 && wantRetry ≤ 1 &&
     ((wantRetry == 1 && conflictTag == 2) ||
      (wantRetry == 0 && (conflictTag == 1 || conflictTag == 3 || conflictTag == 4 || conflictTag == 5))) then 1 else 0

theorem kill_mutantConflictRetireStopping :
    verifyLocalConflictDisposition 409 1 0 ≠ mutantConflictRetireStopping 409 1 0 ∧
    verifyLocalConflictDisposition 409 3 0 = mutantConflictRetireStopping 409 3 0 := by
  decide

end OrbLocald.MutantSuite
