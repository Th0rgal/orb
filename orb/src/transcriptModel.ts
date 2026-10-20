import { isFailedStatus } from "./missionStatus";
import type { DraftImage } from "./imageAttachments";
import { deferredMessages } from "./deferredMessages";
import { isGeneratedRemoteJobStatus, type StreamEvent } from "./stream";

export type StreamItem =
  | { kind: "user"; key: string; text: string; images?: DraftImage[]; messageId?: string; source?: string; queued?: boolean; attached?: boolean; receipt?: boolean; /** Server time the message was stored (ISO), when known. */ at?: string }
  | { kind: "think"; key: string; text: string; done: boolean }
  | { kind: "text"; key: string; text: string; live: boolean }
  | { kind: "error"; key: string; text: string; terminal?: boolean; cancelled?: boolean }
  | {
      kind: "tool";
      key: string;
      callId: string;
      name: string;
      args: unknown;
      result?: unknown;
      done: boolean;
      unresolved?: boolean;
    };


const str = (v: unknown): string => typeof v === "string" ? v : v == null ? "" : String(v);
const states = new WeakMap<StreamItem[], TranscriptReducer>();

/** The producer owns text_delta_latest for an entire assistant response,
 * including tool boundaries. Other text_op bubbles have independent identities.
 * Offsets are Rust Unicode scalar indices, not JavaScript UTF-16 offsets. */
export class TranscriptReducer {
  items: StreamItem[] = [];
  private users = new Map<string, number>();
  private tools = new Map<string, number>();
  private bubbles = new Map<string, number>();
  private seen = new Set<string>();
  private seq = new Map<string, number>();
  private revisions = new Map<string, number>();
  private next = 0;
  /** Index of the last delivered (not queued) user message, or -1. */
  private lastUser = -1;
  /** Antigravity bubble ids, kept in transcript order as they are placed. */
  private native: string[] = [];
  private lastFinal: number | undefined;
  /** Text of the turn-wide bubble when the last turn closed. */
  private carried: string | undefined;
  /** Prefix of a closed turn that Core's live text buffer still prepends. */
  private glued = new Map<string, string>();
  private identity:string|undefined;
  private key(kind: string) { return this.identity ? `${kind}:${this.identity}:${++this.nextForEvent}` : `${kind}-${++this.next}`; }
  private nextForEvent=0;
  private put(index: number, item: StreamItem) { this.items[index] = item; }
  private placeText(bubble:string,item:Extract<StreamItem,{kind:'text'}>):number {
    let index=this.items.length;
    if(bubble.startsWith('antigravity:')) {
      const [,conversation,,step]=bubble.split(':');
      for(let i=this.lastUser+1;i<this.items.length;i++){
        const row=this.items[i];
        if(row.kind==='tool'&&row.callId.startsWith(conversation+':')&&Number(row.callId.slice(conversation.length+1))>Number(step)){index=i;break;}
      }
      item={...item,key:`text:${bubble}`};
    }
    // Appending (the common case) moves no other item.
    if(index<this.items.length){
      for(const map of [this.users,this.tools,this.bubbles])for(const [key,i] of map)if(i>=index)map.set(key,i+1);
      if(this.lastFinal!=null&&this.lastFinal>=index)this.lastFinal++;
      if(this.lastUser>=index)this.lastUser++;
    }
    this.items.splice(index,0,item);
    this.bubbles.set(bubble,index);
    if(bubble.startsWith('antigravity:')){
      // Insert by position so receipts compare bubbles in transcript order.
      let at=this.native.length;
      while(at>0&&(this.bubbles.get(this.native[at-1])??-1)>index)at--;
      this.native.splice(at,0,bubble);
    }
    return index;
  }

  /** Drop one item, keeping every index the reducer holds in step. */
  removeAt(index: number) {
    this.items.splice(index, 1);
    for (const map of [this.users, this.tools, this.bubbles]) {
      for (const [key, position] of map) {
        if (position === index) map.delete(key);
        else if (position > index) map.set(key, position - 1);
      }
    }
    if (this.lastFinal != null) this.lastFinal = this.lastFinal === index ? undefined : this.lastFinal > index ? this.lastFinal - 1 : this.lastFinal;
    if (this.lastUser > index) this.lastUser--;
    else if (this.lastUser === index) this.lastUser = this.items.reduce((last, item, i) => item.kind === "user" && !item.queued ? i : last, -1);
  }
  /** Some harnesses (Antigravity) re-emit a turn's last reasoning after its
   * final answer. Once the turn ends, thoughts trailing its last text move
   * before that text, so they fold with the turn's work instead of dangling
   * below the answer. Only thoughts follow that text, so no tool or user index moves. */
  private hoistTrailingThoughts() {
    let text = -1;
    for (let i = this.items.length - 1; i > this.lastUser; i--) {
      const kind = this.items[i].kind;
      if (kind === "text") { text = i; break; }
      if (kind !== "think") return;
    }
    if (text < 0 || text === this.items.length - 1) return;
    const thoughts = this.items.splice(text + 1);
    this.items.splice(text, 0, ...thoughts);
    for (const [key, i] of this.bubbles) if (i === text) this.bubbles.set(key, i + thoughts.length);
    if (this.lastFinal === text) this.lastFinal = text + thoughts.length;
  }
  private close() {
    const latest = this.bubbles.get("text_delta_latest");
    const turn = latest == null ? undefined : this.items[latest];
    if (turn?.kind === "text" && turn.text) this.carried = turn.text;
    this.glued.clear();
    for (const index of this.bubbles.values()) {
      const item = this.items[index];
      if (item?.kind === "text" && item.live) this.put(index, { ...item, live: false });
    }
    for (let i=0;i<this.items.length;i++) {
      const item=this.items[i];
      if(item.kind==='tool'&&!item.done)this.put(i,{...item,done:true,unresolved:true});
      if(item.kind==='think'&&!item.done)this.put(i,{...item,done:true});
    }
    this.bubbles.clear();
    this.native = [];
  }
  /** Core's durable copy of a cut turn's streamed text. It finalizes the
   * bubble that turn already shows (live or from its stored snapshot), even
   * when the Send now message that cut it is already placed below. */
  private settlePartial(text: string) {
    const want = text.trim();
    if (!want) return;
    for (let i = this.items.length - 1; i >= 0; i--) {
      const item = this.items[i];
      if (item.kind === "user") { if (item.receipt || item.queued) continue; break; }
      if (item.kind !== "text") continue;
      const have = item.text.trim();
      if (have === want || want.startsWith(have) || have.startsWith(want)) { this.put(i, { ...item, text, live: false }); return; }
    }
    // Not shown yet: it precedes the optimistic message that cut it.
    let at = this.items.length;
    while (at > 0) { const row = this.items[at - 1]; if (row.kind === "user" && (row.receipt || row.queued)) at--; else break; }
    if (at < this.items.length) {
      for (const map of [this.users, this.tools, this.bubbles]) for (const [key, i] of map) if (i >= at) map.set(key, i + 1);
      if (this.lastFinal != null && this.lastFinal >= at) this.lastFinal++;
      if (this.lastUser >= at) this.lastUser++;
    }
    this.items.splice(at, 0, { kind: "text", key: this.key("text"), text, live: false });
  }
  apply(ev: StreamEvent) {
    this.identity=ev.eventId??(ev.storedId!==undefined?`stored:${ev.storedId}`:ev.sequence!==undefined?`seq:${ev.sequence}`:undefined);this.nextForEvent=0;
    // The persisted text snapshot keeps its row/event ID as its sequence advances.
    // Each revision must replay; the same row can also serve a later user turn.
    if (ev.type === "text_delta" && ev.sequence != null) this.identity = `text-revision:${ev.sequence}`;
    const d = ev.data;
    // Status notifications are not assistant completions: do not close live text/tools.
    if (ev.type === "assistant_message" && d.success !== false && isGeneratedRemoteJobStatus({content: str(d.content), metadata: d})) return;
    // A message has one identity and a monotonic queued -> delivered lifecycle.
    // Process it before event dedupe and channel sequence checks: receipt, queue
    // snapshot, stored history and SSE may arrive in any order.
    if (ev.type === "user_message") {
      const parts = deferredMessages(str(d.content), d.source, d.messages);
      if (parts) {
        for (const part of parts) this.apply({ type: "user_message", data: { ...part, queued: d.queued === true } });
        return;
      }
      const messageId = typeof d.id === "string" ? d.id : ev.eventId;
      const queued = d.queued === true;
      const source = typeof d.source === "string" ? d.source : undefined;
      if (!messageId && ev.sequence != null) {
        const legacyIdentity = `user:${ev.sequence}:${queued}`;
        if (this.seen.has(legacyIdentity)) return;
        this.seen.add(legacyIdentity);
      }
      const index = messageId ? this.users.get(messageId) : undefined;
      const previous = index == null ? undefined : this.items[index];
      if (previous?.kind === "user" && index != null) {
        if (source && source !== previous.source) this.put(index, { ...previous, source });
        if (!previous.queued || queued) {
          if (previous.receipt && d.receipt !== true) this.put(index, { ...previous, source: source ?? previous.source, text: str(d.content) || previous.text, receipt: false });
          return;
        }
        this.close(); this.lastFinal = undefined;
        // A queued row may precede text that arrived while it was waiting.
        // Delivery places it after that response without changing its identity.
        this.items.splice(index, 1);
        for (const map of [this.users, this.tools, this.bubbles]) {
          for (const [key, position] of map) if (position > index) map.set(key, position - 1);
        }
        if (this.lastFinal != null && this.lastFinal > index) this.lastFinal--;
        this.lastUser = this.items.length;
        this.users.set(messageId!, this.items.length);
        this.items.push({ ...previous, source: source ?? previous.source, text: str(d.content) || previous.text, queued: false, receipt: d.receipt === true, at: typeof d.at === "string" ? d.at : previous.at });
        return;
      }
      if (!queued) { this.close(); this.lastFinal = undefined; }
      if (messageId) this.users.set(messageId, this.items.length);
      if (!queued) this.lastUser = this.items.length;
      this.items.push({ kind: "user", key: messageId ? `user:${messageId}` : this.key("user"), text: str(d.content), messageId, source, queued, attached: d.attached === true, receipt: d.receipt === true, ...(typeof d.at === "string" ? { at: d.at } : {}) });
      return;
    }
    const id = ev.eventId ?? (typeof d.id === "string" ? d.id : undefined);
    const identity = ev.type === "text_delta" && ev.sequence != null ? `text-revision:${ev.sequence}` : d.canonical === true && ev.sequence != null ? `canonical:${ev.sequence}` : id ? `${ev.type}:${id}` : ev.sequence != null ? `stored:${ev.sequence}:${ev.type}` : undefined;
    if (identity && this.seen.has(identity)) return;
    if (identity) this.seen.add(identity);
    const bubble = str(d.bubble_id) || "text_delta_latest";
    const channel = `${ev.type}:${bubble}`;
    if (ev.sequence != null) {
      if (ev.sequence < (this.seq.get(channel) ?? -1)) return;
      this.seq.set(channel, ev.sequence);
    }
    const last = this.items.at(-1);
    switch (ev.type) {
      case "text_delta":
      case "text_op": {
        let index = this.bubbles.get(bubble);
        // A bubble from before the latest delivered user message belongs to an
        // earlier turn. Core reuses one text id per mission, so without this the
        // next turn's text was appended to the previous turn's reply.
        if (index != null && index < this.lastUser) { this.bubbles.delete(bubble); this.revisions.delete(bubble); index = undefined; }
        const previous = index == null ? undefined : this.items[index];
        let text = previous?.kind === "text" ? previous.text : "";
        let live = previous?.kind === "text" ? previous.live : true;
        let snapshot: string | undefined;
        let replacedLength: number | undefined;
        if (ev.type === "text_delta") {
          const next = str(d.content);
          if (d.mode === "delta") {
            text += next;
            live = true;
          } else {
            snapshot = next;
            text = next;
            live = true;
          }
        } else {
          // Positions count code points. Almost every op appends, which needs
          // no per-character copy of the bubble: on a long reply that copy
          // took the reducer to half a second per batch.
          let chars: string[] | undefined;
          const length = () => { chars ??= Array.from(text); return chars.length; };
          const splice = (start: number, remove: number, insert: string) => {
            chars ??= Array.from(text);
            chars.splice(Math.max(0, start), Math.max(0, remove), insert);
            text = chars.join("");
            chars = undefined;
          };
          for (const op of (Array.isArray(d.ops) ? d.ops : []) as Record<string, unknown>[]) {
            if (op.type === "snapshot") {
              const revision = Number(op.revision);
              if (!Number.isFinite(revision) || revision <= (this.revisions.get(bubble) ?? -1)) return;
              this.revisions.set(bubble, revision);
              text = str(op.text); chars = undefined; snapshot = text;
            } else if (op.type === "insert") {
              // This synthetic bubble carries a full snapshot even on reconnect,
              // when a fresh producer buffer emits insert(0, accumulated_text).
              if (bubble === "text_delta_latest" && op.pos === 0) { snapshot = str(op.text); text = snapshot; chars = undefined; }
              // UTF-16 length bounds the code-point count, so this needs no scan.
              else if (typeof op.pos !== "number" || op.pos >= text.length || op.pos >= length()) { text += str(op.text); chars = undefined; }
              else splice(op.pos, 0, str(op.text));
            } else if (op.type === "replace") {
              const range = Array.isArray(op.range) ? op.range as number[] : [0, length()];
              if (bubble === "text_delta_latest" && range[0] === 0) { snapshot = str(op.text); text = snapshot; chars = undefined; replacedLength = range[1]; }
              else splice(range[0], range[1] - range[0], str(op.text));
            } else if (op.type === "finalize") live = false;
          }
        }
        if (ev.type === "text_op" && bubble === "text_delta_latest" && snapshot != null) {
          // A live buffer that outlived a cut turn replaces that whole turn's
          // text with `old turn + new reply`. The new turn starts its own
          // bubble; strip the closed turn's text, for every snapshot of it.
          const carried = this.carried;
          if (index == null && carried && replacedLength === Array.from(carried).length && snapshot.length > carried.length && snapshot.startsWith(carried)) this.glued.set(bubble, carried);
          const prefix = this.glued.get(bubble);
          if (prefix && snapshot.startsWith(prefix)) { snapshot = snapshot.slice(prefix.length); text = snapshot; }
        }
        if (index == null && bubble === "text_delta_latest" && this.lastFinal != null) {
          const finalized = this.items[this.lastFinal];
          if (finalized?.kind === "text" && !finalized.live && snapshot != null && finalized.text.startsWith(snapshot)) {
            // Recovery may replay an unsequenced live prefix after its durable
            // final. A delivered user turn resets lastFinal, so new replies
            // with identical text remain independent.
            return;
          }
        }
        if (index == null) {
          if (!text) return;
          index=this.placeText(bubble,{kind:"text",key:this.key("text"),text,live});
        } else if (previous?.kind === "text" && (previous.text !== text || previous.live !== live)) this.put(index,{...previous,text,live});
        return;
      }
      case "assistant_message": {
        const text=str(d.content);
        const finalBubble=str(d.bubble_id)||"text_delta_latest";
        if(d.canonical===true){
          if(typeof d.revision === 'number') {
            if(d.revision < (this.revisions.get(finalBubble) ?? -1)) return;
            this.revisions.set(finalBubble,d.revision);
          }
          // Canonical rows finalize one identified bubble; other native bubbles
          // must remain distinct. Keep it available for the turn's final event.
          const index=this.bubbles.get(finalBubble) ?? (finalBubble==="text_delta_latest" ? this.lastFinal : undefined);
          const previous=index==null ? undefined : this.items[index];
          if(previous?.kind==="text"&&index!=null){this.put(index,{...previous,text:text||previous.text,live:false});this.bubbles.set(finalBubble,index);}
          else if(text){this.placeText(finalBubble,{kind:"text",key:this.key("text"),text,live:false});}
          return;
        }
        if(d.partial===true&&d.success!==false){this.settlePartial(text);return;}
        const index=this.bubbles.get(finalBubble);
        const previous=index == null ? undefined : this.items[index];
        const native = this.native.map(id=>this.items[this.bubbles.get(id) ?? -1]).filter((i):i is Extract<StreamItem,{kind:'text'}>=>i?.kind==='text');
        const trimmed = text.trim();
        const isNativeReceipt = native.length > 0 && (trimmed === native.map(i=>i.text).join('').trim() || trimmed === native.at(-1)!.text.trim());
        this.close();
        if(d.success===false){this.items.push({kind:"error",key:this.key("error"),text:text||"Mission failed",terminal:true,cancelled:text.trim().toLowerCase()==="cancelled"});return;}
        if(!isNativeReceipt){
          if(previous?.kind === "text" && index != null){this.put(index,{...previous,text:text||previous.text,live:false});this.lastFinal=index;}
          else if(text){this.lastFinal=this.items.length;this.items.push({kind:"text",key:this.key("text"),text,live:false});}
        }
        // Settle the turn's shape only after the final text is in place.
        this.hoistTrailingThoughts();
        return;
      }
      case "thinking": {
        const text=str(d.content),done=d.done===true,want=text.trim();
        const liveLast=last?.kind==="think"&&!last.done;
        // Empty or closing reasoning carries nothing to show.
        if(!want){if(liveLast&&done)this.removeAt(this.items.length-1);return;}
        // A replay of a thought this turn already shows (Antigravity repeats
        // its last summary around tool calls and after the final answer).
        const seen=(from:number,to:number)=>{for(let i=from;i<to;i++){const row=this.items[i];if(row.kind==="think"&&row.done&&row.text.trim()===want)return true;}return false;};
        if(liveLast){
          if(done&&seen(this.lastUser+1,this.items.length-1))this.removeAt(this.items.length-1);
          else this.put(this.items.length-1,{...last,text,done});
        }
        else if(!seen(this.lastUser+1,this.items.length))this.items.push({kind:"think",key:this.key("think"),text,done});
        return;
      }
      case "tool_call":
      case "tool_result": {
        const callId=str(d.tool_call_id), index=this.tools.get(callId);
        if(index!=null){
          const old=this.items[index];
          if(old.kind==="tool"&&ev.type==="tool_result")this.put(index,{...old,result:d.result,done:true,unresolved:false});
          else if(old.kind==="tool"&&ev.type==="tool_call")this.put(index,{...old,name:str(d.name)||old.name,args:d.args??old.args});
          return;
        }
        this.tools.set(callId,this.items.length);
        this.items.push({kind:"tool",key:`tool:${callId}`,callId,name:str(d.name)||"tool",args:d.args??null,...(ev.type==="tool_result"?{result:d.result}:{}),done:ev.type==="tool_result"});return;
      }
      case "error": this.close(); this.items.push({kind:"error",key:this.key("error"),text:str(d.message)});return;
      case "mission_status_changed": {
        const status = str(d.status).toLowerCase();
        if (["completed", "failed", "not_feasible", "interrupted", "cancelled", "canceled"].includes(status)) {
          this.close();
          this.hoistTrailingThoughts();
        }
        const summary = str(d.summary ?? d.content).trim();
        if (isFailedStatus(status) && summary) {
          const lastUser = this.lastUser;
          // The harness already reported the concrete failure; the status summary
          // ("Remote node 'x' finished") would only add a second, vaguer card.
          const alreadyShown = this.items.slice(lastUser + 1).some(item => item.kind === "error" && (item.terminal || item.text.trim() === summary));
          if (!alreadyShown) {
            this.items.push({ kind: "error", key: this.key("error"), text: summary, terminal: true });
          }
        }
        return;
      }
    }
  }
}

/**
 * Punctuation that can never be an answer on its own. Deliberately narrow:
 * `---`, `***`, `|`, backticks and brackets are all meaningful Markdown and are
 * not listed, so real content is never at risk.
 */
const FILLER_ONLY = /^[.\u2026,;]+$/;

/**
 * A finalized assistant bubble holding nothing but filler punctuation, with
 * real output still to come.
 *
 * Asking OpenCode "What's the status of the Pareto audit?" produced a bare `.`
 * between two batches of tool calls, before the real answer — rendered as its
 * own paragraph, and splitting what was one stretch of work into "Worked 5
 * tools" and "Worked 1 tool". The source of the reported live-only emission was not retained in the
 * persisted events. Only finalized bubbles are candidates here; a live
 * prefix must remain free to grow into text.
 *
 * Three conditions keep this from eating anything real:
 *  - `live` bubbles are never hidden, so a `.` that is the first token of a
 *    sentence still being streamed stays and grows normally;
 *  - something must come after it, so if `.` is all the agent ever said the
 *    user sees it rather than an empty transcript;
 *  - only sentence punctuation counts, so code, rules and tables are untouched.
 *
 * Presentation only — the underlying items, and the events behind them, are
 * unchanged.
 */
export function isFillerBubble(item: StreamItem, index: number, items: StreamItem[]): boolean {
  if (item.kind !== "text" || item.live) return false;
  if (!FILLER_ONLY.test(item.text.trim())) return false;
  // An error is not an answer: it must not license hiding the only output there
  // was. Only real text that followed does.
  for (const next of items.slice(index + 1)) {
    if (next.kind === "user" || next.kind === "error") return false;
    if (next.kind === "text" && next.text.trim() && !FILLER_ONLY.test(next.text.trim())) return true;
  }
  return false;
}

/** The transcript as shown: filler bubbles dropped, everything else intact. */
export function withoutFiller(items: StreamItem[]): StreamItem[] {
  const keep = items.filter((item, index) => !isFillerBubble(item, index, items));
  return keep.length === items.length ? items : keep;
}

/** A delivered follow-up supersedes the previous attempt's terminal notice.
 * Keep the raw history intact, and do not dismiss failures for queued input. */
export function visibleTranscript(items: StreamItem[]): StreamItem[] {
  let lastDelivered = -1;
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.kind === "user" && !item.queued && !item.attached) {
      lastDelivered = i;
      break;
    }
  }
  return withoutFiller(items.filter((item, index) =>
    !(item.kind === "error" && item.terminal && index < lastDelivered),
  ));
}

export function buildTranscript(events: StreamEvent[]): StreamItem[] {
  const reducer=new TranscriptReducer();
  for(const event of events)reducer.apply(event);
  states.set(reducer.items,reducer);
  return reducer.items;
}

type UserItem = Extract<StreamItem, { kind: "user" }>;
/** Remove user rows (a cancelled, retracted or elsewhere-delivered message)
 * through the reducer. A plain `filter` produced an array without reducer
 * state, and the next live event threw ("must originate from
 * buildTranscript"): every later text of the turn was dropped until a full
 * resync — after a Send now, the new turn's reply. */
export function removeUsers(items: StreamItem[], match: (item: UserItem) => boolean): StreamItem[] {
  if (!items.some(item => item.kind === "user" && match(item))) return items;
  const reducer = states.get(items);
  if (!reducer) return items.filter(item => item.kind !== "user" || !match(item));
  reducer.items = items.slice();
  for (let i = reducer.items.length - 1; i >= 0; i--) {
    const item = reducer.items[i];
    if (item.kind === "user" && match(item)) reducer.removeAt(i);
  }
  states.set(reducer.items, reducer);
  return reducer.items;
}

/** Rewrite user rows in place (same positions), keeping reducer state. */
export function mapUsers(items: StreamItem[], update: (item: UserItem) => UserItem): StreamItem[] {
  let changed = false;
  const next = items.map(item => { if (item.kind !== "user") return item; const updated = update(item); if (updated !== item) changed = true; return updated; });
  if (!changed) return items;
  const reducer = states.get(items);
  if (reducer) { reducer.items = next; states.set(next, reducer); }
  return next;
}

export function applyStreamEvent(items: StreamItem[], event: StreamEvent): StreamItem[] {
  return applyStreamEvents(items, [event]);
}

/** One copy per transport batch; reducer ordering and deduplication are unchanged. */
export function applyStreamEvents(items: StreamItem[], events: StreamEvent[]): StreamItem[] {
  if (!events.length) return items;
  let reducer=states.get(items);
  if(!reducer){
    if(items.length)throw new Error("Transcript must originate from buildTranscript");
    reducer=new TranscriptReducer();
  }
  reducer.items=items.slice();
  for (const event of events) reducer.apply(event);
  // An event that changed nothing (activity, status, a duplicate) keeps the
  // array identity: a new one would re-run every memo and the turn list.
  if(reducer.items.length===items.length&&reducer.items.every((item,index)=>item===items[index])){reducer.items=items;states.set(items,reducer);return items;}
  states.set(reducer.items,reducer);
  return reducer.items;
}
