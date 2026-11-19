import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, expect, it, vi } from "vitest";
import { api, bumpConnectionVersion } from "../src/api";
import { AirVpnSettings } from "../src/AirVpnSettings";

vi.mock("../src/api", async () => {
  const { createSignal } = await import("solid-js");
  const [connectionVersion, bumpConnectionVersion] = createSignal(0);
  return { api: vi.fn(), connectionVersion, bumpConnectionVersion };
});

beforeEach(() => {
  vi.mocked(api).mockReset().mockResolvedValue({ devices: ["orb-nl"], api_key_configured: true });
});

it("submits a replacement key and clears it after Core acknowledges the save", async () => {
  render(() => <AirVpnSettings />);
  await screen.findByText("orb-nl");
  const input = screen.getByLabelText<HTMLInputElement>("AirVPN API key");
  fireEvent.input(input, { target: { value: "synthetic-test" } });
  fireEvent.click(screen.getByRole("button", { name: "Save key" }));
  await screen.findByText("API key saved.");
  expect(input.value).toBe("");
  expect(api).toHaveBeenCalledWith("/api/settings/airvpn", {
    method: "PUT", body: JSON.stringify({ api_key: "synthetic-test" }),
  });
});

it("discards an unsaved key when the connected Core changes", async () => {
  render(() => <AirVpnSettings />);
  await screen.findByText("orb-nl");
  const getKey = () => screen.getByLabelText<HTMLInputElement>("AirVPN API key");
  fireEvent.input(getKey(), { target: { value: "previous-instance" } });
  bumpConnectionVersion(v => v + 1);
  await waitFor(() => expect(getKey().value).toBe(""));
  expect(vi.mocked(api).mock.calls.every(([, init]) => !init)).toBe(true);
});
