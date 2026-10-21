import { expect, test } from "@playwright/test";

// Regression: a card whose mission keeps changing (events streaming in) used to flip its
// status line between "Generating summary…", "Summary unavailable" and "AI summary"
// several times per second, because the state was keyed by the mission's updatedMs.
test("inbox card summary status stays stable while the mission keeps updating", async ({ page }) => {
  const base = Date.parse("2026-10-21T10:00:00Z");
  let tick = 0;
  let digestCalls = 0;
  await page.addInitScript((base) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test-token");
    localStorage.setItem(`orb.btw:v1:${JSON.stringify([location.origin, "authenticated", "settings:inbox"])}`,
      JSON.stringify({ aiSummary: true, model: "builtin/smart" }));
    localStorage.setItem(`orb.btw:v1:${JSON.stringify([location.origin, "authenticated", "orb:inbox-digest:v7"])}`, JSON.stringify({
      [`health:${base}:builtin/smart`]: {
        schemaVersion: 7, sourceRevision: "r0", sourceUpdatedAt: new Date(base).toISOString(), task: "", verdict: "waiting",
        aiGenerated: true, model: "builtin/smart", updatedMs: base,
        outcome: "À faire côté toi : valider le fix #28.", sources: [{ quote: "Valider le fix #28 avant la release." }],
      },
    }));
  }, base);
  const mission = () => ({
    id: "health", title: "Ok, je veux que tu décompliques l'application", project: "health", status: "awaiting_user",
    backend: "claudecode", created_at: "2026-10-21T09:00:00Z", updated_at: new Date(base + 1000 * ++tick).toISOString(),
    history: [{ role: "user", content: "Simplifie l'application." }, { role: "assistant", content: "Valider le fix #28 avant la release." }],
  });
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/projects") return route.fulfill({ json: { projects: [{ slug: "health", title: "Health Manager", color: "green" }] } });
    if (path === "/api/control/missions") return route.fulfill({ json: [mission()] });
    if (path.endsWith("/inbox-digest")) {
      digestCalls++;
      await new Promise((r) => setTimeout(r, 400));
      return route.fulfill({ json: {
        schemaVersion: 7, sourceRevision: `r${digestCalls}`, sourceUpdatedAt: new Date(base).toISOString(), model: "builtin/smart",
        outcome: "À faire côté toi : valider le fix #28.", sources: [{ quote: "Valider le fix #28 avant la release." }],
      } });
    }
    const match = path.match(/^\/api\/control\/missions\/([^/]+)(\/events)?$/);
    if (match) {
      if (match[2]) return route.fulfill({ headers: { "X-Orb-Events-Protocol": "1", "X-Has-More": "false" }, json: [] });
      return route.fulfill({ json: mission() });
    }
    if (path.endsWith("/queue")) return route.fulfill({ json: [] });
    if (path === "/api/control/stream") return route.fulfill({ contentType: "text/event-stream", body: "" });
    return route.fulfill({ json: {} });
  });
  await page.goto("/");
  await page.locator("#orb-sidebar").getByRole("button", { name: /^Inbox/ }).click();
  const origin = page.locator('[data-inbox-id="health"] .inbox-summary-origin');
  await expect(origin).toBeVisible();
  const samples: string[] = await page.evaluate(async () => {
    const out: string[] = [];
    const end = performance.now() + 3000;
    // Keep the mission "streaming": focus/visibility and poll triggers refresh it constantly.
    const pump = setInterval(() => window.dispatchEvent(new Event("focus")), 100);
    while (performance.now() < end) {
      out.push(document.querySelector('[data-inbox-id="health"] .inbox-summary-origin')?.textContent ?? "");
      await new Promise((r) => requestAnimationFrame(r));
    }
    clearInterval(pump);
    return out;
  });
  const changes = samples.filter((s, i) => i > 0 && s !== samples[i - 1]).length;
  expect(changes, `status samples: ${[...new Set(samples)].join(" | ")}`).toBeLessThanOrEqual(1);
  expect(samples.some((s) => /Generating summary|Summary unavailable/.test(s))).toBe(false);
  await expect(page.locator('[data-inbox-id="health"] .inbox-summary')).toContainText("valider le fix #28");
});
