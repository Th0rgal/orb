import {describe,it,expect} from "vitest";
import {buildTranscript,applyStreamEvent} from "../src/Transcript";
import {storedToStream,type StreamEvent} from "../src/stream";
const event=(type:string,data:Record<string,unknown>):StreamEvent=>({type,data});
describe("interrupted mission evidence",()=>{
 it("preserves partial Codex prose once in replay and live",()=>{
  const text="I’ll make those paths reject unsupported input before the next full run.";
  const rows=[
   {id:1,sequence:4075,event_type:"text_delta",content:text,timestamp:""},
   {id:2,sequence:4076,event_type:"assistant_message",content:text,timestamp:"",metadata:{success:false,resumable:true,completion_evidence:{terminal_reason:"Cancelled"}}},
   {id:3,sequence:4077,event_type:"mission_status_changed",content:"Cancelled by user",timestamp:"",metadata:{status:"interrupted"}}
  ];
  const events=rows.map(storedToStream).filter((e):e is StreamEvent=>!!e);
  const replay=buildTranscript(events);
  let live=buildTranscript([]);for(const e of events)live=applyStreamEvent(live,e);
  expect(live).toEqual(replay);
  expect(replay.filter(i=>i.kind==="text")).toMatchObject([{text,live:false}]);
  expect(replay.filter(i=>i.kind==="error")).toMatchObject([{title:"Mission interrupted",text:expect.stringContaining("interrupted before completion")}]);
  expect(JSON.stringify(replay)).not.toContain("Cancelled by user");
 });
 it("orphan interruption replaces a stale background recovery promise",()=>{
  const text="I will proceed to Round 3 once the test completes.";
  const events=[event("assistant_message",{canonical:true,bubble_id:"antigravity:session:job:893",content:text}),
   event("assistant_message",{content:text+"\n\nCLI error: background task handoff. Recovery scheduled.",success:false}),
   event("mission_status_changed",{status:"active",summary:"Continuing after background task"}),
   event("mission_status_changed",{status:"interrupted",summary:"Interrupted: mission runner exited without reporting a terminal status"})];
  const items=buildTranscript(events);
  expect(items.filter(i=>i.kind==="text")).toHaveLength(1);
  expect(items.filter(i=>i.kind==="error")).toMatchObject([{title:"Mission interrupted",text:"Interrupted: mission runner exited without reporting a terminal status"}]);
  expect(JSON.stringify(items)).not.toContain("Recovery scheduled.");
 });
 it("uses structured stall evidence instead of partial prose as the failure",()=>{
  const items=buildTranscript([event("assistant_message",{content:"Still working.",success:false,completion_evidence:{terminal_reason:"Stalled"}})]);
  expect(items.filter(i=>i.kind==="error")).toMatchObject([{text:expect.stringContaining("no progress"),title:"Mission interrupted"}]);
 });
});
