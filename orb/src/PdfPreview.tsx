import { createEffect, createSignal, onCleanup, onMount, Show } from "solid-js";
import { getDocument, GlobalWorkerOptions, type PDFDocumentProxy, type RenderTask } from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

GlobalWorkerOptions.workerSrc = workerUrl;

/** Render one page at a time; no browser PDF plugin required in the Tauri webview. */
export default function PdfPreview(p: { name: string; load: (signal: AbortSignal) => Promise<Uint8Array>; close: () => void }) {
  const [doc, setDoc] = createSignal<PDFDocumentProxy>();
  const [page, setPage] = createSignal(1);
  const [width, setWidth] = createSignal(0);
  const [error, setError] = createSignal("");
  const [painting, setPainting] = createSignal(false);
  // 1 = fit width; the page is re-rendered at every zoom, never CSS-scaled for long.
  const [zoom, setZoom] = createSignal(1);
  let fitScale = 0, pageWidth = 0;
  const abort = new AbortController();
  let root!: HTMLElement, viewport!: HTMLDivElement, canvas!: HTMLCanvasElement;
  const go = (number: number) => { if (doc()) setPage(Math.max(1, Math.min(number, doc()!.numPages))); };
  /** Zoom around a viewport point, keeping the content under it in place. */
  const zoomTo = (next: number, anchorX = viewport.clientWidth / 2, anchorY = viewport.clientHeight / 2) => {
    next = Math.max(.25, Math.min(8, next));
    const ratio = next / zoom();
    if (!doc() || !fitScale || Math.abs(ratio - 1) < 1e-3) return;
    const left = viewport.scrollLeft + anchorX, top = viewport.scrollTop + anchorY - canvas.offsetTop;
    setZoom(next);
    // Stretch the current bitmap at once so the gesture follows the fingers; the effect repaints it sharp.
    canvas.style.width = `${parseFloat(canvas.style.width) * ratio}px`; canvas.style.height = `${parseFloat(canvas.style.height) * ratio}px`;
    viewport.scrollLeft = left * ratio - anchorX; viewport.scrollTop = top * ratio + canvas.offsetTop - anchorY;
  };
  const fit = () => zoomTo(1);
  // Double-click: fit ↔ the page at its printed size (pdf.js CSS units), or 2× when that already fits.
  const toggle = (x?: number, y?: number) => {
    const actual = pageWidth ? 96 / 72 / fitScale : 2;
    zoomTo(zoom() !== 1 ? 1 : actual > 1.05 ? actual : 2, x, y);
  };
  const keydown = (event: KeyboardEvent) => {
    if (event.altKey || event.ctrlKey || event.shiftKey || event.isComposing || (event.target as HTMLElement).closest("input, textarea, select, [contenteditable=true]")) return;
    const zoomKey = ({"+":1.25, "=":1.25, "-":1/1.25} as Record<string, number>)[event.key];
    if (zoomKey || event.key === "0") {
      event.preventDefault(); event.stopPropagation();
      if (zoomKey) zoomTo(zoom() * zoomKey); else fit();
      return;
    }
    if (event.metaKey) return;
    const next = ({ArrowLeft:page()-1, ArrowRight:page()+1, PageUp:page()-1, PageDown:page()+1, Home:1, End:doc()?.numPages ?? 1} as Record<string, number>)[event.key];
    if (next === undefined) return;
    event.preventDefault(); event.stopPropagation(); go(next); root.focus({preventScroll:true});
  };
  let loading: ReturnType<typeof getDocument> | undefined;
  let rendering: RenderTask | undefined;
  let revision = 0, shownPage = 0, drag: { id: number; x: number; y: number } | undefined;
  onMount(() => {
    root.focus({preventScroll:true});
    const observer = new ResizeObserver(([entry]) => setWidth(Math.max(1, entry.contentRect.width)));
    observer.observe(viewport);
    onCleanup(() => observer.disconnect());
    const point = (event: { clientX: number; clientY: number }) => { const rect = viewport.getBoundingClientRect(); return [event.clientX - rect.left, event.clientY - rect.top] as const; };
    // Trackpad pinch arrives as ctrl+wheel in Chromium and as GestureEvent in WKWebView.
    const wheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      zoomTo(zoom() * Math.exp(-event.deltaY * .01), ...point(event));
    };
    let gestureZoom = 1;
    const gestureStart = (event: Event) => { event.preventDefault(); gestureZoom = zoom(); };
    const gestureChange = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      zoomTo(gestureZoom * gesture.scale, ...point(gesture));
    };
    viewport.addEventListener("wheel", wheel, { passive: false });
    viewport.addEventListener("gesturestart", gestureStart);
    viewport.addEventListener("gesturechange", gestureChange);
    onCleanup(() => { viewport.removeEventListener("wheel", wheel); viewport.removeEventListener("gesturestart", gestureStart); viewport.removeEventListener("gesturechange", gestureChange); });
    void (async () => {
      try {
        const bytes = await p.load(abort.signal);
        if (abort.signal.aborted) return;
        loading = getDocument({ data: bytes });
        const document = await loading.promise;
        if (!abort.signal.aborted) setDoc(document);
      } catch (e) { if (!abort.signal.aborted) setError(e instanceof Error ? e.message : String(e)); }
    })();
  });
  createEffect(() => {
    const document = doc(), number = page(), available = width(), factor = zoom();
    const current = ++revision;
    const previous = rendering;
    previous?.cancel();
    if (!document || !available) return;
    setPainting(true);
    void (async () => {
      try {
        // A cancelled render must release the canvas before it can be reused.
        await previous?.promise.catch(() => {});
        const pdfPage = await document.getPage(number);
        if (current !== revision || abort.signal.aborted) return;
        pageWidth = pdfPage.getViewport({scale:1}).width;
        fitScale = Math.min(available / pageWidth, 2);
        const view = pdfPage.getViewport({scale: fitScale * factor});
        // Sharp at the device ratio, bounded so deep zoom cannot exhaust canvas memory.
        const ratio = Math.min(window.devicePixelRatio || 1, 2, Math.sqrt(32e6 / (view.width * view.height)));
        canvas.width = Math.ceil(view.width * ratio); canvas.height = Math.ceil(view.height * ratio);
        canvas.style.width = `${view.width}px`; canvas.style.height = `${view.height}px`;
        rendering = pdfPage.render({ canvas, viewport: view, transform: [ratio,0,0,ratio,0,0] });
        await rendering.promise;
        if (current === revision) { setPainting(false); if (number !== shownPage) { shownPage = number; viewport.scrollTop = 0; } }
      } catch (e) {
        if (current === revision && !abort.signal.aborted) { setPainting(false); setError(e instanceof Error ? e.message : String(e)); }
      }
    })();
  });
  onCleanup(() => { abort.abort(); revision++; rendering?.cancel(); void loading?.destroy(); });
  return <section class="pdf-viewer" ref={root} tabIndex={0} onKeyDown={keydown} aria-label={`PDF: ${p.name}`} aria-keyshortcuts="ArrowLeft ArrowRight PageUp PageDown Home End Meta+= Meta+- Meta+0">
    <div class="pdf-toolbar" role="toolbar" aria-label="PDF controls">
      <button class="s-btn pdf-back" title="Back to file details" aria-label="Back" onClick={p.close}>‹</button>
      <div class="pdf-pagination">
        <button class="s-btn" aria-label="Previous page" disabled={!doc() || page() <= 1} title="Previous page (← or Page Up)" onClick={() => { go(page()-1); root.focus({preventScroll:true}); }}>‹</button>
        <span aria-live="polite">{doc() ? `${page()} / ${doc()!.numPages}` : "Loading…"}</span>
        <button class="s-btn" aria-label="Next page" disabled={!doc() || page() >= doc()!.numPages} title="Next page (→ or Page Down)" onClick={() => { go(page()+1); root.focus({preventScroll:true}); }}>›</button>
      </div>
      <div class="pdf-zoom">
        <button class="s-btn" aria-label="Zoom out" title="Zoom out (⌘−)" disabled={!doc() || zoom() <= .25} onClick={() => zoomTo(zoom() / 1.25)}>−</button>
        <button class="s-btn pdf-zoom-level" aria-label="Fit width" title="Fit width (⌘0) · double-click the page toggles" disabled={!doc()} onClick={fit}>{Math.round(zoom() * 100)}%</button>
        <button class="s-btn" aria-label="Zoom in" title="Zoom in (⌘+)" disabled={!doc() || zoom() >= 8} onClick={() => zoomTo(zoom() * 1.25)}>+</button>
      </div>
    </div>
    <Show when={error()}><p class="file-muted" role="alert">Couldn’t display this PDF. {error()}</p></Show>
    <div class="pdf-pages" ref={viewport} aria-busy={!doc() || painting()} classList={{"is-zoomed": zoom() > 1}}
      onDblClick={event => { const rect = viewport.getBoundingClientRect(); toggle(event.clientX - rect.left, event.clientY - rect.top); }}
      onPointerDown={event => { if (event.button !== 0 || zoom() <= 1 || event.pointerType === "touch") return; viewport.setPointerCapture(event.pointerId); drag = { id: event.pointerId, x: event.clientX, y: event.clientY }; viewport.classList.add("is-dragging"); }}
      onPointerMove={event => { if (drag?.id !== event.pointerId) return; viewport.scrollLeft -= event.clientX - drag.x; viewport.scrollTop -= event.clientY - drag.y; drag.x = event.clientX; drag.y = event.clientY; }}
      onPointerUp={() => { drag = undefined; viewport.classList.remove("is-dragging"); }} onLostPointerCapture={() => { drag = undefined; viewport.classList.remove("is-dragging"); }}>
      <Show when={!doc() && !error()}><p class="file-muted">Loading PDF…</p></Show>
      <canvas onPointerDown={() => root.focus({preventScroll:true})} ref={canvas} aria-label={`Page ${page()} of ${p.name}`} style={{visibility: doc() && !error() ? "visible" : "hidden"}} />
    </div>
  </section>;
}
