import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('compact quota rows, separate account actions and API key add/edit',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const accounts=[{id:'quota',name:'OpenAI (person@example.com)',account_email:'person@example.com',provider_type:'openai',uses_oauth:true,status:{type:'connected'}},{id:'key',name:'Work key',provider_type:'openai',uses_oauth:false,status:{type:'connected'}}];
 const usage={provider_type:'openai',codex_primary_used_percent:100,codex_primary_window_minutes:10080,codex_primary_reset_at:Math.floor(Date.now()/1000)+7200};
 const writes:any[]=[];
 await page.route('**/api/**',route=>{
  const req=route.request(),path=new URL(req.url()).pathname;
  if(['POST','PUT'].includes(req.method())) {writes.push({method:req.method(),body:req.postDataJSON()});return route.fulfill({json:{}});}
  return route.fulfill({json:path==='/api/cloud/accounts'?[{id:'cursor-default',provider:'cursor_cloud',label:'Cursor Cloud',available:true,experimental:false}]:path==='/api/ai/providers'?accounts:path==='/api/ai/providers/usage'?{entries:{quota:usage}}:path.endsWith('/quota/usage')?usage:path==='/api/projects'?{projects:[]}:[]});
 });
 await page.goto('/');await page.getByRole('button',{name:'Inference',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Inference',exact:true})).toBeVisible();
 const account=page.locator('.p-acc-wrap').filter({hasText:'person@example.com'});
 await account.locator('.p-acc-btn').click();
 await expect(account.getByRole('button',{name:'Reconnect',exact:true})).toHaveCount(0);
 const meter=account.getByRole('progressbar');await expect(meter).toHaveAttribute('aria-valuenow','100');
 // Quotas sit on one compact row per pool.
 const row=await account.locator('.provider-usage-row').first().boundingBox();
 expect(row!.height).toBeLessThan(30);
 await expect(account.locator('.p-chip')).toHaveCount(0);
 const menuBtn=account.getByRole('button',{name:/Actions for/});
 await menuBtn.click();
 const popup=page.getByRole('menu',{name:'Actions'});
 await expect(popup.getByRole('menuitem',{name:'Re-authenticate'})).toBeVisible();
 await expect(popup.getByRole('menuitem',{name:'Remove provider…'})).toHaveClass(/\bdanger\b/);
 await expect(popup.getByRole('separator')).toHaveCount(2);
 // The popup menu stays right-aligned inside the card instead of overflowing past it.
 const cardBox=await account.locator('xpath=ancestor::div[contains(@class,"s-card")]').boundingBox();
 const menuBox=await popup.boundingBox();
 expect(menuBox!.x+menuBox!.width).toBeLessThanOrEqual(cardBox!.x+cardBox!.width+1);
 if (process.env.ORB_REPORT_DIR) await page.screenshot({ path: `${process.env.ORB_REPORT_DIR}/inference-menu-dark.png`, animations: 'disabled', fullPage: true });
 await menuBtn.click();await expect(popup).toHaveCount(0);
 await page.getByRole('button',{name:'Add API key',exact:true}).click();
 const dialog=page.getByRole('dialog');await dialog.locator('input').nth(0).fill('New account');await dialog.locator('input[type=password]').fill('test-only-secret');
 await dialog.getByRole('button',{name:'Save',exact:true}).click();await expect(dialog).toHaveCount(0);
 expect(writes[0]).toEqual({method:'POST',body:{provider_type:'openai',name:'New account',api_key:'test-only-secret'}});
 const key=page.locator('.p-acc-wrap').filter({hasText:'Work key'});await key.getByRole('button',{name:/Actions for/}).click();await page.getByRole('menuitem',{name:'Edit API key'}).click();
 await expect(dialog.locator('input[type=password]')).toHaveValue('');await dialog.locator('input[type=password]').fill('replacement-test-key');await dialog.getByRole('button',{name:'Save',exact:true}).click();await expect(dialog).toHaveCount(0);
 expect(writes[1]).toEqual({method:'PUT',body:{name:'Work key',api_key:'replacement-test-key'}});
 await account.locator('.p-acc-btn').click();
 await expect(account.locator('.provider-usage-chip-label')).toContainText(['Weekly']);
 const cloud=page.getByRole('region',{name:'Cloud agents'});
 await cloud.getByRole('button',{name:/Cursor Cloud/}).click();
 await expect(cloud.getByRole('button',{name:/View usage in Cursor/})).toBeVisible();
 await expect(cloud.getByRole('progressbar')).toHaveCount(0);
 expect(await cloud.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
});
