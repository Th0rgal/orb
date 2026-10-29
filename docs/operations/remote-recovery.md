# Remote mission recovery

Remote execution has two independent facts: the mission's requested state and
the node job's observed state. Losing contact with a node is not evidence that
its process stopped. Keep the job handle and writer lease until a terminal node
receipt; do not dispatch a replacement writer to work around an outage.

## Failure handling

- OpenCode's structured API errors retain their status, retryability and
  `Retry-After` hint for classification. Retryable gateway/network failures use
  the durable remote wait ledger, including after a Core restart. The first
  retry waits at least 60 seconds; later retries back off to 10 minutes plus
  deterministic jitter. A provider's longer Retry-After is honoured. Delays beyond
  seven days require manual recovery instead of an early retry or an unbounded wait.
- Automatic continuation requires a persisted native session. It uses the
  existing node/workspace/session, checks the previous job's termination, and
  is capped at 12 attempts without sustained progress. Duplicate observations
  of the same failed job do not allocate another attempt.
- OpenCode usage limits use the reported reset, without borrowing a different
  provider's account cooldown. Native subscription harnesses retain their
  account-aware reset calculation.
- Explicit pauses/cancellations and expired structured scheduling deadlines
  prevent automatic continuation; replay-start retries must also fit before the
  deadline. Natural-language deadlines cannot be inferred
  safely; set `scheduling.deadline` when creating scheduled work.
- Authentication, provider policy and setup failures require intervention.
  They are not made retryable merely because they contain a transport error.
  Scoped MCP requests rejected with 401 renew once through the existing scoped
  renewal endpoint. They never escalate credentials or retry an ambiguously
  accepted mutation.

After five unsuccessful node observations, Core reports **Reconnecting** and
backs polling off to 60 seconds. It retains the run lease and job handle. Once
the node returns, it observes the original job instead of cancelling it. A user
stop still requests cancellation while offline and awaits terminal proof.

The startup watchdog measures time in `running`, not time queued. Native
protocol activity ends the cold-start watchdog; slow thinking is not a failed
startup. An eventless process is stopped after five minutes. The node's normal
job time limit still applies.

## Cancellation evidence

New nodes persist `cancellation` in their job receipt before delivering the stop
signal: actor, reason and request time. The first cause wins across repeated
requests and restarts. Startup-watchdog provenance takes precedence over the
CLI's subsequent generic `interrupted`. Old nodes remain wire-compatible but
cannot reconstruct historical cancellation actors. Upgrade node binaries to
obtain this evidence for future jobs.

## Operator workflow

- **Reconnecting:** wait or explicitly stop. Do not start another writer.
- **Recovery scheduled:** inspect the retry time/attempt count; Resume now and
  Cancel recovery are available in Orb.
- **Reconnect required:** repair the provider login or the node's scoped Core
  credential. A Core scoped-session 401 is not evidence of a provider quota.
- **Blocked by provider:** review the request. Do not blindly repeat it or try to
  circumvent provider policy.
- **Setup required:** inspect CLI version/path, model availability, workdir and
  permissions before resuming.

Resume instructions are a fixed envelope, not a new mission objective. They
ask the agent to inspect existing files/background jobs and avoid duplicate
work. Generated envelopes never overwrite the user-selected objective.

## Validation

Regression coverage lives in `remote_failure`, `usage_limit_wait`,
`remote_grok`, `dispatch_admission_tests`, `node::job_store`, and
`control_mcp::client`. It covers the OpenCode 502/Retry-After incident, durable
retry fencing, deliberate stops, node reconnects without cancellation,
first-cause cancellation persistence, and scoped renewal without duplicate tool
execution. Orb's launch tests and recovery browser fixture cover presentation,
keyboard actions, themes and narrow viewports.

These changes do not automatically revive old failed missions or infer the
cause of old `interrupted` errors. Confirm current user intent before manually
resuming historical work.

## Recovery ownership and partial replies

CLI exit zero does not prove that the work or background tasks completed.
A background handoff closes that execution and sets `interrupted` with
`background_task_handoff`. The persisted remote wait (failed job ID, retry
count, due time) owns recovery. Clients show **Recovery scheduled** from that
record, never from assistant prose.

Required event order (incident `8c1be306`):

1. The old remote job ends with background tasks unfinished.
2. Core persists its wait and closes the old execution lease.
3. An orphan sweep, even with an earlier Active snapshot, re-reads the mission
   under dispatch admission and leaves the waiting mission untouched.
4. Replay revalidates the exact wait and failed job under the same admission
   lock as Stop/manual Resume. A stale timer cannot dispatch or overwrite a
   newer run/recovery. Only one writer is admitted.
5. Stop fences continuation; manual Resume supersedes the old recovery.
   Neither may be undone by a stale timer's failure cleanup.

Local inactivity interruption is not an explicit Stop. It retains queued work
and durable continuations, does not cancel child missions, and refines a native
`Cancelled` result to `Stalled` before terminal evidence is published. Explicit
Stop overrides this pending interruption and still revokes follow-ups. Shutdown
and concrete native errors retain their own causes. A stall alone does not
establish that replaying side effects is safe: absent an existing continuation,
show Resume rather than promising an automatic retry.

Conditional supervision reports an absent runner separately from renewed
activity. Stale cleanup may close an idle mission with no runner; only actual
recent runner activity vetoes that cleanup.

Partial assistant prose is preserved once, separately from failure evidence.
It must not hide a later lifecycle interruption. Legacy generic `Cancelled`
is not proof of a user Stop. Tests replay handoff/orphan ordering, stale timers,
Stop versus inactivity, and live/reloaded transcript sequences.
