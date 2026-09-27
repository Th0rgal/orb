import {test,expect} from '@playwright/test';
test('edited message uses the same @ suggestions, preserves surrounding text and sends the chosen reference',async({page})=>{
 await page.addInitScript(()=>{localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');});
 await page.route('**/api/**',route=>{const url=new URL(route.request().url());return route.fulfill({json:url.pathname.endsWith('/manifest')?{revision:1,entries:{'context/AGENTS.md':{hash:'x',revision:1,size:3,directory:false}}}:url.pathname.endsWith('/controller')?{job:null}:url.pathname.endsWith('/files')?{entries:[]}:[]});});
 await page.goto('/tests/prompt-mentions.html');await page.getByRole('button',{name:'Edit prompt',exact:true}).click();
 const editor=page.getByRole('textbox',{name:'Edit prompt text'});await editor.fill('Read @AG');
 await expect(page.getByRole('listbox',{name:'Context'})).toBeVisible();await editor.press('Enter');
 await expect(editor).toHaveValue('Read @context/AGENTS.md ');await expect(editor).toBeFocused();
 await editor.press('Control+Enter');await expect(page.locator('output')).toHaveText('Read @context/AGENTS.md');
});
