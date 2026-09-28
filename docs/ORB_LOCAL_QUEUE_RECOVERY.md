# Local queue recovery: mission 77fe4a01-160c-4dfa-b155-3adc0f54e754

## Evidence (2026-09-28, UTC)

- The Claude session binding is `00000000-0000-0000-18d9-66c8bb1bc718`.
- Claude's local JSONL records the repository-review prompt at 06:44:16.724.
- Its final answer was written at 06:52:12.838 (10,708 characters), after the
  individual audits completed. The task was executed; blindly resending repeats it.
- Core's history, read during diagnosis, contains the review prompt once and no
  subsequent assistant answer. Its user event has sequence 17 and timestamp
  10:14:32.436, preceding older-timestamp status events by sequence. Thus this
  history alone does not establish when native execution began.
- Core recorded `interrupted`, reason `client_runner`, at 10:14:32.620.
- The answer was recovered verbatim to
  `artifacts/queue-recovery/77fe4a01-final-response.md`. No cloud execution receipt
  was bypassed, transcript overwritten, or repository-review mission relaunched.

The observed failure is loss of final-result delivery/visibility between local
execution and Core. Available evidence does not establish the exact process exit
or webview-reload event responsible. The running webview's outbox was not directly
inspected; its precise persisted state must not be inferred from the screenshot.

## Immediate changes

- Send-now checks the native run first: stop an active run, reconcile a finished
  or explicitly missing run. An IPC failure does not establish that a run stopped.
- An unconfirmed persisted dispatch older than 30 seconds becomes reviewable,
  never automatically replayed. Explicit retry still checks native ownership.
- An errored unsynchronised prompt is no longer projected as an additional
  optimistic transcript bubble; canonical history remains unchanged.
- Long queued messages use a two-line expandable preview; error rows say
  "Needs attention". The queue dock has an opaque backing below its fade.

These improve controls and presentation but do not implement durable native
completion delivery or restore this result to Core automatically.

## Durable fix, in implementation order

1. **Native transactional outbox.** Move follow-up dispatch and completion syncing
   from webview timers/IndexedDB into a native SQLite journal. UI only submits an
   intent and observes snapshots. Persist message ID, attempt ID, native generation,
   receipt, harness session, output cursor and completion before acknowledging.
2. **One owner per attempt.** Use the existing machine-wide lock plus explicit
   ownership/generation. Do not close receipts from a passive UI reconciler while
   the native owner is flushing results. No lease expiry based only on UI absence.
3. **Idempotent begin and finalise.** Core begin accepts the durable message/attempt
   key and returns the same receipt on retry. Finalise atomically stores the result
   and terminal state. A repeat after a lost acknowledgement returns the stored
   completion, rather than rejecting it and suggesting another execution.
4. **Separate delivery and execution states.** queued → claiming → running →
   completed_locally → syncing → delivered. Unknown launch, failed execution and
   failed synchronisation are distinct. Retrying delivery cannot rerun the prompt.
5. **Safe legacy recovery.** Match an existing native receipt and harness session
   to the saved prompt and completed output. Offer "Restore response" when proven;
   otherwise show "Check previous run". Never deduplicate by text alone, mutate a
   different generation, or interpret a missing UI observer as a stopped process.
6. **One UI projection.** Merge journal and Core events by message/attempt ID;
   a message moves from the queue to the transcript rather than appearing in both.
   Show recovery and synchronisation status beside that same item.

Acceptance tests must cover killing/reloading the webview after each transition,
killing native Orb, two windows competing, Core offline during completion, lost
begin/finalise responses, repeated polling/events, machine transfer and a stale
receipt. For each: one native launch, one user message, one complete answer,
ordered follow-ups, and no silent loss. Test with a bounded fake runner first;
then a harmless real mission with controlled disconnects. Do not restart unrelated
active user missions to exercise crash recovery.
