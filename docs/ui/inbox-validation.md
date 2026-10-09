# Inbox UI validation — 2026-10-09

The change replaces the card-based Inbox layout with a compact continuous list,
reuses the overlay theme tokens, and keeps the existing triage operations. The
inline preview uses the shared transcript and composer. An early-close draft
race found during validation is covered by regression tests.

## Automated checks

- TypeScript (`tsc --noEmit`) and Vite production build: passed.
- Inbox Playwright suite, Chromium and WebKit: 14 passed, 2 intentionally skipped
  opt-in production tests. Covers triage, preview, archive/undo, reply, scrolling,
  keyboard filters, project filters, focus, draft restoration, long content,
  light/dark themes and 390px layouts.
- Overlay Playwright regression suite, Chromium and WebKit: 16 passed.
- Skills settings browser regression: 1 passed.
- Full Vitest suite: 949 passed, 3 skipped, 3 failed in 2 files. The failures are
  the existing baseline failures below; the 3 new draft tests pass.
- `git diff --check`: passed.

The full unit suite is not green. Its unchanged failures are:

1. `history-pagination.test.ts`: "bounds speculative reads while an opened
   conversation loads immediately" expects 2 reads and receives 3.
2. `local-origins.test.ts`: "learns about an archive the default list leaves out,
   and keeps an emptied title" does not retain the expected archive/title state.
3. `local-origins.test.ts`: "retires a synchronized local mission once Core
   confirms 404 or explicit deletion" does not set the expected deletion flag.

These same failures were reproduced on the untouched pre-overlay baseline during
the preceding overlay work. No pagination or local-origin logic is changed here.

Reference PNGs live in
`orb/tests/inbox-ui.browser.spec.ts-snapshots/`. Desktop and 390px light/dark
references were visually reviewed, including the visible mobile row actions.

An intermediate full browser run timed out after the rich preview disappeared
across its polling check in Chromium. Four isolated repeats with tracing (two
per browser) and the subsequent full traced run all passed. The intermittent
failure's cause is unconfirmed; the final successful run does not establish
that it is fixed.

## Native acceptance

The separately installed `/Applications/Orb Overlays.app` is the verification
candidate. `/Applications/Orb.app` remains unchanged. Build origin, executable
hashes, signature verification and backups are recorded in
[`inbox-native-receipt.json`](inbox-native-receipt.json).

Native acceptance uses existing Inbox data, filter changes, working-agent
expansion and inline preview. It does not send messages, retry agents or mark
conversations done. Browser fixtures exercise those mutation paths against
mocked APIs.

The final installed build was checked with live data: rows painted correctly,
the project filter and Peek worked, and an initially empty composer preserved
a verification draft after Escape and reopening. The verification text was
cleared afterwards. The app was left on Unread / All projects with no open
preview, and the existing background context worker was retained.
