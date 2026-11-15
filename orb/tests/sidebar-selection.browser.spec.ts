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
    if(req.method()==='POST' && path==='/api/control/missions/move') {
      const body=req.postDataJSON();
      const ids:string[]=body.mission_ids??[];
      writes.push(...ids);
      const moved=ids.map((mid:string)=>({mission_id:mid,project:body.project,folder:body.folder??'',placement_revision:2}));
      missions=missions.map(m=>ids.includes(m.id)?{...m,project:body.project,folder:body.folder??'',placement_revision:2}:m);
      return route.fulfill({json:{moved,client_op_id:body.client_op_id}});
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
    await expect.poll(()=>writes.length).toBe(2);
    await expect(page.getByRole("dialog")).toContainText("Couldn’t delete 1 agent");
    await page.getByRole("dialog").getByRole("button",{name:"Cancel",exact:true}).click();
    await expect(row(0)).toHaveCount(0);await expect(row(2)).toBeVisible();
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

test('file and folder selection supports keyboard cut and paste with context menu options', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  await page.evaluate(() => {
    let text = '';
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: {
      writeText: async (value: string) => { text = value; }, readText: async () => text,
    } });
  });
  const files = new Map<string, {kind: 'file'|'dir'; content?: string}>([
    ['one:notes.md', {kind:'file', content:'hello'}],
    ['one:docs', {kind:'dir'}],
    ['two:archive', {kind:'dir'}],
  ]);
  const fileTransfers: any[] = [];
  await page.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname;
    if (path === '/api/projects') return route.fulfill({json:{projects:[{slug:'one',title:'One'},{slug:'two',title:'Two'}]}});
    if (path === '/api/control/missions') return route.fulfill({json:[]});
    if (path.endsWith('/controller')) return route.fulfill({json:{job:null,runs:[]}});
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

  const docsFolder = tree.locator('.row.folder').filter({hasText:'docs'});
  const notesFile = tree.locator('.row.file').filter({hasText:'notes.md'});
  await notesFile.click();
  await docsFolder.locator('.row-main').click({modifiers:[shortcut]});
  await expect(tree.locator('[aria-selected="true"]')).toHaveCount(2);
  await notesFile.click({button:'right'});
  await expect(page.getByRole('menuitem')).toHaveText(['Move 2 items', 'Copy 2 items']);

  await page.keyboard.press('Escape');
  await notesFile.focus();
  await page.keyboard.press(`${shortcut}+x`);
  await expect(notesFile).toHaveClass(/mission-cut/);
  const destination = tree.locator('.row.folder').filter({hasText:'archive'});
  await destination.click({button:'right'});
  await page.getByRole('menuitem',{name:'Paste',exact:true}).click();
  await expect.poll(() => fileTransfers.length).toBe(2);
  expect(fileTransfers.map(transfer => transfer.path).sort()).toEqual(['docs', 'notes.md']);
});

test('right-clicking mission B to copy its ID while in mission A restores mission A as selected after the menu closes', async ({page}) => {
  await page.addInitScript(() => {
    localStorage.setItem('orb.apiUrl', location.origin);
    localStorage.setItem('orb.jwt', 'test');
    (window as any).__copied = [];
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: {
        writeText: async (value: string) => { (window as any).__copied.push(value); },
        readText: async () => (window as any).__copied.at(-1) ?? '',
      },
    });
  });
  const idA = '00000000-0000-0000-0000-0000000000aa';
  const idB = '00000000-0000-0000-0000-0000000000bb';
  const missions = [
    {id: idA, title: 'Whitesmith', status: 'active', project: 'one', tags: [], history: [], updated_at: '2026-10-30T10:00:00Z'},
    {id: idB, title: 'boost.ci', status: 'active', project: 'one', tags: [], history: [], updated_at: '2026-10-30T09:00:00Z'},
  ];
  await page.route('**/api/**', async route => {
    const req = route.request(), url = new URL(req.url()), path = url.pathname, id = path.split('/')[4];
    const json = path === '/api/projects' ? {projects: [{slug: 'one', title: 'One'}]}
      : path === '/api/control/missions' ? missions
      : path.startsWith('/api/control/missions/') ? missions.find(m => m.id === id) ?? {}
      : path.endsWith('/files') ? {entries: []} : path.endsWith('/crons') ? {jobs: []} : path.endsWith('/controller') ? {job: null, runs: []} : [];
    await route.fulfill({json});
  });

  await page.goto('/');
  await page.getByRole('button', {name: 'One', exact: true}).click();
  const tree = page.getByRole('tree', {name: 'Projects', exact: true});
  const rowA = tree.getByRole('button', {name: 'Whitesmith', exact: true});
  const rowB = tree.getByRole('button', {name: 'boost.ci', exact: true});
  const itemA = tree.locator(`[data-tree-id="m:${idA}"]`);
  const itemB = tree.locator(`[data-tree-id="m:${idB}"]`);

  // Open mission A: mission A is selected.
  await rowA.click();
  await expect(rowA).toHaveClass(/active/);
  await expect(rowB).not.toHaveClass(/active/);
  await expect(itemA).toHaveAttribute('aria-selected', 'true');
  await expect(itemB).toHaveAttribute('aria-selected', 'false');

  // Right-click mission B: mission B highlights while its context menu is open.
  await rowB.click({button: 'right'});
  await expect(page.getByRole('menu')).toBeVisible();
  await expect(rowB).toHaveClass(/active/);
  await expect(itemB).toHaveAttribute('aria-selected', 'true');

  // Copy mission ID: menu closes, ID is copied, and mission A is selected back.
  await page.getByRole('menuitem', {name: 'Copy mission ID', exact: true}).click();
  await expect(page.getByRole('menu')).toHaveCount(0);
  expect(await page.evaluate(() => (window as any).__copied)).toEqual([idB]);
  await expect(rowA).toHaveClass(/active/);
  await expect(rowB).not.toHaveClass(/active/);
  await expect(itemA).toHaveAttribute('aria-selected', 'true');
  await expect(itemB).toHaveAttribute('aria-selected', 'false');
  await expect.poll(() => page.evaluate(() => localStorage.getItem('orb.selectedConversation'))).toBe(`m:${idA}`);

  // Dismissing the context menu with Escape also restores mission A.
  await rowB.click({button: 'right'});
  await expect(rowB).toHaveClass(/active/);
  await page.keyboard.press('Escape');
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(rowA).toHaveClass(/active/);
  await expect(rowB).not.toHaveClass(/active/);
});
