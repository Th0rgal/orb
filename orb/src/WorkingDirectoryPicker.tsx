import {createSignal, Show} from 'solid-js';
import {FolderIcon} from './icons';

export function WorkingDirectoryPicker(p:{machine:string;value:string;disabled?:boolean;onChange:(value:string)=>void}) {
 const [open,setOpen]=createSignal(false),[error,setError]=createSignal('');
 const [picking,setPicking]=createSignal(false);
 const choose=async()=>{
  setError('');
  if(p.machine!=='local'){setOpen(!open());return;}
  const invoke=(window as any).__TAURI__?.core?.invoke;
  if(!invoke){setOpen(!open());return;}
  const machine=p.machine;setPicking(true);
  try{const path=await invoke('pick_working_directory');if(path&&p.machine===machine)p.onChange(path);}
  catch(e){setError(String(e));}finally{setPicking(false);}
 };
 const label=()=>p.value.replace(/\/$/,'').split('/').pop()||'Folder';
 return <div class="directory-picker">
  <button type="button" class="model directory-button" title={p.value||'Choose working folder'} aria-label="Choose working folder" disabled={p.disabled||picking()} onClick={()=>void choose()}><FolderIcon size={14}/><span>{label()}</span></button>
  <Show when={open()}><div class="menu directory-menu"><label>Folder on {p.machine==='local'?'this computer':p.machine}<input aria-label="Folder path" value={p.value} placeholder="Default directory" onInput={e=>p.onChange(e.currentTarget.value)} onKeyDown={e=>{if(e.key==='Enter'||e.key==='Escape'){e.preventDefault();setOpen(false);}}}/></label><button class="menu-item" onClick={()=>{p.onChange('');setOpen(false);}}>Use default folder</button><button class="menu-item" onClick={()=>setOpen(false)}>Done</button></div></Show>
  <Show when={error()}><div role="alert" class="menu directory-menu">{error()}<button onClick={()=>setError('')}>Dismiss</button></div></Show>
 </div>;
}
