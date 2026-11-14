import {test, expect, type Page} from '@playwright/test';
import fs from 'node:fs';
import {startCore, longEvents, JWT, LONG} from './appPerfCore';

// Reference screenshots of the SolidJS desktop for the LeanUI parity table
// (scripts/leanui_parity.py). One PNG per LeanUI golden, same file name:
// `{screen}_{dark|light}_{1x|2x}.png`, logical viewport 1470x923.
// Data comes from the mock Core in appPerfCore.ts plus the routes below. The
// clock and the Core port are fixed and the build commit shown in Settings is
// replaced by zeros, so two runs produce the same pixels.
const OUT = process.env.ORB_REFERENCE_OUT || 'artifacts/leanui-reference';
const NOW = new Date('2026-10-20T12:00:00Z');
const CORE_PORT = Number(process.env.ORB_REFERENCE_CORE_PORT || 14470);
const THEMES = ['dark', 'light'] as const;
const SCALES = [1, 2] as const;
test.setTimeout(120_000);

const DIFF = [
 'diff --git a/lean/OrbDesktop/Main.lean b/lean/OrbDesktop/Main.lean',
 '--- a/lean/OrbDesktop/Main.lean',
 '+++ b/lean/OrbDesktop/Main.lean',
 '@@ -120,3 +120,3 @@ def renderDesktopFrame',
 '   let availW := viewport.w',
 '-  webkit_web_view_load_uri(wv, orb_dev_url);',
 '+  buildDesktopScreen st availW availH shapedRuns',
 '   let availH := viewport.h',
 '',
].join('\n');

const NODES = [
 {id: 'large-a', status: 'online', labels: ['managed'], cpu_total: 8, mem_total_bytes: 16 * 1024 ** 3, mem_available_bytes: 9 * 1024 ** 3, disk_total_bytes: 125 * 1024 ** 3, disk_available_bytes: 80 * 1024 ** 3, active_jobs: 2},
 {id: 'default-b', status: 'online', labels: ['managed'], cpu_total: 4, mem_total_bytes: 8 * 1024 ** 3, mem_available_bytes: 5 * 1024 ** 3, disk_total_bytes: 50 * 1024 ** 3, disk_available_bytes: 31 * 1024 ** 3, active_jobs: 1},
 {id: 'orb-core-primary', status: 'online', labels: [], cpu_total: 16, mem_total_bytes: 32 * 1024 ** 3, mem_available_bytes: 14 * 1024 ** 3, disk_total_bytes: 512 * 1024 ** 3, disk_available_bytes: 300 * 1024 ** 3, active_jobs: 3},
];

const hit = (n: number, title: string, status: string) => ({
 mission_id: `bbbbbbbb-0000-4000-8000-${String(n).padStart(12, '0')}`, title, project: 'p1', status, backend: 'claudecode',
 updated_at: '2026-10-20T11:45:00Z', locator: `title:${n}`, role: 'title', timestamp: '2026-10-20T11:45:00Z',
 excerpt: title, highlights: [{start: 0, end: 7}], mission_match_count: 1, score: 1 - n / 100,
});

type Screen = {id: string; empty?: boolean; run: (page: Page) => Promise<void>};

const projectRow = (page: Page) => page.getByRole('button', {name: 'Project 0', exact: true});
async function openLongMission(page: Page) {
 await projectRow(page).click();
 await page.locator('button.row.agent').filter({hasText: 'Long mission'}).first().click();
 await expect(page.getByText('Step 59', {exact: true})).toBeVisible();
}

const SCREENS: Screen[] = [
 {id: '01_control_empty', empty: true, run: async page => { await expect(page.getByText('New Agent').first()).toBeVisible(); }},
 {id: '02_control_populated', run: async page => { await expect(projectRow(page)).toBeVisible(); }},
 {id: '03_mission_transcript', run: openLongMission},
 {id: '04_mission_split_diff', run: async page => {
  await openLongMission(page);
  await page.evaluate(() => window.dispatchEvent(new Event('orb:open-changes')));
  await page.getByRole('button', {name: 'Split', exact: true}).click();
  await expect(page.getByText('buildDesktopScreen st availW availH shapedRuns').first()).toBeVisible();
 }},
 {id: '05_machines_fleet', run: async page => {
  await page.getByRole('button', {name: 'Machines', exact: true}).click();
  await expect(page.getByRole('button', {name: /orb-core-primary/}).first()).toBeVisible();
 }},
 {id: '06_settings_general', run: async page => {
  await page.getByRole('button', {name: 'Settings', exact: true}).click();
  const build = page.locator('.settings-row, [class*=row]').filter({hasText: 'Client build commit'}).locator('code').first();
  await expect(build).toBeVisible();
  await build.evaluate(el => { el.textContent = '00000000'; });
  await expect(page.getByText('Unknown', {exact: true})).toBeVisible();
 }},
 {id: '07_search_dialog', run: async page => {
  await expect(projectRow(page)).toBeVisible();
  await page.getByRole('button', {name: 'Search conversations'}).click();
  const input = page.getByPlaceholder('Search conversations and messages…');
  await input.fill('mission');
  await expect(page.getByText('Please inspect module 1 and fix what is broken.')).toBeVisible();
 }},
 // The SolidJS desktop has no "new mission" dialog: a mission is started from
 // the New Agent page. This is that page with the same title typed in.
 {id: '08_new_mission_dialog', run: async page => {
  await expect(projectRow(page)).toBeVisible();
  await page.getByPlaceholder(/Describe a task/).fill('Verify Wave 3 OrbDesktop 36-golden suite');
 }},
 {id: '09_toast_notifications', run: async page => {
  await expect(projectRow(page)).toBeVisible();
  await page.evaluate(async () => {
   const {notify} = await import('/src/toast.tsx' as string);
   notify({key: 'ref-1', kind: 'info', title: 'Mechanical Gate 1 Passed (124/124 Tight Specs)', message: 'All 124 kernel-checked specifications verified with zero vacuous theorems in LeanUISpec.', timeout: 0});
   notify({key: 'ref-2', kind: 'info', title: 'Managed VM large-a Enrolled', message: '8 vCPU / 16 GB RAM ready on Zen 5 AVX-512 node.', timeout: 0});
   notify({key: 'ref-3', kind: 'info', tone: 'warning', title: 'VM TTL Notice (15m Remaining)', message: 'Call extend_managed_machine or harvest bundle before expiry.', timeout: 0});
  });
  await expect(page.getByText('VM TTL Notice (15m Remaining)')).toBeVisible();
 }},
];

async function routes(page: Page, empty: boolean) {
 if (empty) {
  await page.route('**/api/projects', r => r.fulfill({json: {projects: []}}));
  await page.route(/\/api\/control\/missions(\?.*)?$/, r => r.fulfill({json: []}));
 }
 await page.route('**/api/remote-nodes', r => r.fulfill({json: {nodes: NODES}}));
 await page.route('**/api/control/missions/*/checkpoints', r => r.fulfill({json: {checkpoints: []}}));
 await page.route('**/api/control/missions/*/checkpoints/diff**', r => r.fulfill({json: {
  from_ref: 'HEAD', to_ref: '', files: [{status: 'M', path: 'lean/OrbDesktop/Main.lean', additions: 1, deletions: 1}],
  total_additions: 1, total_deletions: 1, raw_diff: DIFF, budget_exceeded: false, filtered_by_author: false,
 }}));
 await page.route('**/api/control/missions/search/messages**', r => r.fulfill({json: {
  hits: [hit(1, 'Mission 1 doing some work', 'active'), hit(2, 'Mission 2 doing some work', 'active'), hit(21, 'Mission 21 doing some work', 'completed')],
  next_cursor: null, coverage: {schema_version: 1, state: 'ready', indexed_missions: 100, total_missions: 100},
 }}));
 await page.route('**/api/control/missions/*/messages/context**', r => r.fulfill({json: {
  mission_id: hit(1, '', '').mission_id, title: 'Mission 1 doing some work', project: 'p1', status: 'active', backend: 'claudecode',
  updated_at: '2026-10-20T11:45:00Z', locator: 'title:1', target_found: true, target_sequence: 1,
  messages: [
   {locator: 'event:1', role: 'user', sequence: 1, timestamp: '2026-10-20T11:44:00Z', content: 'Please inspect module 1 and fix what is broken.', highlights: [], is_target: true},
   {locator: 'event:2', role: 'assistant', sequence: 2, timestamp: '2026-10-20T11:45:00Z', content: 'The change keeps behaviour identical.', highlights: [], is_target: false},
  ],
 }}));
 await page.routeWebSocket('**/api/monitoring/ws', () => {});
}

for (const screen of SCREENS) for (const theme of THEMES) for (const scale of SCALES) {
 const name = `${screen.id}_${theme}_${scale}x`;
 test(name, async ({browser}) => {
  const core = await startCore(longEvents(), CORE_PORT);
  const context = await browser.newContext({viewport: {width: 1470, height: 923}, deviceScaleFactor: scale, colorScheme: theme, reducedMotion: 'reduce'});
  try {
   const page = await context.newPage();
   await page.clock.setFixedTime(NOW);
   await page.addInitScript(a => {
    localStorage.setItem('orb.apiUrl', a.url); localStorage.setItem('orb.jwt', a.jwt); localStorage.setItem('orb-theme', a.theme);
   }, {url: core.url, jwt: JWT, theme});
   await routes(page, !!screen.empty);
   await page.goto('/');
   await screen.run(page);
   await page.mouse.move(735, 2);
   await page.evaluate(async () => {
    await document.fonts.ready;
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
   });
   // Settled means two consecutive frames with the same bytes.
   let shot = Buffer.alloc(0), frames = 0;
   for (; frames < 20; frames++) {
    await page.waitForTimeout(250);
    const next = await page.screenshot({animations: 'disabled', caret: 'hide'});
    if (next.equals(shot)) break;
    shot = next;
   }
   expect(frames, 'the screen never settled').toBeLessThan(20);
   console.log(`${name}: settled after ${frames} frames`);
   fs.mkdirSync(OUT, {recursive: true});
   fs.writeFileSync(`${OUT}/${name}.png`, shot);
   if (name === '03_mission_transcript_dark_1x') {
    const cdp = await context.newCDPSession(page);
    await cdp.send('DOM.enable'); await cdp.send('CSS.enable');
    const {root} = await cdp.send('DOM.getDocument');
    const used: Record<string, unknown> = {};
    for (const sel of ['#orb-sidebar .row-label', '.st-text', '.st-text pre code']) {
     const {nodeId} = await cdp.send('DOM.querySelector', {nodeId: root.nodeId, selector: sel});
     used[sel] = nodeId ? (await cdp.send('CSS.getPlatformFontsForNode', {nodeId})).fonts : 'no such node';
    }
    fs.writeFileSync(`${OUT}/ENV.json`, JSON.stringify({
     now: NOW.toISOString(), viewport: '1470x923', userAgent: await page.evaluate(() => navigator.userAgent),
     browserVersion: browser.version(), longMission: LONG, platformFonts: used,
    }, null, 1) + '\n');
   }
  } finally { await context.close(); await core.close(); }
 });
}
