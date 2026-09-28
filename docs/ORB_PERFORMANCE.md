# Orb desktop performance

## Profile: 28 September 2026

Measured the running macOS Tauri development client with `/usr/bin/sample`
(the unqualified `sample` command on this Mac resolves to a broken Python tool)
and repeated `ps -p <pid> -o pid=,time=,%cpu=,rss=` observations. WebKit was
identified by its launch alongside Orb. No agents were stopped for profiling.

The first WebKit sample reported 623.6 MiB physical footprint, historical peak
2.8 GiB; native Orb reported 64.8 MiB, peak 484.2 MiB. These peaks span the whole
process lifetime and do not establish a leak. WebKit's sampled main-thread work
was concentrated in JavaScript triggered by IndexedDB completion callbacks.

### Changes

- Local outbox polling preserves unchanged array/row identities. IndexedDB
  clones previously invalidated conversation subscribers every second, even for
  an empty queue. A regression test saw five redundant invalidations over five
  idle seconds before the fix and zero afterwards. Durable polling, cross-window
  reads, dispatch locking, and immediate enqueue wakeups remain in place.
- Context token estimates reuse serialized lengths for immutable historical
  tool payloads. Weak keys avoid retaining evicted transcripts. New payloads
  and streaming text still change the estimate; existing token caps are retained.
- Plan recovery, steps, completion count, and published progress are memoized
  instead of repeatedly scanning the same transcript for each UI consumer.

### Results

WebKit benchmark: 150 tool results of 20,000 characters, 60 counter updates.

| | Previous algorithm | Optimized |
|---|---:|---:|
| Elapsed | 173 ms | 4 ms |
| Tool result serializations | 9,000 | 150 |
| Estimated tokens | 16,060 | 16,060 |

The test asserts equal estimates and serialization counts, not timing (which
varies by machine). The timing covers this computation, not entire page loading.

Two ~10-second live observations found WebKit using 1.43 CPU seconds before and
0.08 afterwards (~14.3% vs ~0.8% of one core). Native Orb used 1.76 vs 0.65 CPU
seconds. Agent workloads and other applications were not held constant, so these
are observations, not a controlled whole-app speedup or memory-reduction claim.
Native metrics collection and active harness monitoring still run independently.

### Reproduce

From `orb/`:

```sh
pnpm test tests/local-message-queue.test.ts tests/mission-context.test.ts tests/plan-progress.test.tsx
pnpm exec playwright test context-performance.browser.spec.ts
pnpm build
```

The browser test uses an isolated WebKit page with synthetic tool results and
attaches `context-performance.json` to the Playwright test result. It does not
connect to a real backend or launch missions. For live profiling, sample the
native Orb process and its WebKit content process separately; native-process RSS
alone omits most UI memory. Compare CPU time deltas over equal windows, and keep
the same conversation, streaming activity, and visibility when possible.

## Sidebar expansion (2026-09-28)

A WebKit fixture renders the real `LiveProjectsSection` with 100 conversations
and 180 ms simulated API latency. Initial preloading raced expansion: missions,
files and controller were each requested twice. Reopening added three more reads.

| Read path | Before | After |
| --- | ---: | ---: |
| Initial preload + expansion (four project resources) | 7 requests | 4 requests |
| Collapse/reopen while fresh | 3 additional requests | 0 additional requests |

One two-animation-frame observation measured 213 ms cold / 28 ms warm before,
and 43 ms cold / 33 ms warm after. These include scheduling and prefetch timing;
they are illustrative single observations, **not** stable latency benchmarks.
The repeatable improvement is request count. The test attaches timings for each
run rather than imposing machine-dependent millisecond thresholds.

Implementation:
- In-flight sharing and a 10-second freshness window for project reads; forced
  polling/mutation refreshes retain existing rows while fetching.
- At most 128 cached responses, scoped to this sidebar; cleared on connection
  changes, with old responses prevented from repopulating the cache.
- Four projects preloaded, prioritising expanded/active projects; deliberate
  hover or keyboard focus warms other projects and subfolders after 100 ms.
- Cached file rows survive transient refresh errors, with a retry notice.
- Keyed reconciliation retains unchanged file/cron/controller objects.
- New rows fade in over 100 ms without height animation; reduced-motion disables it.

`sidebarTimingSnapshot()` in `orb/src/sidebarRequests.ts` exposes aggregate request,
cache-hit and coalescing counts plus last/maximum/total duration by resource type.
It stores no account/project names or payloads and has only five possible buckets.
In the Vite developer console:

```js
(await import('/src/sidebarRequests.ts')).sidebarTimingSnapshot()
```

Regression coverage:

```sh
cd orb
pnpm test tests/sidebar-requests.test.ts tests/tree-focus.test.tsx tests/sidebar-actions.test.ts
pnpm exec playwright test sidebar-performance.browser.spec.ts
```

The browser test also verifies recovery from failed refreshes and keyboard
collapse/expansion. It uses no real account and creates no missions.

Suggested next work (not implemented here):
1. Replace duplicate whole-list polling with a shared mission store updated by
   SSE, retaining a slow reconciliation poll after reconnect.
2. Window very long conversation transcripts and project lists; preserve scroll
   anchors and keyboard focus while rendering only nearby rows.
3. Prefetch only recent/hovered conversation tails with a bounded queue, rather
   than warming every active transcript from multiple consumers.
4. Lazy-load provider/settings panels and syntax/PDF viewers; compare first-open
   latency and main bundle size before choosing split boundaries.

A live process snapshot showed high WebKit CPU during this development session;
that is not isolated evidence about sidebar cost. Whole-client profiling needs a
stable visible conversation, no hot reloads, and matched active/idle intervals.

## Reliability-first implementation (28 September 2026)

Applied in the active `sandboxed_sh-orb-client` worktree. Existing unrelated work
was retained. No production backend deployment or remote mission was required.

### Native collection and context synchronization

- The metrics collector now sleeps on a condition variable when its 10-second
  reader lease expires. Reading the metrics panel renews the lease and wakes the
  collector. Active sampling remains every three seconds; disk capacity is cached
  for 60 seconds. Process refresh requests memory only, not per-process CPU,
  environment, executable or disk-I/O details. Samples expose `sampled_at` so a
  returning panel can distinguish a cached result from a fresh sample.
- Native interaction events wake the UI immediately. A capability handshake
  retains 350 ms polling for old native binaries; supporting binaries use a
  10-second visible-window reconciliation poll. Requests remain owned by the
  native process and retain single-consumption/generation checks.
- Context workers use filesystem notifications, coalesced over 200 ms, and retain
  a periodic scan/network reconciliation. Identical successful state increases
  the idle interval from 2 to at most 15 seconds. Pending writes/errors keep the
  short interval. Notifications reset the interval; a missing watcher cannot
  disable periodic reconciliation. Existing HTTP client reuse is retained.
- Identical replica state is not rewritten. Changed state still uses the same
  atomic write and fsync path, including outgoing intent before network calls.
  Tests verify unchanged inode versus durable changed contents.

Already-running detached context workers continue using their loaded binary until
restarted through their normal lifecycle. They were not killed during this task.
Their CPU is not evidence of the new worker scheduler's performance.

### Shared reads and bounded memory

- Ordinary GET calls share only in-flight work, scoped by connection version and
  endpoint. Explicit request options/signals retain independent cancellation.
  Mutation admission invalidates sharing; results are not kept in this layer.
  GETs have a 30-second timeout. Successful replies from an old connection cannot
  enter the current UI. A late 401 cannot disconnect a newer connection.
- Page cache: 32 entries and 32 MiB estimated payload budget, whichever is hit
  first. Oversized values can still be displayed but are not retained by this
  cache. The estimate counts object/string payload conservatively without JSON
  serialization; it is not a measured JS heap limit.
- Cached data and pending admission are reset on connection changes. Old replies
  cannot repopulate the cache, old promise cleanup cannot erase a newer request,
  and a fetch cannot overwrite a newer direct cache publication.
- Refresh consumers see failures even when another consumer sharing the same
  network read elects to show stale cached data.
- Transcript prefetch now uses the existing bounded queue: eight queued jobs,
  one background fetch at a time. Rejected jobs do not stall the queue. Hidden
  windows defer prefetch and resume it when visible. Interactive reads remain
  immediate and can join an in-flight prefetch.
- `cacheStats()` and `readStats()` expose aggregate bounded counters; they contain
  no project names, prompts, URLs or credentials. No monitoring payload is sent.

### Streaming and large histories

- Remote text fragments are applied in 16 ms batches, capped at 128 events.
  Non-text/terminal events flush immediately. One immutable array copy per batch
  replaces one copy per fragment; the existing reducer still owns ordering,
  Unicode text operations and deduplication. Work summaries are memoized.
- Initial history reads fetch 1,000 events instead of 4,000. Earlier pages use
  the existing `before_seq` API. Summarized/sparse responses can still offer an
  earlier-page read; an empty page ends pagination. Previously loaded pages are
  retained across tail refreshes, and pending user messages are preserved.
- Loading an earlier page holds new live events and replays them afterwards.
  Scroll restoration anchors an existing visible DOM node, yields to user
  input, and preserves keyed conversation components.
- The recent-event journal used for paging is capped at 8 MiB estimated payload
  and 4,096 events. On overflow, the visible stream continues normally; paging
  waits for the next successful durable replay (normally response completion).
  The earlier-messages button explains this temporary restriction. No displayed
  text or pending answer is evicted to meet the cache/journal budgets.
- Browser `content-visibility: auto` was tested and **not retained**. WebKit kept
  the text in the DOM but failed to scroll it into the viewport. Pagination is
  shipped without DOM recycling or skipped-layout CSS, preserving selection,
  native find within loaded history and keyboard focus. Searching unloaded
  history still requires loading the earlier pages.

### Validation and reproducibility

```sh
cd orb
npm test -- --maxWorkers=2
npm run build
npx playwright test tests/history-performance.browser.spec.ts \
  tests/stream-batch-performance.browser.spec.ts --config playwright.performance.config.ts
cargo test --manifest-path src-tauri/Cargo.toml --bin orb -- --test-threads=2
```

The targeted browser config runs an isolated Vite server on port 1432 and mocked
backends; it does not create real missions. Browser regressions also cover cloud
navigation/follow-ups, long transcripts and preservation of expanded work.
The WebKit paging test checks actual viewport intersection, not merely DOM presence.

A synthetic benchmark compares 128 fragments on a 2,000-event transcript. Batched
and sequential results match and unchanged prefix objects remain shared. A single
run rounded to 1 ms versus 0 ms, below useful timer precision: **no speedup ratio
is inferred**. The repeatable algorithmic difference is one list copy versus 128.

Process monitoring without collecting arguments or environment variables:

```sh
python3 scripts/orb_profile.py --pid NATIVE_PID --pid WEBKIT_PID \
  --seconds 60 --output artifacts/orb-profile.json
```

Artifacts for this session are under `artifacts/orb-perf-20260928/`. The later
60-second sample observed native Orb at about 0.03% of one core and 58 MiB RSS;
WebKit was essentially inactive with about 4 MiB RSS. Window visibility and
workloads were not controlled, and frontend tests/builds ran concurrently.
This is **not** a matched before/after memory comparison or a claimed whole-app
speedup. A visible/streaming/background soak on a packaged build remains the way
to establish end-to-end gains and detect long-lived retention.
