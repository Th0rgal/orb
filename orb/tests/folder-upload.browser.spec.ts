import { expect, test, type Page } from '@playwright/test';

/** Shared-context upload API with a controllable failure for one file. */
async function mockContext(page: Page, o: { failOnce?: string; delayMs?: number } = {}) {
  const operations: string[] = [];
  let failed = false, active = 0, peak = 0;
  await page.addInitScript(() => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); });
  await page.route('**/api/**', async route => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (path.endsWith('/context/blobs')) {
      active++; peak = Math.max(peak, active);
      await new Promise(r => setTimeout(r, o.delayMs ?? 30));
      active--;
      return route.fulfill({ json: { hash: 'h' } });
    }
    if (path.endsWith('/context/operations')) {
      const op = request.postDataJSON();
      if (o.failOnce && op.path.endsWith(o.failOnce) && !failed) { failed = true; return route.fulfill({ status: 503, body: 'busy' }); }
      operations.push(op.path);
      return route.fulfill({ json: { conflict: false } });
    }
    return route.fulfill({ json: [] });
  });
  return { operations, peak: () => peak };
}

/** A synthetic drop whose DataTransfer exposes folder entries, as Chromium/WebKit do for Finder drops. */
async function dropTree(page: Page, tree: unknown) {
  await page.locator('.composer').evaluate((composer, tree) => {
    const toEntry = (node: any): any => node.children
      ? { isFile: false, isDirectory: true, name: node.name, createReader: () => { let done = false; return { readEntries: (ok: any) => { ok(done ? [] : node.children.map(toEntry)); done = true; } }; } }
      : { isFile: true, isDirectory: false, name: node.name, file: (ok: any) => ok(new File(['x'.repeat(node.size ?? 10)], node.name)) };
    const roots = (tree as any[]).map(toEntry);
    const event = new Event('drop', { bubbles: true, cancelable: true });
    const files = (tree as any[]).filter(node => !node.children).map(node => new File(['x'.repeat(node.size ?? 10)], node.name));
    Object.defineProperty(event, 'dataTransfer', { value: { types: ['Files'], files, items: roots.map(entry => ({ webkitGetAsEntry: () => entry })) } });
    composer.dispatchEvent(event);
  }, tree);
}

test('a dropped folder uploads in parallel, keeps its tree and becomes one mention', async ({ page }) => {
  const api = await mockContext(page, { failOnce: 'sub/c.pdf' });
  await page.goto('/tests/folder-upload.html');
  const files = Array.from({ length: 9 }, (_, i) => ({ name: `aula ${i + 1}.pdf`, size: 2048 }));
  await dropTree(page, [{ name: 'Aulas PPL (ã)', children: [...files, { name: '.DS_Store' }, { name: 'node_modules', children: [{ name: 'x.js' }] }, { name: 'sub', children: [{ name: 'c.pdf' }] }] }]);
  const chip = page.getByRole('group', { name: 'Folder Aulas PPL (ã)' });
  await expect(chip).toBeVisible();
  // The flaky file is retried automatically; the folder then lands as a single mention.
  const input = page.getByPlaceholder('Reply');
  await expect(input).toHaveValue(/^@"attachments\/[0-9a-f-]{36}\/Aulas PPL \(ã\)\/" $/);
  expect(api.operations).toHaveLength(10);
  expect(api.operations.every(path => /^attachments\/[0-9a-f-]{36}\/Aulas PPL \(ã\)\//.test(path))).toBe(true);
  expect(api.operations.some(path => path.endsWith('/sub/c.pdf'))).toBe(true);
  expect(api.operations.some(path => /DS_Store|node_modules/.test(path))).toBe(false);
  expect(api.peak()).toBeLessThanOrEqual(4);
  const done = page.getByRole('group', { name: 'Folder Aulas PPL (ã)' });
  await expect(done).toContainText('10 files');
  await done.getByRole('button', { name: /Show files in/ }).click();
  await expect(done).toContainText('Aulas PPL (ã)/sub/c.pdf');
  await page.screenshot({ path: 'test-results/folder-upload.png' });
  await input.press('Enter');
  await expect.poll(() => page.evaluate(() => (window as any).sent)).toEqual([expect.stringMatching(/^@"attachments\/.+\/Aulas PPL \(ã\)\/"$/)]);
});

test('several dropped files upload together and are mentioned in order', async ({ page }) => {
  const api = await mockContext(page, { delayMs: 60 });
  await page.goto('/tests/folder-upload.html');
  await dropTree(page, [{ name: 'b (1).pdf' }, { name: 'ação.txt' }, { name: 'c.md' }]);
  const input = page.getByPlaceholder('Reply');
  await expect(input).toHaveValue(/^@"attachments\/[^"]+\/b \(1\)\.pdf" @attachments\/[^ ]+\/ação\.txt @attachments\/[^ ]+\/c\.md $/);
  expect(api.operations).toHaveLength(3);
  expect(api.peak()).toBeGreaterThan(1);
});

test('a restored draft whose file is gone sends its text and asks to re-attach only that file', async ({ page }) => {
  await mockContext(page);
  await page.goto('/tests/folder-upload.html?restored');
  const input = page.getByPlaceholder('Reply');
  await expect(input).toHaveValue(/Questões_PPLA_air_Law_key \(1\)\.pdf/);
  await input.press('Enter');
  await expect(page.getByText(/File no longer available — re-attach: Questões_PPLA_air_Law_key \(1\)\.pdf/)).toBeVisible();
  await expect(page.getByRole('alert')).toHaveCount(0);
  await expect(input).toHaveValue('Explique por favor');
  await page.screenshot({ path: 'test-results/upload-recovery.png' });
  await input.press('Enter');
  await expect.poll(() => page.evaluate(() => (window as any).sent)).toEqual(['Explique por favor']);
});
