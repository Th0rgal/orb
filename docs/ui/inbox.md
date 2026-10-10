# Inbox presentation

Run `pnpm exec playwright test --config=playwright.inbox.config.ts` from `orb/`
for the dedicated Chromium/WebKit checks. Committed visual references are macOS
captures and are compared by this configuration on macOS. The general browser
suite and Linux runs retain every behavior assertion without comparing against
another platform's font rendering.

The Inbox uses separate rounded message cards with a quiet border, neutral selected rows,
13px content, a 15px title, and 28px controls. `orb/src/Inbox.css` owns its layout
and reuses the surface, control radius, focus and theme tokens from the
[overlay contract](overlays.md). Filters use an underline for the current view
and a quiet filled background for the current project. Status colors describe
agent state; routine actions remain neutral.

Message cards use the shared 12px corner radius and 8px spacing. Hover,
selection, preview and the inset keyboard focus border follow the same rounded
surface. Individual action controls retain the shared control radius.

Keep the saved conversation title unchanged, using the same `displayTitle` as
its header. The Inbox must never substitute a generated headline, rewrite a
renamed title, or truncate its stored text. CSS may ellipsize the visible row.

A quiet source label distinguishes `AI summary` from an extracted `Latest
update`. The v7 digest contains a one-sentence mission context, optional context details, a short result, an optional unresolved issue,
an optional user decision, and up to two explicit reply drafts. It never
creates a title. Summaries describe recorded claims, not independent
verification. Their source excerpts must match the supplied message snapshot;
the optional Sources disclosure opens the original transcript. Only an exact,
current digest may supply decisions, unresolved issues, suggestions or sources.
Older cached summaries can keep the result visible during refresh.

Peek starts with a one-sentence `Context` above the AI summary: what the mission
is about, using its objective and user requests, not a generic latest "status?"
message. It never replaces the saved title. The context disclosure starts closed
and expands to optional scope details and the latest request. Without a current
digest, use the extracted mission objective/request as a clearly labelled context.
The result follows, then any unresolved issue and concrete `To decide` input.
Sources are secondary evidence, closed by default below the conversation toggle;
opening a source reveals and highlights the matching transcript passage.
The original `Original conversation` is folded by default, and expands for
live replies or on request. Suggested replies show their full text and only
append to the draft; they never submit or run operations. The `Suggested actions`
row also offers `Mark done & archive` (the existing archive operation with Undo)
and `Delete…` (the shared sidebar confirmation and deletion pipeline). These
are explicit product controls, never LLM-generated operations. Only deletion
uses a subtle red treatment. Disable both while the mission is running or a
mutation is pending; deletion still rechecks live state in the existing workflow. Do not restore the
old generic chips with hidden extra instructions such as opening a PR.
Suggested actions display number badges (1–9) in their visual order. Outside editable
fields, a number activates that same button on the focused, open card; disabled
actions stay disabled and deletion still opens confirmation. Pending permission
questions retain their own number keys. Typing after T inserts digits into the
composer without invoking an action.
Avoid duplicate total counts, goal badges and
nested card borders. The compact settings icon retains the current AI model
in its accessible label and tooltip.

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

The active row title is the list's single Tab entry; its actions follow it.
Down/Up or J/K move actual focus between rows, Home/End reach the first/last
row, Space toggles the selected preview and closes any previous one, T focuses
the follow-up in an open preview, R replies and
Enter opens the thread. In the follow-up, Enter sends and Shift+Enter adds a line. Down from a filter
enters the first row. While Inbox is visible, Space from the sidebar returns to
the last focused row (or the active filter when empty) without opening its
preview and dismisses the overlay sidebar on narrow screens; Enter still activates
the sidebar destination. Closing Peek returns focus to the row without scrolling;
marking it done advances focus. Opening a different preview, by keyboard or
mouse, preserves each conversation’s draft and keeps only one preview open.
Leave native disclosure keys, text selection,
textarea movement, IME and child overlays alone.

Do not add opacity entrance animations to Inbox rows. They must paint even
when opened in a background macOS WebKit window. Long summaries are bounded
in the list and expand in Peek; the original content remains in the conversation preview. The
preview context wraps, and its transcript scrolls independently.

## Verification

Run from `orb/`:

```sh
pnpm build
pnpm exec vitest run tests/inboxModel.test.ts tests/inboxDigest.test.ts tests/missionCache.test.ts tests/skills-settings.test.tsx tests/composer-draft-lifecycle.test.tsx tests/composerDrafts.test.ts
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

Inbox defaults to agents started directly by the operator. Child/callback missions
and Hermes-origin missions (including legacy origin tags and missing controller
session IDs) are excluded before classifying pending interactions. Their failures
also do not make a read parent unread or urgent by themselves. Settings → Inbox →
Include autonomous agents opts into those updates, with the same scope applied to
the list, unread count and background digest prefetch. Existing settings without
the preference default to off. Child details remain available from their parent.

Server-scheduled provider recovery stays in Working with a neutral `Recovering` badge. It is not ready for review and does not expose an extra Retry action while a retry is already scheduled. A live permission question still takes priority.
