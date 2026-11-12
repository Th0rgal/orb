# Orb reliability roadmap (2026-11-12)

One list for everything that came out of the first day on the Lean Core
server. It merges the reliability fixes, the client work, clean redeploys and
host monitoring. Each row has one owner and a test that says it is done.

The pattern behind most of the day's failures: Core reported success when
something had gone wrong, and nothing noticed. Items are ordered so that the
"reports success wrongly" class goes first, then missing features.

## Status legend

`done` shipped and checked · `wip` someone is on it · `todo` not started

## A. Core: stop reporting success wrongly

| # | Item | Owner | State | Done when |
| --- | --- | --- | --- | --- |
| A1 | **Top priority.** One alias table for the model proxy (`smart`, `reviewer`, `MiniMax-M3`, `fable-5.2`, `github-copilot/claude-fable-5.2`, …), tested at build time; a 400 names the unknown model. Blocks verity's OCR check and blocked ldgr's Fable consultations (workaround in use: backend `claudecode`, model `claude-fable-5-2`) | parity mission | wip | Verity's OCR review check passes; `consult_model` with Fable 5.2 runs; self-test covers every alias |
| A2 | A turn with zero assistant output is retried, then `failed` with a reason; never `completed` | parity mission | wip | A forced empty reply on dev retries and does not end the mission |
| A3 | Stall watchdog in Core: a mission marked finished or active with live workers/VMs and no wakeup is woken once and flagged | operator session | todo | A deliberately stalled test mission is woken and reported |
| A4 | Honest tool receipts (`action_outcome` matches the result); tool schema and handler generated from one definition | parity mission | todo | Receipts say `succeeded`; a schema/handler mismatch fails the build |
| A5 | A mission whose first turn was never dispatched does not show `active` | parity mission | todo | Start with an unreachable node yields `failed`, not `active` |
| A7 | Missions started through MCP with no node are placed by the fleet scheduler instead of sitting `active` with no job (hit lean-ui for five hours and the client mission) | operator session | done (6670669e6) | — |
| A8 | Library skills load in opencode missions on fleet nodes (lean-ui reported its required skills "aren't exposed by this session's skill loader") | parity mission | todo | A mission on a node lists the library skills |
| A6 | Deploys do not kill running turns (drain, or client retry on 502) | parity mission | todo | A deploy during a running turn produces no 502 in the nginx log |

Shipped today in this class: `resume_mission` honours `content` and `title`
(5dd9753ce); opening a mission no longer rewrites `updated_at` (0ff162c2b).

## B. Managed compute (Boat, lean.ci, Colab)

| # | Item | Owner | State | Done when |
| --- | --- | --- | --- | --- |
| B1 | Restore archived Boat machines | Boat mission | done, unverified live | One archived machine comes back with its files |
| B2 | `extend_managed_machine` works for the owner lineage and the operator, accepts `<id>` and `managed-<id>` | Boat mission | wip | A dev machine is extended through MCP |
| B3 | Expired machines are destroyed at the provider; the owner gets a warning event before expiry | Boat mission | wip | A dev machine is destroyed at expiry with an event; no `ready` row past expiry |
| B4 | Auto-extension while busy, or correct the tool text that promises it | Boat mission | wip | Behaviour and description agree |
| B5 | Harvest: pull a git bundle from a VM to a trusted node through Core, no token on the VM | Boat mission | todo | A worker's commits reach a trusted node without base64 in transcripts |
| B6 | lean.ci provider, then Colab | providers mission | wip (groundwork merged) | A lean.ci machine is rented, used and destroyed on dev, then prod |
| B7 | Sealing authority requires a real operator identity regardless of dev mode | providers mission | wip | Dev-mode login token is refused by the sealing gate |
| B8 | Auto-placement, snapshots, fork | Boat mission | todo | Warm builders work again for verity and turbo-lean |

## C. Client

| # | Item | Owner | State | Done when |
| --- | --- | --- | --- | --- |
| C1 | Status colour: turn end is not mission completion while a wakeup or child remains | client mission | done (client; Core field deployment pending) | Shared derivation/spec in `docs/ui/mission-status.md`; ldgr light/dark keyboard browser replay passes. One Core response field, `live_children_count`, added to list/detail for hidden children; Lean SelfTest added but not run |
| C2 | Stale progress line ("Starting OpenCode on ashur… 7 h 20") clears when the job ends or the mission changes state | client mission | done | `send-continuity.test.tsx` replays both job-end poll and settled-status SSE with a trailing HTTP receipt; startup text/timer clear without replacing the prompt DOM |
| C3 | Subscriptions panel shows "Unknown" | parity mission (server) + client mission | wip | Panel shows real status on dev |
| C4 | Sidebar: missions vanish or revert title after open/rename/move | fixed in Core (0ff162c2b, #1704, #1705) | done | Client replay test added |
| C5 | Show the build commit of client and server in Settings/About | client mission | todo | Visible in the installed app |
| C6 | Open UI bugs from the 2026-11-12 screenshots, collected in `docs/ui/open-bugs.md` | client mission | todo | Each has a test or is closed with a reason |
| C7 | lean-ui replaces the Linux GTK/WebKitGTK shell | lean-ui mission | wip (started for real 19:05 UTC) | PR open with its gates green |

Rule while C7 is in flight: client fixes go in `orb/src`, not in
`linux_shell/`, so they survive the shell swap.

## D. Local install (aarch64 NixOS laptop)

| # | Item | Owner | State | Done when |
| --- | --- | --- | --- | --- |
| D1 | Orb pin in `omarchnix` at current master | operator session | done (1349b797f, lock only) | — |
| D2 | Build on dgx-spark, not on the laptop | operator session | wip | `nixos-rebuild --build-host` succeeds from spark's store |
| D3 | System switch | Thomas (needs sudo) | todo | `orb --version` / About shows the pinned commit |
| D4 | Two launchers only: the Nix install and "Orb (dev)". Retire the hand-synced `~/.local/share/orb-app` bundle | operator session, after D3 | todo | One `.desktop` entry removed |

## E. Redeploys

| # | Item | Owner | State | Done when |
| --- | --- | --- | --- | --- |
| E1 | `orb-deploy <sha>` on the server: exact commit, CI-parity build, self-test, dev, health, prod, rollback, log; `--detach` survives SSH | operator session | done (`scripts/ops/orb-deploy`) | First real prod deploy through it |
| E2 | Same command covers `sandboxed-node` and `sandboxed-mcp` | operator session | todo | Companion binaries report the same build |
| E3 | Missions merge to master, dev deploys automatically; prod stays deliberate | operator session | todo | A merge appears on dev without a human |

## F. Host monitoring

Before: `fleet-watcher` ran hourly and wrote to the journal only; three
maintenance units failed on every run and nobody was told.

| # | Item | Owner | State | Done when |
| --- | --- | --- | --- | --- |
| F1 | `orb-monitor` every 5 min: Core health and build, proxy error rate, stalled missions, expired/orphan/expiring VMs, failed units, long builds; reports only on change | operator session | done (`scripts/ops/orb-monitor`) | — |
| F2 | Alert channel: the monitor posts to the Orb Inbox through its own mission "Orb monitor" (3e18a8a5). The Signal endpoint the audit shipper uses for break-glass alerts still answers 404 | operator session | Inbox done; Signal todo | First report visible in the Inbox; a break-glass test alert arrives |
| F3 | Audit shipper: retry B2 503s instead of failing the run | operator session | done on the host | No failed runs for a day |
| F4 | `sandboxed-worker-rolling-upgrade` (points at the Rust tree) and `sandboxed-harness-update`: fix or delete | operator session | todo | No failed Orb unit |
| F6 | `sandboxed-development-identity` unit fails (found by the monitor); missions use it to sign commits | operator session | todo | Unit active; a mission signs a commit |
| F5 | Retire `fleet-watcher` once F1+F2 cover it; move stalled-mission and VM checks into Core (A3, B3) | operator session | todo | Monitor keeps only what Core cannot see about itself |

## G. Steering

| # | Item | Owner | State |
| --- | --- | --- | --- |
| G1 | managed-compute skill matches reality (fresh machines, TTL for the whole job, emit patches early, no token on VMs) | operator session | todo |
| G2 | One recovery preamble for resumed missions, stored in the library | operator session | todo |

## Order of work for the operator session

1. F2 decision, then F4.
2. D2–D3 with Thomas, then D4.
3. Verify B1 live, restart evm.fast.
4. A3, then E2–E3.
5. G1–G2.
