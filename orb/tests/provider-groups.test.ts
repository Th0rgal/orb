import { afterEach, describe, expect, it, vi } from "vitest";
import type { AIProvider, ProviderUsage } from "../src/api";
import { groupProviderAccounts, isGroupOpen, loadGroupPrefs, saveGroupPrefs, summarizeProviderGroup, toggleGroupPref } from "../src/providerGroups";

const acc = (id: string, provider_type: string, extra: Partial<AIProvider> = {}) =>
  ({ id, provider_type, provider_type_name: provider_type, name: id, enabled: true, uses_oauth: true, status: { type: "connected" }, ...extra }) as AIProvider;
const agy = (claude: number, gemini: number) => ({ provider_type: "antigravity", antigravity_windows: [
  { label: "Claude & GPT · 5h", used_percent: claude }, { label: "Gemini · 5h", used_percent: gemini }, { label: "Gemini · Weekly", used_percent: 0 },
] }) as ProviderUsage;

describe("groupProviderAccounts", () => {
  it("groups by provider type in order of first appearance, accounts by priority", () => {
    const groups = groupProviderAccounts([
      acc("g2", "antigravity", { priority: 1 }), acc("claude", "anthropic"), acc("g1", "antigravity", { priority: 0 }),
      acc("codex", "openai"), acc("g4", "antigravity", { priority: 3 }), acc("g3", "antigravity", { priority: 2 }),
    ]);
    expect(groups.map(g => [g.type, g.accounts.map(a => a.id)])).toEqual([
      ["antigravity", ["g1", "g2", "g3", "g4"]], ["anthropic", ["claude"]], ["openai", ["codex"]],
    ]);
    expect(groups[0].name).toBe("Google Antigravity");
    expect(groups[1].name).toBe("anthropic");
  });
  it("keeps list order for equal priorities and returns nothing for an empty list", () => {
    expect(groupProviderAccounts([acc("a", "xai"), acc("b", "xai")])[0].accounts.map(a => a.id)).toEqual(["a", "b"]);
    expect(groupProviderAccounts([])).toEqual([]);
  });
});

describe("summarizeProviderGroup", () => {
  const four = [acc("a", "antigravity"), acc("b", "antigravity"), acc("c", "antigravity"), acc("d", "antigravity")];
  it("counts statuses worst first and quota as accounts with headroom per family", () => {
    const s = summarizeProviderGroup(four, { a: agy(100, 0), b: agy(99, 10), c: agy(85, 100), d: agy(20, 30) });
    expect(s.text).toBe("4 accounts · 2 limit reached · 1 near limit");
    expect(s.parts.map(p => p.tone)).toEqual(["exhausted", "warning"]);
    expect(s.attention).toBe(false);
    expect(s.chips.map(c => [c.label, c.available, c.total, c.level])).toEqual([["Claude & GPT", 3, 4, "normal"], ["Gemini", 3, 4, "normal"]]);
    expect(s.chips[0].detail).toBe("Claude & GPT: 3 of 4 accounts have quota left · least used 20%");
  });
  it("never reports headroom that only a spent, disabled or signed-out account has", () => {
    const list = [four[0], acc("b", "antigravity", { enabled: false }), acc("c", "antigravity", { status: { type: "needs_reauth" } }), four[3]];
    const s = summarizeProviderGroup(list, { a: agy(100, 100), b: agy(0, 0), c: agy(0, 0), d: agy(100, 92) });
    expect(s.text).toBe("4 accounts · 1 needs sign-in · 2 limit reached · 1 disabled");
    expect(s.attention).toBe(true);
    expect(s.chips.map(c => [c.label, c.available, c.total, c.level])).toEqual([["Claude & GPT", 0, 4, "exhausted"], ["Gemini", 1, 4, "warning"]]);
    expect(s.chips[0].leastUsed).toBeUndefined();
    expect(s.chips[0].detail).toBe("Claude & GPT: 0 of 4 accounts have quota left");
  });
  it("leaves working accounts without a figure out of the count and counts failing ones as unavailable", () => {
    const s = summarizeProviderGroup(four, { a: agy(10, 10), b: { provider_type: "antigravity", error: "boom" } as ProviderUsage });
    // b fails (counted, not available); c and d work but have no figure yet (not counted).
    expect(s.chips.map(c => [c.available, c.total])).toEqual([[1, 2], [1, 2]]);
    expect(s.text).toBe("4 accounts · 1 error");
    expect(summarizeProviderGroup(four).chips).toEqual([]);
    expect(summarizeProviderGroup(four).text).toBe("4 accounts");
  });
  it("treats an account-wide spent window as unavailable for every family", () => {
    const u = (h5: number, d7: number) => ({ provider_type: "anthropic", unified_5h_utilization: h5, unified_7d_utilization: d7 }) as ProviderUsage;
    const s = summarizeProviderGroup([acc("a", "anthropic"), acc("b", "anthropic")], { a: u(.1, 1), b: u(.4, .5) });
    expect(s.chips.map(c => [c.label, c.available, c.total])).toEqual([["5h", 1, 2], ["Weekly", 1, 2]]);
    expect(s.chips[0].leastUsed).toBe(.4);
  });
  it("opens the group for every status that needs the account's own row", () => {
    const one = (usage: Partial<ProviderUsage>, health?: string) => summarizeProviderGroup([four[0], four[1]],
      { a: { provider_type: "antigravity", ...usage } as ProviderUsage }, health ? { a: { account_id: "a", account_state: health } as never } : {});
    expect(one({ status: "needs_verification" }).text).toBe("2 accounts · 1 needs verification");
    expect(one({ status: "needs_verification" }).attention).toBe(true);
    expect(one({}, "out_of_credit").attention).toBe(true);
    expect(one({}, "auth_failed").text).toBe("2 accounts · 1 needs sign-in");
    expect(one({}, "quota_exhausted").attention).toBe(false);
  });
});

describe("group open state", () => {
  afterEach(() => { localStorage.clear(); vi.restoreAllMocks(); });
  it("is collapsed by default and open by default when an account needs attention", () => {
    expect(isGroupOpen({}, "antigravity", false)).toBe(false);
    expect(isGroupOpen({}, "antigravity", true)).toBe(true);
    expect(isGroupOpen({ k: false }, "k", true)).toBe(false);
  });
  it("stores only choices that differ from the default", () => {
    expect(toggleGroupPref({}, "k", false)).toEqual({ k: true });
    expect(toggleGroupPref({ k: true }, "k", false)).toEqual({});
    expect(toggleGroupPref({}, "k", true)).toEqual({ k: false });
    expect(toggleGroupPref({ k: false }, "k", true)).toEqual({});
    // Opened by hand, then a problem appears: closing it is now the explicit choice.
    expect(toggleGroupPref({ k: true }, "k", true)).toEqual({ k: false });
  });
  it("remembers per connection and survives broken storage", () => {
    saveGroupPrefs("http://a", { "antigravity": true });
    expect(loadGroupPrefs("http://a")).toEqual({ "antigravity": true });
    expect(loadGroupPrefs("http://b")).toEqual({});
    saveGroupPrefs("http://a", {});
    expect(localStorage.length).toBe(0);
    localStorage.setItem("orb.inferenceGroups:http://a", '{"x":"yes","y":true}');
    expect(loadGroupPrefs("http://a")).toEqual({ y: true });
    localStorage.setItem("orb.inferenceGroups:http://a", "not json");
    expect(loadGroupPrefs("http://a")).toEqual({});
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("denied"); });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("denied"); });
    expect(loadGroupPrefs("http://a")).toEqual({});
    expect(() => saveGroupPrefs("http://a", { k: true })).not.toThrow();
  });
});
