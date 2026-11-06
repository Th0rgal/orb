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
  if(action==='rename') {
    await expect(dialog.getByRole('textbox')).toHaveValue('Agent 35');
    await page.keyboard.press('Escape');
    await expect(dialog).toHaveCount(0);
    await expect(target).toBeFocused();
    await target.click({button:'right'});
    await page.getByRole('menuitem',{name:'Rename',exact:true}).click();
  }
  if(action==='rename') { await dialog.getByRole('textbox').fill('Renamed agent'); await dialog.getByRole('button',{name:'Rename',exact:true}).click(); await expect(tree.getByRole('button',{name:'Renamed agent',exact:true})).toHaveCount(1); }
  else { await dialog.getByRole('button',{name:'Delete',exact:true}).click(); await expect(target).toHaveCount(0); }
  await expect(dialog).toHaveCount(0);
  await page.waitForTimeout(250);
  const after=await page.locator('.sb-scroll').evaluate(el=>el.scrollTop);
  expect(Math.abs(after-before)).toBeLessThan(2);
});

test('folder rename retains expanded descendants and surfaces work migration errors', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let root='reference';
  let failCronMove=false;
  let holdNextTransfer=false;
  let pendingTransfer: (() => void) | null = null;
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    if(path.endsWith('/file/transfer')) {
      if (holdNextTransfer) {
        holdNextTransfer=false;
        await new Promise<void>(resolve=>{pendingTransfer=resolve;});
        pendingTransfer=null;
      }
      root=req.postDataJSON().destination;
      return route.fulfill({json:{}});
    }
    if(req.method()==='GET' && path.endsWith('/file')) {
      const requested=url.searchParams.get('path')??'';
      if(requested===`${root}/nested/notes.md`) return route.fulfill({json:{content:'# Audit notes',revision:1}});
      return route.fulfill({status:404,body:'file not found'});
    }
    if(req.method()==='PATCH' && path.includes('/crons/')) {
      if(failCronMove) return route.fulfill({status:500,body:'scheduler busy'});
      return route.fulfill({json:{slug:'one',job:{id:'job-1',name:'Nightly audit',schedule:'every 1h',enabled:true,failure_streak:0,folder:root},runs:[]}});
    }
    const folder=url.searchParams.get('path')??'';
    const entries=folder===''?[{name:root,kind:'dir'}]:folder===root?[{name:'nested',kind:'dir'}]:folder===`${root}/nested`?[{name:'notes.md',kind:'file'}]:[];
    const jobs=failCronMove?[{id:'job-1',name:'Nightly audit',schedule:'every 1h',enabled:true,failure_streak:0,folder:'Research'}]:[];
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'}]}:path.endsWith('/files')?{entries}:path.endsWith('/crons')?{jobs}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'One',exact:true}).click();
  await page.getByRole('button',{name:'reference',exact:true}).click();
  await page.getByRole('button',{name:'nested',exact:true}).click();
  const noteRow=page.locator('[data-tree-id="pf:one:reference/nested/notes.md"]');
  await expect(noteRow).toBeVisible();
  await noteRow.getByRole('button',{name:'notes.md',exact:true}).click();
  await page.getByRole('button',{name:'Edit',exact:true}).click();
  await expect(page.locator('.pf-path')).toHaveText('one/reference/nested/notes.md');

  // Gate the transfer so renaming while editing does not read the destination before the server moves it.
  holdNextTransfer=true;
  await page.getByRole('button',{name:'reference',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Rename',exact:true}).click();
  await page.getByLabel('Folder name',{exact:true}).fill('Research');
  await page.getByRole('dialog').getByRole('button',{name:'Rename',exact:true}).click();
  await expect(page.locator('[data-tree-id="pf:one:Research/nested/notes.md"]')).toBeVisible();
  await expect.poll(()=>pendingTransfer!==null).toBe(true);
  // While the folder move is still unsettled, mutating its optimistic destination is disabled.
  await page.getByRole('button',{name:'Research',exact:true}).click({button:'right'});
  await expect(page.getByRole('menuitem',{name:'Rename',exact:true})).toBeDisabled();
  await page.keyboard.press('Escape');
  pendingTransfer!();
  await expect(page.locator('.pf-path')).toHaveText('one/Research/nested/notes.md');
  await expect(page.locator('.file-view .error-notice')).toHaveCount(0);
  await expect(page.getByRole('button',{name:'nested',exact:true})).toHaveAttribute('aria-expanded','true');
  await expect(page.getByRole('button',{name:'reference',exact:true})).toHaveCount(0);

  failCronMove=true;
  await page.getByRole('button',{name:'Research',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Rename',exact:true}).click();
  await page.getByLabel('Folder name',{exact:true}).fill('Archive');
  await page.getByRole('dialog').getByRole('button',{name:'Rename',exact:true}).click();
  await expect(page.getByRole('alert')).toContainText('Nightly audit');
  await expect(page.getByRole('alert')).toContainText('could not follow');
});

test('folder delete dismisses dialog immediately and rolls back cleanly on failure', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let folders=['Audits','Notes'];
  let pendingDelete: (() => void) | null = null;
  let failNextDelete=true;
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    if(req.method()==='DELETE' && path.endsWith('/file')) {
      const target=url.searchParams.get('path')??'';
      await new Promise<void>(resolve=>{pendingDelete=resolve;});
      pendingDelete=null;
      if(failNextDelete) {
        failNextDelete=false;
        return route.fulfill({status:400,body:'This folder contains files that are not part of the project context'});
      }
      folders=folders.filter(f=>f!==target);
      return route.fulfill({json:{deleted:target}});
    }
    if(req.method()==='GET' && path.endsWith('/file')) {
      return route.fulfill({json:{content:'Initial report',revision:1}});
    }
    if(req.method()==='PUT' && path.endsWith('/file')) {
      return route.fulfill({status:500,body:'disk full'});
    }
    const folder=url.searchParams.get('path')??'';
    const entries=folder===''?folders.map(name=>({name,kind:'dir'})):[{name:'report.md',kind:'file'}];
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'}]}:path.endsWith('/files')?{entries}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'One',exact:true}).click();
  await expect(page.getByRole('button',{name:'Audits',exact:true})).toBeVisible();
  await page.getByRole('button',{name:'Audits',exact:true}).click();
  await page.locator('[data-tree-id="pf:one:Audits/report.md"]').getByRole('button',{name:'report.md',exact:true}).click();
  await page.getByRole('button',{name:'Edit',exact:true}).click();
  await page.locator('.file-view textarea').fill('Unsaved offline draft');

  await page.getByRole('button',{name:'Audits',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Delete…',exact:true}).click();
  const dialog=page.getByRole('dialog');
  await expect(dialog).toContainText('Delete folder?');
  await dialog.getByRole('button',{name:'Delete',exact:true}).click();

  // Dialog closes and folder disappears immediately while DELETE is still in flight.
  await expect(dialog).toHaveCount(0);
  await expect(page.getByRole('button',{name:'Audits',exact:true})).toHaveCount(0);
  await expect.poll(()=>pendingDelete!==null).toBe(true);

  // When DELETE fails, folder reappears in place, the open draft stays mounted, and an error toast explains why.
  pendingDelete!();
  await expect(page.getByRole('button',{name:'Audits',exact:true})).toBeVisible();
  await expect(page.locator('.file-view textarea')).toHaveValue('Unsaved offline draft');
  await expect(page.getByRole('alert').filter({hasText:'Couldn’t delete Audits'})).toBeVisible();

  // Second attempt succeeds optimistically, closes the deleted document on completion, and stays gone.
  await page.getByRole('button',{name:'Audits',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Delete…',exact:true}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect(page.getByRole('button',{name:'Audits',exact:true})).toHaveCount(0);
  await expect.poll(()=>pendingDelete!==null).toBe(true);
  pendingDelete!();
  await expect(page.locator('.pf-path')).toHaveCount(0);
  await expect(page.getByRole('button',{name:'Audits',exact:true})).toHaveCount(0);
  await expect(page.getByRole('button',{name:'Notes',exact:true})).toBeVisible();
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


test('moving the visible anchor to another tree preserves its neighbors', async ({page}) => {
  await page.goto('/tests/sidebar-viewport.html');
  await page.locator('.sb-scroll').evaluate(el=>{el.scrollTop=600;});
  const row=page.getByRole('button',{name:'project19',exact:true});
  const before=await row.evaluate(el=>el.getBoundingClientRect().top);
  await page.getByRole('button',{name:'Archive visible project',exact:true}).click();
  await expect(page.getByRole('tree',{name:'Archived',exact:true}).getByRole('button',{name:'project18',exact:true})).toHaveCount(1);
  await page.waitForTimeout(100);
  expect(await row.evaluate(el=>el.getBoundingClientRect().top)).toBe(before);
});
