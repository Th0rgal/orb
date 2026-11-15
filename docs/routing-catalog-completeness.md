# Routing catalog completeness

## Conjecture (master 02e5adbaeb413d9b67804e3d12884c9b0c307a25)

The catalog renderer ignores hydrated OAuth accounts and persisted discovery.
Both static catalog paths depend on cwd. The chain-test loopback request reads
an optional environment secret instead of carrying the authenticated caller.
The desktop picker consumes `providers[].models` directly, so fixing that
response should expose Carbon without a separate client model list.

## Frozen behavioral specification

* An enabled, credentialed, caller-visible account contributes its latest
  successful discovered models to its canonical catalog provider, once per id.
  Partial discovery preserves fallback suggestions. Disconnected accounts do not
  contribute private discovery metadata. Never copy credentials or diagnostics.
* Static catalog resolution prefers `SANDBOXED_CATALOG_DIR`, then installed
  share/lib resources, then cwd `catalog`. Providers and snapshots use the same
  directory. A valid installed catalog must not silently become the five-provider
  emergency catalog because the service starts in `/root`.
* Admin chain tests traverse the real proxy authentication and routing path,
  preserving caller identity. An authenticated resolvable `builtin/smart` probe
  reaches its upstream; missing/invalid authentication is still refused.
* Antigravity Carbon ids remain Carbon; no Carbon-to-Argon substitution.

## Certification

Regression oracle: `orb-core-test` (provider HTTP contracts, hermetic proxy
transport), plus `python3 scripts/lint_kernel_calls.py` and shell syntax checks.
Write regressions before implementation; retain red/green receipts in the PR.
One Lean build at a time, one job, maximum 6144 MiB. These are executable
behavioral checks, not universal proofs or evidence of production deployment.
