import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api, bumpConnectionVersion } from "../src/api";
import { airVpnSessionSummary, parseAirVpnFilenameHint, parseAirVpnStatus } from "../src/airVpnModel";
import { AirVpnSettings } from "../src/AirVpnSettings";

const fixture = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "airvpn-settings.json"),
    "utf8",
  ),
);

vi.mock("../src/api", async () => {
  const { createSignal } = await import("solid-js");
  const [connectionVersion, bumpConnectionVersion] = createSignal(0);
  return {
    api: vi.fn(),
    connectionVersion,
    bumpConnectionVersion,
    isAdminUser: () => true,
    isConnected: () => true,
    listProviders: vi.fn().mockResolvedValue([]),
  };
});

describe("shared/orb-spec/fixtures/airvpn-settings.json", () => {
  for (const c of fixture.status) {
    it(`status: ${c.name}`, () => {
      const got = parseAirVpnStatus(c.input);
      if (c.expected === null) {
        expect(got).toBeNull();
      } else {
        expect(got).not.toBeNull();
        expect({
          apiKeyConfigured: got!.apiKeyConfigured,
          sessionLimit: got!.sessionLimit,
          profiles: got!.profiles,
          activeTunnelsCount: got!.activeTunnels.length,
        }).toEqual(c.expected);
      }
    });
  }

  for (const c of fixture.filename_hints) {
    it(`filename hint: ${c.filename}`, () => {
      expect(parseAirVpnFilenameHint(c.filename)).toEqual(c.expected);
    });
  }

  for (const c of fixture.session_summaries) {
    it(`session summary: ${c.name}`, () => {
      expect(airVpnSessionSummary(c.activeSessions, c.orbTunnels, c.sessionLimit)).toBe(c.expected);
    });
  }
});

describe("AirVpnSettings page", () => {
  beforeEach(() => {
    vi.mocked(api).mockReset().mockResolvedValue({
      api_key_configured: true,
      session_limit: 5,
      devices: ["orb-nl"],
      profiles: [{ device: "orb-nl", country: "NL", server: "Alcyone" }],
      active_tunnels: [{ device: "orb-nl", country: "NL", server: "Alcyone", exits: ["213.152.161.155"], accounts: 1 }],
    });
  });

  it("submits a replacement key via dialog and clears it after Core acknowledges the save", async () => {
    render(() => <AirVpnSettings />);
    await screen.findByText("NL · Alcyone");
    expect(screen.getByText(/213\.152\.161\.155/)).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "Update key…" }));
    const input = screen.getByLabelText<HTMLInputElement>("AirVPN API key");
    fireEvent.input(input, { target: { value: "synthetic-test" } });
    fireEvent.click(screen.getByRole("button", { name: "Save key" }));

    await screen.findByText("API key saved.");
    expect(screen.queryByLabelText("AirVPN API key")).toBeNull();
    expect(api).toHaveBeenCalledWith("/api/settings/airvpn", {
      method: "PUT",
      body: JSON.stringify({ api_key: "synthetic-test" }),
    });
  });

  it("discards an unsaved key draft when the connected Core changes", async () => {
    render(() => <AirVpnSettings />);
    await screen.findByText("NL · Alcyone");
    fireEvent.click(screen.getByRole("button", { name: "Update key…" }));
    const input = screen.getByLabelText<HTMLInputElement>("AirVPN API key");
    fireEvent.input(input, { target: { value: "previous-instance" } });

    bumpConnectionVersion((v) => v + 1);
    await waitFor(() => expect(screen.queryByLabelText("AirVPN API key")).toBeNull());
    expect(vi.mocked(api).mock.calls.every(([, init]) => !init)).toBe(true);
  });

  it("pre-fills country, server, and device from AirVPN filename and deletes profiles with confirmation", async () => {
    render(() => <AirVpnSettings />);
    await screen.findByText("NL · Alcyone");

    fireEvent.click(screen.getByRole("button", { name: "Import profile…" }));
    const fileInput = screen.getByLabelText<HTMLInputElement>("WireGuard profile");
    const conf = "[Interface]\nDNS = 10.2.0.1\nAddress = 10.2.0.2/32\nPrivateKey = fixture\n";
    const file = new File([conf], "AirVPN_CH-Zurich_Kitalpha_UDP-1637.conf", { type: "text/plain" });
    Object.defineProperty(file, "text", { value: () => Promise.resolve(conf) });
    fireEvent.change(fileInput, { target: { files: [file] } });

    await waitFor(() => {
      expect(screen.getByLabelText<HTMLInputElement>("Server country code").value).toBe("CH");
      expect(screen.getByLabelText<HTMLInputElement>("AirVPN server name").value).toBe("Kitalpha");
      expect(screen.getByLabelText<HTMLInputElement>("Device name").value).toBe("orb-ch-kitalpha");
    });

    fireEvent.click(screen.getByRole("button", { name: "Import profile" }));
    await screen.findByText("Device profile saved.");
    expect(api).toHaveBeenCalledWith("/api/settings/airvpn", {
      method: "PUT",
      body: JSON.stringify({
        device_id: "orb-ch-kitalpha",
        country: "CH",
        server: "Kitalpha",
        profile: conf,
      }),
    });

    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    fireEvent.click(await screen.findByRole("button", { name: "Remove profile" }));
    await screen.findByText("Removed profile orb-nl.");
    expect(api).toHaveBeenCalledWith("/api/settings/airvpn", {
      method: "DELETE",
      body: JSON.stringify({ device_id: "orb-nl" }),
    });
  });
});
