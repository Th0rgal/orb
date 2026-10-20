// Offline shape of prod /btw thread 412e22b7 (parent 52bbf658, "Autoresearch-archi"):
// one side mission, 16 question/answer turns, each user message carrying a
// large injected <main_conversation_update> context, tool rows between them,
// and far more events than one 200-row page. The newest turns are the ones a
// stale panel failed to show.
export type FixtureEvent={id:number;sequence:number;event_type:string;timestamp:string;content:string;event_id?:string;tool_call_id?:string|null;tool_name?:string|null;metadata?:Record<string,unknown>};
export const LONG_THREAD_ID='412e22b7-e38e-455e-82b0-27831c26d264';
export const LONG_PARENT_ID='52bbf658-8705-4df7-8510-24dc69aed102';
export const LONG_TURNS:{q:string;a:string}[]=[
 ...Array.from({length:13},(_,i)=>({q:`Older side question ${i+1}`,a:`Older answer ${i+1}.`})),
 {q:'mon agent qui maintient turbo-lean et native-lean m’a dit qu’il allait les refactor',a:'### 1. Faut-il informer le `main` agent maintenant ?\n\nQuoi synchroniser dans le nouveau repo `Th0rgal/research-governor` ?'},
 {q:'tu me dis:\nEn une phrase : Sans turbo-lean, fast-check…',a:"### 1. Ce qu'on a gagné concrètement grâce au Gouverneur\n\nDétails."},
 {q:'redis moi ou nous en sommes et ce qu’il faut dire à mon agent turbo-lean',a:'### 1. Où nous en sommes sur la campagne `evm.fast-dev`\n\nLatest status.'},
];
export function longThreadEvents(turns=LONG_TURNS,toolsPerTurn=11):FixtureEvent[]{
 const out:FixtureEvent[]=[];let seq=0;
 const at=(n:number)=>new Date(Date.UTC(2026,9,20,14,45)+n*60_000).toISOString();
 const push=(event_type:string,content:string,extra:Partial<FixtureEvent>={})=>{seq++;out.push({id:4616812+seq,sequence:seq,event_type,timestamp:at(seq),content,event_id:`e${seq}`,...extra});};
 const context='<main_conversation_update>\n'+'Main agent transcript line with lots of detail.\n'.repeat(110)+'</main_conversation_update>';
 turns.forEach(({q,a})=>{
  push('user_message',`You are the independent /btw agent sharing the main agent's working folder.\n\n${context}\n\nCurrent request:\n${q}\n`,{metadata:{queued:false,source:'api:prod'}});
  push('mission_status_changed','',{metadata:{status:'active'}});
  for(let t=0;t<toolsPerTurn;t++){push('tool_call',JSON.stringify({cmd:'rg x'}),{tool_call_id:`c${seq}`,tool_name:'bash'});push('tool_result','ok',{tool_call_id:`c${seq-1}`,tool_name:'bash'});}
  push('assistant_message',a,{metadata:{success:true}});
  push('mission_status_changed','',{metadata:{status:'completed'}});
 });
 return out;
}
export function longThreadMission(status='completed'){
 const last=longThreadEvents().at(-1)!.timestamp;
 return {id:LONG_THREAD_ID,title:'Autoresearch-archi · btw',backend:'opencode',model_override:'builtin/smart',status,history:[],created_at:'2026-10-20T14:45:22Z',updated_at:last,last_activity_at:last,project:'Assistant',tags:[`fork-workspace:${LONG_PARENT_ID}`,`btw-parent:${LONG_PARENT_ID}`]};
}
const TRANSCRIPT=new Set(['user_message','assistant_message','assistant_message_canonical']);
/** The backend's event paging: `limit` rows (default 200), newest page without
 * a cursor, exclusive since/before cursors, view=transcript, X-Has-More. */
export function pagedEvents(query:URLSearchParams,events:readonly FixtureEvent[]){
 const since=query.get('since_seq'),before=query.get('before_seq'),limit=Number(query.get('limit')??'200')||200;
 const viewed=query.get('view')==='transcript'?events.filter(e=>TRANSCRIPT.has(e.event_type)):events;
 const matching=viewed.filter(e=>(since===null||e.sequence>Number(since))&&(before===null||e.sequence<Number(before)));
 const page=since!==null?matching.slice(0,limit):matching.slice(-limit);
 const seqs=page.map(e=>e.sequence),all=events.map(e=>e.sequence);
 const headers:Record<string,string>={'Access-Control-Expose-Headers':'X-Orb-Events-Protocol, X-Has-More, X-Max-Sequence, X-Next-Cursor, X-Page-Max-Sequence','X-Orb-Events-Protocol':'1','X-Has-More':String(matching.length>page.length),'X-Max-Sequence':String(all.length?Math.max(...all):0)};
 if(seqs.length){headers['X-Page-Max-Sequence']=String(Math.max(...seqs));headers['X-Next-Cursor']=String(since===null?Math.min(...seqs):Math.max(...seqs));}
 return {json:page,headers};
}
