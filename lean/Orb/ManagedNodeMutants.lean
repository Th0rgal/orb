/-
  Orb.ManagedNodeMutants: Phase R5-A adversarial admission mutants (`0 import Lean`, `0 sorryAx`).

   Three or more concrete buggy admitters/steppers per `SM-19`/`SM-20` slice (20 total). Each drops
   one safety fence of the verified `Orb.ManagedNode` gate or reducer, and a `decide` theorem shows
   the mutant accepts a reachable witness the verified specification rejects.
-/
import Orb.ManagedNode

namespace Orb.ManagedNodeMutants

open Orb.ManagedNode

/-! ## 1. `VmLifecycle` (`SM-19`) -/

/-- Drops the `presentedBootEpoch == liveBootEpoch + 1` fence: a stopped VM resumes without
    advancing `node_boot_epoch`. -/
def mutVmResumeSameBoot
    (phaseCode opCode ownerLive idleElapsed : UInt8)
    (liveBootEpoch presentedBootEpoch nowEpoch deletableAt : UInt64) : UInt8 :=
  if opCode == 2 && phaseCode == 2 && liveBootEpoch != 0 &&
     presentedBootEpoch == liveBootEpoch
  then 1
  else verifyVmLifecycleAdmit phaseCode opCode ownerLive idleElapsed liveBootEpoch
    presentedBootEpoch nowEpoch deletableAt

/-- Drops the successor-boot fence on `replace`: a running VM is replaced in place. -/
def mutVmReplaceSameBoot
    (phaseCode opCode ownerLive idleElapsed : UInt8)
    (liveBootEpoch presentedBootEpoch nowEpoch deletableAt : UInt64) : UInt8 :=
  if opCode == 3 && phaseCode == 1 && liveBootEpoch != 0 &&
     presentedBootEpoch == liveBootEpoch
  then 1
  else verifyVmLifecycleAdmit phaseCode opCode ownerLive idleElapsed liveBootEpoch
    presentedBootEpoch nowEpoch deletableAt

/-- Drops the `deletableAt ≤ nowEpoch` retention fence: a running VM is destroyed inside its
    minimum lease. -/
def mutVmDestroyInsideLease
    (phaseCode opCode ownerLive idleElapsed : UInt8)
    (liveBootEpoch presentedBootEpoch nowEpoch deletableAt : UInt64) : UInt8 :=
  if opCode == 4 && phaseCode == 1 && presentedBootEpoch == liveBootEpoch &&
     liveBootEpoch != 0 && ownerLive == 0 && idleElapsed == 1 && nowEpoch < deletableAt
  then 1
  else verifyVmLifecycleAdmit phaseCode opCode ownerLive idleElapsed liveBootEpoch
    presentedBootEpoch nowEpoch deletableAt

/-- Drops the `ownerLive == 0` fence: a live owner may destroy its VM. -/
def mutVmDestroyLiveOwner
    (phaseCode opCode ownerLive idleElapsed : UInt8)
    (liveBootEpoch presentedBootEpoch nowEpoch deletableAt : UInt64) : UInt8 :=
  if ownerLive == 1 then
    verifyVmLifecycleAdmit phaseCode opCode 0 idleElapsed liveBootEpoch presentedBootEpoch
      nowEpoch deletableAt
  else verifyVmLifecycleAdmit phaseCode opCode ownerLive idleElapsed liveBootEpoch
    presentedBootEpoch nowEpoch deletableAt

theorem kill_mutVmResumeSameBoot :
    mutVmResumeSameBoot 2 2 0 0 4 4 10 10 ≠
    verifyVmLifecycleAdmit 2 2 0 0 4 4 10 10 := by
  decide

theorem kill_mutVmReplaceSameBoot :
    mutVmReplaceSameBoot 1 3 0 0 4 4 10 10 ≠
    verifyVmLifecycleAdmit 1 3 0 0 4 4 10 10 := by
  decide

theorem kill_mutVmDestroyInsideLease :
    mutVmDestroyInsideLease 1 4 0 1 4 4 5 10 ≠
    verifyVmLifecycleAdmit 1 4 0 1 4 4 5 10 := by
  decide

theorem kill_mutVmDestroyLiveOwner :
    mutVmDestroyLiveOwner 1 4 1 1 4 4 20 10 ≠
    verifyVmLifecycleAdmit 1 4 1 1 4 4 20 10 := by
  decide

/-! ## 2. `VmClaim` (`SM-19`) -/

/-- Drops the duplicate-reservation fence: a second claim of the same `reservation_id` is
    accepted. -/
def mutClaimDuplicateReservation
    (phaseCode opCode ownerInLineage ownerSuperseded vmLive activeComputeEligible : UInt8)
    (heldReservation presentedReservation nodeBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if opCode == 0 && phaseCode == 1 && ownerInLineage == 1 && ownerSuperseded == 0 &&
     vmLive == 1 && activeComputeEligible == 1 && nodeBootEpoch != 0 &&
     presentedBootEpoch == nodeBootEpoch && presentedReservation == heldReservation &&
     heldReservation != 0
  then 1
  else verifyVmClaimAdmit phaseCode opCode ownerInLineage ownerSuperseded vmLive
    activeComputeEligible heldReservation presentedReservation nodeBootEpoch presentedBootEpoch

/-- Drops the live-and-eligible fence: a `claim` is accepted on a stopped VM. -/
def mutClaimStoppedIneligible
    (phaseCode opCode ownerInLineage ownerSuperseded vmLive activeComputeEligible : UInt8)
    (heldReservation presentedReservation nodeBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if opCode == 0 && phaseCode == 0 && ownerInLineage == 1 && ownerSuperseded == 0 &&
     vmLive == 0 && activeComputeEligible == 0 && nodeBootEpoch != 0 &&
     presentedBootEpoch == nodeBootEpoch && presentedReservation != 0
  then 1
  else verifyVmClaimAdmit phaseCode opCode ownerInLineage ownerSuperseded vmLive
    activeComputeEligible heldReservation presentedReservation nodeBootEpoch presentedBootEpoch

/-- Drops the boot-epoch fence: a `claim` is accepted on a stale boot epoch. -/
def mutClaimStaleBootEpoch
    (phaseCode opCode ownerInLineage ownerSuperseded vmLive activeComputeEligible : UInt8)
    (heldReservation presentedReservation nodeBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if opCode == 0 && phaseCode == 0 && ownerInLineage == 1 && ownerSuperseded == 0 &&
     vmLive == 1 && activeComputeEligible == 1 && nodeBootEpoch != 0 &&
     presentedBootEpoch != nodeBootEpoch && presentedReservation != 0
  then 1
  else verifyVmClaimAdmit phaseCode opCode ownerInLineage ownerSuperseded vmLive
    activeComputeEligible heldReservation presentedReservation nodeBootEpoch presentedBootEpoch

/-- Drops the `ownerSuperseded == 0` fence: a superseded owner may claim. -/
def mutClaimSupersededOwner
    (phaseCode opCode ownerInLineage ownerSuperseded vmLive activeComputeEligible : UInt8)
    (heldReservation presentedReservation nodeBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if ownerSuperseded == 1 then
    verifyVmClaimAdmit phaseCode opCode ownerInLineage 0 vmLive activeComputeEligible
      heldReservation presentedReservation nodeBootEpoch presentedBootEpoch
  else verifyVmClaimAdmit phaseCode opCode ownerInLineage ownerSuperseded vmLive
    activeComputeEligible heldReservation presentedReservation nodeBootEpoch presentedBootEpoch

theorem kill_mutClaimDuplicateReservation :
    mutClaimDuplicateReservation 1 0 1 0 1 1 7 7 4 4 ≠
    verifyVmClaimAdmit 1 0 1 0 1 1 7 7 4 4 := by
  decide

theorem kill_mutClaimStoppedIneligible :
    mutClaimStoppedIneligible 0 0 1 0 0 0 0 7 4 4 ≠
    verifyVmClaimAdmit 0 0 1 0 0 0 0 7 4 4 := by
  decide

theorem kill_mutClaimStaleBootEpoch :
    mutClaimStaleBootEpoch 0 0 1 0 1 1 0 7 4 3 ≠
    verifyVmClaimAdmit 0 0 1 0 1 1 0 7 4 3 := by
  decide

theorem kill_mutClaimSupersededOwner :
    mutClaimSupersededOwner 0 0 1 1 1 1 0 7 4 4 ≠
    verifyVmClaimAdmit 0 0 1 1 1 1 0 7 4 4 := by
  decide

/-! ## 3. `RemoteJobLedger` (`SM-20`) -/

/-- Drops the `operationBootEpoch == nodeBootEpoch` fence: a pre-stop operation id mutates the
    post-resume ledger. -/
def mutJobCrossBoot
    (phaseCode opCode : UInt8)
    (heldOperation presentedOperation operationBootEpoch nodeBootEpoch : UInt64) : UInt8 :=
  if operationBootEpoch != nodeBootEpoch then
    verifyRemoteJobAdmit phaseCode opCode heldOperation presentedOperation nodeBootEpoch
      nodeBootEpoch
  else verifyRemoteJobAdmit phaseCode opCode heldOperation presentedOperation operationBootEpoch
    nodeBootEpoch

/-- Drops the sticky-`uncertain` fence: an uncertain delivery is retried fresh. -/
def mutJobRetryUncertain
    (phaseCode opCode : UInt8)
    (heldOperation presentedOperation operationBootEpoch nodeBootEpoch : UInt64) : UInt8 :=
  if opCode == 5 && phaseCode == 2 && nodeBootEpoch != 0 &&
     operationBootEpoch == nodeBootEpoch && heldOperation != 0 &&
     presentedOperation == heldOperation
  then 1
  else verifyRemoteJobAdmit phaseCode opCode heldOperation presentedOperation operationBootEpoch
    nodeBootEpoch

/-- Drops the first-terminal-wins fence: a succeeded job is failed again. -/
def mutJobSecondTerminal
    (phaseCode opCode : UInt8)
    (heldOperation presentedOperation operationBootEpoch nodeBootEpoch : UInt64) : UInt8 :=
  if opCode == 3 && phaseCode == 3 && nodeBootEpoch != 0 &&
     operationBootEpoch == nodeBootEpoch && heldOperation != 0 &&
     presentedOperation == heldOperation
  then 1
  else verifyRemoteJobAdmit phaseCode opCode heldOperation presentedOperation operationBootEpoch
    nodeBootEpoch

/-- Drops the `ev.operationBootEpoch == s.operationBoot` fence in `stepJobSlice`: substitutes the
    stored `s.operationBoot` in place of the event's `ev.operationBootEpoch` when `phaseCode != 0`,
    admitting an event whose `operationBootEpoch` disagrees with `s.operationBoot`. -/
def mutStepJobIgnorePresentedOperationBoot (s : JobSliceState) (ev : JobSliceEvent) :
    JobSliceState × List JobEffect :=
  let effBoot : UInt64 := if s.phaseCode == 0 then ev.operationBootEpoch else s.operationBoot
  if verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
       effBoot ev.nodeBootEpoch == 1 then
    let nextPhase := remoteJobTargetPhase ev.opCode
    let nextOp : UInt64 :=
      if ev.opCode == 0 || ev.opCode == 10 then ev.presentedOperation else s.operationId
    let effs : List JobEffect :=
      if ev.opCode == 2 || ev.opCode == 3 || ev.opCode == 4 ||
         ev.opCode == 7 || ev.opCode == 8 || ev.opCode == 9 then
        [.persistJob nextPhase nextOp effBoot, .recordTerminal nextPhase nextOp]
      else
        [.persistJob nextPhase nextOp effBoot]
    ({ phaseCode := nextPhase, operationId := nextOp, operationBoot := effBoot }, effs)
  else
    (s, [])

/-- Drops the `presentedOperation > heldOperation` fence on `confirmNotDeliveredRetry` (`opCode = 10`):
    reuses the uncertain `heldOperation` on a retry attempt. -/
def mutJobNotDeliveredRetrySameOperation
    (phaseCode opCode : UInt8)
    (heldOperation presentedOperation operationBootEpoch nodeBootEpoch : UInt64) : UInt8 :=
  if opCode == 10 && phaseCode == 2 && nodeBootEpoch != 0 &&
     operationBootEpoch == nodeBootEpoch && heldOperation != 0 &&
     presentedOperation == heldOperation
  then 1
  else verifyRemoteJobAdmit phaseCode opCode heldOperation presentedOperation operationBootEpoch
    nodeBootEpoch

theorem kill_mutJobCrossBoot :
    mutJobCrossBoot 1 2 9 9 3 4 ≠
    verifyRemoteJobAdmit 1 2 9 9 3 4 := by
  decide

theorem kill_mutJobRetryUncertain :
    mutJobRetryUncertain 2 5 9 9 4 4 ≠
    verifyRemoteJobAdmit 2 5 9 9 4 4 := by
  decide

theorem kill_mutJobSecondTerminal :
    mutJobSecondTerminal 3 3 9 9 4 4 ≠
    verifyRemoteJobAdmit 3 3 9 9 4 4 := by
  decide

theorem kill_mutStepJobIgnorePresentedOperationBoot :
    mutStepJobIgnorePresentedOperationBoot
      { phaseCode := 1, operationId := 9, operationBoot := 4 }
      { opCode := 2, operationBootEpoch := 3, nodeBootEpoch := 4, presentedOperation := 9 } ≠
    stepJobSlice
      { phaseCode := 1, operationId := 9, operationBoot := 4 }
      { opCode := 2, operationBootEpoch := 3, nodeBootEpoch := 4, presentedOperation := 9 } := by
  decide

theorem kill_mutJobNotDeliveredRetrySameOperation :
    mutJobNotDeliveredRetrySameOperation 2 10 9 9 4 4 ≠
    verifyRemoteJobAdmit 2 10 9 9 4 4 := by
  decide

/-! ## 4. `ProcessLiveness` (`SM-20`) -/

/-- Drops the `actualTicks == expectedTicks` fence: `SIGTERM` is admitted on mismatched ticks. -/
def mutProcSigtermMismatchedTicks
    (phaseCode opCode procMissing isZombie : UInt8)
    (expectedPid actualPid : UInt32)
    (expectedTicks actualTicks : UInt64) : UInt8 :=
  if opCode == 2 && phaseCode == 1 && procMissing == 0 && isZombie == 0 &&
     expectedPid != 0 && expectedTicks != 0 && actualPid == expectedPid &&
     actualTicks != expectedTicks
  then 1
  else verifyProcLivenessAdmit phaseCode opCode procMissing isZombie expectedPid actualPid
    expectedTicks actualTicks

/-- Drops the `actualPid == expectedPid` fence on `termSent (3) -> sigkill (3)` escalation:
    `SIGKILL` is admitted on a different pid. -/
def mutProcSigkillMismatchedPid
    (phaseCode opCode procMissing isZombie : UInt8)
    (expectedPid actualPid : UInt32)
    (expectedTicks actualTicks : UInt64) : UInt8 :=
  if opCode == 3 && phaseCode == 3 && procMissing == 0 && isZombie == 0 &&
     expectedPid != 0 && expectedTicks != 0 && actualPid != expectedPid &&
     actualTicks == expectedTicks
  then 1
  else verifyProcLivenessAdmit phaseCode opCode procMissing isZombie expectedPid actualPid
    expectedTicks actualTicks

/-- Drops the `(pid, start_ticks)` recheck on `termSent (3) -> sigkill (3)` escalation: escalates to
    `SIGKILL` after PID reuse (`actualTicks != expectedTicks`). -/
def mutProcTermSentSigkillSkipTicksRecheck
    (phaseCode opCode procMissing isZombie : UInt8)
    (expectedPid actualPid : UInt32)
    (expectedTicks actualTicks : UInt64) : UInt8 :=
  if opCode == 3 && phaseCode == 3 && procMissing == 0 && isZombie == 0 &&
     expectedPid != 0 && expectedTicks != 0 && actualPid == expectedPid &&
     actualTicks != expectedTicks
  then 1
  else verifyProcLivenessAdmit phaseCode opCode procMissing isZombie expectedPid actualPid
    expectedTicks actualTicks

/-- Drops the `isZombie == 0` fence: a zombie is observed alive. -/
def mutProcZombieObservedAlive
    (phaseCode opCode procMissing isZombie : UInt8)
    (expectedPid actualPid : UInt32)
    (expectedTicks actualTicks : UInt64) : UInt8 :=
  if isZombie == 1 then
    verifyProcLivenessAdmit phaseCode opCode procMissing 0 expectedPid actualPid expectedTicks
      actualTicks
  else verifyProcLivenessAdmit phaseCode opCode procMissing isZombie expectedPid actualPid
    expectedTicks actualTicks

theorem kill_mutProcSigtermMismatchedTicks :
    mutProcSigtermMismatchedTicks 1 2 0 0 42 42 1000 1001 ≠
    verifyProcLivenessAdmit 1 2 0 0 42 42 1000 1001 := by
  decide

theorem kill_mutProcSigkillMismatchedPid :
    mutProcSigkillMismatchedPid 3 3 0 0 42 43 1000 1000 ≠
    verifyProcLivenessAdmit 3 3 0 0 42 43 1000 1000 := by
  decide

theorem kill_mutProcTermSentSigkillSkipTicksRecheck :
    mutProcTermSentSigkillSkipTicksRecheck 3 3 0 0 42 42 1000 1001 ≠
    verifyProcLivenessAdmit 3 3 0 0 42 42 1000 1001 := by
  decide

theorem kill_mutProcZombieObservedAlive :
    mutProcZombieObservedAlive 1 0 0 1 42 42 1000 1000 ≠
    verifyProcLivenessAdmit 1 0 0 1 42 42 1000 1000 := by
  decide

/-! ## 5. `RelayCommand` (`SM-19`) -/

/-- Drops the no-pop-before-ack fence: an `ack` is accepted before any lease is held. -/
def mutRelayAckWithoutLease
    (phaseCode opCode : UInt8)
    (heldLeaseId presentedLeaseId liveBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if opCode == 1 && phaseCode == 0 && heldLeaseId == 0 && presentedLeaseId != 0 &&
     liveBootEpoch != 0 && presentedBootEpoch == liveBootEpoch
  then 1
  else verifyRelayCommandAdmit phaseCode opCode heldLeaseId presentedLeaseId liveBootEpoch
    presentedBootEpoch

/-- Drops the sticky-`uncertain` fence: a fresh `retry` is accepted from `Uncertain`. -/
def mutRelayRetryFromUncertain
    (phaseCode opCode : UInt8)
    (heldLeaseId presentedLeaseId liveBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if opCode == 4 && phaseCode == 3 && heldLeaseId != 0 && presentedLeaseId == heldLeaseId &&
     liveBootEpoch != 0 && presentedBootEpoch == liveBootEpoch
  then 1
  else verifyRelayCommandAdmit phaseCode opCode heldLeaseId presentedLeaseId liveBootEpoch
    presentedBootEpoch

/-- Drops the boot-epoch fence: an `ack` is accepted on a stale boot epoch. -/
def mutRelayCrossBootAck
    (phaseCode opCode : UInt8)
    (heldLeaseId presentedLeaseId liveBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if opCode == 1 && phaseCode == 1 && heldLeaseId != 0 && presentedLeaseId == heldLeaseId &&
     liveBootEpoch != 0 && presentedBootEpoch != liveBootEpoch
  then 1
  else verifyRelayCommandAdmit phaseCode opCode heldLeaseId presentedLeaseId liveBootEpoch
    presentedBootEpoch

theorem kill_mutRelayAckWithoutLease :
    mutRelayAckWithoutLease 0 1 0 9 4 4 ≠
    verifyRelayCommandAdmit 0 1 0 9 4 4 := by
  decide

theorem kill_mutRelayRetryFromUncertain :
    mutRelayRetryFromUncertain 3 4 9 9 4 4 ≠
    verifyRelayCommandAdmit 3 4 9 9 4 4 := by
  decide

theorem kill_mutRelayCrossBootAck :
    mutRelayCrossBootAck 1 1 9 9 4 3 ≠
    verifyRelayCommandAdmit 1 1 9 9 4 3 := by
  decide

end Orb.ManagedNodeMutants
