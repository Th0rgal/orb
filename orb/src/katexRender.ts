import katex from "katex";
import "katex/dist/katex.min.css";
// Copying rendered math yields its TeX source instead of the MathML and HTML
// layers glued together ("p\n=\n0.15p=0.15").
import "katex/contrib/copy-tex";

export function renderKatex(text: string, display: boolean): string {
  return katex.renderToString(text, {displayMode: display, throwOnError: false, trust: false, strict: "ignore", maxExpand: 1000});
}
