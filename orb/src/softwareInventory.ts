import { nativeInvoke } from "./native";
import { readJson, writeJson } from "./storage";
import { createSignal } from "solid-js";
import { api, getRemoteNodes, connectionVersion, isConnected } from "./api";
import { historyScope } from "./resourceCache";
import { pathOverrides } from "./localAgents";
export type SoftwareLaunch={session:string;harness:string;version:string|null;runner:string;started_at:number;pid:number};
export type SoftwareComponent={id:string;name:string;version:string|null;path:string|null;installed:boolean;owner:string;update_supported:boolean;latest:string|null;release_error:string|null;running:SoftwareLaunch[];instructions:string;ready?:boolean|null;ready_detail?:string|null};
export type SoftwareJob={id:string;component:string;version:string;path:string;state:string;error:string|null;created_at:number;updated_at:number};
export type SoftwareInventory={checked_at:number;components:SoftwareComponent[];runtime:{name:string;version:string;build:string;path:string|null;restart_required:boolean;running?:SoftwareLaunch[]};jobs:SoftwareJob[]};
export type SoftwareMachine={id:string;name:string;online:boolean;inventory?:SoftwareInventory;error?:string};
const [machines,setMachines]=createSignal<SoftwareMachine[]>([]);
const [refreshing,setRefreshing]=createSignal(false);
export {machines as softwareMachines,refreshing as softwareRefreshing};
const native=nativeInvoke;
const cacheKey=()=>`orb.software.inventory.v1:${historyScope()}`;
export const softwareVersion=(s:string|null)=>s?.match(/(?:^|\s|v)(\d+)\.(\d+)\.(\d+)(?:\s|$)/)?.slice(1).map(Number);
export function newer(latest:string|null,current:string|null){
 const version=softwareVersion;
 const a=version(latest),b=version(current);if(!a||!b)return false;
 for(let i=0;i<3;i++){if(a[i]!==b[i])return a[i]>b[i];}return false;
}
let flight:Promise<void>|undefined;
let generation=0;
let scope="";
function enterScope(){const next=cacheKey();if(scope===next)return;scope=next;generation++;flight=undefined;setRefreshing(false);setMachines(readJson<SoftwareMachine[]>(next,[],Array.isArray).map(m=>({...m,online:false})));}
export function refreshSoftware(force=false):Promise<void>{
 enterScope();if(flight)return flight;
 const epoch=generation,connection=connectionVersion(),key=scope;setRefreshing(true);
 flight=(async()=>{
  const targets:SoftwareMachine[]=[{id:'local',name:'This Mac',online:!!native()}];
  if(isConnected()){
   targets.push({id:'core',name:'Core',online:true});
   try{const data=await getRemoteNodes();targets.push(...data.nodes.map(n=>({id:n.id,name:n.id,online:n.status==='online'})));}
   catch{targets.push(...machines().filter(m=>!['local','core'].includes(m.id)).map(m=>({...m,online:false})));}
  }
  if(epoch!==generation||connection!==connectionVersion())return;
  setMachines(targets.map(target=>({...target,inventory:machines().find(m=>m.id===target.id)?.inventory})));
  const publish=(machine:SoftwareMachine)=>{
   if(epoch===generation&&connection===connectionVersion())setMachines(previous=>previous.map(m=>m.id===machine.id?machine:m));
   return machine;
  };
  const result=await Promise.all(targets.map(async target=>{
   const old=machines().find(m=>m.id===target.id);
   if(!target.online)return publish({...target,inventory:old?.inventory,error:target.id==='local'?'Available in Orb desktop':'Offline'});
   try{
    const inventory:SoftwareInventory=target.id==='local'?await native()!('software_inventory',{overrides:pathOverrides(),force}):await api(`/api/software?force=${force}${target.id==='core'?'':`&node=${encodeURIComponent(target.id)}`}`);
    if(!inventory||!Array.isArray(inventory.components)||!Array.isArray(inventory.jobs)||!inventory.runtime||!Number.isFinite(inventory.checked_at))throw new Error('Invalid software inventory');
    return publish({...target,inventory});
   }catch(e){const message=String(e);return publish({...target,inventory:old?.inventory,error:/404|unknown command|not found|not allowed|Runtime update required/i.test(message)?'Runtime update required':message});}
  }));
  if(epoch!==generation||connection!==connectionVersion())return;
  setMachines(result);writeJson(key,result);
 })().finally(()=>{if(epoch===generation){flight=undefined;setRefreshing(false);}});
 return flight;
}
export function matchesSoftwareJob(job:SoftwareJob,row:SoftwareComponent){
 return job.component===row.id&&(!row.path||job.path===row.path);
}
export function canInstallSoftware(row:SoftwareComponent){
 return !row.installed&&row.update_supported&&!!row.latest;
}
export function canUpdateSoftware(row:SoftwareComponent){
 return row.installed&&row.update_supported&&!!row.path&&newer(row.latest,row.version);
}
export function softwareAttentionSummary(list:SoftwareMachine[]){
 const restarts=list.filter(m=>m.inventory?.runtime.restart_required).length;
 const missing=list.reduce((n,m)=>n+(m.inventory?.components.filter(r=>!r.installed).length??0),0);
 const unready=list.reduce((n,m)=>n+(m.inventory?.components.filter(r=>r.installed&&r.ready===false).length??0),0);
 const updates=list.reduce((n,m)=>n+(m.inventory?.components.filter(r=>r.installed&&newer(r.latest,r.version)).length??0),0);
 return [
  restarts?`${restarts} restart${restarts===1?'':'s'} needed`:'',
  missing?`${missing} missing`:'',
  unready?`${unready} setup needed`:'',
  updates?`${updates} update${updates===1?'':'s'}`:'',
 ].filter(Boolean).join(' · ');
}
export async function updateSoftware(machine:string,row:SoftwareComponent,refresh=true){
 if(!row.latest||!row.update_supported||(!row.path&&row.installed))throw new Error('This installation is managed externally');
 const body={component:row.id,version:row.latest,path:row.path??''};
 if(machine==='local')await native()!('software_update',body);
 else await api(`/api/software/updates${machine==='core'?'':`?node=${encodeURIComponent(machine)}`}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 if(refresh){if(flight)await flight;await refreshSoftware();}
}
export function availableSoftwareUpdates(){
 return machines().filter(m=>m.online&&!m.error&&m.inventory).flatMap(machine=>machine.inventory!.components.filter(row=>(canUpdateSoftware(row)||canInstallSoftware(row))&&!machine.inventory!.jobs.some(j=>matchesSoftwareJob(j,row)&&["queued","installing"].includes(j.state))).map(row=>({machine,row})));
}
export async function updateAllSoftware(){
 const pending=availableSoftwareUpdates(),connection=connectionVersion();
 const failures:string[]=[];
 for(const {machine,row} of pending){if(connection!==connectionVersion()){failures.push("Connection changed; remaining updates were not queued.");break;}try{await updateSoftware(machine.id,row,false);}catch(e){failures.push(`${machine.name} · ${row.name}: ${String(e)}`);}}
 if(flight)await flight;await refreshSoftware();
 if(failures.length)throw new Error(failures.join("; "));
}
export async function cancelSoftware(machine:string,id:string){
 if(machine==='local')await native()!('software_cancel',{id});
 else await api(`/api/software/updates/cancel${machine==='core'?'':`?node=${encodeURIComponent(machine)}`}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})});
 if(flight)await flight;
 await refreshSoftware();
}
/** Checks persist independently of the Machines page; native workers own queued updates. */
export function monitorSoftware(){
 let last=0;let lastScope='';
 const tick=()=>{const key=cacheKey();if(key!==lastScope){lastScope=key;last=0;}
 const pending=machines().some(m=>m.inventory?.jobs.some(j=>['queued','installing'].includes(j.state)));
 if(Date.now()-last>(pending?10000:900000)){last=Date.now();void refreshSoftware();}};
 tick();const timer=setInterval(tick,10000);window.addEventListener('focus',tick);
 return ()=>{clearInterval(timer);window.removeEventListener('focus',tick);};
}
