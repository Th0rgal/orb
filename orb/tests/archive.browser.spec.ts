import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('archive is immediate, preserves the project, and rolls back a failed request',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 let projects=0,release!:()=>void;
 const hold=new Promise<void>(r=>release=r);
 const mission={id:'archive-test',title:'Archive this conversation',status:'awaiting_user',history:[],tags:[]};
 await page.route('**/api/**',async route=>{
  const path=new URL(route.request().url()).pathname;
  if(path.endsWith('/archive-test/status')){await hold;return route.fulfill({status:500,body:'Archive failed'});}
  if(path==='/api/projects')projects++;
  const json=path==='/api/projects'?{projects:[{slug:'test',title:'Test project'}]}:path==='/api/control/missions'?[mission]:path==='/api/control/missions/archive-test'?mission:path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/');
 const project=page.getByRole('button',{name:'Test project',exact:true});await project.click();
 const row=page.getByRole('button',{name:/Archive this conversation/});await expect(row).toBeVisible();
 const reads=projects;
 await row.click({button:'right'});await page.getByRole('menuitem',{name:'Archive',exact:true}).click();
 await expect(row).not.toBeVisible();
 await expect(project).toHaveAttribute('aria-expanded','true');expect(projects).toBe(reads);
 release();await page.getByRole("dialog").getByRole("button",{name:"Close",exact:true}).last().click();await expect(row).toBeVisible();expect(projects).toBe(reads);
});

test('one collapsed archive spans projects, while completion stays in place; restore reveals the original folder',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const missions=[
  {id:'completed',title:'Completed but not archived',status:'completed',project:'one',tags:[]},
  {id:'failed',title:'Failed but not archived',status:'failed',project:'one',tags:[]},
  {id:'archived',title:'Archived nested conversation',status:'acknowledged',project:'two',tags:['orb-folder:notes/deep']},
 ];
 const writes:any[]=[];
 await page.route('**/api/**',async route=>{
  const request=route.request(),url=new URL(request.url()),path=url.pathname;
  if(request.method()==='POST'){
   writes.push({path,body:request.postDataJSON()});
   if(path.endsWith('/archived/status'))missions[2].status=request.postDataJSON().status;
   return route.fulfill({json:{}});
  }
  if(request.method()==='DELETE'&&path==='/api/control/missions/archived'){
   if(missions[2].status==='paused')return route.fulfill({status:409,body:'Cannot delete a paused mission'});
   writes.push({path,method:'DELETE'});
   missions.splice(2,1);
   return route.fulfill({json:{deleted_ids:['archived']}});
  }
  const json=path==='/api/projects'?{projects:[{slug:'one',title:'First project'},{slug:'two',title:'Second project'}]}
   :path==='/api/control/missions'?missions.filter(m=>(!url.searchParams.has('project')||m.project===url.searchParams.get('project'))&&(!url.searchParams.has('status')||m.status===url.searchParams.get('status')))
   :path==='/api/control/missions/archived'?missions[2]
   :path.endsWith('/files')?{entries:[]}:path.endsWith('/controller')?{job:null,runs:[]}:path.endsWith('/crons')?{jobs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/');
 const archives=page.getByRole('button',{name:'Archived',exact:true});
 await expect(archives).toHaveAttribute('aria-expanded','false');
 await page.getByRole('button',{name:'First project',exact:true}).click();
 const projects=page.getByRole('tree',{name:'Projects',exact:true});
 await expect(projects.getByRole('button',{name:/Completed but not archived/})).toBeVisible();
 await expect(projects.getByRole('button',{name:/Failed but not archived/})).toBeVisible();
 await expect(page.getByRole('button',{name:/History ·/})).toHaveCount(0);
 await archives.click();
 const archiveTree=page.getByRole('tree',{name:'Archived conversations'});
 await expect(archives.locator('.history-chevron')).toHaveCSS('transform','matrix(0, 1, -1, 0, 0, 0)');
 await expect(archiveTree.getByRole('button',{name:'Second project',exact:true})).toHaveAttribute('aria-expanded','false');
 await expect(archiveTree.getByRole('button',{name:/Archived nested conversation/})).toHaveCount(0);
 await archiveTree.getByRole('button',{name:'Second project',exact:true}).click();
 const row=archiveTree.getByRole('button',{name:/Archived nested conversation/});
 await expect(row).toBeVisible();
 await page.screenshot({path:'/tmp/orb-archive-project-groups.png'});
 await expect(projects.getByRole('button',{name:'Second project',exact:true})).toHaveAttribute('aria-expanded','false');
 await row.click({button:'right'});await page.getByRole('menuitem',{name:'Restore',exact:true}).click();
 await expect(archiveTree.getByRole('button',{name:/Archived nested conversation/})).toHaveCount(0);
 const restoredRow=projects.getByRole('button',{name:/Archived nested conversation/});
 await expect(restoredRow).toBeVisible();
 await expect(projects.getByRole('button',{name:'Second project',exact:true})).toHaveAttribute('aria-expanded','true');
 await expect(page.getByRole('button',{name:'notes',exact:true})).toHaveAttribute('aria-expanded','true');
 await expect(page.getByRole('button',{name:'deep',exact:true})).toHaveAttribute('aria-expanded','true');
 expect(writes).toEqual([{path:'/api/control/missions/archived/status',body:{status:'paused'}}]);
 expect(missions[2].tags).toEqual(['orb-folder:notes/deep']);
 await page.screenshot({path:'/tmp/orb-shared-archives.png'});
 await restoredRow.click({button:'right'});await page.getByRole('menuitem',{name:'Delete agent…',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect(restoredRow).toHaveCount(0);
 expect(writes).toEqual([
  {path:'/api/control/missions/archived/status',body:{status:'paused'}},
  {path:'/api/control/missions/archived/status',body:{status:'acknowledged'}},
  {path:'/api/control/missions/archived',method:'DELETE'},
 ]);
 await page.reload();await expect(archives).toHaveAttribute('aria-expanded','false');
});

test('archives load older pages on demand and a rejected restore leaves the session archived',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const missions=Array.from({length:101},(_,i)=>({id:`old-${i}`,title:`Old conversation ${i}`,status:'acknowledged',project:'test',tags:[]}));
 const offsets:number[]=[];
 await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url()),path=url.pathname;
  if(path.endsWith('/status'))return route.fulfill({status:500,body:'Restore failed'});
  if(path==='/api/control/missions'&&url.searchParams.get('status')==='acknowledged'){
   const offset=Number(url.searchParams.get('offset'));offsets.push(offset);
   return route.fulfill({json:missions.slice(offset,offset+100)});
  }
  const json=path==='/api/projects'?{projects:[{slug:'test',title:'Test project'}]}:path==='/api/control/missions/old-100'?missions[100]:path==='/api/control/missions'?[]:path.endsWith('/files')?{entries:[]}:path.endsWith('/controller')?{job:null,runs:[]}:path.endsWith('/crons')?{jobs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/');expect(offsets).toEqual([]);
 await page.getByRole('button',{name:'Archived',exact:true}).click();
 const archive=page.getByRole('tree',{name:'Archived conversations'});
 await archive.getByRole('button',{name:'Test project',exact:true}).click();
 await expect(archive.getByRole('button')).toHaveCount(101);
 await page.getByRole('button',{name:'Load older conversations'}).click();
 await expect(archive.getByRole('button')).toHaveCount(102);expect(offsets).toEqual([0,100]);
 const row=archive.getByRole('button',{name:/Old conversation 100/});await row.click({button:'right'});
 await page.getByRole('menuitem',{name:'Restore',exact:true}).click();
 await expect(page.getByRole('alert')).toContainText('Restore failed');
 await page.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).last().click();
 await expect(row).toBeVisible();
 await expect(page.getByRole('tree',{name:'Projects',exact:true}).getByRole('button',{name:'Test project',exact:true})).toHaveAttribute('aria-expanded','false');
});

test('right-click in archives selects and deletes everything, older than 1 day, and older than 1 week',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const now=Date.now(),day=24*60*60*1000;
 let missions=[
  {id:'fresh-one',title:'Fresh one',status:'acknowledged',project:'one',tags:[],updated_at:new Date(now-2*60*60*1000).toISOString()},
  {id:'day-one',title:'Two days one',status:'acknowledged',project:'one',tags:[],updated_at:new Date(now-2*day).toISOString()},
  {id:'week-one',title:'Ten days one',status:'acknowledged',project:'one',tags:[],updated_at:new Date(now-10*day).toISOString()},
  {id:'fresh-two',title:'Fresh two',status:'acknowledged',project:'two',tags:[],updated_at:new Date(now-60*60*1000).toISOString()},
  {id:'day-two',title:'Three days two',status:'acknowledged',project:'two',tags:[],updated_at:new Date(now-3*day).toISOString()},
 ];
 const deleted:string[]=[];
 await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
  if(req.method()==='DELETE'){
   deleted.push(id);missions=missions.filter(m=>m.id!==id);
   return route.fulfill({json:{deleted_ids:[id]}});
  }
  const json=path==='/api/projects'?{projects:[{slug:'one',title:'First project'},{slug:'two',title:'Second project'}]}
   :path==='/api/control/missions'?missions.filter(m=>(!url.searchParams.has('project')||m.project===url.searchParams.get('project'))&&(!url.searchParams.has('status')||m.status===url.searchParams.get('status')))
   :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
   :path.endsWith('/files')?{entries:[]}:path.endsWith('/controller')?{job:null,runs:[]}:path.endsWith('/crons')?{jobs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/');
 const archives=page.getByRole('button',{name:'Archived',exact:true});
 // Right-clicking the collapsed Archived header loads, expands, selects >1 week, and deletes it.
 await archives.click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete older than 1 week…',exact:true}).click();
 const archiveTree=page.getByRole('tree',{name:'Archived conversations'});
 await expect(page.locator('#sidebar-archives [aria-selected="true"]')).toHaveCount(1);
 await expect(page.getByRole('dialog')).toContainText('Delete 1 agent?');
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect.poll(()=>deleted).toEqual(['week-one']);
 await expect(archiveTree.getByRole('button',{name:'Ten days one',exact:true})).toHaveCount(0);

 // Right-clicking a project group inside Archived scopes "older than 1 day" to that project.
 await archiveTree.getByRole('button',{name:'First project',exact:true}).click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete older than 1 day…',exact:true}).click();
 await expect(page.locator('#sidebar-archives [aria-selected="true"]')).toHaveCount(1);
 await expect(page.getByRole('dialog')).toContainText('Delete 1 agent?');
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect.poll(()=>deleted).toEqual(['week-one','day-one']);
 await expect(archiveTree.getByRole('button',{name:'Two days one',exact:true})).toHaveCount(0);
 await expect(archiveTree.getByRole('button',{name:'Fresh one',exact:true})).toBeVisible();

 // A single archived session only exposes actions for that session.
 const freshOne=archiveTree.getByRole('button',{name:'Fresh one',exact:true});
 await freshOne.click({button:'right'});
 await expect(page.getByRole('menuitem',{name:'Delete agent…',exact:true})).toBeVisible();
 await expect(page.getByRole('menuitem',{name:'Delete all…',exact:true})).toHaveCount(0);
 await expect(page.getByRole('menuitem',{name:'Delete older than 1 day…',exact:true})).toHaveCount(0);
 await expect(page.getByRole('menuitem',{name:'Delete older than 1 week…',exact:true})).toHaveCount(0);
 await page.keyboard.press('Escape');

 // Bulk archive actions remain available when multiple sessions are selected.
 const shortcut=process.platform==='darwin'?'Meta':'Control';
 const secondProject=archiveTree.getByRole('button',{name:'Second project',exact:true});
 if(await secondProject.getAttribute('aria-expanded')==='false')await secondProject.click();
 await archiveTree.getByRole('button',{name:'Three days two',exact:true}).click({modifiers:[shortcut]});
 await freshOne.click({button:'right'});
 await expect(page.getByRole('menuitem',{name:'Delete 2 agents…',exact:true})).toBeVisible();
 await expect(page.getByRole('menuitem',{name:'Delete older than 1 day…',exact:true})).toBeVisible();
 await expect(page.getByRole('menuitem',{name:'Delete older than 1 week…',exact:true})).toBeVisible();
 await page.getByRole('menuitem',{name:'Delete all…',exact:true}).click();
 await expect(page.locator('#sidebar-archives [aria-selected="true"]')).toHaveCount(3);
 await expect(page.getByRole('dialog')).toContainText('Delete 3 agents?');
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect.poll(()=>deleted).toEqual(['week-one','day-one','fresh-two','fresh-one','day-two']);
 await expect(page.getByText('No archived conversations.')).toBeVisible();
});

test('deletion stays busy until completion and retains failed targets for retry',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 const now=Date.now(),day=24*60*60*1000;
 let missions=[
  {id:'slow-one',title:'Slow delete one',status:'acknowledged',project:'one',tags:[],updated_at:new Date(now-3*day).toISOString()},
  {id:'fail-two',title:'Failed delete two',status:'acknowledged',project:'one',tags:[],updated_at:new Date(now-2*day).toISOString()},
  {id:'keep-fresh',title:'Fresh conversation',status:'acknowledged',project:'one',tags:[],updated_at:new Date(now-60*1000).toISOString()},
 ];
 let releaseSlow!:()=>void;
 const slowHold=new Promise<void>(r=>{releaseSlow=r;});
 const deleteStarted:string[]=[];
 await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
  if(req.method()==='DELETE'){
   deleteStarted.push(id);
   if(id==='slow-one'){
    await slowHold;
    missions=missions.filter(m=>m.id!==id);
    return route.fulfill({json:{deleted_ids:[id]}});
   }
   if(id==='fail-two'){
    await slowHold;
    return route.fulfill({status:409,body:'mission is busy'});
   }
   missions=missions.filter(m=>m.id!==id);
   return route.fulfill({json:{deleted_ids:[id]}});
  }
  const json=path==='/api/projects'?{projects:[{slug:'one',title:'First project'}]}
   :path==='/api/control/missions'?missions.filter(m=>(!url.searchParams.has('project')||m.project===url.searchParams.get('project'))&&(!url.searchParams.has('status')||m.status===url.searchParams.get('status')))
   :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
   :path.endsWith('/files')?{entries:[]}:path.endsWith('/controller')?{job:null,runs:[]}:path.endsWith('/crons')?{jobs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/');
 const archives=page.getByRole('button',{name:'Archived',exact:true});
 await archives.click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete older than 1 day…',exact:true}).click();
 const dialog=page.getByRole('dialog');
 await expect(dialog).toContainText('Delete 2 agents?');
 await dialog.getByRole('button',{name:'Delete',exact:true}).click();

 // The modal remains in charge while the mutation is running.
 await expect(dialog).toHaveAttribute('aria-busy','true');
 await expect(dialog.getByRole('button',{name:'Cancel',exact:true})).toBeDisabled();
 await page.keyboard.press('Escape'); await expect(dialog).toBeVisible();
 await expect.poll(()=>deleteStarted).toEqual(['fail-two']);
 releaseSlow();
 await expect(dialog).toContainText('fail-two: Error: 409 mission is busy');
 await expect(dialog).not.toHaveAttribute('aria-busy','true');
 await expect(dialog.getByRole('button',{name:'Delete',exact:true})).toBeEnabled();
 await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 const archiveTree=page.getByRole('tree',{name:'Archived conversations'});
 await expect(archiveTree.getByRole('button',{name:'Slow delete one',exact:true})).toHaveCount(0);
 await expect(archiveTree.getByRole('button',{name:'Failed delete two',exact:true})).toBeEnabled();
 await expect(archiveTree.getByRole('button',{name:'Fresh conversation',exact:true})).toBeEnabled();

});

test('archiving or deleting a parent agent cascades to its spawned subagents and keeps them nested in archives',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 let missions:any[]=[
  {id:'parent-archive',title:'Parent to archive',status:'awaiting_user',project:'verity',tags:['orb-folder:Context']},
  {id:'sub-archive-1',title:'Spawned worker 1',status:'failed',project:'verity',parent_mission_id:'parent-archive',tags:[]},
  {id:'sub-archive-2',title:'Spawned worker 2',status:'completed',project:'verity',parent_mission_id:'parent-archive',tags:[]},
  {id:'parent-delete',title:'Parent to delete',status:'awaiting_user',project:'verity',tags:['orb-folder:Context']},
  {id:'sub-delete-1',title:'Delete worker 1',status:'completed',project:'verity',parent_mission_id:'parent-delete',tags:[]},
 ];
 const statusWrites:string[]=[];
 const deleted:string[]=[];
 await page.route('**/api/**',async route=>{
  const req=route.request(),url=new URL(req.url()),path=url.pathname,id=path.split('/')[4];
  if(req.method()==='POST'&&path.endsWith('/status')){
   const status=req.postDataJSON().status;
   statusWrites.push(`${id}:${status}`);
   const target=missions.find(m=>m.id===id);
   if(target)target.status=status;
   return route.fulfill({json:{}});
  }
  if(req.method()==='DELETE'){
   deleted.push(id);
   missions=missions.filter(m=>m.id!==id&&m.parent_mission_id!==id);
   return route.fulfill({json:{deleted_ids:[id]}});
  }
  const json=path==='/api/projects'?{projects:[{slug:'verity',title:'Verity'}]}
   :path==='/api/control/missions'?missions.filter(m=>(!url.searchParams.has('project')||m.project===url.searchParams.get('project'))&&(!url.searchParams.has('status')||m.status===url.searchParams.get('status')))
   :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
   :path.endsWith('/files')?{entries:[{name:'Context',kind:'dir'}]}:path.endsWith('/controller')?{job:null,runs:[]}:path.endsWith('/crons')?{jobs:[]}:[];
  await route.fulfill({json});
 });
 await page.goto('/');
 const projects=page.getByRole('tree',{name:'Projects',exact:true});
 await projects.getByRole('button',{name:'Verity',exact:true}).click();
 await projects.getByRole('button',{name:'Context',exact:true}).click();

 // Archive the parent: neither the parent nor its subagents may remain in the project or pop out to root.
 const parentArchiveRow=projects.getByRole('button',{name:'Parent to archive',exact:true});
 await expect(parentArchiveRow).toBeVisible();
 await parentArchiveRow.click({button:'right'});
 await page.getByRole('menuitem',{name:'Archive',exact:true}).click();
 await expect(parentArchiveRow).toHaveCount(0);
 await expect(projects.getByRole('button',{name:/Spawned worker/})).toHaveCount(0);
 await expect.poll(()=>statusWrites.slice().sort()).toEqual([
  'parent-archive:acknowledged',
  'sub-archive-1:acknowledged',
  'sub-archive-2:acknowledged',
 ]);

 // In Archived, the subagents stay nested under the archived parent rather than flattened into the project.
 await page.getByRole('button',{name:'Archived',exact:true}).click();
 const archiveTree=page.getByRole('tree',{name:'Archived conversations'});
 await archiveTree.getByRole('button',{name:'Verity',exact:true}).click();
 await expect(archiveTree.getByRole('button',{name:'Parent to archive',exact:true})).toBeVisible();
 await expect(archiveTree.getByRole('button',{name:/Spawned worker/})).toHaveCount(0);
 await archiveTree.getByRole('button',{name:/Show the 2 missions launched by Parent to archive/}).click();
 await expect(archiveTree.getByRole('button',{name:'Spawned worker 1',exact:true})).toBeVisible();
 await expect(archiveTree.getByRole('button',{name:'Spawned worker 2',exact:true})).toBeVisible();

 // Delete the other parent: its spawned subagent is removed with it and never pops out to the project root.
 const parentDeleteRow=projects.getByRole('button',{name:'Parent to delete',exact:true});
 await expect(parentDeleteRow).toBeVisible();
 await parentDeleteRow.click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete agent…',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect(parentDeleteRow).toHaveCount(0);
 await expect(projects.getByRole('button',{name:'Delete worker 1',exact:true})).toHaveCount(0);
 expect(deleted).toEqual(['parent-delete']);
});

