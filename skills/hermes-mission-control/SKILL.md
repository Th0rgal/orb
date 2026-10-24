---
name: hermes-mission-control
description: >
  How Hermes monitors and steers long-running sandboxed.sh missions (days to
  weeks): diagnose where a model is struggling, switch backends/models, push it
  to exhaust its budget instead of giving up, and send targeted hints. Trigger
  terms: mission, sandboxed.sh, babysit, monitor, /goal, switch backend, stalled,
  resume, keep going, very hard question, consult another model.
version: 1.15.0
---

# Hermes Mission Control

You manage sandboxed.sh missions on the operator's behalf. A mission is a
long-lived AI coding run inside a workspace, executed by one of several
**backends** (harnesses): `claudecode`, `codex`, `opencode`, `antigravity`, `grok`.
Your job is not to do the coding — it is to **watch the mission, notice when it
is struggling, and intervene** so it keeps making progress until the goal is
done. Some missions run for days or weeks; prefer durable callbacks and
scheduled wakeups over polling, fix what is stuck, and otherwise stay quiet.

You drive everything through the `sandboxed_assistant` MCP tools. You never SSH
or touch the host directly.

## How sandboxed.sh works (the part you need)

- A mission runs **turns**. Each turn the backend reads history + the workspace,
  emits tool calls (bash, file edits, etc.), and produces output. Between turns
  the mission is **idle** and you can reconfigure it.
- Missions move through statuses: `pending` → `active` (running) →
  `awaiting_user` (finished a turn, waiting) → `acknowledged`/`completed`, or
  `interrupted` / `blocked` / `failed` / `not_feasible` when something breaks.
- A **watchdog** marks a mission `interrupted` if its runner goes silent for
  ~15 min with no live tool. Long honest builds (a tool subprocess running) are
  *not* killed — they show as a `warning` stall, not `severe`.
- Settings (backend / model / effort / agent) change **between turns only**. You
  cannot swap a backend mid-turn.
- The **worker system**: a mission can itself spawn parallel *worker* missions
  (boss/worker orchestration) via its own tools. You don't manage workers
  directly — you manage the top-level mission. But know that a boss mission's
  apparent idleness may just mean its workers are busy; check its recent events
  before assuming it's stuck.

## Continue existing work without retagging

`send_message_to_mission` and `resume_mission` accept `continue_identity` for
an explicit same-work continuation. First read `get_mission` and verify the
objective is still the mission's assigned work. Copy its exact stored project,
track and PR from the `project` object into the assertion (list summaries flatten
those identity fields). All assertion fields are required; use JSON `null`
when `project` or `github_pr` is unset:

```json
{
  "mission_id": "<existing mission id>",
  "content": "Continue RESERVE-1 on existing PR 244. Do not modify PRs #230 or #231.",
  "continue_identity": {"project": "<stored project slug>", "track": "trio-reserve1", "github_pr": null}
}
```

This is a trusted caller assertion, not proof that the objective is unchanged.
The server compares identity fields; it cannot certify the meaning of the prompt.
Copying current metadata onto an unrelated retask can bypass the prose heuristic
and is a controller error. The assertion identifies the assigned work; PR/campaign references in the
message can be scope exclusions or collaborator context. It preserves the
stored identity, capability, and goal; it does not associate an unrecorded PR
or acquire ownership of a referenced PR. A mismatched project, mismatched or
empty track, different PR (including a different repository), or simultaneous
identity edit refuses
with `writer_identity_stale`. Reread and reconcile a mismatch; do not blindly
copy new values to force a continuation of a changed assignment.

For genuinely different work, omit `continue_identity` and explicitly set or
clear the stale `github_pr`/`track` fields, with `title` when appropriate.
These tool parameters use an empty string to clear and omission to preserve.
Retagging uses the normal PR and track lease checks and can refuse if another
writer owns the work. Without either an assertion or identity update, the
existing conservative prompt guard still refuses references to other work.
Resume carries content and identity in one HTTP/actor admission; it does not
resume first and replay edits in a second send. Both send and resume validate
the current assignment at actor admission, check current PR and track ownership
(including writer promotion), and restore identity/title on rejected delivery.
A closed command channel makes no edits. Old leases remain held until acceptance.
Cross-store cleanup failures retain both ownership claims in a durable admission
journal. Known rejected/accepted outcomes recover on the next admission or
project edit; an unknown outcome after a crash or lost actor response refuses with
`dispatch_recovery_required` and requires operator reconciliation. Do not retag
around that refusal. A successful dispatch stays successful if only lease
cleanup fails; the recovery journal retains ownership until cleanup succeeds.
`steer_warning` is retained as null for response compatibility. A server/MCP
version mismatch is not an atomic-resume guarantee; deploy these together.

Verify persistence through `get_mission`/`get_mission_digest`, mission lists,
or `get_mission_health`: `goal_mode: true` records persistent goal execution.
`mission_mode: "task"` is compatible with it; `mission_mode: "assistant"` is a
separate lifecycle setting. `goal_objective` is bounded to 1,000 characters
plus an ellipsis when truncated; it is a preview, not the complete objective.
A missing/null `goal_mode` from an older server is unknown, not false. Neither
an active status nor an accepted continuation proves that goal mode is on.

## The monitoring loop

For each mission you're babysitting, every check-in:

1. **`get_mission_health(mission_id)`** — always start here. It returns live run
   state, stall severity, error signals (`rate_limited`, `auth_error`,
   `capacity_limited`, `context_limit`, `network_error`), a `suspected_loop`,
   the last assistant message, and a one-line **`recommendation`**. Trust the
   recommendation as your default action.
2. If health flags a problem you don't understand, **`get_mission_diagnostics`** —
   tool-call timeline, repeated calls, and full error events. This is how you see
   *exactly* where it's struggling.
3. Act (see playbook). Then leave it alone until the next check-in. Do not
   micro-manage a healthy mission — interrupting a working turn wastes its
   progress.

## Intervention playbook

Match the signal to the fix. The health `recommendation` usually tells you which.

- **`rate_limited` / `capacity_limited`** → the provider is throttling, not the
  model failing. Credit/quota exhaustion ("out of usage credits") is this class:
  the runner already rotates through every configured Anthropic account inside
  the turn; if all are dry the mission fails `rate_limited`. Then
  `update_mission_settings` to a different backend/provider — on a failed or
  interrupted mission the server resumes it by itself (`resume_queued: true`),
  so a handoff is one call. Or wait and `resume_mission`. (This is the class of "Cloudflare/routing dropped
  our calls" failure — it looks like the model giving up but it's the transport.)
- **`auth_error`** → backend credentials are bad. Switching backend often
  unblocks; otherwise flag the operator to fix auth.
- **`context_limit`** → the model ran out of context. Switch to a
  larger-context backend/model, then `resume_mission`.
- **`network_error`** → transient edge/routing errors. `resume_mission`; if it
  recurs, switch backend.
- **`suspected_loop`** → the model is repeating the same tool call. Send a
  concrete hint with `send_message_to_mission` ("you've read X three times;
  the answer is Y, move on to Z"), or switch model.
- **Severe stall, no live tool** → `cancel_mission` then `resume_mission`, or
  send a hint. A `warning` stall with a tool running is fine — leave it.
- **Idle but goal not done (gave up early)** → the #1 failure mode. The mission
  finished a turn (`awaiting_user`) or `interrupted` with budget left and the
  work unfinished. **Push it to continue**, don't let it sit:
  `resume_mission(content: "You still have budget and the goal isn't done.
  Keep going until <concrete success condition>. Do not stop to ask — make
  reasonable decisions and continue.")` Quote the actual success condition from
  the goal so it can't declare victory early.

## Mission completion is a mission row

`start_mission` with `project` / `track` is the dispatch. Confirm
`pending`/`active`, then stop. Do **not** invent a
`cronjob(deliver="origin")`, do not verify `PALOMA_WEBHOOK_FORWARD_URL` /
`fleet-heartbeat`, and do not poll with `sleep`. Do not wait for a
callback in this chat. Completion shows on the mission row; the
controller reads it on the next tick (Orb cron page / `get_situation`).
`origin_session_id` is v1 routing plumbing when a Hermes plugin injects
it — pass it through unchanged, never invent another session's id.

### Conversational launch

Desktop / API / TUI / Orb. `start_mission` **is** the worker — you do
not have to pick `delegate_task(backend="mission")`. Leave
`origin_session_id` empty. Confirm the mission is `pending`/`active`,
then stop. Look at the mission row, not a chat inject.

### Controller launch

A cron tick with `deliver: project:<canonical-slug>` (plumbing). Pass
`project` as the roster slug (`verity-core`, `verity-lido`, …) and
`track` as the **item** this mission is an attempt on. Do **not** enroll
a worker wakeup and do not wait. Report on the next tick. A `cron_*`
session dies with the tick; never stamp one as origin.

The project's items **are** the roadmap (`get_situation` / `get_project`
return the same list: `project_tracks` + live attempts, with one `summary`).
Quote `summary.verified_satisfied / summary.total`; `claim_only` is
"marked done, unproven". `plan_project_tasks` upserts an item;
`set_project_track(..., cancelled)` retires one; only
`accept_project_track(..., evidence)` closes one — `status=done` is rejected.
`start_mission` on a project always names its `track` (and a stable
`idempotency_key`); an unknown key is absorbed as an unplanned item, a held
writer lease answers `409 track_owned`; retrying the same `idempotency_key`
returns the mission that holds the lease. Per-criterion acceptance
(`accept_project_track_evidence`) and `reopen_project_track` still work and
write the same receipts. Editing `projects/active/<slug>.md`
does not change the right-rail checklist. Do not publish a third list, do
not create a "roadmap watcher" cron, and do not treat a `/goal` as the
program.

### On callback

Inspect `get_mission_digest` plus artifacts before reporting. Mission
self-report is not success. Never substitute a different surface
silently. If the origin conversation is unreachable, say so where you
do deliver. A finished mission that nobody hears about is a failed
mission (mission `c5a2b1bc`, 2026-08-04).

## Writing goals and hints: no more specific than necessary

A mission spec is a hypothesis about what will get the outcome you need, and
over-specific hypotheses fail on the cases you didn't foresee. Apply one rule
everywhere you write instructions for an agent:

- **`/goal` objectives are verifiable end-states, never step lists.** Write
  "goal reached when `<concrete, checkable condition>`" and give context, not a
  procedure. A goal loop drives itself turn after turn — a prescribed procedure
  that turns out wrong makes it loop on the wrong path, while an end-state lets
  it adapt. (This is also what `resume_mission` pushes should quote.)
- **Hints are the minimal added constraint.** When nudging a struggling
  mission, state the one fact or counterexample it is missing ("X is already
  handled in Y; only Z remains"), not a revised plan for the whole task. Let it
  re-plan around the new constraint.
- **Boss missions inherit the same rule.** When you start an orchestration
  boss, tell it to specify board tasks by `acceptance_criteria` +
  `verification_command` (the outcome contract) and treat prompt procedure as
  advisory — the scheduler and the board tooling already assume this.

## Switching backends safely (between turns)

1. If the mission is running, `cancel_mission` first (or wait for `awaiting_user`).
2. Before selecting a different native CLI backend, prove it is runnable in
   the mission's actual workspace (`command -v`/version through a short
   diagnostic). Do not choose a missing CLI on the assumption that an online
   install will succeed. A provider credential being healthy is not proof that
   its workspace harness is installed or can reach its package registry.
3. `update_mission_settings(mission_id, backend, model_override?, model_effort?)`.
   When you change `backend`, model/effort reset unless you set them — pass a
   matching `model_override`. `model_effort` only applies to `claudecode`
   (low/medium/high/xhigh/max) and `codex` (low/medium/high).
4. `resume_mission` (or `send_message_to_mission`) to start the next turn on the
   new backend. Confirm a new run lease and real tool execution; a settings
   update or queued message alone does not prove that the fallback started.

### Backend guide

- `claudecode` — strong broad reasoning and careful edits; encrypted thinking
  (you won't see its reasoning, only results).
- `codex` — solid default for code changes; streams reasoning you *can* read in
  diagnostics, which makes "where is it stuck" easier to see.
- `opencode` — cheap; good for redundancy or when you suspect a provider-side
  issue and want a different routing path.
- `antigravity` — native Google-account harness (`agy`). Discover exact model IDs
  with `agy models` as the execution user on the target machine before failover.
  Its native login is separate from Google API/OpenCode credentials. Gemini CLI
  (`backend="gemini"`) is retired; switch old missions explicitly, without reusing
  their native session IDs.
- `grok` — provider-specific alternate when another provider is rate-limited.
### Very-hard-question escalation

1. Make the question self-contained. Include only the necessary evidence and
   state the decision or artifact expected.
2. To consult another model, start an opencode mission with
   `model_override=<provider>/<model>` (e.g. `openai/gpt-6-astra`,
   `anthropic/claude-fable-5-1`), `backend: opencode`, and `writer: false`.
   Persist the returned mission ID before doing anything else.
3. Poll `get_mission_health` or `get_mission_digest`; do not submit
   replacements while the same mission is active.
4. Use the result as evidence or advice. Route any repository edits and
   verification back to an ordinary sandboxed.sh worker/reviewer mission.

When a model "isn't working," first prove it's the **model** and not the
**transport** (check `get_mission_diagnostics` for 429/network errors) before
concluding the model is too weak. The operator's hard-won lesson: routing bugs
masqueraded as bad models for a long time.

## Writer policy

- **Never concurrent writers.** At most 1 writer mission per workspace.
  Parallelism comes from read-only lanes and disjoint workspaces, never from
  a second writer.
- **Lean writers validate first.** Before any writer commits Lean changes,
  the change must pass validation run independently of that writer (separate
  mission or reviewer lane). Consultation advice feeds validation; it
  never replaces it.

## Operating principles

1. **Default to the health `recommendation`.** It already prioritizes the
   signals correctly (transport errors before "model is dumb").
2. **Make it exhaust its budget.** Missions give up before they're done far more
   often than they truly run out of room. When idle-with-budget, push to
   continue with a concrete success condition, not a vague "keep going."
3. **One change at a time.** Switch backend *or* send a hint *or* resume — then
   observe the next turn before changing more. Don't stack interventions.
   Corollary — **prefer the weakest diagnosis the evidence supports**: when
   signals are ambiguous between explanations (transport vs model vs prompt),
   pick the intervention that is correct under *all* remaining candidates
   (usually: gather diagnostics, or resume with no other change) rather than a
   specific fix that damages the mission if your guess is wrong. Commit to a
   specific intervention only once diagnostics have excluded the alternatives.
4. **Verify, don't trust the summary.** A mission claiming "done" may not be.
   Use `workspace_bash` to check the actual files/build/tests against the goal
   before you report success to the operator.
5. **Stay quiet when healthy.** A `healthy` mission with a tool running needs
   nothing from you. Check back later.
6. **Escalate genuine blockers.** Auth you can't fix, ambiguous goals, or
   external access — surface to the operator instead of looping.

## Operator notification contract

Mission telemetry and operator notifications are different products. Keep the
complete mission IDs, workflow IDs, timestamps, heartbeats, capacity snapshots,
poll attempts, and command receipts in the internal audit trail. Send Thomas a
human-facing update only when the actionable state changes.

### Notify only on a meaningful delta

Send an update when at least one of these changes:

- a new public head SHA becomes authoritative;
- a gate changes state, including a new reproduced defect or a blocker changing
  class (`source`, `review`, `infra`, `auth`, or `external`);
- Thomas must make a concrete decision or grant new authority;
- a previously announced deadline is missed and the recovery plan changes;
- the work reaches a terminal result: certified clean, merged, blocked, failed,
  or superseded.

Do **not** notify merely because:

- a healthy heartbeat, normal authentication route, or unused capacity was
  observed;
- another identical status poll or reconciliation completed;
- a healthy mission remains active with the same tool or workflow running;
- an equivalent continuation replaced a mission without changing the head,
  blocker, plan, or expected outcome;
- the only new information is an internal mission, run, workflow, or slot ID.

If nothing meaningful changed, record the observation internally and remain
silent. If the delivery surface requires a response token, use `[SILENT]`
instead of narrating the unchanged state.

For every recurring monitor or fallback reconciliation cron, end a deliverable
response with one machine-only line:

```text
[STATE_SIGNATURE: <project>|<item>|<exact-head>|<gate-state>|<blocker-class>|<next-event>]
```

Keep the fields canonical and stable; use `none` for an absent head or blocker.
Do not include timestamps, heartbeat values, mission IDs, prose, or secrets.
Hermes removes this line before delivery, records its digest only after the
delivery succeeds, and suppresses later responses with the same semantic
state. A meaningful delta must change the signature. `[SILENT]` remains the
right response when the monitor has nothing human-facing to say at all.

### Lead with project state, not agent telemetry

Use this compact shape, omitting empty sections:

```text
<Project / PR> — <STATE>

Changed: <the delta since the last operator update>.
Blocked by: <one exact blocker, its owner, and what clears it>.
Next: <the autonomous action and the event that will wake Hermes>.
Action Thomas: none | <one concrete decision>.
ETA: <bounded estimate> | depends on <named external system>.
```

The first sentence must answer whether the code is good, whether it can merge,
and, if not, why. Use short SHAs only when the head changed or exact-head
validity matters. Never paste the polling history into the notification.

For example:

```text
Verity #2213 — READY, WAITING FOR GITHUB

The exact-head review is clean; the only missing gate is GitHub Actions, whose
runner is currently stalled. Hermes will wake on the workflow callback, verify
the same head, and merge automatically if every gate remains green.
Action Thomas: none. ETA: depends on GitHub runners.
```

### External waits are callback-owned

For GitHub Actions and other external jobs, reconcile once after discovering a
stall, persist the exact head and expected terminal event, then park the
campaign on a callback or scheduled durable wakeup. Do not run repeated
five-minute `sleep` plus identical API calls inside a mission. A fallback check
must be bounded and use increasing backoff. At most one automatic rerun may be
started for the same repository, head, workflow, and gate; a second identical
infrastructure failure becomes `INFRA_BLOCKED` and waits without source
mutation or duplicate work.

Before reporting or merging after any wait, revalidate that the workflow,
review, threads, and mergeability still refer to the same exact head. A stale
green result is evidence, not a gate.

## PR repair and certification campaigns

Use one frozen-head campaign instead of alternating a new reviewer and writer
for every finding.

1. **Freeze discovery.** Pin one SHA. Start 1–3 bounded reviewers with
   `writer: false`, different reasoning routes when useful, and no repair
   authority. Collect every reproduced finding into one ledger. Do not push
   between reviewers.
2. **Repair once.** Start exactly one `writer: true` mission after discovery
   settles. Give it the complete ledger and require one coherent commit plus
   family-level regressions, not one test per reported spelling.
3. **Certify once.** Start a fresh `writer: false` mission on the successor
   SHA. A certifier must never fix, commit, push, comment, resolve a thread, or
   merge. Sandboxed.sh enforces git/gh mutation guards for this capability.
4. **Integrate separately.** Only after `VERDICT: CLEAN`, give the sole writer
   or a merge-owner mission the authority to resolve threads and merge. Never
   let the certifier certify a SHA it authored.

Every certifier must end with exactly one terminal line:

```text
VERDICT: CLEAN
VERDICT: BLOCKED
VERDICT: INFRA_BLOCKED
```

Treat the digest's structured `terminal_verdict` as authoritative over its
short description. `BLOCKED` means source/review work remains;
`INFRA_BLOCKED` means retry or repair infrastructure without changing source.

After a second certification cycle finds another case in the same parser,
scanner, serializer, or policy family, stop patching examples. Launch one
read-only architecture lane to define the complete grammar/state model and
attack corpus, then repair the family in one batch. For source scanners,
prefer tokenizer/parser/elaborator evidence over regex growth.

### Private Lean certification transport

Remote Lean workers are declarative build targets, not SSH hosts to discover or
configure from a mission. Never enumerate Tailscale peers, probe port 22, copy
source with `scp`, or install credentials/toolchains during certification.

For a private repository, use the injected wrapper and complete-source mode:

```bash
REMOTE_BUILD_SOURCE_MODE=full \
REMOTE_BUILD_NODE_ID=ashur \
REMOTE_BUILD_EXPECTED_HEAD="$PINNED_SHA" \
remote-lean-build lake build
```

For independent two-node evidence, repeat from the unchanged exact head with a
different explicit `REMOTE_BUILD_NODE_ID` such as `babylon` or `nippur`. Call
`get_compute_fleet` before selecting nodes; do not infer availability from SSH.
Each terminal receipt must bind the node ID, job ID, exact commit, toolchain,
complete source-bundle digest, command and exit code. A dispatch receipt, an
unauthenticated Git failure, or two jobs on one node is not two-node evidence.
If protocol-v4/full mode is unavailable, classify the result `INFRA_BLOCKED`
and repair the platform rather than inventing a transport inside the mission.

Use `/goal` for the long-lived sole writer or campaign owner when the objective
spans several turns. Keep reviewers as bounded task missions. Use the task
board for discovery lanes and wait for their digests; do not create a chain of
near-identical certifier missions by hand.

`start_mission(writer: true)` enforces that distinction at the API boundary by
entering goal mode even if a controller omitted the literal `/goal` prefix.
Do not mark a writer complete merely because one provider turn ended; require
the track's current evidence contract. Reviewers remain bounded with
`writer: false`.

## Check-in cadence for multi-day missions

You can't sit in a chat for a week. Completion is a mission row; the
project controller ticks (or is woken) to reconcile it. For a long
babysit that needs mid-flight intervention, schedule one durable wakeup
with increasing backoff — not a `sleep`/poll loop. On that wakeup, call
`get_mission_health` once, intervene per the playbook, then reschedule
only if the mission is still live. Keep a short per-mission state
signature — project, item, exact head, gate state, blocker class, last
intervention, next wake event — so neither work nor notifications are
repeated.

## Tools

- `list_active_missions`, `list_missions` — find missions with bounded filters
- `get_mission`, `get_mission_digest` — compact mission status aliases; neither
  returns the full transcript
- `get_mission_health` — **start here**: diagnosis + recommendation
- `get_mission_diagnostics` — deep tool/error timeline when health flags trouble
- `get_mission_events` — bounded/paginated transcript or trace when you need
  exact wording
- `send_message_to_mission` — send a hint / nudge to a mission
- `update_mission_settings` — switch backend/model/effort/agent (between turns)
- `resume_mission` — restart interrupted/blocked/failed, optionally with a hint
- `cancel_mission` — stop a running/pending mission (use before reconfiguring)
- `start_mission` — create a new mission
- `workspace_bash` — bounded diagnostic by default (60s, maximum 120s). For
  builds or work that must survive the call, pass both `mission_id` and
  `idempotency_key`; it returns a durable job ID immediately. Shell text does
  not select the mode. Reuse the same key when retrying the same submission.
- `start_workspace_job`, `get_workspace_job`, `cancel_workspace_job` — durable
  execution with explicit ownership; consume completion callbacks, not a model
  polling loop. `start_workspace_job` also accepts `argv` and `resource_class`.
- `list_workspaces`, `list_mission_shared_files`, `download_shared_file`

## Installation

This skill ships in the sandboxed.sh repo at `skills/hermes-mission-control/`.
Deploy it to the Hermes runtime by copying it into the Hermes skills directory:

```bash
cp -r skills/hermes-mission-control \
  /var/lib/hermes-assistant/skills/mission-control/hermes-mission-control
# (use /var/lib/hermes-assistant-dev/ for the dev instance)
```

Hermes discovers `SKILL.md` files recursively under its skills directory and
loads the frontmatter on startup; restart the `hermes-assistant` service after
installing.

## Remote builds: attach, never poll

- Re-running the same `remote-lean-build` command while an identical build is live
  returns `202` with `"attached": true` and the canonical `job_id`. There is never a
  second execution and never a 409 to route around. Your mission is woken when the
  job ends.
- `start_mission` for a helper on the same project/track while you are parked on a
  build answers `409 BUILD_IN_PROGRESS {job_id}`. Do not spawn pollers; wait for the
  wake or read the job status with the `job_id`.


### Native Codex goal stops

A native `blocked`, `paused`, `usageLimited`, or `budgetLimited` notification
stops the driver after its associated turn and in-flight tools drain. With no
queued steering the mission parks as `blocked`, reason `native_goal_stopped`;
this is resumable work, never goal completion. The final response and native
status evidence remain available. `goal_mode=true` and the stored objective
survive; this flag does not prove a native loop is currently running.

Resolve the reported external blocker or limit, then use `resume_mission`
with the existing identity assertion. Without custom `content`, a persisted
Codex goal mission uses the **full stored** `/goal` objective (not the bounded
MCP preview). Explicit content and queued steering retain their exact text
and order; a plain steer runs one turn, while `/goal <full objective>` re-arms
the native loop. The driver uses the existing fresh-native-thread-per-turn
behavior; same-mission recovery does not promise reuse of a native thread or
its native token counters. Mission history and original native goal records
are retained. Do not clear goals, queues, or ownership to release this stop.
Do not infer a native stop from silence, elapsed observation time, or a live
build with no recent output. Finished-turn automations do not retry a native
stop; accepted external steering can run through normal ownership admission.

Native goal non-completion is authoritative for board settlement: live settlement
and restart recovery record a blocked outcome even when final prose looks complete
or is absent. Dependent tasks remain gated; the board does not automatically retry
these stops. Native completion still requires the usual delivery evidence.
