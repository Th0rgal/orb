# Orb roadmap

One file, one master mission, one board. This file replaces
`orb-consolidation-2026-11.md`, `reliability-roadmap-2026-11.md` and the
handoff sections of the other plan documents in this folder; those become
history (`docs/archive/`) and are no longer edited.

- **This file** holds what does not change every hour: the definition of done,
  the rules, and the DAG of work.
- **The mission board** of the master mission (written only by it; there is
  no project board any more) holds what does: who is working on which node,
  PR links,
  evidence, blockers, questions for Thomas.
- Nothing is appended here as a log. A status line that will be stale tomorrow
  belongs on the board. This file changes by PR, when a node is added, split,
  closed or re-ordered.

## 1. Done means

The roadmap is finished when every line below is true on production and has a
receipt (PR, deployed SHA, and the check that was run):

1. **Multi-user works.** A member (`ben`) can sign in on a real desktop client,
   run missions on a lean.ci VM, and can neither see nor act on anything of the
   admin's through REST, MCP or the client.
2. **lean.ci is the default managed provider**, with Boat as availability
   fallback, and a fresh lean.ci VM runs opencode, claude and codex missions.
3. **CI runs on lean.ci Mode 2** for master, with GitHub runners as fallback,
   and meets the targets: web-only PR < 5 min, warm Lean PR < 10 min, cold full
   run < 20 min. No Mode 1. `evm.fast` is never touched.
4. **LeanUI is at pixel parity**: every one of the 36 variants under 1%
   differing pixels, or a listed deliberate improvement with crops. It stays
   opt-in until Thomas decides otherwise.
5. **Core does not report success wrongly**, and deploys do not break running
   turns (section 4, group R).
6. **Operations are governed**: one deploy path for Core and node binaries, env
   migration applied on dev and prod, monitoring quiet.
7. Every node in section 4 is `done` or `dropped` with a reason.

## 2. How the work moves

**The master orchestrates; a timer keeps it awake.** The master mission
(`f5e86c78`, chain `genius`) starts every worker as its own child mission, on
track `roadmap-<row id>` (attempt n > 1: `roadmap-<row id>-<n>`), on ashur or
dgx-spark (the nodes with a checkout and the development identity), with a PR
title ending `(<row id>)`. `orb-roadmap-reconcile` (`scripts/ops`, a 5-minute
timer on the Core host, `ORB_ROADMAP_MASTER` set) is its heartbeat: it reads this
file from master, PRs and CI on GitHub and the roadmap missions in Core, and

- resumes the master with the exact rows to start whenever a queued row (section
  7) has its needs done and no live worker, or the master has been idle for an
  hour;
- resumes an idle worker once, then has the master replace it with the next
  model that is not cooling down (`openai/gpt-6.2-astra`, `openai/gpt-6.2-sol`,
  `anthropic/claude-fable-5-2`; DeepSeek was dropped on 18 Nov after it hung on three rows), then
  posts a decision request to the Inbox after two failed attempts;
- when master CI is red, asks only for the worker that fixes it.

A row is done when its state here says so or when a PR whose title ends with
`(<row id>)` has merged. Workers merge their own PR on green CI (rule M).
`orb-auto-deploy` (hourly timer on the Core host) deploys master to prod with
`orb-deploy` when its CI passed and prod is not on it yet. Install or update
both with `install -m 755 scripts/ops/<name> /usr/local/sbin/` and the units in
`deploy/systemd`. To change what runs next, edit the queue by PR.

### The master mission

The master mission is the controller; its workers run in project `now`
(project `orb` no longer exists). It coordinates; it does
not write feature code, run builds or read large logs itself.

**It runs until section 1 is true.** Closing the nodes that happen to be open
is not the end: after each group it re-reads section 4, turns every `verify`
node into `done` or a concrete node, and continues. It stops only on a stop
condition below or when Thomas says so.

**Each turn is a tick.** Read this file and the board, look at the live
missions and open PRs, take the actions below, rewrite the board, end the turn.
State lives on the board, not in the conversation.

1. **Reconcile.** For every node marked `wip`: is its worker alive, is its PR
   moving? A dead or silent worker (no event for 30 min, or the same command
   three times) is replaced, not waited for.
2. **Queue.** The reconciler dispatches queued rows; the master keeps the
   queue (section 7) short, ordered and free of rows a worker cannot finish.
3. **Verify.** A worker's report is not proof. Before marking a node `done`,
   check the merged SHA and the node's "done when" yourself or with a
   read-only reviewer from another model family.
4. **Deploy** what merged (rule D below).
5. **Write the board**: one line per open node (state, worker, PR, next
   check), then blockers, then questions for Thomas. Keep it under 16 KB.
6. **Wake up** on a child ending, or after at most 45 minutes. A tick that
   finds nothing changed ends silently.

**Tokens.** The master runs on `builtin/genius` and spends it on decisions
only. It never reads a diff, a build log or a transcript longer than a
worker's receipt; when it needs something read, it sends a worker. Workers are
spawned sparingly: one per ready node, none for work a node already has.

**Workers.** One worker per node, one branch, one PR.
- Model, cheapest that can do the node:
  - read-only checks, inventories, `verify` nodes, docs, small mechanical
    edits: `ethereumfoundation/deepseek-v4.1-flash`,
    `ethereumfoundation/glm-5.3-flash-uncensored`,
    `ethereumfoundation/qwen3.8-27b` or Grok 4.7;
  - implementation: `builtin/smart`;
  - a node that failed twice, or a milestone review: `openai/gpt-6-astra`,
    then `openai/gpt-6.1-sol`.
  The plain `ethereumfoundation/glm-5.3` is rejected for our key (node X4).
  Record requested and effective model.
- One writer per queued row; the queue is the only limit (Thomas, 17 Nov). Never two writers on the same files.
- Placement: spread them. No more than 2 Lean-building workers on one static
  node (8 cores each); use `auto-managed:<provider>:large` for the rest. Never
  `nimrud` (reserved), never the Core host. Destroy a VM when its worker ends,
  after its work is pushed.
- **Commit and push often.** A worker pushes its branch after every verified
  step and at least every 30 minutes of work, so a lost machine costs one
  step. Work that exists only on a worker's disk does not count as progress.
- Every worker prompt names: the node id, the goal, the "done when", the files
  it may touch, and the receipt format (at most 20 lines: PR, SHA, what was
  verified, what remains).

**Milestone review.** A milestone is the last node of a chain that changes
production behaviour: L5, C6, U3, M4, O4, O5, and any change to authorization,
secrets or deploy code. Before its PR merges, a second worker that did not
write it reviews the diff read-only (`writer: false`) against the node's "done
when" and `AGENTS.md`, and its findings are fixed. Other nodes merge on green
CI alone.

**Merge (rule M).** Green before merge: every CI check passed, none pending,
and the milestone review done where one applies. Then the worker merges its
own PR (squash) without asking. A red master is fixed before anything else is
merged.

**Deploy (rule D).** One deployer, one deploy at a time.
- Only `orb-deploy --detach <full sha>` (or the governed deploy endpoint with
  a `service_deploy` grant). Never a bare restart or a copied binary.
- Before starting, check that no deploy is running. Never start a rollback
  because a symptom appeared after a deploy without first finding the cause:
  on 15 Nov two rollbacks were deployed for a bug that neither contained.
- After every prod deploy, run one canary mission on a static node ("reply
  OK") and confirm `/api/health` reports the SHA. A failed canary is an
  incident: stop dispatching, find the cause, fix forward or roll back once.
- Batch merges: deploy at most once an hour unless a fix is urgent.

**Incidents.** Symptom, then evidence, then cause, then fix. Add a test that
replays the failure. Write the cause and the fix on the board in three lines.

**Limits that are not negotiable.**
- No secrets in output, repos or VMs. Managed VMs stay credential-free.
- Fleet SSH only through the governed paths; never a break-glass key.
- Do not touch missions the master did not start (project `orb` no longer
  exists), and never `evm.fast`.
- No `Co-Authored-By` or AI attribution in commits.
- Follow `AGENTS.md`: iOS and Android ship together with version bumps,
  specs before tricky fixes, one owner per piece of state.

**Ask Thomas only for what is in section 5.** Everything else is decided by
the master, written in section 6 by PR, and acted on.

**Stop conditions.** Pause dispatch and write the reason at the top of the
board when: prod is unhealthy, master is red for more than one tick, the
managed-VM daily budget is 80% spent, or three workers in a row fail on the
same node (then split or restate the node).

## 3. Reading the DAG

- **State**: `done`, `wip` (a worker or PR exists), `ready` (dependencies
  met), `blocked` (waiting on a node or on Thomas), `verify` (believed done or
  stale: the first task is a read-only check that either closes it or turns it
  into a concrete node).
- **Needs**: nodes that must be `done` first. Everything with no unmet need
  runs in parallel.
- States below are the snapshot at handover, 15 Nov 2026 21:00 UTC, prod on
  `c89371486`. The board is authoritative afterwards.

## 4. The DAG

### L. lean.ci as the managed provider

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| L1 | Agent tools and Lean on bare lean.ci guests (#1791, engine images layered) | — | done | — |
| L2 | lean.ci default in code with Boat fallback (#1793), park/resume, extend (#1798, #1802) | — | done | — |
| L3 | Node enrolment tries every resolved address (IPv4 when IPv6 has no route), public URL `orbcore.thomas.md` (owned by the mission "lean.ci: make a fresh VM enrol and run a turn") | — | done (#1815, 994ef16a) | Merged and deployed |
| L4 | Probe: a fresh `auto-managed:leanci:small` VM enrols and runs opencode, claude and codex turns (16 Nov 11:52Z, reported by the operator: `orb-managed-d2f8a3e7-66d` ready 8 s after spawn, three "reply OK" turns, destroyed; it needed #1853) | L3 | done | Three "reply OK" turns on one VM, VM destroyed |
| L5 | Prod uses lean.ci when a request names no provider. The code default is already `leanci` (`Managed.lean`, `defaultManagedProviderOf`), yet prod answers `default_provider: boat` (16 Nov), so the prod environment must set `SANDBOXED_MANAGED_DEFAULT_PROVIDER` (inferred, not read on the host); that name is not classified in `scripts/ops/orb-env`, which refuses unclassified keys | L4 | ready | Env changed through a deploy; `list_managed_machines` answers `default_provider: leanci`; a mission on `auto-managed` lands on lean.ci |
| L6 | Rollout doc and `build` script match reality: idle check, 100 GiB default, warm-repo trap, layered update, rollback | — | done (lean.ci #40, 705dfaf9) | A dry run following only the doc succeeds |
| L7 | Split the base image from warm project state with named snapshots | L5 | blocked | — |
| L8 | Colab and lean.ci at Boat parity in the UI (list, start, stop, extend, destroy, cost) on desktop, iOS, Android | L5 | verify | Real rental through each client on dev then prod |
| L9 | Enrolment diagnostics run as the node user. On 16 Nov every fresh lean.ci VM failed to enrol because the guest image has `/etc/resolv.conf` mode 0600 root:root and the node runs as `orbnode`; the deadline diagnostics (`guestDiagnosticCommand`) ran `curl` as root, printed `core_http=200` and hid it. The provision script now restores read access (#1853, 12951704) | — | done | The diagnostics print the mode of `/etc/resolv.conf` and a DNS and an HTTP result obtained as `orbnode`; tests by name |
| L10 | lean.ci engine images carry `/etc/resolv.conf` mode 0600 root:root since the image layering of 15 Nov; only the provision script works around it, and a deploy of a commit older than 12951704 removes the workaround | — | blocked (operator, engine sessions) | A guest booted from each engine image has a world-readable `/etc/resolv.conf` before the provision script runs |

### C. CI on lean.ci Mode 2

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| C1 | Workflow routing behind `ORB_LEAN_RUNNERS` with hosted fallback (#1771), planner, tree reuse (#1772), turbo-lean cache (#1786) | — | done | — |
| C2 | Activation handoff documented (#1813) | — | done | — |
| C3 | `lfglabs-dev/lean.ci` #33 and #34 (user-repo JIT runners, runner fence): apply the four listed fixes, `cargo test` on the four crates, merge | — | done (lean.ci #33 91292be3, #34 60089561) | Both merged, SHAs recorded |
| C4 | Deploy lean.ci controller, engines and shim from C3 | C3 | verify | Deployed SHAs recorded |
| C5 | lean-ci GitHub App: Administration read/write, installed on `Th0rgal/orb` | — | done (installation 181598910, reported by the operator 16 Nov) | App installation visible |
| C6 | Set `ORB_LEAN_RUNNERS=true`; one master run green on lean.ci labels | C4, C5, C9 | done | Run URL with lean labels on the jobs |
| C7 | Measure web-only PR, warm Lean PR and cold full CI (receipts below) | C6 | verify | Web and warm measured; full run missed even with some warm artifacts. C7c owns the fully cold confirmation. |
| C7a | Reduce the web PR critical path: inspect the 6m36s between the last browser shard and the start of CI OK | — | ready | A web-only PR builds and tests the changed web inputs and reaches CI OK in <5 min from run creation |
| C7b | Profile Docker (17m04s) and Test (15m02s) on a warm Lean PR; reduce both critical paths | — | ready | A Lean PR with a logged build-cache restore runs the affected tests and reaches CI OK in <10 min |
| C7c | Measure full CI with isolated empty project-build caches (including desktop binaries, web dist and Docker layers); separate runner wait from cold build time | — | ready | All planned jobs execute, logs establish cold project outputs without evicting shared caches, and CI OK finishes in <20 min |
| C8 | Every Orb binary builds through turbo-lean with no raw-Lake fallback, locally and in CI. **C8a:** `nix/package.nix:220-224` sets `ORB_SKIP_TURBO_LEAN` and `ORB_ALLOW_RAW_LAKE_FALLBACK`, and no workflow builds Nix. **C8b:** `scripts/build_orb_bins.sh:309-320` fails closed when turbo-lean is absent unless `ORB_ALLOW_RAW_LAKE_FALLBACK=1` (fixed in #1836) | — | ready | `scripts/build_orb_bins.sh` builds all 12 binaries with the fallback variable unset; the Nix build no longer needs either variable |
| C9 | The lean.ci runner image has the tools the workflows use. With `ORB_LEAN_RUNNERS=true` (16 Nov, 11:56Z to 12:29Z) the master runs of 12951704 failed on `lean-16vcpu-ubuntu-2604` and `lean-32vcpu-ubuntu-2604` runners: `cargo: command not found` in `setup-turbo-lean`, `docker: command not found` at job setup | — | ready | A master run on lean labels passes `setup-turbo-lean` and one job that needs docker |
| C8c | `scripts/ops/orb-deploy:73-74` builds prod with raw `lake build`: move the deploy host to turbo-lean, or record the deploy build as exempt from C8 | O5 | blocked (Thomas) | The deploy build runs through turbo-lean, or the exemption is written in section 6 |

**C7 timing receipts.** Wall clock for each `CI` workflow, attempt 1: GitHub run `created_at` to the `CI OK` job's `completed_at`, including queue time. Times below are UTC; parallel job durations are not added together.

| Sample | Start → CI OK | Scope and cache evidence | Target |
| --- | --- | --- | --- |
| [Web-only PR #1930](https://github.com/Th0rgal/orb/actions/runs/44278806268) | Nov 18 09:44:49 → 09:56:34 · **11m45s** | Only `orb/src/missionHierarchy.ts` and its unit test changed. [Orb build](https://github.com/Th0rgal/orb/actions/runs/44278806268/job/134714134890) restored modules, missed dist and ran Vite; unit and all eight browser shards passed. Lean Test was out of scope. | <5 min: miss → C7a |
| [Warm Lean PR #1945](https://github.com/Th0rgal/orb/actions/runs/44445622666) | Nov 19 02:37:03 → 02:54:46 · **17m43s** | Five `lean/OrbCore` files changed. [Test](https://github.com/Th0rgal/orb/actions/runs/44445622666/job/135297058362) on `lean-4vcpu-ubuntu-2604` restored the `lean-build-…-test` fallback key and logged OrbNetLeaf and OrbClient cache hits; Test and Docker both ran. | <10 min: miss → C7b |
| [Full master dispatch](https://github.com/Th0rgal/orb/actions/runs/44028707423) | Nov 17 06:05:59 → 07:15:10 · **69m11s** | All 21 jobs passed, including eight browser shards. Plan started after 39m42s. [Test](https://github.com/Th0rgal/orb/actions/runs/44028707423/job/133871230126) on `lean-32vcpu-ubuntu-2604`, Harness and Policy missed the Lean build cache; Test alone took 24m23s. Web dist missed, but Desktop restored binaries and Docker restored a Lean build cache. | <20 min: miss → C7c; mixed-cache full run, not a fully cold timing |

### U. LeanUI

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| U1 | S1–S4 parity fixes and 36-variant report (#1805) | — | done | — |
| U2 | `lean/OrbDesktop` builds through turbo-lean (`srcDir ".."` rejected); edits under `lean/LeanUI` invalidate the cache (#1822, 2c36e460; LeanUI parity run 43807502974 runs `scripts/orb_desktop_dev.sh --native` with both override variables unset) | — | done | — |
| U3 | Every variant under 1% or a listed improvement with crops (U2 is needed for the final measurement) | U2 | verify | Table in `docs/ui/leanui-parity.md` regenerated by the documented commands |
| U4 | LeanUI as the default Linux desktop: `orb dev`, the Alt+O launcher and the NixOS package start the LeanUI client; the GTK/WebKit client stays available behind a flag. Reverted 18 Nov: #1910 switched the default while LeanUI was only a renderer of the nine parity fixture screens (no Core data, no working input, slow, no blur); WebKit is the default again and LeanUI starts with `--leanui` | U5, U6, U7, U8 | blocked | Thomas uses LeanUI as his daily client for a day without falling back; then the default switches on Linux |
| U5 | LeanUI talks to Core: it reads `~/.orb/connection.json`, signs in with the existing token, loads the real projects, missions, transcripts, Inbox and machines, and stays live on the same event stream as the WebKit client (no fixture data outside `--screen` golden runs) | — | ready | Launched with no flags it shows Thomas's real projects and missions; a message sent from another client appears within a second; tests by name against a local Core |
| U6 | LeanUI input works end to end: pointer hit-testing on every control, scrolling with the shared scroll policy (`lean/Orb/Scroll.lean`), keyboard focus and shortcuts, text entry with IME, sending a message, Stop, archive, new mission, side panels | U5 | verify | A scripted session (Wayland input injection) creates a mission, sends a message, stops it and archives it; every control in the nine screens responds |
| U7 | LeanUI performance: damage-only redraws (only changed nodes), streamed text coalesced to one frame (`lean/Orb/Stream.lean`), frame-time budget measured in CI | U5 | wip | 60 fps while a long transcript streams on the m2air; startup and transcript-open times recorded in the PR and no worse than WebKit |
| U8 | LeanUI window effects at WebKit parity on Hyprland: transparency and background blur, rounded corners, the `orb-desktop` window class and vibrancy rule | — | verify | Side-by-side screenshots on Hyprland show the same blur and transparency as the WebKit client |

Not on this roadmap: a macOS backend for LeanUI.

### M. Multi-user

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| M1 | Member accounts, per-user libraries, provider editing, redaction, project ownership (#1784, #1787, #1788, #1790, #1799, #1806) | — | done | — |
| M2 | `ben` exists on prod | — | done (Thomas, 15 Nov) | — |
| M3 | In-depth walk as `ben` on prod: REST and MCP isolation matrix (missions, projects, files, secrets, machines, settings, Inbox, search, providers) | — | verify | Scripted matrix checked in; zero leaks, or one node per leak |
| M4 | Same walk on a real desktop client in a Linux VM with a desktop session | M3 | blocked | Screenshots and the list of defects, each fixed with a test |
| M5 | Member missions run on lean.ci VMs by default, at most 2 machines per member, never the Core host | L5 | blocked | A mission started by `ben` with no placement lands on lean.ci |

### R. Core reliability (from the 12 Nov list and 15 Nov incident)

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| R1 | Skill bundle reaches the node outside `argv` (file or stdin); no reference is dropped (#1819, d42e8469) | — | done | — |
| R2 | An exec failure on a node (E2BIG, ENOENT) is reported with its reason, not "exit 127" and an empty log (#1827, be0d66af) | — | verify | Every node reports a build containing be0d66af; an oversized command names its cause |
| R3 | A turn with no assistant output is retried, then `failed` with a reason | — | verify | Forced empty reply on dev |
| R4 | Stall watchdog: a mission `active` with no job, or finished with live workers and no wake-up, is woken once and flagged | — | verify | Deliberately stalled test mission |
| R5 | Honest tool receipts: `action_outcome` matches the result (start, resume and cancel report "rejected" on success today) (#1830, fb111cbf; start, resume and cancel receipts read `accepted` with `durable_success: true` on prod build 056018e36, 16 Nov 04:26 UTC) | — | done | — |
| R6 | A deploy does not kill running turns or lose their events (#1804 covers events) | — | verify | Deploy during a running turn: turn completes, no 502 |
| R7 | A 429 from a chain with one cooling target surfaces as a mission error within a minute | — | verify | Replay on dev |
| R8 | `health/:account/clear` clears both cooldown stores; provider status comes from request evidence | — | verify | Replay on dev |
| R9 | Controller closes out instead of dispatching: `start_mission` and the board make "ready node without worker" visible to the controller | — | done | A controller tick lists ready nodes from the board |
| R10 | [Rust → Lean parity queue](rust-lean-parity-audit.md). Stream relay landed (#1729, #1748, #1757); model-frame latency after #1908 belongs to R30. RUN-09: `WakeupRestartTests`. HTTP-06, HTTP-07: chain patch/get/delete in `Control.lean`, `ProxyRoutingTests`. FLT-01, FLT-02: `TenantIsolationTests`, `ManagedSnapshotLifecycleTests`. PROV01, PROV02, PROV03, PROV04, PROV05: status, Google/Muse/Kimi windows and numeric Codex resets (#1712, `ProviderContractTests`). SEC-05: pre-retrieval gate for managed-classified callers (`f3863239c`). MCP-08, MCP-09, MCP-11, MCP-12: structured board, steers, decisions and Hermes controller retired by #1807. | — | done | All 92 numbered IDs accounted for here or in R11–R18, R20–R23, R30 and O12 (88 comparative findings, two duplicate extensions, one packaging warning, one Lean-only finding). This closes queue coverage; open nodes retain their acceptance checks. |
| R11 | SEC-01: an approval lease is marked biometric-signed without a verified enrolled-device signature | — | done | A lease needs a valid request-bound P-256 signature; replay, bad-signature, wrong-body and expired cases are refused |
| R12 | SEC-02, HTTP-01, SEC-03: one principal resolver | #1839 | done | A legacy token with an unknown subject and a password the database rejected never yield a session |
| R13 | SEC-08: leases bound to a live mission and session at command time (X3 waits for it) | — | done | A lease whose mission or session ended before its TTL is refused at verification and reaping |
| R14 | FLT-13: raw exec on a managed machine never runs with a defaulted admin identity | — | done | Raw exec on a worker is refused or runs as its own Unix identity, never admin |
| R15 | MCP-05: a launch with `writer:false` runs read-only | — | done | `start_mission(writer:false)` yields a read-only launch or an explicit refusal |
| R16 | Tenant isolation residue: HTTP-14, MCP-13, SEC-04, MCP-14, FLT-03, FLT-09, FLT-15, FLT-16, SEC-07, SEC-11; with MCP-01 (and FLT-12, which dedupes to MCP-01/MCP-14) | — | ready | Two users and two unrelated same-user trees: no read, list, count, grant, lease or revocation crosses the boundary |
| R17 | Honest answers, no stub that reports success: HTTP-04, HTTP-05, HTTP-13, HTTP-15, HTTP-16, MCP-04, MCP-10, MCP-15, MCP-16, MCP-17, MCP-18, FLT-04, FLT-14, PROV08, SEC-06. MCP-02: scoped lookup landed; verify all/any waits and evidence-bound reconciliation. MCP-06: question/files and model are routed; raw result still returns mission detail. | — | verify | Each call performs its effect with a receipt or returns unsupported; test mixed pending/rejected receipts and refusal of unsupported reconciliation. Poll a consult before and after completion: `done` and the terminal answer match the child; refuse unsupported quorum. |
| R18 | Runtime liveness: FLT-05, FLT-06, FLT-07, FLT-08, RUN-01, RUN-02, RUN-03, RUN-05, RUN-06, RUN-08, RUN-10, RUN-11, RUN-12, MCP-03, MCP-07, FUP-01, FUP-02 | — | ready | A restart, partition, stale poller, blocked queue prefix or lost reply loses no owned work; SSE streams, WebSocket transports and queue delivery are live. In `migrateLegacyAutomations`, unsupported triggers stay intact rather than becoming one-shot timers; a failed continuation insert never retires the source. |
| R19 | Hung node: a node whose API stops answering while it answers ping is cordoned from placement, its missions are flagged once, and a resume names the node as the cause (lagash, 2026-11-16) | — | verify | Reproduced on dev: cordon, one flag, resume names the node |
| R20 | Data safety: HTTP-02, HTTP-03, HTTP-11, HTTP-12, HTTP-17, RUN-04 | — | done | Uploads round-trip exact bytes with a usable receipt, downloads keep their headers, a color change keeps title and status, retention stays opt-in |
| R21 | Provider usage truth: HTTP-08, HTTP-09, HTTP-10, PROV06, PROV07, PROV09, PROV10, PROV11, SEC-12 | — | verify | Usage, health, reliability and concurrency report observed caller-scoped values, never invented ones |
| R22 | Managed budget: FLT-10, FLT-11 | — | done | A mission pool and the dated global cap gate creation; an impossible single-VM fit is refused |
| R23 | Legacy state migration: SEC-09, SEC-10 | — | done | Existing bunker and telemetry state is migrated once, fail-closed, and survives restart |
| R24 | Receipts under failure: a lost node reply is answered `accepted: no` and retryable although the job may have run; enqueue, dispatch and cancel errors are discarded before a success receipt; a failed receipt insert is ignored, so two same-key calls can both mutate (post-merge review of #1830) | B2 | done | A lost reply, a failed enqueue and two concurrent same-key calls each give one truthful receipt; tests by name |
| R25 | A Core deploy refreshes the node binary served to managed guests, and the served build is visible. Core served guests a node binary of 14 Nov, older than #1815, through every deploy since; it was refreshed by hand on 16 Nov and was not the cause of the enrolment failures of that day (see L9). `orb-deploy` installs the node binary it built into a guest-serving path with backup and rollback, Core serves that path first and logs the sha256 it serves; then `/api/health` names the served node build | — | verify | A deploy without `--rollout-nodes` changes the served binary, test by name; a fresh lean.ci VM runs the deployed node build; `/api/health` shows the served node build |
| R26 | An account disabled by its provider is terminal, not a cooldown. A refusal that says the account itself is disabled (Google `403 PERMISSION_DENIED` with reason `TOS_VIOLATION`, and the equivalent account-ban answers of other providers where already distinguishable) parks the account with no automatic retry until an operator clears it; the classification is a kernel reason code in `lean/Orb/Kernel.lean` with its spec, not a special case in the proxy. The Providers card on desktop, iOS and Android shows "disabled by provider" with the provider's message, not "payment required" or a countdown. Disabling an OAuth-only provider row in Core also disables its matched sidecar auth file, and re-enabling restores it; sidecar auth files with no Core row are shown. Incident 14 to 16 Nov: five Antigravity logins were reported as `payment_required` with a 10 to 30 minute cooldown and retried about ten times an hour (556 refusals); they were disabled by hand on 16 Nov and stay disabled. One PR with tests | — | done | A replayed `403 TOS_VIOLATION` fixture leaves the account terminally parked with zero further upstream attempts; `GET /api/model-routing/health` and the three clients show the state; toggling a Core row changes the sidecar file's `disabled` flag in a test against a fake management endpoint; tests by name |
| R27 | Stream-cut truth. The proxy records a stream that ends without `finish_reason`, carries an error frame after `[DONE]` or any error frame after a 200, or exceeds the idle timeout as a failure (`stream_incomplete` / `idle_timeout`) in `proxy_outcomes`; `/api/ai/proxy/health`, provider health and the breaker (`orb_breaker_step`) count it, so a degrading provider gets a cooldown and the chain fails over. (Evidence 17 Nov, 48 h on `missions-prod.db`: `surplusintelligence/gemini-4-carbon` 11 cuts/timeouts over 1,463 = 7.5/1,000; `gemini-4-argon` 16 over 13,798 = 1.2/1,000; `glm-5.3-flash-uncensored` 1 over 3,630; `gpt-6-astra` 0/10,582; `deepseek-v4.1-flash` 0/5,335; `claude-fable-5-2` 0/2,371; 27 of 28 via `builtin/smart`, counted as HTTP 200 successes; Pareto `8a349331` died 8 times in 14 h) | — | done | Replay fixtures in `shared/orb-spec` (cut before content, cut mid-text, cut mid tool-call JSON, cut after a complete tool call, the observed `[DONE]` then error frame) each produce a failure outcome and a breaker step; health no longer reports them as ok; tests by name |
| R28 | Transient turn recovery. A mission turn that fails on `stream_incomplete` or `idle_timeout` is resumed automatically on the same mission, at most 2 times with backoff, with a visible `recovered` event, before being marked `failed` with the reason. Kernel-side classification with its spec (reason code), not a proxy special case; complements R3/R4 | — | verify | A forced cut on dev resumes the mission once and it completes; a third consecutive cut ends `failed` with the reason; tests by name |
| R29 | Cut-rate monitoring. `orb-monitor` reports per provider/model cuts per 1,000 requests and killed turns, from `mission_events` joined to `proxy_usage`, and alerts on a jump; the 48 h query becomes the standing check | R27 | done | The monitor output shows the rate and an injected spike alerts |
| R30 | Safe in-proxy recovery without breaking the sticky fence. Kernel (`lean/Orb/Kernel.lean`, `Spec.lean`, `audit-spec` clean) gains two endings: (a) cut before any complete tool call: retryable abort, the proxy retries the same provider first (warm cache), then the next chain target after a context-size check, stripping provider-bound reasoning (OpenAI encrypted reasoning, Anthropic signed thinking) when switching; (b) cut after one or more complete tool calls: close the stream cleanly at the end of the last complete tool call as a normal tool-call response and drop only the unfinished tail. Proved: two attempts are never mixed in one stream, a tool call is never delivered twice, abort only before a tool call completes | R27 | verify | The R27 fixtures pass end to end through opencode on dev with no killed turn and no duplicated tool call |
| R31 | Routing by turn length. After one week of R29 data: coordinator and long-running missions default to targets whose measured cut rate keeps a 200-request turn above 99% survival; short calls may keep `surplusintelligence`; reorder `builtin/smart` from the data | R29 (+ 7 days) | blocked | The chain change is merged with the data table in the PR |
| R32 | A provider login that needs signing in again is reported as one, not as "overloaded". On 17 Nov the ChatGPT login `thomas@lfglabs.dev` stopped refreshing at 07:02 UTC (`invalid_refresh_token`), the other OpenAI login was out of quota for 66 h and two more were disabled or expired; CLIProxyAPI answered 503 "auth unavailable", Core classified it as `overloaded`, parked both OpenAI accounts for an hour at a time and showed 100% quota, and every gpt-6-astra and gpt-6.1-sol worker died at start for twelve hours without anyone being told. Core reads the sidecar's per-login state (refresh failure, disabled, expired, quota with reset time) and: shows "sign in again" with the login's email on the Providers card on desktop, iOS and Android; names it in the mission error instead of "Provider is unavailable"; alerts through orb-monitor once when every login of a provider is unusable; and parks for the sidecar's reported reset, not a guessed hour. The classification is a kernel reason code with its spec | — | done | A fixture with one refresh-failed, one quota-exhausted and one disabled login yields "sign in again" for the provider on the three clients and in the mission error, one monitor alert, and a park until the reported reset; a fresh login clears it; tests by name |

**Remaining parity checks in the existing nodes:**

- **R30 — RUN-07:** `recoverBufferedStream` holds recognized model frames below the buffer cap until the upstream ends. `ProxyRoutingTests.runStreaming` measures unrecognized `n` frames. Repeat its delayed-frame test with actual `choices` deltas: the client must see content before upstream completion, and a later cut must never mix attempts or duplicate a tool call.
- **R16:** #1916 leaves workspace resource limits unresolved. Check that the authorized workspace can read, persist and apply its limits to a running job, or receives an explicit unsupported result. A cross-tenant refusal alone does not exercise this path.
- **R21:** #1932 covers caller-scoped observations. Exercise background usage upkeep, renewal after expiry and the configured Google account cap at request acquisition; provider DTO checks alone do not cover these three paths.

### B. A board per mission

Today a board belongs to a project, so two roadmaps that keep a board cannot
share a project. The board moves to the mission: one text, written only by
that mission, travelling with it when it changes project. Creating projects,
moving missions and archiving stay with the operator; this group is only the
code.

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| B1 | Spec `docs/specs/mission-board.md`: one text per mission, 16 KB, written only by that mission, readable by its owner and by the missions it started; a project page lists the boards of its missions; a mission keeps its board when it changes project; the existing project boards (`orb`, `evm-fast`) migrate to their controller mission; event orders that must never lose a board | — | done | Spec merged |
| B2 | Core: storage, `read_mission_board` / `write_mission_board`, REST route, migration; the project board tools keep working for one release as aliases onto the controller mission's board; tenant isolation tests | B1 | done | A member cannot read another user's board; both existing boards survive the migration byte for byte |
| B2b | Named tests for the 31 spec clauses left without one in the table of #1832 (listing order and fields, lifecycle replays, concurrent writers, both startup orders, the alias window) | B2 | done | Every row of the #1832 table names a passing test, or the spec line it came from is changed |
| B3 | Desktop: the mission page shows its board; the project page shows the boards of its missions | B2 | verify (#1842, c39c168f) | Browser test: write, move the mission to another project, board still there |
| B4 | iOS and Android, shipped together with version bumps | B2 | done | Unit tests on both, same fixtures in `shared/orb-spec/` |
| B5 | Moving a mission moves its whole family: `POST /api/control/missions/:id/project` relabels only the mission on prod, against `docs/ui/mission-moves.md` (found 15 Nov: Pareto's 154 workers stayed behind) (#1829 c7a72614, fixed by #1834 39ad8d87, on prod since build 2c36e4608) | — | verify | Moving a root with running workers moves every descendant in one call; test replays it; replay on prod not yet run |
| B5b | A crash between the `missions.db` commit and the `projects.db` rebinding of a family move still needs a retry of the move (review of #1834) | — | done | A crash injected between the two commits is repaired at startup without a retry; test by name |
| B6 | Skills `controllers-policy`, `project-manager` and `docs/AGENT_CONTROL_PLANE.md` describe the mission board | B2 | done (#1845, f27fbdde) | No mention of a project-owned board |

B2 is a milestone (authorization and a data migration): independent review
before merge. Do not move the Orb master or change any project; the operator
does that once B2 and B3 are deployed.

### O. Operations

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| O1 | `orb-deploy` installs ops scripts with backup and rollback (#1811) | — | done | — |
| O2 | Env migration tooling and handoff (#1784, #1814) | — | done | — |
| O3 | Env migration applied on dev, verified | — | ready | Both startup checks pass on dev |
| O4 | Env migration applied on prod | O3 | blocked | Commands from the handoff run through a deploy; checks pass |
| O5 | One governed, checksummed rollout for `sandboxed-node`, `sandboxed-mcp`, `orb-privd` with cordon, drain and rollback, driven by the deploy tool | — | verify | Every node reports the deployed build; no hand copy |
| O6 | Dev deploys automatically on merge; prod stays deliberate | — | verify | A merge appears on dev with no human |
| O7 | Failed units on agent-core fixed or deleted (`sandboxed-worker-rolling-upgrade`, `sandboxed-harness-update`, `sandboxed-development-identity`) | — | verify | `systemctl --failed` shows no Orb unit |
| O8 | Retire `fleet-watcher`; monitor keeps only what Core cannot see about itself | R4 | blocked | — |
| O9 | Hermes cron scheduler on agent-core | — | dropped (#1807 removed the Hermes controllers) | — |
| O10 | Hindsight pages updated when a group closes | per group | ready | Page ids on the board |
| O11 | Old plan documents moved to `docs/archive/` with a pointer here (#1828, 24012e6a) | — | done | — |
| O12 | Node configuration and packaging: OPS-01, OPS-02, OPS-03, OPS-04 | — | done | A newer env edit beats a stale override, all capacity fields load and reload, the env file reloads without a signal, and the privd unit runs the installed artifact |
| O13 | `orb-node-test` fails on the deploy host: the prod deploy of 3b5a35df (16 Nov 11:21Z) aborted with `failed parsing /jobs/:id/files JSON` while CI passes the same test; the test discards the status and body that would name the cause and waits 2.4 s for the job | — | done | The cause is named, or the test reports status, body and job state and waits on a deadline; a prod deploy of master passes the node test |

### X. Clients and smaller items

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| X1 | Native Linux row menu: New cron, New folder, Rename, Archive | U4 decision may drop it | ready | — |
| X2 | macOS native sidebar "+" buttons | — | done | — |
| X3 | Tether: lease revoked on every terminal transition; WAN endpoint chosen for remote fleet hosts | — | ready | Tests first |
| X4 | Plain `ethereumfoundation/glm-5.3` is rejected for our key (the flash variants work): fix the entry or remove it from the catalog | — | done | A turn on it replies, or it is gone from the list |
| X5 | Tether end-to-end retest from a fleet node | 5.3 | blocked (Thomas) | SSH as `orb-tether` succeeds |
| X6 | Routing checks from 15 Nov still hold on prod: provider catalog complete, chain test endpoint authenticated, one "Weekly" row for ChatGPT | — | verify | Three checks against prod |
| X7 | Remote `/goal` in the clients: the pure policy and event sync of #1877 drive a Goal mode for remote missions on desktop, iOS and Android (start, progress, Stop, truthful completion); harnesses Core cannot loop no longer offer Goal and show why; iOS and Android ship together with version bumps | — | wip | Browser test on desktop and unit tests on iOS and Android with the shared fixtures; Goal on an opencode remote mission continues until the objective is met or Stop |

## 5. Waiting on Thomas

Only these. Each one names what it unblocks.

1. **lean-ci GitHub App**: done 16 Nov (C5); C6 still waits on C4 and C9.
2. **YubiKey sessions for lean.ci hosts** when C4 is ready to deploy.
3. **`nh os switch`** on the laptop (unblocks X5).
4. **Go-ahead for named snapshots** on lean.ci (L7): given 16 Nov, behind L5.
5. **LeanUI as default**: approved 17 Nov, reverted 18 Nov until LeanUI is a working client (U5-U8); Thomas decides after using it (U4).
6. **GitHub token on agent-core** is invalid, so library sync fails; replace
   it (library is updated by hand until then).
7. **A `service_deploy` grant for the master mission**, if the master is to
   deploy on its own; otherwise deploys wait for the operator session.
8. **Which clients approve leases** (desktop, iOS, Android): all three sign,
   answered 16 Nov; SEC-01 verifies their enrolled-device signatures before
   issuing one (unblocks R11).

## 6. Decisions in force

| Decision | Source |
| --- | --- |
| Full autonomy to merge and deploy to prod; fix new bugs found on the way | Thomas, 13 and 15 Nov |
| CI is lean.ci Mode 2 only; never Mode 1; never touch `evm.fast` | Thomas, 14 Nov |
| lean.ci is the default provider, Boat only as fallback | Thomas, 14 Nov |
| Members: per-user library, at most 2 managed machines, never the Core host | Thomas, 14 Nov |
| LeanUI stays opt-in; bar is < 1% per screen or a listed improvement | Thomas, 14 Nov |
| Mobile ships on CI alone, iOS and Android together, with version bumps | Thomas, 14 Nov |
| Antigravity always uses `gemini-4-carbon`; `argon` only through Surplus Intelligence | Thomas, 15 Nov |
| The five Antigravity logins disabled on 16 Nov stay disabled; `antigravity` entries stay out of `builtin/smart`, `builtin/fast`, `genius` and `google-sonnet` (R26) | Thomas, 16 Nov |
| Canonical Core URL is `https://orbcore.thomas.md` | Thomas, 15 Nov |
| Master on `builtin/genius`; until R27 and R28 are deployed, workers that run long turns (implementation, integration, coordination) use `openai/gpt-6-astra`, and `builtin/smart` is used only for short read-only checks; spawned sparingly | Thomas, 17 Nov (replaces 15 Nov "workers on `builtin/smart`") |
| Roadmap workers start on the first model that is not cooling down, in order `openai/gpt-6.2-astra`, `openai/gpt-6.2-sol`, `anthropic/claude-fable-5-2`, `ethereumfoundation/deepseek-v4.1-flash` (DeepSeek last) (both of the first two were out of quota for most of 17 Nov afternoon) | Thomas, 17 Nov |
| Unattended overnight operation: `orb-auto-deploy` deploys green master to prod hourly; LeanUI becomes the default only after U5-U8 and Thomas's own trial (U4, reverted 18 Nov); workers may rent lean.ci or Boat VMs within the managed-VM daily cap | Thomas, 17 Nov |
| Workers push often; milestone PRs get an independent review; merges need no approval | Thomas, 15 Nov |
| Green before merge again (CI is fast enough since #1786) | this file |
| Managed VMs hold no credentials; the integrator pushes for them | 13 Nov |

## 7. Queue

Rows the reconciler dispatches, in order. A row leaves the queue by PR when it
is done or dropped.

`U5`, `U8`, `U6`, `U7`, `U3`, `X7`, `R30`, `M3`, `L5`, `R16`, `R17`, `R18`, `R19`, `R21`, `O3`, `O4`, `X3`, `C7`, `C8`, `R31`
