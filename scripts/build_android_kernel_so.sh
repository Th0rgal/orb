#!/usr/bin/env bash
# Build android_dashboard's liborb_kernel.so (arm64-v8a, x86_64) with the NDK
# from the vendored kernel C and the JNI glue, and record the source hash the
# libraries were built from in jni/liborb_kernel.so.sha256.
#
#   scripts/build_android_kernel_so.sh            # rebuild the committed libraries
#   scripts/build_android_kernel_so.sh --check    # CI: stamp matches sources, fresh
#                                                 # NDK build exports the same ABI
set -euo pipefail
cd "$(dirname "$0")/.."

JNILIBS=android_dashboard/app/src/main/jniLibs
SOURCES=(shared/orb-spec/cabi/orb_kernel.h shared/orb-spec/cabi/orb_kernel_unboxed.c
         android_dashboard/app/src/main/jni/orb_kernel_jni.c)
ABIS=(arm64-v8a:aarch64-linux-android24 x86_64:x86_64-linux-android24)

NDK="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [ -z "$NDK" ] && [ -d "$HOME/Library/Android/sdk/ndk" ]; then
  NDK="$(ls -d "$HOME"/Library/Android/sdk/ndk/* | sort -V | tail -1)"
fi
[ -n "$NDK" ] || { echo "Android NDK not found (set ANDROID_NDK_HOME)" >&2; exit 1; }
BIN="$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin | head -1)"

stamp() { cat "${SOURCES[@]}" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
abi_syms() { "$BIN/llvm-nm" -D --defined-only -j "$1" | grep -E '^(orb_|leansys_|Java_)' | sort; }
check_page_align_16k() {
  local so="$1"
  local aligns
  aligns="$("$BIN/llvm-readelf" -l "$so" | awk '$1 == "LOAD" { print $NF }')"
  [ -n "$aligns" ] || { echo "$so: no ELF LOAD segments found" >&2; exit 1; }
  for a in $aligns; do
    [ "$a" = "0x4000" ] || { echo "$so: expected 16 KB LOAD alignment 0x4000, got $a" >&2; exit 1; }
  done
}

check=false
[ "${1:-}" = "--check" ] && check=true
out="$JNILIBS"
$check && out="$(mktemp -d)"

for pair in "${ABIS[@]}"; do
  abi="${pair%%:*}"; target="${pair#*:}"
  mkdir -p "$out/$abi"
  arch_flags=()
  if [ "$abi" = "arm64-v8a" ]; then
    arch_flags=(-march=armv8.2-a+lse+dotprod+fp16)
  fi
  "$BIN/clang" --target="$target" ${arch_flags[@]+"${arch_flags[@]}"} -O2 -fPIC -shared \
    -Wl,-z,max-page-size=16384 -Wl,-s -Wl,--build-id=none \
    -Iandroid_dashboard/app/src shared/orb-spec/cabi/orb_kernel_unboxed.c \
    android_dashboard/app/src/main/jni/orb_kernel_jni.c -o "$out/$abi/liborb_kernel.so"
  check_page_align_16k "$out/$abi/liborb_kernel.so"
  if $check; then
    check_page_align_16k "$JNILIBS/$abi/liborb_kernel.so"
    diff <(abi_syms "$JNILIBS/$abi/liborb_kernel.so") <(abi_syms "$out/$abi/liborb_kernel.so") \
      || { echo "$JNILIBS/$abi/liborb_kernel.so exports differ; run $0" >&2; exit 1; }
  fi
  echo "$abi: $(abi_syms "$out/$abi/liborb_kernel.so" | wc -l | tr -d ' ') ABI exports (16 KB LOAD align 0x4000 verified)"
done

if $check; then
  [ "$(cat android_dashboard/app/src/main/jni/liborb_kernel.so.sha256)" = "$(stamp)" ] \
    || { echo "$JNILIBS was built from different kernel/JNI sources; run $0" >&2; exit 1; }
  echo "jniLibs built from current sources"
else
  stamp > android_dashboard/app/src/main/jni/liborb_kernel.so.sha256
fi
