import {AutomaticReminder, reminderMessages} from "./AutomaticReminder";
import {PromptEditor} from "./PromptEditor";
import {VirtualTurns} from "./VirtualTurns";
import type { JSX } from "solid-js";
import {anchoredDisclosure} from "./anchoredDisclosure";
import { messageImages } from "./messageImages";
import { imagePrompt, type DraftImage } from "./imageAttachments";
import { Lightbox } from "./Lightbox";
import { FileReferenceContext } from "./fileReferenceContext";
import { copyText } from "./clipboard";
import { remoteLog } from "./remoteLog";
import { ErrorNotice } from "./ErrorNotice";
import { forkContext } from "./forkContext";
import { backgroundWake, type BackgroundWake } from "./backgroundWake";
import { For, Show, createSignal, createEffect, createMemo, createContext, useContext, onCleanup } from "solid-js";
import * as Ic from "./icons";
import { markdownText, MdView } from "./Markdown";
import { createStore, reconcile } from "solid-js/store";
import { goalDraft, planObjective } from "./goal";

import { messagePresentation } from "./messagePresentation";
import { latestChecklist, toolArgs, toolName, workSummary } from "./workModel";
import { visibleTranscript, type StreamItem } from "./transcriptModel";
export { buildTranscript, applyStreamEvent } from "./transcriptModel";
export type { StreamItem } from "./transcriptModel";

const DisclosureState=createContext<Map<string,boolean>>();
function disclosure(key:string,initial=false){
 const state=useContext(DisclosureState);
 const [open,setOpen]=createSignal(state?.get(key)??initial);
 const [explicit,setExplicit]=createSignal(state?.has(key)??false);
 return [open,(value:boolean)=>{state?.set(key,value);setExplicit(true);setOpen(value);},explicit] as const;
}

/** Inline code and bold spans inside thought summaries, so raw backticks don't clutter the transcript. */
function thinkInline(text: string): JSX.Element[] {
  const out: JSX.Element[] = [];
  const re = /`([^`\n]+)`|\*\*([^*\n]+)\*\*/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out.push(text.slice(last, m.index));
    if (m[1] !== undefined) out.push(<code>{m[1]}</code>);
    else if (m[2] !== undefined) out.push(<strong>{m[2]}</strong>);
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** Short, human-readable target for a tool call row (Cursor-style). */
function toolTarget(name: string, args: unknown): string {
  const a = toolArgs(args);
  if (!a) return "";
  const pick = (...keys: string[]): string => {
    for (const k of keys) {
      const v = a[k];
      if (typeof v === "string" && v.trim()) return v.trim();
    }
    return "";
  };
  let t = "";
  switch (toolName(name)) {
    case "exec_command":
    case "run_terminal_command":
    case "shell_command":
    case "bash":
    case "terminal":
      t = pick("command", "cmd", "preview");
      break;
    case "read_file":
    case "write_file":
    case "edit_file":
    case "read":
    case "write":
    case "edit":
      t = pick("file_path", "filePath", "path", "file", "preview");
      break;
    case "grep":
    case "glob":
    case "search_files":
      t = pick("pattern", "query", "preview");
      break;
    case "task":
    case "delegate_task":
      t = pick("description", "prompt", "preview");
      break;
    case "webfetch":
    case "web_fetch":
      t = pick("url", "preview");
      break;
    default:
      t = pick("file_path", "path", "command", "query", "url", "pattern", "prompt", "description", "preview");
  }
  if (t.length > 90) t = `${t.slice(0, 90)}…`;
  return t;
}

function resultText(result: unknown): string {
  if (result == null) return "";
  if (typeof result === "string") return result;
  try {
    return JSON.stringify(result, null, 2);
  } catch {
    return String(result);
  }
}

/** A user turn. A `/goal <objective>` message is shown as a Goal turn with the
 * exact objective, not the raw slash command; the text itself is untouched. */
/**
 * `pending` marks the prompt whose answer is still coming. It is the only
 * signal that a healthy mission is working: a slow shimmer along the turn, no
 * text and no extra height, replacing the banner that used to sit above the
 * transcript announcing what the footer already says.
 */
function MessageImage(p: {path:string; index:number; onUrl:(url:string|null)=>void; onOpen:()=>void}) {
  const resolver=useContext(FileReferenceContext);
  const [url,setUrl]=createSignal<string | null>(null);
  const [attempt,setAttempt]=createSignal(0);
  const [loading,setLoading]=createSignal(false);
  createEffect(() => {
    const path=p.path;
    attempt();
    if (/^data:image\/(?:png|jpeg|webp|gif);base64,/i.test(path)) { setUrl(path); setLoading(false); return; }
    let cancelled=false;
    let loaded:string | null=null;
    setUrl(null); setLoading(true);
    void Promise.resolve(resolver?.loadImage?.(path)).then(value => {
      if(cancelled) { if(value?.startsWith("blob:"))URL.revokeObjectURL(value); return; }
      loaded=value ?? null;setUrl(value ?? null);
    }).catch(() => {}).finally(() => {if(!cancelled)setLoading(false);});
    onCleanup(() => {cancelled=true;if(loaded?.startsWith("blob:"))URL.revokeObjectURL(loaded);});
  });
  createEffect(() => p.onUrl(url()));
  return <>
    <button class="message-image" aria-label={`Image #${p.index}`} title={url()?`Open image #${p.index}`:loading()?"Loading image…":"Preview unavailable — click to retry"} disabled={loading()} onDblClick={e=>e.stopPropagation()} onClick={e=>{e.stopPropagation();if(url())p.onOpen();else setAttempt(n=>n+1);}}>
      <Show when={url()} fallback={<Ic.FileIcon size={22}/>}>{src=><img src={src()} alt={`Image #${p.index}`} onError={()=>setUrl(null)}/>}</Show>
      <span>{loading()?"Loading…":url()?`#${p.index}`:"Retry"}</span>
    </button>
  </>;
}

const AUTOMATIC_SOURCES = new Set(["background-task", "scheduler", "idle-worker-watchdog", "transport_auto_resume", "remote-build-terminal", "task-board"]);

/** The coordinator resumed the agent after a background shell ended. It is
 * not something the user wrote, so it is not shown as their message. */
function BackgroundWakeRow(p: { wake: BackgroundWake }) {
  const status = () => p.wake.killed ? "was stopped" : "finished";
  return (
    <details class="background-wake">
      <summary title="Sent automatically by the agent coordinator to resume the agent">
        <Ic.CmdIcon size={12} />
        <span>Background task {status()} · agent resumed</span>
        <code>{p.wake.command.split("\n")[0]}</code>
      </summary>
      <div class="background-wake-body">
        <pre>{p.wake.command}</pre>
        <Show when={p.wake.output && !p.wake.killed} fallback={<p>{p.wake.killed ? "The shell was killed before it finished, so there is no output." : "No output was captured."}</p>}>
          <pre>{p.wake.output}</pre>
        </Show>
        <Show when={p.wake.note}><p>{p.wake.note}</p></Show>
      </div>
    </details>
  );
}

export function UserTurn(p: { text: string; images?: DraftImage[]; source?: string; attached?: boolean; pending?: boolean; onSend?: (text: string) => boolean | Promise<boolean> }) {
  const fork = createMemo(() => forkContext(p.text));
  const presentation = createMemo(() => messagePresentation(p.text));
  const images = createMemo(() => messageImages(presentation().text));
  const thumbnails = createMemo(() => images().paths.length
    ? images().paths.map((path,index)=>({path,reference:images().references[index]}))
    : (p.images ?? []).map((image,index)=>({path:image.dataUrl,reference:image.reference ?? index+1})));
  const goal = createMemo(() => goalDraft(images().text));
  const plan = createMemo(() => planObjective(images().text));
  const [imageUrls, setImageUrls] = createSignal<Record<string, string | null>>({});
  const [viewing, setViewing] = createSignal<number | null>(null);
  let bubble!: HTMLDivElement;
  const [editing, setEditing] = createSignal(false);
  const anchorEdit = anchoredDisclosure();
  const [draft, setDraft] = createSignal("");
  const [copyState, setCopyState] = createSignal("");
  const [sending, setSending] = createSignal(false);
  const [sendError, setSendError] = createSignal("");
  const submit = async () => {
    if (sending() || !draft().trim() || !p.onSend) return;
    setSending(true); setSendError(""); setEditing(false);
    try {
      const accepted = await p.onSend(imagePrompt(draft(), images().paths, images().references.map(reference=>({reference}))));
      if (accepted) setEditing(false);
      else { setEditing(true); setSendError("The message was not sent. Your draft is kept; try again."); }
    } catch (e) { setEditing(true); setSendError(e instanceof Error ? e.message : String(e)); }
    finally { setSending(false); }
  };
  const edit = () => {
    if (fork() || sending()) return;
    const bounds = bubble.getBoundingClientRect();
    bubble.style.setProperty("--editing-width", `${bounds.width}px`);
    bubble.style.setProperty("--editing-height", `${bounds.height}px`);
    const text = bubble.querySelector<HTMLSpanElement>(":scope > span");
    if (text) bubble.style.setProperty("--editing-text-height", `${text.getBoundingClientRect().height}px`);
    anchorEdit(bubble, () => {
      setDraft(images().text); setCopyState(""); setSendError(""); setEditing(true);
    });
  };
  return (
    <div ref={bubble} onDblClick={() => { if (!editing()) edit(); }} class={`user ${editing() ? "editing" : ""} ${goal().kind === "goal" ? "goal" : ""} ${plan() !== null ? "plan" : ""} ${p.pending ? "pending" : ""}`}>
      <Show when={thumbnails().length}><div class="message-images"><For each={thumbnails()}>{(image,i)=><MessageImage path={image.path} index={image.reference} onUrl={url=>setImageUrls(prev=>({...prev,[image.path]:url}))} onOpen={()=>setViewing(i())}/>}</For></div></Show>
      <Show when={viewing()!==null}><Lightbox items={thumbnails().map(image=>({src:imageUrls()[image.path]??null,label:`Image #${image.reference}`}))} index={viewing()!} onClose={()=>setViewing(null)}/></Show>
      <Show when={p.source && AUTOMATIC_SOURCES.has(p.source)}><small class="user-origin" title="This message was generated by the agent coordinator">↻ Automatic follow-up</small></Show>
      <Show when={editing()} fallback={<>
      <Show when={plan() !== null}><small class="user-plan"><Ic.PlanIcon size={12}/>Plan</small></Show>
      <Show when={fork()} fallback={<span>{goal().kind === "goal" ? (goal() as { objective: string }).objective : plan() ?? images().text}</span>}>
        {context => <details class="fork-context"><summary>Forked from {context().source_title || "conversation"} · {context().messages.length} messages</summary>
          <For each={context().messages}>{m => <div class="fork-context-message"><small>{m.role === "user" ? "You" : "Assistant"}</small><p>{m.content}</p></div>}</For>
        </details>}
      </Show>
      <Show when={p.attached || presentation().attached}><small class="user-context">Attached context</small></Show>
      <Show when={!fork() && p.onSend}><button class="icon-btn prompt-edit" aria-label="Edit prompt" onClick={edit}><Ic.PencilIcon size={14} /></button></Show>
      </>}>
        <PromptEditor value={draft()} disabled={sending()} input={setDraft} cancel={()=>{if(!sending())setEditing(false);}} submit={()=>void submit()}/>

        <div class="prompt-editor-actions">
          <button class="icon-btn" aria-label="Cancel" title="Cancel (Esc)" disabled={sending()} onClick={() => setEditing(false)}><Ic.CloseIcon size={13} /></button>
          <button class="icon-btn" aria-label="Copy prompt" title="Copy prompt" onClick={() => { void copyText(draft()).then(() => setCopyState("Copied"), e => setCopyState(String(e))); }}><Ic.CopyIcon size={13} /></button>
          <span role="status">{copyState()}</span>
          <Show when={p.onSend}><button class="send" aria-label={sending() ? "Sending follow-up" : "Send again"} title="Adds a new message at the end of this conversation (⌘/Ctrl+Enter)" disabled={sending() || !draft().trim()} onClick={() => void submit()}><Ic.ArrowUpIcon size={14}/></button></Show>
        </div>
        <Show when={sendError()}><ErrorNotice error={sendError()} /></Show>
      </Show>
    </div>
  );
}

function ToolRow(p: { item: Extract<StreamItem, { kind: "tool" }> }) {
  const [open, setOpen] = disclosure(`tool:${p.item.key}`,false);
  const anchored=anchoredDisclosure();
  let toggle!:HTMLButtonElement;
  const target = () => toolTarget(p.item.name, p.item.args);
  const failed=()=>{const r=toolArgs(p.item.result);return !!r&&(!!r.error||r.status==="failed"||r.is_error===true);};
  const detail = () => {
    const parts: string[] = [];
    if (p.item.args != null) parts.push(typeof p.item.args === "string" ? p.item.args : JSON.stringify(p.item.args, null, 2));
    const r = resultText(p.item.result);
    if (r) parts.push(r);
    if(p.item.unresolved)parts.push("This turn ended without a recorded result for this action.");
    return parts.join("\n\n");
  };
  return (
    <div class={`st-tool ${open() ? "open" : ""}`}>
      <Show when={open()}>
        <pre class="st-tool-detail">{detail() || "(no details)"}</pre>
      </Show>
      <button class="st-tool-head" ref={toggle} aria-expanded={open()} onClick={() => anchored(toggle,()=>setOpen(!open()))}>
        <Ic.ChevronRight size={12} class={`chev ${open() ? "open" : ""}`} />
        <span class="st-tool-name">{p.item.name}</span>
        <Show when={target()}>
          <span class="st-tool-target">{target()}</span>
        </Show>
        <span class="st-tool-state">
          <Show when={p.item.done} fallback={<Ic.Spinner size={12} />}>
            <span class="st-tool-check" classList={{"is-failed":failed()}} title={p.item.unresolved?"No result recorded":failed()?"Failed":undefined}>{p.item.unresolved?"—":failed()?"!":"✓"}</span>
          </Show>
        </span>
      </button>

    </div>
  );
}

export function ThinkBlock(p: { item: Extract<StreamItem, { kind: "think" }> }) {
  const [open, setOpen, isExplicit] = disclosure(`think:${p.item.key}`, !p.item.done);
  const shown = () => isExplicit() ? open() : !p.item.done;
  return (
    <div class={`st-think ${shown() ? "open" : ""}`}>
      <button class="st-think-head" aria-expanded={shown()} onClick={() => setOpen(!shown())}>
        <Show when={p.item.done} fallback={<span class="shimmer">Thinking</span>}>
          <span>Thinking</span>
        </Show>
        <Ic.ChevronRight size={12} class={`chev ${shown() ? "open" : ""}`} />
      </button>
      <Show when={shown() && p.item.text}>
        <div class="st-think-body">{thinkInline(p.item.text)}</div>
      </Show>
    </div>
  );
}

/** Everything an agent does between two pieces of visible text (thoughts
 * and tool calls, interleaved) folds into one "Worked" line, Cursor-style:
 * the header shows the current tool while running; the body stays closed
 * until the user opens it, so a 150-tool run does not dump the full list. */
type WorkItem = Extract<StreamItem, { kind: "tool" | "think" }>;
type Grouped = StreamItem | { kind: "work"; key: string; items: WorkItem[] };

function groupWork(input: StreamItem[], previous: Grouped[] = []): Grouped[] {
  const cached = new Map(previous.filter(x => x.kind === "work").map(x => [x.key, x]));
  const out: Grouped[] = [];
  // Dropping a filler bubble also rejoins the work around it, so one stretch of
  // tool calls reads as one fold instead of being split in two by a stray ".".
  const items = visibleTranscript(input);
  for (const it of items) {
    const last = out[out.length - 1];
    if (it.kind === "tool" || it.kind === "think") {
      if (last && last.kind === "work") last.items.push(it);
      else out.push({ kind: "work", key: it.key, items: [it] });
    } else {
      out.push(it);
    }
  }
  return out.map(item => {
    if (item.kind !== "work") return item;
    const old = cached.get(item.key);
    return old?.kind === "work" && old.items.length === item.items.length && old.items.every((entry, i) => entry === item.items[i]) ? old : item;
  });
}

function WorkFold(p: { items: WorkItem[] }) {
  const running = createMemo(() => p.items.some((t) => (t.kind === "tool" ? !t.done : !t.done)));
  const [open, setOpen] = disclosure(`work:${p.items[0]?.key}`,false);
  const anchored=anchoredDisclosure();
  let toggle!:HTMLButtonElement;
  const current = () => {
    const cur = [...p.items].reverse().find((t) => (t.kind === "tool" ? !t.done : !t.done));
    if (!cur) return "Working…";
    if (cur.kind === "think") return "Thinking";
    return `${cur.name} ${toolTarget(cur.name, cur.args) ?? ""}`.trim();
  };
  const summary = createMemo(() => workSummary(p.items));
  return (
    <div class={`st-work ${open() ? "open" : ""}`}>
      <Show when={open()}>
        <div class="st-work-body">
          <For each={p.items}>
            {(t) => (t.kind === "tool" ? <ToolRow item={t} /> : (
              <Show when={t.text}><div class="st-think-body">{thinkInline(t.text)}</div></Show>
            ))}
          </For>
        </div>
      </Show>
      <button class="st-work-head" ref={toggle} aria-expanded={open()} onClick={() => anchored(toggle,()=>setOpen(!open()))}>
        <Ic.ChevronRight size={12} class={`chev ${open() ? "open" : ""}`} />
        <Show when={running()} fallback={<span class="st-work-label">{summary()}</span>}>
          <span class="st-work-label shimmer">{current()}</span>
        </Show>
      </button>

    </div>
  );
}

function ThinkFold(p: { items: Array<Extract<StreamItem, { kind: "think" }>> }) {
  const [open, setOpen] = disclosure(`think-fold:${p.items[0]?.key}`, false);
  const anchored = anchoredDisclosure();
  let toggle!: HTMLButtonElement;
  const label = () => `${p.items.length} ${p.items.length === 1 ? "thought" : "thoughts"}`;
  return (
    <div class={`st-work st-think-fold ${open() ? "open" : ""}`}>
      <Show when={open()}>
        <div class="st-work-body">
          <For each={p.items}>{(t) => <ThinkBlock item={t} />}</For>
        </div>
      </Show>
      <button class="st-work-head" ref={toggle} aria-expanded={open()} onClick={() => anchored(toggle, () => setOpen(!open()))}>
        <Ic.ChevronRight size={12} class={`chev ${open() ? "open" : ""}`} />
        <span class="st-work-label">{label()}</span>
      </button>
    </div>
  );
}

export function ThoughtSequence(p: { items: Array<Extract<StreamItem, { kind: "think" }>> }) {
  const folded = () => (p.items.length > 1 ? p.items.slice(0, -1) : []);
  const latest = () => p.items[p.items.length - 1];
  return (
    <>
      <Show when={folded().length}>
        <ThinkFold items={folded()} />
      </Show>
      <Show when={latest()}>{(t) => <ThinkBlock item={t()} />}</Show>
    </>
  );
}

export function Transcript(p: { prepareSearch?:(signal:AbortSignal)=>Promise<void>; renderText?: (item: {key: string; text: string; live?: boolean}, fallback: JSX.Element) => JSX.Element; items: StreamItem[]; pending?: boolean; onSend?: (text: string) => boolean | Promise<boolean>; onResume?: () => void }) {
  // Reconcile by stable keys: existing WorkFold/ToolRow instances and parsed
  // historical Markdown survive token updates and history resynchronization.
  const disclosures=new Map<string,boolean>();
  const reminders = createMemo(() => reminderMessages(p.items));
  const checklist = createMemo(() => latestChecklist(p.items));
  const groups = createMemo<Grouped[]>((previous) => groupWork(p.items.filter(item => item.kind !== "user" || !item.queued), previous), []);
  /** Key of the last user turn, when nothing follows it yet. Compared by key
   * rather than identity: `reconcile` hands the loop store proxies, not the
   * original objects. */
  const lastUserKey = createMemo(() => {
    const last = p.items[p.items.length - 1];
    return last?.kind === "user" ? last.key : null;
  });
  const lastErrorKey = createMemo(() => {
    for (let i = groups().length - 1; i >= 0; i--) {
      if (groups()[i].kind === "error") return groups()[i].key;
    }
    return null;
  });
  const turns=createMemo<Array<{key:string;items:Grouped[]}>>((previous)=>{
    const cached=new Map(previous?.map(row=>[row.key,row]));
    const rows:Array<{key:string;items:Grouped[]}>=[];
    for(const item of groups()){if(item.kind==='user'||!rows.length)rows.push({key:item.key,items:[]});rows[rows.length-1].items.push(item);}
    return rows.map(row=>{const old=cached.get(row.key);return old&&old.items.length===row.items.length&&old.items.every((item,index)=>item===row.items[index])?old:row;});
  },[]);
  const [turnStore,setTurns]=createStore<Array<{key:string;items:Grouped[]}>>([]);
  createEffect(()=>setTurns(reconcile(turns(),{key:'key'})));
  const searchText=(turn:{items:Grouped[]})=>turn.items.map(item=>item.kind==='work'?item.items.map(t=>t.kind==='think'?t.text:`${t.name} ${resultText(t.args)} ${resultText(t.result)}`).join('\n'):item.kind==='tool'?`${item.name} ${resultText(item.result)}`:item.kind==='text'?markdownText(item.text):item.text).join('\n');
  return (
    <>
      <DisclosureState.Provider value={disclosures}><VirtualTurns items={turnStore} text={searchText} prepare={p.prepareSearch}>{turn=><For each={turn.items}>
        {(item) => {
          switch (item.kind) {
            case "work":
              if (!item.items.some((t) => t.kind === "tool")) {
                return (
                  <ThoughtSequence
                    items={item.items.filter((t): t is Extract<StreamItem, { kind: "think" }> => t.kind === "think")}
                  />
                );
              }
              return <WorkFold items={item.items} />;
            case "user":
              // Only the turn still waiting for a reply animates: once anything
              // has been said or done after it, the work is visible on its own.
              return <Show when={backgroundWake(item.text, item.source)} fallback={<Show when={reminders().get(item.key)} fallback={<UserTurn text={item.text} images={item.images} source={item.source} attached={item.attached} onSend={p.onSend} pending={p.pending && item.key === lastUserKey()} />}>{reminder => <AutomaticReminder text={item.text} reminder={reminder()} />}</Show>}>
                {wake => <BackgroundWakeRow wake={wake()} />}
              </Show>;
            case "think":
              return <ThinkBlock item={item} />;
            case "text":
              return (
                <div class={`st-text ${item.live ? "live" : ""}`}>
                  {p.renderText ? p.renderText(item, <AssistantText text={item.text} live={item.live} />) : <AssistantText text={item.text} live={item.live} />}
                </div>
              );
            case "tool":
              return <ToolRow item={item} />;
            case "error":
              return <ErrorNotice error={item.text} title={item.cancelled ? "Mission cancelled" : "Mission failed"}>
                <Show when={!item.cancelled && p.onResume && item.key === lastErrorKey()}><button type="button" class="error-notice-link" title="Continue from where the work stopped" onClick={() => p.onResume?.()}>Resume</button></Show>
              </ErrorNotice>;
          }
        }}
      </For>}</VirtualTurns></DisclosureState.Provider>
      <Show when={checklist()?.tasks.length}>
        <section class="mission-tasks" id="mission-tasks" aria-label="Tasks" tabIndex={-1}>
          <div class="tasks-heading"><strong>Tasks</strong><span>{checklist()!.tasks.filter(task => task.status === "completed").length}/{checklist()!.tasks.length} completed</span></div>
          <progress aria-label="Task progress" max={checklist()!.tasks.length} value={checklist()!.tasks.filter(task => task.status === "completed").length} />
          <ol><For each={checklist()!.tasks}>{task => <li data-status={task.status}>
            <span class={`task-state ${task.status === "in_progress" ? "shimmer" : ""}`} aria-label={task.status.replaceAll("_", " ")}>{task.status === "completed" ? "✓" : task.status === "cancelled" ? "−" : task.status === "in_progress" ? "◉" : "○"}</span><span>{task.text}</span>
          </li>}</For></ol>
        </section>
      </Show>
    </>
  );
}

function AssistantText(p: { text: string; live?: boolean }) {
  const references = useContext(FileReferenceContext);
  const content = createMemo(() => remoteLog(p.text));
  const [copied, setCopied] = createSignal(false);
  const [copyError, setCopyError] = createSignal("");
  let timer: ReturnType<typeof setTimeout> | undefined;
  createEffect(() => { p.text; setCopied(false); setCopyError(""); clearTimeout(timer); });
  onCleanup(() => clearTimeout(timer));
  const copy = async () => {
    const text = content().text;
    try {
      await copyText(text);
      if (text !== content().text) return;
      setCopied(true); setCopyError(""); clearTimeout(timer);
      timer = setTimeout(() => setCopied(false), 2000);
    } catch (error) {
      if (text === content().text) setCopyError(error instanceof Error ? error.message : String(error));
    }
  };
  return <>
    <Show when={!p.live} fallback={<FileReferenceContext.Provider value={undefined}><MdView text={content().text} compact /></FileReferenceContext.Provider>}>
      <FileReferenceContext.Provider value={references}><MdView text={content().text} compact /></FileReferenceContext.Provider>
    </Show>
    <Show when={content().details}><details class="legacy-log"><summary>Original execution log</summary><pre>{content().details}</pre></details></Show>
    <Show when={content().text.trim()}>
      <div class="response-actions">
        <button class="icon-btn response-copy" aria-label={copied() ? "Response copied" : "Copy response"} title={copied() ? "Copied" : "Copy response"} onClick={() => void copy()}>
          <Show when={copied()} fallback={<Ic.CopyIcon size={14} />}><Ic.CheckIcon size={14} /></Show>
        </button>
        <span class="sr-only" role="status">{copied() ? "Response copied" : ""}</span>
        <Show when={copyError()}><span class="response-copy-error" role="status">{copyError()}</span></Show>
      </div>
    </Show>
  </>;
}
