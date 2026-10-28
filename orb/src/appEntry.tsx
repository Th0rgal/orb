import { restoreDesktopConnection } from "./api";
import { render } from "solid-js/web";
import App from "./App";
import { FindBar } from "./FindBar";
import { Toaster } from "./toast";
import { startDiagnostics } from "./diagnostics";

export async function mountApp(root: HTMLElement): Promise<void> {
  startDiagnostics();
  await restoreDesktopConnection().catch(() => {});
  root.replaceChildren();
  render(() => <><App /><FindBar /><Toaster /></>, root);
}
