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

A definite launch failure can re-arm the same occurrence with backoff. The
local launcher carries its claim forward in the same transaction as its own
generation change. Stop or an unrelated turn cannot confer retry authority.
Cancellation and claim retain their existing transactional ordering;
cancellation losing to claim returns a conflict.

A remote wake-up binds the claimed occurrence to the original remote job ID
in the same transaction that records the submit intent, before any POST. A
lost reply keeps that claim bound. Reconciliation probes the original node and
job; an accepted job is attached and the wake-up settled atomically, while a
definite rejection or an authoritative not-found allows backoff. An unavailable
probe cannot authorize another submission. The job that *triggers* a wake-up
is independent of the job launched to deliver it.

Legacy automations are migrated only when Core recognizes their trigger and
stop policy. The continuation and source retirement commit together. An
unsupported trigger, conflicting continuation or failed write leaves the
legacy source active.

## Regression evidence and limits

`WakeupRestartTests` uses deterministic callbacks, without timing sleeps:

- A launches while B's same-job watcher is replaced after the due-row scan.
  Only B's replacement input may be delivered to the callback, once.
- Stop occurs inside a failing launch callback. Later ticks must not launch it
  again or leave a rearmed occurrence.
- A callback throws after phase 2 is durably claimed, either before effects or
  after recording acceptance. These characterize the current unresolved
  recovery boundary; neither permits blind replay.

The production local launcher is also exercised with a persisted session and a
missing CLI: the launch advances the generation, settles the mission as
interrupted, and schedules exactly one retry after backoff. A loopback node
fixture exercises the production remote submitter and reconciler: dropping the
POST reply leaves a durable bound claim, and GET probes against that same job
distinguish unavailable, accepted and missing receipts. Migration fixtures
exercise both insertion and retirement failure in an isolated SQLite store.

The replacement callback additionally launches a local `printf` process and
asserts its successful exit and exact output. This is observed local process
input delivery, not remote node/provider acknowledgement. Focused compiled
Lean regressions passed (exit 0). Disabling the atomic snapshot comparison
produced the expected regression failure (exit 1); restoring it passed again.
The full Core self-test build hit the builder's 300-second SelfTest compilation
timeout; the focused executable reused compiled dependencies and C artifacts.

An unexpected local launcher exception without a receipt remains ambiguous;
there is no automatic replay of an unclassified local phase-2 claim.
