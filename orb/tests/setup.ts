import { afterEach } from "vitest";
import { cleanup } from "@solidjs/testing-library";
import { render } from "solid-js/web";
import { Toaster, clearToasts } from "../src/toast";

// The app mounts one Toaster at the root (index.tsx); tests get the same.
const toasterHost = document.createElement("div");
document.body.append(toasterHost);
render(() => Toaster(), toasterHost);
afterEach(() => { cleanup(); clearToasts(); sessionStorage.clear(); localStorage.clear(); });

// jsdom has no layout engine; geometry is exercised in browser tests.
globalThis.ResizeObserver ??= class {observe(){} unobserve(){} disconnect(){}};

// jsdom has no layout; trees reveal their current row with scrollIntoView.
if (typeof Element !== "undefined" && !Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {};
