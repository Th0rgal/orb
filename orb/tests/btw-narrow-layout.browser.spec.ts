import { expect, test, type Page } from "@playwright/test";
import { longConversation, openConversation } from "./btwSideFixture";

// The side question in a window too narrow for two columns. It used to float over the right
// part of the transcript, so both texts were on screen at once with the panel's controls
// directly under the conversation header's. It must take the whole content area on an opaque
// surface, below the title bar.

type Box = { x: number; y: number; width: number; height: number };
const box = async (page: Page, selector: string): Promise<Box> => (await page.locator(selector).boundingBox())!;
const alpha = (page: Page, selector: string) =>
  page.locator(selector).evaluate((el) => {
    const match = getComputedStyle(el).backgroundColor.match(/rgba?\(([^)]+)\)|color\(srgb ([^)]+)\)/);
    const parts = (match?.[1] ?? match?.[2] ?? "").split(/[\s,/]+/).filter(Boolean);
    return parts.length > 3 ? Number(parts[3]) : 1;
  });

async function openSideQuestion(page: Page) {
  await expect(page.getByText("Verified stage 10.")).toBeVisible({ timeout: 20_000 });
  await page.getByRole("button", { name: "Side question", exact: true }).click();
  await expect(page.getByPlaceholder(/Ask a side question/)).toBeVisible();
}

for (const theme of ["dark", "light"] as const) {
  for (const width of [1000, 700, 390]) {
    test(`side question takes the whole content area at ${width}px: ${theme}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 800 });
      await openConversation(page, theme, longConversation);
      await openSideQuestion(page);

      const panel = await box(page, ".btw-sidebar");
      const main = await box(page, ".main");
      const titlebar = await box(page, ".titlebar");
      // Same box as the conversation: no strip of transcript left beside the panel.
      expect(Math.abs(panel.x - main.x)).toBeLessThanOrEqual(1);
      expect(Math.abs(panel.width - main.width)).toBeLessThanOrEqual(1);
      expect(Math.abs(panel.y - main.y)).toBeLessThanOrEqual(1);
      expect(Math.abs(panel.height - main.height)).toBeLessThanOrEqual(1);
      expect(panel.x + panel.width).toBeLessThanOrEqual(width + 1);
      // Opaque, and every point of the conversation area belongs to the panel.
      expect(await alpha(page, ".btw-sidebar")).toBe(1);
      const covered = await page.evaluate(({ x, y, w, h }) => {
        const points = [[0.02, 0.1], [0.5, 0.5], [0.98, 0.1], [0.02, 0.9], [0.98, 0.9], [0.25, 0.3], [0.1, 0.6]];
        return points
          .map(([fx, fy]) => document.elementFromPoint(x + w * fx, y + h * fy))
          .filter((el) => !el?.closest(".btw-sidebar"))
          .map((el) => (el ? `${el.tagName.toLowerCase()}.${el.className}` : "nothing"));
      }, { x: main.x, y: main.y, w: main.width, h: main.height });
      expect(covered).toEqual([]);
      // The panel's own controls sit below the title bar, never over the conversation header.
      const close = page.locator(".btw-sidebar .btw-actions").getByRole("button").last();
      await expect(close).toBeVisible();
      const closeBox = (await close.boundingBox())!;
      expect(closeBox.y).toBeGreaterThanOrEqual(titlebar.y + titlebar.height);
      await expect(page.locator(".titlebar .tb-title")).toBeVisible();

      // Closing gives the conversation back.
      await close.click();
      await expect(page.locator(".btw-sidebar")).toBeHidden();
      await expect(page.getByText("Verified stage 10.")).toBeVisible();
    });
  }

  test(`side question sits beside the conversation in a wide window: ${theme}`, async ({ page }) => {
    await page.setViewportSize({ width: 1400, height: 800 });
    await openConversation(page, theme, longConversation);
    await openSideQuestion(page);
    const panel = await box(page, ".btw-sidebar");
    const main = await box(page, ".main");
    expect(main.x + main.width).toBeLessThanOrEqual(panel.x + 1);
    await expect(page.getByText("Verified stage 10.")).toBeVisible();
  });
}
