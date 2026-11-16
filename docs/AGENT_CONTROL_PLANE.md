# Projects and controller missions

A project is a label and one controller mission. It retains title, objective,
status, color, skills, files, and appearance. Missions use the project label to
share context and organize work.

Start a mission with the controller flag to nominate it as the project controller.
Core records `projects.controller_mission_id`.
Use `GET /api/projects/:slug/controller-mission` to read that assignment and
`PUT /api/projects/:slug/controller-mission` to replace it.

The board belongs to the controller mission, not to the project: one text per
mission, keyed by `mission_id`. The controlling tool is
`read_mission_board` / `write_mission_board`.

- `read_mission_board` takes an optional `mission_id` and defaults to the
  caller's own mission. It returns `mission_id`, `text`, `updated_at`,
  `updated_by_mission_id` and `text_sha256`. A mission with no board row reads
  as empty `text` with null `updated_at` and null `updated_by_mission_id`.
- `write_mission_board` takes `text`, an optional `mission_id` that must equal
  the caller's mission, and an optional `idempotency_key` (1 to 200
  characters). It replaces the whole text; there is no append, patch, field
  merge or per-row edit. It returns a settled action receipt inside the usual
  `{ok, result}` envelope: `action_id`, `tool_name`, `state` (`succeeded`),
  `status` (`completed`), `accepted`, `result` (the five read fields) and
  `target_mission_id`. A retry with the same `idempotency_key` replays that
  receipt and writes nothing, and rewriting identical text changes no column.
- The text limit is 16384 UTF-8 bytes. A larger text is rejected whole with
  `board_too_large` and truncates nothing.

Reads follow live mission ownership: the mission itself, its owner user, and
missions it started (lineage at any depth) read its board, and an `operator` or
`coordinator` reads within the same project. Any other caller gets
`not_found` (`mission_not_found`) with no text, length or hash; a same-tenant
denial is `forbidden`. `GET /api/control/missions/:id/board` maps those to
`404 mission_not_found` and `403 forbidden` with the same fields. Only the
mission itself writes: a `mission_id` in another tenant is `not_found`, and one
inside your tenant that is not your mission is `forbidden` with message
`not_mission_writer`.

The older names `read_project_board` and `write_project_board` are aliases: they
resolve the project's `controller_mission_id` and read or write that mission's
board with the same authorization, so a non-controller write answers
`not_project_controller`; the catalogue gives them no read arguments and only
`text` for the write, taking the project from the calling mission. With a
controller their read returns the mission-board fields; with none it returns
the legacy `text`, `updated_at`, `updated_by_mission_id` and
`controller_mission_id`.

Writing goes through MCP only. `PUT /api/projects/:slug/board` answers
`403 {"error":"not_project_controller"}` for every caller that can see the
project, and `404 not_found` for a project the caller cannot see; `GET
/api/projects/:slug/board` still reads the alias. `PUT
/api/control/missions/:id/board` refuses every caller too
(`403 {"error":"not_mission_writer"}`, or `404 mission_not_found` outside the
mission's tenant).

Replacing the controller copies no board: the new controller starts with an
empty board and the outgoing controller keeps its text. (The one exception is a
project that still holds unclaimed pre-migration text, which its first
controller receives.) Hand off by putting the full board text in the handoff
message; the successor writes it with `write_mission_board` and reads it back.

Moving a mission to another project leaves its board row untouched, but the
alias tools resolve the project's `controller_mission_id`, which a move does
not change. After a move `read_project_board` therefore reads whatever the new
project names as its controller — not the moved mission's board, unless that
project names the mission — and with no controller returns the project's legacy
text and `controller_mission_id: null`, empty when it has no board; the write
answers `not_project_controller` unless the project names the mission. After a
move a controller reads and writes its own board with the mission tools only.

Use `get_project` and `list_projects` for project metadata.
Keep plans, progress, evidence links, and questions in the board text.
Send instructions to the controller mission through ordinary mission messaging.

Structured project tracks, evidence, tasks, decisions, steers, and the Hermes
controller/cron API have been removed. Their REST routes return
`410 {"error":"removed"}` and their MCP tools are absent.
Until installed iOS/Android builds older than 1.77.0 are retired,
`GET /api/projects/:slug/controller` returns `{"job":null}` and
`GET /api/projects/:slug/crons` returns `{"jobs":[]}` with status 200.
These compatibility reads never access the Hermes scheduler.

On first startup after this removal, Core exports the retired tables to
`<data root>/archive/project-board-legacy-<date>.jsonl` and records completion.
Each line identifies its database and table and contains the complete row.
The tables stay in place for a later removal PR.

The export uses private atomic files and writes its completion marker only after
publishing the archive. An export failure stops startup and is retried next time.
JSON values preserve SQL nulls, numbers, and text; blobs use a `$blob_hex` object.
Schema creation and additive migrations retain the old tables. Runtime project
handlers no longer read or write them. Dispatch track leases remain shared with
mission admission and are outside this removal.
