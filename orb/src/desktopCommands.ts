import { nativeEvents } from "./native";

export interface DesktopCommandPayload {
  id?: string;
  ts_ms?: number;
  action?: string;
  backend?: string;
  prompt?: string;
  cwd?: string;
  page?: string;
}

export interface DesktopCommandHandlers {
  onProvidersRefresh: () => void;
  onNewAgent: (cmd: { backend?: string; prompt?: string; cwd?: string }) => void;
  onOpenPage: (page: string) => void;
}

/**
 * Subscribe to `orb-desktop-command` events emitted over `orb-locald`'s `/__orb_events`
 * SSE stream (used by system bar integrations such as `omarchy-orb-agent`).
 */
export function startDesktopCommandListener(handlers: DesktopCommandHandlers): () => void {
  const events = nativeEvents();
  if (!events?.listen) return () => {};

  const seenIds = new Set<string>();
  let disposed = false;
  let unlisten: (() => void) | undefined;

  void events
    .listen<DesktopCommandPayload>("orb-desktop-command", (ev) => {
      if (disposed) return;
      const payload = ev?.payload;
      if (!payload || typeof payload !== "object") return;
      if (typeof payload.id === "string" && payload.id.length > 0) {
        if (seenIds.has(payload.id)) return;
        seenIds.add(payload.id);
        if (seenIds.size > 128) {
          const oldest = seenIds.values().next().value;
          if (oldest !== undefined) seenIds.delete(oldest);
        }
      }
      const action = typeof payload.action === "string" ? payload.action.trim() : "";
      if (action === "providers-refresh") {
        handlers.onProvidersRefresh();
      } else if (action === "new-agent") {
        handlers.onNewAgent({
          backend: typeof payload.backend === "string" && payload.backend.trim() ? payload.backend.trim() : undefined,
          prompt: typeof payload.prompt === "string" && payload.prompt.length > 0 ? payload.prompt : undefined,
          cwd: typeof payload.cwd === "string" && payload.cwd.trim() ? payload.cwd.trim() : undefined,
        });
      } else if (action === "open-page" && typeof payload.page === "string" && payload.page.trim()) {
        handlers.onOpenPage(payload.page.trim());
      }
    })
    .then((stop) => {
      if (disposed) stop();
      else unlisten = stop;
    })
    .catch(() => {});

  return () => {
    disposed = true;
    unlisten?.();
  };
}
