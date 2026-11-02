import { createEffect, createMemo, createSignal, onCleanup, onMount, Show } from "solid-js";
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
            <div class="mermaid-canvas" role="button" tabIndex={0} aria-label="Open diagram full screen" onClick={() => { if (!window.getSelection()?.toString()) setExpanded(true); }} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setExpanded(true); } }}>
              <img class="mermaid-svg" alt="Diagram" draggable={false} src={svgDataUrl(r().svg)} width={Math.round(r().width)} height={Math.round(r().height)} style={fitStyle(r().width, r().height)} />
            </div>
          )}
        </Show>
      </Show>
      <Show when={expanded() && svg()}>{(r) => <MermaidViewer svg={r().svg} width={r().width} height={r().height} onClose={() => setExpanded(false)} />}</Show>
    </div>
  );
}

/** Max bitmap edge (px) and total pixels so the GPU texture stays inside Metal/WebGL limits without tiling. */
const MAX_RASTER_EDGE = 4096;
const MAX_RASTER_PIXELS = 4096 * 4096;

/** Highest crisp pixel density for `width × height` that fits inside a single GPU texture. */
export function mermaidRasterDensity(width: number, height: number, targetScale: number, dpr = 1): number {
  const w = Math.max(1, width), h = Math.max(1, height);
  const cap = Math.min(MAX_RASTER_EDGE / Math.max(w, h), Math.sqrt(MAX_RASTER_PIXELS / (w * h)));
  return Math.max(0.05, Math.min(cap, Math.max(2, targetScale) * Math.max(1, dpr)));
}

/** Fullscreen zoom and pan: wheel or pinch zooms around the pointer, drag pans, 0 fits, +/- step. */
function MermaidViewer(p: { svg: string; width: number; height: number; onClose: () => void }) {
  let stage!: HTMLDivElement, canvas!: HTMLCanvasElement, fallbackImg!: HTMLImageElement;
  const src = svgDataUrl(p.svg);
  const [percent, setPercent] = createSignal(100);
  const [bitmapReady, setBitmapReady] = createSignal(false);
  let scale = 1, x = 0, y = 0, fitting = true, frame = 0, settleTimer: ReturnType<typeof setTimeout> | undefined;
  let rasterDensity = 0, decoded: HTMLImageElement | undefined, alive = true;
  let drag: { id: number; x: number; y: number; ox: number; oy: number } | undefined;

  const applyTransform = () => {
    const t = `translate3d(${x}px, ${y}px, 0) scale(${scale})`;
    canvas.style.transform = t;
    fallbackImg.style.transform = t;
    setPercent(Math.round(scale * 100));
  };
  const paint = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => { frame = 0; applyTransform(); });
  };
  const rasterize = (targetScale: number) => {
    if (!alive || !decoded) return;
    const dpr = typeof devicePixelRatio === "number" ? devicePixelRatio : 1;
    const next = mermaidRasterDensity(p.width, p.height, targetScale, dpr);
    if (bitmapReady() && Math.abs(next - rasterDensity) / (rasterDensity || 1) < 0.15) return;
    const cw = Math.max(1, Math.round(p.width * next)), ch = Math.max(1, Math.round(p.height * next));
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    canvas.width = cw;
    canvas.height = ch;
    ctx.setTransform(cw / Math.max(1, p.width), 0, 0, ch / Math.max(1, p.height), 0, 0);
    ctx.clearRect(0, 0, Math.max(1, p.width), Math.max(1, p.height));
    ctx.drawImage(decoded, 0, 0, Math.max(1, p.width), Math.max(1, p.height));
    rasterDensity = next;
    if (!bitmapReady()) setBitmapReady(true);
  };
  const scheduleRaster = () => {
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => rasterize(scale), 140);
  };
  const fit = () => {
    if (!stage.clientWidth || !stage.clientHeight) return;
    fitting = true;
    const w = stage.clientWidth - 48, h = stage.clientHeight - 48;
    scale = Math.max(0.02, Math.min(2, w / (p.width || 1), h / (p.height || 1)));
    x = (stage.clientWidth - p.width * scale) / 2;
    y = (stage.clientHeight - p.height * scale) / 2;
    paint();
    scheduleRaster();
  };
  const zoomAt = (factor: number, cx = stage.clientWidth / 2, cy = stage.clientHeight / 2) => {
    fitting = false;
    const next = Math.max(0.02, Math.min(8, scale * factor)), k = next / scale;
    x = cx - (cx - x) * k;
    y = cy - (cy - y) * k;
    scale = next;
    paint();
    scheduleRaster();
  };
  const endDrag = () => { drag = undefined; stage.classList.remove("is-dragging"); };

  onMount(() => {
    requestAnimationFrame(fit);
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(() => { if (fitting) fit(); }) : undefined;
    ro?.observe(stage);
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = stage.getBoundingClientRect();
      zoomAt(Math.exp(-e.deltaY * (e.ctrlKey || e.metaKey ? 0.01 : 0.0025)), e.clientX - r.left, e.clientY - r.top);
    };
    // WKWebView exposes native trackpad pinch as GestureEvent rather than wheel.
    let gestureBase = 1;
    const onGestureStart = (e: Event) => { e.preventDefault(); gestureBase = scale; };
    const onGestureChange = (e: Event) => {
      e.preventDefault();
      const g = e as Event & { scale: number; clientX: number; clientY: number };
      const r = stage.getBoundingClientRect();
      if (g.scale > 0) zoomAt((gestureBase * g.scale) / scale, g.clientX - r.left, g.clientY - r.top);
    };
    stage.addEventListener("wheel", onWheel, { passive: false });
    stage.addEventListener("gesturestart", onGestureStart);
    stage.addEventListener("gesturechange", onGestureChange);
    onCleanup(() => {
      ro?.disconnect();
      stage.removeEventListener("wheel", onWheel);
      stage.removeEventListener("gesturestart", onGestureStart);
      stage.removeEventListener("gesturechange", onGestureChange);
    });

    const img = new Image();
    img.decoding = "async";
    img.src = src;
    void img.decode().then(() => {
      if (!alive) return;
      decoded = img;
      rasterize(scale);
    }).catch(() => { /* Keep vector fallback <img> visible if canvas decode fails. */ });
  });
  onCleanup(() => { alive = false; cancelAnimationFrame(frame); clearTimeout(settleTimer); });

  return (
    <Dialog size="fullscreen" class="dlg-mermaid" title="Diagram" hint="Scroll to zoom · drag to pan · 0 to fit" onClose={p.onClose}
      onKeyDown={(e) => {
        if (e.isComposing || e.ctrlKey || e.altKey) return;
        if (e.metaKey && !["+", "=", "-", "0"].includes(e.key)) return;
        if (e.key === "+" || e.key === "=") { e.preventDefault(); zoomAt(1.25); }
        else if (e.key === "-") { e.preventDefault(); zoomAt(0.8); }
        else if (e.key === "0") { e.preventDefault(); fit(); }
      }}>
      <div class="mermaid-stage" ref={stage}
        onPointerDown={(e) => {
          if (e.button !== 0 || (e.target as Element).closest(".mermaid-zoom-controls")) return;
          e.preventDefault();
          try { stage.setPointerCapture(e.pointerId); } catch { /* synthetic pointer events */ }
          drag = { id: e.pointerId, x: e.clientX, y: e.clientY, ox: x, oy: y };
          stage.classList.add("is-dragging");
        }}
        onPointerMove={(e) => {
          if (!drag || drag.id !== e.pointerId) return;
          fitting = false;
          x = drag.ox + e.clientX - drag.x;
          y = drag.oy + e.clientY - drag.y;
          paint();
        }}
        onPointerUp={(e) => { try { if (stage.hasPointerCapture(e.pointerId)) stage.releasePointerCapture(e.pointerId); } catch {} endDrag(); }}
        onPointerCancel={endDrag} onLostPointerCapture={endDrag}>
        <canvas ref={canvas} class="mermaid-zoom" role="img" aria-label="Diagram" style={{ width: `${p.width}px`, height: `${p.height}px`, visibility: bitmapReady() ? "visible" : "hidden" }} />
        <img ref={fallbackImg} class="mermaid-zoom-fallback" alt="" aria-hidden="true" draggable={false} src={src} style={{ width: `${p.width}px`, height: `${p.height}px`, display: bitmapReady() ? "none" : "block" }} />
        <div class="mermaid-zoom-controls">
          <button type="button" class="icon-btn" aria-label="Zoom out" onClick={() => zoomAt(0.8)}>−</button>
          <span class="mermaid-zoom-level">{percent()}%</span>
          <button type="button" class="icon-btn" aria-label="Zoom in" onClick={() => zoomAt(1.25)}>+</button>
          <button type="button" class="mermaid-fit" onClick={fit}>Fit</button>
        </div>
      </div>
    </Dialog>
  );
}
