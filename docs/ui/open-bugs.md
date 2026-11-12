# Client bug register — 2026-11-12

Ordered by user impact. This register distinguishes deterministic client replays
from live account validation: a passing fixture is not evidence that a deployed
account or an installed native bundle was checked.

## Audit environment and limits

- Target: `https://agent-backend-dev.thomas.md`. Public `GET /api/health` returned
  `build: 1349b797f`. `GET /api/control/missions` returned **401** without a
  session. No credentials were supplied; authenticated dev investigation is open.
- Desktop SolidJS client launched locally and Settings/About inspected in light
  and dark mode. Browser replays use scripted Core responses, not live missions.
- The original screenshot files were not included in this mission. Items below
  record the reported symptom and executable reproduction, not invented details
  about those screenshots.
- Chromium is available using isolated userspace libraries. The full browser gate
  finished with **377 passed, 1 skipped, 122 failed**. All 122 failure sections
  were `browserType.launch` errors reporting missing WebKit GTK/media libraries;
  none was a client assertion failure. Further userspace dependency setup did
  not yield a working WebKit smoke session (it hung and was stopped). No system/
  root changes were made; a temporary browser-cache wrapper change was reverted.
  macOS visual references, native installation, iOS and Android were not verified.
- Full gate: `pnpm build` and `pnpm check:bundle` passed; `pnpm test` finished
  **2,174 passed, 3 skipped**. Node 22 needed `NODE_OPTIONS=--experimental-strip-types`
  for the bundle script's TypeScript import. Targeted status tests and production
  build/bundle were rerun after the last status-owner cleanup. Generated browser
  screenshots were inspected and removed/restored rather than committed.

## 1. Turn end incorrectly looks like mission completion (C1)

**State: fixed in client; live deployment verification open.**

Reproduce: run a parent such as ldgr; arm a timed wake-up and launch a worker;
end the parent's turn (`completed`); end the worker; receive
`awaiting_user`/`terminal_reason=awaiting_wakeup`; refresh a completed snapshot
that still contains the continuation. It must never become green/done until
pending work is explicitly removed.

Fix/spec: [mission-status.md](mission-status.md). `missionStatus.ts` owns the
activity/effective status/presentation. Pending children read as background work;
pending wake-ups read as scheduled, with their known time. The header and sidebar
consume the same owner. The only Core API addition is `live_children_count` on
list/detail, with a supporting parent index, so a paginated-out worker still
prevents false completion.

Tests: `mission-status-truth.test.tsx`, `launch.test.ts`, and the **ldgr status
replay** cases in `sidebar-hierarchy.browser.spec.ts` (light/dark, Enter/Escape).
The browser replay passes. The Core count's actual SQL/schema, count deduplication,
zero case and indexed lookup were checked with SQLite. The SelfTest check was first
pushed uncompiled and broke the Core build (deploy of `8446948f2` stopped; prod
untouched). Fixed in `6fbec1601`: the CI command `lake build orb-core orb-core-test
orb-spec-runner -- -DwarningAsError=true` completes and `orb-core-test` exits 0.

## 2. Stale startup progress and timer (C2)

**State: fixed in client replay.**

Reproduce: send a follow-up and keep its accepted HTTP receipt at the transcript
tail; advance elapsed time to 7 h 20; finish the remote job by poll, or emit
`mission_status_changed: awaiting_user`, without subsequent assistant output or a
canonical user-message event. Previously the transcript retained **Starting
OpenCode on ashur… 7 h 20** indefinitely.

Fix: a receipt is not permanent run liveness. Use the shared bounded handoff and
settled job/status evidence. Tests in `send-continuity.test.tsx` reproduce the
exact stale text before the fix and verify it clears afterwards, preserving the
prompt DOM. See [conversation-loading.md](conversation-loading.md).

## 3. Rows look active when nothing runs

**State: covered for terminal execution evidence; ambiguous server evidence open.**

Reproduce the client case: return `status: active`/`pending` with a remote job
whose phase is `finished`, terminal lease/reason, or a post-user error and no live
job. Expect no Working row or running glyph. `mission-activity.test.tsx` covers
these event/evidence combinations; C1 additionally covers a finished parent with
live children versus a scheduled wake-up. Bare awaiting_user is quiet, not active.

If Core still reports active with no terminal evidence, the client cannot prove
that no process runs. Do not add an elapsed-time guess. Capture that live mission's
list/detail/stream evidence after authenticated dev access is provided. This
reported live variant is not closed as a client fix.

## 4. Subscriptions show “Unknown” (C3)

**State: client contract mismatch fixed; live account verification open.**

Reproduce: hydrate a provider with Core's `status.type: ready` (credentials are
configured). Desktop previously lacked this case and displayed **Unknown**.
`provider-usage.test.tsx` reproduces the failure (`Unknown` versus `Configured`).

Fix: `Providers.tsx` says **Configured** for `ready`, while retaining reconnect
and exhausted-quota overrides. It deliberately does not claim authenticated or
usable quota from credential presence. Provider test suites pass. The actual dev
subscriptions panel cannot be checked without an authenticated session; the
server/parity portion of C3 remains open.

## 5. Sidebar hierarchy / disappearing or reverting missions (C4)

**State: fixed in Core (`0ff162c2b`, #1704, #1705); client replay added and passing.**

The reported order is now replayed in the browser by **open, rename and move
replay (2026-11-12)** in `sidebar-hierarchy.browser.spec.ts`: open a mission,
rename it, let a detail read that started before the rename answer with the old
title, poll, reopen, then have another client move it into a folder and replay a
stale pre-move answer. A per-frame recorder fails the test if the row is ever
absent or the old title is ever drawn again after the rename.

Reproduce with `sidebar-hierarchy.browser.spec.ts`: children arrive before their
parent; parent fetch fails or is delayed; resume a callback child after its link
is omitted; move or reload a parent; return error/empty/full list responses.
The frame recorder rejects root-level children or vanished watched rows.
`mission-hierarchy.test.ts` covers lineage ownership. Existing Core fixes remain
the roadmap's resolution; do not invent another hierarchy merge path.

The complete Chromium hierarchy/status suite passes (12 tests). Reopen with the exact live
event order if the reported screenshot still reproduces after authenticated dev
access; that comparison is currently blocked, not claimed verified.

## 6. Inbox

**State: local contract audit passed; screenshot-specific live report untriaged.**

Reproduce with `playwright.inbox.config.ts`: switch filters by keyboard; open and
close previews; preserve drafts across different conversations; reply once;
restore row focus; operate narrow-screen sidebar/Space; test suggested archive,
undo and deletion confirmation. The Chromium Inbox contract suite passes, in
light/dark and desktop/390px cases. No Inbox presentation was changed solely from
an unspecified screenshot. See [inbox.md](inbox.md).

Authenticated dev comparison and WebKit/macOS reference checks remain open.

## 7. Overlays

**State: local functional audit passed; visual/live comparison open.**

Reproduce via `tests/overlays.html` and `playwright.overlays.config.ts`: nested
modal closes first and restores focus; drafts survive cancellation; naming is
single-flight; submenu arrows/Escape work; a confirmation owns the only dim
backdrop; stacked modals ref-count inert holds. The 12 Chromium keyboard/focus/
stacking contract cases pass. Text fields retain the shared 1px focus border,
without feature-specific focus halos. No overlay infrastructure was replaced.
See [overlays.md](overlays.md).

WebKit and macOS visual reference comparison were not run successfully on this
Linux host. The screenshot-specific report stays open until its exact reproduction
and authenticated target are available.

## 8. Settings → Models → Fallback Chains renders blank

**State: client guard fixed; server shape owned by the parity mission.**

Reproduce: have `GET /api/model-routing/chains` return a row with `models_json`
and no `entries` (what dev sent on 2026-11-12). The tab threw while rendering
`chain.entries` and drew nothing.

Fix: `normalizeChains` in `routingApi.ts` is the one reader of that response
(network and local cache). A row without a valid `entries` list is kept, marked,
and drawn with an inline error; its summary is disabled so it cannot be opened
or saved over the server's real models. Valid rows next to it render as before,
and a response that is not a list raises the existing load error instead of an
empty tab. The client deliberately does not parse `models_json`: that would be a
second parser for a shape the server is about to stop sending.

Test: `routing-malformed.test.tsx` (fails without the guard). Not checked against
live dev. Mobile: iOS and Android not changed.

## 9. Build identity unavailable in normal Settings (C5)

**State: fixed; native installed-app smoke check open.**

Reproduce: open Settings → Account. About now displays the client build commit
from bundle metadata and the connected server's `/api/health build`, with explicit
loading/disconnected/unknown states and refresh. Tests: `about-build.test.tsx` and
`debug-info.test.tsx`, including connection changes and malformed/unavailable
health responses. Local light/dark screenshots were inspected. The installed
native app and mobile About screens were not updated/checked here.

## Follow-up needed to finish C6

Provide an authenticated dev session through the approved secret/access mechanism
and the original screenshot files (or precise steps for hierarchy, Inbox and
overlays). Then replay against live dev, record the observed build, and close or
fix each remaining live variant. Do not mark C6 done based solely on mocks.
