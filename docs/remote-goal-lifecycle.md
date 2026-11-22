# Remote goal lifecycle

## Core-emulated remote OpenCode, Codex and Antigravity

Core advertises OpenCode, Codex and Antigravity in `remote_launch.goal_harnesses` when the typed remote
adapter is available. The mission-create endpoint independently rejects an empty
Goal objective or an unsupported remote harness before creating a mission.
An ordinary follow-up after a completed Goal starts a standard turn in the same
mission and harness session. The completed objective remains in history. It cannot
arm another continuation, including for missions completed by an older Core.
If the node accepts the follow-up but its acknowledgement is lost, Core checks
that exact job on the original node. Adoption requires the completed Goal’s
generation and job to still match. A superseded follow-up cannot claim its
successor’s run.
Remote follow-ups to an unfinished Goal steer the existing mission; `/goal` can only start a new
remote mission. Rejected commands leave the transcript and queue untouched.

Antigravity runs in stream-json mode. Its init event binds the mission to a native
conversation UUID. A continuation passes that UUID to `agy --conversation`.
Agent response deltas supply the text used by Goal settlement. Tool events and
usage records do not contribute completion text. The final response supplies
the text if no deltas arrived. A terminal provider error remains a failed turn.

After a successful Goal job drains, a standalone `<!-- GOAL_COMPLETE -->`
on the final assistant line outside a fenced code block is completion evidence.
An unfinished response can arm one durable continuation in the same harness
session. OpenCode resumes its `ses_` session and Codex resumes the thread UUID
reported by `codex exec --json`. Core parks when that session is missing or the limit of 20 automatic
continuations is reached. Goal progress and the terminal reason are available
in mission detail as well as in structured events.
If the terminal log cannot be read through its confirmed end, Core parks the
Goal with `remote_goal_evidence_incomplete`; partial evidence cannot complete
the Goal or arm a continuation.

For remote Codex Goals, the final assistant message shows a result once when
two successive, distinct completed assistant items in the same job contain
the same result and the second adds only the standalone completion marker.
The log and both cumulative streaming snapshots keep their original text.
Intermediate reports, tool activity and repeated paragraphs inside an item
retain their positions in the conversation.

Settlement and Stop serialize on the mission database. The generation, job ID,
and current status fence settlement; Stop advances the generation and revokes
the armed continuation. Before POSTing either the first job or a continuation,
Core records its job ID under that generation. A recovered continuation claim
without a job intent can proceed; with an intent, Core probes that same job ID.
Core cannot attach that job to the mission after Stop, and requests cancellation
if the node accepted it. A committed Stop is not proof of remote process exit.
On restart, Core marks unresolved Goal submissions uncertain before admitting
new work. Background probes leave live submissions alone and can retry an
uncertain job even if the first probe fails.

The sections below record the original baseline, pure policy and broader design
requirements; they describe more than the X7 adapter implements.

## Verified baseline

At `01548485023907d7c127261b8af75235bdfd663f`, remote command preparation
strips `/plan` but forwards `/goal`. Remote Codex uses `codex exec`, not a native
goal app-server driver. The payload's `native_goal=false` alone does not establish
the cause. Generic terminal settlement can mark nonempty successful output
complete without evidence that the objective was achieved.

Historical `core/opencode-goal-loop` (`e134e740`) provides Rust policy precedent:
explicit completion, Stop fencing, existing-wakeup precedence, no-progress and
continuation limits. Its deleted implementation is not available in the current
Lean remote path. Native lifecycle documentation is not implementation evidence.

## Pure policy boundary

`OrbCore.RemoteGoal.decide : GoalState → TurnEvidence → SettlementContext → Decision`
has no IO, persistence, submit loop or scheduler. `requestContinuation` is only a
proposal; it does not mean delivery was accepted or performed.

The owner fence contains mission ID, goal revision, run generation and job ID.
Stale observations do nothing. Settled observations cannot advance counters twice.
A committed Stop fences later observations, including an already proposed next
turn. An explicit admission transition is needed to resume a parked goal.

Unknown outcomes park for reconciliation; they never create a new job. Failed
or empty output cannot complete. Native blocked, paused, usage-limited and
budget-limited evidence is authoritative after the owning turn/tools drain.
Native active status never triggers an emulated turn or Core emulation budget.
Completion evidence must come from the owning final assistant response; callers
must not set `completionConfirmed` from tool output or a substring in quoted text.
The evidence validator is an integration requirement, not implemented here.

Queued steering takes precedence over an automatic turn. Existing wakeups or
continuations prevent competing requests. Budget exhaustion and repeated lack of
progress park with explicit reasons. Objective, session and counters must survive
ordinary resume and restart; the policy does not implement their persistence.

Grammar integration should reuse `Cyber.parseGoalPrefix?` only after compatibility
tests establish whitespace, escaping and objective-preservation semantics across
clients and command preparation. Reject empty objectives; never truncate. Do not
introduce another command parser to bypass those tests.

## Reserved integration design

No durable launch/ack hook contract has been delivered yet. Proposed signatures,
subject to schema/transaction review and explicit shared-file approval:

The wakeup patch covers snapshot-claim and original-generation retry fencing.
Its first handoff does **not** provide durable pre-POST launch identity or lost-ACK
reconciliation. Active goal dispatch has a separate dependency: minimal launch
identity/acceptance-reconciliation design and ownership approval, implementation,
and executable evidence. Neither wakeup handoff nor passing pure tests satisfies
that dependency. No placeholder loop may be wired while it is absent.
Core-emulated jobs retain `native_goal=false`; that flag is not native support.

The prospective launch design carries an immutable durable occurrence identity,
expected owner/run generation and exact job/node/payload binding before POST.
Observations distinguish `NotSubmitted(reason)`, `Accepted(binding)` and
`Uncertain(binding)`. Reconciliation must preserve the same binding; uncertainty
cannot select a fresh job, payload, node or owner generation. The pure
`DispatchBinding`/`sameDispatch` types only express that equality requirement.
They are not an implemented transport API or an exactly-once proof.

Persist-before-POST alone is insufficient: approval also requires receiver
duplicate-job-ID semantics (same binding replays the same acceptance; conflicting
binding is rejected), transaction/crash-window tests, monotonic accepted/terminal
receipts, and a Stop fence that prevents adoption by a newer generation. The
current wakeup patch supplies none of this launch protocol.

```lean
settleRemoteGoal : CoreStore → TurnFence → TurnEvidence → UInt64 →
  IO (Except GoalError SettlementReceipt)
stopRemoteGoal : CoreStore → String → UInt64 → String → UInt64 →
  IO (Except GoalError StopReceipt)
```

Settlement requires an atomic compare-and-set on the owning revision, a unique
settlement receipt and an approved durable continuation intent. Stop must fence
that intent before remote cancellation; cancellation acceptance is not proof of
process termination. Crash recovery must reconcile the existing dispatch identity,
not blindly replay submission. Exact schema and transaction ownership remain open.

After the wakeup patch handoff, rebase and obtain approval before wiring prompt
preparation, evidence collection and terminal settlement in `RemoteDispatch`.
`Control`, `Store`, `SelfTest`, submission/receipt recovery, scheduler and
continuation modules are not part of this pure-policy change.

### Proposed persistence contract (not implemented)

Use additive tables in the existing missions database, under its existing
transaction owner, rather than a second database or writer:

- `mission_goals`: mission primary key; goal revision, exact objective, driver
  kind, phase/reason, continuation/no-progress counters, optional continuation
  limit, owning run generation/job ID, and latest settlement identity. Preserve
  native binding through its existing authority; do not invent or reset it here.
- `mission_goal_settlements`: unique `(mission_id, goal_revision,
  run_generation, job_id)`; evidence fingerprint, decision, resulting revision,
  and optional continuation request ID. A conflicting replay must return a
  conflict, not overwrite accepted evidence.
- Continuation intents belong in the existing approved durable mechanism. A
  goal-specific table must not become a parallel launch queue. Required identity
  fields on that mechanism are a stable request ID, payload revision/fingerprint,
  goal revision and originating settlement identity. Whether existing fields
  suffice must be decided by the continuation owner after its patch lands.

Proposed shared-owner interfaces, with types to be reconciled at handoff:

```lean
claimGoalContinuation : CoreStore → ContinuationIdentity → OwnerFence → UInt64 →
  IO (Except ClaimError GoalClaimReceipt)
dispatchClaimedGoal : GoalClaimReceipt →
  IO (Except DispatchError DispatchObservation)
recordGoalDispatch : CoreStore → GoalClaimReceipt → DispatchObservation → UInt64 →
  IO (Except SettlementError DispatchReceipt)
settleRemoteGoal : CoreStore → TurnFence → TurnEvidence → UInt64 →
  IO (Except GoalError SettlementReceipt)
```

`ContinuationIdentity` includes row ID **and** request ID/payload revision. A
claim of the same row after replacement must not authorize the old payload.
The claim transaction checks identity, due phase, mission/run/goal fences and
Stop state, then returns the payload read inside that transaction. Callers must
not dispatch a payload retained from an earlier scheduler scan. The receipt
binds the claimed payload and an existing durable dispatch identity.

Dispatch is outside the SQL transaction. The shared dispatch owner must already
support a durable identity before the remote effect, accepted/unknown/refused
observations and lookup of that same identity after loss. This proposal does not
authorize changing submission or inventing such support. If the owner cannot
provide it, functional integration stays blocked. Unknown acceptance parks for
reconciliation; resetting to scheduled and submitting a fresh job is forbidden.

Recording dispatch checks the exact claim identity and cannot acknowledge a
replacement request. Acknowledgment means durable acceptance/delivery evidence,
not just that a scheduler function returned. A phase-2 restart must reconcile
the saved dispatch identity or expose a blocked reconciliation obligation; it
must not disappear or automatically create another execution.

Settlement runs in one transaction: re-read the goal owner/revision and Stop
fence; replay an existing settlement receipt if identical; evaluate the pure
policy; persist decision/counters; and, only for a continuation decision, insert
one stable request in the approved continuation mechanism. Commit before
publishing a state event. Rollback leaves neither advanced counters nor a
stranded intent. An explicit wakeup/steering request wins over automatic work.

Stop is a transaction that advances the goal revision, parks it, and fences its
pending automatic intents. Remote cancellation follows separately. If dispatch
was already accepted, expose cancellation pending until terminal evidence; do
not claim that transaction rollback can undo a remote effect. Explicit resume
retains counters/objective and requires reconciliation of unknown prior work.

Required integration reproductions: old-payload scan → same-row replacement →
claim; replacement after claim → acknowledgment; crash before/after intent commit;
lost acceptance response; phase-2 restart; Stop racing claim/dispatch/settlement;
duplicate settlement; and conflicting evidence for the same terminal identity.
The wakeup writer's replacement-race/phase-2 candidates are reported hypotheses,
not compiled proof or established incident causes in this document.

## Capability and parity

The first proposed emulated adapter is remote OpenCode, contingent on working
hooks and integration evidence. No capability is enabled by this policy module.
Preserve actually supported local, native and hosted behavior. Unsupported remote
native-bound missions require an explicit capability/continuity error; never reset
identity or silently convert them to emulation. Native Codex app-server restoration
is separate architectural scope and is not implemented here.

Clients must distinguish persistent goal state from process state and retain the
objective when parked. Structured status-only events must survive refresh and
streaming. Mobile background-sync currently drops goal events without summary or
content; that integration gap is still open. No global capability downgrade is
proposed as a substitute for the requested functional loop.

## Evidence and outstanding checks

`RemoteGoalTests.run` exercises pure terminal event orders: duplicate/stale
ownership, Stop before/after intent, native stop before drain, replay, unknown and
empty outcomes, budget, steering/wakeup precedence and no-progress limits.
These tests do not establish exactly-once execution. Final integration requires
temporary SQLite and a fake remote endpoint covering lost submit responses,
restart around commit/acceptance, queued steering, cancellation uncertainty and
cross-client projection fixtures. Production hook registration remains blocked.


The desktop transcript omits the standalone terminal marker on a final answer
after Core confirms `remote_goal_complete`. A completed mission record also
supplies that confirmation when the completion event lies outside a fetched
page. The same rule applies to a cached Done summary that reproduces the
answer with whitespace flattened. The raw events retain their original text.
A quoted marker, fenced example or ordinary assistant response remains visible.
