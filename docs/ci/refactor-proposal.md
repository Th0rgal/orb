# CI & test refactor proposal

Status: proposal (2026-11-12). Nothing implemented yet.

## What CI does today (and wastes)

| Workflow | Trigger | Main cost | Waste |
| --- | --- | --- | --- |
| `ci.yml` (11 jobs) | every PR/push + daily | `test`: cold `--ensure-lean` + 12 binaries + 7 `lake build`s, no cache | Runs everything on every PR, including docs-only, iOS-only, `orb/`-only. No Lean build cache: every run is a cold build, and it runs raw `lake` rather than turbo-lean. `orb-macos-shell` (macOS runner) runs on every PR. Lean is built twice (`test`, `orb-desktop-shell`, `policy-lint` each build Lean bins separately). |
| `kernel-abi.yml` | every PR/push | Downloads Lean, **`cargo build`s turbo-lean from source in debug** each run, ~20 hand-written `lean -o` invocations, 24 sequential `audit-spec` calls | Not path-gated. Hand-rolled module order duplicates the lakefile (Principle 2). Debug turbo-lean is slow and uncached. Pinned turbo-lean `29d85f7` is behind `82a9406` (missing warm Lake adoption, batched audits, `pr-verify` overlays from #417). |
| `ios-build.yml` | path-gated | macOS runner | OK; but gates on all of `lean/Orb/**` even for spec-only edits. |
| `android-apk.yml` | path-gated | Gradle | No Gradle/JNI cache sharing with kernel artifacts. |

Rough consequence: an `orb/src`-only PR still pays a cold Lean build of every
package, the full kernel audit, Docker, and a macOS runner.

## Goals

1. A PR runs only the jobs whose inputs changed; "inputs" includes workflows,
   toolchain pins, lockfiles and shared fixtures, so skipping is conservative.
2. Lean work is incremental and cached (turbo-lean CAS), never cold on a warm PR.
3. Heavy Lean jobs run on lean.ci warm microVMs with `.olean` CoW overlays,
   not on cold `ubuntu-latest`.
4. One required status check, so branch protection stays simple while jobs skip.
5. `master` push and the nightly still run everything (and seed the cache).

## Design

### 1. One planner job decides what runs

Add `scripts/ci_plan.py` (stdlib only, modelled on turbo-lean's
`scripts/ci_impact_plan.py`): diff `merge-base(base, HEAD)..HEAD`, classify
paths into domains, emit `outputs` JSON. Force-full on `push` to `master`,
`schedule`, `workflow_dispatch`, and when any of `.github/**`,
`lean/lean-toolchain`, `lean/turbo-lean-revision`, `scripts/ci_plan.py`
changed. Unknown paths ⇒ full (fail closed).

| Domain | Paths (sketch) | Jobs |
| --- | --- | --- |
| `docs` | `docs/**/*.md`, `*.md`, `docs-site/**` | docs-site build only |
| `kernel` | `lean/Orb/**`, `lean/audit/**`, `lean/LeanMesh/**`, `shared/orb-spec/cabi/**`, `scripts/gen_*`, `scripts/*kernel*` | kernel-abi, + downstream `lean_bins`, `orb_web`, `ios`, `android` |
| `lean_bins` | `lean/Orb{Core,Node,Bin,Client,Locald,NetLeaf}/**`, `scripts/build_orb_bins.sh` | lean-test, harness-contract, policy-lint, desktop-shell, docker |
| `fixtures` | `shared/orb-spec/fixtures/**` | lean-test (spec-runner), orb-unit, ios, android |
| `orb_web` | `orb/**` (excl. `orb/scripts/build-signer.py`) | orb-unit, orb-browser, orb-performance (perf only if `orb/src/**` or perf config) |
| `desktop_native` | `linux_shell/**`, `macos_shell/**`, `orb/scripts/build-signer.py` | desktop-shell; macos-shell only for `macos_shell/**` |
| `ios` / `android` | `ios_dashboard/**` / `android_dashboard/**` | existing mobile jobs |
| `policy` | `scripts/**` (non-gen), `capabilities/**`, `catalog/**`, `deploy/**`, `docker/**` | policy-lint, capability-matrix, docker |

`fmt` (zero `.rs`, C shim ≤ 220 LOC, call-site lint) always runs; it is seconds.

The domain → job map lives in one checked-in file (`ci/domains.toml`), and the
planner has unit tests replaying real past PR file lists (Principle 4), e.g.
"PR touching only `orb/src/Sidebar.tsx` must not schedule `kernel-abi`" and
"PR touching `shared/orb-spec/fixtures/x.json` must schedule ios + android".

Merge `kernel-abi.yml`, `ios-build.yml`, `android-apk.yml` into `ci.yml` as
jobs gated by `needs.plan.outputs.*` (drop `on.paths`, which cannot express
"downstream of kernel"). Keep `android-apk.yml` only for release publishing.

### 2. Single required gate

A final `ci-ok` job with `needs: [all jobs]`, `if: always()`, that fails if any
needed job is `failure`/`cancelled` and treats `skipped` as pass. Branch
protection requires only `ci-ok`. This keeps "every check green" meaningful
while jobs skip.

### 3. turbo-lean: latest, prebuilt, cached

- Bump `lean/turbo-lean-revision` to current `82a9406` (warm Lake adoption,
  batched `audit-spec`, `pr-verify` overlays). Keep the reviewed-revision pin
  and provenance receipt.
- **turbo-lean is built once per pinned revision, never per run.** A
  `turbo-lean-tool` composite action restores
  `~/.cache/turbo-lean/bin/turbo-lean` from the cache key
  `turbo-lean-bin-${{ runner.os }}-${{ hashFiles('lean/turbo-lean-revision') }}`
  and checks its BLAKE3 hash against the provenance receipt stored with it.
  Only on a cache miss, which happens once after a revision bump, does it
  check out the reviewed revision and run `cargo build --release --locked`,
  then save the binary and receipt. Every other run, and every job in a run,
  restores the binary in about a second. On lean.ci, use the turbo-lean the VM
  image ships when its `--version` revision matches the pin. Otherwise use the
  same cached binary. Either way, no cargo build happens on the hot path.
  Prefer a published release asset of turbo-lean for that revision, if one
  exists, over building it.
- **No `lake` anywhere in CI.** Every Lean build and test goes through
  turbo-lean:
  - kernel-abi: the ~20 hand-written `lean -o … -i …` lines become
    `turbo-lean build --project-dir lean --jobs N` (the lakefile is only the
    module graph that turbo-lean parses).
  - test: the 7 `lake build … && ./.lake/build/bin/…` lines become
    `turbo-lean build --project-dir lean/<Pkg> <test-target>` followed by
    running the binary.
  - `scripts/build_orb_bins.sh` currently falls back to
    `SANDBOXED_ALLOW_RAW_LAKE=1 lake build` when turbo-lean is missing or
    fails. Under `CI=1` (or `ORB_REQUIRE_TURBO_LEAN=1`) remove that fallback:
    a missing or failing turbo-lean fails the job instead of silently running
    a slow, uncached lake build. `--ensure-lean` installs only the Lean
    toolchain, not elan or lake.
  - `-DwarningAsError=true` and `autoImplicit=false` come from the package
    options that turbo-lean reads, so local and CI flags are identical.
  - A `fmt` check fails if `lake build` / `lake exe` shows up in
    `.github/workflows/**` or in the CI scripts.
- **Caching Lean outputs** uses turbo-lean's content-addressed store
  (`.tlpack`), not a `.lake` directory cache. See the next bullets.
- Batch the 24 `audit-spec` calls into one invocation (list of files →
  one JSON report), asserting `vacuous_specs == 0`, `trivial_specs == 0`,
  `horizontal_packing_warnings == []` per file in a small Python check.
- PRs: `turbo-lean pr-verify --base origin/master --mode untrusted
  --kernel auto --receipt …` re-verifies only changed modules and their
  reverse deps, with statement pinning. `master` push / nightly:
  `turbo-lean ci-verify --mode trusted --seed-shards` and write the portable
  `.tlpack` CAS (GDSF GC, `max-reclaimable-bytes` ~2 GiB).
- Cache trust: PR jobs **read** the `.tlpack` seeded by `master` but never write
  a cache that `master` reads (GitHub's cache scoping already enforces this;
  keep `pr-verify` in `untrusted` mode so a cache hit is never a verdict).

### 4. lean.ci runners for Lean jobs

Move `kernel-abi`, `lean-test`, `desktop-shell` (Lean part) and the
fixture-generation checks to lean.ci warm microVMs (`lean-8vcpu…` for PRs,
`lean-16vcpu` for master/nightly), using the CoW `.olean` overlay keyed by
`repo` + `base_key = merge-base SHA` + `lean_mode`. Effect: a PR starts from
the `master` build of its merge base, so only touched modules rebuild.

Open questions to settle before implementing (need lean.ci docs/account):
- Runner integration shape: GitHub self-hosted runner label vs.
  `POST /v1/vms` + exec from an `ubuntu-latest` job (Core already speaks the
  latter API in `lean/OrbCore/OrbCore/Managed.lean`).
- Secret: `LEANCI_API_KEY` as a repo secret, never exposed to fork PRs;
  fork PRs fall back to `ubuntu-latest` + `.tlpack` cache.
- Per-second billing: hard `timeout-minutes` and a fixed TTL on every VM.

Fallback if lean.ci is unavailable: same jobs on `ubuntu-latest` with the
`.tlpack` cache; correctness never depends on lean.ci.

### 5. Build once, fan out

`lean-test` builds the 12 binaries once and uploads them (`target/debug`,
zstd) as an artifact keyed by the Lean input digest. `harness-contract`,
`policy-lint`, `desktop-shell` and `docker` download it instead of each
rebuilding Lean. `kernel-abi` uploads `orb_kernel.wasm` + `liborb_kernel.so`
for `orb-browser`, `ios` and `android` to consume and compare.

### 6. Web and mobile

- `orb-unit`, `orb-browser` (2 shards), `orb-performance` only when `orb_web`
  or `kernel`/`fixtures` changed. Use `vitest --changed origin/master` on PRs
  for the unit tier only if the run stays under the full-suite time; otherwise
  keep full (it is cheap once pnpm and Playwright caches hit).
- `orb-performance` runs on `master` + nightly, and on PRs only when
  `orb/src/mission/**`, virtualization, streaming, or perf config changed
  (perf budgets need a stable baseline; record numbers in the PR anyway).
- `orb-macos-shell` only for `macos_shell/**` (or full runs).
- iOS: add a DerivedData + SPM cache; skip on `lean/Orb/**` changes that do
  not alter `shared/orb-spec/cabi/**` or fixtures (the planner checks the
  generated artifact diff, not the Lean source).
- Android: `gradle/actions/setup-gradle` with configuration cache; reuse the
  `liborb_kernel.so` artifact for the JNI tests.

### 7. Hygiene

- Draft PRs: keep current skip, but run `plan` + `fmt` so feedback is instant.
- Unify `actions/checkout@v4`/`@v6` and other action versions; pin by SHA.
- `concurrency` stays as is (PR-only cancellation).
- Local parity: `scripts/ci_local.sh [--base origin/master]` runs the planner
  and exactly the jobs it selects, so agents run "the ones for the area you
  touched" mechanically instead of from the list in `AGENTS.md`.

## Expected effect (to measure, not promised)

| PR type | Today | After |
| --- | --- | --- |
| docs only | all jobs | `plan`, `fmt`, docs-site |
| `orb/src` only | all + macOS | `plan`, `fmt`, orb-unit, orb-browser (+perf if relevant) |
| one `lean/OrbCore` module | cold build of everything | lean.ci warm overlay, `pr-verify` of changed modules + reverse deps, downstream binary jobs |
| `lean/Orb/Kernel.lean` | full | full minus unaffected mobile/web if generated artifacts unchanged |

Measure before/after per PR class from 20 recent PRs (wall clock, runner
minutes, macOS minutes) and put the table in the implementing PR.

## Rollout

1. Planner + `ci-ok` gate + domain tests, in "report only" mode (all jobs still
   run; planner output logged and compared) for ~1 week.
2. Bump turbo-lean, build it once per revision and cache it, replace hand-rolled `lean`
   invocations and every `lake build` with turbo-lean, remove the lake fallback, and batch audits. Switch Lean jobs to `pr-verify` / `ci-verify`
   with `.tlpack`.
3. Enable skipping; switch branch protection to `ci-ok`.
4. Move Lean jobs to lean.ci with fallback; artifact fan-out.
5. Mobile/web caches and perf gating.

Each step is its own PR, revertible on its own.
