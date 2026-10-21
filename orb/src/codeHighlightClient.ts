let worker: Worker | undefined;
let sequence=0;
// Finished highlights by language and source, so a code block that scrolls
// back into a virtualized transcript paints coloured in its first frame
// instead of plain text for the 120 ms debounce plus the worker round trip.
// Bounded by characters (about 4 MB of strings) with LRU eviction.
const highlights=new Map<string,string>();
let highlightChars=0;
const HIGHLIGHT_BUDGET=2_000_000;
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
/** One lazy worker shared by all blocks. Cancelled requests cannot update stale DOM. */
export function requestHighlight(text:string,lang:string,receive:(html:string|null)=>void):()=>void {
  if (!worker) {
    worker=new Worker(new URL("./codeHighlight.worker.ts",import.meta.url),{type:"module"});
    worker.onmessage=event=>{
      const {id,html}=event.data;
      pending.get(id)?.(html);pending.delete(id);
    };
    worker.onerror=()=>{worker?.terminate();worker=undefined;pending.forEach(cb=>cb(null));pending.clear();};
  }
  const hit=cachedHighlight(text,lang);
  if(hit!==null){receive(hit);return ()=>{};}
  const id=++sequence,key=`${lang}\n${text}`;
  pending.set(id,html=>{if(html!==null&&key.length+html.length<HIGHLIGHT_BUDGET/20)remember(key,html);receive(html);});worker.postMessage({id,text,lang});
  return ()=>{pending.delete(id);};
}
