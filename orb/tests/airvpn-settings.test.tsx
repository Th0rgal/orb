import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api, bumpConnectionVersion, listProviders } from "../src/api";
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
  class ApiError extends Error {
    constructor(public status: number, public detail: string) { super(`${status}: ${detail}`); }
  }
  return {
    api: vi.fn(),
    ApiError,
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

  it("refreshes Account routes after profile removal and clears stale routes on reread failure", async () => {
    vi.mocked(listProviders).mockResolvedValue([
      { id: "acct-1", name: "Claude Work", provider_type: "anthropic", has_credentials: true },
    ]);
    let removed = false;
    let failRouteRead = false;
    vi.mocked(api).mockImplementation(async (path: string, init?: RequestInit) => {
      if (path === "/api/settings/airvpn") {
        if (init?.method === "DELETE") {
          removed = true;
          return { ok: true };
        }
        return {
          api_key_configured: true,
          session_limit: 5,
          devices: removed ? [] : ["orb-nl"],
          profiles: removed ? [] : [{ device: "orb-nl", country: "NL", server: "Alcyone" }],
          active_tunnels: removed ? [] : [{ device: "orb-nl", country: "NL", server: "Alcyone", exits: ["213.152.161.155"], accounts: 1 }],
        };
      }
      if (path === "/api/ai/providers/acct-1/vpn") {
        if (failRouteRead) throw new Error("Core unavailable");
        if (removed) {
          return {
            mode: "vpn", country: "NL", countries: [], can_configure: true,
            status: "blocked", reason: "vpn_profile_unavailable", message: "No AirVPN profile is imported for NL.",
          };
        }
        return {
          mode: "vpn", country: "NL", countries: ["NL"], can_configure: true,
          status: "verified", server: "Alcyone", exits: ["213.152.161.155"],
        };
      }
      return {};
    });

    render(() => <AirVpnSettings />);
    await screen.findByText("Verified exit · Alcyone · 213.152.161.155");

    // Removing the profile must refresh Account routes immediately.
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    fireEvent.click(await screen.findByRole("button", { name: "Remove profile" }));
    await screen.findByText("No AirVPN profile is imported for NL.");
    expect(screen.queryByText(/Verified exit/)).toBeNull();

    // A failed focus reread must clear the confirmed route and show Retry.
    failRouteRead = true;
    window.dispatchEvent(new Event("focus"));
    const retry = await screen.findByRole("button", { name: "Retry connection settings" });
    expect(screen.queryByLabelText("Route for Claude Work")).toBeNull();

    failRouteRead = false;
    fireEvent.click(retry);
    await screen.findByText("No AirVPN profile is imported for NL.");
  });

  it("keeps unconfirmed rows visible under VPN-routed filter and prevents bulk refresh from clobbering a concurrent save", async () => {
    vi.mocked(listProviders).mockResolvedValue([
      { id: "acct-vpn", name: "Claude VPN", provider_type: "anthropic", has_credentials: true },
      { id: "acct-direct", name: "Codex Direct", provider_type: "openai", has_credentials: true },
    ]);
    let failVpnRead = false;
    let resolveBulkDirect!: (v: unknown) => void;
    let directReads = 0;
    let directSavedCountry = "";
    vi.mocked(api).mockImplementation(async (path: string, init?: RequestInit) => {
      if (path === "/api/settings/airvpn") {
        return {
          api_key_configured: true,
          session_limit: 5,
          devices: ["orb-nl"],
          profiles: [{ device: "orb-nl", country: "NL", server: "Alcyone" }],
          active_tunnels: [{ device: "orb-nl", country: "NL", server: "Alcyone", exits: ["213.152.161.155"], accounts: 1 }],
        };
      }
      if (path === "/api/ai/providers/acct-vpn/vpn") {
        if (failVpnRead) throw new Error("Core disconnected");
        return {
          mode: "vpn", country: "NL", countries: ["NL"], can_configure: true,
          status: "verified", server: "Alcyone", exits: ["213.152.161.155"],
        };
      }
      if (path === "/api/ai/providers/acct-direct/vpn") {
        if (init?.method === "PUT") {
          directSavedCountry = "NL";
          return {
            mode: "vpn", country: "NL", countries: ["NL"], can_configure: true,
            status: "verified", server: "Alcyone", exits: ["213.152.161.155"],
          };
        }
        directReads += 1;
        if (directReads === 2) {
          return await new Promise((resolve) => { resolveBulkDirect = resolve; });
        }
        return directSavedCountry
          ? { mode: "vpn", country: directSavedCountry, countries: ["NL"], can_configure: true, status: "verified", server: "Alcyone", exits: ["213.152.161.155"] }
          : { mode: "direct", countries: ["NL"], can_configure: true, status: "direct" };
      }
      return {};
    });

    render(() => <AirVpnSettings />);
    await screen.findByText("Verified exit · Alcyone · 213.152.161.155");

    // Switch filter to "VPN routed only" and fail reread on acct-vpn: row stays visible with Retry and never claims 0 VPN accounts.
    fireEvent.change(screen.getByLabelText("Filter account routes"), { target: { value: "vpn" } });
    failVpnRead = true;
    window.dispatchEvent(new Event("focus"));
    const retry = await screen.findByRole("button", { name: "Retry connection settings" });
    expect(screen.queryByText("0 accounts routed via AirVPN")).toBeNull();
    expect(screen.queryByText("No accounts currently use AirVPN")).toBeNull();
    expect(screen.getByText("Could not confirm 1 account route")).toBeTruthy();

    // Recover acct-vpn via single-row Retry (does not trigger bulk read of acct-direct).
    failVpnRead = false;
    fireEvent.click(retry);
    await screen.findByText("Verified exit · Alcyone · 213.152.161.155");
    expect(directReads).toBe(1);

    // Switch back to all, start a bulk refresh via admin API key save, and save NL on acct-direct while bulk read is in flight.
    fireEvent.change(screen.getByLabelText("Filter account routes"), { target: { value: "all" } });
    fireEvent.click(screen.getByRole("button", { name: "Update key…" }));
    fireEvent.input(screen.getByLabelText("AirVPN API key"), { target: { value: "synthetic-key" } });
    fireEvent.click(screen.getByRole("button", { name: "Save key" }));
    await waitFor(() => expect(directReads).toBe(2));

    const directSelect = screen.getByLabelText<HTMLSelectElement>("Route for Codex Direct");
    fireEvent.change(directSelect, { target: { value: "NL" } });
    await waitFor(() => expect(directSelect.value).toBe("NL"));

    // Resolve the stale in-flight bulk read with Direct; newer NL selection must NOT be overwritten.
    resolveBulkDirect({ mode: "direct", countries: ["NL"], can_configure: true, status: "direct" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(directSelect.value).toBe("NL");
  });
});
