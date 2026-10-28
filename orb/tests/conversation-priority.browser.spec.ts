import { expect, test } from '@playwright/test';

for (const colorScheme of ['light', 'dark'] as const) {
  test(`final response paints before delayed activity and queue (${colorScheme})`, async ({ page }, info) => {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' });
    const id = 'priority';
    const mission = { id, title: 'Priority conversation', status: 'completed', project: 'test', backend: 'antigravity', history: [], created_at: '', updated_at: '' };
    const answer = { id: 6497, sequence: 6497, event_type: 'assistant_message', content: 'The final response is ready to read.', timestamp: '' };
    let release!: () => void;
    const hydration = new Promise<void>(resolve => release = resolve);
    let activityStarted = false;
    await page.addInitScript(() => {
      localStorage.setItem('orb.apiUrl', location.origin);
      localStorage.setItem('orb.jwt', 'test');
    });
    await page.route('**/api/**', async route => {
      const url = new URL(route.request().url()), path = url.pathname;
      if (path === '/api/control/stream') return route.fulfill({ contentType: 'text/event-stream', body: '' });
      if (path.endsWith('/snapshot')) return route.fulfill({json:{profile:'presentation',events:[answer],revision:6497}});
      if (path.endsWith('/events')) {
        if (!(url.searchParams.get('view') === 'transcript' && url.searchParams.get('limit') === '2')) {
          activityStarted = true;
          await hydration;
        }
        return route.fulfill({ json: [answer], headers: { 'X-Orb-Events-Protocol': '1', 'X-Has-More': 'false', 'X-Next-Cursor': '6497', 'X-Page-Max-Sequence': '6497' } });
      }
      if (path === '/api/control/queue') { await hydration; return route.fulfill({ json: [] }); }
      const json = path === '/api/projects' ? { projects: [{ slug: 'test', title: 'test' }] }
        : path === '/api/control/missions' ? [mission]
        : path === `/api/control/missions/${id}` || path.endsWith('/opened') ? mission
        : path.endsWith('/manifest') ? { revision: 1, entries: {} }
        : path.endsWith('/files') ? { entries: [] } : [];
      return route.fulfill({ json });
    });
    await page.goto('/');
    await page.getByRole('button', { name: 'test', exact: true }).click();
    const start = Date.now();
    await page.getByRole('button', { name: 'Priority conversation', exact: true }).click();
    await expect(page.getByText(answer.content, { exact: true })).toBeVisible();
    const answerVisibleMs = Date.now() - start;
    console.log("PRIORITY_FIRST_PAINT", JSON.stringify({ colorScheme, answerVisibleMs }));
    await expect.poll(() => activityStarted).toBe(true);
    await expect(page.getByRole('status', { name: 'Loading conversation activity' })).toBeVisible();
    await info.attach(`preview-${colorScheme}.png`, { body: await page.screenshot({ path: info.outputPath(`preview-${colorScheme}.png`) }), contentType: 'image/png' });
    release();
    await expect(page.getByRole('status', { name: 'Loading conversation activity' })).toHaveCount(0);
    await expect(page.getByText(answer.content, { exact: true })).toHaveCount(1);
    await info.attach('loading-metrics.json', { body: JSON.stringify({ answerVisibleMs, activityAndQueueWereBlocked: true }), contentType: 'application/json' });
  });
}
