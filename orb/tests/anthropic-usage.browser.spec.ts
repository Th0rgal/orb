import { test, expect } from '@playwright/test';

const accounts = [
  { id: 'ben', email: 'ben@example.com', usage: { unified_status: 'allowed_warning', unified_representative_claim: 'seven_day', unified_5h_utilization: 0.09, unified_7d_utilization: 0.91, organization_id: 'org-ben' } },
  { id: 'thomas', email: 'thomas@example.com', usage: { unified_status: 'allowed', unified_5h_utilization: 0.37, unified_7d_utilization: 0.12, organization_id: 'org-thomas' } },
];

for (const theme of ['dark', 'light']) test(`Anthropic subscriptions show per-account usage: ${theme}`, async ({ page }, info) => {
  await page.addInitScript(theme => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); localStorage.setItem('orb-theme', theme); }, theme);
  const reset = Math.floor(Date.now() / 1000) + 5 * 3600;
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/ai/providers') return route.fulfill({ json: accounts.map(a => ({ id: a.id, name: `Anthropic (${a.email})`, account_email: a.email, provider_type: 'anthropic', enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', status: { type: 'connected' } })) });
    const usage = (a: typeof accounts[number]) => ({ provider_type: 'anthropic', account_email: a.email, status_code: 200, unified_5h_reset: reset, unified_7d_reset: reset + 27 * 3600, ...a.usage });
    if (path === '/api/ai/providers/usage') return route.fulfill({ json: { entries: Object.fromEntries(accounts.map(a => [a.id, usage(a)])) } });
    const a = accounts.find(a => path === `/api/ai/providers/${a.id}/usage`);
    if (a) return route.fulfill({ json: usage(a) });
    return route.fulfill({ json: path === '/api/projects' ? { projects: [] } : [] });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
  for (const email of ['ben@example.com', 'thomas@example.com']) await page.getByRole('button', { name: new RegExp(email.replace('.', '\\.')) }).first().click();
  await expect(page.getByTestId('usage-limit-status')).toHaveText('Approaching limit · weekly 91%');
  await expect(page.getByText(/allowed_warning|status:/)).toHaveCount(0);
  await expect(page.getByText('37%').first()).toBeVisible();
  await page.screenshot({ path: `/tmp/orb-anthropic-usage-${info.project.name}-${theme}.png`, fullPage: true });
});
