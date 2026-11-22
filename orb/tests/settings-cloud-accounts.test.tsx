import { render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { Settings } from "../src/Settings";
import { clearConnection, setConnection } from "../src/api";

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

it("loads cloud accounts only once connected, and again after reconnecting", async () => {
  const accounts = vi.fn(() => [{ id: "cursor-default", provider: "cursor_cloud", label: "Cursor Cloud", available: false, experimental: false, reason: "Connect a user API key on Core", capabilities: {} }]);
  const fetch = vi.fn(async (url: string) => new Response(JSON.stringify(url.endsWith("/api/cloud/accounts") ? accounts() : {})));
  vi.stubGlobal("fetch", fetch);
  const cloudCalls = () => fetch.mock.calls.filter(([url]) => String(url).endsWith("/api/cloud/accounts")).length;
  render(() => <Settings />);
  expect(await screen.findByText("Connect to the backend above to see cloud accounts.")).toBeTruthy();
  expect((screen.getByRole("button", { name: "Refresh accounts" }) as HTMLButtonElement).disabled).toBe(true);
  expect(cloudCalls()).toBe(0);
  setConnection("http://core.test", "test-token");
  expect(await screen.findByText("Connect a user API key on Core")).toBeTruthy();
  expect(cloudCalls()).toBe(1);
  setConnection("http://other-core.test", "other-token");
  await waitFor(() => expect(cloudCalls()).toBe(2));
  expect(fetch.mock.calls.filter(([url]) => String(url).endsWith("/api/cloud/accounts")).map(([url]) => String(url))).toEqual(["http://core.test/api/cloud/accounts", "http://other-core.test/api/cloud/accounts"]);
});

it("loads the server GitHub integration only for an authorized session, including after switching accounts", async () => {
  const admin = "http://admin.test";
  const member = "http://member.test";
  const legacy = "http://legacy.test";
  const githubCalls: string[] = [];
  const fetch = vi.fn(async (url: string) => {
    const {origin, pathname} = new URL(url);
    if (pathname === "/api/auth/status") {
      return Response.json(origin === legacy ? {auth_mode: "single_tenant"} : {
        auth_mode: "multi_user", user: { role: origin === admin ? "admin" : "member" },
      });
    }
    if (pathname === "/api/integrations/github/status") {
      githubCalls.push(origin);
      return Response.json({configured: true, connected: false});
    }
    return Response.json(pathname === "/api/cloud/accounts" ? [] : {});
  });
  vi.stubGlobal("fetch", fetch);
  setConnection(admin, "admin-session");
  render(() => <Settings />);
  await waitFor(() => expect(githubCalls).toEqual([admin]));
  setConnection(member, "member-session");
  await waitFor(() => expect(fetch.mock.calls.some(([url]) => url === member + "/api/auth/status")).toBe(true));
  await waitFor(() => expect(screen.queryByText("Mission git & gh credentials")).toBeNull());
  setConnection(legacy, "legacy-session");
  await waitFor(() => expect(githubCalls).toEqual([admin, legacy]));
  expect(screen.getByText("Mission git & gh credentials")).toBeTruthy();
});
