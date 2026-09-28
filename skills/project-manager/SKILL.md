---
name: project-manager
description: Steer sandboxed.sh projects, roadmaps, decisions from chat.
version: 2.0.0
author: thomas
license: MIT
platforms: [linux, macos, windows]
prerequisites:
  tools: [mcp]
metadata:
  hermes:
    tags: [Projects, Roadmap, Orchestration, Autonomy]
---

# Project Manager — projects, roadmaps, decisions

To withdraw work still queued, call `cancel_action(action_id, idempotency_key)`.
Read its receipt: `cancelled=false` means dispatch already started or settled;
use the existing mission/job cancellation tool after inspecting the target.
Cancelling an MCP request or closing stdio does not cancel accepted work.

## When to Use

When the owner asks about their projects ("how is X going?", "what's on the
roadmap?", "what needs me?"), wants roadmap items added/edited/cancelled from
conversation, answers an escalated decision, or asks to change a project's
autonomy grant. Requires the `sandboxed_assistant` MCP server.

Use the `sandboxed_assistant` MCP tool family to talk about the owner's
projects with real data, never from memory. Every project is identified by its
`slug`.

The server runs `sandboxed-mcp` with a scoped coordinator credential. Read
`get_capabilities` if a tool is unavailable; only an operator session can
change autonomy grants or infrastructure. Do not bypass the boundary with
an owner token or a direct API call.

Every mutation requires an `idempotency_key` and returns an action receipt.
Keep the same key and arguments after a lost response. Read `get_action`
until it settles before reporting the change as applied. An action marked
`reconciliation_required` has an uncertain outcome: inspect existing state,
do not repeat it under a new key. A completed launch action means its mission
was created, not that the mission finished or its evidence was accepted.

## Reading state (do this before opining)

1. `list_projects` — the roster with buckets (attention/active/paused) and
   health. Start here when the owner asks "how are my projects doing?".
2. `get_project <slug>` — objective, status/mode, blocker, next action, grant,
   open decisions, recent decisions (the decision ledger), tracks.
3. `get_project_tasks <slug>` — the roadmap: board tasks planned by the
   project's boss missions plus chat-planned proposals (`status: "proposed"`),
   with result digests, PR links and attempts. Use `get_situation <slug>` for
   authoritative verified progress; a completion claim is not verified evidence.

When summarizing, lead with what needs the owner (open decisions, blockers,
failed tasks), then progress (summary done/total), then what is running.

## Shaping the roadmap from conversation

- `plan_project_tasks` — add items. Keys are stable kebab-case, unique per
  project (`task_key`). A proposal is a *plan*, not dispatched work: the
  project's controller adopts it by planning a real board task under the same
  key, at which point the proposal drops out automatically.
- `update_project_task` — edit an open proposal (title, prompt, acceptance
  criteria, dependencies). Board tasks already adopted belong to their boss
  mission — steer the mission instead.
- `cancel_project_task` — remove an open proposal.

Prefer small, verifiable items with acceptance criteria over vague epics.
Re-planning an existing key updates it in place (idempotent), and revives it
if it was cancelled.

## Decisions and autonomy

- `answer_project_decision` — resolve a pending escalation with the owner's
  verdict (only when the owner has actually decided in the conversation).
- `record_project_decision` — declare an act or escalate a question yourself
  when you are operating as the project's controller.
- `get_project_grant` / `set_project_grant` — the autonomy grant: level
  (observe/propose/act_reversible/act_full), merge authority
  (`full | repo:a,b | review-first`), budget per tick, parallel missions.
  Change it only on the owner's explicit request through an operator session.
  A coordinator may read the grant but cannot broaden it.

## Cross-project etiquette

Unscoped coordinator sessions can read the project roster. Project-scoped
sessions can access only their bound project. When the conversation is about
one project, do not mutate another one's state without naming it and getting
the owner's confirmation first. Reads are always fine.


Workspace Git operations (`create_worktree`, `remove_worktree`, `merge_branch`)
require a coordinator/operator session, an explicit `mission_id`, and an
idempotency key. Core routes them to that mission's current machine. Paths
stay inside the mission root; use `repo_path` for a nested checkout. Removal
preserves dirty worktrees. Merge requires a clean checkout already on the
target branch; inspect conflict/abort evidence before assigning a resolver.
Core task-board worktree planning uses the same workspace executor. Task-board
scheduling for node/client bosses and desktop-owned workspace operations remain
unavailable until their execution routing is migrated. Never substitute a Core path.

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
