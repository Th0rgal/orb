import {For,createEffect,createMemo,createSignal,onCleanup,onMount,type JSX} from 'solid-js';
import {matchOffsets} from './searchIndex';
import { timed } from "./diagnostics";
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
export function VirtualTurns<T extends {key:string}>(p:{items:T[];text:(item:T)=>string;prepare?:(signal:AbortSignal)=>Promise<void>;children:(item:T)=>JSX.Element}){
 let root!:HTMLDivElement,scroller:HTMLElement|undefined,frame=0;
 const sizes=new Map<string,number>(),nodes=new Map<string,HTMLElement>();
 const [revision,setRevision]=createSignal(0),[viewport,setViewport]=createSignal({top:0,height:800});
 const [pinned,setPinned]=createSignal(new Set<string>());
 let firstKey:string|undefined;
 const layout=createMemo(()=>timed("turns layout",()=>{
  revision();let top=0;
  const rows=p.items.map(item=>{const row={item,top,height:sizes.get(item.key)??300};top+=row.height;return row;});
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
  setViewport({top:(box?.top??0)-rect.top,height:scroller?.clientHeight||innerHeight||800});
  const selection=getSelection(),next=new Set<string>();
  for(const [key,node]of nodes){
   if(node.contains(document.activeElement)||node.querySelector('.editing,.fork-context[open]'))next.add(key);
   if(selection&&!selection.isCollapsed&&selection.rangeCount){try{if(selection.getRangeAt(0).intersectsNode(node))next.add(key);}catch{}}
  }
  setPinned(old=>old.size===next.size&&[...old].every(k=>next.has(k))?old:next);
 };
 const schedule=()=>{if(!frame)frame=requestAnimationFrame(()=>{frame=0;update();});};
 type Segment={key:string;item?:T;height:number};
 const stable=new Map<string,Segment>();
 const [segments,setSegments]=createSignal<Segment[]>([]);
 createEffect(()=>timed("turns segments",()=>{
  const rows=layout(),v=viewport(),keep=pinned(),out:Segment[]=[];let gap=0,gapStart='';
  const spacer=()=>{if(!gap)return;const key=`gap:${gapStart}`;let row=stable.get(key);if(!row){row={key,height:gap};stable.set(key,row);}row.height=gap;out.push(row);gap=0;};
  rows.forEach((row,index)=>{
   const visible=!scroller||scroller.clientHeight===0||rows.length<=30||keep.has(row.item.key)||index===rows.length-1||(row.top+row.height>=v.top-2*v.height&&row.top<=v.top+3*v.height);
   if(visible){spacer();let value=stable.get(row.item.key);if(!value){value={key:row.item.key,item:row.item,height:0};stable.set(value.key,value);}else{value.item=row.item;}out.push(value);}
   else{if(!gap)gapStart=row.item.key;gap+=row.height;}
  });spacer();setSegments(out);
 }));
 function Row(props:{segment:Segment}){
  let element!:HTMLDivElement;
  onMount(()=>{
   if(!props.segment.item)return;
   const key=props.segment.key;nodes.set(key,element);
   const observer=new ResizeObserver(()=>timed("turn resized",()=>{
    const height=element.getBoundingClientRect().height;if(height<=0||sizes.get(key)===height)return;
    const row=layout().find(row=>row.item.key===key),delta=height-(sizes.get(key)??300);
    sizes.set(key,height);
    if(scroller&&row&&row.top+row.height<viewport().top)scroller.scrollTop+=delta;
    setRevision(n=>n+1);schedule();
   }));observer.observe(element);
   onCleanup(()=>{observer.disconnect();nodes.delete(key);});
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
  onCleanup(()=>{searches.delete(root);cancelAnimationFrame(frame);target.removeEventListener('scroll',schedule);window.removeEventListener('resize',schedule);document.removeEventListener('selectionchange',schedule);root.removeEventListener('focusin',schedule);root.removeEventListener('focusout',schedule);root.removeEventListener('click',schedule);});
 });
 return <div ref={root} data-virtual-transcript style={{'overflow-anchor':'none','min-height':`${Math.min(total(),1)}px`}}><For each={segments()}>{segment=><Row segment={segment}/>}</For></div>;
}
