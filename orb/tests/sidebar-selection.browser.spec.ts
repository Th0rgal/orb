import {test, expect} from '@playwright/test';
test.use({browserName:'webkit'});
for (const action of ['delete', 'move'] as const) test(`sidebar range/toggle selection and batch ${action}`, async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions = Array.from({length:4},(_,i)=>({id:`00000000-0000-0000-0000-00000000000${i}`,title:`Agent ${i}`,status:i === 0 || i === 2 ? 'awaiting_user' : 'failed',project:'one',tags:[],history:[],updated_at:`2026-09-2${5-i}`}));
  const writes: string[]=[];
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    const id=path.split('/')[4];
    if(req.method()==='DELETE') {
      writes.push(id);
      if(id.endsWith('2')) return route.fulfill({status:409,body:'Agent is busy'});
      missions=missions.filter(m=>m.id!==id);return route.fulfill({json:{ok:true}});
    }
    if(req.method()==='POST' && path.endsWith('/project')) {
      writes.push(id); const body=req.postDataJSON();missions=missions.map(m=>m.id===id?{...m,project:body.project,tags:body.tags}:m);
      return route.fulfill({json:{ok:true}});
    }
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'},{slug:'two',title:'Two'}]}
      :path==='/api/control/missions'?missions.filter(m=>!url.searchParams.has('project')||m.project===url.searchParams.get('project'))
      :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
      :path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'One',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  const row=(i:number)=>tree.getByRole('button',{name:`Agent ${i}`,exact:true});
  await row(0).click();await row(2).click({modifiers:['Shift']});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(3);
  await row(1).click({modifiers:['Meta']});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(2);
  await row(2).click({button:'right'});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(2);
  if(action==='delete') {
    await page.getByRole('menuitem',{name:'Delete 2 agents…'}).click();
    await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
    await expect.poll(()=>writes.length).toBe(2);await expect(row(0)).toHaveCount(0);await expect(row(2)).toBeVisible();
    await expect(page.getByText(/Couldn’t delete 1 agent/)).toBeVisible();
  } else {
    await page.getByRole('menuitem',{name:'Move 2 agents',exact:true}).click();
    await page.getByRole('button',{name:'Two',exact:true}).click({button:'right'});
    await page.getByRole('menuitem',{name:'Move 2 agents here',exact:true}).click();
    await expect.poll(()=>writes.length).toBe(2);
    expect(missions.filter(m=>m.project==='two').map(m=>m.title)).toEqual(['Agent 0','Agent 2']);
  }
});

for (const missingAt of ['GET', 'DELETE', 'cascade'] as const) test(`deletion clears an open mission and history (${missingAt})`, async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  const id='00000000-0000-0000-0000-000000000009';
  const child='00000000-0000-0000-0000-000000000008';
  let deleting=false, removed=false;
  const mission={id,title:'Open agent',status:'failed',project:'one',history:[],tags:[],updated_at:'2026-09-25'};
  const parent={...mission,id:child,title:'Parent agent'};
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    if(path===`/api/control/missions/${id}` && deleting && missingAt==='GET') {
      removed=true;return route.fulfill({status:404,body:`Mission ${id} not found`});
    }
    if(req.method()==='DELETE') {
      removed=true;
      return missingAt==='DELETE'?route.fulfill({status:404,body:`Mission ${id} not found`}):route.fulfill({json:{deleted_ids:[child,id]}});
    }
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'}]}
      :path==='/api/control/missions'?(removed?[]:missingAt==='cascade'?[mission,parent]:[mission])
      :path===`/api/control/missions/${id}`?mission:path===`/api/control/missions/${child}`?parent
      :path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'One',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  const row=tree.getByRole('button',{name:'Open agent',exact:true});await row.click();
  await expect.poll(()=>page.evaluate(()=>localStorage.getItem('orb.selectedConversation'))).toBe(`m:${id}`);
  const target=missingAt==='cascade'?tree.getByRole('button',{name:'Parent agent',exact:true}):row;
  await target.click({button:'right'});await page.getByRole('menuitem',{name:'Delete agent…'}).click();
  deleting=true;
  await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
  await expect.poll(()=>page.evaluate(()=>localStorage.getItem('orb.selectedConversation'))).toBe('');
  await expect(row).toHaveCount(0);
  await expect(page.getByText(/Couldn’t delete/)).toHaveCount(0);
  // Every navigation entry pointing at the deleted mission was cleared.
  await page.keyboard.press('Meta+[');
  await expect.poll(()=>page.evaluate(()=>localStorage.getItem('orb.selectedConversation'))).not.toBe(`m:${id}`);
});

test('cron and mixed file/folder/cron selection supports Cmd/Shift click, Cmd+X/V and right-click Move/Paste with careful context menu options', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  await page.evaluate(() => {
    let text = '';
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
      writeText: async (value: string) => { text = value; }, readText: async () => text,
    } });
  });
  let crons: Record<string, any[]> = {
    one: [
      {id:'cron-1',name:'Nightly Sweep',schedule:'every 1h',enabled:true,failure_streak:0,folder:''},
      {id:'cron-2',name:'Hourly Audit',schedule:'every 1h',enabled:true,failure_streak:0,folder:''},
    ],
    two: [],
  };
  const files = new Map<string, {kind: 'file'|'dir'; content?: string}>([
    ['one:notes.md', {kind:'file', content:'hello'}],
    ['one:docs', {kind:'dir'}],
    ['two:archive', {kind:'dir'}],
  ]);
  const cronUpdates: any[] = [];
  const fileTransfers: any[] = [];
  await page.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path === '/api/projects') return route.fulfill({json:{projects:[{slug:'one',title:'One'},{slug:'two',title:'Two'}]}});
    if (path === '/api/control/missions') return route.fulfill({json:[]});
    if (path.endsWith('/controller')) return route.fulfill({json:{job:null,runs:[]}});
    const cronMatch = path.match(/^\/api\/projects\/([^/]+)\/crons(?:\/([^/]+))?$/);
    if (cronMatch) {
      const [, slug, id] = cronMatch;
      if (req.method() === 'GET' && !id) return route.fulfill({json:{jobs: crons[slug] ?? []}});
      if (req.method() === 'PATCH' && id) {
        const body = req.postDataJSON();
        cronUpdates.push({slug, id, body});
        const job = (crons[slug] ?? []).find(j => j.id === id);
        if (job) {
          const targetSlug = body.project || slug;
          const updated = {...job, folder: body.folder ?? job.folder};
          if (targetSlug !== slug) {
            crons[slug] = (crons[slug] ?? []).filter(j => j.id !== id);
            crons[targetSlug] = [...(crons[targetSlug] ?? []), updated];
          } else {
            crons[slug] = (crons[slug] ?? []).map(j => j.id === id ? updated : j);
          }
          return route.fulfill({json:{slug:targetSlug,job:updated,runs:[]}});
        }
      }
    }
    const filesMatch = path.match(/^\/api\/projects\/([^/]+)\/files$/);
    if (filesMatch) {
      const [, slug] = filesMatch;
      const dir = url.searchParams.get('path') ?? '';
      const entries: any[] = [];
      for (const [key, val] of files) {
        if (!key.startsWith(`${slug}:`)) continue;
        const p = key.slice(slug.length + 1);
        const parent = p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '';
        if (parent === dir) entries.push({name: p.split('/').at(-1), kind: val.kind});
      }
      return route.fulfill({json:{entries}});
    }
    const transferMatch = path.match(/^\/api\/projects\/([^/]+)\/file\/transfer(?:\/([^/]+))?$/);
    if (transferMatch) {
      const [, fromSlug, toSlugParam] = transferMatch;
      const toSlug = toSlugParam || fromSlug;
      const body = req.postDataJSON();
      fileTransfers.push({fromSlug, toSlug, ...body});
      const oldPrefix = `${fromSlug}:${body.path}`;
      const newPrefix = `${toSlug}:${body.destination}`;
      for (const [k, v] of [...files.entries()]) {
        if (k === oldPrefix || k.startsWith(`${oldPrefix}/`)) {
          files.set(newPrefix + k.slice(oldPrefix.length), v);
          if (!body.copy) files.delete(k);
        }
      }
      return route.fulfill({json:{path:body.destination}});
    }
    if (path.endsWith('/file')) return route.fulfill({json:{content:'hello',revision:1}});
    await route.fulfill({json:{}});
  });

  await page.goto('/');
  await page.evaluate(() => {
    let text = '';
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
      writeText: async (value: string) => { text = value; }, readText: async () => text,
    } });
  });
  await page.getByRole('button',{name:'One',exact:true}).click();
  await page.getByRole('button',{name:'Two',exact:true}).click();
  const tree = page.getByRole('tree',{name:'Projects',exact:true});
  const shortcut = process.platform === 'darwin' ? 'Meta' : 'Control';

  // 1. Single cron right-click Move + right-click Paste into folder
  const cron1 = tree.getByRole('button',{name:'Nightly Sweep',exact:true});
  await cron1.click({button:'right'});
  await expect(page.getByRole('menuitem')).toHaveText(['Move', 'Delete…']);
  await page.getByRole('menuitem',{name:'Move',exact:true}).click();
  await expect(cron1).toHaveClass(/mission-cut/);

  const docsFolder = tree.locator('.row.folder').filter({hasText:'docs'});
  await docsFolder.click({button:'right'});
  await page.getByRole('menuitem',{name:'Paste',exact:true}).click();
  await expect.poll(() => cronUpdates.length).toBe(1);
  expect(cronUpdates[0]).toEqual({slug:'one', id:'cron-1', body:{folder:'docs'}});

  // 2. Multi-select files + folders (without crons): right-click shows Move N items and Copy N items (no Rename/Delete)
  const notesFile = tree.locator('.row.file').filter({hasText:'notes.md'});
  await notesFile.click();
  await docsFolder.locator('.row-main').click({modifiers:[shortcut]});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(2);
  await notesFile.click({button:'right'});
  await expect(page.getByRole('menuitem')).toHaveText(['Move 2 items', 'Copy 2 items']);

  // 3. Add a cron to the selection (mixed file + folder + cron): Copy is hidden, only Move 3 items is shown!
  const cron2 = tree.getByRole('button',{name:'Hourly Audit',exact:true});
  await cron2.click({modifiers:[shortcut]});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(3);
  await cron2.click({button:'right'});
  await expect(page.getByRole('menuitem')).toHaveText(['Move 3 items']);

  // 4. Use Cmd+X on the 3 selected items (file + folder + cron) and Cmd+V on Project Two's archive folder
  await page.keyboard.press('Escape');
  await cron2.click();
  await docsFolder.locator('.row-main').click({modifiers:['Shift']});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(3);
  await cron2.focus();
  await page.keyboard.press(`${shortcut}+x`);
  await expect(cron2).toHaveClass(/mission-cut/);
  await expect(notesFile).toHaveClass(/mission-cut/);

  // Right-click Paste into One/docs for cron2 + notesFile
  await page.keyboard.press('Escape');
  await cron2.click();
  await notesFile.click({modifiers:[shortcut]});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(2);
  await cron2.click({button:'right'});
  await page.getByRole('menuitem',{name:'Move 2 items',exact:true}).click();
  await docsFolder.click({button:'right'});
  await page.getByRole('menuitem',{name:'Paste',exact:true}).click();
  await expect.poll(() => cronUpdates.length).toBe(2);
  await expect.poll(() => fileTransfers.length).toBe(1);
  expect(cronUpdates[1]).toEqual({slug:'one', id:'cron-2', body:{folder:'docs'}});
  expect(fileTransfers[0]).toEqual({fromSlug:'one', toSlug:'one', path:'notes.md', destination:'docs/notes.md', copy:false});
});

