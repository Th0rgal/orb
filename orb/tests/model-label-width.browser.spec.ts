import {test, expect} from "@playwright/test";

const missionId = "11111111-2222-3333-4444-555555555555";
const model = "ethereumfoundation/deepseek-v4.1-flash";

function mission() {
  return {
    id: missionId,
    title: "Model label width",
    status: "completed",
    backend: "opencode",
    model_override: model,
    project: "orb",
    history: [],
    created_at: "2026-11-05T09:50:00Z",
    updated_at: "2026-11-05T10:00:00Z",
  };
}

async function openMission(page: import("@playwright/test").Page) {
  await page.addInitScript((id) => {
    localStorage.setItem("orb.apiUrl", location.origin);
    localStorage.setItem("orb.jwt", "test");
    localStorage.setItem("orb.selectedConversation", `m:${id}`);
  }, missionId);
  await page.route("**/api/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    const json = path === "/api/backends"
      ? [{id: "opencode", name: "OpenCode"}]
      : path === "/api/providers/backend-models"
        ? {backends: {opencode: [{value: model, label: model}]}}
        : path === "/api/model-routing/chains"
          ? []
          : path === "/api/projects"
            ? {projects: [{slug: "orb", name: "orb"}]}
            : path === "/api/control/missions"
              ? [mission()]
              : path === `/api/control/missions/${missionId}`
                ? mission()
                : path.endsWith("/events")
                  ? {events: [], has_more: false}
                  : path.endsWith("/stream")
                    ? {events: [], has_more: false}
                    : path === "/api/remote-nodes"
                      ? {enabled: true, nodes: []}
                      : path.endsWith("/crons")
                        ? {jobs: []}
                        : {entries: [], job: null, runs: []};
    return route.fulfill({json});
  });
  await page.goto("/");
  await expect(page.locator(".under")).toBeVisible();
  await expect(page.locator(".under-model")).toContainText(model);
}

test("model label uses available width before truncating", async ({page}) => {
  await openMission(page);
  const metrics = await page.locator(".under").evaluate((row) => {
    const label = row.querySelector<HTMLElement>(".under-model .model-label")!;
    return {labelWidth: label.clientWidth, labelScrollWidth: label.scrollWidth, text: label.textContent};
  });
  expect(metrics.labelScrollWidth).toBeLessThanOrEqual(metrics.labelWidth);
  expect(metrics.text).toBe(model);
  await page.screenshot({path: "test-results/model-label-wide.png"});
});

test("narrow model label truncates without pushing the context badge out of the row", async ({page}) => {
  await page.setViewportSize({width: 360, height: 900});
  await openMission(page);
  const metrics = await page.locator(".under").evaluate((row) => {
    const label = row.querySelector<HTMLElement>(".under-model .model-label")!;
    const badge = row.querySelector<HTMLElement>(".ctx")!;
    const rowBox = row.getBoundingClientRect();
    const badgeBox = badge.getBoundingClientRect();
    return {
      labelWidth: label.clientWidth,
      labelScrollWidth: label.scrollWidth,
      rowWidth: row.clientWidth,
      rowScrollWidth: row.scrollWidth,
      badgeInside: badgeBox.left >= rowBox.left && badgeBox.right <= rowBox.right,
      title: label.closest(".under-model")?.getAttribute("title"),
    };
  });
  expect(metrics.labelScrollWidth).toBeGreaterThan(metrics.labelWidth);
  expect(metrics.rowScrollWidth).toBeLessThanOrEqual(metrics.rowWidth);
  expect(metrics.badgeInside).toBe(true);
  expect(metrics.title).toBe(model);
});
