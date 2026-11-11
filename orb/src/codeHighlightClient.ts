import { batch } from "solid-js";

let worker: Worker | undefined;
let sequence=0;
// Finished highlights by language and source, so a code block that scrolls
// back into a virtualized transcript paints coloured in its first frame
// instead of plain text for the 120 ms debounce plus the worker round trip.
// Bounded by characters (about 4 MB of strings) with LRU eviction.
const highlights=new Map<string,string>();
let highlightChars=0;
const HIGHLIGHT_BUDGET=2_000_000;
const MAX_SINGLE_HIGHLIGHT_CHARS = Math.floor(HIGHLIGHT_BUDGET / 4);
export function cachedHighlight(text:string,lang:string):string|null{
  const key=`${lang}\n${text}`,html=highlights.get(key);
  if(html===undefined)return null;
  highlights.delete(key);highlights.set(key,html);return html;
}
function remember(key:string,html:string){
  if(highlights.has(key))return;
  highlights.set(key,html);highlightChars+=key.length+html.length;
  for(const [old,value] of highlights){if(highlightChars<=HIGHLIGHT_BUDGET)break;highlights.delete(old);highlightChars-=old.length+value.length;}
}
const pending=new Map<number,(html:string|null)=>void>();
let flushQueue: Array<{ id: number; html: string | null }> = [];
let flushScheduled = false;
function flushWorkerBatch() {
  flushScheduled = false;
  const ready = flushQueue;
  flushQueue = [];
  batch(() => {
    for (const { id, html } of ready) {
      pending.get(id)?.(html);
      pending.delete(id);
    }
  });
}
/** One lazy worker shared by all blocks. Cancelled requests cannot update stale DOM. */
export function requestHighlight(text:string,lang:string,receive:(html:string|null)=>void):()=>void {
  const hit=cachedHighlight(text,lang);
  if(hit!==null){receive(hit);return ()=>{};}
  if (typeof Worker === "undefined") { receive(null); return () => {}; }
  if (!worker) {
    worker=new Worker(new URL("./codeHighlight.worker.ts",import.meta.url),{type:"module"});
    worker.onmessage=event=>{
      const {id,html}=event.data;
      flushQueue.push({ id, html });
      if (!flushScheduled) {
        flushScheduled = true;
        queueMicrotask(flushWorkerBatch);
      }
    };
    worker.onerror=()=>{worker?.terminate();worker=undefined;flushQueue=[];flushScheduled=false;pending.forEach(cb=>cb(null));pending.clear();};
  }
  const id=++sequence,key=`${lang}\n${text}`;
  pending.set(id,html=>{if(html!==null&&key.length+html.length<MAX_SINGLE_HIGHLIGHT_CHARS)remember(key,html);receive(html);});worker.postMessage({id,text,lang});
  return ()=>{pending.delete(id);};
}

/** Pre-warm worker syntax highlighting for settled code blocks off the critical path. */
export function warmHighlight(text: string, lang: string): void {
  if (!lang || !text || text.length > 100_000 || typeof Worker === "undefined") return;
  if (cachedHighlight(text, lang) !== null) return;
  requestHighlight(text, lang, () => {});
}
