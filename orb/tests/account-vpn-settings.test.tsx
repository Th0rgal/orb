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
