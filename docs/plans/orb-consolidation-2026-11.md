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
| A | `35cd3390-5a58-4cd7-8444-172a84d5faa8` | `0f88c8f6-084e-46a3-89ad-29aa52d300de` | Build script, turbo-lean pin/upstream soundness fix | Public HTTPS source/build proceeding; SSH clone fails host-key verification and gh has no auth; push/PR/merge blocked; full build not yet demonstrated |
| B | `36bddaa5-fcc4-4fbf-a78a-b717e1e198a7` | `f9444f29-2b15-49f4-ad81-37346c0844e5` | `.github/**`, `scripts/ci*`, `ci/**`, CI proposal; B.1 waits A | Active B.2 tested opt-in routing preparation, Ubuntu default/fork fallback and public 20-PR baseline; private lean.ci clone/auth runner checks and signed publication blocked by absent provisioned identity; B.1 waits A |
| C | `816f574f-6e85-4d3a-8123-8429f10e86b3` | `21fa6dec-b7d5-4b8a-9ab3-12f7a3218af4` | Managed REST/lifecycle sections and managed UI/models on desktop/iOS/Android | Active; regression-first REST extend, provider gating, ready/epoch contracts on three clients; live dev→prod and Mac validation depend on E+G; access/slot not established |
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

## Operator requests

No new deployment requested yet. Future entries must give an exact SHA, dev or
prod target, verification command and result; do not repeat an in-flight deploy.
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
