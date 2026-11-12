import { render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { RoutingSettings } from "../src/RoutingSettings";
import { clearConnection, setConnection } from "../src/api";
import { listChains, normalizeChains, routingCatalog } from "../src/routingApi";

const good = { id: "builtin/smart", name: "Smart", entries: [{ provider_id: "anthropic", model_id: "claude-test" }], is_default: true, strip_thinking: false, created_at: "", updated_at: "" };
// What dev Core sent on 2026-11-12: the stored column, not the API shape.
const legacy = { id: "team/cheap", name: "Cheap", models_json: "[{\"provider_id\":\"openai\",\"model_id\":\"gpt-test\"}]", updated_at: "" };

describe("normalizeChains", () => {
  it("keeps valid rows untouched and marks the rest instead of dropping them", () => {
    const rows = normalizeChains([good, legacy, { id: "x", entries: [{ provider_id: 1 }] }, null, { name: "No id", entries: [] }]);
    expect(rows.map(r => !!r.malformed)).toEqual([false, true, true, true, true]);
    expect(rows[0]).toEqual(good);
    expect(rows[1]).toMatchObject({ id: "team/cheap", name: "Cheap", entries: [] });
    expect(rows[1].malformed).toContain("models_json");
    expect(new Set(rows.map(r => r.id)).size).toBe(rows.length);
  });
  it("a marked row read back from the local cache stays marked, never editable", () => {
    const once = normalizeChains([legacy]);
    expect(normalizeChains(JSON.parse(JSON.stringify(once)))).toEqual(once);
  });
  it("rejects a response that is not a list", () => {
    expect(() => normalizeChains({ error: "nope" })).toThrow(/unexpected/);
  });
});

describe("Fallback Chains tab with a malformed row", () => {
  let writes = 0;
  beforeEach(() => {
    writes = 0;
    localStorage.clear();
    setConnection("https://routing-malformed.test", "test");
    vi.stubGlobal("fetch", vi.fn(async (input: string, init?: RequestInit) => {
      const path = new URL(input).pathname;
      if ((init?.method ?? "GET") !== "GET") writes++;
      const body = path === "/api/model-routing/chains" ? [legacy, good] : path === "/api/model-routing/catalog" ? { providers: [] } : [];
      return new Response(JSON.stringify(body), { status: 200 });
    }));
  });
  afterEach(() => { listChains.clear?.(); routingCatalog.clear?.(); clearConnection(); vi.unstubAllGlobals(); });

  it("renders every chain, with an inline error on the malformed one and no way to edit it", async () => {
    const view = render(() => <RoutingSettings />);
    await waitFor(() => expect(screen.getByText("Smart")).toBeTruthy());
    expect(view.container.querySelectorAll(".routing-chain").length).toBe(2);
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain("models_json");
    const bad = alert.closest(".routing-chain")!;
    const summary = bad.querySelector<HTMLButtonElement>(".routing-chain-summary")!;
    expect(summary.textContent).toContain("Cheap");
    expect(summary.disabled).toBe(true);
    summary.click();
    expect(bad.querySelector(".routing-editor")).toBeNull();
    const ok = screen.getByText("Smart").closest<HTMLButtonElement>(".routing-chain-summary")!;
    expect(ok.disabled).toBe(false);
    expect(ok.textContent).toContain("claude-test");
    expect(writes).toBe(0);
  });
});
