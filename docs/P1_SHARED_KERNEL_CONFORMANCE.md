# Shared-kernel conformance: implementation and limits

`scripts/run_shared_kernel_conformance.py` executes every public symbol in
`shared/orb-spec/kernel_abi.json`: 96 Orb exports and 33 LeanSys exports (129
public exports across the 130-entry manifest after `#1488` added
`orb_slot_bypass_step`). The inventoried compiler helper is excluded from the
public surface. The complete [P0–P7 roadmap](TRUSTWORTHY_SHARED_LEAN_ROADMAP.md)
and acceptance gates still apply. No phase is accepted by this harness.

Use reviewed compiler executables and the pinned LeanSys checkout explicitly:

```sh
python3 scripts/run_shared_kernel_conformance.py \
  --turbo-root /path/to/turbo-lean \
  --lean-sys-root /path/to/lean-sys \
  --lean-bin-dir /path/to/lean-4.35.0/bin \
  --expected-orb-head FULL_REVIEWED_ORB_SHA \
  --expected-turbo-head FULL_REVIEWED_TURBO_SHA \
  --out /path/to/new-evidence-directory
```

The output directory must not exist and should be outside the source worktrees.
The harness requires clean Orb, Turbo and pinned LeanSys inputs, checks the
caller-supplied full revisions, records resolved tools and version responses,
and hashes participating harness modules and generated artifacts recursively.
It requires POSIX process groups. Only Linux execution is established here;
Darwin command support is not a native Apple qualification receipt.
Each run preserves command arguments,
working directories, exit codes, stdout/stderr, source and tool hashes,
generated sources, binaries, inputs and observed values. Per-case SHA-256 receipts
bind the input, result, engine and the shared provenance hash. They are unsigned
consistency records, not authenticated execution attestations or proofs. Hashes
of command logs bind the supplied local receipts; dynamic libraries, operating
system, compiler correctness and hardware execution remain assumptions.

For each export the corpus includes six boundary vectors (0, 1, 2, 3, maximum,
maximum minus one) and two reproducibly seeded random vectors: 1032 base cases
across the current 129 public exports (1024 base / 1044 total at the 128-export
execution head `3c70e5ada` recorded below). Lean-witnessed domain mutation
vectors extend a current 129-export run to 1052 cases.
This small scalar corpus is not exhaustive fuzzing. Stock Lean executes wrappers
calling the actual exported Lean definitions. Those wrappers also compile via
stock `lean -c` and `leanc`. Native C is compiled from the vendored artifact;
generated Rust FFI calls exercise the same C ABI. Scalar WASM compiles that C
using Clang's freestanding headers and explicit LLD WASM mode, then runs in Node.
UInt64 values cross JavaScript boundaries as decimal strings and BigInt.
LNIR uses the actual source frontend and interpreter; errors remain failures.
No handwritten behavioral oracle, precomputed answer, or mocked engine supplies
an execution result.

Native calls execute in supervised subprocesses, with active case markers and
flushed observations. Timeouts, crash signals and SIGTERM preserve command
receipts; partial valid rows remain separate from complete engines and are
compared when a complete stock reference exists. LNIR uses one request per
input/case and validates a strict decimal UInt64 result, avoiding positional
identity within repeated-declaration batches and unbounded command lines.
Missing tools, unsuccessful commands, bad row identities and incomplete engines
remain visible. A mismatch or mutation-qualification failure exits 1.
Malformed output retains independently valid expected-ID observations for
comparison, including rows after a malformed line. All occurrences of a duplicate
identity are excluded as ambiguous, with the engine explicitly blocked. Extra IDs
cannot discard valid observations. Once a built mutant is invoked, malformed,
missing or duplicate results, crashes and timeouts fail qualification (exit 1);
unavailable build/reference prerequisites remain incomplete (exit 2).
The harness exits `0` (`PASS`) only when all six required scalar engines
(`stock_lean`, `stock_extracted_c`, `vendored_native_c`, `rust_abi`, `wasm`,
`lnir`) complete every public-export and witness case with zero mismatches, all
production host adapters (`rust_orb_spec` via `crates/orb-spec`,
`projection_invariants` shared fixtures, and `jni_x86_64` via the shipped
`liborb_kernel.so`) agree with `stock_lean`, the 3-way loop/alias/RC corpus
(`scripts/conformance_loop_alias_rc.lean`) agrees across `stock_lean`,
`stock_extracted_c`, `lnir`, and `lnir --opt` with `live_objects == 0` and
passing `validate-tv`, and all 21 Lean-witnessed domain mutants (`lean/Orb/MutantSuite.lean`,
3 per family across all 7 roadmap families) plus the low-bit scalar shims are
killed in both native C and WebAssembly. Otherwise any missing engine or
unqualified stage exits `2` (`INCOMPLETE`) and any mismatch or surviving mutant
exits `1` (`FAIL`). Physical iPhone 13 mini and Pixel 8 hardware remain
explicitly recorded as `BLOCKED_PHYSICAL_DEVICE`.

The initial workspace run executed all 896 cases in stock Lean, extracted C,
vendored native C, generated Rust ABI and WASM with zero observed mismatches.
LNIR failed on missing UInt casts, scalar type errors and unresolved calls; it was
not counted as a successful engine. Subsequent runs must retain their own exact
source/command receipts. The mandatory missing NTT binding and failed/missing CI
checks in turbo-lean PR264 remain blockers; this harness does not waive them.
P2 bootstrap/deduplication is still open. Physical iPhone13 mini and Pixel8 remain
`BLOCKED_PHYSICAL_DEVICE`. No merge or production deployment follows from these
local observations.


The exact `c02351a5` full run terminated with exit **2 / INCOMPLETE**:
five complete scalar paths (896 rows each), 16 agreeing partial LNIR observations,
880 failed LNIR requests, 3,600 comparisons and zero observed mismatches. Native
and WASM low-bit mutants were detected on exactly cases 96–103. These paths share
implementations: Rust FFI and WASM both exercise the vendored C; this is not five
independent implementations. The mandatory NTT binding and broader P1 gates
remain open.

Follow-up evidence repairs include partial observations in schema-v2 case
receipts with `engine_complete: false`. Missing cases receive no synthetic rows.
The provenance hash also binds all three repository identities (including
LeanSys), clean-state observations and environment metadata. Command outputs
require unsigned decimal tokens, matching the LNIR value contract; decimal
leading zeros are not an additional canonical-format requirement. LNIR failures
retain their count and point to the raw error/command files. Hashes remain
unsigned consistency checks, not execution attestations. These reporting repairs
do not turn prior-run receipts into a fresh engine execution at the repair head.

A subsequent fresh run at Orb `10252589` / Turbo `854184b7` terminated with
**exit 2 / INCOMPLETE**. Thirteen harness tests passed. Five scalar paths
completed 896 cases each; LNIR produced 333 agreeing partial observations and
563 failed requests: 432 UInt8 equality, 91 UInt8 less-or-equal, 16 UInt8
less-than and 24 local-helper calls. There were 3,917 comparisons, zero observed
mismatches and 4,813 case receipts, including 333 partial records. Both mutants
were killed on exactly cases 96–103. This is fresh evidence for those exact
heads, separate from the earlier reporting-only replay.

Full-receipt review exposed a reporter boundary: failed compile/link commands
could print valid-looking rows and have them admitted as partial execution.
Commands now default to the prerequisite role; only explicitly marked case
execution can contribute failed-command stdout as observations. An actual
nonzero subprocess regression verifies rejection for prerequisites and retention
of a real execution mismatch. Engines inherit an explicit path/home/temp
environment allowlist; credentials and injection variables are excluded. The
effective environment and Python binary identity are recorded in provenance.
These follow-up repairs do not rerun or retroactively relabel the prior run.
Clean source heads plus tool digests do not alone establish binary-to-source
build lineage; build receipts and the trusted build/toolchain remain separate
assumptions, not a compiler-correctness proof.

Subsequent review also reproduced dropped LNIR observations when a process emitted
valid one-row JSON then exited nonzero. The per-case path now applies the same
identity/value checks to preserved execution stdout while retaining the request
failure. Such rows are partial evidence and a mismatching row forces exit 1;
invalid JSON or wrong identity contributes no observation. Both baseline and
mutant WASM calls share the explicit execution role. These reporter tests use
fixture subprocesses, not real engine qualification or a new full conformance run.
The environment allowlist currently targets the qualified Linux toolchain;
non-default SDK/Rustup/Nix environments may require explicit future support.
PATH/HOME/configuration, interpreter libraries and tool-resolution mediators are
trusted dependencies; binary hashes do not attest those dependencies. Command
history is hashed in provenance separately from the artifact inventory.

Response processing stays inside each request's ordinary-exception boundary.
A real subprocess regression emits an earlier valid mismatch then deeply nested
JSON (both zero and nonzero exits): parser recursion failure retains the earlier
partial mismatch and forces FAIL. SystemExit/KeyboardInterrupt remain outside
that catch. Early tool-resolution failures can leave only commands.json rather
than a normal report; such setup failures establish no engine qualification and
must retain their original evidence directory rather than retrying over it.

## Exact-head qualification, 2026-10-31

Fresh execution at Orb `3c70e5ada278a4e37e0180255f360aa2ff5fe86c`,
Turbo `e585ba96f58cb06414ce5e3216f3ffc0ce235300` (merged Stage 1D #280),
and LeanSys `c089f3e31dbd36f2bde2219913d5b9c90da670be` exited **0 / PASS**.
All three input checkouts were clean. Later documentation commits are not new
execution heads and do not retroactively change these receipts.

All six engines executed 1044 cases over 128 public exports: 5220 comparisons,
zero observed mismatches. Rust production wrappers passed 1044 rows; shipped
x86_64 JNI passed 524 rows over 64 JNI exports; 19 projection fixture cases passed.
The loop/alias/RC corpus passed 42 cases across stock Lean, extracted C, LNIR and
optimized LNIR, with seven probes, zero live objects and passing symbolic TV.
All seven mutation families killed three domain mutants each: **21 distinct
domain mutants**, each executed in native and WASM (42 kills), plus two scalar
shim executions, giving **44 killed mutation executions**, not 44 distinct mutants.
The conformance harness unit suite passed 21 tests.

Evidence directory: `/srv/sandboxed-storage/host-tmp/opencode/p1-final-e585ba9-20261031`.

| Receipt | SHA-256 |
| --- | --- |
| `report.json` | `88acaae9c5c7add56e9258ef51c83925f35a446d9d9ca8a4b807f55df0d8ad70` |
| `provenance.json` | `8f1a3af1c0f7040561953d630d59e10774bc7770242be4197c0f4066dff51016` |
| `commands.json` | `e93caaf14b6b1f43c3465ea1177949419df5a7cc6f3b2ad49922a9041f03c907` |
| `case-receipts.jsonl` | `c34b6a17857a35845ad8d6ec3c925fac7e8afb252dd216f0cc88cef19dd16939` |

These are local unsigned receipts, not durable public artifact hosting or proof
of complete host wiring. On current `master` (130 manifest entries after `#1488`
added `orb_slot_bypass_step`), the coverage registry remains **23 partial / 107
unconnected** (`acceptance: INCOMPLETE`; 23 partial / 106 unconnected across the
129 entries at execution head `3c70e5ada`). Physical iPhone/Pixel execution
remains blocked. See [P3 target qualification](P3_TARGET_QUALIFICATION_REPORT.md)
for the separate execution-versus-cross-compilation scope. Earlier incomplete
runs above remain historical evidence; they are not relabeled by this successful
run.
