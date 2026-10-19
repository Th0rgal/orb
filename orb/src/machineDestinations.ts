import { isRecord, readJson, removeKey, writeJson } from "./storage";
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
 const saved=readJson<{account?:string;rows?:Destination[]}|null>(KEY,null,isRecord);
 if(saved?.account===account()&&Array.isArray(saved.rows)){cache={scope:scope(),rows:saved.rows};return saved.rows;}
 return [];
}
export function cacheMachineDestinations(rows:Destination[]){
 cache={scope:scope(),rows};
 if(rows.length)writeJson(KEY,{account:account(),rows});else removeKey(KEY);
}
export function preferSparkAdministration<T>(rows:T[],id:(row:T)=>string|undefined):T[]{
 return rows.some(row=>id(row)==='dgx-spark-admin')?rows.filter(row=>id(row)!=='dgx-spark'):rows;
}
