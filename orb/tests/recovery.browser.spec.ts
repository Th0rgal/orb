import {test,expect} from '@playwright/test';
for(const theme of ['dark','light'])test(`recovery is clear and keyboard accessible in ${theme}`,async({page},info)=>{
 await page.setViewportSize({width:390,height:700});
 await page.goto(`/tests/recovery.html?theme=${theme}`);
 await expect(page.getByRole('status')).toContainText('Recovery scheduled');
 await expect(page.getByRole('status')).toContainText('attempt 3/12');
 await expect(page.locator('.error-notice')).toHaveCount(0);
 await expect(page.locator('.user')).toHaveCount(0);
 await expect(page.locator('details')).not.toHaveAttribute('open','');
 expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
 await page.screenshot({path:info.outputPath(`recovery-${theme}.png`)});
 await page.getByRole('button',{name:'Resume now'}).focus();
 await page.keyboard.press('Tab');
 await expect(page.getByRole('button',{name:'Cancel recovery'})).toBeFocused();
 await page.keyboard.press('Enter');
 await expect(page.getByRole('status')).toContainText('Paused');
 await expect(page.getByRole('button',{name:'Resume now'})).toHaveCount(0);
 await page.reload();
 await page.getByRole('button',{name:'Resume now'}).click();
 await expect(page.getByRole('status')).toHaveCount(0);
 await page.getByText('Agent resumed automatically',{exact:true}).click();
 await expect(page.locator('details')).toHaveAttribute('open','');
});

for(const [scenario,label] of [['reconnecting','Reconnecting'],['policy','Blocked by provider']])test(`${scenario} explains the next step without a false retry`,async({page})=>{
 await page.setViewportSize({width:390,height:700});
 await page.goto(`/tests/recovery.html?scenario=${scenario}`);
 await expect(page.getByText(label,{exact:false}).first()).toBeVisible();
 await expect(page.getByRole('button',{name:'Cancel recovery'})).toHaveCount(0);
 await expect(page.getByRole('button',{name:'Resume now'})).toHaveCount(0);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
