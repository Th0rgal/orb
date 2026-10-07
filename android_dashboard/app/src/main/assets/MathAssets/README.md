# Bundled rich-text dependencies

- markdown-it 14.1.0, MIT; npm distribution `dist/markdown-it.min.js`.
  License: `markdown-it-LICENSE.txt`.
- KaTeX 0.18.9, MIT; distribution JavaScript, stylesheet and fonts.
  License: `LICENSE.txt`.
- `orb-renderer.js`: Orb integration rules and resource/link policy.

Bundled deliberately: Markdown and math do not need a CDN or user network
connection. Raw HTML is disabled, KaTeX trust is false and macro expansion is
bounded. The WKWebView uses a nonpersistent data store and a restrictive CSP.
Update vendored assets together, keep their licenses, then run both the Node
corpus and Simulator WebKit tests in `TestsSupport/README.md`.
