import OrbLocald.Spec

/-
  OrbLocald.MutantSuite — 3-mutant kill & agreement witnesses for OrbLocald.Spec (`0 sorryAx`).
-/

namespace OrbLocald.MutantSuite

open OrbLocald.Spec

/-- Mutant 1: accepts non-loopback `isLoopback ≤ 1` RPC origins whenever bearer token matches. -/
def mutantRpcAuthIgnoreLoopback (isLoopback tokenMatches : UInt8) (tokenLen : UInt32) : UInt8 :=
  if isLoopback ≤ 1 && tokenMatches == 1 && tokenLen ≥ 16 && tokenLen ≤ 4096 then 1 else 0

theorem kill_mutantRpcAuthIgnoreLoopback :
    verifyLocaldRpcAuth 0 1 32 ≠ mutantRpcAuthIgnoreLoopback 0 1 32 ∧
    verifyLocaldRpcAuth 1 1 32 = mutantRpcAuthIgnoreLoopback 1 1 32 := by
  decide

/-- Mutant 2: retries unsafe write requests (`hasIdempotencyKey ≤ 1`) across failover origins without `Idempotency-Key`. -/
def mutantWriteRetryWithoutIdempotency (isSafeMethod hasIdempotencyKey nextOriginIdx originCount : UInt8) : UInt8 :=
  if originCount ≥ 1 && originCount ≤ 16 && nextOriginIdx < originCount &&
     (isSafeMethod == 1 || hasIdempotencyKey ≤ 1) then 1 else 0

theorem kill_mutantWriteRetryWithoutIdempotency :
    verifyTransportWriteRetry 0 0 1 3 ≠ mutantWriteRetryWithoutIdempotency 0 0 1 3 ∧
    verifyTransportWriteRetry 0 1 1 3 = mutantWriteRetryWithoutIdempotency 0 1 1 3 := by
  decide

/-- Mutant 3: reuses Touch ID grace window on non-Bitwarden approval routes (`isBitwardenReq ≤ 1`). -/
def mutantGraceNonBitwarden (isPost isBitwardenReq : UInt8) (uuidLen : UInt32) (isApproveOrReject : UInt8) : UInt8 :=
  if isPost == 1 && isBitwardenReq ≤ 1 && uuidLen == 36 && isApproveOrReject == 1 then 1 else 0

theorem kill_mutantGraceNonBitwarden :
    verifyPalomaGraceEligible 1 0 36 1 ≠ mutantGraceNonBitwarden 1 0 36 1 ∧
    verifyPalomaGraceEligible 1 1 36 1 = mutantGraceNonBitwarden 1 1 36 1 := by
  decide

end OrbLocald.MutantSuite
