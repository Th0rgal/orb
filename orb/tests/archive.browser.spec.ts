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
 release();await expect(row).toBeVisible();expect(projects).toBe(reads);
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
 await expect(projects.getByRole('button',{name:/Archived nested conversation/})).toBeVisible();
 await expect(projects.getByRole('button',{name:'Second project',exact:true})).toHaveAttribute('aria-expanded','true');
 await expect(page.getByRole('button',{name:'notes',exact:true})).toHaveAttribute('aria-expanded','true');
 await expect(page.getByRole('button',{name:'deep',exact:true})).toHaveAttribute('aria-expanded','true');
 expect(writes).toEqual([{path:'/api/control/missions/archived/status',body:{status:'paused'}}]);
 expect(missions[2].tags).toEqual(['orb-folder:notes/deep']);
 await page.screenshot({path:'/tmp/orb-shared-archives.png'});
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
 await expect(archiveTree.locator('[aria-selected="true"]')).toHaveCount(1);
 await expect(page.getByRole('dialog')).toContainText('Delete 1 agent?');
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect.poll(()=>deleted).toEqual(['week-one']);
 await expect(archiveTree.getByRole('button',{name:'Ten days one',exact:true})).toHaveCount(0);

 // Right-clicking a project group inside Archived scopes "older than 1 day" to that project.
 await archiveTree.getByRole('button',{name:'First project',exact:true}).click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete older than 1 day…',exact:true}).click();
 await expect(archiveTree.locator('[aria-selected="true"]')).toHaveCount(1);
 await expect(page.getByRole('dialog')).toContainText('Delete 1 agent?');
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect.poll(()=>deleted).toEqual(['week-one','day-one']);
 await expect(archiveTree.getByRole('button',{name:'Two days one',exact:true})).toHaveCount(0);
 await expect(archiveTree.getByRole('button',{name:'Fresh one',exact:true})).toBeVisible();

 // Right-clicking an archived row also exposes the bulk delete actions across all archives.
 await archiveTree.getByRole('button',{name:'Fresh one',exact:true}).click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete all…',exact:true}).click();
 await expect(archiveTree.locator('[aria-selected="true"]')).toHaveCount(3);
 await expect(page.getByRole('dialog')).toContainText('Delete 3 agents?');
 await page.getByRole('dialog').getByRole('button',{name:'Delete',exact:true}).click();
 await expect.poll(()=>deleted).toEqual(['week-one','day-one','fresh-two','fresh-one','day-two']);
 await expect(page.getByText('No archived conversations.')).toBeVisible();
});

test('confirming deletion closes the dialog immediately while deleting in the background and makes in-flight agents uninteractable',async({page})=>{
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

 // Dialog closes immediately so the app remains usable while deletion runs in the background.
 await expect(dialog).toHaveCount(0);
 await expect.poll(()=>deleteStarted).toEqual(['fail-two']);

 const archiveTree=page.getByRole('tree',{name:'Archived conversations'});
 const slowRow=archiveTree.getByRole('button',{name:'Slow delete one',exact:true});
 const failRow=archiveTree.getByRole('button',{name:'Failed delete two',exact:true});
 const freshRow=archiveTree.getByRole('button',{name:'Fresh conversation',exact:true});

 // Both queued agents are disabled/uninteractable and cannot be opened or right-clicked for deletion again.
 await expect(slowRow).toBeDisabled();
 await expect(slowRow).toHaveAttribute('aria-busy','true');
 await expect(failRow).toBeDisabled();
 await expect(freshRow).toBeEnabled();

 await slowRow.click({button:'right',force:true});
 await expect(page.getByRole('menu')).toHaveCount(0);

 // User can freely interact with other conversations while background deletion is in flight.
 await freshRow.click();
 await expect(freshRow).toHaveAttribute('aria-current','page');

 // Bulk "Delete all…" skips the two agents already being deleted and only targets the remaining 1 agent.
 await archiveTree.getByRole('button',{name:'First project',exact:true}).click({button:'right'});
 await page.getByRole('menuitem',{name:'Delete all…',exact:true}).click();
 await expect(page.getByRole('dialog')).toContainText('Delete 1 agent?');
 await page.getByRole('dialog').getByRole('button',{name:'Cancel',exact:true}).click();

 // Once the background requests finish, the deleted row disappears and the failed row becomes interactable again.
 releaseSlow();
 await expect(slowRow).toHaveCount(0);
 await expect(failRow).toBeEnabled();
 await expect(page.locator('.error-dialog')).toContainText('fail-two: Error: 409 mission is busy');
});

