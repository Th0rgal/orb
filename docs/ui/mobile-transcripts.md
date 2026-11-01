# Mobile Transcript Safety & Native Rendering Contract

This specification records the architecture and formal invariants preventing crash, OOM, ANR, and WebView IPC hangs on long, math- and table-heavy missions (such as `boost.ci`: `e352c2be-f908-4e34-9694-ccc23688ca8b`) across Orb iOS (`ios_dashboard/SandboxedDashboard/Orb`) and Orb Android (`android_dashboard`).

## 1. Zero Embedded WebViews in Conversation Transcripts

Conversation rows never mount `android.webkit.WebView` or `WKWebView`:

- **Native Markdown & Loose Pipe Tables**: `OrbPipeTables` normalizes bare `a | b | c` rows (both `\n` and `\r\n` CRLF inputs) into GFM tables gated by `OrbKernel.gfmPipeRowAdmitted` and `OrbKernel.numericCellAdmitted`, verified against `shared/orb-spec/fixtures/loose-pipe-tables.json`.
- **Native LaTeX Math (`OrbMath`)**: Inline (`$...$`, `\(...\)`) and display (`$$...$$`, `\[...\]`) LaTeX render directly to native `AttributedString` (SwiftUI) and `AnnotatedString` (Jetpack Compose) via bounded recursive-descent formatting (`MAX_DEPTH = 16`, `MAX_SPAN_CHARS = 8192`) with an LRU cache (`capacity = 512`).
- **Native Downsampled Images**: Inline Markdown images decode off the main thread (`ImageIO` `CGImageSourceCreateThumbnailAtIndex` on iOS; two-pass `BitmapFactory.Options.inJustDecodeBounds` + `inSampleSize` on Android) capped at `1600 px` max dimension and `20 MiB` network payload.
- **Bounded Offscreen Mermaid Snapshotter (iOS)**: `OrbMermaidRenderer` renders fenced `mermaid` blocks to static `UIImage` snapshots with strict `8 s` page-load and `6 s` `callAsyncJavaScript` continuation timeouts, recovering cleanly on `webViewWebContentProcessDidTerminate`.

## 2. Formal `Orb.Transcript` Invariants (`lean/Orb/Transcript.lean`)

`lean/Orb/Transcript.lean` (`0 import Lean`, `0 sorryAx`, audited by `turbo-lean --json audit-spec`) proves three cross-platform properties mirrored in `orb/src/transcriptGates.ts`, `OrbTranscriptGates` (`OrbPipeTables.swift`), and `OrbTranscriptGates.kt`, and checked against `shared/orb-spec/fixtures/transcript-gates.json`:

1. **Injective Turn-Key Allocation (`allocTurnKeys_nodup`, `allocTurnKeys_fresh_gen_zero`)**:
   Every turn list passed to Jetpack Compose `LazyColumn(items(..., key = { it.id }))` or SwiftUI `ForEach` passes through `OrbTranscriptGates`. Already-distinct non-empty IDs remain untouched (`gen = 0`), while empty or colliding keys (retried canonical bubbles, empty cloud turn keys, repeated optimistic turns) receive strictly monotonic `#gen` suffixes so duplicate-key runtime exceptions are impossible.
2. **Pandoc-Aligned Inline `$` LaTeX Gate (`latexSpanAdmitted_iff`, `currency_span_rejected`, `oversized_latex_span_rejected`)**:
   Admits inline `$` spans iff `0 < len ≤ 8192`, unescaped/unblocked at both ends, single-line, and not prose currency (`$15 and $20` where `firstDigit && internalSpace && !hasMathOp`).
3. **Transcript Window & Active Mount Conservation (`visible_plus_hidden_conserved`, `visibleTurnCount_monotone_steps`, `admitMount_bounded`)**:
   Splitting `total` turns into `hiddenTurnCount + visibleTurnCount` conserves `total`, grows monotonically as older history is expanded, and bounds active heavy mounts at `cap`.

## 3. Bounded Payloads & Storage Guards

- **`POST /api/control/missions/:id/opened`**: Returns a compact `{ id, user_opened_at, updated_at }` receipt rather than re-serializing full mission history (`mark_mission_opened` in `src/api/control/mission_settings.rs`).
- **App-Group / Preferences Size Cap**: `OrbSharedInboxState` skips `UserDefaults` persistence when encoded JSON exceeds `512 KiB`, preventing iOS `cfprefsd` Jetsam kills.
- **Privacy-Safe Crash Breadcrumbs**: `OrbCrashBreadcrumbs` records only structural metadata (screen name, mission UUID, event count, heap KB, exception class — never prompts, tokens, or message text).

## 4. Verification & Differential Fuzzing

- **Real Production Replay**: `shared/orb-spec/fixtures/transcripts/boost_ci.json` (481 events) replays natively in `BoostCiTranscriptTest.kt` and `OrbRichTextTests.swift` asserting zero WebViews and unique turn keys.
- **Headless Pure SwiftPM Package**: `ios_dashboard/OrbModelPackage` compiles pure Foundation models + `orb_kernel_unboxed.c` directly under `swift test` on both macOS and Linux Boat VMs without Simulator overhead.
- **500-Seed Deterministic Property Fuzzing**: `orb/tests/transcript-gates.test.ts`, `OrbTranscriptFuzzTest.kt`, `OrbModelPackageTests.swift`, and `OrbRichTextTests.swift` fuzz arbitrary pagination/SSE interleavings, duplicate bubble IDs, CRLF tables, non-BMP surrogates (`🔹`), and unclosed LaTeX braces on every CI run.
