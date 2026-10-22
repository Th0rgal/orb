import {test, expect} from "@playwright/test";

for (const theme of ["dark", "light"]) {
  test(`loose pipe table renders as a table in ${theme} theme`, async ({page}, testInfo) => {
    await page.goto(`/tests/pipe-tables.html?theme=${theme}`);
    await expect(page.locator("table th")).toHaveCount(7);
    await expect(page.locator("tbody tr")).toHaveCount(4);
    const cell = page.locator("tbody tr").first().locator("td").nth(1);
    expect(await cell.evaluate((td) => [getComputedStyle(td).textAlign, getComputedStyle(td).fontVariantNumeric])).toEqual(["right", "tabular-nums"]);
    await page.screenshot({path: testInfo.outputPath(`${theme}-desktop.png`), fullPage: true});
    await page.setViewportSize({width: 390, height: 844});
    // The table scrolls inside its own block; the page never scrolls sideways.
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
    const wrap = page.locator(".md-table-wrap");
    expect(await wrap.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
    await page.screenshot({path: testInfo.outputPath(`${theme}-narrow.png`), fullPage: true});
  });
}
