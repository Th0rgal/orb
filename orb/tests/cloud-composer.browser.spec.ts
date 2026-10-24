import { test, expect, type Page } from '@playwright/test';
import { startBubbleSampling, stopBubbleSampling } from './fluidity';

const MID = 'cccccccc-cccc-4ccc-cccc-cccccccccccc';
const caps = (attachments: boolean) => ({ models: false, repository: false, follow_up: true, cancel: true, artifacts: false, attachments, detailed_events: false });
const ACCOUNTS = [
 { id: 'grok', provider: 'grok_bot', label: 'Grok Bot', available: true, experimental: true, capabilities: caps(false) },
 { id: 'cursor-default', provider: 'cursor_cloud', label: 'Cursor Cloud', available: true, experimental: false, capabilities: caps(false) },
 { id: 'paloma', provider: 'hermes', label: 'Paloma', available: true, experimental: false, capabilities: caps(true) },
];

async function mock(page: Page, o: { launches: any[]; createDelay?: number; executionDelay?: number }) {
 let created = false;
 const mission = { id: MID, title: 'Read the attached notes', backend: 'cloud_hermes', project: 'demo', status: 'active', history: [], created_at: '', updated_at: '' };
 await page.addInitScript(() => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); });
 await page.route('**/api/**', async route => {
  const request = route.request(), url = new URL(request.url()), path = url.pathname;
  if (path === '/api/control/stream') return route.fulfill({ contentType: 'text/event-stream', body: '' });
  if (path === '/api/uploads' && request.method() === 'POST') { const name = request.postDataJSON()?.name || 'notes.txt'; return route.fulfill({ json: { name, path: `/var/lib/sandboxed-sh/uploads/${name}`, size: 12, sha256: 'abc' } }); }
  if (path === '/api/fs/upload' && request.method() === 'POST') return route.fulfill({ json: { path: `/var/lib/sandboxed-sh/uploads/${url.searchParams.get('name') || 'notes.txt'}` } });
  if (path === '/api/control/missions' && request.method() === 'POST') {
   o.launches.push(request.postDataJSON());
   if (o.createDelay) await new Promise(r => setTimeout(r, o.createDelay));
   created = true;
   return route.fulfill({ json: mission });
  }
  let json: unknown = {};
  if (path === '/api/projects') json = { projects: [{ slug: 'demo', title: 'Demo' }] };
  else if (path === '/api/cloud/accounts') json = ACCOUNTS;
  else if (path === `/api/control/missions/${MID}`) json = mission;
  else if (path === `/api/control/missions/${MID}/cloud`) {
   if (o.executionDelay) await new Promise(r => setTimeout(r, o.executionDelay));
   json = { mission_id: MID, revision: 1, selection: { provider: 'hermes', account: 'paloma' }, turns: [{ key: 't1', prompt: o.launches.at(-1)?.prompt ?? '', phase: 'running', artifacts: [], branches: [] }] };
  }
  else if (path === `/api/control/missions/${MID}/cloud/children`) json = { missions: [] };
  else if (path === '/api/control/missions') json = created ? [mission] : [];
  else if (path === '/api/control/queue' || path === '/api/backends') json = [];
  else if (path.endsWith('/files')) json = { entries: [] };
  else if (path.endsWith('/crons')) json = { jobs: [] };
  else if (path.includes('/controller')) json = { job: null, runs: [] };
  else if (path === '/api/providers/backend-models') json = { backends: {} };
  return route.fulfill({ json });
 });
}
const plusInset = (page: Page, scope: string) => page.locator(`${scope} .composer`).first().evaluate(c => {
 const plus = c.querySelector('.plus')!.getBoundingClientRect(), box = c.getBoundingClientRect();
 return { left: Math.round(plus.left - box.left), bottom: Math.round(box.bottom - plus.bottom) };
});

test('Hermes is the default service; "+" sits like the mission composer and sends the file', async ({ page }) => {
 const launches: any[] = [];
 await mock(page, { launches });
 await page.goto('/');
 const mission = await plusInset(page, '.main .new-agent');
 await page.getByRole('button', { name: 'Cloud agent', exact: true }).click();
 const form = page.getByRole('region', { name: 'Cloud agent' });
 await expect(form.getByLabel('Service', { exact: true })).toContainText('Hermes');
 await expect(form.getByLabel('Profile', { exact: true })).toContainText('Paloma');
 const plus = form.getByRole('button', { name: 'Attach file or image' });
 await expect(plus).toBeVisible();
 await expect(plus).toBeEnabled();
 expect(await plusInset(page, '.cloud-agent-page')).toEqual(mission);
 await form.getByLabel('Choose images').setInputFiles({ name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('ORB_ATTACH_OK') });
 await expect(form.getByRole('button', { name: 'Remove notes.txt' })).toBeVisible();
 await form.getByLabel('Prompt', { exact: true }).fill('Read the attached notes');
 await form.getByRole('button', { name: 'Create cloud agent' }).click();
 await expect.poll(() => launches.length).toBe(1);
 expect(launches[0].cloud).toMatchObject({ provider: 'hermes', account: 'paloma' });
 expect(launches[0].prompt).toContain('@/var/lib/sandboxed-sh/uploads/notes.txt');
 expect(launches[0]).not.toHaveProperty('attachments');
});

test('a removed chip is not sent, and services without attachments disable "+" with a reason', async ({ page }) => {
 const launches: any[] = [];
 await mock(page, { launches });
 await page.goto('/');
 await page.getByRole('button', { name: 'Cloud agent', exact: true }).click();
 const form = page.getByRole('region', { name: 'Cloud agent' });
 await form.getByLabel('Choose images').setInputFiles({ name: 'drop.txt', mimeType: 'text/plain', buffer: Buffer.from('x') });
 await form.getByRole('button', { name: 'Remove drop.txt' }).click();
 await expect(form.getByRole('button', { name: 'Remove drop.txt' })).toHaveCount(0);
 for (const name of ['Grok Bot', 'Cursor Cloud']) {
  await form.getByLabel('Service', { exact: true }).click();
  await page.getByRole('option', { name, exact: true }).click();
  const plus = form.getByRole('button', { name: 'Attach file or image' });
  await expect(plus).toBeVisible();
  await expect(plus).toBeDisabled();
  await expect(plus).toHaveAttribute('title', new RegExp(`${name} doesn’t accept attachments`));
 }
 // A drop on an unsupported service is refused out loud, not dropped.
 await form.locator('.composer').dispatchEvent('drop', { dataTransfer: await page.evaluateHandle(() => { const d = new DataTransfer(); d.items.add(new File(['x'], 'x.txt', { type: 'text/plain' })); return d; }) });
 await expect(page.getByText(/Cursor Cloud doesn’t accept attachments/).first()).toBeVisible();
 // The last explicit choice is kept.
 await page.reload();
 await expect(page.getByRole('region', { name: 'Cloud agent' }).getByLabel('Service', { exact: true })).toContainText('Cursor Cloud');
 expect(launches).toEqual([]);
});

test('launching renders the conversation at once: no bare loading line, the bubble does not move', async ({ page }) => {
 const launches: any[] = [];
 await mock(page, { launches, createDelay: 700, executionDelay: 500 });
 await page.goto('/');
 await page.getByRole('button', { name: 'Cloud agent', exact: true }).click();
 const form = page.getByRole('region', { name: 'Cloud agent' });
 await expect(form.getByLabel('Service', { exact: true })).toContainText('Hermes');
 const prompt = 'Fluid launch check';
 await form.getByLabel('Prompt', { exact: true }).fill(prompt);
 await startBubbleSampling(page, prompt, /^\s*(Launching|Loading cloud conversation|Starting cloud)/i);
 await form.getByRole('button', { name: 'Create cloud agent' }).click();
 await expect(page.locator('.tb-title, header').first()).toContainText(prompt);
 await expect(page.locator('.main .user').filter({ hasText: prompt })).toBeVisible();
 await expect(page.getByText('Working', { exact: false }).first()).toBeVisible();
 await expect(page.getByPlaceholder(/Send follow-up/)).toBeVisible();
 await expect.poll(() => page.evaluate(() => location.hash + document.title)).toBeTruthy();
 // Through creation and the first server state.
 await page.waitForTimeout(1800);
 const r = await stopBubbleSampling(page);
 expect(r.bare).toBe(0);
 expect(r.shown).toBeGreaterThan(10);
 expect(r.gaps).toBe(0);
 expect(r.maxShift).toBeLessThanOrEqual(2);
});
