# Sidebar hierarchy and list membership

Status: normative. Applies to the desktop Orb (`orb/`), and in reduced form to
iOS (`ios_dashboard/`) and Android (`android_dashboard/`).

## Problem

The sidebar nests missions a mission launched (subagents) inside their parent,
by `parent_mission_id`, `callback_parent_mission_id`, and the hierarchy tags
(`worker-dispatch:*`, `superseded`, `superseded_by:*`, `superseded-by:*`,
`fork-of:*`, `btw-parent:*`). Two user-visible bugs came from how rows reach it:

1. **Subagent flicker.** A child was drawn at the project root for one or more
   frames, then snapped back under its parent.
2. **Vanishing Hermes missions.** After an Orb or Hermes restart, `cloud_hermes`
   missions disappeared from the sidebar though Core still had them.

### Root causes (with evidence, 2026-10-22)

- **Derived lineage is not on every payload.** Core computes
  `callback_parent_mission_id` from the Hermes state DB, and only in the list
  (`mission_list.rs`) and single-read (`mission_read.rs`) handlers. Every
  mutation answer (`/resume`, `/pause`, settings, project, clone) serialized the
  bare `Mission`, without it. While Hermes restarts, the state DB read can
  fail, and even the list then answers without the link. The Orb replaced rows
  wholesale (`mergeById`, `setMission(next)`), so the child lost its parent
  until the next good answer.
- **Parents paged out of the list.** A project page is the 100 most recent
  rows. In production on 2026-10-22, 59 of 62 children in the 200-row page
  had their parent off the page. Each poll re-fetched every missing parent by
  id. A fetch that failed with nothing cached, or a parent filed in another
  project (filtered out on purpose), left the children as roots.
- **Membership followed the latest answer.** Each list answer *replaced* the
  rows on screen. When Core was unreachable, `listProjectMissions` /
  `listMissions` returned only the desktop journal rows, and those replaced
  the whole list. An empty or short answer served during a restart did the
  same.
- **Open missions pushed off the history page.** The project page asked for
  `all=true&limit=100`, i.e. recent history *including archived rows*. On
  `verity-core` that page held 100 rows, and 16 of the 19 open `cloud_hermes`
  missions (interrupted or failed, last updated 9 to 19 Oct) were older than
  the 100th row, so they were never listed. This is the "Hermes missions
  disappeared" report: every restart creates or updates many missions, which
  pushes more open ones off the page.
- **Journal rows carry no lineage.** Desktop journal rows (`local_origin_list`)
  have no parent fields. A pending journal row overrides Core's row.

Related, on Core: resuming a `cloud_hermes` mission through
`POST /api/control/missions/:id/resume` answered **500**. The cause was the
error "Cloud conversations use their provider account": the machine-transfer
guard refused it, and the guard's error was mapped to `internal_error`. Cloud
conversations continue with a follow-up turn, not a harness restart. Hermes
gateway restarts interrupt running `cloud_hermes` turns. For example,
`bb4e48a7` went `interrupted` at 08:49Z on 2026-10-22, the same minute as a
`hermes-gateway` restart. The other interrupted missions are in same-minute
clusters, the restart pattern.

### Root causes (with evidence, 2026-10-29 — fork version inversion & idle-worker resurrection)

- **Fork-group leader chosen purely by raw `updated_at`.** `forkLeaders`
  (`orb/src/missionTree.ts`, `OrbCore.swift`, `OrbCore.kt`) elected the leader
  of a `fork-of:` group solely by `activity(m) > activity(best)`, ignoring
  archival/supersession status, live execution status, and fork lineage depth:
  1. During a harness transfer (for example Codex `86d91cc3` -> OpenCode
     `builtin/smart` `65407660`), stopping or archiving the source mission (or
     a late status/metadata event on the source within seconds of fork creation)
     advanced `source.updated_at >= fork.updated_at`. Because `TreeView.ts`
     auto-expands any leader that `holds` the open mission, the brand-new fork
     appeared for ~1 s indented inside the source as an `earlier` version row
     (`"OpenCode · builtin/smart"`) before jumping to top-level once its first
     event updated `fork.updated_at`.
  2. `App.onFork` updated only `App`'s activity signal and triggered an async
     `bumpProjects()` read without synchronously inserting the new fork into
     `ProjectFiles`'s per-project `missions[slug]` store.
  3. On `agent-core` on 2026-10-29, archived Codex mission `86d91cc3` remained
     retained in `visibleMissions` as parent context for its worker children
     (`9bfbb6e4`, etc.), and a second fork `d65744b9` shared the same root
     group. Whenever `86d91cc3` or `d65744b9` received a newer `updated_at`
     (even in `interrupted` or `acknowledged` status), active mission `65407660`
     (`"Orb: leaninification"`) was demoted into `versions` inside the stopped
     mission, then jumped back to top-level when `65407660` updated at `06:02Z`.
- **Idle-worker watchdog resurrected archived/superseded parents.** In Core
  (`src/api/supervision.rs`), `notify_parents_of_idle_children` checked only
  `!parent.status.is_terminal()`. Because `MissionStatus::Acknowledged`
  (archived) and `MissionStatus::Paused` are non-terminal, parked `Acknowledged`
  worker `9bfbb6e4` caused `[worker-watchdog]` to inject control messages into
  archived `86d91cc3` at `03:26Z` and `05:33Z`, flipping `86d91cc3` back to
  `Active` and then `Interrupted` (`03:41Z`, `05:48Z`).

## Invariants

**H1. A mission with a parent link is never drawn at the root.** If the
parent is not among the loaded rows, the child is held under a placeholder
parent row. The child is drawn at the root only once the parent is confirmed
gone (Core answers 404 for it).

**H2. Parent identity is sticky.** A link, once seen on any payload, is
remembered. A payload that lacks the field, or has it `null` or empty, never
clears it. A different non-empty value from Core replaces it. Only an explicit
re-parent (`reparentMission`) clears it. Hierarchy tags are kept the same way:
a payload whose `tags` omit one gets it back.

**H3. Orphans are resolved, with a defined fallback.** A child whose parent
is not loaded triggers a parent fetch by id (`resolveParent`):

- `loading`: a placeholder row stands in for the parent. It shows the last
  title the Orb saw for that id, or "Parent mission" if it never saw one, and
  it sits in the child's folder. All orphans of one parent share it.
- On a transient failure, the fetch retries with backoff (1 s, 2 s, 4 s and so
  on, capped at 30 s). The placeholder stays.
- `found`: the parent is listed as context in its own project. A parent filed
  in another project stays a placeholder with its real title, and opening the
  placeholder opens the parent.
- `gone` (404): the children are drawn as roots. If the parent appears in a
  later list answer, it is resolved again.

**H4. Event order never changes the final tree.** For any interleaving of
full rows, link-less mutation answers, stream status stubs and list pages, the
parent of every row in the converged tree is the same.

**H5. Optimistic and partial updates keep hierarchy fields.** Status stubs,
optimistic moves and archives, and an open conversation laid over its list
row all go through `mergeMission(prev, patch, "partial")`. That call changes
only the fields the patch names.

**F1. Fork-group leadership respects retirement, liveness, and lineage.** Within
any connected `fork-of:` group (`forkLeaders` on desktop, iOS, and Android),
each version is ranked lexicographically by the 4-tuple
`(unretired, live, effectiveActivity, forkDepth)`:

1. `unretired` (`1` vs `0`): a version that is neither archived
   (`acknowledged` / `archived`) nor tagged `superseded` (`superseded`,
   `superseded_by:*`, `superseded-by:*`) always leads over a retired version,
   even when `missionTreeRows` retains an archived parent for its workers.
2. `live` (`1` vs `0`): a live version (`active`, `running`, `pending`,
   `queued`, `starting`, `resuming`, `waiting_background`, `awaiting_user`)
   always leads over a stopped version (`completed`, `interrupted`, `failed`,
   `cancelled`, `paused`, `blocked`). A stopped version never hides a running
   version inside `earlier`.
3. `effectiveActivity`: `updated_at` (falling back to `created_at`), except
   that when an ancestor version's `updated_at` falls within `FORK_SETTLE_MS`
   (15 s) of a descendant fork's `created_at`, its `effectiveActivity` is
   clamped to that descendant's `created_at` so post-cancel/cleanup/metadata
   writes on the source cannot outrank the newly created fork. Deliberately
   resuming or messaging an earlier version later still advances its
   `effectiveActivity` past the window and makes it lead again.
4. `forkDepth`: deeper `fork-of:` lineage breaks ties deterministically
   regardless of list order.

**F2. Optimistic fork insertion & transfer handoff.** When `onFork(next)` fires,
Orb commits `next` into `App.missions`, `App.openMission`, and
`ProjectFiles.missions[slug]` synchronously inside one `batch()` (via
`orb:mission-forked`, advancing `missionRevision` to fence pre-fork list reads)
before selecting `m:<next.id>`. When a transfer enters `running` and starts
archiving `sourceId`, `orb:mission-archived` hides `sourceId` optimistically at
once and rolls back via `orb:mission-archive-failed` only on server failure.

**W1. Idle-worker watchdog never wakes retired parents.** Core's
`notify_parents_of_idle_children` (`src/api/supervision.rs`) sends
`[worker-watchdog]` notifications only when `parent.status` is one of
`Active | Pending | WaitingBackground | AwaitingUser`, `parent` carries no
`superseded` tag, and `parent` has not been forked forward by a conversation
fork (`fork-of:<parent.id>`).

**M1. A failed, empty or partial answer never removes rows.** A row leaves the
list only through:

- an explicit delete or archive in this window (`removeRows`, `archivedInSession`),
  which is immediate;
- `MISSES_TO_REMOVE` (2) consecutive *authoritative* list answers that omit
  it, spread over at least `MISS_WINDOW_MS` (5 s). A single poll can trigger
  several reads of the same list, so count alone is not enough.

An answer from the desktop journal while Core is unreachable is *partial*
(`partialList`). It updates rows and never counts as a miss. Reconnects and
restarts therefore reconcile what is on screen and never replace it.

**M2. Missions that still matter are always listed; history stays history.**
A project's rows are its recent history page (`all=true&limit=100`, archived
rows included). Open missions older than that page (`limit=200`, paged up to
1000) are added only through `openBeyondPage`:

- *live* ones (`active`, `running`, `pending`, `queued`, `awaiting_user`,
  `resuming`, `starting`, `waiting_background`) are always added, however old;
- *stopped* ones (`interrupted`, `failed`, `paused`, `blocked`) are added only
  if updated in the last 7 days (`RECENT_OPEN_MS`). Older ones are history:
  they stay in the archive and in the normal paged list, never resurfaced;
- a *child* is added only if it is live itself, in which case its parent is
  fetched and it nests there, or if its parent is already listed. A stale
  child of a completed, acknowledged or archived parent never brings that
  parent in. It is never shown at the root or under a placeholder either.

In production on 2026-10-22, `verity`, `verity-core` and `verity-lido` held
465 open rows. 396 of them were interrupted or failed rows from July to
September, many of them children of completed or acknowledged parents. #1253
resurfaced them all; this rule hides them, while open `cloud_hermes`
missions, live or recently interrupted, still show.

## Implementation (desktop)

`orb/src/missionHierarchy.ts` holds the single path:

- `observeMission` / `withHierarchy` / `stickHierarchy` implement the sticky
  registry. `apiRequest` applies `stickHierarchy` to every mission-shaped JSON
  answer under `/api/control/missions*`. That covers lists, reads, and every
  mutation answer. Desktop journal rows get it in `listMissions` and
  `listProjectMissions`.
- `mergeMission(prev, next, "full" | "partial")` is the one merge. A full row
  replaces the old one, so cleared fields stay cleared, and keeps its links. A
  partial patch changes only the fields it names.
- `reconcileMissionList(prev, next, misses, partial)` sets list membership
  (M1). It is used by `ProjectFiles.loadMissions` and `App.refreshMissions`.
- `resolveParent` / `resolvedParents` are the parent resolver (H3).
  `nestMissions(rows, { placeholder })` holds orphans under the placeholder
  that `placeholderParent(slug)` returns (`tree/TreeView.ts`).
- `resetMissionHierarchy` runs when the connection changes.

## Implementation (Core)

- `POST /api/control/missions/:id/resume` returns the mission with the same
  derived `callback_parent_mission_id` as `GET /missions/:id`
  (`callback_parent::with_lineage`). Clients must still apply H2: the derived
  link can be missing whenever the Hermes state DB is unreadable.
- Resuming a `cloud_*` mission becomes a follow-up turn on its provider
  conversation: the request `content`, or "Continue where you left off.". It no
  longer answers 500. Options a hosted provider cannot honour
  (`clean_workspace`, `skip_message`, identity changes) answer 409.

## iOS and Android

Both apps nest by the same fields (`OrbRow.parentMissionID`,
`OrbMissionTree.parentId`). H2 is implemented there: `OrbHierarchy` (Swift)
and `OrbMissionTree.knownParents` (Kotlin) remember links, and `reparent` /
reset change them. H1 and H3 placeholders and M1 reconciliation are not yet
implemented on mobile. Mobile lists are refetched wholesale, and an orphan is
drawn at the root as before. Porting `reconcileMissionList` and the
placeholder is the follow-up.

## Tests

- `orb/tests/mission-hierarchy.test.ts` covers the merge, sticky links,
  re-parent, placeholders and the resolver (retry, 404). A property test
  replays 300 random orderings of full, stripped, status and page events. It
  asserts that no frame has a known child at the root and that every ordering
  converges on the same tree.
- `orb/tests/sidebar-hierarchy.browser.spec.ts` (Playwright, scripted Core,
  per-frame recorder via MutationObserver and requestAnimationFrame) covers:
  a paged-out parent whose first fetch fails; children before a slow parent;
  a callback child resumed while its derived link is absent; a resumed parent
  with children; a parent moved to another project; a reload during
  streaming; Hermes missions through a restart (error, error, empty, full,
  empty, full); open missions older than the history page; real `verity-core`
  open rows (`tests/fixtures/verity-core-open-missions.json`, 60 stale and 40
  recent or live): no stale row is drawn, while live and recent roots are.
- Core: `callback_parent::tests::attach_adds_a_derived_parent_and_keeps_an_existing_one`.
- Mobile: `OrbContractTests.testParentLinkIsStickyAcrossPayloadsThatOmitIt`,
  `OrbMissionTreeTest.parentLinkIsStickyAcrossPayloadsThatOmitIt`.

## Cut/paste and cross-project transfer ownership

### Root causes (with evidence, 2026-10-30 — split subtree & blocked macOS Tauri transfers)

On `agent-core` on 2026-10-29 (`16:20:39Z`–`20:16:53Z`), transferring active
orchestrator mission `0c532a32` (`evm.fast`) with ~40 historical worker
children between `assistant` (`Assistant`) and `verity-core` (`Ethereum`) in
the installed macOS Orb client (`/Applications/Orb.app`) split the tree across
both projects (`1/13` in `Assistant`, `16` in `Ethereum`, both highlighted and
stuck in `.mission-cut`) and ignored subsequent `⌘X`/`⌘V` and drag attempts:

1. **Prompt-derived writer tag mutation broke `move_only` on active missions.**
   `0c532a32` had `tags = ["fork-workspace:...", "fork-of:..."]` (no
   `"pr-writer"` tag) while its initial prompt matched `requested_pr_writer`.
   `update_mission_project_locked` (`src/api/control/mission_settings.rs`)
   treated any `req.tags` payload as `could_change_writer_status = true`,
   injected `"pr-writer"` into `effective_tags`, and then evaluated
   `folder_only(&effective_tags, &current.project.tags)` as `false` — skipping
   `move_running_mission_project` and returning `409 Conflict`
   (`assignment_busy`). Moving a running mission between `orb-folder:*` folders
   within the same project similarly fell through to `require_quiescent`.
2. **Terminal/superseded workers minted fresh 6-hour writer leases on move.**
   `update_mission_project_locked` unconditionally acquired a live track lease
   even when `ExecutionOwnership::holds_track(id) == Some(false)` (`completed`,
   `failed`, `cancelled`, `acknowledged` / `superseded`). The first completed
   worker on each shared track (`wave6-b1-loopfree`, `wave6-b2-htab`, etc.)
   succeeded (`200 OK`) and grabbed an exclusive writer lease on `verity-core`,
   causing 17 sibling historical runs on the same tracks to fail with `409
   Conflict` (`LeaseError::Owned`) and stay stranded in `assistant`.
3. **Duplicate `SidebarTree` key (`m:<parentId>`) for cross-project
   placeholders.** `placeholderParent` (`orb/src/tree/TreeView.ts`) emitted
   `id = "m:0c532a32"` in `Ethereum` while `Assistant` held the real
   `id = "m:0c532a32"`, colliding in `reconcile(next, { key: "id" })`
   (`orb/src/Tree.tsx`), highlighting both rows simultaneously, and routing
   `findNodeById` to `Assistant` when interacting with `Ethereum`.
4. **macOS Tauri menu intercepted `⌘X`/`⌘C`/`⌘V` as `ClipboardEvent`s and
   sidebar lacked row paste/drop.** Tauri v2's default macOS `Edit` menu
   intercepts `⌘X`/`⌘C`/`⌘V` before `keydown` reaches `WKWebView` and dispatches
   DOM `cut`/`copy`/`paste` events instead; `ProjectFiles.tsx` only listened to
   `onKeyDown`, ignored `⌘V` and `"Move here"` on non-header/non-folder rows
   inside a project, omitted `resolvedParents` from `allKnownMissions`, and had
   no pointer drag-and-drop between projects/folders.

### Transfer invariants

**H6. Cross-project placeholder rows carry distinct tree keys
(`mp:<slug>:<missionId>`).** A parent mission's canonical row in its own project
uses `m:<missionId>`; a cross-project placeholder parent (`orb_placeholder`)
uses `mp:<slug>:<missionId>`. `SidebarTree` keyed reconciliation, expand state,
selection, and `findNodeById` never collide across projects, while clicking or
acting on `mp:<slug>:<missionId>` opens/targets `<missionId>`.

**P1. Pure project/folder moves preserve runtime state and historical leases.**
- A patch changing only `project` and/or `orb-folder:*` tags never mutates
  `"pr-writer"` / `"pr-readonly"` tags or arbitrates foreign PR writer leases;
  running missions move atomically via `move_running_mission_project` (across
  projects) or direct tag update (within a project).
- Missions with `ExecutionOwnership::holds_track(id) == Some(false)` absorb
  their track in the destination project and release stale leases without
  acquiring a new live track lease, so completed or superseded sibling runs
  never block each other or live workers.
- Root cross-project moves pass `include_descendants: true` so Core also moves
  any paged-out, archived, or unexpanded `parent_mission_id` descendants on the
  server under the same `DISPATCH_ADMISSION` and durable admission lock
  (stripping child `orb-folder:*` tags while keeping capability and hierarchy
  tags). If any descendant transfer fails (for example, a live writer conflict
  on a destination track), Core rolls back the root and every preceding
  descendant's `MissionProject` metadata and track leases before returning the
  error so subtrees are never left split across projects.

**P2. Single sidebar transfer pipeline across menu, clipboard, and drag.**
Context-menu `Move` / `Move here` (available on projects, folders, and rows
inside a project), keyboard `⌘X`/`⌘C`/`⌘V` (`keydown` and native macOS
`cut`/`copy`/`paste` `ClipboardEvent`s), and pointer drag-and-drop onto
`[data-drop-project]` targets resolve destination `(slug, enclosingFolder)` via
one helper and execute through the same move pipeline.

A mission has one visible project/folder during and after a move, including when
it is the open conversation. The loaded sidebar listing owns placement; open
conversation details may refresh status/content but cannot restore an older
project or folder. Apply the shared move projection to that resolved placement.
Rendering a projected destination is not server acknowledgement.

A successful move commits its placement to the sidebar listings atomically:
remove the old membership, insert/update the destination, and fence reads started
before that acknowledgement. Do not wait for a destination list request before
making this change. Failed writes remove only their optimistic projection and
restore their original placement with a visible retryable error.

Regression sequences:
1. Open a mission in A; cut/paste into B while the write is held; observe
   exactly one row in B; acknowledge the write while holding B's list refresh;
   deliver the old A response and old conversation details; expire the move
   overlay. At every step the row remains only in B. Repeat for a nested folder
   and a rejected move, which must restore A.
2. Active forked parent without `"pr-writer"` tag (whose initial prompt requests
   writer) plus multiple completed/superseded workers sharing a writer track:
   transferring to another project moves the active parent and every worker
   without `409 Conflict` or live lease leaks, including unloaded descendants.
3. Split subtree across projects A and B: placeholder parent in B uses
   `mp:B:<id>` without colliding with `m:<id>` in A, and transferring via native
   `cut`/`paste` `ClipboardEvent`, row context menu `Move here`, or pointer
   drag-and-drop consolidates the subtree into the target project.
