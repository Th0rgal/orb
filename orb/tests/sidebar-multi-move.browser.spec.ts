import {test, expect, type Page} from '@playwright/test';
test.use({browserName:'webkit'});
const P='00000000-0000-0000-0000-0000000000a1', F='00000000-0000-0000-0000-0000000000a2', C='00000000-0000-0000-0000-0000000000a3';
type M={id:string;title:string;status:string;project:string;tags:string[];history:[];updated_at:string;parent_mission_id?:string};
async function setup(page:Page, opts:{failMove?:string; deleteRunning?:boolean; crossProject?:boolean; staleDetails?:boolean}={}) {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions:M[]=[
    {id:P,title:'Pareto',status:'completed',project:'verity',tags:[],history:[],updated_at:'2026-10-20T07:00:00Z'},
    {id:F,title:'Fredrik',status:'completed',project:'verity',tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'},
    {id:C,title:'Deep Audit',status:opts.deleteRunning?'active':'interrupted',project:'verity',tags:[],history:[],updated_at:'2026-10-20T05:00:00Z',parent_mission_id:P},
  ];
  const original=missions.map(m=>({...m}));
  const writes:string[]=[]; const cancels:string[]=[];
  let release:()=>void=()=>{}; const gate=new Promise<void>(r=>release=r);
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
    if(req.method()==='POST' && path.endsWith('/project')) {
      writes.push(id); await gate;
      if(id===opts.failMove) return route.fulfill({status:409,body:'Mission is locked'});
      const body=req.postDataJSON();
      missions=missions.map(m=>{
        if(m.id===id) return {...m,project:body.project,tags:body.tags};
        if(body.include_descendants && m.parent_mission_id===id) return {...m,project:body.project,tags:m.tags.filter((t:string)=>!t.startsWith('orb-folder:'))};
        return m;
      });
      return route.fulfill({json:{ok:true}});
    }
    if(req.method()==='POST' && path.endsWith('/cancel')) { cancels.push(id); missions=missions.map(m=>m.id===id?{...m,status:'interrupted'}:m); return route.fulfill({json:{ok:true}}); }
    if(req.method()==='DELETE') {
      if(missions.some(m=>m.parent_mission_id===id) && url.searchParams.get('include_descendants')!=='true') return route.fulfill({status:409,body:'Mission has 1 descendant session'});
      const running=missions.find(m=>m.parent_mission_id===id&&m.status==='active');
      if(running) return route.fulfill({status:409,body:`Cannot delete a running mission or worker (${running.id}). Cancel it first.`});
      const gone=[id,...missions.filter(m=>m.parent_mission_id===id).map(m=>m.id)];
      missions=missions.filter(m=>!gone.includes(m.id)); return route.fulfill({json:{deleted_ids:gone}});
    }
    const json=path==='/api/projects'?{projects:[{slug:'verity',title:'Verity'},...(opts.crossProject?[{slug:'other',title:'Other'}]:[])]}
      :path==='/api/control/missions'?missions.filter(m=>!url.searchParams.has('project')||m.project===url.searchParams.get('project'))
      :path.startsWith('/api/control/missions/')?(opts.staleDetails?original:missions).find(m=>m.id===id)??{}
      :path.endsWith('/files')?{entries:(url.searchParams.get('path')??'')===''?[{name:'Audits',kind:'dir'}]:[]}
      :path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'Verity',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  return {tree,writes,cancels,release,missions:()=>missions};
}
async function moveBoth(page:Page, tree:ReturnType<Page['getByRole']>) {
  await tree.getByRole('button',{name:'Pareto',exact:true}).click();
  await tree.getByRole('button',{name:'Fredrik',exact:true}).click({modifiers:['Meta']});
  await tree.getByRole('button',{name:'Fredrik',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Move 2 agents',exact:true}).click();
  await tree.getByRole('button',{name:'Audits',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Move 2 agents here',exact:true}).click();
}
// The tree is flat with aria-level: 2 = project root (Verity), 3 = inside Audits.
const folderOf=async(tree:ReturnType<Page['getByRole']>,title:string)=>{
  const item=tree.getByRole('treeitem').filter({has:tree.page().getByRole('button',{name:title,exact:true})});
  if(!await item.count()) return null;
  const level=await item.first().getAttribute('aria-level');
  return level==='3'?'Audits':level==='2'?'Verity':level;
};

test('multi-move into a subfolder moves every selected mission at once, children stay nested', async ({page}) => {
  const {tree,writes,release,missions}=await setup(page);
  await moveBoth(page,tree);
  // Both requests are in flight together and both rows are already in Audits, not grayed.
  await expect.poll(()=>writes.length).toBe(2);
  await expect.poll(()=>folderOf(tree,'Pareto')).toBe('Audits');
  await expect.poll(()=>folderOf(tree,'Fredrik')).toBe('Audits');
  await expect(tree.locator('.mission-cut')).toHaveCount(0);
  release();
  await expect.poll(()=>missions().filter(m=>m.tags.includes('orb-folder:Audits')).map(m=>m.title).sort()).toEqual(['Fredrik','Pareto']);
  // After the server confirms and lists refresh, both are still there and the child is not orphaned.
  await page.waitForTimeout(300);
  await expect(tree.getByRole('button',{name:'Pareto',exact:true})).toBeVisible();
  await expect(tree.getByRole('button',{name:'Fredrik',exact:true})).toBeVisible();
  await expect(tree.getByText('Empty folder')).toHaveCount(0);
  expect(await folderOf(tree,'Pareto')).toBe('Audits');
  expect(await folderOf(tree,'Fredrik')).toBe('Audits');
  // The child is still nested under Pareto, not an orphan at the project root.
  await expect(tree.getByRole('button',{name:'Show the 1 mission launched by Pareto'})).toBeVisible();
  await expect(tree.getByRole('button',{name:'Deep Audit',exact:true})).toHaveCount(0);
});

test('a failed move rolls back only that mission, with an inline error', async ({page}) => {
  const {tree,release}=await setup(page,{failMove:F});
  await moveBoth(page,tree);
  await expect.poll(()=>folderOf(tree,'Fredrik')).toBe('Audits');
  release();
  await expect(page.getByText(/Couldn.t move/).first()).toBeVisible();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect.poll(()=>folderOf(tree,'Fredrik')).toBe('Verity');
  expect(await folderOf(tree,'Pareto')).toBe('Audits');
});

test('deleting a mission with a running worker offers Stop and delete', async ({page}) => {
  const {tree,cancels,missions}=await setup(page,{deleteRunning:true});
  await tree.getByRole('button',{name:'Pareto',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:/^Delete/}).click();
  // The confirmation names the session that goes with it, flagged as running.
  await expect(page.getByRole('dialog')).toContainText('This also deletes 1 session: Deep Audit (running).');
  await page.getByRole('dialog').getByRole('button',{name:'Delete 2 sessions',exact:true}).click();
  const dialog=page.getByRole('dialog');
  await expect(dialog).toContainText('This also deletes 1 session: Deep Audit');
  await expect(dialog).toContainText('1 worker is still running');
  await dialog.getByRole('button',{name:'Stop and delete',exact:true}).click();
  await expect.poll(()=>cancels).toEqual([C]);
  await expect.poll(()=>missions().map(m=>m.title)).toEqual(['Fredrik']);
  await expect(tree.getByRole('button',{name:'Pareto',exact:true})).toHaveCount(0);
});

test('deleting a mission without children uses the plain wording and no cascade opt-in', async ({page}) => {
  const urls:string[]=[];
  page.on('request',r=>{ if(r.method()==='DELETE') urls.push(new URL(r.url()).search); });
  const {tree,missions}=await setup(page);
  await tree.getByRole('button',{name:'Fredrik',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:/^Delete/}).click();
  const dialog=page.getByRole('dialog');
  await expect(dialog).toContainText('Delete 1 agent?');
  await expect(dialog).not.toContainText('also deletes');
  await dialog.getByRole('button',{name:'Delete',exact:true}).click();
  await expect.poll(()=>missions().map(m=>m.title).sort()).toEqual(['Deep Audit','Pareto']);
  expect(urls).toEqual(['']);
});


test('Cmd+X/Cmd+V moves the open mission once across projects despite stale detail reads', async ({page}) => {
  await page.clock.install();
  const {tree,writes,release,missions}=await setup(page,{crossProject:true,staleDetails:true});
  const row=tree.getByRole('button',{name:'Pareto',exact:true});
  await row.click();
  await row.focus();await page.keyboard.press('Meta+x');
  await expect(tree.locator('.mission-cut')).toHaveCount(1);
  const destination=tree.getByRole('button',{name:'Other',exact:true});
  await destination.click();await destination.focus();await page.keyboard.press('Meta+v');
  await expect.poll(()=>writes).toEqual([P]); // single atomic root subtree write (no standalone child write)
  await expect(row).toHaveCount(1);
  await expect(tree.locator('.row.project.contains-current')).toHaveAttribute('data-drop-project','other');
  release();
  await expect.poll(()=>missions().find(m=>m.id===P)?.project).toBe('other');
  await expect.poll(()=>missions().find(m=>m.id===C)?.project).toBe('other');
  await expect(tree.locator('.mission-cut')).toHaveCount(0);
  await page.clock.fastForward(31_000);
  await expect(row).toHaveCount(1);
  await expect(tree.locator('.row.project.contains-current')).toHaveAttribute('data-drop-project','other');
  await expect(tree.getByRole('button',{name:'Show the 1 mission launched by Pareto'})).toHaveCount(1);
});

test('split cross-project subtree uses distinct placeholder keys and heals via macOS ClipboardEvent cut/paste onto a mission row', async ({page}) => {
  const C2='00000000-0000-0000-0000-0000000000a4', OTHER_M='00000000-0000-0000-0000-0000000000a5';
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions:M[]=[
    {id:P,title:'evm.fast',status:'active',project:'assistant',tags:[],history:[],updated_at:'2026-10-20T07:00:00Z'},
    {id:C,title:'Worker 1',status:'completed',project:'assistant',tags:[],history:[],updated_at:'2026-10-20T05:00:00Z',parent_mission_id:P},
    {id:C2,title:'Worker 2',status:'completed',project:'ethereum',tags:[],history:[],updated_at:'2026-10-20T05:30:00Z',parent_mission_id:P},
    {id:OTHER_M,title:'snark.fast',status:'completed',project:'ethereum',tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'},
  ];
  const bodies:Array<{id:string;body:Record<string,unknown>}>=[];
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
    if(req.method()==='POST' && path.endsWith('/project')) {
      const body=req.postDataJSON();
      bodies.push({id,body});
      missions=missions.map(m=>{
        if(m.id===id) return {...m,project:body.project,tags:body.tags};
        if(body.include_descendants && m.parent_mission_id===id) return {...m,project:body.project,tags:m.tags.filter(t=>!t.startsWith('orb-folder:'))};
        return m;
      });
      return route.fulfill({json:{ok:true}});
    }
    const json=path==='/api/projects'?{projects:[{slug:'assistant',title:'Assistant'},{slug:'ethereum',title:'Ethereum'}]}
      :path==='/api/control/missions'?missions.filter(m=>!url.searchParams.has('project')||m.project===url.searchParams.get('project'))
      :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
      :path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');
  await page.getByRole('button',{name:'Assistant',exact:true}).click();
  await page.getByRole('button',{name:'Ethereum',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  // Canonical row in Assistant and cross-project placeholder in Ethereum have distinct keys and do not double-highlight.
  await expect(tree.locator(`[data-tree-id="m:${P}"]`)).toHaveCount(1);
  await expect(tree.locator(`[data-tree-id="mp:ethereum:${P}"]`)).toHaveCount(1);
  const canonicalBtn=tree.locator(`[data-tree-id="m:${P}"] button.row.agent`);
  await canonicalBtn.click();
  await expect(tree.locator('button.row.agent.active')).toHaveCount(1);

  // Dispatch native macOS AppKit-style ClipboardEvent('cut') on canonical row, then ClipboardEvent('paste') on a mission row inside Ethereum.
  const cutPayload=await canonicalBtn.evaluate(el=>{
    const dt=new DataTransfer();
    const ev=new ClipboardEvent('cut',{bubbles:true,cancelable:true,clipboardData:dt});
    el.dispatchEvent(ev);
    return dt.getData('text/plain');
  });
  expect(cutPayload).toContain('orb:cut-mission:');
  await expect(tree.locator('.mission-cut')).toHaveCount(1);

  const ethRow=tree.getByRole('button',{name:'snark.fast',exact:true});
  await ethRow.evaluate((el,text)=>{
    const dt=new DataTransfer();
    dt.setData('text/plain',text);
    const ev=new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:dt});
    el.dispatchEvent(ev);
  },cutPayload);

  await expect.poll(()=>bodies.some(b=>b.id===P && b.body.project==='ethereum' && b.body.include_descendants===true)).toBe(true);
  await expect(tree.locator(`[data-tree-id="mp:ethereum:${P}"]`)).toHaveCount(0);
  await expect(tree.locator(`[data-tree-id="m:${P}"]`)).toHaveCount(1);
  await expect(tree.getByRole('button',{name:'Show the 2 missions launched by evm.fast'})).toBeVisible();
});

test('pointer drag-and-drop and right-click Move here on a destination mission row transfer across projects', async ({page}) => {
  const {tree,release,missions}=await setup(page,{crossProject:true});
  release();
  await tree.getByRole('button',{name:'Other',exact:true}).click();
  const fredrik=tree.getByRole('button',{name:'Fredrik',exact:true});
  const otherHeader=tree.getByRole('button',{name:'Other',exact:true});
  const srcBox=(await fredrik.boundingBox())!;
  const dstBox=(await otherHeader.boundingBox())!;

  await page.mouse.move(srcBox.x+20,srcBox.y+10);
  await page.mouse.down();
  await page.mouse.move(dstBox.x+20,dstBox.y+10,{steps:5});
  await expect(tree.locator('.row.project[data-drop-project="other"]')).toHaveClass(/drop-active/);
  await page.mouse.up();

  await expect.poll(()=>missions().find(m=>m.id===F)?.project).toBe('other');
  await expect(tree.locator('.row.project.drop-active')).toHaveCount(0);

  // Move Fredrik back to Verity by right-clicking Pareto (a mission row inside Verity) and choosing "Move here".
  await fredrik.click({button:'right'});
  await page.getByRole('menuitem',{name:'Move',exact:true}).click();
  await tree.getByRole('button',{name:'Pareto',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Move here',exact:true}).click();
  await expect.poll(()=>missions().find(m=>m.id===F)?.project).toBe('verity');
});
