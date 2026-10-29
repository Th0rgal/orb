import { render, fireEvent, screen, waitFor } from "@solidjs/testing-library";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import SearchDialog from "../src/SearchDialog";
import {
  clearConnection,
  searchConversationMessages,
  setConnection,
  type ConversationSearchResponse,
  type Mission,
} from "../src/api";
import { startDiagnostics } from "../src/diagnostics";
import { isSearchShortcut } from "../src/keyboardShortcuts";
import { resolveTargetKeys, splitUtf16Highlights } from "../src/searchTarget";
import type { StreamItem } from "../src/transcriptModel";

describe("conversation search keyboard shortcuts", () => {
  const originalPlatform = Object.getOwnPropertyDescriptor(navigator, "platform");

  afterEach(() => {
    if (originalPlatform) {
      Object.defineProperty(navigator, "platform", originalPlatform);
    }
  });

  it("matches Command-K on macOS and Control-K on non-macOS while respecting IME and modifiers", () => {
    Object.defineProperty(navigator, "platform", { value: "MacIntel", configurable: true });
    expect(
      isSearchShortcut(new KeyboardEvent("keydown", { key: "k", code: "KeyK", metaKey: true })),
    ).toBe(true);
    expect(
      isSearchShortcut(new KeyboardEvent("keydown", { key: "k", code: "KeyK", ctrlKey: true })),
    ).toBe(false);
    expect(
      isSearchShortcut(
        new KeyboardEvent("keydown", { key: "k", code: "KeyK", metaKey: true, shiftKey: true }),
      ),
    ).toBe(false);
    const imeEvent = new KeyboardEvent("keydown", {
      key: "k",
      code: "KeyK",
      metaKey: true,
      isComposing: true,
    });
    expect(isSearchShortcut(imeEvent)).toBe(false);

    Object.defineProperty(navigator, "platform", { value: "Linux x86_64", configurable: true });
    expect(
      isSearchShortcut(new KeyboardEvent("keydown", { key: "k", code: "KeyK", ctrlKey: true })),
    ).toBe(true);
    expect(
      isSearchShortcut(new KeyboardEvent("keydown", { key: "k", code: "KeyK", metaKey: true })),
    ).toBe(false);
  });
});

describe("UTF-16 highlight splitting and locator resolution", () => {
  it("preserves astral-plane emoji UTF-16 code-unit spans and never interprets HTML", () => {
    const text = "Fix 🚀 café <img src=x onerror=alert(1)> token";
    const start = text.indexOf("café");
    const htmlStart = text.indexOf("<img");
    const segs = splitUtf16Highlights(text, [
      { start, end: start + "café".length },
      { start: htmlStart, end: htmlStart + 4 },
    ]);
    expect(segs.map(s => s.text).join("")).toBe(text);
    expect(segs.filter(s => s.match).map(s => s.text)).toEqual(["café", "<img"]);
  });

  it("resolves user, assistant, bubble, tool-turn, and cloud locators to transcript turns", () => {
    const items: StreamItem[] = [
      { kind: "user", key: "user:u-1", text: "Hello", messageId: "u-1", sequence: 1 },
      { kind: "tool", key: "tool:c-1", callId: "c-1", name: "Bash", args: {}, done: true, sequence: 2 },
      { kind: "text", key: "text:antigravity:conv:0:step1", text: "Answer 1", live: false, eventId: "e-3", sequence: 3 },
      { kind: "user", key: "turn-2:prompt", text: "Cloud prompt", sequence: 4 },
      { kind: "text", key: "turn-2:answer:0", text: "Cloud reply", live: false, sequence: 5 },
    ];

    expect(
      resolveTargetKeys(items, {
        requestId: 1,
        missionId: "m1",
        locator: "msg:id:u-1",
        role: "user",
      }),
    ).toEqual({ turnKey: "user:u-1", messageKey: "user:u-1" });

    expect(
      resolveTargetKeys(items, {
        requestId: 2,
        missionId: "m1",
        locator: "msg:bubble:antigravity:conv:0:step1",
        role: "assistant",
      }),
    ).toEqual({ turnKey: "user:u-1", messageKey: "text:antigravity:conv:0:step1" });

    expect(
      resolveTargetKeys(items, {
        requestId: 3,
        missionId: "m1",
        locator: "turn:tools:1",
        role: "tool",
      }),
    ).toEqual({ turnKey: "user:u-1" });

    expect(
      resolveTargetKeys(items, {
        requestId: 4,
        missionId: "m1",
        locator: "cloud:turn-2:prompt",
        role: "user",
      }),
    ).toEqual({ turnKey: "turn-2:prompt", messageKey: "turn-2:prompt" });
  });
});

describe("telemetry redaction and SearchDialog state discipline", () => {
  const origFetch = globalThis.fetch;

  beforeEach(() => {
    startDiagnostics();
    setConnection("http://127.0.0.1:59999", "test-jwt-token");
  });

  afterEach(() => {
    globalThis.fetch = origFetch;
    clearConnection();
  });

  it("never records raw search queries in diagnostics on failed or aborted requests", async () => {
    const secretQuery = "ultra_sensitive_search_needle_88412";
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: "boom" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await expect(searchConversationMessages({ q: secretQuery })).rejects.toThrow();

    const ctrl = new AbortController();
    globalThis.fetch = vi.fn().mockImplementation((_url, init?: RequestInit) => {
      return new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("Aborted", "AbortError"));
        });
      });
    });
    const pending = searchConversationMessages({ q: secretQuery }, ctrl.signal);
    ctrl.abort();
    await expect(pending).rejects.toThrow();

    const diag = (window as unknown as { orbDiagnostics?: { recent: () => unknown[] } })
      .orbDiagnostics;
    const serialized = JSON.stringify(diag?.recent() ?? []);
    expect(serialized).not.toContain(secretQuery);
    expect(serialized).toContain("redacted");
  });

  it("distinguishes indexing from empty results, escapes HTML in excerpts, and rejects stale out-of-order responses", async () => {
    let resolveSlowAlpha: ((res: Response) => void) | undefined;
    const fetchMock = vi.fn().mockImplementation((input: RequestInfo | URL) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/messages/context")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              mission_id: "m-beta",
              title: "Beta Thread",
              project: "orb",
              status: "completed",
              backend: "opencode",
              updated_at: "2026-10-29T00:00:00Z",
              locator: "msg:seq:9",
              target_found: true,
              target_sequence: 9,
              messages: [
                {
                  locator: "msg:seq:9",
                  role: "assistant",
                  sequence: 9,
                  timestamp: "2026-10-29T00:00:00Z",
                  content: "Safe preview <script>window.__pwned=true</script> beta",
                  highlights: [{ start: 50, end: 54 }],
                  is_target: true,
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          ),
        );
      }

      const q = url.searchParams.get("q") ?? "";
      if (q === "indexing_probe") {
        const body: ConversationSearchResponse = {
          hits: [],
          next_cursor: null,
          coverage: {
            schema_version: 1,
            state: "indexing",
            indexed_missions: 420,
            total_missions: 1200,
          },
        };
        return Promise.resolve(
          new Response(JSON.stringify(body), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          }),
        );
      }
      if (q === "alpha") {
        return new Promise<Response>(resolve => {
          resolveSlowAlpha = resolve;
        });
      }
      if (q === "beta") {
        const body: ConversationSearchResponse = {
          hits: [
            {
              mission_id: "m-beta",
              title: "Beta <img src=x onerror=alert(1)>",
              project: "orb",
              status: "completed",
              backend: "opencode",
              updated_at: "2026-10-29T00:00:00Z",
              locator: "msg:seq:9",
              role: "assistant",
              sequence: 9,
              timestamp: "2026-10-29T00:00:00Z",
              excerpt: "Matched beta <script>alert(1)</script>",
              highlights: [{ start: 8, end: 12 }],
              mission_match_count: 1,
              score: 10,
            },
          ],
          next_cursor: null,
          coverage: {
            schema_version: 1,
            state: "ready",
            indexed_missions: 1200,
            total_missions: 1200,
          },
        };
        return Promise.resolve(
          new Response(JSON.stringify(body), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          }),
        );
      }
      const empty: ConversationSearchResponse = {
        hits: [],
        next_cursor: null,
        coverage: { schema_version: 1, state: "ready", indexed_missions: 10, total_missions: 10 },
      };
      return Promise.resolve(
        new Response(JSON.stringify(empty), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
    });
    globalThis.fetch = fetchMock;

    const recent: Mission[] = [
      {
        id: "m-recent",
        title: "Recent Architecture Sync",
        status: "active",
        project: "orb",
        history: [{ role: "user", content: "Check recent status" }],
        created_at: "2026-10-28T10:00:00Z",
        updated_at: "2026-10-29T01:00:00Z",
      },
    ];
    const onOpenHit = vi.fn();
    let currentQuery = "";

    const view = render(() => {
      return (
        <SearchDialog
          query={currentQuery}
          onQueryChange={q => {
            currentQuery = q;
            view.rerender(() => (
              <SearchDialog
                query={currentQuery}
                onQueryChange={() => {}}
                projects={[{ slug: "orb", title: "Orb" } as never]}
                recentMissions={recent}
                onClose={() => {}}
                onOpenMission={() => {}}
                onOpenHit={onOpenHit}
              />
            ));
          }}
          projects={[{ slug: "orb", title: "Orb" } as never]}
          recentMissions={recent}
          onClose={() => {}}
          onOpenMission={() => {}}
          onOpenHit={onOpenHit}
        />
      );
    });

    // Empty query shows recent conversations immediately in both list and preview.
    expect(screen.getAllByText("Recent Architecture Sync").length).toBeGreaterThanOrEqual(2);
    view.unmount();

    // Incomplete indexing never claims "No matching passages".
    const indexingView = render(() => (
      <SearchDialog
        query="indexing_probe"
        onQueryChange={() => {}}
        projects={[]}
        recentMissions={[]}
        onClose={() => {}}
        onOpenMission={() => {}}
        onOpenHit={onOpenHit}
      />
    ));
    await waitFor(() => {
      expect(screen.getByTestId("search-still-indexing")).toBeTruthy();
    });
    expect(screen.queryByTestId("search-empty")).toBeNull();
    expect(screen.queryByText(/No matching passages/i)).toBeNull();
    indexingView.unmount();

    // Out-of-order responses: "alpha" starts first, then user switches to "beta", then "alpha" resolves late.
    const [qSig, setQSig] = (await import("solid-js")).createSignal("alpha");
    const raceView = render(() => (
      <SearchDialog
        query={qSig()}
        onQueryChange={setQSig}
        projects={[]}
        recentMissions={[]}
        onClose={() => {}}
        onOpenMission={() => {}}
        onOpenHit={onOpenHit}
      />
    ));
    await new Promise(r => setTimeout(r, 150));
    setQSig("beta");
    await waitFor(() => {
      expect(screen.getAllByText(/Matched/).length).toBeGreaterThan(0);
    });

    // Resolve stale "alpha" response AFTER "beta" is already displayed.
    resolveSlowAlpha?.(
      new Response(
        JSON.stringify({
          hits: [
            {
              mission_id: "m-alpha",
              title: "Stale Alpha Hit",
              project: null,
              status: "active",
              backend: "opencode",
              updated_at: "2026-10-29T00:00:00Z",
              locator: "msg:seq:1",
              role: "user",
              sequence: 1,
              timestamp: "2026-10-29T00:00:00Z",
              excerpt: "Stale alpha excerpt",
              highlights: [],
              mission_match_count: 1,
              score: 5,
            },
          ],
          next_cursor: null,
          coverage: { schema_version: 1, state: "ready", indexed_missions: 10, total_missions: 10 },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
    await new Promise(r => setTimeout(r, 40));
    expect(screen.queryByText("Stale Alpha Hit")).toBeNull();

    // Pointer click on result row selects and previews without navigating away.
    const row = document.querySelector<HTMLElement>('[data-cs-index="0"]')!;
    expect(row).toBeTruthy();
    await fireEvent.click(row);
    expect(onOpenHit).not.toHaveBeenCalled();

    // Escaped HTML check: zero injected script or img tags.
    expect(document.body.querySelectorAll("script").length).toBe(0);
    expect(document.body.querySelectorAll("img[onerror]").length).toBe(0);

    // Explicit Open passage button navigates.
    await fireEvent.click(screen.getByTestId("search-open-hit"));
    expect(onOpenHit).toHaveBeenCalledTimes(1);
    expect(onOpenHit.mock.calls[0][0].mission_id).toBe("m-beta");

    // Disconnecting transitions cleanly to disconnected state without stale hits.
    clearConnection();
    await waitFor(() => {
      expect(screen.getByTestId("search-disconnected")).toBeTruthy();
    });
    raceView.unmount();
  });
});
