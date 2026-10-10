import { Menu } from "./Menu";
import { createEffect, createResource, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import { api, connectionVersion, type Mission } from "./api";
import "./cyberAccess.css";
export type CyberMode = "standard" | "daybreak" | "automatic";
export interface CyberSelection { mode: CyberMode; status: "requested" | "confirmed"; confirmed_program?: string | null; confirmed_model?: string | null; revision: string }
export const [draftCyber, setDraftCyber] = createSignal<CyberMode>("standard");
export const cyberLabels: Record<CyberMode,string> = {standard:"Standard",daybreak:"Daybreak",automatic:"Automatic"};
export function cyberCompatibility(mode:CyberMode, model:string):string|undefined {
 const id=model.split('/').at(-1)??model;
 if(mode==='standard'&&(id.startsWith('gpt-daybreak-')||id==='gpt-5.6-cyber'))return 'This model requires Daybreak. Choose Daybreak or Automatic, or change the model.';
 if(mode==='daybreak'&&!['gpt-6.1-sol','gpt-6-astra','gpt-6-sol','gpt-5.6-sol','gpt-daybreak-blue-latest','gpt-daybreak-red-latest','gpt-5.6-cyber'].includes(id))return 'Daybreak support has not been established for this model.';
}
export function cyberError(error:unknown):string {
 const text=error instanceof Error?error.message:String(error);
 if(text.includes('access_program_not_enabled'))return 'Daybreak is not enabled for this account and model. Check the account’s approved access, or explicitly select Standard. The model was not changed.';
 if(text.includes('unsupported_access_program'))return 'This connection cannot apply the requested cyber program. Choose another supported connection, or explicitly select Automatic. '+text;
 if(text.includes('invalid_access_program'))return 'The selected cyber program is incompatible with this model. Choose another program or model.';
 if(text.includes('cyberPolicy')||text.includes('cyber_policy'))return 'OpenAI rejected this request under its cyber policy. This can also happen with Daybreak enabled. '+text;
 return text;
}
export const getCyber=async(id:string)=>{await requireCyberSupport();return api<CyberSelection>(`/api/control/missions/${id}/cyber`,{cache:"no-store"});};
export const saveCyber=(id:string,mode:CyberMode)=>api<CyberSelection>(`/api/control/missions/${id}/cyber`,{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode})});
export function CyberPicker(p:{value:CyberMode;model:string;disabled?:boolean;remote?:boolean;note?:string;confirmed?:boolean;onChange:(mode:CyberMode)=>void}) {
 const [open,setOpen]=createSignal(false);let root:HTMLDivElement|undefined;
 const [route,{refetch:refetchRoute}]=createResource(()=>p.remote?[connectionVersion(),p.model] as const:false,async([,model])=>{
  const modes=['standard','daybreak'] as const;
  const supported=await Promise.all(modes.map(async mode=>{
   const value=await api<{route_supported?:boolean}>(`/api/control/cyber-capabilities?model=${encodeURIComponent(model)}&mode=${mode}&remote=true`,{cache:"no-store"});
   return value.route_supported===true;
  }));
  return {standard:supported[0],daybreak:supported[1]};
 });
 const routeRefusal=(mode:CyberMode)=>p.remote&&mode!=='automatic'&&(route.error||route()?.[mode]!==true)
  ?(route.error?'Could not check the Cyber route. Reopen this menu to retry.':route.loading?'Checking the selected Cyber route…':'This remote route cannot guarantee the selected Cyber program. Choose Automatic explicitly or a direct OpenAI route.'):undefined;

 return <div class="cyber-picker model-wrap under-model-wrap" ref={root}>
  <button class={`model under-model cyber-pill ${p.confirmed&&p.value==='daybreak'?'confirmed':''}`} type="button" aria-label={`Cyber program: ${cyberLabels[p.value]}`} aria-haspopup="menu" aria-expanded={open()} title={`Cyber: ${cyberLabels[p.value]}${p.value==='daybreak'?(p.confirmed?' (active)':' (requested)'):''}. ${p.note??'Choose a cyber program.'}`} onClick={()=>{if(!open()&&p.remote)void refetchRoute();setOpen(!open());}}>
   <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M12 3 4 6v6c0 4 5 8 8 9 3-1 8-5 8-9V6z"/></svg>
  </button>
  <Show when={open()}><Menu class="under-model-menu cyber-menu" label="Cyber program" placement="top-start" onClose={() => setOpen(false)}>
   <For each={['standard','daybreak','automatic'] as CyberMode[]}>{mode=><button role="menuitemradio" aria-checked={p.value===mode} class={`menu-item ${p.value===mode?'on':''}`} disabled={p.disabled||!!cyberCompatibility(mode,p.model)||!!routeRefusal(mode)} title={routeRefusal(mode)??cyberCompatibility(mode,p.model)??({standard:"Standard safeguards",daybreak:"Requires approved account access",automatic:"Use the account’s default access"}[mode])} onClick={()=>{p.onChange(mode);setOpen(false);}}>
    <span class="pick-name">{cyberLabels[mode]}</span><span class="pick-check">{p.value===mode?'✓':''}</span>
   </button>}</For>
  </Menu></Show>
 </div>;
}
export function MissionCyber(p:{mission:Mission;onError?:(message:string)=>void}) {
 const [saving,setSaving]=createSignal(false);
 const [selection,{mutate,refetch}]=createResource(()=>[connectionVersion(),p.mission.id,p.mission.model_override,p.mission.status] as const,()=>getCyber(p.mission.id));
 createEffect(()=>{if(p.mission.status==='active'){const timer=setInterval(()=>void refetch(),8000);onCleanup(()=>clearInterval(timer));}});
 const update=async(mode:CyberMode)=>{
  const id=p.mission.id;setSaving(true);
  try {const saved=await saveCyber(id,mode);if(id===p.mission.id)mutate(saved);}
  catch(e){p.onError?.(cyberError(e));}finally{setSaving(false);}
 };
 return <><span class="under-sep">·</span><Show when={!selection.error} fallback={<span class="under-model" title="The connected backend does not expose cyber settings, or the request failed. Update or reconnect before changing this option.">Cyber: unavailable</span>}>
  <CyberPicker remote={!p.mission.local_run_active&&!!(p.mission.remote_node_id||p.mission.remote_job?.node_id)} value={selection()?.mode??'automatic'} model={p.mission.model_override??''} disabled={selection.loading||saving()} note="Applies to the next turn." confirmed={!selection.loading&&selection()?.status==='confirmed'&&!!selection()?.confirmed_program} onChange={update}/>
 </Show></>;
}

export async function requireCyberSupport(selection?:{model:string;mode:CyberMode;remote:boolean}){
 const query=selection?`?model=${encodeURIComponent(selection.model)}&mode=${selection.mode}&remote=${selection.remote}`:"";
 let value:{version?:number;route_supported?:boolean;refusal?:string};
 try {value=await api("/api/control/cyber-capabilities"+query,{cache:"no-store"});}
 catch {throw Error("Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept; the requested program was not silently omitted.");}
 if(value.version!==2)throw Error("Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept.");
 if(selection?.remote&&selection.mode!=='automatic'&&value.route_supported!==true)
  throw Error(value.refusal??"This backend cannot confirm the selected Cyber route. Choose Automatic explicitly. Your draft is kept.");
}
