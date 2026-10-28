import {test, expect} from '@playwright/test';
import {startCore, JWT, LONG} from './appPerfCore';
test.setTimeout(180000);
// ~3000 events, 7.7 MB: big tool outputs like the prod mission 26f2518c.
function heavy() {
 const out: Record<string, unknown>[] = []; let seq = 0;
 const push = (event_type: string, content: string, extra: Record<string, unknown> = {}) => { seq++; out.push({id: seq, sequence: seq, event_id: `e${seq}`, event_type, content, timestamp: new Date(Date.UTC(2026, 9, 20) + seq * 1000).toISOString(), ...extra}); };
 for (let t = 0; t < 40; t++) {
  push('user_message', `Turn ${t}: keep going.`);
  for (let k = 0; k < 36; k++) { const id = `c${t}-${k}`; push('tool_call', JSON.stringify({command: `cat src/file_${k}.rs`}), {tool_call_id: id, tool_name: 'Bash'}); push('tool_result', `line ${k} of a large file with some code in it\n`.repeat(k % 6 === 0 ? 400 : 40), {tool_call_id: id, tool_name: 'Bash'}); }
  push('assistant_message', `## Turn ${t}\n\nDone with step ${t}.`);
 }
 return out;
}
const seen: Record<string, {ms: number; kb: number}> = {};
for (const mode of ['full', 'max_payload']) test(`heavy mission open (${mode})`, async ({page}) => {
 const events = heavy();
 const core = await startCore(events);
 await page.route('**/events?**', route => { const u = new URL(route.request().url()); if (mode === 'full') u.searchParams.delete('max_payload'); return route.continue({url: u.toString()}); });
 let bytes = 0; page.on('response', async r => { if (r.url().includes(`${LONG}/events`)) bytes += (await r.body().catch(() => Buffer.alloc(0))).length; });
 await page.addInitScript(a => { localStorage.setItem('orb.apiUrl', a.url); localStorage.setItem('orb.jwt', a.jwt); }, {url: core.url, jwt: JWT});
 const t0 = Date.now();
 await page.goto('/');
 await page.getByRole('button', {name: 'Project 0', exact: true}).click();
 await page.locator('button.row.agent').filter({hasText: 'Long mission'}).first().click();
 await expect(page.getByText('Turn 39', {exact: true})).toBeVisible({timeout: 60000});
 const firstRender = Date.now() - t0;
 await page.waitForTimeout(2000);
 console.log('HEAVY', mode, 'first_render_ms', firstRender, 'event_kb', Math.round(bytes / 1024), 'pages', core.counts.get('/api/control/missions/:id/events'));
 seen[mode] = {ms: firstRender, kb: bytes / 1024};
 if (mode === 'max_payload') {
  // Shortened rows: far fewer bytes, and an opened row shows its whole output.
  expect(seen.max_payload.kb).toBeLessThan(seen.full.kb * 0.6);
  await page.locator('.st-work-head').last().click();
  await page.locator('.st-tool-head').filter({hasText: 'file_0.rs'}).last().click();
  const detail = page.locator('.st-tool-detail').last();
  await expect(detail).toContainText('line 0 of a large file');
  await expect(detail).not.toContainText('bytes omitted');
 }
 await core.close();
});
