# W-CI-1 CI speed report

W-CI-1 moves Lean package builds onto the pinned, cached `turbo-lean` wrapper
installed once by the `setup-turbo-lean` composite action. The binary build
script now makes an uncached Lake fallback explicit, rather than silently
masking a cache or build failure. The Docker build can select prebuilt CI
binaries while retaining the source builder for local image builds.

`kernel-abi.yml` stays a separate workflow: the shared planner selects it
through `ci/domains.toml` (`wf:kernel-abi`) and it keeps its own verification
receipt, so `CI OK` never certifies the kernel audit. Its initial `Orb.*`
kernel modules still compile directly with `lean` before `AuditSpec.lean`
runs, while native package self-tests and `audit-spec` checks use the cached
`turbo_lean.sh` path shared with `ci.yml`.

## Measurements

- The pinned `turbo-lean` release build completed in **6m06s**.
- A previous full source build reached **2.85 GB** maximum RSS and was
  interrupted after **12,667s**; it is retained as an interrupted run, not a
  successful baseline.
- Focused W-CI-1 checks passed: `python3 -m unittest -v
  scripts/test_build_orb_bins.py scripts/test_ci_plan.py` ran **75 tests**,
  plus `scripts/test_coverage_registry.py` **8 tests**.
