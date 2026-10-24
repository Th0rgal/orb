---
name: boat-machines
description: "When and how a mission should rent boat.dev managed VMs: whether to use one at all, size choice, one warm snapshot per project, forking the parent VM, sharing a VM between sequential siblings, stopping instead of idling, budgets and cleanup. Use before spawn_managed_machine, start_mission(remote_node_id=\"auto-managed:...\"), fork, snapshot or stop/resume tools."
license: MIT
metadata:
  hermes:
    tags: [Boat, Managed-VM, Compute, Budget, Snapshot]
    related_skills: [sandboxed-sh-missions]
---

# Boat managed machines

## Do you need one?

Use a managed VM only when the work needs dedicated CPU/RAM (parallel builds,
big test suites, memory-hungry Lean/Rust) or isolation, or when
`get_compute_fleet` shows no free capacity. Reading code, reviews and short
probes run where you are.

## Size

All sizes run the same CPU: AMD Ryzen 9 9950X (Zen 5, AVX-512, VPCLMULQDQ).
Size buys cores and RAM, not CPU features. Do not rent `xlarge` to check CPU
flags.

| size | vCPU / RAM | $/h | use for |
| --- | --- | --- | --- |
| small | 2 / 4 GB | 0.018 | probes, audits, single tests |
| default | 4 / 8 GB | 0.036 | normal builds |
| large | 8 / 16 GB | 0.072 | parallel cargo/lake builds |
| xlarge | 16 / 32 GB | 0.20 | only measured heavy fan-out |

TTL defaults to 60 min and auto-extends in 30 min steps while the VM is busy.
Do not ask for long TTLs.

## Budget

Call `get_budget` first. If your mission has a pool, every VM, extension,
fork and resume is checked against it (`budget_exceeded` says what is
left). Give a child its own cap with `start_mission(..., budget_usd=2)`; it
must fit your remaining pool.

## One warm snapshot per project

Set up once, then start children from it:

1. `spawn_managed_machine(size="large", reason="warm image")`
2. On it: clone the repos, install the pinned toolchains, run the builds that
   fill caches. Keep everything outside `/tmp` and `~/.cache`: snapshots do
   not keep them. Use e.g. `/var/lib/orb-node/work/<repo>`, `CARGO_TARGET_DIR`
   and `.lake` inside the repo.
3. `snapshot_managed_machine(machine_id="large-a", name="lean-native-warm")`,
   then poll `list_managed_snapshots()` until `ready`.
4. Children: `start_mission(remote_node_id="auto-managed:default",
   managed_from_snapshot="lean-native-warm", ...)` or
   `spawn_managed_machine(from_snapshot="lean-native-warm")`.

Refresh the snapshot when lockfiles or toolchains change (same name, then
delete the old one). Core keeps the newest 2 per project and deletes ones
unused for 14 days; 10 are free, then $1.70/month each.

## Fork when a child needs your exact state

`fork_managed_machine(machine_id="large-a")` copies your VM for one child,
then `start_mission(remote_node_id="<returned name>", ...)`. Boat forks from
a background snapshot up to about a minute old: write and `sync` what the
child needs and wait ~60 s, or take a named snapshot for an exact copy.

## Share one VM between sequential siblings

If children run one after another, rent one VM yourself
(`spawn_managed_machine`) and start each child on it by name. You stay the
owner, so the VM survives each child. `auto-managed` also reuses an idle VM
of the same size left by an ended sibling.

## Stop instead of idling, destroy when done

- Pausing for a while (waiting on review, CI, the user):
  `stop_managed_machine(machine_id=...)`, later
  `resume_managed_machine(machine_id=...)` (same name, files kept, processes
  restart; within 24 h). The reaper also stops VMs of interrupted or waiting
  owners and resumes them when the owner works again.
- Finished: `destroy_managed_machine(machine_id=...)`.
- `list_managed_machines()` shows what you own (compact; `verbose=true` for
  everything).

## Credentials

VMs hold no credentials. git over https to github.com uses the GitHub token
Core delivers to your mission; never paste tokens into commands or files.
