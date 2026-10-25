import {test, expect} from '@playwright/test';
test.use({browserName:'webkit'});
test('sidebar chrome is not selectable and only rows show focus', async ({page}) => {
  await page.addInitScript(() => {localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
  const missions = Array.from({length:3},(_,i)=>({id:`00000000-0000-0000-0000-00000000000${i}`,title:`Agent ${i}`,status:'failed',project:'one',tags:[],history:[],updated_at:`2026-09-2${5-i}`}));
  await page.route('**/api/**',async route=>{
    const url=new URL(route.request().url()),path=url.pathname,id=path.split('/')[4];
    const json=path==='/api/projects'?{projects:[{slug:'one',title:'One'}]}
      :path==='/api/control/missions'?missions
      :path.startsWith('/api/control/missions/')?missions.find(m=>m.id===id)??{}
      :path.endsWith('/files')?{entries:[]}:path.endsWith('/crons')?{jobs:[]}:path.endsWith('/controller')?{job:null,runs:[]}:[];
    await route.fulfill({json});
  });
  await page.goto('/');await page.getByRole('button',{name:'One',exact:true}).click();
  const tree=page.getByRole('tree',{name:'Projects',exact:true});
  const first=tree.getByRole('button',{name:'Agent 0',exact:true}), last=tree.getByRole('button',{name:'Agent 2',exact:true});
  await expect(last).toBeVisible();
  const a=(await first.boundingBox())!, b=(await last.boundingBox())!;
  await page.mouse.move(a.x+a.width-4,a.y+a.height/2);await page.mouse.down();
  await page.mouse.move(b.x+4,b.y+b.height/2,{steps:8});await page.mouse.up();
  expect(await page.evaluate(()=>getSelection()?.toString() ?? '')).toBe('');
  await page.keyboard.press('Meta+a');
  expect(await page.evaluate(()=>getSelection()?.toString().includes('Agent 0') ?? false)).toBe(false);

  const region=page.locator('[data-project-navigation]');
  await expect(region).not.toHaveAttribute('title',/.*/);
  const box=(await region.boundingBox())!;
  await page.mouse.click(box.x+box.width/2,box.y+box.height-2);
  // WebKit leaves the region focused after a click (buttons don't take focus); it must not draw a box.
  expect(await region.evaluate(el=>getComputedStyle(el).outlineStyle)).toBe('none');
  await region.evaluate(el=>(el as HTMLElement).focus());
  expect(await region.evaluate(el=>getComputedStyle(el).outlineStyle)).toBe('none');

  await first.focus();await page.keyboard.press('ArrowDown');
  await expect(tree.getByRole('button',{name:'Agent 1',exact:true})).toBeFocused();
  const entry=tree.locator('.tree-entry:has(button:focus)');
  await expect(entry).toHaveCount(1);
  expect(await entry.evaluate(el=>getComputedStyle(el).boxShadow)).not.toBe('none');
});
