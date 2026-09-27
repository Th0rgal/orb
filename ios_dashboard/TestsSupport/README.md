# Orb iOS validation

Run from the repository root. Xcode 26 and an iOS 26 Simulator are required.

## Deterministic integration tests

```sh
python3 ios_dashboard/TestsSupport/orb_fixture_server.py
# In another terminal, for the sign-in layout test:
python3 ios_dashboard/TestsSupport/orb_fixture_server.py --port 18769 --require-auth
# In another terminal, for expired-session recovery (restart before each run):
python3 ios_dashboard/TestsSupport/orb_fixture_server.py --port 18770 --expire-session
# For saved-login and expired-token renewal:
python3 ios_dashboard/TestsSupport/orb_fixture_server.py --port 18772 --require-auth
# For loading/cache/history and the composer mode menu:
python3 ios_dashboard/TestsSupport/orb_fixture_server.py --port 18771 --list-delay 4
```

In a separate terminal, choose an installed Simulator UUID and run:

```sh
xcodebuild -project ios_dashboard/SandboxedDashboard.xcodeproj \
  -scheme SandboxedDashboard -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' \
  -derivedDataPath /tmp/orb-ios-derived -jobs 2 -parallel-testing-enabled NO \
  -only-testing:SandboxedDashboardTests/OrbContractTests \
  -only-testing:SandboxedDashboardTests/OrbRichTextTests \
  -only-testing:SandboxedDashboardUITests/OrbFlowUITests test
node ios_dashboard/TestsSupport/test_rich_renderer.cjs
```

The loopback fixture has no provider credentials. UI tests use a DEBUG-only
local cache reset; it is refused for non-loopback API endpoints. They create
classic agents and each cloud type, send follow-ups, navigate expanded folders,
exclude local Mac missions, open context, edit Markdown, reopen a rich ChatGPT
conversation and open its image artifact and read its CSV artifact. The provider fixtures are test data,
not evidence that a remote provider is healthy.

`OrbRichTextTests` uses actual WKWebView and bundled fonts/scripts, not a mocked
renderer. It checks inline/display/aligned math, currency, tables and escaped
cells, nested lists, code copying, artifact callbacks, unsafe input, unfinished
streaming content, document reuse, resizing, long responses and accessibility
text size. XCTest UI attachments include screenshots; reviewed examples are kept in
`screenshots/`. These are evidence, not pixel-diff baselines. MathML exists for assistive
technology; this does not replace a manual VoiceOver pass on a device.

`fixtures/chatgpt-rich.md` is synthetic. `cursor-live.md` and `grok-live.md` are
unmodified responses to bounded, dedicated test prompts on 2026-09-27. No user
conversation or account metadata is included.

## Operator-only live tests

`orb_live_proxy.py` is an operator helper for this workspace, not an app service.
It keeps Core auth in memory, requires the existing SSH identity, remote auth
helper and tunnel at 127.0.0.1:18768, and accepts writes only to its dedicated
`orb-ios-validation` project/missions. Never expose it beyond loopback. The
production token is not passed into Simulator launch arguments or fixtures.
Opt-in `OrbLiveUITests` requires `TEST_RUNNER_ORB_LIVE_TESTS=1` and the bridge on
18767. Verify catalogue labels before running; they can change per account.
A timeout or `submission_uncertain` is not permission to recreate a conversation.
Retain the request identity and reconcile on Core.

## Results on 2026-09-27

- Renderer corpus: 20 Node checks. Native coverage: 7 WebKit tests and 4
  model/contract tests; UI coverage: 9 Simulator scenarios.
- iPhone 17e / iOS 26.5: Markdown and KaTeX rendered visually; native artifact
  preview and reopen test passed. Creation/follow-up tests passed for classical,
  ChatGPT, Cursor and Grok using the deterministic service.
- Real Grok Bot: first response and follow-up completed on mission
  `5fff0532-8193-4d07-85f2-2bcb7593086f`.
- Real Cursor: response and follow-up completed on
  `89d44961-7b06-4083-8a35-1593470d9de9`. An earlier request without a Git ref
  failed with `invalid_request`; iOS now requires a ref at creation.
- Real ChatGPT: `e3f3a008-dd20-4405-9fc0-ac4125dafedc` stayed in
  `submission_uncertain`, with no confirmed external conversation. It was not
  recreated. The pool's `available` value is not proof of current authentication.

## Remaining acceptance work

Do not call the entire redesign production-ready from these tests alone.
ChatGPT's live submission/reconciliation still needs resolution. The complete
network-loss/receipt-replay matrix, Core restart, real approval prompts, Markdown
conflict comparison, pixel-diff baselines, physical-device VoiceOver and APNs
provisioning/delivery have not all been validated. Images use a native pinch/drag viewer; small Markdown/text/CSV artifacts use
in-app text rendering, with QuickLook as the fallback for other formats. PDF
and other binary formats still need dedicated preview tests. The preview
supports reading/sharing artifacts, not editing provider files. Cloud uploads
remain unavailable; supported classical attachments are bounded to 20 MiB.

## Compact layout review (2026-09-27)

The conversation composer no longer reserves a row for completed status. Its
opaque surface prevents transcript bleed-through; the idle composer measures
95 pt at the default text size on iPhone 17e. Model, attach and send controls
retain 44 pt targets. Reconnection/submission errors remain in the transcript.
Projects use inline titles, tighter rows, horizontal separators and a toolbar
creation action. Filters live in the project menu. Search reveals matching
conversations even in collapsed folders. Agent/server sheets support medium
and large sizes. Documents focus the editor on entry and offer Save only for
changes, including from Preview. Sign-in uses a shorter heading and form.

The nine deterministic UI scenarios passed, including classic/cloud creation
and follow-ups, reconnection, keyboard layout, settings, context editing,
conversation reopening and image/CSV previews. The 20 renderer checks passed.
Targeted layout checks were repeated after correcting separator orientation.
Screenshots prefixed `compact-` record the reviewed layouts. Secure-input
screenshots omit protected password/keyboard pixels; XCTest checks keyboard
presence and Sign In reachability separately. These checks use fixtures and
do not change the live-provider limitations listed above.

## Session recovery

`testExpiredSessionAndServerPassword` exercises a real HTTP 401 through OrbCore,
checks that project creation/search disappear, submits a wrong then correct
password, and replaces credentials from Server settings. It also verifies that
a failed settings login preserves the working session. The fixture issues a
new token at startup; restart port 18770 before repeating this scenario.
Connect stays in the server sheet's toolbar so the keyboard cannot cover it.

## Navigation and composer

Project lists and conversations use an account-scoped disk/memory cache with a
30-second freshness window. Concurrent loads share one request. The first project
and two conversations are prefetched; mutations invalidate the affected project.
Cold loads show progress rather than an empty-state message.

Conversation rendering begins with the latest 20 messages, anchored at the bottom.
“Load earlier messages” reveals another 20 and preserves the previous boundary.
This is **rendering pagination**, not network history pagination: the existing
Core mission/cloud endpoints still return the full history. Reducing that initial
payload requires a compatible history API on Core.

The + menu offers Photos, Files and (for Codex) Mode. Mode inserts `@`, opening
Message/Plan/Goal suggestions. A selected non-default mode becomes a removable
chip. Arbitrary @mentions remain ordinary text. Cloud attachment/mode controls
are not exposed when the provider does not support them.

Validation: 5 model/cache tests and 7 native WebKit tests passed. Simulator
checks passed for delayed loading, cached return navigation, latest-first history,
loading earlier messages without losing the reading position, the @ mode picker
and /plan submission, compact keyboard/settings layout, and ChatGPT reopening
with image/CSV previews. Screenshots `composer-mode-picker.png` and
`conversation-latest-messages.png` show the final navigation/composer behavior.

## Loading and bottom anchoring follow-up

Cold conversation lists use five noninteractive skeleton rows with the real row
spacing and a single VoiceOver loading label. Server settings use 14-point field
corners without the redundant password helper.

Bottom following now distinguishes user scrolling from content/viewport resizing.
WebKit height updates keep following the end until the user scrolls away. The
rich renderer contains collapsed block margins in its measured content box and
disables nested automatic scroll insets, preventing the final paragraph from
being clipped even when the artifact row is visible.

`testRichResponseStaysAtBottomAfterLayoutGrowth` starts with a short running reply,
then replaces it with 40 Markdown/math sections and a final marker. It verifies
that the final marker and file button are both visible above the composer without
a scroll gesture. This test and all seven native renderer tests passed; the
existing loading/cache/earlier-history test also passed with the new scroll logic.

## Saved login and cloud-only ChatGPT

Tokens and login credentials use separate endpoint-scoped Keychain services.
Login reports storage failures; explicit logout clears both. An expired token
triggers one saved-credential login attempt, including for streaming 401s.
A failed renewal leaves the reconnect screen available. Credentials are never
written to the response cache or UserDefaults. Older versions stored no password,
so one successful sign-in is needed to enable renewal.

The saved-login UI scenario terminates/relaunches the app, rotates the fixture's
token, then checks that renewal returns to projects without requesting a password.
The regular-agent fixture deliberately advertises chatgpt_ui: the harness picker
must exclude it while the separate ChatGPT cloud creation scenario remains valid.
Existing mission records are unchanged.

Verified on iPhone 17e / iOS 26.5: regular-agent and ChatGPT-cloud creation
passed; expired-token recovery performed exactly one new login. Installing the
built app over the existing Simulator app (without uninstalling or clearing its
container/Keychain) reopened Projects without entering a password.

The Settings recovery scenario also passed (wrong password, successful reconnect,
failed replacement preserving the session, then successful replacement). The test
dismisses iOS's delayed Save Password sheet before reopening Settings.
