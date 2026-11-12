# Hybrid Native Chrome (`OrbLocald` Sidebar & `Cmd+K` Palette Projection)

By default on desktop shells (`ORB_NATIVE_CHROME` unset or `1`; pass `ORB_NATIVE_CHROME=0`
to fall back to the WebView-rendered sidebar, exposed to the WebView as
`window.__ORB_NATIVE_CHROME__ === true`), the native shell
(`macos_shell/main.swift` via `NSSplitView` + `NSTableView` + `NSPanel`, and
`linux_shell/` via `GtkPaned` + `GtkListBox` + `GtkPopover`) renders the sidebar
navigation tree and `Cmd+K` / `Ctrl+K` quick-switcher natively, while the WebView
renders transcripts, Markdown, diffs, KaTeX, Mermaid, PDFs, and the composer.

## Single Owner & Cold-Start Hydration (`AGENTS.md` Principle 3)

`OrbLocald.NativeChrome` (`lean/OrbLocald/OrbLocald/NativeChrome.lean`, `0 import Lean`,
`0 sorryAx`) is the single canonical owner of the flattened native chrome row model:

1. **Monotonic revision fencing (`syncRevision` vs `viewRevision`)**: `native_chrome_sync_state`
   accepts state snapshots scoped by `scope` (`historyScope()`) and producer `revision : UInt64`
   (`sync_revision`). Any payload whose `revision` is strictly older than `syncRevision` for the
   same `scope` is ignored without erasing newer state, while local `native_chrome_toggle_expand`
   updates bump only the output `viewRevision` (`revision`) so local expand/collapse toggles never
   fence out subsequent WebView snapshots. Switching `scope` resets the active scope view cleanly
   while preserving per-scope expand/collapse sets (`maxScopes = 8`).
2. **`0 ms` cold-start hydration from `~/.orb/ui-cache.sqlite3`**: When `native_chrome_get_rows`
   or `native_chrome_palette_query` is called before the WebView has pushed its first live
   `native_chrome_sync_state` (or with `scope` omitted, defaulting to the most recently saved
   `ui_sidebar` scope), `OrbLocald` hydrates projects and missions directly from the existing
   `ui_sidebar` table in `~/.orb/ui-cache.sqlite3` so native sidebar rows paint on frame 0
   before WebKit finishes booting JavaScript.

## Formal Kernel Gate Wiring (`lean/Orb/Kernel.lean`)

Every hierarchy, deduplication, and move-admission decision in `OrbLocald.NativeChrome`
routes through the verified unboxed kernel functions in `Orb.Kernel`:

- **Mission deduplication & monotonic merge (`Orb.Kernel.sidebarMergeStep`)**:
  Merges `missions`, `completedMissions`, and `projectMissions` by mission ID ordinal and
  `updatedAtMs`, dropping superseded/archived duplicates and keeping the newer snapshot
  (`uniqueSidebarBit = 1024`).
- **Cycle-safe hierarchy & filter retention (`Orb.Kernel.sidebarVisibility`)**:
  Computes `retainInMainTree` (`bit 0`), `showInArchiveOnly` (`bit 8`), and
  `isCycleSafeChild` (`bit 16`, blocking `isFork == 1` and `parentReachesSelf == 1`
  parent cycles) before flattening launched child missions beneath their parent.
- **Move target admission (`Orb.Kernel.sidebarMoveTargetAdmit`)**:
  Validates project/folder move targets (`itemKind` `0..3`), rejecting folder
  self/subtree cycles (`dstIsSelfOrSubtree == 1`) and same-container no-op moves while
  admitting cross-project moves to identical relative folder paths.
- **Gesture state machine (`Orb.Kernel.sidebarDragStep`)**:
  Governs press-and-hold (`260 ms`), drag threshold (`6 px`), and spring-loaded folder
  expansion (`450 ms`) consistently across WebView and native chrome surfaces.

## Default Project, Archived Section & Context Menu

- A mission Core files under no project (`project: null` or `""`) is projected into the
  catch-all `default` project (shown as "Default"), never at the sidebar root.
- Archived (`acknowledged`) conversations never appear inside projects. The WebView syncs
  `archived_missions` (first page of `listArchivedMissions`, reloaded on
  `orb:mission-archived` and after native actions) and `OrbLocald` lists their roots,
  newest first, under the `archive` row, collapsed unless a selected conversation is in it.
  An archived root that still has a live descendant stays in its project.
- Right-clicking a mission row opens a native menu (`linux_shell/gtk_menu.c`): Rename…,
  Move to ▸ project, Archive/Restore, Copy mission ID, Mission settings. Each item calls
  `window.__ORB_NATIVE_MISSION_ACTION__(action, id, arg)`, which reuses the HTML sidebar's
  API calls (`renameOptimistically`, `moveMission`, `archiveMission`, `reopenMission`), so
  optimistic updates and error toasts have one implementation. macOS (`NSTableView`) does
  not have this menu yet.
- Multi-selection: Ctrl/Super-click toggles a mission, project, folder or file row, Shift-click
  extends from the anchor, a plain click or Escape clears it. Right-click inside a selection of
  more than one shows only bulk actions: for missions Move N to ▸, Archive/Restore N and Delete N…
  (the HTML sidebar's selection menu); other selections show the count and Clear selection.
- Ctrl/Super+Delete deletes the selected missions, or the open one, through the headless
  `ProjectFiles` confirmation (running workers and descendants included). With WebView focus the
  same shortcut (Cmd+Backspace too on macOS) is handled by `ProjectFiles`, never while typing.

## Loopback JSON-RPC & SSE Contract

All commands run over `127.0.0.1:<rpcPort>/__orb_rpc` gated by the 32-byte launch token:

| Command | Arguments | Response |
| --- | --- | --- |
| `native_chrome_sync_state` | `{ scope, revision, selected, on_settings?, is_admin?, inbox_enabled?, inbox_unread?, settings_badge?, settings_dots?, filter_query?, projects, missions, completed_missions?, project_missions? }` | `{ revision, sync_revision, scope, applied, row_count }` |
| `native_chrome_get_rows` | `{ scope?, filter_query? }` | `{ scope, revision, sync_revision, on_settings, selected, rows: SidebarRow[], footer: SidebarRow }` |
| `native_chrome_toggle_expand` | `{ scope?, row_id, expanded? }` | `{ scope, revision, row_id, expanded, rows: SidebarRow[], footer: SidebarRow }` |
| `native_chrome_move_admit` | `{ item_kind, src_project, src_path?, dst_project, dst_path? }` | `{ admitted: Bool }` |
| `native_chrome_palette_query` | `{ scope?, query, limit? }` | `{ scope, query, items: PaletteItem[] }` |

Each `SidebarRow` and `PaletteItem` includes `icon`, `color`, and `status` metadata (plus
`child_count` and `live_child_count` on expandable mission rows) so native shells
(`macos_shell/` SF Symbols and `linux_shell/` Cairo vector glyphs) render:
- the `35 px` top header toolbar (`[Sidebar toggle] [Search] ··· [Back] [Forward]`, synced via
  `set_native_history` / `set_native_sidebar` and hidden in the WebView `.titlebar` while the
  native sidebar is open),
- per-project folder colors, neutral robot (`bot`) glyphs with bottom-right status cutout badges
  (including a 12-step spinner active only while visible rows are running),
- collapsed-by-default subagent/version trees (`expandedIds` / `collapsedIds` overrides, auto-opening
  only along the selected mission's ancestor chain) with a right-aligned `[live/total ▸]` toggle
  button separate from mission row selection,
- non-selectable `section` / `note` rows, and the pinned bottom `Settings` `footer` button
  identically to the standard WebView sidebar.

Whenever `native_chrome_sync_state` applies a state change or `native_chrome_toggle_expand`
flips a container's expansion state, `orb-locald` broadcasts SSE event
`native_chrome_rows_changed` (`{ scope, revision, row_count }`) on `/__orb_events` so
attached native shells update in place without polling.

## Cross-Client Fixture & Self-Test Coverage

- `shared/orb-spec/fixtures/native-chrome-sidebar.json` defines deterministic test vectors
  for top-level navigation rows, project/folder/child-mission flattening, parent-cycle
  rejection, monotonic merge deduplication, folder move cycle rejection, and `Cmd+K`
  trigram/prefix/substring palette ranking (`LeanSys.Search`).
- `lean/OrbLocald/OrbLocald/SelfTest.lean` replays the fixture end-to-end against
  `dispatchRpcCommand` and verifies cold-start SQLite hydration from `ui_sidebar`.
