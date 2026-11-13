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
- **Live finding:** member provider list exposes owner account-display emails
  and account IDs. E+G owns failing regression and member-safe type/toggle
  projection; H retains admin health/cooldown ownership. Full G remains open:
  MCP, create/run with managed placement/spend/proxy tokens, sharing, search,
  Inbox, files and real Linux desktop member login still unverified.

## Operator requests

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
