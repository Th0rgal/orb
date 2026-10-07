# Orb on iPhone: local agents and computer use

Status: implemented as a vertical slice in this repository; **not yet run on a
physical iPhone** (see [Verification status](#verification-status)). Research
current as of 2026-10-07 (iOS 26 shipping, iOS 27 in developer beta).

## The answer to the critical question

> What is the maximum autonomous control of the entire iPhone achievable from
> a self-contained TestFlight application on stock iOS?

**Observe everything, navigate between apps, type into focused fields, and run
user Shortcuts — but never touch.** Concretely, with no external machine:

| Primitive | Achievable? | Mechanism |
|---|---|---|
| See the whole screen, any app | **Yes**, after one user tap to start | ReplayKit broadcast upload extension (iOS 26); `SCContentSharingPicker` on iOS 27 |
| Read on-screen text | **Yes** | Vision OCR on broadcast frames, on device |
| Open another app / deep link | **Yes** (foreground); measured per device when backgrounded | `UIApplication.open`, universal links, URL schemes |
| Run multi-step automations in other apps | **Yes**, within what Shortcuts actions offer | `shortcuts://x-callback-url/run-shortcut` |
| Type into the focused field of another app | **Yes**, only while the Orb keyboard is the active keyboard | Custom keyboard extension + `UITextDocumentProxy` |
| Press return / delete | **Yes**, same condition | `UITextDocumentProxy` |
| **Tap / swipe / scroll / long-press at coordinates in another app** | **No** | No public or requestable API exists |
| **Focus a text field in another app** | **No** | Requires a tap |
| **Activate an accessibility element in another app** | **No** | Assistive-tech APIs are consumer-facing, not programmable |
| Read another app's accessibility tree | **No** | Not exposed to third-party apps |
| Invoke another app's App Intents directly | **No** | Only Siri/Shortcuts (the system) can; apps can run a *Shortcut* that does |

**The exact missing primitive is cross-app input injection** (synthesizing a
touch event delivered to another process). Everything an agent needs that does
not require a touch is implemented. Agents are told this explicitly through the
`capabilities` tool so they plan around it (deep links with prefilled
parameters, Shortcuts, keyboard) instead of requesting coordinates.

## Capability matrix

| Capability | TestFlight | Technical reason |
|---|---|---|
| Run agent harness processes on the phone | **Yes** (with iSH ARM64 linked) | `fork`/`exec`/`posix_spawn` are unavailable to App Store/TestFlight apps and JIT is forbidden. OpenMinis' iSH ARM64 fork runs an AArch64 Alpine userland **inside Orb's process** with a threaded-code interpreter that emits no machine code (same approach as iSH on the App Store, and OpenMinis itself ships on the App Store). Guest fork/exec/pipes/PTYs are emulated; guest sockets are host sockets. |
| Shell, PTY, pipes, process tree | **Yes** (runtime linked) | Emulated by the iSH kernel layer (`/dev/ptmx`, `devpts`). |
| Filesystem + persistent workspaces | **Yes** | fakefs root in Application Support; workspaces bind-mounted at `/root/work`; both survive termination. |
| git, Node 22 (`--jitless`), Go, Rust binaries | **Yes, slow** (runtime linked) | AArch64 guest under interpreter: 3–30× native per upstream benchmarks; V8 runs jitless. |
| Codex CLI | **Expected yes, unmeasured** | Rust musl aarch64 binary inside the guest. Not yet measured on device. |
| Claude Code | **Unmeasured** | Since 2.1.113 ships a Bun-compiled native binary (`linux-arm64-musl`); `cli.js` up to 2.1.112 runs on Node. Both must be measured in the guest. |
| OpenCode | **Unmeasured** | Bun-compiled native binary (`linux-arm64-musl`). |
| Antigravity CLI (`agy`) | **No (today)** | Closed-source native binary with no published linux-arm64-musl build installable in the guest; Orb reports it unavailable instead of faking it. |
| Built-in Codex-style computer use (no runtime needed) | **Yes** | In-app Responses API `computer` tool loop through Orb Core's `/v1` proxy (`ComputerUseAgent`). Network only. |
| Codex CLI ↔ iPhone computer tools | **Yes** | In-app loopback MCP server (`127.0.0.1`, bearer token); Codex/Claude Code/OpenCode load it as a remote MCP server. Codex's own "Computer Use" plugin is macOS/Windows-only and drives desktop accessibility; this replaces it with an iOS environment. |
| Screen observation of other apps (iOS 26) | **Yes** (user starts it once) | Broadcast upload extension (`com.apple.broadcast-services-upload`), separate process, ~50 MB memory limit, keeps capturing while Orb is suspended. `RPSystemBroadcastPickerView` can preselect Orb Screen but **cannot start without the user's tap**. |
| Screen observation (iOS 27) | **Probably** | ScreenCaptureKit (`SCStream`, `SCContentSharingPicker`) is available on iOS 27 and ReplayKit broadcast APIs are deprecated. Background capture uses the new `screen-capture` background mode; field reports conflict on whether it works on device and passes App Store Connect. Orb keeps the ReplayKit path, which still works on 27. |
| On-device OCR | **Yes** | Vision `VNRecognizeTextRequest`. |
| Frame de-duplication / low bandwidth | **Yes** | 24×48 luminance grid diff in the extension; frames are only written on material change (+30 s keyframe); configurable max dimension and FPS. |
| Text injection into other apps | **Yes, conditional** | Custom keyboard + Full Access. Works only while the Orb keyboard is the *active, visible* keyboard and a field is already focused. Never available in secure or phone-pad fields, or in apps that disallow custom keyboards. A keyboard cannot run or receive commands while hidden. |
| Read text around the cursor | **Yes, conditional** | `documentContextBeforeInput/AfterInput`, same conditions. Never secure fields. |
| Open apps / URLs | **Yes** | `UIApplication.open`. `LSApplicationQueriesSchemes` limits `canOpenURL` probes (50 entries, 25 on iOS 27+); opening does not need the allowlist. |
| Open apps while Orb is backgrounded | **Measured per device** | Undocumented; Orb records the result and, when refused, posts a notification the user taps to continue. |
| Run Shortcuts | **Yes** | `shortcuts://x-callback-url/run-shortcut` with text input; result returns via x-success. Shortcuts may show its own permission prompts. |
| Call another app's App Intents directly | **No** | No public API; only via a user Shortcut. |
| Share sheet | **Yes** (user picks target) | `UIActivityViewController`, foreground only. |
| Clipboard | **Yes** | `UIPasteboard`; reading may show iOS's paste prompt. |
| Background execution of a running turn | **Partial** | iOS 26 `BGContinuedProcessingTask`: user-initiated, shows system progress UI, user-cancellable, can be expired. Otherwise ~30 s grace via `beginBackgroundTask`. Audio/location modes as keep-alive are not legitimate (App Review 2.5.4) and are not used. |
| Resume after suspension/termination | **Yes** | Checkpoint per mission (native session id, in-flight prompt). On reopen: close the stale Core run, begin a new one, resume the native session. |
| Tap/swipe/scroll in other apps | **No** | See below. |

## Accessibility / system-control investigation

| Candidate | Observe other app | Tap coordinate | Activate element | Type | User interaction | External host | Public API | Entitlement | TestFlight |
|---|---|---|---|---|---|---|---|---|---|
| ReplayKit broadcast extension | Yes | No | No | No | Start once | No | Yes | None | Yes |
| ScreenCaptureKit (iOS 27) | Yes | No | No | No | Picker once | No | Yes | None (background mode `screen-capture`) | Unknown (conflicting reports) |
| Custom keyboard (Full Access) | Cursor context only | No | No | Yes (focused field, keyboard visible) | Enable once + field focus | No | Yes | None | Yes |
| URL schemes / universal links | No | No | No | Prefill via params | No (foreground) | No | Yes | None | Yes |
| Shortcuts URL scheme | No | No | Only via Shortcuts actions | Via actions | Possibly first-run prompt | No | Yes | None | Yes |
| App Intents / App Shortcuts / iOS 27 App Schemas | Own app only | No | Own app only | No | Siri-invoked | No | Yes | None | Yes |
| Visual Intelligence / `IntentValueQuery` / View Annotations | Own app's content to Siri | No | No | No | Yes | No | Yes | None | Yes |
| iOS 27 `LongRunningIntent` | No | No | No | No | Siri-invoked | No | Yes | None | Yes |
| Voice Control | User's voice drives *all* apps | Yes (for the user) | Yes (for the user) | Yes | Yes (speech) | No | **No API** | — | — |
| Switch Control | — | Yes (for the user) | Yes (for the user) | — | Yes (switch hardware) | No | **No API** | — | — |
| AssistiveTouch | — | Yes (for the user) | — | — | Yes | No | **No API** | — | — |
| UIAccessibility (UIKit) | Own app only | Own app only | Own app only | Own app only | — | No | Yes | None | Yes |
| MDM (incl. supervised) | No | No | No | No | — | MDM server | Yes | MDM | N/A (remote view-only products use broadcast) |
| XCUITest / WebDriverAgent | Yes | Yes | Yes | Yes | — | **Yes**: testmanagerd must be started by a host over RemoteXPC (iOS 17+); devicectl fallback removed on iOS 27 | Test-only | Developer Mode + "Enable UI Automation" | **No** (cannot be launched on device alone) |
| Private SPI (`XCSynthesizedEventRecord`, IOHID) | Yes | Yes | Yes | Yes | — | DDI mount / pairing | **No** | — | **No** |

No Apple-documented entitlement grants cross-app input injection, assistive
technology control, or accessibility-tree access of other apps. There is none
to request. Orb does not use private APIs; none are needed for this slice.

## Architecture as implemented

```text
Orb Core (unchanged execution model: placement:"client" never starts a harness)
  /api/control/clients                POST register {client_id, platform:"ios", runtime, capabilities}
  /api/control/clients/:id/inbox      GET  prompts + follow-ups for missions this phone owns
  /api/control/missions               POST {placement:"client", client_id} → tags worker-client:<id>, client-platform:ios
  /api/control/missions/:id/client-run      begin / received / verify (run receipt, generation)
  /api/control/missions/:id/client-events   normalized tool_call/tool_result/thinking/text_delta/error stream
  /api/control/missions/:id/client-transcript, client-status   (existing)
  /v1/responses, /v1/messages               inference via per-mission proxy key
        ▲
        │ HTTPS (the only network peer)
Orb iOS
  LocalAgentNode ─ registration, inbox, proxy keys, scene phase, BGContinuedProcessingTask
  LocalMissionRunner (OrbLocalKit) ─ one IOSLocalHarness per mission, checkpoints, lifecycle states
     CLIHarness + HarnessDialect {Codex, Claude Code, OpenCode, Antigravity}
        └─ ISHLinuxRuntime (UnixRuntime) ─ OrbLinuxBridge.c ─ iSH ARM64 (optional link)
     ComputerUseAgent (Responses `computer` tool) ─ no runtime needed
  IOSComputerMCPServer + LoopbackMCPServer (127.0.0.1, bearer)
  OrbIOSActionExecutor ─ open_url/open_app/app_action/run_shortcut/type_text/clipboard/share/screenshot/observe
     ScreenObservationService ◄─ App Group ◄─ OrbScreenBroadcast (ReplayKit extension)
     KeyboardCommandQueue ─ App Group ─► OrbKeyboard (keyboard extension)
     AppRegistry ─ doc-sourced deep-link templates + on-device observations
```

Mission state is explicit: `running`, `background_running`, `suspended_by_ios`,
`resume_required`, `interrupted`, `completed`, `failed`. Execution never moves
to Core; a suspended mission stays the phone's and a notification asks the user
to reopen Orb.

## Building with the Linux runtime

The iSH ARM64 interpreter is GPLv3 with an App Store distribution exception
(`LICENSE.IOS`). It is **not vendored**; linking it is an explicit build choice:

```sh
git clone https://github.com/OpenMinis/ish-arm64 && cd ish-arm64
git checkout e6521d9cfe9cd48f19917fc3b23aea622ba358b4   # bridge verified against this
# build libish.a, libish_emu.a, libfakefs.a for iphoneos arm64 (see app/xcode-meson.sh)
```

Then set, for the `SandboxedDashboard` target (e.g. in an xcconfig or Xcode
Cloud environment):

```
ORB_ISH_DEFINES = ORB_WITH_ISH=1 GUEST_ARM64=1 ENGINE_ASBESTOS=1
ORB_ISH_SOURCE_DIR = /path/to/ish-arm64
ORB_ISH_LDFLAGS = /path/to/build-arm64/libish.a /path/to/build-arm64/libish_emu.a /path/to/build-arm64/libfakefs.a -lsqlite3 -larchive
```

Distributing a build that links it makes Orb subject to the GPL for that
binary; decide that before shipping. Without it, `unix_shell` is `false`, CLI
harnesses report unavailable, and the built-in computer-use engine still works.

## TestFlight / App Review notes

- **Downloading the Alpine root filesystem and npm packages** at the user's
  request is the same model iSH and OpenMinis ship with; review risk is
  moderate under 2.5.2 (code that changes app behaviour). Orb's own features do
  not change; the guest runs user-chosen tools in a sandboxed interpreter.
- **Keyboard (4.4.1)**: must work without Full Access (it does: manual
  return/delete/globe), must not launch other apps (it does not), and must
  explain data use. Typed content is never stored.
- **Broadcast extension**: the system shows a recording indicator; Orb's copy
  explains that agents see the screen while it is on.
- **Background (2.5.4)**: only `BGContinuedProcessingTask` for user-started
  missions; no audio/location keep-alive.
- **Local network prompt**: the loopback MCP server binds 127.0.0.1 only.

## Verification status

Done here, without an iPhone:

- Core: client registry, iPhone-owned mission creation, inbox routing,
  structured event ingest, receipt enforcement — Rust unit + integration tests.
- OrbLocalKit (all platform-neutral logic: four harness dialects, CLI engine,
  runner, lifecycle, checkpoint/resume, computer-use loop, Computer Use action
  translation, MCP server, keyboard queue, app registry, frame change
  detection): 23 Swift tests, run on Linux.
- Desktop: phone-owned missions are never claimed by Orb desktop; labels no
  longer assume "This computer".
- `OrbLinuxBridge.c` compiles against the pinned iSH ARM64 headers.

Not yet done, and required before claiming the milestone:

1. Compile the iOS targets in macOS CI (the PR's `iOS Build` job).
2. On a physical iPhone (TestFlight): run the Settings → This iPhone probe and
   record results here; run a "This iPhone" Codex computer-use mission that
   opens Maps, types through the Orb keyboard, and observes the result; kill
   Orb mid-turn and confirm resume.
3. Link iSH ARM64 and measure which CLIs run in the guest and how fast.
