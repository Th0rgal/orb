import {For,createEffect,createMemo,createSignal,onCleanup,onMount,type JSX} from 'solid-js';
import {matchOffsets} from './searchIndex';
import { timed } from "./diagnostics";
import { scrollKeeper } from "./mission/scrollPolicy";
export type SearchHit={key:string;occurrence:number};
export interface TranscriptSearch {
 search(query:string,sensitive:boolean,whole:boolean):SearchHit[];
 reveal(hit:SearchHit):Promise<HTMLElement|undefined>;
 prepare(signal:AbortSignal):Promise<void>;
}
const searches=new WeakMap<HTMLElement,TranscriptSearch>();
export function transcriptSearch(scope:HTMLElement):TranscriptSearch|undefined{
 const root=scope.matches('[data-virtual-transcript]')?scope:scope.querySelector<HTMLElement>('[data-virtual-transcript]');
 return root?searches.get(root):undefined;
}
// Measured row heights survive remounts, per conversation (small LRU), so switching back to a
// mission lays out at real sizes instead of the 300px estimate and needs no scroll correction.
const sizeCaches=new Map<string,Map<string,number>>();
function sizeCache(key?:string){
 if(!key)return new Map<string,number>();
 let cache=sizeCaches.get(key);
 if(cache)sizeCaches.delete(key);else cache=new Map();
 sizeCaches.set(key,cache);
 while(sizeCaches.size>40)sizeCaches.delete(sizeCaches.keys().next().value!);
 return cache;
}
export function VirtualTurns<T extends {key:string}>(p:{items:T[];text:(item:T)=>string;estimate?:(item:T)=>number;prepare?:(signal:AbortSignal)=>Promise<void>;sizeKey?:string;children:(item:T)=>JSX.Element}){
 let root!:HTMLDivElement,scroller:HTMLElement|undefined,frame=0;
 const sizes=sizeCache(p.sizeKey),nodes=new Map<string,HTMLElement>();
 // First estimate per row, kept fixed so an unmeasured gap never changes height.
 const estimates=new Map<string,number>();
 const guess=(item:T)=>{let h=estimates.get(item.key);if(h===undefined){h=Math.max(40,Math.round(p.estimate?.(item)??300));estimates.set(item.key,h);}return h;};
 const known=(key:string)=>sizes.get(key)??estimates.get(key)??300;
 const [revision,setRevision]=createSignal(0),[viewport,setViewport]=createSignal({top:0,height:800,up:false});
 const [pinned,setPinned]=createSignal(new Set<string>());
 let firstKey:string|undefined;
 const layout=createMemo(()=>timed("turns layout",()=>{
  revision();let top=0;
  const rows=p.items.map(item=>{const row={item,top,height:sizes.get(item.key)??guess(item)};top+=row.height;return row;});
  const previousIndex=firstKey?rows.findIndex(row=>row.item.key===firstKey):-1;
  firstKey=rows[0]?.item.key;
  if(previousIndex>0&&scroller){
   // Retain the visible turns before virtualization can unmount the old anchor.
   const delta=rows[previousIndex].top,target=scroller,scrollTop=target.scrollTop;
   setViewport(value=>({...value,top:value.top+delta}));
   queueMicrotask(()=>{if(target.isConnected){target.scrollTop=scrollTop+delta;schedule();}});
  }
  return rows;
 }));
 const total=()=>{const rows=layout(),last=rows.at(-1);return last?last.top+last.height:0;};
 const update=()=>{
  const rect=root.getBoundingClientRect(),box=scroller?.getBoundingClientRect();
  // Keep the larger pre-render buffer on the side the reader is heading to:
  // a fast flick up otherwise outruns the two viewports mounted above and
  // shows the gap spacer for a frame. The total mounted span is unchanged.
  const top=(box?.top??0)-rect.top;
  setViewport(old=>({top,height:scroller?.clientHeight||innerHeight||800,up:top<old.top-1||(top<=old.top+1&&old.up)}));
  const selection=getSelection(),next=new Set<string>();
  for(const [key,node]of nodes){
   if(node.contains(document.activeElement)||node.querySelector('.editing,.fork-context[open]'))next.add(key);
   if(selection&&!selection.isCollapsed&&selection.rangeCount){try{if(selection.getRangeAt(0).intersectsNode(node))next.add(key);}catch{}}
  }
  setPinned(old=>old.size===next.size&&[...old].every(k=>next.has(k))?old:next);
 };
 const schedule=()=>{if(!frame)frame=requestAnimationFrame(()=>{frame=0;update();});};
 // A measurement moves the rows after it. Re-windowing in the same frame
 // (ResizeObserver callbacks and their microtasks run before paint) mounts
 // whatever the correction brought into view, instead of painting the gap
 // spacer for a frame and filling it on the next one.
 let settling=false;
 const settle=()=>{if(settling)return;settling=true;queueMicrotask(()=>{settling=false;if(root.isConnected)update();});};
 // Row measurement, batched: all rects are read from one layout, then the
 // sizes, the scroll correction and the re-windowing are applied once.
 const measureQueue=new Map<string,HTMLElement>(),fromGap=new Set<string>();
 let rendered=false;
 let measureQueued=false;
 const flushMeasure=()=>timed("turn resized",()=>{
  measureQueued=false;if(!measureQueue.size)return;
  const scrollerTop=scroller?.getBoundingClientRect().top;
  const reads=[...measureQueue].map(([key,node])=>[key,node.getBoundingClientRect()] as const);
  measureQueue.clear();
  // An estimate correction only moves the reader when the row replaced a gap
  // spacer laid out at that estimate. Rows of the first render never sat in a
  // gap, and a reader at the bottom is kept there by the pinned scroll.
  const box=scroller,atBottom=!box||box.scrollHeight-box.scrollTop-box.clientHeight<80;
  let delta=0,changed=false;
  for(const [key,rect]of reads){
   const height=rect.height;if(height<=0||sizes.get(key)===height)continue;
   // Unmeasured rows were laid out at their estimate; correct from that too,
   // or older turns paged in above the viewport push the reader's place down.
   const prevHeight=known(key),first=!sizes.has(key);
   sizes.set(key,height);changed=true;
   // A first measurement of a row cut by the top edge (paged in mid-drag) is
   // an estimate correction, not a change the reader made: keep what is below
   // the edge still too. Later resizes there (an expanded fold) grow downward.
   if(scrollerTop===undefined||(first&&(!fromGap.has(key)||atBottom)))continue;
   if(rect.bottom<=scrollerTop+1||(first&&rect.top<scrollerTop))delta+=height-prevHeight;
  }
  fromGap.clear();
  // At the bottom the pinned scroll owns the position. A row above that shrank
 // has already been absorbed by the browser clamping scrollTop; subtracting
 // the delta again moved a pinned reader up by that amount (and unpinned it).
 if(delta&&scroller&&!atBottom){
  scroller.scrollTop+=delta;
  // When the pinned scroll already put its anchor back for this same change
  // (its observer ran first), the delta above is applied twice: its keeper
  // measures where the anchor is and settles to the one correct position.
  scrollKeeper(scroller)?.();
 }
  if(changed){setRevision(n=>n+1);settle();}
 });
 const queueMeasure=(key:string,node:HTMLElement)=>{measureQueue.set(key,node);if(!measureQueued){measureQueued=true;queueMicrotask(flushMeasure);}};
 const resizes=new ResizeObserver(entries=>{for(const entry of entries){const node=entry.target as HTMLElement,key=node.dataset.turnKey;if(key)measureQueue.set(key,node);}flushMeasure();});
 onCleanup(()=>resizes.disconnect());
 type Segment={key:string;item?:T;height:number};
 const stable=new Map<string,Segment>();
 const [segments,setSegments]=createSignal<Segment[]>([]);
 createEffect(()=>timed("turns segments",()=>{
  const rows=layout(),v=viewport(),keep=pinned(),out:Segment[]=[];let gap=0,gapStart='';
  const spacer=()=>{if(!gap)return;const key=`gap:${gapStart}`;let row=stable.get(key);if(!row){row={key,height:gap};stable.set(key,row);}row.height=gap;out.push(row);gap=0;};
  rows.forEach((row,index)=>{
   const visible=!scroller||scroller.clientHeight===0||rows.length<=30||keep.has(row.item.key)||index===rows.length-1||(row.top+row.height>=v.top-(v.up?3:2)*v.height&&row.top<=v.top+(v.up?2:3)*v.height);
   if(visible){spacer();let value=stable.get(row.item.key);if(!value){value={key:row.item.key,item:row.item,height:0};stable.set(value.key,value);}else{value.item=row.item;}out.push(value);}
   else{if(!gap)gapStart=row.item.key;gap+=row.height;}
  });spacer();setSegments(out);
 }));
 function Row(props:{segment:Segment}){
  let element!:HTMLDivElement;
  onMount(()=>{
   if(!props.segment.item)return;
   const key=props.segment.key;nodes.set(key,element);
   // Measure a freshly mounted row before paint, batched with every other
   // row mounted in this pass: its ResizeObserver notification can be held to
   // the next frame when the re-windowing that mounted it ran from an
   // observer callback, and that frame painted the estimate (a 100-300 px
   // jump on a fast drag).
   if(rendered)fromGap.add(key);
   queueMeasure(key,element);
   resizes.observe(element);
   onCleanup(()=>{resizes.unobserve(element);nodes.delete(key);measureQueue.delete(key);});
  });
  return props.segment.item?<div ref={element} data-turn-key={props.segment.key} style={{display:'flow-root'}}>{p.children(props.segment.item)}</div>:<div aria-hidden="true" style={{height:`${segments().find(s=>s.key===props.segment.key)?.height??0}px`}}/>;
 }
 createEffect(()=>{p.items.length;queueMicrotask(schedule);});
 onMount(()=>{
  scroller=root.closest<HTMLElement>('.scroll,[data-find-conversation]')??undefined;
  const target=scroller??window;target.addEventListener('scroll',schedule,{passive:true});window.addEventListener('resize',schedule);document.addEventListener('selectionchange',schedule);root.addEventListener('focusin',schedule);root.addEventListener('focusout',schedule);root.addEventListener('click',schedule);
  searches.set(root,{
   search:(query,sensitive,whole)=>p.items.flatMap(item=>matchOffsets(p.text(item),query,sensitive,whole).map((_,occurrence)=>({key:item.key,occurrence}))),
   prepare:signal=>p.prepare?.(signal)??Promise.resolve(),
   async reveal(hit){
    const row=layout().find(row=>row.item.key===hit.key);if(!row)return;
    setPinned(prev=>new Set([...prev,hit.key]));
    await new Promise<void>(resolve=>requestAnimationFrame(()=>resolve()));
    const node=nodes.get(hit.key);node?.scrollIntoView({block:'center'});update();return node;
   },
  });update();
  requestAnimationFrame(()=>{rendered=true;});
  onCleanup(()=>{searches.delete(root);cancelAnimationFrame(frame);target.removeEventListener('scroll',schedule);window.removeEventListener('resize',schedule);document.removeEventListener('selectionchange',schedule);root.removeEventListener('focusin',schedule);root.removeEventListener('focusout',schedule);root.removeEventListener('click',schedule);});
 });
 return <div ref={root} data-virtual-transcript style={{'overflow-anchor':'none','min-height':`${Math.min(total(),1)}px`}}><For each={segments()}>{segment=><Row segment={segment}/>}</For></div>;
}
