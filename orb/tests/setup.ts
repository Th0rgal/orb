import { afterEach } from "vitest";
import { cleanup } from "@solidjs/testing-library";
afterEach(() => { cleanup(); sessionStorage.clear(); localStorage.clear(); });

// jsdom has no layout engine; geometry is exercised in browser tests.
globalThis.ResizeObserver ??= class {observe(){} unobserve(){} disconnect(){}};
