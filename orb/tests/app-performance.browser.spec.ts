import {test, expect, type Page} from '@playwright/test';
import {startCore, JWT, LONG, type Core} from './appPerfCore';

// Whole-app runs against a mock Core with realistic volume. Each action
// reports wall time, long tasks (>50 ms), DOM mutations and requests.
test.setTimeout(180_000);

const probe = () => {
 const w = window as any;
 w.__perf = {long: [] as number[], mutations: 0};
 new PerformanceObserver(list => { for (const e of list.getEntries()) w.__perf.long.push(Math.round(e.duration)); }).observe({type: 'longtask', buffered: true});
 const watch = () => new MutationObserver(list => { for (const r of list) w.__perf.mutations += r.addedNodes.length + r.removedNodes.length + (r.type === 'characterData' || r.type === 'attributes' ? 1 : 0); })
  .observe(document.documentElement, {subtree: true, childList: true, characterData: true, attributes: true});
 if (document.documentElement) watch(); else addEventListener('DOMContentLoaded', watch);
};
async function measure(page: Page, core: Core, action: () => Promise<unknown>) {
 await page.evaluate(() => { const p = (window as any).__perf; if (p) { p.long = []; p.mutations = 0; } });
 core.counts.clear();
 const t0 = Date.now();
 await action();
 const ms = Date.now() - t0;
 await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
 const p = await page.evaluate(() => (window as any).__perf);
 return {ms, longTasks: p.long.length, longMs: p.long.reduce((a: number, b: number) => a + b, 0), maxLong: Math.max(0, ...p.long), mutations: p.mutations, requests: Object.fromEntries(core.counts)};
}

test('whole app: open, stream, switch, sidebar refresh and idle polls', async ({page}) => {
 const core = await startCore();
 const report: Record<string, unknown> = {};
 try {
  await page.addInitScript(a => { localStorage.setItem('orb.apiUrl', a.url); localStorage.setItem('orb.jwt', a.jwt); }, {url: core.url, jwt: JWT});
  await page.addInitScript(probe);
  const rate = Number(process.env.ORB_PERF_CPU_THROTTLE ?? 1);
  if (rate > 1) await (await page.context().newCDPSession(page)).send('Emulation.setCPUThrottlingRate', {rate});
  report.start = await measure(page, core, async () => {
   await page.goto('/');
   await expect(page.getByRole('button', {name: 'Project 0', exact: true})).toBeVisible();
  });
  await page.getByRole('button', {name: 'Project 0', exact: true}).click();
  await page.getByRole('button', {name: 'Project 1', exact: true}).click();
  const row = (title: string) => page.locator('button.row.agent').filter({hasText: title}).first();
  report.open = await measure(page, core, async () => {
   await row('Long mission').click();
   await expect(page.getByText('Step 59', {exact: true})).toBeVisible();
  });
  report.stream = await measure(page, core, async () => {
   for (let i = 0; i < 200; i++) {
    core.push('text_delta', {mission_id: LONG, content: `word${i} `});
    await new Promise(r => setTimeout(r, 15));
   }
   await expect(page.getByText(/word199/)).toBeVisible();
  });
  report.switch = await measure(page, core, async () => {
   for (let i = 0; i < 5; i++) {
    await row('Mission 21 doing').click();
    await expect(page.locator('.st-text, .empty, .composer').first()).toBeVisible();
    await row('Long mission').click();
    await expect(page.getByText('Step 59', {exact: true})).toBeVisible();
   }
  });
  report.idle = await measure(page, core, () => page.waitForTimeout(12_000));
  const r = report as Record<string, {ms: number; maxLong: number; mutations: number; requests: Record<string, number>}>;
  const total = (k: string) => Object.values(r[k].requests).reduce((a, b) => a + b, 0);
  // A delta patches the live turn only, never the transcript or sidebar.
  expect(r.stream.mutations / 200).toBeLessThan(6);
  // One switch reads the mission, its events and side panels: no list storms.
  expect(total('switch') / 10).toBeLessThan(20);
  expect((r.switch.requests['/api/control/missions'] ?? 0) / 10).toBeLessThan(5);
  // Idle: no DOM churn, and polling stays within its intervals.
  expect(r.idle.mutations).toBeLessThan(20);
  expect(r.idle.requests['/api/control/missions'] ?? 0).toBeLessThan(16);
  for (const k of ['open', 'stream', 'switch', 'idle']) expect(r[k].maxLong).toBeLessThan(250);
 } finally {
  console.log('APP_PERF', JSON.stringify(report, null, 1));
  await core.close();
 }
});
