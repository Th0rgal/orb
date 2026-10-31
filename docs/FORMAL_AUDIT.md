# Formal audit reproducibility

The reviewed turbo-lean source revision is recorded in
[`lean/turbo-lean-revision`](../lean/turbo-lean-revision). It currently pins
`e585ba96f58cb06414ce5e3216f3ffc0ce235300` from
[Th0rgal/turbo-lean](https://github.com/Th0rgal/turbo-lean/commit/e585ba96f58cb06414ce5e3216f3ffc0ce235300).
Its package version is `0.1.0`; that version alone does not identify the source.

The Kernel ABI workflow checks out that exact revision, verifies the checkout
and Lean toolchain pin, and builds with Cargo's locked dependency graph. Its
`kernel-spec-audit` artifact contains the source revision, the built binary's
SHA-256 and reported version, and the JSON audit report. This records build
provenance; it does not claim bit-identical binaries across platforms.

For a local audit, build the pinned upstream checkout using the toolchain in
`lean/lean-toolchain` (currently Lean 4.35.0):

```sh
# In a separate checkout at the revision recorded above:
(cd lean && lake build LeanSys LeanNative.Spec)
CARGO_PROFILE_DEV_DEBUG=0 cargo build --locked -j 1 -p turbo-lean

# In the Orb checkout, with TURBO_BIN pointing at that built binary:
TURBO_LEAN_NO_AUDIT_CACHE=1 SANDBOXED_TELEMETRY_BATCH_ONLY=1 \
  "$TURBO_BIN" --json audit-spec lean/Orb/Spec.lean > /tmp/orb-spec-audit.json
python3 scripts/check_spec_audit.py /tmp/orb-spec-audit.json
python3 -m unittest -v scripts/test_spec_audit.py
```

`audit-spec` has its own cache; the global `--cache-dir` option does not disable
it. CI requires `cache_hit: false`, a nonempty inventory with every spec tight,
zero vacuous/trivial specs, and no horizontal-packing warnings. A successful
CLI exit alone is insufficient because packing warnings are advisory upstream.
The wrapper also rejects absent or incorrectly typed fields.

The textual turbo-lean audit supplements the existing direct Lean compiler and
axiom/vacuity audit (`lean/audit/AuditSpec.lean`); it does not replace proof
checking. Existing C regeneration, binding, fixture, JNI and ABI checks remain
in the same workflow. Building the audit tool may use Lake for its upstream
proof dependencies; normal Orb Cargo builds still compile the checked-in C
artifact without invoking Lean, Lake, or Elan.
