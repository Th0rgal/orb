import { test, expect, type Page } from '@playwright/test';

// Inference page: several accounts of one provider collapse under one
// expandable header (model: src/providerGroups.ts).
const report = process.env.ORB_REPORT_DIR;
const agy = (id: string, priority: number, status = 'connected') => ({
  id, name: `Antigravity (${id}@example.com)`, account_email: `${id}@example.com`, provider_type: 'antigravity', provider_type_name: 'Google Antigravity',
  enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', priority, status: { type: status },
});
const codex = { id: 'codex', name: 'ChatGPT (solo@example.com)', account_email: 'solo@example.com', provider_type: 'openai', provider_type_name: 'OpenAI', enabled: true, uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', status: { type: 'connected' } };
const pools = (claude: number, gemini: number) => ({ provider_type: 'antigravity', antigravity_plan: 'Google AI Ultra', antigravity_windows: [
  { label: 'Claude & GPT · 5h', used_percent: claude }, { label: 'Gemini · 5h', used_percent: gemini },
] });

type Fixture = { providers: object[]; usage: Record<string, object> };
const four = (): Fixture => ({
  providers: [agy('one', 0), agy('two', 1), codex, agy('three', 2), agy('four', 3)],
  usage: {
    one: pools(100, 0), two: pools(99, 12), three: pools(85, 100), four: pools(20, 30),
    codex: { provider_type: 'openai', codex_plan_type: 'pro', codex_primary_used_percent: 42, codex_primary_window_minutes: 300 },
  },
});

async function open(page: Page, fixture: Fixture, theme = 'dark') {
  await page.addInitScript(theme => {
    localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); localStorage.setItem('orb-theme', theme);
  }, theme);
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    const one = path.match(/^\/api\/ai\/providers\/([^/]+)\/usage$/)?.[1];
    const body = path === '/api/ai/providers' ? fixture.providers
      : path === '/api/ai/providers/usage' ? { entries: fixture.usage }
      : one ? fixture.usage[one] ?? {}
      : path === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Inference', exact: true }).click();
}

const head = (page: Page) => page.locator('.p-group-head');
const rows = (page: Page) => page.locator('.p-group-body .p-acc-wrap');
const subscriptions = (page: Page) => page.locator('.s-sec', { has: page.getByRole('heading', { name: 'Subscriptions' }) }).locator('.s-card');

for (const theme of ['dark', 'light']) test(`four Antigravity accounts collapse into one expandable group: ${theme}`, async ({ page }, info) => {
  const fixture = four();
  await open(page, fixture, theme);
  const shot = (name: string) => subscriptions(page).screenshot({ path: report ? `${report}/${name}-${theme}.png` : info.outputPath(`${name}-${theme}.png`) });

  // Collapsed by default: one honest header instead of four rows.
  await expect(head(page)).toHaveCount(1);
  await expect(head(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(head(page).locator('.p-account-name')).toHaveText('Google Antigravity');
  await expect(head(page).locator('.s-row-desc')).toHaveText('4 accounts·2 limit reached·1 near limit');
  await expect(head(page).locator('.p-usage-chip')).toHaveText(['Claude & GPT3 of 4 left', 'Gemini3 of 4 left']);
  await expect(head(page).locator('.p-usage-chip').first()).toHaveAttribute('title', 'Claude & GPT: 3 of 4 accounts have quota left · least used 20%');
  await expect(rows(page)).toHaveCount(0);

  // A provider with one account is the plain row it always was, outside any group.
  const solo = page.locator('.p-acc-wrap', { hasText: 'solo@example.com' });
  await expect(solo).toBeVisible();
  await expect(page.locator('.p-group', { hasText: 'solo@example.com' })).toHaveCount(0);
  await expect(solo.locator('.p-rank')).toHaveCount(0);
  await expect(solo.locator('.p-usage-chip')).toHaveText(['5h42%']);
  // The header is as tall as an account row and ends on the same columns.
  const headBox = (await head(page).boundingBox())!, soloBox = (await solo.locator('.p-acc').boundingBox())!;
  expect(Math.abs(headBox.height - soloBox.height)).toBeLessThanOrEqual(1);
  expect(Math.abs(headBox.x + headBox.width - (soloBox.x + soloBox.width))).toBeLessThanOrEqual(1);
  await shot('groups-collapsed');

  // Phone width: the chips move under the title and are never clipped or overlapped.
  await page.setViewportSize({ width: 390, height: 900 });
  const toggle = page.getByRole('button', { name: 'Toggle sidebar' });
  if (await toggle.getAttribute('aria-expanded') === 'true') await toggle.click();
  await expect(head(page).locator('.p-group-left').first()).toBeHidden();
  const chipBoxes = await head(page).locator('.p-usage-chip').evaluateAll(els => els.map(el => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, clipped: el.scrollWidth > el.clientWidth }; }));
  const edge = (await head(page).boundingBox())!;
  expect(chipBoxes.every(c => !c.clipped && c.right <= edge.x + edge.width)).toBe(true);
  expect(chipBoxes[0].right).toBeLessThanOrEqual(chipBoxes[1].left);
  await shot('groups-collapsed-phone');
  await page.setViewportSize({ width: 1100, height: 900 });
  if (await toggle.getAttribute('aria-expanded') === 'false') await toggle.click();

  // Click expands: the rows keep their priority order and their own controls.
  await head(page).click();
  await expect(head(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(rows(page)).toHaveCount(4);
  await expect(rows(page).locator('.p-account-email .sr-only')).toHaveText(['one@example.com', 'two@example.com', 'three@example.com', 'four@example.com']);
  await expect(rows(page).locator('.p-rank')).toHaveText(['1st', '2nd', '3rd', '4th']);
  await expect(page.getByRole('button', { name: 'Actions for Antigravity (two@example.com)' })).toBeVisible();
  await shot('groups-expanded');

  // A usage refresh updates the header in place: the group stays open and its rows are not rebuilt.
  await rows(page).first().evaluate(el => { (el as HTMLElement).dataset.probe = 'kept'; });
  await head(page).evaluate(el => { (el as HTMLElement).dataset.probe = 'kept'; });
  fixture.usage = { ...fixture.usage, four: pools(100, 30) };
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await expect(head(page).locator('.s-row-desc')).toHaveText('4 accounts·3 limit reached·1 near limit');
  await expect(head(page).locator('.p-usage-chip').first()).toHaveText('Claude & GPT2 of 4 left');
  await expect(head(page)).toHaveAttribute('data-probe', 'kept');
  await expect(rows(page).first()).toHaveAttribute('data-probe', 'kept');
  await expect(rows(page)).toHaveCount(4);

  // The choice is remembered across a reload.
  await page.reload();
  await page.getByRole('button', { name: 'Inference', exact: true }).click();
  await expect(head(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(rows(page)).toHaveCount(4);

  // Keyboard: the header is a button (Enter / Space), arrows collapse and expand.
  await head(page).focus();
  await page.keyboard.press('Enter');
  await expect(head(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(rows(page)).toHaveCount(0);
  await page.keyboard.press('Space');
  await expect(head(page)).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('ArrowRight');
  await expect(head(page)).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('ArrowLeft');
  await expect(head(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(head(page)).toBeFocused();
  // Quiet focus: the shared 1px stroke, no halo.
  expect(await head(page).evaluate(el => { const s = getComputedStyle(el); return [s.outlineWidth, s.outlineStyle, s.boxShadow]; })).toEqual(['1px', 'solid', 'none']);
  await page.reload();
  await page.getByRole('button', { name: 'Inference', exact: true }).click();
  await expect(head(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(rows(page)).toHaveCount(0);
});

test('an account that needs sign-in opens its group by default', async ({ page }, info) => {
  const fixture: Fixture = { providers: [agy('one', 0), agy('two', 1, 'needs_reauth'), codex], usage: { one: pools(10, 10) } };
  await open(page, fixture);
  await expect(head(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(head(page).locator('.s-row-desc')).toHaveText('2 accounts·1 needs sign-in');
  // The signed-out account counts as not available, not as missing.
  await expect(head(page).locator('.p-usage-chip')).toHaveText(['Claude & GPT1 of 2 left', 'Gemini1 of 2 left']);
  await expect(rows(page)).toHaveCount(2);
  await expect(rows(page).nth(1).locator('.p-st')).toHaveText('Reconnect');
  await subscriptions(page).screenshot({ path: report ? `${report}/groups-needs-sign-in.png` : info.outputPath('groups-needs-sign-in.png') });

  // Collapsing it anyway is the user's choice and is kept; the header still says why.
  await head(page).click();
  await expect(head(page)).toHaveAttribute('aria-expanded', 'false');
  await page.reload();
  await page.getByRole('button', { name: 'Inference', exact: true }).click();
  await expect(head(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(head(page).locator('.s-row-desc')).toHaveText('2 accounts·1 needs sign-in');
});
