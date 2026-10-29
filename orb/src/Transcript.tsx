import { swallow } from "./log";
import { seenTurnStart, turnStartedAt } from "./TurnStatus";
import { toMs, turnAgo, turnDate, turnTiming, workedFor, type TurnTiming } from "./turnTiming";
import { useTooltip } from "./Tooltip";
import { formatElapsed, useNow } from "./time";
import {AutomaticReminder, reminderMessages} from "./AutomaticReminder";
import { ErrorToast } from "./toast";
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
import { ErrorNotice, isNonResumableError } from "./ErrorNotice";
import { forkContext } from "./forkContext";
import { backgroundWake, type BackgroundWake } from "./backgroundWake";
import { For, Show, batch, createSignal, createEffect, createMemo, createContext, useContext, onCleanup } from "solid-js";
import * as Ic from "./icons";
import { markdownText, MdView } from "./Markdown";
import { createStore, reconcile } from "solid-js/store";
import { goalDraft, planObjective } from "./goal";
import { isTaskTool, latestTaskList, parseTaskList, sameChecklist, sameTaskCardView, taskCardView, turnOutcomeAfter, type TurnOutcome } from "./taskList";

import { messagePresentation, isAutomaticRecovery, isResumePrompt } from "./messagePresentation";
import { computeDiffStats, narrationKeys, narrationLine, toolArgs, toolName, workKind, workSummary, type DiffStats, type TaskItem } from "./workModel";
import { visibleTranscript, type StreamItem } from "./transcriptModel";
import { collectFollowUps, isOrchestrationTool, isSubagentTool } from "./orchestrationModel";
import { FollowUpsContext, OrchestrationCard } from "./OrchestrationCard";
export { buildTranscript, applyStreamEvent } from "./transcriptModel";
export type { StreamItem } from "./transcriptModel";

const DisclosureState=createContext<Map<string,boolean>>();
type ToolCallLoader=(callId:string)=>Promise<{args?:unknown;result?:unknown}>;
/** Loads the whole call of a tool row Core shortened (`truncated`). */
const ToolCallLoaderContext=createContext<ToolCallLoader>();
function disclosure(key:string,initial=false){
 const state=useContext(DisclosureState);
 const [open,setOpen]=createSignal(state?.get(key)??initial);
 const [explicit,setExplicit]=createSignal(state?.has(key)??false);
 return [open,(value:boolean)=>{state?.set(key,value);setExplicit(true);setOpen(value);},explicit] as const;
}

const dismissedChecklists = new Set<string>();

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
export function toolTarget(name: string, args: unknown): string {
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
    case "run_command":
    case "bash":
    case "shell":
    case "terminal":
      t = pick("command", "cmd", "CommandLine", "preview");
      break;
    case "read_file":
    case "write_file":
    case "edit_file":
    case "view_file":
    case "view_file_outline":
    case "view_code_item":
    case "replace_file_content":
    case "multi_replace_file_content":
    case "write_to_file":
    case "read":
    case "write":
    case "edit":
      t = pick("file_path", "filePath", "path", "file", "TargetFile", "AbsolutePath", "preview");
      break;
    case "grep":
    case "glob":
    case "list":
    case "list_dir":
    case "find_by_name":
    case "grep_search":
    case "search_files":
      t = pick("pattern", "query", "Pattern", "Query", "path", "SearchPath", "DirectoryPath", "preview");
      break;
    case "task":
    case "agent":
    case "delegate_task":
    case "subagent":
    case "spawn_subagent":
      t = pick("description", "prompt", "preview");
      break;
    case "taskcreate":
      t = pick("subject", "description");
      break;
    case "taskupdate":
      t = [pick("taskId") && `#${pick("taskId").replace(/^#/, "")}`, pick("status").replaceAll("_", " ")].filter(Boolean).join(" ");
      break;
    case "webfetch":
    case "web_fetch":
    case "read_url_content":
      t = pick("url", "Url", "preview");
      break;
    case "websearch":
    case "web_search":
    case "search_web":
      t = pick("query", "Query", "preview");
      break;
    case "skill":
      t = pick("name", "preview");
      break;
    default:
      t = pick("file_path", "filePath", "path", "TargetFile", "AbsolutePath", "command", "CommandLine", "query", "url", "pattern", "prompt", "description", "name", "preview");
  }
  if (t.length > 90) t = `${t.slice(0, 90)}…`;
  return t;
}

function toolArgsBadges(name: string, args: unknown): string[] {
  const a = toolArgs(args);
  if (!a) return [];
  const badges: string[] = [];
  const n = toolName(name);
  if (n === "read" || n === "read_file" || n === "view_file") {
    if (typeof a.offset === "number") badges.push(`offset=${a.offset}`);
    if (typeof a.limit === "number") badges.push(`limit=${a.limit}`);
    if (typeof a.StartLine === "number" && typeof a.EndLine === "number") badges.push(`L${a.StartLine}-${a.EndLine}`);
  } else if (n === "grep" || n === "grep_search") {
    if (typeof a.include === "string" && a.include.trim()) badges.push(`include=${a.include.trim()}`);
  } else if (n === "task" || n === "agent" || n === "subagent" || n === "spawn_subagent") {
    const sub = typeof a.subagent_type === "string" ? a.subagent_type : typeof a.agent === "string" ? a.agent : "";
    if (sub.trim()) badges.push(sub.trim());
  }
  return badges;
}

function ToolGlyph(p: { name: string }) {
  const kind = () => {
    const n = toolName(p.name);
    if (isSubagentTool(p.name)) return "agent";
    if (isTaskTool(p.name)) return "plan";
    if (n === "webfetch" || n === "web_fetch" || n === "websearch" || n === "web_search" || n === "search_web" || n === "read_url_content") return "web";
    return workKind(p.name);
  };
  return (
    <span class="st-tool-glyph" data-kind={kind()} aria-hidden="true">
      {kind() === "read" ? <Ic.FileIcon size={13} />
        : kind() === "search" ? <Ic.SearchIcon size={13} />
        : kind() === "command" ? <Ic.CmdIcon size={13} />
        : kind() === "edit" ? <Ic.PencilIcon size={13} />
        : kind() === "agent" ? <Ic.BranchIcon size={13} />
        : kind() === "plan" ? <Ic.PlanIcon size={13} />
        : kind() === "web" ? <Ic.ExternalIcon size={13} />
        : <Ic.GearIcon size={13} />}
    </span>
  );
}

export function DiffBadges(p: { stats: DiffStats }) {
  return (
    <span class="st-diff-badges" aria-label={`+${p.stats.additions} -${p.stats.deletions}`}>
      <Show when={p.stats.additions > 0 || p.stats.deletions === 0}>
        <span class="st-diff-add">+{p.stats.additions}</span>
      </Show>
      <Show when={p.stats.deletions > 0}>
        <span class="st-diff-del">-{p.stats.deletions}</span>
      </Show>
    </span>
  );
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
    }).catch(swallow("transcript.loadImage")).finally(() => {if(!cancelled)setLoading(false);});
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

export function UserTurn(p: { text: string; images?: DraftImage[]; source?: string; attached?: boolean; pending?: boolean; /** Handed to the agent; its turn has not started yet. */ sending?: boolean; onSend?: (text: string) => boolean | Promise<boolean> }) {
  const fork = createMemo(() => forkContext(p.text));
  // An edited message's request is the bubble; its history collapses above it.
  const editable = createMemo(() => !fork() || fork()!.request !== undefined);
  const presentation = createMemo(() => messagePresentation(fork()?.request ?? (fork() ? "" : p.text)));
  const images = createMemo(() => messageImages(presentation().text));
  // A fork's history quotes old uploads; those markers are not this turn's images.
  const thumbnails = createMemo(() => !editable() ? [] : images().paths.length
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
    if (!editable() || sending()) return;
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
    <Show when={isAutomaticRecovery(p.text) || isResumePrompt(p.text)} fallback={
    <div ref={bubble} onDblClick={() => { if (!editing()) edit(); }} class={`user ${editing() ? "editing" : ""} ${goal().kind === "goal" ? "goal" : ""} ${plan() !== null ? "plan" : ""} ${p.pending ? "pending" : ""} ${p.sending ? "sending" : ""}`} aria-busy={p.sending ? true : undefined}>
      <Show when={thumbnails().length}><div class="message-images"><For each={thumbnails()}>{(image,i)=><MessageImage path={image.path} index={image.reference} onUrl={url=>setImageUrls(prev=>({...prev,[image.path]:url}))} onOpen={()=>setViewing(i())}/>}</For></div></Show>
      <Show when={viewing()!==null}><Lightbox items={thumbnails().map(image=>({src:imageUrls()[image.path]??null,label:`Image #${image.reference}`}))} index={viewing()!} onClose={()=>setViewing(null)}/></Show>
      <Show when={p.source && AUTOMATIC_SOURCES.has(p.source)}><small class="user-origin" title="This message was generated by the agent coordinator">↻ Automatic follow-up</small></Show>
      <Show when={editing()} fallback={<>
      <Show when={plan() !== null}><small class="user-plan"><Ic.PlanIcon size={12}/>Plan</small></Show>
      <Show when={fork()}>
        {context => <details class="fork-context"><summary>{context().request !== undefined ? "Earlier conversation" : `Transferred from ${context().source_title || "conversation"}`} · {context().messages.length} messages</summary>
          <For each={context().messages}>{m => <div class="fork-context-message"><small>{m.role === "user" ? "You" : m.role === "assistant" ? "Assistant" : "Context"}</small><p>{m.content}</p></div>}</For>
        </details>}
      </Show>
      <Show when={editable()}><span>{goal().kind === "goal" ? (goal() as { objective: string }).objective : plan() ?? images().text}</span></Show>
      <Show when={p.attached || presentation().attached}><small class="user-context">Attached context</small></Show>
      <Show when={editable() && p.onSend}><button class="icon-btn prompt-edit" aria-label="Edit prompt" onClick={edit}><Ic.PencilIcon size={14} /></button></Show>
      </>}>
        <PromptEditor value={draft()} disabled={sending()} input={setDraft} cancel={()=>{if(!sending())setEditing(false);}} submit={()=>void submit()}/>

        <div class="prompt-editor-actions">
          <button class="icon-btn" aria-label="Cancel" title="Cancel (Esc)" disabled={sending()} onClick={() => setEditing(false)}><Ic.CloseIcon size={13} /></button>
          <button class="icon-btn" aria-label="Copy prompt" title="Copy prompt" onClick={() => { void copyText(draft()).then(() => setCopyState("Copied"), e => setCopyState(String(e))); }}><Ic.CopyIcon size={13} /></button>
          <span role="status">{copyState()}</span>
          <Show when={p.onSend}><button class="send" aria-label={sending() ? "Sending follow-up" : "Send again"} title="Replaces this message and what came after it (⌘/Ctrl+Enter)" disabled={sending() || !draft().trim()} onClick={() => void submit()}><Ic.ArrowUpIcon size={14}/></button></Show>
        </div>
        <ErrorToast error={sendError()} title="Couldn’t send your message" onDismiss={() => setSendError("")} />
      </Show>
    </div>
    }><details class="background-wake">
      <summary><Ic.CmdIcon size={12}/><span>{isResumePrompt(p.text) ? "Resumed after interruption" : "Agent resumed automatically"}</span></summary>
      <div class="background-wake-body"><p>{p.text}</p></div>
    </details></Show>
  );
}

function ToolRow(props: { item: Extract<StreamItem, { kind: "tool" }> }) {
  const [open, setOpen] = disclosure(`tool:${props.item.key}`,false);
  // A shortened row shows its excerpt at once and its whole call when loaded.
  const loadToolCall = useContext(ToolCallLoaderContext);
  const [full, setFull] = createSignal<{args?:unknown;result?:unknown}>();
  const [fullError, setFullError] = createSignal("");
  createEffect(() => {
    if (!open() || !props.item.truncated || !props.item.done || full() || !loadToolCall) return;
    setFullError("");
    loadToolCall(props.item.callId).then(setFull, () => setFullError("The full output couldn’t load. Showing an excerpt."));
  });
  const p = { get item() { const f = full(); return f ? { ...props.item, args: f.args ?? props.item.args, result: f.result ?? props.item.result } : props.item; } };
  const [copied, setCopied] = createSignal(false);
  const anchored=anchoredDisclosure();
  let toggle!:HTMLButtonElement;
  const target = () => toolTarget(p.item.name, p.item.args);
  const badges = createMemo(() => toolArgsBadges(p.item.name, p.item.args));
  const diff = createMemo(() => computeDiffStats(p.item));
  const checklist = createMemo(() => parseTaskList(p.item.name, p.item.args));
  const failed=()=>{const r=toolArgs(p.item.result);return !!r&&(!!r.error||r.status==="failed"||r.is_error===true);};
  const isCommand = () => workKind(p.item.name) === "command";
  const commandText = () => {
    const a = toolArgs(p.item.args);
    if (!a) return "";
    for (const k of ["command", "cmd", "CommandLine"]) {
      if (typeof a[k] === "string" && a[k].trim()) return a[k].trim();
    }
    return "";
  };
  const outputOnly = () => {
    const r = p.item.result;
    if (r == null) return "";
    if (typeof r === "string") return r;
    const obj = toolArgs(r);
    if (obj) {
      for (const k of ["output", "stdout", "result", "error", "message"]) {
        if (typeof obj[k] === "string" && obj[k].trim()) return obj[k];
      }
    }
    return resultText(r);
  };
  const detail = () => {
    const parts: string[] = [];
    if (p.item.args != null) parts.push(typeof p.item.args === "string" ? p.item.args : JSON.stringify(p.item.args, null, 2));
    const r = resultText(p.item.result);
    if (r) parts.push(r);
    if(p.item.unresolved)parts.push("This turn ended without a recorded result for this action.");
    return parts.join("\n\n");
  };
  const copyDetail = () => {
    const text = isCommand() && commandText() ? `$ ${commandText()}${outputOnly() ? "\n\n" + outputOnly() : ""}` : detail();
    if (!text) return;
    void copyText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    }).catch(swallow("transcript.copy"));
  };
  return (
    <div class={`st-tool ${open() ? "open" : ""} ${failed() ? "is-failed" : ""}`} data-kind={workKind(p.item.name)}>
      <Show when={open()}>
        <Show when={checklist()?.length} fallback={
          <div class="st-tool-detail-wrap">
            <button type="button" class="icon-btn st-tool-copy" aria-label={copied() ? "Copied" : "Copy tool output"} title={copied() ? "Copied" : "Copy"} onClick={(e) => { e.stopPropagation(); copyDetail(); }}>
              <Show when={copied()} fallback={<Ic.CopyIcon size={12} />}><Ic.CheckIcon size={12} /></Show>
            </button>
            <Show when={fullError()}><div class="st-tool-note" role="status">{fullError()}</div></Show>
            <Show when={isCommand() && commandText()} fallback={<pre class="st-tool-detail">{detail() || "(no details)"}</pre>}>
              <pre class="st-tool-detail st-tool-bash"><span class="st-bash-cmd">$ {commandText()}</span><Show when={outputOnly()}>{"\n\n"}{outputOnly()}</Show><Show when={p.item.unresolved}>{"\n\n"}This turn ended without a recorded result for this action.</Show></pre>
            </Show>
          </div>
        }>
          <div class="st-tool-detail st-tool-checklist">
            <ol><For each={checklist()!}>{task => <li data-status={task.status}><span class="task-state">{task.status === "completed" ? "✓" : task.status === "cancelled" ? "−" : task.status === "in_progress" ? "◉" : "○"}</span><span>{task.text}</span></li>}</For></ol>
          </div>
        </Show>
      </Show>
      <button class="st-tool-head" ref={toggle} aria-expanded={open()} onClick={() => anchored(toggle,()=>setOpen(!open()))}>
        <Ic.ChevronRight size={12} class={`chev ${open() ? "open" : ""}`} />
        <ToolGlyph name={p.item.name} />
        <span class="st-tool-name">{p.item.name}</span>
        <Show when={target()}>
          <span class="st-tool-target">{target()}</span>
        </Show>
        <Show when={badges().length}>
          <span class="st-tool-badges"><For each={badges()}>{b => <span class="st-tool-badge">{b}</span>}</For></span>
        </Show>
        <Show when={checklist()?.length}>
          <span class="st-tool-badge">{checklist()!.filter(t => t.status === "completed").length}/{checklist()!.length}</span>
        </Show>
        <Show when={diff()}>
          {d => <DiffBadges stats={d()} />}
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

/** Open state that sticks for the item's lifetime: the initial value is
 * recorded once, so finalizing a live item (done flips) or remounting it into a
 * fold never re-derives the default and the row does not jump. */
function stickyDisclosure(key: string, initial: () => boolean) {
  const state = useContext(DisclosureState);
  if (state && !state.has(key)) state.set(key, initial());
  const [open, setOpen] = createSignal(state?.get(key) ?? initial());
  return [open, (value: boolean) => { state?.set(key, value); setOpen(value); }] as const;
}

export function ThinkBlock(p: { item: Extract<StreamItem, { kind: "think" }> }) {
  // A thought that is still streaming when it mounts opens so its text is
  // visible, and stays open once it finalizes; finished thoughts load collapsed.
  const [open, setOpen] = stickyDisclosure(`think:${p.item.key}`, () => !p.item.done);
  // An in-progress block with no text only repeats the live status next to the composer.
  return (
    <Show when={p.item.done || p.item.text.trim()}>
    <div class={`st-think ${open() ? "open" : ""}`}>
      <button class="st-think-head" aria-expanded={open()} onClick={() => setOpen(!open())}>
        <Show when={p.item.done} fallback={<span class="shimmer">Thinking</span>}>
          <span>Thinking</span>
        </Show>
        <Ic.ChevronRight size={12} class={`chev ${open() ? "open" : ""}`} />
      </button>
      <Show when={open() && p.item.text}>
        <div class="st-think-body">{thinkInline(p.item.text)}</div>
      </Show>
    </div>
    </Show>
  );
}

/** Everything an agent does between two pieces of visible text (thoughts
 * and tool calls, interleaved) folds into one "Worked" line, Cursor-style:
 * the header shows the current tool while running; the body stays closed
 * until the user opens it, so a 150-tool run does not dump the full list. */
type WorkItem = Extract<StreamItem, { kind: "tool" | "think" | "text" }>;
type Grouped = StreamItem | { kind: "work"; key: string; items: WorkItem[] };

function groupWork(input: StreamItem[], previous: Grouped[] = []): Grouped[] {
  const cached = new Map(previous.filter(x => x.kind === "work").map(x => [x.key, x]));
  const out: Grouped[] = [];
  // Dropping a filler bubble also rejoins the work around it, so one stretch of
  // tool calls reads as one fold instead of being split in two by a stray ".".
  const items = visibleTranscript(input);
  const narration = narrationKeys(items, isOrchestrationTool);
  for (const it of items) {
    const last = out[out.length - 1];
    // Starting a subagent or a machine is what the run is about, not plumbing:
    // it stands on its own instead of hiding among "N other tools".
    if (it.kind === "tool" && isOrchestrationTool(it.name)) {
      out.push(it);
    } else if (it.kind === "tool" || it.kind === "think" || (it.kind === "text" && narration.has(it.key))) {
      if (last && last.kind === "work") last.items.push(it);
      // Hydration can turn a preview's text into narration inside a work fold.
      // Distinct keys prevent reconciliation from mutating a mounted text row
      // into a different variant (and briefly handing Markdown undefined text).
      else out.push({ kind: "work", key: `work:${it.key}`, items: [it] });
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
  const running = createMemo(() => p.items.some((t) => t.kind !== "text" && !t.done));
  /** While the fold runs, the newest narration reads as one clamped line under
   * its header instead of full paragraphs in the transcript. */
  const note = createMemo(() => {
    if (!running()) return "";
    for (let i = p.items.length - 1; i >= 0; i--) { const t = p.items[i]; if (t.kind === "text") return narrationLine(t.text); }
    return "";
  });
  const [open, setOpen] = disclosure(`work:${p.items[0]?.key}`,false);
  const anchored=anchoredDisclosure();
  let toggle!:HTMLButtonElement;
  const current = () => {
    const cur = [...p.items].reverse().find((t): t is Exclude<WorkItem, { kind: "text" }> => t.kind !== "text" && !t.done);
    if (!cur) return "Working…";
    if (cur.kind === "think") return "Thinking";
    return `${cur.name} ${toolTarget(cur.name, cur.args) ?? ""}`.trim();
  };
  const summary = createMemo(() => workSummary(p.items));
  const totalDiff = createMemo<DiffStats | null>(() => {
    let additions = 0, deletions = 0, has = false;
    for (const t of p.items) {
      if (t.kind !== "tool") continue;
      const d = computeDiffStats(t);
      if (d) { has = true; additions += d.additions; deletions += d.deletions; }
    }
    return has ? { additions, deletions } : null;
  });
  return (
    <div class={`st-work ${open() ? "open" : ""}`}>
      <Show when={open()}>
        <div class="st-work-body">
          <For each={p.items}>
            {(t) => (t.kind === "tool" ? <ToolRow item={t} /> : t.kind === "text" ? (
              <div class="st-work-note"><MdView text={t.text} compact /></div>
            ) : (
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
        <Show when={!running() && totalDiff()}>
          {d => <DiffBadges stats={d()} />}
        </Show>
      </button>
      <Show when={!open() && note()}><div class="st-work-live-note" title={note()}>{note()}</div></Show>

    </div>
  );
}

type ThinkItem = Extract<StreamItem, { kind: "think" }>;

/** Consecutive thoughts between two visible texts/tools: one fold whose header
 * sits above its rows and opens downward. The live thought joins the group;
 * the fold starts open when it mounts with a live thought so streaming text is
 * visible, and keeps that state when the thought finalizes. */
function ThinkFold(p: { items: ThinkItem[] }) {
  const [open, setOpen] = stickyDisclosure(`think-fold:${p.items[0]?.key}`, () => p.items.some(t => !t.done));
  const live = () => p.items.some(t => !t.done);
  const label = () => `${p.items.length} ${p.items.length === 1 ? "thought" : "thoughts"}`;
  return (
    <div class={`st-think-fold ${open() ? "open" : ""}`}>
      <button class="st-think-fold-head" aria-expanded={open()} onClick={() => setOpen(!open())}>
        <span class={live() ? "shimmer" : undefined}>{label()}</span>
        <Ic.ChevronRight size={12} class={`chev ${open() ? "open" : ""}`} />
      </button>
      <Show when={open()}>
        <div class="st-think-fold-body">
          <For each={p.items}>{(t) => <ThinkBlock item={t} />}</For>
        </div>
      </Show>
    </div>
  );
}

export function ThoughtSequence(p: { items: ThinkItem[] }) {
  // Hide the empty live placeholder the same way ThinkBlock does, so it does
  // not bump the count; every remaining thought, live or not, shares one fold.
  const shown = () => p.items.filter(t => t.done || t.text.trim());
  return (
    <Show when={shown().length > 1} fallback={<For each={shown()}>{(t) => <ThinkBlock item={t} />}</For>}>
      <ThinkFold items={shown()} />
    </Show>
  );
}

function MissionTasksCard(p: { key: string; tasks: TaskItem[]; ended?: boolean; outcome?: TurnOutcome }) {
  const [collapsed, setCollapsed] = createSignal(false);
  const [dismissed, setDismissed] = createSignal(dismissedChecklists.has(p.key));
  createEffect(() => {
    setDismissed(dismissedChecklists.has(p.key));
  });
  const view = createMemo(() => taskCardView(p.tasks, p.ended === true, p.outcome), undefined, { equals: sameTaskCardView });
  const completedCount = () => p.tasks.filter(task => task.status === "completed").length;
  const allDone = () => p.tasks.length > 0 && p.tasks.every(task => task.status === "completed" || task.status === "cancelled");
  const activeTask = () =>
    p.tasks.find(t => t.status === "in_progress") ??
    p.tasks.find(t => t.status === "pending") ??
    p.tasks.filter(t => t.status === "completed").at(-1) ??
    p.tasks[0];
  const dismiss = () => {
    dismissedChecklists.add(p.key);
    setDismissed(true);
  };
  return (
    <Show when={!dismissed()}>
      <section class={`mission-tasks ${collapsed() ? "collapsed" : ""} ${allDone() ? "is-done" : ""} ${view().state === "stopped" ? "is-ended" : ""} ${view().state === "stale" ? "is-stale" : ""}`} data-state={view().state} id="mission-tasks" aria-label="Tasks" tabIndex={-1}>
        <div class="tasks-heading">
          <button type="button" class="tasks-heading-toggle" aria-expanded={!collapsed()} onClick={() => setCollapsed(v => !v)}>
            <Ic.ChevronDown size={13} class={`tasks-chev ${collapsed() ? "collapsed" : ""}`} />
            <strong>Tasks</strong>
            <span class="tasks-count">{view().label}</span>
            <Show when={collapsed() && activeTask()}>
              <span class="tasks-preview">{activeTask()!.text}</span>
            </Show>
          </button>
          <Show when={allDone()}>
            <button
              type="button"
              class="icon-btn tasks-dismiss"
              aria-label="Dismiss completed tasks"
              title="Dismiss completed tasks"
              onClick={dismiss}
            >
              <Ic.CheckIcon size={13} />
            </button>
          </Show>
        </div>
        <Show when={!collapsed()}>
          <progress aria-label="Task progress" max={p.tasks.length} value={completedCount()} />
          <ol><For each={view().tasks}>{task => <li data-status={task.status}>
            <span class={`task-state ${task.status === "in_progress" ? "shimmer" : ""}`} aria-label={task.status === "stale" ? "status not reported" : task.status.replaceAll("_", " ")} title={task.status === "stale" ? "The agent did not report a final status for this item" : undefined}>{task.status === "completed" ? "✓" : task.status === "cancelled" ? "−" : task.status === "in_progress" ? "◉" : task.status === "stale" ? "?" : "○"}</span><span class="task-text">{task.text}</span>
          </li>}</For></ol>
        </Show>
      </section>
    </Show>
  );
}

export function Transcript(p: { sizeKey?: string; backend?: string | null; prepareSearch?:(signal:AbortSignal)=>Promise<void>; renderText?: (item: {key: string; text: string; live?: boolean}, fallback: JSX.Element) => JSX.Element; items: StreamItem[]; pending?: boolean; /** Message id still being handed to the agent (Send now). */ sending?: string; working?: boolean; workingLabel?: string; /** `messageId`: the stored message being edited, which the new text replaces. */ onSend?: (text: string, messageId?: string) => boolean | Promise<boolean>; onResume?: () => void; onOpenSource?: () => void; loadToolCall?: ToolCallLoader }) {
  // Reconcile by stable keys: existing WorkFold/ToolRow instances and parsed
  // historical Markdown survive token updates and history resynchronization.
  const disclosures=new Map<string,boolean>();
  const reminders = createMemo(() => reminderMessages(p.items));
  const checklist = createMemo(() => latestTaskList(p.items), null, { equals: sameChecklist });
  const followUps = createMemo(() => collectFollowUps(p.items));
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
  // A delta changes the last turn only: reconcile the turns that changed, not
  // the whole transcript store. A removed or reordered turn reconciles all.
  let shownTurns:Array<{key:string;items:Grouped[]}>=[];
  createEffect(()=>{
    const next=turns(),prev=shownTurns;shownTurns=next;
    if(next.length<prev.length||prev.some((row,i)=>row!==next[i]&&row.key!==next[i].key)){setTurns(reconcile(next,{key:'key'}));return;}
    batch(()=>{for(let i=0;i<next.length;i++)if(next[i]!==prev[i])setTurns(i,reconcile(next[i],{key:'key'}));});
  });
  const searchText=(turn:{items:Grouped[]})=>turn.items.map(item=>item.kind==='work'?item.items.map(t=>t.kind==='think'?t.text:t.kind==='text'?markdownText(t.text):`${t.name} ${resultText(t.args)} ${resultText(t.result)}`).join('\n'):item.kind==='tool'?`${item.name} ${resultText(item.result)}`:item.kind==='text'?markdownText(item.text):item.text).join('\n');
  // Rough height of a turn before it is first measured, from its text: rows
  // paged in above the reader start close to their real size, so the scroll
  // correction when they are measured is small instead of hundreds of px.
  const wrapped=(text:string,width:number)=>text.split('\n').reduce((n,line)=>n+Math.max(1,Math.ceil(line.length/width)),0);
  const estimateTurn=(turn:{items:Grouped[]})=>turn.items.reduce((h,item)=>h+(item.kind==='user'?54+21*wrapped(item.text,92):item.kind==='text'?12+23*wrapped(item.text,100):item.kind==='error'?64:34),0);
  const turnTip = useTooltip<TurnTiming>(TURN_TIP_ID, t => <><div class="row-tip-title">{turnDate(t.completedAt)}</div><Show when={t.workedMs !== undefined}><div class="row-tip-meta">Worked for {workedFor(t.workedMs!)}</div></Show></>, { placement: "top-end", width: 200, class: "turn-tip" });
  return (
    <TurnTipContext.Provider value={turnTip}><FollowUpsContext.Provider value={followUps}>
      <ToolCallLoaderContext.Provider value={p.loadToolCall}><DisclosureState.Provider value={disclosures}><VirtualTurns items={turnStore} estimate={estimateTurn} text={searchText} prepare={p.prepareSearch} sizeKey={p.sizeKey}>{turn=><For each={turn.items}>
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
              return <Show when={backgroundWake(item.text, item.source)} fallback={<Show when={reminders().get(item.key)} fallback={<UserTurn text={item.text} images={item.images} source={item.source} attached={item.attached} onSend={p.onSend ? text => p.onSend!(text, item.messageId) : undefined} pending={p.pending && item.key === lastUserKey()} sending={!!p.sending && item.messageId === p.sending} />}>{reminder => <AutomaticReminder text={item.text} reminder={reminder()} />}</Show>}>
                {wake => <BackgroundWakeRow wake={wake()} />}
              </Show>;
            case "think":
              return <ThoughtSequence items={[item]} />;
            case "text": {
              const timing = createMemo(() => item.live ? undefined : answerTiming(item.at, turn.items), undefined, { equals: (a, b) => a?.completedAt === b?.completedAt && a?.workedMs === b?.workedMs });
              return (
                <div class={`st-text ${item.live ? "live" : ""}`}>
                  {p.renderText ? p.renderText(item, <AssistantText text={item.text} live={item.live} timing={timing()} />) : <AssistantText text={item.text} live={item.live} timing={timing()} />}
                </div>
              );
            }
            case "tool":
              return isOrchestrationTool(item.name) ? <OrchestrationCard item={item} /> : <ToolRow item={item} />;
            case "error":
              return <ErrorNotice backend={p.backend} error={item.text} title={item.title ?? (item.cancelled ? "Mission cancelled" : "Mission failed")}>
                <Show when={!item.cancelled && p.onResume && item.key === lastErrorKey() && !isNonResumableError(item.text, p.backend)}><button type="button" class="error-notice-link" title="Continue from where the work stopped" onClick={() => p.onResume?.()}>Resume</button></Show>
                <Show when={p.onOpenSource && item.key === lastErrorKey()}><button type="button" class="error-notice-link" onClick={() => p.onOpenSource?.()}>Open original conversation</button></Show>
              </ErrorNotice>;
          }
        }}
      </For>}</VirtualTurns></DisclosureState.Provider></ToolCallLoaderContext.Provider>
      <Show when={p.working && !liveTail(p.items)}><WorkingRow items={p.items} label={p.workingLabel} /></Show>
      <Show when={checklist()?.tasks.length}>
        <MissionTasksCard key={checklist()!.key} tasks={checklist()!.tasks} ended={p.working === false} outcome={turnOutcomeAfter(p.items, checklist()!.key)} />
      </Show>
      {turnTip.surface}
    </FollowUpsContext.Provider></TurnTipContext.Provider>
  );
}

const TURN_TIP_ID = "turn-time-tip";
type TurnTip = { bind: (value: TurnTiming) => Record<string, (event: never) => void> };
/** One tooltip for every response row, so rows add no window listeners. */
const TurnTipContext = createContext<TurnTip>();
function TurnTime(p: { timing: TurnTiming }) {
  const now = useNow(60_000);
  const tip = useContext(TurnTipContext);
  const label = createMemo(() => turnAgo(p.timing.completedAt, now()));
  return <span class="response-time" tabindex="0" {...(tip?.bind(p.timing) ?? {})}><time datetime={new Date(p.timing.completedAt).toISOString()} aria-label={`Completed ${turnDate(p.timing.completedAt)}`}>{label()}</time></span>;
}
/** Latest known time in a turn, for an answer that carries none itself (a
 * harness receipt that stamped another bubble, narration-folded text, a
 * history seed): its assistant rows, folded narration, then the turn's own
 * start, so every finished answer still shows when it happened. */
const turnEnd = (items: Grouped[]): string | undefined => {
  let best: string | undefined, bestMs = -Infinity;
  const see = (at: string | undefined) => { const ms = toMs(at); if (ms !== undefined && ms > bestMs) { bestMs = ms; best = at; } };
  for (const item of items) {
    if (item.kind === "text") see(item.at);
    else if (item.kind === "work") for (const t of item.items) if (t.kind === "text") see(t.at);
  }
  return best;
};
/** The answer's own time, else the turn's latest; duration only from a known
 * start. With neither, the turn's start dates it (no "worked for"). */
function answerTiming(at: string | undefined, items: Grouped[]): TurnTiming | undefined {
  const start = userStart(items[0]);
  return turnTiming(start, at ?? turnEnd(items)) ?? turnTiming(undefined, start);
}
const userStart = (item: Grouped | undefined) => item?.kind === "user" ? item.at ?? seenTurnStart(item.messageId ?? item.key) : undefined;

function AssistantText(p: { text: string; live?: boolean; timing?: TurnTiming }) {
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
        <Show when={!p.live && p.timing}>{timing => <TurnTime timing={timing()} />}</Show>
        <span class="sr-only" role="status">{copied() ? "Response copied" : ""}</span>
        <Show when={copyError()}><span class="response-copy-error" role="status">{copyError()}</span></Show>
      </div>
    </Show>
  </>;
}

/** True when the newest item is itself an active row (thinking or a running
 * tool): that row already says what the agent is doing. Text never counts,
 * even while marked live: a harness (OpenCode) can leave its last bubble open
 * while the turn moved on to a silent command, and the turn must still read
 * as working. */
export function liveTail(items: StreamItem[]): boolean {
  const last = items[items.length - 1];
  if (!last) return false;
  if (last.kind === "think" || last.kind === "tool") return !last.done;
  return false;
}

/** The only "working" indicator: a transcript row shaped like "Thinking", shown
 * when no live row is visible, with the elapsed turn time. */
function WorkingRow(p: { items: StreamItem[]; label?: string }) {
  const now = useNow(1000);
  const seen = Date.now();
  const started = createMemo(() => turnStartedAt(p.items) ?? seen);
  // The label is the announced status; the ticking time is not read out.
  return <Show when={!["tool", "think"].includes(p.items.at(-1)?.kind ?? "")}><div class="st-think st-working">
    <div class="st-think-head"><span class="shimmer agent-wait-status" role="status" aria-live="polite">{p.label || "Working"}</span><span class="st-working-time" aria-hidden="true">{formatElapsed(now() - started())}</span></div>
  </div></Show>;
}
