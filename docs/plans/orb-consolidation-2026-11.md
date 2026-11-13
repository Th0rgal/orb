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

### Immediate A memory-cap intervention

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
