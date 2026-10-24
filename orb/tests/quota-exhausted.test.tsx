import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { render, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Providers } from "../src/Providers";
import { clearConnection, setConnection, type AIProvider, type ProviderUsage } from "../src/api";
import { codingPlanWindows, effectiveProviderStatus, quotaLevel, quotaStatus } from "../src/providerUsage";

const fixture = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "quota-exhausted.json"), "utf8")) as { cases: Array<{ name: string; windows: { label: string; used: number }[]; expected: { level: string; label: string; accountWide: boolean } | null }> };
const levels = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "quota-level.json"), "utf8")) as { cases: Array<{ name: string; used: number | null; hasReset?: boolean; expected: string }> };

describe("shared/orb-spec/fixtures/quota-exhausted.json", () => {
  for (const c of fixture.cases) it(c.name, () => expect(quotaStatus(c.windows)).toEqual(c.expected));
});

describe("shared/orb-spec/fixtures/quota-level.json", () => {
  for (const c of levels.cases) it(c.name, () => expect(quotaLevel(c.used, c.hasReset)).toBe(c.expected));
});

it("reads an Antigravity window with a reset but no figure as spent", () => {
  expect(codingPlanWindows({ provider_type: "antigravity", antigravity_windows: [{ label: "Gemini · 5h", reset_at: 2000000000 } as never] } as ProviderUsage)).toEqual([{ label: "Gemini · 5h", used: 1, reset: 2000000000 }]);
});

const antigravity = { id: "agy", name: "Antigravity (thomas@example.com)", provider_type: "antigravity", enabled: true, uses_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" } } as AIProvider;
const agyUsage = (gemini: number, claude: number) => ({ provider_type: "antigravity", antigravity_windows: [{ label: "Gemini · 5h", used_percent: gemini }, { label: "Claude & GPT · 5h", used_percent: claude }] }) as ProviderUsage;

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); });

it("names the exhausted pool instead of the whole account", () => {
  expect(effectiveProviderStatus(antigravity, agyUsage(100, 0))).toBe("pool_exhausted");
  expect(effectiveProviderStatus(antigravity, agyUsage(100, 100))).toBe("quota_exhausted");
  expect(effectiveProviderStatus(antigravity, agyUsage(40, 0))).toBe("connected");
});

it("shows 'Gemini quota exhausted' and highlights only the spent chip", async () => {
  setConnection("http://core.test", "test-token");
  vi.stubGlobal("fetch", vi.fn(async (url: string) => new Response(JSON.stringify(url.endsWith("/providers") ? [antigravity] : url.includes("/agy/usage") ? agyUsage(100, 0) : url.endsWith("/providers/usage") ? { entries: { agy: agyUsage(100, 0) } } : {}))));
  const { container } = render(() => <Providers />);
  await waitFor(() => expect(container.textContent).toContain("Gemini quota exhausted"));
  // Collapse the row (Antigravity opens expanded) to see the summary chips.
  (container.querySelector(".p-acc-btn") as HTMLButtonElement).click();
  await waitFor(() => expect(container.querySelectorAll(".p-usage.compact .p-usage-chip")).toHaveLength(2));
  const chips = [...container.querySelectorAll(".p-usage.compact .p-usage-chip")];
  expect(chips.map(c => c.classList.contains("exhausted"))).toEqual([true, false]);
  expect(container.querySelector(".p-st")?.classList.contains("exhausted")).toBe(true);
  expect(chips[0].classList.contains("top")).toBe(true);
  expect(container.querySelector(".p-usage-more")?.textContent).toBe("+1");
});
