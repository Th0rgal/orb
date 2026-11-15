# Orb roadmap

One file, one master mission, one board. This file replaces
`orb-consolidation-2026-11.md`, `reliability-roadmap-2026-11.md` and the
handoff sections of the other plan documents in this folder; those become
history (`docs/archive/`) and are no longer edited.

- **This file** holds what does not change every hour: the definition of done,
  the rules, and the DAG of work.
- **The project board** (text board of project `orb`, written only by the
  master mission) holds what does: who is working on which node, PR links,
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
7. **One mission per roadmap.** Each roadmap (Orb, turbo-lean, evm.fast,
   Pareto) is one master mission with its own board; projects are only shelves
   (`Now`, `Later`, `Misc`), and the stale missions are archived.
8. Every node in section 4 is `done` or `dropped` with a reason.

## 2. How the master mission works

The master mission is the controller of project `orb`. It coordinates; it does
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
2. **Dispatch.** Every node whose dependencies are `done` and that has no live
   worker gets one, up to the worker limit. *A turn must not end while a ready
   node has no worker and a slot is free.* Finishing bookkeeping is not
   finishing the roadmap.
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
- At most 6 writers at once. Never two writers on the same files.
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
- Do not touch missions outside project `orb`, and never `evm.fast`.
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
| L3 | Node enrolment tries every resolved address (IPv4 when IPv6 has no route), public URL `orbcore.thomas.md` | — | wip (#1815) | Merged and deployed |
| L4 | Probe: a fresh `auto-managed:leanci:small` VM enrols and runs opencode, claude and codex turns | L3 | blocked | Three "reply OK" turns on one VM, VM destroyed |
| L5 | Prod `SANDBOXED_MANAGED_DEFAULT_PROVIDER=leanci` | L4 | blocked | Env changed through a deploy; a mission on `auto-managed` lands on lean.ci |
| L6 | Rollout doc and `build` script match reality: idle check, 100 GiB default, warm-repo trap, layered update, rollback | — | ready | A dry run following only the doc succeeds |
| L7 | Split the base image from warm project state with named snapshots | L5 | blocked (Thomas, 5.4) | — |
| L8 | Colab and lean.ci at Boat parity in the UI (list, start, stop, extend, destroy, cost) on desktop, iOS, Android | L5 | verify | Real rental through each client on dev then prod |

### C. CI on lean.ci Mode 2

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| C1 | Workflow routing behind `ORB_LEAN_RUNNERS` with hosted fallback (#1771), planner, tree reuse (#1772), turbo-lean cache (#1786) | — | done | — |
| C2 | Activation handoff documented (#1813) | — | done | — |
| C3 | `lfglabs-dev/lean.ci` #33 and #34 (user-repo JIT runners, runner fence): apply the four listed fixes, `cargo test` on the four crates, merge | — | ready | Both merged, SHAs recorded |
| C4 | Deploy lean.ci controller, engines and shim from C3 | C3 | blocked (operator, YubiKey, 5.2) | Deployed SHAs recorded |
| C5 | lean-ci GitHub App: Administration read/write, installed on `Th0rgal/orb` | — | blocked (Thomas, 5.1) | App installation visible |
| C6 | Set `ORB_LEAN_RUNNERS=true`; one master run green on lean.ci labels | C4, C5 | blocked | Run URL with lean labels on the jobs |
| C7 | Measure and record: web-only PR, warm Lean PR, cold full run | C6 | blocked | Three run URLs with timings; targets met or a node opened per miss |
| C8 | Every Orb binary builds through turbo-lean with no raw-Lake fallback, locally and in CI | — | verify | `scripts/build_orb_bins.sh` for all 12 binaries with the fallback variable unset |

### U. LeanUI

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| U1 | S1–S4 parity fixes and 36-variant report (#1805) | — | done | — |
| U2 | `lean/OrbDesktop` builds through turbo-lean (`srcDir ".."` rejected); edits under `lean/LeanUI` invalidate the cache | — | wip | `scripts/orb_desktop_dev.sh --native` works with no override |
| U3 | Every variant under 1% or a listed improvement with crops | U2 for the final measurement | wip | Table in `docs/ui/leanui-parity.md` regenerated by the documented commands |
| U4 | LeanUI as the default Linux desktop | U3 | blocked (Thomas, 5.5) | — |

Not on this roadmap: a macOS backend for LeanUI.

### M. Multi-user

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| M1 | Member accounts, per-user libraries, provider editing, redaction, project ownership (#1784, #1787, #1788, #1790, #1799, #1806) | — | done | — |
| M2 | `ben` exists on prod | — | done (Thomas, 15 Nov) | — |
| M3 | In-depth walk as `ben` on prod: REST and MCP isolation matrix (missions, projects, files, secrets, machines, settings, Inbox, search, providers) | — | ready | Scripted matrix checked in; zero leaks, or one node per leak |
| M4 | Same walk on a real desktop client in a Linux VM with a desktop session | M3 | blocked | Screenshots and the list of defects, each fixed with a test |
| M5 | Member missions run on lean.ci VMs by default, at most 2 machines per member, never the Core host | L5 | blocked | A mission started by `ben` with no placement lands on lean.ci |

### R. Core reliability (from the 12 Nov list and 15 Nov incident)

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| R1 | Skill bundle reaches the node outside `argv` (file or stdin); no reference is dropped | — | wip | Library over 128 KiB installs completely on a node |
| R2 | An exec failure on a node (E2BIG, ENOENT) is reported with its reason, not "exit 127" and an empty log | — | ready | Oversized command yields an error naming the cause |
| R3 | A turn with no assistant output is retried, then `failed` with a reason | — | verify | Forced empty reply on dev |
| R4 | Stall watchdog: a mission `active` with no job, or finished with live workers and no wake-up, is woken once and flagged | — | verify | Deliberately stalled test mission |
| R5 | Honest tool receipts: `action_outcome` matches the result (start, resume and cancel report "rejected" on success today) | — | ready | Receipts of the three calls say `succeeded` |
| R6 | A deploy does not kill running turns or lose their events (#1804 covers events) | — | verify | Deploy during a running turn: turn completes, no 502 |
| R7 | A 429 from a chain with one cooling target surfaces as a mission error within a minute | — | verify | Replay on dev |
| R8 | `health/:account/clear` clears both cooldown stores; provider status comes from request evidence | — | verify | Replay on dev |
| R9 | Controller closes out instead of dispatching: `start_mission` and the board make "ready node without worker" visible to the controller | — | ready | A controller tick lists ready nodes from the board |
| R10 | Rust → Lean parity queue (`rust-lean-parity-audit.md`), RUN-07 first; no new audit documents | — | verify | Ranked queue with each item `done` or a node here |

### S. One mission per roadmap, three projects

Today a board belongs to a project, so each roadmap needs its own project:
nine projects, 3,000 missions, and the four live roadmaps are hard to see.
Target: the roadmap **is** its master mission; a project is a shelf.

| Project | Holds |
| --- | --- |
| `Now` | master missions of the roadmaps being pushed (Orb, turbo-lean, evm.fast, Pareto) |
| `Later` | master missions of parked roadmaps; moved to `Now` when they matter again |
| `Misc` | one-off missions (today's `default`, `assistant`, `health-manager`, `minecraft`) |

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| S1 | Spec `docs/specs/mission-board.md`: the board belongs to a mission (one text, 16 KB, written only by that mission, read by its owner and the missions it started); a project page lists the boards of its missions; a mission keeps its board and its children when it changes project; existing project boards migrate to their controller mission | — | ready | Spec merged, with the event orders that must not lose a board |
| S2 | Core: mission board storage, `read_mission_board` / `write_mission_board` (the project tools stay as aliases onto the controller's board for one release), REST route, migration, tenant isolation tests | S1 | blocked | A member cannot read another user's board; migration keeps every existing board |
| S3 | Desktop: the mission page shows its board; the project page shows the boards of its missions in order; moving a master between projects keeps its workers nested under it | S2 | blocked | Browser test replays a move while a worker is running |
| S4 | iOS and Android: same as S3, shipped together with version bumps | S2 | blocked | Unit tests on both; same fixtures in `shared/orb-spec/` |
| S5 | Archive in bulk: REST and MCP call that archives missions by filter (project, status, older than), dry-run first, reversible | — | ready | Dry run prints the count; unarchive restores |
| S6 | Cost per mission is recorded (`total_cost_cents` is 0 on every mission today), so the model tiers above can be measured | — | ready | A turn on a priced model shows a non-zero cost; per-project total on the project page |
| S7 | Create `Now`, `Later`, `Misc`; move the Orb master into `Now`, its workers nested under it; fold `refining-loops` and `orb` away | S2, S3 | blocked | The Orb master writes its own board from `Now` |
| S8 | Archive stale missions: `interrupted`, `failed` or `awaiting_user`, untouched for 7 days, with no live child, in `default`, `verity-core`, `refining-loops` and unlabelled (about 700 on 15 Nov). Never an `active` mission, a master, or anything in `evm-fast`, `turbo-lean` or Pareto | S5 | blocked (Thomas, 5.8: confirm the dry-run count) | Count before and after on the board |
| S9 | Fold `default`, `assistant`, `health-manager`, `minecraft` into `Misc`; parked roadmaps (Verity, LeanVM, ldgr) get one mission each in `Later` | S7, S8 | blocked | Three projects left besides the ones in S10 |
| S10 | turbo-lean, evm.fast and Pareto move to the same shape: one master mission in `Now`, its own board, a guideline file in its repo, the model tiers above; Pareto goes from two controllers, a watchdog and a steward to one master. The Orb master writes the proposal for each; it does not touch their missions | S7 | blocked (Thomas, 5.9, per campaign) | Each campaign's session has the proposal; moved only on Thomas's word |
| S11 | One supervision check for all roadmaps: twice a day, reads the boards in `Now`, reports only changes; replaces the hourly Pareto check and the evm.fast check | S10 | blocked | One scheduled task left |
| S12 | Skills `controllers-policy` and `project-manager` and `docs/AGENT_CONTROL_PLANE.md` describe the mission board and the three projects | S2 | blocked | No mention of a project-owned board |

S2 is a milestone (authorization): it gets the independent review. Until S7,
the Orb master stays in project `orb`, which gives it a writable board.

### O. Operations

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| O1 | `orb-deploy` installs ops scripts with backup and rollback (#1811) | — | done | — |
| O2 | Env migration tooling and handoff (#1784, #1814) | — | done | — |
| O3 | Env migration applied on dev, verified | — | ready | Both startup checks pass on dev |
| O4 | Env migration applied on prod | O3 | blocked | Commands from the handoff run through a deploy; checks pass |
| O5 | One governed, checksummed rollout for `sandboxed-node`, `sandboxed-mcp`, `orb-privd` with cordon, drain and rollback, driven by the deploy tool | — | ready | Every node reports the deployed build; no hand copy |
| O6 | Dev deploys automatically on merge; prod stays deliberate | — | verify | A merge appears on dev with no human |
| O7 | Failed units on agent-core fixed or deleted (`sandboxed-worker-rolling-upgrade`, `sandboxed-harness-update`, `sandboxed-development-identity`) | — | verify | `systemctl --failed` shows no Orb unit |
| O8 | Retire `fleet-watcher`; monitor keeps only what Core cannot see about itself | R4 | blocked | — |
| O9 | Hermes cron scheduler on agent-core | — | verify (probably dropped: Hermes controllers removed by #1807) | Closed with a reason |
| O10 | Hindsight pages updated when a group closes | per group | ready | Page ids on the board |
| O11 | Old plan documents moved to `docs/archive/` with a pointer here | — | ready | One plan file left in `docs/plans/` besides audits still in use |

### X. Clients and smaller items

| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| X1 | Native Linux row menu: New cron, New folder, Rename, Archive | U4 decision may drop it | ready | — |
| X2 | macOS native sidebar "+" buttons | — | ready | — |
| X3 | Tether: lease revoked on every terminal transition; WAN endpoint chosen for remote fleet hosts | — | ready | Tests first |
| X4 | Plain `ethereumfoundation/glm-5.3` is rejected for our key (the flash variants work): fix the entry or remove it from the catalog | — | ready | A turn on it replies, or it is gone from the list |
| X5 | Tether end-to-end retest from a fleet node | 5.3 | blocked (Thomas) | SSH as `orb-tether` succeeds |
| X6 | Routing checks from 15 Nov still hold on prod: provider catalog complete, chain test endpoint authenticated, one "Weekly" row for ChatGPT | — | verify | Three checks against prod |

## 5. Waiting on Thomas

Only these. Each one names what it unblocks.

1. **lean-ci GitHub App**: approve Administration read/write and install it
   on `Th0rgal/orb` (unblocks C5, C6).
2. **YubiKey sessions for lean.ci hosts** when C4 is ready to deploy.
3. **`nh os switch`** on the laptop (unblocks X5).
4. **Go-ahead for named snapshots** on lean.ci (L7).
5. **LeanUI as default**, once U3 passes (U4).
6. **GitHub token on agent-core** is invalid, so library sync fails; replace
   it (library is updated by hand until then).
7. **A `service_deploy` grant for the master mission**, if the master is to
   deploy on its own; otherwise deploys wait for the operator session.
8. **Confirm the archive count** from the S8 dry run before anything is
   archived.
9. **Per campaign, say when** turbo-lean, evm.fast and Pareto may move to the
   one-master shape (S10).

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
| Canonical Core URL is `https://orbcore.thomas.md` | Thomas, 15 Nov |
| A roadmap is one master mission with its own board; projects are shelves: `Now`, `Later`, `Misc` | Thomas, 15 Nov |
| Master on `builtin/genius`, workers on `builtin/smart`, spawned sparingly; Astra then `gpt-6.1-sol` only after two failures | Thomas, 15 Nov |
| Workers push often; milestone PRs get an independent review; merges need no approval | Thomas, 15 Nov |
| Green before merge again (CI is fast enough since #1786) | this file |
| Managed VMs hold no credentials; the integrator pushes for them | 13 Nov |
