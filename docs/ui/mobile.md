# Orb native presentation

The SwiftUI and Compose clients share the desktop's neutral visual language:
`#191919` surfaces, `#333333` strong borders, 6pt/dp control corners and 12pt/dp
composer/panel corners. Android Material actions use neutral colors too. Native sheets, text input, gestures and focus remain platform controls. Semantic colors identify agent state; ordinary actions use
neutral text.

Inbox is a continuous list. Each row starts with quiet project/status metadata,
then a two-line title and a bounded result. Avoid rounded cards inside the list,
duplicate Goal badges, and colored button backgrounds for routine actions.
Original requests and work receipts remain available when the row is expanded.
Read state is also exposed to accessibility, rather than relying on font weight.
Inbox actions and filters retain 44pt (iOS) / 48dp (Android) touch areas even
when their visible labels and borders are compact.

Use `OrbStyle` in `OrbProjects.swift` (iOS) and `OrbTheme.kt` (Android) for shared
surfaces and radii. Android Material sheets/dialogs inherit these radii from
`SandboxedTheme`; existing native iOS alerts keep system behavior.

## Device verification

Run the deterministic server from `ios_dashboard/`:

```sh
python3 TestsSupport/orb_fixture_server.py --port 18766
```

The iOS `OrbFlowUITests` cover Inbox layout, working rows, preview, unsent reply, the main
composer with the keyboard, and the agent/model sheet. Run the targeted tests
on an iPhone simulator. The fixture server is loopback only.

Android device checks use a separate application ID to preserve the installed
app's account and drafts:

```sh
cd android_dashboard
adb reverse tcp:18766 tcp:18766
ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew \
  :app:connectedDebugAndroidTest --max-workers=1
```

`OrbPolishTest` uses UI Automator and the `.preview` application ID that every debug build carries.
It exercises Inbox, preview, an unsent reply, the conversation composer and the
model picker. Screenshots are saved in the preview app's external files directory.
Unlock the device before running these visual checks. Do not uninstall or clear the normal app for visual testing.

The current evidence, screenshots and device limitations are recorded in
[mobile validation](mobile-validation.md).

## Conversation and project cache restoration

Opening an existing conversation or project first restores the account-scoped
cache, then refreshes from Core. Disk reads and JSON decoding for conversation
history, event history and project mission rows must not run on the UI thread.
Memory hits remain immediate. A newer network value wins over a pending disk read.

List projections do not own conversation history: a summary with empty history
must not hide a full disk conversation after memory trimming. A global roster
limited to the latest 100 missions must not replace a project's cached roster;
only the project response owns removals. Fresh global rows update known missions
and can seed a missing cache.

Regression order: save full history/project rows, clear memory, receive a partial
global list, reopen offline. The saved answer and older project rows must remain
visible without waiting for network. Refresh errors retain cached content.

### Desktop progressive loading

On a cold conversation open, clients request the presentation snapshot before
the raw activity tail. Desktop falls back to two transcript events on older Core. Persisted messages can paint while activity and
queue reads remain pending. This preview has no raw replay cursor and cannot
satisfy a complete load or refresh; reconnect and older-page merges still use
the full raw page cursor. Partial snapshots remain retryable after failure.
The activity skeleton uses the existing reduced-motion-aware shimmer. Live SSE
received during hydration is held and reconciled by the existing replay owner.

iOS and Android restore a separate presentation cache before the full refresh.
Preview messages never advance the event cursor. All three clients keep a bounded
recent-conversation cache current through foreground compact stream hints; mobile
streams are cancelled when the app stops being active.

Text rows and work-fold containers have distinct keys: hydration must never
mutate a mounted Markdown row into a tool-group variant.
