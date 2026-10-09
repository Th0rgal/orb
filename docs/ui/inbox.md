# Inbox presentation

The Inbox uses a continuous list with thin separators, neutral selected rows,
13px content, a 15px title, and 28px controls. `orb/src/Inbox.css` owns its layout
and reuses the surface, control radius, focus and theme tokens from the
[overlay contract](overlays.md). Filters use an underline for the current view
and a quiet filled background for the current project. Status colors describe
agent state; routine actions remain neutral.

Keep the triage model and operations in `Inbox.tsx` / `inboxModel.ts` unchanged
when adjusting presentation. In particular, viewing or replying must not drop
a row from under the user, running agents remain behind the working toggle,
and unread state, undo, pending operations and saved composer drafts retain
their existing semantics. A fast-close guard flushes typed composer content even
if IndexedDB hydration has not completed; reads also see pending writes so
reopening cannot restore an older value. Closing an untouched composer before
hydration must never erase its saved draft.

The title and row actions share stable grid space on desktop: hover must not
move or truncate the title differently. At narrow widths, actions move onto
their own line and remain visible. A focused control also selects its row for
keyboard triage. The filter tabs use Left/Right, Home/End and roving Tab focus;
project filters expose their pressed state. Peek remains an inline region,
uses the shared Transcript and Composer, and delegates child overlays to the
shared layer manager.

Do not add opacity entrance animations to Inbox rows. They must paint even
when opened in a background macOS WebKit window. Long summaries are bounded
in the list; their full content remains in the conversation preview. The
preview context wraps, and its transcript scrolls independently.

## Verification

Run from `orb/`:

```sh
pnpm build
pnpm exec vitest run tests/inboxModel.test.ts tests/missionCache.test.ts tests/skills-settings.test.tsx tests/composer-draft-lifecycle.test.tsx tests/composerDrafts.test.ts
pnpm exec playwright test --config=playwright.inbox.config.ts
```

The browser configuration runs Chromium and WebKit. The existing triage and
rich-transcript tests cover interactions, replies, archive/undo, images,
attachments, and scroll retention. `tests/inbox-ui.browser.spec.ts` adds light
and dark references for the list, empty state and preview, including 390px,
stable hover geometry, keyboard filters, row focus and draft restoration.
Only update reference PNGs after visually reviewing the changes.

For installed verification, open Inbox in the candidate build, inspect its
list, switch filters, expand working agents and open/close Peek. Do not send
messages or mark real conversations done merely to validate appearance.
Record the installed source hash and bundle identity separately from browser
fixtures; fixtures do not prove installed behavior.
