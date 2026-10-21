import { render } from "solid-js/web";
import { Transcript, buildTranscript } from "../src/Transcript";
import type { StreamEvent } from "../src/stream";
import "../src/styles.css";
// 320 turns of realistic assistant output: prose, lists, a highlighted code
// block, inline and display math, so remounting rows does real Markdown,
// KaTeX and Prism work.
const events: StreamEvent[] = [];
for (let i = 0; i < 320; i++) {
  const lines = 4 + (i * 7) % 23;
  const code = Array.from({ length: lines }, (_, l) => `  const v${l} = compute(${i}, ${l}) * Math.sqrt(${l + 1}); // step ${l}`).join("\n");
  const reply = `## Step ${i}\n\nWe inspect **module ${i}** and the \`render${i}()\` path. The cost is $O(n \\log n)$ where $n = ${i + 3}$.\n\n` +
    `- first point about turn ${i}\n- second point with a [link](https://example.com/${i})\n- third point\n\n` +
    "```ts\nexport function f" + i + "() {\n" + code + "\n  return v0;\n}\n```\n\n" +
    `$$\\sum_{k=1}^{${i + 2}} \\frac{k^2}{${i + 1}} = \\int_0^1 x^{${i % 9}}\\,dx$$\n\n` +
    (i % 3 ? `A closing paragraph that wraps over a couple of lines so heights differ between turns. `.repeat(1 + i % 4) : "");
  events.push(
    { type: "user_message", data: { content: `Question ${i}: ${"please look at this ".repeat(1 + i % 5)}`, id: `u${i}` } },
    { type: "assistant_message", data: { content: reply, id: `a${i}` } },
  );
}
render(() => <main id="scroller" class="scroll" style={{ height: "100vh", overflow: "auto" }}><div class="col"><Transcript sizeKey="scroll-up" items={buildTranscript(events)} /></div></main>, document.getElementById("root")!);

/** Samples every frame while the spec scrolls: a visible row counts as
 * unpainted when the viewport shows a virtual gap or a content-visibility
 * skipped subtree. Code drawn as plain text while its highlight is still in
 * the worker is counted separately (it is drawn, just not coloured yet). */
function sampler() {
  const scroller = document.getElementById("scroller")!;
  const frames: { dt: number; blank: number; skipped: number; plain: number }[] = [];
  const jumps: unknown[] = [];
  // Screen movement the input asked for since the last painted frame.
  let intended = 0, pending = 0, still = 0;
  const onWheel = (e: WheelEvent) => { intended -= e.deltaY; };
  scroller.addEventListener("wheel", onWheel, { passive: true });
  (window as any).scrollUp.intend = (px: number) => { intended += px; };
  let drift = 0, anchor: Element | null = null, anchorTop = 0, anchorScroll = 0;
  let shift = 0, last = performance.now(), running = true, longTasks = 0;
  const po = new PerformanceObserver(list => { for (const e of list.getEntries() as any[]) shift += e.value; });
  po.observe({ type: "layout-shift", buffered: false });
  const lt = new PerformanceObserver(list => { longTasks += list.getEntries().length; });
  try { lt.observe({ type: "longtask" }); } catch {}
  const visible = (el: Element, top: number, bottom: number) => { const r = el.getBoundingClientRect(); return r.bottom > top && r.top < bottom && r.height > 0; };
  // Sample what was painted: a task posted from rAF runs right after the
  // frame, once ResizeObserver corrections and content-visibility updates
  // of that frame are done (reading in rAF itself sees a half-built frame).
  const channel = new MessageChannel();
  channel.port1.onmessage = () => sample();
  const tick = () => { if (running) channel.port2.postMessage(0); };
  const sample = () => {
    if (!running) return;
    const now = performance.now(), box = scroller.getBoundingClientRect();
    let blank = 0, skipped = 0, plain = 0;
    for (const gap of scroller.querySelectorAll('[data-virtual-transcript] > div[aria-hidden="true"]')) if (visible(gap, box.top, box.bottom)) blank++;
    for (const row of scroller.querySelectorAll(".user, .st-text, .md-code-block, .md-math-block")) if (visible(row, box.top, box.bottom) && !((row.firstElementChild ?? row) as any).checkVisibility({ contentVisibilityAuto: true })) skipped++;
    for (const code of scroller.querySelectorAll(".md-code-block pre code")) if (!code.querySelector("span") && visible(code, box.top, box.bottom)) plain++;
    // Anchor drift: how far the row under the viewport centre moved on screen
    // beyond what the wheel or drag asked for — the jump the reader sees.
    // (Scroll corrections that keep content still are not drift.)
    pending += intended; intended = 0;
    if (anchor?.isConnected && scroller.scrollTop > 0) {
      const moved = anchor.getBoundingClientRect().top - anchorTop;
      // Input may land over several frames: movement that follows the
      // pending input consumes it; movement beyond it, or against it, is drift.
      let d = 0;
      if (Math.abs(moved) < 1) { if (++still > 3) pending = 0; }
      else if (Math.sign(moved) === Math.sign(pending) && Math.abs(moved) <= Math.abs(pending) + 1) { pending -= moved; still = 0; }
      else if (Math.sign(moved) === Math.sign(pending)) { d = Math.abs(moved) - Math.abs(pending); pending = 0; still = 0; }
      else d = Math.abs(moved);
      drift += d; if (d > 30 && jumps.length < 12) jumps.push({ d: Math.round(d), key: anchor.getAttribute("data-turn-key"), moved: Math.round(moved) });
    } else pending = 0;
    anchor = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)?.closest("[data-turn-key]") ?? null;
    if (anchor) { anchorTop = anchor.getBoundingClientRect().top; anchorScroll = scroller.scrollTop; }
    frames.push({ dt: now - last, blank, skipped, plain }); last = now;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  return () => {
    running = false; scroller.removeEventListener("wheel", onWheel); po.disconnect(); lt.disconnect();
    const dts = frames.slice(1).map(f => f.dt).sort((a, b) => a - b);
    const q = (p: number) => dts[Math.min(dts.length - 1, Math.floor(p * dts.length))] ?? 0;
    return {
      frames: frames.length,
      blankFrames: frames.filter(f => f.blank).length,
      skippedFrames: frames.filter(f => f.skipped).length,
      unhighlightedFrames: frames.filter(f => f.plain).length,
      unpaintedFrames: frames.filter(f => f.blank || f.skipped).length,
      layoutShift: +shift.toFixed(4), anchorDriftPx: Math.round(drift), jumps,
      frameMedian: +q(0.5).toFixed(1), frameP95: +q(0.95).toFixed(1), frameMax: +(dts.at(-1) ?? 0).toFixed(1),
      longTasks,
    };
  };
}
function resources() {
  const mem = (performance as any).memory;
  return { domNodes: document.getElementsByTagName("*").length, heapMB: mem ? +(mem.usedJSHeapSize / 1048576).toFixed(1) : null };
}
Object.assign(window, { scrollUp: { sampler, resources } });
