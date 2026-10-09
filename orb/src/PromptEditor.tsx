import {createContext,useContext,createSignal,createMemo,createEffect,onCleanup,Show,type Accessor} from 'solid-js';
import {atQuery,filterAttach,folderPrefixFromQuery,insertMention,loadAttachItems,type AttachItem} from './attach';
import {MentionPicker} from './MentionPicker';
import {connectionVersion,isConnected} from './api';
export const MentionProjectContext=createContext<Accessor<string|undefined>>(()=>undefined);
export function PromptEditor(p:{value:string;disabled:boolean;input:(text:string)=>void;cancel:()=>void;submit:()=>void}){
 const project=useContext(MentionProjectContext);
 const [items,setItems]=createSignal<AttachItem[]>([]),[caret,setCaret]=createSignal(0),[closed,setClosed]=createSignal(false),[index,setIndex]=createSignal(0);
 let field!:HTMLTextAreaElement;
 const options=createMemo(()=>{const q=atQuery(p.value,caret());return !closed()&&q.open?filterAttach(items(),q.query):[];});
 const folder=createMemo(()=>{const q=atQuery(p.value,caret());return !closed()&&q.open?(folderPrefixFromQuery(items(),q.query)??''):'';});
 createEffect(()=>{options();setIndex(0);});
 createEffect(()=>{const slug=project();connectionVersion();let alive=true;setItems([]);if(slug&&isConnected())void loadAttachItems(slug).then(items=>{if(alive)setItems(items);});onCleanup(()=>alive=false);});
 const resize=()=>{field.style.height='auto';field.style.height=`${field.scrollHeight}px`;};
 const pick=(item:AttachItem)=>{const next=insertMention(p.value,caret(),item);p.input(next.text);setClosed(true);field.value=next.text;resize();field.focus({preventScroll:true});field.setSelectionRange(next.caret,next.caret);setCaret(next.caret);};
 const openFolder=(nextFolder:string)=>{const q=atQuery(p.value,caret());if(!q.open||q.start<0)return;const token=nextFolder?`@${nextFolder.replace(/\/+$/,'')}/`:'@';const next=`${p.value.slice(0,q.start)}${token}${p.value.slice(caret())}`;const nextCaret=q.start+token.length;p.input(next);setClosed(false);field.value=next;resize();field.focus({preventScroll:true});field.setSelectionRange(nextCaret,nextCaret);setCaret(nextCaret);};
 const cursor=()=>{setCaret(field.selectionStart);};

 return <><textarea class="prompt-editor" rows={1} aria-label="Edit prompt text" disabled={p.disabled} value={p.value} ref={el=>{field=el;queueMicrotask(()=>{if(!field.isConnected)return;resize();field.setSelectionRange(p.value.length,p.value.length);field.focus({preventScroll:true});cursor();});}}
  onInput={e=>{p.input(e.currentTarget.value);setClosed(false);cursor();resize();}} onClick={cursor} onKeyUp={cursor} onSelect={cursor}
  onKeyDown={e=>{if(e.isComposing)return;const rows=options();if(rows.length&&['ArrowDown','ArrowUp','Enter','Tab','Escape'].includes(e.key)){e.preventDefault();e.stopPropagation();if(e.key==='Escape')setClosed(true);else if(e.key==='ArrowDown'||e.key==='ArrowUp')setIndex(i=>(i+(e.key==='ArrowDown'?1:-1)+rows.length)%rows.length);else pick(rows[index()]);return;}if(e.key==='Escape'){e.stopPropagation();p.cancel();}else if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){e.preventDefault();p.submit();}}}/>
  <Show when={options().length}><MentionPicker anchor={field} onClose={()=>setClosed(true)} items={options()} index={index()} highlight={setIndex} pick={pick} folder={folder()||undefined} onBack={()=>{const cur=folder();const idx=cur.lastIndexOf('/');openFolder(idx>=0?cur.slice(0,idx):'');}} onOpenFolder={openFolder}/></Show>
 </>;
}
