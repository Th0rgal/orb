---
name: project-manager
description: Manage project metadata, controller missions, and text boards.
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

Gemini CLI (`backend="gemini"`) is retired. Use `backend="antigravity"` with
an exact model from `agy models` on the execution machine. Existing Gemini CLI
missions must be explicitly switched before resuming; do not reuse their native
session IDs or treat Google/OpenCode OAuth as an Antigravity login.
