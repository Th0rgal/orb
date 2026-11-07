/-
  OrbCore.RunCoordinator: Phase R3-B single authoritative run coordinator (`SM-03`).

  One state machine owns mission phase, run phase, `run_generation`, `owner_epoch`,
  `caller_epoch`, `active_tool_calls`, and pending structured receipts. Run transitions
  go through `Orb.Lifecycle.verifyRunLifecycleAdmit` / `Orb.Lifecycle.stepRunSlice`.
  Mission phase is the image of `Orb.Lifecycle.verifyMissionLifecycleAdmit` /
  `Orb.Lifecycle.stepMissionSlice` — never a hardcoded phase table. Control view is a
  pure projection of that state.

  Completion is a structured tool receipt (tool name, `ok = true`, and a message id
  distinct from the mission id), never a prose match. A missing ToolResult is
  reconciled by a bounded idempotent crash tombstone that drives
  `active_tool_calls` to zero. A normal drain with zero live calls records no tombstone.
-/
import Orb.Lifecycle

namespace OrbCore.RunCoordinator

open Orb.Lifecycle

/-- Structured tool-execution receipt. Completion is this record, never a prose substring. -/
structure ToolReceipt where
  toolName : String
  ok : Bool
  messageId : String
  missionId : String
  deriving Repr, DecidableEq

/-- One in-flight tool call. `tombstoned` records a crash reconcile. -/
structure ActiveToolCall where
  callId : String
  toolName : String
  tombstoned : Bool := false
  deriving Repr, DecidableEq

/-- Authoritative coordinator state. There is no second mutable runner. -/
structure CoordinatorState where
  missionId : String
  missionPhase : UInt8
  runPhase : UInt8
  runGeneration : UInt64
  ownerEpoch : UInt64
  callerEpoch : UInt64
  ownerSuperseded : UInt8 := 0
  activeToolCalls : Array ActiveToolCall := #[]
  pendingReceipts : Array ToolReceipt := #[]
  crashTombstones : UInt32 := 0
  deriving Repr, DecidableEq

/-- Read-only control projection. Derived only from `CoordinatorState`. -/
structure ControlProjection where
  missionId : String
  missionPhase : UInt8
  runPhase : UInt8
  runGeneration : UInt64
  ownerEpoch : UInt64
  callerEpoch : UInt64
  ownerSuperseded : Bool
  activeToolCalls : UInt32
  pendingReceipts : UInt32
  crashTombstones : UInt32
  deriving Repr, DecidableEq

/-- Outcome of a terminal turn. `messageId` is the receipt id, never the mission id. -/
structure CompletionPoll where
  completed : Bool
  messageId : String
  ok : Bool
  deriving Repr, DecidableEq

def liveToolCount (calls : Array ActiveToolCall) : UInt32 :=
  let n := (calls.filter (fun c => !c.tombstoned)).size
  (Nat.min n 0xFFFFFFFF).toUInt32

def projectControl (s : CoordinatorState) : ControlProjection :=
  { missionId := s.missionId
    missionPhase := s.missionPhase
    runPhase := s.runPhase
    runGeneration := s.runGeneration
    ownerEpoch := s.ownerEpoch
    callerEpoch := s.callerEpoch
    ownerSuperseded := s.ownerSuperseded != 0
    activeToolCalls := liveToolCount s.activeToolCalls
    pendingReceipts := (Nat.min s.pendingReceipts.size 0xFFFFFFFF).toUInt32
    crashTombstones := s.crashTombstones }

def phasesInDomain (s : CoordinatorState) : Bool :=
  (MissionPhase.decode? s.missionPhase.toNat).isSome &&
  (RunPhase.decode? s.runPhase.toNat).isSome

def canMutateInFlight (s : CoordinatorState) : Bool :=
  s.ownerSuperseded == 0 &&
  match MissionPhase.decode? s.missionPhase.toNat, RunPhase.decode? s.runPhase.toNat with
  | some mp, some rp =>
    !mp.isTerminal && (rp == .claimed || rp == .running || rp == .drainingTools)
  | _, _ => false

def isStructuredReceipt (s : CoordinatorState) (r : ToolReceipt) : Bool :=
  !r.toolName.isEmpty && !r.messageId.isEmpty && r.messageId != r.missionId && r.messageId != s.missionId

def missionOpForRun (runOp : UInt8) : Option MissionOp :=
  if runOp == RunOp.encode .claimFreshGeneration then some .dispatchRun
  else if runOp == RunOp.encode .failTurn then some .failRun
  else if runOp == RunOp.encode .abortTurnReceipt then some .finalizeCancelReceipt
  else none

def stepCoupledMission (s : CoordinatorState) (runOp hasStructuredReceipt hasAbortReceipt markSup : UInt8)
    (callerEpoch : UInt64) : Option UInt8 :=
  let _ := hasStructuredReceipt
  match MissionPhase.decode? s.missionPhase.toNat, RunPhase.decode? s.runPhase.toNat with
  | none, _ => none
  | _, none => none
  | some mp, some _ =>
    let slice : MissionSliceState := {
      phaseCode := s.missionPhase
      superseded := s.ownerSuperseded
      resumeIntent := 0
      ownerEpoch := s.ownerEpoch
      notBeforeEpoch := 0
      stateRevision := 0
    }
    if markSup == 1 then
      match mp with
      | .completed | .failed | .cancelled =>
        if s.ownerSuperseded == 0 && s.ownerEpoch != 0 && callerEpoch == s.ownerEpoch then
          some s.missionPhase
        else
          none
      | _ =>
        let ev : MissionSliceEvent := {
          opCode := MissionOp.encode .dispatchRun
          hasEvidence := 0
          hasTermReceipt := 0
          reqResumeInt := 0
          callerEpoch := callerEpoch
          nowEpoch := 0
          reqNotBefore := 0
          markSuperseded := 1
        }
        let (next, effs) := stepMissionSlice slice ev
        if effs.isEmpty then none else some next.phaseCode
    else
      match missionOpForRun runOp with
      | none =>
        if runOp == RunOp.encode .confirmSpawned && mp != .active then
          if verifyMissionLifecycleAdmit s.missionPhase (MissionOp.encode .dispatchRun)
               s.ownerSuperseded 0 0 0 s.ownerEpoch callerEpoch 0 0 != 1 then
            none
          else
            let ev : MissionSliceEvent := {
              opCode := MissionOp.encode .dispatchRun
              hasEvidence := 0
              hasTermReceipt := 0
              reqResumeInt := 0
              callerEpoch := callerEpoch
              nowEpoch := 0
              reqNotBefore := 0
              markSuperseded := 0
            }
            let (next, effs) := stepMissionSlice slice ev
            if effs.isEmpty then none else some next.phaseCode
        else if mp == .active then
          some s.missionPhase
        else
          none
      | some mop =>
        let opCode := MissionOp.encode mop
        let hasTerm : UInt8 := if runOp == RunOp.encode .abortTurnReceipt then hasAbortReceipt else 0
        if mop == .dispatchRun && mp == .active then
          if s.ownerSuperseded == 0 && s.ownerEpoch != 0 && callerEpoch == s.ownerEpoch then
            some s.missionPhase
          else
            none
        else if verifyMissionLifecycleAdmit s.missionPhase opCode s.ownerSuperseded 0 hasTerm 0
             s.ownerEpoch callerEpoch 0 0 != 1 then
          none
        else
          let ev : MissionSliceEvent := {
            opCode := opCode
            hasEvidence := 0
            hasTermReceipt := hasTerm
            reqResumeInt := 0
            callerEpoch := callerEpoch
            nowEpoch := 0
            reqNotBefore := 0
            markSuperseded := 0
          }
          let (next, effs) := stepMissionSlice slice ev
          if effs.isEmpty then none else some next.phaseCode

/-- Tombstone every still-live call and count each one, saturating at `UInt32.max`. -/
def tombstoneLive (s : CoordinatorState) : CoordinatorState :=
  let live := s.activeToolCalls.filter fun c => !c.tombstoned
  if live.isEmpty then s
  else
    let added := (Nat.min live.size (0xFFFFFFFF - s.crashTombstones.toNat)).toUInt32
    { s with
      activeToolCalls := s.activeToolCalls.map fun c =>
        if c.tombstoned then c else { c with tombstoned := true }
      crashTombstones := s.crashTombstones + added }

/-- Apply one `RunSliceEvent` through `stepRunSlice`, inspecting `(next, effs)`:
    - Refused steps (`effs.isEmpty`) leave `CoordinatorState` unchanged.
    - When `stepRunSlice` emits `.clearWedgedToolCalls` or drives `next.activeToolCalls == 0`
      on terminal `failed` / `aborted` while live calls existed, live calls are tombstoned
      and `crashTombstones` increments (never silently dropped).
    - Normal zero-call drain (`opCode = reconcileDrainedTools`, `drainTimedOut = 0`) or fresh
      generation claim (`opCode = claimFreshGeneration`) clears retired rows without adding tombstones.
    - `markOwnerSuperseded = 1` preserves `phaseCode`, `activeToolCalls`, and `pendingReceipts`. -/
def applyRun (s : CoordinatorState) (ev : RunSliceEvent) : CoordinatorState :=
  if !phasesInDomain s then s
  else
    let liveBefore := liveToolCount s.activeToolCalls
    let slice : RunSliceState := {
      phaseCode := s.runPhase
      ownerSuperseded := s.ownerSuperseded
      activeToolCalls := liveBefore
      runGeneration := s.runGeneration
      durableOwnerEpoch := s.ownerEpoch
    }
    let (next, effs) := stepRunSlice slice ev
    if effs.isEmpty then s
    else
      match stepCoupledMission s ev.opCode ev.hasStructuredReceipt ev.hasAbortReceipt
              ev.markOwnerSuperseded ev.callerOwnerEpoch with
      | none => s
      | some nextMissionPhase =>
        let clearedWedged := effs.any fun
          | .clearWedgedToolCalls _ => true
          | _ => false
        let terminalForcedClear :=
          ev.markOwnerSuperseded == 0 &&
          liveBefore > 0 &&
          next.activeToolCalls == 0 &&
          (next.phaseCode == RunPhase.encode .failed || next.phaseCode == RunPhase.encode .aborted)
        let tombstonedState :=
          if clearedWedged || terminalForcedClear then tombstoneLive s else s
        let tools :=
          if ev.markOwnerSuperseded == 1 then s.activeToolCalls
          else if clearedWedged || terminalForcedClear then tombstonedState.activeToolCalls
          else if next.activeToolCalls == 0 then #[]
          else s.activeToolCalls
        let receipts :=
          if ev.markOwnerSuperseded == 0 && next.phaseCode ≥ RunPhase.encode .completed then #[]
          else s.pendingReceipts
        { s with
          missionPhase := nextMissionPhase
          runPhase := next.phaseCode
          ownerSuperseded := next.ownerSuperseded
          runGeneration := next.runGeneration
          callerEpoch := ev.callerOwnerEpoch
          activeToolCalls := tools
          pendingReceipts := receipts
          crashTombstones := tombstonedState.crashTombstones }

def applyRunChecked (s : CoordinatorState) (ev : RunSliceEvent) (errTag : String) :
    Except String CoordinatorState :=
  let next := applyRun s ev
  if next == s then .error errTag else .ok next

def admitsRun (s : CoordinatorState) (op : RunOp) (hasStructuredReceipt hasAbortReceipt drainTimedOut : UInt8)
    (toolCalls : UInt32) (proposedGeneration callerEpoch : UInt64) : Bool :=
  phasesInDomain s &&
  verifyRunLifecycleAdmit s.runPhase (RunOp.encode op) s.ownerSuperseded hasStructuredReceipt hasAbortReceipt
    drainTimedOut toolCalls s.runGeneration proposedGeneration s.ownerEpoch callerEpoch == 1

/-- Superseded owners or terminal missions cannot start a run. -/
def startRun (s : CoordinatorState) (callerEpoch proposedGeneration : UInt64) : Except String CoordinatorState :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else if s.ownerSuperseded != 0 || callerEpoch != s.ownerEpoch then
    .error "superseded_or_stale_owner"
  else if !admitsRun s .claimFreshGeneration 0 0 0 0 proposedGeneration callerEpoch then
    .error "run_admit_rejected"
  else
    applyRunChecked s {
      opCode := RunOp.encode .claimFreshGeneration
      hasStructuredReceipt := 0
      hasAbortReceipt := 0
      drainTimedOut := 0
      markOwnerSuperseded := 0
      nextToolCalls := 0
      proposedGeneration := proposedGeneration
      callerOwnerEpoch := callerEpoch
    } "run_admit_rejected"

/-- Spawn confirmation (`claimed` → `running`) at the current generation. -/
def confirmSpawned (s : CoordinatorState) (callerEpoch : UInt64) : Except String CoordinatorState :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else if !admitsRun s .confirmSpawned 0 0 0 (liveToolCount s.activeToolCalls) s.runGeneration callerEpoch then
    .error "confirm_rejected"
  else
    applyRunChecked s {
      opCode := RunOp.encode .confirmSpawned
      hasStructuredReceipt := 0
      hasAbortReceipt := 0
      drainTimedOut := 0
      nextToolCalls := liveToolCount s.activeToolCalls
      proposedGeneration := s.runGeneration
      callerOwnerEpoch := callerEpoch
    } "confirm_rejected"

/-- Record a tool call only while unsuperseded, non-terminal, and in-flight (`1..3`). -/
def noteToolCall (s : CoordinatorState) (callId toolName : String) : CoordinatorState :=
  if !canMutateInFlight s || callId.isEmpty || liveToolCount s.activeToolCalls == 0xFFFFFFFF then s
  else if s.activeToolCalls.any (fun c => c.callId == callId && !c.tombstoned) then s
  else { s with activeToolCalls := s.activeToolCalls.push { callId := callId, toolName := toolName } }

/-- Retire a live tool call when its normal `ToolResult` arrives (only while unsuperseded and in-flight). -/
def finishToolCall (s : CoordinatorState) (callId : String) : CoordinatorState :=
  if !canMutateInFlight s then s
  else { s with activeToolCalls := s.activeToolCalls.filter (fun c => c.callId != callId || c.tombstoned) }

/-- Enter tool drain only while at least one live tool call is outstanding. -/
def enterToolDrain (s : CoordinatorState) (callerEpoch : UInt64) : Except String CoordinatorState :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else
    let n := liveToolCount s.activeToolCalls
    if !admitsRun s .enterToolDrain 0 0 0 n s.runGeneration callerEpoch then
      .error "drain_rejected"
    else
      applyRunChecked s {
        opCode := RunOp.encode .enterToolDrain
        hasStructuredReceipt := 0
        hasAbortReceipt := 0
        drainTimedOut := 0
        nextToolCalls := n
        proposedGeneration := s.runGeneration
        callerOwnerEpoch := callerEpoch
      } "drain_rejected"

/-- Normal drained exit: `drainingTools` with zero live calls returns to `running`
    through `reconcileDrainedTools` and `drainTimedOut = 0`. No crash tombstone is recorded. -/
def finishDrainedTools (s : CoordinatorState) (callerEpoch : UInt64) : Except String CoordinatorState :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else
    let n := liveToolCount s.activeToolCalls
    if s.runPhase != RunPhase.encode .drainingTools || n != 0 then
      .error "drain_not_clear"
    else if !admitsRun s .reconcileDrainedTools 0 0 0 0 s.runGeneration callerEpoch then
      .error "drain_finish_rejected"
    else
      applyRunChecked s {
        opCode := RunOp.encode .reconcileDrainedTools
        hasStructuredReceipt := 0
        hasAbortReceipt := 0
        drainTimedOut := 0
        nextToolCalls := 0
        proposedGeneration := s.runGeneration
        callerOwnerEpoch := callerEpoch
      } "drain_finish_rejected"

/-- Missing-`ToolResult` reconcile. From `running` with live calls, steps
    `enterToolDrain` then `reconcileDrainedTools` with `drainTimedOut = 1` so
    `stepRunSlice` emits `.clearWedgedToolCalls` (`2 → 3 → 2`). From `drainingTools`
    with live calls, the timed-out drain admits directly. Each retired live call records
    one crash tombstone. Already clear and not draining (for a valid unsuperseded owner) is a no-op. -/
def reconcileMissingToolResult (s : CoordinatorState) (callerEpoch : UInt64) :
    Except String CoordinatorState :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else if s.ownerSuperseded != 0 || s.ownerEpoch == 0 || callerEpoch != s.ownerEpoch then
    .error "superseded_or_stale_owner"
  else
    let n := liveToolCount s.activeToolCalls
    if n == 0 && s.runPhase != RunPhase.encode .drainingTools then
      .ok s
    else if n == 0 then
      finishDrainedTools s callerEpoch
    else
      let drainedRes : Except String CoordinatorState :=
        if s.runPhase == RunPhase.encode .running then enterToolDrain s callerEpoch
        else if s.runPhase == RunPhase.encode .drainingTools then .ok s
        else .error "reconcile_rejected"
      match drainedRes with
      | .error err => .error err
      | .ok drained =>
        let live := liveToolCount drained.activeToolCalls
        if !admitsRun drained .reconcileDrainedTools 0 0 1 live drained.runGeneration callerEpoch then
          .error "reconcile_rejected"
        else
          applyRunChecked drained {
            opCode := RunOp.encode .reconcileDrainedTools
            hasStructuredReceipt := 0
            hasAbortReceipt := 0
            drainTimedOut := 1
            nextToolCalls := live
            proposedGeneration := drained.runGeneration
            callerOwnerEpoch := callerEpoch
          } "reconcile_rejected"

/-- Queue a structured receipt only while unsuperseded, non-terminal, and in-flight.
    Prose is ignored: only `ToolReceipt` values are stored. -/
def pushReceipt (s : CoordinatorState) (r : ToolReceipt) : CoordinatorState :=
  if !canMutateInFlight s || !isStructuredReceipt s r || r.missionId != s.missionId then s
  else if s.pendingReceipts.any (fun p => p.messageId == r.messageId) then s
  else { s with pendingReceipts := s.pendingReceipts.push r }

/-- Receipt id for a panic/fail poll: the stored message id, or `""`. Never `missionId`. -/
def failMessageId (s : CoordinatorState) : String :=
  match s.pendingReceipts.find? (isStructuredReceipt s) with
  | some r => if r.messageId == s.missionId then "" else r.messageId
  | none => ""

/-- Complete only from `running` with zero live tools and a structured `ok = true` receipt.
    An `ok = false` receipt is not a completion; route it through `failTurn`.
    By default (`parkMission := false`), `completeTurn` finalizes both `RunPhase` (`completed = 4`)
    and `MissionPhase` (`completed = 5` via `MissionOp.completeWithReceipt`), making the mission
    permanently terminal. Pass `parkMission := true` when parking a multi-turn mission between
    turns (`MissionOp.parkAwaitingUser` -> `awaitingUser = 0`) so `claimNextGeneration` can step
    `runGeneration + 1`. -/
def completeTurn (s : CoordinatorState) (callerEpoch : UInt64) (parkMission : Bool := false) :
    Except String (CoordinatorState × CompletionPoll) :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else
    match s.pendingReceipts.find? fun r => isStructuredReceipt s r && r.ok with
    | none => .error "completion_requires_structured_receipt"
    | some r =>
      if liveToolCount s.activeToolCalls != 0 then
        .error "tools_still_active"
      else if !admitsRun s .completeTurnReceipt 1 0 0 0 s.runGeneration callerEpoch then
        .error "complete_rejected"
      else
        let mop : MissionOp := if parkMission then .parkAwaitingUser else .completeWithReceipt
        let hasEv : UInt8 := if parkMission then 0 else 1
        if verifyMissionLifecycleAdmit s.missionPhase (MissionOp.encode mop) s.ownerSuperseded
             hasEv 0 0 s.ownerEpoch callerEpoch 0 0 != 1 then
          .error "complete_rejected"
        else
          let mSlice : MissionSliceState := {
            phaseCode := s.missionPhase
            superseded := s.ownerSuperseded
            resumeIntent := 0
            ownerEpoch := s.ownerEpoch
            notBeforeEpoch := 0
            stateRevision := 0
          }
          let (mNext, mEffs) := stepMissionSlice mSlice {
            opCode := MissionOp.encode mop
            hasEvidence := hasEv
            hasTermReceipt := 0
            reqResumeInt := 0
            callerEpoch := callerEpoch
            nowEpoch := 0
            reqNotBefore := 0
            markSuperseded := 0
          }
          if mEffs.isEmpty then
            .error "complete_rejected"
          else
            match applyRunChecked s {
              opCode := RunOp.encode .completeTurnReceipt
              hasStructuredReceipt := 1
              hasAbortReceipt := 0
              drainTimedOut := 0
              nextToolCalls := 0
              proposedGeneration := s.runGeneration
              callerOwnerEpoch := callerEpoch
            } "complete_rejected" with
            | .error err => .error err
            | .ok next =>
              let finalSt := { next with missionPhase := mNext.phaseCode }
              .ok (finalSt, {
                completed := finalSt.runPhase == RunPhase.encode .completed
                messageId := r.messageId
                ok := true
              })

/-- Fail or panic the turn. Live calls are tombstoned by `applyRun` when the kernel
    clears them, never erased with `crashTombstones = 0`. `messageId` is the receipt id
    when one exists, otherwise `""`, and never `missionId`. -/
def failTurn (s : CoordinatorState) (callerEpoch : UInt64) : Except String (CoordinatorState × CompletionPoll) :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else if !admitsRun s .failTurn 0 0 0 (liveToolCount s.activeToolCalls) s.runGeneration callerEpoch then
    .error "fail_rejected"
  else
    let mid := failMessageId s
    match applyRunChecked s {
      opCode := RunOp.encode .failTurn
      hasStructuredReceipt := 0
      hasAbortReceipt := 0
      drainTimedOut := 0
      nextToolCalls := liveToolCount s.activeToolCalls
      proposedGeneration := s.runGeneration
      callerOwnerEpoch := callerEpoch
    } "fail_rejected" with
    | .error err => .error err
    | .ok next =>
      .ok (next, { completed := false, messageId := mid, ok := false })

/-- Abort the turn on an explicit termination receipt. Live calls are tombstoned. -/
def abortTurn (s : CoordinatorState) (callerEpoch : UInt64) (hasAbortReceipt : Bool) :
    Except String (CoordinatorState × CompletionPoll) :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else
    let recBit : UInt8 := if hasAbortReceipt then 1 else 0
    if !admitsRun s .abortTurnReceipt 0 recBit 0 (liveToolCount s.activeToolCalls) s.runGeneration callerEpoch then
      .error "abort_rejected"
    else
      let mid := failMessageId s
      match applyRunChecked s {
        opCode := RunOp.encode .abortTurnReceipt
        hasStructuredReceipt := 0
        hasAbortReceipt := recBit
        drainTimedOut := 0
        nextToolCalls := liveToolCount s.activeToolCalls
        proposedGeneration := s.runGeneration
        callerOwnerEpoch := callerEpoch
      } "abort_rejected" with
      | .error err => .error err
      | .ok next =>
        .ok (next, { completed := false, messageId := mid, ok := false })

/-- Mark the durable owner superseded through `stepRunSlice` (`markOwnerSuperseded = 1`)
    and `stepMissionSlice`. In-flight calls and receipts stay put; later mutations fail closed. -/
def markSuperseded (s : CoordinatorState) (callerEpoch : UInt64) : Except String CoordinatorState :=
  if !phasesInDomain s then
    .error "phase_out_of_domain"
  else if s.ownerSuperseded != 0 || s.ownerEpoch == 0 || callerEpoch != s.ownerEpoch then
    .error "supersede_rejected"
  else
    applyRunChecked s {
      opCode := RunOp.encode .claimFreshGeneration
      hasStructuredReceipt := 0
      hasAbortReceipt := 0
      drainTimedOut := 0
      markOwnerSuperseded := 1
      nextToolCalls := liveToolCount s.activeToolCalls
      proposedGeneration := s.runGeneration
      callerOwnerEpoch := callerEpoch
    } "supersede_rejected"

/-- A completed run (`RunPhase = completed (4)`) on a non-terminal mission does not re-enter
    `running` unless `proposedGeneration = runGeneration + 1`. Terminal missions (`5, 6, 7`)
    never admit another generation. -/
def claimNextGeneration (s : CoordinatorState) (callerEpoch proposedGeneration : UInt64) :
    Except String CoordinatorState :=
  startRun s callerEpoch proposedGeneration

def fresh (missionId : String) (ownerEpoch : UInt64) : CoordinatorState :=
  { missionId := missionId
    missionPhase := MissionPhase.encode .awaitingUser
    runPhase := RunPhase.encode .idle
    runGeneration := 0
    ownerEpoch := ownerEpoch
    callerEpoch := ownerEpoch }

end OrbCore.RunCoordinator
