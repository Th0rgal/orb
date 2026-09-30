import {For,Show,type JSX} from 'solid-js';
import {type AttachItem} from './attach';
import * as Ic from './icons';
export function MentionPicker(p:{items:AttachItem[];index:number;highlight:(index:number)=>void;pick:(item:AttachItem)=>void;style?:JSX.CSSProperties}){
 return <div class="menu slash-menu" role="listbox" aria-label="Context" style={p.style} onPointerDown={e=>{e.preventDefault();e.stopPropagation();}}>
  <For each={['Context','Folders','Files'] as const}>{section=>{
   const rows=()=>p.items.filter(item=>item.section===section);
   return <Show when={rows().length}><div class="slash-head">{section}</div><For each={rows()}>{item=>{
    const index=()=>p.items.indexOf(item);
    return <button type="button" role="option" aria-selected={p.index===index()} class={`menu-item ${p.index===index()?'on':''}`} onMouseEnter={()=>p.highlight(index())} onClick={()=>p.pick(item)}>
     <span class="menu-ico">{item.kind==='folder'||item.kind==='context'?<Ic.FolderIcon size={14}/>:item.kind==='controller'?<Ic.TargetIcon size={14}/>:<Ic.FileIcon size={14}/>}</span>{item.label}
    </button>;
   }}</For></Show>;
  }}</For>
 </div>;
}
