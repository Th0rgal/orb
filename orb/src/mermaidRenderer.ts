// Mermaid rendering service for transcript diagrams.
//
// The `mermaid` package (≈ 1 MB) is imported lazily, the first time a
// completed diagram is shown, so startup and plain transcripts never pay for
// it. Results are cached by (theme, source) hash: a transcript re-render, a
// row remounted by the virtual list or the same diagram in two messages reuse
// the SVG instead of running layout again. Renders are serialised because
// mermaid keeps global configuration and measures text in the live document.

export type MermaidTheme = Record<string, string>;
export type MermaidResult = { ok: true; svg: string; width: number; height: number } | { ok: false; error: string };

type MermaidApi = typeof import("mermaid").default;
type Purify = typeof import("dompurify").default;

const MAX_SOURCE = 50_000;
const CACHE_LIMIT = 200;
const cache = new Map<string, MermaidResult>();
const pending = new Map<string, Promise<MermaidResult>>();
let loader: Promise<{ mermaid: MermaidApi; purify: Purify }> | undefined;
let queue: Promise<unknown> = Promise.resolve();
let configured = "";
let seq = 0;

/** FNV-1a, 32 bit; collisions only cost a wrong cache hit between two sources of one transcript, so the length is mixed in too. */
export function hashSource(source: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < source.length; i++) { h ^= source.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return `${(h >>> 0).toString(36)}-${source.length.toString(36)}`;
}

function cacheKey(source: string, theme: MermaidTheme): string {
  return `${hashSource(JSON.stringify(theme))}:${hashSource(source)}`;
}

function remember(key: string, value: MermaidResult) {
  cache.delete(key);
  cache.set(key, value);
  while (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value!);
}

/** A finished render of this source in this theme, if one exists. Never starts a render. */
export function cachedMermaid(source: string, theme: MermaidTheme): MermaidResult | undefined {
  const key = cacheKey(source, theme), hit = cache.get(key);
  if (hit) remember(key, hit);
  return hit;
}

export function clearMermaidCache() { cache.clear(); pending.clear(); }
export function mermaidCacheSize() { return cache.size; }

/** Test seam: replaces the lazy import (unit tests run without layout). */
export function setMermaidLoader(load: (() => Promise<{ mermaid: MermaidApi; purify: Purify }>) | undefined) {
  loader = load ? load() : undefined;
  configured = "";
}

function load() {
  return loader ??= Promise.all([import("mermaid"), import("dompurify")]).then(([m, p]) => ({ mermaid: m.default, purify: p.default }));
}

// ---- theme ---------------------------------------------------------------

function hex(value: string, fallback: string): string {
  const v = value.trim();
  if (/^#[0-9a-f]{6}$/i.test(v)) return v.toLowerCase();
  if (/^#[0-9a-f]{3}$/i.test(v)) return `#${[...v.slice(1)].map((c) => c + c).join("")}`.toLowerCase();
  return fallback;
}
/** `a` mixed into `b` by `t` (0 → b, 1 → a), as #rrggbb. */
export function mix(a: string, b: string, t: number): string {
  const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16)), pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16));
  return `#${pa.map((x, i) => Math.round(x * t + pb[i] * (1 - t)).toString(16).padStart(2, "0")).join("")}`;
}

/** Mermaid `base` theme variables derived from Orb's design tokens. */
export function orbMermaidTheme(root: Element = document.documentElement): MermaidTheme {
  const css = getComputedStyle(root), v = (name: string, fallback: string) => hex(css.getPropertyValue(name), fallback);
  const light = (root as HTMLElement).dataset?.theme === "light";
  const bg = v("--bg-inset", light ? "#f6f5f2" : "#1c1c1c"), fg = v("--fg", light ? "#242423" : "#d8d8d7");
  const fg2 = v("--fg-2", light ? "#535250" : "#b1b1b1"), fg3 = v("--fg-3", light ? "#7b7a76" : "#8a8a8a");
  const stroke = v("--stroke-strong", light ? "#d4d3cd" : "#3a3a3a"), elev = v("--bg-elev", light ? "#f1f0ed" : "#212121");
  const blue = v("--blue", light ? "#2f6bd8" : "#86aee4"), green = v("--green", light ? "#1e7a45" : "#80b28d");
  const purple = v("--purple", light ? "#7a5cd6" : "#a08ce0"), amber = v("--amber", light ? "#8a6d0b" : "#c9a227");
  const red = v("--red", light ? "#cf3a4b" : "#e0707d");
  const tint = (c: string, t: number) => mix(c, bg, t);
  const node = tint(blue, light ? 0.1 : 0.16), nodeBorder = tint(blue, light ? 0.55 : 0.5);
  const second = tint(purple, light ? 0.1 : 0.16), third = tint(green, light ? 0.09 : 0.14);
  const font = css.getPropertyValue("--sans").trim() || "-apple-system, BlinkMacSystemFont, sans-serif";
  const accents = [blue, green, purple, amber, red, fg3];
  const pie: Record<string, string> = {};
  for (let i = 0; i < 12; i++) pie[`pie${i + 1}`] = tint(accents[i % 6], i < 6 ? (light ? 0.75 : 0.7) : (light ? 0.4 : 0.38));
  const scale: Record<string, string> = {};
  for (let i = 0; i < 12; i++) { scale[`cScale${i}`] = tint(accents[i % 6], light ? 0.16 : 0.26); scale[`cScaleLabel${i}`] = fg; }
  return {
    darkMode: String(!light), background: bg, fontFamily: font, fontSize: "13px",
    pieTitleTextSize: "15px", pieSectionTextSize: "13px", pieLegendTextSize: "13px",
    textColor: fg, primaryColor: node, primaryTextColor: fg, primaryBorderColor: nodeBorder,
    secondaryColor: second, secondaryTextColor: fg, secondaryBorderColor: tint(purple, 0.5),
    tertiaryColor: third, tertiaryTextColor: fg, tertiaryBorderColor: tint(green, 0.5),
    lineColor: fg3, mainBkg: node, nodeBorder, nodeTextColor: fg, clusterBkg: tint(fg, 0.04), clusterBorder: stroke,
    titleColor: fg, edgeLabelBackground: bg, labelTextColor: fg,
    noteBkgColor: tint(amber, light ? 0.12 : 0.16), noteTextColor: fg, noteBorderColor: tint(amber, 0.5),
    actorBkg: node, actorBorder: nodeBorder, actorTextColor: fg, actorLineColor: fg3, signalColor: fg2, signalTextColor: fg,
    labelBoxBkgColor: elev, labelBoxBorderColor: stroke, loopTextColor: fg2, activationBkgColor: elev, activationBorderColor: nodeBorder,
    sequenceNumberColor: bg,
    classText: fg, attributeBackgroundColorOdd: bg, attributeBackgroundColorEven: elev,
    labelColor: fg, altBackground: elev, stateBkg: node, stateLabelColor: fg, compositeBackground: tint(fg, 0.04), compositeTitleBackground: elev, specialStateColor: fg3, innerEndBackground: fg3,
    sectionBkgColor: tint(blue, 0.1), altSectionBkgColor: bg, sectionBkgColor2: tint(purple, 0.1),
    taskBkgColor: tint(blue, light ? 0.5 : 0.45), taskBorderColor: nodeBorder, taskTextColor: light ? "#ffffff" : bg, taskTextLightColor: fg, taskTextDarkColor: fg, taskTextOutsideColor: fg, taskTextClickableColor: blue,
    activeTaskBkgColor: tint(green, 0.45), activeTaskBorderColor: tint(green, 0.7), doneTaskBkgColor: tint(fg3, 0.35), doneTaskBorderColor: fg3,
    critBkgColor: tint(red, 0.5), critBorderColor: red, gridColor: stroke, todayLineColor: red,
    pieTitleTextColor: fg, pieSectionTextColor: light ? "#ffffff" : bg, pieLegendTextColor: fg, pieStrokeColor: bg, pieStrokeWidth: "1.5px", pieOuterStrokeColor: stroke, pieOuterStrokeWidth: "1px", pieOpacity: "1",
    relationColor: fg3, relationLabelColor: fg, relationLabelBackground: bg,
    ...Object.fromEntries(accents.flatMap((c, i) => [[`git${i}`, tint(c, light ? 0.3 : 0.4)], [`gitBranchLabel${i}`, fg]])),
    ...pie, ...scale,
  };
}

// ---- rendering -------------------------------------------------------------

function errorMessage(e: unknown): string {
  const raw = e instanceof Error ? e.message : typeof e === "string" ? e : (e as { str?: string })?.str ?? String(e);
  return raw.replace(/\s+$/g, "").split("\n").slice(0, 6).join("\n").slice(0, 600) || "Unknown syntax error";
}

function size(svg: string): { width: number; height: number } {
  const vb = /viewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)/.exec(svg);
  return vb ? { width: Number(vb[1]), height: Number(vb[2]) } : { width: 0, height: 0 };
}

/** As an <img> data URL: the SVG can then neither run script nor load anything (fonts, images, CSS) from the network. */
export function svgDataUrl(svg: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/** Sanitise mermaid's output: no scripts, event handlers, external references or foreign HTML beyond plain labels. */
/** Directives (`%%{init: …}%%`) are removed before parsing: they could restyle the diagram. */
export function stripDirectives(source: string): string {
  return source.replace(/%%\{[\s\S]*?\}%%/g, "");
}

/**
 * Author CSS is kept only when it is plainly harmless: no escapes, no image-set,
 * no @-rule except mermaid's own @keyframes, and url() only to a fragment of the
 * same SVG. Anything else is dropped whole rather than rewritten.
 */
export function safeCss(css: string): boolean {
  if (/\\|image-set|-webkit-image-set|expression\s*\(/i.test(css)) return false;
  if (/@(?!keyframes\b)/i.test(css)) return false;
  for (const m of css.matchAll(/url\s*\(\s*(['"]?)([^)]*)\)/gi)) if (!m[2].trim().startsWith("#")) return false;
  return true;
}

let hooked = false;
function installHooks(purify: Purify) {
  if (hooked) return;
  hooked = true;
  purify.addHook("uponSanitizeElement", (node, data) => {
    if (data.tagName === "style" && !safeCss(node.textContent ?? "")) node.textContent = "";
  });
  purify.addHook("uponSanitizeAttribute", (_node, data) => {
    if (data.attrName === "style") { if (!safeCss(data.attrValue)) data.keepAttr = false; }
    else if (/url\s*\(|\\/i.test(data.attrValue) && !/^\s*url\(\s*#[^)\\]*\)\s*$/i.test(data.attrValue)) data.keepAttr = false;
  });
}

export function sanitizeSvg(purify: Purify, svg: string): string {
  installHooks(purify);
  return purify.sanitize(svg, {
    USE_PROFILES: { svg: true, svgFilters: true, html: true },
    // Mermaid draws labels as HTML inside <foreignObject>; DOMPurify checks lower-cased names.
    ADD_TAGS: ["foreignobject"],
    HTML_INTEGRATION_POINTS: { foreignobject: true },
    FORBID_TAGS: ["script", "iframe", "object", "embed", "form", "input", "button", "textarea", "a", "image", "use", "set", "animate", "animateMotion", "animateTransform", "animatemotion", "animatetransform", "link", "img", "video", "audio", "source"],
    FORBID_ATTR: ["href", "xlink:href", "action", "formaction", "srcset", "src"],
    ALLOW_DATA_ATTR: false,
  });
}

async function run(raw: string, theme: MermaidTheme): Promise<MermaidResult> {
  const { mermaid, purify } = await load();
  const source = stripDirectives(raw);
  const config = JSON.stringify(theme);
  if (configured !== config) {
    mermaid.initialize({
      // Diagram source can carry %%{init}%% directives or front-matter config; these keys stay Orb's.
      secure: ["secure", "securityLevel", "startOnLoad", "maxTextSize", "maxEdges", "suppressErrorRendering", "theme", "themeVariables", "themeCSS", "fontFamily", "darkMode", "htmlLabels", "dompurifyConfig"],
      // Labels are measured in the live document before our own pass: keep resources out of them too.
      dompurifyConfig: { FORBID_TAGS: ["img", "image", "a", "video", "audio", "source", "picture", "iframe", "object", "embed", "link", "style"], FORBID_ATTR: ["href", "xlink:href", "src", "srcset", "style", "background"] },
      startOnLoad: false, securityLevel: "strict", theme: "base", themeVariables: theme,
      // Mermaid fills ER cardinality circles white and draws gantt grids light regardless of theme.
      themeCSS: `marker circle { fill: ${theme.background}; } .grid .tick line { stroke: ${theme.clusterBorder}; opacity: 1; }`, fontFamily: theme.fontFamily,
      maxTextSize: MAX_SOURCE, maxEdges: 800, suppressErrorRendering: true, htmlLabels: true,
      flowchart: { useMaxWidth: false, padding: 12, nodeSpacing: 36, rankSpacing: 44, curve: "basis" },
      sequence: { useMaxWidth: false, actorMargin: 44, boxMargin: 8, noteMargin: 10, messageMargin: 32, mirrorActors: false },
      class: { useMaxWidth: false }, state: { useMaxWidth: false }, er: { useMaxWidth: false },
      gantt: { useMaxWidth: false, useWidth: 760, axisFormat: "%b %-d", barHeight: 22, barGap: 6, fontSize: 12, sectionFontSize: 12, leftPadding: 90 },
      pie: { useMaxWidth: false, textPosition: 0.72 }, mindmap: { useMaxWidth: false, padding: 12 },
      journey: { useMaxWidth: false }, timeline: { useMaxWidth: false }, gitGraph: { useMaxWidth: false },
    });
    configured = config;
  }
  try {
    await mermaid.parse(source);
  } catch (e) {
    return { ok: false, error: errorMessage(e) };
  }
  const id = `orb-mermaid-${++seq}`;
  try {
    const { svg } = await mermaid.render(id, source);
    const clean = sanitizeSvg(purify, svg);
    return { ok: true, svg: clean, ...size(clean) };
  } catch (e) {
    return { ok: false, error: errorMessage(e) };
  } finally {
    // A failed render leaves its scratch nodes behind.
    document.getElementById(id)?.remove();
    document.getElementById(`d${id}`)?.remove();
  }
}

/** Render (or reuse) a diagram. Concurrent requests for the same source share one render. */
export function renderMermaid(source: string, theme: MermaidTheme = orbMermaidTheme()): Promise<MermaidResult> {
  const key = cacheKey(source, theme), hit = cache.get(key);
  if (hit) { remember(key, hit); return Promise.resolve(hit); }
  if (source.length > MAX_SOURCE) return Promise.resolve({ ok: false, error: `Diagram source is too large (${source.length} characters)` });
  if (!source.trim()) return Promise.resolve({ ok: false, error: "Empty diagram" });
  const inFlight = pending.get(key);
  if (inFlight) return inFlight;
  const job = queue.then(() => run(source, theme), () => run(source, theme)).catch((e) => ({ ok: false as const, error: errorMessage(e) }))
    .then((result) => { pending.delete(key); remember(key, result); return result; });
  queue = job;
  pending.set(key, job);
  return job;
}
