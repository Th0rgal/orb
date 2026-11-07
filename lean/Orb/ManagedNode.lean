/-
  Orb.ManagedNode: Phase R5-A Managed VM, Claim, Remote Job Ledger, Process Liveness & Relay Command
  (`0 import Lean`, `0 sorryAx`).

  Formalizes the five coordinated remote-compute slices (`plan.md` §Phase R5-A, `SM-19`, `SM-20`):
    1. `VmLifecycle`        (`SM-19`) boot-epoch fence, `replace`, `activeComputeEligible`, and `deletable_at` retention
    2. `VmClaim`            (`SM-19`) reservation uniqueness, lineage ownership, compute eligibility, and boot-epoch fence
    3. `RemoteJobLedger`    (`SM-20`) operation-id fence, uncertain delivery, first terminal
    4. `ProcessLiveness`    (`SM-20`) `(pid, start_ticks)` identity and signal admission
    5. `RelayCommand`       (`SM-19`) leased relay delivery without pop-before-ack and sticky uncertain reconcile

  Each slice exposes typed protocol ADTs, a pure scalar admitter, and a reducer composed over
  `R5WorldState` via `Orb.Spec.SpecBlock` with disjoint 64-bit footprints.
-/
import Orb.Spec

namespace Orb.ManagedNode

open Orb.Spec

/-! ## 1. `VmLifecycle` (`SM-19`) -/

inductive VmPhase where
  | absent
  | running
  | stopped
  | destroyed
  deriving Repr, DecidableEq

def VmPhase.encode : VmPhase → UInt8
  | .absent    => 0
  | .running   => 1
  | .stopped   => 2
  | .destroyed => 3

def VmPhase.decode? : Nat → Option VmPhase
  | 0 => some .absent
  | 1 => some .running
  | 2 => some .stopped
  | 3 => some .destroyed
  | _ => none

def VmPhase.isLive : VmPhase → Bool
  | .running => true
  | _ => false

inductive VmOp where
  | provision
  | stop
  | resume
  | replace
  | destroy
  deriving Repr, DecidableEq

def VmOp.encode : VmOp → UInt8
  | .provision => 0
  | .stop      => 1
  | .resume    => 2
  | .replace   => 3
  | .destroy   => 4

def VmOp.decode? : Nat → Option VmOp
  | 0 => some .provision
  | 1 => some .stop
  | 2 => some .resume
  | 3 => some .replace
  | 4 => some .destroy
  | _ => none

/-- Pure admission gate for `VmLifecycle` (`SM-19`):
    - `node_boot_epoch` is the durable fence. A zero live epoch never mutates.
    - `stop` keeps the epoch. `resume` (only from `stopped`) and `replace` (from `running` or
      `stopped`) are the only transitions that advance `node_boot_epoch`, and both must present
      `liveBootEpoch + 1` without wrapping.
    - `destroy` is rejected inside the minimum lease (`nowEpoch < deletableAt`) and rejected even
      past `deletableAt` while a live owner exists (`ownerLive == 1`). An ended owner (`ownerLive == 0`)
      whose idle timer has elapsed (`idleElapsed == 1`) and whose clock is past `deletableAt` may destroy. -/
@[inline]
def verifyVmLifecycleAdmit
    (phaseCode opCode ownerLive idleElapsed : UInt8)
    (liveBootEpoch presentedBootEpoch nowEpoch deletableAt : UInt64) : UInt8 :=
  if phaseCode ≤ 3 &&
     opCode ≤ 4 &&
     liveBootEpoch != 0 &&
     ((opCode == 0 && phaseCode == 0 && presentedBootEpoch == liveBootEpoch) ||
      (opCode == 1 && phaseCode == 1 && presentedBootEpoch == liveBootEpoch) ||
      (opCode == 2 && phaseCode == 2 &&
       liveBootEpoch < presentedBootEpoch && presentedBootEpoch == liveBootEpoch + 1) ||
      (opCode == 3 && (phaseCode == 1 || phaseCode == 2) &&
       liveBootEpoch < presentedBootEpoch && presentedBootEpoch == liveBootEpoch + 1) ||
      (opCode == 4 && (phaseCode == 1 || phaseCode == 2) &&
       presentedBootEpoch == liveBootEpoch &&
       ownerLive == 0 && idleElapsed == 1 && deletableAt ≤ nowEpoch))
  then 1 else 0

@[inline]
def vmLifecycleTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 || opCode == 2 || opCode == 3 then 1
  else if opCode == 1 then 2
  else 3

@[inline]
def vmLifecycleNextBoot (opCode : UInt8) (liveBoot presentedBoot : UInt64) : UInt64 :=
  if opCode == 2 || opCode == 3 then presentedBoot else liveBoot

@[inline]
def vmPhaseComputeEligible (phaseCode : UInt8) : UInt8 :=
  if phaseCode == 1 then 1 else 0

structure VmSliceState where
  phaseCode             : UInt8
  activeComputeEligible : UInt8
  nodeBootEpoch         : UInt64
  deletableAt           : UInt64
  deriving Repr, DecidableEq

structure VmSliceEvent where
  opCode             : UInt8
  ownerLive          : UInt8
  idleElapsed        : UInt8
  presentedBootEpoch : UInt64
  nowEpoch           : UInt64
  deriving Repr, DecidableEq

inductive VmEffect where
  | persistVmPhase (nextPhase : UInt8) (computeEligible : UInt8) (bootEpoch : UInt64)
  | recordBootFence (bootEpoch : UInt64)
  | closeCostLedger (bootEpoch : UInt64)
  deriving Repr, DecidableEq

def stepVmSlice (s : VmSliceState) (ev : VmSliceEvent) :
    VmSliceState × List VmEffect :=
  if verifyVmLifecycleAdmit s.phaseCode ev.opCode ev.ownerLive ev.idleElapsed
       s.nodeBootEpoch ev.presentedBootEpoch ev.nowEpoch s.deletableAt == 1 then
    let nextPhase := vmLifecycleTargetPhase ev.opCode
    let nextBoot := vmLifecycleNextBoot ev.opCode s.nodeBootEpoch ev.presentedBootEpoch
    let nextEligible := vmPhaseComputeEligible nextPhase
    let effs : List VmEffect :=
      if ev.opCode == 2 || ev.opCode == 3 then
        [.persistVmPhase nextPhase nextEligible nextBoot, .recordBootFence nextBoot]
      else if ev.opCode == 4 then
        [.persistVmPhase nextPhase nextEligible nextBoot, .closeCostLedger nextBoot]
      else
        [.persistVmPhase nextPhase nextEligible nextBoot]
    ({ s with
        phaseCode := nextPhase
        activeComputeEligible := nextEligible
        nodeBootEpoch := nextBoot }, effs)
  else
    (s, [])

def foldVmSlice (s : VmSliceState) : List VmSliceEvent → VmSliceState
  | [] => s
  | ev :: rest => foldVmSlice (stepVmSlice s ev).1 rest

/-! ## 2. `VmClaim` (`SM-19`) -/

inductive ClaimPhase where
  | unowned
  | claimed
  | released
  deriving Repr, DecidableEq

def ClaimPhase.encode : ClaimPhase → UInt8
  | .unowned  => 0
  | .claimed  => 1
  | .released => 2

def ClaimPhase.decode? : Nat → Option ClaimPhase
  | 0 => some .unowned
  | 1 => some .claimed
  | 2 => some .released
  | _ => none

inductive ClaimOp where
  | claim
  | release
  | reclaim
  deriving Repr, DecidableEq

def ClaimOp.encode : ClaimOp → UInt8
  | .claim   => 0
  | .release => 1
  | .reclaim => 2

def ClaimOp.decode? : Nat → Option ClaimOp
  | 0 => some .claim
  | 1 => some .release
  | 2 => some .reclaim
  | _ => none

/-- Pure admission gate for `VmClaim` (`SM-19`):
    - A reservation id is claimed at most once; duplicate claims of a held reservation are rejected.
    - Caller must be in the live owner lineage (`ownerInLineage == 1`) and not superseded (`ownerSuperseded == 0`).
    - All operations require a live non-zero `nodeBootEpoch` matched by `presentedBootEpoch`
      (stale boot epochs are rejected).
     - `claim` and `reclaim` require a live compute-eligible VM (`vmLive == 1 && activeComputeEligible == 1`).
     - `release` of the held reservation stays allowed when the VM is stopped (`vmLive ≤ 1` and
       `activeComputeEligible ≤ 1`, provided `(vmLive == 1) == (activeComputeEligible == 1)`),
       so a stopped VM can drop its claim, while rejecting stale boot epochs.
     - `stepClaimSlice` coordinates with `VmLifecycle`: when `s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch`
       (a claim released or boot-orphaned on boot `b` before `stop -> resume` or `replace` advanced
       `nodeBootEpoch` to `b + 1`), a fresh `claim` (`opCode == 0`) on the resumed VM
       (`vmLive == 1 && activeComputeEligible == 1` and `presentedBootEpoch == s.nodeBootEpoch`)
       treats the prior-boot `claimed` or `released` row as unowned (`effPhase := 0`), provided
       `heldReservation < presentedReservation`. Any claim record with `s.claimBoot > s.nodeBootEpoch`
       is rejected. -/
@[inline]
def verifyVmClaimAdmit
    (phaseCode opCode ownerInLineage ownerSuperseded vmLive activeComputeEligible : UInt8)
    (heldReservation presentedReservation nodeBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if phaseCode ≤ 2 &&
     opCode ≤ 2 &&
     ownerInLineage == 1 &&
     ownerSuperseded == 0 &&
     vmLive ≤ 1 &&
     activeComputeEligible ≤ 1 &&
     nodeBootEpoch != 0 &&
     presentedBootEpoch == nodeBootEpoch &&
     presentedReservation != 0 &&
     ((opCode == 0 && phaseCode == 0 && vmLive == 1 && activeComputeEligible == 1 &&
       heldReservation < presentedReservation) ||
      (opCode == 1 && phaseCode == 1 &&
       presentedReservation == heldReservation && heldReservation != 0 &&
       vmLive == activeComputeEligible) ||
      (opCode == 2 && phaseCode == 2 &&
       vmLive == 1 && activeComputeEligible == 1 &&
       heldReservation < presentedReservation))
  then 1 else 0

@[inline]
def vmClaimTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 1 then 2 else 1

structure ClaimSliceState where
  phaseCode     : UInt8
  reservationId : UInt64
  claimBoot     : UInt64 := 0
  nodeBootEpoch : UInt64
  deriving Repr, DecidableEq

structure ClaimSliceEvent where
  opCode                : UInt8
  ownerInLineage        : UInt8
  ownerSuperseded       : UInt8
  vmLive                : UInt8
  activeComputeEligible : UInt8
  presentedReservation  : UInt64
  presentedBootEpoch    : UInt64
  deriving Repr, DecidableEq

inductive ClaimEffect where
  | persistClaim (reservationId : UInt64) (bootEpoch : UInt64)
  | releaseClaim (reservationId : UInt64) (bootEpoch : UInt64)
  deriving Repr, DecidableEq

def stepClaimSlice (s : ClaimSliceState) (ev : ClaimSliceEvent) :
    ClaimSliceState × List ClaimEffect :=
  let effPhase : UInt8 :=
    if (s.phaseCode == 1 || s.phaseCode == 2) &&
       s.claimBoot != 0 && s.claimBoot < s.nodeBootEpoch && ev.opCode == 0
    then 0
    else s.phaseCode
  if (s.phaseCode == 0 || s.claimBoot == 0 ||
      (ev.opCode == 1 && s.claimBoot == s.nodeBootEpoch) ||
      ((ev.opCode == 0 || ev.opCode == 2) && s.claimBoot ≤ s.nodeBootEpoch)) &&
     verifyVmClaimAdmit effPhase ev.opCode ev.ownerInLineage ev.ownerSuperseded
       ev.vmLive ev.activeComputeEligible
       s.reservationId ev.presentedReservation s.nodeBootEpoch ev.presentedBootEpoch == 1 then
    let nextPhase := vmClaimTargetPhase ev.opCode
    let nextRes : UInt64 := if ev.opCode == 1 then s.reservationId else ev.presentedReservation
    let effs : List ClaimEffect :=
      if ev.opCode == 1 then
        [.releaseClaim s.reservationId s.nodeBootEpoch]
      else
        [.persistClaim nextRes s.nodeBootEpoch]
    ({ s with phaseCode := nextPhase, reservationId := nextRes, claimBoot := s.nodeBootEpoch }, effs)
  else
    (s, [])

/-! ## 3. `RemoteJobLedger` (`SM-20`) -/

inductive JobPhase where
  | absent
  | accepted
  | uncertain
  | succeeded
  | failed
  | cancelled
  deriving Repr, DecidableEq

def JobPhase.encode : JobPhase → UInt8
  | .absent     => 0
  | .accepted   => 1
  | .uncertain  => 2
  | .succeeded  => 3
  | .failed     => 4
  | .cancelled  => 5

def JobPhase.decode? : Nat → Option JobPhase
  | 0 => some .absent
  | 1 => some .accepted
  | 2 => some .uncertain
  | 3 => some .succeeded
  | 4 => some .failed
  | 5 => some .cancelled
  | _ => none

def JobPhase.isTerminal : JobPhase → Bool
  | .succeeded | .failed | .cancelled => true
  | _ => false

inductive JobOp where
  | accept
  | markUncertain
  | succeed
  | fail
  | cancel
  | retry
  | bindReconciledAccepted
  | reconcileSucceeded
  | reconcileFailed
  | reconcileCancelled
  | confirmNotDeliveredRetry
  deriving Repr, DecidableEq

def JobOp.encode : JobOp → UInt8
  | .accept                    => 0
  | .markUncertain             => 1
  | .succeed                   => 2
  | .fail                      => 3
  | .cancel                    => 4
  | .retry                     => 5
  | .bindReconciledAccepted    => 6
  | .reconcileSucceeded        => 7
  | .reconcileFailed           => 8
  | .reconcileCancelled        => 9
  | .confirmNotDeliveredRetry  => 10

def JobOp.decode? : Nat → Option JobOp
  | 0  => some .accept
  | 1  => some .markUncertain
  | 2  => some .succeed
  | 3  => some .fail
  | 4  => some .cancel
  | 5  => some .retry
  | 6  => some .bindReconciledAccepted
  | 7  => some .reconcileSucceeded
  | 8  => some .reconcileFailed
  | 9  => some .reconcileCancelled
  | 10 => some .confirmNotDeliveredRetry
  | _  => none

/-- Pure admission gate for the remote outbox / job ledger (`SM-20`).
    Op codes for `R5-C` (`OrbNode`) reconciliation, matching `HarnessCloud.CloudTurnOp`
    (`bindReconciledTurn = 6`, `confirmNotDeliveredRetry = 7`) and `RelayCommand.reconcile`:
      `0` accept, `1` markUncertain, `2` succeed, `3` fail, `4` cancel, `5` retry (always rejected),
      `6` bindReconciledAccepted (`uncertain -> accepted`, same operation),
      `7` reconcileSucceeded, `8` reconcileFailed, `9` reconcileCancelled (same operation),
      `10` confirmNotDeliveredRetry (`uncertain -> accepted` only with `presentedOperation > heldOperation`).
    - `operation_id` is accepted only when its boot epoch equals the live `node_boot_epoch` and,
      once a claim is held, equals the recorded `operationBoot`. A pre-stop operation cannot mutate
      the post-resume ledger, and a substituted stored boot cannot stand in for the presented one.
    - `Uncertain (2)` is sticky for a blind `retry` (`opCode = 5`): that opcode is never admitted.
      Explicit same-operation reconciliation (`6..9`) or a strictly fresher not-delivered retry (`10`)
      are the only exits.
    - The first terminal transition (`succeeded`, `failed`, `cancelled`) wins. Later terminal
      ops and retries of that operation id are rejected. -/
@[inline]
def verifyRemoteJobAdmit
    (phaseCode opCode : UInt8)
    (heldOperation presentedOperation operationBootEpoch nodeBootEpoch : UInt64) : UInt8 :=
  if phaseCode ≤ 5 &&
     opCode ≤ 10 &&
     nodeBootEpoch != 0 &&
     presentedOperation != 0 &&
     operationBootEpoch == nodeBootEpoch &&
     ((opCode == 0 && phaseCode == 0 && heldOperation == 0) ||
      ((opCode == 1 || opCode == 2 || opCode == 3 || opCode == 4) && phaseCode == 1 &&
       heldOperation != 0 && presentedOperation == heldOperation) ||
      ((opCode == 6 || opCode == 7 || opCode == 8 || opCode == 9) && phaseCode == 2 &&
       heldOperation != 0 && presentedOperation == heldOperation) ||
      (opCode == 10 && phaseCode == 2 && heldOperation != 0 && heldOperation < presentedOperation))
  then 1 else 0

@[inline]
def remoteJobTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 || opCode == 6 || opCode == 10 then 1
  else if opCode == 1 then 2
  else if opCode == 2 || opCode == 7 then 3
  else if opCode == 3 || opCode == 8 then 4
  else 5

structure JobSliceState where
  phaseCode     : UInt8
  operationId   : UInt64
  operationBoot : UInt64
  deriving Repr, DecidableEq

structure JobSliceEvent where
  opCode             : UInt8
  operationBootEpoch : UInt64
  nodeBootEpoch      : UInt64
  presentedOperation : UInt64
  deriving Repr, DecidableEq

inductive JobEffect where
  | persistJob (phaseCode : UInt8) (operationId : UInt64) (bootEpoch : UInt64)
  | recordTerminal (phaseCode : UInt8) (operationId : UInt64)
  deriving Repr, DecidableEq

def stepJobSlice (s : JobSliceState) (ev : JobSliceEvent) :
    JobSliceState × List JobEffect :=
  if ev.operationBootEpoch == ev.nodeBootEpoch &&
     (s.phaseCode == 0 || ev.operationBootEpoch == s.operationBoot) &&
     verifyRemoteJobAdmit s.phaseCode ev.opCode s.operationId ev.presentedOperation
       ev.operationBootEpoch ev.nodeBootEpoch == 1 then
    let nextPhase := remoteJobTargetPhase ev.opCode
    let nextOp : UInt64 :=
      if ev.opCode == 0 || ev.opCode == 10 then ev.presentedOperation else s.operationId
    let effs : List JobEffect :=
      if ev.opCode == 2 || ev.opCode == 3 || ev.opCode == 4 ||
         ev.opCode == 7 || ev.opCode == 8 || ev.opCode == 9 then
        [.persistJob nextPhase nextOp ev.operationBootEpoch, .recordTerminal nextPhase nextOp]
      else
        [.persistJob nextPhase nextOp ev.operationBootEpoch]
    ({ phaseCode := nextPhase, operationId := nextOp, operationBoot := ev.operationBootEpoch }, effs)
  else
    (s, [])

/-! ## 4. `ProcessLiveness` (`SM-20`) -/

inductive ProcPhase where
  | unknown
  | alive
  | dead
  | termSent
  | killSent
  deriving Repr, DecidableEq

def ProcPhase.encode : ProcPhase → UInt8
  | .unknown  => 0
  | .alive    => 1
  | .dead     => 2
  | .termSent => 3
  | .killSent => 4

def ProcPhase.decode? : Nat → Option ProcPhase
  | 0 => some .unknown
  | 1 => some .alive
  | 2 => some .dead
  | 3 => some .termSent
  | 4 => some .killSent
  | _ => none

inductive ProcOp where
  | observeAlive
  | observeDead
  | sigterm
  | sigkill
  deriving Repr, DecidableEq

def ProcOp.encode : ProcOp → UInt8
  | .observeAlive => 0
  | .observeDead  => 1
  | .sigterm      => 2
  | .sigkill      => 3

def ProcOp.decode? : Nat → Option ProcOp
  | 0 => some .observeAlive
  | 1 => some .observeDead
  | 2 => some .sigterm
  | 3 => some .sigkill
  | _ => none

 /-- Pure admission gate for process liveness (`SM-20`):
    - A leader is the pair `(pid, start_ticks)`. A different pid or different start ticks is not
      the same leader, so it cannot confirm liveness or admit a signal.
    - Missing `/proc` or a zombie does not count as alive.
    - Escalation is `alive (1) -> termSent (3) -> killSent (4) -> dead (2)`. `SIGTERM` (`opCode = 2`)
      is admitted only from `alive`. `SIGKILL` (`opCode = 3`) is admitted only from `termSent`, and
      still rechecks `(pid, start_ticks)` with `procMissing = 0` and `isZombie = 0` (no PID-reuse kill).
    - `observeDead` (`opCode = 1`) is admitted from `unknown`, `alive`, `termSent`, and `killSent`.
      `dead (2)` is terminal. A duplicate `SIGTERM` or `SIGKILL` is rejected. -/
@[inline]
def verifyProcLivenessAdmit
    (phaseCode opCode procMissing isZombie : UInt8)
    (expectedPid actualPid : UInt32)
    (expectedTicks actualTicks : UInt64) : UInt8 :=
  if phaseCode ≤ 4 &&
     opCode ≤ 3 &&
     expectedPid != 0 &&
     expectedTicks != 0 &&
     ((opCode == 0 && (phaseCode == 0 || phaseCode == 1) &&
       procMissing == 0 && isZombie == 0 &&
       actualPid == expectedPid && actualTicks == expectedTicks) ||
      (opCode == 1 && (phaseCode == 0 || phaseCode == 1 || phaseCode == 3 || phaseCode == 4) &&
       (procMissing == 1 || isZombie == 1 || actualPid != expectedPid ||
        actualTicks != expectedTicks)) ||
      (opCode == 2 && phaseCode == 1 &&
       procMissing == 0 && isZombie == 0 &&
       actualPid == expectedPid && actualTicks == expectedTicks) ||
      (opCode == 3 && phaseCode == 3 &&
       procMissing == 0 && isZombie == 0 &&
       actualPid == expectedPid && actualTicks == expectedTicks))
  then 1 else 0

@[inline]
def procLivenessTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 then 2
  else if opCode == 2 then 3
  else 4

structure ProcSliceState where
  phaseCode   : UInt8
  leaderPid   : UInt32
  leaderTicks : UInt64
  deriving Repr, DecidableEq

structure ProcSliceEvent where
  opCode      : UInt8
  procMissing : UInt8
  isZombie    : UInt8
  actualPid   : UInt32
  actualTicks : UInt64
  deriving Repr, DecidableEq

inductive ProcEffect where
  | persistLeader (phaseCode : UInt8) (pid : UInt32) (ticks : UInt64)
  | sendSignal (signal : UInt8) (pid : UInt32) (ticks : UInt64)
  deriving Repr, DecidableEq

def stepProcSlice (s : ProcSliceState) (ev : ProcSliceEvent) :
    ProcSliceState × List ProcEffect :=
  if verifyProcLivenessAdmit s.phaseCode ev.opCode ev.procMissing ev.isZombie
       s.leaderPid ev.actualPid s.leaderTicks ev.actualTicks == 1 then
    let nextPhase := procLivenessTargetPhase ev.opCode
    let effs : List ProcEffect :=
      if ev.opCode == 2 then
        [.persistLeader nextPhase s.leaderPid s.leaderTicks, .sendSignal 15 s.leaderPid s.leaderTicks]
      else if ev.opCode == 3 then
        [.persistLeader nextPhase s.leaderPid s.leaderTicks, .sendSignal 9 s.leaderPid s.leaderTicks]
      else
        [.persistLeader nextPhase s.leaderPid s.leaderTicks]
    ({ s with phaseCode := nextPhase }, effs)
  else
    (s, [])

/-! ## 5. `RelayCommand` (`SM-19`) -/

inductive RelayPhase where
  | pending
  | leased
  | accepted
  | uncertain
  deriving Repr, DecidableEq

def RelayPhase.encode : RelayPhase → UInt8
  | .pending   => 0
  | .leased    => 1
  | .accepted  => 2
  | .uncertain => 3

def RelayPhase.decode? : Nat → Option RelayPhase
  | 0 => some .pending
  | 1 => some .leased
  | 2 => some .accepted
  | 3 => some .uncertain
  | _ => none

def RelayPhase.isRetired : RelayPhase → Bool
  | .accepted => true
  | _ => false

inductive RelayOp where
  | lease
  | ack
  | markUncertain
  | reconcile
  | retry
  deriving Repr, DecidableEq

def RelayOp.encode : RelayOp → UInt8
  | .lease         => 0
  | .ack           => 1
  | .markUncertain => 2
  | .reconcile     => 3
  | .retry         => 4

def RelayOp.decode? : Nat → Option RelayOp
  | 0 => some .lease
  | 1 => some .ack
  | 2 => some .markUncertain
  | 3 => some .reconcile
  | 4 => some .retry
  | _ => none

/-- Pure admission gate for `RelayCommand` leased delivery (`SM-19`):
    - No pop-before-ack: `lease` moves `Pending (0) -> Leased (1)`, requires `presentedBootEpoch ==
      liveBootEpoch`, `liveBootEpoch != 0`, `presentedLeaseId != 0`, and `heldLeaseId == 0`,
      recording `leaseEpoch := nowEpoch` without retiring the command.
    - `ack` (`Leased (1) -> Accepted (2)`) requires `presentedLeaseId == heldLeaseId`,
      `heldLeaseId != 0`, and `presentedBootEpoch == liveBootEpoch`.
    - `markUncertain` (`Leased (1) -> Uncertain (3)`) records lost-ack ambiguity for the held lease
      on the matching boot epoch.
    - `reconcile` (`Uncertain (3) -> Accepted (2)` only) requires `presentedLeaseId == heldLeaseId`
      and matching boot epoch; never issues a fresh lease and never returns to `Pending`.
    - `retry` (`opCode == 4`) and any fresh `lease` from `Uncertain` or `Accepted` are rejected. -/
@[inline]
def verifyRelayCommandAdmit
    (phaseCode opCode : UInt8)
    (heldLeaseId presentedLeaseId liveBootEpoch presentedBootEpoch : UInt64) : UInt8 :=
  if phaseCode ≤ 3 &&
     opCode ≤ 4 &&
     liveBootEpoch != 0 &&
     presentedBootEpoch == liveBootEpoch &&
     presentedLeaseId != 0 &&
     ((opCode == 0 && phaseCode == 0 && heldLeaseId == 0) ||
      (opCode == 1 && phaseCode == 1 && heldLeaseId != 0 && presentedLeaseId == heldLeaseId) ||
      (opCode == 2 && phaseCode == 1 && heldLeaseId != 0 && presentedLeaseId == heldLeaseId) ||
      (opCode == 3 && phaseCode == 3 && heldLeaseId != 0 && presentedLeaseId == heldLeaseId))
  then 1 else 0

@[inline]
def relayCommandTargetPhase (opCode : UInt8) : UInt8 :=
  if opCode == 0 then 1
  else if opCode == 1 || opCode == 3 then 2
  else 3

@[inline]
def relayPhaseRetired (phaseCode : UInt8) : UInt8 :=
  if phaseCode == 2 then 1 else 0

structure RelaySliceState where
  phaseCode     : UInt8
  retired       : UInt8
  heldLeaseId   : UInt64
  leaseEpoch    : UInt64
  nodeBootEpoch : UInt64
  deriving Repr, DecidableEq

structure RelaySliceEvent where
  opCode             : UInt8
  presentedLeaseId   : UInt64
  presentedBootEpoch : UInt64
  nowEpoch           : UInt64
  deriving Repr, DecidableEq

inductive RelayEffect where
  | persistLease (leaseId : UInt64) (leaseEpoch : UInt64) (bootEpoch : UInt64)
  | persistUncertain (leaseId : UInt64) (bootEpoch : UInt64)
  | retireCommand (leaseId : UInt64) (bootEpoch : UInt64)
  deriving Repr, DecidableEq

def stepRelaySlice (s : RelaySliceState) (ev : RelaySliceEvent) :
    RelaySliceState × List RelayEffect :=
  if verifyRelayCommandAdmit s.phaseCode ev.opCode
       s.heldLeaseId ev.presentedLeaseId s.nodeBootEpoch ev.presentedBootEpoch == 1 then
    let nextPhase := relayCommandTargetPhase ev.opCode
    let nextLease : UInt64 := if ev.opCode == 0 then ev.presentedLeaseId else s.heldLeaseId
    let nextLeaseEpoch : UInt64 := if ev.opCode == 0 then ev.nowEpoch else s.leaseEpoch
    let nextRetired := relayPhaseRetired nextPhase
    let effs : List RelayEffect :=
      if ev.opCode == 0 then
        [.persistLease nextLease nextLeaseEpoch s.nodeBootEpoch]
      else if ev.opCode == 1 || ev.opCode == 3 then
        [.retireCommand nextLease s.nodeBootEpoch]
      else
        [.persistUncertain nextLease s.nodeBootEpoch]
    ({ s with
        phaseCode := nextPhase
        retired := nextRetired
        heldLeaseId := nextLease
        leaseEpoch := nextLeaseEpoch }, effs)
  else
    (s, [])

/-! ## 6. Orthogonal `R5WorldState` composition -/

structure R5WorldState where
  vm    : VmSliceState
  claim : ClaimSliceState
  job   : JobSliceState
  proc  : ProcSliceState
  relay : RelaySliceState
  deriving Repr, DecidableEq

def vmLifecycleSpecBlock :
    SpecBlock R5WorldState VmSliceState VmSliceEvent VmEffect where
  footprint := ⟨0x01, 0x01⟩
  project w := w.vm
  inject w s := { w with vm := s }
  step := stepVmSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def vmClaimSpecBlock :
    SpecBlock R5WorldState ClaimSliceState ClaimSliceEvent ClaimEffect where
  footprint := ⟨0x02, 0x02⟩
  project w := w.claim
  inject w s := { w with claim := s }
  step := stepClaimSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def remoteJobSpecBlock :
    SpecBlock R5WorldState JobSliceState JobSliceEvent JobEffect where
  footprint := ⟨0x04, 0x04⟩
  project w := w.job
  inject w s := { w with job := s }
  step := stepJobSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def processLivenessSpecBlock :
    SpecBlock R5WorldState ProcSliceState ProcSliceEvent ProcEffect where
  footprint := ⟨0x08, 0x08⟩
  project w := w.proc
  inject w s := { w with proc := s }
  step := stepProcSlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

def relayCommandSpecBlock :
    SpecBlock R5WorldState RelaySliceState RelaySliceEvent RelayEffect where
  footprint := ⟨0x10, 0x10⟩
  project w := w.relay
  inject w s := { w with relay := s }
  step := stepRelaySlice
  frame_get _ _ := rfl
  frame_set w := by cases w; rfl

end Orb.ManagedNode
