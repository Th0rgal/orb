import { beforeEach, expect, it, vi } from "vitest";
vi.mock("../src/api", () => ({ connectionVersion:()=>0, listQueuedMessages: vi.fn(async () => []) }));
vi.mock("../src/stream", () => ({ getMissionEventPage: vi.fn(), storedToStream: (row: unknown) => row }));
import { getMissionEventPage } from "../src/stream";
import { putTranscript, refreshTranscript } from "../src/missionCache";
beforeEach(() => vi.clearAllMocks());
it("fetches new history rather than returning a cached transcript", async () => {
  putTranscript("refresh-test", { items: [], stream: [] });
  vi.mocked(getMissionEventPage).mockResolvedValue({events:[],hasMore:false});
  await refreshTranscript("refresh-test");
  expect(getMissionEventPage).toHaveBeenCalledWith("refresh-test",{});
});
it("surfaces failed refresh instead of silently reporting stale data as refreshed", async () => {
  putTranscript("refresh-failure", { items: [], stream: [] });
  vi.mocked(getMissionEventPage).mockRejectedValue(new Error("offline"));
  await expect(refreshTranscript("refresh-failure")).rejects.toThrow("offline");
});
