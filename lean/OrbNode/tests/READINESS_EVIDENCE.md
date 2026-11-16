# Spawn readiness investigation

Base: `20f104597a12ac80874e1b63f1a9c333a76cbb60`.
Fixture handoff: `12fb7dfe580f25f3c3439b251e8ccc4d4cb63656`, preserved by
`30077eac4f9b9c6d8743036712325bd556b0d270`.

## Focused replay before production changes

`SpawnCleanupTest` calls the actual `commitPreparedJob` with the original
`sleep 30` prepared job and `simulated_sqlite_lock`. It retains the existing
60 ms observation delay and dead-process predicate. A diagnostic-only preload
gates the real child's `setsid` on a pipe, releasing it after the original
SIGKILL attempt. No extra sleep, signal retry, or predicate relaxation.

Build: `LEAN_NUM_THREADS=1 SANDBOXED_ALLOW_RAW_LAKE=1 lake build orb-node-spawn-cleanup-test`

Trace: PID 1144039, ticks 223039503, inherited PGID/SID 1143865.
TERM and KILL to -1144039 both returned -1, errno 3 (ESRCH).
Child subsequently completed setsid, PGID/SID 1144039.
Fixture: ledger failed with the expected error, phase 4, poll 0,
procMissing 0, isZombie 0, same start ticks. Actual executable exit **1**.
Post-observation cleanup is separate from the measured result.

This establishes the mechanism in a focused Node replay, not the historical
cycle13 PID, and does not establish the cause of cycle10. Reported cycle10
Node1 (unknown conjunct), cycle13 Node1 (dead0/0 only), isolated104/104 and
cycles11/12 Node0 remain historical evidence, not newly reproduced runs.

## Candidate handshake

Only the nonpiped spawn changes. An acknowledgment after successful setsid
precedes the parent return. Pipe endpoints are CLOEXEC and closed on all
paths. Timeout is 5000 ms; interruption fails rather than restarting it.
EOF, short status, and child setup failure propagate as IO errors. Failed
setup kills the unreaped direct child, never its inherited process group.
Runner identity gates and exec exit126/127 behavior are unchanged.

The final candidate reserves a detached reaper before fork. Failure kills the
unreaped direct child and transfers wait ownership to that worker; the caller
does not block on an uninterruptible child. On success the worker exits without
waiting, leaving Runner as the sole child-wait owner. Reservation failure occurs
before fork, so it cannot strand a child. EINTR handling in the reaper resumes
waitpid only; it does not retry spawn, readiness or termination.

## Candidate evidence

Ungated focused execution: exit **0**, PID1145899, dead1/0.
Deterministic gated execution released when the parent entered the readiness
wait: exit **0**, PID1146856, ticks223050712, setsid completed before both
signals; both returned0, phase4, poll614180323329, dead1/0.

C helper tests: success, setsid failure, EOF, injected timeout, injected EINTR,
short status: exit **0**, all assert direct-child reaping and stable FD count.
These timeout cases inject poll results; they do not measure elapsed timeout.
An additional real-deadline case subsequently blocked the child before ACK:
actual timeout 5.004 seconds, ETIMEDOUT, child reaped, stable FD count, exit0.
Successful handoff separately preserved exit0/126/127 and parent wait ownership.
Actual Runner failure propagation tests for fail/eof/timeout/eintr: each exit
**0**, failed ledger, pid0, live0, nonempty setup error.

Final reaper candidate: gated PID1168301 ticks223116322, signals bothrc0,
dead1/0, exit **0**. All four Runner setup-failure cases still exit **0**.
Reserved-reaper test receives an explicit waitpid completion pipe event for
each setup-failure mode and verifies ECHILD afterward; exit **0**, FD count
unchanged. Full binary and focused binary build: exit **0**, 111 jobs.
Main C shim 214 lines; readiness helper 111 lines; diagnostic/test C72/95 lines.
Final built full-suite binary SHA256:
`2e1f47e857ac2606008f7937adeb3ddbfb8552ce7eb9779307030c064597d807`.

Build bootstrap: repo script initially exited1 at turbo-lean's dynamic
extern_lib gate. Authorized raw-Lake fallback built the static artifact;
two foreground build attempts hit tool timeouts. Later complete Node build
exited **0** (108 jobs). Turbo-lean still rejects the custom dynamic target,
so subsequent sequential builds use the explicit authorized fallback.

Full non-root suite subsequently executed once under operator's revised
sequence: actual exit **1**, assertion "archive-backed lean_build queues while
saturated and redacts persisted data_base64", before SM-20. Retained fixture
`/tmp/orb-node-selftest-823394-1794864265/jobs.db` shows archive job ...993
already running with data_base64 empty; blocker jobs ...991/...992 failed with
`command exited with Some(143)`. The archive fixture commit exists. This
isolates a queued-state mismatch but does not establish its scheduling cause.
No assertion was relaxed and no full-suite rerun performed.

Operator clarified the 220-line condition is per file, approving the214/111
production files; aggregate325 is disclosed, not treated as a per-file limit.
Root run is assigned to dgx-spark via controller after Core builds are idle.
Root gate unavailable locally: mission uid995 has
no_new_privs; sudo refuses; ORB_SUDO_TOKEN absent; no privileged-request tool
or local Orb REST connection is provisioned. No production deployment.
