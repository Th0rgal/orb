import { test, expect } from '@playwright/test';

for (const theme of ['dark', 'light']) {
  test(`subscription reset confirmation and auto-reset toggle: ${theme}`, async ({ page }) => {
    await page.addInitScript(t => {
      localStorage.setItem('orb.apiUrl', location.origin);
      localStorage.setItem('orb.jwt', 'test');
      localStorage.setItem('orb-theme', t);
    }, theme);

    let autoReset = false;
    let redeemed = false;
    const resetCalls: Array<Record<string, unknown>> = [];
    const putCalls: Array<Record<string, unknown>> = [];

    await page.route('**/api/**', async route => {
      const req = route.request();
      const path = new URL(req.url()).pathname;
      const method = req.method();
      const provider = {
        id: 'claude-1',
        name: 'Anthropic (alice@example.com)',
        account_email: 'alice@example.com',
        provider_type: 'anthropic',
        enabled: true,
        uses_oauth: true,
        has_oauth: true,
        auto_reset_on_limit: autoReset,
        credential_owner: 'cli_proxy',
        status: { type: 'connected' },
      };
      const currentUsage = () => redeemed
        ? {
            provider_type: 'anthropic',
            account_email: 'alice@example.com',
            unified_status: 'allowed',
            unified_5h_utilization: 0,
            unified_7d_utilization: 0,
            reset_redeemed: true,
            subscription_resets: { available_count: 0, usable_now: false, grants: [] },
          }
        : {
            provider_type: 'anthropic',
            account_email: 'alice@example.com',
            unified_status: 'rejected',
            unified_representative_claim: 'seven_day',
            unified_5h_utilization: 0.25,
            unified_7d_utilization: 1,
            subscription_resets: {
              available_count: 1,
              usable_now: true,
              grants: [{
                id: 'grant-1',
                label: 'Promotional reset',
                clears: ['5h', 'Weekly'],
                resets_left: 1,
                usable_now: true,
                requires_limit: true,
              }],
            },
          };

      if (path === '/api/ai/providers' && method === 'GET') {
        return route.fulfill({ json: [provider] });
      }
      if (path === '/api/ai/providers/claude-1' && method === 'PUT') {
        const body = req.postDataJSON() as Record<string, unknown>;
        putCalls.push(body);
        autoReset = Boolean(body.auto_reset_on_limit);
        return route.fulfill({ json: { ...provider, auto_reset_on_limit: autoReset } });
      }
      if (path === '/api/ai/providers/claude-1/reset-usage' && method === 'POST') {
        resetCalls.push(req.postDataJSON() as Record<string, unknown>);
        redeemed = true;
        return route.fulfill({ json: currentUsage() });
      }
      if (path === '/api/ai/providers/usage') {
        return route.fulfill({ json: { entries: { 'claude-1': currentUsage() } } });
      }
      if (path === '/api/ai/providers/claude-1/usage') {
        return route.fulfill({ json: currentUsage() });
      }
      return route.fulfill({ json: path === '/api/projects' ? { projects: [] } : [] });
    });

    await page.goto('/');
    await page.getByRole('button', { name: 'Inference', exact: true }).click();
    await expect(page.getByTestId('subscription-reset-hint')).toHaveText('·1 reset available');

    await page.getByRole('button', { name: /alice@example\.com/ }).first().click();
    const region = page.getByRole('region', { name: 'Subscription reset', exact: true });
    await expect(region).toContainText('1 reset available');
    await expect(region).toContainText('Clears 5h and Weekly');

    const autoSwitch = region.getByRole('switch', { name: /Auto-use reset on limit/ });
    await expect(autoSwitch).toHaveAttribute('aria-checked', 'false');
    await autoSwitch.click();
    await expect(autoSwitch).toHaveAttribute('aria-checked', 'true');
    expect(putCalls).toEqual([{ auto_reset_on_limit: true }]);

    await region.getByRole('button', { name: 'Use reset…' }).click();
    const dialog = page.getByRole('dialog', { name: 'Use subscription reset' });
    await expect(dialog).toBeVisible();
    await dialog.getByRole('button', { name: 'Use reset' }).click();

    await expect(dialog).toBeHidden();
    expect(resetCalls).toHaveLength(1);
    expect(typeof resetCalls[0].idempotency_key).toBe('string');
    await expect(page.getByTestId('subscription-reset-hint')).toHaveCount(0);
  });
}
