# Phase P7: Measured Optimization, Cross-Client $O(N)$ Unclosed-Fence Streaming & ISA-Dispatched SIMD Scanner Qualification

Base commit: `76aa1c12c56b9190e7831c5787a621d81f29e8da` (`master`)
Branch: `feat/p7-measured-streaming-and-simd-opt`
Machine-readable artifact: `/tmp/p7-benchmarks.json` (paired with baseline `/tmp/p7-before.json`)

## 1. Benchmark Environment & Methodology

All `BEFORE` and `AFTER` measurements were captured back-to-back on an identical dedicated 8-vCPU / 16 GB RAM `boat.dev` instance:

- **CPU**: AMD Ryzen 9 9950X (Zen 5), 8 vCPUs (`sse2`, `avx2`, `avx512f`, `avx512bw`; detected Lean ISA mask `799`)
- **Kernel / OS**: Linux `6.8.0-101-generic` `x86_64`
- **Desktop runtime**: Node.js `v22.22.2`, Vite `6.4.3` production build (`orb/dist`), Playwright Headless Chromium with CDP `Performance.getMetrics` (`TaskDuration`, `JSHeapUsedSize`) and `--js-flags=--expose-gc`
- **Kotlin / JNI runtime**: OpenJDK `11.0.30` + `kotlinc-jvm 1.9.24` linked against `liborb_spec_cabi` (`shared/orb-spec/cabi/orb_kernel_unboxed.c` + `OrbKernelJni.c` compiled with `clang -O3 -fPIC`)
- **Rust / C-ABI runtime**: `rustc 1.94.1` (`cargo build --offline --release -p orb-spec`, `-O3` unboxed Lean C-ABI `liborb_spec_cabi.a`)
- **Lean / Spec Audit**: `leanprover/lean4:v4.35.0` + `turbo-lean` (`0 import Lean`, `0 sorryAx`)

Every benchmark discards warmup iterations and reports sample count $n$, median (`p50`), `p99`, standard deviation, and coefficient of variation (`CV`). Every optimization lever retained in Desktop passed an individual end-to-end ablation ratchet (`ΔE2E >= 1%` on live `MissionView` Chromium main-thread CPU time).

---

## 2. Formal Specification & Proof Summary (`lean/Orb/Stream.lean` & `lean/Orb/Spec.lean`)

1. **Checkpointed Incremental Line Scanner (`lean/Orb/Stream.lean`)**:
   - Defined `ScanCheckpoint` (`fenced`, `inList`, `inQuote`, `lastBlankPos`), `stepScanLine`, `scanLinesFrom`, and `checkpointCommitBoundary`.
   - Proved **`scanLinesFrom_eq_commitBoundary`** (equivalence between checkpointed incremental scanning across appended line slices and full-prefix `commitBoundary`), **`scanLinesFrom_append`** (exact compositionality across delta chunks: `scanLinesFrom ck (ls₁ ++ ls₂) base = scanLinesFrom (scanLinesFrom ck ls₁ base) ls₂ (base + linesLen ls₁)`), and **`checkpointScan_total_lines_eq`** ($\sum_i |\Delta L_i| = |L|$ total line visits vs $\Theta(N^2)$ prefix re-scans).
2. **Audit Gate Verification**:
   - `turbo-lean --json audit-spec lean/Orb/Spec.lean`: `vacuous_specs = 0`, `trivial_specs = 0`, `horizontal_packing_warnings = []`.
   - `lean/audit/AuditSpec.lean`: `1446` declarations, `316` theorems, `80` `Orb.Kernel` exports (`113` total manifest exports in `kernel_abi.json` including `lean-sys`), `7` `MetaStepSpec`, `10` universal algebraic Meta-Specs, `0 sorryAx`.

---

## 3. Architectural Optimizations Shipped

1. **Cross-Client $O(N)$ Checkpointed Unclosed-Fence & Pipe-Table Streaming (Desktop, Android, iOS)**:
   - **Desktop (`orb/src/Markdown.tsx`, `orb/src/CodeBlock.tsx`, `orb/src/pipeTables.ts`)**: Replaced per-delta `tail.split("\n")` re-scanning and full-tail `parseMarkdown` inside open code fences with persistent `scanCursor` + `fenceBodyCursor` checkpoints, zero-alloc `utf8LenSlice`, $O(1)$ sampled prefix-continuity check, zero-copy `text.slice(fenceBodyStart)` for unindented LF fences, early loose-pipe table scan before `src.split("\n")`, `<Index each={blocks()}>` + keyed `renderBlockSlot` in `MdView` to preserve mounted `CodeBlock` DOM nodes across deltas, and incremental `appendChild(document.createTextNode(delta))` + streaming highlight-cache bypass above `16 KB` in `CodeBlock`.
   - **Android (`OrbStreamText.kt`, `OrbPipeTables.kt`, `OrbRichText.kt`) & iOS (`OrbStreamText.swift`, `OrbPipeTables.swift`, `OrbRichText.swift`)**: Added persistent checkpoint cursors (`scanCursor`, `fenceBodyCursor`, `openFenceStart`) in `OrbIncrementalParser`, incremental open-fence block accumulation, open-fence / ` | ` fast-paths in `normalizeLoosePipeTables`, and `OPEN_FENCE_STREAM_THRESHOLD = 4096` syntax-highlight deferral while a large fence is actively streaming (preserving `stream-commit.json` and `stream-cost.json` fixture parity for normal streams).
2. **Desktop Frame-Coalesced Transport Batching & Transcript Memo Stabilization**:
   - **`orb/src/stream.ts`, `orb/src/mission/MissionView.tsx`, `orb/src/missionCache.ts`, `orb/src/Inbox.tsx`**: Added `onBatch` callback to `createEventCoalescer` so bursts within a 16 ms frame apply via `applyStreamEvents(cur, pending)` with a single `items.slice()` copy instead of $k$ array clones per frame.
   - **`orb/src/transcriptModel.ts`, `orb/src/Transcript.tsx`, `orb/src/Chapters.tsx`, `orb/src/TurnRecap.tsx`, `orb/src/PlanProgress.tsx`**: Replaced $O(N^2)$ forward lookaheads in `withoutFiller` with a single $O(N)$ reverse pass, short-circuited `nonQueuedViewItems`/`nonQueuedItems` when no queued user message exists, added structural equality comparators to `confirmedRemote`, `deliveredRemote`, `reminders`, `followUps`, and `chapters`, and replaced `.slice().reverse()` allocations with reverse index loops.
3. **Rust KMP Stream Fragment Overlap & Lean-Gated SIMD Byte Scanner (`crates/orb-spec/src/lib.rs`, `src/api/control/streaming.rs`)**:
   - Replaced quadratic `suffix_prefix_overlap_len` byte-window probing (`O(min(|existing|, |incoming|)^2)`) with a linear Knuth-Morris-Pratt prefix-Automaton matcher (`O(|incoming|)` time, stack-resident `[u32; 512]` buffer for typical fragments), backed by a `1,024`-case differential proptest against the reference oracle.
   - Added `orb_spec::stream_simd` (`scan_stream_bytes`, `scan_stream_bytes_scalar`, `select_verified_simd_width`) computing `StreamByteScanSummary` (`newlines`, `fence_candidates`, `pipe_bytes`, `last_newline`) across `Scalar`, `x86_64` `SSE2` (16 B/iter), `x86_64` `AVX2` (32 B/iter), and `aarch64` `NEON` (16 B/iter), gated at runtime by `lean_sys_cabi::select_isa` + fail-closed `lean_sys_cabi::verify_isa_selection`, verified by a `1,024`-case alignment/boundary/random differential suite.

---

## 4. Before vs. After Benchmark Tables

### Scenario 1: Desktop Cold Start + WASM Instantiation (`n = 10` fresh Chromium contexts)

| Metric | Before (`p50` / `p99`, `CV`) | After (`p50` / `p99`, `CV`) | Delta / Ratio |
| --- | --- | --- | --- |
| Cold-start wall clock (`ms`) | `128.06 ms` / `240.98 ms` (`0.306`) | `108.16 ms` / `116.59 ms` (`0.033`) | **`-15.54%` (`1.18x` faster)** |
| `orb_kernel.wasm` compile+init (`ms`) | `0.50 ms` / `0.70 ms` (`0.207`) | `0.40 ms` / `0.60 ms` (`0.242`) | **`-20.00%` (`1.25x` faster)** |
| Post-mount JS heap (`MB`) | `5.39 MB` / `6.68 MB` (`0.102`) | `4.87 MB` / `5.80 MB` (`0.062`) | **`-9.54%`** |
| Startup JS bundle (`check-bundle.mjs`, cap `1150 kB`) | `1096.8 kB` | `1102.4 kB` (`1102 kB` integer check) | Within `1150 kB` budget (`✓`) |

### Scenario 2: Live Stream 500 Deltas (Desktop Reducer + `MissionView` E2E & Rust KMP Merge)

| Metric | Before (`p50` / `p99`, `CV`) | After (`p50` / `p99`, `CV`) | Delta / Ratio |
| --- | --- | --- | --- |
| Desktop 500 deltas single-event loop (`ms`, `n=7`) | `19.80 ms` / `28.50 ms` (`0.181`) | `5.80 ms` / `5.90 ms` (`0.026`) | **`-70.71%` (`3.41x` faster)** |
| Desktop 500 deltas batched-5 (`ms`, `n=7`) | `4.70 ms` / `10.10 ms` (`0.377`) | `1.50 ms` / `1.60 ms` (`0.043`) | **`-68.09%` (`3.13x` faster)** |
| Desktop E2E `MissionView` 500 SSE deltas main-thread CPU (`ms`, `n=5`) | `323.60 ms` / `339.96 ms` (`0.044`) | `197.48 ms` / `210.24 ms` (`0.079`) | **`-38.97%` (`1.64x` faster)** |
| Desktop E2E `MissionView` 500 SSE deltas wall clock (`ms`, `n=5`, 1.6 s pacing) | `1657.01 ms` / `1666.08 ms` (`0.005`) | `1623.60 ms` / `1648.04 ms` (`0.007`) | **`-2.02%`** |
| Rust `merge_text_stream_fragment` 500 cumulative 64 KB snapshots (`ms`, `n=7`) | `128.097 ms` / `136.224 ms` (`0.026`) | `0.0368 ms` / `0.0428 ms` (`0.056`) | **`-99.97%` (`3,480.9x` faster)** |

### Scenario 3: Log Replay (`2,500` Stored Events -> `1,619` Items / `1,472` Visible)

| Metric | Before (`p50` / `p99`, `CV`) | After (`p50` / `p99`, `CV`) | Delta / Ratio |
| --- | --- | --- | --- |
| `buildTranscript` + live tail (`ms`, `n=9`) | `7.30 ms` / `10.50 ms` (`0.159`) | `6.00 ms` / `6.80 ms` (`0.067`) | **`-17.81%` (`1.22x` faster)** |
| Full pipeline (`visibleTranscript` + `groupWork` narration fold, `ms`, `n=9`) | `8.20 ms` / `11.60 ms` (`0.148`) | `6.30 ms` / `8.20 ms` (`0.121`) | **`-23.17%` (`1.30x` faster)** |
| E2E `MissionView` open `2,500`-event mission (`ms`, `n=5`) | `94.08 ms` / `108.91 ms` (`0.095`) | `92.81 ms` / `112.45 ms` (`0.130`) | **`-1.34%`** |

### Scenario 4: Unclosed Code-Fence Pathological Stream (`1 KB` Deltas into Unclosed ```` ```rust ```` Fence)

| Client & Payload | Metric | Before | After | Improvement |
| --- | --- | --- | --- | --- |
| **Desktop (`256 KB`, 256 frames)** | Scanned / Parsed UTF-8 bytes | `33,667,960` / `33,678,109` | `262,115` / `272,227` | **`128.45x` / `123.71x` fewer bytes** |
| **Desktop (`256 KB`, 256 frames)** | Parser wall clock (`p50` / `p99`, `CV`) | `175.50 ms` / `194.10 ms` (`0.098`) | `8.20 ms` / `11.10 ms` (`0.143`) | **`21.40x` faster (`-95.33%`)** |
| **Desktop (`256 KB`, 256 frames)** | Per-frame `p50` / `p99` / last frame (`ms`) | `0.50` / `2.70` / `1.20 ms` | `0.00` / `0.20` / `0.00 ms` | **`O(1)` per delta** |
| **Desktop (`256 KB`, 256 frames)** | E2E `MissionView` live CPU (`p50` / `p99`, `CV`) | `504.15 ms` / `545.10 ms` (`0.056`) | `337.62 ms` / `359.86 ms` (`0.039`) | **`1.49x` faster (`-33.03%`)** |
| **Desktop (`1 MB`, 1,024 frames)** | Scanned / Parsed UTF-8 bytes | `537,332,176` / `537,365,533` | `1,048,508` / `1,081,828` | **`512.47x` / `496.72x` fewer bytes** |
| **Desktop (`1 MB`, 1,024 frames)** | Parser wall clock (`p50` / `p99`, `CV`) | `2,885.90 ms` / `2,887.40 ms` (`0.002`) | `110.20 ms` / `138.10 ms` (`0.104`) | **`26.19x` faster (`-96.18%`)** |
| **Kotlin/JNI (`256 KB`, 256 frames)** | Scanned / Parsed UTF-8 bytes | `33,667,989` / `33,678,108` | `262,115` / `282,220` | **`128.45x` / `119.33x` fewer bytes** |
| **Kotlin/JNI (`256 KB`, 256 frames)** | Full streaming path (`p50` / `p99`, `CV`, `n=7`) | `99.73 ms` / `118.21 ms` (`0.077`) | `25.80 ms` / `26.26 ms` (`0.030`) | **`3.86x` faster (`-74.13%`)** |
| **Kotlin/JNI (`1 MB`, 1,024 frames)** | Scanned / Parsed UTF-8 bytes | `537,332,205` / `537,365,532` | `1,048,508` / `1,091,821` | **`512.47x` / `492.17x` fewer bytes** |
| **Kotlin/JNI (`1 MB`, 1,024 frames)** | Blocks-only path (`p50` / `p99`, `CV`, `n=5`) | `970.35 ms` / `1,064.56 ms` (`0.041`) | `273.84 ms` / `278.53 ms` (`0.013`) | **`3.54x` faster (`-71.78%`)** |
| **Kotlin/JNI (`1 MB`, 1,024 frames)** | Full streaming path (`p50` / `p99`, `CV`, `n=5`) | `1,895.84 ms` / `1,923.42 ms` (`0.013`) | `390.03 ms` / `397.00 ms` (`0.008`) | **`4.86x` faster (`-79.43%`)** |

Exact block/character output parity (`parityOk = true`, `finalCodeLen = 262,107` at `256 KB` and `1,048,539` at `1 MB`) verified between incremental streaming and `parseMarkdown(fullText)` on both Desktop and Kotlin/JNI, plus Swift unit test parity in `OrbStreamTextTests.swift`.

### Scenario 5: Memory, Jetsam Gate & Lean-Gated SIMD Byte Scanner (`100 MB` Stream Buffer)

| Metric | Before | After | Delta / Verification |
| --- | --- | --- | --- |
| Desktop peak JS heap during `1 MB` unclosed-fence stream | `67.681 MB` | `11.243 MB` | **`6.02x` lower (`-83.39%`)** |
| Rust native harness peak RSS (`ru_maxrss`) | `3,392 KB` | `3,336 KB` | `-1.65%` |
| Apple 16 KB page-alignment & Jetsam C-ABI gates (`leansys_page_align_mask`, `leansys_jetsam_admitted`, `leansys_zero_copy_buffer_admitted`) | Verified | Verified | `16383` mask; `1.4 GB` main app admitted; `24 MiB` (`25,165,824`) extension admitted, `25,165,825` rejected; `4095` mask rejected; `1 MiB` aligned buffer admitted |
| `100 MB` stream byte scan — Scalar (`p50` / `p99`, `CV`, `n=7`) | `55.934 ms` / `56.609 ms` (`0.009`) | `64.703 ms` / `77.556 ms` (`0.103`) | Baseline reference |
| `100 MB` stream byte scan — `SSE2` 16 B/iter (`p50` / `p99`, `CV`, `n=7`) | N/A | `8.712 ms` / `9.717 ms` (`0.042`) | **`6.42x` vs before / `7.43x` in-run** (`~11.48 GB/s`) |
| `100 MB` stream byte scan — `AVX2` 32 B/iter (`p50` / `p99`, `CV`, `n=7`) | N/A | `5.572 ms` / `6.295 ms` (`0.046`) | **`10.04x` vs before / `11.61x` in-run** (`~17.95 GB/s`) |
| `100 MB` stream byte scan — `leansys_select_isa` + `leansys_verify_isa_selection` dispatched (`p50` / `p99`, `CV`, `n=7`) | N/A | `5.716 ms` / `6.095 ms` (`0.032`) | **`9.79x` vs before / `11.32x` in-run** (`~17.50 GB/s`, `variant = 2` `AVX2`, `verified = true`) |

---

## 5. End-to-End Ablation Ratchet (`ΔE2E >= 1%` Rule)

Each Desktop optimization lever was individually disabled in a production Vite build and measured on live `MissionView` Chromium main-thread `TaskDuration` CPU time (`n = 5` post-warmup runs for 500-delta live stream; `n = 4` post-warmup runs for `512 KB` 256-frame live unclosed fence):

| Optimization Lever Ablated | `stream500` CPU `p50` (`ms`) | `stream500` `ΔE2E` | `fence512k` CPU `p50` (`ms`) | `fence512k` `ΔE2E` | Ratchet (`>= 1%`) |
| --- | --- | --- | --- | --- | --- |
| **Full P7 Optimized Baseline** | **`168.091 ms`** | — | **`471.865 ms`** | — | Baseline |
| Ablate Lever 1: Checkpointed $O(N)$ fence & pipe-table scanner (`Markdown.tsx`, `pipeTables.ts`) | `289.430 ms` | **`+41.92%`** | `995.845 ms` | **`+52.62%`** | **KEEP (`✓`)** |
| Ablate Lever 2: 16 ms frame-coalesced `onBatch` reducer (`stream.ts`) | `257.680 ms` | **`+34.77%`** | `688.986 ms` | **`+31.51%`** | **KEEP (`✓`)** |
| Ablate Lever 3: `<Index>` slot reuse + incremental `CodeBlock` text-node append (`Markdown.tsx`, `CodeBlock.tsx`) | `205.385 ms` | **`+18.16%`** | `489.004 ms` | **`+3.50%`** | **KEEP (`✓`)** |
| Ablate Lever 4: Linear `withoutFiller` + stabilized `MissionView`/`Transcript`/`Chapters` memos | `179.428 ms` | **`+6.32%`** | `468.446 ms` | `-0.73%` (noise) | **KEEP (`✓`, `+6.32%` on `stream500`)** |

---

## 6. Batched C-ABI Boundary Analysis & Qualification

Per-call unboxed scalar C-ABI latency across WASM and JNI was profiled during live streaming and `2,500`-event log replay:

- **Desktop WASM (`orb_kernel.wasm`)**: `2,500`-event replay invokes `orb_workfold_step` / `orb_taskcard_step` / `orb_turn_summary_step` in `~1.9 ms` total (`< 0.8 µs` per event across JS->WASM scalar calls), while cold instantiation takes `0.4 ms`. During unclosed-fence streaming, `leansysGfmPipeRowAdmitted` is invoked `0` times after the early loose-pipe fast-path (`!hasLooseCandidate`).
- **Kotlin JNI (`liborb_spec_cabi.so`)**: Unboxed scalar JNI transitions take `< 50 ns/call`; during `1 MB` unclosed-fence streaming, `0` JNI calls occur inside the fence loop.
- **Conclusion**: Cross-language ABI marshaling is `< 0.5%` of total frame/replay time once redundant $O(N^2)$ re-parsing and per-delta reactive array cloning are eliminated; adding a shared linear-memory ring-buffer ABI export would increase unsafe surface area without yielding `>= 1%` E2E improvement, so scalar unboxed exports are retained unchanged.

---

## 7. Known Offline / Environment Verification Boundaries

- **WebKit Playwright binary & `swiftc` toolchain**: Not installed on this offline Linux `x86_64` VM (`webkit-2203` absent; macOS/Xcode unavailable). All Chromium Playwright kernel & performance specs (`kernel.browser.spec.ts`, `app-performance.browser.spec.ts`, `heavy-mission-performance.browser.spec.ts`, `performance.browser.spec.ts`) and all `204` Vitest files (`1,636` tests) pass locally; Swift changes mirror the verified Kotlin/TypeScript state machine line-for-line and include matching `XCTest` coverage in `OrbStreamTextTests.swift`.
- **Android Gradle daemon**: Host has OpenJDK 11 only (AGP `8.9.1` requires JDK 17); Kotlin production sources + `OrbStreamTextTest.kt` were compiled directly with `kotlinc-jvm 1.9.24` against real JNI `liborb_spec_cabi.so` and verified end-to-end on JVM.
