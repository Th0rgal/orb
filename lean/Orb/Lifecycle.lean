/-
  Orb.Lifecycle: Phase R3-A Coordinated Orthogonal Lifecycle Steppers & SpecBlocks
  (`0 import Lean`, `0 sorryAx`).

  Formalizes the 5 coordinated mission-execution slices (`plan.md` §Phase R3-A):
    1. `MissionLifecycle`   (`SM-01`, `SM-06`, `SM-09`)
    2. `RunLifecycle`       (`SM-03`, `SM-10`)
    3. `QueueItemLifecycle` (`SM-04`, `SM-05`, `G-ORB-2`)
    4. `CancelProtocol`     (`SM-03`, `SM-14`)
    5. `WakeupContinuation` (`SM-07`)

  Each slice exposes:
    - Typed protocol phase/op ADTs with explicit `decode?` / `encode` roundtrips.
    - Pure scalar admission & transition steppers suitable for SQLite CAS transactions in `OrbCore`.
    - Pure slice reducers (`State -> Event -> State × List Effect`) composed over `R3WorldState`
      via `Orb.Spec.SpecBlock` with disjoint 64-bit footprints.
-/
import Orb.Spec

namespace Orb.Lifecycle

open Orb.Spec

/-! ## 1. `MissionLifecycle` (`SM-01`, `SM-06`, `SM-09`) -/

inductive MissionPhase where
  | awaitingUser
  | active
  | waitingBackground
  | waitingRateLimit
  | interrupted
  | completed
  | failed
  | cancelled
  deriving Repr, DecidableEq

def MissionPhase.encode : MissionPhase → UInt8
  | .awaitingUser      => 0
  | .active            => 1
  | .waitingBackground => 2
  | .waitingRateLimit  => 3
  | .interrupted       => 4
  | .completed         => 5
  | .failed            => 6
  | .cancelled         => 7

def MissionPhase.decode? : Nat → Option MissionPhase
  | 0 => some .awaitingUser
  | 1 => some .active
  | 2 => some .waitingBackground
  | 3 => some .waitingRateLimit
  | 4 => some .interrupted
  | 5 => some .completed
  | 6 => some .failed
  | 7 => some .cancelled
  | _ => none

def MissionPhase.isTerminal : MissionPhase → Bool
  | .completed | .failed | .cancelled => true
  | _ => false

inductive MissionOp where
  | dispatchRun
  | parkAwaitingUser
  | parkBackground
  | parkRateLimit
  | resumeRateLimit
  | markInterrupted
  | completeWithReceipt
  | failRun
  | finalizeCancelReceipt
  deriving Repr, DecidableEq

def MissionOp.encode : MissionOp → UInt8
  | .dispatchRun           => 0
  | .parkAwaitingUser      => 1
  | .parkBackground        => 2
  | .parkRateLimit         => 3
  | .resumeRateLimit       => 4
  | .markInterrupted       => 5
  | .completeWithReceipt   => 6
  | .failRun               => 7
  | .finalizeCancelReceipt => 8

def MissionOp.decode? : Nat → Option MissionOp
  | 0 => some .dispatchRun
  | 1 => some .parkAwaitingUser
  | 2 => some .parkBackground
  | 3 => some .parkRateLimit
  | 4 => some .resumeRateLimit
  | 5 => some .markInterrupted
  | 6 => some .completeWithReceipt
  | 7 => some .failRun
  | 8 => some .finalizeCancelReceipt
  | _ => none

/-- Pure admission gate for `MissionLifecycle` transitions:
    - Terminal missions (`phase >= 5`), superseded missions (`superseded == 1`), and
      unmatched owner epochs (`callerEpoch != ownerEpoch` or `ownerEpoch == 0`) never admit mutations.
    - `resumeRateLimit` (`op == 4`) requires `phase == 3` (`waitingRateLimit`), `resumeIntent == 1`,
      and `notBeforeEpoch <= nowEpoch` (`SM-06` unified local/remote quota wait).
    - `completeWithReceipt` (`op == 6`) requires `phase == 1` and structured `hasEvidence == 1` (`SM-01`, `SM-03`).
    - `finalizeCancelReceipt` (`op == 8`) requires explicit `hasTermReceipt == 1` (`SM-03`). -/
@[inline]
def verifyMissionLifecycleAdmit
    (phaseCode opCode superseded hasEvidence hasTermReceipt resumeIntent : UInt8)
    (ownerEpoch callerEpoch nowEpoch notBeforeEpoch : UInt64) : UInt8 :=
  if superseded == 0 &&
     ownerEpoch != 0 &&
     callerEpoch == ownerEpoch &&
     phaseCode ≤ 4 &&
     opCode ≤ 8 &&
     ((opCode == 0 && (phaseCode == 0 || phaseCode == 2 || phaseCode == 4)) ||
      (opCode == 1 && phaseCode == 1) ||
      (opCode == 2 && phaseCode == 1) ||
      (opCode == 3 && phaseCode == 1 && nowEpoch < notBeforeEpoch && resumeIntent == 1) ||
      (opCode == 4 && phaseCode == 3 && resumeIntent == 1 && notBeforeEpoch ≤ nowEpoch) ||
      (opCode == 5 && (phaseCode == 1 || phaseCode == 2 || phaseCode == 3)) ||
      (opCode == 6 && phaseCode == 1 && hasEvidence == 1) ||
      (opCode == 7 && (phaseCode == 1 || phaseCode == 2 || phaseCode == 3 || phaseCode == 4)) ||
      (opCode == 8 && (phaseCode == 0 || phaseCode == 1 || phaseCode == 2 || phaseCode == 3 || phaseCode == 4) &&
       hasTermReceipt == 1))
  then 1 else 0

@[inline]
def missionLifecycleTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 0
  else if opCode == 2 then 2
  else if opCode == 3 then 3
  else if opCode == 4 then 1
  else if opCode == 5 then 4
  else if opCode == 6 then 5
  else if opCode == 7 then 6
  else 7

structure MissionSliceState where
  phaseCode      : UInt8
  superseded     : UInt8
  resumeIntent   : UInt8
  ownerEpoch     : UInt64
  notBeforeEpoch : UInt64
  stateRevision  : UInt32
  deriving Repr, DecidableEq

structure MissionSliceEvent where
  opCode         : UInt8
  hasEvidence    : UInt8
  hasTermReceipt : UInt8
  reqResumeInt   : UInt8
  callerEpoch    : UInt64
  nowEpoch       : UInt64
  reqNotBefore   : UInt64
  markSuperseded : UInt8
  deriving Repr, DecidableEq

inductive MissionEffect where
  | persistMissionPhase (nextPhase : UInt8) (nextRevision : UInt32)
  | recordTerminalEvidence (nextPhase : UInt8)
  | scheduleRateLimitWake (notBeforeEpoch : UInt64)
  deriving Repr, DecidableEq

def stepMissionSlice (s : MissionSliceState) (ev : MissionSliceEvent) :
    MissionSliceState × List MissionEffect :=
  let effResume := if ev.opCode == 3 then ev.reqResumeInt else s.resumeIntent
  let effNotBefore := if ev.opCode == 3 then ev.reqNotBefore else s.notBeforeEpoch
  if ev.markSuperseded == 1 && s.superseded == 0 && s.phaseCode ≤ 4 &&
     s.ownerEpoch != 0 && ev.callerEpoch == s.ownerEpoch && s.stateRevision < 0xFFFFFFFF then
    let nextRev := s.stateRevision + 1
    ({ s with superseded := 1, stateRevision := nextRev },
     [.persistMissionPhase s.phaseCode nextRev])
  else if verifyMissionLifecycleAdmit s.phaseCode ev.opCode s.superseded ev.hasEvidence
            ev.hasTermReceipt effResume s.ownerEpoch ev.callerEpoch ev.nowEpoch effNotBefore == 1 &&
          s.stateRevision < 0xFFFFFFFF then
    let nextPhase := missionLifecycleTargetPhase ev.opCode
    let nextRev := s.stateRevision + 1
    let nextResume : UInt8 := if ev.opCode == 3 then 1 else if ev.opCode == 4 || nextPhase ≥ 5 then 0 else s.resumeIntent
    let nextNb : UInt64 := if ev.opCode == 3 then ev.reqNotBefore else if ev.opCode == 4 || nextPhase ≥ 5 then 0 else s.notBeforeEpoch
    let effs : List MissionEffect :=
      if ev.opCode == 3 then
        [.persistMissionPhase nextPhase nextRev, .scheduleRateLimitWake ev.reqNotBefore]
      else if nextPhase ≥ 5 then
        [.persistMissionPhase nextPhase nextRev, .recordTerminalEvidence nextPhase]
      else
        [.persistMissionPhase nextPhase nextRev]
    ({ s with
        phaseCode := nextPhase
        resumeIntent := nextResume
        notBeforeEpoch := nextNb
        stateRevision := nextRev }, effs)
  else
    (s, [])

/-! ## 2. `RunLifecycle` (`SM-03`, `SM-10`) -/

inductive RunPhase where
  | idle
  | claimed
  | running
  | drainingTools
  | completed
  | failed
  | aborted
  deriving Repr, DecidableEq

def RunPhase.encode : RunPhase → UInt8
  | .idle          => 0
  | .claimed       => 1
  | .running       => 2
  | .drainingTools => 3
  | .completed     => 4
  | .failed        => 5
  | .aborted       => 6

def RunPhase.decode? : Nat → Option RunPhase
  | 0 => some .idle
  | 1 => some .claimed
  | 2 => some .running
  | 3 => some .drainingTools
  | 4 => some .completed
  | 5 => some .failed
  | 6 => some .aborted
  | _ => none

def RunPhase.isTerminal : RunPhase → Bool
  | .completed | .failed | .aborted => true
  | _ => false

inductive RunOp where
  | claimFreshGeneration
  | confirmSpawned
  | enterToolDrain
  | reconcileDrainedTools
  | completeTurnReceipt
  | failTurn
  | abortTurnReceipt
  deriving Repr, DecidableEq

def RunOp.encode : RunOp → UInt8
  | .claimFreshGeneration  => 0
  | .confirmSpawned        => 1
  | .enterToolDrain        => 2
  | .reconcileDrainedTools => 3
  | .completeTurnReceipt   => 4
  | .failTurn              => 5
  | .abortTurnReceipt      => 6

def RunOp.decode? : Nat → Option RunOp
  | 0 => some .claimFreshGeneration
  | 1 => some .confirmSpawned
  | 2 => some .enterToolDrain
  | 3 => some .reconcileDrainedTools
  | 4 => some .completeTurnReceipt
  | 5 => some .failTurn
  | 6 => some .abortTurnReceipt
  | _ => none

/-- Pure admission gate for `RunLifecycle` transitions (`SM-03`, `SM-10`):
    - Superseded owners (`ownerSuperseded == 1`) or stale owner epochs (`callerOwnerEpoch != durableOwnerEpoch`)
      are strictly forbidden from claiming or mutating runs.
     - Terminal runs (`phaseCode >= 4`) and `idle` (`phaseCode == 0`) can enter `claimed` (`opCode == 0`)
       ONLY when `proposedGeneration.toNat = currentGeneration.toNat + 1` with no `UInt64` wrap
       (`currentGeneration < proposedGeneration` and their difference is exactly 1). A completed run
       NEVER re-enters `running` at the same `run_generation`.
    - In-flight transitions (`opCode >= 1`) require `proposedGeneration == currentGeneration` and `currentGeneration != 0`.
    - `completeTurnReceipt` (`opCode == 4`) requires structured `hasStructuredReceipt == 1` and `activeToolCalls == 0`.
    - `reconcileDrainedTools` (`opCode == 3`) bounds wedged `activeToolCalls` when `activeToolCalls == 0 || drainTimedOut == 1`. -/
@[inline]
def verifyRunLifecycleAdmit
    (phaseCode opCode ownerSuperseded hasStructuredReceipt hasAbortReceipt drainTimedOut : UInt8)
    (activeToolCalls : UInt32)
    (currentGeneration proposedGeneration durableOwnerEpoch callerOwnerEpoch : UInt64) : UInt8 :=
  if ownerSuperseded == 0 &&
     durableOwnerEpoch != 0 &&
     callerOwnerEpoch == durableOwnerEpoch &&
     phaseCode ≤ 6 &&
     opCode ≤ 6 &&
      ((opCode == 0 && (phaseCode == 0 || phaseCode ≥ 4) &&
       currentGeneration < 0xFFFFFFFFFFFFFFFF &&
       currentGeneration < proposedGeneration &&
       proposedGeneration - currentGeneration == 1) ||
      (opCode ≥ 1 && currentGeneration != 0 && proposedGeneration == currentGeneration &&
       ((opCode == 1 && phaseCode == 1) ||
        (opCode == 2 && phaseCode == 2 && activeToolCalls > 0) ||
        (opCode == 3 && phaseCode == 3 && (activeToolCalls == 0 || drainTimedOut == 1)) ||
        (opCode == 4 && phaseCode == 2 && activeToolCalls == 0 && hasStructuredReceipt == 1) ||
        (opCode == 5 && (phaseCode == 1 || phaseCode == 2 || phaseCode == 3)) ||
        (opCode == 6 && (phaseCode == 1 || phaseCode == 2 || phaseCode == 3) && hasAbortReceipt == 1))))
  then 1 else 0

@[inline]
def runLifecycleTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 3
  else if opCode == 3 then 2
  else if opCode == 4 then 4
  else if opCode == 5 then 5
  else 6

structure RunSliceState where
  phaseCode         : UInt8
  ownerSuperseded   : UInt8
  activeToolCalls   : UInt32
  runGeneration     : UInt64
  durableOwnerEpoch : UInt64
  deriving Repr, DecidableEq

structure RunSliceEvent where
  opCode               : UInt8
  hasStructuredReceipt : UInt8
  hasAbortReceipt      : UInt8
  drainTimedOut        : UInt8
  markOwnerSuperseded  : UInt8 := 0
  nextToolCalls        : UInt32
  proposedGeneration   : UInt64
  callerOwnerEpoch     : UInt64
  deriving Repr, DecidableEq

inductive RunEffect where
  | spawnHarnessRun (generation : UInt64)
  | persistRunPhase (phaseCode : UInt8) (generation : UInt64)
  | clearWedgedToolCalls (generation : UInt64)
  deriving Repr, DecidableEq

def stepRunSlice (s : RunSliceState) (ev : RunSliceEvent) :
    RunSliceState × List RunEffect :=
  let effTools := if ev.opCode == 2 then ev.nextToolCalls else s.activeToolCalls
  if ev.markOwnerSuperseded == 1 && s.ownerSuperseded == 0 &&
     s.durableOwnerEpoch != 0 && ev.callerOwnerEpoch == s.durableOwnerEpoch then
    ({ s with ownerSuperseded := 1 }, [.persistRunPhase s.phaseCode s.runGeneration])
  else if ev.markOwnerSuperseded == 0 &&
          verifyRunLifecycleAdmit s.phaseCode ev.opCode s.ownerSuperseded
            ev.hasStructuredReceipt ev.hasAbortReceipt ev.drainTimedOut
            effTools s.runGeneration ev.proposedGeneration
            s.durableOwnerEpoch ev.callerOwnerEpoch == 1 then
    let nextPhase := runLifecycleTargetPhase ev.opCode
    let nextGen := if ev.opCode == 0 then ev.proposedGeneration else s.runGeneration
    let nextTools : UInt32 :=
      if ev.opCode == 2 then ev.nextToolCalls
      else if ev.opCode == 0 || ev.opCode == 3 || nextPhase ≥ 4 then 0
      else s.activeToolCalls
    let effs : List RunEffect :=
      if ev.opCode == 0 then
        [.persistRunPhase nextPhase nextGen, .spawnHarnessRun nextGen]
      else if ev.opCode == 3 && ev.drainTimedOut == 1 then
        [.clearWedgedToolCalls nextGen, .persistRunPhase nextPhase nextGen]
      else
        [.persistRunPhase nextPhase nextGen]
    ({ s with
        phaseCode := nextPhase
        activeToolCalls := nextTools
        runGeneration := nextGen }, effs)
  else
    (s, [])

def foldRunSlice (s : RunSliceState) (evs : List RunSliceEvent) : RunSliceState :=
  evs.foldl (fun acc ev => (stepRunSlice acc ev).1) s

/-! ## 3. `QueueItemLifecycle` (`SM-04`, `SM-05`, `G-ORB-2`) -/

inductive QueueItemPhase where
  | queued
  | claimed
  | delivered
  | crashTombstone
  | cancelled
  deriving Repr, DecidableEq

def QueueItemPhase.encode : QueueItemPhase → UInt8
  | .queued         => 0
  | .claimed        => 1
  | .delivered      => 2
  | .crashTombstone => 3
  | .cancelled      => 4

def QueueItemPhase.decode? : Nat → Option QueueItemPhase
  | 0 => some .queued
  | 1 => some .claimed
  | 2 => some .delivered
  | 3 => some .crashTombstone
  | 4 => some .cancelled
  | _ => none

def QueueItemPhase.isAckedOrRetired : QueueItemPhase → Bool
  | .delivered | .cancelled => true
  | _ => false

inductive QueueItemOp where
  | claimForRun
  | confirmDelivered
  | releaseRejected
  | markCrashTombstone
  | requeueTombstone
  | cancelQueued
  | editQueuedContent
  deriving Repr, DecidableEq

def QueueItemOp.encode : QueueItemOp → UInt8
  | .claimForRun        => 0
  | .confirmDelivered   => 1
  | .releaseRejected    => 2
  | .markCrashTombstone => 3
  | .requeueTombstone   => 4
  | .cancelQueued       => 5
  | .editQueuedContent  => 6

def QueueItemOp.decode? : Nat → Option QueueItemOp
  | 0 => some .claimForRun
  | 1 => some .confirmDelivered
  | 2 => some .releaseRejected
  | 3 => some .markCrashTombstone
  | 4 => some .requeueTombstone
  | 5 => some .cancelQueued
  | 6 => some .editQueuedContent
  | _ => none

/-- Pure admission gate for `QueueItemLifecycle` (`SM-04`, `SM-05`, `G-ORB-2`):
    - Once acknowledged (`phaseCode == 2`, `delivered`) or `cancelled` (`phaseCode == 4`),
      NO operation is ever admitted (acknowledged queue items CANNOT replay, be edited, or be re-claimed).
    - `claimForRun` (`opCode == 0`) requires `phaseCode == 0` (`queued`), `runGeneration != 0`,
      and `deferredUnpacked == 1` (`SM-05` structured deferred batches unpacked uniformly before claim).
    - `confirmDelivered` (`opCode == 1`) requires `phaseCode == 1`, `claimedGeneration == runGeneration`,
      `durablyStarted == 1`, and `deliverySeq != 0`.
    - `markCrashTombstone` (`opCode == 3`) transitions `claimed` (`1`) to `crashTombstone` (`3`) when
      either `claimBootEpoch != nodeBootEpoch` (restart boundary) or `uncertainTimeout == 1`.
    - `requeueTombstone` (`opCode == 4`) requires explicit `operatorConfirmedNotDelivered == 1` on `phaseCode == 3`. -/
@[inline]
def verifyQueueItemAdmit
    (phaseCode opCode deferredUnpacked durablyStarted uncertainTimeout operatorConfirmedNotDelivered contentNonEmpty : UInt8)
    (claimedGeneration runGeneration claimBootEpoch nodeBootEpoch deliverySeq : UInt64) : UInt8 :=
  if phaseCode ≤ 4 &&
     opCode ≤ 6 &&
     phaseCode != 2 &&
     phaseCode != 4 &&
     nodeBootEpoch != 0 &&
     ((opCode == 0 && phaseCode == 0 && deferredUnpacked == 1 && runGeneration != 0) ||
      (opCode == 1 && phaseCode == 1 && claimedGeneration != 0 &&
       claimedGeneration == runGeneration && claimBootEpoch == nodeBootEpoch &&
       durablyStarted == 1 && deliverySeq != 0) ||
      (opCode == 2 && phaseCode == 1 && claimedGeneration != 0 &&
       claimedGeneration == runGeneration && uncertainTimeout == 0) ||
      (opCode == 3 && phaseCode == 1 &&
       (claimBootEpoch != nodeBootEpoch || uncertainTimeout == 1)) ||
      (opCode == 4 && phaseCode == 3 && operatorConfirmedNotDelivered == 1) ||
      (opCode == 5 && phaseCode == 0) ||
      (opCode == 6 && phaseCode == 0 && contentNonEmpty == 1))
  then 1 else 0

@[inline]
def queueItemTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 0
  else if opCode == 3 then 3
  else if opCode == 4 then 0
  else if opCode == 5 then 4
  else 0

structure QueueSliceState where
  phaseCode         : UInt8
  claimedGeneration : UInt64
  claimBootEpoch    : UInt64
  deliveredSeq      : UInt64
  editRevision      : UInt32
  deriving Repr, DecidableEq

structure QueueSliceEvent where
  opCode                        : UInt8
  deferredUnpacked              : UInt8
  durablyStarted                : UInt8
  uncertainTimeout              : UInt8
  operatorConfirmedNotDelivered : UInt8
  contentNonEmpty               : UInt8
  runGeneration                 : UInt64
  nodeBootEpoch                 : UInt64
  deliverySeq                   : UInt64
  deriving Repr, DecidableEq

inductive QueueEffect where
  | persistQueuePhase (nextPhase : UInt8) (claimedGen : UInt64) (deliveredSeq : UInt64)
  | emitEditedMessageEvent (editRevision : UInt32)
  deriving Repr, DecidableEq

def stepQueueSlice (s : QueueSliceState) (ev : QueueSliceEvent) :
    QueueSliceState × List QueueEffect :=
  if verifyQueueItemAdmit s.phaseCode ev.opCode ev.deferredUnpacked ev.durablyStarted
       ev.uncertainTimeout ev.operatorConfirmedNotDelivered ev.contentNonEmpty
       s.claimedGeneration ev.runGeneration s.claimBootEpoch ev.nodeBootEpoch ev.deliverySeq == 1 &&
     s.editRevision < 0xFFFFFFFF then
    let nextPhase := queueItemTargetPhase ev.opCode
    let nextClaimGen : UInt64 :=
      if ev.opCode == 0 then ev.runGeneration
      else if nextPhase == 0 || nextPhase == 4 then 0
      else s.claimedGeneration
    let nextBoot : UInt64 :=
      if ev.opCode == 0 then ev.nodeBootEpoch
      else if nextPhase == 0 || nextPhase == 4 then 0
      else s.claimBootEpoch
    let nextDelivSeq : UInt64 :=
      if ev.opCode == 1 then ev.deliverySeq else s.deliveredSeq
    let nextEditRev : UInt32 :=
      if ev.opCode == 6 then s.editRevision + 1 else s.editRevision
    let effs : List QueueEffect :=
      if ev.opCode == 6 then
        [.persistQueuePhase nextPhase nextClaimGen nextDelivSeq, .emitEditedMessageEvent nextEditRev]
      else
        [.persistQueuePhase nextPhase nextClaimGen nextDelivSeq]
    ({ phaseCode := nextPhase
       claimedGeneration := nextClaimGen
       claimBootEpoch := nextBoot
       deliveredSeq := nextDelivSeq
       editRevision := nextEditRev }, effs)
  else
    (s, [])

/-! ## 4. `CancelProtocol` (`SM-03`, `SM-14`) -/

inductive CancelPhase where
  | none
  | cancelRequested
  | signalDispatched
  | cancelled
  deriving Repr, DecidableEq

def CancelPhase.encode : CancelPhase → UInt8
  | .none             => 0
  | .cancelRequested  => 1
  | .signalDispatched => 2
  | .cancelled        => 3

def CancelPhase.decode? : Nat → Option CancelPhase
  | 0 => some .none
  | 1 => some .cancelRequested
  | 2 => some .signalDispatched
  | 3 => some .cancelled
  | _ => Option.none

inductive CancelOp where
  | requestCancel
  | dispatchKillSignal
  | confirmTerminatedReceipt
  | resetForNewRun
  deriving Repr, DecidableEq

def CancelOp.encode : CancelOp → UInt8
  | .requestCancel            => 0
  | .dispatchKillSignal       => 1
  | .confirmTerminatedReceipt => 2
  | .resetForNewRun           => 3

def CancelOp.decode? : Nat → Option CancelOp
  | 0 => some .requestCancel
  | 1 => some .dispatchKillSignal
  | 2 => some .confirmTerminatedReceipt
  | 3 => some .resetForNewRun
  | _ => none

/-- Pure admission gate for `CancelProtocol`:
    - `CancelRequested` (`phaseCode == 1`) and `SignalDispatched` (`phaseCode == 2`) NEVER transition
      to `Cancelled` (`3`) unless `runnerTerminatedReceipt == 1 && receiptGeneration == targetGeneration`
      AND `uncertainDeliveryBlocked == 0` (`orb_queue_step` uncertain delivery blocks premature cancel).
    - `requestCancel` (`opCode == 0`) requires `phaseCode == 0`, `targetGeneration != 0`, and `uncertainDeliveryBlocked == 0`.
    - `resetForNewRun` (`opCode == 3`) requires `phaseCode == 3` (`cancelled`) and `receiptGeneration < targetGeneration`
      (only a strictly newer run generation clears a finalized cancellation). -/
@[inline]
def verifyCancelProtocolAdmit
    (phaseCode opCode runnerTerminatedReceipt uncertainDeliveryBlocked : UInt8)
    (targetGeneration receiptGeneration : UInt64) : UInt8 :=
  if phaseCode ≤ 3 &&
     opCode ≤ 3 &&
     targetGeneration != 0 &&
     ((opCode == 0 && phaseCode == 0 && uncertainDeliveryBlocked == 0) ||
      (opCode == 1 && phaseCode == 1 && uncertainDeliveryBlocked == 0) ||
      (opCode == 2 && (phaseCode == 1 || phaseCode == 2) &&
       runnerTerminatedReceipt == 1 && uncertainDeliveryBlocked == 0 &&
       receiptGeneration == targetGeneration) ||
      (opCode == 3 && phaseCode == 3 && receiptGeneration != 0 &&
       receiptGeneration < targetGeneration))
  then 1 else 0

@[inline]
def cancelProtocolTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 3
  else 0

structure CancelSliceState where
  phaseCode        : UInt8
  targetGeneration : UInt64
  deriving Repr, DecidableEq

structure CancelSliceEvent where
  opCode                   : UInt8
  runnerTerminatedReceipt  : UInt8
  uncertainDeliveryBlocked : UInt8
  eventGeneration          : UInt64
  deriving Repr, DecidableEq

inductive CancelEffect where
  | recordCancelRequest (generation : UInt64)
  | sendRunnerAbortSignal (generation : UInt64)
  | commitCancelledReceipt (generation : UInt64)
  deriving Repr, DecidableEq

def stepCancelSlice (s : CancelSliceState) (ev : CancelSliceEvent) :
    CancelSliceState × List CancelEffect :=
  let effTargetGen := if ev.opCode == 0 || ev.opCode == 3 then ev.eventGeneration else s.targetGeneration
  let effReceiptGen := if ev.opCode == 3 then s.targetGeneration else ev.eventGeneration
  if verifyCancelProtocolAdmit s.phaseCode ev.opCode ev.runnerTerminatedReceipt
       ev.uncertainDeliveryBlocked effTargetGen effReceiptGen == 1 then
    let nextPhase := cancelProtocolTargetPhase ev.opCode
    let nextGen : UInt64 :=
      if ev.opCode == 0 then ev.eventGeneration
      else if ev.opCode == 3 then 0
      else s.targetGeneration
    let effs : List CancelEffect :=
      if ev.opCode == 0 then [.recordCancelRequest ev.eventGeneration]
      else if ev.opCode == 1 then [.sendRunnerAbortSignal s.targetGeneration]
      else if ev.opCode == 2 then [.commitCancelledReceipt s.targetGeneration]
      else []
    ({ phaseCode := nextPhase, targetGeneration := nextGen }, effs)
  else
    (s, [])

/-! ## 5. `WakeupContinuation` (`SM-07`) -/

inductive WakeupPhase where
  | disarmed
  | armed
  | fired
  | superseded
  | cancelled
  deriving Repr, DecidableEq

def WakeupPhase.encode : WakeupPhase → UInt8
  | .disarmed   => 0
  | .armed      => 1
  | .fired      => 2
  | .superseded => 3
  | .cancelled  => 4

def WakeupPhase.decode? : Nat → Option WakeupPhase
  | 0 => some .disarmed
  | 1 => some .armed
  | 2 => some .fired
  | 3 => some .superseded
  | 4 => some .cancelled
  | _ => none

inductive WakeupOp where
  | armWakeup
  | replaceArmedWakeup
  | fireDueWakeup
  | supersedeStaleGeneration
  | cancelWakeup
  deriving Repr, DecidableEq

def WakeupOp.encode : WakeupOp → UInt8
  | .armWakeup                => 0
  | .replaceArmedWakeup       => 1
  | .fireDueWakeup            => 2
  | .supersedeStaleGeneration => 3
  | .cancelWakeup             => 4

def WakeupOp.decode? : Nat → Option WakeupOp
  | 0 => some .armWakeup
  | 1 => some .replaceArmedWakeup
  | 2 => some .fireDueWakeup
  | 3 => some .supersedeStaleGeneration
  | 4 => some .cancelWakeup
  | _ => none

/-- Pure admission gate for dedicated `mission_continuations` one-shot wakeups (`SM-07`):
    - Decouples one-shot continuations from user cron `mission_automations`.
    - `armWakeup` (`opCode == 0`) requires `phaseCode != 1`, non-terminal owner (`ownerTerminal == 0`),
      `currentRunGeneration != 0`, and `nowEpoch < dueEpoch`.
    - `replaceArmedWakeup` (`opCode == 1`) atomically replaces an already-armed wakeup when
      `phaseCode == 1`, `ownerTerminal == 0`, `currentRunGeneration >= armedGeneration`, and `nowEpoch < dueEpoch`.
    - `fireDueWakeup` (`opCode == 2`) requires `phaseCode == 1` (`armed` — fired/superseded/cancelled wakeups
      never double-fire), `ownerTerminal == 0`, `ownerBusy == 0`, `armedGeneration == currentRunGeneration`,
      and `dueEpoch <= nowEpoch` (`ClockDiscipline`).
    - `supersedeStaleGeneration` (`opCode == 3`) retires an armed wakeup (`phaseCode == 1 -> 3`) when
      `armedGeneration < currentRunGeneration` (a new user turn or run generation advanced past the parked turn). -/
@[inline]
def verifyWakeupContinuationAdmit
    (phaseCode opCode ownerTerminal ownerBusy : UInt8)
    (armedGeneration currentRunGeneration dueEpoch nowEpoch : UInt64) : UInt8 :=
  if phaseCode ≤ 4 &&
     opCode ≤ 4 &&
     ((opCode == 0 && phaseCode != 1 && ownerTerminal == 0 &&
       currentRunGeneration != 0 && nowEpoch < dueEpoch) ||
      (opCode == 1 && phaseCode == 1 && ownerTerminal == 0 &&
       currentRunGeneration != 0 && armedGeneration ≤ currentRunGeneration && nowEpoch < dueEpoch) ||
      (opCode == 2 && phaseCode == 1 && ownerTerminal == 0 && ownerBusy == 0 &&
       armedGeneration != 0 && armedGeneration == currentRunGeneration && dueEpoch ≤ nowEpoch) ||
      (opCode == 3 && phaseCode == 1 && armedGeneration < currentRunGeneration) ||
      (opCode == 4 && phaseCode == 1))
  then 1 else 0

@[inline]
def wakeupContinuationTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 1
  else if opCode == 2 then 2
  else if opCode == 3 then 3
  else 4

structure WakeupSliceState where
  phaseCode       : UInt8
  armedGeneration : UInt64
  dueEpoch        : UInt64
  deriving Repr, DecidableEq

structure WakeupSliceEvent where
  opCode               : UInt8
  ownerTerminal        : UInt8
  ownerBusy            : UInt8
  currentRunGeneration : UInt64
  reqDueEpoch          : UInt64
  nowEpoch             : UInt64
  deriving Repr, DecidableEq

inductive WakeupEffect where
  | persistContinuation (phaseCode : UInt8) (armedGen : UInt64) (dueEpoch : UInt64)
  | dispatchWakeupTurn (armedGen : UInt64)
  deriving Repr, DecidableEq

def stepWakeupSlice (s : WakeupSliceState) (ev : WakeupSliceEvent) :
    WakeupSliceState × List WakeupEffect :=
  let effDue := if ev.opCode == 0 || ev.opCode == 1 then ev.reqDueEpoch else s.dueEpoch
  if verifyWakeupContinuationAdmit s.phaseCode ev.opCode ev.ownerTerminal ev.ownerBusy
       s.armedGeneration ev.currentRunGeneration effDue ev.nowEpoch == 1 then
    let nextPhase := wakeupContinuationTargetPhase ev.opCode
    let nextGen : UInt64 :=
      if ev.opCode == 0 || ev.opCode == 1 then ev.currentRunGeneration else s.armedGeneration
    let nextDue : UInt64 :=
      if ev.opCode == 0 || ev.opCode == 1 then ev.reqDueEpoch else s.dueEpoch
    let effs : List WakeupEffect :=
      if ev.opCode == 2 then
        [.persistContinuation nextPhase nextGen nextDue, .dispatchWakeupTurn nextGen]
      else
        [.persistContinuation nextPhase nextGen nextDue]
    ({ phaseCode := nextPhase, armedGeneration := nextGen, dueEpoch := nextDue }, effs)
  else
    (s, [])

/-! ## 6. Orthogonal `R3WorldState` Composition via `Orb.Spec.SpecBlock` -/

structure R3WorldState where
  mission : MissionSliceState
  run     : RunSliceState
  queue   : QueueSliceState
  cancel  : CancelSliceState
  wakeup  : WakeupSliceState
  deriving Repr, DecidableEq

def missionLifecycleSpecBlock :
    SpecBlock R3WorldState MissionSliceState MissionSliceEvent MissionEffect where
  footprint := ⟨0x01, 0x01⟩
  project w := w.mission
  inject w s := { w with mission := s }
  step := stepMissionSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def runLifecycleSpecBlock :
    SpecBlock R3WorldState RunSliceState RunSliceEvent RunEffect where
  footprint := ⟨0x02, 0x02⟩
  project w := w.run
  inject w s := { w with run := s }
  step := stepRunSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def queueItemSpecBlock :
    SpecBlock R3WorldState QueueSliceState QueueSliceEvent QueueEffect where
  footprint := ⟨0x04, 0x04⟩
  project w := w.queue
  inject w s := { w with queue := s }
  step := stepQueueSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def cancelProtocolSpecBlock :
    SpecBlock R3WorldState CancelSliceState CancelSliceEvent CancelEffect where
  footprint := ⟨0x08, 0x08⟩
  project w := w.cancel
  inject w s := { w with cancel := s }
  step := stepCancelSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def wakeupContinuationSpecBlock :
    SpecBlock R3WorldState WakeupSliceState WakeupSliceEvent WakeupEffect where
  footprint := ⟨0x10, 0x10⟩
  project w := w.wakeup
  inject w s := { w with wakeup := s }
  step := stepWakeupSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

end Orb.Lifecycle
