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
