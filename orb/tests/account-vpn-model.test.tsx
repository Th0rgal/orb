import { fireEvent, render, screen } from "@solidjs/testing-library";
import { beforeEach, expect, it, test, vi } from "vitest";
import fixture from "../../shared/orb-spec/fixtures/account-vpn.json";
import { accountVpnRoute, accountVpnView, accountVpnWrite, alternativeRouterAccess, missingAccountSetting } from "../src/accountVpn";
import { api } from "../src/api";
import { AccountVpnSettings } from "../src/AccountVpnSettings";
import { AlternativeRouterSettings } from "../src/AlternativeRouterSettings";

vi.mock("../src/api", () => {
  class ApiError extends Error {
    constructor(public status: number, public detail: string) { super(`${status}: ${detail}`); }
  }
  return { api: vi.fn(), ApiError, connectionVersion: () => 1 };
});
const { ApiError } = await import("../src/api");

beforeEach(() => { vi.mocked(api).mockReset(); });

test.each(fixture.routes)("account connection: $name", c => {
  const route = accountVpnRoute(c.payload);
  expect(route).not.toBeNull();
  const view = accountVpnView(route!, c.native);
  expect({ ...view, confirm_direct: view.confirmDirect, confirmDirect: undefined })
    .toEqual({ ...c.view, confirmDirect: undefined });
});

test("an unreadable account connection confirms nothing", () => {
  for (const payload of fixture.invalid_routes) expect(accountVpnRoute(payload)).toBeNull();
});

test.each(fixture.writes)("account connection write for '$country'", c => {
  expect(accountVpnWrite(c.country)).toEqual(c.body);
});

test.each(fixture.read_errors)("settings read error: $name", c => {
  expect(missingAccountSetting(c.status, c.body, c.path)).toBe(c.missing_endpoint);
});

test.each(fixture.router_access)("router access payload $payload", c => {
  expect(alternativeRouterAccess(c.payload)).toBe(c.allowed);
});

test.each(fixture.routes)("account connection row renders: $name", async c => {
  vi.mocked(api).mockResolvedValueOnce(c.payload);
  render(() => <AccountVpnSettings account="a" nativeAccount={c.native} />);
  const select = await screen.findByLabelText("Account connection") as HTMLSelectElement;
  expect(select.value).toBe(c.view.selected);
  expect(select.disabled).toBe(!c.view.editable);
  expect(Array.from(select.options).map(o => o.textContent)).toEqual(["Direct", ...c.view.countries.map(x => `AirVPN · ${x}`)]);
  expect(screen.queryAllByRole("button", { name: "Confirm Direct route" })).toHaveLength(c.view.confirm_direct ? 1 : 0);
  expect(screen.queryAllByRole("button", { name: "Retry verification" })).toHaveLength(c.view.retry ? 1 : 0);
  expect(screen.queryAllByRole("button", { name: "Refresh connection settings" })).toHaveLength(c.view.editable ? 0 : 1);
  expect(screen.queryByRole("status")?.textContent ?? "").toBe(c.view.status);
  if (c.view.notice) screen.getByText(c.view.notice);
  else expect(screen.queryByText(/VPN routing is unavailable|Import a named server profile/)).toBeNull();
});

it("leaves the account connection unconfirmed when Core answers without a mode", async () => {
  vi.mocked(api).mockResolvedValueOnce(fixture.invalid_routes[2]);
  render(() => <AccountVpnSettings account="a" />);
  await screen.findByRole("button", { name: "Retry connection settings" });
  expect(screen.queryByLabelText("Account connection")).toBeNull();
  expect(screen.queryByText(fixture.labels.vpn_update)).toBeNull();
});

it("shows router access only after Core confirms it and keeps a refused change off", async () => {
  vi.mocked(api).mockResolvedValueOnce({ allowed: false })
    .mockRejectedValueOnce(new ApiError(503, "{\"error\":\"sidecar_unavailable\"}"))
    .mockResolvedValueOnce({ allowed: false })
    .mockResolvedValueOnce({ allowed: true });
  render(() => <AlternativeRouterSettings account="team/b" />);
  const toggle = await screen.findByRole("switch", { name: "Allow alternative routers" });
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  fireEvent.click(toggle);
  await screen.findByText(fixture.labels.router_unconfirmed);
  await vi.waitFor(() => expect(api).toHaveBeenCalledTimes(3));
  expect(screen.getByRole("switch", { name: "Allow alternative routers" }).getAttribute("aria-checked")).toBe("false");
  await vi.waitFor(() => expect((screen.getByRole("switch", { name: "Allow alternative routers" }) as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(screen.getByRole("switch", { name: "Allow alternative routers" }));
  await vi.waitFor(() => expect(screen.getByRole("switch", { name: "Allow alternative routers" }).getAttribute("aria-checked")).toBe("true"));
  expect(screen.queryByText(fixture.labels.router_unconfirmed)).toBeNull();
  const put = (allowed: boolean) => ["/api/ai/providers/team%2Fb/alternative-routers",
    { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ allowed }) }];
  expect(vi.mocked(api).mock.calls).toEqual([
    ["/api/ai/providers/team%2Fb/alternative-routers", undefined], put(true),
    ["/api/ai/providers/team%2Fb/alternative-routers", undefined], put(true),
  ]);
});

it("hides router access when Core does not state it and explains an older Core", async () => {
  vi.mocked(api).mockResolvedValueOnce({ allowed: "true" });
  const first = render(() => <AlternativeRouterSettings account="a" />);
  await screen.findByRole("button", { name: "Retry router settings" });
  expect(screen.queryByRole("switch")).toBeNull();
  expect(screen.queryByText(fixture.labels.router_update)).toBeNull();
  first.unmount();
  const legacy = fixture.read_errors.find(e => e.name === "older Core without router access")!;
  vi.mocked(api).mockRejectedValueOnce(new ApiError(legacy.status, legacy.body)).mockResolvedValueOnce({ allowed: true });
  render(() => <AlternativeRouterSettings account="a" />);
  await screen.findByText(fixture.labels.router_update);
  expect(screen.queryByRole("switch")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Retry router settings" }));
  const toggle = await screen.findByRole("switch", { name: "Allow alternative routers" });
  expect(toggle.getAttribute("aria-checked")).toBe("true");
});

it("keeps a newer router-access toggle when an older focus reread finishes", async () => {
  let finishRead!: (v: unknown) => void;
  vi.mocked(api).mockResolvedValueOnce({ allowed: true })
    .mockImplementationOnce(() => new Promise(resolve => { finishRead = resolve; }))
    .mockResolvedValueOnce({ allowed: false });
  render(() => <AlternativeRouterSettings account="focus-race" />);
  const toggle = await screen.findByRole("switch", { name: "Allow alternative routers" }) as HTMLButtonElement;
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  window.dispatchEvent(new Event("focus"));
  await vi.waitFor(() => expect(api).toHaveBeenCalledTimes(2));
  expect(toggle.disabled).toBe(false);
  fireEvent.click(toggle);
  await vi.waitFor(() => expect(toggle.getAttribute("aria-checked")).toBe("false"));
  finishRead({ allowed: true });
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(toggle.getAttribute("aria-checked")).toBe("false");
});
