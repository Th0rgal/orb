import {test, expect, type Page} from '@playwright/test';
import {eventPage} from './eventPageFixture';
test.use({browserName:'webkit'});
const P='00000000-0000-0000-0000-0000000000a1', F='00000000-0000-0000-0000-0000000000a2', C='00000000-0000-0000-0000-0000000000a3';
type M={id:string;title:string;status:string;project:string;folder?:string;placement_revision?:number;tags:string[];history:[];updated_at:string;parent_mission_id?:string};

async function setup(page:Page, opts:{failMove?:boolean; deleteRunning?:boolean; crossProject?:boolean; staleDetails?:boolean; requireApprovalConfirm?:boolean}={}) {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions:M[]=[
    {id:P,title:'Pareto',status:'completed',project:'verity',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T07:00:00Z'},
    {id:F,title:'Fredrik',status:'completed',project:'verity',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'},
    {id:C,title:'Deep Audit',status:opts.deleteRunning?'active':'interrupted',project:'verity',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T05:00:00Z',parent_mission_id:P},
  ];
  const original=missions.map(m=>({...m}));
  const writes:Array<{mission_ids:string[];project?:string;folder?:string;approval_policy?:string}>=[];
  const cancels:string[]=[];
  let release:()=>void=()=>{}; const gate=new Promise<void>(r=>release=r);
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
    if(req.method()==='POST' && path==='/api/control/missions/move') {
      const body=req.postDataJSON();
      writes.push(body);
      await gate;
      if(opts.failMove) return route.fulfill({status:409,body:'Mission is locked'});
      if(opts.requireApprovalConfirm && (!body.approval_policy || body.approval_policy==='check')) {
        return route.fulfill({
          status:409,
          contentType:'application/json',
          body:JSON.stringify({
            code:'approval_transfer_confirmation_required',
            error:'Moving across projects affects active secret approvals.',
            target_project:body.project ?? 'other',
            grants:[{id:'g1',mission_id:body.mission_ids[0],secret_name:'PROD_API_KEY',source_project:'verity',expires_at:'2026-12-01T00:00:00Z'}],
            pending_requests:[{id:'r1',mission_id:body.mission_ids[0],secret_name:'PROD_WRITE_TOKEN',operation:'write',source_project:'verity'}],
          }),
        });
      }
      const rootSet=new Set<string>(body.mission_ids ?? []);
      const moved:Array<{mission_id:string;project:string;folder:string;placement_revision:number}>=[];
      missions=missions.map(m=>{
        const isRoot=rootSet.has(m.id);
        const isChild=!!m.parent_mission_id && rootSet.has(m.parent_mission_id);
        if(!isRoot && !isChild) return m;
        const nextProj=body.project ?? m.project;
        const nextFolder=isRoot ? (body.folder ?? '') : '';
        const nextRev=(m.placement_revision ?? 0) + 1;
        moved.push({mission_id:m.id,project:nextProj,folder:nextFolder,placement_revision:nextRev});
        return {...m,project:nextProj,folder:nextFolder,placement_revision:nextRev};
      });
      return route.fulfill({json:{moved,client_op_id:body.client_op_id}});
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

test('multi-move into a subfolder sends a single atomic batch request, moves both immediately, and keeps children nested', async ({page}) => {
  const {tree,writes,release,missions}=await setup(page);
  await moveBoth(page,tree);
  // Single atomic batch request is in flight and both rows are already in Audits, not grayed.
  await expect.poll(()=>writes.length).toBe(1);
  expect(writes[0]?.mission_ids.sort()).toEqual([P,F].sort());
  expect(writes[0]?.folder).toBe('Audits');
  await expect.poll(()=>folderOf(tree,'Pareto')).toBe('Audits');
  await expect.poll(()=>folderOf(tree,'Fredrik')).toBe('Audits');
  await expect(tree.locator('.mission-cut')).toHaveCount(0);
  release();
  await expect.poll(()=>missions().filter(m=>m.folder==='Audits').map(m=>m.title).sort()).toEqual(['Fredrik','Pareto']);
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

test('a failed atomic batch move rolls back every selected mission together, with an inline error', async ({page}) => {
  const {tree,release}=await setup(page,{failMove:true});
  await moveBoth(page,tree);
  await expect.poll(()=>folderOf(tree,'Fredrik')).toBe('Audits');
  release();
  await expect(page.getByText(/Couldn.t move/).first()).toBeVisible();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect.poll(()=>folderOf(tree,'Fredrik')).toBe('Verity');
  expect(await folderOf(tree,'Pareto')).toBe('Verity');
});

test('cross-project move with active secret approvals prompts for confirmation and applies chosen policy', async ({page}) => {
  const {tree,writes,release,missions}=await setup(page,{crossProject:true,requireApprovalConfirm:true});
  release();
  const row=tree.getByRole('button',{name:'Pareto',exact:true});
  await row.click({button:'right'});
  await page.getByRole('menuitem',{name:'Move',exact:true}).click();
  await tree.getByRole('button',{name:'Other',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:'Move here',exact:true}).click();

  const dialog=page.getByRole('dialog');
  await expect(dialog).toContainText('Move with active secret approvals?');
  await expect(dialog).toContainText('PROD_API_KEY');
  await expect(dialog).toContainText('PROD_WRITE_TOKEN');
  await dialog.getByRole('button',{name:'Move & revoke approvals',exact:true}).click();

  await expect(dialog).toHaveCount(0);
  await expect.poll(()=>writes.length).toBe(2);
  expect(writes[0]?.approval_policy).toBe('check');
  expect(writes[1]?.approval_policy).toBe('revoke');
  await expect.poll(()=>missions().find(m=>m.id===P)?.project).toBe('other');
  await expect.poll(()=>missions().find(m=>m.id===C)?.project).toBe('other');
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
  await expect.poll(()=>writes.map(w=>w.mission_ids)).toEqual([[P]]);
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
    {id:P,title:'evm.fast',status:'active',project:'assistant',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T07:00:00Z'},
    {id:C,title:'Worker 1',status:'completed',project:'assistant',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T05:00:00Z',parent_mission_id:P},
    {id:C2,title:'Worker 2',status:'completed',project:'ethereum',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T05:30:00Z',parent_mission_id:P},
    {id:OTHER_M,title:'snark.fast',status:'completed',project:'ethereum',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'},
  ];
  const bodies:Array<Record<string,unknown>>=[];
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
    if(req.method()==='POST' && path==='/api/control/missions/move') {
      const body=req.postDataJSON();
      bodies.push(body);
      const rootSet=new Set<string>(body.mission_ids ?? []);
      const moved:Array<{mission_id:string;project:string;folder:string;placement_revision:number}>=[];
      missions=missions.map(m=>{
        const isRoot=rootSet.has(m.id);
        const isChild=!!m.parent_mission_id && rootSet.has(m.parent_mission_id);
        if(!isRoot && !isChild) return m;
        const nextRev=(m.placement_revision ?? 0) + 1;
        const nextFolder=isRoot ? (body.folder ?? '') : '';
        moved.push({mission_id:m.id,project:body.project,folder:nextFolder,placement_revision:nextRev});
        return {...m,project:body.project,folder:nextFolder,placement_revision:nextRev};
      });
      return route.fulfill({json:{moved,client_op_id:body.client_op_id}});
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

  await expect.poll(()=>bodies.some(b=>(b.mission_ids as string[])?.includes(P) && b.project==='ethereum')).toBe(true);
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

test('when system clipboard write is refused, paste prefers the active local cut over a stale system clipboard reference', async ({page}) => {
  await page.addInitScript(() => {
    localStorage.setItem('orb.apiUrl',location.origin);
    localStorage.setItem('orb.jwt','test');
    Object.defineProperty(navigator,'clipboard',{
      configurable:true,
      value:{writeText:async()=>{throw new DOMException('Refused','NotAllowedError');}},
    });
  });
  let filesByProject:Record<string,string[]>={verity:['a.md','b.md'],other:[]};
  const transfers:Array<{from:string;to:string;path:string;destination:string}>=[];
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    if(req.method()==='POST' && path.includes('/file/transfer')) {
      const parts=path.split('/'),from=parts[3],to=parts[6]??from,body=req.postDataJSON();
      transfers.push({from,to,path:body.path,destination:body.destination});
      filesByProject[from]=(filesByProject[from]??[]).filter(f=>f!==body.path);
      filesByProject[to]=[...(filesByProject[to]??[]),body.destination];
      return route.fulfill({json:{ok:true}});
    }
    const slug=path.split('/')[3];
    const json=path==='/api/projects'?{projects:[{slug:'verity',title:'Verity'},{slug:'other',title:'Other'}]}
      :path==='/api/control/missions'?[]
      :path.endsWith('/files')?{entries:((url.searchParams.get('path')??'')===''?(filesByProject[slug]??[]).map(name=>({name,kind:'file'})):[])}
      :path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');
  await page.getByRole('button',{name:'Verity',exact:true}).click();
  await page.getByRole('button',{name:'Other',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});

  // Cut a.md via native ClipboardEvent('cut') so the system clipboard receives a valid reference to a.md.
  const fileABtn=tree.locator('[data-tree-id="pf:verity:a.md"] button.row');
  const staleSystemPayload=await fileABtn.evaluate(el=>{
    const dt=new DataTransfer();
    el.dispatchEvent(new ClipboardEvent('cut',{bubbles:true,cancelable:true,clipboardData:dt}));
    return dt.getData('text/plain');
  });
  expect(staleSystemPayload).toContain('orb:file:');

  // Now cut b.md from the context menu; navigator.clipboard.writeText rejects, leaving staleSystemPayload in the OS clipboard.
  await tree.locator('[data-tree-id="pf:verity:b.md"] button.row').click({button:'right'});
  await page.getByRole('menuitem',{name:'Cut',exact:true}).click();

  // Paste onto Other using a native ClipboardEvent carrying the stale a.md payload: b.md must move, not a.md.
  const otherBtn=tree.getByRole('button',{name:'Other',exact:true});
  const dispatchPaste=async()=>otherBtn.evaluate((el,text)=>{
    const dt=new DataTransfer();
    dt.setData('text/plain',text);
    el.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:dt}));
  },staleSystemPayload);

  await dispatchPaste();
  await expect.poll(()=>transfers).toEqual([{from:'verity',to:'other',path:'b.md',destination:'b.md'}]);

  // A second paste with the still-stale OS clipboard payload must not resurrect the superseded a.md cut.
  await dispatchPaste();
  await page.waitForTimeout(150);
  expect(transfers).toEqual([{from:'verity',to:'other',path:'b.md',destination:'b.md'}]);
});

test('deleting a parent with unloaded server-side descendants or paused child recovers cleanly without pre-DELETE transcript GETs', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  const HIDDEN_PAUSED='00000000-0000-0000-0000-0000000000a9';
  let visible=[{id:F,title:'Fredrik',status:'completed',project:'verity',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'}];
  let hiddenPaused=true;
  const transcriptGets:string[]=[];
  const deleteSearches:string[]=[];
  const acknowledged:string[]=[];
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
    if(req.method()==='GET' && /^\/api\/control\/missions\/[^/]+$/.test(path)) {
      transcriptGets.push(id);
      return route.fulfill({json:visible.find(m=>m.id===id)??{}});
    }
    if(req.method()==='POST' && path.endsWith('/status')) {
      acknowledged.push(id);
      if(id===HIDDEN_PAUSED) hiddenPaused=false;
      return route.fulfill({json:{ok:true}});
    }
    if(req.method()==='DELETE') {
      deleteSearches.push(url.search);
      if(url.searchParams.get('include_descendants')!=='true') {
        return route.fulfill({status:409,body:`Mission ${id} has 1 descendant sessions: hidden (paused). Pass ?include_descendants=true to delete them with it.`});
      }
      if(hiddenPaused) {
        return route.fulfill({status:409,body:`Cannot delete a paused mission (${HIDDEN_PAUSED}). Resume or cancel it first.`});
      }
      visible=[];
      return route.fulfill({json:{deleted_ids:[HIDDEN_PAUSED,id]}});
    }
    const json=path==='/api/projects'?{projects:[{slug:'verity',title:'Verity'}]}
      :path==='/api/control/missions'?visible
      :path.endsWith('/files')?{entries:[]}
      :path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'Verity',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  await tree.getByRole('button',{name:'Fredrik',exact:true}).click({button:'right'});
  await page.getByRole('menuitem',{name:/^Delete/}).click();
  const dialog=page.getByRole('dialog');
  await dialog.getByRole('button',{name:'Delete',exact:true}).click();
  // First attempt had unloaded descendants on the server: modal surfaces the refusal and remembers confirmation.
  await expect(dialog).toContainText('1 descendant sessions');
  await dialog.getByRole('button',{name:'Delete',exact:true}).click();
  // Retry passes ?include_descendants=true, auto-acknowledges the hidden paused child, and completes deletion.
  await expect(dialog).toHaveCount(0);
  expect(transcriptGets).toEqual([]);
  expect(acknowledged).toEqual([HIDDEN_PAUSED]);
  expect(deleteSearches).toEqual(['','?include_descendants=true','?include_descendants=true']);
  await expect(tree.getByRole('button',{name:'Fredrik',exact:true})).toHaveCount(0);
});

test('long-press lifts row, spring-loads collapsed project on 450ms dwell, opens Move to picker on hold-release without stealing selection, and moves folders with missions and crons across projects', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions:M[]=[
    {id:P,title:'Pareto',status:'completed',project:'verity',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T09:00:00Z'},
    {id:F,title:'Fredrik',status:'completed',project:'verity',folder:'',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'},
    {id:C,title:'Nested Agent',status:'completed',project:'verity',folder:'Specs',placement_revision:1,tags:[],history:[],updated_at:'2026-10-20T05:00:00Z'},
  ];
  let dirs:Record<string,Array<{name:string;kind:'file'|'dir'}>>={
    'verity:':[{name:'Specs',kind:'dir'}],
    'verity:Specs':[{name:'plan.md',kind:'file'}],
    'other:':[{name:'Archive',kind:'dir'}],
    'other:Archive':[],
  };
  let crons:Record<string,Array<{id:string;name:string;schedule:string;enabled:boolean;failure_streak:number;folder?:string}>>={
    verity:[{id:'cron-1',name:'Nightly Spec Check',schedule:'every 1h',enabled:true,failure_streak:0,folder:'Specs'}],
    other:[],
  };
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname;
    if(req.method()==='POST' && path==='/api/control/missions/move') {
      const body=req.postDataJSON();
      const rootSet=new Set<string>(body.mission_ids ?? []);
      const moved:Array<{mission_id:string;project:string;folder:string;placement_revision:number}>=[];
      missions=missions.map(m=>{
        const isRoot=rootSet.has(m.id);
        const isChild=!!m.parent_mission_id && rootSet.has(m.parent_mission_id);
        if(!isRoot && !isChild) return m;
        const nextProj=body.project ?? m.project;
        const nextFolder=isRoot ? (body.folder ?? '') : '';
        const nextRev=(m.placement_revision ?? 0) + 1;
        moved.push({mission_id:m.id,project:nextProj,folder:nextFolder,placement_revision:nextRev});
        return {...m,project:nextProj,folder:nextFolder,placement_revision:nextRev};
      });
      return route.fulfill({json:{moved,client_op_id:body.client_op_id}});
    }
    if(req.method()==='POST' && path.includes('/file/transfer')) {
      const parts=path.split('/'),from=parts[3],to=parts[6]??from,body=req.postDataJSON();
      const fromParent=body.path.includes('/')?body.path.slice(0,body.path.lastIndexOf('/')):'';
      const base=body.path.includes('/')?body.path.slice(body.path.lastIndexOf('/')+1):body.path;
      const moved=(dirs[`${from}:${fromParent}`]??[]).find(e=>e.name===base)??{name:base,kind:'dir' as const};
      dirs[`${from}:${fromParent}`]=(dirs[`${from}:${fromParent}`]??[]).filter(e=>e.name!==base);
      const toParent=body.destination.includes('/')?body.destination.slice(0,body.destination.lastIndexOf('/')):'';
      const toBase=body.destination.includes('/')?body.destination.slice(body.destination.lastIndexOf('/')+1):body.destination;
      dirs[`${to}:${toParent}`]=[...(dirs[`${to}:${toParent}`]??[]),{name:toBase,kind:moved.kind}];
      if(moved.kind==='dir' && dirs[`${from}:${body.path}`]) {
        dirs[`${to}:${body.destination}`]=dirs[`${from}:${body.path}`];
        delete dirs[`${from}:${body.path}`];
      }
      return route.fulfill({json:{path:body.destination}});
    }
    if(req.method()==='PATCH' && path.includes('/crons/')) {
      const parts=path.split('/'),from=parts[3],cronId=parts[5],body=req.postDataJSON();
      const target=body.project??from;
      const existing=(crons[from]??[]).find(j=>j.id===cronId)??{id:cronId,name:'Nightly Spec Check',schedule:'every 1h',enabled:true,failure_streak:0};
      const updated={...existing,folder:body.folder??existing.folder};
      if(target!==from) {
        crons[from]=(crons[from]??[]).filter(j=>j.id!==cronId);
        crons[target]=[...(crons[target]??[]),updated];
      } else {
        crons[from]=(crons[from]??[]).map(j=>j.id===cronId?updated:j);
      }
      return route.fulfill({json:{slug:target,job:updated,runs:[]}});
    }
    if(path==='/api/projects') return route.fulfill({json:{projects:[{slug:'verity',title:'Verity'},{slug:'other',title:'Other'}]}});
    if(path==='/api/control/missions') {
      const proj=url.searchParams.get('project');
      return route.fulfill({json:missions.filter(m=>!proj||m.project===proj)});
    }
    if(path.startsWith('/api/control/missions/')) {
      const id=path.split('/')[4];
      return route.fulfill({json:missions.find(m=>m.id===id)??{}});
    }
    const slug=path.split('/')[3];
    if(path.endsWith('/files')) return route.fulfill({json:{entries:dirs[`${slug}:${url.searchParams.get('path')??''}`]??[]}});
    if(path.endsWith('/crons')) return route.fulfill({json:{jobs:crons[slug]??[]}});
    if(path.endsWith('/controller')) return route.fulfill({json:{job:null,runs:[]}});
    return route.fulfill({json:[]});
  });

  await page.goto('/');
  await page.getByRole('button',{name:'Verity',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});

  // Open Pareto so Pareto is the committed active conversation.
  const paretoBtn=tree.getByRole('button',{name:'Pareto',exact:true});
  await paretoBtn.click();
  await expect(paretoBtn).toHaveAttribute('aria-current','page');

  // 1. Long-press (>= 260ms) and release in place on unselected Fredrik -> opens searchable Move to Picker
  //    without navigating away from Pareto, then moves Fredrik into Other / Archive!
  const fredrikBtn=tree.getByRole('button',{name:'Fredrik',exact:true});
  const fBox=(await fredrikBtn.boundingBox())!;
  await page.mouse.move(fBox.x+24,fBox.y+10);
  await page.mouse.down();
  await page.waitForTimeout(300);
  await expect(fredrikBtn).toHaveClass(/drag-source/);
  await expect(page.locator('.sidebar-drag-pill')).toContainText('Fredrik');
  await page.mouse.up();

  const picker=page.getByRole('dialog',{name:'Move to'});
  await expect(picker).toBeVisible();
  // Pareto remains the committed open mission while Fredrik is transiently highlighted for the picker.
  await expect(paretoBtn).toHaveAttribute('aria-current','page');
  await picker.getByRole('combobox').fill('Archive');
  await picker.getByRole('option',{name:/Archive/}).click();
  await expect.poll(()=>missions.find(m=>m.id===F)).toMatchObject({project:'other',folder:'Archive'});
  await expect(paretoBtn).toHaveAttribute('aria-current','page');

  // Collapse Other again so we can test 450ms spring-loaded auto-expand while dragging!
  const otherBtn=tree.getByRole('button',{name:'Other',exact:true});
  if((await otherBtn.getAttribute('aria-expanded'))==='true') await otherBtn.click();
  await expect(otherBtn).toHaveAttribute('aria-expanded','false');

  // 2. Escape during an active drag cancels cleanly without moving.
  const specsRow=tree.locator('[data-tree-id="pf:verity:Specs"] .row-main');
  const sBox=(await specsRow.boundingBox())!;
  const oBox=(await otherBtn.boundingBox())!;
  await page.mouse.move(sBox.x+24,sBox.y+10);
  await page.mouse.down();
  await page.mouse.move(sBox.x+24,sBox.y+30,{steps:4});
  await page.keyboard.press('Escape');
  await page.mouse.up();
  expect(dirs['verity:']?.map(e=>e.name)).toEqual(['Specs']);

  // 3. Dragging folder "Specs" (containing mission "Nested Agent" and cron "Nightly Spec Check")
  //    onto collapsed project "Other", dwelling >= 450ms to spring-load expand "Other", and dropping
  //    moves the folder, nested mission, and nested cron across projects together!
  await page.mouse.move(sBox.x+24,sBox.y+10);
  await page.mouse.down();
  await page.mouse.move(oBox.x+24,oBox.y+10,{steps:6});
  await expect(tree.locator('.row.project[data-drop-project="other"]')).toHaveClass(/drop-active/);
  await page.waitForTimeout(500);
  await expect(otherBtn).toHaveAttribute('aria-expanded','true');
  // Re-position on Other header in case expansion shifted rows, then drop.
  const oBoxAfter=(await otherBtn.boundingBox())!;
  await page.mouse.move(oBoxAfter.x+24,oBoxAfter.y+10);
  await page.mouse.up();

  await expect.poll(()=>dirs['other:']?.some(e=>e.name==='Specs')).toBe(true);
  await expect.poll(()=>missions.find(m=>m.id===C)).toMatchObject({project:'other',folder:'Specs'});
  await expect.poll(()=>crons.other.some(j=>j.id==='cron-1' && j.folder==='Specs')).toBe(true);
  expect(crons.verity).toEqual([]);
});

test('selecting transcript text while Composer textarea is focused blurs empty Composer selection so Cmd+C copies transcript text', async ({page}) => {
  await page.addInitScript(() => {
    localStorage.setItem('orb.apiUrl',location.origin);
    localStorage.setItem('orb.jwt','test');
  });
  const mission={
    id:P,title:'Pareto',status:'completed',project:'verity',folder:'',tags:[],
    updated_at:'2026-09-25T10:00:00Z',
    history:[],
  };
  const events=[
    {id:1,sequence:1,event_type:'user_message',content:'Show token',timestamp:'2026-09-25T10:00:00Z'},
    {id:2,sequence:2,event_type:'assistant_message_canonical',content:'COPY_TOKEN_ALPHA_99',timestamp:'2026-09-25T10:00:01Z',event_id:'turn:1',metadata:{bubble_id:'turn:1',revision:1}},
  ];
  await page.route('**/api/**',async route=>{
    const url=new URL(route.request().url()),path=url.pathname;
    if(path==='/api/projects') return route.fulfill({json:{projects:[{slug:'verity',title:'Verity'}]}});
    if(path==='/api/control/missions') return route.fulfill({json:[mission]});
    if(path===`/api/control/missions/${P}`) return route.fulfill({json:mission});
    if(path.endsWith('/events')) return route.fulfill(eventPage(route,events));
    if(path.endsWith('/files')) return route.fulfill({json:{entries:[]}});
    if(path.endsWith('/crons')) return route.fulfill({json:{jobs:[]}});
    if(path.endsWith('/controller')) return route.fulfill({json:{job:null,runs:[]}});
    return route.fulfill({json:[]});
  });

  await page.goto('/');
  await page.getByRole('button',{name:'Verity',exact:true}).click();
  await page.getByRole('tree',{name:'Projects',exact:true}).getByRole('button',{name:'Pareto',exact:true}).click();
  await expect(page.getByText('COPY_TOKEN_ALPHA_99')).toBeVisible();
  await expect(page.locator('.scroll')).not.toHaveClass(/\blanding\b/);

  // Focus Composer with empty selection (matching Orb launch/mission open behavior), then select transcript text.
  const composer=page.locator('.composer textarea');
  await composer.focus();
  await expect(composer).toBeFocused();

  const selectedAndBlurred=await page.evaluate(()=>{
    const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
    let targetNode:Text|null=null;
    while(walker.nextNode()){
      const n=walker.currentNode as Text;
      if(n.nodeValue?.includes('COPY_TOKEN_ALPHA_99')){ targetNode=n; break; }
    }
    if(!targetNode) return null;
    const range=document.createRange();
    range.selectNodeContents(targetNode);
    const sel=window.getSelection()!;
    sel.removeAllRanges();
    sel.addRange(range);
    return new Promise<{selected:string;activeTag:string}>(resolve=>{
      setTimeout(()=>resolve({
        selected:window.getSelection()?.toString()??'',
        activeTag:document.activeElement?.tagName??'',
      }),30);
    });
  });
  expect(selectedAndBlurred).toEqual({selected:'COPY_TOKEN_ALPHA_99',activeTag:'BODY'});
});
