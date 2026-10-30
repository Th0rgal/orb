import { restoreDesktopConnection } from "./api";
import { render } from "solid-js/web";
import App from "./App";
import { FindBar } from "./FindBar";
import { Toaster } from "./toast";
import "./styles.css";
import { startDiagnostics } from "./diagnostics";

export async function mountApp(root: HTMLElement): Promise<void> {
  startDiagnostics();
  await restoreDesktopConnection().catch(() => {
    console.warn("Orb could not restore the saved desktop connection");
  });
  root.replaceChildren();
  render(() => <><App /><FindBar /><Toaster /></>, root);
}
