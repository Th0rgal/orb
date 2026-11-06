import * as drafts from "./composerDrafts";
import { getApiUrl, getJwt } from './api';
import { doesTurnAnswerPending, type SideAttachment, type SideExchange } from './sideQuestionClient';

export type SavedSideQuestion = {
  history: SideExchange[];
  draft: string;
  model: string;
  open: boolean;
  docked: boolean;
  /** `turnId` is the turn's client message id, reused by Retry; `notSent` means
   * Core never accepted the question. */
  pending?: { question: string; answer: string; error?: string; attachments?:SideAttachment[]; turnId?: string; startedAt?: string; notSent?: boolean };
  /** Questions typed while the side agent was answering, oldest first. */
  queue?: QueuedSideQuestion[];
};
/** Turns kept per /btw tab. Core is the record; this only bounds the cache. */
export const BTW_HISTORY_LIMIT = 200;
export type QueuedSideQuestion = { id: string; question: string; attachments?: SideAttachment[] };
export function sideQuestionKey(mission: string): string {
  let account = 'local';
  try {
    const token = getJwt();
    if (token) {
      const payload = JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      account = String(payload.sub ?? payload.user_id ?? 'authenticated');
    }
  } catch { account = 'authenticated'; }
  return `orb.btw:v1:${JSON.stringify([getApiUrl().replace(/\/+$/, ''), account, mission])}`;
}
// Last known open/closed state and full saved payload per thread, so a mission switch
// can hydrate the /btw dock in the same frame as the transcript instead of flashing
// empty or waiting on an async IndexedDB read.
const openHints = new Map<string, boolean>();
const forcedOpen = new Set<string>();
const savedCache = new Map<string, SavedSideQuestion>();
export function peekSideQuestionOpen(key: string): boolean | undefined {
  return forcedOpen.has(key) ? true : openHints.get(key);
}
export function peekSavedSideQuestion(key: string): SavedSideQuestion | undefined {
  return savedCache.get(key);
}
export function resetSideQuestionStorageForTest(): void {
  openHints.clear();
  forcedOpen.clear();
  savedCache.clear();
}
export function hintSideQuestionOpen(key: string): void {
  forcedOpen.add(key);
  openHints.set(key, true);
}
export function consumeSideQuestionOpenHint(key: string): boolean {
  const forced = forcedOpen.delete(key);
  if (forced) openHints.set(key, true);
  return forced;
}
const keyLocks = new Map<string, Promise<unknown>>();
function withSideQuestionLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const prev = keyLocks.get(key) ?? Promise.resolve();
  const run = prev.then(fn, fn);
  const settled = run.then(() => undefined, () => undefined);
  keyLocks.set(key, settled);
  void settled.then(() => {
    if (keyLocks.get(key) === settled) keyLocks.delete(key);
  });
  return run;
}
function readLegacySideQuestion(key: string): SavedSideQuestion | undefined {
  try {
    return JSON.parse(localStorage.getItem(key) ?? 'null') ?? undefined;
  } catch {
    return undefined;
  }
}
function normalizeSavedSideQuestion(value: SavedSideQuestion | undefined): SavedSideQuestion | undefined {
  if (!value || !Array.isArray(value.history)) return undefined;
  return {
    history: value.history.filter((v: SideExchange) => typeof v?.question === 'string' && typeof v?.answer === 'string').slice(-BTW_HISTORY_LIMIT),
    draft: typeof value.draft === 'string' ? value.draft.slice(0, 2000) : '',
    model: typeof value.model === 'string' ? value.model : '',
    open: value.open === true,
    docked: value.docked === true,
    pending: typeof value.pending?.question === 'string' && typeof value.pending?.answer === 'string' ? value.pending : undefined,
    queue: Array.isArray(value.queue) ? value.queue.filter((v: QueuedSideQuestion) => typeof v?.id === 'string' && typeof v?.question === 'string').slice(0, 20) : [],
  };
}
function cacheSavedSideQuestion(key: string, normalized: SavedSideQuestion): void {
  savedCache.delete(key);
  savedCache.set(key, normalized);
  while (savedCache.size > 64) {
    const oldest = savedCache.keys().next().value;
    if (oldest === undefined) break;
    savedCache.delete(oldest);
  }
  openHints.set(key, Boolean(normalized.open));
}
export async function readSideQuestion(key: string): Promise<SavedSideQuestion | undefined> {
  return withSideQuestionLock(key, async () => {
    try {
      const raw = await drafts.readSideThread<SavedSideQuestion>(key).catch(() => undefined) ?? readLegacySideQuestion(key);
      const normalized = normalizeSavedSideQuestion(raw);
      if (!normalized) {
        savedCache.delete(key);
        return undefined;
      }
      cacheSavedSideQuestion(key, normalized);
      return normalized;
    } catch { return undefined; }
  });
}
export async function writeSideQuestion(key: string, value: SavedSideQuestion): Promise<boolean> {
  const normalized = normalizeSavedSideQuestion(value);
  if (normalized) cacheSavedSideQuestion(key, normalized);
  else openHints.set(key, Boolean(value.open));
  return withSideQuestionLock(key, async () => {
    try {
      await drafts.saveSideThread(key, value);
      localStorage.removeItem(key);
      return true;
    } catch { return false; }
  });
}
export async function reconcileSavedSideQuestion(
  key: string,
  serverHistory: readonly SideExchange[],
  options?: {
    canCommit?: () => boolean;
    isIgnoredAnswer?: (answer: string) => boolean;
  },
): Promise<boolean> {
  if (!serverHistory.length) return false;
  return withSideQuestionLock(key, async () => {
    const computeNext = (raw: SavedSideQuestion | undefined): SavedSideQuestion | undefined => {
      if (options?.canCommit && !options.canCommit()) return undefined;
      const saved = normalizeSavedSideQuestion(raw ?? readLegacySideQuestion(key));
      if (!saved?.pending || saved.pending.notSent) return undefined;
      const cleanLocal = options?.isIgnoredAnswer
        ? saved.history.filter(row => !options.isIgnoredAnswer!(row.answer))
        : saved.history;
      if (!doesTurnAnswerPending(saved.pending, serverHistory, cleanLocal, BTW_HISTORY_LIMIT)) {
        return undefined;
      }
      const localByPair = new Map<string, SideAttachment[]>();
      for (const row of cleanLocal) {
        if (row.attachments?.length) {
          localByPair.set(`${row.question.trim()}\u0000${row.answer.trim()}`, row.attachments);
        }
      }
      const mergedHistory = serverHistory.slice(-BTW_HISTORY_LIMIT).map(row => {
        const attached = row.attachments?.length
          ? row.attachments
          : localByPair.get(`${row.question.trim()}\u0000${row.answer.trim()}`);
        return { ...row, ...(attached?.length ? { attachments: attached } : {}) };
      });
      return { ...saved, history: mergedHistory, pending: undefined };
    };
    try {
      let updated = false;
      let nextValue: SavedSideQuestion | undefined;
      if (typeof drafts.updateSideThread === 'function') {
        const res = await drafts.updateSideThread<SavedSideQuestion>(key, computeNext);
        updated = res.updated;
        nextValue = res.value;
      } else {
        const raw = await drafts.readSideThread<SavedSideQuestion>(key).catch(() => undefined);
        nextValue = computeNext(raw);
        if (nextValue !== undefined) {
          await drafts.saveSideThread(key, nextValue);
          updated = true;
        }
      }
      if (updated && nextValue) {
        const normalized = normalizeSavedSideQuestion(nextValue) ?? nextValue;
        cacheSavedSideQuestion(key, normalized);
        localStorage.removeItem(key);
      }
      return updated;
    } catch { return false; }
  });
}
