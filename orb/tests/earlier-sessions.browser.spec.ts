import { test, expect } from "@playwright/test";
test.use({
  browserName:
    process.env.ORB_TEST_BROWSER === "webkit" ? "webkit" : "chromium",
});
const earlier = "08ea5752-536d-4cef-9d9e-f29b117d89cc";
const report = `/var/lib/sandboxed-node/${earlier}/reports/ops-2026-10-27/RAPPORT-FINAL.md`;
test("a replacement mission opens its predecessor's files from the transcript and the tree", async ({ page }) => {
  const sources: string[] = [];
  await page.route("**/api/**", (route) => {
    if (!route.request().url().endsWith("/file-resources"))
      return route.fulfill({ json: {} });
    const q = route.request().postDataJSON();
    sources.push(q.source);
    let body: unknown = {};
    if (q.action === "roots")
      body = {
        sources: [
          { id: "workspace", label: "Workspace", machine: "nippur", available: true },
          { id: `earlier:${earlier}`, label: "security (fresh session) · 08ea5752", group: "earlier", mission: earlier, machine: "nippur", available: true },
        ],
      };
    // Each node source only matches absolute paths under its own root.
    const mine = (p: string) => q.source === `earlier:${earlier}` && p === report;
    if (q.action === "resolve")
      body = {
        results: q.paths.map((reference: string) => ({
          reference,
          matches: mine(reference)
            ? [{ name: "RAPPORT-FINAL.md", path: "reports/ops-2026-10-27/RAPPORT-FINAL.md", kind: "file" }]
            : [],
        })),
      };
    if (q.action === "list")
      body = {
        entries: q.source === "workspace"
          ? [{ name: ".cache", path: ".cache", kind: "dir" }]
          : [{ name: "reports", path: "reports", kind: "dir" }],
      };
    if (q.action === "read")
      body = q.source === `earlier:${earlier}`
        ? { content: "# Rapport final\n\nAucune attestation SOC 2.", size: 40, binary: false, truncated: false }
        : {};
    return route.fulfill({ json: body });
  });
  await page.setViewportSize({ width: 1500, height: 900 });
  await page.goto("/tests/earlier-sessions.html");
  await page.getByRole("button", { name: report, exact: true }).click();
  await expect(page.getByRole("heading", { name: "Rapport final" })).toBeVisible();
  expect(sources).toContain(`earlier:${earlier}`);
  // A path under an unrelated mission's root never becomes a link.
  await expect(page.getByRole("button", { name: /secret\.md/ })).toHaveCount(0);
  const tree = page.getByRole("navigation", { name: "File explorer" });
  await expect(tree.getByText("Earlier sessions")).toBeVisible();
  await expect(tree.getByRole("button", { name: /security \(fresh session\) · 08ea5752/ })).toBeVisible();
});
