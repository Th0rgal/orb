# Shared scalar WASM artifact stage

`scripts/build_orb_kernel_wasm.py` compiles the same vendored unboxed C used by
native clients into scalar WASM. It uses the supplied Lean toolchain's Clang,
freestanding headers and explicit LLD WASM driver. `mvp` CPU and disabled SIMD
flags make the scalar profile explicit. No fallback implementation is generated.

```sh
python3 scripts/build_orb_kernel_wasm.py \
  --lean-bin-dir /path/to/lean-4.35.0/bin \
  --out /path/to/orb_kernel.wasm \
  --receipt /path/to/new-build-receipt.json
```

The manifest controls all 113 exported function names and ABI parameter/result
types (112 public-prefix exports and one compiler helper). The builder rejects
missing or extra function exports, wrong WASM types and all imports. Uint8 and
Uint32 use WASM i32; Uint64 uses i64. A small metadata parser checks those ABI
sections; a real Node WebAssembly engine validates and instantiates the complete
module before publication. This division does not claim the parser is a full
WASM validator or establish compiler correctness. The raw build receipt records
commands, builder/loader/tool/source/manifest/artifact hashes, source revision,
mode, output path, comparison/publication outcome and overall attempt status.

The output file is replaced by rename only after validation. A failed tool or
validation preserves the previous artifact. This is single-file POSIX publication,
not a power-loss durability guarantee or atomic artifact-plus-receipt transaction.
`--check` rebuilds and compares bytes without publishing; it requires the same
toolchain for reproducibility. Existing receipt paths are rejected to retain
failed and prior attempts. Input loading occurs inside the reserved receipt's
failure scope. Overall success is set after staging-directory cleanup; a cleanup
failure after rename records failure while retaining the fact of publication.
Invalid argument paths and unavailable receipt creation cannot be recorded to
that requested receipt. Metadata fixtures exercise type/name/import drift and
truncation. Real Node tests reject invalid bodies and instantiation traps before
publication; mismatch, rename and input failure injections preserve prior data.
Those fixtures are not shared-kernel execution results.

## Desktop adapters and startup

The shipped `orb/src/assets/orb_kernel.wasm` is built by this command. Rebuild it
before running `python3 scripts/gen_kernel_bindings.py`; CI rebuilds in check mode
against the shipped bytes. The generator emits `orbKernelAbi.ts` for all 113
manifest entries, recording the artifact SHA-256 and expected export arities.
The runtime verifies that hash, rejects imports or export drift, validates and
instantiates the complete module, then publishes its instance. A failed attempt
does not publish a partial instance. SHA-256 ties these adapters to the supplied
bytes; it does not prove those bytes implement Lean semantics.

Scalar UInt64 parameters/results stay BigInt, including values with bit 63 set.
UInt8 and UInt32 parameters require in-range integer numbers. WASM signed results
are normalized to their unsigned ABI representation. Inputs outside these raw
contracts throw instead of silently wrapping or losing precision.
`orbKernel.ts` retains host boolean/enum encoding, coordinate validation and
display strings. Work folding, task states, relative-time buckets, usage-limit
fields, transcript patching and the two scanner admissions call the generated
bindings. The seven handwritten decision implementations are removed. Host time
inputs are finite, safe integer seconds after flooring and clamping negatives;
the raw UInt64 interface accepts the full 64-bit range. The host usage adapter
rounds/clamps percentage values to UInt8; invalid utilization is marked absent.

`index.tsx` imports only the kernel, startup view and theme before initialization.
App, API connection and stores are behind `import('./appEntry')`, invoked after
the kernel is ready. Kernel download, integrity or instantiation failure shows a
visible Retry button without loading App. App import/mount failure offers Reload;
it does not retry partially created stores. There is no behavioral runtime fallback.
The outer pre-existing `bootstrap.ts` still handles failure to import this initial
module graph. Secure-context WebCrypto and WebAssembly BigInt are required.
The bundle budget still includes the full App static graph through Vite's
manifest; the new initialization boundary does not exempt eager application code.

Unit tests initialize the actual shipped WASM. The dedicated browser suite checks
the failed-download/retry import order and shared projection fixtures:

```sh
cd orb
pnpm install --frozen-lockfile
pnpm exec vitest run
pnpm build
pnpm exec playwright install chromium
pnpm exec playwright test --config=playwright.kernel.config.ts
```

Those bounded checks do not establish full P1 multi-engine host conformance,
WebKit/Tauri execution, performance targets or P2 phase acceptance. Native
iOS/Android clients retain their existing C ABI path and shared fixtures; this
changes the desktop implementation rather than adding a mobile feature.
Physical iPhone13 mini and Pixel8 remain
`BLOCKED_PHYSICAL_DEVICE`. The complete P0–P7 roadmap and required CI/review gates
remain in force; no merge or production deployment is authorized here.
