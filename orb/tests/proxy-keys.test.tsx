import { render, screen, fireEvent, waitFor, within } from "@solidjs/testing-library";
import { beforeEach, afterEach, describe, it, expect, vi } from "vitest";
import { ProxyApiKeys } from "../src/ProxyApiKeys";
import { RoutingSettings } from "../src/RoutingSettings";
import { setConnection, clearConnection } from "../src/api";
import type { ProxyApiKeySummary } from "../src/proxyKeysApi";

const key = (id: string): ProxyApiKeySummary => ({
  id, name: id, key_prefix: `prefix-${id}`, created_at: "2026-09-01T00:00:00Z", last_used_at: null,
});
let keys: ProxyApiKeySummary[];
let failDelete: string;
let failList: boolean;
let writes: { path: string; method: string; body: any }[];
const response = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

beforeEach(() => {
  keys = [key("Cursor"), key("CI")];
  failDelete = "";
  failList = false;
  writes = [];
  setConnection("https://keys.test", "fixture");
  vi.stubGlobal("fetch", vi.fn(async (input: string, init?: RequestInit) => {
    const path = new URL(input).pathname;
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(init.body as string) : undefined;
    if (method !== "GET") writes.push({ path, method, body });
    if (path === "/api/model-routing/chains") return response([]);
    if (path === "/api/proxy-keys/cleanup") return response({ keys: [...keys], cutoff: "2026-10-01", dry_run: true });
    if (method === "DELETE") {
      const id = decodeURIComponent(path.split("/").at(-1)!);
      if (id === failDelete) return response("Cannot revoke", 503);
      keys = keys.filter(k => k.id !== id);
      return new Response(null, { status: 204 });
    }
    if (path === "/api/proxy-keys" && method === "POST") {
      const created = key(body.name);
      keys.push(created);
      return response({ ...created, key: "test-only-created-secret" });
    }
    if (path === "/api/proxy-keys") return failList ? response("Unavailable", 503) : response([...keys]);
    throw Error(path);
  }));
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: vi.fn().mockResolvedValue(undefined) } });
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });
async function mount() {
  render(() => <ProxyApiKeys />);
  await screen.findByRole("button", { name: "Revoke Cursor" });
  await waitFor(() => expect(screen.getByRole("button", { name: "Refresh" })).toHaveProperty("disabled", false));
}

describe("Proxy API keys", () => {
  it("loads on opening its Routing tab and forgets the created secret on leaving", async () => {
    render(() => <RoutingSettings onOpenClient={() => {}} />);
    await screen.findByText(/No chains configured/);
    expect(fetch).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Proxy API Keys" }));
    await screen.findByRole("button", { name: "Revoke Cursor" });
    fireEvent.click(screen.getByRole("button", { name: "New Key" }));
    fireEvent.input(screen.getByLabelText("Key name"), { target: { value: "  Windsurf  " } });
    fireEvent.click(screen.getByRole("button", { name: "Create", exact: true }));
    await screen.findByText("test-only-created-secret");
    expect(writes).toContainEqual({ path: "/api/proxy-keys", method: "POST", body: { name: "Windsurf" } });
    fireEvent.click(screen.getByRole("button", { name: "Copy key" }));
    await waitFor(() => expect(navigator.clipboard.writeText).toHaveBeenCalledWith("test-only-created-secret"));
    expect(localStorage.getItem("test-only-created-secret")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Fallback Chains" }));
    expect(screen.queryByText("test-only-created-secret")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Proxy API Keys" }));
    await screen.findByRole("button", { name: "Revoke Windsurf" });
    expect(screen.queryByText("test-only-created-secret")).toBeNull();
  });

  it("previews cleanup and revokes only selected keys after confirmation", async () => {
    await mount();
    fireEvent.click(screen.getByRole("button", { name: "Clean Up" }));
    await screen.findByRole("checkbox", { name: /Cursor/ });
    expect(writes).toEqual([{ path: "/api/proxy-keys/cleanup", method: "POST", body: { max_age_days: 7, dry_run: true } }]);
    fireEvent.click(screen.getByRole("checkbox", { name: /CI/ }));
    fireEvent.click(screen.getByRole("button", { name: "Revoke 1 key" }));
    expect(writes.some(w => w.method === "DELETE")).toBe(false);
    const dialog = screen.getByRole("dialog", { name: "Revoke API key?" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Revoke key", exact: true }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Revoke Cursor" })).toBeNull());
    expect(writes.filter(w => w.method === "DELETE")).toEqual([{ path: "/api/proxy-keys/Cursor", method: "DELETE", body: undefined }]);
    expect(screen.getByRole("button", { name: "Revoke CI" })).toBeTruthy();
  });

  it("keeps failed cleanup keys available for retry and reports partial success", async () => {
    failDelete = "CI";
    await mount();
    fireEvent.click(screen.getByRole("button", { name: "Clean Up" }));
    await screen.findByRole("checkbox", { name: /Cursor/ });
    fireEvent.click(screen.getByRole("button", { name: "Revoke 2 keys" }));
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Revoke 2 keys" }));
    await screen.findByText(/Revoked 1 of 2 keys. 1 failed/);
    expect(screen.queryByRole("checkbox", { name: /Cursor/ })).toBeNull();
    expect(screen.getByRole("checkbox", { name: /CI/ })).toHaveProperty("checked", true);
    await waitFor(() => expect(screen.getByRole("button", { name: "Revoke 1 key" })).toHaveProperty("disabled", false));
  });

  it("requires confirmation for individual revocation and supports cancellation", async () => {
    await mount();
    fireEvent.click(screen.getByRole("button", { name: "Revoke Cursor" }));
    fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Cancel" }));
    expect(writes).toEqual([]);
    expect(screen.getByRole("button", { name: "Revoke Cursor" })).toBeTruthy();
  });

  it("ignores stale previews and disables cleanup for invalid ages", async () => {
    await mount();
    const original = vi.mocked(fetch).getMockImplementation()!;
    let finish: ((value: Response) => void) | undefined;
    vi.mocked(fetch).mockImplementation((input, init) => {
      if (String(input).endsWith("/cleanup") && JSON.parse(init!.body as string).max_age_days === 7)
        return new Promise(resolve => { finish = resolve; });
      return original(input, init);
    });
    fireEvent.click(screen.getByRole("button", { name: "Clean Up" }));
    fireEvent.input(screen.getByLabelText("Inactive days"), { target: { value: "14" } });
    await screen.findByRole("checkbox", { name: /Cursor/ });
    finish!(response({ keys: [key("stale")], cutoff: "", dry_run: true }));
    await new Promise(resolve => setTimeout(resolve, 0));
    expect(screen.queryByRole("checkbox", { name: /stale/ })).toBeNull();
    fireEvent.input(screen.getByLabelText("Inactive days"), { target: { value: "0" } });
    expect(screen.getByRole("button", { name: "Revoke 0 keys" })).toHaveProperty("disabled", true);
    expect(screen.queryByRole("checkbox")).toBeNull();
  });

  it("clears secrets on connection changes and ignores a late creation response", async () => {
    await mount();
    let finish: ((value: Response) => void) | undefined;
    const original = vi.mocked(fetch).getMockImplementation()!;
    vi.mocked(fetch).mockImplementation((input, init) => init?.method === "POST"
      ? new Promise(resolve => { finish = resolve; }) : original(input, init));
    fireEvent.click(screen.getByRole("button", { name: "New Key" }));
    fireEvent.input(screen.getByLabelText("Key name"), { target: { value: "Late" } });
    fireEvent.click(screen.getByRole("button", { name: "Create", exact: true }));
    setConnection("https://other-keys.test", "fixture2");
    finish!(response({ ...key("Late"), key: "late-secret" }));
    await waitFor(() => expect(screen.getByText("https://other-keys.test/v1")).toBeTruthy());
    expect(screen.queryByText("late-secret")).toBeNull();
    expect(screen.queryByLabelText("Key name")).toBeNull();
    clearConnection();
    expect(screen.queryByRole("button", { name: "Revoke Cursor" })).toBeNull();
  });

  it("shows list errors instead of claiming there are no keys and retries", async () => {
    failList = true;
    render(() => <ProxyApiKeys />);
    await screen.findByText(/Could not load proxy API keys/);
    expect(screen.queryByText(/No API keys yet/)).toBeNull();
    failList = false;
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await screen.findByRole("button", { name: "Revoke Cursor" });
    expect(screen.queryByText(/Could not load proxy API keys/)).toBeNull();
  });
});
