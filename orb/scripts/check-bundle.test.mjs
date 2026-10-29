// Build-layout fixtures only; these are not kernel conformance observations.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const checker = fileURLToPath(new URL("./check-bundle.mjs", import.meta.url));
function check(change = () => {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "orb-bundle-"));
  try {
    fs.mkdirSync(path.join(dir, ".vite"));
    fs.mkdirSync(path.join(dir, "assets"));
    const manifest = {
      "index.html": { file: "assets/bootstrap.js", isEntry: true, dynamicImports: ["_index.js"] },
      "_index.js": { file: "assets/index.js", dynamicImports: ["_appEntry-hash.js"] },
      "_appEntry-hash.js": { file: "assets/appEntry-hash.js", name: "appEntry", isDynamicEntry: true, imports: ["_shared.js"], dynamicImports: ["lazy"] },
      "_shared.js": { file: "assets/shared.js" },
      lazy: { file: "assets/mermaid-lazy.js" },
    };
    const files = { "bootstrap.js": "", "index.js": "", "appEntry-hash.js": "a".repeat(800 * 1024), "shared.js": "b".repeat(300 * 1024), "mermaid-lazy.js": "" };
    const html = { text: '<script type="module" src="/assets/bootstrap.js"></script>' };
    change(manifest, files, html);
    for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, "assets", name), text);
    fs.writeFileSync(path.join(dir, ".vite/manifest.json"), JSON.stringify(manifest));
    fs.writeFileSync(path.join(dir, "index.html"), html.text);
    return spawnSync(process.execPath, [checker, dir], { encoding: "utf8" });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

test("counts synthetic App key and static graph, leaving feature imports lazy", () => {
  const result = check();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /startup JS: 1100 kB in 4 chunks/);
});
test("App graph still fails the unchanged byte budget", () => {
  const result = check((_, files) => { files["shared.js"] += "x".repeat(100 * 1024); });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /over budget/);
});
test("rejects missing App and a lazy renderer pulled into a static import", () => {
  assert.notEqual(check(manifest => { delete manifest["_appEntry-hash.js"]; }).status, 0);
  const result = check(manifest => { manifest["_appEntry-hash.js"].imports.push("lazy"); });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /lazy dependencies/);
});
test("rejects a script injected into HTML outside the manifest graph", () => {
  const result = check((_, files, html) => {
    files["injected.js"] = "x".repeat(100 * 1024);
    html.text += '<script src="/assets/injected.js"></script>';
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unaccounted startup script/);
});
test("rejects external scripts whose size cannot be accounted for locally", () => {
  for (const src of ["https://example.com/external.js", "https://orb-bundle.invalid/assets/bootstrap.js", "//orb-bundle.invalid/assets/bootstrap.js"]) {
    const result = check((_, __, html) => { html.text += `<script src=${src}></script>`; });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Unaccounted startup script/);
  }
});
test("recognizes quoted and unquoted HTML entry URLs without double counting", () => {
  const result = check((_, __, html) => {
    html.text += "<SCRIPT SRC='./assets/bootstrap.js?v=1'></SCRIPT><script src=/assets/bootstrap.js></script>";
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1100 kB in 4 chunks/);
});
