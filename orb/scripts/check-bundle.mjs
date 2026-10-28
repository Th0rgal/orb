// Startup bundle budget: the chunks index.html loads before the first paint.
// Heavy renderers (KaTeX, Mermaid, PDF.js) and Settings pages load on demand;
// a static import that pulls one back into the entry chunk fails this check.
import fs from "node:fs";
import path from "node:path";

const BUDGET_KB = 1150;
const LAZY = ["katex", "mermaid", "pdfjs-dist", "cytoscape"];
const dist = path.resolve(process.argv[2] ?? "dist");
const assets = path.join(dist, "assets");
const seen = new Set();
const visit = file => {
  if (seen.has(file)) return;
  seen.add(file);
  const code = fs.readFileSync(path.join(assets, file), "utf8");
  // Static imports only; dynamic import() chunks are loaded on demand.
  for (const m of code.matchAll(/(?:^|[;}\s])import\s*(?:[\w${}\s,*]+from\s*)?["']\.\/([^"']+\.js)["']/g)) visit(m[1]);
};
const html = fs.readFileSync(path.join(dist, "index.html"), "utf8");
for (const m of html.matchAll(/src="\/assets\/([^"]+\.js)"/g)) visit(m[1]);
// The entry is a tiny bootstrap that dynamic-imports the app; count that too.
for (const file of [...seen]) {
  const code = fs.readFileSync(path.join(assets, file), "utf8");
  for (const m of code.matchAll(/import\(["']\.\/([^"']+\.js)["']\)/g)) visit(m[1]);
}
let bytes = 0;
const offenders = [];
for (const file of seen) {
  const code = fs.readFileSync(path.join(assets, file), "utf8");
  bytes += code.length;
  if (/\bkatex-display\b/.test(code) && /renderToString/.test(code) && /KaTeX parse error/.test(code)) offenders.push(`${file}: katex`);
  if (/mermaid/i.test(file) || LAZY.some(name => file.startsWith(name))) offenders.push(file);
}
const kb = Math.round(bytes / 1024);
console.log(`startup JS: ${kb} kB in ${seen.size} chunks (budget ${BUDGET_KB} kB)`);
if (offenders.length) { console.error(`lazy dependencies in the startup bundle: ${offenders.join(", ")}`); process.exit(1); }
if (kb > BUDGET_KB) { console.error(`startup JS over budget by ${kb - BUDGET_KB} kB`); process.exit(1); }
