# Agent schedules and harness event ingestion

How Core turns an agent's own scheduling tool into a durable mission schedule,
and what the harness stream parsers must guarantee while doing it.

## Incident (mission 2e8228cf, 2026-10-24)

Thomas asked an Antigravity mission to "update me every 30min". `agy` called
its native `schedule` tool with `CronExpression: "*/30 * * * *"`. From then on
Orb showed nothing for 35 minutes while `agy` kept working (its own log shows
model calls and tool runs every minute).

Root cause, reproduced with agy 1.4.7 and in the node job logs:

- A recurring `schedule` step stays `ACTIVE` for the lifetime of the cron (agy
  treats it as a background task: `root agent idle; waiting up to 30m0s for 1
  background task(s)`).
- agy's `--output-format stream-json` emitter is ordered. It holds every later
  `step_update` behind the `ACTIVE` step and writes them only when the process
  exits. Job `24068a12` flushed held steps 766–1217 at once when it hit a quota
  error 69 minutes later. Job `453352f9` was stopped with SIGTERM and lost
  steps 1755..1945 entirely; only `result: interrupted` arrived.
- The CLI's persisted conversation still contains those steps, so resuming
  the conversation keeps the work.

Core did not drop events. The CLI never wrote them to stdout.

A one-shot `schedule` (`DurationSeconds`) completes at once and is not affected.
It keeps the existing one-shot wake-up mapping.

## Event-ingestion invariant

For every harness parser (`shared/antigravity.rs` `Stream`, remote
`GrokStream`, local runners):

1. While the harness process is alive, no event after a `tool_result` is
   dropped. A parser never stops reading because a tool call or tool result
   looks final.
2. A turn ends only on an explicit terminal event (`result`, `end`) or on
   process exit. A tool call never ends a turn.
3. If the CLI itself withholds events (the recurring `schedule` case), the
   host must end the native process deliberately and resume the conversation.
   Leaving it running would keep the mission silent.

Point 3 is implemented as the *schedule handoff* below. This invariant is about
I/O, not a pure step function, so it is tested with stream fixtures
(`tests/fixtures/antigravity_cron_schedule.jsonl`) and not proved in Lean.

## Schedule handoff

When the stream reports an `ACTIVE` `schedule` step with a `CronExpression`
(`Stream::blocking_cron`) and the conversation identity is durable:

1. Core registers a mission automation: trigger `cron` (UTC), `stop_policy:
   never`, `__wakeup_source = antigravity-schedule`, `__wakeup_request_id =
   antigravity-cron:<sha256(cron, prompt)[..16]>`. At each tick the scheduler
   sends the prompt as a queued message to the mission.
2. Core stops the CLI. On a node, this cancels the job with actor
   `native_schedule`. That provenance survives Core restarts, so the verdict
   still treats the turn as handed off.
3. The verdict counts the `interrupted` result as a clean end of turn
   (`Stream::cron_handoff`). It then registers a one-shot resume wake-up
   (`antigravity-cron-resume:<job>`) that tells the agent Orb now owns the
   schedule and asks it not to call `schedule` again.

The schedule is a normal wake-up continuation. The mission's wake-up dialog
shows it as `Scheduled: every 30 min — next at HH:MM` and has a Cancel
schedule button. Cancelling it or stopping the mission deactivates it.

Mobile clients do not list wake-up continuations yet. This feature is
desktop-only for now, like the existing one-shot wake-ups.

## Verified step: `orb_schedule_step`

`lean/Orb/Kernel.lean` `scheduleAction` decides each registration and tick.
`src/api/control/automation_http.rs` calls it at registration, and
`src/api/control/automation_scheduler.rs` calls it on each tick.

| Input | Meaning |
| --- | --- |
| `op` | `0` = register, `1` = tick |
| `known` | a row with the same key exists (active or cancelled) |
| `cancelled` | the row was cancelled or its mission stopped |
| `ownerTerminal` | the owning mission no longer exists |
| `authorized` | the caller owns the mission |
| `busy` | the mission is mid-turn |
| `lastFired`, `nextDue`, `now` | last fire (or registration), the first cron slot after it, the clock |

Actions: `0` drop, `1` register, `2` dedupe, `3` fire, `4` wait. A fire moves
the reference to `now` (`scheduleNextRef`), never to the missed slot.

Proofs in `lean/Orb/Spec.lean` use the Layer I meta-specs. No `sorry` and no
custom axioms are allowed: `crates/orb-spec/build.rs` compiles with
`-DwarningAsError=true` and rejects `axiom` declarations.

- `IdempotentOutboxSpec` (`scheduleOutbox`, corollary 37): a known key is never
  registered again. It dedupes for the owner and is dropped otherwise, so the
  agent re-scheduling after each restart yields one schedule.
- `ClockDiscipline` (`scheduleClock`, corollaries 38–39): the fire bit is set
  only by the due-slot guard. A fire strictly advances the reference, and the
  advanced reference consumes the slot, so the same slot never fires twice at
  any later time. After downtime there is at most one fire for all missed
  slots. Without a fire, the reference does not move.
- `StickyFence` (`scheduleFence`, corollary 40): a cancelled schedule or a
  terminal owner stays fenced on every tick and never fires again.
- `ScopedAuthority` (`scheduleAuthority`, corollary 41): only an authorized
  caller can register a schedule or make one fire. Every unauthorized
  operation is dropped.

## Dedupe and supersession

- Same cron and same prompt gives the same automation id. Re-registering
  returns the existing row, including a cancelled one. A user's cancel is
  sticky for that key.
- Same cron with a reworded prompt replaces the older schedule
  (`wakeup_supersession_key`: `antigravity-cron:<expression>`).
- A tick that finds the mission busy waits. The slot fires once, at the first
  idle tick.
