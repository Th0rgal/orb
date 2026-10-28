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

This is the artifact portion of P2, not phase acceptance. Generated TypeScript
adapters, asynchronous app bootstrap before stores load, visible failure/retry,
deletion of behavioral TypeScript copies and browser conformance remain open.
Native iOS/Android clients retain their existing C ABI path. No UI feature ships
in this stage. Physical iPhone13 mini and Pixel8 remain
`BLOCKED_PHYSICAL_DEVICE`. The complete P0–P7 roadmap and required CI/review gates
remain in force; no merge or production deployment is authorized here.
