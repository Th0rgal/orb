# Inbox UI validation — 2026-10-09

The change replaces the card-based Inbox layout with a compact continuous list,
reuses the overlay theme tokens, and keeps the existing triage operations. The
inline preview uses the shared transcript and composer. An early-close draft
race found during validation is covered by regression tests.

The refinement removes redundant goal badges, counts and nested card borders;
keeps the list to title and result; and puts optional request/goal context behind
a native disclosure. Rows now have roving Tab entry, actual focus movement with
arrows/J/K and Home/End, and focus restoration after closing Peek.

## Automated checks

- TypeScript (`tsc --noEmit`) and Vite production build: passed.
- Inbox Playwright suite, Chromium and WebKit: 16 passed, 2 intentionally skipped
  opt-in production tests. Covers triage, preview, archive/undo, reply, scrolling,
  keyboard filters, project filters, row focus, native disclosure keys, draft restoration, long content,
  light/dark themes and 390px layouts.
- Targeted Vitest (Inbox model, mission cache and composer drafts): 26 passed.
- The preceding `7eecdf635` validation also ran the overlay browser suite
  (16 passed), Skills settings browser check (1 passed), and full Vitest suite
  (949 passed, 3 skipped, 3 failed in 2 files). These broader suites were not
  repeated for this Inbox-only refinement. The baseline failures are below.
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

The latest refinement was checked with live data: the compact list painted,
Down from the filter focused the row title, Space opened Peek with context
collapsed, R placed the caret in the reply composer, and Escape restored title
focus. No draft was edited or message sent. Only one actionable live row was
available; cross-row navigation was verified in the browser fixtures.

The preceding installed build also verified the project filter and draft
restoration after Escape/reopening, then cleared the verification text. The
latest app was left on Unread with no open preview, and the existing background
context worker was retained.
