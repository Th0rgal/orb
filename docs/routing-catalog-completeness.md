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

### Custom-provider extension

* Desktop, iOS and Android resolve an exact catalog id first. Otherwise a custom
  provider accepts its raw id or its lowercase ASCII-alphanumeric name slug.
  `custom:surplus`, `surplus` and `surplusintelligence` therefore resolve to the
  same fixture named `Surplus Intelligence`. Unknown ids remain editable and
  visible; display labels never replace persisted ids merely by rendering them.
* Model pickers use that resolved provider's models, including `gpt-6-astra`.
  Argon remains a Surplus model, not a replacement for Antigravity Carbon.
* Admin catalog refresh performs authenticated server-side model discovery for
  enabled custom providers with stored credentials. Append `/models` to the
  configured base URL, preserving API prefixes and avoiding duplicate `/models`.
* Persist only nonempty, deduplicated model ids and allowlisted metadata. Never
  return the stored credential or upstream response diagnostics. Failed discovery
  retains the last successful models; configured manual models remain available.

The extension's HTTP contract checks the request path and bearer, discovery
deduplication, manual-model preservation and secret exclusion. Desktop tests
exercise all three aliases through the routing editor. These extension checks
have green results; unlike the original regressions, a pre-fix red run has not
yet been recorded. Native build acceptance remains separate from desktop checks.

Regression oracle: `orb-core-test` (provider HTTP contracts, hermetic proxy
transport), plus `python3 scripts/lint_kernel_calls.py` and shell syntax checks.
Write regressions before implementation; retain red/green receipts in the PR.
One Lean build at a time, one job, maximum 6144 MiB. These are executable
behavioral checks, not universal proofs or evidence of production deployment.
