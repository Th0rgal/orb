import { createSignal, onCleanup, onMount, Show } from "solid-js";

export function imageMime(name: string): string | undefined {
  return ({ png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", jfif: "image/jpeg", gif: "image/gif", webp: "image/webp", avif: "image/avif", bmp: "image/bmp", ico: "image/x-icon", svg: "image/svg+xml" } as Record<string, string>)[name.split(".").pop()?.toLowerCase() ?? ""];
}

/** Decode once; only the image's compositor transform changes during gestures. */
export default function ImagePreview(p: { name: string; load: (signal: AbortSignal) => Promise<Uint8Array>; close: () => void }) {
  const [ready, setReady] = createSignal(false), [error, setError] = createSignal("");
  const [percent, setPercent] = createSignal(100);
  let root!: HTMLElement, viewport!: HTMLDivElement, img!: HTMLImageElement;
  let url: string | undefined, frame = 0, scale = 1, x = 0, y = 0, width = 0, height = 0, fitting = true;
  let drag: { id: number; x: number; y: number } | undefined;
  const abort = new AbortController();
  const paint = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      img.style.transform = `translate3d(${x}px, ${y}px, 0) scale(${scale})`;
      setPercent(Math.round(scale * 100));
    });
  };
  const constrain = () => {
    const limitX = Math.max(0, (img.naturalWidth * scale - width) / 2);
    const limitY = Math.max(0, (img.naturalHeight * scale - height) / 2);
    x = Math.max(-limitX, Math.min(limitX, x)); y = Math.max(-limitY, Math.min(limitY, y));
  };
  const fit = () => {
    if (!ready() || !width || !height) return;
    fitting = true; scale = Math.min(1, Math.max(1, width - 32) / img.naturalWidth, Math.max(1, height - 80) / img.naturalHeight);
    x = y = 0; paint();
  };
  const zoom = (next: number, anchorX = 0, anchorY = 0) => {
    if (!ready()) return;
    fitting = false;
    next = Math.max(Math.min(.01, scale), Math.min(16, next));
    const ratio = next / scale;
    x = anchorX - (anchorX - x) * ratio; y = anchorY - (anchorY - y) * ratio;
    scale = next; constrain(); paint();
  };
  const wheel = (e: WheelEvent) => {
    if (!ready()) return;
    e.preventDefault(); e.stopPropagation();
    if (e.ctrlKey || e.metaKey) {
      const rect = viewport.getBoundingClientRect();
      zoom(scale * Math.exp(-e.deltaY * .01), e.clientX - rect.left - width / 2, e.clientY - rect.top - height / 2);
    } else {
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? height : 1;
      x -= e.deltaX * unit; y -= e.deltaY * unit; constrain(); paint();
    }
  };
  onMount(() => {
    const observer = new ResizeObserver(([entry]) => {
      width = entry.contentRect.width; height = entry.contentRect.height;
      if (fitting) fit(); else { constrain(); paint(); }
    });
    observer.observe(viewport);
    // WKWebView exposes native trackpad pinch as GestureEvent rather than wheel.
    let gestureScale = 1;
    const gestureStart = (event: Event) => { event.preventDefault(); gestureScale = scale; };
    const gestureChange = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      const rect = viewport.getBoundingClientRect();
      zoom(gestureScale * gesture.scale, gesture.clientX - rect.left - width / 2, gesture.clientY - rect.top - height / 2);
    };
    viewport.addEventListener("gesturestart", gestureStart);
    viewport.addEventListener("gesturechange", gestureChange);
    onCleanup(() => { viewport.removeEventListener("gesturestart", gestureStart); viewport.removeEventListener("gesturechange", gestureChange); });
    viewport.addEventListener("wheel", wheel, { passive: false });
    onCleanup(() => { observer.disconnect(); viewport.removeEventListener("wheel", wheel); });
    void (async () => {
      try {
        const bytes = await p.load(abort.signal);
        if (abort.signal.aborted) return;
        url = URL.createObjectURL(new Blob([bytes as Uint8Array<ArrayBuffer>], { type: imageMime(p.name) }));
        img.src = url;
        await img.decode();
        if (abort.signal.aborted) return;
        setReady(true); fit();
      } catch (e) { if (!abort.signal.aborted) setError(e instanceof Error ? e.message : String(e)); }
    })();
  });
  onCleanup(() => { abort.abort(); cancelAnimationFrame(frame); if (url) URL.revokeObjectURL(url); });
  const endDrag = () => { drag = undefined; viewport.classList.remove("is-dragging"); };
  return <section class="pdf-viewer image-viewer" ref={root} tabIndex={0} aria-label={`Image: ${p.name}`} onKeyDown={e => {
    if (e.altKey || e.metaKey || e.ctrlKey || (e.target as HTMLElement).closest("input,textarea,select")) return;
    if (!["+", "=", "-", "0", "1", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) return;
    e.preventDefault(); e.stopPropagation();
    if (e.key === "0") fit();
    else if (e.key === "1") zoom(1);
    else if (e.key === "+" || e.key === "=") zoom(scale * 1.25);
    else if (e.key === "-") zoom(scale / 1.25);
    else { x += e.key === "ArrowLeft" ? 40 : e.key === "ArrowRight" ? -40 : 0; y += e.key === "ArrowUp" ? 40 : e.key === "ArrowDown" ? -40 : 0; constrain(); paint(); }
  }}>
    <div class="image-viewport" ref={viewport} aria-busy={!ready() && !error()} onDblClick={() => fitting ? zoom(1) : fit()}
      onPointerDown={e => { if (e.button !== 0 || !ready()) return; e.preventDefault(); root.focus({ preventScroll: true }); viewport.setPointerCapture(e.pointerId); drag = { id: e.pointerId, x: e.clientX, y: e.clientY }; viewport.classList.add("is-dragging"); }}
      onPointerMove={e => { if (!drag || drag.id !== e.pointerId) return; x += e.clientX - drag.x; y += e.clientY - drag.y; drag.x = e.clientX; drag.y = e.clientY; constrain(); paint(); }}
      onPointerUp={e => { if (viewport.hasPointerCapture(e.pointerId)) viewport.releasePointerCapture(e.pointerId); endDrag(); }} onPointerCancel={endDrag} onLostPointerCapture={endDrag}>
      <img ref={img} alt={p.name} draggable={false} style={{ visibility: ready() ? "visible" : "hidden" }} />
    </div>
    <Show when={!ready() && !error()}><p class="file-muted image-status">Loading image…</p></Show>
    <Show when={error()}><p class="file-muted image-status" role="alert">Couldn’t display this image. {error()}</p></Show>
    <div class="pdf-toolbar image-toolbar" role="toolbar" aria-label="Image controls">
      <button class="s-btn pdf-back" title="Back to file details" aria-label="Back" onClick={p.close}>‹</button>
      <button class="s-btn" title="Zoom out (−)" aria-label="Zoom out" disabled={!ready() || percent() <= 1} onClick={() => zoom(scale / 1.25)}>−</button>
      <button class="s-btn image-percent" title="Actual size (1)" aria-label="Actual size" disabled={!ready()} onClick={() => zoom(1)}>{percent()}%</button>
      <button class="s-btn" title="Zoom in (+)" aria-label="Zoom in" disabled={!ready() || percent() >= 1600} onClick={() => zoom(scale * 1.25)}>+</button>
      <button class="s-btn" title="Fit to window (0)" disabled={!ready()} onClick={fit}>Fit</button>
    </div>
  </section>;
}
