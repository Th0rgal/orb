import {eventPage} from "./eventPageFixture";
import { test, expect } from "@playwright/test";
import { writeFileSync } from "node:fs";
test("long transcript DOM benchmark retains expanded work",async({page})=>{
 await page.goto(`/tests/transcript.html${process.env.ORB_BENCHMARK_BASELINE ? "?baseline" : ""}`);
 await expect(page.locator(".st-work").first()).toBeVisible();
 if(!process.env.ORB_BENCHMARK_BASELINE)expect(await page.locator(".st-work").count()).toBeLessThan(40);
 const result=await page.evaluate(()=> (window as any).transcriptHarness.benchmark());
 console.log("TRANSCRIPT_BENCHMARK",JSON.stringify(result));
 writeFileSync(`test-results/transcript-${process.env.ORB_BENCHMARK_BASELINE ? "before" : "after"}.json`,JSON.stringify(result,null,2));
 if(!process.env.ORB_BENCHMARK_BASELINE){expect(result.foldRetained).toBe(true);expect(result.foldOpen).toBe(true);expect(result.removed).toBeLessThan(500);}
});

test("cumulative live text across tools renders once and preserves open tool details",async({page})=>{
 await page.goto("/tests/transcript.html");
 await page.waitForFunction(()=>!!(window as any).transcriptHarness);
 await page.evaluate(()=> (window as any).transcriptHarness.reset([
  {type:"text_op",data:{bubble_id:"text_delta_latest",ops:[{type:"insert",pos:0,text:"Inspect file."}]}},
  {type:"tool_call",data:{tool_call_id:"a",name:"read",args:{path:"guard.ts"}}},
  {type:"tool_result",data:{tool_call_id:"a",result:"Complete"}}
 ]));
 await page.locator(".st-work-head").click();await page.locator(".st-tool-head").click();
 await page.evaluate(()=> (window as any).transcriptHarness.apply({type:"text_op",data:{bubble_id:"text_delta_latest",ops:[{type:"replace",range:[0,13],text:"Inspect file. Fix guard."}]}}));
 await expect(page.locator(".st-text")).toHaveCount(1);
 await expect(page.locator(".st-text")).toHaveText("Inspect file. Fix guard.");
 await expect(page.locator(".st-caret")).toHaveCount(0);
 await expect(page.locator(".st-work-body")).toBeVisible();await expect(page.locator(".st-tool-detail")).toBeVisible();
 await page.evaluate(()=> (window as any).transcriptHarness.apply({type:"assistant_message",data:{id:"final",content:"Fixed the guard."}}));
 await expect(page.locator(".st-text")).toHaveCount(1);await expect(page.locator(".st-caret")).toHaveCount(0);
 await expect(page.locator(".st-tool-detail")).toBeVisible();
 await page.evaluate(()=> (window as any).transcriptHarness.reset([
  {type:"tool_call",data:{tool_call_id:"a",name:"read",args:{path:"guard.ts"}}},
  {type:"tool_result",data:{tool_call_id:"a",result:"Complete"}},
  {type:"assistant_message",data:{id:"final",content:"Fixed the guard."}}
 ]));
 await expect(page.locator(".st-text")).toHaveCount(1);
 await expect(page.locator(".st-work-body")).toBeVisible();await expect(page.locator(".st-tool-detail")).toBeVisible();
  await page.screenshot({path:"test-results/orb-stream-reconciled.png"});
});

test("native Grok canary final assistant_message then text_delta renders once",async({page})=>{
  const events=(await import("./fixtures/native-canary-events.json",{with:{type:"json"}})).default;
  await page.addInitScript(()=>{localStorage.setItem("orb.apiUrl",location.origin);localStorage.setItem("orb.jwt","test");localStorage.setItem("orb-theme","dark");});
  const mission={id:"44584615-b118-45c4-a4e7-299c2ab1a153",title:"Orb native Grok launch verification",status:"completed",history:[],workspace_name:"host",remote_node_id:"dgx-spark",created_at:"",updated_at:""};
  await page.route("**/api/**",async route=>{
    const path=new URL(route.request().url()).pathname;
    const json=path==="/api/projects"?{projects:[{slug:"test",title:"test"}]}
      :path==="/api/control/missions"&&new URL(route.request().url()).searchParams.get("project")==="test"?[mission]
      :path==="/api/control/missions/44584615-b118-45c4-a4e7-299c2ab1a153"?mission
      :path.endsWith("/events")?events
      :path==="/api/control/stream"?undefined
      :path.endsWith("/files")?{entries:[]}
      :path.endsWith("/crons")?{jobs:[]}
      :path.endsWith("/controller")?{job:null,runs:[]}
      :[];
    if(path==="/api/control/stream")return route.fulfill({contentType:"text/event-stream",body:""});
    return route.fulfill(path.endsWith("/events")?eventPage(route,Array.isArray(json)?json:[]):{json});
  });
  await page.goto("/");
  await page.getByRole("button",{name:"test",exact:true}).click();
  await page.getByRole("button",{name:/Orb native Grok launch verification/}).click();
  await expect(page.locator(".tb-title")).toContainText("Orb native Grok launch verification");
  await expect(page.locator(".tb-title")).not.toHaveText(/^Mission$/);
  await expect(page.locator(".st-text")).toHaveCount(1);
  await expect(page.locator(".st-text")).toContainText("ORB_PROD_NATIVE_GROK_OK");
  await expect(page.locator(".st-text")).toContainText("spark-de79");
  await page.screenshot({path:"test-results/orb-native-canary-once.png"});
});

test("legacy OpenCode results render as Markdown with the raw log folded away",async({page})=>{
 await page.goto("/tests/transcript.html");await page.waitForFunction(()=>!!(window as any).transcriptHarness);
 await page.evaluate(()=>{
  const raw="Remote node 'dgx-spark' job 3dff58d2-508c-458e-90c1-701e402a6b5f finished with state 'succeeded' (exit Some(0))\n\nlog tail:\ntruncated first line...\n"+JSON.stringify({type:"text",sessionID:"ses_native",part:{id:"part_1",text:"## Status\n\nRunning and durable."}});
  (window as any).transcriptHarness.reset([{type:"assistant_message",data:{content:raw}}]);
 });
 await expect(page.getByRole("heading",{name:"Status"})).toBeVisible();await expect(page.locator(".legacy-log pre")).toBeHidden();
 await page.getByText("Original execution log").click();await expect(page.locator(".legacy-log pre")).toContainText('"sessionID":"ses_native"');
});

test("successful remote receipt is collapsed beneath the human reply",async({page})=>{
 await page.goto('/tests/transcript.html');
 await page.waitForFunction(()=>!!(window as any).transcriptHarness);
 const receipt="Remote node 'dgx-spark' job ab58d8b5-e1b4-4652-a5c0-9a0e37e0bb97 finished with state 'succeeded' (exit Some(0))\n\nlog tail:\n**Depuis quand** : mercredi.";
 await page.evaluate(text=>(window as any).transcriptHarness.reset([{type:'assistant_message',data:{content:text}}]),receipt);
 await expect(page.locator('.legacy-log')).toHaveCount(1);
 await expect(page.locator('.legacy-log pre')).not.toBeVisible();
 await expect(page.locator('.st-text')).toContainText('Depuis quand');
 await page.locator('.legacy-log summary').click();
 await expect(page.locator('.legacy-log pre')).toHaveText(receipt);
});

test('paused Antigravity receipt keeps raw JSON collapsed',async({page})=>{
 await page.goto('/tests/transcript.html');
 await page.waitForFunction(()=>!!(window as any).transcriptHarness);
 const header="Remote node 'old-agent' job 7fb1fd5f-fac8-47b1-a17a-62cfc8846222 reached state 'cancelled' (exit None) after the mission left Active (paused); the mission status is preserved.\nerror: cancelled";
 const receipt=header+'\n\nlog tail:\n'+',"parameters":{"CommandLine":"python3 ..."}}\n'+JSON.stringify({event:'step_update',step_update:{state:'DONE',tool_name:'view_file'}});
 await page.evaluate(text=>(window as any).transcriptHarness.reset([{type:'assistant_message',data:{content:text}}]),receipt);
 await expect(page.locator('.st-text .md')).toHaveText(header.replace('\n',' '));
 await expect(page.locator('.legacy-log pre')).toBeHidden();
 await expect(page.locator('.legacy-log')).not.toHaveAttribute('open','');
 await page.locator('.legacy-log summary').click();
 await expect(page.locator('.legacy-log pre')).toHaveText(receipt);
 await page.locator('.legacy-log summary').click();
 await expect(page.locator('.legacy-log pre')).toBeHidden();
});

test('action details expand above their trigger without moving it off screen',async({page})=>{
 await page.goto('/tests/transcript.html');
 await page.waitForFunction(()=>!!(window as any).transcriptHarness);
 await page.evaluate(()=> (window as any).transcriptHarness.reset([
  {type:'user_message',data:{content:'Earlier context\n'.repeat(70)}},
  {type:'tool_call',data:{tool_call_id:'a',name:'webfetch',args:{url:'https://example.test'}}},
  {type:'tool_result',data:{tool_call_id:'a',result:'Details\n'.repeat(30)}},
  {type:'assistant_message',data:{content:'Finished'}}
 ]));
 const fold=page.locator('.st-work-head');
 await fold.scrollIntoViewIfNeeded();
 const before=await fold.boundingBox();await fold.click();
 await expect(fold).toHaveAttribute('aria-expanded','true');
 await page.waitForTimeout(50);
 const after=await fold.boundingBox();const body=await page.locator('.st-work-body').boundingBox();
 expect(body!.y+body!.height).toBeLessThanOrEqual(after!.y+1);
 expect(Math.abs(after!.y-before!.y)).toBeLessThan(3);
 const tool=page.locator('.st-tool-head');await tool.click();
 await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const detail=await page.locator('.st-tool-detail').boundingBox();const trigger=await tool.boundingBox();
 expect(detail!.y+detail!.height).toBeLessThanOrEqual(trigger!.y+1);
});


test("Gemini progress survives persisted snapshot refreshes",async({page})=>{
 await page.goto("/tests/transcript.html");
 await page.waitForFunction(()=>!!(window as any).transcriptHarness);
 const first={type:"text_delta",eventId:"text_delta_latest",storedId:700,sequence:100,data:{content:"Checking proofs."}};
 const latest={...first,sequence:104,data:{content:"Checking proofs. Compilation finished."}};
 const tool={type:"tool_call",data:{tool_call_id:"proof",name:"bash",args:{command:"lake build"}}};
 await page.evaluate(events=>(window as any).transcriptHarness.reset(events),[first,tool]);
 await page.evaluate(event=>(window as any).transcriptHarness.apply(event),{type:"text_delta",data:latest.data});
 await expect(page.locator(".st-text")).toHaveText(latest.data.content);
 // Periodic recovery rebuilds cached history plus newly persisted revisions.
 await page.evaluate(events=>(window as any).transcriptHarness.reset(events),[first,tool,latest]);
 await expect(page.locator(".st-text")).toHaveText(latest.data.content);
  await page.evaluate(events=>(window as any).transcriptHarness.reset(events),[first,tool,latest,first]);
  await expect(page.locator(".st-text")).toHaveText(latest.data.content);
});

test("OpenCode / Cursor-styled tool components, diff badges, collapsible & dismissible Tasks, and nested Markdown lists render cleanly",async({page})=>{
  await page.goto("/tests/transcript.html");
  await page.waitForFunction(()=>!!(window as any).transcriptHarness);
  await page.evaluate(()=> (window as any).transcriptHarness.reset([
    {type:"user_message",data:{id:"u1",content:"Refactor Transcript.tsx and verify nested Markdown lists."}},
    {type:"thinking",data:{content:"Inspecting `src/Transcript.tsx` and **workModel**.",done:true}},
    {type:"tool_call",data:{tool_call_id:"t-read",name:"read",args:{filePath:"src/Transcript.tsx",offset:1,limit:120}}},
    {type:"tool_result",data:{tool_call_id:"t-read",name:"read",result:"1: import ..."}},
    {type:"tool_call",data:{tool_call_id:"t-edit",name:"edit",args:{filePath:"src/Transcript.tsx",oldString:"old line 1\nold line 2",newString:"new line 1\nnew line 2\nnew line 3\nnew line 4"}}},
    {type:"tool_result",data:{tool_call_id:"t-edit",name:"edit",result:"Edit applied successfully."}},
    {type:"tool_call",data:{tool_call_id:"t-bash",name:"bash",args:{command:"pnpm test && pnpm build"}}},
    {type:"tool_result",data:{tool_call_id:"t-bash",name:"bash",result:"✓ 94 tests passed\n✓ built in 4.2s"}},
    {type:"tool_call",data:{tool_call_id:"t-todo",name:"todowrite",args:{todos:[
      {content:"Inspect OpenCode & Cursor components",status:"completed",priority:"high"},
      {content:"Remove redundant bottom Tasks button & add dismiss button",status:"completed",priority:"high"},
      {content:"Fix nested Markdown lists in FilePanel",status:"completed",priority:"high"}
    ]}}},
    {type:"tool_result",data:{tool_call_id:"t-todo",name:"todowrite",result:"ok"}},
    {type:"assistant_message",data:{id:"a1",content:[
      "### 2.2 Assumptions That Mask a Code / Logic Edge Case",
      "1. **Assumption `A7` (No mid-epoch APR setter call) in `APR-1` (`CE-APR-1`)**:",
      "   - **What it masks**: On `54502d1`, `IdleCreditVault.setApr` and `setAprs` do not check `!isEpochRunning`.",
      "   - **Client view**: Agreed that APR should stay fixed during a fixed-rate epoch.",
      "   - **Recommendation**: Guard `setApr`, `setAprs`, and `setMaxApr`.",
      "2. **Checkpoint Coherence `A-P1` Across Mid-Epoch Deposits (`CE-4`)**:",
      "   - **What it masks**: `depositDuringEpoch` mints shares while adding only `amount` to `lastNAVAA/BB`.",
      "   - **PoC for William (`tests/solidity/Price1DepositDuringEpoch.t.sol`)**:",
      "     - `test_CE_4_forcedAccountingAfterMidEpochDepositLowersPriceAA`: lowers `priceAA` by 1-wei rounding.",
      "     - `test_CE_4_materialDropWithJuniorAdjustment`: lowers `priceAA` by > 1 bp (~6.9 bps)."
    ].join("\n")}}
  ]));
  await expect(page.locator(".st-work-head .st-diff-add")).toHaveText("+4");
  await expect(page.locator(".st-work-head .st-diff-del")).toHaveText("-2");
  await page.locator(".st-work-head").click();
  await page.locator(".st-tool-head", { hasText: "bash" }).click();
  await expect(page.locator(".st-bash-cmd")).toHaveText("$ pnpm test && pnpm build");
  await expect(page.locator(".mission-tasks")).toContainText("3/3 completed");
  await expect(page.locator(".tasks-dismiss")).toBeVisible();
  await expect(page.locator(".st-text ol > li")).toHaveCount(2);
  await expect(page.locator(".st-text ol > li").first().locator("ul > li")).toHaveCount(3);
  await page.screenshot({path:"test-results/orb-components-cursor-style.png", fullPage: true});
  await page.locator(".tasks-dismiss").click();
  await expect(page.locator(".mission-tasks")).toHaveCount(0);
});
