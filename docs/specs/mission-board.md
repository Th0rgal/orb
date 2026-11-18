# Mission board

Status: contract for roadmap node `B1` (`docs/plans/orb-roadmap.md`). `B2`
implements storage, tools, the REST route and the migration; `B3` (desktop),
`B4` (iOS/Android) and `B6` (skills, `docs/AGENT_CONTROL_PLANE.md`) follow.
This document specifies the ownership boundary and replay guarantees; it does
not transfer operator-owned project or mission lifecycle operations to a
mission.

## Problem

A board belongs to a project, so two roadmaps that each keep a board cannot
share a project. The board moves to the mission: one text, written only by that
mission, travelling with it when it changes project. The project keeps its
label, its owner and its controller mission; it no longer owns prose.

## Identity and ownership

- A board is keyed by `mission_id` and nothing else. There is at most one board
  per mission, and a mission has at most one text.
- The **mission whose id equals `mission_id`** is the only writer.
- The text is not a plan, a task list or a merge of documents. It is one
  replacement text; there is no append, patch, field merge or per-row edit.
- The project board is retired. `project_board` rows are migrated (see *Migration from project boards*) and the
  table is retained unread for a later removal, exactly like the other retired
  project tables in `docs/AGENT_CONTROL_PLANE.md`.

The controller mission is a project assignment, not a second owner for the
board. Project creation, mission moves, project moves, mission archiving,
project archiving and controller nomination/replacement remain operator-owned
operations. They may change which missions a project page lists, but they may
not write, copy, clear or otherwise take ownership of a mission's board.

## Storage

`missions.db`, additive and idempotent:

```sql
CREATE TABLE IF NOT EXISTS mission_board (
  mission_id           TEXT PRIMARY KEY,
  text                 TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  updated_by_mission_id TEXT NOT NULL,
  text_sha256          TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_mission_board_updated ON mission_board(updated_at);
```

- `text` is stored and returned byte for byte as UTF-8. No normalization,
  trimming, markdown rewriting or escaping happens on write or read.
- `text_sha256` is the lowercase hex SHA-256 of those UTF-8 bytes. It is a cache
  key for clients, never an authorization input.
- The limit is **16384 bytes of UTF-8** after encoding the exact string. A
  larger text is rejected whole (`board_too_large`, HTTP `400`); it is never
  truncated, and a rejected write changes no column.
- Empty text is a valid board ("no plan yet") and is distinguishable from a
  missing row only by the absence of `updated_at`.
- The board row is written in the same `IMMEDIATE` transaction that records the
  write receipt, so a crash leaves either the old text or the new text.

## Authorization

Reads:

| Reader | Boards readable |
| --- | --- |
| the mission itself | its own |
| the mission's owner user (`missions.owner_user_id`) | every mission it owns |
| any mission it started — descendants through `parent_mission_id`, `btw-parent:<id>`, and `fork-of:` group members it launched — at any depth | its ancestors' |
| `operator` / `coordinator`, confined to the same project | within that project |
| any other mission or user | none |

The owner means the mission's owning user as recorded by Core. An owner may
read the boards of that user's missions, subject to the same tenant and
project-scope checks as other Core reads. A mission may additionally read the
boards of missions it started, through the recorded parent/fork lineage at any
depth. That relation is directional: a parent does not gain permission to
read a child merely by starting it. A project page applies these same checks to
each listed mission rather than granting project-wide board access.

Writes: only the mission itself. An operator, the project owner or the
controller mission can read a board but cannot write it; there is no
administrative override, because an overridden board would no longer be that
mission's account of its own work.

Directionality is deliberate and not symmetric: a descendant reads its ancestors' boards;
a parent without a project role cannot read its child's board. Read access is re-derived from live
`missions` rows on every call (owner, `parent_mission_id`, `project`), never
from a token claim captured at session creation.

Zero-oracle responses:

- Unknown mission id and unreadable mission id both answer `404`
  `{"error":"mission_not_found"}` to a caller outside the mission's tenant.
- A mismatch inside the caller's own tenant answers `403`
  `{"error":"not_mission_writer"}` for writes and `403`
  `{"error":"forbidden"}` for reads, matching the existing
  `checkMissionReadAccess` vocabulary.
- Denials carry no text, no length, no `updated_at` and no hash.

A member cannot read another user's board. Project slugs stay owner-scoped
(`<user_id>:<slug>`), so two users' projects with the same display slug never
share a mission listing, and therefore never share boards.

## Surface

MCP (replacing the project board pair, one release of aliases in *Compatibility window*):

- `read_mission_board` — `{mission_id?}`; defaults to the caller's own mission.
  Returns `{mission_id, text, updated_at, updated_by_mission_id, text_sha256}`.
- `write_mission_board` — `{mission_id?, text, idempotency_key?}`. The
  `mission_id` must equal the caller's mission; anything else is
  `not_mission_writer`. Returns the same shape as the read.
- Both are mutating-control tools for `orb/src/localMessageQueue` purposes only
  when they mutate; reads never create an action receipt.

REST:

- `GET /api/control/missions/:id/board` — the same body as the read tool.
- `PUT /api/control/missions/:id/board` — reserved for a mission-bound REST
  credential. Core does not yet issue that credential, so user principals are
  refused exactly like the other mission-board write surface: unreadable
  missions answer `404 {"error":"mission_not_found"}` and readable missions
  answer `403 {"error":"not_mission_writer"}`. The `{text, base_updated_at?}`
  body and its optimistic fence remain the contract for mission-bound writers:
  when `base_updated_at` is present and differs from the stored `updated_at`,
  the write answers `409 {"error":"board_conflict","updated_at":…}` and changes
  nothing. Omitting it is an unconditional replace. Until the credential exists,
  MCP `write_mission_board` is the write surface and the storage fence is named
  in `B2b`.
- `GET /api/projects/:slug/boards` — the project page listing (*Project page listing*).

## Project page listing

`GET /api/projects/:slug/boards` returns metadata for the boards of the
missions in that project that the caller may read:

```json
{"project":"orb","boards":[
  {"mission_id":"…","title":"…","status":"active","parent_mission_id":null,
   "updated_at":"…","bytes":1284,"text_sha256":"…"}]}
```

- Metadata only, and only for missions that have a board row. The text is
  fetched per board with the mission route, so a project with many missions
  stays one small response and one row repaint per board card. A caller never
  learns that an unreadable mission has a board from this listing.
- Ordering is `updated_at` descending, then `mission_id` ascending, so equal
  timestamps never reorder between polls.
- Archived missions are included only when `?all=true`; deleted missions and
  missions the caller cannot read are omitted entirely. The listing never
  returns a count that reveals an unreadable board.

## Lifecycle and operator-owned transitions

| Event | Effect on the board |
| --- | --- |
| Mission moves project or folder (`POST /api/control/missions/move`, family expansion) | None. The row is keyed by `mission_id`; the text, `updated_at` and writer are untouched. The mission leaves one project listing and appears in the other with the same hash. |
| Folder rename cascade | None, same reason. |
| Project rename, re-slug, archive, restore, delete | None. Boards follow missions, not project rows. A `status='deleted'` project hides its page but keeps its missions and their boards. |
| Mission archived (`Acknowledged`) | Board retained and still writable by the mission. Archiving changes presentation only, as in `docs/specs/mission-workspace-purge.md`; the archive operation remains operator-owned. |
| Mission resumed | Board unchanged. Resume never re-creates, truncates or re-reads a board. |
| `POST /api/control/missions/:id/fork` | The source keeps its board; the fork is a new mission id and starts with no board row. A fork is a new account of work, not a copy of the old one. |
| Machine transfer / handoff that keeps the same mission id | Board unchanged. Identity is the id, not the machine, node or backend. |
| `DELETE /api/control/missions/:id` | The board row is deleted in the same transaction as the mission row and its events. Deletion is the only path that removes a board, and it is explicit and operator-owned. |
| Controller mission replaced (`PUT /api/projects/:slug/controller-mission`) | No board is copied or moved. The old controller keeps its board; the new one starts empty. |

## Migration from project boards

One additive, idempotent, restart-safe step, recorded in
`mission_board_migrations(name TEXT PRIMARY KEY, completed_at TEXT NOT NULL,
detail TEXT NOT NULL)`:

1. For each `project_board` row whose `projects.controller_mission_id` names an
   existing mission, insert a `mission_board` row with the **identical** `text`
   bytes, the original `updated_at`, `updated_by_mission_id` set to that
   controller mission, and its `text_sha256`. `INSERT OR IGNORE` on
   `mission_id`, so a re-run never overwrites a board that mission has written
   since.
2. For a `project_board` row with no controller mission — or with a controller
   id that no longer exists — keep the text in place and record it as unclaimed
   in the receipt `detail`. It is **not** deleted and **not** attributed to an
   arbitrary mission. The next controller nomination for that project claims it
   (`PUT …/controller-mission` copies the unclaimed text into the new
   controller's board when that mission has no board yet).
3. Only after the copy commits, write the completion marker. A failure before
   the marker is retried next startup; a failure after it is a no-op.
4. The migration runs **before** the legacy project-table export completes its
   marker, in the same startup sequence as
   `exportLegacyProjectBoard`. The `project_board` table stays populated, so a
   later removal PR re-verifies rather than reconstructs.

Required outcomes:

- `orb` and `evm-fast` boards survive byte for byte: same UTF-8 bytes, same
  `updated_at`, one `mission_board` row each, attributed to their controller
  mission.
- Re-running the migration on an upgraded store changes zero rows.
- A store with a project board but no controller mission keeps that text
  readable through the alias window (*Compatibility window*) and claims it on the next nomination.

## Concurrency, retries and restarts

- **Atomic replace.** A write either commits the whole text or nothing. Readers
  never observe a partial, interleaved or truncated text, and never a
  `text_sha256` that disagrees with `text`.
- **Identical rewrite is a no-op.** Writing text equal to the stored text
  commits no row change: `updated_at` and `updated_by_mission_id` keep their
  values, so a retry cannot reorder the project listing.
- **Two writers on one mission** (a resumed turn racing a queued turn) resolve
  by `updated_at` of the last committed transaction. With `base_updated_at`
  both callers see one `409` and one `200`; without it the later commit wins.
  Neither loses bytes to a merge, because there is no merge.
- **Retried MCP calls** carrying `idempotency_key` replay the settled
  `mcp_actions_v1` receipt and do not write again. A retry without a key is a
  full replace, never an append.
- **Uncertain transport.** A client that did not see the response re-reads the
  board and compares `text_sha256`; it never re-sends a different text as a
  "fix". The write receipt is the authority for whether the call landed.
- **Restart.** The board lives in `missions.db` and needs no boot replay. Boot
  reconciliation must not delete boards for missions that are archived, not yet
  listed, or being migrated; board rows are deleted only by mission deletion.
- **Tenant scope changes** (`mcp_sessions_v1.project_scope` rebinding during a
  move) do not touch boards; access is recomputed from the mission row.

## Event orders that must never lose a board

Each order is a required replay test in `B2`, asserted on stored bytes:

1. **Write then move.** `PUT …/board` commits, then
   `POST /api/control/missions/move` relabels the mission and its family. After
   both acks the board is byte-identical and listed under the new project only.
2. **Move then write.** The move commits first; the queued write then lands on
   the moved mission. The board is present under the new project with the new
   text, and the old project listing never shows a ghost board.
3. **Move, stale poll, write.** A project listing started before the move
   resolves after it and is discarded by `placement_revision`; the later write
   is not overwritten by that stale response.
4. **Archive, write, resume.** Archiving between a read and a write must not
   reject or drop the write; resume must not revert the text to the pre-archive
   value.
5. **Migration re-run after a write.** Startup migration runs again on a store
   where the controller mission already wrote a newer board; the legacy text
   must not overwrite it, and the marker prevents a third pass.
6. **Controller replacement after migration.** `PUT …/controller-mission`
   changes who reads via the alias; the migrated text stays with the mission
   that received it, and the new controller's board stays empty until it writes.
7. **Fork during an in-flight write.** The source's write commits after the
   fork response; the fork's board stays absent and the source keeps its text.
8. **Project delete then mission read.** Deleting the project record does not
   touch `mission_board`; the mission route still returns the text to its owner.
9. **Mission delete during an in-flight write.** The delete transaction wins or
   the write does; the outcome is one of those two, and the store never holds a
   board without its mission.
10. **Legacy export and migration in either startup order.** Export then
    migration and migration then export both leave the `orb` and `evm-fast`
    texts byte-identical, attributed to their controller missions, and the
    legacy archive complete. Neither marker may cause a board row to be
    discarded or a newer mission-owned text to be overwritten.

11. **Operator transition ordering.** A project create, mission move, project
    move, mission archive, project archive, controller replacement or restart
    may occur before, after or between a board read/write and its response.
    The committed board remains keyed to the same `mission_id`; no transition
    may create a second board, replace committed text with an empty response,
    or make a stale project listing delete a board. The only removal ordering
    is an explicit mission deletion transaction, which removes the mission and
    its board together.

## Out of scope

- Client rendering, mobile parity and version bumps (`B3`, `B4`).
- Skill and `docs/AGENT_CONTROL_PLANE.md` wording (`B6`).
- Moving missions or projects, and any change to `orb` or `evm-fast` runtime
  data: the operator does that once `B2` and `B3` are deployed.
- Structured tracks, tasks, decisions and steers stay removed
  (`410 {"error":"removed"}`).

## Compatibility window

For one release, `read_project_board` and `write_project_board` keep working as
aliases:

- The alias resolves the project's controller mission and reads or writes that
  mission's board, with exactly the mission-board authorization, so a non-
  controller write still answers `not_project_controller`.
- When a project has no controller mission and holds unclaimed legacy text, the
  read returns that text and the write answers `not_project_controller`.
- `GET /api/projects/:slug/board` and `PUT /api/projects/:slug/board` behave the
  same way. The `410` retirement of the structured project routes is unchanged.

After that release the alias calls are removed; the mission tools and the
mission REST route are the only board surface.
