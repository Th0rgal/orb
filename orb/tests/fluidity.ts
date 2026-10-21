import type {Page} from '@playwright/test';
/** Frame sampler for send fluidity: scroll, layout shift, message presence, error surfaces. */
export type Frame={t:number;anchor:number|null;top:number;height:number;gap:number;transcript:number;queue:number;leaving:number;side:number;errors:string[]};
export type Fluidity={frames:number;toVisibleMs:number|null;reversals:number;maxJump:number;maxGap:number;cls:number;missing:number;duplicated:number;errors:string[]};

export async function startSampling(page:Page,text:string){
 await page.evaluate(text=>{
  const w=window as any;const frames:any[]=[];w.fl_={frames,shifts:[] as number[],t0:0};
  try{new PerformanceObserver(list=>{for(const e of list.getEntries() as any[])if(!e.hadRecentInput&&w.fl_.t0&&e.startTime>=w.fl_.t0){w.fl_.shifts.push(e.value);if(w.flDebug)console.log('SHIFT',e.value.toFixed(4),Math.round(e.startTime-w.fl_.t0),(e.sources??[]).map((x:any)=>(x.node?.className??x.node?.nodeName??'?')+':'+Math.round(x.previousRect.y)+'>'+Math.round(x.currentRect.y)+' h'+Math.round(x.previousRect.height)+'>'+Math.round(x.currentRect.height)).join(' | '));}}).observe({type:'layout-shift',buffered:false});}catch{}
  const visible=(el:Element)=>{const r=el.getBoundingClientRect();return r.width>0&&r.height>0;};
  const has=(sel:string)=>[...document.querySelectorAll(sel)].filter(el=>visible(el)&&el.textContent?.includes(text));
  // What the eye follows: an existing transcript paragraph's screen position.
  let anchor:Element|undefined;
  const sample=()=>{
   const s=document.querySelector('.main .scroll') as HTMLElement|null;
   if(!anchor?.isConnected)anchor=[...(s?.querySelectorAll('p')??[])].filter(visible).at(-1);
   frames.push({t:performance.now(),anchor:anchor?Math.round(anchor.getBoundingClientRect().top):null,top:s?.scrollTop??0,height:s?.scrollHeight??0,gap:s?Math.max(0,s.scrollHeight-s.scrollTop-s.clientHeight):0,
    transcript:has('.scroll .user').length,
    queue:has('.followup-queue .queue-row:not(.leaving)').length,
    leaving:has('.followup-queue .queue-row.leaving').length,
    side:has('.btw-thread').length,
    errors:[...document.querySelectorAll('[role=alert], .error-notice, .error, .toast.error')].filter(visible).map(el=>(el.textContent??'').trim().slice(0,100))});
  };
  // Read after the frame is painted (rAF, then the next task): this is what
  // the user saw, after ResizeObserver scroll pinning ran for that frame.
  const tick=()=>{setTimeout(sample,0);w.flRaf=requestAnimationFrame(tick);};
  tick();
 },text);
}
/** Mark the user action (Enter/click) just before performing it. */
export const markAction=(page:Page)=>page.evaluate(()=>{(window as any).fl_.t0=performance.now();});

export async function stopSampling(page:Page,{side=false}:{side?:boolean}={}):Promise<Fluidity>{
 const {frames,shifts,t0}=await page.evaluate(()=>{const w=window as any;cancelAnimationFrame(w.flRaf);return w.fl_;}) as {frames:Frame[];shifts:number[];t0:number};
 const after=frames.filter(f=>f.t>=t0);
 const before=new Set((frames.filter(f=>f.t<t0).at(-1)??after[0])?.errors??[]);
 const shown=(f:Frame)=>side?f.side>0:f.transcript+f.queue+f.leaving>0;
 const first=after.findIndex(shown);
 let reversals=0,maxJump=0,dir=0;
 for(let i=1;i<after.length;i++){
  // The anchor moves only when content above the dock changes; a move back
  // the other way is the bounce the eye sees.
  const a=after[i].anchor,b=after[i-1].anchor;const d=a==null||b==null?0:a-b;
  // A jump the user did not cause: the content moved under a pinned view.
  if(Math.abs(d)>2){if(dir&&Math.sign(d)!==dir)reversals++;dir=Math.sign(d);}
  const gapJump=after[i].gap-after[i-1].gap;if(after[i-1].gap<=2)maxJump=Math.max(maxJump,gapJump);
 }
 if(process.env.FLUIDITY_DEBUG){let last='';for(const f of after){const k=`a${f.anchor} ${f.top}|${f.height}|${f.gap}|t${f.transcript} q${f.queue} l${f.leaving}`;if(k!==last){console.log(Math.round(f.t-t0),k);last=k;}}}
 const tail=first<0?[]:after.slice(first);
 return {
  frames:after.length,
  toVisibleMs:first<0?null:Math.round(after[first].t-t0),
  reversals,maxJump:Math.round(maxJump),
  maxGap:Math.round(Math.max(0,...tail.slice(Math.min(tail.length,6)).map(f=>f.gap))),
  cls:Number(shifts.reduce((a,b)=>a+b,0).toFixed(4)),
  missing:side?0:tail.filter(f=>!shown(f)).length,
  duplicated:side?0:tail.filter(f=>f.transcript>1||f.queue>1||f.transcript+f.queue>1).length,
  errors:[...new Set(after.flatMap(f=>f.errors).filter(e=>!before.has(e)))],
 };
}

/** Per-frame position of the user bubble holding `text`, and any bare loading line. */
export async function startBubbleSampling(page:Page,text:string,bare:RegExp){
 await page.evaluate(({text,bare})=>{
  const w=window as any;const re=new RegExp(bare.source,bare.flags);const frames:any[]=[];w.flb_={frames,t0:performance.now()};
  const sample=()=>{
   const bubble=[...document.querySelectorAll('.main .user')].find(el=>el.textContent?.includes(text)&&el.getBoundingClientRect().height>0);
   const r=bubble?.getBoundingClientRect();
   const main=document.querySelector('.main') as HTMLElement|null;
   frames.push({t:performance.now(),top:r?Math.round(r.top):null,left:r?Math.round(r.left):null,bare:re.test(main?.innerText??'')});
  };
  const tick=()=>{setTimeout(sample,0);w.flbRaf=requestAnimationFrame(tick);};tick();
 },{text,bare:{source:bare.source,flags:bare.flags}});
}
export async function stopBubbleSampling(page:Page){
 const frames=await page.evaluate(()=>{const w=window as any;cancelAnimationFrame(w.flbRaf);return w.flb_.frames;}) as {t:number;top:number|null;left:number|null;bare:boolean}[];
 const placed=frames.filter(f=>f.top!=null);
 const tops=placed.map(f=>f.top!),lefts=placed.map(f=>f.left!);
 return {frames:frames.length,bare:frames.filter(f=>f.bare).length,shown:placed.length,
  maxShift:placed.length?Math.max(Math.max(...tops)-Math.min(...tops),Math.max(...lefts)-Math.min(...lefts)):0,
  gaps:frames.slice(frames.findIndex(f=>f.top!=null)).filter(f=>f.top==null).length};
}
