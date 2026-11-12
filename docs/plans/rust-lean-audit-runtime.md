# Rust → Lean runtime audit

> **Publication freshness, through `05714bb68`:** all R/L citations below retain the pinned `5383bf27b` comparison. Recovery subsequently registers periodic Boat inventory reconciliation and implements archived/stable-ID resume (`Control.lean:6551` onward and `RemoteFleetAndRelay.lean:838–970` at publication). Therefore pinned inventory rows saying no provider-observation timer are not current-state assertions. This is progress on the already-owned fleet work, not a new RUN finding or proof of a complete TTL/orphan reaper. The 12 numbered RUN comparisons remain source-derived; see the parent report's bounded freshness notes.

## Scope, revisions, and evidence standard

Read-only source audit, 2026-11-12. Rust baseline `4199fc06e^` resolves to
`b22ed3181df64cf9681e887381ede7ed15fe96aa`; Lean/current HEAD is
`5383bf27b8f8e664b654339cf88e14c90dba665c`. Read `AGENTS.md`,
`docs/plans/core-recovery-2026-11.md`, and
`docs/plans/managed-providers-leanci-colab.md`. No builds, tests, services, or
commits were run. Suggested checks below are future acceptance criteria, not
observed test results. Independent source review confirmed 11 findings and
narrowed RUN-10; the review verdicts and qualifications are recorded below.

References to Rust paths/lines mean the baseline, not deleted files at HEAD.
In tables, **C/** expands to `lean/OrbCore/OrbCore/`, **B/** to
`lean/OrbBin/OrbBin/`, and **N/** to `lean/OrbNode/OrbNode/`.
`C/Control.lean:6335–6508` is the actual server startup/accept loop; a missing-duty
citation to that range means no registration there or in the traced startup
callees, not that a similarly named definition cannot exist anywhere.

Classification: **E** = equivalent for the narrowly stated duty; **D** = wired
but behavior differs; **S** = endpoint/adapter exists but is a stub for the
required behavior; **M** = no executing counterpart found; **U** = unresolved
or insufficiently traced. E is not a whole-feature PASS. A pure definition,
import, extern declaration, self-test, or proof is not a running background duty.
Intervals below are source defaults, not claims about deployed environment values.

## Actual entrypoint and ownership

Rust `src/main.rs:9–92` creates a multithread Tokio runtime (16 MiB worker stacks),
initializes configuration/encryption, reconciles Hermes drain policy, then calls
`api::serve`. `src/lib.rs:36–121` declares modules; `src/api/mod.rs:125` re-exports
`routes::serve`. The startup registrations are in `src/api/routes.rs`, not in
`api/mod.rs` itself.

Lean `C/CliMain.lean:82–98` calls `loadConfigFromEnv` then `runCoreServer`.
`C/Control.lean:6335–6446` opens/hydrates stores, bootstraps Ask, loads managed
fleet/routing/auth state, and constructs hubs and a **new empty warm harness
manager**. Important positive wiring, which must not be called missing:

- `C/Store.lean:1159–1167` runs lease recovery and startup/health reconciliation
  (`C/Store.lean:683–837`). This is real, but narrower than Rust recovery.
- `C/Control.lean:6447–6448` starts hosted/cloud supervision.
- `C/Control.lean:6458–6470` starts remote-job reattachment followed by a real
  continuation scheduler, sleeping 2 s between completed passes.
- `C/Control.lean:6471–6504` implements systemd READY/WATCHDOG/STOPPING notifications
  in the accept loop. Watchdog interval is `max(1, WATCHDOG_USEC/2_000_000)` seconds,
  or 15 s when unset, provided NOTIFY_SOCKET exists. This is not the old Rust
  runtime-probing watchdog, but it is not absent.
- `C/Control.lean:5880–6290` is a real live multiplexed sync WebSocket; other
  WebSocket paths do not use that implementation.
- Local execution is `C/Control.lean:1551–1587` →
  `B/ClaudeControl.lean:1591–1774`, not `RunCoordinator`.

## Numbered new findings

These are new relative to the two running plans, not assertions that nobody has
noticed them elsewhere. Each proposed fix is one bounded PR; no fix was applied.

### RUN-01 — Local process restart has no matching drain/recovery lifecycle (D/M, high)

**Effect.** A Core stop can leave a local mission apparently active without a
new process owning its harness. Reopening the database is not a local harness
reattachment or supervised resume. Conversely, a detached process may outlive
Core; its fate depends on the service's kill policy, which this audit did not
inspect on the host.

**Rust evidence.** `src/api/routes.rs:1765–1897` installs SIGTERM/SIGINT graceful
shutdown, sends shutdown commands to control sessions, and drains before exit;
`src/api/control/actor.rs:164–174` schedules recovery of interrupted/server-shutdown
missions. `src/api/reconcile.rs:80–124,968–974` supplies a delayed boot backstop
(default enabled, 45 s delay, 180 s active grace, 6 h interrupted horizon, cap 20).

**Lean evidence.** `C/Control.lean:6410,6458–6470` constructs an empty in-memory
warm manager and reattaches remote jobs only. `C/Store.lean:731–837` really calls
`Orb.Kernel.reconcileStep`, but its mission handling marks orphaned rows and
settles old waiting-background rows; it does not execute the interrupt/resume
workflow for local active harnesses. `C/Control.lean:6471–6508` emits watchdog and
STOPPING notifications but installs no Core SIGTERM/SIGINT drain handler. The
normal unbounded listener does not reach its cleanup merely because a signal
arrived. Do not confuse this with Node's real signal handling at
`N/Server.lean:1899–1954`.

**One PR fix.** Add a local-run lifecycle owner with signal-driven bounded drain,
durable interruption receipts, and a boot pass that either safely reattaches a
verified live identity or settles/resumes the interrupted turn. Acceptance:
restart an active local turn and an idle warm process; no ghost active row,
no duplicate writer, and an explicit recovery receipt.

### RUN-02 — No executing same-boot mission supervision/background-shell watcher (M, high)

**Effect.** A live-but-silent local CLI or a failed detached reader can remain
active indefinitely. A shell task launched in the background does not acquire
the Rust watcher that wakes the mission with its eventual result. A healthy
HTTP accept loop can continue petting systemd while mission execution is stuck.

**Rust evidence.** `src/api/control/actor.rs:177–239` registers stale cleanup,
stuck watchdog, waiting-background boot settlement, and background autoresume.
`src/api/supervision.rs:889–1107` polls every 60 s, examines running activity,
OOM changes and idle workers. The actual inactivity default is **900 s**, not
the older ten-minute comment (`src/api/control/control_queue.rs:430–442`,
`MISSION_STUCK_SECONDS`, minimum accepted override 30 s).
`src/api/supervision.rs:1492–1508` checks stale missions every 300 s when configured;
`src/api/supervision/bg_autoresume.rs:23–47,265–284` polls every 10 s, with 15 s
stable idle, 20 s start grace/probe timeout and 30 min overall timeout.

**Lean evidence.** `B/ClaudeControl.lean:1272–1363,1704–1774` reads stdout until
EOF; there is no semantic-progress timer in those readers.
`C/Control.lean:6447–6470` starts cloud and continuation/remote duties, not these
watchers. `C/Store.lean:806–817` is old-boot waiting-background settlement, not a
same-boot completion watcher. `C/HostObservers.lean:298–304` consists of seeded
kernel observations, not a monitoring loop.

**One PR fix.** Restore an executing local supervisor with independent progress
and process-liveness observations and bounded background-task completion wakeup.
Keep HTTP watchdog health distinct. Acceptance: quiet live CLI, dead reader,
background completion, and explicitly paused mission have distinct outcomes.

### RUN-03 — Core lost event-driven scope teardown and its periodic backstop (M, high)

**Effect.** Stopping/settling a mission no longer guarantees cleanup of old Core
execution scopes, including scopes left by the retired server. This is separate
from the provider VM reaper and from Node's job-resource teardown.

**Rust evidence.** `src/api/control/actor.rs:124–130` registers the status listener;
`src/api/routes.rs:790–797` registers periodic scope and boot reconciliation.
`src/api/scope_reaper.rs:45–78,332–384`: enabled by default, 30 s event grace,
15 min sweep, 12 h zombie age; configurable with `SCOPE_REAPER_*`,
`SCOPE_TEARDOWN_GRACE_SECS`, `SCOPE_ZOMBIE_MAX_AGE_HOURS`.

**Lean evidence.** No corresponding Core scope enumeration/listener is registered
in `C/Control.lean:6335–6508`. `B/ClaudeControl.lean:1011–1042` has an explicit
per-run process-group stop, not a sweep of leaked systemd scopes.
`N/Runner.lean:1863–1994` does have job teardown and must not be called absent.

**One PR fix.** Add a Core scope owner/listener plus a periodic reconciliation
backstop, preserving active/background-work exemptions and verified ownership.
Acceptance: stale old-boot scope removed; active Node and local work untouched.

### RUN-04 — Workspace/scratch retention and disk-pressure duties are not scheduled (M, medium)

**Effect.** Configured cleanup and pressure alerts stop running; disk reservations,
authorized purge retries, orphan directories and configured container `/tmp`
retention lose their old periodic driver. This can increase disk pressure, but
Rust deletion was opt-in: it is incorrect to claim all installations used to
automatically delete terminal workspaces.

**Rust evidence.** `src/api/routes.rs:780–787` registers GC and disk watcher.
`src/api/mission_workspace_gc.rs:31–52,67–84,138–170` sweeps hourly by default,
retention 1 day (legacy stopped retention 7 days), enabled settings default false,
and deletion additionally requires `WORKSPACE_GC_EXECUTE`. Reservation sweeping
is a separate duty driven by the tick, not permission to delete workspaces;
the tick also drives authorized workspace purges and configured container tmp.
The pressure watcher is independently scheduled regardless of workspace deletion
opt-in. Missing these drivers is distinct from missing destructive retention.
`src/api/disk_watch.rs:22–35,122–169` checks every 5 min, with 3-point recovery
hysteresis and default repeat suppression 24 h.

**Lean evidence.** `C/Control.lean:6335–6508` has no equivalent startup duty;
`C/ResourcesAndSystem.lean:334` is request-time resources rendering, not GC or
alerts. Ask's startup sandbox GC (`C/Control.lean:6372`) is a different scope.

**One PR fix.** Restore a maintenance pass for workspace retention/reservations
with pressure observation and opt-in deletion semantics; preserve resumable and
active owners. Acceptance: dry-run remains non-destructive and explicit execute
mode only removes eligible confined paths.

### RUN-05 — SSE contracts were replaced with finite snapshots (S/D, high)

**Effect.** An EventSource gets one body and reaches EOF, rather than receiving
live mission changes. Reconnects can repeat a constant `id: 1`; reconnecting is
not durable replay. Project-context notifications have the same finite-body
problem. This is distinct from the recovery plan's MCP event pagination gap.

**Rust evidence.** `src/api/control/streaming.rs:735–1144` supplies initial status,
live named AgentEvents, mission/kind filters, per-mission `since_seq` replay
(limit 500), lag signaling, and 15 s keepalive (1 s shutdown checks).
`src/api/project_files.rs:969–994` keeps filesystem subscriptions alive and emits
`event: changed`, `data: {}` initially and on changes.

**Lean evidence.** `C/Control.lean:3898–3927` returns a `CoreHttpResponse` with
one `missions_snapshot` (limit 200) or `snapshot` (first event page, limit 100),
constant event ID 1, and a ByteArray body. The Rust `/api/control/stream?mission=…`
contract is not preserved by adding a separate `missions/:id/stream` endpoint.
`C/Control.lean:5488–5497` similarly returns one context SSE body.
`C/Control.lean:6312–6321` serializes these as ordinary completed HTTP responses.
The live `/api/control/sync` WebSocket is **not** missing and does not repair the
SSE fallback contract.

**One PR fix.** Add a real streaming HTTP response mode and bind mission/context
subscriptions to connection lifetime, with cursor replay, bounded lag handling,
auth rechecks and independent keepalive. Acceptance: mutate after opening the
stream, reconnect at a nonzero cursor, and observe exactly the expected events.

### RUN-06 — Non-sync WebSockets upgrade into a generic ACK loop (S, high)

**Effect.** Console, workspace shell, desktop and monitoring can complete a
WebSocket handshake without performing their advertised transport. Quiet
connections close after 2 s; busy ones are capped at 64 receive-loop steps.
This is a transport stub, not evidence of PTY/display/metrics parity.

**Rust evidence.** `src/api/routes.rs:875–890` wires separate console, shell,
desktop and monitoring handlers. `src/api/console.rs:132,486`,
`src/api/desktop_stream.rs:153–294`, `src/api/monitoring.rs:750–828` implement
actual endpoint-specific workers/data transfer.

**Lean evidence.** Upgrade routing at `C/Control.lean:1956–1962` and post-upgrade
handling at `C/Control.lean:6322–6330` select the specialized implementation only
for `/api/control/sync`. Other upgrades call
`C/Control.lean:5820–5857`: `ready` hello; ping/pong; close; text/binary →
`{"type":"ack"}`; 2,000 ms readable poll; 64 steps. No PTY, desktop frames or
metrics producer is passed to that function.

**One PR fix.** Replace the generic loop with endpoint-specific transport
owners (or explicitly reject unsupported upgrades until implemented). First PR
scope: console/workspace-shell PTY bridge with reconnect/cleanup. Track desktop
and monitoring adapters explicitly rather than treating the generic handshake
as completion. Acceptance: shell output and input round-trip after >2 s idle.

### RUN-07 — `/v1` SSE is buffered until upstream response completion (D, high)

**Effect.** Streaming model calls lose incremental delivery and keepalives;
clients can time out while Core accumulates a successful generation. The
pre-/post-first-byte kernel fence is not evidence of actual network commitment.
This is independent of per-model pricing and the already-owned TLS quiet-socket
check.

**Rust evidence.** `src/api/proxy.rs:3417–3425` constructs an async response stream;
`src/api/proxy_reliability.rs:290–327` sets 60 s ordinary / 180 s reasoning idle
baselines (adaptive ceiling 300 s), 15 s keepalive, and default two precommit stall
retries. These are stream behaviors, not simply a returned Content-Type.

**Lean evidence.** `C/Proxy.lean:751–788` appends plaintext response bytes into
`rawBuf` until EOF/limit/deadline, then parses the complete response. Limits are
10 min byte-idle, 1 h total, and 16 MiB. `C/Proxy.lean:1056–1076` selects this or
`httpsRequest`; `lean/OrbNetLeaf/OrbNetLeaf/TlsHttp.lean:489–509` also returns a
fully drained/framed response. `C/Control.lean:6312–6321` writes only after
request dispatch returns. `C/Proxy.lean:790–805` models commitment but supplies
no downstream incremental byte writer in this execution path.

**One PR fix.** Introduce a streaming proxy transport/response path that commits
on the actual first downstream write and runs byte-idle and semantic-progress
deadlines independently; preserve no-failover-after-commit. Acceptance: delayed
chunks arrive before upstream EOF; keepalive-only traffic cannot extend progress
forever. Do not describe the already-owned TLS fix as new here.

### RUN-08 — Legacy non-interval automations are destructively converted to time wakeups (D, high)

**Effect.** A cron, webhook, or agent-finished automation may fire as a one-shot
timer (often base timestamp + 300 s), then the source automation is deactivated.
Cron expression/timezone and event-trigger semantics are not preserved.

**Rust evidence.** `src/api/control/automation_scheduler.rs:157–165,313–406`
distinguishes interval, cron (with timezone-aware next occurrence), webhook,
agent-finished, Telegram and durable-job triggers; event triggers are not generic
time intervals. The persisted shape is confirmed at
`src/api/mission_store/sqlite.rs:442–483`: `trigger_type='cron'` stores
`expression`/`timezone`, `webhook` stores its config, and `agent_finished` has
no interval seconds. Independent review additionally verified the historical
schema/write shape at `src/api/mission_store/sqlite/migrations.rs:172–189`
and `src/api/mission_store/sqlite/automations.rs:41–65`. Thus the 300 s fallback
is not merely a hypothetical mismatch with an unverified old schema.

**Lean evidence.** `C/RemoteDispatch.lean:1262–1289` reads all active legacy rows,
without restricting trigger kind. At `:1331–1351`, missing seconds default to
300; only job triggers are separated; all others become `time`; only exact
`interval` can recur. At `:1365–1370`, it inserts the continuation and sets the
source `active=0`. This migration is wired every scheduler pass at `:1388`.
It is not an unused compatibility helper.

**One PR fix.** Gate migration to supported trigger/stop-policy shapes and leave
unsupported sources active with an explicit migration diagnostic; implement
cron/event semantics separately. Check insertion result before source retirement.
Acceptance: cron/webhook/agent-finished rows are never silently changed into timers.

### RUN-09 — A one-shot wakeup is consumed before successful launch (D, high)

**Effect.** A due one-shot continuation can be marked resumed even when its local
CLI is missing or remote dispatch fails; nothing re-arms it. Local launch also
sets mission active before binary resolution, so this can strand an active row
with no process.

**Rust evidence.** `src/api/control/continuations.rs:157–330` keeps delivery
acknowledgement/retry state and explicitly retains unacknowledged delivery for
retry after restart (bounded backoff). This is a narrower guarantee than claiming
Rust retries every provider failure.

**Lean evidence.** `C/QueueCont.lean:890–932` advances the continuation to phase 2
on `resume`. `C/RemoteDispatch.lean:1442–1498` performs that transition before
remote/local launch; failure only emits an error or returns false. Re-arm at
`:1500–1517` applies only to recurring `interval:` entries with `stopFirst=false`.
`C/Control.lean:1577–1596` persists active status before calling
`B/ClaudeControl.lean:1607–1618`, which can return missing-binary error before
there is a run/reader. The launch-error return does not settle that mission row.

**One PR fix.** Add durable claimed/dispatch-acknowledged continuation delivery;
keep an uncommitted one-shot retryable, and roll back/settle a local launch
failure atomically with its receipt. Acceptance: missing CLI and transient remote
failure do not consume a one-shot or create a ghost active mission.

### RUN-10 — No independent remote-followup pump without an active poller (M/D, high; narrowed)

**Effect.** A waiting **remote-placement** followup without an active remote
poller has no automatic consumer. Manual queue APIs are not a background
delivery pump. Local queue-drain parity is not established by the Rust pump
cited here and is not counted as a confirmed regression.

**Rust evidence.** `src/api/control/hub.rs:451` starts the pump;
`src/api/control/remote_queue.rs:461–505` wakes on job exit or every 3 s,
deduplicates by mission and processes up to eight missions concurrently.
Critically, `src/api/control/remote_queue.rs:510–528` explicitly uses
`NoLocalFallback` and requires remote placement. This limits the old guarantee
to remote followup work.

**Lean evidence.** `C/RemoteDispatch.lean:817–842,1009–1024` pops a waiting followup
only from the remote terminal-job path. Startup reattachment at `:1202–1256`
selects nonterminal runs with active/pending missions, not waiting queue rows.
`C/Control.lean:4750–4869` exposes explicit queue operations; no independent
remote queue pump is registered at `:6447–6470`. Immediate message delivery and
active remote-job completion are distinct wired paths, so this does not claim
that all message-send paths fail. Local completion at `:1515–1539` lacks this
particular drain, but whether it regresses another Rust local consumer remains
**U**, outside this finding's admitted scope.

**One PR fix.** Restore a durable remote-placement followup pump, triggered by
remote terminal receipts plus periodic restart repair; preserve claim-generation
and boot fencing. Acceptance: a remote waiting queue survives restart with no
active poller and is delivered once when its owner is idle. Unifying local
followups with this owner would be a separate extension, not proven parity work.

### RUN-11 — First 32 blocked continuations can starve later due work (D, medium)

**Effect.** Due rows for 32 still-active owners remain armed at the front of the
same ordered query forever. A later idle owner's due wakeup is never inspected.
The 2 s interval does not guarantee progress/fairness. This requires a prefix
of at least 32 blocked rows; no production starvation was observed in this audit.

**Rust evidence.** `src/api/control/automation_scheduler.rs:146–157` iterates the
active automation collection, performing the busy-owner decision within the
iteration rather than stopping after a fixed prefix of blocked owners.

**Lean evidence.** `C/RemoteDispatch.lean:1390–1397` selects the ordered prefix
`LIMIT 32`; `:1433–1435` leaves active/pending/waiting-background owners unchanged.
The next pass uses the same query. A future-due durable-job row can also occupy
this prefix because all `durable_job_terminal` rows are selected regardless of
due time, with the actual test deferred to `:1414–1423`.

**One PR fix.** Page through a bounded fair cursor or exclude non-actionable owners
and nonterminal jobs in the candidate query, retaining correctness rechecks at
claim time. Acceptance: 32 blocked rows cannot prevent row 33 from firing.

### RUN-12 — Telemetry's periodic flush depends on an idle accept poll (D, medium)

**Effect.** With telemetry enabled and a pending batch, sustained successful
accepts can suppress the periodic outbound flush indefinitely. This is a
conditional source-derived failure, not an observed production starvation or a
claim that telemetry is never sent: the explicit ingestion route can also start
a flush.

**Rust evidence.** `src/api/usage_telemetry.rs:43–44,569–584` runs an independent
30 s or wake-driven flusher, draining batches, with max backoff 600 s.

**Lean evidence.** `C/Control.lean:6481–6502` checks the 30 s flush only inside the
`tcpAcceptPoll` error/timeout arm. The successful-accept arm services watchdog
notifications but not telemetry. `C/TelemetryAndVoice.lean:628–686` has a real
batch flusher/backoff; it lacks an independent periodic caller here.
`C/Control.lean:5624` is the separate ingestion-triggered flush.

**One PR fix.** Move telemetry scheduling to an independent single-owner task
(or execute the due check after either accept outcome), coalescing in-flight
flushes. Acceptance: continuous accepted connections do not suppress a pending
batch past its flush deadline.

## Background-duty inventory

Each row is a logical duty, not every async database offload or test spawn.
Conditional/default-off duties remain in the inventory. The action-worker and
Node sections distinguish work outside Core's boot loops.

### Server startup and process-wide duties

| Duty | Rust interval/default/shape and evidence | Lean evidence and current shape | Class / ownership |
|---|---|---|---|
| Hermes service drain policy | Boot once; `src/main.rs:46–53` | `C/CliMain.lean:82–98`; no equivalent boot service migration traced | M; RUN-01, deploy docs also recovery §4 |
| Key/config initialization | Boot once; `src/main.rs:55–85` | Store/auth setup `C/Control.lean:6341–6400`; exact key compatibility not audited | U |
| MCP startup refresh | Detached boot `refresh_all(true)`; `src/api/routes.rs:203–209` | Gateway exists; no registry refresh task in `C/Control.lean:6335–6508` | M |
| Orphan command containers | Boot machinectl sweep; `src/api/routes.rs:302–328` | No Core boot sweep at `C/Control.lean:6335–6508` | M; RUN-03 |
| Console session expiry | Every 10 s, disconnected retention 30 s; `src/api/console.rs:34–37,79–82` | Generic WS loop `C/Control.lean:5820–5857`, no session pool | S; RUN-06 |
| Monitoring sample | Independent 1 s process/container collection; `src/api/monitoring.rs:336,426–430`, startup `routes.rs:197,250` | Resources on request, `C/ResourcesAndSystem.lean:334`; monitoring WS generic | D/S |
| Proxy latency summaries | Every 300 s; `src/api/routes.rs:299–300`, `src/api/proxy_timing.rs:947–948` | No corresponding timer in `C/Control.lean:6335–6508` | M |
| Software queue worker | Thread, 5 s poll; `shared/agent_software.rs:1042–1048`, `routes.rs:331` | Request-time system/software handlers; no boot worker traced, `C/ResourcesAndSystem.lean` + boot `Control.lean:6335–6508` | U: handler internals not exhaustively traced |
| Library initialization/skill sync | Boot if remote configured; up to 8 concurrent workspace syncs; `routes.rs:476–512` | Skill operations in `C/Skills.lean`; boot path does not launch this sweep | M for boot sweep; feature compatibility U |
| Search backfill | Boot + 15 ms yield, 8 ms between batches; `src/api/mission_store/sqlite.rs:666`, `sqlite/search_index.rs:257–285` | Opens index `C/Control.lean:6380`; request indexing at `:3218,3714,3738`; no historical backfill task | D |
| Resource rollup backfill | Boot detached recent 8-day backfill; `src/api/mission_store/sqlite.rs:669`, `sqlite_resources.rs:495–515` | Legacy hydration at `C/Control.lean:6368`; equivalent rollup backfill not established | U; compute history owned recovery §2.3 |
| Validation outbox forwarder | Every 5 s; `src/api/validation.rs:1138–1145`, `routes.rs:607` | No registered timer `C/Control.lean:6335–6508` | M |
| Project STATE ingestion | Every 60 s; `src/api/projects_overview.rs:65–76`, `routes.rs:608` | Project files handlers `C/ProjectFilesAndController.lean`; no boot ingestor | M |
| Evidence observer | Every 600 s; `src/api/evidence_watch.rs:18,156–159`, `routes.rs:609` | No registered observer `C/Control.lean:6335–6508` | M |
| Project-context filesystem observation | Boot scan + filesystem notifications, not a timer; `src/api/project_files.rs:927–962`, `routes.rs:615` | Request-time context operations `C/Control.lean:5460–5521`; no Core filesystem observer | D; RUN-05 |
| Managed key discovery | Detached boot Bitwarden discovery; `routes.rs:727–731` | Boat key load `C/Control.lean:6381`; expanded registry/key work owned | D; provider plan step 0 |
| Managed VM reaper | Every 30 s or activity notification + 1 s coalesce; `src/managed/mod.rs:2697–2708` | Provider observation definitions `C/Managed.lean:969–996`, no boot reaper | M; **already owned recovery §2.1** |
| Managed provider reconcile + snapshot cleanup | 20 s initial delay, then max(30 s, configured 120 s default); `src/managed/mod.rs:668,2710–2719` | `C/Managed.lean:969–996` defined observations; no periodic caller in Core startup | M; **already owned recovery §2.1**, snapshots §1 |
| Remote fleet heartbeat monitor | 15 s default; zero disables; configured fleet required; `src/remote_node/monitor.rs:1163–1194` | Request probes `C/RemoteFleetAndRelay.lean:606`; heartbeat/relay paths exist but no process-wide monitor | D; **already owned recovery §2.2** |
| Provider usage refresh | 20 s boot delay, 2 s staggering, then 120 s refresh; stale at 600 s; `src/api/ai_providers.rs:11225–11257`, `provider_usage_cache.rs:20–24` | Demand-triggered dedicated refresh `C/ProviderUsageAndLogin.lean:716–752,1402–1403`, same 120/600 s thresholds | D: no idle refresh |
| Kimi token refresh | 240 s; `src/api/ai_providers.rs:12186–12201` | No boot timer `C/Control.lean:6335–6508`; demand credential paths not equivalent proactive loop | M for timer |
| CLIProxy account projection | 30 s; `src/api/cli_proxy_accounts.rs:149–153` | Hydration/auth routes, no registered projection timer in `C/Control.lean:6335–6508` | M for timer |
| Antigravity account refresh | 300 s; `src/api/antigravity_accounts.rs:34,1257–1261` | No registered refresh timer in `C/Control.lean:6335–6508` | M for timer |
| Generic OAuth refresh/rotation reconcile | 10 s boot delay; every 15 min, refresh within 1 h expiry; drains pending rotations first; `src/api/routes.rs:3490–3558` | Auth rotation handle constructed `C/Control.lean:6400`; ledger/drain APIs `C/AuthSidecar.lean`, no periodic caller established | D/U: definitions ≠ proactive renewal |
| Compute sample/retention | Every 60 s; `src/api/resources.rs:53–55` | Live-only history explicitly documented `C/ResourcesAndSystem.lean:332–334,546` | M; **already owned recovery §2.3** |
| Metadata client initialization | Boot detached configuration refresh; `src/api/routes.rs:750–767` | Mission title operations exist; equivalent task not established in boot path | U |
| Assistant/MCP gateway worker | Queued work, event driven; `src/control_mcp/gateway.rs:2151–2185`, `routes.rs:770` | In-process `C/McpGateway.lean` routes; dedicated queue-worker equivalence not established | U |
| Desktop session cleanup | 900 s default; `src/api/desktop.rs:25,661–716`, `routes.rs:772–777` | No desktop lifecycle owner in generic WS `C/Control.lean:5820–5857` | M/S; RUN-06 |
| Mission workspace GC | Hourly; retention/default gates described RUN-04; `src/api/mission_workspace_gc.rs:31–84` | No boot timer `C/Control.lean:6335–6508` | M; RUN-04 |
| Disk pressure watcher | 5 min; 24 h repeat, 3-point hysteresis; `src/api/disk_watch.rs:22–35,122–169` | Request-time resources only `C/ResourcesAndSystem.lean:334` | M; RUN-04 |
| Telemetry flushing | 30 s or wake; backoff cap 600 s; `src/api/usage_telemetry.rs:43–44,569–584` | Accept-idle 30 s check + ingestion trigger, `C/Control.lean:5624,6481–6502` | D; RUN-12 |
| Scope status listener/reaper | Event+30 s grace; 15 min sweep; `src/api/scope_reaper.rs:45–78,332–384` | No boot registration `C/Control.lean:6335–6508` | M; RUN-03 |
| Boot mission/scope reconcile | Once after 45 s; configured enabled; `src/api/reconcile.rs:80–124,968–974` | Real immediate store reconcile `C/Store.lean:731–837,1164`; narrower observations/effects | D; RUN-01 |
| Remote-job restart repair | Initial 10 s; periodic backoff/rechecks `src/api/control/remote_jobs.rs:1238–1321` | Once before continuation loop, `C/Control.lean:6465`; persisted-offset reattach `C/RemoteDispatch.lean:1202–1256` | D: real, not absent |
| Remote rate-limit replay | Every 30 s; `src/api/control/remote_jobs.rs:1330–1334` | Wait/replay store gates `C/Store.lean:3105–3433`; no independent periodic replay caller identified | U: do not infer runtime from gates |
| Queued-job rebalance | 30 s; >=2 enabled static nodes; `src/api/control/rebalance.rs:17,143–149` | No boot rebalance registration `C/Control.lean:6335–6508` | M |
| Deferred proxy worker | 2 s when idle; 330 s HTTP timeout; `src/api/deferred_proxy.rs:13,282–303` | No corresponding queued proxy worker in boot path `C/Control.lean:6335–6508` | M |
| Eager control sessions/hosted resume | Boot default + configured cloud owners; `src/api/routes.rs:817–839` | Cloud supervisor actually starts `C/Control.lean:6447–6448`; every 2 s scan up to 32 nonterminal rows `C/CloudHttpAndWorker.lean:1277–1295` | D; not missing |
| Model catalog refresh | Immediately + 600 s default; zero means one fetch; `src/api/providers.rs:1560–1584` | Provider/model request handlers, no periodic registration in `C/Control.lean:6335–6508` | M for timer |
| Systemd watchdog | WATCHDOG_USEC/3 (minimum 100 ms); dedicated thread probes Tokio responder; `src/watchdog.rs:32,77–110`, `routes.rs:1762–1763` | Accept-loop notifications; half configured timeout or 15 s default; `C/Control.lean:6471–6504` | D: listener responsiveness, not runtime/mission probe |
| Graceful shutdown | Signal-driven session drain + 5 s connection grace; `src/api/routes.rs:15–16,1765–1897` | STOPPING emitted only on normal loop exit `C/Control.lean:6503–6508` | M/D; RUN-01 |

### Per-control-session and scheduler duties

| Duty | Rust interval/default/shape and evidence | Lean evidence and shape | Class |
|---|---|---|---|
| Event fanout/ring pruning | Event-driven + 30 s prune; `src/api/control/actor.rs:48–75` | Broadcast hub and store subscriber dispatcher `C/Control.lean:6412`, `C/Store.lean:1444–1446` | D: different ownership |
| Main actor scheduling | Parallel-completion 100 ms, queued-delivery retry 1 s, execution heartbeat 15 s; `src/api/control/actor.rs:622–624` | Direct request handlers plus warm readers; no equivalent main actor in `C/Control.lean:1551–1587,6447–6470` | D |
| Persistent event logger | Receives broadcast events; `src/api/control/actor.rs:243–369` | Store-first append/broadcast callbacks `C/Control.lean:1515–1539`, remote event ingestion `C/RemoteDispatch.lean:899–908` | D: no separate logger required to count this as durable |
| Shutdown mission recovery | Boot once persistent sessions; `src/api/control/actor.rs:164–174` | Real store boot reconcile, no local launch/reattach `C/Store.lean:731–837` | D; RUN-01 |
| Stale active cleanup | 300 s checks if configured stale hours >0; `src/api/control/actor.rs:177–185`, `src/api/supervision.rs:1492–1508` | No registered same-boot sweep `C/Control.lean:6447–6470` | M; RUN-02 |
| Stuck/OOM/idle-worker supervision | 60 s, 900 s inactivity, idle child notify 3600 s default (zero disables); `src/api/supervision.rs:889–1127` | No matching observer; seeded `C/HostObservers.lean:298–304` is not a caller | M; RUN-02 |
| Background-shell completion | 10 s, enabled by default; `src/api/control/actor.rs:210–239`, `src/api/supervision/bg_autoresume.rs:23–47,265` | Old-boot settlement only `C/Store.lean:806–817` | M/D; RUN-02 |
| Native goal/cron observer | Event-driven if automations enabled; `src/api/control/actor.rs:372–380` | Parser models exist `C/Harness.lean`; actual readers `B/ClaudeControl.lean:1272–1363,1704–1774` do not wire that observer | M |
| Automation/continuation scheduler | 5 s; `src/api/control/automation_scheduler.rs:62–99` | 2 s **after pass**, `C/Control.lean:6468–6470`; time/job/interval logic `C/RemoteDispatch.lean:1376–1523` | D; RUN-08/09/11 |
| Workflow timeout | Every ~60 s, waiting-external age 30 min; `src/api/control/automation_scheduler.rs:101–115` | No matching housekeeping in `C/RemoteDispatch.lean:1376–1523` | M |
| Scheduled-message crash recovery | Every ~60 s, sending age 5 min; `src/api/control/automation_scheduler.rs:117–131` | No matching housekeeping in real scheduler `C/RemoteDispatch.lean:1376–1523` | M |
| Webhook dedup GC | Every ~60 s, age 15 min; `src/api/control/automation_scheduler.rs:134–141` | No matching housekeeping in `C/RemoteDispatch.lean:1376–1523` | M |
| Paloma webhook forwarding | Event-driven + 60 s reconciliation, 250 ms retry progression; `src/api/control/actor.rs:103–121`, `webhook_forwarder.rs:147,559,575` | No registered forwarder `C/Control.lean:6447–6470` | M |
| Telegram status alerts | Event subscription; `src/api/control/actor.rs:96–101`, `src/api/telegram.rs:2588–2619` | No event-alert task established; hosted Hermes transport is separate `C/CloudHttpAndWorker.lean:980,1277` | U |
| Telegram schedule delivery | 2 s; `src/api/telegram.rs:125,2887–2888` | Controller/cron proxying `C/ProjectFilesAndController.lean:973–1078` is not this Core scheduler | M for Core loop |
| Remote followup pump | 3 s + completion wake, concurrent 8; `src/api/control/hub.rs:451`, `remote_queue.rs:471–505` | Only remote terminal path pops next row `C/RemoteDispatch.lean:817–842,1024` | D; RUN-10 |
| Hosted per-mission worker | Spawned via control hub, scan every 1 s; `src/api/control/hub.rs:554`, `src/api/cloud_agents/worker.rs:5–37` | Real worker `C/CloudHttpAndWorker.lean:1247–1274`: 1500 ms Cursor / 400 ms Hermes; cap 3600 iterations, then supervisor can reclaim | D |
| Hosted restart supervisor | Per-user worker resumes stored work, above | Real process-wide 2 s scan, excludes uncertain/reconnect-required terminal-like states; `C/CloudHttpAndWorker.lean:1277–1295` | E for existence/restart driver only; provider semantics U |

### Execution, request-scoped workers, and transports

These do not all need replacement background timers. A request-local lifetime or
changed architecture is recorded rather than assuming every Rust spawn should
be copied.

| Duty / stream producer | Rust evidence and interval/shape | Lean evidence and interval/shape | Class |
|---|---|---|---|
| Mission runner/start/cancel owner | `src/api/mission_runner.rs:1013,3788`; actor owns tasks; per-workspace drivers | Local start `C/Control.lean:1551–1587` → `B/ClaudeControl.lean:1591–1774`, process groups, cwd confinement and optional worktrees | D: actually executing |
| Warm local harness output | Driver stdout/stderr and mission execution lifetime; `src/api/runners/claudecode.rs:1892–1994` | Claude NDJSON lifetime reader, callbacks per turn; `B/ClaudeControl.lean:1272–1363`; no read-progress timeout | D; RUN-02 |
| Non-Claude local output | Separate OpenCode/Codex/ACP drivers; `src/api/runners/opencode.rs:955`, `src/backend/codex/app_server.rs:360–380`, `src/api/grok_tool_bridge/acp.rs:674–895` | One-shot CLI reader/parser `B/ClaudeControl.lean:1414–1585,1687–1774` | D; protocol/session parity not proved |
| Local process stop | Runner cancellation/actor shutdown | Explicit TERM → 80 ms → KILL/wait, `B/ClaudeControl.lean:1011–1042`; actual path does not use registry kill handle | D; PID-reuse safety of this path U |
| Local model-discovery subprocess | Request/probe worker, not periodic; `src/api/providers.rs:2457–2519` | Reader task, 50 ms polling, 8 s deadline, kill/reap `B/ClaudeControl.lean:555–596` | D |
| Remote job submission/poll | Request spawn; state polls plus 500 ms log tick; `src/api/control/remote_jobs.rs:1980–2033,2151–2166,2228` | Real per-job task every 350 ms after prior pass; log chunks 256 KiB, max 8 per pass; state request 12 s; `C/RemoteDispatch.lean:847–963` | D |
| Remote terminal drain/cancel | Job-owner/cancellation observers `src/api/control/remote_jobs.rs:1113–1244,2228–2295` | Final log drain/cancel checks `C/RemoteDispatch.lean:869–880,963–1024`; 60 consecutive state-call errors → lost/failed | D; stale-generation effects require further review |
| Durable job heartbeat/deadline | 15 s heartbeat plus timeout/cancel clear; `src/api/durable_jobs.rs:744–793,905–907` | Durable job API `C/RemoteFleetAndRelay.lean:937`; no matching local durable-job heartbeat owner established | U |
| Managed provisioning readiness | Async spawn/provision; 2 s state/enrollment polls; `src/managed/mod.rs:4378,4682–4718,5005–5066` | `C/ManagedProvisioning.lean:24,71,103,114`, shared worker provisioning; `C/RemoteFleetAndRelay.lean` caller | D; **owned provider plans** |
| Relay command wait | Remote client request ownership `src/remote_node/client.rs:489` | Request-local 25 ms polling, default timeout 25 s; `C/RemoteFleetAndRelay.lean:177–208`; relay long poll 25 s configured `C/Control.lean:6413`, 100 ms checks `:2368–2369` | D |
| Ask sandbox heartbeat/cleanup | During remote Ask, 60 s heartbeat; `src/api/ask/mod.rs:1990–1991`; setup/cleanup tasks `:1795,2233` | Startup Ask GC `C/Control.lean:6372`; registry sidecar APIs `C/HarnessSessionRegistry.lean:1745–1778`; live heartbeat parity not established | U |
| Ask/BTW answer workers | Request-scoped channel workers `src/api/ask/http.rs:614–645`, `src/api/ask/btw.rs:254–286` | BTW child uses local launch `C/Control.lean:2984–3133`; not old Ask SSE adapter | D |
| OAuth/login/device polling | Provider-specific TTL/poll loops; `src/api/ai_providers.rs:11997–12021`, `src/api/cli_proxy_login.rs:354,543`, `src/api/github_integration.rs:182` | In-request/provider login APIs `C/ProviderUsageAndLogin.lean`; exact per-provider poll/timeout equivalence not fully traced | U; no blanket missing-auth claim |
| Metadata/background refresh | One-shot title/description updates `src/api/control/mission_metadata.rs:1554,1604` | Request/title and imported legacy metadata, `C/Control.lean:3938–3970`; lifecycle equivalence unverified | U |
| Board/transfer/remote-build actions | Request workers `src/api/control/board.rs:843,1773`, `machine_transfer.rs:946`, `src/api/remote_build.rs:901,952` | Store/remote request paths; no complete worker equivalence traced | U: no false PASS |
| MCP client renewal | Every 60 s while stdio alive; `src/control_mcp/client.rs:965–974` | Real 60 × 1 s cancellable sleep + renewal `B/SandboxedMcpMain.lean:1571–1583` | E for renewal cadence/lifetime |
| MCP subprocess I/O | Stderr drain + response demux, process lifetime; `src/mcp/registry.rs:1093–1106` | In-process gateway and stdio entrypoint; registry/subprocess supervision parity not established | U |
| Generic command task / agent task | Request-spawn stdout/stderr readers, timeout and 2 s drain; `src/api/routes.rs:2770–2806,2938–2943,3109–3177`, `src/agents/context.rs:125,151`, `src/agents/opencode.rs:244` | No equivalent `/api/task` process-lifecycle path established in `C/Control.lean` | M for legacy task surface; legacy usage U |
| Agent event backend readers | Backend stdout/stderr/session tasks; `src/backend/claudecode/client.rs:130–186`, `src/backend/opencode/mod.rs:85`, `src/opencode/mod.rs:190,345` | Real local readers in `B/ClaudeControl.lean`; **not** evidence that old backend session models are used | D |
| Workspace build cancellation/settlement | Claim/settle tasks survive request cancellation; `src/workspace/mod.rs:797–880` | Request/Node preparation differs; exact equivalent guard not established | U |
| Deployment/update workers | Request-spawn with progress channels; `src/api/system.rs:3915,6229` | Guarded synchronous deploy `C/CliMain.lean:31–78`, `C/Control.lean:5524`; full flow already recovery §4 | D; already owned |

### Node execution duties (separate executable, not Core startup)

| Duty | Rust reference/default/shape | Lean reference/default/shape | Class |
|---|---|---|---|
| Node scheduler/admission | Actor spawn `src/node/runner.rs:499`; job launch workers `:972` | Main server drives `tickRuntimeReserve`, 200 ms accept timeout + request-time calls; `N/Server.lean:640,1899–1933`, `N/Runner.lean:1865` | D; real |
| Process liveness/reaping | 30 s default sweep, 20 s vanish grace; `src/node/runner.rs:88–93,1135–1144` | Actual tick inspects live processes, exit status and verified teardown; `N/Runner.lean:1895–1956`; request/accept-loop driven, not independent 30 s task | D |
| Node timeout/cancel escalation | Max job default 14,400 s, kill grace 1 s; `src/node/runner.rs:29–35` | Timeout branch `N/Runner.lean:1934–1956`; verified process groups; config-default equivalence not fully checked | D/U |
| Steer-between-tools watcher | 100 ms + 120 ms stable window; `src/node/runner.rs:974–996` | Real per-steer dedicated task `N/Server.lean:1273–1302`, same 100/120 ms checks | E for cadence/role |
| Async preparation/launch | Task-per-launch; `src/node/runner.rs:972,1328` | Dedicated worker, cleanup on exception, launches outside mutex; `N/Server.lean:1230–1271` | D; real |
| Capacity config reload | 30 s file watcher; `src/node/capacity.rs:31,625–647` | SIGHUP-driven reload `N/Server.lean:1912–1922`, implementation `N/Runner.lean:1221`; no periodic file watcher established | D |
| Project context replica daemon | Every 2 s; `src/node/project_context.rs:49–74` | Dedicated 2 s daemon `N/ProjectContext.lean:681–703`, wired `N/Server.lean:1907` | E for scheduling |
| Dial-out relay/reconnect | `src/node/dial.rs:112–142`; request workers/reconnect | Real dedicated relay/request tasks + backoff `N/Dial.lean:129–155`, wired `N/Server.lean:1908–1909` | D; exact backoff parity U |
| Confined slot provisioning | Retry 5 s, request timeout 15 s; `src/node/slot.rs:22–47,165`, runner `:486` | `N/PrivdClient.lean`/per-user job paths exist; equivalent slot retry owner not traced | U |
| Job scopes/checkouts/scratch teardown | Per-job completion/cancel, `src/node/runner.rs:1252`, `src/node/scratch.rs:118` | Dedicated teardown `N/Runner.lean:997–1005`, actual calls `:1916,1943,1969,1994,2116`; receipt retirement in `N/Store.lean:1322,1438` | D; do not call all Node GC missing |
| Scratch aged/pressure sweep | Demand/prebuild sweep, 72 h retention / 6 h pressure age; `src/node/scratch.rs:13–15,255–269`, `src/node/lean.rs:2825,2955` | Receipt retirement is real; equivalent aged/pressure sweep not established by inspected caller paths | U |
| Job ledger / crash restore | Ledger actor `src/remote_node/job_ledger.rs:398`; startup recovery separate | `N/Store.lean:937` opens ledger; async sync retry `:1516–1518`; full recovery/lost-process policy not compared exhaustively | U |
| Node output/transfer drains | Concurrent stdout/stderr; `src/nspawn.rs:418,442,776,793`, `src/node/lean.rs:3145–3152`, `src/machine_transfer_archive.rs:189` | `N/Runner.lean:2343–2344`, `N/Transfer.lean:1209,1269`; capped execute output and request-local drains | D; transfer framing parity U |
| Node signals/shutdown | Separate Node lifecycle, not Core's handler | Real install/poll/finally `N/Server.lean:1900–1954`; SIGHUP reload, TERM/INT exit, gone relay stops loop | E for presence, detailed drain policy U |

## Stream inventory

Shape includes framing and connection lifetime, not just endpoint existence.
Finite JSON/event retrieval is not an SSE stream. Rust tests that instantiate
mock SSE servers are excluded.

| Stream | Rust shape/default and source | Lean shape/default and source | Class |
|---|---|---|---|
| Control SSE `/api/control/stream` | Initial `status`, named live AgentEvents; mission/kinds filters; replay >since_seq capped 500; `stream_lagged`; 15 s keepalive; `src/api/control/streaming.rs:735–1144` | One `missions_snapshot`, ID 1, 200 missions; `C/Control.lean:3898–3910` | S; RUN-05 |
| Mission-filtered SSE | Same Rust endpoint with mission/mission_id query, `since_seq`, kinds; `streaming.rs:7–28,831–879` | Separate `/missions/:id/stream`: one `snapshot`, ID 1, first 100 events, `C/Control.lean:3912–3927`; ignores old filtering/replay contract | D/S; RUN-05 |
| Control WS `/api/control/ws` | Live AgentEvents, `Resume{since_seq}`, 15 s heartbeat, 1 s shutdown check; `src/api/control/streaming.rs:546–720`; route `routes.rs:998` | Not in explicit upgraded route list `C/Control.lean:1196–1199`; generic upgrades are not this live transport | M |
| Multiplexed sync WS `/api/control/sync` | `orb-sync.v1`, sync_ready, subscriptions/presentation/replay/caught-up; 10 s independent heartbeat; 64 subs, replay 500; `src/api/control/sync_stream.rs:18–21,125,238–290,369` | **Live**, authorized replay+push; 512 outbound frames/2 MiB; max payload default 4096 (256..65536); heartbeat only after 15 s read-idle; `C/Control.lean:5874–6010,6147–6181,6185–6193,6245–6266` | D, not S/M; subscription-cap equivalence U |
| Console WS | PTY-backed, reconnect pool 30 s, sweep 10 s; `src/api/console.rs:34–37,79,132–425` | Generic ready/ack/ping/pong, 2 s read poll, max 64 steps; `C/Control.lean:5820–5857,6322–6330` | S; RUN-06 |
| Workspace shell WS | Workspace shell input/output, `src/api/console.rs:486–771`; route `routes.rs:878–880` | Same generic loop, no shell owner passed; `C/Control.lean:1196–1199,6322–6330` | S; RUN-06 |
| Desktop WS | Receive/input/video-frame workers; `src/api/desktop_stream.rs:153,189,294` | Same generic ACK loop `C/Control.lean:6322–6330` | S; RUN-06 |
| Monitoring WS | JSON metrics pushed from collector, receive/stream tasks; `src/api/monitoring.rs:750–828` (collector 1 s) | Same generic ACK loop `C/Control.lean:6322–6330` | S; RUN-06 |
| Client-link WS | Linked-client command/event bridge, ping every 15 s; `src/api/control/client_link.rs:644,805`; `routes.rs:1001` | No client-link WS route in explicit list `C/Control.lean:1196–1199`; managed/client mission rows do not supply this bridge | M |
| Task SSE `/api/task/:id/stream` | `log`, terminal `done {status,result}`, polls 100 ms; `src/api/routes.rs:3337–3405` | No executing legacy task stream established in `C/Control.lean` dispatcher | M |
| Ask SSE | Request worker → channel → SSE, keepalive default; `src/api/ask/http.rs:449,614–645` | BTW/local child mission path `C/Control.lean:2984–3133` differs; old Ask streaming transport not traced | U/D |
| BTW SSE | `event: btw` JSON channel until completion, default keepalive; `src/api/ask/btw.rs:208,254–286` | Child-agent lifecycle and sync events, `C/Control.lean:3000–3133`; not the old SSE body contract | D |
| Context file-change SSE | Initial + filesystem `event: changed`, `data: {}`, default keepalive; `src/api/project_files.rs:969–994` | One generated event body, `C/R7Core.lean:572`, `C/Control.lean:5488–5497` | S; RUN-05 |
| Proxy model SSE `/v1/*` | Incremental bytes/translated events, 15 s keepalive, idle/progress control; `src/api/proxy.rs:3417–3425`, `proxy_reliability.rs:290–327` | Buffered ByteArray until full upstream response; plaintext 16 MiB, 10 min idle/1 h total; TLS full drain; `C/Proxy.lean:745–788,1056–1076` | D; RUN-07 |
| System update/deploy progress SSE | Channel/async stream progress, `src/api/system.rs:2722–2778,2854–2876,3493,3915–3916,4685–5053` | Guarded deployment result, `C/CliMain.lean:31–78`, `C/Control.lean:5524`; progress stream parity not established | D/U; recovery §4 owns full deploy |
| Cyber response stream | Request-local async response body `src/api/control/cyber.rs:424` | `C/Cyber.lean` exists; incremental downstream lifetime not traced | U |
| Cloud event API | `/missions/:id/cloud/events` is event retrieval, not assumed live SSE; `src/api/routes.rs:1036–1037` | Cloud workers persist/publish events `C/CloudHttpAndWorker.lean:969,1247–1295` | U for wire parity; do not miscount REST as stream |
| Harness stdout/SSE/ACP | Per-driver NDJSON + OpenCode SSE/CLI + ACP; `src/api/runners/opencode.rs:955`, `src/api/grok_tool_bridge/acp.rs:674–895` | Actual local stdout NDJSON/one-shot reader `B/ClaudeControl.lean:1272–1363,1704–1774`; dual-channel reconciliation only defined elsewhere | D; proof wiring below |
| Remote logs/relay | Polled NDJSON log bytes/state; `src/api/control/remote_jobs.rs:2228`; remote relay client `src/remote_node/client.rs:489` | 350 ms task, 256 KiB chunks/max eight, offset persistence; `C/RemoteDispatch.lean:847–963`; 25 s relay longpoll `C/Control.lean:6413,2368–2369` | D; real stream-over-polling |

## Defined/proved versus actually invoked

| Surface | Definition/proof evidence | Actual host-call evidence / limit |
|---|---|---|
| `HostObservers.scheduler_pass` | `C/HostObservers.lean:246–248` calls a board-slot export on fixed seed-selected arguments | No scheduler registration/caller in actual Core loop. Not a runtime scheduling pass. |
| `HostObservers.decide`, `classify_mission` | `C/HostObservers.lean:298–304`, seed-selected all-zero/all-one vectors and export lookup | Not actual mission/VM observations. Actual store reconciliation **does** invoke `Orb.Kernel.reconcileStep` at `C/Store.lean:794–796`, with several observations hardcoded zero and limited interpreted effects. |
| `RunCoordinator` | `C/RunCoordinator.lean:208–394` models tool drain/tombstones and admits transitions | Production local launcher uses `B/ClaudeControl.lean`, not this coordinator. No production call found outside model/self-test dependencies in the inspected Core tree. |
| Harness dual-channel completion | `C/Harness.lean:348–364`; `C/HarnessSessionRegistry.lean:249–542` models OpenCode SSE + CLI-exit handling | Actual local OpenCode path is one-shot CLI (`B/ClaudeControl.lean:1441,1687–1774`); do not claim that model's SSE/CLI-exit fence runs there. |
| PID-safe registry stop | `C/HarnessSessionRegistry.lean:108–175,634–642` observes `/proc` start ticks and invokes liveness gate before kill | Actual local stop is `B/ClaudeControl.lean:1011–1042`, raw process-group signal/wait. Node separately performs real verified teardown (`N/Runner.lean:1913–1916`). |
| Harness continuity restart | `C/HarnessSessionRegistry.lean:1047–1423` supplies CAS, prompt claim, delivery and restart reconciliation | Import/open at `C/Control.lean:25,61` does not instantiate registry or wire continuity operations to `startHarnessTurn`. Startup only calls Ask bootstrap at `:6372`. |
| Ask sidecar GC | `C/HarnessSessionRegistry.lean:1745–1778` | **Wired** at `C/Control.lean:6372`, not unused. It is startup-only and not all-workspace retention. |
| Managed observation | `C/Managed.lean:969–996` | Defined, not periodically fed at startup. Already-owned fleet gap; no duplicate RUN finding. |
| Proxy commitment gates | `C/Proxy.lean:790–805` and forward-chain kernel calls | Pure admission/fallback logic really exists; actual downstream writing occurs only after dispatch (`C/Control.lean:6312–6321`). Proved model commitment is not a receipt of a socket write. |
| Node process lifecycle | `N/Runner.lean:1865–1994`, `N/Server.lean:1899–1933` | Actual tick called from request/accept paths; unlike the unused Core registry, these are executing host paths. |

## Existing ownership and non-duplication

- **Recovery plan §1 / provider child plan:** provider registry, Boat snapshots/fork/
  restore/placement, lean.ci/Colab clients, provisioning readiness and provider key
  sealing. Provisioning is now wired; the plan's original description is historical,
  not proof that current Boat only inserts a row. Do not re-open as RUN findings.
- **Recovery §2.1:** VM TTL reaper, provider reconciliation, orphan destruction and
  cost-ledger closure, including unused provider observations. The missing Core
  scope reaper (RUN-03) owns OS scopes, not rented-machine deletion.
- **Recovery §2.2–2.3:** node heartbeat/capacity reality and minute compute history.
  Inventory shows cadence changes, not a competing implementation assignment.
- **Recovery §4:** MCP receipts, event pagination, resume content, timestamps,
  nudge leakage, blended price, TLS quiet-socket behavior, deploy flow and transient
  model-call retry ownership. RUN-05 concerns live SSE/cursors, not MCP pagination;
  RUN-07 concerns incremental downstream bytes, not pricing or the TLS quiet-socket
  defect; RUN-09 concerns durable wakeup delivery, not generic model retry.
- **Provider plan step 0:** prompt action acceptance/readiness polling, transient
  availability, transport diagnostics and reserved key ownership. Not duplicated.

## Review/acceptance handoff

Highest priority source-derived candidates: RUN-01/02 (orphaned/stuck local work),
RUN-05/06/07 (advertised live transports), RUN-08/09/10 (durable scheduling and
followups). RUN-03/04 restore resource maintenance; RUN-11/12 fix fairness/timer
coupling. Priorities are proposed, not production incident confirmation.

### Independent source-review verdicts

The coordinator relayed independent review of all 12 candidates: **11 CONFIRMED,
1 NARROW, no full refutations**. These are source-review verdicts, not live
reproductions or test results. The RUN-10 narrowing is incorporated above.

| Finding | Review verdict | Admitted scope / qualification |
|---|---|---|
| RUN-01 | CONFIRMED | Conditional local-turn restart/drain gap; real store boot reconciliation exists but does not launch local recovery. Host kill policy remains unverified. |
| RUN-02 | CONFIRMED | Local same-boot supervision/background watcher, not an assertion that no global supervision exists. |
| RUN-03 | CONFIRMED | Core/legacy scope cleanup; not a claim every new run leaks or Node cleanup is absent. |
| RUN-04 | CONFIRMED | Preserve opt-in deletion; reservation and pressure drivers are separate duties. |
| RUN-05 | CONFIRMED | Finite SSE contract only; multiplexed sync WebSocket is genuinely live. |
| RUN-06 | CONFIRMED | Non-sync upgraded paths use the generic ACK adapter, not endpoint-specific transport. |
| RUN-07 | CONFIRMED | Incremental HTTP buffering; separate from already-owned TLS deadline, retry and pricing work. |
| RUN-08 | CONFIRMED | Historical schema/write shape independently verified; unsupported triggers are converted and source rows retired. |
| RUN-09 | CONFIRMED | Rust baseline guarantees unacknowledged-delivery retention, not universal retry of all provider failures. |
| RUN-10 | NARROW | Remote-placement followups without an active poller only; Rust pump explicitly disallows local fallback. Local extension remains U and is not counted as a regression. |
| RUN-11 | CONFIRMED | Requires a prefix of at least 32 blocked rows; no observed production starvation claimed. |
| RUN-12 | CONFIRMED | Requires enabled telemetry, pending work and sustained successful accepts; ingestion-triggered flush still exists. |

RUN-05 and RUN-07 should share one streaming HTTP transport owner/framework;
their endpoint-specific fixes must not introduce duplicate streaming frameworks.
RUN-06's unsupported console/shell/desktop/monitoring adapters remain separately
visible rather than being declared complete by a generic upgrade.

No U entry is a PASS or a confirmed new defect. This audit does not attest remote
host environment, service kill policy, browser/client fallback selection,
provider API behavior, or end-to-end proof extraction/runtime coverage.
