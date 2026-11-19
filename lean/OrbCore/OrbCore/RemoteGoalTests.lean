import OrbCore.RemoteGoal

namespace OrbCore.RemoteGoalTests
open OrbCore.RemoteGoal

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"remote goal: {label}")

private def fence : TurnFence := ⟨"mission", 2, 3, "job"⟩
private def initial : GoalState := { owner := fence }
private def progress : TurnEvidence := {
  owner := fence, outcome := .succeeded, drained := true,
  kind := .finalAssistant,
  finalText := "Implemented one step; verification remains.", madeProgress := true }

def run : IO Unit := do
  check (hasCompletionMarker "Verified.\r\n<!-- GOAL_COMPLETE -->\r\n\n") "standalone final marker"
  for text in #["I read <!-- GOAL_COMPLETE -->", "<!-- GOAL_COMPLETE -->\nStill working",
      "> <!-- GOAL_COMPLETE -->", "```html\n<!-- GOAL_COMPLETE -->\n```", "~~~html\n<!-- GOAL_COMPLETE -->"] do
    check (!hasCompletionMarker text) "quoted, fenced or nonfinal marker ignored"
  check (match admit .unavailable false "objective" with | .error .unsupported => true | _ => false) "unavailable is fail closed"
  check (match admit .coreOpenCode true "objective" with | .error .nativeContinuityRequired => true | _ => false)
    "native binding cannot be converted to emulation"
  check (match admit .coreOpenCode false " \n" with | .error .emptyObjective => true | _ => false) "empty objective refused"
  let exactObjective := "  Preserve quotes ' and \" and \\ plus Unicode λ\nfull objective  "
  check (match admit .coreOpenCode false exactObjective with | .ok s => s == exactObjective | _ => false) "objective preserved exactly"
  let next := decide initial progress {}
  check (next.effect == .requestContinuation) "plain successful turn continues"
  check ((decide next.state progress {}).effect == .none) "duplicate terminal ignored"
  check (next.state.continuations == 1) "one continuation intent"
  check (continuationIntent next == some ⟨fence, 1⟩) "intent bound to settlement tuple"
  check (continuationIntent (decide next.state progress {}) == none) "replay produces no intent"
  for stale in #[{ fence with jobId := "older" }, { fence with runGeneration := 2 },
      { fence with goalRevision := 1 }, { fence with missionId := "other" }] do
    check ((decide initial { progress with owner := stale } {}).effect == .none) "stale owner"
  let stopped := decide initial progress { stopCommitted := true }
  check (stopped.effect == .park .stopped) "stop before settlement"
  check ((decide stopped.state { progress with completionConfirmed := true } {}).effect == .none)
    "late completion cannot rearm stop"
  check ((decide next.state progress { stopCommitted := true }).effect == .park .stopped)
    "stop after continuation intent"
  check ((decide initial { progress with outcome := .unknown, completionConfirmed := true } {}).effect == .park .unknownOutcome)
    "unknown outcome cannot complete or retry"
  check ((decide initial { progress with finalText := " \n", completionConfirmed := true } {}).effect == .park .emptyOutput)
    "empty output cannot complete"
  check ((decide initial { progress with outcome := .failed, completionConfirmed := true } {}).effect == .park .failed)
    "failed process cannot complete"
  for (status, reason) in #[(NativeStatus.blocked, ParkReason.blocked), (.paused, .paused),
      (.usageLimited, .usageLimited), (.budgetLimited, .budgetLimited)] do
    let stop := { progress with nativeStatus := some status, completionConfirmed := true }
    let beforeDrain := decide initial { stop with drained := false } {}
    check (beforeDrain.effect == .none) "native stop waits for drain"
    let drained := decide beforeDrain.state stop {}
    check (drained.effect == .park reason) "native stop overrides prose completion"
    check ((decide drained.state stop {}).effect == .none) "native stop replay"
  check ((decide initial { progress with nativeStatus := some .active, completionConfirmed := true } {}).effect == .none)
    "native active never starts emulated turn"
  check ((decide initial { progress with completionConfirmed := true } {}).effect == .completed)
    "confirmed final evidence completes"
  check ((decide initial progress { maxContinuations := some 0 }).effect == .park .budgetLimited)
    "zero budget does not dispatch"
  check ((decide initial progress { steeringPending := true, wakeupPending := true }).effect == .park .awaitingSteering)
    "steering precedence"
  check ((decide initial progress { wakeupPending := true }).effect == .park .awaitingWakeup)
    "existing wakeup prevents competing timer"
  check ((decide initial progress { continuationPending := true }).effect == .park .continuationPending)
    "existing continuation prevents duplicate"
  let stalled := { initial with noProgressTurns := 2 }
  check ((decide stalled { progress with madeProgress := false } {}).effect == .park .noProgress)
    "bounded no-progress loop"
  check ((decide stalled progress {}).state.noProgressTurns == 0) "progress resets streak"
  let activeNative := { progress with nativeStatus := some .active }
  check ((decide initial activeNative { maxContinuations := some 0 }).effect == .none)
    "emulation budget cannot stop a native driver"
  let pendingNative := { progress with nativeStatus := some .blocked, drained := false }
  let pending := decide initial pendingNative {}
  check ((decide pending.state activeNative {}).effect == .none)
    "authoritative reactivation before drain does not settle earlier stop"
  let uncertain := decide initial { progress with outcome := .unknown } {}
  check ((decide uncertain.state progress {}).effect == .none)
    "ordinary late success cannot bypass unknown-outcome reconciliation"
  let complete := decide initial { progress with completionConfirmed := true } {}
  check ((decide complete.state progress {}).effect == .none)
    "late progress cannot restart a complete goal"
  let secondOwner := { fence with runGeneration := 4, jobId := "job-2" }
  let secondTurn := { next.state with owner := secondOwner, settled := false }
  let secondEvidence := { progress with owner := secondTurn.owner }
  check ((decide secondTurn secondEvidence { maxContinuations := some 1 }).effect == .park .budgetLimited)
    "admitted next turn retains exhausted continuation count"
  check ((decide secondTurn progress {}).effect == .none)
    "first-turn replay cannot settle admitted second turn"
  for kind in #[EvidenceKind.toolOutput, .partialAssistant, .transportOnly] do
    check ((decide initial { progress with kind := kind, completionConfirmed := true } {}).effect == .park .unknownOutcome)
      "non-final evidence cannot complete or trigger another job"
  let cancelling := decide initial { progress with outcome := .unknown } { stopCommitted := true }
  check (cancelling.effect == .park .stopped && cancelling.state.continuations == 0)
    "stop fences work despite unknown transport, without claiming termination"
  check (!(project cancelling.state).executionTerminationKnown) "stop is not termination proof"
  check ((project uncertain.state).reconciliationRequired) "unknown projection requires reconciliation"
  check (continuationIntent cancelling == none) "stop cannot create intent"
  let binding : DispatchBinding := {
    occurrence := ⟨fence, 1⟩, expectedOwner := fence,
    jobId := "next-job", nodeId := "same-node", payloadIdentity := "exact-payload" }
  check (sameDispatch binding binding) "same uncertain dispatch can be reconciled"
  for changed in #[{ binding with jobId := "fresh-job" },
      { binding with nodeId := "different-node" },
      { binding with payloadIdentity := "replacement" },
      { binding with expectedOwner := { fence with runGeneration := 4 } },
      { binding with occurrence := ⟨fence, 2⟩ }] do
    check (!sameDispatch binding changed) "reconciliation cannot adopt replacement identity"

end OrbCore.RemoteGoalTests
