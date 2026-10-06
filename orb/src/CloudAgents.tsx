import { pollWhileVisible } from "./poll";
import { QuizAnswer } from "./QuizAnswer";
import * as Ic from "./icons";
import { For, Show, createSignal, createEffect, onMount, onCleanup } from 'solid-js';
import { api, getMission, openExternalUrl, type Mission } from './api';
import { cloudAccounts, cloudAccountLabel, cloudCanSend, cloudExecution, cloudNames, cloudPhase, launchCloud, safeCloudUrl, type CloudAccount, type CloudExecution, type CloudProvider } from './cloudAgentApi';
import './cloudAgents.css';
import { ProviderLogo } from './ProviderLogo';
import { Composer, draftLightbox, floatingDock } from './App';
import { Transcript } from './Transcript';
import type { StreamItem } from './transcriptModel';
import { ProjectPicker } from './ProjectPicker';
import { CloudModelPicker } from './CloudModelPicker';
import type { ModelParam } from './cloudAgentApi';
import { AgentChoice, AgentChoiceMenu } from './AgentChoice';
import { type DraftImage, IMAGE_COUNT, imagePrompt, readImagePaste, stageRemoteImages } from './imageAttachments';
import { Lightbox } from './Lightbox';
export function CloudAgentPage(p: { project: string; path?: string; projects?: {id: string; name: string}[]; onProject?: (id: string) => void; onCreateProject?: () => void; onCreated: (m: Mission) => void }) {
  const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [provider, setProvider] = createSignal<CloudProvider>('chatgpt');
  const [accountId, setAccountId] = createSignal('');
  const [prompt, setPrompt] = createSignal(''); const [model, setModel] = createSignal(''); const [modelParams,setModelParams]=createSignal<ModelParam[]>([]);
  const [images, setImages] = createSignal<DraftImage[]>([]); const [viewing, setViewing] = createSignal<number | null>(null);
  const [imageError, setImageError] = createSignal(''); const [readingImages, setReadingImages] = createSignal(false);
  const [repositoriesLoading, setRepositoriesLoading] = createSignal(true);
  const [repo, setRepo] = createSignal(''); const [ref, setRef] = createSignal('');
  const [options, setOptions] = createSignal<{models: {id: string; name?: string; displayName?: string}[]; repos: {url: string}[]}>({models: [], repos: []});
  const [error, setError] = createSignal(''); const [busy, setBusy] = createSignal(false); const [loaded, setLoaded] = createSignal(false);
  const [open, setOpen] = createSignal<string | null>(null);
  const close = () => setOpen(null);
  let ta!: HTMLTextAreaElement; let fileInput!: HTMLInputElement;
  let attempt: { signature: string; key: string; prompt: string } | undefined;
  const account = () => accounts().find(a => a.provider === provider() && a.id === accountId()) ?? accounts().find(a => a.provider === provider() && a.available) ?? accounts().find(a => a.provider === provider());
  const canAttach = () => Boolean(account()?.capabilities.attachments);
  onMount(async () => { try { setAccounts(await cloudAccounts()); } catch(e) { setError(String(e)); } finally { setLoaded(true); } });
  const choose = (value: CloudProvider) => {
    setError(''); setImageError(''); setProvider(value); setAccountId(''); setModel(''); setModelParams([]); setRepo(''); setRef(''); setImages([]);
  };
  const pasteImages = async (event: ClipboardEvent) => {
    if (!canAttach()) return;
    const clipboard = event.clipboardData;
    if (!clipboard) return;
    const files = Array.from(clipboard.files).filter(file => file.type.startsWith("image/"));
    const html = clipboard.getData("text/html");
    const plain = clipboard.getData("text/plain");
    if (!files.length && !/<img\b|data-proton-embedded\s*=/i.test(html)) return;
    event.preventDefault();
    if (readingImages() || busy()) return;
    setImageError('');
    const original = prompt(), start = ta?.selectionStart ?? original.length, end = ta?.selectionEnd ?? original.length;
    setReadingImages(true);
    try {
      const first = Math.max(0, ...images().map(image => image.reference ?? 0)) + 1;
      const next = await readImagePaste(html, plain, files, first);
      if (images().length + next.images.length > IMAGE_COUNT) throw new Error(`Attach up to ${IMAGE_COUNT} images at a time.`);
      if (prompt() !== original) throw new Error("The draft changed while images loaded. Paste again to insert them at the cursor.");
      const value = original.slice(0, start) + next.text + original.slice(end);
      setImages(previous => [...previous, ...next.images]);
      setPrompt(value); if (ta) { ta.value = value; ta.setSelectionRange(start + next.text.length, start + next.text.length); }
    } catch (e) { setImageError(e instanceof Error ? e.message : String(e)); }
    finally { setReadingImages(false); }
  };
  const attachImageFiles = async (files: File[]) => {
    if (!canAttach() || !files.length || busy() || readingImages()) return;
    const pictures = files.filter(file => file.type.startsWith("image/"));
    if (pictures.length !== files.length) { setImageError("Use a PNG, JPEG, WebP or GIF image."); if (!pictures.length) return; }
    const clipboard = { files: pictures, getData: () => "" };
    await pasteImages({ clipboardData: clipboard, preventDefault() {} } as unknown as ClipboardEvent);
  };
  const submit = async () => {
    const rawPrompt = prompt().trim() || (images().length ? "Please look at the attached images." : "");
    if (busy() || readingImages() || !account()?.available || !rawPrompt) return;
    const cloud = { provider: provider(), account: account()!.id, ...(model() ? {model: model(), ...(modelParams().length ? {model_params:modelParams()} : {})} : {}), ...(repo() ? {repository: repo()} : {}), ...(ref() ? {git_ref: ref()} : {}) };
    const signature = JSON.stringify({ title: rawPrompt.slice(0, 100), prompt: rawPrompt, images: images().map(i => i.id), project: p.project, tags: p.path ? [`orb-folder:${p.path}`] : [], cloud });
    setBusy(true); setError('');
    try {
      if (attempt?.signature !== signature) {
        const sentPrompt = images().length ? imagePrompt(rawPrompt, await stageRemoteImages(images(), undefined, "core"), images()) : prompt();
        attempt = { signature, key: crypto.randomUUID(), prompt: sentPrompt };
      }
      const body = { title: rawPrompt.slice(0, 100), prompt: attempt.prompt, project: p.project, tags: p.path ? [`orb-folder:${p.path}`] : [], cloud };
      p.onCreated(await launchCloud({...body, idempotency_key: attempt.key}));
    } catch(e) { setError(String(e)); } finally { setBusy(false); }
  };
  return <section class="new-agent cloud-agent-page" aria-label="Cloud agent"><div class="new-inner">
    <div class="na-meta">
      <div class="na-drop" onPointerDown={e => e.stopPropagation()}>
        <button class="na-drop-btn" aria-label="Choose project" aria-haspopup="dialog" aria-expanded={open() === 'project'} disabled={!p.onProject || busy()} onClick={e => {e.currentTarget.focus(); setOpen(open() === 'project' ? null : 'project');}}>
          {p.projects?.find(item => item.id === p.project)?.name ?? (p.project || 'No project')}
          <Show when={p.path}><span class="new-agent-folder">/ {p.path}</span></Show><Ic.ChevronDown size={12}/>
        </button>
        <Show when={open() === 'project'}><ProjectPicker projects={p.projects ?? []} selected={p.project} canCreate={!!p.onCreateProject}
          onSelect={id => {p.onProject?.(id); close();}} onClose={close} onCreate={() => {close(); p.onCreateProject?.();}}/></Show>
      </div>
      <Show when={account()}><AgentChoice label={provider()==='hermes'?'Profile':'Account'} description={account()?.label} meta value={account()!.id} items={accounts().filter(a => a.provider === provider()).map(a => ({value:a.id, label:cloudAccountLabel(a),description:a.label}))}
        icon={<ProviderLogo type={provider()}/>} suffix={<Show when={account()?.experimental}><span class="cloud-experimental" title="Experimental connector" aria-label="Experimental connector"><Ic.FlaskIcon size={13}/></span></Show>}
        disabled={busy()} open={open() === 'account'} onOpen={() => setOpen('account')} onClose={close} onSelect={setAccountId}/></Show>
    </div>
    <div class="composer tall"
      onDragOver={e => { if (canAttach() && Array.from(e.dataTransfer?.types ?? []).includes("Files")) { e.preventDefault(); e.stopPropagation(); if (e.dataTransfer) e.dataTransfer.dropEffect = "copy"; e.currentTarget.classList.add("drop-active"); } }}
      onDragLeave={e => { if (!e.currentTarget.contains(e.relatedTarget as Node)) e.currentTarget.classList.remove("drop-active"); }}
      onDrop={e => { if (!canAttach()) return; e.preventDefault(); e.stopPropagation(); e.currentTarget.classList.remove("drop-active"); void attachImageFiles(Array.from(e.dataTransfer?.files ?? [])); }}>
      <div class="composer-field">
        <Show when={images().length}><div class="composer-images"><For each={images()}>{image => <div class="composer-image"><img src={image.dataUrl} alt={image.reference ? `Image #${image.reference}` : "Attached image"} title="Open preview" onClick={e => { e.stopPropagation(); setViewing(images().indexOf(image)); }} /><Show when={image.reference}><span class="composer-image-reference">#{image.reference}</span></Show><button class="icon-btn" aria-label="Remove image" title="Remove image" onClick={e => { e.stopPropagation(); setImages(current => current.filter(item => item.id !== image.id)); if (image.reference) { const value = prompt().replaceAll(`[Image #${image.reference}]`, ""); setPrompt(value); if (ta) ta.value = value; } }}><Ic.CloseIcon size={12}/></button></div>}</For></div></Show>
        <Show when={viewing() !== null && images().length}><Lightbox items={draftLightbox(images())} index={viewing()!} onClose={() => setViewing(null)} /></Show>
        <Show when={imageError()}><span class="image-paste-error" role="alert">{imageError()}</span></Show>
        <textarea ref={ta} aria-label="Prompt" autofocus rows={2} placeholder="Describe a task for your cloud agent" value={prompt()} disabled={busy()} onPaste={event => void pasteImages(event)} onInput={e => setPrompt(e.currentTarget.value)} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); void submit(); } }} />
      </div>
      <div class="plus-wrap">
        <Show when={canAttach()}>
          <input ref={fileInput} type="file" accept="image/png,image/jpeg,image/webp,image/gif" multiple hidden aria-label="Choose images" onChange={event => { const files = Array.from(event.currentTarget.files ?? []); event.currentTarget.value = ""; void attachImageFiles(files); }} />
          <button class="plus" title="Attach image" aria-label="Attach image" disabled={busy() || readingImages()} onClick={() => fileInput.click()}><Ic.PlusIcon size={14} /></button>
        </Show>
        <ProviderLogo type={provider()}/>
      </div>
      <div class="picks">
        <AgentChoice label="Service" value={provider()} items={Object.entries(cloudNames).map(([value,label]) => ({value,label}))} disabled={busy()}
          open={open() === 'service'} onOpen={() => setOpen('service')} onClose={close} onSelect={value => void choose(value as CloudProvider)}/>
        <Show when={account()?.available && account()?.capabilities.models}><CloudModelPicker provider={provider()} model={model()} params={modelParams()} disabled={busy()} onChange={(model,params)=>{setModel(model);setModelParams(params);}} onError={setError} onRepositories={repos=>setOptions({models:[],repos})} onRepositoriesLoading={setRepositoriesLoading}/></Show>
      </div>
      <div class="send-slot"><button class="send" aria-label="Create cloud agent" title="Create cloud agent" disabled={busy() || readingImages() || !account()?.available || (!prompt().trim() && !images().length) || !p.project} onClick={() => void submit()}><Show when={busy()} fallback={<Ic.ArrowUpIcon size={14} />}><Ic.Spinner size={14} /></Show></button></div>
    </div>
    <div class="cloud-page-details">
      <Show when={account()?.available && account()?.capabilities.repository}><div class="cloud-repository">
        <Show when={!repositoriesLoading()} fallback={<button class="na-drop-btn" disabled role="status"><Ic.Spinner size={14}/>Loading repositories…</button>}>
        <AgentChoice label="Repository" meta searchable searchLabel="Search repositories" emptyLabel="No matching repositories" value={repo()} items={[{value:'',label:'No repository'},...options().repos.map(r => ({value:r.url,label:r.url.replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, ''),description:r.url}))]}
          disabled={busy()} open={open() === 'repository'} onOpen={() => setOpen('repository')} onClose={close} onSelect={value => {setRepo(value); setRef('');}}/>
        </Show>
        <Show when={repo()}><div class="na-drop" onPointerDown={e => e.stopPropagation()}>
          <button class="na-drop-btn" aria-label="Git reference" aria-haspopup="dialog" aria-expanded={open() === 'reference'} disabled={busy()} onClick={e => {e.currentTarget.focus(); setOpen(open() === 'reference' ? null : 'reference');}}>{ref() || 'Default branch'}<Ic.ChevronDown size={12}/></button>
          <Show when={open() === 'reference'}><AgentChoiceMenu label="Git reference" meta dialog onClose={close}>
            <input class="project-search" aria-label="Branch or Git reference" placeholder="Default branch" value={ref()} onInput={e => setRef(e.currentTarget.value)} onKeyDown={e => {if(e.key === 'Enter'){e.preventDefault(); close();}}}/>
            <button class="menu-item" onClick={close}>Use {ref() || 'default branch'}</button>
          </AgentChoiceMenu></Show>
        </div></Show>
      </div></Show>
      <Show when={!account()}><p class="cloud-note" role="status">{loaded() ? 'No connected account for this service' : 'Checking connected accounts…'}</p></Show>
      <Show when={account()?.reason && !account()?.available}><p class="cloud-note" role="status">{account()?.reason}</p></Show>

      <Show when={error()}><p class="cloud-note" role="alert">{error()}</p></Show>
    </div>
  </div></section>;
}
export function CloudConversation(p: { id: string; onMission?: (m: Mission | null) => void; onOpenMission?: (m:Mission)=>void }) {
  const [children,setChildren]=createSignal<{id:string;title:string;status:string}[]>([]);
  const [execution, setExecution] = createSignal<CloudExecution>(); const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [error, setError] = createSignal(''); const [busy, setBusy] = createSignal(false);
  const [model,setModel]=createSignal(''),[modelParams,setModelParams]=createSignal<ModelParam[]>([]);
  let initialized=false;
  createEffect(()=>{const e=execution();if(e&&!initialized){initialized=true;setModel(e.turns.at(-1)?.model ?? e.selection.model ?? '');setModelParams(e.turns.at(-1)?.model_params ?? e.selection.model_params ?? []);}});
  let attempt: {signature: string; text: string; key: string; model:string; params:ModelParam[]} | undefined; let stopPoll: (() => void) | undefined; let disposed = false; let refreshing: Promise<void> | undefined;
  const refresh = (): Promise<void> => {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      try { const [e, m] = await Promise.all([cloudExecution(p.id), getMission(p.id)]);
        if (!disposed) { setExecution(old => JSON.stringify(old) === JSON.stringify(e) ? old : e); p.onMission?.(m); setError(''); }
        if(e.selection.provider==='hermes') {
          const result=await api<{missions:{id:string;title:string;status:string}[]}>(`/api/control/missions/${p.id}/cloud/children`);
          if(!disposed)setChildren(result.missions);
        }
      } catch(e) { if (!disposed) setError(`Connection lost. Last observed state is preserved. ${String(e)}`); }
      finally { refreshing = undefined; }
    })();
    return refreshing;
  };
  onMount(() => { void refresh(); stopPoll = pollWhileVisible(refresh, 3000); void cloudAccounts().then(value => { if (!disposed) setAccounts(value); }).catch(e => { if (!disposed) setError(String(e)); }); });
  onCleanup(() => { disposed = true; stopPoll?.(); p.onMission?.(null); });
  const account = () => accounts().find(a => a.id === execution()?.selection.account && a.provider === execution()?.selection.provider);
  const send = async (text: string, images: DraftImage[] = []) => {
    if (busy() || (!text.trim() && !images.length) || !execution() || !cloudCanSend(execution()!)) return false;
    const signature = JSON.stringify({ text, images: images.map(i => i.id), model: model(), params: modelParams() });
    setBusy(true);
    try {
      if (attempt?.signature !== signature) {
        const sent = images.length ? imagePrompt(text, await stageRemoteImages(images, undefined, "core"), images) : text;
        attempt = { signature, text: sent, key: crypto.randomUUID(), model: model(), params: modelParams() };
      }
      await api('/api/control/message', {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({mission_id: p.id, content: attempt.text, client_message_id: attempt.key,...(attempt.model || execution()?.selection.provider==='hermes' ? {cloud_model:attempt.model,cloud_model_params:attempt.params}: {})})});
      attempt = undefined; await refresh(); return true;
    } catch(e) { setError(String(e)); return false; } finally { setBusy(false); }
  };
  const cancel = async () => { setBusy(true); try { await api(`/api/control/missions/${p.id}/cloud/cancel`, {method:'POST'}); } catch(e) { setError(String(e)); } finally { setBusy(false); } };
  const approve = async (run_id:string, request_id:string|undefined, choice:string) => {
    setBusy(true);
    try {await api(`/api/control/missions/${p.id}/cloud/approval`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({run_id,request_id,choice})});await refresh();}
    catch(e){setError(String(e));}finally{setBusy(false);}
  };
  const download = async (path: string) => { try { const result = await api<{url?:string; content_base64?:string; name?:string}>(`/api/control/missions/${p.id}/cloud/artifact?path=${encodeURIComponent(path)}`); if (result.content_base64) { const bytes = Uint8Array.from(atob(result.content_base64), c => c.charCodeAt(0)); const blob = URL.createObjectURL(new Blob([bytes], {type:'application/octet-stream'})); const link = document.createElement('a'); link.href = blob; link.download = result.name ?? 'artifact'; link.click(); setTimeout(() => URL.revokeObjectURL(blob), 10000); return; } const url = safeCloudUrl(result.url); if (!url) throw new Error('Invalid artifact URL'); await openExternalUrl(url); } catch(e) {setError(String(e));} };
  const working = (t: {phase: string}) => ['queued', 'submitting', 'running', 'waiting_user', 'cancel_requested'].includes(t.phase);
  const active = () => execution()?.turns.some(working) ?? false;
  const items = (): StreamItem[] => (execution()?.turns ?? []).flatMap(t => [
    {kind: 'user' as const, key: `${t.key}:prompt`, text: t.prompt},
    ...(t.result ? [{kind: 'text' as const, key: `${t.key}:answer`, text: t.result, live: working(t)}] : []),
  ]);
  // The provider exposes no timestamps; time the turn from when Orb first saw it working.
  const [now, setNow] = createSignal(Date.now()); const seen = new Map<string, number>();
  const stopClock = pollWhileVisible(() => { if (active()) setNow(Date.now()); }, 1000); onCleanup(stopClock);
  const progress = () => {
    const t = execution()?.turns.find(working); if (!t) return;
    if (!seen.has(t.key)) seen.set(t.key, Date.now());
    const seconds = Math.max(0, Math.floor((now() - seen.get(t.key)!) / 1000));
    const label = t.phase === 'cancel_requested' ? 'Stopping…' : t.phase === 'queued' ? 'Queued…'
      : t.phase === 'waiting_user' ? 'Waiting for approval' : t.phase === 'submitting' ? (t.detail ?? `Opening ${cloudNames[execution()!.selection.provider]}…`)
      : t.result ? 'Writing…' : (t.detail ?? 'Thinking…');
    return `${label} · ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  };
  return <><div class="scroll"><div class="col cloud-transcript">
    <Show when={error()}><p class="cloud-note" role="alert">{error()}</p></Show>
    <Show when={execution()} fallback={<p role="status">Loading cloud conversation…</p>}>{e => <>
      <Transcript items={items()} pending={active()} renderText={(item, fallback) =>
        <Show when={e().selection.provider === 'chatgpt'} fallback={fallback}>
          <QuizAnswer text={item.text} fallback={fallback}
            disabled={busy() || !cloudCanSend(e()) || !account()?.capabilities.follow_up || item.key !== `${e().turns.at(-1)?.key}:answer`}
            onSubmit={text => send(text, [])}/>
        </Show>}/>
      <Show when={progress()}>{text => <p class="cloud-working" role="status"><span class="cloud-working-dot" aria-hidden="true"/>{text()}</p>}</Show>
      <Show when={children().length}><div aria-label="Delegated missions"><For each={children()}>{child=><p><button class="na-drop-btn" onClick={()=>void getMission(child.id).then(m=>p.onOpenMission?.(m)).catch(e=>setError(String(e)))}>{child.title || child.id}</button> · {child.status}</p>}</For></div></Show>
      <For each={e().turns}>{turn => <>
        <Show when={turn.detail && !working(turn)}><p class="cloud-note">{turn.detail}</p></Show>
        <For each={turn.branches}>{branch => <p>{branch.branch} <Show when={safeCloudUrl(branch.prUrl)}>{url => <a href={url()} target="_blank" rel="noopener noreferrer">View pull request</a>}</Show></p>}</For>
        <For each={turn.artifacts.filter(a=>a.kind==='hermes_approval' && turn.phase==='waiting_user')}>{approval => <div role="group" aria-label="Hermes approval"><p>{approval.request?.command ?? 'Hermes is waiting for your approval.'}</p><For each={approval.request?.choices ?? ['once','deny']}>{choice=><button class="na-drop-btn" disabled={busy()} onClick={()=>void approve(approval.run_id!,approval.request?.request_id,choice)}>{choice==='once'?'Approve once':choice==='deny'?'Deny':choice}</button>}</For></div>}</For>
        <For each={turn.artifacts.filter(a=>!a.kind)}>{artifact => <p><button class="na-drop-btn" onClick={() => void download(artifact.path)}>Download {artifact.path}</button></p>}</For>
      </>}</For>
    </>}</Show>
  </div></div><div class="dock" ref={floatingDock}><div class="col">
    <Show when={execution()}>{e => <>
      <Show when={account()?.capabilities.follow_up}><Composer textOnly={!account()?.capabilities.attachments} imagesOnly={Boolean(account()?.capabilities.attachments)} picker={false} scope={`cloud:${p.id}`} placeholder="Continue this conversation…" busy={active()} disabled={busy() || !cloudCanSend(e())} onSend={send} controls={<Show when={account()?.capabilities.models}><div class="picks"><CloudModelPicker provider={e().selection.provider} model={model()} params={modelParams()} disabled={busy()} onChange={(model,params)=>{setModel(model);setModelParams(params);}} onError={setError}/></div></Show>}
        onStop={account()?.capabilities.cancel && e().turns.some(t => t.external_id && ['running','submitting','waiting_user'].includes(t.phase)) ? () => void cancel() : undefined}/></Show>
      <div class="cloud-conversation-meta"><ProviderLogo type={e().selection.provider}/><span title={account()?.label}>{cloudNames[e().selection.provider]}<Show when={!account() || cloudAccountLabel(account()!) !== cloudNames[e().selection.provider]}> · {account() ? cloudAccountLabel(account()!) : e().selection.account}</Show></span>
        <span role="status">{cloudPhase(e().turns.at(-1)?.phase ?? '')}</span>
        <Show when={safeCloudUrl(e().external_url)}>{url => <a href={url()} onClick={event => {event.preventDefault(); void openExternalUrl(url());}}>Open in {cloudNames[e().selection.provider]}</a>}</Show>
      </div>
    </>}</Show>
  </div></div></>;
}
