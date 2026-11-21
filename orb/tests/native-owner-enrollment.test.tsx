import { render, fireEvent, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { NativeOwnerEnrollment } from "../src/NativeOwnerEnrollment";
import * as client from "../src/api";

afterEach(() => vi.restoreAllMocks());

it("uses the revision shown to the owner for enrollment and removal", async () => {
  let account = "";
  let revision = 3;
  const writes: unknown[] = [];
  vi.spyOn(client, "api").mockImplementation(async (path, options) => {
    if (path === "/api/native-owner-enrollments") return ["ledger-node"];
    expect(path).toBe("/api/native-owner-enrollments/ledger-node");
    if (options?.method === "PUT") {
      const update = JSON.parse(String(options.body));
      writes.push(update);
      account = update.account_id;
      revision++;
    }
    return { account_id: account, revision, launch_block: "native_owner_executor_unavailable" };
  });
  const ui = render(() => <NativeOwnerEnrollment account="ledger-account" />);
  fireEvent.click(await ui.findByRole("button", { name: "Enroll this account" }));
  expect((await ui.findByRole("status")).textContent).toContain("isolated workspace executor");
  fireEvent.click(await ui.findByRole("button", { name: "Remove enrollment" }));
  await waitFor(() => expect(writes).toEqual([
    { account_id: "ledger-account", expected_revision: 3 },
    { account_id: "", expected_revision: 4 }
  ]));
});

it("hides enrollment when the dev endpoint is unavailable", async () => {
  const read = vi.spyOn(client, "api").mockRejectedValue(new Error("not found"));
  const ui = render(() => <NativeOwnerEnrollment account="ledger-account" />);
  await waitFor(() => expect(read).toHaveBeenCalledTimes(1));
  expect(ui.queryByRole("button")).toBeNull();
});
