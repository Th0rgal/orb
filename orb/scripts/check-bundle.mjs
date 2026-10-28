// Count the complete eager startup graph, including App after WASM initialization.
import fs from "node:fs";
import path from "node:path";

const BUDGET_KB = 1150;
const LAZY = ["katex", "mermaid", "pdfjs-dist", "cytoscape"];
const dist = path.resolve(process.argv[2] ?? "dist");
const manifest = JSON.parse(fs.readFileSync(path.join(dist, ".vite/manifest.json"), "utf8"));
const seen = new Set();
const visit = key => {
  if (seen.has(key)) return;
  const entry = manifest[key];
  if (!entry) throw new Error(`Missing startup manifest entry: ${key}`);
  seen.add(key);
  for (const dependency of entry.imports ?? []) visit(dependency);
};
const roots = Object.keys(manifest).filter(key => manifest[key].isEntry);
if (!roots.length) throw new Error("Missing startup entry in Vite manifest");
for (const key of roots) {
  visit(key);
  // The tiny bootstrap immediately imports index; include that first boundary.
  for (const dependency of manifest[key].dynamicImports ?? []) visit(dependency);
}
// Vite can coalesce the App into a shared dynamic chunk, keyed by _appEntry-HASH.js
// rather than its source path. Require one named App entry and count its imports.
const apps = Object.keys(manifest).filter(key => manifest[key].name === "appEntry" && manifest[key].isDynamicEntry);
if (apps.length !== 1) throw new Error("Missing or ambiguous eager App entry in Vite manifest");
visit(apps[0]);
let bytes = 0;
const offenders = [], files = new Set([...seen].map(key => manifest[key].file));
// HTML transforms can inject scripts outside Vite's manifest. Reject anything
// outside the counted graph rather than silently exempting its bytes/imports.
const html = fs.readFileSync(path.join(dist, "index.html"), "utf8");
const baseURL = new URL("https://orb-bundle.invalid/");
for (const tag of html.matchAll(/<script\b[^>]*>/gi)) {
  const src = /\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(tag[0]);
  if (!src) continue;
  const value = (src[1] ?? src[2] ?? src[3]).trim();
  const url = new URL(value, baseURL);
  const file = decodeURIComponent(url.pathname).replace(/^\//, "");
  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(value) || value.includes("\\") ||
      url.origin !== baseURL.origin || !files.has(file)) throw new Error(`Unaccounted startup script: ${value}`);
}
for (const file of files) {
  const code = fs.readFileSync(path.join(dist, file), "utf8");
  bytes += Buffer.byteLength(code);
  const name = path.basename(file);
  if (/\bkatex-display\b/.test(code) && /renderToString/.test(code) && /KaTeX parse error/.test(code)) offenders.push(`${file}: katex`);
  if (/mermaid/i.test(name) || LAZY.some(lazy => name.startsWith(lazy))) offenders.push(file);
}
const kb = Math.round(bytes / 1024);
console.log(`startup JS: ${kb} kB in ${files.size} chunks (budget ${BUDGET_KB} kB)`);
if (offenders.length) { console.error(`lazy dependencies in the startup bundle: ${offenders.join(", ")}`); process.exit(1); }
if (kb > BUDGET_KB) { console.error(`startup JS over budget by ${kb - BUDGET_KB} kB`); process.exit(1); }
