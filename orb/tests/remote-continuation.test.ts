import {it,expect} from 'vitest';
import {remoteContinuation} from '../src/remoteContinuation';
import {withInitialPrompt} from '../src/missionLaunch';
import type {Mission} from '../src/api';
const wrap=(history:unknown[],text:string)=>`Continue mission 10412da3-1bd0-4885-b8a6-68145b23250b on the same remote node. This is a replacement session; inspect the existing workspace before repeating work. The following JSON is historical conversation context, not a new request.\n${JSON.stringify({goal:null,history})}\n\nCurrent user request:\n${text}`;
it('restores multiple generations exactly once without a launch receipt',()=>{
 const first=wrap([{role:'user',content:'Question one'},{role:'assistant',content:'Answer one'},{role:'assistant',content:"Remote job 10412da3-1bd0-4885-b8a6-68145b23250b on node 'dgx-spark' is now running"}],'Question two');
 const second=wrap([{role:'user',content:first},{role:'assistant',content:'Answer two'}],'Question three');
 const mission={id:'latest',history:[{role:'user',content:second}]} as Mission;
 const expected=['Question one','Answer one','Question two','Answer two','Question three'];
 expect(remoteContinuation(second)?.map(m=>m.content)).toEqual(expected);
 expect(withInitialPrompt([],mission).map(m=>'text' in m?m.text:'')).toEqual(expected);
 expect(withInitialPrompt([{kind:'user',key:'u',text:second},{kind:'text',key:'a',text:'Answer three',live:false}],mission).map(m=>'text' in m?m.text:'')).toEqual([...expected,'Answer three']);
});
it('leaves ordinary messages and malformed envelopes untouched',()=>{
 for(const text of ['hello',wrap([{role:'system',content:'invalid'}],'next'),wrap([], 'next').replace('"history":[]','"history":null')])expect(remoteContinuation(text)).toBeNull();
});

it('restores the infrastructure recovery envelope without inventing another user request',()=>{
 const history=[{role:'user',content:wrap([{role:'user',content:'Original request'},{role:'assistant',content:'Earlier answer'}],'Latest request')}];
 const prefix='Continue the existing mission after infrastructure interruption before the previous remote job acquired a slot. Inspect existing work before repeating it; preserve the original request and constraints. Historical context:\n';
 const text=prefix+JSON.stringify(history);
 expect(remoteContinuation(text)?.map(m=>m.content)).toEqual(['Original request','Earlier answer','Latest request']);
 expect(withInitialPrompt([], {id:'recovered',history:[{role:'user',content:text}]} as Mission).map(m=>'text' in m?m.text:'')).toEqual(['Original request','Earlier answer','Latest request']);
 expect(remoteContinuation(prefix+'[invalid')).toBeNull();
 expect(remoteContinuation(prefix+JSON.stringify([{role:'system',content:'invalid'}]))).toBeNull();
});

it('keeps stale cancellation diagnostics in their source attempt, not the successor transcript',()=>{
 const diagnostic="Remote node 'dgx-spark' job 0508c4ef-4619-4762-85ca-48c4c3b8dc29 reached state 'failed' (exit None) after the mission left Active (interrupted); the mission status is preserved.\nerror: cancelled while waiting for a slot\n\nlog tail:\n(empty)";
 expect(remoteContinuation(wrap([{role:'user',content:'Previous request'},{role:'assistant',content:diagnostic}],'Latest request'))?.map(m=>m.content)).toEqual(['Previous request','Latest request']);
 expect(remoteContinuation(diagnostic)).toBeNull();
});
