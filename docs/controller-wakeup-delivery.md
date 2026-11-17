# Controller wake-up delivery boundaries

Baseline: `01548485023907d7c127261b8af75235bdfd663f`.

## Contract

A successful schedule action acknowledges durable registration, not delivery.
The scheduler emits wake transcript text before launching; that text alone is
not proof that a harness received the input.

The scheduler's due-row scan is a snapshot. Replacement may reuse a row ID,
and an ordinary follow-up may carry the armed row into a newer generation.
Before claiming, compare both request identity and generation inside the
claim transaction. Snapshot-driven deadline/supersession writes must use the
same fence. A stale scan must neither consume a replacement with the old
prompt nor supersede a correctly carried wake-up.

A failed one-shot launch may retry only under its original request identity
and generation. Stop's generation increment must never become authority to
retry the stopped occurrence. Cancellation and claim retain their existing
transactional ordering; cancellation losing to claim returns a conflict.

## Regression evidence and limits

`WakeupRestartTests` uses deterministic callbacks, without timing sleeps:

- A launches while B's same-job watcher is replaced after the due-row scan.
  Only B's replacement input may be delivered to the callback, once.
- Stop occurs inside a failing launch callback. Later ticks must not launch it
  again or leave a rearmed occurrence.
- A callback throws after phase 2 is durably claimed, either before effects or
  after recording acceptance. These characterize the current unresolved
  recovery boundary; neither permits blind replay.

The callback tests do not prove remote admission, native harness delivery, or a
deployed fix. The three operator-reported incidents have no supplied IDs or
timestamps; their causes remain unestablished. Preserved accepted schedules
with matching wake prompts are not classified as failed incidents.

The replacement callback additionally launches a local `printf` process and
asserts its successful exit and exact output. This is observed local process
input delivery, not remote node/provider acknowledgement. Focused compiled
Lean regressions passed (exit 0). Disabling the atomic snapshot comparison
produced the expected regression failure (exit 1); restoring it passed again.
The full Core self-test build hit the builder's 300-second SelfTest compilation
timeout; the focused executable reused compiled dependencies and C artifacts.

## Outstanding recovery boundary

Phase-2 claims stranded by exceptions need durable stage/dispatch identity,
not an unconditional reset to phase 1. Remote submission currently allocates
a job ID, sends POST, then persists on acknowledgement. Acceptance followed by
lost acknowledgement is uncertain, not proof of failure. Safe recovery needs
an occurrence-to-job/node binding persisted before submission and results
distinguishing definitely-not-submitted, accepted, and uncertain. Reconcile
uncertainty using the same identity; do not generate another job or node.
Terminal evidence must settle the bound occurrence, and a stale failure must
not undo acceptance. Those submit/poller changes require separate coordinated
ownership and are outside this patch.
