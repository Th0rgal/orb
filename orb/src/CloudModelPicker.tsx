import {createEffect,createMemo,createSignal,Show,onCleanup} from 'solid-js';
import {api} from './api';
import {AgentChoice} from './AgentChoice';
import type {CloudProvider,ModelParam} from './cloudAgentApi';
export interface CloudModel {id:string;name?:string;displayName?:string;parameters?:{id:string;displayName?:string;values:{value:string;displayName?:string}[]}[];variants?:{displayName?:string;isDefault?:boolean;params:ModelParam[]}[]}
export function modelChoices(models:CloudModel[]) {
 return models.flatMap(model => {
  const name=model.displayName ?? model.name ?? model.id;
  if(!model.variants?.length)return [{value:JSON.stringify({id:model.id,params:[]}),label:name}];
  return model.variants.map(variant=>{
   const parts=variant.params.filter(p=>p.value!=='false').map(param=>{
    const spec=model.parameters?.find(p=>p.id===param.id);
    return spec?.values.find(v=>v.value===param.value)?.displayName ?? param.value;
   });
   const label=[name,...parts.filter(part=>!name.toLowerCase().includes(part.toLowerCase()))].join(' · ');
   return {value:JSON.stringify({id:model.id,params:variant.params}),label};
  });
 });
}
export function CloudModelPicker(p:{provider:CloudProvider;model:string;params:ModelParam[];disabled?:boolean;onChange:(model:string,params:ModelParam[])=>void;onError:(error:string)=>void;onRepositories?:(repos:{url:string}[])=>void;onRepositoriesLoading?:(loading:boolean)=>void}){
 const provider = createMemo(()=>p.provider);
 const [models,setModels]=createSignal<CloudModel[]>([]),[efforts,setEfforts]=createSignal<{id:string;name?:string;displayName?:string}[]>([]),[open,setOpen]=createSignal<'model'|'effort'|null>(null),[loading,setLoading]=createSignal(true);
 createEffect(()=>{
  const selectedProvider=provider();
  if(selectedProvider==='grok_bot')return;
  let current=true; // provider changes discard late discovery replies
  setModels([]);setEfforts([]);setLoading(true);p.onRepositories?.([]);p.onRepositoriesLoading?.(true);
  void api<{models:{items:CloudModel[]};efforts?:{id:string;name?:string;displayName?:string}[]|{items:{id:string;name?:string;displayName?:string}[]};repositories?:{items:{url:string}[]}}>(`/api/cloud/${selectedProvider==='hermes'?'hermes':selectedProvider==='chatgpt'?'chatgpt':'cursor'}/options`).then(data=>{
   if(!current)return;
   const effortItems=Array.isArray(data.efforts)?data.efforts:(data.efforts?.items ?? []);
   setModels(data.models.items ?? []);
   setEfforts(effortItems);
   p.onRepositories?.(data.repositories?.items ?? []);
   if(!p.model){
    const selected=data.models.items?.find(m=>m.id===(selectedProvider==='hermes'?'':selectedProvider==='chatgpt'?'gpt-6-pro':'default')) ?? data.models.items?.[0];
    if(selected){
     const baseParams=selected.variants?.find(v=>v.isDefault)?.params ?? selected.variants?.[0]?.params ?? [];
     const existingEffort=p.params.filter(x=>x.id==='effort'||x.id==='reasoning_effort');
     p.onChange(selected.id,(effortItems.length && existingEffort.length)?[...baseParams,...existingEffort]:baseParams);
    }
   }
  }).catch(error=>{if(current)p.onError(String(error));}).finally(()=>{if(current){setLoading(false);p.onRepositoriesLoading?.(false);}});
  onCleanup(()=>{current=false;});
 });
 const hasEffortPicker=()=>efforts().length>0;
 const currentEffort=()=>p.params.find(x=>x.id==='effort'||x.id==='reasoning_effort')?.value ?? '';
 const modelParamsOnly=()=>hasEffortPicker()?p.params.filter(x=>x.id!=='effort'&&x.id!=='reasoning_effort'):p.params;
 const value=()=>JSON.stringify({id:p.model,params:modelParamsOnly()});
 const choices=createMemo(()=>{
  const items=modelChoices(models());
  // Keep the recorded model visible even if discovery no longer lists it.
  // Never silently replace the user's selection with another model.
  if(p.model && !items.some(item=>item.value===value())) {
   const name=models().find(model=>model.id===p.model);
   items.unshift({value:value(),label:name?.displayName ?? name?.name ?? p.model});
  }
  return items;
 });
 const effortChoices=createMemo(()=>{
  const items=efforts().map(e=>({value:e.id,label:e.displayName ?? e.name ?? (e.id || 'Default effort')}));
  const cur=currentEffort();
  if(cur && !items.some(i=>i.value===cur)) items.push({value:cur,label:cur});
  return items;
 });
 return <Show when={!loading()} fallback={<button class="model" disabled>Loading models…</button>}>
  <AgentChoice label="Model" value={value()} items={choices()} disabled={p.disabled || !models().length} open={open()==='model'} onOpen={()=>setOpen('model')} onClose={()=>setOpen(null)} onSelect={val=>{const choice=JSON.parse(val);const eff=currentEffort();const nextParams=hasEffortPicker()&&eff?[...choice.params,{id:'effort',value:eff}]:choice.params;p.onChange(choice.id,nextParams);}} searchable/>
  <Show when={hasEffortPicker()}>
   <AgentChoice label="Effort" value={currentEffort()} items={effortChoices()} disabled={p.disabled} open={open()==='effort'} onOpen={()=>setOpen('effort')} onClose={()=>setOpen(null)} onSelect={eff=>{const rest=p.params.filter(x=>x.id!=='effort'&&x.id!=='reasoning_effort');p.onChange(p.model,eff?[...rest,{id:'effort',value:eff}]:rest);}}/>
  </Show>
 </Show>;
}
