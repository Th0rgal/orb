import { expect, test } from '@playwright/test';

for (const colorScheme of ['dark', 'light'] as const) {
  test(`Inference page paints synchronously and never blocks behind background project pagination (${colorScheme})`, async ({ page }) => {
    await page.emulateMedia({ colorScheme, reducedMotion: 'reduce' });
    let releaseProviders!: () => void;
    const holdProviders = new Promise<void>((resolve) => {
      releaseProviders = resolve;
    });
    const stalledBackground: Array<() => void> = [];

    await page.addInitScript(() => {
      localStorage.setItem('orb.apiUrl', location.origin);
      localStorage.setItem('orb.jwt', 'test');
      localStorage.setItem('orb.expandedProjects', JSON.stringify({ 'verity-core': true, default: true }));
    });

    await page.route('**/api/**', async (route) => {
      const url = new URL(route.request().url());
      const path = url.pathname;
      if (path === '/api/control/stream') {
        return route.fulfill({ contentType: 'text/event-stream', body: '' });
      }
      if (path === '/api/projects') {
        return route.fulfill({
          json: {
            projects: [
              { slug: 'verity-core', title: 'Verity Core', status: 'active' },
              { slug: 'default', title: 'Default', status: 'active' },
            ],
          },
        });
      }
      if (path === '/api/control/missions' && url.searchParams.get('project')) {
        const offset = Number(url.searchParams.get('offset') ?? '0');
        if (offset > 0) {
          await new Promise<void>((resolve) => stalledBackground.push(resolve));
          return route.fulfill({ json: [] });
        }
        if (url.searchParams.get('all') === 'true') {
          return route.fulfill({ json: [] });
        }
        return route.fulfill({
          json: Array.from({ length: 200 }, (_, i) => ({
            id: `m-${url.searchParams.get('project')}-${i}`,
            title: `Mission ${i}`,
            status: 'active',
            project: url.searchParams.get('project'),
          })),
        });
      }
      if (path === '/api/ai/providers') {
        await holdProviders;
        return route.fulfill({
          json: [
            {
              id: 'claude-max',
              name: 'Claude Max',
              account_email: 'team@example.com',
              provider_type: 'anthropic',
              uses_oauth: true,
              status: { type: 'connected' },
            },
          ],
        });
      }
      if (path === '/api/ai/providers/usage') {
        return route.fulfill({ json: { entries: {} } });
      }
      if (path === '/api/cloud/accounts') {
        return route.fulfill({
          json: [{ id: 'hermes-1', provider: 'hermes', label: 'Hermes', available: true, experimental: false }],
        });
      }
      return route.fulfill({ json: [] });
    });

    await page.goto('/');
    await expect(page.getByRole('button', { name: 'Verity Core', exact: true })).toBeVisible({ timeout: 25_000 });
    const syncPaint = await page.evaluate(() => {
      const btn = [...document.querySelectorAll('button.row')].find((el) => el.textContent?.includes('Inference')) as HTMLButtonElement | undefined;
      if (!btn) throw new Error('Missing Inference nav button');
      btn.click();
      const heading = document.querySelector('main.main h2')?.textContent ?? null;
      const skeleton = document.querySelector('main.main [role="status"][aria-label="Loading inference accounts"]') !== null;
      return { heading, skeleton };
    });

    expect(syncPaint.heading).toBe('Inference');
    expect(syncPaint.skeleton).toBe(true);

    releaseProviders();
    await expect(page.getByText('Claude Max')).toBeVisible();

    const holdReload = new Promise<void>(() => {});
    await page.route('**/api/ai/providers', async (route) => {
      await holdReload;
      return route.fulfill({ json: [] });
    });
    await page.reload();
    await page.getByRole('button', { name: 'Inference', exact: true }).click();
    await expect(page.getByText('Claude Max')).toBeVisible();
    await expect(page.getByRole('status', { name: 'Loading inference accounts' })).toHaveCount(0);

    while (stalledBackground.length > 0) stalledBackground.shift()?.();
  });
}
