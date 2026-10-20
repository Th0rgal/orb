import { test, expect, type Page } from '@playwright/test';
import { startSampling, markAction, stopSampling } from './fluidity';

// A cloud conversation is a mission: same transcript, scroll anchoring and composer.
const id = 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb';
const para = (n: number) => Array.from({length: 6}, (_, i) => `Paragraph ${n}.${i}: the cloud agent explains its reasoning at some length so the transcript overflows.`).join('\n\n');

async function mockCloud(page: Page, state: { streaming: boolean; chunks: number }) {
 const mission = {id, title: 'Cloud layout', backend: 'cloud_hermes', project: 'demo', status: 'active', history: [], created_at: '', updated_at: ''};
 await page.addInitScript(() => { localStorage.setItem('orb.apiUrl', location.origin); localStorage.setItem('orb.jwt', 'test'); });
 await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname;
  if (path === '/api/control/stream') return route.fulfill({contentType: 'text/event-stream', body: ''});
  if (path === '/api/control/message') return route.fulfill({json: {message_accepted: true, queued: true, mission_id: id}});
  let json: unknown = {};
  if (path === '/api/projects') json = {projects: [{slug: 'demo', title: 'Demo'}]};
  else if (path === '/api/control/missions') json = [mission];
  else if (path === `/api/control/missions/${id}`) json = mission;
  else if (path.endsWith('/cloud/children')) json = {missions: []};
  else if (path.endsWith('/cloud')) {
   if (state.streaming) state.chunks++;
   const turns = Array.from({length: 4}, (_, i) => ({key: `t${i}`, prompt: `Question ${i}`, phase: 'response_complete', result: para(i), artifacts: [], branches: []}));
   const live = Array.from({length: state.chunks}, (_, i) => `Live chunk ${i} keeps arriving while the agent streams its answer.`).join('\n\n');
   turns.push({key: 'live', prompt: 'Keep going', phase: state.streaming ? 'running' : 'response_complete', result: `${live}\n\nFINAL LINE ${state.chunks}`, artifacts: [], branches: []});
   json = {mission_id: id, revision: state.chunks, selection: {provider: 'hermes', account: 'hermes-default'}, turns};
  }
  else if (path === '/api/cloud/accounts') json = [{id: 'hermes-default', provider: 'hermes', label: 'Hermes', available: true, capabilities: {follow_up: true, cancel: true, attachments: true}}];
  else if (path.endsWith('/files')) json = {entries: []};
  else if (path.endsWith('/crons')) json = {jobs: []};
  else if (path.includes('/controller')) json = {job: null, runs: []};
  else if (path === '/api/control/queue' || path === '/api/backends') json = [];
  else if (path === '/api/providers/backend-models') json = {backends: {}};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button', {name: 'Demo', exact: true}).click();
 await page.locator('button.row.agent').filter({hasText: 'Cloud layout'}).click();
}

const gap = (page: Page) => page.locator('.main .scroll').evaluate(s => s.scrollHeight - s.scrollTop - s.clientHeight);

test('cloud conversation keeps the last message above the mission composer', async ({page}) => {
 const state = {streaming: false, chunks: 3};
 await mockCloud(page, state);
 const last = page.getByText('FINAL LINE 3');
 await expect(last).toBeVisible({timeout: 10000});
 // Same composer as a mission follow-up, in the same dock.
 const composer = page.locator('.main .dock .composer');
 await expect(composer).toHaveCount(1);
 await expect(composer.getByPlaceholder('Send follow-up')).toBeVisible();
 await expect(page.locator('.main .dock .composer textarea, .main .dock .composer [contenteditable]')).toHaveCount(1);
 await expect.poll(() => gap(page)).toBeLessThan(4);
 const text = await last.boundingBox(), box = await composer.boundingBox();
 expect(text && box && text.y + text.height).toBeLessThanOrEqual(box!.y);
});

test('cloud conversation stays pinned while streaming and keeps a scrolled-up position', async ({page}) => {
 const state = {streaming: true, chunks: 1};
 await mockCloud(page, state);
 await expect(page.getByText(/FINAL LINE/)).toBeVisible({timeout: 10000});
 // The mission Working row, not a cloud-specific one.
 await expect(page.locator('.main .scroll .st-working').first()).toBeVisible();
 await expect(page.locator('.cloud-working')).toHaveCount(0);
 await startSampling(page, 'Keep going');
 await markAction(page);
 const start = state.chunks;
 await expect.poll(() => state.chunks, {timeout: 15000}).toBeGreaterThan(start + 4);
 const run = await stopSampling(page);
 expect(run.maxJump).toBeLessThan(40);
 await expect.poll(() => gap(page)).toBeLessThan(4);
 const composer = await page.locator('.main .dock .composer').boundingBox();
 const last = await page.getByText(/FINAL LINE/).boundingBox();
 expect(last!.y + last!.height).toBeLessThanOrEqual(composer!.y);

 // Scrolling up stops following; more streamed text does not pull the reader down.
 await page.locator('.main .scroll').evaluate(s => { s.scrollTop = 200; s.dispatchEvent(new Event('scroll')); });
 const at = state.chunks;
 await expect.poll(() => state.chunks, {timeout: 15000}).toBeGreaterThan(at + 2);
 expect(await page.locator('.main .scroll').evaluate(s => s.scrollTop)).toBeLessThan(260);
});
