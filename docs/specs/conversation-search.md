# Global conversation search — specification

Status: implemented (Core SQLite FTS5 + Orb desktop; mobile follow-up tracked below).

## Problem and inspected behavior

The desktop titlebar Search button in `orb/src/App.tsx` has no click handler,
and the app keyboard handler has no Command-K binding. Core has mission search
and moment-search endpoints, but these are not a complete content-search engine:

- Cross-mission moment search scans up to 2,000 missions and reads `Mission.history`.
- SQLite mission lists deliberately return empty histories. Fetching each full
  mission would still load only its most recent 200 messages and would add an
  expensive query loop.
- Ordinary mission search scans up to 10,000 records and may stop once enough
  matches have been found. This cannot guarantee coverage or global relevance.
- Moment results identify entries by array offset rather than a durable event
  identity, which is unsuitable for navigating into paged, changing history.

Do not wire the new dialog to those scans and present it as exhaustive search.

## Interaction contract

The titlebar button, Command-Shift-F on macOS, Control-Shift-F elsewhere (plus
Command-F / Control-F when focus is inside `#orb-sidebar`), open one search
surface. Command-K / Control-K is reserved for opening and focusing the `/btw`
side-question panel. The shortcut works from the composer without sending or changing its
draft. Respect IME composition and higher-priority modal interactions. When search
is already open, the shortcut focuses its input rather than opening another copy.

Use the existing overlay/focus infrastructure. Open immediately with the input
focused and recent conversations available. Escape closes and restores focus.
Arrow keys select results, Enter opens the selected hit, and pointer selection
updates a preview without navigating away. Preserve the current conversation and
scroll position until the user explicitly opens a result.

The desktop surface follows the supplied reference: a generous centered dialog,
a prominent input, quiet filter chips, compact result rows on the left, and a
message-context preview on the right. Each row shows a title, project, date, and
highlighted excerpt. Use existing Orb typography, theme tokens, radii and spacing.
Support light/dark themes, reduced motion, keyboard operation, and narrow windows;
on narrow layouts, show the preview as a second view instead of squeezing columns.

Default scope includes active and archived conversations visible to the current
user on the selected backend. Offer project, date, and message-role filters and
relevance/recent ordering. Show multiple matching passages grouped by conversation
without allowing a long conversation to monopolize the first page.

Empty, loading, failed, disconnected, and still-indexing states are distinct.
Preserve result dimensions during loading. Do not label incomplete indexing as
"no results". Cancel obsolete requests and reject late responses after a query,
filter, backend, or account change. Do not persist raw queries in telemetry.

## Search architecture

### Canonical documents and ownership

Add a rebuildable search projection to each user's existing SQLite mission store.
Use stable document identities: mission UUID plus canonical event/message ID (or
persisted sequence where no message ID exists). Cloud-turn projections need
stable turn/message keys too. Titles and metadata may have a dedicated document
per conversation; do not duplicate the entire conversation into every result.

Index the persisted visible transcript, including old and archived messages.
Reuse canonical event folding so streamed fragments, finalized messages, retries,
and replacement/canonical messages do not produce duplicate or stale hits.
Resolve spilled `content_file` text when indexing, not on each query. Cover
cloud prompts/results through their persisted canonical source rather than the
limited synthesized `Mission.history` field.

User and assistant text is the primary search corpus. Decide and document which
visible tool outputs are included, with a filter to reduce tool-output noise.
Hidden internal state and credentials are not searchable content. Attachment-body
extraction/OCR is a separate capability and must not be implied by text search.

Core enforces ownership before retrieval and again before returning preview data.
Indexes and query caches must not cross backend/account boundaries. Mission
removal, message edits, replacement, and permission changes must remove or update
the corresponding projection. Search results never grant access by themselves.

### Lexical retrieval first

Use SQLite FTS5 with Unicode-aware tokenization, prefix queries, weighted BM25
ranking, and snippets around the actual match. Exact title/identifier matches
should rank strongly; recency should break close ties rather than bury older exact
matches. Handle punctuation and code/UUID searches deliberately; do not pass raw
user text as unchecked FTS syntax. Evaluate typo/substring support separately.

Return a compact hit contract: conversation identity/title/project/date, stable
message locator, role, excerpt, plain-text highlight ranges, and pagination cursor.
Return index coverage/version separately. Do not serialize whole Mission objects
or histories for each hit. Render highlights as escaped text segments, not raw HTML.

Keep one Core search service/store interface and migrate existing callers to it
where contracts overlap. Reuse the repository's SQLite/FTS conventions; avoid a
second external database or independently owned copy of conversation state.

### Incremental maintenance and backfill

Create the schema quickly, then backfill in bounded, restartable batches outside
startup and request latency. Persist a versioned watermark and reconcile writes
that occur during backfill. New committed messages and canonical replacements
update the projection through the existing persistence boundary. Do not rebuild
the index on startup, per query, or for every streaming token.

Make concurrent create/edit/delete operations, interrupted backfills, index
rebuilds, and large spilled messages explicit test cases. The projection must be
reconstructible from authoritative data. Measure write overhead, index size,
backfill throughput, and interactive latency while indexing is active.

### Exact-message navigation

Add a bounded context lookup around a durable message locator. Opening a hit must
load the needed history window even when it is far beyond the latest 200 messages.
Use the existing transcript projection and pinned-scroll owner to reveal and
briefly highlight the matched message. Do not add a competing scrollTop writer.
If a result was edited or deleted since the query, reconcile visibly and keep the
conversation usable. Fetch preview context only for the selected result.

### Optional semantic phase

After evaluating lexical relevance, add semantic retrieval only for demonstrated
meaning-based misses. Embed canonical message/turn chunks asynchronously, cache
by content hash plus model version, and retain the same ownership/deletion rules.
Combine lexical and semantic ranks while preserving strong exact identifier/code
matches. Embedding outages or lag must not disable lexical search. Measure the
quality gain, latency, storage, inference cost, and multilingual behavior before
choosing a model or introducing a vector service.

## Delivery and verification

1. **Index and API:** specify the result/locator contract, implement canonical
   indexing and resumable backfill, replace scan-based retrieval, add context
   lookup, and test authorization, deletion, and all-history coverage.
2. **Desktop dialog:** wire button and shortcut to one lazy-loaded component,
   implement results/preview/filters/navigation, and add keyboard and browser
   replay tests using delayed and reordered responses. Document the desktop-to-
   mobile gap; mobile follow-up must ship equivalent iOS and Android behavior.
3. **Relevance refinement:** evaluate recorded test queries and add typo or
   semantic retrieval only where measured failures justify it.

Use a realistic synthetic corpus of at least 12,000 conversations and 200,000
message records, including archived histories and messages older than the current
API windows. Initial targets, to be measured rather than claimed in advance:

- Dialog visible and focused within 100 ms, independent of network availability.
- Warm indexed Core query p95 under 200 ms for the benchmark corpus.
- End-to-end results target under 400 ms on a defined connection, with debounce
  and network time reported separately.
- No stale results after query/account/backend changes; no inaccessible results.
- Correct passage navigation beyond 200 messages and beyond 2,000 conversations.
- Correct incremental replacement and deletion, and restart-safe backfill.

Record cold/warm timings, corpus and hardware details, memory/index size, and
write-path overhead. Test both themes, narrow windows, keyboard-only operation,
IME input, escaped markup, disconnection, failures, and index-in-progress states.

## Measured verification & platform parity notes (2026-10-29)

### Synthetic benchmark (`api::mission_store::sqlite::search_tests::search_benchmark_12k_conversations_200k_messages`)

- **Corpus**: `12,000` conversations (`25%` archived `acknowledged`, `25%` `completed`, `25%` `awaiting_user`, `25%` `active` across 6 projects) and `204,000` persisted `mission_events` message records (`216,000` FTS5 documents including per-conversation `title` documents).
- **Hardware & build profile**: Apple Silicon Mac (`16 GB` unified memory, macOS), `cargo test` (`unoptimized` debug profile with `CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0`).
- **Store open (schema DDL + FTS5 rank config)**: `73.40 ms` (non-blocking; resumable background backfill runs asynchronously in bounded 50-mission batches).
- **Full backfill throughput**: `34.46 s` (`5,920 msgs/s`), followed by FTS5 segment optimization.
- **Storage**: `109.72 MB` raw SQLite DB → `318.20 MB` indexed DB+WAL (`+208.48 MB` FTS5 + `mission_search_docs` projection with `prefix='2 3'`).
- **Query latency (60 warm queries across exact identifiers, code paths, quoted phrases, Unicode diacritics, project filters, and `Relevance`/`Recent` sorts)**:
  - Cold first query (`DeepArchiveBeacon_X99` at conversation `#11,990` beyond 2,000-mission window): `2.86 ms`
  - Warm query `p50`: `19.87 ms`
  - Warm query `p95`: `161.21 ms` (within `< 200 ms` target even in an unoptimized build)
  - Warm query `p99`: `165.22 ms`
- **Incremental write overhead**: `0.535 ms/msg` average per committed message (`log_event`).
- **Desktop dialog open latency (`orb/tests/conversation-search.browser.spec.ts`)**: `7.6 ms` (`SEARCH_DIALOG_OPEN_MS`, well within `< 100 ms`), independent of network availability (`180 ms` typing debounce; network fetch measured separately).

### Tool-output indexing policy, in-conversation Find (`Cmd+F`), & mobile parity gap

- **Final-messages-only corpus (both `Cmd+K` global search and `Cmd+F` in-conversation Find)**:
  - Default message search indexes **only** genuine user prompts and final agent answers (`[data-find-message]` in the DOM and top-level `user` / `text` items in `Transcript.tsx`).
  - Reasoning traces (`ThinkBlock` / `ThinkFold`, whether collapsed or sticky-open), intermediate assistant narration bubbles folded before work tool calls (`WorkFold` / `narrationKeys`), tool rows/arguments/outputs (`ToolRow`, `OrchestrationCard`), task checklists, `/btw` activity/narration rows, and automatic coordinator wakeups/recovery/resume prompts (`background-task`, `scheduler`, `idle-worker-watchdog`, `transport_auto_resume`, `remote-build-terminal`, `task-board`, `[Automatic recovery]`, resume prompt) are **excluded** from message search.
  - Raw `tool_result` stdout and shell command lines are **never** indexed (preventing secret/log noise leakage). In global search (`Cmd+K`, schema `v2`), safe file/URL targets extracted from `tool_call` arguments (`Path`, `file_path`, `url`, etc.) remain folded into a bounded per-turn `role = "tool"` document (`<= 4 KiB`), excluded by default (`include_tools = false`) and opt-in only via the `Tools` filter chip.
- **In-conversation Find (`orb/src/FindBar.tsx`, `Command-F` / `Control-F`)**:
  - Cursor-style floating Find widget: single recessed `.find-field` with borderless `<input>` (no inner focus halo) and inline Match Case (`Aa`, `⌥⌘C` / `Alt+C`) and Whole Word (`[ab]`, `⌥⌘W` / `Alt+W`) icon toggles, fixed-width tabular `.find-count` (no horizontal jump when typing), and Previous/Next/Close actions (`Enter`, `Shift+Enter`, `⌘G`/`⇧⌘G`, `F3`, `Esc`).
  - Seeds query from single-line selection inside the target scroller on open; selects the first match in or below the current viewport (or nearest match above when scrolled past all matches) and preserves the active match across streaming deltas and history prepends without scroll hijacking.
  - Hydrates older conversation history via a single lightweight `view=transcript` spine fetch (`prepareTranscriptSearch` in `orb/src/missionCache.ts`) without paging raw tool-call history or blocking live match counts behind `"Searching history…"`.
  - Paints both passive (`::highlight(orb-find)`) and active (`::highlight(orb-find-current)`) CSS Custom Highlights without mutating SolidJS DOM nodes or expanding collapsed `WorkFold`/`ThinkBlock`/`<details>` disclosures, and scrolls via `markScrollIntent` to the exact matched `Range` with clearance below `.find-bar`.
- **Mobile parity gap**: Core endpoints (`GET /api/control/missions/search` and `GET /api/control/missions/:id/context`) and UTF-16 highlight/locator contracts are shared and backend-ready; Orb desktop ships `<SearchDialog>` (`Command-K` / `Control-K`) and `<FindBar>` (`Command-F` / `Control-F`), while equivalent iOS (`ios_dashboard`) and Android (`android_dashboard`) global search sheets and in-conversation Find bars remain a follow-up.

Reference: https://www.sqlite.org/fts5.html
