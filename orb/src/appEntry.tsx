import { resolveTransportBase, restoreDesktopConnection, setTransportBridgeEnabled } from "./api";
import { render } from "solid-js/web";
import App from "./App";
import { FindBar } from "./FindBar";
import { Toaster } from "./toast";
import "./styles.css";
import { startDiagnostics } from "./diagnostics";

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

export async function mountApp(root: HTMLElement): Promise<void> {
  guardViewportPinchZoom();
  startDiagnostics();
  setTransportBridgeEnabled(true);
  await restoreDesktopConnection().catch(() => {
    console.warn("Orb could not restore the saved desktop connection");
  });
  await resolveTransportBase().catch(() => null);
  root.replaceChildren();
  render(() => <><App /><FindBar /><Toaster /></>, root);
}
