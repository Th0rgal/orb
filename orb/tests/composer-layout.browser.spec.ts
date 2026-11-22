import {test, expect, type Locator} from '@playwright/test';
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

async function textContrast(label: Locator, surfaceSelector: string, pseudo?: string) {
  return label.evaluate((el, {surfaceSelector, pseudo}) => {
    function luminance(rgb: string) {
      const [r, g, b] = rgb.match(/[\d.]+/g)!.map(value => {
        const channel = Number(value) / 255;
        return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
      });
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }
    const text = luminance(getComputedStyle(el, pseudo).color);
    const surface = luminance(getComputedStyle(el.closest(surfaceSelector)!).backgroundColor);
    return (Math.max(text, surface) + 0.05) / (Math.min(text, surface) + 0.05);
  }, {surfaceSelector, pseudo});
}

for (const theme of ['dark', 'light']) {
  test(`composer hint and command menu headings are legible in the ${theme} theme`, async ({page}) => {
    await page.goto('/tests/form-feedback.html?voice');
    const input = page.locator('.composer textarea');
    await expect(input).toBeVisible();
    await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
    expect(await textContrast(input, '.composer', '::placeholder')).toBeGreaterThanOrEqual(4.5);

    await input.press('/');
    const heading = page.getByRole('listbox', {name: 'Commands'}).getByText('Modes', {exact: true});
    await expect(heading).toBeVisible();
    expect(await textContrast(heading, '.slash-menu')).toBeGreaterThanOrEqual(4.5);
  });
}
