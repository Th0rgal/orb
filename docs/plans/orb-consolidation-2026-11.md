# Orb consolidation roadmap (2026-11-13)

Status: approved by Thomas on 2026-11-13 ("full autonomy, approved to deploy and
test in production, prioritise speed, do not wait for CI initially, fix any new
bug you find"). Owner: the single mission **"Orb: consolidation"** (project
`refining-loops`). It replaces the four earlier Orb missions (`68e2a387` parity,
`44e3fec6` Boat recovery, `2bf5e847` lean.ci/Colab providers, `9382ef4d`
dev/prod), whose handoffs are at the top of their plan documents in this folder.

## How the work is run

- One orchestrator (opencode, `builtin/genius`; mission
  `b8062114-2687-43fe-9c75-e6ca123694f6`). It keeps the task board, reviews
  and merges; it does not write feature code itself.
- Workers are child missions (`builtin/smart` on opencode by default), each on
  **its own managed VM** (`auto-managed:<provider>:<size>`, Boat or lean.ci) so
  Lean builds never share a build slot. At most 6 writers at once, one per
  track, one branch per bounded change. Destroy VMs when a worker ends.
- Merge policy today: a worker merges its own PR once its local CI-parity build
  and self-test pass; GitHub CI is checked afterwards and any red master is the
  first thing fixed. Once track B makes CI fast (< 10 min), return to
  green-before-merge (AGENTS.md).
- Deploys: `orb-deploy --detach <sha> --dev-only` first, verify on dev, then
  prod. Never a bare restart or binary copy. One deploy at a time.
- Every decision that Thomas would otherwise have been asked about goes into
  the decision log below, with the reason.

## Tracks

### A. turbo-lean builds all of Orb (blocks B)
`turbo-lean` rejects `OrbBin.PosixExt` and `OrbCore.Store` in its in-kernel
`.olean` soundness audit (PR #1708 CI), and missions report a "known
OrbCore.Spec materialization gate", so everyone falls back to raw
`SANDBOXED_ALLOW_RAW_LAKE=1 lake build`. Reproduce, find the cause (Orb source
or `Th0rgal/turbo-lean`), fix it at the cause, bump `lean/turbo-lean-revision`.
Done when `scripts/build_orb_bins.sh` builds every binary through turbo-lean
with no raw-Lake fallback, locally and in CI.

### B. CI: fast, cached, on lean.ci
1. Land #1708 (cached pinned turbo-lean binary, batched audit-spec, no raw Lake).
2. Move Linux jobs to lean.ci runners (GitHub App `lean-ci`; labels validated on
   2026-11-11: `lean-16vcpu-ubuntu-2604`, `lean-32vcpu-ubuntu-2604`). macOS/iOS
   jobs stay on GitHub `macos-26`. Keep a `workflow_dispatch` input / repo
   variable to fall back to `ubuntu-latest` when lean.ci is at capacity.
   Known lean.ci gaps to fix or work around (lean.ci is ours: fix upstream in
   `lfglabs-dev/lean.ci`, keeping it generic, no Orb-specific coupling): the
   Actions cache is not wired inside microVMs; warm-base pinning across engines
   was broken for Actions jobs on 6 Nov; `Th0rgal/orb` is a user repo, while
   the App syncs an org runner group, so repo-level JIT runners may be needed.
3. Finish the planner in `docs/ci/refactor-proposal.md`: path-gated jobs
   (docs-only and `orb/`-only PRs skip Lean; kernel-abi merged into `ci.yml`),
   master pushes seed the warm base / turbo-lean CAS, no test reruns when
   inputs are unchanged.
Targets, measured and written here: web-only PR < 5 min, warm Lean PR < 10 min,
cold full run < 20 min.

### C. lean.ci and Colab at Boat parity in the product
After #1720: on desktop, iOS and Android a user can see active VMs per
provider, start one from the UI (size, TTL), stop/extend/destroy it, and see
cost, for `boat`, `leanci` and `colab` alike. Test with real rentals on dev,
then prod. iOS and Android ship together (version bump per AGENTS.md).

### D. Rust → Lean parity: implement, stop auditing
Work the ranked queue in `rust-lean-parity-audit.md` (handoff section), one
bounded branch per finding group, failing test first, verified on dev. Start
with RUN-07 (incremental proxy streaming + deadlines) and the "Not done" items
of the implementation ledger. No new audit documents.

### E. Dev/prod environments live
Apply items 1–6 of `dev-prod-environments.md` on agent-core (base + overlays,
settings round trip, sealing, `dev_operator` grant, auto-deploy timer, dev
spend cap), verify each, then run the multi-user isolation test on dev and fix
every leak with a test. Keep `docs/operations/*` exact.

### F. Hindsight
When a track closes, update the Hindsight pages (lean.ci page
`kp-7660c626095640c08f6742f9e60c2946`, the "Now" chapter, Orb pages) with the
outcome. Request memory-write access through the governed broker.

### G. Multi-user must work (Thomas, 13 Nov 12:10 UTC: "very important")
Create a non-admin user `ben` (dev first, then prod), and test in depth as him
on a real Orb desktop client running in a Linux VM (managed VM with a desktop
session, `linux_shell` build pointed at the instance): sign in, create and run
missions, projects, files, providers/usage, managed machines, settings, Inbox,
search. He must never see or act on admin's missions, projects, secrets,
machines or settings (REST, MCP and client). Every bug found gets a failing
test, a fix, a deploy, and a re-test. This extends track E's isolation test.

### H. Proxy / provider bugs found on 13 Nov (fix with tests)
- `POST /api/model-routing/health/:account/clear` clears only
  `proxyCooldownsRef`, not the health tracker's cooldowns, and
  `GET /api/model-routing/health` reports `cooldown_secs_remaining: 0` while
  the proxy answers 429 "in cooldown" for that account (`cliproxyapi:anthropic`).
- A chain with a single cooling target leaves an opencode turn "running" with
  no output and no error for 15+ minutes ("Starting OpenCode on ashur…"); the
  mission shows `healthy`. The 429 must surface as a mission error quickly.
- The Anthropic provider card shows `connected`, 7-day use 0.07, while
  CLIProxyAPI has the only working Claude credential parked
  (`reason=credential_quota`, ~123 h) since 03:45 UTC; every request has
  returned 503 since. Status must come from that evidence.
- The native-chrome palette RPC `native_chrome_palette_query` in orb-locald is
  unused since #1721: remove it with its self-test cases.
- `orb-env migrate` reports ~80 "shared setting differences" between prod and
  dev env files; it needs a way to classify one-sided keys instead of failing.

## Task board — 13 Nov 12:14 UTC

Launch receipts report all six workers active on distinct Boat large VMs, with
requested and effective backend/model `opencode` / `builtin/smart`. These are
launch attestations, not completed build, merge or live acceptance evidence.
All tracks remain open. The orchestrator owns this document; workers report
bounded artifacts and do not rewrite this board.

| Track | Mission UUID | Managed machine UUID | Owned files/sections and dependency | State / evidence |
| --- | --- | --- | --- | --- |
| A | `35cd3390-5a58-4cd7-8444-172a84d5faa8` | `0f88c8f6-084e-46a3-89ad-29aa52d300de` | Build script, turbo-lean pin/upstream soundness fix | Partial GREEN candidate: fido-agent-proxy66.59s/1.53GiB, audit suite19/19 worker-reported. Core RED ~186 private pure C-ABI externs ConformanceRunner; bounded runtime-only boundary review approved, no blanket pure admission; fullA open |
| B | `36bddaa5-fcc4-4fbf-a78a-b717e1e198a7` | `f9444f29-2b15-49f4-ad81-37346c0844e5` | `.github/**`, `scripts/ci*`, `ci/**`, CI proposal; B.1 waits A | API scaffold v3 harvested/hash-verified, supersedes v2; Ubuntu hosted only, no HTTP/auth adapter/CI wiring. Worker reports32 tests; NOT merge-ready/live-verified. VM destroy failed provider_http_error; cleanup open. B.1 waits A |
| C | `816f574f-6e85-4d3a-8123-8429f10e86b3` | `21fa6dec-b7d5-4b8a-9ab3-12f7a3218af4` | Managed REST/lifecycle sections and managed UI/models on desktop/iOS/Android | Initial lifecycle regression RED worker-reported; REST extend/client capability draft in progress. Installed turbo --no-telemetry mismatch/raw fallback, core-test280/299 at10min timeout NOT pass; live/Mac gates pending |
| D | `95ad3d8d-5af8-4228-943d-509baa9394d8` | `6b6d2464-4997-42e1-b6d4-00b5fbb61264` | Proxy/Control downstream streaming sections, OrbNetLeaf TLS, streaming tests | Active RUN-07; public HTTPS clone succeeded, SSH host verification/gh auth block publication; bundle fallback; VM expires 15:12:52Z; no streaming acceptance claimed |
| E+G | `6fa970f7-8799-4c80-a312-f7884efc21f4` | `a474d57a-39d7-4b0f-a447-5f7f888de185` | Environment/settings ops, principal/security/MCP admission; sole live deployment owner; real Linux desktop ben test | Active; live agent-core inspection/authority required before changes |
| F | Orchestrator | None | Governed Hindsight writes after track acceptance | Pending; no track closed |
| H | `11a48ddf-fb0b-49b4-8c42-2bd95518b296` | `7ca70124-a137-4aab-ba1d-9a584333ffa1` | Proxy account-health/provider-auth sections, fast launch errors, obsolete locald palette RPC | Active branch `fix/h-provider-health` base `de3fd0fa1`; reports legacy-ref-only health route and missing synthetic account/tracker handling (source-derived, not independently accepted); TTL 15:12:52Z; live evidence requested from E |

Shared Core files have section-level ownership, not permission for broad rewrites.
Each worker must report branch/PR/last pushed SHA; none exists at launch.
Read-only independent scope review: `24b8c6f7-7e24-4769-ac1d-f2163171fe81`,
requested/effective `opencode` / `builtin/smart`, no managed build slot.
Quorum is degraded to the reachable builtin chain; no cross-family vote claimed.

### Initial reconciliation / blockers

- Master read at `de3fd0fa`: parity handoff in #1723 merge `a34d76da`, recovery
  handoff `566dd2d6`, provider handoff `de3fd0fa` are present. The environment
  plan has no handoff heading, so its implementation ledger was read instead.
- Old parity mission full ID was source-resolved as
  `68e2a387-6c45-400d-a88a-7f0c6c2e37b3`. Read was forbidden, but its cancellation
  was accepted (action `858f0f12-5692-419e-9def-6248012376fb`). Terminal health
  and wake-up cancellation still require verification. Other three full IDs and
  environment handoff publication remain to resolve; do not invent UUIDs.
- Coordinator has no provisioned Git author/signing profile or `gh` login.
  Public clone succeeds; master CI inspection failed at `gh` authentication.
  `git diff --check` passed for this document; the requested small commit failed
  with `Author identity unknown` (exit 128), so no commit or push is claimed.
  Publication and independent CI checks are blocked until provisioned transport
  is available. No key/token workaround or invented CI result is permitted.
- Installed ops skill references are absent. Repository runbooks were read as
  fallback; runtime JIT/dev grant availability is not yet established. User
  deployment authority does not itself supply an operational credential.
- No unrelated project mission or machine was changed. No deployment performed
  by this coordinator. Reconcile live state before any deployment repetition.

C coordination: E+G UUID supplied to C; request forwarded to E+G for sanctioned
live access, exact-SHA rental/UI checks, resource cleanup and Mac validation.
No Mac slot or live bearer has been established; Linux/source checks cannot
substitute for native iOS execution.

B independently confirms no GitHub identity/signing configuration; public reads
work but private `lfglabs-dev/lean.ci` clone requires authentication. Generic
upstream repairs and authenticated runner/cache/warm-base acceptance remain
blocked. Prepare opt-in routing with Ubuntu default/fork fallback and public
baseline evidence without claiming an upstream fix or runner validation.

### D baseline and shared proxy interface update

D reports installed turbo-lean rejects script flag `--no-telemetry`, after which
`scripts/build_orb_bins.sh` silently starts raw Lake. The baseline reached about
263 jobs / 200 seconds before tool deadline: **not a turbo-lean pass, not a
completed build**. D set no explicit audit bypass/fallback environment. This
worker observation is forwarded to A for reproduction and script/pin repair;
coordinator has not independently reproduced it. No script ownership transferred.
D plans an optional per-connection downstream sink on `forwardProxyChain`, with
H account/classification sections preserved; H notified to avoid broad rewrites.

### B checkpoint — harvested, not accepted for merge

- Trusted nimrud artifact:
  `/var/lib/sandboxed-node/uploads/a4835823-bd85-4d79-90cc-35cb113ecc0b/orb-b2-checkpoint.tar.gz`,
  26,425 bytes; governed harvest SHA-256
  `97ef187265ff34da8cb0d9e43538afe87359bf2e26fedd0e57336daf7009989a`
  matches worker report. Base `de3fd0fa1bf025cf29258bc3b3bda953a12877fe`;
  worker branch `ci/leanci-opt-in`, no commit/PR/merge.
- Archive listing independently checked: `.github/workflows/{ci,kernel-abi}.yml`,
  `docs/ci/refactor-proposal.md`, `scripts/ci_measure.py`, `ci/test_runners.py`,
  `ci/baseline-2026-11-13.json`. No extraction/integration yet.
- Prepared direct-runner opt-in for five jobs is superseded by the operator's
  API-bridge decision. Do not land inaccessible direct runner labels as B.2 done.
  Baseline/measurement code may be reused only after diff/test review.
- Worker reports 5 regression tests/48 routing cases, 23 planner tests,
  actionlint (existing config-inline warning filtered), Python compile,
  kernel-call lint/state inventory/whitespace pass. Native full parity, live App,
  cache/base and after measurements absent: **not merge-ready**.
- Worker baseline: newest 20 PRs #1704–1723, 16 complete, median wall 23.53 min,
  median summed job time 74.85 min; name-inferred macOS total 41.85 min including
  partials. Queue/billed time excluded. These figures are not independently
  recomputed yet; no before/after speedup claim.
- Worker reports #1708 head `8fcf5038` has multiple failures and remains open;
  master snapshot kernel-abi running/plan success is not a green master verdict.
- Artifact safe on nimrud; destroy VM request failed
  `lifecycle_rejected/provider_http_error`. Resource cleanup is **open**, not
  silently treated as destroyed. Reconcile provider state before further action.

### B public master-CI snapshot (worker observation)

- New master `36b4205ab94bd8a97cb9a1b9058672640b2ee11b`: CI
  `43424565802` and Kernel ABI `43424565364` pending, zero check-runs at read;
  **not green**. Prior `afae6c68` CI `43424227886` running, kernel cancelled.
- Historical master `a34d76da` CI `43422052000` failed Test
  (12:06:42–12:19:04), browser 1/2 (through 12:19:53), browser 2/2
  (through 12:16:28), and CI OK. Failure causes not yet traced; do not attribute
  browser failures to A without logs/reproduction. Master red investigation has
  priority over accepting more feature deliveries.
- Worker confirms the 20-PR raw baseline is present in the harvested archive;
  baseline is obtained, not pending. Independent recomputation still pending.
  Authenticated logs/writes remain blocked until broker delivery; public reads
  used no credential/config workaround. A notified; B.1 remains untouched.

### A reproduced audit rejection — worker evidence

A reports upstream turbo-lean `15676ea` rejects all 24 safe `@[extern]`
opaque IO syscall declarations in `OrbBin.PosixExt`: 40.69 seconds, peak
1.53 GiB. Orb pin `29d85f7` additionally rejects current Lake configuration
before audit. Proposed generic terminal-IO-codomain admission is under
investigation, **not accepted or implemented evidence**. Preserve fail-closed
pure extern, `implemented_by`, unsafe, forged IO names, axiom and replay checks;
canonical type identity and proof dependencies need independent review.
A reports workspace-job API returned completed without execution/logs; actual
RED was timed bash. No build success inferred from the fabricated job receipt.

### B API-bridge retask checkpoint

B reports direct `lean-*` runner expressions removed from prepared workflows;
heavy jobs remain `ubuntu-latest`, fallback/timeouts retained, B.1 untouched.
Superseded label-routing v2 archive must **not** be published. New bridge work
is only a transport-neutral skeleton/tests, not wired, executed live or accepted.
It denies fork/unknown events, preserves exit status, rejects missing receipts or
status/truncated logs, cleans up in `finally`, and uses a deadline before hard TTL.
Require source-confirmed OIDC audience/exchange/claims and idempotent-create /
ambiguous-result reconciliation; do not invent prebuild or authentication schema.

Trusted-source bundle dependency: upstream default branch, exact SHA, AGENTS,
manifests and tests; VM/prebuild handlers, OIDC auth policy, engine/base affinity
and CAS, exec/file/log guest transport, Actions repo-JIT integration. Specifically
`crates/leanci-ctrl/src/vms.rs` and related handlers. Need authoritative TTL,
readiness, cursor/truncation/exit and immutable-base publication contracts before
adapter wiring. Private clone is pending trusted nimrud secret delivery; no guest
credential transfer. Generic JIT remains separate from the immediate bridge.

### B API scaffold v3 — current harvested checkpoint

Governed harvest delivered 34,122 bytes to trusted nimrud:
`/var/lib/sandboxed-node/uploads/11225fa2-94b5-408f-adb7-886d6a6dc41a/orb-b2-api-checkpoint-v3.tar.gz`.
SHA-256 matches worker report:
`4790335fddeda63bd10df1ef3bbf02400ab75bb820f7fc2f539957ff6978be50`.
Base remains `de3fd0fa1bf025cf29258bc3b3bda953a12877fe`; v3 supersedes v2.
Archive listing checked independently: `b2-tracked.patch`, two Orb workflows,
CI proposal, `ci_bridge.py`, `ci_measure.py`, routing tests and raw baseline.
No extraction/integration performed yet. Worker reports 32 passing tests
(9 hosted-route/bridge/measurement + 23 planner), actionlint, Python compilation
and whitespace checks. No direct labels; all hosted Ubuntu. No HTTP/auth adapter
or CI bridge wiring: source-dependent implementation and live acceptance remain
open. This checkpoint is artifact preservation, not B.2 completion.

### A partial GREEN and next boundary

Worker reports generic safe terminal-IO candidate builds `fido-agent-proxy` in
66.59 s, peak 1.53 GiB; kernel audit Python suite 19/19 passes in 47.896 s,
retaining pure extern, malformed pin, forged replay and unsafe negatives.
These are partial worker results, not independent soundness certification or a
full Orb build. Combined Core test build is RED on about 186 private pure C-ABI
extern opaques in ConformanceRunner, correctly rejected by strict policy.

A is authorized to inspect sink-assurance and propose a section-local explicit
unsafe runtime-only boundary for ConformanceRunner bindings/callers (or smaller
idiomatic IO wrappers), with exact file/caller-cone report before editing.
No safe theorem/spec may depend on the foreign result, no blanket pure-extern
audit admission, and conformance execution must not be relabeled kernel proof.
Other production paths/track ownership remain excluded. Independent upstream
patch review and complete binary/self-test gates still required.

### C regression/build checkpoint

C reports initial lifecycle regression RED as expected; REST extend and client
capability controls remain draft. Independently of D, C found installed
`/opt/orb/bin/turbo-lean` rejects `--no-telemetry`, then unedited script falls
back to raw Lake. Cold Core-test build reached 280/299 before a 10-minute tool
timeout: **not a complete build, not turbo-lean acceptance**. A notified of this
second worker observation; no build-script ownership transfer or deployment.

## Waiting on Thomas

These GitHub web approvals block only direct repo-level JIT runners, not the
immediate API-dispatch bridge:

1. Approve lean-ci App repository permission `administration: write`.
2. Install/authorize the lean-ci App on `Th0rgal`, including `Th0rgal/orb`.

No questions sent; implement/test generic support against an authorized
`lfglabs-dev` test repository while the bridge proceeds.

### Operator verified B/G update

- Both dev and prod reported healthy on `de3fd0fa1` since 12:19 UTC. This
  supersedes the prior in-progress prod status; independent live probes pending.
- Operator's App-JWT read: lean-ci App `5538046` is installed only on
  `lfglabs-dev` selected repos; Orb installation lookup is 404. App grants
  actions/checks/contents/pull_requests/workflows and organization runners write,
  but no repository administration. Direct `runs-on: lean-*` on Orb is not usable.
- B.2 now prioritizes a thin hosted API-dispatch bridge to `/v1/vms` or
  `/v1/prebuilds`, truthful streamed logs/result, server-side warm base/CAS,
  authorized GitHub OIDC preferred, repo-secret fallback otherwise. Retain
  `ubuntu-latest` fallback and hosted macOS/iOS. Generic user-repo JIT support
  is a separate bounded upstream delivery gated by the two approvals above.
- Operator dev REST first pass: member `ben`, id
  `1fc5e9f6-72a6-4dc1-a308-ee79de5bf776`, Unix `orb-ben`, cap 200 cents;
  `/api/auth/me` 200 `multi_user`, empty own inventory; admin mission
  GET/events/cancel 404; admin-users/secrets/settings/system-deploy 403;
  projects/workspaces/nodes empty. Password retained privately on agent-core;
  never copied to a managed VM or printed.
- **Live finding (found on `de3fd0fa1`):** member provider list exposes owner
  account-display emails and account IDs. Names and emails fixed by #1742
  (`e6e4541f`, live on dev and prod); the E+G worker that wrote it
  (`6fa970f7`) ended at 14:04. **Owner of the member provider rows since
  22:23: H-core `21b1bfca`** (closed key list, custom-model limits, id
  minting), see the 22:15 section below. If `6fa970f7` is resumed it does not
  edit `Store.lean` or `ProviderUsageAndLogin.lean`. Full G remains open:
  MCP, create/run with managed placement/spend/proxy tokens, sharing, search,
  Inbox, files and real Linux desktop member login still unverified.

## Operator requests

### Coordinator status 22:15 UTC: master moved to #1747, four pull requests open, one red with a real gap

**Master.** Tip is `33b24769` (#1747, operator). Its `CI` and `Kernel ABI`
runs were still in progress at 22:08; `989b801a` (#1746) `CI` also still in
progress, `c0557790` (#1744) `CI` green. No tip after `e43a808d` has been
seen fully green yet, so **no deploy request in this section**.

**Merged since 18:45.** #1737 (login completion), #1738, #1739, #1740
(first-event watchdog), #1741 (docs-only push filters), #1742 (member
provider projection), #1744 (`DELETE /api/control/queue/:id`), #1746
(copy-selection flake), #1747. #1738, #1739, #1740 and #1747 were merged by
the operator and not reviewed by the coordinator. None of these is live:
prod and dev were on `313ec310d` at 19:21, not rechecked since.

**Open pull requests.**

| PR | What | State at 22:08 | Next |
| --- | --- | --- | --- |
| #1743 | desktop: a mission that ended keeps no phantom queue; `awaiting_user` is not ended | **merged 22:10 as `74f89ae0`**, every check green on `1c1a3c3a` | rides the next deploy |
| #1748 | Core: a cut-off streamed reply is not a clean end; pacing slot held for the whole stream | `Test`, `kernel-abi` pending | squash-merge on green |
| #1749 | tests: member-minted MCP sessions are refused every `secret_*` tool | just opened | squash-merge on green |
| #1745 | Core: reduced member views on sibling routes; sidecar parked logins on the health route | **`Test` red** | do not merge, see below |

**#1745 is red for a real reason.** `[orb-core-test] FAIL: tenant isolation:
member resources overview hides other users' missions, fleet sources and
inference pools` (check added by operator commit `2fc87261`). Read in the
code, not run: the member branch of `GET /api/resources/overview` keeps
missions *shared* with the member, never reduces `links` (pool ids and other
users' mission ids), and leaves fleet-wide vCPU totals. Correction ordered
from the H-core worker on `wip/g-overview-member-links` (owner-only missions,
`links: []`, compute totals zeroed, admin reply unchanged, failing tests
first), together with a fix of the `orb-sidecar-guard` paragraph in
`docs/model-routing-health-cooldowns.md`, which describes a restart the
script never does. Review comment:
https://github.com/Th0rgal/orb/pull/1745#issuecomment-6866119448. The sidecar
part of the PR is accepted. **Operator: please do not merge #1745 before
that correction lands on it.**

**Workers.**

- D2 (uruk): #1748 and #1749 delivered. Now on a bounded follow-up
  (`wip/d-stream-untilclose-eof`): with close-delimited framing a timeout or
  read error is still reported as a complete body.
- C (lagash): silent turn on a cooling chain. First patch not published: it
  trusted the `x-sandboxed-execution-key` header to pick the mission to
  stop, so one mission's credential could stop another's turn. Corrections
  in progress, no patch received yet.
- H-core (nippur): the #1745 correction above.
- Red-master worker (VM `a474d57a`, expires 23:42): fixture kernel race.
  42-file patch plus a ready-promise patch for `approval-queue` and
  `smooth-send` exist; worker reports 24 passed with and without a 3 s
  kernel delay for those two. The full two-shard run under the delay is not
  established (one log partial, one run died on a busy port). Nothing
  published; master browser shards are green without it.
- H (VM `7ca70124`, stopped): #1743 delivered.

**Docs-only push filter (#1741) confirmed.** The push of this section
(`e98ee7cd`, one file under `docs/`) started no `CI` and no `Kernel ABI`
run (Actions API: 0 runs for that SHA, checked 22:10 and 22:11).

**Relay received 22:11: "H request recorded … branch `fix/h-provider-health`
base `de3fd0fa1`".** Read as a delayed message from the isolation worker,
written against the 13:08 state. Checked: no branch `fix/h-provider-health`
exists on origin; H's mission `11a48ddf` is completed. What it asks for
now lives elsewhere:

- H's provider work: #1737 (merged, `51beb2e8`) and #1743 (merged,
  `74f89ae0`).
- Parked sidecar logins on the health route and the admin clear: commits
  `e080233e` + `33eabd77` inside #1745, **not merged** (PR red, see above).
  Read contract: `GET /api/model-routing/health` rows gain `parked_until`,
  `parked_reason`, `parked_source` (`sidecar` / `core` / null) next to
  `cooldown_secs_remaining`; `POST /api/model-routing/health/:id/clear` is
  admin only. Source: `ProviderUsageAndLogin.lean`, doc
  `docs/model-routing-health-cooldowns.md`. No final tested SHA can be
  given until #1745 is corrected and merged.
- Prompt error when a chain has one target and it is cooling: C's patch,
  not published (security correction pending).

Nothing live was done on this relay. The rules it states are adopted for
the live validation once a `dev_operator` grant exists: dev only, never
restart the sidecar, never clear a real quota park, clear only cooldowns
the test created, no account identifier in any evidence.

**Relay received 22:12: "Operator delegation acknowledged …" (isolation
worker `6fa970f7`, completed 14:04).** Read as a delayed message; its
"current fetched master `6f17599d`" is 29 commits behind today's tip.
Checked on origin: `b1320c6f` (per-key `orb-env` ownership), `d2e580e9`
(dev/prod handoff in `docs/plans/dev-prod-environments.md`) and
`scripts/dev_user_isolation.py` (`--url`, `--token-file`, `--sha`; creates a
member with `daily_spend_cap_cents: 0`, disables it on cleanup) are all on
master. Decisions:

- The worker's leftover patch is harvested to the coordinator's keep
  directory (SHA-256 `fd8fa880…add77`, 4 files). Its `orb-env`, doc and
  `test_orb_env.py` hunks are the superseded `--share-one-sided` idea:
  **not applied**. Its 8-line `SelfTest.lean` secret-tool check was never
  run and expects error code `admin_required`, while the gate on master
  answers `forbidden` (`McpGateway.lean:442`); the same intent is now
  covered by #1749. **Not integrated.**
- Nothing live was done: no config change, no user created, no grant.
- Isolation is still **not** accepted. The live run needs a dev admin
  bearer the coordinator does not hold (grant `f0eadef4` pending).

**Operator, when convenient (dev only, no env edit, no restart):** run
`scripts/dev_user_isolation.py --url http://127.0.0.1:3002 --sha <full SHA
dev reports> --token-file <private dev admin bearer file>` on agent-core
and paste the JSON result here with usernames and ids removed. Best done
after the next deploy so it exercises #1742 and #1749's gate on the live
build.

**Live builds changed (health endpoints, 22:19).** Prod reports build
`e43a808d4` (`auth_mode: single_tenant`), dev reports `0fc4d71af`
(`auth_mode: multi_user`). Both contain #1735 to #1742; neither contains
#1744, #1746 or #1743. Dev's `0fc4d71a` is the fourth commit of the #1745
branch (sidecar parked logins + reduced sibling routes), without the later
operator commits and without the overview correction. This replaces the
"`313ec310d`" line above.

**Relay received 22:13: "member `GET /api/ai/providers` leaks owner
account-email display names + IDs" (found on `de3fd0fa1`).** Not routed to
H (`11a48ddf` is completed and client-only); the provider module belongs to
the H-core worker `21b1bfca`. State of the finding, read in the code on
master, not run live:

- **Display names and emails: fixed by #1742** (`e6e4541f`, in both live
  builds). Member rows come from `renderMemberHydratedProviderJv`
  (`ProviderUsageAndLogin.lean:510`) and `renderAIProviderForCallerJson`
  (`Store.lean:4154`): `name` is the provider type name, numbered when
  there are several ("Anthropic 1"); no `account_email`, `base_url`,
  limits or status account. Tests at `TenantIsolationTests.lean` 407-449.
  Note: the CI run on the #1742 merge commit itself was cancelled by the
  next push; the tests ran green on later tips.
- **Row `id`: still returned, on purpose.** It is the key of the member
  toggle (`PUT /api/ai/providers/:id/preference`, `Control.lean:4443`) and
  of `user_provider_prefs`. Ids are `prov-<epoch>-<seq>` when Core mints
  them (`Control.lean:4496`), but an admin can supply one and old ones are
  copied from `ai_providers.json` (`LegacyHydrate.lean:446`). **Whether any
  live id contains an account name is not established**; it depends on
  stored data the coordinator cannot read.
- **Gap:** no test holds the member row to a closed list of keys, and the
  member response of the toggle route has no isolation test.

Ordered from H-core (after its current task, branch
`wip/g-member-provider-row-allowlist`): closed-key tests for the member
list, detail and toggle response, an admin positive control, a fix only
if one fails, and a code answer on every path that mints a provider id.
If an id can derive from an account identifier it must stop and report:
replacing the id with an alias changes the toggle key and is not decided.

**Operator, dev only, read-only, possible now on `0fc4d71af`:** as a
member, `GET /api/ai/providers`; report only the set of key names per row
(and inside `status` and `custom_models`), and for each row `id` a yes/no
on "contains an email, account name or login file name". No values.

**Addendum 22:28 to the member provider-row follow-up.** Read on master,
not run: the store renderer `renderAIProviderForCallerJson`
(`Store.lean:4154`) passes custom models through `renderCustomModelsJson`
for members too, which adds `rpm_limit`, `tpm_limit` and `max_concurrency`
per model. The member toggle response (`Control.lean:4459`) always uses
that renderer; the test fixture's custom model carries no limits, so no
test would see it. Rate-limit internals, not account identity. Added to
H-core's task: a toggle-response test expected to fail on master, then a
fix confined to the member path of that renderer; plus marker coverage of
the login-list and auth-methods routes and a 403 check for a member
starting a login.

**Relays received 22:25 and 22:27 (isolation worker `6fa970f7`, completed
14:04; its "newer master `0da01d9e`" is 29 commits behind).** Both read as
delayed. Their line numbers for the provider renderers describe
`de3fd0fa` and no longer match master (#1742 rewrote those paths). What
was done and decided:

- Second leftover patch harvested and kept (SHA-256 `c766c07f…e115a1`, one
  hunk in `SelfTest.lean`); its added lines are identical to the
  `SelfTest` hunk of the first patch. Still **not integrated**: never run,
  and it expects code `admin_required` where the only gate read on master
  (`McpGateway.lean:442`) answers `forbidden`. Whether an earlier branch
  answers first for an operator-role principal was not traced.
- Native Linux shell: worker-reported only, `make -C linux_shell test`
  built and self-tested against GTK 3.24.41 / WebKitGTK 2.52.3. No
  authorized display (it refused, correctly, to reuse another user's X
  cookie), no test member. **No desktop isolation pass.**
- No grant exists for this mission or for `6fa970f7`
  (`list_mission_access`: none), and the coordinator has no tool to request
  one. Nothing live was done.

**Waiting on Thomas / operator for isolation acceptance, unchanged:** a
`dev_operator` grant (dev, 30 min is enough) for the mission that will run
the checks, or the operator running `scripts/dev_user_isolation.py` and
the member provider-row read on dev itself and pasting key names and
booleans only. And the names-only output of `orb-env inventory --prod …
--dev …` (key names and `unknown_keys`, no values) so the remaining
environment differences can be judged.

**Update 23:05 UTC.**

- Merged: #1748 (`0bcf82d0`, streamed-relay fixes for the five #1729
  defects) and #1749 (`b6afa205`, tests pinning that a member's session
  cannot call the `secret_*` tools). Master CI on `0bcf82d0` passed; on
  `b6afa205` it is running. Not deployed.
- #1745 (member sibling routes, sidecar parked logins): head is now
  `55813fd1`. The red `Test` was a real leak in the member resources
  overview (a shared mission of the admin, its provider links, fleet-wide
  vCPU totals). The worker's 9-line correction and its tests are
  cherry-picked on the branch; `Test` passed on that head, `kernel-abi`
  still running. Decision taken there: a mission shared with a member no
  longer shows its cost card in that member's overview.
- #1751 opened (`ready/c-cooling-chain-ends-turn`, `c3d79bd1`): Core ends a
  mission turn with a visible reason when its model chain has no usable
  target for more than 60 s. Operator item C (a), second half. Coordinator
  removed the worker's two poller edits before publishing (untested, and
  they changed what clients receive after a user Stop). Covers remote
  opencode, claudecode and codex turns only; `provider_unavailable` has no
  client card yet. First build on this base is the PR's CI.
- D2 `wip/d-stream-untilclose-eof` (`498fd8a4`) read. One correction
  ordered: over TLS only `close_notify` may count as a clean end of a
  close-delimited body, not a bare TCP close. Not published.
- Fixture kernel race: the slow run (3 s kernel delay) gave 51 failed /
  214 passed on shard 1; 31 failures are `launch.browser.spec.ts` on the
  real app, so the delay breaks unrelated tests and the run proves nothing
  about fixtures. Slow runs stopped; worker is closing out (classification
  table, one normal-speed confirmation, two patches). Nothing published.
  Master browser shards are green without it.
- Line "lean-ci App `5538046` is installed only on `lfglabs-dev`" further
  up is superseded by "CI: lean runners and docs-only pushes" below.

**Dev grant for isolation checks, 23:13 UTC (operator action, no duplicate).**
The isolation worker `6fa970f7` asked again for a `dev_operator` grant. The
request already exists: `f0eadef4-2978-46c7-82ae-5a6a7dd40ec2` (operator-
submitted, recorded further down as pending Thomas). Do not create a second
one. The coordinator cannot submit, see or redeem it (`list_mission_access`
for this mission: none), so its current state is not known here.
One constraint is new: that worker runs on managed VM `a474d57a`, which
reaches its 12-hour limit at 00:12 UTC and cannot be extended. A grant
approved for `6fa970f7` is only usable until then. If approval comes later,
the checks need a successor mission on another node and a request naming
that mission; the coordinator will write its id here before asking. The
operator running `scripts/dev_user_isolation.py` itself (operator request 1)
needs no grant and stays the shortest path.

**Update 23:27 UTC.**

- Merged: #1745 as `2b06d8a199c31dc1cc9ef5178bf96758036ae6fc` (member sibling routes, sidecar parked logins, overview correction). Its CI ran on a base before #1749; master CI on `2b06d8a1` is the first combined build and was still running at 23:25Z.
- Open, waiting for CI:
  - #1751 (`c3d79bd1`): a mission whose model chain is cooling for more than 60 s now ends its turn with a reason instead of staying silent. `Test` passed, `kernel-abi` pending at 23:25Z.
  - #1752 (`19fe8ace`): a close-delimited stream cut off by a timeout, a read error or a TCP close without TLS `close_notify` is no longer reported complete. Worker-tested on `b6afa205`; this is the same two commits on `2b06d8a1`. Known limit: on a plain-TCP (loopback) upstream a connection reset after the socket polled readable still counts as a clean end.
  - #1753 (`d3953b32`): the member provider toggle reply no longer carries the admin's per-model rate limits; tests pin the exact member field set on provider rows. The coordinator resolved a conflict with #1745 in `TenantIsolationTests.lean` (both blocks kept); that file is first compiled by this PR's CI.
- Provider row ids: Core never builds an id from an email, account name or login file name (worker trace: new rows get `prov-<epoch>-<seq>` unless an admin supplies an id; `ai_providers.json` ids are copied as stored; login never creates a row). Operator request 2 (yes/no per live `id`) is still the only way to rule out a hand-typed id.
- Browser fixture kernel race: closed without a PR. Two patches are kept on nimrud (`keep/fixture-kernel-init-42.patch`, sha256 `e5e771e6…d6a0`, 42 files under `orb/tests`; `keep/fixture-kernel-ready-promise.patch`, sha256 `c2a68970…419b`, 3 files), base `eb2791e5`. Evidence: `approval-queue`, `smooth-send`, `mermaid` repeated 3 times with both patches, `84 passed` (log read by the coordinator). Not run: both full shards with both patches together. The slow-network run (51 failed) proved nothing: the 3 s delay broke unrelated real-app tests. Master shards are green without the patches, so nothing is published; reopen only if the `Shared kernel is not initialized` failure returns.
- Isolation worker (`6fa970f7`): its provider patch `g-provider-identity-only-0da01d9e.patch` is rejected (does not apply after #1742, the leak is already fixed, its member shape drops `id`/`name` and breaks the toggle, never compiled). It will not be deployed. Its `orb-env` patch is superseded by the per-key policy on master. All four patches are preserved on nimrud; none is applied.
- Managed VM `a474d57a` stopped at 23:25Z (disk kept about 24 h). It reached its 12-hour limit at 00:12Z, so a later dev grant needs a successor mission on another node.
- No deploy request yet: no master tip after `e43a808d` has both CI and Kernel ABI green.

**Update 23:30 UTC.**

- Merged: #1751 as `37541b466009a7b144d966bbb419b9cfa0654f58` (11 checks passed on base `b6afa205`; trial merge with `2b06d8a1` clean, no file changed on both sides, #1745 does not call the functions whose signature #1751 changes). Master CI on `37541b46` is the first combined build.
- **Sidecar cooldown fields are not observed.** Core (`fetchSidecarAuthFiles`, merged in #1745) reads `cooldowns[].remaining_seconds`, `cooldowns[].retry_at` and `cooldowns[].reason` from CLIProxyAPI `GET /v0/management/auth-files`. Only `remaining_seconds` is also used by `scripts/ops/orb-sidecar-guard`. `retry_at` and `reason` rest on the worker's reading and on test fixtures, not on a live reply. If they are absent, Core falls back to `now + remaining_seconds` and `credential_quota`, so the card stays correct. If they are free text, Core passes them unchanged to members as `parked_until` / `parked_reason`. H-core (`21b1bfca`) has Task 4: accept `reason` only as a short lowercase slug and `retry_at` only as a timestamp-shaped string, branch `wip/h-parked-reason-closed-shape`. No client reads `parked_*` yet.
- There is no field named `reset_duration_seconds` anywhere in the repository. The example relayed by the isolation worker was invented and nothing is coded against it.

**Operator request 5: field names and types of the sidecar login list (read-only, on agent-core).** Prints one line per JSON path with its types. It prints no login name, email, token or key: object keys that do not look like field names are shown as `<key>`, strings are shown as `str` only, except `status`, `cooldowns[].scope` and `cooldowns[].reason` when they are a short lowercase slug, and `cooldowns[].retry_at` with every digit replaced by 9. It sends one GET, changes nothing and restarts nothing. Checked on two made-up replies on nimrud only. Paste the output as is.

```python
import json, re, sys, urllib.request
def shape(v, path, out):
    if isinstance(v, dict):
        for k, x in v.items():
            shape(x, path + "." + (k if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,39}", k) else "<key>"), out)
    elif isinstance(v, list):
        out.setdefault(path + "[]", set()).add("array")
        for x in v:
            shape(x, path + "[]", out)
    else:
        t = type(v).__name__
        if path.endswith(("cooldowns[].reason", "cooldowns[].scope", ".status")) and isinstance(v, str):
            t += ":" + (v if re.fullmatch(r"[a-z0-9_]{1,40}", v) else "<other,%d chars>" % len(v))
        if path.endswith("cooldowns[].retry_at") and isinstance(v, str):
            t += ":" + (re.sub(r"[0-9]", "9", v) if re.fullmatch(r"[0-9TZ:+.\-]{1,35}", v) else "<other,%d chars>" % len(v))
        out.setdefault(path, set()).add(t)
def main(doc):
    out = {}
    shape(doc, "$", out)
    for p in sorted(out):
        print(p, "|".join(sorted(out[p])))
if __name__ == "__main__":
    if len(sys.argv) > 1:
        main(json.load(open(sys.argv[1])))
    else:
        key = [l.split("=", 1)[1].strip().strip("\"'") for l in open("/etc/open_agent/open_agent.env") if l.startswith("CLI_PROXY_MANAGEMENT_KEY=")][0]
        req = urllib.request.Request("http://127.0.0.1:8317/v0/management/auth-files", headers={"Authorization": "Bearer " + key})
        main(json.load(urllib.request.urlopen(req, timeout=10)))
```

Run: `sudo python3 sidecar_schema.py` (reads `CLI_PROXY_MANAGEMENT_KEY` from `/etc/open_agent/open_agent.env`, like the guard script). Most useful while a login is parked; with no cooldown active the `cooldowns[]` lines will be missing and that is itself worth knowing.

**Correction 23:33 UTC: dev access never goes to a managed VM.** The 23:13 note above said a grant approved for `6fa970f7` would be usable on its VM until 00:12Z. That was wrong: managed VMs must hold no credentials, and a dev admin bearer is one. `6fa970f7` ran on managed VM `a474d57a` (now stopped) and will not redeem anything. `f0eadef4-2978-46c7-82ae-5a6a7dd40ec2` is a request id, not a grant id, and names that mission, so approving it as it stands is of no use. Two valid paths remain: the operator runs `scripts/dev_user_isolation.py` on agent-core and pastes the sanitized JSON (operator request 1, no grant needed), or a new mission on a trusted static node is named in a new request; the coordinator starts that mission and writes its id here only when the operator asks for this path. No grant exists for the coordinator (`list_mission_access`: none at 23:31Z).

Live builds at 23:31Z (health endpoints, 9-character `build` resolved in the repository): prod `e43a808d46d28543022f12705e5dbae14b72d59d` (on master, #1739); dev `0fc4d71af69bbb66225ef043eefcaafed4b5e3bf` (a `wip/e-member-sibling-routes` commit, not on master). The 13:16Z deploy of `9e33099d4cf5aabfffdc565aeb8dd3bcb103905e` that the worker's relay mentions is long superseded. Any deploy request written here will give the full 40-character SHA and ask for the finished deploy receipt plus the `build` value from the health endpoint.

**Update 00:40 UTC, 14 Nov (coordinator).**

- Merged: #1752 (`ba366e3614609763cfe910f2623c619791cab140`, a stream that ends without a clean end of body is no longer reported complete) and #1753 (`15d404cd7c49dcd003ec5d11bc79e3a61ffe1da1`, a member's provider toggle reply no longer carries the admin's per-model limits). Neither is deployed yet: dev and prod both report build `c77d4e162` at 00:29 UTC.
- Open: #1754 (`d99871e1d216b8f6c3ec15d32b5c17de1384206b`), sidecar `reason` and `retry_at` are shown only in a fixed shape. Tests (a), (b), (d) failed before the fix per the worker; I read the full diff and did not rebuild it. CI on the new base was still running at 00:34 UTC. Limit: if the live sidecar uses another form for `reason`, every sidecar park shows `credential_quota` (operator request 5 would settle this).
- Three settings pages that crash for every user (operator client walk). Traced by reading both sides at `21f20846`, nothing run. Core's replies lack the field names the desktop, iOS and Android read; the mismatch dates from #1693 (12 Nov), not from this week's merges, and the repo's own audit already lists it (`docs/plans/rust-lean-audit-provider-status.md`, PROV07 and HTTP08).
  - Usage summary: client reads `totals.requests`, `cost_cents`, `unknown_cost_requests`, `since`, `cost_status`, `by_hour`; Core sends `events`, `recorded_cost_cents`, `estimated_cost_cents`, `window_start`.
  - Proxy health: client reads `groups`, `chains`, `totals.ok`, `retried`, `fell_back`; Core sends `by_provider`, `by_chain`, `succeeded`, `retried_requests`, `fallback_requests`.
  - Routing health: client reads `cooldown_remaining_secs`, `is_healthy`, `total_input_tokens` and other counters; Core sends `cooldown_secs_remaining`, `remaining_quota_pct`, `sample_count`. My earlier instruction to keep `cooldown_secs_remaining` as the only cooldown field was wrong and is being reversed.
  - No error boundary exists around settings pages.
  - Owners: H-core (`21b1bfca`, nippur) adds the client-read keys in Core without removing any (branch `wip/h-client-reply-shapes`); new worker `d3be1f3d-1b2a-49bf-a69b-72310d0938fe` (uruk) makes the three desktop pages tolerate absent fields (branch `wip/h-settings-pages-tolerate-core-shapes`).
- Search answers 404: `/api/control/missions/:id/messages` (`Control.lean` about 3694) matches before the search route with `id = "search"`. Scoped users get 404; on single-tenant prod the caller probably gets a message array instead of search results. Deduced from route order, not run. Owner: C (`729e035b`, lagash), tests first.
- Session token in a WebKit WebSocket error: the token is not in the URL; both sockets pass it as a subprotocol (`orb/src/stream.ts` 694-698, `orb/src/Machines.tsx` 263-266). Why WebKit prints it is not established. No owner yet.
- No owner yet: admin controls shown to members; a member has no mission target on desktop; presentation stream closing 0.4 s after its snapshot; the six routes that still answer the same for members (`/api/model-routing/chains`, `/api/cloud/accounts`, `/api/mesh/status`, `/api/usage-telemetry`, `/api/mcp/capabilities`, `/api/library/skill-delivery`).
- Lean runners (lean.ci PR #34, head `90ae6f2d6de17d6d235b903f4296ea59c249bf39`): my review of the previous head found that a fenced job at the head of the queue blocked every older-engine poll and caused a claim/release/audit loop, and that the heartbeat overwrote `worker_nodes.metadata`. Both are addressed in the new head (read, not built; worker reports 227 tests pass, four new ones failed before). Remaining points are in the PR comment. **The security hold is unchanged**: no deploy, variable, label, merge or Supabase change.
- The operator brief "sent to the coordinator at 23:40" did not arrive as a turn; the findings above are taken from the night log.

**Update 00:46 UTC, 14 Nov (coordinator): silent model stream.**

- Operator observation: the coordinator's own turn received no events from Core's model proxy from 23:48:56 to about 00:08 UTC (at least 19 minutes) until the operator stopped the process. Requirement: a proxied stream with no bytes for 20 minutes must end with an error.
- Read on master `b2c1eab2` (nothing run): the idle limit is 600 s per read (`Proxy.lean` 824), but each failover attempt before the response head gets a fresh 600 s and nothing is sent to the client meanwhile, so the wait grows with the number of targets; a timeout is not distinguishable from a closed connection; any upstream byte, keep-alive lines included, resets the clock, leaving only the 60-minute total limit; no test exercises a real deadline.
- Which of these happened in the incident is not established. To tell them apart someone with access to agent-core would need the proxy records of the call that started at 23:48:56 UTC (attempt count, bytes relayed).
- Owner: D2 (`4549d257`, uruk), branch `wip/d-stream-idle-budget`, tests first: one 20-minute budget across attempts, a distinct `upstream_idle_timeout` outcome (504 before the head), wire tests with injected limits. Keep-alive-only streams are recorded as a known limit, not changed.
- The relay of the lean.ci worker report received at 00:38 UTC describes commit `50771e0f` (13 Nov 16:33 UTC). The PR branch has three later commits; head `90ae6f2d` is the one reviewed above. Nothing in that relay changes the hold. The coordinator deploys nothing on lean.ci.

**Update 01:10 (coordinator).**

- **#1754 merged** as `8be33c00` at 00:52:35Z (head `d99871e1`: 11 checks pass, 4 skipped; merge-tree clean against `c5d2f78e`; no file in common with master's changes since the PR base). CI on `8be33c00` was running at 01:07Z.
- **Live at 01:07Z:** prod and dev both report build `c5d2f78e9`, which contains #1751, #1752 and #1753 and does not contain #1754.
- **Owned by the operator session, not by the coordinator (do not duplicate):** LeanUI `744dcd38-b550-4208-8d10-441705fc8297` (the three #1711 defects, reference captures, pixel-diff table) and Member UI `d5218bd0-b37f-44dd-85cd-efcd04f09c61` (role gating of admin controls, raw 403 JSON, WebSocket token, member mission target, iOS/Android mirror). These items leave the coordinator's unowned list.
- **H-client `d3be1f3d` scope closed** to `UsageSettings.tsx`, `ReliabilityView.tsx`, `RoutingSettings.tsx`, their four data modules (`usageApi.ts`, `proxyHealthApi.ts`, `reliability.ts`, `routingApi.ts`) and their tests. The earlier permission to guard other files under `orb/src` is withdrawn; other files are reported, not edited.
- **Workers at 01:00Z:** D2, H-client, H-core and C all show tool events within the last minutes (H-core finished its Part A tests-only build at 00:55Z; C built `orb-core-test` at 00:51Z). No worker branch is on origin yet.
- **Presentation stream closes right after its snapshot: cause found by reading `8be33c00`, nothing run.** `GET /api/control/stream` (`lean/OrbCore/OrbCore/Control.lean` 4245-4257) returns one `missions_snapshot` frame as a fixed body and ends the reply. It reads none of `mission`, `since_seq`, `profile`, `kinds`. `registerSseSubscriber` (`LegacyHydrate.lean` 366) has no caller outside `SelfTest.lean`, so no HTTP client ever receives a live event on this route. `GET /api/control/missions/:id/stream` (4259-4273) is the same one-frame reply. The block dates from the port commit `6ba6b085` (11 Nov). This holds for every caller, admin or member.
  - Desktop only uses this route when the `/api/control/sync` WebSocket is not connected (`orb/src/stream.ts` 1222-1255). When the body ends it throws `stream ended`, reports disconnected, and reconnects after 2 s, 4 s, 8 s, then every 15 s (1209-1218). Inference, not observed: in the operator's WebKit walk the WebSocket failed (that is the error that printed the token), so the client fell back to this route.
  - Android calls `/api/control/stream?mission=…` (`OrbBackgroundSync.kt` 1113, 1269) and iOS calls the route in `OrbClient.swift` 809. Both get the mission list frame, not that mission's events. Not run on either platform.
  - A real stream needs a held-open reply (`bodyStream?`, `Control.lean` 1166), a hub subscription, a keep-alive, and a per-caller filter: `publishControlEvent` delivers every mission's events to a subscriber without a mission filter, so a member must not get an unfiltered subscription. Owner: D2 after the idle-budget task (streaming transport). Not dispatched yet.
- **`/api/remote-nodes` hang: one cause found by reading, and it does not depend on the caller.** The handler (`Control.lean` 5178-5193) is the same for admins and members; the only caller-dependent parts are two SQL reads and the filter on managed machines. It calls `buildComputeFleetJVal` (`RemoteFleetAndRelay.lean` 662), which probes every static node (`probeAllStaticNodesParallel`, 602) and waits for all probes. Each probe is `sendJsonRequest … 2500` on the node's base URL. On a plain `http://` URL the 2500 ms only limits reads (`OrbBin/HttpClient.lean`, `readSocketTimed`); the connection itself is `LeanSys.Posix.tcpConnect`, a blocking `connect()` with no timeout (`lean-sys` at the pinned revision `bbe3183d`, `c/lean_sys_shim.c`, `leansys_net_listen` with `backlog == 0`). A node address that drops packets therefore holds the whole reply until the kernel gives up on the connection (about two minutes with Linux defaults).
  - Not established: why the operator saw it for members only. Nothing in Core's handler explains a difference. Needed from the operator: was the hang seen with a direct request (how long, which status) or in the client, and does the same request as admin on dev return at once.
  - Client side, read only: `/api/remote-nodes` is in the lowest request class (`orb/src/transportScheduler.ts` 66). That class is paused while the client counts a transport failure, and a queued request has no timeout. This could look like a hang in the client; it was not reproduced.
  - Fix inside Core without touching `lean-sys`: wait for the probes up to a deadline and report unfinished nodes from the heartbeat cache as today's offline rows. Owner: C after Task E (`RemoteFleetAndRelay.lean`). Not dispatched yet.

**Update 01:40 (14 Nov).** Master `8be33c00` (#1754): CI and Kernel ABI green. Live prod and dev at 01:22Z: `c5d2f78e9` (has #1751-#1753, not #1754).

- **#1755 open** (`ready/c-search-route-shadow`, head `68faafe2`, track C Task E): `GET /api/control/missions/search/messages` was answered by `/api/control/missions/:id/messages` with `id = "search"` (scoped caller 404 `mission_not_found`, legacy-unscoped `200 []`). Fix in `Control.lean`: `search` is never a mission id (three sites). Worker test: cases (a), (b), (d) failed before the fix, (c) passed. Coordinator read the full patch; resulting blobs equal the worker's. Reported, not changed: `coverage.indexed_missions` / `total_missions` come from an unscoped `COUNT(*)`, so a member learns the total mission count.
- **#1756 open** (`ready/h-settings-pages-tolerate-core-shapes`, head `a7c433cd`, H-client): Usage, Router reliability and Routing health pages no longer throw on Core's present replies; absent number shows a dash, absent array the "no data" text; cooldown read as `cooldown_remaining_secs ?? cooldown_secs_remaining`. Six unit tests, three failing before the fix. Only the three pages, four data modules and two test files change. Limits: the usage chart still draws 0 for requests and cost Core does not send; `orb/src/UsageCharts.tsx:23` is unguarded (out of scope, gets a normalized array); bundle budget headroom 1 kB; mobile readers unchanged.
- **D2 idle budget** (`wip/d-stream-idle-budget` `eb371f71`): design accepted, not published. Sent back at 01:36Z with four points: (1) the `proxy_outcomes` row is now written only after the stream pump returns, so it can be lost; (2) an unrequested change of the exhausted-chain reply body for every transport error; (3) a non-2xx upstream answer arriving after the budget is relabelled 504 `upstream_idle_timeout`; (4) upper time bounds of a few hundred ms in tests (flaky on CI). Test result lines and before-fix evidence were missing from the reply.
  - D2's read-only answer on watchdogs: remote turns have a 900 s limit only before the first stdout byte (`RemoteDispatch.lean` 978-982, 1072-1096); after that no limit; `missions.stall_minutes` is stored but enforced by no loop; local harness loops have no idle timer. A harness behind `orb-locald` sees a truncated stream as a clean end, not as an error (`OrbLocald/CliMain.lean` 159-218). Not verified by the coordinator. No owner.
- **C Task F dispatched 01:30Z**: deadline on the static-node probe wait for `GET /api/remote-nodes` (`RemoteFleetAndRelay.lean` only, tests first with a never-completing connect, no `lean-sys` change).
- **H-core Task 5**: Part A (routing health keys) pushed at `3e133534`, not reviewed yet; branch conflicts with master in `docs/model-routing-health-cooldowns.md` (based on the pre-squash #1754 commits); rebase requested.
- Real SSE for `GET /api/control/stream`: still not dispatched (D2 after the idle budget).

**Update 02:30 (coordinator).**

- Merged: #1756 (settings pages tolerate Core reply shapes, `ce029bec`) and #1755 (mission search route no longer shadowed, `6ed24089`). Master CI is green on both; Kernel ABI on `6ed24089` was still running at 02:31Z. Live build on prod and dev at 02:31Z: `c5d2f78e9` (does not contain #1754, #1755, #1756).
- Open, waiting for CI: **#1757** (one idle budget before the stream head; a timeout is told apart from a closed connection). Its first CI run failed three jobs on one lint finding (`lean-finally-let-mut` in `Control.lean`): the `finally` block read a `let mut` set inside the `try`, which is always the old value. The coordinator missed it in review (the diff was read, the lint was not run) and fixed it in `cbff919e`. From now on `python3 scripts/lint_kernel_calls.py` is run on the agent node before any publish.
- Open, waiting for CI: **#1758** (`/api/remote-nodes` waits at most 2500 ms for static-node probes). Limits written in the PR: the stuck probe thread is not stopped (one thread and one socket per unreachable node per request, for about 130 s); `POST /api/nodes/:name/capacity` is still unbounded; a connect timeout in the plain-HTTP client is the complete fix and has no owner.
- D2 (uruk) is on two tasks, both based on the #1757 branch: a test that fails if the shared pre-head budget is removed, then a real held-open SSE stream for `/api/control/stream` and `/api/control/missions/:id/stream` with per-caller scoping.
- H-core Task 5 (additive Core keys for the three settings pages): routing health accepted; proxy health sent back with four points (01:58Z); usage summary sent back with five points (02:22Z). The main one: `by_api_key` would have shown one mission's execution key (`remote-launch:<mission id>`) as a label, because that is what the only writer stores in `api_key_name`. Nothing of Task 5 is published.

**Update 03:10 (coordinator).**

- Merged: **#1757** (one idle budget before the stream head, `a54cf97c`, 02:58Z) and **#1758** (`/api/remote-nodes` waits at most 2500 ms for static-node probes, `fc770afe`, 03:06Z). For both, the `Test` job result line was read on the PR head before merging (`orb-core-test` ok, 101 host tests; spec runner 5 passed). #1758's CI ran on the base before #1757; the two touch no common file or name. Master CI on both merge commits was still running at 03:06Z. Live build on prod and dev at 03:04Z: `6ed240898` (does not contain these two).
- Open: **#1760** (tests only): the "upstream never answers" case now uses three targets, so it fails if the shared pre-head budget is removed (the gap disclosed in #1757). Not built by the coordinator and no result lines from the worker for this commit; its `Test` job is the first known run. That it fails without the budget check is by reading, not observed.
- Open as **draft, do not merge**: **#1759** (Core keys the three settings pages read: routing health, proxy health, usage summary). Eight of nine review points are closed in the code. The ninth is a defect the coordinator caused: `by_root_mission` joins `mission_orchestration_meta`, which no production code writes, so in production it is a copy of `by_mission` while the test passes on its own fixture. The coordinator suggested that join without checking for a writer. H-core has been sent back to roll up through `missions.parent_mission_id` or drop the key. CI skips `Test` and the lints on draft PRs, so nothing on this branch has been built in CI yet.
- H-core's written report for the proxy-health part described functions, keys and files that do not exist on the branch. The code was reviewed directly and is fine; the report's result lines are treated as unverified. Workers are now told to write file:line references from the final commit and to give the command and finish time for each result line.
- C (lagash) has Task G: a connect timeout for plain-HTTP requests, the cause behind the `/api/remote-nodes` hang. By reading: `HttpClient.sendRequest` uses lean-sys `tcpConnect` (blocking, no timeout); our own C shim already has a connect with a timeout (`orb_net_leaf.c:58`), used only by the TLS path. So no lean-sys change is needed: one small exported C function plus one `@[extern]`, and the generated FFI allowlist. This adds a function to the trusted C shim.
- D2 (uruk) continues on the held-open SSE stream, now based on master `a54cf97c`.

**Update 04:15 (coordinator).**

- Merged: **#1760** (tests only, `a8d8df6b`, 03:39Z). Master CI is green on `a54cf97c` (#1757), `fc770afe` (#1758) and `a8d8df6b` (#1760); the Kernel ABI run on `a8d8df6b` was still running at 04:14Z. Live build at 04:14Z: prod and dev both `6ed240898`, so #1757, #1758 and #1760 are merged but not deployed.
- Open, ready: **#1761** (C, Task G): plain-HTTP requests give up on the TCP connect after `min(timeoutMs, 10000)` ms instead of blocking for about 130 s. This is the cause behind the `/api/remote-nodes` hang that #1758 bounded from outside. `Test` passed on the PR head (`orb-core-test` ok, 101 host tests; spec runner 5 passed); the new cases sit inside an existing host test, so the log does not name them. Waiting for `kernel-abi` (C shim is 219 of 220 allowed lines), then merge. Behaviour changes listed in the PR: host names and IPv6 literals now connect over plain HTTP (the old path took numeric IPv4 only), name resolution is outside the timeout, writes are now bounded. `Proxy.lean` 848 and 1063 still use the blocking connect.
- **#1759** stays a draft. The `mission_orchestration_meta` defect is fixed on the branch (roll-up now walks `missions.parent_mission_id`, tip `17ddf619`). Review found two smaller defects in the new roll-up, both back with H-core, tests first: the sort uses a non-strict comparator (`>=`), which `Array.qsort` gets wrong (checked with Lean v4.35.0 on the coordinator node: `[1, 2, 2, 1]` comes out `[2, 1, 2, 1]`), and a root bucket can carry a subagent's id as its label. Nothing on this branch has been built in CI yet (draft).
- D2's held-open SSE stream (`wip/d-control-stream-sse`) was read in full and is **not published**. Main finding: members would receive almost no live events, even for their own missions, because the stream reads the mission id from the event payload and most real payloads do not carry one (the tests' payloads do). Also sent back: about 50 `users` queries per second per idle stream; a disconnect probe added to `handleClientConn` that also changes the model proxy stream; the snapshot rule for admins changed; a new production environment variable for the keep-alive interval.

**Update 04:37 (coordinator).**

- Merged: **#1761** (plain-HTTP requests give up on the TCP connect after `min(timeoutMs, 10000)` ms, `72679fb7`, 04:35Z). Before merging: all 16 checks passed on the PR head, including `kernel-abi` (C shim line limit, warnings as errors) and `Test` (`orb-core-test` ok, 101 host tests; spec runner 5 passed); the only change on master since the PR base was this board. Not verified: a real unreachable node, a slow upload, macOS. Behaviour changes are listed in the PR (host names and IPv6 literals now connect over plain HTTP, name resolution is outside the timeout, writes are bounded).
- Master CI: `a8d8df6b` (#1760) is fully green (CI and Kernel ABI). Runs for `72679fb7` had just started at 04:36Z.
- Live build at 04:30Z: prod and dev both `6ed240898`, so #1757, #1758, #1760 and #1761 are merged but not deployed. Until a deploy, `/api/remote-nodes` can still hang on an unreachable static node.
- In progress, nothing delivered yet: H-core on the two roll-up defects of #1759 (still a draft), D2 on the five SSE review points.

**Update 05:25 (coordinator).**

- Master: CI and Kernel ABI both passed on `72679fb7` (#1761). Prod and dev still report build `6ed240898` (read 05:24Z), so #1757, #1758, #1760 and #1761 are merged but not live.
- Held-open SSE stream (D2, `wip/d-control-stream-sse` at `68d8e52f`): round 2 read in full, **not published**. Accepted by reading the code: the hub now carries event type and mission id (no payload parsing), the client-socket peek in `handleClientConn` is gone, the snapshot uses the same caller scope as `GET /api/control/missions`, the keep-alive interval is a `CoreAppState` field (15 s default, no env var), caller re-check once per second. Sent back at 05:25Z:
  1. **Privacy defect**: `sseStreamResponse` delivers every mission's live frames to any admin user (`Control.lean:1179-1190`, `1247-1249` on that tip). The kernel rule (`multiuserRbacStep`, read class) and the sync WebSocket refuse a mission to an admin who is neither owner nor participant; the stream's own snapshot lists only the admin's missions. The branch test asserts the wrong behaviour. Asked: no admin bypass for frames with a mission id; frames without one stay admin and legacy-unscoped only.
  2. The stream does not end when the bearer token expires (the sync WebSocket does). Asked: re-check with `resolveCallerPrincipal?` on the request headers.
  3. The lag test depends on the stream loop being asleep during a 270-frame burst: would be flaky on master. Asked for a hub-level assertion plus a retried socket check.
  4. Per-stream visibility cache grows by one entry per mission id seen.
  - Worker-reported only, not verified: `orb-core-test` ok with `"host_tests":101`, spec runner `5 passed` on `68d8e52f`.
  - Finding for the clients, no owner: the desktop fallback opens `/api/control/stream?profile=presentation&kinds=mission_presentation`; nothing in `lean/` publishes a `mission_presentation` event on the hub, so that stream would carry only the snapshot, keep-alives and `stream_lagged`. D2's reading and mine agree; not tested against a client.
- #1759 (draft): H-core has run seven builds on showing the new tests fail before the fix and has not yet changed `ProviderUsageAndLogin.lean`; nothing pushed. Sent a note at 05:25Z: commit the tests, make the two fixes (strict comparator with tie-break, root label = root id), one build, push.

**Still open, no owner.** Track A / #1708; lean.ci PR #34 fence review
(interdiff unread, lean runners stay on hold); isolation acceptance and
managed-lifecycle live validation (need the `dev_operator` grant
`f0eadef4`); the three operator findings in `core-recovery-2026-11.md`
166-178; a remote turn whose queued follow-up fails to dispatch stays
`active` with no run (`RemoteDispatch.lean:1185`). The 19:06 relay "C live
validation request received for 816f574f" was read as a delayed message;
nothing was done on it.

**Update 09:42 UTC, 14 Nov (coordinator `2bcfd62a`).**

- **Master and live builds.** Master tip is `3226e954c` (#1765, MacBook tether broker and MCP tools, merged 09:21Z after #1759 settings reply keys, #1762 held-open SSE streams, #1763 locald router provider, and #1764 desktop `+` action buttons). Both prod and dev `/api/health` report `build: "3226e954c"` (`single_tenant` on prod, `multi_user` on dev), so the `/api/remote-nodes` probe deadline (#1758) and HTTP connect timeout (#1761) are now live on dev.
- **Open PRs:**
  - **#1766** (`8363f23d`, single-tenant managed budget carries client-read `_usd`, `active`, TTL and size keys): CI running (`Orb Desktop Shell`, `Harness Contract Tests`, `Docker image`, `Policy Lint` passed; waiting on `Test` and `kernel-abi`).
  - **#1708** (`ci/cached-turbo-lean`): remains open for Track A/B.
- **Multi-user member (`ben`) execution & WebSocket gaps identified on `3226e954c` and dispatched to two isolated `boat:large` workers:**
  1. **Core + Web (`8f53412f` on `managed-3800f797`):**
     - `orb-jwt-v2:<userId>:<role>:<sessionEpoch>:<exp>.<hmac>` (`Control.lean:305`) contains colons, violating RFC 6455 `tchar` when passed as `jwt.<token>` in `Sec-WebSocket-Protocol` (`orb/src/stream.ts:695`, `orb/src/Machines.tsx:266`), throwing a `DOMException` that embeds the raw token. Fix: encode `:` as `~` in the WebSocket subprotocol, normalize `~` -> `:` in `verifySessionTokenV2` / `extractWsJwtSubproto?`, echo the client subprotocol verbatim in `negotiateWsSubprotocol?`, wrap `Machines.tsx` `new WebSocket` in `try/catch`, and redact any `jwt.`/`orb-jwt-` token in WebSocket error strings.
     - `POST /api/control/missions` (`Control.lean:4152`) with `"remote_node_id": "auto-managed:<provider>:<size>"` and a non-empty prompt calls `submitRemoteMissionTurn` without provisioning a VM first, failing with `502 no_managed_machines_available` when the user has no ready VM. Fix: provision through the shared managed-machine admission path when a prompt is present (matching `McpGateway.lean` and `POST /api/managed-machines`), bind `owner_mission := mid`, roll back on refusal, and cover `resume`/`steer` on unresolved `auto-managed` targets while preserving `SelfTest.lean:1752`.
     - `classifyMissionPlacementTarget` (`Control.lean:1112`) now classifies `OrbCore.AutoPlacement.reserved` targets (`dgx-spark-admin`) as `(1, 1)` so members receive `core_target_forbidden_for_member` at admission, and `orb/src/App.tsx:839-857` defaults non-admins without static nodes to the first usable `auto-managed:<provider>:<size>` instead of `"local"`.
  2. **OrbNode single-tenant managed VM (`28a75b5a` on `managed-f82ce6eb`):**
     - On a managed VM, `sandboxed-node` runs as `orbnode` via dial-out enrollment without `orb-privd` (`/run/orb-privd.sock` absent). `OrbNode/Server.lean:616` (`admitNodeLeaseRole`) currently uses `targetKind := 2` and sets `execUnixUser := claims.unixUsername.getD ""`, causing `Runner.lean:1316-1333` (`ensureMissionUser`) to fail on member jobs. Fix: add `managedSandbox : Bool := false` to `NodeConfig` (enabled on dial-out / `SANDBOXED_NODE_MANAGED_SANDBOX=1`), pass `targetKind := 3` to `Orb.Kernel.placementRoleAdmit`, set `execUnixUser := ""` when `managedSandbox` is true while keeping `callerRole := "member"` when `!rec.ownerUserId.isEmpty` so `managed_auth` host credentials are never copied for member jobs.
- **LeanUI Wave 2 (`ea916daa` on `managed-d8103971`):** healthy and active on `lean/OrbDesktop/Screens.lean` and `orb/tests/leanui-reference.capture.ts` (36 reference captures and per-screen pixel-diff table).
- **Operator correction (08:50 UTC & 14 Nov relays, recorded 09:48 UTC): dead `~/.ssh/orb_m2air_temp` key deleted; laptop access will use the MacBook tether broker (`request_macbook_tether` / `list_macbook_tethers` / `revoke_macbook_tether`, #1765 merged on master `3226e954c`) once the operator gives the go-ahead.** Removed `~/.ssh/orb_m2air_temp` and `~/.ssh/orb_m2air_temp.pub` from the coordinator home (`ls -la ~/.ssh` verified empty). Do not touch `feat/mac-tether` or call `request_macbook_tether` until the operator instructs. All desktop/LeanUI builds, reference captures, and pixel-diff runs proceed on managed VMs (headless Wayland + lavapipe, `ea916daa` on `managed-d8103971` at event seq 599 packaging its Wave 2 bundle), while items that remain strictly laptop-only until the tether is ready are:
  1. Native macOS shell & signer (`Orb macOS Shell & Signer (Swift)`) runtime and Touch ID / Keychain verification.
  2. Native iOS (`OrbApp` / Simulator) and Android (`android-orb`) interactive device/emulator walk as member `ben`.
  3. Live authenticated browser/desktop walk as `ben` against dev Core (`agent-backend-dev.thomas.md`), because managed VMs must never receive `ben`'s session token or credentials.

### Open items with no owner yet (filed 10:10 UTC, 14 Nov, from the operator)

Staff these after the multi-user and LeanUI priorities are satisfied. Each gets
an owner and a dated status line here when dispatched.

| # | Item | Detail |
| --- | --- | --- |
| U1 | Governed node binary rollout | `sandboxed-mcp`, `sandboxed-node` and `orb-privd` are copied to fleet nodes by hand (nimrud ran a 30 Oct `sandboxed-mcp` until 14 Nov). Wanted: one governed, checksummed rollout path with cordon/drain and rollback, driven from the deploy tool. Interim operator script to study, not to depend on: `/root/orb-node-mcp-update.sh` on agent-core. |
| U2 | Native Linux row menu | `linux_shell/gtk_chrome.c` still lacks New cron, New folder, Rename and Archive; #1764 added only the "+" buttons. |
| U3 | macOS native sidebar "+" buttons | The macOS native sidebar does not have the "+" (New project, New agent in a project or folder) buttons added for Linux in #1764. |
| U4 | Tether lease revoke on every terminal transition | `request_macbook_tether` leases are revoked only on stop, cancel and DELETE routes. The MCP `cancel_mission` tool and provider-failure stops leave the lease alive until its TTL (up to 4 h). Revoke on every terminal transition; tests first. |
| U5 | Tether decision (recorded, closed) | The confined host shell keeps `~/.ssh`, `~/.orb` and Bitwarden hidden. Do not ask Thomas for more access. |

**Update 10:28 UTC, 14 Nov (coordinator `2bcfd62a`).**

- **CI speed track staffed in parallel now** (not queued behind multi-user or LeanUI; `$200/day` VM cap):
  - **W-CI-1 (`b3b4bc79-e2cc-4793-aed3-902641105fe1` on `managed-f824120f-72c8-413d-9f63-7f75caab9c31` / `orb-managed-bb0ba6fa-796`, `boat:large`)**:
    - Root cause identified for `--no-telemetry` fallback on nodes/CI: pre-installed `/usr/local/bin/turbo-lean` on fleet/managed nodes is an Oct 31 binary that lacks `--no-telemetry`, `--no-daemon`, and `--no-auto-worktree-link`, while `scripts/build_orb_bins.sh` unconditionally passed `--no-telemetry` and fell back to uncached raw `lake build` on exit code 2.
    - W-CI-1 fixes `scripts/build_orb_bins.sh` to probe `turbo-lean --help` before passing optional global flags (while setting `TURBO_LEAN_TELEMETRY=off LEAN_NATIVE_TELEMETRY=off`) and fail closed instead of silently falling back to raw Lake; ports `.github/actions/setup-turbo-lean/action.yml` (#1708) with cached release `turbo-lean` binary + persisted CAS/`.lake` cache keyed on toolchain + lakefile + source hashes (restore on PR, save on `master`); and folds `kernel-abi.yml` into `ci.yml` so it shares the planner and cached Lean artifacts without weakening any test or audit.
  - **W-CI-2 (`2c14ec06-c5f4-4d92-9bc3-b7057b9a6608` on `managed-98ceb168-e4f4-46cc-afd2-6a7d644b307c` / `orb-managed-fce8fadb-9d0`, `boat:large`)**:
    - Root cause identified for 11 min desktop-only PRs and redundant `master` push rebuilds: `orb-browser` Shard 1 ran `pnpm build` from scratch + two `playwright.kernel.config.ts` suites on top of `test:browser --shard=1/2`, both shards ran `ci_harden_ubuntu_apt.sh` + `playwright install --with-deps` even on cache hits, and `master` push rebuilt trees identical to green PR runs.
    - W-CI-2 adds tree-hash verification reuse / cache promotion when a `master` push tree matches a green PR run, shares the built `orb/dist` artifact from `orb-unit` across `orb-browser` shards and `orb-performance`, rebalances browser shards, and scopes `desktop_native` domain triggers so desktop-only PRs finish in `< 5 min`.
  - **W-CI-3 (`57fec405-a612-40e2-8673-1c885505f63e` on `managed-e8cc032a-dc5f-4d41-b39e-5db796d270a5` / `orb-managed-282e51a4-40b`, `boat:large`)**:
    - Completed and harvested Deliverable 2 (`w-ci-3-orb.bundle`, commit `a95efef4` on `ci/w-ci-3-lean-runners-opt-in`): gates Linux CI jobs behind `vars.ORB_LEAN_RUNNERS == 'true'` (and `workflow_dispatch` input `use_lean_runners`) on trusted default-branch events with exact fallback to `ubuntu-latest` / `ubuntu-24.04` (verified by 28 unit + mutation tests in `scripts/test_ci_plan.py`), and writes Thomas's exact approval & rollout checklist in `docs/ci-lean-runners.md`.
    - Deliverable 1 (`lfglabs-dev/lean.ci` PR #34 runner fence): delivering the private `lean.ci` crate archive to `57fec405` so it can fix the remaining review items (`routing.rs` `runner_fence_capable` strip, `github.rs` rerun `run_attempt` from verified `WorkflowRun` provenance, `store.rs` `RefusedNotAllowed` queue ordering, and live shell execution tests of the `ACTIONS_RUNNER_HOOK_JOB_STARTED` fence script) and run `cargo test` across all crates.
- **#1766 and #1767**: merged to `master` (`a64471d2`, `1f1e1ab3`).
- **PRs opened for CI speed (real-run timings still to fill in):**
  - **#1771** (W-CI-3, `ci/w-ci-3-lean-runners-opt-in`, `a95efef4`): lean.ci opt-in behind `ORB_LEAN_RUNNERS` with exact `ubuntu-latest`/`ubuntu-24.04` fallbacks, 28 planner tests plus mutation checks, and `docs/ci-lean-runners.md` spelling out what Thomas must approve. Not enabled by this PR.
  - **#1772** (W-CI-2, `ci/w-ci-2-tree-reuse-and-fast-desktop`, `9d096be1`, rebased on today's `master`): verified-tree receipts and artifacts so a master push matching a green tree reuses its routing; one `orb-build` job publishes `orb/dist` for unit, browser and performance; eight whole-file browser shards; pinned Playwright image; `lean/OrbDesktop/**` moved to `desktop_native`. Worker evidence: 348 script tests, 2225 unit tests, 55 planner tests at 100% branch coverage, shards 181 s / 148 s locally, all 517 browser and 10 performance tests retained.
  - Cold vs warm wall clock on GitHub Actions is the remaining measurement; both PRs must produce their own before/after numbers before this track can close.
- **W-CI-1 (`b3b4bc79`)**: still running on `orb-managed-bb0ba6fa-796`. It has the `build_orb_bins.sh` CLI-probe fix building `OrbBin` and `OrbNode` through the installed binary, `kernel-abi` moved into `ci.yml` and kept in `ci-ok`, restore-on-PR / save-on-master caching, and regression tests for old, current and partial `turbo-lean` CLIs plus the explicit raw-Lake override. Cold build measurement still in flight; no bundle yet.
- **W-CI-3 deliverable 1 blocked on private-source delivery.** `lfglabs-dev/lean.ci` is private and the worker VM holds no credentials by design. The archive is prepared on nimrud (`sha256 1f529941...`), but nimrud is unreachable from a managed VM (port 8099 times out) and the `.paloma/` attachment probe did not materialize. Do not put a GitHub token on a managed VM to work around this. The four scoped fixes are written out below so they can be applied by whoever has the private checkout:
  1. `leanci-ctrl/src/routing.rs` (~321, portable warm artifact report): remove `runner_fence_capable` from the metadata object before `patch_rows`, exactly as the warm-layer path at ~409 already does.
  2. `leanci-ctrl/src/github.rs` (~712, `try_admit_and_dispatch_job`): set `ActionsRunnerFenceSpec.run_attempt` from the verified `WorkflowRun` provenance JSON (`provenance["run_attempt"]`) rather than `run.github_run_attempt`, so a rerun whose queued `workflow_job` omitted `run_attempt` is not rejected by the fence verifier; test with `run_attempt: 2`.
  3. `leanci-ctrl/src/store.rs` (~3555, `release_db_claim`): the non-prebuild path pushes the refused assignment to the back of `assignment_queue`, so in-memory order diverges from `created_at`; insert in `created_at` order and test it.
  4. `leanci-shim/src/lib.rs`: execute the generated `ACTIONS_RUNNER_HOOK_JOB_STARTED` script as `bash` with real `GITHUB_*` env and `GITHUB_EVENT_PATH`, using the shim's own writer for the script text, covering matching default-branch push (0), wrong `GITHUB_RUN_ID` (non-zero), `pull_request` event (non-zero), wrong `GITHUB_SHA` (non-zero), missing fence file (non-zero).
  Then `cargo test -p leanci-types -p leanci-shim -p leanci-engine -p leanci-ctrl`. Nothing merged, no variable or Supabase change: shipping stays Thomas's decision.

### Status update — 2026-11-14 ~11:45 UTC (Mode 2 directive confirmed; PR #1771 & #1772 green with measured timings)
- **Thomas's directive on W-CI-3 confirmed:** Mode 2 only (`runs-on: lean-16vcpu-ubuntu-2604` / `lean-32vcpu-ubuntu-2604`), no Mode 1 prebuilds, and zero touch on `evm.fast` (`Layr-Labs/evm.fast-dev` / `Th0rgal/evm-fast-pilot`).
- **PR #1771 (`ci/w-ci-3-lean-runners-opt-in`) and PR #1772 (`ci/w-ci-2-tree-reuse-and-fast-desktop`) are both 100% GREEN** (all 16 and 24 check contexts passing).
- **Measured GitHub Actions wall-clock timings on real runs (#1771 run `43588087727` vs #1772 run `43588165243`):**
  - **Browser shards (W-CI-2):** dropped from **518 s (8.6 min) / 407 s (6.8 min)** on 2 shards (`ubuntu-24.04` + apt + `pnpm build` per shard) to **127 s–232 s (2.1–3.9 min)** across 8 whole-file shards in the pinned Playwright container after a single **51 s** `Orb build` job (`Orb browser (1/8)` 232 s including the 2 kernel browser suites; shards 2–8: 188 s, 180 s, 139 s, 127 s, 169 s, 160 s, 203 s).
  - **Orb unit (W-CI-2):** dropped from **205 s (3.4 min)** to **110 s (1.8 min)** by reusing the `Orb build` dist artifact.
  - **Projected desktop-only PR (`orb/**`, `macos_shell/**`, `linux_shell/**`, `lean/OrbDesktop/**`):** `Plan` (13 s) + `Orb build` (51 s) + slowest browser shard (232 s) / `Orb Desktop Shell` (203 s) + `CI OK` (7 s) = **~303 s (5.0 min)** vs **11 min** baseline, and `lean/OrbDesktop/**` no longer triggers the 20 min `Test` job.
  - **Uncached Lean jobs on GitHub hosted (`Test` 1075–1245 s / 17.9–20.8 min, `Harness Contract` 530–620 s / 8.8–10.3 min, `Docker` 658–705 s / 11.0–11.8 min, `kernel-abi` 1372–1972 s / 22.9–32.9 min):** still dominated by uncached raw `lake build` and `kernel-abi`'s cold `cargo build -j 1` of `turbo-lean`; these are the exact jobs W-CI-1 (`b3b4bc79`, currently finishing its cold `OrbCore` build on `orb-managed-bb0ba6fa-796`) converts to cached `turbo-lean` and folds into `ci.yml`.
- **What merging and deploying `lean.ci` PRs #33 + #34 changes on `lean.ci` production, and how to roll back (for Thomas's decision):**
  - **Production changes when deployed:**
    1. `leanci-ctrl` (`ubuntu@5.39.72.91`, `leanci-ctrl.service`): enables User-owned repository JIT runner registration (`/repos/{owner}/{repo}/actions/runners/generate-jitconfig` with `runner_group_id: 1`) **only** for repositories explicitly listed in `/etc/leanci/leanci-ctrl.env` `LEANCI_USER_RUNNER_REPOSITORIES=Th0rgal/orb` whose GitHub App installation is active with `Administration: write` and `repo.enabled = true`. Before every dispatch, `leanci-ctrl` fetches `/repos/{owner}/{repo}/actions/runs/{run_id}` and requires matching `repository.id == head_repository.id`, default branch (`master`), and event in `["push", "schedule", "workflow_dispatch"]`. Every User-repository assignment carries `ActionsRunnerFenceSpec` and is only routed to engines whose live heartbeat declares `runner_fence: true`.
    2. `leanci-engine` (`10.88.100.11..13`, `leanci-engine.service`) + guest rootfs (`/var/lib/boost/rootfs-base/ubuntu2604-boost*.ext4` `/usr/local/bin/leanci-shim`): heartbeats advertise `runner_fence: true`; fenced jobs run in `mode: "actions_runner_fenced"`, which writes `runner-fence.json` + `job-started-hook.sh` and sets `ACTIONS_RUNNER_HOOK_JOB_STARTED` before `actions-runner` starts. If a PR or mismatched job claims the JIT runner by label, the hook writes `runner-fence-violation.txt` and `SIGKILL`s `Runner.Worker` + `Runner.Listener` before any container pull, `pre:` hook, checkout, or cache restore; the engine destroys the microVM (`conclusion = "fenced"`) and `leanci-ctrl` re-queues the displaced trusted job (up to 3 attempts).
    3. **Warm cache inside `lean.ci` microVMs (item c):** `leanci-shim` (`prepare_runner_cache`) already exchanges `cache_auth_token` against the engine-local `leanci-cache-proxy` (`http://172.30.0.1:4200`, two-tier NVMe + S3) and exports `ACTIONS_CACHE_URL=http://172.30.0.1:4200/`, `ACTIONS_CACHE_SERVICE_V2=True`, `NODE_OPTIONS=--require preload.js` (redirecting `actions/cache@v5` Twirp/artifactcache traffic to the local NVMe proxy), plus `TURBO_LEAN_REMOTE_CACHE=http://172.30.0.1:4200/turbo` and `TURBO_LEAN_REMOTE_TOKEN`. Combined with W-CI-1's `setup-turbo-lean` action, `turbo-lean`'s CAS is warm across `lean.ci` microVMs.
  - **Immediate rollback (two independent levers):**
    - *Orb side (instant, zero deploy):* `gh variable set ORB_LEAN_RUNNERS --repo Th0rgal/orb --body false` (or delete the variable) — every workflow job immediately evaluates back to `ubuntu-latest` / `ubuntu-24.04`.
    - *`lean.ci` ctrl side:* remove `Th0rgal/orb` from `LEANCI_USER_RUNNER_REPOSITORIES` in `/etc/leanci/leanci-ctrl.env` and `sudo systemctl restart leanci-ctrl.service` (or restore `/usr/local/bin/leanci-ctrl.rollback`). No database schema migration is involved.

### Status update — 2026-11-14 ~11:57 UTC (MacBook tether live E2E test on `nimrud`)
- **Requested & approved:** `request_macbook_tether(scope="host_ssh", ttl_minutes=120)` created lease `ae4981a6-4ae1-43f9-ad74-881678d2bcfe`; Thomas approved with Touch ID (`state: "approved"`, `effective_scope: "host_ssh"`, `effective_target: "thomas"`, `overlay_ip: "10.88.200.10"`, `mac_overlay_ip: "10.88.200.1"`, `mac_ssh_port: 2224`, `mac_wg_pubkey: "rgY2mepUA4Hgse4bbYOKUDE1pJQrPeb+URmtdxrzEjM="`, `mac_direct_endpoint: "192.168.1.126:51889"`, `relay_endpoint: "65.109.98.246:51890"`, `expires_at: 1794664476`).
- **Step-by-step outcome:**
  1. **Client key provisioning + KEM PSK derivation (`sandboxed-mcp`):** SUCCEEDED — `/dev/shm/orb-mac-tether-ae4981a6-4ae1-43f9-ad74-881678d2bcfe` (`0700`) populated with `id_ed25519`, `id_ed25519.pub`, `kem.key`, `peer.psk`, `wg.key`, `wg-macmesh0.conf`, `ssh_config`.
  2. **Core lease verification (`/api/mac-tether/verify-lease` from `orb-privd-lean`):** SUCCEEDED — `orb-privd-lean` verified the `tether1.*` lease against Core and created `/run/orb-mac-tether/<reqId>` (`0700 root:root`).
  3. **`mac_tether_up` (`orb-privd-lean` -> `wg set wg-macmesh0 ...`):** FAILED (`tunnel_active: false`) with exact error:
     `keys ready in /dev/shm/orb-mac-tether-ae4981a6-4ae1-43f9-ad74-881678d2bcfe; orb-privd activation skipped (wg set wg-macmesh0 failed: fopen: Permission denied)`
     and `tearDownMacTetherState` deleted `wg-macmesh0`.
  4. **Root cause on `nimrud`:** Ubuntu 24.04's AppArmor profile `/etc/apparmor.d/wg` for `/usr/bin/wg` only allows reading `/etc/wireguard/{,**}` and `/etc/lean-mesh/{,**}` (from `/etc/apparmor.d/local/wg`). When `orb-privd-lean` runs `wg set wg-macmesh0 private-key /run/orb-mac-tether/<reqId>/wg.key peer <pub> preshared-key /run/orb-mac-tether/<reqId>/peer.psk ...`, AppArmor denies `/usr/bin/wg` opening `/run/orb-mac-tether/<reqId>/*` (`fopen: Permission denied`).
  5. **Minimal fix (one-line host config or code):**
     - *Host config on `nimrud` (instant, no rebuild, reuses existing approved lease `ae4981a6-4ae1-43f9-ad74-881678d2bcfe` via `list_macbook_tethers`):* append `/run/orb-mac-tether/{,**} r,` to `/etc/apparmor.d/local/wg` and reload with `apparmor_parser -r /etc/apparmor.d/wg`.
     - *Code fix in `OrbBin/PrivdMain.lean`:* either default `ORB_MAC_TETHER_RUN_DIR` to `/etc/wireguard/orb-mac-tether` (already allowed by `/etc/apparmor.d/wg`'s `file rw @{etc_rw}/wireguard/{,**},`) or pass `/dev/stdin` / `wg setconf` via stdin.



**Update 10:10 UTC, 14 Nov (coordinator `2bcfd62a`).**

- Filed U1 to U5 on this board with no owner; U5 is a closed decision, not work.
- **#1767** (operator's, waiting on CI): `Test` and `kernel-abi` pending at 10:10Z, everything else passed. The operator merges and deploys #1766 and #1767, then installs the Lean `orb-privd` on nimrud; this mission will be paused briefly during that rollout. I do not deploy or touch nimrud's node binaries.
- Tether: call `request_macbook_tether` with target host only after the operator confirms; until then no laptop path is used.
- Active workers unchanged at 10:10Z: `18ab4b08` (Core member `auto-managed` + WS token), `d9a273d2` (OrbNode `managedSandbox`), `242ef3da` (per-user libraries), `ea916daa` (LeanUI Wave 2 bundle parts).

**Update 10:05 UTC, 14 Nov (coordinator `2bcfd62a`).**

- **Live builds.** Operator confirms prod and dev run `e263b6bd4`; my own read of both health endpoints at 09:48Z still showed prod `3226e954c` and dev `432f3fef4`, so a deploy landed after that read. #1757, #1758, #1760 and #1761 are live.
- **Dead SSH key removed.** `~/.ssh/orb_m2air_temp` and `.pub` deleted; `~/.ssh` is empty. Laptop access will come only through the MacBook tether broker (#1765, live on prod). Not usable from fleet nodes until the operator rolls out the new `sandboxed-mcp` key provisioner and Lean `orb-privd` (`mac_tether_up`); that rollout is the operator's, not mine. Nothing touched on `feat/mac-tether`. Laptop-only work stays queued: macOS shell/signer + Touch ID, iOS/Android interactive walks as `ben`, credentialed `ben` desktop walk.
- **Worker VM loss and respawn.** The two `boat:large` workers dispatched at 09:40 (`8f53412f`, `28a75b5a`) were gone by 09:50Z with their missions and actions deleted (`get_mission`/`get_action` -> `not_found`), so nothing was delivered. Respawned and relaunched:
  - `18ab4b08-539b-43ef-b4b5-3691b24c5c4c` on `managed-01f71d95-46f4-4a6e-aafa-eade3990a01a` (`orb-managed-1d7b9b09-c85`): Core + web (WebSocket `tchar` token encoding/redaction, `auto-managed` provisioning in `POST /api/control/missions`, `AutoPlacement.reserved` classification, `App.tsx` member default target).
  - `d9a273d2-a071-4216-8891-59a435bb449c` on `managed-1b5db84a-b829-46cf-b90a-39689597ae41` (`orb-managed-504f9b5d-008`): `OrbNode` single-tenant `managedSandbox` admission/execution without `orb-privd`.
- **PR #1766.** `Test` passed on the head `8363f23d` (21m42s); `kernel-abi` still pending. Merge when it lands.
- **Member skill libraries (Thomas's decision).** Spec written and pushed to `master` as `docs/specs/per-user-skill-library.md` (`d9233feb`): per-user checkout `{storeRoot}/library/users/<userId>`, per-user `library.json` for remote/revision, `resolveLibraryRootFor`, owner path and `LIBRARY_PATH` unchanged, `/api/library/*` and `/api/library/skill-delivery` scoped to the caller, mission install scoped to the mission owner, clients show the member's own library with create/edit, eight new Core tests and one kernel gate, plus a dev `ben` verification step. A third `boat:large` worker is being spawned for the implementation.
- **Managed compute.** Daily cap is now $200 (operator). Fleet budget read at 09:58Z: `spent_today_cents: 0`, `daily_cap_cents: 20000`, `max_concurrent: 100`.
- **LeanUI Wave 2 (`ea916daa`).** Worker reports mean mismatch `58.63%` -> `7.62%` (`4.09%` above tolerance, SSIM `0.9340`, max `0.9841`), 36/36 deterministic, `scripts/test_leanui_tokens.py` passing. Its reply carried the Wave 1 bundle base64 but the Wave 2 base64 was truncated by the event transport before `===BUNDLE_END===`; asked it for the Wave 2 bundle and parity table in <=32 KB parts. Worker-reported only, not yet harvested or verified.

### Operator night log, 13 Nov 21:15 to 23:45 UTC (Claude, for Thomas)

Thomas approved a night plan at about 21:15 UTC and is away. Facts and decisions:

- **Deploys.** Prod and dev ran `e43a808d4` from 21:32, then `c77d4e162` from
  23:39 (dev first each time, self-test green). After the second deploy
  `builtin/smart` and `genius` both answer on prod. The operator session is the
  deploy owner for the night and deploys each green master tip; no deploy
  request is needed.
- **Member isolation, measured.** A probe on agent-core compares about 300 GET
  routes as admin and as `ben` on dev (`/root/benprobe.py`, names and sizes
  only). On `c77d4e162` the member no longer receives owner provider names,
  the discovery file, other users' usage rows or failures, Library skill
  bodies, other users' missions in the resources overview, host paths, or the
  software inventory paths. Still identical for members: `/api/model-routing/chains`,
  `/api/cloud/accounts`, `/api/mesh/status`, `/api/usage-telemetry`,
  `/api/mcp/capabilities`, `/api/library/skill-delivery`.
- **Real client walk as `ben`.** Run in a throwaway NixOS VM on Thomas's laptop
  (Playwright WebKit, `orb/dist` at `0fc4d71af`, dev Core), 69 screenshots.
  Not the native shell. Findings are in the brief sent to the coordinator at
  23:40: three settings pages crash for every user because Core's reply shape
  differs from `orb/src` (usage summary, proxy health, routing health); search
  answers 404; the presentation stream closes 0.4 s after its snapshot; admin
  controls are shown to members; a member has no mission target on desktop;
  the session token appears in a WebKit WebSocket error message.
- **Decision: token only, laptop only.** Managed VMs must not hold
  credentials, so the VM ran locally with `ben`'s dev session token and never
  his password. The token was printed once in the local session log, so
  `ben`'s dev password was reset at 22:40 (old token answers 401).
- **Decision: member reduced views, not 403**, wherever member screens call the
  route. Usage summary for members is zeroed; per-member usage is a follow-up.
- **Decision left to Thomas:** members' missions still receive Library skill
  bodies in their workspace, and the delivery catalog lists skill names and
  descriptions to members. Per-skill visibility is a policy choice.
- **Bug: `send_message_to_mission` (MCP) answered `action_outcome: rejected`
  three times** for this mission tonight while `queued: true`; the notes never
  arrived. The same text sent through `POST /api/control/message` was accepted.
  No owner yet.
- **Bug: `PUT /api/model-routing/chains/:id` cannot address built-in ids that
  contain a slash** (`builtin/smart`); it creates a stray chain that can take
  `is_default`. Workaround: `POST /api/model-routing/chains` with the id in the
  body. No owner yet.
- **Surplus Intelligence** is a provider on prod since 16:00 UTC and serves
  `gemini-4-argon` as third target of `builtin/smart`; Thomas entered the key
  and lowered its discount floor to 97 %.

### Coordinator status 18:45 UTC: two fixes merged, queue delete missing in Core, lean runner fence not ready

**Master.** Tip is `eb2791e5` (#1736, merged by the coordinator at 18:31
with all checks green). CI `43463948426` and Kernel ABI on `e9786d7e` (#1735)
both completed green. Open pull requests: #1708 only.

**Merged since 16:40.**

- #1735 (`e9786d7e`): `tests/code-block.tsx` initialises the kernel itself.
  This fixes the red-master flake. The plugin change described in the 16:40
  section below (`edde09e8`) is dropped: with it the fixture loads through a
  dynamic `import()` after a top-level `await`, `page.goto()` returns before
  the fixture ran, and shard 1 ended 9 failed, 4 flaky.
- #1736 (`eb2791e5`): `deletable_at` is `null` when a machine has no minimum
  lease, instead of `1970-01-01T00:00:00Z`; the number is in
  `deletable_at_sec`. Not verified: iOS and Android builds beyond CI.

**No deploy request for #1736.** Correction of an earlier coordinator note:
the `deletable_at` equal to `created_at` seen on prod at 18:36 (machine
`a474d57a`) is not the 1970 defect. The create path sets
`deletableAtSec := nowEpochSec` (`Control.lean:4968`, `McpGateway.lean:376`),
so a new machine is deletable from creation. #1736 changes only rows whose
stored value is 0, and clients read the field only while `reap_reason` starts
with `awaiting_deletable_at:` (`orb/src/managedMachineModel.ts:541-543`). It
can ride the next deploy. CI and Kernel ABI on `eb2791e5` were still running
at 18:55.

**New finding, by reading master, nothing run: Core has no
`DELETE /api/control/queue/:id`.** Desktop, iOS and Android all call it to
remove a queued follow-up. The `:id` arm in `Control.lean` (~5191) handles
`PATCH` only, so the call ends in the generic 404. The desktop treats that
404 as success (`orb/src/RemoteQueue.tsx:238-245`): the card disappears, the
row stays, the card returns on the next fetch and the message is delivered
after a later turn. `POST …/send-now?interrupt=true`
(`ResourcesAndSystem.lean:2739`) only moves the row to the head and answers
`promoted: true`; nothing stops the running turn. Both are already listed in
`docs/plans/core-recovery-2026-11.md` line 172. This explains the queued
steer that could not be removed on mission `734c3bb7`. C (`729e035b`, lagash)
has the route as `wip/c-queue-delete`, tests first.

**Member isolation.** Still not passed.

- `wip/e-member-provider-projection` (`79473e60`) is reviewed and accepted;
  it waits behind the login fix because both edit
  `ProviderUsageAndLogin.lean`.
- Six neighbouring routes have no role check. C's test, pushed as
  `wip/e-member-sibling-routes-tests` (`dac3d30e`, expected to fail), shows a
  member reading the owner's provider names (`/api/providers/catalog`), the
  discovery file (`/api/providers/discovery`), every user's usage rows
  (`/api/ai/usage/summary`) and failures (`/api/ai/proxy/health`).
  `/api/ai/proxy/timing` and `/api/model-routing/health` return no marker.
  Member screens on all three clients call usage summary and routing health,
  so the fix is a reduced view, not a 403. Fix assigned to H-core after its
  current tasks.

**Provider reconnect (Thomas's panel bug).** `wip/h-provider-login-health`
(`50d7b0d0`) is reviewed and accepted with one correction: Antigravity
cooldowns are keyed per model (`cliproxyapi:antigravity:<model>`) and the
branch cleared exact keys only. H-core (`21b1bfca`, nippur) confirmed the
reading and pushed the corrected commit (`85aa81a9`) at 18:50. The
coordinator read the change (one rule, used in the three places that clear
evidence), cherry-picked it onto `eb2791e5` and opened #1737
(`ready/h-provider-login-health`, `d8e70607`). The build and test results are
the worker's report (build 4:59 with plain Lake); the coordinator has not
seen the log lines, so CI on #1737 is the independent run. Merge when green.

**Streaming (#1729 defects, live).** The D worker on dgx-spark produced no
events in two turns and is cancelled. D2 (`4549d257`, uruk) replaces it and
was reading the code at 18:30. No fix is merged; the four defects in the
16:10 section stand.

**Lean runners (lean.ci #34).** Reviewed by reading plus running the verifier
script on 13 environments: it refuses `pull_request_target`, `workflow_run`,
another run, a rerun attempt and a missing event file. Not ready:

1. `write_job_started_summary_hook(...).ok()` (`leanci-shim/src/lib.rs:404`):
   if the hook cannot be written the runner starts without it.
2. `runner_fence` is an optional field: a guest image with an older shim
   ignores it and runs the job unfenced, while the new controller admits
   public repositories.
3. No test evidence: only Vercel checks ran on the pull request.

Th0rgal/orb is public, so this is the path that matters. Corrections sent to
`e14bb767` (uruk) at 18:40. No deploy, no label or variable change.

**Other work in progress.**

- Docs-only push filters: v2 rejected (`!` is documented for `paths`, not
  `paths-ignore`; `docs/**` hides five docs that tests read). v3 asked from
  `e14bb767`.
- Fixture kernel start: with the kernel delayed 3 s, `approval-queue`,
  `machine-transfer` and `send-experience` fail with "Shared kernel is not
  initialized". 45 of 48 fixture pages depend on the race. Worker `549c6b99`
  adds the two lines per fixture and runs both shards.
- Desktop mission view (`734c3bb7` symptoms): v2 not publishable (docs named
  mobile code that does not exist; cases replayed fields Core never sends;
  the queue card cause is the missing route above). v3 asked from `11a48ddf`,
  due 20:15.

**Added 19:06 UTC.**

- **Master is red on `eb2791e5`.** CI job "Orb browser (1/2)" failed:
  `tests/sidebar-multi-move.browser.spec.ts:552` (Cmd+C copies transcript
  text) lost its selection on 3 of 3 attempts. The same test failed once and
  passed on retry on `e9786d7e`. #1736 touches no file under `orb/`, so this
  is an existing flake, not caused by the merge. Failed job re-run by the
  coordinator at 19:03 (attempt 2 in progress). Worker `549c6b99` has the
  cause and fix as its next step; nothing was merged on top of the red run.
- **Silent turn on a cooling chain (Thomas's outage request).** Traced by
  reading, nothing run: when every target of a chain is cooling, the proxy
  answers 429 with `Retry-After` up to 3600 s (`Control.lean` ~1486-1493,
  `Proxy.lean` 253-257, 635-651) and writes nothing to the mission, although
  it knows which mission asked. No watchdog ends a silent turn before the
  node's 4 hour job limit; `stall_minutes` has no consumer. Assigned to C
  (`729e035b`) as `wip/h-cooling-chain-ends-turn`, after its queue-delete
  branch: one mission error event and the turn stopped when the wait is over
  60 s, tests first.
- **Operator relay passed to H-core:** the sidecar management schema for the
  parked-credential task, and that the guard from #1727 is installed on prod.
  The branch `fix/provider-health-clear-and-login` named in that relay is
  already on master as #1728; #1737 sits on top of it.
- **Build option for workers:** push a `wip/` branch and ask here for
  "build+self-test `<full sha>` dev-only". None requested yet.

**No owner.** Independent review of the #1731 `[ffi]` allowlist and
turbo-lean `aee2d17`; `lean/turbo-lean-revision` still `29d85f7`; installed
turbo-lean rejects `--no-telemetry`, so every node builds with plain Lake.

### Coordinator status 16:40 UTC: member provider identity exposed, fixture fix held back

**Master.** Tip is `313ec310` (#1734, OpenCode over ACP, merged by the
operator at 16:33; not reviewed by the coordinator). CI run `43457328636`
on `6bf88c30` completed green. Kernel ABI is green on `f1d2a61e`
(`43452657455`) and was still running on `6bf88c30` at 16:35. CI
`43463948426` on `313ec310` is in progress. The only open pull request is
#1708.

**New finding, by reading master, nothing run: a member can read the
identity of the owner's provider accounts.** Prod is single-tenant, so
nobody is exposed today; dev is multi-user and this blocks the isolation
sign-off.

- `GET /api/ai/providers` takes the hydrated branch
  (`ProviderUsageAndLogin.lean` ~1389-1405) whenever `ai_providers.json` or
  a CLIProxy auth file exists. A member then gets the full
  `renderHydratedProviderJv` row for every enabled provider with
  credentials: `account_email`, `status.account`, the stored name, base
  URL, Google project id, rate limits. Only the fallback in `Control.lean`
  ~4448-4466 uses the redacting renderer.
- `GET /api/ai/providers/:id`, `/usage`, `/:id/usage` and
  `/for-backend/:backend` have no role check and carry the email or the
  stored name.
- The existing test (`SelfTest.lean` ~4864-4870) only checks that the API
  key and one base URL are absent from the member list.
- A patch from the old E+G worker
  (`g-provider-identity-only-0da01d9e.patch`) is rejected: it reduces the
  member row to `provider_type` and `user_enabled`, which removes the `id`
  the member's own preference toggle needs
  (`orb/src/Providers.tsx:335`), and leaves the detail and usage routes
  open.
- H-core `21b1bfca` (nippur) owns that file and was asked at 16:40 for
  failing tests through HTTP first, then one member projection for list,
  detail and usage, as `wip/e-member-provider-projection`.

**`code-block` fixture fix: not published.** The worker's one-line change
to `testFixtureKernelBootstrap` (commit `edde09e8`) applies to `313ec310`,
the served HTML now wraps the fixture entry instead of the Vite client,
and the spec passed 20 of 20 on WebKit (log read) and on Chromium (worker
report). But the worker's full shard 1 run with the fix, read while still
running (172 of 266 results), shows nine tests failing on all three
attempts, three timeouts and two flaky. Master CI passes that shard.
Whether the fix or the worker's VM causes them is unknown; the worker was
asked at 16:40 to run the same spec files on unmodified master and report
test by test.

**Managed extend route exists twice.** `Control.lean` ~5024-5050 serves
`POST /api/managed-machines/:id/{stop,resume,extend}` for the owner only
and reloads the fleet cache. `RemoteFleetAndRelay.lean` ~1605-1616 serves
the same three for any admin, without the reload, but is only reached
after the first, so it is dead for these calls. C successor `729e035b`
had concluded the `Control.lean` arm was redundant and was about to remove
it, which would have let an admin extend a member's machine. Told at 16:40
to leave it, add a test that an admin gets 404 on a member's machine, and
keep the red-then-green evidence for `deletable_at` only. Its branch is
still not on origin and its tree was still on a pre-merge base.

**Other tracks.**

- Streaming (#1729): D successor pushed `wip/d-stream-contract-tests`
  `237a46e6` (tests, then fixes for truncation, cleanup and pacing). Read
  in full, not built by the coordinator. Five changes requested at 16:25:
  keep the usage accounting when a stream is cut, keep the real status of
  a cut 429 or 401, show that no stream can be dropped without its pump
  running, do not wait for upstream data when aborting, state the missing
  TLS total-time test. Not rebased on master yet.
- E+G's late claim that MCP `secret_*` tools have no admin gate is stale:
  master has the gate (`McpGateway.lean` ~437-441, error `forbidden`,
  commits `d1965606` and `40e71c0b`); the worker's base predates it. One
  gap remains and is with D successor as a tests-only branch
  `wip/e-member-session-secret-tools`: no test uses a session the member
  minted for its own mission.
- Provider panel: H-core has the sidecar-error fix and both tests stacked
  and rebased on `6bf88c30`, building at 16:19. Not pushed.
- Lean runners: B successor is wiring the job-bound fence and the
  immediate requeue of a displaced trusted job in `leanci-ctrl`. No branch
  reported.
- Mission view (`734c3bb7`): H `11a48ddf` is still reading desktop code,
  no patch.

No new `wip/` or `ready/` ref has appeared on origin since 16:10 other than
`237a46e6`.

### Coordinator status 16:10 UTC: master CI green, #1732 and #1729 live with open defects

**Master.** CI run `43452656987` on `f1d2a61e` completed green at about
16:05 UTC, the first green master CI run today (provider specs fixed by
#1730, planner claim fixed by `f1d2a61e`). Its Kernel ABI run
`43452657455` was still in progress at 16:09. #1732 was merged at 15:54 as
`6bf88c30`; its CI run `43457328636` is in progress, iOS and Android
builds on it are green. Prod and dev both report build `6bf88c30` at 16:09
(health endpoints), so #1729 and #1732 are live.

**Live defects, each with a worker on the fix:**

- `deletable_at` (from #1732, `Managed.lean:1634`): a managed machine with
  no minimum lease is reported as deletable at `1970-01-01T00:00:00Z`.
  All three clients read `deletable_at ?? reap_at`. C successor `729e035b`
  (lagash) has the fix and tests on its node, red on master's production
  files and green with the change by its own report; told at 16:01 to
  rebase on `6bf88c30` and push `wip/c-core-managed-list`. Not reviewed.
- Streaming (#1729, `aa96142d`), four defects found by reading: a
  truncated upstream body ends as a normal stream; the upstream is not
  closed when the downstream head write fails; the pacing slot is released
  before the body is pumped; the TLS reader enforces no total time limit.
  D successor `66e692a7` (dgx-spark) has failing tests compiling and is
  writing the fixes. Nothing pushed beyond `wip/d-stream-contract-tests`
  `9b2769b0`.
- `code-block` browser flake (3/20 on WebKit): cause is the
  `testFixtureKernelBootstrap` plugin in `orb/vite.config.ts`, which wraps
  the Vite client script instead of the fixture's entry, so 46 of 48
  fixture pages start without the kernel. Worker `549c6b99` is fixing the
  plugin; its one-file workaround was not published.

**Thomas's three requests.**

- Lean runners: lean.ci PR #33 is open and keeps public user repositories
  denied, because a JIT runner is not bound to a job and a fork pull
  request could take a runner booted for a trusted push. Orb is public, so
  #33 alone does not deliver the request. B successor `e14bb767` (uruk) is
  implementing a fence in the guest shim as a stacked PR. It found in the
  `actions/runner` v2.338.2 source that a failing job-started hook does
  not stop `pre:` and `post:` action steps, so the hook has to kill the
  runner process. No deploy, no repository variable change.
  `wip/b-docs-only-push-filters` is rejected as written: `'**/*.md'` would
  skip CI for Markdown files that are test inputs (`skills/*/SKILL.md`,
  three iOS fixtures, `shared/orb-spec/ABI.md`, `plan.md`). A narrower v2
  with a planner test is requested.
- Provider panel after reconnect: H-core `21b1bfca` (nippur) pushed
  `wip/h-login-completion` `e11f4375` and a regression test for #1728,
  `wip/h-cooldown-clear` `dc6a2171`. Review found one regression: after
  the callback is accepted the poll no longer asks the sidecar for its
  status, so a wrong callback URL fails after 60 seconds with the wrong
  reason. Fix and a single stacked branch `wip/h-provider-login-health`
  requested at 15:59.
- Fable outage actions: guard shipped by the operator in #1727. Core
  display of sidecar parking and admin clear: design requested from
  H-core, not started.

**Mission view stuck after completion (`734c3bb7`).** H's first desktop
patch is not published. It clears a stale `remote_job`, but no non-test
Lean file emits `remote_job`, `queue_wait`, `execution` or `recovery`
since the Lean port (#1595), so that cannot be what was on screen.
`docs/REMOTE_NODES.md` and `scripts/remote-launch-canary.sh` still
describe those fields. H `11a48ddf` was re-briefed at 15:48 to reproduce
the incident with fields Core really sends. Mobile part on hold.

**Not reviewed by the coordinator:** #1731 (turbo-lean `[ffi]` allowlist,
generated from every in-tree `@[extern]`), upstream turbo-lean `aee2d17`,
#1734 (OpenCode over ACP), #1708. `lean/turbo-lean-revision` is still
`29d85f7d` while Nix pins `aee2d17`.

### Coordinator status 14:40 UTC: red master reproduced, A extern findings

**Red master.** Run `43438246411` on `8a0c7198` completed red, again only
in `Orb browser (1/2)` and `(2/2)`. Worker `549c6b99` reports (its own
runs, not yet reviewed by the coordinator):

- All eight provider cases reproduce on `8a0c7198` and pass once the
  account group is opened; no product change needed. The stale-spec
  hypothesis for #1722 holds.
- `code-block` is flaky: 17/20 passed alone. The failures are preceded by
  `Shared kernel is not initialized`. `orb/tests/code-block.tsx` renders
  `Transcript` without `initializeKernel()`, unlike `orb/src/index.tsx`
  and `orb/tests/transcript.tsx:3-4`. The worker may fix that fixture
  only, and must explain why the failure is intermittent.
- No patch delivered yet. The provider fix ships first if it is ready
  before the `code-block` work.

**A: the `unsafe` proposal is declined.** Old A proposed marking the
ConformanceRunner externs and their callers `unsafe`. Read against
turbo-lean source, this makes things worse:

- At the Orb pin `29d85f7d` every `unsafe` declaration is rejected
  (`ZygoteWorker.lean:1395`); only the init-exec whitelist is exempt.
- At `bca79f34` (the pin #1708 proposes) and at HEAD `15676ea2`,
  `isPinnedFfiOpaque` requires `!cinfo.isUnsafe`, so an `unsafe` extern can
  no longer be admitted by the per-symbol pin, and each `unsafe` caller
  needs its own `[unsafe] allow` entry.
- It would touch about 250 defs in `HostObservers`/`HostTests` and, by the
  proposal's own account, still fail the extern gate.

**A: what the existing admission mechanism requires** (source reading at
turbo-lean HEAD, nothing executed):

- `--ffi-allow` is not a user flag. It is generated from the compiled-in
  table `PINNED_FFI_PACKAGES` (`crates/turbo-lean/src/zygote.rs:4000`):
  a git dependency with pinned URL, revision and source SHA-256, plus a
  `(declaration, C symbol)` list. Path dependencies and in-tree modules
  are skipped.
- Orb's 24 `OrbBin.PosixExt` externs are in-tree, so no configuration in
  Orb can admit them. Orb also pins `lean-sys` at `bbe3183d`, while the
  table pins `077775ba`.
- ConformanceRunner has 192 externs (150 `orb_*`, 41 `leansys_*`, 1
  `lp_*`); none of its `leansys_*` symbols is among the 8 pinned ones.
- ConformanceRunner, HostObservers and HostTests are imported only by the
  `OrbCore` umbrella, and the umbrella only by `SelfTest`. The `orb-core`
  root `CliMain` does not import them. They affect `orb-core-test`,
  `orb-spec-runner` and the `OrbCore` library target, not the server
  binary. `PosixExt` is imported by 53 modules and blocks everything.

**#1708 does not solve this.** Its `Test` job (`131367939609`) fails on
the same 24 `PosixExt` rejections, and its kernel-ABI job (`131367817432`)
fails on `turbo_spec_verify_audit_materialize_gate` for `Orb.Spec`
(`skeleton_clean=false, all_shards_certified=false, is_stubbed=true`).
`bca79f34` is an ancestor of turbo-lean HEAD and a descendant of the
current pin.

**A: decision needed, in turbo-lean, not in Orb.** Two ways to admit the
OS bindings without weakening the gate:

1. Move the `PosixExt` and `Sqlite` bindings into `Th0rgal/lean-sys` and
   add them to `PINNED_FFI_PACKAGES` with revision and source hash. Uses
   the mechanism that exists; costs a lean-sys change, a turbo-lean
   release and two pin bumps.
2. Add a project-level pinned FFI table to turbo-lean (module,
   declaration, C symbol, source hash) for in-tree modules. Smaller for
   Orb, but a new trust path in the gate that needs the same independent
   review as the rejected IO admission.

Until one lands, `wip/a-fail-closed-build-script` and #1708 both stay
unmergeable, and Orb keeps building through raw Lake. Not assigned: red
master and the three direct requests come first.

### Coordinator status 14:25 UTC: red master, overlaps, A measurement

**Master CI is red since 12:19 UTC.** Last green run: `ce131e11` (11:44).
Every completed run since fails only in `Orb browser (1/2)` and `(2/2)`
(`afae6c68`, `36b4205a`, `5852cc15`, `6b34935e`, `0dea70c8`); the others
were cancelled by newer pushes. Run `43438246411` on `8a0c7198` is in
progress with `Orb browser (2/2)` already failed.

- Failing specs on `0dea70c8`: `provider-quota-levels` (4 cases),
  `provider-account-order` (2), `anthropic-usage` (2), `code-block` (1).
- Likely cause, from reading the diff, not yet reproduced: #1722
  (`f6961606`, 11:59) collapses several accounts of one provider into a
  group closed by default (`.p-group-head` in `orb/src/Providers.tsx`).
  The three provider specs use two accounts of one type and look for the
  account rows directly; none was updated.
- `code-block` did not fail in the first red run, so it may be flaky.
- Worker `549c6b99-4b6f-4870-96e9-f523187218c4` (reusing VM `a474d57a`,
  expires 17:12 UTC) reproduces, fixes and delivers a patch. Scope:
  browser specs, product code only if a defect is proven.

**Overlap with operator PRs.**

- #1728 (`8a0c7198`, merged 13:57) fixes cooldown GET and clear across
  both owners and resets cooldowns and refused-login usage on a completed
  sidecar login. It adds no tests. H-core (`21b1bfca`) was told to rebase,
  drop duplicates and deliver what is left: the auth-file wait before the
  login session reports done, the re-probe, and the replay tests.
- #1729 (`fix/proxy-stream-passthrough`, head `6376a23b`, open, conflicts
  with master, no checks yet) implements incremental proxy streaming, which
  is track D's RUN-07. D (`95ad3d8d`) was told not to land a second
  implementation and to report what #1729 leaves open, with tests.
- #1708 (`ci/cached-turbo-lean`, head `8fcf5038`, opened 12 Nov, 8 checks
  failing) already provisions a cached `turbo-lean` in CI, removes raw
  Lake from `scripts/build_orb_bins.sh` and bumps the pin to `bca79f34`.
  It covers the same ground as track A's script change and B's CI work.
  Not yet reviewed by the coordinator; A and B must build on it or
  replace it, not run beside it.

**A.**

- `wip/a-fail-closed-build-script` at `e5208b1a` holds the reviewed script
  and test patch (source SHA-256 `9678ae0c…`). Verified on nimrud only by
  `bash -n`, `git diff --check` and its 7 unit tests. Not mergeable: no
  caller has a compatible `turbo-lean`, and the audit rejects the extern
  opaques in `OrbBin.PosixExt` and `ConformanceRunner`.
- Measurement on lagash (`7de6fc9b`, master `01f505a9`, cgroup
  `memory.max` 8 GiB): `orb-core` builds in 11:43.84, exit 0, peak RSS
  4.54 GiB, cgroup peak 7.05 GiB, 4574 major faults, no OOM events.
  `ProviderUsageAndLogin` took 30 s. The build went through **raw Lake**
  because the installed `turbo-lean 0.1.0` rejects `--no-telemetry`, so
  the turbo-lean path and the kernel audit were not exercised. The managed
  VM cap of 4.16 GiB is below the measured peak RSS.
- Extern admission design still unassigned.

**Workers.**

- B successor (`e14bb767`, uruk, cgroup 16 GiB): stopped at 13:51 because
  its `GITHUB_TOKEN` request `0de37764-51be-4a62-9905-00ee372d5301` is
  pending. Resumed at 14:17 on the parts that need no token (Orb workflow
  patch, baseline, gating design). **Thomas: approve that request** or
  lean.ci work cannot start.
- C (`816f574f`): no tool activity since 13:23 UTC although reported
  active; no checkpoint delivered. To be checked at the next wake.
- E+G (`6fa970f7`): mission completed; member redaction of
  `/api/ai/providers` not delivered. Dev grant `f0eadef4…` still pending.
- VMs for C, D, E+G and H extended to 17:12 UTC.

### Claude (Fable) outage 2026-11-13, 03:45 to 13:29 UTC: root cause

Established by the operator session; recorded here as reported, not
re-derived by the coordinator.

1. 03:45:07 UTC: Anthropic answered one 429 `rate_limit_error` ("would exceed
   your account's rate limit") to a Fable request on the thomas.marchand
   credential during a burst (15 requests/minute at 03:43). CLIProxyAPI
   (`claude_ratelimit.go:254`) took the weekly reset (18 Nov 15:00 UTC) as the
   cooldown and escalated it from model scope to credential scope
   (`credential_quota`). Fable, Opus 5.5, Opus 4.6 and Haiku were parked for
   131 h while the account was at 8% weekly use.
2. The second Claude login (benjamin) had an expired refresh token
   (`invalid_grant`), so there was no other candidate: every Claude request
   returned 503 `auth_unavailable` for the whole window.
3. Orb turned each 503 into its own 40-minute provider cooldown.
   `POST /api/model-routing/health/:id/clear` did not clear it and
   `GET /api/model-routing/health` showed 0 s.
4. The `genius` chain had a single target, so missions hung on
   "Starting OpenCode…" with no error.
5. The provider panel showed thomas.marchand as connected at 8% throughout.

Proof the park was wrong: at 13:28 the operator cleared the sidecar cooldown
(disable/enable the auth file through the management API) and, with benjamin's
credential disabled for the test, the thomas.marchand credential answered Fable
and Opus 5.5 with 200.

Related panel bug, same day: after Thomas reconnected benjamin at 13:20 UTC the
panel kept showing "the provider rejected this login" with stale 98% usage
until a real request was served at 13:29. Cause in
`lean/OrbCore/OrbCore/ProviderUsageAndLogin.lean`: the oauth-callback success
path (~1597) deletes `provider_auth_health` rows but leaves the cached usage
entry at `needs_reauth` (read by `loginRejected`, ~1143), returns "completing"
before the auth file exists so the client refresh (`orb/src/Providers.tsx`
~618) re-caches the old state, and clears neither cooldown store.

Actions and owners:

| Action | Owner | State |
|---|---|---|
| Login completion: drop cached usage, clear both cooldown stores, report done only when the auth file is visible; replay test | H-core `21b1bfca-fc38-4d05-8896-94f733e7baf2` (nippur) | dispatched 13:50 |
| Cooldown clear clears every store; health GET reports real remaining time | H-core | queued behind the above |
| Core reads sidecar `/v0/management/auth-files` cooldowns, shows "parked until …, reason", admin clear | H-core | API shape to be proposed first |
| CLIProxyAPI: 429 without a 7-day `rejected` status uses the short reset; model-scope quota must not park the credential | H-core, research only | options write-up; no third-party issue or PR without Thomas |
| Clients (desktop, iOS, Android) need no change beyond the Core fix | H `11a48ddf-fb0b-49b4-8c42-2bd95518b296` | check requested |
| Single-target `genius` chain hangs with no error | H-core | to be located and reported |

### CI: lean runners and docs-only pushes

- lean-ci App `5538046` is now installed on user `Th0rgal` (installation
  `181598910`, all repositories) with `administration: write`. The two
  "Waiting on Thomas" items for B are resolved, and the hosted-dispatcher
  bridge design is superseded.
- B successor `e14bb767-3a6e-4251-a078-97c2c70cdb4a` (static node uruk):
  repo-level JIT runner support in `lfglabs-dev/lean.ci` for user-owned repos,
  a deploy runbook for `leanci-ctrl`, Orb Linux jobs on `runs-on: lean-*`
  behind a repository variable with `ubuntu-latest` when unset, then measured
  wall time. Brief requires an explicit decision on which repositories and
  events may obtain a runner (public repo, fork PRs, all-repos installation).
- `BOOST_CI_SSH_PRIVATE_KEY` granted to the coordinator at 13:48; kept on
  nimrud. `leanci-ctrl` deploy is done by the coordinator after review, not by
  the worker.
- Docs-only pushes: `0dea70c8` (Thomas) added `paths-ignore: ['docs/**']` to
  `ci.yml` and `kernel-abi.yml`. `'**/*.md'` is not yet covered; assigned to
  the B successor. At 13:47 CI run `43434265856` on `0dea70c8` was in progress;
  every earlier master run since 12:04 was cancelled.
- Live at 13:47: prod and dev both report build `7a9dfa936`.

### A decision 13:47 UTC: IO-extern admission rejected as written

Independent read-only review `41a10629-d3f7-4aa8-9158-894681f38399` returned
**not acceptable as is**. Findings are source-derived; the reviewer executed
no fixture.

- Canonical-name forgery: the matcher checks the name `IO` inside the
  inspected environment. A `prelude` module that defines
  `def IO (α : Type) : Type := α` can make a pure extern pass as an IO extern.
  This is a pure-extern policy bypass candidate, not a demonstrated false
  theorem.
- A terminal `IO` type does not show the foreign code stays out of the
  verifier process: initializers and elaboration can run it.
- `IO` is not a barrier to pure consumers: an action can be applied to a
  world token and its result constructors inspected.
- The existing fixtures test declarations next to an admitted opaque, not
  axioms or `sorry` inside the admitted opaque itself.

Conditions for approval: attest canonical `IO` with pinned import provenance;
show dependency and replay coverage for admitted opaques; an explicit
runtime-reachability contract or per-symbol trust approval; independent
execution of the missing adversarial fixtures. Consequence: no upstream
turbo-lean commit and no pin bump from this patch. OrbBin `PosixExt` (24
externs) and Core `ConformanceRunner` (about 186) stay rejected by the audit,
so the fail-closed build script cannot land on its own. Next step for A is a
design choice between an explicit pinned per-symbol allowlist (the existing
`--ffi-allow` mechanism) and the attested admission above; not yet assigned.

### A status 13:40 UTC: audit patch on security hold, lean.ci successor failed

- **lean.ci successor failed.** Mission `d76cd199-448d-44ad-ab2b-afff1011c0f1`
  on `leanci:2xlarge` exited 127 twice before the harness produced any model
  turn. Cause not established: a diagnostic workspace job returned `completed`
  with no output. VM `f322ed0f-7ea3-4b5f-8cf2-154d17bc3622` destroyed; $0.80
  committed, no build ran, no memory figure obtained.
- **Static-node measurement started.** Read-only mission
  `7de6fc9b-30b2-453e-9e44-dc8553cd0e0a` placed on `lagash` by the fleet
  scheduler: report effective cgroup limits first, then one `orb-core` build on
  unmodified master with wall time, peak RSS and major faults. No source edits.
- **turbo-lean IO-extern admission is on HOLD**, raised by the A worker itself.
  The matcher is a syntactic `.const ``IO` check: no attestation of the canonical
  IO definition, no tampered-canonical fixture, aliases rejected rather than
  normalized. Independent read-only review `41a10629-d3f7-4aa8-9158-894681f38399`
  is running with the expanded patch. No upstream commit, no pin bump, no merge
  until it returns.
- **Fail-closed build script is separable but not landable yet.** Independent
  read of `orb.patch` (applies on `2fe03910`): fallback and `ORB_SKIP_TURBO_LEAN`
  bypass are removed. Open points sent to A: preflight runs after the
  `--ensure-lean` toolchain bootstrap; staging checks only that a binary exists,
  not that this run built it; no regression test. Landing blocker: `ci.yml`,
  `kernel-abi.yml`, `Dockerfile` and `scripts/managed_image.py` have no
  compatible `turbo-lean` on PATH, and `nix/turbo-lean.nix` pins `f240450a`
  while `lean/turbo-lean-revision` says `29d85f7d`. Merging the script alone
  would turn those callers red.
- **Worker-reported, not reproduced here:** nine OrbBin binaries 77.28 s,
  OrbLocald 159.54 s, OrbNode 111.03 s, all with the held candidate turbo-lean;
  kernel audit suite 20 tests. Core has no passing build on any track.
- Harvested on nimrud, hashes verified: `track-a-checkpoint.tar.gz`
  (`c0b87da1…`), `track-a-interface-checkpoint.tar.gz` (`0392ed25…`),
  `track-a-security-hold.tar.gz` (`51920dcf…`), under
  `/var/lib/sandboxed-node/uploads/{cf816647…,77b3639f…,a85d0885…}/`.
- Old A (`35cd3390…`, VM `0f88c8f6…`, expires 15:12:52Z) keeps the script and
  its new test only; the turbo-lean patch and ConformanceRunner are frozen.

### Operator decisions: A replacement and H terminal-state replay

Operator declines managed-VM hand cgroup retuning; the older intervention
request below is **superseded, do not execute**. A successor launched with
requested/effective `opencode` / `builtin/smart` on catalog-confirmed
`leanci:2xlarge` (32 vCPU, 96 GiB RAM, 200 GB disk, $0.40/hour), initial TTL
120 minutes. Mission `d76cd199-448d-44ad-ab2b-afff1011c0f1`, managed VM
`f322ed0f-7ea3-4b5f-8cf2-154d17bc3622`. Preparation only: verify actual effective
job/ancestor memory allowance >=12 GiB and free disk before one heavy build.
Old A asked to freeze writes/export both patches immediately; no overlapping
source changes or old-VM destruction before verified harvest/handoff. Node
receipt did not provide expiry; verify provider state/TTL on next inspection.

H owns new cross-client terminal-state bug, spec and replay first: mission
`734c3bb7` completed on Core since 12:10, no remote_job, queue or continuation,
but desktop retains sendable queued steer, optimistic stop bubble, launch line
and Reconnecting chip (`missionLaunch.tsx:306`). Replay repeated steer at
11:48/11:55/12:00 during 429 chain; job `36cf3c7d` cancelled 11:55, fork
`b6934223`, prod restarts 12:07/12:19, other-session completion. Find canonical
merge retaining stale remote job/status. Terminal authoritative state must clear
stale launch/job/pending bubble; undelivered queued follow-up cannot remain
silently sendable (mark not sent or reconcile with delivery evidence). Desktop,
iOS and Android share semantics/fixtures; delayed terminal snapshots must not
kill genuinely newer turns. H owns client mission-status merge/spec/test paths;
C retains managed controls, D streaming, E principal/account security.

E+G dev grant request submitted by operator:
`f0eadef4-2978-46c7-82ae-5a6a7dd40ec2`, pending Thomas approval, not yet access.
E+G notified. Operator dev deploy of `9e33099d4` started 13:16 UTC; no duplicate
promotion or full deployed-SHA verification claimed.

### Immediate A memory-cap intervention (superseded)

A mission `35cd3390-5a58-4cd7-8444-172a84d5faa8`, VM
`0f88c8f6-084e-46a3-89ad-29aa52d300de`: reported effective
`memory.max=4471676928` despite 16 GiB VM. ProviderUsageAndLogin attempts
8m26 and 30m55 exhausted module deadlines, with 607 GB reads / 2.44 million
major faults / zero swap: incomplete production build, not compiler failure.
Worker instructed not to repeat until resources fixed; collecting read-only
PID/cgroup/ancestor limits and active-job evidence.

**Operator request, no deployment:** identify the actual remote build execution
systemd scope (job/execution UUID, not mission UUID); verify no competing heavy
jobs and enough VM/ancestor headroom; retune only that authorized scope to
`MemoryMax=12884901888`, `MemoryHigh=11596411692`, keeping zero swap and existing
CPU policy. Confirm actual cgroup max/high and ancestor limits before A retries.
Use authorized operator host effects, not worker self-modification. Current
Lean source has no workspace resource-retune endpoint. Runner.lean:801 derives
80% host RAM divided by normal+side capacity; :895 applies per-job properties.
For subsequent scopes, operator may consider node-wide
`SANDBOXED_NODE_JOB_MEMORY_BYTES=12884901888` only with exclusive concurrency
policy and controlled provisioning; do not silently grant all jobs 12 GiB.
If scope retune cannot be authorized, preserve artifacts and re-place with a
verified per-job allowance, not merely a larger advertised VM.

A reports IO audit 19/19 remains GREEN; fail-closed build-script fallback removal
has bash syntax/whitespace checks only. Request harvest now for independent
bounded script review; full Core acceptance and ConformanceRunner boundary
remain open. Source coordination does not permit blanket pure extern admission.

No new deployment requested yet. Future entries must give an exact SHA, dev or
prod target, verification command and result; do not repeat an in-flight deploy.

### Current integration and B source contract — supersedes earlier blockers

GitHub broker access granted on trusted nimrud; authenticated as Th0rgal.
Operator relay merged diagnostic as #1724; duplicate #1725 closed without
branch deletion. Local master fast-forwarded to `c49c64df`, including operator
per-key env policy `b1320c6f` and account-switch fix `84b74c3e`. Coordinator reran
`python3 -m unittest scripts.test_orb_env scripts.test_dev_user_isolation`:
22/22 pass; relevant Python compilation passes. This is not full G acceptance.
`ready/e-env-classification-report` remains preserved. Local master stays docs
only; finished code uses ready branches and operator relay remains fallback.

Private `lfglabs-dev/lean.ci` cloned on trusted nimrud at
`71f71f3fc69fc7f9ed3ce2cd37cd6638abc89c03`. Credential-free source archive:
`/tmp/opencode/leanci-source.tar.gz`, SHA-256
`1d7703677f6f86efe7e9ba275b5511e138a92ea6c818d76bdcb1e9f7e8c22479`.
**Operator request:** relay this archive to B VM
`f9444f29-2b15-49f4-ad81-37346c0844e5` work directory and return destination;
our exposed tools have harvest-out but no confirmed existing-mission upload.
No token/key in the archive (git archive of tracked source).

Source contract review sent to B: VM APIs reject OIDC JWT; OIDC works directly
only on prebuild/base APIs. No VM-token exchange found. Prebuild compiles Lean
exports, not arbitrary shell CI. VM exec supports JSON/SSE output and terminal
exit, files capped 32 MiB, exec capped 600 seconds. Idempotency is in-memory
15 minutes and SSE bypasses it; no TTL-extension/resume/log-poll endpoint found.
Do not implement guessed auth, durable-exactly-once claims or misuse prebuild as
general dispatcher. Workspace VM API credential remains Core-reserved after
operator-requested retry; use governed integration or reviewed upstream scoped
auth support, never raw provider key extraction. Host SSH key approval remains
pending after retry. Boat/Colab secrets not requested: no need outside Core.

E+G dev grant request tool remains absent; operator admin submission required:
`POST /api/privilege-access/request`, body mission id
`6fa970f7-8799-4c80-a312-f7884efc21f4`, scope `dev_operator`, target_host `dev`,
ttl_minutes 240, session_scoped true. Submission/approval not yet established.

### E+G operational checkpoint and coordinator probes

E+G has no dev-operator grant ID or privileged-access request tool on its managed
VM; host config inspection and deployment therefore remain operator work, not
an SSH workaround. No deployment/restart performed. Operator requests:

| Request | Target / SHA | Verification / status |
| --- | --- | --- |
| Provide complete 65 prod-only environment key names, never values | Current dev/prod inventory; no deployment | Confirm names-only inventory covers 116 prod / 61 dev keys; needed for checked-in classification, unknown keys fail closed |
| Supply governed dev access for full G member tests, or execute exact endpoint tests on behalf of E+G | Current dev, observed short build `de3fd0fa1`; resolve full SHA before any deploy | Grant ID scoped to mission if supported, otherwise sanitized HTTP status/schema evidence; no member password or bearer on managed VM |

Coordinator independently probed both public `/api/health` endpoints: status ok,
build `de3fd0fa1`; dev `multi_user`, legacy Library SSH remote; prod
`single_tenant`, canonical HTTPS Library remote. E+G's observed `f6961606a` is
a discrepant observation, not a verified deployment transition. Full deployed
SHA remains unverified. No change requested on partial short SHA.

E+G reports environment CLI names-only classification and explicit
`--share-one-sided KEY` red-to-green, 15 tests; broader Python ops 30 tests pass,
4 sealing CLI tests skipped for absent binary. These are worker reports, not
acceptance: explicit checked-in `shared` / `instance-owned` / `prod-only-allowed`
classification remains required; arbitrary CLI sharing is insufficient.
Prescribed and direct supported turbo builds time out, no full build pass.
Correction: VM has existing Xorg/Openbox processes; this harness lacks DISPLAY
attachment and GTK3/WebKit development packages for linux_shell. No real Orb
shell test has run. E+G to inspect authorized local display attachment and
VM-local build dependencies, not substitute browser-only or fabricated evidence.

E+G checkpoint preserved on trusted nimrud:
`/var/lib/sandboxed-node/uploads/1df8648c-344f-4fac-9312-586b25877710/eg-orb-env-one-sided-classification.patch`,
9,329 bytes, SHA-256
`bb3e21f8d64038095dfb90cc32befffa18b716ad6dc42e40ee365e162322235b`.
Source review: changes ops documentation, `scripts/ops/orb-env` and its tests;
no integration. Current `split_envs` permits arbitrary one-sided keys into shared
base and cannot preserve prod-only authority outside existing INSTANCE_KEYS.
It does not satisfy declared classification acceptance: require explicit
checked-in per-key policy, retained prod-only/instance overlays, unknown-key
rejection and no CLI bypass of protected authority. Revision requested with
regressions for Hermes/console SSH/node tokens and forbidden sharing. Worker
commit/PR identity absence does not block harvesting; base SHA still requested.

Fetched master `36b4205ab94bd8a97cb9a1b9058672640b2ee11b`: contains
`OrbBin/SelfTest.lean:1010` syntax repair for historical master Test failure.
This explains that Test failure only; browser failures and current CI still
need their own evidence. Operator ledger/inventory below retained verbatim.
E+G to supply exact multi-user dev configuration and checked-in environment-key
classification before operator application. No hand-edited production env.

### Operator update — 13 Nov, after 12:18 UTC

- Operator reports dev at `de3fd0fa1`, self-test 11/10/101 green and healthy at
  12:18 UTC; prod deployment is underway, not yet confirmed complete. These are
  operator reports, not independent coordinator live verification.
- Environment migration is not applied: 65 prod-only, 10 dev-only, 11 differing
  keys. Await operator's pushed key-name inventory; E owns explicit checked-in
  classification (`shared`, `instance-owned`, `prod-only-allowed`).
- Dev is currently `auth_mode: single_tenant`; G requires operator-applied
  multi-user configuration before its isolation acceptance can run.
- Operator reports parity/Boat/provider completed with handoffs on master
  (`a34d76da8`, `566dd2d62`, `de3fd0fa1`). Dev/prod mission `9382ef4d` still
  writing handoff: cancellation must wait for its published commit.
- Trusted nimrud integrator is authorized to retrieve `GITHUB_TOKEN`, use it
  only via local private file/process environment for gh and HTTPS Git, and
  set the documented development author identity. Signing unavailable: unsigned
  publication explicitly permitted with disclosure. No credentials to managed VMs.
- Broker retrieval of `GITHUB_TOKEN` is **pending**, request
  `e0a36684-bd02-4c3b-ba9e-7253bf56eb23`; no usable secret path delivered yet.
  Workers continue local checks and produce harvestable patch/bundle artifacts.
- Documented local author identity configured under the operator's explicit
  exception. Roadmap committed as `0b8b09b8`, unsigned (no signing material
  provisioned); push not yet performed. Repeated named-secret retrieval still
  returned pending, latest request `8487270d-d454-4efa-9fdd-73428faffd8f`.
  Do not infer credential delivery or GitHub publication from the local commit.
### Original operator request ledger

Missions cannot SSH to agent-core. Append here: exact SHA, dev or prod, and the
verification command. The operator session runs them and records the result.

| When (UTC) | Request | Result |
| --- | --- | --- |
| 13 Nov 12:09 | deploy master `de3fd0fa1` to dev | done 12:18, self-test 11/10/101, dev healthy |
| 13 Nov 12:19 | deploy `de3fd0fa1` to prod | started 12:19 |

### Env migration inventory (names only, 13 Nov)

`orb-env migrate` refuses: prod has 116 keys, dev 61.
- Differ: `BROWSER_ENABLED`, `DASHBOARD_PASSWORD`, `DEFAULT_MODEL`, `JWT_SECRET`, `PORT`, `SANDBOXED_MANAGED_REAPER_DRY_RUN`, `SANDBOXED_PUBLIC_URL`, `SANDBOXED_REMOTE_NODES`, `SANDBOXED_REMOTE_NODE_SEPOLIA_TOKEN`, `SANDBOXED_SH_OPENCODE_DEFAULT_MODEL`, `SANDBOXED_SINGLE_TENANT_USER_ID`.
- Dev-only: `AUTOMATION_MANAGER_MCP_BIN`, `CODEX_APP_SERVER_MODE`, `LIBRARY_PATH`, `OPENAGENT_DATA_DIR`, `RUST_MIN_STACK`, `SANDBOXED_MANAGED_ENABLED`, `SANDBOXED_PROXY_SECRET`, `SANDBOXED_SH_RTK_ENABLED`, `SCOPE_REAPER_ENABLED`, `WORKING_DIR`.
- Prod-only (65): Hermes (`HERMES_*`), console SSH (`CONSOLE_SSH_*`), browser, disk admission/alerts (`DISK_*`, `MISSION_DISK_*`), mission CPU caps, managed-compute tuning (`SANDBOXED_MANAGED_*`), node tokens for dgx-spark-admin/lagash/nimrud, Supabase, Spark arbiter, Tavily, AMP, Boat, CLIProxy management, workspace GC, container tmp, and others. Several must stay prod-only (Hermes authority, console SSH, node tokens); the tool needs a declared classification rather than failing on every one-sided key.

## Decision log

| When (UTC) | Decision | Why |
| --- | --- | --- |
| 13 Nov 11:44 | Merged #1721 (web search dialog in native chrome) without waiting for CI | Thomas's explicit instruction |
| 13 Nov 12:03–12:06 | Merged #1711, #1717, #1720 without waiting for remaining checks | "No need to wait for CI initially"; each had a passing local CI-parity build + self-test; #1711 was fully green |
| 13 Nov 12:07 | Asked the four old missions for a final handoff commit, then close them | One orchestrator instead of four missions sharing one build slot |
| 13 Nov | #1708 kept open, assigned to track A/B rather than closed | It is the base of the CI work; its failure is the turbo-lean audit rejection |
| 13 Nov 12:05 | Genius chain changed from `[anthropic/claude-fable-5-2]` to `[anthropic/claude-fable-5-2, openai/gpt-6.1-sol, antigravity/claude-opus-5-5-high, google/gemini-4-carbon-eap]` on prod | Thomas asked that the Genius fallback chain work; its only target has been refused since 03:45 UTC (Claude credential parked for quota in CLIProxyAPI) |
| 13 Nov 12:08 | Cancelled the stuck turns of ldgr (`b6934223`) and Pareto (`8a349331`) and re-sent Thomas's last question with "answer once, no wake-ups, no children, stop" | He wants the answer and to continue manually |
| 13 Nov 12:10 | Orchestrator runs on opencode with the `genius` chain instead of Claude Code + Fable | Claude Code needs Anthropic, which is refused until the quota resets or Thomas signs in again; `genius` returns to Fable by itself when it recovers |
| 13 Nov 12:10 | CLIProxyAPI not restarted to clear the parked Claude credential | It would cut the streams of ~20 running missions, and the quota park is probably real |
| 13 Nov 12:14 | Use six isolated Boat large workers, requested/effective opencode builtin/smart | Latest explicit instruction allows six writers; separate VM per build; no Anthropic selection |
| 13 Nov 12:14 | E+G is the only deploy executor; C/D/H request live checks through it | Avoid simultaneous orb-deploy and duplicate dev/prod operations; inspect live state first |
| 13 Nov 12:14 | Assign orb-env one-sided-key handling to E rather than H | E owns environment migration, preventing a second writer on the same script |
| 13 Nov 12:14 | Keep A build-script/pin ownership separate from B workflow ownership, and B.1 dependent on A | Avoid landing no-fallback CI before the soundness root fix works |
| 13 Nov 12:14 | Use section-local changes in shared Control/Proxy modules and exact-revision review before acceptance | Six tracks cannot have disjoint files throughout this backend; broad rewrites would conflict |
| 13 Nov 12:14 | Record credential and runtime-grant gaps as blocked; do not change Git config, fabricate signatures, or extract fleet/provider credentials | Explicit autonomy is not evidence of provisioned operational access; preserve security boundaries |
| 13 Nov 12:14 | Start independent read-only scope review using reachable builtin/smart and record degraded quorum | Anthropic unavailable; no independent family execution has been established |
| 13 Nov 12:14 | Request old parity cancellation after confirming its handoff on master; retain wake-up/health verification as open | Read ACL refused but cancellation accepted; an action receipt alone does not prove complete cleanup |
| 13 Nov, A transport update | A continues public HTTPS clone/build, preserving local commits or a harvestable git bundle; publication remains blocked | Worker independently confirms SSH host-key verification failure, no gh auth or provisioned Git transport; do not disable host-key checking or introduce credentials |
| 13 Nov, D transport update | D continues local RUN-07/RUN-05 transport implementation, preserving a bundle before 15:12:52Z expiry | HTTPS clone succeeds but SSH host verification and gh auth fail; keep H account/error sections untouched and retain publication as blocked |
| 13 Nov, C coordination update | Route C live rental/UI checks and Mac validation request through E+G; keep native iOS verification pending | One deployment owner prevents overlapping promotions; no sanctioned live access or Mac validation slot established yet |
| 13 Nov, H coordination update | Ask E+G for sanitized parked-quota schema and exact-SHA health/dispatch/startup-error evidence; cooldown-clear mutations restricted to test-owned fixtures | Verify H's source findings without restarting CLIProxyAPI or un-parking a real exhausted credential; H transport and orb-env exclusions preserved |
| 13 Nov, B provisioning update | Keep lean.ci runner routing opt-in with Ubuntu default/fork fallback; report private upstream and authenticated runner checks as blocked | B independently lacks GitHub/signing identity and cannot clone private lean.ci; routing tests do not establish runner/cache/warm-base operation; B.1 remains dependent on A |
| 13 Nov, operator unblocking update | Centralize bundle integration/publication on trusted nimrud, request GITHUB_TOKEN through broker, permit documented author config and disclosed unsigned commits if signing unavailable | Operator explicitly authorizes this exception; managed VMs intentionally remain credential-free; secret retrieval currently pending |
| 13 Nov, operator unblocking update | Route unavailable host effects through exact-SHA Operator requests instead of SSH; treat reported dev deploy as evidence and prod as in progress | Missions cannot SSH agent-core; prevent duplicate deployments and retain runtime-grant boundaries |
| 13 Nov, operator unblocking update | Implement checked-in environment-key classification before migration; request exact multi-user dev config through E+G | Existing migration refuses 65 prod-only/10 dev-only/11 different keys; do not hand-edit prod env or test multi-user claims on single-tenant dev |
| 13 Nov, operator unblocking update | Wait for dev/prod mission handoff commit before cancellation; prior three handoffs are reported complete | Preserve final delivery; completed report is not an independently verified wake-up cleanup receipt |
| 13 Nov, D build/interface update | Assign unsupported --no-telemetry and silent raw-Lake fallback repair to A; classify D baseline incomplete/non-turbo; notify H of optional forwardProxyChain sink | Avoid false turbo acceptance and duplicate script ownership; preserve account/classification behavior while D changes streaming transport |
| 13 Nov, operator B/G update | Replace immediate direct-runner plan with hosted lean.ci API-dispatch bridge, keep Ubuntu fallback; implement generic repo-JIT separately and list two web approvals | Operator verified App lacks Orb installation and repository administration; direct runner labels cannot work today, bridge must not wait for web clicks |
| 13 Nov, operator B/G update | Accept operator REST checks as scoped evidence only; assign provider-account redaction to E+G coordinated with H | Member account-email/id leakage is live-reproduced; REST first pass does not certify MCP, execution, sharing or desktop isolation |
| 13 Nov, operator B/G update | Record trusted-host-only lean.ci OIDC allowlisting through governed ops; no BOOST_CI_SSH_PRIVATE_KEY on managed guests | Operator authorizes lean.ci host administration, but broker delivery and verified target/host policy still required |
| 13 Nov, B checkpoint | Harvest B archive immediately, preserve baseline/tests, reject direct-runner changes as completion, request VM destruction | SHA/size match; operator API bridge supersedes prepared label routing; no native/live parity; destruction failed provider_http_error so cleanup remains open |
| 13 Nov, B public CI update | Record historical master red and current head pending separately; prioritize cause-specific CI repair, keep B.1 gated by A | Public API establishes failed Test/browser gates on a34d76da, not failure cause or current green status; baseline obtained in checkpoint, not yet independently recomputed |
| 13 Nov, A RED update | Require narrow generic IO-extern audit fix with adversarial negatives and independent review before acceptance; retain timed execution as evidence, not empty workspace-job completion | A reproduced 24 rejected IO opaques on upstream15676ea; name-based blanket admission could weaken soundness and is not an acceptable speed workaround |
| 13 Nov, B API bridge checkpoint | Do not publish superseded label-routing v2; preserve new bridge skeleton separately and wait for authoritative upstream auth/transport/base contracts before wiring | B removed direct labels, keeps hosted Ubuntu fallback; transport-neutral tests are not a live adapter; prevent guessed OIDC/prebuild schemas or ambiguous-create leaks |
| 13 Nov, B v3 harvest | Preserve hash-matched API scaffold v3 as current checkpoint; do not mark bridge complete | 32 tests are worker-reported, no HTTP/auth adapter or CI wiring exists; managed resource cleanup remains separately open |
| 13 Nov, A partial GREEN | Extend A ownership narrowly to ConformanceRunner runtime bindings/callers after sink/caller-cone review; preserve strict pure-extern rejection | Partial IO-extern success exposes pure foreign conformance boundary, which must be honest runtime-unsafe/IO rather than unsoundly admitted as safe proof code; full A remains open |
| 13 Nov, C regression update | Keep C acceptance open and route confirmed installed-tool flag mismatch to existing A repair | Initial regression RED and 280/299 timed-out fallback build are not passing gates; same defect corroborates D without duplicate script edits |
| 13 Nov 12:09 | ldgr answer taken from the original mission `734c3bb7`, not the fork `b6934223` | The fork's opencode session had no history and answered "no prior work visible" |
| 13 Nov 12:10 | ldgr's running children (`f1e3aa73` site, `819a0cd5` Bitcoin suites, `f711ad14`) left running | They are work Thomas asked for; cancelling would lose it. Their completion notes can still wake the parent |
| 13 Nov 12:12 | Env migration (dev/prod item 1) not applied | 86 key conflicts; hand-editing prod env under time pressure is the wrong risk. Fix the tool first |
| 13 Nov 12:19 | Deployed `de3fd0fa1` to dev, then prod | Thomas approved prod deploys; dev build + self-test were green |
| 13 Nov 12:20 | Orchestrator is the git integrator with `GITHUB_TOKEN` from the broker; worker VMs stay credential-free | Managed VMs have no GitHub identity, and workers refused to improvise one |
| 14 Nov 09:40 | Split member mission-on-managed-VM + WebSocket tchar fix across two disjoint `boat:large` workers (`8f53412f` for `OrbCore`+`orb/src`, `28a75b5a` for `OrbNode`), avoiding `Managed.lean` (#1766) | Each Lean build runs in its own isolated VM without touching files owned by open PR #1766 |
| 14 Nov 09:44 | Run all desktop/LeanUI rendering and pixel-diff work on managed VMs (headless Wayland + lavapipe); do not probe or tunnel to `m2air` | `lean-mesh` denies worker->laptop `:22` and fleet keys forbid forwarding by design; macOS shell, iOS/Android interactive walks, and credentialed `ben` desktop walks remain laptop-only until Thomas approves a route |
| 14 Nov 09:48 | Deleted dead `~/.ssh/orb_m2air_temp` and `.pub` on `nimrud`; wait for operator go-ahead before calling `request_macbook_tether` (`sandbox_ssh` default) | Operator directive: temporary SSH key is dead and laptop access will go exclusively through the MacBook tether broker |
| 14 Nov 10:05 | Respawned the two lost `boat:large` workers and relaunched Core (`18ab4b08`) and OrbNode (`d9a273d2`); published the per-user library spec and started a third worker | Both 09:40 workers vanished with their receipts; spec-first is required before the per-user library code |
| 14 Nov 10:05 | Per-user library design: owner checkout and `LIBRARY_PATH` unchanged; members get `{storeRoot}/library/users/<userId>` and their own `library.json`; admin steering a member mission installs the member's skills | Thomas's decision; keeps existing installs working while removing the owner-library leak |
| 14 Nov 10:10 | Filed operator items U1-U5 with no owner; U5 recorded as a closed access decision | Staff after multi-user and LeanUI; the node binary rollout stays with the deploy tool, not a per-mission script |
| 14 Nov 10:10 | Do not deploy #1766/#1767 or install node binaries on nimrud; the operator owns that rollout and will pause this mission | Duplicated deploys and a hand-installed `sandboxed-mcp` are exactly the U1 defect |
| 14 Nov 10:20 | Staffed CI speed track in parallel on 3 dedicated `boat:large` VMs: W-CI-1 (`b3b4bc79`), W-CI-2 (`2c14ec06`), W-CI-3 (`57fec405`) | Thomas directive: run CI speed in parallel with multi-user and LeanUI now (`$200/day` VM cap); report before/after timings from real runs |
