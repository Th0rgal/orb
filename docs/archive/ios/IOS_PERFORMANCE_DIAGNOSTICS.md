# iOS Performance Diagnostics

Date: 2026-05-25

## Instrumentation Added

- `SandboxedDashboard/Services/ControlPerformanceDiagnostics.swift`
  - Adds `Logger` + `OSSignposter` under subsystem `md.thomas.openagent.dashboard`, category `ControlPerformance`.
  - Records recent slow operations and hot SwiftUI body render counts while the in-app diagnostics overlay is enabled.
- `SandboxedDashboard/Views/Control/ControlView.swift`
  - Existing **Control Diagnostics** menu toggle now also reports slowest measured operation and hottest body render probes.
  - Signposted/timed paths:
    - `control.fetch_snapshot`
    - `control.fetch_current_snapshot`
    - `control.fetch_reload_snapshot`
    - `control.fetch_switch_snapshot`
    - `control.fetch_refresh_snapshot`
    - `control.fetch_earlier`
    - `control.fetch_delta`
    - `control.apply_snapshot`
    - `control.sort_remember_events`
    - `control.replay_events`
    - `control.apply_delta`
    - `control.group_messages`
  - Body render probes:
    - `MessageBubble`
    - `ToolGroupView`
    - `MarkdownView`
- `SandboxedDashboard/Views/Components/MarkdownView.swift`
  - Adds `markdown.parse` timing when Control Diagnostics is enabled.
  - Caches parsed markdown blocks and inline `AttributedString(markdown:)` output by content hash.
- `SandboxedDashboard/Models/ChatHistoryReducer.swift`
  - Adds a pure historical replay reducer that builds chat messages with indexed ids/tool calls and assigns UI state once.
- `SandboxedDashboard/Services/ImageMemoryCache.swift`
  - Adds a shared `NSCache` image store and background ImageIO downsampling for inline/shared chat images.
- `SandboxedDashboard/Services/APIService.swift`
  - Adds whole-app request and decode timing for every JSON API call:
    - `api.request`
    - `api.decode`
  - This covers Control, History, Files, Settings, Workspaces, and other views using `APIService`.

## Simulator / Instruments Notes

Validated locally:

```bash
xcodebuild -project ios_dashboard/SandboxedDashboard.xcodeproj \
  -scheme SandboxedDashboard \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Result: build succeeded. Existing warning remains in `APIService.swift` about generic `T.Type` Sendability; it is unrelated to the diagnostics patch.

Tests:

```bash
xcrun simctl create OpenAgentPerf \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16 \
  com.apple.CoreSimulator.SimRuntime.iOS-26-4
xcrun simctl boot <device-id>
xcodebuild -project ios_dashboard/SandboxedDashboard.xcodeproj \
  -scheme SandboxedDashboard \
  -destination 'id=<device-id>' \
  test
```

Result: 30 tests passed. Existing Swift 6 actor warnings remain in `NetworkResilienceTests` for `ControlView.migrateMissionCacheIfNeeded()` calls from a non-main-actor test method; unrelated to this performance pass.

Trace work:

```bash
for template in 'SwiftUI' 'Time Profiler' 'Animation Hitches'; do
  xcrun xctrace record \
    --template "$template" \
    --device <device-id> \
    --launch md.thomas.openagent.dashboard \
    --time-limit 5s \
    --output "/tmp/SandboxedDashboard-${template// /-}.trace"
done
```

Result:
- SwiftUI launched the app and saved `/tmp/SandboxedDashboard-SwiftUI.trace`, but reported that the SwiftUI instrument is not supported on this Simulator runtime.
- Time Profiler launched the app, but did not end the recording after the requested 5-second time limit and was stopped by the timeout wrapper. A partial `/tmp/SandboxedDashboard-Time-Profiler.trace` bundle was left.
- Animation Hitches launched the app and saved `/tmp/SandboxedDashboard-Animation-Hitches.trace`, but reported that Hitches is not supported on this platform.

The temporary simulator was shut down and deleted. Manual Instruments capture on a physical iOS device, or a simulator/runtime that supports these instruments, is still useful with these templates:

```bash
xcrun xctrace record \
  --template 'SwiftUI' \
  --device <device-id> \
  --launch md.thomas.openagent.dashboard \
  --time-limit 30s \
  --output /tmp/SandboxedDashboard-SwiftUI.trace

xcrun xctrace record \
  --template 'Time Profiler' \
  --device <device-id> \
  --launch md.thomas.openagent.dashboard \
  --time-limit 30s \
  --output /tmp/SandboxedDashboard-TimeProfiler.trace

xcrun xctrace record \
  --template 'Animation Hitches' \
  --device <device-id> \
  --launch md.thomas.openagent.dashboard \
  --time-limit 30s \
  --output /tmp/SandboxedDashboard-Hitches.trace
```

In Console/Instruments, filter for:

```text
subsystem == "md.thomas.openagent.dashboard"
category == "ControlPerformance"
```

## Diagnostics

1. **Fixed: historical chat replay no longer replays through UI state.**
   `applyViewingMissionWithEvents` now uses `ChatHistoryReducer.reduce(events:mission:)`, which builds `[ChatMessage]` in a pure pass with indexed ids/tool calls/text-op buffers and assigns `messages` once. Live tail deltas still use `handleStreamEvent`, which is acceptable because those batches are small.

2. **Fixed: assistant markdown parsing is cached.**
   `MarkdownView` caches block parsing and inline attributed text by content hash. Cache misses still emit `markdown.parse` timing when Control Diagnostics is enabled.

3. **Fixed: chat rows have a narrower render boundary.**
   The conversation rows now live in `ConversationRowsView`, which receives only grouped items, copy/retry closures, and tool expansion state. Further row-level `Equatable` models are an optional follow-up if Instruments shows redraws from unrelated parent state.

4. **The diagnostics overlay itself is intentionally debug-only but can perturb results.**
   When enabled, body probes mutate an in-memory counter and `markdown.parse` timing wraps parsing. Use it to identify suspicious paths, then confirm with Instruments signposts with the overlay hidden.

5. **Fixed: large mission cache decode moves off the first render.**
   Small cache files keep the synchronous fast path. Cache files above the threshold are decoded in a detached task and applied only if they are still relevant and not older than an already-applied snapshot.

6. **Running-mission and child-mission polling can still invalidate ControlView regularly.**
   The code already backs off on failures and gates child-mission fetches, but successful 5-second polling mutates `runningMissions` on the parent view. This can drive redraws in the chat subtree unless the chat list is isolated from polling state.

7. **Fixed: list sorting/filtering is memoized outside body.**
   `HistoryView.filteredMissions`, `FilesView.sortedEntries`, and mission switcher running/recent/search sections are now state-backed and recomputed when their inputs change.

8. **Fixed: inline/shared images use a memory cache and downsampling.**
   `ImageMemoryCache` stores decoded images by URL and downscales large images off the main actor before SwiftUI renders them.

9. **Fixed enough: row timers are scoped to visible active work.**
   Tool/thinking timers only start after the row appears, only run while the tool/thought is active, and cancel on disappear/completion. A shared elapsed-time ticker is not needed unless future profiling shows many simultaneously active rows.

## Recommended Fixes

1. **Done: replace replay-through-UI-state with a pure reducer.**
   Build `[ChatMessage]` from `[StoredEvent]` in a pure function using dictionaries/sets for ids (`messageById`, `toolById`, active thinking id). Assign `messages` once at the end. This removes repeated array scans and avoids transient SwiftUI invalidations during replay.

2. **Done: cache parsed markdown per content hash.**
   Move markdown parsing out of `body`, or introduce a `ParsedMarkdown` cache keyed by message id + content hash. For streaming content, debounce parsing to frame cadence or parse only the active message incrementally.

3. **Done: isolate chat list state from toolbar/polling state.**
   Extract the conversation list into a small view model or child view that only receives `groupedItems`, copy/retry closures, and scroll state. Keep `runningMissions`, queue polling, sheets, and toolbar state out of the row subtree.

4. **Done: track rendered message ids during replay.**
   Even before a full reducer refactor, maintain a temporary `Set<String>` during historical replay so duplicate checks are O(1) instead of `messages.contains`.

5. **Done: move cache decode off the first render when the cache file is large.**
   For cache files over a small threshold, render the skeleton immediately and decode in a background task, then publish the decoded snapshot. Keep the current sync fast path for small cache files.

6. **Done: memoize sorted/filter lists outside view bodies.**
   For History, Files, and mission switcher/search, compute sorted/filter outputs when source arrays or query/filter settings change, not every `body` evaluation.

7. **Optional follow-up: use `EquatableView` or narrower Equatable row models for chat rows.**
   Make visible rows skip body work when unrelated state changes. This is especially important for assistant rows with expensive markdown.

8. **Done: add image cache and downsampling.**
   Use `URLCache`/`NSCache` keyed by resolved download URL and downsample large images before storing in SwiftUI state. This should reduce both network repeat work and memory spikes.

9. **Done with current simulator limits: run trace templates on a configured simulator session.**
   All three requested templates were run against a booted iPhone 16 simulator. SwiftUI and Animation Hitches are unsupported by this simulator/runtime; Time Profiler launches but does not stop cleanly from `xctrace` here. Use a physical device for complete trace data.
