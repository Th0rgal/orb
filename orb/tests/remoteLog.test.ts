import { describe, it, expect } from "vitest";
import { remoteLog } from "../src/remoteLog";
const envelope = "Remote node 'dgx-spark' job 3dff58d2-508c-458e-90c1-701e402a6b5f finished with state 'succeeded' (exit Some(0))\n\nlog tail:\n";
const text = JSON.stringify({type:"text",sessionID:"ses_native",part:{id:"part_1",text:"## Status\n\nRunning and durable."}});
describe("legacy OpenCode remote log", () => {
  it("decodes text after a truncated line and retains the exact log", () => {
    const raw=envelope+'truncated JSON...\n'+text+'\n'+text+'\n'+JSON.stringify({type:"step_finish",sessionID:"ses_native",part:{tokens:{total:38487}}});
    expect(remoteLog(raw)).toEqual({text:"## Status\n\nRunning and durable.",details:raw});
  });
  it("leaves ordinary JSON alone and collapses unrecognized remote logs", () => {
    expect(remoteLog(text)).toEqual({text});
    for(const raw of [envelope+'',envelope+JSON.stringify({event:"step_update",step_update:{state:"DONE"}})]) expect(remoteLog(raw)).toEqual({text:envelope.split('\n\nlog tail:')[0],details:raw});
  });
  it("retains failure status even when the log contains a text part", () => {
    const raw=envelope.replace("'succeeded'", "'failed'")+text;
    expect(remoteLog(raw).text).toContain("'failed'");
    expect(remoteLog(raw).text).toContain("## Status\n");
  });
});

it("preserves successful Markdown links and requested JSON replies", () => {
 for (const answer of ['[documentation](https://example.com)', '{"status":"ok","results":[1,2]}', '[1, 2, 3]']) {
  expect(remoteLog(envelope+answer)).toEqual({text:answer,details:envelope+answer});
 }
 const log='truncated first line...\n'+JSON.stringify({event:'result',result:{status:'SUCCESS',response:'done'}});
 expect(remoteLog(envelope+log)).toEqual({text:envelope.split('\n\nlog tail:')[0],details:envelope+log});
});

it("unwraps successful Claude Markdown while keeping the receipt in details",()=>{
 const answer="- **Depuis quand** : mercredi.\n\nDébit non disponible.";
 expect(remoteLog(envelope+answer)).toEqual({text:answer,details:envelope+answer});
 for(const header of [envelope.replace("'succeeded'","'failed'"),envelope.replace('Some(0)','Some(1)')])expect(remoteLog(header+answer)).toEqual({text:header.split('\n\nlog tail:')[0],details:header+answer});
});

it("collapses truncated Antigravity JSON after a mission pause", () => {
 const header="Remote node 'old-agent' job 7fb1fd5f-fac8-47b1-a17a-62cfc8846222 reached state 'cancelled' (exit None) after the mission left Active (paused); the mission status is preserved.\nerror: cancelled";
 const log=',"parameters":{"CommandLine":"python3 ..."}}\n'+JSON.stringify({event:'step_update',step_update:{state:'DONE',tool_name:'view_file'}})+'\n'+JSON.stringify({event:'result',result:{status:'ERROR',error:'interrupted'}});
 const raw=header+'\n\nlog tail:\n'+log;
 expect(remoteLog(raw)).toEqual({text:header,details:raw});
 expect(remoteLog(raw).text).not.toContain('step_update');
});

it("preserves diagnostics even for non-JSON failures and does not touch ordinary prose", () => {
 const raw=envelope.replace("'succeeded'", "'failed'")+'Traceback: process interrupted';
 expect(remoteLog(raw)).toEqual({text:raw.split('\n\nlog tail:')[0],details:raw});
 const prose='Here is a log tail:\n'+text;
 expect(remoteLog(prose)).toEqual({text:prose});
});
