# Orb iOS validation

Run from the repository root. Xcode 26 and an iOS 26 Simulator are required.

## Deterministic integration tests

```sh
python3 ios_dashboard/TestsSupport/orb_fixture_server.py
# In another terminal, for the sign-in layout test:
python3 ios_dashboard/TestsSupport/orb_fixture_server.py --port 18769 --require-auth
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
