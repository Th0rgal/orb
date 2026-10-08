import {getApiUrl,getJwt,connectionVersion,type Mission} from './api';
import {nativeInvoke} from './clientRuns';
// Concurrent list, queue and transcript reads share one native journal scan.
// Never cache settled rows: launches and synchronization can change them immediately.
const reads=new Map<number,Promise<Mission[]>>();
export async function localOrigins(missionId?:string):Promise<Mission[]>{
 const invoke=nativeInvoke();if(!invoke||!getJwt())return [];
 const version=connectionVersion();
 let read=reads.get(version);
 if(!read){
  read=(async()=>{
   try{const rows=await invoke('local_origin_list',{connection:{api_url:getApiUrl(),token:getJwt()}});if(version!==connectionVersion())throw new Error("Connection changed while reading local missions");return Array.isArray(rows)?rows as Mission[]:[];}
   catch(error){if(/unknown command|not found/i.test(String(error)))return [];throw error;}
  })().finally(()=>reads.delete(version));
  reads.set(version,read);
 }
 const rows=await read;
 return missionId?rows.filter(row=>row.id===missionId):rows;
}
/** Local work that Core has not accepted yet. It overrides what Core lists.
 * The shown status may be one Core confirmed, so only the journal's own run state counts;
 * a desktop build without that field never shows confirmed statuses. */
export const localPending=(mission:Mission)=>!!mission.local_sync_pending||(mission.local_run_active??mission.status==="active");
let lastObservation=0;
/** Orders requests and accepted changes made by this window, even within one millisecond. */
export const observe=()=>lastObservation=Math.max(Date.now(),lastObservation+1);
export interface Confirmation {id:string;status?:string;title?:string;deleted?:boolean;observed_at:number}
/** Persist what Core confirmed. The journal keeps the newest observation and ignores unsynchronized work. */
export async function confirmLocalOrigins(confirmations:Confirmation[]):Promise<void>{
 const invoke=nativeInvoke();if(!invoke||!getJwt()||!confirmations.length)return;
 try{await invoke('local_origin_confirm',{connection:{api_url:getApiUrl(),token:getJwt()},confirmations});}
 catch{/* The list on screen already comes from Core; an older desktop build only loses the offline copy. */}
}
/** Retire local-origin journals and bindings once Core confirms deletion. */
export function confirmDeletedLocalOrigins(ids:string[],observedAt=observe()):Promise<void>{
 const unique=[...new Set(ids.filter(Boolean))];
 for(const id of unique)unlistedReads.delete(id);
 return confirmLocalOrigins(unique.map(id=>({id,deleted:true,observed_at:observedAt})));
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
 // The list refreshes every few seconds; a conversation outside it is read far less often.
 const now=Date.now(),due=missing.filter(mission=>{const last=unlistedReads.get(mission.id);return !last||now-last.at>=(last.mission&&LIVE_STATUSES.has(last.mission.status)?UNLISTED_LIVE_MS:UNLISTED_SETTLED_MS);});
 const deletedIds:string[]=[];
 await Promise.allSettled(due.map(async mission=>{
  try{const value=await read(mission.id);unlistedReads.set(mission.id,{at:Date.now(),mission:value?.id?value:undefined});}
  catch(error){
   unlistedReads.set(mission.id,{at:Date.now(),mission:undefined});
   if((error as {status?:number})?.status===404||/\b404\b|not found/i.test(String(error)))deletedIds.push(mission.id);
  }
 }));
 if(deletedIds.length){
  await confirmDeletedLocalOrigins(deletedIds);
  // Retirement invalidates cached rows; retain the 404 backoff for journals
  // still present in this refresh's local snapshot.
  for(const id of deletedIds)unlistedReads.set(id,{at:Date.now(),mission:undefined});
 }
 return missing.flatMap(mission=>{const value=unlistedReads.get(mission.id)?.mission;return value?[value]:[];});
}
const UNLISTED_LIVE_MS=30_000,UNLISTED_SETTLED_MS=10*60_000;
const LIVE_STATUSES=new Set(["active","running","pending","queued","starting","resuming"]);
const unlistedReads=new Map<string,{at:number;mission?:Mission}>();
export function forgetUnlistedReads(){unlistedReads.clear();}
