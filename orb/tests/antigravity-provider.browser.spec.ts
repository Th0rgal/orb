import { test, expect } from '@playwright/test';

for (const theme of ['dark', 'light']) test(`provider accounts and machine details stay distinct: ${theme}`, async ({ page }, testInfo) => {
  const browserName = testInfo.project.name;
  await page.addInitScript(theme => {
    localStorage.setItem('orb.apiUrl', location.origin);
    localStorage.setItem('orb.jwt', 'test');
    localStorage.setItem('orb-theme', theme);
  }, theme);
  await page.route('**/api/**', route => {
    const url = new URL(route.request().url());
    const body = url.pathname === '/api/providers/antigravity-models'
      ? url.searchParams.has('node_id') ? [['flash', 'Gemini Flash']] : Array.from({ length: 21 }, (_, i) => [`agy-${i}`, `Gemini model ${i + 1} with a long descriptive name`])
      : url.pathname === '/api/ai/providers' ? [
        { id: 'antigravity', name: 'Antigravity subscription', provider_type: 'antigravity', uses_oauth: true, has_oauth: true, credential_owner: 'cli_proxy', status: { type: 'connected' } },
        { id: 'google', name: 'Google Gemini', provider_type: 'google', uses_oauth: true, has_oauth: true, status: { type: 'connected' } },
        { id: 'google-key', name: 'Google key', provider_type: 'google', uses_oauth: true, has_oauth: false, has_api_key: true, status: { type: 'connected' } },
      ]
      : url.pathname === '/api/remote-nodes' ? { enabled: true, nodes: [{ id: 'old-agent', status: 'online', cordoned: false }] }
      : url.pathname === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
  const native = page.getByRole('region', { name: 'Antigravity execution', exact: true });
  await expect(native.getByRole('status')).toHaveText('Available on Core, old-agent');
  await expect(native.getByLabel('Antigravity machine')).toHaveCount(0);
  await expect(native.getByRole('button', { name: '21 models available' })).toBeVisible();
  await expect(native.getByRole('list')).toHaveCount(0);
  await expect(native.locator('.s-card')).toHaveCount(0);
  await expect(page.getByRole('region', { name: 'Model connections' }).getByText('Gemini model access', { exact: true })).toBeVisible();
  await expect(page.getByText('Gemini API', { exact: true })).toBeVisible();
  await page.screenshot({ path: `/tmp/orb-providers-${browserName}-${theme}.png`, fullPage: true });
  await page.setViewportSize({ width: 780, height: 700 });
  await native.getByRole('button', { name: '21 models available' }).click();
  const list = native.getByRole('list', { name: 'Antigravity models' });
  await expect(list).toBeVisible();
  expect((await list.boundingBox())!.height).toBeLessThanOrEqual(200);
  await page.screenshot({ path: `/tmp/orb-providers-expanded-${browserName}-${theme}.png`, fullPage: true });
  await page.getByRole('button', { name: /Google Antigravity Connected/ }).click();
  await expect(native).toHaveCount(0);
});

test('provider failures recover with the keyboard and keep the list on a failed refresh', async ({page}) => {
  await page.addInitScript(() => { localStorage.setItem('orb.apiUrl',location.origin); localStorage.setItem('orb.jwt','test'); });
  let fail = true;
  await page.route('**/api/**', route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/ai/providers' && fail) return route.fulfill({status:503,body:'Temporary outage'});
    return route.fulfill({json:path === '/api/ai/providers' ? [{id:'mistral',name:'Mistral Vibe',provider_type:'mistral',enabled:true,uses_oauth:true,status:{type:'connected'}}] : []});
  });
  await page.goto('/');
  await page.getByRole('button',{name:'Providers',exact:true}).click();
  await expect(page.getByRole('alert')).toContainText('Could not load providers');
  await expect(page.getByText('Loading providers…')).toHaveCount(0);
  fail = false;
  const retry = page.getByRole('button',{name:'Try again'});
  await retry.focus();
  await retry.press('Enter');
  await expect(page.getByText('Mistral Vibe',{exact:true})).toBeVisible();
  await expect(page.getByRole('button',{name:'View Mistral monthly usage'})).toBeVisible();
  await expect(page.getByRole('progressbar')).toHaveCount(0);
  fail = true;
  await page.getByRole('button',{name:'Refresh',exact:true}).click();
  await expect(page.getByRole('alert')).toContainText('Could not refresh providers');
  await expect(page.getByText('Mistral Vibe',{exact:true})).toBeVisible();
});

for (const theme of ['dark','light']) test(`Mistral monthly usage uses a clear console fallback: ${theme}`, async ({page}, info) => {
  await page.addInitScript(theme => { localStorage.setItem('orb.apiUrl',location.origin); localStorage.setItem('orb.jwt','test'); localStorage.setItem('orb-theme',theme); },theme);
  await page.route('**/api/**',route => route.fulfill({json:new URL(route.request().url()).pathname==='/api/ai/providers'?[{id:'mistral',name:'Mistral Vibe',provider_type:'mistral',enabled:true,uses_oauth:true,status:{type:'connected'}}]:[]}));
  await page.goto('/');
  await page.getByRole('button',{name:'Providers',exact:true}).click();
  await expect(page.getByRole('button',{name:'View Mistral monthly usage'})).toBeVisible();
  await page.getByRole('button',{name:/Mistral Vibe Connected/}).click();
  await expect(page.getByText(/monthly Vibe allowance only in its console/)).toBeVisible();
  await expect(page.getByRole('button',{name:'Show monthly usage'})).toBeVisible();
  await expect(page.getByRole('button',{name:'Open console ↗'})).toBeVisible();
  await expect(page.getByRole('progressbar')).toHaveCount(0);
  await page.screenshot({path:`/tmp/orb-mistral-usage-${info.project.name}-${theme}.png`,fullPage:true});
  await page.getByRole("button",{name:"Toggle sidebar",exact:true}).click();
  await page.setViewportSize({width:390,height:844});
  await expect(page.getByRole('button',{name:'Show monthly usage'})).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
  await page.screenshot({path:`/tmp/orb-mistral-usage-mobile-${info.project.name}-${theme}.png`,fullPage:true});
  await page.getByRole('button',{name:/Mistral Vibe Connected/}).click();
  await expect(page.getByRole('button',{name:'View Mistral monthly usage'})).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

test('Mistral monthly usage renders once the console session is connected', async ({page}) => {
  await page.addInitScript(() => { localStorage.setItem('orb.apiUrl',location.origin); localStorage.setItem('orb.jwt','test'); });
  const usage = {provider_type:'mistral',status:'connected',mistral_usage_session:'connected',mistral_plan:'Chat · Individual',mistral_monthly_used_percent:37,mistral_monthly_reset:1893456000};
  await page.route('**/api/**',route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/ai/providers') return route.fulfill({json:[{id:'mistral',name:'Mistral Vibe',provider_type:'mistral',enabled:true,uses_oauth:true,status:{type:'connected'}}]});
    if (path === '/api/ai/providers/usage') return route.fulfill({json:{entries:{mistral:usage}}});
    if (path === '/api/ai/providers/mistral/usage') return route.fulfill({json:usage});
    return route.fulfill({json:[]});
  });
  await page.goto('/');
  await page.getByRole('button',{name:'Providers',exact:true}).click();
  await expect(page.getByText('Chat · Individual')).toBeVisible();
  await expect(page.getByRole('button',{name:'View Mistral monthly usage'})).toHaveCount(0);
  await page.getByRole('button',{name:/Mistral Vibe Connected/}).click();
  await expect(page.getByText('Monthly',{exact:true}).first()).toBeVisible();
  await expect(page.getByRole('button',{name:'Disconnect usage'})).toBeVisible();
});

for (const theme of ['dark','light']) test(`Antigravity quota groups show shared 5h and weekly limits: ${theme}`, async ({page}, info) => {
  await page.addInitScript(theme => { localStorage.setItem('orb.apiUrl',location.origin); localStorage.setItem('orb.jwt','test'); localStorage.setItem('orb-theme',theme); }, theme);
  const soon = Math.floor(Date.now()/1000);
  const usage = {provider_type:'antigravity',status:'connected',antigravity_plan:'Google AI Ultra',antigravity_windows:[
    {label:'Gemini · 5h',used_percent:12,reset_at:soon+5*3600},{label:'Gemini · Weekly',used_percent:0.3,reset_at:soon+6*86400},
    {label:'Claude & GPT · 5h',used_percent:48,reset_at:soon+2*3600},{label:'Claude & GPT · Weekly',used_percent:91,reset_at:soon+7*86400}]};
  await page.route('**/api/**',route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/api/ai/providers') return route.fulfill({json:[{id:'antigravity',name:'Antigravity subscription',provider_type:'antigravity',uses_oauth:true,has_oauth:true,credential_owner:'cli_proxy',status:{type:'connected'}}]});
    if (path === '/api/ai/providers/usage') return route.fulfill({json:{entries:{antigravity:usage}}});
    if (path === '/api/ai/providers/antigravity/usage') return route.fulfill({json:usage});
    if (path === '/api/remote-nodes') return route.fulfill({json:{enabled:true,nodes:[]}});
    return route.fulfill({json:[]});
  });
  await page.goto('/');
  await page.getByRole('button',{name:'Providers',exact:true}).click();
  const groups = page.locator('.provider-usage-group');
  await expect(groups).toHaveCount(2);
  await expect(groups.locator('.provider-usage-group-title')).toHaveText(['Gemini','Claude & GPT']);
  await expect(groups.nth(1).getByRole('progressbar',{name:'Weekly usage'})).toHaveAttribute('aria-valuenow','91');
  await expect(groups.nth(0).getByText('Resets in 6d')).toBeVisible();
  await groups.nth(0).scrollIntoViewIfNeeded();
  await page.screenshot({path:`test-results/antigravity-quota-${info.project.name}-${theme}.png`,fullPage:true});
  // Collapsed: one chip per group, and the title keeps its width.
  await page.getByRole('button',{name:/Google Antigravity Claude & GPT quota at 91%/}).click();
  const chips = page.locator('.p-usage.compact .p-usage-chip');
  await expect(chips).toHaveCount(2);
  await expect(chips.nth(1)).toHaveText(/Claude & GPT\s*91%/);
  const title = page.locator('.s-row-title').filter({hasText:'Google Antigravity'});
  expect((await title.boundingBox())!.height).toBeLessThan(40);
  await page.setViewportSize({width:780,height:700});
  expect((await title.boundingBox())!.height).toBeLessThan(40);
  await page.screenshot({path:`test-results/antigravity-collapsed-${info.project.name}-${theme}.png`,fullPage:true});
});
