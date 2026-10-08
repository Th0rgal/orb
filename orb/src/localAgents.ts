import { getCyber, requireCyberSupport, type CyberMode } from "./cyberAccess";
import {followNative} from "./nativeInteractionStream";
import { rememberClientRunReceipt, type ClientRunReceipt } from "./clientRuns";
/**
 * Local harnesses: the CLIs installed on this computer, not a sandboxed.sh
 * runner. Detection and process control go through Tauri. Mention rewriting
 * is pure and tested without a desktop shell.
 */
import { bufferedOutput, type OutputEvent } from "./localStream";
import { createSignal } from "solid-js";
import { mentionText, scanMentions, type AttachChip } from "./attach";
import { getApiUrl, getJwt, listProjectFiles, readProjectFile, getProjectController } from "./api";

function savedLocalFailures(): Record<string,string> {
  try { return JSON.parse(localStorage.getItem("orb.localFailures") ?? "{}"); } catch { return {}; }
}
const [localFailures, setLocalFailures] = createSignal<Record<string,string>>(savedLocalFailures());
export const localFailure = (id:string) => localFailures()[id];
export function recordLocalFailure(id:string, error:unknown) {
  const message = error == null ? "" : error instanceof Error ? error.message : String(error);
  setLocalFailures(previous => { const next={...previous}; if(message)next[id]=message;else delete next[id];
    try {localStorage.setItem("orb.localFailures",JSON.stringify(next));} catch {} return next; });
}
export const LOCAL_HARNESSES = ["claudecode", "codex", "grok", "opencode", "antigravity"] as const;
export type LocalHarnessId = (typeof LOCAL_HARNESSES)[number];

const FILE_CAP = 512 * 1024;
const FOLDER_CAP = 256 * 1024;
const PATH_KEY = "orb.localAgentPaths";
const BIND_KEY = "orb.localBindings";

export interface ScanRow {
  models?: [string,string][];
  auth_error?: string | null;
  id: string;
  bin: string;
  path?: string | null;
  version?: string | null;
  installed: boolean;
  plan_supported?: boolean;
}

export interface LocalBinding {
  harness: string;
  bin: string;
  cwd: string;
  model?: string;
  effort?: string;
  sessionId?: string;
  transferId?: string;
}

export interface LocalFile {
  encoding?: "base64";
  rel: string;
  content: string;
}

const [installed, setInstalled] = createSignal<ScanRow[]>([]);
const runVersions = new Map<string,number>();
const launching = new Set<string>();
const [running, setRunning] = createSignal<Record<string, boolean>>({});
const [liveText, setLiveText] = createSignal<Record<string, string>>({});

export const localInstalled = installed;
export const localRunKnown = (id:string) => Object.hasOwn(running(),id);
export const localRunActive = (id: string) => !!running()[id];
export interface LocalActivity {
  id: string; label: string; done: boolean; failed: boolean;
  kind?: string; background?: boolean; tool_use_id?: string | null;
  detail?: string | null; status?: string; started_at?: number;
  updated_at?: number; finished_at?: number | null; thinking_tokens?: number | null;
}
const [activities, setActivities] = createSignal<Record<string, LocalActivity[]>>({});
export const localActivities = (id: string) => activities()[id] ?? [];
export const localLiveText = (id: string) => liveText()[id] ?? "";

export function pathOverrides(): Record<string, string> {
  try {
    const raw = localStorage.getItem(PATH_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    return parsed && typeof parsed === "object" ? (parsed as Record<string, string>) : {};
  } catch {
    return {};
  }
}

export function setPathOverride(id: string, path: string) {
  const next = pathOverrides();
  const trimmed = path.trim();
  if (trimmed) next[id] = trimmed;
  else delete next[id];
  localStorage.setItem(PATH_KEY, JSON.stringify(next));
}

const [bindings, setBindings] = createSignal<Record<string, LocalBinding>>({});
let bindingsReady: Promise<void> | undefined;
let bindingRevision=-1;
type BindingSnapshot={revision:number;bindings:Record<string,LocalBinding>};
const applyBindings=(snapshot:BindingSnapshot)=>{if(snapshot.revision>=bindingRevision){bindingRevision=snapshot.revision;setBindings(snapshot.bindings);}};
export function localBinding(id: string): LocalBinding | undefined { return bindings()[id]; }
export async function rememberBinding(id: string, binding: LocalBinding) {
 await restoreLocalBindings();
 if(JSON.stringify(bindings()[id])===JSON.stringify(binding))return;
 const invoke=tauriInvoke();if(!invoke)throw Error('Native storage unavailable.');
 applyBindings(await invoke('local_binding_set',{id,binding}) as BindingSnapshot);
}

type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

function tauriInvoke(): Invoke | null {
  const g = window as unknown as {
    __TAURI__?: { core?: { invoke?: Invoke } };
    __TAURI_INTERNALS__?: { invoke?: Invoke };
  };
  return g.__TAURI__?.core?.invoke ?? g.__TAURI_INTERNALS__?.invoke ?? null;
}

export async function refreshLocalBindings(): Promise<void> {
 await restoreLocalBindings();
 const invoke=tauriInvoke();
 if(!invoke)throw new Error('Native storage unavailable.');
 try { applyBindings(await invoke('local_bindings_refresh') as BindingSnapshot); }
 catch(error) {
  // An older native shell can coexist with the updated dev frontend until restart.
  if(!/local_bindings_refresh.*(?:not found|not allowed)|(?:unknown command|command not found).*local_bindings_refresh/i.test(String(error)))throw error;
 }
}

export function restoreLocalBindings(): Promise<void> {
 if(bindingsReady)return bindingsReady;
 if(!tauriInvoke())return Promise.resolve();
 bindingsReady=new Promise<void>((resolve,reject)=>{
  let initialized=false;
  const stop=followNative<{revision:number;bindings:Record<string,LocalBinding>}>('local_bindings',{},snapshot=>{
   applyBindings(snapshot);
   window.dispatchEvent(new Event('orb:queue-wake'));
   if(initialized)return;initialized=true;
   void (async()=>{
    let legacy:Record<string,LocalBinding>={};
    try{legacy=JSON.parse(localStorage.getItem(BIND_KEY)||'{}');}catch{/* Invalid legacy data is not imported. */}
    if(legacy&&typeof legacy==='object'&&!Array.isArray(legacy))for(const [id,binding] of Object.entries(legacy)){
     if(!snapshot.bindings[id]&&binding&&['harness','bin','cwd'].every(key=>typeof (binding as unknown as Record<string,unknown>)[key]==='string'))await tauriInvoke()!('local_binding_set',{id,binding,ifAbsent:true});
    }
    localStorage.removeItem(BIND_KEY);resolve();
   })().catch(error=>{bindingsReady=undefined;stop();reject(error);});
  },error=>{bindingsReady=undefined;stop();reject(error);});
  window.addEventListener('pagehide',stop,{once:true});
 });
 return bindingsReady;
}

const [scanning, setScanning] = createSignal(false);
export const localAgentsScanning = scanning;
let scanPromise: Promise<ScanRow[]> | undefined;
let scannedAt = 0;
let scannedPaths = "";
/** A known binary can start while inventory refreshes. Native spawn validates its path. */
export async function localAgentForLaunch(id:string):Promise<ScanRow|undefined>{
 const cached=installed().find(row=>row.id===id&&row.installed&&row.path);
 if(cached){void refreshLocalAgents(false);return cached;}
 return (await refreshLocalAgents(false)).find(row=>row.id===id&&row.installed&&row.path);
}

const localModelRequests = new Set<string>();
function refreshLocalAntigravityModels() {
  const path = installed().find(row => row.id === "antigravity")?.path;
  const invoke = tauriInvoke();
  if (!path || !invoke || localModelRequests.has(path)) return;
  localModelRequests.add(path);
  void invoke("local_antigravity_models", {path}).then(models => {
    setInstalled(rows => rows.map(row => row.id === "antigravity" && row.path === path ? {...row,models:models as [string,string][],auth_error:null} : row));
  }).catch(error => {
    setInstalled(rows => rows.map(row => row.id === "antigravity" && row.path === path ? {...row,models:[],auth_error:String(error)} : row));
  }).finally(() => localModelRequests.delete(path));
}

export function refreshLocalAgents(force = false): Promise<ScanRow[]> {
  if (scanPromise) return scanPromise;
  const paths = pathOverrides();
  const key = JSON.stringify(paths);
  if (!force && key === scannedPaths && Date.now() - scannedAt < 60_000) return Promise.resolve(installed());
  setScanning(true);
  scanPromise = (async () => {
    const invoke = tauriInvoke();
    if (!invoke) { setInstalled([]); return []; }
    try {
      const rows = await invoke("local_agents_scan", { request: { overrides: paths } }) as ScanRow[];
      // Older desktop builds tied `installed` to the version probe succeeding.
      // A resolved path is enough to launch; missing version only limits capabilities.
      setInstalled(Array.isArray(rows) ? rows.map(row => ({...row, installed: !!row.path})) : []);
      scannedAt = Date.now(); scannedPaths = key;
      refreshLocalAntigravityModels();
      return installed();
    } catch { return installed(); }
  })().finally(() => { setScanning(false); scanPromise = undefined; });
  return scanPromise;
}

export function installedIds(): string[] {
  return installed().filter((row) => row.installed && row.path).map((row) => row.id);
}

/** Same secret names the backend refuses to materialize. */
export function isSecretPath(rel: string): boolean {
  const lower = rel.replace(/\\/g, "/").toLowerCase();
  const name = lower.split("/").pop() ?? lower;
  if (lower.split("/").some((part) => [".git", ".ssh", ".aws", ".codex", ".claude"].includes(part) || part === ".env" || part.startsWith(".env."))) {
    return true;
  }
  return (
    name === ".env" ||
    name.startsWith(".env.") ||
    name.endsWith(".pem") ||
    name.endsWith(".key") ||
    name === "id_rsa" ||
    name.startsWith("id_rsa.") ||
    name.startsWith("id_ed25519") ||
    name.includes("credentials") ||
    name === "auth.json" ||
    name === "secrets" ||
    name === "secrets.yaml" ||
    name === "secrets.yml" ||
    name === "secrets.json" ||
    name.endsWith(".p12") ||
    name.endsWith(".pfx")
  );
}

export function quotePath(path: string): string {
  return /[\s"]/.test(path) ? `"${path.replace(/"/g, '\\"')}"` : path;
}

/** Replace each written mention with the absolute path that was copied. */
export function rewritePrompt(text: string, replacements: Array<{ raw: string; absolute: string }>): string {
  let out = text;
  for (const row of replacements) {
    if (!row.raw) continue;
    out = out.replace(row.raw, quotePath(row.absolute));
  }
  return out;
}

export interface MaterializeResult {
  prompt: string;
  files: LocalFile[];
  note: string;
}

/**
 * Copy plan for the mentions in `text`. Unknown `@words` stay prose.
 * A secret or unreadable mentioned file refuses the send.
 */
export async function materializeMentions(
  slug: string,
  text: string,
  chips: AttachChip[],
  readFile: (path: string) => Promise<string> = (path) => readProjectFile(slug, path),
  listDir: (path: string) => Promise<Array<{ name: string; kind: string }>> = async (path) => listProjectFiles(slug, path),
): Promise<MaterializeResult> {
  const mentions = scanMentions(text).map(m=>{
    if(m.raw.startsWith('@"'))return m;
    const value=m.value.replace(/[.,;:!?]+$/,"");
    return {...m,value,raw:m.raw.slice(0,m.raw.length-(m.value.length-value.length))};
  });
  const files: LocalFile[] = [];
  const replacements: Array<{ raw: string; absolute: string }> = [];
  const explicitContext = (value: string) => chips.some(c => c.kind === "context" && c.path?.replace(/\/$/, "") === value.replace(/\/$/, ""));
  // Project files and folders are the synced project context. Point the agent
  // at that live replica so what it writes there syncs to the sidebar; a copy
  // under .paloma/attach never came back (mission 49660417 wrote @Context).
  const projectPath = (value: string) => {
    const bare = value.replace(/\/$/, "");
    return chips.some(chip => chip.kind !== "controller" && chip.path?.replace(/\/$/, "") === bare);
  };
  for (const mention of mentions) if (projectPath(mention.value) && isSecretPath(mention.value.replace(/\/$/, ""))) throw new Error(`${mention.value} is not copied. Your draft is kept.`);
  const namespaceContext = (value: string) => value === "context" || value.startsWith("context/");
  const contextMentions = mentions.filter(m => namespaceContext(m.value) || explicitContext(m.value) || projectPath(m.value));
  const required = contextMentions.some(m => namespaceContext(m.value) || explicitContext(m.value));
  if (chips.some(c => c.project && c.project !== slug)) throw new Error("The referenced files belong to another project. Select them again.");
  let contextRoot: string | undefined;
  const contextPaths=new Map<string,string>();
  if (contextMentions.length) {
    const invoke = tauriInvoke();
    if (!invoke && required) throw new Error("Shared context requires the Orb desktop app on this computer.");
    try {
      if (invoke) {
        const result = await invoke("project_context_prepare", {request:{endpoint:getApiUrl(),token:getJwt()??"",project:slug,paths:contextMentions.map(m=>m.value)}}) as {root:string;state:{error?:string};resolved_paths:string[]};
        if(!Array.isArray(result.resolved_paths)||result.resolved_paths.length!==contextMentions.length)throw Error("Restart Orb to load the updated context resolver. Your draft is kept.");
        for (const [index, mention] of contextMentions.entries()) {
          if (explicitContext(mention.value) && result.resolved_paths[index] !== mention.value.replace(/\/$/, "")) throw Error("The referenced path no longer exists. Select it again; your draft is kept.");
        }
        contextRoot=result.root;
        contextMentions.forEach((mention,index)=>contextPaths.set(mention.value.replace(/\/$/,""),result.resolved_paths[index]));
      }
    } catch (error) {
      // Without the live replica, project files are still copied as before.
      if (required) throw error;
    }
  }
  let folderBytes = 0;
  for (const mention of mentions) {
    const bare = mention.value.replace(/\/$/, "");
    if (contextRoot && contextPaths.has(bare)) {
      replacements.push({raw:mention.raw,absolute:`${contextRoot}${contextPaths.get(bare) ? "/"+contextPaths.get(bare) : ""}`});
      continue;
    }
    const chip = chips.find((item) => {
      if (item.kind === "controller") return bare.toLowerCase() === "controller";
      return item.path?.replace(/\/$/, "") === bare;
    });
    if (!chip) continue;
    if (chip.kind === "controller") {
      let body = "# Controller\n\nNo controller snapshot was available.\n";
      try {
        const view = await getProjectController(slug, 1);
        body = `# Controller\n\n${view.job?.name || slug}\n`;
      } catch {
        /* snapshot stays the fallback line */
      }
      const rel = ".paloma/controller.md";
      files.push({ rel, content: body });
      replacements.push({ raw: mention.raw, absolute: rel });
      continue;
    }
    const path = chip.path ?? "";
    if (isSecretPath(path)) throw new Error(`${path} is not copied. Your draft is kept.`);
    if (chip.kind === "file") {
      let content = "";
      try {
        content = await readFile(path);
      } catch (e) {
        throw new Error(`${path} could not be read. Your draft is kept. ${e instanceof Error ? e.message : ""}`.trim());
      }
      if (content.length > FILE_CAP) throw new Error(`${path} is over the ${FILE_CAP} byte cap. Your draft is kept.`);
      const rel = `.paloma/attach/${path}`;
      files.push({ rel, content });
      replacements.push({ raw: mention.raw, absolute: rel });
      continue;
    }
    const pending: string[] = [path];
    while (pending.length && files.length < 200) {
      const dir = pending.pop()!;
      let entries: Array<{ name: string; kind: string }> = [];
      try {
        entries = await listDir(dir);
      } catch (e) {
        throw new Error(`${dir}/ could not be read. Your draft is kept. ${e instanceof Error ? e.message : ""}`.trim());
      }
      for (const entry of entries) {
        const relPath = `${dir}/${entry.name}`.replace(/^\//, "");
        if (isSecretPath(relPath)) continue;
        if (entry.kind === "dir") pending.push(relPath);
        else {
          if (folderBytes >= FOLDER_CAP) break;
          const content = await readFile(relPath);
          const take = content.slice(0, FOLDER_CAP - folderBytes);
          folderBytes += take.length;
          files.push({ rel: `.paloma/attach/${relPath}`, content: take });
        }
      }
    }
    replacements.push({ raw: mention.raw, absolute: `.paloma/attach/${path}` });
  }
  const prompt = rewritePrompt(text, replacements.map((row) => ({ ...row, absolute: row.absolute.startsWith("/") ? row.absolute : `__ROOT__/${row.absolute}` })));
  return {
    prompt,
    files,
    note: replacements.map((row) => row.absolute).join("\n"),
  };
}

/** Swap the placeholder root for the workspace Tauri created. */
export function bindWorkspace(prompt: string, root: string): string {
  return prompt.replaceAll("__ROOT__", root.replace(/\/$/, ""));
}

/** Validate an explicit host folder before copying attachments or claiming a run. */
export async function localDirectory(path: string): Promise<string> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Local folders require Orb desktop.");
  return await invoke("local_agents_directory", {path}) as string;
}

export async function localWorkspace(slug: string): Promise<string> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Local agents run in the Orb desktop app.");
  const path = await invoke("local_agents_workspace", { request: { slug } });
  if (typeof path !== "string" || !path) throw new Error("Could not create the local workspace.");
  return path;
}

export async function writeLocalFiles(root: string, files: LocalFile[]): Promise<void> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Local agents run in the Orb desktop app.");
  const result = await invoke("local_agents_write", { request: { root, files } }) as {skipped?: string[]; binary_supported?: boolean};
  if (files.some(file => file.encoding === "base64") && !result?.binary_supported) throw new Error("Restart Orb to enable image attachments. Your draft is kept.");
  if (result?.skipped?.length) throw new Error(`Some files could not be attached: ${result.skipped.join(", ")}`);
}

export interface StartLocal {
  cyber_access?: CyberMode;
  cyber_revision?: string;
  imagePaths?: string[];
  id: string;
  harness: string;
  bin: string;
  cwd: string;
  prompt: string;
  model?: string;
  effort?: string;
  sessionId?: string;
  sharedCwdWith?: string;
}

const nativeRecoveries = new Map<string, Promise<unknown>>();
const pendingLaunches = new Map<string, Promise<unknown>>();

export async function startLocal(req: StartLocal): Promise<ClientRunReceipt> {
  if (localRunActive(req.id)) throw new Error("This mission is still running locally. Stop it before sending another message.");
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Local agents run in the Orb desktop app.");
  launching.add(req.id);
  const version=(runVersions.get(req.id) ?? 0)+1;
  runVersions.set(req.id,version);
  recordLocalFailure(req.id, null);
  setRunning((prev) => ({ ...prev, [req.id]: true }));
  setLiveText((prev) => ({ ...prev, [req.id]: "" }));
  setActivities(prev => ({ ...prev, [req.id]: [] }));
  try {
    // Let this window's in-flight reconciliation release its native lock first.
    await nativeRecoveries.get(req.id);
    await import("./localWakeups").then(m=>m.replayLocalWakeupStops());
    if(runVersions.get(req.id)!==version)throw new Error("Local launch rejected: stopped before launch");
    if(req.harness === "codex") {
      await requireLocalCyber(invoke);
      const selection = await getCyber(req.id);
      req = {...req,cyber_access:selection.mode,cyber_revision:selection.revision};
      if(runVersions.get(req.id)!==version)throw new Error("Local launch rejected: stopped before launch");
    }
    const launch = invoke("local_run_launch", {
      connection: { api_url: getApiUrl(), token: getJwt() },
      request: { ...req, session_id: req.sessionId, image_paths: req.imagePaths ?? [], shared_cwd_with: req.sharedCwdWith },
    });
    pendingLaunches.set(req.id,launch);
    const receipt = await launch as ClientRunReceipt;
    rememberClientRunReceipt(req.id, receipt);
    return receipt;
  } catch (e) {
    // An uncertain native start keeps the lease until polling proves it stopped.
    launching.delete(req.id);
    await reconcileLocalRun(req.id);
    const msg = e instanceof Error ? e.message : String(e);
    if (!/^Local launch deferred:/.test(msg) && !/already has non-terminal run|still running locally|starting in another Orb window/i.test(msg)) {
      recordLocalFailure(req.id, e);
    }
    throw e;
  } finally {
    pendingLaunches.delete(req.id);
    launching.delete(req.id);
  }
}

export interface PollLocal {
  activities?: LocalActivity[];
  text: string;
  done: boolean;
  exit_code?: number | null;
  session_id?: string | null;
  error?: string | null;
  retryable?: boolean;
  resumed: boolean;
  /** Set while the turn has answered and only its background tasks remain (ms since the epoch). */
  waiting_since?: number | null;
}

export async function pollLocal(id: string): Promise<PollLocal> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Local agents run in the Orb desktop app.");
  return (await invoke("local_agents_poll", { id })) as PollLocal;
}

/** The native runner survives webview reloads; frontend flags do not. */
const reconciling=new Map<string,Promise<void>>();
export function reconcileLocalRun(id:string):Promise<void>{
 const pending=reconciling.get(id);
 if(pending)return pending.then(()=>reconcileRun(id));
 const work=reconcileRun(id).finally(()=>reconciling.delete(id));reconciling.set(id,work);return work;
}
async function reconcileRun(id: string): Promise<void> {
  if (launching.has(id)) return;
  const version=runVersions.get(id);
  try {
    const state = await pollLocal(id);
    if (runVersions.get(id)!==version) return;
    if (!state.done) recordLocalFailure(id, null);
    setRunning(prev => ({ ...prev, [id]: !state.done }));
    if(!state.done&&!followers.has(id))void followLocal(id,()=>{}).catch(console.error);
    setLiveText(prev => ({ ...prev, [id]: state.text }));
    setActivities(prev => ({ ...prev, [id]: state.activities ?? [] }));
    if (state.session_id) {
      const binding = localBinding(id);
      if (binding) await rememberBinding(id, { ...binding, sessionId: state.session_id });
    }
  } catch (error) {
    // A transport error does not mean the process stopped.
    if (runVersions.get(id)===version && /no local run/i.test(String(error))) {
      const wasKnownSettled = Object.hasOwn(running(), id) && running()[id] === false;
      if (localBinding(id) && !launching.has(id) && !wasKnownSettled) {
        try {
          const settled = await nativeRecovery(id);
          if (runVersions.get(id)!==version) return;
          recordLocalFailure(id, null);
          setRunning(prev => ({ ...prev, [id]: false }));
          if (settled !== false) window.dispatchEvent(new Event("orb:refresh"));
        } catch (recoveryError) {
          // A failed recovery keeps the server fence. Do not mark the local run
          // settled while another window or orphan process still holds it.
          if (runVersions.get(id)===version) {
            recordLocalFailure(id, recoveryError);
            setRunning(prev => {
              if (!Object.hasOwn(prev, id)) return prev;
              const next = { ...prev };
              delete next[id];
              return next;
            });
          }
        }
      } else {
        setRunning(prev => ({ ...prev, [id]: false }));
      }
    }
  }
}

export async function stopLocal(id: string, options: { cancelWakeups?: boolean } = {}): Promise<void> {
  runVersions.set(id,(runVersions.get(id) ?? 0)+1);
  const invoke = tauriInvoke();
  if (invoke) {
    const connection = { api_url: getApiUrl(), token: getJwt() };
    const sameConnection = () => connection.api_url === getApiUrl() && connection.token === getJwt();
    // Persist the fence before stopping: a previously fetched inbox can arrive late.
    const queue = options.cancelWakeups !== false ? await import("./localMessageQueue") : undefined;
    if (!sameConnection()) throw new Error("Connection changed. Stop the mission from its original connection.");
    const cancelToken = await queue?.cancelQueuedWakeups(id);
    const pending=pendingLaunches.get(id);
    await invoke("local_agents_stop", { id });
    // A native command already sent to IPC may enter after the first Stop.
    // Drain that invocation and stop again before acknowledging cancellation.
    if(pending){await pending.catch(()=>{});await invoke("local_agents_stop",{id});}
    // Queue advancement and machine transfer stop a process, not the mission.
    if (queue) {
      try { await invoke("local_wakeups_cancel", { mission: id, connection, cancelToken }); }
      catch (error) { if (!/unknown command|command .*not found/i.test(String(error))) throw error; }
      try {
        const synced = await invoke("local_wakeups_sync", { connection }) as { cancelled?: {mission:string;token:string}[] };
        if (sameConnection()) await queue.confirmWakeupStops(synced.cancelled ?? []);
      } catch { /* Offline Stop stays fenced until its durable cancellation syncs. */ }
    }
  }
  setRunning((prev) => ({ ...prev, [id]: false }));
}

/** One process subscription per run; all views share its output and completion. */
const followers=new Map<string,{promise:Promise<PollLocal>;listeners:Set<(text:string)=>void>}>();
export function followLocal(id:string,onText:(text:string)=>void):Promise<PollLocal>{
 const existing=followers.get(id);if(existing){existing.listeners.add(onText);onText(localLiveText(id));return existing.promise;}
 const listeners=new Set([onText]);
 const promise=new Promise<PollLocal>((resolve,reject)=>{
  const buffer=bufferedOutput<PollLocal>(text=>{setLiveText(prev=>({...prev,[id]:text}));listeners.forEach(listener=>listener(text));},resolve);
  let stop=()=>{};
  stop=followNative<OutputEvent<PollLocal>&{activities?:LocalActivity[]}>('local_agents',{id},event=>{
   if(event.activities)setActivities(prev=>({...prev,[id]:event.activities!}));
   buffer.receive(event);if(event.state)queueMicrotask(()=>{stop();window.removeEventListener('pagehide',stop);});
  },error=>{buffer.dispose();reject(error);});
  window.addEventListener('pagehide',stop,{once:true});
 }).then(async state=>{
  setActivities(prev=>({...prev,[id]:state.activities??[]}));
  if(state.session_id){const binding=localBinding(id);if(binding)await rememberBinding(id,{...binding,sessionId:state.session_id});}
  setRunning(prev=>({...prev,[id]:false}));return state;
 }).catch(error=>{recordLocalFailure(id,error);throw error;}).finally(()=>{followers.delete(id);window.dispatchEvent(new Event('orb:queue-wake'));});
 followers.set(id,{promise,listeners});return promise;
}

export async function localSessionGit(cwd: string): Promise<{ repository: string; branch?: string | null } | null> {
  const invoke = tauriInvoke();
  return invoke ? await invoke("local_session_git", { cwd }) as { repository: string; branch?: string | null } | null : null;
}

/** Initial runs have a native-generated identity and a durable synchronization journal. */
export async function startLocalOrigin(request: Omit<StartLocal,"id">, draft: {key:string;title:string;project:string;prompt:string;tags:string[]}): Promise<import("./api").Mission> {
 const invoke=tauriInvoke();if(!invoke)throw new Error("Open Orb desktop to start on this computer.");
 if(request.harness==='codex'){await requireCyberSupport();await requireLocalCyber(invoke);}
 await import("./localWakeups").then(m=>m.replayLocalWakeupStops());
 let mission:import("./api").Mission;
 try{mission=await invoke("local_origin_launch",{request:{...request,id:"",session_id:null,image_paths:request.imagePaths??[]},draft,connection:{api_url:getApiUrl(),token:getJwt()}}) as import("./api").Mission;}
 catch(error){if(/unknown command|command .*not found/i.test(String(error)))throw new Error("Update Orb desktop to enable local launches with offline support. Your draft is kept.");throw error;}
 await rememberBinding(mission.id,{harness:request.harness,bin:request.bin,cwd:mission.working_directory ?? request.cwd,model:request.model,effort:request.effort});
 await reconcileLocalRun(mission.id);
 return mission;
}

/** Explicit retry must prove the previous native launch is no longer alive. */
export async function recoverLocalLaunch(id: string, sharedCwdWith?: string): Promise<void> {
 const invoke=tauriInvoke();
 if(!invoke)throw new Error("Local agents run in the Orb desktop app.");
 await nativeRecovery(id, sharedCwdWith);
 await reconcileLocalRun(id);
}

function nativeRecovery(id: string, sharedCwdWith?: string): Promise<unknown> {
 const existing=nativeRecoveries.get(id);
 if(existing)return existing;
 const invoke=tauriInvoke();
 if(!invoke)return Promise.reject(new Error("Local agents run in the Orb desktop app."));
 const pending=invoke("local_run_reconcile",{id,sharedCwdWith,connection:{api_url:getApiUrl(),token:getJwt()}}).finally(()=>{nativeRecoveries.delete(id);});
 nativeRecoveries.set(id,pending);
 return pending;
}

/** Sync and expose all project skills before launch; failures keep the draft. */
export async function prepareProjectSkills(project: string, cwd: string, harness: string, bin?: string): Promise<void> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Project skills require the Orb desktop app. Your draft is kept.");
  await invoke("project_skills_prepare", {
    request: { endpoint: getApiUrl(), token: getJwt() ?? "", project, paths: [] }, cwd, harness, bin: bin ?? null,
  });
}

export interface PreflightStatus {
  python3_ready: boolean;
  python3_version?: string | null;
  pyyaml_ready: boolean;
  preflight_error?: string | null;
  identity_ready: boolean;
  identity_fingerprint?: string | null;
  identity_updated_at?: number | null;
}

export interface HarnessSkillTarget {
  id: string;
  name: string;
  global_rel: string;
  global_path: string;
  project_rel: string;
  exists: boolean;
  skill_count: number;
  synced_count: number;
  canonical_total: number;
  missing_skills: string[];
}

export interface SkillSourceInfo {
  id: string;
  label: string;
  path: string;
  exists: boolean;
  skill_count: number;
}

export interface DiscoveredSkill {
  name: string;
  description?: string | null;
  origin: string;
  source_path?: string | null;
  harnesses: string[];
  managed: boolean;
  content_preview?: string | null;
}

export interface LocalSkillsReport {
  checked_at: number;
  home_dir: string;
  preflight: PreflightStatus;
  sources: SkillSourceInfo[];
  harnesses: HarnessSkillTarget[];
  skills: DiscoveredSkill[];
}

export interface SyncSkillPayload {
  name: string;
  content: string;
  files?: Array<{ rel: string; content: string }>;
}

export interface SyncSkillsResult {
  synced_skills: number;
  harnesses_updated: number;
  skipped_unmanaged: string[];
  report: LocalSkillsReport;
}

export async function localSkillsStatus(): Promise<LocalSkillsReport | null> {
  const invoke = tauriInvoke();
  if (!invoke) return null;
  return (await invoke("local_skills_status")) as LocalSkillsReport;
}

export async function localSkillsSync(options: { librarySkills?: SyncSkillPayload[]; pruneRemoved?: boolean } = {}): Promise<SyncSkillsResult> {
  const invoke = tauriInvoke();
  if (!invoke) throw new Error("Unified local skill sync requires the Orb desktop app.");
  return (await invoke("local_skills_sync", {
    request: {
      library_skills: options.librarySkills ?? [],
      prune_removed: options.pruneRemoved ?? false,
    },
  })) as SyncSkillsResult;
}

async function requireLocalCyber(invoke:NonNullable<ReturnType<typeof tauriInvoke>>){
 try {if(await invoke("local_agents_cyber_capabilities")===2)return;}catch{}
 throw Error("Update Orb desktop before requesting a cyber program on this computer. Your selection was not silently omitted.");
}

