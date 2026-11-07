/-
  Orb.HarnessCloudMutants: Phase R4-A adversarial admission mutants (`0 import Lean`, `0 sorryAx`).

  Three concrete buggy admitters / classifiers per coordinated R4-A slice (12 total). Each drops one
  safety fence of the verified `Orb.HarnessCloud` scalar gate, and a `decide` `Ne` theorem shows
  the mutant accepts a reachable witness the verified gate rejects.
-/
import Orb.HarnessCloud

namespace Orb.HarnessCloudMutants

open Orb.HarnessCloud

/-! ## 1. `CloudTurn` (`SM-14`) -/

def mutCloudTurnUncertainFreshSubmit
    (phaseCode opCode hasTerminationReceipt hasCompletionReceipt
     operatorConfirmedNotDelivered approvalResolved : UInt8)
    (lastAttemptId proposedAttemptId providerTurnId approvalReqId
     submittedAtMs nowMs : UInt64) : UInt8 :=
  if phaseCode == 4 && opCode == 0 && proposedAttemptId != 0 &&
     lastAttemptId < proposedAttemptId && submittedAtMs != 0
  then 1
  else verifyCloudTurnAdmit phaseCode opCode hasTerminationReceipt hasCompletionReceipt
    operatorConfirmedNotDelivered approvalResolved lastAttemptId proposedAttemptId
    providerTurnId approvalReqId submittedAtMs nowMs

def mutCloudTurnCancelWithoutReceipt
    (phaseCode opCode hasTerminationReceipt hasCompletionReceipt
     operatorConfirmedNotDelivered approvalResolved : UInt8)
    (lastAttemptId proposedAttemptId providerTurnId approvalReqId
     submittedAtMs nowMs : UInt64) : UInt8 :=
  if hasTerminationReceipt == 0 then
    verifyCloudTurnAdmit phaseCode opCode 1 hasCompletionReceipt
      operatorConfirmedNotDelivered approvalResolved lastAttemptId proposedAttemptId
      providerTurnId approvalReqId submittedAtMs nowMs
  else
    verifyCloudTurnAdmit phaseCode opCode hasTerminationReceipt hasCompletionReceipt
      operatorConfirmedNotDelivered approvalResolved lastAttemptId proposedAttemptId
      providerTurnId approvalReqId submittedAtMs nowMs

def mutCloudTurnDuplicateAttemptSubmit
    (phaseCode opCode hasTerminationReceipt hasCompletionReceipt
     operatorConfirmedNotDelivered approvalResolved : UInt8)
    (lastAttemptId proposedAttemptId providerTurnId approvalReqId
     submittedAtMs nowMs : UInt64) : UInt8 :=
  if phaseCode == 0 && opCode == 0 && proposedAttemptId != 0 &&
     proposedAttemptId == lastAttemptId && submittedAtMs != 0
  then 1
  else verifyCloudTurnAdmit phaseCode opCode hasTerminationReceipt hasCompletionReceipt
    operatorConfirmedNotDelivered approvalResolved lastAttemptId proposedAttemptId
    providerTurnId approvalReqId submittedAtMs nowMs

theorem kill_mutCloudTurnUncertainFreshSubmit :
    mutCloudTurnUncertainFreshSubmit 4 0 0 0 0 0 1 2 0 0 100 100 ≠
    verifyCloudTurnAdmit 4 0 0 0 0 0 1 2 0 0 100 100 := by
  decide

theorem kill_mutCloudTurnCancelWithoutReceipt :
    mutCloudTurnCancelWithoutReceipt 5 9 0 0 0 0 2 2 10 0 100 200 ≠
    verifyCloudTurnAdmit 5 9 0 0 0 0 2 2 10 0 100 200 := by
  decide

theorem kill_mutCloudTurnDuplicateAttemptSubmit :
    mutCloudTurnDuplicateAttemptSubmit 0 0 0 0 0 0 3 3 0 0 100 100 ≠
    verifyCloudTurnAdmit 0 0 0 0 0 0 3 3 0 0 100 100 := by
  decide

/-! ## 2. `HarnessSession` (`SM-15`, `SM-16`, `SM-17`) -/

def mutHarnessExitToolDepthUnderflow
    (phaseCode opCode steerPending hasTurnIdleReceipt hasProcExitReceipt : UInt8)
    (toolDepth : UInt32)
    (sessionGeneration eventGeneration : UInt64) : UInt8 :=
  if phaseCode == 2 && opCode == 3 && toolDepth == 0 &&
     steerPending ≤ 1 && sessionGeneration != 0 && eventGeneration == sessionGeneration
  then 1
  else verifyHarnessSessionAdmit phaseCode opCode steerPending hasTurnIdleReceipt
    hasProcExitReceipt toolDepth sessionGeneration eventGeneration

def mutHarnessDeadWithoutProcExitReceipt
    (phaseCode opCode steerPending hasTurnIdleReceipt hasProcExitReceipt : UInt8)
    (toolDepth : UInt32)
    (sessionGeneration eventGeneration : UInt64) : UInt8 :=
  if hasProcExitReceipt == 0 then
    verifyHarnessSessionAdmit phaseCode opCode steerPending hasTurnIdleReceipt
      1 toolDepth sessionGeneration eventGeneration
  else
    verifyHarnessSessionAdmit phaseCode opCode steerPending hasTurnIdleReceipt
      hasProcExitReceipt toolDepth sessionGeneration eventGeneration

def mutHarnessStaleGenerationAdmit
    (phaseCode opCode steerPending hasTurnIdleReceipt hasProcExitReceipt : UInt8)
    (toolDepth : UInt32)
    (sessionGeneration eventGeneration : UInt64) : UInt8 :=
  if eventGeneration != sessionGeneration then
    verifyHarnessSessionAdmit phaseCode opCode steerPending hasTurnIdleReceipt
      hasProcExitReceipt toolDepth sessionGeneration sessionGeneration
  else
    verifyHarnessSessionAdmit phaseCode opCode steerPending hasTurnIdleReceipt
      hasProcExitReceipt toolDepth sessionGeneration eventGeneration

theorem kill_mutHarnessExitToolDepthUnderflow :
    mutHarnessExitToolDepthUnderflow 2 3 0 0 0 0 4 4 ≠
    verifyHarnessSessionAdmit 2 3 0 0 0 0 4 4 := by
  decide

theorem kill_mutHarnessDeadWithoutProcExitReceipt :
    mutHarnessDeadWithoutProcExitReceipt 4 10 0 0 0 0 4 4 ≠
    verifyHarnessSessionAdmit 4 10 0 0 0 0 4 4 := by
  decide

theorem kill_mutHarnessStaleGenerationAdmit :
    mutHarnessStaleGenerationAdmit 1 1 0 0 0 0 4 3 ≠
    verifyHarnessSessionAdmit 1 1 0 0 0 0 4 3 := by
  decide

/-! ## 3. `ProviderAttempt` (`SM-21`) -/

def mutProviderStaleGenerationDispatch
    (firstByteCommitted failureReason : UInt8)
    (pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold : UInt32)
    (routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch : UInt64) : UInt8 :=
  if attemptGeneration != routeGeneration then
    verifyProviderAttemptAdmit firstByteCommitted failureReason
      pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
      routeGeneration routeGeneration nowEpoch cooldownUntilEpoch
  else
    verifyProviderAttemptAdmit firstByteCommitted failureReason
      pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
      routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch

def mutProviderCommittedTransparentReroute
    (firstByteCommitted failureReason : UInt8)
    (pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold : UInt32)
    (routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch : UInt64) : UInt8 :=
  if firstByteCommitted == 1 && failureReason == 4 then
    verifyProviderAttemptAdmit 0 failureReason
      pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
      routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch
  else
    verifyProviderAttemptAdmit firstByteCommitted failureReason
      pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
      routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch

def mutProviderPinMismatchDispatch
    (firstByteCommitted failureReason : UInt8)
    (pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold : UInt32)
    (routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch : UInt64) : UInt8 :=
  if pinnedAccountId != 0 && candidateAccountId != pinnedAccountId then
    verifyProviderAttemptAdmit firstByteCommitted failureReason
      0 candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
      routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch
  else
    verifyProviderAttemptAdmit firstByteCommitted failureReason
      pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
      routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch

theorem kill_mutProviderStaleGenerationDispatch :
    mutProviderStaleGenerationDispatch 0 0 0 7 0 2 0 3 5 4 20 10 ≠
    verifyProviderAttemptAdmit 0 0 0 7 0 2 0 3 5 4 20 10 := by
  decide

theorem kill_mutProviderCommittedTransparentReroute :
    mutProviderCommittedTransparentReroute 1 4 7 7 0 2 0 3 5 5 20 10 ≠
    verifyProviderAttemptAdmit 1 4 7 7 0 2 0 3 5 5 20 10 := by
  decide

theorem kill_mutProviderPinMismatchDispatch :
    mutProviderPinMismatchDispatch 0 0 7 9 0 2 0 3 5 5 20 10 ≠
    verifyProviderAttemptAdmit 0 0 7 9 0 2 0 3 5 5 20 10 := by
  decide

/-! ## 4. `AuthRefresh` (`SM-21`) -/

def mutAuthRevokedRefreshClaim
    (phaseCode opCode fsyncCompleted flockHeld : UInt8)
    (durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
     nowEpoch newExpiryEpoch : UInt64) : UInt8 :=
  if phaseCode == 3 && opCode == 0 then
    verifyAuthRefreshAdmit 0 opCode fsyncCompleted flockHeld
      durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
      nowEpoch newExpiryEpoch
  else
    verifyAuthRefreshAdmit phaseCode opCode fsyncCompleted flockHeld
      durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
      nowEpoch newExpiryEpoch

def mutAuthNonceMismatchStage
    (phaseCode opCode fsyncCompleted flockHeld : UInt8)
    (durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
     nowEpoch newExpiryEpoch : UInt64) : UInt8 :=
  if phaseCode == 1 && opCode == 1 && presentedLoginNonce != expectedLoginNonce then
    verifyAuthRefreshAdmit phaseCode opCode fsyncCompleted flockHeld
      durableAuthGeneration candidateGeneration expectedLoginNonce expectedLoginNonce
      nowEpoch newExpiryEpoch
  else
    verifyAuthRefreshAdmit phaseCode opCode fsyncCompleted flockHeld
      durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
      nowEpoch newExpiryEpoch

def mutAuthCommitWithoutFsyncOrFlock
    (phaseCode opCode fsyncCompleted flockHeld : UInt8)
    (durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
     nowEpoch newExpiryEpoch : UInt64) : UInt8 :=
  if phaseCode == 2 && opCode == 2 && (fsyncCompleted == 0 || flockHeld == 0) then
    verifyAuthRefreshAdmit phaseCode opCode 1 1
      durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
      nowEpoch newExpiryEpoch
  else
    verifyAuthRefreshAdmit phaseCode opCode fsyncCompleted flockHeld
      durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
      nowEpoch newExpiryEpoch

theorem kill_mutAuthRevokedRefreshClaim :
    mutAuthRevokedRefreshClaim 3 0 0 0 4 5 99 99 10 20 ≠
    verifyAuthRefreshAdmit 3 0 0 0 4 5 99 99 10 20 := by
  decide

theorem kill_mutAuthNonceMismatchStage :
    mutAuthNonceMismatchStage 1 1 0 0 4 4 99 77 10 20 ≠
    verifyAuthRefreshAdmit 1 1 0 0 4 4 99 77 10 20 := by
  decide

theorem kill_mutAuthCommitWithoutFsyncOrFlock :
    mutAuthCommitWithoutFsyncOrFlock 2 2 0 1 4 4 0 0 10 20 ≠
    verifyAuthRefreshAdmit 2 2 0 1 4 4 0 0 10 20 := by
  decide

end Orb.HarnessCloudMutants
