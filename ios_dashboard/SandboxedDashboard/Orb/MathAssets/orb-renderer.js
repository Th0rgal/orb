/* Orb's local Markdown/KaTeX renderer. No provider-supplied HTML is executed. */
(function(root){
  const md = root.markdownit({html:false,linkify:true,breaks:false,typographer:false});
  const safeLink = value => /^(https?:|mailto:)/i.test(value) && !/^https?:\/\/[^/]*@/i.test(value);
  md.validateLink = value => safeLink(value) || /^(sandbox:|\/mnt\/data\/)/.test(value);
  function formula(source, display) {
    try { return root.katex.renderToString(source,{displayMode:display,throwOnError:false,trust:false,maxExpand:1000,output:'htmlAndMathml'}); }
    catch (_) { return '<code class="math-error">'+md.utils.escapeHtml(source)+'</code>'; }
  }
  md.inline.ruler.before('escape','orb_math',function(state,silent){
    const pos=state.pos, src=state.src;
    const prefix=src.slice(pos,pos+2);
    const display=prefix==='$$'||prefix==='\\[';
    const slash=prefix==='\\('||prefix==='\\[';
    if(!slash && (src[pos]!=='$' || /\s/.test(src[pos+(display?2:1)]||'') || (pos>0 && /[\w\\]/.test(src[pos-1])))) return false;
    const open=slash?prefix:display?'$$':'$',close=slash?(display?'\\]':'\\)'):open;
    let end=src.indexOf(close,pos+open.length);
    while(end>=0 && src[end-1]==='\\')end=src.indexOf(close,end+close.length);
    if(end<0 || (!slash && (/\s/.test(src[end-1]) || /\w/.test(src[end+close.length]||'')))) return false;
    const content=src.slice(pos+open.length,end);
    if(content.includes('\n') || !content.trim()) return false;
    if(!silent){const token=state.push('orb_math','math',0);token.content=content;token.meta={display};}
    state.pos=end+close.length;return true;
  });
  md.renderer.rules.orb_math=(tokens,index)=>formula(tokens[index].content,tokens[index].meta?.display||false);
  md.block.ruler.before('fence','orb_math_block',function(state,start,end,silent){
    const begin=state.bMarks[start]+state.tShift[start],line=state.src.slice(begin,state.eMarks[start]);
    const open=line.startsWith('$$')?'$$':line.startsWith('\\[')?'\\[':null;
    if(!open)return false;
    const close=open==='$$'?'$$':'\\]';let content=line.slice(open.length),next=start+1;
    const same=content.indexOf(close);
    if(same>=0){if(content.slice(same+close.length).trim())return false;content=content.slice(0,same);}
    else {
      let found=false;
      while(next<end){const row=state.src.slice(state.bMarks[next]+state.tShift[next],state.eMarks[next]);next++;const at=row.indexOf(close);if(at>=0){if(row.slice(at+close.length).trim())return false;content+='\n'+row.slice(0,at);found=true;break;}content+='\n'+row;}
      if(!found)return false; // Incomplete streaming input remains readable source.
    }
    if(silent)return true;
    const token=state.push('orb_math_block','math',0);token.content=content;token.block=true;token.map=[start,next];state.line=next;return true;
  },{alt:['paragraph','reference','blockquote','list']});
  md.renderer.rules.orb_math_block=(tokens,index)=>'<div class="math-block">'+formula(tokens[index].content,true)+'</div>\n';
  const imageRule=md.renderer.rules.image;
  md.renderer.rules.image=(tokens,index,options,env,self)=>{
    const src=tokens[index].attrGet('src')||'';
    if(!/^https:\/\//i.test(src))return '<button class="artifact" data-artifact="'+md.utils.escapeHtml(src)+'">'+md.utils.escapeHtml(tokens[index].content||'Open image')+'</button>';
    tokens[index].attrSet('referrerpolicy','no-referrer');tokens[index].attrSet('loading','lazy');return imageRule(tokens,index,options,env,self);
  };
  const fence=md.renderer.rules.fence;
  md.renderer.rules.fence=(tokens,index,options,env,self)=>'<div class="code-block"><button class="copy-code" type="button">Copy code</button>'+fence(tokens,index,options,env,self)+'</div>';
  root.orbRender=source=>md.render(source);
})(globalThis);
