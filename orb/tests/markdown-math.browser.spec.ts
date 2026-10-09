import {test, expect} from "@playwright/test";

for (const theme of ["dark", "light"]) {
  test(`numeric math in nested lists renders in ${theme} theme`, async ({page}, testInfo) => {
    await page.goto(`/tests/markdown-math.html?theme=${theme}`);
    await expect(page.locator(".katex")).toHaveCount(4);
    await expect(page.locator(".katex-display")).toHaveCount(1);
    await expect(page.locator("strong .katex")).toHaveCount(1);
    await expect(page.locator(".katex-error")).toHaveCount(0);
    await expect(page.locator("code")).toHaveText("word_math.rs");
    await page.screenshot({path: testInfo.outputPath(`${theme}-desktop.png`)});
    await page.setViewportSize({width: 390, height: 844});
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
    await expect(page.locator(".md-math-block")).toBeVisible();
    await page.screenshot({path: testInfo.outputPath(`${theme}-narrow.png`)});
  });
}
