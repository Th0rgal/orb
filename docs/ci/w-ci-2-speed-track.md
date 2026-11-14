# W-CI-2: verified-tree reuse and desktop CI

Base: `1f1e1ab31ad3839c27104afcbfeaa39bdc98ac86` (`origin/master` at clone).
Branch: `ci/w-ci-2-tree-reuse-and-fast-desktop`.

## Actual bottleneck

At this base, `linux_shell/**` already selects only `orb-desktop-shell`, and
`macos_shell/**` selects both shell jobs. Neither selects browser/performance.
`lean/OrbDesktop/**` incorrectly belonged to the broad `lean_bins` domain; it
now belongs to `desktop_native`. UI changes legitimately select browser tests.
Unknown paths and CI inputs still select everything.

The Actions API shows the actual cost in recent green UI PR
[CI run 43583911586](https://github.com/Th0rgal/orb/actions/runs/43583911586):

| Step | Browser 1 | Browser 2 |
| --- | ---: | ---: |
| apt hardening + Playwright install | 49 s | 41 s |
| Browser tests | 508 s | 348 s |
| Kernel dev tests | 13 s | — |
| Rebuild + kernel production tests | 38 s | — |

Its unit job spent 34 s building and 128 s testing. The tests dominate: removing
installation alone cannot meet five minutes.

## Execution and evidence

A short `orb-build` job installs/restores dependencies, builds once, caches
`dist` by tracked inputs and uploads it with the hidden Vite manifest. Unit,
browser and performance jobs depend on this preparation, without waiting for
the whole unit suite. Browser tests use **eight file-based shards**, retaining
one worker, retries and file order. Some specs compare measurements from earlier
tests in their file, so individual-test sharding would weaken an assertion.
Dev kernel Chromium/WebKit tests stay on shard 1; production tests use the
shared build on shard 2.

The pinned Playwright `v1.55.0-noble` image matches the pinned npm package and
supplies browsers, system libraries and fonts. Browser/performance jobs do not
run apt or browser installation. A separate OS/architecture/Ubuntu 24/Node 22/
lockfile cache supplies node modules. Whole-app performance tests use `dist`;
fixture HTML and source-module tests retain the dev server. All ten performance
tests remain selected with unchanged assertions.

The planner hashes `HEAD^{tree}` and tracked Git objects per impact domain.
Build hashes include names, modes, object IDs and CI/toolchain configuration.
The CI bundle uses its input hash as its CI build identity; ordinary desktop
builds keep the existing commit identity.

`CI OK` saves `ci-verified-tree-<tree>` and a `ci-verification` run artifact.
Receipts distinguish checks that passed from checks the successful impact plan
certified unrelated. An identical master tree preserves that successful PR
routing instead of reverting to the full-push fallback. Unexpectedly skipped
required checks cannot be certified; failed report-only performance results
never become a blocking master pass. Hygiene still runs on master.

Kernel ABI has separate `kernel-abi-verified-tree-<tree>` receipts and a
`kernel-abi-verification` artifact. CI OK cannot certify Kernel ABI or mobile.
The existing kernel audit body and required job remain intact. Nightly/manual
runs bypass reuse. Unverified master/main trees retain the full-run fallback.

PR caches are scoped to the PR merge ref, so content keys alone cannot make
them available to master. Read-only Actions API lookup bridges that boundary,
using receipts from completed green workflow runs. Receipts identify the actual
checkout tree, rather than PR `run.head_sha` (which can be the unmerged head).
Lookup is bounded to 20 recent green runs and approximately 25 seconds. Missing
tokens, API failures, corrupt/expired artifacts and mismatched run attempts are
cache misses. The feature needs a successful run of the new workflow to seed
its first receipt; older runs without receipts are not reused.

Matching frontend and desktop binary artifacts can be promoted into master
caches without running the already-covered tests or native/apt setup. Native
artifacts preserve executable modes with tar. Expired build artifacts fall back
to rebuilding. Desktop binary inputs cover Lean/shared/build-driver/CI sources,
excluding shell and OrbDesktop edits that cannot affect these two binaries.
Every selected shell run still compiles/tests the C shell and runs wakeup tests.
Only these two build caches are promoted; other jobs gain no new build cache.

## Local measurements

The VM reports 8 CPUs and 15 GiB RAM. This worker did not launch GitHub Actions;
the coordinator must measure end-to-end latency and the five-minute target.

| Check | Result |
| --- | --- |
| All scripts unit tests | 348 tests; passed in 60.3 s, 10 existing skips needing fresh native binaries |
| `python3 scripts/test_ci_plan.py` | 55 passed |
| Planner coverage, including CLI | 100% statements/branches (274 statements, 122 branches) |
| actionlint | Passed, excluding existing unrelated Docker `config-inline` deprecation |
| `pnpm install --frozen-lockfile` | 2.3 s |
| `pnpm build` | 41.5 s initial; 44.2 s with explicit CI identity |
| Bundle checker tests / budget | All 6 passed; 1149 kB / 1150 kB |
| `pnpm test` | 121.6 s; 2225 passed, 3 existing skips |
| Final browser shard 1/8 | 181.1 s; 65 passed |
| Final browser shard 2/8 | 148.0 s; 67 passed |
| Kernel dev Chromium + WebKit | 11.7 s; 6 passed |
| Kernel production Chromium + WebKit | 5.9 s; 4 passed, 2 existing dev-only skips |
| Performance, dist + dev fixtures | 67.3 s; all 10 passed, one on existing retry |
| Linux shell compile/self-test (WebKitGTK) | 3.6 s; passed |
| Wakeup MCP tests | 8 passed in 2.2 s |

Playwright test-list inventories preserve the **exact multiset**: all 517 browser
tests, with shard counts `[65, 67, 63, 71, 59, 65, 63, 64]`, and all ten performance
tests. Representative shards were executed locally, not all eight final shards.

Python dependencies used a temporary virtualenv. Missing WebKit `libwoff1` and
`libgstreamer-plugins-bad1.0-0` libraries were extracted from Ubuntu packages
into the local browser cache without sudo. An exploratory check using the VM's
older preinstalled `sandboxed-mcp` failed one current integration assertion; it
was not substituted for a fresh checkout build. No assertions or test skips
were changed to accommodate this VM.

GitHub authentication and the managed signing profile were not provisioned.
Delivery is a local unsigned worker commit and bundle for the coordinator to
apply/sign/push. No remote branch was pushed.

## Coordinator measurement

1. Apply the bundle and run this CI-changing PR. Its first run is deliberately
   full, because workflows/planner are new inputs. Check both receipt artifacts.
2. Squash with an up-to-date base or fast-forward. Compare the push tree to the
   PR receipt. Expect hygiene and cache promotion, with separate Kernel ABI
   reuse. The new Kernel ABI OK job does not replace the existing required job.
3. Check Linux-only, macOS-only, OrbDesktop-only and UI PRs. Inspect cache hits
   and all eight shard times. A different merge tree must execute checks.
