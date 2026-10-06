import { test, expect } from '@playwright/test';
test.use({ browserName: 'webkit' });
test('Providers nests native execution inside the Antigravity subscription', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('orb.apiUrl', location.origin);
    localStorage.setItem('orb.jwt', 'test');
  });
  await page.route('**/api/**', route => {
    const url = new URL(route.request().url());
    const body = url.pathname === '/api/providers/antigravity-models'
      ? url.searchParams.has('node_id') ? [['flash', 'Gemini Flash']] : [['agy-demo', 'Gemini 4 Argon']]
      : url.pathname === '/api/ai/providers' ? [{id:'antigravity',name:'Antigravity subscription',provider_type:'antigravity',uses_oauth:true,credential_owner:'cli_proxy',status:{type:'connected'}}]
      : url.pathname === '/api/remote-nodes' ? { enabled: true, nodes: [{ id: 'old-agent' }] }
      : url.pathname === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Add subscription account', exact: true })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Antigravity CLI', exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: /Antigravity subscription Connected/ }).click();
  const native = page.getByRole('region', { name: 'Antigravity CLI', exact: true });
  await native.getByRole('button', { name: /Execution machines/ }).click();
  await expect(native.getByText('Gemini 4 Argon')).toBeVisible();
  await page.screenshot({ path: '/tmp/antigravity-provider.png', fullPage: true });
  await native.getByLabel('Antigravity machine').selectOption('old-agent');
  await expect(native.getByText('Gemini Flash')).toBeVisible();
  await expect(native.getByText('Gemini 4 Argon')).toHaveCount(0);
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('region', { name: 'Antigravity CLI', exact: true })).toHaveCount(0);
});
