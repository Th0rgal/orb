import { test, expect } from '@playwright/test';

test('archive moves a controller into the shared archive and restore keeps it paused', async ({page}) => {
  let archived = false;
  const actions: string[] = [];
  await page.route('**/api/**', async route => {
    const path = new URL(route.request().url()).pathname;
    let result: unknown = {};
    const view = () => ({slug:'notes',job:{id:'controller',name:'notes-controller',enabled:false,state:'paused',archived,failure_streak:0},runs:[]});
    if(path === '/api/projects') result = {projects:[{slug:'notes',title:'Project notes',status:'active'}]};
    else if(path.endsWith('/controller/action')) {
      const {action} = route.request().postDataJSON();
      actions.push(action); archived = action === 'archive'; result = view();
    } else if(path.endsWith('/controller')) result = view();
    else if(path.endsWith('/crons')) result = {jobs:[]};
    else if(path.endsWith('/missions')) result = [];
    else if(path.endsWith('/files')) result = {entries:[]};
    await route.fulfill({json:result});
  });
  const errors: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto('/tests/browser.html?theme=dark');
  await page.getByRole('button',{name:'Project notes',exact:true}).click();
  const controller = page.getByRole('button',{name:/notes-controller/});
  await controller.click({button:'right'});
  await page.getByRole('menuitem',{name:'Archive',exact:true}).click();
  await expect(controller).toHaveCount(0);
  await page.getByRole('button',{name:'Archived',exact:true}).click();
  await page.getByRole('tree',{name:'Archived conversations'}).getByRole('button',{name:'Project notes',exact:true}).click();
  await expect(controller).toBeVisible();
  await expect(controller.getByRole('img',{name:'Paused',exact:true})).toBeVisible();
  await controller.click({button:'right'});
  await page.getByRole('menuitem',{name:'Restore',exact:true}).click();
  await expect(page.getByRole('tree',{name:'Archived conversations'}).getByRole('button',{name:/notes-controller/})).toHaveCount(0);
  await expect(controller).toBeVisible();
  expect(actions).toEqual(['archive','restore']);
  expect(errors).toEqual([]);
  await page.screenshot({path:'/tmp/orb-controller-restored.png'});
});

test('delete cron via right-click in sidebar and from Settings page', async ({page}) => {
  let controllerDeleted = false;
  let cronDeleted = false;
  const deletedEndpoints: string[] = [];
  await page.route('**/api/**', async route => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    const method = req.method();
    let result: unknown = {};
    const controllerView = () => ({slug:'notes',job:controllerDeleted ? null : {id:'controller',name:'notes-controller',enabled:true,state:'scheduled',archived:false,failure_streak:0},settings:{prompt:'Check repo',prompt_chars:10,skills:[],repeat_completed:0,no_agent:false,continuity:false,enabled_toolsets:[]},runs:[]});
    const extraJob = {id:'extra-1',name:'extra-sync',schedule:'every 1h',prompt:'Sync docs',enabled:true,state:'scheduled',failure_streak:0};
    if(path === '/api/projects') result = {projects:[{slug:'notes',title:'Project notes',status:'active'}]};
    else if(path.endsWith('/controller') && method === 'DELETE') {
      controllerDeleted = true;
      deletedEndpoints.push('DELETE /controller');
      result = controllerView();
    } else if(path.endsWith('/controller')) result = controllerView();
    else if(path.endsWith('/crons/extra-1') && method === 'DELETE') {
      cronDeleted = true;
      deletedEndpoints.push('DELETE /crons/extra-1');
      result = {deleted:'extra-1'};
    } else if(path.endsWith('/crons/extra-1')) result = {job:extraJob,runs:[]};
    else if(path.endsWith('/crons')) result = {jobs:cronDeleted ? [] : [extraJob]};
    else if(path.endsWith('/missions')) result = [];
    else if(path.endsWith('/files')) result = {entries:[]};
    else if(path.endsWith('/steers')) result = {pending:[],recent:[]};
    await route.fulfill({json:result});
  });
  const errors: string[] = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto('/tests/browser.html?theme=dark');
  await page.getByRole('button',{name:'Project notes',exact:true}).click();

  // 1. Right-click delete on extra cron row in sidebar
  const extraRow = page.getByRole('button',{name:/extra-sync/});
  await expect(extraRow).toBeVisible();
  await extraRow.click({button:'right'});
  await page.getByRole('menuitem',{name:'Delete…',exact:true}).click();
  const confirmDlg = page.getByRole('dialog',{name:'Delete cron?'});
  await expect(confirmDlg).toBeVisible();
  await confirmDlg.getByRole('button',{name:'Delete',exact:true}).click();
  await expect(extraRow).toHaveCount(0);

  // 2. Delete controller cron from its Settings page
  const controllerRow = page.getByRole('button',{name:/notes-controller/});
  await expect(controllerRow).toBeVisible();
  await controllerRow.click();
  await page.getByRole('button',{name:'Settings',exact:true}).click();
  await page.getByRole('button',{name:'Delete cron…',exact:true}).click();
  const settingsConfirmDlg = page.getByRole('dialog',{name:'Delete cron?'});
  await expect(settingsConfirmDlg).toBeVisible();
  await settingsConfirmDlg.getByRole('button',{name:'Delete',exact:true}).click();
  await expect(page.getByText('This project has no controller cron in Hermes.')).toBeVisible();

  expect(deletedEndpoints).toEqual(['DELETE /crons/extra-1', 'DELETE /controller']);
  expect(errors).toEqual([]);
});
