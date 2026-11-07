/-
  Orb.LifecycleMutants: Phase R3-A adversarial admission mutants (`0 import Lean`, `0 sorryAx`).

  Three concrete buggy admitters per coordinated lifecycle slice (15 total). Each drops one
  safety fence of the verified `Orb.Lifecycle` scalar admitter, and a `decide` theorem shows
  the mutant accepts a reachable witness the verified admitter rejects.
-/
import Orb.Lifecycle

namespace Orb.LifecycleMutants

open Orb.Lifecycle

/-! ## 1. `MissionLifecycle` -/

/-- Off-by-one `superseded ≤ 1` instead of `superseded == 0`: a superseded owner may resume. -/
def mutMissionSupersededResume
    (phaseCode opCode superseded hasEvidence hasTermReceipt resumeIntent : UInt8)
    (ownerEpoch callerEpoch nowEpoch notBeforeEpoch : UInt64) : UInt8 :=
  if superseded ≤ 1 then
    verifyMissionLifecycleAdmit phaseCode opCode 0 hasEvidence hasTermReceipt resumeIntent
      ownerEpoch callerEpoch nowEpoch notBeforeEpoch
  else 0

/-- Drops the `callerEpoch == ownerEpoch` scoped-authority fence: a foreign caller may act. -/
def mutMissionForeignCaller
    (phaseCode opCode superseded hasEvidence hasTermReceipt resumeIntent : UInt8)
    (ownerEpoch callerEpoch nowEpoch notBeforeEpoch : UInt64) : UInt8 :=
  if callerEpoch != ownerEpoch then
    verifyMissionLifecycleAdmit phaseCode opCode superseded hasEvidence hasTermReceipt resumeIntent
      ownerEpoch ownerEpoch nowEpoch notBeforeEpoch
  else
    verifyMissionLifecycleAdmit phaseCode opCode superseded hasEvidence hasTermReceipt resumeIntent
      ownerEpoch callerEpoch nowEpoch notBeforeEpoch

/-- Drops the `nowEpoch < notBeforeEpoch` clock fence: rate-limit parking accepts a due epoch. -/
def mutMissionParkAlreadyDue
    (phaseCode opCode superseded hasEvidence hasTermReceipt resumeIntent : UInt8)
    (ownerEpoch callerEpoch nowEpoch notBeforeEpoch : UInt64) : UInt8 :=
  if superseded == 0 && ownerEpoch != 0 && callerEpoch == ownerEpoch &&
     phaseCode == 1 && opCode == 3 && resumeIntent == 1 && notBeforeEpoch ≤ nowEpoch
  then 1
  else verifyMissionLifecycleAdmit phaseCode opCode superseded hasEvidence hasTermReceipt
    resumeIntent ownerEpoch callerEpoch nowEpoch notBeforeEpoch

theorem kill_mutMissionSupersededResume :
    mutMissionSupersededResume 0 0 1 0 0 1 5 5 10 20 ≠
    verifyMissionLifecycleAdmit 0 0 1 0 0 1 5 5 10 20 := by
  decide

theorem kill_mutMissionForeignCaller :
    mutMissionForeignCaller 1 1 0 0 0 0 5 9 10 20 ≠
    verifyMissionLifecycleAdmit 1 1 0 0 0 0 5 9 10 20 := by
  decide

theorem kill_mutMissionParkAlreadyDue :
    mutMissionParkAlreadyDue 1 3 0 0 0 1 5 5 30 30 ≠
    verifyMissionLifecycleAdmit 1 3 0 0 0 1 5 5 30 30 := by
  decide

/-! ## 2. `RunLifecycle` -/

/-- Off-by-one `ownerSuperseded ≤ 1` instead of `ownerSuperseded == 0`: a superseded owner opens a run. -/
def mutRunSupersededOpen
    (phaseCode opCode ownerSuperseded hasStructuredReceipt hasAbortReceipt drainTimedOut : UInt8)
    (activeToolCalls : UInt32)
    (currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch : UInt64) : UInt8 :=
  if ownerSuperseded ≤ 1 then
    verifyRunLifecycleAdmit phaseCode opCode 0 hasStructuredReceipt hasAbortReceipt drainTimedOut
      activeToolCalls currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch
  else 0

/-- Drops the `proposedGeneration == currentGeneration + 1` fence: a terminal run re-enters
    `Running` on the same generation. -/
def mutRunReenterSameGeneration
    (phaseCode opCode ownerSuperseded hasStructuredReceipt hasAbortReceipt drainTimedOut : UInt8)
    (activeToolCalls : UInt32)
    (currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch : UInt64) : UInt8 :=
  if ownerSuperseded == 0 && durableOwnerEpoch != 0 && callerOwnerEpoch == durableOwnerEpoch &&
     opCode == 0 && phaseCode == 4 && proposedGeneration == currentGeneration
  then 1
  else verifyRunLifecycleAdmit phaseCode opCode ownerSuperseded hasStructuredReceipt
    hasAbortReceipt drainTimedOut activeToolCalls currentGeneration proposedGeneration
    durableOwnerEpoch callerOwnerEpoch

/-- Drops the `hasStructuredReceipt == 1` fence: a turn completes on prose alone. -/
def mutRunCompleteWithoutReceipt
    (phaseCode opCode ownerSuperseded hasStructuredReceipt hasAbortReceipt drainTimedOut : UInt8)
    (activeToolCalls : UInt32)
    (currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch : UInt64) : UInt8 :=
  if hasStructuredReceipt == 0 then
    verifyRunLifecycleAdmit phaseCode opCode ownerSuperseded 1 hasAbortReceipt drainTimedOut
      activeToolCalls currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch
  else
    verifyRunLifecycleAdmit phaseCode opCode ownerSuperseded hasStructuredReceipt hasAbortReceipt drainTimedOut
      activeToolCalls currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch

theorem kill_mutRunSupersededOpen :
    mutRunSupersededOpen 0 0 1 0 0 0 0 4 5 7 7 ≠
    verifyRunLifecycleAdmit 0 0 1 0 0 0 0 4 5 7 7 := by
  decide

theorem kill_mutRunReenterSameGeneration :
    mutRunReenterSameGeneration 4 0 0 0 0 0 0 8 8 7 7 ≠
    verifyRunLifecycleAdmit 4 0 0 0 0 0 0 8 8 7 7 := by
  decide

theorem kill_mutRunCompleteWithoutReceipt :
    mutRunCompleteWithoutReceipt 2 4 0 0 0 0 0 8 8 7 7 ≠
    verifyRunLifecycleAdmit 2 4 0 0 0 0 0 8 8 7 7 := by
  decide

/-! ## 3. `QueueItemLifecycle` -/

/-- Drops the `phaseCode != 2` replay fence: an acknowledged item is claimed again. -/
def mutQueueAckedReplay
    (phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout operatorConfirmedNotDelivered contentNonEmpty : UInt8)
    (claimedGeneration runGeneration claimBootEpoch nodeBootEpoch deliverySeq : UInt64) : UInt8 :=
  if opCode == 0 && phaseCode == 2 && deferredUnpacked == 1 && runGeneration != 0 && nodeBootEpoch != 0
  then 1
  else verifyQueueItemAdmit phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout
    operatorConfirmedNotDelivered contentNonEmpty claimedGeneration runGeneration claimBootEpoch
    nodeBootEpoch deliverySeq

/-- Drops the `durablyStarted == 1` fence: delivery is confirmed before durable start. -/
def mutQueueConfirmBeforeDurableStart
    (phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout operatorConfirmedNotDelivered contentNonEmpty : UInt8)
    (claimedGeneration runGeneration claimBootEpoch nodeBootEpoch deliverySeq : UInt64) : UInt8 :=
  if durablyStarted == 0 then
    verifyQueueItemAdmit phaseCode opCode deferredUnpacked 1 uncertainTimeout
      operatorConfirmedNotDelivered contentNonEmpty claimedGeneration runGeneration claimBootEpoch
      nodeBootEpoch deliverySeq
  else
    verifyQueueItemAdmit phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout
      operatorConfirmedNotDelivered contentNonEmpty claimedGeneration runGeneration claimBootEpoch
      nodeBootEpoch deliverySeq

/-- Drops the `claimBootEpoch == nodeBootEpoch` fence: a crash-epoch claim confirms delivery. -/
def mutQueueCrossBootConfirm
    (phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout operatorConfirmedNotDelivered contentNonEmpty : UInt8)
    (claimedGeneration runGeneration claimBootEpoch nodeBootEpoch deliverySeq : UInt64) : UInt8 :=
  if opCode == 1 && phaseCode == 1 && claimedGeneration != 0 && claimedGeneration == runGeneration &&
     durablyStarted == 1 && deliverySeq != 0 && nodeBootEpoch != 0 && claimBootEpoch != nodeBootEpoch
  then 1
  else verifyQueueItemAdmit phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout
    operatorConfirmedNotDelivered contentNonEmpty claimedGeneration runGeneration claimBootEpoch
    nodeBootEpoch deliverySeq

theorem kill_mutQueueAckedReplay :
    mutQueueAckedReplay 2 0 1 0 0 0 0 0 9 3 3 1 ≠
    verifyQueueItemAdmit 2 0 1 0 0 0 0 0 9 3 3 1 := by
  decide

theorem kill_mutQueueConfirmBeforeDurableStart :
    mutQueueConfirmBeforeDurableStart 1 1 0 0 0 0 0 9 9 3 3 4 ≠
    verifyQueueItemAdmit 1 1 0 0 0 0 0 9 9 3 3 4 := by
  decide

theorem kill_mutQueueCrossBootConfirm :
    mutQueueCrossBootConfirm 1 1 1 1 0 0 0 9 9 3 8 4 ≠
    verifyQueueItemAdmit 1 1 1 1 0 0 0 9 9 3 8 4 := by
  decide

/-! ## 4. `CancelProtocol` -/

/-- Drops the `runnerTerminatedReceipt == 1` fence: `CancelRequested` jumps to `Cancelled`. -/
def mutCancelWithoutTerminationReceipt
    (phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked : UInt8)
    (targetGeneration receiptGeneration : UInt64) : UInt8 :=
  if runnerTerminatedReceipt == 0 then
    verifyCancelProtocolAdmit phaseCode opCode 1 uncertainDeliveryBlocked targetGeneration receiptGeneration
  else
    verifyCancelProtocolAdmit phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked targetGeneration receiptGeneration

/-- Drops the `receiptGeneration == targetGeneration` fence: a stale receipt cancels. -/
def mutCancelStaleReceipt
    (phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked : UInt8)
    (targetGeneration receiptGeneration : UInt64) : UInt8 :=
  if opCode == 2 && phaseCode == 1 && runnerTerminatedReceipt == 1 &&
     uncertainDeliveryBlocked == 0 && targetGeneration != 0 && receiptGeneration != targetGeneration
  then 1
  else verifyCancelProtocolAdmit phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked
    targetGeneration receiptGeneration

/-- Drops the `uncertainDeliveryBlocked == 0` fence: an uncertain delivery may be cancelled. -/
def mutCancelUncertainDelivery
    (phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked : UInt8)
    (targetGeneration receiptGeneration : UInt64) : UInt8 :=
  if uncertainDeliveryBlocked == 1 then
    verifyCancelProtocolAdmit phaseCode opCode runnerTerminatedReceipt 0 targetGeneration receiptGeneration
  else
    verifyCancelProtocolAdmit phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked targetGeneration receiptGeneration

theorem kill_mutCancelWithoutTerminationReceipt :
    mutCancelWithoutTerminationReceipt 1 2 0 0 6 6 ≠
    verifyCancelProtocolAdmit 1 2 0 0 6 6 := by
  decide

theorem kill_mutCancelStaleReceipt :
    mutCancelStaleReceipt 1 2 1 0 6 5 ≠
    verifyCancelProtocolAdmit 1 2 1 0 6 5 := by
  decide

theorem kill_mutCancelUncertainDelivery :
    mutCancelUncertainDelivery 0 0 0 1 6 0 ≠
    verifyCancelProtocolAdmit 0 0 0 1 6 0 := by
  decide

/-! ## 5. `WakeupContinuation` -/

/-- Drops the `ownerTerminal == 0` fence: a terminal owner arms a wakeup. -/
def mutWakeupArmTerminalOwner
    (phaseCode opCode ownerTerminal ownerBusy : UInt8)
    (armedGeneration currentRunGeneration dueEpoch nowEpoch : UInt64) : UInt8 :=
  if ownerTerminal == 1 then
    verifyWakeupContinuationAdmit phaseCode opCode 0 ownerBusy armedGeneration currentRunGeneration
      dueEpoch nowEpoch
  else
    verifyWakeupContinuationAdmit phaseCode opCode ownerTerminal ownerBusy armedGeneration currentRunGeneration
      dueEpoch nowEpoch

/-- Drops the `dueEpoch ≤ nowEpoch` clock fence: a future wakeup fires early. -/
def mutWakeupFireBeforeDue
    (phaseCode opCode ownerTerminal ownerBusy : UInt8)
    (armedGeneration currentRunGeneration dueEpoch nowEpoch : UInt64) : UInt8 :=
  if opCode == 2 && phaseCode == 1 && ownerTerminal == 0 && ownerBusy == 0 &&
     armedGeneration != 0 && armedGeneration == currentRunGeneration && nowEpoch < dueEpoch
  then 1
  else verifyWakeupContinuationAdmit phaseCode opCode ownerTerminal ownerBusy armedGeneration
    currentRunGeneration dueEpoch nowEpoch

/-- Drops the `armedGeneration == currentRunGeneration` fence: a stale arm fires. -/
def mutWakeupFireStaleGeneration
    (phaseCode opCode ownerTerminal ownerBusy : UInt8)
    (armedGeneration currentRunGeneration dueEpoch nowEpoch : UInt64) : UInt8 :=
  if opCode == 2 && phaseCode == 1 && ownerTerminal == 0 && ownerBusy == 0 &&
     armedGeneration != 0 && armedGeneration < currentRunGeneration && dueEpoch ≤ nowEpoch
  then 1
  else verifyWakeupContinuationAdmit phaseCode opCode ownerTerminal ownerBusy armedGeneration
    currentRunGeneration dueEpoch nowEpoch

theorem kill_mutWakeupArmTerminalOwner :
    mutWakeupArmTerminalOwner 0 0 1 0 0 4 20 10 ≠
    verifyWakeupContinuationAdmit 0 0 1 0 0 4 20 10 := by
  decide

theorem kill_mutWakeupFireBeforeDue :
    mutWakeupFireBeforeDue 1 2 0 0 4 4 20 10 ≠
    verifyWakeupContinuationAdmit 1 2 0 0 4 4 20 10 := by
  decide

theorem kill_mutWakeupFireStaleGeneration :
    mutWakeupFireStaleGeneration 1 2 0 0 3 4 10 20 ≠
    verifyWakeupContinuationAdmit 1 2 0 0 3 4 10 20 := by
  decide

end Orb.LifecycleMutants
