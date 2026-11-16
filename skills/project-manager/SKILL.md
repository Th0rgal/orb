---
name: project-manager
description: Manage project metadata, controller missions, and their mission-owned text boards.
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

A project is a label with one controller mission. The board belongs to that
controller mission, not to the project. Read metadata with `get_project` or
`list_projects` and the board with `read_mission_board`.

Start a mission with the controller flag to assign the controller, or use the
project controller-mission REST endpoint. Send requests through ordinary
mission messaging. Follow the user's authority and budget instructions.
Verify results before reporting completion and keep actionable evidence on
the board. Consult `docs/AGENT_CONTROL_PLANE.md` for the API contract.

## The mission board

`read_mission_board` takes an optional `mission_id` and defaults to your own
mission. `write_mission_board` takes `text`, an optional `mission_id` that must
equal your own mission, and an optional `idempotency_key` of 1 to 200
characters. The board is one replacement text: no append, patch, field merge
or per-row edit. Replace it with a concise plan, progress, evidence links,
blockers, and questions, within 16384 UTF-8 bytes.

A read returns `mission_id`, `text`, `updated_at`, `updated_by_mission_id` and
`text_sha256`. A mission that has never written a board reads as empty `text`
with null `updated_at` and null `updated_by_mission_id`. A write returns a
settled action receipt: `action_id`, `tool_name`, `state`, `status`,
`accepted`, `result` (the five read fields) and `target_mission_id`. Retrying
with the same `idempotency_key` replays that receipt and writes nothing.
Writing text equal to the stored text changes no column, so `updated_at` and
the writer keep their values.

Reads follow live mission ownership: the mission itself, its owner user, and
missions it started (lineage at any depth) read its board, and `operator` or
`coordinator` read within the same project. Every other caller gets
`not_found` (`mission_not_found`) with no text, length or hash; a same-tenant
denial is `forbidden`. Only the mission itself writes: a `mission_id` in
another tenant is `not_found`, and one inside your tenant that is not your
mission is `forbidden` with message `not_mission_writer`. A text larger than
16384 UTF-8 bytes is rejected whole with `board_too_large`.

`read_project_board` and `write_project_board` are older names that resolve
the project's controller mission and read or write that mission's board with
the same authorization, so a non-controller write answers
`not_project_controller`. The catalogue gives them no arguments for the read
and only `text` for the write; they take the project from the calling mission,
and a mission with no project answers `no_project`. Their read of a project
with a controller returns the mission-board fields; with no controller it
returns the legacy `text`, `updated_at`, `updated_by_mission_id` and
`controller_mission_id`. Prefer the mission tools.

Writes go through MCP only. `PUT /api/projects/:slug/board` answers
`403 {"error":"not_project_controller"}` for every caller that can see the
project, and `404 not_found` for a project the caller cannot see; `GET
/api/projects/:slug/board` still reads the alias. `PUT
/api/control/missions/:id/board` refuses every caller too:
`403 {"error":"not_mission_writer"}`, or `404 mission_not_found` outside the
mission's tenant.

Nominating a new controller copies no board: the successor starts empty while
the outgoing controller keeps its text. (The one exception is a project that
still holds unclaimed pre-migration text, which its first controller receives.)
Hand off by putting the full board text in the handoff message; the successor
writes it with `write_mission_board` and reads it back.

A move to another project updates the mission's placement and leaves its board
row untouched. The older names stay project-based: `read_project_board` and
`write_project_board` resolve `projects.controller_mission_id` of the project
the calling mission now belongs to, and a move never changes that column. So
after a move `read_project_board` reads whatever the new project names as its
controller — not your board, unless that project names your mission — and
answers `forbidden` or `not_found` when you may not read that mission. If the
new project has no controller, the read returns the project's legacy text and
`controller_mission_id: null`, which is empty text when the project never had a
board; the write answers `not_project_controller` unless that project names
your mission. The rule: after a move, read and write your own board with
`read_mission_board` and `write_mission_board` only.

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
