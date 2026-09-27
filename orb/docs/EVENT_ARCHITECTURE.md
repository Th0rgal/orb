# Orb event and rendering architecture

Orb's native process owns bindings, interactions and local runs. Views consume
snapshots and changes. There is no old-native polling fallback. Deploy the
backend and desktop together; event pages require `X-Orb-Events-Protocol: 1`.

## Ownership and recovery

- Native subscriptions register the initial snapshot under the same lock as
  publication. Explicit unsubscribe handles late registration; WebView page
  reload clears old subscriptions without cancelling native requests/runs.
- Bindings are read from disk once, written atomically and only when changed.
  Revisions prevent late responses from replacing newer frontend state. The
  one-time localStorage import only inserts absent native entries and removes
  the old copy after successful import.
- Local run reconciliation is serialized per mission. One output follower is
  shared by consumers. Queue changes, binding changes, completion and online
  events wake the durable queue. Only uncertain/failed rows retry every 30 s.
- Process completion waits on the OS and readers drain through a condition
  variable. Stop and reaping serialize on the child handle; completion includes
  the exit status before waking subscribers. Other missions do not share that
  wait lock.

## Transcript contract

The `/missions/:id/events` endpoint has one array response representation and
pagination metadata in headers. It retains this existing representation rather
than introducing a second envelope or adapting other client surfaces needlessly.
`X-Next-Cursor` is the first raw sequence for backward pages and the last raw
sequence for forward pages. `X-Page-Max-Sequence` describes the actual page;
`X-Max-Sequence` describes availability and must not advance the consumed cursor.
`X-Has-More` may conservatively cause one final empty request on an exact page
boundary. All cursor metadata is computed before projection/condensation.

Orb loads 1,000 events initially. Backward pages and forward recovery serialize
per connection/mission, while identical concurrent operations coalesce. Empty
histories are valid cache entries. An invalid cursor reconstructs the snapshot.
A connection change invalidates pending results.

The mounted mission subscribes to SSE before requesting its snapshot. Events
arriving during recovery are buffered and reconciled against persisted identity.
Text callbacks batch on a 16 ms timer; non-text state flushes pending text first.
A healthy stream never triggers periodic complete history reads. Reopening a
cached mission performs delta recovery, not merely reuse of an old snapshot.

Mounted transcript snapshots are retained independently of the inactive LRU.
The latter allows at most 32 entries and 64 MiB of estimated serialized size;
this is a cache budget, not a claim about total JS heap size. Loading failures
preserve the previous cached value but reject so callers can show the failure.

## Rendering and search

Whole user turns are virtualized, with measured heights and two viewports of
overscan. The current tail, focused editor and active selection are retained.
Disclosure state belongs to the transcript and survives unmounting a turn;
opening many historical tools does not permanently mount all visited turns.

Search indexes transcript data, including Markdown block text, rather than only
mounted elements. It loads older pages while searching and mounts the selected
result before highlighting it. Loading is cancellable between pages and displays
progress. File search continues to use its rendered text index.

## Context and metrics

A shared OS watcher invalidates each context root. Native subscriptions and the
backend context SSE stream share these watchers. Events coalesce for 100 ms;
readers reload authoritative versions, so atomic file replacement and watcher
error/overflow cause resynchronization rather than invented incremental edits.
Views preserve local drafts and conditional-write conflict handling.

The native replica synchronizes on local changes and remote context events.
A quiet worker only checks its connection file every 30 seconds for revocation;
it does not scan the tree at that cadence. Failed/pending synchronization retries
at that recovery boundary. Token rotation replaces the remote listener.

Global CPU/memory aggregates continue every three seconds. Process/GPU details
have a six-second demand lease renewed by the visible expanded machine view;
disk enumeration is cached for 60 seconds. `timings_ms` exposes collection phases
for diagnostics. Native process-tree memory does not claim to include all
macOS-managed WebKit services.

## Validation and measurements

The native fixture uses synthetic data and real Tauri/WKWebView. Five visible
runs of 1,000 exchanges and 100 updates each produced:

| Measure | Prior audit | New native fixture |
|---|---:|---:|
| Mounted elements | 40,023 | 390 |
| Initial mounting | 161 ms, one run | 44 ms cold, then 6–9 ms |
| Per-update p95 | 8 ms, one run | 6–9 ms |
| Updates over 16 ms | 0 | 0 of 500 |

Focus, text and selection survived 20 equivalent question snapshots. The native
subscription received one initial value and no idle repetitions. Raw results are
in `performance-20260927/tauri-virtualized.json`. The fixture now includes a scroll
container and FindBar; the prior audit was a single pass, so this comparison is
indicative rather than a statistically controlled CPU experiment. The
`metrics.cpu_percent` field measures the host, **not Orb's process CPU**.

Browser coverage also checks offscreen search and an edited prompt retained
while scrolling. Tests exercise cursor progress before condensation, queued
message preservation, concurrent backward/forward recovery, invalid cursors,
connection changes, idempotent binding persistence, failed writes, atomic file
replacement, cancellation and process lifecycle.

Verified on macOS: 540 frontend unit tests, 83 native tests (six pre-existing
ignored tests), three backend cursor tests, and 60 selected browser/performance
checks passed. TypeScript, the production frontend build and `cargo check --lib`
also passed. The frontend build still warns about the approximately 503 kB main
chunk; unrelated compiler warnings remain. These are local validations, not a
production rollout or Linux/Windows runtime validation.

Run from `orb/`:

```sh
pnpm test
pnpm exec playwright test --config playwright.performance.config.ts
pnpm build
cargo test --manifest-path src-tauri/Cargo.toml --bin orb
```

From the repository root:

```sh
cargo test --lib event_page_cursor_tests
cargo check --lib
```

## Rollout

Source is developed in an isolated worktree. No running production service or
active desktop agent is restarted by the tests. Before deployment, snapshot the
persistent backend databases and `.orb` data, finish/stop active runs, then ship
the backend and desktop as one version. Verify context streaming, a pending
question, a queued follow-up, reconnection and a long conversation. Roll back
the pair together if necessary. There is no compatibility polling branch.
