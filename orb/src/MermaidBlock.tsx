import { createEffect, createMemo, createSignal, onCleanup, Show } from "solid-js";
import { copyText } from "./clipboard";
import { Dialog } from "./Dialog";
import { CheckIcon, CopyIcon } from "./icons";
import { cachedMermaid, orbMermaidTheme, svgDataUrl, renderMermaid, type MermaidResult, type MermaidTheme } from "./mermaidRenderer";

/** Fenced languages rendered as diagrams. */
export const isMermaidLang = (lang: string) => /^\s*mermaid\s*$/i.test(lang);

// One observer for every block: the theme attribute changes rarely, and the
// token-derived theme is part of each cache key.
const [themeTick, setThemeTick] = createSignal(0);
let observing = false;
function watchTheme() {
  if (observing || typeof MutationObserver === "undefined") return;
  observing = true;
  new MutationObserver(() => setThemeTick((n) => n + 1)).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "style", "class"] });
}

const ExpandIcon = (p: { size?: number }) => (
  <svg width={p.size ?? 14} height={p.size ?? 14} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M9.5 2.5h4v4M6.5 13.5h-4v-4M13.5 2.5 9 7M2.5 13.5 7 9" />
  </svg>
);

/** Debounce for a block that just closed: the message may still be settling. */
const RENDER_DELAY = 140;
/** Inline diagrams are never taller than this; the expanded view shows them at any size. */
const MAX_INLINE_HEIGHT = "60vh";
/**
 * Fit inside the card: as wide as the column allows, never past natural size,
 * and never taller than MAX_INLINE_HEIGHT, keeping the aspect ratio. The width
 * is known before the image decodes, so the frame never jumps.
 */
export function fitStyle(width: number, height: number) {
  const ratio = width / (height || 1);
  return { width: `min(${width}px, 100%, calc(${MAX_INLINE_HEIGHT} * ${ratio.toFixed(4)}))`, "aspect-ratio": `${width} / ${height || 1}`, height: "auto" };
}

export function MermaidBlock(p: { text: string; complete: boolean }) {
  watchTheme();
  const theme = createMemo<MermaidTheme>(() => { themeTick(); return orbMermaidTheme(); }, orbMermaidTheme(), { equals: (a, b) => JSON.stringify(a) === JSON.stringify(b) });
  const source = () => p.text.replace(/\s+$/, "");
  const [result, setResult] = createSignal<MermaidResult | undefined>(p.complete ? cachedMermaid(source(), theme()) : undefined);
  const [choice, setChoice] = createSignal<"diagram" | "code" | undefined>();
  const [feedback, setFeedback] = createSignal("");
  const [expanded, setExpanded] = createSignal(false);
  let feedbackTimer: ReturnType<typeof setTimeout> | undefined;
  onCleanup(() => clearTimeout(feedbackTimer));

  createEffect(() => {
    const text = source(), complete = p.complete, t = theme();
    if (!complete) return;
    const hit = cachedMermaid(text, t);
    if (hit) { setResult(hit); return; }
    let live = true;
    const timer = setTimeout(() => void renderMermaid(text, t).then((r) => { if (live) setResult(r); }), RENDER_DELAY);
    onCleanup(() => { live = false; clearTimeout(timer); });
  });

  const failed = () => { const r = result(); return r && !r.ok ? r.error : undefined; };
  const svg = () => { const r = result(); return r?.ok ? r : undefined; };
  const view = () => (!p.complete || failed() ? "code" : choice() ?? "diagram");
  const copy = async () => {
    try { await copyText(source()); setFeedback("Copied"); } catch (e) { setFeedback(e instanceof Error ? e.message : String(e)); }
    clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(() => setFeedback(""), 2500);
  };

  return (
    <div class="md-code-block mermaid-block" data-view={view()} data-state={!p.complete ? "streaming" : failed() ? "error" : svg() ? "ready" : "rendering"}>
      <div class="mermaid-head">
        <span class="mermaid-label">Mermaid</span>
        <div class="mermaid-toggle" role="group" aria-label="Mermaid view">
          <button type="button" aria-pressed={view() === "diagram"} disabled={!p.complete || !!failed()} onClick={() => setChoice("diagram")}>Diagram</button>
          <button type="button" aria-pressed={view() === "code"} onClick={() => setChoice("code")}>Code</button>
        </div>
        <span class="mermaid-spacer" />
        <Show when={feedback()}><span class="mermaid-feedback" role="status">{feedback()}</span></Show>
        <button type="button" class="icon-btn mermaid-action" aria-label="Copy diagram source" title={feedback() || "Copy source"} onClick={() => void copy()}>
          <Show when={feedback() === "Copied"} fallback={<CopyIcon size={14} />}><CheckIcon size={14} /></Show>
        </button>
        <button type="button" class="icon-btn mermaid-action" aria-label="Expand diagram" title="Expand" disabled={!svg()} onClick={() => setExpanded(true)}>
          <ExpandIcon />
        </button>
      </div>
      <Show when={view() === "diagram"} fallback={
        <>
          <Show when={failed()}>{(msg) => <div class="mermaid-error" role="note"><strong>Couldn't render diagram</strong><span>{msg()}</span></div>}</Show>
          <pre><code>{p.text}</code></pre>
        </>
      }>
        <Show when={svg()} fallback={<div class="mermaid-skeleton" aria-label="Rendering diagram" role="status"><span /><span /><span /></div>}>
          {(r) => (
            <div class="mermaid-canvas" tabIndex={0} aria-label="Diagram" onDblClick={() => setExpanded(true)}>
              <img class="mermaid-svg" alt="Diagram" draggable={false} src={svgDataUrl(r().svg)} width={Math.round(r().width)} height={Math.round(r().height)} style={fitStyle(r().width, r().height)} />
            </div>
          )}
        </Show>
      </Show>
      <Show when={expanded() && svg()}>{(r) => <MermaidViewer svg={r().svg} width={r().width} height={r().height} onClose={() => setExpanded(false)} />}</Show>
    </div>
  );
}

/** Fullscreen zoom and pan: wheel or pinch zooms around the pointer, drag pans, 0 fits, +/- step. */
function MermaidViewer(p: { svg: string; width: number; height: number; onClose: () => void }) {
  let stage!: HTMLDivElement;
  const [scale, setScale] = createSignal(1);
  const [pos, setPos] = createSignal({ x: 0, y: 0 });
  const fit = () => {
    const w = stage.clientWidth - 48, h = stage.clientHeight - 48;
    const s = Math.max(0.02, Math.min(2, w / (p.width || 1), h / (p.height || 1)));
    setScale(s);
    setPos({ x: (stage.clientWidth - p.width * s) / 2, y: (stage.clientHeight - p.height * s) / 2 });
  };
  const zoomAt = (factor: number, cx = stage.clientWidth / 2, cy = stage.clientHeight / 2) => {
    const s = scale(), next = Math.max(0.02, Math.min(8, s * factor)), k = next / s, o = pos();
    setScale(next);
    setPos({ x: cx - (cx - o.x) * k, y: cy - (cy - o.y) * k });
  };
  let drag: { x: number; y: number; ox: number; oy: number } | undefined;
  createEffect(() => { if (stage) requestAnimationFrame(fit); });
  return (
    <Dialog size="fullscreen" class="dlg-mermaid" title="Diagram" hint="Scroll to zoom · drag to pan · 0 to fit" onClose={p.onClose}
      onKeyDown={(e) => {
        if (e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key === "+" || e.key === "=") { e.preventDefault(); zoomAt(1.25); }
        else if (e.key === "-") { e.preventDefault(); zoomAt(0.8); }
        else if (e.key === "0") { e.preventDefault(); fit(); }
      }}>
      <div class="mermaid-stage" ref={stage}
        onWheel={(e) => { e.preventDefault(); const r = stage.getBoundingClientRect(); zoomAt(Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0025)), e.clientX - r.left, e.clientY - r.top); }}
        onPointerDown={(e) => { if (e.button !== 0 || (e.target as Element).closest(".mermaid-zoom-controls")) return; stage.setPointerCapture(e.pointerId); const o = pos(); drag = { x: e.clientX, y: e.clientY, ox: o.x, oy: o.y }; }}
        onPointerMove={(e) => { if (drag) setPos({ x: drag.ox + e.clientX - drag.x, y: drag.oy + e.clientY - drag.y }); }}
        onPointerUp={() => { drag = undefined; }} onPointerCancel={() => { drag = undefined; }}>
        <img class="mermaid-zoom" alt="Diagram" draggable={false} src={svgDataUrl(p.svg)} style={{ width: `${p.width}px`, height: `${p.height}px`, transform: `translate(${pos().x}px, ${pos().y}px) scale(${scale()})` }} />
        <div class="mermaid-zoom-controls">
          <button type="button" class="icon-btn" aria-label="Zoom out" onClick={() => zoomAt(0.8)}>−</button>
          <span class="mermaid-zoom-level">{Math.round(scale() * 100)}%</span>
          <button type="button" class="icon-btn" aria-label="Zoom in" onClick={() => zoomAt(1.25)}>+</button>
          <button type="button" class="mermaid-fit" onClick={fit}>Fit</button>
        </div>
      </div>
    </Dialog>
  );
}
