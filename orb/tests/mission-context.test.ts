import {expect,it,vi} from 'vitest';
import {estimateTokens} from '../src/missionContext';
import type {StreamItem} from '../src/transcriptModel';

it('reuses historical payload counts while receiving new output',()=>{
 const serialize=vi.fn(()=>({output:'x'.repeat(100_000)}));
 const result={toJSON:serialize};
 const tool:StreamItem={kind:'tool',key:'tool',callId:'tool',name:'Read',args:{path:'/workspace'},result,done:true};
 const first=estimateTokens([tool,{kind:'text',key:'reply',text:'abcd',live:true}]);
 expect(estimateTokens([tool,{kind:'text',key:'reply',text:'abcdefgh',live:true}])).toBe(first+1);
 expect(serialize).toHaveBeenCalledTimes(1);
 expect(estimateTokens([{...tool,result:'ok'}])).toBeLessThan(first);
});

it('keeps the existing caps and includes current user and reasoning text',()=>{
 expect(estimateTokens([
  {kind:'user',key:'u',text:'abcd'},
  {kind:'think',key:'t',text:'x'.repeat(9000),done:true},
  {kind:'tool',key:'r',callId:'r',name:'Read',args:'x'.repeat(900),result:'y'.repeat(900),done:true},
 ])).toBe((4+8000+4+400+400)/4);
});
