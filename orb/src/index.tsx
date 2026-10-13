import {restoreDesktopConnection} from "./api";
import { render } from "solid-js/web";
import App from "./App";
import {FindBar} from "./FindBar";
import { Toaster } from "./toast";
import { initTheme } from "./theme";
import "./styles.css";
import { startDiagnostics } from "./diagnostics";

initTheme();
startDiagnostics();
void restoreDesktopConnection().finally(() => {
  render(() => <><App /><FindBar /><Toaster /></>, document.getElementById("root")!);
});
