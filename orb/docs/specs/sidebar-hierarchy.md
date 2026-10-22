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
