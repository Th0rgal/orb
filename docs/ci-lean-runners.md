# Linux CI runner opt-in

Status: staged, **not safe to enable yet on public Orb**. Leave the repository
variable `ORB_LEAN_RUNNERS` unset. The lean.ci controller change rejects public
User-owned repositories until job-assignment fencing is implemented and tested.
A JIT runner is single-job, not bound to the webhook job that caused its boot.
A fork can modify its workflow to request the same label and race another job.
A workflow expression or webhook refusal alone does not close that race.

## Selection and rollback

After the controller and scheduling security prerequisite are reviewed, deployed
and verified, set repository Actions variable `ORB_LEAN_RUNNERS` to exactly
`true`. Linux jobs use `lean-16vcpu-ubuntu-2604`, with Test and Kernel ABI using
`lean-32vcpu-ubuntu-2604`; the Kernel ABI plan job uses 16 vCPU. Every pull request
(including same-repository PRs) keeps its original hosted label; macOS and iOS stay on
`macos-26`. Fork repositories also stay hosted, even if they copy the variable.
This conservative initial rollout only accelerates `push`, `schedule` and
`workflow_dispatch` on the repository default branch, matching controller admission.
Tags, release branches, non-default-branch dispatches and all other event types
stay hosted. It makes no PR-speedup claim.

Unset, false, misspelled or other variable values preserve each original hosted
label: `ubuntu-24.04` for orb-browser, orb-performance and orb-desktop-shell;
`ubuntu-latest` for the other Linux jobs.
There is no automatic outage fallback: a selected lean runner that is unavailable
leaves the job queued awaiting a matching runner. To disable, delete the
repository variable (Settings → Secrets and variables → Actions → Variables),
or set it to `false`. Cancel already-queued runs and trigger new runs after the
change; do not assume a queued job's evaluated `runs-on` changes in place.
The worker does not set this variable, deploy, or enable the feature.

The lean.ci App being installed on all account repositories is not compute
approval. The controller's operator allowlist and per-repository enabled state
must both authorize a repository. No unrelated account repository may be opted
in implicitly. Public repositories require a separate execution fence; adding
Orb to an allowlist must not bypass the public-repository deny.

## Documentation-only pushes

CI and Kernel ABI ignore `docs/**` and `**/*.md` on push only. Android and iOS
already use positive path filters, so their push filters end with `!docs/**`
and `!**/*.md` instead (GitHub forbids combining `paths` and `paths-ignore`).
Their tag triggers retain GitHub's usual behavior: path filters do not filter
tag pushes. PR filters are unchanged to preserve existing required checks.

## Image compatibility and measurements

lean.ci's image recipe includes actions-runner v2.338.2, build-essential, elan,
Lean (recipe default v4.33.1), lean4export and a caller-provided turbo-lean binary
copied to `/usr/local/bin/turbo-lean`. The source does not pin that binary's
version or prove the currently deployed image accepts `--no-telemetry`.
The lean acceleration shim invokes `turbo-lean build --no-daemon --no-telemetry`;
record `command -v turbo-lean`, `turbo-lean --version`, and build help from a real
runner before attributing acceleration to it. Orb's build script and
`lean/turbo-lean-revision` are track A owned and are intentionally unchanged.
Ubuntu 26.04 image compatibility (apt, Playwright, Docker and Android SDK) also
requires real-run verification; image recipes are not execution evidence.

The previous 23.53-minute baseline is not reproducible under the following
explicit definition. GitHub REST API recomputation for PRs #1704–#1723 selects
the latest completed `ci.yml` pull_request run on each PR's final head SHA;
wall time is run `created_at` to maximum job `completed_at` for that exact
attempt. All 20 completed runs: median **15.8667 minutes**; 15 successful runs:
median **16.2667 minutes**. This is CI only, not all required workflows. Includes
a docs/planner-only run (#1714, 0.35 minutes); scope and outcome mix mean this is
not a controlled performance experiment. All selected attempts are 1.

| PR | Run ID | Conclusion | Wall minutes |
| --- | --- | --- | ---: |
| 1704 | 43247203379 | success | 17.3667 |
| 1705 | 43247490816 | success | 15.0167 |
| 1706 | 43263027911 | success | 19.5333 |
| 1707 | 43262423973 | success | 12.4500 |
| 1708 | 43271100439 | failure | 9.2000 |
| 1709 | 43283831700 | success | 20.2500 |
| 1710 | 43393428958 | success | 16.2667 |
| 1711 | 43414233414 | success | 20.5667 |
| 1712 | 43403021346 | success | 15.4667 |
| 1713 | 43403291349 | success | 9.9333 |
| 1714 | 43403357975 | success | 0.3500 |
| 1715 | 43404948366 | success | 20.6500 |
| 1716 | 43405569545 | success | 17.9333 |
| 1717 | 43421443059 | failure | 22.7667 |
| 1718 | 43408962634 | success | 9.0833 |
| 1719 | 43413319428 | success | 21.9500 |
| 1720 | 43420557756 | failure | 12.5667 |
| 1721 | 43419424806 | success | 11.6833 |
| 1722 | 43421421205 | failure | 20.3833 |
| 1723 | 43422027918 | failure | 11.9833 |

Reproduce using `GET /repos/Th0rgal/orb/pulls/{number}` for final head SHA,
`GET /repos/Th0rgal/orb/actions/workflows/ci.yml/runs?head_sha={sha}&per_page=100`,
then `GET /repos/Th0rgal/orb/actions/runs/{id}/attempts/1/jobs?per_page=100`.
Sort candidates by `(run_number, run_attempt)` and choose the last completed
pull_request run; compute medians over unrounded seconds. This took 60 API
requests with environment-only authenticated access.

Real lean-runner comparison is **pending**, not estimated: first close the public
assignment race, deploy and verify controller behavior, then run comparable
same-SHA hosted/lean push or dispatch jobs with matching planner scope and cache
state. Record queue time, complete workflow wall time, individual heavy jobs,
runner labels, image/tool versions and conclusions. PR runs deliberately remain
hosted and cannot serve as evidence of lean acceleration.
