import { cachedHighlight, requestHighlight } from "./codeHighlightClient";
import { createEffect, createSignal, onCleanup, Show } from "solid-js";
import { copyText } from "./clipboard";
import { CopyIcon, CheckIcon } from "./icons";

export function CodeBlock(p: {text:string;lang:string;streaming?:boolean}) {
  const [html,setHtml]=createSignal<string|null>(p.lang&&!p.streaming?cachedHighlight(p.text,p.lang):null);
  const [feedback,setFeedback]=createSignal("");
  let feedbackTimer: ReturnType<typeof setTimeout> | undefined;
  let plainEl: HTMLElement | undefined;
  let streamedPrefix = "";
  onCleanup(()=>clearTimeout(feedbackTimer));
  let mounted=false;
  createEffect(()=>{
    const el=plainEl, text=p.text;
    if(!el)return;
    if(p.streaming && streamedPrefix.length>0 && text.startsWith(streamedPrefix)){
      if(text.length>streamedPrefix.length)el.appendChild(document.createTextNode(text.slice(streamedPrefix.length)));
    }else{
      el.textContent=text;
    }
    streamedPrefix=p.streaming?text:"";
  });
  createEffect(()=>{
    const text=p.text, lang=p.lang, streaming=Boolean(p.streaming);
    if (!lang || text.length>100_000 || (streaming && text.length>16_384)) {
      setHtml(null);
      mounted=true;
      return;
    }
    const hit=cachedHighlight(text,lang);
    setHtml(hit);
    if (hit!==null || typeof Worker === "undefined") {
      mounted=true;
      return;
    }
    let cancel: (()=>void) | undefined;
    // Coalesce streaming updates; completed blocks retain their highlighted DOM.
    // A block that mounts with its text (a turn paged in by the virtual list
    // ahead of the viewport) asks at once, so it is coloured before it shows.
    const timer=setTimeout(()=>{
      cancel=requestHighlight(text,lang,setHtml);
    },streaming||mounted?120:0);
    mounted=true;
    onCleanup(()=>{clearTimeout(timer);cancel?.();});
  });
  const copy=async()=>{
    try {await copyText(p.text);setFeedback("Copied");}
    catch(e) {setFeedback(e instanceof Error?e.message:String(e));}
    clearTimeout(feedbackTimer);
    feedbackTimer=setTimeout(()=>setFeedback(""),2500);
  };
  return <div class="md-code-block">
    <pre><Show when={html()} fallback={<code ref={el=>{plainEl=el;streamedPrefix="";el.textContent=p.text;if(p.streaming)streamedPrefix=p.text;}}/>}>{value=><code innerHTML={value()}/>}</Show></pre>
    <button class="icon-btn code-copy" aria-label="Copy code" title={feedback()||"Copy code"} onClick={()=>void copy()}>
      <Show when={feedback()==="Copied"} fallback={<CopyIcon size={14}/>}><CheckIcon size={14}/></Show>
    </button>
    <Show when={feedback()}><span class="code-copy-feedback" role="status">{feedback()}</span></Show>
  </div>;
}
