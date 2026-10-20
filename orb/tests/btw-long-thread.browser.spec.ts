import {test,expect} from '@playwright/test';
test.use({browserName:'webkit'});
test.setTimeout(120000);
// Prod mission 52bbf658: the /btw tab showed an old state of its one thread
// (an older answer, then "Starting side agent…") instead of Core's latest turns.
test('the /btw tab shows the full current server history of a long thread and follows it live',async({page})=>{
 await page.goto('/tests/btw-long-thread.html');
 const thread=page.locator('.btw-panel .btw-thread');
 // The cached tab state reopens the panel.
 await expect(thread).toBeVisible({timeout:75000});
 await expect(thread).toContainText('Où nous en sommes sur la campagne',{timeout:20000});
 await expect(thread).toContainText('redis moi ou nous en sommes');
 await expect(thread).toContainText("Ce qu'on a gagné concrètement");
 await expect(thread).toContainText('Older answer 1.');
 await expect(thread).not.toContainText('Starting side agent');
 await expect(page.locator('.btw-panel [data-side-turn]')).toHaveCount(16);
 // Newest last.
 await expect(page.locator('.btw-panel [data-side-turn]').last()).toContainText('evm.fast-dev');
 // The thread is far longer than one 200-row event page.
 expect(await page.evaluate(()=>(window as any).eventCount)).toBeGreaterThan(400);
 expect((await page.evaluate(()=>(window as any).eventRequests) as string[]).length).toBeGreaterThan(0);
 // Live follow: a turn added on Core shows up without reopening the tab.
 await page.evaluate(()=>(window as any).askOnServer('Q17 live follow','A17 arrives live'));
 await expect(page.locator('.btw-panel [data-side-turn]').last()).toContainText('A17 arrives live',{timeout:20000});
 // After a reload the fixture's Core no longer has Q17 (it is in memory),
 // while the local cache does: Core wins, the cache-only turn disappears.
 await page.reload();
 await expect(thread).toBeVisible({timeout:75000});
 await expect(thread).not.toContainText('A17 arrives live',{timeout:20000});
 await expect(page.locator('.btw-panel [data-side-turn]').last()).toContainText('evm.fast-dev');
 await expect(page.locator('.btw-panel [data-side-turn]')).toHaveCount(16);
});
