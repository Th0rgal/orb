# OpenCode runner lifecycle

A tool-call step is progress, not a completed turn. Stdout JSON and SSE use
one parser: `step_finish` with `tool-calls` does not complete the turn, even
after hundreds of steps. Existing inactivity and repeated-provider-error
supervision remains responsible for stopping unhealthy runs; a count of
successful tool steps is not evidence of a loop.

When cancelling or aborting a streaming OpenCode process, Core first reads the unreaped
child’s cgroup and stops that exact scope if its full mission identity matches.
This stops PTY helpers that create separate sessions without touching another
generation’s scope. Where no owned scope is available, Core sends SIGTERM to its owned
child and allows the native MCP launch wrapper to forward termination and
reap the harness before escalating to SIGKILL. Killing that wrapper first
can leave a writer running after its mission lease has ended. Successful
completion uses graceful wrapper shutdown and preserves intentionally detached
background work instead of stopping the entire scope.

The scope reaper also stops host mission scopes after failed or interrupted
runs, using the full mission identity in the scope name. The delayed recheck
preserves a mission already resumed to active/pending or waiting on background
work. Awaiting-user and paused host scopes retain their existing background
work policy. Process-group cleanup alone does not cover children such as
`script` that create a separate session; the owned systemd scope is the
backstop on scoped installations.

Regression evidence: replay more than 40 tool-only steps followed by a real
stop event; terminate a wrapper whose harness has a separate process group
and verify that it reaps that harness; preserve active/background scopes
while cleaning up failed/interrupted host scopes.

This addresses the 2026-10-28 incident in which healthy OpenCode tool work
hit a hard-coded 40-step cutoff, was killed as if complete, and then appeared
as a provider failure because it had not yet produced a final text response.
