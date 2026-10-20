import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test.setTimeout(120000);
test('the /btw tab shows every thread in order and a new answer on a completed thread live',async({page})=>{
 await page.goto('/tests/btw-threads.html');
 const input=page.locator('.composer textarea').first();
 await expect(input).toBeVisible({timeout:75000});
 await input.pressSequentially('/btw');
 await input.press('Enter');
 const thread=page.locator('.btw-thread');
 // History across threads, in the order the questions were asked.
 await expect(thread).toContainText('A4',{timeout:15000});
 const order=async()=>(await thread.textContent())!.match(/Q\d/g);
 expect(await order()).toEqual(['Q1','Q2','Q3','Q4']);
 // A question asked on the completed newest thread (another device): its
 // answer appears without reopening the tab.
 await page.evaluate(()=>(window as any).askOnServer('newest','Q5 consensus plan','A5 the plan'));
 await expect(thread).toContainText('A5 the plan',{timeout:10000});
 expect(await order()).toEqual(['Q1','Q2','Q3','Q4','Q5']);
});
