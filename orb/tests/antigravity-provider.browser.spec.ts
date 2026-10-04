import { test, expect } from '@playwright/test';
test.use({ browserName: 'webkit' });
test('Providers shows Antigravity CLI and only account-discovered models', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('orb.apiUrl', location.origin);
    localStorage.setItem('orb.jwt', 'test');
  });
  await page.route('**/api/**', route => {
    const url = new URL(route.request().url());
    const body = url.pathname === '/api/providers/antigravity-models'
      ? url.searchParams.has('node_id') ? [['flash', 'Gemini Flash']] : [['agy-demo', 'Gemini 4 Argon']]
      : url.pathname === '/api/remote-nodes' ? { enabled: true, nodes: [{ id: 'old-agent' }] }
      : url.pathname === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  const native = page.getByRole('region', { name: 'Antigravity CLI', exact: true });
  await native.getByRole('button', { name: /Antigravity CLI/ }).click();
  await expect(native.getByText('Gemini 4 Argon')).toBeVisible();
  await page.screenshot({ path: '/tmp/antigravity-providers.png', fullPage: true });
  await native.getByLabel('Antigravity machine').selectOption('old-agent');
  await expect(native.getByText('Gemini Flash')).toBeVisible();
  await expect(native.getByText('Gemini 4 Argon')).toHaveCount(0);
});
