import { pollWhileVisible } from "./poll";
import { QuizAnswer } from "./QuizAnswer";
import * as Ic from "./icons";
import { For, Show, createSignal, createEffect, onMount, onCleanup } from 'solid-js';
import { api, getMission, openExternalUrl, type Mission } from './api';
import { cloudAccounts, cloudAccountLabel, cloudCanSend, cloudExecution, cloudNames, cloudPhase, launchCloud, safeCloudUrl, type CloudAccount, type CloudExecution, type CloudProvider } from './cloudAgentApi';
import './cloudAgents.css';
import { Composer, floatingDock } from './App';
import { Transcript } from './Transcript';
import type { StreamItem } from './transcriptModel';
import { ProjectPicker } from './ProjectPicker';
import { CloudModelPicker } from './CloudModelPicker';
import type { ModelParam } from './cloudAgentApi';
import { AgentChoice, AgentChoiceMenu } from './AgentChoice';
export function CloudAgentPage(p: { project: string; path?: string; projects?: {id: string; name: string}[]; onProject?: (id: string) => void; onCreateProject?: () => void; onCreated: (m: Mission) => void }) {
  const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [provider, setProvider] = createSignal<CloudProvider>('chatgpt');
  const [accountId, setAccountId] = createSignal('');
  const [prompt, setPrompt] = createSignal(''); const [model, setModel] = createSignal(''); const [modelParams,setModelParams]=createSignal<ModelParam[]>([]);
  const [repositoriesLoading, setRepositoriesLoading] = createSignal(true);
  const [repo, setRepo] = createSignal(''); const [ref, setRef] = createSignal('');
  const [options, setOptions] = createSignal<{models: {id: string; name?: string; displayName?: string}[]; repos: {url: string}[]}>({models: [], repos: []});
  const [error, setError] = createSignal(''); const [busy, setBusy] = createSignal(false); const [loaded, setLoaded] = createSignal(false);
  const [open, setOpen] = createSignal<string | null>(null);
  const close = () => setOpen(null);
  let attempt: { signature: string; key: string } | undefined;
  const account = () => accounts().find(a => a.provider === provider() && a.id === accountId()) ?? accounts().find(a => a.provider === provider() && a.available) ?? accounts().find(a => a.provider === provider());
  onMount(async () => { try { setAccounts(await cloudAccounts()); } catch(e) { setError(String(e)); } finally { setLoaded(true); } });
  const choose = (value: CloudProvider) => {
    setError(''); setProvider(value); setAccountId(''); setModel(''); setModelParams([]); setRepo(''); setRef('');
  };
  const submit = async () => {
    if (busy() || !account()?.available || !prompt().trim()) return;
    const body = { title: prompt().trim().slice(0, 100), prompt: prompt(), project: p.project, tags: p.path ? [`orb-folder:${p.path}`] : [], cloud: { provider: provider(), account: account()!.id, ...(model() ? {model: model(), ...(modelParams().length ? {model_params:modelParams()} : {})} : {}), ...(repo() ? {repository: repo()} : {}), ...(ref() ? {git_ref: ref()} : {}) } };
    const signature = JSON.stringify(body);
    if (attempt?.signature !== signature) attempt = {signature, key: crypto.randomUUID()};
    setBusy(true); setError('');
    try { p.onCreated(await launchCloud({...body, idempotency_key: attempt.key})); } catch(e) { setError(String(e)); } finally { setBusy(false); }
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
      <Show when={account()}><AgentChoice label="Account" description={account()?.label} meta value={account()!.id} items={accounts().filter(a => a.provider === provider()).map(a => ({value:a.id, label:cloudAccountLabel(a),description:a.label}))}
        icon={<Ic.CloudIcon size={14}/>} suffix={<Show when={account()?.experimental}><span class="cloud-experimental" title="Experimental connector" aria-label="Experimental connector"><Ic.FlaskIcon size={13}/></span></Show>}
        disabled={busy()} open={open() === 'account'} onOpen={() => setOpen('account')} onClose={close} onSelect={setAccountId}/></Show>
    </div>
    <div class="composer tall">
      <div class="composer-field"><textarea aria-label="Prompt" autofocus rows={2} placeholder="Describe a task for your cloud agent" value={prompt()} disabled={busy()} onInput={e => setPrompt(e.currentTarget.value)} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); void submit(); } }} /></div>
      <div class="plus-wrap"><Ic.CloudIcon size={16} /></div>
      <div class="picks">
        <AgentChoice label="Service" value={provider()} items={Object.entries(cloudNames).map(([value,label]) => ({value,label}))} disabled={busy()}
          open={open() === 'service'} onOpen={() => setOpen('service')} onClose={close} onSelect={value => void choose(value as CloudProvider)}/>
        <Show when={account()?.available && account()?.capabilities.models}><CloudModelPicker provider={provider()} model={model()} params={modelParams()} disabled={busy()} onChange={(model,params)=>{setModel(model);setModelParams(params);}} onError={setError} onRepositories={repos=>setOptions({models:[],repos})} onRepositoriesLoading={setRepositoriesLoading}/></Show>
      </div>
      <div class="send-slot"><button class="send" aria-label="Create cloud agent" title="Create cloud agent" disabled={busy() || !account()?.available || !prompt().trim() || !p.project} onClick={() => void submit()}><Show when={busy()} fallback={<Ic.ArrowUpIcon size={14} />}><Ic.Spinner size={14} /></Show></button></div>
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
export function CloudConversation(p: { id: string; onMission?: (m: Mission | null) => void }) {
  const [execution, setExecution] = createSignal<CloudExecution>(); const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [error, setError] = createSignal(''); const [busy, setBusy] = createSignal(false);
  const [model,setModel]=createSignal(''),[modelParams,setModelParams]=createSignal<ModelParam[]>([]);
  let initialized=false;
  createEffect(()=>{const e=execution();if(e&&!initialized){initialized=true;setModel(e.turns.at(-1)?.model ?? e.selection.model ?? '');setModelParams(e.turns.at(-1)?.model_params ?? e.selection.model_params ?? []);}});
  let attempt: {text: string; key: string; model:string; params:ModelParam[]} | undefined; let stopPoll: (() => void) | undefined; let disposed = false; let refreshing: Promise<void> | undefined;
  const refresh = (): Promise<void> => {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      try { const [e, m] = await Promise.all([cloudExecution(p.id), getMission(p.id)]);
        if (!disposed) { setExecution(old => JSON.stringify(old) === JSON.stringify(e) ? old : e); p.onMission?.(m); setError(''); }
      } catch(e) { if (!disposed) setError(`Connection lost. Last observed state is preserved. ${String(e)}`); }
      finally { refreshing = undefined; }
    })();
    return refreshing;
  };
  onMount(() => { void refresh(); stopPoll = pollWhileVisible(refresh, 3000); void cloudAccounts().then(value => { if (!disposed) setAccounts(value); }).catch(e => { if (!disposed) setError(String(e)); }); });
  onCleanup(() => { disposed = true; stopPoll?.(); p.onMission?.(null); });
  const account = () => accounts().find(a => a.id === execution()?.selection.account && a.provider === execution()?.selection.provider);
  const send = async (text: string) => {
    if (busy() || !text.trim() || !execution() || !cloudCanSend(execution()!)) return false;
    if (attempt?.text !== text || attempt?.model!==model() || JSON.stringify(attempt?.params)!==JSON.stringify(modelParams())) attempt = {text, key: crypto.randomUUID(),model:model(),params:modelParams()};
    setBusy(true);
    try { await api('/api/control/message', {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({mission_id: p.id, content: attempt.text, client_message_id: attempt.key,...(attempt.model ? {cloud_model:attempt.model,cloud_model_params:attempt.params}: {})})}); attempt = undefined; await refresh(); return true; } catch(e) { setError(String(e)); return false; } finally { setBusy(false); }
  };
  const cancel = async () => { setBusy(true); try { await api(`/api/control/missions/${p.id}/cloud/cancel`, {method:'POST'}); } catch(e) { setError(String(e)); } finally { setBusy(false); } };
  const download = async (path: string) => { try { const result = await api<{url?:string; content_base64?:string; name?:string}>(`/api/control/missions/${p.id}/cloud/artifact?path=${encodeURIComponent(path)}`); if (result.content_base64) { const bytes = Uint8Array.from(atob(result.content_base64), c => c.charCodeAt(0)); const blob = URL.createObjectURL(new Blob([bytes], {type:'application/octet-stream'})); const link = document.createElement('a'); link.href = blob; link.download = result.name ?? 'artifact'; link.click(); setTimeout(() => URL.revokeObjectURL(blob), 10000); return; } const url = safeCloudUrl(result.url); if (!url) throw new Error('Invalid artifact URL'); await openExternalUrl(url); } catch(e) {setError(String(e));} };
  const working = (t: {phase: string}) => ['queued', 'submitting', 'running', 'cancel_requested'].includes(t.phase);
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
      : t.phase === 'submitting' ? (t.detail ?? `Opening ${cloudNames[execution()!.selection.provider]}…`)
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
            onSubmit={send}/>
        </Show>}/>
      <Show when={progress()}>{text => <p class="cloud-working" role="status"><span class="cloud-working-dot" aria-hidden="true"/>{text()}</p>}</Show>
      <For each={e().turns}>{turn => <>
        <Show when={turn.detail && !working(turn)}><p class="cloud-note">{turn.detail}</p></Show>
        <For each={turn.branches}>{branch => <p>{branch.branch} <Show when={safeCloudUrl(branch.prUrl)}>{url => <a href={url()} target="_blank" rel="noopener noreferrer">View pull request</a>}</Show></p>}</For>
        <For each={turn.artifacts}>{artifact => <p><button class="na-drop-btn" onClick={() => void download(artifact.path)}>Download {artifact.path}</button></p>}</For>
      </>}</For>
    </>}</Show>
  </div></div><div class="dock" ref={floatingDock}><div class="col">
    <Show when={execution()}>{e => <>
      <Show when={account()?.capabilities.follow_up}><Composer textOnly picker={false} scope={`cloud:${p.id}`} placeholder="Continue this conversation…" busy={active()} disabled={busy() || !cloudCanSend(e())} onSend={send} controls={<Show when={account()?.capabilities.models}><div class="picks"><CloudModelPicker provider={e().selection.provider} model={model()} params={modelParams()} disabled={busy()} onChange={(model,params)=>{setModel(model);setModelParams(params);}} onError={setError}/></div></Show>}
        onStop={account()?.capabilities.cancel && e().turns.some(t => t.external_id && ['running','submitting'].includes(t.phase)) ? () => void cancel() : undefined}/></Show>
      <div class="cloud-conversation-meta"><span title={account()?.label}>{cloudNames[e().selection.provider]}<Show when={!account() || cloudAccountLabel(account()!) !== cloudNames[e().selection.provider]}> · {account() ? cloudAccountLabel(account()!) : e().selection.account}</Show></span>
        <span role="status">{cloudPhase(e().turns.at(-1)?.phase ?? '')}</span>
        <Show when={safeCloudUrl(e().external_url)}>{url => <a href={url()} onClick={event => {event.preventDefault(); void openExternalUrl(url());}}>Open in {cloudNames[e().selection.provider]}</a>}</Show>
      </div>
    </>}</Show>
  </div></div></>;
}
