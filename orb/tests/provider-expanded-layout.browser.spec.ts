import { test, expect } from '@playwright/test';

test.use({ browserName: process.env.ORB_TEST_BROWSER === 'webkit' ? 'webkit' : 'chromium' });
 for (const theme of ['light', 'dark']) for (const width of [1100, 480]) test(`expanded quota space and footer ${theme} ${width}`, async ({ page }, info) => {
  await page.addInitScript(theme => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');localStorage.setItem('orb-theme',theme);},theme);
  const entries = { xai: {provider_type:'xai',xai_plan:'SuperGrok Heavy',xai_credit_label:'Weekly',xai_credit_used_percent:38,xai_credit_reset:Math.floor(Date.now()/1000)+144000,xai_on_demand_used:35,xai_on_demand_cap:100}, openai: {provider_type:'openai',codex_primary_used_percent:7,codex_primary_window_minutes:10080}, agy: {provider_type:'antigravity',antigravity_windows:[{label:'Gemini · 5h',used_percent:33},{label:'Claude & GPT · 5h',used_percent:0},{label:'Claude & GPT · Weekly',used_percent:52}]} };
  await page.route('**/api/**',route=> {
   const path=new URL(route.request().url()).pathname;
   const body=path==='/api/ai/providers' ? [{id:'xai',name:'xAI',provider_type:'xai',uses_oauth:true,status:{type:'connected'}},{id:'openai',name:'OpenAI',provider_type:'openai',uses_oauth:true,status:{type:'connected'}},{id:'agy',name:'Google Antigravity',provider_type:'antigravity',uses_oauth:true,status:{type:'connected'}}]
    :path.endsWith('/xai/usage')?entries.xai:path==='/api/ai/providers/usage'?{entries}:path.endsWith('/openai/usage')?entries.openai:path.endsWith('/agy/usage')?entries.agy
    :path==='/api/managed-machines/settings'?{antigravity_on_managed:true}:path==='/api/providers/antigravity-models'?[['gemini','Gemini']]
    :path==='/api/remote-nodes'?{nodes:[]}:path==='/api/projects'?{projects:[]}:[];
   return route.fulfill({json:body});
  });
  await page.goto('/');await page.getByRole('button',{name:'Providers',exact:true}).click();
  await page.setViewportSize({width,height:1000});
  if(width===480) {const toggle=page.getByRole('button',{name:'Toggle sidebar'});if(await toggle.getAttribute('aria-expanded')==='true') await toggle.click();}
  const openai=page.locator('.p-acc-wrap').filter({has:page.locator('.s-row-title',{hasText:'OpenAI'})});
  await openai.locator('.p-acc-btn').click();
  const row=openai.locator('.provider-usage-row');const bar=openai.getByRole('progressbar');
  await expect(bar).toBeVisible();
  expect((await bar.boundingBox())!.width / (await row.boundingBox())!.width).toBeGreaterThan(0.55);
  const agy=page.locator('.p-acc-wrap').filter({has:page.locator('.s-row-title',{hasText:'Google Antigravity'})});
  await expect(agy.locator('.provider-usage-unavailable')).toHaveText('WeeklyNot reported');
  await expect(agy.locator('.provider-usage-unavailable').getByRole('progressbar')).toHaveCount(0);
  const footer=agy.getByRole('region',{name:'Antigravity execution',exact:true});
  const detail=await agy.locator('.p-detail').boundingBox();
  expect((await footer.boundingBox())!.y).toBeGreaterThanOrEqual(detail!.y+detail!.height);
  await expect(footer.getByRole('switch')).toHaveAttribute('aria-checked','true');
  expect(await agy.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
  const xai=page.locator('.p-acc-wrap').filter({has:page.locator('.s-row-title',{hasText:'xAI'})});
  await xai.locator('.p-acc-btn').focus();await page.keyboard.press('Enter');
  const credits=xai.getByRole('progressbar',{name:'On-demand credits usage'});
  await expect(credits).toHaveAttribute('aria-valuenow','35');
  await expect(xai.getByText('35 / 100 used',{exact:true})).toBeVisible();
  await expect(xai.getByText('38% used',{exact:true})).toBeVisible();
  const meter=xai.locator('.provider-usage-meter').last();
  expect((await credits.boundingBox())!.width / (await meter.boundingBox())!.width).toBeGreaterThan(.95);
  expect(await xai.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
  await page.screenshot({path:info.outputPath('expanded-providers.png'),fullPage:true});
 });
