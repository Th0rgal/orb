# Conversation loading and cached presentation

The readable conversation and current activity must not wait for tool history.
Desktop, iOS and Android share these invariants:

- Account, mission and run identity scope every cached value and live update.
- A partial snapshot never erases complete history. Late disk/network reads do
  not overwrite newer revisions. Completion cannot be undone by an old action.
- Show cached content while refreshing; loading is distinct from execution.
- One activity area owns the current turn. A known action replaces the generic
  working label in place; historical work counts do not add a second status row.
- Latest durable answers load before detailed tool history. Partial previews
  never become pagination cursors or complete inputs to Inbox summaries.
- Offscreen foreground updates carry compact state/references, not tool payloads
  or token deltas. Reconnect/gaps trigger reconciliation. Mobile suspension uses
  resume reconciliation rather than relying on background sockets.
- Images already read reuse a bounded, account/mission-scoped cache. Concurrent
  consumers share reads; failures are retryable; scope changes reject late loads.
  Mutable workspace images must expire or be invalidated when the mission changes.
- Existing scroll ownership remains authoritative. Hydration must preserve the
  reader's anchor. Skeletons represent only missing content; reduced motion works.

## Regression scenarios

Replay summary before events, preview before raw tail, completion before stale
activity, disk after network, switch-account during image load, concurrent image
mounts, reopen offline, filtered-stream cross-mission events, stream reconnect,
and pagination after a partial preview. Measure first readable paint separately
from full hydration and report actual payload sizes and foreground bandwidth.

## Implementation and budgets

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

Scroll event ordering matters: a layout shrink can clamp the browser before its
ResizeObserver runs, or an earlier corrective scroll event can arrive after the
next layout. These are not new reader intent. The scroll owner restores the old
anchor before remembering the viewport; `scroll-anchor.browser.spec.ts` replays
both narration collapse and stale-cache enrichment with the working row absent.

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
