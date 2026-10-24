import { test, expect, type Page } from '@playwright/test';

// One quota language across the Providers page: < 80% neutral, 80-99% warning,
// 100% (as displayed) exhausted. Two Antigravity accounts reproduce the bug
// where a 99.96%-used Gemini pool showed "100%" in grey next to a red chip.
const report = process.env.ORB_REPORT_DIR;
const agy = (id: string, email: string) => ({ id, name: `Antigravity (${email})`, account_email: email, provider_type: 'antigravity', enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', status: { type: 'connected' } });
const providers = [
  agy('her3sy', 'thomas.her3sy@gmail.com'),
  agy('m44', 'thomas.marchand.44@gmail.com'),
  { id: 'codex', name: 'ChatGPT (thomas@example.com)', account_email: 'thomas@example.com', provider_type: 'openai', enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', status: { type: 'connected' } },
];
const usage: Record<string, object> = {
  her3sy: { provider_type: 'antigravity', antigravity_plan: 'Google AI Ultra', antigravity_windows: [
    { label: 'Claude & GPT · 5h', used_percent: 100 }, { label: 'Claude & GPT · Weekly', used_percent: 41 },
    { label: 'Gemini · 5h', used_percent: 99.6 }, { label: 'Gemini · Weekly', used_percent: 52 },
  ] },
  m44: { provider_type: 'antigravity', antigravity_plan: 'Google AI Ultra', antigravity_windows: [
    { label: 'Claude & GPT · 5h', used_percent: 85 }, { label: 'Gemini · 5h', used_percent: 100 },
  ] },
  codex: { provider_type: 'openai', codex_plan_type: 'pro', codex_primary_used_percent: 42, codex_primary_window_minutes: 300, codex_secondary_used_percent: 79, codex_secondary_window_minutes: 10080 },
};

async function open(page: Page, theme: string, width: number) {
  await page.addInitScript(theme => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); localStorage.setItem('orb-theme', theme); }, theme);
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    const one = path.match(/^\/api\/ai\/providers\/([^/]+)\/usage$/)?.[1];
    const body = path === '/api/ai/providers' ? providers
      : path === '/api/ai/providers/usage' ? { entries: usage }
      : one ? usage[one] ?? {}
      : path === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  await page.setViewportSize({ width, height: 900 });
  const toggle = page.getByRole('button', { name: 'Toggle sidebar' });
  if (width < 700 && await toggle.getAttribute('aria-expanded') === 'true') await toggle.click();
  // Antigravity rows open expanded; collapse them to see the summary chips.
  for (const email of ['thomas.her3sy@gmail.com', 'thomas.marchand.44@gmail.com']) {
    const row = page.locator('.p-acc-btn', { hasText: email });
    await expect(row).toBeVisible();
    if (await row.getAttribute('aria-expanded') === 'true') await row.click();
  }
}

const card = (page: Page) => page.locator('.s-card', { has: page.locator('.p-account-email', { hasText: 'thomas.her3sy@gmail.com' }) });

for (const theme of ['light', 'dark']) for (const [size, width] of [['wide', 1100], ['phone', 390]] as const)
test(`quota levels color chips and status: ${theme} ${size}`, async ({ page }, info) => {
  await open(page, theme, width);
  const shot = (name: string) => report ? `${report}/${name}` : info.outputPath(name);
  await card(page).screenshot({ path: shot(`quota-levels-${theme}-${size}.png`) });

  const her3sy = page.locator('.p-account-header', { hasText: 'thomas.her3sy@gmail.com' });
  const m44 = page.locator('.p-account-header', { hasText: 'thomas.marchand.44@gmail.com' });
  const codex = page.locator('.p-account-header', { hasText: 'thomas@example.com' });
  await expect(her3sy.locator('.p-st')).toHaveText('Claude & GPT and Gemini quota exhausted');
  await expect(her3sy.locator('.p-st')).toHaveClass(/\bexhausted\b/);
  await expect(m44.locator('.p-st')).toHaveText('Gemini quota exhausted');
  await expect(codex.locator('.p-st')).toHaveText('Connected');
  if (size === 'wide') {
    await expect(her3sy.locator('.p-usage-chip.exhausted')).toHaveCount(2);
    await expect(m44.locator('.p-usage-chip.exhausted')).toHaveText(['Gemini100%']);
    await expect(m44.locator('.p-usage-chip.warning')).toHaveText(['Claude & GPT85%']);
    await expect(codex.locator('.p-usage-chip.warning, .p-usage-chip.exhausted')).toHaveCount(0);
    // Chips line up in columns across rows.
    const lefts = await page.locator('.p-usage.compact').evaluateAll(els => els.map(e => Math.round(e.getBoundingClientRect().left)));
    expect(new Set(lefts).size).toBe(1);
  }
  // Exhausted and warning chips/status resolve to distinct colors from neutral.
  const colors = await page.evaluate(() => {
    const c = (sel: string) => { const e = document.querySelector(sel); return e ? getComputedStyle(e).color : null; };
    return { danger: c('.p-st.exhausted'), neutral: c('.p-usage-chip:not(.warning):not(.exhausted) .p-usage-pct') };
  });
  expect(colors.danger).not.toBe(colors.neutral);
  // Status stays on one line; the full email fits on wide screens.
  for (const row of [her3sy, m44, codex]) {
    const lines = await row.locator('.s-row-desc').evaluate(e => Math.round(e.getBoundingClientRect().height / parseFloat(getComputedStyle(e).lineHeight)));
    expect(lines).toBe(1);
  }
  // Emails truncate in the middle: the domain always stays readable.
  for (const row of [her3sy, m44, codex]) {
    const domain = await row.locator('.p-email-domain').evaluate(e => e.scrollWidth <= e.clientWidth + 1 && e.getBoundingClientRect().width > 0);
    expect(domain).toBe(true);
  }
  if (size === 'wide') expect(await codex.locator('.p-email-local').evaluate(e => e.scrollWidth > e.clientWidth)).toBe(false);

  // Expanded card: bars follow the same levels.
  await page.locator('.p-acc-btn', { hasText: 'thomas.marchand.44@gmail.com' }).click();
  const body = page.locator('.p-acc-wrap', { hasText: 'thomas.marchand.44@gmail.com' });
  await expect(body.locator('.p-bar-fill.exhausted')).toHaveCount(1);
  await expect(body.locator('.p-bar-fill.warning')).toHaveCount(1);
  await body.screenshot({ path: shot(`quota-levels-expanded-${theme}-${size}.png`) });
});
