import { test, expect } from '@playwright/test';

const account = (id: string, email: string, priority: number) => ({
  id, name: `Antigravity (${email})`, account_email: email, provider_type: 'antigravity', provider_type_name: 'Google Antigravity',
  enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', priority, status: { type: 'connected' },
});

for (const theme of ['dark', 'light']) test(`Antigravity account order is editable: ${theme}`, async ({ page }, info) => {
  await page.addInitScript(theme => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); localStorage.setItem('orb-theme', theme); }, theme);
  let accounts = [account('first', 'first@example.com', 0), account('second', 'second@example.com', 1)];
  const reorders: string[][] = [];
  let failNext = false;
  await page.route('**/api/**', async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/ai/providers/reorder') {
      const { ids } = route.request().postDataJSON() as { ids: string[] };
      reorders.push(ids);
      if (failNext) return route.fulfill({ status: 500, body: 'boom' });
      accounts = accounts.map(a => ({ ...a, priority: ids.indexOf(a.id) }));
      return route.fulfill({ json: accounts });
    }
    if (path === '/api/ai/providers') return route.fulfill({ json: accounts });
    if (path === '/api/ai/providers/usage') return route.fulfill({ json: { entries: {} } });
    return route.fulfill({ json: path === '/api/projects' ? { projects: [] } : [] });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  const emails = () => page.locator('.p-acc-wrap .p-account-email .sr-only').allTextContents();
  await expect.poll(emails).toEqual(['first@example.com', 'second@example.com']);
  await expect(page.locator('.p-rank')).toHaveText(['1st', '2nd']);
  await expect(page.getByRole('button', { name: 'Try first@example.com earlier' })).toBeDisabled();

  await page.getByRole('button', { name: 'Try second@example.com earlier' }).click();
  await expect.poll(emails).toEqual(['second@example.com', 'first@example.com']);
  expect(reorders).toEqual([['second', 'first']]);
  await page.screenshot({ path: `/tmp/orb-account-order-${info.project.name}-${theme}.png`, fullPage: true });

  // A refused reorder rolls back visibly.
  failNext = true;
  await page.getByRole('button', { name: 'Try first@example.com earlier' }).click();
  await expect(page.getByText(/Could not change the order of Google Antigravity accounts/)).toBeVisible();
  await expect.poll(emails).toEqual(['second@example.com', 'first@example.com']);
});
