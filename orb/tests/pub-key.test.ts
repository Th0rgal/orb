import { afterEach, expect, it, vi } from "vitest";
import { readPalomaPub } from "../src/pubKey";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

it("keeps the key unavailable in a packaged client without a native key", async () => {
  vi.stubEnv("DEV", false);
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  expect(await readPalomaPub()).toBe("");
  expect(fetch).not.toHaveBeenCalled();
});

it("ignores the HTML page returned for an unknown preview route", async () => {
  vi.stubEnv("DEV", true);
  vi.stubGlobal("fetch", async () => new Response("<!doctype html>", { headers: { "Content-Type": "text/html" } }));
  expect(await readPalomaPub()).toBe("");
});

it("reads a plain text key from the Vite preview endpoint", async () => {
  vi.stubEnv("DEV", true);
  vi.stubGlobal("fetch", async () => new Response("ssh-ed25519 test\n", { headers: { "Content-Type": "text/plain; charset=utf-8" } }));
  expect(await readPalomaPub()).toBe("ssh-ed25519 test");
});
