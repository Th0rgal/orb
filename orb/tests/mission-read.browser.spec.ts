import { expect, test } from "@playwright/test";

test("refreshing an opened conversation does not repeat its read receipt", async ({ page }) => {
  let reads = 0, receipts = 0;
  const mission = { id: "read-once", title: "Read receipt", status: "completed", project: "test", backend: "antigravity", history: [], created_at: "2026-10-09T10:00:00Z", updated_at: "2026-10-09T10:01:00Z" };
  await page.addInitScript(() => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
  });
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/api/control/missions/read-once") { reads++; return route.fulfill({ json: mission }); }
    if (path.endsWith("/opened")) { receipts++; return route.fulfill({ json: mission }); }
    if (path.endsWith("/events")) return route.fulfill({ json: [], headers: { "X-Orb-Events-Protocol": "1", "X-Has-More": "false", "X-Max-Sequence": "0" } });
    const json = path === "/api/projects" ? { projects: [{ slug: "test", title: "test" }] }
      : path === "/api/control/missions" ? [mission]
      : path.endsWith("/manifest") ? { revision: 1, entries: {} }
      : path.endsWith("/files") ? { entries: [] } : [];
    return route.fulfill({ json });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "test", exact: true }).click();
  await page.getByRole("button", { name: "Read receipt", exact: true }).click();
  await expect(page.getByPlaceholder("Send follow-up")).toBeVisible();
  await expect.poll(() => receipts).toBe(1);
  for (let i = 0; i < 3; i++) {
    const before = reads;
    // A refresh follows Core's status event after recording the opened receipt.
    await page.evaluate(() => window.dispatchEvent(new Event("orb:refresh")));
    await expect.poll(() => reads).toBeGreaterThan(before);
  }
  expect(receipts).toBe(1);
});
