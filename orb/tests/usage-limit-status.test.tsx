import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fireEvent, render, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Providers } from "../src/Providers";
import { clearConnection, setConnection, type AIProvider, type ProviderUsage } from "../src/api";
import { sharedAnthropicOrganizations, usageLimitStatus } from "../src/providerUsage";

const fixture = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "usage-limit-status.json"), "utf8")) as { cases: Array<{ name: string; usage: ProviderUsage; nowSec: number; expected: unknown }> };

describe("shared/orb-spec/fixtures/usage-limit-status.json", () => {
  for (const c of fixture.cases) it(c.name, () => expect(usageLimitStatus(c.usage, c.nowSec)).toEqual(c.expected));
});

const account = (id: string, email: string) => ({ id, provider_type: "anthropic", name: `Anthropic (${email})`, account_email: email, enabled: true, uses_oauth: true, has_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" } }) as AIProvider;
const anthropic = (org: string, h5: number, d7: number, extra: Partial<ProviderUsage> = {}) => ({ provider_type: "anthropic", organization_id: org, unified_status: "allowed", unified_5h_utilization: h5, unified_7d_utilization: d7, ...extra }) as ProviderUsage;

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); });

it("renders each Anthropic account's own numbers and a friendly warning", async () => {
  setConnection("http://core.test", "test-token");
  const ben = anthropic("org-ben", 0.09, 0.91, { unified_status: "allowed_warning", unified_representative_claim: "seven_day" });
  const thomas = anthropic("org-thomas", 0.37, 0.12);
  vi.stubGlobal("fetch", vi.fn(async (url: string) => new Response(JSON.stringify(url.endsWith("/providers") ? [account("ben", "ben@example.com"), account("thomas", "thomas@example.com")] : url.endsWith("/providers/usage") ? { entries: { ben, thomas } } : url.includes("/ben/usage") ? ben : url.includes("/thomas/usage") ? thomas : {}))));
  const { container } = render(() => <Providers />);
  await waitFor(() => expect(container.textContent).toContain("thomas@example.com"));
  for (const btn of [...container.querySelectorAll("button")].filter(b => /(ben|thomas)@example\.com/.test(b.textContent ?? ""))) fireEvent.click(btn);
  await waitFor(() => expect(container.textContent).toContain("91%"));
  expect(container.querySelector("[data-testid=usage-limit-status]")?.textContent).toBe("Approaching limit · weekly 91%");
  for (const pct of ["9%", "37%", "12%"]) expect(container.textContent).toContain(pct);
  expect(container.textContent).not.toMatch(/allowed_warning|status:/);
  expect(container.textContent).not.toContain("Shared organization limit");
});

it("labels accounts of one organization as a shared limit", () => {
  const shared = sharedAnthropicOrganizations({ a: anthropic("org-1", 0.1, 0.2), b: anthropic("org-1", 0.1, 0.2), c: anthropic("org-2", 0.5, 0.5) });
  expect([...shared]).toEqual(["org-1"]);
});
