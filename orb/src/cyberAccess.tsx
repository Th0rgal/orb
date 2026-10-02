import { createEffect, createResource, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import { api, connectionVersion, type Mission } from "./api";
import { missionSettingsIdle } from "./missionLaunch";
import { ChevronDown } from "./icons";
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
export function CyberPicker(p:{value:CyberMode;model:string;disabled?:boolean;note?:string;confirmed?:boolean;onChange:(mode:CyberMode)=>void}) {
 const [open,setOpen]=createSignal(false);let root:HTMLDivElement|undefined;
 const close=(e:PointerEvent)=>{if(!root?.contains(e.target as Node))setOpen(false);};
 const key=(e:KeyboardEvent)=>{if(e.key==='Escape')setOpen(false);};
 onMount(()=>{window.addEventListener('pointerdown',close);window.addEventListener('keydown',key);});
 onCleanup(()=>{window.removeEventListener('pointerdown',close);window.removeEventListener('keydown',key);});
 createEffect(()=>{if(p.disabled)setOpen(false);});
 return <div class="cyber-picker model-wrap under-model-wrap" ref={root}>
  <button class={`model under-model cyber-pill ${p.confirmed&&p.value==='daybreak'?'confirmed':''}`} disabled={p.disabled} aria-label={`Cyber program: ${cyberLabels[p.value]}`} aria-haspopup="menu" aria-expanded={open()} title={p.note??(p.confirmed?'Provider-confirmed program':'Requested program; activation is not confirmed')} onClick={()=>setOpen(!open())}>
   <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M12 3 4 6v6c0 4 5 8 8 9 3-1 8-5 8-9V6z"/></svg>
   Cyber: {cyberLabels[p.value]}<Show when={p.value==='daybreak'}><span class="cyber-state">{p.confirmed?'active':'requested'}</span></Show><ChevronDown size={10}/>
  </button>
  <Show when={open()}><div class="menu cyber-menu" role="menu" aria-label="Cyber program">
   <For each={['standard','daybreak','automatic'] as CyberMode[]}>{mode=><button role="menuitemradio" aria-checked={p.value===mode} class={`menu-item ${p.value===mode?'on':''}`} disabled={!!cyberCompatibility(mode,p.model)} title={cyberCompatibility(mode,p.model)} onClick={()=>{p.onChange(mode);setOpen(false);}}>
    <span><span class="pick-name">{cyberLabels[mode]}</span><small>{cyberCompatibility(mode,p.model)??({standard:'Use standard safeguards.',daybreak:'Request the approved access for this model. Account authorization is checked at launch.',automatic:'Let the provider choose from this account’s approved access.'}[mode])}</small></span><span class="pick-check">{p.value===mode?'✓':''}</span>
   </button>}</For><p>{p.note??'Applies to the next launch. Does not grant account access or change system permissions.'}</p>
  </div></Show>
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
  <CyberPicker value={selection()?.mode??'automatic'} model={p.mission.model_override??''} disabled={selection.loading||saving()||!missionSettingsIdle(p.mission.status)} note={!missionSettingsIdle(p.mission.status)?'Stop the current turn to change its cyber program.':(selection()?.status==='confirmed'?`Provider confirmed ${selection()?.confirmed_program} on ${selection()?.confirmed_model ?? 'the selected model'} for the latest observed request.`:'Saved per mission. Activation has not been confirmed by the provider.')} confirmed={!selection.loading&&selection()?.status==='confirmed'&&!!selection()?.confirmed_program} onChange={update}/>
 </Show></>;
}

export async function requireCyberSupport(){
 try {const value=await api<{version?:number}>("/api/control/cyber-capabilities",{cache:"no-store"});if(value.version===2)return;}catch{}
 throw Error("Update or reconnect to a backend supporting cyber selection before launching. Your draft is kept; the requested program was not silently omitted.");
}
