import { test, expect } from '@playwright/test';

// Antigravity reports separate Gemini and Claude & GPT pools. When only the
// Gemini pool is spent, the collapsed row must say so, highlight that chip
// alone, and never clip a percentage (the email gives way instead).
const report = process.env.ORB_REPORT_DIR;
const provider = { id: 'agy', name: 'Antigravity subscription', account_email: 'thomas.marchand.long-address@example.com', provider_type: 'antigravity', enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', status: { type: 'connected' } };
const usage = { provider_type: 'antigravity', antigravity_plan: 'Google AI Ultra', antigravity_windows: [
  { label: 'Gemini · 5h', used_percent: 100 }, { label: 'Gemini · Weekly', used_percent: 62 },
  { label: 'Claude & GPT · 5h', used_percent: 0 }, { label: 'Claude & GPT · Weekly', used_percent: 0 },
] };

for (const theme of ['light', 'dark']) for (const [size, width] of [['normal', 1100], ['narrow', 480]] as const)
test(`Antigravity quota chips never clip: ${theme} ${size}`, async ({ page }, info) => {
  await page.addInitScript(theme => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); localStorage.setItem('orb-theme', theme); }, theme);
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    const body = path === '/api/ai/providers' ? [provider]
      : path === '/api/ai/providers/usage' ? { entries: { agy: usage } }
      : path === '/api/ai/providers/agy/usage' ? usage
      : path === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  const row = page.getByRole('button', { name: /Google Antigravity/ });
  await expect(row).toContainText('Gemini quota exhausted');
  await expect(row).not.toContainText(/^Quota exhausted/);
  await row.click();
  await page.setViewportSize({ width, height: 700 });
  const toggle = page.getByRole('button', { name: 'Toggle sidebar' });
  if (size === 'narrow' && await toggle.getAttribute('aria-expanded') === 'true') await toggle.click();
  const chips = row.locator('.p-usage.compact');
  await expect(chips).toBeVisible();
  const header = page.locator('.p-account-header', { has: row });
  // Narrow rows move the chips under the status line instead of hiding them.
  await expect(chips.locator('.p-usage-chip:visible')).toHaveText(['Gemini100%', 'Claude & GPT0%']);
  await expect(chips.locator('.p-usage-chip.exhausted')).toHaveText('Gemini100%');
  // Nothing in the chip area is clipped or overlaps the chevron.
  const geometry = await header.evaluate(h => {
    const area = h.querySelector('.p-usage.compact')!.getBoundingClientRect();
    const chev = h.querySelector('.p-acc-chev')!.getBoundingClientRect();
    const clipped = [...h.querySelectorAll<HTMLElement>('.p-usage.compact *')].filter(e => e.offsetParent && e.scrollWidth > e.clientWidth + 1).length;
    const email = h.querySelector<HTMLElement>('.p-email-local')!;
    return { gap: chev.left - area.right, clipped, emailEllipsis: email.scrollWidth > email.clientWidth };
  });
  expect(geometry.clipped).toBe(0);
  expect(geometry.gap).toBeGreaterThanOrEqual(0);
  if (size === 'narrow') expect(geometry.emailEllipsis).toBe(true);
  await header.screenshot({ path: report ? `${report}/antigravity-${theme}-${size}.png` : info.outputPath(`antigravity-${theme}-${size}.png`) });
  if (report) await page.screenshot({ path: `${report}/antigravity-${theme}-${size}-page.png` });
});
