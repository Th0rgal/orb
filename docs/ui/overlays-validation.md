# Overlay migration validation

## Scope and source

Implementation checkout: `/Users/thomas/work/paloma/sandboxed_sh-overlay-system`.
Branch: `feat/orb-overlay-system`, based on `960b656f`.
The marketing checkout `/Users/thomas/work/orb` and the active development checkout
`/Users/thomas/work/paloma/sandboxed_sh` were not edited by this work.
Desktop/web only; backend APIs and native iOS/Android were not changed.

The overlay contract and executable examples are in [overlays.md](overlays.md).
The message editor shares the compact controls, neutral send action, dark field
surface, and uninterrupted action row. Reference captures are in
`orb/tests/overlays.browser.spec.ts-snapshots/` (Chromium and WebKit, both themes).

## Automated checks

- TypeScript `tsc --noEmit` and Vite production build pass.
- Full Vitest run: **946 passed, 3 failed, 3 skipped** (952 tests), including
  pointer/ancestor focus restoration and pending-tooltip Escape regressions.
  The three failures reproduce in an untouched checkout of `960b656f`:
  `history-pagination.test.ts` speculative read bound, and the two
  `local-origins.test.ts` archive/deletion reconciliation cases. They are not
  overlay regressions. Logs: `/tmp/orb-overlays-units-verified.log` and
  `/tmp/orb-overlays-baseline.log`.
- Full browser run: **205 passed, 2 failed, 1 skipped** (208 scenarios).
  The two failures match the untouched-base transcript/queue cases described
  below; the skipped scenario requires an explicit production opt-in.
  Log: `/tmp/orb-overlays-complete-final.log`.
- Gallery: **16 passed**, with **32 reference captures**. Log: `/tmp/orb-overlays-final-gallery.log`.
  This separate gallery configuration was run explicitly on macOS with Chromium
  and WebKit; its committed image baselines are macOS captures. The ordinary
  browser suite and the gallery are distinct commands (see `overlays.md`).
- Focused form, keyboard and file-panel unit checks: **65 passed**.
  WebKit file/search follow-up: **7 passed**.
  Final Rename/sidebar unit follow-up: **16 passed**; WebKit sidebar, routed
  selection and Rename browser follow-up: **11 passed**.
- The gallery verifies both themes, 390px width, long titles, initial focus,
  Tab/Shift-Tab, parent/child Escape, submenus, draft discard, a slow failed
  save and retry, single submission, disabled options, loading, empty/error
  states, search and active versus committed selection.
- The focused WebKit file-panel check verifies that Escape dismisses a modal
  without restoring/closing the maximized file panel beneath it. The gallery
  also checks that the Find bar stays open while Escape closes its picker.

Stale Hermes browser assertions were also reproduced on the untouched base:
its action spy counted the existing `/opened` tracking calls as user actions,
and its cron delete tests expected a removed view to stay on screen. The tests
now ignore tracking calls and assert that the deleted row and confirmation close.
Logs: `/tmp/orb-overlays-baseline-browser.log` and `/tmp/orb-overlays-baseline-extra.log`.
The machine-load fixture also counted completed/archive reads as its active
mission fetch; the untouched base performs four total reads. It now distinguishes
those endpoints and still asserts that opening the picker makes no additional requests.

The untouched base also fails the transcript DOM benchmark (300 work groups,
expected fewer than 40) and the queue/checklist scenario (it waits for an absent
`Tasks` button). The other 14 scenarios in that baseline run pass. Evidence:
`/tmp/orb-overlays-baseline-last.log`. The editor geometry test now checks the
intentional 16px content inset while continuing to assert that opening or growing
the editor does not move the bubble or its scroll anchor.

## Native acceptance

The verification build uses the separate bundle ID `md.thomas.orb.overlays` and
application name **Orb Overlays**. It does not replace or restart `/Applications/Orb.app`.
Native packaging verifies the copied executable before signing, signs the sidecar
before the outer bundle, and runs `codesign --verify --deep --strict`.
Build provenance and checksums are recorded in `overlays-native-receipt.json`.

The installed application was exercised through the native accessibility tree and
screenshots, connected to the existing backend:

- Project creation: entered a temporary name; Escape opened the confirmation with
  `Keep editing` focused; returning preserved the name; discarded only that new draft.
- API key: initial focus on the name, opened the provider select, moved its active
  option, then Escape kept the selected provider and parent form. A second Escape
  closed the untouched form and restored the `Add API key` trigger. No key entered.
- SSH: entered a temporary name; Escape opened confirmation; another Escape
  restored the form and name; cleared that temporary name and cancelled. No SSH
  connection, probe, or save was performed.
- Agent deletion: confirmation focused `Cancel`; Escape closed it and the same
  agent remained in the tree. No deletion was submitted.
- Fork menus: opened harness then model submenus; three successive Escape presses
  returned one level at a time and then closed the root. No fork was submitted.
- Cron: initial draft was empty. A temporary name survived `Keep editing`; Cancel
  used the same confirmation. Discarded only this newly created test draft.
- Message editor: opened an existing prompt, visually checked the uninterrupted
  toolbar and round send action, then Escape cancelled without sending.

This pass exposed a false dirty-state prompt on an untouched Rename form. The
caller published its target before its initial value, mounting `NameDialog` with
the previous value. Initialization now completes before the target is published,
for agent/project rename and file rename/move. The WebKit sidebar test checks an
untouched close, reopening, then a real rename with scroll preservation.
It also requires focus to return to the exact originating row. WebKit's fallback
focus on a containing region no longer replaces that pointer target. A pending
row tooltip is cancelled when an interactive overlay opens, so it cannot steal
the modal's first Escape key.

The final rebuilt/signed application was reopened from `/Applications/Orb Overlays.app`
(foreground PID 45913). Rename closed directly without changes; ArrowDown then
focused the next agent row, confirming keyboard navigation resumed at the original
row. The other native flows above were checked before these initialization/focus
follow-ups, and their shared behavior was covered again by the final automated
suite. All 13 focused dialog regressions pass. No prompt, credential save, fork,
real deletion, or existing draft discard was submitted.
