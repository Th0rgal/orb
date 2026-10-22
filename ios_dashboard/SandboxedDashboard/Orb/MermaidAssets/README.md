# Bundled Mermaid renderer

- mermaid 11.17.2, MIT; npm distribution `dist/mermaid.min.js` (same version
  as `orb/package.json`). License: `LICENSE.txt`.
- `renderer.html`: hidden renderer page used by `OrbMermaidRenderer`. Its theme
  is generated from Orb desktop's dark tokens (`orb/src/mermaidRenderer.ts`).

No CDN: diagrams render offline. Mermaid runs with `securityLevel: "strict"`
(which sanitises labels with DOMPurify), and the SVG is shown in a WKWebView
whose CSP forbids every script, so diagram source can never execute code.
Update together with the desktop `mermaid` pin.
