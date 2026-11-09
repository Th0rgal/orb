# Poor-Network Transport, Priority Scheduling & Local-First Continuity

This specification defines how Orb clients (`orb-locald` + desktop WebView, iOS, and Android) sustain responsive conversation progress, deterministic failover, and zero self-inflicted congestion on high-RTT, high-packet-loss networks (such as congested Wi-Fi or weak cellular links).

## Failure Mode Replayed

On a `4 Mbps` link with `490–825 ms` idle TLS RTT, `2.6–4.6 s` loaded RTT (bufferbloat), and intermittent packet loss:

1. **Cold TCP/TLS per request & uncompressed payloads:** Opening a fresh HTTP/1.1 `Connection: close` socket per REST call without `gzip` multiplied `800 ms–6 s` TLS handshakes across `430 KB` payloads (`5.5×` larger than `gzip`).
2. **Duplicate-IP failover waste:** Failing over from `https://orbcore.thomas.md` to `https://agent-backend.nico-best-pc-ever.ovh` retried the exact same direct Hetzner IP (`65.109.98.246`) before trying the Cloudflare Anycast Edge (`https://agent-backend.thomas.md`), burning two full timeouts before reaching BBR edge termination.
3. **Unprioritized startup fan-out:** Launching or reloading fired `30–40` concurrent requests (`/api/software` per node, `/files`, `/crons`, `/antigravity-models`, cold transcript prefetches) alongside foreground conversation loads, saturating the uplink/downlink queue and starving `GET /api/control/missions/:id/events` past its `30 s` deadline.
4. **Fixed WebSocket suicide timers:** Fixed `5,000 ms` connect/pong deadlines (`2,500 ms` on wake) tore down healthy `sync-ws` sockets whenever loaded RTT crossed `2.6–4.6 s`, triggering `onLagged` + `10 s` poll resync storms.
5. **Volatile transcript cache:** Reloading or restarting wiped in-memory `pageCache`, leaving conversations on a skeleton screen until WAN round-trips completed.

## Architecture ("Lean Decides, Platform/Leaf Does")

### 1. Kernel RTT Estimator & Link Budget Governor (`lean/Orb/Kernel.lean`)

All four client targets (macOS, Linux, iOS, Android) share two unboxed C-ABI functions in `Orb.Kernel`, proved in `lean/Orb/Spec.lean`:

- **`orb_rtt_ewma_step(srttMs, rttVarMs, sampleMs)`**:
  - Clamps `sampleMs` to `1..60,000 ms`.
  - Cold start (`srttMs == 0`): initializes `nextSrtt = sample`, `nextVar = max(50, sample / 2)`.
  - Steady state (RFC 6298 Jacobson/Karels integer EWMA): `nextVar = clamp((3 * rttVar + |srtt - sample|) / 4, 10, 60000)`, `nextSrtt = clamp((7 * srtt + sample) / 8, 1, 60000)`.
  - Packs `(nextVar << 32) | nextSrtt`.

- **`orb_client_link_budget_step(srttMs, rttVarMs, consecutiveFailures, isConstrained, p0InFlight)`**:
  - Computes priority concurrency caps and adaptive WebSocket deadlines in a single `UInt64`:
    - `bits 0..7` (`p1Cap`, `2..6`): Foreground conversation & sidebar concurrency (`6` when healthy `srtt <= 400 ms`, `3` when `400 < srtt <= 1200 ms`, `2` when `srtt > 1200 ms`, `consecutiveFailures > 0`, or `isConstrained != 0`).
    - `bits 8..15` (`p2Cap`, `0..4`): Background sweep concurrency (`4` when healthy and `p0InFlight == 0`, `1` when `400 < srtt <= 1200 ms` and `p0InFlight == 0`, and **`0` (strictly paused)** whenever `p0InFlight > 0`, `srtt > 1200 ms`, `consecutiveFailures > 0`, or `isConstrained != 0`).
    - `bits 16..31` (`connectDeadlineMs`, `8,000..30,000 ms`): `clamp((srtt == 0 ? 10000 : srtt + 4 * rttVar + 4000) + 2000 * min(consecutiveFailures, 4), 8000, 30000)`.
    - `bits 32..47` (`pongDeadlineMs`, `8,000..25,000 ms`): `clamp(srtt == 0 ? 8000 : srtt + 4 * rttVar + 3000, 8000, 25000)`.
    - `bits 48..63` (`wakePongDeadlineMs`, `6,000..15,000 ms`): `clamp(srtt == 0 ? 6000 : srtt + 2 * rttVar + 2500, 6000, 15000)`.
  - **`P0` (Interactive prompts, approvals, auth, cancellations)** is never throttled by `p1Cap`/`p2Cap` and immediately zeroes `p2Cap` while in flight.

### 2. Edge-Diverse Failover Ordering (Desktop, `orb-locald`, iOS, Android)

`orbcore.thomas.md` and `agent-backend.nico-best-pc-ever.ovh` terminate on the same direct Hetzner origin, whereas `agent-backend.thomas.md` terminates TCP/TLS/HTTP/2/HTTP/3 at the nearest Cloudflare Anycast PoP with BBR congestion control.

Candidate ordering ensures the first failover hop always switches **network path class** (Direct <-> Anycast Edge) rather than re-hitting the same congested route:

- Primary `https://orbcore.thomas.md` -> `["https://orbcore.thomas.md", "https://agent-backend.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"]`
- Primary `https://agent-backend.nico-best-pc-ever.ovh` -> `["https://agent-backend.nico-best-pc-ever.ovh", "https://agent-backend.thomas.md", "https://orbcore.thomas.md"]`
- Primary `https://agent-backend.thomas.md` -> `["https://agent-backend.thomas.md", "https://orbcore.thomas.md", "https://agent-backend.nico-best-pc-ever.ovh"]`

### 3. `OrbNetLeaf` & `orb-locald` Multiplexed HTTP/2 Pool + RFC 1952 `gzip` (macOS & Linux)

1. **Bounded Non-Blocking Connect & `TCP_NODELAY` (`orb_net_leaf.c`, `<= 220` C LOC):**
   - `onl_connect_sock` uses `O_NONBLOCK` + `poll(POLLOUT, timeout_ms)` + `getsockopt(SO_ERROR)` so dropped SYN packets on macOS/Linux never stall on the 75 s kernel `keepinit` timer, and sets `TCP_NODELAY = 1` + `SO_KEEPALIVE = 1` on stream sockets.
2. **Pure Lean 4 RFC 1952 `gzip` / RFC 1951 `DEFLATE` (`OrbNetLeaf.Gzip`):**
   - `orb-locald` advertises `Accept-Encoding: gzip` on upstream REST requests and transparently inflates `Content-Encoding: gzip` responses in pure verified-bounds Lean (`CRC32` + `ISIZE` + `maxRespBytes` cap), cutting JSON payload bytes by `5–6×` with zero `libz` C FFI bloat.
3. **Persistent Multiplexed HTTP/2 Pool (`OrbNetLeaf.H2Pool`, `OrbNetLeaf.Spec.H2ClientStreamOrderSpec`):**
   - Maintains a warm TLS 1.3 `ALPN "h2"` session per `(host, port)`, multiplexing concurrent odd client streams (`1, 3, 5, ...`) through a single-owner actor `Task` that drains priority-ordered outbound `16 KiB` frames (`P0 > P1 > P2`), shares the connection `HpackDecoderTable`, auto-ACKs `SETTINGS`/`PING`, replenishes `WINDOW_UPDATE`, and falls back cleanly to HTTP/1.1 if a custom server does not negotiate `h2`.
   - **RFC 9113 §5.1.1 Wire Stream-ID Monotonicity (`H2ClientStreamOrderSpec`):** Incoming batches are stably ordered by priority (`P0 -> P1 -> P2`) before admission, and odd client `streamId`s (`1, 3, 5, ...`) are allocated strictly at wire `HEADERS` flush time — never before priority insertion — so reordering `P0` ahead of `P1`/`P2` never opens a higher stream ID before a lower one (`GOAWAY(PROTOCOL_ERROR)`).
4. **Stateful Origin Health & Telemetry in `orb-locald`:**
   - `transport_bridge_configure` honors `apiUrl`, orders failover origins Edge-diversely, prewarms the upstream H2 session, tracks per-origin EWMA RTT and `20 s` failure cooldowns, and emits `X-Orb-Transport-Rtt-Ms` and `X-Orb-Upstream-Origin` on loopback responses.
   - **Compute-Bound SRTT Exclusion:** Subprocess/telemetry/quota/analytics endpoints (`/api/software`, `/api/stats`, `/api/resources/*`, `/api/usage*`, `/api/proxy-health*`, `/api/providers/antigravity-models`, `/api/antigravity-models`, `/api/ai/providers/usage`, `/api/ai/providers/:id/usage`, `/api/file-resources`, `/inbox-digest`) are excluded from EWMA link RTT updates in both `orb-locald` and `orb/src/api.ts` so multi-second server CLI/SQLite rollup work never inflates `srttMs` or zeroes `p2Cap` on fast links.
5. **Multiplexed Pool & Hub Teardown Total-Drain Contract (`OrbNetLeaf.Spec.PoolTeardownDrainSpec`):**
   - Every multiplexed connection worker or sync hub (`OrbNetLeaf.H2Pool`, Android `ControlSyncHub`) must resolve **100% of queued and in-flight stream/subscriber waiters** on teardown (`GOAWAY`, TLS EOF, write error, explicit `close()`): queued/unwritten streams resolve as `.retryUnprocessed`, while streams whose `HEADERS` already hit the wire resolve as `.terminalError` (no unsafe replay of non-idempotent mutations).
   - State mutated inside `try` and drained inside `finally` in Lean 4 **must** live in `IO.Ref` (never `let mut`, because `tryFinally` captures pre-`try` state bindings), and promise consumers **must** await `IO.Promise.result?` (never `.result!`), enforced repo-wide by `scripts/lint_kernel_calls.py`.

### 4. Persistent Snapshot Hydration, Cross-Navigation Caching & Calm UX

- **Persistent Transcript & Sidebar Cache (`orb/src/persistentCache.ts`, `orb/src/api.ts`):** Ready mission transcripts (LRU 24) and sidebar mission/project lists persist locally scoped to the active backend origin (cleared immediately on `clearConnection()`), with an in-memory `catalogMemory` mirror in `orb/src/api.ts` so synchronous hydration (`peekCachedProjects()`) succeeds even when WebKit `localStorage` hits its 5 MB quota.
- **Preserved Sidebar & `pageCache` View Snapshots Across Settings Navigation (`orb/src/App.tsx`, `orb/src/pageCache.ts`):** Opening and leaving Settings (`⌘,` / `Back`) hides `.sb-main-nav` (`LiveProjectsSection`, keyed by `connectionVersion`) and pauses its background sweep without unmounting its project/folder/mission state or losing sidebar `scrollTop` (matching iOS `.sheet` and Android `OrbSettingsSheet` behavior). Top-level and Settings views (`Providers`, `Machines`, `Resources`, `Settings`, `RoutingSettings`, `UsageSettings`) hydrate initial signals from `pageCache` (`cacheReset()`-scoped to the active connection) so revisiting any page renders cached snapshots synchronously with zero skeleton flash while refreshing quietly in the background. Write-only analytics flushes (`POST /api/usage-telemetry/events`) run at `P2` priority without invalidating `sharedReads`.
- **Strict `P2` Background Prefetch Isolation (Desktop, iOS, Android):** Background transcript/event prefetches and collapsed-project warmups run strictly in the `P2` lane (bounded by `linkBudget.p2Cap`, paused when `p2Cap == 0`), never enqueue into `P1`, and abort immediately if the user opens the conversation in the foreground (`P1`).
- **Loading vs. Confirmed Empty Invariant:** Views with asynchronous backing data (`ProjectFiles`, `Providers`, mobile `OrbHome` / `OrbProjectPage` / `OrbMoveSheet` / `OrbProvidersSettings`) render calm skeleton rows while initial fetches are in flight and inline retryable error banners on failure — never asserting `"No projects"` / `"No providers"` / `"No conversations"` until a response confirms emptiness.
- **Calm Link Status:** When `sync-ws` is reconnecting or EWMA RTT exceeds `1,200 ms`, `MissionView` surfaces a quiet, non-jumping status pill while keeping cached transcripts interactive and suppressing background prefetches (`monitorSoftware` startup delay + `isBackgroundSyncActive()` prefetch gate).
