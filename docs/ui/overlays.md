# Orb overlays

Desktop/web overlays use SolidJS, CSS variables, and the primitives in `orb/src`.
No additional UI library is needed. Native iOS and Android are separate clients.

## Choose a primitive

- A task that blocks the underlying view: `Dialog`.
- One editable name or path: `NameDialog`.
- Confirmation before an operation: `ConfirmDialog`. Always pass `destructive` explicitly; use `true` for irreversible deletion.
- An interrupted operation with technical details: `ErrorDialog`.
- Commands, including cascading submenus: `Menu` / `PopupMenu` and `MenuList`.
- A native form value with a fixed option set: `Select`.
- Searchable values, groups, loading/empty/error states or footer actions: `Picker`.
- Other anchored content: `Popover`.
- Delayed, non-interactive row details: `useTooltip`, backed by `Popover`.
- Image attachments: `Lightbox`, which uses a fullscreen `Dialog`.

`overlayLayer.ts` owns parent/child order, dismissal, inert backgrounds and focus scopes.
`overlayPosition.ts` owns placement, flipping, resizing and viewport margins.
Do not add business-specific global Escape/outside-click listeners, fixed positions,
z-index values, or new overlay backdrops. Put new behavior in the shared primitive.
Caret-driven autocomplete keeps focus in its editor using `trap={false}`; hover
previews additionally use `restoreFocus={false}` to avoid reopening on focus.
Their layout and dismissal still use `Popover`. Hierarchical folder browsing and
the multi-step machine transfer retain their business content inside `Popover`;
they share layer, focus and placement behavior, with no independent backdrops.

Non-overlay exceptions are explicit: the Find bar stays attached to its search
region, file panels are layout panes, and the toast is a status announcement.
Compact, non-interactive queue shortcut hints and inline voice errors keep their
local presentation; they cannot contain commands or open child surfaces. Native
`title` hints remain native. New interactive content must use the primitives above.

## Visual contract

Dark surface `#191919`, border `#333333`, one pixel. Light surfaces use the
corresponding `--overlay-*` tokens. Modal radius 12px, menus 8px, controls 6px.
Modal widths: compact 400px, standard 480px, wide 640px; fullscreen fills the window.
Content padding 16px. Footers have a top separator and 12px/16px padding.
Titles use 15px/500; body and controls use 13px. Inputs are 32px and buttons 28px.
The 16px viewport inset and scrolling body keep actions reachable in small windows.

Secondary actions are transparent; primary actions are neutral; red marks irreversible
actions. Keyboard focus is a separate outline, not a hover or selection color.
Active search results are different from committed values. Arrow navigation must
never commit a value. Disabled options cannot receive an activation.

## Executable examples

Run `cd orb && pnpm dev` and open `/tests/overlays.html`.
The source is `orb/tests/overlay-gallery.tsx`. These examples are used directly by
`orb/tests/overlays.browser.spec.ts` in Chromium and WebKit.

Confirmation (gallery: **Confirm deletion**):

```tsx
<ConfirmDialog title="Delete folder"
  description="Delete Research notes and its contents? This cannot be undone."
  action="Delete folder" destructive onConfirm={close} onClose={close}/>
```

Form (gallery: **Provider form**, abbreviated):

```tsx
<Dialog title="Connect a provider" dirty={dirty()} busy={saving()} onClose={close}
  footer={requestClose => <>
    <DialogButton onClick={requestClose}>Cancel</DialogButton>
    <DialogButton variant="primary" disabled={saving()} onClick={save}>Save</DialogButton>
  </>}>
  <Field label="Account name" description="This name is shown on all devices.">
    <input class="s-input" value={name()} onInput={e => setName(e.currentTarget.value)}/>
  </Field>
</Dialog>
```

Picker (gallery: **Choose model**):

```tsx
<Picker label="Models" searchLabel="Search models" anchor={anchor()}
  items={items()} selected={selected()} onSelect={select} onClose={close}/>
```

Pass `loading`, `error`, `onRetry`, `emptyLabel`, `noResultsLabel`, and `footer`
when the data source needs those states. Do not silently show an empty list on failure.

## Copy and focus

Use specific titles/actions: “Rename agent”, “Create project”, “Delete folder”.
Use “Cancel” for cancellation, “Close” for information, and “Keep editing” when
preserving a draft. Use ellipses only when the command opens another step.
Descriptions belong under the title, without truncation. `Field` associates its
label, description and inline error with its control. Technical details can collapse;
the actionable explanation remains visible.

A modal traps focus and makes the underlying application inert. Closing restores
focus with `preventScroll`. A child receives Escape first; closing it leaves its
parent open. Submenus support arrows, Home/End, activation, Escape and ArrowLeft.
Pickers focus search initially, or the selected enabled option when search is
disabled. Only one option is active; arrows move it without committing, and
Enter or Space commits it (Space remains text in search). Refreshing options
preserves the active ID. For a modal draft, pass `dirty` and route Cancel
through the footer's `requestClose`; X, Escape and outside clicks use the same path.
Reusable form actions use `DialogActions` to stay in the fixed modal footer, or
render inline when the form is embedded in a page. `CronForm` registers its persisted-draft guard through `DialogCloseContext`, so
all close requests use its confirmation and clear the saved draft only on discard.

Set `busy` synchronously before awaiting a mutation; also guard the handler itself.
Keep the view, input and actionable error on failure. Never intercept unmodified
Enter globally, textarea Enter, or IME composition. `NameDialog` uses native form
submission and checks composition. Native form selects retain their change semantics.

## Add or change an overlay

1. Choose the primitive above and pass business data/callbacks.
2. Keep state and API requests in the caller. Supply dirty/busy/error/disabled state.
3. Add the example to the executable gallery if it introduces a new visual family.
4. Test parent/child focus and dismissal, disabled choices, failed requests and retry.
5. Run `pnpm build`, relevant Vitest tests, and
   `pnpm exec playwright test --config=playwright.overlays.config.ts`.
6. Review both themes and 390px layouts. Update reference screenshots intentionally.

The gallery uses test data only. Installed-app acceptance uses existing records and
cancels Rename, deletion, provider, SSH, cron and project forms. It must not delete
real data, save credentials, submit authentication or replace existing drafts.
