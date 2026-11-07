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

## Regression coverage

- `orb/tests/sidebar-selection.test.ts` exercises the `createTreeSelection` state
  machine across single-row context menus, cascading submenus, multi-selection
  preservation, and outside-selection right-clicks.
- `orb/tests/sidebar-selection.browser.spec.ts` and
  `orb/tests/orb-actions.browser.spec.ts` verify in WebKit/Chromium that right-click
  **Copy mission ID** (and `Escape` dismissal) on mission B while viewing mission A
  highlights B only while the menu is open and restores selection to A once closed.
