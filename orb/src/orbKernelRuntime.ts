// This module owns initialization. No caller can execute a behavioral fallback.
let instance: WebAssembly.Instance | undefined;
let scratchBaseOffset = 65_536;
const WASM_MAX_SCRATCH_EXTRA_BYTES = 1_048_576;

export async function loadKernel(bytes: Uint8Array, sha256: string, arities: Record<string, number>): Promise<void> {
  const buffer = new Uint8Array(bytes).buffer;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", buffer));
  if (Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("") !== sha256) {
    throw new Error("Shared kernel integrity check failed");
  }
  const module = await WebAssembly.compile(buffer);
  if (WebAssembly.Module.imports(module).length) throw new Error("Shared kernel must have no imports");
  const exports = WebAssembly.Module.exports(module);
  const functions = exports.filter(entry => entry.kind === "function");
  if (functions.length !== Object.keys(arities).length || functions.some(entry => !(entry.name in arities)) ||
      exports.some(entry => entry.kind !== "function" && !(entry.name === "memory" && entry.kind === "memory"))) {
    throw new Error("Shared kernel exports differ from its manifest");
  }
  const candidate = await WebAssembly.instantiate(module);
  for (const [name, arity] of Object.entries(arities)) {
    const fn = candidate.exports[name];
    if (typeof fn !== "function" || fn.length !== arity) throw new Error(`Shared kernel ABI mismatch: ${name}`);
  }
  const candidateMem = candidate.exports.memory;
  scratchBaseOffset = candidateMem instanceof WebAssembly.Memory
    ? Math.max(WASM_PAGE_BYTES, candidateMem.buffer.byteLength)
    : WASM_PAGE_BYTES;
  instance = candidate;
}

export function word(value: number | bigint, bits: 8 | 32 | 64): number | bigint {
  if (bits === 64) {
    if (typeof value !== "bigint" || value < 0n || value > 0xffff_ffff_ffff_ffffn) throw new RangeError("Expected UInt64 bigint");
  } else if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > (bits === 8 ? 255 : 0xffff_ffff)) {
    throw new RangeError(`Expected UInt${bits} number`);
  }
  return value;
}

export function callKernel(name: string, args: (number | bigint)[]): number | bigint {
  if (!instance) throw new Error("Shared kernel is not initialized");
  return (instance.exports[name] as (...args: (number | bigint)[]) => number | bigint)(...args);
}

export function result32(raw: number | bigint): number {
  if (typeof raw !== "number") throw new TypeError("Expected WASM i32 result");
  return raw >>> 0;
}

export function result64(raw: number | bigint): bigint {
  if (typeof raw !== "bigint") throw new TypeError("Expected WASM i64 result");
  return BigInt.asUintN(64, raw);
}

export function bindKernelFn<T extends (number | bigint)[]>(
  name: string,
  widths: readonly (8 | 32 | 64)[],
  ret64: boolean,
): (...args: T) => number | bigint {
  return (...args: T) => {
    for (let i = 0; i < widths.length; i++) word(args[i], widths[i]);
    const raw = callKernel(name, args);
    return ret64 ? result64(raw) : result32(raw);
  };
}

const WASM_PAGE_BYTES = 65_536;

export function kernelScratchBaseOffset(): number {
  if (!instance) throw new Error("Shared kernel is not initialized");
  return scratchBaseOffset;
}

const SLICE_STEP_OUT_BYTES = 32;

export function ensureKernelLinearScratch(minExtraBytes: number): {
  memory: WebAssembly.Memory;
  inOffset: number;
  outOffset: number;
} {
  if (!instance) throw new Error("Shared kernel is not initialized");
  const mem = instance.exports.memory;
  if (!(mem instanceof WebAssembly.Memory)) {
    throw new Error("Shared kernel does not export linear memory");
  }
  const outOffset = scratchBaseOffset;
  const inOffset = scratchBaseOffset + SLICE_STEP_OUT_BYTES;
  const boundedExtra = Math.min(WASM_MAX_SCRATCH_EXTRA_BYTES, Math.max(0, Math.ceil(minExtraBytes)));
  const needed = inOffset + boundedExtra;
  if (needed > mem.buffer.byteLength) {
    const extraPages = Math.ceil((needed - mem.buffer.byteLength) / WASM_PAGE_BYTES);
    mem.grow(extraPages);
  }
  return { memory: mem, inOffset, outOffset };
}

