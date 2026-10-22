import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';

// Hermes attaches files with `MEDIA:<path>`. Core copies them into the mission
// media store and rewrites the answer to rich tags; old answers still carry the
// raw directive. Both render as shared files, never as the directive text.
const id = '55518e2b-ba20-42bc-b5d8-bbdb3b072328';
const store = `/root/.sandboxed-sh/mission-media/${id}`;
const hash = 'a'.repeat(64);
const png = readFileSync(new URL('./fixtures/hermes-usage-chart.png', import.meta.url));
const prose = 'Sur les 30 jours, Gemini fait 20 % du total, concentré sur les 4 derniers jours.';

async function mock(page: Page, theme: 'dark' | 'light') {
 const mission = {id, title: 'Usage Gemini', backend: 'cloud_hermes', project: 'demo', status: 'awaiting_user', history: [], created_at: '', updated_at: ''};
 const downloads: string[] = [];
 await page.addInitScript(t => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); localStorage.setItem('orb-theme', t); }, theme);
 await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname;
  if (path === '/api/control/stream') return route.fulfill({contentType: 'text/event-stream', body: ''});
  if (path === '/api/file-resources') {
   const q = request.postDataJSON();
   if (q.action === 'roots') return route.fulfill({json: {sources: [{id: 'media', label: 'Shared files', path: store, available: true}]}});
   if (q.action === 'resolve') return route.fulfill({json: {results: q.paths.map((reference: string) => ({reference, matches: reference === `${hash}.png` ? [{name: `${hash}.png`, path: `${hash}.png`, kind: 'file', size: png.length}] : []}))}});
   if (q.action === 'download') { downloads.push(q.path); return route.fulfill({json: {bytes: [...png], size: png.length, next: png.length}}); }
   return route.fulfill({json: {}});
  }
  if (path === '/api/fs/download') return route.fulfill({status: 404, body: 'File not found'});
  let json: unknown = {};
  if (path === '/api/projects') json = {projects: [{slug: 'demo', title: 'Demo'}]};
  else if (path === '/api/control/missions') json = [mission];
  else if (path === `/api/control/missions/${id}`) json = mission;
  else if (path.endsWith('/cloud/children')) json = {missions: []};
  else if (path.endsWith('/cloud')) json = {mission_id: id, revision: 1, selection: {provider: 'hermes', account: 'paloma'}, turns: [
   {key: 'old', prompt: 'Ancien graphique ?', phase: 'response_complete', result: 'Graphique (message antérieur) :\n\nMEDIA:/tmp/orb_usage_7d.png', artifacts: [], branches: []},
   {key: 'new', prompt: 'Trace un graphique de l’usage sur 30 jours', phase: 'response_complete', artifacts: [], branches: [],
    result: `${prose}\n\n<image path="${store}/${hash}.png" alt="orb_usage_30d.png" />\n\n<file path="/tmp/orb_usage_raw.csv" name="orb_usage_raw.csv" unavailable="true" />`},
  ]};
  else if (path === '/api/cloud/accounts') json = [{id: 'paloma', provider: 'hermes', label: 'Paloma', available: true, capabilities: {follow_up: true, cancel: true, attachments: true}}];
  else if (path.endsWith('/files')) json = {entries: []};
  else if (path.endsWith('/crons')) json = {jobs: []};
  else if (path.includes('/controller')) json = {job: null, runs: []};
  else if (path === '/api/control/queue' || path === '/api/backends') json = [];
  else if (path === '/api/providers/backend-models') json = {backends: {}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button', {name: 'Demo', exact: true}).click();
 await page.locator('button.row.agent').filter({hasText: 'Usage Gemini'}).click();
 return downloads;
}

for (const theme of ['dark', 'light'] as const) {
 test(`Hermes media renders as shared files (${theme})`, async ({page}) => {
  const downloads = await mock(page, theme);
  const main = page.locator('.main');
  await expect(main.getByText(prose)).toBeVisible({timeout: 10000});
  // The copied image renders inline, through the mission's media source.
  const image = main.locator('.md-workspace-image img[alt="orb_usage_30d.png"]');
  await expect(image).toBeVisible();
  await expect.poll(() => image.evaluate(img => (img as HTMLImageElement).naturalWidth)).toBe(640);
  expect(downloads).toContain(`${hash}.png`);
  // A file Core could not copy is a chip, not a dead path.
  await expect(main.locator('.md-file-unavailable')).toContainText('orb_usage_raw.csv');
  await expect(main.locator('.md-file-unavailable')).toContainText('File no longer available');
  // An answer stored before Core normalized still hides the directive.
  await expect(main.locator('.md-workspace-image-missing').filter({hasText: 'orb_usage_7d.png'})).toBeVisible();
  await expect(main).not.toContainText('MEDIA:');
  await page.screenshot({path: `screenshots/hermes-media-${theme}.png`});
  // Click opens the existing preview.
  await image.click();
  await expect(page.locator('.lightbox, [role="dialog"]').first()).toBeVisible();
  await page.screenshot({path: `screenshots/hermes-media-preview-${theme}.png`});
 });
}
