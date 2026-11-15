---
name: controllers-policy
description: "Autonomy contract and routing index for autonomous project controllers. Uses a controller mission and text board."
license: MIT
metadata:
  hermes:
    version: "2.0.0"
    author: Paloma
    platforms: [linux]
    tags: [controllers, autonomy, policy, fleet]
---

# Project controller

A project is a label with one controller mission and one text board.
Read metadata with `get_project` or `list_projects` and context with
`read_project_board`. Only the current controller mission can call
`write_project_board`; replace the text with a concise plan, progress,
evidence links, blockers, and questions. Keep it within 16384 UTF-8 bytes.

Start a mission with the controller flag to assign the controller, or use the
project controller-mission REST endpoint. Send requests through ordinary
mission messaging. Follow the user's authority and budget instructions.
Verify results before reporting completion and keep actionable evidence on
the board. Consult `docs/AGENT_CONTROL_PLANE.md` for the API contract.

## Remote builds: attach, never poll

- Re-running the same `remote-lean-build` command while an identical build is live
  returns `202` with `"attached": true` and the canonical `job_id`. There is never a
  second execution and never a 409 to route around. Your mission is woken when the
  job ends.
- `start_mission` for a helper on the same project/track while you are parked on a
  build answers `409 BUILD_IN_PROGRESS {job_id}`. Do not spawn pollers; wait for the
  wake or read the job status with the `job_id`.

### Hosted cloud attempts (Orb)

Discover `list_cloud_accounts` before selecting a cloud service. `start_mission`
accepts `cloud: {provider, account, repository?, git_ref?, model?}` and a stable
`idempotency_key`. Providers are `grok_bot` and `cursor_cloud`; there is no
Codex Cloud. Never put credentials or local folder paths in the cloud selection.
Use `get_cloud_execution` for durable provider state and results. A response
finishing does not establish that the project objective is complete. `submission_uncertain` requires reconciliation,
not another launch. Follow-ups use `send_message_to_mission` with a stable UUID
`client_message_id`. Availability and cancellation are capability-gated. This
initial implementation refuses track/writer admission rather than bypassing its
leases; keep such attempts on the existing executor until supported.

### Cloud model selection and verified Grok Bot

Use `list_cloud_models` with `provider: cursor_cloud` before selecting a model. Creation accepts `cloud.model` and Cursor `cloud.model_params: [{id,value}]`. Follow-ups accept `cloud_model` and `cloud_model_params` in `send_message_to_mission`; these settings belong to that turn, not earlier turns. Keep the same `client_message_id` on retries, including the same model parameters. Grok Bot has no model selector or attachment capability. Its dedicated Bots share the account computer: archiving an Orb mission must not delete provider files. Never replace an uncertain submission with a new mission.


Workspace Git operations (`create_worktree`, `remove_worktree`, `merge_branch`)
require a coordinator/operator session, an explicit `mission_id`, and an
idempotency key. Core routes them to that mission's current machine. Paths
stay inside the mission root; use `repo_path` for a nested checkout. Removal
preserves dirty worktrees. Merge requires a clean checkout already on the
target branch; inspect conflict/abort evidence before assigning a resolver.
An operator may settle an uncertain action with `reconcile_action`, using the
original mission/project scope and concrete evidence from the target. It never
replays the action. Do not mark it rejected unless absence of effects is verified.

Workspace jobs follow the mission placement on Core or a node. A remote job
receipt includes `remote.node_id` and `spawn_accepted`; `unknown` after a lost
response requires inspecting the existing job ID, never a new submission key.
Node logs combine stdout/stderr. Cancellation is complete only when the node
reports a terminal state. Unsettled jobs prevent moving the workspace.

### Reading cloud results economically

`get_cloud_execution` returns the latest turn by default, omits prompts, and caps each
result/detail excerpt at 4096 Unicode characters. Use `offset=0` for history.
Follow `page.next_offset` with
`offset` to read new turns; poll the unfinished turn again until it is terminal.
For a longer result, use that turn's `offset`, `limit=1`, and the field's
`text_slices.result.next_offset` as `text_offset`. Request `include_prompt=true`
only when needed. Artifact and branch payloads are omitted; counts remain.
Do not interpret a page or excerpt boundary as provider completion.

`cancel_mission` acknowledges a cancellation request, not a stopped process.
After its action completes, follow the result's `next_tool`: use
`get_cloud_execution` for provider confirmation or `get_mission_health` for
native runner termination. Do not report cancellation complete solely because
the action is completed or `cancel_requested` is true.

Discover supported models with `list_cloud_models`; preserve model parameters on retries.
Cloud attempts reject track leases, writer grants and scheduled admission.

Gemini CLI (`backend="gemini"`) is retired. Use `backend="antigravity"` with
an exact model from `agy models` on the execution machine. Existing Gemini CLI
missions must be explicitly switched before resuming; do not reuse their native
session IDs or treat Google/OpenCode OAuth as an Antigravity login.

Read `get_project_grant` for existing authority and budget. Only operator sessions
may change it with `set_project_grant` on the owner's explicit instructions.
One live writer per branch; preserve operator-relaunched missions. Answer
mission questions with `answer_mission_question` or escalate with evidence.
