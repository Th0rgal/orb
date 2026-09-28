import { describe, it, expect, beforeEach, vi } from "vitest";
import { cachePeek, cachePut, cacheLoad, cachePrefetch, cacheRemember, cacheRecents, cacheReset, cacheBusy } from "../src/pageCache";

beforeEach(() => {
  cacheReset();
  sessionStorage.clear();
});

describe("pageCache", () => {
  it("returns a put value and rotates LRU on peek", () => {
    cachePut("a", 1);
    cachePut("b", 2);
    expect(cachePeek("a")).toBe(1);
    expect(cachePeek("b")).toBe(2);
  });

  it("joins in-flight loads and caches the result", async () => {
    let n = 0;
    const load = () => {
      n++;
      return Promise.resolve("ok");
    };
    const a = cacheLoad("k", load);
    const b = cacheLoad("k", load);
    expect(cacheBusy("k")).toBe(true);
    expect(await a).toBe("ok");
    expect(await b).toBe("ok");
    expect(n).toBe(1);
    expect(cachePeek("k")).toBe("ok");
  });

  it("keeps the previous hit when a refresh fails", async () => {
    cachePut("k", "old");
    await expect(cacheLoad("k", () => Promise.reject(new Error("no")))).rejects.toThrow("no");
    expect(cachePeek("k")).toBe("old");
  });

  it("bounds retained payload bytes as well as entry count", () => {
    const value="x".repeat(9*1024*1024);
    cachePut("first",value);cachePut("second",value);
    expect(cachePeek("first")).toBeUndefined();
    expect(cachePeek("second")).toBe(value);
  });

  it("does not repopulate a reset cache from an old request", async () => {
    let finish!:(value:string)=>void;
    const old=cacheLoad("key",()=>new Promise<string>(resolve=>finish=resolve));
    cacheReset();cachePut("key","new");finish("old");
    await expect(old).rejects.toThrow("Connection changed");
    expect(cachePeek("key")).toBe("new");
  });

  it("remembers recent pages", () => {
    cacheRemember("m:1");
    cacheRemember("m:2");
    cacheRemember("m:1");
    expect(cacheRecents()).toEqual(["m:1", "m:2"]);
  });

  it("does not enqueue a prefetch for a warm key", async () => {
    cachePut("warm", 1);
    const run = vi.fn(async () => 2);
    cachePrefetch("warm", run);
    await new Promise((r) => setTimeout(r, 50));
    expect(run).not.toHaveBeenCalled();
  });
});
