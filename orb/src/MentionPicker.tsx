import {createEffect,For,Show,type JSX} from 'solid-js';
import {type AttachItem} from './attach';
import * as Ic from './icons';
export function MentionPicker(p:{items:AttachItem[];index:number;highlight:(index:number)=>void;pick:(item:AttachItem)=>void;folder?:string;onBack?:()=>void;onOpenFolder?:(folder:string)=>void;style?:JSX.CSSProperties}){
 let root:HTMLDivElement|undefined;
 createEffect(()=>{p.index;p.items;requestAnimationFrame(()=>root?.querySelector<HTMLElement>('.menu-item.on')?.scrollIntoView?.({block:'nearest'}));});
 return <div ref={root} class="menu slash-menu" role="listbox" aria-label="Context" style={p.style} onPointerDown={e=>{e.preventDefault();e.stopPropagation();}}>
  <Show when={p.folder && p.onBack}>
   <div class="slash-folder-bar">
    <button type="button" class="menu-item slash-back" onClick={()=>p.onBack?.()}><span class="menu-ico"><Ic.ArrowLeft size={14}/></span><span class="slash-item-label">{p.folder}/</span></button>
   </div>
  </Show>
  <For each={['Context','Folders','Files'] as const}>{section=>{
   const rows=()=>p.items.filter(item=>item.section===section);
   return <Show when={rows().length}><div class="slash-head">{section}</div><For each={rows()}>{item=>{
    const index=()=>p.items.indexOf(item);
    const isFolder=()=>item.section==='Folders'&&!!item.path&&!!p.onOpenFolder;
    return <div class="slash-row">
     <button type="button" role="option" aria-selected={p.index===index()} title={item.path??item.label} class={`menu-item ${p.index===index()?'on':''}`} onMouseEnter={()=>p.highlight(index())} onClick={()=>{if(isFolder())p.onOpenFolder!(item.path!.replace(/\/$/,''));else p.pick(item);}}>
      <span class="menu-ico">{item.kind==='folder'||item.kind==='context'&&item.section==='Folders'?<Ic.FolderIcon size={14}/>:item.kind==='controller'?<Ic.TargetIcon size={14}/>:<Ic.FileIcon size={14}/>}</span>
      <span class="slash-item-label">{item.label}</span>
      <Show when={isFolder()}><span class="slash-chevron"><Ic.ChevronRight size={12}/></span></Show>
     </button>
    </div>;
   }}</For></Show>;
  }}</For>
 </div>;
}

