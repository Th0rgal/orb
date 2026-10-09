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
      : url.pathname === '/api/remote-nodes' ? { enabled: true, nodes: [{ id: 'old-agent' }] }
      : url.pathname === '/api/projects' ? { projects: [] } : [];
    return route.fulfill({ json: body });
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Providers', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
  const native = page.getByRole('region', { name: 'Antigravity execution', exact: true });
  await expect(native.getByLabel('Antigravity machine')).toBeVisible();
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
  await native.getByLabel('Antigravity machine').selectOption('old-agent');
  await expect(native.getByText('Gemini Flash', { exact: true })).toBeVisible();
  await expect(native.getByText('Gemini model 1 with a long descriptive name', { exact: true })).toHaveCount(0);
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
  await expect(page.getByText(/Its live counter is not available/)).toBeVisible();
  await expect(page.getByRole('progressbar')).toHaveCount(0);
  await page.screenshot({path:`/tmp/orb-mistral-usage-${info.project.name}-${theme}.png`,fullPage:true});
  await page.getByRole("button",{name:"Toggle sidebar",exact:true}).click();
  await page.setViewportSize({width:390,height:844});
  await expect(page.getByRole('button',{name:'View monthly usage ↗'})).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
  await page.screenshot({path:`/tmp/orb-mistral-usage-mobile-${info.project.name}-${theme}.png`,fullPage:true});
  await page.getByRole('button',{name:/Mistral Vibe Connected/}).click();
  await expect(page.getByRole('button',{name:'View Mistral monthly usage'})).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
