import {connectionVersion,getApiUrl,getJwt} from './api';
import type {Destination} from './machineTransfer';

// Only presentation data is cached. Transfer actions and validation stay live.
// The list is also persisted so the menu opens filled after a restart; it is
// scoped to the backend and account, never to a token that could be reused.
const KEY='orb.machineDestinations';
let cache:{scope:string;rows:Destination[]}|undefined;
const scope=()=>`${getApiUrl()}:${connectionVersion()}`;
const account=()=>{let h=2166136261;for(const c of getJwt()??'')h=Math.imul(h^c.charCodeAt(0),16777619);return `${getApiUrl()}:${(h>>>0).toString(36)}`;};
export function cachedMachineDestinations():Destination[]{
 if(cache?.scope===scope())return cache.rows;
 try{
  const saved=JSON.parse(localStorage.getItem(KEY)??'null') as {account?:string;rows?:Destination[]}|null;
  if(saved?.account===account()&&Array.isArray(saved.rows)){cache={scope:scope(),rows:saved.rows};return saved.rows;}
 }catch{/* unreadable storage: fetch instead */}
 return [];
}
export function cacheMachineDestinations(rows:Destination[]){
 cache={scope:scope(),rows};
 try{if(rows.length)localStorage.setItem(KEY,JSON.stringify({account:account(),rows}));else localStorage.removeItem(KEY);}catch{/* quota */}
}
export function preferSparkAdministration<T>(rows:T[],id:(row:T)=>string|undefined):T[]{
 return rows.some(row=>id(row)==='dgx-spark-admin')?rows.filter(row=>id(row)!=='dgx-spark'):rows;
}
