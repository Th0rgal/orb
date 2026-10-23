# Orb kernel ABI

`kernel_abi.json` is the single source of truth for the verified kernel's C
surface: every exported symbol, its return type, and the order, name and C
type of each argument. The proofs live in `lean/Orb/Kernel.lean` (orb-spec)
and in `lean-sys` (`leansys_*`). The vendored C is
`cabi/orb_kernel_unboxed.c`.

## Generated files

`scripts/gen_kernel_bindings.py` writes these files. Do not edit them by hand.

| File | Contents |
| --- | --- |
| `shared/orb-spec/cabi/orb_kernel.h` | one prototype per manifest entry, in manifest order |
| `android_dashboard/app/src/main/jni/orb_kernel_jni.c` | a `Java_sh_sandboxed_dashboard_orb_OrbKernel_<method>` thunk for every entry with a `jni` block |

```sh
python3 scripts/gen_kernel_bindings.py          # regenerate
python3 scripts/gen_kernel_bindings.py --check  # CI: fail if stale
```

## Manifest schema

```jsonc
{
  "name": "leansys_sse_frame_scan",           // exported C symbol
  "ret": "uint8_t",                           // uint8_t | uint32_t | uint64_t
  "params": [
    {"name": "frameOff", "type": "uint64_t"}, // JNI: uint64_t -> jlong, others -> jint
    {"name": "lastByte", "type": "uint8_t"},
    {"name": "utilizationPct", "type": "uint8_t", "jni": "sat_u8"} // clamp jint to 0..255
  ],
  "jni": {"method": "leansysSseFrameScan", "ret": "jbyte"},       // optional
  "internal": true                            // optional: helper, never JNI-exported
}
```

The generator rejects duplicate symbols, duplicate JNI methods, duplicate
parameter names, unsupported types, and `sat_u8` on anything other than `uint8_t`.

## Changing a kernel signature

1. Change the Lean spec and regenerate `cabi/orb_kernel_unboxed.c`.
2. Update the entry in `kernel_abi.json` and run the generator.
3. Update the matching `external fun` in `OrbKernel.kt`. The lint compares its
   arity and Kotlin types with the manifest.
4. Rebuild the host test library
   `android_dashboard/app/src/test/resources/jni/liborb_kernel.so` and the
   Android `jniLibs` (NDK).

For example, `leansys_sse_frame_scan` takes six arguments. The last,
`lastByte`, is the final byte of the frame, so a frame can only be admitted
when it ends on a line terminator.

## Call-site lint

`scripts/lint_kernel_calls.py` scans the TypeScript, Kotlin and Swift clients.
Each rule targets a bug class that has shipped before:

| Rule | Rejects |
| --- | --- |
| `duplicated-count` | `gfmPipeRowAdmitted(..., cells.size, cells.size)`: passing the same count as `colCount` and `sepCols` makes the separator check vacuous |
| `synthetic-length` | fabricated spans (`len + 7`, `max(1, n)`, an offset-0 row with `rowLen == bufLen`) instead of real offsets in the source buffer |
| `stale-tag-kind` | tag-kind ranges that still admit kind 4 (`tagKind <= 4`, `1...4`, `in 1..4`); the kernel admits kinds 1..3 |
| `jni-arity` | a Kotlin `external fun` that disagrees with the manifest |

`scripts/test_kernel_abi.py` covers the manifest, the generator and every lint
rule. `.github/workflows/kernel-abi.yml` runs all of the above and compiles the
C-ABI and JNI into a host `.so`, then checks that it exports every manifest
symbol.
