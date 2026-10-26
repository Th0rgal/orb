/** Opt-in usage telemetry (docs/USAGE_TELEMETRY.md). Orb sends page, action
 * and approval events to Core, which forwards them to the owner's telemetry
 * hub namespace. Nothing is queued unless Core reports telemetry `active`.
 * Events carry identifiers only, never prompts, payloads or secrets; the
 * schemas and enums are `shared/orb-spec/fixtures/usage-telemetry.json`, and
 * iOS (`OrbUsageTelemetry.swift`) and Android (`UsageTelemetry.kt`) use the
 * same names. */
import { api } from "./api";
import { signedApi } from "./deviceApproval";

export type UsageTelemetryStatus = {
  enabled: boolean;
  prompts_enabled: boolean;
  active: boolean;
  hub_url: string;
  namespace: string | null;
  token_configured: boolean;
  queued: number;
  last_error: string | null;
};

export type UsageTelemetryConfig = Partial<{
  enabled: boolean;
  prompts_enabled: boolean;
  hub_url: string;
  namespace: string;
  /** `tl_live_` token; "" clears it. */
  token: string;
}>;

export const USAGE_ACTIONS = [
  "sidebar_move", "btw", "fork", "queue", "file_viewer_open",
  "inbox_open", "inbox_archive", "inbox_snooze", "inbox_done",
  "message_edit", "message_resend",
] as const;
export type UsageAction = (typeof USAGE_ACTIONS)[number];
export type PageSurface = "screen" | "sheet" | "pane";
export type ApprovalKind = "tool" | "command_class" | "grant" | "payment";
export type ApprovalDecision = "approved" | "denied" | "expired" | "dismissed";
export type ApprovalMethod = "face_id" | "touch_id" | "passcode" | "desktop_click" | "none";

type Event = Record<string, string | number | boolean>;
type Transport = (events: Event[]) => Promise<void>;

const FLUSH_MS = 30_000;
const FLUSH_AT = 50;
const QUEUE_CAP = 500;
const IDENT = /^[A-Za-z0-9_.:/+@-]{1,120}$/;

/** Mission and conversation ids become their kind (`m:<uuid>` → `mission`). */
export function screenName(page: string | null): string {
  if (page == null) return "home";
  const kind = /^(m|pf|c|pc|ps):/.exec(page)?.[1];
  return kind ? ({ m: "mission", pf: "project_file", c: "conversation", pc: "project_cron", ps: "project_settings" } as Record<string, string>)[kind] : page;
}

export function createUsageTelemetry(o: { transport: Transport; client?: string; appVersion?: string; now?: () => number }) {
  const now = o.now ?? Date.now;
  let active = false;
  let queue: Event[] = [];
  let flushing: Promise<void> | undefined;

  const push = (schema: string, fields: Record<string, string | number | boolean | undefined>) => {
    if (!active) return;
    const event: Event = { schema, event_id: crypto.randomUUID(), ts: new Date(now()).toISOString(), client: o.client ?? "desktop" };
    if (o.appVersion) event.app_version = o.appVersion;
    for (const [key, value] of Object.entries(fields)) {
      if (value === undefined || (typeof value === "string" && !IDENT.test(value))) continue;
      event[key] = typeof value === "number" ? Math.max(0, Math.round(value)) : value;
    }
    queue.push(event);
    if (queue.length > QUEUE_CAP) queue = queue.slice(-QUEUE_CAP);
    if (queue.length >= FLUSH_AT) void flush();
  };

  /** Send what is queued; on failure the events stay for the next flush. */
  const flush = (): Promise<void> => {
    if (flushing || !queue.length) return flushing ?? Promise.resolve();
    const batch = queue.slice(0, FLUSH_AT);
    flushing = o.transport(batch)
      .then(() => { queue = queue.slice(batch.length); })
      .catch(() => undefined)
      .finally(() => { flushing = undefined; });
    return flushing;
  };

  return {
    setActive(on: boolean) { active = on; if (!on) queue = []; },
    get active() { return active; },
    get queued() { return queue.length; },
    flush,
    action(action: UsageAction, surface?: string, count?: number) {
      push("orb.action.v1", { action, surface, count });
    },
    approval(e: { kind: ApprovalKind; decision: ApprovalDecision; method: ApprovalMethod; waitMs?: number; toolName?: string; commandClass?: string }) {
      push("orb.approval.v1", { kind: e.kind, decision: e.decision, method: e.method, wait_ms: e.waitMs, tool_name: e.toolName, command_class: e.commandClass });
    },
    /** Start a page view; call the result when it closes. Core derives
     * `quick_close` from `dwell_ms`. */
    page(screen: string, surface: PageSurface, entryPoint?: string): () => void {
      const opened = now();
      let closed = false;
      return () => {
        if (closed) return;
        closed = true;
        push("orb.page.v1", { screen, surface, entry_point: entryPoint, dwell_ms: now() - opened });
      };
    },
  };
}

export const usageTelemetry = createUsageTelemetry({
  transport: async events => { await api("/api/usage-telemetry/events", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ events }) }); },
});

export const getUsageTelemetryStatus = () => api<UsageTelemetryStatus>("/api/usage-telemetry");

export async function updateUsageTelemetryConfig(config: UsageTelemetryConfig): Promise<UsageTelemetryStatus> {
  const status = await signedApi<UsageTelemetryStatus>("PUT", "/api/usage-telemetry/config", config, "change usage telemetry");
  usageTelemetry.setActive(status.active);
  return status;
}

/** Learn whether telemetry is on and flush on a timer and when hidden. */
export function startUsageTelemetry(): () => void {
  const refresh = () => getUsageTelemetryStatus().then(s => usageTelemetry.setActive(s.active), () => undefined);
  void refresh();
  const timer = setInterval(() => void usageTelemetry.flush(), FLUSH_MS);
  const onVisibility = () => { if (document.visibilityState === "hidden") void usageTelemetry.flush(); else void refresh(); };
  document.addEventListener("visibilitychange", onVisibility);
  return () => { clearInterval(timer); document.removeEventListener("visibilitychange", onVisibility); };
}
