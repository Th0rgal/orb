import { expect, it, vi } from "vitest";
import { ApiError, postWhileTurnRuns } from "../src/api";

const running = () => new ApiError(409, "REMOTE_JOB_STILL_RUNNING: mission m still owns job j on remote node 'babylon'; wait for it to finish or cancel the mission first");

it("re-posts a follow-up refused because a turn runs, until Core accepts it", async () => {
  const receipt = { id: "m1", queued: true, message_accepted: true };
  const post = vi.fn().mockRejectedValueOnce(running()).mockRejectedValueOnce(running()).mockResolvedValue(receipt);
  const sleep = vi.fn().mockResolvedValue(undefined);
  await expect(postWhileTurnRuns(post, () => false, sleep)).resolves.toBe(receipt);
  expect(post).toHaveBeenCalledTimes(3);
  expect(sleep).toHaveBeenCalledTimes(2);
});

it("still surfaces other refusals at once", async () => {
  const other = new ApiError(409, "REMOTE_RESUME_REQUIRES_REPLACEMENT: x");
  const post = vi.fn().mockRejectedValue(other);
  await expect(postWhileTurnRuns(post, () => false, async () => {})).rejects.toBe(other);
  expect(post).toHaveBeenCalledTimes(1);
});

it("stops when the connection changes", async () => {
  const post = vi.fn().mockRejectedValue(running());
  await expect(postWhileTurnRuns(post, () => true, async () => {})).rejects.toThrow("Connection changed");
});
