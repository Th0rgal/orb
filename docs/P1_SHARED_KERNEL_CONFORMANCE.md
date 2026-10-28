# Shared-kernel conformance: implementation and limits

`scripts/run_shared_kernel_conformance.py` executes every public symbol in
`shared/orb-spec/kernel_abi.json`: 80 Orb exports and 32 LeanSys exports. The
inventoried compiler helper is excluded from the public surface. The complete
[P0–P7 roadmap](TRUSTWORTHY_SHARED_LEAN_ROADMAP.md) and acceptance gates still apply.
No phase is accepted by this harness.

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
maximum minus one) and two reproducibly seeded random vectors: 896 cases total.
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
Otherwise the harness exits 2 (`INCOMPLETE`),
even when all scalar observations agree: existing production host adapters,
loop/alias/reference-counting cases, per-family mutation qualification and target
qualification are not implemented here. Generated Rust ABI calls do not exercise
the existing Rust host wrappers. Do not wrap exit 2 into a passing conformance gate.

The harness compiles native and WASM mutants that flip the low result bit of one
real forwarding export, executes them, and requires the comparator to detect all
eight affected cases, with exactly the intended low-bit flip and no unrelated
changes relative to an agreeing unmutated backend. This qualifies two bounded
mutation experiments only.
Adversarial harness tests reject dropped/extra/duplicate rows, swapped identities,
changed unequal values, and malformed LNIR response values. Hash tests show
payload changes alter the digest; they do not implement authenticated receipt
ingestion or detect identity substitution independent of values. Actual missing
commands and nonzero exits preserve failures. Real native abort/hang, SIGTERM and
child/grandchild timeout tests check supervision and interruption receipts.
This does not satisfy the roadmap's full engine-mutation or three-mutants-per-family
acceptance requirements.

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
