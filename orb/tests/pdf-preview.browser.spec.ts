import { test, expect } from '@playwright/test';
test.use({browserName:'webkit'});
// Small valid two-page document, no external fonts/assets or private content.
function fixture() {
 const objects = ['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
 '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 5 0 R >>',
 '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 6 0 R >>',
 ...['1 0 0 rg 30 30 240 340 re f','0 0 1 rg 30 30 240 340 re f'].map(s=>`<< /Length ${s.length} >>\nstream\n${s}\nendstream`)];
 let pdf='%PDF-1.4\n';const offsets=[0];
 objects.forEach((s,i)=>{offsets.push(pdf.length);pdf+=`${i+1} 0 obj\n${s}\nendobj\n`;});
 const xref=pdf.length;pdf+=`xref\n0 7\n0000000000 65535 f \n${offsets.slice(1).map(n=>`${String(n).padStart(10,'0')} 00000 n \n`).join('')}trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`;
 return [...Buffer.from(pdf)];
}
for(const broken of [false,true]) test(`PDF preview ${broken?'reports damaged documents':'renders pages on demand in WebKit'}`,async({page})=>{
 const bytes=broken?[1,2,3]:fixture(); let downloads=0;
 await page.route('**/api/**',route=>{
  const q=route.request().postDataJSON()??{};
  let json:unknown={};
  if(q.action==='roots')json={sources:[{id:'workspace',label:'Workspace',available:true}]};
  if(q.action==='resolve')json={results:q.paths.map((reference:string)=>({reference,matches:reference.includes('IMPLEMENTATION')?[{name:'sample.pdf',path:'sample.pdf',kind:'file'}]:[]}))};
  if(q.action==='list')json={entries:[{name:'sample.pdf',path:'sample.pdf',kind:'file'}]};
  if(q.action==='read')json={binary:true,size:bytes.length,truncated:false};
  if(q.action==='download'){downloads++;json={bytes,size:bytes.length,next:bytes.length};}
  return route.fulfill({json});
 });
 await page.goto('/tests/file-panel.html');
 await page.getByRole('button',{name:'IMPLEMENTATION-BRIEF.md',exact:true}).click();
 await expect(page.getByRole('button',{name:'View PDF',exact:true})).toBeVisible();expect(downloads).toBe(0);
 await page.getByRole('button',{name:'View PDF',exact:true}).click();
 if(broken)await expect(page.getByRole('alert')).toContainText('Couldn’t display this PDF');
 else {
  await expect(page.locator('.pdf-pages')).toHaveAttribute('aria-busy','false');
  const pixel=()=>page.locator('.pdf-pages canvas').evaluate(c=>Array.from((c as HTMLCanvasElement).getContext('2d')!.getImageData(c.width/2,c.height/2,1,1).data));
  expect(await pixel()).toEqual([255,0,0,255]);
  await page.keyboard.press('End');
  await expect(page.locator('.pdf-pagination')).toContainText('2 / 2');
  await page.keyboard.press('Home');
  await expect(page.locator('.pdf-pagination')).toContainText('1 / 2');
  await page.keyboard.press('PageDown');
  await expect(page.locator('.pdf-pagination')).toContainText('2 / 2');
  await page.keyboard.press('ArrowLeft');
  await expect(page.locator('.pdf-pagination')).toContainText('1 / 2');
  await page.getByRole('textbox',{name:'Draft'}).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('.pdf-pagination')).toContainText('1 / 2');
  await page.getByRole('button',{name:'Next page'}).click();
  await expect(page.locator('.pdf-pagination')).toContainText('2 / 2');
  await expect.poll(pixel).toEqual([0,0,255,255]);
  // Zoom repaints the page at the new scale (backing store tracks CSS size) without moving the viewer.
  const viewer=await page.locator('.pdf-viewer').boundingBox();
  const size=()=>page.locator('.pdf-pages canvas').evaluate(c=>({css:parseFloat((c as HTMLCanvasElement).style.width),px:(c as HTMLCanvasElement).width}));
  const fitted=await size();
  await page.locator('.pdf-viewer').focus();
  await page.keyboard.press('Meta+=');
  await expect(page.locator('.pdf-zoom-level')).toHaveText('125%');
  await expect(page.locator('.pdf-pages')).toHaveAttribute('aria-busy','false');
  await expect.poll(async()=>{const z=await size();return Math.round(z.css/fitted.css*100);}).toBe(125);
  await expect.poll(async()=>{const z=await size();return z.px/z.css;}).toBeCloseTo(fitted.px/fitted.css,1);
  expect(await page.locator('.pdf-viewer').boundingBox()).toEqual(viewer);
  await page.keyboard.press('Meta+0');
  await expect(page.locator('.pdf-zoom-level')).toHaveText('100%');
  await page.locator('.pdf-pages canvas').dblclick();
  await expect(page.locator('.pdf-zoom-level')).not.toHaveText('100%');
  await expect(page.locator('.pdf-pages')).toHaveClass(/is-zoomed/);
  await page.locator('.pdf-pages canvas').dblclick();
  await expect(page.locator('.pdf-zoom-level')).toHaveText('100%');
  // Trackpad pinch: ctrl+wheel zooms in around the pointer.
  const box=(await page.locator('.pdf-pages').boundingBox())!;
  await page.mouse.move(box.x+box.width/2,box.y+100);
  await page.keyboard.down('Control');await page.mouse.wheel(0,-60);await page.keyboard.up('Control');
  await expect.poll(async()=>parseInt(await page.locator('.pdf-zoom-level').innerText())).toBeGreaterThan(100);
  for(const colorScheme of ['light','dark'] as const){await page.emulateMedia({colorScheme});await page.screenshot({path:`test-results/orb-pdf-zoom-${colorScheme}.png`});}
  await page.getByRole('button',{name:'Zoom out'}).click();
  await page.getByRole('button',{name:'Fit width'}).click();
  await expect(page.locator('.pdf-zoom-level')).toHaveText('100%');
 }
 await page.getByRole('button',{name:'Back',exact:true}).click();
 await expect(page.getByRole('button',{name:'View PDF',exact:true})).toBeVisible();
 await expect(page.locator('.pdf-viewer')).toHaveCount(0);
});
