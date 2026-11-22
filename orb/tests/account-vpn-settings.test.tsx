import { fireEvent, render, screen } from "@solidjs/testing-library";
import { expect, it, vi } from "vitest";
import { api } from "../src/api";
import { AccountVpnSettings } from "../src/AccountVpnSettings";

vi.mock("../src/api", () => ({ api: vi.fn(), connectionVersion: () => 1 }));

it("saves only the expanded account and retries a saved route when a slot opens", async () => {
  const base = { can_configure: true, countries: ["NL"] };
  vi.mocked(api).mockResolvedValueOnce({ ...base, mode: "direct", status: "direct" })
    .mockResolvedValueOnce({ ...base, mode: "vpn", country: "NL", status: "blocked", message: "All five AirVPN sessions are in use." })
    .mockResolvedValueOnce({ ...base, mode: "vpn", country: "NL", status: "verified", server: "west", exits: ["192.0.2.20"] });
  render(() => <AccountVpnSettings account="chat/a" />);
  const select = await screen.findByLabelText("Account connection");
  fireEvent.change(select, { target: { value: "NL" } });
  await screen.findByText("All five AirVPN sessions are in use.");
  expect(api).toHaveBeenLastCalledWith("/api/ai/providers/chat%2Fa/vpn", {
    method: "PUT", body: JSON.stringify({ mode: "vpn", country: "NL" }),
  });
  fireEvent.click(screen.getByRole("button", { name: "Retry verification" }));
  await screen.findByText("Verified exit · west · 192.0.2.20");
});

it("shows why the selected account cannot route and rereads it after reconnection", async () => {
  const direct = { countries: ["NL"], mode: "direct", status: "direct" };
  vi.mocked(api).mockClear().mockResolvedValueOnce({ ...direct, can_configure: false,
    configuration_message: "Check the account connection, then refresh." })
    .mockResolvedValueOnce({ ...direct, can_configure: true });
  render(() => <AccountVpnSettings account="second" />);
  await screen.findByText("Check the account connection, then refresh.");
  expect((screen.getByLabelText("Account connection") as HTMLSelectElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Refresh connection settings" }));
  await vi.waitFor(() => expect((screen.getByLabelText("Account connection") as HTMLSelectElement).disabled).toBe(false));
  expect(vi.mocked(api).mock.calls).toEqual(Array(2).fill(["/api/ai/providers/second/vpn", undefined]));
});

it("rereads a pending exit on visibility and stops once verified", async () => {
  const route = { can_configure: true, countries: ["NL"], mode: "vpn", country: "NL" };
  vi.mocked(api).mockClear().mockResolvedValueOnce({ ...route, status: "blocked",
    reason: "vpn_awaiting_verification", message: "Waiting for exit verification." })
    .mockResolvedValueOnce({ ...route, status: "verified", server: "west", exits: ["192.0.2.20"] });
  render(() => <AccountVpnSettings account="pending" />);
  await screen.findByText("Waiting for exit verification.");
  document.dispatchEvent(new Event("visibilitychange"));
  await screen.findByText("Verified exit · west · 192.0.2.20");
  document.dispatchEvent(new Event("visibilitychange"));
  await Promise.resolve();
  expect(vi.mocked(api).mock.calls).toEqual(Array(2).fill(["/api/ai/providers/pending/vpn", undefined]));
});

it("keeps a newer Direct selection when an older verification read finishes", async () => {
  const pending = { mode: "vpn", country: "NL", countries: ["NL"], can_configure: true,
    status: "blocked", reason: "vpn_awaiting_verification", message: "Waiting for exit verification." };
  let finishRead!: (r: unknown) => void;
  vi.mocked(api).mockClear().mockResolvedValueOnce(pending)
    .mockImplementationOnce(() => new Promise(resolve => { finishRead = resolve; }))
    .mockResolvedValueOnce({ mode: "direct", countries: ["NL"], status: "direct", can_configure: true });
  render(() => <AccountVpnSettings account="switching" />);
  await screen.findByText("Waiting for exit verification.");
  document.dispatchEvent(new Event("visibilitychange"));
  await vi.waitFor(() => expect(api).toHaveBeenCalledTimes(2));
  const select = screen.getByLabelText("Account connection") as HTMLSelectElement;
  fireEvent.change(select, { target: { value: "" } });
  await vi.waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  finishRead({ ...pending, status: "verified", reason: undefined, server: "west" });
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(select.value).toBe("");
  expect(screen.queryByText(/Verified exit/)).toBeNull();
});
