import {createRoot,createEffect,onCleanup} from "solid-js";
import {followNative} from "./nativeInteractionStream";
import {api,getApiUrl,getJwt,connectionVersion} from './api';
import {nativeInvoke} from './clientRuns';
export interface ContextEntry {hash:string|null; directory:boolean; revision:number; size:number}
export interface ContextManifest {revision:number; entries:Record<string,ContextEntry>}
export interface ContextOperation {id:string;path:string;base:number|null;hash:string|null;directory:boolean;delete:boolean;source:string}
export interface ContextChange {revision:number;path:string;entry:ContextEntry|null;source:string}
const route=(slug:string)=>`/api/projects/${encodeURIComponent(slug)}/context`;
export const contextManifest=(slug:string)=>api<ContextManifest>(`${route(slug)}/manifest`);
export const contextHistory=(slug:string)=>api<ContextChange[]>(`${route(slug)}/history`);
export const contextConflicts=(slug:string)=>api<Record<string,ContextOperation>>(`${route(slug)}/conflicts`);
export async function restoreContext(slug:string,path:string,entry:ContextEntry|null,base:number|null,conflict?:string){
 const operation:ContextOperation={id:crypto.randomUUID(),path,base,hash:entry?.hash??null,directory:entry?.directory??false,delete:!entry,source:'Orb'};
 const result=await api<{revision:number;conflict:boolean}>(`${route(slug)}/${conflict?`conflicts/${encodeURIComponent(conflict)}`:'operations'}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(operation)});
 if(result.conflict)throw new Error('This file changed again. Refresh before resolving it. Your variant is preserved.');
}
export async function readProjectFileVersion(slug:string,path:string){
 const local=await localContextFile<{content:string;revision?:number}>(slug,"read",path);if(local)return local;
 return api<{content:string;revision?:number}>(`/api/projects/${encodeURIComponent(slug)}/file?path=${encodeURIComponent(path)}`);
}
export async function contextBlob(slug:string,hash:string):Promise<Blob>{
 const {getApiUrl,getJwt}=await import('./api');
 const response=await fetch(`${getApiUrl()}${route(slug)}/blobs/${encodeURIComponent(hash)}`,{headers:{Authorization:`Bearer ${getJwt()??''}`}});
 if(!response.ok)throw new Error(`Cannot load context version (${response.status})`);
 return response.blob();
}

export async function localContextFile<T>(slug:string,operation:string,path:string,content?:string,revision?:number):Promise<T|undefined>{
 const invoke=nativeInvoke();if(!invoke)return undefined;
 return await invoke('project_context_file',{request:{endpoint:getApiUrl(),token:getJwt()??'',project:slug},operation,path,content:content??null,revision:revision??null}) as T;
}

/** One context transport per project; views only invalidate their own projection. */
const contextStreams=new Map<string,{listeners:Set<()=>void>;errors:Set<(error:unknown)=>void>;stop:()=>void}>();
export function subscribeProjectContext(slug:string,changed:()=>void,failed:(error:unknown)=>void):()=>void{
 return createRoot(dispose=>{createEffect(()=>{connectionVersion();onCleanup(followContext(slug,changed,failed));});return dispose;});
}
function followContext(slug:string,changed:()=>void,failed:(error:unknown)=>void):()=>void{
 const key=`${connectionVersion()}:${getApiUrl()}:${slug}`;
 let stream=contextStreams.get(key);
 if(!stream){
  const endpoint=getApiUrl(),token=getJwt(),version=connectionVersion();
  const listeners=new Set<()=>void>(),errors=new Set<(error:unknown)=>void>();
  let stopped=false,timer:ReturnType<typeof setTimeout>|undefined,abort:AbortController|undefined;
  const publish=()=>{if(version===connectionVersion())listeners.forEach(callback=>callback());};
  const report=(error:unknown)=>errors.forEach(callback=>callback(error));
  const connect=async()=>{
   abort=new AbortController();
   try{
    const response=await fetch(`${endpoint}${route(slug)}/stream`,{headers:{Authorization:`Bearer ${token??''}`},signal:abort.signal});
    if(!response.ok||!response.body)throw Error(`Context stream failed (${response.status})`);
    publish();const reader=response.body.getReader(),decoder=new TextDecoder();let pending='';
    while(!stopped){const chunk=await reader.read();if(chunk.done)throw Error('Context stream interrupted');pending+=decoder.decode(chunk.value,{stream:true}).replace(/\r\n/g,'\n');let end:number;while((end=pending.indexOf('\n\n'))>=0){const event=pending.slice(0,end);pending=pending.slice(end+2);if(event.includes('data:'))publish();}}
   }catch(error){if(!stopped){report(error);timer=setTimeout(()=>void connect(),3000);}}
  };
  const stopNative=nativeInvoke()?followNative('project_context',{request:{endpoint:getApiUrl(),token:getJwt()??'',project:slug}},publish,report):()=>{};
  const visible=()=>{if(!document.hidden)publish();};document.addEventListener('visibilitychange',visible);
  stream={listeners,errors,stop:()=>{stopped=true;clearTimeout(timer);abort?.abort();stopNative();document.removeEventListener('visibilitychange',visible);}};
  contextStreams.set(key,stream);void connect();
 }
 stream.listeners.add(changed);stream.errors.add(failed);
 return()=>{stream!.listeners.delete(changed);stream!.errors.delete(failed);if(!stream!.listeners.size){stream!.stop();contextStreams.delete(key);}};
}
