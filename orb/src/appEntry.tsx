import { bootstrapDesktopRuntime, getJwt, setTransportBridgeEnabled } from "./api";
import { render } from "solid-js/web";
import App from "./App";
import { FindBar } from "./FindBar";
import { Toaster } from "./toast";
import "./styles.css";
import { startDiagnostics } from "./diagnostics";
import { hydrateTranscriptFromDisk } from "./missionCache";
import { loadPersistedSidebar } from "./persistentCache";
import { historyScope } from "./resourceCache";

let viewportZoomGuarded = false;
function guardViewportPinchZoom() {
  if (viewportZoomGuarded || typeof window === "undefined") return;
  viewportZoomGuarded = true;
  // Keep unhandled trackpad pinch gestures from magnifying the app's visual viewport;
  // interactive diagram/image/PDF stages handle ctrl+wheel and GestureEvents first.
  window.addEventListener("wheel", (e) => { if (e.ctrlKey) e.preventDefault(); }, { passive: false });
  window.addEventListener("gesturestart", (e) => e.preventDefault());
  window.addEventListener("gesturechange", (e) => e.preventDefault());
}

async function preloadFrameZeroCache(): Promise<void> {
  if (!getJwt()) return;
  const scope = historyScope();
  const tasks: Promise<unknown>[] = [loadPersistedSidebar(scope).catch(() => null)];
  try {
    const saved = typeof localStorage !== "undefined" ? localStorage.getItem("orb.selectedConversation") : null;
    if (saved && saved.startsWith("m:")) {
      const mid = saved.slice(2).trim();
      if (mid) tasks.push(hydrateTranscriptFromDisk(mid, { syncBump: true }).catch(() => undefined));
    }
  } catch {
    /* ignore storage unavailability */
  }
  await Promise.all(tasks);
}

export async function mountApp(root: HTMLElement): Promise<void> {
  guardViewportPinchZoom();
  startDiagnostics();
  setTransportBridgeEnabled(true);
  // Preload IndexedDB in parallel when web credentials are already in localStorage,
  // then ensure any connection restored from `desktop_bootstrap` also hydrates frame-0 cache.
  await Promise.all([bootstrapDesktopRuntime(), preloadFrameZeroCache()]);
  await preloadFrameZeroCache();
  root.replaceChildren();
  render(() => <><App /><FindBar /><Toaster /></>, root);
}
