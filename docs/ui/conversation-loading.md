# Conversation loading and cached presentation

The readable conversation and current activity must not wait for tool history.
Desktop, iOS and Android share these invariants:

- Account, mission and run identity scope every cached value and live update.
- A partial snapshot never erases complete history. When catching up from a stale
  `since_seq` cursor exceeds two forward pages (`> 400` raw events) and jumps to
  the latest `200`-event tail, cached `spineAnswers` from earlier turns are
  retained and `{ before_seq, view = "transcript" }` hydrates any conversational
  gap before `nextCursor` whenever the tail lacks a delivered `user_message` or
  skipped forward pages; only an explicit server `reset` clears prior history.
  Late disk/network reads do not overwrite newer revisions. Completion cannot be
  undone by an old action.
- Show cached content while refreshing; loading is distinct from execution.
- One activity area owns the current turn. A known action replaces the generic
  working label in place; historical work counts do not add a second status row.
- Latest durable answers load before detailed tool history. Partial previews
  never become pagination cursors or complete inputs to Inbox summaries, and
  merging an offscreen presentation preview ahead of a stale raw `cursor` marks
  the mission dirty for raw catch-up on reopen.
- Currently active/live missions and recently opened foreground conversations
  (up to 12 parent missions ordered `focusedIds → liveIds → recentIds` plus each
  warm mission's active `/btw` child mission) stay live over the single
  multiplexed `/api/control/sync` WebSocket (`max_payload = 4096`) when
  **Background sync** resolves to active (`On` or `Auto` on a healthy link),
  rendering on open with zero HTTP round-trips. Per-mission `stream_lagged`
  frames (`mission_id` present when a single mission's `since_seq` exceeds the
  500-event replay window) recover that mission locally without tripping global
  link-quality backpressure; only socket-wide `stream_lagged` frames pause
  **Background sync**. When **Background sync** is `Off` or `Auto` pauses on a
  slow/Data-Saver link, unfocused subscriptions detach immediately while
  preserving cached transcripts, `/btw` turns, and `since_seq` cursors; clean
  missions without intervening `mission_presentation` hints reopen without
  redundant metadata or `/btw` crawls. Mobile suspension uses resume
  reconciliation rather than relying on background sockets.
- Images already read reuse a bounded, account/mission-scoped cache. Concurrent
  consumers share reads; failures are retryable; scope changes reject late loads.
  Mutable workspace images must expire or be invalidated when the mission changes.
- Existing scroll ownership remains authoritative. Hydration must preserve the
  reader's anchor. `--scroll-reserve` holds collapsed narration height only
  while the reader's anchored element or turn row stays connected in the DOM;
  a snapshot replacement that disconnects the anchor clears the reserve so no
  blank scroll void remains below the conversation. Upward pagination hydrates
  missing `{ view = "transcript" }` spine rows when a raw `before_seq` batch
  contains only folded tool events, and upward wheel/key input at `scrollTop = 0`
  loads older history even when the loaded tail fits within the viewport height.
  Skeletons represent only missing content; reduced motion works.

## Regression scenarios

Replay summary before events, preview before raw tail, completion before stale
activity, offscreen automatic-recovery completion reopened from a pre-recovery
snapshot, disk after network, switch-account during image load, concurrent image
mounts, reopen offline, filtered-stream cross-mission events, stream reconnect,
and pagination after a partial preview. Measure first readable paint separately
from full hydration and report actual payload sizes and foreground bandwidth.

## Implementation and budgets

`GET /api/control/missions/:id/open?limit=150&max_payload=8192[&since_seq=N]` is
the single-roundtrip cold/catch-up conversation open bundle across Desktop, iOS,
and Android. In one response (`protocol = 1`, `Accept-Encoding: gzip` over
HTTP/1.1 keep-alive) it returns `mission`, the `events` raw tail (or `since_seq`
delta), `spine` (`user_message` / `assistant_message` conversational spine when
`since_seq` is omitted and `has_more` is `true`, eliminating separate
`view=transcript` and `before_seq` roundtrips), and `queue` (seeded directly into
follow-up queue state with zero extra `/api/control/queue` poll on open). Older
servers returning `404` transparently fall back to the split endpoints per
`(endpoint, backendVersion)`.

`GET /api/control/missions/:id/snapshot?profile=presentation` explicitly selects
one latest durable assistant message plus a three-event conversational tail,
with a raw event watermark. No tool payloads or aggregate history counts are
loaded. Optional actor activity enrichment has a 100 ms deadline. The ordinary
events endpoint checks existence/status through metadata, not full history.

`/api/control/stream?profile=presentation&kinds=mission_presentation` carries
bounded hints, never tool arguments/results or text deltas. The kinds parameter
makes older servers safely send no mission payloads. Activity labels are capped
at 160 characters and throttled to one per second per mission per connection.
Terminal and attention hints trigger coalesced roster refresh and recent-answer
prefetch. At most 12 recently opened conversations are eligible; mobile drains
three refreshes per cycle. Existing polling remains the compatibility fallback.

Desktop downloaded images and upload previews share a 48 MiB encoded-memory LRU;
iOS and Android bound decoded images at 32 MiB and downsample to 2048 px. All three platforms
share concurrent reads. Mutable images expire within five minutes;
desktop also scopes them to mission revision. Decoded/upload image caches are in-memory; native workspace files retain their existing account-scoped disk cache, while
native presentation/history caches survive restarts. No cache is an archive.

Scroll event ordering matters: HTML dispatches queued `scroll` events before
`ResizeObserver` callbacks, so a layout shrink or column widening can clamp the
browser before `ResizeObserver` runs, and an earlier corrective bottom scroll can
arrive after the next frame's narrowing or viewport-height shrink. These are not
new reader intent (`scrollEvent` in `lean/Orb/Scroll.lean` and `scrollPolicy.ts`):
passive `scroll` events during geometry changes never unpin a following reader,
the scroller's own viewport box is observed alongside its content column and dock,
and an unpinned scroll owner restores the old anchor before remembering the
viewport. `scroll-anchor.browser.spec.ts` and `scroll-contract.browser.spec.ts`
replay narration collapse, stale-cache enrichment, frame-by-frame narrowing,
widening-plus-height-shrink, and side-panel divider drags across both the main
and `/btw` side conversations.

Raw backfill is always sequence-sorted and deduplicated before reduction, including when a complete cache has newer presentation events beyond its raw cursor. Roster reads may only supersede an already applied newer response; a newer pending request does not invalidate useful completed data.

## Native transcript parity

Native clients fetch the sequenced conversational rows (user, assistant, canonical
assistant) separately from the raw tool tail, using the existing events endpoint.
`OrbConversationHistory` owns their merge on iOS and Android. Identified rows merge
by sequence, retaining repeated identical messages and chronological order. Legacy
unsequenced caches may only append events after a known overlap; an unanchored tail
cannot append old prompts below newer answers. Queued prompts and unsuccessful
assistant events are not delivered conversation rows. A failed conversation read
retains the cached conversation. Tool-only refreshes must also rebuild conversation
messages when their batch contains an answer. Canonical answer notifications trigger
the same refresh as ordinary answers. Shared `conversation-history.json` fixtures
replay stale history followed by several user/assistant pairs, old tails, repeated
prompts, canonical answers, queued messages, and out-of-order event delivery.

Android continuation caches can contain several missions. Both conversation and
raw-event cursors are calculated only from rows belonging to the requested mission;
an ancestor sequence of 1000 cannot skip a continuation at sequence 20.

Canonical bubble IDs and revisions survive in the stored conversation. Rendering
replaces stale bubble revisions and suppresses the ordinary terminal receipt when
it repeats the native bubbles, matching desktop. Storage retains that receipt so
the incremental cursor still advances. Legacy overlap must reach the final stored
row; matching an earlier repeated prompt is not sufficient.

## Warm background sync and low-bandwidth policy

Desktop (`orb/src/backgroundSync.ts`), iOS (`OrbBackgroundSync.swift`), and
Android (`OrbBackgroundSync.kt`) share one per-device **Background sync** policy
(`Auto` | `On` | `Off`, default `Auto`) in `Settings → Account`, verified against
`shared/orb-spec/fixtures/background-sync-policy.json`:

1. **`Auto` link-quality state machine (zero synthetic probes):**
   - Evaluates passive OS flags (`navigator.connection.saveData` / `2g` /
     `downlink < 1 Mbps`, iOS `NWPathMonitor.isConstrained`, Android Data Saver /
     `linkDownstreamBandwidthKbps < 1000`) plus `/api/control/sync` WebSocket
     `ping` → `pong` RTT, `stream_lagged`, and unexpected reconnects.
   - **Trips immediately (`active = false`)** on OS Data Saver / constrained link,
     `stream_lagged`, ping timeout, `>= 2` unexpected disconnects within `60 s`,
     or `2` consecutive `ping` RTTs `> 750 ms`.
   - **Recovers (`active = true`)** with hysteresis only when OS Data Saver is
     `false`, at least `30 s` have elapsed since the last lag/disconnect, and `3`
     consecutive `ping` RTTs measure `< 350 ms`.

2. **Warm subscription set (`K = 12`) and `/btw` companion streams:**
   - On `/api/control/sync`, `subscribe` passes `max_payload = 4096` (Core
     shortens oversized `tool_call` / `tool_result` strings identically to HTTP
     `GET /events?max_payload=4096`, preserving interactive and orchestration
     JSON cards) and acknowledges `since_seq` replay completion with
     `sync_caught_up`.
   - `mission_presentation` frames include `btw_parent_id` when emitted by a
     `btw-parent:<uuid>` side mission so warm parents discover new `/btw` runs
     without polling `GET /missions?tag=btw-parent:...` (seeding the bound `/btw`
     child ID immediately on Desktop, iOS, and Android even when no prior `/btw`
     snapshot existed for that parent).
   - When **Background sync** resolves to active, the client keeps all focused
     missions plus up to `12` MRU recently opened missions (and each warm
     mission's active `/btw` child mission) subscribed in memory (`WarmLive`)
     through a single shared `WarmMissionSub` primitive per platform, reducing
     live events (`user_message`, `text_delta`, `assistant_message`,
     `mission_status_changed`, and `mission_settings_updated`) directly into the
     transcript, mission metadata/settings patch, and `/btw` caches so switching
     back requires zero HTTP requests. Unfocused `mission_status_changed` frames
     also fold into cached transcripts so live streaming bubbles close and
     terminal notices persist before reopen.

3. **Zero-cost quickness and bandwidth wins in `Off` / paused mode:**
   - Both `/api/control/sync` subscriptions and mobile `/events` HTTP reads bound
     tool payloads with `max_payload = 4096`.
   - Live WebSocket frames update cached transcripts directly on Desktop, iOS,
     and Android — never discarded on unmount and never triggering redundant full
     HTTP history reloads while streaming.
   - `/btw` uses `/api/control/sync` subscriptions instead of HTTP polling on
     all clients across `Auto`, `On`, and `Off`.
   - While unfocused in `Off` / paused mode on an unbroken `/api/control/sync`
     connection, clients track per-mission and `/btw` dirty flags from
     `mission_presentation` hints so returning to an untouched conversation skips
     redundant metadata, queue, and `/btw` history fetches:
     - **Every** `mission_presentation` hint (including `mission_activity`) on an
       unfocused mission without a caught-up `WarmMissionSub`, tearing down a warm
       subscription while the mission is live, or receiving offscreen live events
       after `pageCache` evicted the in-memory `:tx` snapshot marks that mission
       dirty (`dirtyMissions`).
     - Even when `dirtyMissions` is clear on an active `/api/control/sync`
       socket, `cleanStaleOnMount` only skips `resync(true)` on a settled
       (`completed` / `done` / `awaiting_user` / `waiting_user`) mission if the
       cached snapshot already contains a delivered `user` turn and a finalized
       non-empty assistant `text` reply after `lastUser`. A snapshot captured
       right after an `[Automatic recovery]` prompt or an earlier interrupted
       turn's `error` item always reconciles `/events` on mount and during status
       polling (where a prior turn's `error` row does not satisfy `hasFinalReply`
       once `status` is `completed` / `done`) instead of rendering `"The mission
       completed without transcript output."`
     - Disk-persisted `/btw` drafts never overwrite warm `/btw` state or mark it
       clean, pending turns always force authoritative Core reconciliation, and
       any partial `/btw` event fetch failure keeps the parent marked dirty (see
       [`docs/specs/side-questions.md`](../specs/side-questions.md)).
