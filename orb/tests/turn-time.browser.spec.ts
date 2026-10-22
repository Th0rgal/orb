import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";

const shots = process.env.ORB_UI_REPORT_DIR ?? "test-results/ui-hover-time";
mkdirSync(shots, { recursive: true });

for (const theme of ["dark", "light"]) test(`completed turns show when they finished and how long they worked (${theme})`, async ({ page }) => {
  await page.goto(`/tests/turn-time.html?theme=${theme}`);
  const first = page.locator(".st-text").first();
  await expect(first).toContainText("Refactored the session store");
  const label = first.locator(".response-time");
  await expect(label).toHaveText("6d ago");
  // Plain muted text like the icons: no pill, vertically centred with the copy button.
  const look = await label.evaluate(el => { const c = getComputedStyle(el); return { bg: c.backgroundColor, border: c.borderTopWidth, color: c.color }; });
  expect(look.bg).toBe("rgba(0, 0, 0, 0)");
  expect(look.border).toBe("0px");
  const done = await page.evaluate(() => (window as any).turnTimeHarness.done as number);
  const absolute = await page.evaluate(ms => new Date(ms).toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }), done);
  await first.hover();
  await label.hover();
  const [a, b] = await Promise.all([label.boundingBox(), first.locator(".response-copy").boundingBox()]);
  expect(Math.abs((a!.y + a!.height / 2) - (b!.y + b!.height / 2))).toBeLessThan(1.5);
  await expect.poll(() => label.evaluate(el => getComputedStyle(el).color)).not.toBe(look.color);
  const tip = page.getByRole("tooltip");
  await expect(tip).toContainText(absolute);
  await expect(tip).toContainText("Worked for 12h 6m");
  await page.screenshot({ path: `${shots}/turn-time-${theme}.png`, clip: { x: 0, y: 0, width: 1100, height: 260 } });

  // A streaming answer has no time yet; it appears once the turn completes.
  await page.evaluate(() => (window as any).turnTimeHarness.apply({ type: "text_delta", data: { content: "Writing the docs" } }));
  const live = page.locator(".st-text").nth(1);
  await live.hover();
  await expect(live.locator(".response-copy")).toBeVisible();
  await expect(live.locator(".response-time")).toHaveCount(0);
  await page.evaluate(() => (window as any).turnTimeHarness.apply({ type: "assistant_message", data: { content: "Documented the session store.", at: new Date().toISOString() } }));
  await live.hover();
  await expect(live.locator(".response-time")).toHaveText("just now");
  await live.locator(".response-time").hover();
  await expect(page.getByRole("tooltip")).toContainText(/Worked for 3m( \d+s)?/);
});
