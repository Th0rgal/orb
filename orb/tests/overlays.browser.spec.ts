import {test,expect} from "@playwright/test";
for(const theme of ["dark","light"]){
 test(`surfaces and small-window layout: ${theme}`,async({page})=>{
  await page.goto(`/tests/overlays.html?theme=${theme}`);
  await page.getByRole("button",{name:"Rename",exact:true}).click();
  const dialog=page.getByRole("dialog",{name:"Rename agent"});
  await expect(page.getByLabel("Agent name")).toBeFocused();
  expect((await dialog.boundingBox())!.width).toBe(400);
  await expect(dialog).toHaveScreenshot(`name-${theme}.png`);
  await page.keyboard.press("Escape");
  await expect(page.getByRole("button",{name:"Rename",exact:true})).toBeFocused();
  await page.getByRole("button",{name:"Confirm deletion"}).click();
  await expect(page.getByRole("button",{name:"Cancel",exact:true})).toBeFocused();
  await expect(page.getByRole("dialog")).toHaveScreenshot(`confirm-${theme}.png`);
  await page.keyboard.press("Escape");
  await page.getByRole("button",{name:"Actions",exact:true}).click();
  await expect(page.getByRole("menu",{name:"Project actions"})).toHaveScreenshot(`menu-${theme}.png`);
  await page.keyboard.press("Escape");
  await page.getByRole("button",{name:"Error details"}).click();
  await expect(page.getByRole("dialog")).toHaveScreenshot(`error-${theme}.png`);
  await page.keyboard.press("Escape");
  await page.getByRole("button",{name:"Image preview"}).click();
  await expect(page.getByRole("dialog")).toHaveScreenshot(`lightbox-${theme}.png`);
  await page.keyboard.press("Escape");
  await page.setViewportSize({width:390,height:500});
  await page.getByRole("button",{name:"Provider form"}).click();
  const form=page.getByRole("dialog").first();const box=(await form.boundingBox())!;
  expect(box.x).toBeGreaterThanOrEqual(16);expect(box.y).toBeGreaterThanOrEqual(16);expect(box.y+box.height).toBeLessThanOrEqual(484);
  await expect(form.getByRole("button",{name:"Save",exact:true})).toBeInViewport();
  await expect(form).toHaveScreenshot(`form-mobile-${theme}.png`);
  await page.keyboard.press("Escape");
  await page.getByRole("button",{name:"Choose model"}).click();
  await expect(page.getByRole("combobox")).toBeFocused();
  await expect(page.getByRole("dialog")).toHaveScreenshot(`picker-mobile-${theme}.png`);
  await page.keyboard.press("Escape");
  await page.getByRole("button",{name:"Edit prompt"}).click();
  await expect(page.getByLabel("Edit prompt text")).toBeFocused();
  await expect(page.locator(".gallery-message")).toHaveScreenshot(`message-editor-${theme}.png`);
 });
}
test("modal children close first and restore focus",async({page})=>{
 await page.goto('/tests/overlays.html');await page.getByRole('button',{name:'Provider form'}).click();
 const modal=page.getByRole('dialog').first();
 await modal.getByLabel('Provider',{exact:true}).click();await expect(page.getByRole('listbox')).toBeVisible();
 await page.keyboard.press('ArrowDown');await expect(modal.getByLabel('Provider',{exact:true})).toHaveValue('one');
 await page.keyboard.press('Escape');await expect(modal).toBeVisible();await expect(page.getByRole('listbox')).toHaveCount(0);
 await modal.getByRole('button',{name:'Pick a model'}).click();await expect(page.getByRole('dialog',{name:'Models',exact:true}).getByRole('combobox')).toBeFocused();
 await page.getByRole('dialog',{name:'Models',exact:true}).getByRole('combobox').fill('nothing matches');await expect(page.getByText('No results',{exact:true})).toBeVisible();
 await page.keyboard.press('Escape');await expect(modal.getByRole('button',{name:'Pick a model'})).toBeFocused();
 await modal.getByLabel('Notes').fill('Line 1');await page.keyboard.press('Enter');await expect(modal.getByLabel('Notes')).toHaveValue('Line 1\n');
 await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);
});
test("draft protection and single in-flight naming mutation",async({page})=>{
 await page.goto('/tests/overlays.html');await page.getByRole('button',{name:'Rename',exact:true}).click();
 await page.getByLabel('Agent name').fill('New name');await page.keyboard.press('Escape');
 await expect(page.getByRole('button',{name:'Keep editing'})).toBeFocused();await page.keyboard.press('Escape');
 await expect(page.getByLabel('Agent name')).toHaveValue('New name');
 await page.getByRole('dialog').getByRole('button',{name:'Rename',exact:true}).dblclick();
 await expect(page.getByRole('alert')).toContainText('Could not save');await expect(page.getByRole('status',{includeHidden:true})).toContainText('Save attempts: 1');
 await expect(page.getByLabel('Agent name')).toHaveValue('New name');await page.getByRole('dialog').getByRole('button',{name:'Rename',exact:true}).click();
 await expect(page.getByRole('dialog')).toHaveCount(0);await expect(page.getByRole('status',{includeHidden:true})).toContainText('Save attempts: 2');
});
test("submenus support arrows, Escape and hover",async({page})=>{
 await page.goto('/tests/overlays.html');await page.getByRole('button',{name:'Actions',exact:true}).click();
 await expect(page.getByRole('menuitem',{name:'Rename…'})).toBeFocused();
 await page.keyboard.press('End');await page.keyboard.press('ArrowRight');await expect(page.getByRole('menuitem',{name:'Copy path'})).toBeFocused();
 await page.keyboard.press('Escape');await expect(page.getByRole('menuitem',{name:'More actions'})).toBeFocused();
 await page.keyboard.press('ArrowRight');await page.keyboard.press('ArrowLeft');await expect(page.getByRole('menuitem',{name:'More actions'})).toBeFocused();
 await page.keyboard.press('Escape');await expect(page.getByRole('menu')).toHaveCount(0);
 await page.getByRole('button',{name:'Actions',exact:true}).click();await page.getByRole('menuitem',{name:'More actions'}).hover();await expect(page.getByRole('menuitem',{name:'Copy path'})).toBeVisible();
});

test("picker states, disabled options and active versus selected values", async({page})=>{
 for (const [state,message] of [["loading","Loading…"],["empty","No options available"],["error","Models could not load. Try again."]]) {
  await page.goto(`/tests/overlays.html?picker-state=${state}`);
  await page.getByRole("button",{name:"Choose model"}).click();
  await expect(page.getByRole("dialog")).toContainText(message);
  if(state==="error") {
   await page.getByRole("button",{name:"Try again"}).click();
   await expect(page.getByRole("option",{name:"Standard"})).toBeVisible();
  }
 }
 await page.goto('/tests/overlays.html');await page.getByRole('button',{name:'Choose model'}).click();
 const search=page.getByRole('combobox');
 await expect(page.getByRole('option',{name:'Unavailable model'})).toBeDisabled();
 await page.keyboard.press('ArrowDown');
 await expect(page.getByRole('option',{name:'Standard'})).toHaveAttribute('aria-selected','true');
 await expect(page.getByRole('option',{name:'Advanced Additional reasoning'})).toHaveAttribute('data-active','true');
 await page.keyboard.press('Enter');
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect(page.getByRole('status')).toContainText('Selected: two');
 await page.getByRole('button',{name:'Choose model'}).click();
 await search.fill('Model 39');await expect(page.getByRole('option')).toHaveCount(1);
 await page.keyboard.press('Enter');await expect(page.getByRole('status')).toContainText('Selected: option-39');
});

test("search shortcuts defer Escape to the open picker",async({page})=>{
 await page.goto('/tests/overlays.html');await page.locator('h1').click();
 await page.keyboard.press('Meta+f');await expect(page.getByRole('search')).toBeVisible();
 await page.getByRole('button',{name:'Choose model'}).click();
 await page.keyboard.press('Escape');await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect(page.getByRole('search')).toBeVisible();
 await page.keyboard.press('Escape');await expect(page.getByRole('search')).toHaveCount(0);
});

test("a confirmation above a popover owns the only dim backdrop",async({page})=>{
 await page.goto('/tests/overlays.html');await page.getByRole('button',{name:'New project',exact:true}).click();
 await page.getByRole('textbox',{name:'Project name'}).fill('Draft project');
 await page.getByRole('button',{name:'Cancel',exact:true}).click();
 await expect(page.getByRole('button',{name:'Keep editing'})).toBeFocused();
 await expect(page.locator('.dlg-back-dim')).toHaveCount(1);
 await page.keyboard.press('Escape');
 await expect(page.getByRole('textbox',{name:'Project name'})).toHaveValue('Draft project');
});

test('effort picker keeps one active row through refresh and commits the keyboard choice',async({page})=>{
 await page.goto('/tests/overlays.html');
 await page.getByRole('button',{name:'Reasoning effort: low',exact:true}).click();
 const low=page.getByRole('option',{name:'Low',exact:true}), high=page.getByRole('option',{name:'High',exact:true});
 await expect(low).toBeFocused();
 await high.hover();
 await expect(page.locator('.picker-row[data-active="true"]')).toHaveCount(1);
 await expect(high).toHaveAttribute('data-active','true');
 expect(await low.evaluate(el=>getComputedStyle(el).backgroundColor)).not.toBe(await high.evaluate(el=>getComputedStyle(el).backgroundColor));
 await low.focus();
 await page.keyboard.press('ArrowDown');
 await expect(high).toBeFocused();
 await expect(low).toHaveAttribute('aria-selected','true');
 // The gallery refreshes option objects every 250 ms, like mission polling.
 await page.waitForTimeout(600);
 await expect(high).toBeFocused();
 await expect(high).toHaveAttribute('data-active','true');
 await page.keyboard.press('Space');
 await expect(page.getByRole('dialog')).toHaveCount(0);
 const trigger=page.getByRole('button',{name:'Reasoning effort: high',exact:true});
 await expect(trigger).toBeFocused();
 await trigger.click();
 await expect(high).toHaveAttribute('aria-selected','true');
 await expect(high).toBeFocused();
 await page.keyboard.press('Home');
 await page.keyboard.press('Enter');
 await expect(page.getByRole('button',{name:'Reasoning effort: Default',exact:true})).toBeFocused();
});

test('Antigravity effort saves, survives reopening and retains the previous value on failure',async({page})=>{
 const mission={id:'antigravity-effort',title:'Antigravity effort check',project:'test',status:'active',backend:'antigravity',model_override:'agy-demo',model_effort:'low' as string|null,history:[],created_at:'',updated_at:''};
 const patches:unknown[]=[];let fail=false;
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','fixture');localStorage.setItem('orb-theme','dark');});
 await page.route('**/api/**',async route=>{
  const request=route.request(), path=new URL(request.url()).pathname;
  if(path.endsWith('/settings') && request.method()==='PATCH'){
   patches.push(request.postDataJSON());
   if(fail)return route.fulfill({status:503,body:'Temporarily unavailable'});
   mission.model_effort=request.postDataJSON().model_effort || null;
   return route.fulfill({json:mission});
  }
  if(path.endsWith('/events'))return route.fulfill({headers:{'X-Orb-Events-Protocol':'1','X-Has-More':'false'},json:[]});
  if(path==='/api/control/stream')return route.fulfill({contentType:'text/event-stream',body:''});
  const json=path==='/api/projects'?{projects:[{slug:'test',title:'Test'}]}
   :path==='/api/backends'?[{id:'antigravity',name:'Antigravity'}]
   :path==='/api/providers/antigravity-models'?{models:[{value:'agy-demo',label:'Argon'}]}
   :path==='/api/control/missions'?[mission]
   :path===`/api/control/missions/${mission.id}`?mission
   :path.endsWith('/queue')?[]
   :path.endsWith('/history')?[]
   :path.endsWith('/files')?{entries:[]}
   :path.endsWith('/crons')?{jobs:[]}
   :{};
  return route.fulfill({json});
 });
 await page.goto('/');
 await page.getByRole('button',{name:'Test',exact:true}).click();
 await page.getByRole('button',{name:/Antigravity effort check/}).click();
 const trigger=()=>page.getByRole('button',{name:/^Reasoning effort:/});
 await expect(trigger()).toHaveAccessibleName('Reasoning effort: Low');
 await trigger().click();
 await expect(page.getByRole('option',{name:'Low',exact:true})).toBeFocused();
 await page.keyboard.press('End');await page.keyboard.press('Enter');
 await expect(trigger()).toHaveAccessibleName('Reasoning effort: High');
 expect(patches).toEqual([{model_effort:'high'}]);
 await trigger().click();
 await expect(page.getByRole('option',{name:'High',exact:true})).toHaveAttribute('aria-selected','true');
 await page.keyboard.press('Escape');
 fail=true;
 await trigger().click();await page.getByRole('option',{name:'Low',exact:true}).click();
 await expect(page.getByRole('alert').first()).toBeVisible();
 await expect(trigger()).toHaveAccessibleName('Reasoning effort: High');
 fail=false;
 await trigger().click();await page.getByRole('option',{name:'Default (High)',exact:true}).click();
 await expect(trigger()).toHaveAccessibleName('Reasoning effort: Default (High)');
 expect(patches.at(-1)).toEqual({model_effort:''});
});

for(const theme of ["dark","light"]) test(`menu focus stays quiet and keyboard navigation works: ${theme}`,async({page})=>{
 await page.goto(`/tests/overlays.html?theme=${theme}&menu-variants=1`);
 await page.getByRole('button',{name:'Choose model',exact:true}).click();
 const search=page.getByRole('combobox');
 await expect(search).toBeFocused();
 await expect(search).toHaveCSS('outline-style','none');
 await expect(search).toHaveCSS('box-shadow','none');
 await page.keyboard.press('ArrowDown');
 await page.keyboard.press('Enter');
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await page.getByRole('button',{name:'Actions',exact:true}).click();
 await page.keyboard.press('ArrowDown');
 await page.keyboard.press('Home');
 const item=page.getByRole('menuitem',{name:'Rename…'});
 await expect(item).toBeFocused();
 await expect(item).toHaveCSS('outline-style','none');
 await expect(item).toHaveCSS('box-shadow','none');
 expect(await item.evaluate(el=>getComputedStyle(el).backgroundColor)).not.toBe('rgba(0, 0, 0, 0)');
 await page.keyboard.press('End');
 const machine=page.getByRole('button',{name:/^Use this machine/,pressed:true});
 await expect(machine).toBeFocused();
 await expect(machine).toHaveCSS('outline-style','none');
 await expect(machine).toHaveCSS('box-shadow','none');
 const program=page.getByRole('menuitemradio',{name:'Default program',exact:true});
 await expect(program).toHaveAttribute('aria-checked','true');
 await expect(program).toHaveCSS('background-color','rgba(0, 0, 0, 0)');
 await page.keyboard.press('ArrowUp');
 await expect(program).toBeFocused();
 await expect(machine).toHaveCSS('background-color','rgba(0, 0, 0, 0)');
 expect(await machine.evaluate(el=>getComputedStyle(el,'::after').content)).toBe('"✓"');
 await expect(program).toHaveCSS('outline-style','none');
 await expect(program).toHaveCSS('box-shadow','none');
 await expect(program).not.toHaveCSS('background-color','rgba(0, 0, 0, 0)');
 await page.keyboard.press('Escape');
 await expect(page.getByRole('button',{name:'Actions',exact:true})).toBeFocused();
 await page.getByRole('button',{name:'Reasoning effort: low',exact:true}).click();
 const low=page.getByRole('option',{name:'Low',exact:true});
 const high=page.getByRole('option',{name:'High',exact:true});
 await expect(low).toBeFocused();
 await expect(low).toHaveCSS('box-shadow','none');
 await page.keyboard.press('ArrowDown');
 await expect(high).toBeFocused();
 await expect(high).toHaveCSS('box-shadow','none');
 await expect(high).toHaveCSS('outline-style','none');
 await expect(low).toHaveAttribute('aria-selected','true');
 await expect(high).toHaveAttribute('aria-selected','false');
 expect(await low.evaluate(el=>getComputedStyle(el).backgroundColor)).not.toBe(await high.evaluate(el=>getComputedStyle(el).backgroundColor));
 await expect(page.getByRole('dialog')).toHaveScreenshot(`picker-focus-${theme}.png`);
 await page.keyboard.press('Escape');
 await expect(page.getByRole('button',{name:'Reasoning effort: low',exact:true})).toBeFocused();
});
