# Verity remote goal timeout — 2026-09-27 diagnosis

Mission: ebb2f1fe-8d03-4cc0-b966-68b3cb86077f.
Node: old-agent. Job: 74be2556-e750-4d1b-a506-1f42dc68806d.

Read-only inspection of the node's jobs.db records start at
2026-09-26T16:04:27.163268910Z and finish at
2026-09-26T18:04:27.429106358Z, state failed, exit code null,
error `timed out after 7200s`. The job requested no explicit timeout.
The running node environment still sets SANDBOXED_NODE_MAX_JOB_SECS=7200.

Core submits the native goal as a RawCommand with timeout_secs=None. The
node's clamp_timeout therefore chooses the node maximum; run_logged_command
applies an absolute timer to the entire native process, not an inactivity timer
or a per-goal iteration timer. Timeout kills the contained process tree.

The job log contains 22 native goal iterations and 415 goal.status events,
all active. The final events still show active status and tool progress before
turn.failed reports Codex app-server disconnected. No native completion or
budget stop is present in this log.

The bubblewrap/user-namespace diagnostic is the first log line, at
16:04:27.480187Z. The same process then ran and completed tools for two hours.
It is not the trigger for this terminal timeout. Do not disable host isolation
based on this diagnostic alone.

Current mission status is blocked with native_goal_stopped. That label hides
this node infrastructure timeout; it does not prove Codex chose to stop.
The prior unified MCP deployment did not alter this node lifetime policy.

Follow-up correction should distinguish long-lived native goal leases from
bounded shell/build job deadlines, retain cancellation/resource containment,
and report remote timeout explicitly. Resumption must preserve the native
thread, goal objective, budget and usage; inspect existing validation jobs
before any relaunch. This diagnosis did not resume or mutate the mission.

## Correction and recovery — 2026-09-27

Implemented protocol 5 `RawCommand.long_running` (default false). Core opts
native Codex goal missions into this policy and checks the live node heartbeat
before issuing launch credentials. Older nodes fail closed with an upgrade
instruction. Unlimited goal lifetime retains cancellation, capacity accounting,
process-group/cgroup cleanup and native goal budget/usage stop conditions.
Explicit goal timeouts still apply; ordinary commands and Lean builds retain
the node ceiling. Node deadline failures now use `remote_node_timeout` rather
than `native_goal_stopped` in the native stream observer.

Validation: 16 node runner tests, 11 protocol tests, 17 native stream tests,
and 6 Python Codex continuity tests passed. The new execution regression runs
a goal beyond a one-second node ceiling, checks an ordinary job still times
out, and checks an explicitly bounded goal still times out. Cancellation of
an unlimited job also passes. Linux debug backend and node builds passed.

Deployed to Core production through the guarded endpoint after the active
server-owned Claude mission became idle. Restarted Hermes afterwards.
Backend SHA256:
`7dc4b8bd8d224360ffdb50627db1b1540a54ad5bd060ee9f25ad02f38c40e799`.
Updated idle old-agent node; Core confirms healthy protocol 5 heartbeat.
Other fleet nodes were not restarted in this repair: native goals require
their node upgrade before dispatch, while ordinary jobs remain compatible.
Source changes remain in the local unified-MCP worktree; deployed snapshot
metadata still names its prior base `fe08605a12c4` (the digest identifies the
actual patched binary).

Recovery action `60bbc0b7-d6f7-45ba-8b6a-41f46567d234` completed.
New node job `b5bb9562-28b8-4b55-b3c0-7142d4ef93a7` is running with
`long_running=true`, `timeout_secs=null`, on the same native thread
`01a0de07-cadd-7a61-b0c5-6aa62dfae607`. Its log confirms active native goal,
iteration/turn start, and two completed command executions inspecting saved
state. The agent explicitly confirmed it would preserve the existing goal.
No new mission, thread, objective or budget was created. The two-hour wall
clock has not been waited out; policy execution is covered by the short
boundary regression and the live persisted payload.

## Second failure: host memory exhaustion, recovered 2026-09-27 12:04 UTC

The resumed job ran six iterations then failed at 10:17:17 UTC. Kernel logs
show a global OOM at 10:17:11: Lean PID 2699543 consumed 62,820,696 KiB
anonymous RSS. systemd stopped its entire node-job scope after the child OOM,
which disconnected Codex. The new lifetime policy did not time out.

Installed `/etc/systemd/user/sandboxed-node-job-.scope.d/50-memory-containment.conf`
on old-agent with MemoryMax=24G, MemorySwapMax=4G, OOMPolicy=continue; reloaded
its user manager without restarting the node. Example retained in
`docs/examples/systemd/old-agent-node-memory.conf`. Two slots fit within the
62 GiB host with headroom. An isolated 64 MiB scope killed a 256 MiB allocating
child with SIGKILL while its supervising Python process survived and returned
success. An initial canary using the job prefix inherited the 24 GiB drop-in
and did not exhaust memory; the corrected separate canary verified the policy.

Recovery action 9dc6722e-d8f0-4e2f-91d5-048b902bc3e1 launched node job
8870e648-f6d0-4f31-b97a-56e6198168fb. Same native thread confirmed. Actual
scope reports MemoryMax=25769803776, MemorySwapMax=4294967296,
OOMPolicy=continue. Agent acknowledged the failed smoke and will decompose
its proof without weakening full-state equality. Core reports active/healthy,
generation 18, and the job has completed new inspection commands. Orb was
correct to show the intervening stop; its mission pane polls Core every ten
seconds. No UI or native app restart was needed.
