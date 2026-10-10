import { test, expect } from '@playwright/test';

test('Muse Code stays a subscription and explains an inactive account', async ({page}) => {
  await page.addInitScript(() => {
    localStorage.setItem('orb.apiUrl', location.origin);
    localStorage.setItem('orb.jwt', 'test');
  });
  const submissions: unknown[] = [];
  await page.route('**/api/**', route => {
    const req = route.request(), path = new URL(req.url()).pathname;
    let body: unknown = [];
    if (path === '/api/ai/providers/cli-proxy-login') {
      if (req.method() === 'POST') {
        submissions.push(req.postDataJSON());
        body = {session_id:'muse-test',auth_url:'https://auth.meta.com/oauth/device/',flow:'device',instructions:'Approve the code in your browser.'};
      } else body = {available:true,providers:[{id:'muse-code',name:'Muse Code'}]};
    } else if (path === '/api/ai/providers/cli-proxy-login/muse-test') {
      body = {status:'failed',message:'This Meta account has no active Muse Code subscription. No API billing fallback was enabled.'};
    } else if (path === '/api/projects') body = {projects:[]};
    return route.fulfill({json:body});
  });
  // The actual provider page uses the native browser opener. Keep this fixture
  // on the dialog so it tests the error and does not contact a real account.
  await page.addInitScript(() => { window.open = () => null; });
  await page.goto('/');
  await page.getByRole('button', {name:'Providers',exact:true}).click();
  await page.getByRole('button', {name:'Add subscription account'}).click();
  await page.getByRole('radio', {name:/Muse Code/}).click();
  await page.getByRole('button', {name:'Continue in browser'}).click();
  await expect(page.getByRole('dialog')).toContainText('no active Muse Code subscription');
  await expect(page.getByRole('dialog').getByRole('textbox')).toHaveCount(0);
  expect(submissions).toEqual([{provider:'muse-code'}]);
});
