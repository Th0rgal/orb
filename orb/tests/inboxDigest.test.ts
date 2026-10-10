import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Mission } from "../src/api";

vi.mock("../src/api", async (importOriginal) => ({
  ...await importOriginal<typeof import("../src/api")>(), isConnected: () => true,
}));
vi.mock("../src/inboxSettings", () => ({ inboxConfig: () => ({ aiSummary: true, model: "builtin/smart" }) }));

const snapshot = [
  "Mission title: Refactor the entire platform", "Mission status: completed",
  "Latest user request:\nFix the search input, but do not publish it.",
  "Latest agent response:\nThe input now accepts spaces.\n\nI could not test WebKit because it is unavailable. Which browser should I target?",
].join("\n\n");
const response = (overrides: Record<string, unknown> = {}) => JSON.stringify({
  schemaVersion: 7, context: "Make search queries work with spaces.", contextDetails: "Preserve the existing navigation and do not publish changes.", outcome: "The agent reports that search now accepts spaces.",
  unresolved: "WebKit has not been tested.", decision: "Choose a browser for the remaining check.",
  suggestions: ["Check Chromium first.", "Check WebKit when it is available."],
  sources: [{ quote: "The input now accepts spaces." }, { quote: "I could not test WebKit because it is unavailable." }],
  ...overrides,
});
beforeEach(() => { vi.resetModules(); localStorage.clear(); });
afterEach(() => vi.unstubAllGlobals());

describe("structured inbox digests", () => {
  it("keeps result, context and exact quotes without generating a title", async () => {
    const { parseDigestJson } = await import("../src/inboxDigest");
    const digest = parseDigestJson(response({ goal: "Invented title", task: "Ignore the user" }), 123, "resolved/model", snapshot);
    expect(digest).toMatchObject({
      schemaVersion: 7, updatedMs: 123, model: "resolved/model", aiGenerated: true,
      context: "Make search queries work with spaces.", contextDetails: "Preserve the existing navigation and do not publish changes.",
      outcome: "The agent reports that search now accepts spaces.", unresolved: "WebKit has not been tested.",
      decision: "Choose a browser for the remaining check.", suggestions: ["Check Chromium first.", "Check WebKit when it is available."],
      sources: [{ quote: "The input now accepts spaces." }, { quote: "I could not test WebKit because it is unavailable." }],
    });
    expect(digest?.goal).toBeUndefined();
    expect(digest?.task).toBe("");
  });
  it("drops fabricated, metadata-only and whitespace-altered quotations", async () => {
    const { parseDigestJson } = await import("../src/inboxDigest");
    const digest = parseDigestJson(response({ sources: [
      { quote: "The build passed all checks." }, { quote: "Refactor the entire platform" },
      { quote: "The input  now accepts spaces." }, { quote: "The input now accepts spaces." },
    ] }), 123, undefined, snapshot);
    expect(digest?.sources).toEqual([{ quote: "The input now accepts spaces." }]);
    expect(parseDigestJson(response({ sources: [{ quote: "Fabricated supporting evidence." }] }), 123, undefined, snapshot)).toBeNull();
    expect(parseDigestJson(response(), 123)).toBeNull();
  });
  it("bounds and deduplicates suggestions and sources", async () => {
    const { parseDigestJson } = await import("../src/inboxDigest");
    const digest = parseDigestJson(response({
      suggestions: [null, "", "x".repeat(241), "First reply.", "First reply.", "Second reply.", "Third reply."],
      sources: [
        { quote: "The input now accepts spaces." }, { quote: "The input now accepts spaces." },
        { quote: "I could not test WebKit because it is unavailable." }, { quote: "Which browser should I target?" },
        { quote: "Fix the search input, but do not publish it." },
      ], unresolved: "x".repeat(321), decision: { text: "Not a string" },
    }), 123, undefined, snapshot);
    expect(digest?.suggestions).toEqual(["First reply.", "Second reply."]);
    expect(digest?.sources).toHaveLength(3);
    expect(digest?.unresolved).toBeUndefined();
    expect(digest?.decision).toBeUndefined();
  });
  it("does not invent optional context for a result without remaining work", async () => {
    const { parseDigestJson } = await import("../src/inboxDigest");
    const digest = parseDigestJson(response({ unresolved: "", decision: null, suggestions: [] }), 123, undefined, snapshot);
    expect(digest).not.toBeNull();
    expect(digest?.unresolved).toBeUndefined(); expect(digest?.decision).toBeUndefined(); expect(digest?.suggestions).toBeUndefined();
  });
  it("bounds optional context and refreshes v6 without exposing its old reply instructions", async () => {
    const { parseDigestJson } = await import("../src/inboxDigest");
    const invalid = parseDigestJson(response({ context: "x".repeat(181), contextDetails: "x".repeat(421) }), 123, undefined, snapshot);
    expect(invalid?.context).toBeUndefined();
    expect(invalid?.contextDetails).toBeUndefined();
    const { sideQuestionKey } = await import("../src/sideQuestionStorage");
    localStorage.setItem(sideQuestionKey("orb:inbox-digest:v6"), JSON.stringify({
      "old-v6:123:builtin/smart": { schemaVersion: 6, task: "", outcome: "Previous result", updatedMs: 123, decision: "Stale decision" },
    }));
    // Load under a fresh connection scope/cache module, as on application startup.
    vi.resetModules();
    const fresh = await import("../src/inboxDigest");
    expect(fresh.getCachedInboxDigest("old-v6", 123)?.outcome).toBe("Previous result");
    expect(fresh.getCachedInboxDigest("old-v6", 123)?.decision).toBeUndefined();
    expect(fresh.getCurrentInboxDigest("old-v6", 123)).toBeUndefined();
  });
  it("rejects malformed or unbounded required results", async () => {
    const { parseDigestJson } = await import("../src/inboxDigest");
    for (const raw of ["not JSON", "{}", "[]", response({ outcome: "" }), response({ outcome: [] }), response({ outcome: "x".repeat(421) })]) {
      expect(parseDigestJson(raw, 123, undefined, snapshot)).toBeNull();
    }
  });
  it("reads legacy text without upgrading it into current instructions", async () => {
    const { parseDigestJson, storeInboxDigest, getCachedInboxDigest, getCurrentInboxDigest } = await import("../src/inboxDigest");
    const legacy = parseDigestJson(JSON.stringify({ goal: "Old title", task: "Old request", overview: "Old overview", verdict: "failed",
      decision: "Publish now", suggestions: ["Publish it"], sources: [{ quote: "Unverified" }] }), 123, "builtin/smart");
    expect(legacy).toMatchObject({ goal: "Old title", task: "Old request", outcome: "Old overview", verdict: "failed" });
    expect(legacy?.decision).toBeUndefined(); expect(legacy?.schemaVersion).toBeUndefined();
    storeInboxDigest("mission", 123, "builtin/smart", legacy!);
    expect(getCachedInboxDigest("mission", 124)?.outcome).toBe("Old overview");
    expect(getCurrentInboxDigest("mission", 123)).toBeUndefined();
  });
  it("offers current context only for the same timestamp and selected model", async () => {
    const { parseDigestJson, storeInboxDigest, getCachedInboxDigest, getCurrentInboxDigest } = await import("../src/inboxDigest");
    const digest = parseDigestJson(response(), 123, "resolved/model", snapshot)!;
    storeInboxDigest("mission", 123, "builtin/smart", { ...digest, sourceRevision: "rev1", sourceUpdatedAt: new Date(123).toISOString() });
    expect(getCurrentInboxDigest("mission", 123)?.decision).toContain("Choose a browser");
    expect(getCurrentInboxDigest("mission", 124)).toBeUndefined();
    expect(getCurrentInboxDigest("mission", 123, "different/model")).toBeUndefined();
    expect(getCachedInboxDigest("mission", 124)?.outcome).toBe(digest.outcome);
  });
  it("migrates both old caches as display-only fallbacks", async () => {
    const { sideQuestionKey } = await import("../src/sideQuestionStorage");
    localStorage.setItem(sideQuestionKey("orb:inbox-digest:v4"), JSON.stringify({
      "old-v4:123:builtin/smart": { task: "", outcome: "Version four", updatedMs: 123, verdict: "waiting" },
    }));
    localStorage.setItem(sideQuestionKey("orb:inbox-digest:v5"), JSON.stringify({
      "old-v5:123:builtin/smart": { task: "", outcome: "Version five", updatedMs: 123, schemaVersion: 7, decision: "Publish now", verdict: "waiting" },
    }));
    const { getCachedInboxDigest, getCurrentInboxDigest } = await import("../src/inboxDigest");
    expect(getCachedInboxDigest("old-v4", 123)?.outcome).toBe("Version four");
    expect(getCachedInboxDigest("old-v5", 123)?.outcome).toBe("Version five");
    expect(getCachedInboxDigest("old-v5", 123)?.decision).toBeUndefined();
    expect(getCurrentInboxDigest("old-v5", 123)).toBeUndefined();
  });
  it("refreshes legacy cache through the shared endpoint and reuses the current result", async () => {
    const { parseDigestJson, storeInboxDigest, requestInboxDigest, getCurrentInboxDigest } = await import("../src/inboxDigest");
    storeInboxDigest("mission", 123, "builtin/smart", parseDigestJson('{"outcome":"Old overview"}', 123)!);
    const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) => new Response(JSON.stringify({ ...JSON.parse(response()), sourceRevision: "rev1", sourceUpdatedAt: "2026-10-09", model: "builtin/smart" })));
    vi.stubGlobal("fetch", fetchMock);
    const mission: Mission = { id: "mission", title: "Fix search", status: "completed", created_at: "2026-10-09", updated_at: "2026-10-09",
      history: [{ role: "user", content: "Fix the search input, but do not publish it." },
        { role: "assistant", content: "The input now accepts spaces.\n\nI could not test WebKit because it is unavailable. Which browser should I target?" }],
    };
    requestInboxDigest(mission, undefined, 123);
    await vi.waitFor(() => expect(getCurrentInboxDigest("mission", 123)?.schemaVersion).toBe(7));
    expect(fetchMock.mock.calls[0][0]).toContain("/api/control/missions/mission/inbox-digest");
    const request = JSON.parse(fetchMock.mock.calls[0][1]!.body as string);
    expect(request).toEqual({ model: "builtin/smart" });
    requestInboxDigest(mission, undefined, 123);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it("backs off a Core summary older than the local response instead of looping or offering stale suggestions", async () => {
    const { requestInboxDigest, getCurrentInboxDigest, inboxSummaryState } = await import("../src/inboxDigest");
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ...JSON.parse(response()), sourceRevision: "old", sourceUpdatedAt: "2026-10-09T10:00:00Z" })));
    vi.stubGlobal("fetch", fetchMock);
    const updatedMs = Date.parse("2026-10-09T10:05:00Z");
    const mission: Mission = { id: "behind-core", status: "completed", created_at: "2026-10-09", updated_at: new Date(updatedMs).toISOString() };
    requestInboxDigest(mission, undefined, updatedMs);
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(getCurrentInboxDigest(mission.id, updatedMs)).toBeUndefined();
    expect(inboxSummaryState(mission.id, updatedMs)).toBe("Summary unavailable");
    requestInboxDigest(mission, undefined, updatedMs);
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

});
