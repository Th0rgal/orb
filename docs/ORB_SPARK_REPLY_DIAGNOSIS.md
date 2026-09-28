# Spark reply failure, 2026-09-28

Mission: `be37dfb7-e31f-4327-8259-6f56a0529625`.

1. Job `45cc8169-b5d4-47b7-ac04-eb39051cfac3` was marked running before
   obtaining its external memory slot. It waited from 10:29 until 11:42 UTC.
2. The arbiter had `ARBITER_DRY_RUN=1`: it reported vLLM stopped while actually
   leaving it running. Available memory stayed near 8.3 GB, below the 12 GB guard.
3. After vLLM/router preemption, memory rose to 116 GB and the slot was granted.
4. Startup then failed before Claude with `Core refused scoped session (401
   Unauthorized)`. Scoped MCP sessions expire after one hour; this job waited
   longer than that before using its dispatch-time credential.

Operational repair: backed up `/etc/spark/arbiter.env`, disabled dry-run and
restarted the idle arbiter (no held slots or running build jobs). Restored vLLM
and its router while idle. Its next admission then performed real preemption.
The original PR-tagged mission requires a linked replacement by Core admission:
`d2415091-a5e0-4e38-8582-62f6175ed355`, job
`df088266-db5d-48d5-9bb0-5fa3f5aaf2f2`; admitted with a fresh credential and granted
a slot at 11:47:09 UTC. This record alone does not assert a completed Claude reply.

Remaining systemic work:
- Expose waiting-for-slot and the denial reason separately from harness-running.
- Mint or refresh mission-scoped credentials after admission, before harness start;
  do not broaden token permissions or simply extend all session lifetimes.
- Make dry-run state visible in readiness and reject production scheduling that
  relies on simulated preemption. Verify actual process state and stop results.

Verification: the replacement's native log subsequently contained Claude's complete
French answer (1,369 bytes), confirming the address check ran successfully.
Sidebar navigation fix passed all five WebKit selection regressions plus TypeScript
and production frontend build.
