# Sidebar selection and context menus

The desktop project tree (`orb/src/tree/selection.ts`, `orb/src/ProjectFiles.tsx`)
separates three distinct row states so transient menus never steal ownership from
the open conversation:

1. **Committed item (`selected`)**: Owned by top-level navigation (`m:<id>`,
   `pf:<slug>:<path>`, `pc:<slug>:<id>`, `c:<slug>`, or a top-level page such as
   New Agent or Inbox). Navigating resets any transient multi-selection and
   anchors Shift-range selection at the newly opened row.
2. **Explicit multi-selection (`selectionActive` + `selectedTreeIds`)**: Entered
   only through explicit selection gestures (`Shift`-click, `Cmd`/`Ctrl`-click,
   or bulk archive selection actions). Cleared by navigation, plain-clicking a
   row to open it, pressing `Escape` in the tree, or right-clicking a row outside
   the current multi-selection.
3. **Transient context-menu / move-picker target (`contextTreeId`)**: Derived
   directly from the currently open row overlay (`missionMenu`, `fileMenu`,
   `controllerMenu`, or `movePicker`). Right-clicking an unselected row — or
   long-pressing (`260ms` without pointer movement) and releasing to open the
   searchable **Move to** `Picker` — highlights that row (`active` and
   `aria-selected="true"`) while the menu or picker remains open, without mutating
   `selectionActive` or opening the row.

## Live native desktop hierarchy

On the first live roster, a sole project opens automatically. Its folder icon uses the project color from Core, with the theme’s muted icon color for a missing or unknown value. Multiple projects start collapsed when no mission is selected.

Opening or closing a project changes the tree disclosure. The current view,
draft text, and draft destination survive either gesture. The open folder icon
identifies an expanded project. Its plus button starts a new draft in that project.

A roster refresh must retain the project, folder, launch parent, callback
parent, and fork source of each mission. A child arriving before its controller
keeps its parent identity across the refresh. Opening a project must use its
project-scoped roster: a global recent-missions page cannot establish either
a complete child count or the absence of an older controller. The launched-work
badge counts descendants at every depth, including those inside collapsed rows.
Expanding a row changes visibility while preserving its count. Archives stay
in their disclosure. Opening a child selects the same mission across refreshes.

## Press-and-hold & drag-move gestures (`lean/Orb/Kernel.lean`, `orb/src/tree/rowDrag.ts`)

Pure gesture phase transitions, timers, auto-scroll velocity math, and move-target
admission live in Lean 4 (`orb_sidebar_drag_step`, `orb_sidebar_move_target_admit`
in `lean/Orb/Kernel.lean`, proved in `lean/Orb/Spec.lean`):

- **Quick click (`< 260ms`, `< 6px`)**: Releases cleanly with `eatClick = false` so
  normal mission/file/cron activation and folder expand/collapse stay instant.
- **Press-and-hold (`>= 260ms`, `< 6px`)**: Lifts the row (or active multi-selection)
  into `armed` state (`.row.drag-source` + monochrome `.sidebar-drag-pill`) and
  dismisses any delayed hover tooltip. Releasing without dragging opens the
  searchable cross-project/folder **Move to** `Picker` anchored to the row and
  suppresses the synthetic `click` (`eatClick = true`).
- **Immediate or post-hold drag (`>= 6px`)**: Transitions into `dragging`,
  highlights only Lean-admitted destination containers (`.drop-active`), expands
  collapsed projects and folders once after a `450ms` dwell (`springTargetOrd`
  clears to `0` on fire so containers never oscillate), auto-scrolls `.sb-scroll`
  within `36px` top/bottom zones (`1..10 px/frame`), and cancels cleanly on
  `Escape`, right-click, window `blur`, or `pointercancel`.
- **Target admission & folder work**: Folders can never move into themselves or
  their own descendants (`dstIsSelfOrSubtree`), items cannot no-op drop onto their
  current container, and moving a folder across projects or folders carries its
  nested missions (including launched subtrees) and crons along with it.

## Invariants

- Closing a single-row context menu — whether via a non-navigating action (**Copy
  mission ID**, **Copy**, **Cut**, **Move**, **Rename**, **Mission settings…**,
  **Archive**, **Delete…**) or dismissal (`Escape`, outside click) — immediately
  restores `.active` and `aria-selected="true"` to the committed `selected` item
  (or clears tree row highlighting when a top-level view like New Agent or Inbox
  is open).
- Right-clicking a row that is already a member of an active multi-selection
  preserves the entire multi-selection across both menu open and menu dismissal.
- Right-clicking a row outside an active multi-selection exits that
  multi-selection back to the committed item and highlights only the right-clicked
  row for the lifetime of the menu.

In both Linux renderers, Ctrl-clicking A and C followed by right-clicking B clears A and C from the command targets. Escape dismisses B’s menu and leaves the previously opened conversation in place. Right-clicking C directly after selecting A and C retains both targets.

Archive admission is checked in the same Core transaction as the status update. If B starts a turn after the client reads B as idle, Archive returns HTTP 409 and preserves B’s status even before its run record exists. The client reports the refusal and keeps A open.

When a live mission list arrives before its project folders, the sidebar shows each controller at the root with its worker count. Expanding the controller reveals its workers. When its project arrives, the same controller and descendants use the project’s expansion state.

## Regression coverage

- `orb/tests/sidebar-selection.test.ts` exercises the `createTreeSelection` state
  machine across single-row context menus, cascading submenus, multi-selection
  preservation, and outside-selection right-clicks.
- `orb/tests/sidebar-selection.browser.spec.ts` and
  `orb/tests/orb-actions.browser.spec.ts` verify in WebKit/Chromium that right-click
  **Copy mission ID** (and `Escape` dismissal) on mission B while viewing mission A
  highlights B only while the menu is open and restores selection to A once closed.

A delegated mission follows its visible controller when a move or partial update leaves the child with an older project slug. The controller keeps its descendant count while collapsed. Expanding it reveals the child once, beneath that controller.
