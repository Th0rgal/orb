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
3. **Transient context-menu target (`contextTreeId`)**: Derived directly from the
   currently open row context menu (`missionMenu`, `fileMenu`, `controllerMenu`).
   Right-clicking an unselected row highlights that row (`active` and
   `aria-selected="true"`) while its context menu (including cascading submenus
   such as **Transfer to another agent**) remains open, without mutating
   `selectionActive` or opening the row.

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
