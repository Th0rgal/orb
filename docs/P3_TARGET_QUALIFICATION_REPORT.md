# P3 target qualification — 2026-10-31

## Scope and exact inputs

Result: **QUALIFIED_WITH_HONEST_DEVICE_BLOCKERS**, not full roadmap acceptance
and not authorization to replace production artifacts.

- Orb execution head: `3c70e5ada278a4e37e0180255f360aa2ff5fe86c`.
- Turbo execution head: `e585ba96f58cb06414ce5e3216f3ffc0ce235300` (Stage 1D #280 merged).
- LeanSys: `c089f3e31dbd36f2bde2219913d5b9c90da670be`.
- All input checkouts clean; compiler executables clean-built from the Turbo head.
- 129 manifest entries; 128 public exports (95 Orb + 33 LeanSys); 1044 cases.
- Default and verified-kernel-only certificate checks report `verified: true`,
  but both retain effective `overallAssurance: Tested` for these frontend inputs.
  Do not promote that label to a kernel proof of the compiled program.

## Executed versus cross-compiled targets

| Target/path | Evidence |
| --- | --- |
| Linux x86_64 baseline LLVM, optimized LLVM, linked static archive | Each executed 1044 cases, zero mismatches |
| dgx-spark real Linux aarch64 (`10.88.0.2`, Cortex-X925) | Vendored C, baseline LLVM and optimized LLVM each executed 1044 cases, zero mismatches; remote scratch cleaned |
| Node/V8 WASM MVP, explicit SIMD128, shipped `orb_kernel.wasm` | Each executed 1044 cases, zero mismatches, zero imports; MVP IR excludes SIMD128 and opt-in IR includes it |
| Shipped Android x86_64 library via Linux ctypes | 128 C exports / 1044 cases and 64 JNI exports / 524 cases, zero mismatches; not Android OS/device execution |
| Android arm64-v8a and x86_64 JNI artifacts | Source rebuild check passed, 192 ABI exports and 16 KB LOAD alignment; arm64 Android device execution not established |
| macOS ARM64, iOS ARM64, iOS simulator ARM64 static archives | Cross-compiled and headers inspected: Mach-O platforms 1, 2 and 7 respectively; not native Apple execution |
| Android ARM64 static archive | ELF64 AArch64 inspected; OS/ABI not verified by the object-header inspection |
| MacBook Air `10.88.0.100` | `BLOCKED_HOST_UNREACHABLE` (SSH timeout) |
| Physical iPhone 13 mini / Pixel 8 | `BLOCKED_PHYSICAL_DEVICE` |

Cross-compilation, static header inspection, Linux JNI loading and real Linux
ARM64 execution must not be conflated with iOS or Android device execution.

## Receipts and reproducibility limits

Successful evidence directory:
`/srv/sandboxed-storage/host-tmp/opencode/p3-final-e585ba9-20261031-exact-oracle`.
Runner: `/srv/sandboxed-storage/host-tmp/opencode/run_p3_full_128_qual.py`.
This temporary runner and host-local evidence are not guaranteed durable public
artifacts. Preserve them separately before reclaiming host storage.

| Receipt | SHA-256 |
| --- | --- |
| `p3-target-qualification-summary.json` | `e6b8f9eaba8f252053979932ea90b7f4c2d1587575a7460cc323d087389e3871` |
| `commands-log.json` | `0ba3831bc6641d9c6204a39cd69da92a3b41d5d1da910aed24cc0f916f49df4d` |

P1 input evidence and hashes are recorded in
[P1 conformance](P1_SHARED_KERNEL_CONFORMANCE.md). The P3 summary binds artifact
hashes, case counts, commands and exact repository heads. These unsigned receipts
establish observed execution, not compiler/toolchain/loader correctness.
Documentation publication heads are distinct from the execution head above.

The earlier directory `p3-final-e585ba9-20261031` failed the WASM comparison:
JavaScript parsed numeric oracle values through `Number`, rounding large UInt64
values (81 mismatches). The runner was corrected to serialize oracle values as
decimal strings before `BigInt` conversion. The successful run is a fresh full
execution in a new directory; the failed attempt is retained, not overwritten or
relabeled.

## Remaining acceptance work

Physical device and native Apple execution remain blocked. Production rollout,
full end-to-end host callers and independently accepted phase exits remain
separate gates. On current `master` (130 manifest entries after `#1488` added
`orb_slot_bypass_step`), the coverage registry is **23 partial / 107 unconnected**
(23 partial / 106 unconnected across the 129 entries at execution head
`3c70e5ada`); passing scalar conformance does not close those connections.

`scripts/run_p3_qualification.py` is the repo-owned local driver for a later
checkout. It signs an Ed25519 consistency receipt (`assurance: Tested`,
`kernel_proof: false`) binding both compared archive hashes and distinguishing
`compared_backend` from the selected `backend` under rollback, compares the
260-case scalar C ABI (`130 * 2`) with a LeanNative `probe_*` archive (supplied
via `--leannative-archive` or compiled fresh via `--turbo-root`), and rolls
back with `--rollback-stock` or `ORB_KERNEL_BACKEND=stock-c`. A local match is
not phase acceptance, the historical 1044-case multi-target qualification,
device qualification, or a compiler proof. CI runs the stock path only. The
historical LeanNative archive above is external evidence, not a committed
production artifact.
