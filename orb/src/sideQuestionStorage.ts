import {readSideThread,saveSideThread} from "./composerDrafts";
import { getApiUrl, getJwt } from './api';
import type { SideAttachment, SideExchange } from './sideQuestionClient';

export type SavedSideQuestion = {
  history: SideExchange[];
  draft: string;
  model: string;
  open: boolean;
  docked: boolean;
  /** `turnId` is the turn's client message id, reused by Retry; `notSent` means
   * Core never accepted the question. */
  pending?: { question: string; answer: string; error?: string; attachments?:SideAttachment[]; turnId?: string; notSent?: boolean };
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
// Last known open/closed state per thread, so a mission switch can place the dock in the
// same frame as the transcript instead of after the async storage read.
const openHints = new Map<string, boolean>();
const forcedOpen = new Set<string>();
export function peekSideQuestionOpen(key: string): boolean | undefined {
  return forcedOpen.has(key) ? true : openHints.get(key);
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
export async function readSideQuestion(key: string): Promise<SavedSideQuestion | undefined> {
  try {
    const value = await readSideThread<SavedSideQuestion>(key).catch(()=>undefined) ?? JSON.parse(localStorage.getItem(key) ?? 'null');
    if (!value || !Array.isArray(value.history)) return;
    openHints.set(key, Boolean(value.open));
    return {
      history: value.history.filter((v: SideExchange) => typeof v?.question === 'string' && typeof v?.answer === 'string').slice(-BTW_HISTORY_LIMIT),
      draft: typeof value.draft === 'string' ? value.draft.slice(0, 2000) : '',
      model: typeof value.model === 'string' ? value.model : '',
      open: value.open === true,
      docked: value.docked === true,
      pending: typeof value.pending?.question === 'string' && typeof value.pending?.answer === 'string' ? value.pending : undefined,
      queue: Array.isArray(value.queue) ? value.queue.filter((v: QueuedSideQuestion) => typeof v?.id === 'string' && typeof v?.question === 'string').slice(0, 20) : [],
    };
  } catch { return; }
}
export async function writeSideQuestion(key: string, value: SavedSideQuestion): Promise<boolean> {
  openHints.set(key, Boolean(value.open));
  try { await saveSideThread(key,value); localStorage.removeItem(key); return true; }
  catch { return false; }
}
