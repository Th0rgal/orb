/-
  Orb.HarnessCloud: Phase R4-A Cloud Turn, Harness Warm-Session, Provider Attempt Classifier
  & Auth-Refresh Steppers & SpecBlocks (`0 import Lean`, `0 sorryAx`).

  Formalizes the 4 coordinated Phase R4-A slices (`plan.md` §Phase R4-A):
    1. `CloudTurn`         (`SM-14`) — Provider/cloud turn submission, approval, uncertainty & cancellation stepper.
    2. `HarnessSession`    (`SM-15`, `SM-16`, `SM-17`) — Generation-fenced harness warm-session stepper.
    3. `ProviderAttempt`   (`SM-21`) — Generation-fenced provider-attempt classifier (proxy commitment + breaker).
    4. `AuthRefresh`       (`SM-21`) — Generation-fenced OAuth/CLIProxy auth-refresh & rotation admitter.

  Each slice exposes:
    - Typed protocol phase/op/verdict ADTs with explicit `decode?` / `encode` roundtrips.
    - Pure scalar admission & classification functions suitable for SQLite CAS transactions in `OrbCore`.
    - Pure slice reducers (`State -> Event -> State × List Effect`) composed over `R4WorldState`
      via `Orb.Spec.SpecBlock` with disjoint 64-bit footprints.
-/
import Orb.Spec

namespace Orb.HarnessCloud

open Orb.Spec

/-! ## 1. `CloudTurn` (`SM-14`) — Provider / Cloud Turn Stepper -/

inductive CloudTurnPhase where
  | queued
  | submitting
  | running
  | waitingApproval
  | uncertain
  | cancelRequested
  | terminal
  deriving Repr, DecidableEq

def CloudTurnPhase.encode : CloudTurnPhase → UInt8
  | .queued          => 0
  | .submitting      => 1
  | .running         => 2
  | .waitingApproval => 3
  | .uncertain       => 4
  | .cancelRequested => 5
  | .terminal        => 6

def CloudTurnPhase.decode? : Nat → Option CloudTurnPhase
  | 0 => some .queued
  | 1 => some .submitting
  | 2 => some .running
  | 3 => some .waitingApproval
  | 4 => some .uncertain
  | 5 => some .cancelRequested
  | 6 => some .terminal
  | _ => none

def CloudTurnPhase.isTerminal : CloudTurnPhase → Bool
  | .terminal => true
  | _ => false

inductive CloudTurnOp where
  | beginSubmit
  | confirmAccepted
  | rejectPreCommit
  | markUncertain
  | awaitApproval
  | resolveApproval
  | bindReconciledTurn
  | confirmNotDeliveredRetry
  | requestCancel
  | finalizeCancelReceipt
  | completeTurnReceipt
  deriving Repr, DecidableEq

def CloudTurnOp.encode : CloudTurnOp → UInt8
  | .beginSubmit              => 0
  | .confirmAccepted          => 1
  | .rejectPreCommit          => 2
  | .markUncertain            => 3
  | .awaitApproval            => 4
  | .resolveApproval          => 5
  | .bindReconciledTurn       => 6
  | .confirmNotDeliveredRetry => 7
  | .requestCancel            => 8
  | .finalizeCancelReceipt    => 9
  | .completeTurnReceipt      => 10

def CloudTurnOp.decode? : Nat → Option CloudTurnOp
  | 0  => some .beginSubmit
  | 1  => some .confirmAccepted
  | 2  => some .rejectPreCommit
  | 3  => some .markUncertain
  | 4  => some .awaitApproval
  | 5  => some .resolveApproval
  | 6  => some .bindReconciledTurn
  | 7  => some .confirmNotDeliveredRetry
  | 8  => some .requestCancel
  | 9  => some .finalizeCancelReceipt
  | 10 => some .completeTurnReceipt
  | _  => none

/-- Pure admission gate for `CloudTurn` transitions (`SM-14`):
    - Only legal edges across `Queued (0) -> Submitting (1) -> Running (2)`,
      `WaitingApproval (3)`, `Uncertain (4)`, `CancelRequested (5)`, `Terminal (6)` are admitted.
    - `Terminal` (`phaseCode == 6`) is sticky and never admits any operation.
    - `beginSubmit` (`opCode == 0`) requires `phaseCode == 0` (`Queued`), `proposedAttemptId != 0`, and
      `lastAttemptId < proposedAttemptId` (strictly fresh attempt ID: duplicate `attempt_id` is rejected,
      and `Uncertain` (`phaseCode == 4`) NEVER starts a fresh submission).
    - `Uncertain` (`phaseCode == 4`) exits ONLY via operator/controller reconciliation:
      `bindReconciledTurn` (`opCode == 6`, binding `providerTurnId != 0`) or
      `confirmNotDeliveredRetry` (`opCode == 7`, returning to `Queued` when `operatorConfirmedNotDelivered == 1`).
    - `CancelRequested` (`phaseCode == 5`) transitions ONLY to `Terminal` (`opCode == 9`) and requires
      explicit `hasTerminationReceipt == 1`. -/
@[inline]
def verifyCloudTurnAdmit
    (phaseCode opCode hasTerminationReceipt hasCompletionReceipt
     operatorConfirmedNotDelivered approvalResolved : UInt8)
    (lastAttemptId proposedAttemptId providerTurnId approvalReqId
     submittedAtMs nowMs : UInt64) : UInt8 :=
  if phaseCode ≤ 5 &&
     opCode ≤ 10 &&
     ((opCode == 0 && phaseCode == 0 &&
       proposedAttemptId != 0 && lastAttemptId < proposedAttemptId && submittedAtMs != 0) ||
      (opCode ≥ 1 && lastAttemptId != 0 && proposedAttemptId == lastAttemptId &&
       ((opCode == 1 && phaseCode == 1 && providerTurnId != 0 && submittedAtMs ≤ nowMs) ||
        (opCode == 2 && phaseCode == 1) ||
        (opCode == 3 && phaseCode == 1) ||
        (opCode == 4 && phaseCode == 2 && approvalReqId != 0) ||
        (opCode == 5 && phaseCode == 3 && approvalResolved == 1 && approvalReqId != 0) ||
        (opCode == 6 && phaseCode == 4 && providerTurnId != 0) ||
        (opCode == 7 && phaseCode == 4 && operatorConfirmedNotDelivered == 1) ||
        (opCode == 8 && (phaseCode == 0 || phaseCode == 2 || phaseCode == 3)) ||
        (opCode == 9 && phaseCode == 5 && hasTerminationReceipt == 1) ||
        (opCode == 10 && phaseCode == 2 && hasCompletionReceipt == 1))))
  then 1 else 0

@[inline]
def cloudTurnTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 0
  else if opCode == 3 then 4
  else if opCode == 4 then 3
  else if opCode == 5 then 2
  else if opCode == 6 then 2
  else if opCode == 7 then 0
  else if opCode == 8 then 5
  else if opCode == 9 then 6
  else 6

structure CloudTurnSliceState where
  phaseCode       : UInt8
  unreconciledUnc : UInt8
  lastAttemptId   : UInt64
  providerTurnId  : UInt64
  eventCursor     : UInt64
  approvalReqId   : UInt64
  submittedAtMs   : UInt64
  deriving Repr, DecidableEq

structure CloudTurnSliceEvent where
  opCode                        : UInt8
  hasTerminationReceipt         : UInt8
  hasCompletionReceipt          : UInt8
  operatorConfirmedNotDelivered : UInt8
  approvalResolved              : UInt8
  proposedAttemptId             : UInt64
  reqProviderTurnId             : UInt64
  reqEventCursor                : UInt64
  reqApprovalReqId              : UInt64
  reqSubmittedAtMs              : UInt64
  nowMs                         : UInt64
  deriving Repr, DecidableEq

inductive CloudTurnEffect where
  | persistCloudTurn (nextPhase : UInt8) (attemptId : UInt64) (providerTurnId : UInt64)
  | dispatchProviderSubmit (attemptId : UInt64) (submittedAtMs : UInt64)
  | requestProviderCancel (attemptId : UInt64)
  | recordCloudTerminalReceipt (attemptId : UInt64)
  deriving Repr, DecidableEq

def stepCloudTurnSlice (s : CloudTurnSliceState) (ev : CloudTurnSliceEvent) :
    CloudTurnSliceState × List CloudTurnEffect :=
  let effProviderId :=
    if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId else s.providerTurnId
  let effApprovalId :=
    if ev.opCode == 4 then ev.reqApprovalReqId else s.approvalReqId
  let effSubmittedAt :=
    if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs
  if verifyCloudTurnAdmit s.phaseCode ev.opCode ev.hasTerminationReceipt ev.hasCompletionReceipt
       ev.operatorConfirmedNotDelivered ev.approvalResolved
       s.lastAttemptId ev.proposedAttemptId effProviderId effApprovalId
       effSubmittedAt ev.nowMs == 1 then
    let nextPhase := cloudTurnTargetPhase ev.opCode
    let nextUnc : UInt8 :=
      if ev.opCode == 3 then 1
      else if ev.opCode == 6 || ev.opCode == 7 then 0
      else s.unreconciledUnc
    let nextAttempt : UInt64 :=
      if ev.opCode == 0 then ev.proposedAttemptId else s.lastAttemptId
    let nextProvId : UInt64 :=
      if ev.opCode == 1 || ev.opCode == 6 then ev.reqProviderTurnId
      else if ev.opCode == 0 || ev.opCode == 2 || ev.opCode == 7 then 0
      else s.providerTurnId
    let nextCursor : UInt64 :=
      if ev.opCode == 1 || ev.opCode == 5 || ev.opCode == 6 || ev.opCode == 10 then ev.reqEventCursor
      else if ev.opCode == 0 || ev.opCode == 2 || ev.opCode == 7 then 0
      else s.eventCursor
    let nextApproval : UInt64 :=
      if ev.opCode == 4 then ev.reqApprovalReqId
      else if ev.opCode == 5 || nextPhase == 5 || nextPhase == 6 then 0
      else s.approvalReqId
    let nextSubMs : UInt64 :=
      if ev.opCode == 0 then ev.reqSubmittedAtMs else s.submittedAtMs
    let effs : List CloudTurnEffect :=
      if ev.opCode == 0 then
        [.persistCloudTurn nextPhase nextAttempt nextProvId,
         .dispatchProviderSubmit nextAttempt nextSubMs]
      else if ev.opCode == 8 then
        [.persistCloudTurn nextPhase nextAttempt nextProvId,
         .requestProviderCancel nextAttempt]
      else if nextPhase == 6 then
        [.persistCloudTurn nextPhase nextAttempt nextProvId,
         .recordCloudTerminalReceipt nextAttempt]
      else
        [.persistCloudTurn nextPhase nextAttempt nextProvId]
    ({ phaseCode := nextPhase
       unreconciledUnc := nextUnc
       lastAttemptId := nextAttempt
       providerTurnId := nextProvId
       eventCursor := nextCursor
       approvalReqId := nextApproval
       submittedAtMs := nextSubMs }, effs)
  else
    (s, [])

/-! ## 2. `HarnessSession` (`SM-15`, `SM-16`, `SM-17`) — Warm-Session Stepper -/

inductive HarnessSessionPhase where
  | starting
  | ready
  | inTurn
  | parked
  | terminating
  | dead
  deriving Repr, DecidableEq

def HarnessSessionPhase.encode : HarnessSessionPhase → UInt8
  | .starting    => 0
  | .ready       => 1
  | .inTurn      => 2
  | .parked      => 3
  | .terminating => 4
  | .dead        => 5

def HarnessSessionPhase.decode? : Nat → Option HarnessSessionPhase
  | 0 => some .starting
  | 1 => some .ready
  | 2 => some .inTurn
  | 3 => some .parked
  | 4 => some .terminating
  | 5 => some .dead
  | _ => none

def HarnessSessionPhase.isDead : HarnessSessionPhase → Bool
  | .dead => true
  | _ => false

inductive HarnessSessionOp where
  | confirmReady
  | beginTurn
  | enterToolCall
  | exitToolCall
  | queueSteer
  | flushSteerBetweenTools
  | finishTurnToReady
  | parkSession
  | wakeParkedSession
  | beginTerminate
  | confirmProcessDead
  deriving Repr, DecidableEq

def HarnessSessionOp.encode : HarnessSessionOp → UInt8
  | .confirmReady           => 0
  | .beginTurn              => 1
  | .enterToolCall          => 2
  | .exitToolCall           => 3
  | .queueSteer             => 4
  | .flushSteerBetweenTools => 5
  | .finishTurnToReady      => 6
  | .parkSession            => 7
  | .wakeParkedSession      => 8
  | .beginTerminate         => 9
  | .confirmProcessDead     => 10

def HarnessSessionOp.decode? : Nat → Option HarnessSessionOp
  | 0  => some .confirmReady
  | 1  => some .beginTurn
  | 2  => some .enterToolCall
  | 3  => some .exitToolCall
  | 4  => some .queueSteer
  | 5  => some .flushSteerBetweenTools
  | 6  => some .finishTurnToReady
  | 7  => some .parkSession
  | 8  => some .wakeParkedSession
  | 9  => some .beginTerminate
  | 10 => some .confirmProcessDead
  | _  => none

/-- Pure admission gate for `HarnessSession` warm-process lifecycle (`SM-15`, `SM-16`, `SM-17`):
    - Enforces `Starting (0) -> Ready (1) -> InTurn(toolDepth, steerPending) (2) -> Parked (3) -> Terminating (4) -> Dead (5)`.
    - `Dead` (`phaseCode == 5`) is strictly sticky (`phaseCode <= 4`).
    - Generation mismatch (`eventGeneration != sessionGeneration` or `sessionGeneration == 0`) fails closed.
    - `exitToolCall` (`opCode == 3`) requires `0 < toolDepth`, ensuring `toolDepth` NEVER underflows / goes negative.
    - `finishTurnToReady` (`opCode == 6`) and `flushSteerBetweenTools` (`opCode == 5`) require `toolDepth == 0`
      (and `steerPending == 0` + `hasTurnIdleReceipt == 1` on turn completion).
    - `Terminating -> Dead` (`opCode == 10`) requires `phaseCode == 4` and explicit `hasProcExitReceipt == 1`. -/
@[inline]
def verifyHarnessSessionAdmit
    (phaseCode opCode steerPending hasTurnIdleReceipt hasProcExitReceipt : UInt8)
    (toolDepth : UInt32)
    (sessionGeneration eventGeneration : UInt64) : UInt8 :=
  if phaseCode ≤ 4 &&
     opCode ≤ 10 &&
     steerPending ≤ 1 &&
     sessionGeneration != 0 &&
     eventGeneration == sessionGeneration &&
     ((opCode == 0 && phaseCode == 0) ||
      (opCode == 1 && phaseCode == 1 && toolDepth == 0 && steerPending == 0) ||
      (opCode == 2 && phaseCode == 2 && toolDepth < 0xFFFFFFFF) ||
      (opCode == 3 && phaseCode == 2 && 0 < toolDepth) ||
      (opCode == 4 && phaseCode == 2 && steerPending == 0) ||
      (opCode == 5 && phaseCode == 2 && toolDepth == 0 && steerPending == 1) ||
      (opCode == 6 && phaseCode == 2 && toolDepth == 0 && steerPending == 0 && hasTurnIdleReceipt == 1) ||
      (opCode == 7 && phaseCode == 1 && toolDepth == 0 && steerPending == 0) ||
      (opCode == 8 && phaseCode == 3 && toolDepth == 0 && steerPending == 0) ||
      (opCode == 9 && (phaseCode == 0 || phaseCode == 1 || phaseCode == 2 || phaseCode == 3)) ||
      (opCode == 10 && phaseCode == 4 && hasProcExitReceipt == 1))
  then 1 else 0

@[inline]
def harnessSessionTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 2
  else if opCode == 3 then 2
  else if opCode == 4 then 2
  else if opCode == 5 then 2
  else if opCode == 6 then 1
  else if opCode == 7 then 3
  else if opCode == 8 then 1
  else if opCode == 9 then 4
  else 5

structure HarnessSessionSliceState where
  phaseCode         : UInt8
  steerPending      : UInt8
  toolDepth         : UInt32
  sessionGeneration : UInt64
  deriving Repr, DecidableEq

structure HarnessSessionSliceEvent where
  opCode             : UInt8
  hasTurnIdleReceipt : UInt8
  hasProcExitReceipt : UInt8
  eventGeneration    : UInt64
  deriving Repr, DecidableEq

inductive HarnessSessionEffect where
  | persistHarnessState (nextPhase : UInt8) (toolDepth : UInt32) (steerPending : UInt8) (generation : UInt64)
  | injectMidturnSteer (generation : UInt64)
  | signalProcessGroupKill (generation : UInt64)
  | reapDeadSession (generation : UInt64)
  deriving Repr, DecidableEq

def stepHarnessSessionSlice (s : HarnessSessionSliceState) (ev : HarnessSessionSliceEvent) :
    HarnessSessionSliceState × List HarnessSessionEffect :=
  if verifyHarnessSessionAdmit s.phaseCode ev.opCode s.steerPending
       ev.hasTurnIdleReceipt ev.hasProcExitReceipt
       s.toolDepth s.sessionGeneration ev.eventGeneration == 1 then
    let nextPhase := harnessSessionTargetPhase ev.opCode
    let nextDepth : UInt32 :=
      if ev.opCode == 2 then s.toolDepth + 1
      else if ev.opCode == 3 then s.toolDepth - 1
      else if ev.opCode == 9 || ev.opCode == 10 then 0
      else s.toolDepth
    let nextSteer : UInt8 :=
      if ev.opCode == 4 then 1
      else if ev.opCode == 5 || ev.opCode == 6 || ev.opCode == 9 || ev.opCode == 10 then 0
      else s.steerPending
    let effs : List HarnessSessionEffect :=
      if ev.opCode == 5 then
        [.injectMidturnSteer s.sessionGeneration,
         .persistHarnessState nextPhase nextDepth nextSteer s.sessionGeneration]
      else if ev.opCode == 9 then
        [.persistHarnessState nextPhase nextDepth nextSteer s.sessionGeneration,
         .signalProcessGroupKill s.sessionGeneration]
      else if ev.opCode == 10 then
        [.persistHarnessState nextPhase nextDepth nextSteer s.sessionGeneration,
         .reapDeadSession s.sessionGeneration]
      else
        [.persistHarnessState nextPhase nextDepth nextSteer s.sessionGeneration]
    ({ phaseCode := nextPhase
       steerPending := nextSteer
       toolDepth := nextDepth
       sessionGeneration := s.sessionGeneration }, effs)
  else
    (s, [])

/-! ## 3. `ProviderAttempt` (`SM-21`) — Generation-Fenced Provider Attempt Classifier -/

inductive ProviderAttemptVerdict where
  | rejectStaleOrPin
  | dispatchFresh
  | rerouteSameAccount
  | rerouteExcludeCurrent
  | abortCommittedLock
  | parkAccountQuota
  | cooldownRateLimit
  | cooldownTransientOrAuth
  | passCommittedStream
  deriving Repr, DecidableEq

def ProviderAttemptVerdict.encode : ProviderAttemptVerdict → UInt8
  | .rejectStaleOrPin        => 0
  | .dispatchFresh           => 1
  | .rerouteSameAccount      => 2
  | .rerouteExcludeCurrent   => 3
  | .abortCommittedLock      => 4
  | .parkAccountQuota        => 5
  | .cooldownRateLimit       => 6
  | .cooldownTransientOrAuth => 7
  | .passCommittedStream     => 8

def ProviderAttemptVerdict.decode? : Nat → Option ProviderAttemptVerdict
  | 0 => some .rejectStaleOrPin
  | 1 => some .dispatchFresh
  | 2 => some .rerouteSameAccount
  | 3 => some .rerouteExcludeCurrent
  | 4 => some .abortCommittedLock
  | 5 => some .parkAccountQuota
  | 6 => some .cooldownRateLimit
  | 7 => some .cooldownTransientOrAuth
  | 8 => some .passCommittedStream
  | _ => none

def ProviderAttemptVerdict.admitsDispatch : ProviderAttemptVerdict → Bool
  | .dispatchFresh | .rerouteSameAccount | .rerouteExcludeCurrent => true
  | _ => false

/-- Pure generation-fenced provider attempt classifier extending proxy commitment & breaker rules (`SM-21`):
    `failureReason`:
      `0 = ok_fresh`, `1 = rate_limit_429`, `2 = quota_exhausted`, `3 = payment_required_402`,
      `4 = transient_502_stall`, `5 = auth_401_403`.
    - Fails closed (`0 = rejectStaleOrPin`) whenever `routeGeneration == 0`, `attemptGeneration != routeGeneration`
      (stale generation), `candidateAccountId == 0`, `(pinnedAccountId != 0 && candidateAccountId != pinnedAccountId)`,
      `(firstByteCommitted == 1 && pinnedAccountId == 0)`, `nowEpoch < cooldownUntilEpoch`, or `failureReason > 5`.
    - Once `firstByteCommitted == 1`:
      - `failureReason == 0` returns `8 = passCommittedStream` (in-flight committed stream pass-through;
        never opens a second upstream attempt, never resets `transientStreak`, and never trips breaker `7`).
      - Any non-zero `failureReason >= 1` returns `4 = abortCommittedLock`
        (transparent reroute after SSE commitment is strictly forbidden).
    - Pre-commit (`firstByteCommitted == 0`):
      - `failureReason == 0`: `1` (`dispatchFresh`) if `attemptsUsed <= maxRetries`, else `7`.
      - `failureReason == 2 || failureReason == 3`: `5` (`parkAccountQuota`).
      - `failureReason == 1`: `6` (`cooldownRateLimit`).
      - `failureReason == 5`: `7` (`cooldownTransientOrAuth`).
      - `failureReason == 4`: if `transientStreak >= transientThreshold && transientThreshold >= 1`
        or `!(attemptsUsed < maxRetries)` then `7`, else if `attemptsUsed + 1 >= 2` then `3`
        (`rerouteExcludeCurrent`) else `2` (`rerouteSameAccount`). -/
@[inline]
def classifyProviderAttempt
    (firstByteCommitted failureReason : UInt8)
    (pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold : UInt32)
    (routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch : UInt64) : UInt8 :=
  if routeGeneration == 0 ||
     attemptGeneration != routeGeneration ||
     candidateAccountId == 0 ||
     (pinnedAccountId != 0 && candidateAccountId != pinnedAccountId) ||
     (firstByteCommitted == 1 && pinnedAccountId == 0) ||
     nowEpoch < cooldownUntilEpoch ||
     failureReason > 5
  then 0
  else if firstByteCommitted == 1 then
    if failureReason == 0 then 8
    else 4
  else if failureReason == 0 then
    if attemptsUsed ≤ maxRetries then 1 else 7
  else if failureReason == 2 || failureReason == 3 then 5
  else if failureReason == 1 then 6
  else if failureReason == 5 then 7
  else
    if (transientStreak ≥ transientThreshold && transientThreshold ≥ 1) || !(attemptsUsed < maxRetries) then 7
    else if attemptsUsed + 1 ≥ 2 then 3
    else 2

/-- Pure boolean gate (`UInt8` `0/1`) deciding whether a provider attempt may dispatch upstream (`SM-21`). -/
@[inline]
def verifyProviderAttemptAdmit
    (firstByteCommitted failureReason : UInt8)
    (pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold : UInt32)
    (routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch : UInt64) : UInt8 :=
  let v := classifyProviderAttempt firstByteCommitted failureReason
    pinnedAccountId candidateAccountId attemptsUsed maxRetries transientStreak transientThreshold
    routeGeneration attemptGeneration nowEpoch cooldownUntilEpoch
  if v == 1 || v == 2 || v == 3 then 1 else 0

structure ProviderAttemptSliceState where
  firstByteCommitted : UInt8
  pinnedAccountId    : UInt32
  attemptsUsed       : UInt32
  transientStreak    : UInt32
  routeGeneration    : UInt64
  cooldownUntilEpoch : UInt64
  deriving Repr, DecidableEq

structure ProviderAttemptSliceEvent where
  chunkCommits       : UInt8
  failureReason      : UInt8
  candidateAccountId : UInt32
  maxRetries         : UInt32
  transientThreshold : UInt32
  attemptGeneration  : UInt64
  nowEpoch           : UInt64
  nextCooldownEpoch  : UInt64
  deriving Repr, DecidableEq

inductive ProviderAttemptEffect where
  | dispatchUpstreamAttempt (accountId : UInt32) (verdictCode : UInt8) (generation : UInt64)
  | tripAccountBreaker (verdictCode : UInt8) (cooldownUntil : UInt64)
  | abortLockedStream (generation : UInt64)
  deriving Repr, DecidableEq

def stepProviderAttemptSlice (s : ProviderAttemptSliceState) (ev : ProviderAttemptSliceEvent) :
    ProviderAttemptSliceState × List ProviderAttemptEffect :=
  let v := classifyProviderAttempt s.firstByteCommitted ev.failureReason
    s.pinnedAccountId ev.candidateAccountId s.attemptsUsed ev.maxRetries
    s.transientStreak ev.transientThreshold s.routeGeneration ev.attemptGeneration
    ev.nowEpoch s.cooldownUntilEpoch
  if v == 0 || v == 8 then
    (s, [])
  else
    let nextCommit : UInt8 :=
      if s.firstByteCommitted == 1 || (v == 1 && ev.chunkCommits == 1) then 1 else 0
    let nextPin : UInt32 :=
      if s.pinnedAccountId != 0 then s.pinnedAccountId
      else if v == 1 && ev.chunkCommits == 1 then ev.candidateAccountId
      else 0
    let nextAttempts : UInt32 :=
      if (v == 2 || v == 3) && s.attemptsUsed < 0xFFFFFFFF then s.attemptsUsed + 1
      else s.attemptsUsed
    let nextStreak : UInt32 :=
      if v == 1 then 0
      else if ev.failureReason == 4 && s.firstByteCommitted != 1 && s.transientStreak < 0xFFFFFFFF then
        s.transientStreak + 1
      else s.transientStreak
    let nextCooldown : UInt64 :=
      if (v == 5 || v == 6 || v == 7) && s.cooldownUntilEpoch < ev.nextCooldownEpoch then
        ev.nextCooldownEpoch
      else s.cooldownUntilEpoch
    let effs : List ProviderAttemptEffect :=
      if v == 1 || v == 2 || v == 3 then
        [.dispatchUpstreamAttempt ev.candidateAccountId v s.routeGeneration]
      else if v == 4 then
        [.abortLockedStream s.routeGeneration]
      else
        [.tripAccountBreaker v nextCooldown]
    ({ firstByteCommitted := nextCommit
       pinnedAccountId := nextPin
       attemptsUsed := nextAttempts
       transientStreak := nextStreak
       routeGeneration := s.routeGeneration
       cooldownUntilEpoch := nextCooldown }, effs)

/-! ## 4. `AuthRefresh` (`SM-21`) — Generation-Fenced Auth Refresh & Rotation Stepper -/

inductive AuthRefreshPhase where
  | valid
  | refreshClaimed
  | pendingFsync
  | revoked
  deriving Repr, DecidableEq

def AuthRefreshPhase.encode : AuthRefreshPhase → UInt8
  | .valid          => 0
  | .refreshClaimed => 1
  | .pendingFsync   => 2
  | .revoked        => 3

def AuthRefreshPhase.decode? : Nat → Option AuthRefreshPhase
  | 0 => some .valid
  | 1 => some .refreshClaimed
  | 2 => some .pendingFsync
  | 3 => some .revoked
  | _ => none

def AuthRefreshPhase.isRevoked : AuthRefreshPhase → Bool
  | .revoked => true
  | _ => false

inductive AuthRefreshOp where
  | claimRefresh
  | stageRotatedSecret
  | commitFsyncAndDrain
  | abortRefreshTransient
  | revokeCredential
  deriving Repr, DecidableEq

def AuthRefreshOp.encode : AuthRefreshOp → UInt8
  | .claimRefresh          => 0
  | .stageRotatedSecret    => 1
  | .commitFsyncAndDrain   => 2
  | .abortRefreshTransient => 3
  | .revokeCredential      => 4

def AuthRefreshOp.decode? : Nat → Option AuthRefreshOp
  | 0 => some .claimRefresh
  | 1 => some .stageRotatedSecret
  | 2 => some .commitFsyncAndDrain
  | 3 => some .abortRefreshTransient
  | 4 => some .revokeCredential
  | _ => none

/-- Pure admission gate for OAuth / CLIProxy credential refresh & rotation (`SM-21`):
    - Fails closed on `Revoked` (`phaseCode == 3`), zero `durableAuthGeneration`, or stale generation:
      - `claimRefresh` (`opCode == 0`) requires `phaseCode == 0` (`valid`), no wrap on `durableAuthGeneration`,
        `durableAuthGeneration < candidateGeneration`, `candidateGeneration - durableAuthGeneration == 1`
        (strictly consecutive fresh generation), and non-zero `expectedLoginNonce`.
      - In-flight / revoke ops (`opCode >= 1`) require `candidateGeneration == durableAuthGeneration`.
      - `stageRotatedSecret` (`opCode == 1`) requires `phaseCode == 1`, `expectedLoginNonce != 0`, and
        `presentedLoginNonce == expectedLoginNonce` (attempt-bound CLIProxy login directory, forbidding
        ambient set-diff misattribution across concurrent logins).
      - `commitFsyncAndDrain` (`opCode == 2`) requires `phaseCode == 2`, `fsyncCompleted == 1`,
        `flockHeld == 1`, and `nowEpoch < newExpiryEpoch` (prevents `CoalescedAsyncWriter` clearing `dirty`
        before `fsync` and prevents `oauth_reconcile` unlinking a newer rotation generation). -/
@[inline]
def verifyAuthRefreshAdmit
    (phaseCode opCode fsyncCompleted flockHeld : UInt8)
    (durableAuthGeneration candidateGeneration expectedLoginNonce presentedLoginNonce
     nowEpoch newExpiryEpoch : UInt64) : UInt8 :=
  if phaseCode ≤ 2 &&
     opCode ≤ 4 &&
     durableAuthGeneration != 0 &&
     ((opCode == 0 && phaseCode == 0 &&
       durableAuthGeneration < 0xFFFFFFFFFFFFFFFF &&
       durableAuthGeneration < candidateGeneration &&
       candidateGeneration - durableAuthGeneration == 1 &&
       expectedLoginNonce != 0) ||
      (opCode ≥ 1 && candidateGeneration == durableAuthGeneration &&
       ((opCode == 1 && phaseCode == 1 &&
         expectedLoginNonce != 0 && presentedLoginNonce == expectedLoginNonce) ||
        (opCode == 2 && phaseCode == 2 &&
         fsyncCompleted == 1 && flockHeld == 1 && nowEpoch < newExpiryEpoch) ||
        (opCode == 3 && (phaseCode == 1 || phaseCode == 2)) ||
        (opCode == 4 && (phaseCode == 0 || phaseCode == 1 || phaseCode == 2)))))
  then 1 else 0

@[inline]
def authRefreshTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 0
  else if opCode == 3 then 0
  else 3

structure AuthRefreshSliceState where
  phaseCode             : UInt8
  dirtyPending          : UInt8
  durableAuthGeneration : UInt64
  activeLoginNonce      : UInt64
  tokenExpiryEpoch      : UInt64
  deriving Repr, DecidableEq

structure AuthRefreshSliceEvent where
  opCode              : UInt8
  fsyncCompleted      : UInt8
  flockHeld           : UInt8
  candidateGeneration : UInt64
  reqLoginNonce       : UInt64
  nowEpoch            : UInt64
  newExpiryEpoch      : UInt64
  deriving Repr, DecidableEq

inductive AuthRefreshEffect where
  | beginNonceBoundLogin (generation : UInt64) (loginNonce : UInt64)
  | stageRotationRecord (generation : UInt64)
  | drainAppliedRotation (generation : UInt64) (expiryEpoch : UInt64)
  | retainDirtyBackoff (generation : UInt64)
  | persistRevokedAuth (generation : UInt64)
  deriving Repr, DecidableEq

def stepAuthRefreshSlice (s : AuthRefreshSliceState) (ev : AuthRefreshSliceEvent) :
    AuthRefreshSliceState × List AuthRefreshEffect :=
  let effExpectedNonce :=
    if ev.opCode == 0 then ev.reqLoginNonce else s.activeLoginNonce
  if verifyAuthRefreshAdmit s.phaseCode ev.opCode ev.fsyncCompleted ev.flockHeld
       s.durableAuthGeneration ev.candidateGeneration
       effExpectedNonce ev.reqLoginNonce ev.nowEpoch ev.newExpiryEpoch == 1 then
    let nextPhase := authRefreshTargetPhase ev.opCode
    let nextDirty : UInt8 :=
      if ev.opCode == 1 then 1
      else if ev.opCode == 2 || ev.opCode == 4 then 0
      else s.dirtyPending
    let nextGen : UInt64 :=
      if ev.opCode == 0 then ev.candidateGeneration else s.durableAuthGeneration
    let nextNonce : UInt64 :=
      if ev.opCode == 0 then ev.reqLoginNonce
      else if nextPhase == 0 || nextPhase == 3 then 0
      else s.activeLoginNonce
    let nextExpiry : UInt64 :=
      if ev.opCode == 2 then ev.newExpiryEpoch else s.tokenExpiryEpoch
    let effs : List AuthRefreshEffect :=
      if ev.opCode == 0 then
        [.beginNonceBoundLogin nextGen nextNonce]
      else if ev.opCode == 1 then
        [.stageRotationRecord nextGen]
      else if ev.opCode == 2 then
        [.drainAppliedRotation nextGen nextExpiry]
      else if ev.opCode == 3 then
        [.retainDirtyBackoff nextGen]
      else
        [.persistRevokedAuth nextGen]
    ({ phaseCode := nextPhase
       dirtyPending := nextDirty
       durableAuthGeneration := nextGen
       activeLoginNonce := nextNonce
       tokenExpiryEpoch := nextExpiry }, effs)
  else
    (s, [])

/-! ## 5. Orthogonal `R4WorldState` Composition via `Orb.Spec.SpecBlock` -/

structure R4WorldState where
  cloudTurn       : CloudTurnSliceState
  harnessSession  : HarnessSessionSliceState
  providerAttempt : ProviderAttemptSliceState
  authRefresh     : AuthRefreshSliceState
  deriving Repr, DecidableEq

def cloudTurnSpecBlock :
    SpecBlock R4WorldState CloudTurnSliceState CloudTurnSliceEvent CloudTurnEffect where
  footprint := ⟨0x20, 0x20⟩
  project w := w.cloudTurn
  inject w s := { w with cloudTurn := s }
  step := stepCloudTurnSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def harnessSessionSpecBlock :
    SpecBlock R4WorldState HarnessSessionSliceState HarnessSessionSliceEvent HarnessSessionEffect where
  footprint := ⟨0x40, 0x40⟩
  project w := w.harnessSession
  inject w s := { w with harnessSession := s }
  step := stepHarnessSessionSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def providerAttemptSpecBlock :
    SpecBlock R4WorldState ProviderAttemptSliceState ProviderAttemptSliceEvent ProviderAttemptEffect where
  footprint := ⟨0x80, 0x80⟩
  project w := w.providerAttempt
  inject w s := { w with providerAttempt := s }
  step := stepProviderAttemptSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def authRefreshSpecBlock :
    SpecBlock R4WorldState AuthRefreshSliceState AuthRefreshSliceEvent AuthRefreshEffect where
  footprint := ⟨0x100, 0x100⟩
  project w := w.authRefresh
  inject w s := { w with authRefresh := s }
  step := stepAuthRefreshSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

end Orb.HarnessCloud
