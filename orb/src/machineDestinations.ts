import {connectionVersion,getApiUrl} from './api';
import type {Destination} from './machineTransfer';

// Only presentation data is cached. Transfer actions and validation stay live.
let cache:{scope:string;rows:Destination[]}|undefined;
const scope=()=>`${getApiUrl()}:${connectionVersion()}`;
export const cachedMachineDestinations=()=>cache?.scope===scope()?cache.rows:[];
export function cacheMachineDestinations(rows:Destination[]){cache={scope:scope(),rows};}
export function preferSparkAdministration<T>(rows:T[],id:(row:T)=>string|undefined):T[]{
 return rows.some(row=>id(row)==='dgx-spark-admin')?rows.filter(row=>id(row)!=='dgx-spark'):rows;
}
