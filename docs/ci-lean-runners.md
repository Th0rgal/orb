# Linux CI runner opt-in

The workflows are staged with hosted runners as the default. Thomas must complete
and approve the checklist below before setting `ORB_LEAN_RUNNERS=true`.

The [15 Nov Mode 2 activation handoff](archive/plans/orb-consolidation-2026-11.md#b2-mode-2-activation-handoff--15-nov-2026)
records the verified GitHub/upstream state and the ordered operator commands.
Routing landed in Orb **#1771**; #1781 was a mobile version bump. As checked on
15 Nov, the repository variable is unset, the runner inventory is empty, and
lean.ci #33/#34 remain open. App installation and deployed controller/engine state
still require operator verification. JIT runners register on demand, so an empty
idle inventory alone does not prove a registration failure. Labels are carried
by each ephemeral JIT registration, not created as a repository setting.

## Selection

Every Linux job in `ci.yml` and `kernel-abi.yml` selects lean.ci only when all of
these conditions hold:

- Repository Actions variable `ORB_LEAN_RUNNERS` equals `true`.
- `github.repository == 'Th0rgal/orb'`.
- And either:
  - `github.ref == format('refs/heads/{0}', github.event.repository.default_branch)`,
    the event is `push`, `schedule`, or `workflow_dispatch`, and for
    `workflow_dispatch` the boolean input `use_lean_runners` is checked (its
    default is false); or
  - the event is `pull_request` and the pull request's head repository is
    `Th0rgal/orb` itself (a branch of this repository, which only people with
    write access can push). Fork pull requests and `pull_request_target` stay
    on hosted runners. lean.ci enforces the same rule on its side: it admits a
    pull request run only when its head repository id is the repository's, and
    the runner is fenced to that one run (lean.ci #41).

Test and Kernel ABI use `lean-32vcpu-ubuntu-2604`; other Linux jobs, including
both plan jobs, use `lean-16vcpu-ubuntu-2604`. Exception: Orb browser, Orb
performance and Docker image always run on hosted runners, because they need
Docker (a `container:` image or `docker build`/`run`) and lean.ci guests have no
Docker daemon (first lean.ci master run, 16 Nov). Orb Desktop Shell also stays hosted: it builds the
Linux desktop release binaries, which must link against Ubuntu 24.04 system
libraries, and lean.ci guests are Ubuntu 26.04. Both aggregators stay hosted:
in [web PR CI](https://github.com/Th0rgal/orb/actions/runs/44278806268), CI OK
waited 6m36s for a Lean runner after its dependencies finished, then ran for 10s.
lean.ci guests also ship
without Rust: on a turbo-lean cache miss, `setup-turbo-lean` installs a pinned
minimal Rust 1.99.1 through `rustup-init`. Fork pull requests, fork repositories,
other non-default-branch events, tags, other events, and unset/false variables preserve
each job's original hosted runner:

| Workflow | Jobs | Hosted fallback |
| --- | --- | --- |
| CI | orb-build, orb-unit, orb-browser, orb-performance, orb-desktop-shell | `ubuntu-24.04` |
| CI | plan, test, fmt, harness-contract, capability-matrix, policy-lint, docker, ci-ok | `ubuntu-latest` |
| Kernel ABI | plan, kernel-abi | `ubuntu-latest` |
| Kernel ABI | kernel-ok (aggregator stays hosted) | `ubuntu-latest` |

The macOS job remains on `macos-26`. This change does not alter push path filters.
`python3 -m unittest -v scripts/test_ci_plan.py` tests the actual runner expressions
against the explicit original-label inventory, including PR and disabled cases.

## Thomas's approval and rollout checklist

- [ ] Review and merge [lean.ci #33](https://github.com/lfglabs-dev/lean.ci/pull/33)
  (`feat/user-repository-jit`) first.
- [ ] Review and merge [lean.ci #34](https://github.com/lfglabs-dev/lean.ci/pull/34)
  (`feat/user-repository-jit-fence`) second. Confirm the final head has passing
  Rust tests, the rerun-attempt regression, ordered requeue coverage, and real
  shell execution of the job-start hook (matching push accepted; run ID, SHA,
  pull_request, and missing-fence cases rejected).
- [ ] Roll out the merged `leanci-engine` **and** a rebuilt guest rootfs containing
  the matching `leanci-shim` with the `ACTIONS_RUNNER_HOOK_JOB_STARTED` execution
  fence. Restart/drain engines as required for the new rootfs to serve fresh
  guests; updating the controller alone is insufficient.
- [ ] Verify deployed engine heartbeats report `runner_fence: Some(true)` (wire
  capability `runner_fence: true`). Confirm fenced jobs cannot be assigned to
  an engine that omits or disables that capability. Confirm the guest receives
  its fence file and executes the hook before any workflow steps. A UI-only
  `runner_fence_capable` metadata flag is not capability evidence.
- [ ] Deploy the merged `leanci-ctrl` and set its environment to
  `LEANCI_USER_RUNNER_REPOSITORIES=Th0rgal/orb`. Preserve other explicit operator
  approvals if the existing value contains authorized repositories. Confirm the
  GitHub App installation and per-repository enabled state also authorize Orb.
  Installing an App across an account is not permission to opt in every repo.
- [ ] Verify controller admission and guest fencing for the trusted default
  branch, including a run attempt 2 whose workflow_job omits `run_attempt`.
  Verify PR/untrusted jobs cannot acquire useful execution by racing the JIT
  runner's label. A JIT runner is single-job; its label alone does not bind it to
  the webhook job that caused its boot.
- [ ] Review and merge the Orb opt-in PR with the variable unset/false. Confirm
  PR jobs retain their hosted labels and all required checks pass on that head.
- [ ] Check a deployed Ubuntu 26.04 runner's tool versions and compatibility for
  apt, Playwright/browser dependencies, Docker, and the Lean/kernel toolchain.
  Record image/rootfs identity and engine/controller revisions. Source recipes
  and local tests do not prove deployed image compatibility or a speedup.
- [ ] **Approve enablement:** in `Th0rgal/orb` → Settings → Secrets and variables
  → Actions → Variables → Repository variables, create/edit `ORB_LEAN_RUNNERS`
  with value `true`. Equivalent operator command:
  `gh variable set ORB_LEAN_RUNNERS --repo Th0rgal/orb --body true`.
- [ ] Run CI and Kernel ABI via Actions → Run workflow on the default branch,
  checking `use_lean_runners`. Confirm 16/32 vCPU labels, fence acceptance, job
  completion, and required checks. Record run URLs, attempt, SHA, queue time,
  total wall time, heavy-job timings, cache state, and image/tool versions.
  Compare hosted and lean runs on the same SHA and planner scope before claiming
  performance gains. Push/schedule runs now opt in automatically.

## Immediate rollback

Set repository variable `ORB_LEAN_RUNNERS=false` in the same Variables page, or:

```sh
gh variable set ORB_LEAN_RUNNERS --repo Th0rgal/orb --body false
```

Deleting the variable also restores the original hosted labels. Cancel queued or
in-progress lean runs and start new runs after changing it; an already evaluated
`runs-on` is not guaranteed to change in place. No automatic availability fallback
exists once a lean label has been selected: an unavailable runner leaves the job
queued. Rollback requires no workflow commit or controller deployment.
