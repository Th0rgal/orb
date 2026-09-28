# Remote Claude replies in Orb

Remote Claude jobs used plain `claude -p` output, while the native observer
attached only to Grok, OpenCode and Codex. The generic observer therefore emitted
`Remote job … is now running` and returned the log tail only at termination.
Orb filtered that generated text during stored-event replay, but not during live
SSE reduction, where it could also finalize a live assistant bubble.

The launch command now requests verbose stream-json with partial messages. The
native observer accepts Claude and maps session identity, text deltas, assistant
snapshots, thinking, tool calls/results and terminal results. Repeated full text
and terminal snapshots are not appended twice. A zero process exit without a
terminal Claude result does not count as a successful turn.

Orb applies the same exact generated-status predicate during live reduction,
before changing transcript state. Failed messages and ordinary prose remain
visible. Node lifecycle status continues through mission status events.

Validation: transcript regression suite (14 tests), TypeScript and Vite build
passed. The 20 native observer tests, launch-command test and both Claude continuation/transfer integration tests also passed.


Production verification:
- Installed and running binary SHA-256:
  `3a940aeb6d9505449b6963893d8f4e6b74feac25a31a0eaab680504901338c3a`.
- Read-only Spark canary `92e5b06b-eb8a-4a69-b2a7-e8d3139f1cb7` completed,
  then continued on the same native session.
- Its follow-up SSE capture delivered partial text at 3.02s, complete opening
  text and Bash tool call at 4.02s, tool result at 12.03s, further text at 13.23s,
  and assistant completion at 16.32s. No generated job-status assistant row.
- Durable history contains both completed replies. Initial event persistence
  lagged behind live transport; verification used the actual SSE channel.
- Full receipt: `/root/.cache/claude-stream-sse-receipt.json` on Core.
- An earlier canary caught a stale build artifact from the shared build directory;
  rebuilt and verified the running executable hash before accepting the result.
