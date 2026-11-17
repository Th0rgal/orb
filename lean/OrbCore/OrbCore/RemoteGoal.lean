/- Pure remote goal settlement policy. No persistence, dispatch or scheduler.
   Admission must reuse Cyber.parseGoalPrefix? and preserve native bindings. -/
namespace OrbCore.RemoteGoal

inductive Capability where
  | unavailable | coreOpenCode | native
  deriving BEq, Repr

inductive AdmissionError where
  | unsupported | nativeContinuityRequired | emptyObjective
  deriving BEq, Repr

/-- Pure admission for a parsed objective. Capability is supplied by a verified
    adapter contract, never inferred from a harness name or this policy module. -/
def admit (capability : Capability) (nativeBound : Bool) (objective : String) :
    Except AdmissionError String :=
  if nativeBound then .error .nativeContinuityRequired
  else if capability != .coreOpenCode then .error .unsupported
  else if objective.trimAscii.toString.isEmpty then .error .emptyObjective
  else .ok objective

structure TurnFence where
  missionId : String
  goalRevision : Nat
  runGeneration : Nat
  jobId : String
  deriving BEq, Repr

inductive ParkReason where
  | stopped | blocked | paused | usageLimited | budgetLimited
  | unknownOutcome | failed | emptyOutput | noProgress | awaitingWakeup
  | awaitingSteering | continuationPending
  deriving BEq, Repr

inductive Phase where
  | active | complete | parked (reason : ParkReason)
  deriving BEq, Repr

structure GoalState where
  owner : TurnFence
  phase : Phase := .active
  settled : Bool := false
  continuations : Nat := 0
  noProgressTurns : Nat := 0
  deriving Repr

inductive ProcessOutcome where
  | succeeded | failed | unknown
  deriving BEq, Repr

inductive EvidenceKind where
  | finalAssistant | toolOutput | partialAssistant | transportOnly
  deriving BEq, Repr

inductive NativeStatus where
  | active | complete | blocked | paused | usageLimited | budgetLimited
  deriving BEq, Repr

structure TurnEvidence where
  owner : TurnFence
  outcome : ProcessOutcome
  /-- True only after the owning turn and its tool results have drained. -/
  drained : Bool := false
  finalText : String := ""
  kind : EvidenceKind := .transportOnly
  /-- Validated final-assistant evidence, never a substring/tool-output match. -/
  completionConfirmed : Bool := false
  madeProgress : Bool := false
  nativeStatus : Option NativeStatus := none
  deriving Repr

structure SettlementContext where
  stopCommitted : Bool := false
  steeringPending : Bool := false
  wakeupPending : Bool := false
  continuationPending : Bool := false
  maxContinuations : Option Nat := none
  maxNoProgress : Nat := 3
  deriving Repr

inductive Effect where
  | none | completed | park (reason : ParkReason) | requestContinuation
  deriving BEq, Repr

structure Decision where
  state : GoalState
  effect : Effect := .none
  deriving Repr

structure ContinuationIntent where
  /-- The settlement tuple is the identity, not an ambiguous concatenated key. -/
  settlement : TurnFence
  ordinal : Nat
  deriving BEq, Repr

structure DispatchBinding where
  occurrence : ContinuationIntent
  expectedOwner : TurnFence
  jobId : String
  nodeId : String
  /-- Opaque exact-payload identity supplied by the eventual durable owner. -/
  payloadIdentity : String
  deriving BEq, Repr

inductive DispatchObservation where
  | notSubmitted (reason : String)
  | accepted (binding : DispatchBinding)
  | uncertain (binding : DispatchBinding)
  deriving BEq, Repr

/-- Pure reconciliation guard, not a claim or receiver deduplication guarantee.
    Unknown acceptance must retain occurrence, job, node, payload and owner. -/
def sameDispatch (expected observed : DispatchBinding) : Bool := expected == observed

/-- Construct an intent only from a continuation decision. Repeated extraction
    yields the same identity; atomic persistence must deduplicate that tuple. -/
def continuationIntent (decision : Decision) : Option ContinuationIntent :=
  if decision.effect == .requestContinuation && decision.state.settled then
    some { settlement := decision.state.owner, ordinal := decision.state.continuations }
  else none

structure Projection where
  phase : Phase
  reconciliationRequired : Bool
  /-- Fencing an objective is not evidence that its process has terminated. -/
  executionTerminationKnown : Bool := false
  deriving BEq, Repr

def project (state : GoalState) : Projection := {
  phase := state.phase
  reconciliationRequired := state.phase == .parked .unknownOutcome
}

private def park (state : GoalState) (reason : ParkReason) : Decision :=
  { state := { state with phase := .parked reason, settled := true }, effect := .park reason }

/-- One owning terminal observation can settle once. Continuation requests are
    intents only: an approved transactional owner must commit and deliver them.
    A separate explicit admission transition is required to resume parked goals. -/
def decide (state : GoalState) (turn : TurnEvidence) (ctx : SettlementContext) : Decision := Id.run do
  if state.owner != turn.owner then return { state }
  if ctx.stopCommitted then
    if state.phase == .parked .stopped then return { state }
    return park state .stopped
  if state.settled || state.phase != .active then return { state }
  if turn.outcome == .unknown then return park state .unknownOutcome
  if !turn.drained then return { state }
  match turn.nativeStatus with
  | some .blocked => return park state .blocked
  | some .paused => return park state .paused
  | some .usageLimited => return park state .usageLimited
  | some .budgetLimited => return park state .budgetLimited
  | _ => pure ()
  if turn.outcome == .failed then return park state .failed
  -- A transport status, partial text or tool result is not a final response.
  if turn.kind != .finalAssistant then return park state .unknownOutcome
  if turn.finalText.trimAscii.toString.isEmpty then return park state .emptyOutput
  -- An active native goal cannot be completed by an outer prose marker.
  let complete := match turn.nativeStatus with
    | some .complete => true
    | some _ => false
    | none => turn.completionConfirmed
  if complete then
    return { state := { state with phase := .complete, settled := true }, effect := .completed }
  -- Native active status belongs to its driver, including its budget policy.
  if turn.nativeStatus == some .active then return { state }
  if ctx.steeringPending then return park state .awaitingSteering
  if ctx.wakeupPending then return park state .awaitingWakeup
  if ctx.continuationPending then return park state .continuationPending
  if let some limit := ctx.maxContinuations then
    if state.continuations >= limit then return park state .budgetLimited
  let noProgress := if turn.madeProgress then 0 else state.noProgressTurns + 1
  let next := { state with noProgressTurns := noProgress }
  if noProgress >= max 1 ctx.maxNoProgress then return park next .noProgress
  return {
    state := { next with settled := true, continuations := state.continuations + 1 }
    effect := .requestContinuation
  }

end OrbCore.RemoteGoal
