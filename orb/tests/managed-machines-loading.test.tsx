import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { setConnection } from "../src/api";
import { ManagedMachines } from "../src/ManagedMachines";
import * as model from "../src/managedMachineModel";

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

it("shows loading and allows a failed first provider request to be retried", async () => {
  setConnection("https://orb.example", "test");
  let fail!: (error: Error) => void;
  const load = vi.spyOn(model, "listManagedMachines")
    .mockImplementationOnce(() => new Promise((_resolve, reject) => { fail = reject; }))
    .mockResolvedValueOnce(null);
  render(() => <ManagedMachines />);
  expect(screen.getByRole("status", { name: "Loading machine providers" })).toBeTruthy();
  fail(new Error("Provider inventory unavailable"));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("Provider inventory unavailable"));
  expect(screen.queryByLabelText("Loading machine providers")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(load).toHaveBeenCalledTimes(2));
  await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  expect(screen.queryByLabelText("Loading machine providers")).toBeNull();
});
