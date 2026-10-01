import { api } from "./api";

export interface Continuation {
  id: string;
  state: "scheduled" | "queued" | "error" | "waiting_for_client" | "pending_sync";
  next_at?: string | null;
  trigger: "time" | "job" | "delivery";
  reason?: string | null;
  source?: string | null;
  error?: string | null;
}
export interface ContinuationSummary { count: number; items: Continuation[] }

export function continuationLabel(summary: ContinuationSummary): string {
  const item = summary.items.find(item => item.state === "error") ?? summary.items[0];
  if (!item) return "Scheduled wake-up";
  if (item.state === "error") return "Wake-up delivery needs attention";
  if (item.state === "pending_sync") return "Wake-up waiting to sync";
  if (item.state === "waiting_for_client") return "Wake-up waiting for this computer";
  if (item.state === "queued") return "Wake-up queued";
  if (item.trigger === "job") return "Will resume when the job finishes";
  const date = item.next_at ? new Date(item.next_at) : null;
  const time = date && Number.isFinite(date.getTime()) ? date.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : null;
  return time ? `Wake-up scheduled for ${time}` : "Scheduled wake-up";
}

export function actOnContinuation(id: string, action: "resume" | "cancel") {
  return api(`/api/control/automations/${encodeURIComponent(id)}/action`, {
    method: "POST", body: JSON.stringify({ action }),
  });
}
