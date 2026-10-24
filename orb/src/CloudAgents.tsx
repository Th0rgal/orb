import { swallow } from "./log";
import { pollWhileVisible } from "./poll";
import { ErrorToast } from "./toast";
import * as Ic from "./icons";
import { For, Show, createSignal, createEffect, on, onMount, onCleanup } from 'solid-js';
import { createPinnedScroll } from './mission/pinnedScroll';
import { JumpToLatest } from './mission/JumpToLatest';
import { api, getMission, openExternalUrl, type Mission } from './api';
import { cloudAccounts, cloudAccountLabel, cloudAttachmentBlock, cloudLaunchSeeds, defaultCloudProvider, readCloudProvider, writeCloudProvider, type CloudLaunchSeed, cloudCanSend, cloudExecution, cloudNames, cloudPhase, launchCloud, safeCloudUrl, type CloudAccount, type CloudExecution, type CloudProvider, type CloudTurn } from './cloudAgentApi';
import './cloudAgents.css';
import { ProviderLogo } from './ProviderLogo';
import { Composer, floatingDock } from './composer/Composer';
import { Transcript } from './Transcript';
import type { StreamItem } from './transcriptModel';
import { ProjectPicker } from './ProjectPicker';
import { CloudModelPicker } from './CloudModelPicker';
import type { ModelParam } from './cloudAgentApi';
import { AgentChoice, AgentChoiceMenu } from './AgentChoice';
import { type DraftImage, imagePrompt, stageRemoteImages } from './imageAttachments';
import { DEFAULT_PROJECT, ensureDefaultProject } from './defaultProject';

function splitResultWithInlineThoughts(keyPrefix: string, raw: string, isLive: boolean, existingThoughts: Set<string>): StreamItem[] {
  const out: StreamItem[] = [];
  const regex = /<think>([\s\S]*?)(?:<\/think>|$)/gi;
  let lastIndex = 0;
  let visible = '';
  let match: RegExpExecArray | null;
  let idx = 0;
  let hadThink = false;
  while ((match = regex.exec(raw)) !== null) {
    hadThink = true;
    visible += raw.slice(lastIndex, match.index);
    const closed = /<\/think>$/i.test(match[0]);
    const thought = match[1].trim();
    if (thought && !existingThoughts.has(thought)) {
      existingThoughts.add(thought);
      out.push({ kind: 'think', key: `${keyPrefix}:inline-think:${idx++}`, text: thought, done: closed || !isLive });
    }
    lastIndex = regex.lastIndex;
  }
  if (!hadThink) {
    return raw ? [{ kind: 'text', key: `${keyPrefix}:answer`, text: raw, live: isLive }] : [];
  }
  visible += raw.slice(lastIndex);
  if (visible.trim()) {
    out.push({ kind: 'text', key: `${keyPrefix}:answer`, text: visible.trim(), live: isLive });
  }
  return out;
}

function turnToStreamItems(t: CloudTurn, isWorking: boolean): StreamItem[] {
  const out: StreamItem[] = [{ kind: 'user', key: `${t.key}:prompt`, text: t.prompt }];
  const seenThoughts = new Set<string>();
  for (let idx = 0; idx < (t.steps?.length ?? 0); idx++) {
    const step = t.steps![idx];
    if (step.kind === 'think') {
      const text = step.text?.trim();
      if (text && !seenThoughts.has(text)) {
        seenThoughts.add(text);
        out.push({ kind: 'think', key: `${t.key}:step:${step.id ?? idx}`, text, done: step.done ?? !isWorking });
      }
    } else if (step.kind === 'tool') {
      const callId = step.call_id ?? step.id ?? `${t.key}:tool:${idx}`;
      const done = step.done ?? (step.status ? step.status !== 'running' : !isWorking);
      const args = step.args ?? (typeof step.input === 'string' && step.input ? { command: step.input } : step.input ?? {});
      const result = step.result ?? step.output ?? (step.error ? { error: step.error } : undefined);
      out.push({ kind: 'tool', key: `${t.key}:step:${callId}`, callId, name: step.name ?? 'tool', args, result, done });
    }
  }
  if (t.result) {
    out.push(...splitResultWithInlineThoughts(t.key, t.result, isWorking, seenThoughts));
  }
  return out;
}

export function CloudAgentPage(p: { project: string; path?: string; projects?: {id: string; name: string}[]; onProject?: (id: string) => void; onCreateProject?: () => void; onPending?: (seed: CloudLaunchSeed | null) => void; onCreated: (m: Mission) => void }) {
  const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [provider, setProvider] = createSignal<CloudProvider>(defaultCloudProvider([], readCloudProvider()) );
  const [accountId, setAccountId] = createSignal('');
  const [model, setModel] = createSignal(''); const [modelParams,setModelParams]=createSignal<ModelParam[]>([]);
  const [repositoriesLoading, setRepositoriesLoading] = createSignal(true);
  const [repo, setRepo] = createSignal(''); const [ref, setRef] = createSignal('');
  const [options, setOptions] = createSignal<{models: {id: string; name?: string; displayName?: string}[]; repos: {url: string}[]}>({models: [], repos: []});
  const [error, setError] = createSignal(''); const [busy, setBusy] = createSignal(false); const [loaded, setLoaded] = createSignal(false);
  const [launching, setLaunching] = createSignal<CloudLaunchSeed | null>(null);
  const [open, setOpen] = createSignal<string | null>(null);
  const close = () => setOpen(null);
  let attempt: { signature: string; key: string; prompt: string } | undefined;
  let explicit = false;
  const account = () => accounts().find(a => a.provider === provider() && a.id === accountId()) ?? accounts().find(a => a.provider === provider() && a.available) ?? accounts().find(a => a.provider === provider());
  const canAttach = () => Boolean(account()?.capabilities.attachments);
  onMount(async () => {
    try { const list = await cloudAccounts(); setAccounts(list); if (!explicit) setProvider(defaultCloudProvider(list, readCloudProvider())); }
    catch(e) { setError(String(e)); } finally { setLoaded(true); }
  });
  const choose = (value: CloudProvider) => {
    explicit = true; writeCloudProvider(value);
    setError(''); setProvider(value); setAccountId(''); setModel(''); setModelParams([]); setRepo(''); setRef('');
  };
  const submit = async (text: string, images: DraftImage[]) => {
    const rawPrompt = text.trim() || (images.length ? "Please look at the attached images." : "");
    const chosen = account();
    if (busy() || !chosen?.available || !rawPrompt || !p.project) return false;
    if (images.length && !canAttach()) { setError(cloudAttachmentBlock(provider(), chosen) ?? ''); return false; }
    const cloud = { provider: provider(), account: chosen.id, ...(model() ? {model: model()} : {}), ...(modelParams().length ? {model_params: modelParams()} : {}), ...(repo() ? {repository: repo()} : {}), ...(ref() ? {git_ref: ref()} : {}) };
    const tags = p.path ? [`orb-folder:${p.path}`] : [];
    const signature = JSON.stringify({ prompt: rawPrompt, images: images.map(i => i.id), project: p.project, tags, cloud });
    // Show the conversation the mission will open into right away: the prompt
    // as its first bubble, the Working row and the composer in place.
    const seed: CloudLaunchSeed = { prompt: rawPrompt, images, provider: provider(), account: chosen.id };
    setBusy(true); setError(''); setLaunching(seed); p.onPending?.(seed);
    try {
      if (p.project === DEFAULT_PROJECT.slug) await ensureDefaultProject().catch(swallow("cloudAgents.ensureDefaultProject"));
      if (attempt?.signature !== signature) {
        const sent = images.length ? imagePrompt(rawPrompt, await stageRemoteImages(images, undefined, "core"), images) : rawPrompt;
        attempt = { signature, key: crypto.randomUUID(), prompt: sent };
      }
      const m = await launchCloud({ title: rawPrompt.slice(0, 100), prompt: attempt.prompt, project: p.project, tags, cloud, idempotency_key: attempt.key });
      cloudLaunchSeeds.set(m.id, seed);
      attempt = undefined;
      p.onCreated(m);
      return true;
    } catch(e) { setError(String(e)); setLaunching(null); p.onPending?.(null); return false; }
    finally { setBusy(false); }
  };
  const picks = <div class="picks">
    <AgentChoice label="Service" value={provider()} items={Object.entries(cloudNames).map(([value,label]) => ({value,label}))} disabled={busy()}
      open={open() === 'service'} onOpen={() => setOpen('service')} onClose={close} onSelect={value => void choose(value as CloudProvider)}/>
    <Show when={account()?.available && account()?.capabilities.models}><CloudModelPicker provider={provider()} model={model()} params={modelParams()} disabled={busy()} onChange={(model,params)=>{setModel(model);setModelParams(params);}} onError={setError} onRepositories={repos=>setOptions({models:[],repos})} onRepositoriesLoading={setRepositoriesLoading}/></Show>
  </div>;
  return <>
  <Show when={launching()}>{seed => <CloudConversation id="" launch={seed()} />}</Show>
  <section class="new-agent cloud-agent-page" aria-label="Cloud agent" style={{display: launching() ? 'none' : undefined}}><div class="new-inner">
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
    {/* The shared composer, as on a new mission: "+" sits at the same left inset. */}
    <Composer tall autofocus picker={false} busy={false} onPending={() => {}} onSendError={setError}
      scope={`cloud:new:${provider()}`} placeholder="Describe a task for your cloud agent" inputLabel="Prompt" sendLabel="Create cloud agent"
      disabled={busy() || !account()?.available || !p.project}
      textOnly={!canAttach()} attachDisabledReason={cloudAttachmentBlock(provider(), account())}
      imagesOnly={canAttach() && provider() !== 'hermes'} directFileUpload={provider() === 'hermes'}
      controls={picks} onSend={submit} />
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
      <Show when={error()}><p class="cloud-note inline-error" role="alert">{error()}</p></Show>
    </div>
  </div></section></>;
}
export function CloudConversation(p: { id: string; launch?: CloudLaunchSeed; onMission?: (m: Mission | null) => void; onOpenMission?: (m:Mission)=>void }) {
  // Between submit and the first server state, the prompt the user just sent
  // is the first bubble, so the view does not flash a loading line or jump.
  const seed = () => p.launch ?? cloudLaunchSeeds.get(p.id);
  const [children,setChildren]=createSignal<{id:string;title:string;status:string}[]>([]);
  const [execution, setExecution] = createSignal<CloudExecution>(); const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [error, setError] = createSignal(''); const [busy, setBusy] = createSignal(false);
  const [model,setModel]=createSignal(''),[modelParams,setModelParams]=createSignal<ModelParam[]>([]);
  let initializedFor = '';
  createEffect(()=>{
    const e=execution();
    if(e&&initializedFor!==e.mission_id){
      initializedFor=e.mission_id;
      setModel(e.turns.at(-1)?.model ?? e.selection.model ?? '');
      setModelParams(e.turns.at(-1)?.model_params ?? e.selection.model_params ?? []);
    }
  });
  let attempt: {signature: string; text: string; key: string; model:string; params:ModelParam[]} | undefined; let stopPoll: (() => void) | undefined; let stopFastPoll: (() => void) | undefined; let disposed = false; let refreshing: Promise<void> | undefined;
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
  const working = (t: {phase: string}) => ['queued', 'submitting', 'running', 'waiting_user', 'cancel_requested'].includes(t.phase);
  const active = () => execution()?.turns.some(working) ?? false;
  onMount(() => {
    void cloudAccounts().then(value => { if (!disposed) setAccounts(value); }).catch(e => { if (!disposed) setError(String(e)); });
    if (!p.id) return;
    void refresh();
    stopPoll = pollWhileVisible(refresh, 2500);
    stopFastPoll = pollWhileVisible(() => (active() || !execution() ? refresh() : undefined), 750);
  });
  onCleanup(() => { disposed = true; stopPoll?.(); stopFastPoll?.(); if (p.id) p.onMission?.(null); });
  createEffect(() => { if (execution()?.turns.length) cloudLaunchSeeds.delete(p.id); });
  const selection = () => execution()?.selection ?? (seed() ? { provider: seed()!.provider, account: seed()!.account ?? '' } : undefined);
  const account = () => accounts().find(a => a.id === selection()?.account && a.provider === selection()?.provider);
  // Optimistic send, like a mission follow-up: the message is in the transcript
  // the moment it is sent, and leaves once the provider reports it as a turn.
  const [outgoing, setOutgoing] = createSignal<{id: string; text: string; images: DraftImage[]; turns: number}[]>([]);
  const [sendError, setSendError] = createSignal<string | null>(null);
  const pin = createPinnedScroll({ key: () => p.id });
  pin.observe();
  const send = async (text: string, images: DraftImage[] = []) => {
    if ((!text.trim() && !images.length) || !execution() || !cloudCanSend(execution()!)) return false;
    const signature = JSON.stringify({ text, images: images.map(i => i.id), model: model(), params: modelParams() });
    const row = { id: crypto.randomUUID(), text, images, turns: execution()!.turns.length + outgoing().length };
    setOutgoing(rows => [...rows, row]); setSendError(null); pin.pin();
    try {
      if (attempt?.signature !== signature) {
        const sent = images.length ? imagePrompt(text, await stageRemoteImages(images, undefined, "core"), images) : text;
        attempt = { signature, text: sent, key: crypto.randomUUID(), model: model(), params: modelParams() };
      }
      await api('/api/control/message', {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({mission_id: p.id, content: attempt.text, client_message_id: attempt.key,...(attempt.model || attempt.params.length || execution()?.selection.provider==='hermes' ? {cloud_model:attempt.model,cloud_model_params:attempt.params}: {})})});
      attempt = undefined; await refresh(); return true;
    } catch(e) { setOutgoing(rows => rows.filter(r => r.id !== row.id)); setSendError(String(e)); return false; }
  };
  // A sent row is replaced by the turn the provider opens for it.
  createEffect(() => { const n = execution()?.turns.length ?? 0; setOutgoing(rows => { const kept = rows.filter(r => n <= r.turns); return kept.length === rows.length ? rows : kept; }); });
  const cancel = async () => { setBusy(true); try { await api(`/api/control/missions/${p.id}/cloud/cancel`, {method:'POST'}); } catch(e) { setError(String(e)); } finally { setBusy(false); } };
  const approve = async (run_id:string, request_id:string|undefined, choice:string) => {
    setBusy(true);
    try {await api(`/api/control/missions/${p.id}/cloud/approval`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({run_id,request_id,choice})});await refresh();}
    catch(e){setError(String(e));}finally{setBusy(false);}
  };
  const download = async (path: string) => { try { const result = await api<{url?:string; content_base64?:string; name?:string}>(`/api/control/missions/${p.id}/cloud/artifact?path=${encodeURIComponent(path)}`); if (result.content_base64) { const bytes = Uint8Array.from(atob(result.content_base64), c => c.charCodeAt(0)); const blob = URL.createObjectURL(new Blob([bytes], {type:'application/octet-stream'})); const link = document.createElement('a'); link.href = blob; link.download = result.name ?? 'artifact'; link.click(); setTimeout(() => URL.revokeObjectURL(blob), 10000); return; } const url = safeCloudUrl(result.url); if (!url) throw new Error('Invalid artifact URL'); await openExternalUrl(url); } catch(e) {setError(String(e));} };
  const launchItems = (): StreamItem[] => { const s = seed(); return s && !execution()?.turns.length ? [{ kind: 'user', key: 'launch:prompt', text: s.prompt, images: s.images }] : []; };
  const launchPending = () => !execution()?.turns.length && !!seed();
  const items = (): StreamItem[] => [...launchItems(), ...(execution()?.turns ?? []).flatMap(t => turnToStreamItems(t, working(t))),
    ...outgoing().map((r): StreamItem => ({ kind: 'user', key: `outgoing:${r.id}`, text: r.text, images: r.images, messageId: r.id }))];
  createEffect(on(items, () => queueMicrotask(pin.scrollIfPinned), { defer: true }));
  createEffect(on(execution, e => { if (e) queueMicrotask(pin.landAtBottom); }));
  const progress = () => {
    const t = execution()?.turns.find(working); if (!t) return;
    return t.phase === 'cancel_requested' ? 'Stopping…' : t.phase === 'queued' ? 'Queued…'
      : t.phase === 'waiting_user' ? 'Waiting for approval' : t.phase === 'submitting' ? (t.detail ?? `Opening ${cloudNames[execution()!.selection.provider]}…`)
      : t.result ? 'Writing…' : (t.detail ?? 'Working…');
  };
  return <><div class="scroll" ref={pin.ref} onScroll={pin.onScroll}><div class="col">
    <Show when={error()}><p class="cloud-note inline-error" role="alert">{error()}</p></Show>
    <Show when={execution() || seed()} fallback={<div class="sk-transcript" role="status" aria-label="Loading conversation" aria-busy="true"><div class="sk-lines" aria-hidden="true"><i style={{ width: "58%" }} /><i style={{ width: "86%" }} /><i style={{ width: "72%" }} /></div></div>}>
      <Transcript sizeKey={`m:${p.id || 'launch'}`} items={items()} pending={launchPending() || (active() && !outgoing().length)} sending={outgoing().at(-1)?.id} working={launchPending() || active() || outgoing().length > 0} workingLabel={progress() ?? (launchPending() ? 'Working…' : 'Sending…')}/>
    </Show>
    <Show when={execution()}>{e => <>
      <Show when={children().length}><div aria-label="Delegated missions"><For each={children()}>{child=><p><button class="na-drop-btn" onClick={()=>void getMission(child.id).then(m=>p.onOpenMission?.(m)).catch(e=>setError(String(e)))}>{child.title || child.id}</button> · {child.status}</p>}</For></div></Show>
      <For each={e().turns}>{turn => <>
        <Show when={turn.detail && !working(turn)}><p class="cloud-note">{turn.detail}</p></Show>
        <For each={turn.branches}>{branch => <p>{branch.branch} <Show when={safeCloudUrl(branch.prUrl)}>{url => <a href={url()} target="_blank" rel="noopener noreferrer">View pull request</a>}</Show></p>}</For>
        <For each={turn.artifacts.filter(a=>a.kind==='hermes_approval' && turn.phase==='waiting_user')}>{approval => <div role="group" aria-label="Hermes approval"><p>{approval.request?.command ?? 'Hermes is waiting for your approval.'}</p><For each={approval.request?.choices ?? ['once','deny']}>{choice=><button class="na-drop-btn" disabled={busy()} onClick={()=>void approve(approval.run_id!,approval.request?.request_id,choice)}>{choice==='once'?'Approve once':choice==='deny'?'Deny':choice}</button>}</For></div>}</For>
        <For each={turn.artifacts.filter(a=>!a.kind)}>{artifact => <p><button class="na-drop-btn" onClick={() => void download(artifact.path)}>Download {artifact.path}</button></p>}</For>
      </>}</For>
    </>}</Show>
  </div></div><div class="dock" ref={floatingDock}><JumpToLatest pinned={pin.pinned} onJump={pin.pin} /><div class="col">
    <Show when={!execution() && seed()}>{s => <>
      <Composer picker={false} textOnly scope={`cloud:${p.id || 'launch'}`} placeholder="Send follow-up" busy disabled onPending={() => {}} onSend={() => false}/>
      <div class="cloud-conversation-meta"><ProviderLogo type={s().provider}/><span>{cloudNames[s().provider]}</span><span role="status">{cloudPhase('submitting')}</span></div>
    </>}</Show>
    <Show when={execution()}>{e => <>
      <Show when={account()?.capabilities.follow_up}><Composer allowConcurrentSend retainFailedMessage onPending={() => {}} onSendError={setSendError} textOnly={!account()?.capabilities.attachments} imagesOnly={Boolean(account()?.capabilities.attachments) && e().selection.provider !== 'hermes'} directFileUpload={e().selection.provider === 'hermes'} picker={false} scope={`cloud:${p.id}`} placeholder="Send follow-up" busy={active()} disabled={!cloudCanSend(e())} onSend={send}
        onStop={account()?.capabilities.cancel && e().turns.some(t => t.external_id && ['running','submitting','waiting_user'].includes(t.phase)) ? () => void cancel() : undefined}/></Show>
      <ErrorToast error={sendError()} title="Couldn’t send your message" onDismiss={() => setSendError(null)} />
      <div class="cloud-conversation-meta"><ProviderLogo type={e().selection.provider}/><span title={account()?.label}>{cloudNames[e().selection.provider]}<Show when={!account() || cloudAccountLabel(account()!) !== cloudNames[e().selection.provider]}> · {account() ? cloudAccountLabel(account()!) : e().selection.account}</Show></span>
        {/* Like the agent composer: model and effort are chosen below the field, not inside it. */}
        <Show when={account()?.capabilities.models} fallback={<>
          <Show when={model() || (e().turns.at(-1)?.model ?? e().selection.model)}><span> · {model() || e().turns.at(-1)?.model || e().selection.model}</span></Show>
          <Show when={(modelParams().find(x => x.id === 'effort')?.value ?? (e().turns.at(-1)?.model_params ?? e().selection.model_params)?.find(x => x.id === 'effort')?.value)}>{eff => <span> · {eff()}</span>}</Show>
        </>}>
          <div class="picks cloud-meta-picks"><CloudModelPicker provider={e().selection.provider} model={model()} params={modelParams()} disabled={busy()} onChange={(model,params)=>{setModel(model);setModelParams(params);}} onError={setError}/></div>
        </Show>
        <span role="status">{cloudPhase(e().turns.at(-1)?.phase ?? '')}</span>
        <Show when={safeCloudUrl(e().external_url)}>{url => <a href={url()} onClick={event => {event.preventDefault(); void openExternalUrl(url());}}>Open in {cloudNames[e().selection.provider]}</a>}</Show>
      </div>
    </>}</Show>
  </div></div></>;
}
