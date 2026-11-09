import { cleanup, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { UsersSettings } from "../src/UsersSettings";
import { applyAuthMeResponse, resetCurrentUserState } from "../src/accountAdmin";
import { clearConnection, setConnection } from "../src/api";

describe("UsersSettings", () => {
  afterEach(() => {
    cleanup();
    localStorage.clear();
    clearConnection();
    resetCurrentUserState();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("displays @admin · Admin · You without 404 or empty state against a legacy single-tenant Core", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.endsWith("/api/admin/users")) {
          return new Response("Not Found", { status: 404 });
        }
        if (url.endsWith("/api/auth/me")) {
          return new Response("Not Found", { status: 404 });
        }
        if (url.endsWith("/api/auth/status")) {
          return new Response(
            JSON.stringify({
              auth_mode: "single_tenant",
              password_source: "environment",
              dev_mode: false,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
      }),
    );

    setConnection("https://orbcore.example.com", "tok-single-tenant");
    applyAuthMeResponse({ auth_mode: "single_tenant", dev_mode: false });

    render(() => <UsersSettings />);

    await waitFor(() => {
      expect(screen.getByText("@admin")).toBeTruthy();
    });

    expect(screen.getByText(/Single-tenant administrator/)).toBeTruthy();
    expect(screen.getByText(/· Admin · You/)).toBeTruthy();
    expect(screen.queryByText("Couldn’t load users")).toBeNull();
    expect(screen.queryByText("No user accounts yet")).toBeNull();
    expect(screen.getByRole("button", { name: "Add user…" }).hasAttribute("disabled")).toBe(true);
  });

  it("suppresses false empty state when /api/admin/users fails with a transient 502 error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.endsWith("/api/admin/users")) {
          return new Response(JSON.stringify({ error: "Upstream gateway unavailable" }), {
            status: 502,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
      }),
    );

    setConnection("https://orbcore.example.com", "tok-multi");
    applyAuthMeResponse({
      auth_mode: "multi_user",
      user: {
        id: "u-admin",
        username: "admin",
        role: "admin",
        unix_username: null,
        daily_spend_cap_cents: null,
        spent_today_cents: 0,
      },
      capabilities: {
        can_manage_users: true,
        can_use_core_target: true,
        can_manage_global_providers: true,
      },
    });

    render(() => <UsersSettings />);

    await waitFor(() => {
      expect(screen.getByText("Couldn’t load users")).toBeTruthy();
    });

    expect(screen.queryByText("No user accounts yet")).toBeNull();
    expect(screen.queryByText("0 accounts configured on Core.")).toBeNull();
  });

  it("clears stale multi_user cache when /api/auth/me 404s and legacy /api/auth/status omits auth_mode", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.endsWith("/api/admin/users") || url.endsWith("/api/auth/me")) {
          return new Response("Not Found", { status: 404 });
        }
        if (url.endsWith("/api/auth/status")) {
          return new Response(JSON.stringify({ authenticated: true }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
      }),
    );

    setConnection("https://legacy-core.example.com", "tok-legacy");
    applyAuthMeResponse({
      auth_mode: "multi_user",
      user: {
        id: "u-stale",
        username: "admin",
        role: "admin",
        unix_username: null,
        daily_spend_cap_cents: null,
        spent_today_cents: 0,
      },
    });

    render(() => <UsersSettings />);

    await waitFor(() => {
      expect(screen.getByText(/Single-tenant administrator/)).toBeTruthy();
    });
    expect(screen.getByText("@admin")).toBeTruthy();
    expect(screen.queryByText("Couldn’t load users")).toBeNull();
  });
});
