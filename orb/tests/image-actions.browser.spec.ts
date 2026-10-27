import {test, expect, type Page} from '@playwright/test';
test.use({browserName: 'webkit'});

// Stand-in for the Tauri bridge: records native calls and answers the Save dialog.
const mockNative = (page: Page) => page.addInitScript(() => {
  (window as any).calls = [];
  (window as any).__TAURI_INTERNALS__ = {invoke: async (command: string, args: unknown) => {(window as any).calls.push({command, args}); return command === 'save_file_as' ? '/Users/me/Downloads/bench chart.png' : null;}};
  (window as any).clipboardItems = [];
  Object.defineProperty(navigator, 'clipboard', {value: {
    writeText: async (text: string) => {(window as any).copied = text;},
    write: async (items: ClipboardItem[]) => {for (const item of items) (window as any).clipboardItems.push({types: item.types, size: (await item.getType('image/png')).size});},
  }});
});

test('Download in the image viewer saves the original name and bytes through the native dialog', async ({page}) => {
  await mockNative(page);
  await page.goto('/tests/image-actions.html');
  await page.getByRole('button', {name: /Benchmark chart/}).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByRole('heading')).toHaveText('Benchmark chart');
  await dialog.getByRole('button', {name: 'Download image'}).click();
  await expect(page.getByRole('status')).toHaveText('Image saved');
  const [call] = await page.evaluate(() => (window as any).calls);
  expect(call.command).toBe('save_file_as');
  expect(call.args.name).toBe('bench chart.png');
  expect(call.args.dataBase64).toBe(await page.evaluate(() => (window as any).PNG));
});

test('right-clicking an image offers save, copy image and copy path instead of the webview menu', async ({page}) => {
  await mockNative(page);
  await page.goto('/tests/image-actions.html');
  const image = page.getByRole('button', {name: /Benchmark chart/});
  // Transcript image: hover download and its own menu.
  await image.hover();
  await expect(page.getByRole('button', {name: 'Download image'})).toBeVisible();
  const prevented = await image.evaluate(el => !el.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true, clientX: 60, clientY: 60})));
  expect(prevented).toBe(true);
  const menu = page.getByRole('menu');
  await expect(menu.getByRole('menuitem')).toHaveText(['Save image as…', 'Copy image', 'Copy path']);
  await menu.getByRole('menuitem', {name: 'Copy path'}).click();
  expect(await page.evaluate(() => (window as any).copied)).toBe('reports/bench chart.png');
  // Full-screen viewer: same menu on the zoomable image.
  await image.click();
  await page.locator('.image-viewport').click({button: 'right'});
  await page.getByRole('menuitem', {name: 'Copy image'}).click();
  await expect(page.getByRole('status')).toHaveText('Image copied');
  expect(await page.evaluate(() => (window as any).clipboardItems)).toEqual([{types: ['image/png'], size: 73}]);
  await page.locator('.image-viewport').click({button: 'right'});
  await page.getByRole('menuitem', {name: 'Save image as…'}).click();
  await expect.poll(() => page.evaluate(() => (window as any).calls.map((c: any) => c.args.name))).toEqual(['bench chart.png']);
});
