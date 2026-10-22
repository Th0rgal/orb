import { expect, test } from "@playwright/test";
import fixture from "./fixtures/stale-tasks-ccd5a32b.json" with { type: "json" };

const shots = process.env.ORB_STALE_TASKS_SHOTS;

for (const theme of ["dark", "light"] as const) {
  test(`ccd5a32b: a finished turn with a stale task list is neutral (${theme})`, async ({ page }) => {
    await page.goto("/tests/transcript.html");
    await page.waitForFunction(() => !!(window as any).transcriptHarness);
    await page.evaluate(([events, theme]) => {
      document.documentElement.dataset.theme = theme as string;
      const h = (window as any).transcriptHarness;
      h.setWorking(false);
      h.reset(events);
    }, [fixture.events, theme] as const);
    const card = page.locator(".mission-tasks");
    await expect(card).toHaveAttribute("data-state", "stale");
    await expect(card.locator(".tasks-count")).toHaveText("Task list not updated · turn finished (2/4 completed)");
    await expect(card).not.toContainText("Stopped");
    await expect(card.locator('li[data-status="stale"]')).toHaveCount(2);
    await card.scrollIntoViewIfNeeded();
    if (shots) await card.screenshot({ path: `${shots}/tasks-card-stale-${theme}.png` });

    // The same list after an interrupted turn keeps the Stopped label.
    await page.evaluate(([events]) => (window as any).transcriptHarness.reset([...(events as unknown[]).slice(0, -1), { type: "assistant_message", data: { content: "Interrupted", success: false } }]), [fixture.events] as const);
    await expect(card).toHaveAttribute("data-state", "stopped");
    await expect(card.locator(".tasks-count")).toHaveText("Stopped at step 3/4");
    if (shots) await card.screenshot({ path: `${shots}/tasks-card-stopped-${theme}.png` });
  });
}
