import { expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { kernelAbi, initializeKernel } from "../src/orbKernelAbi";

it("refuses execution before initialization and rejects corrupt bytes", async () => {
  vi.resetModules();
  const fresh = await import("../src/orbKernelAbi");
  expect(() => fresh.kernelAbi.orb_relative_time_bucket(0n)).toThrow("not initialized");
  await expect(fresh.initializeKernel(new Uint8Array([0, 1, 2]))).rejects.toThrow("integrity");
  expect(() => fresh.kernelAbi.orb_relative_time_bucket(0n)).toThrow("not initialized");
  await fresh.initializeKernel(new Uint8Array(readFileSync("src/assets/orb_kernel.wasm")));
  expect(fresh.kernelAbi.orb_relative_time_bucket(0n)).toBe(0n);
});

it("keeps i64 and high i32 bits unsigned and rejects lossy input", async () => {
  // The high 32-bit sequence saturates and sets WASM i64's signed bit.
  expect(kernelAbi.orb_transcript_patch_step(0xffff_ffff, 0xffff_ffff, 0, 1)).toBe(0xffff_ffff_ffff_ffffn);
  expect(() => kernelAbi.orb_relative_time_bucket(Number.MAX_SAFE_INTEGER as unknown as bigint)).toThrow("UInt64");
  expect(() => kernelAbi.orb_relative_time_bucket(-1n)).toThrow("UInt64");
  expect(() => kernelAbi.orb_relative_time_bucket(1n << 64n)).toThrow("UInt64");
  expect(() => kernelAbi.orb_transcript_patch_step(1.5, 0, 0, 1)).toThrow("UInt32");
  expect(() => kernelAbi.orb_transcript_patch_step(0, 0, 256, 1)).toThrow("UInt8");
  await expect(initializeKernel(new Uint8Array([1]))).rejects.toThrow("integrity");
  // Failed replacement cannot corrupt the previously initialized instance.
  expect(kernelAbi.orb_relative_time_bucket(0n)).toBe(0n);
});
