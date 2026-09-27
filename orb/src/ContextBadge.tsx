import {createSignal,onCleanup,onMount,Show} from 'solid-js';
import {subscribeProjectContext,contextConflicts} from './projectContext';
import {getApiUrl,getJwt,connectionVersion} from './api';
import {nativeInvoke} from './clientRuns';
export function ContextBadge(p:{slug:string}){
 const[label,setLabel]=createSignal(''),[detail,setDetail]=createSignal(''),[expanded,setExpanded]=createSignal(false);
 let disposed=false;
 const refresh=async()=>{
  const version=connectionVersion(),slug=p.slug;
  let label='',detail='';
  try {
   const conflicts=await contextConflicts(p.slug);const count=Object.keys(conflicts).length;
   if(count){label=`${count} context conflict${count===1?'':'s'}`;detail=Object.values(conflicts).map(op=>op.path).join('\n');}
  }catch(error){label='Context unavailable';detail=String(error);}
  const invoke=nativeInvoke();
  if(invoke)try{
   const result=await invoke('project_context_status',{request:{endpoint:getApiUrl(),token:getJwt()??'',project:p.slug}}) as {state:{initialized:boolean;pending:unknown[];error?:string}};
   if(result.state.initialized && result.state.error){label=label||'Context sync pending';detail=[detail,result.state.error,`${result.state.pending.length} local changes queued`].filter(Boolean).join('\n');}
   else if(result.state.pending.length){label=label||'Syncing context…';}
  }catch(error){label=label||'Context unavailable';detail=[detail,String(error)].filter(Boolean).join('\n');}
  if(!disposed && version===connectionVersion() && slug===p.slug){setLabel(label);setDetail(detail);}
 };
 onMount(()=>{void refresh();const stop=subscribeProjectContext(p.slug,()=>void refresh(),error=>setDetail(String(error)));onCleanup(()=>{disposed=true;stop();});});
 return <Show when={label()}><div class="context-sync-state"><button class="s-btn" aria-expanded={expanded()} onClick={event=>{event.stopPropagation();setExpanded(!expanded());}}>{label()}</button><Show when={expanded()}><div class="context-sync-detail">{detail()||'Changes are being synchronized.'}</div></Show></div></Show>;
}
