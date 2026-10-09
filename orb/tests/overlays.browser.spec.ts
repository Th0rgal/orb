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
