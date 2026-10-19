import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createRoot } from "solid-js";
import { isRecord, jsonSignal, readJson, readString, removeKey, resetStorageCache, writeJson, writeString } from "../src/storage";

beforeEach(() => resetStorageCache());
afterEach(() => { vi.restoreAllMocks(); resetStorageCache(); });

it("round-trips JSON and returns the fallback for missing, malformed or invalid values", () => {
  expect(readJson("k", { a: 0 })).toEqual({ a: 0 });
  expect(writeJson("k", { a: 1 })).toBe(true);
  expect(readJson("k", { a: 0 })).toEqual({ a: 1 });
  localStorage.setItem("bad", "{oops");
  expect(readJson("bad", "fallback")).toBe("fallback");
  localStorage.setItem("arr", "[1]");
  expect(readJson("arr", {}, isRecord)).toEqual({});
  localStorage.setItem("null", "null");
  expect(readJson("null", 7)).toBe(7);
});

it("parses once per stored text and notices outside changes", () => {
  const parse = vi.spyOn(JSON, "parse");
  localStorage.setItem("k", JSON.stringify({ n: 1 }));
  readJson("k", {}); readJson("k", {}); readJson("k", {});
  expect(parse).toHaveBeenCalledTimes(1);
  localStorage.setItem("k", JSON.stringify({ n: 2 }));
  expect(readJson("k", {})).toEqual({ n: 2 });
});

it("never throws when storage refuses a write and keeps the value for this session", () => {
  vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new DOMException("full", "QuotaExceededError"); });
  expect(() => writeJson("k", { kept: true })).not.toThrow();
  expect(writeJson("k", { kept: true })).toBe(false);
  expect(readJson("k", null)).toEqual({ kept: true });
  expect(writeString("s", "value")).toBe(false);
  expect(readString("s")).toBe("value");
});

it("survives a getItem that throws", () => {
  vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("denied"); });
  expect(readJson("k", 3)).toBe(3);
  expect(readString("k")).toBeNull();
});

it("persists a jsonSignal and removes keys", () => {
  createRoot(dispose => {
    const [value, setValue] = jsonSignal("sig", 1);
    setValue(2);
    expect(value()).toBe(2);
    expect(localStorage.getItem("sig")).toBe("2");
    dispose();
  });
  removeKey("sig");
  expect(readJson("sig", 0)).toBe(0);
});
