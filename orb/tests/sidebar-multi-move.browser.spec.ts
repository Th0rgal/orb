import {test, expect, type Page} from '@playwright/test';
test.use({browserName:'webkit'});
const P='00000000-0000-0000-0000-0000000000a1', F='00000000-0000-0000-0000-0000000000a2', C='00000000-0000-0000-0000-0000000000a3';
type M={id:string;title:string;status:string;project:string;tags:string[];history:[];updated_at:string;parent_mission_id?:string};
async function setup(page:Page, opts:{failMove?:string; deleteRunning?:boolean}={}) {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  let missions:M[]=[
    {id:P,title:'Pareto',status:'completed',project:'verity',tags:[],history:[],updated_at:'2026-10-20T07:00:00Z'},
    {id:F,title:'Fredrik',status:'completed',project:'verity',tags:[],history:[],updated_at:'2026-10-20T06:00:00Z'},
    {id:C,title:'Deep Audit',status:opts.deleteRunning?'active':'interrupted',project:'verity',tags:[],history:[],updated_at:'2026-10-20T05:00:00Z',parent_mission_id:P},
  ];
  const writes:string[]=[]; const cancels:string[]=[];
  let release:()=>void=()=>{}; const gate=new Promise<void>(r=>release=r);
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
    if(req.method()==='POST' && path.endsWith('/project')) {
      writes.push(id); await gate;
      if(id===opts.failMove) return route.fulfill({status:409,body:'Mission is locked'});
      const body=req.postDataJSON();missions=missions.map(m=>m.id===id?{...m,project:body.project,tags:body.tags}:m);
      return route.fulfill({json:{ok:true}});
    }
    if(req.method()==='POST' && path.endsWith('/cancel')) { cancels.push(id); missions=missions.map(m=>m.id===id?{...m,status:'interrupted'}:m); return route.fulfill({json:{ok:true}}); }
    if(req.method()==='DELETE') {
      const running=missions.find(m=>m.parent_mission_id===id&&m.status==='active');
      if(running) return route.fulfill({status:409,body:`Cannot delete a running mission or worker (${running.id}). Cancel it first.`});
      const gone=[id,...missions.filter(m=>m.parent_mission_id===id).map(m=>m.id)];
      missions=missions.filter(m=>!gone.includes(m.id)); return route.fulfill({json:{deleted_ids:gone}});
    }
    const json=path==='/api/projects'?{projects:[{slug:'verity',title:'Verity'}]}
      :path==='/api/control/missions'?missions.filter(m=>!url.searchParams.has('project')||m.project===url.searchParams.get('project'))
      :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
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
  await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
  const dialog=page.getByRole('dialog');
  await expect(dialog).toContainText('1 worker is still running');
  await dialog.getByRole('button',{name:'Stop and delete',exact:true}).click();
  await expect.poll(()=>cancels).toEqual([C]);
  await expect.poll(()=>missions().map(m=>m.title)).toEqual(['Fredrik']);
  await expect(tree.getByRole('button',{name:'Pareto',exact:true})).toHaveCount(0);
});
