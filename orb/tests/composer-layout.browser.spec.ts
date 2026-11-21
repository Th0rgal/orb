import {test, expect} from '@playwright/test';
test('composer expands for a soft wrap and shrinks back to one row', async ({page}, testInfo) => {
 await page.goto('/tests/form-feedback.html?voice');
 const input=page.locator('.composer textarea');
 const plus=page.locator('.composer .plus');
 await expect(page.locator('.voice-slot')).toBeVisible();
 const field=await input.boundingBox();
 const button=await plus.boundingBox();
 expect(Math.abs(field!.y+field!.height/2-button!.y-button!.height/2)).toBeLessThan(4);
 await input.fill('A short reply with enough words to wrap softly over two lines without an explicit newline.');
 await expect(page.locator('.composer')).toHaveClass(/tall/);
 await input.fill('A longer reply that needs two lines even after the input expands to its full width. '.repeat(2));
 expect(await input.evaluate(el => el.scrollHeight - el.clientHeight)).toBeLessThanOrEqual(1);
 await page.screenshot({path:testInfo.outputPath('two-lines.png')});
 await input.fill('Short');
 expect((await input.boundingBox())!.height).toBeLessThanOrEqual(24);
 await input.fill('');
 expect((await input.boundingBox())!.height).toBeLessThanOrEqual(24);
 await page.screenshot({path:testInfo.outputPath('empty.png')});
});

for (const theme of ['dark', 'light']) {
  test(`empty composer hint is legible in the ${theme} theme`, async ({page}) => {
    await page.goto('/tests/form-feedback.html?voice');
    const input = page.locator('.composer textarea');
    await expect(input).toBeVisible();
    const contrast = await input.evaluate((field, theme) => {
      document.documentElement.dataset.theme = theme;
      function luminance(rgb: string) {
        const [r, g, b] = rgb.match(/[\d.]+/g)!.map(value => {
          const channel = Number(value) / 255;
          return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
        });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
      }
      const hint = luminance(getComputedStyle(field, '::placeholder').color);
      const surface = luminance(getComputedStyle(field.closest('.composer')!).backgroundColor);
      return (Math.max(hint, surface) + 0.05) / (Math.min(hint, surface) + 0.05);
    }, theme);
    expect(contrast).toBeGreaterThanOrEqual(4.5);
  });
}
