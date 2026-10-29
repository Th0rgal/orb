# Orb Trustworthy Shared-Lean Roadmap & Phase DAG

## Current acceptance status (Codex handoff, 2026-10-28)

**P0–P7 remain unaccepted.** The phase DAG and exit gates below are requirements,
not receipts that they have executed. P0 is in progress; P1 has a compiler-side
harness PR but full Orb/LeanSys conformance remains open; P2–P7 remain open.
Compiler and Orb repairs are tracked in draft PRs turbo-lean #264 and Orb #1396.
Bounded source-and-receipt reviews of turbo `8108785` and Orb `5d961353`
found no new confirmed repair regression; both remained overall BLOCKED.
Fresh exact-head reviews are required for subsequent changes. Turbo has no GitHub
check rollup; Orb kernel-abi passed, while draft Rust jobs were skipped.
No phase acceptance, merge or production deployment follows from those checks.

The coverage registry remains incomplete: 101 entries are unconnected and 12
have explicit partial evidence in `shared/orb-spec/coverage_evidence.json`.
Source hashes bind local host-test receipts to the linked theorem declarations
and observers; these links do not establish authoritative callers or adapter parity.
Its 113 manifest entries are 80 `orb_*` exports (`Orb.Kernel.*`), 32 `leansys_*`
exports (`LeanSys.Spec.*`, verified against pinned `lean-sys` by `gen_orb_kernel_unboxed.py`),
and the compiler helper `lp_orb_x2dspec_Orb_Kernel_accessStep___redArg` (`model: null`).
The original 112-export requirement still covers all public Orb/LeanSys exports; the helper
remains inventoried separately rather than being counted as an extra public gate.
Shadow observations now count missing host HOME poststates as unobserved,
never as ExactMatch; remote execution observation remains open. The stale-snapshot repair also includes newly stored supersession in the
admission predicate; it does not close the observation-to-execution race.
Independent exact-head reviews remain required.

The native builder now derives its entire symbol inventory from the ABI
manifest and checks both the object and archive, requiring exactly one strong
text definition per entry and no extra globals or unresolved imports. Tool
failure rejects the artifact. This establishes a symbol-table constraint, not
C signature correctness, target qualification or compiler correctness. Apple
underscore normalization is parser-tested; physical/native Apple execution is
not established by that test.

Local recovery checks: all 14 fork/control tests pass, including independently
injected archive-state, exact action-identity (`EffectMismatch`), and HOME-state divergences, plus stale caller snapshots with either stored
supersession tag form. The registry
has seven adversarial tests and the ABI manifest suite has 18 passing tests.
The direct submission-producer regression replays stored archive and both
stored supersession-tag forms, checking rejection before node contact and job
publication, and verifies `EffectMismatch` detection when host and Lean agree on
boolean admission or rejection yet disagree on exact `MissionControlAction` codes.
It also preserves a visible divergence for an archived caller
paired with a live store: the scalar monotone-archive model does not refine
that reverse snapshot. The SQLite fixture preserves the store's prohibition
on acknowledging a nonterminal run; this is not an atomic execution fence.
These receipts establish local execution only. Mission-control shadow effects
compare exact pre-dispatch `MissionControlAction` codes against independent host expectations, not post-dispatch remote node process execution;
HOME preflights lack remote poststate receipts. Neither is an end-to-end proof.

Host/device information below comes from earlier enumeration. This handoff has
not executed native artifacts on those remote hosts or devices. Physical iPhone
13 mini and Pixel 8 qualification remains `BLOCKED_PHYSICAL_DEVICE`.

## 1. Executive Summary & Architectural Mandate

This document persists the complete, executable **Orb Trustworthy Shared-Lean Roadmap** across **`Th0rgal/orb`** and **`Th0rgal/turbo-lean`** (including `LeanNative` and `lean-sys`).

### Architectural Ownership Boundary
- **Lean 4 (`v4.35.0`, `0 import Lean`, `0 sorryAx`)** owns pure decisions, admission gates, and deterministic state machines (`lean/Orb/Kernel.lean`, `lean/Orb/Spec.lean`, `lean/Orb/Stream.lean`, `lean/Orb/Scroll.lean`, and `LeanSys`).
- **Rust (`src/`, `crates/orb-spec/`)** owns async Tokio/Axum I/O, network transport, SQLite persistence, OS process/cgroup isolation, and cryptography.
- **SolidJS (`orb/`), SwiftUI (`ios_dashboard/`), and Kotlin Compose (`android_dashboard/`)** own rendering, platform geometry, localization, and platform effects.
- **Single Logical Implementation via Stable ABI**:
  - Native clients (iOS C-ABI, Android JNI, macOS, Linux server) link compiled unboxed C-ABI artifacts directly.
  - Desktop JS (`orb/`) executes the **exact same kernel via WebAssembly (`orb_kernel.wasm`)**, synchronous after a single async bootstrap before module-level stores initialize.
  - **Zero handwritten behavioral runtime fallback**: `orb/src/orbKernel.ts` contains generated typed ABI adapters over `orb_kernel.wasm` plus host-only presentation/formatting strings where Lean returns semantic `(unit, value, status)` tuples. Startup failures surface explicitly with retry rather than falling back to duplicate TypeScript domain logic.
  - **Stock Lean (`lean -c`)** remains the independent CI reference oracle and explicit build-time rollback while `LeanNative` passes and target backends are qualified stage by stage.

---

## 2. Verified Baseline & Pin Alignment

| Repository / Component | Baseline Revision Inspected | Role |
| :--- | :--- | :--- |
| **`Th0rgal/orb`** | `e6b3283eff02e644660a79acc8b0a6d4c6a14331` | Core backend, `orb-spec` crate, desktop/iOS/Android clients, formal kernel (`Orb.Kernel`, `Orb.Spec`, `Orb.Stream`, `Orb.Scroll`) |
| **`Th0rgal/turbo-lean`** (Orb pin prior to P0) | `71c61b14a8cf5e061def8a571208c2a6ffd26c66` | Incremental Lean verifier, `audit-spec`, `LeanNative` compiler & `LNIR` operational semantics |
| **`Th0rgal/turbo-lean`** (`main` HEAD at mission start) | `fbd36764a27c62705c825744d9f0a5ca7523811e` | Includes M1.4–M5 refactored pipeline (`ConLeche`, `ElabAudit`, `EqSat`, `LoopSchedule`, `OwnershipRC`, `CoreCLI` compression) |
| **`Th0rgal/lean-sys`** | `077775ba387f1eeb2976cb8763b4633b8d5ce313` | Verified systems gates & scanners (`leansys_*`) |

### Alignment with Public `turbo-lean/roadmap/` (`README.md`, `GOALS.md`, `VALIDATION_CONTRACTS.md`, `CONFORMANCE_SUITE.md`, `MAXWELL_STRATEGIES.md`)
- **M1 (Frozen statements, semantic dependency closure, kernel-AST `audit-spec` v2, real conformance)** $\leftrightarrow$ **Orb P0 & P1**: Enforces fail-closed compiler/artifact verification, honest per-stage provenance (`VerifiedKernelProof` vs. `TranslationValidated` vs. `Tested` vs. `Assumed` vs. `Unsupported`), and real 3-way+ differential execution (stock `.lean`, actual `LNIR` evaluator `evalDecl`, extracted C, native/WASM binary, and host wrappers).
- **M2 (`con-leche` independent checker qualification)** $\leftrightarrow$ **Orthogonal kernel receipt sovereignty** (explicitly not a prerequisite for P2 TypeScript deduplication).
- **M3 (`HeaderPin` surface-syntax audit & CAS dependency-bound proof replay)** $\leftrightarrow$ **Orb P0 & P6**: Prevents statement spoofing and ensures frozen specification integrity.
- **M4 (Pure `LCNF -> LNIR` bridge & compositional `EqSat`, `LoopSchedule`, `OwnershipRC` passes)** $\leftrightarrow$ **Orb P3**: Qualifies `LeanNative` scalar and loop passes behind `VerifiedCodePassContract` / `VerifiedTVPassContract` before switching production artifacts.
- **M5 (Typed MLIR lowering & `LNSym` ARM64 hot kernels)** $\leftrightarrow$ **Orb P3 & P7**: Grounds target-specific codegen and SIMD scanners without claiming blanket LLVM/linker/loader verification.
- **M6 (Ecosystem & grammar-guided fuzz conformance)** $\leftrightarrow$ **Orb P1, P3 & P6**: Continuous differential fuzzing and $\ge 3$ mutant kills per spec family.

---

## 3. Phase DAG & Required Exit Gates

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ P0: Honest Claims & Fail-Closed Trust Boundary (turbo-lean + orb)            │
│  • Compiler missing-input / unknown-target / tool-failure fail-closed        │
│  • Proper macosArm64 target (distinct from iosArm64); atomic output publish  │
│  • Archive/object/WASM magic, arch, platform, exports/imports verification   │
│  • Per-stage provenance labels matching actual execution branch              │
│  • Machine-checked Orb coverage registry & non-circular shadow observations  │
└──────────────────────┬───────────────────────────────────┬───────────────────┘
                       │                                   │
                       ▼                                   ▼
┌─────────────────────────────────────────┐ ┌──────────────────────────────────┐
│ P1: Real Independent Conformance        │ │ P2: Remove orbKernel.ts Copies   │
│  • Stock .lean vs LNIR eval vs C vs     │ │     via Shared WASM              │
│    native/WASM binary vs host wrappers  │ │  • Compile orb_kernel_unboxed.c  │
│  • Cryptographic per-case receipts      │ │    to orb_kernel.wasm (0 waiting │
│  • Missing engine => FAIL/INCOMPLETE    │ │    on P3 compiler research)      │
│  • All 112 Orb/LeanSys exports + fuzz   │ │  • Generated TS adapters + BigInt│
│  • Engine & harness mutation tests      │ │  • Async bootstrap + retry UI    │
└──────────────────────┬──────────────────┘ └──────────────┬───────────────────┘
                       │                                   │
                       └─────────────────┬─────────────────┘
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ P3: Qualify LeanNative on Real Targets Before Switching Production Artifacts │
│  • Scalar exports with optional passes disabled first, then qualified passes │
│  • Explicit supported subset, numeric/memory/SDK/target contracts            │
│  • Portable Android baseline & scalar WASM profile (--wasm-simd128 opt-in)   │
│  • Honest execution vs BLOCKED_DEVICE status for physical hardware           │
└────────────────────────────────────────┬─────────────────────────────────────┘
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ P4: Shared Compositional State-Machine & Arena ABI                           │
│  • Generic Machine<State,Event,Effect> over OrbWire word+arena               │
│  • Typed stable IDs, revisions, field presence, patches, effects             │
│  • Versioned codec roundtrips; zero partial mutation on capacity error       │
└────────────────────────────────────────┬─────────────────────────────────────┘
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ P5 + P6: Paired Executable Lean Migrations & Stronger Meta-Specs             │
│  1. Versioned mission merge/hierarchy (epoch-aware, unarchive vs fence)      │
│  2. Transcript reducer/streaming (stable IDs, gap buffer, full replay eq)    │
│  3. Durable outbox/queue/leases (persistent+volatile, crash between steps)   │
│  4. Provider attempt lifecycle (retry budgets, first-byte fence, clocks)     │
│  5. Authorization (fresh scoped revocable evidence observe->gate->execute)   │
│  6. Scheduling/resources (reservation capacity, TTL/boot epochs, fairness)   │
│  7. Incremental parsing/indexing/scroll (chunk equivalence, bounded tail)    │
│  • Each paired with reachable traces & >= 3 killed mutants per family        │
└────────────────────────────────────────┬─────────────────────────────────────┘
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ P7: Measured Optimization After Trust & Workload Profiling                   │
│  • Eliminate rescans/whole-list replacement; batch ABI calls                 │
│  • Qualify NEON / WASM SIMD scanners with target capability & equivalence    │
│  • Benchmark cold start, p50/p99 stream, replay, memory, huge unclosed fence │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Known Baseline Gaps & Remediation Matrix

| ID | Baseline Gap | Location | Remediation Phase & Action |
| :--- | :--- | :--- | :--- |
| **G-ORB-1** | `clientParityStep` uses XOR/count summary (`transcriptSeq ^^^ (markdownBlocksCount <<< 16) ^^^ (sendQueueDepth <<< 24)`); `Spec.lean` near 3116 claims full client projection parity | `lean/Orb/Kernel.lean:1606`, `lean/Orb/Spec.lean:3111` | **P0**: Narrow theorem/doc name to `client_summary_digest_word_parity_across_targets` and record explicit summary-digest assumption in coverage registry. **P4/P5**: Replace lossy digest with full state/patch equivalence over `OrbWire`. |
| **G-ORB-2** | `at_most_one_writer_and_no_message_lost_or_duplicated` models single-step admission given supplied `hasLease`/`msgAlreadyDelivered` booleans, not durable crash/concurrent queue conservation | `lean/Orb/Spec.lean:2062` | **P0**: Rename to `single_step_writer_admission_and_delivered_flag_gate` and document assumption. **P5.3/P6**: Model persistent + volatile outbox/queue/lease state across crash boundaries with conservation & fencing theorems. |
| **G-ORB-3** | `replay_log_eq_live_transcript_and_monotone_seq` proves `transcriptReduceStep` ignores `isReplayFromLog` on a single 64-bit transition word, not full transcript fold equivalence | `lean/Orb/Kernel.lean:1502`, `lean/Orb/Spec.lean:2663` | **P0**: Rename to `transcript_reduce_step_word_ignores_replay_flag_and_rejects_stale_seq`. **P5.2/P6**: Prove multi-event transcript reducer fold & replay equivalence. |
| **G-ORB-4** | `CostBound` instances in `Spec.lean` set `cpuFuel := fun _ _ => 1` symbolically rather than actual runtime step/byte counters | `lean/Orb/Spec.lean:2134, 2713, 3056` | **P0**: Label symbolic step count vs. measured runtime cost in registry and `Spec.lean`. **P6/P7**: Pair structural/amortized step counters with real runtime benchmarks. |
| **G-ORB-5** | `missionControlMetaStepSpec` sets `expectedEffect := fun _ _ => True`; `src/api/control/fork.rs` feeds Lean's own `verdict.archived_next` as `legacy_after` and `&false, &false` in `observe_fork_home_shadow` (circular comparison) | `lean/Orb/Spec.lean:2119`, `src/api/control/fork.rs:68, 117` | **P0**: Tighten `expectedEffect` to match the concrete expected `MissionControlAction` code, and compute independent host post-state (`host_archived_after`, `host_override_home_after`) in `fork.rs` & `remote_jobs.rs` with unit tests proving shadow divergence detection when host disagrees with Lean. |
| **G-ORB-6** | `Orb.Stream.incCost_linear` requires bounded-tail hypothesis `∀ u ∈ us, u.len - u.commit ≤ t`; giant unclosed code fences have unbounded tail `u.len - u.commit = u.len` | `lean/Orb/Stream.lean:314` | **P0/P5.7/P7**: Document bounded-tail precondition explicitly, add unclosed-fence tail cap / checkpointed scanner state so giant unclosed fences do not trigger quadratic re-parsing. |
| **G-ORB-7** | Admission gates prove boolean decisions over caller-supplied flags, not truth/freshness of evidence or host enforcement | `lean/Orb/Spec.lean`, `src/` | **P0**: Record explicit host-observation assumptions in `shared/orb-spec/coverage_registry.json`. **P5.5/P6**: Model `observe -> gate -> execute` epoch/target/lease binding and TOCTOU rejection. |
| **G-ORB-8** | `orb/src/orbKernel.ts` duplicates 7 kernel functions by hand in TypeScript | `orb/src/orbKernel.ts` | **P2**: Compile `orb_kernel_unboxed.c` to `orb_kernel.wasm`, generate `orb/src/orbKernel.ts` from `kernel_abi.json`, add async WASM bootstrap before app import, and delete handwritten behavioral copies. |
| **G-TL-1** | `parseTargetArch` maps `"macos-arm64"` to `.iosArm64` and unknown strings to `.x86_64` | `lean/LeanNative/Driver/Worker.lean:45` | **P0**: Add `TargetArch.macosArm64` (`arm64-apple-macosx14.0.0`, Mach-O platform macOS, `-mcpu=apple-m2`), and make `parseTargetArch?` fail closed on unknown targets. |
| **G-TL-2** | `loadInputModule` returns `defaultMod` (`mkCanonicalBenchmarkModule`) when an explicit `--lnir` or `--input` file does not exist or when no input is given to compile commands | `lean/LeanNative/Driver/CoreCLI.lean:103, 115` | **P0**: Fail closed when an explicit input path is missing or when a compile/validate command lacks `--input` (unless `--canonical-benchmark` or `--fastcheck-sample` is explicitly passed). |
| **G-TL-3** | `runCompileStaticLib` writes textual LLVM IR to `.a` and returns exit code `0` with `archive=false` when `clang` or `ar` fails | `lean/LeanNative/Driver/CoreCLI.lean:275-280` | **P0**: Fail closed (non-zero exit, no corrupt `.a` published), use atomic staging + rename so previous valid outputs are preserved on failure, and verify archive/object/WASM magic, architecture, platform, and exported symbols. |
| **G-TL-4** | `LLVM.lean` unconditionally emits `"target-features"="+simd128"` on `wasm32` | `lean/LeanNative/Backend/LLVM.lean:1720` | **P0/P3**: Default `wasm32` to portable scalar profile; enable `+simd128` only when explicitly requested via `--wasm-simd128` / `IsaLevel`. |
| **G-TL-5** | `ofHybridVerifiedContract` stamps `.verifiedKernelProof` even when `candBody != kernelBody` and the extended branch was only checked by `validateTranslationDecl` (or when `UnboxTupleSROA`/`HoistExclusivity`/`LoopVectorizeOpt` use `ofCodeTransform` without a kernel proof on the full pass function) | `lean/LeanNative/Transform/Pass.lean:84-120` | **P0**: Distinguish `VerifiedKernelProof`, `TranslationValidated`, `Tested`, `Assumed`, and `Unsupported` per pass step and per declaration based on the **actual executed branch**. |
| **G-TL-6** | `fuzz_lcnf_conformance.py` `lnir_oracle` calls `reference_oracle`, `c_abi_value` returns precomputed `program["value"]`, and missing engines still return `ok: True` | `scripts/fuzz_lcnf_conformance.py`, `scripts/run_conformance_suite.py` | **P0/P1**: Fail closed if any required engine (`lean`, `lean-native-core`, `clang`) is missing; execute actual `.lean` via stock Lean, actual `LNIR` interpreter (`evalDecl`) on lowered IR, and actual compiled native/WASM binary on the same inputs with cryptographic per-case receipts and mutation-kill tests. |

---

## 5. Governance, Delegation & Review Protocol

1. **Coordinating Mission**: Codex resumes the persisted work after the OpenCode runner incident and manages the phase DAG, worktree isolation, build serialization, and verification gates.
2. **Independent Frontier Reviews (`openai/gpt-6-astra` and `antigravity/gemini-4-argon-low`)**:
   - Every phase PR in `Th0rgal/turbo-lean` and `Th0rgal/orb` is independently audited by both `openai/gpt-6-astra` and `antigravity/gemini-4-argon-low` against the exact git diff, theorem statements, raw command receipts, and mutation tests.
   - Any disagreement is resolved by concrete counterexamples, proofs, or executable tests—never by majority vote or worker summaries.
3. **Device & Environment Honesty**:
   - Available execution hosts in this environment:
     - `agent-core` (`x86_64-unknown-linux-gnu`, AMD Ryzen 5 3600, 62 GiB RAM)
     - `dgx-spark` (`aarch64-unknown-linux-gnu`, Linux 6.14 ARM64)
     - `macbook-air` (`arm64-apple-macosx`, Apple M2 `T8112`, macOS, plus Xcode `iPhone 13 mini Simulator`)
   - Physical `iPhone 13 mini` hardware (`apple-a15` iOS device) and physical `Pixel 8` (`tensor-g3` Android device) are not USB/network-attached (`xcrun xctrace list devices` lists only `air (2)` and simulators; `adb` is not attached). Therefore, physical iPhone 13 mini and physical Pixel 8 device execution checks remain explicitly marked **`BLOCKED_PHYSICAL_DEVICE`** in all reports and target qualification matrices, while `macbook-air` (real Apple M2 macOS hardware), `iPhone 13 mini Simulator` (on Mac), `dgx-spark` (real ARM64 Linux hardware), `agent-core` (real x86_64 Linux + WASM V8/Node/Playwright + Android JNI host `.so`), and cross-compiled Mach-O/ELF/WASM binary inspections require execution receipts before qualification.
