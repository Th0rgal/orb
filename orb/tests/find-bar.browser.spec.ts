import http from "node:http";
import type { AddressInfo } from "node:net";
import { expect, test } from "@playwright/test";
import { JWT } from "./appPerfCore";

const MISSION_ID = "dddddddd-0000-4000-8000-000000000001";

function buildConversationEvents() {
  const out: Array<Record<string, unknown>> = [];
  let seq = 0;

  // 130 historical turns => 260 events so initial limit=200 tail leaves older history (`X-Has-More: true`).
  for (let t = 1; t <= 130; t++) {
    seq++;
    out.push({
      id: seq,
      sequence: seq,
      event_id: `u-${t}`,
      event_type: "user_message",
      content: `Historical user prompt ${t}`,
      timestamp: new Date(Date.UTC(2026, 9, 15) + seq * 1000).toISOString(),
    });
    seq++;
    out.push({
      id: seq,
      sequence: seq,
      event_id: `a-${t}`,
      event_type: "assistant_message",
      content:
        t === 3
          ? "Early ArchiveBeacon_404 final answer preserved in history."
          : `Historical assistant reply ${t} with concise details.`,
      timestamp: new Date(Date.UTC(2026, 9, 15) + seq * 1000).toISOString(),
    });
  }

  // Final rich turn with thoughts, intermediate narration, tool call/output, auto wake, and tall final answer.
  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "u-final",
    event_type: "user_message",
    content: "Please audit SentinelTarget handling across the client.",
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 1)).toISOString(),
  });

  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "th-final",
    event_type: "thinking",
    content: "Reasoning about ThoughtOnlySecret_808 and SentinelTarget internals.",
    metadata: { done: true },
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 2)).toISOString(),
  });

  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "opencode:narration-final",
    event_type: "assistant_message_canonical",
    content: "NarrationOnlySecret_809 inspecting SentinelTarget before running tools.",
    metadata: { bubble_id: "opencode:narration-final" },
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 3)).toISOString(),
  });

  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "tc-final",
    tool_call_id: "call-final-1",
    tool_name: "read_file",
    event_type: "tool_call",
    content: JSON.stringify({ path: "src/ToolArgSecret_810.ts" }),
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 4)).toISOString(),
  });

  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "tr-final",
    tool_call_id: "call-final-1",
    tool_name: "read_file",
    event_type: "tool_result",
    content: "ToolOutSecret_811 mentioning SentinelTarget inside file output",
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 5)).toISOString(),
  });

  const spacer = Array.from(
    { length: 22 },
    (_, idx) => `Section filler paragraph ${idx + 1} keeping tall multi-screen geometry realistic.`,
  ).join("\n\n");

  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "opencode:answer-final",
    event_type: "assistant_message_canonical",
    content: [
      "First occurrence of SentinelTarget near the top of the final answer.",
      spacer,
      "Second occurrence of SentinelTarget in the middle of the tall final answer.",
      spacer,
      "Third occurrence of SentinelTarget at the bottom of the final answer.",
    ].join("\n\n"),
    metadata: { bubble_id: "opencode:answer-final" },
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 6)).toISOString(),
  });

  seq++;
  out.push({
    id: seq,
    sequence: seq,
    event_id: "u-auto-wake",
    event_type: "user_message",
    content: "AutoWakeSecret_812 SentinelTarget coordinator ping",
    metadata: { source: "background-task" },
    timestamp: new Date(Date.UTC(2026, 9, 16, 1, 0, 7)).toISOString(),
  });

  return out;
}

async function startFindMockCore() {
  const allEvents = buildConversationEvents();
  let transcriptSpineRequests = 0;
  let rawOlderRequests = 0;

  const mission = {
    id: MISSION_ID,
    title: "Cursor Find UX Verification",
    backend: "opencode",
    project: "orb",
    status: "completed",
    history: [],
    created_at: "2026-10-15T00:00:00Z",
    updated_at: "2026-10-16T01:00:10Z",
  };

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

    if (path.endsWith("/events")) {
      const view = url.searchParams.get("view");
      const since = url.searchParams.get("since_seq");
      const before = url.searchParams.get("before_seq");
      if (view === "transcript") {
        if (before !== null) transcriptSpineRequests++;
        const spine = allEvents.filter(
          e =>
            (e.event_type === "user_message" ||
              e.event_type === "assistant_message" ||
              e.event_type === "assistant_message_canonical") &&
            (before === null || (e.sequence as number) < Number(before)),
        );
        const seqs = spine.map(e => e.sequence as number);
        return json(res, spine, {
          "X-Orb-Events-Protocol": "1",
          "X-Has-More": "false",
          "X-Max-Sequence": String(allEvents.length),
          ...(seqs.length
            ? {
                "X-Page-Max-Sequence": String(Math.max(...seqs)),
                "X-Next-Cursor": String(Math.min(...seqs)),
              }
            : {}),
        });
      }

      if (before !== null) rawOlderRequests++;
      let page = allEvents.filter(
        e =>
          (since === null || (e.sequence as number) > Number(since)) &&
          (before === null || (e.sequence as number) < Number(before)),
      );
      const limit = Number(url.searchParams.get("limit") ?? 200);
      const more = page.length > limit;
      page = since !== null ? page.slice(0, limit) : page.slice(-limit);
      const seqs = page.map(e => e.sequence as number);
      return json(res, page, {
        "X-Orb-Events-Protocol": "1",
        "X-Has-More": String(more),
        "X-Max-Sequence": String(allEvents.length),
        ...(seqs.length
          ? {
              "X-Page-Max-Sequence": String(Math.max(...seqs)),
              "X-Next-Cursor": String(since === null ? Math.min(...seqs) : Math.max(...seqs)),
            }
          : {}),
      });
    }

    if (path === "/api/projects") return json(res, { projects: [{ slug: "orb", title: "Orb" }] });
    if (path === "/api/control/missions") return json(res, [mission]);
    if (path.startsWith("/api/control/missions/") && path.split("/").length === 5) {
      return json(res, mission);
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
    stats: () => ({ transcriptSpineRequests, rawOlderRequests }),
    close: () => {
      server.closeAllConnections();
      return new Promise<void>(resolve => server.close(() => resolve()));
    },
  };
}

test("FindBar matches Cursor UX, searches only final messages, paints passive+active highlights, and scrolls exact ranges", async ({
  page,
}) => {
  const core = await startFindMockCore();
  try {
    await page.addInitScript(
      a => {
        localStorage.setItem("orb.apiUrl", a.url);
        localStorage.setItem("orb.jwt", a.jwt);
      },
      { url: core.url, jwt: JWT },
    );

    await page.goto("/");
    await page.getByRole("button", { name: "Orb", exact: true }).click({ timeout: 15000 });
    await page.getByText("Cursor Find UX Verification").first().click();
    await expect(page.getByText("Third occurrence of SentinelTarget")).toBeVisible({ timeout: 10000 });

    const isMac = await page.evaluate(() => /mac|iphone|ipad|ipod/i.test(navigator.platform));
    const findChord = isMac ? "Meta+f" : "Control+f";

    await page.locator(".scroll").click({ position: { x: 40, y: 120 } });
    await page.keyboard.press(findChord);

    const bar = page.locator(".find-bar");
    const field = page.locator(".find-field");
    const input = page.getByRole("textbox", { name: "Find in conversation" });
    const count = page.locator(".find-count");

    await expect(bar).toBeVisible();
    await expect(input).toBeFocused();
    await expect(count).toHaveText("");

    // Verify no inner focus halo on bare <input> in both dark and light mode, and stable bar geometry.
    for (const theme of ["dark", "light"] as const) {
      await page.evaluate(t => {
        if (t === "light") document.documentElement.dataset.theme = "light";
        else delete document.documentElement.dataset.theme;
      }, theme);
      const boxShadow = await input.evaluate(el => getComputedStyle(el).boxShadow);
      expect(boxShadow).toBe("none");
    }
    await page.evaluate(() => {
      delete document.documentElement.dataset.theme;
    });

    const initialBarBox = await bar.boundingBox();
    const initialFieldBox = await field.boundingBox();
    expect(initialBarBox).not.toBeNull();
    expect(initialFieldBox).not.toBeNull();

    // Non-message tokens (thoughts, WorkFold narration, tool args/results, auto wakes) must never match
    // and must never expand collapsed WorkFold disclosures.
    for (const excludedToken of [
      "ThoughtOnlySecret_808",
      "NarrationOnlySecret_809",
      "ToolArgSecret_810",
      "ToolOutSecret_811",
      "AutoWakeSecret_812",
    ]) {
      await input.fill(excludedToken);
      await expect(count).toHaveText("No results");
    }
    await expect(page.locator(".st-work-head").first()).toHaveAttribute("aria-expanded", "false");

    const noResultBarBox = await bar.boundingBox();
    expect(Math.abs(noResultBarBox!.width - initialBarBox!.width)).toBeLessThanOrEqual(1);

    // Search "SentinelTarget": 1 in user prompt + 3 in tall final answer = 4 matches total!
    await input.fill("SentinelTarget");
    await expect(count).toContainText("/ 4");

    const matchedBarBox = await bar.boundingBox();
    expect(Math.abs(matchedBarBox!.width - initialBarBox!.width)).toBeLessThanOrEqual(1);

    // Both passive (orb-find) and active (orb-find-current) CSS highlights are populated!
    const highlightSizes = await page.evaluate(() => {
      const reg = (CSS as unknown as { highlights?: Map<string, { size: number }> }).highlights;
      return {
        passive: reg?.get("orb-find")?.size ?? 0,
        active: reg?.get("orb-find-current")?.size ?? 0,
      };
    });
    expect(highlightSizes.active).toBe(1);
    expect(highlightSizes.passive).toBeGreaterThanOrEqual(1);

    // Stepping through all 4 occurrences scrolls each active Range into clear view below FindBar!
    const seenTops: number[] = [];
    for (let stepIdx = 0; stepIdx < 4; stepIdx++) {
      await input.press("Enter");
      const activePosition = await page.evaluate(() => {
        const scroller = document.querySelector(".scroll")!;
        const barEl = document.querySelector(".find-bar")!;
        const reg = (CSS as unknown as { highlights?: Map<string, Set<Range>> }).highlights;
        const current = reg?.get("orb-find-current");
        const range = current ? [...current][0] : undefined;
        if (!range) return null;
        const r = range.getBoundingClientRect();
        const s = scroller.getBoundingClientRect();
        const b = barEl.getBoundingClientRect();
        const overlapsBarHorizontally = r.right > b.left - 8;
        const minTop = overlapsBarHorizontally ? b.bottom : s.top;
        return {
          inView: r.top >= minTop - 2 && r.bottom <= s.bottom + 2,
          docY: Math.round(scroller.scrollTop + (r.top - s.top)),
        };
      });
      expect(activePosition).not.toBeNull();
      expect(activePosition!.inView).toBe(true);
      seenTops.push(activePosition!.docY);
    }
    // 4 distinct vertical match positions across the prompt and tall 3-part answer!
    expect(new Set(seenTops).size).toBe(4);

    // Search preparation hydrated the >200-event history via 1 fast view=transcript spine request and 0 raw older loops!
    expect(core.stats().transcriptSpineRequests).toBe(1);
    expect(core.stats().rawOlderRequests).toBe(0);

    // Deep historical match (>200 events back) resolves immediately from the hydrated spine and scrolls into view!
    // (Once scroller reaches scrollTop < 800 at turn 0, MissionView's normal scrollback listener may fetch raw tool details.)
    await input.fill("ArchiveBeacon_404");
    await expect(count).toHaveText("1 / 1");
    await expect(page.getByText("Early ArchiveBeacon_404 final answer preserved in history.")).toBeVisible();
    expect(core.stats().transcriptSpineRequests).toBe(1);
  } finally {
    await core.close();
  }
});
