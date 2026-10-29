import { createSignal } from "solid-js";
import { getMissionPassageContext, type SearchHighlightRange } from "./api";
import { hydratePassageEvents, peekReadyTranscript } from "./missionCache";
import { notify } from "./toast";
import type { StreamItem } from "./transcriptModel";
import { transcriptSearch } from "./VirtualTurns";
import "./searchTarget.css";

export interface PendingSearchTarget {
  requestId: number;
  missionId: string;
  locator: string;
  role: string;
  sequence?: number | null;
  eventId?: string | null;
  query?: string;
}

const [pendingTarget, setPendingTarget] = createSignal<PendingSearchTarget | null>(null);
let nextRequestId = 0;

export const pendingSearchTarget = pendingTarget;

export function hasPendingSearchTarget(missionId: string | undefined): boolean {
  const cur = pendingTarget();
  return !!missionId && !!cur && cur.missionId === missionId;
}

export function requestSearchTarget(target: Omit<PendingSearchTarget, "requestId">): void {
  setPendingTarget({ ...target, requestId: ++nextRequestId });
}

export function clearSearchTarget(requestId?: number): void {
  setPendingTarget(cur => {
    if (!cur) return null;
    if (requestId !== undefined && cur.requestId !== requestId) return cur;
    return null;
  });
}

/** Escape plain text into highlighted segments using UTF-16 code-unit spans (`[start, end)`).
 * Never interprets HTML; callers render plain strings and `<mark>` elements. */
export function splitUtf16Highlights(
  text: string,
  ranges: SearchHighlightRange[] | undefined,
): Array<{ text: string; match: boolean }> {
  if (!text) return [];
  if (!ranges?.length) return [{ text, match: false }];
  const len = text.length;
  const sorted = [...ranges]
    .map(r => ({
      start: Math.max(0, Math.min(len, r.start)),
      end: Math.max(0, Math.min(len, r.end)),
    }))
    .filter(r => r.end > r.start)
    .sort((a, b) => a.start - b.start || a.end - b.end);

  if (!sorted.length) return [{ text, match: false }];

  const out: Array<{ text: string; match: boolean }> = [];
  let cursor = 0;
  for (const r of sorted) {
    if (r.start < cursor) {
      if (r.end <= cursor) continue;
      out.push({ text: text.slice(cursor, r.end), match: true });
      cursor = r.end;
      continue;
    }
    if (r.start > cursor) {
      out.push({ text: text.slice(cursor, r.start), match: false });
    }
    out.push({ text: text.slice(r.start, r.end), match: true });
    cursor = r.end;
  }
  if (cursor < len) {
    out.push({ text: text.slice(cursor), match: false });
  }
  return out;
}

export function resolveTargetKeys(
  items: StreamItem[],
  target: PendingSearchTarget,
): { turnKey: string; messageKey?: string } | null {
  const visible = items.filter(i => i.kind !== "user" || !i.queued);
  if (!visible.length) return null;

  // Build turn boundaries matching `Transcript.tsx` (`item.kind === "user" || !turns.length`).
  const turns: Array<{ key: string; items: StreamItem[] }> = [];
  for (const item of visible) {
    if (item.kind === "user" || !turns.length) {
      turns.push({ key: item.key, items: [] });
    }
    turns[turns.length - 1].items.push(item);
  }

  const matchItem = (item: StreamItem): boolean => {
    const loc = target.locator;
    if (loc.startsWith("cloud:")) {
      // `cloud:<turnKey>:prompt` -> `<turnKey>:prompt`
      const suffix = loc.slice("cloud:".length);
      return item.key === suffix;
    }
    if (loc.startsWith("msg:id:")) {
      const id = loc.slice("msg:id:".length);
      if (item.kind === "user") return item.messageId === id || item.key === `user:${id}`;
      if (item.kind === "text") return item.eventId === id || item.key.includes(`:${id}:`);
    }
    if (loc.startsWith("msg:bubble:")) {
      const bubble = loc.slice("msg:bubble:".length);
      return item.key === `text:${bubble}` || (item.kind === "text" && item.eventId === bubble);
    }
    if (loc.startsWith("msg:seq:")) {
      const seq = Number(loc.slice("msg:seq:".length));
      if (Number.isFinite(seq) && "sequence" in item && item.sequence === seq) return true;
    }
    if (target.eventId) {
      if (item.kind === "user" && item.messageId === target.eventId) return true;
      if (item.kind === "text" && item.eventId === target.eventId) return true;
      if (item.key === `${target.eventId}:prompt` && target.role === "user") return true;
      if (item.key === `${target.eventId}:answer` && target.role === "assistant") return true;
    }
    if (target.sequence != null && "sequence" in item && item.sequence === target.sequence) {
      return true;
    }
    return false;
  };

  if (target.locator.startsWith("turn:tools:")) {
    const anchorSeq = Number(target.locator.slice("turn:tools:".length));
    const byAnchor = turns.find(t =>
      t.items.some(i => "sequence" in i && i.sequence === anchorSeq),
    );
    if (byAnchor) return { turnKey: byAnchor.key };
  }

  for (const turn of turns) {
    for (const item of turn.items) {
      if (matchItem(item)) {
        return { turnKey: turn.key, messageKey: item.key };
      }
    }
  }

  // Fallback by sequence proximity: pick the turn whose anchor <= target.sequence.
  if (target.sequence != null) {
    let candidate: { key: string; items: StreamItem[] } | undefined;
    for (const turn of turns) {
      const seqs = turn.items
        .map(i => ("sequence" in i && typeof i.sequence === "number" ? i.sequence : undefined))
        .filter((n): n is number => n !== undefined);
      if (seqs.length && Math.min(...seqs) <= target.sequence) {
        candidate = turn;
      }
    }
    if (candidate) {
      const roleMatch = candidate.items.find(i =>
        target.role === "user" ? i.kind === "user" : i.kind === "text",
      );
      return { turnKey: candidate.key, messageKey: roleMatch?.key };
    }
  }

  return null;
}

function flashElement(el: HTMLElement): void {
  el.classList.remove("search-target-flash");
  // Force reflow if re-triggering the same message row.
  void el.offsetWidth;
  el.classList.add("search-target-flash");
  window.setTimeout(() => {
    el.classList.remove("search-target-flash");
  }, 2400);
}

/** Hydrate deep history if needed, reveal the target turn through VirtualTurns,
 * center the specific message through the existing scroll container, and reconcile
 * visibly if the passage was edited or deleted since the search. */
export async function fulfillSearchTarget(options: {
  missionId: string;
  target: PendingSearchTarget;
  getItems: () => StreamItem[];
  onHydrated?: (items: StreamItem[]) => void;
  getScroller: () => HTMLElement | undefined;
  beginJump: () => void;
  endJump: (target?: Element | null) => void;
  isCloud?: boolean;
}): Promise<void> {
  const { missionId, target, getItems, onHydrated, getScroller, beginJump, endJump, isCloud } = options;
  if (target.locator === "title") {
    clearSearchTarget(target.requestId);
    return;
  }

  beginJump();
  let landedNode: HTMLElement | null = null;
  let targetFoundOnServer = true;
  try {
    if (!isCloud) {
      const snap = peekReadyTranscript(missionId);
      const needsDeepHydration =
        !resolveTargetKeys(getItems(), target) ||
        (target.sequence != null && snap?.before !== undefined && target.sequence < snap.before);
      try {
        const ctx = await getMissionPassageContext(missionId, {
          locator: target.locator,
          sequence: target.sequence,
          event_id: target.eventId,
          query: target.query ?? null,
          before: 2,
          after: 2,
          include_events: needsDeepHydration,
        });
        targetFoundOnServer = ctx.target_found;
        if (needsDeepHydration && ctx.events?.length) {
          const hydrated = await hydratePassageEvents(missionId, ctx.events);
          onHydrated?.(hydrated.items);
        }
      } catch {
        // Offline or older backend: fall back to loaded items if available.
      }
    }

    // Wait two frames for Solid + VirtualTurns to reflect any hydrated items and initial layout.
    await new Promise<void>(resolve =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
    );

    const resolved = resolveTargetKeys(getItems(), target);

    if (!targetFoundOnServer) {
      notify({
        kind: "info",
        key: `search-reconcile:${missionId}:${target.locator}`,
        title: "Passage updated since search",
        message: "That message was edited or removed — showing the surrounding conversation.",
      });
    }

    if (!resolved) {
      if (targetFoundOnServer) {
        notify({
          kind: "info",
          key: `search-missing:${missionId}:${target.locator}`,
          title: "Message no longer at that position",
          message: "Opened the conversation, but the matched passage could not be located.",
        });
      }
      return;
    }

    const scroller = getScroller();
    if (!scroller) return;

    const searchHandle = transcriptSearch(scroller);
    const turnNode = await searchHandle?.reveal({ key: resolved.turnKey, occurrence: 0 });
    // Let VirtualTurns ResizeObserver flush measured row heights around the revealed turn.
    await new Promise<void>(resolve => requestAnimationFrame(() => resolve()));

    const findMessageNode = (): HTMLElement | null => {
      if (!resolved.messageKey) return null;
      const escaped =
        typeof CSS !== "undefined" && typeof CSS.escape === "function"
          ? CSS.escape(resolved.messageKey)
          : resolved.messageKey.replace(/"/g, '\\"');
      return (turnNode ?? scroller).querySelector<HTMLElement>(`[data-message-key="${escaped}"]`);
    };

    landedNode = findMessageNode() ?? turnNode ?? null;
    if (landedNode && landedNode !== turnNode) {
      landedNode.scrollIntoView({ block: "center" });
    }
  } finally {
    endJump(landedNode);
    if (landedNode) flashElement(landedNode);
    clearSearchTarget(target.requestId);
  }
}
