import {getApiUrl,getJwt,connectionVersion,type Mission} from './api';
import {nativeInvoke} from './clientRuns';
export async function localOrigins():Promise<Mission[]>{
 const invoke=nativeInvoke();if(!invoke||!getJwt())return [];
 const version=connectionVersion();
 try{const rows=await invoke('local_origin_list',{connection:{api_url:getApiUrl(),token:getJwt()}});if(version!==connectionVersion())throw new Error("Connection changed while reading local missions");return Array.isArray(rows)?rows as Mission[]:[];}
 catch(error){if(/unknown command|not found/i.test(String(error)))return [];throw error;}
}
/** Local work that Core has not accepted yet. It overrides what Core lists.
 * The shown status may be one Core confirmed, so only the journal's own run state counts;
 * a desktop build without that field never shows confirmed statuses. */
export const localPending=(mission:Mission)=>!!mission.local_sync_pending||(mission.local_run_active??mission.status==="active");
let lastObservation=0;
/** Orders requests and accepted changes made by this window, even within one millisecond. */
export const observe=()=>lastObservation=Math.max(Date.now(),lastObservation+1);
export interface Confirmation {id:string;status?:string;title?:string;observed_at:number}
/** Persist what Core confirmed. The journal keeps the newest observation and ignores unsynchronized work. */
export async function confirmLocalOrigins(confirmations:Confirmation[]):Promise<void>{
 const invoke=nativeInvoke();if(!invoke||!getJwt()||!confirmations.length)return;
 try{await invoke('local_origin_confirm',{connection:{api_url:getApiUrl(),token:getJwt()},confirmations});}
 catch{/* The list on screen already comes from Core; an older desktop build only loses the offline copy. */}
}
/** Compare Core's answer with the journal and remember archive, restore and title changes. */
export function rememberCoreState(local:Mission[],remote:Mission[],observedAt:number):Promise<void>{
 const known=new Map(remote.map(mission=>[mission.id,mission]));
 return confirmLocalOrigins(local.flatMap(mission=>{
  const core=known.get(mission.id);
  if(!core||localPending(mission)||(core.status===mission.status&&(core.title??"")===(mission.title??"")))return [];
  // An emptied title is a title: dropping it would bring the old name back offline.
  return [{id:mission.id,status:core.status,...(typeof core.title==="string"?{title:core.title}:{}),observed_at:observedAt}];
 }));
}
/** Lists leave out archived rows. Ask Core about synchronized journal missions it did not list. */
export async function unlistedCoreState(local:Mission[],listed:Mission[],read:(id:string)=>Promise<Mission>):Promise<Mission[]>{
 const seen=new Set(listed.map(mission=>mission.id));
 const missing=local.filter(mission=>!seen.has(mission.id)&&!localPending(mission)).slice(0,20);
 const found=await Promise.allSettled(missing.map(mission=>read(mission.id)));
 return found.flatMap(result=>result.status==="fulfilled"&&result.value?.id?[result.value]:[]);
}
