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
FREESTANDING_FLAGS=()
if [ -n "$NDK" ]; then
  BIN="$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin | head -1)"
elif command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; then
  if [ -x /usr/bin/clang ]; then
    BIN=/usr/bin
  else
    BIN="$(dirname "$(command -v clang)")"
  fi
  JNI_SHIM_DIR="$(mktemp -d)"
  trap 'rm -rf "$JNI_SHIM_DIR"' EXIT
  cat << 'EOF' > "$JNI_SHIM_DIR/jni.h"
#ifndef _FREESTANDING_JNI_H_
#define _FREESTANDING_JNI_H_
#include <stdint.h>
typedef uint8_t jboolean;
typedef int8_t jbyte;
typedef uint16_t jchar;
typedef int16_t jshort;
typedef int32_t jint;
typedef int64_t jlong;
typedef float jfloat;
typedef double jdouble;
typedef void *JNIEnv;
typedef void *jclass;
typedef void *jobject;
#define JNIEXPORT __attribute__((visibility("default")))
#define JNICALL
#endif
EOF
  FREESTANDING_FLAGS=(-ffreestanding -fuse-ld=lld -nostdlib "-I$JNI_SHIM_DIR")
else
  echo "Android NDK or clang+lld not found (set ANDROID_NDK_HOME)" >&2
  exit 1
fi

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
  "$BIN/clang" --target="$target" ${arch_flags[@]+"${arch_flags[@]}"} ${FREESTANDING_FLAGS[@]+"${FREESTANDING_FLAGS[@]}"} -O2 -fPIC -shared \
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

HOST_TEST_SO=android_dashboard/app/src/test/resources/jni/liborb_kernel.so
if ! $check && [ -d "$(dirname "$HOST_TEST_SO")" ]; then
  cp "$out/x86_64/liborb_kernel.so" "$HOST_TEST_SO"
fi
if [ -f "$HOST_TEST_SO" ]; then
  check_page_align_16k "$HOST_TEST_SO"
  diff <(abi_syms "$JNILIBS/x86_64/liborb_kernel.so") <(abi_syms "$HOST_TEST_SO") \
    || { echo "$HOST_TEST_SO exports differ from x86_64 jniLibs" >&2; exit 1; }
fi

if $check; then
  [ "$(cat android_dashboard/app/src/main/jni/liborb_kernel.so.sha256)" = "$(stamp)" ] \
    || { echo "$JNILIBS was built from different kernel/JNI sources; run $0" >&2; exit 1; }
  echo "jniLibs built from current sources"
else
  stamp > android_dashboard/app/src/main/jni/liborb_kernel.so.sha256
fi
