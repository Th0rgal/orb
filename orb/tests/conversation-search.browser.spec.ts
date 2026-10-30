import http from "node:http";
import type { AddressInfo } from "node:net";
import { expect, test } from "@playwright/test";
import { JWT } from "./appPerfCore";

const DEEP_ID = "cccccccc-0000-4000-8000-000000000001";
const EDITED_ID = "cccccccc-0000-4000-8000-000000000002";

function buildDeepEvents() {
  // 160 turns = 320 events. Initial `/events?limit=200` only returns sequences 121..320,
  // so sequence 14 (turn 7) is far beyond the 200-message initial tail window!
  const out: Array<Record<string, unknown>> = [];
  let seq = 0;
  for (let t = 1; t <= 160; t++) {
    seq++;
    out.push({
      id: seq,
      sequence: seq,
      event_id: `e${seq}`,
      event_type: "user_message",
      content: `User question for turn ${t}`,
      timestamp: new Date(Date.UTC(2026, 9, 10) + seq * 1000).toISOString(),
    });
    seq++;
    out.push({
      id: seq,
      sequence: seq,
      event_id: `e${seq}`,
      event_type: "assistant_message",
      content:
        t === 7
          ? `Early needle42 passage at turn 7 with <script>window.__xss=1</script> safe text.`
          : `Assistant detailed answer for turn ${t}.\n\nParagraph filler to ensure scrollable height (${t}).`,
      timestamp: new Date(Date.UTC(2026, 9, 10) + seq * 1000).toISOString(),
    });
  }
  return out;
}

async function startSearchMockCore() {
  const deepEvents = buildDeepEvents();
  const editedEvents = [
    {
      id: 1,
      sequence: 1,
      event_id: "ed-1",
      event_type: "user_message",
      content: "Check edited passage behaviour",
      timestamp: "2026-10-25T10:00:00Z",
    },
    {
      id: 2,
      sequence: 2,
      event_id: "ed-2",
      event_type: "assistant_message",
      content: "Updated passage text after replacement.",
      timestamp: "2026-10-25T10:00:05Z",
    },
  ];

  const missions = [
    {
      id: DEEP_ID,
      title: "Deep Archived Thread",
      backend: "opencode",
      project: "orb",
      status: "completed",
      history: [],
      created_at: "2026-10-10T00:00:00Z",
      updated_at: "2026-10-20T00:00:00Z",
    },
    {
      id: EDITED_ID,
      title: "Edited Conversation",
      backend: "opencode",
      project: "orb",
      status: "active",
      history: [],
      created_at: "2026-10-25T10:00:00Z",
      updated_at: "2026-10-25T10:05:00Z",
    },
  ];

  let createMissionCount = 0;

  const json = (
    res: http.ServerResponse,
    body: unknown,
    headers: Record<string, string> = {},
  ) => {
    res.writeHead(200, { "Content-Type": "application/json", ...headers });
    res.end(JSON.stringify(body));
  };

  const server = http.createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Headers", "*");
    res.setHeader("Access-Control-Allow-Methods", "*");
    res.setHeader(
      "Access-Control-Expose-Headers",
      "X-Orb-Events-Protocol, X-Has-More, X-Max-Sequence, X-Next-Cursor, X-Page-Max-Sequence",
    );
    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url!, "http://127.0.0.1");
    const path = url.pathname;

    if (path === "/api/control/stream") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
      res.write(": open\n\n");
      return;
    }

    if (path === "/api/control/missions" && req.method === "POST") {
      createMissionCount++;
      return json(res, missions[0]);
    }

    if (path === "/api/control/missions/search/messages") {
      const q = (url.searchParams.get("q") ?? "").trim();
      if (q === "slowfirst") {
        const timer = setTimeout(() => {
          json(res, {
            hits: [
              {
                mission_id: EDITED_ID,
                title: "Stale Slow Hit",
                project: "orb",
                status: "active",
                backend: "opencode",
                updated_at: "2026-10-25T10:05:00Z",
                locator: "msg:seq:1",
                role: "user",
                sequence: 1,
                event_id: "ed-1",
                timestamp: "2026-10-25T10:00:00Z",
                excerpt: "Stale slowfirst result that must be discarded",
                highlights: [{ start: 6, end: 15 }],
                mission_match_count: 1,
                score: 4,
              },
            ],
            next_cursor: null,
            coverage: { schema_version: 1, state: "ready", indexed_missions: 2, total_missions: 2 },
          });
        }, 220);
        req.on("close", () => clearTimeout(timer));
        return;
      }

      if (q === "needle42") {
        return json(res, {
          hits: [
            {
              mission_id: DEEP_ID,
              title: "Deep Archived Thread",
              project: "orb",
              status: "completed",
              backend: "opencode",
              updated_at: "2026-10-20T00:00:00Z",
              locator: "msg:id:e14",
              role: "assistant",
              sequence: 14,
              event_id: "e14",
              timestamp: "2026-10-10T00:00:14Z",
              excerpt: "Early needle42 passage at turn 7 with <script>window.__xss=1</script>",
              highlights: [{ start: 6, end: 14 }],
              mission_match_count: 2,
              score: 18,
            },
            {
              mission_id: DEEP_ID,
              title: "Deep Archived Thread",
              project: "orb",
              status: "completed",
              backend: "opencode",
              updated_at: "2026-10-20T00:00:00Z",
              locator: "msg:id:e13",
              role: "user",
              sequence: 13,
              event_id: "e13",
              timestamp: "2026-10-10T00:00:13Z",
              excerpt: "User question for turn 7",
              highlights: [],
              mission_match_count: 2,
              score: 9,
            },
          ],
          next_cursor: null,
          coverage: { schema_version: 1, state: "ready", indexed_missions: 2, total_missions: 2 },
        });
      }

      if (q === "edited_hit") {
        return json(res, {
          hits: [
            {
              mission_id: EDITED_ID,
              title: "Edited Conversation",
              project: "orb",
              status: "active",
              backend: "opencode",
              updated_at: "2026-10-25T10:05:00Z",
              locator: "msg:id:deleted-99",
              role: "assistant",
              sequence: 2,
              event_id: "deleted-99",
              timestamp: "2026-10-25T10:00:05Z",
              excerpt: "Old edited_hit text before replacement",
              highlights: [{ start: 4, end: 14 }],
              mission_match_count: 1,
              score: 12,
            },
          ],
          next_cursor: null,
          coverage: { schema_version: 1, state: "ready", indexed_missions: 2, total_missions: 2 },
        });
      }

      return json(res, {
        hits: [],
        next_cursor: null,
        coverage: { schema_version: 1, state: "ready", indexed_missions: 2, total_missions: 2 },
      });
    }

    const ctxMatch = path.match(/^\/api\/control\/missions\/([^/]+)\/messages\/context$/);
    if (ctxMatch) {
      const id = ctxMatch[1];
      const includeEvents = url.searchParams.get("include_events") === "true";
      if (id === DEEP_ID) {
        const windowEvents = deepEvents.filter(
          e => (e.sequence as number) >= 11 && (e.sequence as number) <= 18,
        );
        return json(res, {
          mission_id: DEEP_ID,
          title: "Deep Archived Thread",
          project: "orb",
          status: "completed",
          backend: "opencode",
          updated_at: "2026-10-20T00:00:00Z",
          locator: "msg:id:e14",
          target_found: true,
          target_sequence: 14,
          messages: [
            {
              locator: "msg:id:e13",
              role: "user",
              sequence: 13,
              event_id: "e13",
              timestamp: "2026-10-10T00:00:13Z",
              content: "User question for turn 7",
              highlights: [],
              is_target: false,
            },
            {
              locator: "msg:id:e14",
              role: "assistant",
              sequence: 14,
              event_id: "e14",
              timestamp: "2026-10-10T00:00:14Z",
              content:
                "Early needle42 passage at turn 7 with <script>window.__xss=1</script> safe text.",
              highlights: [{ start: 6, end: 14 }],
              is_target: true,
            },
          ],
          ...(includeEvents ? { events: windowEvents } : {}),
        });
      }
      return json(res, {
        mission_id: EDITED_ID,
        title: "Edited Conversation",
        project: "orb",
        status: "active",
        backend: "opencode",
        updated_at: "2026-10-25T10:05:00Z",
        locator: "msg:id:deleted-99",
        target_found: false,
        target_sequence: 2,
        messages: [
          {
            locator: "msg:id:ed-2",
            role: "assistant",
            sequence: 2,
            event_id: "ed-2",
            timestamp: "2026-10-25T10:00:05Z",
            content: "Updated passage text after replacement.",
            highlights: [],
            is_target: false,
          },
        ],
        ...(includeEvents ? { events: editedEvents } : {}),
      });
    }

    if (path.endsWith("/events")) {
      const id = path.split("/")[4];
      const rows = id === DEEP_ID ? deepEvents : editedEvents;
      const since = url.searchParams.get("since_seq");
      const before = url.searchParams.get("before_seq");
      let page = rows.filter(
        e =>
          (since === null || (e.sequence as number) > Number(since)) &&
          (before === null || (e.sequence as number) < Number(before)),
      );
      const limit = Number(url.searchParams.get("limit") ?? 200);
      const more = page.length > limit;
      page = since !== null ? page.slice(0, limit) : page.slice(-limit);
      const seqs = page.map(e => e.sequence as number);
      const headers: Record<string, string> = {
        "X-Orb-Events-Protocol": "1",
        "X-Has-More": String(more),
        "X-Max-Sequence": String(rows.length),
      };
      if (seqs.length) {
        headers["X-Page-Max-Sequence"] = String(Math.max(...seqs));
        headers["X-Next-Cursor"] = String(
          since === null ? Math.min(...seqs) : Math.max(...seqs),
        );
      }
      return json(res, page, headers);
    }

    if (path === "/api/projects") {
      return json(res, { projects: [{ slug: "orb", title: "Orb" }] });
    }
    if (path === "/api/control/missions") {
      return json(res, missions);
    }
    if (path.startsWith("/api/control/missions/") && path.split("/").length === 5) {
      const id = path.split("/")[4];
      return json(res, missions.find(m => m.id === id) ?? missions[0]);
    }
    if (path.endsWith("/files")) return json(res, { entries: [] });
    if (path.endsWith("/crons")) return json(res, { jobs: [] });
    if (path.includes("/controller")) return json(res, { job: null, runs: [] });
    if (path === "/api/providers/backend-models") return json(res, { backends: {} });
    if (/queue|backends|remote-nodes|automations|approval/.test(path)) {
      return json(res, path.includes("approval") ? { items: [] } : []);
    }
    return json(res, {});
  });

  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    getCreateMissionCount: () => createMissionCount,
    close: () => {
      server.closeAllConnections();
      return new Promise<void>(resolve => server.close(() => resolve()));
    },
  };
}

test("global conversation search: <100ms open, draft safety, out-of-order rejection, narrow layout, and >200-message passage jump", async ({
  page,
}) => {
  const core = await startSearchMockCore();
  try {
    await page.addInitScript(
      a => {
        localStorage.setItem("orb.apiUrl", a.url);
        localStorage.setItem("orb.jwt", a.jwt);
      },
      { url: core.url, jwt: JWT },
    );

    await page.goto("/");
    const composer = page.locator("textarea").first();
    await expect(composer).toBeVisible();

    // Prewarm idle timer settles quickly; type an unsent draft in the composer.
    await composer.click();
    await composer.fill("Keep my unsent draft intact");

    const isMac = await page.evaluate(() => /mac|iphone|ipad|ipod/i.test(navigator.platform));
    const chord = isMac ? "Meta+Shift+f" : "Control+Shift+f";

    // Measure shortcut open + input focus latency (< 100 ms target).
    const openMs = await page.evaluate(
      async ({ isMacPlatform }) => {
        const t0 = performance.now();
        window.dispatchEvent(
          new KeyboardEvent("keydown", {
            key: "F",
            code: "KeyF",
            shiftKey: true,
            metaKey: isMacPlatform,
            ctrlKey: !isMacPlatform,
            bubbles: true,
            cancelable: true,
          }),
        );
        await new Promise<void>(resolve => {
          const check = () => {
            const dlg = document.querySelector('[data-testid="conversation-search-dialog"]');
            const active = document.activeElement;
            if (dlg && active instanceof HTMLInputElement && dlg.contains(active)) {
              resolve();
              return;
            }
            requestAnimationFrame(check);
          };
          check();
        });
        return performance.now() - t0;
      },
      { isMacPlatform: isMac },
    );
    console.log("SEARCH_DIALOG_OPEN_MS", Number(openMs.toFixed(2)));
    expect(openMs).toBeLessThan(100);
    expect(core.getCreateMissionCount()).toBe(0);

    // Escape closes and restores focus to the composer with draft untouched.
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("conversation-search-dialog")).toBeHidden();
    await expect(composer).toBeFocused();
    await expect(composer).toHaveValue("Keep my unsent draft intact");

    // Titlebar Search button opens the same surface; pressing shortcut again focuses input without duplicating.
    await page.getByRole("button", { name: "Search conversations" }).click();
    const dialog = page.getByTestId("conversation-search-dialog");
    await expect(dialog).toBeVisible();
    await dialog.getByRole("button", { name: "User" }).focus();
    await page.keyboard.press(chord);
    const searchInput = dialog.getByRole("combobox", {
      name: "Search conversations and messages",
    });
    await expect(searchInput).toBeFocused();
    await expect(page.getByTestId("conversation-search-dialog")).toHaveCount(1);

    // Reset role filter to All, trigger out-of-order slowfirst -> needle42 race.
    await dialog.getByRole("button", { name: "All", exact: true }).click();
    await searchInput.fill("slowfirst");
    await page.waitForTimeout(140); // Let slowfirst request start in-flight
    await searchInput.fill("needle42");

    await expect(dialog.locator(".cs-row-excerpt").first()).toContainText("Early needle42 passage");
    await page.waitForTimeout(260); // Wait past slowfirst's 220ms server delay
    await expect(dialog).not.toContainText("Stale slowfirst result");

    // Verify XSS escaping in both dark and light themes.
    expect(await page.evaluate(() => (window as unknown as { __xss?: number }).__xss)).toBeUndefined();
    await page.evaluate(() => document.documentElement.setAttribute("data-theme", "light"));
    await expect(dialog.locator("mark.cs-mark").first()).toHaveText("needle42");
    await page.evaluate(() => document.documentElement.removeAttribute("data-theme"));

    // Narrow layout (<720px) uses second-view preview instead of squeezing columns.
    await page.setViewportSize({ width: 390, height: 844 });
    await dialog.locator('[data-cs-index="0"]').click();
    await expect(dialog.locator(".cs-body")).toHaveAttribute("data-mobile-pane", "preview");
    await dialog.getByRole("button", { name: "Results" }).click();
    await expect(dialog.locator(".cs-body")).toHaveAttribute("data-mobile-pane", "results");
    await page.setViewportSize({ width: 1100, height: 900 });

    // Press Enter on the selected needle42 hit (sequence 14 of 320, beyond the 200-event window).
    await searchInput.focus();
    await page.keyboard.press("Enter");
    await expect(dialog).toBeHidden();

    const matchedTurnText = page.getByText(/Early needle42 passage at turn 7/);
    await expect(matchedTurnText).toBeVisible({ timeout: 10_000 });
    await expect(page.locator(".search-target-flash")).toBeVisible();

    // Edited/removed hit reconciles visibly via toast while keeping conversation usable.
    await page.keyboard.press(chord);
    await expect(searchInput).toBeFocused();
    await searchInput.fill("edited_hit");
    await expect(dialog.locator(".cs-row-excerpt").first()).toContainText("Old edited_hit text");
    await page.keyboard.press("Enter");
    await expect(page.getByText("Passage updated since search")).toBeVisible();
    await expect(page.getByText("Updated passage text after replacement.")).toBeVisible();

    // Command-F inside the focused sidebar opens global search, and Command-\ toggles full-width Zen mode.
    const findChord = isMac ? "Meta+f" : "Control+f";
    const zenChord = isMac ? "Meta+\\" : "Control+\\";
    const btwChord = isMac ? "Meta+k" : "Control+k";
    await page.locator("#orb-sidebar button.row").first().focus();
    await page.keyboard.press(findChord);
    await expect(dialog).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();

    // Command-K opens /btw on the open conversation; Command-\ from main hides both sidebar and /btw, then restores both.
    await page.keyboard.press(btwChord);
    await expect(page.locator(".btw-sidebar")).toBeVisible();
    await page.locator(".main textarea").first().focus();
    await page.keyboard.press(zenChord);
    await expect(page.locator(".app")).toHaveClass(/sb-hidden/);
    await expect(page.locator(".btw-sidebar")).not.toBeVisible();
    await page.keyboard.press(zenChord);
    await expect(page.locator(".app")).not.toHaveClass(/sb-hidden/);
    await expect(page.locator(".btw-sidebar")).toBeVisible();
  } finally {
    await core.close();
  }
});
