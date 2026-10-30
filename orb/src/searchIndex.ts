export type TextSegment = {node: Text; start: number; end: number};
export type TextIndex = {text: string; nodes: TextSegment[]};
export type IndexTextOptions = {messagesOnly?: boolean};
const excluded = [
  'button:not(.file-reference)',
  'textarea',
  'input',
  'script',
  'style',
  '.file-provenance',
  '.find-bar',
  '.code-copy-feedback',
  '.mermaid-head',
  '.md-file-unavailable > small',
  '.st-work',
  '.st-think',
  '.st-think-fold',
  '.st-tool',
  '.st-orch',
  '.mission-tasks',
  '.background-wake',
  '.automatic-reminder',
  '.fork-context',
  '.legacy-log',
  '.agent-activity',
  '.btw-narration',
  '.btw-queue',
  '.btw-progress',
  '.turn-recap',
  '.error-notice',
  '.response-actions',
  '.user-origin',
  '.user-plan',
  '.user-context',
  '.message-images',
  '[aria-hidden="true"]',
  '[hidden]',
].join(',');
const blockSelector = 'p,li,pre,h1,h2,h3,h4,tr,td,th,.user,[data-find-message]';
export function indexText(scope:HTMLElement,options?:IndexTextOptions):TextIndex {
  const nodes:TextSegment[]=[];let text='',block:Element|null=null;
  const requireMessage=options?.messagesOnly===true;
  const walker=document.createTreeWalker(scope,NodeFilter.SHOW_TEXT,{acceptNode(node){
    const parent=node.parentElement;
    if(!parent||parent.closest(excluded)||(parent.checkVisibility&&!parent.checkVisibility({contentVisibilityAuto:false})))return NodeFilter.FILTER_REJECT;
    if(requireMessage){
      const msg=parent.closest('[data-find-message]');
      if(!msg||!scope.contains(msg))return NodeFilter.FILTER_REJECT;
    }
    return NodeFilter.FILTER_ACCEPT;
  }});
  let node:Node|null;
  while((node=walker.nextNode())) {
    const next=node.parentElement?.closest(blockSelector)??scope;
    if(block&&next!==block)text+='\n';block=next;
    const start=text.length;text+=node.textContent;nodes.push({node:node as Text,start,end:text.length});
  }
  return {text,nodes};
}
export function matchOffsets(text:string,query:string,matchCase:boolean,whole:boolean):{start:number;end:number}[] {
  if(!query)return [];
  const escaped=query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const re=new RegExp(escaped,matchCase?'gu':'giu'),matches=[];
  for(const m of text.matchAll(re)) {
    const start=m.index!,end=start+m[0].length;
    if(!whole || (!/[\p{L}\p{N}_]/u.test(text[start-1]??'')&&!/[\p{L}\p{N}_]/u.test(text[end]??'')))matches.push({start,end});
  }
  return matches;
}
export function matchRange(index:TextIndex,match:{start:number;end:number}):Range|undefined {
  const locate=(offset:number)=>{let lo=0,hi=index.nodes.length;while(lo<hi){const mid=(lo+hi)>>>1;if(index.nodes[mid].end<=offset)lo=mid+1;else hi=mid;}return index.nodes[lo];};
  const a=locate(match.start),b=locate(match.end-1);if(!a||!b)return;
  const range=document.createRange();range.setStart(a.node,match.start-a.start);range.setEnd(b.node,match.end-b.start);return range;
}
