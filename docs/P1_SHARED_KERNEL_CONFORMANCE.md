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
