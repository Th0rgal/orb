# Antigravity recovery

A remote node process may exit zero while Antigravity's final result reports a
stream interruption or HTTP 503. The native result, not the process exit code,
decides whether the turn finished. An intentional pause remains a pause. Recoverable native result errors no longer
trigger immediate process cancellation while the CLI may still retry. A later
SUCCESS clears the previous attempt's error. Authentication/identity failures
and the no-progress startup timeout retain their cancellation safeguards.

A response exceeding the provider output-token limit uses the same bounded
recovery path, with an instruction to keep responses short, move large output to
workspace files, and avoid duplicating running tasks. This cannot increase or
eliminate the provider's response-length limit.

Core owns recovery, including when Orb is closed. It keeps the native conversation
and remote placement, waits for the old job to terminate, then uses the existing
fenced continuation path. The prompt asks the agent to inspect existing work and
background tasks before proceeding; it does not resubmit the original task.
This preserves conversational state, but cannot guarantee exactly-once execution
of arbitrary external tools: the agent must reconcile their results before retrying.

Transient failures wait 1, 2, 4, 8, then 10 minutes, plus up to 20% deterministic
jitter. After twelve consecutive recoveries, operator intervention is required.
A run with over 1,000 output tokens and at least ten minutes of execution resets
that budget. A single large response does not reset it. Repeated observations of
the same terminal job preserve the existing deadline and counter.

Explicit authentication failures and operator stops do not enter this loop.
Recognized usage limits retain their separate reset-time scheduling policy.
The persisted remote wait ledger survives Core restarts. Stop or manual Resume
invalidates the scheduled wait through the existing mission status/lease checks.

The mission detail/list `recovery` projection reports kind, reason, resume time,
and attempt budget only while the mission is actually waiting. Orb displays
`Recovery scheduled`, the local resume time, `Resume now`, and `Cancel recovery`.
Automatic recovery prompts appear in collapsed disclosures rather than user
message bubbles; old quota-prefixed recovery prompts use the same presentation.

Verification: `cargo test -j 1 --lib usage_limit_wait`, Orb launch/transcript/Inbox
unit tests, `pnpm build`, and `tests/recovery.browser.spec.ts` in Chromium and
WebKit. The executable presentation fixture is `tests/recovery.html`.

## Incident evidence (2026-10-09)

- `85cce150-8b72-4a5f-be57-61aea8043104` on `old-agent`: native
  stream interruptions and `UNAVAILABLE (503)` appeared alongside intentional
  pauses. Earlier automatic resumes were already present, but were presented
  as quota recovery and could reset their backoff after a single large response.
- `3d921fb4-c533-4b37-8a8b-ab9dc0dc3c3b` on `ashur`, job
  `5bbb0be9-e528-4cef-ab77-1bcde1f8bd59`: the native result reported
  `Your previous response was cut off because it exceeded the output token limit`
  and `Retries remaining: 3`; the node receipt was `cancelled`. The old observer
  cancelled on any Antigravity result error, including this recoverable case.

These are distinct from operator cancellation and from exhausted subscription
allowances. The provider may still truncate a response; recovery must not turn
that event into permanent failure or restart work that is already running.
