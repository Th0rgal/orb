import {test, expect} from '@playwright/test';
test.use({browserName:'webkit'});
for (const action of ['rename', 'delete'] as const) test(`sidebar preserves viewport after ${action}`, async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions = Array.from({length:60},(_,i)=>({id:`agent-${i}`,title:`Agent ${i}`,status:'failed',project:'one',tags:[],history:[],updated_at:new Date(Date.UTC(2026,8,30,0,60-i)).toISOString()}));
  await page.route('**/api/**', async route => {
    const req=route.request(), url=new URL(req.url()), path=url.pathname, id=path.split('/')[4];
    if(req.method()==='DELETE') { missions=missions.filter(m=>m.id!==id); return route.fulfill({json:{deleted_ids:[id]}}); }
    if(req.method()==='POST' && path.endsWith('/title')) { missions=missions.map(m=>m.id===id?{...m,title:req.postDataJSON().title}:m); return route.fulfill({json:{ok:true}}); }
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'}]}
      :path==='/api/control/missions'?missions:path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
      :path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/'); await page.getByRole('button',{name:'One',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  await tree.getByRole('button',{name:'Agent 0',exact:true}).click();
  const target=tree.getByRole('button',{name:'Agent 35',exact:true});
  await target.scrollIntoViewIfNeeded();
  // Right-click does not necessarily focus the clicked row on macOS.
  await target.click({button:'right'});
  const before=await page.locator('.sb-scroll').evaluate(el=>el.scrollTop);
  await page.getByRole('menuitem',{name:action==='rename'?'Rename':'Delete agent…',exact:true}).click();
  const dialog=page.getByRole('dialog');
  if(action==='rename') { await dialog.getByRole('textbox').fill('Renamed agent'); await dialog.getByRole('button',{name:'Save',exact:true}).click(); await expect(tree.getByRole('button',{name:'Renamed agent',exact:true})).toHaveCount(1); }
  else { await dialog.getByRole('button',{name:'Delete',exact:true}).click(); await expect(target).toHaveCount(0); }
  await expect(dialog).toHaveCount(0);
  await page.waitForTimeout(250);
  const after=await page.locator('.sb-scroll').evaluate(el=>el.scrollTop);
  expect(Math.abs(after-before)).toBeLessThan(2);
});

test('folder rename retains expanded descendants', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let root='reference';
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    if(path.endsWith('/file/transfer')) {root=req.postDataJSON().destination;return route.fulfill({json:{}});}
    const folder=url.searchParams.get('path')??'';
    const entries=folder===''?[{name:root,kind:'dir'}]:folder===root?[{name:'nested',kind:'dir'}]:folder===`${root}/nested`?[{name:'notes.md',kind:'file'}]:[];
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'}]}:path.endsWith('/files')?{entries}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'One',exact:true}).click();
  await page.getByRole('button',{name:'reference',exact:true}).click();
  await page.getByRole('button',{name:'nested',exact:true}).click();
  await expect(page.locator('[data-tree-id="pf:one:reference/nested/notes.md"]')).toBeVisible();
  await page.getByRole('button',{name:'reference',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Rename',exact:true}).click();
  await page.getByLabel('Folder name',{exact:true}).fill('Research');
  await page.getByRole('dialog').getByRole('button',{name:'Rename',exact:true}).click();
  await expect(page.locator('[data-tree-id="pf:one:Research/nested/notes.md"]')).toBeVisible();
  await expect(page.getByRole('button',{name:'nested',exact:true})).toHaveAttribute('aria-expanded','true');
  await expect(page.getByRole('button',{name:'reference',exact:true})).toHaveCount(0);
});


test('off-screen archived rows do not move the project viewport', async ({page}) => {
  await page.goto('/tests/sidebar-viewport.html');
  await page.locator('.sb-scroll').evaluate(el=>{el.scrollTop=600;});
  const before=await page.locator('.sb-scroll').evaluate(el=>el.scrollTop);
  await page.getByRole('button',{name:'Remove archived row',exact:true}).click();
  await expect(page.getByRole('button',{name:'archive0',exact:true})).toHaveCount(0);
  await page.waitForTimeout(100);
  expect(await page.locator('.sb-scroll').evaluate(el=>el.scrollTop)).toBe(before);
});


test('project updates above the viewport preserve visible archived rows', async ({page}) => {
  await page.goto('/tests/sidebar-viewport.html');
  await page.locator('.sb-scroll').evaluate(el=>{el.scrollTop=2100;});
  const row=page.getByRole('button',{name:'archive8',exact:true});
  const before=await row.evaluate(el=>el.getBoundingClientRect().top);
  await page.getByRole('button',{name:'Remove project row',exact:true}).click();
  await expect(page.getByRole('button',{name:'project0',exact:true})).toHaveCount(0);
  await page.waitForTimeout(100);
  expect(await row.evaluate(el=>el.getBoundingClientRect().top)).toBe(before);
});
