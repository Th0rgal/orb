import OrbLocald.Spec

/-
  OrbLocald.MutantSuite — 7-mutant kill & agreement witnesses covering all 5 gates in OrbLocald.Spec (`0 sorryAx`).
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

end OrbLocald.MutantSuite
