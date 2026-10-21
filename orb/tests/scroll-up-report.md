# Fast scroll-up: rows drawn late

Fixture: `tests/scroll-up.html` has 320 turns. Each turn has a user bubble and an assistant reply with a heading, a list, inline math, a TypeScript block (6–29 lines) and display math. It renders through the real `Transcript` / `VirtualTurns` in a `.scroll` column, with a 1100×900 viewport in headless Chromium.
Spec: `tests/scroll-up.browser.spec.ts`. To produce these numbers, run `ORB_SCROLL_REPORT_ONLY=1 ORB_SCROLL_LABEL=<name> pnpm exec playwright test tests/scroll-up.browser.spec.ts`. For the stress variant, also set `ORB_SCROLL_WHEEL=2400 ORB_SCROLL_DRAG_STEPS=90`.

Every run starts at the bottom of the transcript and scrolls to the top in one of two ways:

- **wheel**: 80 wheel events of 1200 px (stress: 2400 px), one every 16 ms, which is roughly 70k px/s.
- **drag**: a scrollbar-thumb drag, where pointer-rate input moves `scrollTop` by `scrollHeight/180` per event (stress: `/90`), which crosses the whole transcript in about 3 s (stress: 1.5 s).

Each painted frame is sampled by a task posted from `requestAnimationFrame`. That task runs after the frame, once its ResizeObserver corrections and content-visibility updates are done. The sampler records these counters:

| metric | meaning |
|---|---|
| unpainted frames | a frame in which a visible row is a virtual-list gap spacer (**blank**) or a `content-visibility` subtree the browser skipped (**skipped**) |
| plain-code frames | a frame in which a visible code block is still uncoloured text, waiting for the highlight worker |
| anchor drift | px that the row under the viewport centre moved beyond what the wheel or drag asked for. This is the jump the reader sees. |
| layout shift | sum of `layout-shift` entries |
| frame time | rAF-to-rAF interval |
| CPU | CDP `TaskDuration` / `ScriptDuration` during the scroll |
| DOM / heap | element count and `usedJSHeapSize` after the scroll, and idle at the bottom |

## Root cause

Rows are not lazy in one single place. Four separate things each delay drawing a row that scrolls in from above:

1. **Code highlighting restarted from zero on every remount.** `VirtualTurns` unmounts turns more than 2 viewports away. When a turn comes back, `CodeBlock` waited for a 120 ms debounce plus a round trip to the worker before it coloured the code, and nothing was cached. In practice, every code block that scrolled into view appeared as plain monochrome text and was coloured a moment later. This is the "draws after a fraction of a second" effect, and it showed in 216 of 258 frames of the wheel run.
2. **User bubbles kept `content-visibility: auto` inside the virtual list.** Chrome decides whether such a subtree is relevant only after layout. On a fast flick, a bubble that entered the viewport painted as an empty box for a frame. The virtual list already bounds what is mounted, so this skip only delayed the paint and saved nothing.
3. **Unmeasured rows were assumed to be 300 px.** The real rows here are about 850 px. Corrections arrived through each row's own ResizeObserver. When the re-windowing that mounted a row ran from inside another observer callback, the browser held that row's notification to the next frame, so one frame painted the estimate. This caused 100–400 px jumps during a drag, plus layout-shift scores of 28–40.
4. **The pre-render buffer was biased toward the bottom**: 2 viewports above and 3 below. A flick up outran it first.

## Fix

- `codeHighlightClient.ts` keeps an LRU cache of finished highlights, keyed by language and source and bounded at 2M characters. `CodeBlock` starts from the cached HTML, so a remounted block is coloured in its first frame. A block that mounts with its text already complete asks the worker immediately; the 120 ms debounce now applies only to streaming updates.
- `Markdown.tsx` adds an LRU of KaTeX output (1500 formulas) and an LRU of parsed Markdown blocks for messages at mount time (400 messages). Streaming updates keep using the incremental parser and never touch the cache.
- `styles.css`: `[data-virtual-transcript] .user { content-visibility: visible; }`. The top-level `.scroll .col > *` rule with `contain-intrinsic-size: auto 160px` is unchanged, and so is the `.st-working` / `[data-virtual-transcript]` exemption that prevents the 160 px flash.
- `VirtualTurns.tsx`:
  - The buffer follows the scroll direction: 3 viewports ahead and 2 behind. The mounted span is the same 5 viewports as before.
  - Per-row estimates come from the text (`Transcript` passes `estimate`). Each estimate is frozen at first use, so a gap never changes height.
  - One shared ResizeObserver handles all rows, and newly mounted rows are measured in the same pass, before paint. All rects are read from a single layout, then sizes, the scroll correction and re-windowing are applied once, and re-windowing runs in a microtask in the same frame.
  - A row's first measurement corrects the scroll only when the row replaced a gap spacer and the reader is not at the bottom. That leaves bottom pinning to `pinnedScroll.ts`, which is unchanged.

## Results

Each cell is a median of 3 runs. The before runs are master `8caa9427f`; the after runs are this branch.

### Default spec (asserted in CI)

The quiet-machine runs had load average around 4:

| | wheel before | wheel after | drag before | drag after |
|---|---:|---:|---:|---:|
| unpainted frames (blank + skipped) | 0 | **0** | 0 | **0** |
| plain-code frames | 216 / 258 | **0** / 257 | 190 / 208 | **2** / 231 |
| anchor drift (px) | 0 | 0 | 1 | 0 |
| layout shift | 28.0 | **0** | 40.7 | 36.4 |
| frame median / p95 (ms) | 15.3 / 26.7 | 14.8 / 32.3 | 16.6 / 24.4 | 16.7 / 26.4 |
| long tasks | 0 | 0 | 0 | 0 |
| CPU task / script (ms) | 1499 / 482 | 1544 / 456 | 1092 / 367 | 2176 / 653 |
| DOM elements after scroll | 4356 | 3872 | 4388 | 2096 |
| JS heap after scroll (MB) | 22 | 28 | 25 | 22 |

The same spec run interleaved before/after with load average 15–30, while another agent was running tests:

| | wheel before | wheel after | drag before | drag after |
|---|---:|---:|---:|---:|
| unpainted frames | 0 | **0** | 2 | **0** |
| plain-code frames | 84 | **0** | 219 | **16** |
| layout shift | 28.0 | **0** | 40.4 | 9.6 |
| CPU task (ms) | 5087 | 4823 | 8441 | 8348 |
| long tasks | 10 | 11 | 11 | 50 |

### Stress (2400 px wheel events, drag in 90 steps)

Interleaved runs under load:

| | wheel before | wheel after | drag before | drag after |
|---|---:|---:|---:|---:|
| unpainted frames | **23** (skipped bubbles) | **0** | **43** | **4** (blank) |
| plain-code frames | 203 | 0 | 172 | 83 |
| anchor drift (px) | 0 | 0 | 383 | 2 |
| layout shift | 2.4 | 0 | 32.3 | 0 |
| CPU task (ms) | 5931 | 5472 | 4136 | 3963 |

### Idle footprint at the bottom

| | before | after |
|---|---:|---:|
| DOM elements | 2272 | 2756 |
| JS heap (MB, noisy: GC timing) | 16–57 | 23–48 |

## Resource cost

- **Wheel CPU is unchanged**: 1499 vs 1544 ms on the quiet machine, and lower in the loaded medians.
- **Drag CPU is higher on the quiet machine**: 1092 to 2176 ms over about 3 s, about 9 ms per frame instead of 5. That cost is the code now actually being coloured. With the old `CodeBlock` swapped back in on this branch, drag CPU was 1516 ms. Before, most blocks scrolled past as plain text and only blocks the reader stopped on were highlighted, so the old number avoided work the old UI also skipped showing. Under load, the before and after drag numbers overlap (8441 vs 8348 ms).
- **Long tasks**: the loaded drag runs (default spec) recorded 50 long tasks after vs 11 before, while CPU totals were about the same. The quiet-machine runs had 0 in both versions. This is not separated from load noise and should be watched.
- **DOM during scroll is lower**: down by 11% in the wheel run and 52% in the drag run, because accurate estimates mean fewer rows fall inside the buffer. **DOM at idle is 21% higher** (+484 elements), because after a scroll up the larger buffer stays on the side above.
- **Caches are bounded**: highlights at 2M characters (about 4 MB of strings), formulas at 1500 entries, parsed messages at 400 entries. Heap differences sit inside GC noise.

## Regression test

`tests/scroll-up.browser.spec.ts` runs in the regular browser suite. On both the wheel run and the drag run it asserts zero unpainted frames and an anchor drift under 200 px. It also checks that the run actually started deep in the transcript.

Layout shift is reported but not asserted. Programmatic scroll corrections still register `layout-shift` entries even when the content does not move on screen, which is why anchor drift is the measure the test relies on.

Plain-code frames are reported but not asserted. On the very first view of a turn, highlighting still needs one round trip to the worker. Prism stays off the main thread on purpose.
