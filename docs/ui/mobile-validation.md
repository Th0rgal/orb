# Native mobile UI validation — 2026-10-09

Scope: shared neutral surfaces/radii, quieter home controls, continuous Inbox
rows, readable title/metadata separation, compact composer and native selector
surfaces. Backend requests and triage operations are unchanged.

## Build and test environment

- Checkout: `sandboxed_sh-overlay-system`, branch `feat/orb-overlay-system`.
- Android target: connected Pixel 8, Android 17.
- Android verification variant: `sh.sandboxed.dashboard.preview` (`Orb Preview`).
  The normal `sh.sandboxed.dashboard` package and its data are preserved.
- iOS target: iPhone 17 Pro simulator, iOS 26.5,
  `B0C48C19-4FAA-45A2-840B-1D950391136C`.
- The simulator's original app data was backed up before fixture tests at
  `/tmp/orb-mobile-original-simulator-data`.
- Fixture server: `ios_dashboard/TestsSupport/orb_fixture_server.py`, loopback
  port 18766; Android reaches it through `adb reverse`.

The initial Compose/Espresso device harness failed before rendering the test
with `NoSuchMethodException: android.hardware.input.InputManager.getInstance`
on Android 17. The device tests now use the supported
[UI Automator test framework](https://developer.android.com/jetpack/androidx/releases/test-uiautomator).
This changes test infrastructure, not app behavior.

An existing iOS Inbox model test called a main-actor-isolated builder from a
nonisolated test method. Marking that test `@MainActor` restores compilation
without changing the model. Its clipping assertion now supplies an explicit
character limit, matching the existing behavior that keeps prose below the
summary budget intact.

## Results

- Android debug app and instrumentation APK compile successfully with
  `-PorbPreview`; `testDebugUnitTest` has no source tests in this project.
- The final preview APK is installed on the connected Pixel 8. Its installed
  SHA-256 matches the build output:
  `87b48beae46ca55e0e9f5a31ab2db93922d35441c170fcf2a549b275cbcc0ed5`.
- The normal Android package remains at its original install path, with SHA-256
  `cac74ac0d872e8fa6b73a55d936b4558639659fe3729f7ad30637e283137e964`.
- Android visual acceptance is **pending**. The phone shows `AlternateBouncerView`
  (the lock screen); the user has been asked to unlock it. The new UI Automator
  tests have compiled but have not passed on the device yet.
- iOS: both UI flows and all 12 desktop-parity unit tests passed in
  `/tmp/orb-mobile-ios-acceptance.xcresult`. This covers the Inbox, working rows,
  Peek, inline reply with keyboard, 44pt actions, the compact main composer,
  keyboard avoidance and the model sheet.
- Inbox testing caught a plain SwiftUI button exposing only its text bounds.
  Adding an explicit content shape fixed the 44pt accessibility/touch frame.
- The separate composer rerun passed in `/tmp/orb-mobile-ios-draft.xcresult`:
  the exact multiline draft survives closing the model sheet.
- The original simulator data was restored after testing. All 98 backed-up
  files match byte-for-byte, and the simulator was rebooted to clear preference
  caches. The new app binary remains installed; the real app was not launched
  against its restored account.
- [Build receipt](mobile-receipt.json) records source-file hashes, installed
  binary hashes and the separate original/fixture data backups.

Build logs and test bundles are retained under `/tmp/orb-mobile-*`. These are
fixture checks, not tests against the user's production account. No messages
were sent and no real project or conversation was deleted.


## Reviewed iOS references

- [Inbox](mobile-references/ios-inbox.png)
- [Working rows](mobile-references/ios-inbox-working.png)
- [Inline reply and keyboard](mobile-references/ios-inbox-reply.png)
- [Main composer and keyboard](mobile-references/ios-composer-keyboard.png)
- [Native model sheet](mobile-references/ios-agent-settings.png)

These are native simulator captures from the built app, not mockups. The apps
retain their existing dark appearance; light mode, landscape and large Dynamic
Type are not acceptance claims for this pass. iOS sheets retain their system
presentation. Legacy dashboard pages with explicit colors are outside this
Orb Inbox/composer pass.
