# Projects and controller missions

A project is a label, one controller mission, and one text board.
It retains title, objective, status, color, skills, files, and appearance.
Missions use the project label to share context and organize work.

Start a mission with the controller flag to nominate it as the project controller.
Core records `projects.controller_mission_id`; one mission owns board writes.
Use `GET /api/projects/:slug/controller-mission` to read that assignment and
`PUT /api/projects/:slug/controller-mission` to replace it.

Read the board with `GET /api/projects/:slug/board` or `read_project_board`.
The controller replaces its text with `write_project_board` (up to 16384 UTF-8
bytes). The authenticated REST `PUT /api/projects/:slug/board` also updates it.
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
