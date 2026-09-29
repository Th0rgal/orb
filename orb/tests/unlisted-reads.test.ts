import { beforeEach, expect, test, vi } from "vitest";
import { forgetUnlistedReads, unlistedCoreState } from "../src/localOrigins";
import type { Mission } from "../src/api";

const mission = (id: string, status: string) => ({ id, status, title: id }) as unknown as Mission;

beforeEach(() => { forgetUnlistedReads(); vi.useRealTimers(); });

test("a conversation outside the list is not read again at every refresh", async () => {
  vi.useFakeTimers();
  const read = vi.fn(async (id: string) => {
    if (id === "gone") throw new Error("404");
    return mission(id, id === "live" ? "active" : "completed");
  });
  const local = [mission("done", "completed"), mission("live", "completed"), mission("gone", "completed")];

  expect((await unlistedCoreState(local, [], read)).map(m => m.id)).toEqual(["done", "live"]);
  expect(read).toHaveBeenCalledTimes(3);

  vi.advanceTimersByTime(5_000);
  // The known state is still reported, without a request.
  expect((await unlistedCoreState(local, [], read)).map(m => m.id)).toEqual(["done", "live"]);
  expect(read).toHaveBeenCalledTimes(3);

  vi.advanceTimersByTime(30_000);
  await unlistedCoreState(local, [], read);
  expect(read.mock.calls.slice(3).map(call => call[0])).toEqual(["live"]);

  vi.advanceTimersByTime(10 * 60_000);
  await unlistedCoreState(local, [], read);
  expect(read.mock.calls.slice(4).map(call => call[0]).sort()).toEqual(["done", "gone", "live"]);
});
