# Mission Moves (Folders, Subfolders, and Projects)

## Scope

Moving one or more missions (conversations), folders, or subfolders inside a
project or across projects across Core (`src/`), Orb desktop (`orb/`), iOS
(`ios_dashboard/`), and Android (`android_dashboard/`).

Machine transfers (`POST /api/control/missions/:id/machine-transfer`) are
separate and governed by [ORB_MISSION_TRANSFER.md](../ORB_MISSION_TRANSFER.md).

## Principles

1. **First-class relational placement, zero tag smuggling.**
   Each mission carries `project` (`TEXT`), `folder` (`TEXT NOT NULL DEFAULT ''`),
   and `placement_revision` (`INTEGER NOT NULL DEFAULT 0`) directly in `missions`
   with composite index `idx_missions_project_folder(project, folder)`.
   `orb-folder:<path>` tags are retired across all servers and clients.

2. **Root vs nested lineage invariant.**
   - A root mission (or any `fork-of:` version in a root conversation group) owns
     its `(project, folder)` placement (`""` = project root, `"foo/bar"` = nested
     folder without leading/trailing slashes).
   - Every launched worker/subagent descendant (`parent_mission_id` where not a
     `fork-of:` link, Hermes `callback_parent` child, `/btw` side session
     `btw-parent:<id>`, and `btw-subagent` worker) stays nested under its root
     conversation with `folder = ""` and **always shares its root conversation's
     `project`**.
   - Moving a mission automatically expands to its complete family closure on Core:
     co-located `fork-of:` group members (when moving the group leader; moving an
     explicit earlier version moves that version and its own launched subtree),
     all launched descendants at any depth, Hermes `callback_parent` children, and
     all `/btw` side sessions (`btw-parent:*`) plus their worker subtrees. No
     child, fork, or `/btw` side session is ever stranded in the previous project
     or folder.

3. **Two execution tiers on Core.**
   - **Intra-project folder move (`from_project == to_project`):** Pure metadata
     relocation. Executes in a single `IMMEDIATE` SQLite transaction on
     `missions.db` (`SET folder = ?, placement_revision = placement_revision + 1`
     with `updated_at` preserved so activity recency order never jumps). Touches
     neither `ControlCommand` actor queues, `durable_lock`, `projects.db`, nor
     `SecretBroker`.
   - **Cross-project transfer (`from_project != to_project`):** Atomic batch
     transfer across the expanded family closure:
     1. Preflights `SecretBroker` for live approved Touch-ID grants (`Grant`) or
        pending secret write/delete/move requests (`SecretRequest`) attached to
        any mission in the moving set.
     2. When `approval_policy == "check"` (the default) and at least one live
        grant or pending request exists, returns `409 Conflict` with
        `{ code: "approval_transfer_confirmation_required", grants, pending_requests }`
        before mutating any state.
     3. When no live grants/pending requests exist, or `approval_policy` is
        explicitly `"revoke"` or `"keep"`, transfers track leases in `projects.db`,
        updates `(project, folder, placement_revision = placement_revision + 1)`
        with `updated_at` preserved, updates `mcp_sessions_v1.project_scope`, and
        applies the chosen secret policy (`"revoke"` revokes live grants and denies
        pending requests; `"keep"` rebinds `paloma_project` on grants and pending
        requests to `to_project`, auto-resolving pending `Read` requests covered
        by `to_project`'s `default_access`).
     4. Dynamic authorization (`SecretBroker::caller_for` and MCP gateway
        `authorize_job`) always resolves a mission principal's project from live
        `MissionStore` state rather than a static creation-time JWT claim.

4. **Server-side folder cascade.**
   Renaming or moving a folder via `POST /api/projects/:slug/file/transfer`
   atomically rewrites matching `missions.folder` (`folder = old` or
   `folder LIKE old || '/%'`, incrementing `placement_revision`) and
   `project_crons.folder` on Core, then broadcasts `mission_placement_changed`.
   Clients never paginate or loop over folder missions to rewrite paths.

5. **Monotone client reconciliation (`orb_placement_merge_step`) & SSE sync.**
   - Core emits `AgentEvent::MissionPlacementChanged { moves }` on the control
     event stream for every mission move and folder cascade.
   - Every client store (`missions[slug]`, `archivedMissions`, `ancestorCache`,
     `parentRows`, iOS `OrbModel`, Android `OrbRepository`) reconciles `(project,
     folder, placement_revision)` through the Lean-verified
     `orb_placement_merge_step` gate:
     - While an optimistic local move is in flight (`pendingLocalOpId != 0`),
       polls/snapshots lacking a confirming revision (`incomingRev <= baseRev` on
       the old placement) cannot snap the row back to its prior folder or project.
     - Once settled, any payload with `incomingRev < currentRev` preserves the
       newer `(project, folder, currentRev)` instead of reverting.
     - Any payload or SSE event advancing a mission to `project = P` with a newer
       `placement_revision` immediately evicts stale copies from every other
       project bucket and updates cached ancestor/parent records so ghost
       placeholder parents cannot appear.
   - No 30-second client-side timer overlays (`MOVE_CONFIRM_MS`) and no pre-move
     `GET /api/control/missions/:id` round-trip.

## API Contract

### `POST /api/control/missions/move`

Request:
```json
{
  "mission_ids": ["9f559751-f14e-4016-94d0-9caf1458778d"],
  "project": "default",
  "folder": "research/lean",
  "approval_policy": "check"
}
```
- `mission_ids`: non-empty list of mission UUIDs selected by the user.
- `project`: target project slug (validated & canonicalized).
- `folder`: normalized relative folder path (`""` for project root; rejects `..`,
  control characters, or leading/trailing slashes after normalization).
- `approval_policy`: `"check"` (default) | `"revoke"` | `"keep"`.

Success (`200 OK`):
```json
{
  "moved": [
    {
      "mission_id": "9f559751-f14e-4016-94d0-9caf1458778d",
      "project": null,
      "folder": "research/lean",
      "placement_revision": 4
    }
  ]
}
```

Confirmation required (`409 Conflict`):
```json
{
  "code": "approval_transfer_confirmation_required",
  "error": "Moving across projects affects active secret approvals.",
  "target_project": "default",
  "grants": [
    {
      "id": "grant-uuid",
      "mission_id": "9f559751-f14e-4016-94d0-9caf1458778d",
      "secret_name": "PROD_API_KEY",
      "source_project": "assistant",
      "expires_at_ms": 1793775533000
    }
  ],
  "pending_requests": [
    {
      "id": "req-uuid",
      "mission_id": "9f559751-f14e-4016-94d0-9caf1458778d",
      "secret_name": "PROD_WRITE_TOKEN",
      "operation": "write",
      "source_project": "assistant"
    }
  ]
}
```

## Required Event-Order Replay Tests

1. **Stale poll during in-flight folder move:** Poll starts before move `A/f1 -> A/f2`,
   optimistic move applies, stale poll resolves with `(A, f1, rev=0)`, move response
   commits `(A, f2, rev=1)` — row stays in `A/f2` for every frame with zero flicker.
2. **Rapid multi-hop move (`A/f1 -> A/f2 -> B/f3`):** Out-of-order HTTP responses and
   interleaved project polls never revert `B/f3` (`rev=2`) back to `A/f2` (`rev=1`)
   or `A/f1` (`rev=0`).
3. **Cross-project subtree + `/btw` + archived parent closure:** Moving a conversation
   with launched workers, forks, archived ancestor context, and `/btw` side sessions
   moves every descendant atomically and evicts cached ancestor rows from the source
   project so zero ghost parent rows remain.
4. **Cross-project approval confirmation (`check` -> `409` -> `revoke` | `keep`):**
   Moving a mission with a live grant returns `409`, keeps the mission at its source
   until confirmed, and applies `"revoke"` or `"keep"` cleanly on confirmation.
